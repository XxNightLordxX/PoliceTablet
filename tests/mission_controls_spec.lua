-- Mission controls core (step P1): CP.DeptControls (register, bounds, get, snapshot, set, reset, view), the six
-- callbacks and actions, the master switch, the grants, the change wait, the self rule and the audit. One test control
-- per department and one server-wide control outside the master switch. Runs in both storage modes.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

H.boot({ side = 'server', realLocale = true })

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/permissions, access, admin, adminkit, settings, tablet, deptcontrols. Stand-in: CP.Qbx.

local LIC2 = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2'
local people = {
    [1] = {
        cid = 'MCA00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [2] = { cid = 'MCS00002', license = LIC2, job = 'sast', grade = 4 },
    [3] = { cid = 'MCS00003', license = 'license:cccccccccccccccccccccccccccccccccccccc3', job = 'sast', grade = 3 },
    [4] = { cid = 'MCF00004', license = 'license:dddddddddddddddddddddddddddddddddddddd4', job = 'fib', grade = 4 },
    [5] = { cid = 'MCO00005', license = 'license:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee5', job = 'sast', grade = 0 },
}
local qboxLicense = { MCALT002 = LIC2 }   -- a second character of player 2 (Qbox's players table)
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
end

CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p then return nil end
        return {
            src = src,
            citizenid = p.cid,
            license = p.license,
            name = 'Player ' .. src,
            job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
        }
    end,
    getByCitizenId = function(cid)
        for src, p in pairs(people) do
            if p.cid == cid then return src end
        end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for src in pairs(people) do out[#out + 1] = src end
        table.sort(out)
        return out
    end,
    licenseOf = function(cid)
        for _, p in pairs(people) do
            if p.cid == cid then return p.license end
        end
        return qboxLicense[cid]
    end,
    citizenidsOfLicense = function(lic)
        local out = {}
        for cid, l in pairs(qboxLicense) do
            if l == lic then out[#out + 1] = cid end
        end
        return out
    end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}

for _, t in ipairs({ 'cp_audit', 'cp_settings', 'cp_admin_requests', 'cp_officers', 'cp_dept_controls' }) do
    H.sql('DELETE FROM ' .. t)
end

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/deptcontrols/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
}) do
    H.load(m)
end
H.step(0)

local DC, S, U = CP.DeptControls, CP.Settings, CP.U

local reqSeq = 0
local function Rid(n) return ('%08x-0000-4000-8000-%012x'):format(n, 91) end
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'm' .. reqSeq
    payload = payload or {}
    if payload.requestId == nil then payload.requestId = Rid(reqSeq) end
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end
local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end
local function SupSet(src, key, value, reason)
    return Act('server:sup:setMissionControl', src, { key = key, value = value, reason = reason or 'busy night' })
end
local function LastAudit()
    return H.sql(
        'SELECT actor, role, action, target, old_value, new_value, reason FROM cp_audit ORDER BY id DESC LIMIT 1')[1]
end
local function Wait(s) H.time = H.time + s end

-- the test controls: a per-department number (config 600; lower relaxes) and a server-wide one outside the master
local CONFIG_WAIT = 600
DC.register('t_wait', {
    kind = 'number',
    integer = true,
    configValue = function() return CONFIG_WAIT end,
    relaxes = function(v, c) return v < c end,
})
DC.register('t_global', {
    kind = 'number',
    serverWide = true,
    master = false,
    configValue = function() return 10 end,
})

local keepSup = U.deepcopy(Config.Permissions.supervisor)
local keepMC = U.deepcopy(Config.MissionControls)

-- ============================================================================
--                        1. SHIPPED: EVERYTHING IS OFF
-- ============================================================================

do
    H.eq(Config.Permissions.supervisor.missionControls, false, 'the master switch ships off')
    local shipped = {}
    for k in pairs(Config.MissionControls.controls) do shipped[#shipped + 1] = k end
    table.sort(shipped)
    H.eq(
        table.concat(shipped, ','),
        'abandonCooldown,addRunTime,boards,callLane,clearCooldown,cooldownScale,crossDept,dailyCap,difficulty,'
            .. 'featuredType,happyHour,happyHourCash,hourlyCap,idleCheck,missionBan,noRepeat,notices,readyCheck,reviewRules,'
            .. 'staffCallWait,startTimeout,timeLimit,twistCash,twists,typeOfTheDay,types,unitSize',
        'the cooldown controls (P2, P3, P6 happy hour, P7 clear), P7 + minutes, the P8 / P9 run controls, the P11'
            .. ' mission ban, the P12 call lane and staff call wait, the P13 notices and participation and the P14'
            .. ' boards and review rules, the P15 twists, the P16 cash bonuses and the P18 Type of the Day (off) ship'
    )
    H.eq(Config.MissionControls.controls.addRunTime.on, false, 'only the cooldown controls ship on')
    H.ok(next(Config.MissionControls.grants) == nil, 'no grant ships')
    H.eq(Config.MissionControls.changeWait, 300, 'change wait 300 s')
    H.eq(Config.MissionControls.selfExempt, true, 'the self rule ships on')
    local ok, err = SupSet(2, 't_wait', 400)
    H.ok(ok == false and err == 'err.no_permission',
        'shipped: a supervisor\'s change is refused (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:resetMissionControl', 2, { key = 't_wait', reason = 'x' })
    H.ok(ok == false and err == 'err.no_permission', 'and a reset')
    local r = Cb('sup:getMissionControls', 2)
    H.ok(r.ok == false and r.error == 'err.no_permission', 'and the view: ' .. cjson.encode(r))
    H.eq(DC.get('sast', 't_wait'), CONFIG_WAIT, 'get = the config value')
    ok, err = Act('server:admin:setMissionControl', 1,
        { department = 'sast', key = 't_wait', value = 400, reason = 'x' })
    H.ok(ok == false and err == 'err.control_off', 'an admin cannot save a change of a control that is off either')
    H.eq(#H.sql('SELECT department FROM cp_dept_controls'), 0, 'nothing saved')
end

-- ============================================================================
--              2. SWITCHED ON: BOUNDS, REASON, AUDIT, DEPARTMENTS
-- ============================================================================

Config.Permissions.supervisor.missionControls = true
Config.MissionControls.controls = { t_wait = { on = true, min = 300, max = 900 } }

do
    local ok, err = SupSet(2, 't_wait', 200)
    H.ok(ok == false and err == 'err.control_value', 'below min is refused')
    ok, err = SupSet(2, 't_wait', 1000)
    H.ok(ok == false and err == 'err.control_value', 'above max is refused')
    ok, err = SupSet(2, 't_wait', 450.5)
    H.ok(ok == false and err == 'err.control_value', 'a whole-number control takes whole numbers')
    ok, err = SupSet(2, 't_wait', 400, '   ')
    H.ok(ok == false and err == 'err.reason_required', 'a reason is required')
    ok, err = SupSet(5, 't_wait', 400)
    H.ok(ok == false and err == 'err.no_permission', 'an officer is refused')
    H.reset()
    ok, err = SupSet(2, 't_wait', 400, 'short staffed')
    H.ok(ok == true and err.value == 400 and err.department == 'sast', 'inside the bounds it is saved')
    local a = LastAudit()
    H.ok(
        a and a.role == 'supervisor' and a.action == 'missionControlSet' and a.target == 'sast:t_wait'
            and tostring(a.old_value) == '600' and tostring(a.new_value) == '400' and a.reason == 'short staffed',
        'audited with role supervisor, old, new and the reason: ' .. cjson.encode(a or {})
    )
    H.eq(DC.get('sast', 't_wait'), 400, 'SAST reads the change')
    H.eq(DC.get('fib', 't_wait'), CONFIG_WAIT, 'FIB is unchanged')
    local pushed = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:push')) do
        if e.args[1] == 'missionControls' then pushed[e.target] = true end
    end
    H.ok(pushed[1] and pushed[3] and not pushed[4] and not pushed[5],
        'pushed to the admins and SAST\'s supervisors only')
    local r = Cb('sup:getMissionControls', 3)
    local c = r.ok and r.data.departments[1].controls[1]
    H.ok(
        r.ok and #r.data.departments == 1 and r.data.departments[1].key == 'sast' and c.key == 't_wait'
            and c.value == 400 and c.configValue == 600 and c.min == 300 and c.max == 900 and c.setBy == 'MCS00002'
            and c.setRole == 'supervisor' and c.waitLeft > 0 and c.waitLeft <= 300,
        'the supervisor view: his department, value, config value, bounds, who, change wait left'
    )
    r = Cb('admin:getMissionControls', 1)
    H.ok(r.ok and #r.data.departments == 2, 'the admin view: every department')
    r = Cb('admin:getMissionControls', 2)
    H.ok(not r.ok, 'a supervisor never reads the admin view')
end

-- ============================================================================
--       3. CHANGE WAIT, BOUNDS NARROWED, DEPARTMENT OVERRIDE, SELF RULE
-- ============================================================================

do
    local ok, err = SupSet(3, 't_wait', 500)
    H.ok(ok == false and err == 'err.control_wait', 'a second change within the change wait is refused')
    Wait(301)
    ok = SupSet(3, 't_wait', 350)
    H.eq(ok, true, 'after the change wait it goes through')
    Config.MissionControls.controls.t_wait.min = 450
    H.eq(DC.get('sast', 't_wait'), 450, 'narrowing the bounds clamps the live value')
    Config.MissionControls.controls.t_wait.min = 300
    Config.Departments.sast.missionControls = { t_wait = { min = 500 } }
    H.eq(DC.get('sast', 't_wait'), 500, 'a department override bound wins')
    Wait(301)
    ok, err = SupSet(3, 't_wait', 400)
    H.ok(ok == false and err == 'err.control_value', 'and is what a supervisor may pick')
    Config.Departments.sast.missionControls = nil
    -- the self rule: player 3 set 350 (relaxes 600)
    H.eq(DC.get('sast', 't_wait', { citizenid = 'MCS00003' }), CONFIG_WAIT, 'the setter gets the config value')
    H.eq(DC.get('sast', 't_wait', { { citizenid = 'MCO00005' }, { citizenid = 'MCS00003' } }), CONFIG_WAIT,
        'and a unit he is in')
    H.eq(DC.get('sast', 't_wait', { citizenid = 'MCO00005' }), 350, 'another officer gets the change')
    Wait(301)
    H.eq(SupSet(2, 't_wait', 380), true, 'player 2 sets it')
    H.eq(DC.get('sast', 't_wait', { citizenid = 'MCALT002' }), CONFIG_WAIT,
        'any character of the setter\'s license gets the config value')
    Config.MissionControls.selfExempt = false
    H.eq(DC.get('sast', 't_wait', { citizenid = 'MCS00002' }), 380, 'selfExempt off: the setter gets it too')
    Config.MissionControls.selfExempt = true
    H.ok(DC.snapshot({ department = 'sast', citizenid = 'MCO00005' }).t_wait == nil,
        'a between control is not in the run snapshot')
end

-- ============================================================================
--              4. EXPIRY, RESET, ADMINS, OTHER DEPARTMENT, GRANTS
-- ============================================================================

do
    Wait(301)
    local res
    CreateThread(function() res = table.pack(DC.set(2, 't_wait', 420, 'tonight', { expiresAt = os.time() + 60 })) end)
    H.ok(res and res[1] == true, 'a change with an end time')
    H.eq(DC.get('sast', 't_wait'), 420, 'used until it ends')
    Wait(61)
    H.eq(DC.get('sast', 't_wait'), CONFIG_WAIT, 'an expired row is ignored')
    local ok, err = Act('server:sup:resetMissionControl', 4, { key = 't_wait', reason = 'x' })
    H.ok(ok == false and err == 'err.control_not_set', 'FIB has nothing to reset (his own department only)')
    ok, err = Act('server:admin:setMissionControl', 1,
        { department = 'fib', key = 't_wait', value = 1000, reason = 'x' })
    H.ok(ok == false and err == 'err.control_value', 'an admin stays inside the bounds')
    ok = Act('server:admin:setMissionControl', 1, { department = 'fib', key = 't_wait', value = 700, reason = 'event' })
    H.eq(ok, true, 'an admin changes any department')
    H.eq(LastAudit().role, 'admin', 'audited as admin')
    ok = Act('server:admin:setMissionControl', 1, { department = 'fib', key = 't_wait', value = 800, reason = 'again' })
    H.eq(ok, true, 'no change wait for an admin')
    H.eq(DC.get('fib', 't_wait'), 800, 'FIB reads it')
    ok, err = Act('server:sup:resetMissionControl', 2, { key = 't_wait', reason = '' })
    H.ok(ok == false and err == 'err.reason_required', 'a reset needs a reason')
    ok = Act('server:sup:resetMissionControl', 2, { key = 't_wait', reason = 'back to normal' })
    H.eq(ok, true, 'a supervisor resets his department')
    H.eq(#H.sql('SELECT department FROM cp_dept_controls WHERE department = \'sast\''), 0, 'the row is gone')
    H.eq(DC.get('fib', 't_wait'), 800, 'FIB keeps its change')
    ok = Act('server:admin:resetMissionControl', 1, { department = 'fib', key = 't_wait', reason = 'done' })
    H.eq(ok, true, 'an admin resets any department')
    H.eq(DC.get('fib', 't_wait'), CONFIG_WAIT, 'back to config')

    Wait(301)
    Config.MissionControls.grants = { sast = { minGrade = 4 } }
    ok, err = SupSet(3, 't_wait', 400)
    H.ok(ok == false and err == 'err.no_permission', 'a grant minGrade 4: a grade 3 supervisor is refused')
    H.eq(SupSet(2, 't_wait', 400), true, 'grade 4 may')
    Config.MissionControls.grants = {}

    -- the server-wide control: outside the master switch, one value for every department
    Config.MissionControls.controls.t_global = { on = true, min = 0, max = 20 }
    Config.Permissions.supervisor.missionControls = false
    H.eq(DC.get('sast', 't_wait'), CONFIG_WAIT, 'master switch off again: config values')
    ok, err = SupSet(2, 't_wait', 450)
    H.ok(ok == false and err == 'err.no_permission', 'and a supervisor cannot change a control under it')
    ok = SupSet(4, 't_global', 5)
    H.eq(ok, true, 'a control outside the master switch: a FIB supervisor changes it')
    H.ok(DC.get('sast', 't_global') == 5 and DC.get('fib', 't_global') == 5, 'for every department')
    H.eq(#H.sql('SELECT department FROM cp_dept_controls WHERE department = \'*\''), 1, 'saved once, under *')
    Config.MissionControls.controls.t_global.on = false
    H.eq(DC.get('fib', 't_global'), 10, 'its own switch off: the config value')
end

-- ============================================================================
--                         5. CONFIG CHECKS (SETTINGS)
-- ============================================================================

do
    H.eq(DC.checkConfig({ t_wait = { on = true, min = 5, max = 1 } }), 'err.control_config', 'min above max')
    H.eq(DC.checkConfig({ nope = { on = true } }), 'err.control_config', 'an unknown control')
    H.eq(DC.checkConfig({ t_wait = { on = true, min = 1, max = 5 } }), nil, 'a good one')
    H.eq(S.checkDepartments('Departments.sast.missionControls', { nope = { on = true } }), 'err.control_config',
        'a department\'s missionControls: registered controls only')
    H.eq(S.checkDepartments('Departments.sast.missionControls', { t_wait = { min = 400 } }), nil,
        'a good department override')
end

-- ============================================================================
--                              6. THE ADMIN VIEW
-- ============================================================================
-- STEP P4: ADMIN UI -> PERMISSIONS CARD.

do
    Config.Permissions.supervisor.missionControls = true
    Config.MissionControls.controls = { t_wait = { on = true, min = 300, max = 900 }, t_global = { on = false } }
    Config.Departments.sast.missionControls = { t_wait = { min = 500 } }
    DC.clearCache()
    local r = Cb('admin:getMissionControls', 1)
    local sast, fib
    for _, d in ipairs(r.ok and r.data.departments or {}) do
        if d.key == 'sast' then sast = d elseif d.key == 'fib' then fib = d end
    end
    H.ok(
        r.ok and r.data.bounds.t_wait.min == 300 and r.data.bounds.t_wait.max == 900
            and r.data.bounds.t_global.on == false,
        'the admin view: the shared switches and bounds as saved: ' .. cjson.encode(r.data and r.data.bounds or {})
    )
    H.ok(
        sast and sast.controls[1].own.min == 500 and sast.controls[1].min == 500
            and sast.boundsPath == 'Departments.sast.missionControls' and fib and fib.controls[1].own == nil,
        'each department: its own bounds and the setting they are saved in'
    )
    H.ok(r.data.serverWide[1].own == nil and r.data.serverWide[1].key == 't_global',
        'a server-wide control has no department bounds')
    local sv = Cb('sup:getMissionControls', 2)
    H.ok(sv.ok and sv.data.bounds == nil and sv.data.departments[1].boundsPath == nil,
        'a supervisor\'s view carries neither')
end

-- ============================================================================
--                  7. THE SUPERVISOR UI SCREEN (SESSION FLAG)
-- ============================================================================
-- STEP P5: session.config.missionControls shows the Mission controls screen while the player may change a control.

do
    local function Flag(src)
        local r = Cb('getSession', src, { ui = 'supervisor', silent = true })
        return r.ok and r.data.config.missionControls
    end
    Config.Permissions.supervisor.missionControls = false
    Config.MissionControls.controls = { t_wait = { on = true, min = 300, max = 900 }, t_global = { on = true } }
    H.ok(DC.available(2) and Flag(2) == true, 'master off, a control outside it on: the screen shows')
    H.ok(not DC.available(5) and Flag(5) == false, 'never for an officer')
    Config.MissionControls.controls.t_global.on = false
    H.ok(not DC.available(2) and Flag(2) == false, 'nothing a supervisor may change: hidden')
    Config.Permissions.supervisor.missionControls = true
    H.ok(DC.available(2) and Flag(2) == true, 'the master switch and a control under it: shown')
    Config.MissionControls.grants = { sast = { minGrade = 4 } }
    H.ok(DC.available(2) and not DC.available(3), 'a grant leaves out a grade 3 supervisor')
    Config.MissionControls.grants = {}
end

-- Step P10: a choice control with no list field (featuredType) offers every name its choices function gives.
do
    Config.Permissions.supervisor.missionControls = true
    H.eq(DC.register('t_pick', {
        kind = 'choice',
        choices = function() return { 'a', 'b' } end,
        configValue = function() return nil end,
    }), true, 'a choice control without a list registers')
    Config.MissionControls.controls = { t_pick = { on = true } }
    local row
    for _, c in ipairs(DC.view(2).departments[1].controls) do if c.key == 't_pick' then row = c end end
    H.eq(row and table.concat(row.offered, ','), 'a,b', 'no list: every choice is offered')
    local ok, err = SupSet(2, 't_pick', 'c')
    H.ok(ok == false and err == 'err.control_value', 'a name its choices do not give is refused')
    DC.unregister('t_pick')
end

Config.Permissions.supervisor = keepSup
Config.MissionControls = keepMC
Config.Departments.sast.missionControls = nil
DC.unregister('t_wait')
DC.unregister('t_global')
H.sql('DELETE FROM cp_dept_controls')

return H
