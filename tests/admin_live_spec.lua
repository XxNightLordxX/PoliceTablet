-- Full admin control, live runs and units (P3): the Live screen's runs (incl. tests and operations), End run, End test,
-- Recall, + minutes, the units list with Remove and Disband, Type of the Day, the modifier switches and the maintenance
-- refusal at accept. Real runs, events, units, livectl, adminkit, admin, access and permissions.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
Config.Events.modifierChance = 0
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
local Runs, Units, Events, Kit, Maint = CP.Runs, CP.Units, CP.Events, CP.AdminKit, CP.Maintenance

local function Rows(uuid)
    return H.sql(
        'SELECT citizenid, state, end_reason, final_points, cash_base FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid',
        { uuid })
end

-- ============================================================================
--                                THE LIVE LIST
-- ============================================================================

local run1 = assert(W.newRun({ 7, 8 }))
local test = assert(W.newRun({ 9 }, { test = { adminSrc = 3 } }))

local res = W.cb('admin:getLiveRuns', 1, {})
H.ok(res.ok, 'an admin reads the live runs')
H.eq(#res.data.runs, 2, 'both runs listed, the test run too')
local seen = {}
for _, r in ipairs(res.data.runs) do seen[r.runId] = r end
H.eq(seen[run1.id].test, false, 'a normal run is not marked test')
H.eq(seen[test.id].test, true, 'the test run is marked')
H.eq(seen[test.id].testBy, 3, 'and says which admin runs it')
H.eq(#seen[run1.id].participants, 2, 'participants listed')
H.eq(seen[run1.id].participants[1].citizenid, 'OFF00007', 'with their citizenid (links to Officers)')
H.eq(seen[run1.id].own, false, 'not the admin\'s own run')
H.eq(res.data.runTimeAddMax, 600, 'the time cap from Config.AdminControl')

local sup = W.cb('admin:getLiveRuns', 2, {})
H.eq(sup.ok, false, 'a supervisor never reads the Live screen')
local off = W.cb('admin:getLiveRuns', 7, {})
H.eq(off.ok, false, 'an officer neither')

-- ============================================================================
--                                  + MINUTES
-- ============================================================================

local ok, err = W.act('server:admin:addRunTime', 1, { runId = run1.id, minutes = 5, reason = 'lag' })
H.eq(ok, false, 'add time is refused before the timer runs')
H.eq(err, 'err.live_timer_not_running', 'with the reason (it would raise the time limit)')
H.eq(run1.timeLimit, 600, 'and the limit is untouched')

W.start(run1)
H.eq(run1.state, 'in_progress', 'the run is in progress')
H.ok(run1.timer.running, 'its timer runs')
local before = Runs.remaining(run1)
ok, err = W.act('server:admin:addRunTime', 1, { runId = run1.id, minutes = 5 })
H.eq(err, 'err.reason_required', 'a reason is needed')
ok, err = W.act('server:admin:addRunTime', 1, { runId = run1.id, minutes = 11, reason = 'lag' })
H.eq(err, 'err.live_minutes_range', 'one click adds at most 10 minutes')
ok, err = W.act('server:admin:addRunTime', 1, { runId = run1.id, minutes = 5, reason = 'server lag' })
H.ok(ok, 'five minutes added')
H.eq(err.timeAdded, 300, 'the total is kept')
H.ok(Runs.remaining(run1) >= before + 300 - 15, 'the timer has five more minutes')
H.eq(run1.timeLimit, 600, 'the time limit fast_finish is judged on stays the original')
H.eq(W.toasts(7, 'admin.live.notice.time_added'), 1, 'participants are told')
ok = W.act('server:admin:addRunTime', 3, { runId = run1.id, minutes = 5, reason = 'again' })
H.ok(ok, 'another admin adds five more (600 s in all)')
ok, err = W.act('server:admin:addRunTime', 1, { runId = run1.id, minutes = 1, reason = 'more' })
H.eq(err, 'err.live_time_max', 'the run\'s total stays within runTimeAddMax')
H.eq(#W.audits('runTimeAdd'), 2, 'every addition is audited')
H.eq(W.audits('runTimeAdd')[1].category, 'operations', 'to the operations webhook')

-- ============================================================================
--                                    RECALL
-- ============================================================================

local run2 = assert(W.newRun({ 1, 2 }, {}))
ok, err = W.act('server:admin:recall', 3, { runId = run2.id, src = 2 })
H.eq(err, 'err.reason_required', 'recall needs a reason')
ok, err = W.act('server:admin:recall', 1, { runId = run2.id, src = 2, reason = 'stuck' })
H.eq(ok, false, 'an admin never recalls from a run they are on')
H.eq(err, 'err.own_run', 'own run refused')
ok = W.act('server:admin:recall', 3, { runId = run2.id, src = 2, reason = 'stuck in a wall' })
H.ok(ok, 'another admin recalls the participant')
H.eq(run2.participants[2].endReason, 'force_recall', 'they left with force_recall (no penalty, no cooldown)')
H.eq(Runs.onCooldown('SUP00002', 'patrol', W.DEF.id), false, 'no cooldown after a recall')

-- ============================================================================
--                                   END RUN
-- ============================================================================

ok, err = W.act('server:admin:endRun', 3, { runId = run1.id, reason = 'broken' })
H.eq(err, 'err.confirm_mismatch', 'End run needs the typed word END')
ok, err = W.act('server:admin:endRun', 1, { runId = run2.id, reason = 'broken', confirm = 'END' })
H.eq(err, 'err.own_run', 'an admin never ends their own run')
ok, err = W.act('server:admin:endRun', 1, { runId = test.id, reason = 'x', confirm = 'END' })
H.eq(err, 'err.live_use_end_test', 'a test run is ended with End test')

local prop = run1.objectives[1].state.prop
H.ok(prop and W.ents[prop] ~= nil, 'the run spawned its object')
local stopsBefore, releasesBefore = W.count('block.stop'), W.count('draw.release')
ok, err = W.act('server:admin:endRun', 3, { runId = run1.id, reason = 'mission broke', confirm = 'end' })
H.ok(ok, 'another admin ends the run (the word in any case)')
H.eq(err.participants, 2, 'both participants left')
H.eq(run1.state, 'ended', 'the run ended')
H.eq(run1.endState, 'abandoned', 'as abandoned')
H.eq(Runs.get(run1.id), nil, 'and is gone from the live list')
H.eq(W.ents[prop].exists, false, 'its entity was deleted')
H.eq(W.count('block.stop'), stopsBefore + 1, 'its objective was stopped (zones, blips)')
H.eq(W.count('draw.release'), releasesBefore + 1, 'its location reservation was released')
local rows = Rows(run1.id)
H.eq(#rows, 2, 'one row per participant')
for _, r in ipairs(rows) do
    H.eq(r.end_reason, 'cancelled', 'end reason cancelled')
    H.eq(r.state, 'abandoned', 'state abandoned')
    H.eq(tonumber(r.final_points), 0, 'no points')
end
H.eq(Runs.onCooldown('OFF00007', 'patrol', W.DEF.id), false, 'no cooldown for an ended run')
H.eq(Runs.isOnMission(7), false, 'the participant is free again')
H.eq(W.toasts(8, 'admin.live.notice.run_ended'), 1, 'participants are told')
local endAudit = W.audits('runEnd')
H.eq(#endAudit, 1, 'audited once')
H.eq(endAudit[1].category, 'operations', 'to the operations webhook')
H.eq(endAudit[1].reason, 'mission broke', 'with the reason')

-- A participant who is down when the run ends leaves the way every end handles it (Hard rule 18).
local run3 = assert(W.newRun({ 7, 8 }))
W.start(run3)
W.downed[8] = true
ok = W.act('server:admin:endRun', 1, { runId = run3.id, reason = 'restart soon', confirm = 'END' })
W.downed[8] = nil
H.ok(ok, 'a run with a downed participant ends')
H.eq(W.count('downed.handle'), 1, 'the downed participant got the pick-up / EMS follow-up')
H.eq(run3.participants[8].endReason, 'downed', 'they failed as downed (Hard rule 18)')
H.eq(run3.participants[7].endReason, 'cancelled', 'the others left as cancelled')
H.eq(run3.state, 'ended', 'the run ended')

-- An operation's run is ended by cancelling the operation (cp_operations says cancelled).
local opRun = assert(W.newRun({ 7, 8 }, { operationId = 41 }))
W.op = { id = 41, runId = opRun.id, status = 'running' }
ok = W.act('server:admin:endRun', 1, { runId = opRun.id, reason = 'op broke', confirm = 'END' })
H.ok(ok, 'an operation run ends')
H.eq(W.count('ops.cancel'), 1, 'through the operation\'s cancel')
H.eq(W.log['ops.cancel'][1][2], 'op broke', 'with the admin\'s reason')
H.eq(opRun.state, 'ended', 'the run ended')
H.eq(opRun.participants[7].endReason, 'cancelled', 'participants left as cancelled')

-- ============================================================================
--                                   END TEST
-- ============================================================================

ok, err = W.act('server:admin:endTest', 1, { runId = run2.id, reason = 'x' })
H.eq(err, 'err.live_not_test', 'End test only ends test runs')
ok, err = W.act('server:admin:endTest', 1, { runId = test.id })
H.eq(err, 'err.reason_required', 'End test needs a reason')
ok = W.act('server:admin:endTest', 1, { runId = test.id, reason = 'left it running' })
H.ok(ok, 'an admin ends another admin\'s test')
H.eq(test.state, 'ended', 'the test ended')
H.eq(W.count('testing.ended'), 1, 'the testing module heard of it')
H.eq(#Rows(test.id), 0, 'a test saves no row')
H.eq(W.audits('testEnd')[1].category, 'builder', 'audited to the builder webhook')

-- ============================================================================
--                                    UNITS
-- ============================================================================

H.fire('crimson-police:server:unitInvite', 7, { targetSrc = 8 }, 'u1')
H.fire('crimson-police:server:unitRespond', 8, { accepted = true }, 'u2')
H.fire('crimson-police:server:unitInvite', 7, { targetSrc = 9 }, 'u3')
H.fire('crimson-police:server:unitRespond', 9, { accepted = true }, 'u4')
local unit = Units.unitOf(7)
H.ok(unit and #unit.members == 3, 'officers 7, 8 and 9 form a unit')

res = W.cb('admin:getUnits', 3, {})
H.ok(res.ok, 'an admin reads the units')
H.eq(#res.data.units, 1, 'one unit')
local u = res.data.units[1]
H.eq(u.id, unit.id, 'the same unit as Units.unitOf')
H.eq(u.leader, unit.leader, 'the same leader')
H.eq(#u.members, #Units.members(7), 'the same members as Units.members')
H.eq(u.members[1].name, 'Olive Seven', 'with their names')
H.eq(u.locked, false, 'not locked')
H.eq(W.cb('admin:getUnits', 2, {}).ok, false, 'a supervisor never reads it')

Units.lock(unit)
ok, err = W.act('server:admin:removeFromUnit', 3, { unitId = unit.id, src = 9, reason = 'afk' })
H.eq(err, 'err.live_unit_locked', 'a locked unit is not changed')
ok, err = W.act('server:admin:disbandUnit', 3, { unitId = unit.id, reason = 'afk' })
H.eq(err, 'err.live_unit_locked', 'nor disbanded')
Units.unlock(unit)

local checkDone = nil
Units.readyCheck(unit, 'patrol', function() checkDone = 'ready' end, function()
    checkDone = 'cancel'
end)
ok, err = W.act('server:admin:removeFromUnit', 3, { unitId = unit.id, src = 9, reason = 'afk' })
H.eq(err, 'err.live_unit_ready_check', 'refused during a ready check')
H.fire('crimson-police:server:unitReady', 8, { accepted = false }, 'u5')
H.eq(checkDone, 'cancel', 'the check ended')
if unit.locked then Units.unlock(unit) end

local onRun = assert(W.newRun({ 9 }))
ok, err = W.act('server:admin:disbandUnit', 3, { unitId = unit.id, reason = 'x' })
H.eq(err, 'err.live_unit_on_run', 'refused while a member is on a run')
Runs.removeParticipant(onRun, 9, 'quit')

ok, err = W.act('server:admin:removeFromUnit', 3, { unitId = unit.id, src = 9 })
H.eq(err, 'err.reason_required', 'remove needs a reason')
ok = W.act('server:admin:removeFromUnit', 3, { unitId = unit.id, src = 9, reason = 'asked to leave' })
H.ok(ok, 'an admin takes one member out')
H.eq(Units.unitOf(9), nil, 'they are out')
H.eq(W.toasts(9, 'unit.admin_removed_you'), 1, 'and told')
H.eq(W.toasts(7, 'unit.admin_removed'), 1, 'the others are told')
H.eq(tostring(W.audits('unitRemove')[1].target), tostring(unit.id), 'audited')

H.fire('crimson-police:server:unitInvite', 3, { targetSrc = 9 }, 'u6')
H.fire('crimson-police:server:unitRespond', 9, { accepted = true }, 'u7')
local mine = Units.unitOf(3)
ok, err = W.act('server:admin:disbandUnit', 3, { unitId = mine.id, reason = 'x' })
H.eq(err, 'err.live_own_unit', 'an admin never splits their own unit')

ok = W.act('server:admin:disbandUnit', 1, { unitId = unit.id, reason = 'clean up' })
H.ok(ok, 'an admin disbands a unit')
H.eq(Units.unitOf(7), nil, 'nobody is in it any more')
H.eq(W.toasts(8, 'unit.admin_disbanded'), 1, 'members are told')
H.eq(#W.audits('unitDisband'), 1, 'audited')

-- ============================================================================
--                      TYPE OF THE DAY AND THE MODIFIERS
-- ============================================================================

Config.Events.typeOfTheDay = true
local rolled = Events.rolledTypeOfTheDay()
local other = rolled == 'patrol' and 'training' or 'patrol'
res = W.cb('admin:getToday', 1, {})
H.ok(res.ok, 'an admin reads today')
H.eq(res.data.typeOfTheDay, rolled, 'today\'s type is the roll')
H.eq(res.data.override, nil, 'no override yet')
H.ok(#res.data.modifiers == 3, 'the three modifiers with their switches')

ok, err = W.act('server:admin:setTypeOfDay', 1, { type = 'nope', reason = 'x' })
H.eq(err, 'err.unknown_type', 'only a mission type')
ok = W.act('server:admin:setTypeOfDay', 1, { type = other, reason = 'event night' })
H.ok(ok, 'an admin overrides today\'s type')
H.eq(Events.typeOfTheDay(), other, 'every reader sees the override')
H.eq(Events.typeOfTheDay(CP.Schedule.dayKey(os.time() - 86400)),
    Events.rolledTypeOfTheDay(CP.Schedule.dayKey(os.time() - 86400)), 'another day keeps its roll')
H.ok(W.toasts(7, 'admin.live.notice.tod_changed') >= 1, 'officers are told')
H.eq(W.audits('todOverride')[1].new_value, other, 'audited')

-- a restart keeps it (read back from today's cp_audit row, which a backup restore never replaces)
H.load('modules/events/server.lua')
H.eq(CP.Events.typeOfTheDay(), other, 'the override survives a restart')
ok = W.act('server:admin:setTypeOfDay', 1, { type = 'none', reason = 'quiet day' })
H.ok(ok, 'no Type of the Day today')
H.eq(CP.Events.typeOfTheDay(), nil, 'none today')
-- the next day the roll is back
local savedTime = H.time
H.time = H.time + 86400 + 3600
H.eq(CP.Events.typeOfTheDay(), CP.Events.rolledTypeOfTheDay(), 'the override ends at the daily reset')
H.time = savedTime
ok = W.act('server:admin:setTypeOfDay', 1, { type = 'auto', reason = 'back to normal' })
H.eq(CP.Events.typeOfTheDay(), CP.Events.rolledTypeOfTheDay(), 'auto puts today\'s roll back')
Config.Events.typeOfTheDay = false
ok, err = W.act('server:admin:setTypeOfDay', 1, { type = 'patrol', reason = 'x' })
H.eq(err, 'err.live_tod_off', 'refused while Type of the Day is off in Settings')
Config.Events.typeOfTheDay = true

Config.Events.modifierChance = 1
local rolls = {}
for i = 1, 40 do
    local key = CP.Events.rollModifier({ id = 'm' .. i, seed = i * 7919, missionType = 'tactical' })
    rolls[key or 'none'] = true
end
H.ok(rolls.armored_hostiles and rolls.time_crunch, 'every modifier rolls while switched on')
Config.Events.modifiers = { armored_hostiles = false, time_crunch = true, radio_silence = false }
rolls = {}
for i = 1, 40 do
    local key = CP.Events.rollModifier({ id = 'm' .. i, seed = i * 7919, missionType = 'tactical' })
    rolls[key or 'none'] = true
end
H.eq(rolls.armored_hostiles, nil, 'a switched-off modifier never rolls')
H.eq(rolls.radio_silence, nil, 'nor the other one')
H.ok(rolls.time_crunch, 'the one left on still rolls')
Config.Events.modifiers = { armored_hostiles = false, time_crunch = false, radio_silence = false }
H.eq(CP.Events.rollModifier({ id = 'x', seed = 5, missionType = 'patrol' }), nil, 'all off: no modifier')
Config.Events.modifiers = { armored_hostiles = true, time_crunch = true, radio_silence = true }
Config.Events.modifierChance = 0

-- ============================================================================
--                      MAINTENANCE AND THE SIDEBAR COUNT
-- ============================================================================

local counts = CP.Tablet.navCounts(1)
H.eq(counts.adminLive, #Runs.all(), 'the Live badge counts the live runs (admins only)')
H.eq(CP.Tablet.navCounts(7).adminLive, nil, 'an officer never gets it')

Maint.begin('storage', { by = 'console' })
local r, e = W.newRun({ 8 })
H.eq(r, nil, 'no run starts during maintenance')
H.eq(e, 'err.maintenance', 'with the maintenance reason')
ok, err = W.act('server:admin:endRun', 3, { runId = run2.id, reason = 'x', confirm = 'END' })
H.eq(err, 'err.maintenance', 'admin actions wait too')
H.ok(W.cb('admin:getLiveRuns', 1, {}).ok, 'reads keep working')
Maint.finish('storage')
r = W.newRun({ 8 })
H.ok(r ~= nil, 'runs start again after the lock')

_G.print = W.realPrint
return H
