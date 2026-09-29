--[[ modules/disputes/server.lua · CP.Disputes (server): officers' disputes about their flagged, voided or
  failed runs (cp_disputes) and how supervisors and admins answer them.

  Owns
    * filing: an officer may dispute one of their OWN rows that is flagged, voided or failed, within
      Config.Disputes.windowHours of the run (read at call time). One dispute per row, ever: an open one
      blocks a second (err.dispute_open) and a decided one is final (err.dispute_final). Manual awards and
      goal rows cannot be disputed. goes_to = 'supervisor' for flagged or voided rows (the department's
      supervisors), 'admin' for failed rows. The insert is atomic (INSERT ... SELECT ... WHERE NOT EXISTS).
      Filing toasts the online staff who can answer it (tellStaff, never participants of the run): admins
      for 'admin' disputes or while Config.Permissions.supervisor.handleDisputes is off, else the on-duty
      supervisors of the run's departments, or the admins when every online supervisor of those
      departments took part in the run.
    * answering (decision final, reason required, never by a participant of that run):
        approve  flagged row -> CP.Admin.approveFlagged (flag cleared, held cash released, XP)
                 voided row  -> voided = 0 (and flagged = 0), CP.Scoring.onRowApproved (XP back),
                                CP.Cash.release when its cash is still held, CP.Leaderboard.invalidate
                 failed row  -> CP.Scoring.manualAward(src, citizenid, awardPoints, reason)
        reject   keeps the row as it is; a voided row whose cash is still held (or pending) is forfeited (CP.Cash.forfeit)
      "Took part" also covers a participant still on the live run (no row of theirs yet): refused and
      left out of their lists.
      The dispute is claimed first (UPDATE ... WHERE status = 'open'), so two reviewers can never both
      answer it; a failed manual award re-opens it. Every answer is audited (category flags) and posted
      to the flags webhook; filing posts to the flags webhook. The officer gets a toast when online.

  Public API (docs/ARCHITECTURE.md §5.24)
    CP.Disputes.eligible(row, citizenid, nowTs) -> ok, errKey|nil, kind    pure; kind 'voided'|'flagged'|'failed'
        row = { citizenid, mission_type, state, flagged, voided, created_ts }
    CP.Disputes.kindOf(row) -> 'voided'|'flagged'|'failed'|nil      CP.Disputes.goesTo(kind) -> 'supervisor'|'admin'
    CP.Disputes.forSupervisor(src) -> { DisputeView }   open supervisor disputes about runs involving their
        department (every department for an admin without a department), never runs they took part in
    CP.Disputes.forAdmin(excludeCitizenid?) -> { DisputeView }   every open dispute (both kinds)
    CP.Disputes.forOfficer(citizenid, goesTo?, viewerSrc?) -> { DisputeView }   that officer's disputes (any status)
    CP.Disputes.handle(src, disputeId, decision, reason, awardPoints, opts) -> ok, data|errKey
        decision 'approve'|'reject'; awardPoints 1..10000 for an approved failed-run dispute;
        opts.adminOnly = true refuses non-admins (the admin endpoint)
    DisputeView = { id, rowId, runUuid, citizenid, name, callsign, department, departmentShort, missionId,
      missionLabel, missionType, missionTypeLabel, kind, state, endReason, tier, participants, points, cash,
      cashStatus, flagged, voided, flagReason, reason, goesTo, status, handledBy, createdAt, handledAt,
      runAt, canHandle }
  Net
    action   server:dispute               { rowId, reason }                 officer (CP.Access.getOfficer)
    action   server:sup:handleDispute     { disputeId, decision, reason }   handleDisputes (flagged/voided)
    action   server:admin:handleDispute   { disputeId, decision, reason, awardPoints }  admin (any kind)
    callback admin:getDisputes            -> { disputes = CP.Disputes.forAdmin(own citizenid) }
]]

CP.Disputes = CP.Disputes or {}
local D = CP.Disputes
local U = CP.U
local TAG = 'disputes'

local MAX_AWARD = 10000
local LIST_LIMIT = 200
local NON_MISSION_TYPES = { manual_award = true, goal = true }

-- ── helpers ─────────────────────────────────────────────────────────────────

-- Clip to at most n characters without cutting a UTF-8 sequence in half, dropping bytes that are not valid
-- UTF-8 first. The cp_* columns are utf8mb4 (VARCHAR(n) counts characters) and MariaDB's strict mode
-- refuses a broken sequence (error 1366), so a byte clip (CP.U.clip) of an accented reason could make
-- the whole insert fail.
local function clip(s, n)
    if s == nil then return nil end
    s = tostring(s)
    for _ = 1, 64 do
        local len, bad = utf8.len(s)
        if len then break end
        s = s:sub(1, bad - 1) .. s:sub(bad + 1)
    end
    if not utf8.len(s) then s = s:gsub('[\128-\255]', '?') end
    if utf8.len(s) <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1)
end
local function toSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function call(modName, fnName, ...)
    if not has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function int(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function cleanText(v, max)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v:gsub('[%c]', ' '))
    if s == '' then return nil end
    return clip(s, max or 255)
end

local function query(sql, params)
    db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function single(sql, params)
    db()
    local ok, res = pcall(MySQL.single.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil, false
    end
    return type(res) == 'table' and res or nil, true
end

local function update(sql, params)
    db()
    local ok, res = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(res))
        return nil
    end
    return tonumber(res) or 0
end

local function isAdmin(src)
    return CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
end

local function can(src, action, ctx)
    if not has('Permissions', 'can') then return false, 'err.no_permission' end
    local ok, allowed, errKey = call('Permissions', 'can', src, action, ctx)
    if not ok then return false, 'err.internal' end
    if not allowed then return false, errKey or 'err.no_permission' end
    return true
end

local function roleOf(src)
    if tonumber(src) == 0 then return 'console' end
    return isAdmin(src) and 'admin' or 'supervisor'
end

local function deptShort(key)
    if type(key) ~= 'string' then return '' end
    local d = CP.Access and CP.Access.department and CP.Access.department(key)
    return d and d.short or key:upper()
end

local function typeLabel(t)
    local mt = Config.MissionTypes and Config.MissionTypes[t]
    return mt and mt.label or tostring(t or '')
end

local function missionLabel(id)
    if has('Admin', 'missionLabel') then return CP.Admin.missionLabel(id) end
    local def = has('Missions', 'get') and CP.Missions.get(id) or nil
    return type(def) == 'table' and def.label or tostring(id or '')
end

local function audit(...)
    if has('Admin', 'audit') then call('Admin', 'audit', ...) end
end

local function webhook(...)
    if has('Admin', 'webhook') then call('Admin', 'webhook', ...) end
end

local function notify(src, kind, key, vars)
    if toSrc(src) and has('Tablet', 'notify') then call('Tablet', 'notify', src, kind, key, vars) end
end

local function onlineSrc(citizenid)
    if type(citizenid) ~= 'string' or not has('Qbx', 'getByCitizenId') then return nil end
    local ok, s = call('Qbx', 'getByCitizenId', citizenid)
    return ok and toSrc(s) or nil
end

local function citizenOf(src)
    if tonumber(src) == 0 then return nil end
    local ok, info = call('Qbx', 'getInfo', src)
    if ok and type(info) == 'table' then return info.citizenid end
    return nil
end

-- Whether citizenid is (or was) a participant of the still-running run runUuid: their own row is only
-- written when they leave, so the cp_mission_runs check alone misses a reviewer who is still on it.
local function inLiveRun(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' or type(runUuid) ~= 'string' or not has('Runs', 'get') then return false end
    local ok, run = call('Runs', 'get', runUuid)
    if not ok or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    for _, p in pairs(run.participants) do
        if type(p) == 'table' and p.citizenid == citizenid then return true end
    end
    return false
end

local function windowSeconds()
    local h = num(Config.Disputes and Config.Disputes.windowHours, 48)
    if h < 0 then h = 0 end
    return math.floor(h * 3600)
end

-- ── pure rules ──────────────────────────────────────────────────────────────
function D.kindOf(row)
    if type(row) ~= 'table' then return nil end
    if U.truthy(row.voided) then return 'voided' end
    if U.truthy(row.flagged) then return 'flagged' end
    if row.state == 'failed' then return 'failed' end
    return nil
end

function D.goesTo(kind)
    if kind == 'failed' then return 'admin' end
    if kind == 'voided' or kind == 'flagged' then return 'supervisor' end
    return nil
end

function D.eligible(row, citizenid, nowTs)
    if type(row) ~= 'table' then return false, 'err.row_not_found' end
    if type(citizenid) ~= 'string' or row.citizenid ~= citizenid then return false, 'err.not_your_run' end
    if NON_MISSION_TYPES[row.mission_type] then return false, 'err.not_disputable' end
    local kind = D.kindOf(row)
    if not kind then return false, 'err.not_disputable' end
    local created = num(row.created_ts, 0)
    if (nowTs or os.time()) - created > windowSeconds() then return false, 'err.dispute_window' end
    return true, nil, kind
end

-- ── views ───────────────────────────────────────────────────────────────────
local VIEW_SQL = [[SELECT d.id, d.run_id, d.citizenid, d.reason, d.goes_to, d.status, d.handled_by,
  UNIX_TIMESTAMP(d.created_at) AS created_ts, UNIX_TIMESTAMP(d.handled_at) AS handled_ts,
  r.run_uuid, r.department, r.mission_type, r.mission_id, r.state, r.end_reason, r.tier, r.participants,
  r.final_points, r.cash_status, r.flagged, r.voided, r.flag_reason,
  JSON_VALUE(r.breakdown, '$.cash.amount') AS cash_amount, UNIX_TIMESTAMP(r.created_at) AS run_ts,
  o.display_name, o.callsign
  FROM cp_disputes d
  JOIN cp_mission_runs r ON r.id = d.run_id
  LEFT JOIN cp_officers o ON o.citizenid = d.citizenid]]

local function viewOf(r, viewerCitizenid)
    local kind
    if r.goes_to == 'admin' then
        kind = 'failed'
    elseif U.truthy(r.voided) then
        kind = 'voided'
    else
        kind = 'flagged'
    end
    return {
        id = math.tointeger(tonumber(r.id)), rowId = math.tointeger(tonumber(r.run_id)), runUuid = r.run_uuid,
        citizenid = r.citizenid, name = r.display_name or r.citizenid, callsign = r.callsign,
        department = r.department, departmentShort = deptShort(r.department),
        missionId = r.mission_id, missionLabel = missionLabel(r.mission_id), missionType = r.mission_type,
        missionTypeLabel = typeLabel(r.mission_type), kind = kind, state = r.state, endReason = r.end_reason,
        tier = r.tier, participants = math.floor(num(r.participants, 1)), points = math.floor(num(r.final_points, 0)),
        cash = math.floor(num(r.cash_amount, 0)), cashStatus = r.cash_status,
        flagged = U.truthy(r.flagged), voided = U.truthy(r.voided), flagReason = r.flag_reason,
        reason = r.reason, goesTo = r.goes_to, status = r.status, handledBy = r.handled_by,
        createdAt = math.floor(num(r.created_ts, 0)), handledAt = tonumber(r.handled_ts) and math.floor(tonumber(r.handled_ts)) or nil,
        runAt = math.floor(num(r.run_ts, 0)),
        canHandle = r.status == 'open' and (viewerCitizenid == nil or viewerCitizenid ~= r.citizenid),
    }
end

-- Runs the viewer took part in (for canHandle when the list is not already filtered).
local function ownRuns(citizenid, uuids)
    local out = {}
    if not citizenid or #uuids == 0 then return out end
    local marks, params = {}, { citizenid }
    for i = 1, math.min(#uuids, 500) do
        marks[#marks + 1] = '?'
        params[#params + 1] = uuids[i]
    end
    for _, r in ipairs(query(('SELECT DISTINCT run_uuid FROM cp_mission_runs WHERE citizenid = ? AND run_uuid IN (%s)'):format(table.concat(marks, ', ')), params) or {}) do
        out[r.run_uuid] = true
    end
    return out
end

-- dropOwn: leave out disputes about runs the viewer took part in (the review lists never show them).
local function views(rows, viewerCitizenid, dropOwn)
    local uuids, seen = {}, {}
    for _, r in ipairs(rows) do
        if r.run_uuid and not seen[r.run_uuid] then seen[r.run_uuid] = true; uuids[#uuids + 1] = r.run_uuid end
    end
    local own = ownRuns(viewerCitizenid, uuids)
    local out = {}
    for _, r in ipairs(rows) do
        local mine = own[r.run_uuid] or inLiveRun(viewerCitizenid, r.run_uuid)
        if not (mine and dropOwn) then
            local v = viewOf(r, viewerCitizenid)
            if mine then v.canHandle = false end
            out[#out + 1] = v
        end
    end
    return out
end

function D.forSupervisor(src)
    local officer = CP.Access and CP.Access.getOfficer and CP.Access.getOfficer(src) or nil
    local dept = officer and officer.department or nil
    if not dept and not isAdmin(src) then return {} end
    local citizenid = officer and officer.citizenid or citizenOf(src) or ''
    local sql = VIEW_SQL .. " WHERE d.status = 'open' AND d.goes_to = 'supervisor'"
    local params = {}
    if dept then
        sql = sql .. ' AND r.run_uuid IN (SELECT x.run_uuid FROM cp_mission_runs x WHERE x.department = ?)'
        params[#params + 1] = dept
    end
    sql = sql .. ' AND r.run_uuid NOT IN (SELECT y.run_uuid FROM cp_mission_runs y WHERE y.citizenid = ?)'
    params[#params + 1] = citizenid
    sql = sql .. (' ORDER BY d.created_at, d.id LIMIT %d'):format(LIST_LIMIT)
    return views(query(sql, params) or {}, citizenid ~= '' and citizenid or nil, true)
end

function D.forAdmin(excludeCitizenid)
    local sql = VIEW_SQL .. " WHERE d.status = 'open'"
    local params = {}
    if type(excludeCitizenid) == 'string' and excludeCitizenid ~= '' then
        sql = sql .. ' AND r.run_uuid NOT IN (SELECT y.run_uuid FROM cp_mission_runs y WHERE y.citizenid = ?)'
        params[#params + 1] = excludeCitizenid
    end
    sql = sql .. (' ORDER BY d.created_at, d.id LIMIT %d'):format(LIST_LIMIT)
    local viewer = type(excludeCitizenid) == 'string' and excludeCitizenid ~= '' and excludeCitizenid or nil
    return views(query(sql, params) or {}, viewer, viewer ~= nil)
end

function D.forOfficer(citizenid, goesTo, viewerSrc)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end
    local sql = VIEW_SQL .. ' WHERE d.citizenid = ?'
    local params = { citizenid }
    if goesTo == 'admin' or goesTo == 'supervisor' then
        sql = sql .. ' AND d.goes_to = ?'
        params[#params + 1] = goesTo
    end
    sql = sql .. ' ORDER BY d.created_at DESC, d.id DESC LIMIT 50'
    local viewer = viewerSrc ~= nil and citizenOf(viewerSrc) or nil
    return views(query(sql, params) or {}, viewer)
end

-- ── filing ──────────────────────────────────────────────────────────────────
local ROW_SQL = [[SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, flagged, voided,
  cash_status, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_mission_runs WHERE id = ?]]

local function runDepartments(runUuid)
    if has('Admin', 'runDepartments') then
        local ok, list = call('Admin', 'runDepartments', runUuid)
        if ok and type(list) == 'table' then return list end
    end
    local out = {}
    for _, r in ipairs(query('SELECT DISTINCT department FROM cp_mission_runs WHERE run_uuid = ?', { runUuid }) or {}) do
        out[#out + 1] = r.department
    end
    return out
end

-- Supervisors answer disputes only while Config.Permissions.supervisor.handleDisputes is on.
local function supervisorsHandle()
    local sup = Config.Permissions and Config.Permissions.supervisor
    return type(sup) == 'table' and sup.handleDisputes == true
end

-- Toast the staff who can answer a new dispute (never participants of the run). Admins for failed-run
-- disputes, or for every dispute while the supervisors' switch is off. A flagged/voided-run dispute goes to
-- the on-duty supervisors of the run's departments; when every online supervisor of those departments
-- took part in the run (so none of them may answer it), the admins are told instead.
local function tellStaff(goesTo, runUuid, label)
    if not (has('Qbx', 'getOnlinePlayers') and has('Qbx', 'getInfo')) then return end
    local ok, list = call('Qbx', 'getOnlinePlayers')
    if not ok or type(list) ~= 'table' then return end
    local depts = {}
    for _, d in ipairs(runDepartments(runUuid)) do depts[d] = true end
    local participants = {}
    for _, r in ipairs(query('SELECT citizenid FROM cp_mission_runs WHERE run_uuid = ?', { runUuid }) or {}) do participants[r.citizenid] = true end
    local okR, run = call('Runs', 'get', runUuid)
    if okR and type(run) == 'table' and type(run.participants) == 'table' then
        for _, p in pairs(run.participants) do if type(p) == 'table' and p.citizenid then participants[p.citizenid] = true end end
    end
    local function supervisorOfRun(info)
        if type(info.job) ~= 'table' or not (CP.Access and CP.Access.departmentForJob) then return false end
        local dk = CP.Access.departmentForJob(info.job.name)
        local dept = dk and depts[dk] and CP.Access.department(dk)
        return dept ~= nil and dept ~= false and num(info.job.gradeLevel, -1) >= num(dept.supervisorGrade, math.huge)
    end
    local admins, supervisors = {}, {}
    local supTookPart, supOther = false, false
    for _, s in ipairs(list) do
        local okI, info = call('Qbx', 'getInfo', s)
        if okI and type(info) == 'table' then
            local sup = supervisorOfRun(info)
            if participants[info.citizenid] then
                if sup then supTookPart = true end
            else
                if isAdmin(s) then admins[#admins + 1] = s end
                if sup and info.job.onduty then
                    supervisors[#supervisors + 1] = s
                elseif sup then
                    supOther = true   -- off duty now, but may still answer it once back on duty
                end
            end
        end
    end
    local targets
    if goesTo == 'admin' or not supervisorsHandle() then
        -- With the supervisors' switch off, admins are the only ones who can answer it.
        targets = admins
    elseif #supervisors > 0 then
        targets = supervisors
    elseif supTookPart and not supOther then
        -- every supervisor of the department took part: nobody there may answer it, admins can
        targets = admins
    else
        targets = {}
    end
    if #targets > 0 and has('Tablet', 'notifyMany') then
        call('Tablet', 'notifyMany', targets, 'info', 'admin.notice.new_dispute', { mission = label })
    end
end

local INSERT_SQL = [[INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to)
  SELECT ?, ?, ?, ? FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM cp_disputes WHERE run_id = ?)]]

function D.file(src, payload)
    local officer, errKey = nil, 'err.not_police'
    if CP.Access and CP.Access.getOfficer then officer, errKey = CP.Access.getOfficer(src) end
    if not officer then return false, errKey or 'err.not_police' end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local rowId = int(payload.rowId, 1, 2147483647)
    if not rowId then return false, 'err.invalid_row' end
    local reason = cleanText(payload.reason, 255)
    if not reason then return false, 'err.reason_required' end
    if not CP.Net.rateOk(src, 'disputes:file', 3, 60000) then return false, 'err.rate_limited' end

    local row, okQ = single(ROW_SQL, { rowId })
    if not okQ then return false, 'err.internal' end
    if not row then return false, 'err.row_not_found' end
    local ok, e, kind = D.eligible(row, officer.citizenid, os.time())
    if not ok then return false, e end

    local prev = single('SELECT id, status FROM cp_disputes WHERE run_id = ? ORDER BY id DESC LIMIT 1', { rowId })
    if prev then return false, prev.status == 'open' and 'err.dispute_open' or 'err.dispute_final' end

    local goesTo = D.goesTo(kind)
    db()
    local okI, id = pcall(MySQL.insert.await, INSERT_SQL, { rowId, officer.citizenid, reason, goesTo, rowId })
    if not okI then
        CP.err(TAG, 'dispute insert failed: %s', tostring(id))
        return false, 'err.internal'
    end
    id = tonumber(id)
    if not id or id <= 0 then return false, 'err.dispute_open' end

    local label = missionLabel(row.mission_id)
    webhook('flags', CP.L('admin.webhook.dispute_filed', { mission = label }), CP.L('admin.webhook.dispute_filed_desc', { goes_to = CP.L('admin.dispute.goes_to.' .. goesTo) }), {
        { name = CP.L('admin.webhook.field.officer'), value = ('%s (%s)'):format(officer.name or officer.citizenid, officer.citizenid), inline = true },
        { name = CP.L('admin.webhook.field.run'), value = ('#%d · %s'):format(rowId, CP.L('admin.dispute.kind.' .. kind)), inline = true },
        { name = CP.L('admin.webhook.field.reason'), value = reason, inline = false },
    })
    CreateThread(function() tellStaff(goesTo, row.run_uuid, label) end)
    CP.log(TAG, 'dispute %d filed by %s about row %d (%s -> %s)', id, officer.citizenid, rowId, kind, goesTo)
    return true, { disputeId = id, goesTo = goesTo, kind = kind }
end

-- ── answering ───────────────────────────────────────────────────────────────
local LOAD_SQL = [[SELECT d.id, d.run_id, d.citizenid, d.goes_to, d.status,
  r.run_uuid, r.mission_id, r.mission_type, r.state, r.flagged, r.voided, r.cash_status
  FROM cp_disputes d JOIN cp_mission_runs r ON r.id = d.run_id WHERE d.id = ?]]

local RESTORE_SQL = [[UPDATE cp_mission_runs SET voided = 0, flagged = 0,
  breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.flagged', NULL), breakdown)
  WHERE id = ? AND voided = 1]]

local function restoreVoided(d)
    local n = update(RESTORE_SQL, { d.run_id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then return true end     -- already restored
    call('Scoring', 'onRowApproved', d.run_id)
    if d.cash_status == 'held' or d.cash_status == 'pending' then call('Cash', 'release', d.run_id) end
    call('Leaderboard', 'invalidate')
    return true
end

local function reopen(id)
    update("UPDATE cp_disputes SET status = 'open', handled_by = NULL, handled_at = NULL WHERE id = ?", { id })
end

function D.handle(src, disputeId, decision, reason, awardPoints, opts)
    opts = type(opts) == 'table' and opts or {}
    local id = int(disputeId, 1, 2147483647)
    if not id then return false, 'err.invalid_dispute' end
    if decision ~= 'approve' and decision ~= 'reject' then return false, 'err.invalid_decision' end
    reason = cleanText(reason, 255)
    if not reason then return false, 'err.reason_required' end
    if opts.adminOnly and not isAdmin(src) then return false, 'err.no_permission' end

    local d, okQ = single(LOAD_SQL, { id })
    if not okQ then return false, 'err.internal' end
    if not d then return false, 'err.dispute_not_found' end
    d.run_id = math.tointeger(tonumber(d.run_id)) or d.run_id
    if d.status ~= 'open' then return false, 'err.dispute_closed' end

    local kind = d.goes_to == 'admin' and 'failed' or (U.truthy(d.voided) and 'voided' or 'flagged')
    if d.goes_to == 'admin' then
        local ok, e = can(src, 'handleFailedDispute')
        if not ok then return false, e end
    else
        local ctx = nil
        if not isAdmin(src) then ctx = { departments = runDepartments(d.run_uuid) } end
        local ok, e = can(src, 'handleDisputes', ctx)
        if not ok then return false, e end
    end
    if not has('Permissions', 'canReviewRun') then return false, 'err.no_permission' end
    local okR, allowed, eR = call('Permissions', 'canReviewRun', src, d.run_uuid)
    if not okR then return false, 'err.internal' end
    if not allowed then return false, eR or 'err.own_run' end
    if inLiveRun(citizenOf(src), d.run_uuid) then return false, 'err.own_run' end

    local points
    if decision == 'approve' and kind == 'failed' then
        points = int(awardPoints, 1, MAX_AWARD)
        if not points then return false, 'err.invalid_points' end
        if not has('Scoring', 'manualAward') then return false, 'err.module_unavailable' end
    end

    local handler = tonumber(src) == 0 and 'console' or (citizenOf(src) or ('player:' .. tostring(src)))
    local status = decision == 'approve' and 'approved' or 'rejected'
    local claimed = update("UPDATE cp_disputes SET status = ?, handled_by = ?, handled_at = NOW() WHERE id = ? AND status = 'open'",
        { status, clip(handler, 50), id })
    if claimed == nil then return false, 'err.internal' end
    if claimed == 0 then return false, 'err.dispute_closed' end

    if decision == 'approve' then
        if kind == 'failed' then
            local ok, res, e = call('Scoring', 'manualAward', src, d.citizenid, points, reason)
            if not ok or res == false or (res == nil and type(e) == 'string') then
                reopen(id)
                return false, (ok and e) or 'err.internal'
            end
        elseif kind == 'flagged' then
            local ok, res, e = call('Admin', 'approveFlagged', src, d.run_id, reason, { skipPermission = true, noAudit = true, quiet = true })
            if not ok or (res == false and e ~= 'err.not_flagged') then
                if ok and e == 'err.already_voided' then
                    local done = restoreVoided(d)
                    if not done then reopen(id); return false, 'err.internal' end
                else
                    reopen(id)
                    return false, (ok and e) or 'err.internal'
                end
            end
        else
            local done, e = restoreVoided(d)
            if not done then
                reopen(id)
                return false, e
            end
        end
    elseif kind == 'voided' and (d.cash_status == 'held' or d.cash_status == 'pending') then
        call('Cash', 'forfeit', d.run_id)
    end

    local label = missionLabel(d.mission_id)
    local newValue = status
    if points then newValue = ('+%d'):format(points) end
    audit(src, roleOf(src), 'flags', decision == 'approve' and 'disputeApproved' or 'disputeRejected',
        ('#%s %s'):format(tostring(d.run_id), tostring(d.citizenid)), kind, newValue, reason)
    notify(onlineSrc(d.citizenid), decision == 'approve' and 'success' or 'warning',
        decision == 'approve' and 'admin.notice.dispute_approved' or 'admin.notice.dispute_rejected', { mission = label })
    CP.log(TAG, 'dispute %d %s by %s', id, status, tostring(handler))
    return true, { disputeId = id, status = status, kind = kind, points = points }
end

-- ── net ─────────────────────────────────────────────────────────────────────
CP.Net.action('server:dispute', function(src, payload)
    return D.file(src, payload)
end, { rate = 2 })

CP.Net.action('server:sup:handleDispute', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local id = int(payload.disputeId, 1, 2147483647)
    if not id then return false, 'err.invalid_dispute' end
    -- The supervisor endpoint answers flagged/voided disputes only (failed runs go to admins).
    if not isAdmin(src) then
        local row = single('SELECT goes_to FROM cp_disputes WHERE id = ?', { id })
        if row and row.goes_to == 'admin' then return false, 'err.no_permission' end
    end
    return D.handle(src, id, payload.decision, payload.reason, payload.awardPoints)
end, { rate = 3 })

CP.Net.action('server:admin:handleDispute', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return D.handle(src, payload.disputeId, payload.decision, payload.reason, payload.awardPoints, { adminOnly = true })
end, { rate = 3 })

CP.Net.callback('admin:getDisputes', function(src)
    local ok, e = can(src, 'openAdmin')
    if not ok then return nil, e end
    return { disputes = D.forAdmin(citizenOf(src)) }
end, { rate = 3 })
