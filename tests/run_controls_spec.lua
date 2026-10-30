-- In a run (step P8): four per-department Mission controls of scope 'run' read for the leader at the accept and

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
Config.Events.modifierChance = 0
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
local Runs, DC = CP.Runs, CP.DeptControls
local MC = Config.MissionControls

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

for _, key in ipairs({ 'startTimeout', 'readyCheck', 'timeLimit', 'idleCheck' }) do
    H.eq(MC.controls[key].on, false, key .. ' ships off')
    H.eq(DC.def(key).scope, 'run', key .. ' is locked at the accept')
    H.eq(DC.def(key).serverWide, false, key .. ' is per department')
    H.eq(DC.def(key).master, true, key .. ' sits under the master switch')
end
H.eq(MC.controls.readyCheck.canTurnOff, false, 'supervisors may not switch the ready check off as shipped')
H.eq(DC.checkConfig({
    startTimeout = MC.controls.startTimeout,
    readyCheck = MC.controls.readyCheck,
    timeLimit = MC.controls.timeLimit,
    idleCheck = MC.controls.idleCheck,
}), nil, 'the shipped bounds pass')
H.eq(DC.checkConfig({ readyCheck = { canTurnOff = 'yes' } }), 'err.control_config', 'canTurnOff is true or false')
H.eq(DC.checkConfig({ timeLimit = { canTurnOff = true } }), 'err.control_config', 'and only for the ready check')

-- shipped: nothing moves (no row, the switches off)
local plain = assert(W.newRun({ 7 }))
H.eq(plain.startTimeout, 600, 'shipped: Config.Limits.startTimeout')
H.eq(plain.timeLimit, 600, 'shipped: the mission\'s time limit')
H.eq(plain.fastBaseLimit, nil, 'no unscaled limit kept')
H.eq(Runs.readySeconds({ department = 'sast', citizenid = 'OFF00007' }), 20, 'shipped: Config.Units.readyTimeout')
Runs.cancelRun(plain, 'cancelled')

-- ============================================================================
--                            CHANGES PER DEPARTMENT
-- ============================================================================

Config.Permissions.supervisor.missionControls = true
for _, key in ipairs({ 'startTimeout', 'readyCheck', 'timeLimit', 'idleCheck' }) do MC.controls[key].on = true end
MC.changeWait = 0
local function Set(key, value)
    return DC.set(1, key, value, 'busy night', { department = 'sast' })
end
H.eq(Set('startTimeout', 900), true, 'SAST: 900 s to reach the start')
H.eq(Set('timeLimit', 1.25), true, 'SAST: x1.25 the time limit')
H.eq(Set('idleCheck', 120), true, 'SAST: idle officers removed after 120 s')
H.eq(Set('readyCheck', 30), true, 'SAST: 30 s to answer the ready check')
local ok, err = Set('idleCheck', 200)
H.ok(ok == false and err == 'err.control_value', 'the idle check is stricter only (above 180 refused)')
ok, err = Set('readyCheck', 0)
H.ok(ok == false and err == 'err.control_value', 'no switching the ready check off without canTurnOff')

local sast = assert(W.newRun({ 7, 9 }))
local fib = assert(W.newRun({ 8 }))
H.eq(sast.startTimeout, 900, 'a SAST leader\'s run gets 900 s')
H.eq(sast.participants[9].deadline, sast.acceptedAt + 900, 'every member\'s start deadline too')
H.eq(fib.startTimeout, 600, 'an FIB leader\'s run keeps 600 s')
H.eq(sast.timeLimit, 750, 'the scaled run lasts longer (600 x 1.25)')
H.eq(sast.fastBaseLimit, 600, 'the fast-finish bonus keeps the unscaled 600 s')
H.eq(fib.timeLimit, 600, 'the FIB run is not scaled')
H.eq(fib.fastBaseLimit, nil, 'and keeps no second limit')
H.eq(sast.controls.idleCheck, 120, 'run.controls holds the SAST idle check')
H.eq(Runs.readySeconds({ department = 'sast', citizenid = 'OFF00007' }), 30, 'a SAST unit answers in 30 s')
H.eq(Runs.readySeconds({ department = 'fib', citizenid = 'OFF00008' }), 20, 'an FIB unit in 20 s')

MC.controls.readyCheck.canTurnOff = true
H.eq(Set('readyCheck', 0), true, 'with canTurnOff a department may switch its ready check off')
H.eq(Runs.readySeconds({ department = 'sast', citizenid = 'OFF00007' }), 0, 'no ready check for SAST')
MC.controls.readyCheck.canTurnOff = false
H.eq(Runs.readySeconds({ department = 'sast', citizenid = 'OFF00007' }), 20,
    'canTurnOff taken back: the config ready check again')

-- a change mid-run never moves a live run
H.eq(DC.reset(1, 'sast', 'startTimeout', 'done'), true, 'the start timeout back to config')
H.eq(Set('idleCheck', 60), true, 'the idle check now 60 s')
H.eq(sast.startTimeout, 900, 'the live run keeps its 900 s')
H.eq(sast.controls.idleCheck, 120, 'and its 120 s idle check')

-- the idle check: 120 s for the SAST run, 180 s (config) for the FIB run
H.load('modules/anticheat/server.lua')   -- the real idle check (the fixture stubs CP.AntiCheat)
Runs.markArrived(sast, 7)
Runs.markArrived(fib, 8)
H.eq(sast.state, 'in_progress', 'the SAST run started')
CP.AntiCheat._idleCheck(sast.startedAt + 119)
H.eq(sast.participants[9].status, 'active', 'not before 120 s')
CP.AntiCheat._idleCheck(sast.startedAt + 120)
H.eq(sast.participants[9].status, 'left', 'idle 120 s removes the officer who never reached the start earlier')
H.eq(sast.participants[7].status, 'active', 'the one who arrived stays')

-- a scaled run's pre-start adjustment moves the unscaled limit by the same seconds
local adj = assert(W.newRun({ 2 }))
H.eq(adj.timeLimit, 750, 'scaled')
Runs.adjustTimer(adj, 60)
H.eq(adj.timeLimit, 810, 'an adjustment before the timer runs')
H.eq(adj.fastBaseLimit, 660, 'moves the unscaled limit too')

for _, key in ipairs({ 'startTimeout', 'readyCheck', 'timeLimit', 'idleCheck' }) do MC.controls[key].on = false end
MC.changeWait = 300
Config.Permissions.supervisor.missionControls = false

_G.print = W.realPrint
return H
