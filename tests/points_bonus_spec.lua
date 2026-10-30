-- Points bonuses inside admin bounds (step P20): happyHourPoints (x the final points of a completed run a department
-- leads that was accepted while a happy hour ran, fixed at the accept) and twistPoints (x each twist's points share,
-- still under Config.Events.twistMaxPoints). Plain Lua with stubbed Mission controls: no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
Config.Events = Config.Events or {}
Config.Events.typeOfTheDay = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local defs, values, rows, held = {}, {}, {}, false
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    get = function(dept, key)
        local v = values[dept or '*'] and values[dept or '*'][key]
        if v ~= nil then return v, rows[key] end
        return defs[key] and defs[key].configValue() or nil
    end,
    heldBy = function() return held end,
}

H.load('modules/happyhour/server.lua')
H.load('modules/events/server.lua')
H.load('modules/scaling/server.lua')
H.load('modules/scoring/server.lua')
local HH, E, S = CP.HappyHour, CP.Events, CP.Scoring
local MC = Config.MissionControls.controls
local SAST = { { citizenid = 'SAST1' } }

-- The final points of a run of P = 100, one officer, the standard tier (x1.0), no fast finish.
local function Points(extra, result)
    local p = { src = 1, department = 'sast', status = 'active', score = {}, vehicle = { seen = false } }
    local run = {
        id = 1,
        missionType = 'patrol',
        mission = { type = 'patrol', points = 100 },
        pointsBase = 100,
        payTier = { tier = 'standard', points = 1.0, cash = 1.0 },
        participants = { [1] = p },
        order = { 1 },
        shared = {},
        startedAt = os.time() - 300,
    }
    for k, v in pairs(extra or {}) do run[k] = v end
    local b = S.compute(run, p, result or 'completed', { durationS = 300, departments = 1 })
    return b.final, b
end

-- ============================================================================
--                            SHIPPED: NOTHING MOVES
-- ============================================================================

for _, key in ipairs({ 'happyHourPoints', 'twistPoints' }) do
    H.eq(MC[key].on, false, key .. ' ships off')
    H.ok(MC[key].min == 1.0 and MC[key].max == 1.0, key .. ' ships with min = max = 1.0 (moves nothing)')
    H.eq(defs[key].scope, 'run', key .. ' is read at the accept')
end
H.eq(defs.happyHourPoints.kind, 'number', 'happyHourPoints: one multiplier')
H.eq(defs.twistPoints.kind, 'map', 'twistPoints: a multiplier per twist')
H.eq(defs.twistPoints.configValue().armored_hostiles, 1.0, 'twistPoints config value x1.0 per enabled twist')
local plainPts, plain = Points()
H.ok(plainPts == 100 and plain.mBonus == nil and plain.tod == false, 'a plain run scores P')
local armored = { modifiers = { 'armored_hostiles' } }
H.eq((Points(armored)), 125, 'a twist adds its config share')
H.eq((Points({ modifiers = armored.modifiers, controls = { twistPoints = defs.twistPoints.configValue() } })), 125,
    'the config twist points value changes nothing')

-- ============================================================================
--                         SAST HAPPY HOUR POINTS x1.2
-- ============================================================================

H.eq(HH.pointsBonusFor(1.2, SAST), nil, 'no happy hour running: no bonus at the accept')
values['*'] = { happyHour = { minutes = 15, noRepeat = 0 } }
rows.happyHour = { expiresAt = os.time() + 600, setBy = 'SUP1' }
local bonus = HH.pointsBonusFor(1.2, SAST)
H.eq(bonus, 1.2, 'a SAST-led run accepted in the window carries x1.2')
H.eq(HH.pointsBonusFor(1.0, SAST), nil, 'x1.0 (the shipped bounds) is no bonus')
held = true
H.eq(HH.pointsBonusFor(1.2, SAST), nil, 'the one who started the happy hour (and his unit) gets none')
held = false

local during = { controls = { pointsBonus = bonus } }
local pts, b = Points(during)
H.eq(pts, 120, 'accepted in the window: x1.2 points')
H.eq(b.mBonus, 1.2, 'the breakdown names the bonus (the result card shows it)')
rows.happyHour = { expiresAt = os.time() - 1, setBy = 'SUP1' }
H.eq(HH.pointsBonusFor(1.2, SAST), nil, 'accepted after the hour: no bonus')
H.eq((Points(during)), 120, 'the hour ending never cuts a run accepted in it')
H.eq((Points({ controls = { pointsBonus = 1.2 }, modifiers = armored.modifiers })), 150, 'after the twist: 125 x1.2')

local failedPts, failed = Points(during, 'failed')
H.ok(failedPts == (Points(nil, 'failed')) and failed.mBonus == nil, 'a failed run: no bonus (completed runs only)')
H.eq((Points({ test = {}, controls = { pointsBonus = 1.2 } })), 100, 'none on a test run')
H.eq((Points({ isBoss = true, controls = { pointsBonus = 1.2 } })), 100, 'none on the Weekly Boss')
H.eq((Points({ operationId = 4, controls = { pointsBonus = 1.2 } })), 100, 'none on a Cross-Department run')

-- ============================================================================
--                                 TWIST POINTS
-- ============================================================================

local open = { min = 1.0, max = 2.0 }
H.eq(defs.twistPoints.check({ armored_hostiles = 1.5 }, open).armored_hostiles, 1.5, 'inside the bounds: kept')
H.eq(defs.twistPoints.check({ armored_hostiles = 2.5 }, open), nil, 'above the admin max: refused')
H.eq(defs.twistPoints.check({ armored_hostiles = 1.1 }, MC.twistPoints), nil, 'the shipped bounds refuse any raise')
H.ok(defs.twistPoints.relaxes({ time_crunch = 1.1 }) and not defs.twistPoints.relaxes({ time_crunch = 1.0 }),
    'a raise relaxes (the self rule applies)')

local scale = { armored_hostiles = 2.0 }
H.eq((Points({ modifiers = armored.modifiers, controls = { twistPoints = scale } })), 150,
    'Armored Hostiles 0.25 x the department 2 = +50')
local two = {
    modifiers = { 'armored_hostiles', 'time_crunch' },
    controls = { twistPoints = { armored_hostiles = 2.0, time_crunch = 2.0 } },
}
H.eq((Points(two)), 170, 'two raised twists never above Config.Events.twistMaxPoints (0.70)')
H.eq(CP.Twists.bonus({ 'armored_hostiles' }, nil, scale).cash, CP.Twists.bonus({ 'armored_hostiles' }).cash,
    'cash never changes')
local function Raised(extra)
    local run = { modifiers = armored.modifiers, controls = { twistPoints = scale } }
    for k, v in pairs(extra) do run[k] = v end
    return (Points(run))
end
H.eq(Raised({ test = {} }), 125, 'twist points: none on a test run')
H.eq(Raised({ operationId = 2 }), 125, 'twist points: none on a Cross-Department run')

local function PointsOf(list, key)
    for _, o in ipairs(list) do
        if o.key == key then return o.points end
    end
end
local mission = { { id = 'x', type = 'tactical', objectives = {} } }
H.eq(PointsOf(E.twistOffer('tactical', mission, 'sast'), 'radio_silence'), 0.25,
    'the accept step: a twist without a raise shows its config share')
values.sast = { twistPoints = { radio_silence = 2.0 } }
H.eq(PointsOf(E.twistOffer('tactical', mission, 'sast'), 'radio_silence'), 0.5,
    'the accept step shows the department\'s raised twist points')

return H
