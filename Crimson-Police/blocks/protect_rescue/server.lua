-- Objective block "protect_rescue" (server half)

local BLOCK = 'protect_rescue'
local U = CP.U

local REACH_SLACK = 2.0        -- metres of position lag allowed around interaction ranges
local TARGET_RANGE = 2.0       -- default ox_target distance for "Cut restraints"
local FREE_SHARE = 0.8         -- 'freed' must arrive at least this share of freeTime after 'free_start'
local HIT_WINDOW_MS = 1000     -- one counted hit per hostage and attacker in this window
local REUSE_OFFSET = 1.0       -- metres between hostages sharing a spot
local SAFE_RADIUS = 6.0
local DEFAULT_ICON = 'fas fa-scissors'
local RETRY_MS = 1000          -- run-start spawns waiting for room retry this often

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function InRange(v, r, scale)
    scale = scale or 1
    return IsNum(v) and type(r) == 'table' and v >= r[1] * scale - 1e-9 and v <= r[2] * scale + 1e-9
end

local function Bad(key, vars)
    return false, CP.L(key, vars)
end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return IsNum(x) and IsNum(y) and IsNum(z)
end

local function HeadingOf(p)
    if type(p) == 'vector4' then return p.w + 0.0 end
    if type(p) == 'table' then return (tonumber(p.w or p[4] or p.heading) or 0.0) + 0.0 end
    return 0.0
end

local function ToVec4(p, dx, dy)
    local x, y, z = U.xyz(p)
    return vector4(x + (dx or 0.0), y + (dy or 0.0), z + 0.0, HeadingOf(p))
end

local function PointList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if v == nil then return {} end
    if IsVec(v) then return { v } end
    if type(v) ~= 'table' then return {} end
    if type(v.points) == 'table' then v = v.points end
    local out = {}
    for i = 1, #v do
        local p = v[i]
        if IsVec(p) then
            out[#out + 1] = p
        elseif type(p) == 'table' and IsVec(p.coords) then
            out[#out + 1] = p.coords
        end
    end
    return out
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function AllAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if allowed and not U.contains(allowed, v) then return false end
    end
    return true
end

local function IsParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    if ctx.run and type(ctx.run.participants) == 'table' and ctx.run.participants[src] then return true end
    for _, s in ipairs(ctx.participants() or {}) do
        if s == src then return true end
    end
    return false
end

-- Still on the run: a participant who left shoots as an outsider (CP.Npc and CP.AntiCheat agree).
local function IsActiveParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    for _, s in ipairs(ctx.participants() or {}) do
        if tonumber(s) == src then return true end
    end
    return false
end

local function RngOf(ctx)
    local st = ctx.state
    if not st.rng then
        st.rng = ctx.rng or U.rng(((ctx.run and ctx.run.seed) or 1) + (ctx.index or 0))
    end
    return st.rng
end

local function PedCoords(p)
    if p.entity and DoesEntityExist(p.entity) then return GetEntityCoords(p.entity) end
    return nil
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Defaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 15 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.npcs == nil then obj.npcs = 'hostages' end
    if obj.count == nil then obj.count = c.npcs[3] end
    if obj.peds == nil then obj.peds = U.copy(c.peds) end
    if obj.restrained == nil then obj.restrained = c.restrained.default end
    if obj.freeTime == nil then obj.freeTime = c.freeTime[3] * 1000 end
    if type(obj.target) ~= 'table' then obj.target = {} end
    if obj.target.label == nil then obj.target.label = CP.L('block.protect_rescue.cut_restraints') end
    if obj.target.icon == nil then obj.target.icon = DEFAULT_ICON end
    if obj.target.distance == nil then obj.target.distance = TARGET_RANGE end
    if obj.safe == nil then obj.safe = 'safe' end
    if obj.safeRadius == nil then obj.safeRadius = SAFE_RADIUS end
    if obj.hitPenalty == nil then obj.hitPenalty = c.hitPenalty[3] end
    if obj.failIfDies == nil then obj.failIfDies = c.failIfDies.default end
    return obj
end

local function CheckLocation(o, loc, li, strict)
    local pts = PointList(loc, o.npcs)
    if #pts == 0 then
        return Bad('block.protect_rescue.invalid.points_missing', { key = tostring(o.npcs), location = li })
    end
    if #PointList(loc, o.safe) == 0 then
        return Bad('block.protect_rescue.invalid.points_missing', { key = tostring(o.safe), location = li })
    end
    if strict and #pts < o.count then
        return Bad('block.protect_rescue.invalid.points_count', { location = li, min = o.count, have = #pts })
    end
    -- no-build zones for every mission (docs/CRIMSON_ARENA.md rule 7); NPC spots are spawn points, so
    -- custom missions also keep them Config.Builder.minSpawnFromStart away from the start
    local start = loc.start and loc.start.coords
    for _, p in ipairs(pts) do
        if InNoBuild(p) then return Bad('block.protect_rescue.invalid.points_zone', { location = li }) end
        if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
            return Bad('block.protect_rescue.invalid.points_start',
                { location = li, min = Config.Builder.minSpawnFromStart })
        end
    end
    if InNoBuild(PointList(loc, o.safe)[1]) then
        return Bad('block.protect_rescue.invalid.points_zone', { location = li })
    end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.protect_rescue.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')

    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.protect_rescue.invalid.min_seconds') end
    if not InRange(o.presenceRange, c.presenceRange) then
        return Bad('block.protect_rescue.invalid.range',
            { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if not IsInt(o.count) or not InRange(o.count, c.npcs) then
        return Bad('block.protect_rescue.invalid.range', { field = 'count', min = c.npcs[1], max = c.npcs[2] })
    end
    if not AllAllowed(o.peds, strict and Config.Builder.allowed.peds or nil) then
        return Bad('block.protect_rescue.invalid.peds')
    end
    if type(o.restrained) ~= 'boolean' then return Bad('block.protect_rescue.invalid.flags') end
    if type(o.failIfDies) ~= 'boolean' then return Bad('block.protect_rescue.invalid.flags') end
    if not InRange(o.freeTime, c.freeTime, 1000) then
        return Bad('block.protect_rescue.invalid.range',
            { field = 'freeTime', min = c.freeTime[1], max = c.freeTime[2] })
    end
    if type(o.target.label) ~= 'string' or o.target.label == '' or not IsNum(o.target.distance)
        or o.target.distance <= 0 then
        return Bad('block.protect_rescue.invalid.target')
    end
    if not IsNum(o.safeRadius) or o.safeRadius <= 0 then return Bad('block.protect_rescue.invalid.safe_radius') end
    if not InRange(o.hitPenalty, c.hitPenalty) then
        return Bad('block.protect_rescue.invalid.range',
            { field = 'hitPenalty', min = c.hitPenalty[1], max = c.hitPenalty[2] })
    end
    if type(location) == 'table' then
        return CheckLocation(o, location, 1, strict)
    end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            local ok, why = CheckLocation(o, loc, li, strict)
            if not ok then return false, why end
        end
    end
    return true
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    if type(o.npcs) == 'string' then out[#out + 1] = o.npcs end
    if type(o.safe) == 'string' then out[#out + 1] = o.safe end
    return out
end

-- What appears at each location key this objective uses, for the spawn point check (Admin UI -> Testing,
-- modules/testing; ARCHITECTURE 7.1 pointKinds): the hostages are people, the safe spot is a
-- marker.
local function PointKinds(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    if type(o.npcs) == 'string' then out[#out + 1] = { key = o.npcs, kind = 'ped' } end
    if type(o.safe) == 'string' then out[#out + 1] = { key = o.safe, kind = 'marker' } end
    return out
end

-- ============================================================================
--                                  RUN STATE
-- ============================================================================

local ctxByState = setmetatable({}, { __mode = 'k' })
local listening = false

local function StateOf(ctx)
    Defaults(ctx.obj)
    local st = ctx.state
    if not st.block then
        st.block = BLOCK
        st.peds = {}
        st.spawned = 0
        st.slots = {}
        st.freeing = {}
        st.lastHit = {}
        st.hurt = false
        st.hits = 0
    end
    ctxByState[st] = ctx
    return st
end

local function Target(ctx)
    return math.max(0, math.floor((tonumber(ctx.obj.count) or 0) + 0.5))
end

local function SafePoint(ctx)
    return PointList(ctx.location, ctx.obj.safe)[1]
end

local function Tally(st)
    local living, freed, safe = 0, 0, 0
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            living = living + 1
            if p.state == 'freed' or p.state == 'safe' then freed = freed + 1 end
            if p.state == 'safe' then safe = safe + 1 end
        end
    end
    return living, freed, safe
end

local function UpdateHud(ctx, st)
    local living, _, safe = Tally(st)
    local total = math.max(living, Target(ctx) - (st.spawned - living))
    local text = CP.L('block.protect_rescue.detail', { safe = safe, total = total })
    if text ~= st.hudText then
        st.hudText = text
        ctx.hud({ detail = text, value = safe, max = total })
    end
end

local function Flush(ctx, st)
    if st.dirty then
        st.dirty = false
        local list = {}
        for _, p in pairs(st.peds) do
            list[#list + 1] = { netId = p.netId, state = p.state, index = p.index }
        end
        table.sort(list, function(a, b) return a.index < b.index end)
        ctx.send({ peds = list })
    end
    if st.current then UpdateHud(ctx, st) end
end

local function SetPed(ctx, st, p, state)
    p.state = state
    CP.Npc.setState(ctx.run, p.netId, state)
    st.dirty = true
end

-- ============================================================================
--                          WHEN AND WHERE THEY APPEAR
-- ============================================================================
-- Config.Spawning.hostagesAt (PLAN S15, owner request of 2026-10-19: "make it be progressive"): 'objective' = the
-- hostages appear when their own objective starts, through the engine's spawn director (ctx.whenNear: an officer
-- within activateRange; ctx.choosePoints at the indoor distance, minDistanceIndoor from every officer), and after
-- hostagesWaitMax seconds of officers standing closer they appear on their points anyway (one warning; 0 = never);
-- 'runStart' (or the director switched off, enabled = false) = in prepare, when the run starts, as before.

local function SpawnCfg() return type(Config.Spawning) == 'table' and Config.Spawning or {} end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v
end

-- true = the hostages appear when the run starts (prepare), as before; false = when their objective starts.
local function AtRunStart()
    local cfg = SpawnCfg()
    return cfg.enabled == false or cfg.hostagesAt == 'runStart'
end

-- Hostage i's spot: point order[k] of the list (k = (i - 1) % #pts + 1), a ring REUSE_OFFSET metres further out per
-- lap when there are more hostages than points (built-in missions only), and its console name.
local function Slot(ctx, st, pts, i)
    local k = ((i - 1) % #pts) + 1
    local lap = (i - 1) // #pts
    local idx = st.order[k]
    local base = pts[idx]
    local name = ('%s[%d]'):format(tostring(ctx.obj.npcs), idx)
    if lap == 0 then return ToVec4(base), name end
    local point = ToVec4(base, math.cos(lap + k) * REUSE_OFFSET * lap, math.sin(lap + k) * REUSE_OFFSET * lap)
    return point, ('%s +%.2f m'):format(name, REUSE_OFFSET * lap)
end

-- One hostage on spot i; false when it could not be made.
local function SpawnOne(ctx, st, i, point)
    local initial = ctx.obj.restrained ~= false and 'restrained' or 'idle'
    local model = RngOf(ctx):pick(ctx.obj.peds) or Cfg().peds[1]
    local ent, netId = ctx.spawnPed({
        model = model,
        coords = point,
        role = 'hostage',
        armed = false,
        cfg = { group = 'neutral', restrained = initial == 'restrained' },
        tag = 'hostage' .. i,
    })
    if not netId then return false end
    st.peds[tostring(netId)] = { netId = netId, entity = ent, index = i, state = initial, hurt = false }
    st.slots[i] = true
    st.spawned = st.spawned + 1
    CP.Npc.setState(ctx.run, netId, initial)
    st.dirty = true
    return true
end

-- At run start (AtRunStart): every free spot in order, as before.
local function SpawnLoop(ctx, st, want, pts)
    for i = 1, want do
        if st.spawned >= want then break end
        if not st.slots[i] then
            if not ctx.canSpawn(1, false) then return false end
            if not SpawnOne(ctx, st, i, (Slot(ctx, st, pts, i))) then return false end
            if st.stopped then return false end
        end
    end
    return true
end

-- The nearest active participant's distance to point on the map (math.huge with none).
local function NearestOfficer(ctx, point)
    local best = math.huge
    for _, src in ipairs(ctx.participants() or {}) do
        local c = ctx.coords(src)
        if c then
            local d = U.dist2d(c, point)
            if d < best then best = d end
        end
    end
    return best
end

-- The middle of the hostages' points (where the director measures the officers' way in to).
local function Middle(pts)
    local x, y, z = 0.0, 0.0, 0.0
    for _, p in ipairs(pts) do
        local px, py, pz = U.xyz(p)
        x, y, z = x + px, y + py, z + pz
    end
    return vector3(x / #pts, y / #pts, z / #pts)
end

-- When their objective is current: the free spots the spawn director allows now (indoor distance), once an officer
-- is near; after hostagesWaitMax seconds short (counted while an officer is near) the rest on their spots anyway.
-- st.waitMs is that clock (GetGameTimer); the director gets it as opts.since.
local function SpawnDirected(ctx, st, want, pts)
    if not st.current then return false end
    local centre = Middle(pts)
    if not ctx.whenNear(centre) then
        st.waitMs = nil
        return false
    end
    local offer = {}
    for i = 1, want do
        if not st.slots[i] then
            local point, name = Slot(ctx, st, pts, i)
            offer[#offer + 1] = { coords = point, label = name, slot = i }
        end
    end
    local now = Now()
    st.waitMs = st.waitMs or now
    local chosen = ctx.choosePoints(offer, #offer, {
        name = ('the hostages (%s)'):format(tostring(ctx.obj.npcs)),
        wave = 'hostages',
        since = os.time() - math.floor((now - st.waitMs) / 1000),
        centre = centre,
        indoor = true,
    }) or {}
    local waited = (now - st.waitMs) / 1000
    local maxWait = math.max(0, Num(SpawnCfg().hostagesWaitMax, 10))
    local late = #chosen < #offer and maxWait > 0 and waited >= maxWait
    if late then chosen = offer end
    local ok, closest = true, math.huge
    for _, c in ipairs(chosen) do
        if st.spawned >= want then break end
        if not ctx.canSpawn(1, false) then
            ok = false
            break
        end
        local d = NearestOfficer(ctx, c.coords)
        if not SpawnOne(ctx, st, c.slot, c.coords) then
            ok = false
            break
        end
        if d < closest then closest = d end
        if st.stopped then return false end
    end
    if late and closest < math.huge and not st.saidLate then
        st.saidLate = true
        CP.warn(BLOCK,
            'run %s (%s, %s): the hostages appeared %.0f m from an officer after %.0f s of waiting for the officers to step back to %.0f m (Config.Spawning.hostagesWaitMax)',
            tostring(ctx.run and ctx.run.id), tostring(ctx.run and ctx.run.missionId),
            tostring(ctx.location and ctx.location.label or '?'), closest, waited,
            math.max(0, Num(SpawnCfg().minDistanceIndoor, 15.0)))
    end
    if st.spawned >= want then st.waitMs = nil end
    return ok and st.spawned >= want
end

-- Spawns the hostages still missing (distinct spots first); false while waiting for room (or, when they appear with
-- their objective, for an officer near them and far enough). A location with no hostage points spawns nobody (one
-- warning; never on the start point). The spawning flag (re-entry while ctx.spawnPed yields) is always cleared, even
-- when a spawn throws.
local function SpawnMissing(ctx, st)
    local want = Target(ctx)
    if st.spawned >= want then return true end
    if st.spawning or st.stopped then return false end
    local pts = PointList(ctx.location, ctx.obj.npcs)
    if #pts == 0 then
        if not st.saidNoPoints then
            st.saidNoPoints = true
            CP.warn(BLOCK,
                'run %s (%s): the location has no hostage points under %s; no hostage appears (never at the start point)',
                tostring(ctx.run and ctx.run.id), tostring(ctx.run and ctx.run.missionId), tostring(ctx.obj.npcs))
        end
        return false
    end
    if not st.order or #st.order ~= #pts then
        local idx = {}
        for i = 1, #pts do idx[i] = i end
        st.order = RngOf(ctx):shuffle(idx)
    end
    st.spawning = true
    local okCall, ok = pcall(AtRunStart() and SpawnLoop or SpawnDirected, ctx, st, want, pts)
    st.spawning = false
    if not okCall then
        CP.err(BLOCK, 'spawning hostages for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(ok))
        return false
    end
    return ok and st.spawned >= want
end

-- ============================================================================
--                              DAMAGE AND DEATHS
-- ============================================================================
-- Also while another objective is current.

local function Hit(ctx, st, key, attacker)
    local p = st.peds[key]
    if not p or p.state == 'dead' then return false end
    p.hurt = true
    if not st.hurt then
        st.hurt = true
        st.dirty = true
    end
    attacker = tonumber(attacker)
    local pen = tonumber(ctx.obj.hitPenalty) or 0
    if not attacker or pen <= 0 or not IsActiveParticipant(ctx, attacker) then return true end
    local k = key .. ':' .. tostring(attacker)
    local t = Now()
    local last = st.lastHit[k]
    if last and t - last < HIT_WINDOW_MS then return true end
    st.lastHit[k] = t
    st.hits = (st.hits or 0) + 1
    ctx.penalize('hostage_hit', { count = 1, points = -pen })
    return true
end

local function Died(ctx, st, key, killerSrc)
    local p = st.peds[key]
    if not p or p.state == 'dead' then return end
    p.state = 'dead'
    p.hurt = true
    st.hurt = true
    st.dirty = true
    if st.failed then return end
    if IsParticipant(ctx, killerSrc) then
        st.failed = true
        ctx.fail('run.fail_killed_unarmed')
    elseif ctx.obj.failIfDies ~= false then
        st.failed = true
        ctx.fail('block.protect_rescue.fail_died')
    end
end

-- Hostage entities that vanished without a death event count as dead.
local function CheckGone(ctx, st)
    for key, p in pairs(st.peds) do
        if p.state ~= 'dead' and (not p.entity or not DoesEntityExist(p.entity)) then
            Died(ctx, st, key, nil)
        end
    end
end

local function FindState(run, netId)
    if type(run) ~= 'table' or type(run.objectives) ~= 'table' then return nil end
    local key = tostring(netId)
    for _, o in pairs(run.objectives) do
        local st = type(o) == 'table' and o.state or nil
        if type(st) == 'table' and st.block == BLOCK and type(st.peds) == 'table' and st.peds[key] then return st end
    end
    return nil
end

local function Listen()
    if listening or not CP.Npc or not CP.Npc.onDamaged then return end
    listening = true
    CP.Npc.onDamaged(function(run, netId, attackerSrc)
        local st = FindState(run, netId)
        local ctx = st and ctxByState[st]
        if not ctx then return end
        Hit(ctx, st, tostring(netId), attackerSrc)
        Flush(ctx, st)
    end)
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.stopped or not st.current then return end
    if st.spawned < Target(ctx) then return end
    local living = 0
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            living = living + 1
            if p.state ~= 'safe' then return end
        end
    end
    -- The bonus must be recorded before ctx.complete (completing the last objective ends the run
    -- and scores it), but a completion refused for minSeconds would leave it recorded while a
    -- hostage can still be hurt: award it only once the minimum time has passed.
    local minMs = (tonumber(ctx.obj.minSeconds) or 0) * 1000
    local early = st.startedAt ~= nil and Now() - st.startedAt < minMs
    if not early and not st.hurt and not st.bonusGiven then
        st.bonusGiven = true
        ctx.award('no_hostage_hurt', { count = 1 })
    end
    if ctx.complete({ safe = living, hits = st.hits or 0 }) ~= false then
        st.completed = true
    end
end

local function ReleaseIdle(ctx, st)
    if ctx.obj.restrained ~= false then return end
    for _, p in pairs(st.peds) do
        if p.state == 'idle' then SetPed(ctx, st, p, 'freed') end
    end
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

-- The run moved to In progress: the hostages appear now only with Config.Spawning.hostagesAt = 'runStart' (or the
-- director off), as before; else when this objective starts.
local function Prepare(ctx)
    local st = StateOf(ctx)
    Listen()
    if not AtRunStart() then
        Flush(ctx, st)
        return
    end
    if not SpawnMissing(ctx, st) then
        CreateThread(function()
            while not st.stopped and not st.failed and st.spawned < Target(ctx)
                and not (ctx.run and ctx.run.state == 'ended') do
                Wait(RETRY_MS)
                if not st.current then SpawnMissing(ctx, st) end
                Flush(ctx, st)
            end
        end)
    end
    Flush(ctx, st)
end

local function Start(ctx)
    local st = StateOf(ctx)
    Listen()
    st.current = true
    st.startedAt = st.startedAt or Now()
    SpawnMissing(ctx, st)
    CheckGone(ctx, st)
    if st.failed then return end
    ReleaseIdle(ctx, st)
    st.dirty = true
    Flush(ctx, st)
end

local function Tick(ctx)
    local st = StateOf(ctx)
    if st.stopped or st.failed then return end
    st.current = true
    if not st.completed then
        SpawnMissing(ctx, st)
        ReleaseIdle(ctx, st)
        CheckGone(ctx, st)
        if st.failed then return end
        local safe = SafePoint(ctx)
        local r = tonumber(ctx.obj.safeRadius) or SAFE_RADIUS
        if safe then
            for _, p in pairs(st.peds) do
                if p.state == 'freed' then
                    local c = PedCoords(p)
                    if c and U.dist(c, safe) <= r then
                        SetPed(ctx, st, p, 'safe')
                        -- the service record: one rescue for every participant in the run
                        if CP.Runs and CP.Runs.noteStat and ctx.run then
                            CP.Runs.noteStat(ctx.run, nil, 'rescues', 1)
                        end
                    end
                end
            end
        end
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function InReach(ctx, src, p)
    local pc, sc = PedCoords(p), ctx.coords(src)
    local reach = (tonumber(ctx.obj.target.distance) or TARGET_RANGE) + REACH_SLACK
    return pc ~= nil and sc ~= nil and U.dist(pc, sc) <= reach
end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local netId = tonumber(ev.netId)
    local key = netId and tostring(netId) or nil
    local p = key and st.peds[key] or nil
    local t = ev.type
    local ok, why = true, nil
    if t == 'free_start' or t == 'freed' then
        if not p then return false, 'unknown_entity' end
        if p.state == 'freed' or p.state == 'safe' then return false, 'duplicate' end
        if p.state ~= 'restrained' then return false, 'wrong_state' end
        if not InReach(ctx, src, p) then return false, 'too_far' end
        local sk = tostring(src)
        if t == 'free_start' then
            -- one cut at a time per participant (one progress bar): a new start replaces the last one
            for _, bySrc in pairs(st.freeing) do bySrc[sk] = nil end
            st.freeing[key] = st.freeing[key] or {}
            st.freeing[key][sk] = Now()
        else
            local started = st.freeing[key] and st.freeing[key][sk]
            if not started then return false, 'not_started' end
            if Now() - started < (tonumber(ctx.obj.freeTime) or 0) * FREE_SHARE then return false, 'too_fast' end
            st.freeing[key] = nil
            SetPed(ctx, st, p, 'freed')
        end
    elseif t == 'shot' or t == 'damaged' then
        if not p then return false, 'unknown_entity' end
        -- onEvent cannot tell a CP.Npc dispatch from client evidence (server:objective delivers the
        -- same shape), and a client must never be able to cost the team hostage_hit or the
        -- no_hostage_hurt bonus. CP.Npc.onDamaged, which is server-only, reports every hit on a
        -- hostage (both events are always sent together with it), so while it is listened to these
        -- events are acknowledged and change nothing. Without it they are the only damage channel.
        if listening then
            Flush(ctx, st)
            return true
        end
        local attacker = ev.src or ev.attacker
        if t == 'shot' and attacker == nil then attacker = src end
        Hit(ctx, st, key, attacker)
    else
        return false, 'unknown_event'
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
    return ok, why
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    Died(ctx, st, tostring(netId), killerSrc)
    Flush(ctx, st)
end

local function Presence(ctx, src, coords)
    local st = StateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            local c = PedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local s = SafePoint(ctx) or (ctx.location and ctx.location.start and ctx.location.start.coords)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local living, freed, safe = Tally(st)
    local total = math.max(living, Target(ctx) - (st.spawned - living))
    return {
        {
            label = CP.L('block.protect_rescue.check_freed'),
            done = total > 0 and freed >= total,
            value = freed,
            max = total,
        },
        {
            label = CP.L('block.protect_rescue.check_safe'),
            done = total > 0 and safe >= total,
            value = safe,
            max = total,
        },
    }
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for _, p in pairs(st.peds) do ctx.delete(p.netId) end
    local keep, current = st.rng, st.current
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    st = StateOf(ctx)
    st.current = current
    if current then st.startedAt = Now() end
    SpawnMissing(ctx, st)
    if current then ReleaseIdle(ctx, st) end
    st.dirty = true
    Flush(ctx, st)
end

local function Rescale(ctx)
    local st = StateOf(ctx)
    st.dirty = true
    Flush(ctx, st)
end

local function Stop(ctx)
    local st = StateOf(ctx)
    st.stopped = true
    st.current = false
end

CP.Blocks.register(BLOCK, {
    defaults = Defaults,
    validate = Validate,
    armedCount = function() return 0 end,
    requiredPoints = RequiredPoints,
    pointKinds = PointKinds,
    prepare = Prepare,
    -- the engine warns about a block that makes entities in prepare, unless an owner setting asked for it
    spawnsInPrepare = function() return AtRunStart() end,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    onEntityDead = OnEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = StateOf(ctx)
        for _, bySrc in pairs(st.freeing) do bySrc[tostring(src)] = nil end
    end,
    rescale = Rescale,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = Stop,
})
