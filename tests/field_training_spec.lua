-- Field training, part 1 (step T1, Config.FieldTraining): a supervisor pairs a trainer with a rookie of his own
-- department, completed runs the two finish together count per mission type, the trainer signs a ready task off,
-- and every task signed off gives the badge. Plain Lua: stubbed MySQL (the officer rows), the real adminkit.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

-- src -> { cid, license, dept, sup, admin, grade }
local people = {
    [1] = { cid = 'FT_ADMIN', license = 'license:a1', dept = 'sast', sup = true, admin = true, grade = 6 },
    [2] = { cid = 'FT_SUP02', license = 'license:s2', dept = 'sast', sup = true, grade = 4 },
    [3] = { cid = 'FT_TRN03', license = 'license:t3', dept = 'sast', grade = 2 },
    [4] = { cid = 'FT_ROO04', license = 'license:r4', dept = 'sast', grade = 0 },
    [5] = { cid = 'FT_LOW05', license = 'license:l5', dept = 'sast', grade = 1 },
    [6] = { cid = 'FT_FIB06', license = 'license:f6', dept = 'fib', grade = 3 },
    [7] = { cid = 'FT_ROO07', license = 'license:r7', dept = 'sast', grade = 0 },
    [8] = { cid = 'FT_ROO08', license = 'license:r8', dept = 'sast', grade = 0 },
}
-- the officer rows (cp_officers): citizenid -> { department, display_name, field_training }
local officers = {}
for src, p in pairs(people) do
    H.players[src] = { ace = {}, coords = vec3(0.0, 0.0, 0.0) }
    officers[p.cid] = { department = p.dept, display_name = 'Officer ' .. src }
end
officers.FT_OFF09 = { department = 'sast', display_name = 'Offline Rookie' }
local function SrcOf(cid)
    for src, p in pairs(people) do if p.cid == cid then return src end end
    return nil
end

local badges, audits, toasts = {}, {}, {}
MySQL.single.await = function(sql, params)
    if sql:find('field_training FROM cp_officers WHERE citizenid', 1, true) then return officers[params[1]] end
    return nil
end
MySQL.update.await = function(sql, params)
    if sql:find('UPDATE cp_officers SET field_training', 1, true) then
        local o = officers[params[2]]
        if not o then return 0 end
        o.field_training = params[1]
        return 1
    end
    if sql:find('INSERT IGNORE INTO cp_badges', 1, true) then
        badges[#badges + 1] = { citizenid = params[1], badge = params[2] }
        return 1
    end
    return 0
end
MySQL.query.await = function(sql, params)
    local out = {}
    for cid, o in pairs(officers) do
        local r = {
            citizenid = cid,
            display_name = o.display_name,
            department = o.department,
            field_training = o.field_training,
        }
        if sql:find('JSON_VALUE(field_training', 1, true) then
            local t = o.field_training and json.decode(o.field_training)
            if t and t.trainer == params[1] then out[#out + 1] = r end
        elseif sql:find('WHERE department = ?', 1, true) then
            if o.department == params[1] then out[#out + 1] = r end
        end
    end
    table.sort(out, function(a, b) return a.citizenid < b.citizenid end)
    return out
end
CP.Migrations = {
    ready = function() return true end,
}
_G.GetPlayers = function()
    local out = {}
    for src in pairs(people) do out[#out + 1] = tostring(src) end
    return out
end

CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p then return nil end
        return { citizenid = p.cid, name = 'Officer ' .. src, job = { name = p.dept, gradeLevel = p.grade } }
    end,
    getByCitizenId = SrcOf,
}
CP.Access = {
    isAdmin = function(src) return src == 0 or (people[src] and people[src].admin == true) or false end,
    getOfficer = function(src)
        local p = people[src]
        if not p or not p.dept then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.cid,
            name = 'Officer ' .. src,
            department = p.dept,
            rank = 'Rank',
            isSupervisor = p.sup == true,
            gradeLevel = p.grade,
        }
    end,
    departmentForJob = function(job) return job end,
    licensesOfSrc = function(src) return people[src] and { people[src].license } or {} end,
    licenseOf = function(cid)
        local s = SrcOf(cid)
        return s and people[s].license or nil
    end,
}
CP.Permissions = {
    can = function(src, _, ctx)
        local p = people[src]
        if not p then return false, 'err.no_permission' end
        if p.admin then return true end
        if not p.sup then return false, 'err.no_permission' end
        if ctx and ctx.department and ctx.department ~= p.dept then return false, 'err.other_department' end
        return true
    end,
}
CP.Admin = {
    auditSync = function(actor, role, _, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            role = role,
            action = action,
            target = target,
            old = old,
            new = new,
            reason = reason,
        }
        return #audits
    end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars)
        toasts[#toasts + 1] = { src = src, kind = kind, key = key, vars = vars }
        return true
    end,
}

for _, m in ipairs({ 'modules/adminkit/server.lua', 'modules/fieldtraining/server.lua' }) do H.load(m) end
local Kit, FT = CP.AdminKit, CP.FieldTraining
local FTC = Config.FieldTraining

local function Pair(src, rookie, trainer)
    return Kit.run('server:sup:ftoPair', src, { rookie = rookie, trainer = trainer })
end
local function Record(cid)
    local t = officers[cid].field_training
    return t and json.decode(t) or nil
end
-- A completed run of missionType: the rookie's row settles; the trainer finished it too unless trainerResult says so.
local function Run(rookieSrc, missionType, trainerResult, extra)
    local rp = { citizenid = people[rookieSrc].cid, result = 'completed' }
    local tp = { citizenid = 'FT_TRN03', result = trainerResult or 'completed' }
    local run = { id = 'run-x', missionType = missionType, participants = { [rookieSrc] = rp, [3] = tp } }
    local row = { state = 'completed', flagged = 0 }
    for k, v in pairs(extra or {}) do row[k] = v end
    return FT.onRowSettled(run, rp, 1, row)
end
local function Toasts(key)
    local n = 0
    for _, t in ipairs(toasts) do if t.key == key then n = n + 1 end end
    return n
end

-- ============================================================================
--                        SHIPPED CONFIG: NOTHING MOVES
-- ============================================================================

H.ok(FTC.enabled == false and FTC.rookiesPerTrainer == 2 and FTC.badge == 'field_training', 'ships off')
H.ok(FTC.tasks.patrol == 3 and FTC.tasks.investigation == 2 and FTC.tasks.tactical == 1, 'with three tasks')
local ok, err = Pair(2, 'FT_ROO04', 'FT_TRN03')
H.eq(err, 'err.fto_off', 'off: pairing is refused')
H.eq(Run(4, 'patrol'), false, 'off: a run counts for nothing')
H.eq(FT.mine(3), nil, 'off: the Profile shows nothing')
H.eq(select(2, FT.signOff(3, { rookie = 'FT_ROO04', task = 'patrol' })), 'err.fto_off', 'off: no sign-off')
H.eq(#audits + #badges, 0, 'no audit and no badge')

-- ============================================================================
--                                   PAIRING
-- ============================================================================

FTC.enabled = true
FTC.tasks = { patrol = 2, tactical = 1 }
ok, err = Pair(4, 'FT_ROO07', 'FT_TRN03')
H.eq(err, 'err.no_permission', 'an officer may not pair')
ok, err = Pair(6, 'FT_ROO04', 'FT_TRN03')
H.eq(err, 'err.no_permission', 'a FIB officer may not pair SAST officers')
ok, err = Pair(2, 'FT_ROO04', 'FT_ROO04')
H.eq(err, 'err.fto_same_officer', 'never the same officer')
ok, err = Pair(2, 'FT_ROO04', 'FT_LOW05')
H.eq(err, 'err.fto_trainer_grade', 'a trainer below the trainer grade (sast = 2) is refused')
ok, err = Pair(2, 'FT_ROO04', 'FT_FIB06')
H.eq(err, 'err.other_department', 'a trainer of another department is refused')
ok, err = Pair(2, 'FT_ROO04', 'FT_NOBODY')
H.eq(err, 'err.fto_trainer_offline', 'the trainer must be online')
ok, err = Pair(2, 'FT_SUP02', 'FT_TRN03')
H.eq(err, 'err.self_target', 'a supervisor never pairs his own character as the rookie')
local view
ok, view = Pair(2, 'FT_ROO04', 'FT_TRN03')
H.ok(ok == true and view.trainer.citizenid == 'FT_TRN03' and view.total == 2 and view.signed == 0, 'paired')
local rec = Record('FT_ROO04')
H.ok(rec and rec.trainer == 'FT_TRN03' and rec.dept == 'sast' and rec.by == 'FT_SUP02', 'saved on the rookie row')
H.ok(
    audits[#audits].action == 'ftoPair' and audits[#audits].role == 'supervisor'
        and audits[#audits].target == 'FT_ROO04' and audits[#audits].new == 'FT_TRN03',
    'audited as ftoPair'
)
H.ok(Toasts('fto.toast.paired_rookie') == 1 and Toasts('fto.toast.paired_trainer') == 1, 'both are told')
ok, err = Pair(2, 'FT_ROO04', 'FT_SUP02')
H.eq(err, 'err.fto_already_paired', 'a rookie has one trainer')
ok, err = Pair(2, 'FT_TRN03', 'FT_SUP02')
H.eq(ok, true, 'a trainer may be paired as a rookie of someone else')
ok, err = Pair(2, 'FT_ROO07', 'FT_TRN03')
H.eq(err, 'err.fto_trainer_in_training', 'but then he trains nobody new')
ok = Kit.run('server:sup:ftoUnpair', 2, { rookie = 'FT_TRN03' })
H.ok(ok == true and officers.FT_TRN03.field_training == nil, 'End training clears the record')
H.eq(audits[#audits].action, 'ftoUnpair', 'audited as ftoUnpair')
ok = Pair(1, 'FT_ROO07', 'FT_TRN03')
H.eq(ok, true, 'an admin pairs too (the second rookie)')
ok, err = Pair(2, 'FT_OFF09', 'FT_TRN03')
H.eq(err, 'err.fto_trainer_full', 'rookiesPerTrainer (2) is the limit')

-- ============================================================================
--                               RUNS THAT COUNT
-- ============================================================================

H.eq(Run(4, 'patrol', 'abandoned'), false, 'the trainer left the run: it does not count')
H.eq(Run(4, 'patrol', nil, { flagged = 1 }), false, 'a flagged row does not count')
H.eq(Run(4, 'patrol', nil, { state = 'failed' }), false, 'a failed run does not count')
H.eq(Run(4, 'investigation'), false, 'a type with no task does not count')
H.eq(Run(4, 'patrol'), true, 'a completed run with the trainer counts')
H.eq(Run(4, 'patrol'), true, 'the second one too')
H.eq(Run(4, 'patrol'), false, 'never above the task count')
H.eq(Record('FT_ROO04').tasks.patrol.runs, 2, 'patrol 2 of 2')
H.eq(Toasts('fto.toast.ready'), 1, 'the trainer is told the task is ready')
do
    local rp, tp = { citizenid = 'FT_ROO07', result = 'completed' }, { citizenid = 'FT_TRN03', result = 'completed' }
    CP.Hooks.fire('row:settled', { missionType = 'tactical', participants = { [7] = rp, [3] = tp } }, rp, 1,
        { state = 'completed', flagged = 0 })
    H.eq(Record('FT_ROO07').tasks.tactical.runs, 1, 'the row:settled hook counts the run (CP.Runs settles rows)')
end

-- ============================================================================
--                                   SIGN-OFF
-- ============================================================================

-- step G3: the feature rewards it asks for (CP.FeatureRewards, its own spec pays them)
local frPaid = {}
CP.FeatureRewards = {
    payLater = function(feature, cid, opts) frPaid[#frPaid + 1] = { feature = feature, cid = cid, key = opts.key } end,
}

ok, err = FT.signOff(2, { rookie = 'FT_ROO04', task = 'patrol' })
H.eq(err, 'err.fto_not_trainer', 'only his own trainer signs off (not a supervisor)')
ok, err = FT.signOff(3, { rookie = 'FT_ROO04', task = 'tactical' })
H.eq(err, 'err.fto_task_not_ready', 'a task whose count is not reached')
ok, err = FT.signOff(3, { rookie = 'FT_ROO04', task = 'boat' })
H.eq(err, 'err.fto_task_unknown', 'an unknown task')
ok, view = FT.signOff(3, { rookie = 'FT_ROO04', task = 'patrol', note = 'Solid traffic stops' })
H.ok(ok == true and view.signed == 1 and view.tasks[1].signed.note == 'Solid traffic stops', 'signed off with a note')
H.ok(
    audits[#audits].action == 'ftoSignOff' and audits[#audits].new == 'patrol'
        and audits[#audits].reason == 'Solid traffic stops',
    'audited as ftoSignOff'
)
ok, err = FT.signOff(3, { rookie = 'FT_ROO04', task = 'patrol' })
H.eq(err, 'err.fto_task_signed', 'never twice')
H.eq(#badges, 0, 'no badge before the last task')
local mine = FT.mine(3)
H.ok(mine and #mine.rookies == 2 and mine.training == nil, 'the trainer\'s Profile lists his rookies')
H.ok(FT.mine(4).training.tasks[1].signed ~= nil, 'the rookie\'s Profile shows the sign-off')
H.eq(Run(4, 'tactical'), true, 'the tactical run')
ok, view = FT.signOff(3, { rookie = 'FT_ROO04', task = 'tactical' })
H.ok(ok == true and view.doneAt ~= nil, 'the last task: training done')
H.ok(badges[1] and badges[1].citizenid == 'FT_ROO04' and badges[1].badge == 'field_training', 'the badge is given')
H.ok(
    #frPaid == 3 and frPaid[1].feature == 'ftoSignOff' and frPaid[1].cid == 'FT_TRN03'
        and frPaid[1].key == 'fto:FT_ROO04:patrol',
    'G3: the trainer is paid per sign-off, once per rookie and task'
)
H.ok(
    frPaid[3] and frPaid[3].feature == 'ftoComplete' and frPaid[3].cid == 'FT_ROO04'
        and frPaid[3].key == 'fto:FT_ROO04:done',
    'G3: the rookie is paid once when his training is done'
)
H.eq(Toasts('fto.toast.done'), 1, 'the rookie is told')
H.eq(Run(4, 'patrol'), false, 'a finished training counts nothing more')
H.eq(#FT.mine(3).rookies, 1, 'and frees the trainer\'s place')

-- the supervisor's view
local d = FT.deptView(2, 'sast')
H.ok(d and #d.pairs == 2 and d.trainerGrade == 2, 'Department Report lists the pairings')
local trainerListed = false
for _, t in ipairs(d.trainers) do if t.citizenid == 'FT_TRN03' then trainerListed = true end end
H.ok(trainerListed, 'and the online trainers')
H.eq(select(2, FT.deptView(2, 'fib')), 'err.other_department', 'never another department')
H.eq(select(2, FT.deptView(3, 'sast')), 'err.no_permission', 'never an officer')

-- ============================================================================
--                  STEP T2: THE RIDE-ALONG RULE AND THE BONUS
-- ============================================================================

H.ok(type(FTC.requireTrainerFor) == 'table' and next(FTC.requireTrainerFor) == nil and FTC.trainerBonus == 0,
    'T2 ships with no ride-along rule and no trainer bonus')
local rookie7, trainer3, other5 = { citizenid = 'FT_ROO07' }, { citizenid = 'FT_TRN03' }, { citizenid = 'FT_LOW05' }
H.eq(FT.unitCheck({ rookie7 }, 'tactical'), true, 'an empty rule: a rookie takes any type alone')
FTC.requireTrainerFor = { 'tactical' }
local okU, errU, who = FT.unitCheck({ rookie7, other5 }, 'tactical')
H.ok(okU == false and errU == 'err.fto_trainer_needed' and who == 'FT_ROO07', 'a listed type without the trainer')
H.eq(FT.unitCheck({ other5, rookie7, trainer3 }, 'tactical'), true, 'with his trainer in the unit')
H.eq(FT.unitCheck({ rookie7 }, 'patrol'), true, 'a type not listed')
H.eq(FT.unitCheck({ { citizenid = 'FT_ROO04' } }, 'tactical'), true, 'a finished training is free')
FTC.requireTrainerFor = { tactical = true }
H.eq(FT.unitCheck({ rookie7 }, 'tactical'), false, 'a { type = true } map works too')
local m7 = FT.mine(7)
H.ok(m7 and m7.training and m7.training.needsTrainer[1] == Config.MissionTypes.tactical.label,
    'the rookie\'s card lists the ride-along types')
-- step F3: the same rule for a rookie who joins a live case as backup (CP.Runs.addParticipant)
local okJ, errJ = FT.joinCheck('FT_ROO07', { 'FT_LOW05' }, 'tactical')
H.ok(okJ == false and errJ == 'err.fto_trainer_needed', 'F3: a rookie joins a listed type only with his trainer on it')
H.eq(FT.joinCheck('FT_ROO07', { 'FT_LOW05', 'FT_TRN03' }, 'tactical'), true, 'F3: his trainer is on the case')
H.eq(FT.joinCheck('FT_ROO07', {}, 'patrol'), true, 'F3: a type not listed')
H.eq(FT.joinCheck('FT_LOW05', {}, 'tactical'), true, 'F3: an officer not in training')
FTC.enabled = false
H.eq(FT.unitCheck({ rookie7 }, 'tactical'), true, 'off: no rule')
H.eq(FT.joinCheck('FT_ROO07', {}, 'tactical'), true, 'F3 off: no rule for a backup either')
FTC.enabled = true
FTC.requireTrainerFor = {}
H.eq(FT.joinCheck('FT_ROO07', {}, 'tactical'), true, 'F3: an empty rule')

local bonusRows = {}
CP.Scoring = {
    _insertBonusRow = function(cid, kind, missionId, points, label, extra)
        bonusRows[#bonusRows + 1] = { cid = cid, kind = kind, missionId = missionId, points = points, extra = extra }
        return #bonusRows
    end,
}
FTC.tasks = { patrol = 2, tactical = 1 }
ok = FT.signOff(3, { rookie = 'FT_ROO07', task = 'tactical' })
H.ok(ok == true and #bonusRows == 0, 'trainerBonus 0: no points row')
H.eq(FT.mine(3).trainerBonus, 0, 'and the card shows no bonus')
FTC.trainerBonus = 25
H.eq(Run(7, 'patrol'), true, 'a patrol run')
H.eq(Run(7, 'patrol'), true, 'and another')
ok = FT.signOff(3, { rookie = 'FT_ROO07', task = 'patrol' })
local b = bonusRows[1]
H.ok(
    ok == true and b and b.cid == 'FT_TRN03' and b.points == 25 and b.kind == 'manual_award'
        and b.missionId == 'fto_bonus',
    'trainerBonus: 25 points to the trainer per signed task'
)
H.ok(Toasts('fto.toast.bonus') == 1, 'the trainer is told')
FTC.trainerBonus = 99999
H.eq(FT.trainerBonus(), 1000, 'the bonus is capped at 1000')
FTC.trainerBonus = 0

-- ============================================================================
--             STEP F3: THE BADGE IN THE ADMIN UI GRANT/REVOKE LIST
-- ============================================================================

for _, k in ipairs({ 'onDutyChange', 'onJobChange', 'onPlayerLoaded', 'onPlayerUnload' }) do
    CP.Qbx[k] = CP.Qbx[k] or function() end
end
H.load('modules/scoring/server.lua')
local function Listed()
    for _, a in ipairs(CP.Scoring.badgeCatalog().achievements) do
        if a.id == 'field_training' then return a end
    end
    return nil
end
local a = Listed()
H.ok(a ~= nil and a.label == 'Field Training', 'F3: the field training badge is in the grant/revoke list')
H.eq(CP.Scoring.validBadgeId('field_training'), true, 'F3: an admin may grant or revoke it')
FTC.enabled = false
H.eq(Listed(), nil, 'F3: field training off: not listed')
H.eq(CP.Scoring.validBadgeId('field_training'), false, 'F3: off: not a badge an admin may grant')
FTC.enabled = true

return H
