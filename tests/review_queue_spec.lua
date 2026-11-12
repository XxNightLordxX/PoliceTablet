-- The one Review queue (modules/review/queue.lua): flagged runs and disputes in one list with a type column,

-- The one Review queue (modules/review/queue.lua): flagged runs and disputes in one list with a type column,
-- one read (review:getQueue) and one decide action (server:review:decide) for supervisors and admins. One block per
-- old feature, driven through the new engine: the supervisor's flagged runs, his disputes, the Admin UI's flagged
-- runs and disputes, Approve / Void, the second Void, a dispute's answer (failed runs: admins only, with points),
-- Approve the whole run, the reply that carries the queue and the live push. Plain stubs, no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

-- players: 2 and 7 SAST supervisors, 4 an FIB supervisor, 1 an admin (no department), 6 an officer
local people = {
    [1] = { cid = 'ADM00001', admin = true },
    [2] = { cid = 'SUP00002', dept = 'sast', sup = true },
    [7] = { cid = 'SUP00007', dept = 'sast', sup = true },
    [4] = { cid = 'SUP00004', dept = 'fib', sup = true },
    [6] = { cid = 'OFF00006', dept = 'sast' },
}
CP.Access = CP.Access or {}
CP.Access.isAdmin = function(src) return people[tonumber(src)] ~= nil and people[tonumber(src)].admin == true end

local switches = { reviewFlagged = true, handleDisputes = true }
CP.Permissions = {
    can = function(src, action)
        local p = people[tonumber(src)]
        if not p then return false, 'err.no_permission' end
        if p.admin then return true end
        if action == 'openAdmin' or not p.sup or switches[action] ~= true then return false, 'err.no_permission' end
        return true
    end,
}

-- the rows: flagged rows by department, open disputes (goes_to, department)
local flags, disputes, calls = {}, {}, {}
local function Reset()
    flags = {
        { rowId = 11, runUuid = 'run-a', department = 'sast', createdAt = 100, flagReason = 'speed' },
        { rowId = 12, runUuid = 'run-a', department = 'sast', createdAt = 101, flagReason = 'speed' },
        { rowId = 13, runUuid = 'run-b', department = 'fib', createdAt = 300, flagReason = 'presence' },
        { rowId = 14, runUuid = 'run-c', department = 'sast', createdAt = 50, flagReason = 'manual', adminOnly = true },
    }
    disputes = {
        { id = 11, rowId = 20, department = 'sast', goesTo = 'supervisor', createdAt = 200, kind = 'voided' },
        { id = 21, rowId = 21, department = 'sast', goesTo = 'admin', createdAt = 400, kind = 'failed' },
    }
    calls = {}
end
Reset()

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = v end
    return out
end

CP.Admin = {
    viewerDepartment = function(src)
        local p = people[tonumber(src)]
        return p and p.dept, p and p.cid
    end,
    runDepartments = function(uuid)
        for _, f in ipairs(flags) do if f.runUuid == uuid then return { f.department } end end
        return {}
    end,
    ownRunCheck = function() return true end,
}

-- the flagged rows of the queue: modules/review/flagged.lua (stubbed: its rules have their own specs)
CP.Review = {
    -- dept nil = every department; admin = keep the kinds a department hands to admins
    flaggedRows = function(dept, cid, admin)
        calls[#calls + 1] = { 'flaggedRows', dept, cid, admin }
        local out = {}
        for _, f in ipairs(flags) do
            if (dept == nil or f.department == dept) and (not f.adminOnly or admin or dept == nil) then
                out[#out + 1] = Copy(f)
            end
        end
        return out
    end,
    approveFlagged = function(src, rowId, reason)
        calls[#calls + 1] = { 'approveFlagged', src, rowId, reason }
        if not reason or reason == '' then return false, 'err.reason_required' end
        for i, f in ipairs(flags) do
            if f.rowId == rowId then
                table.remove(flags, i)
                return true, { rowId = rowId }
            end
        end
        return false, 'err.not_flagged'
    end,
    voidFlagged = function(src, rowId, reason)
        calls[#calls + 1] = { 'voidFlagged', src, rowId, reason }
        -- the department's reviewRules.secondVoid: a supervisor's first Void only waits
        if not CP.Access.isAdmin(src) and rowId == 12 then return true, { rowId = rowId, pending = true } end
        for i, f in ipairs(flags) do
            if f.rowId == rowId then
                table.remove(flags, i)
                return true, { rowId = rowId }
            end
        end
        return false, 'err.not_flagged'
    end,
}

CP.Disputes = {
    forSupervisor = function(src)
        local p = people[tonumber(src)] or {}
        local out = {}
        for _, d in ipairs(disputes) do
            if d.goesTo == 'supervisor' and (p.dept == nil or d.department == p.dept) then out[#out + 1] = Copy(d) end
        end
        return out
    end,
    forAdmin = function()
        local out = {}
        for _, d in ipairs(disputes) do out[#out + 1] = Copy(d) end
        return out
    end,
    handle = function(src, id, decision, reason, points)
        calls[#calls + 1] = { 'handle', src, id, decision, reason, points }
        for i, d in ipairs(disputes) do
            if d.id == id then
                if d.kind == 'failed' and decision == 'approve' and not points then
                    return false, 'err.invalid_points'
                end
                table.remove(disputes, i)
                return true, { disputeId = id, status = decision == 'approve' and 'approved' or 'rejected' }
            end
        end
        return false, 'err.dispute_not_found'
    end,
}

-- the two reads queue.lua makes itself: a flagged row's run, a dispute's goes_to, a run's flagged rows
MySQL = MySQL or {}
MySQL.single = MySQL.single or {}
MySQL.query = MySQL.query or {}
MySQL.single.await = function(sql, params)
    if sql:find('cp_disputes', 1, true) then
        for _, d in ipairs(disputes) do
            if d.id == params[1] then return { goes_to = d.goesTo } end
        end
        return nil
    end
    for _, f in ipairs(flags) do if f.rowId == params[1] then return { run_uuid = f.runUuid } end end
    return nil
end
MySQL.query.await = function(_, params)
    local out = {}
    for _, f in ipairs(flags) do if f.runUuid == params[1] then out[#out + 1] = { id = f.rowId } end end
    return out
end

local pushes = {}
local navAsked = {}   -- src -> opts of the last CP.Tablet.navChanged (Z12)
CP.Tablet = {
    push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end,
    notify = function() end,
    navChanged = function(src, opts) navAsked[src] = opts or {} end,
}

H.load('modules/review/queue.lua')
local R = CP.Review

local seq = 0
local function Act(name, src, payload)
    H.clockMs = (H.clockMs or 0) + 1100
    seq = seq + 1
    local reqId = 'rq' .. seq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
end
local function Cb(src, args)
    H.clockMs = (H.clockMs or 0) + 1100
    return H.callback('crimson-police:review:getQueue', src, args)
end
local function Last(name)
    for i = #calls, 1, -1 do if calls[i][1] == name then return calls[i] end end
    return {}
end
local function Ids(queue, kind)
    local out = {}
    for _, i in ipairs(H.reviewItems(queue, kind)) do out[#out + 1] = tostring(i.id) end
    return table.concat(out, ',')
end

-- ============================================================================
--                     ONE READ, ONE ACTION (no old names)
-- ============================================================================

H.ok(H.callbacks['crimson-police:review:getQueue'] ~= nil, 'one read: review:getQueue')
H.ok(H.handlers['crimson-police:server:review:decide'] ~= nil, 'one action: server:review:decide')
for _, old in ipairs({ 'sup:getReviewQueue', 'admin:getFlagged', 'admin:getDisputes' }) do
    H.eq(H.callbacks['crimson-police:' .. old], nil, 'the old read ' .. old .. ' is gone')
end
for _, old in ipairs({
    'sup:reviewFlagged',
    'admin:reviewFlagged',
    'sup:handleDispute',
    'admin:handleDispute',
    'admin:approveRun',
}) do
    H.eq(H.handlers['crimson-police:server:' .. old], nil, 'the old action server:' .. old .. ' is gone')
end

-- ============================================================================
--                  THE SUPERVISOR'S FLAGGED RUNS AND DISPUTES
-- ============================================================================

local q = Cb(2)
H.eq(q.ok, true, 'a supervisor reads his queue')
H.eq(Ids(q.data, 'flag'), '12,11', 'flagged runs of his department, newest first')
H.eq(Ids(q.data, 'dispute'), '11', 'the disputes his department answers (a failed run is an admin\'s)')
H.eq(q.data.items[1].type, 'dispute', 'one list: the newer dispute sits above the older flags')
H.eq(q.data.items[1].id ~= nil and q.data.items[2].id ~= nil, true, 'every item has an id')
H.eq(calls[1][2], 'sast', 'flaggedRows of his department')
H.eq(calls[1][3], 'SUP00002', 'without his own runs')
H.eq(calls[1][4], false, 'the kinds his department hands to admins are left out')
H.eq(q.data.canReview and q.data.canHandle, true, 'canReview / canHandle as before')
H.eq(q.data.all, false, 'his department only')
H.eq(Cb(6).error, 'err.no_permission', 'an officer gets no queue')
H.eq(Cb(2, { all = true }).error, 'err.no_permission', 'a supervisor never reads every department')

switches.handleDisputes = false
local onlyFlags = Cb(2).data
H.eq(Ids(onlyFlags, 'dispute'), '', 'handleDisputes off: no disputes in his queue')
H.eq(onlyFlags.canHandle, false, 'and canHandle false')
switches.handleDisputes, switches.reviewFlagged = true, false
local onlyDisputes = Cb(2).data
H.eq(Ids(onlyDisputes, 'flag'), '', 'reviewFlagged off: no flagged runs')
H.eq(Ids(onlyDisputes, 'dispute'), '11', 'the disputes stay')
switches.reviewFlagged = true

-- ============================================================================
--                   THE ADMIN UI'S FLAGGED RUNS AND DISPUTES
-- ============================================================================

calls = {}
local a = Cb(1, { all = true })
H.eq(a.ok, true, 'an admin reads every department')
H.eq(Ids(a.data, 'flag'), '13,12,11,14', 'every flagged run, the admin-only kinds too (as on Review -> Flagged runs)')
H.eq(Ids(a.data, 'dispute'), '21,11', 'every open dispute, the failed runs too (as on Review -> Disputes)')
H.eq(calls[1][2], nil, 'no department filter')
H.eq(calls[1][3], 'ADM00001', 'the admin\'s own runs left out')
H.eq(a.data.all, true, 'all')

-- ============================================================================
--                                APPROVE / VOID
-- ============================================================================

local ok, res = Act('server:review:decide', 2, { type = 'flag', id = 11, decision = 'approve', reason = 'Checked' })
H.eq(ok, true, 'a supervisor approves a flagged run')
H.eq(Last('approveFlagged')[3], 11, 'through CP.Admin.approveFlagged')
H.eq(res.rowId, 11, 'the reply keeps its rowId')
H.eq(Ids(res.queue, 'flag'), '12', 'the reply carries his fresh queue, the row gone')
ok, res = Act('server:review:decide', 2, { type = 'flag', id = 12, decision = 'void', reason = 'Teleport' })
H.eq(ok and res.pending, true, 'the second Void rule: a first supervisor Void only waits (pending)')
ok, res = Act('server:review:decide', 2, { type = 'flag', id = 12, decision = 'maybe', reason = 'x' })
H.eq(res, 'err.invalid_decision', 'a flag is approved or voided')
ok, res = Act('server:review:decide', 2, { type = 'flag', id = 'x', decision = 'approve', reason = 'x' })
H.eq(res, 'err.invalid_row', 'the row id is checked')
ok, res = Act('server:review:decide', 2, { type = 'other', id = 1, decision = 'approve', reason = 'x' })
H.eq(res, 'err.invalid_payload', 'an unknown type is refused')
ok, res = Act('server:review:decide', 1, { type = 'flag', id = 13, decision = 'void', reason = 'Admin', all = true })
H.eq(ok, true, 'an admin voids any department\'s row')
H.eq(res.queue and res.queue.all, true, 'the Admin UI\'s decision answers with the Admin UI\'s queue')

-- ============================================================================
--                                   DISPUTES
-- ============================================================================

ok, res = Act('server:review:decide', 2,
    { type = 'dispute', id = 21, decision = 'approve', reason = 'x', awardPoints = 10 })
H.eq(res, 'err.no_permission', 'supervisors never answer a dispute about a failed run')
ok, res = Act('server:review:decide', 2, { type = 'dispute', id = 11, decision = 'reject', reason = 'Fine' })
H.eq(ok, true, 'a supervisor rejects a dispute')
H.eq(Last('handle')[4], 'reject', 'through CP.Disputes.handle')
H.eq(Ids(res.queue, 'dispute'), '', 'the reply carries his queue, the dispute gone')
ok, res = Act('server:review:decide', 1, { type = 'dispute', id = 21, decision = 'approve', reason = 'Lag' })
H.eq(res, 'err.invalid_points', 'a failed run\'s approval needs points')
ok, res = Act('server:review:decide', 1,
    { type = 'dispute', id = 21, decision = 'approve', reason = 'Lag', awardPoints = 40 })
H.eq(ok, true, 'an admin approves it with points')
H.eq(Last('handle')[6], 40, 'the points reach CP.Disputes.handle')

-- ============================================================================
--                            APPROVE THE WHOLE RUN
-- ============================================================================

Reset()
ok, res = Act('server:review:decide', 2, { type = 'flag', runUuid = 'run-a', decision = 'approve', reason = 'x' })
H.eq(res, 'err.no_permission', 'Approve the whole run is an admin\'s')
ok, res = Act('server:review:decide', 1, { type = 'flag', runUuid = 'run-a', decision = 'void', reason = 'x' })
H.eq(res, 'err.invalid_decision', 'a whole run is only approved')
ok, res = Act('server:review:decide', 1, { type = 'flag', runUuid = 'run-a', decision = 'approve', reason = '' })
H.eq(res, 'err.reason_required', 'with a reason')
ok, res = Act('server:review:decide', 1,
    { type = 'flag', runUuid = 'run-a', decision = 'approve', reason = 'Ok', all = true })
H.eq(ok and res.approved, 2, 'an admin approves both flagged rows of the run at once')
H.eq(Ids(res.queue, 'flag'), '13,14', 'and they leave his queue')
ok, res = Act('server:review:decide', 1, { type = 'flag', runUuid = 'run-a', decision = 'approve', reason = 'Ok' })
H.eq(res, 'err.not_flagged', 'a run with no flagged row left')

-- ============================================================================
--                                  LIVE PUSH
-- ============================================================================

Reset()
pushes = {}
for _, src in ipairs({ 2, 7, 4 }) do Cb(src) end
Cb(1, { all = true })
H.eq(R._watch()[1], nil, 'the Admin UI\'s queue polls (never in the push list)')
ok = Act('server:review:decide', 2, { type = 'flag', id = 11, decision = 'approve', reason = 'Checked' })
local got = {}
for _, p in ipairs(pushes) do if p.topic == 'reviewQueue' then got[p.src] = p.data end end
H.ok(got[7] ~= nil and type(got[7].items) == 'table', 'the other SAST supervisor gets his fresh queue')
H.eq(got[2], nil, 'not the decider himself')
H.eq(got[4], nil, 'nor a supervisor of another department')
H.ok(navAsked[2] and navAsked[2].review == true, '(Z12) the decider\'s review badge is counted again')
H.ok(navAsked[7] and navAsked[7].review == true, '(Z12) and the badge of the supervisor whose queue was refreshed')
H.eq(navAsked[4], nil, '(Z12) not another department\'s')
H.eq(R.share(1), 3, 'an admin\'s decision reaches every department\'s open queue')
H.eq(R.share(2, { 'sast', 'fib' }), 2, 'a cross-department run reaches both departments')
H.fire('playerDropped', 7, 'Exiting')
H.eq(R.share(2), 0, 'a supervisor who left is forgotten')
H.time = (H.time or os.time()) + 120
H.eq(R.share(1), 0, 'a queue not asked for in 75 s counts as closed')

-- ============================================================================
--            FIN4: CORRECTION BATCHES AND UNDO IN THE ADMIN'S QUEUE
-- ============================================================================

local undone, restored = {}, {}
local now = os.time()
CP.Corrections = {
    batches = function()
        return {
            {
                id = 'b-new',
                kind = 'bulkVoid',
                state = 'done',
                undo = 'restoreBatch',
                createdAt = now - 3600,
                total = 4,
            },
            { id = 'b-old', kind = 'bulkVoid', state = 'done', undo = 'restoreBatch', createdAt = now - 30 * 86400 },
            {
                id = 'b-gone',
                kind = 'retire',
                state = 'done',
                undo = 'unretire',
                createdAt = now - 60,
                restored = true,
            },
            { id = 'b-run', kind = 'bulkVoid', state = 'running', undo = 'restoreBatch', createdAt = now - 60 },
            { id = 'b-badge', kind = 'recheckBadges', state = 'done', createdAt = now - 60 },
        }
    end,
    undoBatch = function(src, id, reason)
        undone[#undone + 1] = { src, id, reason }
        return true, { jobId = 'job-1' }
    end,
}
local realKit = CP.AdminKit
CP.AdminKit = {
    -- the real Restore run is an admin's (AdminKit's guard); the stub keeps that rule
    run = function(name, src, p)
        if not CP.Access.isAdmin(src) then return false, 'err.no_permission' end
        restored[#restored + 1] = { name, src, p }
        return true, { rowId = p.rowId }
    end,
}
Config.AdminUi = Config.AdminUi or {}
Config.AdminUi.reviewBatchDays, Config.AdminUi.reviewUndo = 7, true
Reset()
local aq = Cb(1, { all = true }).data
H.eq(Ids(aq, 'batch'), 'b-new', 'the admin\'s queue lists the batches of the last 7 days that can still be undone')
H.ok(aq.canUndo == true and aq.canUndoBatch == true, 'and offers Undo')
local sq = Cb(2).data
H.ok(Ids(sq, 'batch') == '' and sq.canUndo ~= true, 'a supervisor\'s queue has no batches and no Undo')
Config.AdminUi.reviewBatchDays = 0
H.eq(Ids(Cb(1, { all = true }).data, 'batch'), '', 'reviewBatchDays = 0: batches stay on Corrections only')
Config.AdminUi.reviewBatchDays = 7
ok, res = Act('server:review:decide', 1,
    { type = 'batch', id = 'b-new', decision = 'undo', reason = 'Wrong filter', all = true })
H.ok(ok == true and undone[1][2] == 'b-new' and undone[1][3] == 'Wrong filter', 'a batch\'s Undo is its own Undo')
H.ok(res.queue and res.queue.all == true, 'and the reply carries the admin\'s queue')
ok, res = Act('server:review:decide', 1, { type = 'flag', id = 13, decision = 'undo', reason = 'Mistake', all = true })
H.ok(ok == true and restored[1][1] == 'server:admin:restoreRun' and restored[1][3].rowId == 13,
    'Undo of a void restores the run through Restore run')
ok, res = Act('server:review:decide', 2, { type = 'flag', id = 11, decision = 'undo', reason = 'x' })
H.eq(res, 'err.no_permission', 'a supervisor cannot undo (Restore run is an admin\'s)')
ok, res = Act('server:review:decide', 1, { type = 'flag', id = 'x', decision = 'undo', reason = 'x', all = true })
H.eq(res, 'err.invalid_row', 'the row id is checked')
Config.AdminUi.reviewUndo = false
ok, res = Act('server:review:decide', 1, { type = 'flag', id = 13, decision = 'undo', reason = 'x', all = true })
H.eq(res, 'err.review_undo_off', 'reviewUndo = false: no Undo in the queue')
H.eq(Cb(1, { all = true }).data.canUndo, false, 'and none offered')
Config.AdminUi.reviewUndo = true
local cfgFile = io.open('Crimson-Police/config/config.lua', 'r')
local cfgText = cfgFile and cfgFile:read('a') or ''
if cfgFile then cfgFile:close() end
H.ok(cfgText:find('reviewBatchDays = 7', 1, true) and cfgText:find('reviewUndo = true', 1, true),
    'shipped: batches of 7 days and Undo in the queue')
CP.Corrections, CP.AdminKit = nil, realKit

-- ============================================================================
--                  ONE MODULE: modules/review (its sub-files)
-- ============================================================================

local function Exists(rel)
    local f = io.open('Crimson-Police/' .. rel, 'r')
    if f then f:close() end
    return f ~= nil
end
for _, part in ipairs({ 'anticheat', 'reviewrules', 'disputes', 'corrections', 'queue' }) do -- FIN4: flagged, history below
    H.ok(Exists('modules/review/' .. part .. '.lua'), 'modules/review/' .. part .. '.lua')
    H.ok(not Exists('modules/' .. part .. '/server.lua'), 'no modules/' .. part .. '/server.lua any more')
end
local mf = io.open('Crimson-Police/fxmanifest.lua', 'r')
local manifest = mf and mf:read('a') or ''
if mf then mf:close() end
H.ok(manifest:find('\'modules/review/*.lua\'', 1, true) ~= nil, 'the manifest loads the review module\'s sub-files')
H.ok(Exists('modules/review/flagged.lua') and Exists('modules/review/history.lua'), 'FIN4: flagged rows and history')
local adminSrc = io.open('Crimson-Police/modules/admin/admin.lua', 'r')
local adminText = adminSrc and adminSrc:read('a') or ''
if adminSrc then adminSrc:close() end
for _, gone in ipairs({
    'function Admin.flaggedRows',
    'function Admin.approveFlagged',
    'function Admin.voidFlagged',
    'function Admin.flaggedCount',
}) do
    H.ok(not adminText:find(gone, 1, true), 'FIN4: ' .. gone .. ' moved to modules/review/flagged.lua')
end

return H
