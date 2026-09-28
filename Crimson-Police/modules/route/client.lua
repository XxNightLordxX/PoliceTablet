-- modules/route/client.lua · CP.Route (client): the GPS route to the mission start and the reports the
-- server checks (docs/ARCHITECTURE.md §5.12, SPEC "Route to the start").
--
-- Owns: the start waypoint, a temporary route blip used to read GTA's GPS route, the fixed polyline sampled
-- from it, the reports to server:routeStatus, the route part of the HUD (HudState.route) and the client
-- actions setGps and recalcRoute (NUI 'client' endpoint, registered with CP.Tablet.registerClientAction).
--
-- Public API
--   CP.Route.begin(runId, startCoords, opts?) -> boolean
--       Sets the waypoint (SetNewWaypoint) and a GPS route to the start, waits for the route to exist,
--       samples it every Config.Route.sampleEvery m with GetPosAlongGpsTypeRoute over GetGpsBlipRouteLength
--       into a fixed polyline (never recalculated automatically; when sampling fails the straight line from
--       the player to the start is used and logged), then reports every Config.Route.reportEvery s the 2D
--       distance from the player to that polyline (CP.U.distToPolyline) and the player's coords.
--       opts = { startRoute = false (test run without the route: waypoint only, no reports, HUD 'disabled'),
--       radius }. Idempotent for the same runId. CP.Runs calls it on client:start; this file also reacts to
--       client:start itself, so a missed call cannot skip the route.
--   CP.Route.recalculate() -> ok, data|errKey     asks the server (server:recalcRoute); on ok resamples the
--       route from where the player is. data = { recalcsLeft }. errKeys: err.route_inactive,
--       err.route_arrived, err.route_disabled, err.route_no_recalcs, err.busy, err.timeout. Yields.
--   CP.Route.stop()                               clears the waypoint (when it is still ours), the blip and
--                                                 the reports; that run is never begun again on this client
--                                                 (CP.Runs calls it on arrival and at the end). Never touches
--                                                 the HUD (the run engine owns it).
--   CP.Route.current() -> { runId, arrived, routeOn } | nil
-- Client actions: setGps (re-sets the waypoint to the start; the polyline stays the same), recalcRoute.
-- Events handled: client:routeWarning (runId, secondsLeft|nil) -> HUD { route = { status, secondsLeft,
-- distance } } and one toast when a warning first appears; client:routeRecalc (runId, ok, recalcsLeft);
-- client:routeStatus (runId, RouteStatus) and client:participants (runId, list) -> 'arrived';
-- client:start (fallback begin) and client:runEnded (fallback stop).

CP.Route = CP.Route or {}
local R = CP.Route
local TAG = 'route'
local ROUTE_WAIT_MS = 5000          -- how long to wait for GTA to find the GPS route
local RECALC_TIMEOUT_MS = 10000
local WAYPOINT_SPRITE = 8
local SLOT_TYPES = { 1, 0 }         -- radar blip route first, then the waypoint route

local cur = nil                     -- the active route
local tokenSeq = 0
local latestStart = nil             -- runId of the latest client:start
local endedRuns, endedCount = {}, 0 -- runs that ended on this client (begin refuses them)

local function markEnded(runId)
    if endedRuns[runId] then return end
    if endedCount >= 50 then endedRuns, endedCount = {}, 0 end
    endedRuns[runId] = true
    endedCount = endedCount + 1
end

-- ── helpers ─────────────────────────────────────────────────────────────────
local function toVec3(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = CP.U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    if type(z) ~= 'number' then z = 0.0 end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function valid(token)
    return cur ~= nil and cur.token == token
end

local function playerPos()
    local c = GetEntityCoords(PlayerPedId())
    return vector3(c.x, c.y, c.z)
end

local function maxDeviation()
    return tonumber(Config.Route.maxDeviation) or 120.0
end

local function hudRoute(route)
    if CP.Tablet and CP.Tablet.hud then CP.Tablet.hud({ route = route }) end
end

local function toast(kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars)) end
end

-- Cumulative lengths so the HUD can show the distance still to drive along the fixed line.
local function setPolyline(pts)
    local cum = { 0.0 }
    for i = 2, #pts do cum[i] = cum[i - 1] + CP.U.dist2d(pts[i - 1], pts[i]) end
    cur.polyline = pts
    cur.cum = cum
end

local function remainingAlong(pos)
    local pts, cum = cur.polyline, cur.cum
    if not pts or #pts < 2 then return math.floor(CP.U.dist2d(pos, cur.target) + 0.5) end
    local px, py = pos.x, pos.y
    local best, bestAlong = math.huge, 0.0
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local vx, vy = b.x - a.x, b.y - a.y
        local len2 = vx * vx + vy * vy
        local t = 0.0
        if len2 > 0 then t = CP.U.clamp(((px - a.x) * vx + (py - a.y) * vy) / len2, 0.0, 1.0) end
        local cx, cy = a.x + t * vx, a.y + t * vy
        local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
        if d < best then
            best = d
            bestAlong = cum[i] + t * math.sqrt(len2)
        end
    end
    local left = cum[#cum] - bestAlong
    if left < 0 then left = 0 end
    return math.floor(left + 0.5)
end

local function showRoute()
    if not cur or cur.arrived then return end
    if not cur.routeOn then
        hudRoute({ status = 'disabled' })
        return
    end
    local r = { distance = cur.distance }
    if cur.warning ~= nil then
        r.status = 'off'
        r.secondsLeft = cur.warning
    elseif cur.metres and cur.metres > maxDeviation() then
        r.status = 'off'
    else
        r.status = 'on'
    end
    hudRoute(r)
end

local function removeBlip()
    if cur and cur.blip then
        if DoesBlipExist(cur.blip) then
            SetBlipRoute(cur.blip, false)
            RemoveBlip(cur.blip)
        end
        cur.blip = nil
    end
end

local function setWaypoint()
    if cur then SetNewWaypoint(cur.target.x + 0.0, cur.target.y + 0.0) end
end

-- Only remove the waypoint when it still points at our start (the player may have set their own).
local function clearOurWaypoint(target)
    if not IsWaypointActive() then return end
    local blip = GetFirstBlipInfoId(WAYPOINT_SPRITE)
    if not blip or not DoesBlipExist(blip) then return end
    local c = GetBlipInfoIdCoord(blip)
    if CP.U.dist2d(c, target) <= 15.0 then SetWaypointOff() end
end

-- ── sampling ────────────────────────────────────────────────────────────────
local function waitForRoute(token)
    local deadline = GetGameTimer() + ROUTE_WAIT_MS
    while GetGameTimer() < deadline do
        if not valid(token) then return false end
        if GetGpsBlipRouteFound() and (GetGpsBlipRouteLength() or 0) > 0 then return true end
        Wait(100)
    end
    return false
end

local function pickSlot()
    for _, slot in ipairs(SLOT_TYPES) do
        local ok, pos = GetPosAlongGpsTypeRoute(true, 0.0, slot)
        if ok and pos then return slot end
    end
    return nil
end

-- Returns a polyline from the player to the start (the GPS route, or the straight line).
local function samplePolyline(token)
    local target = cur.target
    local runId = cur.runId
    local start = playerPos()
    local pts
    local blip = AddBlipForCoord(target.x, target.y, target.z)
    cur.blip = blip
    SetBlipSprite(blip, 1)
    SetBlipColour(blip, 1)
    SetBlipScale(blip, 0.8)
    SetBlipRouteColour(blip, 1)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(CP.L('route.blip'))
    EndTextCommandSetBlipName(blip)
    SetBlipRoute(blip, true)
    if waitForRoute(token) and valid(token) then
        local length = tonumber(GetGpsBlipRouteLength()) or 0
        local step = tonumber(Config.Route.sampleEvery) or 50.0
        if step < 5.0 then step = 5.0 end
        local slot = pickSlot()
        if slot and length > 0 then
            pts = { start }
            local d, n = step, 0
            while d < length do
                local ok, pos = GetPosAlongGpsTypeRoute(true, d + 0.0, slot)
                if ok and pos then pts[#pts + 1] = vector3(pos.x, pos.y, pos.z) end
                d = d + step
                n = n + 1
                if n % 40 == 0 then
                    Wait(0)
                    if not valid(token) then break end
                end
            end
            pts[#pts + 1] = target
            if #pts < 3 then pts = nil end
        end
    end
    if valid(token) then removeBlip() end
    if not pts then
        CP.warn(TAG, 'no GPS route to the start of run %s: using the straight line', runId)
        pts = { start, target }
        if valid(token) then toast('warning', 'route.no_gps') end
    else
        CP.log(TAG, 'route of run %s sampled: %d points', runId, #pts)
    end
    return pts
end

local function resample(token)
    cur.sampling = true
    setWaypoint()
    local pts = samplePolyline(token)
    if not valid(token) then return false end
    setPolyline(pts)
    cur.metres = 0
    cur.warning = nil
    cur.sampling = false
    return true
end

-- ── reports ─────────────────────────────────────────────────────────────────
local function reportOnce()
    local pos = playerPos()
    local metres = CP.U.distToPolyline(pos, cur.polyline)
    if metres == math.huge then return end
    cur.metres = metres
    cur.distance = remainingAlong(pos)
    TriggerServerEvent(CP.e('server:routeStatus'), cur.runId, metres + 0.0, pos)
    showRoute()
end

local function routeThread(token)
    if not resample(token) then return end
    showRoute()
    while valid(token) and not cur.arrived do
        if cur.polyline and not cur.sampling then reportOnce() end
        local every = tonumber(Config.Route.reportEvery) or 2
        if every < 1 then every = 1 end
        Wait(math.floor(every * 1000))
    end
end

-- ── public API ──────────────────────────────────────────────────────────────
function R.current()
    if not cur then return nil end
    return { runId = cur.runId, arrived = cur.arrived, routeOn = cur.routeOn }
end

function R.stop()
    if not cur then return end
    local target = cur.target
    local pending = cur.recalcPending
    markEnded(cur.runId)                -- stopped (arrival or run end): never begun again for this run
    removeBlip()
    clearOurWaypoint(target)
    cur = nil
    if pending then pending.done = true; pending.p:resolve({ ok = false, stopped = true }) end
end

function R.begin(runId, startCoords, opts)
    if type(runId) ~= 'string' or runId == '' or endedRuns[runId] then return false end
    opts = type(opts) == 'table' and opts or {}
    if cur and cur.runId == runId then
        if opts.startRoute == false and cur.routeOn then
            cur.routeOn = false
            showRoute()
        end
        return true
    end
    local target = toVec3(startCoords)
    if not target then
        CP.warn(TAG, 'begin for run %s without start coords', runId)
        return false
    end
    if cur then R.stop() end
    tokenSeq = tokenSeq + 1
    cur = {
        runId = runId, target = target, radius = tonumber(opts.radius), token = tokenSeq,
        routeOn = opts.startRoute ~= false, arrived = false,
        polyline = nil, cum = nil, metres = nil, distance = nil, warning = nil, sampling = false,
    }
    setWaypoint()
    local token = tokenSeq
    if cur.routeOn then
        CreateThread(function() routeThread(token) end)   -- the HUD line appears once the route is sampled
    else
        showRoute()
    end
    return true
end

local function markArrived()
    if not cur or cur.arrived then return end
    local target = cur.target
    cur.arrived = true
    cur.warning = nil
    removeBlip()
    clearOurWaypoint(target)
    hudRoute({ status = 'arrived' })
    toast('success', 'route.arrived')
end

function R.recalculate()
    if not cur then return false, 'err.route_inactive' end
    if cur.arrived then return false, 'err.route_arrived' end
    if not cur.routeOn then return false, 'err.route_disabled' end
    if cur.recalcPending or cur.sampling then return false, 'err.busy' end
    local token = cur.token
    local pending = { p = promise.new(), done = false }
    cur.recalcPending = pending
    TriggerServerEvent(CP.e('server:recalcRoute'), cur.runId)
    SetTimeout(RECALC_TIMEOUT_MS, function()
        if not pending.done then
            pending.done = true
            pending.p:resolve({ ok = false, timeout = true })
        end
    end)
    local res = Citizen.Await(pending.p)
    if not valid(token) then return false, 'err.route_inactive' end
    cur.recalcPending = nil
    if res.timeout then return false, 'err.timeout' end
    if not res.ok then return false, 'err.route_no_recalcs' end
    if not resample(token) then return false, 'err.route_inactive' end
    showRoute()
    local left = tonumber(res.left) or 0
    toast('info', 'route.recalculated', { left = left })
    return true, { recalcsLeft = left }
end

-- ── server events ───────────────────────────────────────────────────────────
RegisterNetEvent(CP.e('client:routeWarning'), function(runId, secondsLeft)
    if not cur or cur.runId ~= runId or cur.arrived then return end
    if type(secondsLeft) == 'number' then
        local first = cur.warning == nil
        cur.warning = math.max(0, math.floor(secondsLeft))
        showRoute()
        if first then toast('warning', 'route.warning', { seconds = cur.warning }) end
    else
        local was = cur.warning ~= nil
        cur.warning = nil
        showRoute()
        if was then toast('success', 'route.back_on') end
    end
end)

RegisterNetEvent(CP.e('client:routeRecalc'), function(runId, ok, left)
    if not cur or cur.runId ~= runId then return end
    local pending = cur.recalcPending
    if not pending or pending.done then return end
    pending.done = true
    pending.p:resolve({ ok = ok == true, left = tonumber(left) })
end)

RegisterNetEvent(CP.e('client:routeStatus'), function(runId, status)
    if not cur or cur.runId ~= runId then return end
    if type(status) == 'table' and status.status == 'arrived' then markArrived() end
end)

RegisterNetEvent(CP.e('client:participants'), function(runId, list)
    if not cur or cur.runId ~= runId or cur.arrived or type(list) ~= 'table' then return end
    local me = GetPlayerServerId(PlayerId())
    for _, e in ipairs(list) do
        if type(e) == 'table' and tonumber(e.src) == me and e.arrived == true then
            markArrived()
            return
        end
    end
end)

-- Fallback: CP.Runs calls begin when it handles client:start. A second later, begin here too (a no-op for
-- the same runId), so the route can never be skipped; the delay lets the engine set up the HUD first.
-- Only for the latest client:start, and never for a run that has ended meanwhile.
RegisterNetEvent(CP.e('client:start'), function(runId, data)
    if type(runId) ~= 'string' or type(data) ~= 'table' then return end
    local start = type(data.start) == 'table' and data.start or nil
    if not start then return end
    latestStart = runId
    local coords, opts = start.coords, { startRoute = data.startRoute ~= false, radius = start.radius }
    SetTimeout(1000, function()
        if latestStart ~= runId or endedRuns[runId] then return end
        R.begin(runId, coords, opts)
    end)
end)

RegisterNetEvent(CP.e('client:runEnded'), function(runId)
    if type(runId) ~= 'string' then return end
    markEnded(runId)
    if cur and cur.runId == runId then R.stop() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    R.stop()
end)

-- ── client actions (registered once every module has loaded) ───────────────
CreateThread(function()
    Wait(0)
    if not (CP.Tablet and CP.Tablet.registerClientAction) then
        CP.err(TAG, 'modules/tablet is missing: Set GPS and Recalculate route are unavailable')
        return
    end
    CP.Tablet.registerClientAction('setGps', function()
        if not cur then return false, 'err.route_inactive' end
        setWaypoint()
        toast('info', 'route.gps_set')
        return true, { runId = cur.runId }
    end)
    CP.Tablet.registerClientAction('recalcRoute', function()
        return R.recalculate()
    end)
end)
