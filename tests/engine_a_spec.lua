-- tests/engine_a_spec.lua · modules/missions, draw, scaling, schedule, events (slice engine_a).
--
-- Mission files are served from memory through a LoadResourceFile override, other modules are
-- stubbed, and every SQL statement of the slice runs against MariaDB. The spec uses its own
-- database (cp_test_engine_a, rebuilt from sql/migrations) so parallel runs of other specs that
-- reset cp_test cannot interfere.

local H = dofile('tests/harness.lua')
H.db = 'cp_test_engine_a'
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U
local T0 = H.time                 -- Monday 2026-09-21 14:13:20 (server time zone of the test box)
local FRIDAY = 1790337600         -- Friday 2026-09-25 12:00:00
local WEEK_START = 1789948800     -- Monday 2026-09-21 00:00:00

-- ── locale: serve this slice's part as en.json so CP.L returns real text ─────
local partFile = io.open(H.root .. 'locales/parts/engine_a.json', 'r')
local partText = partFile:read('a')
partFile:close()

-- ── in-memory resource files ───────────────────────────────────────────────
local files = {}
local realLoad = LoadResourceFile
LoadResourceFile = function(res, path)
    if files[path] ~= nil then return files[path] or nil end
    if path == 'locales/en.json' then return partText end
    if path:sub(1, 9) == 'missions/' then return nil end
    return realLoad(res, path)
end
H.load('shared/locale.lua')
H.eq(CP.L('board.locked_empty', { type = 'Patrol', size = 3 }), 'No Patrol missions for a unit of 3', 'locale part loaded')

local function locSrc(n, x0)
    local out = {}
    for i = 1, n do
        local x = x0 + i * 1000
        out[#out + 1] = ('{ label = "Spot %d", start = { coords = vec3(%d.0, 100.0, 30.0), radius = 50.0 }, spawns = { vec4(%d.0, 140.0, 30.0, 90.0), vec4(%d.0, 150.0, 30.0, 90.0) }, scene = vec3(%d.0, 120.0, 30.0) }'):format(i, x, x, x, x)
    end
    return '{ ' .. table.concat(out, ',\n    ') .. ' }'
end

local DEFAULT_OBJ = "{ { block = 'checkpoint_route', label = 'Drive the route', checkpoints = 'spawns' } }"

local function missionSrc(o)
    return ([[
-- test mission %s
RegisterMission({
  id = %q, label = %q, description = 'Test mission', type = %q,
  departments = %s, minOfficers = %d, maxOfficers = %d, difficulty = %d,
  timeLimit = 600, cooldown = 900,
  locations = %s,
  objectives = %s,
  %s
})
]]):format(o.id, o.fileId or o.id, o.label or ('Label ' .. o.id), o.type or 'patrol', o.deps or '{}', o.min or 1, o.max or 1,
        o.diff or 1, locSrc(o.n or 5, o.x0 or 0), o.objectives or DEFAULT_OBJ, o.extra or '')
end

local function builtin(id, src) files['missions/builtin/' .. id .. '.lua'] = src end

builtin('patrol_a', missionSrc({ id = 'patrol_a', min = 1, max = 1, x0 = 0 }))
builtin('patrol_b', missionSrc({ id = 'patrol_b', min = 1, max = 2, x0 = 10000 }))
builtin('patrol_c', missionSrc({ id = 'patrol_c', min = 1, max = 2, x0 = 20000 }))
builtin('patrol_d', missionSrc({ id = 'patrol_d', min = 1, max = 4, x0 = 30000 }))
builtin('training_solo', missionSrc({ id = 'training_solo', type = 'training', x0 = 40000, diff = 2 }))
builtin('invest_fib', missionSrc({ id = 'invest_fib', type = 'investigation', deps = "{ 'fib' }", min = 2, max = 4, x0 = 50000 }))
builtin('tac_one', missionSrc({
    id = 'tac_one', type = 'tactical', min = 1, max = 4, diff = 3, x0 = 60000,
    objectives = [[{
      { block = 'hostile_waves', label = 'Neutralise all hostiles', spawns = 'spawns', accuracy = 25 },
      { block = 'interact_points', label = 'Secure the scene', minSeconds = 8, points = 'scene', count = 2 },
    }]],
    extra = [[
  payout = 5000, cashBase = 10, vehiclePenalties = false,
  scaling = { 'objectives.1.waves', 'objectives.9.nothing', { path = 'objectives.2.count', max = 4 }, 42 },
  items = { { name = 'radio', count = 1 }, { count = 2 } },
  bonuses = { { id = 'no_participant_downed', pctOfPoints = 0.10 }, { id = 'racer_detained', points = 30, each = true }, { id = 'mystery_bonus' } },
  penalties = { { id = 'hard_ram', points = -10, each = true } },]],
}))
builtin('weekly_boss_kingpin', missionSrc({
    id = 'weekly_boss_kingpin', type = 'tactical', min = 1, max = 4, diff = 3, n = 3, x0 = 70000,
    objectives = "{ { block = 'hostile_waves', label = 'Neutralise all hostiles', spawns = 'spawns', waves = { 8, 8, 7, 7 } } }",
    extra = "scaling = { 'objectives.1.waves' },",
}))
builtin('bad_block', missionSrc({ id = 'bad_block', objectives = "{ { block = 'no_such_block' } }" }))
builtin('bad_twice', missionSrc({ id = 'bad_twice' }) .. "\nRegisterMission({ id = 'bad_twice' })\n")
builtin('bad_id', missionSrc({ id = 'bad_id', fileId = 'something_else' }))
builtin('bad_syntax', "RegisterMission({ id = 'bad_syntax', ")
builtin('bad_validate', missionSrc({ id = 'bad_validate', type = 'tactical', objectives = "{ { block = 'hostile_waves', spawns = 'nowhere' } }" }))
builtin('bad_type', missionSrc({ id = 'bad_type', type = 'traffic' }))
builtin('bad_runtime', "error('boom')")
builtin('bad_sandbox', "os.exit(1)\n" .. missionSrc({ id = 'bad_sandbox' }))
files['missions/builtin/index.lua'] = [[
return {
  'patrol_a', 'patrol_b', 'patrol_c', 'patrol_d', 'training_solo', 'invest_fib', 'tac_one', 'weekly_boss_kingpin',
  'bad_block', 'bad_twice', 'bad_id', 'bad_syntax', 'bad_validate', 'bad_type', 'bad_runtime', 'bad_sandbox',
  'missing_file', 'patrol_a', 42,
}
]]
files['missions/custom/custom_file.lua'] = missionSrc({ id = 'custom_file', type = 'training', n = 3, x0 = 80000 })

-- ── fake blocks ─────────────────────────────────────────────────────────────
CP.Blocks.register('hostile_waves', {
    defaults = function(obj)
        obj.waves = obj.waves or { 7, 7, 6 }
        obj.accuracy = obj.accuracy or 25
        return obj
    end,
    validate = function(obj, mission, location)
        if type(location[obj.spawns or 'spawns']) ~= 'table' then return false, 'spawns missing' end
        return true
    end,
    armedCount = function(obj)
        local n = 0
        for _, w in ipairs(obj.waves) do n = n + w end
        return n
    end,
})
CP.Blocks.register('interact_points', {
    defaults = function(obj) obj.use = obj.use or 'all'; return obj end,
    validate = function(obj, mission, location)
        if obj.points and location[obj.points] == nil then return false, 'points missing' end
        return true
    end,
})
CP.Blocks.register('checkpoint_route', {
    defaults = function(obj) obj.radius = obj.radius or 10.0; return obj end,
})

-- ── stubs of other modules ──────────────────────────────────────────────────
local officers = {
    [1] = { src = 1, citizenid = 'CIDA', name = 'Alice A', department = 'sast', job = 'sast', onduty = true },
    [2] = { src = 2, citizenid = 'CIDB', name = 'Bob B', department = 'fib', job = 'fib', onduty = true },
    [3] = { src = 3, citizenid = 'CIDC', name = 'Carl C', department = 'sast', job = 'sast', onduty = true },
    [4] = { src = 4, citizenid = 'CIDD', name = 'Dana D', department = 'fib', job = 'fib', onduty = true },
    [9] = { src = 9, citizenid = 'CIDADMIN', name = 'Admin', department = 'sast', job = 'sast', onduty = true },
}
local offDuty = {}
CP.Access = {
    getOfficer = function(src)
        local o = officers[src]
        if not o then return nil, 'err.not_police' end
        if offDuty[src] then return nil, 'err.not_on_duty' end
        return o
    end,
    role = function(src) return src == 9 and 'admin' or 'officer' end,
}

local units = {}
local lockCalls, unlockCalls = 0, 0
CP.Units = {
    unitOf = function(src) return units[src] end,
    members = function(src)
        local u = units[src]
        if u then return u.members end
        return { src }
    end,
    isLeader = function(src)
        local u = units[src]
        return (not u) or u.leader == src
    end,
    lock = function(u) u.locked = true; lockCalls = lockCalls + 1 end,
    unlock = function(u) u.locked = false; unlockCalls = unlockCalls + 1 end,
}
local function setUnit(members)
    local u = { id = #members * 10, leader = members[1], members = members, locked = false }
    for _, m in ipairs(members) do units[m] = u end
    return u
end
local function clearUnits() units = {} end

local rs = { cooldowns = {}, hourly = {}, onMission = {}, busy = {}, runs = {}, created = {}, mode = 'ok' }
CP.Runs = {
    cooldowns = function(cid) return rs.cooldowns[cid] or { types = {}, missions = {} } end,
    completionsLastHour = function(cid) return rs.hourly[cid] or 0 end,
    isOnMission = function(src) return rs.onMission[src] == true end,
    getBySrc = function(src)
        if rs.onMission[src] then return { id = 'active-' .. src } end
        return nil
    end,
    capsOk = function(t)
        if rs.busy[t] then return false, 'err.caps_reached' end
        return true
    end,
    create = function(opts)
        if rs.mode == 'fail' then return nil, 'err.create_refused' end
        if rs.mode == 'error' then error('create exploded') end
        local run = { id = 'run-' .. (#rs.created + 1), mission = opts.mission, locationIndex = opts.locationIndex }
        rs.created[#rs.created + 1] = opts
        rs.runs[run.id] = run
        if rs.mode ~= 'noreserve' then CP.Draw.reserve(run.id, opts.mission.id, opts.locationIndex) end
        return run
    end,
    get = function(id) return rs.runs[id] end,
}
local onCall, foreign, bucket = {}, {}, {}
CP.Calls = { isOnCall = function(src) return onCall[src] == true end }
CP.Alerts = {
    foreignFlag = function(src) return foreign[src] == true end,
    inArena = function(src) return foreign[src] == true or (bucket[src] or 0) ~= 0 end,
}
-- FiveM server natives the harness does not provide.
GetPlayerRoutingBucket = function(src) return bucket[tonumber(src)] or 0 end
TriggerLatentClientEvent = function(name, target, bps, ...)
    H.events[#H.events + 1] = { kind = 'latent', name = name, target = target, bps = bps, args = { ... } }
end
local opLocked = false
CP.Operations = {
    isLocked = function() return opLocked end,
    boardCard = function(src)
        return { id = 7, missionLabel = 'Op Mission', launcher = 'Sgt X', status = 'joining', joined = 1, max = 8, joinedByMe = false, canJoin = true, joinEndsIn = 120 }
    end,
}
CP.Permissions = {
    can = function(src, action)
        if src == 9 then return true end
        return false, 'err.no_permission'
    end,
}
local audits = {}
CP.Admin = { audit = function(...) audits[#audits + 1] = { ... } end }

local customList = {}
local reloadCalls = 0
CP.Builder = {
    loadPublished = function() return customList end,
    onReload = function() reloadCalls = reloadCalls + 1; return { edited = 0 } end,
}

-- ── load the slice ──────────────────────────────────────────────────────────
H.load('modules/scaling/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/events/server.lua')
H.load('modules/missions/server.lua')
H.load('modules/draw/server.lua')

-- Helpers for net handlers.
local reqN = 0
local function act(name, src, payload)
    reqN = reqN + 1
    local id = 'q' .. reqN
    H.clockMs = H.clockMs + 2000
    H.fire('crimson-police:' .. name, src, payload, id)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end
local function cb(name, src, args)
    H.clockMs = H.clockMs + 2000
    return H.callback('crimson-police:' .. name, src, args)
end

local runN = 0
local function insertRun(cid, mtype, mid, state, reason, ts)
    runN = runN + 1
    H.sql("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base, created_at) VALUES (?, ?, ?, ?, 'sast', ?, ?, 100, FROM_UNIXTIME(?))",
        { ('uuid-%04d'):format(runN), mtype, mid, cid, state, reason, ts })
end

-- ═══ CP.Scaling ══════════════════════════════════════════════════════════════
do
    local S = CP.Scaling
    local names = { 'standard', 'reinforced', 'heavy', 'heavy', 'major', 'major', 'critical', 'critical', 'critical' }
    for n, name in ipairs(names) do H.eq(S.tierFor(n).tier, name, 'tierFor ' .. n) end
    H.eq(S.tierFor(0).tier, 'standard', 'tierFor 0')
    H.eq(S.tierFor(nil).tier, 'standard', 'tierFor nil')
    H.eq(S.tierByName('heavy').count, 1.5, 'tierByName')
    H.eq(S.tierByName('nope'), nil, 'tierByName unknown')
    H.eq(S.tierByName(Config.Scaling[2]), Config.Scaling[2], 'tierByName row')
    H.eq(S.lower('heavy', 'reinforced').tier, 'reinforced', 'lower')
    H.eq(S.lower(Config.Scaling[1], 'critical').tier, 'standard', 'lower rows')
    H.eq(S.lower(nil, 'major').tier, 'major', 'lower nil a')
    H.eq(S.lower('heavy', nil).tier, 'heavy', 'lower nil b')
    H.eq(S.label('heavy'), 'Heavy', 'label')
    H.eq(S.label(Config.Scaling[5]), 'Critical', 'label row')
    H.eq(S.scaleCount(7, 'reinforced'), 9, '7 x 1.25 = 8.75 -> 9')
    H.eq(S.scaleCount(7, 'heavy'), 11, '7 x 1.5 = 10.5 -> 11 (halves up)')
    H.eq(S.scaleCount(6, S.tierByName('heavy')), 9, '6 x 1.5')
    H.eq(S.scaleCount(3, 'critical'), 8, '3 x 2.5 = 7.5 -> 8')
    H.eq(S.scaleCount(20, 'standard'), 20, 'standard x1')

    local mission = {
        id = 'm', objectives = { { waves = { 7, 7, 6 } }, { suspects = 2, label = 'x' } },
        scaling = { 'objectives.1.waves', { path = 'objectives.2.suspects', max = 4 }, 'locations.1', 'objectives.2.label' },
    }
    local heavy = S.apply(mission, 'heavy')
    H.eq(heavy[1].waves[1], 11, 'apply list 1')
    H.eq(heavy[1].waves[3], 9, 'apply list 3')
    H.eq(heavy[2].suspects, 3, 'apply number')
    H.eq(heavy[2].label, 'x', 'non-number path untouched')
    local crit = S.apply(mission, 'critical')
    H.eq(crit[2].suspects, 4, 'max clamp')
    H.eq(crit[1].waves[1], 18, '7 x 2.5 = 17.5 -> 18')
    H.eq(mission.objectives[1].waves[1], 7, 'apply does not touch the mission')
    H.eq(S.apply(mission, 'standard')[1].waves[2], 7, 'standard unchanged')

    local acc, arm = S.combat(25, 0, 'heavy', nil)
    H.eq(acc, 35, 'combat accuracy'); H.eq(arm, 25, 'combat armour')
    acc, arm = S.combat(25, 0, 'heavy', { modifier = 'armored_hostiles', missionType = 'tactical' })
    H.eq(arm, 75, 'armored hostiles on tactical')
    acc, arm = S.combat(25, 0, 'heavy', { modifier = 'armored_hostiles', missionType = 'patrol' })
    H.eq(arm, 25, 'armored hostiles never outside tactical')
    acc, arm = S.combat(25, 10, 'standard', { modifier = 'armored_hostiles', mission = { type = 'tactical' } })
    H.eq(arm, 60, 'armored via run.mission.type')
    acc = S.combat(95, 0, 'critical')
    H.eq(acc, 100, 'accuracy clamped to 100')
end

-- ═══ CP.Schedule ═════════════════════════════════════════════════════════════
do
    local S = CP.Schedule
    H.eq(S.now(), T0, 'now')
    Config.Time.resetHour = 0
    H.eq(S.dayKey(T0), '2026-09-21', 'dayKey')
    H.eq(S.weekday(T0), 'monday', 'weekday')
    H.eq(S.dayStart(T0), os.time({ year = 2026, month = 9, day = 21, hour = 0 }), 'dayStart')
    H.eq(S.weekStart(T0), os.time({ year = 2026, month = 9, day = 21, hour = 0 }), 'weekStart on monday')
    H.eq(S.weekStart(FRIDAY), os.time({ year = 2026, month = 9, day = 21, hour = 0 }), 'weekStart from friday')
    H.eq(S.weekKey(FRIDAY), '2026-09-21', 'weekKey')
    H.eq(S.weekday(FRIDAY), 'friday', 'weekday friday')
    H.eq(S.monthStart(T0), os.time({ year = 2026, month = 9, day = 1, hour = 0 }), 'monthStart')
    H.eq(S.sqlTime(os.time({ year = 2026, month = 9, day = 21, hour = 14, min = 5, sec = 9 })), '2026-09-21 14:05:09', 'sqlTime')

    -- resetHour 6: Monday 03:00 still belongs to Sunday; the week starts on the previous Monday 06:00
    Config.Time.resetHour = 6
    local mon3 = os.time({ year = 2026, month = 9, day = 21, hour = 3 })
    H.eq(S.dayKey(mon3), '2026-09-20', 'reset-adjusted day')
    H.eq(S.weekday(mon3), 'sunday', 'reset-adjusted weekday')
    H.eq(S.dayStart(mon3), os.time({ year = 2026, month = 9, day = 20, hour = 6 }), 'dayStart at resetHour')
    H.eq(S.weekStart(mon3), os.time({ year = 2026, month = 9, day = 14, hour = 6 }), 'weekStart before reset')
    H.eq(S.weekStart(os.time({ year = 2026, month = 9, day = 21, hour = 7 })), os.time({ year = 2026, month = 9, day = 21, hour = 6 }), 'weekStart after reset')
    H.eq(S.monthStart(os.time({ year = 2026, month = 10, day = 1, hour = 3 })), os.time({ year = 2026, month = 9, day = 1, hour = 6 }), 'monthStart before reset on the 1st')
    H.eq(S.monthStart(os.time({ year = 2026, month = 10, day = 1, hour = 9 })), os.time({ year = 2026, month = 10, day = 1, hour = 6 }), 'monthStart after reset')
    Config.Leaderboard.weekStartsOn = 'sunday'
    H.eq(S.weekKey(os.time({ year = 2026, month = 9, day = 23, hour = 12 })), '2026-09-20', 'weekStartsOn sunday')
    Config.Leaderboard.weekStartsOn = 'monday'
    Config.Time.resetHour = 0

    -- boundary listeners: fired once when the boundary passes, never on start
    local daily, weekly, monthly = {}, {}, {}
    S.onDaily(function(k) daily[#daily + 1] = k end)
    S.onWeekly(function(k, prev) weekly[#weekly + 1] = { k, prev } end)
    S.onMonthly(function(ts) monthly[#monthly + 1] = ts end)
    S.onDaily(function() error('listener failure is contained') end)
    H.eq(S.onDaily('not a function'), false, 'bad listener refused')
    local f = S._check(T0 + 60)
    H.ok(not f.daily and not f.weekly and not f.monthly, 'nothing fires within the same day (start was recorded at load)')
    H.eq(#daily, 0, 'no daily on start')
    local tue = os.time({ year = 2026, month = 9, day = 22, hour = 0, min = 0, sec = 20 })
    f = S._check(tue)
    H.ok(f.daily and not f.weekly, 'daily fired at midnight')
    H.eq(daily[1], '2026-09-22', 'daily gets the new day key')
    S._check(tue + 30)
    H.eq(#daily, 1, 'fired once')
    local nextMon = os.time({ year = 2026, month = 9, day = 28, hour = 0, min = 0, sec = 10 })
    f = S._check(nextMon)
    H.ok(f.daily and f.weekly and not f.monthly, 'weekly fired on monday')
    H.eq(weekly[1][1], '2026-09-28', 'weekly key')
    H.eq(weekly[1][2], os.time({ year = 2026, month = 9, day = 21, hour = 0 }), 'previous week start')
    local oct1 = os.time({ year = 2026, month = 10, day = 1, hour = 0, min = 0, sec = 5 })
    f = S._check(oct1)
    H.ok(f.monthly, 'monthly fired')
    H.eq(monthly[1], os.time({ year = 2026, month = 10, day = 1, hour = 0 }), 'monthly gets the month start')
    local nDaily = #daily
    f = S._check(T0)   -- the clock moving back never fires a reset
    H.ok(not f.daily and not f.weekly and not f.monthly, 'clock moved back: nothing fires')
    H.eq(#daily, nDaily, 'no daily on a backwards clock')
    H.eq(S._check(T0 + 30).daily, false, 'still the same day afterwards')

    -- retention job: archive old runs, purge old audit rows
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_mission_runs_archive')
    H.sql('DELETE FROM cp_audit')
    local old = os.time({ year = 2025, month = 8, day = 1, hour = 12 })
    insertRun('RET1', 'patrol', 'patrol_a', 'completed', 'completed', old)
    insertRun('RET1', 'patrol', 'patrol_b', 'completed', 'completed', old + 3600)
    insertRun('RET1', 'patrol', 'patrol_c', 'completed', 'completed', T0 - 86400)
    H.sql("INSERT INTO cp_audit (actor, role, action, created_at) VALUES ('console', 'console', 'old', FROM_UNIXTIME(?))", { T0 - 200 * 86400 })
    H.sql("INSERT INTO cp_audit (actor, role, action, created_at) VALUES ('console', 'console', 'new', FROM_UNIXTIME(?))", { T0 - 10 * 86400 })
    local res = S._runRetention(T0)
    H.eq(res.archived, 2, 'two old rows archived')
    H.eq(res.auditDeleted, 1, 'one old audit row deleted')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n, 1, 'recent row stays')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs_archive')[1].n, 2, 'archive holds the old rows')
    H.eq(H.sql("SELECT mission_id FROM cp_mission_runs_archive ORDER BY id LIMIT 1")[1].mission_id, 'patrol_a', 'archived content kept')
    res = S._runRetention(T0)
    H.eq(res.archived, 0, 'nothing more to archive')
    -- an id collision (AUTO_INCREMENT reset after a restore): the live row is kept, never deleted unarchived
    do
        local archivedId = H.sql('SELECT MIN(id) AS id FROM cp_mission_runs_archive')[1].id
        H.sql("INSERT INTO cp_mission_runs (id, run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base, created_at) VALUES (?, 'uuid-collide', 'patrol', 'patrol_z', 'RET2', 'sast', 'completed', 'completed', 100, FROM_UNIXTIME(?))",
            { archivedId, old + 7200 })
        res = S._runRetention(T0)
        H.eq(res.archived, 0, 'retention: a row whose id collides with an archived one is not deleted')
        H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_mission_runs WHERE run_uuid = 'uuid-collide'")[1].n, 1, 'retention: the colliding live row is kept')
        H.eq(H.sql("SELECT mission_id FROM cp_mission_runs_archive WHERE id = ?", { archivedId })[1].mission_id, 'patrol_a', 'retention: the archived row is untouched')
        H.sql("DELETE FROM cp_mission_runs WHERE run_uuid = 'uuid-collide'")
    end
    Config.Retention.runArchiveMonths = 0
    Config.Retention.auditDays = 0
    insertRun('RET1', 'patrol', 'patrol_a', 'completed', 'completed', old)
    res = S._runRetention(T0)
    H.eq(res.archived, 0, 'runArchiveMonths 0 = never')
    H.eq(res.auditDeleted, 0, 'auditDays 0 = keep')
    Config.Retention.runArchiveMonths = 12
    Config.Retention.auditDays = 180
    -- the daily reset runs the retention job (in its own thread, after the daily listeners)
    local nBefore = #daily
    f = S._check(T0 + 86400)
    H.ok(f.daily, 'next day fires')
    H.eq(#daily, nBefore + 1, 'daily listeners fired')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE created_at < FROM_UNIXTIME(?)', { T0 - 300 * 86400 })[1].n, 0, 'the old row was archived at the daily reset')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs_archive')[1].n, 3, 'archive holds it')
    S._check(T0 + 30)   -- back to the test day (clock moved back: nothing fires)
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_mission_runs_archive')
end

-- ═══ CP.Missions ═════════════════════════════════════════════════════════════
local summary
do
    local M = CP.Missions
    H.eq(cb('getMissionDefs', 5).error, 'err.not_ready', 'getMissionDefs before the first load')

    customList = {
        {   -- a full definition with loader fields
            id = 'custom_dock', label = 'Dock Raid', type = 'tactical', minOfficers = 2, maxOfficers = 4, timeLimit = 720,
            locations = {
                { label = 'Dock 1', start = { coords = vec3(90000.0, 0.0, 5.0), radius = 60.0 }, spawns = { vec4(90010.0, 0.0, 5.0, 0.0) }, evidence = { vec3(90020.0, 0.0, 5.0) } },
                { label = 'Dock 2', start = { coords = vec3(91000.0, 0.0, 5.0), radius = 60.0 }, spawns = { vec4(91010.0, 0.0, 5.0, 0.0) }, evidence = { vec3(91020.0, 0.0, 5.0) } },
                { label = 'Dock 3', start = { coords = vec3(92000.0, 0.0, 5.0), radius = 60.0 }, spawns = { vec4(92010.0, 0.0, 5.0, 0.0) }, evidence = { vec3(92020.0, 0.0, 5.0) } },
            },
            objectives = { { block = 'hostile_waves', label = 'Clear the dock', waves = { 6, 6 } }, { block = 'interact_points', label = 'Seize', points = 'evidence' } },
            scaling = { 'objectives.1.waves' },
            source = 'custom', version = 3, filePath = 'missions/custom/custom_dock.lua', editedInCode = 1, status = 'published',
        },
        { id = 'custom_file', filePath = 'missions/custom/custom_file.lua', version = 2 },          -- meta only: file read here
        { def = { id = 'custom_bad', label = 'Bad', type = 'nope', timeLimit = 600 }, meta = { version = 1 } },
        { id = 'patrol_a', label = 'Clash', type = 'patrol', timeLimit = 600, locations = { { start = { coords = vec3(1, 2, 3), radius = 5 } } }, objectives = { { block = 'checkpoint_route' } } },
        { id = 'custom_gone', filePath = 'missions/custom/custom_gone.lua', version = 1 },
    }

    summary = M.loadAll()
    H.eq(summary.builtin, 8, 'eight built-in missions loaded')
    H.eq(summary.custom, 2, 'two custom missions loaded')
    H.eq(summary.loaded, 10, 'loaded total')
    local failedIds = {}
    for _, f in ipairs(summary.failed) do failedIds[tostring(f.id)] = f.error end
    for _, id in ipairs({ 'bad_block', 'bad_twice', 'bad_id', 'bad_syntax', 'bad_validate', 'bad_type', 'bad_runtime', 'bad_sandbox', 'missing_file', 'custom_bad', 'patrol_a', 'custom_gone' }) do
        H.ok(failedIds[id] ~= nil, 'rejected: ' .. id)
    end
    H.ok(failedIds.bad_block:find('unknown block', 1, true), 'unknown block reason')
    H.ok(failedIds.bad_twice:find('exactly one', 1, true), 'two RegisterMission calls')
    H.ok(failedIds.bad_id:find('does not match', 1, true), 'id mismatch')
    H.ok(failedIds.bad_syntax:find('syntax', 1, true), 'syntax error')
    H.ok(failedIds.bad_validate:find('spawns missing', 1, true), 'block validate reason')
    H.ok(failedIds.bad_type:find('Config.MissionTypes', 1, true), 'bad type')
    H.ok(failedIds.bad_sandbox:find('os', 1, true), 'sandbox has no os')
    H.ok(failedIds.missing_file:find('not found', 1, true), 'missing file')
    H.ok(failedIds.patrol_a:find('already uses', 1, true), 'custom id clash with a built-in')
    H.ok(summary.warnings > 0, 'warnings counted')

    local tac = M.get('tac_one')
    H.ok(tac ~= nil, 'tac_one loaded')
    H.eq(tac.payout, nil, 'payout field ignored')
    H.eq(tac.cashBase, nil, 'cashBase field ignored')
    H.eq(tac.source, 'builtin', 'source')
    H.eq(tac.filePath, 'missions/builtin/tac_one.lua', 'filePath')
    H.eq(tac.defHash, U.hashHex(files['missions/builtin/tac_one.lua']), 'defHash of the file content')
    H.eq(tac.isBoss, false, 'not the boss')
    H.eq(tac.status, 'published', 'status')
    H.eq(tac.editedInCode, false, 'editedInCode default')
    H.eq(tac.version, nil, 'built-in has no version')
    H.eq(tac.vehiclePenalties, false, 'vehiclePenalties kept')
    H.eq(tac.startTimeout, Config.Limits.startTimeout, 'startTimeout default')
    H.eq(tac.objectives[1].minSeconds, 60, 'hostile_waves default minSeconds')
    H.eq(tac.objectives[1].presenceRange, Config.Blocks.hostile_waves.presenceRange[3], 'presenceRange default from config/blocks.lua')
    H.eq(tac.objectives[1].waves[1], 7, 'block defaults applied')
    H.eq(tac.objectives[2].minSeconds, 8, 'file minSeconds kept')
    H.eq(tac.objectives[2].use, 'all', 'second block defaults')
    H.eq(#tac.scaling, 2, 'invalid scaling entries dropped')
    H.eq(tac.scaling[1], 'objectives.1.waves', 'scaling path kept')
    H.eq(tac.scaling[2].max, 4, 'scaling max kept')
    H.eq(#tac.items, 1, 'invalid item dropped')
    H.eq(#tac.bonuses, 2, 'bonus without value dropped')
    H.eq(tac.bonuses[2].id, 'racer_detained', 'explicit-value extra kept')
    H.eq(tac.bonuses[2].each, true, 'each kept')
    H.eq(#tac.penalties, 1, 'penalty kept')
    H.eq(tac.description, 'Test mission', 'description')

    local boss = M.get('weekly_boss_kingpin')
    H.eq(boss.isBoss, true, 'boss flagged')
    local tacList = M.byType('tactical')
    H.eq(#tacList, 2, 'byType tactical: tac_one + custom_dock, never the boss')
    for _, d in ipairs(tacList) do H.ok(not d.isBoss, 'byType excludes the boss') end
    H.eq(#M.byType('patrol'), 4, 'byType patrol')
    local list = M.list()
    H.eq(#list, 10, 'list has every mission')
    for i = 2, #list do H.ok(list[i - 1].id < list[i].id, 'list sorted by id') end
    H.eq(U.count(M.all()), 10, 'all')
    M.all().patrol_a = nil
    H.ok(M.get('patrol_a') ~= nil, 'all() returns a copy')

    local dock = M.get('custom_dock')
    H.eq(dock.source, 'custom', 'custom source')
    H.eq(dock.version, 3, 'custom version')
    H.eq(dock.editedInCode, true, 'editedInCode from the builder')
    H.ok(type(dock.defHash) == 'string' and #dock.defHash == 8, 'stable hash without a file')
    local cf = M.get('custom_file')
    H.eq(cf.version, 2, 'meta-only custom entry loaded from its file')
    H.eq(cf.defHash, U.hashHex(files['missions/custom/custom_file.lua']), 'custom defHash from the file')

    H.ok(M.isEnabled('patrol_d'), 'enabled')
    Config.DisabledMissions = { 'patrol_d' }
    H.ok(not M.isEnabled('patrol_d'), 'Config.DisabledMissions')
    Config.DisabledMissions = {}
    H.ok(not M.isEnabled('nope'), 'unknown id not enabled')

    -- broadcast and callback
    local pushes = H.findEvents('crimson-police:client:missions')
    H.ok(#pushes >= 1, 'definitions broadcast after load')
    H.eq(pushes[#pushes].target, -1, 'broadcast to everyone')
    H.eq(pushes[#pushes].kind, 'latent', 'the large list is sent as a latent event')
    H.ok((tonumber(pushes[#pushes].bps) or 0) > 0, 'latent event bandwidth set')
    H.eq(#pushes[#pushes].args[1], 10, 'full list')
    local reply = cb('getMissionDefs', 5)
    H.eq(reply.ok, true, 'getMissionDefs ok')
    H.eq(#reply.data, 10, 'getMissionDefs list')
    local sTac
    for _, d in ipairs(reply.data) do if d.id == 'tac_one' then sTac = d end end
    H.eq(getmetatable(sTac.locations[1].start.coords), nil, 'vectors serialized as plain tables')
    H.eq(sTac.locations[1].start.coords.x, 61000.0, 'vector x kept')
    H.eq(sTac.locations[1].spawns[1].w, 90.0, 'vec4 w kept')

    -- normalize (pure)
    local base = {
        id = 'norm_one', label = 'N', type = 'patrol', timeLimit = 300,
        locations = { { start = { coords = vec3(1.0, 2.0, 3.0), radius = 10.0 } } },
        objectives = { { block = 'checkpoint_route' } },
    }
    local n = M.normalize(base, { source = 'custom', version = '4' })
    H.ok(n ~= nil, 'minimal definition normalises')
    H.eq(n.minOfficers, 1, 'minOfficers default'); H.eq(n.maxOfficers, 1, 'maxOfficers default')
    H.eq(n.difficulty, Config.Blocks.details.difficulty[3], 'difficulty default')
    H.eq(n.cooldown, Config.Blocks.details.cooldown[3], 'cooldown default')
    H.eq(n.vehiclePenalties, true, 'vehiclePenalties default')
    H.eq(n.version, 4, 'custom version from meta')
    H.eq(n.objectives[1].minSeconds, 20, 'checkpoint_route minSeconds default')
    H.eq(n.objectives[1].presenceRange, 300, 'checkpoint_route presenceRange default')
    H.eq(n.objectives[1].label, 'Objective 1', 'objective label default')
    H.eq(n.locations[1].label, 'Location 1', 'location label default')
    H.eq(M.get('norm_one'), nil, 'normalize does not register')
    local function bad(patch, msg)
        local d = U.deepcopy(base)
        for k, v in pairs(patch) do d[k] = v end
        local r, err = M.normalize(d, {})
        H.ok(r == nil and type(err) == 'string', msg .. ' (' .. tostring(err) .. ')')
    end
    bad({ id = 'Bad Id' }, 'id pattern')
    bad({ label = '' }, 'label required')
    bad({ minOfficers = 3, maxOfficers = 2 }, 'min > max')
    bad({ maxOfficers = 9 }, 'max over unit size')
    bad({ difficulty = 4 }, 'difficulty range')
    bad({ timeLimit = 10 }, 'timeLimit range')
    bad({ timeLimit = false }, 'timeLimit must be a number')
    bad({ locations = {} }, 'locations required')
    bad({ locations = { { start = { radius = 5 } } } }, 'start coords required')
    bad({ objectives = {} }, 'objectives required')
    bad({ vehiclePenalties = 'yes' }, 'vehiclePenalties boolean')
    bad({ departments = 'sast' }, 'departments list')
    local v = M.normalize(U.deepcopy(base) , {})
    H.eq(v.source, 'builtin', 'default source')
    local d2 = U.deepcopy(base); d2.locations = { { start = vec3(5.0, 5.0, 5.0) } }; d2.departments = { sast = true }
    local n2 = M.normalize(d2, {})
    H.eq(n2.locations[1].start.radius, 50.0, 'bare vector start normalised')
    H.eq(n2.departments[1], 'sast', 'department map normalised to a list')
    local d3 = U.deepcopy(base); d3.id = 'weekly_boss_kingpin'; d3.type = 'patrol'
    local n3 = M.normalize(d3, {})
    H.eq(n3.type, 'tactical', 'boss is always tactical')
    H.eq(n3.isBoss, true, 'isBoss set by the loader')

    -- the loader fields are set before the blocks' validate(): built-in missions are exempt from the
    -- Mission Builder's allowed lists (the real blocks check mission.source == 'builtin')
    local seenSource, seenBoss = {}, {}
    CP.Blocks.register('strict_block', {
        validate = function(obj, mission, location)
            seenSource[#seenSource + 1] = mission.source
            seenBoss[#seenBoss + 1] = mission.isBoss
            if mission.source ~= 'builtin' and obj.model ~= 'allowed_ped' then return false, 'model not allowed' end
            return true
        end,
    })
    local sd = U.deepcopy(base); sd.objectives = { { block = 'strict_block', model = 's_m_y_prisoner_01' } }
    local sb = M.normalize(sd, { source = 'builtin' })
    H.ok(sb ~= nil, 'a built-in mission passes a block guardrail meant for custom missions')
    H.eq(seenSource[#seenSource], 'builtin', 'validate sees mission.source = builtin')
    H.eq(seenBoss[#seenBoss], false, 'validate sees mission.isBoss')
    local sc, scErr = M.normalize(U.deepcopy(sd), { source = 'custom' })
    H.ok(sc == nil and tostring(scErr):find('model not allowed', 1, true), 'the same file as a custom mission is held to the guardrail')
    H.eq(seenSource[#seenSource], 'custom', 'validate sees mission.source = custom')
    local sBoss = U.deepcopy(sd); sBoss.id = 'weekly_boss_kingpin'; sBoss.type = 'tactical'
    H.ok(M.normalize(sBoss, { source = 'builtin' }) ~= nil, 'the built-in Weekly Boss passes')
    H.eq(seenBoss[#seenBoss], true, 'validate sees the boss flag')

    -- mission items Crimson-Arena takes away are never mission items (docs/CRIMSON_ARENA.md rule 4)
    for _, name in ipairs({ 'armour', 'Bandage', 'ammo-9', 'WEAPON_PISTOL', 'weapon_stungun' }) do
        local di = U.deepcopy(base); di.items = { { name = 'radio', count = 1 }, { name = name, count = 1 } }
        local r, e = M.normalize(di, {})
        H.ok(r == nil and tostring(e):find('never be a mission item', 1, true), 'forbidden mission item ' .. name)
    end
    local okItems = U.deepcopy(base); okItems.items = { { name = 'radio', count = 2 }, { name = 'armoured_vest_box' } }
    local ni = M.normalize(okItems, {})
    H.ok(ni ~= nil and #ni.items == 2, 'ordinary item names are kept')

    -- no point of a location inside a no-build zone (docs/CRIMSON_ARENA.md rule 7)
    local dz = U.deepcopy(base); dz.locations = { { start = { coords = vec3(-282.0, -2030.0, 30.0), radius = 30.0 } } }
    local rz, ez = M.normalize(dz, {})
    H.ok(rz == nil and tostring(ez):find('Crimson-Arena lobby', 1, true), 'start inside the Crimson-Arena lobby rejected (' .. tostring(ez) .. ')')
    dz = U.deepcopy(base)
    dz.locations = { { start = { coords = vec3(1.0, 2.0, 3.0), radius = 10.0 }, spawns = { vec4(900.0, 0.0, 0.0, 0.0), vec4(2344.0, 2565.0, 46.0, 0.0) } } }
    rz, ez = M.normalize(dz, {})
    H.ok(rz == nil and tostring(ez):find('Trailer Park', 1, true) and tostring(ez):find('spawns', 1, true), 'a nested point inside the arena match zone rejected')
    dz.locations[1].spawns[2] = vec4(2344.0, 2800.0, 46.0, 0.0)   -- 235 m away: outside the 160 m zone
    H.ok(M.normalize(dz, {}) ~= nil, 'points outside every zone are fine')
    dz = U.deepcopy(base); dz.locations = { { start = { coords = vec3(470.0, -974.0, 30.0), radius = 30.0 } } }
    H.eq(M.normalize(dz, { source = 'builtin' }), nil, 'no-build zones apply to built-in missions too')

    -- parse: the loader sandbox for one file's source (used by the Mission Builder and CP.Testing)
    local raw, perr = M.parse(files['missions/builtin/tac_one.lua'], 'missions/builtin/tac_one.lua')
    H.ok(raw ~= nil and raw.id == 'tac_one', 'parse returns the raw definition (' .. tostring(perr) .. ')')
    H.eq(raw.payout, 5000, 'parse does not normalise (raw fields kept)')
    H.eq(M.get('tac_one').payout, nil, 'the registry copy is still normalised')
    local _, e1 = M.parse("error('x')", '@missions/custom/x.lua')
    H.ok(tostring(e1):find('missions/custom/x.lua:1', 1, true) and not tostring(e1):find('@', 1, true), 'chunk name with or without @')
    local p2, e2 = M.parse(files['missions/builtin/bad_twice.lua'], 'missions/builtin/bad_twice.lua')
    H.ok(p2 == nil and tostring(e2):find('exactly one', 1, true), 'parse: one RegisterMission call')
    H.eq(M.parse('', 'x.lua'), nil, 'parse: empty source')
    H.eq(M.parse("os.exit(1)", 'x.lua'), nil, 'parse: sandboxed')

    -- register / unregister
    H.reset()
    local reg = M.register({ id = 'custom_new', label = 'New', type = 'patrol', minOfficers = 1, maxOfficers = 2, timeLimit = 400,
        locations = { { start = { coords = vec3(3.0, 3.0, 3.0), radius = 20.0 } } }, objectives = { { block = 'checkpoint_route' } }, version = 1 })
    H.ok(reg ~= nil and M.get('custom_new') == reg, 'register adds the mission')
    H.eq(reg.source, 'custom', 'registered as custom')
    H.eq(#H.findEvents('crimson-police:client:missions'), 1, 'register broadcasts')
    H.eq(#M.byType('patrol'), 5, 'joins its type pool')
    local nope, why = M.register({ id = 'patrol_b', label = 'x', type = 'patrol', timeLimit = 300, locations = base.locations, objectives = base.objectives })
    H.ok(nope == nil and why:find('built-in', 1, true), 'register cannot replace a built-in')
    H.eq(M.register({ id = 'x' }), nil, 'register rejects invalid')
    local claimed = M.register({ id = 'custom_claims', label = 'Claims', type = 'patrol', minOfficers = 1, maxOfficers = 1, timeLimit = 400,
        locations = { { start = { coords = vec3(4.0, 4.0, 4.0), radius = 20.0 } } }, objectives = { { block = 'checkpoint_route' } },
        version = 2, source = 'builtin' })
    H.eq(claimed and claimed.source, 'custom', 'a registered definition claiming source = builtin is still custom (builder guardrails apply)')
    H.eq(claimed and claimed.version, 2, 'with its version')
    M.unregister('custom_claims')
    H.eq(M.unregister('patrol_b'), false, 'built-ins cannot be unregistered')
    H.eq(M.unregister('custom_new'), true, 'unregister custom')
    H.eq(M.get('custom_new'), nil, 'gone')
    H.eq(M.unregister('custom_new'), false, 'unregister twice')

    -- reload (builder hook first) and the admin action
    local before = reloadCalls
    local rsum = M.reload()
    H.eq(reloadCalls, before + 1, 'reload calls CP.Builder.onReload')
    H.eq(rsum.builder.edited, 0, 'builder result in the summary')
    H.eq(rsum.loaded, 10, 'reload loads again')
    local ok, data = act('server:admin:reloadMissions', 9, nil)
    H.eq(ok, true, 'admin reload ok')
    H.eq(data.loaded, 10, 'admin reload summary')
    H.ok(#data.failed >= 9, 'admin reload lists rejected missions')
    H.eq(audits[#audits][4], 'reloadMissions', 'reload audited')
    H.eq(audits[#audits][2], 'admin', 'audit role')
    ok, data = act('server:admin:reloadMissions', 1, nil)
    H.eq(ok, false, 'officer cannot reload')
    H.eq(data, 'err.no_permission', 'no permission key')

    -- a failed builder hook never wipes the built-ins
    CP.Builder.loadPublished = function() error('db down') end
    local s2 = M.loadAll()
    H.eq(s2.builtin, 8, 'built-ins still load when the builder fails')
    H.ok(s2.builderError ~= nil, 'builder error reported')
    H.eq(s2.custom, 2, 'loaded custom missions are kept when the builder fails')
    H.ok(M.get('custom_dock') ~= nil, 'custom mission still in its pool')
    CP.Builder.loadPublished = function() return customList end
    M.loadAll()
    H.eq(U.count(M.all()), 10, 'custom missions back')
end

-- ═══ CP.Events ═══════════════════════════════════════════════════════════════
do
    local E = CP.Events
    local tod = E.typeOfTheDay('2026-09-21')
    H.ok(Config.MissionTypes[tod] ~= nil, 'type of the day is a mission type')
    H.eq(E.typeOfTheDay('2026-09-21'), tod, 'same day, same type (restart-safe)')
    H.eq(E.typeOfTheDay(), E.typeOfTheDay(CP.Schedule.dayKey()), 'default day key')
    local seen = {}
    for d = 1, 60 do seen[E.typeOfTheDay(('2026-%02d-%02d'):format(10 + (d > 30 and 1 or 0), (d - 1) % 30 + 1))] = true end
    H.ok(U.count(seen) >= 3, 'types rotate across days')
    Config.Events.typeOfTheDay = false
    H.eq(E.typeOfTheDay('2026-09-21'), nil, 'disabled')
    Config.Events.typeOfTheDay = true

    local mods = E.modifiers()
    H.eq(mods.armored_hostiles.label, 'modifier.armored_hostiles', 'modifier label key')
    H.eq(mods.armored_hostiles.tacticalOnly, true, 'armored is tactical only')
    H.eq(U.count(mods), 3, 'three modifiers')

    H.eq(E.rollModifier({ seed = 1, test = { adminSrc = 1 }, missionType = 'tactical' }), nil, 'never on tests')
    H.eq(E.rollModifier({ seed = 1, operationId = 3, missionType = 'tactical' }), nil, 'never on operations')
    H.eq(E.rollModifier({ seed = 1, isBoss = true, missionType = 'tactical' }), nil, 'never on the boss')
    H.eq(E.rollModifier(nil), nil, 'nil run')
    local counts, rolled = { tactical = {}, patrol = {} }, { tactical = 0, patrol = 0 }
    local N = 4000
    for _, t in ipairs({ 'tactical', 'patrol' }) do
        for s = 1, N do
            local m = E.rollModifier({ seed = s * 7919, missionType = t })
            if m then
                rolled[t] = rolled[t] + 1
                counts[t][m] = (counts[t][m] or 0) + 1
            end
        end
    end
    H.near(rolled.tactical / N, 0.25, 0.03, 'about 25% of tactical runs roll a modifier')
    H.near(rolled.patrol / N, 0.25, 0.03, 'about 25% of patrol runs roll a modifier')
    H.eq(counts.patrol.armored_hostiles, nil, 'armored hostiles never outside tactical')
    H.ok((counts.tactical.armored_hostiles or 0) > 0, 'armored hostiles on tactical')
    H.ok((counts.patrol.time_crunch or 0) > 0 and (counts.patrol.radio_silence or 0) > 0, 'other modifiers on patrol')
    H.eq(E.rollModifier({ seed = 12345, missionType = 'tactical' }), E.rollModifier({ seed = 12345, missionType = 'tactical' }), 'deterministic by seed')
    Config.Events.modifierChance = 0
    H.eq(E.rollModifier({ seed = 5, missionType = 'patrol' }), nil, 'chance 0')
    Config.Events.modifierChance = 0.25

    -- Weekly Boss availability (DB: once per officer per week)
    H.sql('DELETE FROM cp_mission_runs')
    insertRun('CIDA', 'tactical', 'weekly_boss_kingpin', 'abandoned', 'quit', FRIDAY - 3600)           -- used this week
    insertRun('CIDB', 'tactical', 'weekly_boss_kingpin', 'abandoned', 'real_call', FRIDAY - 3000)      -- exempt
    insertRun('CIDB', 'tactical', 'weekly_boss_kingpin', 'abandoned', 'cancelled', FRIDAY - 2900)      -- exempt
    insertRun('CIDC', 'tactical', 'weekly_boss_kingpin', 'completed', 'completed', WEEK_START - 3600)  -- last week
    -- Last Sunday's run that ended after Monday's reset: the row is dated this week but it was last
    -- week's attempt (rows are written when the run ends).
    insertRun('CIDD', 'tactical', 'weekly_boss_kingpin', 'completed', 'completed', WEEK_START + 600)

    local ok, why = E.bossAvailable(1, officers[1])
    H.eq(ok, false, 'not on a monday'); H.eq(why, 'err.boss_not_today', 'not today key')
    H.eq(E.bossCard(1), nil, 'no boss card on a monday')

    H.time = FRIDAY
    ok, why = E.bossAvailable(1, officers[1])
    H.eq(why, 'err.boss_used', 'used this week (quit)')
    H.eq(E.bossAvailable(2, officers[2]), true, 'real_call and cancelled do not use the attempt')
    H.eq(E.bossAvailable(3), true, 'last week does not count; officer looked up')
    H.eq(E.bossAvailable(4, officers[4]), true, 'a Sunday-night run that ended after the weekly reset uses last week\'s attempt')
    insertRun('CIDD', 'tactical', 'weekly_boss_kingpin', 'abandoned', 'idle', FRIDAY - 40000)          -- Friday 00:53
    H.eq(select(2, E.bossAvailable(4, officers[4])), 'err.boss_used', 'a Friday row uses the attempt')
    H.sql("DELETE FROM cp_mission_runs WHERE citizenid = 'CIDD'")
    H.eq(select(2, E.bossAvailable(77)), 'err.not_police', 'non-officer')
    opLocked = true
    H.eq(select(2, E.bossAvailable(2, officers[2])), 'err.operation_locked', 'hidden while an operation is active')
    H.eq(E.bossCard(2), nil, 'no boss card while an operation is active')
    opLocked = false
    Config.Events.weeklyBoss.enabled = false
    H.eq(select(2, E.bossAvailable(2, officers[2])), 'err.boss_disabled', 'disabled')
    Config.Events.weeklyBoss.enabled = true
    Config.DisabledMissions = { 'weekly_boss_kingpin' }
    H.eq(select(2, E.bossAvailable(2, officers[2])), 'err.boss_unavailable', 'boss mission turned off')
    Config.DisabledMissions = {}

    local card = E.bossCard(2)
    H.ok(card ~= nil, 'boss card on friday')
    H.eq(card.key, 'weekly_boss', 'boss key')
    H.eq(card.label, 'Label weekly_boss_kingpin', 'boss label from the mission')
    H.eq(card.points, 500, 'boss points from config')
    H.eq(card.cash[1], 2500, 'boss cash (fallback: event payout x tier)')
    H.eq(card.pool, 1, 'pool 1')
    H.eq(card.mode, 'solo', 'solo')
    H.eq(card.available, true, 'available')
    H.eq(card.locked, nil, 'not locked')
    H.eq(card.typeOfTheDay, E.typeOfTheDay() == 'tactical', 'ToD flag for tactical')
    H.eq(E.bossCard(1).locked.reason, 'Already attempted this week', 'own attempt used')
    setUnit({ 2, 1 })
    card = E.bossCard(2)
    H.eq(card.mode, 'unit', 'unit card')
    H.eq(card.cash[1], 2875, 'reinforced cash 2500 x 1.15')
    H.eq(card.locked.reason, 'Alice A already attempted it this week', 'member attempt used')
    H.eq(card.available, false, 'not available')
    clearUnits()
    rs.busy.tactical = true
    onCall[2] = true
    card = E.bossCard(2)
    H.eq(card.busy, true, 'busy when the tactical cap is reached')
    H.eq(card.onCall, true, 'on a call')
    rs.busy.tactical = nil
    onCall[2] = nil
    rs.cooldowns.CIDB = { types = {}, missions = { weekly_boss_kingpin = FRIDAY + 600 } }
    card = E.bossCard(2)
    H.eq(card.locked.reason, 'The Weekly Boss is on cooldown', 'mission cooldown lock')
    H.eq(card.locked['until'], FRIDAY + 600, 'cooldown until')
    rs.cooldowns.CIDB = nil
    rs.hourly.CIDB = 8
    card = E.bossCard(2)
    H.eq(card.locked and card.locked.reason, 'Hourly limit reached (8 completed runs per hour)', 'boss card: hourly cap lock')
    H.eq(card.available, false, 'boss card: not available at the hourly cap')
    rs.hourly.CIDB = nil
    setUnit({ 2, 3 })
    rs.hourly.CIDC = 8
    card = E.bossCard(2)
    H.eq(card.locked and card.locked.reason, 'Carl C reached the hourly limit (8 completed runs per hour)', 'boss card: member hourly cap')
    rs.hourly.CIDC = nil
    clearUnits()
    CP.Cash = { range = function(key, members) return 3000, 3000 end }
    H.eq(E.bossCard(2).cash[1], 3000, 'CP.Cash.range used when it knows the boss')
    CP.Cash = nil
    CP.Payouts = { baseFor = function(def) return 4000 end }
    H.eq(E.bossCard(2).cash[1], 4000, 'admin payout via CP.Payouts.baseFor')
    CP.Payouts = nil
    H.time = T0
end

-- ═══ CP.Draw ═════════════════════════════════════════════════════════════════
do
    local D = CP.Draw
    local A, B, C, Dd = officers[1], officers[2], officers[3], officers[4]
    local function ids(list)
        local out = {}
        for _, d in ipairs(list) do out[#out + 1] = d.id end
        table.sort(out)
        return table.concat(out, ',')
    end

    -- pools
    H.eq(ids(D.pool('patrol', { A })), 'patrol_a,patrol_b,patrol_c,patrol_d', 'solo patrol pool')
    H.eq(ids(D.pool('patrol', { A, B })), 'patrol_b,patrol_c,patrol_d', 'pool supports the unit size')
    H.eq(ids(D.pool('patrol', { 1, 2, 3 })), 'patrol_d', 'members as srcs')
    local p, reason = D.pool('investigation', { A })
    H.eq(#p, 0, 'investigation needs 2+'); H.eq(reason, 'board.locked_empty_solo', 'solo empty reason')
    H.eq(ids(D.pool('investigation', { B, Dd })), 'invest_fib', 'fib-only mission for an fib unit')
    p, reason = D.pool('investigation', { A, B })
    H.eq(#p, 0, 'not open to every department'); H.eq(reason, 'board.locked_empty', 'unit empty reason')
    H.eq(ids(D.pool('tactical', { A })), 'tac_one', 'boss never in the tactical pool')
    rs.cooldowns.CIDA = { types = {}, missions = { patrol_a = T0 + 600 } }
    H.eq(ids(D.pool('patrol', { A })), 'patrol_b,patrol_c,patrol_d', 'mission cooldown excludes')
    rs.cooldowns.CIDA = { types = {}, missions = { patrol_a = T0 + 600, patrol_b = T0 + 300, patrol_c = T0 + 900, patrol_d = T0 + 1200 } }
    local info
    p, reason, info = D.pool('patrol', { A })
    H.eq(reason, 'board.locked_mission_cooldown', 'all on cooldown')
    H.eq(info.cooldownUntil, T0 + 300, 'earliest cooldown end')
    rs.cooldowns.CIDA = { types = {}, missions = { patrol_a = T0 - 5 } }
    H.eq(#D.pool('patrol', { A }), 4, 'expired cooldown ignored')
    rs.cooldowns.CIDA = nil
    Config.DisabledMissions = { 'patrol_d' }
    H.eq(ids(D.pool('patrol', { A })), 'patrol_a,patrol_b,patrol_c', 'disabled missions excluded')
    Config.DisabledMissions = {}

    -- reservations
    H.eq(D.reserve('r1', 'patrol_a', 2), true, 'reserve free spot')
    H.ok(D.isReserved('patrol_a', 2), 'reserved')
    H.eq(D.reserve('test1', 'patrol_a', 2), false, 'a second holder (test run) can still reserve')
    D.release('r1')
    H.ok(D.isReserved('patrol_a', 2), 'still held by the test run')
    D.release('test1')
    H.ok(not D.isReserved('patrol_a', 2), 'released')
    H.eq(D.release('nobody'), false, 'release unknown')
    D.reserve('r2', 'patrol_a', 1)
    D.reserve('r2', 'patrol_a', 3)
    H.ok(not D.isReserved('patrol_a', 1) and D.isReserved('patrol_a', 3), 'one reservation per run')
    D.release('r2')
    H.eq(D.reserve(nil, 'patrol_a', 1), false, 'reserve needs a run id')

    -- pickLocation: reserved skipped, player clearance, fallback
    local pa = CP.Missions.get('patrol_a')
    for i = 1, 4 do D.reserve('res' .. i, 'patrol_a', i) end
    H.eq(D.pickLocation(pa, { 1 }, U.rng(3)), 5, 'only the free spot')
    D.reserve('res5', 'patrol_a', 5)
    H.eq(D.pickLocation(pa, { 1 }, U.rng(3)), nil, 'every spot reserved')
    Config.Limits.reserveLocations = false
    H.ok(D.pickLocation(pa, { 1 }, U.rng(3)) ~= nil, 'reserveLocations = false ignores reservations')
    Config.Limits.reserveLocations = true
    for i = 1, 5 do D.release('res' .. i) end
    H.players[50] = { coords = vec3(1010.0, 100.0, 30.0) }     -- a bystander 10 m from spot 1
    H.players[1] = { coords = vec3(2000.0, 100.0, 30.0) }      -- the participant on spot 2
    local picked = {}
    for s = 1, 200 do picked[D.pickLocation(pa, { 1 }, U.rng(U.hash('pick' .. s)))] = true end
    H.ok(not picked[1], 'spot with a non-participant nearby skipped')
    H.ok(picked[2], 'participant nearby does not block')
    H.ok(picked[3] and picked[4] and picked[5], 'other spots drawn')
    bucket[50] = 4210                                           -- the bystander is in Crimson-Arena
    picked = {}
    for s = 1, 200 do picked[D.pickLocation(pa, { 1 }, U.rng(U.hash('pick' .. s)))] = true end
    H.ok(picked[1], 'players in Crimson-Arena never block a spot')
    bucket[50] = nil
    for i = 2, 5 do D.reserve('res' .. i, 'patrol_a', i) end
    H.eq(D.pickLocation(pa, { 1 }, U.rng(9)), 1, 'the only free spot is used even with a bystander')
    for i = 2, 5 do D.release('res' .. i) end
    H.eq(D.pickLocation(pa, { 1 }, U.rng(3), { exclude = { [1] = true, [2] = true, [3] = true, [4] = true } }), 5, 'exclude option')
    H.players[50] = nil

    -- draw: no-repeat from DB history
    H.sql('DELETE FROM cp_mission_runs')
    insertRun('CIDA', 'patrol', 'patrol_a', 'completed', 'completed', T0 - 300)
    insertRun('CIDA', 'patrol', 'patrol_b', 'abandoned', 'quit', T0 - 200)
    insertRun('CIDA', 'patrol', 'patrol_c', 'failed', 'downed', T0 - 100)            -- failed: not a "last completed or abandoned"
    insertRun('CIDA', 'tactical', 'weekly_boss_kingpin', 'completed', 'completed', T0 - 50)
    insertRun('CIDA', 'goal', 'patrol_2', 'completed', 'completed', T0 - 40)
    local got = {}
    for s = 1, 60 do
        local def, idx = D.draw('patrol', { A }, { rng = U.rng(U.hash('draw' .. s)) })
        got[def.id] = true
        H.ok(idx >= 1 and idx <= 5, 'location index')
    end
    H.ok(got.patrol_c and got.patrol_d, 'large pool: the two others are drawn')
    H.ok(not got.patrol_a and not got.patrol_b, 'large pool (4+) skips the last two completed/abandoned')

    Config.Draw.largePool = 5
    got = {}
    for s = 1, 60 do got[D.draw('patrol', { A }, { rng = U.rng(U.hash('draw' .. s)) }).id] = true end
    H.ok(not got.patrol_b and got.patrol_a, 'small pool skips only the last one')
    Config.Draw.largePool = 4

    D.recordLast('CIDA', 'patrol', 'patrol_c')                 -- a row being written right now
    got = {}
    for s = 1, 60 do got[D.draw('patrol', { A }, { rng = U.rng(U.hash('draw' .. s)) }).id] = true end
    H.ok(got.patrol_a and got.patrol_d and not got.patrol_b and not got.patrol_c, 'recordLast bridges rows not yet in the DB')
    D.recordLast('CIDA', 'patrol', 'weekly_boss_kingpin')      -- ignored

    -- unit: union of every member's last mission
    insertRun('CIDB', 'patrol', 'patrol_d', 'completed', 'completed', T0 - 30)
    got = {}
    for s = 1, 40 do got[D.draw('patrol', { A, B }, { rng = U.rng(U.hash('draw' .. s)) }).id] = true end
    H.eq(ids((function() local l = {} for k in pairs(got) do l[#l + 1] = { id = k } end return l end)()), 'patrol_b', 'unit avoids A last (c) and B last (d)')

    -- only one eligible may repeat
    insertRun('CIDC', 'patrol', 'patrol_d', 'completed', 'completed', T0 - 20)
    H.eq(D.draw('patrol', { A, B, C }, { rng = U.rng(1) }).id, 'patrol_d', 'a pool of one repeats')

    -- histories covering the whole pool: relax to "not the unit's latest"
    Config.DisabledMissions = { 'patrol_d' }        -- unit A+B pool = { b, c }
    insertRun('CIDB', 'patrol', 'patrol_b', 'completed', 'completed', T0 - 10)   -- B's last = b, A's last = c (memory)
    got = {}
    for s = 1, 40 do got[D.draw('patrol', { A, B }, { rng = U.rng(U.hash('draw' .. s)) }).id] = true end
    H.ok(got.patrol_b and not got.patrol_c, 'relaxed: never the most recent mission of the unit (A: patrol_c just now)')
    Config.DisabledMissions = {}

    -- draw errors
    local none, err = D.draw('investigation', { A })
    H.eq(none, nil, 'no pool'); H.eq(err, 'err.pool_empty', 'pool empty key')
    rs.cooldowns.CIDA = { types = {}, missions = { patrol_a = T0 + 600, patrol_b = T0 + 300, patrol_c = T0 + 900, patrol_d = T0 + 1200 } }
    H.eq(select(2, D.draw('patrol', { A })), 'err.pool_cooldown', 'pool cooldown key')
    rs.cooldowns.CIDA = nil
    local tacDef = CP.Missions.get('tac_one')
    for i = 1, 5 do D.reserve('full' .. i, 'tac_one', i) end
    H.eq(select(2, D.draw('tactical', { A })), 'err.no_location', 'every location in use')
    for i = 1, 5 do D.release('full' .. i) end
    H.ok(tacDef ~= nil, 'tac_one exists')

    -- ── board ──────────────────────────────────────────────────────────────
    H.sql('DELETE FROM cp_mission_runs')
    H.players[1] = nil
    local board = D.boardCards(1)
    H.eq(#board.cards, 4, 'one card per mission type')
    local order = {}
    for i, c in ipairs(board.cards) do order[i] = c.key end
    H.eq(table.concat(order, ','), 'patrol,training,investigation,tactical', 'sorted by points')
    local pc = board.cards[1]
    H.eq(pc.label, 'Patrol', 'label'); H.eq(pc.points, 60, 'points')
    H.eq(pc.pool, 4, 'pool count'); H.eq(pc.mode, 'solo', 'solo')
    H.eq(pc.cash[1], 250, 'cash min (fallback)'); H.eq(pc.cash[2], 313, 'cash max with a modifier: 250 x 1.25 = 312.5 -> 313')
    H.eq(pc.locked, nil, 'patrol unlocked'); H.eq(pc.busy, false, 'not busy'); H.eq(pc.onCall, false, 'not on call')
    H.eq(pc.typeOfTheDay, CP.Events.typeOfTheDay() == 'patrol', 'ToD flag')
    H.eq(board.cards[2].pool, 2, 'training pool includes the custom mission')
    H.eq(board.cards[3].locked.reason, 'No Investigation missions available for you right now', 'solo locked reason')
    H.eq(board.boss, nil, 'no boss card on monday')
    H.eq(board.operation, nil, 'no operation')
    H.eq(board.unit.size, 1, 'unit size'); H.eq(board.unit.isLeader, true, 'solo leader')
    H.eq(board.activeRunId, nil, 'no active run')
    local todCount = 0
    for _, c in ipairs(board.cards) do if c.typeOfTheDay then todCount = todCount + 1 end end
    H.eq(todCount, 1, 'exactly one Type of the Day card')

    setUnit({ 1, 3, 2 })
    board = D.boardCards(3)
    H.eq(board.unit.size, 3, 'unit of 3'); H.eq(board.unit.isLeader, false, 'member is not leader')
    H.eq(board.cards[1].mode, 'unit', 'unit mode')
    H.eq(board.cards[1].pool, 1, 'unit of 3 pool')
    H.eq(board.cards[2].locked.reason, 'No Training missions for a unit of 3', 'locked reason text for a unit')
    H.eq(board.cards[1].cash[1], 325, 'heavy cash 250 x 1.30')
    clearUnits()

    rs.cooldowns.CIDA = { types = { tactical = T0 + 240 }, missions = {} }
    rs.busy.tactical = true
    rs.hourly.CIDA = 0
    onCall[1] = true
    rs.onMission[1] = true
    board = D.boardCards(1)
    local tc = board.cards[4]
    H.eq(tc.locked.reason, 'Tactical is on cooldown', 'type cooldown lock')
    H.eq(tc.locked['until'], T0 + 240, 'cooldown until')
    H.eq(tc.busy, true, 'Server busy')
    H.eq(board.cards[1].onCall, true, 'On a call')
    H.eq(board.activeRunId, 'active-1', 'active run id')
    rs.cooldowns.CIDA = nil; rs.busy.tactical = nil; onCall[1] = nil; rs.onMission[1] = nil

    rs.hourly.CIDA = 8
    H.eq(D.boardCards(1).cards[1].locked.reason, 'Hourly limit reached (8 completed runs per hour)', 'hourly cap lock')
    rs.hourly.CIDA = nil
    setUnit({ 2, 1 })
    rs.cooldowns.CIDA = { types = { patrol = T0 + 100 }, missions = {} }
    H.eq(D.boardCards(2).cards[1].locked.reason, 'Alice A has Patrol on cooldown', 'member cooldown lock')
    rs.cooldowns.CIDA = nil
    offDuty[1] = true
    H.eq(D.boardCards(2).cards[1].locked.reason, "A unit member can't take missions right now", 'member unavailable')
    offDuty[1] = nil
    clearUnits()

    CP.Cash = { range = function(key, members) return 1040, 1300 end }
    board = D.boardCards(1)
    H.eq(board.cards[4].cash[1], 1040, 'CP.Cash.range min'); H.eq(board.cards[4].cash[2], 1300, 'CP.Cash.range max')
    CP.Cash = nil
    CP.Scoring = { P = function(def) return 100 * def.difficulty end }
    H.eq(D.boardCards(1).cards[4].points, 300, 'points from CP.Scoring.P (best in the pool)')
    CP.Scoring = nil

    opLocked = true
    board = D.boardCards(1)
    H.eq(#board.cards, 0, 'operation: no type cards')
    H.eq(board.boss, nil, 'operation: no boss')
    H.eq(board.operation.id, 7, 'operation card only')
    opLocked = false

    H.time = FRIDAY
    board = D.boardCards(2)
    H.ok(board.boss ~= nil and board.boss.key == 'weekly_boss', 'boss card on friday')
    H.time = T0

    local reply = cb('getMissionTypes', 1)
    H.eq(reply.ok, true, 'getMissionTypes ok')
    H.eq(#reply.data.cards, 4, 'getMissionTypes cards')
    reply = cb('getMissionTypes', 77)
    H.eq(reply.ok, false, 'non-officer refused'); H.eq(reply.error, 'err.not_police', 'access error key')

    -- ── accept ─────────────────────────────────────────────────────────────
    local ok, data = act('server:acceptType', 1, 'traffic_stop')
    H.eq(data, 'err.invalid_type', 'unknown type')
    ok, data = act('server:acceptType', 1, { junk = true })
    H.eq(data, 'err.invalid_type', 'bad payload')
    ok, data = act('server:acceptType', 1, string.rep('x', 200))
    H.eq(data, 'err.invalid_type', 'oversized payload')
    ok, data = act('server:acceptType', 77, 'patrol')
    H.eq(data, 'err.not_police', 'non-officer')
    offDuty[1] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.not_on_duty', 'off duty')
    offDuty[1] = nil

    local unit = setUnit({ 1, 2 })
    ok, data = act('server:acceptType', 2, 'patrol')
    H.eq(data, 'err.not_leader', 'leader only')
    unit.locked = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.unit_locked', 'unit already accepted')
    unit.locked = false
    offDuty[2] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.member_unavailable', 'every member must be an officer')
    offDuty[2] = nil
    foreign[2] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.in_arena', 'foreign crimsonArena flag on a member')
    foreign[2] = nil
    bucket[2] = 4210
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.in_arena', 'a member in another routing bucket (CP.Alerts.inArena)')
    local alerts = CP.Alerts
    CP.Alerts = { foreignFlag = alerts.foreignFlag }
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.in_arena', 'routing bucket fallback without CP.Alerts.inArena')
    CP.Alerts = alerts
    bucket[2] = nil
    rs.onMission[2] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.member_on_run', 'member already on a run')
    rs.onMission[2] = nil
    onCall[2] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.member_on_call', 'member on a real call')
    onCall[2] = nil
    rs.hourly.CIDB = 8
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.member_hourly_cap', 'member hourly cap')
    rs.hourly.CIDB = nil
    rs.cooldowns.CIDB = { types = { patrol = T0 + 60 }, missions = {} }
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.member_type_cooldown', 'member type cooldown')
    rs.cooldowns.CIDB = nil
    H.eq(unit.locked, false, 'unit never locked by a refused accept')
    clearUnits()

    foreign[1] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.in_arena', 'own foreign flag')
    foreign[1] = nil
    rs.onMission[1] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.already_on_run', 'one active run')
    rs.onMission[1] = nil
    onCall[1] = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.on_call', 'on a real call')
    onCall[1] = nil
    rs.hourly.CIDA = 8
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.hourly_cap', 'hourly cap')
    rs.hourly.CIDA = nil
    rs.cooldowns.CIDA = { types = { patrol = T0 + 60 }, missions = {} }
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.type_cooldown', 'type cooldown')
    rs.cooldowns.CIDA = nil
    rs.busy.patrol = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.server_busy', 'server caps')
    rs.busy.patrol = nil
    opLocked = true
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.operation_locked', 'Cross-Department lock')
    opLocked = false
    ok, data = act('server:acceptType', 1, 'investigation')
    H.eq(data, 'err.pool_empty', 'empty pool')

    -- success (solo)
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'accept ok')
    H.eq(data.runId, 'run-1', 'run id returned')
    local opts = rs.created[1]
    H.eq(opts.missionType, 'patrol', 'create: missionType')
    H.eq(opts.leaderSrc, 1, 'create: leader')
    H.eq(#opts.members, 1, 'create: members'); H.eq(opts.members[1].citizenid, 'CIDA', 'create: officer tables')
    H.eq(opts.mission.type, 'patrol', 'create: drawn mission of the type')
    H.eq(opts.isBoss, false, 'create: not the boss')
    H.eq(opts.test, nil, 'create: not a test')
    H.ok(CP.Draw.isReserved(opts.mission.id, opts.locationIndex), 'location reserved for the run')
    CP.Draw.release('run-1')
    H.ok(not CP.Draw.isReserved(opts.mission.id, opts.locationIndex), 'provisional reservation was released')

    -- quick second accept: rate limited
    H.fire('crimson-police:server:acceptType', 1, 'patrol', 'fast1')
    H.fire('crimson-police:server:acceptType', 1, 'patrol', 'fast2')
    local lastReply = H.events[#H.events]
    H.eq(lastReply.args[1], 'fast2', 'reply to the second request')
    H.eq(lastReply.args[3], 'err.rate_limited', 'second accept inside 1.5 s is rate limited')

    -- unit success: locked, every member in the run
    unit = setUnit({ 1, 3 })
    local lockBefore = lockCalls
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'unit accept ok')
    H.eq(lockCalls, lockBefore + 1, 'CP.Units.lock called')
    H.eq(unit.locked, true, 'invites closed')
    local last = rs.created[#rs.created]
    H.eq(#last.members, 2, 'both members in the run')
    H.ok(last.mission.maxOfficers >= 2, 'mission supports the unit')

    -- create refuses -> unit unlocked, error passed through
    unit.locked = false
    rs.mode = 'fail'
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.create_refused', 'create error passed through')
    H.eq(unit.locked, false, 'unit unlocked after a failed create')
    rs.mode = 'error'
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.run_create_failed', 'create exception')
    H.eq(unit.locked, false, 'unit unlocked after a create exception')
    rs.mode = 'noreserve'
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'accept ok when the engine did not reserve')
    last = rs.created[#rs.created]
    H.ok(CP.Draw.isReserved(last.mission.id, last.locationIndex), 'draw reserves for the run as a fallback')
    rs.mode = 'ok'

    -- an invite accepted while the checks yield (docs/notes/teams.md): the locked unit would hold an
    -- officer who was never checked and is not on the run -> refused, unlocked, the leader tries again
    unit.locked = false
    local realHourly = CP.Runs.completionsLastHour
    CP.Runs.completionsLastHour = function(cid)
        if cid == 'CIDC' and #unit.members == 2 then
            unit.members = { 1, 3, 4 }   -- CP.Units.members hands out copies: a new list, not the checked one
            units[4] = unit
        end
        return 0
    end
    local createdBefore = #rs.created
    ok, data = act('server:acceptType', 1, 'patrol')
    CP.Runs.completionsLastHour = realHourly
    H.eq(ok, false, 'a unit that changed during the accept is refused')
    H.eq(data, 'err.busy', 'with err.busy (the leader accepts again)')
    H.eq(unit.locked, false, 'and unlocked again')
    H.eq(#rs.created, createdBefore, 'no run created')
    unit.members = { 1, 3 }
    units[4] = nil
    -- a member who left during the checks: refused the same way
    CP.Runs.completionsLastHour = function(cid)
        if cid == 'CIDC' and #unit.members == 2 then unit.members = { 1 }; units[3] = nil end
        return 0
    end
    ok, data = act('server:acceptType', 1, 'patrol')
    CP.Runs.completionsLastHour = realHourly
    H.eq(data, 'err.busy', 'a member who left during the accept: refused')
    H.eq(#rs.created, createdBefore, 'still no run')
    -- a forming unit (leader + pending invites) dissolves at lock: the leader goes solo and the accept goes on
    clearUnits()
    local forming = { id = 99, leader = 1, members = { 1 }, locked = false }
    units[1] = forming
    local realLock = CP.Units.lock
    CP.Units.lock = function(u) u.locked = true; lockCalls = lockCalls + 1; if u == forming then units[1] = nil end end
    ok, data = act('server:acceptType', 1, 'patrol')
    CP.Units.lock = realLock
    H.eq(ok, true, 'a forming unit dissolved by the lock still accepts (solo)')
    H.eq(#rs.created[#rs.created].members, 1, 'solo run')
    CP.Draw.release(data and data.runId)
    clearUnits()

    -- BoardData extras: the server clock for the countdowns and the Type of the Day multiplier
    local board2 = cb('getMissionTypes', 1).data
    H.eq(board2.serverTime, H.time, 'BoardData.serverTime = os.time()')
    H.eq(board2.todMultiplier, Config.Events.todMultiplier, 'BoardData.todMultiplier = Config.Events.todMultiplier')

    -- Weekly Boss
    ok, data = act('server:acceptType', 2, 'weekly_boss')
    H.eq(data, 'err.boss_not_today', 'boss only on its days')
    H.time = FRIDAY
    H.sql('DELETE FROM cp_mission_runs')
    insertRun('CIDA', 'tactical', 'weekly_boss_kingpin', 'abandoned', 'quit', FRIDAY - 3600)
    ok, data = act('server:acceptType', 1, 'weekly_boss')
    H.eq(data, 'err.boss_used', 'boss once per week')
    setUnit({ 2, 1 })
    ok, data = act('server:acceptType', 2, 'weekly_boss')
    H.eq(data, 'err.member_boss_used', 'every member needs the attempt')
    clearUnits()
    rs.cooldowns.CIDB = { types = { tactical = FRIDAY + 60 }, missions = {} }
    ok, data = act('server:acceptType', 2, 'weekly_boss')
    H.eq(ok, true, 'boss accept ok (a Tactical type cooldown does not block the event card)')
    rs.cooldowns.CIDB = nil
    last = rs.created[#rs.created]
    H.eq(last.mission.id, 'weekly_boss_kingpin', 'boss mission')
    H.eq(last.missionType, 'tactical', 'boss stored as tactical')
    H.eq(last.isBoss, true, 'isBoss passed')
    rs.busy.tactical = true
    ok, data = act('server:acceptType', 3, 'weekly_boss')
    H.eq(data, 'err.server_busy', 'boss counts toward the tactical cap')
    rs.busy.tactical = nil
    H.time = T0
end

-- ═══ CP.Missions client half ═════════════════════════════════════════════════
do
    local serverList = cb('getMissionDefs', 5).data
    local serverMissions = CP.Missions
    CP.Missions = nil
    local requests = 0
    local realRequest = CP.Net.request
    CP.Net.request = function(name)
        requests = requests + 1
        if name == 'getMissionDefs' then return { ok = true, data = U.deepcopy(serverList) } end
        return { ok = false, error = 'err.no_response' }
    end
    H.load('modules/missions/client.lua')
    local client = CP.Missions
    H.eq(client.get('tac_one'), nil, 'nothing before the request')
    H.advance(2000)
    H.eq(requests, 1, 'requested once on join')
    local def = client.get('tac_one')
    H.ok(def ~= nil, 'definition available')
    H.ok(getmetatable(def.locations[1].start.coords) ~= nil, 'coords rebuilt as a vector')
    H.eq(def.locations[1].spawns[1].w, 90.0, 'vec4 rebuilt with w')
    H.eq(def.locations[1].start.radius, 50.0, 'plain numbers untouched')
    H.eq(type(def.objectives[1].waves), 'table', 'plain lists untouched')
    H.eq(getmetatable(def.objectives[1].waves), nil, 'a list of numbers is not a vector')

    -- a push replaces the list
    local pushed = U.deepcopy(serverList)
    local keep = {}
    for _, d in ipairs(pushed) do if d.id ~= 'tac_one' then keep[#keep + 1] = d end end
    H.fire('crimson-police:client:missions', 0, keep)
    H.eq(client.get('tac_one'), nil, 'push replaced the definitions')
    H.ok(client.get('patrol_a') ~= nil, 'others still there')
    H.eq(client.get(42), nil, 'bad id')
    CP.Net.request = realRequest
    CP.Missions = serverMissions
end

-- ═══ Integration: the real built-in mission files with the real blocks ═══════
-- The blocks exempt built-in missions from the Mission Builder's allowed model lists
-- (mission.source == 'builtin'): Prison Break's inmates and the Kingpin's boss model must load.
do
    local fakeBlocks = CP.Blocks._list
    CP.Blocks._list = {}
    local blockIds = { 'checkpoint_route', 'escort', 'flee_arrest', 'hostile_waves', 'interact_points',
        'protect_rescue', 'pursuit', 'search_area', 'skill_check' }
    local allLoaded = true
    for _, b in ipairs(blockIds) do
        local ok, err = pcall(H.load, 'blocks/' .. b .. '/server.lua')
        if not ok then
            allLoaded = false
            print(('  (real-file check skipped: blocks/%s/server.lua does not load: %s)'):format(b, tostring(err)))
        end
    end
    if allLoaded then
        local M = CP.Missions
        local indexSrc = realLoad('Crimson-Police', 'missions/builtin/index.lua')
        local ids = assert(load(indexSrc, '@index', 't', {}))()
        H.eq(#ids, 14, 'index lists the 13 missions plus the Weekly Boss')
        local real = {}
        for _, id in ipairs(ids) do
            local path = 'missions/builtin/' .. id .. '.lua'
            local content = realLoad('Crimson-Police', path)
            local raw, perr = M.parse(content, path)
            H.ok(raw ~= nil and raw.id == id, 'real file parses: ' .. id .. ' (' .. tostring(perr) .. ')')
            if raw then
                local def, err = M.normalize(raw, { source = 'builtin', filePath = path, defHash = U.hashHex(content) })
                H.ok(def ~= nil, 'real built-in mission loads: ' .. id .. ' (' .. tostring(err) .. ')')
                real[id] = def
            end
        end
        H.ok(real.prison_break ~= nil, 'Prison Break loads with its prison-clothes models')
        H.ok(real.weekly_boss_kingpin ~= nil and real.weekly_boss_kingpin.isBoss == true, 'the Weekly Boss loads and is the boss')
        if real.gang_shootout then
            local heavy = CP.Scaling.apply(real.gang_shootout, 'heavy')
            H.eq(table.concat(heavy[1].waves, ','), '11,11,9', 'Gang Shootout at Heavy: 7/7/6 x 1.5, halves up')
            H.eq(real.gang_shootout.objectives[1].presenceRange, Config.Blocks.hostile_waves.presenceRange[3], 'real block presence default')
        end
    end
    CP.Blocks._list = fakeBlocks
end

return H
