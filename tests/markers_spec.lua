-- CP.Markers (modules/markers/client.lua; PLAN M1, BLIPS_FINAL R1-R10): the objective pointer on an officer's map,
-- one GPS line at most, cleared at every stop; and its hooks in modules/runs/client.lua.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                     THE GAME: BLIPS, ENTITIES, WAYPOINT
-- ============================================================================

local PED = 4242
local world = { me = vec3(0.0, 0.0, 30.0), waypoint = false, route = nil, ents = {}, streamed = {}, netChecks = 0 }
local BL = { all = {}, n = 0, log = {}, name = nil }

local function NewBlip(kind, fields)
    BL.n = BL.n + 1
    local b = { id = BL.n, kind = kind, live = true, route = false, flashes = false }
    for k, v in pairs(fields) do b[k] = v end
    BL.all[BL.n] = b
    BL.log[#BL.log + 1] = { op = 'add', id = BL.n, kind = kind }
    return BL.n
end
local function B(id) return BL.all[id] end
local function Setter(field)
    return function(id, v)
        local b = BL.all[id]
        if b then b[field] = v end
    end
end

_G.PlayerPedId = function() return PED end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 7 end
_G.GetEntityCoords = function(e)
    if e == PED then return world.me end
    return world.ents[e] or vec3(0.0, 0.0, 0.0)
end
_G.DoesEntityExist = function(e) return e == PED or world.ents[e] ~= nil end
_G.NetworkDoesNetworkIdExist = function(n)
    world.netChecks = world.netChecks + 1
    return world.streamed[n] ~= nil
end
_G.NetworkGetEntityFromNetworkId = function(n) return world.streamed[n] or 0 end
_G.IsWaypointActive = function() return world.waypoint end
_G.AddBlipForCoord = function(x, y, z) return NewBlip('coord', { x = x, y = y, z = z }) end
_G.AddBlipForEntity = function(e) return NewBlip('entity', { ent = e }) end
_G.AddBlipForRadius = function(x, y, z, r) return NewBlip('radius', { x = x, y = y, z = z, radius = r }) end
_G.DoesBlipExist = function(id) return BL.all[id] ~= nil and BL.all[id].live end
_G.RemoveBlip = function(id)
    local b = BL.all[id]
    if b then b.live = false end
    BL.log[#BL.log + 1] = { op = 'remove', id = id, routed = b and b.route }
end
_G.SetBlipRoute = function(id, on)
    local b = BL.all[id]
    if b then b.route = on == true end
    BL.log[#BL.log + 1] = { op = 'route', id = id, on = on == true }
end
_G.SetBlipCoords = function(id, x, y, z)
    local b = BL.all[id]
    if b then b.x, b.y, b.z, b.moved = x, y, z, (b.moved or 0) + 1 end
end
_G.GetBlipCoords = function(id)
    local b = BL.all[id]
    if not b then return vec3(0.0, 0.0, 0.0) end
    if b.kind == 'entity' then return world.ents[b.ent] or vec3(0.0, 0.0, 0.0) end
    return vec3(b.x or 0.0, b.y or 0.0, b.z or 0.0)
end
_G.SetBlipSprite = Setter('sprite')
_G.SetBlipColour = Setter('colour')
_G.SetBlipScale = Setter('scale')
_G.SetBlipAlpha = Setter('alpha')
_G.SetBlipAsShortRange = Setter('shortRange')
_G.SetBlipCategory = Setter('category')
_G.SetBlipPriority = Setter('priority')
_G.SetBlipFlashes = Setter('flashes')
_G.SetBlipFlashTimer = Setter('flashMs')
_G.SetBlipRouteColour = Setter('routeColour')
_G.ShowNumberOnBlip = Setter('number')
_G.BeginTextCommandSetBlipName = function(kind) BL.name = { kind = kind } end
_G.AddTextComponentSubstringPlayerName = function(text) BL.name.text = text end
_G.EndTextCommandSetBlipName = function(id)
    local b = BL.all[id]
    if b and BL.name and BL.name.kind == 'STRING' then b.name = BL.name.text end
end

local function Live(kind)
    local out = {}
    for id, b in pairs(BL.all) do if b.live and (kind == nil or b.kind == kind) then out[#out + 1] = id end end
    table.sort(out)
    return out
end
local function Routed()
    local out = {}
    for id, b in pairs(BL.all) do if b.live and b.route then out[#out + 1] = id end end
    return out
end
local function Tick(n) for _ = 1, n or 1 do H.step(1000) end end
local defaults = {}
for k, v in pairs(Config.Markers) do defaults[k] = v end
local function Reset()
    world.me, world.waypoint, world.route, world.ents, world.streamed = vec3(0.0, 0.0, 30.0), false, nil, {}, {}
    CP.Markers.clear()
    for _, b in pairs(BL.all) do b.live = false end
    BL.log = {}
    Config.Markers = {}
    for k, v in pairs(defaults) do Config.Markers[k] = v end
end
-- every blip that left the map had its GPS line turned off first (BLIPS_FINAL R10)
local function NoRemovedRoute()
    for _, e in ipairs(BL.log) do if e.op == 'remove' and e.routed then return false end end
    return true
end

CP.Route = {
    current = function() return world.route end,
}
H.load('modules/markers/client.lua')
local M = CP.Markers
H.ok(type(M.set) == 'function' and type(M.adopt) == 'function' and type(M.release) == 'function', 'CP.Markers loaded')
local K = Config.Markers.kinds

-- ============================================================================
--                 CONFIG: THE SHIPPED VALUES AND THEIR LIMITS
-- ============================================================================

do
    local c = Config.Markers
    H.ok(c.enabled == true and c.route == true and c.routeColour == 5 and c.routeOffWithin == 40.0,
        'shipped: on, yellow')
    H.ok(c.trackEvery == 2 and c.farTargets == true and c.shortRange == false and c.flashSeconds == 5,
        'shipped: R5, R7')
    H.ok(c.category == 2 and c.areaAlpha == 80 and c.startCircleMin == 200.0, 'shipped: legend distance, circles')
    H.eq(c.radioSilence, 'area', 'shipped: Radio Silence keeps circles and single points (owner decision)')
    H.eq(c.radioSilenceLastKnown, 0, 'shipped: no last-known circle')
    H.ok(c.startBlip == true and c.hudLine == true and c.objectiveGps == true and c.serviceVehicles == true, 'switches')
    H.eq(K.fightArea.sprite, 84, 'kinds: the fight area is a red skull')
    H.eq(K.fightArea.colour, 1, 'kinds: red = enemy')
    H.eq(K.escort.colour, 3, 'kinds: blue = friendly')
    H.eq(K.scene.sprite, 162, 'kinds: the scene is a map pin, never 310 (skull and crossbones)')
    for name, k in pairs(K) do
        -- BLIPS_FINAL R4: no plain yellow or blue sprite-1 dot (the police and EMS duty look) unless it is numbered
        local numbered = name == 'checkpoint' or name == 'clue' or name == 'point' or name == 'device'
        H.ok(not (k.sprite == 1 and (k.colour == 5 or k.colour == 3)) or numbered, 'kinds.' .. name .. ': no duty dot')
    end
    -- a config.lua without the section is reported at start (shared/init.lua CONFIG_SECTIONS); the ranges and the
    -- Radio Silence choice are checked in tests/settings_spec.lua
    local cfg = {}
    for k, v in pairs(Config) do cfg[k] = v end
    H.eq(CP.configProblem(cfg), nil, 'the shipped config is whole')
    cfg.Markers = nil
    local level, text = CP.configProblem(cfg)
    H.ok(level == 'warn' and text:find('Config.Markers is missing', 1, true) ~= nil,
        'a missing Config.Markers is named')
end

-- ============================================================================
--                     A POINT: ONE BLIP, ONE LINE, CLEARED
-- ============================================================================

do
    Reset()
    H.ok(M.set('run-1', 1, { kind = 'point', coords = { x = 500.0, y = 0.0, z = 30.0 }, label = 'Business' }), 'set')
    local live = Live()
    H.eq(#live, 1, 'one blip for a point')
    local b = B(live[1])
    H.eq(b.kind, 'coord', 'at the point')
    H.ok(b.x == 500.0 and b.y == 0.0, 'where the server said')
    H.eq(b.sprite, K.objective.sprite, 'kinds.objective sprite')
    H.eq(b.colour, K.objective.colour, 'kinds.objective colour')
    H.eq(b.scale, K.objective.scale, 'kinds.objective scale')
    H.eq(b.name, 'Business', 'named with the marker label')
    H.eq(b.shortRange, false, 'not short range (shows at the radar edge)')
    H.eq(b.category, 2, 'legend shows the distance')
    H.eq(b.priority, 12, 'above the detail blips')
    H.ok(b.flashes == true and b.flashMs == 5000, 'flashes for flashSeconds (SET_BLIP_FLASH_TIMER)')
    H.eq(#Routed(), 1, 'one GPS line')
    H.ok(b.route and b.routeColour == 5, 'on the point, in routeColour')

    -- R6: off within routeOffWithin, back on when leaving
    world.me = vec3(470.0, 0.0, 30.0)
    Tick()
    H.eq(#Routed(), 0, 'no line within 40 m')
    world.me = vec3(400.0, 0.0, 30.0)
    Tick()
    H.eq(#Routed(), 1, 'the line is back 100 m away')

    -- an update with the same shape keeps the blip (its line and flash survive)
    M.update('run-1', 1, { kind = 'point', coords = { x = 500.0, y = 0.0, z = 30.0 }, label = 'Business' })
    H.eq(Live()[1], live[1], 'the same blip after an unchanged update')
    H.ok(B(live[1]).route, 'still routed')

    -- clear: the line off before the blip goes
    H.ok(M.clear('run-1', 1), 'clear')
    H.eq(#Live(), 0, 'nothing left on the map')
    H.ok(NoRemovedRoute(), 'SetBlipRoute(false) before RemoveBlip')
    H.eq(M.clear('run-1', 1), false, 'a second clear finds nothing')

    -- the loop ends with the marker: nothing runs for an officer with no objective
    local checks = world.netChecks
    Tick(5)
    H.eq(world.netChecks, checks, 'no checks once cleared')
end

-- ============================================================================
--           THE LOOP: ONLY WHILE SOMETHING IS ON THE MAP, NEVER TWO
-- ============================================================================

do
    Reset()
    Tick(2)
    local realThread, threads = CreateThread, 0
    _G.CreateThread = function(fn)
        threads = threads + 1
        return realThread(fn)
    end
    M.set('run-l', 1, nil)
    H.eq(threads, 0, 'an objective with no marker starts no loop')
    local target = { kind = 'targets', targets = { { key = 41, netId = 41, x = 800.0, y = 0.0, z = 30.0 } } }
    M.set('run-l', 1, target)
    H.eq(threads, 1, 'a marker starts one loop')
    M.clear()
    M.set('run-l', 2, target)
    M.update('run-l', 2, target)
    M.set('run-l', 3, target)
    H.eq(threads, 1, 'set, clear and set again: still the one loop')
    local checks = world.netChecks
    Tick(3)
    H.eq(world.netChecks - checks, 3, 'one check of the one target a second')
    M.clear()
    Tick(2)
    M.set('run-l', 4, target)
    H.eq(threads, 2, 'the loop ended with the clear; a new marker starts a new one')
    M.clear()
    _G.CreateThread = realThread
end

-- ============================================================================
--                         R2: ONE GPS LINE PER OFFICER
-- ============================================================================

do
    Reset()
    world.route = { runId = 'run-2', arrived = false, routeOn = true }
    M.set('run-2', 1, { kind = 'point', coords = { x = 900.0, y = 0.0, z = 30.0 } })
    H.eq(#Live(), 1, 'the pointer shows while the officer drives to the start')
    H.eq(#Routed(), 0, 'but no line: the start keeps the only one (CP.Route samples the blip route first)')
    world.route.arrived = true
    Tick()
    H.eq(#Routed(), 1, 'arrived: the pointer routes')
    world.waypoint = true
    Tick()
    H.eq(#Routed(), 0, 'his own waypoint: our line goes off')
    world.waypoint = false
    world.route = nil
    Tick()
    H.eq(#Routed(), 1, 'waypoint gone: back on')
    H.eq(B(Live()[1]).name, 'markers.objective', 'no label: the Objective fallback')

    Config.Markers.route = false
    Tick()
    H.eq(#Routed(), 0, 'route = false: the line goes off')
    Config.Markers.route = true
    Tick()
    M.set('run-2', 2, { kind = 'point', coords = { x = 900.0, y = 0.0, z = 30.0 }, route = 'block' })
    Tick()
    H.eq(#Live(), 1, 'route = block: the point shows')
    H.eq(#Routed(), 0, 'and the block keeps its own line')
    Config.Markers.route = false
    M.set('run-2', 3, { kind = 'point', coords = { x = 900.0, y = 0.0, z = 30.0 } })
    Tick(3)
    local ever = false
    for _, e in ipairs(BL.log) do if e.op == 'route' and e.on and e.id == Live()[1] then ever = true end end
    H.eq(ever, false, 'route = false never routes')
    H.ok(NoRemovedRoute(), 'every replaced blip lost its line first')
    M.clear()
end

-- ============================================================================
--                   R7: TARGETS FAR AWAY, STREAMED, NEAREST
-- ============================================================================

do
    Reset()
    -- a fleeing car 800 m away: not streamed to this game, shown from the server's position
    M.set('run-3', 1, {
        kind = 'targets',
        targets = { { key = 101, netId = 101, x = 800.0, y = 0.0, z = 30.0, look = 'vehicle', label = 'Getaway car' } },
    })
    local live = Live()
    H.eq(#live, 1, 'one blip for the unstreamed car')
    local far = B(live[1])
    H.ok(far.kind == 'coord' and far.x == 800.0, 'a coord blip at the server position')
    H.eq(far.sprite, K.vehicle.sprite, 'the same sprite as the car blip (kinds.vehicle)')
    H.eq(far.colour, K.vehicle.colour, 'red: enemy')
    H.eq(far.name, 'Getaway car', 'the target label')
    H.ok(far.route, 'the line goes to it')
    M.update('run-3', 1, {
        kind = 'targets',
        targets = { { key = 101, netId = 101, x = 700.0, y = 50.0, z = 30.0, look = 'vehicle', label = 'Getaway car' } },
    })
    H.eq(Live()[1], live[1], 'the same blip, moved')
    H.ok(far.x == 700.0 and far.y == 50.0 and (far.moved or 0) >= 1, 'SetBlipCoords to the new server position')

    -- it streams in: an entity blip replaces the coord blip, the line moves with it
    world.ents[5001] = vec3(300.0, 0.0, 30.0)
    world.streamed[101] = 5001
    Tick()
    live = Live()
    H.eq(#live, 1, 'still one icon')
    local near = B(live[1])
    H.ok(near.kind == 'entity' and near.ent == 5001, 'an entity blip once streamed')
    H.ok(near.route and #Routed() == 1, 'the line moved to the entity blip')
    H.eq(far.live, false, 'the coord blip is gone')
    H.eq(near.flashes, false, 'the swap does not flash again')

    -- it streams out again: back to the server position
    world.streamed[101] = nil
    Tick()
    live = Live()
    H.ok(#live == 1 and B(live[1]).kind == 'coord', 'a coord blip again after it streamed out')
    H.eq(#Routed(), 1, 'one line')
    H.ok(NoRemovedRoute(), 'no blip left with its line on')

    -- farTargets = false: an unstreamed target shows nothing
    Config.Markers.farTargets = false
    Tick()
    H.eq(#Live(), 0, 'farTargets off: no blip out of streaming range')
    Config.Markers.farTargets = true

    -- two targets: the line goes to the nearest, and moves only when another is 25 % closer
    M.set('run-3', 2, {
        kind = 'targets',
        targets = {
            { key = 'a', x = 300.0, y = 0.0, z = 30.0, look = 'fleeing' },
            { key = 'b', x = 0.0, y = 200.0, z = 30.0, look = 'fleeing' },
        },
    })
    local function RoutedAt()
        local r = Routed()
        if #r ~= 1 then return nil end
        local b = B(r[1])
        return b.x, b.y
    end
    local _, y = RoutedAt()
    H.eq(y, 200.0, 'nearest first (200 m)')
    M.update('run-3', 2, {
        kind = 'targets',
        targets = {
            { key = 'a', x = 190.0, y = 0.0, z = 30.0, look = 'fleeing' },
            { key = 'b', x = 0.0, y = 200.0, z = 30.0, look = 'fleeing' },
        },
    })
    _, y = RoutedAt()
    H.eq(y, 200.0, '190 m is not 25 % closer than 200 m: no switch (no GPS flicker)')
    M.update('run-3', 2, {
        kind = 'targets',
        targets = {
            { key = 'a', x = 140.0, y = 0.0, z = 30.0, look = 'fleeing' },
            { key = 'b', x = 0.0, y = 200.0, z = 30.0, look = 'fleeing' },
        },
    })
    local x = RoutedAt()
    H.eq(x, 140.0, '140 m is: the line switches')
    H.eq(#Routed(), 1, 'always one line')
    M.update('run-3', 2, { kind = 'targets', targets = { { key = 'b', x = 0.0, y = 200.0, z = 30.0 } } })
    H.eq(#Live(), 1, 'a target that went is dropped')
    H.ok(NoRemovedRoute(), 'its line off first')
    M.clear()
    H.eq(#Live(), 0, 'cleared')
end

-- ============================================================================
--                   R1: THE BLOCK'S OWN BLIP IS THE POINTER
-- ============================================================================

do
    Reset()
    M.set('run-4', 1, { kind = 'targets', targets = { { key = 77, netId = 77, x = 600.0, y = 0.0, z = 30.0 } } })
    local own = Live()[1]
    H.ok(B(own).route, 'our coord blip routes while the block has none')
    -- the block draws the suspect and hands its blip over
    world.ents[6001] = vec3(500.0, 0.0, 30.0)
    world.streamed[77] = 6001
    local blockBlip = AddBlipForEntity(6001)
    H.ok(M.adopt(77, blockBlip), 'adopt')
    H.eq(B(own).live, false, 'our icon goes: one icon per target')
    H.ok(B(blockBlip).route and #Routed() == 1, 'the line is on the block\'s blip')
    H.eq(B(blockBlip).priority, 12, 'the adopted pointer is raised')
    Tick(2)
    H.eq(#Live(), 1, 'no second icon while it is adopted, even streamed')
    H.ok(M.release(77), 'release')
    H.eq(B(blockBlip).route, false, 'released: its line goes off before the block removes it')
    H.eq(B(blockBlip).live, true, 'the block\'s blip is the block\'s to remove')
    RemoveBlip(blockBlip)
    H.eq(#Live(), 1, 'CP.Markers draws the target again')
    H.ok(B(Live()[1]).route, 'and routes it')
    -- an adopted blip the block removed without a release: our icon comes back at the next check
    local again = AddBlipForEntity(6001)
    M.adopt('77', again)
    RemoveBlip(again)
    Tick()
    H.eq(#Live(), 1, 'a removed adopted blip falls back to our icon')
    -- clear hands every adopted blip back with its line off
    local third = AddBlipForEntity(6001)
    M.adopt(77, third)
    H.ok(B(third).route, 'routed')
    M.clear()
    H.ok(B(third).route == false and B(third).live, 'clear: the adopted blip loses its line, the block keeps it')
    H.eq(M.release(77), false, 'nothing adopted after a clear')
    RemoveBlip(third)
end

-- ============================================================================
--                        AREAS: A CIRCLE AND ITS CENTRE
-- ============================================================================

do
    Reset()
    M.set('run-5', 1, {
        kind = 'area',
        look = 'fightArea',
        coords = { x = 0.0, y = 400.0, z = 30.0 },
        radius = 60.0,
        label = 'Hostiles',
    })
    local circles, centres = Live('radius'), Live('coord')
    H.ok(#circles == 1 and #centres == 1, 'a radius blip and a centre')
    local circle, centre = B(circles[1]), B(centres[1])
    H.ok(circle.radius == 60.0 and circle.alpha == 80 and circle.colour == K.fightArea.colour, 'red, areaAlpha')
    H.ok(centre.sprite == 84 and centre.name == 'Hostiles', 'the skull centre, named')
    H.ok(centre.route and not circle.route, 'the line goes to the centre')
    world.me = vec3(0.0, 350.0, 30.0)
    Tick()
    H.eq(#Routed(), 0, 'inside the circle: no line')
    M.update('run-5', 1,
        { kind = 'area', look = 'fightArea', coords = { x = 0.0, y = 400.0, z = 30.0 }, radius = 30.0 })
    H.eq(circle.live, false, 'a new radius: the circle is redrawn')
    H.eq(#Live('radius'), 1, 'one circle')
    Tick()
    H.eq(#Routed(), 1, 'outside the smaller circle: the line is back')
    -- a block that draws the circle itself hands over its centre: CP.Markers draws neither
    local blockCentre = AddBlipForCoord(0.0, 400.0, 30.0)
    M.adopt('area', blockCentre)
    M.update('run-5', 1, { kind = 'area', key = 'area', coords = { x = 0.0, y = 400.0, z = 30.0 }, radius = 30.0 })
    H.eq(#Live('radius'), 0, 'adopted centre: no circle of ours')
    H.ok(B(blockCentre).route, 'the line on the block\'s centre')
    M.clear()
    RemoveBlip(blockCentre)
    H.eq(#Live(), 0, 'cleared')
end

-- ============================================================================
--                        R9: RADIO SILENCE, THREE MODES
-- ============================================================================

do
    Reset()
    local silent = { radioSilence = true }
    H.eq(M.hidden(silent, 'route'), true, '\'area\': no line')
    H.eq(M.hidden(silent, 'fightArea'), false, '\'area\': the circle shows')
    H.eq(M.hidden(silent, 'objective'), false, '\'area\': a single point shows')
    H.eq(M.hidden(silent, 'fleeing'), true, '\'area\': no blips on people')
    H.eq(M.hidden(silent, 'vehicle'), true, '\'area\': no blips on cars')
    H.eq(M.hidden({ radioSilence = false }, 'route'), false, 'no Radio Silence: nothing hidden')
    M.set('run-6', 1, { kind = 'point', coords = { x = 500.0, y = 0.0, z = 30.0 } }, silent)
    H.ok(#Live() == 1 and #Routed() == 0, '\'area\': the point, no line')
    M.set('run-6', 2, { kind = 'targets', targets = { { key = 1, x = 500.0, y = 0.0, z = 30.0, look = 'fleeing' } } },
        silent)
    H.eq(#Live(), 0, '\'area\': a moving target shows nothing (radioSilenceLastKnown = 0)')

    -- the optional last-known circle, moved only every radioSilenceLastKnown seconds
    Config.Markers.radioSilenceLastKnown = 10
    Tick()
    local known = Live('radius')
    H.eq(#known, 1, 'a last-known circle')
    H.ok(B(known[1]).radius == 200.0 and B(known[1]).name == 'markers.last_known', '200 m, named')
    M.update('run-6', 2,
        { kind = 'targets', targets = { { key = 1, x = 650.0, y = 0.0, z = 30.0, look = 'fleeing' } } })
    H.eq(B(known[1]).x, 500.0, 'not moved before 10 s')
    Tick(10)
    H.eq(B(known[1]).x, 650.0, 'moved after 10 s')
    H.eq(#Routed(), 0, 'never a line')
    Config.Markers.radioSilenceLastKnown = 0
    Tick()
    H.eq(#Live(), 0, 'off again: the circle goes')

    Config.Markers.radioSilence = 'none'
    M.set('run-6', 3, { kind = 'point', coords = { x = 500.0, y = 0.0, z = 30.0 } }, silent)
    H.eq(#Live(), 0, '\'none\': no objective blip (as before)')
    H.eq(M.hidden(silent, 'start'), false, '\'none\': the start still shows')
    H.eq(M.hidden(silent, 'prisonerVan'), false, '\'none\': service vehicles still show')
    Config.Markers.radioSilence = 'full'
    Tick()
    H.ok(#Live() == 1 and #Routed() == 1, '\'full\': everything, the line too')
    M.clear()
end

-- ============================================================================
--                      SWITCHES, SERVICE VEHICLES, STYLE
-- ============================================================================

do
    Reset()
    Config.Markers.enabled = false
    M.set('run-7', 1, { kind = 'point', coords = { x = 500.0, y = 0.0, z = 30.0 } })
    H.eq(#Live(), 0, 'enabled = false: no pointer')
    Config.Markers.enabled = true
    Tick()
    H.eq(#Live(), 1, 'switched on mid-objective: it shows at the next check')
    Config.Markers.flashSeconds = 0
    M.set('run-7', 2, { kind = 'point', coords = { x = 510.0, y = 0.0, z = 30.0 } })
    H.eq(B(Live()[1]).flashes, false, 'flashSeconds = 0: no flash')
    M.clear()

    -- a prisoner van coming to the officer: shown, never routed, in every Radio Silence mode
    M.service('van-1', { netId = 300, coords = { x = 50.0, y = 50.0, z = 30.0 }, kind = 'prisonerVan' })
    local van = B(Live()[1])
    H.ok(van.sprite == 285 and van.colour == 3 and van.name == 'markers.prisoner_van', 'the van: cell bars, blue')
    H.eq(#Routed(), 0, 'never routed')
    world.ents[7001] = vec3(40.0, 40.0, 30.0)
    world.streamed[300] = 7001
    Tick()
    H.eq(B(Live()[1]).kind, 'entity', 'on the van once streamed')
    Config.Markers.serviceVehicles = false
    Tick()
    H.eq(#Live(), 0, 'serviceVehicles = false: no van blip')
    Config.Markers.serviceVehicles = true
    Tick()
    H.eq(#Live(), 1, 'back on')
    M.service('van-1', nil)
    H.eq(#Live(), 0, 'removed')

    local blip = AddBlipForCoord(1.0, 2.0, 3.0)
    H.ok(M.style(blip, 'point', 'Point 3', { number = 3, variant = 'followUp' }), 'style')
    local b = B(blip)
    H.ok(b.sprite == 1 and b.number == 3 and b.colour == 17 and b.name == 'Point 3', 'numbered, follow-up orange')
    H.ok(b.shortRange == false and b.category == 2, 'R5 on every objective blip')
    RemoveBlip(blip)
end

-- ============================================================================
--                     THE HOOKS IN modules/runs/client.lua
-- ============================================================================
-- Start, marker, stop, end.

do
    Reset()
    local started = 0
    CP.Route = {
        current = function() return world.route end,
        begin = function() return true end,
        stop = function() end,
    }
    CP.Tablet = { hud = function() end, registerClientAction = function() end, notify = function() end }
    CP.Blocks.register('marker_probe', {
        start = function() started = started + 1 end,
        stop = function() end,
    })
    _G.GetVehiclePedIsIn = function() return 0 end
    _G.IsPedArmed = function() return false end
    _G.GetStreetNameAtCoord = function() return 0 end
    _G.GetNameOfZone = function() return '' end
    H.load('modules/runs/client.lua')
    local function Fire(name, ...)
        for _, fn in ipairs(H.handlers[CP.e(name)] or {}) do fn(...) end
    end
    local mission = {
        id = 'probe',
        label = 'Probe',
        objectives = { { block = 'marker_probe' }, { block = 'marker_probe' } },
    }

    -- the start circle follows Config.Markers.startCircleMin and areaAlpha
    Config.Markers.startCircleMin = 100.0
    Fire('client:start', 'run-8', {
        missionId = 'probe',
        mission = mission,
        host = 7,
        start = { coords = { x = 10.0, y = 10.0, z = 30.0 }, radius = 150.0 },
    })
    local circles = Live('radius')
    H.eq(#circles, 1, 'a 150 m start is a circle with startCircleMin = 100')
    H.eq(B(circles[1]).alpha, 80, 'in areaAlpha')
    Fire('client:inProgress', 'run-8', { objectives = mission.objectives })
    Fire('client:objective', 'run-8', 1,
        { action = 'start', marker = { kind = 'point', coords = { x = 400.0, y = 0.0, z = 30.0 }, label = 'Go' } })
    H.eq(started, 1, 'the block started')
    H.eq(B(circles[1]).live, false, 'the start circle went at the objective start')
    local live = Live()
    H.ok(#live == 1 and B(live[1]).name == 'Go', 'client:objective start sets the pointer')
    H.eq(#Routed(), 1, 'routed (the officer arrived: no CP.Route)')
    Fire('client:marker', 'run-8', 1, { kind = 'point', coords = { x = 420.0, y = 0.0, z = 30.0 }, label = 'Go' })
    H.eq(B(live[1]).x, 420.0, 'client:marker moves it')
    Fire('client:marker', 'run-8', 2, { kind = 'point', coords = { x = 0.0, y = 0.0, z = 30.0 } })
    H.eq(B(live[1]).x, 420.0, 'a marker for another objective is ignored')
    Fire('client:marker', 'run-x', 1, { kind = 'point', coords = { x = 0.0, y = 0.0, z = 30.0 } })
    H.eq(B(live[1]).x, 420.0, 'and one for another run')
    Fire('client:objective', 'run-8', 1, { action = 'stop' })
    H.eq(#Live(), 0, 'client:objective stop clears it')
    H.ok(NoRemovedRoute(), 'line off first')

    Fire('client:objective', 'run-8', 2,
        { action = 'start', marker = { kind = 'targets', targets = { { key = 9, x = 300.0, y = 0.0, z = 30.0 } } } })
    H.eq(#Live(), 1, 'objective 2 has its pointer')
    Fire('client:runEnded', 'run-8', 'completed', 'completed')
    H.eq(#Live(), 0, 'client:runEnded clears it')
    H.ok(NoRemovedRoute(), 'line off first')
    local checks = world.netChecks
    Tick(5)
    H.eq(world.netChecks, checks, 'nothing runs after the run ended')

    Config.Markers.startCircleMin = 200.0
    Fire('client:start', 'run-9', {
        missionId = 'probe',
        mission = mission,
        host = 7,
        start = { coords = { x = 10.0, y = 10.0, z = 30.0 }, radius = 150.0 },
    })
    H.eq(#Live('radius'), 0, 'startCircleMin = 200 (shipped): a 150 m start draws no circle')
    Fire('client:inProgress', 'run-9', { objectives = mission.objectives })
    Fire('client:objective', 'run-9', 1,
        { action = 'start', marker = { kind = 'point', coords = { x = 400.0, y = 0.0, z = 30.0 } } })
    H.eq(#Live(), 1, 'run 9 pointer')
    for _, fn in ipairs(H.handlers.onResourceStop or {}) do fn('Crimson-Police') end
    H.eq(#Live(), 0, 'onResourceStop clears it')
    H.ok(NoRemovedRoute(), 'line off first')
end

return H
