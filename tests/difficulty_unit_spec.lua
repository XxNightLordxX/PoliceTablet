-- Difficulty and unit size (step P9): two per-department Mission controls. difficulty picks one of the presets the
-- admin lists (Config.NpcDifficulty) for runs the department leads, read at the accept; unitSize caps the units its
-- leaders may lead, never above Config.Limits.maxUnitSize.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
Config.Events.modifierChance = 0
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
local Runs, DC, S, Units = CP.Runs, CP.DeptControls, CP.Scaling, CP.Units
local MC = Config.MissionControls

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

for _, key in ipairs({ 'difficulty', 'unitSize' }) do
    H.eq(MC.controls[key].on, false, key .. ' ships off')
    H.eq(DC.def(key).scope, 'run', key .. ' is read at the accept')
    H.eq(DC.def(key).serverWide, false, key .. ' is per department')
end
H.eq(DC.def('difficulty').kind, 'choice', 'difficulty is a pick from a list')
H.eq(DC.checkConfig({ difficulty = MC.controls.difficulty, unitSize = MC.controls.unitSize }), nil,
    'the shipped bounds pass')
H.eq(DC.checkConfig({ difficulty = { presets = { 'easy', 'brutal' } } }), 'err.control_config',
    'only Config.NpcDifficulty presets')
H.eq(DC.checkConfig({ difficulty = { presets = { 'easy', 'easy' } } }), 'err.control_config', 'each preset once')

local plain = assert(W.newRun({ 7 }))
H.eq(plain.controls.difficulty, 'normal', 'shipped: Config.NpcDifficulty.preset')
H.eq(S.feel(plain).healthMult, 1.0, 'shipped: normal feel')
H.eq(Units.maxSize('sast'), 4, 'shipped: Config.Limits.maxUnitSize')
Runs.cancelRun(plain, 'cancelled')

-- ============================================================================
--                                  UNIT SIZE
-- ============================================================================

Config.Permissions.supervisor.missionControls = true
MC.controls.difficulty.on, MC.controls.unitSize.on = true, true
MC.changeWait = 0
local function Set(key, value)
    return DC.set(1, key, value, 'busy night', { department = 'sast' })
end
local ok, err = Set('unitSize', 5)
H.ok(ok == false and err == 'err.control_value', 'never above the admin max (4)')
MC.controls.unitSize.max = 6
ok, err = Set('unitSize', 5)
H.ok(ok == false and err == 'err.control_value', 'never above Config.Limits.maxUnitSize either')
MC.controls.unitSize.max = 4
H.eq(Set('unitSize', 3), true, 'SAST: units of at most 3')
H.eq(Units.maxSize('sast'), 3, 'SAST leaders: 3')
H.eq(Units.maxSize('fib'), 4, 'FIB leaders keep 4')
H.eq(W.act('server:unitInvite', 7, 9), true, 'a SAST leader invites a second')
H.eq(W.act('server:unitInvite', 7, 2), true, 'and a third')
ok, err = W.act('server:unitInvite', 7, 1)
H.ok(ok == false and err == 'err.unit_full', 'a fourth invite is refused under the SAST max of 3')
H.eq(Units.view(7).maxSize, 3, 'the Units screen shows 3')
H.eq(Units.view(8).maxSize, 4, 'an FIB officer still sees 4')
Units._reset()

-- ============================================================================
--                                  DIFFICULTY
-- ============================================================================

ok, err = Set('difficulty', 'hard')
H.ok(ok == false and err == 'err.control_value', 'a preset the admin did not list is refused')
H.eq(Set('difficulty', 'easy'), true, 'SAST: easy')
local sast = assert(W.newRun({ 7, 9 }))
local fib = assert(W.newRun({ 8 }))
H.eq(sast.controls.difficulty, 'easy', 'run.controls holds the SAST difficulty')
H.eq(S.feel(sast).healthMult, 0.85, 'a SAST run: easy health')
H.eq(S.feel(sast).fleeMult, 0.8, 'and easy runners')
H.eq(S.feel(fib).healthMult, 1.0, 'an FIB run: normal health')
local accE, armE = S.combat(10, 10, 'standard', sast)
local accN, armN = S.combat(10, 10, 'standard', fib)
H.ok(accE < accN, ('easy NPCs aim worse (%d < %d)'):format(accE, accN))
H.eq(armE, armN, 'easy adds no armour')
H.ok(accN <= Config.NpcCombat.accuracyMax, 'the NpcCombat cap still applies')
H.eq(sast.pointsBase, fib.pointsBase, 'points unchanged')
H.eq(DC.reset(1, 'sast', 'difficulty', 'done'), true, 'back to config')
H.eq(S.feel(sast).healthMult, 0.85, 'the live run keeps easy')

MC.controls.difficulty.on, MC.controls.unitSize.on = false, false
MC.changeWait = 300
Config.Permissions.supervisor.missionControls = false

_G.print = W.realPrint
return H
