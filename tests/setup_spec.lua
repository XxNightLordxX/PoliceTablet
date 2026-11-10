-- Admin UI -> Home's First-start setup (SALE3, modules/admin/setup): shipped off (Home as before); with

-- Admin UI -> Home's First-start setup (SALE3, modules/admin/setup): shipped off (Home as before); with
-- Config.AdminUi.setupScreen on it shows to admins until one finishes or skips it. What it shows (departments, the
-- Qbox police jobs, desks, storage, the scripts found, the presets) and how each answer becomes ordinary settings,
-- saved and audited, with the preset applied after.

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: modules/access/permissions, modules/admin (cp_audit), modules/admin/adminkit, modules/admin/settings,
-- modules/admin/adminhome, modules/admin/setup. Stand-ins: CP.Access, CP.Qbx (qbx_core's own police jobs) and
-- CP.Integrations.

local LADDER = {
    [0] = { name = 'Recruit' },
    [1] = { name = 'Officer' },
    [2] = { name = 'Sergeant' },
    [3] = { name = 'Lieutenant' },
    [4] = { name = 'Chief', isboss = true },
}
-- qbx_core shared/jobs.lua: police (LSPD), bcso and sasp are type 'leo'; ambulance is not
local JOBS = {
    police = { label = 'LSPD', type = 'leo', grades = LADDER },
    bcso = { label = 'BCSO', type = 'leo', grades = LADDER },
    sasp = { label = 'SASP', type = 'leo', grades = LADDER },
    ambulance = { label = 'EMS', type = 'ems', grades = LADDER },
    sast = { label = 'SAST', grades = LADDER },
}

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
H.players[2] = { ace = {} }
CP.Access = {
    isAdmin = function(src) return src == 0 or src == 1 end,
    isSupervisor = function() return false end,
    getOfficer = function() return nil, 'err.not_police' end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = ('SUP%05d'):format(src), name = 'Admin ' .. src } end,
    getJobs = function() return JOBS end,
}
CP.Tablet = { push = function() end }
CP.Runs = {
    all = function() return {} end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
CP.Integrations = {
    ORDER = { dispatch = { 'sc-dispatch', 'ps-dispatch' }, banking = { 'Renewed-Banking' } },
    status = function()
        return {
            { kind = 'dispatch', setting = 'auto', active = 'sc-dispatch' },
            { kind = 'banking', setting = 'auto', active = nil, why = 'missing' },
        }
    end,
}
H.sql('DELETE FROM cp_settings')
H.sql('DELETE FROM cp_audit')
H.load('modules/admin/adminkit.lua')
H.load('modules/access/permissions.lua')
H.load('modules/admin/admin.lua')
H.load('modules/admin/settings.lua')
H.load('modules/admin/adminhome.lua')
H.load('modules/admin/setup.lua')
H.step(0)
local S, Setup, Kit = CP.Settings, CP.Setup, CP.AdminKit
H.ok(S.isLoaded(), 'the settings load')

-- an admin action as the net handler runs it (in a thread: the audit row is written with an await)
local function Run(name, src, payload)
    local res
    CreateThread(function() res = table.pack(Kit.run(name, src, payload)) end)
    return table.unpack(res or {}, 1, res and res.n or 0)
end

local function Audits(action)
    return H.sql(('SELECT action, target, new_value, reason FROM cp_audit WHERE action = \'%s\''):format(action))
end

-- ============================================================================
--                           SHIPPED: HOME AS BEFORE
-- ============================================================================

H.eq(Config.AdminUi.setupScreen, false, 'setupScreen ships false (Home opens on its dashboard, as before)')
H.eq(Config.AdminUi.setupDone, false, 'setupDone ships false')
H.eq(Setup.pending(), false, 'shipped: the setup never shows')
H.eq(CP.AdminHome.home(1).setup, false, 'Home says so')
H.ok((S.entry('AdminUi.setupScreen').desc or ''):find('First-start setup', 1, true) ~= nil,
    'setupScreen is a setting with its plain description')
H.eq(S.entry('AdminUi.setupDone').kind, 'boolean', 'setupDone is an on/off setting')

H.ok(S.set(0, 'AdminUi.setupScreen', true), 'an admin turns it on')
H.eq(Setup.pending(), true, 'on and not done: it shows')
H.eq(CP.AdminHome.home(1).setup, true, 'Home shows it')

-- ============================================================================
--                                WHAT IT SHOWS
-- ============================================================================

do
    local v = Setup.view()
    local keys = {}
    for _, d in ipairs(v.departments) do keys[#keys + 1] = d.key .. ':' .. table.concat(d.jobs, '+') end
    H.eq(table.concat(keys, ','), 'fib:fib,sast:sast', 'config.lua\'s departments with their jobs')
    local jobs = {}
    for _, j in ipairs(v.jobs) do jobs[#jobs + 1] = j.name .. (j.department and ('>' .. j.department) or '') end
    H.eq(table.concat(jobs, ','), 'bcso,police,sasp,sast>sast',
        'the Qbox police jobs and the jobs a department lists (not EMS)')
    H.eq(#v.jobs[1].grades, 5, 'each with its grades')
    H.eq(v.jobs[1].grades[5].boss, true, 'the boss grade is marked')
    H.eq(#v.desks, #Config.Tablet.desks, 'every desk')
    H.eq(v.desks[1].label, 'Mission Row PD front desk', 'by label')
    H.eq(v.storage.database, Config.Database.enabled == true, 'where data is saved')
    H.ok(v.storage.copyCommand:find('storage copy', 1, true) ~= nil, 'and the copy command')
    H.eq(v.integrations[1].active, 'sc-dispatch', 'the scripts found')
    H.eq(v.integrations[2].why, 'missing', 'and the ones missing')
    H.ok(#v.integrations[1].options >= 3, 'with the choices of each')
    local presets = {}
    for _, p in ipairs(v.presets) do presets[#presets + 1] = p.key end
    H.eq(table.concat(presets, ','), 'casual,serious,golive', 'the presets')
end

-- ============================================================================
--                           ANSWERS THAT ARE REFUSED
-- ============================================================================

do
    local _, e1 = Setup.changes({ departments = { nope = { supervisorGrade = 2 } } })
    H.eq(e1, 'err.dept_unknown', 'an unknown department is refused')
    local _, e2 = Setup.changes({ add = { 'ambulance_x' } })
    H.eq(e2, 'err.dept_key', 'a job Qbox does not have is refused')
    local _, e3 = Setup.changes({ add = { 'sast' } })
    H.eq(e3, 'err.dept_exists', 'a department key that exists is refused')
    local _, e4 = Setup.changes({ desks = { 99 } })
    H.eq(e4, 'err.invalid_payload', 'a desk that does not exist is refused')
    local _, e5 = Setup.changes({ departments = { sast = { jobs = {} } } })
    H.eq(e5, 'err.invalid_payload', 'a department needs a job')
    H.eq(#Setup.changes({ departments = { sast = { supervisorGrade = 3 } } }), 0, 'an unchanged answer changes nothing')
end

-- ============================================================================
--                                    FINISH
-- ============================================================================

do
    local ok, err = Run('server:admin:finishSetup', 2, { skip = true })
    H.eq(ok, false, 'only admins finish or skip it')
    H.eq(err, 'err.no_permission', 'refused for a player')

    local desks = #Config.Tablet.desks
    local okF, res = Run('server:admin:finishSetup', 1, {
        departments = { sast = { jobs = { 'sast', 'sasp' }, supervisorGrade = 4 } },
        add = { 'police' },
        desks = { 1, 3 },
        integrations = { banking = 'none' },
        preset = 'casual',
    })
    H.ok(okF, 'finished: ' .. tostring(res))
    H.eq(res.changed, 5, 'five settings changed (jobs, grade, the new department, desks, banking)')
    H.eq(table.concat(Config.Departments.sast.jobs, ','), 'sast,sasp', 'the department\'s jobs')
    H.eq(Config.Departments.sast.supervisorGrade, 4, 'its supervisor grade')
    H.eq(Config.Departments.police.label, 'LSPD', 'a department for the Qbox police job, named after it')
    H.eq(Config.Departments.police.supervisorGrade, 4, 'supervising from the job\'s boss grade')
    H.eq(table.concat(Config.Departments.police.jobs, ','), 'police', 'with that job')
    H.eq(#Config.Tablet.desks, 2, 'one desk of ' .. desks .. ' left out')
    H.eq(Config.Integrations.banking, 'none', 'the banking script choice')
    H.eq(res.preset and res.preset.key, 'casual', 'the preset applied after')
    H.eq(Config.Npc.tellHints, true, 'the preset\'s settings are set')
    H.eq(Config.AdminUi.setupDone, true, 'marked done')
    H.eq(Setup.pending(), false, 'it no longer shows')
    local a = Audits('setupFinished')
    H.eq(#a, 1, 'one audit line for the setup')
    local row = H.sql('SELECT reason FROM cp_audit WHERE target = \'Integrations.banking\' ORDER BY id DESC LIMIT 1')[1]
    H.eq(row and row.reason, 'First-start setup', 'each answer is an ordinary setting change with the setup as reason')
    H.eq(#S.addedDepartments(), 1, 'the new department is an in-game department (Departments edits it)')
end

-- ============================================================================
--                               SKIP, AND AGAIN
-- ============================================================================

do
    H.ok(S.set(0, 'AdminUi.setupDone', false), 'setupDone back to false: it shows again')
    H.eq(Setup.pending(), true, 'shows again')
    H.clockMs = H.clockMs + 5000
    local ok, res = Run('server:admin:finishSetup', 1, { skip = true })
    H.ok(ok and res.changed == 0, 'skipped: nothing else changes')
    H.eq(Setup.pending(), false, 'skipped: it no longer shows')
    H.eq(#Audits('setupSkipped'), 1, 'one audit line for the skip')
end

H.sql('DELETE FROM cp_settings')
H.sql('DELETE FROM cp_audit')
return H
