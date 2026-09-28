--[[ blocks/checkpoint_route/server.lua · objective block "checkpoint_route" (server half)

  What it does
    Drive to a list of checkpoints in order. Each checkpoint counts when a participant is inside its
    radius (in a police vehicle when policeVehicle is on) and, with stopFor > 0, has stayed stopped
    there for stopFor seconds; with stopFor = 0 it is a drive-through gate. Only the current
    checkpoint counts, so a missed one must be driven through before the next one counts.
    Powers Beat Patrol (use = 'random', count = 5, stop 10 s) and EVOC Course (use = 'all',
    drive-through, medal times, contact seconds, fails when the course vehicle is undriveable).
    The server tracks every participant's position each tick (server-side coordinates) to verify the
    stop time, and the course vehicle's engine/body health (undriveable fail, no_contact check).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.checkpoint_route)
    checkpoints        location key: list of vec3/vec4, or a road route { points = { vec3, ... } }
                       (an inline list or route table in the objective also works)
    use                'all' | 'random'                   [Config.Blocks.checkpoint_route.use.default = 'all']
    count              checkpoints used when use = 'random' (required for random)
    radius             metres                             [radius[3] = 10]
    stopFor            seconds stopped inside; 0 = drive through   [stopFor[3] = 10]
    policeVehicle      checkpoint only counts in a police vehicle (Config.PoliceVehicles)  [policeVehicle.default = true]
    medals             false | true | { gold, silver, bronze } seconds; location.medals (a table) overrides
                       [medals.default = false]. With medals the course time decides one medal bonus and
                       run.flags.medals = true is set in prepare (the common fast bonus is skipped).
    contactPenalty     seconds per wall/vehicle contact   [contactPenalty[3] = 2]; added to the course time
                       and taken off the run timer (CP.Runs.adjustTimer)
    timerStart         'first' (course clock starts at checkpoint 1) | 'start' (when the objective starts)  ['first']
    failIfUndriveable  fail the run when the course vehicle becomes undriveable   [true]
    minSeconds [20] · presenceRange [presenceRange[3] = 300] · label
    With use = 'random' a pool point inside location.start (the start marker) is always used first and
    the others follow in the pool's circular order from it ("Start: the first checkpoint").

  Evidence accepted (client -> server through ctx.report; the engine adds coords and time)
    { type = 'checkpoint', index, netId?, vehClass?, model?, try? }   index = the current checkpoint
    { type = 'contact', netId? }        course running, reporter in a vehicle, at most 1 per 1.2 s, 60 counted
    { type = 'undriveable', netId }     the reporter's course vehicle; verified with its engine health

  Bonuses / penalties recorded (shared, via ctx.award)
    medal_gold | medal_silver | medal_bronze   one of them, from course time + contact seconds (medal courses)
    no_contact                                 medal courses: no counted contact and no server-side body damage
  Fail reason keys: block.checkpoint_route.fail_undriveable

  ctx.state
    points = { vec3 }, current = index | nil (finished), done = n, finished, completed, failed,
    medals = { gold, silver, bronze } | nil, trackContacts, contacts, penalty (s), courseStartMs,
    startMs, courseTime, medal, near = { [src] = { cp, since } }, vehicles = { [src] = netId },
    body = { [netId] = { start, min } }, healthy = { [netId] = true }, lastContact = { [src] = ms }, timedOut
]]

local BLOCK = 'checkpoint_route'

local STOP_SLACK      = 4.0    -- metres of position lag allowed around a stop checkpoint
local DRIVE_SLACK     = 12.0   -- metres allowed around a drive-through gate (moving fast + lag)
local DWELL_SLACK     = 2.0    -- seconds of server sampling tolerance on stopFor
local CONTACT_GAP_MS  = 1200   -- at most one counted contact per participant in this window (client: 1.5 s)
local CONTACT_MAX     = 60     -- counted contacts per objective
local BODY_CONTACT    = 10.0   -- body health lost on the course that denies no_contact
local REPORT_ENGINE   = 100.0  -- an 'undriveable' report needs the engine at or below this

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

local function h32(v)
    local n = math.tointeger(tonumber(v) or 0) or 0
    return n & 0xFFFFFFFF
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

-- ── Points ──────────────────────────────────────────────────────────────────
local function resolvePoints(obj, location)
    local list = obj.checkpoints
    if type(list) == 'string' then list = location and location[list] end
    if type(list) ~= 'table' or isVec(list) then return nil end
    if type(list.points) == 'table' then list = list.points end
    local out = {}
    for i = 1, #list do
        if not isVec(list[i]) then return nil end
        out[i] = vec3Of(list[i])
    end
    return out
end

-- The pool point inside the location's start marker, if any (it becomes the first checkpoint).
local function anchorIndex(pool, location)
    local start = type(location) == 'table' and location.start or nil
    if type(start) ~= 'table' or not isVec(start.coords) then return nil end
    local limit = tonumber(start.radius) or 0.0
    local best, bestD
    for i, p in ipairs(pool) do
        local d = CP.U.dist(p, start.coords)
        if d <= limit and (not bestD or d < bestD) then best, bestD = i, d end
    end
    return best
end

-- Indices of the pool to use, in driving order.
local function pickIndices(n, use, count, anchor, rng)
    local out = {}
    if use ~= 'random' then
        for i = 1, n do out[i] = i end
        return out
    end
    count = math.max(0, math.min(count or n, n))
    local pool = {}
    for i = 1, n do
        if i ~= anchor then pool[#pool + 1] = i end
    end
    local want = count
    if anchor and count > 0 then
        out[1] = anchor
        want = count - 1
    end
    for _, i in ipairs(rng:sample(pool, want)) do out[#out + 1] = i end
    local base = anchor or 1
    table.sort(out, function(a, b) return ((a - base) % n) < ((b - base) % n) end)
    return out
end

local function medalTimes(obj, location)
    local m = type(location) == 'table' and location.medals or nil
    if type(m) ~= 'table' then m = obj.medals end
    if type(m) ~= 'table' then return nil end
    local g = tonumber(m.gold or m[1])
    local s = tonumber(m.silver or m[2])
    local b = tonumber(m.bronze or m[3])
    if not g or not s or not b then return nil end
    return { gold = g, silver = s, bronze = b }
end

local function medalsValid(m)
    if type(m) ~= 'table' then return false end
    local g = tonumber(m.gold or m[1])
    local s = tonumber(m.silver or m[2])
    local b = tonumber(m.bronze or m[3])
    return g ~= nil and s ~= nil and b ~= nil and g > 0 and g <= s and s <= b
end

-- ── Vehicles (server natives) ───────────────────────────────────────────────
local function vehicleOf(src, last)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    return GetVehiclePedIsIn(ped, last == true) or 0
end

local function entityOf(netId)
    netId = idx(netId)
    if not netId then return 0 end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return 0 end
    return ent
end

-- Config.PoliceVehicles: models are checked on the server; the class comes from the server native
-- where the runtime provides it, otherwise from the class the client reported with the evidence.
local function policeVehicleOk(veh, ev)
    local pv = Config.PoliceVehicles or {}
    local model = h32(GetEntityModel(veh))
    for _, name in ipairs(pv.models or {}) do
        if h32(joaat(name)) == model then return true end
    end
    local class
    if type(GetVehicleClass) == 'function' then class = GetVehicleClass(veh) end
    if class == nil and type(ev) == 'table' then class = idx(ev.vehClass) end
    if class == nil then return false end
    for _, c in ipairs(pv.classes or {}) do
        if c == class then return true end
    end
    return false
end

local function sampleVehicle(st, netId)
    local ent = entityOf(netId)
    if ent == 0 then return 0, nil end
    local body = tonumber(GetVehicleBodyHealth(ent))
    if body then
        local b = st.body[netId]
        if not b then
            st.body[netId] = { start = body, min = body }
        elseif body < b.min then
            b.min = body
        end
    end
    local engine = tonumber(GetVehicleEngineHealth(ent))
    if engine and engine > 0 then st.healthy[netId] = true end
    return ent, engine
end

local function bodyContact(st)
    for _, b in pairs(st.body) do
        if b.start - b.min >= BODY_CONTACT then return true end
    end
    return false
end

-- ── State ───────────────────────────────────────────────────────────────────
local function ensure(ctx)
    local st = ctx.state
    if st.points then return st end
    local obj = ctx.obj
    local pool = resolvePoints(obj, ctx.location)
    if not pool or #pool == 0 then
        CP.err('blocks', 'checkpoint_route: objective %s has no usable checkpoints (%s)', tostring(ctx.index), tostring(obj.checkpoints))
        pool = {}
        st.broken = true
    end
    local anchor = (obj.use == 'random') and anchorIndex(pool, ctx.location) or nil
    st.points = {}
    for n, i in ipairs(pickIndices(#pool, obj.use, idx(obj.count), anchor, ctx.rng)) do st.points[n] = pool[i] end
    st.current = (#st.points > 0) and 1 or nil
    st.done = 0
    st.medals = medalTimes(obj, ctx.location)
    st.trackContacts = (tonumber(obj.contactPenalty) or 0) > 0 or st.medals ~= nil
    st.contacts, st.penalty = 0, 0
    st.near, st.vehicles, st.lastContact, st.body, st.healthy = {}, {}, {}, {}, {}
    return st
end

local function sendState(ctx, st)
    local pts = {}
    for i, p in ipairs(st.points) do pts[i] = plain(p) end
    local running = st.courseStartMs ~= nil and not st.finished
    ctx.send({
        kind = 'state',
        points = pts,
        current = st.current,
        done = st.done,
        total = #st.points,
        finished = st.finished == true,
        medals = st.medals,
        track = { contacts = st.trackContacts == true, undriveable = ctx.obj.failIfUndriveable == true },
        course = {
            running = running,
            elapsedMs = running and (now() - st.courseStartMs) or 0,
            penalty = st.penalty,
            contacts = st.contacts,
            time = st.courseTime,
            medal = st.medal,
        },
    })
end

local function tryComplete(ctx, st)
    if st.completed then return true end
    local ok = ctx.complete({ time = st.courseTime, medal = st.medal, contacts = st.contacts })
    if ok ~= false then st.completed = true end
    return st.completed
end

local function finish(ctx, st)
    st.finished = true
    st.current = nil
    for _, netId in pairs(st.vehicles) do sampleVehicle(st, netId) end
    local t = now()
    local startMs = st.courseStartMs or st.startMs or t
    st.courseTime = math.max(0, (t - startMs) / 1000) + (st.penalty or 0)
    if st.medals then
        local m = st.medals
        local medal = (st.courseTime <= m.gold and 'gold')
            or (st.courseTime <= m.silver and 'silver')
            or (st.courseTime <= m.bronze and 'bronze')
            or nil
        st.medal = medal
        if medal then ctx.award('medal_' .. medal) end
        if st.contacts == 0 and not bodyContact(st) then
            st.noContact = true
            ctx.award('no_contact')
        end
    end
end

-- ── Evidence ────────────────────────────────────────────────────────────────
local function onCheckpoint(ctx, st, src, ev)
    local k = idx(ev.index)
    if not k then return false, 'bad_index' end
    if st.finished or k < (st.current or 0) then return false, 'already_done' end
    if k ~= st.current then return false, 'out_of_order' end
    local cp = st.points[k]
    local c = ctx.coords(src)
    if not c then return false, 'no_coords' end
    local obj = ctx.obj
    local stopFor = tonumber(obj.stopFor) or 0
    local radius = tonumber(obj.radius) or 10.0
    local slack = stopFor > 0 and STOP_SLACK or DRIVE_SLACK
    if CP.U.dist(c, cp) > radius + slack then return false, 'too_far' end
    local veh = vehicleOf(src)
    if obj.policeVehicle ~= false then
        if veh == 0 then return false, 'not_in_vehicle' end
        if not policeVehicleOk(veh, ev) then return false, 'not_police_vehicle' end
    end
    if stopFor > 0 then
        local n = st.near[src]
        if not n or n.cp ~= k then
            st.near[src] = { cp = k, since = now() }
            n = st.near[src]
        end
        if (now() - n.since) / 1000 < stopFor - DWELL_SLACK then return false, 'not_held' end
    end

    st.done = k
    st.current = k + 1
    st.near = {}
    if veh ~= 0 then
        local netId = NetworkGetNetworkIdFromEntity(veh)
        if netId and netId ~= 0 then
            st.vehicles[src] = netId
            sampleVehicle(st, netId)
        end
    end
    if k == 1 and not st.courseStartMs then st.courseStartMs = now() end
    if k >= #st.points then finish(ctx, st) end
    sendState(ctx, st)
    if st.finished then tryComplete(ctx, st) end
    return true
end

local function onContact(ctx, st, src, ev)
    if not st.trackContacts then return false, 'not_tracked' end
    if not st.courseStartMs or st.finished then return false, 'course_not_running' end
    if vehicleOf(src) == 0 then return false, 'not_in_vehicle' end
    local t = now()
    local last = st.lastContact[src]
    if last and t - last < CONTACT_GAP_MS then return false, 'rate' end
    if st.contacts >= CONTACT_MAX then return false, 'cap' end
    st.lastContact[src] = t
    st.contacts = st.contacts + 1
    local pen = tonumber(ctx.obj.contactPenalty) or 0
    if pen > 0 then
        st.penalty = st.penalty + pen
        CP.Runs.adjustTimer(ctx.run, -pen)
    end
    sendState(ctx, st)
    return true
end

local function onUndriveable(ctx, st, src, ev)
    if ctx.obj.failIfUndriveable ~= true then return false, 'not_tracked' end
    if st.finished then return false, 'already_done' end
    local netId = idx(ev.netId)
    local ent = entityOf(netId)
    if ent == 0 then return false, 'no_vehicle' end
    local mine = st.vehicles[src] == netId or vehicleOf(src) == ent or vehicleOf(src, true) == ent
    if not mine then return false, 'not_course_vehicle' end
    local engine = tonumber(GetVehicleEngineHealth(ent))
    local tank = type(GetVehiclePetrolTankHealth) == 'function' and tonumber(GetVehiclePetrolTankHealth(ent)) or nil
    local wrecked = (engine ~= nil and engine <= REPORT_ENGINE) or (tank ~= nil and tank <= 0 and st.healthy[netId] == true)
    if not wrecked then return false, 'vehicle_ok' end
    st.failed = true
    ctx.fail('block.checkpoint_route.fail_undriveable')
    return true
end

-- ── Block ───────────────────────────────────────────────────────────────────
local function applyDefaults(obj)
    local c = cfg()
    if obj.minSeconds == nil then obj.minSeconds = 20 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.label == nil then obj.label = CP.L('block.checkpoint_route.label') end
    if obj.use == nil then obj.use = c.use.default end
    if obj.radius == nil then obj.radius = c.radius[3] + 0.0 end
    if obj.stopFor == nil then obj.stopFor = c.stopFor[3] end
    if obj.policeVehicle == nil then obj.policeVehicle = c.policeVehicle.default end
    if obj.medals == nil then obj.medals = c.medals.default end
    if obj.contactPenalty == nil then obj.contactPenalty = c.contactPenalty[3] end
    if obj.timerStart == nil then obj.timerStart = 'first' end
    if obj.failIfUndriveable == nil then obj.failIfUndriveable = true end
    return obj
end

CP.Blocks.register(BLOCK, {
    defaults = applyDefaults,

    validate = function(obj, mission, location)
        local c = cfg()
        if type(obj) ~= 'table' then return bad('block.checkpoint_route.invalid.objective') end
        obj = applyDefaults(CP.U.deepcopy(obj))
        if type(obj.checkpoints) ~= 'string' and type(obj.checkpoints) ~= 'table' then
            return bad('block.checkpoint_route.invalid.checkpoints')
        end
        if not CP.U.contains(c.use.options, obj.use) then return bad('block.checkpoint_route.invalid.use') end
        if obj.use == 'random' then
            local n = idx(obj.count)
            if not n or not inRange(n, c.checkpoints) then
                return bad('block.checkpoint_route.invalid.range', { field = 'count', min = c.checkpoints[1], max = c.checkpoints[2] })
            end
        end
        if not inRange(obj.radius, c.radius) then
            return bad('block.checkpoint_route.invalid.range', { field = 'radius', min = c.radius[1], max = c.radius[2] })
        end
        if not inRange(obj.stopFor, c.stopFor) then
            return bad('block.checkpoint_route.invalid.range', { field = 'stopFor', min = c.stopFor[1], max = c.stopFor[2] })
        end
        if not inRange(obj.contactPenalty, c.contactPenalty) then
            return bad('block.checkpoint_route.invalid.range', { field = 'contactPenalty', min = c.contactPenalty[1], max = c.contactPenalty[2] })
        end
        if not inRange(obj.presenceRange, c.presenceRange) then
            return bad('block.checkpoint_route.invalid.range', { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
        end
        if type(obj.minSeconds) ~= 'number' or obj.minSeconds < 0 then
            return bad('block.checkpoint_route.invalid.min_seconds')
        end
        if type(obj.policeVehicle) ~= 'boolean' or type(obj.failIfUndriveable) ~= 'boolean' then
            return bad('block.checkpoint_route.invalid.flags')
        end
        if obj.timerStart ~= 'first' and obj.timerStart ~= 'start' then
            return bad('block.checkpoint_route.invalid.timer_start')
        end
        if obj.medals ~= false and obj.medals ~= true and not medalsValid(obj.medals) then
            return bad('block.checkpoint_route.invalid.medals')
        end
        local locations = {}
        if type(location) == 'table' then
            locations[1] = location
        elseif type(mission) == 'table' and type(mission.locations) == 'table' then
            locations = mission.locations
        end
        for li, loc in ipairs(locations) do
            local pts = resolvePoints(obj, loc)
            if not pts then
                return bad('block.checkpoint_route.invalid.points_missing', { key = tostring(obj.checkpoints), location = li })
            end
            local used = (obj.use == 'random') and idx(obj.count) or #pts
            if #pts < used or not inRange(used, c.checkpoints) then
                return bad('block.checkpoint_route.invalid.points_count', { location = li, min = c.checkpoints[1], max = c.checkpoints[2], have = #pts })
            end
            for _, p in ipairs(pts) do
                if inNoBuild(p) then return bad('block.checkpoint_route.invalid.points_zone', { location = li }) end
            end
            if loc.medals ~= nil and not medalsValid(loc.medals) then
                return bad('block.checkpoint_route.invalid.medals')
            end
            if obj.medals == true and loc.medals == nil then
                return bad('block.checkpoint_route.invalid.location_medals', { location = li })
            end
        end
        return true
    end,

    armedCount = function(obj)
        return 0
    end,

    requiredPoints = function(obj)
        if type(obj.checkpoints) == 'string' then return { obj.checkpoints } end
        return {}
    end,

    prepare = function(ctx)
        local st = ensure(ctx)
        if st.medals then
            ctx.run.flags = ctx.run.flags or {}
            ctx.run.flags.medals = true
        end
    end,

    start = function(ctx)
        local st = ensure(ctx)
        st.startMs = now()
        if ctx.obj.timerStart == 'start' and not st.courseStartMs then st.courseStartMs = st.startMs end
        st.resent = false
        if #st.points == 0 then
            finish(ctx, st)
        end
        sendState(ctx, st)
        if st.finished then tryComplete(ctx, st) end
    end,

    tick = function(ctx, dt)
        local st = ensure(ctx)
        if st.completed or st.failed then return end
        if not st.resent then
            st.resent = true
            sendState(ctx, st)
        end
        if st.finished then
            tryComplete(ctx, st)
            return
        end
        -- Server-side stop timing: who is inside the current checkpoint, and since when.
        local cp = st.points[st.current]
        local reach = (tonumber(ctx.obj.radius) or 10.0) + STOP_SLACK
        local t = now()
        for _, src in ipairs(ctx.participants()) do
            local c = ctx.coords(src)
            if c and cp and CP.U.dist(c, cp) <= reach then
                local n = st.near[src]
                if not n or n.cp ~= st.current then st.near[src] = { cp = st.current, since = t } end
            else
                st.near[src] = nil
            end
        end
        -- Course vehicles: body health for no_contact, engine health for the undriveable fail.
        if st.courseStartMs then
            for _, netId in pairs(st.vehicles) do
                local ent, engine = sampleVehicle(st, netId)
                if ctx.obj.failIfUndriveable == true and ent ~= 0 and engine and engine <= 0 and st.healthy[netId] then
                    st.failed = true
                    ctx.fail('block.checkpoint_route.fail_undriveable')
                    return
                end
            end
        end
    end,

    onEvent = function(ctx, src, ev)
        local st = ensure(ctx)
        if type(ev) ~= 'table' then return false, 'bad_event' end
        if st.completed or st.failed then return false, 'objective_over' end
        if ev.type == 'checkpoint' then return onCheckpoint(ctx, st, src, ev) end
        if ev.type == 'contact' then return onContact(ctx, st, src, ev) end
        if ev.type == 'undriveable' then return onUndriveable(ctx, st, src, ev) end
        return false, 'unknown_event'
    end,

    -- This block spawns no peds or vehicles, so no entity of this objective can die.
    onEntityDead = function(ctx, netId, killerSrc)
        return nil
    end,

    onParticipantLeft = function(ctx, src)
        local st = ensure(ctx)
        st.near[src] = nil
        st.vehicles[src] = nil
        st.lastContact[src] = nil
    end,

    -- Only a scaled random count can shrink: checkpoints not reached yet are dropped from the end.
    rescale = function(ctx)
        local st = ensure(ctx)
        if st.finished or ctx.obj.use ~= 'random' then return end
        local want = idx(ctx.obj.count)
        if not want then return end
        local keep = math.max(want, st.done + 1, 2)
        if keep >= #st.points then return end
        for i = #st.points, keep + 1, -1 do st.points[i] = nil end
        sendState(ctx, st)
    end,

    -- The time limit fails the run (no alternative outcome for this block).
    onTimeout = function(ctx)
        ensure(ctx).timedOut = true
        return nil
    end,

    -- The next checkpoint or the nearest other participant, whichever is closer.
    presence = function(ctx, src, coords)
        local st = ensure(ctx)
        local cp = st.points[st.current or 0] or st.points[#st.points]
        local best = cp and CP.U.dist(coords, cp) or 0.0
        for _, other in ipairs(ctx.participants()) do
            if other ~= src then
                local oc = ctx.coords(other)
                if oc then best = math.min(best, CP.U.dist(coords, oc)) end
            end
        end
        return best
    end,

    checklist = function(ctx)
        local st = ensure(ctx)
        return {
            { label = CP.L('block.checkpoint_route.checklist'), done = st.finished == true, value = st.done, max = #st.points },
        }
    end,

    restart = function(ctx)
        local st = ensure(ctx)
        st.current = (#st.points > 0) and 1 or nil
        st.done = 0
        st.finished, st.completed, st.failed = false, false, false
        st.contacts, st.penalty = 0, 0
        st.courseTime, st.medal, st.noContact = nil, nil, nil
        st.startMs = now()
        st.courseStartMs = (ctx.obj.timerStart == 'start') and st.startMs or nil
        st.near, st.vehicles, st.lastContact, st.body, st.healthy = {}, {}, {}, {}, {}
        sendState(ctx, st)
    end,

    stop = function(ctx)
        local st = ctx.state
        st.near, st.lastContact = {}, {}
    end,
})
