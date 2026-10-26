-- Manhunt through the spawn director (Config.Spawning, PLAN S16) on the real engine, the real search_area block and the

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

for _, b in ipairs({
    'checkpoint_route',
    'interact_points',
    'skill_check',
    'hostile_waves',
    'protect_rescue',
    'flee_arrest',
    'pursuit',
    'escort',
    'search_area',
}) do
    H.load('blocks/' .. b .. '/server.lua')
end
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/server.lua')
local Missions = CP.Missions
local summary = Missions.loadAll()
CP.warn = realWarn
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end
H.eq(cfg.enabled, true, 'shipped: the spawn director is on')
H.eq(cfg.activateRange, 150.0, 'shipped: people appear once an officer is within 150 m')
H.eq(cfg.minDistance, 40.0, 'shipped: never closer than 40 m to an officer')
H.eq(cfg.waveDelayMax, 20, 'shipped: 20 s before a closer point may be used')
H.eq(cfg.hardMin, 20.0, 'shipped: never closer than 20 m after that')

-- ============================================================================
--                    CONSOLE, WARNINGS, THE OFFICERS' GAMES
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    -- the harness's own failure lines still reach the runner
    if line:find('^  FAIL ') then realPrint(line) end
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end

-- lib.callback.await, as ox_lib's server side: sees(src, args) answers the line-of-sight ask (nil = no answer, as a
-- game that does not answer in time); every other ask goes to the world's own fake (the custody road point).
local VISIBLE = 'crimson-police:client:spawn:visible'
local worldAwait = lib.callback.await
local sees, asks = nil, {}
lib.callback.await = function(name, src, args)
    if name ~= VISIBLE then return worldAwait(name, src, args) end
    asks[#asks + 1] = { src = src, n = #args.points, points = args.points }
    if sees then return sees(src, args) end
    return nil
end
local function Hidden(_, args)
    local out = {}
    for k = 1, #args.points do out[k] = false end
    return out
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- ============================================================================
--                                   THE HUNT
-- ============================================================================

local def = Missions.get('manhunt')
local loc = def.locations[1]
H.eq(loc.label, 'Sandy Shores', 'location 1 is Sandy Shores')
H.eq(def.objectives[1].block, 'search_area', 'objective 1 is the search')
local C = loc.center

-- Every fugitive and clue made, with the nearest officer's distance when it appeared (the officers stand still
-- while the clock runs one second at a time).
local born = {}
local function Nearest(c)
    local best = math.huge
    for _, src in ipairs({ 1, 2 }) do
        local p = H.players[src] and H.players[src].coords
        if p then best = math.min(best, D2(c, p)) end
    end
    return best
end
local function Record(run)
    for netId, e in pairs(run.entities) do
        if (e.role == 'fugitive' or e.role == 'clue' or e.role == 'witness') and not born[netId] then
            local m = W.ent(e.entity)
            born[netId] = { role = e.role, at = m and m.coords, nearest = m and Nearest(m.coords) or -1 }
        end
    end
end
local function Secs(run, n)
    for _ = 1, n do
        W.tick(1)
        Record(run)
    end
end

-- The officers wait at the west edge of the 600 m circle when the search starts. after = an objective that follows
-- the search (Manhunt has none).
local function Hunt(srcs, location, tier, after)
    for _, src in ipairs(srcs) do W.place(src, C.x - 590.0, C.y, C.z) end
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { location or loc }
    if after then m.objectives = { def.objectives[1], after } end
    local run = W.start(srcs, m, { test = { adminSrc = srcs[1], forcedTier = tier or 'standard' } })
    Record(run)
    return run
end
local function St(run) return run.objectives[1].state end
local function Made(run, role)
    local out = {}
    for _, e in pairs(run.entities) do if e.role == role then out[#out + 1] = e end end
    return out
end
local function Fugitives(run) return Made(run, 'fugitive') end
local function NetOf(run, e)
    for n, x in pairs(run.entities) do if x == e then return n end end
    return nil
end
local function Clues(run) return #Made(run, 'clue') + #Made(run, 'witness') end
local function EndRun(run)
    if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end
    W.tick(1)
end
-- Fugitive 1's own hiding spot (the circle shrinks towards it from the start).
local function OwnSpot(run, location)
    local st = St(run)
    local idx = st.order[1]
    return (location or loc).hiding[idx], idx
end

-- A spot dist metres from target, further than keep metres from every point of avoid (nil when none is).
local function Around(target, dist, avoid, keep)
    for deg = 0, 345, 15 do
        local a = math.rad(deg)
        local p = vec3(target.x + math.cos(a) * dist, target.y + math.sin(a) * dist, target.z)
        local ok = true
        for _, q in ipairs(avoid or {}) do
            if D2(p, q) <= keep then
                ok = false
                break
            end
        end
        if ok then return p end
    end
    return nil
end
local function Place(src, p) W.place(src, p.x, p.y, p.z) end

-- Every point of the hunt but the ones given.
local function Others(run, but)
    local out = {}
    for _, cl in ipairs(St(run).clues) do
        if cl ~= but then out[#out + 1] = cl.coords end
    end
    local own = OwnSpot(run)
    if own ~= but then out[#out + 1] = own end
    return out
end

do -- the officer at the edge of the 600 m circle: nothing; a clue at 140 m; the fugitive only from 40 m out
    born = {}
    local run = Hunt({ 1 })
    H.eq(run.state, 'in_progress', 'the hunt is on')
    local st = St(run)
    H.eq(#st.clues, 3, 'three clues are picked from the start')
    H.eq(#Fugitives(run), 0, 'no fugitive when the search starts')
    H.eq(Clues(run), 0, 'no clue when the search starts')
    Secs(run, 3)
    H.eq(#Fugitives(run) + Clues(run), 0, 'nothing while nobody is near any of them')

    -- 140 m from clue 1, more than 150 m from everything else
    local cl = st.clues[1]
    local p = Around(cl.coords, 140.0, Others(run, cl), 155.0)
    H.ok(p ~= nil, 'a spot 140 m from clue 1 away from the rest')
    Place(1, p)
    Secs(run, 1)
    H.ok(cl.netId ~= nil, 'an officer 140 m from clue 1: it appears')
    H.eq(Clues(run), 1, 'only that one')
    H.eq(#Fugitives(run), 0, 'the fugitive still waits')
    H.near(born[cl.netId] and born[cl.netId].nearest or -1, 140.0, 0.01, 'it appeared 140 m from him')
    H.ok(D2(W.ent(run.entities[cl.netId].entity).coords, cl.coords) < 0.01, 'on its own spot')

    -- straight to 30 m from the fugitive's hiding spot (he never passed 40-150 m): the fugitive waits
    local own, idx = OwnSpot(run)
    local q = Around(own, 30.0, {}, 0)
    Place(1, q)
    Secs(run, 3)
    H.eq(#Fugitives(run), 0, 'an officer 30 m from the hiding spot: no fugitive pops up next to him')
    H.eq(#LinesWith(('hiding[%d] skipped: 30 m from Officer 1'):format(idx)), 1, 'the console says why, once')
    -- he steps back to 100 m: the fugitive is there, on his own spot
    Place(1, Around(own, 100.0, {}, 0))
    Secs(run, 1)
    local f = Fugitives(run)[1]
    H.ok(f ~= nil, 'the officer 100 m from the hiding spot: the fugitive appears')
    H.ok(f and D2(W.ent(f.entity).coords, own) < 0.01, 'on his own hiding spot')
    local fNet = f and NetOf(run, f)
    H.near(fNet and born[fNet] and born[fNet].nearest or -1, 100.0, 0.01, 'he appeared 100 m from the officer')
    H.eq(fNet and CP.Npc.getState(fNet), 'idle', 'hiding (idle)')

    -- a clue that appeared stays when the officers drive away
    Place(1, vec3(C.x + 3000.0, C.y, C.z))
    Secs(run, 3)
    H.ok(run.entities[cl.netId] and W.ent(run.entities[cl.netId].entity).exists, 'the clue stays when he drives off')
    EndRun(run)
end

-- Every fugitive and clue made in this spec so far and below: the rules held for each.
local function CheckBorn(label)
    local bad = {}
    for netId, b in pairs(born) do
        if b.role == 'fugitive' and b.nearest < 40.0 then
            bad[#bad + 1] = ('fugitive %s %.1f m'):format(netId, b.nearest)
        end
        if b.nearest > 150.0 + 1e-6 then bad[#bad + 1] = ('%s %s %.1f m away'):format(b.role, netId, b.nearest) end
    end
    H.eq(#bad, 0, label .. ' (' .. table.concat(bad, '; ') .. ')')
end
CheckBorn('every fugitive appeared 40-150 m from the officer, every clue within 150 m')

-- ============================================================================
--                    A CLUE CLOSER THAN 40 M: OUT OF SIGHT
-- ============================================================================

do
    born = {}
    local run = Hunt({ 1 })
    local st = St(run)
    local cl = st.clues[1]
    Place(1, Around(cl.coords, 25.0, {}, 0))
    asks = {}
    Secs(run, 3)
    H.ok(cl.netId == nil, 'an officer 25 m from clue 1 whose game does not answer: it waits (it might be seen)')
    H.ok(#asks >= 1 and asks[1].src == 1 and asks[1].n == 1, 'his game was asked whether it sees that one point')
    H.eq(#LinesWith(('%s skipped: 25 m from Officer 1 and not known to be out of his sight'):format(cl.name)), 1,
        'the console says why, once')
    -- his game says the spot is hidden (behind a wall): the clue appears, 25 m from him
    sees = Hidden
    Secs(run, 2)
    H.ok(cl.netId ~= nil, 'out of his sight: the clue appears 25 m from him')
    sees = nil
    EndRun(run)

    -- seen: after waveDelayMax (20 s) hardMin (20 m) is enough; at 10 m it waits for good
    run = Hunt({ 1 })
    st = St(run)
    local c1, c2 = st.clues[1], st.clues[2]
    Place(1, Around(c1.coords, 25.0, { c2.coords }, 45.0))
    Secs(run, 18)
    H.ok(c1.netId == nil, 'in sight 25 m away: nothing for 18 s')
    Secs(run, 3)
    H.ok(c1.netId ~= nil, 'after waveDelayMax: it appears 25 m away (hardMin 20 m)')
    Place(1, Around(c2.coords, 10.0, {}, 0))
    Secs(run, 30)
    H.ok(c2.netId == nil, 'in sight 10 m away: never, also after 30 s')
    sees = Hidden
    Secs(run, 2)
    H.ok(c2.netId ~= nil, 'once his game says it is hidden: it appears')
    sees = nil
    H.eq(#LinesWith('clue 1 waited 2'), 1, 'clue 1 came closer after waiting: one warning')
    H.eq(#LinesWith('clue 2 waited'), 0, 'clue 2 did not come closer: it was out of sight')
    EndRun(run)

    -- preferHidden = false: no game is asked, the clue waits for him to step back
    cfg.preferHidden = false
    run = Hunt({ 1 })
    st = St(run)
    cl = st.clues[1]
    Place(1, Around(cl.coords, 25.0, {}, 0))
    asks = {}
    sees = Hidden
    Secs(run, 3)
    H.eq(#asks, 0, 'preferHidden = false: no game is asked')
    H.ok(cl.netId == nil, 'and the clue waits')
    Place(1, Around(cl.coords, 60.0, {}, 0))
    Secs(run, 1)
    H.ok(cl.netId ~= nil, 'he steps back to 60 m: it appears')
    sees = nil
    Reset()
    EndRun(run)

    -- the search ends while the director waits for his game's answer: the clue is never made for the next objective
    run = Hunt({ 1 }, nil, nil, { block = 'stub_hold', label = 'After', minSeconds = 0 })
    st = St(run)
    cl = st.clues[1]
    Place(1, Around(cl.coords, 25.0, {}, 0))
    local skipped = false
    sees = function(src, args)
        if not skipped then
            skipped = true
            CP.Runs.testSkip(run)
        end
        return Hidden(src, args)
    end
    Secs(run, 3)
    sees = nil
    H.ok(skipped, 'late clue: his game was asked whether it sees the clue')
    H.ok(st.halted == true and run.state == 'in_progress' and run.objectiveIndex == 2,
        'late clue: the search ended while his game answered, the run goes on')
    H.eq(cl.netId, nil, 'late clue: no clue is made for the search that is over')
    H.eq(Clues(run), 0, 'late clue: none in the world during the next objective')
    EndRun(run)
end

-- ============================================================================
--               THE FUGITIVE: ANOTHER HIDING SPOT, NEVER CLOSER
-- ============================================================================

do
    -- two hiding spots 80 m apart: the officer 30 m from the fugitive's own one, on the far side from the other
    born = {}
    local two = {}
    for k, v in pairs(loc) do two[k] = v end
    local A = vec4(C.x + 100.0, C.y, C.z, 90.0)
    local B = vec4(C.x + 180.0, C.y, C.z, 90.0)
    two.hiding = { A, B }
    local run = Hunt({ 1 }, two)
    local own, idx = OwnSpot(run, two)
    local other = idx == 1 and B or A
    local side = own.x < other.x and -1 or 1
    W.place(1, own.x + side * 30.0, own.y, own.z)
    Secs(run, 10)
    H.eq(#Fugitives(run), 0, 'the officer 30 m from his spot: no fugitive for 10 s')
    Secs(run, 12)
    local f = Fugitives(run)[1]
    H.ok(f ~= nil, 'after waveDelayMax the fugitive hides on the other free spot instead')
    H.ok(f and D2(W.ent(f.entity).coords, other) < 0.01, 'on the other spot, 110 m from the officer')
    H.eq(#LinesWith(('fugitive 1 hides on hiding[%d] instead of hiding[%d]'):format(idx == 1 and 2 or 1, idx)), 1,
        'the console says so')
    EndRun(run)

    -- the officer between both spots, 25 m from each: nobody appears, however long he stays (no hardMin for him)
    local close = {}
    for k, v in pairs(loc) do close[k] = v end
    close.hiding = { vec4(C.x + 100.0, C.y, C.z, 90.0), vec4(C.x + 150.0, C.y, C.z, 90.0) }
    run = Hunt({ 1 }, close)
    W.place(1, C.x + 125.0, C.y, C.z)
    Secs(run, 60)
    H.eq(#Fugitives(run), 0, 'an officer 25 m from both spots: no fugitive after 60 s')
    W.place(1, C.x + 125.0, C.y + 100.0, C.z)
    Secs(run, 1)
    H.eq(#Fugitives(run), 1, 'he walks 100 m off: the fugitive appears')
    EndRun(run)

    -- the heavy tier (two fugitives) with two officers: each on his own spot, each only once an officer is near
    run = Hunt({ 1, 2 }, nil, 'heavy')
    H.eq(#Fugitives(run), 0, 'heavy: nobody when the search starts')
    local st = St(run)
    local s1, s2 = loc.hiding[st.order[1]], loc.hiding[st.order[2]]
    Place(1, Around(s1, 120.0, { s2 }, 160.0))
    Secs(run, 1)
    H.eq(#Fugitives(run), 1, 'heavy: an officer near the first spot: one fugitive')
    Place(2, Around(s2, 120.0, { s1 }, 160.0))
    Secs(run, 1)
    H.eq(#Fugitives(run), 2, 'heavy: the second officer near the second spot: the second fugitive')
    EndRun(run)
end
CheckBorn('every fugitive 40 m or more from both officers, every clue and fugitive within 150 m of one')

-- ============================================================================
--                   THE CIRCLE SHRINKS TOWARDS A HIDING SPOT
-- ============================================================================

do
    local run = Hunt({ 1 })
    local st = St(run)
    local own = OwnSpot(run)
    local cl = st.clues[1]
    local p = Around(cl.coords, 100.0, { own }, 155.0)
    H.ok(p ~= nil, 'a spot 100 m from clue 1, more than 150 m from the hiding spot')
    Place(1, p)
    Secs(run, 1)
    H.ok(cl.netId ~= nil, 'clue 1 is there')
    -- he checks it (more than 150 m from the hiding spot): the circle shrinks to 300 m round the fugitive's own
    -- spot, although the fugitive has not appeared yet
    H.ok(D2(cl.coords, own) > 151.0, 'clue 1 lies more than 150 m from the hiding spot')
    W.place(1, cl.coords.x + 1.0, cl.coords.y, cl.coords.z)
    H.fire('crimson-police:server:objective', 1, run.id, 1, { type = 'clue_start', clue = 1 })
    W.tick(5)
    H.fire('crimson-police:server:objective', 1, run.id, 1, { type = 'clue', clue = 1 })
    W.tick(1)
    H.eq(#Fugitives(run), 0, 'the fugitive still waits')
    H.eq(cl.status, 'done', 'clue 1 checked')
    H.eq(st.circle.radius, 300, 'the circle shrank to 300 m')
    H.ok(D2(st.circle.center, own) <= 300 * 0.7 + 1e-6, 'round the hiding spot of the fugitive still waiting')
    EndRun(run)
end

-- ============================================================================
--                   ENABLED = FALSE: AS BEFORE, AT THE START
-- ============================================================================

do
    cfg.enabled = false
    local run = Hunt({ 1 })
    H.eq(#Fugitives(run), 1, 'enabled = false: the fugitive when the search starts, as before')
    H.eq(Clues(run), 3, 'enabled = false: all three clues too')
    local own = OwnSpot(run)
    H.ok(D2(W.ent(Fugitives(run)[1].entity).coords, own) < 0.01, 'on his own spot')
    Reset()
    EndRun(run)
end

_G.print = realPrint
lib.callback.await = worldAwait

return H
