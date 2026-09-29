-- tests/blocks_a_spec.lua · objective blocks checkpoint_route, interact_points and skill_check
-- (server halves) driven with a fake ctx, plus the locale part check for every key the six files use.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- Use this slice's locale part as the locale so labels resolve like they will in en.json.
do
    local orig = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return orig(res, 'locales/parts/blocks_a.json') end
        return orig(res, path)
    end
    H.load('shared/locale.lua')
    _G.LoadResourceFile = orig
end

-- ── natives: player vehicles, props ─────────────────────────────────────────
local vehicles, byNet, props = {}, {}, {}
local function addVehicle(ent, netId, spec)
    spec = spec or {}
    vehicles[ent] = {
        netId = netId, model = spec.model or joaat('police'),
        engine = spec.engine or 1000.0, body = spec.body or 1000.0, tank = spec.tank or 1000.0, exists = true,
    }
    byNet[netId] = ent
    return vehicles[ent]
end
_G.GetVehiclePedIsIn = function(ped, last)
    local p = H.players[ped // 100]
    if not p then return 0 end
    if last then return p.lastVehicle or p.vehicle or 0 end
    return p.vehicle or 0
end
-- The driver seat (-1) holds the ped (src * 100) of the player in that vehicle, unless the player is marked
-- as a passenger (H.players[src].passenger = true).
_G.GetPedInVehicleSeat = function(veh, seat)
    if seat ~= -1 or not veh or veh == 0 then return 0 end
    for src, p in pairs(H.players) do
        if p.vehicle == veh and not p.passenger then return src * 100 end
    end
    return 0
end
_G.GetEntityModel = function(ent) return vehicles[ent] and vehicles[ent].model or 0 end
-- FiveM has no server-side vehicle class: the server half must never ask for one.
local classAsked = 0
_G.GetVehicleClass = function() classAsked = classAsked + 1; error('the server must not read a vehicle class') end
_G.NetworkGetEntityFromNetworkId = function(netId) return byNet[netId] or 0 end
_G.NetworkGetNetworkIdFromEntity = function(ent)
    if vehicles[ent] then return vehicles[ent].netId end
    if props[ent] then return props[ent].netId end
    return 0
end
_G.DoesEntityExist = function(ent)
    if vehicles[ent] then return vehicles[ent].exists end
    if props[ent] then return true end
    return ent ~= nil and ent ~= 0
end
_G.GetVehicleEngineHealth = function(ent) return vehicles[ent] and vehicles[ent].engine or 0.0 end
_G.GetVehicleBodyHealth = function(ent) return vehicles[ent] and vehicles[ent].body or 0.0 end
_G.GetVehiclePetrolTankHealth = function(ent) return vehicles[ent] and vehicles[ent].tank or 0.0 end
local playerCoords = GetEntityCoords
_G.GetEntityCoords = function(ent)
    if props[ent] then return props[ent].coords end
    return playerCoords(ent)
end

local serverSpeeds = {}   -- server GetEntitySpeed (OneSync copy of the entity)
_G.GetEntitySpeed = function(ent) return serverSpeeds[ent] or 0.0 end

local timerAdjust, timerPause = {}, {}
CP.Runs = {
    adjustTimer = function(run, seconds) timerAdjust[#timerAdjust + 1] = seconds end,
    pauseTimer = function(run, paused)
        timerPause[#timerPause + 1] = paused
        run.timer = run.timer or {}
        run.timer.paused = paused
    end,
}

H.load('blocks/checkpoint_route/server.lua')
H.load('blocks/interact_points/server.lua')
H.load('blocks/skill_check/server.lua')

local CR = CP.Blocks.get('checkpoint_route')
local IP = CP.Blocks.get('interact_points')
local SC = CP.Blocks.get('skill_check')
H.ok(CR and IP and SC, 'the three blocks registered')

-- ── fake ctx ────────────────────────────────────────────────────────────────
local nextNet = 900
local function fakeCtx(o)
    local run = o.run or {
        id = 'run-1', seed = o.seed or 1234, host = 1, flags = { medals = false }, shared = {},
        participants = {}, objectives = {},
    }
    run.mission, run.location = o.mission, o.location
    local obj = o.obj
    local ctx = {
        run = run, index = o.index or 1, obj = obj, base = CP.U.deepcopy(obj), mission = o.mission,
        location = o.location, tier = { tier = 'standard', count = 1.0 }, state = {},
        rng = CP.U.rng(run.seed + (o.index or 1)),
    }
    local calls = { complete = 0, fail = {}, award = {}, awardOpts = {}, penalize = {}, send = {}, hud = {}, spawn = {}, delete = {}, canSpawn = 0 }
    ctx.calls = calls
    ctx.completeResult = true
    ctx.capOk = true
    ctx.srcs = o.srcs or { 1 }
    ctx.complete = function(data) calls.complete = calls.complete + 1; return ctx.completeResult end
    ctx.fail = function(key) calls.fail[#calls.fail + 1] = key end
    ctx.award = function(id, opts)
        calls.award[#calls.award + 1] = id
        calls.awardOpts[#calls.awardOpts + 1] = { id = id, opts = opts }
    end
    ctx.penalize = function(id, opts) calls.penalize[#calls.penalize + 1] = id end
    ctx.send = function(data) calls.send[#calls.send + 1] = CP.U.deepcopy(data) end
    ctx.hud = function(patch) calls.hud[#calls.hud + 1] = patch end
    ctx.canSpawn = function(n, armed) calls.canSpawn = calls.canSpawn + 1; return ctx.capOk end
    local function spawn(kind)
        return function(opts)
            nextNet = nextNet + 1
            local ent = nextNet * 10
            calls.spawn[#calls.spawn + 1] = { kind = kind, opts = opts, netId = nextNet }
            props[ent] = { netId = nextNet, coords = vec3(CP.U.xyz(opts.coords)) }
            byNet[nextNet] = ent
            return ent, nextNet
        end
    end
    ctx.spawnPed, ctx.spawnVehicle, ctx.spawnObject = spawn('ped'), spawn('vehicle'), spawn('object')
    ctx.delete = function(netId) calls.delete[#calls.delete + 1] = netId end
    ctx.participants = function() return ctx.srcs end
    ctx.coords = function(src) return H.players[src] and H.players[src].coords end
    ctx.isHost = function(src) return src == run.host end
    ctx.host = function() return run.host end
    ctx.combat = function(a, b) return a, b end
    return ctx
end

local function lastSend(ctx) return ctx.calls.send[#ctx.calls.send] end
local function contains(list, v) return CP.U.contains(list, v) end
local function count(list, v)
    local n = 0
    for _, x in ipairs(list) do if x == v then n = n + 1 end end
    return n
end
local function at(src, v) H.players[src] = H.players[src] or {}; H.players[src].coords = vec3(v.x, v.y, v.z) end
local function advance(ms) H.clockMs = H.clockMs + ms end
local function reasonIs(reason, key) -- validate returns translated text; compare the template before its first {var}
    local text = CP.L(key)
    local prefix = text:match('^([^{]*)') or text
    return type(reason) == 'string' and reason:sub(1, #prefix) == prefix
end

-- ════════════════════════════════════════════════════════════════════════════
-- checkpoint_route
-- ════════════════════════════════════════════════════════════════════════════
local function spots(n, ox, oy)
    local out = {}
    for i = 1, n do out[i] = vec3((ox or 0.0) + i * 100.0, (oy or 0.0), 30.0) end
    return out
end

do -- defaults
    local o = CR.defaults({ block = 'checkpoint_route', checkpoints = 'spots' })
    H.eq(o.radius, 10.0, 'cr default radius')
    H.eq(o.stopFor, 10, 'cr default stopFor')
    H.eq(o.vehicleRequired, true, 'cr default vehicleRequired')
    H.eq(o.policeVehicle, nil, 'cr defaults write no policeVehicle')
    H.eq(o.medals, false, 'cr default medals')
    H.eq(o.contactPenalty, 2, 'cr default contactPenalty')
    H.eq(o.timerStart, 'first', 'cr default timerStart')
    H.eq(o.failIfUndriveable, true, 'cr default failIfUndriveable')
    H.eq(o.minSeconds, 20, 'cr default minSeconds')
    H.eq(o.presenceRange, 300, 'cr default presenceRange')
    H.eq(o.use, 'all', 'cr default use')
    local kept = CR.defaults({ checkpoints = 'x', radius = 5.0, stopFor = 0, vehicleRequired = false })
    H.eq(kept.radius, 5.0, 'cr keeps radius')
    H.eq(kept.stopFor, 0, 'cr keeps stopFor 0')
    H.eq(kept.vehicleRequired, false, 'cr keeps vehicleRequired false')
    -- published mission files may still use the old name: an alias, read without a warning
    local warned = 0
    local realWarn = CP.warn
    CP.warn = function(...) warned = warned + 1 end
    local old = CR.defaults({ checkpoints = 'x', policeVehicle = false })
    H.eq(old.vehicleRequired, false, 'the old policeVehicle = false is read as vehicleRequired = false')
    H.eq(old.policeVehicle, nil, 'the old name is dropped by defaults')
    H.eq(CR.defaults({ checkpoints = 'x', policeVehicle = true }).vehicleRequired, true, 'the old policeVehicle = true')
    H.eq(CR.defaults({ checkpoints = 'x', policeVehicle = false, vehicleRequired = true }).vehicleRequired, true, 'the new name wins over the old one')
    local oldLoc = { start = { coords = vec3(0.0, 0.0, 30.0), radius = 30.0 }, spots = spots(4) }
    H.eq(CR.validate({ block = 'checkpoint_route', checkpoints = 'spots', policeVehicle = true }, { locations = { oldLoc } }, oldLoc), true,
        'an objective with the old name validates')
    CP.warn = realWarn
    H.eq(warned, 0, 'the old name causes no warning')
    H.eq(CR.requiredPoints({ checkpoints = 'spots' })[1], 'spots', 'cr required points')
    H.eq(CR.armedCount({}), 0, 'cr armed count')
end

do -- validate
    local loc = { label = 'D1', start = { coords = vec3(300.0, 0.0, 30.0), radius = 30.0 }, spots = spots(8) }
    local mission = { locations = { loc, { label = 'D2', start = { coords = vec3(0.0, 5000.0, 30.0), radius = 30.0 }, spots = spots(9, 0.0, 5000.0) } } }
    local good = CR.defaults({ block = 'checkpoint_route', checkpoints = 'spots', use = 'random', count = 5 })
    H.eq(CR.validate(good, mission, loc), true, 'cr valid beat patrol')
    H.eq(CR.validate(good, mission, nil), true, 'cr valid across every location')
    local ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', use = 'random', count = 1 }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.range'), 'cr count below 2 rejected')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', radius = 25.0 }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.range'), 'cr radius out of range')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', stopFor = 31 }), mission, loc)
    H.ok(ok == false, 'cr stopFor out of range')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', contactPenalty = 11 }), mission, loc)
    H.ok(ok == false, 'cr contactPenalty out of range')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', use = 'random', count = 9 }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.points_count'), 'cr count above pool rejected')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'nope' }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.points_missing'), 'cr missing key rejected')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', use = 'zigzag' }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.use'), 'cr bad use rejected')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', medals = { gold = 100, silver = 90, bronze = 120 } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.medals'), 'cr unordered medals rejected')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', medals = true }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.location_medals'), 'cr medals=true needs location medals')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', timerStart = 'later' }), mission, loc)
    H.ok(ok == false, 'cr bad timerStart')
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots', vehicleRequired = 'yes' }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.flags'), 'cr vehicleRequired must be on or off')
    local evocLoc = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 30.0 }, course = { points = spots(12) }, medals = { gold = 60, silver = 80, bronze = 100 } }
    H.eq(CR.validate(CR.defaults({ checkpoints = 'course', stopFor = 0, medals = true }), { locations = { evocLoc } }, evocLoc), true, 'cr route format with location medals')
    local tooMany = { start = evocLoc.start, course = spots(21) }
    ok = CR.validate(CR.defaults({ checkpoints = 'course' }), { locations = { tooMany } }, tooMany)
    H.eq(ok, false, 'cr 21 checkpoints in use rejected')
    ok = CR.validate(CR.defaults({ checkpoints = 'spots', minSeconds = -1 }), mission, loc)
    H.eq(ok, false, 'cr negative minSeconds rejected')
    local mrpd = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 30.0 }, spots = { vec3(10.0, 0.0, 0.0), vec3(470.0, -970.0, 30.0) } }
    ok, why = CR.validate(CR.defaults({ checkpoints = 'spots' }), { locations = { mrpd } }, mrpd)
    H.ok(ok == false and reasonIs(why, 'block.checkpoint_route.invalid.points_zone'), 'cr checkpoint in a no-build zone rejected')
end

-- Beat Patrol: random 5 of 8, stop 10 s while driving a vehicle (any vehicle); the spot at the start comes first.
do
    H.clockMs = 100000
    local loc = { label = 'District', start = { coords = vec3(300.0, 0.0, 30.0), radius = 30.0 }, spots = spots(8) }
    local obj = CR.defaults({ block = 'checkpoint_route', checkpoints = 'spots', use = 'random', count = 5, contactPenalty = 0, failIfUndriveable = false })
    local ctx = fakeCtx({ obj = obj, location = loc, mission = { locations = { loc } }, seed = 777 })
    CR.prepare(ctx)
    H.eq(ctx.run.flags.medals, false, 'beat patrol leaves the fast bonus on')
    local st = ctx.state
    H.eq(#st.points, 5, 'beat patrol uses 5 checkpoints')
    H.eq(st.points[1].x, 300.0, 'the spot at the start marker is the first checkpoint')
    local seen = {}
    for _, p in ipairs(st.points) do
        H.ok(not seen[p.x], 'checkpoints are distinct'); seen[p.x] = true
    end
    -- same seed -> same checkpoints on every server call (and for every participant)
    local ctx2 = fakeCtx({ obj = CP.U.deepcopy(obj), location = loc, seed = 777 })
    CR.prepare(ctx2)
    for i = 1, 5 do H.eq(ctx2.state.points[i].x, st.points[i].x, 'deterministic checkpoint ' .. i) end

    CR.start(ctx)
    local snap = lastSend(ctx)
    H.eq(snap.kind, 'state', 'start sends a snapshot')
    H.eq(snap.total, 5, 'snapshot total')
    H.eq(snap.current, 1, 'snapshot current')

    at(1, vec3(0.0, 900.0, 30.0))
    H.players[1].vehicle = 0
    local okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.ok(okE == false and why == 'out_of_order', 'later checkpoint does not count first')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.ok(okE == false and why == 'too_far', 'too far from checkpoint 1')
    at(1, st.points[1])
    CR.tick(ctx, 1); advance(10000); CR.tick(ctx, 1)
    H.eq(st.near[1], nil, 'on foot: no stop time')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.ok(okE == false and why == 'not_in_vehicle', 'on foot rejected')
    -- a passenger is not driving: the server reads the driver seat itself, whatever the client reports
    addVehicle(5000, 50, { model = joaat('sultan') })
    H.players[1].vehicle = 5000
    H.players[1].passenger = true
    CR.tick(ctx, 1); advance(10000); CR.tick(ctx, 1)
    H.eq(st.near[1], nil, 'a passenger gets no stop time')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1, netId = 50, vehClass = 18, model = joaat('police') })
    H.ok(okE == false and why == 'not_driving', 'a passenger is rejected (a reported class 18 and police model change nothing)')
    H.players[1].passenger = nil
    -- a non-police vehicle completes the stop when the participant drives it
    CR.tick(ctx, 1)
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.ok(okE == false and why == 'not_held', 'stop time not reached yet')
    advance(9000)
    CR.tick(ctx, 1)
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1, try = 2 }), true, 'held 9 s of 10 (tolerance) driving a civilian car: accepted')
    H.eq(st.current, 2, 'next checkpoint is current')
    H.eq(st.vehicles[1], 50, 'the driven car is the course vehicle')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.ok(okE == false and why == 'already_done', 'duplicate checkpoint rejected')
    H.eq(CR.checklist(ctx)[1].value, 1, 'checklist value 1')
    H.eq(CR.checklist(ctx)[1].max, 5, 'checklist max 5')
    -- contacts are not tracked when contactPenalty = 0 and there are no medals
    okE, why = CR.onEvent(ctx, 1, { type = 'contact' })
    H.ok(okE == false and why == 'not_tracked', 'contacts off for beat patrol')
    -- presence: next checkpoint or nearest partner, whichever is closer
    ctx.srcs = { 1, 2 }
    at(2, vec3(st.points[2].x + 40.0, 0.0, 30.0))
    at(1, vec3(st.points[2].x + 250.0, 0.0, 30.0))
    H.near(CR.presence(ctx, 1, H.players[1].coords), 210.0, 1e-6, 'presence uses the nearer partner')
    at(2, vec3(st.points[2].x + 900.0, 0.0, 30.0))
    H.near(CR.presence(ctx, 1, H.players[1].coords), 250.0, 1e-6, 'presence uses the next checkpoint')
    CR.onParticipantLeft(ctx, 2)
    H.players[2] = nil
    ctx.srcs = { 1 }
    -- client class evidence is ignored: a reported civilian class (4) and taxi model do not stop a driver
    at(1, st.points[2])
    CR.tick(ctx, 1); advance(10000); CR.tick(ctx, 1)
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2, vehClass = 4, model = joaat('taxi') }), true,
        'a reported class 4 changes nothing: driving is what counts')
    -- another vehicle for checkpoint 3 (any model, e.g. an add-on unmarked car)
    addVehicle(5002, 52, { model = joaat('police9') })
    H.players[1].vehicle = 5002
    at(1, st.points[3])
    CR.tick(ctx, 1); advance(10000); CR.tick(ctx, 1)
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 3 }), true, 'any driven vehicle accepted')
    H.eq(classAsked, 0, 'the server never asked for a vehicle class')
    -- rescale: a scaled random count only shrinks what has not been reached
    ctx.obj.count = 4
    CR.rescale(ctx)
    H.eq(#st.points, 4, 'rescale drops one unreached checkpoint')
    -- last checkpoints, with the minimum time not reached on the first try
    H.players[1].vehicle = 5000
    at(1, st.points[4])
    CR.tick(ctx, 1); advance(10000); CR.tick(ctx, 1)
    ctx.completeResult = false
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 4 }), true, 'last checkpoint accepted')
    H.eq(st.finished, true, 'route finished')
    H.eq(ctx.calls.complete, 1, 'complete tried at once')
    CR.tick(ctx, 1)
    H.eq(ctx.calls.complete, 2, 'complete retried next tick (minSeconds)')
    ctx.completeResult = true
    CR.tick(ctx, 1)
    H.eq(ctx.calls.complete, 3, 'complete accepted')
    CR.tick(ctx, 1)
    H.eq(ctx.calls.complete, 3, 'no complete after success')
    H.eq(#ctx.calls.award, 0, 'beat patrol records no bonus of its own')
    H.eq(CR.onTimeout(ctx), nil, 'timeout fails the run')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 5 })
    H.eq(okE, false, 'events after completion rejected')
    -- restart (test control)
    CR.restart(ctx)
    H.eq(st.current, 1, 'restart back to checkpoint 1')
    H.eq(st.done, 0, 'restart clears progress')
    H.eq(lastSend(ctx).current, 1, 'restart sends a snapshot')
end

-- Server-side stop verification: the server's own samples must see the participant stopped inside the
-- marker, driving a vehicle when one is required, for the stop time.
do
    H.clockMs = 150000
    local loc = { label = 'District', start = { coords = vec3(300.0, 0.0, 30.0), radius = 30.0 }, spots = spots(8) }
    local obj = CR.defaults({ checkpoints = 'spots', use = 'random', count = 5, contactPenalty = 0, failIfUndriveable = false })
    local ctx = fakeCtx({ obj = obj, location = loc, seed = 777 })
    CR.prepare(ctx); CR.start(ctx)
    H.eq(#timerPause, 0, 'beat patrol (no medals) never holds the run timer')
    local st = ctx.state
    local p1 = st.points[1]
    addVehicle(5101, 151, { model = joaat('buffalo') })
    H.players[1] = { coords = vec3(p1.x, p1.y, p1.z), vehicle = 5101 }
    serverSpeeds[5101] = 12.0
    for _ = 1, 12 do advance(1000); CR.tick(ctx, 1) end
    H.eq(st.near[1], nil, 'moving inside the marker: no stop time on the server')
    local okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.ok(okE == false and why == 'not_held', 'circling inside the marker is not a stop')
    serverSpeeds[5101] = 2.0   -- creeping still counts (the client stops at 1.5 m/s; the server allows lag)
    for _ = 1, 9 do advance(1000); CR.tick(ctx, 1) end
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 }), true, 'stopped (server speed) for 9 s accepted')
    local p2 = st.points[2]
    H.players[1] = { coords = vec3(p2.x, p2.y, p2.z), vehicle = 0 }
    for _ = 1, 12 do advance(1000); CR.tick(ctx, 1) end
    H.eq(st.near[1], nil, 'on foot with a vehicle required: no stop time')
    -- in the stopped car, but not at the wheel
    H.players[1].vehicle = 5101
    H.players[1].passenger = true
    serverSpeeds[5101] = nil
    for _ = 1, 12 do advance(1000); CR.tick(ctx, 1) end
    H.eq(st.near[1], nil, 'as a passenger: no stop time')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.ok(okE == false and why == 'not_driving', 'a passenger is rejected')
    H.players[1].passenger = nil
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.ok(okE == false and why == 'not_held', 'taking the wheel at the end does not count the time on foot or as a passenger')
    for _ = 1, 10 do advance(1000); CR.tick(ctx, 1) end
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 }), true, 'driving and stopped for the stop time: accepted')
    H.eq(classAsked, 0, 'still no vehicle class asked for')
end

-- vehicleRequired = false (also the old policeVehicle = false of a published file): on foot or as a passenger counts.
do
    H.clockMs = 170000
    local loc = { label = 'Course', start = { coords = vec3(0.0, 0.0, 30.0), radius = 30.0 }, spots = spots(4) }
    local obj = CR.defaults({ checkpoints = 'spots', stopFor = 0, policeVehicle = false, contactPenalty = 0, failIfUndriveable = false })
    H.eq(obj.vehicleRequired, false, 'policeVehicle = false read as vehicleRequired = false')
    local ctx = fakeCtx({ obj = obj, location = loc, seed = 5 })
    CR.prepare(ctx); CR.start(ctx)
    local st = ctx.state
    H.players[1] = { coords = vec3(st.points[1].x, st.points[1].y, st.points[1].z), vehicle = 0 }
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 }), true, 'no vehicle required: on foot accepted')
    addVehicle(5201, 251, { model = joaat('bus') })
    H.players[1] = { coords = vec3(st.points[2].x, st.points[2].y, st.points[2].z), vehicle = 5201, passenger = true }
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 }), true, 'no vehicle required: a passenger accepted')
    H.eq(st.vehicles[1], 251, 'the vehicle the participant is in is still the course vehicle')
end

-- EVOC Course: every checkpoint, drive-through, medals from the location, contact seconds.
local function evoc(opts)
    H.clockMs = 500000
    timerAdjust, timerPause = {}, {}
    local loc = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 30.0 }, course = { points = spots(4) }, medals = { gold = 60, silver = 80, bronze = 100 } }
    local obj = CR.defaults({ block = 'checkpoint_route', checkpoints = 'course', stopFor = 0, medals = true, radius = 10.0 })
    local ctx = fakeCtx({ obj = obj, location = loc, seed = 42, mission = opts and opts.mission })
    addVehicle(6001, 61, { model = joaat('police3') })
    H.players[1] = { coords = vec3(0.0, 0.0, 0.0), vehicle = 6001 }
    CR.prepare(ctx)
    CR.start(ctx)
    return ctx, ctx.state
end

do
    local ctx, st = evoc()
    H.eq(ctx.run.flags.medals, true, 'medal course drops the common fast bonus')
    H.eq(st.trackContacts, true, 'contacts tracked')
    local okE, why = CR.onEvent(ctx, 1, { type = 'contact' })
    H.ok(okE == false and why == 'course_not_running', 'no contacts before the first checkpoint')
    at(1, vec3(st.points[1].x + 21.0, 0.0, 30.0))
    H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 }), true, 'drive-through within radius + lag slack')
    H.ok(st.courseStartMs ~= nil, 'course clock starts at checkpoint 1')
    H.eq(lastSend(ctx).course.running, true, 'snapshot says the course runs')
    at(1, vec3(st.points[2].x + 23.0, 0.0, 30.0))
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.ok(okE == false and why == 'too_far', 'gate missed by 23 m')
    okE, why = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 3 })
    H.ok(okE == false and why == 'out_of_order', 'missed gate must be driven first')
    H.eq(CR.onEvent(ctx, 1, { type = 'contact' }), true, 'contact counted')
    H.eq(timerAdjust[#timerAdjust], -2, 'contact takes 2 s off the run timer')
    okE, why = CR.onEvent(ctx, 1, { type = 'contact' })
    H.ok(okE == false and why == 'rate', 'contact rate limited')
    advance(1600)
    H.eq(CR.onEvent(ctx, 1, { type = 'contact' }), true, 'second contact after the gap')
    H.eq(st.penalty, 4, 'penalty seconds add up')
    H.players[1].vehicle = 0
    advance(1600)
    okE, why = CR.onEvent(ctx, 1, { type = 'contact' })
    H.ok(okE == false and why == 'not_in_vehicle', 'contact on foot rejected')
    H.players[1].vehicle = 6001
    -- server cap on counted contacts
    for _ = 1, 80 do advance(1600); CR.onEvent(ctx, 1, { type = 'contact' }) end
    H.eq(st.contacts, 60, 'contacts capped at 60')
    st.contacts, st.penalty = 2, 4
    for k = 2, 4 do
        at(1, st.points[k])
        advance(15000)
        H.eq(CR.onEvent(ctx, 1, { type = 'checkpoint', index = k }), true, 'gate ' .. k)
    end
    -- 1.6 s + 80 * 1.6 s + 1.6 s + 45 s + 4 s penalty
    H.ok(st.courseTime > 100, 'slow course has no medal time')
    H.eq(st.medal, nil, 'no medal')
    H.eq(#ctx.calls.award, 0, 'no medal, no no_contact (contacts)')
    H.eq(ctx.calls.complete, 1, 'course completes')
end

do -- gold with contacts
    local ctx, st = evoc()
    at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    advance(1000); CR.onEvent(ctx, 1, { type = 'contact' })
    for k = 2, 4 do at(1, st.points[k]); advance(16000); CR.onEvent(ctx, 1, { type = 'checkpoint', index = k }) end
    H.near(st.courseTime, 51.0, 1e-6, 'course time = 49 s + 2 s contact')
    H.ok(contains(ctx.calls.award, 'medal_gold'), 'gold medal')
    H.ok(not contains(ctx.calls.award, 'no_contact'), 'no no_contact after a contact')
end

do -- silver, no contact
    local ctx, st = evoc()
    at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    for k = 2, 4 do at(1, st.points[k]); advance(23000); CR.tick(ctx, 1); CR.onEvent(ctx, 1, { type = 'checkpoint', index = k }) end
    H.ok(contains(ctx.calls.award, 'medal_silver'), 'silver medal at 69 s')
    H.ok(contains(ctx.calls.award, 'no_contact'), 'no_contact bonus')
    H.eq(#ctx.calls.award, 2, 'exactly two awards')
end

-- Medal and no_contact awards carry the EVOC card values as trusted points hints (custom missions cannot
-- list these ids: Config.Bonuses has none), capped by Config.Builder.bonusCap.points on custom missions.
do
    local function hintOf(ctx, id)
        for _, a in ipairs(ctx.calls.awardOpts) do if a.id == id then return a.opts and a.opts.points end end
        return nil
    end
    local function silverRun(mission)
        local ctx, st = evoc({ mission = mission })
        at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
        for k = 2, 4 do at(1, st.points[k]); advance(23000); CR.tick(ctx, 1); CR.onEvent(ctx, 1, { type = 'checkpoint', index = k }) end
        return ctx
    end
    local b = silverRun({ source = 'builtin' })
    H.eq(hintOf(b, 'medal_silver'), 25, 'built-in: silver medal hint = card value 25')
    H.eq(hintOf(b, 'no_contact'), 10, 'built-in: no_contact hint = card value 10')
    local c = silverRun({ source = 'custom' })
    H.eq(hintOf(c, 'medal_silver'), 25, 'custom: silver medal hint 25 (under the cap)')
    H.eq(hintOf(c, 'no_contact'), 10, 'custom: no_contact hint 10')
    local ctxG, stG = evoc({ mission = { source = 'custom' } })
    at(1, stG.points[1]); CR.onEvent(ctxG, 1, { type = 'checkpoint', index = 1 })
    for k = 2, 4 do at(1, stG.points[k]); advance(16000); CR.onEvent(ctxG, 1, { type = 'checkpoint', index = k }) end
    H.eq(hintOf(ctxG, 'medal_gold'), 50, 'custom: gold medal hint 50 (= the default cap)')
    local savedCap = Config.Builder.bonusCap.points
    Config.Builder.bonusCap.points = 30
    local ctxC, stC = evoc({ mission = { source = 'custom' } })
    at(1, stC.points[1]); CR.onEvent(ctxC, 1, { type = 'checkpoint', index = 1 })
    for k = 2, 4 do at(1, stC.points[k]); advance(16000); CR.onEvent(ctxC, 1, { type = 'checkpoint', index = k }) end
    H.eq(hintOf(ctxC, 'medal_gold'), 30, 'custom: gold medal hint capped by Config.Builder.bonusCap.points')
    local ctxB, stB = evoc({ mission = { source = 'builtin' } })
    at(1, stB.points[1]); CR.onEvent(ctxB, 1, { type = 'checkpoint', index = 1 })
    for k = 2, 4 do at(1, stB.points[k]); advance(16000); CR.onEvent(ctxB, 1, { type = 'checkpoint', index = k }) end
    H.eq(hintOf(ctxB, 'medal_gold'), 50, 'built-in: the card value is never capped')
    Config.Builder.bonusCap.points = savedCap
end

do -- bronze; body damage seen by the server denies no_contact
    local ctx, st = evoc()
    at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    vehicles[6001].body = 950.0
    CR.tick(ctx, 1)
    for k = 2, 4 do at(1, st.points[k]); advance(30000); CR.onEvent(ctx, 1, { type = 'checkpoint', index = k }) end
    H.ok(contains(ctx.calls.award, 'medal_bronze'), 'bronze medal at 90 s')
    H.ok(not contains(ctx.calls.award, 'no_contact'), 'server-side body damage denies no_contact')
end

do -- timerStart = 'start'
    local ctx, st = evoc()
    H.eq(st.courseStartMs, nil, 'first: no clock before checkpoint 1')
    local loc = ctx.location
    local obj = CR.defaults({ checkpoints = 'course', stopFor = 0, medals = true, timerStart = 'start' })
    local c2 = fakeCtx({ obj = obj, location = loc })
    CR.prepare(c2); CR.start(c2)
    H.ok(c2.state.courseStartMs ~= nil, 'start: clock runs from the objective start')
end

do -- EVOC: "the timer starts at the first checkpoint": the run timer is held until checkpoint 1
    local ctx, st = evoc()
    H.eq(timerPause[1], true, 'medal course holds the run timer at the start marker')
    H.eq(lastSend(ctx).course.held, true, 'the snapshot tells the client the timer waits')
    CR.tick(ctx, 1)
    H.eq(#timerPause, 1, 'held once')
    at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    H.eq(timerPause[2], false, 'checkpoint 1 starts the run timer')
    H.eq(lastSend(ctx).course.held, false, 'the snapshot says the timer runs')
    at(1, st.points[2]); advance(5000); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.eq(#timerPause, 2, 'later checkpoints do not touch the timer')
    CR.stop(ctx)
    H.eq(#timerPause, 2, 'stop after the release changes nothing')

    -- nobody crosses checkpoint 1: the timer starts anyway after the grace
    local c2 = evoc()
    advance(119000); CR.tick(c2, 1)
    H.eq(timerPause[#timerPause], true, 'still held before the grace ends')
    advance(1000); CR.tick(c2, 1)
    H.eq(timerPause[#timerPause], false, 'grace over: the run timer starts without checkpoint 1')
    H.eq(lastSend(c2).course.held, false, 'the client hears the timer runs')
    H.eq(c2.state.courseStartMs, nil, 'the course clock still waits for checkpoint 1')

    -- stop and restart
    local c3 = evoc()
    CR.stop(c3)
    H.eq(timerPause[#timerPause], false, 'stop releases a held timer')
    local c4 = evoc()
    at(1, c4.state.points[1]); CR.onEvent(c4, 1, { type = 'checkpoint', index = 1 })
    CR.restart(c4)
    H.eq(timerPause[#timerPause], true, 'restart holds the timer again until checkpoint 1')

    -- not held: a later objective, timerStart = 'start', or a timer somebody else paused
    local loc = ctx.location
    timerPause = {}
    local c5 = fakeCtx({ obj = CR.defaults({ checkpoints = 'course', stopFor = 0, medals = true }), location = loc, index = 2 })
    CR.prepare(c5); CR.start(c5)
    H.eq(#timerPause, 0, 'a medal course after another objective does not hold the timer')
    local c6 = fakeCtx({ obj = CR.defaults({ checkpoints = 'course', stopFor = 0, medals = true, timerStart = 'start' }), location = loc })
    CR.prepare(c6); CR.start(c6)
    H.eq(#timerPause, 0, "timerStart = 'start' does not hold the timer")
    local c7 = fakeCtx({ obj = CR.defaults({ checkpoints = 'course', stopFor = 0, medals = true }), location = loc })
    c7.run.timer = { remaining = 240, paused = true }
    CR.prepare(c7); CR.start(c7)
    at(1, c7.state.points[1]); CR.onEvent(c7, 1, { type = 'checkpoint', index = 1 })
    H.eq(#timerPause, 0, 'a timer paused by the test controls is left alone')
end

do -- undriveable
    local ctx, st = evoc()
    at(1, st.points[1]); CR.onEvent(ctx, 1, { type = 'checkpoint', index = 1 })
    local okE, why = CR.onEvent(ctx, 1, { type = 'undriveable', netId = 61 })
    H.ok(okE == false and why == 'vehicle_ok', 'healthy vehicle report rejected')
    addVehicle(7001, 71, { engine = 50.0 })
    okE, why = CR.onEvent(ctx, 1, { type = 'undriveable', netId = 71 })
    H.ok(okE == false and why == 'not_course_vehicle', 'somebody else\'s vehicle rejected')
    vehicles[6001].engine = 60.0
    H.eq(CR.onEvent(ctx, 1, { type = 'undriveable', netId = 61 }), true, 'wrecked course vehicle accepted')
    H.eq(ctx.calls.fail[1], 'block.checkpoint_route.fail_undriveable', 'run fails: undriveable')
    okE = CR.onEvent(ctx, 1, { type = 'checkpoint', index = 2 })
    H.eq(okE, false, 'no events after the fail')

    local c2, s2 = evoc()
    at(1, s2.points[1]); CR.onEvent(c2, 1, { type = 'checkpoint', index = 1 })
    CR.tick(c2, 1)
    vehicles[6001].engine = -50.0
    CR.tick(c2, 1)
    H.eq(c2.calls.fail[1], 'block.checkpoint_route.fail_undriveable', 'server tick detects a dead engine')

    local c3 = fakeCtx({ obj = CR.defaults({ checkpoints = 'course', stopFor = 0, failIfUndriveable = false }), location = c2.location })
    CR.prepare(c3); CR.start(c3)
    okE, why = CR.onEvent(c3, 1, { type = 'undriveable', netId = 61 })
    H.ok(okE == false and why == 'not_tracked', 'failIfUndriveable = false ignores the report')
    H.eq(#c3.calls.fail, 0, 'no fail when off')
    vehicles[6001].engine = 1000.0
end

-- ════════════════════════════════════════════════════════════════════════════
-- interact_points
-- ════════════════════════════════════════════════════════════════════════════
local function businesses(n)
    local out = {}
    for i = 1, n do out[i] = { coords = vec4(i * 200.0, 1000.0, 20.0, 90.0), label = 'Shop ' .. i } end
    return out
end

local businessObj = {
    block = 'interact_points', label = 'Check the businesses', points = 'businesses', use = 'random', count = 4,
    target = { label = 'Check door', icon = 'fa-solid fa-door-closed' },
    progress = { label = 'Checking door', duration = 5000, anim = 'clipboard' },
    roll = { outcomes = { { id = 'secure', chance = 0.75 }, { id = 'open', chance = 0.25, followUp = { label = 'Secure door', duration = 5000 } } } },
    logResult = { choices = { 'secure', 'found_open' }, correct = { secure = 'secure', open = 'found_open' } },
}

do -- defaults
    local o = IP.defaults({ block = 'interact_points', points = 'scene' })
    H.eq(o.progress.duration, 5000, 'ip default duration 5 s')
    H.eq(o.progress.label, Config.Blocks.interact_points.label, 'ip default progress label from config')
    H.eq(o.progress.anim, 'clipboard', 'ip default animation')
    H.eq(o.target.radius, 1.5, 'ip default target radius')
    H.eq(o.minSeconds, 5, 'ip default minSeconds')
    H.eq(o.presenceRange, 150, 'ip default presenceRange')
    H.eq(o.use, 'all', 'ip default use')
    local h = IP.defaults({ points = 'spots', hidden = {} })
    H.eq(h.hidden.count, 1, 'ip hidden default count')
    H.eq(h.hidden.prop, 'prop_ld_bomb', 'ip hidden default prop')
    H.eq(IP.requiredPoints({ points = 'scene' })[1], 'scene', 'ip required points')
end

do -- validate
    local loc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12), scene = vec3(1.0, 2.0, 3.0), spots = spots(6) }
    local mission = { locations = { loc } }
    H.eq(IP.validate(IP.defaults(CP.U.deepcopy(businessObj)), mission, loc), true, 'ip valid business check')
    H.eq(IP.validate(IP.defaults({ points = 'scene', progress = { duration = 8000 } }), mission, loc), true, 'ip valid single point')
    local function variant(patch)
        local o = CP.U.deepcopy(businessObj)
        patch(o)
        return IP.validate(IP.defaults(o), mission, loc)
    end
    local ok, why = variant(function(o) o.roll.outcomes[1].chance = 0.65 end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.chances'), 'ip chances must add up')
    ok, why = variant(function(o) o.logResult.correct.open = 'maybe' end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.log_correct'), 'ip correct must be a choice')
    ok, why = variant(function(o) o.logResult.choices = { 'a', 'b', 'c', 'd', 'e' } end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.log_choices'), 'ip 5 choices rejected')
    ok, why = variant(function(o) o.count = 11 end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.range'), 'ip 11 points rejected')
    ok, why = variant(function(o) o.progress.anim = 'dance' end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.anim'), 'ip anim not allowed')
    ok, why = variant(function(o) o.progress.duration = 40000 end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.range'), 'ip 40 s progress rejected')
    ok, why = variant(function(o) o.roll.outcomes[2].followUp.duration = 0 end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.follow_up'), 'ip bad follow-up rejected')
    ok, why = variant(function(o) o.hidden = { count = 1 } end)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.hidden_exclusive'), 'ip hidden + roll rejected')
    ok, why = IP.validate(IP.defaults({ points = 'spots', hidden = { count = 7 } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.hidden_count'), 'ip more devices than spots rejected')
    ok, why = IP.validate(IP.defaults({ points = 'spots', hidden = { count = 1 }, fastBonus = { seconds = 120 } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.fast_bonus'), 'ip fast bonus needs an id')
    local builtinMission = { source = 'builtin', locations = { loc } }
    H.eq(IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2 }, fastBonus = { seconds = 120, id = 'devices_found_fast' } }), builtinMission, loc), true, 'ip valid hidden search')
    -- custom missions: a standard fast-bonus id only, the block's own device models only, allowed animation names only
    ok, why = IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2 }, fastBonus = { seconds = 120, id = 'devices_found_fast' } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.fast_bonus_custom'), 'ip custom: a fast bonus outside Config.Bonuses rejected')
    H.eq(IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2 }, fastBonus = { seconds = 120, id = 'correct_log' } }), mission, loc), true, 'ip custom: a Config.Bonuses fast bonus id accepted')
    H.eq(IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2 } }), mission, loc), true, 'ip custom: the default device prop accepted')
    H.eq(IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2, prop = 'prop_c4_final_green' } }), mission, loc), true, 'ip custom: the Bomb Disposal device prop accepted')
    ok, why = IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2, prop = 'prop_big_shit_01' } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.hidden_prop'), 'ip custom: any other device prop rejected')
    H.eq(IP.validate(IP.defaults({ points = 'spots', hidden = { count = 2, prop = 'prop_big_shit_01' } }), builtinMission, loc), true, 'ip built-in: its own device prop is trusted')
    ok, why = IP.validate(IP.defaults({ points = 'spots', progress = { anim = { scenario = 'WORLD_HUMAN_CLIPBOARD' } } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.anim'), 'ip custom: a raw scenario table rejected')
    ok, why = IP.validate(IP.defaults({ points = 'spots', progress = { anim = { dict = 'amb@x', clip = 'base' } } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.anim'), 'ip custom: a raw dict/clip table rejected')
    ok, why = IP.validate(IP.defaults({ points = 'nowhere' }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.points_missing'), 'ip missing key rejected')
    ok = IP.validate(IP.defaults({ points = 'spots', use = 'random', count = 7 }), mission, loc)
    H.eq(ok, false, 'ip count above pool rejected')
    H.eq(IP.validate(IP.defaults({ points = 'spots', progress = { anim = { scenario = 'WORLD_HUMAN_CLIPBOARD' } } }), builtinMission, loc), true, 'ip scenario table anim allowed (built-in)')
    H.eq(IP.validate(IP.defaults({ points = 'spots', logResult = { choices = { 'x', 'y', 'z' } } }), mission, loc), true, 'ip builder log without roll')
    local zoneLoc = { scene = vec3(310.0, -590.0, 43.0) }
    ok, why = IP.validate(IP.defaults({ points = 'scene' }), { locations = { zoneLoc } }, zoneLoc)
    H.ok(ok == false and reasonIs(why, 'block.interact_points.invalid.points_zone'), 'ip point in a no-build zone rejected')
end

do -- rolls: deterministic per seed, roughly 25% open
    local loc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12) }
    local open, total = 0, 0
    for seed = 1, 150 do
        local ctx = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = seed * 7919 })
        IP.prepare(ctx)
        for _, p in ipairs(ctx.state.points) do
            total = total + 1
            if p.outcome == 'open' then open = open + 1 end
        end
    end
    H.eq(total, 600, '4 points per run')
    H.ok(open / total > 0.18 and open / total < 0.32, ('about a quarter open (%d / %d)'):format(open, total))
    local a = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = 99 })
    local b = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = 99 })
    IP.prepare(a); IP.prepare(b)
    for n = 1, 4 do
        H.eq(a.state.points[n].outcome, b.state.points[n].outcome, 'same seed same outcome ' .. n)
        H.eq(a.state.points[n].coords.x, b.state.points[n].coords.x, 'same seed same business ' .. n)
    end
    H.eq(a.state.points[1].coords.x, 200.0, 'the business at the start is used first')
end

-- Business Check flow: check door (5 s), open doors get "Secure door" (5 s), then the tablet log.
do
    H.clockMs = 1000000
    local loc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12) }
    local seed
    for s = 1, 500 do -- a seed that rolls at least one open and one secure door
        local c = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = s })
        IP.prepare(c)
        local o, sec = 0, 0
        for _, p in ipairs(c.state.points) do if p.outcome == 'open' then o = o + 1 else sec = sec + 1 end end
        if o >= 1 and sec >= 1 then seed = s; break end
    end
    H.ok(seed ~= nil, 'found a mixed seed')
    local ctx = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = seed })
    IP.prepare(ctx)
    IP.start(ctx)
    local st = ctx.state
    local snap = lastSend(ctx)
    H.eq(snap.kind, 'state', 'ip start sends a snapshot')
    H.eq(#snap.points, 4, 'ip snapshot has 4 points')
    H.eq(snap.points[1].outcome, nil, 'outcomes stay hidden until the door is checked')
    local secureN, openN
    for n, p in ipairs(st.points) do
        if p.outcome == 'secure' and not secureN then secureN = n end
        if p.outcome == 'open' and not openN then openN = n end
    end
    -- secure door
    local sp = st.points[secureN]
    at(1, vec3(sp.coords.x + 10.0, sp.coords.y, sp.coords.z))
    local okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = secureN })
    H.ok(okE == false and why == 'too_far', 'ip too far')
    at(1, vec3(sp.coords.x + 1.0, sp.coords.y, sp.coords.z))
    okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = secureN })
    H.ok(okE == false and why == 'too_quick', 'ip progress time not spent at the door')
    IP.tick(ctx, 1)
    advance(4000)
    IP.tick(ctx, 1)
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = secureN }), true, 'ip door checked after 4 s (5 s - tolerance)')
    H.eq(sp.status, 'log', 'secure door waits for the log')
    H.eq(st.log.point, secureN, 'state.log points at the door')
    H.eq(#st.log.choices, 2, 'two log choices')
    H.eq(st.log.choices[1].id, 'secure', 'choice 1 id')
    H.eq(st.log.choices[1].label, 'Secure', 'choice 1 label translated')
    H.eq(st.log.choices[2].label, 'Found open – secured', 'choice 2 label translated')
    H.eq(lastSend(ctx).points[secureN].outcomeLabel, 'The door is secure', 'the result is shown after the check')
    okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = secureN })
    H.ok(okE == false and why == 'wrong_state', 'ip duplicate check rejected')
    okE, why = IP.onEvent(ctx, 1, { type = 'log', point = openN, choice = 'secure' })
    H.ok(okE == false and why == 'wrong_state', 'cannot log an unchecked door')
    okE, why = IP.onEvent(ctx, 1, { type = 'log', point = secureN, choice = 'maybe' })
    H.ok(okE == false and why == 'bad_choice', 'unknown choice rejected')
    H.eq(IP.onEvent(ctx, 1, { type = 'log', point = secureN, choice = 'secure' }), true, 'correct log accepted')
    H.eq(count(ctx.calls.award, 'correct_log'), 1, 'correct_log recorded')
    H.eq(st.log, nil, 'no log waiting')
    okE = IP.onEvent(ctx, 1, { type = 'log', point = secureN, choice = 'secure' })
    H.eq(okE, false, 'duplicate log rejected')
    -- open door: follow-up, then a wrong log
    local op = st.points[openN]
    at(1, op.coords)
    IP.tick(ctx, 1); advance(5000); IP.tick(ctx, 1)
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = openN }), true, 'open door checked')
    H.eq(op.status, 'followup', 'open door needs securing')
    H.eq(lastSend(ctx).points[openN].followUp.label, 'Secure door', 'follow-up label sent')
    H.eq(lastSend(ctx).points[openN].outcomeLabel, 'The door was found open', 'open result shown')
    okE, why = IP.onEvent(ctx, 1, { type = 'followup', point = openN })
    H.ok(okE == false and why == 'too_quick', 'secure door needs its 5 s')
    advance(5000)
    H.eq(IP.onEvent(ctx, 1, { type = 'followup', point = openN }), true, 'door secured')
    H.eq(st.log.point, openN, 'open door waits for the log')
    H.eq(IP.onEvent(ctx, 1, { type = 'log', point = openN, choice = 'secure' }), true, 'wrong log accepted')
    H.eq(count(ctx.calls.penalize, 'wrong_log'), 1, 'wrong_log recorded')
    H.eq(ctx.calls.complete, 0, 'not complete with doors left')
    H.eq(IP.checklist(ctx)[1].value, 2, 'ip checklist 2 done')
    H.eq(IP.checklist(ctx)[1].max, 4, 'ip checklist of 4')
    -- presence: the nearest point not yet done
    local rest = {}
    for n, p in ipairs(st.points) do if p.status == 'pending' then rest[#rest + 1] = n end end
    at(1, vec3(st.points[rest[1]].coords.x + 30.0, st.points[rest[1]].coords.y, st.points[rest[1]].coords.z))
    H.near(IP.presence(ctx, 1, H.players[1].coords), 30.0, 1e-6, 'ip presence from the nearest open point')
    -- the other doors (log them correctly)
    for _, n in ipairs(rest) do
        local p = st.points[n]
        at(1, p.coords)
        IP.tick(ctx, 1); advance(5000); IP.tick(ctx, 1)
        H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = n }), true, 'door ' .. n .. ' checked')
        if p.status == 'followup' then advance(5000); IP.onEvent(ctx, 1, { type = 'followup', point = n }) end
        local choice = (p.outcome == 'open') and 'found_open' or 'secure'
        H.eq(IP.onEvent(ctx, 1, { type = 'log', point = n, choice = choice }), true, 'door ' .. n .. ' logged')
    end
    H.eq(ctx.calls.complete, 1, 'business check completes after the last log')
    H.eq(count(ctx.calls.award, 'correct_log'), 3, 'three correct logs')
    okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = 1 })
    H.ok(okE == false and why == 'objective_over', 'events after completion rejected')
end

do -- the follow-up ("Secure door") also needs the server to see the officer at the door for its time
    H.clockMs = 1500000
    local loc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12) }
    local ctx, openN
    for s2 = 1, 500 do
        local c = fakeCtx({ obj = IP.defaults(CP.U.deepcopy(businessObj)), location = loc, seed = s2 })
        IP.prepare(c)
        for n, p in ipairs(c.state.points) do if p.outcome == 'open' then openN = n end end
        if openN then ctx = c; break end
    end
    IP.start(ctx)
    local op = ctx.state.points[openN]
    at(1, op.coords)
    IP.tick(ctx, 1); advance(5000); IP.tick(ctx, 1)
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = openN, seq = 1 }), true, 'open door checked')
    at(1, vec3(op.coords.x + 60.0, op.coords.y, op.coords.z))
    IP.tick(ctx, 1); advance(5000); IP.tick(ctx, 1)
    at(1, op.coords)
    local okE, why = IP.onEvent(ctx, 1, { type = 'followup', point = openN, seq = 2 })
    H.ok(okE == false and why == 'too_quick', 'walking away and back does not count as securing the door')
    ctx.srcs = { 1, 2 }
    at(2, vec3(op.coords.x + 80.0, op.coords.y, op.coords.z))
    IP.tick(ctx, 1); advance(4000); IP.tick(ctx, 1)
    at(2, op.coords)
    okE, why = IP.onEvent(ctx, 2, { type = 'followup', point = openN, seq = 1 })
    H.ok(okE == false and why == 'too_quick', 'a partner who just walked up cannot report the follow-up')
    H.eq(IP.onEvent(ctx, 1, { type = 'followup', point = openN, seq = 3 }), true, 'secured after 4 s at the door (5 s - tolerance)')
    H.eq(op.status, 'log', 'waits for the log')
    ctx.srcs = { 1 }
end

do -- Secure the scene: one point, 8 s, minSeconds retry
    H.clockMs = 2000000
    local loc = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 80.0 }, scene = vec3(50.0, 50.0, 10.0) }
    local ctx = fakeCtx({ obj = IP.defaults({ block = 'interact_points', points = 'scene', minSeconds = 8, progress = { label = 'Securing scene', duration = 8000 } }), location = loc })
    IP.prepare(ctx); IP.start(ctx)
    at(1, vec3(51.0, 50.0, 10.0))
    IP.tick(ctx, 1)
    advance(5000); IP.tick(ctx, 1)
    local okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = 1 })
    H.ok(okE == false and why == 'too_quick', 'scene needs 8 s')
    advance(2000); IP.tick(ctx, 1)
    ctx.completeResult = false
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = 1 }), true, 'scene secured')
    H.eq(ctx.calls.complete, 1, 'complete tried')
    IP.tick(ctx, 1)
    H.eq(ctx.calls.complete, 2, 'complete retried')
    ctx.completeResult = true
    IP.tick(ctx, 1)
    IP.tick(ctx, 1)
    H.eq(ctx.calls.complete, 3, 'complete once accepted')
    H.eq(IP.onTimeout(ctx), nil, 'ip timeout fails')
end

-- Bomb Disposal search: 6 hiding spots, 2 devices (scaled), spawn caps, fast bonus.
local function bombSearch(countN, seed)
    H.clockMs = 3000000
    local loc = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 50.0 }, spots = spots(6, 0.0, 3000.0) }
    local obj = IP.defaults({
        block = 'interact_points', points = 'spots', minSeconds = 5,
        target = { label = 'Search' }, progress = { label = 'Searching', duration = 3000, anim = 'search' },
        hidden = { count = countN, prop = 'prop_ld_bomb' }, fastBonus = { seconds = 120, id = 'devices_found_fast' },
    })
    local ctx = fakeCtx({ obj = obj, location = loc, seed = seed or 5 })
    IP.prepare(ctx); IP.start(ctx)
    return ctx, ctx.state
end

local function search(ctx, n)
    local p = ctx.state.points[n]
    at(1, p.coords)
    IP.tick(ctx, 1); advance(3000); IP.tick(ctx, 1)
    return IP.onEvent(ctx, 1, { type = 'interact', point = n })
end

do
    local ctx, st = bombSearch(2)
    local devices, empty = {}, {}
    for n, p in ipairs(st.points) do
        if p.device then devices[#devices + 1] = n else empty[#empty + 1] = n end
    end
    H.eq(#devices, 2, 'two spots hide a device')
    H.eq(#st.points, 6, 'every hiding spot is searchable')
    for _, pt in ipairs(lastSend(ctx).points) do H.eq(pt.device, nil, 'which spots hide devices is never sent') end
    H.eq(search(ctx, empty[1]), true, 'empty spot searched')
    H.eq(#ctx.calls.spawn, 0, 'nothing spawned for an empty spot')
    local okE, why = IP.onEvent(ctx, 1, { type = 'interact', point = empty[1] })
    H.ok(okE == false and why == 'wrong_state', 'spot searched twice rejected')
    ctx.capOk = false
    H.eq(search(ctx, devices[1]), true, 'device found')
    H.eq(st.found, 1, 'one device found')
    H.eq(#ctx.calls.spawn, 0, 'spawn waits for the cap')
    IP.tick(ctx, 1)
    H.eq(#ctx.calls.spawn, 0, 'still waiting for the cap')
    ctx.capOk = true
    IP.tick(ctx, 1)
    H.eq(#ctx.calls.spawn, 1, 'device prop spawned once the cap allows')
    local sp = ctx.calls.spawn[1]
    H.eq(sp.kind, 'object', 'device is an object')
    H.eq(sp.opts.model, 'prop_ld_bomb', 'device prop model')
    H.eq(sp.opts.role, 'device', 'device role')
    H.eq(sp.opts.tag, 'shared:devices', 'device tag')
    H.eq(#ctx.run.shared.devices, 1, 'device shared with the next objective')
    H.eq(ctx.run.shared.devices[1].netId, sp.netId, 'shared device netId')
    H.eq(ctx.run.shared.devices[1].model, 'prop_ld_bomb', 'shared device carries its model (for re-creation)')
    H.near(ctx.run.shared.devices[1].coords.x, st.points[devices[1]].coords.x, 1e-6, 'shared device coords')
    H.eq(IP.checklist(ctx)[1].value, 1, 'devices checklist 1')
    H.eq(IP.checklist(ctx)[1].max, 2, 'devices checklist of 2')
    H.eq(search(ctx, devices[2]), true, 'second device found')
    H.eq(#ctx.run.shared.devices, 2, 'both devices shared')
    H.ok(contains(ctx.calls.award, 'devices_found_fast'), 'every device found within 2 minutes')
    H.eq(ctx.calls.complete, 1, 'search completes when every device is found')
    H.eq(#empty - 1, 3, 'three spots were never searched')
    -- restart removes the props this objective spawned
    IP.restart(ctx)
    H.eq(#ctx.calls.delete, 2, 'restart deletes both device props')
    H.eq(#ctx.run.shared.devices, 0, 'restart clears shared devices')
    H.eq(st.found, 0, 'restart clears found devices')
    H.eq(st.points[devices[1]].status, 'pending', 'restart reopens the spots')
    H.eq(st.points[devices[1]].device, true, 'same hiding spots after restart')
end

do -- slow search: no fast bonus; the last device waits for the cap before completing
    local ctx, st = bombSearch(1)
    local dev
    for n, p in ipairs(st.points) do if p.device then dev = n end end
    advance(121000)
    ctx.capOk = false
    H.eq(search(ctx, dev), true, 'device found late')
    H.ok(not contains(ctx.calls.award, 'devices_found_fast'), 'no fast bonus after 2 minutes')
    H.eq(ctx.calls.complete, 0, 'not complete while the prop waits for the cap')
    ctx.capOk = true
    IP.tick(ctx, 1)
    H.eq(ctx.calls.complete, 1, 'complete once the prop exists')
end

do -- rescale: devices not found yet shrink to the new count
    local ctx, st = bombSearch(3, 11)
    H.eq(st.total, 3, 'three devices hidden')
    local first
    for n, p in ipairs(st.points) do if p.device and not first then first = n end end
    search(ctx, first)
    ctx.obj.hidden.count = 1
    IP.rescale(ctx)
    H.eq(st.total, 1, 'rescale: only the found device remains')
    local left = 0
    for _, p in ipairs(st.points) do if p.device then left = left + 1 end end
    H.eq(left, 1, 'unfound devices removed from their spots')
    H.eq(ctx.calls.complete, 1, 'rescale completes the search')
    H.eq(#ctx.calls.spawn, 1, 'nothing extra spawned by rescale')

    local c2, s2 = bombSearch(3, 12)
    c2.obj.hidden.count = 2
    IP.rescale(c2)
    H.eq(s2.total, 2, 'rescale 3 -> 2 before any find')
    H.eq(#c2.calls.spawn, 0, 'rescale spawns nothing')
end

do -- rescale of a scaled random count drops points not started
    local loc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12) }
    local ctx = fakeCtx({ obj = IP.defaults({ points = 'businesses', use = 'random', count = 4, progress = { duration = 1000 } }), location = loc })
    IP.prepare(ctx); IP.start(ctx)
    at(1, ctx.state.points[1].coords)
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = 1 }), true, '1 s progress needs no dwell')
    ctx.obj.count = 2
    IP.rescale(ctx)
    H.eq(IP.checklist(ctx)[1].max, 2, 'two points left in use')
    H.eq(ctx.state.points[4].status, 'dropped', 'last pending point dropped')
    at(1, ctx.state.points[2].coords)
    H.eq(IP.onEvent(ctx, 1, { type = 'interact', point = 2 }), true, 'second point done')
    H.eq(ctx.calls.complete, 1, 'completes with the smaller count')
    IP.onParticipantLeft(ctx, 1)
end

-- ════════════════════════════════════════════════════════════════════════════
-- skill_check
-- ════════════════════════════════════════════════════════════════════════════
do -- defaults and validate
    local o = SC.defaults({ block = 'skill_check' })
    H.eq(o.targets, 'shared:devices', 'sc default targets')
    H.eq(table.concat(o.checks, ','), 'easy,medium,medium,hard', 'sc default checks')
    H.eq(o.missPenalty, 30, 'sc default missPenalty')
    H.eq(o.failAfter, 2, 'sc default failAfter')
    H.eq(o.explosion, true, 'sc default explosion')
    H.eq(o.minSeconds, 10, 'sc default minSeconds')
    H.eq(o.presenceRange, 150, 'sc default presenceRange')
    H.ok(o.checks ~= Config.Blocks.skill_check.difficulty.default, 'sc default checks copied')
    H.eq(#SC.requiredPoints(o), 0, 'shared devices need no placed points')
    H.eq(SC.requiredPoints({ targets = 'panels' })[1], 'panels', 'sc location targets are required points')

    local search = IP.defaults({ block = 'interact_points', points = 'spots', hidden = { count = 1 } })
    local defuse = SC.defaults({ block = 'skill_check' })
    local loc = { spots = spots(6), panels = { vec3(1.0, 1.0, 1.0), vec3(2.0, 2.0, 2.0) } }
    local mission = { locations = { loc }, objectives = { search, defuse } }
    H.eq(SC.validate(defuse, mission, loc), true, 'sc valid after a hidden search')
    local ok, why = SC.validate(defuse, { locations = { loc }, objectives = { defuse } }, loc)
    H.ok(ok == false and reasonIs(why, 'block.skill_check.invalid.no_devices'), 'sc shared devices need a search first')
    ok, why = SC.validate(defuse, { locations = { loc }, objectives = { defuse, search } }, loc)
    H.eq(ok, false, 'sc search after the defuse rejected')
    ok, why = SC.validate(SC.defaults({ checks = { 'easy', 'easy', 'easy', 'easy', 'easy', 'easy', 'easy', 'easy', 'easy' } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.skill_check.invalid.range'), 'sc 9 checks rejected')
    ok, why = SC.validate(SC.defaults({ checks = { 'easy', 'extreme' } }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.skill_check.invalid.difficulty'), 'sc bad difficulty rejected')
    ok = SC.validate(SC.defaults({ failAfter = 4 }), mission, loc)
    H.eq(ok, false, 'sc failAfter 4 rejected')
    ok = SC.validate(SC.defaults({ missPenalty = 121 }), mission, loc)
    H.eq(ok, false, 'sc missPenalty 121 rejected')
    H.eq(SC.validate(SC.defaults({ targets = 'panels' }), mission, loc), true, 'sc location targets valid')
    local zoneLoc = { panels = { vec3(1768.0, 2570.0, 45.0) } }
    ok, why = SC.validate(SC.defaults({ targets = 'panels' }), { locations = { zoneLoc } }, zoneLoc)
    H.ok(ok == false and reasonIs(why, 'block.skill_check.invalid.points_zone'), 'sc target in a no-build zone rejected')
    ok, why = SC.validate(SC.defaults({ targets = 'nowhere' }), mission, loc)
    H.ok(ok == false and reasonIs(why, 'block.skill_check.invalid.points_missing'), 'sc missing target key')
    H.eq(SC.armedCount(defuse), 0, 'sc armed count')
end

local function defuseCtx(opts)
    opts = opts or {}
    H.clockMs = 4000000
    timerAdjust = {}
    local obj = SC.defaults({ block = 'skill_check', checks = opts.checks })
    local ctx = fakeCtx({ obj = obj, location = {}, index = 2, srcs = { 1, 2 } })
    ctx.run.shared.devices = {}
    for i = 1, (opts.devices or 2) do
        local netId = 800 + i
        local c = vec3(i * 10.0, 4000.0, 5.0)
        props[netId * 10] = { netId = netId, coords = c }
        byNet[netId] = netId * 10
        ctx.run.shared.devices[i] = { netId = netId, coords = c, model = opts.model, heading = opts.heading }
    end
    SC.prepare(ctx)
    SC.start(ctx)
    return ctx, ctx.state
end

local function round(ctx, src, target, index, success)
    advance(300)
    return SC.onEvent(ctx, src, { type = 'check', target = target, index = index, success = success })
end

do -- two devices, misses, completion without the bonus
    local ctx, st = defuseCtx()
    H.eq(#st.targets, 2, 'targets taken from shared devices')
    H.eq(lastSend(ctx).kind, 'state', 'sc start sends a snapshot')
    at(1, vec3(10.0, 4001.0, 5.0))
    local okE, why = round(ctx, 1, 1, 2, true)
    H.ok(okE == false and why == 'wrong_index', 'rounds must come in order')
    okE, why = round(ctx, 1, 3, 1, true)
    H.ok(okE == false and why == 'bad_target', 'unknown target rejected')
    okE, why = round(ctx, 1, 1, 1, 'yes')
    H.ok(okE == false and why == 'bad_result', 'success must be a boolean')
    at(2, vec3(20.0, 4020.0, 5.0))
    okE, why = round(ctx, 2, 2, 1, true)
    H.ok(okE == false and why == 'too_far', 'too far from the device')
    H.eq(round(ctx, 1, 1, 1, true), true, 'round 1 passed')
    okE, why = SC.onEvent(ctx, 1, { type = 'check', target = 1, index = 2, success = true })
    H.ok(okE == false and why == 'too_quick', 'rounds cannot arrive instantly')
    at(2, vec3(11.0, 4000.0, 5.0))
    okE, why = round(ctx, 2, 1, 2, true)
    H.ok(okE == false and why == 'busy', 'someone else is working this device')
    for k = 2, 4 do H.eq(round(ctx, 1, 1, k, true), true, 'round ' .. k .. ' passed') end
    H.eq(st.targets[1].status, 'defused', 'device 1 defused')
    okE, why = round(ctx, 1, 1, 5, true)
    H.ok(okE == false and why == 'wrong_state', 'defused device rejects rounds')
    H.eq(SC.checklist(ctx)[1].value, 1, 'sc checklist 1 of 2')
    -- device 2: a miss repeats the round and costs 30 s
    at(2, vec3(20.0, 4000.5, 5.0))
    H.eq(round(ctx, 2, 2, 1, false), true, 'miss accepted')
    H.eq(timerAdjust[1], -30, 'miss takes 30 s off the run timer')
    H.eq(st.targets[2].next, 1, 'a miss repeats the round')
    H.eq(st.targets[2].streak, 1, 'one miss in a row')
    H.near(SC.presence(ctx, 2, H.players[2].coords), 0.5, 1e-6, 'presence from the device being worked on')
    H.eq(round(ctx, 2, 2, 1, true), true, 'retry passed')
    H.eq(st.targets[2].streak, 0, 'success resets the streak')
    H.eq(round(ctx, 2, 2, 2, false), true, 'another miss (not in a row)')
    H.eq(#ctx.calls.fail, 0, 'misses not in a row do not set it off')
    for k = 2, 4 do H.eq(round(ctx, 2, 2, k, true), true, 'device 2 round ' .. k) end
    H.eq(ctx.calls.complete, 1, 'every device defused completes')
    H.ok(not contains(ctx.calls.award, 'no_missed_checks'), 'no bonus after misses')
    H.eq(#timerAdjust, 2, 'two misses, two penalties')
end

do -- clean defuse: bonus; the lock frees itself
    local ctx, st = defuseCtx({ devices = 1 })
    at(1, vec3(10.0, 4000.0, 5.0))
    at(2, vec3(10.5, 4000.0, 5.0))
    H.eq(round(ctx, 1, 1, 1, true), true, 'p1 starts the device')
    local okE, why = round(ctx, 2, 1, 2, true)
    H.ok(okE == false and why == 'busy', 'p2 locked out')
    advance(15000)
    SC.tick(ctx, 1)
    H.eq(st.targets[1].worker, nil, 'idle lock released on tick')
    for k = 2, 4 do H.eq(round(ctx, 2, 1, k, true), true, 'p2 takes over round ' .. k) end
    H.ok(contains(ctx.calls.award, 'no_missed_checks'), 'no_missed_checks recorded')
    H.eq(ctx.calls.complete, 1, 'complete')
end

do -- two misses in a row set the device off
    local ctx, st = defuseCtx()
    at(1, vec3(20.0, 4000.0, 5.0))
    H.eq(round(ctx, 1, 2, 1, true), true, 'round 1')
    H.eq(round(ctx, 1, 2, 2, false), true, 'miss 1')
    H.eq(round(ctx, 1, 2, 2, false), true, 'miss 2')
    H.eq(st.targets[2].status, 'exploded', 'device went off')
    local boom
    for _, s in ipairs(ctx.calls.send) do if s.kind == 'explode' then boom = s end end
    H.ok(boom ~= nil, 'explode message sent')
    H.eq(boom.by, 1, 'the reporting participant plays the effect')
    H.eq(boom.target, 2, 'explode target')
    H.eq(boom.effect, true, 'effect on')
    H.near(boom.coords.x, 20.0, 1e-6, 'explode coords from the device')
    H.eq(ctx.calls.fail[1], 'block.skill_check.fail_exploded', 'run fails: device went off')
    local okE, why = round(ctx, 1, 1, 1, true)
    H.ok(okE == false and why == 'objective_over', 'no rounds after the explosion')
end

do -- timeout: armed devices go off for the host; restart; location targets; no targets
    local ctx, st = defuseCtx()
    at(1, vec3(10.0, 4000.0, 5.0))
    for k = 1, 4 do round(ctx, 1, 1, k, true) end
    ctx.calls.send = {}
    H.eq(SC.onTimeout(ctx), nil, 'sc timeout fails the run')
    local booms = 0
    for _, s in ipairs(ctx.calls.send) do
        if s.kind == 'explode' then
            booms = booms + 1
            H.eq(s.by, ctx.run.host, 'timeout effect played by the host')
        end
    end
    H.eq(booms, 1, 'only the armed device goes off')
    SC.restart(ctx)
    H.eq(st.targets[1].status, 'armed', 'restart re-arms devices')
    H.eq(st.targets[2].next, 1, 'restart from round 1')
    H.eq(st.misses, 0, 'restart clears misses')

    local c2 = fakeCtx({ obj = SC.defaults({ targets = 'panels', checks = { 'easy' } }), location = { panels = { vec3(0.0, 0.0, 0.0), vec4(5.0, 0.0, 0.0, 90.0) } } })
    SC.prepare(c2)
    H.eq(#c2.state.targets, 2, 'location targets known at prepare')
    SC.start(c2)
    at(1, vec3(0.0, 1.0, 0.0))
    H.eq(round(c2, 1, 1, 1, true), true, 'panel 1 done in one check')
    at(1, vec3(5.0, 1.0, 0.0))
    H.eq(round(c2, 1, 2, 1, true), true, 'panel 2 done')
    H.eq(c2.calls.complete, 1, 'location targets complete')

    local c3 = fakeCtx({ obj = SC.defaults({}), location = {} })
    SC.prepare(c3); SC.start(c3); SC.tick(c3, 1)
    H.eq(c3.calls.complete, 1, 'no devices: nothing to defuse')
    H.eq(#c3.calls.award, 0, 'no bonus without devices')
end

do -- device props deleted when the search objective ended are re-created (cap respected), same devices
    local ctx, st = defuseCtx({ devices = 2, model = 'prop_bomb_01', heading = 45.0 })
    H.eq(#ctx.calls.spawn, 0, 'props that exist are not re-created')
    byNet[801], byNet[802] = nil, nil   -- the engine deleted objective 1's entities
    ctx.capOk = false
    SC.tick(ctx, 1)
    H.eq(#ctx.calls.spawn, 0, 're-creation waits for the spawn cap')
    ctx.capOk = true
    SC.tick(ctx, 1)
    H.eq(#ctx.calls.spawn, 2, 'both device props re-created')
    local sp = ctx.calls.spawn[1]
    H.eq(sp.kind, 'object', 're-created device is an object')
    H.eq(sp.opts.model, 'prop_bomb_01', 'same model as the search spawned')
    H.eq(sp.opts.role, 'device', 're-created device role')
    H.eq(sp.opts.frozen, true, 're-created device is frozen')
    H.near(sp.opts.coords.w, 45.0, 1e-6, 'heading kept')
    H.near(sp.opts.coords.x, 10.0, 1e-6, 'at the device coords')
    H.eq(st.targets[1].netId, sp.netId, 'the target follows the new prop')
    H.eq(#st.targets, 2, 'no duplicate target for a re-created prop')
    SC.rescale(ctx); SC.tick(ctx, 1)
    H.eq(#st.targets, 2, 'still no duplicate after a sync')
    H.eq(#ctx.calls.spawn, 2, 'nothing more spawned while the props exist')
    at(1, vec3(10.0, 4000.0, 5.0))
    for k = 1, 4 do H.eq(round(ctx, 1, 1, k, true), true, 'defusing the re-created device, round ' .. k) end
    H.eq(st.targets[1].status, 'defused', 're-created device defused')
    byNet[st.targets[1].netId] = nil
    SC.tick(ctx, 1)
    H.eq(#ctx.calls.spawn, 2, 'a defused device is not re-created')
    -- a model that never spawns: give up after a few tries, the device still works at its coords
    local c2, s2 = defuseCtx({ devices = 1 })
    byNet[801] = nil
    c2.spawnObject = function(opts) c2.calls.spawn[#c2.calls.spawn + 1] = { opts = opts }; return nil, nil end
    for _ = 1, 6 do SC.tick(c2, 1) end
    H.eq(#c2.calls.spawn, 3, 'gives up after 3 failed re-creations')
    H.eq(c2.calls.spawn[1].opts.model, 'prop_ld_bomb', 'default device model')
    at(1, vec3(10.0, 4000.0, 5.0))
    H.eq(round(c2, 1, 1, 1, true), true, 'defusing works without the prop')
    -- location targets have no prop to re-create
    local c3 = fakeCtx({ obj = SC.defaults({ targets = 'panels' }), location = { panels = { vec3(0.0, 0.0, 0.0) } } })
    SC.prepare(c3); SC.start(c3); SC.tick(c3, 1)
    H.eq(#c3.calls.spawn, 0, 'location targets spawn nothing')
end

do -- a device added to shared.devices later is picked up (rescale/tick)
    local ctx, st = defuseCtx({ devices = 1 })
    props[8990] = { netId = 899, coords = vec3(99.0, 4000.0, 5.0) }
    byNet[899] = 8990
    ctx.run.shared.devices[2] = { netId = 899, coords = vec3(99.0, 4000.0, 5.0) }
    SC.rescale(ctx)
    H.eq(#st.targets, 2, 'late device synced')
    SC.onParticipantLeft(ctx, 1)
    SC.stop(ctx)
end

-- ════════════════════════════════════════════════════════════════════════════
-- locale part: every key the six files use exists
-- ════════════════════════════════════════════════════════════════════════════
do
    local f = assert(io.open(H.root .. 'locales/parts/blocks_a.json'))
    local part = require('cjson').decode(f:read('a'))
    f:close()
    local files = {
        'blocks/checkpoint_route/server.lua', 'blocks/checkpoint_route/client.lua',
        'blocks/interact_points/server.lua', 'blocks/interact_points/client.lua',
        'blocks/skill_check/server.lua', 'blocks/skill_check/client.lua',
    }
    local n = 0
    for _, rel in ipairs(files) do
        local src = assert(io.open(H.root .. rel)):read('a')
        for key in src:gmatch("'(block%.[%w_]+%.[%w_%.]+)'") do
            if key:sub(-1) ~= '.' and key:sub(-1) ~= '_' then
                n = n + 1
                H.ok(part[key] ~= nil, 'locale key ' .. key .. ' (' .. rel .. ')')
            end
        end
    end
    H.ok(n > 60, 'scanned the literal keys')
    for _, key in ipairs({
        'block.checkpoint_route.hud.medal_gold', 'block.checkpoint_route.hud.medal_silver', 'block.checkpoint_route.hud.medal_bronze',
        'block.interact_points.log.secure', 'block.interact_points.log.found_open',
        'block.interact_points.outcome.secure', 'block.interact_points.outcome.open',
        'bonus.medal_gold', 'bonus.medal_silver', 'bonus.medal_bronze', 'bonus.no_contact', 'bonus.devices_found_fast',
    }) do
        H.ok(part[key] ~= nil, 'dynamic locale key ' .. key)
    end
    for key in pairs(part) do
        H.ok(key:match('^block%.checkpoint_route%.') or key:match('^block%.interact_points%.') or key:match('^block%.skill_check%.') or key:match('^bonus%.'), 'namespace of ' .. key)
    end
end

-- ════════════════════════════════════════════════════════════════════════════
-- client halves: smoke test with native stubs and strict globals (a misspelt name errors)
-- ════════════════════════════════════════════════════════════════════════════
local serverImpl = { checkpoint_route = CR, interact_points = IP, skill_check = SC }
do
    local speeds, blips, zones, removedZones, explosions, sounds = {}, {}, {}, {}, {}, 0
    local removedDicts = {}
    local nextBlip = 0
    local function newBlip() nextBlip = nextBlip + 1; blips[nextBlip] = true; return nextBlip end
    local stub = {
        PlayerPedId = function() return 100 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 1 end,
        GetEntitySpeed = function(ent) return speeds[ent] or 0.0 end,
        GetPedInVehicleSeat = function(veh, seat) return 100 end,
        HasEntityCollidedWithAnything = function() return false end,
        IsVehicleDriveable = function(veh) return (vehicles[veh] and vehicles[veh].engine or 0) > 0 end,
        NetworkGetEntityIsNetworked = function(ent) return vehicles[ent] ~= nil end,
        DrawMarker = function() end,
        AddBlipForCoord = function() return newBlip() end,
        AddBlipForRadius = function() return newBlip() end,
        SetBlipSprite = function() end, SetBlipColour = function() end, SetBlipScale = function() end,
        SetBlipAsShortRange = function() end, SetBlipRoute = function() end, SetBlipRouteColour = function() end,
        SetBlipAlpha = function() end,
        BeginTextCommandSetBlipName = function() end, AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,
        DoesBlipExist = function(b) return blips[b] == true end,
        RemoveBlip = function(b) blips[b] = nil end,
        GetStreetNameAtCoord = function() return 11, 0 end,
        GetStreetNameFromHashKey = function() return 'Vespucci Blvd' end,
        GetNameOfZone = function() return 'DOWNT' end,
        GetLabelText = function() return 'Downtown' end,
        PlaySoundFrontend = function() sounds = sounds + 1 end,
        TaskPlayAnim = function() end,
        StopAnimTask = function() end,
        RemoveAnimDict = function(dict) removedDicts[#removedDicts + 1] = dict end,
        AddExplosion = function(x, y, z, kind, damage, audible, invisible, shake)
            explosions[#explosions + 1] = { x = x, y = y, z = z, kind = kind, damage = damage }
        end,
    }
    for k, v in pairs(stub) do _G[k] = v end
    local skillResults = {}
    lib.progressBar = function(opts) lib._lastProgress = opts; return true end
    lib.progressActive = function() return false end
    lib.cancelProgress = function() end
    lib.skillCheck = function(difficulty, keys)
        lib._skill = (lib._skill or 0) + 1
        local r = table.remove(skillResults, 1)
        if r == nil then return true end
        return r
    end
    lib.skillCheckActive = function() return false end
    lib.cancelSkillCheck = function() end
    lib.requestAnimDict = function() return true end
    H.exportsMock.ox_target = {
        addSphereZone = function(opts) zones[#zones + 1] = opts; return #zones end,
        removeZone = function(id) removedZones[id] = true end,
    }
    CP.Blocks._list.checkpoint_route, CP.Blocks._list.interact_points, CP.Blocks._list.skill_check = nil, nil, nil
    setmetatable(_G, { __index = function(_, k) error('undefined global ' .. tostring(k), 2) end })

    H.load('blocks/checkpoint_route/client.lua')
    H.load('blocks/interact_points/client.lua')
    H.load('blocks/skill_check/client.lua')
    local CRc, IPc, SCc = CP.Blocks.get('checkpoint_route'), CP.Blocks.get('interact_points'), CP.Blocks.get('skill_check')
    H.ok(CRc ~= serverImpl.checkpoint_route and CRc.update and IPc.update and SCc.update, 'client halves registered')

    local function clientCtx(obj, opts)
        opts = opts or {}
        local c = { runId = 'run-1', index = opts.index or 1, obj = obj, base = obj, mission = {}, location = {},
            isHost = true, test = false, radioSilence = opts.radioSilence == true, state = {}, participants = { 1 }, seed = 1 }
        c.reports, c.lines = {}, {}
        c.report = function(ev) c.reports[#c.reports + 1] = ev end
        c.hudDetail = function(text) c.lines[#c.lines + 1] = text or false end
        return c
    end
    local function lastLine(c)
        for i = #c.lines, 1, -1 do if c.lines[i] then return c.lines[i] end end
        return nil
    end
    local function steps(n, ms) for _ = 1, n do H.step(ms or 100) end end
    local function openBlips() local n = 0; for _ in pairs(blips) do n = n + 1 end; return n end

    -- checkpoint_route: snapshot before start, stop timer, report, stop cleans up
    H.clockMs = 7000000
    local loc = { start = { coords = vec3(100.0, 0.0, 30.0), radius = 30.0 }, spots = spots(6) }
    local sobj = serverImpl.checkpoint_route.defaults({ checkpoints = 'spots', use = 'all' })
    local sctx = fakeCtx({ obj = sobj, location = loc })
    serverImpl.checkpoint_route.prepare(sctx); serverImpl.checkpoint_route.start(sctx)
    local cctx = clientCtx(CP.U.deepcopy(sobj))
    CRc.prepare(cctx)
    CRc.update(cctx, lastSend(sctx))
    H.eq(openBlips(), 0, 'no blips before start')
    addVehicle(9001, 91, { model = joaat('sultan') })
    H.players[1] = { coords = vec3(100.0, 0.0, 30.0), vehicle = 9001 }
    speeds[9001] = 0.0
    CRc.start(cctx)
    H.eq(openBlips(), 2, 'current and next checkpoint blips')
    -- a passenger (someone else at the wheel): the HUD asks to drive, nothing is reported
    local seat = GetPedInVehicleSeat
    _G.GetPedInVehicleSeat = function() return 555 end
    steps(3)
    H.ok(tostring(lastLine(cctx)):find('driving a vehicle', 1, true) ~= nil, 'passenger: the HUD asks to drive: ' .. tostring(lastLine(cctx)))
    steps(120)
    H.eq(#cctx.reports, 0, 'passenger: no checkpoint report')
    _G.GetPedInVehicleSeat = seat
    steps(3)
    H.ok(tostring(lastLine(cctx)):find('Hold still', 1, true) ~= nil, 'stop timer on the HUD: ' .. tostring(lastLine(cctx)))
    steps(100)
    local rep = cctx.reports[1]
    H.ok(rep and rep.type == 'checkpoint' and rep.index == 1 and rep.netId == 91, 'checkpoint reported with the vehicle')
    H.ok(rep and rep.vehClass == nil and rep.model == nil, 'no vehicle class or model in the report (the server trusts neither)')
    -- the server accepts it and the next snapshot moves the client on
    serverImpl.checkpoint_route.tick(sctx, 1)
    sctx.state.near[1] = { cp = 1, since = H.clockMs - 11000 }
    H.eq(serverImpl.checkpoint_route.onEvent(sctx, 1, rep), true, 'server accepts the client evidence')
    CRc.update(cctx, lastSend(sctx))
    steps(1)
    H.ok(tostring(lastLine(cctx)):find('2 of 6', 1, true) ~= nil or tostring(lastLine(cctx)):find('cleared', 1, true) ~= nil, 'HUD follows the snapshot: ' .. tostring(lastLine(cctx)))
    speeds[9001] = 10.0
    H.players[1].coords = vec3(200.0, 0.0, 30.0)
    steps(2)
    H.ok(tostring(lastLine(cctx)):find('Stop inside', 1, true) ~= nil, 'moving inside the marker: ' .. tostring(lastLine(cctx)))
    CRc.hostChanged(cctx, false)
    CRc.stop(cctx)
    H.eq(openBlips(), 0, 'stop removes the blips')
    H.eq(cctx.lines[#cctx.lines], false, 'stop clears the HUD line')
    local before = #cctx.reports
    steps(20)
    H.eq(#cctx.reports, before, 'the loop ended with stop')
    -- radio silence: no blips, the street name instead
    local rctx = clientCtx(CP.U.deepcopy(sobj), { radioSilence = true })
    CRc.update(rctx, lastSend(sctx)); CRc.start(rctx)
    H.eq(openBlips(), 0, 'radio silence: no blips')
    H.players[1].coords = vec3(2000.0, 0.0, 30.0)
    steps(12)
    H.ok(tostring(lastLine(rctx)):find('Vespucci', 1, true) ~= nil, 'radio silence shows the street: ' .. tostring(lastLine(rctx)))
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.eq(rctx.lines[#rctx.lines], false, 'resource stop cleans up')

    -- EVOC client: contact detection and undriveable report while the course runs
    local eobj = serverImpl.checkpoint_route.defaults({ checkpoints = 'course', stopFor = 0, medals = true })
    local eloc = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 30.0 }, course = spots(4), medals = { gold = 60, silver = 80, bronze = 100 } }
    local ectx = fakeCtx({ obj = eobj, location = eloc })
    serverImpl.checkpoint_route.prepare(ectx); serverImpl.checkpoint_route.start(ectx)
    H.players[1] = { coords = vec3(100.0, 0.0, 30.0), vehicle = 9001 }
    speeds[9001] = 20.0
    local ec = clientCtx(CP.U.deepcopy(eobj))
    ec.state = {}
    H.eq(lastSend(ectx).course.held, true, 'EVOC server holds the run timer before checkpoint 1')
    CRc.update(ec, lastSend(ectx)); CRc.start(ec)
    steps(1)
    H.ok(tostring(lastLine(ec)):find('timer starts at checkpoint 1', 1, true) ~= nil, 'HUD says the timer waits: ' .. tostring(lastLine(ec)))
    H.eq(ec.reports[1] and ec.reports[1].index, 1, 'drive-through gate reported at speed')
    serverImpl.checkpoint_route.onEvent(ectx, 1, ec.reports[1])
    CRc.update(ec, lastSend(ectx))
    steps(2)
    speeds[9001] = 5.0          -- 15 m/s lost in one sample: a crash
    steps(2)
    local contact
    for _, r in ipairs(ec.reports) do if r.type == 'contact' then contact = r end end
    H.ok(contact ~= nil and contact.netId == 91, 'crash reported as a contact')
    vehicles[9001].engine = -10.0
    steps(2)
    local und
    for _, r in ipairs(ec.reports) do if r.type == 'undriveable' then und = r end end
    H.ok(und ~= nil and und.netId == 91, 'undriveable vehicle reported')
    H.ok(tostring(lastLine(ec)):find('Time', 1, true) ~= nil or tostring(lastLine(ec)):find('Contact', 1, true) ~= nil, 'course line on the HUD: ' .. tostring(lastLine(ec)))
    ec.state.transient = nil
    local before = #ec.lines
    steps(5, 100)   -- half a second of frames
    local line = tostring(lastLine(ec))
    H.ok(line:find('Time %d+ s') ~= nil and line:find('%d%.%d') == nil, 'running course clock in whole seconds: ' .. line)
    H.ok(#ec.lines - before <= 2, ('HUD line sent at most once a second (%d updates)'):format(#ec.lines - before))
    CRc.stop(ec)
    vehicles[9001].engine = 1000.0

    -- interact_points: zones, progress bar, follow-up swap, cleanup
    local iloc = { start = { coords = vec3(200.0, 1000.0, 20.0), radius = 40.0 }, businesses = businesses(12) }
    local iobj = serverImpl.interact_points.defaults(CP.U.deepcopy(businessObj))
    local ictx = fakeCtx({ obj = iobj, location = iloc, seed = 3 })
    serverImpl.interact_points.prepare(ictx); serverImpl.interact_points.start(ictx)
    local ic = clientCtx(CP.U.deepcopy(iobj))
    IPc.prepare(ic); IPc.start(ic); IPc.update(ic, lastSend(ictx))
    H.eq(#zones, 4, 'one ox_target zone per open door')
    H.ok(zones[1].name:find('^crimson%-police:') ~= nil and zones[1].options[1].name:find('^crimson%-police:') ~= nil, 'zone and option names prefixed')
    H.eq(zones[1].options[1].label, 'Check door', 'target label from the mission')
    H.eq(openBlips(), 4, 'a blip per open door')
    H.eq(zones[1].options[1].canInteract(), true, 'option available')
    zones[1].options[1].onSelect()
    H.eq(ic.reports[1] and ic.reports[1].type, 'interact', 'progress bar finished -> interact reported')
    H.eq(ic.reports[1].point, 1, 'interact point')
    H.eq(ic.reports[1].seq, 1, 'interact report carries a sequence number')
    H.eq(lib._lastProgress.duration, 5000, 'progress duration from the objective')
    H.eq(lib._lastProgress.canCancel, true, 'progress can be cancelled')
    H.eq(lib._lastProgress.disable.move, true, 'movement disabled')
    H.eq(lib._lastProgress.anim.scenario, 'WORLD_HUMAN_CLIPBOARD', 'clipboard animation')
    local snap = CP.U.deepcopy(lastSend(ictx))
    snap.points[1].status = 'followup'
    snap.points[1].outcomeLabel = 'The door was found open'
    snap.points[1].followUp = { label = 'Secure door', duration = 5000 }
    IPc.update(ic, snap)
    H.ok(removedZones[1] == true, 'main zone removed after the check')
    H.eq(zones[5].options[1].label, 'Secure door', 'follow-up zone added')
    steps(6)
    H.ok(tostring(lastLine(ic)):find('Secure door', 1, true) ~= nil, 'follow-up hint: ' .. tostring(lastLine(ic)))
    zones[5].options[1].onSelect()
    H.eq(ic.reports[2] and ic.reports[2].type, 'followup', 'follow-up reported')
    H.eq(ic.reports[2].seq, 2, 'sequence number counts up')
    snap = CP.U.deepcopy(snap)
    snap.points[1].status = 'log'
    snap.log = { point = 1, choices = { { id = 'secure', label = 'Secure' } } }
    IPc.update(ic, snap)
    ic.state.transient = nil
    steps(6)
    H.ok(tostring(lastLine(ic)):find('tablet', 1, true) ~= nil, 'log hint on the HUD: ' .. tostring(lastLine(ic)))
    IPc.hostChanged(ic, false)
    IPc.stop(ic)
    local allRemoved = true
    for id = 1, #zones do if not removedZones[id] then allRemoved = false end end
    H.ok(allRemoved, 'stop removes every zone')
    H.eq(openBlips(), 0, 'stop removes the blips')
    -- hidden search client: one area blip, search target label, found message
    local bobj = serverImpl.interact_points.defaults({ points = 'spots', hidden = { count = 1 }, target = { label = 'Search' }, progress = { duration = 3000, anim = 'search' } })
    local bctx = fakeCtx({ obj = bobj, location = { spots = spots(6) } })
    serverImpl.interact_points.prepare(bctx); serverImpl.interact_points.start(bctx)
    local bc = clientCtx(CP.U.deepcopy(bobj))
    IPc.start(bc); IPc.update(bc, lastSend(bctx))
    H.eq(openBlips(), 2, 'hidden search: area blip and centre')
    local s2 = CP.U.deepcopy(lastSend(bctx))
    s2.points[2].status = 'done'; s2.points[2].found = true; s2.found = 1
    IPc.update(bc, s2)
    steps(6)
    H.ok(tostring(lastLine(bc)):find('found', 1, true) ~= nil, 'device found message: ' .. tostring(lastLine(bc)))
    IPc.stop(bc)

    -- skill_check: rounds one by one, stop on a miss, explosion effect for the reporter
    local zbase = #zones
    local kobj = serverImpl.skill_check.defaults({})
    local kc = clientCtx(CP.U.deepcopy(kobj), { index = 2 })
    SCc.prepare(kc); SCc.start(kc)
    SCc.update(kc, { kind = 'state', checks = 4, targets = {
        { coords = { x = 10.0, y = 0.0, z = 0.0 }, netId = 801, status = 'armed', next = 1, streak = 0 },
        { coords = { x = 20.0, y = 0.0, z = 0.0 }, netId = 802, status = 'armed', next = 3, streak = 0 },
    } })
    H.eq(#zones - zbase, 2, 'a zone per armed device')
    H.eq(zones[zbase + 1].options[1].label, 'Defuse device', 'default defuse label')
    skillResults = { true, true, false }
    zones[zbase + 1].options[1].onSelect()
    steps(5)
    H.eq(#kc.reports, 3, 'three rounds reported, stopped at the miss')
    H.eq(removedDicts[#removedDicts], 'amb@medic@standing@kneel@base', 'the kneel animation dictionary is released after the defuse')
    H.ok(kc.reports[1].index == 1 and kc.reports[1].success == true and kc.reports[3].success == false, 'rounds reported in order')
    skillResults = {}
    zones[zbase + 2].options[1].onSelect()
    steps(5)
    H.eq(kc.reports[4].index, 3, 'a device resumes at its next round')
    H.eq(#kc.reports, 5, 'rounds 3 and 4 of device 2')
    SCc.update(kc, { kind = 'state', checks = 4, targets = {
        { coords = { x = 10.0, y = 0.0, z = 0.0 }, netId = 801, status = 'armed', next = 3, streak = 1 },
        { coords = { x = 20.0, y = 0.0, z = 0.0 }, netId = 802, status = 'defused', next = 5, streak = 0 },
    } })
    skillResults = { false }
    zones[zbase + 1].options[1].onSelect()
    steps(5)
    local m1, m2 = kc.reports[3], kc.reports[6]
    H.ok(m1.index == m2.index and m1.success == false and m2.success == false and m1.seq ~= m2.seq,
        'two misses in a row on the same round are distinct reports (seq)')
    SCc.update(kc, { kind = 'explode', target = 1, coords = { x = 10.0, y = 0.0, z = 0.0 }, by = 1, effect = true })
    H.eq(#explosions, 1, 'the reporting participant plays the explosion')
    H.eq(explosions[1].damage, 0.0, 'explosion damage scale 0')
    SCc.update(kc, { kind = 'explode', target = 1, coords = { x = 10.0, y = 0.0, z = 0.0 }, by = 7, effect = true })
    H.eq(#explosions, 1, 'other participants do not add an explosion')
    SCc.hostChanged(kc, false)
    SCc.stop(kc)
    H.ok(removedZones[zbase + 1] and removedZones[zbase + 2], 'stop removes the defuse zones')

    -- The engine may hand every hook a fresh ctx (and ctx.state): each block keeps one state per run/objective.
    local function fresh(base)
        local c = {}
        for k, v in pairs(base) do c[k] = v end
        c.state = {}
        return c
    end
    do
        local z0 = #zones
        local fc = clientCtx(CP.U.deepcopy(iobj))
        fc.runId = 'run-fresh'
        IPc.prepare(fresh(fc))
        IPc.update(fresh(fc), lastSend(ictx))   -- snapshot before start, as the engine may deliver it
        IPc.start(fresh(fc))
        H.eq(#zones - z0, 4, 'fresh ctx.state per hook: the pending snapshot still registers the zones')
        zones[z0 + 1].options[1].onSelect()
        H.eq(fc.reports[1] and fc.reports[1].type, 'interact', 'fresh ctx.state per hook: targets work')
        IPc.stop(fresh(fc))
        local gone = true
        for id = z0 + 1, #zones do if not removedZones[id] then gone = false end end
        H.ok(gone, 'fresh ctx.state per hook: stop removes every zone')
        H.eq(openBlips(), 0, 'fresh ctx.state per hook: stop removes the blips')

        local cf = clientCtx(CP.U.deepcopy(sobj))
        cf.runId = 'run-fresh'
        H.players[1] = { coords = vec3(2000.0, 0.0, 30.0), vehicle = 9001 }
        CRc.prepare(fresh(cf)); CRc.update(fresh(cf), lastSend(sctx)); CRc.start(fresh(cf))
        H.eq(openBlips(), 2, 'checkpoint_route with fresh ctx.state: blips shown')
        CRc.update(fresh(cf), lastSend(sctx))
        H.eq(openBlips(), 2, 'a later snapshot reaches the same state')
        CRc.stop(fresh(cf))
        H.eq(openBlips(), 0, 'checkpoint_route with fresh ctx.state: stop removes the blips')
        local n = #cf.reports
        steps(10)
        H.eq(#cf.reports, n, 'checkpoint_route loop ended')

        local z1 = #zones
        local kf = clientCtx(CP.U.deepcopy(kobj), { index = 2 })
        kf.runId = 'run-fresh'
        SCc.prepare(fresh(kf)); SCc.start(fresh(kf))
        SCc.update(fresh(kf), { kind = 'state', checks = 4, targets = {
            { coords = { x = 10.0, y = 0.0, z = 0.0 }, netId = 801, status = 'armed', next = 1, streak = 0 },
        } })
        H.eq(#zones - z1, 1, 'skill_check with fresh ctx.state: zone added after start')
        SCc.stop(fresh(kf))
        H.ok(removedZones[z1 + 1] == true, 'skill_check with fresh ctx.state: stop removes the zone')
    end

    setmetatable(_G, nil)
end

return H
