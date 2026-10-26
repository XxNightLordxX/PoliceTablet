-- Service vehicles never appear on top of the officers (Config.Custody.serviceClearance, PLAN S17) on the real engine,

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
local Runs, Custody = W.Runs, W.Custody
H.load('modules/spawn/server.lua')

local TIMEOUT = Config.Custody.serviceTimeout
H.eq(Config.Custody.serviceClearance, 30.0, 'a service vehicle keeps 30 m from every player (shipped)')
H.eq(TIMEOUT, 60, 'the fallback comes after 60 s')

for src = 1, 4 do W.place(src, 3000.0 + src * 100.0, 3000.0, 30.0) end

local function HoldRun(members)
    local m = W.mission({ { block = 'stub_hold', label = 'Hold', minSeconds = 0 } })
    return W.start(members or { 1 }, m)
end

local function D(a, b) return U.dist(vec3(a.x, a.y, a.z), vec3(b.x, b.y, b.z)) end

-- The nearest player to p (every player counts, as on the server).
local function Nearest(p)
    local best = math.huge
    for src = 1, 4 do
        local c = H.players[src] and H.players[src].coords
        if c then best = math.min(best, D(c, p)) end
    end
    return best
end

local function PlaceOf(run, netId)
    local e = run.entities[netId]
    local b = e and W.bags[e.entity]
    return b and b.cp and b.cp.place or nil
end

local function SideAsks(from)
    local out = {}
    for i = (from or 0) + 1, #W.roadAsks do
        local a = W.roadAsks[i]
        if a.args and a.args.min < 100.0 then out[#out + 1] = a end
    end
    return out
end

local function Made(model, from)
    local n = 0
    for i = (from or 0) + 1, #W.bagWrites do
        local w = W.bagWrites[i]
        local e = W.ent(w.h)
        if w.k == 'cp' and e and e.model == model and not w.seen then
            w.seen = true
            n = n + 1
        end
    end
    return n
end

-- ============================================================================
--          THE ROAD POINT CHECK USES Config.Custody.serviceClearance
-- ============================================================================

do
    local run = HoldRun({ 1 })
    W.place(1, 700.0, 525.0, 30.0)
    local s = { kind = 'transport', near = vec3(500.0, 500.0, 30.0), dest = vec4(500.0, 500.0, 30.0, 0.0) }
    H.eq(Custody.checkRoadPoint(run, s, { coords = { x = 700.0, y = 500.0, z = 30.0 } }), nil,
        'a road point 25 m from a player is refused')
    H.ok(Custody.checkRoadPoint(run, s, { coords = { x = 700.0, y = 460.0, z = 30.0 } }) ~= nil,
        'one 65 m from him is taken')
    Config.Custody.serviceClearance = 70.0
    H.eq(Custody.checkRoadPoint(run, s, { coords = { x = 700.0, y = 460.0, z = 30.0 } }), nil,
        'serviceClearance = 70: 65 m is too close')
    -- the road point beside the scene: serviceClearance to serviceClearance + 40 m from the parking point
    Config.Custody.serviceClearance = 30.0
    W.place(1, 3100.0, 3000.0, 30.0)
    H.eq(Custody.checkRoadPoint(run, s, { coords = { x = 545.0, y = 500.0, z = 30.0 } }, true) ~= nil, true,
        'beside the scene: 45 m from the parking point is taken')
    H.eq(Custody.checkRoadPoint(run, s, { coords = { x = 520.0, y = 500.0, z = 30.0 } }, true), nil,
        'beside the scene: 20 m is too close to the parking point')
    H.eq(Custody.checkRoadPoint(run, s, { coords = { x = 590.0, y = 500.0, z = 30.0 } }, true), nil,
        'and 90 m too far from it')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                      AN OFFICER ON THE TRANSPORT POINT
-- ============================================================================
-- THE VAN COMES BESIDE THE SCENE.

do
    local run = HoldRun({ 1, 2 })
    local point = vec4(520.0, 500.0, 30.0, 90.0)
    W.place(1, 521.0, 500.0, 30.0)
    W.place(2, 520.0, 535.0, 30.0)
    W.roadPoint = nil
    local van = Custody.requestTransport(run, vec3(500.0, 500.0, 30.0), { obj = 1, point = point })
    local asked = #W.roadAsks
    W.tick(TIMEOUT + 2)
    H.eq(van.status, 'pending', 'serviceTimeout passed with an officer on the transport point: not put on him')
    H.eq(van.veh, nil, 'no van made there')
    local side = SideAsks(asked)
    H.ok(#side >= 1, 'the driving client is asked for a road point beside the scene')
    local a = side[#side] and side[#side].args or {}
    H.ok(a.near and D(a.near, point) < 0.01, 'around the transport point')
    H.eq(a.min, 30.0, 'serviceClearance from it')
    H.eq(a.max, 70.0, 'up to 40 m further out')
    -- a road point beside the scene within 30 m of the other officer is refused
    W.roadPoint = function(_, args)
        if args.min < 100.0 then return { coords = { x = 520.0, y = 532.0, z = 30.0 }, heading = 180.0 } end
        return nil
    end
    W.tick(4)
    H.eq(van.status, 'pending', 'a road point beside the scene 3 m from an officer is refused')
    -- a clear one is taken: the van is made there, frozen until an officer's game has put it on the ground
    W.roadPoint = function(_, args)
        if args.min < 100.0 then return { coords = { x = 520.0, y = 450.0, z = 30.0 }, heading = 0.0 } end
        return nil
    end
    W.tick(4)
    H.eq(van.status, 'parked', 'the van stands on the road point beside the scene')
    H.ok(van.placed, 'placed, not driven')
    local vc = W.at(run, van.veh)
    H.ok(vc and D(vc, vec3(520.0, 450.0, 30.0)) < 0.5, 'on that road point')
    H.ok(vc and Nearest(vc) >= 30.0, ('30 m or more from every player (%.1f m)'):format(vc and Nearest(vc) or -1))
    local place = PlaceOf(run, van.veh)
    H.ok(place and place.token, 'it waits for its placement (S10 placer)')
    H.eq(place and place.kind, 'vehicle', 'as a vehicle')
    -- the hand over still works from the van where it stands
    H.eq(Custody.transport(run, 1).status, 'parked', 'transport(run) reports it parked')
    W.roadPoint = nil
    W.place(2, 3200.0, 3000.0, 30.0)
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                   THE OFFICER STEPS OFF THE PARKING POINT
-- ============================================================================
-- THE VAN IS PUT THERE.

do
    local run = HoldRun({ 1 })
    local point = vec4(520.0, 500.0, 30.0, 90.0)
    W.place(1, 521.0, 500.0, 30.0)
    W.roadPoint = nil
    local van = Custody.serviceVehicle(run, 'coroner', vec3(500.0, 500.0, 30.0), { obj = 1, point = point })
    W.tick(TIMEOUT + 2)
    H.eq(van.status, 'pending', 'the coroner van waits while the officer stands on its point')
    W.place(1, 580.0, 500.0, 30.0)
    W.tick(2)
    H.eq(van.status, 'parked', 'he stepped 60 m away: the coroner van is put on its point')
    H.ok(D(W.at(run, van.veh), point) < 0.5, 'on its point')
    H.ok(PlaceOf(run, van.veh) ~= nil, 'and waits for its placement')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                              NO TRANSPORT POINT
-- ============================================================================
-- NEVER ON THE SCENE (WHERE THE ARREST HAPPENED).

do
    local run = HoldRun({ 1 })
    local scene = vec3(500.0, 500.0, 30.0)
    W.place(1, 502.0, 500.0, 30.0)
    W.roadPoint = function(_, args)
        if args.min < 100.0 then
            return { coords = { x = args.near.x, y = args.near.y + 45.0, z = args.near.z }, heading = 0.0 }
        end
        return nil
    end
    local van = Custody.requestTransport(run, scene, { obj = 1 })
    W.tick(TIMEOUT + 5)
    H.eq(van.status, 'parked', 'the van is there after the fallback')
    local vc = W.at(run, van.veh)
    H.ok(vc and D(vc, scene) >= 30.0, ('not on the scene (%.1f m from it)'):format(vc and D(vc, scene) or -1))
    H.ok(vc and D(vc, scene) <= Config.Custody.transport.parkWithin,
        'within parkWithin of the scene, where an officer can walk the prisoner to it')
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--     A LATE VAN IS PUT ON ITS PARKING POINT ONLY ONCE NOBODY STANDS ON IT
-- ============================================================================

do
    local run = HoldRun({ 1 })
    local point = vec4(520.0, 500.0, 30.0, 90.0)
    W.place(1, 700.0, 700.0, 30.0)
    W.roadPoint = function(_, args)
        if args.min >= 100.0 then
            return { coords = { x = args.near.x + 200.0, y = args.near.y, z = args.near.z }, heading = 90.0 }
        end
        return nil
    end
    local van = Custody.requestTransport(run, vec3(500.0, 500.0, 30.0), { obj = 1, point = point })
    W.tick(2)
    H.eq(van.status, 'coming', 'the van drives in from its road point')
    local first = PlaceOf(run, van.veh)
    H.ok(first and first.token, 'made frozen there, waiting for its placement')
    H.fire('crimson-police:server:spawnPlaced', 1, run.id,
        { netId = van.veh, token = first.token, result = 'placed', reason = 'ok', z = first.z })
    H.eq(PlaceOf(run, van.veh), nil, 'an officer\'s game put it on the road: it drives')
    local road = W.at(run, van.veh)
    -- it never arrives; the officer stands on the transport point
    W.place(1, 520.5, 500.0, 30.0)
    W.tick(TIMEOUT + 2)
    H.eq(van.status, 'coming', 'late, but an officer stands on its parking point: it is not put on him')
    H.ok(D(W.at(run, van.veh), road) < 0.01, 'it stays where it drives')
    H.eq(PlaceOf(run, van.veh), nil, 'and asks for no placement')
    W.place(1, 580.0, 500.0, 30.0)
    W.tick(1)
    H.eq(van.status, 'parked', 'the officer stepped away: the late van is put on its parking point')
    H.ok(van.placed, 'placed')
    local at = W.at(run, van.veh)
    H.ok(D(at, point) < 0.01, 'on its parking point')
    local place = PlaceOf(run, van.veh)
    H.ok(place ~= nil, 'no raw move: it waits frozen there for an officer\'s game to put it on the ground')
    H.ok(place and place.token ~= first.token, 'a new ask (new token)')
    H.ok(place and math.abs(place.x - point.x) < 0.01 and math.abs(place.y - point.y) < 0.01, 'at the parking point')
    H.ok(place and place.from and math.abs(place.from.x - road.x) < 0.01 and math.abs(place.from.y - road.y) < 0.01,
        'from where it was driving (the placer moves it first when the move has not reached its game)')
    H.fire('crimson-police:server:spawnPlaced', 1, run.id,
        { netId = van.veh, token = place.token, result = 'placed', reason = 'snap', z = point.z - 0.3 })
    H.eq(PlaceOf(run, van.veh), nil, 'placed: the ask is over')
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--  A ROAD POINT AN OFFICER WALKS ONTO WHILE THE VAN WAITS FOR ROOM IS DROPPED
-- ============================================================================

do
    local run = HoldRun({ 1 })
    W.place(1, 505.0, 500.0, 30.0)
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 200.0, y = args.near.y, z = args.near.z }, heading = 90.0 }
    end
    local fill = {}
    while Runs.canSpawn(run, 1, false) do
        local _, n = Runs.spawnObject(run, { obj = 1, model = 'prop_cone', coords = vec3(0.0, 0.0, 0.0) })
        fill[#fill + 1] = n
    end
    local van = Custody.serviceVehicle(run, 'transport', vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(2)
    H.eq(van.status, 'pending', 'at the entity cap the van waits')
    H.ok(van.roadPoint ~= nil, 'with its checked road point')
    W.place(1, 705.0, 500.0, 30.0)
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x, y = args.near.y + 200.0, z = args.near.z }, heading = 0.0 }
    end
    Runs.deleteEntity(run, table.remove(fill))
    Runs.deleteEntity(run, table.remove(fill))
    W.tick(5)
    H.eq(van.status, 'coming', 'with room it spawns')
    local vc = W.at(run, van.veh)
    H.ok(vc and D(vc, vec3(700.0, 500.0, 30.0)) > 30.0, 'not on the road point the officer walked onto')
    H.ok(vc and Nearest(vc) >= 30.0, 'on a new one, away from every player')
    for _, n in ipairs(fill) do Runs.deleteEntity(run, n) end
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--         A TOW TRUCK WITH NO ROAD POINT IS NEVER MADE INSIDE THE CAR
-- ============================================================================

do
    local run = HoldRun({ 1 })
    local _, carNet = Runs.spawnVehicle(run,
        { obj = 1, model = 'asea', coords = vec4(600.0, 600.0, 30.0, 0.0), role = 'parked' })
    local car = Custody.register(run, 1, carNet, {
        kind = 'vehicle',
        role = 'parked',
        truth = 'stolen',
        demeanour = 'compliant',
        cues = {},
        actions = { 'runPlate', 'impound' },
    })
    W.place(1, 602.0, 600.0, 30.0)
    W.roadPoint = nil
    local mark = #W.bagWrites
    H.eq(Custody.impound(run, carNet, 1), true, 'impound calls the tow truck')
    local tow = nil
    for _, s in ipairs(Custody._servicesOf(run)) do if s.kind == 'tow' then tow = s end end
    W.tick(TIMEOUT + 2)
    H.eq(car.state, 'impounded', 'no road point within serviceTimeout: the car fades out as impounded')
    H.eq(run.entities[carNet], nil, 'and is removed')
    H.eq(tow and tow.status, 'gone', 'the tow truck is done')
    H.eq(tow and tow.veh, nil, 'never made (it was put inside the car, beside the officer, and never loaded it)')
    H.eq(Made('flatbed', mark), 0, 'no flatbed in the run')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                  Config.Spawning.enabled = FALSE: AS BEFORE
-- ============================================================================

do
    Config.Spawning.enabled = false
    local run = HoldRun({ 1 })
    local point = vec4(520.0, 500.0, 30.0, 90.0)
    W.place(1, 521.0, 500.0, 30.0)
    W.roadPoint = nil
    local van = Custody.requestTransport(run, vec3(500.0, 500.0, 30.0), { obj = 1, point = point })
    W.tick(TIMEOUT + 2)
    H.eq(van.status, 'parked', 'enabled = false: placed on its parking point after serviceTimeout, as before')
    H.ok(D(W.at(run, van.veh), point) < 0.01, 'on the transport point')
    Config.Spawning.enabled = true
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                        THE VAN ON EVERY OFFICER'S MAP
-- ============================================================================
-- PLAN M7, client:serviceBlip.
-- From its spawn until it drives off, sent when its status changes (never on a timer); a late partner gets it when
-- he arrives; a tow truck that was never made and the coroner van send none.

do
    local EV = 'crimson-police:client:serviceBlip'
    local function Sent(from)
        local out = {}
        for i = from + 1, #H.events do
            local e = H.events[i]
            if e.kind == 'client' and e.name == EV then out[#out + 1] = { to = e.target, data = e.args[1] } end
        end
        return out
    end
    local function To(list)
        local out = {}
        for _, x in ipairs(list) do out[#out + 1] = tostring(x.to) end
        table.sort(out)
        return table.concat(out, ',')
    end
    local run = HoldRun({ 1, 2 })
    W.place(1, 3100.0, 3000.0, 30.0)
    W.place(2, 3200.0, 3000.0, 30.0)
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 200.0, y = args.near.y, z = args.near.z }, heading = 90.0 }
    end
    local mark = #H.events
    local van = Custody.requestTransport(run, vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(3)
    H.eq(van.status, 'coming', 'blip: the van spawned and drives in')
    local s = Sent(mark)
    H.eq(To(s), '1,2', 'blip: sent to both officers once it spawned')
    local d = s[1] and s[1].data or {}
    H.ok(d.runId == run.id and d.id == van.id and d.kind == 'prisonerVan' and d.show == true and d.netId == van.veh,
        'blip: the run, the van\'s id and net id, kinds.prisonerVan')
    H.ok(d.coords and D(d.coords, vec3(700.0, 500.0, 30.0)) < 1.0, 'blip: where the server has it')
    mark = #H.events
    W.tick(20)
    H.eq(#Sent(mark), 0, 'blip: nothing more while it drives (no timer)')

    -- a partner who arrives late gets it (run:arrived)
    CP.Hooks.fire('run:arrived', run, 3, false)
    s = Sent(mark)
    H.ok(#s == 1 and s[1].to == 3 and s[1].data.show == true and s[1].data.netId == van.veh,
        'blip: a late partner gets the van already on the others\' maps')

    -- late: put on its parking point (one update each, at its new spot)
    mark = #H.events
    W.tick(TIMEOUT)
    H.eq(van.status, 'parked', 'blip: late, it is put on its parking point')
    s = Sent(mark)
    H.ok(To(s) == '1,2' and s[1].data.show == true and D(s[1].data.coords, vec3(500.0, 500.0, 30.0)) < 1.0,
        'blip: moved to the parking point for everyone')

    -- the arrest objective done: it drives off after leaveAfter, its blip goes, and nothing once it is gone
    run.objectives[1].status = 'done'
    mark = #H.events
    W.tick(Config.Custody.transport.leaveAfter + 2)
    H.eq(van.status, 'leaving', 'blip: it drives off')
    s = Sent(mark)
    H.ok(To(s) == '1,2' and s[1].data.show == false and s[1].data.netId == nil, 'blip: off every map as it leaves')
    mark = #H.events
    W.tick(30)
    H.eq(van.status, 'gone', 'blip: then it is gone')
    H.eq(#Sent(mark), 0, 'blip: nothing more once gone')
    CP.Hooks.fire('run:arrived', run, 4, false)
    H.eq(#Sent(mark), 0, 'blip: a partner arriving now gets none')
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')

    -- a tow truck that was never made (no road point) and a coroner van: no blip at all
    run = HoldRun({ 1 })
    local _, carNet = Runs.spawnVehicle(run,
        { obj = 1, model = 'asea', coords = vec4(600.0, 600.0, 30.0, 0.0), role = 'parked' })
    Custody.register(run, 1, carNet, {
        kind = 'vehicle',
        role = 'parked',
        truth = 'stolen',
        demeanour = 'compliant',
        cues = {},
        actions = { 'runPlate', 'impound' },
    })
    W.place(1, 602.0, 600.0, 30.0)
    mark = #H.events
    H.eq(Custody.impound(run, carNet, 1), true, 'blip: impound calls the tow truck')
    W.tick(TIMEOUT + 2)
    H.eq(#Sent(mark), 0, 'blip: a tow truck never made sends no blip')
    W.place(1, 3100.0, 3000.0, 30.0)
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 200.0, y = args.near.y, z = args.near.z }, heading = 90.0 }
    end
    local coroner = Custody.serviceVehicle(run, 'coroner', vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(3)
    H.eq(coroner.status, 'coming', 'blip: the coroner van drives in')
    H.eq(#Sent(mark), 0, 'blip: the coroner van stays unmarked')
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

return H
