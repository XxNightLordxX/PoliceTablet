-- tests/fixtures/engine_b/client_spec.lua · the client half of the run engine (modules/runs/client.lua).
-- Run in its own process by tests/engine_b_spec.lua (the harness boots one side per process); prints
-- "RESULT <passes> <failures>" on the last line.
local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ── client natives ──────────────────────────────────────────────────────────
local me = { ped = 100, veh = 0, siren = false, armed = false, shooting = false }
local networked = { [500] = 55, [600] = 66 }
local fromNet = { [55] = 500, [66] = 600 }
local controlled = {}
_G.PlayerPedId = function() return me.ped end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.GetEntityCoords = function() return vec3(1.0, 2.0, 3.0) end
_G.GetVehiclePedIsIn = function() return me.veh end
_G.GetPedInVehicleSeat = function(veh) return veh == me.veh and me.ped or 0 end
_G.NetworkGetEntityIsNetworked = function(e) return networked[e] ~= nil end
_G.NetworkGetNetworkIdFromEntity = function(e) return networked[e] or 0 end
_G.NetworkDoesNetworkIdExist = function(n) return fromNet[n] ~= nil end
_G.NetworkGetEntityFromNetworkId = function(n) return fromNet[n] or 0 end
_G.DoesEntityExist = function(e) return e == 500 or e == 600 or e == 700 or e == me.ped end
_G.NetworkHasControlOfEntity = function(e) return controlled[e] == true end
_G.NetworkRequestControlOfEntity = function(e) controlled[e] = true end
_G.IsVehicleSirenOn = function() return me.siren end
_G.IsPedArmed = function() return me.armed end
_G.IsPedShooting = function() return me.shooting end
_G.IsEntityAPed = function(e) return e == 600 or e == 700 end
_G.IsPedAPlayer = function() return false end
local waypoint
_G.SetNewWaypoint = function(x, y) waypoint = { x, y } end
_G.Entity = function(e)
    -- Entity(e).state is only valid for networked entities (it reads the network id).
    if not networked[e] then error('Entity() on a local entity ' .. tostring(e)) end
    return { state = {} }
end
local blips, nextBlip = {}, 900
_G.AddBlipForRadius = function(x, y, z, r) nextBlip = nextBlip + 1; blips[nextBlip] = { x = x, y = y, z = z, r = r }; return nextBlip end
_G.SetBlipColour = function(b, c) if blips[b] then blips[b].colour = c end end
_G.SetBlipAlpha = function(b, a) if blips[b] then blips[b].alpha = a end end
_G.DoesBlipExist = function(b) return blips[b] ~= nil end
_G.RemoveBlip = function(b) blips[b] = nil end
local function blipCount() local n = 0; for _ in pairs(blips) do n = n + 1 end return n end

-- ── stubs ───────────────────────────────────────────────────────────────────
local hudLog, results, actions, routeLog = {}, {}, {}, {}
local hudState = nil
CP.Tablet = {
    hud = function(patch)
        hudLog[#hudLog + 1] = patch or 'nil'
        if patch == nil then hudState = nil return end
        hudState = hudState or {}
        local nullable = { modifier = true, timer = true, route = true, message = true, detail = true }
        for k, v in pairs(patch) do if v == false and nullable[k] then hudState[k] = nil else hudState[k] = v end end
    end,
    result = function(r) results[#results + 1] = r end,
    registerClientAction = function(name, fn) actions[name] = fn end,
}
CP.Route = {
    begin = function(runId, coords, opts) routeLog[#routeLog + 1] = { 'begin', runId, coords, opts } end,
    stop = function() routeLog[#routeLog + 1] = { 'stop' } end,
}

local calls = {}
local function rec(name, ctx, a) calls[#calls + 1] = { name = name, index = ctx.index, a = a, ctx = ctx } end
local function callsOf(name, index)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name and (index == nil or c.index == index) then out[#out + 1] = c end end
    return out
end
CP.Blocks.register('test_block', {
    prepare = function(ctx) rec('prepare', ctx) end,
    start = function(ctx) rec('start', ctx); ctx.state.started = true end,
    update = function(ctx, data) rec('update', ctx, data) end,
    hostChanged = function(ctx, isHost) rec('hostChanged', ctx, isHost) end,
    stop = function(ctx) rec('stop', ctx) end,
})

H.load('modules/runs/client.lua')
local Runs = CP.Runs
H.ok(actions.logResult ~= nil, 'logResult client action registered')
H.eq(Runs.current(), nil, 'no run')
H.eq(select(2, actions.logResult({ point = 1, choice = 'secure' })), 'err.not_on_run', 'log without a run')

local function serverEvents(name)
    local out = {}
    for _, e in ipairs(H.events) do if e.kind == 'server' and e.name == name then out[#out + 1] = e end end
    return out
end

-- client:start
local mission = { id = 'beat_patrol', label = 'Beat Patrol', objectives = { { block = 'test_block', label = 'A', count = 1 }, { block = 'test_block', label = 'B' } } }
H.fire('crimson-police:client:start', nil, 'run-1', {
    missionId = 'beat_patrol', mission = mission, locationIndex = 2,
    location = { label = 'L', start = { coords = vec3(10.0, 20.0, 30.0), radius = 10.0 } },
    start = { coords = vec3(10.0, 20.0, 30.0), radius = 10.0 }, expectedTier = 'reinforced', seed = 42, host = 1,
    test = nil, modifier = 'radio_silence', startRoute = true, startTimeout = 600, isBoss = false,
    participants = { { src = 1, name = 'A', status = 'active', arrived = false }, { src = 2, name = 'B', status = 'active', arrived = false } },
})
local cur = Runs.current()
H.eq(cur.id, 'run-1', 'current run')
H.eq(cur.isHost, true, 'host flag')
H.eq(cur.state, 'accepted', 'accepted')
H.eq(hudLog[1], 'nil', 'HUD reset first')
H.eq(hudState.phase, 'route', 'HUD route phase')
H.eq(hudState.tier, 'reinforced', 'HUD expected tier')
H.eq(hudState.modifier.key, 'radio_silence', 'HUD modifier')
H.eq(hudState.route.status, 'on', 'HUD route on')
H.eq(hudState.testControls, false, 'no test controls')
H.eq(routeLog[1][1], 'begin', 'CP.Route.begin on start')
H.eq(routeLog[1][3].x, 10.0, 'route to the start coords')

-- client:inProgress + objective actions
H.fire('crimson-police:client:inProgress', nil, 'run-1', { tier = 'reinforced', payTier = 'reinforced', objectives = { { block = 'test_block', label = 'A', count = 2 }, { block = 'test_block', label = 'B' } }, timeLimit = 480, remaining = 480 })
H.eq(cur.state, 'in_progress', 'in progress')
H.eq(hudState.phase, 'objectives', 'HUD objectives phase')
H.eq(hudState.timer.remaining, 480, 'HUD timer')
H.fire('crimson-police:client:objective', nil, 'run-1', 1, { action = 'prepare' })
H.fire('crimson-police:client:objective', nil, 'run-1', 2, { action = 'prepare' })
H.fire('crimson-police:client:objective', nil, 'run-1', 1, { action = 'start' })
H.eq(#callsOf('prepare'), 2, 'prepare for every objective')
local ctx = callsOf('start', 1)[1].ctx
H.eq(ctx.obj.count, 2, 'client ctx.obj is the scaled objective')
H.eq(ctx.base.count, 1, 'client ctx.base is the unscaled objective')
H.eq(ctx.runId, 'run-1', 'ctx.runId')
H.eq(ctx.radioSilence, true, 'ctx.radioSilence')
H.eq(ctx.isHost, true, 'ctx.isHost')
H.eq(ctx.seed, 42, 'ctx.seed')
H.eq(#ctx.participants, 2, 'ctx.participants')
H.eq(callsOf('prepare', 1)[1].ctx.state.started, true, 'ctx.state persists across hooks')
H.fire('crimson-police:client:objective', nil, 'run-1', 1, { action = 'update', data = { n = 3 } })
H.eq(callsOf('update', 1)[1].a.n, 3, 'update data')
H.fire('crimson-police:client:objective', nil, 'run-1', 1, { action = 'bogus' })
H.fire('crimson-police:client:objective', nil, 'other-run', 1, { action = 'stop' })
H.eq(#callsOf('stop'), 0, 'bad action / other run ignored')

-- evidence and HUD detail
H.reset()
ctx.report({ type = 'checkpoint', index = 3 })
local ev = serverEvents('crimson-police:server:objective')[1]
H.eq(ev.args[1], 'run-1', 'report runId')
H.eq(ev.args[2], 1, 'report index')
H.eq(ev.args[3].type, 'checkpoint', 'report evidence')
H.eq(ev.args[3].coords.x, 1.0, 'report adds coords')
H.ok(type(ev.args[3].time) == 'number', 'report adds time')
ctx.hudDetail('Hold still: 6 s')
H.eq(hudState.detail, 'Hold still: 6 s', 'hudDetail')
ctx.hudDetail(nil)
H.eq(hudState.detail, nil, 'hudDetail cleared')
H.ok(actions.logResult({ point = 2, choice = 'secure' }), 'logResult')
local lg = serverEvents('crimson-police:server:objective')[2]
H.eq(lg.args[3].type, 'log', 'log evidence type')
H.eq(lg.args[3].point, 2, 'log point')
H.eq(select(2, actions.logResult({ point = 'x', choice = 'secure' })), 'err.invalid_payload', 'bad log payload')

-- server HUD patches and messages
H.fire('crimson-police:client:hud', nil, 'run-1', { objectives = { { label = 'A', done = false, current = true } }, message = { text = 'Hello', kind = 'info' } })
H.eq(hudState.message.text, 'Hello', 'HUD message')
H.eq(#hudState.objectives, 1, 'HUD objectives')
H.advance(8100)
H.eq(hudState.message, nil, 'HUD message clears itself')

-- entities
H.eq(Runs.getEntity(55, 0), 500, 'getEntity')
H.eq(Runs.getEntity(99, 0), nil, 'getEntity missing')
H.ok(Runs.control(500, 100), 'control as host')

-- telemetry
H.reset()
me.veh = 500
me.siren = true
H.advance(5000)
local tel = serverEvents('crimson-police:server:telemetry')
local kinds = {}
for _, e in ipairs(tel) do kinds[e.args[2]] = (kinds[e.args[2]] or 0) + 1 end
H.eq(kinds.lights_siren, 1, 'lights and siren once on Beat Patrol')
H.ok((kinds.vehicle or 0) >= 1, 'vehicle netId while driving')
H.eq(tel[#tel].args[3].netId ~= nil, true, 'telemetry data')
me.armed, me.shooting = true, true
H.advance(1000)
me.armed, me.shooting = false, false
kinds = {}
for _, e in ipairs(serverEvents('crimson-police:server:telemetry')) do kinds[e.args[2]] = (kinds[e.args[2]] or 0) + 1 end
H.eq(kinds.weapon_fired, 1, 'weapon fired once')
H.reset()
TriggerEvent('gameEventTriggered', 'CEventNetworkEntityDamage', { 600, 500, 0, 0, 0, 0, 0 })
TriggerEvent('gameEventTriggered', 'CEventNetworkEntityDamage', { 600, 500, 0, 0, 0, 0, 0 })
local hits = 0
for _, e in ipairs(serverEvents('crimson-police:server:telemetry')) do if e.args[2] == 'ped_hit' then hits = hits + 1; H.eq(e.args[3].netId, 66, 'ped hit netId') end end
H.eq(hits, 1, 'ped hit reported once')

-- tier, host and participants
H.fire('crimson-police:client:tierChanged', nil, 'run-1', 'standard', 'reinforced', { [2] = { block = 'test_block', label = 'B', count = 1 } })
H.eq(hudState.tier, 'standard', 'HUD tier changed')
H.eq(hudState.payTier, 'reinforced', 'HUD pay tier kept')
H.eq(callsOf('prepare', 2)[1].ctx.obj.count, 1, 'rescaled objectives reach ctx.obj')
H.fire('crimson-police:client:hostChanged', nil, 'run-1', 2)
H.eq(cur.isHost, false, 'no longer host')
H.eq(callsOf('hostChanged', 1)[1].a, false, 'block hostChanged')
H.eq(ctx.isHost, false, 'ctx.isHost updated')
H.eq(Runs.control(500, 0), false, 'control only for the host')
local stops = #routeLog
H.fire('crimson-police:client:participants', nil, 'run-1', { { src = 1, status = 'active', arrived = true }, { src = 2, status = 'left', arrived = false } })
H.eq(routeLog[#routeLog][1], 'stop', 'route stopped on own arrival')
H.eq(#routeLog, stops + 1, 'route stopped once')
H.eq(#ctx.participants, 1, 'ctx.participants follows the run')

-- run ended
H.fire('crimson-police:client:runEnded', nil, 'run-1', 'abandoned', 'real_call', { runId = 'run-1', result = 'abandoned' })
H.eq(Runs.current(), nil, 'run cleared')
H.eq(#callsOf('stop'), 2, 'every prepared block stopped')
H.eq(hudState.phase, 'ended', 'HUD ended')
H.eq(hudState.message.text, 'run.ended_real_call', 'end message for a real call')
H.eq(hudState.message.kind, 'info', 'real call message kind')
H.eq(results[#results].runId, 'run-1', 'result screen shown')
H.eq(routeLog[#routeLog][1], 'stop', 'route stopped at the end')
H.reset()
me.veh = 500
H.advance(12500)
H.eq(hudState, nil, 'HUD hidden after the end')
H.eq(#serverEvents('crimson-police:server:telemetry'), 0, 'telemetry loops stopped with the run')

-- a failed mission shows the block's reason; test runs show the test controls
H.fire('crimson-police:client:start', nil, 'run-2', {
    missionId = 'x', mission = { id = 'x', label = 'X', objectives = { { block = 'test_block', label = 'A' } } },
    location = { start = { coords = vec3(0, 0, 0), radius = 5.0 } }, start = { coords = vec3(5.0, 6.0, 0.0), radius = 5.0 },
    expectedTier = 'heavy', seed = 1, host = 1, test = { adminSrc = 1, useStartRoute = false, forcedTier = 'heavy' }, startRoute = false,
    participants = { { src = 1, status = 'active' } },
})
H.eq(hudState.test, true, 'TEST RUN banner')
H.eq(hudState.testControls, true, 'test controls for the admin who started it')
H.eq(hudState.route.status, 'disabled', 'route off in the HUD')
H.eq(routeLog[#routeLog][1], 'begin', 'CP.Route.begin also for a test with the route off')
H.eq(routeLog[#routeLog][4].startRoute, false, 'route begun without the checks')
H.eq(waypoint, nil, 'CP.Route sets the waypoint itself')
H.fire('crimson-police:client:runEnded', nil, 'run-2', 'failed', 'mission_failed', { failReason = 'run.fail_killed_unarmed' })
H.eq(hudState.message.text, 'run.fail_killed_unarmed', 'fail reason shown')
H.eq(hudState.message.kind, 'error', 'failed message kind')

-- resource stop cleans up
H.fire('crimson-police:client:start', nil, 'run-3', {
    missionId = 'x', mission = { id = 'x', label = 'X', objectives = { { block = 'test_block', label = 'A' } } },
    location = { start = { coords = vec3(0, 0, 0), radius = 5.0 } }, start = { coords = vec3(0, 0, 0), radius = 5.0 },
    expectedTier = 'standard', seed = 1, host = 1, startRoute = true, participants = {},
})
H.fire('crimson-police:client:inProgress', nil, 'run-3', { objectives = { { block = 'test_block', label = 'A' } }, remaining = 60 })
H.fire('crimson-police:client:objective', nil, 'run-3', 1, { action = 'prepare' })
local stopsBefore = #callsOf('stop')
TriggerEvent('onResourceStop', 'Crimson-Police')
H.eq(#callsOf('stop'), stopsBefore + 1, 'blocks stopped on resource stop')
H.eq(Runs.current(), nil, 'no run after resource stop')
H.eq(hudState, nil, 'HUD hidden on resource stop')

-- ── review: pedestrian hits on local-only peds, the Manhunt start circle ────
me.veh = 500
H.fire('crimson-police:client:start', nil, 'run-4', {
    missionId = 'manhunt', mission = { id = 'manhunt', label = 'Manhunt', objectives = { { block = 'test_block', label = 'Search' } } },
    location = { start = { coords = vec3(1740.0, 3720.0, 33.8), radius = 600.0 } }, start = { coords = vec3(1740.0, 3720.0, 33.8), radius = 600.0 },
    expectedTier = 'standard', seed = 1, host = 1, startRoute = true, participants = { { src = 1, status = 'active', arrived = false } },
})
H.eq(blipCount(), 1, 'a 600 m start circle is shown on the map at accept')
local circle = blips[nextBlip]
H.eq(circle and circle.r, 600.0, 'with the start radius')
H.reset()
local okHit, errHit = pcall(TriggerEvent, 'gameEventTriggered', 'CEventNetworkEntityDamage', { 700, 500, 0, 0, 0, 0, 0 })
H.ok(okHit, 'a local-only ped hit never touches its state bag: ' .. tostring(errHit))
H.eq(#serverEvents('crimson-police:server:telemetry'), 0, 'and is not reported')
H.fire('crimson-police:client:inProgress', nil, 'run-4', { objectives = { { block = 'test_block', label = 'Search' } }, remaining = 720 })
H.fire('crimson-police:client:objective', nil, 'run-4', 1, { action = 'prepare' })
H.eq(blipCount(), 1, 'the circle stays while the objective is prepared')
H.fire('crimson-police:client:objective', nil, 'run-4', 1, { action = 'start' })
H.eq(blipCount(), 0, 'the block takes over the circle when the objective starts')
H.fire('crimson-police:client:runEnded', nil, 'run-4', 'abandoned', 'quit', nil)

H.fire('crimson-police:client:start', nil, 'run-5', {
    missionId = 'manhunt', mission = { id = 'manhunt', label = 'Manhunt', objectives = { { block = 'test_block', label = 'Search' } } },
    location = { start = { coords = vec3(0, 0, 0), radius = 600.0 } }, start = { coords = vec3(0, 0, 0), radius = 600.0 },
    expectedTier = 'standard', seed = 1, host = 1, startRoute = true, participants = { { src = 1, status = 'active', arrived = false } },
})
H.eq(blipCount(), 1, 'circle for the next run')
H.fire('crimson-police:client:participants', nil, 'run-5', { { src = 1, status = 'active', arrived = true } })
H.eq(blipCount(), 0, 'the circle goes when this officer is inside it')
H.fire('crimson-police:client:runEnded', nil, 'run-5', 'abandoned', 'quit', nil)
H.fire('crimson-police:client:start', nil, 'run-6', {
    missionId = 'manhunt', mission = { id = 'manhunt', label = 'Manhunt', objectives = { { block = 'test_block', label = 'Search' } } },
    location = { start = { coords = vec3(0, 0, 0), radius = 600.0 } }, start = { coords = vec3(0, 0, 0), radius = 600.0 },
    expectedTier = 'standard', seed = 1, host = 1, startRoute = true, participants = { { src = 1, status = 'active', arrived = false } },
})
H.fire('crimson-police:client:runEnded', nil, 'run-6', 'abandoned', 'start_timeout', nil)
H.eq(blipCount(), 0, 'the circle is removed when the run ends')
H.fire('crimson-police:client:start', nil, 'run-7', {
    missionId = 'beat_patrol', mission = { id = 'beat_patrol', label = 'Beat Patrol', objectives = { { block = 'test_block', label = 'A' } } },
    location = { start = { coords = vec3(0, 0, 0), radius = 10.0 } }, start = { coords = vec3(0, 0, 0), radius = 10.0 },
    expectedTier = 'standard', seed = 1, host = 1, startRoute = true, participants = {},
})
H.eq(blipCount(), 0, 'a point start gets no circle')
TriggerEvent('onResourceStop', 'Crimson-Police')

print(('RESULT %d %d'):format(H.passes, H.failures))
return H
