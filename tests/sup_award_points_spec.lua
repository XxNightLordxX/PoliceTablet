-- A supervisor gives points (step P22, the awardPoints Mission control, owner decision 2026-10-19): only through the
-- admin's point-adjust path (CP.Corrections.adjust), inside the admin's min and max and awardPointsPerDay, to an
-- officer of his own department, never to a character of his own license, with a reason, audited as 'supervisor'.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

-- src -> { cid, license, dept, sup, admin, grade }
local people = {
    [1] = { cid = 'AP_ADMIN', license = 'license:a1', dept = 'sast', sup = true, admin = true, grade = 6 },
    [2] = { cid = 'AP_SUP02', license = 'license:s2', dept = 'sast', sup = true, grade = 4 },
    [3] = { cid = 'AP_OFF03', license = 'license:o3', dept = 'sast', grade = 1 },
    [4] = { cid = 'AP_FIB04', license = 'license:f4', dept = 'fib', grade = 1 },
    [5] = { cid = 'AP_SUP05', license = 'license:s5', dept = 'sast', sup = true, grade = 4 },
}
-- offline officers: citizenid -> department (cp_officers)
local offline = { AP_ALT02 = 'sast', AP_OFF06 = 'sast' }
local licenses = { AP_ALT02 = 'license:s2', AP_OFF06 = 'license:o6' }
for src, p in pairs(people) do
    H.players[src] = { ace = {}, coords = vec3(0.0, 0.0, 0.0) }
    licenses[p.cid] = p.license
end
local function SrcOf(cid)
    for src, p in pairs(people) do if p.cid == cid then return src end end
    return nil
end
local function DeptOfCid(cid)
    local s = SrcOf(cid)
    return s and people[s].dept or offline[cid]
end

local rows, audits = {}, {}      -- manual award rows (Scoring.adjust), audit rows (CP.Admin.auditSync)
MySQL.insert.await = function() return 1 end
MySQL.update.await = function() return 1 end
MySQL.scalar.await = function(sql, params)
    if sql:find('SELECT department FROM cp_officers', 1, true) then return offline[params[1]] end
    return 0
end
MySQL.single.await = function(sql, params)
    if sql:find('FROM cp_officers WHERE citizenid', 1, true) then
        local cid = params[1]
        local dept = DeptOfCid(cid)
        if not dept then return nil end
        return { citizenid = cid, department = dept, xp = 1000, license = licenses[cid] }
    end
    return nil
end
-- Kit.dailySum: today's manual award rows whose breakdown.by is one of the actors (the trailing params)
MySQL.query.await = function(sql, params)
    if not sql:find('mission_type = \'manual_award\'', 1, true) then return {} end
    local actors = {}
    for i = 3, #params do actors[params[i]] = true end
    local out = {}
    for _, r in ipairs(rows) do
        if (r.missionId == params[1] or r.missionId == params[2]) and actors[r.by] then
            out[#out + 1] = { v = r.points }
        end
    end
    return out
end
CP.Migrations = {
    ready = function() return true end,
}

CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p then return nil end
        return { citizenid = p.cid, name = 'P ' .. src, job = { name = p.dept, gradeLevel = p.grade } }
    end,
    getByCitizenId = SrcOf,
}
CP.Access = {
    isAdmin = function(src) return src == 0 or (people[src] and people[src].admin == true) or false end,
    getOfficer = function(src)
        local p = people[src]
        if not p then return nil, 'err.not_police' end
        return { src = src, citizenid = p.cid, department = p.dept, isSupervisor = p.sup == true, gradeLevel = p.grade }
    end,
    departmentForJob = function(job) return job end,
    licensesOfSrc = function(src) return people[src] and { people[src].license } or {} end,
    licenseOf = function(cid) return licenses[cid] end,
    selfCitizenids = function(src)
        local out = {}
        for cid, lic in pairs(licenses) do
            if people[src] and lic == people[src].license then out[#out + 1] = cid end
        end
        return out
    end,
}
CP.Permissions = {
    can = function(src, key)
        local p = people[src]
        if not p then return false, 'err.no_permission' end
        if p.admin then return true end
        if key == 'missionControls' and p.sup and Config.Permissions.supervisor.missionControls == true then
            return true
        end
        return false, 'err.no_permission'
    end,
    gradeGrant = function() return true end,
}
CP.Admin = {
    auditSync = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            role = role,
            category = category,
            action = action,
            target = target,
            new = new,
            reason = reason,
        }
        return #audits
    end,
}
CP.Scoring = {
    adjust = function(src, cid, n, reason)
        rows[#rows + 1] = {
            citizenid = cid,
            points = n,
            reason = reason,
            by = people[src] and people[src].cid or 'console',
            missionId = n > 0 and 'manual_award' or 'manual_adjust',
        }
        return #rows
    end,
}
CP.Leaderboard = { invalidate = function() end }

for _, m in ipairs({
    'modules/adminkit/server.lua',
    'modules/corrections/server.lua',
    'modules/deptcontrols/server.lua',
    'modules/supawards/server.lua',
}) do
    H.load(m)
end
local Kit, DC, SA = CP.AdminKit, CP.DeptControls, CP.SupAwards

local function Give(src, cid, points, extra)
    H.clockMs = (H.clockMs or 0) + 11000     -- one award per officer per 10 s (targetRate)
    local p = { citizenid = cid, points = points, reason = 'Great scene work' }
    for k, v in pairs(extra or {}) do p[k] = v end
    return Kit.run('server:sup:awardPoints', src, p)
end
local function Awards(action)
    local out = {}
    for _, a in ipairs(audits) do if a.action == action then out[#out + 1] = a end end
    return out
end

local MC = Config.MissionControls

-- ============================================================================
--                        SHIPPED CONFIG: NOTHING MOVES
-- ============================================================================

H.ok(MC.controls.awardPoints.on == false and MC.controls.awardPoints.min == 1 and MC.controls.awardPoints.max == 50,
    'ships off, 1-50 points an award')
H.eq(MC.awardPointsPerDay, 100, '100 points a supervisor a day')
H.eq(DC.def('awardPoints').kind, 'action', 'an action control')
H.eq(DC.def('awardPoints').master, true, 'under the master switch')
H.eq(DC.checkConfig({ awardPoints = MC.controls.awardPoints }), nil, 'the shipped bounds pass the config check')
H.eq(DC.checkConfig({ awardPoints = { on = true, min = 1, max = 20000 } }), 'err.control_config',
    'never above one admin adjustment (10000)')
local ok, err = Give(2, 'AP_OFF03', 10)
H.eq(ok, false, 'off as shipped: refused')
H.eq(SA.supView(2, 'AP_OFF03'), nil, 'and Department Report offers nothing')
MC.controls.awardPoints.on = true
ok, err = Give(2, 'AP_OFF03', 10)
H.eq(err, 'err.no_permission', 'the control on but the master switch off: still refused')
MC.controls.awardPoints.on = false
Config.Permissions.supervisor.missionControls = true
ok, err = Give(2, 'AP_OFF03', 10)
H.eq(err, 'err.control_off', 'the master switch on but the control off: refused')
H.eq(#rows + #audits, 0, 'no row and no audit')

-- ============================================================================
--                                  THE RULES
-- ============================================================================

MC.controls.awardPoints.on = true
local view = SA.supView(2, 'AP_OFF03')
H.ok(
    view and view.min == 1 and view.max == 50 and view.perDay == 100 and view.usedToday == 0
        and view.confirmAbove == 500,
    'switched on: Department Report offers it'
)
H.eq(SA.supView(2, 'AP_SUP02'), nil, 'never on his own character')
H.eq(SA.supView(2, 'AP_ALT02'), nil, 'nor another character of his license')
H.eq(SA.supView(2, 'AP_FIB04'), nil, 'nor an officer of another department')
H.eq(SA.supView(3, 'AP_OFF06'), nil, 'an officer is offered nothing')

ok, err = Give(2, 'AP_SUP02', 10)
H.eq(err, 'err.self_target', 'never himself')
ok, err = Give(2, 'AP_ALT02', 10)
H.eq(err, 'err.self_target', 'never another character on his license')
ok, err = Give(2, 'AP_FIB04', 10)
H.eq(err, 'err.other_department', 'never an FIB officer')
ok, err = Give(2, 'AP_OFF03', 51)
H.eq(err, 'err.award_points_range', 'never above the admin\'s max')
ok, err = Give(2, 'AP_OFF03', 0)
H.eq(err, 'err.award_points_range', 'never below the min')
ok, err = Give(2, 'AP_OFF03', -10)
H.eq(err, 'err.award_points_range', 'never a deduction')
ok, err = Give(2, 'AP_OFF03', 10, { reason = '' })
H.eq(err, 'err.reason_required', 'a reason is required')
ok, err = Give(3, 'AP_OFF06', 10)
H.eq(err, 'err.no_permission', 'an officer may not')
Config.AdminControl.pointAdjust = false
ok, err = Give(2, 'AP_OFF03', 10)
H.eq(err, 'err.award_off', 'AdminControl.pointAdjust off stops it too')
H.eq(SA.supView(2, 'AP_OFF03'), nil, 'and Department Report offers nothing then')
Config.AdminControl.pointAdjust = true
H.eq(#rows + #audits, 0, 'nothing refused wrote a row or an audit')

-- ============================================================================
--                         THE AWARD: THE ADMIN'S PATH
-- ============================================================================

local res
ok, res = Give(2, 'AP_OFF03', 30)
H.ok(ok == true and res.points == 30 and res.citizenid == 'AP_OFF03', 'a SAST officer gets 30 points')
H.ok(
    rows[1] and rows[1].missionId == 'manual_award' and rows[1].by == 'AP_SUP02'
        and rows[1].reason == 'Great scene work',
    'a manual award row like an admin\'s (who and why)'
)
local a = Awards('manualAward')[1]
H.ok(a and a.role == 'supervisor' and a.target == 'AP_OFF03' and a.new == '30' and a.reason == 'Great scene work',
    'audited as manualAward by a supervisor, with the reason')
ok, res = Give(2, 'AP_OFF06', 50)
H.eq(ok, true, 'an officer of his department who is offline (cp_officers)')
H.eq(SA.supView(2, 'AP_OFF03').usedToday, 80, 'the dialog counts today\'s points')
ok, err = Give(2, 'AP_OFF03', 21)
H.eq(err, 'err.award_daily_limit', 'over awardPointsPerDay (80 + 21 > 100)')
ok = Give(2, 'AP_OFF03', 20)
H.eq(ok, true, 'up to the limit')
ok = Give(5, 'AP_OFF03', 20)
H.eq(ok, true, 'another supervisor has his own limit')
Config.AdminControl.adjustDailyLimit = 30
ok, err = Give(5, 'AP_OFF03', 20)
H.eq(err, 'err.adjust_daily_limit', 'the admin\'s adjustDailyLimit applies too (the same path)')
Config.AdminControl.adjustDailyLimit = 0
MC.awardPointsPerDay = 0
ok = Give(2, 'AP_OFF03', 50)
H.eq(ok, true, 'awardPointsPerDay 0 = no limit')
H.eq(SA.supView(2, 'AP_OFF03').perDay, nil, 'and the dialog shows no count')
MC.awardPointsPerDay = 100
Config.Departments.sast.missionControls = { awardPoints = { max = 10 } }
ok, err = Give(5, 'AP_OFF06', 20)
H.eq(err, 'err.award_points_range', 'a department\'s own bounds win')
Config.Departments.sast.missionControls = nil
Config.AdminControl.adjustConfirmAbove = 40
ok, err = Give(5, 'AP_OFF06', 45)
H.eq(err, 'err.confirm_mismatch', 'at or above adjustConfirmAbove the citizenid is typed (the admin\'s guard)')
ok = Give(5, 'AP_OFF06', 45, { confirm = 'AP_OFF06' })
H.eq(ok, true, 'typed: given')
Config.AdminControl.adjustConfirmAbove = 500

-- an admin: no department or per-day rule; the self rule stays
ok = Give(1, 'AP_FIB04', 50)
H.eq(ok, true, 'an admin gives to any department')
H.eq(Awards('manualAward')[#Awards('manualAward')].role, 'admin', 'audited as admin')
ok, err = Give(1, 'AP_ADMIN', 5)
H.eq(err, 'err.self_target', 'an admin never to himself')

-- one path: Admin UI Give or take points and Give points both end in CP.Corrections.adjust
H.eq(Kit._actions()['server:admin:adjustPoints'].opts.confirm, CP.Corrections.adjustConfirm,
    'the admin tool keeps the same typed-confirmation guard')

MC.controls.awardPoints.on = false
Config.Permissions.supervisor.missionControls = false
return H
