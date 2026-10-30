-- The placer (modules/spawn/client.lua; PLAN S9): a participant's game puts a new mission entity on the ground when
-- the server asks through its cp bag, or leaves a bad point frozen, and tells the server, against the typed natives
-- of H.placerNatives over the ground map of H.groundNatives.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local G = H.groundNatives()
local P = H.placerNatives()
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn }
end
local currentRun = nil
CP.Runs = {
    current = function() return currentRun end,
}
H.load('modules/spawn/client.lua')

local EVENT = 'crimson-police:server:spawnPlaced'
local ME, PARTNER, BYSTANDER = 0, 1, 2 -- player indexes in this game
local PED, VAN, BOX = 9001, 9002, 9003 -- entity handles in this game

local handlers = 0
for _, h in ipairs(bagHandlers) do if h.key == 'cp' and h.bag == nil then handlers = handlers + 1 end end
H.eq(handlers, 1, 'one handler for the cp bag of every entity')
H.eq(Config.Spawning.place, true, 'config.lua: the placer is on')

local function Near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-6 end

-- A new game for each case: flat ground at z (none when nil), collision at once, no water, no wall; this player
-- (server id 1) and his partner (2) are on run-1, a bystander (3) is not.
local function Game(z)
    G.reset()
    G.car = 0
    G.surfaces = z and { { z = z } } or {}
    G.collisionMs = 0
    G.interiors = {}
    G.water = nil
    G.wall = function() return false end
    G.capsuleFrames, G.capsuleStuck, G.capsuleFail, G.hitAs = 1, false, false, 1
    G.models = {}
    P.entities, P.ignored, P.calls = {}, {}, {}
    P.me = ME
    P.players = {
        [ME] = { src = 1, ped = G.ped, coords = vec3(0.0, -60.0, 30.0) },
        [PARTNER] = { src = 2, ped = 5001, coords = vec3(0.0, -90.0, 30.0) },
        [BYSTANDER] = { src = 3, ped = 5002, coords = vec3(0.0, 20.0, 30.0) },
    }
    currentRun = {
        id = 'run-1',
        participants = { { src = 1, status = 'active' }, { src = 2, status = 'active' } },
    }
    H.events = {}
end

local function Bag(netId, value)
    for _, h in ipairs(bagHandlers) do
        if h.key == 'cp' then h.fn('entity:' .. netId, 'cp', value, 0, false) end
    end
end

local function Ask(netId, place, extra)
    local bag = { run = 'run-1', obj = 1, role = 'hostile', state = 'idle', armed = false, cfg = {}, place = place }
    for k, v in pairs(extra or {}) do bag[k] = v end
    Bag(netId, bag)
    return bag
end

local function Reports() return H.findEvents(EVENT) end

-- Frames of 16 ms until fn() or ms ran out; fn's answer.
local function Until(fn, ms)
    local t0 = H.clockMs
    while not fn() and H.clockMs - t0 < (ms or 40000) do H.step(16) end
    return fn()
end

local function Settle(ms)
    local t0 = H.clockMs
    while H.clockMs - t0 < ms do H.step(16) end
end

local function Called(name, handle)
    local n = 0
    for _, c in ipairs(P.calls) do
        if c.name == name and (handle == nil or c.args[1] == handle) then n = n + 1 end
    end
    return n
end

local function Report(i)
    local r = Reports()[i or 1]
    return r and r.args[2] or {}, r and r.args[1] or nil
end

-- ============================================================================
--                  A PERSON THIS GAME CONTROLS: OK, SNAP, BAD
-- ============================================================================

do
    -- the ground 1 m under a person's point (where a standing person's point is): put on it, let go, told
    Game(30.0)
    local e = P.entity(PED, { netId = 41, type = 1, owner = ME, frozen = true, coords = vec3(10.0, 20.0, 31.0) })
    local errors = P.typeErrors + G.typeErrors
    Ask(41, { x = 10, y = 20, z = 31, h = 90, kind = 'ped', token = 't-41' })
    H.ok(Until(function() return #Reports() == 1 end), 'the placer told the server')
    local r, runId = Report()
    H.eq(runId, 'run-1', 'for run-1')
    H.ok(r.netId == 41 and r.token == 't-41' and r.result == 'placed' and r.reason == 'ok',
        'net id, the server\'s token, placed, ok')
    H.ok(Near(r.groundZ, 30.0) and Near(r.z, 31.0) and Near(r.dz, 1.0),
        'the ground at 30.0, put at 31.0, 1.0 m over it')
    H.ok(Near(e.coords.x, 10.0) and Near(e.coords.y, 20.0) and Near(e.coords.z, 31.0),
        'the person stands on the ground at the server\'s x, y')
    H.eq(e.frozen, false, 'and is let go')
    H.eq(e.keepTasks, true, 'keeping the tasks his game gave him')
    H.eq(e.loadCollision, true, 'the collision around him is kept loaded (no dormant ped far from this player)')
    H.eq(P.typeErrors + G.typeErrors, errors, 'whole-number coordinates from the bag reach the game as decimals')
    local hc = nil
    for _, c in ipairs(G.calls) do if c.name == 'HasCollisionLoadedAroundEntity' then hc = c.args[1] end end
    H.eq(hc, PED, 'the probe waited for the collision around the person, not around this player')
    H.ok(G.capsules[1] and G.capsules[1].ignore == PED, 'his own space is checked ignoring himself')
    H.ok(G.capsules[1] and Near(G.capsules[1].z1, 30.45), 'on the ground at 30.0')
    -- the freeze is held until the probe has judged the point
    local froze, coordsAt, letGo = nil, nil, nil
    for i, c in ipairs(P.calls) do
        if c.name == 'FreezeEntityPosition' and c.args[2] == true and not froze then froze = i end
        if c.name == 'SetEntityCoordsNoOffset' then coordsAt = i end
        if c.name == 'FreezeEntityPosition' and c.args[2] == false then letGo = i end
    end
    H.ok(froze and coordsAt and letGo and froze < coordsAt and coordsAt < letGo,
        'frozen first, moved onto the ground, then let go')
    H.eq(Called('NetworkRequestControlOfEntity'), 0, 'no control asked for: this game has it')
    -- the same ask again (another write of the bag) is not placed twice
    Ask(41, { x = 10, y = 20, z = 31, h = 90, kind = 'ped', token = 't-41' }, { state = 'hostile' })
    Settle(2000)
    H.eq(#Reports(), 1, 'the same token is placed once')

    -- the gang_shootout #4 spawns[7] case of the spawn audit: 0.52 m under the ground: put on it
    Game(6.40)
    e = P.entity(PED, { netId = 42, type = 1, owner = ME, frozen = true, coords = vec3(1153.75, -3169.50, 5.88) })
    Ask(42, { x = 1153.75, y = -3169.50, z = 5.88, h = 0, kind = 'ped', token = 7 })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    r = Report()
    H.ok(r.result == 'placed' and r.reason == 'snap' and r.token == 7, 'placed, snap (a number token works too)')
    H.ok(Near(e.coords.z, 7.40) and Near(r.z, 7.40) and Near(r.groundZ, 6.40), 'put 1 m over the ground at 6.40')
    H.eq(e.frozen, false, 'let go')

    -- 5 m under the ground: bad, stays frozen where it is, nothing moved
    Game(36.0)
    e = P.entity(PED, { netId = 43, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 31.0) })
    Ask(43, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-43' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    r = Report()
    H.ok(r.result == 'bad' and r.reason == 'underground', 'bad: under the ground')
    H.ok(Near(r.groundZ, 36.0) and Near(r.dz, -5.0) and r.z == nil, 'the ground 5 m over the point, not put anywhere')
    H.eq(e.frozen, true, 'it stays frozen')
    H.eq(Called('SetEntityCoordsNoOffset'), 0, 'and is not moved')
    for _, c in ipairs(P.calls) do
        if c.name == 'FreezeEntityPosition' then H.eq(c.args[2], true, 'never let go') end
    end

    -- in water and a building's inside that never loads: bad, frozen
    Game(10.0)
    G.water = function() return 12.0 end
    e = P.entity(PED, { netId = 44, type = 1, owner = ME, frozen = true })
    Ask(44, { x = 0, y = 0, z = 11, kind = 'ped', token = 't-44' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.eq(Report().reason, 'in_water', 'in water')
    H.eq(Report().result, 'bad', 'is bad')
    H.eq(e.frozen, true, 'stays frozen')
    Game(10.0)
    Config.Spawning.interiorTimeoutMs = 1000
    G.interiors[7] = {
        at = function() return true end,
        ready = false,
    }
    e = P.entity(PED, { netId = 45, type = 1, owner = ME, frozen = true })
    Ask(45, { x = 0, y = 0, z = 11, kind = 'ped', token = 't-45' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().result == 'bad' and Report().reason == 'interior_not_loaded', 'bad: the inside never loaded')
    H.eq(e.frozen, true, 'stays frozen')
    Config.Spawning.interiorTimeoutMs = 5000

    -- a person in a wall: bad
    Game(30.0)
    G.wall = function() return true end
    e = P.entity(PED, { netId = 46, type = 1, owner = ME, frozen = true })
    Ask(46, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-46' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().result == 'bad' and Report().reason == 'in_wall', 'bad: in a wall')
    H.eq(e.frozen, true, 'stays frozen')
end

-- ============================================================================
--                           A VEHICLE AND AN OBJECT
-- ============================================================================

do
    -- a van at the road's height (the spawn audit's G5: its lower body in the road): on its wheels by its model's size
    Game(20.0)
    local hash = joaat('stockade')
    G.models[hash] = { mn = vec3(-1.3, -3.0, -0.9), mx = vec3(1.3, 3.0, 1.9), preloaded = true }
    local e = P.entity(VAN,
        { netId = 51, type = 2, model = hash, heading = 45.0, owner = ME, frozen = true, coords = vec3(5.0, 6.0, 20.0) })
    Ask(51, { x = 5, y = 6, z = 20, kind = 'vehicle', token = 't-51' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    local r = Report()
    H.ok(r.result == 'placed' and r.reason == 'ok', 'placed: a point at the road\'s height is inside its range')
    H.ok(Near(e.coords.z, 20.9) and Near(r.z, 20.9),
        'still lifted: its point 0.9 m over the road (-min.z of its model)')
    H.ok(e.onGround == true, 'then set on its wheels')
    H.eq(e.frozen, false, 'and let go')
    H.eq(e.keepTasks, false, 'a vehicle has no tasks to keep')
    H.ok(G.capsules[1] and G.capsules[1].ignore == VAN, 'its space is checked ignoring the van itself')
    local heading = nil
    for _, c in ipairs(G.calls) do if c.name == 'StartShapeTestCapsule' then heading = c.args end end
    H.ok(heading and Near(heading[1] - heading[4], -2 * math.sin(math.rad(45.0)) * (3.0 - 1.0)),
        'along the heading the van has in this game (the bag gave none)')

    -- an object 0.48 m under the road shoulder (the Manhunt clue): on the ground, still frozen
    Game(50.0)
    e = P.entity(BOX, { netId = 52, type = 3, owner = ME, frozen = true, coords = vec3(1.0, 2.0, 49.52) })
    Ask(52, { x = 1, y = 2, z = 49.52, kind = 'object', token = 't-52' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    r = Report()
    H.ok(r.result == 'placed' and r.reason == 'snap' and Near(e.coords.z, 50.0), 'an object is put on the ground')
    H.ok(e.onGround == true, 'placed on it properly')
    H.eq(e.frozen, true, 'and stays frozen')
    for _, c in ipairs(P.calls) do
        if c.name == 'FreezeEntityPosition' then H.eq(c.args[2], true, 'an object is never let go') end
    end
    H.eq(#G.capsules, 0, 'an object gets no wall probe')

    -- the kind from the entity when the bag gives none
    Game(50.0)
    e = P.entity(BOX, { netId = 53, type = 3, owner = ME, frozen = true, coords = vec3(1.0, 2.0, 50.2) })
    Ask(53, { x = 1, y = 2, z = 50.2, token = 't-53' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().reason == 'ok' and e.frozen == true and Near(e.coords.z, 50.0), 'an object by its type: ok, frozen')
end

-- ============================================================================
--                                WHO PLACES IT
-- ============================================================================

do
    -- not a participant (this player left the run): nothing at all
    Game(30.0)
    currentRun.participants[1].status = 'left'
    local e = P.entity(PED, { netId = 61, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 5.0) })
    Ask(61, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-61' })
    Settle(3000)
    H.eq(#Reports(), 0, 'a player who is no participant tells nothing')
    H.ok(#P.calls == 0 or (Called('FreezeEntityPosition') == 0 and Called('SetEntityCoordsNoOffset') == 0),
        'and touches nothing')
    H.ok(Near(e.coords.z, 5.0) and e.frozen == true, 'the entity is where it was')
    -- another run's entity, and no run
    Game(30.0)
    P.entity(PED, { netId = 62, type = 1, owner = ME, frozen = true })
    Bag(62, { run = 'run-9', state = 'idle', place = { x = 0, y = 0, z = 31, kind = 'ped', token = 'x' } })
    currentRun = nil
    Ask(62, { x = 0, y = 0, z = 31, kind = 'ped', token = 'y' })
    Settle(3000)
    H.eq(#Reports(), 0, 'another run\'s entity and an entity with no run of this player: nothing')
    H.eq(Called('FreezeEntityPosition'), 0, 'not touched')

    -- controlled by the partner's game: his game places it, this one does not ask for it
    Game(30.0)
    e = P.entity(PED, { netId = 63, type = 1, owner = PARTNER, frozen = true, grantMs = 0 })
    Ask(63, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-63' })
    Settle(3000)
    H.eq(#Reports(), 0, 'a person the partner\'s game controls: this game tells nothing')
    H.eq(Called('NetworkRequestControlOfEntity'), 0, 'and does not take him from the partner')

    -- a bystander's game controls it and this player is the participant nearest to it: control asked, placed
    Game(30.0)
    e = P.entity(PED, { netId = 64, type = 1, owner = BYSTANDER, frozen = true, grantMs = 300 })
    Ask(64, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-64' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Called('NetworkRequestControlOfEntity', PED) >= 1, 'control asked for')
    H.ok(Report().result == 'placed' and e.owner == ME and e.frozen == false and Near(e.coords.z, 31.0),
        'then placed and let go')
    -- nobody's game controls it: the same
    Game(30.0)
    e = P.entity(PED, { netId = 65, type = 1, owner = -1, frozen = true, grantMs = 0 })
    Ask(65, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-65' })
    H.ok(Until(function() return #Reports() == 1 end), 'an entity nobody controls is placed by the nearest participant')

    -- a bystander controls it and the partner is nearer to it: the partner's game places it
    Game(30.0)
    P.players[PARTNER].coords = vec3(0.0, -10.0, 30.0)
    e = P.entity(PED, { netId = 66, type = 1, owner = BYSTANDER, frozen = true, grantMs = 0 })
    Ask(66, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-66' })
    Settle(3000)
    H.eq(#Reports(), 0, 'the partner is nearer: this game leaves it to his')
    H.eq(Called('NetworkRequestControlOfEntity'), 0, 'and asks for nothing')
    -- the partner's ped is not streamed here (too far to know): this player is the nearest it knows
    Game(30.0)
    P.players[PARTNER] = nil
    e = P.entity(PED, { netId = 67, type = 1, owner = BYSTANDER, frozen = true, grantMs = 0 })
    Ask(67, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-67' })
    H.ok(Until(function() return #Reports() == 1 end), 'a participant this game does not know does not count')

    -- the bystander's game never lets go: nothing moved, nothing told; a later write of the bag tries again
    Game(30.0)
    e = P.entity(PED, { netId = 68, type = 1, owner = BYSTANDER, frozen = true, coords = vec3(0.0, 0.0, 29.0) })
    Ask(68, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-68' })
    Settle(4000)
    H.eq(#Reports(), 0, 'no control: nothing told')
    local stopped = 0
    for _, w in ipairs(H.findEvents('crimson-police:server:spawnChecking')) do
        if w.args[2].done == true and w.args[2].token == 't-68' then stopped = stopped + 1 end
    end
    H.eq(stopped, 1, 'but the server hears once that this game stopped checking it')
    H.ok(Near(e.coords.z, 29.0) and (P.ignored.SetEntityCoordsNoOffset or 0) == 0, 'and nothing moved')
    local asked = Called('NetworkRequestControlOfEntity', PED)
    H.ok(asked >= 1, 'control was asked for')
    e.grantMs = 0
    e.requestedAt = nil
    Ask(68, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-68' }, { state = 'hostile' })
    H.ok(Until(function() return #Reports() == 1 end), 'the next write of the same ask tries again and places it')

    -- the entity is not in this game yet (out of its range): nothing; it streams in later and its bag comes again
    Game(30.0)
    Ask(69, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-69' })
    Settle(4000)
    H.eq(#Reports(), 0, 'an entity this game does not have: nothing')
    local e69 = P.entity(PED, { netId = 69, type = 1, owner = ME, frozen = true })
    Ask(69, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-69' })
    H.ok(Until(function() return #Reports() == 1 end), 'once it streams in (the bag again) it is placed')
    H.eq(e69.frozen, false, 'and let go')
end

-- ============================================================================
--       SEATED, CUFFED, LOST, A NEW ASK, BAD BAGS, MANY AT ONCE, THE END
-- ============================================================================

do
    -- a person in a car goes where the car goes: not moved, let go
    Game(30.0)
    local e = P.entity(PED,
        { netId = 71, type = 1, owner = ME, frozen = true, seated = true, coords = vec3(0.0, 0.0, 30.6) })
    Ask(71, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-71' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().result == 'placed' and Report().reason == 'seated' and Report().groundZ == nil, 'placed, seated')
    H.ok(Near(e.coords.z, 30.6) and e.frozen == false, 'not moved, let go')
    -- anything attached to another entity: the same
    Game(30.0)
    e = P.entity(BOX, { netId = 72, type = 3, owner = ME, frozen = true, attached = true })
    Ask(72, { x = 0, y = 0, z = 31, kind = 'object', token = 't-72' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().reason == 'attached' and e.frozen == true and Called('SetEntityCoordsNoOffset') == 0,
        'an attached object: not moved, still frozen')

    -- a cuffed person (CP.Npc holds that pose frozen): put on the ground, kept frozen
    Game(30.0)
    e = P.entity(PED, { netId = 73, type = 1, owner = ME, frozen = true })
    Ask(73, { x = 0, y = 0, z = 31.5, kind = 'ped', token = 't-73' }, { state = 'cuffed' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().result == 'placed' and Near(e.coords.z, 31.0) and e.frozen == true,
        'placed, still frozen in his pose')

    -- another game takes the entity over while the ground loads: nothing moved, nothing told
    Game(30.0)
    G.collisionMs = 1000
    e = P.entity(PED, {
        netId = 74,
        type = 1,
        owner = ME,
        frozen = true,
        coords = vec3(0.0, 0.0, 33.0),
        loseAt = H.clockMs + 500,
        loseTo = BYSTANDER,
    })
    Ask(74, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-74' })
    Settle(6000)
    H.eq(#Reports(), 0, 'taken over during the check: not told')
    H.ok(Near(e.coords.z, 33.0), 'not moved')
    -- but the server hears this game stopped checking it, so its placeTimeoutMs runs on now (not after 45 s)
    local words = H.findEvents('crimson-police:server:spawnChecking')
    H.eq(#words, 2, 'the server was told this game checks it, then that it stopped')
    local first, second = words[1] and words[1].args or {}, words[2] and words[2].args or {}
    local stop = type(second[2]) == 'table' and second[2] or {}
    H.ok(
        type(first[2]) == 'table' and first[2].done == nil and second[1] == 'run-1' and stop.netId == 74
            and stop.token == 't-74' and stop.done == true,
        'the second word: done, with its run, net id and token'
    )

    -- a new ask (a new token) for the same net id is placed again
    Game(30.0)
    e = P.entity(PED, { netId = 75, type = 1, owner = ME, frozen = true })
    Ask(75, { x = 0, y = 0, z = 31, kind = 'ped', token = 'a' })
    H.ok(Until(function() return #Reports() == 1 end), 'first ask')
    e.frozen = true
    Ask(75, { x = 0, y = 0, z = 31, kind = 'ped', token = 'b' })
    H.ok(Until(function() return #Reports() == 2 end), 'a new token: placed again')
    H.eq(Report(2).token, 'b', 'with the new token')
    -- the ask withdrawn (a bag with no place) and the same token again: placed again
    Bag(75, { run = 'run-1', state = 'idle' })
    Ask(75, { x = 0, y = 0, z = 31, kind = 'ped', token = 'b' })
    H.ok(Until(function() return #Reports() == 3 end), 'after a bag without place the token counts as new')

    -- bags that ask nothing usable
    Game(30.0)
    P.entity(PED, { netId = 76, type = 1, owner = ME, frozen = true })
    Ask(76, { x = 'a', y = 0, z = 31, kind = 'ped', token = 't' })
    Ask(76, { x = 0, y = 0, z = 31, kind = 'ped' })
    Ask(76, { x = 0, y = 0, z = 31, kind = 'ped', token = { 1 } })
    Ask(76, { x = 0, y = 0, z = 31, kind = 'ped', token = 't' }, { state = 'dead' })
    Ask(76, { x = 0, y = 0, z = 31, kind = 'ped', token = 't' }, { run = 5 })
    Bag(76, 'nonsense')
    for _, h in ipairs(bagHandlers) do
        if h.key == 'cp' then
            h.fn('player:1', 'cp', { run = 'run-1', place = { x = 0, y = 0, z = 31, token = 'p' } }, 0, false)
        end
    end
    Settle(3000)
    H.eq(#Reports(), 0,
        'no numbers, no token, a table token, a dead one, no run id, no table, a player\'s bag: nothing')
    H.eq(Called('FreezeEntityPosition'), 0, 'nothing touched')

    -- a wave at once: four placed at a time, all told
    Game(30.0)
    G.collisionMs = 400
    local frozenBy = {}
    for i = 1, 6 do
        P.entity(9100 + i, { netId = 80 + i, type = 1, owner = ME, frozen = true, coords = vec3(i + 0.0, 0.0, 31.0) })
        Ask(80 + i, { x = i, y = 0, z = 31, kind = 'ped', token = 'w' .. i })
    end
    -- before any waits for its turn, the server hears this game checks each (its placeTimeoutMs then waits for it)
    Settle(50)
    local checking = H.findEvents('crimson-police:server:spawnChecking')
    H.eq(#checking, 6, 'the server is told this game checks every one of the wave, at once')
    local each = true
    for i = 1, 6 do
        local hit = 0
        for _, c in ipairs(checking) do
            if c.args[1] == 'run-1' and c.args[2].netId == 80 + i and c.args[2].token == 'w' .. i then hit = hit + 1 end
        end
        if hit ~= 1 then each = false end
    end
    H.ok(each, 'once each, with its run, net id and token')
    H.eq(#Reports(), 0, 'none placed yet')
    local most = 0
    Until(function()
        local busy = 0
        for i = 1, 6 do
            local started = false
            for _, c in ipairs(P.calls) do
                if c.name == 'SetEntityLoadCollisionFlag' and c.args[1] == 9100 + i then started = true end
            end
            local told = false
            for _, rep in ipairs(Reports()) do if rep.args[2].netId == 80 + i then told = true end end
            if started and not told then busy = busy + 1 end
        end
        if busy > most then most = busy end
        return #Reports() == 6
    end)
    H.eq(#Reports(), 6, 'every one of the wave is told')
    H.eq(most, 4, 'at most four are placed at once')
    H.eq(#H.findEvents('crimson-police:server:spawnChecking'), 6, 'and the server was told once per entity, no more')
    for i = 1, 6 do
        H.eq(P.entities[9100 + i].frozen, false, 'wave person ' .. i .. ' let go')
    end

    -- a wave a bystander's game controls (a far fight streamed in by a patrol car): four at a time also while control
    -- is asked for (the slot is taken first), all placed
    Game(30.0)
    G.collisionMs = 400
    for i = 1, 6 do
        P.entity(9100 + i, {
            netId = 80 + i,
            type = 1,
            owner = BYSTANDER,
            grantMs = 300,
            frozen = true,
            coords = vec3(i + 0.0, 0.0, 31.0),
        })
        Ask(80 + i, { x = i, y = 0, z = 31, kind = 'ped', token = 'b' .. i })
    end
    local mostAsking, mostProbing = 0, 0
    Until(function()
        local asking, probing = 0, 0
        for i = 1, 6 do
            local told = false
            for _, rep in ipairs(Reports()) do if rep.args[2].netId == 80 + i then told = true end end
            if not told then
                if (P.entities[9100 + i].requests or 0) > 0 then asking = asking + 1 end
                if Called('SetEntityLoadCollisionFlag', 9100 + i) > 0 then probing = probing + 1 end
            end
        end
        if asking > mostAsking then mostAsking = asking end
        if probing > mostProbing then mostProbing = probing end
        return #Reports() == 6
    end)
    H.eq(#Reports(), 6, 'every one of the bystander\'s wave is told')
    H.eq(mostAsking, 4, 'control is asked for four at a time')
    H.eq(mostProbing, 4, 'and four are placed at once')
    for i = 1, 6 do
        H.ok(P.entities[9100 + i].frozen == false and P.entities[9100 + i].owner == ME,
            'bystander wave person ' .. i .. ' placed and let go')
    end

    -- placed and let go already by a game that could not tell the server (its player left the run), and running now
    -- 12 m from the server's point: left where it is, not frozen, not moved back, told
    Game(30.0)
    e = P.entity(PED, { netId = 77, type = 1, owner = ME, frozen = false, coords = vec3(12.0, 0.0, 31.4) })
    Ask(77, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-77' }, { state = 'fleeing' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    local r = Report()
    H.ok(r.result == 'placed' and r.reason == 'moved' and Near(r.z, 31.4) and r.groundZ == nil,
        'placed: it has moved, at the height it stands at')
    H.eq(Called('FreezeEntityPosition'), 0, 'not frozen')
    H.eq(Called('SetEntityCoordsNoOffset'), 0, 'not moved back to the server\'s point')
    H.ok(e.frozen == false and Near(e.coords.x, 12.0), 'still running where he is')
    -- 2 m from it (a vehicle set on its wheels shifts a little): still placed as usual
    Game(30.0)
    e = P.entity(PED, { netId = 78, type = 1, owner = ME, frozen = true, coords = vec3(2.0, 0.0, 31.0) })
    Ask(78, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-78' })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().reason == 'ok' and Near(e.coords.x, 0.0) and e.frozen == false, 'near its point: placed on it')

    -- the server moved the ask to another point after a bad one (PLAN S10): he waits frozen at from, 30 m away; he
    -- is moved there first (so the ground loaded and probed is the one around him there), then put on the ground
    Game(30.0)
    e = P.entity(PED, { netId = 79, type = 1, owner = ME, frozen = true, coords = vec3(10.0, 20.0, 25.0) })
    Ask(79, { x = 40, y = 20, z = 31.5, h = 0, kind = 'ped', token = 't-79b', from = { x = 10, y = 20 } })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    r = Report()
    H.ok(r.result == 'placed' and r.reason == 'ok' and Near(r.z, 31.0), 'placed at the new point, not "moved"')
    H.ok(Near(e.coords.x, 40.0) and Near(e.coords.y, 20.0) and Near(e.coords.z, 31.0) and e.frozen == false,
        'standing on the ground at the new point, let go')
    local first, hc = nil, nil
    for i, c in ipairs(P.calls) do
        if c.name == 'SetEntityCoordsNoOffset' and not first then first = i end
    end
    for _, c in ipairs(G.calls) do if c.name == 'HasCollisionLoadedAroundEntity' and not hc then hc = c end end
    H.ok(first and Near(P.calls[first].args[2], 40.0) and Near(P.calls[first].args[4], 31.5),
        'first moved to the new point at its own height, frozen')
    H.eq(hc and hc.args[1], PED, 'the ground then loads around him there')
    -- far from both points: placed and let go before, as without from
    Game(30.0)
    e = P.entity(PED, { netId = 80, type = 1, owner = ME, frozen = false, coords = vec3(70.0, 20.0, 31.2) })
    Ask(80, { x = 40, y = 20, z = 31, kind = 'ped', token = 't-80b', from = { x = 10, y = 20 } })
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().reason == 'moved' and Near(e.coords.x, 70.0), 'far from both points: moved, left where he is')

    -- seated by the server while his ground loads (a pursuit's driver: the seat comes right after the ped is made):
    -- not moved, let go, told seated
    Game(30.0)
    G.collisionMs = 300
    e = P.entity(PED, { netId = 81, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 29.0) })
    Ask(81, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-81' })
    Settle(100)
    e.seated = true
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    H.ok(Report().reason == 'seated' and e.frozen == false and Near(e.coords.z, 29.0),
        'seated during the check: not moved, let go, told seated')
    -- set somewhere else by the server during the check: left there, let go, told moved
    Game(30.0)
    G.collisionMs = 300
    e = P.entity(PED, { netId = 82, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 31.0) })
    Ask(82, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-82' })
    Settle(100)
    e.coords = vec3(20.0, 0.0, 31.5)
    H.ok(Until(function() return #Reports() == 1 end), 'told')
    r = Report()
    H.ok(r.reason == 'moved' and Near(r.z, 31.5) and Near(e.coords.x, 20.0) and e.frozen == false,
        'moved away during the check: not moved back, let go, told moved')

    -- the run ends while the ground loads: the placement stops before it tells the server
    Game(30.0)
    G.collisionMs = 2000
    P.entity(PED, { netId = 91, type = 1, owner = ME, frozen = true })
    Ask(91, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-91' })
    Settle(500)
    H.fire('crimson-police:client:runEnded', nil, 'run-1', 'completed', 'completed')
    Settle(6000)
    H.eq(#Reports(), 0, 'the end of the run: nothing told for it')
    -- another run's end changes nothing
    Game(30.0)
    G.collisionMs = 1000
    P.entity(PED, { netId = 92, type = 1, owner = ME, frozen = true })
    Ask(92, { x = 0, y = 0, z = 31, kind = 'ped', token = 't-92' })
    Settle(200)
    H.fire('crimson-police:client:runEnded', nil, 'run-0', 'completed', 'completed')
    H.ok(Until(function() return #Reports() == 1 end), 'an earlier run\'s end does not stop this one')
end

H.eq(P.typeErrors, 0, 'every placer native got its arguments\' types')
H.eq(G.typeErrors, 0, 'every ground native got its arguments\' types')

P.restore()
G.restore()
return H
