-- Full admin control, officers (P1): signed point adjustments, the bulk void and restore engine, restore run, void
-- kinds, flag by hand, retire, XP check, record move, badge overrides, profile tools, streaks, first-run bonus,
-- goals and staff notices. Every action is admin-only, audited and goes through CP.AdminKit.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
local Act, Cb, Data, Rid, Count, One = W.act, W.cb, W.data, W.rid, W.count, W.one
local Kit = CP.AdminKit

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_mission_runs_archive')
H.sql('DELETE FROM cp_audit')

local DAY = 86400

-- an adjustment (one per officer per 10 s across admins: the clock moves on first)
local function Adj(src, p)
    H.clockMs = H.clockMs + 10100
    return Act('server:admin:adjustPoints', src, p)
end

-- ============================================================================
--                         1. ADMIN ONLY, EVERY ACTION
-- ============================================================================

do
    Config.Permissions.supervisor = CP.U.copy(Config.Permissions.supervisor)
    for _, k in ipairs(CP.Permissions.adminOnlyKeys()) do Config.Permissions.supervisor[k] = true end
    local refused = {}
    for _, a in ipairs({
        { 'server:admin:adjustPoints', { citizenid = 'OFF00003', points = 5, reason = 'x', requestId = Rid() } },
        {
            'server:admin:bulkVoid',
            { filter = { citizenid = 'OFF00003', allTime = true }, reason = 'x', requestId = Rid() },
        },
        { 'server:admin:retireOfficer', { citizenid = 'OFF00003', reason = 'x', requestId = Rid() } },
        { 'server:admin:fixXp', { citizenid = 'OFF00003', reason = 'x' } },
        { 'server:admin:grantBadge', { citizenid = 'OFF00003', badgeId = 'iron_wheels', reason = 'x' } },
        { 'server:admin:moveRecord', { from = 'OLD00009', to = 'NEW00009', reason = 'x', requestId = Rid() } },
        { 'server:admin:postNotice', { text = 'hi', expiresAt = H.time + 3600, reason = 'x' } },
        { 'server:admin:resetLook', { citizenid = 'OFF00003', reason = 'x' } },
    }) do
        local ok, e = Act(a[1], 2, a[2])
        if ok ~= false or e ~= 'err.no_permission' then refused[#refused + 1] = a[1] .. '=' .. tostring(e) end
    end
    H.eq(table.concat(refused, ', '), '', 'a supervisor never passes an officers action, even switched on')
    Config.Permissions.supervisor = CP.U.deepcopy(
        CP.Settings and CP.Settings._defaults and CP.Settings._defaults().Permissions.supervisor
            or Config.Permissions.supervisor
    )
end

-- ============================================================================
--                         2. SIGNED POINT ADJUSTMENTS
-- ============================================================================

do
    W.officer('OFF00003', 'sast', 0)
    W.row({ citizenid = 'OFF00003', points = 120, at = H.time - 7200 })
    W.async(function() return CP.Scoring.syncXp('OFF00003') end)
    H.eq(W.xp('OFF00003'), 120, 'the officer has 120 XP from one run')

    local ok, e = Adj(1, { citizenid = 'OFF00003', points = 0, reason = 'x', requestId = Rid() })
    H.ok(not ok and e == 'err.invalid_points', 'zero points are refused: ' .. tostring(e))
    ok, e = Adj(1, { citizenid = 'OFF00003', points = 10001, reason = 'x', confirm = 'OFF00003', requestId = Rid() })
    H.ok(not ok and e == 'err.invalid_points', 'more than 10,000 is refused: ' .. tostring(e))
    ok, e = Adj(1, { citizenid = 'OFF00003', points = -50, requestId = Rid() })
    H.ok(not ok and e == 'err.reason_required', 'a reason is required')

    ok, e = Adj(1, { citizenid = 'OFF00003', points = 40, reason = 'Event host', requestId = Rid() })
    H.ok(ok == true and e.points == 40, 'a positive adjustment')
    H.eq(W.xp('OFF00003'), 160, 'XP 120 + 40')
    local award = One([[SELECT mission_type, mission_id, final_points, JSON_VALUE(breakdown, '$.by') AS by_actor
        FROM cp_mission_runs WHERE id = ?]], { e.rowId })
    H.ok(award.mission_type == 'manual_award' and award.mission_id == 'manual_award' and award.by_actor == 'ADM00001',
        'a manual_award row that says who gave it')

    ok, e = Adj(1, { citizenid = 'OFF00003', points = -50, reason = 'Farmed a call', requestId = Rid() })
    H.ok(ok == true and e.points == -50, 'a deduction: ' .. tostring(e))
    local deduction = e.rowId
    local d = One('SELECT mission_type, mission_id, final_points FROM cp_mission_runs WHERE id = ?', { deduction })
    H.ok(d.mission_type == 'manual_award' and d.mission_id == 'manual_adjust' and tonumber(d.final_points) == -50,
        'a manual_adjust row with negative points')
    H.eq(W.xp('OFF00003'), 110, 'XP 160 - 50')
    H.eq(W.auditCount('pointsAdjust', 'OFF00003'), 1, 'audited as pointsAdjust')

    -- the deduction limit: never below 0
    local pts = Data('admin:getOfficerPoints', 1, { citizenid = 'OFF00003' })
    H.ok(pts and pts.adjust.maxDeduction <= 110,
        'the most a deduction may take is shown: ' .. tostring(pts and pts.adjust.maxDeduction))
    ok, e = Adj(1,
        { citizenid = 'OFF00003', points = -(pts.adjust.maxDeduction + 1), reason = 'too much', requestId = Rid() })
    H.ok(not ok and e == 'err.adjust_too_low', 'a deduction below 0 is refused')

    -- the typed confirmation at or above adjustConfirmAbove
    H.clockMs = H.clockMs + 11000
    ok, e = Adj(1, { citizenid = 'OFF00003', points = 600, reason = 'big', requestId = Rid() })
    H.ok(not ok and e == 'err.confirm_mismatch', 'a big adjustment asks for the citizenid: ' .. tostring(e))
    H.clockMs = H.clockMs + 11000
    ok = Adj(1, { citizenid = 'OFF00003', points = 600, reason = 'big', confirm = 'OFF00003', requestId = Rid() })
    H.eq(ok, true, 'with the citizenid typed')
    H.eq(W.xp('OFF00003'), 710, 'XP 110 + 600')

    -- self: the admin's own characters (by license) are refused; the console may
    W.officer('ALT00001', 'sast', 0)
    ok, e = Adj(1, { citizenid = 'ADM00001', points = 5, reason = 'me', requestId = Rid() })
    H.ok(not ok and e == 'err.self_target', 'the admin\'s own character is refused')
    ok, e = Adj(1, { citizenid = 'ALT00001', points = 5, reason = 'me', requestId = Rid() })
    H.ok(not ok and e == 'err.self_target', 'and the admin\'s second character (same license)')
    H.clockMs = H.clockMs + 11000
    local okC, eC = W.async(function()
        return Kit.run('server:admin:adjustPoints', 0,
            { citizenid = 'ALT00001', points = 5, reason = 'console', requestId = Rid() })
    end)
    H.eq(okC, true, 'the console may: ' .. tostring(eC))

    -- the daily limit, counted from the rows (so it holds across a restart)
    Config.AdminControl.adjustDailyLimit = 700
    H.clockMs = H.clockMs + 11000
    ok, e = Adj(1, { citizenid = 'OFF00003', points = 20, reason = 'limit', requestId = Rid() })
    H.ok(not ok and e == 'err.adjust_daily_limit',
        'over the admin\'s daily limit (40 + 50 + 600 used): ' .. tostring(e))
    ok = Adj(5, { citizenid = 'OFF00003', points = 20, reason = 'other admin', requestId = Rid() })
    H.eq(ok, true, 'another admin has their own limit')
    Config.AdminControl.adjustDailyLimit = 0

    -- off switch for deductions
    Config.AdminControl.pointAdjust = false
    H.clockMs = H.clockMs + 11000
    ok, e = Adj(1, { citizenid = 'OFF00003', points = -5, reason = 'off', requestId = Rid() })
    H.ok(not ok and e == 'err.adjust_off', 'deductions off: refused: ' .. tostring(e))
    Config.AdminControl.pointAdjust = true

    -- undo = void that row; XP stays max(0, signed sum)
    ok = Act('server:admin:voidRun', 1, { rowId = deduction, reason = 'undo', kind = 'correction' })
    H.eq(ok, true, 'the deduction is voided (undo)')
    H.eq(W.xp('OFF00003'), 780, 'XP back up by 50')
    H.eq(W.xp('OFF00003'), W.derived('OFF00003'), 'and equal to the rows')

    -- a supervisor can't flag-and-void a deduction
    H.clockMs = H.clockMs + 11000
    local again, eA = W.async(function()
        return Kit.run('server:admin:adjustPoints', 0,
            { citizenid = 'OFF00003', points = -30, reason = 'again', requestId = Rid() })
    end)
    H.eq(again, true, 'another deduction: ' .. tostring(eA))
    local ded2 = Count([[SELECT MAX(id) AS n FROM cp_mission_runs WHERE mission_id = 'manual_adjust']])
    ok, e = Act('server:admin:flagRow', 1, { rowId = ded2, reason = 'flag' })
    H.ok(not ok and e == 'err.not_reviewable', 'flag by hand refuses a manual row')
    H.sql('UPDATE cp_mission_runs SET flagged = 1 WHERE id = ?', { ded2 })
    ok, e = Act('server:sup:reviewFlagged', 2, { rowId = ded2, decision = 'void', reason = 'erase' })
    H.ok(not ok, 'a supervisor review refuses a deduction: ' .. tostring(e))
    H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ?', { ded2 })

    -- boards sum signed points; run counts ignore both kinds of rows
    CP.Leaderboard.invalidate()
    local board = W.async(function() return CP.Leaderboard.ranking({ period = 'weekly', filter = 'overall' }) end)
    local _, all = W.async(function() return CP.Leaderboard.ranking({ period = 'weekly', filter = 'overall' }) end)
    local e3 = all and all.OFF00003
    H.ok(board ~= nil, 'the weekly board builds')
    H.eq(e3 and e3.points, 120 + 40 + 600 + 20 - 30, 'the weekly board sums the signed points')
    H.eq(e3 and e3.runs, 1, 'and counts one run (manual rows are not runs)')
end

-- ============================================================================
--                           3. THE BULK VOID ENGINE
-- ============================================================================

local batchId
do
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_mission_runs_archive')
    W.officer('OFF00004', 'fib', 0)
    W.officer('OFF00006', 'sast', 0)
    local shared = W.uuid()
    local ids = {}
    for i = 1, 6 do
        ids[#ids + 1] = W.row({
            citizenid = 'OFF00004',
            department = 'fib',
            points = 100,
            at = H.time - i * 3600,
            cash = 300,
            cashStatus = i == 1 and 'held' or 'paid',
            cashPaid = i == 1 and 0 or 300,
        })
    end
    -- an archived row inside the window
    local arch = W.row(
        { citizenid = 'OFF00004', department = 'fib', points = 50, at = H.time - 2 * DAY, archive = true })
    -- a run the admin's second character took part in
    W.row({ citizenid = 'OFF00004', department = 'fib', points = 70, at = H.time - 5000, uuid = shared })
    W.row({ citizenid = 'ALT00001', department = 'sast', points = 70, at = H.time - 5000, uuid = shared })
    -- outside the window
    W.row({ citizenid = 'OFF00004', department = 'fib', points = 999, at = H.time - 20 * DAY })
    W.async(function() return CP.Scoring.syncXp('OFF00004') end)
    H.eq(W.xp('OFF00004'), 600 + 50 + 70 + 999, 'XP from every counted row')

    local filter = {
        citizenid = 'OFF00004',
        from = os.date('%Y-%m-%d', H.time - 3 * DAY),
        to = os.date('%Y-%m-%d', H.time),
    }
    local pv = Data('admin:previewBulkVoid', 1, { filter = filter })
    H.eq(pv and pv.total, 7, 'preview: six live rows and one archived row (the shared run left out)')
    H.eq(pv and pv.excluded, 1, 'the run the admin\'s second character took part in is left out and counted')
    H.eq(pv and pv.archived, 1, 'one of them archived')
    H.eq(pv and pv.held, 300, 'the cash still held')
    H.eq(pv and pv.confirmWord, 'VOID 7', 'the typed word')

    local ok, e = Act('server:admin:bulkVoid', 1, {
        filter = filter,
        reason = 'Bugged week',
        confirm = 'VOID 6',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(not ok and e == 'err.confirm_mismatch', 'the wrong count is refused')
    ok, e = Act('server:admin:bulkVoid', 1,
        { filter = filter, reason = 'Bugged week', confirm = 'VOID 7', requestId = Rid() })
    H.ok(not ok and (e == 'err.preview_missing' or e == 'err.preview_stale'),
        'no preview token: refused: ' .. tostring(e))
    pv = Data('admin:previewBulkVoid', 1, { filter = filter })
    ok, e = Act('server:admin:bulkVoid', 1, {
        filter = filter,
        reason = 'Bugged week',
        confirm = 'VOID 7',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok == true and e.rows == 7, 'the bulk void starts: ' .. tostring(e and e.rows or e))
    batchId = e and e.jobId
    H.ok(W.drain(), 'the job finishes')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE void_batch = ? AND voided = 1', { batchId }), 6,
        'the six live rows carry the batch id')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs_archive WHERE void_batch = ? AND voided = 1', { batchId }), 1,
        'and the archived row')
    H.eq(Count(
        [[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE void_batch = ? AND void_kind = 'correction']],
        { batchId }
    ), 6, 'voided as corrections')
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE void_batch = ?
        AND JSON_VALUE(breakdown, '$.cash.beforeVoid') = 'held']], { batchId }),
        1,
        'each row keeps its cash status'
    )
    H.eq(W.xp('OFF00004'), 70 + 999, 'XP recomputed from the rows at the end')
    H.eq(W.xp('OFF00004'), W.derived('OFF00004'), 'equal to the rows')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'voidRun' AND target LIKE '% OFF00004']]), 7,
        'one audit line per row')
    H.eq(W.auditCount('bulkVoid'), 1, 'and one summary line')
    H.eq(CP.Access.isSuspended and CP.Access.isSuspended('OFF00004') or false, false, 'corrections give no strike')

    -- the forfeiture job forfeits the held row because it is voided; restore puts it back to pending once
    local heldId = ids[1]
    H.sql([[UPDATE cp_mission_runs SET cash_status = 'forfeited' WHERE id = ?]], { heldId })
    local bk = Data('admin:getCorrections', 1, { citizenid = 'OFF00004' })
    local listed = false
    for _, b in ipairs(bk and bk.batches or {}) do
        if b.id == batchId and b.undo == 'restoreBatch' then listed = true end
    end
    H.ok(listed, 'the Corrections tab lists the batch with Undo')
    ok, e = Act('server:admin:restoreBatch', 1, { batchId = batchId, reason = 'Undo', requestId = Rid() })
    H.ok(ok == true and e.rows == 7, 'the batch is restored: ' .. tostring(e and e.rows or e))
    H.ok(W.drain(), 'the restore job finishes')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE void_batch = ?', { batchId }), 0,
        'no row keeps the batch')
    H.eq(W.xp('OFF00004'), 600 + 50 + 70 + 999, 'points and XP come back')
    local held = One('SELECT cash_status FROM cp_mission_runs WHERE id = ?', { heldId })
    H.ok(held.cash_status == 'pending' or held.cash_status == 'paid' or held.cash_status == 'paying',
        'the batch-caused forfeit is pending again: ' .. tostring(held.cash_status))
    ok, e = Act('server:admin:restoreBatch', 1, { batchId = batchId, reason = 'Again', requestId = Rid() })
    H.ok(not ok and e == 'err.batch_restored', 'a batch is restored once')
    H.ok(arch > 0, 'archive row id')

    -- strike voids still count toward the automatic suspension
    pv = Data('admin:previewBulkVoid', 1, { filter = filter })
    ok, e = Act('server:admin:bulkVoid', 1, {
        filter = filter,
        kind = 'strike',
        reason = 'Cheating',
        confirm = 'VOID 7',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.eq(ok, true, 'a strike bulk void')
    W.drain()
    local strikes = W.async(function() return CP.AntiCheat.strikeCount and CP.AntiCheat.strikeCount('OFF00004') end)
    H.ok((tonumber(strikes) or 0) >= 1, 'strike voids count: ' .. tostring(strikes))

    -- setVoidKind changes the count
    local one = ids[2]
    local before = tonumber(strikes) or 0
    ok = Act('server:admin:setVoidKind', 1, { rowId = one, kind = 'correction', reason = 'not a cheat' })
    H.eq(ok, true, 'the kind of one void is changed')
    local after = W.async(function() return CP.AntiCheat.strikeCount('OFF00004') end)
    H.eq(tonumber(after), before - 1, 'the strike count follows')

    -- the cap
    Config.AdminControl.bulkMaxRows = 3
    pv = Data('admin:previewBulkVoid', 1, { filter = { citizenid = 'OFF00006', allTime = true } })
    W.row({ citizenid = 'OFF00006', points = 10 })
    W.row({ citizenid = 'OFF00006', points = 10 })
    W.row({ citizenid = 'OFF00006', points = 10 })
    W.row({ citizenid = 'OFF00006', points = 10 })
    pv = Data('admin:previewBulkVoid', 1, { filter = { citizenid = 'OFF00006', allTime = true } })
    H.ok(pv and pv.tooMany == true and pv.previewToken == nil, 'more rows than bulkMaxRows: no token')
    ok, e = Act('server:admin:bulkVoid', 1,
        { filter = { citizenid = 'OFF00006', allTime = true }, reason = 'x', confirm = 'VOID 4', requestId = Rid() })
    H.ok(not ok and e == 'err.bulk_too_many', 'and the action refuses')
    Config.AdminControl.bulkMaxRows = 5000

    -- the busy lock refuses a storage copy while a job runs
    local okL = Kit.lock('job', { kind = 'test' })
    H.eq(okL, true, 'a job holds the lock')
    if CP.Admin.storageCopy then
        local okS = W.async(function() return CP.Admin.storageCopy(0, 'database-to-files', false) end)
        H.ok(okS ~= true, 'a storage copy waits for the job')
    end
    Kit.unlock('job')
end

-- A bulk void a restart stopped after two batches is finished at start-up, with XP from the rows.
do
    local cjson = require('cjson')
    W.officer('OFF00005X', 'sast', 0)
    local keys = {}
    for i = 1, 120 do keys[#keys + 1] = 'L' .. W.row({ citizenid = 'OFF00005X', points = 5, at = H.time - i * 60 }) end
    W.async(function() return CP.Scoring.syncXp('OFF00005X') end)
    H.eq(W.xp('OFF00005X'), 600, '120 rows of 5 points')
    local jobId = '77777777-0000-4000-8000-000000000001'
    -- the first two batches (100 rows) were voided before the restart; the officer's XP was not recomputed yet
    local first = {}
    for i = 1, 100 do first[i] = tonumber(keys[i]:sub(2)) end
    H.sql(('UPDATE cp_mission_runs SET voided = 1, void_kind = \'correction\', void_batch = ? WHERE id IN (%s)'):format(
        table.concat(first, ', ')
    ), { jobId })
    H.sql([[INSERT INTO cp_admin_jobs (id, kind, state, filter, detail, done, total, actor, reason, created_at,
        updated_at) VALUES (?, 'bulkVoid', 'running', '{}', ?, 100, 120, 'ADM00001', 'restart test', NOW(), NOW())]],
        { jobId, cjson.encode({ kind = 'correction', cids = { 'OFF00005X' }, ids = keys, reason = 'restart test' }) })
    local n = W.async(function() return Kit._resumeJobs() end)
    H.eq(n, 1, 'the interrupted job is finished at start-up')
    W.drain()
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = 'OFF00005X' AND voided = 1
        AND void_batch = ?]], { jobId }),
        120,
        'every row of the job is voided'
    )
    H.eq(W.xp('OFF00005X'), 0, 'XP recomputed from the rows after the resumed job')
    H.eq(One('SELECT state FROM cp_admin_jobs WHERE id = ?', { jobId }).state, 'done', 'the job is done')
end

-- ============================================================================
--                   4. RESTORE RUN, FLAG BY HAND, VOID KIND
-- ============================================================================

do
    local rid = W.row({ citizenid = 'OFF00006', points = 80, cash = 200, cashStatus = 'held', voided = true })
    H.sql([[UPDATE cp_mission_runs SET void_kind = 'strike' WHERE id = ?]], { rid })
    H.sql([[INSERT INTO cp_disputes (run_id, citizenid, reason, status, goes_to, created_at)
        VALUES (?, 'OFF00006', 'not me', 'open', 'supervisor', NOW())]], { rid })
    local ok, e = Act('server:admin:restoreRun', 1, { rowId = rid, reason = 'wrong void' })
    H.ok(ok == true, 'restore run: ' .. tostring(e))
    local r = One('SELECT voided, cash_status FROM cp_mission_runs WHERE id = ?', { rid })
    H.eq(H.bit(r.voided), 0, 'the row counts again')
    H.ok(r.cash_status ~= 'held', 'held cash is released: ' .. tostring(r.cash_status))
    local d = One('SELECT status FROM cp_disputes WHERE run_id = ?', { rid })
    H.eq(d.status, 'approved', 'the open dispute is closed as approved')
    ok, e = Act('server:admin:restoreRun', 1, { rowId = rid, reason = 'again' })
    H.ok(not ok and e == 'err.not_voided', 'a second restore is refused (K)')

    -- forfeited cash stays forfeited
    local fid = W.row({ citizenid = 'OFF00006', points = 30, cash = 100, cashStatus = 'forfeited', voided = true })
    ok = Act('server:admin:restoreRun', 1, { rowId = fid, reason = 'late' })
    H.eq(ok, true, 'a forfeited row is restored')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = ?', { fid }).cash_status, 'forfeited',
        'its cash stays forfeited')

    -- own run refused
    local own = W.uuid()
    local orow = W.row({ citizenid = 'OFF00006', points = 30, voided = true, uuid = own })
    W.row({ citizenid = 'ALT00001', points = 30, uuid = own })
    ok, e = Act('server:admin:restoreRun', 1, { rowId = orow, reason = 'mine' })
    H.ok(not ok and (e == 'err.self_target' or e == 'err.own_run'), 'a run the admin took part in: ' .. tostring(e))

    -- flag by hand
    local frow = W.row({ citizenid = 'OFF00006', points = 90 })
    W.async(function() return CP.Scoring.syncXp('OFF00006') end)
    local xp0 = W.xp('OFF00006')
    ok = Act('server:admin:flagRow', 1, { rowId = frow, reason = 'looks odd' })
    H.eq(ok, true, 'flagged by hand')
    H.eq(W.xp('OFF00006'), xp0 - 90, 'its XP is held')
    ok, e = Act('server:admin:flagRow', 1, { rowId = frow, reason = 'again' })
    H.ok(not ok and e == 'err.state_changed', 'flagging twice is refused (K)')
end

-- ============================================================================
--                     5. RETIRE, XP CHECK, PROFILE HIDDEN
-- ============================================================================

do
    H.sql([[UPDATE cp_officers SET bio = 'My bio', avatar_kind = 'url', avatar_value = 'https://i.imgur.com/a.png',
        avatar_status = 'approved' WHERE citizenid = 'OFF00006']])
    W.onRun[6] = { id = W.uuid() }
    local pv = Data('admin:previewRetire', 1, { citizenid = 'OFF00006' })
    H.ok(pv and pv.busy == 'err.officer_on_run', 'the preview says the officer is on a run')
    local ok, e = Act('server:admin:retireOfficer', 1, {
        citizenid = 'OFF00006',
        reason = 'Left',
        confirm = 'OFF00006',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(not ok and e == 'err.officer_on_run', 'retire is refused while on a run')
    W.onRun[6] = nil

    pv = Data('admin:previewRetire', 1, { citizenid = 'OFF00006' })
    ok, e = Act('server:admin:retireOfficer', 1, {
        citizenid = 'OFF00006',
        reason = 'Left',
        confirm = 'OFF00006',
        previewToken = pv.previewToken,
        requestId = Rid(),
        excludeFromBoards = true,
    })
    H.ok(ok == true, 'retired: ' .. tostring(e))
    W.drain()
    local o = One('SELECT retired_at, board_excluded, bio, avatar_value FROM cp_officers WHERE citizenid = ?',
        { 'OFF00006' })
    H.ok(o.retired_at ~= nil and H.bit(o.board_excluded) == 1, 'retired and off the boards')
    H.ok(o.bio == 'My bio' and o.avatar_value ~= nil, 'picture and bio are kept (hidden, not cleared)')
    local okT, eT = CP.Access.getOfficer(6)
    H.ok(not okT and eT == 'err.retired', 'a retired officer can\'t open the tablet: ' .. tostring(eT))
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = 'OFF00006' AND voided = 0]]), 0,
        'every row is voided')
    H.eq(W.xp('OFF00006'), 0, 'XP from the rows: 0')
    local prof = W.async(function() return CP.Leaderboard.profileOf and CP.Leaderboard.profileOf('OFF00006') end)
    if type(prof) == 'table' then H.ok(prof.bio == nil, 'the bio is hidden while retired') end

    ok, e = Act('server:admin:unretireOfficer', 1, { citizenid = 'OFF00006', reason = 'Back', requestId = Rid() })
    H.ok(ok == true, 'unretired: ' .. tostring(e))
    W.drain()
    o = One('SELECT retired_at, board_excluded FROM cp_officers WHERE citizenid = ?', { 'OFF00006' })
    H.ok(o.retired_at == nil and H.bit(o.board_excluded) == 0, 'back on the boards')
    H.ok(CP.Access.getOfficer(6) ~= nil, 'the tablet opens again')
    H.ok(W.xp('OFF00006') > 0, 'the rows count again')

    -- XP check finds and fixes drift (live + archive)
    W.row({ citizenid = 'OFF00006', points = 40, archive = true })
    H.sql([[UPDATE cp_officers SET xp = 5 WHERE citizenid = 'OFF00006']])
    local chk = Data('admin:checkXp', 1, { citizenid = 'OFF00006' })
    H.ok(chk and chk.stored == 5 and chk.derived == W.derived('OFF00006') and chk.diff ~= 0, 'XP check finds the drift')
    ok, e = Act('server:admin:fixXp', 1, { citizenid = 'OFF00006', reason = 'drift' })
    H.ok(ok == true and e.new == chk.derived, 'Fix writes what the rows give')
    H.eq(W.auditCount('xpFix', 'OFF00006'), 1, 'audited')
end

-- ============================================================================
--                                6. RECORD MOVE
-- ============================================================================

do
    W.officer('OLD00009', 'sast', 0, { license = W.LIC9 })
    W.row({ citizenid = 'OLD00009', points = 100 })
    W.row({ citizenid = 'OLD00009', points = 50, archive = true })
    H.sql([[INSERT INTO cp_badges (citizenid, badge_id, earned_at) VALUES ('OLD00009', 'iron_wheels', NOW())]])
    W.async(function() return CP.Scoring.syncXp('OLD00009') end)

    local res = Cb('admin:previewRecordMove', 1, { from = 'OLD00009', to = 'NEW00010' })
    H.ok(res and res.ok == false and res.error == 'err.record_move_license',
        'a different license is refused: ' .. tostring(res and res.error))
    local pv = Data('admin:previewRecordMove', 1, { from = 'OLD00009', to = 'NEW00009' })
    H.ok(pv and pv.verified == true and pv.confirmWord == 'NEW00009', 'same license: verified, type the new citizenid')
    H.eq(pv and pv.effect.rows, 2, 'two rows move (live and archive)')
    H.eq(pv and pv.effect.badges, 1, 'and the badge')

    -- refused with a paying row
    local payId = W.row({ citizenid = 'OLD00009', points = 1, cashStatus = 'paying' })
    res = Cb('admin:previewRecordMove', 1, { from = 'OLD00009', to = 'NEW00009' })
    H.ok(res and res.error == 'err.record_move_paying', 'refused while a payment is paying')
    H.sql('DELETE FROM cp_mission_runs WHERE id = ?', { payId })

    pv = Data('admin:previewRecordMove', 1, { from = 'OLD00009', to = 'NEW00009' })
    local ok, e = Act('server:admin:moveRecord', 1, {
        from = 'OLD00009',
        to = 'NEW00009',
        reason = 'Re-created',
        confirm = 'NEW00009',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok == true, 'moved: ' .. tostring(e))
    local jobId = ok and e.jobId or nil
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = 'NEW00009']]), 1, 'the live row moved')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_mission_runs_archive WHERE citizenid = 'NEW00009']]), 1,
        'the archived row')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_badges WHERE citizenid = 'NEW00009']]), 1, 'the badge')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_officers WHERE citizenid = 'OLD00009']]), 0, 'the old record is gone')
    H.eq(One([[SELECT department FROM cp_mission_runs WHERE citizenid = 'NEW00009']]).department, 'sast',
        'rows keep their department')
    H.eq(W.xp('NEW00009'), 150, 'XP recomputed from the rows')

    ok, e = Act('server:admin:undoRecordMove', 1, { jobId = jobId, reason = 'Mistake' })
    H.ok(ok == true, 'undo: ' .. tostring(e))
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = 'OLD00009']]), 1, 'moved back')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_officers WHERE citizenid = 'OLD00009']]), 1, 'the record is back')

    -- the target has rows of its own: refused
    W.row({ citizenid = 'NEW00009', points = 5 })
    res = Cb('admin:previewRecordMove', 1, { from = 'OLD00009', to = 'NEW00009' })
    H.ok(res and res.error == 'err.record_move_has_rows', 'a target with rows is refused')
    -- an online character is refused
    res = Cb('admin:previewRecordMove', 1, { from = 'OFF00003', to = 'NEW00009' })
    H.ok(res and res.error == 'err.record_move_online', 'an online character is refused')
end

-- ============================================================================
--                              7. BADGE OVERRIDES
-- ============================================================================

do
    local ok, ge = Act('server:admin:grantBadge', 1,
        { citizenid = 'OFF00003', badgeId = 'iron_wheels', reason = 'Lost it to a bug' })
    H.eq(ok, true, 'a badge is granted: ' .. tostring(ge))
    local added, removed = W.async(function() return CP.Scoring.recheckBadges('OFF00003') end)
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_badges WHERE citizenid = 'OFF00003' AND badge_id = 'iron_wheels']]), 1,
        'a granted badge survives a re-check')
    H.ok(type(removed) == 'table' and #removed == 0 and type(added) == 'table', 'nothing removed')
    ok = Act('server:admin:revokeBadge', 1, { citizenid = 'OFF00003', badgeId = 'iron_wheels', reason = 'Not earned' })
    H.eq(ok, true, 'revoked')
    Config.Badges = CP.U.copy(Config.Badges)
    Config.Badges.roadWarrior = 1
    ok = Act('server:admin:revokeBadge', 1, { citizenid = 'OFF00003', badgeId = 'road_warrior', reason = 'Blocked' })
    H.eq(ok, true, 'a badge is blocked')
    W.async(function() return CP.Scoring.recheckBadges('OFF00003') end)
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_badges WHERE citizenid = 'OFF00003' AND badge_id = 'road_warrior']]), 0,
        'a blocked badge is never added again')
    Config.Badges.roadWarrior = 100
    local o = Data('admin:getOfficer', 1, { citizenid = 'OFF00003' })
    local blocked = false
    for _, b in ipairs(o and o.badges or {}) do
        if b.id == 'road_warrior' and b.source == 'blocked' then blocked = true end
    end
    H.ok(blocked, 'the officer record shows the block')
    local okB, eB = Act('server:admin:grantBadge', 1, { citizenid = 'OFF00003', badgeId = 'nope', reason = 'x' })
    H.ok(not okB and eB == 'err.badge_unknown', 'an unknown badge is refused')
end

-- ============================================================================
--                  8. PROFILE TOOLS, STREAK, FIRST RUN, GOALS
-- ============================================================================

do
    H.sql([[UPDATE cp_officers SET accent = '#ff0000', ui_scale = 1.2 WHERE citizenid = 'OFF00003']])
    local ok, e = Act('server:admin:resetLook', 1, { citizenid = 'OFF00003', reason = 'Unreadable' })
    H.ok(ok == true, 'reset look: ' .. tostring(e))
    local o = One('SELECT accent, ui_scale FROM cp_officers WHERE citizenid = ?', { 'OFF00003' })
    H.ok(o.accent == nil and o.ui_scale == nil, 'the look is back to the defaults')

    ok, e = Act('server:admin:clearProfileCooldown', 1, { citizenid = 'OFF00003', reason = 'Typo' })
    H.ok(ok == true, 'profile cooldown cleared: ' .. tostring(e))

    -- first-run bonus: once per day per officer, counted from cp_audit
    ok, e = Act('server:admin:resetFirstRun', 1, { citizenid = 'OFF00003', reason = 'Crash' })
    H.ok(ok == true, 'first-run bonus available again: ' .. tostring(e))
    ok, e = Act('server:admin:resetFirstRun', 1, { citizenid = 'OFF00003', reason = 'Again' })
    H.ok(not ok and e == 'err.once_a_day', 'once a day')
    ok, e = Act('server:admin:resetFirstRun', 5, { citizenid = 'OFF00003', reason = 'Other admin' })
    H.ok(not ok and e == 'err.once_a_day', 'for every admin (counted from the audit rows)')

    -- streak recalc from rows
    ok, e = Act('server:admin:recalcStreak', 1, { citizenid = 'OFF00003', reason = 'stale' })
    H.ok(ok == true and type(e.new) == 'table', 'streak recalculated: ' .. tostring(e))
    ok, e = Act('server:admin:forgiveStreakDays', 1, { citizenid = 'OFF00003', days = 99, reason = 'downtime' })
    H.ok(not ok and e == 'err.invalid_days', 'forgive is capped at streakForgiveMax')

    -- banned words: file write with .bak and live reload
    local okW, eW = Act('server:admin:setBannedWords', 1, { add = { 'zorkle' }, remove = {}, reason = 'new slur' })
    H.ok(okW == true, 'banned words saved: ' .. tostring(eW))
    local file = Config.Profile.bannedWordsFile
    H.ok(W.files[file] and W.files[file]:find('zorkle', 1, true) ~= nil, 'the file is written')
    H.ok(W.files[file .. '.bak'] ~= nil, 'the old file is kept as .bak')
    local test = Data('admin:testBannedWords', 1, { text = 'you zorkle' })
    H.ok(test and test.banned == true, 'the new word is caught at once (live reload)')

    -- staff notices
    ok, e = Act('server:admin:postNotice', 1,
        { text = 'Training night Friday 8 pm', expiresAt = H.time + DAY, reason = 'event' })
    H.ok(ok == true, 'a staff notice is posted: ' .. tostring(e))
    local nid = ok and e.id
    local ann = W.async(function() return CP.Leaderboard.announcements('sast') end)
    local shown = false
    for _, a in ipairs(ann or {}) do
        if type(a) == 'table' and tostring(a.text):find('Training night', 1, true) then shown = true end
    end
    H.ok(shown, 'shown on Home')
    ok, e = Act('server:admin:postNotice', 1, { text = 'you zorkle', expiresAt = H.time + DAY, reason = 'x' })
    H.ok(not ok and (e == 'err.notice_banned' or e == 'err.rate_limited'), 'a banned word is refused: ' .. tostring(e))
    ok, e = Act('server:admin:postNotice', 5, { text = 'Too long', expiresAt = H.time + 31 * DAY, reason = 'x' })
    H.ok(not ok and e == 'err.notice_expiry', 'expiry over 30 days is refused')
    H.time = H.time + DAY + 60
    CP.Leaderboard.invalidate()
    ann = W.async(function() return CP.Leaderboard.announcements('sast') end)
    shown = false
    for _, a in ipairs(ann or {}) do
        if type(a) == 'table' and tostring(a.text):find('Training night', 1, true) then shown = true end
    end
    H.ok(not shown, 'gone at its expiry')
    H.ok(nid ~= nil, 'notice id')
end

-- ============================================================================
--                     9. LOCALE KEYS OF THIS PACKAGE EXIST
-- ============================================================================

do
    local merged = CP.Locale.all()
    local missing = {}
    for _, file in ipairs({ 'modules/corrections/server.lua' }) do
        local src = assert(io.open(H.root .. file, 'r')):read('a')
        for key in src:gmatch('\'([%a_]+%.[%w_%.]+)\'') do
            local ns = key:match('^([%a_]+)%.')
            if (ns == 'err' or ns == 'admin') and not key:match('%.$') and merged[key] == nil then
                missing[#missing + 1] = key
            end
        end
    end
    H.eq(table.concat(missing, ', '), '', 'every locale key of modules/corrections exists')
end

_G.print = W.realPrint or print
return H
