-- hostile_waves through the spawn director (Config.Spawning, PLAN S2) on the real engine, the real block and the
-- built-in mission files: wave 1 once an officer is near, every wave away from the officers, the rest waits.

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
local HW = CP.Blocks.get('hostile_waves')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end
H.eq(cfg.leaveOutAfter, 45, 'a wave short of points with nobody left to fight leaves the rest out after 45 s')

-- ============================================================================
--                          CONSOLE, WARNINGS, SPAWNS
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

-- every ped the engine creates, with the nearest officer (2D) at that moment
local officers = {}
local spawns = {}
local realCreatePed = CreatePed
_G.CreatePed = function(t, model, x, y, z, h, ...)
    local near, who = math.huge, nil
    for _, src in ipairs(officers) do
        local c = H.players[src].coords
        local d = math.sqrt((c.x - x) ^ 2 + (c.y - y) ^ 2)
        if d < near then near, who = d, src end
    end
    local handle = realCreatePed(t, model, x, y, z, h, ...)
    spawns[#spawns + 1] = { handle = handle, x = x, y = y, z = z, near = near, who = who }
    return handle
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function Secs(n) W.tick(n) end
local function Place(src, x, y, z) W.place(src, x, y, z) end

-- A run of mission id at its location li with only the fight (objective 1, with obj's changes), then an objective
-- that holds the run open; the officers stand where the spec put them when it starts.
local function Fight(id, li, srcs, opts)
    opts = opts or {}
    local def = Missions.get(id)
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { opts.location or def.locations[li] }
    local obj = U.deepcopy(def.objectives[opts.index or 1])
    for k, v in pairs(opts.obj or {}) do obj[k] = v end
    m.objectives = { obj, { block = 'stub_hold', label = 'Hold' } }
    officers = srcs
    spawns = {}
    local run = W.start(srcs, m,
        { test = { adminSrc = srcs[1], forcedTier = opts.tier or 'standard' }, seed = opts.seed })
    return run, CP.Runs.ctx(run, 1)
end
local function SpawnedSince(from)
    local out = {}
    for i = (from or 0) + 1, #spawns do out[#out + 1] = spawns[i] end
    return out
end
local function Nearest(list)
    local m = math.huge
    for _, s in ipairs(list) do if s.near < m then m = s.near end end
    return m
end
-- Kill every hostile of objective 1 still standing (the officer's ped is the killer).
local function KillAll(run, killer)
    for _, e in ipairs(CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })) do
        local m = W.ent(e.entity)
        if m and m.exists and (m.health or 0) > 0 then
            m.killer = (killer or 1) * 100
            m.health = 0
        end
    end
    Secs(2)
end
local function Alive(run) return #CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true }) end
local function Done(run) return run.objectives[1].status == 'done' end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end

-- ============================================================================
--                    GANG SHOOTOUT, CONTAINER YARD TERMINAL
-- ============================================================================
-- IN FROM THE FAR SIDE (a1 4.1).
-- The audit's case: every spawn point is south of the start, so an officer who comes in from the south crosses the
-- 80 m circle 0.8 m from spawns[7]. Before the director wave 1 (7) appeared all round him, 2 m away.

do
    local def = Missions.get('gang_shootout')
    local loc = def.locations[4]
    H.eq(loc.label, 'Container yard, Terminal', 'location 4 is the Terminal container yard')
    Place(1, 1156.0, -3170.0, 5.9)
    H.ok(D2(H.players[1].coords, loc.start.coords) <= loc.start.radius, 'the officer is inside the start circle')
    local run, ctx = Fight('gang_shootout', 4, { 1 })
    H.eq(run.state, 'in_progress', 'the run started: he crossed the circle')
    H.eq(#spawns, 3, 'wave 1: only the 3 points 40 m or more in front of him, at once')
    H.ok(Nearest(spawns) >= 40.0, ('none closer than 40 m (nearest %.1f m)'):format(Nearest(spawns)))
    for _, sp in ipairs(spawns) do H.ok(sp.y > -3170.0, 'every one in front of him (north, towards the yard)') end
    H.eq(#LinesWith('spawns[7] skipped: 2 m from Officer 1'), 1, 'the console names the file\'s point: spawns[7], 2 m')
    H.eq(#LinesWith('spawns[6] skipped: 5 m from Officer 1'), 1, 'and spawns[6], 5 m')
    H.eq(ctx.state.waves[1].spawned, 3, 'wave 1 has 3 of its 7 out')
    H.eq(HW.checklist(ctx)[1].max, 20, 'the fight still counts 20 hostiles')
    Secs(10)
    H.eq(#spawns, 3, 'the other 4 wait: no point 40 m away is left')
    Secs(10)
    local later = SpawnedSince(3)
    H.eq(#later, 2, 'after waveDelayMax (20 s) two more, on points 20 m or more away')
    H.ok(Nearest(later) >= 20.0, ('never closer than hardMin (nearest %.1f m)'):format(Nearest(later)))
    H.eq(#WarnsWith(
        'wave 1 (spawns) waited 20 s for points 40 m from the officers; used 2 closer one(s), the nearest 25 m away'
    ), 1, 'one warning names the wave and how close it came')
    H.eq(#LinesWith('spawns[14] skipped: behind Officer 1'), 1, 'spawns[14], 24 m away but behind him, is never used')
    Secs(30)
    H.eq(#spawns, 5, 'nothing else while he stands there')
    EndRun(run)
end

-- ============================================================================
--                              THE NORMAL WAY IN
-- ============================================================================
-- From the start marker: every hostile appears over the fight, none close, none behind.

do
    local loc = Missions.get('gang_shootout').locations[4]
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run, ctx = Fight('gang_shootout', 4, { 1 })
    H.eq(#spawns, 7, 'from the start marker wave 1 (7) appears at once')
    H.ok(Nearest(spawns) >= 40.0, ('none closer than 40 m (nearest %.1f m)'):format(Nearest(spawns)))
    local t = 0
    while not Done(run) and t < 600 do
        KillAll(run, 1)
        t = t + 2
    end
    H.ok(Done(run), 'the fight is won')
    H.eq(#spawns, 20, 'all 20 hostiles of the standard tier appeared over the fight (the count is never cut)')
    H.ok(Nearest(spawns) >= 40.0, ('none of the 20 closer than 40 m (nearest %.1f m)'):format(Nearest(spawns)))
    H.eq(run.objectiveIndex, 2, 'the next objective is current')
    H.eq(#WarnsWith('left out'), 0, 'nobody left out')
    EndRun(run)
end

-- ============================================================================
--                             A PUSH INTO THE YARD
-- ============================================================================
-- WAVE 2 COMES FROM IN FRONT OF HIM, FAR AWAY.

do
    local loc = Missions.get('gang_shootout').locations[4]
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run, ctx = Fight('gang_shootout', 4, { 1 })
    H.eq(#spawns, 7, 'wave 1 at once')
    -- he pushes into the yard, to the middle of the points
    Place(1, 1160.0, -3150.0, 5.9)
    local w1 = #spawns
    -- five of wave 1 fall (2 left: wave 2 comes)
    local list = CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })
    for i = 1, 5 do
        local m = W.ent(list[i].entity)
        m.killer, m.health = 100, 0
    end
    Secs(3)
    local w2 = SpawnedSince(w1)
    H.eq(#w2, 1, 'wave 2 starts with the one point 40 m or more in front of him')
    H.ok(Nearest(w2) >= 40.0, ('wave 2 only on points 40 m or more from him (nearest %.1f m)'):format(Nearest(w2)))
    Secs(25)
    local w2b = SpawnedSince(w1)
    H.eq(#w2b, 6, 'after waveDelayMax five more, 20 m or more away')
    H.ok(Nearest(w2b) >= 20.0, ('never closer than hardMin (nearest %.1f m)'):format(Nearest(w2b)))
    -- in the middle of the yard he faces the way in (from the start, north, towards the yard): wave 2 comes from the
    -- far side in front of him, never from the start side at his back
    for _, sp in ipairs(w2b) do H.ok(sp.y < -3150.0, ('wave 2 in front of him (%.1f, %.1f)'):format(sp.x, sp.y)) end
    H.eq(ctx.state.waves[2].spawned, 6, 'wave 2 has 6 of its 7 out; the last one waits')
    -- he walks back to the start: the last one may come now
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    Secs(2)
    H.eq(ctx.state.waves[2].spawned, 7, 'once he moved away, the rest of the wave appears')
    H.ok(Nearest(SpawnedSince(w1 + 6)) >= 40.0, 'far from him again (the wave got all it asked: its clock stopped)')
    EndRun(run)
end

-- ============================================================================
--                    WAVE 1 WAITS UNTIL AN OFFICER IS NEAR
-- ============================================================================
-- Config.Spawning.activateRange.

do
    cfg.activateRange = 50.0
    local loc = Missions.get('gang_shootout').locations[4]
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run, ctx = Fight('gang_shootout', 4, { 1 })
    H.eq(run.state, 'in_progress', 'the run is in progress (he reached the start)')
    Secs(5)
    H.eq(#spawns, 0, 'nobody appears while he is 60 m from the middle of the yard (activateRange 50)')
    H.eq(ctx.state.wave, 0, 'wave 1 has not begun')
    Place(1, 1160.0, -3110.0, 5.9)
    Secs(2)
    H.ok(#spawns > 0, 'he walked up to 45 m from the middle: wave 1 appears')
    H.ok(Nearest(spawns) >= 40.0, ('and away from him (nearest %.1f m)'):format(Nearest(spawns)))
    Reset()
    EndRun(run)
end

-- ============================================================================
--                               NO SPAWN POINTS
-- ============================================================================
-- Never at the start point: the fight is skipped.

do
    local def = Missions.get('gang_shootout')
    local loc = {}
    for k, v in pairs(def.locations[4]) do loc[k] = v end
    loc.spawns = {}
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run, ctx = Fight('gang_shootout', 4, { 1 }, { location = loc })
    Secs(2)
    H.eq(#spawns, 0, 'no spawn points: nobody appears, not at the start point either')
    H.eq(#WarnsWith(
        'wave 1: 7 hostile(s) left out: the location has no spawn points under spawns (never at the start point)'
    ), 1, 'one warning for each wave says why')
    H.eq(#WarnsWith('wave 3: 6 hostile(s) left out'), 1, 'every wave of the fight is left out')
    Secs(70)
    H.ok(Done(run), 'the fight completes once its minimum time has passed (nothing to fight)')
    EndRun(run)
end

-- ============================================================================
--             HOSTAGE RESCUE: INSIDE THE BANK, THE INDOOR DISTANCE
-- ============================================================================

do
    local def = Missions.get('hostage_rescue')
    H.eq(def.objectives[1].indoor, true, 'the hostage takers\' fight is marked indoor in the file')
    local loc = def.locations[1]
    H.eq(loc.label, 'Fleeca Bank, Legion Square', 'location 1 is the Legion Square Fleeca')
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run = Fight('hostage_rescue', 1, { 1 })
    H.eq(#spawns, 4, 'from the street outside (35-39 m away) all 4 appear at once')
    H.ok(Nearest(spawns) >= 15.0 and Nearest(spawns) < 40.0,
        ('closer than the outdoor 40 m, never under 15 m (nearest %.1f m)'):format(Nearest(spawns)))
    EndRun(run)
    -- the same fight without the flag would keep the outdoor 40 m: nobody at first
    Place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run2 = Fight('hostage_rescue', 1, { 1 }, { obj = { indoor = false } })
    H.eq(#spawns, 0, 'outdoors the same points are too close (under 40 m)')
    EndRun(run2)
    -- 16 m and 14 m from the nearest spot inside
    local nearest = loc.spawns[7]   -- (153.78, -1040.33): the spot nearest the door
    Place(1, nearest.x + 14.0, nearest.y, nearest.z)
    local run3, ctx3 = Fight('hostage_rescue', 1, { 1 })
    realPrint('probe F3', #spawns, Nearest(spawns))
    H.ok(Nearest(spawns) >= 15.0,
        ('an officer at the door: nobody within 15 m of him (nearest %.1f m)'):format(Nearest(spawns)))
    H.ok(#LinesWith('spawns[7] skipped: 14 m from Officer 1') == 1, 'the spot 14 m from him is skipped')
    EndRun(run3)
end

-- ============================================================================
--                                  THE RAIDS
-- ============================================================================
-- Both officers at the entries, the indoor distance.
-- Objective 2 starts the moment the breach completes, with the officers at the two entries: 2.6-10.5 m from the
-- crew's points before the director (a1 4.1 item 1); no point is 40 m from them at any of the 14 locations.

for _, case in ipairs({ { 'drug_lab_raid', 1, 3 }, { 'gang_hideout_raid', 5, 4 } }) do
    local id, li, atOnce = case[1], case[2], case[3]
    local def = Missions.get(id)
    H.eq(def.objectives[2].indoor, true, id .. ': the fight after the breach is marked indoor in the file')
    local loc = def.locations[li]
    Place(1, loc.entries[1].x, loc.entries[1].y, loc.entries[1].z)
    Place(2, loc.entries[2].x, loc.entries[2].y, loc.entries[2].z)
    local run, ctx = Fight(id, li, { 1, 2 }, { index = 2, seed = 7 })
    realPrint('probe raid', id, #spawns, Nearest(spawns), table.concat(ctx.state.sets or {}, ','))
    H.ok(#spawns >= atOnce,
        ('%s %s: %d of the crew appear at once (%d expected)'):format(id, loc.label, #spawns, atOnce))
    H.ok(Nearest(spawns) >= 15.0,
        ('%s: none within 15 m of the breach team (nearest %.1f m)'):format(id, Nearest(spawns)))
    EndRun(run)
end

-- ============================================================================
--                   NOBODY LEFT TO FIGHT AND NO POINT TO USE
-- ============================================================================
-- THE REST IS LEFT OUT (45 s).

do
    -- six points within 12 m of a spot in the yard; the start (the Terminal's) is 68 m north of it
    local base = Missions.get('gang_shootout').locations[4]
    local loc = {}
    for k, v in pairs(base) do loc[k] = v end
    local P = vec3(1160.0, -3160.0, 5.9)
    loc.spawns = {}
    for _, o in ipairs({ { 8, 0 }, { -8, 0 }, { 0, 8 }, { 0, -8 }, { 6, 6 }, { -6, -6 } }) do
        loc.spawns[#loc.spawns + 1] = vec4(P.x + o[1], P.y + o[2], P.z, 0.0)
    end
    local s0 = base.start.coords
    local function Yard()
        Place(1, s0.x, s0.y, s0.z)
        warns = {}
        local run, ctx = Fight('gang_shootout', 4, { 1 }, { location = loc, obj = { waves = { 3, 3 } } })
        H.eq(#spawns, 3, 'from the start wave 1 (3) appears on the yard\'s points')
        Place(1, P.x, P.y, P.z)   -- he walks onto the spot: every point is within 12 m of him
        return run, ctx
    end

    local run, ctx = Yard()
    KillAll(run, 1)
    H.ok(ctx.state.waves[2] ~= nil and ctx.state.waves[2].spawned == 0, 'wave 2 begins but has no point it may use')
    Secs(40)
    H.eq(#WarnsWith('left out'), 0, 'not before leaveOutAfter (45 s since the wave first had to wait)')
    H.eq(#spawns, 3, 'and nobody appears within 20 m of him, however long it waits')
    Secs(5)
    local w = WarnsWith(': wave 2: 3 hostile(s) left out: for 4')
    H.eq(#w, 1, 'at 45 s with nobody left to fight the wave is left out, with one warning')
    H.ok(w[1] and w[1].text:find('too close to or behind the officers (Config.Spawning.leaveOutAfter)', 1, true) ~= nil,
        'the warning says why and which setting')
    H.ok(w[1] and w[1].text:find('(gang_shootout)', 1, true) ~= nil, 'and names the mission')
    H.eq(ctx.state.waves[2].left, 3, 'wave 2 counts 3 left out')
    H.eq(HW.checklist(ctx)[1].max, 3, 'the fight now counts the 3 that appeared')
    Secs(20)
    H.ok(Done(run), 'and completes (after its 60 s minimum) instead of stalling')
    EndRun(run)

    -- not while a hostile still stands: the clock runs, the rest waits until he falls
    run, ctx = Yard()
    local alive = CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })
    for i = 2, #alive do
        local m = W.ent(alive[i].entity)
        m.killer, m.health = 100, 0
    end
    Secs(60)
    H.ok(ctx.state.waves[2] ~= nil, 'one of wave 1 is left: wave 2 has begun')
    H.eq(#WarnsWith('left out'), 0, 'he still stands after 60 s: nobody is left out')
    H.eq(Alive(run), 1, 'he is the only one up')
    KillAll(run, 1)
    H.eq(#WarnsWith('wave 2: 3 hostile(s) left out'), 1, 'he falls: wave 2 is left out at once')
    EndRun(run)

    -- leaveOutAfter = 0: never; the wave waits for the officers to move
    cfg.leaveOutAfter = 0
    run, ctx = Yard()
    KillAll(run, 1)
    Secs(300)
    H.eq(#WarnsWith('left out'), 0, 'leaveOutAfter 0: nobody is ever left out')
    H.eq(ctx.state.waves[2].spawned, 0, 'wave 2 still waits')
    H.eq(run.objectives[1].status, 'active', 'the fight goes on')
    Place(1, s0.x, s0.y, s0.z)
    Secs(2)
    H.eq(ctx.state.waves[2].spawned, 3, 'he walks back to the start: wave 2 appears')
    H.ok(Nearest(SpawnedSince(3)) >= 40.0, 'far from him')
    Reset()
    EndRun(run)
end

-- ============================================================================
--                                   THE BOSS
-- ============================================================================
-- His own spot when it is far enough, else a point of the fight.

do
    local def = Missions.get('weekly_boss_kingpin')
    local loc = def.locations[1]
    local function BossRun(x, y)
        Place(1, x, y, 107.0)
        local run, ctx = Fight('weekly_boss_kingpin', 1, { 1 }, { obj = { waves = { 1 } } })
        Secs(2)
        local boss = CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', role = 'boss' })[1]
        local at = boss and W.ent(boss.entity).coords
        return run, ctx, at
    end
    -- 60 m west of his spot, in the start circle: the Kingpin comes out on his own spot
    local run, ctx, at = BossRun(1305.0, 1135.0)
    H.ok(at ~= nil, 'the Kingpin appears after the last wave')
    H.ok(at and D2(at, loc.boss) < 0.01, 'on his own spot (60 m from the officer)')
    EndRun(run)
    -- hidden points first (Config.Spawning.preferHidden): the officer's game sees his own spot and, of the rest, only
    -- the last point sent is hidden. The wave's hostile appears on that hidden point; the Kingpin still on his own
    -- spot (the block marks it first = true), never on a hidden fight point instead. The run starts in a thread, as
    -- the server's arrival check starts it (a pick only asks the officers' games where it can wait for them)
    local realAwait = lib.callback.await
    local asks, hiddenAt = {}, nil
    lib.callback.await = function(name, src, args)
        asks[#asks + 1] = { name = name, src = src, n = #args.points }
        local out, last = {}, args.points[#args.points]
        for k, p in ipairs(args.points) do out[k] = not (k == #args.points and D2(p, loc.boss) > 0.01) end
        hiddenAt = hiddenAt or last
        return out
    end
    Place(1, 1305.0, 1135.0, 107.0)
    CreateThread(function() run, ctx = Fight('weekly_boss_kingpin', 1, { 1 }, { obj = { waves = { 1 } } }) end)
    Secs(2)
    lib.callback.await = realAwait
    local boss = CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', role = 'boss' })[1]
    at = boss and W.ent(boss.entity).coords
    H.ok(#asks == 2 and asks[1].name == 'crimson-police:client:spawn:visible' and asks[1].src == 1,
        ('the officer\'s game was asked what it sees, for the wave and for the Kingpin (%d asks)'):format(#asks))
    H.ok(hiddenAt and spawns[1] and D2(spawns[1], hiddenAt) < 0.01, 'the wave\'s hostile came out on the hidden point')
    H.ok(at and D2(at, loc.boss) < 0.01, 'the Kingpin still on his own spot, although the officer sees it')
    EndRun(run)
    -- from the start marker his spot is 39.7 m away: he comes out on a point of the fight 40 m or more away
    run, ctx, at = BossRun(loc.start.coords.x, loc.start.coords.y)
    H.ok(at ~= nil and D2(at, loc.boss) > 1.0, 'his spot is 39.7 m from the officer: not there')
    H.ok(at and D2(at, H.players[1].coords) >= 40.0,
        ('on a point 40 m or more away (%.1f m)'):format(at and D2(at, H.players[1].coords) or -1))
    H.eq(#LinesWith('boss[1] skipped: 40 m from Officer 1'), 1, 'the console says why his own spot was skipped')
    EndRun(run)
    -- the wave appeared, then he stands on every point and on the Kingpin's spot: the Kingpin is left out 45 s later
    -- and the fight completes
    local tight = {}
    for k, v in pairs(loc) do tight[k] = v end
    local s0 = loc.start.coords
    tight.spawns = { vec4(s0.x, s0.y + 60.0, s0.z, 0.0), vec4(s0.x + 5.0, s0.y + 60.0, s0.z, 0.0) }
    tight.boss = vec4(s0.x + 2.0, s0.y + 62.0, s0.z, 0.0)
    Place(1, s0.x, s0.y, s0.z)
    warns = {}
    run, ctx = Fight('weekly_boss_kingpin', 1, { 1 },
        { obj = { waves = { 1 }, nextWave = { aliveAtMost = 0, afterSeconds = 300 } }, location = tight })
    H.eq(#spawns, 1, 'wave 1 (one hostile) appears 60 m in front of him; the Kingpin waits for him to fall')
    Place(1, s0.x + 2.0, s0.y + 60.0, s0.z)
    KillAll(run, 1)
    H.eq(#CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', role = 'boss' }), 0, 'no Kingpin within 5 m of him')
    Secs(30)
    H.eq(#WarnsWith('left out'), 0, 'not yet')
    Secs(20)
    H.eq(#WarnsWith('The Kingpin: 1 hostile(s) left out: for 4'), 1,
        'the Kingpin is left out after 45 s, with a warning')
    H.eq(#spawns, 1, 'nobody else appeared')
    Secs(45)
    H.ok(Done(run), 'the fight completes without him (after its 90 s minimum)')
    local cl = run.objectives[1].final or HW.checklist(ctx)
    H.eq(#cl, 1, 'the result has no Kingpin line for a Kingpin who never appeared')
    EndRun(run)
end

-- ============================================================================
--                         STANDING ON THE POINTS FIRST
-- ============================================================================
-- Officers among the points before the fight begins only make it wait.

do
    local base = Missions.get('gang_shootout').locations[4]
    local loc = {}
    for k, v in pairs(base) do loc[k] = v end
    local P = vec3(1160.0, -3160.0, 5.9)
    loc.spawns = {}
    for _, o in ipairs({ { 8, 0 }, { -8, 0 }, { 0, 8 }, { 0, -8 }, { 6, 6 }, { -6, -6 } }) do
        loc.spawns[#loc.spawns + 1] = vec4(P.x + o[1], P.y + o[2], P.z, 0.0)
    end
    Place(1, P.x, P.y, P.z)
    H.ok(D2(H.players[1].coords, base.start.coords) <= base.start.radius, 'the spot is inside the start circle')
    warns = {}
    local run = Fight('gang_shootout', 4, { 1 }, { location = loc, obj = { waves = { 3, 3 } } })
    Secs(300)
    H.eq(#spawns, 0, 'he stands among every point: nobody appears')
    H.eq(#WarnsWith('left out'), 0, 'and nobody is left out: a fight is never skipped that way')
    H.eq(run.objectives[1].status, 'active', 'it waits')
    Place(1, base.start.coords.x, base.start.coords.y, base.start.coords.z)
    Secs(2)
    H.eq(#spawns, 3, 'he backs off to the start: wave 1 appears')
    H.ok(Nearest(spawns) >= 40.0, 'far from him')
    Secs(60)
    H.eq(#spawns, 3, 'wave 2 does not pile on: afterSeconds (90 s) counts from wave 1\'s first hostile, not its wait')
    Secs(30)
    H.eq(#spawns, 6, 'wave 2 comes 90 s after wave 1 appeared')
    EndRun(run)
end

-- ============================================================================
--                         A WAVE LARGER THAN THE LIST
-- ============================================================================
-- Ring copies of the points, each checked like a point.

do
    local def = Missions.get('gang_shootout')
    local base = def.locations[4]
    local loc = {}
    for k, v in pairs(base) do loc[k] = v end
    local s0 = base.start.coords
    -- two points 10 m and 15 m from the start, two 60 m and 70 m in front of it (south, towards the yard)
    loc.spawns = {
        vec4(s0.x + 10.0, s0.y, s0.z, 0.0),
        vec4(s0.x - 15.0, s0.y, s0.z, 0.0),
        vec4(s0.x, s0.y - 60.0, s0.z, 0.0),
        vec4(s0.x + 5.0, s0.y - 70.0, s0.z, 0.0),
    }
    Place(1, s0.x, s0.y, s0.z)
    local run, ctx = Fight('gang_shootout', 4, { 1 }, { location = loc, obj = { waves = { 6 } } })
    H.eq(#spawns, 4, 'a wave of 6 on 4 points: the 2 far points and one ring copy of each')
    for _, sp in ipairs(spawns) do
        local d3, d4 = D2(sp, loc.spawns[3]), D2(sp, loc.spawns[4])
        H.ok(math.min(d3, d4) < 1.3, ('every one on a far point or 1.25 m from it (%.2f m)'):format(math.min(d3, d4)))
        H.ok(sp.near >= 40.0, 'none near the officer')
    end
    H.eq(#LinesWith('spawns[1] +1.25 m skipped'), 1, 'the copy of a near point is checked and skipped too')
    EndRun(run)
end

-- ============================================================================
--              SWITCHED OFF: PEOPLE APPEAR AS BEFORE THE DIRECTOR
-- ============================================================================

do
    cfg.enabled = false
    Place(1, 1156.0, -3170.0, 5.9)
    local run = Fight('gang_shootout', 4, { 1 })
    H.eq(#spawns, 7, 'Config.Spawning.enabled = false: all of wave 1 at once')
    H.ok(Nearest(spawns) < 5.0, ('on the file\'s points, as before (nearest %.1f m)'):format(Nearest(spawns)))
    Reset()
    EndRun(run)
end

-- ============================================================================
--                         THE INDOOR OPTION IS CHECKED
-- ============================================================================

do
    local loc = Missions.get('gang_shootout').locations[1]
    local builtin, custom = { source = 'builtin' }, { source = 'custom' }
    local ok, why = HW.validate({ indoor = 'yes' }, builtin, loc)
    H.eq(ok, false, 'indoor must be true or false')
    H.eq(why, CP.L('block.hostile_waves.invalid.indoor'), 'with its own reason')
    H.ok(CP.L('block.hostile_waves.invalid.indoor'):find('indoor must be true', 1, true) ~= nil, 'in plain words')
    H.eq(HW.validate({ indoor = true }, builtin, loc), true, 'indoor = true is fine')
    H.eq(HW.validate({ indoor = false }, builtin, loc), true, 'and false')
    H.eq(select(2, HW.validate({ indoor = 1 }, custom, loc)), CP.L('block.hostile_waves.invalid.indoor'),
        'a number is refused in a custom mission too')
end

_G.print = realPrint
return H
