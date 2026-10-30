-- The builder_client slice: modules/builder/client.lua (CP.Builder, client side).

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                                  FAKE WORLD
-- ============================================================================

local vec = vector3
local W = {
    ped = 100,
    pos = { x = 1017.5, y = -3108.4, z = 5.9 },
    heading = 90.0,
    dead = false,
    veh = 0,
    driver = false,
    aim = nil,
    groundZ = 5.0,
    water = false,
    blocked = false,
    normalZ = 1.0,
    keys = {},
    ents = {},
    nextEnt = 5000,
    deleted = {},
    created = {},
    blips = {},
    removedBlips = 0,
    waypoints = {},
    waypointOff = 0,
    tasks = {},
    tempActions = {},
    stuckTargets = {},
    nodeDx = 0.0,
    nodeDz = 0.0,
    onRoad = false,
    pathCalls = 0,
    noPathCall = nil,
    pathRange = nil,
    zonesLive = 0,
    zonesMade = 0,
    coordsNoOffset = {},
    playerMoves = 0,
    capsules = 0,
    notVehicle = false,
}

local function NewEnt(kind, x, y, z, net)
    W.nextEnt = W.nextEnt + 1
    local e = W.nextEnt
    W.ents[e] = { kind = kind, coords = { x = x, y = y, z = z }, net = net }
    W.created[#W.created + 1] = { e = e, kind = kind, net = net }
    return e
end

_G.PlayerPedId = function() return W.ped end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 7 end
_G.GetEntityCoords = function(e)
    if e == W.ped then return vec(W.pos.x, W.pos.y, W.pos.z) end
    local ent = W.ents[e]
    if ent then return vec(ent.coords.x, ent.coords.y, ent.coords.z) end
    return vec(0.0, 0.0, 0.0)
end
_G.GetEntityHeading = function() return W.heading end
_G.IsEntityDead = function(e) if e == W.ped then return W.dead end return false end
_G.GetVehiclePedIsIn = function() return W.veh end
_G.GetPedInVehicleSeat = function(veh, seat)
    if veh == W.veh and seat == -1 and W.driver then return W.ped end
    return 0
end
_G.GetGameplayCamCoord = function() return vec(W.pos.x, W.pos.y, W.pos.z + 1.5) end
_G.GetGameplayCamRot = function() return vec(0.0, 0.0, 0.0) end
_G.StartExpensiveSynchronousShapeTestLosProbe = function() return 1 end
_G.StartShapeTestCapsule = function() W.capsules = W.capsules + 1; return 2 end
_G.GetShapeTestResult = function(handle)
    if handle == 1 then
        if not W.aim then return 2, 0, vec(0.0, 0.0, 0.0), vec(0.0, 0.0, 1.0), 0 end
        return 2, 1, vec(W.aim.x, W.aim.y, W.aim.z), vec(0.0, 0.0, W.normalZ), 0
    end
    return 2, W.blocked and 1 or 0, vec(0.0, 0.0, 0.0), vec(0.0, 0.0, 1.0), 0
end
_G.GetGroundZFor_3dCoord = function() return true, W.groundZ end
_G.TestProbeAgainstWater = function() return W.water end
_G.IsEntityInWater = function() return W.swimming == true end
_G.GetWaterHeight = function() return false, 0.0 end
_G.IsModelInCdimage = function() return true end
_G.IsModelAPed = function() return true end
_G.IsModelAVehicle = function() return not W.notVehicle end
_G.HasModelLoaded = function() return true end
_G.GetModelDimensions = function() return vec(-1.0, -2.4, -0.6), vec(1.0, 2.4, 1.0) end
_G.CreatePed = function(_, _, x, y, z, _, net) return NewEnt('ped', x, y, z, net) end
_G.CreateVehicle = function(_, x, y, z, _, net) return NewEnt('vehicle', x, y, z, net) end
_G.CreatePedInsideVehicle = function(veh, _, _, seat, net) return NewEnt('driver', 0.0, 0.0, 0.0, net) end
_G.DoesEntityExist = function(e) return W.ents[e] ~= nil end
_G.DeleteEntity = function(e) W.deleted[#W.deleted + 1] = e; W.ents[e] = nil end
_G.SetEntityCoordsNoOffset = function(e, x, y, z) W.coordsNoOffset[#W.coordsNoOffset + 1] = e end
_G.SetEntityCoords = function() W.playerMoves = W.playerMoves + 1 end
_G.AddBlipForEntity = function() local b = 900 + #W.blips + 1; W.blips[b] = true; return b end
_G.DoesBlipExist = function(b) return W.blips[b] == true end
_G.RemoveBlip = function(b) W.blips[b] = nil; W.removedBlips = W.removedBlips + 1 end
_G.SetNewWaypoint = function(x, y) W.waypoints[#W.waypoints + 1] = { x = x, y = y } end
_G.SetWaypointOff = function() W.waypointOff = W.waypointOff + 1 end
_G.GetClosestVehicleNodeWithHeading = function(x, y, z)
    return true, vec(x + W.nodeDx, y, z + W.nodeDz), 0.0
end
_G.IsPointOnRoad = function() return W.onRoad end
_G.CalculateTravelDistanceBetweenPoints = function(ax, ay, az, bx, by, bz)
    W.pathCalls = W.pathCalls + 1
    if W.pathCalls == W.noPathCall then return 100000.0 end
    if W.pathRange then
        -- the game streams path nodes around the player only: further away the native fails
        local here = W.ents[W.veh] and W.ents[W.veh].coords or W.pos
        local function far(x, y) return math.sqrt((x - here.x) ^ 2 + (y - here.y) ^ 2) > W.pathRange end
        if far(ax, ay) or far(bx, by) then return 100000.0 end
    end
    return math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2 + (bz - az) ^ 2)
end
_G.TaskVehicleDriveToCoordLongrange = function(driver, veh, x, y, z, speed, style, stop)
    W.tasks[#W.tasks + 1] = {
        driver = driver,
        veh = veh,
        x = x,
        y = y,
        z = z,
        speed = speed,
        style = style,
        stop = stop,
    }
    if W.stuckTargets[x] then return end
    local ent = W.ents[veh]
    if ent then ent.coords = { x = x, y = y, z = z } end
end
_G.TaskVehicleTempAction = function(driver, veh, action, ms)
    W.tempActions[#W.tempActions + 1] = { action = action, ms = ms }
end
_G.GetEntitySpeed = function() return 10.0 end
_G.IsVehicleDriveable = function() return true end
_G.IsDisabledControlJustPressed = function(_, c) return W.keys[c] == true end
_G.IsDisabledControlPressed = function() return false end
_G.IsControlPressed = function() return false end
for _, n in ipairs({
    'RequestModel',
    'SetModelAsNoLongerNeeded',
    'SetEntityAsMissionEntity',
    'SetEntityAlpha',
    'SetEntityCollision',
    'FreezeEntityPosition',
    'SetEntityInvincible',
    'SetEntityVisible',
    'SetEntityHeading',
    'SetBlockingOfNonTemporaryEvents',
    'SetPedCanRagdoll',
    'SetVehicleDoorsLocked',
    'SetVehicleEngineOn',
    'SetVehicleOnGroundProperly',
    'SetPedKeepTask',
    'SetPedCanBeDraggedOut',
    'SetDriverAbility',
    'SetDriverAggressiveness',
    'SetBlipSprite',
    'SetBlipColour',
    'BeginTextCommandSetBlipName',
    'EndTextCommandSetBlipName',
    'AddTextComponentSubstringPlayerName',
    'DisableControlAction',
    'PlaySoundFrontend',
    'DrawMarker',
    'DrawLine',
    'SetDrawOrigin',
    'SetTextScale',
    'SetTextFont',
    'SetTextCentre',
    'SetTextOutline',
    'SetTextColour',
    'BeginTextCommandDisplayText',
    'EndTextCommandDisplayText',
    'ClearDrawOrigin',
}) do
    _G[n] = function() end
end
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn }
end
_G.LocalPlayer = { state = {} }
_G.lib.zones = {
    sphere = function(o)
        W.zonesLive, W.zonesMade = W.zonesLive + 1, W.zonesMade + 1
        W.lastZone = o
        return {
            remove = function() W.zonesLive = W.zonesLive - 1 end,
        }
    end,
}

-- Translate with this slice's locale part (locales/en.json is only merged at release).
local strings
do
    local fh = assert(io.open(H.root .. 'locales/parts/builder_client.json', 'r'))
    strings = json.decode(fh:read('a'))
    fh:close()
    local realL = CP.L
    CP.L = function(key, vars)
        local text = strings[key]
        if text == nil then return realL(key, vars) end
        return (
            text:gsub('{([%w_]+)}', function(k)
                local v = vars and vars[k]
                if v == nil then return '{' .. k .. '}' end
                return tostring(v)
            end)
        )
    end
end

-- ============================================================================
--                     CP.Tablet, CP.Runs, CP.Qbx STAND-INS
-- ============================================================================

local T = { isOpen = true, closes = 0, opens = {}, overlays = {}, pushes = {}, toasts = {}, actions = {} }
CP.Tablet = {
    isOpen = function() return T.isOpen end,
    close = function() T.closes = T.closes + 1; T.isOpen = false end,
    open = function(ui) T.opens[#T.opens + 1] = ui; T.isOpen = true end,
    overlay = function(o) T.overlays[#T.overlays + 1] = o or false end,
    push = function(topic, data) T.pushes[#T.pushes + 1] = { topic = topic, data = data } end,
    notify = function(kind, text) T.toasts[#T.toasts + 1] = { kind = kind, text = text } end,
    registerClientAction = function(name, fn) T.actions[name] = fn end,
}
local currentRun = nil
CP.Runs = {
    current = function() return currentRun end,
}
local unloadFns = {}
CP.Qbx = {
    onUnload = function(fn) unloadFns[#unloadFns + 1] = fn end,
}

H.load('modules/builder/client.lua')
local B = CP.Builder

local function Act(name, payload) return T.actions[name](payload) end
local function Frame(keys, ms)
    W.keys = {}
    for _, k in ipairs(keys or {}) do W.keys[k] = true end
    H.step(ms or 16)
    W.keys = {}
end
local function Frames(n, ms) for _ = 1, n do Frame(nil, ms) end end
local function LastOverlay(kind)
    for i = #T.overlays, 1, -1 do
        local o = T.overlays[i]
        if o and (not kind or o.kind == kind) then return o end
    end
    return nil
end
local function LastPush() return T.pushes[#T.pushes] end
local function Has(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end
local KEY = { E = 38, BACK = 194, DELETE = 178, ENTER = 191, P = 199, X = 73, WHEEL_UP = 15 }
local DOCKS = { x = 1017.52, y = -3108.44, z = 5.9 }

-- ============================================================================
--                                 REGISTRATION
-- ============================================================================

for _, name in ipairs({
    'builderPlace',
    'builderRecord',
    'builderTestDrive',
    'builderResult',
    'builderCancel',
    'builderWaypoint',
    'builderHere',
    'builderAutoPoints',
    'builderCheckPoints',
    'builderTeleport',
    'builderShowMap',
}) do
    H.ok(type(T.actions[name]) == 'function', 'client action registered: ' .. name)
end
H.ok(H.handlers[CP.e('client:builder')] ~= nil, 'crimson-police:client:builder handler registered')
H.eq(CP.e('client:builder'), 'crimson-police:client:builder', 'event name')
H.ok(H.handlers.onResourceStop ~= nil, 'onResourceStop handler registered')
H.eq(#bagHandlers, 1, 'one state bag handler')
H.eq(bagHandlers[1].key, 'crimsonArena', 'the handler watches crimsonArena')
H.eq(bagHandlers[1].bag, 'player:7', 'on the local player bag')
H.eq(#unloadFns, 1, 'a character unload handler')
H.eq(B.active(), nil, 'no tool at start')

-- ============================================================================
--                                 PURE HELPERS
-- ============================================================================

H.near(B.headingOf({ x = 0, y = 0 }, { x = 0, y = 10 }), 0.0, 1e-6, 'heading north = 0')
H.near(B.headingOf({ x = 0, y = 0 }, { x = -10, y = 0 }), 90.0, 1e-6, 'heading west = 90')
H.near(B.headingOf({ x = 0, y = 0 }, { x = 0, y = -10 }), 180.0, 1e-6, 'heading south = 180')
H.near(B.headingOf({ x = 0, y = 0 }, { x = 10, y = 0 }), 270.0, 1e-6, 'heading east = 270')
H.near(B.routeLength({ { x = 0, y = 0, z = 0 }, { x = 30, y = 40, z = 0 }, { x = 30, y = 40, z = 12 } }), 62.0, 1e-6,
    'route length')
H.eq(B.routeLength({}), 0.0, 'empty route length')
do
    local pts = {}
    for i = 1, 30 do pts[i] = { x = i, y = 0, z = 0 } end
    local th = B.thin(pts, 8)
    H.eq(#th, 8, 'thin keeps max points')
    H.eq(th[1].x, 1, 'thin keeps the first point')
    H.eq(th[8].x, 30, 'thin keeps the last point')
    for i = 2, #th do H.ok(th[i].x > th[i - 1].x, 'thin keeps the order ' .. i) end
    H.eq(#B.thin(pts, 40), 30, 'thin leaves a short list alone')
    H.ok(B.thin(pts, 40) ~= pts, 'thin returns a copy')
end
H.eq(B.drivingStyle('careful'), 786603, 'careful style')
H.eq(B.drivingStyle('cautious'), 786603, 'cautious style')
H.eq(B.drivingStyle('normal'), 786475, 'normal style')
H.eq(B.drivingStyle('fast'), 786492, 'fast style')
H.eq(B.drivingStyle('reckless'), 786492, 'reckless keeps to its lanes')
H.eq(B.drivingStyle('nonsense'), 786475, 'unknown style is normal')

-- ============================================================================
--                              THE ROUTE RECORDER
-- ============================================================================

do
    local rec = B.newRecorder({ turnAngle = 30, maxGap = 150 })
    -- 400 m straight north, one sample every 25 m
    for i = 0, 16 do H.ok(rec:add({ x = 0, y = i * 25.0, z = 10 }), 'sample ' .. i .. ' kept') end
    H.eq(rec:add({ x = 0.4, y = 400.3, z = 10 }), false, 'a sample closer than 1 m is a duplicate')
    H.eq(rec:count(), 17, 'samples')
    local wps = rec:waypoints()
    H.eq(wps[1].y, 0.0, 'first waypoint is the first sample')
    H.eq(wps[#wps].y, 400.0, 'waypoints end at the current end')
    for i = 2, #wps do
        H.ok(wps[i].y - wps[i - 1].y <= 150.0 + 1e-6, 'waypoint gap at most maxGap (' .. i .. ')')
    end
    H.ok(#wps < 17, 'a straight road keeps few waypoints (' .. #wps .. ')')
    H.near(rec:length(), 400.0, 1e-6, 'length of a straight recording')
    -- a right turn east: the corner becomes a waypoint
    for i = 1, 4 do rec:add({ x = i * 25.0, y = 400.0, z = 10 }) end
    local corner = false
    for _, p in ipairs(rec:waypoints()) do if p.x == 0 and p.y == 400.0 then corner = true end end
    H.ok(corner, 'the sample at the turn is a waypoint')
    H.near(rec:length(), 500.0, 1e-6, 'length through the corner')
    -- undo 100 m: back to the corner
    local removed = rec:undo(100)
    H.near(removed, 100.0, 1e-6, 'undo removes 100 m')
    H.eq(rec:endPoint().x, 0.0, 'end back at the corner (x)')
    H.eq(rec:endPoint().y, 400.0, 'end back at the corner (y)')
    H.near(rec:length(), 400.0, 1e-6, 'length after undo')
    -- stops
    H.ok(rec:addStop(20, 2), 'a stop at the current end')
    local ok2, why2 = rec:addStop(20, 2)
    H.eq(ok2, false, 'a second stop on the same waypoint is refused')
    H.eq(why2, 'builder.rec.stop_here', 'reason stop_here')
    rec:add({ x = 25.0, y = 400.0, z = 10 })
    rec:add({ x = 50.0, y = 400.0, z = 10 })
    H.ok(rec:addStop(20, 2), 'a second stop further on')
    local ok3, why3 = rec:addStop(20, 2)
    H.eq(ok3, false, 'no more than max stops')
    H.eq(why3, 'builder.rec.stop_max', 'reason stop_max')
    local pts, stops, dropped = rec:finish()
    H.eq(pts[#pts].x, 50.0, 'finish ends at the last sample')
    H.eq(#stops, 1, 'the stop on the last waypoint is dropped')
    H.eq(dropped, 1, 'one dropped stop')
    H.eq(pts[stops[1].at].y, 400.0, 'the kept stop is at the corner')
    H.eq(pts[stops[1].at].x, 0.0, 'the kept stop is at the corner (x)')
    H.eq(stops[1].wait, 20, 'stop wait')
    -- undo that removes a stop's waypoint removes the stop
    local rec2 = B.newRecorder({})
    for i = 0, 8 do rec2:add({ x = 0, y = i * 25.0, z = 0 }) end
    H.ok(rec2:addStop(15, 5), 'stop at 200 m')
    rec2:undo(60)
    H.eq(#rec2.stops, 0, 'undo past a stop removes it')
    local early = B.newRecorder({})
    early:add({ x = 0, y = 0, z = 0 })
    local okE, whyE = early:addStop(15, 5)
    H.eq(okE, false, 'no stop before the second sample')
    H.eq(whyE, 'builder.rec.stop_too_early', 'reason stop_too_early')
    H.eq(early:undo(100), 0.0, 'undo keeps the first sample')
    H.eq(early:count(), 1, 'first sample kept')
    local pts1 = early:finish()
    H.eq(#pts1, 1, 'a one-sample recording has one point')
    -- turnAngle: a gentle bend under 30 degrees keeps no extra waypoint
    local rec3 = B.newRecorder({ turnAngle = 30, maxGap = 1000 })
    rec3:add({ x = 0, y = 0, z = 0 })
    rec3:add({ x = 0, y = 25, z = 0 })
    rec3:add({ x = 5, y = 50, z = 0 })     -- about 11 degrees
    rec3:add({ x = 10, y = 75, z = 0 })
    H.eq(#rec3:waypoints(), 2, 'a gentle bend keeps only the ends')
end

-- ============================================================================
--                               PLACEMENT CHECKS
-- ============================================================================

do
    local good = {
        hit = true,
        x = 1050,
        y = -3108,
        z = 5.0,
        groundZ = 5.0,
        normalZ = 1.0,
        water = false,
        blocked = false,
        distance = 30,
    }
    local function Spot(over)
        local s = {}
        for k, v in pairs(good) do s[k] = v end
        for k, v in pairs(over or {}) do if v == 'NIL' then s[k] = nil else s[k] = v end end
        return s
    end
    local ctx = {
        kind = 'ped',
        points = {},
        multiple = true,
        max = 3,
        zones = Config.Builder.noBuildZones,
        spawn = true,
        start = DOCKS,
        minFromStart = 30,
        otherStarts = {},
        minLocationGap = 100,
        minGap = 0,
        maxDistance = 50,
    }
    H.eq(B.checkSpot(Spot(), ctx), true, 'a good spot')
    local function Reason(s, c)
        local ok, key, vars = B.checkSpot(s, c or ctx)
        return ok and 'ok' or key, vars
    end
    H.eq(Reason({ hit = false }), 'builder.place.reason.no_hit', 'nothing aimed at')
    H.eq(Reason(nil), 'builder.place.reason.no_hit', 'no spot')
    H.eq(Reason(Spot({ distance = 60 })), 'builder.place.reason.far', 'too far away')
    H.eq(Reason(Spot({ x = 470.63, y = -974.11, z = 30.18, groundZ = 30.18 })), 'builder.place.reason.zone',
        'in a no-build zone')
    local _, zv = Reason(Spot({ x = 470.63, y = -974.11 }))
    H.eq(zv.zone, 'Mission Row PD and FIB HQ', 'zone label in the reason vars')
    H.eq(Reason(Spot({ water = true })), 'builder.place.reason.water', 'in water')
    H.eq(Reason(Spot({ z = 9.0 })), 'builder.place.reason.not_ground', 'on a roof or wall above the ground')
    H.eq(Reason(Spot({ groundZ = 'NIL' })), 'builder.place.reason.not_ground', 'no ground found')
    H.eq(Reason(Spot({ normalZ = 0.4 })), 'builder.place.reason.steep', 'too steep')
    H.eq(Reason(Spot({ blocked = 'NIL' })), 'builder.place.reason.checking', 'probe pending')
    H.eq(Reason(Spot({ blocked = true })), 'builder.place.reason.blocked', 'inside a wall or object')
    local k, v = Reason(Spot({ x = 1030 }))
    H.eq(k, 'builder.place.reason.start', 'spawn too close to the start')
    H.eq(v.min, 30, 'min distance in vars')
    -- armed spawns (shootout, boss, ambush and pursuit cars, door associates): outside the start circle plus
    -- Config.Builder.spawnMargin, 2D, as the server (CP.Builder.armedKeepOut)
    local actx = {}
    for key, value in pairs(ctx) do actx[key] = value end
    actx.armed, actx.startRadius, actx.spawnMargin = true, 60, 40
    k, v = Reason(Spot({ x = 1067.52 }), actx)
    H.eq(k, 'builder.place.reason.armed', 'an armed spawn 50 m from a 60 m start is refused')
    H.eq(v.min, 100, 'the start circle plus the margin in the vars')
    H.ok(CP.L(k, v):find('100 m', 1, true) ~= nil, 'the message names the distance: ' .. CP.L(k, v))
    H.eq(Reason(Spot({ x = 1118.52 }), actx), 'ok', 'an armed spawn 101 m out is placed')
    H.eq(Reason(Spot({ x = 1067.52 }), ctx), 'ok', 'an unarmed spawn (a hostage) 50 m out is placed: 30 m floor')
    actx.spawnMargin = 0
    H.eq(Reason(Spot({ x = 1067.52 }), actx), 'builder.place.reason.armed', 'margin 0: still outside the 60 m circle')
    H.eq(Reason(Spot({ x = 1079.52 }), actx), 'ok', 'margin 0: 62 m from a 60 m start is placed')
    H.eq(B.armedKeepOut({ armed = true, startRadius = 10, spawnMargin = 5, minFromStart = 30 }), 30,
        'the keep-out is never under minFromStart')
    H.eq(B.armedKeepOut({ startRadius = 60, spawnMargin = 40, minFromStart = 30 }), nil, 'not armed: no keep-out')
    H.eq(B.armedKeepOut({ armed = true, spawnMargin = 40 }), nil, 'no start circle (a search circle): no keep-out')
    -- markers: aimed surface counts, no ground or probe checks
    local mctx = { kind = 'marker', points = {}, multiple = true, max = 5, zones = {}, maxDistance = 50 }
    H.eq(Reason(Spot({ z = 9.0, blocked = 'NIL' }), mctx), 'ok', 'a marker on a raised surface')
    H.eq(Reason(Spot({ water = true }), mctx), 'builder.place.reason.water', 'markers not in water')
    -- max
    local full = { kind = 'marker', points = { {}, {}, {} }, multiple = true, max = 3, zones = {} }
    H.eq(Reason(Spot(), full), 'builder.place.reason.max', 'every point placed')
    -- start gap (2D) to other starts
    local sctx = {
        kind = 'start',
        points = {},
        multiple = false,
        zones = {},
        otherStarts = { { x = 1100, y = -3108, z = 50 } },
        minLocationGap = 100,
        maxDistance = 50,
    }
    H.eq(Reason(Spot(), sctx), 'builder.place.reason.gap', 'a start closer than minLocationGap to another start')
    sctx.otherStarts = { { x = 1200, y = -3108, z = 5 } }
    H.eq(Reason(Spot(), sctx), 'ok', 'a start far enough from the others')
    -- spacing between points of one key
    local gctx = {
        kind = 'marker',
        points = { { x = 1050, y = -3100, z = 5 } },
        multiple = true,
        max = 5,
        zones = {},
        minGap = 40,
    }
    H.eq(Reason(Spot(), gctx), 'builder.place.reason.spacing', 'closer than minGap to a placed point')
    gctx.minGap = 5
    H.eq(Reason(Spot(), gctx), 'ok', 'spacing satisfied')
    -- the start distance and the spacing count the point as it is stored (a ped stands 1 m above the ground), as
    -- the server does: 29.9 m out and 3 m below the start is 30.05 m from the aimed spot, 29.97 m stored
    local porch = { x = 1000.0, y = -3108.0, z = 10.0 }
    local low = Spot({ x = 1029.9, y = -3108.0, z = 7.0, groundZ = 7.0 })
    local pctx = {}
    for key, value in pairs(ctx) do pctx[key] = value end
    pctx.start = porch
    H.eq(Reason(low, pctx), 'ok', '(30.05 m from the aimed spot)')
    low.stored = { x = 1029.9, y = -3108.0, z = 8.0 }
    H.eq(Reason(low, pctx), 'builder.place.reason.start', 'the start distance uses the stored height')
    low.stored = { x = 1030.1, y = -3108.0, z = 8.0 }
    H.eq(Reason(low, pctx), 'ok', '30.17 m stored is far enough')
    local near = Spot({ x = 1050.0, y = -3108.0, z = 5.0, stored = { x = 1050.0, y = -3108.0, z = 6.0 } })
    local nctx = {
        kind = 'ped',
        points = { { x = 1057.95, y = -3108.0, z = 6.0 } },
        multiple = true,
        max = 5,
        zones = {},
        minGap = 8,
    }
    H.eq(Reason(near, nctx), 'builder.place.reason.spacing', 'the spacing uses the stored height (7.95 m apart)')
end

-- ============================================================================
--                               PAYLOAD PARSING
-- ============================================================================

do
    local base = {
        missionId = 'custom_dockside_raid',
        location = 1,
        key = 'spawns',
        kind = 'ped',
        heading = true,
        multiple = true,
        min = 2,
        max = 3,
        points = {},
        start = DOCKS,
        spawn = true,
        otherStarts = {},
    }
    local function With(over)
        local p = {}
        for k, v in pairs(base) do p[k] = v end
        for k, v in pairs(over or {}) do if v == 'NIL' then p[k] = nil else p[k] = v end end
        return p
    end
    local o = assert(B.parsePlace(With()))
    H.eq(o.ui, 'supervisor', 'ui defaults to supervisor')
    H.eq(o.min, 2, 'min')
    H.eq(o.max, 3, 'max')
    H.eq(o.heading, true, 'heading')
    H.eq(o.spawn, true, 'spawn')
    H.eq(o.armed, false, 'not armed unless asked')
    local ap = assert(B.parsePlace(With({ armed = true, startRadius = 60 })))
    H.eq(ap.armed, true, 'an armed spawn key')
    H.eq(ap.startRadius, 60, 'the start circle is passed on')
    H.eq(assert(B.parsePlace(With({ armed = true, spawn = false }))).armed, false, 'armed only for a spawn key')
    H.eq(select(2, B.parsePlace(With({ armed = 'yes' }))), 'err.invalid_payload', 'armed must be boolean')
    H.eq(select(2, B.parsePlace(With({ startRadius = -1 }))), 'err.invalid_payload', 'a negative start circle')
    H.eq(select(2, B.parsePlace(With({ startRadius = 'big' }))), 'err.invalid_payload', 'start circle must be a number')
    H.eq(o.start.w, nil, 'the start carries no heading')
    H.eq(select(2, B.parsePlace(With({ kind = 'tree' }))), 'err.invalid_payload', 'bad kind')
    H.eq(select(2, B.parsePlace(With({ missionId = 'bad id!' }))), 'err.invalid_payload', 'bad mission id')
    H.eq(select(2, B.parsePlace(With({ location = 0 }))), 'err.invalid_payload', 'bad location')
    H.eq(select(2, B.parsePlace(With({ key = '1abc' }))), 'err.invalid_payload', 'bad key')
    H.eq(select(2, B.parsePlace(With({ ui = 'officer' }))), 'err.invalid_payload', 'bad ui')
    H.eq(select(2, B.parsePlace(With({ heading = 'yes' }))), 'err.invalid_payload', 'heading must be boolean')
    H.eq(select(2, B.parsePlace(With({ max = 0 }))), 'err.invalid_payload', 'max at least 1')
    H.eq(select(2, B.parsePlace(With({ points = { { x = 'a', y = 0, z = 0 } } }))), 'err.invalid_payload', 'bad point')
    H.eq(select(2, B.parsePlace(With({ points = { { x = 99999, y = 0, z = 0 } } }))), 'err.invalid_payload',
        'point off the map')
    H.eq(select(2, B.parsePlace(With({ minGap = -1 }))), 'err.invalid_payload', 'negative minGap')
    H.eq(select(2, B.parsePlace(With({ model = 'bad model' }))), 'err.invalid_payload', 'bad model name')
    H.eq(select(2, B.parsePlace('x')), 'err.invalid_payload', 'not a table')
    -- kerb spots (field_contact parked): the result names the street at each point
    H.eq(o.streets, false, 'no street names unless asked')
    H.eq(assert(B.parsePlace(With({ streets = true }))).streets, true, 'streets asked for kerb spots')
    H.eq(select(2, B.parsePlace(With({ streets = 'yes' }))), 'err.invalid_payload', 'streets must be boolean')
    -- aliases of the task text
    local a = assert(
        B.parsePlace(With({ max = 'NIL', count = 4, points = 'NIL', existing = { { x = 1, y = 2, z = 3, w = 400 } } })))
    H.eq(a.max, 4, 'count is an alias of max')
    H.eq(#a.points, 1, 'existing is an alias of points')
    H.eq(a.points[1].w, 40.0, 'headings are normalised')
    -- a single point keeps the last existing one
    local s = assert(B.parsePlace(With({
        multiple = false,
        min = 'NIL',
        max = 'NIL',
        points = { { x = 1, y = 1, z = 1 }, { x = 2, y = 2, z = 2 } },
    })))
    H.eq(s.max, 1, 'single: max 1')
    H.eq(s.min, 1, 'single: min 1')
    H.eq(#s.points, 1, 'single: one point kept')
    H.eq(s.points[1].x, 2.0, 'single: the last point kept')
    -- extra points beyond max are dropped; min is capped by max
    local m = assert(B.parsePlace(With({
        min = 5,
        max = 2,
        points = { { x = 1, y = 1, z = 1 }, { x = 2, y = 2, z = 2 }, { x = 3, y = 3, z = 3 } },
    })))
    H.eq(#m.points, 2, 'points beyond max dropped')
    H.eq(m.min, 2, 'min capped by max')
    -- areas and starts: radius clamped, no heading
    local st = assert(B.parsePlace(With({ kind = 'start', heading = true, multiple = true, radius = 500 })))
    H.eq(st.radius, 150.0, 'start radius clamped to 150')
    H.eq(st.heading, false, 'starts carry no heading')
    H.eq(st.multiple, false, 'one start per location')
    local ar = assert(B.parsePlace(With({ kind = 'area', radiusMin = 10, radiusMax = 40, radius = 5 })))
    H.eq(ar.radius, 10, 'area radius clamped to radiusMin')
    H.eq(ar.radiusMax, 40, 'radiusMax')
    H.eq(select(2, B.parsePlace(With({ kind = 'area', radiusMin = 50, radiusMax = 40 }))), 'err.invalid_payload',
        'radiusMax below radiusMin')
    local mk = assert(B.parsePlace(With({ kind = 'marker', radius = 75 })))
    H.eq(mk.showRadius, 75, 'a marker radius is only drawn')
    H.eq(mk.radius, nil, 'a marker returns no radius')
    local h0 = assert(B.parsePlace(With({ heading = false, points = { { x = 1, y = 1, z = 1, w = 90 } } })))
    H.eq(h0.points[1].w, nil, 'no heading: w removed')
    -- labels: trimmed, at most 64 characters (UTF-8)
    local long = string.rep('é', 80)
    local lb = assert(B.parsePlace(With({ label = '  ' .. long .. '  ' })))
    H.eq(utf8.len(lb.label), 64, 'label clipped to 64 characters')
    H.eq(assert(B.parsePlace(With({ label = '   ' }))).label, nil, 'blank label dropped')
    H.eq(select(2, B.parsePlace(With({ label = 5 }))), 'err.invalid_payload', 'label must be text')

    local r = assert(B.parseRecord({ missionId = 'm1', location = 2, key = 'route', block = 'escort' }))
    H.eq(r.stops, true, 'block = \'escort\' enables stops')
    H.eq(r.loop, false, 'loop defaults to false')
    local r2 = assert(
        B.parseRecord({ missionId = 'm1', location = 2, key = 'raceLoop', stops = false, loop = true, block = 'escort' }))
    H.eq(r2.stops, false, 'explicit stops wins over the block alias')
    H.eq(r2.loop, true, 'loop')
    H.eq(select(2, B.parseRecord({ missionId = 'm1', location = 2, key = 'route', loop = 1 })), 'err.invalid_payload',
        'loop must be boolean')

    local route = { points = { { x = 0, y = 0, z = 0 }, { x = 0, y = 100, z = 0 } }, stops = { { at = 2, wait = 10 } } }
    local td = assert(B.parseTestDrive({
        missionId = 'm1',
        location = 1,
        key = 'route',
        route = route,
        vehicle = 'stockade',
        speed = 60,
        style = 'reckless',
    }))
    H.eq(td.vehicle, 'stockade', 'escort vehicle allowed')
    H.eq(td.style, 'reckless', 'style kept')
    H.eq(#td.stops, 1, 'stops kept')
    local td2 = assert(B.parseTestDrive({
        missionId = 'm1',
        location = 1,
        key = 'route',
        route = route,
        vehicle = 'sultan',
        speed = 60,
        style = 'drifting',
    }))
    H.eq(td2.style, 'normal', 'unknown style falls back to normal')
    H.eq(select(
        2,
        B.parseTestDrive({
            missionId = 'm1',
            location = 1,
            key = 'route',
            route = route,
            vehicle = 'adder',
            speed = 60,
        })
    ), 'err.builder_bad_vehicle', 'a vehicle outside Config.Builder.allowed')
    H.eq(select(
        2,
        B.parseTestDrive({
            missionId = 'm1',
            location = 1,
            key = 'route',
            route = route,
            vehicle = 'sultan',
            speed = 400,
        })
    ), 'err.invalid_payload', 'speed out of range')
    H.eq(select(
        2,
        B.parseTestDrive({
            missionId = 'm1',
            location = 1,
            key = 'route',
            route = { points = { { x = 0, y = 0, z = 0 } } },
            vehicle = 'sultan',
            speed = 60,
        })
    ), 'err.invalid_payload', 'a route needs two points')
    H.eq(select(
        2,
        B.parseTestDrive({
            missionId = 'm1',
            location = 1,
            key = 'route',
            route = { points = route.points, stops = { { at = 9, wait = 10 } } },
            vehicle = 'sultan',
            speed = 60,
        })
    ), 'err.invalid_payload', 'a stop outside the route')
end

-- ============================================================================
--                                   REFUSALS
-- ============================================================================

local placePayload = {
    missionId = 'custom_dockside_raid',
    location = 1,
    key = 'spawns',
    kind = 'ped',
    model = 'g_m_y_lost_01',
    heading = true,
    multiple = true,
    min = 2,
    max = 3,
    points = {},
    start = DOCKS,
    spawn = true,
    otherStarts = {},
    ui = 'admin',
    label = 'Hostile spawn points',
}
local recordPayload = {
    missionId = 'custom_quarry_escort',
    location = 1,
    key = 'route',
    block = 'escort',
    label = 'Escort route',
}
local drivePayload = {
    missionId = 'custom_quarry_escort',
    location = 1,
    key = 'route',
    vehicle = 'stockade',
    speed = 60,
    style = 'reckless',
    route = {
        points = {
            { x = 1000, y = -3000, z = 5 },
            { x = 1000, y = -2900, z = 5 },
            { x = 1100, y = -2900, z = 5 },
            { x = 1200, y = -2900, z = 5 },
        },
        stops = { { at = 2, wait = 5 } },
    },
}
do
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena', matchId = 3 }
    H.eq(select(2, Act('builderPlace', placePayload)), 'err.in_arena', 'placement refused in Crimson-Arena')
    H.eq(select(2, Act('builderRecord', recordPayload)), 'err.in_arena', 'recording refused in Crimson-Arena')
    H.eq(select(2, Act('builderTestDrive', drivePayload)), 'err.in_arena', 'test drive refused in Crimson-Arena')
    H.eq(select(2, Act('builderWaypoint', { coords = { x = 1, y = 2, z = 3 } })), 'err.in_arena',
        'GPS waypoint refused in Crimson-Arena')
    H.eq(#W.waypoints, 0, 'no waypoint set in the arena')
    LocalPlayer.state.crimsonArena = { active = false, source = 'crimson-arena' }
    H.eq((Act('builderWaypoint', { coords = { x = 1, y = 2, z = 3 } })), true,
        'an inactive arena value does not refuse')
    H.eq(W.waypoints[1].x, 1, 'GPS waypoint set')
    H.eq(select(2, Act('builderWaypoint', { coords = 'here' })), 'err.invalid_payload', 'waypoint needs coords')
    LocalPlayer.state.crimsonArena = nil
    W.dead = true
    H.eq(select(2, Act('builderPlace', placePayload)), 'err.builder_dead', 'refused while dead')
    W.dead = false
    currentRun = { runId = 'r1' }
    H.eq(select(2, Act('builderRecord', recordPayload)), 'err.builder_on_run', 'refused on a mission run')
    currentRun = nil
    Config.Builder.enabled = false
    H.eq(select(2, Act('builderPlace', placePayload)), 'err.builder_disabled', 'refused while the builder is disabled')
    Config.Builder.enabled = true
    H.eq(select(2, Act('builderPlace', { missionId = 'x' })), 'err.invalid_payload', 'a bad payload')
    W.notVehicle = true
    H.eq(select(2, Act('builderTestDrive', drivePayload)), 'err.builder_bad_vehicle', 'a model that is no vehicle')
    W.notVehicle = false
    H.eq(B.active(), nil, 'nothing started by the refusals')
    H.eq(T.closes, 0, 'the tablet stayed open')
    local okC, dataC = Act('builderCancel', {})
    H.eq(okC, true, 'builderCancel answers')
    H.eq(dataC.cancelled, false, 'nothing to cancel')
    local okR, dataR = Act('builderResult', {})
    H.eq(okR, true, 'builderResult answers')
    H.eq(dataR, nil, 'no result yet')
end

-- ============================================================================
--                               A PLACEMENT RUN
-- ============================================================================

do
    T.isOpen = true
    W.aim = { x = 1050.0, y = -3108.4, z = 5.0 }
    local ok, data = Act('builderPlace', placePayload)
    H.eq(ok, true, 'placement starts')
    H.eq(data.started, true, 'immediate { started = true }')
    H.eq(B.active(), 'placement', 'the placement tool runs')
    H.eq(select(2, Act('builderRecord', recordPayload)), 'err.builder_busy', 'one tool at a time')
    Frame()
    H.eq(T.closes, 1, 'the tablet closed into placement mode')
    local ghost = W.created[#W.created]
    H.eq(ghost.kind, 'ped', 'a ped ghost')
    H.eq(ghost.net, false, 'the ghost is local (not networked)')
    Frames(3)
    local ov = LastOverlay('placement')
    H.ok(ov ~= nil, 'placement overlay shown')
    H.eq(ov.key, 'spawns', 'overlay key')
    H.eq(ov.label, 'Hostile spawn points', 'overlay label')
    H.eq(ov.min, 2, 'overlay min')
    H.eq(ov.max, 3, 'overlay max')
    H.eq(ov.mode, 'ped', 'overlay mode')
    H.eq(ov.heading, 90, 'overlay heading starts at the player heading')
    H.ok(W.capsules > 0, 'the ped volume was probed')
    Frames(10)
    H.eq(LastOverlay('placement').valid, true, 'a valid spot')
    Frame({ KEY.E })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 1, 'one point placed')
    -- too close to the start
    W.aim = { x = 1030.0, y = -3108.4, z = 5.0 }
    Frames(12)
    ov = LastOverlay('placement')
    H.eq(ov.valid, false, 'a spawn point near the start is invalid')
    H.eq(ov.reason, CP.L('builder.place.reason.start', { min = 30 }), 'reason text translated')
    H.ok(tostring(ov.reason):find('30', 1, true) ~= nil, 'the reason names 30 m')
    Frame({ KEY.E })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 1, 'an invalid spot is not placed')
    -- in water
    W.aim = { x = 1050.0, y = -3090.0, z = 5.0 }
    W.water = true
    Frames(12)
    H.eq(LastOverlay('placement').reason, CP.L('builder.place.reason.water'), 'water is refused')
    W.water = false
    -- blocked by a wall
    W.blocked = true
    W.aim = { x = 1051.0, y = -3090.0, z = 5.0 }
    Frames(12)
    H.eq(LastOverlay('placement').reason, CP.L('builder.place.reason.blocked'), 'a wall is refused')
    W.blocked = false
    -- rotate and place a second point
    W.aim = { x = 1052.0, y = -3090.0, z = 5.0 }
    Frame({ KEY.WHEEL_UP })
    Frames(12)
    H.eq(LastOverlay('placement').heading, 100, 'scroll rotates by 10 degrees')
    H.eq(LastOverlay('placement').valid, true, 'the new spot is valid')
    Frame({ KEY.E })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 2, 'two points placed')
    Frame({ KEY.BACK })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 1, 'Backspace undoes the last point')
    Frame({ KEY.E })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 2, 'placed again')
    local pushesBefore = #T.pushes
    Frame({ KEY.ENTER })
    Frame()
    H.eq(B.active(), nil, 'Enter ends the tool')
    H.eq(#T.pushes, pushesBefore + 1, 'the result was pushed')
    local p = LastPush()
    H.eq(p.topic, 'builder', 'push topic builder')
    H.eq(p.data.event, 'clientResult', 'push event clientResult')
    H.eq(p.data.id, 'custom_dockside_raid', 'push mission id')
    local res = p.data.result
    H.eq(res.kind, 'placement', 'result kind')
    H.eq(res.cancelled, false, 'not cancelled')
    H.eq(res.location, 1, 'result location')
    H.eq(res.key, 'spawns', 'result key')
    H.eq(#res.points, 2, 'two points returned')
    H.eq(res.points[1].x, 1050.0, 'first point x')
    H.eq(res.points[1].z, 6.0, 'a ped is stored at standing height (ground + 1 m)')
    H.eq(res.points[1].w, 90.0, 'first point heading')
    H.eq(res.points[2].w, 100.0, 'second point heading after rotating')
    H.eq(res.seq, 1, 'first result seq')
    H.ok(Has(W.deleted, ghost.e), 'the ghost was deleted')
    H.eq(T.overlays[#T.overlays], false, 'the overlay was cleared')
    H.eq(W.zonesLive, 0, 'every zone removed')
    H.ok(W.zonesMade > 0, 'the start keep-out circle was drawn as a zone')
    for _, e in ipairs(W.coordsNoOffset) do H.ok(e ~= W.ped, 'only the ghost is moved') end
    H.eq(W.playerMoves, 0, 'the player is never moved')
    H.eq(#T.opens, 0, 'the tablet reopens after a moment')
    H.advance(400)
    H.eq(T.opens[1], 'admin', 'the tablet reopened on the UI the tool came from')
    local okR, pulled = Act('builderResult', {})
    H.eq(okR, true, 'builderResult')
    H.eq(pulled.seq, 1, 'the pending result')
    H.eq(select(2, Act('builderResult', {})), nil, 'a result is handed out once')
end

-- ============================================================================
--                  A START PLACEMENT: radius and single point
-- ============================================================================

do
    T.isOpen = true
    W.aim = { x = 1300.0, y = -3108.4, z = 5.0 }
    W.pos = { x = 1290.0, y = -3108.4, z = 5.9 }
    local ok = Act('builderPlace', {
        missionId = 'custom_dockside_raid',
        location = 2,
        key = 'start',
        kind = 'start',
        multiple = false,
        radius = 60,
        points = {},
        otherStarts = { DOCKS },
    })
    H.eq(ok, true, 'start placement starts')
    Frames(5)
    H.eq(LastOverlay('placement').radius, 60, 'overlay radius')
    Frame({ KEY.WHEEL_UP })
    Frames(10)
    H.eq(LastOverlay('placement').radius, 65, 'scroll grows the radius by 5 m')
    Frame({ KEY.E })
    Frames(3)
    W.aim = { x = 1310.0, y = -3108.4, z = 5.0 }
    Frames(3)
    Frame({ KEY.E }) -- a single point: placing again replaces it
    Frames(3)
    Frame({ KEY.ENTER })
    Frame()
    local res = LastPush().data.result
    H.eq(#res.points, 1, 'one start')
    H.eq(res.points[1].x, 1310.0, 'the last placement replaced the first')
    H.eq(res.points[1].w, nil, 'a start carries no heading')
    H.eq(res.points[1].z, 5.0, 'a start is stored on the ground')
    H.eq(res.radius, 65, 'the radius is returned')
    H.eq(res.seq, 2, 'seq increases')
    H.advance(400)
    H.eq(T.opens[#T.opens], 'supervisor', 'reopened on the default UI')
    Act('builderResult', {})
    -- a start near another location's start
    T.isOpen = true
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
    W.aim = { x = 1060.0, y = -3108.4, z = 5.0 }
    Act('builderPlace', {
        missionId = 'custom_dockside_raid',
        location = 2,
        key = 'start',
        kind = 'start',
        points = {},
        otherStarts = { DOCKS },
    })
    Frames(5)
    H.eq(LastOverlay('placement').reason, CP.L('builder.place.reason.gap', { min = 100 }), 'too close to another start')
    local okC, dc = Act('builderCancel', {})
    H.eq(okC and dc.cancelled, true, 'builderCancel stops the tool')
    Frame()
    H.eq(LastPush().data.result.cancelled, true, 'a cancelled result')
    H.eq(#LastPush().data.result.points, 0, 'a cancelled start placement keeps the existing points')
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--            X CANCELS, AIMED DELETE, THE HUD COUNTER AND KEEP-OUT
-- ============================================================================

do
    local given = {
        { x = 1050.0, y = -3108.4, z = 6.0, w = 0.0 },
        { x = 1060.0, y = -3108.4, z = 6.0, w = 0.0 },
        { x = 1070.0, y = -3108.4, z = 6.0, w = 0.0 },
    }
    local payload = {}
    for k, v in pairs(placePayload) do payload[k] = v end
    payload.points = given
    payload.max = 5
    W.groundZ = 5.0
    W.pos = { x = 1060.0, y = -3100.0, z = 5.9 }

    -- X: the result is cancelled and carries the given points, unchanged
    T.isOpen = true
    W.aim = { x = 1080.0, y = -3108.4, z = 5.0 }
    H.eq(Act('builderPlace', payload), true, 'placement with given points starts')
    Frames(12)
    local ov = LastOverlay('placement')
    H.eq(ov.keepOut, 30, 'the HUD names the start keep-out (30 m for an unarmed key)')
    H.eq(ov.armed, false, 'an unarmed key')
    Frame({ KEY.E })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 4, 'a fourth point placed')
    W.aim = { x = 1060.5, y = -3108.0, z = 5.0 }
    Frames(3)
    Frame({ KEY.DELETE })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 3, 'Delete removed the aimed point')
    Frame({ KEY.X })
    Frame()
    H.eq(B.active(), nil, 'X ends the tool')
    local res = LastPush().data.result
    H.eq(res.cancelled, true, 'X cancels')
    H.eq(#res.points, 3, 'the cancelled result keeps the given points')
    for i, p in ipairs(given) do H.eq(res.points[i].x, p.x, 'given point ' .. i .. ' unchanged') end
    H.advance(400)
    Act('builderResult', {})

    -- Delete while aiming at the second point removes that one, not the last
    T.isOpen = true
    W.aim = { x = 1059.0, y = -3108.9, z = 5.0 }
    Act('builderPlace', payload)
    Frames(12)
    H.eq(LastOverlay('placement').aimed, 2, 'the HUD knows the aimed point')
    Frame({ KEY.DELETE })
    Frames(3)
    -- Backspace aimed at a point removes it too
    W.aim = { x = 1050.4, y = -3108.4, z = 5.0 }
    Frames(3)
    Frame({ KEY.BACK })
    Frames(3)
    -- Delete aimed at nothing removes nothing
    W.aim = { x = 1080.0, y = -3108.4, z = 5.0 }
    Frames(3)
    Frame({ KEY.DELETE })
    Frames(10)
    H.eq(LastOverlay('placement').placed, 1, 'Delete aimed at nothing removes nothing')
    Frame({ KEY.ENTER })
    Frame()
    res = LastPush().data.result
    H.eq(res.cancelled, false, 'Enter keeps the edits')
    H.eq(#res.points, 1, 'one point left')
    H.eq(res.points[1].x, 1070.0, 'the aimed points were removed, the third is kept')
    H.advance(400)
    Act('builderResult', {})

    -- an armed key: the HUD keep-out is the start circle plus the margin
    T.isOpen = true
    payload.armed = true
    payload.startRadius = 25
    payload.points = {}
    W.aim = { x = 1085.0, y = -3108.4, z = 5.0 }
    Act('builderPlace', payload)
    Frames(12)
    ov = LastOverlay('placement')
    H.eq(ov.armed, true, 'an armed key')
    H.eq(ov.keepOut, 25 + (Config.Builder.spawnMargin or 40), 'armed keep-out = start radius + spawnMargin')
    Frame({ KEY.X })
    Frame()
    H.advance(400)
    Act('builderResult', {})
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
end

-- ============================================================================
--              A SPAWN BELOW THE START: the stored height counts
-- ============================================================================
-- The server checks the start distance on the stored point (a ped at ground + 1 m), so the tool does too.

do
    T.isOpen = true
    local porch = { x = 1017.52, y = -3108.44, z = 10.0 }
    local payload = {}
    for k, v in pairs(placePayload) do payload[k] = v end
    payload.start = porch
    W.groundZ = 7.0
    W.aim = { x = porch.x + 29.9, y = porch.y, z = 7.0 }
    Act('builderPlace', payload)
    Frames(12)
    local ov = LastOverlay('placement')
    H.eq(ov.valid, false, 'a ped 29.97 m from the start as stored is refused (30.05 m from the aimed street)')
    H.eq(ov.reason, CP.L('builder.place.reason.start', { min = 30 }), 'refused for the start distance')
    W.aim = { x = porch.x + 30.2, y = porch.y, z = 7.0 }
    Frames(12)
    H.eq(LastOverlay('placement').valid, true, '30.27 m from the start as stored is far enough')
    Frame({ KEY.E })
    Frames(3)
    Frame({ KEY.ENTER })
    Frame()
    local p = LastPush().data.result.points[1]
    H.eq(p.z, 8.0, 'the ped is stored at ground + 1 m')
    H.ok(math.sqrt((p.x - porch.x) ^ 2 + (p.y - porch.y) ^ 2 + (p.z - porch.z) ^ 2) >= 30.0,
        'the stored point passes the server\'s 3D start distance')
    H.advance(400)
    Act('builderResult', {})
    W.groundZ = 5.0
end

-- ============================================================================
--                            A ROUTE RECORDING RUN
-- ============================================================================

do
    T.isOpen = true
    W.veh = NewEnt('player_vehicle', 1000.0, -3000.0, 5.0, true)
    W.driver = false
    local vehEnt = W.ents[W.veh]
    local function Drive(x, y, keys)
        vehEnt.coords = { x = x, y = y, z = 5.0 }
        Frame(keys)
    end
    W.pathCalls, W.noPathCall = 0, 2 -- the second road-path check finds no path: segment 2 (checked as it is kept)
    local ok = Act('builderRecord', recordPayload)
    H.eq(ok, true, 'recording starts')
    Frames(20)
    H.eq(LastOverlay('recording').waiting, 'vehicle', 'waits for the player to drive')
    W.driver = true
    -- north 200 m in 5 m steps (a sample every 25 m); a stop at 100 m; two samples where the node is 12 m above but
    -- the car is on a road (IsPointOnRoad answers true with the manifest's OAL, the integer 1 without it)
    for i = 0, 40 do
        local y = -3000.0 + i * 5.0
        if i == 10 then W.nodeDz, W.onRoad = 12.0, true end
        if i == 15 then W.nodeDz, W.onRoad = 12.0, 1 end
        if i == 11 or i == 16 then W.nodeDz, W.onRoad = 0.0, false end
        Drive(1000.0, y, i == 20 and { KEY.E } or nil)
    end
    Frames(10)
    local ov = LastOverlay('recording')
    H.eq(ov.stops, 1, 'E added a stop point')
    H.eq(ov.stopsEnabled, true, 'stops enabled for an escort')
    H.eq(ov.maxStops, 5, 'max stops from Config.Blocks.escort.stops')
    H.eq(ov.rejected, 0, 'a car on a road surface is not rejected')
    H.eq(ov.length, 200, 'length so far')
    H.eq(ov.undoMetres, 100, 'undo metres shown')
    -- east 200 m; two samples off road
    for i = 1, 40 do
        local x = 1000.0 + i * 5.0
        W.nodeDx = (x >= 1050 and x < 1100) and 50.0 or 0.0
        Drive(x, -2800.0)
    end
    W.nodeDx = 0.0
    Frames(10)
    ov = LastOverlay('recording')
    H.eq(ov.rejected, 2, 'two off-road samples rejected')
    -- undo 100 m: wait until the driver is back at the end of the recording
    Frame({ KEY.BACK })
    Frames(10)
    ov = LastOverlay('recording')
    H.eq(ov.waiting, 'return', 'after an undo the recording waits for the driver to come back')
    H.eq(ov.distance, 100, 'distance back to the end')
    H.ok(tostring(ov.message):find('100', 1, true) ~= nil, 'the undo message names the metres')
    Drive(1110.0, -2800.0)
    Frames(12)
    H.eq(LastOverlay('recording').waiting, false, 'recording again near the end')
    for i = 1, 38 do Drive(1110.0 + i * 5.0, -2800.0) end
    -- pause: no samples while paused
    Frame({ KEY.P })
    Frames(10)
    H.eq(LastOverlay('recording').paused, true, 'P pauses')
    local samples = LastOverlay('recording').samples
    for i = 1, 10 do Drive(1300.0 + i * 5.0, -2800.0) end
    Frames(10)
    H.eq(LastOverlay('recording').samples, samples, 'no samples while paused')
    Drive(1300.0, -2800.0, { KEY.P })
    Frames(10)
    H.eq(LastOverlay('recording').paused, false, 'P resumes')
    Frame({ KEY.X })
    for _ = 1, 20 do Frame() end
    local p = LastPush()
    H.eq(p.data.id, 'custom_quarry_escort', 'recording result pushed')
    local res = p.data.result
    H.eq(res.kind, 'recording', 'result kind recording')
    H.eq(res.cancelled, false, 'not cancelled')
    local pts = res.route.points
    H.eq(pts[1].x, 1000.0, 'the route starts where recording started (x)')
    H.eq(pts[1].y, -3000.0, 'the route starts where recording started (y)')
    local corner = false
    for _, q in ipairs(pts) do if q.x == 1000.0 and q.y == -2800.0 then corner = true end end
    H.ok(corner, 'the corner is a waypoint')
    for i = 2, #pts do
        H.ok(math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2) <= 150.0 + 1e-6,
            'waypoints at most 150 m apart (' .. i .. ')')
    end
    local stop = res.route.stops[1]
    H.ok(stop ~= nil, 'the stop point is in the route')
    H.eq(pts[stop.at].y, -2900.0, 'the stop is where E was pressed')
    H.eq(stop.wait, 20, 'stop wait = Config.Blocks.escort.stopWait default')
    H.ok(stop.at > 1 and stop.at < #pts, 'the stop is on an interior waypoint')
    H.eq(res.rejected, 2, 'rejected samples counted')
    H.eq(#res.rejectedSamples, 2, 'rejected positions returned')
    H.eq(res.rejectedSamples[1].x, 1050.0, 'first rejected sample')
    H.eq(res.length, math.floor(B.routeLength(pts) + 0.5), 'length = sum of the waypoint distances')
    H.ok(res.length >= 495 and res.length <= 520,
        'about 500 m recorded: 200 north, 300 east after the undo (' .. res.length .. ')')
    H.eq(#res.unreachable, 1, 'one waypoint without a road path to the next')
    H.eq(res.unreachable[1], 2, 'the second waypoint is unreachable')
    H.eq(res.droppedStops, 0, 'no stop dropped')
    H.eq(res.route.loop, nil, 'not a loop')
    local sawChecking = false
    for _, o in ipairs(T.overlays) do
        if o and o.kind == 'recording' and o.waiting == 'checking' then sawChecking = true end
    end
    H.ok(sawChecking, 'the overlay shows the road-path check')
    H.advance(400)
    H.eq(T.opens[#T.opens], 'supervisor', 'reopened after recording')
    Act('builderResult', {})
    W.pathCalls, W.noPathCall = 0, nil
end

-- ============================================================================
--            A RECORDING WITH FEWER THAN TWO WAYPOINTS IS CANCELLED
-- ============================================================================

do
    T.isOpen = true
    Act('builderRecord', { missionId = 'custom_quarry_escort', location = 1, key = 'raceLoop', loop = true })
    Frames(3)
    Frame({ KEY.X })
    Frames(3)
    local res = LastPush().data.result
    H.eq(res.cancelled, true, 'nothing recorded: cancelled')
    H.eq(res.route.loop, true, 'loop flag kept')
    H.eq(#res.unreachable, 0, 'no path checks for an empty route')
    H.ok(T.toasts[#T.toasts].text == CP.L('builder.rec.nothing'), 'a warning toast')
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--           A LONG ROUTE: road paths are checked next to the player
-- ============================================================================
-- The game streams path nodes around the player only: a segment far from where X is pressed cannot be checked
-- there, so each one is checked while it is driven.

do
    T.isOpen = true
    W.veh, W.driver = NewEnt('player_vehicle', 2000.0, -3000.0, 5.0, true), true
    local vehEnt = W.ents[W.veh]
    W.pathCalls, W.noPathCall, W.pathRange = 0, nil, 400.0
    Act('builderRecord', { missionId = 'custom_quarry_escort', location = 1, key = 'route', label = 'Escort route' })
    Frames(2)
    for i = 0, 100 do -- 2.5 km north in 25 m steps
        vehEnt.coords = { x = 2000.0, y = -3000.0 + i * 25.0, z = 5.0 }
        Frame()
    end
    Frame({ KEY.X })
    Frames(20)
    local res = LastPush().data.result
    H.eq(res.kind, 'recording', 'the long recording ended')
    H.ok(res.length >= 2400, 'about 2.5 km recorded (' .. res.length .. ')')
    H.eq(#res.unreachable, 0, 'no waypoint is reported unreachable because it is far from where X was pressed')
    W.pathRange = nil
    H.advance(400)
    Act('builderResult', {})
    -- an undo drops the checks of the segments it removes: waypoints every 150 m, the third segment fails once
    T.isOpen = true
    local function North(y) vehEnt.coords = { x = 2000.0, y = y, z = 5.0 }; Frame() end
    W.pathCalls = 0
    vehEnt.coords = { x = 2000.0, y = -3000.0, z = 5.0 }
    Act('builderRecord', { missionId = 'custom_quarry_escort', location = 1, key = 'route' })
    Frames(2)
    -- to 350 m: segments 1 and 2 checked
    for i = 1, 14 do North(-3000.0 + i * 25.0) end
    H.eq(W.pathCalls, 2, 'two segments checked while driving')
    W.noPathCall = 3
    -- to 475 m: segment 3 checked, no path
    for i = 15, 19 do North(-3000.0 + i * 25.0) end
    Frame({ KEY.BACK })
    Frames(3)
    -- back at 375 m, on to 625 m: segment 3 checked again
    North(-2625.0)
    for i = 16, 25 do North(-3000.0 + i * 25.0) end
    Frame({ KEY.X })
    Frames(20)
    res = LastPush().data.result
    H.ok(W.pathCalls >= 4, 'the segment was checked again after the undo')
    H.eq(#res.unreachable, 0, 'the undone segment\'s failed check is gone')
    W.noPathCall = nil
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--                     BACK IN A VEHICLE AWAY FROM THE END
-- ============================================================================
-- The recording waits for the driver to return: a resume on foot, or another car, must not add a straight
-- undriven jump to the route.

do
    T.isOpen = true
    local function GetIn(x, y) W.veh, W.driver = NewEnt('player_vehicle', x, y, 5.0, true), true end
    local function GetOut(x, y)
        W.veh, W.driver = 0, false
        W.pos = { x = x, y = y, z = 5.9 }
    end
    local function DriveTo(x, y, keys)
        W.ents[W.veh].coords = { x = x, y = y, z = 5.0 }
        Frame(keys)
    end
    GetIn(3000.0, -3000.0)
    Act('builderRecord', { missionId = 'custom_quarry_escort', location = 1, key = 'route' })
    Frames(2)
    -- 500 m north: the end is at y = -2500
    for i = 0, 20 do DriveTo(3000.0, -3000.0 + i * 25.0) end
    Frames(10)
    local samples = LastOverlay('recording').samples
    -- pause, get out, walk 300 m to another car and resume on foot
    Frame({ KEY.P })
    GetOut(3000.0, -2500.0)
    Frames(10)
    W.pos = { x = 3300.0, y = -2500.0, z = 5.9 }
    Frame({ KEY.P })
    Frames(10)
    H.eq(LastOverlay('recording').paused, false, 'P resumes on foot')
    GetIn(3300.0, -2500.0)
    for i = 1, 4 do DriveTo(3300.0, -2500.0 + i * 25.0) end
    Frames(10)
    local ov = LastOverlay('recording')
    H.eq(ov.waiting, 'return', 'a resume on foot away from the end waits for the driver to come back')
    H.eq(ov.samples, samples, 'nothing is sampled away from the end')
    DriveTo(3000.0, -2490.0)
    Frames(10)
    H.eq(LastOverlay('recording').waiting, false, 'recording again at the end')
    -- the end is at y = -2290
    for i = 1, 8 do DriveTo(3000.0, -2490.0 + i * 25.0) end
    Frames(10)
    samples = LastOverlay('recording').samples
    -- no pause: get out, and drive off in another car 300 m away
    GetOut(3000.0, -2290.0)
    Frames(10)
    H.eq(LastOverlay('recording').waiting, 'vehicle', 'out of the driver seat')
    GetIn(3300.0, -2290.0)
    for i = 1, 4 do DriveTo(3300.0, -2290.0 + i * 25.0) end
    Frames(10)
    ov = LastOverlay('recording')
    H.eq(ov.waiting, 'return', 'another car away from the end waits for the driver to come back')
    H.eq(ov.samples, samples, 'nothing is sampled from the other car')
    DriveTo(3000.0, -2285.0)
    Frames(10)
    H.eq(LastOverlay('recording').waiting, false, 'driven back to the end: recording again')
    for i = 1, 4 do DriveTo(3000.0, -2285.0 + i * 25.0) end
    Frame({ KEY.X })
    Frames(20)
    local pts = LastPush().data.result.route.points
    local off = 0
    for _, q in ipairs(pts) do if q.x ~= 3000.0 then off = off + 1 end end
    H.ok(#pts >= 2, 'a route was recorded')
    H.eq(off, 0, 'every waypoint is on the driven road (no jump to the other cars)')
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--                                 A TEST DRIVE
-- ============================================================================

do
    T.isOpen = true
    W.veh, W.driver = 0, false
    W.pos = { x = 0.0, y = 0.0, z = 0.0 }         -- far from the route start
    W.stuckTargets = { [1100] = true }            -- waypoint 3 is never reached
    W.tasks, W.tempActions = {}, {}
    local offBefore = W.waypointOff
    local ok = Act('builderTestDrive', drivePayload)
    H.eq(ok, true, 'test drive starts')
    Frames(5)
    H.eq(W.waypoints[#W.waypoints].x, 1000.0, 'a GPS waypoint leads to the route start')
    H.eq(LastOverlay('testdrive').waiting, 'approach', 'overlay: approach')
    W.pos = { x = 1000.0, y = -3002.0, z = 5.0 }  -- at the start: the spawn point must be clear
    Frames(12)
    H.eq(LastOverlay('testdrive').waiting, 'clear', 'overlay: clear the spawn point')
    W.pos = { x = 1020.0, y = -3010.0, z = 5.0 }
    Frames(12)
    local veh, driver
    for _, c in ipairs(W.created) do
        if c.kind == 'vehicle' then veh = c end
        if c.kind == 'driver' then driver = c end
    end
    H.ok(veh ~= nil, 'a vehicle was spawned')
    H.eq(veh.net, false, 'the test vehicle is local')
    H.eq(driver.net, false, 'the driver is local')
    H.eq(W.tasks[1].x, 1000.0, 'first task: waypoint 2 (x)')
    H.eq(W.tasks[1].y, -2900.0, 'first task: waypoint 2 (y)')
    H.near(W.tasks[1].speed, 60 / 3.6, 1e-6, 'speed in m/s')
    H.eq(W.tasks[1].style, 786492, 'reckless drives lane-keeping')
    H.eq(W.tempActions[1].ms, 5000, 'waits out the escort stop at waypoint 2')
    H.eq(LastOverlay('testdrive').stopLeft ~= false, true, 'overlay: stop countdown')
    H.advance(6000, 100)
    H.eq(W.tasks[#W.tasks].x, 1100.0, 'driving to waypoint 3')
    H.eq(LastOverlay('testdrive').waypoint, 3, 'overlay waypoint 3')
    H.ok(type(LastOverlay('testdrive').timeLeft) == 'number', 'overlay: time left')
    H.advance(31000, 100)
    H.ok(Has(LastOverlay('testdrive').failed, 3), 'waypoint 3 marked failed after testDriveTimeout')
    H.advance(2000, 100)
    local p = LastPush()
    local res = p.data.result
    H.eq(res.kind, 'testdrive', 'result kind testdrive')
    H.eq(res.completed, true, 'the drive completed')
    H.eq(res.cancelled, false, 'not cancelled')
    H.eq(#res.failed, 1, 'one failed waypoint')
    H.eq(res.failed[1], 3, 'waypoint 3 failed')
    H.ok(Has(W.deleted, veh.e) and Has(W.deleted, driver.e), 'vehicle and driver deleted')
    H.ok(W.removedBlips >= 1, 'blip removed')
    H.ok(W.waypointOff > offBefore, 'the GPS waypoint was cleared')
    H.eq(W.playerMoves, 0, 'the player is never moved')
    H.advance(400)
    Act('builderResult', {})
    W.stuckTargets = {}
    -- X stops a drive
    T.isOpen = true
    Act('builderTestDrive', drivePayload)
    Frames(5)
    Frame({ KEY.X })
    Frames(3)
    res = LastPush().data.result
    H.eq(res.cancelled, true, 'X stops the drive')
    H.eq(res.completed, false, 'not completed')
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--                                 DRAW PACING
-- ============================================================================
-- The recorder's version, the test drive's per-frame route.

-- Recorder.ver grows on every change to the waypoints or stops (the recording's draw cache is keyed on it)
do
    local rec = B.newRecorder({ turnAngle = 30, maxGap = 150 })
    H.eq(rec.ver, 0, 'a new recorder is version 0')
    local v = rec.ver
    for i = 0, 8 do
        rec:add({ x = 0, y = i * 25.0, z = 10 })
        H.ok(rec.ver > v, 'a kept sample changes the version (' .. i .. ')')
        v = rec.ver
    end
    rec:add({ x = 0.2, y = 200.2, z = 10 })
    H.eq(rec.ver, v, 'a duplicate sample leaves the version alone')
    H.ok(rec:addStop(5, 5), 'a stop is added')
    H.ok(rec.ver > v, 'a stop changes the version')
    v = rec.ver
    H.eq(rec:addStop(5, 5), false, 'a second stop on the same waypoint is refused')
    H.eq(rec.ver, v, 'a refused stop leaves the version alone')
    rec:undo(60)
    H.ok(rec.ver > v, 'an undo that removes samples changes the version')
    v = rec.ver
    rec:undo(0)
    H.eq(rec.ver, v, 'an undo that removes nothing leaves the version alone')
    rec:finish()
    H.ok(rec.ver > v, 'finish changes the version')
end

-- the markers and lines drawn this frame, as plain lists
local drawn = nil
local realMarker, realLine = _G.DrawMarker, _G.DrawLine
local function RecordDraws()
    _G.DrawMarker = function(kind, x, y, z, _, _, _, _, _, _, sx, sy, sz, r, g, b, a)
        if drawn then drawn[#drawn + 1] = { 'M', kind, x, y, z, sx, sy, sz, r, g, b, a } end
    end
    _G.DrawLine = function(...)
        if drawn then drawn[#drawn + 1] = { 'L', ... } end
    end
end
local function StopDraws()
    _G.DrawMarker, _G.DrawLine = realMarker, realLine
    drawn = nil
end
local function Flat(list)
    local out = {}
    for _, c in ipairs(list) do
        local parts = {}
        for k, v in ipairs(c) do parts[k] = type(v) == 'number' and ('%.3f'):format(v) or tostring(v) end
        out[#out + 1] = table.concat(parts, ',')
    end
    return table.concat(out, ';')
end

-- A recording draws exactly rec:waypoints() in the frame of every change (a new sample, an undo, the last frame)
do
    H.eq(B.active(), nil, 'no tool before the recording draw check')
    T.isOpen = true
    W.veh = NewEnt('player_vehicle', 3000.0, 500.0, 5.0, true)
    W.driver = true
    W.nodeDx, W.nodeDz, W.onRoad = 0.0, 0.0, false
    local vehEnt = W.ents[W.veh]
    RecordDraws()
    local function RouteDots()
        local out = {}
        for _, c in ipairs(drawn) do
            if c[1] == 'M' and c[2] == 28 and c[6] == 0.6 then out[#out + 1] = { x = c[3], y = c[4] } end
        end
        return out
    end
    local function DriveTo(y, keys)
        vehEnt.coords = { x = 3000.0, y = y, z = 5.0 }
        drawn = {}
        Frame(keys)
        return RouteDots()
    end
    H.eq(Act('builderRecord', recordPayload), true, 'the recording for the draw check starts')
    Frames(3)
    local mismatch = 0
    local before = {}
    for i = 0, 24 do
        local y = 500.0 + i * 5.0
        local dots = DriveTo(y)
        -- a sample is taken every 25 m: in that frame the last dot is it
        if i % 5 == 0 and (#dots == 0 or dots[#dots].y ~= y) then mismatch = mismatch + 1 end
        before = dots
    end
    H.eq(mismatch, 0, 'every new sample is drawn in the frame it is taken')
    DriveTo(620.0, { KEY.BACK })
    local dots = DriveTo(620.0)
    H.ok(#dots < #before, 'the frame after the undo draws the shorter recording')
    local prefix = true
    for k, d in ipairs(dots) do
        if d.x ~= before[k].x or d.y ~= before[k].y then prefix = false end
    end
    H.ok(prefix, 'what is left after the undo is the start of what was drawn')
    for i = 1, 8 do before = DriveTo(500.0 + (#dots - 1) * 25.0 + i * 5.0) end
    Frame({ KEY.X })
    StopDraws()
    for _ = 1, 20 do Frame() end
    local pts = LastPush().data.result.route.points
    local same = #pts == #before
    for k, q in ipairs(pts) do
        if not before[k] or before[k].x ~= q.x or before[k].y ~= q.y then same = false end
    end
    H.ok(same, 'the last frame drew exactly the recorded route')
    H.advance(400)
    Act('builderResult', {})
    W.veh, W.driver = 0, false
end

-- A test drive of a 500-point route: the same markers and lines as the drawing before this pacing, frame by frame,
-- and no U.dist call in a frame (it was one per route point)
do
    H.eq(B.active(), nil, 'no tool before the 500-point test drive')
    T.isOpen = true
    W.veh, W.driver = 0, false
    W.tasks, W.tempActions = {}, {}
    local N = 500
    local route = {}
    for i = 1, N do route[i] = { x = 2000 + (i - 1) * 30, y = 0, z = 5 + (i % 7) } end
    local stuck = { [100] = true, [300] = true }
    W.stuckTargets = {}
    for i in pairs(stuck) do W.stuckTargets[route[i].x] = true end
    local stops = {}
    for _, at in ipairs({ 50, 150, 250, 350, 450 }) do stops[#stops + 1] = { at = at, wait = 1 } end
    local payload = {}
    for k, v in pairs(drivePayload) do payload[k] = v end
    payload.route = { points = route, stops = stops }
    -- what drives the drawing: the latest task's waypoint, and whether the car waits at a stop since
    local phase = { target = nil, stop = false, done = false }
    local realTask, realTemp = _G.TaskVehicleDriveToCoordLongrange, _G.TaskVehicleTempAction
    _G.TaskVehicleDriveToCoordLongrange = function(driver, veh, x, ...)
        phase.target, phase.stop = math.floor((x - 2000) / 30 + 0.5) + 1, false
        return realTask(driver, veh, x, ...)
    end
    _G.TaskVehicleTempAction = function(driver, veh, action, ms)
        if ms == 3000 then phase.done = true else phase.stop = true end
        return realTemp(driver, veh, action, ms)
    end
    local dists = 0
    local realDist = CP.U.dist
    CP.U.dist = function(a, b)
        dists = dists + 1
        return realDist(a, b)
    end
    local FAILED, DONE, ROUTE = { 240, 70, 77 }, { 52, 196, 124 }, { 78, 161, 255 }
    -- the drawing as it was before this pacing (U.dist, a scan of the failed list, two tables per line)
    local function OldDraw(pos, current)
        local out = {}
        for i = 1, N do
            local p = route[i]
            if realDist(pos, p) < 160.0 * 2 then
                local bad = stuck[i] and i < phase.target
                local c = bad and FAILED or (i < current and DONE or ROUTE)
                out[#out + 1] = { 'M', 28, p.x, p.y, p.z + 0.5, 0.7, 0.7, 0.7, c[1], c[2], c[3], 180 }
                if i > 1 then
                    local q = route[i - 1]
                    out[#out + 1] = { 'L', q.x, q.y, q.z + 0.5, p.x, p.y, p.z + 0.5, c[1], c[2], c[3], 200 }
                end
            end
        end
        return out
    end
    RecordDraws()
    W.pos = { x = 2003.3, y = 20.7, z = 5.0 }
    H.eq(Act('builderTestDrive', payload), true, 'the 500-point test drive starts')
    local frames, same, maxDists, drawnFrames = 0, 0, 0, 0
    local startPushes = #T.pushes
    -- 30 m apart: farther than the arrive radius, so a stuck car does not reach the next waypoint by accident
    for _ = 1, 20000 do
        local started = phase.target ~= nil
        -- the player follows the car, a little aside
        local veh
        for _, c in ipairs(W.created) do if c.kind == 'vehicle' then veh = c.e end end
        if veh and W.ents[veh] then
            local cp = W.ents[veh].coords
            W.pos = { x = cp.x + 3.3, y = cp.y + 20.7, z = 5.0 }
        end
        drawn, dists = {}, 0
        local pos = { x = W.pos.x, y = W.pos.y, z = W.pos.z }
        Frame()
        -- (the frame the car spawns also runs the last check that the spawn point is clear)
        if started and not phase.done then
            frames = frames + 1
            if #drawn > 0 then drawnFrames = drawnFrames + 1 end
            local want = OldDraw(pos, phase.stop and phase.target + 1 or phase.target)
            if Flat(drawn) == Flat(want) then same = same + 1 end
            if dists > maxDists then maxDists = dists end
        end
        if #T.pushes > startPushes and LastPush().data.result.kind == 'testdrive' then break end
    end
    StopDraws()
    CP.U.dist = realDist
    _G.TaskVehicleDriveToCoordLongrange, _G.TaskVehicleTempAction = realTask, realTemp
    W.stuckTargets = {}
    local res = LastPush().data.result
    H.eq(res.kind, 'testdrive', 'the 500-point test drive ends')
    H.eq(table.concat(res.failed, ','), '100,300', 'the two unreachable waypoints failed')
    H.ok(drawnFrames > 1000, 'the route was drawn in many frames (' .. drawnFrames .. ')')
    H.eq(same, frames, 'every frame draws the same markers and lines, in the same colours, as before')
    H.eq(maxDists, 0, 'no U.dist call in a drive frame')
    H.advance(400)
    Act('builderResult', {})
end

-- ============================================================================
--                                CRIMSON-ARENA
-- ============================================================================
-- A running tool stops without reopening the tablet.

do
    T.isOpen = true
    W.aim = { x = 1050.0, y = -3108.4, z = 5.0 }
    Act('builderPlace', placePayload)
    Frames(3)
    local opens = #T.opens
    bagHandlers[1].fn('player:7', 'crimsonArena', { active = true, source = 'crimson-arena' })
    H.eq(B.active(), 'placement', 'the bag handler only queues work')
    Frames(3)
    H.eq(B.active(), nil, 'the arena value stopped the tool')
    H.eq(LastPush().data.result.cancelled, true, 'cancelled result')
    H.advance(500)
    H.eq(#T.opens, opens, 'the tablet does not reopen for the arena')
    Act('builderResult', {})
    -- the own crimsonArena value (source crimson-police) does not stop a tool
    Act('builderPlace', placePayload)
    Frames(2)
    bagHandlers[1].fn('player:7', 'crimsonArena', { active = true, source = 'crimson-police' })
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-police' }
    Frames(20)
    H.eq(B.active(), 'placement', 'Crimson-Police\'s own value does not stop the tool')
    -- the value arriving directly (no bag event) is caught by the tool's own check
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
    Frames(20)
    H.eq(B.active(), nil, 'the tool checks the arena value itself')
    LocalPlayer.state.crimsonArena = nil
    H.advance(500)
    H.eq(#T.opens, opens, 'still no reopen')
    Act('builderResult', {})
end

-- ============================================================================
--                      A MISSION RUN STOPS A RUNNING TOOL
-- ============================================================================
-- A unit member is put on the run the leader drew: the tool's controls and HUD would fight the run's.

do
    local function Stops(name, payload)
        T.isOpen = true
        H.eq((Act(name, payload)), true, name .. ' starts')
        Frames(3)
        local opens = #T.opens
        currentRun = { runId = 'r2' }
        Frames(20)
        H.eq(B.active(), nil, 'a mission run stops the tool (' .. name .. ')')
        H.eq(LastPush().data.result.cancelled, true, 'a cancelled result (' .. name .. ')')
        H.eq(T.toasts[#T.toasts].text, CP.L('builder.tool_stopped_run'), 'the player is told why (' .. name .. ')')
        H.advance(500)
        H.eq(#T.opens, opens, 'the tablet does not reopen over the run (' .. name .. ')')
        currentRun = nil
        Act('builderResult', {})
    end
    W.aim = { x = 1050.0, y = -3108.4, z = 5.0 }
    Stops('builderPlace', placePayload)
    W.veh, W.driver = NewEnt('player_vehicle', 1000.0, -3000.0, 5.0, true), true
    Stops('builderRecord', recordPayload)
    W.veh, W.driver = 0, false
    W.pos = { x = 0.0, y = 0.0, z = 0.0 }
    Stops('builderTestDrive', drivePayload)
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
end

-- ============================================================================
--               BUILDER EVENTS, DEATH, UNLOAD AND RESOURCE STOP
-- ============================================================================

do
    T.isOpen = true
    Act('builderPlace', placePayload)
    Frames(2)
    local pushAt = #T.pushes
    H.fire(CP.e('client:builder'), nil, { event = 'lockBroken', id = 'another_mission', by = 'Ada Admin' })
    local fwd = T.pushes[pushAt + 1]
    H.ok(
        fwd and fwd.topic == 'builder' and fwd.data.event == 'lockBroken' and fwd.data.id == 'another_mission'
            and fwd.data.by == 'Ada Admin',
        'a lock break is forwarded to the open builder screen (push builder lockBroken with who did it)'
    )
    Frames(2)
    H.eq(B.active(), 'placement', 'an event for another mission changes nothing')
    H.fire(CP.e('client:builder'), nil, { event = 'lockBroken', id = 'custom_dockside_raid' })
    Frames(2)
    H.eq(B.active(), nil, 'a broken lock stops the tool of that mission')
    H.eq(LastPush().data.result.cancelled, true, 'cancelled by the broken lock')
    local opens = #T.opens
    H.advance(400)
    H.eq(#T.opens, opens + 1, 'reopens after a broken lock (the editor shows the banner)')
    -- a pending result of a deleted mission is dropped
    H.fire(CP.e('client:builder'), nil, { event = 'deleted', id = 'custom_dockside_raid' })
    H.eq(select(2, Act('builderResult', {})), nil, 'deleted: the pending result is dropped')
    local pushAt2 = #T.pushes
    H.fire(CP.e('client:builder'), nil, { event = 'nonsense', id = 'x' })
    H.fire(CP.e('client:builder'), nil, 'bad')
    H.eq(#T.pushes, pushAt2, 'unknown or malformed builder events are not forwarded')
    -- death stops a tool, no reopen
    T.isOpen = false
    Act('builderPlace', placePayload)
    Frames(2)
    W.dead = true
    Frames(20)
    H.eq(B.active(), nil, 'death stops the tool')
    W.dead = false
    opens = #T.opens
    H.advance(400)
    H.eq(#T.opens, opens, 'no reopen after death')
    Act('builderResult', {})
    -- unload: cancel, no reopen, pending result cleared
    Act('builderPlace', placePayload)
    Frames(2)
    unloadFns[1]()
    Frames(2)
    H.eq(B.active(), nil, 'unload stops the tool')
    H.advance(400)
    H.eq(#T.opens, opens, 'no reopen after unload')
    unloadFns[1]()
    H.eq(select(2, Act('builderResult', {})), nil, 'unload clears the pending result')
    -- resource stop: entities and overlay cleaned up at once
    Act('builderPlace', placePayload)
    Frames(3)
    local ghost = W.created[#W.created].e
    local live = W.zonesLive
    H.ok(live > 0, 'zones live while placing')
    TriggerEvent('onResourceStop', 'another-resource')
    H.ok(W.ents[ghost] ~= nil, 'another resource stopping changes nothing')
    TriggerEvent('onResourceStop', CP.resource)
    H.eq(W.ents[ghost], nil, 'the ghost is deleted on resource stop')
    H.eq(W.zonesLive, 0, 'zones removed on resource stop')
    H.eq(T.overlays[#T.overlays], false, 'overlay cleared on resource stop')
end

-- ============================================================================
--                                THE NUI STORE
-- ============================================================================
-- web/src/builder/store.ts and applyResult.ts, bundled with esbuild and run in node: a tool result is applied with
-- its point spec. The clientResult push must not drop the running tool: its PointSpec says how the result is written
-- (flee paths are a list of lists, a recorded checkpoint route is thinned), and the workspace opens the editor of a
-- pending result from it.

do
    local root = H.root
    if root:sub(1, 1) ~= '/' then
        local pwd = io.popen('pwd')
        root = pwd:read('l') .. '/' .. root
        pwd:close()
    end
    local esbuild = root .. 'web/node_modules/.bin/esbuild'
    local fh = io.open(esbuild, 'r')
    local probe = io.popen('command -v node')
    local node = probe:read('a') ~= ''
    probe:close()
    if not (fh and node) then
        print('SKIP tests/builder_client_spec.lua: the NUI store check needs node and web/node_modules (npm ci)')
    else
        fh:close()
        local js = [[
const listeners = [];
globalThis.window = { addEventListener: (type, fn) => { if (type === 'message') listeners.push(fn); } };
const S = require('WEB_DIR/store');
const A = require('WEB_DIR/applyResult');
const out = {};
const push = result => listeners.forEach(fn =>
    fn({ data: { type: 'push', topic: 'builder', data: { event: 'clientResult', id: result.missionId, result } } }));
const tool = (kind, spec) =>
    S.setTool({ kind, missionId: 'm1', location: 1, key: spec.key, spec, scope: 'sup', startedAt: 0 });
// useDraftEditor.applyPending: the queued results of the mission, each with the spec of the tool that made it
const applyPending = def => {
    const list = S.takeResults('m1');
    const t = S.currentTool();
    for (const r of list) {
        const spec = t && t.missionId === r.missionId && t.key === r.key ? t.spec : null;
        const applied = A.applyResult(def, r, spec, null);
        if (applied.def) def = applied.def;
        out.meta = applied.meta;
        out.message = applied.messageKey;
    }
    S.setTool(null);
    return def;
};
const pt = i => ({ x: 100 + i, y: 200 + i, z: 30 });
const flee = { key: 'routes', field: 'routes', labelKey: 'builder.points.flee_paths', kind: 'marker', heading: false,
    multiple: true, lists: true, min: 2, max: 12, spawn: false, objective: 1 };
const checkpoints = { key: 'checkpoints', field: 'checkpoints', labelKey: 'builder.points.checkpoints', kind: 'route',
    heading: false, multiple: true, min: 2, max: 20, spawn: false, objective: 1, thinTo: 20, spacing: 300 };
let def = { locations: [{ label: 'L1', start: { coords: pt(0), radius: 60 } }], objectives: [] };
const placed = (seq, n) => ({ kind: 'placement', missionId: 'm1', location: 1, key: 'routes', cancelled: false, seq,
    points: Array.from({ length: n }, (_, i) => pt(seq * 10 + i)) });
tool('placement', flee);
push(placed(1, 3));
const kept = S.currentTool();
out.toolKept = !!kept && kept.spec === flee;
out.autoOpen = !!kept && S.hasResults(kept.missionId);
def = applyPending(def);
tool('placement', flee);
push(placed(2, 2));
def = applyPending(def);
out.paths = def.locations[0].routes.map(p => p.length);
out.toolAfter = S.currentTool() === null;
tool('recording', checkpoints);
push({ kind: 'recording', missionId: 'm1', location: 1, key: 'checkpoints', cancelled: false, seq: 3, length: 4000,
    rejected: 0, rejectedSamples: [], unreachable: [],
    route: { points: Array.from({ length: 45 }, (_, i) => pt(i * 3)), stops: [] } });
def = applyPending(def);
out.checkpoints = def.locations[0].checkpoints.length;
out.plain = Array.isArray(def.locations[0].checkpoints);
out.thinned = out.meta.thinned;
out.recMessage = out.message;
// a 0.44 km beat driven around a block (waypoints 25 m apart): checkpoints about 300 m apart, not a road route
const beat = Array.from({ length: 18 }, (_, i) => ({ x: 100 + i * 25, y: 200, z: 30 }));
tool('recording', checkpoints);
push({ kind: 'recording', missionId: 'm1', location: 1, key: 'checkpoints', cancelled: false, seq: 4, length: 440,
    rejected: 0, rejectedSamples: [], unreachable: [], route: { points: beat, stops: [], loop: true } });
def = applyPending(def);
out.beat = def.locations[0].checkpoints.map(p => p.x);
// a long patrol (45 waypoints 100 m apart) with a 50 m spacing keeps every waypoint, then at most 20
tool('recording', { ...checkpoints, spacing: 50 });
push({ kind: 'recording', missionId: 'm1', location: 1, key: 'checkpoints', cancelled: false, seq: 5, length: 4400,
    rejected: 0, rejectedSamples: [], unreachable: [],
    route: { points: Array.from({ length: 45 }, (_, i) => ({ x: i * 100, y: 0, z: 30 })), stops: [] } });
def = applyPending(def);
out.long = def.locations[0].checkpoints.length;
console.log(JSON.stringify(out));
]]
        js = js:gsub('WEB_DIR', function() return root .. 'web/src/builder' end)
        local tmp = os.tmpname()
        local entry, bundle = tmp .. '.js', tmp .. '.cjs'
        local f = assert(io.open(entry, 'w'))
        f:write(js)
        f:close()
        local flags = '--bundle --platform=node --format=cjs --log-level=error'
        local shell = '\'%s\' \'%s\' %s --outfile=\'%s\' 2>&1 && node \'%s\' 2>&1'
        local cmd = shell:format(esbuild, entry, flags, bundle, bundle)
        local p = io.popen(cmd)
        local text = p:read('a')
        p:close()
        os.remove(tmp)
        os.remove(entry)
        os.remove(bundle)
        local ok, got = pcall(json.decode, text:match('{.*}') or '')
        H.ok(ok and type(got) == 'table', 'store.ts and applyResult.ts ran in node: ' .. text:sub(1, 300))
        got = (ok and type(got) == 'table') and got or {}
        H.eq(got.toolKept, true, 'the clientResult push keeps the running tool and its point spec')
        H.eq(got.autoOpen, true, 'a pending result of the running tool can open its editor (BuilderWorkspace)')
        H.eq(json.encode(got.paths), '[3,2]', 'a second flee path is added next to the first (a list of lists)')
        H.eq(got.toolAfter, true, 'the tool is forgotten once its result is applied')
        H.eq(got.checkpoints, 2, 'a 0.19 km recording with a 300 m spacing keeps its first and last point')
        H.eq(got.plain, true, 'a recorded patrol is saved as plain checkpoints, not a road route')
        H.eq(got.thinned, 45, 'the route meta says how many waypoints were recorded')
        H.eq(got.recMessage, 'builder.result.recorded_checkpoints', 'the confirmation says it was saved as checkpoints')
        H.eq(json.encode(got.beat), '[100,400,525]', 'a 0.44 km beat: checkpoints about 300 m apart and its end')
        H.eq(got.long, 20, 'a recorded patrol keeps at most checkpoint_route.checkpoints[2] checkpoints')
    end
end

-- ============================================================================
--                               USE MY POSITION
-- ============================================================================
-- (builderHere): the spot where the player stands.

do
    -- the tool an earlier case left running ends first (builderHere refuses while one runs, as the tools do)
    if B.active() then
        H.eq(select(2, Act('builderHere', { missionId = 'x' })), 'err.invalid_payload', 'the payload is checked first')
        B.cancel('ui')
        Frames(40)
    end
    H.eq(B.active(), nil, 'no tool runs before builderHere')
    local closes, opens = T.closes, #T.opens
    W.pos = { x = 1300.0, y = -3000.0, z = 6.0 }
    W.groundZ = 5.0
    W.heading = 120.0
    W.veh, W.water, W.swimming, W.blocked = 0, false, false, false
    local startPayload = {
        missionId = 'custom_dockside_raid',
        location = 1,
        key = 'start',
        kind = 'start',
        radius = 60,
        points = {},
        otherStarts = {},
        ui = 'admin',
    }
    -- B14: the start names its street (the New mission wizard names the mission after it)
    local streetAt, streetName = _G.GetStreetNameAtCoord, _G.GetStreetNameFromHashKey
    _G.GetStreetNameAtCoord = function(x) return x == 1300.0 and 4242 or 0, 0 end
    _G.GetStreetNameFromHashKey = function(h) return h == 4242 and 'Vespucci Blvd' or '' end
    local ok, r = Act('builderHere', startPayload)
    H.eq(ok, true, 'builderHere answers at once')
    H.eq(r.street, 'Vespucci Blvd', 'a start answers the street it stands on')
    H.eq(r.ok, true, 'the start is set where the player stands')
    H.eq(r.reason, false, 'no reason when it is ok')
    H.eq(json.encode({ r.point.x, r.point.y, r.point.z }), '[1300,-3000,5]',
        'a start is stored on the ground under the player (as the placement tool stores it)')
    H.eq(r.point.w, nil, 'a start keeps no heading')
    H.eq(r.result.kind, 'placement', 'the answer carries a placement result')
    H.eq(r.result.cancelled, false, 'not cancelled')
    H.eq(r.result.key, 'start', 'for the start')
    H.eq(#r.result.points, 1, 'one start')
    H.eq(r.result.radius, 60, 'the start keeps its radius')
    H.eq(B.active(), nil, 'no tool was started')
    H.eq(T.closes, closes, 'the tablet stayed open')
    H.eq(#T.opens, opens, 'and was not reopened')

    -- on foot, a hostile spawn point: added to the ones there, 1 m above the ground, facing the player's way
    local spawnPayload = {}
    for k, v in pairs(placePayload) do spawnPayload[k] = v end
    spawnPayload.points = { { x = 1250.0, y = -3000.0, z = 6.0, w = 0.0 } }
    spawnPayload.start = { x = 1200.0, y = -3000.0, z = 5.0 }
    ok, r = Act('builderHere', spawnPayload)
    H.eq(ok and r.ok, true, 'a spawn point is added where the player stands')
    H.eq(json.encode({ r.point.x, r.point.y, r.point.z, r.point.w }), '[1300,-3000,6,120]',
        'a ped point: 1 m above the ground, with the player\'s heading')
    H.eq(#r.result.points, 2, 'added after the point already placed')
    H.eq(r.street, nil, 'only a start names its street')
    H.eq(r.result.points[1].x, 1250.0, 'the placed point is kept')

    -- in a vehicle: the vehicle's position and heading, a vehicle point lifted by the model's height
    local car = NewEnt('vehicle', 1310.0, -3005.0, 5.8, true)
    W.veh = car
    W.heading = 271.0
    ok, r = Act('builderHere', {
        missionId = 'custom_dockside_raid',
        location = 1,
        key = 'cars',
        kind = 'vehicle',
        model = 'sultan',
        heading = true,
        multiple = true,
        max = 4,
        points = {},
        otherStarts = {},
    })
    H.eq(ok and r.ok, true, 'a vehicle point is set where the player\'s vehicle is')
    H.eq(json.encode({ r.point.x, r.point.y, r.point.z, r.point.w }), '[1310,-3005,5.6,271]',
        'a vehicle point: the vehicle\'s spot, the ground plus the model\'s lift, the vehicle\'s heading')
    W.veh = 0
    W.ents[car] = nil

    -- refused: in water, in a no-build zone, too close to the start, in a wall; nothing is set
    W.swimming = true
    ok, r = Act('builderHere', startPayload)
    H.eq(ok, true, 'a refusal is an answer too')
    H.eq(r.ok, false, 'refused in water')
    H.eq(r.reason, 'In water', 'the reason in words')
    H.eq(r.result, nil, 'no result to apply')
    W.swimming = false
    local zones = Config.Builder.noBuildZones
    Config.Builder.noBuildZones = { { label = 'Pier', coords = { x = 1305.0, y = -3000.0, z = 5.0 }, radius = 50.0 } }
    ok, r = Act('builderHere', startPayload)
    H.eq(r.ok, false, 'refused inside a no-build zone')
    H.eq(r.reason, 'Inside the no-build zone Pier', 'the zone is named')
    Config.Builder.noBuildZones = zones
    spawnPayload.start = { x = 1290.0, y = -3000.0, z = 5.0 }
    ok, r = Act('builderHere', spawnPayload)
    H.eq(r.ok, false, 'a spawn point too close to the start is refused')
    W.blocked = true
    spawnPayload.start = { x = 1200.0, y = -3000.0, z = 5.0 }
    ok, r = Act('builderHere', spawnPayload)
    H.eq(r.reason, 'Inside a wall, object or vehicle', 'a spot with no room for the ped is refused')
    W.blocked = false

    -- the same refusals as the tools, and the switch
    W.dead = true
    H.eq(select(2, Act('builderHere', startPayload)), 'err.builder_dead', 'refused while dead')
    W.dead = false
    H.eq(select(2, Act('builderHere', { missionId = 'x' })), 'err.invalid_payload', 'a bad payload')
    Config.Builder.useMyPosition = false
    H.eq(select(2, Act('builderHere', startPayload)), 'err.builder_here_off',
        'Config.Builder.useMyPosition = false turns it off')
    Config.Builder.useMyPosition = true
    H.eq(B.active(), nil, 'still no tool')
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
    W.heading = 90.0
    _G.GetStreetNameAtCoord, _G.GetStreetNameFromHashKey = streetAt, streetName
end

-- ============================================================================
--        B8: builderTeleport (the server says where, the screen never)
-- ============================================================================

do
    while B.active() do
        B.cancel('ui')
        H.step(100)
    end
    local moves, sentPayload = {}, nil
    local keep = {
        set = _G.SetEntityCoords,
        net = CP.Net.action,
        fadeOut = _G.DoScreenFadeOut,
        fadeIn = _G.DoScreenFadeIn,
        faded = _G.IsScreenFadedOut,
        collision = _G.RequestCollisionAtCoord,
    }
    _G.RequestCollisionAtCoord = function() end
    _G.SetEntityCoords = function(_, x, y, z) moves[#moves + 1] = { x = x, y = y, z = z } end
    _G.DoScreenFadeOut, _G.DoScreenFadeIn = function() end, function() end
    _G.IsScreenFadedOut = function() return true end
    local answer = { ok = true, data = {} }
    CP.Net.action = function(name, p)
        sentPayload = { name = name, p = p }
        if answer.ok then
            H.fire(CP.e('client:builder:teleport'), nil, {
                missionId = p.missionId,
                location = p.location,
                key = p.key,
                index = p.index,
                coords = { x = 10.0, y = 20.0, z = 30.0 },
            })
        end
        return answer
    end
    local function Run(payload)
        local res = nil
        CreateThread(function() res = { Act('builderTeleport', payload) } end)
        for _ = 1, 40 do
            if res then break end
            H.step(50)
        end
        return res or {}
    end
    H.ok(H.handlers[CP.e('client:builder:teleport')] ~= nil, 'crimson-police:client:builder:teleport is handled')
    H.fire(CP.e('client:builder:teleport'), nil,
        { missionId = 'm', location = 1, key = 'start', index = 1, coords = { x = 1.0, y = 1.0, z = 1.0 } })
    H.eq(#moves, 0, 'an answer to no request moves nobody')
    W.groundZ = 28.5
    local r = Run(
        { missionId = 'custom_yard', location = 2, key = 'spawns', index = 3, coords = { x = 99, y = 99, z = 99 } })
    H.eq(r[1], true, 'builderTeleport: ' .. tostring(r[2]))
    H.ok(
        sentPayload and sentPayload.name == 'server:builder:teleport' and sentPayload.p.coords == nil
            and sentPayload.p.key == 'spawns' and sentPayload.p.index == 3,
        'the server is asked which point, with no coordinates'
    )
    H.ok(#moves >= 1 and moves[#moves].x == 10.0 and moves[#moves].y == 20.0 and moves[#moves].z == 28.5,
        'he lands on the ground at the server\'s point')
    moves = {}
    answer = { ok = false, error = 'err.no_permission' }
    r = Run({ missionId = 'custom_yard', location = 2, key = 'spawns', index = 3 })
    H.eq(r[2], 'err.no_permission', 'a server refusal is passed on')
    H.eq(#moves, 0, 'and nobody moves')
    W.dead = true
    H.eq(Run({ missionId = 'custom_yard', location = 1, key = 'start', index = 1 })[2], 'err.builder_dead',
        'refused while down')
    W.dead = false
    Config.Builder.teleport = false
    H.eq(Run({ missionId = 'custom_yard', location = 1, key = 'start', index = 1 })[2], 'err.builder_teleport_off',
        'Config.Builder.teleport = false')
    Config.Builder.teleport = true
    _G.SetEntityCoords, CP.Net.action = keep.set, keep.net
    _G.DoScreenFadeOut, _G.DoScreenFadeIn, _G.IsScreenFadedOut = keep.fadeOut, keep.fadeIn, keep.faded
    _G.RequestCollisionAtCoord = keep.collision
end

-- ============================================================================
--                                     B10
-- ============================================================================
-- FILL THE POINTS FOR ME (B.autoFill, builderAutoPoints).

do
    local U = CP.U
    -- a repeatable random(): the same spots every run
    local seed = 12345
    local function Random()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed / 2147483648
    end
    local start = { x = 1000.0, y = -3000.0, z = 5.0 }
    local o = assert(B.parsePlace({
        missionId = 'custom_shootout',
        location = 1,
        key = 'hostiles',
        kind = 'ped',
        heading = true,
        multiple = true,
        min = 11,
        max = 20,
        points = {},
        start = start,
        spawn = true,
        armed = true,
        startRadius = 60,
        minGap = 4,
        otherStarts = {},
    }))
    local keepOut = B.armedKeepOut({ armed = true, startRadius = 60, spawnMargin = 40, minFromStart = 30 })
    H.eq(keepOut, 100, 'the armed keep-out of a 60 m start: 100 m')
    local inner, outer = B.autoRing(o, { 15.0, 80.0 })
    H.eq(inner .. '/' .. outer, '115.0/180.0', 'the ring is Config.Builder.autoFillRing beyond the keep-out')
    local walls = 0
    local snapped = 0
    local deps = {
        ring = { 15.0, 80.0 },
        lift = 1.0,
        random = Random,
        snap = function(_, x, y)
            snapped = snapped + 1
            if snapped % 5 == 0 then
                return nil
            end -- no navmesh there
            -- the snap may pull a spot inwards: some land inside the keep-out and must be dropped
            local dx, dy = x - start.x, y - start.y
            local k = snapped % 4 == 0 and 0.5 or 1.0
            return { x = start.x + dx * k, y = start.y + dy * k, z = 5.0 }
        end,
        probe = function(_, _, _, z)
            walls = walls + 1
            if walls % 3 == 0 then return { status = 'in_wall', wall = true } end
            if walls % 7 == 0 then return { status = 'snap', z = 6.2, groundZ = 5.2 } end
            return { status = 'ok', z = z, groundZ = 5.0, normalZ = 1.0, wall = false }
        end,
    }
    local r = B.autoFill(o, 11, deps)
    H.eq(#r.added, 11, 'a fill proposes the 11 points asked for')
    H.eq(#r.points, 11, 'with none there before')
    H.ok(r.dropped > 0, 'spots with no ground, in a wall or inside the keep-out are dropped: ' .. r.dropped)
    H.eq(r.tries, #r.added + r.dropped, 'every try is a point or a drop')
    local inside, close, noHeading, bad = 0, 0, 0, 0
    for i, p in ipairs(r.added) do
        if U.dist2d(p, start) < keepOut then inside = inside + 1 end
        for j = i + 1, #r.added do
            if U.dist(p, r.added[j]) < 4 then close = close + 1 end
        end
        if type(p.w) ~= 'number' then noHeading = noHeading + 1 end
        if p.z ~= 6.0 and p.z ~= 6.2 then bad = bad + 1 end
    end
    H.eq(inside, 0, 'no proposed point is inside the keep-out (the arrival circle plus the margin)')
    H.eq(close, 0, 'every two proposed points are minGap (4 m) apart')
    H.eq(noHeading, 0, 'a heading key gets headings (facing the start)')
    H.eq(bad, 0, 'stored 1 m above the ground, or where the probe snapped it')
    local p1 = r.added[1]
    H.ok(math.abs(((p1.w - B.headingOf(p1, start)) + 180) % 360 - 180) < 0.02, 'the first point faces the start')

    -- the points already there are kept and counted for the spacing; the key's max caps the fill
    local o2 = assert(B.parsePlace({
        missionId = 'custom_shootout',
        location = 1,
        key = 'hostiles',
        kind = 'ped',
        multiple = true,
        max = 3,
        points = { { x = 1120.0, y = -3000.0, z = 6.0 } },
        start = start,
        spawn = true,
        armed = true,
        startRadius = 60,
        otherStarts = {},
    }))
    r = B.autoFill(o2, 11, deps)
    H.eq(#r.added, 2, 'a fill never goes past the key\'s max')
    H.eq(r.points[1].x, 1120.0, 'the point already placed is kept first')
    for _, p in ipairs(r.added) do
        H.ok(U.dist(p, r.points[1]) >= 3.0, 'a proposed point keeps 3 m from a placed one')
    end

    -- nothing safe: the fill stops after its tries, with nothing proposed
    r = B.autoFill(o, 11, {
        random = Random,
        snap = function(_, x, y) return { x = x, y = y, z = 5.0 } end,
        probe = function() return { status = 'in_water', water = true } end,
    })
    H.eq(#r.added, 0, 'no point when every spot fails')
    H.eq(r.tries, 132, 'and it stops after 12 tries per point')

    -- the client action
    while B.active() do
        B.cancel('ui')
        H.step(100)
    end
    local keep = { safe = _G.GetSafeCoordForPed, side = _G.GetPointOnRoadSide, spawn = CP.Spawn }
    _G.GetSafeCoordForPed = function(x, y, z) return true, vector3(x, y, z) end
    _G.GetPointOnRoadSide = function(x, y, z) return true, vector3(x + 2.0, y, z) end
    CP.Spawn = {
        probe = function(_, _, _, z) return { status = 'ok', z = z, groundZ = 5.0, normalZ = 1.0 } end,
    }
    W.groundZ = 5.0
    W.pos = { x = 1010.0, y = -3000.0, z = 6.0 }
    local payload = {
        missionId = 'custom_shootout',
        location = 1,
        key = 'hostiles',
        kind = 'ped',
        heading = true,
        multiple = true,
        min = 11,
        max = 20,
        points = {},
        start = start,
        spawn = true,
        armed = true,
        startRadius = 60,
        otherStarts = {},
        count = 11,
    }
    local ok, reply = Act('builderAutoPoints', payload)
    H.eq(ok, true, 'builderAutoPoints answers: ' .. tostring(reply))
    H.eq(reply.ok, true, 'the points are proposed')
    H.eq(#reply.proposed, 11, '11 proposed points')
    H.eq(reply.result and reply.result.kind, 'placement', 'with a placement result to keep')
    H.eq(#reply.result.points, 11, 'holding them')
    H.eq(B.active(), nil, 'no tool was started')
    local veh = {}
    for k, v in pairs(payload) do veh[k] = v end
    veh.kind, veh.key, veh.count, veh.model = 'vehicle', 'cars', 2, 'sultan'
    ok, reply = Act('builderAutoPoints', veh)
    H.eq(ok and reply.ok and #reply.proposed, 2, 'vehicle points are proposed at the side of the road')
    W.pos = { x = 1500.0, y = -3000.0, z = 6.0 }
    ok, reply = Act('builderAutoPoints', payload)
    H.eq(ok and reply.ok, false, 'refused while the player is far from the location')
    H.ok(tostring(reply.reason):find('Stand near the location', 1, true) ~= nil, 'and he is told to stand near it')
    W.pos = { x = 1010.0, y = -3000.0, z = 6.0 }
    payload.start = nil
    H.eq(select(2, Act('builderAutoPoints', payload)), 'err.builder_auto_start', 'a fill needs the start')
    payload.start = start
    payload.count = nil
    H.eq(select(2, Act('builderAutoPoints', payload)), 'err.invalid_payload', 'a fill needs a count')
    payload.count = 11
    H.eq(select(2, Act('builderAutoPoints', placePayload)), 'err.invalid_payload', 'a payload with no count')
    Config.Builder.autoFill = false
    H.eq(select(2, Act('builderAutoPoints', payload)), 'err.builder_auto_off', 'Config.Builder.autoFill = false')
    Config.Builder.autoFill = true
    _G.GetSafeCoordForPed, _G.GetPointOnRoadSide, CP.Spawn = keep.safe, keep.side, keep.spawn
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
end

-- ============================================================================
--                                     B12
-- ============================================================================
-- MOVE THE WHOLE LOCATION HERE (B.checkPoints, builderCheckPoints).

do
    local start = { x = 2000.0, y = 500.0, z = 30.0 }
    local base = {
        missionId = 'custom_shootout',
        location = 1,
        start = start,
        startRadius = 60,
        offset = { x = 1000.0, y = 3500.0, z = 24.1 },
        keys = {
            {
                key = 'hostiles',
                kind = 'ped',
                spawn = true,
                armed = true,
                minGap = 4,
                points = {
                    { x = 880.0, y = -3000.0, z = 6.0, w = 90.0 },  -- 120 m from the old start: fine
                    { x = 1000.0, y = -2880.0, z = 6.0, w = 0.0 },  -- in water at the new place
                    { x = 1002.0, y = -2880.0, z = 6.0, w = 0.0 },  -- 2 m from the 2nd (failed: not counted)
                    { x = 1120.0, y = -3000.0, z = 6.0, w = 0.0 },  -- in a wall
                    { x = 1122.0, y = -3000.0, z = 6.0, w = 0.0 },  -- fine
                    { x = 1124.0, y = -3000.0, z = 6.0, w = 0.0 },  -- 2 m from the 5th: too close
                },
            },
            { key = 'cars', kind = 'vehicle', model = 'sultan', points = { { x = 1050.0, y = -3050.0, z = 5.5 } } },
            { key = 'door', kind = 'marker', points = { { x = 1010.0, y = -3000.0, z = 5.0 } } },
            {
                key = 'route',
                route = true,
                points = { { x = 900.0, y = -3000.0, z = 5.0 }, { x = 1900.0, y = -3000.0, z = 9.0 } },
            },
        },
    }
    local o = assert(B.parseCheckPoints(base))
    H.eq(#o.keys, 4, 'every point list of the location is read')
    local probes = {}
    local deps = {
        ground = function(x) return x < 2500.0 and 30.0 + (x - 1880.0) / 1000.0 or nil end,
        lift = function(kind) return kind == 'vehicle' and 0.6 or 1.0 end,
        probe = function(kind, x, y, z)
            probes[#probes + 1] = kind
            if x == 2000.0 and y == 620.0 then return { status = 'in_water', water = true } end
            if x == 2120.0 then return { status = 'in_wall', wall = true } end
            if kind == 'vehicle' then return { status = 'snap', z = z + 0.4, groundZ = z - 0.6 } end
            return { status = 'ok', z = z, groundZ = z - (kind == 'ped' and 1.0 or 0.0), normalZ = 1.0, wall = false }
        end,
    }
    local r = B.checkPoints(o, deps)
    local byKey = {}
    for _, k in ipairs(r.keys) do byKey[k.key] = k end
    local h = byKey.hostiles
    H.eq(#h.points, 6, 'every point of a key moves')
    H.eq(h.points[1].x .. '/' .. h.points[1].y, '1880.0/500.0', 'by the same offset as the start (x, y)')
    H.eq(h.points[1].w, 90.0, 'and keeps its heading')
    H.eq(h.points[1].z, 31.0, 'its height is put on the ground there (1 m over it for a person), not the old z + dz')
    H.eq(byKey.cars.points[1].z, 31.17, 'a vehicle is put where the probe snapped it')
    H.eq(byKey.door.points[1].z, 30.13, 'a marker sits on the ground')
    local route = byKey.route
    H.eq(route.points[2].x .. '/' .. route.points[2].z, '2900.0/33.1', 'a route only moves (no ground found is fine)')
    H.eq(route.checked, false, 'and is not checked')
    H.eq(#route.failed, 0, 'with no failures')
    local failed = {}
    for _, f in ipairs(h.failed) do failed[#failed + 1] = f.index .. ':' .. f.reasonKey end
    H.eq(table.concat(failed, ' '),
        '2:builder.place.reason.water 4:builder.place.reason.blocked 6:' .. 'builder.place.reason.spacing',
        'the failed points are listed with why (a failed one keeps no spacing)')
    H.eq(r.moved .. '/' .. r.failed, '10/3', '10 points moved, 3 need a new spot')

    -- the keep-out of the new start, no ground, and the time limit
    local near = assert(B.parseCheckPoints({
        missionId = 'custom_shootout',
        location = 1,
        start = start,
        startRadius = 60,
        offset = { x = 0.0, y = 0.0, z = 0.0 },
        keys = {
            {
                key = 'hostiles',
                kind = 'ped',
                spawn = true,
                armed = true,
                points = { { x = 2050.0, y = 500.0, z = 31.0 }, { x = 2600.0, y = 500.0, z = 31.0 } },
            },
        },
    }))
    r = B.checkPoints(near, deps)
    failed = {}
    for _, f in ipairs(r.keys[1].failed) do failed[#failed + 1] = f.index .. ':' .. f.reasonKey end
    H.eq(table.concat(failed, ' '), '1:builder.place.reason.armed 2:builder.place.reason.not_ground',
        'inside the new keep-out, and with no ground, a point fails')
    r = B.checkPoints(o, {
        ground = deps.ground,
        probe = deps.probe,
        timeUp = function() return true end,
    })
    H.eq(r.failed, 8, 'after the time limit the points not checked are listed (routes are never checked)')
    H.eq(r.keys[1].failed[1].reasonKey, 'builder.move.reason.time', 'as not checked in time')

    -- the payload
    local bad = { missionId = 'custom_shootout', location = 1, start = start, keys = {} }
    H.eq(select(2, B.parseCheckPoints(bad)), 'err.invalid_payload', 'a move needs the offset')
    bad.offset, bad.keys = { x = 1, y = 2, z = 3 }, { { key = 'x', kind = 'tank', points = {} } }
    H.eq(select(2, B.parseCheckPoints(bad)), 'err.invalid_payload', 'and known kinds')

    -- the client action
    while B.active() do
        B.cancel('ui')
        H.step(100)
    end
    local keep, collision = CP.Spawn, _G.RequestCollisionAtCoord
    _G.RequestCollisionAtCoord = function() end
    CP.Spawn = {
        probe = function(kind, _, _, z)
            return { status = 'ok', z = z, groundZ = z - (kind == 'ped' and 1.0 or 0.0), normalZ = 1.0 }
        end,
    }
    W.groundZ = 30.0
    W.pos = { x = 2005.0, y = 500.0, z = 31.0 }
    local ok, reply = Act('builderCheckPoints', base)
    H.eq(ok, true, 'builderCheckPoints answers: ' .. tostring(reply))
    H.eq(reply.ok and reply.moved, 10, 'all 10 points moved')
    H.eq(reply.keys[1].points[1].z, 31.0, 'on the ground where the player stands')
    H.eq(reply.failed, 2, 'the two hostiles closer than 4 m to another are listed')
    H.ok(type(reply.keys[1].failed[1].reason) == 'string' and reply.keys[1].failed[1].reasonKey == nil,
        'with the reason in words')
    W.pos = { x = 1017.5, y = -3108.4, z = 5.9 }
    ok, reply = Act('builderCheckPoints', base)
    H.eq(ok and reply.ok, false, 'refused while the player is far from the new start')
    Config.Builder.useMyPosition = false
    H.eq(select(2, Act('builderCheckPoints', base)), 'err.builder_here_off', 'Config.Builder.useMyPosition = false')
    Config.Builder.useMyPosition = true
    CP.Spawn, _G.RequestCollisionAtCoord = keep, collision
end

-- ============================================================================
--            B17: builderShowMap (temporary blips on the pause map)
-- ============================================================================

do
    local frontend = 0
    local coordBlips = {}
    _G.AddBlipForCoord = function(x, y, z)
        local b = 1900 + #coordBlips + 1
        coordBlips[#coordBlips + 1] = { b = b, x = x, y = y, z = z }
        W.blips[b] = true
        return b
    end
    _G.SetBlipScale = function() end
    _G.SetBlipAsShortRange = function() end
    _G.IsPauseMenuActive = function() return false end
    _G.ActivateFrontendMenu = function() frontend = frontend + 1 end
    local function Live()
        local n = 0
        for _, c in ipairs(coordBlips) do if W.blips[c.b] then n = n + 1 end end
        return n
    end
    local cabin = { x = 1390.2, y = 3605.8, z = 38.9 }
    local payload = {
        points = {
            { kind = 'start', coords = cabin },
            { kind = 'spawn', coords = { x = 1395.0, y = 3610.0, z = 38.9 } },
            { kind = 'checkpoint', coords = { x = 1420.0, y = 3640.0, z = 38.0 } },
        },
    }
    H.eq(select(2, Act('builderShowMap', {})), 'err.invalid_payload', 'show on map needs points')
    H.eq(select(2, Act('builderShowMap', { points = { { kind = 'boat', coords = cabin } } })), 'err.invalid_payload',
        'an unknown point kind is refused')
    H.eq(select(2, Act('builderShowMap', { points = { { kind = 'start', coords = 'cabin' } } })), 'err.invalid_payload',
        'a point needs coords')
    local many = {}
    for i = 1, 301 do many[i] = { kind = 'spawn', coords = cabin } end
    H.eq(select(2, Act('builderShowMap', { points = many })), 'err.invalid_payload', 'at most 300 points')
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
    H.eq(select(2, Act('builderShowMap', payload)), 'err.in_arena', 'show on map refused in Crimson-Arena')
    LocalPlayer.state.crimsonArena = nil
    H.eq(#coordBlips, 0, 'no blip from a refused request')

    T.isOpen = true
    local closes = T.closes
    local ok, reply = Act('builderShowMap', payload)
    H.eq(ok, true, 'show on map accepted')
    H.eq(reply.shown, 3, 'one blip per point')
    H.eq(Live(), 3, 'the start, the spawn and the checkpoint are on the map')
    H.eq(coordBlips[1].x, cabin.x, 'the start blip sits on the start')
    Frames(10, 50)
    H.eq(T.closes, closes + 1, 'the tablet closes')
    H.eq(frontend, 1, 'the pause map opens')
    Frames(10, 100)
    H.eq(Live(), 3, 'the blips stay while the tablet is closed')

    -- a second "Show on map" replaces the first one's blips
    ok = Act('builderShowMap', { points = { { kind = 'start', coords = cabin } } })
    H.eq(ok, true, 'a second show accepted')
    H.eq(Live(), 1, 'the earlier blips are cleared')
    Frames(10, 50)
    H.eq(B.mapBlips(), 1, 'one blip on the map')
    CP.Tablet.open('supervisor')
    Frames(4, 100)
    H.eq(Live(), 0, 'the blips are cleared when the tablet opens again')
    H.eq(B.mapBlips(), 0, 'nothing left on the map')

    -- a resource stop clears them too
    T.isOpen = true
    Act('builderShowMap', payload)
    H.eq(Live(), 3, 'shown again')
    TriggerEvent('onResourceStop', CP.resource)
    H.eq(Live(), 0, 'a resource stop clears the blips')
    Frames(10, 100)
    T.isOpen = true
end

-- ============================================================================
--                LOCALE: every text key the client uses exists
-- ============================================================================

do
    local fh = assert(io.open(H.root .. 'modules/builder/client.lua', 'r'))
    local src = fh:read('a')
    fh:close()
    local missing = {}
    for key in src:gmatch('\'(builder%.[%w_%.]+)\'') do
        if key ~= 'builder.' and not key:match('%.$') and strings[key] == nil then missing[#missing + 1] = key end
    end
    for key in src:gmatch('\'(err%.[%w_]+)\'') do
        if strings[key] == nil then missing[#missing + 1] = key end
    end
    H.eq(table.concat(missing, ', '), '',
        'every builder.* / err.* key of the client is in locales/parts/builder_client.json')
end

return H
