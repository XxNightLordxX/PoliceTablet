-- A department's goals (step P21): a supervisor picks which of the admin's daily and weekly goals (Config.Goals) his
-- department's officers draw theirs from, counting from the next weekly reset; the points never change, other
-- departments and the setter keep the admin's whole lists. Plain Lua: stubbed controls, schedule and SQL.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local DAY, WEEK = 86400, 7 * 86400
local MONDAY0 = 4 * DAY                           -- 1970-01-05, a Monday (UTC)
local function WeekStart(ts) return ts - (ts - MONDAY0) % WEEK end
local W1 = WeekStart(os.time()) + 2 * DAY + 3600  -- a Wednesday
local NOW = W1
CP.Schedule = {
    now = function() return NOW end,
    dayKey = function(ts) return os.date('!%Y-%m-%d', ts or NOW) end,
    dayStart = function(ts)
        ts = ts or NOW
        return ts - ts % DAY
    end,
    weekStart = function(ts) return WeekStart(ts or NOW) end,
    weekKey = function(ts) return os.date('!%Y-%m-%d', WeekStart(ts or NOW)) end,
}
CP.Qbx = {
    getByCitizenId = function() return nil end,
}

-- the control: on for SAST only while 'on'; one saved row per department
local defs, on, rows = {}, false, {}
local function Bounds() return Config.MissionControls.controls.goals end
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    active = function(dept, key) return on and key == 'goals' and dept == 'sast' end,
    bounds = function() return Bounds() end,
    get = function(dept, key, officer)
        local def = defs[key]
        local cfg = def.configValue()
        local row = rows[dept]
        if not (on and dept == 'sast' and row) then return cfg end
        local v = def.clamp(row.value, Bounds())
        if v == nil then return cfg end
        if type(officer) == 'table' and officer.citizenid == row.setBy then return cfg end
        return v
    end,
}

-- SQL: an officer's department (S... = SAST, F... = FIB); no goal progress and no goal reward yet
local deptReads = 0
MySQL = MySQL or {}
MySQL.scalar = MySQL.scalar or {}
MySQL.scalar.await = function(sql, args)
    if sql:find('SELECT department FROM cp_officers', 1, true) then
        deptReads = deptReads + 1
        return args[1]:sub(1, 1) == 'S' and 'sast' or 'fib'
    end
    if sql:find('COUNT(*)', 1, true) or sql:find('SUM(', 1, true) then return 0 end
    return nil
end
CP.Migrations = {
    ready = function() return true end,
}

H.load('modules/goals/server.lua')
local G = CP.Goals
local def = defs.goals

-- The same seed with a 'kind' list narrowed to ids: the goal an officer gets.
local CIDS = {}
for i = 1, 40 do CIDS[i] = ('S%04d'):format(i) end
local function Ids(kind, ts, prefix)
    local seen = {}
    for _, cid in ipairs(CIDS) do
        local g = G._pick(kind, (prefix or '') .. cid, ts)
        seen[g.id] = true
    end
    local out = {}
    for id in pairs(seen) do out[#out + 1] = id end
    table.sort(out)
    return table.concat(out, ',')
end

-- ============================================================================
--                            SHIPPED: NOTHING MOVES
-- ============================================================================

local MC = Config.MissionControls.controls
H.ok(MC.goals.on == false and MC.goals.min == 1 and MC.goals.max == 5, 'goals ships off (pick 1 to 5)')
H.ok(def ~= nil and def.kind == 'map', 'the goals control is registered')
local cfg = def.configValue()
H.ok(#cfg.daily == 0 and #cfg.weekly == 0, 'no pick: every goal')
H.ok(def.relaxes(), 'a pick relaxes: the setter keeps the whole lists')
local allWeekly = Ids('weekly', W1)
local allDaily = Ids('daily', W1)
H.ok(select(2, allWeekly:gsub(',', '')) >= 3, 'the admin\'s whole weekly list is drawn (' .. allWeekly .. ')')
H.eq(deptReads, 0, 'control off: no department is read')

-- ============================================================================
--                                  THE CHECK
-- ============================================================================

local function Check(v) return (def.check(v, { min = 1, max = 2 })) end
local ok = Check({ daily = { 'arrests_2' }, weekly = { 'impound_3', 'any_15' } })
H.ok(ok and ok.daily[1] == 'arrests_2' and ok.weekly[1] == 'any_15' and ok.weekly[2] == 'impound_3',
    'a pick inside the bounds, in the admin\'s order')
H.eq(Check({ daily = { 'nope' }, weekly = {} }), nil, 'an unknown goal is refused')
H.eq(Check({ daily = { 'any_15' }, weekly = {} }), nil, 'a weekly goal in the daily list is refused')
H.eq(Check({ daily = { 'any_3', 'any_3' }, weekly = {} }), nil, 'a repeat is refused')
H.eq(Check({ daily = { 'any_3', 'patrol_2', 'unit_1' }, weekly = {} }), nil, 'more than max is refused')
H.eq(Check({ daily = {}, weekly = {}, from = '2000-01-03' }), nil, 'the week it counts from is the server\'s')
H.ok(Check({ daily = {}, weekly = {} }) ~= nil, 'none picked (every goal) is allowed')

-- ============================================================================
--           A PICK COUNTS FROM THE NEXT WEEKLY RESET, FOR SAST ONLY
-- ============================================================================

on = true
local PICK = { daily = { 'patrol_2' }, weekly = { 'any_15', 'impound_3' } }
local saved = def.carry({ role = 'supervisor', dept = 'sast', value = PICK, row = nil })
H.eq(saved.from, os.date('!%Y-%m-%d', WeekStart(W1) + WEEK), 'the pick counts from the next week')
H.eq(saved.prev, nil, 'nothing was picked before: every goal until then')
rows.sast = { value = saved, setBy = 'SUP1' }
H.eq(Ids('weekly', W1), allWeekly, 'this week: SAST officers keep the whole list (no goal changes under them)')
local W2 = W1 + WEEK
H.eq(Ids('weekly', W2), 'any_15,impound_3', 'next week: SAST officers draw from the pick')
H.eq(Ids('daily', W2), 'patrol_2', 'and their daily goals too')
H.ok(deptReads > 0, 'the officer\'s department is read while the control is on')
H.eq(Ids('weekly', W2, 'F'), Ids('weekly', W1, 'F'), 'FIB officers keep the whole list')
H.ok(G._pick('weekly', 'SUP1', W2).id == G._pick('weekly', 'SUP1', W2, false).id, 'the setter keeps the whole list')

-- the points stay the admin's
NOW = W2
local fo = G.forOfficer('S0001', 'sast')
H.ok(fo.weekly and (fo.weekly.id == 'any_15' or fo.weekly.id == 'impound_3'), 'Home shows a picked goal')
H.eq(fo.weekly.points, Config.Goals.weeklyPoints, 'a picked goal pays the admin\'s weekly points')
H.eq(fo.daily.points, Config.Goals.dailyPoints, 'and the daily points')

-- a second change made in that week counts from the week after; the first pick stays until then
local PICK2 = { daily = {}, weekly = { 'cross_2' } }
local saved2 = def.carry({ role = 'supervisor', dept = 'sast', value = PICK2, row = rows.sast })
rows.sast = { value = saved2, setBy = 'SUP1' }
H.eq(Ids('weekly', W2), 'any_15,impound_3', 'a change made this week never moves this week\'s goals')
H.eq(Ids('weekly', W2 + WEEK), 'cross_2', 'it counts from the week after')
H.eq(Ids('daily', W2 + WEEK), allDaily, 'no daily pick: every goal')

-- ============================================================================
--                         WHAT THE ADMIN CHANGES LATER
-- ============================================================================

local keep = Config.Goals.weekly
Config.Goals.weekly = { { id = 'any_15', label = 'Complete 15 missions', count = 15 } }
H.eq(Ids('weekly', W2 + WEEK), 'any_15', 'a picked goal the admin removed: back to the admin\'s list')
Config.Goals.weekly = keep
local cut = def.clamp({ daily = { 'any_3', 'patrol_2', 'unit_1' }, weekly = {} }, { min = 1, max = 2 })
H.eq(#cut.daily, 2, 'a narrower max cuts a saved list')
on = false
H.eq(Ids('weekly', W2), allWeekly, 'the control switched off: every goal at once')
on = true

-- what the supervisor's screen shows
NOW = W2
local view = def.viewExtra('sast')
H.eq(view.goalsFrom, os.date('!%Y-%m-%d', WeekStart(W2) + WEEK), 'the week a pick saved now counts from')
H.eq(table.concat(view.goalsNow.weekly, ','), 'any_15,impound_3', 'the lists that count this week')
H.eq(#view.goalsAll.weekly, #Config.Goals.weekly, 'the admin\'s weekly goals to pick from')
H.ok(CP.L('mc.control.goals') ~= 'mc.control.goals', 'the control has a name')

return H
