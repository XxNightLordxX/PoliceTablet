-- One history per run (FIN4, modules/review/history.lua): the rows of the run (live and archived), its flags and

-- One history per run (FIN4, modules/review/history.lua): the rows of the run (live and archived), its flags and
-- staff notes, the decisions on its rows, its disputes and the correction batch that voided a row come back as one
-- timeline, oldest first. The smallest database case for the new reads; the queue's History button and the Admin UI's
-- run detail draw this list.

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', realLocale = true })
for _, t in ipairs({ 'cp_audit', 'cp_disputes', 'cp_mission_runs', 'cp_mission_runs_archive', 'cp_admin_jobs' }) do
    H.sql('DELETE FROM ' .. t)
end
H.load('modules/review/history.lua')

local function Run(tbl, cid, at, batch)
    H.sql((
        'INSERT INTO %s (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, '
        .. 'points_base, cash_paid, cash_status, void_batch, created_at) VALUES (\'run-h\', \'patrol\', '
        .. '\'beat_patrol\', ?, \'sast\', \'completed\', \'completed\', 60, 0, \'none\', ?, ?)'
    ):format(tbl), { cid, batch, at })
    return H.sql(('SELECT id FROM %s WHERE citizenid = ?'):format(tbl), { cid })[1].id
end
local function Audit(action, target, old, new, reason, at)
    H.sql([[INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason, created_at)
        VALUES ('SUP00002', 'supervisor', 'flags', ?, ?, ?, ?, ?, ?)]], { action, target, old, new, reason, at })
end

local r1 = Run('cp_mission_runs', 'OFF00001', '2026-01-01 10:00:00', 'batch-1')
local r2 = Run('cp_mission_runs_archive', 'OFF00002', '2026-01-01 10:00:01', nil)
Audit('runFlagged', 'run-h', 'OFF00001', 'too_fast', 'Arrived in 4 s', '2026-01-01 10:00:02')
Audit('voidFlagged', ('#%d OFF00001'):format(r1), 'flagged', 'voided', 'Teleported', '2026-01-01 11:00:00')
Audit('approveFlagged', '#999 OTHER', 'flagged', 'approved', 'Another run', '2026-01-01 11:30:00')
H.sql([[INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to, status, created_at)
    VALUES (?, 'OFF00001', 'I had lag', 'supervisor', 'open', '2026-01-01 12:00:00')]], { r1 })
H.sql([[INSERT INTO cp_admin_jobs (id, kind, state, done, total, actor, reason, created_at)
    VALUES ('batch-1', 'bulkVoid', 'done', 1, 1, 'ADM00001', 'Bad event', '2026-01-02 09:00:00')]])

local h = CP.Review.history('run-h')
local kinds = {}
for _, e in ipairs(h.events) do kinds[#kinds + 1] = e.kind .. ':' .. tostring(e.action) end
H.eq(table.concat(kinds, ' '),
    'row:completed row:completed flag:runFlagged decision:voidFlagged dispute:opened batch:bulkVoid',
    'one timeline, oldest first: both rows, the flag, the decision, the dispute, the batch (never another run)')
local byKind = {}
for _, e in ipairs(h.events) do byKind[e.kind .. (e.citizenid or '')] = e end
H.ok(byKind.rowOFF00002 and byKind.rowOFF00002.rowId == r2, 'an archived row counts')
H.ok(byKind.flagOFF00001.new == 'too_fast' and byKind.flagOFF00001.detail == 'Arrived in 4 s', 'the flag kind and text')
local d = byKind.decisionOFF00001
H.ok(d and d.rowId == r1 and d.actor == 'SUP00002' and d.reason == 'Teleported', 'the decision: its row, who, why')
H.eq(byKind.disputeOFF00001.reason, 'I had lag', 'the dispute and the officer\'s text')
H.ok(byKind.batch and byKind.batch.batch == 'batch-1' and byKind.batch.actor == 'ADM00001', 'the batch, who ran it')
H.eq(select(2, CP.Review.history('no-such-run')), 'err.invalid_run', 'a run with no rows')
H.eq(select(2, CP.Review.history('bad uuid!')), 'err.invalid_run', 'a bad id')

return H
