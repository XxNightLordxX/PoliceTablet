-- Happy hour (step P6): a supervisor starts N minutes (inside the admin's min and max) with no mission cooldowns

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', stopped = { ox_inventory = true } })

-- ============================================================================
--                                  THE SERVER
-- ============================================================================

local people = {
    [1] = {
        cid = 'HHA00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [2] = { cid = 'HHS00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [3] = { cid = 'HHO00003', license = 'license:cccccccccccccccccccccccccccccccccccccc3', job = 'sast', grade = 0 },
    [4] = { cid = 'HHF00004', license = 'license:dddddddddddddddddddddddddddddddddddddd4', job = 'fib', grade = 0 },
    [5] = { cid = 'HHF00005', license = 'license:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee5', job = 'fib', grade = 4 },
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
local mission = { id = 'hh_mission', type = 'tactical', cooldown = 1200 }
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
    'modules/happyhour/server.lua',
    'modules/runs/server.lua',
}) do
    H.load(m)
end
H.step(0)

local DC, Runs, HH = CP.DeptControls, CP.Runs, CP.HappyHour
local CID = {}
for src, p in pairs(people) do CID[src] = p.cid end
-- the no-repeat control lives in modules/draw: the same registration, without the draw
if not DC.def('noRepeat') then
    DC.register('noRepeat', {
        kind = 'bool',
        serverWide = true,
        master = false,
        configValue = function() return true end,
        relaxes = function(v) return v == false end,
    })
end

-- a quit of the tactical mission that ended now: a 1200 s mission cooldown and the abandon type cooldown
local function Quit(cid)
    MySQL.insert.await([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base) VALUES (?, 'tactical', 'hh_mission', ?, 'sast', 'abandoned', 'quit', 200)]],
        { 'hh-' .. cid, cid })
end
local ended = H.time
for src = 1, 5 do Quit(CID[src]) end
local ABANDON = Config.Limits.abandonCooldown or 300

local function Left(src, part, key, reader)
    local u = Runs.cooldowns(CID[src], reader and { officer = reader } or nil)[part][key]
    return u and u - ended or nil
end
local function Officer(src) return { citizenid = CID[src], department = people[src].job } end
local function Forget() for src = 1, 5 do Runs._forgetOfficer(CID[src]) end end
-- the real actions (the screens' path): server:sup:setMissionControl, server:admin:resetMissionControl
local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'h' .. reqSeq
    payload.requestId = ('%08x-0000-4000-8000-%012x'):format(reqSeq, 92)
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end
local function Start(src, value, reason)
    local admin = people[src].ace
    return Act(admin and 'server:admin:setMissionControl' or 'server:sup:setMissionControl', src,
        { key = 'happyHour', value = value, reason = reason })
end
local changed = {}
CP.Hooks.on('deptControls:changed', function(e) changed[#changed + 1] = e end)

-- ============================================================================
--                       1. SHIPPED: ON, NOTHING RUNNING
-- ============================================================================

do
    local b = Config.MissionControls.controls.happyHour
    H.ok(b and b.on == true and b.min == 5 and b.max == 30, 'happyHour ships on, 5-30 minutes')
    H.eq(Config.MissionControls.happyHourPerDay, 1, 'once a day')
    H.ok(DC.def('happyHour').serverWide and not DC.def('happyHour').master, 'server-wide, outside the master switch')
    H.eq(HH.state(nil), nil, 'no happy hour')
    H.eq(Left(3, 'missions', 'hh_mission'), 1200, 'the config cooldown')
end

-- ============================================================================
--                    2. A SAST SUPERVISOR STARTS 15 MINUTES
-- ============================================================================

local started = ended
do
    local ok, err = Start(2, { minutes = 40, noRepeat = true }, 'quiet night')
    H.ok(ok == false and err == 'err.control_value', 'above the admin max is refused')
    ok, err = Start(2, { minutes = 15, bonus = 1 }, 'quiet night')
    H.ok(ok == false and err == 'err.control_value', 'an unknown field is refused')
    ok = Start(3, { minutes = 15 }, 'quiet night')
    H.ok(ok == false, 'an officer cannot start one')
    ok, err = Start(2, { minutes = 15, noRepeat = true }, 'quiet night')
    H.ok(ok == true, 'a supervisor starts 15 minutes: ' .. tostring(err))
    local row = H.sql([[SELECT department, set_by, UNIX_TIMESTAMP(expires_at) AS e FROM cp_dept_controls
        WHERE control_key = 'happyHour']])[1]
    H.ok(row and row.department == '*' and row.set_by == CID[2], 'one row for the whole server, with who set it')
    H.eq(tonumber(row and row.e), started + 900, 'it ends 15 minutes later')

    H.eq(Left(3, 'missions', 'hh_mission'), nil, 'a SAST officer\'s cooldown reads 0')
    H.eq(Runs.onCooldown(CID[3], 'patrol', 'hh_mission'), false, 'he may take the mission again')
    H.eq(Left(4, 'missions', 'hh_mission'), nil, 'an FIB officer\'s too (server-wide, owner decision)')
    H.eq(Left(2, 'missions', 'hh_mission'), 1200, 'the setter is not freed')
    H.eq(Left(4, 'missions', 'hh_mission', { Officer(4), Officer(2) }), 1200, 'nor a unit he is in')
    H.eq(Left(3, 'types', 'tactical'), ABANDON, 'the abandon type cooldown stays')
    H.eq(DC.get(nil, 'noRepeat', Officer(3)), false, 'ticked: the no-repeat rule is off')
    H.eq(DC.get(nil, 'noRepeat', Officer(2)), true, 'but not for the setter')

    local s = HH.state(Officer(3))
    H.ok(s and s.endsAt == started + 900 and s.minutes == 15 and s.noRepeat == true, 'the state the screens show')
    H.ok(s and s.by == 'Rank Player 2' and s.self == false, 'set by the sergeant, applies to the officer')
    H.eq(HH.state(Officer(2)).self, true, 'the setter is told it does not apply to him')
    H.ok(#changed > 0 and changed[#changed].key == 'happyHour', 'the readers hear the start')

    DC.clearCache()
    Forget()
    H.eq(Left(3, 'missions', 'hh_mission'), nil, 'a restart keeps the window')

    ok, err = Start(1, { minutes = 10 }, 'again')
    H.ok(ok == false and err == 'err.happy_hour_running', 'one at a time, admins too')
    local view = DC.view(2)
    local c
    for _, x in ipairs(view.serverWide) do if x.key == 'happyHour' then c = x end end
    H.ok(c and c.usedToday == 1 and c.perDay == 1 and c.timeLeft == 900, 'the screen: used today, time left')
end

-- ============================================================================
--                   3. IT ENDS; ONCE A DAY; AN ADMIN ENDS IT
-- ============================================================================

do
    HH._tick()
    local before = #changed
    H.time = started + 901
    HH._tick()
    H.ok(#changed == before + 1 and changed[#changed].expired == true, 'the end is heard once')
    HH._tick()
    H.eq(#changed, before + 1, 'and only once')
    H.eq(HH.state(nil), nil, 'no happy hour now')
    H.eq(Left(3, 'missions', 'hh_mission'), 1200, 'after it: the original end + cooldown')
    H.ok(Runs.onCooldown(CID[3], 'patrol', 'hh_mission'), 'on cooldown again')
    H.eq(DC.get(nil, 'noRepeat', Officer(3)), true, 'the no-repeat rule is back')

    local ok, err = Start(5, { minutes = 10 }, 'second one')
    H.ok(ok == false and err == 'err.happy_hour_used', 'a second one the same day is refused: ' .. tostring(err))
    ok, err = Start(1, { minutes = 10 }, 'event night')
    H.ok(ok == true, 'an admin may start another: ' .. tostring(err))
    H.eq(Left(3, 'missions', 'hh_mission'), nil, 'running again')
    ok, err = Act('server:admin:resetMissionControl', 1, { department = '*', key = 'happyHour', reason = 'enough' })
    H.ok(ok == true, 'an admin ends it now: ' .. tostring(err))
    H.eq(Left(3, 'missions', 'hh_mission'), 1200, 'ended: cooldowns count again')
    H.eq(HH.state(nil), nil, 'no happy hour')

    Config.MissionControls.controls.happyHour.on = false
    ok, err = Start(1, { minutes = 10 }, 'x')
    H.ok(ok == false and err == 'err.control_off', 'the admin switch off: none can start')
    Config.MissionControls.controls.happyHour.on = true
    H.time = ended
end

H.sql('DELETE FROM cp_dept_controls')
H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_audit')

return H
