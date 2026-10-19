-- Pursuit cars through the spawn director (Config.Spawning, PLAN S13) on the real engine, the real block and the

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
H.load('modules/spawn/server.lua')
H.load('blocks/pursuit/server.lua')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = U.deepcopy(v) end
end
H.eq(cfg.vehicleLift, 0.5, 'a car made on the road itself is lifted 0.5 m over it')
H.eq(cfg.secondViolatorUpstream, 200.0, 'a second violator appears 200 m up the road from the officers')

-- ============================================================================
--                              CONSOLE, WARNINGS
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if line:find('^  FAIL ') then realPrint(line) end
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end
local realWarn = CP.warn
local warns = {}
CP.warn = function(tag, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    warns[#warns + 1] = { tag = tag, text = ok and text or fmt }
    return realWarn(tag, fmt, ...)
end
local function WarnsWith(text)
    local out = {}
    for _, w in ipairs(warns) do if w.text:find(text, 1, true) then out[#out + 1] = w end end
    return out
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function Secs(n) W.tick(n) end
local function Place(src, x, y) W.place(src, x, y, 30.0) end
local function Me(src) return H.players[src].coords end
local function Ctx(run, i) return CP.Runs.ctx(run, i) end
local function EndRun(run)
    if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end
    Secs(1)
end

-- The suspect cars of objective i in the order they were made: { netId, at = coords, bag = cp bag }.
local function Cars(run, i)
    local st = run.objectives[i] and run.objectives[i].state
    local out = {}
    for _, key in ipairs(st and st.vorder or {}) do
        local v = st.vehicles[key]
        local e = run.entities[v.netId]
        out[#out + 1] = {
            netId = v.netId,
            v = v,
            at = W.at(run, v.netId),
            bag = e and W.bags[e.entity] and W.bags[e.entity].cp or nil,
        }
    end
    return out
end

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

-- A straight corridor north along x = 5000, 2 km long (a waypoint every 100 m, the road at z 30); the observation
-- point 16 m right of the road at y = 5800.
local function Corridor()
    local pts = {}
    for i = 0, 20 do pts[#pts + 1] = vec3(5000.0, 5000.0 + i * 100.0, 30.0) end
    return {
        label = 'Corridor',
        start = { coords = vec3(5016.0, 5800.0, 30.0), radius = 40.0 },
        speed = 80,
        route = { points = pts, loop = false },
    }
end

local function Violator(extra)
    local o = {
        block = 'pursuit',
        label = 'Observe and stop the violator',
        mode = 'stop',
        vehicles = 1,
        suspectsPerVehicle = 1,
        route = 'route',
        spawnOffset = -200,
        models = { 'sultan' },
        trigger = { distance = 60.0, lights = true },
        footFlee = 0,
        responses = { yield = 1.0, flee = 0, fight = 0 },
        observe = { kind = 'pace', zoneSpeed = 'speed', over = { 20, 45 }, behind = 80.0, seconds = 5, tolerance = 5 },
        fastStop = false,
        neverShoots = true,
        minSeconds = 0,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

-- Traffic Enforcement's shape: the violator, a hold (the stop), the second violator, a hold.
local function TwoViolators(location)
    return W.mission({
        Violator(),
        { block = 'stub_hold', label = 'Work the stop', minSeconds = 0 },
        Violator({ label = 'Observe and stop the second violator' }),
        { block = 'stub_hold', label = 'Work the second stop', minSeconds = 0 },
    }, location or Corridor())
end

-- Objective 1 (the first violator) and 2 (its stop) done, with the officers where the test put them.
local function ToSecondViolator(run)
    Ctx(run, 1).complete({})
    Secs(1)
    Ctx(run, 2).complete({})
    Secs(1)
    H.eq(run.objectiveIndex, 3, 'the second violator\'s objective runs')
end

-- ============================================================================
--                            1. THE FIRST VIOLATOR
-- ============================================================================
-- 200 M UP THE ROAD FROM THE OBSERVATION POINT, 0.5 M OVER THE ROAD.

do
    Reset()
    warns, lines = {}, {}
    Place(1, 5016.0, 5800.0)
    local run = W.start({ 1 }, TwoViolators())
    Secs(1)
    local cars = Cars(run, 1)
    H.eq(#cars, 1, 'the first violator is made at once')
    local c = cars[1]
    H.near(c.at.y, 5600.0, 0.01, 'it is 200 m up the road from the observation point')
    H.near(c.at.x, 5000.0, 0.01, 'on the road')
    H.near(c.at.z, 30.5, 0.001, 'its z is the road\'s plus vehicleLift (0.5 m): never inside the road surface')
    H.ok(c.bag and c.bag.place and math.abs(c.bag.place.z - 30.5) < 0.001,
        'it waits frozen for an officer\'s game to put it on its wheels there (the placer, at the lifted z)')
    H.eq(#LinesWith('vehicle 1 at spawnOffset -200 m'), 1, 'the console names where it was made')
    EndRun(run)
end

do
    -- vehicleLift = 0: on the road's own height, as before
    Reset()
    cfg.vehicleLift = 0
    Place(1, 5016.0, 5800.0)
    local run = W.start({ 1 }, TwoViolators())
    Secs(1)
    local c = Cars(run, 1)[1]
    H.near(c and c.at.z or 0, 30.0, 0.001, 'vehicleLift 0: on the road\'s height, as before')
    EndRun(run)
end

do
    -- three cars queue 8 m apart behind the first, all lifted; the race loop's waypoint is lifted, a file point is not
    Reset()
    Place(1, 5016.0, 5800.0)
    local run = W.start({ 1 }, W.mission({ Violator({ vehicles = 3 }) }, Corridor()))
    Secs(1)
    local cars = Cars(run, 1)
    H.eq(#cars, 3, 'three cars')
    for i, c in ipairs(cars) do
        H.near(c.at.y, 5600.0 - (i - 1) * 8.0, 0.01, ('car %d queues %d m behind the first'):format(i, (i - 1) * 8))
        H.near(c.at.z, 30.5, 0.001, ('car %d is 0.5 m over the road'):format(i))
    end
    EndRun(run)

    local loop = Corridor()
    loop.route = {
        points = {
            vec3(6000.0, 6000.0, 40.0),
            vec3(6200.0, 6000.0, 40.0),
            vec3(6200.0, 6200.0, 40.0),
            vec3(6000.0, 6200.0, 40.0),
        },
        loop = true,
    }
    loop.start = { coords = vec3(6100.0, 5900.0, 40.0), radius = 40.0 }
    Place(1, 6100.0, 5900.0)
    run = W.start({ 1 }, W.mission({
        Violator({ spawnOffset = false, observe = false, route = 'route', trigger = { distance = 60.0 } }),
    }, loop))
    Secs(1)
    local r = Cars(run, 1)[1]
    H.ok(r ~= nil, 'a race loop car is made on a waypoint of the loop')
    H.near(r and r.at.z or 0, 40.5, 0.001, 'a race loop\'s waypoint is lifted 0.5 m over the road too')
    EndRun(run)

    local grid = Corridor()
    grid.grid = { vec4(5000.0, 5300.0, 30.6, 0.0) }
    Place(1, 5016.0, 5800.0)
    run = W.start({ 1 }, W.mission({ Violator({ spawnOffset = false, observe = false, spawns = 'grid' }) }, grid))
    Secs(1)
    local g = Cars(run, 1)[1]
    H.near(g and g.at.z or 0, 30.6, 0.001, 'a mission file\'s own car point is used as written (already over the road)')
    EndRun(run)
end

-- ============================================================================
--                            2. THE SECOND VIOLATOR
-- ============================================================================
-- UP THE ROAD FROM THE OFFICERS, WHEREVER THEY WORKED THE FIRST STOP.

do
    -- the a1 case: an officer who chased the first violator back up the road stands on its old spot (y 5600)
    Reset()
    warns, lines = {}, {}
    Place(1, 5016.0, 5800.0)
    Place(2, 5016.0, 5810.0)
    local run = W.start({ 1, 2 }, TwoViolators())
    Secs(1)
    local first = Cars(run, 1)[1]
    H.near(first.at.y, 5600.0, 0.01, 'the first violator came from y 5600')
    Place(1, 5004.0, 5600.0)
    Place(2, 5000.0, 6400.0)
    ToSecondViolator(run)
    local cars = Cars(run, 3)
    H.eq(#cars, 1, 'the second violator is made')
    local c = cars[1]
    H.ok(c and D2(c.at, first.at) > 150.0, 'not at the first violator\'s point, where an officer stands now')
    H.ok(c and D2(c.at, Me(1)) >= 199.0, 'it is 200 m up the road from the officer furthest up it')
    H.near(c and c.at.y or 0, 5400.0, 0.01, 'at y 5400: 200 m before officer 1, so it drives towards both officers')
    H.near(c and c.at.x or 0, 5000.0, 0.01, 'on the road')
    H.near(c and c.at.z or 0, 30.5, 0.001, 'and 0.5 m over it')
    H.near(c and c.at.w or (W.model(run, c.netId) or {}).heading or 0, 0.0, 0.01, 'facing the driving direction')
    H.eq(#LinesWith('200 m up the road from player 1'), 1, 'the console names the officer it counted from')
    -- its blip shows once it has passed officer 1 (where he stood), not before
    local v = c.v
    H.ok(v.passed ~= true, 'not past the officers yet: no blip')
    local m = W.model(run, c.netId)
    m.coords, m.heading = vec3(5000.0, 5550.0, 30.0), 0.0
    Secs(1)
    H.ok(v.passed ~= true, 'still 50 m before him: no blip')
    m.coords = vec3(5000.0, 5650.0, 30.0)
    Secs(1)
    H.eq(v.passed, true, 'past where officer 1 stood: it counts as passed (its blip shows)')
    EndRun(run)
end

do
    -- the officers 700 m and 500 m down the road from the observation point: it comes 200 m before the nearer one,
    -- not from y 5600, 900 m behind them (out of their 424 m range: nobody's game would even move it)
    Reset()
    Place(1, 5016.0, 5800.0)
    Place(2, 5016.0, 5810.0)
    local run = W.start({ 1, 2 }, TwoViolators())
    Secs(1)
    Place(1, 5000.0, 6500.0)
    Place(2, 5030.0, 6300.0)   -- 30 m off the road counts as on it
    ToSecondViolator(run)
    local c = Cars(run, 3)[1]
    H.near(c and c.at.y or 0, 6100.0, 0.01, 'it comes 200 m up the road from officer 2, the one furthest up it')
    H.ok(c and D2(c.at, Me(1)) >= 200.0 and D2(c.at, Me(2)) >= 200.0, '200 m or more from both officers')
    EndRun(run)
end

do
    -- nobody on the road (both 500 m off it): from the observation point's spot, as the first one
    Reset()
    Place(1, 5016.0, 5800.0)
    Place(2, 5016.0, 5810.0)
    local run = W.start({ 1, 2 }, TwoViolators())
    Secs(1)
    Place(1, 5500.0, 6000.0)
    Place(2, 5500.0, 6100.0)
    ToSecondViolator(run)
    local c = Cars(run, 3)[1]
    H.near(c and c.at.y or 0, 5600.0, 0.01, 'no officer on the road: from the observation point\'s spot')
    EndRun(run)
end

do
    -- secondViolatorUpstream = 0: at the first violator's point, as before; enabled = false: the same, on the road's
    -- height, at once even with an officer on it
    for _, mode in ipairs({ 'zero', 'off' }) do
        Reset()
        if mode == 'zero' then cfg.secondViolatorUpstream = 0 else cfg.enabled = false end
        Place(1, 5016.0, 5800.0)
        Place(2, 5016.0, 5810.0)
        local run = W.start({ 1, 2 }, TwoViolators())
        Secs(1)
        Place(1, 5004.0, 5600.0)
        Place(2, 5000.0, 6400.0)
        ToSecondViolator(run)
        local c = Cars(run, 3)[1]
        if mode == 'zero' then
            -- the director still keeps it off the officer standing there: it waits until he moves
            H.eq(c, nil, 'secondViolatorUpstream 0: the first one\'s spot, but not while an officer stands on it')
            Place(1, 5000.0, 6450.0)
            Secs(1)
            c = Cars(run, 3)[1]
            H.near(c and c.at.y or 0, 5600.0, 0.01, 'he drives off: at the first violator\'s point, as before')
        else
            H.near(c and c.at.y or 0, 5600.0, 0.01, 'enabled = false: at the first violator\'s point, as before')
            H.near(c and c.at.z or 0, 30.0, 0.001, 'enabled = false: on the road\'s height, as before')
        end
        EndRun(run)
    end
end

-- ============================================================================
--                        3. THE DIRECTOR AND THE PLACER
-- ============================================================================

do
    -- an officer 10 m from the spot and its slots: the car waits; he drives off: it appears
    Reset()
    warns, lines = {}, {}
    Place(1, 5016.0, 5800.0)
    Place(2, 5005.0, 5590.0)
    local run = W.start({ 1, 2 }, W.mission({ Violator() }, Corridor()))
    Secs(3)
    H.eq(#Cars(run, 1), 0, 'an officer 10 m from the spot: the car does not pop in beside him')
    H.ok(#LinesWith('vehicle 1 at spawnOffset -200 m skipped') >= 1, 'the console says why it waits')
    H.eq(run.state, 'in_progress', 'the run goes on (it waits, it does not fail)')
    Place(2, 5016.0, 5810.0)
    W.roadAsks = {}
    Secs(1)
    local c = Cars(run, 1)[1]
    H.near(c and c.at.y or 0, 5600.0, 0.01, 'he drives off: it appears on its spot')
    local seen = 0
    for _, a in ipairs(W.roadAsks) do if a.name == 'crimson-police:client:spawn:visible' then seen = seen + 1 end end
    H.eq(seen, 0, 'no officer\'s game is asked what it sees: a car\'s slots keep their own order (ordered)')
    EndRun(run)
end

do
    -- an officer 30 m from the spot: after waveDelayMax (20 s) hardMin (20 m) is enough, with one warning
    Reset()
    warns = {}
    Place(1, 5016.0, 5800.0)
    Place(2, 5000.0, 5610.0)   -- 10, 18 and 26 m from the car's three slots
    local run = W.start({ 1, 2 }, W.mission({ Violator() }, Corridor()))
    Secs(18)
    H.eq(#Cars(run, 1), 0, 'an officer 10-26 m from every slot for 18 s: it still waits')
    Secs(4)
    local c = Cars(run, 1)[1]
    H.ok(c ~= nil, 'after waveDelayMax it appears')
    H.near(c and c.at.y or 0, 5584.0, 0.01, 'on the first slot hardMin (20 m) allows: 16 m further up the road')
    H.ok(c and D2(c.at, Me(2)) >= 20.0, 'never under hardMin')
    H.eq(#WarnsWith('vehicle 1 waited'), 1, 'one warning that it had to come closer')
    EndRun(run)

    -- 10 m away: under hardMin it never appears beside him
    Reset()
    Place(1, 5016.0, 5800.0)
    Place(2, 5000.0, 5600.0)
    run = W.start({ 1, 2 }, W.mission({ Violator() }, Corridor()))
    Secs(40)
    local near = Cars(run, 1)[1]
    H.ok(near == nil or D2(near.at, Me(2)) >= 20.0, 'an officer on the spot: never a car within hardMin of him')
    EndRun(run)
end

do
    -- the officer's game finds the spot bad: the placer moves the car to the next slot (8 m further up the road)
    Reset()
    warns = {}
    Place(1, 5016.0, 5800.0)
    local run = W.start({ 1 }, W.mission({ Violator() }, Corridor()))
    Secs(1)
    local c = Cars(run, 1)[1]
    local place = c and c.bag and c.bag.place
    H.ok(place ~= nil, 'the car waits for its placement')
    H.fire('crimson-police:server:spawnPlaced', 1, run.id,
        { netId = c.netId, token = place.token, result = 'bad', reason = 'underground', z = 25.0 })
    Secs(1)
    local again = Cars(run, 1)[1].bag.place
    H.ok(again and again.token ~= place.token, 'a new placement ask')
    H.near(again and again.y or 0, 5592.0, 0.01, 'at the slot behind it on the road (the objective\'s next slot)')
    H.near(again and again.z or 0, 30.5, 0.001, 'lifted like its own')
    H.eq(#WarnsWith('vehicle 1 at spawnOffset -200 m, 8 m back'), 1, 'the console names the slot it moved to')
    EndRun(run)
end

-- ============================================================================
--                4. NEVER ON A PLAYER (no start to count from)
-- ============================================================================

do
    Reset()
    warns = {}
    Place(1, 5016.0, 5800.0)
    local run = W.start({ 1 }, W.mission({
        { block = 'stub_hold', label = 'Drive in', minSeconds = 0 },
        Violator(),
    }, Corridor()))
    Secs(1)
    -- the location loses its start (a custom mission's broken location); the officer stands 30 m off the road
    run.location.start = nil
    Place(1, 5030.0, 6500.0)
    Ctx(run, 1).complete({})
    Secs(1)
    local c = Cars(run, 2)[1]
    H.ok(c ~= nil, 'the car takes the objective\'s other points')
    H.ok(c and D2(c.at, vec3(5000.0, 6300.0, 30.0)) > 50.0,
        'not 200 m up the road from the officer\'s position (spawnOffset never counts from a player)')
    H.near(c and c.at.y or 0, 5000.0, 0.01, 'at the road route\'s first point')
    H.near(c and c.at.z or 0, 30.5, 0.001, 'lifted over the road')
    H.eq(#WarnsWith('no start for spawnOffset to count from'), 1, 'one warning')
    EndRun(run)
end

_G.print = realPrint
CP.warn = realWarn
return H
