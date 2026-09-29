-- CP.Npc (server): the authoritative state machine of mission NPCs.

CP.Npc = CP.Npc or {}
local Npc = CP.Npc
local U = CP.U
local TAG = 'npc'

local CUFF_EVENT = 'crimson-police:server:npcCuff'

local STATES = {
    idle = true,
    hostile = true,
    fleeing = true,
    surrendered = true,
    cuffed = true,
    dead = true,
    restrained = true,
    freed = true,
    safe = true,
    driving = true,
    stopped = true,
}
-- Shooting a ped in one of these states costs shot_surrendered.
local PROTECTED = { surrendered = true, cuffed = true, restrained = true }
local BAG_PROTECTED = { run = true, obj = true, state = true, seq = true, taskSeq = true }

local TICK_MS = 1000               -- death watcher / health poll / cuff reach sampling
local GONE_TICKS = 1               -- checks without the entity before it counts as dead (before the engine's
                                   -- own 2-check vanish rule, so onDeath listeners see those deaths too)
local SURRENDER_GRACE_MS = 3000   -- a hit this soon after a surrender is a shot already in flight
local SHOT_WINDOW_MS = 2000       -- one shot_surrendered per shooter and ped in this window
local DAMAGE_WINDOW_MS = 1000     -- one damage report per ped and attacker in this window
local POLL_OVERLAP_MS = 2000      -- a health drop this soon after a weapon event is that event
local KILL_MEMORY_MS = 5000       -- fallback killer: the last player hit this recent
local PLAYER_MAP_MS = 250         -- ped -> player map cache
local CUFF_SLACK_M = 0.5          -- the cuff itself: maxDistance + this
local CUFF_REACH_SLACK_M = 1.5    -- reach sampling while the progress bar runs
local CUFF_DWELL_SLACK_MS = 2000  -- the officer must have been in reach for duration - this
local DEFAULT_CUFF_MS = 5000
local DEFAULT_CUFF_RANGE = 3.0
local CUFF_MS_RANGE = { 500, 60000 }
local CUFF_RANGE_RANGE = { 1.0, 10.0 }
local MAX_LABEL = 64
local MAX_HITS = 32
local MAX_NETID = 0xFFFFFF
local MAX_RUNID = 64
local RNG_SALT = 0x4E504331       -- 'NPC1'

-- Weapons that do not count as "shooting" a surrendered NPC (melee, vehicles, falls).
local NOT_SHOTS = {}
for _, name in ipairs({
    'WEAPON_UNARMED',
    'WEAPON_NIGHTSTICK',
    'WEAPON_FLASHLIGHT',
    'WEAPON_KNUCKLE',
    'WEAPON_KNIFE',
    'WEAPON_BAT',
    'WEAPON_HAMMER',
    'WEAPON_CROWBAR',
    'WEAPON_GOLFCLUB',
    'WEAPON_BOTTLE',
    'WEAPON_DAGGER',
    'WEAPON_HATCHET',
    'WEAPON_MACHETE',
    'WEAPON_SWITCHBLADE',
    'WEAPON_WRENCH',
    'WEAPON_BATTLEAXE',
    'WEAPON_POOLCUE',
    'WEAPON_STONE_HATCHET',
    'WEAPON_RUN_OVER_BY_CAR',
    'WEAPON_RAMMED_BY_CAR',
    'WEAPON_FALL',
}) do
    NOT_SHOTS[(math.tointeger(joaat(name)) or 0) & 0xFFFFFFFF] = true
end

local peds = {}          -- [netId] = rec (see recFor)
local rolls = {}         -- [runId] = { rng, results = { [netId] = boolean } }
local shotAt = {}        -- ['netId:src'] = ms of the last counted shot_surrendered
local deathFns, damageFns = {}, {}
local playerMap, playerMapAt = {}, -math.huge

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Now() return GetGameTimer() end

local function ToInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    local n = math.tointeger(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function Exists(e)
    return type(e) == 'number' and e ~= 0 and DoesEntityExist(e) == true
end

local function WriteBag(e, bag)
    local ok, err = pcall(function() Entity(e).state:set('cp', bag, true) end)
    if not ok then CP.warn(TAG, 'could not write the cp state bag of entity %s: %s', tostring(e), tostring(err)) end
    return ok
end

local function RunById(id)
    if id == nil or not (CP.Runs and CP.Runs.get) then return nil end
    local ok, run = pcall(CP.Runs.get, id)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function IsLive(run)
    return type(run) == 'table' and run.id ~= nil and run.state ~= 'ended'
end

-- The participant table of an ACTIVE participant (the run table's own data, ARCHITECTURE §4.2).
local function ActiveParticipant(run, src)
    src = tonumber(src)
    if not src or type(run) ~= 'table' or type(run.participants) ~= 'table' then return nil end
    local p = run.participants[src]
    if type(p) == 'table' and p.status == 'active' then return p end
    return nil
end

local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, res = pcall(CP.Alerts.inArena, src)
    return ok and res == true
end

-- For judging someone else's hit or kill: the crimsonArena flag is client-writable, so a player in bucket 0 is
-- in this world whatever it says (a real match player is in Crimson-Arena's bucket).
local function InArenaMatch(src)
    if not InArena(src) then return false end
    if type(GetPlayerRoutingBucket) ~= 'function' then return true end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    return not ok or (tonumber(b) or 0) ~= 0
end

local function Notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, kind, key, vars) end
end

local function Dispatch(run, index, src, ev)
    index = tonumber(index)
    if not index or not (CP.Runs and CP.Runs.dispatch) then return false end
    local ok, res, why = pcall(CP.Runs.dispatch, run, index, src, ev)
    if not ok then
        CP.err(TAG, 'dispatch of %s to objective %s of run %s failed: %s', tostring(ev.type), tostring(index),
            tostring(run.id), tostring(res))
        return false
    end
    if res == false then
        CP.log(TAG, 'objective %s of run %s refused %s for %s: %s', index, run.id, ev.type, ev.netId, tostring(why))
    end
    return res ~= false
end

local function Uhash(h)
    h = math.tointeger(tonumber(h) or 0) or 0
    return h & 0xFFFFFFFF
end

-- ============================================================================
--                           PLAYERS BEHIND ENTITIES
-- ============================================================================

local function PlayerFromPed(ped)
    if not Exists(ped) then return nil end
    local t = Now()
    if t - playerMapAt >= PLAYER_MAP_MS then
        playerMap = {}
        for _, s in ipairs(GetPlayers()) do
            local n = tonumber(s)
            local pp = n and GetPlayerPed(n)
            if pp and pp ~= 0 then playerMap[pp] = n end
        end
        playerMapAt = t
    end
    return playerMap[ped]
end

-- The player who owns (simulates) an entity, or nil (server-owned, unknown).
local function OwnerOf(e)
    if type(NetworkGetEntityOwner) ~= 'function' then return nil end
    local ok, o = pcall(NetworkGetEntityOwner, e)
    o = ok and tonumber(o) or nil
    if o and o > 0 then return o end
    return nil
end

-- src|nil, kind: 'player' (the player's ped), 'vehicle' (the driver of a vehicle), 'npc', 'object'
local function AttackerOf(ent)
    if not Exists(ent) then return nil, nil end
    local t = GetEntityType(ent)
    if t == 2 then
        local driver = GetPedInVehicleSeat(ent, -1)
        local s = PlayerFromPed(driver)
        if s then return s, 'vehicle' end
        if Exists(driver) then return nil, 'npc' end
        return nil, 'object'
    elseif t == 1 then
        local s = PlayerFromPed(ent)
        if s then return s, 'player' end
        return nil, 'npc'
    end
    return nil, 'object'
end

-- ============================================================================
--                                 THE REGISTRY
-- ============================================================================
-- The server's truth; the replicated bag is only ever written.
-- rec = { netId, runId, entity, bag, obj, role, state, cuff, since, surrenderedAt, hp, gone, dead,
--         near = { [src] = ms in reach }, wdeAt, lastDamage = { src, at }, dmgAt = { [key] = ms } }
-- rec.bag is the value last written to Entity(e).state.cp (seeded from the engine's copy, info.bag);
-- state / cuff / obj / role mirror it.

-- The engine's own copy of the bag it wrote at spawn (run.entities[netId].bag), or one rebuilt from the
-- engine record (an engine without that copy): never the live bag.
local function SeedBag(run, info)
    if type(info) == 'table' and type(info.bag) == 'table' then
        local b = U.deepcopy(info.bag)
        b.run = run.id
        if not STATES[b.state] then b.state = 'idle' end
        return b
    end
    return {
        run = run.id,
        obj = info and info.obj,
        role = info and info.role,
        state = 'idle',
        armed = (info and info.armed) == true,
        cfg = {},
        tag = info and info.tag,
    }
end

local function Mirror(rec, bag)
    rec.bag = bag
    rec.state = bag.state or 'idle'
    rec.cuff = type(bag.cuff) == 'table' and bag.cuff or nil
    rec.obj = bag.obj
    rec.role = bag.role
end

local function NewRec(run, netId, info)
    local rec = { netId = netId, runId = run.id, near = {}, dmgAt = {}, gone = 0, entity = info.entity }
    Mirror(rec, SeedBag(run, info))
    if info.dead then rec.state = 'dead' end
    peds[netId] = rec
    return rec
end

-- The record of a ped of this run, or nil when the net id is not one of this run's entities (then no
-- record is made, and a record of another run is never replaced).
local function RecFor(run, netId, info)
    info = info or (type(run.entities) == 'table' and run.entities[netId]) or nil
    local rec = peds[netId]
    if rec and rec.runId == run.id and not (info and info.entity and rec.entity and info.entity ~= rec.entity) then
        rec.entity = rec.entity or (info and info.entity)
        return rec
    end
    if type(info) ~= 'table' then return nil end
    return NewRec(run, netId, info)
end

-- The entity of a run's ped (the handle the engine created), or nil. Never resolved through the pool:
-- another entity may carry that net id (or a client-written bag) by now.
local function EntityOf(run, netId, rec)
    if rec and Exists(rec.entity) then return rec.entity end
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if info and Exists(info.entity) then return info.entity end
    return nil
end

-- Write nb as the ped's bag and make it the server's truth (also the engine's copy, so a record made
-- again later starts from it).
local function Commit(run, netId, rec, e, nb)
    if not WriteBag(e, nb) then return false end
    Mirror(rec, nb)
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if type(info) == 'table' and info.entity == e then info.bag = nb end
    return true
end

-- The record for this net id: its own run's while that run is live, else the one of the live run that
-- lists the net id now (made on first use: a ped no setState has touched yet).
local function FindRec(netId)
    local rec = peds[netId]
    if rec and (rec.dead or IsLive(RunById(rec.runId))) then return rec end
    if not (CP.Runs and CP.Runs.all) then return rec end
    local ok, list = pcall(CP.Runs.all)
    if not ok or type(list) ~= 'table' then return nil end
    for _, run in pairs(list) do
        if IsLive(run) and type(run.entities) == 'table' and type(run.entities[netId]) == 'table' then
            return RecFor(run, netId, run.entities[netId])
        end
    end
    return rec          -- the last server state of a run that just ended (pruned on the next watcher tick)
end

local function IsPedRecord(netId, info)
    if info.kind == 'ped' then return true end
    if info.kind ~= nil then return false end
    if peds[netId] then return true end
    return Exists(info.entity) and GetEntityType(info.entity) == 1
end

-- ============================================================================
--                                    STATE
-- ============================================================================

function Npc.setState(run, netId, state, extra)
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if not IsLive(run) or not netId then
        CP.warn(TAG, 'setState(%s, %s) ignored: no live run or bad net id', tostring(type(run) == 'table' and run.id),
            tostring(netId))
        return false
    end
    if not STATES[state] then
        CP.warn(TAG, 'setState: unknown NPC state %s', tostring(state))
        return false
    end
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    local rec = RecFor(run, netId, info)
    if not rec then
        CP.warn(TAG, 'setState: net id %s is not an entity of run %s', netId, tostring(run.id))
        return false
    end
    local e = EntityOf(run, netId, rec)
    if not e then
        CP.log(TAG, 'setState %s -> %s: the entity does not exist', netId, state)
        return false
    end
    rec.entity = e
    local bag = rec.bag
    local changed = bag.state ~= state
    if not changed and type(extra) ~= 'table' then
        rec.state = state
        return true
    end
    local nb = U.copy(bag)
    nb.state = state
    nb.seq = (tonumber(bag.seq) or 0) + 1
    if changed then nb.task, nb.taskSeq = nil, nil end
    if type(extra) == 'table' then
        for k, v in pairs(extra) do
            if k == 'cfg' then
                if type(v) == 'table' then
                    local c = type(nb.cfg) == 'table' and U.copy(nb.cfg) or {}
                    for ck, cv in pairs(v) do c[ck] = U.serialize(cv) end
                    nb.cfg = c
                end
            elseif k == 'task' then
                -- taskSeq identifies this one-off task: later writes of the bag (a cfg merge,
                -- enableCuff) keep it, so the host never runs the same task twice
                if type(v) == 'table' then
                    nb.task, nb.taskSeq = U.serialize(v), nb.seq
                else
                    nb.task, nb.taskSeq = nil, nil
                end
            elseif not BAG_PROTECTED[k] then
                nb[k] = U.serialize(v)
            end
        end
    end
    if state == 'dead' then
        nb.cuff = nil
        nb.task, nb.taskSeq = nil, nil
    end
    if not Commit(run, netId, rec, e, nb) then return false end
    if changed then
        rec.since = Now()
        if state == 'surrendered' then rec.surrenderedAt = rec.since end
        rec.near = {}
    end
    CP.log(TAG, 'run %s ped %s: %s -> %s', tostring(run.id), netId, tostring(bag.state), state)
    return true
end

function Npc.getState(netId)
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if not netId then return nil end
    local rec = FindRec(netId)
    if not rec then return nil end
    if rec.dead then return 'dead' end
    return rec.state
end

function Npc.isNeutralised(netId)
    local s = Npc.getState(netId)
    return s == 'dead' or s == 'cuffed'
end

function Npc.rollSurrender(run, netId, chance)
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if type(run) ~= 'table' or run.id == nil or not netId then return false end
    local p = tonumber(chance) or 0
    if p ~= p then p = 0 end
    if p > 1 then p = p / 100 end
    p = U.clamp(p, 0, 1)
    local r = rolls[run.id]
    if not r then
        local seed = math.floor(tonumber(run.seed) or 1)
        r = { rng = U.rng((seed ~ RNG_SALT) & 0x7FFFFFFF), results = {} }
        rolls[run.id] = r
    end
    local res = r.results[netId]
    if res == nil then
        res = r.rng:chance(p)
        r.results[netId] = res
        CP.log(TAG, 'run %s ped %s surrender roll (%.2f): %s', tostring(run.id), netId, p, tostring(res))
    end
    return res
end

function Npc.enableCuff(run, netId, opts)
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if not IsLive(run) or not netId then return false end
    opts = type(opts) == 'table' and opts or {}
    local label = type(opts.label) == 'string' and U.trim(opts.label) or ''
    if label == '' then label = CP.L('npc.cuff') end
    local duration = tonumber(opts.duration) or DEFAULT_CUFF_MS
    if duration ~= duration then duration = DEFAULT_CUFF_MS end
    local range = tonumber(opts.maxDistance) or DEFAULT_CUFF_RANGE
    if range ~= range then range = DEFAULT_CUFF_RANGE end
    local cuff = {
        label = U.clip(label, MAX_LABEL),
        duration = math.floor(U.clamp(duration, CUFF_MS_RANGE[1], CUFF_MS_RANGE[2])),
        maxDistance = U.clamp(range + 0.0, CUFF_RANGE_RANGE[1], CUFF_RANGE_RANGE[2]),
    }
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    local rec = RecFor(run, netId, info)
    if not rec or rec.dead then return false end
    local e = EntityOf(run, netId, rec)
    if not e then return false end
    local nb = U.copy(rec.bag)
    nb.cuff = cuff
    nb.seq = (tonumber(nb.seq) or 0) + 1
    if not Commit(run, netId, rec, e, nb) then return false end
    rec.entity = e
    CP.log(TAG, 'run %s ped %s is cuffable (%s, %d ms, %.1f m)', tostring(run.id), netId, cuff.label, cuff.duration,
        cuff.maxDistance)
    return true
end

function Npc.onDeath(fn)
    if type(fn) == 'function' then deathFns[#deathFns + 1] = fn end
end

function Npc.onDamaged(fn)
    if type(fn) == 'function' then damageFns[#damageFns + 1] = fn end
end

-- ============================================================================
--                               SHOTS AND DAMAGE
-- ============================================================================

local function Shot(run, netId, rec, src, state)
    local t = Now()
    if state == 'surrendered' and rec.surrenderedAt and t - rec.surrenderedAt < SURRENDER_GRACE_MS then return false end
    local k = netId .. ':' .. src
    if shotAt[k] and t - shotAt[k] < SHOT_WINDOW_MS then return false end
    shotAt[k] = t
    if CP.Runs and CP.Runs.penalize then
        local ok, err = pcall(CP.Runs.penalize, run, 'shot_surrendered', { src = src })
        if not ok then CP.err(TAG, 'penalize shot_surrendered failed: %s', tostring(err)) end
    end
    Dispatch(run, rec.obj, src, { type = 'shot', netId = netId, src = src })
    local pts = Config.Scoring and Config.Scoring.common and tonumber(Config.Scoring.common.shotSurrendered) or 0
    Notify(src, 'warning', 'npc.shot_surrendered', { points = math.abs(pts) })
    CP.log(TAG, 'run %s: %s shot %s ped %s', tostring(run.id), src, tostring(state), netId)
    return true
end

local function Damaged(run, netId, rec, attacker)
    local t = Now()
    local key = tostring(attacker or 'npc')
    if rec.dmgAt[key] and t - rec.dmgAt[key] < DAMAGE_WINDOW_MS then return false end
    rec.dmgAt[key] = t
    if attacker and ActiveParticipant(run, attacker) then
        Dispatch(run, rec.obj, attacker, { type = 'damaged', netId = netId, attacker = attacker })
    end
    for _, fn in ipairs(damageFns) do
        local ok, err = pcall(fn, run, netId, attacker)
        if not ok then CP.err(TAG, 'onDamaged listener failed: %s', tostring(err)) end
    end
    return true
end

-- The player behind a weapon damage packet. A client only sends damage caused by entities it
-- controls, so parentGlobalId is trusted only as far as the sender could have sent it: an NPC
-- parent the sender owns (a hostile on the host shooting a hostage) is nobody; the sender's own ped
-- or vehicle is the sender; a parent naming another player's ped or a vehicle another player drives
-- is still the sender (a forged packet must never cost someone else a penalty or fail the run for
-- them), and so is an NPC the sender does not own. Returns src|nil, kind.
local function ShooterOf(src, data)
    local parent = ToInt(tonumber(data.parentGlobalId), 1, MAX_NETID)
    if parent then
        local pe = NetworkGetEntityFromNetworkId(parent)
        if Exists(pe) then
            local s, kind = AttackerOf(pe)
            if s then return src, kind end
            if kind == 'npc' and OwnerOf(pe) == src then return nil, 'npc' end
        end
    end
    return src, 'player'
end

-- Server-side proof that an active participant fired a weapon (no_weapons_fired): a gun hit on a mission
-- ped (weaponDamageEvent) or a gun kill. The client's own weapon_fired telemetry adds misses.
local function NoteFired(run, src)
    if not (CP.Runs and CP.Runs.noteWeaponFired) then return end
    local ok, err = pcall(CP.Runs.noteWeaponFired, run, src)
    if not ok then CP.err(TAG, 'noteWeaponFired failed: %s', tostring(err)) end
end

local function OnWeaponDamage(src, data, hits)
    if InArenaMatch(src) then return end
    local attacker, kind = ShooterOf(src, data)
    if attacker and attacker ~= src and InArenaMatch(attacker) then return end
    local isShot = not NOT_SHOTS[Uhash(data.weaponType)]
    local t = Now()
    local done, fired = {}, {}
    for i = 1, math.min(#hits, MAX_HITS) do
        local netId = ToInt(tonumber(hits[i]), 1, MAX_NETID)
        local rec = netId and peds[netId] or nil
        if rec and not rec.dead and not done[netId] then
            done[netId] = true
            local run = RunById(rec.runId)
            if IsLive(run) then
                local state = rec.state
                rec.wdeAt = t
                if attacker then rec.lastDamage = { src = attacker, at = t } end
                local gunHit = attacker ~= nil and isShot and kind == 'player'
                    and ActiveParticipant(run, attacker) ~= nil
                if gunHit and not fired[run.id] then
                    fired[run.id] = true
                    NoteFired(run, attacker)
                end
                if gunHit and PROTECTED[state] then
                    Shot(run, netId, rec, attacker, state)
                end
                if rec.role == 'hostage' then Damaged(run, netId, rec, attacker) end
            end
        end
    end
end

AddEventHandler('weaponDamageEvent', function(sender, data)
    local src = tonumber(sender) or tonumber(source)
    if WasEventCanceled() then return end
    if not src or type(data) ~= 'table' or next(peds) == nil then return end
    local hits = data.hitGlobalIds
    if type(hits) ~= 'table' then
        local one = tonumber(data.hitGlobalId)
        if not one then return end
        hits = { one }
    end
    if #hits == 0 then return end
    local ok, err = pcall(OnWeaponDamage, src, data, hits)
    if not ok then CP.err(TAG, 'weaponDamageEvent from %s failed: %s', tostring(src), tostring(err)) end
end)

-- A health/armour drop the weapon events did not report (the shooter owns the ped).
local function HealthDropped(run, netId, rec, e)
    local t = Now()
    if rec.wdeAt and t - rec.wdeAt < POLL_OVERLAP_MS then return end
    if type(GetPedSourceOfDamage) ~= 'function' then return end
    local srcEnt = GetPedSourceOfDamage(e)
    if not Exists(srcEnt) or srcEnt == e then return end
    local attacker, kind = AttackerOf(srcEnt)
    if attacker and kind == 'player' and OwnerOf(e) ~= attacker then
        -- A player who does not own the ped reaches it through weaponDamageEvent, which already
        -- handled that hit; GetPedSourceOfDamage keeps naming them after later damage with no source
        -- of its own (a fall, a fire), so this drop is nobody's shot.
        attacker, kind = nil, 'unknown'
    end
    if attacker and InArenaMatch(attacker) then return end
    local state = rec.state
    if attacker then rec.lastDamage = { src = attacker, at = t } end
    if attacker and kind == 'player' and PROTECTED[state] and ActiveParticipant(run, attacker) then
        Shot(run, netId, rec, attacker, state)
    end
    if rec.role == 'hostage' then Damaged(run, netId, rec, attacker) end
end

-- ============================================================================
--                                    DEATHS
-- ============================================================================
-- killerSrc|nil, how: 'player' (their own ped per GetPedSourceOfDeath), 'vehicle', 'memory' (last hit)
local function KillerOf(e, rec)
    local s, kind = AttackerOf(GetPedSourceOfDeath(e))
    if s then return s, kind end
    if kind == 'npc' then return nil end
    local ld = rec.lastDamage
    if ld and Now() - ld.at <= KILL_MEMORY_MS then return ld.src, 'memory' end
    return nil
end

-- The ped died of a gunshot (GetPedCauseOfDeath is a weapon that is not melee, a vehicle or a fall).
local function GunDeath(e)
    if not e or type(GetPedCauseOfDeath) ~= 'function' then return false end
    local ok, c = pcall(GetPedCauseOfDeath, e)
    c = ok and tonumber(c) or 0
    return c ~= 0 and not NOT_SHOTS[Uhash(c)]
end

local function Died(run, netId, rec, e)
    if rec.dead then return end
    rec.dead = true
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if info and info.dead then
        rec.state = 'dead'
        return
    end
    local killer, how
    if e then killer, how = KillerOf(e, rec) end
    if killer and InArenaMatch(killer) then killer = nil end
    local isPart = killer ~= nil and ActiveParticipant(run, killer) ~= nil
    local prev = rec.state
    -- A participant's gun kill is proof of gunfire; noted before entityDied, which can end the run.
    if isPart and how == 'player' and GunDeath(e) then NoteFired(run, killer) end
    -- Outside help first: entityDied runs the owning block's onEntityDead, which can complete the
    -- last objective (or fail the run) and end it on the spot. CP.AntiCheat.onNpcKilled ignores ended
    -- runs, so a flag raised after that would never reach the rows endRun writes.
    if killer and not isPart and CP.AntiCheat and CP.AntiCheat.onNpcKilled then
        local ok, err = pcall(CP.AntiCheat.onNpcKilled, run, killer)
        if not ok then CP.err(TAG, 'onNpcKilled failed: %s', tostring(err)) end
    end
    if CP.Runs and CP.Runs.entityDied then
        local ok, err = pcall(CP.Runs.entityDied, run, netId, killer)
        if not ok then CP.err(TAG, 'entityDied(%s, %s) failed: %s', tostring(run.id), netId, tostring(err)) end
    end
    if e and Exists(e) and rec.bag and rec.bag.state ~= 'dead' then
        local nb = U.copy(rec.bag)
        nb.state, nb.cuff, nb.task, nb.taskSeq = 'dead', nil, nil, nil
        nb.seq = (tonumber(rec.bag.seq) or 0) + 1
        Commit(run, netId, rec, e, nb)
    end
    rec.state = 'dead'
    rec.cuff = nil
    rec.near = {}
    for _, fn in ipairs(deathFns) do
        local ok, err = pcall(fn, run, netId, killer, isPart)
        if not ok then CP.err(TAG, 'onDeath listener failed: %s', tostring(err)) end
    end
    CP.log(TAG, 'run %s ped %s died (was %s, killer %s, participant %s)', tostring(run.id), netId, tostring(prev),
        tostring(killer), tostring(isPart))
end

-- ============================================================================
--                             CUFF REACH SAMPLING
-- ============================================================================

local function SampleReach(run, rec, e)
    if rec.state ~= 'surrendered' or type(rec.cuff) ~= 'table' then
        if next(rec.near) then rec.near = {} end
        return
    end
    local pc = GetEntityCoords(e)
    local reach = (tonumber(rec.cuff.maxDistance) or DEFAULT_CUFF_RANGE) + CUFF_REACH_SLACK_M
    local t = Now()
    for src, p in pairs(run.participants or {}) do
        local s = tonumber(src)
        if s and type(p) == 'table' and p.status == 'active' then
            local ped = GetPlayerPed(s)
            if Exists(ped) and U.dist(GetEntityCoords(ped), pc) <= reach then
                rec.near[s] = rec.near[s] or t
            else
                rec.near[s] = nil
            end
        elseif s then
            rec.near[s] = nil
        end
    end
end

-- ============================================================================
--                               THE 1 S WATCHER
-- ============================================================================
-- True when the server has real health data for the ped: a max health above 0 or a recorded cause of
-- death. When neither native answers, a 0 is trusted (the behaviour before this check existed).
local function HealthSynced(e)
    local known = false
    if type(GetEntityMaxHealth) == 'function' then
        local ok, m = pcall(GetEntityMaxHealth, e)
        if ok and tonumber(m) then
            known = true
            if tonumber(m) > 0 then return true end
        end
    end
    if type(GetPedCauseOfDeath) == 'function' then
        local ok, c = pcall(GetPedCauseOfDeath, e)
        if ok and tonumber(c) then
            known = true
            if tonumber(c) ~= 0 then return true end
        end
    end
    return not known
end

local function CheckPed(run, netId, info, rec)
    local e = EntityOf(run, netId, rec)
    if not e then
        rec.gone = (rec.gone or 0) + 1
        if rec.gone >= GONE_TICKS then Died(run, netId, rec, nil) end
        return
    end
    rec.gone = 0
    rec.entity = e
    local hp = GetEntityHealth(e) or 0
    if hp <= 0 then
        -- Server-side health is the owner's sync data (0 until a client created and synced a server-made
        -- entity, as modules/runs assumes): a 0 is a death once a positive health was seen, or when the
        -- health data is there (a max health or a cause of death).
        if rec.hpSeen or HealthSynced(e) then Died(run, netId, rec, e) end
        return
    end
    rec.hpSeen = true
    -- the server record is the truth (state, cuff, obj, role); a client-written bag is never read
    local total = hp + (GetPedArmour(e) or 0)
    if rec.hp and total < rec.hp - 0.5 and (PROTECTED[rec.state] or rec.role == 'hostage') then
        HealthDropped(run, netId, rec, e)
    end
    rec.hp = total
    SampleReach(run, rec, e)
end

local function Tick()
    if not (CP.Runs and CP.Runs.all) then return end
    local ok, list = pcall(CP.Runs.all)
    if not ok or type(list) ~= 'table' then return end
    local seen, live = {}, {}
    for _, run in pairs(list) do
        if IsLive(run) and type(run.entities) == 'table' then
            live[run.id] = true
            -- A death runs the owning block, which can end the run (every record removed) or start
            -- the next objective (new records, and a spawn that yields): never walk run.entities
            -- itself while that happens.
            local snapshot = {}
            for key, info in pairs(run.entities) do snapshot[#snapshot + 1] = { key, info } end
            for _, kv in ipairs(snapshot) do
                local key, info = kv[1], kv[2]
                local netId = ToInt(tonumber(key), 1, MAX_NETID)
                -- every entity of a live run keeps its record (a vehicle's state too); only peds are watched
                if netId and type(info) == 'table' then seen[netId] = run.id end
                if netId and type(info) == 'table' and IsPedRecord(netId, info) then
                    if info.dead then
                        -- the engine's own death (or ours): mark an existing record, never create one
                        local r = peds[netId]
                        if r and r.runId == run.id then
                            r.dead = true
                            r.state = 'dead'
                        end
                    elseif IsLive(run) and run.entities[key] == info then
                        local rec = RecFor(run, netId, info)
                        if not rec.dead then
                            local okc, err = pcall(CheckPed, run, netId, info, rec)
                            if not okc then
                                CP.err(TAG, 'check of ped %s in run %s failed: %s', netId, tostring(run.id),
                                    tostring(err))
                            end
                        end
                    end
                end
            end
        end
    end
    for netId, rec in pairs(peds) do
        if seen[netId] == nil or seen[netId] ~= rec.runId then peds[netId] = nil end
    end
    for runId in pairs(rolls) do
        if not live[runId] then rolls[runId] = nil end
    end
    local t = Now()
    for k, at in pairs(shotAt) do
        if t - at > 60000 then shotAt[k] = nil end
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local ok, err = pcall(Tick)
        if not ok then CP.err(TAG, 'watcher tick failed: %s', tostring(err)) end
    end
end)

-- ============================================================================
--                                "Cuff suspect"
-- ============================================================================

local function Refuse(src, key, why)
    CP.log(TAG, 'cuff by %s refused: %s', tostring(src), why or key)
    Notify(src, 'error', key)
    return false, key
end

local function HandleCuff(src, runId, netId)
    if type(runId) ~= 'string' or #runId == 0 or #runId > MAX_RUNID then
        return Refuse(src, 'err.npc_invalid', 'bad run id')
    end
    netId = ToInt(netId, 1, MAX_NETID)
    if not netId then return Refuse(src, 'err.npc_invalid', 'bad net id') end
    local run = RunById(runId)
    if not IsLive(run) then return Refuse(src, 'err.npc_not_on_run', 'no live run') end
    local p = ActiveParticipant(run, src)
    if not p then return Refuse(src, 'err.npc_not_on_run', 'not an active participant') end
    if run.state ~= 'in_progress' then return Refuse(src, 'err.npc_run_not_active', 'run not in progress') end
    if not p.arrived then return Refuse(src, 'err.npc_not_arrived', 'not arrived') end
    if InArena(src) then return Refuse(src, 'err.npc_in_arena', 'in arena') end
    if CP.Access and CP.Access.getOfficer then
        local ok, officer = pcall(CP.Access.getOfficer, src)
        if ok and not officer then return Refuse(src, 'err.npc_not_officer', 'not an officer') end
    end
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if type(info) ~= 'table' or info.dead or (info.kind ~= nil and info.kind ~= 'ped') then
        return Refuse(src, 'err.npc_unknown', 'not a ped of this run')
    end
    local rec = RecFor(run, netId, info)
    if not rec or rec.dead then return Refuse(src, 'err.npc_unknown', 'dead') end
    local e = EntityOf(run, netId, rec)
    if not e or (GetEntityHealth(e) or 0) <= 0 then return Refuse(src, 'err.npc_unknown', 'no entity') end
    -- the server record, never the replicated bag (a client could have written 'surrendered' and a cuff)
    local cuffCfg = rec.cuff
    if rec.state ~= 'surrendered' or type(cuffCfg) ~= 'table' then
        return Refuse(src, 'err.npc_not_surrendered', 'state ' .. tostring(rec.state))
    end
    local range = tonumber(cuffCfg.maxDistance) or DEFAULT_CUFF_RANGE
    local ped = GetPlayerPed(src)
    if not Exists(ped) or U.dist(GetEntityCoords(ped), GetEntityCoords(e)) > range + CUFF_SLACK_M then
        return Refuse(src, 'err.npc_too_far', 'too far')
    end
    local need = math.max(0, (tonumber(cuffCfg.duration) or DEFAULT_CUFF_MS) - CUFF_DWELL_SLACK_MS)
    local since = rec.near[src]
    if need > 0 and (not since or Now() - since < need) then
        return Refuse(src, 'err.npc_too_fast',
            ('in reach %s ms of %d'):format(since and tostring(Now() - since) or 'no', need))
    end
    if not Npc.setState(run, netId, 'cuffed') then return Refuse(src, 'err.npc_unknown', 'state write failed') end
    rec.near = {}
    Dispatch(run, rec.obj, src, { type = 'cuffed', netId = netId })
    CP.log(TAG, 'run %s: %s cuffed ped %s', tostring(run.id), src, netId)
    return true
end

RegisterNetEvent(CUFF_EVENT, function(runId, netId)
    local src = source
    if not CP.Net.rateOk(src, CUFF_EVENT, 3, 2000) then
        CP.log(TAG, 'cuff from %s rate limited', tostring(src))
        return
    end
    local ok, err = pcall(HandleCuff, src, runId, netId)
    if not ok then CP.err(TAG, 'npcCuff from %s failed: %s', tostring(src), tostring(err)) end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    for _, rec in pairs(peds) do rec.near[src] = nil end
    local suffix = ':' .. src
    for k in pairs(shotAt) do
        if k:sub(-#suffix) == suffix then shotAt[k] = nil end
    end
    playerMapAt = -math.huge
end)
