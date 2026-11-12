-- The generic example config on the real server, with its first-start setup.

-- The generic example config on the real server, with its first-start setup. The world of
-- tests/workflows_full_spec.lua booted on config/examples/generic.lua copied over
-- config.lua (CP_WF_CONFIG): a city sold the resource, its departments qbx_core's own police jobs (police, bcso, sasp,
-- supervising from grade 3), every other script 'auto', Home on the First-start setup, a fresh saves folder.
--   1. The first start: the setup shows to the admin (and to nobody else), what it found (the departments, the Qbox
--      police jobs, the storage, the scripts 'auto' found), a drop and a restart in the middle.
--   2. The setup finished: a department added from a Qbox job, a supervisor grade changed, a script picked, a
--      preset; refused answers; a restart keeps it all and Home opens as usual.
--   3. Playing on it: an LSPD officer's Beat Patrol paid, a BCSO supervisor's Department screen, the added department.

_G.CP_WF_WORLD = 'system_generic'
_G.CP_WF_CONFIG = 'config/examples/generic.lua'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD, _G.CP_WF_CONFIG = nil, nil
local H, CID, PD = W.H, W.CID, W.PD
local Cb, Act, Secs = W.Cb, W.Act, W.Secs

local function Open(src, ui) return Cb('getSession', src, { ui = ui or 'officer', via = 'command' }) end
local function Later() H.time = H.time + 3700 end

-- qbx_core shared/jobs.lua's police jobs (type 'leo'), Recruit 0 to Chief 4 (boss), and a sheriff's ranger job the
-- city added itself
local LADDER = {
    [0] = { name = 'Recruit' },
    [1] = { name = 'Officer' },
    [2] = { name = 'Sergeant' },
    [3] = { name = 'Lieutenant' },
    [4] = { name = 'Chief', isboss = true },
}
H.exportsMock.qbx_core.GetJobs = function()
    return {
        police = { label = 'LSPD', type = 'leo', grades = LADDER },
        bcso = { label = 'BCSO', type = 'leo', grades = LADDER },
        sasp = { label = 'SASP', type = 'leo', grades = LADDER },
        ranger = { label = 'Park Rangers', type = 'leo', grades = LADDER },
        unemployed = { label = 'Civilian', grades = { [0] = { name = 'Freelancer' } } },
    }
end
-- the players of the world in this city's jobs
local JOBS = {
    [1] = { 'police', 1 },
    [2] = { 'bcso', 1 },
    [3] = { 'police', 3 },
    [4] = { 'bcso', 3 },
    [6] = { 'sasp', 1 },
    [7] = { 'ranger', 1 },
}
for src, j in pairs(JOBS) do
    PD[src].job.name, PD[src].job.label, PD[src].job.type = j[1], j[1], 'leo'
    PD[src].job.grade = { level = j[2], name = LADDER[j[2]].name }
end
-- a fresh install: the saves folder empty, the server started on it
Secs(2)
TriggerEvent('onResourceStop', 'Crimson-Police')
H.restart()
os.execute(('rm -rf \'%s/saves\''):format(H.resourcePath()))
H.emptySaves = true
W.Boot()
H.emptySaves = nil
Secs(5)
for src in pairs(JOBS) do W.Reconnect(src) end

local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }

-- ============================================================================
--                     1. THE FIRST START, THE SETUP SHOWS
-- ============================================================================

do
    H.eq(CP.Migrations.status().pending, 0, 'fresh: every table built at start')
    H.eq(Config.AdminUi.setupScreen, true, 'generic: the First-start setup is on')
    H.eq(Config.Departments.police and Config.Departments.police.short, 'LSPD', 'generic: LSPD from qbx_core\'s police')
    H.eq(Config.Departments.sast, nil, 'generic: no owner department')
    for _, kind in ipairs(CP.Integrations.KINDS) do
        H.eq(Config.Integrations[kind], 'auto', 'generic: ' .. kind .. ' auto')
    end
    H.eq(Config.Database.enabled, W.ON_DB, 'generic: the store (the saves folder as shipped)')
    H.eq(Config.Debug, true, 'generic: Debug on as shipped')

    local home = Cb('admin:getHome', 5)
    H.eq(home and home.setup, true, 'setup: Home opens on it')
    local s, err = Cb('admin:getSetup', 5)
    H.ok(type(s) == 'table', 'setup: its answers open: ' .. tostring(err))
    local keys, jobs = {}, {}
    for _, d in ipairs(s and s.departments or {}) do keys[#keys + 1] = d.key .. ':' .. d.supervisorGrade end
    for _, j in ipairs(s and s.jobs or {}) do
        jobs[#jobs + 1] = j.name .. (j.department and ('>' .. j.department) or '')
    end
    H.eq(table.concat(keys, ' '), 'bcso:3 police:3 sasp:3', 'setup: the three departments, supervising from 3')
    H.eq(table.concat(jobs, ' '), 'bcso>bcso police>police ranger sasp>sasp', 'setup: the Qbox police jobs')
    H.eq(s and s.storage and s.storage.database, W.ON_DB, 'setup: the store (the saves folder as shipped)')
    local found = {}
    for _, i in ipairs(s and s.integrations or {}) do found[#found + 1] = i.kind .. ':' .. tostring(i.active) end
    H.eq(table.concat(found, ' '),
        'dispatch:sc-dispatch ambulance:sc-ambulance banking:Renewed-Banking police:sc-police',
        'setup: the scripts auto found')
    H.ok(s and #(s.presets or {}) >= 1, 'setup: the presets')

    -- nobody but an admin
    for _, src in ipairs({ 3, 4, 1 }) do
        local v, why = Cb('admin:getSetup', src)
        H.eq(v, nil, ('setup: %s cannot open it (%s)'):format(CID[src], tostring(why)))
        local ok = Act('server:admin:finishSetup', src, { skip = true })
        H.eq(ok, false, ('setup: %s cannot skip it'):format(CID[src]))
    end
    -- the officers can already use the tablet (the setup only waits on Home)
    H.ok(Open(1) ~= nil, 'setup pending: the LSPD officer opens the tablet')
    H.eq(Open(7), nil, 'setup pending: the ranger is no officer yet')

    -- the admin quits half way, the server restarts: still shown
    W.Drop(5)
    W.Restart()
    W.Reconnect(5)
    H.eq((Cb('admin:getHome', 5) or {}).setup, true, 'restart and reconnect: still shown')
end

-- ============================================================================
--                            2. THE SETUP FINISHED
-- ============================================================================

do
    -- refused answers: an unknown department, a job Qbox does not have, a department that exists, a bad script
    for _, bad in ipairs({
        { { departments = { sast = { supervisorGrade = 3 } } }, 'err.dept_unknown' },
        { { add = { { job = 'nope' } } }, 'err.dept_key' },
        { { add = { { job = 'police' } } }, 'err.dept_exists' },
        { { add = { { job = 'ranger', themeFrom = 'fib' } } }, 'err.dept_unknown' },
    }) do
        local ok, err = Act('server:admin:finishSetup', 5, bad[1])
        H.eq(err, bad[2], 'setup: refused ' .. bad[2])
        H.eq(ok, false, 'setup: ...and not done')
    end
    H.eq(Config.AdminUi.setupDone, false, 'setup: still not done')
    local ok, err = Act('server:admin:finishSetup', 5, {
        departments = { bcso = { supervisorGrade = 2 } },
        add = { { job = 'ranger', themeFrom = 'bcso' } },
        integrations = { ambulance = 'none' },
        preset = 'casual',
    })
    H.eq(ok, true,
        'setup: finished with a department added, a grade, a script and the casual preset: ' .. tostring(err))
    H.eq((Cb('admin:getHome', 5) or {}).setup, false, 'setup: Home opens as usual')
    H.eq(Config.Departments.bcso.supervisorGrade, 2, 'setup: BCSO supervises from 2')
    H.ok(Config.Departments.ranger ~= nil, 'setup: Park Rangers added')
    H.eq(Config.Departments.ranger and Config.Departments.ranger.supervisorGrade, 4, 'setup: ...its boss grade')
    H.eq(Config.Integrations.ambulance, 'none', 'setup: no ambulance script')
    H.eq(
        W.Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { 'setSetting' }) > 0
            or W.Count('SELECT COUNT(*) AS n FROM cp_settings_history') > 0,
        true,
        'setup: saved as settings, audited'
    )
    ok = Act('server:admin:finishSetup', 5, { skip = true })
    W.Restart()
    H.eq((Cb('admin:getHome', 5) or {}).setup, false, 'restart: still done')
    H.eq(Config.Departments.bcso.supervisorGrade, 2, 'restart: BCSO still from 2')
    H.ok(Config.Departments.ranger ~= nil, 'restart: Park Rangers kept')
    H.eq(Config.Integrations.ambulance, 'none', 'restart: no ambulance script still')
end

-- ============================================================================
--                        3. PLAYING ON THE GENERIC CITY
-- ============================================================================

do
    -- an LSPD officer's Beat Patrol, paid
    Later()
    Config.DisabledMissions = PATROL_OTHERS
    local ok, why = Act('server:acceptType', 1, 'patrol')
    Config.DisabledMissions = {}
    H.eq(ok, true, 'play: the LSPD officer accepts Beat Patrol: ' .. tostring(why))
    local run = CP.Runs.getBySrc(1)
    if run then
        local veh = W.TakeWheel(1, run)
        W.DriveCheckpoints(1, run, veh)
        Secs(5)
    end
    local row = run and W.Rows('run_uuid = ?', { run.id })[1]
    H.eq(row and row.state, 'completed', 'play: completed')
    H.eq(row and row.cash_status, 'paid', 'play: paid')
    -- the BCSO officer of grade 3 supervises; the ranger is an officer of the added department
    local sess = Open(4)
    H.ok(sess ~= nil, 'play: the BCSO lieutenant opens the tablet')
    local today, terr = Cb('sup:getToday', 4)
    H.ok(today ~= nil, 'play: ...and the Department screen: ' .. tostring(terr))
    today = Cb('sup:getToday', 2)
    H.eq(today, nil, 'play: a BCSO officer of grade 1 is no supervisor')
    H.ok(Open(7) ~= nil, 'play: the ranger opens the tablet (Park Rangers)')
    W.Drop(7)
    W.Restart()
    W.Reconnect(7)
    H.ok(Open(7) ~= nil, 'restart and reconnect: the ranger still opens it')
end

_G.print = W.realPrint

return H
