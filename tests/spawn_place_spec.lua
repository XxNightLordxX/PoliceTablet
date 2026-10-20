-- The server's side of the placer (Config.Spawning.place, PLAN S10; modules/spawn/server.lua) on the real engine

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
local Runs = CP.Runs

H.load('modules/spawn/server.lua')
local Spawn = CP.Spawn
H.ok(type(Spawn) == 'table' and type(Spawn.ask) == 'function', 'CP.Spawn.ask on the server')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end

-- ============================================================================
--                         THE SHIPPED VALUES (README)
-- ============================================================================

H.eq(cfg.place, true, 'the placement ships on')
H.eq(cfg.placeTimeoutMs, 8000, 'an entity waits 8 s for an officer\'s game while an officer is near')
H.eq(cfg.retries, 2, 'two other points after a bad one')
H.eq(cfg.onTimeout, 'unfreeze', 'then it is let go where it stands, as before')

-- ============================================================================
--                 THE GAME THAT SIMULATES AN ENTITY (OneSync)
-- ============================================================================

local rpcs = {} -- every FreezeEntityPosition the server sent: { h, on, to = the owner's src, or 'queued' }
_G.FreezeEntityPosition = function(h, on)
    local e = W.ent(h)
    if not e then return end
    local owner = e.owner or -1
    if owner > 0 then
        e.frozenOn = e.frozenOn or {}
        e.frozenOn[owner] = on
        rpcs[#rpcs + 1] = { h = h, on = on, to = owner }
    else
        e.queued = e.queued or {}
        e.queued[#e.queued + 1] = on
        rpcs[#rpcs + 1] = { h = h, on = on, to = 'queued' }
    end
end
_G.NetworkGetEntityOwner = function(h)
    local e = W.ent(h)
    return e and e.owner or -1
end
-- The game of src takes the entity: the RPCs kept for the first game reach it.
local function Own(h, src)
    local e = W.ent(h)
    if (e.owner or -1) <= 0 then
        for _, on in ipairs(e.queued or {}) do
            e.frozenOn = e.frozenOn or {}
            e.frozenOn[src] = on
        end
        e.queued = nil
    end
    e.owner = src
end
local function FrozenHere(h)
    local e = W.ent(h)
    return e.frozenOn ~= nil and e.frozenOn[e.owner] == true
end
local function Rpcs(h, on)
    local out = {}
    for _, r in ipairs(rpcs) do if r.h == h and (on == nil or r.on == on) then out[#out + 1] = r end end
    return out
end

local function Warns(text)
    local out = {}
    for _, e in ipairs(CP.Problems.list({ tag = 'spawn', level = 'warn' })) do
        if e.text:find(text, 1, true) then out[#out + 1] = e end
    end
    return out
end

-- ============================================================================
--                               THE PROBE BLOCK
-- ============================================================================
-- Objective 'place_probe' makes what obj.make lists (kind, name, model, coords, alt) when it starts.

local made, dead = {}, {}
CP.Blocks.register('place_probe', {
    start = function(ctx)
        for _, s in ipairs(ctx.obj.make or {}) do
            local fn = ctx.spawnPed
            if s.kind == 'vehicle' then fn = ctx.spawnVehicle elseif s.kind == 'object' then fn = ctx.spawnObject end
            local _, netId = fn({
                model = s.model or 'g_m_y_lost_01',
                coords = s.coords,
                role = 'hostile',
                armed = s.kind == 'ped' or nil,
                weapon = s.kind == 'ped' and 'WEAPON_PISTOL' or nil,
                alt = s.alt,
            })
            made[s.name] = netId
        end
    end,
    onEntityDead = function(_, netId) dead[#dead + 1] = netId end,
})

-- Officers 1 and 2 on the run, 3 a bystander; the scene 60 m north of where the officers stand.
local function Scene(make)
    Reset()
    made, dead, rpcs = {}, {}, {}
    W.place(1, 100.0, 100.0)
    W.place(2, 104.0, 100.0)
    W.place(3, 100.0, 150.0)
    local m = W.mission(
        { { block = 'place_probe', label = 'Probe', make = make }, { block = 'stub_hold', label = 'Hold' } })
    local run = W.start({ 1, 2 }, m, { test = { adminSrc = 1 } })
    return run
end

local function Handle(run, netId) return run.entities[netId] and run.entities[netId].entity end
local function BagOf(run, netId) return (W.bags[Handle(run, netId)] or {}).cp end
local function Ask(run, netId) return (BagOf(run, netId) or {}).place end
local function Answer(src, run, netId, data)
    local d = { netId = netId, token = (Ask(run, netId) or {}).token }
    for k, v in pairs(data) do d[k] = v end
    H.fire('crimson-police:server:spawnPlaced', src, run.id, d)
end
local function EndRun(run)
    if run.state ~= 'ended' then Runs.endRun(run, 'failed', 'test') end
    W.tick(1)
end

-- ============================================================================
--            EVERY NEW ENTITY IS FROZEN AND ASKS FOR ITS PLACEMENT
-- ============================================================================

do
    local run = Scene({
        { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 90.0) },
        { name = 'van', kind = 'vehicle', model = 'speedo', coords = vec4(110.0, 165.0, 30.0, 180.0) },
        { name = 'box', kind = 'object', model = 'prop_box_wood02a', coords = vec3(95.0, 170.0, 30.0) },
    })
    H.eq(run.state, 'in_progress', 'the run is in progress')
    local ped, van, box = made.ped, made.van, made.box
    H.ok(ped and van and box, 'a person, a vehicle and an object')
    local a = Ask(run, ped)
    H.ok(type(a) == 'table', 'the person\'s cp bag asks for a placement')
    H.ok(a.x == 100.0 and a.y == 160.0 and a.z == 31.0 and a.h == 90.0 and a.kind == 'ped',
        'at the file\'s point and heading, as a person')
    H.eq(type(a.token), 'string', 'with a token')
    H.eq(a.from, nil, 'no from on a first ask')
    H.eq(Ask(run, van).kind, 'vehicle', 'the vehicle asks as a vehicle')
    H.eq(Ask(run, box).kind, 'object', 'the object as an object')
    H.ok(a.token ~= Ask(run, van).token and Ask(run, van).token ~= Ask(run, box).token, 'a token per entity')
    H.eq(Spawn.waiting(run.id), 3, 'three entities wait')
    -- the freeze: nobody simulates them yet, so FXServer keeps it for the first game that takes them
    H.eq(#Rpcs(Handle(run, ped), true), 1, 'the person is frozen on the server (one RPC)')
    H.eq(Rpcs(Handle(run, ped), true)[1].to, 'queued', 'kept for the first game that takes him')
    H.eq(#Rpcs(Handle(run, van), true), 1, 'the vehicle too')
    H.ok(#Rpcs(Handle(run, box), true) >= 1, 'and the object')
    -- the engine's copy keeps the ask, so CP.Npc's later writes carry it
    H.eq(run.entities[ped].bag.place.token, a.token, 'the engine\'s copy of the bag holds the ask')
    Own(Handle(run, ped), 1)
    W.tick(1)
    H.ok(FrozenHere(Handle(run, ped)), 'frozen on officer 1\'s game, which took him')
    H.eq(#Rpcs(Handle(run, ped), true), 1, 'not frozen again: his game is an officer\'s near him, it places him')
    CP.Npc.setState(run, ped, 'hostile')
    H.eq(Ask(run, ped).token, a.token, 'turned hostile: the bag still asks (CP.Npc\'s write keeps it)')
    H.eq(BagOf(run, ped).state, 'hostile', 'and is hostile')

    -- officer 1's game put him on the ground and let him go
    Answer(1, run, ped, { result = 'placed', reason = 'snap', groundZ = 29.5, dz = 1.5, z = 30.5 })
    H.eq(Ask(run, ped), nil, 'the answer is taken: the ask is out of the bag')
    H.eq(run.entities[ped].bag.place, nil, 'and out of the engine\'s copy')
    H.eq(#Rpcs(Handle(run, ped), false), 0, 'nothing is unfrozen here: the officer\'s game let him go')
    H.eq(Spawn.waiting(run.id), 2, 'two still wait')
    CP.Npc.setState(run, ped, 'fleeing')
    H.eq(Ask(run, ped), nil, 'a later write of CP.Npc does not bring the ask back')
    -- the same answer again changes nothing
    Answer(1, run, ped, { result = 'bad', reason = 'underground', token = a.token })
    H.eq(Ask(run, ped), nil, 'an answer for an ask that is over is ignored')

    -- answers that are not taken
    local vt = Ask(run, van).token
    Answer(1, run, van, { result = 'placed', reason = 'ok', z = 30.4, token = 'not-the-token' })
    H.eq(Ask(run, van).token, vt, 'a wrong token is ignored')
    Answer(3, run, van, { result = 'placed', reason = 'ok', z = 30.4 })
    H.eq(Ask(run, van).token, vt, 'a bystander\'s answer is ignored')
    H.fire('crimson-police:server:spawnPlaced', 1, 'another-run',
        { netId = van, token = vt, result = 'placed', z = 30.4 })
    H.eq(Ask(run, van).token, vt, 'an answer for another run is ignored')
    H.fire('crimson-police:server:spawnPlaced', 1, run.id, 'nonsense')
    H.eq(Ask(run, van).token, vt, 'an answer that is no table is ignored')
    Answer(1, run, van, { result = 'placed', reason = 'ok', z = 45.0 })
    H.eq(Ask(run, van).token, vt, 'a vehicle put 15 m over its point is not taken')
    H.eq(#Warns('too far from its point; not taken'), 1, 'with a warning')
    Answer(2, run, van, { result = 'placed', reason = 'ok', z = 31.2 })
    H.eq(Ask(run, van), nil, 'officer 2\'s answer is taken (any officer of the run)')
    -- an object stays frozen once placed
    Answer(1, run, box, { result = 'placed', reason = 'ok', z = 30.0 })
    H.eq(Ask(run, box), nil, 'the object is placed')
    H.eq(#Rpcs(Handle(run, box), false), 0, 'and never unfrozen')
    H.eq(Spawn.waiting(run.id), 0, 'nothing waits')
    EndRun(run)

    -- a person the game left as he was (seated in a car): let go from here too
    run = Scene({
        { name = 'driver', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) },
        { name = 'rider', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) },
        { name = 'car', kind = 'vehicle', model = 'sultan', coords = vec4(100.0, 160.0, 30.5, 0.0) },
    })
    Own(Handle(run, made.driver), 1)
    Answer(1, run, made.driver, { result = 'placed', reason = 'seated' })
    H.eq(Ask(run, made.driver), nil, 'seated: placed')
    H.eq(#Rpcs(Handle(run, made.driver), false), 1, 'and let go from here as well')
    -- a bad answer for one the server seated after the game checked his ground: placed, no other point, no warning
    SetPedIntoVehicle(Handle(run, made.rider), Handle(run, made.car), 0)
    Own(Handle(run, made.rider), 1)
    Answer(1, run, made.rider, { result = 'bad', reason = 'in_wall', groundZ = 30.0 })
    H.eq(Ask(run, made.rider), nil, 'a bad point for a seated person: placed')
    H.eq(#Rpcs(Handle(run, made.rider), false), 1, 'let go')
    H.eq(#Warns(('run %s: ped '):format(run.id)), 0, 'no warning: his seat is his place')
    EndRun(run)
end

-- ============================================================================
--                A BAD POINT: ANOTHER POINT, THEN KEPT AS IT IS
-- ============================================================================

do
    local run = Scene({
        {
            name = 'ped',
            kind = 'ped',
            coords = vec4(100.0, 160.0, 25.0, 0.0),
            alt = {
                { coords = vec4(101.0, 120.0, 30.0, 0.0), label = 'spawns[2]' }, -- 20 m from the officers: never
                { coords = vec4(130.0, 170.0, 31.0, 10.0), label = 'spawns[3]' },
                { coords = vec4(70.0, 170.0, 31.0, 20.0), label = 'spawns[4]' },
                { coords = vec4(60.0, 175.0, 31.0, 30.0), label = 'spawns[5]' },
            },
        },
        { name = 'other', kind = 'ped', coords = vec4(130.0, 170.5, 31.0, 0.0) }, -- stands on spawns[3]
    })
    local ped = made.ped
    Own(Handle(run, ped), 1)
    local first = Ask(run, ped)
    Answer(1, run, ped, { result = 'bad', reason = 'underground', groundZ = 31.4, dz = -6.4 })
    W.tick(2)
    local a = Ask(run, ped)
    H.ok(type(a) == 'table', 'a bad point: the bag asks again')
    H.ok(a.token ~= first.token, 'with a new token')
    H.ok(a.x == 70.0 and a.y == 170.0 and a.z == 31.0 and a.h == 20.0,
        'at the next point the director allows: not 20 m from the officers, not where another stands')
    H.ok(type(a.from) == 'table' and a.from.x == 100.0 and a.from.y == 160.0, 'from = where he waits')
    H.eq(#Warns(
        ('run %s: ped g_m_y_lost_01 at 100.00 160.00 25.00 is underground (ground 31.40); used spawns[4] (70.00 170.00 31.00) instead'):format(
            run.id)
    ), 1, 'one warning names the point, the reason, the ground and the point used instead')
    H.eq(#Rpcs(Handle(run, ped), false), 0, 'he still waits frozen')
    -- the old token is over
    Answer(1, run, ped, { result = 'placed', reason = 'ok', z = 25.0, token = first.token })
    H.eq(Ask(run, ped).token, a.token, 'a late answer for the old point is ignored')
    -- bad again: the last allowed point
    Answer(1, run, ped, { result = 'bad', reason = 'in_wall', groundZ = 30.0 })
    W.tick(2)
    local b = Ask(run, ped)
    H.ok(b and b.x == 60.0 and b.y == 175.0 and b.from.x == 70.0, 'a second bad point: the next one')
    -- bad a third time: Config.Spawning.retries (2) spent, kept where he is
    Answer(1, run, ped, { result = 'bad', reason = 'in_water', groundZ = 28.0 })
    W.tick(2)
    H.eq(Ask(run, ped), nil, 'retries spent: the ask is over')
    H.eq(#Rpcs(Handle(run, ped), false), 1, 'and he is let go where he is (as before)')
    H.eq(#Warns('is in_water (ground 28.00); used it there (Config.Spawning.retries = 2 spent)'), 1,
        'one warning says so')
    EndRun(run)

    -- no other point: kept at once
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 25.0, 0.0) } })
    Own(Handle(run, made.ped), 1)
    Answer(1, run, made.ped, { result = 'bad', reason = 'floating' })
    W.tick(1)
    H.eq(Ask(run, made.ped), nil, 'no other point: the ask is over')
    H.eq(#Warns('is floating (ground not found); used it there (no other point allowed)'), 1, 'and said')
    EndRun(run)

    -- retries = 0: the first point only
    run = Scene({
        { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 25.0, 0.0), alt = { vec4(70.0, 170.0, 31.0, 0.0) } },
    })
    cfg.retries = 0
    Own(Handle(run, made.ped), 1)
    Answer(1, run, made.ped, { result = 'bad', reason = 'underground', groundZ = 31.0 })
    W.tick(1)
    H.eq(Ask(run, made.ped), nil, 'retries = 0: never another point')
    EndRun(run)
end

-- ============================================================================
--                   NO ANSWER IN TIME, AND WHO SIMULATES IT
-- ============================================================================

do
    local run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) } })
    local h = Handle(run, made.ped)
    -- a bystander's game takes him: frozen there again (the first freeze reached him, the RPC goes to him)
    Own(h, 3)
    W.tick(1)
    H.ok(FrozenHere(h), 'frozen on the bystander\'s game')
    H.eq(#Rpcs(h, true), 2, 'the server froze him again for that game')
    -- then officer 2's game takes him: no freeze from here (his game places him)
    Own(h, 2)
    W.tick(1)
    H.eq(#Rpcs(h, true), 2, 'an officer\'s game near him: not frozen from here')
    W.tick(4)
    H.ok(Ask(run, made.ped) ~= nil, '6 s: still waiting')
    W.tick(3)
    H.eq(Ask(run, made.ped), nil, 'no answer within 8 s with an officer near: the ask is over')
    H.eq(#Rpcs(h, false), 1, 'and he is let go where he stands (onTimeout = unfreeze)')
    H.eq(#Warns('was not placed by an officer\'s game within 8000 ms; let go where it stands'), 1, 'one warning')
    EndRun(run)

    -- an answer after the server froze him again: let go from here too
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) } })
    h = Handle(run, made.ped)
    Own(h, 3)
    W.tick(1)
    Own(h, 1)
    W.tick(1)
    Answer(1, run, made.ped, { result = 'placed', reason = 'ok', z = 31.0 })
    H.eq(#Rpcs(h, false), 1, 'placed after a freeze from here: unfrozen from here as well')
    EndRun(run)

    -- the officers far away: he waits frozen (nobody can place him), no time runs
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 460.0, 31.0, 0.0) } })
    W.tick(30)
    H.ok(Ask(run, made.ped) ~= nil, 'officers 360 m away: still waiting after 30 s')
    H.eq(#Rpcs(Handle(run, made.ped), false), 0, 'frozen')
    W.place(1, 100.0, 380.0)
    W.tick(9)
    H.eq(Ask(run, made.ped), nil, 'an officer comes within 150 m: 8 s later he is let go')
    EndRun(run)

    -- onTimeout = 'delete': removed, and the objective counts him as gone
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) } })
    cfg.onTimeout = 'delete'
    local netId = made.ped
    h = Handle(run, netId)
    W.tick(9)
    H.eq(run.entities[netId], nil, 'onTimeout = delete: the run no longer has him')
    H.eq(W.ent(h).exists, false, 'deleted')
    H.eq(dead[1], netId, 'the objective learnt he is gone')
    H.eq(#Warns('within 8000 ms; removed'), 1, 'one warning')
    EndRun(run)
end

-- ============================================================================
--                       SWITCHED OFF, AND THE RUN'S END
-- ============================================================================

do
    -- the switch is turned off inside the block's start (W.start resets nothing, Reset() runs before it)
    local offKey = nil
    CP.Blocks.register('place_off', {
        start = function(ctx)
            cfg[offKey] = false
            local _, n = ctx.spawnPed({ model = 'g_m_y_lost_01', coords = vec4(100.0, 160.0, 31.0, 0.0), role = 'x' })
            made.ped = n
        end,
    })
    local function Off(key)
        offKey = key
        Reset()
        made, rpcs = {}, {}
        local m = W.mission({ { block = 'place_off', label = 'Off' }, { block = 'stub_hold', label = 'Hold' } })
        return W.start({ 1, 2 }, m, { test = { adminSrc = 1 } })
    end
    local run = Off('place')
    H.eq(Ask(run, made.ped), nil, 'place = false: no ask')
    H.eq(#Rpcs(Handle(run, made.ped)), 0, 'and no freeze (a person appears as before)')
    H.eq(Spawn.waiting(run.id), 0, 'nothing waits')
    EndRun(run)
    run = Off('enabled')
    H.eq(Ask(run, made.ped), nil, 'Config.Spawning.enabled = false: no ask either')
    EndRun(run)

    -- switched off in Settings while one waits: let go at the next check
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) } })
    cfg.place = false
    W.tick(1)
    H.eq(Ask(run, made.ped), nil, 'switched off: the ask is over')
    H.eq(#Rpcs(Handle(run, made.ped), false), 1, 'and he is let go')
    EndRun(run)

    -- the run ends while one waits
    run = Scene({ { name = 'ped', kind = 'ped', coords = vec4(100.0, 160.0, 31.0, 0.0) } })
    H.eq(Spawn.waiting(run.id), 1, 'one waits')
    EndRun(run)
    H.eq(Spawn.waiting(run.id), 0, 'the run ended: nothing waits')
end

-- ============================================================================
--                THE DIRECTOR'S SPARE POINTS (ctx.choosePoints)
-- ============================================================================

do
    local run = Scene({})
    local ctx = Runs.ctx(run, 1)
    local list = {}
    for i = 1, 5 do list[i] = { coords = vec4(80.0 + i * 8, 170.0, 31.0, 0.0), label = ('spawns[%d]'):format(i) } end
    cfg.preferHidden = false
    local chosen, _, spare = ctx.choosePoints(list, 2, { name = 'spawns' })
    H.eq(#chosen, 2, 'two chosen')
    H.eq(#spare, 3, 'the three others that passed are the spare points')
    local seen = {}
    for _, c in ipairs(chosen) do seen[c.label] = true end
    for _, c in ipairs(spare) do H.ok(not seen[c.label], 'spare ' .. c.label .. ' is not a chosen one') end
    -- a point too close to the officers is never spare
    list[6] = { coords = vec4(100.0, 110.0, 31.0, 0.0), label = 'spawns[6]' }
    _, _, spare = ctx.choosePoints(list, 2, { name = 'spawns' })
    for _, c in ipairs(spare) do H.ok(c.label ~= 'spawns[6]', 'the 10 m point is not spare') end
    EndRun(run)
end

-- ============================================================================
--                             A GANG SHOOTOUT WAVE
-- ============================================================================
-- (the real hostile_waves block): ANOTHER OF ITS POINTS.

do
    H.load('blocks/hostile_waves/server.lua')
    local HW = CP.Blocks.get('hostile_waves')
    Reset()
    cfg.preferHidden = false
    made, dead, rpcs = {}, {}, {}
    W.place(1, 100.0, 100.0)
    W.place(2, 104.0, 100.0)
    local spawns = {}
    for i = 1, 8 do spawns[i] = vec4(70.0 + i * 7.0, 175.0 + (i % 2) * 6.0, 31.0, 180.0) end
    local obj = HW.defaults({
        block = 'hostile_waves',
        label = 'Neutralise all hostiles',
        minSeconds = 0,
        waves = { 2 },
        weapons = { 'WEAPON_PISTOL' },
        accuracy = 10,
    })
    local m = W.mission({ obj, { block = 'stub_hold', label = 'Hold' } },
        { label = 'Yard', start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 }, spawns = spawns })
    local run = W.start({ 1, 2 }, m, { test = { adminSrc = 1, forcedTier = 'standard' } })
    W.tick(2)
    local peds = Runs.entitiesFor(run, { obj = 1, kind = 'ped' })
    H.eq(#peds, 2, 'wave 1: two hostiles')
    local used = {}
    for _, e in ipairs(peds) do
        local a = Ask(run, e.netId)
        H.ok(a ~= nil and a.kind == 'ped', 'each hostile asks for his placement')
        used[('%.2f,%.2f'):format(a.x, a.y)] = true
    end
    local netId = peds[1].netId
    local before = Ask(run, netId)
    Own(Handle(run, netId), 1)
    Answer(1, run, netId, { result = 'bad', reason = 'underground', groundZ = 36.0 })
    W.tick(2)
    local a = Ask(run, netId)
    H.ok(a ~= nil and a.token ~= before.token, 'a bad point: he waits for another one')
    local onList = false
    for _, p in ipairs(spawns) do if p.x == a.x and p.y == a.y then onList = true end end
    H.ok(onList, 'one of the location\'s spawn points')
    H.ok(not used[('%.2f,%.2f'):format(a.x, a.y)], 'not one a hostile of the wave already uses')
    H.ok(math.sqrt((a.x - 100.0) ^ 2 + (a.y - 100.0) ^ 2) >= cfg.minDistance, 'away from the officers')
    H.eq(#Warns(('run %s: ped '):format(run.id)), 1, 'one warning for him')
    H.ok(Warns(('run %s: ped '):format(run.id))[1].text:find('used spawns%[%d%] %(') ~= nil,
        'naming the spawn point used instead')
    -- a 'moved' answer (placed and let go before) is taken wherever he stands
    Answer(1, run, netId, { result = 'placed', reason = 'moved', z = 80.0 })
    H.eq(Ask(run, netId), nil, 'moved: taken, its height not checked')
    EndRun(run)
end

Reset()
return H
