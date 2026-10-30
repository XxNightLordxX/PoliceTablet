-- field_contact through the spawn director (Config.Spawning, PLAN S12) on the real engine, the real block and the

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
H.load('modules/spawn/server.lua')
local impl = CP.Blocks.get('field_contact')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = U.deepcopy(v) end
end
H.eq(cfg.contactRing and cfg.contactRing[1], 25.0, 'a returning driver or a thief appears 25 m or more from the car')
H.eq(cfg.contactRing and cfg.contactRing[2], 40.0, 'and 40 m at most')
H.eq(cfg.sceneOutside, 10.0, 'a scene appears beyond the approach distance plus 10 m')
H.eq(cfg.sceneWaitMax, 45, 'and appears anyway after 45 s of officers standing too close')

-- ============================================================================
--                  CONSOLE, WARNINGS, HUD, THE OFFICER'S GAME
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
local huds = {}
local realHud = CP.Runs.hud
CP.Runs.hud = function(run, patch)
    if type(patch) == 'table' and type(patch.message) == 'table' then huds[#huds + 1] = patch.message end
    return realHud(run, patch)
end
local function HudsWith(text)
    local n = 0
    for _, m in ipairs(huds) do
        local t = type(m.text) == 'table' and (m.text.key or '') or tostring(m.text)
        if tostring(t):find(text, 1, true) then n = n + 1 end
    end
    return n
end

-- The officer's game answering the walk-in ask (modules/spawn/client.lua Spawn.walkIn): Answer(src, args) -> the
-- reply and how long his game takes (ox_lib's await yields until the reply comes back).
local WALK_IN = 'crimson-police:client:spawn:walkIn'
local asks = {}
local Answer = nil
local roadAwait = lib.callback.await
lib.callback.await = function(name, src, args)
    if name ~= WALK_IN then return roadAwait(name, src, args) end
    asks[#asks + 1] = { src = src, args = U.deepcopy(args), at = H.clockMs }
    local reply, delay = nil, 300
    if Answer then reply, delay = Answer(src, args) end
    Wait(delay or 300)
    return reply
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function Secs(n) W.tick(n) end
local function Place(src, x, y) W.place(src, x, y, 30.0) end
local function Me(src) return H.players[src].coords end
local function EndRun(run)
    if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end
    Secs(1)
end
local function Acts(behaviour, netId)
    local out = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:contactAct')) do
        local d = e.args[1]
        if d and d.behaviour == behaviour and (netId == nil or d.netId == netId) then out[#out + 1] = e end
    end
    return out
end
local function Person(run, role)
    for _, p in ipairs(W.people(run, 1)) do if p.role == role then return p end end
    return nil
end
local function St(run) return run.objectives[1].state end
-- An officer's game put netId on the ground where it waits (server:spawnPlaced, Config.Spawning.place).
local function Placed(src, run, netId)
    local e = run.entities[netId]
    local place = e and W.bags[e.entity] and W.bags[e.entity].cp and W.bags[e.entity].cp.place
    H.ok(place ~= nil, 'he waits frozen for his placement where he appeared')
    if not place then return end
    H.fire('crimson-police:server:spawnPlaced', src, run.id,
        { netId = netId, token = place.token, result = 'placed', reason = 'ok', z = place.z })
end

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

-- Four kerb spots along y = 1000 at x = 1060, 1120, 1300, 1500; the start 50 m short of the first.
local function Street(n)
    local xs = { 1060.0, 1120.0, 1300.0, 1500.0 }
    local spots = {}
    for i = 1, n or 4 do
        spots[i] = { coords = vec4(xs[i], 1000.0, 30.0, 90.0), rule = 'metered', street = 'Alta Street' }
    end
    return { label = 'Alta Street', start = { coords = vec3(1000.0, 950.0, 30.0), radius = 40.0 }, spots = spots }
end

local function Scene()
    return {
        label = 'Behind the 24/7',
        start = { coords = vec3(2000.0, 1940.0, 30.0), radius = 40.0 },
        car = vec4(2000.0, 2000.0, 30.0, 0.0),
        peopleSpots = {
            vec4(2003.0, 2000.0, 30.0, 0.0),
            vec4(2005.0, 2002.0, 30.0, 0.0),
            vec4(2006.0, 1998.0, 30.0, 0.0),
        },
        fleeTo = { { vec3(2100.0, 2000.0, 30.0), vec3(2200.0, 2000.0, 30.0) } },
        transport = vec4(2010.0, 1980.0, 30.0, 0.0),
    }
end

local function Parked(cars, extra, n)
    local o = {
        block = 'field_contact',
        label = 'Check the cars',
        mode = 'parked',
        cars = cars,
        profileSet = 'test_legal',
        returning = { chance = 0 },
        thief = { chance = 0 },
        minSeconds = 0,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return W.mission({ o, { block = 'stub_hold', label = 'After', minSeconds = 0 } }, Street(n))
end

local function SceneMission()
    return W.mission({
        {
            block = 'field_contact',
            label = 'Check the scene',
            mode = 'scene',
            people = 2,
            cars = 1,
            profileSet = 'test_clean',
            scene = { loitering = 1 },
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, Scene())
end

local sets = Config.Custody.profileSets
sets.test_clean = sets.test_clean or { person = { clean = 100 }, vehicle = { legal = 100 } }
sets.test_legal = sets.test_legal or { vehicle = { legal = 100 } }
sets.test_stolen = sets.test_stolen or { vehicle = { stolen = 100 } }

-- the car at x on the street, or nil
local function CarAt(run, x)
    for _, c in ipairs(W.cars(run, 1)) do
        local at = W.at(run, c.netId)
        if at and math.abs(at.x - x) < 0.01 then return c, at end
    end
    return nil
end

-- ============================================================================
--                                  1. PARKED
-- ============================================================================
-- EACH CAR WHEN AN OFFICER IS NEAR IT, NOT ON TOP OF IT.

do
    Reset()
    warns, lines = {}, {}
    Place(1, 5000.0, 5000.0)
    local run = W.start({ 1 }, Parked(4, nil, 4))
    Secs(3)
    H.eq(#W.cars(run, 1), 0, 'nobody within 150 m of the street: no parked car yet')
    H.eq(#WarnsWith('waited'), 0, 'and nothing waits (no warning)')
    local check = impl.checklist(CP.Runs.ctx(run, 1))[1]
    H.eq(check.max, 4, 'the checklist counts the four cars the sweep will have')
    -- 20 m from the first spot: it waits; the second (63 m) appears; the far ones (241 m, 441 m) do not yet
    Place(1, 1060.0, 980.0)
    Secs(1)
    H.ok(CarAt(run, 1060.0) == nil, 'the car 20 m from the officer does not pop in beside him')
    H.ok(CarAt(run, 1120.0) ~= nil, 'the car 63 m ahead appears')
    H.ok(CarAt(run, 1300.0) == nil and CarAt(run, 1500.0) == nil, 'the cars 241 m and 441 m away not yet')
    H.eq(#LinesWith('spots[1] waits: an officer is 20 m from it, it appears beyond 35 m'), 1,
        'the console says once why spots[1] waits')
    Secs(5)
    H.eq(#LinesWith('spots[1] waits'), 1, 'once, not every second')
    -- he steps back: 70 m from it, it appears
    Place(1, 1060.0, 930.0)
    Secs(1)
    local a, at = CarAt(run, 1060.0)
    H.ok(a ~= nil and D2(at, Me(1)) > 35.0, 'stepped back to 70 m: the first car appears')
    -- 25 m from the third: it waits for waveDelayMax (20 s), then hardMin (20 m) lets it in, with one warning
    Place(1, 1300.0, 1025.0)
    Secs(19)
    H.ok(CarAt(run, 1300.0) == nil, 'an officer 25 m away for 19 s: the third car still waits')
    Secs(2)
    local c3, at3 = CarAt(run, 1300.0)
    H.ok(c3 ~= nil, 'after waveDelayMax the third appears 25 m away (hardMin 20 m)')
    H.ok(at3 and D2(at3, Me(1)) >= 20.0, 'never under hardMin')
    H.eq(#WarnsWith('spots[3] waited'), 1, 'one warning: it appeared closer than 35 m')
    -- 10 m from the fourth: under hardMin it waits until sceneWaitMax (45 s), then appears anyway, with a warning
    Place(1, 1500.0, 1010.0)
    Secs(44)
    H.ok(CarAt(run, 1500.0) == nil, 'an officer 10 m away for 44 s: the fourth car still waits')
    Secs(2)
    H.ok(CarAt(run, 1500.0) ~= nil, 'after sceneWaitMax it appears anyway (the sweep never stalls)')
    local w = WarnsWith('Config.Spawning.sceneWaitMax')
    H.eq(#w, 1, 'with one warning')
    H.ok(
        w[1] and W.contains(w[1].text, 'cus_mission') and W.contains(w[1].text, 'Alta Street')
            and W.contains(w[1].text, 'spots[4]'),
        'naming the mission, the place and the point: ' .. tostring(w[1] and w[1].text)
    )
    H.eq(#W.cars(run, 1), 4, 'four cars in all')
    EndRun(run)
end

-- ============================================================================
--                                   2. SCENE
-- ============================================================================
-- THE WHOLE SCENE WHILE THE OFFICERS ARE STILL OUT.

do
    -- an officer 20 m from the scene (inside approach + sceneOutside = 35 m): nothing yet
    Reset()
    warns, lines = {}, {}
    Place(1, 2000.0, 1980.0)
    local run = W.start({ 1 }, SceneMission())
    Secs(5)
    H.eq(#W.people(run, 1) + #W.cars(run, 1), 0, 'an officer 20 m away: the scene does not pop in in front of him')
    H.eq(#LinesWith('the scene waits: an officer is 19 m from it'), 1, 'the console says why (the nearest point)')
    -- at 60 m: the car and both people appear at once
    Place(1, 2000.0, 1940.0)
    Secs(1)
    H.eq(#W.cars(run, 1), 1, 'an officer 60 m away: the car is there')
    H.eq(#W.people(run, 1), 2, 'and both people, the whole scene at once')
    H.eq(St(run).approached, nil, 'nobody reacts yet (the officer is outside the 25 m approach)')
    -- he walks up: they react at 25 m as before
    Place(1, 2000.0, 1985.0)
    Secs(2)
    H.eq(St(run).approached, true, 'within 25 m the people react')
    EndRun(run)
end

do
    -- sceneWaitMax = 0: an officer who stays on top of the scene keeps it waiting; nobody near starts no clock
    Reset()
    cfg.sceneWaitMax = 0
    warns = {}
    Place(1, 5000.0, 5000.0)
    local run = W.start({ 1 }, SceneMission())
    Secs(60)
    H.eq(#W.people(run, 1), 0, 'nobody within 150 m: no scene')
    Place(1, 2000.0, 1995.0)
    Secs(70)
    H.eq(#W.people(run, 1), 0, 'sceneWaitMax 0: an officer 5 m away keeps it waiting for ever')
    H.eq(#WarnsWith('sceneWaitMax'), 0, 'without a warning')
    Place(1, 2000.0, 1940.0)
    Secs(1)
    H.eq(#W.people(run, 1), 2, 'he steps back: it appears')
    EndRun(run)
end

do
    -- the director off: the scene appears at once, 20 m from the officer, as before
    Reset()
    cfg.enabled = false
    Place(1, 2000.0, 1980.0)
    local run = W.start({ 1 }, SceneMission())
    Secs(1)
    H.eq(#W.people(run, 1), 2, 'Config.Spawning.enabled = false: the scene appears at once, as before')
    EndRun(run)
end

-- ============================================================================
--                           3. THE RETURNING DRIVER
-- ============================================================================
-- FROM THE OFFICER'S GAME, WALKS UP ONCE PLACED.

do
    Reset()
    warns, lines, asks, huds = {}, {}, {}, {}
    Place(1, 1000.0, 950.0)
    Place(2, 1000.0, 960.0)
    local run = W.start({ 1, 2 }, Parked(1, { returning = { chance = 1, max = 1 } }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    H.ok(car ~= nil, 'the car is there (78 m from the officers)')
    -- officer 2 stands 30 m north of the car; the game of officer 1 (at the car) answers four points
    Place(2, 1060.0, 1030.0)
    Answer = function()
        return {
            { x = 1068.0, y = 1000.0, z = 31.0, hidden = true },   -- 8 m from the car: inside the ring
            { x = 1060.0, y = 1033.0, z = 31.0, hidden = true },   -- 3 m from officer 2
            { x = 1090.0, y = 1000.0, z = 31.4, hidden = true },   -- 30 m east, out of sight
            { x = 1060.0, y = 965.0, z = 31.2, hidden = false },   -- 35 m south
            { x = 1200.0, y = 1000.0, z = 31.0, hidden = false },  -- 140 m: outside the ring
        },
            300
    end
    W.near(1, run, car.netId, 1.5)
    W.decide(1, run, car.netId, 'cite')
    H.eq(#asks, 1, 'citing the car asks the game of the officer who cited it for a point')
    local ask = asks[1]
    H.eq(ask and ask.src, 1, 'officer 1 (who cited)')
    H.ok(
        ask and ask.args.car and math.abs(ask.args.car.x - carAt.x) < 0.01 and math.abs(ask.args.car.y - carAt.y) < 0.01,
        'with the car\'s position')
    H.ok(ask and ask.args.ring[1] == 25.0 and ask.args.ring[2] == 40.0, 'the ring 25-40 m (contactRing)')
    H.eq(ask and ask.args.ms, 1250, 'and the time his game may probe (losTimeoutMs less the way back)')
    H.eq(Person(run, 'returning_driver'), nil, 'nobody appears before his game has answered')
    H.eq(St(run).walkIns, 1, 'one on his way')
    Secs(1)
    H.eq(run.objectives[1].status, 'active', 'every car decided, but the objective waits for him')
    local drv = Person(run, 'returning_driver')
    H.ok(drv ~= nil, 'the driver appears once the answer is in')
    local dAt = drv and W.at(run, drv.netId)
    H.ok(dAt and math.abs(dAt.x - 1090.0) < 0.01 and math.abs(dAt.y - 1000.0) < 0.01 and math.abs(dAt.z - 31.4) < 0.01,
        'on the first usable point: 30 m east, out of sight, at his game\'s height')
    H.ok(dAt and D2(dAt, carAt) >= 25.0 and D2(dAt, Me(1)) >= 25.0 and D2(dAt, Me(2)) >= 25.0,
        '25 m or more from the car and from both officers')
    H.ok(math.abs((W.model(run, drv.netId).heading or 0) - 90.0) < 0.5, 'facing the car')
    H.eq(St(run).walkIns, 0, 'nobody on the way any more')
    H.ok(#LinesWith('returning_driver appears 30 m from the car (his game)') == 1, 'the console says where from')
    -- he waits frozen for his placement: no walk yet, nothing said yet
    Secs(2)
    H.eq(#Acts('walk_to', drv.netId), 0, 'no walk while he waits for an officer\'s game to put him on the ground')
    H.eq(HudsWith('returning_'), 0, 'and nothing said about him yet')
    Placed(1, run, drv.netId)
    Secs(1)
    local walks = Acts('walk_to', drv.netId)
    H.eq(#walks, 1, 'placed: he walks up to the car')
    H.eq(walks[1] and walks[1].args[1].args.veh, car.netId, 'to his car')
    H.eq(walks[1] and walks[1].target, run.host, 'the host\'s game walks him')
    local rd = St(run).contacts[drv.netId].returning
    rd.outcome = 'takes'
    Secs(10)
    H.eq(rd.done, nil, 'still walking (30 m): the ticket is not taken from afar')
    H.eq(HudsWith('returning_'), 0, 'and not announced before he is there')
    -- the host's game walked him to the car
    SetEntityCoords(run.entities[drv.netId].entity, carAt.x + 2.0, carAt.y, carAt.z)
    Secs(1)
    H.eq(HudsWith('returning_takes'), 1, 'at the car he says he takes the ticket')
    Secs(3)
    H.eq(rd.done, true, 'and takes it')
    Secs(1)
    H.eq(run.objectives[1].status, 'done', 'resolved: the objective completes')
    EndRun(run)
end

do
    -- he would argue, but an officer meets him on his walk and explains the citation: at the car he takes the ticket
    Reset()
    asks, huds = {}, {}
    Place(1, 1000.0, 950.0)
    local run = W.start({ 1 }, Parked(1, { returning = { chance = 1, max = 1 } }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    Answer = function() return { { x = 1090.0, y = 1000.0, z = 31.0, hidden = true } }, 200 end
    W.near(1, run, car.netId, 1.5)
    W.decide(1, run, car.netId, 'cite')
    Secs(1)
    local drv = Person(run, 'returning_driver')
    H.ok(drv ~= nil, 'calmed: the driver appears')
    local rd = drv and St(run).contacts[drv.netId].returning
    if rd then rd.outcome = 'argues' end
    if drv then drv.arguing = true end
    Placed(1, run, drv.netId)
    Secs(1)
    H.eq(#Acts('walk_to', drv.netId), 1, 'calmed: he walks up to the car')
    W.near(1, run, drv.netId, 1.5)
    W.act(1, run, drv.netId, 'explain')
    H.eq(drv.arguing, false, 'calmed: Explain the citation on his walk')
    SetEntityCoords(run.entities[drv.netId].entity, carAt.x + 2.0, carAt.y, carAt.z)
    Secs(1)
    H.eq(HudsWith('returning_argues'), 0, 'calmed: at the car he is not announced as arguing')
    H.eq(HudsWith('returning_takes'), 1, 'calmed: he says he takes the ticket')
    Secs(3)
    H.eq(rd and rd.done, true, 'calmed: and takes it')
    EndRun(run)
end

do
    -- his game gives no answer in time (losTimeoutMs 1500): round the car, 25-40 m from it, never near an officer
    Reset()
    warns, lines, asks = {}, {}, {}
    Place(1, 1000.0, 950.0)
    Place(2, 1000.0, 960.0)
    local run = W.start({ 1, 2 }, Parked(1, { returning = { chance = 1, max = 1 } }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    Place(2, 1060.0, 1030.0)
    Answer = function()
        return { { x = 1090.0, y = 1000.0, z = 31.0 } }, 3000
    end
    W.near(1, run, car.netId, 1.5)
    W.decide(1, run, car.netId, 'cite')
    Secs(1)
    H.eq(Person(run, 'returning_driver'), nil, 'nobody while his game still has time')
    Secs(1)
    local drv = Person(run, 'returning_driver')
    H.ok(drv ~= nil, 'no answer within 1.5 s: he appears anyway')
    local dAt = drv and W.at(run, drv.netId)
    local d = dAt and D2(dAt, carAt) or 0
    H.ok(d >= 25.0 - 1e-6 and d <= 40.0 + 1e-6, ('round the car, 25-40 m from it (%.1f m)'):format(d))
    H.ok(dAt and D2(dAt, Me(1)) >= 25.0 and D2(dAt, Me(2)) >= 25.0,
        ('never closer than 25 m to an officer (%.1f m, %.1f m)'):format(dAt and D2(dAt, Me(1)) or 0,
            dAt and D2(dAt, Me(2)) or 0))
    H.ok(math.abs((dAt and dAt.z or 0) - carAt.z) < 0.01, 'at the car\'s height (the placer puts him on the ground)')
    H.eq(#LinesWith('(round the car)'), 1, 'the console says it was the ring')
    Secs(3)
    H.eq(W.count(W.people(run, 1), function(p) return p.role == 'returning_driver' end), 1,
        'the late answer adds nobody')
    -- the placement times out (nobody answered it): he is let go and walks
    Secs(8)
    H.eq(#Acts('walk_to', drv.netId), 1, 'once his placement is over he walks up to the car')
    EndRun(run)
end

do
    -- every point of the answer is unusable (in the ring's middle, on an officer, nonsense): the ring
    Reset()
    lines, asks = {}, {}
    Place(1, 1000.0, 950.0)
    local run = W.start({ 1 }, Parked(1, { returning = { chance = 1, max = 1 } }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    Answer = function()
        return { { x = 1061.0, y = 1000.0, z = 31.0 }, { x = 'a' }, 'no', { x = 1090.0, y = 1000.0, z = 90.0 } }, 100
    end
    W.near(1, run, car.netId, 1.5)
    W.decide(1, run, car.netId, 'cite')
    Secs(1)
    local drv = Person(run, 'returning_driver')
    local dAt = drv and W.at(run, drv.netId)
    H.ok(dAt and D2(dAt, carAt) >= 25.0 - 1e-6 and D2(dAt, Me(1)) >= 25.0, 'an unusable answer: the ring instead')
    H.ok(dAt and math.abs(dAt.z - 90.0) > 1.0, 'never a point 60 m over the car')
    EndRun(run)
end

-- ============================================================================
--           4. THE THIEF: FROM OUT OF SIGHT, WALKS IN, RUNS AT 15 M
-- ============================================================================

do
    Reset()
    lines, asks = {}, {}
    Place(1, 1000.0, 950.0)
    local run = W.start({ 1 }, Parked(1, {
        profileSet = 'test_stolen',
        thief = { chance = 1, runAt = 15.0 },
        escapeFails = false,
        custody = 'cuff',
    }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    Answer = function() return { { x = 1060.0, y = 1035.0, z = 31.0, hidden = true } }, 200 end
    W.near(1, run, car.netId, 1.5)
    W.act(1, run, car.netId, 'inspect')
    Secs(1)
    H.eq(#asks, 1, 'the first inspect of a stolen car asks the inspecting officer\'s game')
    local th = Person(run, 'thief')
    local tAt = th and W.at(run, th.netId)
    H.ok(tAt and math.abs(tAt.y - 1035.0) < 0.01, 'the thief appears on his game\'s point')
    H.ok(tAt and D2(tAt, carAt) >= 25.0 and D2(tAt, Me(1)) >= 25.0, '35 m from the car, out of sight')
    Placed(1, run, th.netId)
    Secs(1)
    H.eq(#Acts('walk_to', th.netId), 1, 'placed: he walks back to the car he stole')
    H.eq(#Acts('flee_on_approach', th.netId), 0, 'not running yet')
    -- the host walked him on: 12 m from the officer he sees him and runs
    SetEntityCoords(run.entities[th.netId].entity, carAt.x, carAt.y + 12.0, carAt.z)
    Secs(1)
    H.eq(#Acts('flee_on_approach', th.netId), 1, 'within 15 m of the officer he runs')
    EndRun(run)
end

do
    -- the thief is out while two parked cars still wait for an officer: the HUD and the checklist count them all
    Reset()
    asks = {}
    Place(1, 1060.0, 930.0)
    local run = W.start({ 1 }, Parked(4, {
        profileSet = 'test_stolen',
        thief = { chance = 1 },
        escapeFails = false,
        custody = 'cuff',
    }, 4))
    Secs(1)
    H.eq(#W.cars(run, 1), 2, 'count: the two cars near the officer are there, the far two not yet')
    local car = CarAt(run, 1060.0)
    Answer = function() return { { x = 1060.0, y = 1035.0, z = 31.0, hidden = true } }, 200 end
    W.near(1, run, car.netId, 1.5)
    W.act(1, run, car.netId, 'inspect')
    Secs(1)
    H.ok(Person(run, 'thief') ~= nil, 'count: the thief is out')
    H.eq(#W.cars(run, 1), 2, 'count: still two cars')
    local function Max() return run.objectives[1].hud and run.objectives[1].hud.max end
    H.eq(impl.checklist(CP.Runs.ctx(run, 1))[1].max, 5, 'count: the checklist counts 4 cars and the thief')
    H.eq(Max(), 5, 'count: the HUD counts 4 cars and the thief')
    -- the officer drives on: the last two cars appear, and the count does not jump
    Place(1, 1400.0, 900.0)
    Secs(1)
    H.eq(#W.cars(run, 1), 4, 'count: the last two cars appear')
    H.eq(Max(), 5, 'count: the HUD still counts 5')
    H.eq(impl.checklist(CP.Runs.ctx(run, 1))[1].max, 5, 'count: the checklist still counts 5')
    EndRun(run)
end

-- ============================================================================
--             5. THE DIRECTOR OFF: 14 M / 30 M AT ONCE, AS BEFORE
-- ============================================================================

do
    Reset()
    cfg.enabled = false
    asks, huds = {}, {}
    Place(1, 1000.0, 950.0)
    local run = W.start({ 1 }, Parked(1, { returning = { chance = 1, max = 1 } }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    W.near(1, run, car.netId, 1.5)
    W.decide(1, run, car.netId, 'cite')
    local drv = Person(run, 'returning_driver')
    H.ok(drv ~= nil, 'off: the driver appears at once')
    H.eq(#asks, 0, 'without asking a game')
    local dAt = drv and W.at(run, drv.netId)
    H.ok(dAt and math.abs(D2(dAt, carAt) - 14.0) < 0.01, '14 m from the car, as before')
    H.eq(#Acts('walk_to', drv.netId), 1, 'and walks up at once')
    H.ok(HudsWith('returning_') == 1, 'what he does is said at once')
    EndRun(run)
end

do
    Reset()
    cfg.enabled = false
    asks = {}
    Place(1, 1000.0, 950.0)
    local run = W.start({ 1 }, Parked(1, { profileSet = 'test_stolen', thief = { chance = 1 }, custody = 'cuff' }, 1))
    Secs(1)
    local car, carAt = CarAt(run, 1060.0)
    W.near(1, run, car.netId, 1.5)
    W.act(1, run, car.netId, 'inspect')
    local th = Person(run, 'thief')
    H.ok(th and math.abs(D2(W.at(run, th.netId), carAt) - 30.0) < 0.01, 'off: the thief waits 30 m from the car')
    H.eq(#asks, 0, 'no game asked')
    EndRun(run)
end

Reset()
Answer = nil
lib.callback.await = roadAwait
CP.Runs.hud = realHud
CP.warn = realWarn
_G.print = realPrint
return H
