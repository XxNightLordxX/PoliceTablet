-- Supervisor officer actions (step P7): Clear cooldown (one officer's mission or type cooldown, from Department
-- Report) and "+ minutes" on a live run (Live Missions), both Mission controls of kind 'action'. Real runs, livectl,
-- deptcontrols, adminkit, admin, access and permissions (tests/fixtures/admin_live_world.lua).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
Config.Events.modifierChance = 0
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
local Runs, DC, LiveCtl = CP.Runs, CP.DeptControls, CP.LiveCtl

-- an FIB supervisor
W.people[10] = { cid = 'SUP00010', license = 'license:g10', job = 'fib', grade = 4, name = 'Fay Fib' }
H.players[10] = { ace = {}, coords = vec3(100.0, 100.0, 30.0) }
H.sql('INSERT INTO cp_officers (citizenid, department, license) VALUES (?, ?, ?)', { 'SUP00010', 'fib', 'license:g10' })

local function Roles(action)
    local out = {}
    for _, r in ipairs(H.sql('SELECT role FROM cp_audit WHERE action = ? ORDER BY id', { action })) do
        out[#out + 1] = r.role
    end
    return out
end

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

local MC = Config.MissionControls
H.eq(MC.controls.clearCooldown.on, true, 'clearCooldown ships on (a cooldown control, owner decision)')
H.eq(MC.controls.addRunTime.on, false, 'addRunTime ships off')
H.eq(MC.controls.addRunTime.min, 1, 'one minute per click at least')
H.eq(MC.controls.addRunTime.max, 5, 'five at most')
H.eq(MC.clearCooldownPerDay, 5, 'five clears a supervisor a day')
H.eq(MC.addRunTimePerDay, 10, 'ten additions a supervisor a day')
H.eq(MC.addRunTimeMax, 300, 'five minutes per run in all')
H.eq(Config.Permissions.supervisor.missionControls, false, 'the master switch ships off')
H.eq(DC.def('clearCooldown').kind, 'action', 'registered as an action control')
H.eq(DC.def('clearCooldown').serverWide, true, 'clearCooldown is server-wide')
H.eq(DC.def('clearCooldown').master, false, 'and outside the master switch')
H.eq(DC.def('addRunTime').master, true, 'addRunTime is under the master switch')
H.eq(DC.checkConfig({ clearCooldown = MC.controls.clearCooldown, addRunTime = MC.controls.addRunTime }), nil,
    'the shipped bounds pass the config check')
H.eq(DC.checkConfig({ addRunTime = { on = true, min = 1, max = 11 } }), 'err.control_config',
    'at most 10 minutes per click')
local okS, errS = DC.set(1, 'clearCooldown', true, 'x')
H.eq(okS, false, 'an action control has no value to set')
H.eq(errS, 'err.control_unknown', 'refused as no value control')
H.eq(DC.get('sast', 'clearCooldown'), nil, 'nor one to read')
local others = {}
for _, key in ipairs(DC.keys()) do
    if DC.def(key).kind ~= 'action' then others[#others + 1] = DC.def(key) end
end
for _, d in ipairs(others) do DC.unregister(d.key) end
H.eq(DC.available(2), false, 'an action control alone never opens the Mission controls screen')
for _, d in ipairs(others) do DC.register(d.key, d) end

-- ============================================================================
--                                CLEAR COOLDOWN
-- ============================================================================

local now = os.time()
W.row({ cid = 'OFF00007', reason = 'quit', state = 'abandoned', ts = now - 60 })
W.row({ cid = 'OFF00008', reason = 'quit', state = 'abandoned', ts = now - 60 })
Runs._forgetOfficer('OFF00007')
Runs._forgetOfficer('OFF00008')
H.ok(Runs.onCooldown('OFF00007', 'patrol', W.DEF.id), 'officer 7 is on cooldown')

local res = W.cb('sup:getOfficerCooldowns', 2, { citizenid = 'OFF00007' })
H.ok(res.ok, 'a supervisor reads an officer\'s cooldowns')
H.eq(res.data.cooldowns.types[1].key, 'patrol', 'the type cooldown')
H.eq(res.data.cooldowns.missions[1].id, W.DEF.id, 'the mission cooldown')
H.eq(res.data.clears.max, 3, 'the officer\'s clears a day (all staff)')
H.eq(res.data.mine.perDay, 5, 'the supervisor\'s own clears a day')
H.eq(res.data.cashToday, nil, 'no cash in the trimmed view')
H.eq(W.cb('sup:getOfficerCooldowns', 7, { citizenid = 'OFF00009' }).ok, false, 'never for an officer')
H.ok(LiveCtl.supClearView(2, 'OFF00009') ~= nil, 'the Department Report dialog offers Clear cooldown')
H.eq(LiveCtl.supClearView(2, 'SUP00002'), nil, 'but not on his own character')
H.eq(LiveCtl.supClearView(7, 'OFF00009'), nil, 'nor to an officer')

local A = 'server:sup:clearCooldowns'
local ok, err = W.act(A, 2, { citizenid = 'OFF00007', scope = 'type', key = 'patrol' })
H.eq(err, 'err.reason_required', 'a reason is needed')
ok, err = W.act(A, 2, { citizenid = 'OFF00007', scope = 'all', reason = 'x' })
H.eq(err, 'err.invalid_payload', 'never every cooldown at once')
ok, err = W.act(A, 2, { citizenid = 'SUP00002', scope = 'type', key = 'patrol', reason = 'x' })
H.eq(err, 'err.self_target', 'never his own character')
ok, err = W.act(A, 7, { citizenid = 'OFF00009', scope = 'type', key = 'patrol', reason = 'x' })
H.eq(ok, false, 'an officer never clears')

ok, err = W.act(A, 2, { citizenid = 'OFF00007', scope = 'type', key = 'patrol', reason = 'bugged call' })
H.ok(ok, 'a SAST supervisor clears a SAST officer\'s type cooldown')
H.eq(err.used, 1, 'the officer\'s first clear today')
H.eq(Runs.cooldowns('OFF00007').types.patrol, nil, 'patrol is free')
H.ok(Runs.cooldowns('OFF00007').missions[W.DEF.id] ~= nil, 'the mission cooldown stays')
H.eq(W.toasts(7, 'sup.notice.cooldowns_cleared'), 1, 'the officer is told')
H.eq(Roles('cooldownClear')[1], 'supervisor', 'audited as a supervisor (the admin\'s Today & cooldowns history)')

ok, err = W.act(A, 2, { citizenid = 'OFF00008', scope = 'mission', key = W.DEF.id, reason = 'bugged call' })
H.ok(ok, 'an FIB officer too: a cooldown change is server-wide (owner decision)')
H.eq(Runs.cooldowns('OFF00008').missions[W.DEF.id], nil, 'his mission cooldown is free')

ok = W.act(A, 2, { citizenid = 'OFF00007', scope = 'mission', key = W.DEF.id, reason = 'x' })
H.ok(ok, 'the officer\'s second clear')
ok = W.act('server:admin:clearCooldowns', 1, { citizenid = 'OFF00007', scope = 'all', reason = 'x' })
H.ok(ok, 'an admin\'s clear is the third')
ok, err = W.act(A, 2, { citizenid = 'OFF00007', scope = 'type', key = 'training', reason = 'x' })
H.eq(err, 'err.live_clear_limit', 'the fourth of the day for that officer is refused (shared with admins)')

local run9 = assert(W.newRun({ 9 }))
ok, err = W.act(A, 2, { citizenid = 'OFF00009', scope = 'type', key = 'patrol', reason = 'x' })
H.eq(err, 'err.live_officer_on_run', 'not while the officer is on a run')
Runs.removeParticipant(run9, 9, 'quit')

MC.clearCooldownPerDay = 3
ok, err = W.act(A, 2, { citizenid = 'OFF00009', scope = 'type', key = 'patrol', reason = 'x' })
H.eq(err, 'err.sup_clear_used', 'the supervisor\'s own clears a day')
ok = W.act(A, 10, { citizenid = 'OFF00009', scope = 'type', key = 'patrol', reason = 'x' })
H.ok(ok, 'another supervisor has his own count')
MC.clearCooldownPerDay = 5

MC.controls.clearCooldown.on = false
ok, err = W.act(A, 2, { citizenid = 'OFF00009', scope = 'type', key = 'training', reason = 'x' })
H.eq(err, 'err.control_off', 'the admin switch off refuses')
H.eq(LiveCtl.supClearView(2, 'OFF00009'), nil, 'and the button is gone')
MC.controls.clearCooldown.on = true

-- ============================================================================
--                                  + MINUTES
-- ============================================================================

local T = 'server:sup:addRunTime'
local run = assert(W.newRun({ 7, 8 }))
W.start(run)
ok, err = W.act(T, 2, { runId = run.id, minutes = 2, reason = 'lag' })
H.eq(ok, false, 'shipped off')
H.eq(LiveCtl.supTimeView(2), nil, 'no + minutes on Live Missions')
MC.controls.addRunTime.on = true
ok, err = W.act(T, 2, { runId = run.id, minutes = 2, reason = 'lag' })
H.eq(ok, false, 'the master switch still applies')
Config.Permissions.supervisor.missionControls = true

local view = LiveCtl.supTimeView(2)
H.eq(view and view.max, 5, 'five minutes a click')
H.eq(view.maxSeconds, 300, 'within min(addRunTimeMax, AdminControl.runTimeAddMax)')
ok, err = W.act(T, 2, { runId = run.id, minutes = 6, reason = 'lag' })
H.eq(err, 'err.live_minutes_range', 'at most the admin\'s max a click')
ok, err = W.act(T, 2, { runId = run.id, minutes = 2 })
H.eq(err, 'err.reason_required', 'a reason is needed')

ok = W.act('server:admin:addRunTime', 1, { runId = run.id, minutes = 3, reason = 'lag' })
H.ok(ok, 'an admin adds three minutes first')
local before = Runs.remaining(run)
ok, err = W.act(T, 2, { runId = run.id, minutes = 2, reason = 'traffic' })
H.ok(ok, 'the supervisor adds two')
H.eq(err.timeAdded, 300, 'five minutes in all, the admin\'s counted')
H.ok(Runs.remaining(run) >= before + 120 - 5, 'the timer has two more minutes')
H.eq(run.timeLimit, 600, 'the time limit the fast-finish bonus is judged on stays the original')
H.eq(W.toasts(8, 'sup.notice.time_added'), 1, 'participants are told')
ok, err = W.act(T, 2, { runId = run.id, minutes = 1, reason = 'more' })
H.eq(err, 'err.live_time_max', 'the run\'s total stays within the supervisors\' cap')
local roles = Roles('runTimeAdd')
H.eq(roles[#roles], 'supervisor', 'audited as a supervisor')

local run2 = assert(W.newRun({ 9 }))
W.start(run2)
ok, err = W.act(T, 10, { runId = run2.id, minutes = 1, reason = 'x' })
H.eq(err, 'err.other_department', 'an FIB supervisor never adds to a SAST-only run')
local run3 = assert(W.newRun({ 2 }))
W.start(run3)
ok, err = W.act(T, 2, { runId = run3.id, minutes = 1, reason = 'x' })
H.eq(err, 'err.own_run', 'never his own run')

local live = W.cb('sup:getLiveRuns', 2, {})
H.ok(live.ok, 'Live Missions')
H.eq(live.data.addTime.max, 5, 'offers + minutes')
local byId = {}
for _, r in ipairs(live.data.runs) do byId[r.runId] = r end
H.eq(byId[run.id].timeAdded, 300, 'with what was added')
H.eq(byId[run3.id].own, true, 'and marks his own run')

MC.addRunTimePerDay = 1
ok, err = W.act(T, 2, { runId = run2.id, minutes = 1, reason = 'x' })
H.eq(err, 'err.sup_time_used', 'the supervisor\'s additions a day')
MC.addRunTimePerDay = 10
MC.controls.addRunTime.on = false
Config.Permissions.supervisor.missionControls = false

_G.print = W.realPrint
return H
