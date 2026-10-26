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
-- the tablet as modules/tablet gives it: the HUD patches, the toasts and the client actions registered (PLAN M10)
local TB = { huds = {}, notes = {}, actions = {} }
local TABLET = {
    hud = function(patch) TB.huds[#TB.huds + 1] = patch end,
    notify = function(kind, text) TB.notes[#TB.notes + 1] = { kind = kind, text = text } end,
    registerClientAction = function(name, fn) TB.actions[name] = fn end,
}
CP.Tablet = TABLET
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
    -- a target a block names by its net id but gives no look (it gets 'objective', a single point's look): still a
    -- person or a car, so no blip on it, streamed or not
    world.ents[6101] = vec3(520.0, 0.0, 30.0)
    world.streamed[61] = 6101
    M.set('run-6', 4, { kind = 'targets', targets = { { key = 61, netId = 61, x = 520.0, y = 0.0, z = 30.0 } } },
        silent)
    Tick()
    H.eq(#Live(), 0, '\'area\': a target with a net id and no look gets no entity blip')
    world.streamed[61] = nil
    Tick()
    H.eq(#Live(), 0, '\'area\': nor a blip at the server\'s position once it streams out')
    Config.Markers.radioSilenceLastKnown = 10
    Tick()
    H.eq(#Live('radius'), 1, 'only the last-known circle, when that is on')
    H.eq(#Live(), 1, 'and nothing else')
    Config.Markers.radioSilenceLastKnown = 0
    world.ents[6101] = nil
    M.set('run-6', 2, { kind = 'targets', targets = { { key = 1, x = 500.0, y = 0.0, z = 30.0, look = 'fleeing' } } },
        silent)
    Tick()

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
    H.eq(B(circles[1]).colour, K.start.colour, 'in the colour of kinds.start (yellow, M9)')
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

-- ============================================================================
--    M2: A BLOCK HANDS ITS OWN BLIPS OVER (interact_points, Business Check)
-- ============================================================================
-- The server's pointer names every door still to check by its number; the block's numbered door blips are the
-- pointer, so there is no separate "Objective" blip and the line goes to the officer's nearest door.

do
    Reset()
    _G.DrawMarker = _G.DrawMarker or function() end
    _G.PlaySoundFrontend = _G.PlaySoundFrontend or function() end
    H.exportsMock.ox_target = {
        addSphereZone = function() return 1 end,
        removeZone = function() end,
    }
    H.load('blocks/interact_points/client.lua')
    local IPc = CP.Blocks.get('interact_points')
    local ctx = {
        runId = 'run-ip',
        index = 1,
        obj = { label = 'Check the doors', target = { label = 'Check door' }, progress = { duration = 5000 } },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    local doors = { { 0.0, 500.0 }, { 0.0, 200.0 }, { 0.0, 900.0 } }
    local function Snapshot(statuses)
        local pts = {}
        for n, d in ipairs(doors) do
            pts[n] = { coords = { x = d[1], y = d[2], z = 30.0 }, label = 'Shop ' .. n, status = statuses[n] }
        end
        return { kind = 'state', points = pts, total = #pts, done = 0 }
    end
    local function Pointer(statuses)
        local targets = {}
        for n, d in ipairs(doors) do
            if statuses[n] == 'pending' then
                targets[#targets + 1] = {
                    key = n,
                    x = d[1],
                    y = d[2],
                    z = 30.0,
                    look = 'point',
                    number = n,
                    label = 'Shop ' .. n,
                }
            end
        end
        return { kind = 'targets', targets = targets }
    end
    local all = { 'pending', 'pending', 'pending' }
    IPc.start(ctx)
    -- the start message's pointer comes first (CP.Markers' own pins for a moment), the block's snapshot right after
    M.set('run-ip', 1, Pointer(all), ctx)
    local ownPins = Live('coord')
    H.eq(#ownPins, 3, 'before the block draws: CP.Markers shows the doors itself')
    IPc.update(ctx, Snapshot(all))
    local live = Live()
    H.eq(#live, 3, 'one icon per door: the block\'s blips, no separate Objective blip')
    for _, id in ipairs(ownPins) do H.eq(B(id).live, false, 'CP.Markers\' own pin ' .. id .. ' gave way') end
    local numbers = {}
    for _, id in ipairs(live) do
        local b = B(id)
        numbers[#numbers + 1] = b.number
        H.ok(b.sprite == K.point.sprite and b.colour == K.point.colour and b.shortRange == false,
            'a door blip in kinds.point, never short range')
    end
    table.sort(numbers)
    H.eq(table.concat(numbers, ','), '1,2,3', 'numbered doors')
    local routed = Routed()
    H.ok(#routed == 1 and B(routed[1]).number == 2, 'the GPS line goes to the nearest door\'s own blip (door 2)')
    H.ok(B(routed[1]).flashes == true and (B(routed[1]).flashMs or 0) > 0, 'the door blip carries the pointer\'s flash')
    H.eq(B(routed[1]).priority, 12, 'raised above the detail blips')

    -- door 2 checked: the block's next snapshot, then the server's next pointer (the tick)
    local after = { 'pending', 'log', 'pending' }
    IPc.update(ctx, Snapshot(after))
    M.update('run-ip', 1, Pointer(after), ctx)
    Tick()
    live = Live()
    H.eq(#live, 2, 'two doors left, two icons')
    routed = Routed()
    H.ok(#routed == 1 and B(routed[1]).number == 1, 'the line moves to the next nearest door (door 1)')
    H.ok(NoRemovedRoute(), 'every door blip lost its line before the block removed it')

    -- release with a blip only gives back that blip
    local other = AddBlipForCoord(0.0, 0.0, 30.0)
    H.eq(M.release(1, other), false, 'release(key, blip): not the blip handed over for that key')
    H.ok(B(routed[1]).route, 'the handed-over blip keeps its line')
    RemoveBlip(other)

    -- the objective stops: pointer cleared first, then the block removes its blips
    M.clear('run-ip', 1)
    IPc.stop(ctx)
    H.eq(#Live(), 0, 'stop: nothing left on the map')
    H.ok(NoRemovedRoute(), 'line off first')
end

-- ============================================================================
-- M6: POINT OBJECTIVES (interact_points, skill_check, process_scene, checkpoint_route)
-- ============================================================================
-- The blocks' own blips are the pointer (R1); a snapshot keeps every blip that still shows the same thing, so the
-- GPS line and the flash on it survive (R8); checkpoint_route keeps its own line, in routeColour, never while this
-- officer still drives to the start or has a waypoint of his own (R2).

-- the blip operations logged since index from
local function Ops(from)
    local n = { add = 0, remove = 0, route = 0 }
    for i = from + 1, #BL.log do
        local e = BL.log[i]
        n[e.op] = (n[e.op] or 0) + 1
    end
    return n
end
local function ByNumber(n)
    for _, id in ipairs(Live()) do if B(id).number == n then return id end end
    return nil
end
local function Quiet(ops) return ops.add == 0 and ops.remove == 0 and ops.route == 0 end
local function OpsText(ops) return ('%d added, %d removed, %d line changes'):format(ops.add, ops.remove, ops.route) end
_G.DrawMarker = _G.DrawMarker or function() end
_G.PlaySoundFrontend = _G.PlaySoundFrontend or function() end
_G.GetVehiclePedIsIn = _G.GetVehiclePedIsIn or function() return 0 end

-- interact_points (Business Check): an unchanged snapshot redraws nothing; a follow-up is restyled in place
do
    Reset()
    H.exportsMock.ox_target = {
        addSphereZone = function() return 1 end,
        removeZone = function() end,
    }
    local IPc = CP.Blocks.get('interact_points')
    local ctx = {
        runId = 'run-ip6',
        index = 1,
        obj = { label = 'Check the doors', target = { label = 'Check door' }, progress = { duration = 5000 } },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    local doors = { { 0.0, 500.0 }, { 0.0, 200.0 }, { 0.0, 900.0 } }
    local function Snapshot(statuses, extra)
        local pts = {}
        for n, d in ipairs(doors) do
            pts[n] = { coords = { x = d[1], y = d[2], z = 30.0 }, label = 'Shop ' .. n, status = statuses[n] }
        end
        local snap = { kind = 'state', points = pts, total = #pts, done = 0 }
        for k, v in pairs(extra or {}) do snap[k] = v end
        return snap
    end
    local function Pointer(statuses)
        local targets = {}
        for n, d in ipairs(doors) do
            if statuses[n] == 'pending' or statuses[n] == 'followup' then
                targets[#targets + 1] = {
                    key = n,
                    x = d[1],
                    y = d[2],
                    z = 30.0,
                    look = 'point',
                    number = n,
                    label = 'Shop ' .. n,
                    variant = statuses[n] == 'followup' and 'followUp' or nil,
                }
            end
        end
        return { kind = 'targets', targets = targets }
    end
    local all = { 'pending', 'pending', 'pending' }
    IPc.start(ctx)
    M.set('run-ip6', 1, Pointer(all), ctx)
    IPc.update(ctx, Snapshot(all))
    local d1, d2, d3 = ByNumber(1), ByNumber(2), ByNumber(3)
    H.ok(#Live() == 3 and d1 and d2 and d3, 'ip: three numbered door blips, no second icon')
    H.ok(B(d2).route and #Routed() == 1, 'ip: the line on the nearest door (door 2)')
    H.ok(B(d2).flashes == true, 'ip: with the pointer\'s flash')

    -- the same doors again (only the counts changed): nothing redrawn, the line and the flash stay
    local mark = #BL.log
    IPc.update(ctx, Snapshot(all, { together = { count = 2, window = 6 } }))
    M.update('run-ip6', 1, Pointer(all), ctx)
    Tick()
    local ops = Ops(mark)
    H.ok(Quiet(ops), 'ip: an unchanged snapshot keeps every blip (' .. OpsText(ops) .. ')')
    H.ok(B(d1).live and B(d2).live and B(d3).live, 'ip: the same three blips')
    H.ok(B(d2).route and B(d2).flashes == true, 'ip: door 2 keeps the line and the flash')

    -- door 2 was found open: it needs securing, restyled in place (orange), the line stays on it
    local fu = { 'pending', 'followup', 'pending' }
    mark = #BL.log
    IPc.update(ctx, Snapshot(fu))
    M.update('run-ip6', 1, Pointer(fu), ctx)
    Tick()
    ops = Ops(mark)
    H.ok(Quiet(ops), 'ip: a follow-up restyles the door\'s own blip (' .. OpsText(ops) .. ')')
    H.eq(B(d2).colour, K.point.followUpColour, 'ip: door 2 orange (kinds.point.followUpColour)')
    H.ok(B(d2).live and B(d2).route, 'ip: and keeps the line')

    -- door 2 secured: only its blip goes, its line off first, and the line moves on to door 1
    local done = { 'pending', 'done', 'pending' }
    M.update('run-ip6', 1, Pointer(done), ctx)
    IPc.update(ctx, Snapshot(done))
    Tick()
    H.eq(B(d2).live, false, 'ip: the secured door\'s blip went')
    H.ok(B(d1).live and B(d3).live and #Live() == 2, 'ip: doors 1 and 3 keep their blips')
    H.ok(B(d1).route and #Routed() == 1, 'ip: the line moves on to door 1')
    H.ok(NoRemovedRoute(), 'ip: every removed blip lost its line first')
    M.clear('run-ip6', 1)
    IPc.stop(ctx)
    H.eq(#Live(), 0, 'ip: stop leaves nothing')
end

-- interact_points hidden search (Bomb Disposal, the raids' stashes): a yellow circle and pin, kept while searching
do
    Reset()
    local IPc = CP.Blocks.get('interact_points')
    local ctx = {
        runId = 'run-ip6h',
        index = 1,
        obj = { hidden = { count = 2 }, target = { label = 'Search' } },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    local spots = { { 0.0, 600.0 }, { 40.0, 600.0 }, { 0.0, 640.0 } }
    local function Snapshot(found)
        local pts = {}
        for n, d in ipairs(spots) do
            pts[n] = { coords = { x = d[1], y = d[2], z = 30.0 }, status = n <= found and 'done' or 'pending' }
        end
        return { kind = 'state', hidden = true, points = pts, found = found, total = 2 }
    end
    IPc.start(ctx)
    M.set('run-ip6h', 1, {
        kind = 'area',
        key = 'area',
        look = 'searchArea',
        coords = { x = 40.0 / 3, y = 1840.0 / 3, z = 30.0 },
        radius = 40.0,
        label = 'Search area',
    }, ctx)
    IPc.update(ctx, Snapshot(0))
    local circles, pins = Live('radius'), Live('coord')
    H.ok(#circles == 1 and #pins == 1, 'ip hidden: one circle and one centre, the block\'s (no second icon or circle)')
    local circle, centre = circles[1], pins[1]
    H.ok(B(circle).colour == K.searchArea.colour and B(circle).alpha == Config.Markers.areaAlpha,
        'ip hidden: the circle yellow at areaAlpha (it was red at 90)')
    H.ok(
        B(centre).sprite == K.searchArea.sprite and B(centre).colour == K.searchArea.colour
            and B(centre).scale == K.searchArea.scale and B(centre).shortRange == false,
        'ip hidden: the centre a yellow pin, kinds.searchArea (it was a red dot)'
    )
    H.ok(B(centre).route and #Routed() == 1, 'ip hidden: the line on the centre')
    local mark = #BL.log
    IPc.update(ctx, Snapshot(1))
    Tick()
    local ops = Ops(mark)
    H.ok(Quiet(ops), 'ip hidden: one device found, the search goes on: nothing redrawn (' .. OpsText(ops) .. ')')
    H.ok(B(centre).route and B(circle).live, 'ip hidden: the same circle and centre, the line stays')
    M.update('run-ip6h', 1, nil, ctx)
    IPc.update(ctx, Snapshot(2))
    H.eq(#Live(), 0, 'ip hidden: every device found: circle and centre go')
    H.ok(NoRemovedRoute(), 'ip hidden: the line off first')
    IPc.stop(ctx)
end

-- skill_check (Bomb Disposal, Drug Lab Raid "Shut down the lab"): numbered yellow devices, the set-back one orange
do
    Reset()
    H.load('blocks/skill_check/client.lua')
    local SCc = CP.Blocks.get('skill_check')
    local ctx = {
        runId = 'run-sc6',
        index = 2,
        obj = { checks = { 'easy' } },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    local spots = { 300.0, 700.0 }
    local function Snap(s1, s2, worker)
        local targets = {}
        for i, s in ipairs({ s1, s2 }) do
            targets[i] = {
                coords = { x = 0.0, y = spots[i], z = 30.0 },
                netId = 800 + i,
                status = s,
                next = 1,
                streak = 0,
            }
        end
        targets[1].worker = worker
        return { kind = 'state', checks = 1, targets = targets }
    end
    local function Pointer(s1, s2)
        local targets = {}
        for i, s in ipairs({ s1, s2 }) do
            if s == 'armed' or s == 'setback' or s == 'cooldown' then
                targets[#targets + 1] = {
                    key = 'd' .. i,
                    x = 0.0,
                    y = spots[i],
                    z = 30.0,
                    look = 'device',
                    number = i,
                    variant = s == 'setback' and 'setback' or nil,
                    label = 'Device ' .. i,
                }
            end
        end
        return { kind = 'targets', targets = targets }
    end
    SCc.prepare(ctx)
    SCc.start(ctx)
    M.set('run-sc6', 2, Pointer('armed', 'armed'), ctx)
    SCc.update(ctx, Snap('armed', 'armed'))
    local d1, d2 = ByNumber(1), ByNumber(2)
    H.ok(#Live() == 2 and d1 and d2, 'sc: one numbered blip per device, the block\'s (no CP.Markers pin)')
    H.ok(
        B(d1).sprite == K.device.sprite and B(d1).colour == K.device.colour and B(d1).scale == K.device.scale
            and B(d1).shortRange == false and B(d1).category == 2,
        'sc: kinds.device (yellow; it was red), never short range'
    )
    H.ok(B(d1).route and #Routed() == 1, 'sc: the line on the nearest device\'s own blip')
    H.ok(B(d1).flashes == true, 'sc: with the pointer\'s flash')

    -- a partner works device 1 (its worker changed, nothing else): nothing redrawn
    local mark = #BL.log
    SCc.update(ctx, Snap('armed', 'armed', 9))
    M.update('run-sc6', 2, Pointer('armed', 'armed'), ctx)
    Tick()
    local ops = Ops(mark)
    H.ok(Quiet(ops), 'sc: an unchanged snapshot keeps every blip (' .. OpsText(ops) .. ')')
    H.ok(B(d1).route and B(d1).flashes == true, 'sc: device 1 keeps the line and the flash')

    -- set back (Ventilate): the same blip, orange, the line stays; then waiting to be tried again: yellow again
    mark = #BL.log
    SCc.update(ctx, Snap('setback', 'armed'))
    M.update('run-sc6', 2, Pointer('setback', 'armed'), ctx)
    Tick()
    ops = Ops(mark)
    H.ok(Quiet(ops), 'sc: a setback restyles the device\'s own blip (' .. OpsText(ops) .. ')')
    H.ok(B(d1).live and B(d1).colour == K.device.setbackColour and B(d1).route,
        'sc: set back = orange (kinds.device.setbackColour; it had no blip), keeps the line')
    SCc.update(ctx, Snap('cooldown', 'armed'))
    M.update('run-sc6', 2, Pointer('cooldown', 'armed'), ctx)
    Tick()
    H.ok(B(d1).live and B(d1).colour == K.device.colour and B(d1).route,
        'sc: waiting to be tried again: the same blip, yellow, keeps the line')

    -- device 1 shut down: its blip goes, its line off first, the line moves to device 2
    M.update('run-sc6', 2, Pointer('defused', 'armed'), ctx)
    SCc.update(ctx, Snap('defused', 'armed'))
    Tick()
    H.eq(B(d1).live, false, 'sc: a defused device\'s blip goes')
    H.ok(B(d2).live and B(d2).route and #Live() == 1, 'sc: the line moves to device 2')
    H.ok(NoRemovedRoute(), 'sc: every removed blip lost its line first')
    M.clear('run-sc6', 2)
    SCc.stop(ctx)
    H.eq(#Live(), 0, 'sc: stop leaves nothing')
end

-- process_scene (Warrant Service, the raids, Gang Shootout): the scene is a yellow map pin with the line
do
    Reset()
    H.exportsMock.ox_target = {
        addSphereZone = function() return 1 end,
        removeZone = function() end,
        addLocalEntity = function() end,
        removeLocalEntity = function() end,
    }
    H.load('blocks/process_scene/client.lua')
    local PSc = CP.Blocks.get('process_scene')
    local scene = { x = 0.0, y = 400.0, z = 30.0 }
    local pointer = { kind = 'point', key = 'scene', look = 'scene', coords = scene, label = 'Scene' }
    local function Snap() return { bodies = {}, released = false, scene = scene, coroner = false } end
    local ctx = { runId = 'run-ps6', index = 3, obj = {}, state = {}, report = function() end }
    PSc.prepare(ctx)
    PSc.start(ctx)
    M.set('run-ps6', 3, pointer, ctx)
    H.eq(#Live(), 1, 'ps: CP.Markers\' pin until the block draws its own')
    PSc.update(ctx, Snap())
    local live = Live()
    H.eq(#live, 1, 'ps: one icon, the block\'s scene blip')
    local b = B(live[1])
    H.ok(
        b.sprite == K.scene.sprite and b.colour == K.scene.colour and b.scale == K.scene.scale and b.shortRange == false
            and b.category == 2,
        'ps: a yellow map pin (kinds.scene), not 310 white (the skull and crossbones)'
    )
    H.ok(b.route and b.flashes == true, 'ps: the line and the flash on it')
    local mark = #BL.log
    PSc.update(ctx, Snap())
    Tick()
    local ops = Ops(mark)
    H.ok(Quiet(ops), 'ps: the next snapshot redraws nothing (' .. OpsText(ops) .. ')')
    M.clear('run-ps6', 3)
    PSc.stop(ctx)
    H.eq(#Live(), 0, 'ps: stop leaves nothing')
    H.ok(NoRemovedRoute(), 'ps: the line off first')

    -- Radio Silence ('area', shipped): the block draws none, CP.Markers shows the scene alone, without a line
    local rctx = { runId = 'run-ps6r', index = 3, obj = {}, state = {}, report = function() end, radioSilence = true }
    PSc.prepare(rctx)
    PSc.start(rctx)
    M.set('run-ps6r', 3, pointer, rctx)
    PSc.update(rctx, Snap())
    Tick()
    H.ok(#Live() == 1 and B(Live()[1]).sprite == K.scene.sprite and #Routed() == 0,
        'ps Radio Silence: the scene pin, no line')
    M.clear()
    PSc.stop(rctx)
end

-- checkpoint_route (Beat Patrol, EVOC): numbered yellow checkpoints, its own line in routeColour, never two lines
do
    Reset()
    _G.GetStreetNameFromHashKey = _G.GetStreetNameFromHashKey or function() return 'Vespucci Blvd' end
    _G.GetLabelText = _G.GetLabelText or function() return 'Downtown' end
    _G.GetStreetNameAtCoord = _G.GetStreetNameAtCoord or function() return 0 end
    _G.GetNameOfZone = _G.GetNameOfZone or function() return '' end
    local asks = 0
    local waypointActive = _G.IsWaypointActive
    _G.IsWaypointActive = function()
        asks = asks + 1
        return world.waypoint
    end
    H.load('blocks/checkpoint_route/client.lua')
    local CRc = CP.Blocks.get('checkpoint_route')
    local ys = { 600.0, 1200.0, 1800.0 }
    local function Snap(current, finished)
        local pts = {}
        for i, y in ipairs(ys) do pts[i] = { x = 0.0, y = y, z = 30.0 } end
        return {
            kind = 'state',
            points = pts,
            current = current,
            total = #pts,
            finished = finished == true,
            track = {},
            course = {},
        }
    end
    local function Pointer(n)
        return {
            kind = 'point',
            key = 'cp' .. n,
            number = n,
            look = 'checkpoint',
            coords = { x = 0.0, y = ys[n], z = 30.0 },
            label = 'Checkpoint ' .. n,
            route = 'block',
        }
    end
    local ctx = {
        runId = 'run-cr6',
        index = 1,
        obj = { radius = 10.0 },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }

    -- a late partner: still driving to the start (CP.Route on, not arrived), the action already at checkpoint 1
    world.route = { runId = 'run-cr6', arrived = false, routeOn = true }
    CRc.prepare(ctx)
    CRc.start(ctx)
    M.set('run-cr6', 1, Pointer(1), ctx)
    CRc.update(ctx, Snap(1))
    local c1, c2 = ByNumber(1), ByNumber(2)
    H.ok(#Live() == 2 and c1 and c2, 'cr: the current and the next checkpoint, numbered: one icon each')
    H.ok(
        B(c1).sprite == K.checkpoint.sprite and B(c1).colour == K.checkpoint.colour
            and B(c1).scale == K.checkpoint.scale and B(c1).shortRange == false,
        'cr: checkpoint 1 in kinds.checkpoint (yellow; it was red 0.9)'
    )
    H.ok(B(c2).colour == K.checkpoint.colour and B(c2).scale == K.checkpoint.nextScale, 'cr: the next one smaller')
    H.eq(#Routed(), 0,
        'cr late partner: no checkpoint line while he drives to the start (the start keeps the only one)')
    Tick(3)
    H.eq(#Routed(), 0, 'cr late partner: still none')

    -- he arrives at the start: the line comes on, on checkpoint 1's own blip, in routeColour
    world.route.arrived = true
    Tick(2)
    local r = Routed()
    H.ok(#r == 1 and r[1] == c1, 'cr: arrived: the line on checkpoint 1\'s own blip')
    H.eq(B(c1).routeColour, Config.Markers.routeColour, 'cr: in Config.Markers.routeColour (yellow; it was red)')
    world.waypoint = true
    Tick(2)
    H.eq(#Routed(), 0, 'cr: his own waypoint: the checkpoint line goes off')
    world.waypoint = false
    Tick(2)
    H.ok(B(c1).route, 'cr: waypoint gone: back on')

    -- at frame rate near the checkpoint: the rule is asked once a second, the line natives only on a change
    world.me = vec3(0.0, 520.0, 30.0)
    local mark = #BL.log
    asks = 0
    for _ = 1, 125 do H.step(16) end
    H.eq(Ops(mark).route, 0, 'cr: no SetBlipRoute while nothing changes')
    H.ok(asks >= 1 and asks <= 3, ('cr: the line rule asked %d times in 2 s of frames (once a second)'):format(asks))
    Config.Markers.routeColour = 3
    Tick(2)
    H.eq(B(c1).routeColour, 3, 'cr: a new routeColour reaches the checkpoint line')

    -- checkpoint 1 cleared: checkpoint 2 takes the line, full size; nothing removed with its line on
    world.me = vec3(0.0, 0.0, 30.0)
    M.update('run-cr6', 1, Pointer(2), ctx)
    CRc.update(ctx, Snap(2))
    local n2 = ByNumber(2)
    H.ok(B(c1).live == false and B(c2).live == false and #Live() == 2, 'cr: checkpoints 2 and 3 now')
    H.ok(B(n2).route and B(n2).scale == K.checkpoint.scale and #Routed() == 1, 'cr: the line on checkpoint 2')
    M.update('run-cr6', 1, nil, ctx)
    CRc.update(ctx, Snap(nil, true))
    H.eq(#Live(), 0, 'cr: finished: nothing left')
    H.ok(NoRemovedRoute(), 'cr: every removed blip lost its line first')
    CRc.stop(ctx)

    -- Radio Silence ('area', shipped): the block draws none, CP.Markers shows the current checkpoint without a line
    world.route = nil
    local rctx = {
        runId = 'run-cr6r',
        index = 1,
        obj = { radius = 10.0 },
        state = {},
        report = function() end,
        hudDetail = function() end,
        radioSilence = true,
    }
    CRc.prepare(rctx)
    CRc.start(rctx)
    M.set('run-cr6r', 1, Pointer(1), rctx)
    CRc.update(rctx, Snap(1))
    Tick(2)
    local only = Live()
    H.ok(#only == 1 and B(only[1]).number == 1 and B(only[1]).colour == K.checkpoint.colour and #Routed() == 0,
        'cr Radio Silence: checkpoint 1 alone, numbered, no line')
    M.clear()
    CRc.stop(rctx)
    _G.IsWaypointActive = waypointActive
end

-- ============================================================================
--       M8: RADIO SILENCE IN THE BLOCKS, BY Config.Markers.radioSilence
-- ============================================================================
-- Every block asks CP.Markers.hidden(ctx, kind) before it draws a blip or a line: 'area' (shipped) keeps the
-- objective's circle or its one point without a line (CP.Markers shows only the officer's nearest of several points
-- or devices itself), 'full' everything as without Radio Silence, 'none' nothing (before M8 every block drew nothing).

do
    Reset()
    local silent = { radioSilence = true }
    -- a block's own blips under 'area' (shipped)
    for _, kind in ipairs({ 'checkpoint', 'searchArea', 'fightArea', 'destination', 'safePoint', 'scene', 'objective' }) do
        H.eq(M.hidden(silent, kind), false, '\'area\': the block draws its ' .. kind)
    end
    for _, kind in ipairs({
        'point',
        'device',
        'clue',
        'hostile',
        'suspect',
        'fleeing',
        'vehicle',
        'contact',
        'contactVehicle',
        'escort',
        'hostage',
        'route',
    }) do
        H.eq(M.hidden(silent, kind), true, '\'area\': the block draws no ' .. kind)
    end
    H.eq(M.hidden(silent, 'checkpoint', 'next'), true, '\'area\': no second checkpoint')
    H.eq(M.hidden({ radioSilence = false }, 'point'), false, 'no Radio Silence: the block draws its points')
    Config.Markers.radioSilence = 'full'
    for _, kind in ipairs({ 'point', 'device', 'clue', 'hostile', 'fleeing', 'vehicle', 'escort', 'hostage', 'route' }) do
        H.eq(M.hidden(silent, kind), false, '\'full\': the block draws its ' .. kind)
    end
    H.eq(M.hidden(silent, 'checkpoint', 'next'), false, '\'full\': the next checkpoint too')
    Config.Markers.radioSilence = 'none'
    for _, kind in ipairs({ 'checkpoint', 'searchArea', 'safePoint', 'scene', 'objective', 'point' }) do
        H.eq(M.hidden(silent, kind), true, '\'none\': no ' .. kind)
    end
    Config.Markers.radioSilence = 'bogus'
    H.eq(M.hidden(silent, 'point'), true, 'an unknown mode counts as \'area\'')
    H.eq(M.hidden(silent, 'scene'), false, 'an unknown mode counts as \'area\' (the scene shows)')
    Config.Markers.radioSilence = 'area'

    -- CP.Markers itself under 'area': of several points only this officer's nearest, switching at 25 % closer
    local doors = { { 0.0, 500.0 }, { 0.0, 200.0 }, { 0.0, 900.0 } }
    local targets = {}
    for n, d in ipairs(doors) do
        targets[n] = { key = n, x = d[1], y = d[2], z = 30.0, look = 'point', number = n, label = 'Shop ' .. n }
    end
    M.set('run-m8', 1, { kind = 'targets', targets = targets }, silent)
    H.ok(#Live() == 1 and B(Live()[1]).number == 2 and #Routed() == 0, '\'area\': only the nearest door (2), no line')
    world.me = vec3(0.0, 360.0, 30.0) -- door 1 at 140 m, door 2 at 160 m: not 25 % closer
    Tick()
    H.ok(#Live() == 1 and B(Live()[1]).number == 2, '\'area\': no flicker between two doors about as near')
    world.me = vec3(0.0, 850.0, 30.0) -- door 3 at 50 m
    Tick()
    H.ok(#Live() == 1 and B(Live()[1]).number == 3, '\'area\': the nearest door again once it is clearly nearer')
    H.ok(NoRemovedRoute(), '\'area\': never a line')
    Config.Markers.radioSilence = 'full'
    Tick()
    H.ok(#Live() == 3 and #Routed() == 1, '\'full\': every door, the line on the nearest')
    M.clear()
end

-- the blocks per mode: interact_points (Business Check), skill_check (Bomb Disposal), checkpoint_route (Beat Patrol)
do
    local IPc, SCc, CRc =
        CP.Blocks.get('interact_points'), CP.Blocks.get('skill_check'), CP.Blocks.get('checkpoint_route')
    local function Ctx(runId)
        return {
            runId = runId,
            index = 1,
            obj = { label = 'Check the doors', checks = { 'easy' }, radius = 10.0, progress = { duration = 5000 } },
            state = {},
            report = function() end,
            hudDetail = function() end,
            radioSilence = true,
        }
    end
    local ys = { 500.0, 200.0, 900.0 }
    local function DoorSnap()
        local pts = {}
        for n, y in ipairs(ys) do
            pts[n] = { coords = { x = 0.0, y = y, z = 30.0 }, label = 'Shop ' .. n, status = 'pending' }
        end
        return { kind = 'state', points = pts, total = #pts, done = 0 }
    end
    local function DevSnap()
        local t = {}
        for i, y in ipairs(ys) do
            t[i] = { coords = { x = 0.0, y = y, z = 30.0 }, netId = 900 + i, status = 'armed', next = 1, streak = 0 }
        end
        return { kind = 'state', checks = 1, targets = t }
    end
    local function Pointer(prefix, look)
        local t = {}
        for n, y in ipairs(ys) do
            t[n] = { key = prefix .. n, x = 0.0, y = y, z = 30.0, look = look, number = n, label = look .. ' ' .. n }
        end
        return { kind = 'targets', targets = t }
    end
    local function CrSnap()
        local pts = {}
        for i, y in ipairs(ys) do pts[i] = { x = 0.0, y = y, z = 30.0 } end
        return { kind = 'state', points = pts, current = 1, total = #pts, finished = false, track = {}, course = {} }
    end
    local crPointer = {
        kind = 'point',
        key = 'cp1',
        number = 1,
        look = 'checkpoint',
        coords = { x = 0.0, y = 500.0, z = 30.0 },
        label = 'Checkpoint 1',
        route = 'block',
    }

    for _, mode in ipairs({ 'area', 'full', 'none' }) do
        -- doors: the block's own blips first (no pointer yet), then the server's pointer
        Reset()
        Config.Markers.radioSilence = mode
        local ctx = Ctx('run-m8ip-' .. mode)
        IPc.start(ctx)
        M.set(ctx.runId, 1, nil, ctx)
        IPc.update(ctx, DoorSnap())
        local own = #Live()
        M.update(ctx.runId, 1, Pointer('', 'point'), ctx)
        Tick()
        if mode == 'area' then
            H.ok(own == 0 and #Live() == 1 and B(Live()[1]).number == 2 and #Routed() == 0,
                'ip \'area\': no door blips of the block, CP.Markers\' nearest door alone, no line')
        elseif mode == 'full' then
            H.ok(own == 3 and #Live() == 3 and #Routed() == 1,
                'ip \'full\': the block\'s three door blips (none before M8), the line on the nearest')
        else
            H.ok(own == 0 and #Live() == 0, 'ip \'none\': nothing')
        end
        M.clear()
        IPc.stop(ctx)

        -- devices
        Reset()
        Config.Markers.radioSilence = mode
        ctx = Ctx('run-m8sc-' .. mode)
        SCc.prepare(ctx)
        SCc.start(ctx)
        M.set(ctx.runId, 1, nil, ctx)
        SCc.update(ctx, DevSnap())
        own = #Live()
        M.update(ctx.runId, 1, Pointer('d', 'device'), ctx)
        Tick()
        if mode == 'area' then
            H.ok(own == 0 and #Live() == 1 and B(Live()[1]).number == 2 and #Routed() == 0,
                'sc \'area\': no device blips of the block, the nearest device alone, no line')
        elseif mode == 'full' then
            H.ok(own == 3 and #Live() == 3 and #Routed() == 1,
                'sc \'full\': the block\'s three device blips (none before M8), the line on the nearest')
        else
            H.ok(own == 0 and #Live() == 0, 'sc \'none\': nothing')
        end
        M.clear()
        SCc.stop(ctx)

        -- checkpoints: the current one (and the next) are the block's, with its own line
        Reset()
        Config.Markers.radioSilence = mode
        ctx = Ctx('run-m8cr-' .. mode)
        CRc.prepare(ctx)
        CRc.start(ctx)
        M.set(ctx.runId, 1, crPointer, ctx)
        CRc.update(ctx, CrSnap())
        Tick(2)
        if mode == 'area' then
            H.ok(#Live() == 1 and B(Live()[1]).number == 1 and #Routed() == 0,
                'cr \'area\': the current checkpoint alone, no line')
        elseif mode == 'full' then
            H.ok(#Live() == 2 and ByNumber(1) and ByNumber(2) and #Routed() == 1 and B(ByNumber(1)).route,
                'cr \'full\': the current and the next checkpoint, the block\'s line on the current')
        else
            H.eq(#Live(), 0, 'cr \'none\': nothing')
        end
        M.clear()
        CRc.stop(ctx)
        H.ok(NoRemovedRoute(), mode .. ': every line off before its blip went')
    end
    Reset()
end

-- ============================================================================
-- M7: DETAIL BLIPS (a set-back device keeps a flashing blip; service vehicles on every officer's map)
-- ============================================================================
-- The game's flash: SET_BLIP_FLASH_TIMER ends a flash after ms; SetBlipFlashes starts or stops one (a flash started
-- after the timer ran out goes on until it is stopped).

local flashSetter, timerSetter = _G.SetBlipFlashes, _G.SetBlipFlashTimer
_G.SetBlipFlashes = function(id, on)
    local b = BL.all[id]
    if b then b.flashes, b.flashUntil = on == true, nil end
end
_G.SetBlipFlashTimer = function(id, ms)
    local b = BL.all[id]
    if b then b.flashMs, b.flashUntil = ms, GetGameTimer() + ms end
end
local function Flashing(id)
    local b = B(id)
    return b ~= nil and b.flashes == true and (b.flashUntil == nil or GetGameTimer() < b.flashUntil)
end

-- skill_check (Drug Lab Raid objective 5 "Shut down the lab", onFail setback Ventilate): named after the mission's
-- target; set back, the same blip orange, named after the recovery step and flashing until it is fixed
do
    Reset()
    Config.Labels = { ['block.skill_check.blip_setback'] = '{action} {n}' }
    local SCc = CP.Blocks.get('skill_check')
    local lab = { x = 0.0, y = 300.0, z = 30.0 }
    local function Ctx(runId)
        return {
            runId = runId,
            index = 5,
            obj = { checks = { 'easy' }, target = { label = 'Shut down the lab' } },
            state = {},
            report = function() end,
            hudDetail = function() end,
        }
    end
    local function Snap(status)
        return {
            kind = 'state',
            checks = 1,
            targets = { { coords = lab, status = status, next = 1, streak = 0 } },
            setback = { label = 'Ventilate', duration = 10000 },
        }
    end
    local function Pointer(status)
        local setback = status == 'setback'
        return {
            kind = 'targets',
            targets = {
                {
                    key = 'd1',
                    x = lab.x,
                    y = lab.y,
                    z = lab.z,
                    look = 'device',
                    number = 1,
                    variant = setback and 'setback' or nil,
                    label = setback and 'Ventilate 1' or 'Shut down the lab',
                },
            },
        }
    end
    local ctx = Ctx('run-sc7')
    SCc.prepare(ctx)
    SCc.start(ctx)
    M.set('run-sc7', 5, Pointer('armed'), ctx)
    SCc.update(ctx, Snap('armed'))
    local live = Live()
    H.eq(#live, 1, 'sc7: one icon, the lab\'s own blip')
    local id = live[1]
    H.eq(B(id).name, 'Shut down the lab', 'sc7: named after the mission\'s target (it was "Device 1")')
    H.ok(Flashing(id) and B(id).route, 'sc7: the pointer\'s first flash and the line')
    Tick(6)
    H.eq(Flashing(id), false, 'sc7: the first flash is over after flashSeconds')

    -- two misses: set back (Ventilate)
    SCc.update(ctx, Snap('setback'))
    M.update('run-sc7', 5, Pointer('setback'), ctx)
    Tick()
    H.ok(B(id).live and B(id).colour == K.device.setbackColour and B(id).number == 1,
        'sc7: set back: the same numbered blip, orange')
    H.eq(B(id).name, 'Ventilate 1', 'sc7: named after the recovery step (block.skill_check.blip_setback)')
    H.eq(Flashing(id), true, 'sc7: flashing while set back (Config.Markers.setbackFlash)')
    Tick(20)
    H.ok(Flashing(id) and B(id).route, 'sc7: still flashing 20 s later, with the line')

    -- ventilated, waiting to be tried again: yellow, named after the target, the flash stops
    SCc.update(ctx, Snap('cooldown'))
    M.update('run-sc7', 5, Pointer('cooldown'), ctx)
    Tick()
    H.ok(B(id).live and B(id).colour == K.device.colour and B(id).name == 'Shut down the lab',
        'sc7: fixed: the same blip, yellow, the target\'s name again')
    H.eq(Flashing(id), false, 'sc7: the flash stops once it is fixed')
    M.clear('run-sc7', 5)
    SCc.stop(ctx)
    H.eq(#Live(), 0, 'sc7: stop leaves nothing')

    -- a partner whose game first sees the lab while it is set back: it flashes without a timer that would end it
    Reset()
    Config.Labels = { ['block.skill_check.blip_setback'] = '{action} {n}' }
    local pctx = Ctx('run-sc7p')
    SCc.prepare(pctx)
    SCc.start(pctx)
    M.set('run-sc7p', 5, Pointer('setback'), pctx)
    SCc.update(pctx, Snap('setback'))
    live = Live()
    H.eq(#live, 1, 'sc7 partner: one icon')
    H.ok(B(live[1]).flashMs == nil and Flashing(live[1]), 'sc7 partner: flashing, no flash timer on it')
    Tick(10)
    H.eq(Flashing(live[1]), true, 'sc7 partner: still flashing after flashSeconds')
    M.clear('run-sc7p', 5)
    SCc.stop(pctx)

    -- setbackFlash = false: orange while set back, no flash after the first one
    Reset()
    Config.Markers.setbackFlash = false
    local nctx = Ctx('run-sc7n')
    SCc.prepare(nctx)
    SCc.start(nctx)
    M.set('run-sc7n', 5, Pointer('armed'), nctx)
    SCc.update(nctx, Snap('armed'))
    id = Live()[1]
    Tick(6)
    SCc.update(nctx, Snap('setback'))
    M.update('run-sc7n', 5, Pointer('setback'), nctx)
    Tick()
    H.ok(B(id).colour == K.device.setbackColour and not Flashing(id), 'sc7 setbackFlash = false: orange, not flashing')
    M.clear('run-sc7n', 5)
    SCc.stop(nctx)
    Config.Labels = {}
end

-- the prisoner van and the tow truck (modules/custody/client.lua): on every officer's map from the server's
-- client:serviceBlip until it drives off or the run ends; never another run's
do
    Reset()
    H.load('modules/custody/client.lua')
    local savedCurrent = CP.Runs.current
    local run = { id = 'run-sv7', state = 'in_progress' }
    CP.Runs.current = function() return run end
    local function Send(data)
        for _, fn in ipairs(H.handlers['crimson-police:client:serviceBlip'] or {}) do fn(data) end
    end
    local van = { runId = 'run-sv7', id = 1, kind = 'prisonerVan', show = true, netId = 900 }
    van.coords = { x = 150.0, y = 0.0, z = 30.0 }
    Send(van)
    local live = Live()
    H.eq(#live, 1, 'sv7: the van on the map')
    local vb = B(live[1])
    H.ok(vb.sprite == K.prisonerVan.sprite and vb.colour == K.prisonerVan.colour and vb.scale == K.prisonerVan.scale,
        'sv7: kinds.prisonerVan (blue cell bars)')
    H.ok(vb.kind == 'coord' and vb.x == 150.0 and vb.name == 'markers.prisoner_van',
        'sv7: at the server\'s position until it streams in, named Prisoner transport')
    H.eq(#Routed(), 0, 'sv7: never routed')
    world.ents[7101] = vec3(140.0, 0.0, 30.0)
    world.streamed[900] = 7101
    Tick()
    H.ok(#Live() == 1 and B(Live()[1]).kind == 'entity', 'sv7: on the van itself once it streams in')
    Send({ runId = 'run-sv7', id = 2, kind = 'towTruck', show = true, netId = 901, coords = { x = 0.0, y = 200.0 } })
    local tow = nil
    for _, b in ipairs(Live()) do if B(b).sprite == K.towTruck.sprite then tow = b end end
    H.ok(tow and B(tow).colour == K.towTruck.colour and B(tow).name == 'markers.tow_truck', 'sv7: the tow truck too')
    Send({ runId = 'run-other', id = 3, kind = 'prisonerVan', show = true, netId = 902, coords = van.coords })
    Send({ runId = 'run-sv7', id = 4, kind = 'start', show = true, netId = 903, coords = van.coords })
    H.eq(#Live(), 2, 'sv7: another run\'s van and an unknown kind are ignored')
    Send({ runId = 'run-sv7', id = 2, kind = 'towTruck', show = false })
    H.ok(#Live() == 1 and B(tow).live == false, 'sv7: the tow truck drove off: its blip goes')
    -- an objective's stop keeps it; the run's end (CP.Markers.clear() in the run cleanup) takes it off
    M.set('run-sv7', 1, { kind = 'point', coords = { x = 0.0, y = 500.0, z = 30.0 } })
    M.clear('run-sv7', 1)
    H.eq(#Live(), 1, 'sv7: an objective\'s stop keeps the van')
    M.clear()
    H.eq(#Live(), 0, 'sv7: the run\'s end removes it')
    Send(van)
    run.state = 'ended'
    Send({ runId = 'run-sv7', id = 5, kind = 'prisonerVan', show = true, netId = 904, coords = van.coords })
    H.eq(#Live(), 1, 'sv7: nothing new once the run is over')
    M.clear()
    CP.Runs.current = savedCurrent
end

_G.SetBlipFlashes, _G.SetBlipFlashTimer = flashSetter, timerSetter

-- ============================================================================
--         M9: THE MISSION START STAYS A YELLOW PIN FOR THE WHOLE DRIVE
-- ============================================================================
-- modules/route/client.lua: the named Mission start pin (kinds.start) stays from begin until arrival or the end of
-- the run (Config.Markers.startBlip). It carries the GPS line while the route is sampled and, after that, only while
-- the waypoint we set is gone, so the start always keeps a line and never two of ours (BLIPS_FINAL R2).

do
    Reset()
    local WAYPOINT_BLIP = 9000
    local wp = nil                              -- the map waypoint, or nil
    local gps = { found = false, len = 1000.0 } -- GTA's GPS route to the start
    local actions = {}
    local saved = {
        IsWaypointActive = _G.IsWaypointActive,
        DoesBlipExist = _G.DoesBlipExist,
        SetBlipRoute = _G.SetBlipRoute,
    }
    local routeCalls = 0
    _G.SetNewWaypoint = function(x, y) wp = vec3(x, y, 0.0) end
    _G.IsWaypointActive = function() return wp ~= nil end
    _G.GetFirstBlipInfoId = function() return wp and WAYPOINT_BLIP or 0 end
    _G.GetBlipInfoIdCoord = function() return wp end
    _G.SetWaypointOff = function() wp = nil end
    _G.DoesBlipExist = function(id)
        if id == WAYPOINT_BLIP then return wp ~= nil end
        return saved.DoesBlipExist(id)
    end
    _G.SetBlipRoute = function(id, on)
        routeCalls = routeCalls + 1
        saved.SetBlipRoute(id, on)
    end
    _G.GetGpsBlipRouteFound = function() return gps.found end
    _G.GetGpsBlipRouteLength = function() return gps.found and gps.len or 0 end
    _G.GetPosAlongGpsTypeRoute = function(_, d, slot)
        if not gps.found or slot ~= 1 then return false, nil end
        return true, vec3(0.0, d, 30.0)
    end
    CP.Route = nil
    CP.Tablet = {
        hud = function() end,
        notify = function() end,
        registerClientAction = function(name, fn) actions[name] = fn end,
    }
    H.load('modules/route/client.lua')
    H.step(0)
    local CR = CP.Route
    H.ok(type(CR.begin) == 'function' and actions.setGps and actions.recalcRoute, 'm9: CP.Route (client) loaded')
    local START = vec3(0.0, 1000.0, 30.0)
    local MINE = vec3(-800.0, 0.0, 0.0)
    local function Pins()
        local out = {}
        for _, id in ipairs(Live('coord')) do if B(id).name == CP.L('route.blip') then out[#out + 1] = id end end
        return out
    end
    local function Fire(name, ...) TriggerEvent(CP.e(name), ...) end

    -- the drive: a yellow pin from the first moment, the line on it only while the route is sampled
    H.ok(CR.begin('run-m9', START), 'm9: begin')
    local pins = Pins()
    H.eq(#pins, 1, 'm9: the Mission start pin is on the map from the start of the drive')
    local pin = B(pins[1])
    H.ok(pin.sprite == K.start.sprite and pin.colour == K.start.colour and pin.scale == K.start.scale,
        'm9: kinds.start (the yellow map pin, not the red dot)')
    H.ok(pin.x == START.x and pin.y == START.y, 'm9: at the start')
    H.ok(pin.shortRange == false and pin.category == 2, 'm9: at the radar edge, its distance in the legend')
    H.ok(pin.route == true and pin.routeColour == Config.Markers.routeColour,
        'm9: while the route is sampled the pin carries the line (in routeColour)')
    gps.found = true
    H.step(100)
    H.eq(pin.live, true, 'm9: the pin survives the sampling')
    H.eq(pin.route, false, 'm9: after the sampling our waypoint is the only line')
    H.ok(wp and wp.x == START.x and wp.y == START.y, 'm9: our waypoint at the start')
    local calls = routeCalls
    Tick(10)
    H.eq(routeCalls, calls, 'm9: nothing is switched while the waypoint stays the same')

    -- a waypoint of his own: the pin gets the line back, and his waypoint is never touched
    wp = MINE
    Tick(3)
    H.eq(pin.route, true, 'm9: his own waypoint elsewhere: the start pin keeps a GPS line')
    H.ok(wp == MINE, 'm9: his own waypoint stays')
    H.eq(#Routed(), 1, 'm9: one line of ours')
    H.eq(M.canRoute(), false, 'm9: CP.Markers routes nothing while the drive is on')
    wp = nil
    Tick(3)
    H.eq(pin.route, true, 'm9: no waypoint at all: the pin keeps the line')
    H.eq(actions.setGps(), true, 'm9: Set GPS')
    H.eq(pin.route, false, 'm9: Set GPS: our waypoint is the line again, at once')

    -- Recalculate route: the same pin, the line on it while resampling, off again after
    local res
    CreateThread(function() res = { actions.recalcRoute() } end)
    Fire('client:routeRecalc', 'run-m9', true, 1)
    H.step(100)
    H.eq(res and res[1], true, 'm9: recalculated')
    H.eq(#Pins(), 1, 'm9: still one pin')
    H.ok(pin.live and pin.route == false, 'm9: after the resampling our waypoint is the line')

    -- arrival: the pin and its line go
    wp = MINE
    Tick(3)
    H.eq(pin.route, true, 'm9: routed again (his own waypoint)')
    Fire('client:routeStatus', 'run-m9', { status = 'arrived' })
    H.eq(#Pins(), 0, 'm9: arrival removes the pin')
    H.ok(NoRemovedRoute(), 'm9: its line went off first')
    H.ok(wp == MINE, 'm9: his own waypoint stays at arrival')
    calls = routeCalls
    Tick(5)
    H.eq(routeCalls, calls, 'm9: nothing runs after arrival')
    Fire('client:runEnded', 'run-m9')

    -- the end of the run while still driving: the pin and its line go
    BL.log = {}
    wp = nil
    H.ok(CR.begin('run-m9b', START), 'm9b: begin')
    H.step(100)
    H.eq(#Pins(), 1, 'm9b: the pin')
    wp = MINE
    Tick(3)
    H.eq(#Routed(), 1, 'm9b: routed')
    Fire('client:runEnded', 'run-m9b')
    H.eq(#Pins(), 0, 'm9b: the run end removes the pin')
    H.ok(NoRemovedRoute(), 'm9b: its line went off first')

    -- Config.Markers.startBlip = false: the pin only while the route is sampled (before M9)
    Config.Markers.startBlip = false
    wp, gps.found = nil, false
    H.ok(CR.begin('run-m9c', START), 'm9c: begin')
    H.eq(#Pins(), 1, 'm9c: startBlip = false: a pin while the route is sampled')
    gps.found = true
    H.step(100)
    H.eq(#Pins(), 0, 'm9c: and none after it')
    wp = MINE
    Tick(3)
    H.eq(#Pins(), 0, 'm9c: none with a waypoint of his own either')
    Config.Markers.startBlip = true
    Tick(3)
    H.ok(#Pins() == 1 and B(Pins()[1]).route == true, 'm9c: switched back on in Settings: the pin with its line')
    Fire('client:runEnded', 'run-m9c')
    H.eq(#Pins(), 0, 'm9c: gone at the end')

    -- a test run without the start route (Start route off): the pin, never a line
    wp = nil
    H.ok(CR.begin('run-m9d', START, { startRoute = false }), 'm9d: begin without the start route')
    Tick(5)
    H.ok(#Pins() == 1 and #Routed() == 0, 'm9d: the pin, no line of ours')
    Fire('client:runEnded', 'run-m9d')
    H.eq(#Pins(), 0, 'm9d: gone at the end')

    _G.IsWaypointActive, _G.DoesBlipExist, _G.SetBlipRoute =
        saved.IsWaypointActive, saved.DoesBlipExist, saved.SetBlipRoute
end

-- ============================================================================
--                                     M10
-- ============================================================================
-- THE HUD SAYS WHERE THE OBJECTIVE IS AND HOW FAR; OBJECTIVE GPS.
-- CP.Markers' 1 s check sends the HUD what the pointer leads to and how far (Config.Markers.hudLine), only when that
-- changes; the tablet's Objective GPS button (client action setObjectiveGps, Config.Markers.objectiveGps) puts a map
-- waypoint on it, which is then the officer's one line (BLIPS_FINAL R2) and goes with the objective.

do
    Reset()
    CP.Tablet = TABLET
    CP.Route = {
        current = function() return world.route end,
    }
    local WAYPOINT_BLIP = 9100
    local wp, waypoints = nil, 0 -- the map waypoint as the game keeps it, and how often SetNewWaypoint ran
    local saved = { IsWaypointActive = _G.IsWaypointActive, DoesBlipExist = _G.DoesBlipExist }
    _G.SetNewWaypoint = function(x, y)
        wp = vec3(x, y, 0.0)
        waypoints = waypoints + 1
    end
    _G.IsWaypointActive = function() return wp ~= nil end
    _G.GetFirstBlipInfoId = function(sprite) return (sprite == 8 and wp) and WAYPOINT_BLIP or 0 end
    _G.GetBlipInfoIdCoord = function() return wp or vec3(0.0, 0.0, 0.0) end
    _G.SetWaypointOff = function() wp = nil end
    _G.DoesBlipExist = function(id)
        if id == WAYPOINT_BLIP then return wp ~= nil end
        return saved.DoesBlipExist(id)
    end
    -- the HUD's objective lines sent since the last call (false = cleared)
    local function Targets()
        local out = {}
        for _, p in ipairs(TB.huds) do if p.target ~= nil then out[#out + 1] = p.target end end
        TB.huds = {}
        return out
    end
    local Gps = TB.actions.setObjectiveGps
    H.ok(type(Gps) == 'function', 'm10: client action setObjectiveGps registered by modules/markers')
    TB.huds = {}

    -- the HUD line: the label and the distance from the objective's start, sent only when it changes
    M.set('run-m10', 1, { kind = 'point', coords = { x = 2000.0, y = 0.0, z = 30.0 }, label = 'Destination' })
    local t = Targets()
    H.eq(#t, 1, 'm10: one HUD line at the start of the objective')
    H.ok(t[1] and t[1].label == 'Destination' and t[1].distance == 2000 and t[1].inside == nil,
        'm10: the label and how far (2.0 km)')
    Tick(10)
    H.eq(#Targets(), 0, 'm10: 10 s standing still: no HUD send')
    world.me = vec3(30.0, 0.0, 30.0)
    Tick()
    H.eq(#Targets(), 0, 'm10: 1970 m still reads 2.0 km (100 m steps from 1 km): no send')
    world.me = vec3(300.0, 0.0, 30.0)
    Tick()
    t = Targets()
    H.ok(#t == 1 and t[1].distance == 1700, 'm10: 1.7 km: sent once')
    world.me = vec3(1503.0, 0.0, 30.0)
    Tick()
    t = Targets()
    H.ok(#t == 1 and t[1].distance == 500, 'm10: under 1 km in 10 m steps (497 m reads 500 m)')
    M.update('run-m10', 1, { kind = 'point', coords = { x = 2000.0, y = 0.0, z = 30.0 }, label = 'Destination' })
    Tick(3)
    H.eq(#Targets(), 0, 'm10: an unchanged update: no send')

    -- an area: how far to its edge, then inside it
    M.set('run-m10', 2, {
        kind = 'area',
        coords = { x = 1500.0, y = 600.0, z = 30.0 },
        radius = 100.0,
        look = 'fightArea',
        label = 'Hostiles',
    })
    t = Targets()
    H.ok(#t == 1 and t[1].label == 'Hostiles' and t[1].distance == 500, 'm10: an area: 500 m to its edge')
    world.me = vec3(1500.0, 550.0, 30.0)
    Tick()
    t = Targets()
    H.ok(#t == 1 and t[1].inside == true and t[1].distance == 0, 'm10: inside the circle: "You are in the area"')

    -- gone with the objective, and nothing sent after it
    M.clear('run-m10', 2)
    t = Targets()
    H.ok(#t == 1 and t[1] == false, 'm10: the objective stop clears the HUD line')
    Tick(3)
    H.eq(#Targets(), 0, 'm10: nothing sent once cleared')

    -- never while the officer still drives to the start (the route line is his), back once he arrived
    world.me = vec3(0.0, 0.0, 30.0)
    world.route = { runId = 'run-m10', arrived = false, routeOn = true }
    M.set('run-m10', 3, { kind = 'point', coords = { x = 800.0, y = 0.0, z = 30.0 }, label = 'Scene' })
    Tick(2)
    H.eq(#Targets(), 0, 'm10: driving to the start: no objective line on the HUD')
    world.route.arrived = true
    Tick()
    t = Targets()
    H.ok(#t == 1 and t[1].label == 'Scene' and t[1].distance == 800, 'm10: arrived: the objective line')
    world.route = nil

    -- Config.Markers.hudLine = false: cleared once, then nothing
    Config.Markers.hudLine = false
    Tick(3)
    t = Targets()
    H.ok(#t == 1 and t[1] == false, 'm10: hudLine = false clears the line once')
    Config.Markers.hudLine = true
    Tick()
    H.eq(#Targets(), 1, 'm10: switched back on in Settings: the line again')

    -- Radio Silence: only what the map shows; a suspect it hides gives no distance
    local silent = { radioSilence = true }
    M.set('run-m10', 4,
        { kind = 'targets', targets = { { key = 71, netId = 71, x = 900.0, y = 0.0, z = 30.0, look = 'fleeing' } } },
        silent)
    Tick()
    t = Targets()
    H.ok(#t == 1 and t[1] == false, 'm10: Radio Silence \'area\': no HUD distance to a suspect it hides')
    M.set('run-m10', 5, { kind = 'point', coords = { x = 0.0, y = 700.0, z = 30.0 }, label = 'Door' }, silent)
    t = Targets()
    H.ok(#t == 1 and t[1].label == 'Door' and t[1].distance == 700,
        'm10: Radio Silence \'area\': the point it shows has its line')
    M.clear()
    Targets()

    -- Objective GPS: refused with nothing to point at, while driving, when off, under Radio Silence
    local ok, err = Gps()
    H.ok(ok == false and err == 'err.objective_gps_none', 'm10: no objective: refused')
    M.set('run-g', 1, { kind = 'point', coords = { x = 600.0, y = 0.0, z = 30.0 }, label = 'Front door' })
    H.eq(#Routed(), 1, 'm10: the pointer routes before the button')
    world.route = { runId = 'run-g', arrived = false, routeOn = true }
    ok, err = Gps()
    H.ok(ok == false and err == 'err.objective_gps_start', 'm10: still driving to the start: refused')
    world.route = nil
    Config.Markers.objectiveGps = false
    ok, err = Gps()
    H.ok(ok == false and err == 'err.objective_gps_off', 'm10: objectiveGps = false: refused')
    Config.Markers.objectiveGps = true
    M.set('run-s', 1, { kind = 'point', coords = { x = 600.0, y = 0.0, z = 30.0 } }, silent)
    ok, err = Gps()
    H.ok(ok == false and err == 'err.objective_gps_silence', 'm10: Radio Silence \'area\': refused')
    H.eq(wp, nil, 'm10: no waypoint after a refusal')
    Config.Markers.radioSilence = 'full'
    H.eq((Gps()), true, 'm10: Radio Silence \'full\': allowed')
    Config.Markers.radioSilence = 'area'
    M.clear()
    H.eq(wp, nil, 'm10: the run end removes our waypoint')

    -- set: a waypoint on the pointer; the officer's one line (R2), kept while it is ours
    M.set('run-g', 1, { kind = 'point', coords = { x = 600.0, y = 0.0, z = 30.0 }, label = 'Front door' })
    waypoints = 0
    TB.notes = {}
    local data
    ok, data = Gps()
    H.ok(ok == true and type(data) == 'table' and data.label == 'Front door', 'm10: Objective GPS set')
    H.ok(wp and wp.x == 600.0 and wp.y == 0.0, 'm10: the waypoint is on the objective')
    H.eq(#Routed(), 0, 'm10: our line goes off at once: the waypoint is his one line (R2)')
    H.ok(TB.notes[1] and TB.notes[1].kind == 'info' and TB.notes[1].text == 'markers.gps_set', 'm10: a toast says so')
    Tick(3)
    H.eq(#Routed(), 0, 'm10: and stays off while the waypoint is there')
    H.eq(waypoints, 1, 'm10: a point that does not move: the waypoint is set once')
    M.clear('run-g', 1)
    H.eq(wp, nil, 'm10: the objective stop removes our waypoint')

    -- the next objective routes again; a moving one is followed while the waypoint stays ours
    local car = { kind = 'targets', targets = { { key = 81, x = 900.0, y = 0.0, z = 30.0, look = 'vehicle' } } }
    M.set('run-g', 2, car)
    H.eq(#Routed(), 1, 'm10: the next objective has its line (no waypoint left)')
    H.eq((Gps()), true, 'm10: Objective GPS on a moving car')
    waypoints = 0
    car.targets[1].x = 930.0
    M.update('run-g', 2, car)
    Tick()
    H.eq(waypoints, 0, 'm10: moved 30 m: the waypoint stays')
    car.targets[1].x = 1000.0
    M.update('run-g', 2, car)
    Tick()
    H.ok(waypoints == 1 and wp and wp.x == 1000.0, 'm10: moved 100 m: the waypoint follows it')
    H.eq(#Routed(), 0, 'm10: still one line, the waypoint\'s')

    -- his own waypoint is never moved or removed
    local MINE = vec3(-500.0, -500.0, 0.0)
    wp = MINE
    Tick()
    car.targets[1].x = 1200.0
    M.update('run-g', 2, car)
    Tick(2)
    H.ok(wp == MINE, 'm10: a waypoint of his own is not moved')
    M.clear('run-g', 2)
    H.ok(wp == MINE, 'm10: nor removed at the objective stop')

    -- a new objective without a stop in between (an update for another index) still drops our waypoint
    wp = nil
    M.set('run-g', 3, { kind = 'point', coords = { x = 600.0, y = 0.0, z = 30.0 } })
    H.eq((Gps()), true, 'm10: set on objective 3')
    M.update('run-g', 4, { kind = 'point', coords = { x = 0.0, y = 900.0, z = 30.0 } })
    H.eq(wp, nil, 'm10: objective 4: the waypoint of objective 3 went')
    H.eq(#Routed(), 1, 'm10: and objective 4 has its line')
    M.clear()
    H.ok(NoRemovedRoute(), 'm10: every blip lost its line first')

    _G.IsWaypointActive, _G.DoesBlipExist = saved.IsWaypointActive, saved.DoesBlipExist
end

-- ============================================================================
--                                     M11
-- ============================================================================
-- A LATE PARTNER FOLLOWS THE ACTION (modules/runs/client.lua hook).
-- The server's client:routeStatus 'action' (Config.Route.lateArriveRange): the start goes first (circle here, waypoint
-- and pin in CP.Route.follow, which also stops the sampling and reports), and only then does CP.Markers route. Under
-- Radio Silence or with no objective line he keeps the start (follow without dropping it).

do
    Reset()
    local follows = {}
    -- the objective's lines only: modules/route/client.lua (loaded for M9 above) also begins on client:start
    local function ObjRouted()
        local out = {}
        for _, id in ipairs(Routed()) do if B(id).name ~= CP.L('route.blip') then out[#out + 1] = id end end
        return out
    end
    CP.Route = {
        current = function() return world.route end,
        begin = function() return true end,
        stop = function() world.route = nil end,
        follow = function(runId, dropStart, secondsLeft)
            follows[#follows + 1] = {
                runId = runId,
                drop = dropStart,
                left = secondsLeft,
                circles = #Live('radius'),
                routed = #ObjRouted(),
            }
            world.route.action = true
            return true
        end,
    }
    CP.Tablet = { hud = function() end, registerClientAction = function() end, notify = function() end }
    local function Fire(name, ...)
        for _, fn in ipairs(H.handlers[CP.e(name)] or {}) do fn(...) end
    end
    local mission = { id = 'probe', label = 'Probe', objectives = { { block = 'marker_probe' } } }
    local function Late(runId, modifiers)
        world.route = { runId = runId, arrived = false, routeOn = true }
        Fire('client:start', runId, {
            missionId = 'probe',
            mission = mission,
            host = 8,
            modifiers = modifiers,
            start = { coords = { x = 10.0, y = 10.0, z = 30.0 }, radius = 300.0 },
        })
    end

    Late('run-12')
    H.eq(#Live('radius'), 1, 'm11: the start circle while he drives')
    Fire('client:inProgress', 'run-12', { objectives = mission.objectives })
    Fire('client:objective', 'run-12', 1,
        { action = 'start', marker = { kind = 'point', coords = { x = 400.0, y = 0.0, z = 30.0 }, label = 'Go' } })
    Tick()
    H.eq(#ObjRouted(), 0, 'm11: still bound to the start: no objective line (the start keeps his one line)')
    H.eq((M.objectiveGps()), false, 'm11: no Objective GPS while bound to the start')
    Fire('client:routeStatus', 'run-x', { status = 'action' })
    Fire('client:routeStatus', 'run-12', { status = 'arrived' })
    H.eq(#follows, 0, 'm11: another run or another status: nothing')
    Fire('client:routeStatus', 'run-12', { status = 'action', secondsLeft = 287 })
    H.eq(#follows, 1, 'm11: CP.Route.follow once')
    H.eq(follows[1] and follows[1].left, 287, 'm11: with the time he has to reach the action (R6)')
    H.ok(follows[1] and follows[1].runId == 'run-12' and follows[1].drop == true,
        'm11: the start dropped: CP.Markers can draw his line')
    H.ok(follows[1] and follows[1].circles == 0 and follows[1].routed == 0,
        'm11: no start circle and no objective line at that moment (the start goes first)')
    Tick()
    H.eq(#ObjRouted(), 1, 'm11: then CP.Markers routes to the objective')
    H.eq(ObjRouted()[1] and B(ObjRouted()[1]).name, 'Go', 'm11: ...to its pointer')
    Fire('client:runEnded', 'run-12', 'completed', 'completed')
    H.eq(#Live(), 0, 'm11: everything goes at the run end')

    -- Radio Silence ('area', shipped: no objective lines): he keeps the start as his guide
    Late('run-13', { 'radio_silence' })
    Fire('client:inProgress', 'run-13', { objectives = mission.objectives })
    Fire('client:routeStatus', 'run-13', { status = 'action' })
    H.ok(#follows == 2 and follows[2].drop == false, 'm11: Radio Silence: follows, the start kept')
    Fire('client:runEnded', 'run-13', 'completed', 'completed')
    Config.Markers.radioSilence = 'full'
    Late('run-14', { 'radio_silence' })
    Fire('client:inProgress', 'run-14', { objectives = mission.objectives })
    Fire('client:routeStatus', 'run-14', { status = 'action' })
    H.ok(#follows == 3 and follows[3].drop == true, 'm11: Radio Silence \'full\' keeps lines: the start dropped')
    Fire('client:runEnded', 'run-14', 'completed', 'completed')
    Config.Markers.radioSilence = 'area'
    -- no objective line at all (Config.Markers.route or enabled off)
    for i, key in ipairs({ 'route', 'enabled' }) do
        Config.Markers[key] = false
        Late('run-15' .. i)
        Fire('client:inProgress', 'run-15' .. i, { objectives = mission.objectives })
        Fire('client:routeStatus', 'run-15' .. i, { status = 'action' })
        H.ok(#follows == 3 + i and follows[3 + i].drop == false,
            'm11: Config.Markers.' .. key .. ' off: the start kept')
        Fire('client:runEnded', 'run-15' .. i, 'completed', 'completed')
        Config.Markers[key] = true
    end
    M.clear()
end

return H
