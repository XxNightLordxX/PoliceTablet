-- Objective block "skill_check" (server half)

local BLOCK = 'skill_check'

local SHARED = 'shared:devices'
local REACH = 5.0                   -- metres from the target (zone radius + interaction distance + lag)
local LOCK_MS = 15000               -- another participant may take over a target after this long idle
local MIN_ROUND_MS = 250            -- rounds from one participant closer than this are rejected
local ICON = 'fa-solid fa-bomb'
local DEVICE_PROP = 'prop_ld_bomb'  -- model for a re-created device prop when the shared entry has none
local SPAWN_TRIES = 3               -- failed re-creations of one prop before giving up (coords still work)

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

local function Idx(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return type(x) == 'number' and type(y) == 'number' and type(z) == 'number'
end

local function Vec3Of(v)
    local x, y, z = CP.U.xyz(v)
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function Plain(v)
    local x, y, z = CP.U.xyz(v)
    return { x = x, y = y, z = z }
end

local function Bad(key, vars)
    return false, CP.L(key, vars)
end

local function InRange(v, r)
    return type(v) == 'number' and type(r) == 'table' and v >= r[1] and v <= r[2]
end

-- Config.Builder.noBuildZones: no marker, target point or route waypoint inside them.
local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if CP.U.dist2d(p, z.coords) <= (tonumber(z.radius) or 0) then return true end
    end
    return false
end

-- ============================================================================
--                                   TARGETS
-- ============================================================================

local function ResolvePoints(key, location)
    local src = key
    if type(src) == 'string' then src = type(location) == 'table' and location[src] or nil end
    if src == nil then return nil end
    if IsVec(src) then return { Vec3Of(src) } end
    if type(src) ~= 'table' then return nil end
    local out = {}
    for i = 1, #src do
        local p = src[i]
        if type(p) == 'table' and not IsVec(p) and IsVec(p.coords) then p = p.coords end
        if not IsVec(p) then return nil end
        out[i] = Vec3Of(p)
    end
    return out
end

-- shared = the netId the device had in run.shared.devices (its identity; netId may change when the
-- prop is re-created), model/heading for that re-creation.
local function NewTarget(coords, netId, extra)
    extra = type(extra) == 'table' and extra or {}
    return {
        coords = Vec3Of(coords),
        netId = netId,
        shared = netId,
        model = type(extra.model) == 'string' and extra.model or nil,
        heading = tonumber(extra.heading),
        status = 'armed',
        next = 1,
        streak = 0,
        misses = 0,
    }
end

local function Ensure(ctx)
    local st = ctx.state
    if st.targets then return st end
    st.targets = {}
    st.misses = 0
    if ctx.obj.targets ~= SHARED then
        local pts = ResolvePoints(ctx.obj.targets, ctx.location)
        if not pts then
            CP.err('blocks', 'skill_check: objective %s has no usable targets (%s)', tostring(ctx.index),
                tostring(ctx.obj.targets))
            pts = {}
        end
        for i, p in ipairs(pts) do st.targets[i] = NewTarget(p, nil) end
    end
    return st
end

-- Add devices that joined run.shared.devices since the last look. Returns true when it added any.
local function Sync(ctx, st)
    if ctx.obj.targets ~= SHARED then return false end
    local devs = ctx.run.shared and ctx.run.shared.devices
    if type(devs) ~= 'table' then return false end
    local have = {}
    for _, t in ipairs(st.targets) do
        if t.shared then have[t.shared] = true end
    end
    local added = false
    for _, d in ipairs(devs) do
        if type(d) == 'table' and d.netId and not have[d.netId] and IsVec(d.coords) then
            st.targets[#st.targets + 1] = NewTarget(d.coords, d.netId, d)
            have[d.netId] = true
            added = true
        end
    end
    return added
end

local function EntityGone(netId)
    if not netId then return true end
    local ent = NetworkGetEntityFromNetworkId(netId)
    return not ent or ent == 0 or not DoesEntityExist(ent)
end

-- Re-create the prop of every armed shared device whose entity is gone. Returns true when it spawned any.
local function RestoreProps(ctx, st)
    local changed = false
    for _, t in ipairs(st.targets) do
        if t.shared and t.status == 'armed' and (t.spawnFails or 0) < SPAWN_TRIES and EntityGone(t.netId) then
            if not ctx.canSpawn(1, false) then
                break
            end -- cap reached: wait, retried next tick
            local coords = t.coords
            if t.heading then coords = vector4(t.coords.x, t.coords.y, t.coords.z, t.heading + 0.0) end
            local _, netId = ctx.spawnObject({
                model = t.model or DEVICE_PROP,
                coords = coords,
                role = 'device',
                tag = SHARED,
                frozen = true,
            })
            if netId then
                t.netId = netId
                changed = true
            else
                t.spawnFails = (t.spawnFails or 0) + 1
                if t.spawnFails >= SPAWN_TRIES then
                    CP.warn('blocks', 'skill_check: could not re-create device prop %s; the device stays at its coords',
                        tostring(t.model or DEVICE_PROP))
                end
            end
        end
    end
    return changed
end

local function TargetCoords(t)
    if t.netId then
        local ent = NetworkGetEntityFromNetworkId(t.netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return GetEntityCoords(ent) end
    end
    return t.coords
end

local function Checks(ctx)
    return type(ctx.obj.checks) == 'table' and ctx.obj.checks or Cfg().difficulty.default
end

local function SendState(ctx, st)
    local list = {}
    for i, t in ipairs(st.targets) do
        list[i] = {
            coords = Plain(t.coords),
            netId = t.netId,
            status = t.status,
            next = t.next,
            streak = t.streak,
            worker = t.worker,
        }
    end
    ctx.send({ kind = 'state', targets = list, checks = #Checks(ctx) })
end

local function SendExplode(ctx, st, i, by)
    local t = st.targets[i]
    ctx.send({
        kind = 'explode',
        target = i,
        coords = Plain(TargetCoords(t)),
        by = by,
        effect = ctx.obj.explosion ~= false,
    })
end

local function TryComplete(ctx, st)
    if st.completed then return true end
    local ok = ctx.complete({ misses = st.misses, targets = #st.targets })
    if ok ~= false then st.completed = true end
    return st.completed
end

local function CheckDone(ctx, st)
    if st.completed or st.failed then return end
    if #st.targets == 0 then return end
    for _, t in ipairs(st.targets) do
        if t.status ~= 'defused' then return end
    end
    if not st.bonusDone then
        st.bonusDone = true
        if st.misses == 0 then ctx.award('no_missed_checks') end
    end
    st.ready = true
    TryComplete(ctx, st)
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnCheck(ctx, st, src, ev)
    local i = Idx(ev.target)
    local t = i and st.targets[i]
    if not t then return false, 'bad_target' end
    if t.status ~= 'armed' then return false, 'wrong_state' end
    local k = Idx(ev.index)
    if k ~= t.next then return false, 'wrong_index' end
    if type(ev.success) ~= 'boolean' then return false, 'bad_result' end
    local c = ctx.coords(src)
    if not c or CP.U.dist(c, TargetCoords(t)) > REACH then return false, 'too_far' end
    local tm = Now()
    if t.worker and t.worker ~= src and tm - (t.lastAt or 0) < LOCK_MS then return false, 'busy' end
    if t.worker == src and t.lastAt and tm - t.lastAt < MIN_ROUND_MS then return false, 'too_quick' end
    t.worker, t.lastAt = src, tm

    if ev.success then
        t.streak = 0
        t.next = t.next + 1
        if t.next > #Checks(ctx) then
            t.status = 'defused'
            t.worker = nil
            t.defusedBy = src
        end
    else
        t.streak = t.streak + 1
        t.misses = t.misses + 1
        st.misses = st.misses + 1
        local pen = tonumber(ctx.obj.missPenalty) or 0
        if pen > 0 then CP.Runs.adjustTimer(ctx.run, -pen) end
        if t.streak >= (Idx(ctx.obj.failAfter) or Cfg().failAfter[3]) then
            t.status = 'exploded'
            t.worker = nil
            st.failed = true
            SendExplode(ctx, st, i, src)
            SendState(ctx, st)
            ctx.fail('block.skill_check.fail_exploded')
            return true
        end
    end
    SendState(ctx, st)
    CheckDone(ctx, st)
    return true
end

-- ============================================================================
--                                    BLOCK
-- ============================================================================

local function ApplyDefaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 10 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.label == nil then obj.label = CP.L('block.skill_check.label') end
    if obj.targets == nil then obj.targets = SHARED end
    if obj.checks == nil then obj.checks = CP.U.deepcopy(c.difficulty.default) end
    if obj.missPenalty == nil then obj.missPenalty = c.missPenalty[3] end
    if obj.failAfter == nil then obj.failAfter = c.failAfter[3] end
    if type(obj.target) ~= 'table' then obj.target = {} end
    if obj.target.icon == nil then obj.target.icon = ICON end
    if obj.explosion == nil then obj.explosion = true end
    return obj
end

local function HasHiddenSearch(mission, obj)
    if type(mission) ~= 'table' or type(mission.objectives) ~= 'table' then return true end
    local myIndex
    for i, o in ipairs(mission.objectives) do
        if o == obj then myIndex = i end
    end
    for i, o in ipairs(mission.objectives) do
        if type(o) == 'table' and o.block == 'interact_points' and type(o.hidden) == 'table'
            and (not myIndex or i < myIndex) then
            return true
        end
    end
    return false
end

CP.Blocks.register(BLOCK, {
    defaults = ApplyDefaults,

    validate = function(obj, mission, location)
        local c = Cfg()
        if type(obj) ~= 'table' then return Bad('block.skill_check.invalid.objective') end
        local original = obj
        obj = ApplyDefaults(CP.U.deepcopy(obj))
        if type(obj.checks) ~= 'table' or not InRange(#obj.checks, c.checks) then
            return Bad('block.skill_check.invalid.range', { field = 'checks', min = c.checks[1], max = c.checks[2] })
        end
        for _, d in ipairs(obj.checks) do
            if not CP.U.contains(c.difficulty.options, d) then return Bad('block.skill_check.invalid.difficulty') end
        end
        if not InRange(obj.missPenalty, c.missPenalty) then
            return Bad('block.skill_check.invalid.range',
                { field = 'missPenalty', min = c.missPenalty[1], max = c.missPenalty[2] })
        end
        local fa = Idx(obj.failAfter)
        if not fa or not InRange(fa, c.failAfter) then
            return Bad('block.skill_check.invalid.range',
                { field = 'failAfter', min = c.failAfter[1], max = c.failAfter[2] })
        end
        if not InRange(obj.presenceRange, c.presenceRange) then
            return Bad('block.skill_check.invalid.range',
                { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
        end
        if type(obj.minSeconds) ~= 'number' or obj.minSeconds < 0 then
            return Bad('block.skill_check.invalid.min_seconds')
        end
        if type(obj.explosion) ~= 'boolean' then return Bad('block.skill_check.invalid.flags') end
        if obj.targets == SHARED then
            if not HasHiddenSearch(mission, original) then return Bad('block.skill_check.invalid.no_devices') end
            return true
        end
        if type(obj.targets) ~= 'string' and type(obj.targets) ~= 'table' then
            return Bad('block.skill_check.invalid.targets')
        end
        local locations = {}
        if type(location) == 'table' then
            locations[1] = location
        elseif type(mission) == 'table' and type(mission.locations) == 'table' then
            locations = mission.locations
        end
        for li, loc in ipairs(locations) do
            local pts = ResolvePoints(obj.targets, loc)
            if not pts or #pts == 0 then
                return Bad('block.skill_check.invalid.points_missing', { key = tostring(obj.targets), location = li })
            end
            for _, p in ipairs(pts) do
                if InNoBuild(p) then return Bad('block.skill_check.invalid.points_zone', { location = li }) end
            end
        end
        return true
    end,

    armedCount = function(obj)
        return 0
    end,

    requiredPoints = function(obj)
        if type(obj.targets) == 'string' and obj.targets ~= SHARED then return { obj.targets } end
        return {}
    end,

    -- Location targets are known now; shared devices only exist once the search objective found them.
    prepare = function(ctx)
        Ensure(ctx)
    end,

    start = function(ctx)
        local st = Ensure(ctx)
        Sync(ctx, st)
        RestoreProps(ctx, st)
        st.resent = false
        if #st.targets == 0 then
            CP.warn('blocks', 'skill_check: objective %s started with no targets', tostring(ctx.index))
        end
        SendState(ctx, st)
    end,

    tick = function(ctx, dt)
        local st = Ensure(ctx)
        if st.completed or st.failed then return end
        local changed = Sync(ctx, st)
        if RestoreProps(ctx, st) then changed = true end
        if not st.resent then
            st.resent = true
            changed = true
        end
        local tm = Now()
        for _, t in ipairs(st.targets) do
            if t.worker and tm - (t.lastAt or 0) >= LOCK_MS then
                t.worker = nil
                changed = true
            end
        end
        if changed then SendState(ctx, st) end
        if #st.targets == 0 or st.ready then
            st.ready = true
            TryComplete(ctx, st)
        end
    end,

    onEvent = function(ctx, src, ev)
        local st = Ensure(ctx)
        if type(ev) ~= 'table' then return false, 'bad_event' end
        if st.completed or st.failed then return false, 'objective_over' end
        Sync(ctx, st)
        if ev.type == 'check' then return OnCheck(ctx, st, src, ev) end
        return false, 'unknown_event'
    end,

    -- Targets are props or points, not peds or vehicles: nothing of this objective can die.
    onEntityDead = function(ctx, netId, killerSrc)
        return nil
    end,

    onParticipantLeft = function(ctx, src)
        local st = Ensure(ctx)
        local changed = false
        for _, t in ipairs(st.targets) do
            if t.worker == src then
                t.worker = nil
                changed = true
            end
        end
        if changed then SendState(ctx, st) end
    end,

    -- Devices never scale here (the search objective decides how many exist); pick up any change.
    rescale = function(ctx)
        local st = Ensure(ctx)
        if Sync(ctx, st) then SendState(ctx, st) end
    end,

    -- The device timer ran out: every armed device goes off (effect played by the run host) and the
    -- run fails with the engine's time_limit.
    onTimeout = function(ctx)
        local st = Ensure(ctx)
        local host = ctx.host()
        for i, t in ipairs(st.targets) do
            if t.status == 'armed' then
                t.status = 'exploded'
                t.worker = nil
                SendExplode(ctx, st, i, host)
            end
        end
        st.failed = true
        SendState(ctx, st)
        return nil
    end,

    -- The target this participant works on, otherwise the nearest armed one.
    presence = function(ctx, src, coords)
        local st = Ensure(ctx)
        local best
        for _, t in ipairs(st.targets) do
            if t.status == 'armed' then
                local d = CP.U.dist(coords, TargetCoords(t))
                if t.worker == src then return d end
                if not best or d < best then best = d end
            end
        end
        return best or 0.0
    end,

    checklist = function(ctx)
        local st = Ensure(ctx)
        local done = 0
        for _, t in ipairs(st.targets) do
            if t.status == 'defused' then done = done + 1 end
        end
        return {
            {
                label = CP.L('block.skill_check.checklist'),
                done = #st.targets > 0 and done >= #st.targets,
                value = done,
                max = #st.targets,
            },
        }
    end,

    -- Test control: every target is armed again from its first round.
    restart = function(ctx)
        local st = Ensure(ctx)
        Sync(ctx, st)
        for _, t in ipairs(st.targets) do
            t.status, t.next, t.streak, t.misses = 'armed', 1, 0, 0
            t.worker, t.lastAt, t.defusedBy = nil, nil, nil
        end
        st.misses = 0
        st.bonusDone, st.ready, st.completed, st.failed = false, false, false, false
        SendState(ctx, st)
    end,

    stop = function(ctx)
        for _, t in ipairs(ctx.state.targets or {}) do t.worker = nil end
    end,
})
