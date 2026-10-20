-- CP.Route (server): Hard rule 17, the route to the mission start (docs/ARCHITECTURE.md §5.12, SPEC "Route to the
-- start", CRIMSON_ARENA rules 5 and 6).

CP.Route = CP.Route or {}
local R = CP.Route
local TAG = 'route'
local MAX_RUN_ID = 64
local MAX_METRES = 100000.0
local REPORT_MIN_GAP_MS = 900
local POSITION_TOLERANCE = 150.0   -- metres between the reported and the server-side position (at least)

local states = {}     -- states[runId][src] = st
local stopped = {}    -- stopped[runId][src] = true after an explicit stop (the safety net leaves them alone)

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function SecondsMs(v, default)
    local n = tonumber(v) or default
    return math.floor(n * 1000)
end

local function RunsCall(name, ...)
    if not (CP.Runs and type(CP.Runs[name]) == 'function') then return false, nil end
    local ok, a, b = pcall(CP.Runs[name], ...)
    if not ok then
        CP.err(TAG, 'CP.Runs.%s failed: %s', name, tostring(a))
        return false, nil
    end
    return true, a, b
end

local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, v = pcall(CP.Alerts.inArena, src)
    return ok and v == true
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ped)
    if ok then return c end
    return nil
end

local function IsPoint(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return false end
    local x, y = CP.U.xyz(v)
    return type(x) == 'number' and type(y) == 'number'
end

-- The start circle: location.start, or, when the first objective is a search_area (Manhunt), its starting
-- search circle (location[obj.center], obj.startRadius) if that is the larger circle.
local function StartOf(run)
    local loc = type(run) == 'table' and run.location or nil
    local start = type(loc) == 'table' and loc.start or nil
    if type(start) ~= 'table' or not IsPoint(start.coords) then return nil end
    local out = { coords = start.coords, radius = tonumber(start.radius) or 50.0 }
    local mission = run.mission
    local first = type(mission) == 'table' and type(mission.objectives) == 'table' and mission.objectives[1] or nil
    if type(first) == 'table' and first.block == 'search_area' then
        local centre = type(first.center) == 'string' and loc[first.center] or first.center
        local radius = tonumber(first.startRadius)
        if IsPoint(centre) and radius and radius > out.radius then
            out.coords, out.radius = centre, radius
        end
    end
    return out
end

local function RouteEnabled(run)
    return not (type(run.test) == 'table' and run.test.useStartRoute == false)
end

local function Participant(run, src)
    return type(run) == 'table' and type(run.participants) == 'table' and run.participants[src] or nil
end

local function IsActive(run, src)
    local p = Participant(run, src)
    return type(run) == 'table' and run.state ~= 'ended' and type(p) == 'table' and p.status == 'active'
end

local function GetState(runId, src)
    local byRun = states[runId]
    return byRun and byRun[src] or nil
end

local function MarkStopped(runId, src)
    local s = stopped[runId]
    if not s then s = {}; stopped[runId] = s end
    s[src] = true
end

local function ToVec(v)
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y, z = CP.U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

local function RecalcsLeft(st)
    local max = math.floor(tonumber(Config.Route.maxRecalcs) or 0)
    local used = st and st.recalcs or 0
    if used >= max then return 0 end
    return max - used
end

local function SecondsLeftOf(st, now)
    if not st.offSince then return nil end
    local left = SecondsMs(Config.Route.abandonAfter, 30) - (now - st.offSince)
    if left < 0 then left = 0 end
    return math.ceil(left / 1000)
end

local function SendWarning(src, runId, secondsLeft)
    TriggerClientEvent(CP.e('client:routeWarning'), src, runId, secondsLeft)
end

-- The tablet (Active Mission screen / run bar) shows the route status from CP.Runs.view and refreshes on
-- push topic 'run': push the view when the warning appears or goes, and after a recalculation (SPEC: the
-- off-route warning shows "on the HUD and the tablet"). The NUI counts secondsLeft down locally.
local function PushView(runId, src)
    if not (CP.Tablet and CP.Tablet.push and CP.Runs and CP.Runs.view) then return end
    CreateThread(function()
        local _, run = RunsCall('get', runId)
        if type(run) ~= 'table' or run.state == 'ended' then return end
        local _, view = RunsCall('view', run, src)
        if type(view) == 'table' then pcall(CP.Tablet.push, src, 'run', view) end
    end)
end

local function EndStretch(st, src, runId)
    local wasWarned = st.warned
    st.offSince = nil
    st.offCause = nil
    st.warned = false
    if wasWarned then
        SendWarning(src, runId, nil)
        PushView(runId, src)
    end
end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

function R.begin(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or run.id == nil or not src then return false end
    local p = Participant(run, src)
    if type(p) ~= 'table' or p.status ~= 'active' or p.arrived then return false end
    local byRun = states[run.id]
    if not byRun then byRun = {}; states[run.id] = byRun end
    if stopped[run.id] then stopped[run.id][src] = nil end
    if byRun[src] then return true end
    local now = GetGameTimer()
    local start = StartOf(run)
    local coords = ServerCoords(src)
    local d = (start and coords) and CP.U.dist2d(coords, start.coords) or nil
    byRun[src] = {
        runId = run.id,
        src = src,
        mode = RouteEnabled(run) and 'route' or 'arrival',
        begunAt = now,
        lastReport = now,
        lastReportAt = nil,
        reports = 0,
        metres = nil,
        offSince = nil,
        offCause = nil,
        warned = false,
        recalcs = 0,
        closest = d,
        distance = d,
        arrived = false,
    }
    CP.log(TAG, 'begin %d on run %s (%s, %.0f m to go)', src, tostring(run.id), byRun[src].mode, d or -1)
    return true
end

function R.stop(run, src)
    local runId = type(run) == 'table' and run.id or run
    if runId == nil then return end
    local byRun = states[runId]
    if src == nil then
        if byRun then
            for s in pairs(byRun) do MarkStopped(runId, s) end
        end
        states[runId] = nil
        return
    end
    src = ToSrc(src)
    if not src then return end
    MarkStopped(runId, src)
    if byRun then
        byRun[src] = nil
        if next(byRun) == nil then states[runId] = nil end
    end
end

function R.status(run, src)
    src = ToSrc(src)
    local runId = type(run) == 'table' and run.id or run
    local st = (runId ~= nil and src) and GetState(runId, src) or nil
    local maxR = math.floor(tonumber(Config.Route.maxRecalcs) or 0)
    if st then
        local dist = st.distance and CP.U.round(st.distance) or nil
        if st.arrived then return { status = 'arrived', recalcsLeft = RecalcsLeft(st), distance = 0 } end
        if st.mode ~= 'route' then return { status = 'disabled', recalcsLeft = 0, distance = dist } end
        local now = GetGameTimer()
        return {
            -- 'off' only once the warning is shown (SPEC: off the line for warnAfter s shows the warning; the
            -- Active Mission screen shows "on route, or the off-route countdown").
            status = st.warned and 'off' or 'on',
            secondsLeft = st.warned and SecondsLeftOf(st, now) or nil,
            recalcsLeft = RecalcsLeft(st),
            distance = dist,
        }
    end
    local p = (type(run) == 'table' and src) and Participant(run, src) or nil
    if type(p) == 'table' and p.arrived then return { status = 'arrived', recalcsLeft = 0, distance = 0 } end
    if type(run) == 'table' and not RouteEnabled(run) then return { status = 'disabled', recalcsLeft = 0 } end
    return { status = 'on', recalcsLeft = maxR }
end

-- ============================================================================
--                                   OUTCOMES
-- ============================================================================

local function Abandon(run, src, cause)
    local byRun = states[run.id]
    if byRun then byRun[src] = nil end
    MarkStopped(run.id, src)
    CP.log(TAG, '%d abandoned run %s: off route (%s)', src, tostring(run.id), tostring(cause))
    CreateThread(function()
        if IsActive(run, src) then RunsCall('removeParticipant', run, src, 'off_route') end
    end)
end

local function Arrive(run, src, st)
    if st.warned then SendWarning(src, run.id, nil) end
    st.arrived = true
    st.offSince = nil
    st.offCause = nil
    st.warned = false
    st.distance = 0
    CP.log(TAG, '%d reached the start of run %s', src, tostring(run.id))
    CreateThread(function()
        RunsCall('markArrived', run, src)
        -- From the moment a participant reaches the start their combat must not create alerts. CP.Runs
        -- sets the flag in markArrived; set is idempotent, so this only covers an engine that did not.
        if IsActive(run, src) and CP.Alerts and CP.Alerts.set and not (CP.Alerts.has and CP.Alerts.has(src)) then
            if not InArena(src) then pcall(CP.Alerts.set, src, run) end
        end
        TriggerClientEvent(CP.e('client:routeStatus'), src, run.id, R.status(run, src))
    end)
end

-- ============================================================================
--                                   1 S TICK
-- ============================================================================

local function CheckOne(run, src, st, now)
    local c = Config.Route
    if not IsActive(run, src) then
        local byRun = states[run.id]
        if byRun then byRun[src] = nil end
        return
    end
    if st.arrived then return end
    local p = Participant(run, src)
    if p.arrived then                                  -- marked by the engine (e.g. a test teleport)
        st.arrived = true
        return
    end
    if InArena(src) then
        -- Not route-checked (CRIMSON_ARENA rule 6); CP.Alerts removes them from the run.
        st.offSince = nil
        st.offCause = nil
        st.warned = false
        st.lastReport = now
        return
    end
    local start = StartOf(run)
    if not start then return end
    local coords = ServerCoords(src)
    if coords then
        local d = CP.U.dist2d(coords, start.coords)
        st.distance = d
        if d <= start.radius then
            Arrive(run, src, st)
            return
        end
        if st.mode == 'route' then
            if st.closest == nil or d < st.closest then
                st.closest = d
            elseif d - st.closest > (tonumber(c.maxDrift) or 1000.0) then
                Abandon(run, src, 'drift')
                return
            end
        end
    end
    if st.mode ~= 'route' then return end
    local timeoutMs = SecondsMs(c.reportTimeout, 10)
    if not st.offSince and now - st.lastReport > timeoutMs then
        st.offSince = st.lastReport + timeoutMs
        st.offCause = 'no_report'
    end
    if st.offSince then
        local elapsed = now - st.offSince
        if elapsed >= SecondsMs(c.abandonAfter, 30) then
            Abandon(run, src, st.offCause or 'deviation')
            return
        end
        if elapsed >= SecondsMs(c.warnAfter, 10) then
            local first = not st.warned
            if first then
                st.warned = true
                CP.log(TAG, '%d off route on run %s (%s): warned', src, tostring(run.id), tostring(st.offCause))
            end
            SendWarning(src, run.id, SecondsLeftOf(st, now))
            if first then PushView(run.id, src) end
        end
    end
end

local function Tick()
    local now = GetGameTimer()
    local _, runs = RunsCall('all')
    local known = {}
    if type(runs) == 'table' then
        for _, run in ipairs(runs) do
            if type(run) == 'table' and run.id ~= nil then
                known[run.id] = run
                -- safety net: every active participant still heading to the start is route-checked
                if run.state == 'accepted' or run.state == 'in_progress' then
                    local byRun = states[run.id]
                    local st = stopped[run.id]
                    for src, p in pairs(run.participants or {}) do
                        if type(p) == 'table' and p.status == 'active' and not p.arrived and not (byRun and byRun[src])
                            and not (st and st[src]) then
                            R.begin(run, src)
                        end
                    end
                end
            end
        end
    end
    local work = {}
    for runId, byRun in pairs(states) do
        local run = known[runId]
        if not run then
            local _, r = RunsCall('get', runId)
            run = r
        end
        if type(run) ~= 'table' or run.state == 'ended' then
            states[runId] = nil
        else
            for src, st in pairs(byRun) do work[#work + 1] = { run = run, src = src, st = st } end
        end
    end
    for _, w in ipairs(work) do
        local byRun = states[w.run.id]
        if byRun and byRun[w.src] == w.st then CheckOne(w.run, w.src, w.st, now) end
    end
    for runId, byRun in pairs(states) do
        if next(byRun) == nil then states[runId] = nil end
    end
    for runId in pairs(stopped) do
        local run = known[runId]
        if not run then
            local _, r = RunsCall('get', runId)
            run = r
        end
        if type(run) ~= 'table' or run.state == 'ended' then stopped[runId] = nil end
    end
end

-- ============================================================================
--              NET EVENTS (plain: client Lua -> server, no reqId)
-- ============================================================================

local function ValidRunId(runId)
    return type(runId) == 'string' and runId ~= '' and #runId <= MAX_RUN_ID
end

RegisterNetEvent(CP.e('server:routeStatus'), function(runId, metres, coords)
    local src = source
    local n = ToSrc(src)
    if not n or not ValidRunId(runId) then return end
    if type(metres) ~= 'number' or metres ~= metres or metres < 0 then return end
    if not CP.Net.rateOk(n, 'route:status', 3, 1000) then return end
    local st = GetState(runId, n)
    if not st or st.arrived or st.mode ~= 'route' then return end
    local now = GetGameTimer()
    if st.lastReportAt and now - st.lastReportAt < REPORT_MIN_GAP_MS then return end
    st.lastReportAt = now
    if InArena(n) then return end
    local _, run = RunsCall('get', runId)
    if not IsActive(run, n) then return end
    local reported = ToVec(coords)
    if not reported then return end
    local server = ServerCoords(n)
    -- The tolerance never drops below POSITION_TOLERANCE: a smaller maxDeviation must not reject honest
    -- reports sent at speed (the server-side position lags the client by a sync interval).
    local tolerance = math.max(tonumber(Config.Route.maxDeviation) or 120.0, POSITION_TOLERANCE)
    if server and CP.U.dist2d(reported, server) > tolerance then
        CP.log(TAG, 'report of %d ignored: reported position is %.0f m from the server position', n,
            CP.U.dist2d(reported, server))
        return
    end
    if metres > MAX_METRES then metres = MAX_METRES end
    st.lastReport = now
    st.reports = st.reports + 1
    st.metres = metres
    if metres > (tonumber(Config.Route.maxDeviation) or 120.0) then
        if not st.offSince then
            st.offSince = now
            st.offCause = 'deviation'
        end
    elseif st.offSince then
        EndStretch(st, n, runId)
    end
end)

RegisterNetEvent(CP.e('server:recalcRoute'), function(runId)
    local src = source
    local n = ToSrc(src)
    if not n or not ValidRunId(runId) then return end
    if not CP.Net.rateOk(n, 'route:recalc', 1, 2000) then
        TriggerClientEvent(CP.e('client:routeRecalc'), n, runId, false, RecalcsLeft(GetState(runId, n)))
        return
    end
    local st = GetState(runId, n)
    local ok = false
    if st and not st.arrived and st.mode == 'route' and not InArena(n) then
        local _, run = RunsCall('get', runId)
        if IsActive(run, n) and st.recalcs < math.floor(tonumber(Config.Route.maxRecalcs) or 0) then
            st.recalcs = st.recalcs + 1
            ok = true
            EndStretch(st, n, runId)
            st.lastReport = GetGameTimer()          -- the client resamples before its next report
            st.metres = nil
            CP.log(TAG, '%d recalculated the route of run %s (%d used)', n, runId, st.recalcs)
        end
    end
    TriggerClientEvent(CP.e('client:routeRecalc'), n, runId, ok, RecalcsLeft(st))
    if ok then PushView(runId, n) end
end)

AddEventHandler('playerDropped', function()
    local n = ToSrc(source)
    if not n then return end
    for runId, byRun in pairs(states) do
        byRun[n] = nil
        if next(byRun) == nil then states[runId] = nil end
    end
end)

CreateThread(function()
    Wait(0)
    while true do
        Wait(1000)
        local ok, err = pcall(Tick)
        if not ok then CP.err(TAG, 'tick failed: %s', tostring(err)) end
    end
end)
