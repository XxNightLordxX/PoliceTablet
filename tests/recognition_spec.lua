-- Config.Recognition (FM2): XP levels, the auto badges, the weekly board badges, commendations and the field training

-- Config.Recognition (FM2): XP levels, the auto badges, the weekly board badges, commendations and the field training
-- badge are one config section, each part with its own rules. One block per old feature, driven through the new
-- section: what the shipped config gives is what the server gave before, and each part's switch turns only that part
-- off. Plain stubs, no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

CP.Admin = {
    audit = function() end,
    webhook = function() return true end,
}
CP.Tablet = { notify = function() end }
CP.Qbx = {
    onDutyChange = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}

H.load('modules/adminkit/server.lua')
H.load('modules/progression/scoring.lua')
H.load('modules/supervisor/fieldtraining.lua')
local S, FT = CP.Scoring, CP.FieldTraining
local R = Config.Recognition

-- ============================================================================
--                               THE ONE SECTION
-- ============================================================================

for _, old in ipairs({ 'Badges', 'Commendations', 'FieldTraining', 'XPLevels', 'XPCurve' }) do
    H.eq(Config[old], nil, 'no Config.' .. old .. ': it is a part of Config.Recognition')
end
H.eq(Config.Leaderboard.weeklyBadges, nil, 'the weekly board badges left Config.Leaderboard')
for _, part in ipairs({ 'levels', 'levelCurve', 'badges', 'weeklyBadges', 'commendations', 'fieldTraining' }) do
    H.eq(CP.Recognition(part), R[part], part .. ': CP.Recognition answers the config table')
end
H.eq(select(2, CP.Recognition('commendations')), true, 'commendations ship on, as before')
H.eq(select(2, CP.Recognition('fieldTraining')), false, 'field training ships off, as before')
H.eq(select(2, CP.Recognition('badges')), true, 'the auto badges have no switch of their own')
H.eq(next((CP.Recognition('nosuch'))), nil, 'an unknown part: an empty table')
H.eq(select(2, CP.Recognition('nosuch')), false, 'and off')

-- ============================================================================
--                                  XP LEVELS
-- ============================================================================

H.eq(#R.levels, 5, 'the five shipped level names')
H.eq(S.xpLevel(0).label, 'Probationary', 'level 1 is Probationary, as before')
H.eq(S.xpLevel(0).badge, 'grey', 'with the grey medal')
H.eq(S.xpLevel(S.levelXp(10)).label, 'Patrol Officer', 'level 10 starts Patrol Officer')
H.eq(S.levelXp(2), 100, 'levelCurve.first: 100 XP to level 2, as before')
H.eq(S.levelOf(10 ^ 9), 50, 'levelCurve.maxLevel: 50, as before')
R.levelCurve.maxLevel = 20
H.eq(S.levelOf(10 ^ 9), 20, 'a changed curve is read at once')
R.levelCurve.maxLevel = 50
R.levels[1].label = 'Cadet'
H.eq(S.xpLevel(0).label, 'Cadet', 'a renamed level is read at once')
R.levels[1].label = 'Probationary'

-- ============================================================================
--                                 AUTO BADGES
-- ============================================================================

local function Need(id)
    for _, a in ipairs(S.badgeCatalog().achievements) do
        if a.id == id then return a.need end
    end
    return nil
end
local shippedNeed = {
    iron_wheels = 20,
    sharpshooter = 10,
    road_warrior = 100,
    partner_in_crime = 50,
    joint_task_force = 10,
    by_the_book = 100,
    first_responder = 25,
}
for id, n in pairs(shippedNeed) do
    H.eq(R.badges[id], n, id .. ': the badge id is its key, the count as before')
    H.eq(Need(id), n, id .. ': the admin catalog shows the same count')
end
R.badges.road_warrior = 3
H.eq(Need('road_warrior'), 3, 'a changed count is read at once')
R.badges.road_warrior = 0
H.eq(Need('road_warrior'), 0, '0 = that badge is off')
R.badges.road_warrior = 100
H.eq(S.validBadgeId('iron_wheels'), true, 'an admin may grant or revoke an auto badge')

-- ============================================================================
--                             FIELD TRAINING BADGE
-- ============================================================================

H.eq(FT.enabled(), false, 'field training: off as shipped')
H.eq(Need('field_training'), nil, 'off: the training badge is not in the catalog')
H.eq(S.validBadgeId('field_training'), false, 'off: not a badge an admin may grant')
R.fieldTraining.enabled = true
H.eq(FT.enabled(), true, 'fieldTraining.enabled = true: on at once')
H.eq(Need('field_training'), 0, 'on: the training badge is in the catalog (given by the sign-offs)')
H.eq(S.validBadgeId('field_training'), true, 'on: an admin may grant or revoke it')
R.fieldTraining.badge = 'fto_done'
H.eq(FT.badge(), 'fto_done', 'fieldTraining.badge names the badge')
R.fieldTraining.badge = 'field_training'
R.fieldTraining.trainerBonus = 25
H.eq(FT.trainerBonus(), 25, 'fieldTraining.trainerBonus: points per sign-off')
R.fieldTraining.requireTrainerFor = { 'tactical' }
H.eq(FT.requiredTypes().tactical, true, 'fieldTraining.requireTrainerFor: the ride-along rule')
R.fieldTraining.enabled, R.fieldTraining.trainerBonus, R.fieldTraining.requireTrainerFor = false, 0, {}
H.eq(select(2, CP.Recognition('commendations')), true, 'the field training switch leaves commendations alone')

-- ============================================================================
--                                COMMENDATIONS
-- ============================================================================

local C = R.commendations
H.eq(#C.kinds, 6, 'the six shipped kinds')
H.ok(C.perSupervisorPerDay == 3 and C.sameKindCooldownDays == 7 and C.crossDepartment == false,
    'the per day limit, the same-kind cooldown and the own-department rule as before')
C.enabled = false
H.eq(select(2, CP.Recognition('commendations')), false, 'commendations.enabled = false: off')
H.eq(S.xpLevel(0).label, 'Probationary', 'and the levels stay')
H.eq(Need('iron_wheels'), 20, 'and the auto badges stay')
C.enabled = true

-- ============================================================================
--                             WEEKLY BOARD BADGES
-- ============================================================================

H.eq(#R.weeklyBadges, 0, 'no extra weekly badges as shipped (Officer of the Week stays)')

return H
