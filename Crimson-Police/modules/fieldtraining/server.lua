-- CP.FieldTraining (server): field training (Config.FieldTraining). Pairing, runs that count, the trainer's
-- sign-offs (and his trainerBonus points), the badge, and the ride-along rule (requireTrainerFor) that CP.Draw's
-- accept asks.

-- CP.FieldTraining (server): field training (Config.FieldTraining). A supervisor (or an admin) pairs a
-- trainer with a rookie of the department; completed runs the two finish together count towards the sign-off tasks
-- (per mission type); the trainer signs a task off once its count is reached (trainerBonus points to him); every
-- task signed off gives the badge. The ride-along rule (requireTrainerFor, checked by CP.Draw's accept). FT.joinCheck,
-- the same rule for a live case backup (CP.Runs.addParticipant).
-- The record lives on the rookie's officer row (cp_officers.field_training, migration 015), so the database and the
-- saves folder keep it alike. Shipped off: no hook does anything and every action is refused.

CP.FieldTraining = CP.FieldTraining or {}
local FT = CP.FieldTraining
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'fieldtraining'

local CITIZENID_MAX = 50
local NAME_MAX = 64
local BADGE_MAX = 40
local CANDIDATES_MAX = 300   -- officers of one department the pair dialog lists
local LOCK_TRIES = 100       -- 50 ms waits for a rookie's record another thread is writing

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false, nil end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

local function Cfg() return type(Config.FieldTraining) == 'table' and Config.FieldTraining or {} end

function FT.enabled() return Cfg().enabled == true end

local function Cid(v)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v)
    if s == '' or #s > CITIZENID_MAX or not s:match('^[%w_%-]+$') then return nil end
    return s
end

local function Int(v)
    local n = tonumber(v)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return math.floor(n)
end

local function IsAdmin(src) return CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src) == true end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

-- The lowest Qbox grade of a trainer in a department (Config.FieldTraining.trainerGrades, else its supervisorGrade).
function FT.trainerGrade(dept)
    local g = type(Cfg().trainerGrades) == 'table' and Int(Cfg().trainerGrades[dept]) or nil
    if g then return g end
    local d = type(Config.Departments) == 'table' and Config.Departments[dept] or nil
    return type(d) == 'table' and Int(d.supervisorGrade) or 0
end

-- The sign-off tasks in a fixed order: { { type, need, label } } (a mission type with a count above 0).
function FT.tasks()
    local out = {}
    local types = type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}
    for key, n in pairs(type(Cfg().tasks) == 'table' and Cfg().tasks or {}) do
        local need = Int(n)
        if type(key) == 'string' and need and need > 0 then
            local mt = types[key]
            out[#out + 1] = { type = key, need = need, label = type(mt) == 'table' and mt.label or key }
        end
    end
    table.sort(out, function(a, b) return a.type < b.type end)
    return out
end

local function TaskNeed(missionType)
    for _, t in ipairs(FT.tasks()) do
        if t.type == missionType then return t.need end
    end
    return nil
end

local function TaskLabel(missionType)
    for _, t in ipairs(FT.tasks()) do
        if t.type == missionType then return t.label end
    end
    local mt = type(Config.MissionTypes) == 'table' and Config.MissionTypes[missionType] or nil
    return type(mt) == 'table' and mt.label or missionType
end

local function RookiesMax() return math.max(1, Int(Cfg().rookiesPerTrainer) or 2) end

local BONUS_MAX = 1000

-- Points the trainer gets per signed task (Config.FieldTraining.trainerBonus, 0 to 1000; 0 = none).
function FT.trainerBonus() return math.max(0, math.min(BONUS_MAX, Int(Cfg().trainerBonus) or 0)) end

-- The mission types of the ride-along rule (Config.FieldTraining.requireTrainerFor): { [type] = true }. A list of
-- type keys; a { tactical = true } map is read the same way.
function FT.requiredTypes()
    local out = {}
    local list = Cfg().requireTrainerFor
    for k, v in pairs(type(list) == 'table' and list or {}) do
        if type(v) == 'string' and v ~= '' then
            out[v] = true
        elseif type(k) == 'string' and v == true then
            out[k] = true
        end
    end
    return out
end

-- The badge id: letters, digits and _ only, at most 40 characters (cp_badges.badge_id).
function FT.badge()
    local b = Cfg().badge
    if type(b) ~= 'string' or b == '' or #b > BADGE_MAX or not b:match('^[%w_]+$') then return 'field_training' end
    return b
end

-- ============================================================================
--                                  THE RECORD
-- ============================================================================

local function Decode(v)
    local t = U.jsonField(v)
    if type(t) ~= 'table' or type(t.trainer) ~= 'string' then return nil end
    if type(t.tasks) ~= 'table' then t.tasks = {} end
    return t
end

-- The rookie's officer row: { department, name, record | nil } | nil (no row).
local function ReadRow(cid)
    Db()
    local ok, row = pcall(MySQL.single.await,
        'SELECT department, display_name, field_training FROM cp_officers WHERE citizenid = ? LIMIT 1', { cid })
    if not ok then
        CP.err(TAG, 'reading %s failed: %s', cid, tostring(row))
        return nil, 'err.internal'
    end
    if type(row) ~= 'table' then return nil end
    return { department = row.department, name = row.display_name, record = Decode(row.field_training) }
end

local function WriteRecord(cid, record)
    Db()
    local text = record and json.encode(U.serialize(record)) or nil
    local ok, n = pcall(MySQL.update.await, 'UPDATE cp_officers SET field_training = ? WHERE citizenid = ?',
        { text, cid })
    if not ok then
        CP.err(TAG, 'saving %s failed: %s', cid, tostring(n))
        return false
    end
    return (tonumber(n) or 0) > 0
end

local Locks = {}  -- { [rookie citizenid] = true }: one read-change-write of a record at a time

local function WithLock(cid, fn)
    local tries = 0
    while Locks[cid] do
        tries = tries + 1
        if tries > LOCK_TRIES then return false, 'err.busy' end
        Wait(50)
    end
    Locks[cid] = true
    local res = table.pack(pcall(fn))
    Locks[cid] = nil
    if not res[1] then
        CP.err(TAG, 'field training of %s failed: %s', cid, tostring(res[2]))
        return false, 'err.internal'
    end
    return table.unpack(res, 2, res.n)
end

local function Active(record) return type(record) == 'table' and record.doneAt == nil end

-- The officer's department: his Qbox job while online, else cp_officers.department.
local function DeptOf(cid, row)
    local okS, src = Call('Qbx', 'getByCitizenId', cid)
    src = okS and math.tointeger(tonumber(src) or 0) or 0
    if src and src > 0 then
        local _, info = Call('Qbx', 'getInfo', src)
        if type(info) == 'table' and type(info.job) == 'table' then
            local _, dept = Call('Access', 'departmentForJob', info.job.name)
            if type(dept) == 'string' then return dept end
        end
    end
    row = row or ReadRow(cid)
    return type(row) == 'table' and type(row.department) == 'string' and row.department ~= '' and row.department or nil
end

-- The active rookies of one trainer: { { citizenid, name, callsign, department, record } }.
local function RookiesOf(trainerCid)
    Db()
    local ok, rows = pcall(MySQL.query.await, [[SELECT citizenid, display_name, callsign, department, field_training
        FROM cp_officers WHERE JSON_VALUE(field_training, '$.trainer') = ?]], { trainerCid })
    if not ok then
        CP.err(TAG, 'rookies of %s failed: %s', trainerCid, tostring(rows))
        return nil
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local rec = Decode(r.field_training)
        if Active(rec) and rec.trainer == trainerCid then
            out[#out + 1] = {
                citizenid = r.citizenid,
                name = r.display_name,
                callsign = r.callsign,
                department = r.department,
                record = rec,
            }
        end
    end
    return out
end

-- What the tablet shows of one record: tasks in config order with their counts and sign-offs.
function FT.view(cid, name, record)
    if type(record) ~= 'table' then return nil end
    local tasks, signed = {}, 0
    for _, t in ipairs(FT.tasks()) do
        local st = type(record.tasks[t.type]) == 'table' and record.tasks[t.type] or {}
        local runs = math.min(t.need, Int(st.runs) or 0)
        local s = st.signedAt
                and {
                    by = st.signedName or st.signedBy,
                    at = Int(st.signedAt),
                    note = st.note,
                }
            or nil
        if s then signed = signed + 1 end
        tasks[#tasks + 1] = {
            type = t.type,
            label = t.label,
            need = t.need,
            runs = runs,
            ready = s == nil and runs >= t.need,
            signed = s,
        }
    end
    return {
        rookie = { citizenid = cid, name = name or cid },
        trainer = { citizenid = record.trainer, name = record.trainerName or record.trainer },
        department = record.dept,
        pairedAt = Int(record.at),
        pairedBy = record.byName or record.by,
        doneAt = Int(record.doneAt),
        signed = signed,
        total = #tasks,
        tasks = tasks,
    }
end

-- ============================================================================
--                          RUNS THAT COUNT (THE HOOK)
-- ============================================================================

-- A completed, unflagged row of a rookie in training whose trainer finished the same run (same unit) counts one run
-- towards the task of the run's mission type (up to the task's count).
local function TrainerFinished(run, p, trainerCid)
    for _, q in pairs(type(run.participants) == 'table' and run.participants or {}) do
        if type(q) == 'table' and q ~= p and q.citizenid == trainerCid and q.result == 'completed' then
            return true
        end
    end
    return false
end

function FT.onRowSettled(run, p, _, row)
    if not FT.enabled() or type(run) ~= 'table' or type(p) ~= 'table' or type(row) ~= 'table' then return false end
    if run.test or row.state ~= 'completed' or U.truthy(row.flagged) then return false end
    local cid = Cid(p.citizenid)
    local need = TaskNeed(run.missionType)
    if not cid or not need then return false end
    local ok, counted = WithLock(cid, function()
        local r = ReadRow(cid)
        local rec = r and r.record
        if not Active(rec) or not TrainerFinished(run, p, rec.trainer) then return false end
        local st = type(rec.tasks[run.missionType]) == 'table' and rec.tasks[run.missionType] or {}
        if st.signedAt or (Int(st.runs) or 0) >= need then return false end
        st.runs = (Int(st.runs) or 0) + 1
        rec.tasks[run.missionType] = st
        if not WriteRecord(cid, rec) then return false end
        CP.log(TAG, '%s: %s run %d of %d with trainer %s', cid, run.missionType, st.runs, need, rec.trainer)
        if st.runs >= need then
            Kit.notify(rec.trainer, 'info', 'fto.toast.ready',
                { name = r.name or cid, task = TaskLabel(run.missionType) })
        end
        return true
    end)
    return ok == true and counted ~= false
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('row:settled', function(run, p, rowId, row) FT.onRowSettled(run, p, rowId, row) end)
end

-- ============================================================================
--                             THE RIDE-ALONG RULE
-- ============================================================================

-- CP.Draw's accept (the Mission Board and a mission call claim): a rookie in training may take a mission type of
-- requireTrainerFor only with his trainer in the same unit. officers = { { citizenid } } (the whole unit).
-- -> true | false, 'err.fto_trainer_needed', the rookie's citizenid. Reads nothing while the rule is empty.
function FT.unitCheck(officers, missionType)
    if not FT.enabled() or type(officers) ~= 'table' or type(missionType) ~= 'string' then return true end
    if not FT.requiredTypes()[missionType] then return true end
    local inUnit = {}
    for _, o in ipairs(officers) do
        if type(o) == 'table' and type(o.citizenid) == 'string' then inUnit[o.citizenid] = true end
    end
    for _, o in ipairs(officers) do
        local cid = type(o) == 'table' and Cid(o.citizenid) or nil
        local r = cid and ReadRow(cid) or nil
        local rec = r and r.record
        if Active(rec) and not inUnit[rec.trainer] then return false, 'err.fto_trainer_needed', cid end
    end
    return true
end

-- A live case's backup (CP.Runs.addParticipant): the same rule for the officer who joins late, with the
-- officers already on the case as his unit. unit = { citizenid, ... } (the active participants).
-- -> true | false, 'err.fto_trainer_needed'. Reads nothing while the rule is empty or does not list missionType.
function FT.joinCheck(cid, unit, missionType)
    if not FT.enabled() or type(missionType) ~= 'string' or not FT.requiredTypes()[missionType] then return true end
    cid = Cid(cid)
    local r = cid and ReadRow(cid) or nil
    local rec = r and r.record
    if not Active(rec) then return true end
    for _, c in ipairs(type(unit) == 'table' and unit or {}) do
        if c == rec.trainer then return true end
    end
    return false, 'err.fto_trainer_needed'
end

-- ============================================================================
--                         SUPERVISORS: PAIR AND UNPAIR
-- ============================================================================

local function DeptLabel(dept)
    local d = type(Config.Departments) == 'table' and Config.Departments[dept] or nil
    return type(d) == 'table' and (d.short or d.label) or dept
end

-- Admins always; a supervisor only for his own department (CP.Permissions, fieldTraining is every supervisor's), and
-- an officer an admin granted fieldTraining (Config.Permissions.grants), for his own department too.
local function CanManage(src, dept)
    if not FT.enabled() then return false, 'err.fto_off' end
    if type(dept) ~= 'string' then return false, 'err.unknown_officer' end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    return CP.Permissions.can(src, 'fieldTraining', { department = dept })
end

local function RookiePermission(src, payload)
    local cid = type(payload) == 'table' and Cid(payload.rookie) or nil
    if not cid then return false, 'err.invalid_payload' end
    return CanManage(src, DeptOf(cid))
end

-- { rookie, trainer }: both of the same department, the trainer online at or above the trainer grade, the rookie not
-- in training already, the trainer not in training himself and under rookiesPerTrainer.
local function Pair(ctx)
    local rookie, trainer = Cid(ctx.payload.rookie), Cid(ctx.payload.trainer)
    if not rookie or not trainer then return false, 'err.invalid_payload' end
    if rookie == trainer then return false, 'err.fto_same_officer' end
    local okT, tSrc = Call('Qbx', 'getByCitizenId', trainer)
    tSrc = okT and math.tointeger(tonumber(tSrc) or 0) or 0
    local tOfficer = tSrc and tSrc > 0 and CP.Access.getOfficer(tSrc) or nil
    if not tOfficer then return false, 'err.fto_trainer_offline' end
    return WithLock(rookie, function()
        local r = ReadRow(rookie)
        if not r then return false, 'err.unknown_officer' end
        local dept = DeptOf(rookie, r)
        if tOfficer.department ~= dept then return false, 'err.other_department' end
        if (Int(tOfficer.gradeLevel) or 0) < FT.trainerGrade(dept) then return false, 'err.fto_trainer_grade' end
        if Active(r.record) then return false, 'err.fto_already_paired' end
        local tRow = ReadRow(trainer)
        if tRow and Active(tRow.record) then return false, 'err.fto_trainer_in_training' end
        local list = RookiesOf(trainer)
        if not list then return false, 'err.internal' end
        if #list >= RookiesMax() then return false, 'err.fto_trainer_full' end
        local _, byInfo = Call('Qbx', 'getInfo', ctx.src)
        local record = {
            trainer = trainer,
            trainerName = U.clip(tOfficer.name, NAME_MAX),
            dept = dept,
            by = ctx.actor and tostring(ctx.actor) or 'console',
            byName = type(byInfo) == 'table' and U.clip(byInfo.name, NAME_MAX) or nil,
            at = os.time(),
            tasks = {},
        }
        if not ctx.audit('ftoPair', rookie, nil, trainer) then return false, 'err.internal' end
        if not WriteRecord(rookie, record) then return false, 'err.internal' end
        Kit.notify(rookie, 'success', 'fto.toast.paired_rookie', { name = record.trainerName })
        Kit.notify(trainer, 'success', 'fto.toast.paired_trainer', { name = r.name or rookie })
        return true, FT.view(rookie, r.name, record)
    end)
end

local function Unpair(ctx)
    local rookie = Cid(ctx.payload.rookie)
    if not rookie then return false, 'err.invalid_payload' end
    return WithLock(rookie, function()
        local r = ReadRow(rookie)
        if not r or not Active(r.record) then return false, 'err.fto_not_paired' end
        if not ctx.audit('ftoUnpair', rookie, r.record.trainer, nil) then return false, 'err.internal' end
        if not WriteRecord(rookie, nil) then return false, 'err.internal' end
        return true, { rookie = rookie }
    end)
end

local function RookieTarget(payload) return { citizenid = Cid(payload.rookie) } end

Kit.supAction('server:sup:ftoPair', 'fieldTraining', Pair, {
    self = RookieTarget,
    permission = RookiePermission,
    reason = 'optional',
})
Kit.supAction('server:sup:ftoUnpair', 'fieldTraining', Unpair, {
    self = RookieTarget,
    permission = RookiePermission,
    reason = 'optional',
})

-- ============================================================================
--                         THE TRAINER SIGNS A TASK OFF
-- ============================================================================

-- Every task signed off: the training is done and the rookie gets the badge (cp_badges, the Profile's badges).
local function Finish(cid, record, name)
    for _, t in ipairs(FT.tasks()) do
        local st = record.tasks[t.type]
        if type(st) ~= 'table' or not st.signedAt then return false end
    end
    record.doneAt = os.time()
    local badge = FT.badge()
    local ok, err = pcall(MySQL.update.await,
        'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { cid, badge, record.doneAt })
    if not ok then CP.err(TAG, 'the %s badge for %s failed: %s', badge, cid, tostring(err)) end
    CP.log(TAG, '%s finished field training with %s', cid, record.trainer)
    Kit.notify(cid, 'success', 'fto.toast.done', { name = record.trainerName or record.trainer })
    Kit.notify(record.trainer, 'success', 'fto.toast.done_trainer', { name = name or cid })
    return true
end

-- trainerBonus: a points row for the trainer (a manual_award row, mission id fto_bonus, shown in his history).
local function Bonus(trainerCid, rookieName, task)
    local n = FT.trainerBonus()
    if n <= 0 then return nil end
    local reason = CP.L('fto.bonus_reason', { task = TaskLabel(task), name = rookieName })
    local ok, rowId = Call('Scoring', '_insertBonusRow', trainerCid, 'manual_award', 'fto_bonus', n,
        CP.L('admin.mission.fto_bonus'), { reason = reason, by = 'field_training' })
    if not ok or not rowId then
        CP.warn(TAG, 'the trainer bonus of %s could not be saved', trainerCid)
        return nil
    end
    Kit.notify(trainerCid, 'success', 'fto.toast.bonus', { points = n, name = rookieName })
    return rowId
end

-- { rookie, task, note? }: only the rookie's own trainer, only a task whose count is reached and not signed yet.
function FT.signOff(src, payload)
    if not FT.enabled() then return false, 'err.fto_off' end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local officer, errO = CP.Access.getOfficer(src)
    if not officer then return false, errO or 'err.not_police' end
    local rookie, task = Cid(payload.rookie), payload.task
    if not rookie or type(task) ~= 'string' or #task > 32 then return false, 'err.invalid_payload' end
    local note, errN = Kit.reason(payload.note, true)
    if errN then return false, errN end
    local need = TaskNeed(task)
    if not need then return false, 'err.fto_task_unknown' end
    return WithLock(rookie, function()
        local r = ReadRow(rookie)
        local rec = r and r.record
        if not Active(rec) then return false, 'err.fto_not_paired' end
        if rec.trainer ~= officer.citizenid then return false, 'err.fto_not_trainer' end
        local st = type(rec.tasks[task]) == 'table' and rec.tasks[task] or {}
        if st.signedAt then return false, 'err.fto_task_signed' end
        if (Int(st.runs) or 0) < need then return false, 'err.fto_task_not_ready' end
        st.signedBy, st.signedName, st.signedAt = officer.citizenid, U.clip(officer.name, NAME_MAX), os.time()
        st.note = note
        rec.tasks[task] = st
        local id = Kit.auditSync(src, 'audit', 'ftoSignOff', rookie, nil, task, note, { role = 'supervisor' })
        if not id then return false, 'err.internal' end
        local done = Finish(rookie, rec, r.name)
        if not WriteRecord(rookie, rec) then return false, 'err.internal' end
        Kit.notify(rookie, 'success', 'fto.toast.signed', { task = TaskLabel(task), name = st.signedName })
        Bonus(officer.citizenid, r.name or rookie, task)
        -- Config.FeatureRewards: the trainer per sign-off, the rookie once his training is done; each once
        -- per rookie and task whatever pairing comes later (uuidCid: the row is keyed by the rookie, not the trainer)
        local FR = CP.FeatureRewards
        if FR and FR.payLater then
            FR.payLater('ftoSignOff', officer.citizenid, { key = ('fto:%s:%s'):format(rookie, task), uuidCid = rookie })
            if done then FR.payLater('ftoComplete', rookie, { key = ('fto:%s:done'):format(rookie) }) end
        end
        return true, FT.view(rookie, r.name, rec)
    end)
end

CP.Net.action('server:fto:signOff', function(src, payload) return FT.signOff(src, payload) end, { rate = 2 })

-- ============================================================================
--                                  THE VIEWS
-- ============================================================================

-- Profile -> Field training (an officer): his own training as a rookie and his rookies as a trainer; nil when the
-- feature is off or he has neither.
function FT.mine(src)
    if not FT.enabled() then return nil end
    local officer = CP.Access.getOfficer(src)
    if not officer then return nil end
    local out = { rookies = {} }
    local r = ReadRow(officer.citizenid)
    if r and r.record then
        out.training = FT.view(officer.citizenid, r.name or officer.name, r.record)
        local need = {}
        for t in pairs(Active(r.record) and FT.requiredTypes() or {}) do need[#need + 1] = TaskLabel(t) end
        table.sort(need)
        out.training.needsTrainer = need
    end
    for _, x in ipairs(RookiesOf(officer.citizenid) or {}) do
        out.rookies[#out.rookies + 1] = FT.view(x.citizenid, x.name, x.record)
    end
    if not out.training and #out.rookies == 0 then return nil end
    out.trainerBonus = FT.trainerBonus()
    return out
end

CP.Net.callback('fto:getMine', function(src) return FT.mine(src) or false end, { rate = 2 })

-- Online officers of the department who may train (grade at or above the trainer grade).
local function Trainers(dept)
    local out = {}
    local min = FT.trainerGrade(dept)
    for _, s in ipairs(GetPlayers and GetPlayers() or {}) do
        local o = CP.Access.getOfficer(tonumber(s))
        if o and o.department == dept and (Int(o.gradeLevel) or 0) >= min then
            out[#out + 1] = { citizenid = o.citizenid, name = o.name, rank = o.rank }
        end
    end
    table.sort(out, function(a, b) return tostring(a.name) < tostring(b.name) end)
    return out
end

-- Supervisor UI -> Department Report -> Field training: every pairing of the department, the officers who may be
-- paired as rookies and the online trainers; nil when the feature is off.
function FT.deptView(src, dept)
    local ok, errKey = CanManage(src, dept)
    if not ok then return nil, errKey end
    Db()
    local okQ, rows = pcall(MySQL.query.await, [[SELECT citizenid, display_name, callsign, field_training
        FROM cp_officers WHERE department = ? ORDER BY display_name LIMIT ?]], { dept, CANDIDATES_MAX })
    if not okQ then
        CP.err(TAG, 'department %s failed: %s', dept, tostring(rows))
        return nil, 'err.internal'
    end
    local pairs_, candidates = {}, {}
    for _, r in ipairs(rows or {}) do
        local rec = Decode(r.field_training)
        if rec then pairs_[#pairs_ + 1] = FT.view(r.citizenid, r.display_name, rec) end
        if not Active(rec) then
            candidates[#candidates + 1] = { citizenid = r.citizenid, name = r.display_name, callsign = r.callsign }
        end
    end
    return {
        department = dept,
        departmentLabel = DeptLabel(dept),
        trainerGrade = FT.trainerGrade(dept),
        rookiesPerTrainer = RookiesMax(),
        tasks = FT.tasks(),
        pairs = pairs_,
        candidates = candidates,
        trainers = Trainers(dept),
    }
end

CP.Net.callback('sup:getFieldTraining', function(src, args)
    if not FT.enabled() then return false end
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local officer = CP.Access.getOfficer(src)
    local dept = officer and officer.department or nil
    local wanted = args and args.department
    if type(wanted) == 'string' and wanted ~= '' and wanted ~= dept then
        if not IsAdmin(src) then return nil, 'err.other_department' end
        dept = wanted
    end
    if not dept then return nil, 'err.not_police' end
    return FT.deptView(src, dept)
end, { rate = 2 })
