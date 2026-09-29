-- tests/boards_spec.lua · the boards slice: CP.Leaderboard (modules/leaderboard) and CP.Challenge
-- (modules/challenge). Pure ranking/calendar logic plus every SQL statement of both modules, run against
-- MariaDB cp_test through the harness (boards, profiles, hide-name, admin boards, stuck payments, the
-- weekly job and announcements; seasons, bounties, standings in all three scoring modes, week closing,
-- overrides, season end, champion banner, supervisor report and officer activity).
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

local logs = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then logs[#logs + 1] = line return end
    realPrint(line)
end

-- ── time: Wednesday 2026-09-23 12:00 (week of Mon 21 Sep, resetHour 0) ─────
local function ts(y, m, d, h, mi) return os.time({ year = y, month = m, day = d, hour = h or 12, min = mi or 0, sec = 0 }) end
local NOW = ts(2026, 9, 23, 12)
H.time = NOW
local WEEK = ts(2026, 9, 21, 0)
local LAST_WEEK = ts(2026, 9, 14, 0)

-- ── departments, officers, stubs ────────────────────────────────────────────
Config.Departments = {
    sast = { label = 'San Andreas State Troopers', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3,
        theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235' } },
    fib = { label = 'Federal Investigation Bureau', short = 'FIB', jobs = { 'fib' }, supervisorGrade = 3,
        theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' } },
}

local officers = {}   -- src -> officer (§3.1)
local function officer(src, cid, name, dept, callsign, sup)
    officers[src] = { src = src, citizenid = cid, name = name, department = dept, departmentLabel = Config.Departments[dept].label,
        departmentShort = Config.Departments[dept].short, job = dept, rank = sup and 'Sergeant' or 'Trooper', gradeLevel = sup and 3 or 1,
        callsign = callsign, onduty = true, isSupervisor = sup == true, isAdmin = false }
end

CP.Access = {
    getOfficer = function(src)
        local o = officers[tonumber(src)]
        if not o then return nil, 'err.not_police' end
        return CP.U.copy(o)
    end,
    isAdmin = function(src)
        if tonumber(src) == 0 then return true end
        return IsPlayerAceAllowed(src, 'crimsonpolice.admin') == true
    end,
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
        local keys = {}
        for k in pairs(Config.Departments) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for i, k in ipairs(keys) do out[i] = CP.Access.department(k) end
        return out
    end,
}
CP.Qbx = { getInfo = function() return nil end, getByCitizenId = function(cid) return cid == 'LB5' and 55 or nil end }
local audits, hooks, notes = {}, {}, {}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = { actor = actor, role = role, category = category, action = action, target = target, old = old, new = new, reason = reason }
    end,
    webhook = function(category, title, description, fields)
        hooks[#hooks + 1] = { category = category, title = title, description = description, fields = fields }
        return true
    end,
}
CP.Tablet = { notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end }
CP.Missions = { get = function(id) if id == 'gang_shootout' then return { label = 'Gang Shootout' } end return nil end }

H.load('modules/permissions/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/leaderboard/server.lua')
H.load('modules/challenge/server.lua')
local LB, C = CP.Leaderboard, CP.Challenge

-- ── helpers ─────────────────────────────────────────────────────────────────
local function tick() H.clockMs = H.clockMs + 1001 end   -- keeps CP.Net rate limits out of the way

local function cb(name, src, args)
    tick()
    local res = H.callback('crimson-police:' .. name, src, args)
    return res
end

local function act(name, src, payload)
    tick()
    H.reset()
    H.fire('crimson-police:' .. name, src, payload, 'rq')
    local ev = H.findEvents('crimson-police:client:actionResult')[1]
    if not ev then return nil end
    return ev.args[2], ev.args[3]
end

local function clearAll()
    for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive', 'cp_officers', 'cp_seasons', 'cp_dept_bounties', 'cp_badges', 'cp_disputes' }) do
        H.sql('DELETE FROM ' .. t)
    end
    LB.invalidate()
    CP.Challenge.currentSeason(true)   -- drop the cached season list too
end

local uuidN = 0
local function row(t)
    uuidN = uuidN + 1
    local cols = {
        run_uuid = t.uuid or ('run-%04d'):format(uuidN), mission_type = t.type or 'patrol', mission_id = t.mission or 'beat_patrol',
        citizenid = t.cid, department = t.dept or 'sast', participants = t.p or 1, departments_n = t.d or 1,
        state = t.state or 'completed', end_reason = t.reason or ((t.state == 'failed') and 'time_limit' or (t.state or 'completed')),
        points_base = 60, final_points = t.pts or 60, cash_paid = t.cash or 0, cash_status = t.cashStatus or 'none',
        cash_base = t.cashBase or 0, cash_multiplier = t.mult or 1.0,
        flagged = t.flagged and 1 or 0, voided = t.voided and 1 or 0,
    }
    local names, vals, params = {}, {}, {}
    for k, v in pairs(cols) do names[#names + 1] = k; vals[#vals + 1] = '?'; params[#params + 1] = v end
    if t.season then names[#names + 1] = 'season_id'; vals[#vals + 1] = '?'; params[#params + 1] = t.season end
    if t.breakdown then names[#names + 1] = 'breakdown'; vals[#vals + 1] = '?'; params[#params + 1] = t.breakdown end
    names[#names + 1] = 'created_at'; vals[#vals + 1] = 'FROM_UNIXTIME(?)'; params[#params + 1] = t.at or NOW
    local tbl = t.archive and 'cp_mission_runs_archive' or 'cp_mission_runs'
    if t.archive then names[#names + 1] = 'id'; vals[#vals + 1] = '?'; params[#params + 1] = 900000 + uuidN end
    H.sql(('INSERT INTO %s (%s) VALUES (%s)'):format(tbl, table.concat(names, ', '), table.concat(vals, ', ')), params)
    return tonumber(H.sql('SELECT MAX(id) AS id FROM ' .. tbl)[1].id)
end

local function officerRow(cid, name, dept, callsign, xp, hide)
    H.sql('INSERT INTO cp_officers (citizenid, display_name, callsign, rank_label, department, xp, hide_name) VALUES (?, ?, ?, ?, ?, ?, ?)',
        { cid, name, callsign or '', 'Trooper', dept, xp or 0, hide and 1 or 0 })
    if not callsign then H.sql('UPDATE cp_officers SET callsign = NULL WHERE citizenid = ?', { cid }) end
end

local function byCid(list, cid)
    for _, r in ipairs(list or {}) do if r.citizenid == cid then return r end end
    return nil
end

-- ── boot: listeners registered on the scheduler ─────────────────────────────
H.advance(2000)

-- ════════════════════════════════════════════════════════════════════════════
-- Part A · CP.Leaderboard
-- ════════════════════════════════════════════════════════════════════════════

-- pure ranking: points, fewer failed, earliest reached, citizenid
do
    local list = {
        { citizenid = 'B', points = 100, runs = 3, failed = 1, reachedTs = 10 },
        { citizenid = 'A', points = 100, runs = 3, failed = 1, reachedTs = 20 },
        { citizenid = 'C', points = 100, runs = 3, failed = 0, reachedTs = 30 },
        { citizenid = 'D', points = 200, runs = 3, failed = 5, reachedTs = 40 },
        { citizenid = 'E', points = 900, runs = 2, failed = 0, reachedTs = 1 },
        { citizenid = 'F', points = 100, runs = 3, failed = 1, reachedTs = 10 },
    }
    local ranked, all = LB._rankEntries(list, 3)
    H.eq(#ranked, 5, 'min runs keeps 5')
    H.eq(ranked[1].citizenid, 'D', 'most points first')
    H.eq(ranked[2].citizenid, 'C', 'tie: fewer failed')
    H.eq(ranked[3].citizenid, 'B', 'tie: reached first (then citizenid)')
    H.eq(ranked[4].citizenid, 'F', 'same reached: citizenid')
    H.eq(ranked[5].citizenid, 'A', 'reached later')
    H.eq(all.E.rank, 0, 'below min runs is unranked')
    H.eq(ranked[1].rank, 1, 'rank set')
end

clearAll()
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
officer(11, 'LB1', 'Alpha One', 'sast', '2L-11')
officer(12, 'LB2', 'Bravo Two', 'sast', '3L-01')
officer(13, 'LB3', 'Charlie Three', 'fib', 'F-13')
officer(14, 'LB4', 'Delta Four', 'fib', nil)
officer(15, 'LB5', 'Echo Five', 'sast', '2L-15')
officer(16, 'LB6', 'Foxtrot Six', 'sast', '2L-16')   -- no rows at all
officerRow('LB1', 'Alpha One', 'sast', '2L-11', 5000)
officerRow('LB2', 'Bravo Two', 'sast', '3L-01', 3000, true)
officerRow('LB3', 'Charlie Three', 'fib', 'F-13', 100)
officerRow('LB4', 'Delta Four', 'fib', nil, 0)
officerRow('LB5', 'Echo Five', 'sast', '2L-15', 9000)

local bd = { runId = 'x', missionLabel = 'Beat Patrol', missionType = 'patrol', result = 'failed', endReason = 'time_limit', test = false,
    tier = 'standard', payTier = 'standard', participants = 1, departments = 1, durationS = 300,
    points = { P = 60, bonuses = {}, penalties = {}, subtotal = 60, mTeam = 1, mCross = 1, mStreak = 1, capped = false, tod = false, failedShare = 0.5, final = 15 },
    cash = { B = 250, mTier = 1, mMod = 1, amount = 0, status = 'none' }, flagged = nil }

-- LB1: 195 pts, 3 runs, 1 failed, reached Mon 13:00
row({ cid = 'LB1', pts = 60, at = ts(2026, 9, 21, 10), cash = 250, cashStatus = 'paid' })
row({ cid = 'LB1', pts = 60, at = ts(2026, 9, 21, 11), cash = 250, cashStatus = 'paid' })
row({ cid = 'LB1', pts = 60, at = ts(2026, 9, 21, 12), cash = 250, cashStatus = 'paid' })
local lb1Failed = row({ cid = 'LB1', state = 'failed', pts = 15, at = ts(2026, 9, 21, 13), breakdown = bd })
row({ cid = 'LB1', type = 'manual_award', mission = 'manual_award', state = 'completed', reason = 'manual_award', pts = 0, p = 2, at = ts(2026, 9, 21, 9) })
local lb1Old = row({ cid = 'LB1', state = 'failed', pts = 10, at = ts(2026, 9, 20, 10) })   -- last week, older than 48 h
-- LB3: 195 pts, 3 runs, 0 failed
row({ cid = 'LB3', dept = 'fib', pts = 65, at = ts(2026, 9, 22, 9) })
row({ cid = 'LB3', dept = 'fib', pts = 65, at = ts(2026, 9, 22, 10) })
row({ cid = 'LB3', dept = 'fib', pts = 65, at = ts(2026, 9, 22, 11) })
-- LB4: 195 pts, 3 runs, 1 failed, reached Tue 15:00
row({ cid = 'LB4', dept = 'fib', pts = 60, at = ts(2026, 9, 22, 12) })
row({ cid = 'LB4', dept = 'fib', pts = 60, at = ts(2026, 9, 22, 13) })
row({ cid = 'LB4', dept = 'fib', pts = 60, at = ts(2026, 9, 22, 14) })
row({ cid = 'LB4', dept = 'fib', state = 'failed', pts = 15, at = ts(2026, 9, 22, 15) })
-- LB2 (hidden name): 320 pts incl. a unit + cross Tactical; voided and flagged rows are excluded
row({ cid = 'LB2', type = 'tactical', mission = 'gang_shootout', pts = 200, p = 2, d = 2, at = ts(2026, 9, 21, 15), cash = 1040, cashStatus = 'paid' })
row({ cid = 'LB2', pts = 60, at = ts(2026, 9, 21, 16) })
row({ cid = 'LB2', pts = 60, at = ts(2026, 9, 21, 17) })
local lb2Voided = row({ cid = 'LB2', pts = 500, voided = true, at = ts(2026, 9, 22, 8), cash = 300, cashStatus = 'paid' })
local lb2Flagged = row({ cid = 'LB2', pts = 400, flagged = true, at = ts(2026, 9, 22, 9), cashStatus = 'held' })
-- LB5: 2 runs this week + a big manual award (unranked weekly); 3 runs last week
row({ cid = 'LB5', pts = 60, at = ts(2026, 9, 22, 10) })
row({ cid = 'LB5', pts = 60, at = ts(2026, 9, 22, 11) })
row({ cid = 'LB5', type = 'manual_award', mission = 'manual_award', reason = 'manual_award', pts = 1000, at = ts(2026, 9, 22, 12) })
row({ cid = 'LB5', pts = 70, at = ts(2026, 9, 15, 10) })
row({ cid = 'LB5', pts = 70, at = ts(2026, 9, 15, 11) })
row({ cid = 'LB5', pts = 70, at = ts(2026, 9, 15, 12) })
-- LB3: three archived runs (count for all-time runs only)
row({ cid = 'LB3', dept = 'fib', pts = 10, at = ts(2025, 1, 5, 10), archive = true })
row({ cid = 'LB3', dept = 'fib', pts = 10, at = ts(2025, 1, 5, 11), archive = true })
row({ cid = 'LB3', dept = 'fib', pts = 10, at = ts(2025, 1, 5, 12), archive = true })

-- weekly overall
do
    local res = cb('getBoard', 14, { period = 'weekly', filter = 'overall' })
    H.ok(res.ok, 'getBoard ok')
    local b = res.data
    H.eq(b.period, 'weekly', 'period echoed')
    H.eq(#b.rows, 4, 'four officers ranked')
    H.eq(b.rows[1].citizenid, 'LB2', 'LB2 first (voided/flagged excluded)')
    H.eq(b.rows[1].points, 320, 'LB2 counted points')
    H.eq(b.rows[1].name, '3L-01', 'hidden name shows the callsign')
    H.eq(b.rows[2].citizenid, 'LB3', 'fewer failed wins the tie')
    H.eq(b.rows[3].citizenid, 'LB1', 'reached first wins the tie')
    H.eq(b.rows[3].failed, 1, 'failed runs counted')
    H.eq(b.rows[3].runs, 3, 'manual_award is not a run')
    H.eq(b.rows[4].citizenid, 'LB4', 'reached last')
    H.eq(b.me.rank, 4, 'me = own position')
    H.eq(b.me.name, 'Delta Four', 'me carries the own name')
    H.eq(b.rows[1].departmentShort, 'SAST', 'department short from config')
    H.eq(b.rows[1].cash, nil, 'no cash on public boards')
    H.eq(b.minRuns, 3, 'minRuns echoed')
    H.eq(b.window.from, WEEK, 'weekly window starts at the week reset')
end

-- top N smaller than the list: me pinned from outside the top
do
    Config.Leaderboard.topN = 2
    LB.invalidate()
    local b = cb('getBoard', 14, { period = 'weekly', filter = 'overall' }).data
    H.eq(#b.rows, 2, 'topN rows')
    H.eq(b.me.rank, 4, 'me outside the top is still returned')
    Config.Leaderboard.topN = 25
    -- viewer below the minimum: rank 0 with their numbers; viewer without rows: zero row
    local b5 = cb('getBoard', 15, { period = 'weekly' }).data
    H.eq(b5.me.rank, 0, 'unranked viewer rank 0')
    H.eq(b5.me.points, 1120, 'unranked viewer points (manual award counts on overall)')
    H.eq(b5.me.runs, 2, 'unranked viewer runs')
    local b6 = cb('getBoard', 16, {}).data
    H.eq(b6.me.rank, 0, 'no rows -> rank 0')
    H.eq(b6.me.points, 0, 'no rows -> 0 points')
    H.eq(b6.filter, 'overall', 'default filter')
end

-- filters (minimum 1 run to see the filtered sets)
do
    Config.Leaderboard.minRunsToRank = 1
    LB.invalidate()
    local tac = cb('getBoard', 11, { period = 'weekly', filter = 'tactical' }).data
    H.eq(#tac.rows, 1, 'tactical: one officer')
    H.eq(tac.rows[1].points, 200, 'tactical points only')
    local unit = cb('getBoard', 11, { period = 'weekly', filter = 'unit' }).data
    H.eq(#unit.rows, 1, 'unit: manual award with participants 2 does not count')
    H.eq(unit.rows[1].citizenid, 'LB2', 'unit: LB2')
    local cross = cb('getBoard', 11, { period = 'weekly', filter = 'cross' }).data
    H.eq(#cross.rows, 1, 'cross: one officer')
    local fib = cb('getBoard', 11, { period = 'weekly', filter = 'department', department = 'fib' }).data
    H.eq(#fib.rows, 2, 'department fib: two officers')
    H.eq(fib.department, 'fib', 'department echoed')
    local sast = cb('getBoard', 11, { period = 'weekly', filter = 'department' }).data
    H.eq(sast.department, 'sast', 'department filter defaults to the viewer department')
    H.eq(sast.rows[1].citizenid, 'LB5', 'manual award counts on the department board')
    H.eq(sast.rows[1].points, 1120, 'department board points')
    local patrol = cb('getBoard', 11, { period = 'weekly', filter = 'patrol' }).data
    H.eq(byCid(patrol.rows, 'LB5').points, 120, 'patrol board excludes the manual award')
    Config.Leaderboard.minRunsToRank = 3
    LB.invalidate()
end

-- monthly, season (none yet), all-time
do
    local m = cb('getBoard', 11, { period = 'monthly' }).data
    H.eq(m.rows[1].citizenid, 'LB5', 'monthly: LB5 with last week runs')
    H.eq(m.rows[1].points, 1330, 'monthly points')
    H.eq(m.window.from, ts(2026, 9, 1, 0), 'month window')
    local s = cb('getBoard', 11, { period = 'season' }).data
    H.eq(#s.rows, 0, 'no season: empty board')
    H.eq(s.season, nil, 'no season info')
    local a = cb('getBoard', 11, { period = 'alltime', filter = 'tactical' }).data
    H.eq(a.filter, 'overall', 'all-time is overall only')
    H.eq(a.rows[1].citizenid, 'LB5', 'all-time by XP')
    H.eq(a.rows[1].points, 9000, 'all-time points = xp')
    H.eq(byCid(a.rows, 'LB3').runs, 6, 'all-time runs include the archive')
    H.ok(byCid(a.rows, 'LB4') ~= nil, 'xp 0 with 3 runs is listed')
    H.eq(a.window, nil, 'no window for all-time')
end

-- validation
do
    H.eq(cb('getBoard', 11, { period = 'daily' }).error, 'err.invalid_period', 'bad period')
    H.eq(cb('getBoard', 11, { filter = 'swat' }).error, 'err.invalid_filter', 'bad filter')
    H.eq(cb('getBoard', 11, { filter = 'department', department = 'lspd' }).error, 'err.unknown_department', 'bad department')
    H.eq(cb('getBoard', 11, 'weekly').error, 'err.invalid_payload', 'bad args')
    H.eq(cb('getBoard', 99, {}).error, 'err.not_police', 'non-officer refused')
end

-- cache: a new row is invisible until the cache expires or is invalidated
do
    local before = cb('getBoard', 14, { period = 'weekly' }).data
    row({ cid = 'LB4', dept = 'fib', pts = 500, at = ts(2026, 9, 23, 9) })
    local cached = cb('getBoard', 14, { period = 'weekly' }).data
    H.eq(cached.updatedAt, before.updatedAt, 'served from cache')
    H.eq(cached.rows[1].citizenid, 'LB2', 'cached ranking')
    H.time = NOW + 61
    local fresh = cb('getBoard', 14, { period = 'weekly' }).data
    H.eq(fresh.rows[1].citizenid, 'LB4', 'refreshed after cacheSeconds')
    H.time = NOW
    H.sql('UPDATE cp_mission_runs SET voided = 1 WHERE citizenid = ? AND final_points = 500', { 'LB4' })
    LB.invalidate()
    local afterVoid = cb('getBoard', 14, { period = 'weekly' }).data
    H.eq(afterVoid.rows[1].citizenid, 'LB2', 'voided run gone after invalidate()')
end

-- season points
do
    H.eq(LB.seasonPoints('LB1'), 0, 'no season -> 0')
    H.eq(LB.seasonPoints('bad id!'), 0, 'invalid citizenid -> 0')
end

-- profile: own
do
    H.sql("INSERT INTO cp_badges (citizenid, badge_id, earned_at) VALUES ('LB1', 'officer_of_week_2026-09-14', FROM_UNIXTIME(?)), ('LB1', 'iron_wheels', FROM_UNIXTIME(?))", { NOW - 86400, NOW - 3600 })
    local res = cb('getProfile', 11, nil)
    H.ok(res.ok, 'own profile ok')
    local p = res.data
    H.eq(p.own, true, 'own')
    H.eq(p.citizenid, 'LB1', 'own citizenid')
    H.eq(p.name, 'Alpha One', 'own name')
    H.eq(p.xp, 5000, 'xp')
    H.eq(p.level.label, 'Senior Patrol', 'xp level from Config.XPLevels')
    H.eq(p.level.next, 15000, 'next level')
    H.eq(#p.badges, 2, 'badges')
    local week = nil
    for _, b in ipairs(p.badges) do if b.kind == 'week' then week = b end end
    H.ok(week ~= nil, 'officer of the week badge labelled')
    H.eq(#p.runs, 6, 'every row of LB1')
    H.eq(p.runs[1].id, lb1Failed, 'newest first')
    local failed
    for _, r in ipairs(p.runs) do if r.id == lb1Failed then failed = r end end
    H.eq(failed.state, 'failed', 'failed row')
    H.eq(failed.canDispute, true, 'failed within 48 h can be disputed')
    H.eq(failed.breakdown.points.final, 15, 'breakdown from the row JSON')
    H.eq(failed.breakdown.cash.status, 'none', 'own breakdown keeps cash with the row status')
    local old
    for _, r in ipairs(p.runs) do if r.id == lb1Old then old = r end end
    H.eq(old.canDispute, false, 'older than the dispute window')
    local award
    for _, r in ipairs(p.runs) do if r.missionType == 'manual_award' then award = r end end
    H.eq(award.missionLabel, 'profile.manual_award', 'manual award labelled')
    H.eq(award.canDispute, false, 'award rows are never disputed')
    local paid
    for _, r in ipairs(p.runs) do if r.cash == 250 then paid = r end end
    H.eq(paid.cashStatus, 'paid', 'own cash status')
    -- an open dispute blocks another one
    H.sql("INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to) VALUES (?, 'LB1', 'x', 'admin')", { lb1Failed })
    local p2 = cb('getProfile', 11, { citizenid = 'LB1' }).data
    for _, r in ipairs(p2.runs) do if r.id == lb1Failed then H.eq(r.canDispute, false, 'open dispute blocks') end end
    H.eq(p2.own, true, 'own by citizenid')
    -- modules/disputes: one dispute per row, ever (a decided one is final: err.dispute_final)
    H.sql("UPDATE cp_disputes SET status = 'rejected', handled_at = NOW() WHERE run_id = ?", { lb1Failed })
    local p3 = cb('getProfile', 11, nil).data
    for _, r in ipairs(p3.runs) do if r.id == lb1Failed then H.eq(r.canDispute, false, 'a decided dispute is final') end end
    H.sql('DELETE FROM cp_disputes WHERE run_id = ?', { lb1Failed })
end

-- public profile: the breakdown keeps only RunResult fields without cash (no admin notes)
do
    H.sql("UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.reason', 'admin note') WHERE id = ?", { lb1Failed })
    local pub = cb('getProfile', 13, 'LB1').data
    local r
    for _, x in ipairs(pub.runs) do if x.id == lb1Failed then r = x end end
    H.eq(r.breakdown.cash, nil, 'no cash block in a public breakdown')
    H.eq(r.breakdown.reason, nil, 'no extra fields in a public breakdown')
    H.eq(r.breakdown.points.final, 15, 'public breakdown keeps the points')
    H.eq(r.breakdown.missionLabel, 'Beat Patrol', 'public breakdown keeps the label')
    local own = cb('getProfile', 11, nil).data
    for _, x in ipairs(own.runs) do if x.id == lb1Failed then r = x end end
    H.eq(r.breakdown.reason, 'admin note', 'the own breakdown is complete')
    H.sql("UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(breakdown, '$.reason') WHERE id = ?", { lb1Failed })
end

-- cache: invalidate() while a board query is in flight -> that result is not cached
do
    LB.invalidate()
    local realQuery = MySQL.query.await
    local boardQueries, injected = 0, false
    MySQL.query.await = function(sql, params)
        local res = realQuery(sql, params)
        if sql:find('GROUP BY r.citizenid', 1, true) and sql:find('r.created_at >= FROM_UNIXTIME', 1, true) then
            boardQueries = boardQueries + 1
            if not injected then
                injected = true
                LB.invalidate()   -- e.g. a void committed while this query ran
            end
        end
        return res
    end
    local ok1 = cb('getBoard', 13, { period = 'monthly' }).ok
    local ok2 = cb('getBoard', 13, { period = 'monthly' }).ok
    local ok3 = cb('getBoard', 13, { period = 'monthly' }).ok
    MySQL.query.await = realQuery
    H.ok(ok1 and ok2 and ok3, 'boards served')
    H.eq(boardQueries, 2, 'the board read before invalidate() was not cached; the next one was')
end

-- profile: someone else (hidden name, no cash, no breakdown cash)
do
    local p = cb('getProfile', 11, 'LB2').data
    H.eq(p.own, false, 'public profile')
    H.eq(p.name, '3L-01', 'hidden name on a public profile')
    H.eq(p.hideName, true, 'hideName flag')
    for _, r in ipairs(p.runs) do
        H.eq(r.cash, 0, 'no cash on a public profile')
        H.eq(r.cashStatus, '', 'no cash status on a public profile')
        H.eq(r.canDispute, false, 'never disputable on a public profile')
    end
    local tac
    for _, r in ipairs(p.runs) do if r.missionType == 'tactical' then tac = r end end
    H.eq(tac.missionLabel, 'Gang Shootout', 'mission label from CP.Missions')
    local own = cb('getProfile', 12, nil).data
    local flagged, voided
    for _, r in ipairs(own.runs) do
        if r.id == lb2Flagged then flagged = r end
        if r.id == lb2Voided then voided = r end
    end
    H.eq(flagged.flagged, true, 'flagged row')
    H.eq(flagged.canDispute, true, 'flagged can be disputed')
    H.eq(voided.voided, true, 'voided row')
    H.eq(voided.canDispute, true, 'voided can be disputed')
    H.eq(own.name, 'Bravo Two', 'own profile shows the own name even when hidden')
    H.eq(cb('getProfile', 11, 'NOPE').error, 'err.unknown_officer', 'unknown officer')
    H.eq(cb('getProfile', 11, { citizenid = 'bad id!' }).error, 'err.invalid_payload', 'invalid citizenid')
end

-- hide name toggle
do
    local ok, data = act('server:setHideName', 11, true)
    H.eq(ok, true, 'setHideName ok')
    H.eq(data.hideName, true, 'echo')
    H.eq(H.bit(H.sql("SELECT hide_name FROM cp_officers WHERE citizenid = 'LB1'")[1].hide_name), 1, 'stored')
    local b = cb('getBoard', 13, { period = 'weekly' }).data
    H.eq(byCid(b.rows, 'LB1').name, '2L-11', 'others see the callsign')
    local mine = cb('getBoard', 11, { period = 'weekly' }).data
    H.eq(byCid(mine.rows, 'LB1').name, 'Alpha One', 'own row keeps the own name')
    ok = act('server:setHideName', 11, { hideName = false })
    H.eq(ok, true, 'table payload')
    H.eq(H.bit(H.sql("SELECT hide_name FROM cp_officers WHERE citizenid = 'LB1'")[1].hide_name), 0, 'cleared')
    local bad, err = act('server:setHideName', 11, 'yes')
    H.eq(bad, false, 'invalid payload refused')
    H.eq(err, 'err.invalid_payload', 'invalid payload key')
    ok = act('server:setHideName', 16, true)
    H.eq(ok, true, 'officer without a row gets one')
    H.eq(H.bit(H.sql("SELECT hide_name FROM cp_officers WHERE citizenid = 'LB6'")[1].hide_name), 1, 'row created')
    local no, e2 = act('server:setHideName', 99, true)
    H.eq(no, false, 'non-officer refused')
    H.eq(e2, 'err.not_police', 'non-officer key')
end

-- admin boards: permission, cash, unranked, stuck payments, runs of one officer
do
    H.eq(cb('admin:getBoards', 11, {}).error, 'err.no_permission', 'officers cannot open admin boards')
    local stuckId = row({ cid = 'LB3', dept = 'fib', uuid = 'stuck-uuid', pts = 0, cashStatus = 'paying', cashBase = 800, mult = 1.3, at = ts(2026, 9, 23, 8) })
    LB.invalidate()
    local res = cb('admin:getBoards', 1, { period = 'weekly', filter = 'overall' })
    H.ok(res.ok, 'admin board ok')
    local a = res.data
    H.eq(byCid(a.rows, 'LB2').cash, 1340, 'cash paid per officer includes voided paid rows')
    H.eq(byCid(a.rows, 'LB2').realName, 'Bravo Two', 'admins see the real name')
    H.eq(byCid(a.rows, 'LB2').hidden, true, 'hidden flag')
    H.ok(byCid(a.unranked, 'LB5') ~= nil, 'unranked officers listed')
    H.eq(#a.stuck, 1, 'one payment stuck in paying')
    H.eq(a.stuck[1].rowId, stuckId, 'stuck row id')
    H.eq(a.stuck[1].transId, 'CP-stuck-uuid-LB3', 'Renewed-Banking transaction id')
    H.eq(a.stuck[1].amount, 1040, 'expected amount')
    local withRuns = cb('admin:getBoards', 1, { period = 'weekly', citizenid = 'LB2' }).data
    H.eq(#withRuns.runs, 5, 'every row of that officer in the window (voided and flagged too)')
    local allRuns = cb('admin:getBoards', 1, { period = 'alltime', citizenid = 'LB3' }).data
    H.eq(#allRuns.runs, 4, 'all-time runs of that officer')
    local dept = cb('admin:getBoards', 1, { period = 'monthly', filter = 'department', citizenid = 'LB1' }).data
    H.eq(dept.department, 'fib', 'admin department filter defaults to the first department')
    H.eq(cb('admin:getBoards', 1, { citizenid = 'x y' }).error, 'err.invalid_citizenid', 'bad citizenid')
    -- CP.Cash.stuckPayments wins when present
    CP.Cash = { stuckPayments = function() return { { id = 7, run_uuid = 'u7', citizenid = 'Z9', mission_type = 'patrol', mission_id = 'beat_patrol', amount = 250 },
        { id = 8, runUuid = 'u8', citizenid = 'Z8', name = 'Zed Eight', missionId = 'beat_patrol', missionLabel = 'Beat Patrol', amount = 300,
          createdAt = NOW - 60, transId = 'CP-u8-Z8' } } end }
    local viaCash = cb('admin:getBoards', 1, {}).data
    H.eq(viaCash.stuck[1].transId, 'CP-u7-Z9', 'normalised from CP.Cash')
    H.eq(viaCash.stuck[2].createdAt, os.date('%Y-%m-%d %H:%M:%S', NOW - 60), 'CP.Cash createdAt seconds -> text')
    H.eq(viaCash.stuck[2].missionLabel, 'Beat Patrol', 'CP.Cash mission label kept')
    CP.Cash = nil
    H.sql('DELETE FROM cp_mission_runs WHERE id = ?', { stuckId })
    LB.invalidate()
end

-- weekly job: top 3 of last week, Officer of the Week badge once
do
    hooks, notes = {}, {}
    -- the profile test gave LB1 that week's badge: the week counts as done
    H.eq(LB._weeklyJob(LAST_WEEK, WEEK), false, 'an existing badge means the week was done')
    H.eq(#hooks, 0, 'no webhook for a done week')
    H.sql("DELETE FROM cp_badges WHERE badge_id = 'officer_of_week_2026-09-14'")
    hooks, notes = {}, {}
    H.eq(LB._weeklyJob(LAST_WEEK, WEEK), true, 'weekly job awards')
    local b = H.sql("SELECT citizenid FROM cp_badges WHERE badge_id = 'officer_of_week_2026-09-14'")
    H.eq(b[1].citizenid, 'LB5', 'LB5 is Officer of the Week')
    H.eq(#hooks, 1, 'one board webhook')
    H.eq(hooks[1].category, 'board', 'board category')
    H.eq(#hooks[1].fields, 1, 'top 3 (only one qualified)')
    H.eq(notes[1] and notes[1].src, 55, 'online winner notified')
    H.eq(LB._weeklyJob(LAST_WEEK, WEEK), false, 'second run does nothing')
    H.eq(#hooks, 1, 'no second webhook')
    H.eq(LB._weeklyJob(WEEK, WEEK), false, 'empty window refused')
end

-- announcements: last week and last month
do
    LB.invalidate()
    local list = LB.announcements()
    H.eq(#list, 1, 'weekly announcement only')
    H.eq(list[1].kind, 'weekly_top3', 'weekly kind')
    H.eq(list[1].entries[1].citizenid, 'LB5', 'weekly winner')
    row({ cid = 'LB3', dept = 'fib', pts = 90, at = ts(2026, 8, 10, 10) })
    row({ cid = 'LB3', dept = 'fib', pts = 90, at = ts(2026, 8, 11, 10) })
    row({ cid = 'LB3', dept = 'fib', pts = 90, at = ts(2026, 8, 12, 10) })
    LB.invalidate()
    list = LB.announcements()
    H.eq(#list, 2, 'monthly announcement too')
    H.eq(list[2].kind, 'monthly_top3', 'monthly kind')
    H.eq(list[2].entries[1].points, 270, 'monthly points')
    H.eq(list[2].period, '2026-08', 'monthly period')
end

-- CP.Scoring provides the XP level and the badge list when it is loaded
do
    CP.Scoring = {
        xpLevel = function(xp) return { label = 'Scored ' .. xp, badge = 'gold', xp = 15000, next = 40000 } end,
        badges = function()
            return {
                { id = 'iron_wheels', label = 'Iron Wheels', earnedAt = '2026-09-01 10:00:00', earnedTs = NOW - 20 * 86400 },
                { id = 'officer_of_week_2026-09-14', label = 'badge.officer_of_week_2026-09-14', earnedAt = '2026-09-21 00:00:00', earnedTs = NOW - 2 * 86400 },
                { id = 'mystery', label = 'badge.mystery', earnedAt = '2026-09-02 10:00:00', earnedTs = NOW - 19 * 86400 },
            }
        end,
    }
    local p = cb('getProfile', 11, nil).data
    H.eq(p.level.label, 'Scored 5000', 'CP.Scoring.xpLevel used')
    H.eq(p.badges[1].kind, 'week', 'newest badge first, own label for the weekly badge')
    H.eq(p.badges[2].label, 'mystery', 'missing badge text falls back to the id')
    H.eq(p.badges[3].label, 'Iron Wheels', 'scoring label kept')
    CP.Scoring = nil
end

-- mission labels
do
    H.eq(LB.missionLabel('goal', 'patrol_2', nil), 'Complete 2 Patrol missions', 'goal label from Config.Goals')
    H.eq(LB.missionLabel('goal', 'unknown_goal', nil), 'profile.goal_reward', 'unknown goal')
    H.eq(LB.missionLabel('patrol', 'custom_x', { missionLabel = 'Custom X' }), 'Custom X', 'label from the breakdown')
    H.eq(LB.missionLabel('patrol', 'custom_y', nil), 'custom_y', 'id as last resort')
end

-- ════════════════════════════════════════════════════════════════════════════
-- Part B · CP.Challenge
-- ════════════════════════════════════════════════════════════════════════════
clearAll()
audits, hooks = {}, {}
officers = {}
officer(21, 'S1', 'Sam One', 'sast', 'S-1', true)    -- SAST supervisor
officer(22, 'S2', 'Sam Two', 'sast', 'S-2')
officer(31, 'F1', 'Fay One', 'fib', 'F-1', true)     -- FIB supervisor
officer(32, 'F2', 'Fay Two', 'fib', 'F-2')
for _, o in ipairs({ { 'S1', 'Sam One', 'sast', 'S-1' }, { 'S2', 'Sam Two', 'sast', 'S-2' }, { 'S3', 'Sid Three', 'sast', 'S-3' },
        { 'F1', 'Fay One', 'fib', 'F-1' }, { 'F2', 'Fay Two', 'fib', 'F-2' } }) do
    officerRow(o[1], o[2], o[3], o[4], 0, o[1] == 'S2')
end

-- calendar math (week 1 = start .. first reset)
do
    local season = { id = 1, startsAt = ts(2026, 9, 10, 12), active = true }
    H.eq(C._weekIndex(season, ts(2026, 9, 12)), 1, 'week 1 before the first reset')
    H.eq(C._weekIndex(season, ts(2026, 9, 14, 0, 30)), 2, 'week 2 after the reset')
    H.eq(C._weekIndex(season, NOW), 3, 'week 3 now')
    local f, t = C._weekWindow(season, 1)
    H.eq(f, season.startsAt, 'week 1 starts at the season start')
    H.eq(t, LAST_WEEK, 'week 1 ends at the first reset')
    f, t = C._weekWindow(season, 3)
    H.eq(f, WEEK, 'week 3 from')
    H.eq(t, ts(2026, 9, 28, 0), 'week 3 to')
    Config.Time.resetHour = 6
    H.eq(C._weekIndex(season, ts(2026, 9, 14, 5)), 1, 'reset hour 6: Monday 05:00 is still week 1')
    H.eq(C._weekIndex(season, ts(2026, 9, 14, 7)), 2, 'reset hour 6: Monday 07:00 is week 2')
    Config.Time.resetHour = 0
    H.eq(C._pickBounty(5, 2), C._pickBounty(5, 2), 'seeded pick is stable')
    local seen = {}
    for w = 1, 40 do seen[C._pickBounty(5, w)] = true end
    H.ok(seen.most_tactical and seen.most_cross and seen.most_unit and seen.most_completed, 'every bounty gets picked')
end

-- start a season (admin only), on Thursday 10 Sep
H.time = ts(2026, 9, 10, 12)
do
    local no, err = act('server:admin:startSeason', 21, { name = 'Season One' })
    H.eq(no, false, 'supervisor cannot start a season')
    H.eq(err, 'err.no_permission', 'no permission key')
    local bad, e2 = act('server:admin:startSeason', 1, { name = '   ' })
    H.eq(bad, false, 'empty name refused')
    H.eq(e2, 'err.invalid_season_name', 'invalid name key')
    H.eq(act('server:admin:startSeason', 1, 'x'), false, 'non-table payload refused')
    local ok, season = act('server:admin:startSeason', 1, { name = 'Season One' })
    H.eq(ok, true, 'admin starts a season')
    H.eq(season.name, 'Season One', 'season view name')
    H.eq(season.week, 1, 'week 1')
    H.eq(season.weeksLeft, 8, 'eight weeks left')
    H.eq(audits[#audits].action, 'season_start', 'audited')
    H.eq(audits[#audits].actor, 1, 'actor = src')
    local cur = C.currentSeason()
    H.eq(cur.id, season.id, 'currentSeason cached')
    local b = H.sql('SELECT objective FROM cp_dept_bounties WHERE season_id = ? AND week = 1', { cur.id })
    H.eq(b[1].objective, C._pickBounty(cur.id, 1), 'week 1 bounty picked with the seed')
end
local SID = C.currentSeason().id
H.sql('UPDATE cp_dept_bounties SET objective = ? WHERE season_id = ? AND week = 1', { 'most_tactical', SID })
H.sql('INSERT INTO cp_dept_bounties (season_id, week, objective) VALUES (?, 2, ?)', { SID, 'most_completed' })

-- season rows (see the numbers in docs/notes/boards.md "test scenario")
local function srow(t) t.season = SID; return row(t) end
-- week 1
srow({ cid = 'S1', type = 'tactical', pts = 200, at = ts(2026, 9, 11, 10) })
srow({ cid = 'S1', type = 'tactical', pts = 200, at = ts(2026, 9, 11, 11) })
srow({ cid = 'F1', dept = 'fib', type = 'tactical', pts = 200, at = ts(2026, 9, 12, 10) })
-- week 2
srow({ cid = 'S1', pts = 60, at = ts(2026, 9, 15, 10) })
srow({ cid = 'S2', pts = 60, p = 2, at = ts(2026, 9, 16, 10) })
srow({ cid = 'S2', pts = 60, at = ts(2026, 9, 16, 11) })
srow({ cid = 'S2', pts = 60, at = ts(2026, 9, 16, 12) })
srow({ cid = 'S3', type = 'investigation', pts = 160, at = ts(2026, 9, 17, 10) })
srow({ cid = 'F1', dept = 'fib', type = 'tactical', pts = 200, d = 2, at = ts(2026, 9, 16, 10) })
srow({ cid = 'F1', dept = 'fib', type = 'tactical', pts = 200, at = ts(2026, 9, 16, 11) })
for i = 1, 4 do srow({ cid = 'F2', dept = 'fib', pts = 60, at = ts(2026, 9, 18, 8 + i) }) end
srow({ cid = 'F2', dept = 'fib', state = 'failed', pts = 15, at = ts(2026, 9, 18, 14) })
-- week 3 (current)
srow({ cid = 'S2', type = 'tactical', pts = 200, at = ts(2026, 9, 22, 10), cash = 800, cashStatus = 'paid' })
srow({ cid = 'F1', dept = 'fib', type = 'tactical', pts = 200, flagged = true, at = ts(2026, 9, 22, 11) })
srow({ cid = 'S1', pts = 60, voided = true, at = ts(2026, 9, 22, 12) })
srow({ cid = 'S3', type = 'manual_award', mission = 'manual_award', reason = 'manual_award', pts = 50, at = ts(2026, 9, 22, 13) })
-- a row of another season never counts
row({ cid = 'S1', pts = 999, season = SID + 100, at = ts(2026, 9, 22, 14) })

H.time = NOW
C.invalidate()

-- standings before any week closed (average)
do
    local st = C.standings()
    H.eq(st.mode, 'average', 'average mode')
    local fib, sast = st.departments[1], st.departments[2]
    H.eq(sast.key, 'sast', 'sast listed')
    H.eq(sast.activeOfficers, 2, 'SAST: S1 and S2 are active (S3 has 1 run)')
    H.eq(sast.points, 1050, 'SAST season points (manual award included, voided/flagged/other season excluded)')
    H.eq(sast.score, 420, 'SAST average of active officers = 840 / 2')
    H.eq(fib.key, 'fib', 'FIB leads')
    H.eq(fib.score, 428, 'FIB (600 + 255) / 2 rounded')
    H.eq(fib.bonus, 0, 'no bonus before weeks close')
end

-- close weeks 1 and 2 (catch-up path)
do
    local season = C.currentSeason()
    H.eq(C._closeDueWeeks(season, NOW, false), 2, 'weeks 1 and 2 closed')
    local w = H.sql('SELECT week, winner FROM cp_dept_bounties WHERE season_id = ? AND week >= 1 ORDER BY week', { SID })
    H.eq(w[1].winner, 'sast', 'week 1 most_tactical: SAST 2 / 2 active beats FIB 1 / 2')
    H.eq(w[2].winner, 'fib', 'week 2 most_completed: FIB 6 / 2 beats SAST 5 / 2')
    H.eq(w[3] and w[3].winner, nil, 'week 3 still open')
    H.eq(C._closeDueWeeks(season, NOW, false), 0, 'closing is idempotent')
    local st = C.standings()
    local byKey = {}
    for _, d in ipairs(st.departments) do byKey[d.key] = d end
    H.eq(byKey.sast.bonus, 40, 'SAST bonus = floor(10% of 400)')
    H.eq(byKey.fib.bonus, 65, 'FIB bonus = floor(10% of 655)')
    H.eq(byKey.sast.score, 440, 'SAST (840 + 40) / 2')
    H.eq(byKey.fib.score, 460, 'FIB (855 + 65) / 2')
    Config.Challenge.scoring = 'total'
    C.invalidate()
    st = C.standings()
    H.eq(st.departments[1].key, 'sast', 'total mode: SAST leads')
    H.eq(st.departments[1].score, 1090, 'total = 1050 + 40')
    Config.Challenge.scoring = 'top10'
    C.invalidate()
    st = C.standings()
    H.eq(st.departments[1].score, 1090, 'top10 = the 3 SAST officers + bonus')
    H.eq(st.departments[2].score, 920, 'top10 FIB = 855 + 65')
    Config.Challenge.scoring = 'average'
    C.invalidate()
end

-- a department added mid-season joins at 0
do
    Config.Departments.bcso = { label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = { 'bcso' }, supervisorGrade = 3,
        theme = { primary = '#5c4033', accent = '#d4a017', background = '#14100c', surface = '#231c16' } }
    C.invalidate()
    local st = C.standings()
    H.eq(#st.departments, 3, 'three departments')
    H.eq(st.departments[3].key, 'bcso', 'BCSO last')
    H.eq(st.departments[3].score, 0, 'BCSO at 0')
    Config.Departments.bcso = nil
    C.invalidate()
end

-- bounty override (admin, current week only, audited)
do
    local no, err = act('server:admin:overrideBounty', 21, { objective = 'most_unit' })
    H.eq(no, false, 'supervisor cannot override')
    H.eq(err, 'err.no_permission', 'override permission key')
    local bad, e2 = act('server:admin:overrideBounty', 1, { objective = 'most_donuts' })
    H.eq(bad, false, 'unknown objective refused')
    H.eq(e2, 'err.invalid_bounty', 'unknown objective key')
    audits = {}
    local ok, view = act('server:admin:overrideBounty', 1, { objective = 'most_tactical' })
    H.eq(ok, true, 'override ok')
    H.eq(view.id, 'most_tactical', 'new objective')
    H.eq(view.week, 3, 'current week')
    H.eq(view.leaderKey, 'sast', 'SAST leads week 3 tactical (1 / 2; the flagged FIB run is excluded)')
    H.eq(view.leader, 'SAST', 'leader short')
    local picked = C._pickBounty(SID, 3)
    H.eq(view.overridden, picked ~= 'most_tactical', 'overridden flag')
    if picked ~= 'most_tactical' then H.eq(audits[1] and audits[1].action, 'bounty_override', 'override audited') end
    H.eq(H.sql('SELECT objective FROM cp_dept_bounties WHERE season_id = ? AND week = 3', { SID })[1].objective, 'most_tactical', 'stored')
    local b = C.bounty()
    H.eq(b.week, 3, 'bounty() current week')
    H.eq(b.closed, false, 'open')
    local b1 = C.bounty('2026-09-14')
    H.eq(b1.week, 2, 'bounty(weekKey)')
    H.eq(b1.winner, 'fib', 'closed week winner')
    H.eq(C.bounty('junk'), nil, 'bad week key')
end

-- officer challenge view and contributors
do
    local v = cb('getChallenge', 22, nil).data
    H.eq(v.season.name, 'Season One', 'season name')
    H.eq(v.season.weeksLeft, 7, 'weeks left after 13 days')
    H.eq(v.season.week, 3, 'week number')
    H.eq(v.departments[1].key, 'fib', 'FIB first')
    H.eq(v.departments[1].colour, '#1c2541', 'department colour = theme.primary')
    H.eq(v.bounty.id, 'most_tactical', 'bounty')
    H.eq(v.bounty.leader, 'SAST', 'bounty leader')
    H.eq(#v.bounty.rates, 2, 'rates per department')
    H.eq(v.topContributors[1].citizenid, 'S1', 'S1 top SAST contributor')
    H.eq(v.topContributors[2].name, 'S-2', 'hidden contributor shows the callsign')
    H.eq(#v.topContributors, 3, 'SAST has three contributors')
    local c = cb('getDeptContributors', 22, { department = 'fib' }).data
    H.eq(c.department.short, 'FIB', 'contributors department')
    H.eq(#c.contributors, 2, 'two FIB contributors')
    H.eq(c.contributors[1].citizenid, 'F1', 'F1 first')
    H.eq(c.contributors[1].active, true, 'F1 active')
    H.eq(cb('getDeptContributors', 22, { department = 'lspd' }).error, 'err.unknown_department', 'unknown department')
    H.eq(cb('getChallenge', 99, nil).error, 'err.not_police', 'non-officer refused')
    -- the season board now has data
    local sb = cb('getBoard', 22, { period = 'season' }).data
    H.eq(sb.season.name, 'Season One', 'season board season')
    H.eq(sb.rows[1].citizenid, 'F1', 'season board leader')
    H.eq(LB.seasonPoints('S1'), 460, 'season points')
end

-- admin seasons screen
do
    H.eq(cb('admin:getSeasons', 21, nil).error, 'err.no_permission', 'supervisor cannot open admin seasons')
    local a = cb('admin:getSeasons', 1, nil).data
    H.eq(a.current.id, SID, 'current season')
    H.eq(#a.standings, 2, 'standings')
    H.eq(a.bounty.id, 'most_tactical', 'this week')
    H.eq(#a.bountyHistory, 3, 'three bounty weeks')
    H.eq(a.bountyHistory[1].week, 3, 'latest first')
    H.eq(a.bountyHistory[1].current, true, 'current week flagged')
    H.eq(a.bountyHistory[2].winnerShort, 'FIB', 'winner short')
    H.eq(a.bountyHistory[2].bonus, 65, 'bonus in history')
    H.eq(#a.bounties, 4, 'override options')
    H.eq(#a.seasons, 1, 'season list')
end

-- supervisor department report and officer activity
do
    H.eq(cb('sup:getDeptReport', 22, nil).error, 'err.no_permission', 'officers cannot open the report')
    local r = cb('sup:getDeptReport', 21, nil).data
    H.eq(r.department.key, 'sast', 'own department')
    H.eq(r.standing.rank, 2, 'SAST second')
    H.eq(r.standing.of, 2, 'of two')
    H.eq(r.bounty.id, 'most_tactical', 'bounty in the report')
    H.eq(r.week.key, '2026-09-21', 'this week')
    local s2 = byCid(r.officers, 'S2')
    H.eq(s2.runs, 1, 'S2 runs this week')
    H.eq(s2.points, 200, 'S2 points this week')
    H.eq(s2.cash, 800, 'S2 cash this week')
    H.eq(s2.name, 'Sam Two', 'supervisors see real names')
    local s1 = byCid(r.officers, 'S1')
    H.eq(s1.points, 999, 'rows of other seasons still count as activity this week (voided row gives 0)')
    H.eq(cb('sup:getDeptReport', 21, { department = 'fib' }).error, 'err.other_department', 'supervisors only see their department')
    H.eq(cb('sup:getDeptReport', 1, { department = 'fib' }).data.department.key, 'fib', 'admins may pick a department')
    local act1 = cb('sup:getOfficerActivity', 21, { citizenid = 'S2' }).data
    H.eq(#act1.runs, 1, 'S2 activity this week')
    H.eq(act1.runs[1].missionType, 'tactical', 'activity run')
    H.eq(act1.officer.name, 'Sam Two', 'activity officer')
    H.eq(cb('sup:getOfficerActivity', 21, { citizenid = 'F1' }).error, 'err.other_department', 'other department refused')
    H.eq(cb('sup:getOfficerActivity', 21, { citizenid = 'NOBODY' }).error, 'err.unknown_officer', 'unknown officer')
    H.eq(cb('sup:getOfficerActivity', 21, { citizenid = 'a b' }).error, 'err.invalid_citizenid', 'bad citizenid')
    H.eq(cb('sup:getOfficerActivity', 21, nil).error, 'err.invalid_payload', 'bad args')
end

-- the weekly reset through CP.Schedule: week 3 closes, week 4 gets its bounty
do
    hooks = {}
    CP.Schedule._check(NOW)                       -- record the current period
    H.time = ts(2026, 9, 28, 1)
    local fired = CP.Schedule._check(H.time)
    H.eq(fired.weekly, true, 'weekly boundary fired')
    local w3 = H.sql('SELECT winner FROM cp_dept_bounties WHERE season_id = ? AND week = 3', { SID })[1]
    H.eq(w3.winner, 'sast', 'week 3 closed at the reset')
    local w4 = H.sql('SELECT objective, winner FROM cp_dept_bounties WHERE season_id = ? AND week = 4', { SID })[1]
    H.eq(w4.objective, C._pickBounty(SID, 4), 'week 4 bounty picked at the reset')
    H.eq(w4.winner, nil, 'week 4 open')
    local bad, err = act('server:admin:overrideBounty', 1, { objective = 'most_unit' })
    H.eq(bad, true, 'override of the new week works')
    H.sql('UPDATE cp_dept_bounties SET winner = ? WHERE season_id = ? AND week = 4', { '', SID })
    bad, err = act('server:admin:overrideBounty', 1, { objective = 'most_cross' })
    H.eq(bad, false, 'closed week cannot be overridden')
    H.eq(err, 'err.bounty_closed', 'closed key')
    H.sql('UPDATE cp_dept_bounties SET winner = NULL WHERE season_id = ? AND week = 4', { SID })
end

-- end the season: champion, trophies, top 10 badges, webhook, audit, banner
do
    audits, hooks = {}, {}
    H.eq(act('server:admin:endSeason', 21, nil), false, 'supervisor cannot end a season')
    local ok, res = act('server:admin:endSeason', 1, nil)
    H.eq(ok, true, 'season ended')
    H.eq(res.champion, 'fib', 'FIB champion: (855 + 65) / 2 = 460 beats (840 + 40 + 25) / 2 = 452.5')
    H.eq(res.season.active, false, 'inactive')
    H.eq(C.currentSeason(), nil, 'no current season')
    H.eq(C.latestSeason().id, SID, 'latest season kept for the Season board')
    local w4 = H.sql('SELECT week, winner FROM cp_dept_bounties WHERE season_id = ? AND week = 4', { SID })[1]
    H.eq(w4.winner, '', 'week 4 closed without a winner (no runs)')
    local champ = H.sql('SELECT objective, winner FROM cp_dept_bounties WHERE season_id = ? AND week = 0', { SID })[1]
    H.eq(champ.winner, 'fib', 'champion stored in week 0')
    local trophies = H.sql('SELECT citizenid FROM cp_badges WHERE badge_id = ? ORDER BY citizenid', { ('season_%d_champion'):format(SID) })
    H.eq(#trophies, 2, 'trophy for the two active FIB officers')
    H.eq(trophies[1].citizenid, 'F1', 'F1 trophy')
    local top = H.sql('SELECT citizenid FROM cp_badges WHERE badge_id = ? ORDER BY citizenid', { ('season_%d_top10'):format(SID) })
    H.eq(#top, 4, 'top 10 badges for the four ranked officers (S3 has 1 run)')
    H.eq(#res.top10, 4, 'top 10 in the result')
    H.eq(res.top10[1].citizenid, 'F1', 'F1 tops the season board')
    H.eq(#hooks, 1, 'season results webhook')
    H.eq(#hooks[1].fields, 2, 'standings and top 10 fields')
    H.eq(audits[#audits].action, 'season_end', 'season end audited')
    H.eq(audits[#audits].new, 'fib', 'champion in the audit')
    local banner = C.championBanner('fib')
    H.eq(banner.season, 'Season One', 'banner season')
    H.eq(banner.department, 'Federal Investigation Bureau', 'banner department label')
    H.eq(C.championBanner('sast'), nil, 'no banner for other departments')
    H.eq(C.championBanner().departmentKey, 'fib', 'banner without a department')
    local again, err = act('server:admin:endSeason', 1, nil)
    H.eq(again, false, 'nothing to end')
    H.eq(err, 'err.no_season', 'no season key')
    -- profile labels of season badges
    local p = LB.profile(officers[31], nil)
    local kinds = {}
    for _, b in ipairs(p.badges) do kinds[b.kind] = true end
    H.ok(kinds.champion and kinds.top10, 'season badges labelled on the profile')
    -- the ended season still shows on the season board
    local sb = cb('getBoard', 22, { period = 'season' }).data
    H.eq(sb.season.active, false, 'ended season board')
    H.eq(#sb.rows, 4, 'ended season rows')
    local av = cb('admin:getSeasons', 1, nil).data
    H.eq(av.current, nil, 'no current season in the admin view')
    H.eq(av.latest.id, SID, 'latest season in the admin view')
    H.eq(av.seasons[1].championShort, 'FIB', 'champion in the season list')
    local v = cb('getChallenge', 22, nil).data
    H.eq(v.season, nil, 'officer view without a season')
    H.eq(#v.departments, 2, 'zero standings still listed')
end

-- starting a new season ends the running one first
do
    local ok, s2 = act('server:admin:startSeason', 1, { name = 'Season Two' })
    H.eq(ok, true, 'season two')
    audits, hooks = {}, {}
    local ok3, s3 = C.startSeason(0, 'Season Three')   -- the console (/CrimsonPoliceAdmin season start)
    H.eq(ok3, true, 'console starts season three')
    H.eq(audits[1].action, 'season_end', 'season two ended first')
    H.eq(audits[1].role, 'console', 'console role')
    H.eq(audits[1].new, '-', 'no champion without runs')
    local part = io.open('Crimson-Police/locales/parts/boards.json', 'r')
    H.ok(part ~= nil and part:read('a'):find('"challenge.audit_replaced"', 1, true) ~= nil, 'replacement reason is a locale key of this part')
    if part then part:close() end
    H.eq(audits[1].reason, CP.L('challenge.audit_replaced', { name = 'Season Three' }), 'localized reason for the replaced season')
    H.eq(audits[2].action, 'season_start', 'then started')
    H.eq(H.sql('SELECT COUNT(*) AS n FROM cp_seasons WHERE active = 1')[1].n, 1, 'one active season')
    H.eq(C.currentSeason().id, s3.id, 'season three current')
    H.ok(s2.id < s3.id, 'ids increase')
    H.eq(C.championBanner('fib'), nil, 'the last ended season had no champion: no banner')
    H.eq(C.endSeason(22), false, 'officers cannot end a season')
    -- permission first, then the payload (ARCHITECTURE §0.7)
    local n1, e1 = act('server:admin:startSeason', 22, 'not a table')
    H.eq(n1, false, 'officer start refused')
    H.eq(e1, 'err.no_permission', 'start: permission checked before the payload')
    local n2, e2 = act('server:admin:overrideBounty', 22, 42)
    H.eq(e2, 'err.no_permission', 'override: permission checked before the payload')
    H.eq(n2, false, 'officer override refused')
    local n3, e3 = act('server:admin:endSeason', 22, 'x')
    H.eq(e3, 'err.no_permission', 'end: permission checked before the payload')
    H.eq(n3, false, 'officer end refused')
    H.eq(cb('sup:getOfficerActivity', 22, 'bad').error, 'err.no_permission', 'activity: permission checked before the args')
    H.eq(cb('sup:getOfficerActivity', 21, 'bad').error, 'err.invalid_payload', 'activity: a supervisor gets the payload error')
    H.ok(#logs > 0, 'debug lines were formatted')
end

return H
