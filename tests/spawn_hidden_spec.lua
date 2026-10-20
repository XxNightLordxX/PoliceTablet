-- Hidden points first (Config.Spawning.preferHidden, losTimeoutMs; PLAN S5): the spawn director asks the officers'
-- games which of the points that pass its rules they can see (ox_lib callback crimson-police:client:spawn:visible)
-- and uses the hidden ones first, on a real test run of the engine.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local cfg = Config.Spawning
local DEFAULTS = CP.U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end

-- ============================================================================
--                         THE SHIPPED VALUES (README)
-- ============================================================================

H.eq(cfg.preferHidden, true, 'hidden points first ships on')
H.eq(cfg.losTimeoutMs, 1500, 'the server waits 1.5 s for the officers\' games')

-- ============================================================================
--                        A TEST RUN WITH THREE OFFICERS
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

local ctxOf = {}
CP.Blocks.register('hidden_probe', {
    start = function(ctx) ctxOf[ctx.index] = ctx end,
    tick = function() end,
})

local CENTRE = vec3(0.0, 120.0, 30.0)
local mission = {
    id = 'hidden_probe_mission',
    label = 'Hidden probe',
    description = 'A test.',
    type = 'tactical',
    departments = {},
    minOfficers = 1,
    maxOfficers = 4,
    difficulty = 1,
    timeLimit = 600,
    startTimeout = 600,
    cooldown = 0,
    locations = {
        { label = 'Probe yard', start = { coords = vec3(0.0, 0.0, 30.0), radius = 50.0 }, scene = CENTRE },
    },
    objectives = { { block = 'hidden_probe', label = 'One' }, { block = 'hidden_probe', label = 'Two' } },
    scaling = {},
    items = {},
    bonuses = {},
    penalties = {},
    source = 'builtin',
}

local function Place(src, x, y, z) H.players[src].coords = vec3(x + 0.0, y + 0.0, (z or 30.0) + 0.0) end
for src = 1, 3 do H.players[src] = { coords = vec3(0.0, 0.0, 30.0) } end
H.load('modules/runs/server.lua')
local Runs = CP.Runs
H.step(0)

local run = Runs.create({
    mission = mission,
    locationIndex = 1,
    members = {
        { src = 1, citizenid = 'CIT1', name = 'Alice Able', department = 'sast', job = 'sast' },
        { src = 2, citizenid = 'CIT2', name = 'Bob Baker', department = 'sast', job = 'sast' },
        { src = 3, citizenid = 'CIT3', name = 'Cara Cole', department = 'sast', job = 'sast' },
    },
    leaderSrc = 1,
    test = { adminSrc = 1 },
})
Runs.markArrived(run, 1)
H.eq(run.state, 'in_progress', 'the run is in progress')
local ctx = ctxOf[1]

-- Alice and Bob at the front of the yard, Cara far away
local function Home()
    Place(1, 0, 60)
    Place(2, -20, 50)
    Place(3, 5000, 5000)
end
Home()

local function P(x, y) return vec4(x + 0.0, y + 0.0, 30.0, 180.0) end
local function Idx(list) return table.concat(list, ',') end
-- four points in front of Alice and Bob, 54-85 m from them, all on one side: every one passes the rules
local A1, A2, A3, A4 = P(-20, 110), P(0, 115), P(20, 110), P(10, 130)
local YARD = { A1, A2, A3, A4 }

-- ============================================================================
--                             THE OFFICERS' GAMES
-- ============================================================================
-- lib.callback.await, as ox_lib's server side.
-- game[src] = function(args) -> the answer (one boolean per point: true = seen); delay[src] = ms before it answers.

local CALLBACK = 'crimson-police:client:spawn:visible'
local game, delay, asks = {}, {}, {}
lib.callback.await = function(name, src, args)
    asks[#asks + 1] = { name = name, src = src, args = args, at = H.clockMs }
    if delay[src] then Wait(delay[src]) end
    local fn = game[src]
    if not fn then return nil end
    return fn(args)
end
local function Sees(list) return function() return list end end
local function AskedSrcs(from)
    local out = {}
    for i = (from or 0) + 1, #asks do out[#out + 1] = tostring(asks[i].src) end
    table.sort(out)
    return table.concat(out, ',')
end

-- ctx.choosePoints in a thread (as a block's tick or start calls it), the fake clock running until it returns.
local function Pick(candidates, n, opts)
    local res, done = nil, false
    local t0 = H.clockMs
    CreateThread(function()
        res = table.pack(ctx.choosePoints(candidates, n, opts))
        done = true
    end)
    while not done and H.clockMs - t0 < 20000 do H.step(10) end
    H.ok(done, 'the pick returned')
    return res and res[1] or {}, res and res[2] or {}, H.clockMs - t0
end

-- ============================================================================
--                             HIDDEN POINTS FIRST
-- ============================================================================

do
    -- Alice's game sees A1 and A3; Bob's sees all but A4: only A4 is hidden from both
    game[1] = Sees({ true, false, true, false })
    game[2] = Sees({ true, true, true, false })
    local from = #asks
    local pts, idx, took = Pick(YARD, 2, { name = 'yard', centre = CENTRE })
    H.eq(Idx(idx), '4,1', 'the point neither officer can see first, then the block\'s order')
    H.ok(pts[1] == A4 and pts[2] == A1, 'the candidates themselves')
    H.eq(AskedSrcs(from), '1,2', 'Alice and Bob were asked (near the scene); Cara, 5 km away, was not')
    local a = asks[from + 1]
    H.eq(a.name, CALLBACK, 'the callback name')
    H.eq(#a.args.points, 4, 'the four points that pass the rules are sent')
    H.ok(a.args.points[2].x == 0.0 and a.args.points[2].y == 115.0 and a.args.points[2].z == 30.0,
        'each as { x, y, z }')
    H.eq(a.args.ms, 1250, 'the game may probe for losTimeoutMs less 250 ms for the way back')
    H.ok(took < 200, 'answered at once: no wait (' .. took .. ' ms)')
    H.eq(#LinesWith('yard: 1 of 4 points out of the officers\' sight, used first'), 1, 'one console line')
    -- hidden from both: A2 and A4; within the hidden ones and the seen ones the block's order stays
    game[1] = Sees({ true, false, false, false })
    game[2] = Sees({ true, false, true, false })
    local _, idx2 = Pick(YARD, 3, { name = 'yard2', centre = CENTRE })
    H.eq(Idx(idx2), '2,4,1', 'two hidden points (in list order), then the first seen one')
    -- a point one game sees is seen: hidden needs every asked game to say so
    game[1] = Sees({ false, false, false, false })
    game[2] = Sees({ true, true, true, true })
    local _, idx3 = Pick(YARD, 2, { name = 'yard3', centre = CENTRE })
    H.eq(Idx(idx3), '1,2', 'Bob sees every point: the block\'s order')
    -- anything but false counts as seen: a missing entry, 0, a string, no table at all
    game[1] = Sees({ 0, nil, 'false', false })
    game[2] = Sees({ false, false, false, false })
    local _, idx4 = Pick(YARD, 2, { name = 'yard4', centre = CENTRE })
    H.eq(Idx(idx4), '4,1', 'only an answer of exactly false hides a point')
    game[1] = function() return 'all hidden' end
    local _, idx5 = Pick(YARD, 2, { name = 'yard5', centre = CENTRE })
    H.eq(Idx(idx5), '1,2', 'an answer that is no table: every point seen')
    H.eq(#LinesWith('yard5: no usable answer from Alice Able within 1500 ms, every point counts as seen'), 1,
        'said in the console')
end

-- ============================================================================
--               ONLY WHEN IT CAN MATTER, ONLY WHERE IT CAN WAIT
-- ============================================================================

do
    game[1] = Sees({ false, false, false, false })
    game[2] = Sees({ false, false, false, false })
    local from = #asks
    -- as many good points as asked for: every one is used anyway, nobody is asked
    local _, idx = Pick(YARD, 4, { name = 'all', centre = CENTRE })
    H.eq(Idx(idx), '1,2,3,4', 'asked for all four: list order')
    H.eq(#asks, from, 'nobody asked when every good point is used')
    -- outside a thread (a call that cannot wait): no ask, the block's order
    local _, idx2 = ctx.choosePoints(YARD, 2, { name = 'main', centre = CENTRE })
    H.eq(Idx(idx2), '1,2', 'not in a thread: list order')
    H.eq(#asks, from, 'and nobody asked')
    -- preferHidden = false (read live): the mission's own order
    cfg.preferHidden = false
    local _, idx3 = Pick(YARD, 2, { name = 'off', centre = CENTRE })
    H.eq(Idx(idx3), '1,2', 'preferHidden = false: list order')
    H.eq(#asks, from, 'and nobody asked')
    Reset()
    -- the director switched off: as before
    cfg.enabled = false
    local _, idx4 = Pick(YARD, 2, { name = 'disabled', centre = CENTRE })
    H.eq(Idx(idx4), '1,2', 'enabled = false: the first n')
    H.eq(#asks, from, 'and nobody asked')
    Reset()
end

-- ============================================================================
--           NO ANSWER IN TIME: EVERY POINT SEEN, DISTANCE RULES KEPT
-- ============================================================================

do
    game[1] = Sees({ false, false, false, false })
    game[2] = Sees({ false, false, false, false })
    delay[2] = 3000   -- Bob's game answers after 3 s
    local from = #asks
    local _, idx, took = Pick({ P(0, 90), A1, A2, A3, A4 }, 2, { name = 'slow', centre = CENTRE })
    H.eq(Idx(idx), '2,3', 'no answer from Bob in time: list order (the 30 m point still skipped)')
    H.ok(took >= 1500 and took < 1700, 'the director waited losTimeoutMs, no longer (' .. took .. ' ms)')
    H.eq(#LinesWith('slow: no usable answer from Bob Baker within 1500 ms, every point counts as seen'), 1,
        'the console names the game that did not answer')
    H.eq(AskedSrcs(from), '1,2', 'both were asked')
    -- Bob's ask is still out: his game is not asked again meanwhile, and the pick does not wait
    local from2 = #asks
    local _, idx2, took2 = Pick(YARD, 2, { name = 'busy', centre = CENTRE })
    H.eq(Idx(idx2), '1,2', 'a game still busy with an earlier ask: list order')
    H.eq(#asks, from2, 'nobody asked while Bob\'s answer is out')
    H.ok(took2 < 100, 'and no wait (' .. took2 .. ' ms)')
    -- his late answer comes in; then he is asked again
    H.advance(2000, 10)
    delay[2] = nil
    local _, idx3 = Pick(YARD, 2, { name = 'back', centre = CENTRE })
    H.eq(Idx(idx3), '1,2', 'every point hidden from both: the block\'s order within the hidden ones')
    H.eq(AskedSrcs(from2), '1,2', 'Bob is asked again once his late answer came back')
    -- losTimeoutMs is read live
    cfg.losTimeoutMs = 300
    delay[1] = 1000
    local _, _, took4 = Pick(YARD, 2, { name = 'short', centre = CENTRE })
    H.ok(took4 >= 300 and took4 < 450, 'losTimeoutMs 300: waits 300 ms (' .. took4 .. ' ms)')
    H.advance(1000, 10)
    delay[1] = nil
    Reset()
    -- a callback that fails (ox_lib raises: the player is gone, no such callback) is no answer
    game[2] = function() error('callback \'' .. CALLBACK .. '\' does not exist') end
    local _, idx5 = Pick(YARD, 2, { name = 'broken', centre = CENTRE })
    H.eq(Idx(idx5), '1,2', 'a failed callback: list order')
    H.eq(#LinesWith('broken: no usable answer from Bob Baker'), 1, 'said in the console')
    -- no answer in time and Alice walks up to (0, 80) meanwhile: the rules run again all the same, so A1, A2 and A3
    -- (35-36 m from her now) are skipped and only A4 (51 m) is left
    game[1] = function()
        Place(1, 0, 80)
        return { true, false, true, true }
    end
    game[2] = Sees({ false, false, false, false })
    delay[2] = 3000
    local _, idx6, took6 = Pick(YARD, 2, { name = 'walkup', centre = CENTRE })
    H.eq(Idx(idx6), '4', 'no answer in time: the points she walked up to are still skipped')
    H.ok(took6 >= 1500 and took6 < 1700, 'after waiting losTimeoutMs (' .. took6 .. ' ms)')
    H.eq(#LinesWith('walkup: no usable answer from Bob Baker within 1500 ms'), 1, 'Bob named in the console')
    H.eq(#LinesWith('walkup[2] skipped: 35 m from Alice Able'), 1, 'said like any skipped point')
    H.advance(2000, 10)
    delay[2] = nil
    Home()
end

-- ============================================================================
--                      THE RULES RUN AGAIN AFTER THE WAIT
-- ============================================================================
-- THE OFFICERS KEPT MOVING.

do
    -- Alice's game says A2 is hidden, but she walks up to (0, 80) while it probes: A1, A2 and A3 are now 35-36 m
    -- from her, only A4 (51 m) still passes
    game[1] = function()
        Place(1, 0, 80)
        return { true, false, true, true }
    end
    game[2] = Sees({ false, false, false, false })
    local _, idx = Pick(YARD, 2, { name = 'moved', centre = CENTRE })
    H.eq(Idx(idx), '4', 'the hidden point she walked up to is skipped: only the 51 m point is left')
    H.eq(#LinesWith('moved[2] skipped: 35 m from Alice Able'), 1, 'said like any skipped point')
    Home()
end

-- ============================================================================
--                  WHO IS ASKED: THE OFFICERS NEAR THE SCENE
-- ============================================================================

do
    game[1] = Sees({ true, true, true, false })
    game[2] = Sees({ true, true, true, false })
    game[3] = Sees({ true, true, true, true })
    -- Cara within activateRange of the scene too: all three are asked, and she sees A4
    Place(3, 60, 150)
    local from = #asks
    local _, idx = Pick(YARD, 2, { name = 'three', centre = CENTRE })
    H.eq(AskedSrcs(from), '1,2,3', 'all three within 150 m of the scene are asked')
    H.eq(Idx(idx), '1,2', 'Cara sees A4: no point is hidden')
    -- nobody near the scene: only the nearest officer is asked
    Place(1, 0, -200)
    Place(2, 0, -400)
    Place(3, 5000, 5000)
    local from2 = #asks
    local _, idx2 = Pick(YARD, 2, { name = 'farAway', centre = CENTRE })
    H.eq(AskedSrcs(from2), '1', 'nobody within 150 m: the nearest officer (Alice, 320 m) only')
    H.eq(idx2[1], 4, 'her answer orders the points: the one she cannot see first')
    Home()
end

-- ============================================================================
--           ONE SIDE PER WAVE: THE SIDE WITH THE MOST HIDDEN POINTS
-- ============================================================================

do
    -- two points west and two east of Alice and Bob: one 150 degree slice cannot hold both sides. West is listed
    -- first, but only one west point is hidden and both east ones are: the wave comes from the east, out of sight
    local W1, W2, E1, E2 = P(-80, 55), P(-80, 70), P(60, 55), P(60, 70)
    game[1] = Sees({ false, true, false, false })
    game[2] = Sees({ false, true, false, false })
    local _, idx = Pick({ W1, W2, E1, E2 }, 2, { name = 'sides', centre = CENTRE })
    H.eq(Idx(idx), '3,4', 'the side with two hidden points, not the listed first side with one')
    -- every point seen: the block's order decides the side, as before
    game[1] = Sees({ true, true, true, true })
    local _, idx2 = Pick({ W1, W2, E1, E2 }, 2, { name = 'sides2', centre = CENTRE })
    H.eq(Idx(idx2), '1,2', 'nothing hidden: the first listed side')
end

-- ============================================================================
--                  A POINT THE BLOCK MARKS FIRST STAYS AHEAD
-- ============================================================================

do
    -- the boss's own spot (first = true) is seen, the fight's points A3 hidden: his spot stays first, then the
    -- hidden fight point, then the rest
    game[1] = Sees({ true, true, false })
    game[2] = Sees({ true, true, false })
    local own = { coords = A1, label = 'boss[1]', first = true }
    local _, idx = Pick({ own, { coords = A2 }, { coords = A3 } }, 1, { name = 'boss', centre = CENTRE })
    H.eq(Idx(idx), '1', 'the boss\'s own spot, although the officers see it')
    local _, idx2 = Pick({ own, { coords = A2 }, { coords = A3 } }, 2, { name = 'boss2', centre = CENTRE })
    H.eq(Idx(idx2), '1,3', 'then the hidden fight point before the seen one')
    -- two own spots: the hidden one first
    game[1] = Sees({ true, false, false })
    game[2] = Sees({ true, false, false })
    local own2 = { coords = A2, label = 'boss[2]', first = true }
    local _, idx3 = Pick({ own, own2, { coords = A3 } }, 1, { name = 'boss3', centre = CENTRE })
    H.eq(Idx(idx3), '2', 'of his own spots the hidden one')
end

-- ============================================================================
--                               THE RUN GOES ON
-- ============================================================================

H.eq(run.state, 'in_progress', 'nothing above ended the run')

_G.print = realPrint
return H
