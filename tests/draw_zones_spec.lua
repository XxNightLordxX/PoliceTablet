-- Modules/draw (WP4): areas, footprints, zone clearance, location memory and freshness, the county-wide
-- weighting, the daily cap and its board lock, the ready-check call site and admin:getLocationStats.

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_draw_zones'
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U
H.time = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })   -- a Wednesday

-- ============================================================================
--                                    STUBS
-- ============================================================================

local players = {}
local units = {}
local runs, created = {}, {}
local cooldowns, daily = {}, {}
local notes = {}

local function AddPlayer(src, coords)
    players[src] = { citizenid = ('DZ%03d'):format(src), name = 'Officer ' .. src, callsign = '2L-' .. src }
    H.players[src] = { coords = coords or vec3(0.0, 0.0, 0.0) }
end

CP.Access = {
    getOfficer = function(src)
        local p = players[src]
        if not p then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.citizenid,
            name = p.name,
            callsign = p.callsign,
            department = 'sast',
            departmentShort = 'SAST',
            job = 'police',
            rank = 'Trooper',
        }
    end,
    isAdmin = function(src) return src == 99 end,
}
CP.Units = {
    unitOf = function(src)
        for _, u in ipairs(units) do
            for _, m in ipairs(u.members) do if m == src then return u end end
        end
        return nil
    end,
    members = function(src)
        local u = CP.Units.unitOf(src)
        return u and u.members or { src }
    end,
    isLeader = function(src)
        local u = CP.Units.unitOf(src)
        return u ~= nil and u.leader == src
    end,
    lock = function(u) u.locked = true end,
    unlock = function(u) u.locked = false end,
}
CP.Runs = {
    isOnMission = function() return false end,
    getBySrc = function() return nil end,
    capsOk = function() return true end,
    cooldowns = function(cid) return cooldowns[cid] or { types = {}, missions = {} } end,
    completionsLastHour = function() return 0 end,
    completionsToday = function(cid, t) return daily[cid .. '|' .. tostring(t or '*')] or 0 end,
    create = function(opts)
        local run = {
            id = ('run-%d'):format(#created + 1),
            mission = opts.mission,
            missionId = opts.mission.id,
            locationIndex = opts.locationIndex,
            state = 'accepted',
            missionCall = opts.missionCall,
        }
        created[#created + 1] = opts
        runs[run.id] = run
        return run
    end,
    get = function(id) return runs[id] end,
    all = function() return runs end,
}
CP.Cash = {
    range = function() return 200, 300 end,
}
CP.Tablet = {
    notify = function(src, kind, key) notes[#notes + 1] = { src = src, kind = kind, key = key } end,
}
CP.Permissions = {
    can = function(src, action)
        if src == 99 then return true end
        return false, 'err.no_permission'
    end,
}

-- Missions: locations laid out around the area centres of Config.MissionCalls.areas, 300 m apart.
local defs, byId = {}, {}
local function Loc(x, y, extra)
    local l = { label = ('(%d, %d)'):format(x, y), start = { coords = vec3(x + 0.0, y + 0.0, 30.0), radius = 40.0 } }
    for k, v in pairs(extra or {}) do l[k] = v end
    return l
end
local function Def(id, mtype, locations, min, max)
    local d = {
        id = id,
        type = mtype,
        minOfficers = min or 1,
        maxOfficers = max or 4,
        difficulty = 1,
        cooldown = 900,
        locations = locations,
        objectives = { { block = 'checkpoint_route' } },
    }
    defs[#defs + 1] = d
    byId[id] = d
    return d
end
CP.Missions = {
    byType = function(t)
        local out = {}
        for _, d in ipairs(defs) do if d.type == t then out[#out + 1] = d end end
        return out
    end,
    get = function(id) return byId[id] end,
    isEnabled = function(id) return byId[id] ~= nil and not byId[id].off end,
}

H.load('modules/schedule/server.lua')
H.load('modules/draw/server.lua')
local D = CP.Draw

-- south_ls centre (150, -1750), downtown (-150, -850), vinewood (250, 250)
local routeLoc = Loc(150, -1750, {
    route = { points = { vec3(150.0, -1750.0, 30.0), vec3(150.0, -1550.0, 30.0) } },
    spawns = { vec4(160.0, -1740.0, 30.0, 0.0) },
})
local pa = Def('patrol_a', 'patrol', {
    routeLoc,
    Loc(450, -1750),
    Loc(150, -2050),
    Loc(-150, -850),
})
local pb = Def('patrol_b', 'patrol', { Loc(-150, -550), Loc(150, -850), Loc(250, 250) })

-- ============================================================================
--                               AREAS AND POOLS
-- ============================================================================

do
    H.eq(D._areaKeyOf(vec3(140.0, -1760.0, 0.0)), 'south_ls', 'nearest centre: south_ls')
    H.eq(D._areaKeyOf(vec3(-160.0, -700.0, 0.0)), 'downtown', 'nearest centre: downtown')
    H.eq(D._locationArea(pa, 2), 'south_ls', 'location #2 of patrol_a is in south_ls')
    H.eq(D._locationArea(pa, 4), 'downtown', 'location #4 of patrol_a is downtown')
    AddPlayer(1, vec3(0.0, 0.0, 0.0))
    local all = D.pool('patrol', { 1 })
    H.eq(#all, 2, 'the board pool has both patrol missions')
    local south = D.pool('patrol', { 1 }, { area = 'south_ls' })
    H.eq(#south, 1, 'only patrol_a has a location in south_ls')
    H.eq(south[1].id, 'patrol_a', 'south_ls pool')
    for s = 1, 40 do
        local i = D.pickLocation(pa, { 1 }, U.rng(U.hash('area' .. s)), { area = 'south_ls' })
        H.ok(i ~= 4, 'an area-bound pick never leaves the area')
    end
    H.eq(D.pickLocation(pb, { 1 }, U.rng(3), { area = 'south_ls' }), nil, 'no location in the area: nil')
end

-- ============================================================================
--                                  FOOTPRINTS
-- ============================================================================

do
    local fp = D.footprint(pa, 1)
    -- start, the spawn, the two route points and the route every 50 m (3 samples between 0 and 200 m)
    H.ok(#fp >= 6, 'footprint holds the start, the spawn and the sampled route: ' .. #fp)
    local sampled = 0
    for _, p in ipairs(fp) do
        if math.abs(p.x - 150.0) < 0.01 and math.abs(p.y + 1650.0) < 0.01 then sampled = sampled + 1 end
    end
    H.ok(sampled >= 1, 'the route is sampled every 50 m (100 m along it)')
    H.eq(#D.footprint(pa, 99), 0, 'no such location: empty footprint')
end

-- ============================================================================
--                                ZONE CLEARANCE
-- ============================================================================

do
    -- a run of another mission holds a spot 120 m from patrol_a #2 (450, -1750)
    local other = Def('other_near', 'training', { Loc(450, -1630) })
    D.reserve('run-other', 'other_near', 1)
    runs['run-other'] = { id = 'run-other', mission = other, locationIndex = 1, state = 'in_progress' }
    H.ok(D._zoneBlocked(pa, 2), 'patrol_a #2 is within 200 m of another run\'s footprint')
    H.ok(not D._zoneBlocked(pa, 3), 'patrol_a #3 is clear')
    for s = 1, 60 do
        local i = D.pickLocation(pa, { 1 }, U.rng(U.hash('zone' .. s)), { exclude = { [4] = true } })
        H.ok(i ~= 2, 'zone clearance skips the blocked spot while another is free')
    end
    -- every other spot excluded: the blocked spot is still drawn (soft rule)
    local only = D.pickLocation(pa, { 1 }, U.rng(5), { exclude = { [1] = true, [3] = true, [4] = true } })
    H.eq(only, 2, 'zone clearance falls back to the reservation rule when nothing else is free')
    -- the route counts: a run 150 m beside the middle of patrol_a #1's route blocks it
    local side = Def('other_route', 'training', { Loc(300, -1650) })
    D.reserve('run-side', 'other_route', 1)
    runs['run-side'] = { id = 'run-side', mission = side, locationIndex = 1, state = 'in_progress' }
    H.ok(D._zoneBlocked(pa, 1), 'a point 150 m from the sampled route blocks the location')
    D.release('run-side')
    runs['run-side'] = nil
    H.ok(not D._zoneBlocked(pa, 1), 'released: clear again')
    D.release('run-other')
    runs['run-other'] = nil
    H.ok(not D._zoneBlocked(pa, 2), 'the other run ended: clear')
end

-- ============================================================================
--                    LOCATION MEMORY, FRESHNESS, WEIGHTING
-- ============================================================================

do
    -- avoidLastLocations: cp_mission_runs.location_index of every participant, soft
    local ins = [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base, location_index, created_at) VALUES (?, 'patrol', 'patrol_a', ?, 'sast', 'completed',
        'completed', 60, ?, FROM_UNIXTIME(?))]]
    MySQL.insert.await(ins, { 'dz-1', 'DZ001', 1, H.time - 600 })
    MySQL.insert.await(ins, { 'dz-2', 'DZ001', 2, H.time - 300 })
    local seen = {}
    for s = 1, 60 do
        local def, i = D.draw('patrol', { 1 }, { rng = U.rng(U.hash('mem' .. s)), area = 'south_ls' })
        H.eq(def and def.id, 'patrol_a', 'area-bound draw picks the only mission there')
        seen[i] = true
    end
    H.ok(not seen[1] and not seen[2] and seen[3], 'the last 2 locations played are skipped while another is free')
    -- only locations played: still drawn
    MySQL.insert.await(ins, { 'dz-3', 'DZ001', 3, H.time - 100 })
    local def, i = D.draw('patrol', { 1 }, { rng = U.rng(7), area = 'south_ls' })
    H.ok(def ~= nil and i ~= nil, 'soft: with every area location played recently the draw still succeeds')
    -- the in-memory bridge (before the row exists)
    AddPlayer(2)
    D.recordLocation('DZ002', 'patrol_b', 1)
    D.recordLocation('DZ002', 'patrol_b', 2)
    local counts = {}
    for s = 1, 60 do
        local idx = D.pickLocation(pb, { 2 }, U.rng(U.hash('bridge' .. s)), { avoid = { [1] = true, [2] = true } })
        counts[idx] = (counts[idx] or 0) + 1
    end
    H.eq(counts[3], 60, 'opts.avoid skips indices softly')

    -- freshness: a spot used server-wide in the last hour gets half the weight
    D.reserve('run-fresh', 'patrol_b', 1)
    D.release('run-fresh')
    local n1, n = 0, 3000
    for s = 1, n do
        if D.pickLocation(pb, { 2 }, U.rng(U.hash('fresh' .. s))) == 1 then n1 = n1 + 1 end
    end
    -- weights 0.5, 1, 1: expected share 0.2
    H.ok(n1 > n * 0.14 and n1 < n * 0.26, ('a fresh spot is drawn about half as often (%d of %d)'):format(n1, n))
    local oldTime = H.time
    H.time = H.time + 3601
    local m1 = 0
    for s = 1, n do
        if D.pickLocation(pb, { 2 }, U.rng(U.hash('fresh' .. s))) == 1 then m1 = m1 + 1 end
    end
    H.ok(m1 > n * 0.28 and m1 < n * 0.39, ('after an hour it is a normal spot again (%d of %d)'):format(m1, n))
    H.time = oldTime

    -- county-wide weighting towards the unit: 1 / (1 + km / 2)
    local far = Def('patrol_far', 'training', { Loc(0, 4000), Loc(8000, 4000) })
    local near1 = 0
    for s = 1, n do
        local idx = D.pickLocation(far, { 2 }, U.rng(U.hash('near' .. s)), { nearCoords = { vec3(0.0, 4000.0, 0.0) } })
        if idx == 1 then near1 = near1 + 1 end
    end
    -- weights 1 and 1 / (1 + 4) = 0.2: expected share 0.83
    H.ok(near1 > n * 0.78 and near1 < n * 0.88, ('the nearer location wins about 5 in 6 (%d of %d)'):format(near1, n))
    far.off = true
end

-- ============================================================================
--                         DAILY CAP AND THE BOARD LOCK
-- ============================================================================

do
    local cfg = Config.Limits
    local oldMax = cfg.maxCompletionsDay
    cfg.maxCompletionsDay = 3
    daily['DZ001|*'] = 3
    local data = D.boardCards(1)
    local card
    for _, c in ipairs(data.cards) do if c.key == 'patrol' then card = c end end
    H.ok(card and card.locked and card.locked.daily == true, 'the patrol card is locked by the daily cap')
    H.eq(card.locked.reason, 'board.locked_daily', 'daily lock reason key (no locale loaded)')
    local nextDay = CP.Schedule.dayStart(CP.Schedule.dayStart(H.time) + 30 * 3600)
    H.eq(card.locked['until'], nextDay, 'locked until the next day start')
    H.ok(nextDay > H.time and nextDay - H.time <= 86400, 'the next day start is within a day')
    local ok, err = D.check(1, 'patrol')
    H.eq(ok, false, 'accept refused at the daily cap')
    H.eq(err, 'err.daily_cap', 'own daily cap key')
    -- a member at the cap
    AddPlayer(3)
    units = { { id = 1, leader = 3, members = { 3, 1 } } }
    local _, errM = D.check(3, 'patrol')
    H.eq(errM, 'err.member_daily_cap', 'member daily cap key')
    units = {}
    daily['DZ001|*'] = 0
    cfg.maxCompletionsDay = oldMax
    -- the type's own dailyLimit
    Config.MissionTypes.patrol.dailyLimit = 2
    daily['DZ001|patrol'] = 2
    local _, errT = D.check(1, 'patrol')
    H.eq(errT, 'err.type_daily_cap', 'type daily limit key')
    data = D.boardCards(1)
    for _, c in ipairs(data.cards) do if c.key == 'patrol' then card = c end end
    H.eq(card.locked and card.locked.reason, 'board.locked_type_daily', 'type daily lock')
    Config.MissionTypes.patrol.dailyLimit = nil
    daily['DZ001|patrol'] = nil
    H.eq((D.check(1, 'patrol')), true, 'no cap: allowed again')
end

-- ============================================================================
--                   THE READY CHECK CALL SITE (UNITS OF 2+)
-- ============================================================================

do
    AddPlayer(4, vec3(150.0, -1700.0, 30.0))
    AddPlayer(5, vec3(160.0, -1700.0, 30.0))
    local unit = { id = 2, leader = 4, members = { 4, 5 } }
    units = { unit }
    -- without CP.Units.readyCheck the draw follows at once (guarded fallback)
    local ok, data = D.accept(4, 'patrol', {})
    H.eq(ok, true, 'fallback: accepted at once')
    H.ok(data and data.runId ~= nil, 'fallback: the run exists')
    unit.locked = false
    -- with it: pending until the members answer
    local pendingCb
    CP.Units.readyCheck = function(u, typeKey, onReady, onCancel)
        pendingCb = { u = u, typeKey = typeKey, onReady = onReady, onCancel = onCancel }
        return true
    end
    local results = {}
    local n0 = #created
    ok, data = D.accept(4, 'patrol', {
        onDone = function(o, d) results[#results + 1] = { o, d } end,
    })
    H.eq(ok, true, 'ready check: accepted')
    H.eq(data and data.pending, true, 'ready check: pending')
    H.eq(#created, n0, 'no run before everyone is ready')
    H.eq(unit.locked, true, 'the unit is locked while the check runs')
    H.eq(pendingCb.typeKey, 'patrol', 'readyCheck gets the type')
    pendingCb.onReady()
    H.eq(#created, n0 + 1, 'the run is created after the ready check')
    H.eq(results[1] and results[1][1], true, 'onDone(true)')
    H.ok(results[1][2].runId ~= nil, 'onDone gets the run id')
    -- declined: nobody gets a run, the unit unlocks
    unit.locked = false
    results = {}
    ok, data = D.accept(4, 'patrol', {
        onDone = function(o, d) results[#results + 1] = { o, d } end,
    })
    pendingCb.onCancel('err.ready_declined', { 5 })
    H.eq(results[1] and results[1][1], false, 'declined: onDone(false)')
    H.eq(results[1][2], 'err.ready_declined', 'declined: reason key')
    H.eq(unit.locked, false, 'declined: the unit is unlocked')
    H.eq(#created, n0 + 1, 'declined: no run')
    CP.Units.readyCheck = nil
    units = {}

    -- a mission call's response target: nearest member's straight line to the drawn start / 20 m/s + 45 s
    local okC, dc = D.accept(4, 'patrol', { area = 'south_ls', missionCall = { id = 7, code = 'MC-0007' } })
    H.eq(okC, true, 'mission call accept')
    local mc = created[#created].missionCall
    H.eq(mc.id, 7, 'the run gets the call id')
    local start = byId[dc.missionId].locations[dc.locationIndex].start.coords   -- (footprint order follows pairs())
    H.eq(D._locationArea(byId[dc.missionId], dc.locationIndex), 'south_ls', 'drawn inside the call\'s area')
    local d = U.dist(vec3(150.0, -1700.0, 30.0), start)
    H.eq(mc.targetS, math.floor(d / 20 + 45 + 0.5), 'targetS from the nearest member')
    H.eq(created[#created].locationIndex, dc.locationIndex, 'the location index goes to CP.Runs.create')

    -- a county-wide call (no area named) weights the draw towards the unit's members; the board never does
    local seenOpts = {}
    local realDraw = D.draw
    D.draw = function(t, m, o)
        seenOpts[#seenOpts + 1] = o
        return realDraw(t, m, o)
    end
    D.accept(4, 'patrol', { missionCall = { id = 8, code = 'MC-0008' } })
    local near = seenOpts[1] and seenOpts[1].nearCoords
    H.ok(type(near) == 'table' and #near == 1 and U.dist(near[1], vec3(150.0, -1700.0, 30.0)) < 1,
        'county-wide call: the draw is weighted towards the member\'s server-side position')
    H.eq(seenOpts[1] and seenOpts[1].area, nil, 'and not bound to an area')
    D.accept(4, 'patrol', {})
    H.eq(seenOpts[2] and seenOpts[2].nearCoords, nil, 'a Mission Board accept is not weighted')
    D.accept(4, 'patrol', { area = 'south_ls', missionCall = { id = 9, code = 'MC-0009' } })
    H.eq(seenOpts[3] and seenOpts[3].nearCoords, nil, 'an area call is bound to its area instead')
    D.draw = realDraw
end

-- ============================================================================
--                            admin:getLocationStats
-- ============================================================================

do
    local stats = H.callback('crimson-police:admin:getLocationStats', 99, { missionId = 'patrol_a' })
    H.eq(stats.ok, true, 'admin gets the stats')
    local rows = stats.data
    H.eq(#rows, 4, 'one row per location')
    H.eq(rows[1].plays, 1, 'location #1 played once')
    H.eq(rows[3].plays, 1, 'location #3 played once')
    H.eq(rows[4].plays, 0, 'location #4 never played')
    H.eq(rows[2].lastPlayed, H.time - 300, 'last played of #2')
    H.eq(rows[1].area, 'south_ls', 'the area of each location')
    local refused = H.callback('crimson-police:admin:getLocationStats', 1, { missionId = 'patrol_a' })
    H.eq(refused.ok, false, 'officers are refused')
    local bad = H.callback('crimson-police:admin:getLocationStats', 99, { missionId = 'nope' })
    H.eq(bad.error, 'err.draw_unknown_mission', 'unknown mission')
end

return H
