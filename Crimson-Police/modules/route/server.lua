-- modules/route/server.lua · CP.Route (server): Hard rule 17, the route to the mission start
-- (docs/ARCHITECTURE.md §5.12, SPEC "Route to the start", CRIMSON_ARENA rules 5 and 6).
--
-- Owns: the per-participant route state, the plain net events server:routeStatus (runId, metres, coords)
-- and server:recalcRoute (runId), the 1 s arrival / off-route / drift checks, and the server -> client
-- events client:routeWarning (runId, secondsLeft|nil), client:routeRecalc (runId, ok, recalcsLeft) and
-- client:routeStatus (runId, RouteStatus) (sent when the server marks the arrival).
--
-- Public API
--   CP.Route.begin(run, src) -> boolean
--       Starts the checks for one participant (CP.Runs calls it for each participant at create; the 1 s
--       tick also begins any active, not yet arrived participant it finds without a state, unless stop was
--       called for them). Idempotent. Test runs with test.useStartRoute == false get the arrival check only.
--   CP.Route.stop(run|runId, src?) -> nil      ends the checks for src (every participant when src is nil)
--   CP.Route.status(run, src) -> RouteStatus
--       RouteStatus = { status = 'on'|'off'|'arrived'|'disabled', secondsLeft = number|nil (only while the
--       off-route warning is shown), recalcsLeft = number, distance = metres (straight line to the start,
--       2D, rounded)|nil }  (HudState.route plus recalcsLeft for the Active Mission view)
--
-- Per participant: { lastReport, offSince, warned, recalcs, closest, distance, arrived, mode }.
-- Every 1 s, with the SERVER-SIDE ped position:
--   * arrival: within location.start.radius (2D) of location.start.coords -> CP.Runs.markArrived(run, src),
--     then the flag (CP.Alerts.set, idempotent if CP.Runs already set it) and client:routeStatus 'arrived';
--     the checks stop for that participant. For Manhunt the start is the search circle (its centre and
--     radius), so the route leads to the centre until the officer is inside the circle.
--   * off route: the last reported metres > Config.Route.maxDeviation, or no accepted report for
--     Config.Route.reportTimeout s (off from the moment the timeout passed). After Config.Route.warnAfter s
--     off route: client:routeWarning (runId, secondsLeft) every second; after Config.Route.abandonAfter s off
--     route in one stretch: CP.Runs.removeParticipant(run, src, 'off_route'). A report within maxDeviation
--     ends the stretch (client:routeWarning (runId, nil) when a warning was shown).
--   * drift: the straight-line distance to the start grows more than Config.Route.maxDrift past the closest
--     it has been -> 'off_route', whatever the client reports.
--   * in-arena participants (CP.Alerts.inArena) are not route-checked and cannot arrive (CP.Alerts removes
--     them from the run); their reports are ignored.
-- Reports: at most one per 0.9 s per player; ignored unless the runId is the sender's active run, metres is
-- a finite number >= 0 and the reported coords lie within Config.Route.maxDeviation of the server-side ped
-- position (a report that fails is treated as missing). Recalculate: Config.Route.maxRecalcs per
-- participant per run; a granted recalculation ends the current off-route stretch (the new line starts
-- where the officer is).

CP.Route = CP.Route or {}
local R = CP.Route
local TAG = 'route'
local MAX_RUN_ID = 64
local MAX_METRES = 100000.0
local REPORT_MIN_GAP_MS = 900

local states = {}     -- states[runId][src] = st
local stopped = {}    -- stopped[runId][src] = true after an explicit stop (the safety net leaves them alone)

-- ── helpers ─────────────────────────────────────────────────────────────────
local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function secondsMs(v, default)
    local n = tonumber(v) or default
    return math.floor(n * 1000)
end

local function runsCall(name, ...)
    if not (CP.Runs and type(CP.Runs[name]) == 'function') then return false, nil end
    local ok, a, b = pcall(CP.Runs[name], ...)
    if not ok then
        CP.err(TAG, 'CP.Runs.%s failed: %s', name, tostring(a))
        return false, nil
    end
    return true, a, b
end

local function inArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, v = pcall(CP.Alerts.inArena, src)
    return ok and v == true
end

local function serverCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ped)
    if ok then return c end
    return nil
end

local function startOf(run)
    local loc = type(run) == 'table' and run.location or nil
    local start = type(loc) == 'table' and loc.start or nil
    if type(start) ~= 'table' or start.coords == nil then return nil end
    local x = CP.U.xyz(start.coords)
    if type(x) ~= 'number' then return nil end
    return { coords = start.coords, radius = tonumber(start.radius) or 50.0 }
end

local function routeEnabled(run)
    return not (type(run.test) == 'table' and run.test.useStartRoute == false)
end

local function participant(run, src)
    return type(run) == 'table' and type(run.participants) == 'table' and run.participants[src] or nil
end

local function isActive(run, src)
    local p = participant(run, src)
    return type(run) == 'table' and run.state ~= 'ended' and type(p) == 'table' and p.status == 'active'
end

local function getState(runId, src)
    local byRun = states[runId]
    return byRun and byRun[src] or nil
end

local function markStopped(runId, src)
    local s = stopped[runId]
    if not s then s = {}; stopped[runId] = s end
    s[src] = true
end

local function toVec(v)
    local t = type(v)
    if t ~= 'table' and t ~= 'vector3' and t ~= 'vector4' then return nil end
    local x, y, z = CP.U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return { x = x, y = y, z = z }
end

local function recalcsLeft(st)
    local max = math.floor(tonumber(Config.Route.maxRecalcs) or 0)
    local used = st and st.recalcs or 0
    if used >= max then return 0 end
    return max - used
end

local function secondsLeftOf(st, now)
    if not st.offSince then return nil end
    local left = secondsMs(Config.Route.abandonAfter, 30) - (now - st.offSince)
    if left < 0 then left = 0 end
    return math.ceil(left / 1000)
end

local function sendWarning(src, runId, secondsLeft)
    TriggerClientEvent(CP.e('client:routeWarning'), src, runId, secondsLeft)
end

local function endStretch(st, src, runId)
    local wasWarned = st.warned
    st.offSince = nil
    st.offCause = nil
    st.warned = false
    if wasWarned then sendWarning(src, runId, nil) end
end

-- ── public API ──────────────────────────────────────────────────────────────
function R.begin(run, src)
    src = toSrc(src)
    if type(run) ~= 'table' or run.id == nil or not src then return false end
    local p = participant(run, src)
    if type(p) ~= 'table' or p.status ~= 'active' or p.arrived then return false end
    local byRun = states[run.id]
    if not byRun then byRun = {}; states[run.id] = byRun end
    if stopped[run.id] then stopped[run.id][src] = nil end
    if byRun[src] then return true end
    local now = GetGameTimer()
    local start = startOf(run)
    local coords = serverCoords(src)
    local d = (start and coords) and CP.U.dist2d(coords, start.coords) or nil
    byRun[src] = {
        runId = run.id, src = src,
        mode = routeEnabled(run) and 'route' or 'arrival',
        begunAt = now, lastReport = now, lastReportAt = nil, reports = 0, metres = nil,
        offSince = nil, offCause = nil, warned = false,
        recalcs = 0, closest = d, distance = d, arrived = false,
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
            for s in pairs(byRun) do markStopped(runId, s) end
        end
        states[runId] = nil
        return
    end
    src = toSrc(src)
    if not src then return end
    markStopped(runId, src)
    if byRun then
        byRun[src] = nil
        if next(byRun) == nil then states[runId] = nil end
    end
end

function R.status(run, src)
    src = toSrc(src)
    local runId = type(run) == 'table' and run.id or run
    local st = (runId ~= nil and src) and getState(runId, src) or nil
    local maxR = math.floor(tonumber(Config.Route.maxRecalcs) or 0)
    if st then
        local dist = st.distance and CP.U.round(st.distance) or nil
        if st.arrived then return { status = 'arrived', recalcsLeft = recalcsLeft(st), distance = 0 } end
        if st.mode ~= 'route' then return { status = 'disabled', recalcsLeft = 0, distance = dist } end
        local now = GetGameTimer()
        return {
            status = st.offSince and 'off' or 'on',
            secondsLeft = st.warned and secondsLeftOf(st, now) or nil,
            recalcsLeft = recalcsLeft(st),
            distance = dist,
        }
    end
    local p = (type(run) == 'table' and src) and participant(run, src) or nil
    if type(p) == 'table' and p.arrived then return { status = 'arrived', recalcsLeft = 0, distance = 0 } end
    if type(run) == 'table' and not routeEnabled(run) then return { status = 'disabled', recalcsLeft = 0 } end
    return { status = 'on', recalcsLeft = maxR }
end

-- ── outcomes ────────────────────────────────────────────────────────────────
local function abandon(run, src, cause)
    local byRun = states[run.id]
    if byRun then byRun[src] = nil end
    markStopped(run.id, src)
    CP.log(TAG, '%d abandoned run %s: off route (%s)', src, tostring(run.id), tostring(cause))
    CreateThread(function()
        if isActive(run, src) then runsCall('removeParticipant', run, src, 'off_route') end
    end)
end

local function arrive(run, src, st)
    if st.warned then sendWarning(src, run.id, nil) end
    st.arrived = true
    st.offSince = nil
    st.offCause = nil
    st.warned = false
    st.distance = 0
    CP.log(TAG, '%d reached the start of run %s', src, tostring(run.id))
    CreateThread(function()
        runsCall('markArrived', run, src)
        -- From the moment a participant reaches the start their combat must not create alerts. CP.Runs
        -- sets the flag in markArrived; set is idempotent, so this only covers an engine that did not.
        if isActive(run, src) and CP.Alerts and CP.Alerts.set and not (CP.Alerts.has and CP.Alerts.has(src)) then
            if not inArena(src) then pcall(CP.Alerts.set, src, run) end
        end
        TriggerClientEvent(CP.e('client:routeStatus'), src, run.id, R.status(run, src))
    end)
end

-- ── 1 s tick ────────────────────────────────────────────────────────────────
local function checkOne(run, src, st, now)
    local c = Config.Route
    if not isActive(run, src) then
        local byRun = states[run.id]
        if byRun then byRun[src] = nil end
        return
    end
    if st.arrived then return end
    local p = participant(run, src)
    if p.arrived then                                  -- marked by the engine (e.g. a test teleport)
        st.arrived = true
        return
    end
    if inArena(src) then
        -- Not route-checked (CRIMSON_ARENA rule 6); CP.Alerts removes them from the run.
        st.offSince = nil
        st.offCause = nil
        st.warned = false
        st.lastReport = now
        return
    end
    local start = startOf(run)
    if not start then return end
    local coords = serverCoords(src)
    if coords then
        local d = CP.U.dist2d(coords, start.coords)
        st.distance = d
        if d <= start.radius then
            arrive(run, src, st)
            return
        end
        if st.mode == 'route' then
            if st.closest == nil or d < st.closest then
                st.closest = d
            elseif d - st.closest > (tonumber(c.maxDrift) or 1000.0) then
                abandon(run, src, 'drift')
                return
            end
        end
    end
    if st.mode ~= 'route' then return end
    local timeoutMs = secondsMs(c.reportTimeout, 10)
    if not st.offSince and now - st.lastReport > timeoutMs then
        st.offSince = st.lastReport + timeoutMs
        st.offCause = 'no_report'
    end
    if st.offSince then
        local elapsed = now - st.offSince
        if elapsed >= secondsMs(c.abandonAfter, 30) then
            abandon(run, src, st.offCause or 'deviation')
            return
        end
        if elapsed >= secondsMs(c.warnAfter, 10) then
            if not st.warned then
                st.warned = true
                CP.log(TAG, '%d off route on run %s (%s): warned', src, tostring(run.id), tostring(st.offCause))
            end
            sendWarning(src, run.id, secondsLeftOf(st, now))
        end
    end
end

local function tick()
    local now = GetGameTimer()
    local _, runs = runsCall('all')
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
                        if type(p) == 'table' and p.status == 'active' and not p.arrived
                            and not (byRun and byRun[src]) and not (st and st[src]) then
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
            local _, r = runsCall('get', runId)
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
        if byRun and byRun[w.src] == w.st then checkOne(w.run, w.src, w.st, now) end
    end
    for runId, byRun in pairs(states) do
        if next(byRun) == nil then states[runId] = nil end
    end
    for runId in pairs(stopped) do
        local run = known[runId]
        if not run then
            local _, r = runsCall('get', runId)
            run = r
        end
        if type(run) ~= 'table' or run.state == 'ended' then stopped[runId] = nil end
    end
end

-- ── net events (plain: client Lua -> server, no reqId) ─────────────────────
local function validRunId(runId)
    return type(runId) == 'string' and runId ~= '' and #runId <= MAX_RUN_ID
end

RegisterNetEvent(CP.e('server:routeStatus'), function(runId, metres, coords)
    local src = source
    local n = toSrc(src)
    if not n or not validRunId(runId) then return end
    if type(metres) ~= 'number' or metres ~= metres or metres < 0 then return end
    if not CP.Net.rateOk(n, 'route:status', 3, 1000) then return end
    local st = getState(runId, n)
    if not st or st.arrived or st.mode ~= 'route' then return end
    local now = GetGameTimer()
    if st.lastReportAt and now - st.lastReportAt < REPORT_MIN_GAP_MS then return end
    st.lastReportAt = now
    if inArena(n) then return end
    local _, run = runsCall('get', runId)
    if not isActive(run, n) then return end
    local reported = toVec(coords)
    if not reported then return end
    local server = serverCoords(n)
    if server and CP.U.dist2d(reported, server) > (tonumber(Config.Route.maxDeviation) or 120.0) then
        CP.log(TAG, 'report of %d ignored: reported position is %.0f m from the server position', n, CP.U.dist2d(reported, server))
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
        endStretch(st, n, runId)
    end
end)

RegisterNetEvent(CP.e('server:recalcRoute'), function(runId)
    local src = source
    local n = toSrc(src)
    if not n or not validRunId(runId) then return end
    if not CP.Net.rateOk(n, 'route:recalc', 1, 2000) then
        TriggerClientEvent(CP.e('client:routeRecalc'), n, runId, false, recalcsLeft(getState(runId, n)))
        return
    end
    local st = getState(runId, n)
    local ok = false
    if st and not st.arrived and st.mode == 'route' and not inArena(n) then
        local _, run = runsCall('get', runId)
        if isActive(run, n) and st.recalcs < math.floor(tonumber(Config.Route.maxRecalcs) or 0) then
            st.recalcs = st.recalcs + 1
            ok = true
            endStretch(st, n, runId)
            st.lastReport = GetGameTimer()          -- the client resamples before its next report
            st.metres = nil
            CP.log(TAG, '%d recalculated the route of run %s (%d used)', n, runId, st.recalcs)
        end
    end
    TriggerClientEvent(CP.e('client:routeRecalc'), n, runId, ok, recalcsLeft(st))
end)

AddEventHandler('playerDropped', function()
    local n = toSrc(source)
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
        local ok, err = pcall(tick)
        if not ok then CP.err(TAG, 'tick failed: %s', tostring(err)) end
    end
end)
