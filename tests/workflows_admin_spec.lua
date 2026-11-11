-- WF5C: every admin workflow, extensively (the owner: "do extensive workflow testing on everything").

-- WF5C: every admin workflow, extensively (the owner: "do extensive workflow testing on everything").
-- Every workflow and every action of the Admin UI's groups, driven start to finish on the REAL server side of
-- Crimson-Police: the world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the
-- owner's scripts running, database off: the saves folder, as shipped), booted on the shipped config with no section
-- of that spec run (CP_WF_WORLD). Each part runs on the shipped config first, then with the switches on through the
-- Admin UI's own Settings action, with a `restart Crimson-Police` and a player drop and reconnect in the middle, and
-- every refusal an admin screen meets (no permission, a supervisor, wrong department, caps reached, a feature off, the
-- maintenance lock). docs/dev/WORKFLOWS.md lists each workflow with its section here.
--   1. Opening the Admin UI, Home (the dashboard, its queues and shortcuts) and the officer search.
--   2. People: an officer's page, departments (add, off and on, rename, delete), desks, permissions and extra grants.
--   3. Missions: the mission and location switches, the Mission Builder (create, test, publish, edit a built-in,
--      reset it), map markers and extra parts with their rules, the testing tools.
--   4. Money: pay rates, rewards, the payments rows and their actions, department funds, the money tools (ENABLE).
--   5. Review: flagged runs, disputes, corrections, restrictions, the audit log and its export.
--   6. System: Settings (one setting, reset, revert, history), presets with their preview, storage, backups and
--      restore, the jobs screen, problems and the first-start setup.
--   7. The maintenance lock: every admin change refused while it holds, the screens still read.

_G.CP_WF_WORLD = 'admin'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Cb, Act, Secs, Place, Setting = W.Cb, W.Act, W.Secs, W.Place, W.Setting
local cjson = require('cjson')

-- A second admin by his Qbox admin group (Config.QboxAdmins), a SAST cadet.
W.AddPlayer(8, 'WFADMQB8', 'Quinn', 'Boxer', 'unemployed', 0)
W.AddPlayer(9, 'WFADMCA9', 'Eve', 'Cadet', 'sast', 0)
for _, src in ipairs({ 8, 9 }) do
    CID[src] = PD[src].citizenid
    H.players[src].coords = vec3(0.0, 0.0, 0.0)
    W.Reconnect(src)
end
H.players[8].ace.admin = true

local AT = vec3(-300.0, -1400.0, 30.0)
for src = 1, 9 do Place(src, vec3(AT.x + src * 2.0, AT.y, AT.z)) end

local function Later() H.time = H.time + 3700 end
local function Open(src, args)
    args = args or {}
    args.ui = args.ui or 'officer'
    args.via = args.via or 'command'
    return Cb('getSession', src, args)
end
local function Count(sql, params) return W.Count(sql, params) end
local function Audits(action) return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action }) end
local function RequestId() return W.RequestId() end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
    if CP.Units.unitOf(src) then Act('server:teamLeave', src) end
end
-- Beat Patrol alone, the others of its type off (the board draws it), played to its end by the full walk's helpers.
local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
-- Gang Shootout alone of the tactical missions (a unit of two may take it; Beat Patrol is for one officer).
local TACTICAL_OTHERS = {
    'hostage_rescue',
    'bomb_disposal',
    'armored_truck_escort',
    'prison_break',
    'drug_lab_raid',
    'gang_hideout_raid',
}
-- The board draws typeKey for src with the missions of `disabled` off for this one draw only, on top of the
-- missions the admin switched off (Config.DisabledMissions is the mission switch: it is put back as it was).
local function Draw(src, typeKey, disabled)
    Later()
    local saved = Config.DisabledMissions
    local list = {}
    for _, id in ipairs(saved or {}) do list[#list + 1] = id end
    for _, id in ipairs(disabled or {}) do list[#list + 1] = id end
    Config.DisabledMissions = list
    local ok, data = Act('server:acceptType', src, typeKey)
    Config.DisabledMissions = saved
    return ok, data, CP.Runs.getBySrc(src)
end
-- Beat Patrol played to its end (the other patrols off for the draw).
local function Patrol(src)
    local ok, _, run = Draw(src, 'patrol', PATROL_OTHERS)
    if not ok or not run then return nil end
    local veh = W.TakeWheel(src, run)
    W.DriveCheckpoints(src, run, veh)
    Secs(5)
    return run
end
local function LastRow(cid)
    local rows = W.Rows('citizenid = ?', { cid })
    return rows[#rows]
end

-- ============================================================================
--                 1. THE ADMIN UI, HOME, SHORTCUTS AND SEARCH
-- ============================================================================

do
    H.eq(Config.Database.enabled, false, 'shipped: database off (the saves folder)')
    H.eq(Config.Debug, true, 'shipped: Debug on')
    H.eq(Config.AdminUi.setupScreen, false, 'shipped: no first-start setup on Home')
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7, 9 }) do
        H.ok(Open(src) ~= nil, ('tablet: %s opens the Officer UI'):format(CID[src]))
    end

    -- who opens the Admin UI: the AdminAce admin, a Qbox admin (QboxAdmins); never a supervisor, officer, civilian
    H.ok(Open(5, { ui = 'admin' }) ~= nil, 'admin UI: the AdminAce admin opens it')
    H.ok(Open(8, { ui = 'admin' }) ~= nil, 'admin UI: a Qbox admin (group.admin) opens it')
    for _, src in ipairs({ 1, 3, 4, 9 }) do
        local s, why = Open(src, { ui = 'admin' })
        H.eq(why, 'err.not_admin', ('admin UI: %s is refused'):format(CID[src]))
        H.eq(s, nil, ('admin UI: %s gets no session'):format(CID[src]))
    end
    local home, err = Cb('admin:getHome', 3)
    H.eq(home, nil, 'home: a supervisor cannot read it (' .. tostring(err) .. ')')
    -- admins come from config.lua only: Settings never changes QboxAdmins or AdminAce
    local ok
    ok, err = Setting('QboxAdmins', false)
    H.eq(err, 'err.setting_locked', 'qbox admins: Settings cannot change who is an admin')
    ok, err = Setting('AdminAce', 'other.ace')
    H.eq(err, 'err.setting_locked', 'admin ace: Settings cannot change it either')
    -- the owner sets QboxAdmins = false in config.lua: the Qbox admin is no admin, the AdminAce admin still is
    Config.QboxAdmins = false
    local s, why = Open(8, { ui = 'admin' })
    H.eq(why, 'err.not_admin', 'qbox admins off: the Qbox admin is refused')
    H.ok(Open(5, { ui = 'admin' }) ~= nil, 'qbox admins off: the AdminAce admin still opens it')
    Config.QboxAdmins = true
    H.ok(Open(8, { ui = 'admin' }) ~= nil, 'qbox admins on: he opens it again')

    -- Home: on duty, the queues, the alerts and the shipped five shortcuts
    home, err = Cb('admin:getHome', 5)
    H.ok(type(home) == 'table', 'home: the admin opens Home: ' .. tostring(err))
    H.eq(home and home.live.onDuty, 7, 'home: seven police players on duty (1, 2, 3, 4, 6, 7, 9)')
    H.eq(home and table.concat(home.shortcuts, ','), 'newMission,missionSwitch,pay,points,settings',
        'home: the shipped five shortcuts in their order')
    H.eq(home and home.shortcutsByUse, false, 'home: shortcuts in config order (shipped)')
    H.eq(home and home.setup, false, 'home: no first-start setup (shipped)')
    H.eq(home and home.queues.flagged, 0, 'home: no flagged run')
    H.eq(home and home.queues.disputes, 0, 'home: no open dispute')
    H.eq(type(home and home.live.runs), 'table', 'home: the runs going (the liveRuns key)')

    -- a run going shows on Home
    local _, _, run = Draw(1, 'patrol', PATROL_OTHERS)
    H.ok(run ~= nil, 'home: Ada takes Beat Patrol')
    home = Cb('admin:getHome', 5)
    H.eq(home and home.live.runs.n, 1, 'home: her run shows under live now')
    Leave(1)

    -- shortcuts: the admin's own list (unknown keys and doubles dropped, the cap of 8), by use, none
    ok, err = Setting('AdminUi.homeShortcuts', { 'review', 'live', 'review' })
    H.eq(err, 'err.setting_duplicate', 'shortcuts: a shortcut twice is refused')
    ok, err = Setting('AdminUi.homeShortcuts', { 'review', 'nope' })
    H.eq(ok, false, 'shortcuts: an unknown shortcut is refused (' .. tostring(err) .. ')')
    ok, err = Setting('AdminUi.homeShortcuts', { 'review', 'live', 'activity' })
    home = Cb('admin:getHome', 5)
    H.eq(home and table.concat(home.shortcuts, ','), 'review,live,activity',
        'shortcuts: his own list in his order: ' .. tostring(err))
    ok = Setting('AdminUi.homeShortcutsByUse', true)
    H.eq((Cb('admin:getHome', 5) or {}).shortcutsByUse, true, 'shortcuts: by use switched on')
    ok = Setting('AdminUi.homeShortcuts', {})
    H.eq(#((Cb('admin:getHome', 5) or {}).shortcuts or { 1 }), 0, 'shortcuts: {} = none')
    W.Restart()
    H.eq(#((Cb('admin:getHome', 5) or {}).shortcuts or { 1 }), 0, 'restart: still none')
    H.eq((Cb('admin:getHome', 5) or {}).shortcutsByUse, true, 'restart: by use kept')
    Act('server:admin:resetSetting', 5, { path = 'AdminUi.homeShortcuts', reason = 'WF5C' })
    Act('server:admin:resetSetting', 5, { path = 'AdminUi.homeShortcutsByUse', reason = 'WF5C' })
    home = Cb('admin:getHome', 5)
    H.eq(home and table.concat(home.shortcuts, ','), 'newMission,missionSwitch,pay,points,settings',
        'shortcuts: reset to config.lua')

    -- search: by name, callsign and citizenid, a department filter, nothing found, a supervisor refused
    local found = Cb('admin:searchOfficers', 5, { query = 'Ada' })
    local hit
    for _, o in ipairs(found and found.officers or {}) do if o.citizenid == CID[1] then hit = o end end
    H.ok(hit ~= nil, 'search: Ada by her name')
    found = Cb('admin:searchOfficers', 5, { query = CID[2] })
    H.eq(found and #found.officers, 1, 'search: the FIB agent by his citizenid')
    found = Cb('admin:searchOfficers', 5, { query = '', filters = { department = 'fib' } })
    local allFib = found ~= nil and #found.officers >= 2
    for _, o in ipairs(found and found.officers or {}) do if o.department ~= 'fib' then allFib = false end end
    H.ok(allFib, 'search: the FIB filter lists FIB only')
    found = Cb('admin:searchOfficers', 5, { query = 'zzzz nobody' })
    H.eq(found and #found.officers, 0, 'search: nothing found')
    found, err = Cb('admin:searchOfficers', 3, { query = 'Ada' })
    H.eq(found, nil, 'search: a supervisor is refused (' .. tostring(err) .. ')')

    -- the admin drops with Home open; back, Home opens again
    W.Drop(5)
    W.Reconnect(5)
    H.ok(Cb('admin:getHome', 5) ~= nil, 'reconnect: Home opens again')
end

-- ============================================================================
--                                  2. PEOPLE
-- ============================================================================
-- AN OFFICER'S PAGE, DEPARTMENTS, DESKS, PERMISSIONS, GRANTS.

-- Qbox knows a sheriff's job too (the city's jobs.lua); a deputy of it joins later.
do
    local realJobs = H.exportsMock.qbx_core.GetJobs
    H.exportsMock.qbx_core.GetJobs = function()
        local jobs = realJobs()
        jobs.bcso = { label = 'BCSO', type = 'leo', grades = jobs.sast.grades }
        jobs.ranger = { label = 'Rangers', type = 'leo', grades = jobs.sast.grades }
        return jobs
    end
    W.AddPlayer(10, 'WFADMDP10', 'Rex', 'Deputy', 'bcso', 1)
    CID[10] = PD[10].citizenid
    H.players[10].coords = vec3(AT.x + 20.0, AT.y, AT.z)
    W.Reconnect(10)
end

do
    -- an officer's page: his record, his runs; a supervisor refused
    local off, err = Cb('admin:getOfficer', 5, { citizenid = CID[1] })
    H.ok(type(off) == 'table', 'officer: the admin opens Ada\'s page: ' .. tostring(err))
    off, err = Cb('admin:getOfficer', 5, { citizenid = 'NOPE0000' })
    H.eq(off, nil, 'officer: an unknown citizenid (' .. tostring(err) .. ')')
    off, err = Cb('admin:getOfficer', 3, { citizenid = CID[1] })
    H.eq(off, nil, 'officer: a supervisor is refused (' .. tostring(err) .. ')')

    -- suspend: the tablet refused while it holds; a restart keeps it; lifted; twice lifted refused
    local ok
    ok, err = Act('server:admin:suspend', 5, { citizenid = CID[7], days = 2 })
    H.eq(err, 'err.reason_required', 'suspend: a reason is needed')
    ok, err = Act('server:admin:suspend', 3, { citizenid = CID[7], days = 2, reason = 'No-shows' })
    H.eq(ok, false, 'suspend: a supervisor cannot (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:suspend', 5, { citizenid = CID[7], days = 2, reason = 'No-shows' })
    H.eq(ok, true, 'suspend: Dan suspended for two days: ' .. tostring(err))
    local s, why = Open(7)
    H.eq(why, 'err.suspended', 'suspend: his tablet is refused')
    W.Drop(7)
    W.Restart()
    W.Reconnect(7)
    s, why = Open(7)
    H.eq(why, 'err.suspended', 'restart and reconnect: still suspended')
    local rs = Cb('admin:getRestrictions', 5, {})
    local listed = false
    for _, r in ipairs(rs and rs.rows or {}) do
        if r.kind == 'suspension' and r.citizenid == CID[7] then listed = true end
    end
    H.ok(listed, 'suspend: Restrictions lists it')
    ok, err = Act('server:admin:suspend', 5, { citizenid = CID[7], days = 0, reason = 'Talked it over' })
    H.eq(ok, true, 'suspend: lifted: ' .. tostring(err))
    H.ok(Open(7) ~= nil, 'suspend: his tablet opens again')
    ok, err = Act('server:admin:suspend', 5, { citizenid = CID[7], days = 0, reason = 'again' })
    H.eq(err, 'err.not_suspended', 'suspend: lifting twice is refused')
    H.eq(Audits('suspend'), 1, 'suspend: audited once')
    H.eq(Audits('unsuspend'), 1, 'suspend: the lift audited once')
end

do
    -- an officer's run controls: his cooldowns read and cleared (a reason, never by a supervisor, at most
    -- AdminControl.cooldownClearsPerDay a day), across a restart and his drop
    local function TakeAgain(src)
        local saved = Config.DisabledMissions
        Config.DisabledMissions = PATROL_OTHERS
        local ok, err = Act('server:acceptType', src, 'patrol')
        Config.DisabledMissions = saved
        Leave(src)
        return ok, err
    end
    local run = Patrol(1)
    H.ok(run ~= nil and run.state == 'ended', 'cooldowns: Ada plays Beat Patrol')
    local st, err = Cb('admin:getOfficerRunState', 5, { citizenid = CID[1] })
    H.ok(st and st.online == true, 'cooldowns: her run state opens: ' .. tostring(err))
    st, err = Cb('admin:getOfficerRunState', 3, { citizenid = CID[1] })
    H.eq(st, nil, 'cooldowns: a supervisor never reads it (' .. tostring(err) .. ')')
    local ok
    ok, err = TakeAgain(1)
    H.eq(ok, false, 'cooldowns: Beat Patrol again at once is refused (' .. tostring(err) .. ')')
    local function Clear(src, reason)
        Secs(3)
        return Act('server:admin:clearCooldowns', src,
            { citizenid = CID[1], scope = 'mission', key = 'beat_patrol', reason = reason })
    end
    ok, err = Clear(5, nil)
    H.eq(err, 'err.reason_required', 'cooldowns: a reason is needed')
    ok, err = Clear(3, 'mine')
    H.eq(ok, false, 'cooldowns: a supervisor cannot use the admin clear (' .. tostring(err) .. ')')
    for n = 1, Config.AdminControl.cooldownClearsPerDay do
        Patrol(1)
        if n == 2 then
            W.Drop(1)
            W.Restart()
            W.Reconnect(1)
        end
        ok, err = Clear(5, 'Bugged call')
        H.eq(ok, true, ('cooldowns: clear %d: %s'):format(n, tostring(err)))
        ok, err = TakeAgain(1)
        H.eq(ok, true, ('cooldowns: after clear %d she takes it again: %s'):format(n, tostring(err)))
    end
    Patrol(1)
    ok, err = Clear(5, 'Once more')
    H.eq(ok, false,
        'cooldowns: one clear more than the day allows is refused, a restart in between (' .. tostring(err) .. ')')
end

do
    -- departments: the list; a sheriff's department added from the Qbox job, its deputy opens the tablet
    local depts, err = Cb('admin:getDepartments', 5)
    H.ok(type(depts) == 'table' and #depts.departments == 2, 'departments: SAST and FIB listed: ' .. tostring(err))
    local s, why = Open(10)
    H.ok(s == nil, 'departments: the deputy has no tablet yet (' .. tostring(why) .. ')')
    local ok
    ok, err = Act('server:admin:addDepartment', 3,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'bcso' }, supervisorGrade = 3 })
    H.eq(err, 'err.no_permission', 'departments: a supervisor cannot add one')
    ok, err = Act('server:admin:addDepartment', 5,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'nojob' }, supervisorGrade = 3 })
    H.eq(err, 'err.dept_job_unknown', 'departments: a job Qbox does not know is refused')
    ok, err = Act('server:admin:addDepartment', 5,
        { key = 'bcso', label = 'Sheriff', short = 'BCSO', jobs = { 'fib' }, supervisorGrade = 3 })
    H.eq(err, 'err.dept_job_taken', 'departments: FIB\'s job is refused')
    ok, err = Act('server:admin:addDepartment', 5,
        { key = 'sast', label = 'x', short = 'x', jobs = { 'bcso' }, supervisorGrade = 3 })
    H.eq(err, 'err.dept_exists', 'departments: an existing key is refused')
    ok, err = Act('server:admin:addDepartment', 5, {
        key = 'bcso',
        label = 'Blaine County Sheriff',
        short = 'BCSO',
        jobs = { 'bcso' },
        supervisorGrade = 3,
        themeFrom = 'sast',
    })
    H.eq(ok, true, 'departments: BCSO added: ' .. tostring(err))
    local o = Open(10)
    H.ok(o ~= nil, 'departments: the deputy opens his tablet')
    H.eq(CP.Access.getOfficer(10) and CP.Access.getOfficer(10).department, 'bcso', 'departments: as BCSO')
    -- rename it (label and tag); restart: it stays added and renamed
    ok, err = Act('server:admin:saveDepartment', 5,
        { key = 'bcso', fields = { label = 'County Sheriff', short = 'BCS' } })
    H.eq(ok, true, 'departments: renamed: ' .. tostring(err))
    ok, err = Act('server:admin:saveDepartment', 5, { key = 'sast', fields = { label = 'State Troopers' } })
    H.eq(ok, true, 'departments: a config.lua department renamed too: ' .. tostring(err))
    W.Drop(5)
    W.Restart()
    W.Reconnect(5)
    H.eq(Config.Departments.bcso and Config.Departments.bcso.short, 'BCS', 'restart: BCSO kept, its new tag')
    H.eq(Config.Departments.sast.label, 'State Troopers', 'restart: SAST\'s new label kept')
    H.ok(Open(10) ~= nil, 'restart: the deputy still opens his tablet')
    -- off: the typed tag; nobody of it opens the tablet; the last department stays on; back on
    ok, err = Act('server:admin:setDepartmentEnabled', 5,
        { key = 'bcso', enabled = false, reason = 'Quiet', confirm = 'X' })
    H.eq(err, 'err.confirm_mismatch', 'departments: off needs the typed tag')
    -- the deputy on a run: off is refused
    local _, _, run = Draw(10, 'patrol', PATROL_OTHERS)
    ok, err = Act('server:admin:setDepartmentEnabled', 5,
        { key = 'bcso', enabled = false, reason = 'Quiet', confirm = 'BCS' })
    H.ok(run ~= nil, 'departments: the deputy takes Beat Patrol')
    H.eq(err, 'err.dept_on_run', 'departments: off refused while its officer is on a run')
    Leave(10)
    ok, err = Act('server:admin:setDepartmentEnabled', 5,
        { key = 'bcso', enabled = false, reason = 'Quiet', confirm = 'bcs' })
    H.eq(ok, true, 'departments: BCSO off: ' .. tostring(err))
    s, why = Open(10)
    H.eq(s, nil, 'departments: off, the deputy has no tablet (' .. tostring(why) .. ')')
    W.Restart()
    s = Open(10)
    H.eq(s, nil, 'restart: still off')
    ok, err = Act('server:admin:setDepartmentEnabled', 5, { key = 'bcso', enabled = true, reason = 'Back' })
    H.eq(ok, true, 'departments: BCSO on again: ' .. tostring(err))
    H.ok(Open(10) ~= nil, 'departments: the deputy opens his tablet again')
    -- delete: a config.lua department never; one with history never; BCSO's run history keeps it
    ok, err = Act('server:admin:deleteDepartment', 5, { key = 'fib', reason = 'r', confirm = 'FIB' })
    H.eq(err, 'err.dept_builtin', 'departments: a config.lua department cannot be deleted')
    ok, err = Act('server:admin:deleteDepartment', 5, { key = 'bcso', reason = 'r', confirm = 'BCS' })
    H.eq(err, 'err.dept_has_rows', 'departments: BCSO has run history (the abandoned patrol): never deleted')
    -- a department with no history is deleted (typed tag), and stays deleted after a restart
    ok, err = Act('server:admin:addDepartment', 5,
        { key = 'ranger', label = 'Park Rangers', short = 'PR', jobs = { 'ranger' }, supervisorGrade = 3 })
    H.eq(ok, true, 'departments: Park Rangers added: ' .. tostring(err))
    ok, err = Act('server:admin:deleteDepartment', 5, { key = 'ranger', reason = 'Made by mistake', confirm = 'XX' })
    H.eq(err, 'err.confirm_mismatch', 'departments: delete needs the typed tag')
    ok, err = Act('server:admin:deleteDepartment', 5, { key = 'ranger', reason = 'Made by mistake', confirm = 'pr' })
    H.eq(ok, true, 'departments: Park Rangers (no history) deleted: ' .. tostring(err))
    W.Restart()
    H.eq(Config.Departments.ranger, nil, 'restart: still deleted')
    H.eq(Audits('departmentAdded'), 2, 'departments: both adds audited')
    Act('server:admin:resetSetting', 5, { path = 'Departments.sast.label', reason = 'WF5C' })
    H.eq(Config.Departments.sast.label ~= 'State Troopers', true, 'departments: SAST\'s label back to config.lua')
end

do
    -- desks: add one where the admin stands, change it (bad size and department refused), teleport, remove
    local before = #(Config.Tablet.desks or {})
    Place(5, vec3(111.0, 222.0, 30.0))
    local ok, res = Act('server:admin:addDeskHere', 5, { label = 'Bay desk', size = { x = 1, y = 1, z = 1 } })
    H.eq(ok, true, 'desks: one added where the admin stands: ' .. tostring(res))
    local idx = before + 1
    local d = Config.Tablet.desks[idx]
    H.ok(d and math.abs(d.coords.x - 111.0) < 0.01, 'desks: at his position')
    ok, res = Act('server:admin:addDeskHere', 3, { label = 'Mine', size = { x = 1, y = 1, z = 1 } })
    H.eq(ok, false, 'desks: a supervisor cannot add one (' .. tostring(res) .. ')')
    ok, res = Act('server:admin:updateDesk', 5, { index = idx, size = { x = 9, y = 1, z = 1 } })
    H.eq(res, 'err.desk_size', 'desks: a 9 m desk is refused')
    ok, res = Act('server:admin:updateDesk', 5, { index = idx, departments = { 'nope' } })
    H.eq(res, 'err.desk_department', 'desks: an unknown department is refused')
    ok, res = Act('server:admin:updateDesk', 5, { index = idx, label = 'Bay desk 2', departments = { 'fib' } })
    H.eq(ok, true, 'desks: renamed, FIB only: ' .. tostring(res))
    -- a SAST trooper at the FIB desk is refused, the FIB agent opens it
    Place(1, vec3(111.0, 222.0, 30.0))
    Place(2, vec3(111.0, 222.0, 30.0))
    local s, why = Open(1, { via = 'desk', desk = idx })
    H.ok(s == nil, 'desks: a trooper at the FIB desk is refused (' .. tostring(why) .. ')')
    H.ok(Open(2, { via = 'desk', desk = idx }) ~= nil, 'desks: the FIB agent opens it there')
    W.Restart()
    H.eq(Config.Tablet.desks[idx] and Config.Tablet.desks[idx].label, 'Bay desk 2', 'restart: the desk kept')
    ok, res = Act('server:admin:teleportToDesk', 5, { index = idx })
    H.eq(ok, true, 'desks: the admin teleports to it: ' .. tostring(res))
    ok, res = Act('server:admin:removeDesk', 5, { index = idx })
    H.eq(ok, true, 'desks: removed: ' .. tostring(res))
    H.eq(#(Config.Tablet.desks or {}), before, 'desks: back to the shipped desks')
    ok, res = Act('server:admin:removeDesk', 5, { index = 99 })
    H.eq(ok, false, 'desks: an unknown desk (' .. tostring(res) .. ')')
    for src = 1, 10 do Place(src, vec3(AT.x + src * 2.0, AT.y, AT.z)) end
end

do
    -- permissions: the screen; a supervisor power switched off is refused, back on works
    local perms, err = Cb('admin:getPermissions', 5)
    H.ok(type(perms) == 'table' and type(perms.supervisor) == 'table',
        'permissions: the screen opens: ' .. tostring(err))
    perms, err = Cb('admin:getPermissions', 3)
    H.eq(perms, nil, 'permissions: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Setting('Permissions.supervisor.issueCommendation', false)
    H.eq(ok, true, 'permissions: Commend switched off for supervisors: ' .. tostring(err))
    ok, err = Act('server:sup:commend', 3,
        { citizenid = CID[1], kind = 'lifesaving', citation = 'Saved a life today.' })
    H.eq(ok, false, 'permissions: the supervisor\'s Commend is refused (' .. tostring(err) .. ')')
    W.Restart()
    ok, err = Act('server:sup:commend', 3,
        { citizenid = CID[1], kind = 'lifesaving', citation = 'Saved a life today.' })
    H.eq(ok, false, 'restart: still refused')
    ok = Setting('Permissions.supervisor.issueCommendation', true)
    ok, err = Act('server:sup:commend', 3,
        { citizenid = CID[1], kind = 'lifesaving', citation = 'Saved a life today.' })
    H.eq(ok, true, 'permissions: back on, the supervisor commends: ' .. tostring(err))
    -- extra grants: mission calls for one trooper by citizenid, then for SAST from grade 1; an admin-only key never
    ok, err = Setting('Permissions.grants', { missionCalls = { citizenids = { CID[1] } } })
    H.eq(ok, true, 'grants: mission calls for Ada: ' .. tostring(err))
    local sess = Open(1, { ui = 'supervisor' })
    H.ok(sess ~= nil, 'grants: Ada opens the Supervisor UI with her one power')
    local s, why = Open(6, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'grants: Cleo (not granted) does not')
    ok, err = Setting('Permissions.grants', { suspend = { citizenids = { CID[1] } } })
    H.eq(ok, false, 'grants: an admin-only power cannot be granted (' .. tostring(err) .. ')')
    ok, err = Setting('Permissions.grants', { missionCalls = { departments = { sast = { minGrade = 1 } } } })
    H.eq(ok, true, 'grants: mission calls for SAST from grade 1: ' .. tostring(err))
    W.Drop(6)
    W.Restart()
    W.Reconnect(6)
    H.ok(Open(6, { ui = 'supervisor' }) ~= nil, 'restart and reconnect: Cleo (grade 1) has it')
    s, why = Open(9, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'grants: the cadet (grade 0) has not')
    ok = Setting('Permissions.grants', {})
    s, why = Open(6, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'grants: taken back')
    -- the config health check on Permissions
    local health = Cb('admin:getConfigHealth', 5)
    H.ok(type(health) == 'table', 'permissions: the config health list opens')
end

-- ============================================================================
--                                 3. MISSIONS
-- ============================================================================
-- SWITCHES, THE MISSION BUILDER, MAP MARKERS, TESTING TOOLS.

local U = CP.U

do
    -- the mission switch: Beat Patrol off, the board never draws it; a supervisor cannot; restart; reset
    local ms, err = Cb('admin:getMissions', 5)
    H.ok(type(ms) == 'table', 'missions: the list opens: ' .. tostring(err))
    local ok
    ok, err = Act('server:admin:setMissionEnabled', 3, { missionId = 'beat_patrol', enabled = false })
    H.eq(err, 'err.no_permission', 'switch: a supervisor cannot switch a mission')
    ok, err = Act('server:admin:setMissionEnabled', 5, { missionId = 'no_such_mission', enabled = false })
    H.eq(ok, false, 'switch: an unknown mission (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setMissionEnabled', 5, { missionId = 'beat_patrol', enabled = false })
    H.eq(ok, true, 'switch: Beat Patrol off: ' .. tostring(err))
    local okA, dA, rA = Draw(1, 'patrol', PATROL_OTHERS)
    H.eq(okA, false, 'switch: with the other patrols off, nothing to draw (' .. tostring(dA) .. ')')
    W.Restart()
    okA = Draw(1, 'patrol', PATROL_OTHERS)
    H.eq(okA, false, 'restart: Beat Patrol still off')
    ok, err = Act('server:admin:setMissionEnabled', 5, { missionId = 'beat_patrol', enabled = true })
    H.eq(ok, true, 'switch: Beat Patrol on again')
    -- one location off: never drawn; reset brings every switch back
    ok, err = Act('server:admin:setLocationEnabled', 5, { missionId = 'beat_patrol', index = 1, enabled = false })
    H.eq(ok, true, 'switch: its first location off: ' .. tostring(err))
    H.eq(CP.Missions.isLocationEnabled('beat_patrol', 1), false, 'switch: location 1 is off')
    for _ = 1, 3 do
        local okD, _, run = Draw(1, 'patrol', PATROL_OTHERS)
        H.ok(okD == true and run and run.locationIndex ~= 1, 'switch: Beat Patrol drawn at another location')
        Leave(1)
    end
    ok, err = Act('server:admin:resetMissionSwitches', 5, { missionId = 'beat_patrol' })
    H.eq(ok, true, 'switch: reset: ' .. tostring(err))
    H.eq(CP.Missions.isLocationEnabled('beat_patrol', 1), true, 'switch: location 1 back on')
    -- the load summary and a reload of the mission files
    local load = Cb('admin:getMissionLoad', 5)
    H.ok(type(load) == 'table', 'missions: the load summary opens')
    ok, err = Act('server:admin:reloadMissions', 3, {})
    H.eq(ok, false, 'reload: a supervisor cannot (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:reloadMissions', 5, { reason = 'new files' })
    H.eq(ok, true, 'reload: the admin reloads the mission files: ' .. tostring(err))
    H.ok(CP.Missions.get('beat_patrol') ~= nil, 'reload: Beat Patrol still there')
end

do
    -- the Mission Builder as an admin: a new mission from Beat Patrol, saved, a restart, a test that the admin
    -- drops out of, a test driven through, published, drawn and paid; then edit a built-in and reset it
    local ok, d = Act('server:builder:duplicate', 5, { id = 'beat_patrol', label = 'Harbour Patrol' })
    H.eq(ok, true, 'builder: the admin creates a mission from Beat Patrol: ' .. tostring(d))
    local id = type(d) == 'table' and d.id or nil
    local got = Cb('builder:get', 5, { id = id })
    local def = cjson.decode(cjson.encode(U.serialize(got and got.definition or {})))
    def.description = 'The harbour by night.'
    local okS, s = Act('server:builder:save', 5, { id = id, definition = def })
    H.eq(okS, true, 'builder: saved: ' .. tostring(s))
    W.Restart()
    got = Cb('builder:get', 5, { id = id })
    H.eq(got and got.definition and got.definition.description, 'The harbour by night.', 'restart: the draft kept')
    H.eq(CP.Missions.get(id), nil, 'restart: not playable as a draft')
    -- requireTestToPublish on: a supervisor's untested draft is refused; an admin never needs a test
    ok = Setting('Builder.requireTestToPublish', true)
    H.eq(ok, true, 'builder: testing required for supervisors')
    Place(5, vec3(200.0, -1000.0, 29.0))
    local okT, t = Act('server:builder:test', 5, { id = id, location = 1, useStartRoute = false })
    H.eq(okT, true, 'builder: a first test run: ' .. tostring(t))
    local money1 = #W.addMoney
    W.Drop(5)
    H.eq(CP.Runs.getBySrc(5), nil, 'drop: the test run ends')
    H.eq(#W.addMoney, money1, 'drop: it paid nothing')
    W.Reconnect(5)
    Place(5, vec3(200.0, -1000.0, 29.0))
    okT, t = Act('server:builder:test', 5, { id = id, location = 1, useStartRoute = false })
    H.eq(okT, true, 'builder: a test run: ' .. tostring(t))
    local run = CP.Runs.getBySrc(5)
    if run then
        local veh = W.TakeWheel(5, run)
        W.DriveCheckpoints(5, run, veh)
        H.eq(run.state, 'ended', 'builder: the test is driven through')
        H.eq(#W.addMoney, money1, 'builder: a test pays nothing')
    end
    local okP, p = Act('server:builder:publish', 5, { id = id })
    H.eq(okP, true, 'builder: published by the admin: ' .. tostring(p))
    Act('server:admin:resetSetting', 5, { path = 'Builder.requireTestToPublish', reason = 'WF5C' })
    W.Restart()
    local live = CP.Missions.get(id)
    H.ok(live ~= nil and live.type == 'patrol', 'restart: Harbour Patrol plays as a Patrol mission')
    local others = U.copy(PATROL_OTHERS)
    others[#others + 1] = 'beat_patrol'
    local okD, _, orun = Draw(2, 'patrol', others)
    H.eq(okD and orun and orun.missionId, id, 'builder: the FIB agent draws Harbour Patrol')
    if orun then
        local veh = W.TakeWheel(2, orun)
        W.DriveCheckpoints(2, orun, veh)
        Secs(3)
        local r = W.Rows('run_uuid = ?', { orun.id })[1] or {}
        H.eq(r.state, 'completed', 'builder: completed')
        H.eq(tonumber(r.cash_paid), 250, 'builder: paid the Patrol payout ($250)')
    end
    -- archive it: no longer drawn; restore it
    ok, d = Act('server:builder:archive', 5, { id = id, reason = 'Season over' })
    H.eq(ok, true, 'builder: archived: ' .. tostring(d))
    H.eq(CP.Missions.get(id), nil, 'builder: archived, not playable')
    ok, d = Act('server:builder:restore', 5, { id = id })
    H.eq(ok, true, 'builder: restored: ' .. tostring(d))

    -- edit a built-in (an override under the same id), restart, then Reset to original
    ok, d = Act('server:builder:editBuiltin', 3, { id = 'evoc_course' })
    H.eq(ok, false, 'built-in: a supervisor cannot edit one (' .. tostring(d) .. ')')
    ok, d = Act('server:builder:editBuiltin', 5, { id = 'evoc_course' })
    H.eq(ok, true, 'built-in: the admin opens EVOC: ' .. tostring(d))
    local bdef = cjson.decode(cjson.encode(U.serialize(d and d.record and d.record.definition or {})))
    bdef.label = 'EVOC (edited)'
    okS, s = Act('server:builder:save', 5, { id = 'evoc_course', definition = bdef })
    H.eq(okS, true, 'built-in: saved: ' .. tostring(s))
    okP, p = Act('server:builder:publish', 5, { id = 'evoc_course' })
    H.eq(okP, true, 'built-in: published: ' .. tostring(p))
    W.Restart()
    live = CP.Missions.get('evoc_course')
    H.ok(live and live.overridden == true and live.label == 'EVOC (edited)', 'restart: the override plays')
    local diff = Cb('admin:builtinDiff', 5, { id = 'evoc_course' })
    H.ok(type(diff) == 'table', 'built-in: the difference to the shipped one opens')
    ok, d = Act('server:builder:resetBuiltin', 5, { id = 'evoc_course', reason = 'back to stock', confirm = 'nope' })
    H.eq(d, 'err.confirm_mismatch', 'built-in: Reset needs the typed id')
    ok, d = Act('server:builder:resetBuiltin', 5,
        { id = 'evoc_course', reason = 'back to stock', confirm = 'evoc_course' })
    H.eq(ok, true, 'built-in: Reset to original: ' .. tostring(d))
    live = CP.Missions.get('evoc_course')
    H.ok(live and not live.overridden and live.label ~= 'EVOC (edited)', 'built-in: the shipped EVOC plays again')
    W.Restart()
    live = CP.Missions.get('evoc_course')
    H.ok(live and not live.overridden, 'restart: still the shipped one')
    -- editBuiltins off: refused
    ok = Setting('AdminControl.editBuiltins', false)
    ok, d = Act('server:builder:editBuiltin', 5, { id = 'evoc_course' })
    H.eq(ok, false, 'built-in: editBuiltins off refuses it (' .. tostring(d) .. ')')
    Act('server:admin:resetSetting', 5, { path = 'AdminControl.editBuiltins', reason = 'WF5C' })
end

do
    -- map markers: shipped, no extra parts; on with the partner part, each unit member sees the other; a rule
    -- (leader only); a bad rule refused; restart keeps them
    local function Parts(src, since)
        local list = W.ClientEvents('crimson-police:client:markerParts', src, since)
        local last = list[#list]
        return last and last.args[1] or nil
    end
    local function HasPart(view, part)
        for _, it in ipairs(view and view.items or {}) do if it.p == part then return true end end
        return false
    end
    W.FormUnit(1, 6)
    local mark = #H.events
    local okD, _, run = Draw(1, 'tactical', TACTICAL_OTHERS)
    H.eq(okD, true, 'markers: Ada\'s unit takes Gang Shootout')
    Secs(8)
    H.eq(HasPart(Parts(1, mark), 'partner'), false, 'markers shipped: no partner blip (extraParts off)')
    local ok, err = Setting('Markers.extraParts', true)
    H.eq(ok, true, 'markers: extra parts on: ' .. tostring(err))
    ok, err = Setting('Markers.parts.partner.on', true)
    H.eq(ok, true, 'markers: the partner part on: ' .. tostring(err))
    mark = #H.events
    Secs(8)
    H.eq(HasPart(Parts(1, mark), 'partner'), true, 'markers: Ada sees Cleo')
    H.eq(HasPart(Parts(6, mark), 'partner'), true, 'markers: Cleo sees Ada')
    ok, err = Setting('Markers.rules', { partner = { departments = { 'nope' } } })
    H.eq(err, 'err.setting_marker_department', 'markers: a rule naming an unknown department is refused (WF5C-1)')
    ok, err = Setting('Markers.rules', { partnr = { roles = 'leader' } })
    H.eq(err, 'err.setting_marker_part', 'markers: a rule for an unknown part is refused (WF5C-1)')
    ok, err = Setting('Markers.rules', { partner = { missionTypes = { 'patrl' } } })
    H.eq(err, 'err.setting_marker_type', 'markers: a rule naming an unknown mission type is refused (WF5C-1)')
    ok, err = Setting('Markers.rules', { partner = { roles = 'leader' } })
    H.eq(ok, true, 'markers: partner blips for the leader only: ' .. tostring(err))
    W.Restart()
    mark = #H.events
    Leave(1)
    Leave(6)
    W.FormUnit(1, 6)
    okD, _, run = Draw(1, 'tactical', TACTICAL_OTHERS)
    H.eq(okD, true, 'restart: the unit takes Gang Shootout again')
    Secs(8)
    H.eq(HasPart(Parts(1, mark), 'partner'), true, 'restart: the leader still sees his partner')
    H.eq(HasPart(Parts(6, mark), 'partner'), false, 'restart: the member does not (the rule kept)')
    Leave(1)
    Leave(6)
    for _, path in ipairs({ 'Markers.rules', 'Markers.parts.partner.on', 'Markers.extraParts' }) do
        Act('server:admin:resetSetting', 5, { path = path, reason = 'WF5C' })
    end
    H.eq(Config.Markers.extraParts, false, 'markers: back to the shipped extra parts (off)')
end

do
    -- the testing tools: the list, a test run of a built-in started from Testing, ended by the other admin,
    -- recorded, a location marked checked, a result hidden and shown; a supervisor refused
    local tests, err = Cb('admin:getTests', 5)
    H.ok(type(tests) == 'table', 'testing: the screen opens: ' .. tostring(err))
    tests, err = Cb('admin:getTests', 3)
    H.eq(tests, nil, 'testing: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Act('server:admin:startTest', 3, { missionId = 'beat_patrol', location = 1 })
    H.eq(ok, false, 'testing: a supervisor cannot start one (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:recordTest', 5, { missionId = 'beat_patrol', location = 1, result = 'passed' })
    H.eq(err, 'err.test_not_run', 'testing: nothing to record before a test')
    Place(5, vec3(200.0, -1000.0, 29.0))
    ok, err = Act('server:admin:startTest', 5, { missionId = 'beat_patrol', location = 1, useStartRoute = false })
    H.eq(ok, true, 'testing: the admin tests Beat Patrol at location 1: ' .. tostring(err))
    local run = CP.Runs.getBySrc(5)
    H.ok(run ~= nil and run.test ~= nil, 'testing: a test run')
    ok, err = Act('server:admin:endTest', 8, { runId = run and run.id })
    H.eq(err, 'err.reason_required', 'testing: End test needs a reason')
    ok, err = Act('server:admin:endTest', 8, { runId = run and run.id, reason = 'left it running' })
    H.eq(ok, true, 'testing: the other admin ends it: ' .. tostring(err))
    H.eq(CP.Runs.getBySrc(5), nil, 'testing: ended')
    ok, err = Act('server:admin:recordTest', 5, { missionId = 'beat_patrol', location = 1, result = 'passed' })
    H.eq(ok, true, 'testing: the result is recorded: ' .. tostring(err))
    W.Restart()
    local hist = Cb('admin:getTestHistory', 5, { missionId = 'beat_patrol', locationIndex = 1 })
    H.ok(hist and #hist.results >= 1, 'restart: the result is kept')
    local resultId = hist and hist.results[1] and hist.results[1].id
    ok, err = Act('server:admin:hideTestResult', 5, { id = resultId, hidden = true, reason = 'wrong result' })
    H.eq(ok, true, 'testing: the result hidden: ' .. tostring(err))
    ok, err = Act('server:admin:hideTestResult', 5, { id = resultId, hidden = false, reason = 'it was right' })
    H.eq(ok, true, 'testing: shown again: ' .. tostring(err))
    ok, err = Act('server:admin:markLocationChecked', 5, { missionId = 'beat_patrol', locationIndex = 2 })
    H.eq(err, 'err.reason_required', 'testing: Mark checked needs a reason')
    ok, err = Act('server:admin:markLocationChecked', 5,
        { missionId = 'beat_patrol', locationIndex = 2, reason = 'walked it, fine' })
    H.eq(ok, true, 'testing: location 2 marked checked: ' .. tostring(err))
    H.eq(Audits('recordTest'), 1, 'testing: the recording audited')
    for src = 1, 10 do Place(src, vec3(AT.x + src * 2.0, AT.y, AT.z)) end
end

-- ============================================================================
--                                   4. MONEY
-- ============================================================================
-- PAY RATES, REWARDS, PAYMENTS, FUNDS, THE MONEY TOOLS (ENABLE).

-- How Qbox's AddMoney answers Ada's next payment: nil = as normal, false = it refuses, 'raise' = it errors.
local nextAddMoney = nil
do
    local realGet = H.exportsMock.qbx_core.GetPlayer
    H.exportsMock.qbx_core.GetPlayer = function(src)
        local p = realGet(src)
        -- Qbox's RemoveMoney (a clawback): from the bank balance the spec gives the player
        if p then
            p.Functions.RemoveMoney = function(account, amount)
                local m = p.PlayerData.money or {}
                if (m[account] or 0) < amount then return false end
                m[account] = m[account] - amount
                return true
            end
        end
        if p and tonumber(src) == 1 and nextAddMoney ~= nil then
            local mode = nextAddMoney
            local add = p.Functions.AddMoney
            p.Functions.AddMoney = function(...)
                nextAddMoney = nil
                if mode == 'raise' then error('bank is down') end
                if mode == false then return false end
                return add(...)
            end
        end
        return p
    end
end
local function PaidRow(src)
    local run = Patrol(src)
    Secs(3)
    return run and W.Rows('run_uuid = ?', { run.id })[1] or nil
end
local function Owed(row) return tonumber(row and row.cash_paid) end

do
    -- pay rates: the screen; Patrol to $400 (a supervisor cannot use the admin action); a run pays it; restart
    local view, err = Cb('admin:getPayouts', 5)
    H.ok(type(view) == 'table', 'pay: the Pay rates screen opens: ' .. tostring(err))
    view, err = Cb('admin:getPayouts', 1)
    H.eq(view, nil, 'pay: an officer is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Act('server:admin:setTypePayout', 3, { type = 'patrol', amount = 400, reason = 'x' })
    H.eq(ok, false, 'pay: a supervisor cannot use the admin action (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setTypePayout', 5, { type = 'patrol', amount = 25001, reason = 'too much' })
    H.eq(ok, false, 'pay: above Cash.maxPayout refused (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setTypePayout', 5, { type = 'patrol', amount = 400, reason = 'Busy week' })
    H.eq(ok, true, 'pay: Patrol set to $400: ' .. tostring(err))
    W.Restart()
    local row = PaidRow(1)
    H.eq(row and row.state, 'completed', 'pay: Ada\'s patrol completed')
    H.eq(row and tonumber(row.cash_paid), 400, 'restart: the patrol pays the new $400')
    -- a single mission's payout wins over its type's; cleared, the type's again
    ok, err = Act('server:admin:setMissionPayout', 5,
        { missionId = 'beat_patrol', amount = 900, reason = 'Event week' })
    H.eq(ok, true, 'pay: Beat Patrol set to $900: ' .. tostring(err))
    row = PaidRow(1)
    H.eq(row and tonumber(row.cash_paid), 900, 'pay: Beat Patrol pays $900')
    ok, err = Act('server:admin:setMissionPayout', 5,
        { missionId = 'beat_patrol', clear = true, reason = 'Event over' })
    H.eq(ok, true, 'pay: cleared: ' .. tostring(err))
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 400, 'pay: Beat Patrol follows its type again')
    -- adjust all: the preview, its token, +10 % to every type, a used token refused
    local pv
    pv, err = Cb('admin:previewPayoutAdjust', 5, { mode = 'pct', value = 10, scope = 'types' })
    H.ok(pv and pv.previewToken, 'pay: Adjust all shows its preview: ' .. tostring(err))
    local function Adjust(token, confirm)
        return Act('server:admin:adjustAllPayouts', 5, {
            mode = 'pct',
            value = 10,
            scope = 'types',
            reason = 'Inflation',
            confirm = confirm or 'ADJUST',
            previewToken = token,
            requestId = RequestId(),
        })
    end
    ok, err = Adjust(pv and pv.previewToken, 'adjus')
    H.eq(err, 'err.confirm_mismatch', 'pay: Adjust all needs the typed ADJUST')
    ok, err = Adjust(pv and pv.previewToken)
    H.eq(ok, true, 'pay: every type +10 %: ' .. tostring(err))
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 440, 'pay: Patrol now $440')
    ok, err = Adjust(pv and pv.previewToken)
    H.eq(ok, false, 'pay: the used preview cannot run twice (' .. tostring(err) .. ')')
    -- back to config.lua for every type
    for t in pairs(Config.MissionTypes) do
        Act('server:admin:setTypePayout', 5, { type = t, clear = true, reason = 'WF5C' })
    end
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 250, 'pay: Patrol back to config.lua\'s $250')
end

do
    -- payments: the list, a payment Qbox refused (pending) paid by Pay now, a stuck one (paying) marked paid,
    -- a pending one cancelled; a supervisor refused; the officer drops and comes back between
    local list, err = Cb('admin:getPayments', 5, { citizenid = CID[1] })
    H.ok(list and list.total >= 2, 'payments: Ada\'s payments listed: ' .. tostring(err))
    H.eq(list and list.switches and list.switches.clawback, false, 'payments: the money tools ship off')
    list, err = Cb('admin:getPayments', 3, {})
    H.eq(list, nil, 'payments: a supervisor is refused (' .. tostring(err) .. ')')
    nextAddMoney = false
    local row = PaidRow(1)
    H.eq(row and row.cash_status, 'pending', 'payments: Qbox refused the payout: pending')
    W.Drop(1)
    local ok
    ok, err = Act('server:admin:payNow', 5, { rowId = row and row.id, requestId = RequestId() })
    H.ok(ok == true and type(err) == 'table' and err.status == 'pending' and err.online == false,
        'payments: Pay now while she is offline: still pending')
    W.Restart()
    W.Reconnect(1)
    Secs(3)
    -- back online, the login sweep pays what waits for her
    local again = W.Rows('id = ?', { row and row.id })[1]
    H.eq(again and again.cash_status, 'paid', 'restart and reconnect: her login pays the pending payment')
    ok, err = Act('server:admin:payNow', 5, { rowId = row and row.id, requestId = RequestId() })
    H.eq(err, 'err.state_changed', 'payments: Pay now on a paid row is refused')
    -- stuck: Qbox raised during the payout, the row waits for a check
    nextAddMoney = 'raise'
    row = PaidRow(1)
    H.eq(row and row.cash_status, 'paying', 'payments: AddMoney raised: the row stays paying')
    local stuck = Cb('admin:getStuckPayments', 5)
    H.ok(stuck and #(stuck.payments or {}) >= 1, 'payments: it shows as stuck')
    ok, err = Act('server:admin:resolvePayment', 5,
        { rowId = row and row.id, outcome = 'paid', requestId = RequestId() })
    H.eq(err, 'err.reason_required', 'payments: Mark paid needs a reason')
    local owedNow
    for _, r in ipairs((Cb('admin:getPayments', 5, { citizenid = CID[1] }) or {}).rows or {}) do
        if row and r.id == row.id then owedNow = r.owed end
    end
    ok, err = Act('server:admin:resolvePayment', 5, {
        rowId = row and row.id,
        outcome = 'payAgain',
        checked = true,
        reason = 'x',
        requestId = RequestId(),
        confirm = tostring(owedNow),
    })
    H.eq(err, 'err.money_tool_off', 'payments: Pay again ships off')
    ok, err = Act('server:admin:resolvePayment', 5,
        { rowId = row and row.id, outcome = 'paid', reason = 'Checked the bank history', requestId = RequestId() })
    H.eq(ok, true, 'payments: Mark paid: ' .. tostring(err))
    H.eq(W.Rows('id = ?', { row and row.id })[1].cash_status, 'paid', 'payments: paid')
    -- cancel a pending one: the typed amount, the run keeps its points
    nextAddMoney = false
    row = PaidRow(1)
    H.eq(row and row.cash_status, 'pending', 'payments: another pending payment')
    ok, err = Act('server:admin:cancelPayment', 5, { rowId = row and row.id, reason = 'Duplicate', confirm = '1' })
    H.eq(err, 'err.confirm_mismatch', 'payments: Cancel asks for the amount')
    ok, err = Act('server:admin:cancelPayment', 5, { rowId = row and row.id, reason = 'Duplicate', confirm = '250' })
    H.eq(ok, true, 'payments: cancelled: ' .. tostring(err))
    again = W.Rows('id = ?', { row and row.id })[1]
    H.eq(again and again.cash_status, 'forfeited', 'payments: forfeited')
    H.ok(again and tonumber(again.final_points) > 0, 'payments: the run keeps its points')
    ok, err = Act('server:admin:retryPending', 5, { requestId = RequestId() })
    H.eq(ok, true, 'payments: Retry all pending: ' .. tostring(err))
    -- the export
    local csv = Cb('admin:exportPayments', 5, { citizenid = CID[1] })
    H.ok(csv ~= nil, 'payments: exported')
end

do
    -- the money tools: off as shipped; turning one on needs ENABLE; manual cash, a clawback; off again
    local ok, err = Act('server:admin:manualCash', 5,
        { citizenid = CID[1], amount = 300, reason = 'Lost payout', requestId = RequestId() })
    H.eq(err, 'err.money_tool_off', 'money tools: manual cash ships off')
    ok, err = Setting('Cash.allowManualCash', true)
    H.eq(ok, false, 'money tools: turning one on without ENABLE is refused (' .. tostring(err) .. ')')
    for _, path in ipairs({ 'Cash.allowManualCash', 'Cash.allowClawback' }) do
        ok, err = Act('server:admin:setSetting', 5, { path = path, json = 'true', reason = 'WF5C', confirm = 'ENABLE' })
        H.eq(ok, true, ('money tools: %s on with ENABLE: %s'):format(path, tostring(err)))
    end
    W.Restart()
    H.eq(Config.Cash.allowManualCash, true, 'restart: manual cash still on')
    local paid0 = select(2, W.Paid(CID[1]))
    ok, err = Act('server:admin:manualCash', 5,
        { citizenid = CID[1], amount = 300, reason = 'Lost payout', requestId = RequestId() })
    H.ok(ok == true and type(err) == 'table' and err.status == 'paid',
        'money tools: $300 paid by hand: ' .. tostring(err))
    H.eq(select(2, W.Paid(CID[1])) - paid0, 300, 'money tools: exactly $300')
    ok, err = Act('server:admin:manualCash', 5,
        { citizenid = 'NOBODY99', amount = 10, reason = 'x', requestId = RequestId() })
    H.eq(err, 'err.unknown_officer', 'money tools: a citizenid no officer has is an unknown officer (WF5C-2)')
    ok, err = Act('server:admin:manualCash', 3,
        { citizenid = CID[1], amount = 10, reason = 'x', requestId = RequestId() })
    H.eq(ok, false, 'money tools: a supervisor cannot (' .. tostring(err) .. ')')
    PD[1].money = { bank = 100000, cash = 0 }
    local row = PaidRow(1)
    ok, err = Act('server:admin:clawback', 5,
        { rowId = row and row.id, amount = 100000, reason = 'x', confirm = '100000', requestId = RequestId() })
    H.eq(ok, false, 'money tools: never more back than was paid (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:clawback', 5,
        { rowId = row and row.id, amount = 100, reason = 'Paid twice', confirm = '100', requestId = RequestId() })
    H.eq(ok, true, 'money tools: $100 taken back: ' .. tostring(err))
    for _, path in ipairs({ 'Cash.allowManualCash', 'Cash.allowClawback' }) do
        Act('server:admin:resetSetting', 5, { path = path, reason = 'WF5C' })
    end
    ok, err = Act('server:admin:clawback', 5,
        { rowId = row and row.id, amount = 50, reason = 'x', confirm = '50', requestId = RequestId() })
    H.eq(err, 'err.money_tool_off', 'money tools: off again')
    H.eq(Audits('manualCash'), 1, 'money tools: the manual cash audited')
end

do
    -- department funds: the card; Add funds off as shipped; on (ENABLE) with the society source; a deposit
    local f, err = Cb('admin:getDepartmentFunds', 5, { department = 'sast' })
    H.ok(type(f) == 'table', 'funds: the Funds card opens: ' .. tostring(err))
    f, err = Cb('admin:getDepartmentFunds', 3, { department = 'sast' })
    H.eq(f, nil, 'funds: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Act('server:admin:addDepartmentFunds', 5,
        { department = 'sast', amount = 500, reason = 'Top up', confirm = '500', requestId = RequestId() })
    H.eq(err, 'err.money_tool_off', 'funds: Add funds ships off')
    ok, err = Act('server:admin:setSetting', 5,
        { path = 'Cash.allowAddFunds', json = 'true', reason = 'WF5C', confirm = 'ENABLE' })
    H.eq(ok, true, 'funds: Add funds on: ' .. tostring(err))
    ok, err = Act('server:admin:addDepartmentFunds', 5,
        { department = 'nope', amount = 500, reason = 'Top up', confirm = '500', requestId = RequestId() })
    H.eq(ok, false, 'funds: an unknown department (' .. tostring(err) .. ')')
    Secs(11)
    ok, err = Act('server:admin:addDepartmentFunds', 5,
        { department = 'sast', amount = 500, reason = 'Top up', confirm = '50', requestId = RequestId() })
    H.eq(err, 'err.confirm_mismatch', 'funds: the typed amount')
    Secs(11)
    ok, err = Act('server:admin:addDepartmentFunds', 5,
        { department = 'sast', amount = 500, reason = 'Top up', confirm = '500', requestId = RequestId() })
    H.eq(ok, true, 'funds: $500 added to SAST: ' .. tostring(err))
    Act('server:admin:resetSetting', 5, { path = 'Cash.allowAddFunds', reason = 'WF5C' })
end

do
    -- item rewards: off as shipped (Deliver refused); on with a pool; no room: the reward waits; the admin's
    -- list; Deliver now while she is offline refused; delivered once there is room; another cancelled; take back off
    local ok, err = Act('server:admin:deliverRewards', 5, { citizenid = CID[1] })
    H.eq(err, 'err.rewards_off', 'rewards: off as shipped')
    local pool = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } }
    H.eq(Setting('Rewards.enabled', true), true, 'rewards: item rewards on')
    H.eq(Setting('Rewards.byType', { patrol = pool }), true, 'rewards: a water for every patrol')
    local inv = H.exportsMock.ox_inventory
    local canCarry = inv.CanCarryItem
    inv.CanCarryItem = function() return false end
    local items0 = W.ItemsGiven(1, 'water')
    PaidRow(1)
    PaidRow(1)
    H.eq(W.ItemsGiven(1, 'water'), items0, 'rewards: no room: nothing given')
    local view
    view, err = Cb('admin:getRewards', 5, { citizenid = CID[1] })
    local waiting = {}
    for _, r in ipairs(view and view.recent or {}) do
        if r.citizenid == CID[1] and r.status == 'pending' then waiting[#waiting + 1] = r end
    end
    H.eq(#waiting, 2, 'rewards: both wait in her locker: ' .. tostring(err))
    W.Drop(1)
    ok, err = Act('server:admin:deliverRewards', 5, { citizenid = CID[1] })
    H.eq(err, 'err.officer_offline', 'rewards: Deliver now while she is offline is refused')
    W.Restart()
    ok, err = Act('server:admin:cancelReward', 5, { id = waiting[1] and waiting[1].id })
    H.eq(err, 'err.reason_required', 'rewards: Cancel needs a reason')
    ok, err = Act('server:admin:cancelReward', 5, { id = waiting[1] and waiting[1].id, reason = 'Farmed' })
    H.eq(ok, true, 'rewards: one cancelled: ' .. tostring(err))
    inv.CanCarryItem = canCarry
    W.Reconnect(1)
    Secs(3)
    ok, err = Act('server:admin:deliverRewards', 5, { citizenid = CID[1] })
    H.eq(ok, true, 'rewards: Deliver now: ' .. tostring(err))
    H.eq(W.ItemsGiven(1, 'water'), items0 + 1, 'rewards: the other one given once (the cancelled one never)')
    ok, err = Act('server:admin:takeBackReward', 5,
        { id = waiting[2] and waiting[2].id, reason = 'x', confirm = 'water', requestId = RequestId() })
    H.eq(err, 'err.money_tool_off', 'rewards: Take back ships off')
    Act('server:admin:resetSetting', 5, { path = 'Rewards.byType', reason = 'WF5C' })
    Act('server:admin:resetSetting', 5, { path = 'Rewards.enabled', reason = 'WF5C' })
    H.eq(Config.Rewards.enabled, false, 'rewards: off again')
end

-- ============================================================================
--                                  5. REVIEW
-- ============================================================================
-- FLAGGED RUNS, DISPUTES, CORRECTIONS, RESTRICTIONS, THE AUDIT LOG.

local function Bit(v) return v == true or tonumber(v) == 1 end
local function Row(id) return W.Rows('id = ?', { id })[1] or {} end
-- A flagged Beat Patrol: one checkpoint, a 3 km jump in a second (the speed check), then the rest. Its row.
local function FlaggedPatrol(src, far)
    local ok, _, run = Draw(src, 'patrol', PATROL_OTHERS)
    if not ok or not run then return {} end
    local veh = W.TakeWheel(src, run)
    W.DriveCheckpoints(src, run, veh, 1, 1)
    Place(src, far)
    Secs(1)
    W.Objective(src, run, 1, W.CheckpointEv(2, veh))
    H.eq(run.flagged and run.flagged.reason, 'speed', ('%s: the jump flags the run'):format(CID[src]))
    W.DriveCheckpoints(src, run, veh, 2, #run.objectives[1].state.points, 20)
    Secs(3)
    return W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[src] })[1] or {}
end
local function InQueue(src, kind, id)
    -- the Admin UI's queue is the one with all = true (every department, the correction batches)
    local args = (src == 5 or src == 8) and { all = true } or nil
    for _, f in ipairs(H.reviewItems(Cb('review:getQueue', src, args), kind)) do
        if f.id == id or f.rowId == id then return true end
    end
    return false
end
local function Decide(src, payload)
    if src == 5 or src == 8 then payload.all = true end
    return Act('server:review:decide', src, payload)
end

do
    -- flagged: an admin's queue holds every department's flagged runs (Home counts them); he decides any of them
    local a = FlaggedPatrol(1, vec3(3000.0, 3000.0, 30.0))
    local b = FlaggedPatrol(2, vec3(-3000.0, 3000.0, 30.0))
    H.eq(Bit(a.flagged) and Bit(b.flagged), true, 'flagged: a SAST and a FIB run are flagged')
    H.ok(InQueue(5, 'flag', a.id) and InQueue(5, 'flag', b.id), 'flagged: both in the admin\'s Review queue')
    H.ok(InQueue(8, 'flag', b.id), 'flagged: ...and the second admin\'s')
    H.eq((Cb('admin:getHome', 5) or {}).queues.flagged, 2, 'flagged: Home counts two')
    W.Drop(5)
    W.Restart()
    W.Reconnect(5)
    H.ok(InQueue(5, 'flag', a.id), 'restart and reconnect: still in his queue')
    local ok, data = Decide(5, { type = 'flag', id = b.id, decision = 'approve' })
    H.eq(data, 'err.reason_required', 'flagged: a reason is needed')
    local paid0 = W.Paid(CID[2])
    ok, data = Decide(5, { type = 'flag', id = b.id, decision = 'approve', reason = 'Lag spike' })
    H.eq(ok, true, 'flagged: the admin approves the FIB run: ' .. tostring(data))
    H.eq(Row(b.id).cash_status, 'paid', 'flagged: its held cash is paid')
    H.eq(W.Paid(CID[2]), paid0 + 1, 'flagged: once')
    ok, data = Decide(8, { type = 'flag', id = b.id, decision = 'approve', reason = 'Me too' })
    H.eq(ok, false, 'flagged: the second admin\'s approve of it is refused (' .. tostring(data) .. ')')
    ok, data = Decide(5, { type = 'flag', id = a.id, decision = 'void', reason = 'Teleport' })
    H.eq(ok, true, 'flagged: the admin voids the SAST run: ' .. tostring(data))
    H.eq(Bit(Row(a.id).voided), true, 'flagged: voided')

    -- dispute: Ada disputes the void (one dispute per run); she drops; the admin approves it after a restart
    ok, data = Act('server:dispute', 6, { rowId = a.id, reason = 'not mine' })
    H.eq(ok, false, 'dispute: nobody disputes someone else\'s run (' .. tostring(data) .. ')')
    ok, data = Act('server:dispute', 1, { rowId = a.id, reason = 'My game crashed and put me across the map' })
    H.eq(ok, true, 'dispute: Ada disputes the void: ' .. tostring(data))
    local disputeId = type(data) == 'table' and (data.id or data.disputeId) or nil
    for _, d in ipairs(H.reviewItems(Cb('review:getQueue', 5, { all = true }), 'dispute')) do
        if d.rowId == a.id then disputeId = disputeId or d.id end
    end
    H.ok(disputeId ~= nil, 'dispute: in the admin\'s queue')
    H.eq((Cb('admin:getHome', 5) or {}).queues.disputes, 1, 'dispute: Home counts one open dispute')
    ok, data = Act('server:dispute', 1, { rowId = a.id, reason = 'again' })
    H.eq(ok, false, 'dispute: a second dispute of the same run is refused (' .. tostring(data) .. ')')
    W.Drop(1)
    W.Restart()
    ok, data = Decide(5, { type = 'dispute', id = disputeId, decision = 'approve', reason = 'Crash confirmed' })
    H.eq(ok, true, 'restart: the admin approves the dispute while she is offline: ' .. tostring(data))
    W.Reconnect(1)
    Secs(5)
    H.eq(Bit(Row(a.id).voided), false, 'dispute: the run is restored')
    H.eq(Row(a.id).cash_status, 'paid', 'dispute: back online, its held cash is paid')
end

do
    -- corrections: give points (a supervisor cannot use it), the typed confirm above 500, void and restore a run,
    -- a bulk void with its preview, the Corrections list, its Undo; retire and unretire
    local xp0 = W.Xp(CID[6])
    -- one change about one officer per 10 s, whichever admin (opts.targetRate): the dialog waits it out
    local function Adjust(src, payload)
        Secs(10)
        payload.requestId = RequestId()
        return Act('server:admin:adjustPoints', src, payload)
    end
    local ok, data = Adjust(3, { citizenid = CID[6], points = 25, reason = 'x' })
    H.eq(ok, false, 'corrections: a supervisor cannot give points (' .. tostring(data) .. ')')
    ok, data = Adjust(5, { citizenid = CID[6], points = 25 })
    H.eq(data, 'err.reason_required', 'corrections: a reason is needed')
    ok, data = Adjust(5, { citizenid = CID[6], points = 600, reason = 'Event' })
    H.eq(data, 'err.confirm_mismatch', 'corrections: 600 points need the typed amount')
    ok, data = Adjust(5, { citizenid = CID[6], points = 25, reason = 'Helped at the event' })
    H.eq(ok, true, 'corrections: 25 points to Cleo: ' .. tostring(data))
    H.eq(W.Xp(CID[6]), xp0 + 25, 'corrections: her XP +25')
    local run = Patrol(6)
    local row = run and W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[6] })[1] or {}
    xp0 = W.Xp(CID[6])
    ok, data = Act('server:admin:voidRun', 5, { rowId = row.id, reason = 'Bugged course', kind = 'correction' })
    H.eq(ok, true, 'corrections: her patrol voided: ' .. tostring(data))
    H.eq(W.Xp(CID[6]), xp0 - tonumber(row.final_points), 'corrections: its XP gone')
    ok, data = Act('server:admin:voidRun', 5, { rowId = row.id, reason = 'Again', kind = 'correction' })
    H.eq(ok, false, 'corrections: voiding it twice is refused (' .. tostring(data) .. ')')
    W.Restart()
    ok, data = Act('server:admin:restoreRun', 5, { rowId = row.id, reason = 'Course was fine' })
    H.eq(ok, true, 'restart: restored: ' .. tostring(data))
    H.eq(W.Xp(CID[6]), xp0, 'corrections: her XP back')
    -- bulk void of Dan's runs with its preview, then the batch's Undo from Corrections
    Patrol(7)
    Patrol(7)
    local filter = { citizenid = CID[7], allTime = true }
    local pv = Cb('admin:previewBulkVoid', 5, { filter = filter })
    H.ok(pv and pv.total == 2 and pv.previewToken, 'corrections: the bulk void preview shows his two runs')
    ok, data = Act('server:admin:bulkVoid', 5,
        { filter = filter, reason = 'Bugged week', confirm = 'VOID 2', requestId = RequestId() })
    H.eq(ok, false, 'corrections: no preview token: refused (' .. tostring(data) .. ')')
    pv = Cb('admin:previewBulkVoid', 5, { filter = filter })
    ok, data = Act('server:admin:bulkVoid', 5, {
        filter = filter,
        reason = 'Bugged week',
        confirm = 'VOID 2',
        previewToken = pv and pv.previewToken,
        requestId = RequestId(),
    })
    H.eq(ok, true, 'corrections: the bulk void runs: ' .. tostring(data))
    local batchId = type(data) == 'table' and data.jobId or nil
    Secs(5)
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 1', { CID[7] }), 2,
        'corrections: both voided')
    local bk = Cb('admin:getCorrections', 5, { citizenid = CID[7] })
    local listed = false
    for _, b in ipairs(bk and bk.batches or {}) do if b.id == batchId then listed = true end end
    H.ok(listed, 'corrections: the batch is on the Corrections list')
    H.ok(InQueue(5, 'batch', batchId), 'corrections: ...and in the Review queue with its Undo (reviewBatchDays)')
    W.Restart()
    ok, data = Act('server:admin:restoreBatch', 5, { batchId = batchId, reason = 'Undo', requestId = RequestId() })
    H.eq(ok, true, 'restart: the batch is restored: ' .. tostring(data))
    Secs(5)
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 1', { CID[7] }), 0,
        'corrections: both back')
    ok, data = Act('server:admin:restoreBatch', 5, { batchId = batchId, reason = 'Again', requestId = RequestId() })
    H.eq(ok, false, 'corrections: a batch is restored once (' .. tostring(data) .. ')')
    -- retire and unretire: the preview, the typed citizenid; the tablet refused while retired
    pv = Cb('admin:previewRetire', 5, { citizenid = CID[7] })
    ok, data = Act('server:admin:retireOfficer', 5, {
        citizenid = CID[7],
        reason = 'Left the server',
        confirm = CID[7],
        previewToken = pv and pv.previewToken,
        requestId = RequestId(),
    })
    H.eq(ok, true, 'corrections: Dan retired: ' .. tostring(data))
    Secs(5)
    local s, why = Open(7)
    H.eq(why, 'err.retired', 'corrections: his tablet is refused')
    ok, data = Act('server:admin:unretireOfficer', 5,
        { citizenid = CID[7], reason = 'Came back', requestId = RequestId() })
    H.eq(ok, true, 'corrections: unretired: ' .. tostring(data))
    Secs(5)
    H.ok(Open(7) ~= nil, 'corrections: his tablet opens again')
end

do
    -- restrictions: the one list (a suspension, a mission ban); the admin lifts and extends; a supervisor cannot
    -- lift a suspension
    local ok, err = Act('server:admin:suspend', 5, { citizenid = CID[6], days = 1, reason = 'Cooling off' })
    H.eq(ok, true, 'restrictions: Cleo suspended a day: ' .. tostring(err))
    local rs = Cb('admin:getRestrictions', 5, {})
    local row
    for _, r in ipairs(rs and rs.rows or {}) do
        if r.kind == 'suspension' and r.citizenid == CID[6] then row = r end
    end
    H.ok(row ~= nil, 'restrictions: listed')
    Secs(3)
    ok, err = Act('server:restriction', 3, { op = 'lift', kind = 'suspension', citizenid = CID[6], reason = 'x' })
    H.eq(ok, false, 'restrictions: a supervisor cannot lift a suspension (' .. tostring(err) .. ')')
    Secs(3)
    ok, err = Act('server:restriction', 5,
        { op = 'extend', kind = 'suspension', citizenid = CID[6], hours = 24, reason = 'Another day' })
    H.eq(ok, true, 'restrictions: extended a day: ' .. tostring(err))
    W.Restart()
    Secs(3)
    ok, err = Act('server:restriction', 5, { op = 'lift', kind = 'suspension', citizenid = CID[6], reason = 'Done' })
    H.eq(ok, true, 'restart: lifted: ' .. tostring(err))
    H.ok(Open(6) ~= nil, 'restrictions: her tablet opens again')
    Act('server:admin:resetSetting', 5, { path = 'AdminUi.restrictionsExtend', reason = 'WF5C' })
    ok = Setting('AdminUi.restrictionsExtend', false)
    Act('server:admin:suspend', 5, { citizenid = CID[6], days = 1, reason = 'Again' })
    Secs(3)
    ok, err = Act('server:restriction', 5,
        { op = 'extend', kind = 'suspension', citizenid = CID[6], hours = 24, reason = 'More' })
    H.eq(ok, false, 'restrictions: Extend switched off is refused (' .. tostring(err) .. ')')
    Secs(3)
    Act('server:restriction', 5, { op = 'lift', kind = 'suspension', citizenid = CID[6], reason = 'Done' })
    Act('server:admin:resetSetting', 5, { path = 'AdminUi.restrictionsExtend', reason = 'WF5C' })
end

do
    -- the audit log: every change of this walk is there; filters; the export (a latent reply); Save to server
    local page, err = Cb('admin:getAudit', 5, { action = 'suspend' })
    H.ok(page and #(page.rows or page.entries or {}) >= 2, 'audit: the suspensions listed: ' .. tostring(err))
    page, err = Cb('admin:getAudit', 3, {})
    H.eq(page, nil, 'audit: a supervisor is refused (' .. tostring(err) .. ')')
    Secs(6)
    local reply, sent = H.callbackLatent('crimson-police:admin:exportAudit', 5, { action = 'voidRun' }, 'wf5c1')
    local ex = sent and sent[1] and sent[1].args[3]
    H.ok(reply and reply.ok and type(ex) == 'table' and type(ex.csv) == 'string' and ex.rows >= 1,
        'audit: the export comes with its rows')
    local ok, res = Act('server:admin:saveAuditExport', 5, { filters = {} })
    H.ok(ok == true and type(res) == 'table' and res.path:match('^saves/exports/audit%-') ~= nil,
        'audit: Save to server writes saves/exports/audit-<time>.csv: ' .. tostring(res))
    ok, res = Act('server:admin:saveAuditExport', 3, { filters = {} })
    H.eq(ok, false, 'audit: a supervisor cannot save one (' .. tostring(res) .. ')')
end

-- ============================================================================
--                                  6. SYSTEM
-- ============================================================================
-- SETTINGS, PRESETS, STORAGE, BACKUPS, JOBS, PROBLEMS, SETUP.

do
    -- one setting: the gear's Settings view, a save, its history, a revert, a reset; a supervisor refused
    local view, err = Cb('admin:getSettings', 5)
    H.ok(type(view) == 'table' and type(view.sections) == 'table', 'settings: the view opens: ' .. tostring(err))
    view, err = Cb('admin:getSettings', 3)
    H.eq(view, nil, 'settings: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Setting('Units.readyTimeout', 30)
    H.eq(ok, true, 'settings: a unit of at most three: ' .. tostring(err))
    ok, err = Setting('Units.readyTimeout', 'many')
    H.eq(ok, false, 'settings: a value of the wrong kind is refused (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setSetting', 5, { path = 'Units.readyTimeout', json = '{bad', reason = 'x' })
    H.eq(err, 'err.setting_json', 'settings: bad JSON is refused')
    ok, err = Setting('Nope.notASetting', 1)
    H.eq(ok, false, 'settings: an unknown setting is refused (' .. tostring(err) .. ')')
    local hist = Cb('admin:getSettingsHistory', 5, { path = 'Units.readyTimeout' })
    local last = hist and hist.rows and hist.rows[1]
    H.ok(last ~= nil and last.newValue == '30', 'settings: the history has the change')
    W.Restart()
    H.eq(Config.Units.readyTimeout, 30, 'restart: kept')
    ok, err = Act('server:admin:revertSetting', 5, { historyId = last and last.id })
    H.eq(err, 'err.reason_required', 'settings: Revert needs a reason')
    ok, err = Act('server:admin:revertSetting', 5, { historyId = last and last.id, reason = 'Too long' })
    H.eq(ok, true, 'settings: reverted: ' .. tostring(err))
    H.eq(Config.Units.readyTimeout, 20, 'settings: back to 20')
    ok, err = Setting('Units.readyTimeout', 40)
    ok, err = Act('server:admin:resetSetting', 5, { path = 'Units.readyTimeout', reason = 'WF5C' })
    H.eq(ok, true, 'settings: reset to config.lua: ' .. tostring(err))
    H.eq(Config.Units.readyTimeout, 20, 'settings: config.lua\'s 20')
    -- the settings that only config.lua sets: admins, storage, webhooks
    for _, path in ipairs({ 'AdminAce', 'Database.enabled' }) do
        ok, err = Setting(path, path == 'AdminAce' and 'x' or true)
        H.eq(ok, false, ('settings: %s is config.lua only (%s)'):format(path, tostring(err)))
    end
    -- export and import: the export carries the changes; an import of a non-export refused
    local ex = Cb('admin:exportSettings', 5)
    H.ok(type(ex) == 'table', 'settings: exported')
    local pvI
    pvI, err = Cb('admin:previewSettingsImport', 5, { json = '{"hello":1}' })
    H.eq(pvI, nil, 'settings: an import of something else is refused (' .. tostring(err) .. ')')
end

do
    -- presets: the preview lists every change, a supervisor refused, Go-live applied, then reset back
    local pv, err = Cb('admin:previewPreset', 5, { preset = 'golive' })
    H.ok(pv and type(pv.changes) == 'table' and #pv.changes >= 1, 'presets: Go-live\'s preview: ' .. tostring(err))
    pv, err = Cb('admin:previewPreset', 3, { preset = 'golive' })
    H.eq(pv, nil, 'presets: a supervisor is refused (' .. tostring(err) .. ')')
    pv, err = Cb('admin:previewPreset', 5, { preset = 'nope' })
    H.eq(pv, nil, 'presets: an unknown preset (' .. tostring(err) .. ')')
    Secs(6)
    local ok, res = Act('server:admin:applyPreset', 5, { preset = 'golive' })
    H.ok(ok == true and type(res) == 'table' and res.preset and res.preset.changed >= 2,
        'presets: Go-live applied: ' .. tostring(res))
    H.eq(Config.Debug, false, 'presets: Debug off')
    H.eq(Config.Payouts.requireReason, true, 'presets: a reason for pay changes')
    W.Restart()
    H.eq(Config.Debug, false, 'restart: Debug still off')
    Secs(6)
    ok, res = Act('server:admin:applyPreset', 5, { preset = 'golive' })
    H.ok(ok == true and res.preset.changed == 0, 'presets: applied again: nothing left to change')
    for _, path in ipairs({ 'Debug', 'Testing.allowTeleport', 'Testing.debugOverlay', 'Payouts.requireReason' }) do
        Act('server:admin:resetSetting', 5, { path = path, reason = 'WF5C' })
    end
    H.eq(Config.Debug, true, 'presets: back to the shipped Debug on')
    -- a city's own preset saved in game, previewed and applied
    local ok2, err2 = Setting('AdminUi.presets', { quiet = { { path = 'Npc.tellHints', value = false } } })
    H.eq(ok2, true, 'presets: a preset of his own: ' .. tostring(err2))
    pv = Cb('admin:previewPreset', 5, { preset = 'quiet' })
    H.ok(pv and #pv.changes == (Config.Npc.tellHints == false and 0 or 1), 'presets: its preview')
    Act('server:admin:resetSetting', 5, { path = 'AdminUi.presets', reason = 'WF5C' })
end

do
    -- storage: the panel (the saves folder, as shipped); a switch without the typed SWITCH refused; a supervisor
    -- refused (the copy itself: full (12) and storage_copy_spec)
    local st, err = Cb('admin:getStorage', 5)
    H.ok(type(st) == 'table', 'storage: the panel opens: ' .. tostring(err))
    st, err = Cb('admin:getStorage', 3)
    H.eq(st, nil, 'storage: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Act('server:admin:setStorageMode', 5, { mode = 'database', reason = 'x', requestId = RequestId() })
    H.eq(err, 'err.confirm_mismatch', 'storage: Switch needs the typed SWITCH')
    H.eq(Config.Database.enabled, false, 'storage: still the saves folder')
end

do
    -- the jobs screen: the list, Run now of the clean-up job (a reason), a job that cannot run by hand refused
    local jobs, err = Cb('admin:getJobs', 5)
    H.ok(type(jobs) == 'table' and #(jobs.jobs or {}) >= 5, 'jobs: the screen lists the timed jobs: ' .. tostring(err))
    jobs, err = Cb('admin:getJobs', 3)
    H.eq(jobs, nil, 'jobs: a supervisor is refused (' .. tostring(err) .. ')')
    local ok
    ok, err = Act('server:admin:runJobNow', 5, { id = 'cleanup' })
    H.eq(err, 'err.reason_required', 'jobs: Run now needs a reason')
    ok, err = Act('server:admin:runJobNow', 5, { id = 'nope', reason = 'x' })
    H.eq(err, 'err.job_unknown', 'jobs: an unknown job')
    ok, err = Act('server:admin:runJobNow', 5, { id = 'cleanup', reason = 'Disk is full' })
    H.eq(ok, true, 'jobs: the clean-up job runs now: ' .. tostring(err))
    ok, err = Act('server:admin:runJobNow', 5, { id = 'cleanup', reason = 'Again' })
    H.eq(err, 'err.rate_limited', 'jobs: not twice in a row')
    -- problems: the list opens
    local pr
    pr, err = Cb('admin:getProblems', 5)
    H.ok(type(pr) == 'table', 'problems: the list opens: ' .. tostring(err))
end

do
    -- the first-start setup: off as shipped; on, Home shows it; skip refused to a supervisor; finish; restart
    H.eq((Cb('admin:getHome', 5) or {}).setup, false, 'setup: not shown as shipped')
    H.eq(Setting('AdminUi.setupScreen', true), true, 'setup: the screen switched on')
    H.eq((Cb('admin:getHome', 5) or {}).setup, true, 'setup: Home opens on it')
    local s, err = Cb('admin:getSetup', 5)
    H.ok(type(s) == 'table', 'setup: its answers open: ' .. tostring(err))
    local ok
    ok, err = Act('server:admin:finishSetup', 3, { skip = true })
    H.eq(ok, false, 'setup: a supervisor cannot skip it (' .. tostring(err) .. ')')
    W.Drop(5)
    W.Restart()
    W.Reconnect(5)
    H.eq((Cb('admin:getHome', 5) or {}).setup, true, 'restart and reconnect: still shown')
    ok, err = Act('server:admin:finishSetup', 5,
        { departments = { sast = { supervisorGrade = 3 } }, preset = 'casual' })
    H.eq(ok, true, 'setup: finished with the casual preset: ' .. tostring(err))
    H.eq((Cb('admin:getHome', 5) or {}).setup, false, 'setup: no longer shown')
    W.Restart()
    H.eq((Cb('admin:getHome', 5) or {}).setup, false, 'restart: still done')
    for _, path in ipairs({
        'AdminUi.setupScreen',
        'AdminUi.setupDone',
        'Route.required',
        'Npc.tellHints',
        'Decisions.confirmKnownErrors',
        'Decisions.debrief',
    }) do
        Act('server:admin:resetSetting', 5, { path = path, reason = 'WF5C' })
    end
end

-- ============================================================================
--      7. BACKUPS AND RESTORE, AND THE MAINTENANCE LOCK THE RESTORE HOLDS
-- ============================================================================

do
    local ok, res = Act('server:admin:backupNow', 3, {})
    H.eq(ok, false, 'backup: a supervisor cannot make one (' .. tostring(res) .. ')')
    ok, res = Act('server:admin:backupNow', 5, {})
    H.ok(ok == true and type(res) == 'table' and res.name ~= nil, 'backup: the admin makes one: ' .. tostring(res))
    local name = res and res.name
    local list = Cb('admin:getBackups', 5)
    H.ok(list and #(list.backups or {}) >= 1, 'backup: listed')
    local pv = Cb('admin:previewRestore', 5, { name = name })
    H.ok(pv and pv.previewToken, 'restore: the preview')
    ok, res = Act('server:admin:restoreBackup', 5, {
        name = name,
        previewToken = pv and pv.previewToken,
        reason = 'x',
        confirm = 'restor',
        requestId = RequestId(),
    })
    H.eq(res, 'err.confirm_mismatch', 'restore: needs the typed RESTORE')
    pv = Cb('admin:previewRestore', 5, { name = name })
    ok, res = Act('server:admin:restoreBackup', 5, {
        name = name,
        previewToken = pv and pv.previewToken,
        reason = 'WF5C',
        confirm = 'RESTORE',
        requestId = RequestId(),
    }, 400)
    H.ok(ok == true and type(res) == 'table' and res.restart == true, 'restore: done, a restart asked')
    H.eq(CP.Maintenance.active(), 'restore', 'lock: the maintenance lock holds until the restart')

    -- every admin change is refused while it holds; the screens still read
    local refused = {
        { 'server:admin:setSetting', { path = 'Units.readyTimeout', json = '30', reason = 'x' } },
        { 'server:admin:setMissionEnabled', { missionId = 'beat_patrol', enabled = false } },
        { 'server:admin:setTypePayout', { type = 'patrol', amount = 300, reason = 'x' } },
        { 'server:admin:suspend', { citizenid = CID[7], days = 1, reason = 'x' } },
        { 'server:admin:adjustPoints', { citizenid = CID[7], points = 5, reason = 'x', requestId = RequestId() } },
        { 'server:admin:addDeskHere', { label = 'x', size = { x = 1, y = 1, z = 1 } } },
        { 'server:admin:applyPreset', { preset = 'golive' } },
        { 'server:admin:runJobNow', { id = 'cleanup', reason = 'x' } },
        { 'server:admin:backupNow', {} },
        { 'server:admin:startTest', { missionId = 'beat_patrol', location = 1 } },
        { 'server:builder:duplicate', { id = 'beat_patrol', label = 'Locked' } },
    }
    for _, r in ipairs(refused) do
        Secs(1)
        ok, res = Act(r[1], 5, r[2])
        H.eq(ok, false, ('lock: %s refused (%s)'):format(r[1], tostring(res)))
    end
    H.eq(Config.Units.readyTimeout, 20, 'lock: nothing changed')
    for _, name2 in ipairs({
        'admin:getHome',
        'admin:getSettings',
        'admin:getPayments',
        'admin:getAudit',
        'admin:getStorage',
        'admin:getJobs',
        'admin:getBackups',
    }) do
        H.ok(Cb(name2, 5, {}) ~= nil, ('lock: %s still reads'):format(name2))
    end
    local okA, why = Draw(1, 'patrol', PATROL_OTHERS)
    H.eq(okA, false, 'lock: no new run (' .. tostring(why) .. ')')
    W.Drop(5)
    W.Reconnect(5)
    W.Restart()
    H.eq(CP.Maintenance.active(), nil, 'restart: the lock is gone')
    ok, res = Setting('Units.readyTimeout', 30)
    H.eq(ok, true, 'restart: settings change again')
    Act('server:admin:resetSetting', 5, { path = 'Units.readyTimeout', reason = 'WF5C' })
    okA = Draw(1, 'patrol', PATROL_OTHERS)
    H.eq(okA, true, 'restart: runs start again')
    Leave(1)
    ok, res = Act('server:admin:deleteBackup', 5, { name = name, reason = 'Old', confirm = name })
    H.eq(ok, true, 'backup: deleted: ' .. tostring(res))
end

_G.print = W.realPrint

return H
