-- CP.Review (server): the flagged rows of the Review queue. Which rows wait, and the two decisions on one row.

-- Owns
--   * Review.flaggedRows(dept, excludeCitizenid, admin) -> the flagged, not voided rows (at most FLAGGED_LIMIT, newest
--     first) of the runs that involve dept (nil: every department), the runs excludeCitizenid took part in (also one
--     he is still on) left out; a supervisor's list (dept given, admin false) leaves out the flag kinds the row's
--     department hands to admins (reviewRules). Each row carries its flag events and staff notes (cp_audit
--     'runFlagged' / 'runNoted').
--   * Review.flaggedCount(excludeCitizenid) -> how many runs wait in an admin's queue (Home), with no cap.
--   * Review.approveFlagged(src, rowId, reason, opts) -> ok, data|errKey: flagged = 0 (flag_reason kept), held cash
--     released, CP.Scoring.onRowApproved, the board invalidated. opts (CP.Disputes): { skipPermission, noAudit, quiet }.
--   * Review.voidFlagged(src, rowId, reason) -> ok, data|errKey: voided = 1 while still flagged (else err.conflict);
--     a supervisor's first Void under the department's reviewRules.secondVoid answers { pending = true }.
--   Both: a reason, the reviewFlagged switch for a run of the supervisor's department, never a manual award or goal row
--   (err.not_reviewable), never the reviewer's own run (CP.Admin.ownRunCheck). The row itself (CP.Admin.getRow), its
--   audit line and the shared void (CP.Admin.voidRow) stay in modules/admin.

CP.Review = CP.Review or {}
local Review = CP.Review
local TAG = 'review'

local FLAGGED_LIMIT = 200

local Has = CP.Has
local Num = CP.Num
local Can = CP.can

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

local function IsAdmin(src)
    return CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
end

local function Query(sql, params)
    CP.Db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function Update(sql, params)
    CP.Db()
    local ok, res = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(res))
        return nil
    end
    return tonumber(res) or 0
end

-- ============================================================================
--                                  DECISIONS
-- ============================================================================

-- Supervisor review of a row: the action switch, their department, never their own run.
local function ReviewAllowed(src, action, row)
    local ctx = nil
    if not IsAdmin(src) then ctx = { departments = CP.Admin.runDepartments(row.run_uuid) } end
    local ok, errKey = Can(src, action, ctx)
    if not ok then return false, errKey end
    return true
end

-- 'pending' too, as disputes do: a flagged row's pay can wait as pending (an approved row then pays at once)
local function ReleaseHeld(row)
    if row.cash_status == 'held' or row.cash_status == 'pending' then Call('Cash', 'release', row.id) end
end

-- A flag of a kind the row's department hands to admins (its reviewRules Mission control); admins and
-- the console are never bound by it.
local function AdminOnlyRow(src, row)
    if tonumber(src) == 0 or IsAdmin(src) then return false end
    local ok, only = Call('ReviewRules', 'adminOnly', row.department, row.flag_reason)
    return ok and only == true
end

local CLEAR_FLAG_SQL = [[UPDATE cp_mission_runs SET flagged = 0,
  breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.flagged', NULL), breakdown)
  WHERE id = ? AND flagged = 1 AND voided = 0]]

function Review.approveFlagged(src, rowId, reason, opts)
    opts = type(opts) == 'table' and opts or {}
    reason = CP.Admin.cleanText(reason)
    if not reason then return false, 'err.reason_required' end
    local row, errKey = CP.Admin.getRow(rowId)
    if not row then return false, errKey end
    if row.voided then return false, 'err.already_voided' end
    if not row.flagged then return false, 'err.not_flagged' end
    -- a manual award, an adjustment or a goal reward is never reviewed (a supervisor can't erase a deduction)
    if CP.Admin.NON_MISSION_TYPES[row.mission_type] then return false, 'err.not_reviewable' end
    if not opts.skipPermission then
        local ok, e = ReviewAllowed(src, 'reviewFlagged', row)
        if not ok then return false, e end
        if AdminOnlyRow(src, row) then return false, 'err.review_admin_only' end
    end
    local okOwn, eOwn = CP.Admin.ownRunCheck(src, row.run_uuid)
    if not okOwn then return false, eOwn end

    local n = Update(CLEAR_FLAG_SQL, { row.id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then return false, 'err.conflict' end
    Call('ReviewRules', 'clear', row.id)
    ReleaseHeld(row)
    Call('Scoring', 'onRowApproved', row.id)
    Call('Leaderboard', 'invalidate')
    if not opts.noAudit then
        CP.Admin.audit(src, CP.Admin.roleOf(src), 'flags', 'approveFlagged', CP.Admin.rowTarget(row), row.flag_reason,
            'approved', reason)
    end
    if not opts.quiet then
        CP.notify(CP.srcOf(row.citizenid), 'success', 'admin.notice.run_approved',
            { mission = CP.Admin.missionLabel(row.mission_id) })
    end
    CP.log(TAG, 'row %d approved by %s', row.id, tostring(src))
    return true, { rowId = row.id }
end

function Review.voidFlagged(src, rowId, reason)
    reason = CP.Admin.cleanText(reason)
    if not reason then return false, 'err.reason_required' end
    local row, errKey = CP.Admin.getRow(rowId)
    if not row then return false, errKey end
    if row.voided then return false, 'err.already_voided' end
    if not row.flagged then return false, 'err.not_flagged' end
    if CP.Admin.NON_MISSION_TYPES[row.mission_type] then return false, 'err.not_reviewable' end
    local ok, e = ReviewAllowed(src, 'reviewFlagged', row)
    if not ok then return false, e end
    if AdminOnlyRow(src, row) then return false, 'err.review_admin_only' end
    local okOwn, eOwn = CP.Admin.ownRunCheck(src, row.run_uuid)
    if not okOwn then return false, eOwn end
    -- the row's department wants two supervisors for a Void (admins void at once)
    if tonumber(src) ~= 0 and not IsAdmin(src) and Has('ReviewRules', 'voidStep') then
        local officer = CP.Access and CP.Access.getOfficer and CP.Access.getOfficer(src) or nil
        local okS, step, errS = Call('ReviewRules', 'voidStep', officer, row)
        if not okS then return false, 'err.internal' end
        if step == nil then return false, errS end
        if step == 'pending' then
            CP.Admin.audit(src, CP.Admin.roleOf(src), 'flags', 'voidPending', CP.Admin.rowTarget(row), 'flagged',
                'pending', reason)
            return true, { rowId = row.id, pending = true }
        end
    end
    local done, eVoid = CP.Admin.voidRow(src, row, reason, 'voidFlagged', true)
    if not done then return false, eVoid end
    Call('Leaderboard', 'invalidate')
    return true, { rowId = row.id, voided = 1 }
end

-- ============================================================================
--                                  WHAT WAITS
-- ============================================================================

-- Flag events recorded by CP.AntiCheat.flag (cp_audit 'runFlagged') and staff notes by CP.AntiCheat.note
-- ('runNoted', note = true): uuid -> { { citizenid|nil, reason, detail, note } }
local function FlagEvents(uuids)
    local out = {}
    if #uuids == 0 then return out end
    local i = 1
    while i <= #uuids do
        local chunk, marks = {}, {}
        for k = i, math.min(i + 99, #uuids) do
            chunk[#chunk + 1] = uuids[k]
            marks[#marks + 1] = '?'
        end
        i = i + 100
        -- target IN first: the saves folder engine looks rows up by the first indexed IN list it meets
        -- (idx_audit_target, migration 017), not every flag row of the log
        local rows = Query(
            ('SELECT action, target, old_value, new_value, reason FROM cp_audit WHERE target IN (%s) AND category = \'flags\' AND action IN (\'runFlagged\', \'runNoted\') ORDER BY id'):format(
                table.concat(marks, ', ')
            ), chunk) or {}
        for _, r in ipairs(rows) do
            local list = out[r.target] or {}
            out[r.target] = list
            list[#list + 1] = {
                citizenid = r.old_value,
                reason = r.new_value,
                detail = r.reason,
                note = r.action == 'runNoted' or nil,
            }
        end
    end
    return out
end

local FLAGGED_SQL = [[SELECT r.id, r.run_uuid, r.citizenid, r.department, r.mission_type, r.mission_id, r.location_label,
  r.state, r.end_reason, r.tier, r.participants, r.departments_n, r.final_points, r.cash_status, r.flag_reason,
  r.duration_s, JSON_VALUE(r.breakdown, '$.cash.amount') AS cash_amount,
  UNIX_TIMESTAMP(r.created_at) AS created_ts, o.display_name, o.callsign
  FROM cp_mission_runs r
  LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
  WHERE r.flagged = 1 AND r.voided = 0]]

-- How many runs wait in an admin's flagged queue (Home's Live now): every department, the viewer's own runs
-- (also the one he is still on) left out, as on Leaderboards -> Flagged runs. Only the run ids are read, with no
-- FLAGGED_LIMIT cap, so a count over 200 is the real one. The saves folder engine has no COUNT(DISTINCT ...), so the
-- distinct ids are counted here.
---@param excludeCitizenid string|nil
---@return integer
function Review.flaggedCount(excludeCitizenid)
    local sql = 'SELECT DISTINCT r.run_uuid FROM cp_mission_runs r WHERE r.flagged = 1 AND r.voided = 0'
    local params = {}
    if excludeCitizenid then
        sql = sql .. ' AND r.run_uuid NOT IN (SELECT m.run_uuid FROM cp_mission_runs m WHERE m.citizenid = ?)'
        params[1] = excludeCitizenid
    end
    local n = 0
    for _, r in ipairs(Query(sql, params) or {}) do
        if not CP.Admin.inLiveRun(excludeCitizenid, r.run_uuid) then n = n + 1 end
    end
    return n
end

-- admin: an admin's queue (rows his department hands to admins stay in it).
function Review.flaggedRows(dept, excludeCitizenid, admin)
    local sql, params = FLAGGED_SQL, {}
    if dept then
        sql = sql .. ' AND r.run_uuid IN (SELECT d.run_uuid FROM cp_mission_runs d WHERE d.department = ?)'
        params[#params + 1] = dept
    end
    if excludeCitizenid then
        sql = sql .. ' AND r.run_uuid NOT IN (SELECT m.run_uuid FROM cp_mission_runs m WHERE m.citizenid = ?)'
        params[#params + 1] = excludeCitizenid
    end
    sql = sql .. (' ORDER BY r.created_at DESC, r.id DESC LIMIT %d'):format(FLAGGED_LIMIT)
    local rows = {}
    for _, r in ipairs(Query(sql, params) or {}) do
        -- A run the viewer is still on (their own row is not written yet) is their own run too. A flag
        -- kind the row's department hands to admins is not in a supervisor's queue.
        local adminOnly = false
        if dept and not admin then
            local okA, only = Call('ReviewRules', 'adminOnly', r.department, r.flag_reason)
            adminOnly = okA and only == true
        end
        if not adminOnly and not CP.Admin.inLiveRun(excludeCitizenid, r.run_uuid) then rows[#rows + 1] = r end
    end
    local uuids, seen = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.run_uuid] then seen[r.run_uuid] = true; uuids[#uuids + 1] = r.run_uuid end
    end
    local events = FlagEvents(uuids)
    local out = {}
    for _, r in ipairs(rows) do
        local details, reasons, notes = {}, {}, {}
        for _, e in ipairs(events[r.run_uuid] or {}) do
            if e.citizenid == nil or e.citizenid == r.citizenid then
                if e.note then
                    -- a staff note is shown in the run detail; it never made the row held
                    notes[#notes + 1] = { reason = e.reason, detail = e.detail, note = true }
                else
                    if e.detail and e.detail ~= '' then details[#details + 1] = e.detail end
                    if e.reason and e.reason ~= r.flag_reason then reasons[#reasons + 1] = e.reason end
                end
            end
        end
        out[#out + 1] = {
            rowId = math.tointeger(tonumber(r.id)),
            runUuid = r.run_uuid,
            citizenid = r.citizenid,
            name = r.display_name or r.citizenid,
            callsign = r.callsign,
            department = r.department,
            departmentShort = CP.Admin.deptShort(r.department),
            missionId = r.mission_id,
            missionLabel = CP.Admin.missionLabel(r.mission_id),
            missionType = r.mission_type,
            missionTypeLabel = CP.Admin.typeLabel(r.mission_type),
            location = r.location_label,
            state = r.state,
            endReason = r.end_reason,
            tier = r.tier,
            participants = math.floor(Num(r.participants, 1)),
            departments = math.floor(Num(r.departments_n, 1)),
            points = math.floor(Num(r.final_points, 0)),
            cash = math.floor(Num(r.cash_amount, 0)),
            cashStatus = r.cash_status,
            flagReason = r.flag_reason or 'flagged',
            flagDetail = #details > 0 and table.concat(details, ' · ') or nil,
            otherReasons = reasons,
            notes = notes,
            durationS = math.floor(Num(r.duration_s, 0)),
            createdAt = math.floor(Num(r.created_ts, 0)),
            -- the first Void waiting for a second supervisor of the department ({ name, at })
            voidPending = select(2, Call('ReviewRules', 'pendingOf', math.tointeger(tonumber(r.id)))),
        }
    end
    return out
end
