--[[ blocks/skill_check/server.lua · objective block "skill_check" (server half)

  What it does
    Every target (a device from run.shared.devices, or a point of a location key) must be worked with
    a sequence of ox_lib skill checks. The client reports each round as it happens; the server keeps
    the progress per target: a success moves to the next round, a miss repeats the round, takes
    missPenalty seconds off the run timer (CP.Runs.adjustTimer) and counts toward failAfter misses in
    a row on that target, which sets it off: an explosion effect only (played by the client of the
    participant who missed; damage scale 0) and the run fails for everyone. Done when every target is
    defused; no_missed_checks when nobody missed a round. One participant works a target at a time
    (the lock frees itself after 15 s without a round). Powers Bomb Disposal's defusing.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.skill_check)
    targets      'shared:devices' (devices found by an earlier interact_points hidden search) or a
                 location key (vec3/vec4 or list of them)          ['shared:devices']
    checks       difficulty per round                               [difficulty.default = easy, medium, medium, hard]
    missPenalty  seconds off the run timer per miss                 [missPenalty[3] = 30]
    failAfter    misses in a row on one target that set it off      [failAfter[3] = 2]
    target       { label, icon }                                    [label: locale default, icon default]
    explosion    play the explosion effect when a target goes off   [true]
    minSeconds [10] · presenceRange [presenceRange[3] = 150] · label

  Evidence accepted (ctx.report from the client half)
    { type = 'check', target, index, success }   one round: index must be the target's next round,
                                                 the reporter within 5 m of the target (server coords)

  Messages sent (ctx.send): { kind = 'state', targets, checks } after every change;
    { kind = 'explode', target, coords, by, effect } when a target goes off (by = reporting src, or the
    run host when the timer runs out)
  Bonuses / penalties recorded (shared): no_missed_checks (ctx.award)
  Fail reason keys: block.skill_check.fail_exploded
]]

local BLOCK = 'skill_check'

local SHARED       = 'shared:devices'
local REACH        = 5.0      -- metres from the target (zone radius + interaction distance + lag)
local LOCK_MS      = 15000    -- another participant may take over a target after this long idle
local MIN_ROUND_MS = 250      -- rounds from one participant closer than this are rejected
local ICON         = 'fa-solid fa-bomb'

local function cfg() return Config.Blocks[BLOCK] end
local function now() return GetGameTimer() end

local function idx(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

local function isVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return type(x) == 'number' and type(y) == 'number' and type(z) == 'number'
end

local function vec3Of(v)
    local x, y, z = CP.U.xyz(v)
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function plain(v)
    local x, y, z = CP.U.xyz(v)
    return { x = x, y = y, z = z }
end

local function bad(key, vars)
    return false, CP.L(key, vars)
end

local function inRange(v, r)
    return type(v) == 'number' and type(r) == 'table' and v >= r[1] and v <= r[2]
end

-- Config.Builder.noBuildZones: no marker, target point or route waypoint inside them.
local function inNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if CP.U.dist2d(p, z.coords) <= (tonumber(z.radius) or 0) then return true end
    end
    return false
end

-- ── Targets ─────────────────────────────────────────────────────────────────
local function resolvePoints(key, location)
    local src = key
    if type(src) == 'string' then src = type(location) == 'table' and location[src] or nil end
    if src == nil then return nil end
    if isVec(src) then return { vec3Of(src) } end
    if type(src) ~= 'table' then return nil end
    local out = {}
    for i = 1, #src do
        local p = src[i]
        if type(p) == 'table' and not isVec(p) and isVec(p.coords) then p = p.coords end
        if not isVec(p) then return nil end
        out[i] = vec3Of(p)
    end
    return out
end

local function newTarget(coords, netId)
    return { coords = vec3Of(coords), netId = netId, status = 'armed', next = 1, streak = 0, misses = 0 }
end

local function ensure(ctx)
    local st = ctx.state
    if st.targets then return st end
    st.targets = {}
    st.misses = 0
    if ctx.obj.targets ~= SHARED then
        local pts = resolvePoints(ctx.obj.targets, ctx.location)
        if not pts then
            CP.err('blocks', 'skill_check: objective %s has no usable targets (%s)', tostring(ctx.index), tostring(ctx.obj.targets))
            pts = {}
        end
        for i, p in ipairs(pts) do st.targets[i] = newTarget(p, nil) end
    end
    return st
end

-- Add devices that joined run.shared.devices since the last look. Returns true when it added any.
local function sync(ctx, st)
    if ctx.obj.targets ~= SHARED then return false end
    local devs = ctx.run.shared and ctx.run.shared.devices
    if type(devs) ~= 'table' then return false end
    local have = {}
    for _, t in ipairs(st.targets) do
        if t.netId then have[t.netId] = true end
    end
    local added = false
    for _, d in ipairs(devs) do
        if type(d) == 'table' and d.netId and not have[d.netId] and isVec(d.coords) then
            st.targets[#st.targets + 1] = newTarget(d.coords, d.netId)
            have[d.netId] = true
            added = true
        end
    end
    return added
end

local function targetCoords(t)
    if t.netId then
        local ent = NetworkGetEntityFromNetworkId(t.netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return GetEntityCoords(ent) end
    end
    return t.coords
end

local function checks(ctx)
    return type(ctx.obj.checks) == 'table' and ctx.obj.checks or cfg().difficulty.default
end

local function sendState(ctx, st)
    local list = {}
    for i, t in ipairs(st.targets) do
        list[i] = {
            coords = plain(t.coords), netId = t.netId, status = t.status,
            next = t.next, streak = t.streak, worker = t.worker,
        }
    end
    ctx.send({ kind = 'state', targets = list, checks = #checks(ctx) })
end

local function sendExplode(ctx, st, i, by)
    local t = st.targets[i]
    ctx.send({ kind = 'explode', target = i, coords = plain(targetCoords(t)), by = by, effect = ctx.obj.explosion ~= false })
end

local function tryComplete(ctx, st)
    if st.completed then return true end
    local ok = ctx.complete({ misses = st.misses, targets = #st.targets })
    if ok ~= false then st.completed = true end
    return st.completed
end

local function checkDone(ctx, st)
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
    tryComplete(ctx, st)
end

-- ── Evidence ────────────────────────────────────────────────────────────────
local function onCheck(ctx, st, src, ev)
    local i = idx(ev.target)
    local t = i and st.targets[i]
    if not t then return false, 'bad_target' end
    if t.status ~= 'armed' then return false, 'wrong_state' end
    local k = idx(ev.index)
    if k ~= t.next then return false, 'wrong_index' end
    if type(ev.success) ~= 'boolean' then return false, 'bad_result' end
    local c = ctx.coords(src)
    if not c or CP.U.dist(c, targetCoords(t)) > REACH then return false, 'too_far' end
    local tm = now()
    if t.worker and t.worker ~= src and tm - (t.lastAt or 0) < LOCK_MS then return false, 'busy' end
    if t.worker == src and t.lastAt and tm - t.lastAt < MIN_ROUND_MS then return false, 'too_quick' end
    t.worker, t.lastAt = src, tm

    if ev.success then
        t.streak = 0
        t.next = t.next + 1
        if t.next > #checks(ctx) then
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
        if t.streak >= (idx(ctx.obj.failAfter) or cfg().failAfter[3]) then
            t.status = 'exploded'
            t.worker = nil
            st.failed = true
            sendExplode(ctx, st, i, src)
            sendState(ctx, st)
            ctx.fail('block.skill_check.fail_exploded')
            return true
        end
    end
    sendState(ctx, st)
    checkDone(ctx, st)
    return true
end

-- ── Block ───────────────────────────────────────────────────────────────────
local function applyDefaults(obj)
    local c = cfg()
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

local function hasHiddenSearch(mission, obj)
    if type(mission) ~= 'table' or type(mission.objectives) ~= 'table' then return true end
    local myIndex
    for i, o in ipairs(mission.objectives) do
        if o == obj then myIndex = i end
    end
    for i, o in ipairs(mission.objectives) do
        if type(o) == 'table' and o.block == 'interact_points' and type(o.hidden) == 'table' and (not myIndex or i < myIndex) then
            return true
        end
    end
    return false
end

CP.Blocks.register(BLOCK, {
    defaults = applyDefaults,

    validate = function(obj, mission, location)
        local c = cfg()
        if type(obj) ~= 'table' then return bad('block.skill_check.invalid.objective') end
        local original = obj
        obj = applyDefaults(CP.U.deepcopy(obj))
        if type(obj.checks) ~= 'table' or not inRange(#obj.checks, c.checks) then
            return bad('block.skill_check.invalid.range', { field = 'checks', min = c.checks[1], max = c.checks[2] })
        end
        for _, d in ipairs(obj.checks) do
            if not CP.U.contains(c.difficulty.options, d) then return bad('block.skill_check.invalid.difficulty') end
        end
        if not inRange(obj.missPenalty, c.missPenalty) then
            return bad('block.skill_check.invalid.range', { field = 'missPenalty', min = c.missPenalty[1], max = c.missPenalty[2] })
        end
        local fa = idx(obj.failAfter)
        if not fa or not inRange(fa, c.failAfter) then
            return bad('block.skill_check.invalid.range', { field = 'failAfter', min = c.failAfter[1], max = c.failAfter[2] })
        end
        if not inRange(obj.presenceRange, c.presenceRange) then
            return bad('block.skill_check.invalid.range', { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
        end
        if type(obj.minSeconds) ~= 'number' or obj.minSeconds < 0 then
            return bad('block.skill_check.invalid.min_seconds')
        end
        if type(obj.explosion) ~= 'boolean' then return bad('block.skill_check.invalid.flags') end
        if obj.targets == SHARED then
            if not hasHiddenSearch(mission, original) then return bad('block.skill_check.invalid.no_devices') end
            return true
        end
        if type(obj.targets) ~= 'string' and type(obj.targets) ~= 'table' then
            return bad('block.skill_check.invalid.targets')
        end
        local locations = {}
        if type(location) == 'table' then
            locations[1] = location
        elseif type(mission) == 'table' and type(mission.locations) == 'table' then
            locations = mission.locations
        end
        for li, loc in ipairs(locations) do
            local pts = resolvePoints(obj.targets, loc)
            if not pts or #pts == 0 then
                return bad('block.skill_check.invalid.points_missing', { key = tostring(obj.targets), location = li })
            end
            for _, p in ipairs(pts) do
                if inNoBuild(p) then return bad('block.skill_check.invalid.points_zone', { location = li }) end
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
        ensure(ctx)
    end,

    start = function(ctx)
        local st = ensure(ctx)
        sync(ctx, st)
        st.resent = false
        if #st.targets == 0 then
            CP.warn('blocks', 'skill_check: objective %s started with no targets', tostring(ctx.index))
        end
        sendState(ctx, st)
    end,

    tick = function(ctx, dt)
        local st = ensure(ctx)
        if st.completed or st.failed then return end
        local changed = sync(ctx, st)
        if not st.resent then
            st.resent = true
            changed = true
        end
        local tm = now()
        for _, t in ipairs(st.targets) do
            if t.worker and tm - (t.lastAt or 0) >= LOCK_MS then
                t.worker = nil
                changed = true
            end
        end
        if changed then sendState(ctx, st) end
        if #st.targets == 0 or st.ready then
            st.ready = true
            tryComplete(ctx, st)
        end
    end,

    onEvent = function(ctx, src, ev)
        local st = ensure(ctx)
        if type(ev) ~= 'table' then return false, 'bad_event' end
        if st.completed or st.failed then return false, 'objective_over' end
        sync(ctx, st)
        if ev.type == 'check' then return onCheck(ctx, st, src, ev) end
        return false, 'unknown_event'
    end,

    -- Targets are props or points, not peds or vehicles: nothing of this objective can die.
    onEntityDead = function(ctx, netId, killerSrc)
        return nil
    end,

    onParticipantLeft = function(ctx, src)
        local st = ensure(ctx)
        local changed = false
        for _, t in ipairs(st.targets) do
            if t.worker == src then
                t.worker = nil
                changed = true
            end
        end
        if changed then sendState(ctx, st) end
    end,

    -- Devices never scale here (the search objective decides how many exist); pick up any change.
    rescale = function(ctx)
        local st = ensure(ctx)
        if sync(ctx, st) then sendState(ctx, st) end
    end,

    -- The device timer ran out: every armed device goes off (effect played by the run host) and the
    -- run fails with the engine's time_limit.
    onTimeout = function(ctx)
        local st = ensure(ctx)
        local host = ctx.host()
        for i, t in ipairs(st.targets) do
            if t.status == 'armed' then
                t.status = 'exploded'
                t.worker = nil
                sendExplode(ctx, st, i, host)
            end
        end
        st.failed = true
        sendState(ctx, st)
        return nil
    end,

    -- The target this participant works on, otherwise the nearest armed one.
    presence = function(ctx, src, coords)
        local st = ensure(ctx)
        local best
        for _, t in ipairs(st.targets) do
            if t.status == 'armed' then
                local d = CP.U.dist(coords, targetCoords(t))
                if t.worker == src then return d end
                if not best or d < best then best = d end
            end
        end
        return best or 0.0
    end,

    checklist = function(ctx)
        local st = ensure(ctx)
        local done = 0
        for _, t in ipairs(st.targets) do
            if t.status == 'defused' then done = done + 1 end
        end
        return { { label = CP.L('block.skill_check.checklist'), done = #st.targets > 0 and done >= #st.targets, value = done, max = #st.targets } }
    end,

    -- Test control: every target is armed again from its first round.
    restart = function(ctx)
        local st = ensure(ctx)
        sync(ctx, st)
        for _, t in ipairs(st.targets) do
            t.status, t.next, t.streak, t.misses = 'armed', 1, 0, 0
            t.worker, t.lastAt, t.defusedBy = nil, nil, nil
        end
        st.misses = 0
        st.bonusDone, st.ready, st.completed, st.failed = false, false, false, false
        sendState(ctx, st)
    end,

    stop = function(ctx)
        for _, t in ipairs(ctx.state.targets or {}) do t.worker = nil end
    end,
})
