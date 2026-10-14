-- Objective block "checkpoint_route" (server half)

local BLOCK = 'checkpoint_route'

local STOP_SLACK = 4.0         -- metres of position lag allowed around a stop checkpoint
local DRIVE_SLACK = 12.0       -- metres allowed around a drive-through gate (moving fast + lag)
local DWELL_SLACK = 2.0        -- seconds of server sampling tolerance on stopFor
local CONTACT_GAP_MS = 1200    -- at most one counted contact per participant in this window (client: 1.5 s)
local CONTACT_MAX = 60         -- counted contacts per objective
local BODY_CONTACT = 10.0      -- body health lost on the course that denies no_contact
local REPORT_ENGINE = 100.0    -- an 'undriveable' report needs the engine at or below this
local SERVER_STOP_SPEED = 3.0  -- m/s on the server's copy of the entity that still counts as stopped (client: 1.5)
local PRESTART_GRACE = 120     -- s the run timer may wait at the start marker for checkpoint 1 (timerStart = 'first')
-- EVOC Course card: "Gold medal +50, Silver +25, Bronze +10 (replaces the common time bonus); no contact at
-- all +10". Passed as the trusted per-occurrence hint of each award, so a medal course is worth its card
-- values on a mission whose file does not list the ids (every custom mission: Config.Bonuses has no medal
-- or no_contact entry); a file that lists them with its own points keeps those (built-ins). Capped by
-- Config.Builder.bonusCap.points on custom missions.
local CARD_POINTS = { medal_gold = 50, medal_silver = 25, medal_bronze = 10, no_contact = 10 }

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- A card value passed as a points hint; at most Config.Builder.bonusCap.points on non-built-in missions.
local function CardPoints(ctx, v)
    if type(v) ~= 'number' then return nil end
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    if not (type(m) == 'table' and m.source == 'builtin') then
        local cap = tonumber(Config.Builder and Config.Builder.bonusCap and Config.Builder.bonusCap.points)
        if cap and v > cap then v = cap end
    end
    return v
end

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
--                                    POINTS
-- ============================================================================

local function ResolvePoints(obj, location)
    local list = obj.checkpoints
    if type(list) == 'string' then list = location and location[list] end
    if type(list) ~= 'table' or IsVec(list) then return nil end
    if type(list.points) == 'table' then list = list.points end
    local out = {}
    for i = 1, #list do
        if not IsVec(list[i]) then return nil end
        out[i] = Vec3Of(list[i])
    end
    return out
end

-- The pool point inside the location's start marker, if any (it becomes the first checkpoint).
local function AnchorIndex(pool, location)
    local start = type(location) == 'table' and location.start or nil
    if type(start) ~= 'table' or not IsVec(start.coords) then return nil end
    local limit = tonumber(start.radius) or 0.0
    local best, bestD
    for i, p in ipairs(pool) do
        local d = CP.U.dist(p, start.coords)
        if d <= limit and (not bestD or d < bestD) then best, bestD = i, d end
    end
    return best
end

-- Indices of the pool to use, in driving order.
local function PickIndices(n, use, count, anchor, rng)
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

local function MedalTimes(obj, location)
    local m = type(location) == 'table' and location.medals or nil
    if type(m) ~= 'table' then m = obj.medals end
    if type(m) ~= 'table' then return nil end
    local g = tonumber(m.gold or m[1])
    local s = tonumber(m.silver or m[2])
    local b = tonumber(m.bronze or m[3])
    if not g or not s or not b then return nil end
    return { gold = g, silver = s, bronze = b }
end

local function MedalsValid(m)
    if type(m) ~= 'table' then return false end
    local g = tonumber(m.gold or m[1])
    local s = tonumber(m.silver or m[2])
    local b = tonumber(m.bronze or m[3])
    return g ~= nil and s ~= nil and b ~= nil and g > 0 and g <= s and s <= b
end

-- ============================================================================
--                          VEHICLES (server natives)
-- ============================================================================

local function VehicleOf(src, last)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    return GetVehiclePedIsIn(ped, last == true) or 0
end

local function EntityOf(netId)
    netId = Idx(netId)
    if not netId then return 0 end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return 0 end
    return ent
end

-- The vehicle the participant is DRIVING as the server sees it, or 0: in a vehicle and in its driver seat
-- (server natives only; any vehicle counts). Nothing the client reports is used.
local function DrivenVehicle(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    local veh = GetVehiclePedIsIn(ped, false) or 0
    if veh == 0 then return 0 end
    if GetPedInVehicleSeat(veh, -1) ~= ped then return 0 end
    return veh
end

-- vehicleRequired, with the old policeVehicle name as an alias (published files may still use it).
local function VehicleRequired(obj)
    if obj.vehicleRequired ~= nil then return obj.vehicleRequired ~= false end
    return obj.policeVehicle ~= false
end

local function SampleVehicle(st, netId)
    local ent = EntityOf(netId)
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

local function BodyContact(st)
    for _, b in pairs(st.body) do
        if b.start - b.min >= BODY_CONTACT then return true end
    end
    return false
end

-- "Stopped inside the marker" as the server sees it: driving a vehicle when one is required, and the vehicle
-- (or the ped on foot or as a passenger) no faster than SERVER_STOP_SPEED (server GetEntitySpeed works for
-- networked entities).
local function StoppedNow(ctx, src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local veh
    if VehicleRequired(ctx.obj) then
        veh = DrivenVehicle(src)
        if veh == 0 then return false end
    else
        veh = GetVehiclePedIsIn(ped, false) or 0
    end
    local speed = tonumber(GetEntitySpeed(veh ~= 0 and veh or ped)) or 0.0
    return speed <= SERVER_STOP_SPEED
end

-- ============================================================================
--                                RUN TIMER HOLD
-- ============================================================================
-- EVOC: "the timer starts at the first checkpoint".

local function WantsHold(ctx, st)
    return ctx.obj.timerStart == 'first' and st.medals ~= nil and ctx.index == 1 and #st.points > 0
end

local function HoldTimer(ctx, st, on)
    if (st.timerHeld == true) == (on == true) then return end
    if type(CP.Runs) ~= 'table' or type(CP.Runs.pauseTimer) ~= 'function' then return end
    if on then
        local timer = ctx.run and ctx.run.timer
        if type(timer) == 'table' and timer.paused then
            return
        end -- paused by somebody else (test controls)
    end
    st.timerHeld = on == true
    CP.Runs.pauseTimer(ctx.run, on == true)
end

-- ============================================================================
--                                    STATE
-- ============================================================================

local function Ensure(ctx)
    local st = ctx.state
    if st.points then return st end
    local obj = ctx.obj
    local pool = ResolvePoints(obj, ctx.location)
    if not pool or #pool == 0 then
        CP.err('blocks', 'checkpoint_route: objective %s has no usable checkpoints (%s)', tostring(ctx.index),
            tostring(obj.checkpoints))
        pool = {}
        st.broken = true
    end
    local anchor = (obj.use == 'random') and AnchorIndex(pool, ctx.location) or nil
    st.points = {}
    for n, i in ipairs(PickIndices(#pool, obj.use, Idx(obj.count), anchor, ctx.rng)) do st.points[n] = pool[i] end
    st.current = (#st.points > 0) and 1 or nil
    st.done = 0
    st.medals = MedalTimes(obj, ctx.location)
    st.trackContacts = (tonumber(obj.contactPenalty) or 0) > 0 or st.medals ~= nil
    st.contacts, st.penalty = 0, 0
    st.near, st.vehicles, st.lastContact, st.body, st.healthy = {}, {}, {}, {}, {}
    return st
end

local function SendState(ctx, st)
    local pts = {}
    for i, p in ipairs(st.points) do pts[i] = Plain(p) end
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
            elapsedMs = running and (Now() - st.courseStartMs) or 0,
            penalty = st.penalty,
            contacts = st.contacts,
            time = st.courseTime,
            medal = st.medal,
            held = st.timerHeld == true,
        },
    })
end

local function TryComplete(ctx, st)
    if st.completed then return true end
    local ok = ctx.complete({ time = st.courseTime, medal = st.medal, contacts = st.contacts })
    if ok ~= false then st.completed = true end
    return st.completed
end

local function Finish(ctx, st)
    st.finished = true
    st.current = nil
    HoldTimer(ctx, st, false)
    for _, netId in pairs(st.vehicles) do SampleVehicle(st, netId) end
    local t = Now()
    local startMs = st.courseStartMs or st.startMs or t
    st.courseTime = math.max(0, (t - startMs) / 1000) + (st.penalty or 0)
    if st.medals then
        local m = st.medals
        local medal = (st.courseTime <= m.gold and 'gold') or (st.courseTime <= m.silver and 'silver')
            or (st.courseTime <= m.bronze and 'bronze') or nil
        st.medal = medal
        if medal then
            ctx.award('medal_' .. medal, { count = 1, points = CardPoints(ctx, CARD_POINTS['medal_' .. medal]) })
        end
        if st.contacts == 0 and not BodyContact(st) then
            st.noContact = true
            ctx.award('no_contact', { count = 1, points = CardPoints(ctx, CARD_POINTS.no_contact) })
        end
    end
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnCheckpoint(ctx, st, src, ev)
    local k = Idx(ev.index)
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
    local veh
    if VehicleRequired(obj) then
        if VehicleOf(src) == 0 then return false, 'not_in_vehicle' end
        veh = DrivenVehicle(src)
        if veh == 0 then return false, 'not_driving' end
    else
        veh = VehicleOf(src)
    end
    if stopFor > 0 then
        local n = st.near[src]
        if not n or n.cp ~= k then
            st.near[src] = { cp = k, since = Now() }
            n = st.near[src]
        end
        if (Now() - n.since) / 1000 < stopFor - DWELL_SLACK then return false, 'not_held' end
    end

    st.done = k
    st.current = k + 1
    st.near = {}
    if veh ~= 0 then
        local netId = NetworkGetNetworkIdFromEntity(veh)
        if netId and netId ~= 0 then
            st.vehicles[src] = netId
            SampleVehicle(st, netId)
        end
    end
    if k == 1 and not st.courseStartMs then st.courseStartMs = Now() end
    HoldTimer(ctx, st, false)
    if k >= #st.points then Finish(ctx, st) end
    SendState(ctx, st)
    if st.finished then TryComplete(ctx, st) end
    return true
end

local function OnContact(ctx, st, src, ev)
    if not st.trackContacts then return false, 'not_tracked' end
    if not st.courseStartMs or st.finished then return false, 'course_not_running' end
    if VehicleOf(src) == 0 then return false, 'not_in_vehicle' end
    local t = Now()
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
    SendState(ctx, st)
    return true
end

local function OnUndriveable(ctx, st, src, ev)
    if ctx.obj.failIfUndriveable ~= true then return false, 'not_tracked' end
    if st.finished then return false, 'already_done' end
    local netId = Idx(ev.netId)
    local ent = EntityOf(netId)
    if ent == 0 then return false, 'no_vehicle' end
    local mine = st.vehicles[src] == netId or VehicleOf(src) == ent or VehicleOf(src, true) == ent
    if not mine then return false, 'not_course_vehicle' end
    local engine = tonumber(GetVehicleEngineHealth(ent))
    local tank = type(GetVehiclePetrolTankHealth) == 'function' and tonumber(GetVehiclePetrolTankHealth(ent)) or nil
    local wrecked = (engine ~= nil and engine <= REPORT_ENGINE)
        or (tank ~= nil and tank <= 0 and st.healthy[netId] == true)
    if not wrecked then return false, 'vehicle_ok' end
    st.failed = true
    ctx.fail('block.checkpoint_route.fail_undriveable')
    return true
end

-- ============================================================================
--                                    BLOCK
-- ============================================================================

local function ApplyDefaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 20 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.label == nil then obj.label = CP.L('block.checkpoint_route.label') end
    if obj.use == nil then obj.use = c.use.default end
    if obj.radius == nil then obj.radius = c.radius[3] + 0.0 end
    if obj.stopFor == nil then obj.stopFor = c.stopFor[3] end
    if obj.vehicleRequired == nil and obj.policeVehicle ~= nil then
        obj.vehicleRequired = obj.policeVehicle
    end -- old name
    obj.policeVehicle = nil
    if obj.vehicleRequired == nil then obj.vehicleRequired = c.vehicleRequired.default end
    if obj.medals == nil then obj.medals = c.medals.default end
    if obj.contactPenalty == nil then obj.contactPenalty = c.contactPenalty[3] end
    if obj.timerStart == nil then obj.timerStart = 'first' end
    if obj.failIfUndriveable == nil then obj.failIfUndriveable = true end
    return obj
end

CP.Blocks.register(BLOCK, {
    defaults = ApplyDefaults,

    validate = function(obj, mission, location)
        local c = Cfg()
        if type(obj) ~= 'table' then return Bad('block.checkpoint_route.invalid.objective') end
        obj = ApplyDefaults(CP.U.deepcopy(obj))
        if type(obj.checkpoints) ~= 'string' and type(obj.checkpoints) ~= 'table' then
            return Bad('block.checkpoint_route.invalid.checkpoints')
        end
        if not CP.U.contains(c.use.options, obj.use) then return Bad('block.checkpoint_route.invalid.use') end
        if obj.use == 'random' then
            local n = Idx(obj.count)
            if not n or not InRange(n, c.checkpoints) then
                return Bad('block.checkpoint_route.invalid.range',
                    { field = 'count', min = c.checkpoints[1], max = c.checkpoints[2] })
            end
        end
        if not InRange(obj.radius, c.radius) then
            return Bad('block.checkpoint_route.invalid.range',
                { field = 'radius', min = c.radius[1], max = c.radius[2] })
        end
        if not InRange(obj.stopFor, c.stopFor) then
            return Bad('block.checkpoint_route.invalid.range',
                { field = 'stopFor', min = c.stopFor[1], max = c.stopFor[2] })
        end
        if not InRange(obj.contactPenalty, c.contactPenalty) then
            return Bad('block.checkpoint_route.invalid.range',
                { field = 'contactPenalty', min = c.contactPenalty[1], max = c.contactPenalty[2] })
        end
        if not InRange(obj.presenceRange, c.presenceRange) then
            return Bad('block.checkpoint_route.invalid.range',
                { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
        end
        if type(obj.minSeconds) ~= 'number' or obj.minSeconds < 0 then
            return Bad('block.checkpoint_route.invalid.min_seconds')
        end
        if type(obj.vehicleRequired) ~= 'boolean' or type(obj.failIfUndriveable) ~= 'boolean' then
            return Bad('block.checkpoint_route.invalid.flags')
        end
        if obj.timerStart ~= 'first' and obj.timerStart ~= 'start' then
            return Bad('block.checkpoint_route.invalid.timer_start')
        end
        if obj.medals ~= false and obj.medals ~= true and not MedalsValid(obj.medals) then
            return Bad('block.checkpoint_route.invalid.medals')
        end
        local locations = {}
        if type(location) == 'table' then
            locations[1] = location
        elseif type(mission) == 'table' and type(mission.locations) == 'table' then
            locations = mission.locations
        end
        for li, loc in ipairs(locations) do
            local pts = ResolvePoints(obj, loc)
            if not pts then
                return Bad('block.checkpoint_route.invalid.points_missing',
                    { key = tostring(obj.checkpoints), location = li })
            end
            local used = (obj.use == 'random') and Idx(obj.count) or #pts
            if #pts < used or not InRange(used, c.checkpoints) then
                return Bad('block.checkpoint_route.invalid.points_count',
                    { location = li, min = c.checkpoints[1], max = c.checkpoints[2], have = #pts })
            end
            for _, p in ipairs(pts) do
                if InNoBuild(p) then return Bad('block.checkpoint_route.invalid.points_zone', { location = li }) end
            end
            if loc.medals ~= nil and not MedalsValid(loc.medals) then
                return Bad('block.checkpoint_route.invalid.medals')
            end
            if obj.medals == true and loc.medals == nil then
                return Bad('block.checkpoint_route.invalid.location_medals', { location = li })
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
        local st = Ensure(ctx)
        if st.medals then
            ctx.run.flags = ctx.run.flags or {}
            ctx.run.flags.medals = true
        end
    end,

    start = function(ctx)
        local st = Ensure(ctx)
        st.startMs = Now()
        if ctx.obj.timerStart == 'start' and not st.courseStartMs then st.courseStartMs = st.startMs end
        st.resent = false
        if #st.points == 0 then
            Finish(ctx, st)
        elseif WantsHold(ctx, st) and not st.courseStartMs then
            HoldTimer(ctx, st, true)
        end
        SendState(ctx, st)
        if st.finished then TryComplete(ctx, st) end
    end,

    tick = function(ctx, dt)
        local st = Ensure(ctx)
        if st.completed or st.failed then return end
        if st.timerHeld and Now() - (st.startMs or Now()) >= PRESTART_GRACE * 1000 then
            HoldTimer(ctx, st, false) -- nobody crossed checkpoint 1 in time: the run timer starts anyway
            st.resent = false
        end
        if not st.resent then
            st.resent = true
            SendState(ctx, st)
        end
        if st.finished then
            TryComplete(ctx, st)
            return
        end
        -- Server-side stop timing: who is stopped inside the current checkpoint, and since when.
        local cp = st.points[st.current]
        local reach = (tonumber(ctx.obj.radius) or 10.0) + STOP_SLACK
        local stops = (tonumber(ctx.obj.stopFor) or 0) > 0
        local t = Now()
        for _, src in ipairs(ctx.participants()) do
            local c = ctx.coords(src)
            if c and cp and CP.U.dist(c, cp) <= reach and (not stops or StoppedNow(ctx, src)) then
                local n = st.near[src]
                if not n or n.cp ~= st.current then st.near[src] = { cp = st.current, since = t } end
            else
                st.near[src] = nil
            end
        end
        -- Course vehicles: body health for no_contact, engine health for the undriveable fail.
        if st.courseStartMs then
            for _, netId in pairs(st.vehicles) do
                local ent, engine = SampleVehicle(st, netId)
                if ctx.obj.failIfUndriveable == true and ent ~= 0 and engine and engine <= 0 and st.healthy[netId] then
                    st.failed = true
                    ctx.fail('block.checkpoint_route.fail_undriveable')
                    return
                end
            end
        end
    end,

    onEvent = function(ctx, src, ev)
        local st = Ensure(ctx)
        if type(ev) ~= 'table' then return false, 'bad_event' end
        if st.completed or st.failed then return false, 'objective_over' end
        if ev.type == 'checkpoint' then return OnCheckpoint(ctx, st, src, ev) end
        if ev.type == 'contact' then return OnContact(ctx, st, src, ev) end
        if ev.type == 'undriveable' then return OnUndriveable(ctx, st, src, ev) end
        return false, 'unknown_event'
    end,

    -- This block spawns no peds or vehicles, so no entity of this objective can die.
    onEntityDead = function(ctx, netId, killerSrc)
        return nil
    end,

    onParticipantLeft = function(ctx, src)
        local st = Ensure(ctx)
        st.near[src] = nil
        st.vehicles[src] = nil
        st.lastContact[src] = nil
    end,

    -- Only a scaled random count can shrink: checkpoints not reached yet are dropped from the end.
    rescale = function(ctx)
        local st = Ensure(ctx)
        if st.finished or ctx.obj.use ~= 'random' then return end
        local want = Idx(ctx.obj.count)
        if not want then return end
        local keep = math.max(want, st.done + 1, 2)
        if keep >= #st.points then return end
        for i = #st.points, keep + 1, -1 do st.points[i] = nil end
        SendState(ctx, st)
    end,

    -- The time limit fails the run (no alternative outcome for this block).
    onTimeout = function(ctx)
        Ensure(ctx).timedOut = true
        return nil
    end,

    -- The next checkpoint or the nearest other participant, whichever is closer.
    presence = function(ctx, src, coords)
        local st = Ensure(ctx)
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
        local st = Ensure(ctx)
        return {
            {
                label = CP.L('block.checkpoint_route.checklist'),
                done = st.finished == true,
                value = st.done,
                max = #st.points,
            },
        }
    end,

    restart = function(ctx)
        local st = Ensure(ctx)
        st.current = (#st.points > 0) and 1 or nil
        st.done = 0
        st.finished, st.completed, st.failed = false, false, false
        st.contacts, st.penalty = 0, 0
        st.courseTime, st.medal, st.noContact = nil, nil, nil
        st.startMs = Now()
        st.courseStartMs = (ctx.obj.timerStart == 'start') and st.startMs or nil
        st.near, st.vehicles, st.lastContact, st.body, st.healthy = {}, {}, {}, {}, {}
        HoldTimer(ctx, st, false)
        if WantsHold(ctx, st) then HoldTimer(ctx, st, true) end
        SendState(ctx, st)
    end,

    stop = function(ctx)
        local st = ctx.state
        HoldTimer(ctx, st, false)
        st.near, st.lastContact = {}, {}
    end,
})
