-- Mission cooldowns as Mission controls (step P2): cooldownScale (x every mission's cooldown, per mission type) and

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', stopped = { ox_inventory = true } })

-- ============================================================================
--                                  THE SERVER
-- ============================================================================

local people = {
    [1] = {
        cid = 'CDA00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [2] = { cid = 'CDS00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [3] = { cid = 'CDO00003', license = 'license:cccccccccccccccccccccccccccccccccccccc3', job = 'sast', grade = 0 },
    [4] = { cid = 'CDF00004', license = 'license:dddddddddddddddddddddddddddddddddddddd4', job = 'fib', grade = 0 },
    [5] = { cid = 'CDF00005', license = 'license:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee5', job = 'fib', grade = 4 },
}
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
end
local function Info(src)
    local p = people[src]
    if not p then return nil end
    return {
        src = src,
        citizenid = p.cid,
        license = p.license,
        name = 'Player ' .. src,
        job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
    }
end
CP.Qbx = {
    getInfo = Info,
    getByCitizenId = function(cid)
        for src, p in pairs(people) do if p.cid == cid then return src end end
        return nil
    end,
    getOnlinePlayers = function() return { 1, 2, 3, 4, 5 } end,
    licenseOf = function(cid)
        for _, p in pairs(people) do if p.cid == cid then return p.license end end
        return nil
    end,
    citizenidsOfLicense = function() return {} end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
local mission = { id = 'cd_mission', type = 'tactical', cooldown = 1200 }
CP.Missions = {
    reload = function() end,
    get = function(id) if id == mission.id then return mission end end,
    all = function() return { [mission.id] = mission } end,
}
CP.Alerts = {
    foreignClearedAt = {},
    foreignFlag = function() return false end,
    inArena = function() return false end,
}

for _, t in ipairs({ 'cp_audit', 'cp_settings', 'cp_officers', 'cp_dept_controls', 'cp_mission_runs' }) do
    H.sql('DELETE FROM ' .. t)
end
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)   -- align os.time() with NOW()

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/deptcontrols/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/runs/server.lua',
}) do
    H.load(m)
end
H.step(0)

local DC, Runs, U = CP.DeptControls, CP.Runs, CP.U
local CID = {}
for src, p in pairs(people) do CID[src] = p.cid end

-- a quit of the tactical mission that ended now: a 1200 s mission cooldown and the abandon type cooldown
local function Quit(cid)
    MySQL.insert.await([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base) VALUES (?, 'tactical', 'cd_mission', ?, 'sast', 'abandoned', 'quit', 200)]],
        { 'cd-' .. cid, cid })
end
local ended = H.time
for src = 1, 5 do Quit(CID[src]) end
local ABANDON = Config.Limits.abandonCooldown or 300

local function Left(src, part, key, reader)
    local u = Runs.cooldowns(CID[src], reader and { officer = reader } or nil)[part][key]
    return u and u - ended or nil
end
local function Officer(src) return { citizenid = CID[src] } end
local function Forget() for src = 1, 5 do Runs._forgetOfficer(CID[src]) end end

-- ============================================================================
--                     1. SHIPPED: ON, NOTHING CHANGED YET
-- ============================================================================

do
    local b = Config.MissionControls.controls
    H.ok(b.cooldownScale and b.cooldownScale.on == true and b.cooldownScale.min == 0 and b.cooldownScale.max == 2,
        'cooldownScale ships on, 0-2')
    H.ok(
        b.abandonCooldown and b.abandonCooldown.on == true and b.abandonCooldown.min == 0
            and b.abandonCooldown.max == 900,
        'abandonCooldown ships on, 0-900 s'
    )
    H.eq(Config.Permissions.supervisor.missionControls, false, 'the master switch still ships off')
    H.ok(DC.def('cooldownScale').serverWide and not DC.def('cooldownScale').master, 'server-wide, outside the master')
    H.eq(Left(3, 'missions', 'cd_mission'), 1200, 'no change: the config cooldown')
    H.eq(Left(3, 'types', 'tactical'), ABANDON, 'no change: the config abandon cooldown')
    H.eq(Runs.cooldownScale('tactical'), 1, 'scale 1')
end

-- ============================================================================
--            2. A SAST SUPERVISOR HALVES TACTICAL: EVERY DEPARTMENT
-- ============================================================================

do
    local ok, err = DC.set(2, 'cooldownScale', { tactical = 3 }, 'busy night')
    H.ok(ok == false and err == 'err.control_value', 'above the admin max is refused')
    ok, err = DC.set(2, 'cooldownScale', { nosuchtype = 0.5 }, 'busy night')
    H.ok(ok == false and err == 'err.control_value', 'an unknown mission type is refused')
    ok, err = DC.set(3, 'cooldownScale', { tactical = 0.5 }, 'busy night')
    H.ok(ok == false, 'an officer cannot change it')
    ok, err = DC.set(2, 'cooldownScale', { tactical = 0.5 }, 'busy night')
    H.ok(ok == true, 'a supervisor changes it with the master switch off: ' .. tostring(err))
    local row = H.sql('SELECT department, set_by FROM cp_dept_controls WHERE control_key = ?', { 'cooldownScale' })[1]
    H.ok(row and row.department == '*' and row.set_by == CID[2], 'saved once for every department, with who set it')
    H.eq(Left(3, 'missions', 'cd_mission'), 600, 'a SAST officer\'s 1200 s cooldown ends after 600 s')
    H.eq(Left(4, 'missions', 'cd_mission'), 600, 'an FIB officer\'s too (server-wide)')
    H.eq(Left(2, 'missions', 'cd_mission'), 1200, 'the setter is held to 1200 s (self rule)')
    H.eq(Left(4, 'missions', 'cd_mission', { Officer(4), Officer(2) }), 1200,
        'a unit with the setter in it keeps the config cooldown')
    H.eq(Left(3, 'types', 'tactical'), ABANDON, 'the abandon type cooldown is not scaled')
    H.eq(Runs.cooldownScale('tactical'), 0.5, 'the screens read 0.5')
    Forget()
    H.eq(Left(3, 'missions', 'cd_mission'), 600, 'a restart (rebuild from the rows) keeps 600 s')
    H.ok(Runs.onCooldown(CID[3], 'tactical', 'cd_mission'), 'still on cooldown now')
    H.time = ended + 601
    H.eq(Runs.onCooldown(CID[3], 'patrol', 'cd_mission'), false, 'free after 600 s')
    H.ok(Runs.onCooldown(CID[2], 'patrol', 'cd_mission'), 'the setter is still held')
    H.time = ended
end

-- ============================================================================
--                 3. THE ABANDON COOLDOWN, ZERO, ABOVE 1, OFF
-- ============================================================================

do
    local ok, err = DC.set(5, 'abandonCooldown', 120, 'quiet shift')
    H.ok(ok == true, 'an FIB supervisor changes the abandon cooldown: ' .. tostring(err))
    H.eq(Left(3, 'types', 'tactical'), 120, 'every officer\'s abandon cooldown is 120 s')
    H.eq(Left(5, 'types', 'tactical'), ABANDON, 'the setter keeps the config one')
    ok = DC.set(5, 'abandonCooldown', 1000, 'x')
    H.ok(not ok, 'above the admin max is refused')

    H.time = ended + 301   -- the change wait of the control (300 s) has passed
    ok, err = DC.set(1, 'cooldownScale', { tactical = 0 }, 'happy hour test')
    H.ok(ok == true, 'an admin sets 0: ' .. tostring(err))
    H.eq(Runs.cooldowns(CID[3]).missions.cd_mission, nil, 'scale 0: no mission cooldown')

    ok, err = DC.set(1, 'cooldownScale', { tactical = 2 }, 'too many repeats')
    H.ok(ok == true, 'an admin doubles it: ' .. tostring(err))
    H.time = ended + 1300
    Runs._maintenance()
    H.eq(Left(3, 'missions', 'cd_mission'), 2400, 'x2: the entry is not pruned at 1200 s and ends after 2400 s')
    H.eq(Left(1, 'missions', 'cd_mission'), 2400, 'a raise applies to its setter too')
    Forget()
    H.eq(Left(3, 'missions', 'cd_mission'), 2400, 'and the rebuild reads rows that far back')

    Config.MissionControls.controls.cooldownScale.on = false
    H.eq(Runs.cooldowns(CID[3]).missions.cd_mission, nil, 'the admin switch off: back to config (spent at 1200 s)')
    Config.MissionControls.controls.cooldownScale.on = true
    H.time = ended
end

-- ============================================================================
--                               4. CONFIG CHECKS
-- ============================================================================

do
    H.eq(DC.checkConfig({ cooldownScale = { on = true, min = 0, max = 5 } }), 'err.control_config',
        'cooldownScale max above 4 is refused')
    H.eq(DC.checkConfig({ cooldownScale = { on = true, min = 0, max = 4 } }), nil, 'max 4 is fine')
    H.eq(DC.checkConfig({ abandonCooldown = { on = true, min = -1, max = 60 } }), 'err.control_config',
        'a negative abandon cooldown is refused')
    local d = Runs.cooldowns(CID[3])
    H.ok(U.contains({ 'table' }, type(d.types)) and type(d.missions) == 'table', 'the { types, missions } shape stays')
end

H.sql('DELETE FROM cp_dept_controls')
H.sql('DELETE FROM cp_mission_runs')

return H
