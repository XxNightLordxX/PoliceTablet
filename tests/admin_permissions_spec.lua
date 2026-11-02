-- Admin full control, step G1 (the owner: "ensure the admin menu can have full control over every feature limit stuff

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================
-- Real: modules/permissions, admin, confighealth, settings, deptcontrols. Stand-ins: CP.Access (supervisor by
-- grade 4 of the department) and CP.Qbx (citizenid, job and gang of each player).

local people = {
    [1] = { cid = 'GRA00001', dept = 'sast', grade = 4 },                -- a supervisor
    [2] = { cid = 'GRO00002', dept = 'sast', grade = 2 },                -- an officer
    [3] = { cid = 'GRO00003', dept = 'sast', grade = 1 },                -- a junior officer
    [4] = { cid = 'GRF00004', dept = 'fib', grade = 2 },                 -- an officer of another department
    [5] = { cid = 'GRC00005', gang = 'ballas', gangGrade = 3 },          -- a gang member, not police
    [6] = { cid = 'GRC00006', gang = 'ballas', gangGrade = 1 },          -- a junior gang member
    [9] = { cid = 'GRA00009', dept = 'sast', grade = 0, admin = true },  -- an admin
}
CP.Access = {
    isAdmin = function(src) return src == 0 or (people[src] ~= nil and people[src].admin == true) end,
    getOfficer = function(src)
        local p = people[src]
        if not p or not p.dept then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.cid,
            department = p.dept,
            gradeLevel = p.grade,
            isSupervisor = p.grade >= 4,
        }
    end,
}
CP.Access.isSupervisor = function(src)
    local o = CP.Access.getOfficer(src)
    return o ~= nil and o.isSupervisor == true
end
CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p then return nil end
        return {
            src = src,
            citizenid = p.cid,
            name = 'Player ' .. src,
            job = { name = p.dept or 'unemployed', gradeLevel = p.grade or 0 },
            gang = { name = p.gang or 'none', gradeLevel = p.gangGrade or 0 },
        }
    end,
    getGangs = function() return { ballas = { label = 'Ballas', grades = { [0] = { name = 'Recruit' } } } } end,
}
CP.Tablet = { push = function() end }
CP.Runs = {
    all = function() return {} end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
H.load('modules/permissions/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/confighealth/server.lua')
H.load('modules/settings/server.lua')
H.load('modules/deptcontrols/server.lua')
H.step(0)
local S, P, DC, U = CP.Settings, CP.Permissions, CP.DeptControls, CP.U

local function Has(list, v)
    for _, x in ipairs(list or {}) do
        if x == v then return true end
    end
    return false
end

-- ============================================================================
--                    1. EVERY LIMIT HAS A RANGE IN SETTINGS
-- ============================================================================

do
    -- the caps, cooldowns and per-day counts an owner asked for, each with a min and a max in the editor
    for _, path in ipairs({
        'Limits.maxCompletionsHour',
        'Limits.maxCompletionsDay',
        'Limits.abandonCooldown',
        'Limits.startTimeout',
        'MissionCalls.maxOpen',
        'MissionCalls.staffCooldown',
        'Commendations.perSupervisorPerDay',
        'Commendations.sameKindCooldownDays',
        'Payouts.supervisorCooldown',
        'Cash.dailyCap',
        'Rewards.dailyItemCap',
        'Rewards.dailyValueCap',
        'CrossDept.cooldown',
        'Profile.reports.perDay',
        'Profile.avatarUrls.perDay',
        'AntiCheat.voidsToSuspend',
        'AntiCheat.suspendDays',
        'MissionTypes.patrol.points',
        'MissionTypes.tactical.payout',
        'Events.weeklyBoss.payout',
        'Builder.editLockMinutes',
        'Disputes.windowHours',
    }) do
        local e = S.entry(path)
        H.ok(e ~= nil and e.min ~= nil and e.max ~= nil and e.max >= e.default and e.min <= e.default,
            path .. ': a min and a max around its config.lua value')
    end
    -- every number of the limit sections has a max
    local prefixes = {
        'Limits.',
        'AdminControl.',
        'MissionControls.',
        'FieldTraining.',
        'Commendations.',
        'CrossDept.',
        'Volunteers.',
        'RealSuspects.',
        'LiveCrime.',
        'Cash.',
        'Payouts.',
        'Rewards.daily',
        'AntiCheat.',
        'Disputes.',
        'Units.',
    }
    local missing = {}
    for _, e in ipairs(S._schema().list) do
        for _, pre in ipairs(prefixes) do
            if e.kind == 'number' and e.path:sub(1, #pre) == pre and e.max == nil then
                missing[#missing + 1] = e.path
            end
        end
    end
    H.eq(table.concat(missing, ', '), '', 'every number of the limit sections has a range')
    local ok = S.check('Limits.maxCompletionsDay', 501)
    H.ok(not ok, 'a value past the range is refused')
    ok = S.check('Limits.maxCompletionsDay', 40)
    H.ok(ok, 'a value inside it is taken')
end

-- ============================================================================
--                     2. THE FEATURES TAB LINKS EACH LIMIT
-- ============================================================================

do
    local byKey = {}
    for _, f in ipairs(S.features()) do byKey[f.key] = f end
    for _, f in ipairs(S._features) do
        for _, lp in ipairs(f.limits or {}) do
            H.ok(S.entry(lp) ~= nil, f.key .. ': its limit ' .. lp .. ' is a setting')
        end
    end
    local mc = byKey.mission_controls
    H.ok(
        mc ~= nil and Has(mc.limits, 'MissionControls.missionBanPerDay')
            and Has(mc.limits, 'MissionControls.noticesPerDay') and Has(mc.limits, 'MissionControls.awardPointsPerDay'),
        'Mission controls link the ban, notice and points caps'
    )
    H.ok(byKey.field_training and Has(byKey.field_training.limits, 'FieldTraining.rookiesPerTrainer'),
        'field training links rookies per trainer')
    H.ok(byKey.item_rewards and Has(byKey.item_rewards.limits, 'Rewards.dailyValueCap'), 'item rewards link the caps')
    H.ok(byKey.volunteers and Has(byKey.volunteers.limits, 'Volunteers.strikes'), 'volunteers link the strikes')
    H.eq(byKey.flee and byKey.flee.limits, nil, 'a feature with no limits sends none')
end

-- ============================================================================
--                 3. SHIPPED: NO GRANT, TODAY'S RULES EXACTLY
-- ============================================================================

local keepPerms = U.deepcopy(Config.Permissions)

do
    H.ok(type(Config.Permissions.grants) == 'table' and next(Config.Permissions.grants) == nil, 'no grant ships')
    local e = S.entry('Permissions.grants')
    H.ok(e ~= nil and e.desc:find('Extra grants', 1, true) ~= nil,
        'the config.lua comment is its description: ' .. tostring(e and e.desc))
    for _, cap in ipairs(P.grantableKeys()) do
        for src = 2, 6 do H.eq(P.granted(src, cap), false, ('%s: nobody granted to %d'):format(cap, src)) end
    end
    H.ok(P.can(1, 'reviewFlagged', { department = 'sast' }), 'a supervisor reviews as before')
    H.ok(not P.can(2, 'reviewFlagged', { department = 'sast' }), 'an officer does not')
    H.ok(P.can(1, 'fieldTraining', { department = 'sast' }), 'a supervisor pairs field training as before')
    H.ok(not P.can(2, 'fieldTraining', { department = 'sast' }), 'an officer does not')
    H.eq(#P.actionsFor(2), 0, 'an officer has no supervisor actions')
    H.eq(#P.actionsFor(5), 0, 'nor a gang member')
    H.ok(Has(P.actionsFor(1), 'fieldTraining') and Has(P.actionsFor(1), 'viewMissionList'), 'a supervisor has both')
end

-- ============================================================================
--                 4. GRANTS BY DEPARTMENT, GANG AND CITIZENID
-- ============================================================================

do
    Config.Permissions.grants = {
        reviewFlagged = { departments = { sast = { minGrade = 2 } } },
        fieldTraining = { citizenids = { 'GRO00003' } },
        builderTeleport = { gangs = { ballas = { minGrade = 3 } } },
    }
    H.ok(P.granted(2, 'reviewFlagged'), 'sast grade 2: granted from grade 2')
    H.ok(not P.granted(3, 'reviewFlagged'), 'sast grade 1: below the grade')
    H.ok(not P.granted(4, 'reviewFlagged'), 'fib: another department')
    H.ok(P.can(2, 'reviewFlagged', { department = 'sast' }), 'the grant passes the review check')
    local ok, err = P.can(2, 'reviewFlagged', { department = 'fib' })
    H.ok(not ok and err == 'err.other_department', 'only for his own department')
    H.ok(not P.can(2, 'handleDisputes'), 'only the power granted')
    H.ok(P.can(3, 'fieldTraining', { department = 'sast' }), 'one citizenid: field training')
    H.ok(not P.can(2, 'fieldTraining', { department = 'sast' }), 'not another officer')
    H.ok(P.granted(5, 'builderTeleport'), 'a gang member from the gang grade')
    H.ok(not P.granted(6, 'builderTeleport'), 'not below it')
    H.eq(table.concat(P.actionsFor(2), ','), 'reviewFlagged', 'actionsFor lists the granted power')
    H.eq(table.concat(P.actionsFor(3), ','), 'fieldTraining', 'and the citizenid one')

    -- a power switched off stays off, grant or not
    Config.Permissions.supervisor.reviewFlagged = false
    H.ok(not P.can(2, 'reviewFlagged', { department = 'sast' }), 'switched off: the grant does not pass')
    H.eq(#P.actionsFor(2), 0, 'and is not listed')
    Config.Permissions.supervisor.reviewFlagged = true

    -- admin-only actions are never grantable, and a grant never makes an admin
    Config.Permissions.grants.bulkVoid = { citizenids = { 'GRO00002' } }
    Config.Permissions.grants.openAdmin = { citizenids = { 'GRO00002' } }
    H.ok(not P.isGrantable('bulkVoid') and not P.granted(2, 'bulkVoid'), 'bulkVoid is not grantable')
    H.ok(not P.can(2, 'bulkVoid'), 'and refused')
    H.ok(not P.can(2, 'openAdmin') and not CP.Access.isAdmin(2), 'a grant never opens the Admin UI')
    H.ok(not P.isGrantable('viewMissionList'), 'the department report is never granted')
    Config.Permissions = U.deepcopy(keepPerms)
end

-- ============================================================================
--           5. SETTINGS: SAVED, CHECKED AND AUDITED LIKE ANY SETTING
-- ============================================================================

do
    local good = {
        missionControls = {
            departments = { sast = { minGrade = 2 } },
            gangs = { ballas = { grades = { 3, 4 } } },
            citizenids = { 'ABC12345' },
        },
    }
    H.ok(S.check('Permissions.grants', good), 'a grant by department, gang and citizenid is valid')
    local ok, err = S.check('Permissions.grants', { bulkVoid = { citizenids = { 'ABC12345' } } })
    H.ok(not ok and err == 'err.setting_extra_grant_power', 'an admin-only action is refused: ' .. tostring(err))
    ok, err = S.check('Permissions.grants', { reviewFlagged = { departments = { nope = { minGrade = 2 } } } })
    H.ok(not ok and err == 'err.setting_extra_grant_department', 'an unknown department: ' .. tostring(err))
    ok, err = S.check('Permissions.grants', { reviewFlagged = { gangs = { ballas = {} } } })
    H.ok(not ok and err == 'err.setting_extra_grant_grade', 'a gang grant needs a grade: ' .. tostring(err))
    ok = S.check('Permissions.grants', { reviewFlagged = { citizenids = { 'bad id!' } } })
    H.ok(not ok, 'a citizenid is letters and numbers')
    local saved = S.set(0, 'Permissions.grants', good, false, { reason = 'G1 spec' })
    H.ok(saved, 'the console saves it')
    H.ok(P.granted(2, 'missionControls'), 'read live: the new grant counts at once')
    local r = H.callback('crimson-police:admin:getPermissions', 9)
    local extra = r and r.ok and r.data and r.data.extra or {}
    local keys = {}
    for _, pw in ipairs(extra.powers or {}) do keys[#keys + 1] = pw.key end
    H.ok(
        Has(keys, 'missionControls') and Has(keys, 'builderTeleport') and Has(keys, 'fieldTraining')
            and not Has(keys, 'bulkVoid'),
        'the Permissions screen lists the grantable powers: ' .. table.concat(keys, ',')
    )
    H.ok(extra.grants and extra.grants.missionControls ~= nil, 'and the saved grants')
    H.ok(extra.gangs and extra.gangs[1] and extra.gangs[1].key == 'ballas', 'and the Qbox gangs')
    S.reset(0, 'Permissions.grants', { reason = 'G1 spec' })
    H.ok(not P.granted(2, 'missionControls'), 'reset: back to no grant')
end

-- ============================================================================
--             6. MISSION CONTROLS: A GRANTED OFFICER CHANGES THEM
-- ============================================================================

do
    DC.register('g1_wait', {
        kind = 'number',
        integer = true,
        configValue = function() return 600 end,
    })
    Config.Permissions.supervisor.missionControls = true
    Config.MissionControls.controls = U.deepcopy(Config.MissionControls.controls)
    Config.MissionControls.controls.g1_wait = { on = true, min = 300, max = 900 }
    Config.MissionControls.grants = { sast = { minGrade = 4 } }
    H.ok(DC.canChange(1, 'g1_wait'), 'a supervisor may')
    H.ok(not DC.canChange(2, 'g1_wait'), 'an officer may not')
    Config.Permissions.grants = { missionControls = { departments = { sast = { minGrade = 2 } } } }
    local ok, _, role, dept = DC.canChange(2, 'g1_wait')
    H.ok(ok and role == 'supervisor' and dept == 'sast', 'granted: his own department, past the supervisor grade rule')
    H.ok(not DC.canChange(2, 'g1_wait', 'fib'), 'never another department')
    H.ok(not DC.canChange(3, 'g1_wait'), 'below the granted grade: no')
    Config.Permissions.supervisor.missionControls = false
    H.ok(not DC.canChange(2, 'g1_wait'), 'the master switch off: no')
    Config.Permissions = U.deepcopy(keepPerms)
end

return H
