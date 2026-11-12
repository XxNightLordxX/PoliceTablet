-- Config.Objectives: the daily goal, the weekly goal, the department challenge, the weekly bounty and the Type

-- Config.Objectives: the daily goal, the weekly goal, the department challenge, the weekly bounty and the Type
-- of the Day are one config section, each kind with its own switch, points (or multiplier) and picking rules. One
-- block per old feature, driven through the new section: what the shipped config gives is what the server gave
-- before, and each kind's switch turns only that kind off. Plain stubs, no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

local DAY = 86400
CP.Schedule = {
    now = function() return H.time or os.time() end,
    dayKey = function(ts) return os.date('!%Y-%m-%d', ts or os.time()) end,
    dayStart = function(ts)
        ts = ts or os.time()
        return ts - ts % DAY
    end,
    weekStart = function(ts)
        ts = ts or os.time()
        return ts - ts % (7 * DAY)
    end,
    weekKey = function(ts)
        ts = ts or os.time()
        return os.date('!%Y-%m-%d', ts - ts % (7 * DAY))
    end,
}
CP.Admin = {
    audit = function() end,
    webhook = function() return true end,
}
CP.Tablet = { notify = function() end }

H.load('modules/progression/goals.lua')
H.load('modules/progression/events.lua')
H.load('modules/progression/challenge.lua')
local G, E, C = CP.Goals, CP.Events, CP.Challenge
local O = Config.Objectives
local shipped = CP.U.deepcopy(O)

-- ============================================================================
--                               THE ONE SECTION
-- ============================================================================

H.eq(Config.Goals, nil, 'no Config.Goals: the goals are Config.Objectives.dailyGoal / weeklyGoal')
H.eq(Config.Challenge, nil, 'no Config.Challenge: the challenge and the bounty are Config.Objectives kinds')
H.eq(Config.Events.typeOfTheDay, nil, 'the Type of the Day left Config.Events')
H.eq(Config.Events.todMultiplier, nil, 'and its multiplier too')
for _, kind in ipairs({ 'dailyGoal', 'weeklyGoal', 'challenge', 'bounty', 'typeOfTheDay' }) do
    local cfg, on = CP.Objective(kind)
    H.eq(cfg, O[kind], kind .. ': CP.Objective answers the config table')
    H.eq(on, true, kind .. ': ships on, as before')
end
H.eq(next((CP.Objective('nosuch'))), nil, 'an unknown kind: an empty table')
H.eq(select(2, CP.Objective('nosuch')), false, 'and off')

-- ============================================================================
--                            DAILY AND WEEKLY GOALS
-- ============================================================================

H.eq(#O.dailyGoal.goals, 5, 'the five shipped daily goals')
H.eq(#O.weeklyGoal.goals, 5, 'the five shipped weekly goals')
H.eq(O.dailyGoal.points, 50, 'daily goal: 50 points as before')
H.eq(O.weeklyGoal.points, 200, 'weekly goal: 200 points as before')
local daily = G._pick('daily', 'CID1', nil, false)
local weekly = G._pick('weekly', 'CID1', nil, false)
H.ok(daily ~= nil and weekly ~= nil, 'each officer gets one daily and one weekly goal')
local inDaily = false
for _, g in ipairs(O.dailyGoal.goals) do inDaily = inDaily or g.id == daily.id end
H.ok(inDaily, 'the daily goal comes from Config.Objectives.dailyGoal.goals')
H.eq(G._pick('daily', 'CID1', nil, false).id, daily.id, 'the same goal all day (seeded, nothing stored)')
O.dailyGoal.goals = { { id = 'only_one', label = 'Only one', count = 1 } }
H.eq(G._pick('daily', 'CID1', nil, false).id, 'only_one', 'a changed list is read at once')
O.dailyGoal.enabled = false
H.eq(G._pick('daily', 'CID1', nil, false), nil, 'dailyGoal.enabled = false: no daily goal')
H.ok(G._pick('weekly', 'CID1', nil, false) ~= nil, 'the weekly goal keeps its own switch')
O.weeklyGoal.enabled = false
H.eq(G._pick('weekly', 'CID1', nil, false), nil, 'weeklyGoal.enabled = false: no weekly goal')
local view = G.forOfficer('CID1', false)
H.eq(view.daily, nil, 'the officer\'s goals view: no daily goal while it is off')
H.eq(view.weekly, nil, 'nor a weekly one')
Config.Objectives = CP.U.deepcopy(shipped)
O = Config.Objectives

-- ============================================================================
--                               TYPE OF THE DAY
-- ============================================================================

H.eq(O.typeOfTheDay.multiplier, 2.0, 'Type of the Day: x2 points as before')
local roll = E.rolledTypeOfTheDay()
H.ok(roll ~= nil and Config.MissionTypes[roll] ~= nil, 'one mission type a day')
H.eq(E.typeOfTheDay(), roll, 'no override: the day\'s roll')
O.typeOfTheDay.enabled = false
H.eq(E.rolledTypeOfTheDay(), nil, 'typeOfTheDay.enabled = false: no roll')
H.eq(E.typeOfTheDay(), nil, 'and no Type of the Day at all')
O.typeOfTheDay.enabled = true
H.eq(E.typeOfTheDay(), roll, 'switched back on: the same day\'s type')

-- ============================================================================
--                    DEPARTMENT CHALLENGE AND WEEKLY BOUNTY
-- ============================================================================

local r = C._rules()
H.eq(r.on, true, 'the department challenge ships on')
H.eq(r.bountyOn, true, 'the weekly bounty ships on')
H.near(r.bonus, 0.10, 1e-9, 'the bounty bonus: +10 % as before')
H.eq(r.minActive, 3, 'an active officer: 3 runs as before')
H.eq(r.mode, 'average', 'scored per active officer as before')
O.challenge.scoring = 'top10'
O.challenge.minRunsActive = 5
O.bounty.bonus = 0.25
r = C._rules()
H.ok(r.mode == 'top10' and r.minActive == 5 and math.abs(r.bonus - 0.25) < 1e-9,
    'the challenge reads Config.Objectives.challenge and .bounty')
local ids = {}
for _, b in ipairs(O.bounty.objectives) do ids[b.id] = true end
H.ok(ids[C._pickBounty(1, 1)] == true, 'the bounty is picked from Config.Objectives.bounty.objectives')
O.bounty.objectives = { { id = 'most_arrests', label = 'Most arrests' } }
H.eq(C._pickBounty(1, 2), 'most_arrests', 'a changed bounty list is read at once')
O.bounty.enabled = false
r = C._rules()
H.ok(r.on == true and r.bountyOn == false, 'bounty.enabled = false: no bounty, the challenge stays')
O.bounty.enabled = true
O.challenge.enabled = false
r = C._rules()
H.ok(r.on == false and r.bountyOn == false, 'challenge.enabled = false: no challenge and so no bounty')
H.eq(select(2, CP.Objective('bounty')), false, 'CP.Objective says the same')
Config.Objectives = CP.U.deepcopy(shipped)

-- ============================================================================
--                         PER-KIND RESET HOURS (FIN3)
-- ============================================================================
-- Config.Objectives.dailyGoal / weeklyGoal / typeOfTheDay .resetHour: each kind's day or week starts at its own hour;
-- -1 (shipped) = Config.Time.resetHour, as before.

O = Config.Objectives
H.eq(O.dailyGoal.resetHour, -1, 'dailyGoal.resetHour ships -1 (the server reset hour, as before)')
H.eq(O.weeklyGoal.resetHour, -1, 'weeklyGoal.resetHour ships -1')
H.eq(O.typeOfTheDay.resetHour, -1, 'typeOfTheDay.resetHour ships -1')
H.eq(CP.ObjectiveResetHour('dailyGoal'), nil, '-1: no own hour (CP.Schedule uses Config.Time.resetHour)')
do
    local S = CP.Schedule
    local saved = { dayKey = S.dayKey, dayStart = S.dayStart, weekStart = S.weekStart, weekKey = S.weekKey }
    local hours = {}
    for name, fn in pairs(saved) do
        S[name] = function(ts, hour)
            hours[name] = hour == nil and 'none' or hour
            return fn(ts)
        end
    end
    G._pick('daily', 'CID1', nil, false)
    H.eq(hours.dayStart, 'none', 'the shipped daily goal asks for the server day')
    O.dailyGoal.resetHour = 6
    O.weeklyGoal.resetHour = 18
    O.typeOfTheDay.resetHour = 3
    hours = {}
    G._pick('daily', 'CID1', nil, false)
    H.eq(hours.dayStart, 6, 'dailyGoal.resetHour = 6: the daily goal day starts at 06:00')
    hours = {}
    G._pick('weekly', 'CID1', nil, false)
    H.eq(hours.weekStart, 18, 'weeklyGoal.resetHour = 18: the weekly goal week starts at 18:00')
    hours = {}
    E.todDay()
    H.eq(hours.dayKey, 3, 'typeOfTheDay.resetHour = 3: the Type of the Day changes at 03:00')
    O.dailyGoal.resetHour = 24
    H.eq(CP.ObjectiveResetHour('dailyGoal'), nil, 'an hour outside 0-23 is the server reset hour')
    for name, fn in pairs(saved) do S[name] = fn end
    -- the real calendar with an own hour
    local stub = CP.Schedule
    CP.Schedule = nil
    H.load('modules/system/schedule.lua')
    local real = CP.Schedule
    CP.Schedule = stub
    Config.Time.resetHour = 0
    local ts = os.time({ year = 2026, month = 3, day = 10, hour = 5, min = 0, sec = 0 })
    H.eq(real.dayKey(ts), '2026-03-10', 'server reset 00:00: 05:00 is that day')
    H.eq(real.dayKey(ts, 6), '2026-03-09', 'own hour 06:00: 05:00 still belongs to the day before')
    H.eq(real.dayStart(ts, 6), os.time({ year = 2026, month = 3, day = 9, hour = 6, min = 0, sec = 0 }),
        'and that day started at 06:00')
end
Config.Objectives = CP.U.deepcopy(shipped)

return H
