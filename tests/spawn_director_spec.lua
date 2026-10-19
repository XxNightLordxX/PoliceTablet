-- The spawn director (Config.Spawning; modules/runs/server.lua Runs.choosePoints, Runs.whenNear, ctx.choosePoints,
-- ctx.whenNear) on a real test run of the engine, officers placed through the harness's ped coords.

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

H.eq(cfg.enabled, true, 'the director ships on')
H.eq(cfg.activateRange, 150.0, 'people appear once an officer is within 150 m')
H.eq(cfg.minDistance, 40.0, 'never closer than 40 m to an officer')
H.eq(cfg.minDistanceIndoor, 15.0, '15 m inside a building')
H.eq(cfg.behindAngle, 110.0, 'more than 110 degrees off an officer\'s line to the scene is behind him')
H.eq(cfg.maxSpread, 150.0, 'one wave fits in a 150 degree slice')
H.eq(cfg.waveDelayMax, 20, 'a wave waits 20 s for far points')
H.eq(cfg.hardMin, 20.0, 'then never closer than 20 m')
H.eq(cfg.log, true, 'console lines on')

-- ============================================================================
--                        A TEST RUN WITH THREE OFFICERS
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    lines[#lines + 1] = table.concat(parts, ' ')
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end
local function WarnsWith(text)
    local out = {}
    for _, e in ipairs(CP.Problems.list({ tag = 'runs', level = 'warn' })) do
        if e.text:find(text, 1, true) then out[#out + 1] = e end
    end
    return out
end

local ctxOf = {}
CP.Blocks.register('director_probe', {
    start = function(ctx) ctxOf[ctx.index] = ctx end,
    tick = function() end,
})

local CENTRE = vec3(0.0, 120.0, 30.0)   -- the middle of the scene, 120 m north of the start
local mission = {
    id = 'director_probe_mission',
    label = 'Director probe',
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
    objectives = { { block = 'director_probe', label = 'One' }, { block = 'director_probe', label = 'Two' } },
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
H.ok(type(Runs.choosePoints) == 'function' and type(Runs.whenNear) == 'function', 'Runs.choosePoints, Runs.whenNear')

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
H.ok(type(run) == 'table', 'a test run')
Runs.markArrived(run, 1)
H.eq(run.state, 'in_progress', 'the run is in progress')
local ctx = ctxOf[1]
H.ok(ctx ~= nil, 'objective 1 started with its ctx')
H.ok(type(ctx.choosePoints) == 'function' and type(ctx.whenNear) == 'function',
    'ctx.choosePoints and ctx.whenNear are there')

-- Alice and Bob at the front of the yard, Cara far away
Place(1, 0, 60)
Place(2, -20, 50)
Place(3, 5000, 5000)

local function P(x, y) return vec4(x + 0.0, y + 0.0, 30.0, 180.0) end
local function Idx(list) return table.concat(list, ',') end

-- ============================================================================
--                  DISTANCE AND "BEHIND" (ONE OFFICER CLOSE)
-- ============================================================================

do
    local A = P(0, 90)     -- 30 m in front of Alice
    local B = P(0, 105)    -- 45 m in front of her, 58 m from Bob
    local C = P(0, 10)     -- 50 m straight behind Alice (45 m from Bob)
    local D = P(60, 60)    -- 60 m to her right
    local E = P(50, 30)    -- 58 m from Alice, 121 degrees off her line to the scene: behind her (90 off Bob's)
    local spawns = { A, B, C, D, E }
    local pts, idx = ctx.choosePoints(spawns, 9, { name = 'spawns', centre = CENTRE })
    H.eq(Idx(idx), '2,4', 'asked for 9: the 45 m point and the one to the side; 30 m and behind are skipped')
    H.ok(pts[1] == B and pts[2] == D, 'the chosen points are the candidates themselves, in list order')
    H.eq(#LinesWith('spawns[1] skipped: 30 m from Alice Able'), 1, 'one line for the 30 m point')
    H.eq(#LinesWith('spawns[3] skipped: behind Alice Able'), 1, 'one line for the point behind her')
    H.eq(#LinesWith('spawns[5] skipped: behind Alice Able'), 1, '121 degrees off her line to the scene is behind too')
    H.eq(#LinesWith('run ' .. run.id .. ': spawns[1]'), 1, 'the line names the run')
    local n = #lines
    ctx.choosePoints(spawns, 9, { name = 'spawns', centre = CENTRE })
    H.eq(#lines, n, 'asked again: no new lines (a waiting wave asks every second)')
    -- Runs.choosePoints is the same director
    local _, idx2 = Runs.choosePoints(run, spawns, 9, { name = 'spawns', centre = CENTRE })
    H.eq(Idx(idx2), '2,4', 'Runs.choosePoints answers the same')
    -- n smaller than what passes: the first n in list order
    local _, one = ctx.choosePoints(spawns, 1, { centre = CENTRE })
    H.eq(Idx(one), '2', 'asked for 1: the first good point')
    H.eq(#ctx.choosePoints(spawns, 0, { centre = CENTRE }), 0, 'asked for 0: none')
    -- exactly at minDistance is kept, just under it is not
    local _, edge = ctx.choosePoints({ P(0, 100), P(0, 99.5) }, 2, { centre = CENTRE })
    H.eq(Idx(edge), '1', '40 m kept, 39.5 m skipped')
    -- the distance is measured on the map: a point 30 m in front of Alice and 40 m above her is still 30 m away
    local _, high = ctx.choosePoints({ vec3(0.0, 90.0, 70.0) }, 1, { centre = CENTRE })
    H.eq(#high, 0, 'height does not count')
    -- the officers' coords come from the server's ped: Alice moves forward, the 45 m point is now 15 m away
    Place(1, 0, 90)
    local _, moved = ctx.choosePoints({ B }, 1, { centre = CENTRE })
    H.eq(#moved, 0, 'Alice walked up to it: skipped')
    Place(1, 0, 60)
end

-- ============================================================================
--                                   INDOORS
-- ============================================================================

do
    local P16 = P(0, 76)   -- 16 m in front of Alice
    local P14 = P(0, 74)
    H.eq(#ctx.choosePoints({ P16 }, 1, { centre = CENTRE }), 0, 'outdoors 16 m is too close')
    local pts = ctx.choosePoints({ P16, P14 }, 2, { indoor = true, centre = CENTRE })
    H.ok(#pts == 1 and pts[1] == P16, 'indoor: 16 m kept, 14 m skipped')
    local inside = { coords = vec3(0.0, 76.0, 30.0), indoor = true }
    local pts2 = ctx.choosePoints({ inside, P16 }, 2, { centre = CENTRE })
    H.ok(#pts2 == 1 and pts2[1] == inside, 'a point { coords, indoor = true } uses the indoor distance on its own')
    local plain = { x = 0.0, y = 105.0, z = 30.0 }
    local pts3 = ctx.choosePoints({ plain, { 0.0, 106.0, 30.0 } }, 2, { centre = CENTRE })
    H.eq(#pts3, 2, 'plain { x, y, z } and { 1, 2, 3 } points work')
    local _, bad = ctx.choosePoints({ { label = 'x' }, 'spawns', P(0, 105) }, 3, { name = 'odd', centre = CENTRE })
    H.eq(Idx(bad), '3', 'entries that are no point are skipped')
    H.eq(#LinesWith('odd[1] skipped: not a point'), 1, 'and said once')
end

-- ============================================================================
--          "BEHIND" IS SEEN FROM EACH OFFICER'S OWN LINE TO THE SCENE
-- ============================================================================

do
    -- Cara beyond the yard at (0, 400), looking back at the scene: a point at her back counts only within 150 m
    Place(3, 0, 400)
    local _, idx = ctx.choosePoints({ P(0, 560) }, 1, { name = 'far', centre = CENTRE })
    H.eq(Idx(idx), '1', 'a point 160 m behind an officer does not count (further than activateRange)')
    Place(3, 0, 420)
    local _, idx1 = ctx.choosePoints({ P(0, 560) }, 1, { name = 'far2', centre = CENTRE })
    H.eq(#idx1, 0, 'the same point 140 m behind her does')
    H.eq(#LinesWith('far2[1] skipped: behind Cara Cole'), 1, 'said with her name')

    -- Cara came round the far side to (0, 160) and looks at the scene: B, between her and the scene, is in front of
    -- her (and of Alice); a point 55 m at her back is behind her
    Place(3, 0, 160)
    local _, idx2 = ctx.choosePoints({ P(0, 105), P(0, 215) }, 2, { name = 'back', centre = CENTRE })
    H.eq(Idx(idx2), '1', 'Cara came round the far side: B in front of her is kept, the point at her back is not')
    H.eq(#LinesWith('back[2] skipped: behind Cara Cole'), 1, 'the point at her back is said with her name')
    H.eq(#LinesWith('back[1] skipped'), 0, 'B is never "behind" her')

    -- a lone officer who came in from the far side (no one at the start): the scene's points, never the ones at
    -- his back
    Place(1, 5000, 5000)
    Place(2, 5000, 5000)
    Place(3, 0, 170)
    local _, idx3 = ctx.choosePoints({ P(-40, 120), P(40, 120), P(0, 220), P(30, 215) }, 4,
        { name = 'lone', centre = CENTRE })
    H.eq(Idx(idx3), '1,2', 'alone from the far side: the two scene points, not the two at his back')
    H.eq(#LinesWith('lone[3] skipped: behind Cara Cole'), 1, 'straight behind him')
    H.eq(#LinesWith('lone[4] skipped: behind Cara Cole'), 1, '146 degrees off his line to the scene')

    -- Terminal-shaped (Gang Shootout 'Container yard, Terminal': every spawn point is south of the start, so the way
    -- in points south): an officer who drives in from the south, past all of them, still gets the yard's points and
    -- never the ones south of him
    local MID = vec3(0.0, -60.0, 30.0)
    local yard = { P(-20, -30), P(0, -50), P(20, -70), P(10, -90), P(0, -210), P(25, -205) }
    Place(3, 0, -160)
    local _, idx4 = ctx.choosePoints(yard, 6, { name = 'terminal', centre = MID })
    H.eq(Idx(idx4), '1,2,3,4', 'in from the south: the four yard points north of him')
    H.eq(#LinesWith('terminal[5] skipped: behind Cara Cole'), 1, 'the point south of him is behind him')
    H.eq(#LinesWith('terminal[6] skipped: behind Cara Cole'), 1, 'and the other one')
    local _, idx5 = ctx.choosePoints({ yard[1], yard[2], yard[3], yard[4] }, 4, { name = 'terminal2' })
    H.eq(Idx(idx5), '1,2,3,4', 'the yard\'s own list, no centre given (the middle of the points): every point')

    -- an officer in the middle of the scene (closer than 5 m) has no line of his own: he faces the way in, from the
    -- start towards the middle
    Place(1, 0, 60)
    Place(2, -20, 50)
    Place(3, 0, 118)
    local _, idx6 = ctx.choosePoints({ P(0, 170) }, 1, { name = 'mid', centre = CENTRE })
    H.eq(Idx(idx6), '1', 'Cara in the middle faces the way in: the point 52 m ahead of her is kept')
    -- opts.from moves the start: she came in from the far side, so the same point is at her back
    local _, idx7 = ctx.choosePoints({ P(0, 170) }, 1,
        { name = 'mid2', from = vec3(0.0, 300.0, 30.0), centre = CENTRE })
    H.eq(#idx7, 0, 'opts.from: in the middle she faces the other way, the point is behind her')
    H.eq(#LinesWith('mid2[1] skipped: behind Cara Cole'), 1, 'said with her name')

    Place(3, 5000, 5000)
    cfg.behindAngle = 180.0
    local _, idx8 = ctx.choosePoints({ P(0, 10), P(50, 30) }, 2, { centre = CENTRE, name = 'off' })
    H.eq(Idx(idx8), '1,2', 'behindAngle 180: nothing is behind')
    Reset()
    -- no centre given: the officers face the middle of the candidates (here north of Alice and Bob)
    local _, idx9 = ctx.choosePoints({ P(-30, 150), P(30, 150), P(0, 10) }, 3, {})
    H.eq(Idx(idx9), '1,2', 'the default centre: the middle of the candidates')
end

-- ============================================================================
--                   ONE SECTOR PER WAVE (NO RING, NO PINCER)
-- ============================================================================

do
    -- seen from between Alice and Bob (-10, 55): east 0, north 90 and west 180 degrees
    local East, North, West = P(60, 55), P(-10, 125), P(-80, 55)
    local pts, idx = ctx.choosePoints({ East, North, West }, 3, { name = 'ring', centre = CENTRE })
    H.eq(Idx(idx), '1,2', 'east and west do not fit in one 150 degree slice: the slice with the first point')
    H.ok(pts[1] == East and pts[2] == North, 'east and north')
    H.eq(#LinesWith('ring[3] skipped: outside this wave\'s 150 degree sector'), 1, 'the west point is said')
    local _, idx2 = ctx.choosePoints({ West, North, East }, 3, { centre = CENTRE })
    H.eq(Idx(idx2), '1,2', 'the block\'s order decides between two slices that hold as many')
    -- the points the wave already used stay in its slice
    local _, idx3 = ctx.choosePoints({ East, North }, 2, { centre = CENTRE, placed = { vec3(-80.0, 50.0, 30.0) } })
    H.eq(Idx(idx3), '2', 'a wave that started in the west gets the north point, never the east one (no pincer)')
    cfg.maxSpread = 360.0
    local _, idx4 = ctx.choosePoints({ East, North, West }, 3, { centre = CENTRE })
    H.eq(Idx(idx4), '1,2,3', 'maxSpread 360: no slice')
    Reset()
    -- enough points inside the slice: no line for the ones outside it
    local n = #lines
    ctx.choosePoints({ East, North, West }, 2, { name = 'quiet', centre = CENTRE })
    H.eq(#lines, n, 'a point outside the slice is only said when the wave is short of points')
end

-- ============================================================================
--                    ASK 9 FROM 4 GOOD: 4, NEVER A BAD ONE
-- ============================================================================

do
    local list = { P(0, 90), P(0, 105), P(0, 10), P(60, 60), P(-60, 100), P(30, 130) }
    local _, idx = ctx.choosePoints(list, 9, { centre = CENTRE })
    H.eq(Idx(idx), '2,4,5,6', 'four good points of six: four come back')
end

-- ============================================================================
--                A WAVE THAT WAITS: AFTER waveDelayMax, hardMin
-- ============================================================================

do
    local P25 = P(0, 85)   -- 25 m in front of Alice (40 m from Bob)
    local P15 = P(0, 75)   -- 15 m in front of her
    local t0 = H.time
    local _, a = ctx.choosePoints({ P25, P15 }, 2, { name = 'wave', wave = 'w1', centre = CENTRE })
    H.eq(#a, 0, 'at first neither: both closer than 40 m')
    H.time = t0 + 19
    local _, b = ctx.choosePoints({ P25, P15 }, 2, { name = 'wave', wave = 'w1', centre = CENTRE })
    H.eq(#b, 0, 'after 19 s still neither')
    H.eq(#WarnsWith('waited'), 0, 'no warning yet')
    H.time = t0 + 20
    local _, c = ctx.choosePoints({ P25, P15 }, 2, { name = 'wave', wave = 'w1', centre = CENTRE })
    H.eq(Idx(c), '1', 'after waveDelayMax the 25 m point is allowed, the 15 m one not')
    local w = WarnsWith(
        'wave waited 20 s for points 40 m from the officers; used 1 closer one(s), the nearest 25 m away')
    H.eq(#w, 1, 'one warning when the wave had to use a closer point')
    H.ok(w[1] and w[1].text:find('(director_probe_mission)', 1, true) ~= nil, 'it names the mission')
    H.time = t0 + 600
    local _, d = ctx.choosePoints({ P25, P15 }, 2, { name = 'wave', wave = 'w1', centre = CENTRE })
    H.eq(Idx(d), '1', 'the 15 m point never, however long the wave waits')
    H.eq(#WarnsWith('wave waited'), 1, 'still one warning for the wave')
    -- indoor points keep their own 15 m: hardMin never makes a distance bigger
    local _, e = ctx.choosePoints({ P(0, 74), P15 }, 2, { wave = 'w1', indoor = true, centre = CENTRE })
    H.eq(Idx(e), '2', 'indoor after the wait: 15 m kept, 14 m skipped')
    -- a call that got every point it asked for stops the clock: the next ask starts again
    H.time = t0
    H.eq(#ctx.choosePoints({ P25 }, 1, { wave = 'w2', centre = CENTRE }), 0, 'wave 2 waits')
    H.time = t0 + 20
    H.eq(#ctx.choosePoints({ P25 }, 1, { wave = 'w2', centre = CENTRE }), 1, 'wave 2 is full after 20 s')
    H.time = t0 + 21
    H.eq(#ctx.choosePoints({ P25 }, 1, { wave = 'w2', centre = CENTRE }), 0, 'asked again: a fresh clock')
    -- no wave name: no clock, never relaxed; opts.since sets the clock
    H.eq(#ctx.choosePoints({ P25 }, 1, { centre = CENTRE }), 0, 'no wave, no wait: 25 m skipped')
    H.eq(#ctx.choosePoints({ P25 }, 1, { since = H.time - 30, centre = CENTRE }), 1, 'opts.since 30 s ago: relaxed')
    H.eq(#ctx.choosePoints({ P25 }, 1, { since = H.time - 10, centre = CENTRE }), 0, 'opts.since 10 s ago: not yet')
    -- each objective has its own clocks: objective 2's wave w1 starts now
    local ctx2 = Runs.ctx(run, 2)
    H.eq(#ctx2.choosePoints({ P25, P15 }, 2, { wave = 'w1', centre = CENTRE }), 0, 'objective 2\'s w1 is a new wave')
    H.eq(#ctx.choosePoints({ P25, P15 }, 2, { wave = 'w1', centre = CENTRE }), 1, 'objective 1\'s w1 still relaxed')
    local opts = { wave = 'w9' }
    ctx.choosePoints({ P25 }, 1, opts)
    H.eq(opts.obj, nil, 'ctx.choosePoints does not write into the block\'s opts')
    -- a test restart starts the objective again: its clocks too
    H.ok(Runs.testRestart(run), 'Restart objective (test control)')
    H.eq(ctxOf[1], ctx, 'the same ctx')
    H.eq(#ctx.choosePoints({ P25, P15 }, 2, { wave = 'w1', centre = CENTRE }), 0, 'after a restart w1 waits again')
    H.time = t0
end

-- ============================================================================
--                                Runs.whenNear
-- ============================================================================

do
    local near, d = ctx.whenNear(vec3(0.0, 200.0, 30.0))
    H.eq(near, true, 'Alice is 140 m from the point: near (activateRange 150)')
    H.near(d, 140.0, 1e-6, 'the nearest distance')
    local far, d2 = ctx.whenNear(vec3(0.0, 215.0, 30.0))
    H.eq(far, false, '155 m: not yet')
    H.near(d2, 155.0, 1e-6, 'the nearest distance when not near')
    H.eq((ctx.whenNear(vec3(0.0, 215.0, 30.0), 160)), true, 'a range of its own')
    H.eq((ctx.whenNear(vec3(0.0, 60.0, 130.0), 1)), true, 'on the map: 100 m above her is 0 m away')
    H.eq((ctx.whenNear(vec4(0.0, 210.0, 30.0, 90.0))), true, 'a vector4 point')
    H.eq((Runs.whenNear(run, nil)), true, 'no point: nothing to wait for')
    cfg.activateRange = 100.0
    H.eq((ctx.whenNear(vec3(0.0, 200.0, 30.0))), false, 'activateRange is read live')
    Reset()
end

-- ============================================================================
--                        ONLY ACTIVE PARTICIPANTS COUNT
-- ============================================================================

do
    Place(3, 0, 100)   -- Cara right on top of the point
    H.eq(#ctx.choosePoints({ P(0, 105) }, 1, { centre = CENTRE }), 0, 'Cara is 5 m away: skipped')
    Runs.removeParticipant(run, 3, 'quit')
    H.eq(run.participants[3].status, 'left', 'Cara left the run')
    H.eq(#ctx.choosePoints({ P(0, 105) }, 1, { centre = CENTRE }), 1, 'an officer who left does not count')
    H.eq((ctx.whenNear(vec3(0.0, 100.0, 30.0), 10)), false, 'nor for whenNear')
end

-- ============================================================================
--                     SWITCHED OFF: AS BEFORE THE DIRECTOR
-- ============================================================================

do
    local A, B = P(0, 90), P(0, 10)
    cfg.enabled = false
    local pts, idx = ctx.choosePoints({ A, B, P(0, 105) }, 2, { centre = CENTRE })
    H.eq(Idx(idx), '1,2', 'enabled = false: the first n unchanged (30 m and behind included)')
    H.ok(pts[1] == A and pts[2] == B, 'the same values')
    H.eq(#ctx.choosePoints({ A }, 5), 1, 'never more than there are')
    H.eq((ctx.whenNear(vec3(5000.0, 5000.0, 30.0))), true, 'whenNear is always true: people appear as before')
    Reset()
    -- log = false: no line, no warning
    cfg.log = false
    local w = #CP.Problems.list({ tag = 'runs', level = 'warn' })
    ctx.choosePoints({ P(0, 91) }, 1, { name = 'silent', since = H.time - 60, centre = CENTRE })
    ctx.choosePoints({ P(0, 89), P(0, 70) }, 2, { name = 'silent', since = H.time - 60, centre = CENTRE })
    H.eq(#LinesWith('silent['), 0, 'log = false: no console line')
    H.eq(#CP.Problems.list({ tag = 'runs', level = 'warn' }), w, 'and no warning')
    Reset()
end

-- ============================================================================
--                               THE RUN GOES ON
-- ============================================================================

H.eq(run.state, 'in_progress', 'nothing above ended the run')
H.ok(type(run.spawning) == 'table' and type(run.spawning[1]) == 'table' and type(run.spawning[2]) == 'table',
    'the director keeps its clocks on the run, per objective')

_G.print = realPrint
return H
