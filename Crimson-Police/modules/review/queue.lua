-- CP.Review (server): the one Review queue. Flagged runs and disputes sit in one list with a type column
-- ('flag' | 'dispute'), read with one callback and decided with one action, for supervisors (their department) and
-- admins (every department).

-- Owns
--   * the queue: Review.queueFor(src, all) -> { items, canReview, canHandle, all } | nil, errKey. items = every
--     flagged row (CP.Admin.flaggedRows) and every open dispute (CP.Disputes.forSupervisor / forAdmin), each with
--     type = 'flag' | 'dispute' and id (the row id of a flag, the dispute id of a dispute), newest first.
--     A supervisor (all = false) needs reviewFlagged or handleDisputes and sees his department only (the flag kinds
--     the department's reviewRules hands to admins left out); all = true is the Admin UI's queue (openAdmin): every
--     department. Runs the viewer took part in are never listed.
--   * deciding: Review.decide(src, payload) -> ok, data. payload = { type, id, decision, reason, awardPoints?, all? }.
--       flag     'approve' | 'void' -> CP.Admin.approveFlagged / voidFlagged (a supervisor's first Void under the
--                department's reviewRules.secondVoid answers { pending = true }); with runUuid and no id (admins):
--                'approve' every flagged row of that run
--       dispute  'approve' | 'reject' -> CP.Disputes.handle; a dispute about a failed run is an admin's
--                (supervisors get err.no_permission), awardPoints 1..10000 when it is approved
--     The reply carries the viewer's fresh queue (data.queue), so the screen needs no second request.
--   * live push: after a decision every other supervisor with the queue open (asked in the last 75 s) gets his own
--     fresh queue (push 'reviewQueue'), of the row's departments only (an admin's decision: every department).
--
-- Net
--   callback review:getQueue   { all? } -> ReviewQueueData (web/src/types/oversight.ts)
--   action   server:review:decide   payload above

CP.Review = CP.Review or {}
local Review = CP.Review
local TAG = 'review'

local WATCH_S = 75

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function Int(v)
    local n = math.tointeger(tonumber(v))
    if not n or n < 1 or n > 2147483647 then return nil end
    return n
end

local function IsAdmin(src)
    return CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
end

local function Can(src, action, ctx)
    local ok, allowed, errKey = Call('Permissions', 'can', src, action, ctx)
    if not ok then return false, 'err.no_permission' end
    if not allowed then return false, errKey or 'err.no_permission' end
    return true
end

local function Viewer(src)
    if tonumber(src) == 0 then return nil, nil end
    local _, dept, citizenid = Call('Admin', 'viewerDepartment', src)
    return dept, citizenid
end

local function Single(sql, params)
    CP.Db()
    local ok, res = pcall(MySQL.single.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or nil
end

-- ============================================================================
--                                  THE QUEUE
-- ============================================================================

local function Typed(list, kind, idKey, out)
    for _, v in ipairs(type(list) == 'table' and list or {}) do
        v.type = kind
        v.id = v[idKey]
        out[#out + 1] = v
    end
end

function Review.queueFor(src, all)
    local admin = IsAdmin(src)
    local dept, citizenid = Viewer(src)
    local canReview, canHandle
    if all then
        local ok, e = Can(src, 'openAdmin')
        if not ok then return nil, e end
        canReview, canHandle = true, true
    else
        canReview = Can(src, 'reviewFlagged')
        canHandle = Can(src, 'handleDisputes')
        if not canReview and not canHandle then return nil, 'err.no_permission' end
        if not dept and not admin then return nil, 'err.no_permission' end
    end
    local items = {}
    if canReview then
        local _, flagged = Call('Admin', 'flaggedRows', (not all) and dept or nil, citizenid or '', admin)
        Typed(flagged, 'flag', 'rowId', items)
    end
    if canHandle then
        local _, disputes
        if all then
            _, disputes = Call('Disputes', 'forAdmin', citizenid)
        else
            _, disputes = Call('Disputes', 'forSupervisor', src)
        end
        Typed(disputes, 'dispute', 'id', items)
    end
    table.sort(items, function(a, b)
        local ta, tb = tonumber(a.createdAt) or 0, tonumber(b.createdAt) or 0
        if ta ~= tb then return ta > tb end
        if a.type ~= b.type then return a.type < b.type end
        return (tonumber(a.id) or 0) > (tonumber(b.id) or 0)
    end)
    return { items = items, canReview = canReview, canHandle = canHandle, all = all == true }
end

-- Who has the supervisors' queue open: src -> os.time() of his last review:getQueue (the screen asks every 30 s).
-- Closing the tablet or leaving forgets him.
local watch = {}

-- After src decided: every other supervisor with the queue open gets his own fresh queue (push 'reviewQueue'), of
-- dept only: the row's department (or the list of a cross-department run's departments) when given, else a
-- supervisor's own; an admin or the console: every department. Returns how many got it.
function Review.share(src, dept)
    if next(watch) == nil then return 0 end
    if dept == nil and tonumber(src) ~= 0 and not IsAdmin(src) then dept = Viewer(src) end
    local depts = nil
    if type(dept) == 'table' then
        depts = {}
        for _, d in ipairs(dept) do depts[d] = true end
    end
    local now, n = os.time(), 0
    for viewer, at in pairs(watch) do
        if now - at > WATCH_S then
            watch[viewer] = nil
        elseif viewer ~= tonumber(src) then
            local vd = Viewer(viewer)
            if dept == nil or (depts and depts[vd or ''] == true) or (not depts and vd == dept) then
                local okQ, queue = pcall(Review.queueFor, viewer, false)
                if okQ and type(queue) == 'table' and CP.push(viewer, 'reviewQueue', queue) ~= false then
                    n = n + 1
                    Call('Tablet', 'navChanged', viewer, { review = true })   -- his badge and tile too
                end
            end
        end
    end
    return n
end
Review._watch = function() return watch end

-- ============================================================================
--                                   DECIDING
-- ============================================================================

-- The departments of a flagged row's run (a cross-department run's row sits in each of their queues), or nil.
local function RowRunDepartments(rowId)
    local row = Single('SELECT run_uuid FROM cp_mission_runs WHERE id = ?', { rowId })
    if not row or not row.run_uuid then return nil end
    local _, list = Call('Admin', 'runDepartments', row.run_uuid)
    return type(list) == 'table' and #list > 0 and list or nil
end

-- Admins: approve every flagged row of one run (the held cash of all of them is released).
local function ApproveRun(src, runUuid, reason)
    if not IsAdmin(src) then return false, 'err.no_permission' end
    local okP, eP = Can(src, 'reviewFlagged')
    if not okP then return false, eP end
    if type(runUuid) ~= 'string' or #runUuid == 0 or #runUuid > 36 or not runUuid:match('^[%w%-]+$') then
        return false, 'err.invalid_run'
    end
    reason = type(reason) == 'string' and CP.U.trim(reason:gsub('%c', ' ')) or ''
    if reason == '' then return false, 'err.reason_required' end
    local okC, okOwn, eOwn = Call('Admin', 'ownRunCheck', src, runUuid)
    if not okC then return false, 'err.internal' end
    if not okOwn then return false, eOwn end
    CP.Db()
    local okQ, rows = pcall(MySQL.query.await,
        'SELECT id FROM cp_mission_runs WHERE run_uuid = ? AND flagged = 1 AND voided = 0 ORDER BY id', { runUuid })
    rows = okQ and type(rows) == 'table' and rows or {}
    if #rows == 0 then return false, 'err.not_flagged' end
    local n = 0
    for _, r in ipairs(rows) do
        if CP.Admin.approveFlagged(src, r.id, reason) then n = n + 1 end
    end
    if n == 0 then return false, 'err.conflict' end
    return true, { approved = n, runUuid = runUuid }
end

local function DecideFlag(src, p)
    if p.id == nil and p.runUuid ~= nil then
        if p.decision ~= 'approve' then return false, 'err.invalid_decision' end
        return ApproveRun(src, p.runUuid, p.reason)
    end
    local id = Int(p.id)
    if not id then return false, 'err.invalid_row' end
    local depts = not IsAdmin(src) and RowRunDepartments(id) or nil
    local ok, data
    if p.decision == 'approve' then
        ok, data = CP.Admin.approveFlagged(src, id, p.reason)
    elseif p.decision == 'void' then
        ok, data = CP.Admin.voidFlagged(src, id, p.reason)
    else
        return false, 'err.invalid_decision'
    end
    return ok, data, depts
end

local function DecideDispute(src, p)
    local id = Int(p.id)
    if not id then return false, 'err.invalid_dispute' end
    -- a dispute about a failed run is an admin's to answer
    if not IsAdmin(src) then
        local row = Single('SELECT goes_to FROM cp_disputes WHERE id = ?', { id })
        if row and row.goes_to == 'admin' then return false, 'err.no_permission' end
    end
    if not Has('Disputes', 'handle') then return false, 'err.module_unavailable' end
    return CP.Disputes.handle(src, id, p.decision, p.reason, p.awardPoints)
end

-- A decision's reply: data with the viewer's fresh queue (data.queue; a queue that cannot be built is left out), and
-- the other open queues of depts get theirs. A refused decision is answered as it is.
function Review.reply(src, ok, data, depts, all)
    if not ok then return ok, data end
    local out = {}
    if type(data) == 'table' then
        for k, v in pairs(data) do out[k] = v end
    end
    local okQ, queue = pcall(Review.queueFor, src, all)
    if okQ and type(queue) == 'table' then out.queue = queue end
    -- the decider's sidebar badge and Waiting for review tile count again
    Call('Tablet', 'navChanged', src, { review = true })
    pcall(Review.share, src, depts)
    return true, out
end

function Review.decide(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local ok, data, depts
    if payload.type == 'flag' then
        if not CP.Admin or not CP.Admin.approveFlagged then return false, 'err.module_unavailable' end
        ok, data, depts = DecideFlag(src, payload)
    elseif payload.type == 'dispute' then
        ok, data = DecideDispute(src, payload)
    else
        return false, 'err.invalid_payload'
    end
    return Review.reply(src, ok, data, depts, payload.all == true)
end

-- ============================================================================
--                                     NET
-- ============================================================================

CP.Net.callback('review:getQueue', function(src, payload)
    local all = type(payload) == 'table' and payload.all == true
    local queue, err = Review.queueFor(src, all)
    if queue and not all and tonumber(src) and tonumber(src) > 0 then watch[tonumber(src)] = os.time() end
    return queue, err
end, { rate = 3 })

CP.Net.action('server:review:decide', function(src, payload)
    return Review.decide(src, payload)
end, { rate = 3 })

AddEventHandler('playerDropped', function() watch[tonumber(source)] = nil end)
if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('tablet:closed', function(src) watch[tonumber(src)] = nil end)
end
