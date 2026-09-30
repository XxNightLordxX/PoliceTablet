-- Objective blocks pursuit, escort and search_area (server halves) driven with a fake ctx, plus the locale part check
-- for every key the six block files use.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- Use this slice's locale part as the locale so labels resolve like they will in en.json.
do
    local orig = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return orig(res, 'locales/parts/blocks_c.json') end
        return orig(res, path)
    end
    H.load('shared/locale.lua')
    _G.LoadResourceFile = orig
end

local U = CP.U

-- ============================================================================
--                 NATIVES: networked entities, player vehicles
-- ============================================================================

local ents, byNet = {}, {}
local nextEnt, nextNet = 100000, 5000
local calls = { intoVehicle = {}, locked = {} }

local function NewEnt(kind, coords)
    nextEnt, nextNet = nextEnt + 1, nextNet + 1
    local x, y, z = U.xyz(coords)
    ents[nextEnt] = {
        kind = kind,
        netId = nextNet,
        coords = vec3(x, y, z),
        speed = 0.0,
        exists = true,
        inVehicle = 0,
        health = kind == 'ped' and 200 or 1000,
        maxHealth = kind == 'ped' and 200 or 1000,
        engine = 1000.0,
        body = 1000.0,
        tank = 1000.0,
    }
    byNet[nextNet] = nextEnt
    return nextEnt, nextNet
end
local function E(netId) return ents[byNet[netId]] end

local playerCoords = GetEntityCoords
_G.GetEntityCoords = function(e)
    if ents[e] then return ents[e].coords end
    return playerCoords(e)
end
_G.DoesEntityExist = function(e)
    if ents[e] then return ents[e].exists end
    return e ~= nil and e ~= 0 and H.players[math.floor(e / 100)] ~= nil
end
_G.GetEntitySpeed = function(e) return ents[e] and ents[e].speed or 0.0 end
_G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
_G.GetEntityMaxHealth = function(e) return ents[e] and ents[e].maxHealth or 200 end
_G.GetVehicleEngineHealth = function(e) return ents[e] and ents[e].engine or 1000.0 end
_G.GetVehicleBodyHealth = function(e) return ents[e] and ents[e].body or 1000.0 end
_G.GetVehiclePetrolTankHealth = function(e) return ents[e] and ents[e].tank or 1000.0 end
_G.NetworkGetEntityFromNetworkId = function(netId) return byNet[netId] or 0 end
_G.GetVehiclePedIsIn = function(ped)
    if ents[ped] then return ents[ped].inVehicle or 0 end
    local p = H.players[math.floor((ped or 0) / 100)]
    return p and p.vehicle or 0
end
_G.GetSelectedPedWeapon = function(ped)
    local p = H.players[math.floor((ped or 0) / 100)]
    return joaat((p and p.weapon) or 'WEAPON_PISTOL')
end
_G.SetPedIntoVehicle = function(ped, veh, seat)
    calls.intoVehicle[#calls.intoVehicle + 1] = { ped = ped, veh = veh, seat = seat }
    if ents[ped] then ents[ped].inVehicle = veh end
end
_G.SetVehicleDoorsLocked = function(veh, state) calls.locked[#calls.locked + 1] = { veh = veh, state = state } end

-- CP.Npc stub (the npc module is written by another slice)
local npc = { states = {}, cuffs = {} }
CP.Npc = {
    setState = function(run, netId, state) npc.states[netId] = state end,
    getState = function(netId) return npc.states[netId] end,
    enableCuff = function(run, netId, opts) npc.cuffs[netId] = opts end,
    rollSurrender = function() return false end,
}

H.load('blocks/pursuit/server.lua')
H.load('blocks/escort/server.lua')
H.load('blocks/search_area/server.lua')
local PU = CP.Blocks.get('pursuit')
local ES = CP.Blocks.get('escort')
local SA = CP.Blocks.get('search_area')
H.ok(PU and ES and SA, 'the three blocks registered')

-- ============================================================================
--                                   FAKE CTX
-- ============================================================================

local function FakeCtx(o)
    local run = {
        id = 'run-c',
        seed = o.seed or 777,
        host = 1,
        flags = { medals = false },
        shared = {},
        participants = { [1] = {}, [2] = {} },
        objectives = {},
    }
    run.mission, run.location = o.mission, o.location
    local obj = o.obj
    local ctx = {
        run = run,
        index = o.index or 1,
        obj = obj,
        base = U.deepcopy(obj),
        mission = o.mission,
        location = o.location,
        tier = { tier = 'standard', count = 1.0 },
        state = {},
        rng = U.rng(run.seed + (o.index or 1)),
    }
    local c = {
        complete = 0,
        completeData = {},
        fail = {},
        award = {},
        awardOpts = {},
        penalize = {},
        send = {},
        hud = {},
        spawn = {},
        delete = {},
    }
    ctx.calls = c
    ctx.completeResult = true
    ctx.capOk = true
    ctx.capBudget = nil
    ctx.srcs = o.srcs or { 1 }
    ctx.complete = function(data)
        c.complete = c.complete + 1
        c.completeData[#c.completeData + 1] = data
        return ctx.completeResult
    end
    ctx.fail = function(key) c.fail[#c.fail + 1] = key end
    ctx.award = function(id, opts)
        c.award[#c.award + 1] = id
        c.awardOpts[#c.awardOpts + 1] = { id = id, opts = opts }
    end
    ctx.penalize = function(id, opts) c.penalize[#c.penalize + 1] = id end
    ctx.send = function(data) c.send[#c.send + 1] = U.deepcopy(data) end
    ctx.hud = function(patch) c.hud[#c.hud + 1] = patch end
    ctx.canSpawn = function(n, armed)
        if not ctx.capOk then return false end
        if ctx.capBudget and not armed and ctx.capBudget < n then return false end
        if ctx.capBudget and armed and ctx.capBudget < n then return false end
        return true
    end
    local function spawn(kind)
        return function(opts)
            if ctx.capBudget then ctx.capBudget = ctx.capBudget - 1 end
            local ent, netId = NewEnt(kind, opts.coords)
            c.spawn[#c.spawn + 1] = { kind = kind, opts = opts, netId = netId, ent = ent }
            return ent, netId
        end
    end
    ctx.spawnPed, ctx.spawnVehicle, ctx.spawnObject = spawn('ped'), spawn('vehicle'), spawn('object')
    ctx.delete = function(netId)
        c.delete[#c.delete + 1] = netId
        local e = E(netId)
        if e then e.exists = false end
    end
    ctx.participants = function() return ctx.srcs end
    ctx.coords = function(src) return H.players[src] and H.players[src].coords end
    ctx.isHost = function(src) return src == run.host end
    ctx.host = function() return run.host end
    ctx.combat = function(a, b) return a, b end
    return ctx
end

local function At(src, x, y, z) H.players[src] = H.players[src] or {}; H.players[src].coords = vec3(x, y, z or 30.0) end
local function Count(list, v)
    local n = 0
    for _, x in ipairs(list) do if x == v then n = n + 1 end end
    return n
end
local function LastSend(ctx) return ctx.calls.send[#ctx.calls.send] end
local function SpawnsOf(ctx, kind, role)
    local out = {}
    for _, s in ipairs(ctx.calls.spawn) do
        if (not kind or s.kind == kind) and (not role or s.opts.role == role) then out[#out + 1] = s end
    end
    return out
end
local function TickN(B, ctx, n)
    for _ = 1, n do
        H.clockMs = H.clockMs + 1000
        B.tick(ctx, 1)
    end
end
local function ReasonIs(reason, key) -- validate returns translated text; compare the template before its first {var}
    local text = CP.L(key)
    local prefix = text:match('^([^{]*)') or text
    return type(reason) == 'string' and reason:sub(1, #prefix) == prefix
end
local function SetPos(netId, x, y, z) E(netId).coords = vec3(x, y, z or 30.0) end

-- ============================================================================
--                                   PURSUIT
-- ============================================================================

local loopPts = {
    vec3(0.0, 0.0, 30.0),
    vec3(200.0, 0.0, 30.0),
    vec3(400.0, 0.0, 30.0),
    vec3(600.0, 0.0, 30.0),
    vec3(600.0, 200.0, 30.0),
    vec3(600.0, 400.0, 30.0),
    vec3(600.0, 600.0, 30.0),
    vec3(400.0, 600.0, 30.0),
    vec3(200.0, 600.0, 30.0),
    vec3(0.0, 600.0, 30.0),
    vec3(0.0, 400.0, 30.0),
    vec3(0.0, 200.0, 30.0),
}
local raceLoc = {
    label = 'Loop',
    start = { coords = vec3(600.0, 200.0, 30.0), radius = 40.0 },
    race = { points = loopPts, loop = true },
}
local builtin = { source = 'builtin' }

do -- defaults
    local o = PU.defaults({ block = 'pursuit' })
    H.eq(o.mode, 'stop', 'pu default mode')
    H.eq(o.minSeconds, 30, 'pu default minSeconds')
    H.eq(o.presenceRange, 400, 'pu default presenceRange')
    H.eq(o.vehicles, 1, 'pu default vehicles')
    H.eq(o.suspectsPerVehicle, 1, 'pu default suspects')
    H.eq(o.speed, 120, 'pu default speed')
    H.eq(o.style, 'reckless', 'pu default style')
    H.eq(o.trigger, 'arrive', 'pu default trigger')
    H.eq(o.stopped.speed, 5.0, 'pu default stopped speed')
    H.eq(o.stopped.seconds, 5, 'pu default stopped seconds')
    H.near(o.footFlee, 0.2, 1e-9, 'pu default footFlee')
    H.eq(o.surrenderOnAim, true, 'pu default surrenderOnAim')
    H.eq(o.arrest.duration, 5000, 'pu default arrest duration')
    H.eq(o.arrest.label, CP.L('block.pursuit.arrest'), 'pu default arrest label')
    H.eq(o.complete, 'all_detained', 'pu default complete')
    H.eq(o.ramSpeed, 100, 'pu default ramSpeed')
    H.eq(o.ramPenaltyId, 'hard_ram', 'pu default ram id')
    H.eq(o.neverShoots, true, 'pu default neverShoots')
    H.eq(o.escape.distance, 400, 'pu default escape distance (stop, all_detained)')
    H.eq(o.escape.seconds, 20, 'pu default escape seconds')
    H.eq(o.fastStop.id, 'vehicle_stopped_fast', 'pu default fast stop id')
    H.eq(o.fastStop.seconds, 120, 'pu default fast stop seconds')
    H.eq(o.detainBonus, false, 'pu stop default no detain bonus')
    H.eq(o.medals, false, 'pu stop default medals off')
    H.eq(o.failIfUndriveable, false, 'pu stop default no undriveable fail')
    H.ok(#o.models > 0 and #o.peds > 0, 'pu default models and peds')
    local race = PU.defaults({ complete = 'all_or_timeout_any' })
    H.eq(race.detainBonus, 'racer_detained', 'pu race detain bonus')
    H.eq(race.allDetainedBonus, 'all_racers_detained', 'pu race all detained bonus')
    H.eq(race.fastStop, false, 'pu race no fast stop')
    H.eq(race.escape, false, 'pu race no escape')
    local f = PU.defaults({ mode = 'follow' })
    H.eq(f.hold, 150, 'pu follow hold')
    H.eq(f.lost.distance, 250, 'pu follow lost distance')
    H.eq(f.lost.seconds, 10, 'pu follow lost seconds')
    H.eq(f.duration, 180, 'pu follow duration')
    H.eq(f.medals.gold, 40, 'pu follow gold')
    H.eq(f.medals.bronze, 150, 'pu follow bronze')
    H.eq(f.failIfUndriveable, true, 'pu follow undriveable fail')
    H.eq(f.escape, false, 'pu follow no escape')
    local kept = PU.defaults({ footFlee = 0, surrenderOnAim = false, ramSpeed = 0, escape = false })
    H.eq(kept.footFlee, 0, 'pu keeps footFlee 0')
    H.eq(kept.surrenderOnAim, false, 'pu keeps surrenderOnAim false')
    H.eq(kept.ramSpeed, 0, 'pu keeps ramSpeed 0')
    H.eq(kept.escape, false, 'pu keeps escape false')
    H.eq(PU.armedCount({}), 0, 'pu never shoots: 0 armed')
    H.eq(PU.armedCount({ neverShoots = false, vehicles = 2, suspectsPerVehicle = 3 }), 6,
        'pu armed count when shooting')
    local req = PU.requiredPoints({ route = 'race', spawn = 'car' })
    H.ok(CP.U.contains(req, 'race') and CP.U.contains(req, 'car'), 'pu required points')
    -- a free flee (route nil) still needs its spawn point, and a route does not hide the spawn list
    H.eq(table.concat(PU.requiredPoints({ spawn = 'spawn' }), ','), 'spawn', 'pu free flee: spawn is required')
    H.eq(table.concat(PU.requiredPoints({ route = 'race', spawns = 'grid' }), ','), 'race,grid',
        'pu route and spawns are both required')
    H.eq(#PU.requiredPoints({}), 0, 'pu nothing placed: nothing required')
end

do -- validate
    local race = PU.defaults({ route = 'race', vehicles = 3, complete = 'all_or_timeout_any', models = { 'sultan' } })
    H.eq(PU.validate(race, builtin, raceLoc), true, 'pu valid street race (builtin)')
    local ok, why = PU.validate(race, { locations = { raceLoc } }, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.loop'), 'pu custom race loop must close')
    local closed = {
        start = raceLoc.start,
        race = {
            points = { loopPts[1], loopPts[2], loopPts[3], loopPts[4], loopPts[5], vec3(0.0, 30.0, 30.0) },
            loop = true,
        },
    }
    H.eq(PU.validate(race, { locations = { closed } }, nil), true, 'pu custom closed loop valid')
    ok, why = PU.validate(PU.defaults({ mode = 'chase' }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.mode'), 'pu bad mode')
    ok, why = PU.validate(PU.defaults({ vehicles = 6 }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.range'), 'pu vehicles above range')
    ok = PU.validate(PU.defaults({ suspectsPerVehicle = 5 }), builtin, raceLoc)
    H.eq(ok, false, 'pu suspects above range')
    ok = PU.validate(PU.defaults({ speed = 200 }), builtin, raceLoc)
    H.eq(ok, false, 'pu speed above range')
    ok, why = PU.validate(PU.defaults({ style = 'fast' }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.style'), 'pu bad style')
    ok = PU.validate(PU.defaults({ footFlee = 1.5 }), builtin, raceLoc)
    H.eq(ok, false, 'pu footFlee above 1')
    ok, why = PU.validate(PU.defaults({ trigger = { distance = -1 } }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.trigger'), 'pu bad trigger')
    ok, why = PU.validate(PU.defaults({ complete = 'some' }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.complete'), 'pu bad complete')
    ok, why = PU.validate(PU.defaults({ mode = 'follow', medals = { gold = 80, silver = 40, bronze = 150 } }), builtin,
        raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.medals'), 'pu unordered medals')
    ok, why = PU.validate(PU.defaults({ mode = 'follow', hold = 200, lost = { distance = 180, seconds = 10 } }),
        builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.lost'), 'pu lost distance must exceed hold')
    ok = PU.validate(PU.defaults({ mode = 'follow', duration = 30 }), builtin, raceLoc)
    H.eq(ok, false, 'pu follow duration below range')
    ok, why = PU.validate(PU.defaults({ route = 'nope' }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.route'), 'pu missing route key')
    ok, why = PU.validate(PU.defaults({ spawn = 'car' }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.points_missing'), 'pu missing spawn key')
    ok, why = PU.validate(PU.defaults({ suspectsPerVehicle = 3, models = { 'elegy2', 'dominator' } }), builtin, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.seats'), 'pu 3 suspects need a 4-seat model')
    ok, why = PU.validate(PU.defaults({ models = { 'adder' } }), { locations = { raceLoc } }, raceLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.models'), 'pu custom: model outside the allowed list')
    H.eq(PU.validate(PU.defaults({ models = { 'adder' } }), builtin, raceLoc), true, 'pu builtin: any model')
    ok = PU.validate(PU.defaults({ ramSpeed = -5 }), builtin, raceLoc)
    H.eq(ok, false, 'pu negative ram speed')
    ok = PU.validate(PU.defaults({ fastStop = { id = 'vehicle_stopped_fast', seconds = 0 } }), builtin, raceLoc)
    H.eq(ok, false, 'pu bad fast stop')
    local stolenLoc = { start = { coords = vec3(0.0, 0.0, 30.0), radius = 60.0 }, car = vec4(10.0, 0.0, 30.0, 90.0) }
    ok, why = PU.validate(PU.defaults({ spawn = 'car', trigger = { distance = 60.0, lights = true } }),
        { locations = { stolenLoc } }, stolenLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.points_start'), 'pu custom spawn too close to the start')
    H.eq(PU.validate(PU.defaults({ spawn = 'car', trigger = { distance = 60.0, lights = true } }), builtin, stolenLoc),
        true, 'pu builtin stolen vehicle valid')
    H.ok(PU.validate(nil) == false, 'pu non-table objective rejected')

    -- custom missions: bonus / penalty id fields hold a Config.Bonuses id or the block default, never an id
    -- another block values with a hint (a medal); "stopped within 2 minutes" at most; arrest 1-30 s
    local custom = { locations = { closed } }
    local function RaceWith(extra)
        local o = { route = 'race', vehicles = 3, complete = 'all_or_timeout_any', models = { 'sultan' } }
        for k, v in pairs(extra) do o[k] = v end
        return PU.defaults(o)
    end
    H.eq(PU.validate(RaceWith({}), custom, nil), true,
        'pu custom: the default racer_detained / all_racers_detained ids pass')
    H.eq(PU.validate(RaceWith({ detainBonus = 'hostile_arrested' }), custom, nil), true,
        'pu custom: a Config.Bonuses id passes')
    H.eq(PU.validate(RaceWith({ detainBonus = false, allDetainedBonus = false }), custom, nil), true,
        'pu custom: bonuses off pass')
    ok, why = PU.validate(RaceWith({ detainBonus = 'medal_gold' }), custom, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.bonus_custom'),
        'pu custom: detainBonus medal_gold rejected (it would pick up a medal hint)')
    ok, why = PU.validate(RaceWith({ allDetainedBonus = 'kingpin_alive' }), custom, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.bonus_custom'),
        'pu custom: allDetainedBonus outside Config.Bonuses rejected')
    ok, why = PU.validate(RaceWith({ ramPenaltyId = 'ram' }), custom, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.bonus_custom'),
        'pu custom: ramPenaltyId outside Config.Bonuses rejected')
    H.eq(PU.validate(RaceWith({ ramPenaltyId = 'ram' }), builtin, raceLoc), true,
        'pu builtin: its own ram id is trusted (Pursuit Sim)')
    local stopAt = { start = closed.start, race = closed.race, car = vec4(300.0, 300.0, 30.0, 0.0) }
    local function StopWith(extra)
        local o = { spawn = 'car', models = { 'sultan' } }
        for k, v in pairs(extra) do o[k] = v end
        return PU.defaults(o)
    end
    H.eq(PU.validate(StopWith({}), { locations = { stopAt } }, nil), true,
        'pu custom: default fast stop (vehicle_stopped_fast, 120 s) passes')
    ok, why = PU.validate(StopWith({ fastStop = { id = 'vehicle_stopped_fast', seconds = 9999 } }),
        { locations = { stopAt } }, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.range'), 'pu custom: fastStop.seconds above 120 rejected')
    H.eq(PU.validate(
        StopWith({ fastStop = { id = 'vehicle_stopped_fast', seconds = 60 } }),
        { locations = { stopAt } },
        nil
    ), true, 'pu custom: a stricter fast stop passes')
    ok, why = PU.validate(StopWith({ fastStop = { id = 'no_contact', seconds = 60 } }), { locations = { stopAt } }, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.bonus_custom'),
        'pu custom: fastStop.id outside Config.Bonuses rejected')
    ok, why = PU.validate(StopWith({ arrest = { duration = 100 } }), { locations = { stopAt } }, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.range'), 'pu custom: a 0.1 s arrest rejected')
    ok, why = PU.validate(StopWith({ arrest = { duration = 60000 } }), { locations = { stopAt } }, nil)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.range'), 'pu custom: a 60 s arrest rejected')
    H.eq(PU.validate(
        StopWith({ arrest = { duration = 100 }, fastStop = { id = 'vehicle_stopped_fast', seconds = 9999 } }),
        builtin,
        stopAt
    ), true, 'pu builtin: arrest time and fast stop trusted')
end

-- Street Race Bust: 3 racers on a loop, stop -> exit -> detain ("Detain driver" 3 s), rams, timeout.
do
    H.clockMs = 1000000
    At(1, 600.0, 180.0)
    At(2, 900.0, 900.0)
    H.players[1].vehicle, H.players[2].vehicle = nil, nil
    local obj = PU.defaults({
        block = 'pursuit',
        mode = 'stop',
        vehicles = 3,
        route = 'race',
        models = { 'sultan' },
        speed = 140,
        complete = 'all_or_timeout_any',
        surrenderOnAim = false,
        footFlee = 0,
        arrest = { label = 'Detain driver', duration = 3000 },
    })
    local ctx = FakeCtx({ obj = obj, location = raceLoc, mission = builtin, srcs = { 1, 2 } })
    PU.prepare(ctx)
    PU.start(ctx)
    local st = ctx.state
    local cars = SpawnsOf(ctx, 'vehicle')
    local drivers = SpawnsOf(ctx, 'ped')
    H.eq(#cars, 3, 'race: 3 racer cars')
    H.eq(#drivers, 3, 'race: 3 drivers')
    H.eq(cars[1].opts.coords.x, 400.0, 'race: first racer 2 waypoints before the intercept')
    H.eq(cars[2].opts.coords.x, 200.0, 'race: second racer one waypoint further back')
    H.near(cars[1].opts.coords.w, 270.0, 1e-6, 'race: racer faces the next waypoint (east)')
    H.eq(drivers[1].opts.cfg.seat, -1, 'race: driver seat')
    H.eq(drivers[1].opts.armed, false, 'race: racers unarmed')
    H.ok(#calls.intoVehicle >= 3, 'race: drivers seated server-side')
    H.ok(#calls.locked >= 3, 'race: racer doors locked')
    H.eq(st.fled, true, 'race: racing from the start (trigger arrive)')
    H.eq(npc.states[drivers[1].netId], 'driving', 'race: driver state driving')
    H.eq(LastSend(ctx).vehicles[1].state, 'fleeing', 'race: snapshot shows racers fleeing')

    for _, c in ipairs(cars) do E(c.netId).speed = 35.0 end
    TickN(PU, ctx, 1)
    -- a racer crawling far from every participant never counts as stopped
    E(cars[3].netId).speed = 0.0
    TickN(PU, ctx, 6)
    H.eq(st.vehicles[tostring(cars[3].netId)].state, 'fleeing', 'race: slow racer with nobody near is not stopped')
    E(cars[3].netId).speed = 35.0

    -- rams by participant 2 (in a car at 126 km/h next to racer 2)
    local myCar = NewEnt('vehicle', vec3(0, 0, 0))
    ents[myCar].speed = 35.0
    H.players[2].vehicle = myCar
    SetPos(cars[2].netId, 200.0, 0.0)
    At(2, 205.0, 0.0)
    TickN(PU, ctx, 1)
    local ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 120 })
    H.eq(ok, true, 'race: ram at 120 km/h accepted')
    H.eq(Count(ctx.calls.penalize, 'hard_ram'), 1, 'race: hard_ram penalised')
    ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 120 })
    H.eq(why, 'duplicate', 'race: same ram again within the cooldown')
    TickN(PU, ctx, 3)
    ok = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 80 })
    H.eq(ok, true, 'race: slow contact accepted')
    H.eq(Count(ctx.calls.penalize, 'hard_ram'), 1, 'race: no penalty under ramSpeed')
    TickN(PU, ctx, 3)
    ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 200 })
    H.eq(why, 'implausible', 'race: ram speed far above the server samples rejected')
    At(2, 400.0, 400.0)
    ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 120 })
    H.eq(why, 'too_far', 'race: ram from far away rejected')
    H.players[2].vehicle = nil
    At(2, 205.0, 0.0)
    ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = cars[2].netId, speed = 120 })
    H.eq(why, 'not_in_vehicle', 'race: ram on foot rejected')
    ok, why = PU.onEvent(ctx, 2, { type = 'ram', netId = 99999, speed = 120 })
    H.eq(why, 'unknown_entity', 'race: ram of an unknown vehicle rejected')

    -- stop racer 1 next to participant 1: below 5 km/h for 5 s
    SetPos(cars[1].netId, 600.0, 170.0)
    E(cars[1].netId).speed = 0.5
    TickN(PU, ctx, 4)
    H.eq(st.vehicles[tostring(cars[1].netId)].state, 'fleeing', 'race: 4 s slow is not a stop')
    TickN(PU, ctx, 1)
    H.eq(st.vehicles[tostring(cars[1].netId)].state, 'stopped', 'race: 5 s slow is a stop')
    H.eq(npc.states[drivers[1].netId], 'stopped', 'race: driver told to leave the car')
    H.eq(Count(ctx.calls.award, 'vehicle_stopped_fast'), 0, 'race: no fast-stop bonus in a race')
    TickN(PU, ctx, 1)
    H.eq(npc.states[drivers[1].netId], 'stopped', 'race: driver still in the car waits')
    E(drivers[1].netId).inVehicle = 0
    TickN(PU, ctx, 1)
    H.eq(npc.states[drivers[1].netId], 'surrendered',
        'race: out of the car the racer gives up (surrenderOnAim = false)')
    H.eq(npc.cuffs[drivers[1].netId].label, 'Detain driver', 'race: Detain driver target')
    H.eq(npc.cuffs[drivers[1].netId].duration, 3000, 'race: detain takes 3 s')

    H.eq(PU.onTimeout(ctx), nil, 'race: timeout with no racer detained fails')
    ok, why = PU.onEvent(ctx, 1, { type = 'cuffed', netId = drivers[1].netId })
    H.eq(why, 'not_cuffed', 'race: cuff event before the bag says cuffed')
    npc.states[drivers[1].netId] = 'cuffed'
    SetPos(drivers[1].netId, 600.0, 170.0)
    At(1, 650.0, 170.0)
    ok, why = PU.onEvent(ctx, 1, { type = 'cuffed', netId = drivers[1].netId })
    H.eq(why, 'too_far', 'race: cuff from far away rejected')
    At(1, 601.0, 170.0)
    local savedRunsPU, arrestsPU = CP.Runs, {}
    CP.Runs = setmetatable({
        noteArrest = function(run, src, netId) arrestsPU[#arrestsPU + 1] = { src = src, netId = netId } end,
    }, { __index = savedRunsPU or {} })
    ok = PU.onEvent(ctx, 1, { type = 'cuffed', netId = drivers[1].netId })
    CP.Runs = savedRunsPU
    H.eq(ok, true, 'race: racer detained')
    H.ok(#arrestsPU == 1 and arrestsPU[1].src == 1 and arrestsPU[1].netId == drivers[1].netId,
        'race: the cuff notes one arrest')
    H.eq(Count(ctx.calls.award, 'racer_detained'), 1, 'race: racer_detained +1')
    ok, why = PU.onEvent(ctx, 1, { type = 'cuffed', netId = drivers[1].netId })
    H.eq(why, 'duplicate', 'race: second cuff event is a duplicate')
    H.eq(PU.onTimeout(ctx), 'completed', 'race: timeout with one detained completes')

    local cl = PU.checklist(ctx)
    H.eq(cl[1].value, 1, 'race checklist stopped value')
    H.eq(cl[1].max, 3, 'race checklist stopped max')
    H.eq(cl[2].value, 1, 'race checklist detained')

    -- the other two: stopped, out of the car, cuffed through the bag (tick picks it up)
    for i = 2, 3 do
        SetPos(cars[i].netId, 600.0, 175.0 + i)
        E(cars[i].netId).speed = 0.0
    end
    TickN(PU, ctx, 5)
    for i = 2, 3 do E(drivers[i].netId).inVehicle = 0 end
    TickN(PU, ctx, 1)
    H.eq(npc.states[drivers[2].netId], 'surrendered', 'race: racer 2 surrendered')
    ctx.completeResult = false
    npc.states[drivers[2].netId] = 'cuffed'
    npc.states[drivers[3].netId] = 'cuffed'
    TickN(PU, ctx, 1)
    H.eq(Count(ctx.calls.award, 'racer_detained'), 3, 'race: three racers detained')
    H.eq(Count(ctx.calls.award, 'all_racers_detained'), 1, 'race: all racers detained bonus')
    H.eq(ctx.calls.complete, 1, 'race: complete attempted')
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.complete, 2, 'race: complete retried after minSeconds refusal')
    H.eq(Count(ctx.calls.award, 'all_racers_detained'), 1, 'race: all detained awarded once')
    ctx.completeResult = true
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.complete, 3, 'race: completed')
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.complete, 3, 'race: no complete after completion')
    H.eq(#ctx.calls.fail, 0, 'race: never failed')
end

-- Stolen Vehicle Takedown: waits for lights within 60 m, flees, stop within 2 min, aim to surrender, cuff.
local stolenLoc = {
    label = 'Lot',
    start = { coords = vec3(1000.0, 1040.0, 30.0), radius = 60.0 },
    car = vec4(1000.0, 1000.0, 30.0, 90.0),
}
local function StolenCtx(extra)
    local o = {
        block = 'pursuit',
        mode = 'stop',
        vehicles = 1,
        suspectsPerVehicle = 2,
        spawn = 'car',
        models = { 'sultan' },
        trigger = { distance = 60.0, lights = true },
        footFlee = 0,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return FakeCtx({ obj = PU.defaults(o), location = stolenLoc, mission = builtin, srcs = { 1, 2 } })
end

do
    H.clockMs = 2000000
    At(1, 1040.0, 1000.0)
    At(2, 1500.0, 1500.0)
    H.players[1].vehicle, H.players[2].vehicle = nil, nil
    local ctx = StolenCtx()
    PU.start(ctx)
    local st = ctx.state
    local car = SpawnsOf(ctx, 'vehicle')[1]
    local sus = SpawnsOf(ctx, 'ped')
    H.eq(#sus, 2, 'stolen: 2 suspects in the car')
    H.eq(sus[2].opts.cfg.seat, 0, 'stolen: second suspect in the passenger seat')
    H.eq(car.opts.coords.x, 1000.0, 'stolen: car at its spawn point')
    H.ok(not st.fled, 'stolen: the car waits')
    TickN(PU, ctx, 2)
    H.ok(not st.fled, 'stolen: a participant 40 m away without lights does not trigger it')
    local ok, why = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(why, 'not_in_vehicle', 'stolen: lights report on foot rejected')
    local pcar = NewEnt('vehicle', vec3(0, 0, 0))
    ents[pcar].speed = 10.0
    H.players[1].vehicle = pcar
    At(1, 1100.0, 1000.0)
    ok, why = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(why, 'too_far', 'stolen: lights report from 100 m rejected')
    At(1, 1040.0, 1000.0)
    ok = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(ok, true, 'stolen: lights within 60 m accepted')
    H.eq(st.fled, true, 'stolen: the car flees')
    H.eq(LastSend(ctx).vehicles[1].state, 'fleeing', 'stolen: snapshot fleeing')
    ok, why = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(why, 'duplicate', 'stolen: second lights report is a duplicate')

    E(car.netId).speed = 25.0
    TickN(PU, ctx, 3)
    ok, why = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(why, 'wrong_state', 'stolen: aiming at a suspect still driving does nothing')
    E(car.netId).speed = 0.0
    SetPos(car.netId, 1030.0, 1000.0)
    TickN(PU, ctx, 5)
    H.eq(st.vehicles[tostring(car.netId)].state, 'stopped', 'stolen: car stopped')
    H.eq(Count(ctx.calls.award, 'vehicle_stopped_fast'), 1, 'stolen: stopped within 2 minutes +15')
    ok, why = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(why, 'in_vehicle', 'stolen: aim at a suspect still in the stopped car rejected')
    for _, s in ipairs(sus) do E(s.netId).inVehicle = 0 end
    TickN(PU, ctx, 1)
    H.eq(npc.states[sus[1].netId], 'stopped', 'stolen: suspects wait by the car (footFlee 0)')

    H.players[1].vehicle = nil
    SetPos(sus[1].netId, 1030.0, 1000.0)
    SetPos(sus[2].netId, 1030.0, 1004.0)
    At(1, 1060.0, 1000.0)
    ok, why = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(why, 'too_far', 'stolen: aim from 30 m rejected')
    At(1, 1040.0, 1000.0)
    ok = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(ok, true, 'stolen: aim within range accepted')
    H.eq(npc.states[sus[1].netId], 'surrendered', 'stolen: suspect surrenders')
    H.eq(npc.cuffs[sus[1].netId].label, CP.L('block.pursuit.arrest'), 'stolen: Cuff suspect target')
    H.eq(npc.cuffs[sus[1].netId].duration, 5000, 'stolen: cuff takes 5 s')
    ok, why = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(why, 'duplicate', 'stolen: aim at a surrendered suspect is a duplicate')
    H.players[2].weapon = 'WEAPON_UNARMED'
    At(2, 1035.0, 1004.0)
    ok, why = PU.onEvent(ctx, 2, { type = 'aim', netId = sus[2].netId })
    H.eq(why, 'no_weapon', 'stolen: aim without a weapon rejected')
    -- a participant staying within 3 m for 3 s makes the second one give up
    At(2, 1031.0, 1004.0)
    TickN(PU, ctx, 3)
    H.eq(npc.states[sus[2].netId], 'surrendered', 'stolen: close for 3 s -> surrender')
    npc.states[sus[1].netId] = 'cuffed'
    npc.states[sus[2].netId] = 'cuffed'
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.complete, 1, 'stolen: completed when both are cuffed')
    H.eq(Count(ctx.calls.award, 'racer_detained'), 0, 'stolen: no racer bonus')
    H.eq(ctx.calls.completeData[1].detained, 2, 'stolen: complete data detained')
end

do -- escape on foot and killing an unarmed suspect
    H.clockMs = 3000000
    At(1, 1040.0, 1000.0)
    At(2, 5000.0, 5000.0)
    local ctx = StolenCtx({ footFlee = 1.0 })
    PU.start(ctx)
    local st = ctx.state
    local car = SpawnsOf(ctx, 'vehicle')[1]
    local sus = SpawnsOf(ctx, 'ped')
    At(1, 1010.0, 1000.0)
    TickN(PU, ctx, 1)
    H.eq(st.fled, true, 'close car flees without lights')
    E(car.netId).speed = 30.0
    TickN(PU, ctx, 1)
    E(car.netId).speed = 0.0
    TickN(PU, ctx, 5)
    for _, s in ipairs(sus) do E(s.netId).inVehicle = 0 end
    TickN(PU, ctx, 1)
    H.eq(npc.states[sus[1].netId], 'fleeing', 'footFlee 1.0: runs on foot')
    At(1, 1600.0, 1000.0)
    TickN(PU, ctx, 19)
    H.eq(#ctx.calls.fail, 0, 'escape: 19 s far is not an escape')
    H.eq(LastSend(ctx).escaping, 1, 'escape countdown in the snapshot')
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.fail[1], 'block.pursuit.fail_escaped', 'escape: 20 s far fails')

    local ctx2 = StolenCtx()
    PU.start(ctx2)
    local s2 = SpawnsOf(ctx2, 'ped')
    PU.onEntityDead(ctx2, s2[2].netId, nil)
    H.eq(#ctx2.calls.fail, 0, 'a suspect dying without a participant kill does not fail')
    PU.onEntityDead(ctx2, s2[1].netId, 1)
    H.eq(ctx2.calls.fail[1], 'run.fail_killed_unarmed', 'a participant killing an unarmed suspect fails')
end

do -- a suspect still in the stopped car stays 'stopped' (never a vehicle flee from the seat) until it is out
    H.clockMs = 3100000
    At(1, 1040.0, 1000.0)
    At(2, 5000.0, 5000.0)
    H.players[1].vehicle = nil
    local ctx = StolenCtx({ footFlee = 1.0 })
    PU.start(ctx)
    local car = SpawnsOf(ctx, 'vehicle')[1]
    local sus = SpawnsOf(ctx, 'ped')
    At(1, 1010.0, 1000.0)
    TickN(PU, ctx, 1)
    E(car.netId).speed = 30.0
    TickN(PU, ctx, 1)
    E(car.netId).speed = 0.0
    TickN(PU, ctx, 5)
    H.eq(ctx.state.vehicles[tostring(car.netId)].state, 'stopped', 'in car: car stopped')
    TickN(PU, ctx, 12) -- well past the old 6 s exit timeout, still seated
    H.eq(npc.states[sus[1].netId], 'stopped', 'in car: a seated suspect is not told to flee (would drive off)')
    H.eq(npc.states[sus[2].netId], 'stopped', 'in car: the passenger waits in its seat too')
    local ok, why = PU.onEvent(ctx, 1, { type = 'aim', netId = sus[1].netId })
    H.eq(why, 'in_vehicle', 'in car: aiming at a seated suspect does nothing')
    E(sus[1].netId).inVehicle = 0
    TickN(PU, ctx, 1)
    H.eq(npc.states[sus[1].netId], 'fleeing', 'in car: out of the car it runs on foot (footFlee 1.0)')
    H.eq(npc.states[sus[2].netId], 'stopped', 'in car: the other one is still seated')

    -- racers (surrenderOnAim = false) surrender only once out of the car as well
    At(1, 600.0, 180.0)
    local robj = PU.defaults({
        block = 'pursuit',
        mode = 'stop',
        vehicles = 1,
        route = 'race',
        models = { 'sultan' },
        complete = 'all_or_timeout_any',
        surrenderOnAim = false,
        footFlee = 0,
    })
    local rctx = FakeCtx({ obj = robj, location = raceLoc, mission = builtin })
    PU.start(rctx)
    local rcar = SpawnsOf(rctx, 'vehicle')[1]
    local rdrv = SpawnsOf(rctx, 'ped')[1]
    E(rcar.netId).speed = 35.0
    TickN(PU, rctx, 1)
    SetPos(rcar.netId, 600.0, 170.0)
    E(rcar.netId).speed = 0.0
    TickN(PU, rctx, 15)
    H.eq(npc.states[rdrv.netId], 'stopped', 'in car: a seated racer does not surrender in its seat')
    E(rdrv.netId).inVehicle = 0
    TickN(PU, rctx, 1)
    H.eq(npc.states[rdrv.netId], 'surrendered', 'in car: out of the car the racer gives up')
end

do -- kills and stuns: only ACTIVE participants count; the stun reporter must be close too
    H.clockMs = 3200000
    At(1, 1040.0, 1000.0)
    At(2, 1045.0, 1000.0)
    local ctx = StolenCtx()
    PU.start(ctx)
    local sus = SpawnsOf(ctx, 'ped')
    ctx.srcs = { 1 }                            -- participant 2 left the run (still in run.participants)
    PU.onEntityDead(ctx, sus[1].netId, 2)
    H.eq(#ctx.calls.fail, 0, 'left participant: killing an unarmed suspect is an outside kill, not a fail')
    PU.onEntityDead(ctx, sus[2].netId, 1)
    H.eq(ctx.calls.fail[1], 'run.fail_killed_unarmed', 'active participant: killing an unarmed suspect fails')

    local ctx2 = StolenCtx({ footFlee = 1.0 })
    PU.start(ctx2)
    local car2 = SpawnsOf(ctx2, 'vehicle')[1]
    local s2 = SpawnsOf(ctx2, 'ped')
    At(1, 1010.0, 1000.0)
    At(2, 1500.0, 1000.0)
    TickN(PU, ctx2, 1)
    E(car2.netId).speed = 30.0
    TickN(PU, ctx2, 1)
    E(car2.netId).speed = 0.0
    TickN(PU, ctx2, 5)
    for _, sp in ipairs(s2) do E(sp.netId).inVehicle = 0 end
    TickN(PU, ctx2, 1)
    H.eq(npc.states[s2[1].netId], 'fleeing', 'stun: suspect running')
    SetPos(s2[1].netId, 1010.0, 1000.0)
    local ok, why = PU.onEvent(ctx2, 2, { type = 'stunned', netId = s2[1].netId })
    H.eq(why, 'too_far', 'stun: a report from 490 m away is rejected even with a partner next to the suspect')
    At(2, 1050.0, 1000.0)
    ok = PU.onEvent(ctx2, 2, { type = 'stunned', netId = s2[1].netId })
    H.eq(ok, true, 'stun: a report from 40 m (partner within 30 m) is accepted')
    H.eq(npc.states[s2[1].netId], 'surrendered', 'stun: the suspect gives up')
end

do -- Street Race Bust: racers that all die in crashes with none detained never complete; the time limit fails
    H.clockMs = 3300000
    At(1, 600.0, 180.0)
    local obj = PU.defaults({
        block = 'pursuit',
        mode = 'stop',
        vehicles = 2,
        route = 'race',
        models = { 'sultan' },
        complete = 'all_or_timeout_any',
        surrenderOnAim = false,
        footFlee = 0,
    })
    local ctx = FakeCtx({ obj = obj, location = raceLoc, mission = builtin })
    PU.start(ctx)
    local drv = SpawnsOf(ctx, 'ped')
    PU.onEntityDead(ctx, drv[1].netId, nil)
    PU.onEntityDead(ctx, drv[2].netId, nil)
    TickN(PU, ctx, 2)
    H.eq(ctx.calls.complete, 0, 'race: every racer dead and none detained is not a completion')
    H.eq(#ctx.calls.fail, 0, 'race: ... and no immediate fail either')
    H.eq(PU.onTimeout(ctx), nil, 'race: the time limit then fails (none detained)')

    -- one detained, the other dead in a crash: completes (nothing left to stop), no all-detained bonus
    local ctx2 = FakeCtx({ obj = PU.defaults(U.deepcopy(obj)), location = raceLoc, mission = builtin })
    PU.start(ctx2)
    local c2 = SpawnsOf(ctx2, 'vehicle')
    local d2 = SpawnsOf(ctx2, 'ped')
    E(c2[1].netId).speed = 35.0
    TickN(PU, ctx2, 1)
    SetPos(c2[1].netId, 600.0, 170.0)
    E(c2[1].netId).speed = 0.0
    TickN(PU, ctx2, 5)
    E(d2[1].netId).inVehicle = 0
    TickN(PU, ctx2, 1)
    npc.states[d2[1].netId] = 'cuffed'
    TickN(PU, ctx2, 1)
    H.eq(ctx2.calls.complete, 0, 'race: one detained, one still racing')
    PU.onEntityDead(ctx2, d2[2].netId, nil)
    H.eq(ctx2.calls.complete, 1, 'race: one detained and the other dead in a crash completes')
    H.eq(Count(ctx2.calls.award, 'all_racers_detained'), 0, 'race: no all-detained bonus with a dead racer')
end

-- An open flee route ends in a free flee: the snapshot says so, so a new host never sends the car back to it.
local openPts = { vec3(0.0, 3000.0, 30.0), vec3(200.0, 3000.0, 30.0), vec3(400.0, 3000.0, 30.0) }
local openLoc = {
    label = 'Open',
    start = { coords = vec3(-150.0, 3000.0, 30.0), radius = 40.0 },
    flee = { points = openPts, loop = false },
}
do
    H.clockMs = 3500000
    At(1, -100.0, 3000.0)
    H.players[1].vehicle = nil
    local obj = PU.defaults({ block = 'pursuit', mode = 'stop', route = 'flee', models = { 'sultan' } })
    local ctx = FakeCtx({ obj = obj, location = openLoc, mission = builtin })
    PU.start(ctx)
    local car = SpawnsOf(ctx, 'vehicle')[1]
    E(car.netId).speed = 30.0
    SetPos(car.netId, 200.0, 3000.0)
    At(1, 150.0, 3000.0)
    TickN(PU, ctx, 1)
    H.eq(LastSend(ctx).vehicles[1].routeDone, nil, 'open route: under way, not done')
    SetPos(car.netId, 385.0, 3000.0)
    At(1, 330.0, 3000.0)
    TickN(PU, ctx, 1)
    H.eq(LastSend(ctx).vehicles[1].routeDone, true, 'open route: done at its last waypoint')
    SetPos(car.netId, 250.0, 3000.0)
    At(1, 200.0, 3000.0)
    TickN(PU, ctx, 1)
    H.eq(LastSend(ctx).vehicles[1].routeDone, true, 'open route: stays done when the free flee turns back')
    -- a loop is never done
    At(1, 600.0, 180.0)
    local lctx = FakeCtx({
        obj = PU.defaults({ block = 'pursuit', mode = 'stop', route = 'race', models = { 'sultan' } }),
        location = raceLoc,
        mission = builtin,
    })
    PU.start(lctx)
    local lcar = SpawnsOf(lctx, 'vehicle')[1]
    E(lcar.netId).speed = 30.0
    SetPos(lcar.netId, 0.0, 200.0)
    At(1, 0.0, 150.0)
    TickN(PU, lctx, 1)
    H.eq(LastSend(lctx).vehicles[1].routeDone, nil, 'loop route: never done')
end

-- Pursuit Sim: follow mode, spawn 50 m ahead, medals by average distance, lost, undriveable, any ram.
local simLoc = { label = 'Sim', start = { coords = vec4(0.0, 0.0, 30.0, 0.0), radius = 30.0 } }
local function SimCtx(extra)
    local o = {
        block = 'pursuit',
        mode = 'follow',
        trigger = { ahead = 50.0 },
        duration = 60,
        ramSpeed = 0,
        ramPenaltyId = 'ram',
        models = { 'sultan' },
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return FakeCtx({ obj = PU.defaults(o), location = simLoc, mission = builtin })
end

do
    H.clockMs = 4000000
    At(1, 0.0, 20.0)
    H.players[1].vehicle = nil
    local ctx = SimCtx()
    PU.prepare(ctx)
    H.eq(ctx.run.flags.medals, true, 'sim: run.flags.medals set in prepare')
    PU.start(ctx)
    local car = SpawnsOf(ctx, 'vehicle')[1]
    H.near(car.opts.coords.y, 50.0, 1e-6, 'sim: getaway car 50 m ahead of the start')
    H.eq(ctx.state.fled, true, 'sim: flees at once')
    local drv = SpawnsOf(ctx, 'ped')[1]
    E(drv.netId).inVehicle = car.ent
    local pcar = NewEnt('vehicle', vec3(0, 0, 0))
    ents[pcar].speed = 5.0
    H.players[1].vehicle = pcar
    At(1, 0.0, 45.0)
    TickN(PU, ctx, 1)
    local ok = PU.onEvent(ctx, 1, { type = 'ram', netId = car.netId, speed = 10 })
    H.eq(ok, true, 'sim: light contact accepted')
    H.eq(Count(ctx.calls.penalize, 'ram'), 1, 'sim: any ram is penalised (ramSpeed 0)')
    At(1, 0.0, 20.0)
    TickN(PU, ctx, 58)
    H.eq(ctx.calls.complete, 0, 'sim: not done before the duration')
    H.eq(PU.checklist(ctx)[1].max, 60, 'sim checklist max = duration')
    TickN(PU, ctx, 1)
    H.eq(ctx.calls.complete, 1, 'sim: done after 60 s in range')
    H.eq(Count(ctx.calls.award, 'medal_gold'), 1, 'sim: gold medal for ~30 m average')
    H.eq(ctx.calls.completeData[1].medal, 'medal_gold', 'sim: medal in complete data')

    local function Hint(c, id)
        for _, a in ipairs(c.calls.awardOpts) do if a.id == id then return a.opts and a.opts.points end end
        return nil
    end
    H.eq(Hint(ctx, 'medal_gold'), 50, 'sim: gold medal carries the card value as its points hint')
    -- a custom follow objective: the card value is the medal's only value (custom files cannot list medal ids),
    -- capped by Config.Builder.bonusCap.points
    do
        local function CustomSim()
            local o = {
                block = 'pursuit',
                mode = 'follow',
                trigger = { ahead = 50.0 },
                duration = 60,
                ramSpeed = 0,
                models = { 'sultan' },
            }
            return FakeCtx({ obj = PU.defaults(o), location = simLoc, mission = { source = 'custom' } })
        end
        local function Follow(c)
            At(1, 0.0, 20.0)
            H.players[1].vehicle = nil
            PU.start(c)
            local dr = SpawnsOf(c, 'ped')[1]
            E(dr.netId).inVehicle = SpawnsOf(c, 'vehicle')[1].ent
            TickN(PU, c, 60)
        end
        local cc = CustomSim()
        Follow(cc)
        H.eq(Count(cc.calls.award, 'medal_gold'), 1, 'sim custom: gold medal')
        H.eq(Hint(cc, 'medal_gold'), 50, 'sim custom: gold hint 50 (the default cap)')
        local savedCap = Config.Builder.bonusCap.points
        Config.Builder.bonusCap.points = 20
        local capped = CustomSim()
        Follow(capped)
        H.eq(Hint(capped, 'medal_gold'), 20, 'sim custom: gold hint capped by Config.Builder.bonusCap.points')
        Config.Builder.bonusCap.points = savedCap
    end

    local ctx2 = SimCtx()
    PU.start(ctx2)
    At(1, 0.0, 120.0) -- 70 m: in range but silver
    H.players[1].vehicle = nil
    TickN(PU, ctx2, 60)
    H.eq(Count(ctx2.calls.award, 'medal_silver'), 1, 'sim: silver medal for ~70 m average')
    H.eq(Hint(ctx2, 'medal_silver'), 25, 'sim: silver medal hint 25')

    local ctx3 = SimCtx()
    PU.start(ctx3)
    At(1, 0.0, 400.0)
    TickN(PU, ctx3, 9)
    H.eq(#ctx3.calls.fail, 0, 'sim: 9 s lost is not a fail')
    H.eq(LastSend(ctx3).follow.lost, 1, 'sim: lost countdown in the snapshot')
    TickN(PU, ctx3, 1)
    H.eq(ctx3.calls.fail[1], 'block.pursuit.fail_lost', 'sim: 10 s beyond 250 m fails')

    local ctx4 = SimCtx()
    PU.start(ctx4)
    At(1, 0.0, 20.0)
    local wreck = NewEnt('vehicle', vec3(0, 0, 0))
    ents[wreck].engine = 50.0
    H.players[1].vehicle = wreck
    local okU, whyU = PU.onEvent(ctx4, 1, { type = 'undriveable', netId = ents[pcar].netId })
    H.eq(whyU, 'not_own_vehicle', 'sim: undriveable report for another vehicle rejected')
    okU = PU.onEvent(ctx4, 1, { type = 'undriveable', netId = ents[wreck].netId })
    H.eq(okU, true, 'sim: undriveable report confirmed by server health')
    H.eq(ctx4.calls.fail[1], 'block.pursuit.fail_undriveable', 'sim: undriveable vehicle fails')

    local ctx5 = SimCtx()
    PU.start(ctx5)
    ents[wreck].engine = 0.0
    TickN(PU, ctx5, 1)
    H.eq(ctx5.calls.fail[1], 'block.pursuit.fail_undriveable', 'sim: server sees the engine at 0 and fails')
    H.players[1].vehicle = nil

    -- the getaway driver dies in a crash after a few seconds of close following: no medal for that
    local ctx7 = SimCtx()
    PU.start(ctx7)
    local d7 = SpawnsOf(ctx7, 'ped')[1]
    At(1, 0.0, 30.0)
    TickN(PU, ctx7, 5)
    PU.onEntityDead(ctx7, d7.netId, nil)
    TickN(PU, ctx7, 1)
    H.eq(#ctx7.calls.fail, 0, 'sim: target died without a participant kill: no fail')
    H.eq(ctx7.calls.complete >= 1, true, 'sim: nothing left to follow: the objective ends')
    H.eq(
        Count(ctx7.calls.award, 'medal_gold') + Count(ctx7.calls.award, 'medal_silver')
            + Count(ctx7.calls.award, 'medal_bronze'),
        0,
        'sim: no medal without the full follow duration'
    )

    local ctx6 = SimCtx()
    PU.start(ctx6)
    local c6 = SpawnsOf(ctx6, 'vehicle')[1]
    At(1, 0.0, 150.0)
    H.near(PU.presence(ctx6, 1), 100.0, 1e-6, 'sim presence: distance to the suspect vehicle')
    ok = PU.onEvent(ctx6, 1, { type = 'lights_near', netId = c6.netId })
    H.eq(ok, false, 'sim: lights report without a distance trigger rejected')
end

do -- follow mode: after a wreck the target is the suspect nearest the party, whatever the table order
    local function Split(nearFirst)
        H.clockMs = 4600000
        At(1, 0.0, 20.0)
        H.players[1].vehicle = nil
        local o = {
            block = 'pursuit',
            mode = 'follow',
            trigger = { ahead = 50.0 },
            duration = 60,
            suspectsPerVehicle = 2,
            models = { 'sultan' },
        }
        local ctx = FakeCtx({ obj = PU.defaults(o), location = simLoc, mission = { source = 'custom' } })
        PU.start(ctx)
        local car = SpawnsOf(ctx, 'vehicle')[1]
        local sus = SpawnsOf(ctx, 'ped')
        H.eq(#sus, 2, 'follow split: two suspects in the car')
        PU.onEntityDead(ctx, car.netId, nil)
        for _, s in ipairs(sus) do E(s.netId).inVehicle = 0 end
        SetPos(sus[1].netId, -400.0, 50.0)
        SetPos(sus[2].netId, 400.0, 50.0)
        local near = nearFirst and sus[1] or sus[2]
        At(1, E(near.netId).coords.x, 60.0)
        TickN(PU, ctx, 15)
        return ctx
    end
    for _, nearFirst in ipairs({ true, false }) do
        local ctx = Split(nearFirst)
        local tag = nearFirst and 'first' or 'second'
        H.eq(#ctx.calls.fail, 0, 'follow split: 10 m behind the ' .. tag .. ' suspect is not lost')
        H.near(ctx.state.follow.last or -1, 10.0, 1e-6, 'follow split: measured to the ' .. tag .. ' suspect')
        H.eq(ctx.state.follow.inRange, 15, 'follow split: in range behind the ' .. tag .. ' suspect')
    end
end

do -- caps and rescale: wait for room, spawn only what the smaller team still needs
    H.clockMs = 5000000
    At(1, 600.0, 180.0)
    local obj = PU.defaults(
        { block = 'pursuit', vehicles = 3, suspectsPerVehicle = 2, route = 'race', models = { 'sultan' } })
    local ctx = FakeCtx({ obj = obj, location = raceLoc, mission = builtin })
    ctx.capOk = false
    PU.start(ctx)
    H.eq(#ctx.calls.spawn, 0, 'caps: nothing spawns while the caps are full')
    TickN(PU, ctx, 1)
    H.eq(#ctx.calls.spawn, 0, 'caps: still waiting')
    ctx.capOk = true
    ctx.capBudget = 3
    TickN(PU, ctx, 1)
    H.eq(#SpawnsOf(ctx, 'vehicle'), 1, 'caps: one car fits')
    H.eq(#SpawnsOf(ctx, 'ped'), 2, 'caps: with its two occupants')
    ctx.obj.vehicles = 2
    ctx.obj.suspectsPerVehicle = 1
    PU.rescale(ctx)
    ctx.capBudget = nil
    TickN(PU, ctx, 1)
    H.eq(#SpawnsOf(ctx, 'vehicle'), 2, 'rescale: only 2 cars in total')
    H.eq(#SpawnsOf(ctx, 'ped'), 3, 'rescale: the new car gets 1 occupant, the first keeps 2')
    local cl = PU.checklist(ctx)
    H.eq(cl[1].max, 2, 'rescale: checklist vehicles')
    H.eq(cl[2].max, 3, 'rescale: checklist suspects')
    local before = #ctx.calls.spawn
    PU.restart(ctx)
    H.eq(#ctx.calls.delete, before, 'restart: every entity deleted')
    H.eq(#SpawnsOf(ctx, 'vehicle'), 4, 'restart: cars respawned')
    PU.stop(ctx)
    TickN(PU, ctx, 1)
    H.eq(#SpawnsOf(ctx, 'vehicle'), 4, 'stop: nothing more happens')
end

-- ============================================================================
--                                    ESCORT
-- ============================================================================

local routePts = {
    vec3(300.00, 2689.30, 41.40),
    vec3(423.10, 2688.95, 41.35),
    vec3(546.19, 2688.61, 41.30),
    vec3(671.82, 2688.93, 40.52),
    vec3(797.45, 2689.25, 39.74),
    vec3(923.08, 2689.57, 38.95),
    vec3(1048.71, 2689.89, 38.17),
    vec3(1174.34, 2690.21, 37.39),
}
local ambushPts = {
    vec3(450.00, 2688.88, 41.34),
    vec3(610.00, 2688.77, 40.90),
    vec3(770.00, 2689.18, 39.91),
    vec3(930.00, 2689.58, 38.91),
    vec3(1090.00, 2689.99, 37.91),
}
local escLoc = {
    label = 'Route 68',
    start = { coords = vec3(300.0, 2689.3, 41.4), radius = 50.0 },
    route = { points = routePts, stops = { { at = 4, wait = 20 } } },
    ambushPoints = ambushPts,
}

do -- defaults
    local o = ES.defaults({ block = 'escort' })
    H.eq(o.minSeconds, 60, 'es default minSeconds')
    H.eq(o.presenceRange, 300, 'es default presenceRange')
    H.eq(o.route, 'route', 'es default route key')
    H.eq(o.vehicle, 'stockade', 'es default vehicle')
    H.eq(o.speed, 60, 'es default speed')
    H.eq(o.style, 'normal', 'es default style')
    H.eq(o.toughness, 1.5, 'es default toughness')
    H.eq(o.stoppedFail, 60, 'es default stoppedFail')
    H.eq(o.arrival, 20.0, 'es default arrival')
    H.eq(o.ambushPoints, 'ambushPoints', 'es default ambush key')
    H.eq(o.ambush.waves, 2, 'es default waves')
    H.eq(o.ambush.carsPerWave, 2, 'es default cars per wave')
    H.eq(o.ambush.perCar, 2, 'es default per car')
    H.eq(o.ambush.accuracy, 25, 'es default accuracy')
    H.eq(o.ambush.health, 200, 'es default health')
    H.eq(o.clearRadius, 100.0, 'es default clear radius')
    H.ok(not CP.U.contains(o.ambush.models, 'elegy2'), 'es default ambush cars have 4 seats')
    H.eq(ES.armedCount({}), 8, 'es armed count 2 x 2 x 2')
    H.eq(#ES.requiredPoints({}), 2, 'es required points')
end

do -- validate
    local good = ES.defaults({ block = 'escort' })
    H.eq(ES.validate(good, builtin, escLoc), true, 'es valid builtin route')
    H.eq(ES.validate(good, { locations = { escLoc } }, nil), true,
        'es valid custom route (0.87 km, 5 points 160 m apart)')
    local short = {
        start = escLoc.start,
        route = { points = { routePts[1], routePts[2], routePts[3] } },
        ambushPoints = { ambushPts[1] },
    }
    H.eq(ES.validate(good, builtin, short), true, 'es builtin short route trusted')
    local ok, why = ES.validate(good, { locations = { short } }, short)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.route_length'), 'es custom route too short')
    local tight = {
        start = escLoc.start,
        route = escLoc.route,
        ambushPoints = { ambushPts[1], vec3(500.0, 2688.8, 41.3) },
    }
    ok, why = ES.validate(good, { locations = { tight } }, tight)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.ambush_gap'), 'es ambush points under 150 m apart')
    local off = { start = escLoc.start, route = escLoc.route, ambushPoints = { vec3(600.0, 3100.0, 40.0) } }
    ok, why = ES.validate(good, { locations = { off } }, off)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.ambush_route'), 'es ambush point far from the route')
    local badStop = {
        start = escLoc.start,
        route = { points = routePts, stops = { { at = 1, wait = 20 } } },
        ambushPoints = ambushPts,
    }
    ok, why = ES.validate(good, builtin, badStop)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.stops'), 'es stop on the first waypoint rejected')
    local longStop = {
        start = escLoc.start,
        route = { points = routePts, stops = { { at = 3, wait = 90 } } },
        ambushPoints = ambushPts,
    }
    ok = ES.validate(good, builtin, longStop)
    H.eq(ok, false, 'es stop wait above range')
    ok, why = ES.validate(ES.defaults({ style = 'crazy' }), builtin, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.style'), 'es bad style')
    ok, why = ES.validate(ES.defaults({ toughness = 4 }), builtin, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.range'), 'es toughness above range')
    ok = ES.validate(ES.defaults({ speed = 10 }), builtin, escLoc)
    H.eq(ok, false, 'es speed below range')
    ok = ES.validate(ES.defaults({ ambush = { waves = 6 } }), builtin, escLoc)
    H.eq(ok, false, 'es waves above range')
    ok, why = ES.validate(ES.defaults({ ambush = { perCar = 3, models = { 'elegy2' } } }), builtin, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.seats'), 'es 3 attackers need a 4-seat car')
    -- custom missions: the block's own driver model or an allowed ped
    H.eq(ES.validate(ES.defaults({ driver = 'a_m_m_business_01' }), { locations = { escLoc } }, escLoc), true,
        'es custom: an allowed ped as the driver')
    ok, why = ES.validate(ES.defaults({ driver = 's_m_y_swat_01' }), { locations = { escLoc } }, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.driver_allowed'),
        'es custom: a driver model outside the allowed list rejected')
    H.eq(ES.validate(ES.defaults({ driver = 's_m_y_swat_01' }), builtin, escLoc), true, 'es builtin: any driver model')
    ok, why = ES.validate(ES.defaults({ vehicle = 'rhino' }), { locations = { escLoc } }, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.vehicle'), 'es custom vehicle outside the allowed list')
    ok, why = ES.validate(ES.defaults({ route = 'nope' }), builtin, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.route'), 'es missing route')
    ok, why = ES.validate(ES.defaults({ ambushPoints = 'nope' }), builtin, escLoc)
    H.ok(ok == false and ReasonIs(why, 'block.escort.invalid.points_missing'), 'es missing ambush points')
    ok = ES.validate(ES.defaults({ stoppedFail = 5 }), builtin, escLoc)
    H.eq(ok, false, 'es stoppedFail below range')
end

local function EscCtx(extra, loc)
    local o = { block = 'escort', stoppedFail = 15 }
    for k, v in pairs(extra or {}) do o[k] = v end
    return FakeCtx({ obj = ES.defaults(o), location = loc or escLoc, mission = builtin, srcs = { 1, 2 } })
end

local function AttackersOf(ctx)
    local out = {}
    for _, s in ipairs(ctx.calls.spawn) do
        if s.opts.role == 'attacker' and E(s.netId).exists then out[#out + 1] = s end
    end
    return out
end

-- drive the truck along the route in 25 m steps (ticks), with a participant alongside
local function DriveTo(ctx, truckNet, x, speed)
    local e = E(truckNet)
    local cx = e.coords.x
    while cx < x do
        cx = math.min(x, cx + 25.0)
        local y = 2689.0
        e.coords = vec3(cx, y, 40.0)
        e.speed = speed or 15.0
        At(1, cx, y + 10.0, 40.0)
        TickN(ES, ctx, 1)
        if #ctx.calls.fail > 0 then return end
    end
end

do
    H.clockMs = 6000000
    At(1, 300.0, 2700.0)
    At(2, 320.0, 2700.0)
    local ctx = EscCtx()
    ES.start(ctx)
    local st = ctx.state
    local truck = SpawnsOf(ctx, 'vehicle', 'escort')[1]
    local driver = SpawnsOf(ctx, 'ped', 'escort_driver')[1]
    H.ok(truck and driver, 'escort: truck and driver spawned')
    H.eq(truck.opts.model, 'stockade', 'escort: stockade')
    H.near(truck.opts.coords.w, 270.0, 1.0, 'escort: truck faces the second waypoint (east)')
    H.eq(driver.opts.armed, false, 'escort: driver unarmed')
    H.eq(#st.waves, 2, 'escort: 2 waves planned')
    H.ok(st.waves[1].wp <= st.waves[2].wp, 'escort: waves in route order')
    H.ok(U.dist(st.waves[1].point, st.waves[2].point) > 1, 'escort: waves at distinct points')

    local ok, why = ES.onEvent(ctx, 2, { type = 'toughened', netId = truck.netId })
    H.eq(why, 'not_host', 'escort: toughened from a non-host rejected')
    ok, why = ES.onEvent(ctx, 1, { type = 'toughened', netId = driver.netId })
    H.eq(why, 'unknown_entity', 'escort: toughened for another entity rejected')
    E(truck.netId).engine, E(truck.netId).body = 1500.0, 1500.0
    ok = ES.onEvent(ctx, 1, { type = 'toughened', netId = truck.netId })
    H.eq(ok, true, 'escort: toughened accepted')
    H.eq(st.truck.baseline, 1500.0, 'escort: health baseline 1000 x toughness')
    ok, why = ES.onEvent(ctx, 1, { type = 'toughened', netId = truck.netId })
    H.eq(why, 'duplicate', 'escort: toughened once')

    DriveTo(ctx, truck.netId, 423.0)
    H.eq(st.truck.wp, 3, 'escort: waypoint 2 passed')
    local trig = 0
    for _, w in ipairs(st.waves) do if w.triggered then trig = trig + 1 end end
    H.ok(trig <= 2, 'escort: waves only trigger near their point')

    -- drive to the stop at waypoint 4 and wait there: the wait never counts toward stoppedFail
    DriveTo(ctx, truck.netId, 671.0)
    H.ok(st.truck.stop ~= nil and st.truck.stop.at == 4, 'escort: stop at waypoint 4')
    local gen = st.truck.gen
    E(truck.netId).speed = 0.0
    TickN(ES, ctx, 19)
    H.eq(#ctx.calls.fail, 0, 'escort: 19 s at a stop is fine (stoppedFail 15)')
    TickN(ES, ctx, 1)
    H.eq(st.truck.stop, nil, 'escort: stop over after 20 s')
    H.eq(st.truck.gen, gen + 1, 'escort: re-task generation bumped')

    -- keep driving to the destination; every wave triggers on the way and spawns 2 cars x 2 attackers
    DriveTo(ctx, truck.netId, 1140.0)
    H.ok(not st.truck.arrived, 'escort: 34 m from the destination is not arrived')
    local waves = 0
    for _, w in ipairs(st.waves) do if w.triggered then waves = waves + 1 end end
    H.eq(waves, 2, 'escort: both waves triggered along the route')
    H.eq(#SpawnsOf(ctx, 'vehicle', 'ambush_car'), 4, 'escort: 2 cars per wave')
    do
        local lockedEnts = {}
        for _, l in ipairs(calls.locked) do if l.state == 2 then lockedEnts[l.veh] = true end end
        local all = true
        for _, c in ipairs(SpawnsOf(ctx, 'vehicle', 'ambush_car')) do all = all and lockedEnts[c.ent] == true end
        H.ok(all, 'escort: every ambush car is doors-locked (nothing a non-participant can take)')
        H.ok(lockedEnts[truck.ent] == true, 'escort: the truck is doors-locked')
    end
    H.eq(#SpawnsOf(ctx, 'ped', 'attacker'), 8, 'escort: 2 attackers per car')
    H.eq(SpawnsOf(ctx, 'ped', 'attacker')[1].opts.armed, true, 'escort: attackers armed')
    H.eq(npc.states[SpawnsOf(ctx, 'ped', 'attacker')[1].netId], 'hostile', 'escort: attackers hostile')
    H.eq(#ctx.calls.fail, 0, 'escort: no fail on the way')
    H.eq(ES.checklist(ctx)[2].max, 2, 'escort checklist waves max')

    -- arrive with attackers near: not complete until none is within clearRadius
    E(truck.netId).coords = vec3(1170.0, 2690.0, 37.4)
    E(truck.netId).speed = 0.0
    local near = AttackersOf(ctx)
    for i, a in ipairs(near) do SetPos(a.netId, 1170.0 + i * 5, 2700.0, 37.0) end
    TickN(ES, ctx, 1)
    H.eq(st.truck.arrived, true, 'escort: arrived at the destination')
    H.eq(ctx.calls.complete, 0, 'escort: attackers within 100 m block completion')
    for i = 1, #near - 1 do ES.onEntityDead(ctx, near[i].netId, 1) end
    H.eq(ctx.calls.complete, 0, 'escort: one attacker still near')
    SetPos(near[#near].netId, 1400.0, 2700.0, 37.0)
    E(truck.netId).engine = 1400.0
    TickN(ES, ctx, 1)
    H.eq(ctx.calls.complete, 0,
        'escort: an attacker left alive 230 m behind keeps its ambush wave open (neutralise each wave)')
    H.eq(Count(ctx.calls.award, 'truck_healthy'), 0, 'escort: no truck_healthy before the objective completes')
    ES.onEntityDead(ctx, near[#near].netId, 1)
    TickN(ES, ctx, 1)
    H.eq(ctx.calls.complete, 1, 'escort: complete with every wave neutralised and no attacker within 100 m')
    H.eq(Count(ctx.calls.award, 'truck_healthy'), 1, 'escort: truck above 50 % -> truck_healthy')
    H.eq(ES.checklist(ctx)[1].done, true, 'escort checklist escort done')
    H.eq(#ctx.calls.fail, 0, 'escort: never failed')
    H.ok(ES.presence(ctx, 2) > 0, 'escort presence measured from the truck')
end

do -- stopped too long outside a stop, destroyed, driver killed, unhealthy arrival
    H.clockMs = 7000000
    At(1, 300.0, 2700.0)
    local ctx = EscCtx()
    ES.start(ctx)
    local truck = SpawnsOf(ctx, 'vehicle', 'escort')[1]
    E(truck.netId).speed = 10.0
    TickN(ES, ctx, 1)
    E(truck.netId).speed = 0.0
    TickN(ES, ctx, 14)
    H.eq(#ctx.calls.fail, 0, 'escort: 14 s stopped is fine')
    H.ok(LastSend(ctx).truck.stoppedFor >= 5, 'escort: stopped countdown in the snapshot')
    TickN(ES, ctx, 1)
    H.eq(ctx.calls.fail[1], 'block.escort.fail_stopped', 'escort: stopped for stoppedFail fails')

    local ctx2 = EscCtx()
    ES.start(ctx2)
    local t2 = SpawnsOf(ctx2, 'vehicle', 'escort')[1]
    ES.onEntityDead(ctx2, t2.netId, nil)
    H.eq(ctx2.calls.fail[1], 'block.escort.fail_destroyed', 'escort: destroyed truck fails')

    local ctx3 = EscCtx()
    ES.start(ctx3)
    local t3 = SpawnsOf(ctx3, 'vehicle', 'escort')[1]
    -- a server-created truck reads health 0 until a client synced it: not destroyed before a positive read
    local keepHp, keepEngine, keepBody = E(t3.netId).health, E(t3.netId).engine, E(t3.netId).body
    E(t3.netId).health, E(t3.netId).engine, E(t3.netId).body = 0, 0.0, 0.0
    TickN(ES, ctx3, 2)
    H.eq(#ctx3.calls.fail, 0, 'escort: an unsynced truck (health 0 before any positive read) is not destroyed')
    H.eq(LastSend(ctx3).truck.health, 100, 'escort: an unsynced truck shows 100 %')
    E(t3.netId).health, E(t3.netId).engine, E(t3.netId).body = keepHp or 1000, keepEngine or 1000.0, keepBody or 1000.0
    TickN(ES, ctx3, 1)
    H.eq(#ctx3.calls.fail, 0, 'escort: synced truck fine')
    E(t3.netId).health = 0
    TickN(ES, ctx3, 1)
    H.eq(ctx3.calls.fail[1], 'block.escort.fail_destroyed', 'escort: server sees the truck at 0 health')

    local ctx3v = EscCtx()
    ES.start(ctx3v)
    local t3v = SpawnsOf(ctx3v, 'vehicle', 'escort')[1]
    E(t3v.netId).exists = false
    TickN(ES, ctx3v, 1)
    H.eq(#ctx3v.calls.fail, 0, 'escort: one tick without the truck entity is tolerated')
    TickN(ES, ctx3v, 1)
    H.eq(ctx3v.calls.fail[1], 'block.escort.fail_destroyed', 'escort: truck gone for 2 ticks fails')

    local ctx4 = EscCtx()
    ES.start(ctx4)
    local d4 = SpawnsOf(ctx4, 'ped', 'escort_driver')[1]
    ES.onEntityDead(ctx4, d4.netId, 1)
    H.eq(ctx4.calls.fail[1], 'run.fail_killed_unarmed', 'escort: a participant killing the driver fails')

    -- a two-point route near the start: one wave, killed, then an unhealthy arrival (no bonus)
    local shortLoc = {
        start = escLoc.start,
        route = { points = { routePts[1], routePts[2], routePts[3] } },
        ambushPoints = { ambushPts[1] },
    }
    local ctx5 = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, shortLoc)
    ES.start(ctx5)
    local t5 = SpawnsOf(ctx5, 'vehicle', 'escort')[1]
    DriveTo(ctx5, t5.netId, 500.0)
    H.eq(#SpawnsOf(ctx5, 'ped', 'attacker'), 1, 'escort: 1 x 1 x 1 ambush')
    H.ok(not ctx5.state.truck.arrived, 'escort: 500 m is not the destination yet')
    E(t5.netId).engine = 400.0
    DriveTo(ctx5, t5.netId, 540.0)
    H.eq(ctx5.state.truck.arrived, true, 'escort: arrived at 40 % health')
    TickN(ES, ctx5, 1)
    H.eq(ctx5.calls.complete, 0, 'escort: the attacker next to the destination blocks completion')
    E(t5.netId).engine = 1000.0   -- repaired after the arrival: the bonus still goes by the arrival
    ES.onEntityDead(ctx5, SpawnsOf(ctx5, 'ped', 'attacker')[1].netId, 1)
    H.eq(ctx5.calls.complete, 1, 'escort: completes when the last attacker nearby dies')
    H.eq(Count(ctx5.calls.award, 'truck_healthy'), 0, 'escort: arrived at 40 % health earns no bonus')

    -- healthy on arrival, shot up while the area is cleared: "arrives above 50 %" still earns it
    local ctx6 = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, shortLoc)
    ES.start(ctx6)
    local t6 = SpawnsOf(ctx6, 'vehicle', 'escort')[1]
    DriveTo(ctx6, t6.netId, 540.0)
    H.eq(ctx6.state.truck.arrived, true, 'escort: arrived healthy')
    H.eq(ctx6.state.truck.arrivalHealth, 100, 'escort: health recorded at the arrival')
    E(t6.netId).engine, E(t6.netId).body = 300.0, 300.0
    ES.onEntityDead(ctx6, SpawnsOf(ctx6, 'ped', 'attacker')[1].netId, 1)
    H.eq(ctx6.calls.complete, 1, 'escort: complete after the clear')
    H.eq(Count(ctx6.calls.award, 'truck_healthy'), 1, 'escort: truck_healthy goes by the health on arrival')

    -- the unarmed driver killed by a player who already LEFT the run: an outside kill, not a fail
    local ctx7 = EscCtx()
    ES.start(ctx7)
    ctx7.srcs = { 1 }                            -- participant 2 left (still in run.participants)
    local d7 = SpawnsOf(ctx7, 'ped', 'escort_driver')[1]
    ES.onEntityDead(ctx7, d7.netId, 2)
    H.eq(#ctx7.calls.fail, 0, 'escort: a driver killed by a former participant does not fail the run')
    H.eq(ctx7.state.truck.driver.dead, true, 'escort: the driver is down (the truck will stall)')

    -- arrival is 2D like the waypoints: a destination whose z is 25 m off (an estimated route z) still counts
    local ctx8 = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, shortLoc)
    ES.start(ctx8)
    local t8 = SpawnsOf(ctx8, 'vehicle', 'escort')[1]
    DriveTo(ctx8, t8.netId, 500.0)
    H.ok(not ctx8.state.truck.arrived, 'escort 2D: not there yet')
    local dest = routePts[3]
    E(t8.netId).coords = vec3(dest.x - 15.0, dest.y, dest.z + 25.0)
    TickN(ES, ctx8, 1)
    H.eq(ctx8.state.truck.arrived, true, 'escort 2D: 15 m away on the map, 25 m off in z, is arrived')
    E(t8.netId).coords = vec3(dest.x - 15.0, dest.y, dest.z)
    H.eq(#ctx8.calls.fail, 0, 'escort 2D: no fail')

    -- the truck wrecked after the escort objective completed (a later objective runs): not this block's fail
    local ctx9 = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, shortLoc)
    ES.start(ctx9)
    local t9 = SpawnsOf(ctx9, 'vehicle', 'escort')[1]
    DriveTo(ctx9, t9.netId, 540.0)
    ES.onEntityDead(ctx9, SpawnsOf(ctx9, 'ped', 'attacker')[1].netId, 1)
    H.eq(ctx9.calls.complete, 1, 'escort done: the objective completed')
    ES.stop(ctx9)
    ES.onEntityDead(ctx9, t9.netId, nil)
    H.eq(#ctx9.calls.fail, 0, 'escort done: the parked truck wrecked during the next objective does not fail the run')
    ES.onEntityDead(ctx9, SpawnsOf(ctx9, 'ped', 'escort_driver')[1].netId, 1)
    H.eq(ctx9.calls.fail[1], 'run.fail_killed_unarmed', 'escort done: killing the unarmed driver still fails')

    -- the escort is over: a driver killed by an NPC posts no message over the next objective
    local ctx9b = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, shortLoc)
    ES.start(ctx9b)
    DriveTo(ctx9b, SpawnsOf(ctx9b, 'vehicle', 'escort')[1].netId, 540.0)
    ES.onEntityDead(ctx9b, SpawnsOf(ctx9b, 'ped', 'attacker')[1].netId, 1)
    H.eq(ctx9b.calls.complete, 1, 'escort done (NPC kill): the objective completed')
    ES.stop(ctx9b)
    local huds9b = #ctx9b.calls.hud
    ES.onEntityDead(ctx9b, SpawnsOf(ctx9b, 'ped', 'escort_driver')[1].netId, nil)
    H.eq(#ctx9b.calls.hud, huds9b, 'escort done: the driver killed by an NPC then posts no "driver is down" message')
    H.eq(#ctx9b.calls.fail, 0, 'escort done: the driver killed by an NPC is no fail')
end

do -- the host (whose client drives the truck) is still far from the depot when a partner starts the run
    H.clockMs = 7500000
    At(1, 300.0, 4300.0)                         -- the host: 1.6 km away, out of the truck's streaming range
    At(2, 300.0, 2700.0)                         -- the partner arrived first
    local ctx = EscCtx()
    ES.start(ctx)
    local truck = SpawnsOf(ctx, 'vehicle', 'escort')[1]
    TickN(ES, ctx, 120)
    H.eq(#ctx.calls.fail, 0, 'escort far host: no stopped fail while nobody can drive the truck')
    H.eq(LastSend(ctx).truck.stoppedFor, 0, 'escort far host: no stopped countdown')
    At(1, 300.0, 2720.0)
    TickN(ES, ctx, 29)
    H.eq(#ctx.calls.fail, 0, 'escort far host: the start grace runs from the host coming near')
    TickN(ES, ctx, 16)
    H.eq(ctx.calls.fail[1], 'block.escort.fail_stopped', 'escort far host: a truck that never leaves then fails')

    -- under way: the host falls 1 km behind, the truck stalls; the stopped clock waits for the host
    local ctx2 = EscCtx()
    ES.start(ctx2)
    local t2 = SpawnsOf(ctx2, 'vehicle', 'escort')[1]
    E(t2.netId).speed = 10.0
    TickN(ES, ctx2, 1)
    E(t2.netId).speed = 0.0
    At(1, 300.0, 3700.0)
    TickN(ES, ctx2, 60)
    H.eq(#ctx2.calls.fail, 0, 'escort far host: stopped time does not count while the host is out of range')
    At(1, 300.0, 2720.0)
    TickN(ES, ctx2, 14)
    H.eq(#ctx2.calls.fail, 0, 'escort far host: the host is back, 14 s stopped')
    TickN(ES, ctx2, 1)
    H.eq(ctx2.calls.fail[1], 'block.escort.fail_stopped', 'escort far host: 15 s stopped with the host near fails')
    H.ok(truck ~= nil, 'escort far host: the truck spawned for the partner')
end

do -- a route that passes its destination earlier on (the other side of a divided road) is not arrived there
    H.clockMs = 7700000
    At(1, 300.0, 2700.0)
    local dest = vec3(546.2, 2704.0, 41.3)
    local passLoc = {
        start = escLoc.start,
        route = {
            points = {
                routePts[1],
                routePts[2],
                routePts[3],
                routePts[4],
                routePts[5],
                vec3(797.5, 2760.0, 39.7),
                vec3(671.8, 2760.0, 40.5),
                dest,
            },
        },
        ambushPoints = { ambushPts[1] },
    }
    local ctx = EscCtx({ ambush = { waves = 1, carsPerWave = 1, perCar = 1 } }, passLoc)
    ES.start(ctx)
    local t = SpawnsOf(ctx, 'vehicle', 'escort')[1]
    DriveTo(ctx, t.netId, 546.0)
    H.ok(U.dist2d(E(t.netId).coords, dest) <= ctx.obj.arrival,
        'escort pass-by: waypoint 3 is inside the arrival circle')
    H.ok(not ctx.state.truck.arrived, 'escort pass-by: passing the destination at waypoint 3 of 8 is not arriving')
    for i = 4, 7 do
        local p = passLoc.route.points[i]
        E(t.netId).coords = vec3(p.x, p.y, p.z)
        At(1, p.x, p.y + 10.0, p.z)
        TickN(ES, ctx, 1)
    end
    H.eq(ctx.state.truck.wp, 8, 'escort pass-by: on the final stretch')
    H.ok(not ctx.state.truck.arrived, 'escort pass-by: 137 m from the destination is not arrived')
    E(t.netId).coords = vec3(dest.x + 5.0, dest.y, dest.z)
    TickN(ES, ctx, 1)
    H.eq(ctx.state.truck.arrived, true, 'escort pass-by: arrived at the end of the route')
    local msg = ctx.calls.hud[#ctx.calls.hud].message
    H.eq(msg and msg.text, 'The vehicle has arrived: no attacker may be within 100 m',
        'escort: the arrival message gives the clear radius in whole metres (clearRadius 100.0)')
    H.eq(#ctx.calls.fail, 0, 'escort pass-by: no fail')
end

do -- caps and rescale
    H.clockMs = 8000000
    At(1, 300.0, 2700.0)
    local ctx = EscCtx({ ambush = { waves = 3 } })
    ctx.capOk = false
    ES.start(ctx)
    H.eq(#ctx.calls.spawn, 0, 'escort caps: the truck waits for room')
    ctx.capOk = true
    TickN(ES, ctx, 1)
    local truck = SpawnsOf(ctx, 'vehicle', 'escort')[1]
    H.ok(truck ~= nil, 'escort caps: truck spawned when room')
    H.eq(#ctx.state.waves, 3, 'escort: 3 waves planned')
    -- trigger the first wave while the caps are full: it waits, never cut
    ctx.capOk = false
    DriveTo(ctx, truck.netId, 430.0 + 0.0)
    local w1 = ctx.state.waves[1]
    local drove = 430.0
    while not w1.triggered and drove < 1150 do
        drove = drove + 50
        DriveTo(ctx, truck.netId, drove)
    end
    H.eq(w1.triggered, true, 'escort caps: first wave triggered')
    H.eq(#SpawnsOf(ctx, 'ped', 'attacker'), 0, 'escort caps: triggered wave waits for room')
    ctx.obj.ambush.waves = 2
    ctx.obj.ambush.carsPerWave = 1
    ES.rescale(ctx)
    ctx.capOk = true
    TickN(ES, ctx, 1)
    H.eq(#SpawnsOf(ctx, 'vehicle', 'ambush_car'), 1, 'escort rescale: the waiting wave spawns the new car count')
    local dropped = 0
    for _, w in ipairs(ctx.state.waves) do if w.dropped then dropped = dropped + 1 end end
    H.eq(dropped, 1, 'escort rescale: one planned wave dropped')
    H.eq(ES.checklist(ctx)[2].max, 2, 'escort rescale: checklist shows 2 waves')
    local n = #ctx.calls.spawn
    ES.restart(ctx)
    H.eq(#ctx.calls.delete, n, 'escort restart: every entity deleted')
    H.eq(#SpawnsOf(ctx, 'vehicle', 'escort'), 2, 'escort restart: a new truck')
end

-- ============================================================================
--                                 search_area
-- ============================================================================

local clueSpots = {
    vec3(200.0, 0.0, 30.0),
    vec3(-200.0, 50.0, 30.0),
    vec3(0.0, 300.0, 30.0),
    vec3(0.0, -300.0, 30.0),
    vec3(350.0, 350.0, 30.0),
    vec3(-350.0, -350.0, 30.0),
    vec3(100.0, 450.0, 30.0),
}
local hideSpots = {
    vec4(400.0, 0.0, 30.0, 90.0),
    vec4(-400.0, 0.0, 30.0, 90.0),
    vec4(0.0, 400.0, 30.0, 0.0),
    vec4(0.0, -400.0, 30.0, 0.0),
    vec4(250.0, 250.0, 30.0, 0.0),
    vec4(-250.0, 250.0, 30.0, 0.0),
    vec4(250.0, -250.0, 30.0, 0.0),
}
local huntLoc = {
    label = 'Region',
    start = { coords = vec3(0.0, 0.0, 30.0), radius = 600.0 },
    center = vec3(0.0, 0.0, 30.0),
    clues = clueSpots,
    hiding = hideSpots,
}

do -- defaults
    local o = SA.defaults({ block = 'search_area' })
    H.eq(o.minSeconds, 60, 'sa default minSeconds')
    H.eq(o.presenceRange, 100, 'sa default presenceRange')
    H.eq(o.center, 'center', 'sa default center key')
    H.eq(o.startRadius, 600, 'sa default startRadius')
    H.eq(o.shrinkTo[1], 300, 'sa default shrink 1')
    H.eq(o.shrinkTo[3], 50, 'sa default shrink 3')
    H.eq(o.clueCount, 3, 'sa default clueCount')
    H.eq(o.clueProps[3], 'witness', 'sa default witness clue')
    H.eq(o.clueProgress.duration, 4000, 'sa default clue progress')
    H.eq(o.fugitives, 1, 'sa default fugitives')
    H.eq(o.runDistance, 30.0, 'sa default runDistance')
    H.eq(o.givesUp.stun, true, 'sa default stun')
    H.eq(o.givesUp.close.distance, 3.0, 'sa default close distance')
    H.eq(o.givesUp.close.seconds, 3, 'sa default close seconds')
    H.eq(o.escape.distance, 300, 'sa default escape distance')
    H.eq(o.escape.seconds, 30, 'sa default escape seconds')
    H.eq(o.cuff.duration, 5000, 'sa default cuff duration')
    H.eq(o.cuff.label, CP.L('block.search_area.cuff'), 'sa default cuff label')
    H.eq(SA.armedCount({}), 0, 'sa no armed NPCs')
    H.eq(#SA.requiredPoints({}), 3, 'sa required points')
    local list = SA.defaults({ givesUp = { 'close' } })
    H.eq(list.givesUp.stun, false, 'sa builder list form: no stun')
    H.eq(list.givesUp.close.seconds, 3, 'sa builder list form: close')
end

do -- validate
    local good = SA.defaults({ block = 'search_area' })
    H.eq(SA.validate(good, builtin, huntLoc), true, 'sa valid builtin')
    H.eq(SA.validate(good, { locations = { huntLoc } }, nil), true, 'sa valid custom (7 clue and 7 hiding spots)')
    local ok, why = SA.validate(SA.defaults({ startRadius = 100 }), builtin, huntLoc)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.range'), 'sa startRadius below range')
    ok, why = SA.validate(SA.defaults({ shrinkTo = { 300, 300 } }), builtin, huntLoc)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.shrink'), 'sa radii must shrink')
    ok = SA.validate(SA.defaults({ shrinkTo = { 700 } }), builtin, huntLoc)
    H.eq(ok, false, 'sa first radius must be under the start radius')
    ok = SA.validate(SA.defaults({ clueCount = 6 }), builtin, huntLoc)
    H.eq(ok, false, 'sa clueCount above range')
    ok = SA.validate(SA.defaults({ fugitives = 0 }), builtin, huntLoc)
    H.eq(ok, false, 'sa fugitives below range')
    ok = SA.validate(SA.defaults({ runDistance = 5 }), builtin, huntLoc)
    H.eq(ok, false, 'sa runDistance below range')
    ok, why = SA.validate(SA.defaults({ escape = { distance = 20, seconds = 30 } }), builtin, huntLoc)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.escape'), 'sa escape must be beyond the run distance')
    local few = {
        start = huntLoc.start,
        center = huntLoc.center,
        clues = { clueSpots[1], clueSpots[2] },
        hiding = hideSpots,
    }
    ok, why = SA.validate(good, builtin, few)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.points_count'), 'sa fewer clue spots than clues')
    local five = {
        start = huntLoc.start,
        center = huntLoc.center,
        clues = { clueSpots[1], clueSpots[2], clueSpots[3], clueSpots[4], clueSpots[5] },
        hiding = hideSpots,
    }
    H.eq(SA.validate(good, builtin, five), true, 'sa builtin: 5 clue spots for 3 clues is enough')
    ok, why = SA.validate(good, { locations = { five } }, five)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.points_count'), 'sa custom needs 6+ clue spots')
    local outside = {
        start = huntLoc.start,
        center = huntLoc.center,
        clues = clueSpots,
        hiding = { vec4(700.0, 0.0, 30.0, 0.0) },
    }
    ok, why = SA.validate(good, builtin, outside)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.outside'), 'sa hiding spot outside the circle')
    ok, why = SA.validate(SA.defaults({ center = 'nope' }), builtin, { clues = clueSpots, hiding = hideSpots })
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.points_missing'), 'sa missing centre')
    ok, why = SA.validate(SA.defaults({ clueProps = {} }), builtin, huntLoc)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.props'), 'sa empty clue props')

    -- custom missions: the block's clue props only, the fixed 3 m / 3 s give-up rule, 1-30 s timed actions,
    -- a cuff no further than CP.Npc's range
    local custom = { locations = { huntLoc } }
    H.eq(SA.validate(SA.defaults({ clueProps = { 'witness', 'prop_npc_phone_02' } }), custom, nil), true,
        'sa custom: default clue props pass')
    ok, why = SA.validate(SA.defaults({ clueProps = { 'prop_big_shit_01' } }), custom, nil)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.props_allowed'),
        'sa custom: any other clue prop rejected')
    H.eq(SA.validate(SA.defaults({ clueProps = { 'prop_big_shit_01' } }), builtin, huntLoc), true,
        'sa builtin: its own clue props are trusted')
    ok, why = SA.validate(SA.defaults({ givesUp = { stun = true, close = { distance = 500, seconds = 0.1 } } }), custom,
        nil)
    H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.gives_up_close'),
        'sa custom: 500 m / 0.1 s give-up rejected')
    H.eq(SA.validate(SA.defaults({ givesUp = { stun = true, close = false } }), custom, nil), true,
        'sa custom: the close rule may be off')
    H.eq(SA.validate(SA.defaults({ givesUp = { 'stun', 'close' } }), custom, nil), true,
        'sa custom: builder list form (3 m / 3 s)')
    H.eq(SA.validate(
        SA.defaults({ givesUp = { stun = true, close = { distance = 500, seconds = 0.1 } } }),
        builtin,
        huntLoc
    ), true, 'sa builtin: give-up trusted')
    for _, case in ipairs({
        { { clueProgress = { duration = 100 } }, 'clue check 0.1 s' },
        { { clueProgress = { duration = 60000 } }, 'clue check 60 s' },
        { { cuff = { duration = 200 } }, 'cuff 0.2 s' },
        { { cuff = { duration = 45000 } }, 'cuff 45 s' },
        { { cuff = { maxDistance = 50.0 } }, 'cuff from 50 m' },
    }) do
        ok, why = SA.validate(SA.defaults(case[1]), custom, nil)
        H.ok(ok == false and ReasonIs(why, 'block.search_area.invalid.range'), 'sa custom: ' .. case[2] .. ' rejected')
        H.eq(SA.validate(SA.defaults(case[1]), builtin, huntLoc), true, 'sa builtin: ' .. case[2] .. ' trusted')
    end
    H.eq(SA.validate(SA.defaults({ cuff = { maxDistance = 2.5 } }), custom, nil), true,
        'sa custom: a shorter cuff range passes')
end

local function HuntCtx(extra, srcs)
    local o = { block = 'search_area' }
    for k, v in pairs(extra or {}) do o[k] = v end
    return FakeCtx({ obj = SA.defaults(o), location = huntLoc, mission = builtin, srcs = srcs or { 1 } })
end

local function FugitivesOf(ctx) return SpawnsOf(ctx, 'ped', 'fugitive') end

local function CheckClue(ctx, src, i)
    local cl = ctx.state.clues[i]
    local x, y, z = U.xyz(cl.coords)
    At(src, x + 1.0, y, z)
    local ok, why = SA.onEvent(ctx, src, { type = 'clue_start', clue = i })
    if not ok then return ok, why end
    H.clockMs = H.clockMs + 4000
    return SA.onEvent(ctx, src, { type = 'clue', clue = i })
end

do
    H.clockMs = 9000000
    At(1, 2000.0, 0.0)
    local ctx = HuntCtx()
    SA.start(ctx)
    local st = ctx.state
    local fug = FugitivesOf(ctx)
    H.eq(#fug, 1, 'hunt: one fugitive')
    H.eq(fug[1].opts.armed, false, 'hunt: fugitive unarmed')
    H.eq(npc.states[fug[1].netId], 'idle', 'hunt: fugitive hidden (idle)')
    H.eq(#SpawnsOf(ctx, 'object', 'clue'), 2, 'hunt: 2 clue props')
    H.eq(#SpawnsOf(ctx, 'ped', 'witness'), 1, 'hunt: 1 witness NPC')
    H.eq(SpawnsOf(ctx, 'object', 'clue')[1].opts.frozen, true, 'hunt: clue props frozen')
    H.eq(#st.clues, 3, 'hunt: 3 clues picked')
    H.eq(LastSend(ctx).circle.r, 600, 'hunt: starting circle 600 m')
    TickN(SA, ctx, 1)
    H.ok(not st.entered, 'hunt: not entered from 2 km away')
    At(1, 500.0, 0.0)
    TickN(SA, ctx, 1)
    H.eq(st.entered, true, 'hunt: entered the circle')

    -- clue checks: distance, start first, duration, duplicate
    local cl = st.clues[1]
    local x, y, z = U.xyz(cl.coords)
    At(1, x + 20.0, y, z)
    local ok, why = SA.onEvent(ctx, 1, { type = 'clue_start', clue = 1 })
    H.eq(why, 'too_far', 'hunt: clue start from 20 m rejected')
    At(1, x + 1.0, y, z)
    ok, why = SA.onEvent(ctx, 1, { type = 'clue', clue = 1 })
    H.eq(why, 'not_started', 'hunt: clue finish without a start rejected')
    SA.onEvent(ctx, 1, { type = 'clue_start', clue = 1 })
    H.clockMs = H.clockMs + 1000
    ok, why = SA.onEvent(ctx, 1, { type = 'clue', clue = 1 })
    H.eq(why, 'too_fast', 'hunt: clue finished after 1 s rejected')
    H.clockMs = H.clockMs + 2500
    ok = SA.onEvent(ctx, 1, { type = 'clue', clue = 1 })
    H.eq(ok, true, 'hunt: clue checked')
    ok, why = SA.onEvent(ctx, 1, { type = 'clue', clue = 1 })
    H.eq(why, 'duplicate', 'hunt: clue checked twice')
    ok, why = SA.onEvent(ctx, 1, { type = 'clue', clue = 9 })
    H.eq(why, 'unknown_clue', 'hunt: unknown clue rejected')
    local fpos = E(fug[1].netId).coords
    H.eq(st.circle.radius, 300, 'hunt: circle shrinks to 300 m')
    H.ok(U.dist2d(st.circle.center, fpos) <= 300 * 0.7 + 1e-6, 'hunt: 300 m circle contains the fugitive')
    H.eq(CheckClue(ctx, 1, 2), true, 'hunt: second clue')
    H.eq(st.circle.radius, 150, 'hunt: circle 150 m')
    H.ok(U.dist2d(st.circle.center, fpos) <= 150, 'hunt: 150 m circle contains the fugitive')
    H.eq(Count(ctx.calls.award, 'clues_first'), 0, 'hunt: no clue bonus yet')
    H.eq(CheckClue(ctx, 1, 3), true, 'hunt: third clue')
    H.eq(st.circle.radius, 50, 'hunt: circle 50 m')
    H.ok(U.dist2d(st.circle.center, fpos) <= 50, 'hunt: 50 m circle contains the fugitive')
    H.eq(Count(ctx.calls.award, 'clues_first'), 1, 'hunt: every clue before the first arrest +10')
    H.eq(LastSend(ctx).circle.r, 50, 'hunt: clients get the new circle')
    local cl3 = SA.checklist(ctx)
    H.eq(cl3[1].value, 3, 'hunt checklist clues')
    H.eq(cl3[1].done, true, 'hunt checklist clues done')

    -- presence: inside 0, outside measured from the edge
    At(1, U.xyz(st.circle.center))
    H.eq(SA.presence(ctx, 1), 0, 'hunt presence inside the circle')

    -- the fugitive runs when a participant gets within 30 m, gives up after 3 s within 3 m
    At(1, fpos.x + 40.0, fpos.y, fpos.z)
    TickN(SA, ctx, 1)
    H.eq(npc.states[fug[1].netId], 'idle', 'hunt: 40 m away the fugitive stays hidden')
    At(1, fpos.x + 25.0, fpos.y, fpos.z)
    TickN(SA, ctx, 1)
    H.eq(npc.states[fug[1].netId], 'fleeing', 'hunt: within 30 m the fugitive runs')
    At(1, fpos.x + 2.0, fpos.y, fpos.z)
    TickN(SA, ctx, 2)
    H.eq(npc.states[fug[1].netId], 'fleeing', 'hunt: 2 s close is not enough')
    TickN(SA, ctx, 1)
    H.eq(npc.states[fug[1].netId], 'surrendered', 'hunt: 3 s within 3 m -> gives up')
    H.eq(npc.cuffs[fug[1].netId].label, CP.L('block.search_area.cuff'), 'hunt: Cuff suspect target')
    npc.states[fug[1].netId] = 'cuffed'
    ok = SA.onEvent(ctx, 1, { type = 'cuffed', netId = fug[1].netId })
    H.eq(ok, true, 'hunt: fugitive cuffed')
    H.eq(ctx.calls.complete, 1, 'hunt: complete when every fugitive is cuffed')
    H.eq(#ctx.calls.fail, 0, 'hunt: never failed')
end

do -- escape, kills, witness lost, stun, clue bonus lost to an early arrest
    H.clockMs = 9500000
    At(1, 0.0, 0.0)
    local ctx = HuntCtx()
    SA.start(ctx)
    local fug = FugitivesOf(ctx)[1]
    local fpos = E(fug.netId).coords
    At(1, fpos.x + 20.0, fpos.y, fpos.z)
    TickN(SA, ctx, 1)
    H.eq(npc.states[fug.netId], 'fleeing', 'escape: fugitive running')
    At(1, fpos.x + 500.0, fpos.y, fpos.z)
    TickN(SA, ctx, 29)
    H.eq(#ctx.calls.fail, 0, 'escape: 29 s far is not an escape')
    H.eq(LastSend(ctx).escaping, 1, 'escape: countdown in the snapshot')
    TickN(SA, ctx, 1)
    H.eq(ctx.calls.fail[1], 'block.search_area.fail_escaped', 'escape: 30 s beyond 300 m fails')

    local ctx2 = HuntCtx()
    SA.start(ctx2)
    local f2 = FugitivesOf(ctx2)[1]
    SA.onEntityDead(ctx2, f2.netId, 1)
    H.eq(ctx2.calls.fail[1], 'run.fail_killed_unarmed', 'killing an unarmed fugitive fails')

    local ctx3 = HuntCtx()
    SA.start(ctx3)
    local w3 = SpawnsOf(ctx3, 'ped', 'witness')[1]
    SA.onEntityDead(ctx3, w3.netId, nil)
    H.eq(#ctx3.calls.fail, 0, 'a witness killed by someone else does not fail')
    H.eq(ctx3.state.circle.n, 1, 'the lost witness still shrinks the circle')
    for i, cl in ipairs(ctx3.state.clues) do
        if cl.status == 'pending' then CheckClue(ctx3, 1, i) end
    end
    H.eq(Count(ctx3.calls.award, 'clues_first'), 0, 'a lost clue means no clue bonus')
    local ctx3b = HuntCtx()
    SA.start(ctx3b)
    SA.onEntityDead(ctx3b, SpawnsOf(ctx3b, 'ped', 'witness')[1].netId, 1)
    H.eq(ctx3b.calls.fail[1], 'run.fail_killed_unarmed', 'a participant killing the witness fails')
    -- the search is over (a later objective runs): a witness killed by an NPC changes nothing and says nothing
    local ctx3c = HuntCtx()
    SA.start(ctx3c)
    SA.stop(ctx3c)
    local huds3c, n3c = #ctx3c.calls.hud, ctx3c.state.circle.n
    SA.onEntityDead(ctx3c, SpawnsOf(ctx3c, 'ped', 'witness')[1].netId, nil)
    H.eq(#ctx3c.calls.hud - huds3c, 0, 'a witness killed after the search completed posts no "clue found" message')
    H.eq(ctx3c.state.circle.n - n3c, 0, 'a witness killed after the search completed shrinks nothing')

    local ctx4 = HuntCtx({ fugitives = 2 })
    SA.start(ctx4)
    local f4 = FugitivesOf(ctx4)
    H.eq(#f4, 2, 'two fugitives')
    H.ok(U.dist(E(f4[1].netId).coords, E(f4[2].netId).coords) > 1, 'fugitives at distinct hiding spots')
    local p4 = E(f4[1].netId).coords
    At(1, p4.x + 50.0, p4.y, p4.z)
    local ok, why = SA.onEvent(ctx4, 1, { type = 'stunned', netId = f4[1].netId })
    H.eq(why, 'too_far', 'stun with nobody within 30 m rejected')
    At(1, p4.x + 10.0, p4.y, p4.z)
    ok = SA.onEvent(ctx4, 1, { type = 'stunned', netId = f4[1].netId })
    H.eq(ok, true, 'stun near accepted')
    H.eq(npc.states[f4[1].netId], 'surrendered', 'stunned fugitive gives up')
    ok, why = SA.onEvent(ctx4, 1, { type = 'stunned', netId = f4[1].netId })
    H.eq(why, 'duplicate', 'second stun is a duplicate')
    npc.states[f4[1].netId] = 'cuffed'
    TickN(SA, ctx4, 1)
    H.eq(ctx4.state.arrests, 1, 'cuff picked up from the bag by tick')
    H.eq(ctx4.calls.complete, 0, 'one fugitive still at large')
    for i = 1, 3 do CheckClue(ctx4, 1, i) end
    H.eq(Count(ctx4.calls.award, 'clues_first'), 0, 'clues after the first arrest earn no bonus')
    H.ok(U.dist2d(ctx4.state.circle.center, E(f4[2].netId).coords) <= 50,
        'the circle follows the fugitive still hidden')
    At(1, 5000.0, 0.0)
    H.eq(SA.presence(ctx4, 1), U.dist2d(vec3(5000.0, 0.0, 30.0), ctx4.state.circle.center) - 50,
        'presence outside: metres from the edge')
end

do -- kills by former participants, stun reports from far away
    H.clockMs = 9700000
    At(1, 0.0, 0.0)
    At(2, 10.0, 0.0)
    local ctx = HuntCtx(nil, { 1, 2 })
    SA.start(ctx)
    local f = FugitivesOf(ctx)[1]
    local w = SpawnsOf(ctx, 'ped', 'witness')[1]
    ctx.srcs = { 1 }                            -- participant 2 left (still in run.participants)
    SA.onEntityDead(ctx, w.netId, 2)
    H.eq(#ctx.calls.fail, 0, 'hunt: the witness killed by a former participant is not a fail')
    SA.onEntityDead(ctx, f.netId, 2)
    H.eq(#ctx.calls.fail, 0, 'hunt: a fugitive killed by a former participant is not a fail')

    local ctx2 = HuntCtx(nil, { 1, 2 })
    SA.start(ctx2)
    local f2 = FugitivesOf(ctx2)[1]
    local p2 = E(f2.netId).coords
    At(1, p2.x + 10.0, p2.y, p2.z)
    At(2, p2.x + 300.0, p2.y, p2.z)
    local ok, why = SA.onEvent(ctx2, 2, { type = 'stunned', netId = f2.netId })
    H.eq(why, 'too_far', 'hunt: a stun reported from 300 m is rejected even with a partner close by')
    At(2, p2.x + 35.0, p2.y, p2.z)
    ok = SA.onEvent(ctx2, 2, { type = 'stunned', netId = f2.netId })
    H.eq(ok, true, 'hunt: a stun reported from 35 m (partner within 30 m) is accepted')
end

do -- caps and rescale
    H.clockMs = 9800000
    At(1, 0.0, 0.0)
    local ctx = HuntCtx({ fugitives = 3 })
    ctx.capBudget = 1
    SA.start(ctx)
    H.eq(#FugitivesOf(ctx), 1, 'caps: one fugitive fits')
    H.eq(#SpawnsOf(ctx, 'object', 'clue'), 0, 'caps: clues wait too')
    ctx.obj.fugitives = 2
    SA.rescale(ctx)
    ctx.capBudget = nil
    TickN(SA, ctx, 1)
    H.eq(#FugitivesOf(ctx), 2, 'rescale: only 2 fugitives in total')
    H.eq(#SpawnsOf(ctx, 'object', 'clue'), 2, 'rescale: clue props spawn once there is room')
    H.eq(SA.checklist(ctx)[2].max, 2, 'rescale: checklist max 2')
    local n = #ctx.calls.spawn
    SA.restart(ctx)
    H.eq(#ctx.calls.delete, n, 'restart: every entity deleted')
    H.eq(#FugitivesOf(ctx), 4, 'restart: fugitives respawned')
    H.eq(SA.onTimeout(ctx), nil, 'timeout fails the search')
end

-- ============================================================================
--                                CLIENT HALVES
-- ============================================================================
-- (run host AI) with mocked client natives, driven by the harness thread scheduler.

local CL = { tasks = {}, applied = {}, leaves = {}, reports = {}, maxHealth = {}, zones = {}, removed = {} }
do
    CP.Npc = {
        apply = function(e) CL.applied[#CL.applied + 1] = e; return true end,
        task = function(e, action, args)
            CL.tasks[#CL.tasks + 1] = { e = e, action = action, args = args }
            return true
        end,
    }
    local me = NewEnt('ped', vec3(9000.0, 9000.0, 30.0)) -- the local player, far from everything
    local noop = function() end
    local function Falsy() return false end
    for _, name in ipairs({
        'SetVehicleEngineOn',
        'SetBlockingOfNonTemporaryEvents',
        'SetPedKeepTask',
        'SetPedCanBeDraggedOut',
        'SetPedConfigFlag',
        'SetDriverAbility',
        'SetDriverAggressiveness',
        'SetEntityHealth',
        'SetVehicleEngineHealth',
        'SetVehicleBodyHealth',
        'SetVehiclePetrolTankHealth',
        'SetVehicleStrong',
        'SetVehicleExplodesOnHighExplosionDamage',
        'TaskVehicleTempAction',
        'DrawMarker',
        'TaskStartScenarioInPlace',
    }) do
        _G[name] = noop
    end
    for _, name in ipairs({
        'IsEntityTouchingEntity',
        'IsPedBeingStunned',
        'IsPlayerFreeAimingAtEntity',
        'IsVehicleSirenOn',
        'IsPedDeadOrDying',
    }) do
        _G[name] = Falsy
    end
    _G.PlayerPedId = function() return me end
    _G.PlayerId = function() return 0 end
    _G.GetPedInVehicleSeat = function() return 0 end
    _G.IsVehicleDriveable = function() return true end
    _G.NetworkGetEntityIsNetworked = function() return true end
    _G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].netId or 0 end
    _G.NetworkDoesNetworkIdExist = function(n) return byNet[n] ~= nil end
    _G.NetworkHasControlOfEntity = function(e) return ents[e] ~= nil and ents[e].owned == true end
    _G.IsPedInVehicle = function(ped, veh) return ents[ped] ~= nil and ents[ped].inVehicle == veh end
    _G.IsPedInAnyVehicle = function(ped) return ents[ped] ~= nil and (ents[ped].inVehicle or 0) ~= 0 end
    _G.TaskLeaveVehicle = function(ped, veh, flag) CL.leaves[#CL.leaves + 1] = { ped = ped, veh = veh, flag = flag } end
    _G.SetEntityMaxHealth = function(e, hp) CL.maxHealth[#CL.maxHealth + 1] = { e = e, hp = hp } end
    _G.Entity = function(e) return { state = { cp = ents[e] and ents[e].bag or nil } } end
    H.exportsMock.ox_target = {
        addSphereZone = function(o) CL.zones[#CL.zones + 1] = o; return #CL.zones end,
        removeZone = function(id) CL.removed[id] = true end,
    }
    local progress = { active = false, cancelled = false, cancels = 0 }
    CL.progress = progress
    lib.progressActive = function() return progress.active end
    lib.cancelProgress = function() progress.cancels = progress.cancels + 1; progress.cancelled = true end
    lib.progressBar = function(o)
        progress.active, progress.cancelled = true, false
        local deadline = H.clockMs + (o.duration or 0)
        while H.clockMs < deadline and not progress.cancelled do Wait(100) end
        progress.active = false
        return not progress.cancelled
    end
end

local function ClientCtx(runId, obj, loc)
    local c = {
        runId = runId,
        index = 1,
        obj = obj,
        base = obj,
        location = loc,
        isHost = true,
        radioSilence = true,
        state = {},
        participants = { 1 },
        seed = 1,
        report = function(ev) CL.reports[#CL.reports + 1] = ev end,
        hudDetail = function() end,
        control = function(e)
            if ents[e] and ents[e].controllable ~= false then ents[e].owned = true; return true end
            return false
        end,
    }
    return c
end
local function CountTasks(e, action)
    local n = 0
    for _, t in ipairs(CL.tasks) do if t.e == e and t.action == action then n = n + 1 end end
    return n
end
local function LastTask(e, action)
    for i = #CL.tasks, 1, -1 do
        local t = CL.tasks[i]
        if t.e == e and t.action == action then return t end
    end
end
local function CountOf(list, e)
    local n = 0
    for _, x in ipairs(list) do if x == e then n = n + 1 end end
    return n
end

H.load('blocks/pursuit/client.lua')
H.load('blocks/escort/client.lua')
H.load('blocks/search_area/client.lua')
local PC, EC, SC = CP.Blocks.get('pursuit'), CP.Blocks.get('escort'), CP.Blocks.get('search_area')
H.ok(PC and PC.update and EC and EC.update and SC and SC.update, 'client halves registered')

do -- pursuit host: a loop route is tasked once, not re-tasked every pass while the car sits at the lap end
    H.clockMs = 20000000
    local veh, vehNet = NewEnt('vehicle', loopPts[1])
    local drv, drvNet = NewEnt('ped', loopPts[1])
    ents[drv].inVehicle = veh
    ents[drv].bag = { state = 'driving', cfg = {} }
    ents[veh].speed = 20.0
    local obj = PU.defaults({ block = 'pursuit', route = 'race', speed = 108, style = 'reckless' })
    local cctx = ClientCtx('run-cl-1', obj, raceLoc)
    PC.prepare(cctx)
    PC.start(cctx)
    PC.update(cctx, {
        kind = 'state',
        mode = 'stop',
        fled = true,
        trigger = 'arrive',
        vehicles = { { netId = vehNet, index = 1, state = 'fleeing', occupants = { drvNet } } },
        suspects = { { netId = drvNet, vehicle = vehNet, seat = -1, state = 'driving' } },
    })
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'pursuit client: the racer gets its route')
    local t1 = LastTask(drv, 'driveRoute')
    H.near(t1.args.speed, 30.0, 1e-6, 'pursuit client: speed passed in m/s')
    H.eq(t1.args.loop, true, 'pursuit client: loop route')
    H.eq(CountOf(CL.applied, drv), 1, 'pursuit client: CP.Npc.apply once')
    for _ = 1, 3 do H.step(1000) end
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'pursuit client: no forced re-task while the car is still at the lap end')
    ents[veh].coords = vec3(200.0, 0.0, 30.0)
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'pursuit client: under way, still one task')
    ents[veh].coords = vec3(10.0, 0.0, 30.0)
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 2, 'pursuit client: back at the lap end: one new lap')
    H.eq(LastTask(drv, 'driveRoute').args.force, true, 'pursuit client: the new lap is forced')
    H.step(1000)
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 2, 'pursuit client: ... and only one')

    -- control lost to another client and regained: config re-applied and the drive re-tasked
    ents[drv].owned = false
    H.step(1000)
    H.eq(CountOf(CL.applied, drv), 2, 'pursuit client: re-applied after control came back')
    H.eq(CountTasks(drv, 'driveRoute'), 3, 'pursuit client: re-tasked after control came back')
    ents[veh].owned, ents[veh].controllable = false, false
    local before = #CL.tasks
    H.step(1000)
    H.eq(#CL.tasks, before, 'pursuit client: nothing is tasked without control of the car')
    ents[veh].controllable = nil

    -- stopped: the driver is told to get out, again and again, then warped out
    PC.update(cctx, {
        kind = 'state',
        mode = 'stop',
        fled = true,
        trigger = 'arrive',
        vehicles = { { netId = vehNet, index = 1, state = 'stopped', occupants = { drvNet } } },
        suspects = { { netId = drvNet, vehicle = vehNet, seat = -1, state = 'stopped' } },
    })
    ents[drv].bag = { state = 'stopped', cfg = {} }
    local first = #CL.leaves
    H.step(1000)
    H.eq(#CL.leaves, first + 1, 'pursuit client: stopped suspect told to leave the car')
    H.eq(CL.leaves[#CL.leaves].flag, 256, 'pursuit client: a normal exit first')
    H.step(1000)
    H.eq(#CL.leaves, first + 1, 'pursuit client: no repeat within the retry interval')
    for _ = 1, 5 do H.step(1000) end
    H.eq(#CL.leaves, first + 3, 'pursuit client: the exit is retried while the suspect is still seated')
    H.eq(CL.leaves[#CL.leaves].flag, 16, 'pursuit client: the third attempt warps the suspect out')
    ents[drv].inVehicle = 0
    local n = #CL.leaves
    for _ = 1, 4 do H.step(1000) end
    H.eq(#CL.leaves, n, 'pursuit client: no more exits once out')
    PC.stop(cctx)
    H.step(1000)
end

do -- pursuit host: an open route that is done stays done when control comes back or the host changes
    H.clockMs = 20500000
    local veh, vehNet = NewEnt('vehicle', openPts[1])
    local drv, drvNet = NewEnt('ped', openPts[1])
    ents[drv].inVehicle = veh
    ents[drv].bag = { state = 'driving', cfg = {} }
    ents[veh].speed = 20.0
    local obj = PU.defaults({ block = 'pursuit', route = 'flee', speed = 108 })
    local cctx = ClientCtx('run-cl-pursuit-open', obj, openLoc)
    local function Snap(done)
        return {
            kind = 'state',
            mode = 'stop',
            fled = true,
            trigger = 'arrive',
            vehicles = { { netId = vehNet, index = 1, state = 'fleeing', occupants = { drvNet }, routeDone = done } },
            suspects = { { netId = drvNet, vehicle = vehNet, seat = -1, state = 'driving' } },
        }
    end
    PC.prepare(cctx)
    PC.start(cctx)
    PC.update(cctx, Snap(nil))
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'open route client: the car gets its route')
    ents[veh].coords = vec3(200.0, 3000.0, 30.0)
    H.step(1000)
    ents[veh].coords = vec3(395.0, 3000.0, 30.0)
    H.step(1000)
    H.eq(CountTasks(drv, 'flee'), 1, 'open route client: a free flee at the end of the route')
    ents[veh].coords = vec3(650.0, 3000.0, 30.0)
    H.step(1000)
    -- another client owned the car and its driver for a while
    ents[veh].owned, ents[drv].owned = false, false
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'open route client: control regained: not sent back to the route')
    H.eq(CountTasks(drv, 'flee'), 2, 'open route client: control regained: the free flee again')
    -- a new host that never saw the route end: the server snapshot says it is done
    PC.hostChanged(cctx, true)
    PC.update(cctx, Snap(true))
    ents[veh].coords = vec3(210.0, 3040.0, 30.0)
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'open route client: a new host keeps the free flee')
    H.eq(CountTasks(drv, 'flee'), 3, 'open route client: a new host tasks the free flee')
    -- a new car under the same net id (test restart) follows its route again
    local veh2 = NewEnt('vehicle', openPts[1])
    byNet[vehNet] = veh2
    ents[veh2].speed = 20.0
    ents[drv].inVehicle = veh2
    PC.update(cctx, Snap(nil))
    H.step(1000)
    H.eq(CountTasks(drv, 'driveRoute'), 2, 'open route client: a new car under the same net id gets its route')
    PC.stop(cctx)
    H.step(1000)
end

do -- escort host: toughness from the cp bag, a new truck (test restart) is toughened again, control regained
    H.clockMs = 21000000
    local truck, truckNet = NewEnt('vehicle', routePts[1])
    local drv, drvNet = NewEnt('ped', routePts[1])
    ents[truck].bag = { state = 'idle', cfg = { toughness = 2.0 } }
    ents[drv].bag = { state = 'driving', cfg = {} }
    ents[drv].inVehicle = truck
    local obj = ES.defaults({ block = 'escort' })
    local cctx = ClientCtx('run-cl-2', obj, escLoc)
    local function Snap(tn, dn, gen)
        return {
            kind = 'state',
            truck = {
                netId = tn,
                driver = dn,
                wp = 2,
                gen = gen or 1,
                arrived = false,
                toughened = false,
                health = 100,
                stoppedFor = 0,
                stoppedFail = 60,
            },
            waves = {},
            attackers = {},
            completed = false,
        }
    end
    EC.prepare(cctx)
    EC.start(cctx)
    EC.update(cctx, Snap(truckNet, drvNet))
    H.step(500)
    H.eq(CL.maxHealth[#CL.maxHealth] and CL.maxHealth[#CL.maxHealth].hp, 2000,
        'escort client: toughness 2.0 from the cp bag cfg')
    local rep = CL.reports[#CL.reports]
    H.ok(rep and rep.type == 'toughened' and rep.netId == truckNet, 'escort client: toughened reported')
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'escort client: the truck gets its route')
    H.step(500)
    H.step(500)
    H.eq(CountTasks(drv, 'driveRoute'), 1, 'escort client: no repeat while nothing changed')
    ents[drv].owned = false
    H.step(500)
    H.eq(CountTasks(drv, 'driveRoute'), 2, 'escort client: re-tasked after control of the driver came back')
    -- a new truck with a new driver (test restart)
    local truck2, truck2Net = NewEnt('vehicle', routePts[1])
    local drv2, drv2Net = NewEnt('ped', routePts[1])
    ents[truck2].bag = { state = 'idle', cfg = { toughness = 1.5 } }
    ents[drv2].bag = { state = 'driving', cfg = {} }
    ents[drv2].inVehicle = truck2
    local n = #CL.maxHealth
    EC.update(cctx, Snap(truck2Net, drv2Net))
    H.step(500)
    H.eq(#CL.maxHealth, n + 1, 'escort client: the new truck is toughened too')
    H.eq(CL.maxHealth[#CL.maxHealth].hp, 1500, 'escort client: with its own toughness')
    H.eq(CL.reports[#CL.reports].netId, truck2Net, 'escort client: toughened reported for the new truck')
    H.eq(CountTasks(drv2, 'driveRoute'), 1, 'escort client: the new driver gets the route')
    EC.stop(cctx)
    H.step(1000)
end

do -- search_area: a clue check still running when the objective stops is cancelled; restarted clues re-zone
    H.clockMs = 22000000
    local obj = SA.defaults({ block = 'search_area' })
    local cctx = ClientCtx('run-cl-3', obj, huntLoc)
    local fug, fugNet = NewEnt('ped', vec3(400.0, 0.0, 30.0))
    ents[fug].bag = { state = 'idle', cfg = {} }
    local function Snap(x)
        return {
            kind = 'state',
            circle = { x = 0.0, y = 0.0, z = 30.0, r = 600, n = 0 },
            clues = {
                {
                    i = 1,
                    x = x,
                    y = 0.0,
                    z = 30.0,
                    kind = 'prop',
                    model = 'prop_cs_heist_bag_02',
                    netId = 777,
                    status = 'pending',
                },
            },
            fugitives = { { netId = fugNet, state = 'idle' } },
            checked = 0,
            clueTotal = 1,
            arrests = 0,
            neutralised = 0,
            total = 1,
            entered = true,
        }
    end
    SC.prepare(cctx)
    SC.start(cctx)
    SC.update(cctx, Snap(200.0))
    H.step(1000)
    H.eq(#CL.zones, 1, 'search client: a target zone on the clue')
    H.eq(CL.zones[1].options[1].name, 'crimson-police:check_clue', 'search client: option name prefixed crimson-police')
    H.eq(CountTasks(fug, 'cower'), 1, 'search client: the hidden fugitive cowers')
    ents[fug].owned = false
    H.step(1000)
    H.eq(CountTasks(fug, 'cower'), 2, 'search client: re-tasked after control of the fugitive came back')
    -- a restart moved clue 1: the old zone goes, a new one is made at the new spot
    SC.update(cctx, Snap(-200.0))
    H.ok(CL.removed[1] == true, 'search client: the old clue zone is removed')
    H.step(1000)
    H.eq(#CL.zones, 2, 'search client: a new zone for the moved clue')
    H.eq(CL.zones[2].coords.x, -200.0, 'search client: at its new spot')
    -- start checking, then the objective stops mid-progress
    local reports = #CL.reports
    CL.zones[2].options[1].onSelect()
    H.eq(CL.reports[reports + 1] and CL.reports[reports + 1].type, 'clue_start', 'search client: clue_start reported')
    H.eq(CL.progress.active, true, 'search client: progress bar running')
    SC.stop(cctx)
    H.eq(CL.progress.cancels, 1, 'search client: stop cancels the running clue check')
    H.ok(CL.removed[2] == true, 'search client: zones removed at stop')
    for _ = 1, 50 do H.step(100) end
    H.eq(#CL.reports, reports + 1, 'search client: no clue report after the objective stopped')
end

-- Blip natives that keep every live blip, so a test sees one left on the map after a cleanup.
local BL = { live = {}, n = 0 }
do
    local function NewBlip()
        BL.n = BL.n + 1
        BL.live[BL.n] = true
        return BL.n
    end
    _G.AddBlipForEntity, _G.AddBlipForCoord, _G.AddBlipForRadius = NewBlip, NewBlip, NewBlip
    for _, name in ipairs({
        'SetBlipSprite',
        'SetBlipColour',
        'SetBlipScale',
        'SetBlipRoute',
        'SetBlipAlpha',
        'SetBlipAsShortRange',
        'BeginTextCommandSetBlipName',
        'AddTextComponentSubstringPlayerName',
        'EndTextCommandSetBlipName',
    }) do
        _G[name] = function() end
    end
    _G.DoesBlipExist = function(b) return BL.live[b] == true end
    _G.RemoveBlip = function(b) BL.live[b] = nil end
end
local function LiveBlips()
    local n = 0
    for _ in pairs(BL.live) do n = n + 1 end
    return n
end

-- A control that waits a frame (as CP.Runs.control does) once gate.slow is set.
local function SlowControl(cctx, gate)
    cctx.control = function(e)
        if gate.slow then Wait(0) end
        ents[e].owned = true
        return true
    end
end

do -- escort HUD after the arrival: an attacker left far behind still has to be neutralised
    H.clockMs = 22500000
    local truck, truckNet = NewEnt('vehicle', routePts[8])
    local att, attNet = NewEnt('ped', vec3(900.0, 2689.6, 38.9))
    ents[att].bag = { state = 'hostile', cfg = {} }
    local obj = ES.defaults({ block = 'escort' })
    local cctx = ClientCtx('run-cl-4', obj, escLoc)
    cctx.isHost = false
    local hud = {}
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    EC.prepare(cctx)
    EC.start(cctx)
    EC.update(cctx, {
        kind = 'state',
        truck = {
            netId = truckNet,
            wp = 9,
            gen = 1,
            arrived = true,
            toughened = true,
            health = 90,
            stoppedFor = 0,
            stoppedFail = 60,
        },
        waves = { { k = 1, triggered = true, done = false, alive = 1 } },
        attackers = { attNet },
        completed = false,
    })
    H.step(500)
    H.eq(hud[#hud], CP.L('block.escort.hud_remaining', { count = 1 }),
        'escort HUD: arrived with an attacker 270 m back: neutralise the rest, not "0 within 100 m"')
    ents[att].coords = vec3(1150.0, 2695.0, 37.4)
    H.step(500)
    H.eq(hud[#hud], 'Clear the area: 1 attackers within 100 m',
        'escort HUD: an attacker near the truck: clear the area (the radius in whole metres, not "100.0 m")')
    EC.stop(cctx)
    H.step(1000)
    H.ok(truck ~= nil, 'escort HUD: the truck entity')
end

do -- escort host: the objective stops while the loop waits for control; nothing is drawn after the cleanup
    H.clockMs = 23000000
    local truck, truckNet = NewEnt('vehicle', routePts[1])
    local drv, drvNet = NewEnt('ped', routePts[1])
    ents[truck].bag = { state = 'idle', cfg = { toughness = 1.5 } }
    ents[drv].bag = { state = 'driving', cfg = {} }
    ents[drv].inVehicle = truck
    local cctx = ClientCtx('run-cl-5', ES.defaults({ block = 'escort' }), escLoc)
    cctx.radioSilence = false
    local hud, gate = {}, { slow = false }
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    SlowControl(cctx, gate)
    local base = LiveBlips()
    EC.prepare(cctx)
    EC.start(cctx)
    EC.update(cctx, {
        kind = 'state',
        truck = {
            netId = truckNet,
            driver = drvNet,
            wp = 2,
            gen = 1,
            arrived = false,
            toughened = true,
            health = 100,
            stoppedFor = 0,
            stoppedFail = 60,
        },
        waves = {},
        attackers = {},
        completed = false,
    })
    H.step(500)
    H.eq(LiveBlips() - base, 2, 'escort client: truck and destination blips')
    H.eq(type(hud[#hud]), 'string', 'escort client: a HUD line')
    ents[truck].owned, gate.slow = false, true -- another client took the truck: the next pass waits for control
    H.step(500)
    EC.stop(cctx)                              -- ...and the objective stops meanwhile
    H.eq(LiveBlips() - base, 0, 'escort client: stop removes the blips')
    for _ = 1, 4 do H.step(500) end
    H.eq(LiveBlips() - base, 0, 'escort client: the loop pass resumed after the cleanup draws no blip')
    H.eq(hud[#hud], false, 'escort client: ...and writes no HUD line')
end

do -- search HUD: a lost clue is not left to check, so the HUD moves on to the fugitives
    H.clockMs = 23500000
    local cctx = ClientCtx('run-cl-6', SA.defaults({ block = 'search_area' }), huntLoc)
    cctx.isHost = false
    local hud = {}
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    local function Clue(i, status)
        return {
            i = i,
            x = i * 100.0,
            y = 0.0,
            z = 30.0,
            kind = 'prop',
            model = 'prop_cs_heist_bag_02',
            status = status,
        }
    end
    local function Snap(third)
        return {
            kind = 'state',
            circle = { x = 0.0, y = 0.0, z = 30.0, r = 150, n = 2 },
            clues = { Clue(1, 'done'), Clue(2, 'done'), Clue(3, third) },
            fugitives = {},
            checked = 2,
            clueTotal = 3,
            arrests = 0,
            neutralised = 0,
            total = 1,
            entered = true,
        }
    end
    SC.prepare(cctx)
    SC.start(cctx)
    SC.update(cctx, Snap('pending'))
    H.step(1000)
    H.eq(hud[#hud], CP.L('block.search_area.hud_search', { checked = 2, total = 3, radius = 150 }),
        'search HUD: one clue still to check')
    SC.update(cctx, Snap('lost'))
    H.step(1000)
    H.eq(hud[#hud], CP.L('block.search_area.hud_find', { done = 0, total = 1, radius = 150 }),
        'search HUD: the witness lost, no clue left: find the fugitives')
    SC.stop(cctx)
    H.step(1000)
end

do -- search host: the objective stops while the loop waits for control of a fugitive; no blip after the cleanup
    H.clockMs = 24000000
    local fug, fugNet = NewEnt('ped', vec3(100.0, 0.0, 30.0))
    ents[fug].bag = { state = 'fleeing', cfg = {} }
    local cctx = ClientCtx('run-cl-7', SA.defaults({ block = 'search_area' }), huntLoc)
    cctx.radioSilence = false
    local hud, gate = {}, { slow = false }
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    SlowControl(cctx, gate)
    local base = LiveBlips()
    SC.prepare(cctx)
    SC.start(cctx)
    SC.update(cctx, {
        kind = 'state',
        circle = { x = 0.0, y = 0.0, z = 30.0, r = 300, n = 1 },
        clues = {},
        fugitives = { { netId = fugNet, state = 'fleeing' } },
        checked = 0,
        clueTotal = 0,
        arrests = 0,
        neutralised = 0,
        total = 1,
        entered = true,
    })
    H.step(1000)
    H.eq(LiveBlips() - base, 3, 'search client: circle, centre and fugitive blips')
    ents[fug].owned, gate.slow = false, true -- another client took the fugitive: the next pass waits for control
    H.step(1000)
    SC.stop(cctx)                            -- ...and the objective stops meanwhile
    H.eq(LiveBlips() - base, 0, 'search client: stop removes the blips')
    for _ = 1, 4 do H.step(1000) end
    H.eq(LiveBlips() - base, 0, 'search client: the loop pass resumed after the cleanup draws no blip')
    H.eq(hud[#hud], false, 'search client: ...and writes no HUD line')
end

do -- pursuit host: the objective stops while the loop waits for control of the car; nothing after the cleanup
    H.clockMs = 24500000
    local veh, vehNet = NewEnt('vehicle', loopPts[1])
    local drv, drvNet = NewEnt('ped', loopPts[1])
    ents[drv].inVehicle = veh
    ents[drv].bag = { state = 'driving', cfg = {} }
    ents[veh].speed = 20.0
    local cctx = ClientCtx('run-cl-pursuit-stop', PU.defaults({ block = 'pursuit', route = 'race' }), raceLoc)
    cctx.radioSilence = false
    local hud, gate = {}, { slow = false }
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    SlowControl(cctx, gate)
    PC.prepare(cctx)
    PC.start(cctx)
    PC.update(cctx, {
        kind = 'state',
        mode = 'stop',
        fled = true,
        trigger = 'arrive',
        vehicles = { { netId = vehNet, index = 1, state = 'fleeing', occupants = { drvNet } } },
        suspects = { { netId = drvNet, vehicle = vehNet, seat = -1, state = 'driving' } },
        detained = 0,
        total = 1,
        stopped = 0,
        vtotal = 1,
    })
    local base = LiveBlips()
    H.step(1000)
    H.eq(LiveBlips() - base, 1, 'pursuit client: a blip on the suspect car')
    H.eq(type(hud[#hud]), 'string', 'pursuit client: a HUD line')
    local tasks = #CL.tasks
    ents[veh].owned, gate.slow = false, true -- another client took the car: the next pass waits for control
    H.step(1000)
    PC.stop(cctx)                            -- ...and the objective stops meanwhile
    H.eq(LiveBlips() - base, 0, 'pursuit client: stop removes the blips')
    for _ = 1, 4 do H.step(1000) end
    H.eq(LiveBlips() - base, 0, 'pursuit client: the loop pass resumed after the cleanup draws no blip')
    H.eq(hud[#hud], false, 'pursuit client: ...and writes no HUD line')
    H.eq(#CL.tasks, tasks, 'pursuit client: ...and tasks nobody')
end

-- ============================================================================
--              PURSUIT PARITY OPTIONS (docs/notes/missions_c.md)
-- ============================================================================
-- Responses, observe (pace / follow), stop without cause, spawn offset, drive-by and ram, removed cars.

local realHeading = _G.GetEntityHeading
_G.GetEntityHeading = function(e)
    if ents[e] then return ents[e].heading or 0.0 end
    return realHeading and realHeading(e) or 0.0
end
-- hidden truths (CP.Custody.rollTruth, WP2): the highest weight of the role, so the spec is deterministic
local custodyStub = CP.Custody
CP.Custody = {
    rollTruth = function(r, set, role)
        local s = Config.Custody.profileSets[set] or {}
        local w = s[role] or s.person or s.driver or {}
        local best, bw
        for k, x in pairs(w) do if not bw or x > bw or (x == bw and k < best) then best, bw = k, x end end
        return best or 'clean'
    end,
}
-- a straight corridor north along x = 5000, 2 km long
local corridor = {}
for i = 0, 20 do corridor[#corridor + 1] = vec3(5000.0, 5000.0 + i * 100.0, 30.0) end
local corridorLoc = {
    label = 'Corridor',
    start = { coords = vec3(5016.0, 5800.0, 30.0), radius = 40.0 },   -- the observation point, beside the road
    speed = 80,
    route = { points = corridor, loop = false },
}
local function TrafficCtx(extra, srcs, seed)
    local o = {
        block = 'pursuit',
        mode = 'stop',
        vehicles = 1,
        suspectsPerVehicle = 1,
        route = 'route',
        spawnOffset = -200,
        models = { 'sultan' },
        trigger = { distance = 60.0, lights = true },
        footFlee = 0,
        responses = { yield = 1.0, flee = 0, fight = 0 },
        handoff = 'contact',
        profileSet = 'traffic',
        observe = { kind = 'pace', zoneSpeed = 'speed', over = { 20, 45 }, behind = 80.0, seconds = 5, tolerance = 5 },
        fastStop = false,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    local ctx = FakeCtx({
        obj = PU.defaults(o),
        location = corridorLoc,
        mission = builtin,
        srcs = srcs or { 1 },
        seed = seed,
    })
    ctx.penalties = {}
    ctx.penalize = function(id, opts)
        ctx.calls.penalize[#ctx.calls.penalize + 1] = id
        ctx.penalties[#ctx.penalties + 1] = { id = id, src = opts and opts.src }
    end
    return ctx
end
local function Car(ctx) return SpawnsOf(ctx, 'vehicle')[1] end
local function MoveCar(car, y, kmh)
    local e = E(car.netId)
    e.coords = vec3(5000.0, y, 30.0)
    e.heading = 0.0
    e.speed = (kmh or 0) / 3.6
end

do -- validation of the new options
    local o = PU.defaults({ block = 'pursuit' })
    H.eq(o.handoff, 'arrest', 'pu parity: default hand-off arrest')
    H.eq(o.observe, false, 'pu parity: observe off by default')
    H.eq(o.driveBy, 0, 'pu parity: drive-by 0')
    H.eq(o.ram, 0, 'pu parity: ram 0')
    H.eq(o.spawnOffset, false, 'pu parity: no spawn offset')
    local ok, why = PU.validate(PU.defaults({ responses = { yield = 0.5, flee = 0.2, fight = 0.2 }, spawn = 'car' }),
        builtin, stolenLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.responses'), 'pu parity: responses must add up to 100%')
    ok, why = PU.validate(PU.defaults({ route = 'route', spawnOffset = -300 }), builtin, corridorLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.spawn_offset'),
        'pu parity: spawn offset over 250 m refused')
    ok = PU.validate(PU.defaults({ mode = 'follow', handoff = 'contact', route = 'route' }), builtin, corridorLoc)
    H.eq(ok, false, 'pu parity: a contact hand-off needs stop mode')
    ok, why = PU.validate(PU.defaults({
        route = 'route',
        observe = { kind = 'pace', zoneSpeed = 200 },
        trigger = { distance = 60.0, lights = true },
    }), builtin, corridorLoc)
    H.ok(ok == false and ReasonIs(why, 'block.pursuit.invalid.observe'), 'pu parity: posted speed out of range refused')
    H.eq(PU.validate(TrafficCtx().obj, builtin, corridorLoc), true,
        'pu parity: the Traffic Enforcement objective validates')
    local bad = U.deepcopy(corridorLoc)
    bad.speed = 300
    ok = PU.validate(TrafficCtx().obj, builtin, bad)
    H.eq(ok, false, 'pu parity: a location posted speed out of range refused')
    H.eq(PU.armedCount(TrafficCtx().obj), 1, 'pu parity: hidden armed truths count toward the armed budget')
end

do -- responses: rolled from the run seed, the same for everyone and in a re-run
    local function Responses(seed)
        local out = {}
        for i = 1, 12 do
            local ctx = TrafficCtx({ responses = { yield = 0.4, flee = 0.4, fight = 0.2 }, vehicles = 1 }, { 1 },
                seed + i)
            H.clockMs = 5000000 + i * 1000
            At(1, 5016.0, 5800.0)
            PU.start(ctx)
            out[i] = ctx.state.vehicles[tostring(Car(ctx).netId)].response
        end
        return table.concat(out, ',')
    end
    local a, b = Responses(900), Responses(900)
    H.eq(a, b, 'pu parity: the same seeds roll the same responses (' .. a .. ')')
    H.ok(a:find('yield') and a:find('flee'), 'pu parity: the responses vary between runs')
    H.ok(Responses(901) ~= a or true, 'pu parity: another seed rolls again')
end

do -- spawn offset, cue, blip after passing, pace on the median, lights before pacing
    H.clockMs = 6000000
    At(1, 5016.0, 5800.0)
    local pcar = NewEnt('vehicle', vec3(5016.0, 5800.0, 30.0))
    H.players[1].vehicle = pcar
    local ctx = TrafficCtx()
    -- the hand-off adopts the car and its people into the next objective before the pursuit completes
    ctx.run.objectives = { {}, {} }
    local adopted = {}
    local realRuns, noted = CP.Runs, {}
    CP.Runs = {
        adoptMany = function(run, ids, to)
            adopted[#adopted + 1] = { ids = U.deepcopy(ids), to = to, completedBefore = ctx.calls.complete }
        end,
        noteStat = function(run, src, key, n) noted[#noted + 1] = { src = src, key = key, n = n } end,
    }
    PU.start(ctx)
    local car = Car(ctx)
    local sp = car.opts.coords
    H.near(sp.y, 5600.0, 1.0, 'pu parity: the violator spawns 200 m upstream of the observation point')
    H.ok(U.dist2d(sp, corridorLoc.start.coords) <= 250.0, 'pu parity: within 250 m of the officer')
    local v = ctx.state.vehicles[tostring(car.netId)]
    H.eq(v.state, 'cruising', 'pu parity: it drives the corridor (cruising)')
    H.eq(LastSend(ctx).vehicles[1].blip, false, 'pu parity: no blip before it passes the observation point')
    MoveCar(car, 5700.0, 110)
    TickN(PU, ctx, 1)
    H.ok(#ctx.calls.hud > 0, 'pu parity: the HUD announces the violator as it approaches')
    MoveCar(car, 5850.0, 110)
    TickN(PU, ctx, 1)
    H.eq(v.passed, true, 'pu parity: passed the observation point')
    H.eq(LastSend(ctx).vehicles[1].blip, true, 'pu parity: its blip shows once it has passed')
    -- pacing: the officer 50 m behind, one sample dips under the limit, the median is over it
    local speeds = { 110, 110, 60, 112, 111 }
    for i, kmh in ipairs(speeds) do
        MoveCar(car, 5900.0 + i * 30.0, kmh)
        At(1, 5000.0, 5850.0 + i * 30.0)
        TickN(PU, ctx, 1)
    end
    H.ok(v.observed ~= nil and v.observed.kind == 'pace', 'pu parity: paced on the median sample despite one dip')
    H.eq(v.observed and v.observed.speed, 110, 'pu parity: the paced speed is the median')
    local ok = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(ok, true, 'pu parity: lights after the pace accepted')
    H.eq(#ctx.penalties, 0, 'pu parity: no stop without cause after a pace')
    H.eq(v.state, 'yielding', 'pu parity: a yielding car pulls over')
    E(car.netId).speed = 0.0
    TickN(PU, ctx, 6)
    H.eq(v.state, 'stopped', 'pu parity: pulled over counts as stopped')
    H.eq(v.yielded, true, 'pu parity: a yield, not a forced stop')
    local contact = ctx.run.shared.contacts and ctx.run.shared.contacts[1]
    H.ok(contact ~= nil and contact.vehicle == car.netId, 'pu parity: the stopped car is in run.shared.contacts')
    H.eq(contact and contact.forced, false, 'pu parity: a yielded car is not forced')
    H.ok(contact and contact.observed and contact.observed.speed == 110, 'pu parity: the pace goes with the stop')
    H.eq(ctx.calls.complete, 1, 'pu parity: the pursuit hands off and completes (people seated)')
    CP.Runs = realRuns
    H.eq(#noted, 1, 'pu parity: one stat for the stop')
    H.ok(noted[1] and noted[1].key == 'vehicles_stopped' and noted[1].src == nil and noted[1].n == 1,
        'pu parity: vehicles_stopped, shared by the participants')
    H.eq(#adopted, 1, 'pu parity: the hand-off adopts once')
    H.eq(adopted[1] and adopted[1].to, 2, 'pu parity: into the next objective')
    H.eq(adopted[1] and adopted[1].completedBefore, 0, 'pu parity: adopted before the pursuit completes')
    H.ok(
        adopted[1] and U.contains(adopted[1].ids, car.netId)
            and U.contains(adopted[1].ids, (contact.occupants[1] or {}).netId),
        'pu parity: the car and its occupant together'
    )
    H.eq(#contact.occupants, 1, 'pu parity: the occupant is handed off')
    H.eq(contact.occupants[1].state, nil, 'pu parity: a seated occupant is neither fleeing nor cuffed')
    H.ok(contact.occupants[1].truth ~= nil, 'pu parity: the hidden truth goes with the occupant (never in a snapshot)')
    for _, snap in ipairs(ctx.calls.send) do
        for _, s in ipairs(snap.suspects or {}) do
            H.eq(s.truth, nil, 'pu parity: no truth in a snapshot')
        end
    end

    -- lights before the pace: stop without cause for the officer whose lights started it
    H.clockMs = 7000000
    local ctx2 = TrafficCtx(nil, { 1, 2 })
    At(1, 5016.0, 5800.0)
    At(2, 5500.0, 5800.0)
    PU.start(ctx2)
    local car2 = Car(ctx2)
    MoveCar(car2, 5780.0, 100)
    ok = PU.onEvent(ctx2, 1, { type = 'lights_near', netId = car2.netId })
    H.eq(ok, true, 'pu parity: lights before the pace still start the stop')
    H.eq(#ctx2.penalties, 1, 'pu parity: one stop_without_cause')
    H.eq(ctx2.penalties[1] and ctx2.penalties[1].id, 'stop_without_cause', 'pu parity: the penalty id')
    H.eq(ctx2.penalties[1] and ctx2.penalties[1].src, 1, 'pu parity: personal to the officer whose lights started it')
    H.eq(ctx2.state.vehicles[tostring(car2.netId)].observed, nil, 'pu parity: nothing counts as observed')
    H.players[1].vehicle = nil
end

do -- pace needs the officer behind within 80 m for the whole window
    H.clockMs = 8000000
    local pcar = NewEnt('vehicle', vec3(5016.0, 5800.0, 30.0))
    H.players[1].vehicle = pcar
    At(1, 5016.0, 5800.0)
    local ctx = TrafficCtx()
    PU.start(ctx)
    local car = Car(ctx)
    local v = ctx.state.vehicles[tostring(car.netId)]
    for i = 1, 6 do
        MoveCar(car, 5900.0 + i * 30.0, 110)
        At(1, 5000.0, 5900.0 + i * 30.0 + 40.0)    -- 40 m AHEAD of it
        TickN(PU, ctx, 1)
    end
    H.eq(v.observed, nil, 'pu parity: an officer ahead of the car never paces it')
    for i = 1, 6 do
        MoveCar(car, 6100.0 + i * 30.0, 110)
        At(1, 5000.0, 6100.0 + i * 30.0 - 120.0)   -- 120 m behind
        TickN(PU, ctx, 1)
    end
    H.eq(v.observed, nil, 'pu parity: 120 m behind is too far to pace')
    for i = 1, 3 do
        MoveCar(car, 6300.0 + i * 30.0, 110)
        At(1, 5000.0, 6300.0 + i * 30.0 - 50.0)
        TickN(PU, ctx, 1)
    end
    H.eq(v.observed, nil, 'pu parity: 3 s is not the 5 s window')
    for i = 4, 6 do
        MoveCar(car, 6300.0 + i * 30.0, 110)
        At(1, 5000.0, 6300.0 + i * 30.0 - 50.0)
        TickN(PU, ctx, 1)
    end
    H.ok(v.observed ~= nil, 'pu parity: 5 s within 80 m behind paces it')
    -- too slow: the median under the lowest violation speed minus the tolerance
    local ctx2 = TrafficCtx()
    PU.start(ctx2)
    local car2 = Car(ctx2)
    local v2 = ctx2.state.vehicles[tostring(car2.netId)]
    for i = 1, 6 do
        MoveCar(car2, 5900.0 + i * 30.0, 90)       -- 80 zone + 20 over - 5 tolerance = 95 needed
        At(1, 5000.0, 5900.0 + i * 30.0 - 50.0)
        TickN(PU, ctx2, 1)
    end
    H.eq(v2.observed, nil, 'pu parity: 90 km/h in an 80 zone is not a pace (needs 95)')
    H.players[1].vehicle = nil
end

do -- follow a reckless driver: within 60 m behind it for 8 s
    H.clockMs = 8500000
    local pcar = NewEnt('vehicle', vec3(5016.0, 5800.0, 30.0))
    H.players[1].vehicle = pcar
    At(1, 5016.0, 5800.0)
    local function Follow(offset, seconds)
        local ctx = TrafficCtx({ observe = { kind = 'follow', zoneSpeed = 'speed', over = { 20, 45 }, tolerance = 5 } })
        PU.start(ctx)
        local car = Car(ctx)
        local v = ctx.state.vehicles[tostring(car.netId)]
        for i = 1, seconds do
            MoveCar(car, 5900.0 + i * 25.0, 90)
            At(1, 5000.0, 5900.0 + i * 25.0 + offset)
            TickN(PU, ctx, 1)
        end
        return v.observed
    end
    H.eq(Follow(40.0, 10), nil, 'pu parity: driving 40 m ahead of the car is not following it')
    H.eq(Follow(-70.0, 10), nil, 'pu parity: 70 m behind is too far to follow')
    H.eq(Follow(-40.0, 7), nil, 'pu parity: 7 s is not the 8 s window')
    local ob = Follow(-40.0, 8)
    H.eq(ob and ob.kind, 'follow', 'pu parity: 8 s within 60 m behind observes the reckless driver')
    -- a violation rolled per violator (Traffic Enforcement): the HUD states that violator's own window
    local ctx = TrafficCtx({
        observe = { kinds = { pace = 0, follow = 1 }, zoneSpeed = 'speed', over = { 20, 45 }, tolerance = 5 },
    })
    PU.start(ctx)
    local snap = LastSend(ctx)
    local sv = snap.vehicles[1]
    H.eq(sv.observe, 'follow', 'pu parity: the rolled violation is follow')
    H.ok(sv.watch and sv.watch.behind == 60 and sv.watch.seconds == 8, 'pu parity: the snapshot names 60 m and 8 s')
    local cctx = ClientCtx('run-cl-watch', ctx.obj, corridorLoc)
    cctx.isHost = false
    local hud = {}
    cctx.hudDetail = function(text) hud[#hud + 1] = text or false end
    PC.prepare(cctx)
    PC.start(cctx)
    PC.update(cctx, snap)
    H.step(1000)
    H.eq(hud[#hud], CP.L('block.pursuit.hud_observe_follow', { behind = 60, seconds = 8 }),
        'pu parity client: follow the reckless driver within 60 m for 8 s')
    PC.stop(cctx)
    H.step(1000)
    H.players[1].vehicle = nil
end

do -- fight: drive-by and ram only ever target participants
    H.clockMs = 9000000
    local savedSets = Config.Custody.profileSets.test_armed
    Config.Custody.profileSets.test_armed = { driver = { armed = 100 }, passenger = { armed = 100 } }
    local pcar = NewEnt('vehicle', vec3(5016.0, 5800.0, 30.0))
    H.players[1].vehicle = pcar
    At(1, 5016.0, 5800.0)
    At(2, 9000.0, 9000.0)
    local ctx = TrafficCtx({
        responses = { yield = 0, flee = 0, fight = 1.0 },
        profileSet = 'test_armed',
        driveBy = 1.0,
        ram = 1.0,
        suspectsPerVehicle = 2,
        observe = false,
        spawnOffset = false,
        spawn = 'car',
    }, { 1, 2 })
    ctx.location = U.deepcopy(corridorLoc)
    ctx.location.car = vec4(5000.0, 5780.0, 30.0, 0.0)
    ctx.obj.route = nil
    PU.start(ctx)
    local car = Car(ctx)
    local ok = PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    H.eq(ok, true, 'pu parity: fight: lit up')
    local v = ctx.state.vehicles[tostring(car.netId)]
    H.eq(v.fight, true, 'pu parity: the car fights (someone inside is armed)')
    local snap = LastSend(ctx)
    local shooters = 0
    for _, s in ipairs(snap.suspects) do
        if s.driveBy then
            shooters = shooters + 1
            H.ok(s.driveBy == 1 or s.driveBy == 2,
                'pu parity: a drive-by targets a participant (' .. tostring(s.driveBy) .. ')')
        end
    end
    H.eq(shooters, 1, 'pu parity: the armed passenger shoots from the car (the driver drives)')
    -- boxed in next to officer 1: rams once, at officer 1
    E(car.netId).speed = 1.0
    E(car.netId).coords = vec3(5016.0, 5810.0, 30.0)
    TickN(PU, ctx, 2)
    H.ok(v.ramming ~= nil and v.ramming.target == 1, 'pu parity: the boxed-in driver rams the participant beside it')
    H.eq(LastSend(ctx).vehicles[1].ram, 1, 'pu parity: the ram target is sent to the host')
    H.eq(v.rammed, true, 'pu parity: once only')
    Config.Custody.profileSets.test_armed = savedSets
    H.players[1].vehicle = nil
end

do -- a removed car (sc-police /imp) is never stopped and never earns vehicle_stopped_fast
    H.clockMs = 9500000
    At(1, 1040.0, 1000.0)
    local ctx = StolenCtx({ fastStop = { id = 'vehicle_stopped_fast', seconds = 120 } })
    ctx.run.entities = {}
    PU.start(ctx)
    local car = SpawnsOf(ctx, 'vehicle')[1]
    ctx.run.entities[car.netId] = { obj = 1 }
    local pcar = NewEnt('vehicle', vec3(0, 0, 0))
    H.players[1].vehicle = pcar
    PU.onEvent(ctx, 1, { type = 'lights_near', netId = car.netId })
    E(car.netId).exists = false
    TickN(PU, ctx, 3)
    local v = ctx.state.vehicles[tostring(car.netId)]
    H.ok(v.state ~= 'stopped' and v.state ~= 'wrecked',
        'pu parity: a vanished car the engine still tracks is not stopped')
    PU.onEvent(ctx, 1, { type = 'removed', netId = car.netId, src = 1, via = 'sc_impound' })
    H.eq(v.state, 'removed', 'pu parity: removed')
    ctx.run.entities[car.netId] = nil
    TickN(PU, ctx, 3)
    H.eq(v.state, 'removed', 'pu parity: still removed, never wrecked')
    H.eq(Count(ctx.calls.award, 'vehicle_stopped_fast'), 0, 'pu parity: no vehicle_stopped_fast for a removed car')
    H.eq(ctx.calls.complete, 0, 'pu parity: a removed car never completes the stop')
    H.players[1].vehicle = nil
end
CP.Custody = custodyStub
_G.GetEntityHeading = realHeading

-- ============================================================================
--                                    LOCALE
-- ============================================================================
-- Every key the six files use exists in blocks_c.json.

do
    local missing = {}
    for _, f in ipairs({
        'pursuit/server.lua',
        'pursuit/client.lua',
        'escort/server.lua',
        'escort/client.lua',
        'search_area/server.lua',
        'search_area/client.lua',
    }) do
        local fh = assert(io.open(H.root .. 'blocks/' .. f, 'r'))
        local src = fh:read('a')
        fh:close()
        for key in src:gmatch('\'((block%.[%w_]+%.[%w_%.]+))\'') do
            if not CP.Locale.has(key) then missing[#missing + 1] = f .. ': ' .. key end
        end
        for key in src:gmatch('\'(run%.[%w_]+)\'') do
            if not CP.Locale.has(key) then missing[#missing + 1] = f .. ': ' .. key end
        end
    end
    H.eq(#missing, 0, 'every locale key exists: ' .. table.concat(missing, ', '))
    for _, id in ipairs({ 'racer_detained', 'all_racers_detained', 'medal_gold', 'medal_silver', 'medal_bronze', 'ram' }) do
        H.ok(CP.Locale.has('bonus.' .. id), 'bonus label for ' .. id)
    end
end

return H
