-- Leaderboard metrics, levels and avatars on rows, the service record, stat goals and the new bounties (WP6).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then return end
    realPrint(line)
end

-- ============================================================================
--                                     TIME
-- ============================================================================
-- Wednesday 2026-09-23 12:00 (week of Mon 21 Sep, resetHour 0).

local function Ts(y, m, d, h) return os.time({ year = y, month = m, day = d, hour = h or 12, min = 0, sec = 0 }) end
local NOW = Ts(2026, 9, 23, 12)
local WEEK = Ts(2026, 9, 21, 0)
local LAST_MONTH = Ts(2026, 8, 20, 12)
H.time = NOW

-- ============================================================================
--                         DEPARTMENTS, OFFICERS, STUBS
-- ============================================================================

Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',
        short = 'SAST',
        jobs = { 'sast' },
        supervisorGrade = 3,
        theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235' },
    },
    fib = {
        label = 'Federal Investigation Bureau',
        short = 'FIB',
        jobs = { 'fib' },
        supervisorGrade = 3,
        theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' },
    },
}
Config.Leaderboard.minRunsToRank = 3
Config.Leaderboard.minDecisions = 10
Config.Leaderboard.weeklyBadges = { 'arrests' }
Config.Challenge.minRunsActive = 3

local officers = {}
local function Officer(src, cid, name, dept, callsign, sup)
    officers[src] = {
        src = src,
        citizenid = cid,
        name = name,
        department = dept,
        departmentLabel = Config.Departments[dept].label,
        departmentShort = Config.Departments[dept].short,
        job = dept,
        rank = sup and 'Sergeant' or 'Trooper',
        gradeLevel = sup and 3 or 1,
        callsign = callsign,
        onduty = true,
        isSupervisor = sup == true,
        isAdmin = false,
    }
end
CP.Access = {
    getOfficer = function(src)
        local o = officers[tonumber(src)]
        if not o then return nil, 'err.not_police' end
        return CP.U.copy(o)
    end,
    isAdmin = function(src) return tonumber(src) == 0 or IsPlayerAceAllowed(src, 'crimsonpolice.admin') == true end,
    isSupervisor = function(src)
        local o = officers[tonumber(src)]
        return o ~= nil and o.isSupervisor == true
    end,
    department = function(key)
        local d = Config.Departments[key]
        if not d then return nil end
        return { key = key, label = d.label, short = d.short, theme = { primary = d.theme.primary } }
    end,
    departments = function()
        local out = {}
        for _, k in ipairs({ 'fib', 'sast' }) do out[#out + 1] = CP.Access.department(k) end
        return out
    end,
}
CP.Qbx = {
    getInfo = function() return nil end,
    getByCitizenId = function() return nil end,
    onDutyChange = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
local audits = {}
CP.Admin = {
    audit = function(_, _, _, action, target) audits[#audits + 1] = { action = action, target = target } end,
    webhook = function() return true end,
}
CP.Tablet = { notify = function() end, push = function() end }
CP.Missions = {
    get = function(id)
        local labels = { beat_patrol = 'Beat Patrol', gang_shootout = 'Gang Shootout', evoc_course = 'EVOC Course' }
        return labels[id] and { label = labels[id] } or nil
    end,
}

H.load('modules/permissions/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/goals/server.lua')
H.load('modules/leaderboard/server.lua')
H.load('modules/challenge/server.lua')
H.load('modules/profile/server.lua')
local LB, C = CP.Leaderboard, CP.Challenge

local function Tick() H.clockMs = H.clockMs + 1001 end
local function Cb(name, src, args)
    Tick()
    return H.callback('crimson-police:' .. name, src, args)
end
local function Board(src, args)
    local res = Cb('getBoard', src, args)
    H.ok(res and res.ok, 'getBoard answers ' .. tostring(res and res.error))
    return res and res.data
end
local function ByCid(list, cid)
    for _, r in ipairs(list or {}) do if r.citizenid == cid then return r end end
    return nil
end
local function Order(rows)
    local out = {}
    for i, r in ipairs(rows or {}) do out[i] = r.citizenid end
    return table.concat(out, ',')
end

local function ClearAll()
    for _, t in ipairs({
        'cp_mission_runs',
        'cp_mission_runs_archive',
        'cp_officers',
        'cp_seasons',
        'cp_dept_bounties',
        'cp_badges',
        'cp_disputes',
    }) do
        H.sql('DELETE FROM ' .. t)
    end
    LB.invalidate()
    C.currentSeason(true)
end

local uuidN = 0
local function Row(t)
    uuidN = uuidN + 1
    local cols = {
        run_uuid = t.uuid or ('mrun-%04d'):format(uuidN),
        mission_type = t.type or 'patrol',
        mission_id = t.mission or 'beat_patrol',
        citizenid = t.cid,
        department = t.dept or 'sast',
        participants = t.p or 1,
        departments_n = 1,
        state = t.state or 'completed',
        end_reason = t.state == 'failed' and 'time_limit' or (t.state or 'completed'),
        points_base = 60,
        final_points = t.pts or 60,
        cash_paid = 0,
        cash_status = 'none',
        cash_base = 0,
        cash_multiplier = 1.0,
        flagged = t.flagged and 1 or 0,
        voided = t.voided and 1 or 0,
        duration_s = t.dur or 300,
        arrests = t.arrests or 0,
        citations = t.citations or 0,
        impounds = t.impounds or 0,
        rescues = t.rescues or 0,
        vehicles_stopped = t.stopped or 0,
        evidence = t.evidence or 0,
        decisions_ok = t.ok or 0,
        decisions_best = t.best or 0,
        decisions_bad = t.bad or 0,
        lethal = t.lethal or 0,
    }
    local names, vals, params = {}, {}, {}
    for k, v in pairs(cols) do names[#names + 1] = k; vals[#vals + 1] = '?'; params[#params + 1] = v end
    for _, k in ipairs({ 'season', 'call', 'response', 'medal' }) do
        if t[k] ~= nil then
            local col = ({ season = 'season_id', call = 'mission_call_id', response = 'response_s', medal = 'medal' })[k]
            names[#names + 1] = col
            vals[#vals + 1] = '?'
            params[#params + 1] = t[k]
        end
    end
    names[#names + 1] = 'created_at'
    vals[#vals + 1] = 'FROM_UNIXTIME(?)'
    params[#params + 1] = t.at or NOW
    local tbl = t.archive and 'cp_mission_runs_archive' or 'cp_mission_runs'
    if t.archive then names[#names + 1] = 'id'; vals[#vals + 1] = '?'; params[#params + 1] = 800000 + uuidN end
    H.sql(('INSERT INTO %s (%s) VALUES (%s)'):format(tbl, table.concat(names, ', '), table.concat(vals, ', ')), params)
end

local function OfficerRow(cid, name, dept, callsign, xp, hide, avatar)
    H.sql(
        [[INSERT INTO cp_officers (citizenid, display_name, callsign, rank_label, department, xp, hide_name, avatar_kind,
        avatar_value, avatar_status) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)]], {
            cid,
            name,
            callsign,
            'Trooper',
            dept,
            xp or 0,
            hide and 1 or 0,
            avatar and 'preset' or 'initials',
            avatar or '',
            'none',
        })
    if not avatar then H.sql('UPDATE cp_officers SET avatar_value = NULL WHERE citizenid = ?', { cid }) end
end

H.advance(2000)   -- listeners registered on the scheduler

-- ============================================================================
--                                   FIXTURES
-- ============================================================================
-- M1..M6 of SAST, F1/F2 of FIB. Only counted completed rows ever count for a stat metric.

ClearAll()
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
Officer(11, 'M1', 'Alpha One', 'sast', '2L-11')
Officer(12, 'M2', 'Bravo Two', 'sast', '2L-12')
Officer(13, 'M3', 'Charlie Three', 'sast', '2L-13')
Officer(14, 'M4', 'Delta Four', 'sast', '2L-14')
Officer(15, 'M5', 'Echo Five', 'sast', '2L-55')
Officer(16, 'M6', 'Foxtrot Six', 'sast', '2L-16')
OfficerRow('M1', 'Alpha One', 'sast', '2L-11', 500)
OfficerRow('M2', 'Bravo Two', 'sast', '2L-12', 1198)
OfficerRow('M3', 'Charlie Three', 'sast', '2L-13', 6000)
OfficerRow('M4', 'Delta Four', 'sast', '2L-14', 0)
OfficerRow('M5', 'Echo Five', 'sast', '2L-55', 40000, true, 'star')
OfficerRow('M6', 'Foxtrot Six', 'sast', '2L-16', 100, false, 'shield')

-- the season starts on Monday morning, so every row of this week is in it
H.time = WEEK + 3600
local okSeason, season = C.startSeason(0, 'Metrics Season')
H.eq(okSeason, true, 'season started')
H.time = NOW
local SID = season.id

-- M1: 3 counted completed rows (arrests 3, impounds 1, citations 2, rescues 1, 2 calls, 10 decisions, 60% Best)
Row({
    cid = 'M1',
    pts = 60,
    arrests = 2,
    impounds = 1,
    citations = 2,
    ok = 5,
    best = 3,
    bad = 0,
    call = 1,
    response = 80,
    season = SID,
    dur = 300,
    uuid = 'shared-1',
    p = 2,
    lethal = 2,
    medal = 1,
})
Row({
    cid = 'M1',
    pts = 60,
    arrests = 1,
    rescues = 1,
    ok = 4,
    best = 3,
    bad = 1,
    call = 2,
    response = 120,
    season = SID,
    dur = 200,
    uuid = 'shared-2',
    p = 2,
})
Row({ cid = 'M1', pts = 60, season = SID, dur = 250, uuid = 'shared-3', p = 2 })
-- rows that must count nowhere: abandoned, failed, voided and flagged
Row({ cid = 'M1', state = 'abandoned', pts = 0, arrests = 5, impounds = 3, call = 3, season = SID })
Row({
    cid = 'M1',
    state = 'failed',
    pts = 0,
    ok = 9,
    bad = 9,
    arrests = 4,
    mission = 'gang_shootout',
    dur = 100,
    season = SID,
})
Row({ cid = 'M1', voided = true, pts = 60, arrests = 7, ok = 20, best = 20, season = SID })
Row({ cid = 'M1', flagged = true, pts = 60, arrests = 7, ok = 20, best = 20, season = SID })
-- M2: arrests 4, 12 decisions all Best (100%)
Row({ cid = 'M2', pts = 50, arrests = 2, ok = 6, best = 6, season = SID, uuid = 'shared-1', p = 2 })
Row({ cid = 'M2', pts = 50, arrests = 2, ok = 6, best = 6, season = SID, uuid = 'shared-2', p = 2 })
Row({ cid = 'M2', pts = 50, season = SID })
-- M3: arrests 3 (ties M1; more points), 8 decisions (below minDecisions)
Row({ cid = 'M3', pts = 70, arrests = 3, ok = 8, best = 8, season = SID, uuid = 'shared-3', p = 2 })
Row({ cid = 'M3', pts = 70, season = SID })
Row({ cid = 'M3', pts = 70, season = SID })
-- M4: 10 arrests but only 2 completed runs this week (below minRunsToRank); 2 more in the archive
Row({ cid = 'M4', pts = 60, arrests = 5, season = SID })
Row({ cid = 'M4', pts = 60, arrests = 5, season = SID })
Row({ cid = 'M4', pts = 60, arrests = 1, archive = true, at = LAST_MONTH })
Row({ cid = 'M4', pts = 60, arrests = 1, archive = true, at = LAST_MONTH })
-- M5 (hidden name): 3 runs, 1 arrest
Row({ cid = 'M5', pts = 40, arrests = 1, season = SID })
Row({ cid = 'M5', pts = 40, season = SID })
Row({ cid = 'M5', pts = 40, season = SID })
-- M6: 60% Best like M1, but 20 decisions (more decisions win the tie)
Row({ cid = 'M6', pts = 10, ok = 10, best = 6, season = SID })
Row({ cid = 'M6', pts = 10, ok = 10, best = 6, season = SID })
Row({ cid = 'M6', pts = 10, season = SID })
-- M1 archive row from last month: counts all-time and in the service record, not this week
Row({
    cid = 'M1',
    pts = 60,
    arrests = 2,
    archive = true,
    at = LAST_MONTH,
    mission = 'evoc_course',
    dur = 150,
    medal = 2,
})

-- ============================================================================
--                                RANK BY METRIC
-- ============================================================================

local function MetricChecks(period)
    local tag = period .. ': '
    LB.invalidate()
    local b = Board(11, { period = period, metric = 'arrests' })
    H.eq(b.metric, 'arrests', tag .. 'the reply names its metric')
    H.eq(Order(b.rows), 'M2,M3,M1,M5,M6', tag .. 'arrests: most first, ties to more points')
    H.eq(ByCid(b.rows, 'M1').value, 3, tag .. 'arrests only from counted completed rows')
    H.eq(ByCid(b.rows, 'M2').value, 4, tag .. 'M2 has 4 arrests')
    H.eq(ByCid(b.rows, 'M4'), nil, tag .. 'below minRunsToRank is not ranked')
    local imp = Board(11, { period = period, metric = 'impounds' })
    H.eq(ByCid(imp.rows, 'M1').value, 1, tag .. 'the abandoned row\'s impounds count nowhere')
    local calls = Board(11, { period = period, metric = 'calls' })
    H.eq(ByCid(calls.rows, 'M1').value, 2, tag .. 'mission calls: completed rows claimed from a call')
    local cit = Board(11, { period = period, metric = 'citations' })
    H.eq(ByCid(cit.rows, 'M1').value, 2, tag .. 'citations')
    local res = Board(11, { period = period, metric = 'rescues' })
    H.eq(ByCid(res.rows, 'M1').value, 1, tag .. 'rescues')
    local mis = Board(11, { period = period, metric = 'missions' })
    H.eq(ByCid(mis.rows, 'M1').value, 3, tag .. 'missions: completed runs only')
    local j = Board(13, { period = period, metric = 'judgement' })
    H.eq(Order(j.rows), 'M2,M6,M1', tag .. 'judgement: Best share, more decisions win a tie, minDecisions')
    H.eq(ByCid(j.rows, 'M2').value, 100, tag .. 'M2 100% Best')
    H.eq(ByCid(j.rows, 'M1').value, 60, tag .. 'M1 60%: the failed row\'s decisions are left out')
    H.eq(j.me.citizenid, 'M3', tag .. 'the viewer\'s pinned row')
    H.eq(j.me.rank, 0, tag .. 'M3 has too few decisions: pinned, not ranked')
    H.eq(j.minDecisions, 10, tag .. 'judgement board names its minimum')
    local pts = Board(11, { period = period })
    H.eq(pts.metric, 'points', tag .. 'points is the default')
    H.eq(ByCid(pts.rows, 'M1').points, 180, tag .. 'points: voided and flagged rows excluded')
end
MetricChecks('weekly')
MetricChecks('monthly')
MetricChecks('season')

-- all-time: the archive union
do
    LB.invalidate()
    local b = Board(11, { period = 'alltime', metric = 'arrests' })
    H.eq(ByCid(b.rows, 'M4').value, 12, 'all-time: M4 ranks with its archived runs (4 completed, 12 arrests)')
    H.eq(ByCid(b.rows, 'M1').value, 5, 'all-time: M1 arrests include the archive')
    H.eq(b.rows[1].citizenid, 'M4', 'all-time arrests: M4 first')
    local x = Board(11, { period = 'alltime' })
    H.eq(ByCid(x.rows, 'M5').points, 40000, 'all-time points is XP')
end

-- a wrongful arrest (graded wrong: decisions_bad, never an arrest) leaves the arrests metric unchanged
do
    LB.invalidate()
    local before = ByCid(Board(11, { period = 'weekly', metric = 'arrests' }).rows, 'M2').value
    Row({ cid = 'M2', pts = 0, arrests = 0, bad = 1, season = SID })
    LB.invalidate()
    local after = ByCid(Board(11, { period = 'weekly', metric = 'arrests' }).rows, 'M2').value
    H.eq(after, before, 'a wrongful arrest adds no arrest')
end

-- invalid metric, and the cache key includes the metric
do
    local res = Cb('getBoard', 11, { period = 'weekly', metric = 'kills' })
    H.eq(res.error, 'err.invalid_metric', 'an unknown metric is refused')
    local res2 = Cb('getBoard', 11, { period = 'weekly', metric = 'lethal' })
    H.eq(res2.error, 'err.invalid_metric', 'kills are never a metric')
    LB.invalidate()
    local a1 = Board(11, { period = 'weekly', metric = 'arrests' })
    Row({ cid = 'M6', pts = 0, arrests = 50, impounds = 50, season = SID })   -- no invalidate: the cache holds
    local a2 = Board(11, { period = 'weekly', metric = 'arrests' })
    H.eq(Order(a2.rows), Order(a1.rows), 'the arrests board is served from its cache')
    local i2 = Board(11, { period = 'weekly', metric = 'impounds' })
    H.eq(i2.rows[1].citizenid, 'M6', 'another metric has its own cache entry')
    H.sql('DELETE FROM cp_mission_runs WHERE citizenid = ? AND arrests = 50', { 'M6' })
    LB.invalidate()
end

-- ============================================================================
--                      LEVELS, AVATARS, PRIVACY, NO KILLS
-- ============================================================================

do
    LB.invalidate()
    local b = Board(11, { period = 'weekly', metric = 'arrests' })
    local m2 = ByCid(b.rows, 'M2')
    H.eq(m2.level.n, 10, 'M2 at 1,198 XP is level 10')
    H.eq(m2.level.badge, 'bronze', 'level 10 is the Patrol Officer band (bronze)')
    local keys = {}
    for k in pairs(m2.level) do keys[#keys + 1] = k end
    table.sort(keys)
    H.eq(table.concat(keys, ','), 'badge,n', 'a row carries the level number and badge only')
    H.eq(m2.avatar.kind, 'initials', 'no picture: initials')
    H.eq(m2.avatar.initials, 'BT', 'initials of the name')
    H.eq(m2.avatar.frame, 'bronze', 'frame is the level badge')
    local m6 = ByCid(b.rows, 'M6')
    H.eq(m6.avatar.kind, 'preset', 'a preset picture is shown')
    H.eq(m6.avatar.value, 'shield', 'the preset id')
    local m5 = ByCid(b.rows, 'M5')
    H.eq(m5.name, '2L-55', 'a hidden name shows the callsign')
    H.eq(m5.avatar.kind, 'initials', 'a hidden name never shows the picture')
    H.eq(m5.avatar.initials, '2L', 'a hidden name shows the callsign\'s initials')
    H.eq(m5.avatar.value, nil, 'no picture value for a hidden name')
    local own = Board(15, { period = 'weekly', metric = 'arrests' })
    H.eq(ByCid(own.rows, 'M5').avatar.value, 'star', 'the officer sees their own picture')
    H.eq(ByCid(own.rows, 'M5').name, 'Echo Five', 'and their own name')
    -- kills never leave the server
    for _, payload in ipairs({
        Board(11, { period = 'weekly', metric = 'arrests' }),
        Board(11, { period = 'alltime' }),
        Cb('getProfile', 12, { citizenid = 'M1' }).data,
        Cb('getProfile', 11, nil).data,
    }) do
        local text = json.encode(payload)
        H.ok(text:find('lethal', 1, true) == nil and text:lower():find('kill', 1, true) == nil,
            'no kills in a board or profile payload')
    end
    -- the profile's level: the Config.XPLevels band of the number
    local p = Cb('getProfile', 11, { citizenid = 'M3' }).data
    H.eq(p.level.n, 25, 'M3 at 6,000 XP is level 25')
    H.eq(p.level.label, 'Senior Patrol', 'the band of level 25')
    H.eq(p.level.xp, 6000, 'LevelInfo.xp is the officer\'s XP')
    H.ok(p.level.levelXp <= 6000 and p.level.nextLevelXp > 6000, 'levelXp and nextLevelXp bracket the XP')
    local hiddenP = Cb('getProfile', 11, { citizenid = 'M5' }).data
    H.eq(hiddenP.name, '2L-55', 'a hidden profile shows the callsign')
    H.eq(hiddenP.avatar.kind, 'initials', 'and no picture')
end

-- ============================================================================
--                                SERVICE RECORD
-- ============================================================================

do
    -- rapid responses: the rapid_response bonus of a completed row (never an abandoned one)
    local RAPID = '{"points":{"bonuses":[{"id":"rapid_response","points":6}]}}'
    H.sql('UPDATE cp_mission_runs SET breakdown = ? WHERE run_uuid = ? AND citizenid = ?', { RAPID, 'shared-1', 'M1' })
    H.sql('UPDATE cp_mission_runs SET breakdown = ? WHERE citizenid = ? AND state = ?', { RAPID, 'M1', 'abandoned' })
    local life = LB.serviceRecord('M1')
    H.eq(life.rapidResponses, 1, 'service rapid responses: completed rows only')
    H.eq(life.completed, 4, 'service: 3 completed this week + 1 archived (voided and flagged left out)')
    H.eq(life.failed, 1, 'service: the failed row')
    H.eq(life.successRate, 80, 'service: 4 of 5 = 80%')
    H.eq(life.arrests, 5, 'service arrests: counted completed rows and the archive')
    H.eq(life.impounds, 1, 'service impounds: not the abandoned row')
    H.eq(life.decisionsOk, 9, 'service decisions ok')
    H.eq(life.decisionsBest, 6, 'service decisions best')
    H.eq(life.decisionsBad, 1, 'service decisions bad (not the failed row)')
    H.eq(life.calls, 2, 'service calls')
    H.eq(life.avgResponseS, 100, 'service average response (80 and 120)')
    H.eq(life.medals.gold, 1, 'one gold medal')
    H.eq(life.medals.silver, 1, 'one silver medal (archive)')
    local seasonRec = LB.serviceRecord('M1', SID)
    H.eq(seasonRec.completed, 3, 'season record: only the season\'s rows')
    H.eq(seasonRec.arrests, 3, 'season record arrests')
    local bests = LB.personalBests('M1')
    H.eq(#bests, 2, 'bests: only missions with a completed run (not the failed Gang Shootout)')
    local byId = {}
    for _, b in ipairs(bests) do byId[b.missionId] = b.durationS end
    H.eq(byId.beat_patrol, 200, 'fastest completed Beat Patrol')
    H.eq(byId.evoc_course, 150, 'archived EVOC Course counts')
    H.eq(byId.gang_shootout, nil, 'never a mission without a completed run')
    local partner = LB.favouritePartner('M1')
    H.eq(partner and partner.name, 'Bravo Two', 'favourite partner: 2 shared completed runs with M2')
    local own = Cb('getProfile', 11, nil).data
    H.eq(own.service.lifetime.arrests, 5, 'own profile carries the service record')
    H.eq(own.service.season.completed, 3, 'and the season one')
    H.near(own.cleanArrestRate, 71.4, 0.05, 'own clean-arrest rate: 5 ÷ (5 + 2)')
    local pub = Cb('getProfile', 12, { citizenid = 'M1' }).data
    H.eq(pub.cleanArrestRate, nil, 'the clean-arrest rate is on the own profile only')
    H.eq(pub.service.lifetime.completed, 4, 'a public profile shows the service record')
    H.eq(#pub.bests, 2, 'and the personal bests')
end

-- ============================================================================
--                             STAT AND CALL GOALS
-- ============================================================================

do
    local fired = {}
    CP.Hooks.on('goal:completed', function(cid, goalId) fired[#fired + 1] = cid .. ':' .. goalId end)
    local goals = Config.Goals
    Config.Goals = {
        dailyPoints = 50,
        weeklyPoints = 200,
        daily = { { id = 'arrests_2', label = 'Make 2 arrests', stat = 'arrests', count = 2 } },
        weekly = { { id = 'calls_2', label = 'Answer 2 calls', missionCall = true, count = 2 } },
    }
    CP.Goals.onRunCompleted('M1')
    CP.Goals.onRunCompleted('M1')
    local n = H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND mission_type = \'goal\'',
        { 'M1' })[1].n
    H.eq(tonumber(n), 2, 'the stat goal and the call goal each completed once')
    H.eq(#fired, 2, 'goal:completed fired once per goal')
    -- M6 has no arrest: a wrongful arrest (decisions_bad) never moves the arrests goal
    Row({ cid = 'M6', pts = 0, bad = 1, season = SID })
    CP.Goals.onRunCompleted('M6')
    local g = CP.Goals.forOfficer('M6')
    H.eq(g.daily.progress, 0, 'arrests_2: a wrongful arrest counts nothing')
    H.eq(g.daily.done, false, 'arrests_2 not done')
    -- an abandoned row's arrests never count for the goal
    Row({ cid = 'M6', state = 'abandoned', arrests = 3, season = SID })
    H.eq(CP.Goals.forOfficer('M6').daily.progress, 0, 'arrests_2: abandoned rows count nothing')
    Config.Goals = goals
    H.sql('DELETE FROM cp_mission_runs WHERE mission_type = \'goal\'')
    LB.invalidate()
end

-- ============================================================================
--                          MOST ARRESTS / MOST CALLS
-- ============================================================================
-- Per active officer (3+ completed runs this season): SAST has more arrests in total, FIB more per officer.

do
    Officer(21, 'F1', 'Fox One', 'fib', 'F-21')
    Officer(22, 'F2', 'Fox Two', 'fib', 'F-22')
    OfficerRow('F1', 'Fox One', 'fib', 'F-21', 0)
    OfficerRow('F2', 'Fox Two', 'fib', 'F-22', 0)
    for _ = 1, 3 do Row({ cid = 'F1', dept = 'fib', arrests = 3, call = 9, season = SID }) end
    for _ = 1, 3 do Row({ cid = 'F2', dept = 'fib', arrests = 1, season = SID }) end
    local before = H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n
    local ok, view = C.overrideBounty(0, 'most_arrests')
    H.eq(ok, true, 'bounty set to most arrests')
    H.eq(view.id, 'most_arrests', 'the bounty is most_arrests')
    H.eq(view.leaderKey, 'fib', 'FIB leads most arrests per active officer')
    local rates = {}
    for _, r in ipairs(view.rates) do rates[r.key] = r end
    H.eq(rates.fib.count, 12, 'FIB arrests (completed rows only)')
    H.eq(rates.sast.count, 21, 'SAST arrests: M1 3 + M2 4 + M3 3 + M4 10 + M5 1 (abandoned, failed, voided left out)')
    H.eq(rates.sast.activeOfficers, 5, 'SAST active officers: 3+ completed runs')
    local okCalls, callView = C.overrideBounty(0, 'most_calls')
    H.eq(okCalls, true, 'bounty set to most calls')
    H.eq(callView.leaderKey, 'fib', 'FIB leads most calls per active officer (3 ÷ 2 vs 2 ÷ 5)')
    for _, r in ipairs(callView.rates) do rates[r.key] = r end
    H.eq(rates.sast.count, 2, 'SAST calls: M1\'s two completed calls, not the abandoned one')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n, before, 'a bounty view writes no run row')
end

-- ============================================================================
--                  DEPARTMENT REPORT AND WEEKLY METRIC BADGES
-- ============================================================================

do
    local rep = C.deptReport('sast')
    local m1
    for _, o in ipairs(rep.officers) do if o.citizenid == 'M1' then m1 = o end end
    H.eq(m1.arrests, 3, 'report arrests: this week\'s counted completed rows')
    H.eq(m1.impounds, 1, 'report impounds')
    H.eq(m1.calls, 2, 'report calls')
    H.eq(m1.decisionsBest, 6, 'report Best decisions')
    H.eq(m1.decisionsOk + m1.decisionsBad, 10, 'report decisions in total')
    H.ok(json.encode(rep):find('lethal', 1, true) == nil, 'no kills in the report')
    -- an officer's activity lists their active commendations, the viewer's own ones marked
    Officer(17, 'S7', 'Sierra Seven', 'sast', '2L-77', true)
    OfficerRow('S7', 'Sierra Seven', 'sast', '2L-77', 0)
    H.sql([[INSERT INTO cp_commendations (citizenid, kind, citation, department, issued_by, issuer_role, created_at)
        VALUES (?, 'valor', 'Held the line at the bank.', 'sast', ?, 'supervisor', FROM_UNIXTIME(?))]],
        { 'M1', 'S7', NOW })
    H.sql([[INSERT INTO cp_commendations (citizenid, kind, citation, department, issued_by, issuer_role, created_at)
        VALUES (?, 'teamwork', 'Covered two shifts in a row.', 'sast', ?, 'admin', FROM_UNIXTIME(?))]],
        { 'M1', 'ADMIN1', NOW - 60 })
    local act = Cb('sup:getOfficerActivity', 17, { citizenid = 'M1' })
    H.ok(act and act.ok, 'the supervisor reads the officer\'s activity ' .. tostring(act and act.error))
    local cl = act.data.commendations or {}
    H.eq(#cl, 2, 'the activity lists the officer\'s commendations')
    H.eq(cl[1].mine, true, 'the supervisor\'s own commendation is marked')
    H.eq(cl[2].mine, false, 'an admin\'s is not')
    H.sql('DELETE FROM cp_commendations')
    -- next Monday: the week that ended gets "Top Arrests of the Week" (the badge is given once)
    local nextWeek = WEEK + 7 * 86400
    H.time = nextWeek + 3600
    LB._weeklyJob(WEEK, nextWeek)
    local badge = H.sql('SELECT citizenid FROM cp_badges WHERE badge_id = ?', { 'top_arrests_2026-09-21' })
    H.eq(#badge, 1, 'one Top Arrests of the Week badge')
    H.eq(badge[1] and badge[1].citizenid, 'F1', 'to the week\'s top arrester (F1: 9; M4 has too few runs)')
    H.eq(LB._weeklyMetricBadges(WEEK, nextWeek, '2026-09-21'), 0, 'a second run gives nothing')
    H.eq(LB.badgeLabel('top_arrests_2026-09-21'), 'profile.badge.top_metric', 'the badge has its own label')
    H.time = NOW
end

return H
