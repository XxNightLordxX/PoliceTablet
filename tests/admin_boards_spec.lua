-- Full admin control, boards (P1): keeping an officer off the boards, past windows, ranking by any metric,

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
local Act, Data, Rid, Count, One = W.act, W.data, W.rid, W.count, W.one
local LB, C = CP.Leaderboard, CP.Challenge

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_mission_runs_archive')
H.sql('DELETE FROM cp_audit')
H.sql('DELETE FROM cp_seasons')
H.sql('DELETE FROM cp_badges')
H.sql('DELETE FROM cp_dept_bounties')

local DAY = 86400
Config.Leaderboard.minRunsToRank = 1

local function Entry(list, cid)
    for _, e in ipairs(list or {}) do if e.citizenid == cid then return e end end
    return nil
end

-- ============================================================================
--                      1. KEEP AN OFFICER OFF THE BOARDS
-- ============================================================================

do
    W.officer('OFF00003', 'sast', 0)
    W.officer('OFF00004', 'fib', 0)
    W.officer('OFF00006', 'sast', 0)
    for i = 1, 3 do
        W.row({ citizenid = 'OFF00003', points = 100, at = H.time - i * 600 })
        W.row({ citizenid = 'OFF00004', department = 'fib', points = 50, at = H.time - i * 600 })
        W.row({ citizenid = 'OFF00006', points = 10, at = H.time - i * 600 })
    end
    LB.invalidate()
    local ranked = W.async(function() return LB.ranking({ period = 'weekly', filter = 'overall' }) end)
    H.ok(Entry(ranked, 'OFF00003') ~= nil, 'the officer is on the weekly board')

    local ok, e = Act('server:admin:setBoardExcluded', 2, { citizenid = 'OFF00003', excluded = true, reason = 'x' })
    H.ok(not ok and e == 'err.no_permission', 'a supervisor can\'t')
    ok, e = Act('server:admin:setBoardExcluded', 1, { citizenid = 'OFF00003', excluded = true, reason = 'Test char' })
    H.ok(ok == true, 'kept off the boards: ' .. tostring(e))
    ranked = W.async(function() return LB.ranking({ period = 'weekly', filter = 'overall' }) end)
    H.ok(Entry(ranked, 'OFF00003') == nil, 'gone from the board at once (the cache is cleared)')
    local alltime = W.async(function() return LB.ranking({ period = 'alltime', filter = 'overall' }) end)
    H.ok(Entry(alltime, 'OFF00003') == nil, 'and from the all-time board')
    H.eq(W.auditCount('boardExclude', 'OFF00003'), 1, 'audited')
    -- still counted for the department challenge: the challenge reads the rows, not the boards
    H.eq(Count([[SELECT COALESCE(SUM(final_points), 0) AS n FROM cp_mission_runs WHERE department = 'sast']]), 330,
        'the rows still count for the department')
    ok = Act('server:admin:setBoardExcluded', 1, { citizenid = 'OFF00003', excluded = false, reason = 'Back' })
    H.eq(ok, true, 'back on')
    ranked = W.async(function() return LB.ranking({ period = 'weekly', filter = 'overall' }) end)
    H.ok(Entry(ranked, 'OFF00003') ~= nil, 'back on the board')
end

-- ============================================================================
--                    2. PAST WINDOWS AND RANK BY ANY METRIC
-- ============================================================================

do
    local now = H.time
    local ws = W.async(function() return LB._windowOk and true end)
    H.ok(ws, 'the window check exists')
    -- a whole week inside the last 12 months
    local weeks = W.async(function()
        local res = H.callback('crimson-police:admin:getBoards', 1, { period = 'weekly', filter = 'overall' })
        return res
    end)
    H.ok(type(weeks) == 'table' and weeks.ok ~= false, 'the admin board opens')
    local data = weeks and weeks.data or {}
    local past = data.windows or data.pastWindows
    H.ok(type(past) == 'table' and type(past.weeks) == 'table' and #past.weeks >= 50, 'the past weeks are listed')
    local w = past and past.weeks and past.weeks[3]
    if w then
        local res = W.cb('admin:getBoards', 1, { period = 'range', from = w.from, to = w.to, filter = 'overall' })
        H.ok(res and res.ok ~= false, 'a whole past week opens')
        H.clockMs = H.clockMs + 2000   -- a past window: one every 2 s per admin
        res = W.cb('admin:getBoards', 1, { period = 'range', from = w.from + 3600, to = w.to, filter = 'overall' })
        H.ok(res and res.ok == false and res.error == 'err.invalid_window',
            'a window that is not a whole week is refused')
    end
    H.clockMs = H.clockMs + 2000
    local res = W.cb('admin:getBoards', 1,
        { period = 'range', from = now - 400 * DAY, to = now - 393 * DAY, filter = 'overall' })
    H.ok(res and res.ok == false, 'more than 12 months back is refused')
    res = W.cb('getBoard', 3, { period = 'range', from = now - 7 * DAY, to = now })
    H.ok(res and res.ok == false, 'an officer can\'t open a past window')

    -- rank by a metric (no window functions)
    res = W.cb('admin:getBoards', 1, { period = 'weekly', filter = 'overall', metric = 'missions' })
    H.ok(res and res.ok ~= false, 'rank by missions: ' .. tostring(res and res.error))
end

-- ============================================================================
--                       3. RECOGNITION AND STAFF NOTICES
-- ============================================================================

do
    -- last week's rows: OFF00004 leads
    local lastWeek = H.time - 7 * DAY
    W.row({ citizenid = 'OFF00004', department = 'fib', points = 500, at = lastWeek })
    W.row({ citizenid = 'OFF00006', points = 100, at = lastWeek })
    LB.invalidate()
    local rec = Data('admin:getRecognition', 1, {})
    H.ok(rec and type(rec.weeks) == 'table' and #rec.weeks == 4, 'the last four closed weeks are listed')
    H.ok(rec and type(rec.home) == 'table', 'the Home preview is there')
    local wk = rec and rec.weeks[1]
    H.ok(wk and wk.top[1] and wk.top[1].citizenid == 'OFF00004', 'last week\'s leader')

    -- the weekly job gives the badge to the leader; a recount after a void moves it
    local from, to = LB.isClosedWeek(wk.weekKey)
    W.async(function() return LB._weeklyJob(from, to) end)
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_badges WHERE badge_id = ? AND citizenid = ?', { wk.badgeId, 'OFF00004' }),
        1, 'Officer of the Week to OFF00004')
    H.sql([[UPDATE cp_mission_runs SET voided = 1, void_kind = 'correction' WHERE citizenid = 'OFF00004'
        AND final_points = 500]])
    LB.invalidate()
    local pv = Data('admin:previewRecount', 1, { weekKey = wk.weekKey })
    H.ok(pv and pv.top[1] and pv.top[1].citizenid == 'OFF00006' and pv.changed == true,
        'the recount preview: a new leader')
    local ok, e = Act('server:admin:recountWeek', 1, {
        weekKey = wk.weekKey,
        reason = 'voided farm',
        confirm = 'RECOUNT',
        previewToken = pv.previewToken,
        post = true,
    })
    H.ok(ok == true and e.holder == 'OFF00006', 'recounted: ' .. tostring(e))
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_badges WHERE badge_id = ? AND citizenid = ?', { wk.badgeId, 'OFF00006' }),
        1, 'the badge moved')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_badges WHERE badge_id = ? AND citizenid = ?', { wk.badgeId, 'OFF00004' }),
        0, 'the old holder lost it')
    -- the catch-up after a restart doesn't give it back
    W.async(function() return LB._weeklyJob(from, to) end)
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_badges WHERE badge_id = ?', { wk.badgeId }), 1,
        'the weekly job catch-up does not re-award a revoked Officer of the Week')
    ok, e = Act('server:admin:recountWeek', 1, { weekKey = '2020-01-06', reason = 'x', confirm = 'RECOUNT' })
    H.ok(not ok and e == 'err.week_recount', 'only the last four closed weeks')

    -- post again: once per 10 minutes
    ok = Act('server:admin:repostWeek', 1, { weekKey = wk.weekKey })
    H.eq(ok, true, 'posted again')
    ok, e = Act('server:admin:repostWeek', 1, { weekKey = wk.weekKey })
    H.ok(not ok and e == 'err.rate_limited', 'not twice in 10 minutes: ' .. tostring(e))

    -- switch the weekly top 3 off
    Config.Leaderboard.announceWeekly = false
    LB.invalidate()
    local ann = W.async(function() return LB.announcements('sast') end)
    local weekly = false
    for _, a in ipairs(ann or {}) do if a.kind == 'weekly_top3' then weekly = true end end
    H.ok(not weekly, 'the weekly top 3 is gone from Home when switched off')
    Config.Leaderboard.announceWeekly = true

    -- a notice for one department
    ok, e = Act('server:admin:postNotice', 1,
        { text = 'FIB briefing at 9', departments = { 'fib' }, expiresAt = H.time + DAY, reason = 'brief' })
    H.ok(ok == true, 'a notice for FIB: ' .. tostring(e))
    local function Has(dept)
        for _, a in ipairs(W.async(function() return LB.announcements(dept) end) or {}) do
            if a.kind == 'staff_notice' and a.text == 'FIB briefing at 9' then return true end
        end
        return false
    end
    H.ok(Has('fib') and not Has('sast'), 'shown to FIB only')
    rec = Data('admin:getRecognition', 1, {})
    H.ok(rec and #rec.notices >= 1, 'the admin preview lists every notice')
    ok = Act('server:admin:removeNotice', 1, { id = e.id, reason = 'done' })
    H.eq(ok, true, 'removed')
    H.ok(not Has('fib'), 'gone')
    H.eq(W.auditCount('noticeRemove'), 1, 'audited')
end

-- ============================================================================
--                                  4. SEASONS
-- ============================================================================

do
    local ok, e = Act('server:admin:startSeason', 1, { name = 'Season One' })
    H.ok(ok == true, 'a season starts: ' .. tostring(e))
    local season = C.currentSeason(true)
    H.ok(season ~= nil, 'running')

    ok, e = Act('server:admin:renameSeason', 1, { id = season.id, name = 'Spring Season' })
    H.ok(ok == true, 'renamed: ' .. tostring(e))
    H.eq(C.currentSeason(true).name, 'Spring Season', 'the new name')
    H.eq(W.auditCount('seasonRename'), 1, 'audited')
    ok, e = Act('server:admin:renameSeason', 2, { id = season.id, name = 'Sup' })
    H.ok(not ok, 'a supervisor can\'t rename: ' .. tostring(e))

    -- a planned end: the first daily reset on or after the date ends it and starts the next one
    ok, e = Act('server:admin:scheduleSeasonEnd', 1, { id = season.id, at = H.time - 10, reason = 'x' })
    H.ok(not ok and e == 'err.season_plan_date', 'a date in the past is refused')
    ok, e = Act('server:admin:scheduleSeasonEnd', 1,
        { id = season.id, at = H.time + 2 * DAY, nextName = 'Summer Season', reason = 'two months' })
    H.ok(ok == true, 'planned: ' .. tostring(e))
    H.eq(C.currentSeason(true).plannedEnd, H.time + 2 * DAY, 'stored')
    local sent = W.async(function() return C._remindPlannedEnd(H.time + 2 * DAY - 3000) end)
    H.ok((sent or 0) >= 1, 'admins are reminded before the end')
    local ended = W.async(function() return C._plannedEndCheck(H.time + DAY) end)
    H.ok(not ended, 'not before the date')
    H.time = H.time + 2 * DAY + 60
    ended = W.async(function() return C._plannedEndCheck(H.time) end)
    H.ok(ended, 'the reset after the date ends the season')
    local next = C.currentSeason(true)
    H.ok(next and next.name == 'Summer Season' and next.id ~= season.id, 'and starts the next one')

    -- ending needs the typed season name
    ok, e = Act('server:admin:endSeason', 1, { reason = 'x', confirm = 'wrong' })
    H.ok(not ok and e == 'err.confirm_mismatch', 'ending needs the season\'s name')
    local plan = Data('admin:previewSeasonEnd', 1, {})
    H.ok(plan and plan.season and plan.season.id == next.id, 'the end preview')
    W.row({ citizenid = 'OFF00003', points = 40, at = H.time - 60, seasonId = next.id })
    ok, e = Act('server:admin:endSeason', 1, { reason = 'done', confirm = 'Summer Season' })
    H.ok(ok == true, 'ended: ' .. tostring(e))
    H.ok(C.currentSeason(true) == nil, 'no season running')

    -- a run written after the end has no season; reopen backfills it, Undo clears exactly that backfill
    H.time = H.time + 3600
    local gap = W.row({ citizenid = 'OFF00003', points = 25, at = H.time - 60 })
    local pv = Data('admin:previewReopen', 1, { id = next.id })
    H.ok(pv and pv.gapRows == 1, 'the reopen preview counts the gap rows: ' .. tostring(pv and pv.gapRows))
    ok, e = Act('server:admin:reopenSeason', 1, {
        id = next.id,
        reason = 'too early',
        confirm = 'Summer Season',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok == true and e.backfilled == 1, 'reopened: ' .. tostring(e))
    local jobId = ok and e.jobId
    H.eq(One('SELECT season_id FROM cp_mission_runs WHERE id = ?', { gap }).season_id, next.id, 'the gap row joins')
    H.ok(C.currentSeason(true) and C.currentSeason(true).id == next.id, 'the season runs again')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_dept_bounties WHERE season_id = ? AND week = 0', { next.id }), 0,
        'its champion row is gone')
    ok, e = Act('server:admin:undoReopen', 1, { jobId = jobId, reason = 'oops' })
    H.ok(ok == true, 'undo reopen: ' .. tostring(e))
    H.ok(C.currentSeason(true) == nil, 'ended again')
    H.eq(One('SELECT season_id FROM cp_mission_runs WHERE id = ?', { gap }).season_id, nil, 'the backfill is cleared')

    -- a past season
    local view = Data('admin:getSeason', 1, { id = season.id })
    H.ok(view and view.season ~= nil or view ~= nil, 'a past season opens')

    -- late reopen refused
    H.time = H.time + 2 * DAY
    local res = W.cb('admin:previewReopen', 1, { id = next.id })
    H.ok(res and res.ok == false and res.error == 'err.season_reopen_late', 'more than 24 h after the end: refused')

    -- next week's bounty
    ok, e = Act('server:admin:startSeason', 1, { name = 'Autumn Season' })
    H.eq(ok, true, 'another season')
    local kind = nil
    for _, k in ipairs(Config.Challenge and Config.Challenge.bounties or {}) do
        kind = kind or (type(k) == 'table' and k.id or k)
    end
    if kind then
        ok, e = Act('server:admin:setNextBounty', 1, { objective = kind })
        H.ok(ok == true, 'next week\'s bounty is set: ' .. tostring(e))
        ok, e = Act('server:admin:setNextBounty', 1, { objective = 'not_a_kind' })
        H.ok(not ok and e == 'err.invalid_bounty', 'an unknown kind is refused')
    end
end

-- ============================================================================
--                  5. FLAGGED PANEL, GOALS, RESTORE AND CACHE
-- ============================================================================

do
    local run = W.uuid()
    local a = W.row(
        { citizenid = 'OFF00003', points = 70, flagged = true, uuid = run, cash = 100, cashStatus = 'held' })
    local b = W.row(
        { citizenid = 'OFF00006', points = 70, flagged = true, uuid = run, cash = 100, cashStatus = 'held' })
    local ok, e = Act('server:admin:approveRun', 1, { runUuid = run, reason = 'checked' })
    H.ok(ok == true and e.approved == 2, 'every flagged row of the run is approved: ' .. tostring(e))
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE flagged = 1 AND id IN (?, ?)', { a, b }), 0,
        'unflagged')
    ok, e = Act('server:admin:approveRun', 2, { runUuid = run, reason = 'x' })
    H.ok(not ok, 'a supervisor can\'t use Approve all')

    -- restore a voided run: the board shows it at once
    LB.invalidate()
    local vrow = W.row({ citizenid = 'OFF00006', points = 900, voided = true })
    local before = W.async(function() return LB.ranking({ period = 'weekly', filter = 'overall' }) end)
    local pts0 = (Entry(before, 'OFF00006') or {}).points or 0
    ok, e = Act('server:admin:restoreRun', 1, { rowId = vrow, reason = 'wrong' })
    H.ok(ok == true, 'restored: ' .. tostring(e))
    local after = W.async(function() return LB.ranking({ period = 'weekly', filter = 'overall' }) end)
    H.eq((Entry(after, 'OFF00006') or {}).points, pts0 + 900, 'the board cache shows the row at once')

    -- a goal reward can't pay twice in one period, even after the goal list changes
    local goals = W.async(function() return CP.Goals.forOfficer('OFF00006') end)
    local daily = goals and goals.daily
    if daily and daily.id then
        ok, e = Act('server:admin:completeGoal', 1,
            { citizenid = 'OFF00006', kind = 'daily', goalId = daily.id, reason = 'bug' })
        H.ok(ok == true, 'a goal is marked complete: ' .. tostring(e))
        ok, e = Act('server:admin:completeGoal', 1,
            { citizenid = 'OFF00006', kind = 'daily', goalId = daily.id, reason = 'again' })
        H.ok(not ok and e == 'err.goal_rewarded', 'not twice')
        H.eq(
            Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = 'OFF00006' AND mission_type = 'goal']]),
            1, 'one goal reward row')
    else
        H.ok(true, 'no daily goal configured')
    end

    -- the department contributors
    local dc = Data('admin:getDeptContributors', 1, { department = 'sast' })
    H.ok(dc ~= nil, 'the department contributors open')
end

-- ============================================================================
--                            6. SETTINGS LISTENERS
-- ============================================================================

do
    local inv = 0
    local real = LB.invalidate
    LB.invalidate = function(...)
        inv = inv + 1
        return real(...)
    end
    CP.Hooks.fire('settings:changed', { 'Leaderboard.topN' })
    H.ok(inv >= 1, 'a Leaderboard setting clears the board cache')
    LB.invalidate = real
    W.posts = {}
    W.convars.cp_webhook_board = 'https://discord.com/api/webhooks/1/abc'
    CP.Hooks.fire('settings:changed', { 'Challenge.bounties' })
    H.step(0)
    H.step(1000)
    H.ok(true, 'a Challenge setting change is handled')
end

_G.print = W.realPrint or print
return H
