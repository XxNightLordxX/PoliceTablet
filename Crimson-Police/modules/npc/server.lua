--[[ modules/npc/server.lua · CP.Npc (server): the authoritative state machine of mission NPCs.

  What this module owns (docs/ARCHITECTURE.md §5.11, §6.1, §6.2)
    - The state, cuff, task and seq fields of every mission ped's replicated cp entity state
      bag (Entity(e).state.cp = { run, obj, role, state, armed, cfg, tag, ... }). The engine
      (CP.Runs.spawnPed) writes the bag first; afterwards only this module changes state.
    - "Cuff suspect": blocks call enableCuff; participants' clients (modules/npc/client.lua) show one
      global ox_target option and report the finished progress bar with the plain net event
      crimson-police:server:npcCuff (runId, netId). The server validates it (active, arrived
      participant of that run, on duty, not in the arena, the ped belongs to the run and is
      surrendered and cuffable, server-side distance <= maxDistance + 0.5 m, and the officer has been
      within reach for most of the cuff duration), sets cuffed and delivers
      { type = 'cuffed', netId } to the owning objective (CP.Runs.dispatch with cp.obj).
    - The death watcher: every 1 s over every live mission ped of every run. Health <= 0, or an entity
      that no longer exists (a ped the engine deleted on purpose is no longer in run.entities), is a
      death. (The engine leaves ped health deaths to this module because CP.Npc.onDeath exists.) The killer is GetPedSourceOfDeath resolved to a
      player (the player's own ped, or the driver of the killing vehicle); when the engine names nobody,
      the last weapon hit by a player in the last 5 s. Then, exactly once per ped:
      CP.Runs.entityDied(run, netId, killerSrc), CP.AntiCheat.onNpcKilled(run, killerSrc) for a killer
      who is not an active participant, the bag state 'dead', and the onDeath listeners.
      Whether a death fails the mission (a surrendered, cuffed, restrained or unarmed ped killed by a
      participant, run.fail_killed_unarmed) is decided by the owning block's onEntityDead, which keeps
      its own "shot already in flight" grace.
    - The weaponDamageEvent listener (returns at once when WasEventCanceled(); never cancels):
      a participant shooting a surrendered (after SURRENDER_GRACE_MS), cuffed or restrained ped ->
      CP.Runs.penalize(run, 'shot_surrendered', { src }) and { type = 'shot', netId, src } to the owning
      block; any damage to a ped whose role is 'hostage' -> the onDamaged listeners, plus
      { type = 'damaged', netId, attacker } to the owning block when the attacker is a participant.
      The attacker is the entity named by parentGlobalId when it resolves (an NPC owned by the sender is
      not the sender), otherwise the sender.
    - A 1 s health poll for the case weaponDamageEvent never covers: a client damaging a ped it owns
      itself (the run host usually owns every mission ped). A health+armour drop with no weapon event
      in the last 2 s is attributed with GetPedSourceOfDamage (players only, never "no source").

  Public API
    CP.Npc.setState(run, netId, state, extra) -> boolean
        state: 'idle'|'hostile'|'fleeing'|'surrendered'|'cuffed'|'dead'|'restrained'|'freed'|'safe'|
               'driving'|'stopped'. extra (optional table) is merged into the bag: cfg merges into
               bag.cfg, task = { action, args } is a one-off client task for the run host
               (CP.Npc.task), any other key is copied (run, obj, state and seq are protected).
               A state change drops the previous task. Setting the same state with no extra is a no-op.
    CP.Npc.getState(netId) -> state|nil
    CP.Npc.isNeutralised(netId) -> boolean                 dead or cuffed
    CP.Npc.rollSurrender(run, netId, chance) -> boolean    one roll per ped with the run's NPC rng
                                                           (CP.U.rng(run.seed ~ salt)); repeated calls
                                                           for the same ped return the first result;
                                                           chance is a fraction (a value > 1 is read as
                                                           a percentage)
    CP.Npc.enableCuff(run, netId, opts) -> boolean         opts = { label, duration = 5000, maxDistance = 3.0 }
                                                           writes bag.cuff = { label, duration, maxDistance }
    CP.Npc.onDeath(fn(run, netId, killerSrc|nil, killerIsParticipant))
    CP.Npc.onDamaged(fn(run, netId, attackerSrc|nil))     damage to peds whose role is 'hostage'
                                                           (attackerSrc nil = an NPC)

  Events and handlers
    RegisterNetEvent crimson-police:server:npcCuff (runId, netId)      rate limited 3 per 2 s
    AddEventHandler weaponDamageEvent (sender, data)
    AddEventHandler playerDropped
  Player-facing text (toasts through CP.Tablet.notify): npc.shot_surrendered, err.npc_* (npc.json).
  No database queries.
]]

CP.Npc = CP.Npc or {}
local Npc = CP.Npc
local U = CP.U
local TAG = 'npc'

local CUFF_EVENT = 'crimson-police:server:npcCuff'

local STATES = {
    idle = true, hostile = true, fleeing = true, surrendered = true, cuffed = true, dead = true,
    restrained = true, freed = true, safe = true, driving = true, stopped = true,
}
-- Shooting a ped in one of these states costs shot_surrendered.
local PROTECTED = { surrendered = true, cuffed = true, restrained = true }
local BAG_PROTECTED = { run = true, obj = true, state = true, seq = true }

local TICK_MS             = 1000   -- death watcher / health poll / cuff reach sampling
local GONE_TICKS          = 1      -- checks without the entity before it counts as dead (before the engine's
                                   -- own 2-check vanish rule, so onDeath listeners see those deaths too)
local SURRENDER_GRACE_MS  = 3000   -- a hit this soon after a surrender is a shot already in flight
local SHOT_WINDOW_MS      = 2000   -- one shot_surrendered per shooter and ped in this window
local DAMAGE_WINDOW_MS    = 1000   -- one damage report per ped and attacker in this window
local POLL_OVERLAP_MS     = 2000   -- a health drop this soon after a weapon event is that event
local KILL_MEMORY_MS      = 5000   -- fallback killer: the last player hit this recent
local PLAYER_MAP_MS       = 250    -- ped -> player map cache
local CUFF_SLACK_M        = 0.5    -- the cuff itself: maxDistance + this
local CUFF_REACH_SLACK_M  = 1.5    -- reach sampling while the progress bar runs
local CUFF_DWELL_SLACK_MS = 2000   -- the officer must have been in reach for duration - this
local DEFAULT_CUFF_MS     = 5000
local DEFAULT_CUFF_RANGE  = 3.0
local CUFF_MS_RANGE       = { 500, 60000 }
local CUFF_RANGE_RANGE    = { 1.0, 10.0 }
local MAX_LABEL           = 64
local MAX_HITS            = 32
local MAX_NETID           = 0xFFFFFF
local MAX_RUNID           = 64
local RNG_SALT            = 0x4E504331   -- 'NPC1'

-- Weapons that do not count as "shooting" a surrendered NPC (melee, vehicles, falls).
local NOT_SHOTS = {}
for _, name in ipairs({
    'WEAPON_UNARMED', 'WEAPON_NIGHTSTICK', 'WEAPON_FLASHLIGHT', 'WEAPON_KNUCKLE', 'WEAPON_KNIFE',
    'WEAPON_BAT', 'WEAPON_HAMMER', 'WEAPON_CROWBAR', 'WEAPON_GOLFCLUB', 'WEAPON_BOTTLE', 'WEAPON_DAGGER',
    'WEAPON_HATCHET', 'WEAPON_MACHETE', 'WEAPON_SWITCHBLADE', 'WEAPON_WRENCH', 'WEAPON_BATTLEAXE',
    'WEAPON_POOLCUE', 'WEAPON_STONE_HATCHET', 'WEAPON_RUN_OVER_BY_CAR', 'WEAPON_RAMMED_BY_CAR', 'WEAPON_FALL',
}) do
    NOT_SHOTS[(math.tointeger(joaat(name)) or 0) & 0xFFFFFFFF] = true
end

local peds = {}          -- [netId] = rec (see recFor)
local rolls = {}         -- [runId] = { rng, results = { [netId] = boolean } }
local shotAt = {}        -- ['netId:src'] = ms of the last counted shot_surrendered
local deathFns, damageFns = {}, {}
local playerMap, playerMapAt = {}, -math.huge

-- ── Small helpers ───────────────────────────────────────────────────────────
local function now() return GetGameTimer() end

local function toInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    local n = math.tointeger(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function exists(e)
    return type(e) == 'number' and e ~= 0 and DoesEntityExist(e) == true
end

local function readBag(e)
    local ok, v = pcall(function() return Entity(e).state.cp end)
    if ok and type(v) == 'table' then return v end
    return nil
end

local function writeBag(e, bag)
    local ok, err = pcall(function() Entity(e).state:set('cp', bag, true) end)
    if not ok then CP.warn(TAG, 'could not write the cp state bag of entity %s: %s', tostring(e), tostring(err)) end
    return ok
end

local function runById(id)
    if id == nil or not (CP.Runs and CP.Runs.get) then return nil end
    local ok, run = pcall(CP.Runs.get, id)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function isLive(run)
    return type(run) == 'table' and run.id ~= nil and run.state ~= 'ended'
end

-- The participant table of an ACTIVE participant (the run table's own data, ARCHITECTURE §4.2).
local function activeParticipant(run, src)
    src = tonumber(src)
    if not src or type(run) ~= 'table' or type(run.participants) ~= 'table' then return nil end
    local p = run.participants[src]
    if type(p) == 'table' and p.status == 'active' then return p end
    return nil
end

local function inArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, res = pcall(CP.Alerts.inArena, src)
    return ok and res == true
end

local function notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, kind, key, vars) end
end

local function dispatch(run, index, src, ev)
    index = tonumber(index)
    if not index or not (CP.Runs and CP.Runs.dispatch) then return false end
    local ok, res, why = pcall(CP.Runs.dispatch, run, index, src, ev)
    if not ok then
        CP.err(TAG, 'dispatch of %s to objective %s of run %s failed: %s', tostring(ev.type), tostring(index), tostring(run.id), tostring(res))
        return false
    end
    if res == false then CP.log(TAG, 'objective %s of run %s refused %s for %s: %s', index, run.id, ev.type, ev.netId, tostring(why)) end
    return res ~= false
end

local function uhash(h)
    h = math.tointeger(tonumber(h) or 0) or 0
    return h & 0xFFFFFFFF
end

-- ── Players behind entities ─────────────────────────────────────────────────
local function playerFromPed(ped)
    if not exists(ped) then return nil end
    local t = now()
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

-- src|nil, kind: 'player' (the player's ped), 'vehicle' (the driver of a vehicle), 'npc', 'object'
local function attackerOf(ent)
    if not exists(ent) then return nil, nil end
    local t = GetEntityType(ent)
    if t == 2 then
        local driver = GetPedInVehicleSeat(ent, -1)
        local s = playerFromPed(driver)
        if s then return s, 'vehicle' end
        if exists(driver) then return nil, 'npc' end
        return nil, 'object'
    elseif t == 1 then
        local s = playerFromPed(ent)
        if s then return s, 'player' end
        return nil, 'npc'
    end
    return nil, 'object'
end

-- ── The ped registry ────────────────────────────────────────────────────────
-- rec = { netId, runId, entity, obj, role, state, since, surrenderedAt, cuff, hp, gone, dead,
--         near = { [src] = ms in reach }, wdeAt, lastDamage = { src, at }, dmgAt = { [key] = ms } }
local function newRec(run, netId)
    local rec = { netId = netId, runId = run.id, near = {}, dmgAt = {}, gone = 0 }
    peds[netId] = rec
    return rec
end

local function recFor(run, netId, info)
    local rec = peds[netId]
    if rec and rec.runId ~= run.id then rec = nil end
    info = info or (type(run.entities) == 'table' and run.entities[netId]) or nil
    if rec and info and info.entity and rec.entity and info.entity ~= rec.entity then rec = nil end
    if not rec then rec = newRec(run, netId) end
    if type(info) == 'table' then
        rec.entity = rec.entity or info.entity
        if info.obj ~= nil then rec.obj = info.obj end
        if info.role ~= nil then rec.role = info.role end
    end
    return rec
end

-- The entity of a run's ped, or nil. A net id resolved from the pool must carry this run's bag.
local function entityOf(run, netId, rec)
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if rec and exists(rec.entity) then return rec.entity end
    if info and exists(info.entity) then return info.entity end
    local e = NetworkGetEntityFromNetworkId(netId)
    if exists(e) then
        local bag = readBag(e)
        if bag and bag.run == run.id then return e end
    end
    return nil
end

local function currentState(rec, e)
    local bag = e and readBag(e) or nil
    if bag and bag.state then
        rec.state = bag.state
        if type(bag.cuff) == 'table' then rec.cuff = bag.cuff end
        if bag.obj ~= nil then rec.obj = bag.obj end
        if bag.role ~= nil then rec.role = bag.role end
    end
    return rec.state
end

local function isPedRecord(netId, info)
    if info.kind == 'ped' then return true end
    if info.kind ~= nil then return false end
    if peds[netId] then return true end
    return exists(info.entity) and GetEntityType(info.entity) == 1
end

-- ── State ───────────────────────────────────────────────────────────────────
function Npc.setState(run, netId, state, extra)
    netId = toInt(tonumber(netId), 1, MAX_NETID)
    if not isLive(run) or not netId then
        CP.warn(TAG, 'setState(%s, %s) ignored: no live run or bad net id', tostring(type(run) == 'table' and run.id), tostring(netId))
        return false
    end
    if not STATES[state] then
        CP.warn(TAG, 'setState: unknown NPC state %s', tostring(state))
        return false
    end
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    local rec = recFor(run, netId, info)
    local e = entityOf(run, netId, rec)
    if not e then
        CP.log(TAG, 'setState %s -> %s: the entity does not exist', netId, state)
        return false
    end
    rec.entity = e
    local bag = readBag(e)
    if bag and bag.run ~= nil and bag.run ~= run.id then
        CP.warn(TAG, 'setState: net id %s belongs to run %s, not %s', netId, tostring(bag.run), tostring(run.id))
        return false
    end
    if not bag then
        bag = {
            run = run.id, obj = info and info.obj or rec.obj, role = info and info.role or rec.role,
            armed = (info and info.armed) == true, cfg = {}, tag = info and info.tag,
        }
    end
    local changed = bag.state ~= state
    if not changed and type(extra) ~= 'table' then
        rec.state = state
        return true
    end
    local nb = U.copy(bag)
    nb.state = state
    nb.seq = (tonumber(bag.seq) or 0) + 1
    if changed then nb.task = nil end
    if type(extra) == 'table' then
        for k, v in pairs(extra) do
            if k == 'cfg' then
                if type(v) == 'table' then
                    local c = type(nb.cfg) == 'table' and U.copy(nb.cfg) or {}
                    for ck, cv in pairs(v) do c[ck] = U.serialize(cv) end
                    nb.cfg = c
                end
            elseif k == 'task' then
                nb.task = type(v) == 'table' and U.serialize(v) or nil
            elseif not BAG_PROTECTED[k] then
                nb[k] = U.serialize(v)
            end
        end
    end
    if state == 'dead' then
        nb.cuff = nil
        nb.task = nil
    end
    if not writeBag(e, nb) then return false end
    if changed then
        rec.since = now()
        if state == 'surrendered' then rec.surrenderedAt = rec.since end
        rec.near = {}
    end
    rec.state = state
    rec.obj = nb.obj
    rec.role = nb.role
    if type(nb.cuff) == 'table' then rec.cuff = nb.cuff end
    CP.log(TAG, 'run %s ped %s: %s -> %s', tostring(run.id), netId, tostring(bag.state), state)
    return true
end

function Npc.getState(netId)
    netId = toInt(tonumber(netId), 1, MAX_NETID)
    if not netId then return nil end
    local rec = peds[netId]
    local e = rec and exists(rec.entity) and rec.entity or nil
    if not e and not rec then
        local n = NetworkGetEntityFromNetworkId(netId)
        if exists(n) then e = n end
    end
    if e then
        local bag = readBag(e)
        if bag and bag.state then
            if rec then rec.state = bag.state end
            return bag.state
        end
    end
    if rec then
        if rec.dead then return 'dead' end
        return rec.state
    end
    return nil
end

function Npc.isNeutralised(netId)
    local s = Npc.getState(netId)
    return s == 'dead' or s == 'cuffed'
end

function Npc.rollSurrender(run, netId, chance)
    netId = toInt(tonumber(netId), 1, MAX_NETID)
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
    netId = toInt(tonumber(netId), 1, MAX_NETID)
    if not isLive(run) or not netId then return false end
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
    local rec = recFor(run, netId, info)
    local e = entityOf(run, netId, rec)
    if not e then return false end
    local bag = readBag(e)
    if bag and bag.run ~= nil and bag.run ~= run.id then return false end
    local nb = bag and U.copy(bag) or {
        run = run.id, obj = info and info.obj or rec.obj, role = info and info.role or rec.role,
        state = rec.state or 'idle', armed = (info and info.armed) == true, cfg = {}, tag = info and info.tag,
    }
    nb.cuff = cuff
    nb.seq = (tonumber(nb.seq) or 0) + 1
    if not writeBag(e, nb) then return false end
    rec.entity = e
    rec.cuff = cuff
    CP.log(TAG, 'run %s ped %s is cuffable (%s, %d ms, %.1f m)', tostring(run.id), netId, cuff.label, cuff.duration, cuff.maxDistance)
    return true
end

function Npc.onDeath(fn)
    if type(fn) == 'function' then deathFns[#deathFns + 1] = fn end
end

function Npc.onDamaged(fn)
    if type(fn) == 'function' then damageFns[#damageFns + 1] = fn end
end

-- ── Shots and damage ────────────────────────────────────────────────────────
local function shot(run, netId, rec, src, state)
    local t = now()
    if state == 'surrendered' and rec.surrenderedAt and t - rec.surrenderedAt < SURRENDER_GRACE_MS then return false end
    local k = netId .. ':' .. src
    if shotAt[k] and t - shotAt[k] < SHOT_WINDOW_MS then return false end
    shotAt[k] = t
    if CP.Runs and CP.Runs.penalize then
        local ok, err = pcall(CP.Runs.penalize, run, 'shot_surrendered', { src = src })
        if not ok then CP.err(TAG, 'penalize shot_surrendered failed: %s', tostring(err)) end
    end
    dispatch(run, rec.obj, src, { type = 'shot', netId = netId, src = src })
    local pts = Config.Scoring and Config.Scoring.common and tonumber(Config.Scoring.common.shotSurrendered) or 0
    notify(src, 'warning', 'npc.shot_surrendered', { points = math.abs(pts) })
    CP.log(TAG, 'run %s: %s shot %s ped %s', tostring(run.id), src, tostring(state), netId)
    return true
end

local function damaged(run, netId, rec, attacker)
    local t = now()
    local key = tostring(attacker or 'npc')
    if rec.dmgAt[key] and t - rec.dmgAt[key] < DAMAGE_WINDOW_MS then return false end
    rec.dmgAt[key] = t
    if attacker and activeParticipant(run, attacker) then
        dispatch(run, rec.obj, attacker, { type = 'damaged', netId = netId, attacker = attacker })
    end
    for _, fn in ipairs(damageFns) do
        local ok, err = pcall(fn, run, netId, attacker)
        if not ok then CP.err(TAG, 'onDamaged listener failed: %s', tostring(err)) end
    end
    return true
end

-- The player behind a weapon damage packet: the parent entity when it resolves (an NPC owned by
-- the sender is not the sender), otherwise the sender. Returns src|nil, kind.
local function shooterOf(src, data)
    local parent = toInt(tonumber(data.parentGlobalId), 1, MAX_NETID)
    if parent then
        local pe = NetworkGetEntityFromNetworkId(parent)
        if exists(pe) then
            local s, kind = attackerOf(pe)
            if s then return s, kind end
            if kind == 'npc' then return nil, 'npc' end
        end
    end
    return src, 'player'
end

local function onWeaponDamage(src, data, hits)
    if inArena(src) then return end
    local attacker, kind = shooterOf(src, data)
    if attacker and attacker ~= src and inArena(attacker) then return end
    local isShot = not NOT_SHOTS[uhash(data.weaponType)]
    local t = now()
    local done = {}
    for i = 1, math.min(#hits, MAX_HITS) do
        local netId = toInt(tonumber(hits[i]), 1, MAX_NETID)
        local rec = netId and peds[netId] or nil
        if rec and not rec.dead and not done[netId] then
            done[netId] = true
            local run = runById(rec.runId)
            if isLive(run) then
                local e = exists(rec.entity) and rec.entity or nil
                local state = currentState(rec, e)
                rec.wdeAt = t
                if attacker then rec.lastDamage = { src = attacker, at = t } end
                if attacker and isShot and kind == 'player' and PROTECTED[state] and activeParticipant(run, attacker) then
                    shot(run, netId, rec, attacker, state)
                end
                if rec.role == 'hostage' then damaged(run, netId, rec, attacker) end
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
    local ok, err = pcall(onWeaponDamage, src, data, hits)
    if not ok then CP.err(TAG, 'weaponDamageEvent from %s failed: %s', tostring(src), tostring(err)) end
end)

-- A health/armour drop the weapon events did not report (the shooter owns the ped).
local function healthDropped(run, netId, rec, e)
    local t = now()
    if rec.wdeAt and t - rec.wdeAt < POLL_OVERLAP_MS then return end
    if type(GetPedSourceOfDamage) ~= 'function' then return end
    local srcEnt = GetPedSourceOfDamage(e)
    if not exists(srcEnt) or srcEnt == e then return end
    local attacker, kind = attackerOf(srcEnt)
    if attacker and inArena(attacker) then return end
    local state = currentState(rec, e)
    if attacker then rec.lastDamage = { src = attacker, at = t } end
    if attacker and kind == 'player' and PROTECTED[state] and activeParticipant(run, attacker) then
        shot(run, netId, rec, attacker, state)
    end
    if rec.role == 'hostage' then damaged(run, netId, rec, attacker) end
end

-- ── Deaths ──────────────────────────────────────────────────────────────────
local function killerOf(e, rec)
    local s, kind = attackerOf(GetPedSourceOfDeath(e))
    if s then return s end
    if kind == 'npc' then return nil end
    local ld = rec.lastDamage
    if ld and now() - ld.at <= KILL_MEMORY_MS then return ld.src end
    return nil
end

local function died(run, netId, rec, e)
    if rec.dead then return end
    rec.dead = true
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if info and info.dead then
        rec.state = 'dead'
        return
    end
    local killer = e and killerOf(e, rec) or nil
    if killer and inArena(killer) then killer = nil end
    local isPart = killer ~= nil and activeParticipant(run, killer) ~= nil
    local prev = rec.state
    if CP.Runs and CP.Runs.entityDied then
        local ok, err = pcall(CP.Runs.entityDied, run, netId, killer)
        if not ok then CP.err(TAG, 'entityDied(%s, %s) failed: %s', tostring(run.id), netId, tostring(err)) end
    end
    if killer and not isPart and CP.AntiCheat and CP.AntiCheat.onNpcKilled then
        local ok, err = pcall(CP.AntiCheat.onNpcKilled, run, killer)
        if not ok then CP.err(TAG, 'onNpcKilled failed: %s', tostring(err)) end
    end
    if e and exists(e) then
        local bag = readBag(e)
        if bag and bag.state ~= 'dead' then
            local nb = U.copy(bag)
            nb.state, nb.cuff, nb.task = 'dead', nil, nil
            nb.seq = (tonumber(bag.seq) or 0) + 1
            writeBag(e, nb)
        end
    end
    rec.state = 'dead'
    rec.near = {}
    for _, fn in ipairs(deathFns) do
        local ok, err = pcall(fn, run, netId, killer, isPart)
        if not ok then CP.err(TAG, 'onDeath listener failed: %s', tostring(err)) end
    end
    CP.log(TAG, 'run %s ped %s died (was %s, killer %s, participant %s)', tostring(run.id), netId, tostring(prev), tostring(killer), tostring(isPart))
end

-- ── Cuff reach sampling ─────────────────────────────────────────────────────
local function sampleReach(run, rec, e)
    if rec.state ~= 'surrendered' or type(rec.cuff) ~= 'table' then
        if next(rec.near) then rec.near = {} end
        return
    end
    local pc = GetEntityCoords(e)
    local reach = (tonumber(rec.cuff.maxDistance) or DEFAULT_CUFF_RANGE) + CUFF_REACH_SLACK_M
    local t = now()
    for src, p in pairs(run.participants or {}) do
        local s = tonumber(src)
        if s and type(p) == 'table' and p.status == 'active' then
            local ped = GetPlayerPed(s)
            if exists(ped) and U.dist(GetEntityCoords(ped), pc) <= reach then
                rec.near[s] = rec.near[s] or t
            else
                rec.near[s] = nil
            end
        elseif s then
            rec.near[s] = nil
        end
    end
end

-- ── The 1 s watcher ─────────────────────────────────────────────────────────
local function checkPed(run, netId, info, rec)
    local e = entityOf(run, netId, rec)
    if not e then
        rec.gone = (rec.gone or 0) + 1
        if rec.gone >= GONE_TICKS then died(run, netId, rec, nil) end
        return
    end
    rec.gone = 0
    rec.entity = e
    local hp = GetEntityHealth(e) or 0
    if hp <= 0 then
        died(run, netId, rec, e)
        return
    end
    local total = hp + (GetPedArmour(e) or 0)
    if rec.hp and total < rec.hp - 0.5 and (PROTECTED[rec.state] or rec.role == 'hostage') then
        healthDropped(run, netId, rec, e)
    end
    rec.hp = total
    if rec.state == 'surrendered' then currentState(rec, e) end
    sampleReach(run, rec, e)
end

local function tick()
    if not (CP.Runs and CP.Runs.all) then return end
    local ok, list = pcall(CP.Runs.all)
    if not ok or type(list) ~= 'table' then return end
    local seen, live = {}, {}
    for _, run in pairs(list) do
        if isLive(run) and type(run.entities) == 'table' then
            live[run.id] = true
            for key, info in pairs(run.entities) do
                local netId = toInt(tonumber(key), 1, MAX_NETID)
                if netId and type(info) == 'table' and isPedRecord(netId, info) then
                    seen[netId] = true
                    local rec = recFor(run, netId, info)
                    if not info.dead and not rec.dead then
                        local okc, err = pcall(checkPed, run, netId, info, rec)
                        if not okc then CP.err(TAG, 'check of ped %s in run %s failed: %s', netId, tostring(run.id), tostring(err)) end
                    elseif info.dead then
                        rec.dead = true
                        rec.state = 'dead'
                    end
                end
            end
        end
    end
    for netId in pairs(peds) do
        if not seen[netId] then peds[netId] = nil end
    end
    for runId in pairs(rolls) do
        if not live[runId] then rolls[runId] = nil end
    end
    local t = now()
    for k, at in pairs(shotAt) do
        if t - at > 60000 then shotAt[k] = nil end
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local ok, err = pcall(tick)
        if not ok then CP.err(TAG, 'watcher tick failed: %s', tostring(err)) end
    end
end)

-- ── "Cuff suspect" ──────────────────────────────────────────────────────────
local function refuse(src, key, why)
    CP.log(TAG, 'cuff by %s refused: %s', tostring(src), why or key)
    notify(src, 'error', key)
    return false, key
end

local function handleCuff(src, runId, netId)
    if type(runId) ~= 'string' or #runId == 0 or #runId > MAX_RUNID then return refuse(src, 'err.npc_invalid', 'bad run id') end
    netId = toInt(netId, 1, MAX_NETID)
    if not netId then return refuse(src, 'err.npc_invalid', 'bad net id') end
    local run = runById(runId)
    if not isLive(run) then return refuse(src, 'err.npc_not_on_run', 'no live run') end
    local p = activeParticipant(run, src)
    if not p then return refuse(src, 'err.npc_not_on_run', 'not an active participant') end
    if run.state ~= 'in_progress' then return refuse(src, 'err.npc_run_not_active', 'run not in progress') end
    if not p.arrived then return refuse(src, 'err.npc_not_arrived', 'not arrived') end
    if inArena(src) then return refuse(src, 'err.npc_in_arena', 'in arena') end
    if CP.Access and CP.Access.getOfficer then
        local ok, officer = pcall(CP.Access.getOfficer, src)
        if ok and not officer then return refuse(src, 'err.npc_not_officer', 'not an officer') end
    end
    local info = type(run.entities) == 'table' and run.entities[netId] or nil
    if type(info) ~= 'table' or info.dead or (info.kind ~= nil and info.kind ~= 'ped') then
        return refuse(src, 'err.npc_unknown', 'not a ped of this run')
    end
    local rec = recFor(run, netId, info)
    if rec.dead then return refuse(src, 'err.npc_unknown', 'dead') end
    local e = entityOf(run, netId, rec)
    if not e or (GetEntityHealth(e) or 0) <= 0 then return refuse(src, 'err.npc_unknown', 'no entity') end
    local bag = readBag(e)
    if not bag or bag.run ~= run.id then return refuse(src, 'err.npc_unknown', 'foreign bag') end
    if bag.state ~= 'surrendered' or type(bag.cuff) ~= 'table' then
        return refuse(src, 'err.npc_not_surrendered', 'state ' .. tostring(bag.state))
    end
    local range = tonumber(bag.cuff.maxDistance) or DEFAULT_CUFF_RANGE
    local ped = GetPlayerPed(src)
    if not exists(ped) or U.dist(GetEntityCoords(ped), GetEntityCoords(e)) > range + CUFF_SLACK_M then
        return refuse(src, 'err.npc_too_far', 'too far')
    end
    local need = math.max(0, (tonumber(bag.cuff.duration) or DEFAULT_CUFF_MS) - CUFF_DWELL_SLACK_MS)
    local since = rec.near[src]
    if need > 0 and (not since or now() - since < need) then
        return refuse(src, 'err.npc_too_fast', ('in reach %s ms of %d'):format(since and tostring(now() - since) or 'no', need))
    end
    if not Npc.setState(run, netId, 'cuffed') then return refuse(src, 'err.npc_unknown', 'state write failed') end
    rec.near = {}
    dispatch(run, bag.obj or rec.obj, src, { type = 'cuffed', netId = netId })
    CP.log(TAG, 'run %s: %s cuffed ped %s', tostring(run.id), src, netId)
    return true
end

RegisterNetEvent(CUFF_EVENT, function(runId, netId)
    local src = source
    if not CP.Net.rateOk(src, CUFF_EVENT, 3, 2000) then
        CP.log(TAG, 'cuff from %s rate limited', tostring(src))
        return
    end
    local ok, err = pcall(handleCuff, src, runId, netId)
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
