-- Objective block "process_scene" (server half): the coroner step. Bodies of NPCs who died in the run are kept
-- (CP.Runs.holdBodies), photographed and tagged, bagged, then released to the coroner van or at the scene marker.

local BLOCK = 'process_scene'
local U = CP.U

local REACH = 2.5                        -- metres from the body (tag, bag) or the van's rear doors (release)
local VAN_REACH = 6.0
local REACH_SLACK = 1.0
local EARLY_SLACK_MS = 500               -- a finish may come this early
local DWELL_SLACK_MS = 2000              -- the officer must have stayed in reach for the duration minus this
local DEFAULT_ROLES = { 'hostile', 'suspect', 'associate', 'inmate', 'boss', 'subject' }

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v end
local function InRange(v, r, scale)
    scale = scale or 1
    return IsNum(v) and type(r) == 'table' and v >= r[1] * scale - 1e-9 and v <= r[2] * scale + 1e-9
end

local function Bad(key, vars) return false, CP.L(key, vars) end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return IsNum(x) and IsNum(y) and IsNum(z)
end

local function PointOf(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if IsVec(v) then return v end
    if type(v) == 'table' and IsVec(v[1]) then return v[1] end
    return nil
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function TrustedFile(ctx)
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    return type(m) == 'table' and m.source == 'builtin'
end

local function EntCoords(ctx, netId)
    local e = ctx.run.entities[netId]
    if e and e.entity and DoesEntityExist(e.entity) then return GetEntityCoords(e.entity) end
    return nil
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Step(t, labelKey, seconds)
    if type(t) ~= 'table' then t = {} end
    if t.label == nil then t.label = CP.L(labelKey) end
    if t.duration == nil then t.duration = seconds * 1000 end
    return t
end

local function Defaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 5 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.scene == nil then obj.scene = 'scene' end
    if obj.coroner == nil then obj.coroner = c.coroner.default and 'coroner' or false end
    if obj.bodies == nil then obj.bodies = c.bodies[3] end
    if obj.roles == nil then obj.roles = U.copy(DEFAULT_ROLES) end
    obj.tag = Step(obj.tag, 'block.process_scene.tag', c.tagTime[3])
    obj.bag = Step(obj.bag, 'block.process_scene.bag', c.bagTime[3])
    obj.release = Step(obj.release, 'block.process_scene.release', c.releaseTime[3])
    if type(obj.aliveBonus) ~= 'table' then obj.aliveBonus = { id = 'all_taken_alive', points = 15 } end
    if obj.aliveBonus.id == nil then obj.aliveBonus.id = 'all_taken_alive' end
    return obj
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.process_scene.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.process_scene.invalid.min_seconds') end
    if not InRange(o.presenceRange, c.presenceRange) then
        return Bad('block.process_scene.invalid.range',
            { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if not IsNum(o.bodies) or math.floor(o.bodies) ~= o.bodies or not InRange(o.bodies, c.bodies) then
        return Bad('block.process_scene.invalid.range', { field = 'bodies', min = c.bodies[1], max = c.bodies[2] })
    end
    for _, k in ipairs({ { 'tag', c.tagTime }, { 'bag', c.bagTime }, { 'release', c.releaseTime } }) do
        local step = o[k[1]]
        if type(step.label) ~= 'string' or not IsNum(step.duration) or step.duration <= 0 then
            return Bad('block.process_scene.invalid.step', { field = k[1] })
        end
        if strict and not InRange(step.duration, k[2], 1000) then
            return Bad('block.process_scene.invalid.range',
                { field = k[1] .. '.duration', min = k[2][1] * 1000, max = k[2][2] * 1000 })
        end
    end
    if type(o.roles) ~= 'table' then return Bad('block.process_scene.invalid.objective') end
    if type(o.aliveBonus.id) ~= 'string' or (strict and o.aliveBonus.points ~= nil) then
        return Bad('block.process_scene.invalid.alive_bonus')
    end
    local function check(loc, li)
        local p = PointOf(loc, o.scene)
        if not p then return Bad('block.process_scene.invalid.scene', { location = li }) end
        if InNoBuild(p) then return Bad('block.process_scene.invalid.points_zone', { location = li }) end
        local v = o.coroner and PointOf(loc, o.coroner)
        if v and InNoBuild(v) then return Bad('block.process_scene.invalid.points_zone', { location = li }) end
        return true
    end
    if type(location) == 'table' then return check(location, 1) end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            local ok, why = check(loc, li)
            if not ok then return false, why end
        end
    end
    return true
end

-- ============================================================================
--                                  RUN STATE
-- ============================================================================

local function StateOf(ctx)
    Defaults(ctx.obj)
    local st = ctx.state
    if not st.block then
        st.block = BLOCK
        st.bodies = {}             -- [netId] = { netId, coords, tagged, bagged, bag }
        st.order = {}
        st.begins = {}             -- [src] = { kind, netId, at, since }
    end
    return st
end

local function ScenePoint(ctx)
    return PointOf(ctx.location, ctx.obj.scene) or (ctx.location and ctx.location.start and ctx.location.start.coords)
end

local function Counts(st)
    local tagged, bagged = 0, 0
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        if b.tagged then tagged = tagged + 1 end
        if b.bagged then bagged = bagged + 1 end
    end
    return tagged, bagged, #st.order
end

local function Flush(ctx, st)
    local list = {}
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        list[#list + 1] = { netId = netId, tagged = b.tagged, bagged = b.bagged, bag = b.bag }
    end
    local van = nil
    if st.service then
        local status, veh = CP.Custody.serviceStatus(st.service)
        van = { status = status, netId = veh }
    end
    ctx.send({
        bodies = list,
        released = st.released == true,
        van = van,
        scene = ScenePoint(ctx),
        coroner = ctx.obj.coroner ~= false,
    })
    local tagged, bagged, total = Counts(st)
    local text
    if total == 0 then
        text = CP.Lt('block.process_scene.detail_none')
    elseif bagged < total then
        text = CP.Lt('block.process_scene.detail', { tagged = tagged, bagged = bagged, total = total })
    else
        text = CP.Lt('block.process_scene.detail_release')
    end
    ctx.hud({ detail = text, value = bagged, max = total })
end

local function Complete(ctx, st)
    if st.completed then return end
    if ctx.complete({ bodies = #st.order }) ~= false then st.completed = true end
end

-- ============================================================================
--                               THE THREE STEPS
-- ============================================================================

local function VanPoint(ctx, st)
    if not st.service then return nil end
    local status, veh = CP.Custody.serviceStatus(st.service)
    if status ~= 'parked' then return nil end
    return EntCoords(ctx, veh)
end

-- Where src must stand for a step: the body, or the van (the scene marker when the van is off).
local function TargetOf(ctx, st, kind, netId)
    if kind == 'release' then
        if ctx.obj.coroner == false or not st.service then return ScenePoint(ctx), VAN_REACH end
        return VanPoint(ctx, st), VAN_REACH
    end
    local b = st.bodies[netId]
    if not b then return nil end
    return EntCoords(ctx, netId) or b.coords, REACH
end

local function Near(ctx, src, point, reach)
    local sc = ctx.coords(src)
    return sc ~= nil and point ~= nil and U.dist(sc, point) <= reach + REACH_SLACK
end

local function StepOk(ctx, st, kind, netId)
    if kind == 'tag' then
        local b = st.bodies[netId]
        return b ~= nil and not b.tagged
    elseif kind == 'bag' then
        local b = st.bodies[netId]
        return b ~= nil and b.tagged and not b.bagged
    elseif kind == 'release' then
        local _, bagged, total = Counts(st)
        return not st.released and bagged >= total and total > 0
    end
    return false
end

local function Bag(ctx, st, b)
    local coords = EntCoords(ctx, b.netId) or b.coords
    local model = (Config.Custody and Config.Custody.coroner and Config.Custody.coroner.bagProp) or 'xm_prop_body_bag'
    CP.Runs.releaseBody(ctx.run, b.netId)
    b.bagged = true
    if coords then
        local _, bagNet = ctx.spawnObject({ model = model, coords = coords, role = 'body_bag', tag = 'bag' })
        b.bag = bagNet
    end
end

local function Release(ctx, st)
    st.released = true
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        if b.bag then ctx.delete(b.bag) end
    end
    if st.service then CP.Custody.releaseService(ctx.run, st.service) end
end

local function OnStep(ctx, st, src, ev, kind, finish)
    local netId = tonumber(ev.netId)
    if not StepOk(ctx, st, kind, netId) then return false, 'wrong_state' end
    local point, reach = TargetOf(ctx, st, kind, netId)
    if not point then return false, 'not_ready' end
    if not Near(ctx, src, point, reach) then return false, 'too_far' end
    if not finish then
        st.begins[src] = { kind = kind, netId = netId, at = Now(), since = Now() }
        return true
    end
    local bg = st.begins[src]
    st.begins[src] = nil
    if not bg or bg.kind ~= kind or bg.netId ~= netId then return false, 'not_started' end
    local duration = tonumber(ctx.obj[kind].duration) or 0
    local t = Now()
    if t - bg.at < duration - EARLY_SLACK_MS then return false, 'too_fast' end
    if not bg.since or t - bg.since < duration - DWELL_SLACK_MS then return false, 'too_far' end
    if kind == 'tag' then
        st.bodies[netId].tagged = true
        st.bodies[netId].taggedBy = src
    elseif kind == 'bag' then
        Bag(ctx, st, st.bodies[netId])
    else
        Release(ctx, st)
    end
    return true
end

local function SampleBegins(ctx, st)
    for src, bg in pairs(st.begins) do
        local point, reach = TargetOf(ctx, st, bg.kind, bg.netId)
        if Near(ctx, src, point, reach) then
            bg.since = bg.since or Now()
        else
            bg.since = nil
        end
    end
end

local STEP_EVENTS = {
    tag_begin = { 'tag', false },
    tag = { 'tag', true },
    bag_begin = { 'bag', false },
    bag = { 'bag', true },
    release_begin = { 'release', false },
    release = { 'release', true },
}

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local step = STEP_EVENTS[ev.type]
    if not step then return false, 'unknown_event' end
    local ok, why = OnStep(ctx, st, src, ev, step[1], step[2])
    if ok and st.released then Complete(ctx, st) end
    Flush(ctx, st)
    return ok, why
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Prepare(ctx)
    StateOf(ctx)
    CP.Runs.holdBodies(ctx.run, { roles = ctx.obj.roles, max = ctx.obj.bodies })
end

local function Start(ctx)
    local st = StateOf(ctx)
    st.stopped = nil
    CP.Runs.pauseFastClock(ctx.run)
    for _, h in ipairs(CP.Runs.heldBodies(ctx.run)) do
        if not st.bodies[h.netId] then
            st.bodies[h.netId] = { netId = h.netId, coords = h.coords, tagged = false, bagged = false }
            st.order[#st.order + 1] = h.netId
        end
    end
    if #st.order == 0 then
        -- nobody died: nothing to process, so no minimum time either; killing is never worth more than arresting
        local ab = ctx.obj.aliveBonus
        ctx.award(ab.id, { count = 1, points = TrustedFile(ctx) and ab.points or nil })
        ctx.obj.minSeconds = 0
        Flush(ctx, st)
        Complete(ctx, st)
        return
    end
    if ctx.obj.coroner ~= false then
        local scene = ScenePoint(ctx)
        local park = PointOf(ctx.location, ctx.obj.coroner) or scene
        st.service = CP.Custody.serviceVehicle(ctx.run, 'coroner', scene, { obj = ctx.index, point = park })
    end
    Flush(ctx, st)
end

local function Tick(ctx)
    local st = StateOf(ctx)
    if st.stopped or st.completed then return end
    -- a kept body another rule deleted (the FIFO limit, a script) is gone from the list
    local held = {}
    for _, h in ipairs(CP.Runs.heldBodies(ctx.run)) do held[h.netId] = true end
    local keep = {}
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        if b.bagged or held[netId] then
            keep[#keep + 1] = netId
        else
            st.bodies[netId] = nil
        end
    end
    st.order = keep
    SampleBegins(ctx, st)
    if #st.order == 0 and not st.released then st.released = true end
    if st.released then Complete(ctx, st) end
    Flush(ctx, st)
end

local function Presence(ctx, src, coords)
    local st = StateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        local c = EntCoords(ctx, netId) or b.coords
        if c then
            local d = U.dist(coords, c)
            if d < best then best = d end
        end
    end
    if best == math.huge then
        local ref = ScenePoint(ctx)
        best = ref and U.dist(coords, ref) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local tagged, bagged, total = Counts(st)
    return {
        { label = CP.L('block.process_scene.check_tagged'), done = tagged >= total, value = tagged, max = total },
        { label = CP.L('block.process_scene.check_bagged'), done = bagged >= total, value = bagged, max = total },
        {
            label = CP.L('block.process_scene.check_released'),
            done = st.released == true,
            value = st.released and 1 or 0,
            max = 1,
        },
    }
end

local function Stop(ctx)
    local st = StateOf(ctx)
    st.stopped = true
    for _, netId in ipairs(st.order) do
        local b = st.bodies[netId]
        if b.bag then ctx.delete(b.bag) end
        if not b.bagged then CP.Runs.releaseBody(ctx.run, netId) end
    end
    if st.service then CP.Custody.releaseService(ctx.run, st.service) end
end

CP.Blocks.register(BLOCK, {
    defaults = Defaults,
    validate = Validate,
    armedCount = function() return 0 end,
    requiredPoints = function(obj)
        local o = Defaults(U.deepcopy(obj))
        return { o.scene }
    end,
    prepare = Prepare,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    onParticipantLeft = function(ctx, src)
        local st = StateOf(ctx)
        st.begins[src] = nil
    end,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    restart = function(ctx)
        local st = StateOf(ctx)
        for k in pairs(st) do st[k] = nil end
        Start(ctx)
    end,
    stop = Stop,
})
