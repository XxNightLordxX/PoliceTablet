-- CP.Disputes (server): officers' disputes about their flagged, voided or failed runs (cp_disputes) and how
-- supervisors and admins answer them.

CP.Disputes = CP.Disputes or {}
local D = CP.Disputes
local U = CP.U
local TAG = 'disputes'

local MAX_AWARD = 10000
local LIST_LIMIT = 200
local NON_MISSION_TYPES = { manual_award = true, goal = true }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

-- Clip to at most n characters without cutting a UTF-8 sequence in half, dropping bytes that are not valid
-- UTF-8 first. The cp_* columns are utf8mb4 (VARCHAR(n) counts characters) and MariaDB's strict mode
-- refuses a broken sequence (error 1366), so a byte clip (CP.U.clip) of an accented reason could make
-- the whole insert fail.
local function Clip(s, n)
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
local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

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

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function Int(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function CleanText(v, max)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v:gsub('[%c]', ' '))
    if s == '' then return nil end
    return Clip(s, max or 255)
end

local function Query(sql, params)
    Db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function Single(sql, params)
    Db()
    local ok, res = pcall(MySQL.single.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil, false
    end
    return type(res) == 'table' and res or nil, true
end

local function Update(sql, params)
    Db()
    local ok, res = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(res))
        return nil
    end
    return tonumber(res) or 0
end

local function IsAdmin(src)
    return CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
end

local function Can(src, action, ctx)
    if not Has('Permissions', 'can') then return false, 'err.no_permission' end
    local ok, allowed, errKey = Call('Permissions', 'can', src, action, ctx)
    if not ok then return false, 'err.internal' end
    if not allowed then return false, errKey or 'err.no_permission' end
    return true
end

local function RoleOf(src)
    if tonumber(src) == 0 then return 'console' end
    return IsAdmin(src) and 'admin' or 'supervisor'
end

local function DeptShort(key)
    if type(key) ~= 'string' then return '' end
    local d = CP.Access and CP.Access.department and CP.Access.department(key)
    return d and d.short or key:upper()
end

local function TypeLabel(t)
    local mt = Config.MissionTypes and Config.MissionTypes[t]
    return mt and mt.label or tostring(t or '')
end

local function MissionLabel(id)
    if Has('Admin', 'missionLabel') then return CP.Admin.missionLabel(id) end
    local def = Has('Missions', 'get') and CP.Missions.get(id) or nil
    return type(def) == 'table' and def.label or tostring(id or '')
end

local function Audit(...)
    if Has('Admin', 'audit') then Call('Admin', 'audit', ...) end
end

local function Webhook(...)
    if Has('Admin', 'webhook') then Call('Admin', 'webhook', ...) end
end

local function Notify(src, kind, key, vars)
    if ToSrc(src) and Has('Tablet', 'notify') then Call('Tablet', 'notify', src, kind, key, vars) end
end

local function OnlineSrc(citizenid)
    if type(citizenid) ~= 'string' or not Has('Qbx', 'getByCitizenId') then return nil end
    local ok, s = Call('Qbx', 'getByCitizenId', citizenid)
    return ok and ToSrc(s) or nil
end

local function CitizenOf(src)
    if tonumber(src) == 0 then return nil end
    local ok, info = Call('Qbx', 'getInfo', src)
    if ok and type(info) == 'table' then return info.citizenid end
    return nil
end

-- Whether citizenid is (or was) a participant of the still-running run runUuid: their own row is only
-- written when they leave, so the cp_mission_runs check alone misses a reviewer who is still on it.
local function InLiveRun(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' or type(runUuid) ~= 'string' or not Has('Runs', 'get') then
        return false
    end
    local ok, run = Call('Runs', 'get', runUuid)
    if not ok or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    for _, p in pairs(run.participants) do
        if type(p) == 'table' and p.citizenid == citizenid then return true end
    end
    return false
end

local function WindowSeconds()
    local h = Num(Config.Disputes and Config.Disputes.windowHours, 48)
    if h < 0 then h = 0 end
    return math.floor(h * 3600)
end

-- ============================================================================
--                                  PURE RULES
-- ============================================================================

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
    local created = Num(row.created_ts, 0)
    if (nowTs or os.time()) - created > WindowSeconds() then return false, 'err.dispute_window' end
    return true, nil, kind
end

-- ============================================================================
--                                    VIEWS
-- ============================================================================

local VIEW_SQL = [[SELECT d.id, d.run_id, d.citizenid, d.reason, d.goes_to, d.status, d.handled_by,
  UNIX_TIMESTAMP(d.created_at) AS created_ts, UNIX_TIMESTAMP(d.handled_at) AS handled_ts,
  r.run_uuid, r.department, r.mission_type, r.mission_id, r.state, r.end_reason, r.tier, r.participants,
  r.final_points, r.cash_status, r.flagged, r.voided, r.flag_reason,
  JSON_VALUE(r.breakdown, '$.cash.amount') AS cash_amount, UNIX_TIMESTAMP(r.created_at) AS run_ts,
  r.breakdown, o.display_name, o.callsign
  FROM cp_disputes d
  JOIN cp_mission_runs r ON r.id = d.run_id
  LEFT JOIN cp_officers o ON o.citizenid = d.citizenid]]

-- The debrief of the disputed row (the decision ledger with each fact's time, and the people), when it has one.
local function DebriefOf(r)
    local bd = U.jsonField(r.breakdown)
    if type(bd) ~= 'table' then return nil, nil end
    local decisions = type(bd.decisions) == 'table' and #bd.decisions > 0 and bd.decisions or nil
    local people = type(bd.people) == 'table' and #bd.people > 0 and bd.people or nil
    return decisions, people
end

local function ViewOf(r, viewerCitizenid)
    local decisions, people = DebriefOf(r)
    local kind
    if r.goes_to == 'admin' then
        kind = 'failed'
    elseif U.truthy(r.voided) then
        kind = 'voided'
    else
        kind = 'flagged'
    end
    return {
        id = math.tointeger(tonumber(r.id)),
        rowId = math.tointeger(tonumber(r.run_id)),
        runUuid = r.run_uuid,
        citizenid = r.citizenid,
        name = r.display_name or r.citizenid,
        callsign = r.callsign,
        department = r.department,
        departmentShort = DeptShort(r.department),
        missionId = r.mission_id,
        missionLabel = MissionLabel(r.mission_id),
        missionType = r.mission_type,
        missionTypeLabel = TypeLabel(r.mission_type),
        kind = kind,
        state = r.state,
        endReason = r.end_reason,
        tier = r.tier,
        participants = math.floor(Num(r.participants, 1)),
        points = math.floor(Num(r.final_points, 0)),
        cash = math.floor(Num(r.cash_amount, 0)),
        cashStatus = r.cash_status,
        flagged = U.truthy(r.flagged),
        voided = U.truthy(r.voided),
        flagReason = r.flag_reason,
        reason = r.reason,
        goesTo = r.goes_to,
        status = r.status,
        handledBy = r.handled_by,
        createdAt = math.floor(Num(r.created_ts, 0)),
        handledAt = tonumber(r.handled_ts) and math.floor(tonumber(r.handled_ts)) or nil,
        runAt = math.floor(Num(r.run_ts, 0)),
        canHandle = r.status == 'open' and (viewerCitizenid == nil or viewerCitizenid ~= r.citizenid),
        decisions = decisions,
        people = people,
    }
end

-- Runs the viewer took part in (for canHandle when the list is not already filtered).
local function OwnRuns(citizenid, uuids)
    local out = {}
    if not citizenid or #uuids == 0 then return out end
    local marks, params = {}, { citizenid }
    for i = 1, math.min(#uuids, 500) do
        marks[#marks + 1] = '?'
        params[#params + 1] = uuids[i]
    end
    for _, r in
        ipairs(Query(
            ('SELECT DISTINCT run_uuid FROM cp_mission_runs WHERE citizenid = ? AND run_uuid IN (%s)'):format(
                table.concat(marks, ', ')),
            params
        ) or {})
    do
        out[r.run_uuid] = true
    end
    return out
end

-- dropOwn: leave out disputes about runs the viewer took part in (the review lists never show them).
local function Views(rows, viewerCitizenid, dropOwn)
    local uuids, seen = {}, {}
    for _, r in ipairs(rows) do
        if r.run_uuid and not seen[r.run_uuid] then seen[r.run_uuid] = true; uuids[#uuids + 1] = r.run_uuid end
    end
    local own = OwnRuns(viewerCitizenid, uuids)
    local out = {}
    for _, r in ipairs(rows) do
        local mine = own[r.run_uuid] or InLiveRun(viewerCitizenid, r.run_uuid)
        if not (mine and dropOwn) then
            local v = ViewOf(r, viewerCitizenid)
            if mine then v.canHandle = false end
            out[#out + 1] = v
        end
    end
    return out
end

function D.forSupervisor(src)
    local officer = CP.Access and CP.Access.getOfficer and CP.Access.getOfficer(src) or nil
    local dept = officer and officer.department or nil
    if not dept and not IsAdmin(src) then return {} end
    local citizenid = officer and officer.citizenid or CitizenOf(src) or ''
    local sql = VIEW_SQL .. ' WHERE d.status = \'open\' AND d.goes_to = \'supervisor\''
    local params = {}
    if dept then
        sql = sql .. ' AND r.run_uuid IN (SELECT x.run_uuid FROM cp_mission_runs x WHERE x.department = ?)'
        params[#params + 1] = dept
    end
    sql = sql .. ' AND r.run_uuid NOT IN (SELECT y.run_uuid FROM cp_mission_runs y WHERE y.citizenid = ?)'
    params[#params + 1] = citizenid
    sql = sql .. (' ORDER BY d.created_at, d.id LIMIT %d'):format(LIST_LIMIT)
    return Views(Query(sql, params) or {}, citizenid ~= '' and citizenid or nil, true)
end

function D.forAdmin(excludeCitizenid)
    local sql = VIEW_SQL .. ' WHERE d.status = \'open\''
    local params = {}
    if type(excludeCitizenid) == 'string' and excludeCitizenid ~= '' then
        sql = sql .. ' AND r.run_uuid NOT IN (SELECT y.run_uuid FROM cp_mission_runs y WHERE y.citizenid = ?)'
        params[#params + 1] = excludeCitizenid
    end
    sql = sql .. (' ORDER BY d.created_at, d.id LIMIT %d'):format(LIST_LIMIT)
    local viewer = type(excludeCitizenid) == 'string' and excludeCitizenid ~= '' and excludeCitizenid or nil
    return Views(Query(sql, params) or {}, viewer, viewer ~= nil)
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
    local viewer = viewerSrc ~= nil and CitizenOf(viewerSrc) or nil
    return Views(Query(sql, params) or {}, viewer)
end

-- ============================================================================
--                                    FILING
-- ============================================================================

local ROW_SQL = [[SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, flagged, voided,
  cash_status, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_mission_runs WHERE id = ?]]

local function RunDepartments(runUuid)
    if Has('Admin', 'runDepartments') then
        local ok, list = Call('Admin', 'runDepartments', runUuid)
        if ok and type(list) == 'table' then return list end
    end
    local out = {}
    for _, r in ipairs(Query('SELECT DISTINCT department FROM cp_mission_runs WHERE run_uuid = ?', { runUuid }) or {}) do
        out[#out + 1] = r.department
    end
    return out
end

-- Supervisors answer disputes only while Config.Permissions.supervisor.handleDisputes is on.
local function SupervisorsHandle()
    local sup = Config.Permissions and Config.Permissions.supervisor
    return type(sup) == 'table' and sup.handleDisputes == true
end

-- The online staff for a dispute about runUuid (never participants of the run): admins, the on-duty
-- supervisors of the run's departments, whether a supervisor of those departments took part in the run
-- (supTookPart) and whether another one is online off duty (supOther). nil when qbx is unavailable.
local function OnlineStaff(runUuid)
    if not (Has('Qbx', 'getOnlinePlayers') and Has('Qbx', 'getInfo')) then return nil end
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    if not ok or type(list) ~= 'table' then return nil end
    local depts = {}
    for _, d in ipairs(RunDepartments(runUuid)) do depts[d] = true end
    local participants = {}
    for _, r in ipairs(Query('SELECT citizenid FROM cp_mission_runs WHERE run_uuid = ?', { runUuid }) or {}) do
        participants[r.citizenid] = true
    end
    local okR, run = Call('Runs', 'get', runUuid)
    if okR and type(run) == 'table' and type(run.participants) == 'table' then
        for _, p in pairs(run.participants) do
            if type(p) == 'table' and p.citizenid then participants[p.citizenid] = true end
        end
    end
    local function supervisorOfRun(info)
        if type(info.job) ~= 'table' or not (CP.Access and CP.Access.departmentForJob) then return false end
        local dk = CP.Access.departmentForJob(info.job.name)
        local dept = dk and depts[dk] and CP.Access.department(dk)
        return dept ~= nil and dept ~= false and Num(info.job.gradeLevel, -1) >= Num(dept.supervisorGrade, math.huge)
    end
    local admins, supervisors = {}, {}
    local supTookPart, supOther = false, false
    for _, s in ipairs(list) do
        local okI, info = Call('Qbx', 'getInfo', s)
        if okI and type(info) == 'table' then
            local sup = supervisorOfRun(info)
            if participants[info.citizenid] then
                if sup then supTookPart = true end
            else
                if IsAdmin(s) then admins[#admins + 1] = s end
                if sup and info.job.onduty then
                    supervisors[#supervisors + 1] = s
                elseif sup then
                    supOther = true   -- off duty now, but may still answer it once back on duty
                end
            end
        end
    end
    return { admins = admins, supervisors = supervisors, supTookPart = supTookPart, supOther = supOther }
end

-- Toast the staff who can answer a new dispute (never participants of the run). Admins for failed-run
-- disputes, or for every dispute while the supervisors' switch is off. A flagged/voided-run dispute goes to
-- the on-duty supervisors of the run's departments; when no online supervisor of those departments may
-- answer it (every one took part in the run, or none is online), the admins are told instead.
local function TellStaff(goesTo, runUuid, label)
    local st = OnlineStaff(runUuid)
    if not st then return end
    local targets
    if goesTo == 'admin' or not SupervisorsHandle() then
        -- With the supervisors' switch off, admins are the only ones who can answer it.
        targets = st.admins
    elseif #st.supervisors > 0 then
        targets = st.supervisors
    elseif not st.supOther then
        -- the same rule as D.supervisorCanAnswer: nobody there may answer it now, admins can
        targets = st.admins
    else
        targets = {}
    end
    if #targets > 0 and Has('Tablet', 'notifyMany') then
        Call('Tablet', 'notifyMany', targets, 'info', 'admin.notice.new_dispute', { mission = label })
    end
end

-- Whether a supervisor could answer a flagged/voided-run dispute about runUuid right now: the supervisors'
-- switch is on and an online supervisor of the run's departments who did not take part in it exists (on or
-- off duty). false means only an admin can answer it now (CP.Admin lists it on the Officers screen then,
-- matching the admins tellStaff notifies). true when that cannot be told (qbx unavailable): left to the
-- supervisors, as before.
function D.supervisorCanAnswer(runUuid)
    if not SupervisorsHandle() then return false end
    if type(runUuid) ~= 'string' or runUuid == '' then return true end
    local st = OnlineStaff(runUuid)
    if not st then return true end
    return #st.supervisors > 0 or st.supOther
end

local INSERT_SQL = [[INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to)
  SELECT ?, ?, ?, ? FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM cp_disputes WHERE run_id = ?)]]

function D.file(src, payload)
    local officer, errKey = nil, 'err.not_police'
    if CP.Access and CP.Access.getOfficer then officer, errKey = CP.Access.getOfficer(src) end
    if not officer then return false, errKey or 'err.not_police' end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local rowId = Int(payload.rowId, 1, 2147483647)
    if not rowId then return false, 'err.invalid_row' end
    local reason = CleanText(payload.reason, 255)
    if not reason then return false, 'err.reason_required' end
    if not CP.Net.rateOk(src, 'disputes:file', 3, 60000) then return false, 'err.rate_limited' end

    local row, okQ = Single(ROW_SQL, { rowId })
    if not okQ then return false, 'err.internal' end
    if not row then return false, 'err.row_not_found' end
    local ok, e, kind = D.eligible(row, officer.citizenid, os.time())
    if not ok then return false, e end

    local prev = Single('SELECT id, status FROM cp_disputes WHERE run_id = ? ORDER BY id DESC LIMIT 1', { rowId })
    if prev then return false, prev.status == 'open' and 'err.dispute_open' or 'err.dispute_final' end

    local goesTo = D.goesTo(kind)
    Db()
    local okI, id = pcall(MySQL.insert.await, INSERT_SQL, { rowId, officer.citizenid, reason, goesTo, rowId })
    if not okI then
        CP.err(TAG, 'dispute insert failed: %s', tostring(id))
        return false, 'err.internal'
    end
    id = tonumber(id)
    if not id or id <= 0 then return false, 'err.dispute_open' end

    local label = MissionLabel(row.mission_id)
    Webhook('flags', CP.L('admin.webhook.dispute_filed', { mission = label }),
        CP.L('admin.webhook.dispute_filed_desc', { goes_to = CP.L('admin.dispute.goes_to.' .. goesTo) }), {
            {
                name = CP.L('admin.webhook.field.officer'),
                value = ('%s (%s)'):format(officer.name or officer.citizenid, officer.citizenid),
                inline = true,
            },
            {
                name = CP.L('admin.webhook.field.run'),
                value = ('#%d · %s'):format(rowId, CP.L('admin.dispute.kind.' .. kind)),
                inline = true,
            },
            { name = CP.L('admin.webhook.field.reason'), value = reason, inline = false },
        })
    CreateThread(function() TellStaff(goesTo, row.run_uuid, label) end)
    CP.log(TAG, 'dispute %d filed by %s about row %d (%s -> %s)', id, officer.citizenid, rowId, kind, goesTo)
    return true, { disputeId = id, goesTo = goesTo, kind = kind }
end

-- ============================================================================
--                                  ANSWERING
-- ============================================================================

local LOAD_SQL = [[SELECT d.id, d.run_id, d.citizenid, d.goes_to, d.status,
  r.run_uuid, r.mission_id, r.mission_type, r.state, r.flagged, r.voided, r.cash_status
  FROM cp_disputes d JOIN cp_mission_runs r ON r.id = d.run_id WHERE d.id = ?]]

local RESTORE_SQL = [[UPDATE cp_mission_runs SET voided = 0, flagged = 0, void_kind = NULL, void_batch = NULL,
  breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.flagged', NULL), breakdown)
  WHERE id = ? AND voided = 1]]

local function RestoreVoided(d)
    local n = Update(RESTORE_SQL, { d.run_id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then
        return true
    end -- already restored
    Call('Scoring', 'onRowApproved', d.run_id)
    if d.cash_status == 'held' or d.cash_status == 'pending' then Call('Cash', 'release', d.run_id) end
    Call('Leaderboard', 'invalidate')
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('row:restored', d.run_id) end
    return true
end

-- An admin's Restore run (outside a dispute): the same path as an approved dispute. Points and XP come back, held
-- or pending cash is released (forfeited cash stays forfeited), and an open dispute about the row closes as
-- approved. The UPDATE is the compare-and-set: of two restores one wins. ok, info | false, errKey.
function D.restoreRow(src, rowId, reason)
    local id = Int(rowId, 1, 2147483647)
    if not id then return false, 'err.invalid_row' end
    local row, okQ = Single(ROW_SQL, { id })
    if not okQ then return false, 'err.internal' end
    if not row then return false, 'err.row_not_found' end
    if not U.truthy(row.voided) then return false, 'err.not_voided' end
    local n = Update(RESTORE_SQL, { id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then return false, 'err.state_changed' end
    Call('Scoring', 'onRowApproved', id)
    local released = row.cash_status == 'held' or row.cash_status == 'pending'
    if released then Call('Cash', 'release', id) end
    local handler = tonumber(src) == 0 and 'console' or (CitizenOf(src) or ('player:' .. tostring(src)))
    -- two statements (files mode has no multi-table UPDATE): close the dispute, then nothing else
    local closed = Update([[UPDATE cp_disputes SET status = 'approved', handled_by = ?, handled_at = NOW()
        WHERE run_id = ? AND status = 'open']], { Clip(handler, 50), id }) or 0
    Call('Leaderboard', 'invalidate')
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('row:restored', id) end
    Notify(OnlineSrc(row.citizenid), 'success', 'admin.notice.run_restored', { mission = MissionLabel(row.mission_id) })
    return true,
        {
            rowId = id,
            citizenid = row.citizenid,
            missionId = row.mission_id,
            missionType = row.mission_type,
            cashStatus = row.cash_status,
            released = released,
            disputeClosed = closed > 0,
        }
end

-- Open disputes an admin can answer (the sidebar count): cached 30 s.
local openCache = { at = 0, n = 0 }
function D.openCount()
    if os.time() - openCache.at < 30 then return openCache.n end
    local okC, n = pcall(MySQL.scalar.await, 'SELECT COUNT(*) AS n FROM cp_disputes WHERE status = \'open\'', {})
    openCache = { at = os.time(), n = okC and math.floor(Num(n, 0)) or 0 }
    return openCache.n
end

local function Reopen(id)
    Update('UPDATE cp_disputes SET status = \'open\', handled_by = NULL, handled_at = NULL WHERE id = ?', { id })
end

function D.handle(src, disputeId, decision, reason, awardPoints, opts)
    opts = type(opts) == 'table' and opts or {}
    local id = Int(disputeId, 1, 2147483647)
    if not id then return false, 'err.invalid_dispute' end
    if decision ~= 'approve' and decision ~= 'reject' then return false, 'err.invalid_decision' end
    reason = CleanText(reason, 255)
    if not reason then return false, 'err.reason_required' end
    if opts.adminOnly and not IsAdmin(src) then return false, 'err.no_permission' end

    local d, okQ = Single(LOAD_SQL, { id })
    if not okQ then return false, 'err.internal' end
    if not d then return false, 'err.dispute_not_found' end
    d.run_id = math.tointeger(tonumber(d.run_id)) or d.run_id
    if d.status ~= 'open' then return false, 'err.dispute_closed' end

    local kind = d.goes_to == 'admin' and 'failed' or (U.truthy(d.voided) and 'voided' or 'flagged')
    if d.goes_to == 'admin' then
        local ok, e = Can(src, 'handleFailedDispute')
        if not ok then return false, e end
    else
        local ctx = nil
        if not IsAdmin(src) then ctx = { departments = RunDepartments(d.run_uuid) } end
        local ok, e = Can(src, 'handleDisputes', ctx)
        if not ok then return false, e end
    end
    if not Has('Permissions', 'canReviewRun') then return false, 'err.no_permission' end
    local okR, allowed, eR = Call('Permissions', 'canReviewRun', src, d.run_uuid)
    if not okR then return false, 'err.internal' end
    if not allowed then return false, eR or 'err.own_run' end
    if InLiveRun(CitizenOf(src), d.run_uuid) then return false, 'err.own_run' end

    local points
    if decision == 'approve' and kind == 'failed' then
        points = Int(awardPoints, 1, MAX_AWARD)
        if not points then return false, 'err.invalid_points' end
        if not Has('Scoring', 'manualAward') then return false, 'err.module_unavailable' end
    end

    local handler = tonumber(src) == 0 and 'console' or (CitizenOf(src) or ('player:' .. tostring(src)))
    local status = decision == 'approve' and 'approved' or 'rejected'
    local claimed = Update(
        'UPDATE cp_disputes SET status = ?, handled_by = ?, handled_at = NOW() WHERE id = ? AND status = \'open\'',
        { status, Clip(handler, 50), id })
    if claimed == nil then return false, 'err.internal' end
    if claimed == 0 then return false, 'err.dispute_closed' end

    if decision == 'approve' then
        if kind == 'failed' then
            local ok, res, e = Call('Scoring', 'manualAward', src, d.citizenid, points, reason)
            if not ok or res == false or (res == nil and type(e) == 'string') then
                Reopen(id)
                return false, (ok and e) or 'err.internal'
            end
        elseif kind == 'flagged' then
            local ok, res, e = Call('Admin', 'approveFlagged', src, d.run_id, reason,
                { skipPermission = true, noAudit = true, quiet = true })
            if not ok or (res == false and e ~= 'err.not_flagged') then
                if ok and e == 'err.already_voided' then
                    local done = RestoreVoided(d)
                    if not done then Reopen(id); return false, 'err.internal' end
                else
                    Reopen(id)
                    return false, (ok and e) or 'err.internal'
                end
            end
        else
            local done, e = RestoreVoided(d)
            if not done then
                Reopen(id)
                return false, e
            end
        end
    elseif kind == 'voided' and (d.cash_status == 'held' or d.cash_status == 'pending') then
        Call('Cash', 'forfeit', d.run_id)
    end

    local label = MissionLabel(d.mission_id)
    local newValue = status
    if points then newValue = ('+%d'):format(points) end
    Audit(src, RoleOf(src), 'flags', decision == 'approve' and 'disputeApproved' or 'disputeRejected',
        ('#%s %s'):format(tostring(d.run_id), tostring(d.citizenid)), kind, newValue, reason)
    Notify(OnlineSrc(d.citizenid), decision == 'approve' and 'success' or 'warning',
        decision == 'approve' and 'admin.notice.dispute_approved' or 'admin.notice.dispute_rejected',
        { mission = label })
    CP.log(TAG, 'dispute %d %s by %s', id, status, tostring(handler))
    return true, { disputeId = id, status = status, kind = kind, points = points }
end

-- ============================================================================
--                                     NET
-- ============================================================================

CP.Net.action('server:dispute', function(src, payload)
    return D.file(src, payload)
end, { rate = 2 })

CP.Net.action('server:sup:handleDispute', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local id = Int(payload.disputeId, 1, 2147483647)
    if not id then return false, 'err.invalid_dispute' end
    -- The supervisor endpoint answers flagged/voided disputes only (failed runs go to admins).
    if not IsAdmin(src) then
        local row = Single('SELECT goes_to FROM cp_disputes WHERE id = ?', { id })
        if row and row.goes_to == 'admin' then return false, 'err.no_permission' end
    end
    return D.handle(src, id, payload.decision, payload.reason, payload.awardPoints)
end, { rate = 3 })

CP.Net.action('server:admin:handleDispute', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return D.handle(src, payload.disputeId, payload.decision, payload.reason, payload.awardPoints, { adminOnly = true })
end, { rate = 3 })

CP.Net.callback('admin:getDisputes', function(src)
    local ok, e = Can(src, 'openAdmin')
    if not ok then return nil, e end
    return { disputes = D.forAdmin(CitizenOf(src)) }
end, { rate = 3 })

-- Officers → Disputes: the admin sidebar count (admins only), registered once every module has loaded.
CreateThread(function()
    Wait(0)
    if CP.Tablet and CP.Tablet.registerNavCount then
        CP.Tablet.registerNavCount('adminDisputes', function() return D.openCount() end, { adminOnly = true })
    end
end)
