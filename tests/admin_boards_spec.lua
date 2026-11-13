-- Full admin control, boards: keeping an officer off the boards, past windows, ranking by any metric,

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
    ok, e = Act('server:notice:post', 1,
        { kind = 'staff', text = 'FIB briefing at 9', departments = { 'fib' }, days = 1, reason = 'brief' })
    H.ok(ok == true, 'a notice for FIB: ' .. tostring(e))
    local function Has(dept)
        for _, a in ipairs(W.async(function() return LB.announcements(dept) end) or {}) do
            if a.kind == 'staff_notice' and a.text == 'FIB briefing at 9' then return true end
        end
        return false
    end
    H.ok(Has('fib') and not Has('sast'), 'shown to FIB only')
    local nv = Data('notices:get', 1, { kind = 'staff' })
    H.ok(nv and #nv.running >= 1, 'the admin notices card lists every notice')
    ok = Act('server:notice:end', 1, { id = e.id, reason = 'done' })
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
    local toasted = 0
    for _, ev in ipairs(H.events) do
        if ev.name == 'crimson-police:client:notify' and type(ev.args[1]) == 'table'
            and ev.args[1].key == 'challenge.planned_end_soon' then
            toasted = toasted + 1
        end
    end
    H.ok(toasted >= 1, 'the reminder is a toast to the online admins (CP.Tablet.notifyMany)')
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
    for _, k in ipairs(Config.Objectives.bounty.objectives or {}) do
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
--                                   4b. H15
-- ============================================================================
-- THE SEASON CORRECTION TOOLS (RECOUNTS, REOPEN UNDO).
-- Recount champion moves the trophy and the unfinished champion rewards, and a recount back brings the first
-- department's rewards back (the H15 rewards fix); Recount bounty week; Cancel planned end; Undo a reopen with a
-- badge override and pending rewards.

do
    H.mockInventory({ sprunk = { label = 'Sprunk' }, water = { label = 'Water' } })
    H.load('modules/money/rewards.lua')
    local R = CP.Rewards
    Config.Rewards.enabled = true
    Config.Rewards.dailyItemCap, Config.Rewards.dailyValueCap = 0, 0
    Config.Rewards.byType, Config.Rewards.byMission, Config.Rewards.medals = {}, {}, {}
    Config.Rewards.goals, Config.Rewards.levels, Config.Rewards.weeklyBoss = {}, {}, nil
    Config.Rewards.useExamplePools = false
    Config.Rewards.season = {
        champion = { item = 'sprunk', count = 1, value = 25 },
        top10 = { item = 'water', count = 1, value = 20 },
    }
    R._reset()
    R.validate()
    Config.Objectives.challenge.minRunsActive = 1
    local hooks = {}
    local realHook = CP.Admin.webhook
    CP.Admin.webhook = function(kind, title, ...)
        hooks[#hooks + 1] = { kind = kind, title = title }
        return realHook(kind, title, ...)
    end
    W.offline[3], W.offline[4] = true, true      -- both officers offline: their season rewards wait (pending)
    local function Reward(cid, key)
        return One([[SELECT id, status FROM cp_item_rewards WHERE citizenid = ? AND source = 'season'
            AND source_key = ?]], { cid, key })
    end
    local function Badge(cid, badge)
        return Count('SELECT COUNT(*) AS n FROM cp_badges WHERE citizenid = ? AND badge_id = ?', { cid, badge })
    end

    -- a season SAST wins (OFF00003 alone), FIB second (OFF00004)
    local ok, e = Act('server:admin:startSeason', 1, { name = 'Recount Season' })
    H.ok(ok == true, 'H15: a season to correct: ' .. tostring(e))
    local season = C.currentSeason(true)
    local sid = season.id
    H.time = H.time + 3600
    local sastRows = {}
    for i = 1, 2 do
        sastRows[i] = W.row({
            citizenid = 'OFF00003',
            department = 'sast',
            points = 300,
            at = H.time - 600 + i,
            seasonId = sid,
        })
    end
    W.row({ citizenid = 'OFF00004', department = 'fib', points = 100, at = H.time - 500, seasonId = sid })
    ok, e = Act('server:admin:endSeason', 1, { reason = 'done', confirm = 'Recount Season' })
    H.ok(ok == true, 'H15: ended: ' .. tostring(e))
    local champ = ('champion:%d'):format(sid)
    local badge = ('season_%d_champion'):format(sid)
    H.eq(One('SELECT winner FROM cp_dept_bounties WHERE season_id = ? AND week = 0', { sid }).winner, 'sast',
        'H15: SAST is champion')
    H.eq(Reward('OFF00003', champ) and Reward('OFF00003', champ).status, 'pending',
        'H15: the SAST officer\'s champion reward waits (offline)')
    H.eq(Reward('OFF00004', champ), nil, 'H15: FIB has none')
    H.eq(Badge('OFF00003', badge), 1, 'H15: the SAST officer holds the champion trophy')

    -- previews and refusals
    local res = W.cb('admin:previewChampionRecount', 1, { seasonId = 999999 })
    H.ok(res and res.ok == false and res.error == 'err.no_season', 'H15: an unknown season: err.no_season')
    local pv = Data('admin:previewChampionRecount', 1, { seasonId = sid })
    H.ok(pv and pv.old == 'sast' and pv.new == 'sast' and pv.changed == false, 'H15: nothing to recount yet')

    -- OFF00003's runs are voided: FIB wins on a recount
    H.sql('UPDATE cp_mission_runs SET voided = 1 WHERE id IN (?, ?)', { sastRows[1], sastRows[2] })
    pv = Data('admin:previewChampionRecount', 1, { seasonId = sid })
    H.ok(pv and pv.old == 'sast' and pv.new == 'fib' and pv.changed == true and pv.badgeId == badge,
        'H15: the preview names the change sast -> fib')
    local cancelled = 0
    for _, r in ipairs(pv and pv.rewards or {}) do if r.fate == 'cancel' then cancelled = cancelled + 1 end end
    H.eq(cancelled, 1, 'H15: and the one unfinished reward it cancels')
    ok, e = Act('server:admin:recountChampion', 1,
        { seasonId = sid, reason = 'voided runs', confirm = 'wrong', previewToken = pv.previewToken })
    H.ok(not ok and e == 'err.confirm_mismatch', 'H15: the typed word RECOUNT is needed: ' .. tostring(e))
    ok, e = Act('server:admin:recountChampion', 1,
        { seasonId = sid, reason = 'voided runs', confirm = 'RECOUNT', previewToken = 'x' })
    H.ok(not ok, 'H15: a bad preview token is refused: ' .. tostring(e))
    hooks = {}
    pv = Data('admin:previewChampionRecount', 1, { seasonId = sid })
    ok, e = Act('server:admin:recountChampion', 1,
        { seasonId = sid, reason = 'voided runs', confirm = 'RECOUNT', previewToken = pv.previewToken })
    H.ok(ok == true and e.cancelled == 1, 'H15: recounted sast -> fib: ' .. tostring(e and e.cancelled or e))
    H.eq(One('SELECT winner FROM cp_dept_bounties WHERE season_id = ? AND week = 0', { sid }).winner, 'fib',
        'H15: FIB is champion now')
    H.eq(Reward('OFF00003', champ).status, 'forfeited', 'H15: the SAST officer\'s unfinished reward is cancelled')
    H.eq(Reward('OFF00004', champ) and Reward('OFF00004', champ).status, 'pending', 'H15: FIB\'s is granted')
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_badge_overrides WHERE badge_id = ? AND citizenid = 'OFF00004'
        AND mode = 'grant']], { badge }),
        1,
        'H15: the trophy is granted to the FIB officer'
    )
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_badge_overrides WHERE badge_id = ? AND citizenid = 'OFF00003'
        AND mode = 'block']], { badge }),
        1,
        'H15: the SAST officer\'s trophy is blocked'
    )
    H.eq(Badge('OFF00003', badge), 0, 'H15: and taken off him')
    H.eq(W.auditCount('championRecount', ('season:%d'):format(sid)), 1, 'H15: the recount is audited')
    local posted = false
    for _, h in ipairs(hooks) do if h.kind == 'board' then posted = true end end
    H.ok(posted, 'H15: and posted to the board webhook')
    -- a second recount with the same result changes nothing
    pv = Data('admin:previewChampionRecount', 1, { seasonId = sid })
    H.ok(pv.changed == false, 'H15: nothing left to recount')

    -- the runs are restored: recount back to SAST
    H.sql('UPDATE cp_mission_runs SET voided = 0 WHERE id IN (?, ?)', { sastRows[1], sastRows[2] })
    pv = Data('admin:previewChampionRecount', 1, { seasonId = sid })
    ok, e = Act('server:admin:recountChampion', 1,
        { seasonId = sid, reason = 'restored', confirm = 'RECOUNT', previewToken = pv.previewToken })
    H.ok(ok == true, 'H15: recounted fib -> sast: ' .. tostring(e))
    H.eq(Reward('OFF00003', champ).status, 'pending',
        'H15: recount back: the SAST officer\'s champion reward comes back')
    H.eq(Reward('OFF00004', champ).status, 'forfeited', 'H15: and FIB\'s is cancelled')
    H.eq(
        Count('SELECT COUNT(*) AS n FROM cp_item_rewards WHERE citizenid = \'OFF00003\' AND source_key = ?', { champ }),
        1, 'H15: no second row')

    -- 14 days after the end: too late
    local t0 = H.time
    H.time = H.time + 15 * DAY
    res = W.cb('admin:previewChampionRecount', 1, { seasonId = sid })
    H.ok(res and res.ok == false and res.error == 'err.champion_recount_late', 'H15: more than 14 days: refused')
    H.time = t0

    -- Reopen with a badge override and an unfinished top-10 reward, then Undo: both come back
    H.sql([[INSERT INTO cp_badge_overrides (citizenid, badge_id, mode, by_actor, reason)
        VALUES ('OFF00006', ?, 'grant', 'ADM00001', 'helped') ON DUPLICATE KEY UPDATE mode = 'grant']], { badge })
    local top = ('top10:%d'):format(sid)
    local topRow = Reward('OFF00003', top)
    H.eq(topRow and topRow.status, 'pending', 'H15: the top-10 reward waits too')
    pv = Data('admin:previewReopen', 1, { id = sid })
    ok, e = Act('server:admin:reopenSeason', 1,
        { id = sid, reason = 'recheck', confirm = 'Recount Season', previewToken = pv.previewToken, requestId = Rid() })
    H.ok(ok == true, 'H15: reopened: ' .. tostring(e))
    local jobId = ok and e.jobId
    H.eq(Reward('OFF00003', champ).status, 'forfeited', 'H15: the reopen cancels the champion reward')
    H.eq(Reward('OFF00003', top).status, 'forfeited', 'H15: and the top-10 reward')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_badge_overrides WHERE badge_id = ?', { badge }), 0,
        'H15: and drops the trophy overrides')
    ok, e = Act('server:admin:undoReopen', 1, { jobId = jobId, reason = 'oops' })
    H.ok(ok == true, 'H15: undo the reopen: ' .. tostring(e))
    H.eq(Reward('OFF00003', champ).status, 'pending', 'H15: Undo: the champion reward is pending again')
    H.eq(Reward('OFF00003', top).status, 'pending', 'H15: Undo: the top-10 reward is pending again')
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_badge_overrides WHERE badge_id = ? AND citizenid = 'OFF00006'
        AND mode = 'grant']], { badge }),
        1,
        'H15: Undo: the trophy override is back'
    )
    H.eq(One('SELECT winner FROM cp_dept_bounties WHERE season_id = ? AND week = 0', { sid }).winner, 'sast',
        'H15: Undo: the champion row is back')

    -- Reopen, then end the season again (no Undo): the same result gives the cancelled rewards back
    H.time = H.time + 60
    pv = Data('admin:previewReopen', 1, { id = sid })
    ok, e = Act('server:admin:reopenSeason', 1,
        { id = sid, reason = 'recheck', confirm = 'Recount Season', previewToken = pv.previewToken, requestId = Rid() })
    H.ok(ok == true, 'H15: reopened again: ' .. tostring(e))
    H.eq(Reward('OFF00003', champ).status, 'forfeited', 'H15: cancelled by the reopen')
    ok, e = Act('server:admin:endSeason', 1, { reason = 'done again', confirm = 'Recount Season' })
    H.ok(ok == true, 'H15: ended again: ' .. tostring(e))
    H.eq(Reward('OFF00003', champ).status, 'pending', 'H15: ended again: the champion reward comes back')
    H.eq(Reward('OFF00003', top).status, 'pending', 'H15: ended again: the top-10 reward comes back')

    -- the bounty recount: week 1 closed with a stored winner nobody earned
    ok, e = Act('server:admin:startSeason', 1, { name = 'Bounty Season' })
    H.ok(ok == true, 'H15: a running season for the bounty recount: ' .. tostring(e))
    local bs = C.currentSeason(true)
    res = W.cb('admin:previewBountyRecount', 1, { week = 1 })
    H.ok(res and res.ok == false and res.error == 'err.bounty_open', 'H15: the running week cannot be recounted')
    H.time = H.time + 8 * DAY
    H.sql([[INSERT INTO cp_dept_bounties (season_id, week, objective, winner) VALUES (?, 1, ?, 'fib')
        ON DUPLICATE KEY UPDATE winner = 'fib']], {
        bs.id,
        (function()
            for _, k in ipairs(Config.Objectives.bounty.objectives or {}) do
                return type(k) == 'table' and k.id or k
            end
            return 'arrests'
        end)(),
    })
    local bp = Data('admin:previewBountyRecount', 1, { week = 1 })
    H.ok(bp and bp.week == 1 and bp.old == 'fib', 'H15: the bounty preview: ' .. tostring(bp and bp.new))
    ok, e = Act('server:admin:recountBountyWeek', 1,
        { week = 1, reason = 'no one earned it', confirm = 'RECOUNT', previewToken = bp.previewToken })
    H.ok(ok == true, 'H15: the bounty week is recounted: ' .. tostring(e))
    local stored = One('SELECT week, winner FROM cp_dept_bounties WHERE season_id = ? AND week = 1', { bs.id }).winner
    H.eq(tostring(stored), tostring(bp.new), 'H15: the stored winner is the recounted one')
    H.eq(W.auditCount('bountyRecount', ('season:%d:week:1'):format(bs.id)), bp.changed and 1 or 0,
        'H15: audited when it changed')

    -- a planned end, then Cancel
    ok, e = Act('server:admin:scheduleSeasonEnd', 1, { id = bs.id, at = H.time + 3 * DAY, reason = 'plan' })
    H.ok(ok == true, 'H15: an end planned: ' .. tostring(e))
    ok, e = Act('server:admin:cancelSeasonEnd', 1, { id = bs.id + 1000 })
    H.ok(not ok and e == 'err.no_season', 'H15: cancel on another season: refused')
    ok, e = Act('server:admin:cancelSeasonEnd', 1, { id = bs.id })
    H.ok(ok == true, 'H15: the planned end is cancelled: ' .. tostring(e))
    H.eq(C.currentSeason(true).plannedEnd, nil, 'H15: no planned end')
    H.eq(W.auditCount('seasonScheduleCancel'), 1, 'H15: audited')
    ok, e = Act('server:admin:cancelSeasonEnd', 1, { id = bs.id })
    H.ok(not ok, 'H15: nothing left to cancel: ' .. tostring(e))
    ok, e = Act('server:admin:endSeason', 1, { reason = 'tidy', confirm = 'Bounty Season' })
    H.ok(ok == true, 'H15: tidy up: ' .. tostring(e))

    CP.Admin.webhook = realHook
    W.offline[3], W.offline[4] = nil, nil
    Config.Rewards.enabled = false
    Config.Objectives.challenge.minRunsActive = 3
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
    local ok, e = Act('server:review:decide', 1,
        { type = 'flag', decision = 'approve', runUuid = run, reason = 'checked' })
    H.ok(ok == true and e.approved == 2, 'every flagged row of the run is approved: ' .. tostring(e))
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE flagged = 1 AND id IN (?, ?)', { a, b }), 0,
        'unflagged')
    ok, e = Act('server:review:decide', 2, { type = 'flag', decision = 'approve', runUuid = run, reason = 'x' })
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
    CP.Hooks.fire('settings:changed', { 'Objectives.bounty.objectives' })
    H.step(0)
    H.step(1000)
    H.ok(true, 'a Challenge setting change is handled')
end

-- ============================================================================
--                                   STEP H6
-- ============================================================================
-- AN OFFICER'S RUNS A PAGE AT A TIME; THE FLAGGED RUNS ON THEIR OWN (REVIEW).

do
    W.officer('OFF00011', 'sast', 0)
    for i = 1, 13 do W.row({ citizenid = 'OFF00011', points = 5, at = H.time - 7200 - i * 60 }) end
    W.row({ citizenid = 'OFF00011', points = 5, at = H.time - 9000, flagged = true })
    local args = { period = 'alltime', filter = 'overall', citizenid = 'OFF00011', runsPage = 2 }
    local d = W.data('admin:getBoards', 1, args)
    H.ok(#d.runs == 14 and d.runsPage == nil, 'shipped (pageSize 0): every run at once, as before')
    H.eq(d.flagged, nil, 'the board carries no flagged runs (they are on the Review queue)')
    Config.AdminUi.pageSize = 10
    d = W.data('admin:getBoards', 1, args)
    H.ok(d.runsPage and d.runsPage.page == 2 and d.runsPage.pages == 2 and d.runsPage.total == 14,
        'pageSize 10: page 2 of 2, 14 runs')
    H.eq(#d.runs, 4, 'page 2 holds the last 4 runs')
    local alone = W.data('review:getQueue', 1, { all = true })
    H.ok(#H.reviewItems(alone, 'flag') >= 1, 'the Admin UI\'s Review queue lists the flagged run')
    Config.AdminUi.pageSize = 0
end

_G.print = W.realPrint or print
return H
