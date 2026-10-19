-- CP.Spawn.probe (modules/spawn/client.lua; PLAN S6): whether the ground at a mission point is fit to put a person,
-- a vehicle or an object on, against a small game map whose natives check their argument types (H.groundNatives):
-- the collision and the inside of a building load first, then the ground, water and wall probes run.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local W = H.groundNatives()
local PED, CAR = W.ped, 777
H.load('modules/spawn/client.lua')
H.ok(type(CP.Spawn) == 'table' and type(CP.Spawn.probe) == 'function', 'CP.Spawn.probe')

local DEFAULT_GROUND = {
    pedAbove = { -0.3, 1.6 },
    vehicleAbove = { -0.2, 1.5 },
    propAbove = { -0.1, 0.5 },
    snapWithin = 3.0,
}
H.eq(Config.Spawning.ground.snapWithin, 3.0, 'config.lua: snapWithin 3.0 m')
H.eq(table.concat(Config.Spawning.ground.pedAbove, ','), '-0.3,1.6', 'config.lua: a person fits from -0.3 to 1.6 m')
H.eq(table.concat(Config.Spawning.ground.vehicleAbove, ','), '-0.2,1.5', 'config.lua: a vehicle from -0.2 to 1.5 m')
H.eq(table.concat(Config.Spawning.ground.propAbove, ','), '-0.1,0.5', 'config.lua: an object from -0.1 to 0.5 m')
H.eq(Config.Spawning.collisionTimeoutMs, 6000, 'config.lua: 6 s for the collision')
H.eq(Config.Spawning.interiorTimeoutMs, 5000, 'config.lua: 5 s for an interior')

-- A new map for each case: flat ground at z (none when z is nil), collision at once, no water, no wall.
local function Map(z)
    W.reset()
    W.car = 0
    W.surfaces = z and { { z = z } } or {}
    W.collisionMs = 0
    W.interiors = {}
    W.water = nil
    W.wall = function() return false end
    W.capsuleFrames, W.capsuleStuck, W.capsuleFail, W.hitAs = 1, false, false, 1
    W.models = {}
    Config.Spawning.ground = {
        pedAbove = { DEFAULT_GROUND.pedAbove[1], DEFAULT_GROUND.pedAbove[2] },
        vehicleAbove = { DEFAULT_GROUND.vehicleAbove[1], DEFAULT_GROUND.vehicleAbove[2] },
        propAbove = { DEFAULT_GROUND.propAbove[1], DEFAULT_GROUND.propAbove[2] },
        snapWithin = DEFAULT_GROUND.snapWithin,
    }
    Config.Spawning.collisionTimeoutMs = 6000
    Config.Spawning.interiorTimeoutMs = 5000
end

-- The probe in a thread (it waits for the game), one frame = 16 ms: its answer and how long it took.
local function Probe(...)
    local args = table.pack(...)
    local res, done = nil, false
    local t0 = H.clockMs
    CreateThread(function()
        res = CP.Spawn.probe(table.unpack(args, 1, args.n))
        done = true
    end)
    while not done and H.clockMs - t0 < 120000 do H.step(16) end
    H.ok(done, 'the probe answered')
    return res or {}, H.clockMs - t0
end

local function Called(name)
    local n = 0
    for _, c in ipairs(W.calls) do if c.name == name then n = n + 1 end end
    return n
end

local function Near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-6 end

-- ============================================================================
--                     A PERSON: OK, SNAP, UNDER, FLOATING
-- ============================================================================

do
    -- ground 1 m under a person's point (where a standing person's point is): fits
    Map(30.0)
    local errors = W.typeErrors
    local res = Probe('ped', 100, 200, 31, 90, nil)
    H.eq(res.status, 'ok', 'ground 1 m under a person: ok')
    H.ok(Near(res.groundZ, 30.0) and Near(res.dz, 1.0) and Near(res.z, 31.0),
        'ground 30.0, 1.0 m over it, kept at 31.0')
    H.eq(W.typeErrors, errors, 'whole-number coordinates from a mission file reach the game as decimals')
    H.ok(Called('RequestCollisionAtCoord') >= 1, 'the collision at the point is asked for')
    local hc = nil
    for _, c in ipairs(W.calls) do if c.name == 'HasCollisionLoadedAroundEntity' then hc = c.args[1] end end
    H.eq(hc, PED, 'and waited for around this player\'s ped')
    H.eq(res.wall, false, 'the wall probe ran and is clear')
    local c = W.capsules[1]
    H.ok(c and Near(c.x1, 100.0) and Near(c.z1, 30.45) and Near(c.z2, 31.7) and Near(c.r, 0.32),
        'a standing person\'s capsule from 0.45 m to 1.7 m over the ground, 0.32 m wide')
    H.ok(c and c.flags == 1 + 2 + 16 and c.options == 7 and c.ignore == PED,
        'the map, vehicles and objects are walls; his own ped is ignored')
    H.eq(res.interior, 0, 'outside')
    H.eq(res.loaded, true, 'the collision was loaded')
    H.eq(res.roofZ, nil, 'nothing over it')

    -- the gang_shootout #4 spawns[7] case of the spawn audit: 0.52 m under the ground: put on it
    Map(6.40)
    res = Probe('ped', 1153.75, -3169.50, 5.88, 0.0)
    H.eq(res.status, 'snap', 'a person 0.52 m under the ground is put on it')
    H.ok(Near(res.groundZ, 6.40) and Near(res.dz, 5.88 - 6.40) and Near(res.z, 7.40),
        'ground 6.40, -0.52 m, moved to 7.40 (1 m over the ground)')

    -- the ground 2 m over a person's point: under the ground; snapWithin decides whether it is put on it
    Map(33.0)
    Config.Spawning.ground.snapWithin = 2.5
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'underground', 'the ground 2 m over a person: under the ground (snapWithin 2.5 m)')
    H.ok(Near(res.groundZ, 33.0) and Near(res.dz, -2.0) and Near(res.z, 31.0), 'ground 33.0, -2.0 m, not moved')
    H.eq(#W.capsules, 0, 'a bad point gets no wall probe')
    Map(33.0)
    Config.Spawning.ground.snapWithin = 3.5
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'snap', 'with snapWithin 3.5 m the same point is put on the ground (a 3 m move)')
    H.ok(Near(res.z, 34.0), 'at 34.0')

    -- buried deeper than 2 m: the look from 50 m over it finds the ground over it
    Map(nil)
    W.surfaces = { { z = 36.0 } }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'underground', 'a person 5 m under the ground: under the ground')
    H.ok(Near(res.groundZ, 36.0) and Near(res.dz, -5.0), 'the ground over him at 36.0, -5.0 m')

    -- floating: 4 m over the ground is too far to put down; 2 m over it is put down
    Map(30.0)
    res = Probe('ped', 0.0, 0.0, 35.0, 0.0)
    H.eq(res.status, 'floating', 'a person 5 m over the ground: floating')
    H.ok(Near(res.dz, 5.0) and Near(res.z, 35.0), '5.0 m over it, not moved')
    Map(30.0)
    res = Probe('ped', 0.0, 0.0, 32.0, 0.0)
    H.eq(res.status, 'snap', 'a person 2 m over the ground (over 1.6 m) is put down')
    H.ok(Near(res.z, 31.0), 'at 31.0')
    -- the person's range read live from Config.Spawning.ground
    Map(30.0)
    Config.Spawning.ground.pedAbove = { 0.5, 1.2 }
    res = Probe('ped', 0.0, 0.0, 30.2, 0.0)
    H.eq(res.status, 'snap', 'the range is read live: 0.2 m over the ground is under a range of 0.5-1.2 m')
    Map(30.0)
    Config.Spawning.ground.pedAbove = { 2, 1 }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'ok', 'a range whose lowest is over its highest: the config.lua default')
    Map(30.0)
    Config.Spawning.ground = nil
    res = Probe('ped', 0.0, 0.0, 32.0, 0.0)
    H.eq(res.status, 'snap', 'no ground settings at all: the defaults (2 m over it is put down)')
    Config.Spawning.ground = DEFAULT_GROUND

    -- a roof or a bridge over the point: still fine, reported as information
    Map(30.0)
    W.surfaces[2] = { z = 40.0 }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'ok', 'a bridge 9 m over a person: ok')
    H.ok(Near(res.roofZ, 40.0) and Near(res.groundZ, 30.0), 'the ground at 30.0, the roof at 40.0')
    -- a low roof or the floor above 1.6 m over a person's point inside a trailer lab: he stands on the floor under
    -- it (the look from 2 m over him finds the roof's top first)
    Map(nil)
    W.surfaces = { { z = 30.0, nz = 0.9, interior = 55 }, { z = 32.6, interior = 55 } }
    W.interiors[55] = {
        at = function() return true end,
        ready = true,
    }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'ok', 'a person inside under a roof 1.6 m over his point: ok on the floor, not put on the roof')
    H.ok(Near(res.groundZ, 30.0) and Near(res.dz, 1.0) and Near(res.z, 31.0) and Near(res.normalZ, 0.9),
        'the floor at 30.0 (its normal), 1.0 m over it, kept at 31.0')
    H.ok(Near(res.roofZ, 32.6) and res.interior == 55, 'the roof at 32.6 is reported as the roof')
    H.ok(W.capsules[1] and Near(W.capsules[1].z1, 30.45), 'his space is checked on the floor')
    -- 1.8 m over the floor under a roof 1.2 m over him: put down on the floor, not up on the roof
    Map(30.0)
    W.surfaces[2] = { z = 33.0 }
    res = Probe('ped', 0.0, 0.0, 31.8, 0.0)
    H.eq(res.status, 'snap', 'a person 1.8 m over the floor under a roof: put down')
    H.ok(Near(res.z, 31.0) and Near(res.groundZ, 30.0) and Near(res.roofZ, 33.0),
        'onto the floor at 31.0, the roof 33.0')
    -- 0.5 m under the floor above with the floor below 3 m under him: put on the floor above (the smaller move)
    Map(28.0)
    W.surfaces[2] = { z = 31.5 }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'snap', 'a person 0.5 m under an upper floor: put on it')
    H.ok(Near(res.z, 32.5) and Near(res.groundZ, 31.5) and res.roofZ == nil, 'at 32.5, on the floor at 31.5')
    -- the surface normal of the ground
    Map(nil)
    W.surfaces = { { z = 30.0, nz = 0.8 } }
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.ok(Near(res.normalZ, 0.8), 'the ground\'s normal (a slope) is reported')
end

-- ============================================================================
--                           NO GROUND, WATER, WALLS
-- ============================================================================

do
    -- no ground at all: after the collision wait
    Map(nil)
    Config.Spawning.collisionTimeoutMs = 1000
    local res, took = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'no_ground', 'nothing under or over the point: no ground')
    H.eq(res.groundZ, nil, 'no ground height')
    H.ok(took >= 1000 and took < 1100,
        'it looked for the ground until collisionTimeoutMs (read live, ' .. took .. ' ms)')

    -- water over the ground (the sea bed 1.5 m under the surface): in water
    Map(10.0)
    W.water = function() return 11.5 end
    res = Probe('ped', 0.0, 0.0, 11.0, 0.0)
    H.eq(res.status, 'in_water', 'water over the ground: in water')
    H.ok(res.water == true and Near(res.groundZ, 10.0), 'water true, the bed at 10.0')
    -- the water height alone (the surface far under the probe's line) over the ground
    Map(10.0)
    W.water = function() return 14.0 end
    res = Probe('prop', 0.0, 0.0, 10.2, 0.0)
    H.eq(res.status, 'in_water', 'a clue 4 m under water: in water')
    -- a pier: water 5 m under the deck is no water at the point
    Map(5.0)
    W.water = function() return 0.0 end
    res = Probe('ped', 0.0, 0.0, 6.0, 0.0)
    H.eq(res.status, 'ok', 'a person on a pier over the sea: ok')
    H.eq(res.water, false, 'no water at the point')

    -- a wall where the person would stand: in a wall (the hit as 1 or as true)
    Map(30.0)
    W.wall = function() return true end
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'in_wall', 'the capsule hits something: in a wall')
    H.eq(res.wall, true, 'wall true')
    Map(30.0)
    W.wall = function() return true end
    W.hitAs = true
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'in_wall', 'a hit handed back as true: in a wall too')
    -- a point put on the ground is checked where it would stand
    Map(30.0)
    W.wall = function(c) return c.z1 < 30.6 end
    res = Probe('ped', 0.0, 0.0, 32.0, 0.0)
    H.eq(res.status, 'in_wall', 'a point put on the ground is checked for a wall on the ground')
    -- the probe takes a few frames: still read
    Map(30.0)
    W.wall = function() return true end
    W.capsuleFrames = 4
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'in_wall', 'a wall probe that takes four frames still counts')
    -- what it cannot tell is no wall
    Map(30.0)
    W.wall = function() return true end
    W.capsuleStuck = true
    local took2
    res, took2 = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'ok', 'a wall probe that never finishes: not known, the point stays ok')
    H.eq(res.wall, nil, 'wall nil (not known)')
    H.ok(took2 >= 1000 and took2 < 1100, 'it waited 1 s for the wall probe (' .. took2 .. ' ms)')
    local polls = W.capsules[1].polls
    H.advance(2000, 16)
    H.ok(W.capsules[1].polls > polls, 'the unfinished probe is still read afterwards, so the game frees its handle')
    Map(30.0)
    W.capsuleFail = true
    res = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.ok(res.status == 'ok' and res.wall == nil, 'a wall probe that did not start: not known, ok')
    -- in a car the probes ignore the car; a caller can name what they ignore and whose collision counts
    Map(30.0)
    W.car = CAR
    Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(W.capsules[1].ignore, CAR, 'in a car the wall probe ignores his car')
    Map(30.0)
    Probe('ped', 0.0, 0.0, 31.0, 0.0, nil, { entity = 9001, ignore = 9001 })
    local hc = nil
    for _, c in ipairs(W.calls) do if c.name == 'HasCollisionLoadedAroundEntity' then hc = c.args[1] end end
    H.ok(hc == 9001 and W.capsules[1].ignore == 9001, 'opts.entity and opts.ignore: the placer\'s own entity')
end

-- ============================================================================
--                       LOADING: COLLISION AND INTERIORS
-- ============================================================================

do
    -- the collision takes 400 ms to load: the probe waits for it, then finds the ground
    Map(30.0)
    W.collisionMs = 400
    local res, took = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.status, 'ok', 'the ground is found once the collision is there')
    H.ok(res.loaded == true and took >= 400 and took < 600, 'waited for the collision (' .. took .. ' ms)')
    -- it never loads: reported, and the ground (found only with the collision) is missing
    Map(30.0)
    W.collisionMs = nil
    Config.Spawning.collisionTimeoutMs = 10
    res, took = Probe('ped', 0.0, 0.0, 31.0, 0.0)
    H.eq(res.loaded, false, 'the collision never loaded')
    H.eq(res.status, 'no_ground', 'and no ground was found')
    H.ok(took >= 500 and took < 600, 'collisionTimeoutMs is at least 500 ms (' .. took .. ' ms)')

    -- the inside of a bank: pinned until it is ready, then its floor is found
    Map(10.0)
    W.surfaces[2] = { z = 20.0, interior = 77 }
    W.interiors[77] = {
        at = function(_, _, z) return z > 15.0 end,
        readyMs = 300,
    }
    res, took = Probe('ped', 0.0, 0.0, 21.0, 0.0)
    H.eq(res.status, 'ok', 'a person inside a bank: ok on its floor')
    H.ok(Near(res.groundZ, 20.0) and res.interior == 77, 'the floor at 20.0, interior 77')
    H.eq(W.pins[77], 0, 'the probe pinned the interior and let it go again')
    H.eq(W.unpins[77], 1, 'one unpin')
    H.ok(took >= 300 and took < 500, 'waited for the interior (' .. took .. ' ms)')
    -- already loaded: not pinned, not unpinned (someone else's pin stays)
    Map(10.0)
    W.surfaces[2] = { z = 20.0, interior = 77 }
    W.interiors[77] = {
        at = function(_, _, z) return z > 15.0 end,
        ready = true,
    }
    res = Probe('ped', 0.0, 0.0, 21.0, 0.0)
    H.eq(res.status, 'ok', 'a loaded interior: ok')
    H.ok(Called('PinInteriorInMemory') == 0 and Called('UnpinInterior') == 0, 'a loaded interior is not pinned')
    -- never ready: inside not loaded (read live), the pin let go
    Map(10.0)
    W.surfaces[2] = { z = 20.0, interior = 77 }
    W.interiors[77] = {
        at = function(_, _, z) return z > 15.0 end,
    }
    Config.Spawning.interiorTimeoutMs = 1000
    res, took = Probe('ped', 0.0, 0.0, 21.0, 0.0)
    H.eq(res.status, 'interior_not_loaded', 'an interior that never gets ready: inside not loaded')
    H.ok(res.interior == 77 and res.groundZ == nil, 'interior 77, no ground height')
    H.ok(took >= 1000 and took < 1100, 'after interiorTimeoutMs, read live (' .. took .. ' ms)')
    H.eq(W.unpins[77], 1, 'the pin is let go')
    H.eq(#W.capsules, 0, 'and nothing else was probed')
end

-- ============================================================================
--                             VEHICLES AND OBJECTS
-- ============================================================================

do
    local SULTAN = joaat('sultan')
    local function Sultan(preloaded)
        W.models[SULTAN] = {
            mn = vec3(-1.0, -2.3, -0.6),
            mx = vec3(1.0, 2.3, 0.9),
            loadMs = 100,
            preloaded = preloaded,
        }
    end
    -- a car on the road, sized by its model (loaded for it and let go again)
    Map(50.0)
    Sultan(false)
    local res = Probe('vehicle', 0.0, 0.0, 50.6, 90.0, 'sultan')
    H.eq(res.status, 'ok', 'a car 0.6 m over the road: ok')
    H.eq(res.sized, true, 'sized by its model')
    H.ok(W.requested[SULTAN] ~= nil and W.released[SULTAN] == true, 'the model was loaded for it and let go again')
    local c = W.capsules[1]
    -- heading 90 faces -x: the capsule runs 1.6 m to each side along x, 0.9 m over the road, 0.7 m wide
    H.ok(c and Near(c.x1, -1.6) and Near(c.x2, 1.6) and Near(c.y1, 0.0) and Near(c.z1, 50.9) and Near(c.r, 0.7),
        'the car\'s capsule along its heading, half its height over the road')
    -- the Street Race Bust La Mesa case of the spawn audit: a grid car 1.5 m under the road is put on it
    Map(50.0)
    Sultan(true)
    res = Probe('vehicle', 0.0, 0.0, 48.5, 0.0, SULTAN)
    H.eq(res.status, 'snap', 'a car 1.5 m under the road is put on it')
    H.ok(Near(res.z, 50.6), 'at 50.6 (its wheels on the road)')
    H.eq(W.released[SULTAN], nil, 'a model that was loaded already is not let go')
    -- a car in a parking garage, the deck above 1.5 m over its point: on its own level
    Map(50.0)
    W.surfaces[2] = { z = 52.1 }
    Sultan(true)
    res = Probe('vehicle', 0.0, 0.0, 50.6, 0.0, 'sultan')
    H.eq(res.status, 'ok', 'a car under the next deck of a garage: ok, not put on the deck')
    H.ok(Near(res.groundZ, 50.0) and Near(res.z, 50.6) and Near(res.roofZ, 52.1), 'its level at 50.0, the deck 52.1')
    -- 3 m under the road: too far
    Map(50.0)
    Sultan(true)
    res = Probe('vehicle', 0.0, 0.0, 47.0, 0.0, 'sultan')
    H.eq(res.status, 'underground', 'a car 3 m under the road: under the ground')
    -- an unknown model: a car of unknown size
    Map(50.0)
    res = Probe('vehicle', 0.0, 0.0, 50.5, 0.0, 'nosuchcar')
    H.eq(res.sized, false, 'an unknown model: a car of unknown size')
    H.eq(res.status, 'ok', 'still checked')
    H.ok(W.capsules[1] and Near(W.capsules[1].r, 0.8), 'with the Builder\'s car capsule')
    -- a car parked in another car
    Map(50.0)
    Sultan(true)
    W.wall = function() return true end
    res = Probe('vehicle', 0.0, 0.0, 50.6, 0.0, 'sultan')
    H.eq(res.status, 'in_wall', 'a car inside another car or a wall: in a wall')

    -- objects: a clue half under the road is put on it; an object gets no wall probe
    Map(32.68)
    res = Probe('prop', 0.0, 0.0, 32.20, 0.0)
    H.eq(res.status, 'snap', 'a clue 0.48 m under the road is put on it')
    H.ok(Near(res.z, 32.68), 'on the road')
    H.eq(#W.capsules, 0, 'objects get no wall probe')
    Map(30.0)
    res = Probe('prop', 0.0, 0.0, 30.3, 0.0)
    H.eq(res.status, 'ok', 'a stash 0.3 m over the floor: ok')
    Map(30.0)
    res = Probe('object', 0.0, 0.0, 34.0, 0.0)
    H.ok(res.status == 'floating' and res.kind == 'prop', 'kind \'object\' is a prop; 4 m over the floor: floating')
    Map(30.0)
    res = Probe('marker', 0.0, 0.0, 30.0, 0.0)
    H.eq(res.kind, 'prop', 'any other kind is a prop')
end

-- ============================================================================
--                                  BAD INPUT
-- ============================================================================

do
    Map(30.0)
    local res = Probe('ped', 'a', 0.0, 31.0, 0.0)
    H.eq(res.status, 'no_ground', 'a point that is no point: no ground')
    H.eq(#W.calls, 0, 'and the game is not asked anything')
    res = Probe('ped', 0.0, 0.0, 31.0, 'north')
    H.eq(res.status, 'ok', 'a heading that is no number: 0')
end

W.restore()
return H
