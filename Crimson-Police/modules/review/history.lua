-- CP.Review (server): one history per run. Everything that happened to a run after it ended, in one timeline: the

-- CP.Review (server): one history per run. Everything that happened to a run after it ended, in one timeline: the
-- rows written (one per officer), the flags and staff notes, every decision (approve, void, a first Void waiting for
-- a second supervisor, restore, void kind, flag by hand), the disputes opened and answered, and the correction
-- batches that voided its rows.

-- Owns
--   * Review.history(runUuid) -> { runUuid, events } | nil, errKey. events = { { at, kind, action, actor?, role?,
--     citizenid?, rowId?, old?, new?, reason?, detail?, batch? } }, oldest first. kind:
--       row       a row of the run was written (action = its state)
--       flag      flagged by the anticheat or a rule (cp_audit runFlagged; new = the flag kind, detail = its text)
--       note      a staff note on the run (cp_audit runNoted)
--       decision  a staff decision on one row (the cp_audit 'flags' rows whose target is that row: approveFlagged,
--                 voidFlagged, voidPending, voidRun, restoreRun, voidKindSet, flagManual, and the dispute answers
--                 disputeApproved / disputeRejected)
--       dispute   a dispute opened (action 'opened', reason = the officer's text)
--       batch     a correction batch that voided one of its rows (cp_admin_jobs; batch = its id, action = its kind)
--     Rows of both run tables (live and archived) count. Reads only: four queries whatever the run's size.
--   * callback review:getRunHistory { runUuid } -> the history above. Admins (openAdmin) any run; a supervisor with
--     reviewFlagged or handleDisputes a run that involves his department. Never a run the viewer took part in
--     (err.own_run), as in the queue.
--   CP.Corrections.runDetail (Admin UI -> an officer's run) carries the same history as view.history.

CP.Review = CP.Review or {}
local Review = CP.Review
local TAG = 'review'

local Num = CP.Num
local Can = CP.can

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

local function Query(sql, params)
    CP.Db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function Marks(n)
    local m = {}
    for i = 1, n do m[i] = '?' end
    return table.concat(m, ', ')
end

local function ValidUuid(v)
    return type(v) == 'string' and #v > 0 and #v <= 36 and v:match('^[%w%-]+$') ~= nil
end

local function Whole(v) return math.floor(Num(v, 0)) end

-- The kind of a 'flags' audit row about a run or one of its rows.
local AUDIT_KIND = { runFlagged = 'flag', runNoted = 'note' }

local ROW_SQL = [[SELECT id, citizenid, state, void_batch, UNIX_TIMESTAMP(created_at) AS created_ts FROM %s
    WHERE run_uuid = ? ORDER BY id]]

function Review.history(runUuid)
    if not ValidUuid(runUuid) then return nil, 'err.invalid_run' end
    local events, targets, rowIds, batches, seenBatch = {}, { runUuid }, {}, {}, {}
    local function add(e)
        e.order = #events + 1
        events[#events + 1] = e
    end
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        for _, r in ipairs(Query(ROW_SQL:format(tbl), { runUuid }) or {}) do
            local id = Whole(r.id)
            rowIds[#rowIds + 1] = id
            targets[#targets + 1] = ('#%d %s'):format(id, tostring(r.citizenid))
            add({ at = Whole(r.created_ts), kind = 'row', action = r.state, citizenid = r.citizenid, rowId = id })
            local b = r.void_batch
            if type(b) == 'string' and b ~= '' and not seenBatch[b] then
                seenBatch[b] = true
                batches[#batches + 1] = b
            end
        end
    end
    if #rowIds == 0 then return nil, 'err.invalid_run' end
    -- target IN first: the saves folder engine looks rows up by the first indexed IN list (idx_audit_target)
    for _, a in
        ipairs(Query(
            ([[SELECT id, actor, role, action, target, old_value, new_value, reason,
            UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_audit WHERE target IN (%s) AND category = 'flags'
            ORDER BY id]]):format(Marks(#targets)),
            targets
        ) or {})
    do
        local kind = AUDIT_KIND[a.action]
        local e = { at = Whole(a.created_ts), kind = kind or 'decision', action = a.action }
        if kind then
            -- runFlagged / runNoted: old = the officer it is about (nil: the whole run), new = the kind, reason = text
            e.citizenid, e.new, e.detail = a.old_value, a.new_value, a.reason
        else
            e.actor, e.role, e.old, e.new, e.reason = a.actor, a.role, a.old_value, a.new_value, a.reason
            local id, cid = tostring(a.target or ''):match('^#(%d+) (.+)$')
            e.rowId, e.citizenid = tonumber(id), cid
        end
        add(e)
    end
    for _, d in
        ipairs(Query(
            ([[SELECT id, run_id, citizenid, reason, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_disputes
            WHERE run_id IN (%s) ORDER BY id]]):format(Marks(#rowIds)),
            rowIds
        ) or {})
    do
        local rowId = Whole(d.run_id)
        add({
            at = Whole(d.created_ts),
            kind = 'dispute',
            action = 'opened',
            citizenid = d.citizenid,
            rowId = rowId,
            reason = d.reason,
        })
    end
    if #batches > 0 then
        for _, j in
            ipairs(Query(
                ([[SELECT id, kind, actor, reason, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_admin_jobs
                WHERE id IN (%s)]]):format(Marks(#batches)),
                batches
            ) or {})
        do
            add({
                at = Whole(j.created_ts),
                kind = 'batch',
                action = j.kind,
                actor = j.actor,
                reason = j.reason,
                batch = j.id,
            })
        end
    end
    table.sort(events, function(a, b)
        if a.at ~= b.at then return a.at < b.at end
        return a.order < b.order
    end)
    for _, e in ipairs(events) do e.order = nil end
    return { runUuid = runUuid, events = events }
end

-- Who may read one run's history: admins any run, a supervisor a run of his department, never his own run.
local function MayRead(src, runUuid)
    local admin = CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
    if admin then
        local ok, e = Can(src, 'openAdmin')
        if not ok then return false, e end
    else
        local _, depts = Call('Admin', 'runDepartments', runUuid)
        local ctx = { departments = type(depts) == 'table' and depts or {} }
        if not Can(src, 'reviewFlagged', ctx) and not Can(src, 'handleDisputes', ctx) then
            return false, 'err.no_permission'
        end
    end
    local okC, okOwn, eOwn = Call('Admin', 'ownRunCheck', src, runUuid)
    if not okC then return false, 'err.internal' end
    if not okOwn then return false, eOwn end
    return true
end

CP.Net.callback('review:getRunHistory', function(src, payload)
    local runUuid = type(payload) == 'table' and payload.runUuid or nil
    if not ValidUuid(runUuid) then return nil, 'err.invalid_run' end
    local ok, e = MayRead(src, runUuid)
    if not ok then return nil, e end
    return Review.history(runUuid)
end, { rate = 3 })
