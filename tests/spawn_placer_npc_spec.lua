-- The placer (modules/spawn/client.lua) and CP.Npc (modules/npc/client.lua) on one game (PLAN S9): CP.Npc tasks a
-- new person while the placer still checks his ground, and never lets him go before he is on it.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local G = H.groundNatives()
local P = H.placerNatives()
-- CP.Npc's other natives (combat, relationship groups, animations): recorded, answering nothing
local others = {}
H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^%u%l') then
        local f = function(...) others[#others + 1] = { name = k, args = table.pack(...) } end
        _G[k] = f
        return f
    end
    return nil
end)
local bags = {}
_G.Entity = function(e)
    bags[e] = bags[e] or {}
    return { state = bags[e] }
end
_G.IsEntityAPed = function(e) return P.entities[e] ~= nil and P.entities[e].type == 1 end
_G.IsPedAPlayer = function() return false end
_G.IsEntityDead = function() return false end
_G.GetResourceState = function() return 'started' end
H.exportsMock.ox_target = {
    addGlobalPed = function() end,
    removeGlobalPed = function() end,
    addGlobalVehicle = function() end,
    removeGlobalVehicle = function() end,
}
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn }
end
local currentRun = nil
CP.Runs = {
    current = function() return currentRun end,
}

local ME, PARTNER = 0, 1
local PED1, PED2, PED3 = 9001, 9002, 9003 -- a new handle for each person, as in the game
P.me = ME
P.players = {
    [ME] = { src = 1, ped = G.ped, coords = vec3(0.0, -60.0, 30.0) },
    [PARTNER] = { src = 2, ped = 5001, coords = vec3(0.0, -90.0, 30.0) },
}
H.load('modules/npc/client.lua')
H.load('modules/spawn/client.lua')

local EVENT = 'crimson-police:server:spawnPlaced'
local function Near(a, b) return type(a) == 'number' and math.abs(a - b) < 1e-6 end

-- this player (server id 1) hosts run-1 with his partner (2); flat ground at z
local function Game(z)
    G.reset()
    G.car = 0
    G.surfaces = { { z = z } }
    G.collisionMs = 1000
    G.interiors = {}
    G.water = nil
    G.wall = function() return false end
    G.capsuleFrames, G.capsuleStuck, G.capsuleFail, G.hitAs = 1, false, false, 1
    G.models = {}
    P.entities, P.ignored, P.calls = {}, {}, {}
    P.players[PARTNER].coords = vec3(0.0, -90.0, 30.0)
    others = {}
    currentRun = {
        id = 'run-1',
        isHost = true,
        participants = { { src = 1, status = 'active' }, { src = 2, status = 'active' } },
    }
    H.events = {}
end

-- the server writes the person's cp bag: in the bag first, then every handler (as the game runs them)
local function Bag(netId, ent, value)
    bags[ent] = bags[ent] or {}
    bags[ent].cp = value
    for _, h in ipairs(bagHandlers) do
        if h.key == 'cp' then h.fn('entity:' .. netId, 'cp', value, 0, false) end
    end
end

local function Write(netId, ent, state, place)
    Bag(netId, ent, {
        run = 'run-1',
        obj = 1,
        role = 'hostile',
        state = state,
        armed = false,
        cfg = { behaviour = 'aggressive' },
        place = place,
    })
end

local function Reports() return H.findEvents(EVENT) end

local function Placed()
    for _, c in ipairs(P.calls) do if c.name == 'SetEntityCoordsNoOffset' then return true end end
    return false
end

local function Fought(ent)
    for _, c in ipairs(others) do
        if c.name == 'SetPedRelationshipGroupHash' and c.args[1] == ent then return true end
    end
    return false
end

local function Settle(ms)
    local t0 = H.clockMs
    while H.clockMs - t0 < ms do H.step(16) end
end

-- ============================================================================
--                          THIS GAME HOSTS AND PLACES
-- ============================================================================
-- TOLD TO FIGHT WHILE ITS GROUND LOADS.

do
    -- the server makes him (place), and right away makes him hostile (hostile_waves Start: setState): the second write
    -- reaches CP.Npc, which takes him and tasks him to fight, while the placer still waits for his ground
    Game(30.0)
    local e = P.entity(PED1, { netId = 41, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 31.6) })
    local place = { x = 0, y = 0, z = 31.6, kind = 'ped', token = 't-41' }
    Write(41, PED1, 'idle', place)
    Settle(100)
    Write(41, PED1, 'hostile', place)
    local freedEarly, foughtAt, placedAt, frames = false, nil, nil, 0
    while #Reports() == 0 and frames < 1000 do
        H.step(16)
        frames = frames + 1
        if not foughtAt and Fought(PED1) then foughtAt = frames end
        if not placedAt and Placed() then placedAt = frames end
        if not placedAt and e.frozen ~= true then freedEarly = true end
    end
    H.eq(#Reports(), 1, 'the placer told the server')
    H.ok(foughtAt ~= nil and placedAt ~= nil and foughtAt < placedAt, 'CP.Npc tasked him to fight during the check')
    H.eq(freedEarly, false, 'and he stayed frozen until he was on the ground')
    H.ok(Near(e.coords.z, 31.0) and e.keepTasks == true, 'then put on the ground keeping the fight he was given')
    H.eq(e.frozen, false, 'and let go')
    H.eq(Reports()[1].args[2].result, 'placed', 'placed')
    -- the server takes the answer and drops the ask: nothing changes for him
    Write(41, PED1, 'hostile', nil)
    Settle(500)
    H.ok(e.frozen == false and Near(e.coords.z, 31.0), 'still on the ground, free')
end

-- ============================================================================
--              THE PARTNER'S GAME PLACES HIM, THIS ONE HOSTS HIM
-- ============================================================================

do
    -- the partner's game has him, so it places him; CP.Npc here takes him from it (the host fights him) while it
    -- checks, and keeps him frozen (this game may have no ground loaded where he stands) until the server drops the ask
    Game(30.0)
    local e = P.entity(PED2,
        { netId = 42, type = 1, owner = PARTNER, grantMs = 200, frozen = true, coords = vec3(0.0, 0.0, 31.0) })
    Write(42, PED2, 'hostile', { x = 0, y = 0, z = 31, kind = 'ped', token = 't-42' })
    local freed = false
    for _ = 1, 200 do
        H.step(16)
        if e.frozen ~= true then freed = true end
    end
    H.ok(Fought(PED2) and e.owner == ME, 'CP.Npc took him and tasked him to fight')
    H.eq(freed, false, 'he stays frozen while the server still asks for his placement')
    H.eq(#Reports(), 0, 'this game does not place him')
    H.eq(P.ignored.FreezeEntityPosition or 0, 0, 'what this game set on him was kept (it had him)')
    -- the server took the partner's answer: the ask is gone, CP.Npc lets him go here
    Write(42, PED2, 'hostile', nil)
    Settle(1000)
    H.eq(e.frozen, false, 'once the ask is gone this game lets him go')
end

-- ============================================================================
--                 A BAD POINT STAYS FROZEN WHATEVER HE IS TOLD
-- ============================================================================

do
    -- 5 m under the ground: told bad, and CP.Npc's fight that follows does not let him go (the server respawns him)
    Game(36.0)
    local e = P.entity(PED3, { netId = 43, type = 1, owner = ME, frozen = true, coords = vec3(0.0, 0.0, 31.0) })
    local place = { x = 0, y = 0, z = 31, kind = 'ped', token = 't-43' }
    Write(43, PED3, 'idle', place)
    local t0 = H.clockMs
    while #Reports() == 0 and H.clockMs - t0 < 20000 do H.step(16) end
    H.eq(Reports()[1] and Reports()[1].args[2].result, 'bad', 'told bad')
    Write(43, PED3, 'hostile', place)
    local freed = false
    for _ = 1, 200 do
        H.step(16)
        if e.frozen ~= true then freed = true end
    end
    H.ok(Fought(PED3), 'CP.Npc tasked him to fight')
    H.eq(freed, false, 'he stays frozen at the bad point')
    H.ok(Near(e.coords.z, 31.0), 'and is not moved')
end

H.eq(P.typeErrors, 0, 'every placer native got its arguments\' types')
H.eq(G.typeErrors, 0, 'every ground native got its arguments\' types')

P.restore()
G.restore()
return H
