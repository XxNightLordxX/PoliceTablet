-- A department's Type of the Day (step P18): a supervisor picks one mission type for tomorrow; that day his

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local defs, on = {}, false
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    active = function(dept, key) return on and key == 'typeOfTheDay' and dept ~= nil end,
    -- the self rule: the setter's citizenid among the officer, the unit's members or the run's participants
    heldBy = function(who, row)
        local list = type(who) == 'table' and type(who.citizenid) == 'string' and { who } or who
        for _, m in pairs(type(list) == 'table' and list or {}) do
            if type(m) == 'table' and m.citizenid == row.setBy then return true end
        end
        return false
    end,
}

local DAY = 86400
local NOW = os.time()
local TODAY = NOW - NOW % DAY
CP.Schedule = {
    dayKey = function(ts) return os.date('!%Y-%m-%d', ts or os.time()) end,
    dayStart = function(ts)
        ts = ts or os.time()
        return ts - ts % DAY
    end,
}

-- cp_audit: the rows of each department's Type of the Day changes, newest first per target.
local audit, reads = {}, 0
CP.Migrations = {
    ready = function() return true end,
}
MySQL = MySQL or {}
MySQL.single = MySQL.single or {}
MySQL.single.await = function(sql, args)
    if not sql:find('FROM cp_audit', 1, true) or not sql:find('missionControlSet', 1, true) then return nil end
    reads = reads + 1
    for i = #audit, 1, -1 do
        local r = audit[i]
        if r.target == args[1] and r.ts >= args[2] and r.ts < args[3] then return r end
    end
    return nil
end
local function Pick(dept, type, by, ts, action)
    audit[#audit + 1] = {
        target = dept .. ':typeOfTheDay',
        action = action or 'missionControlSet',
        new_value = type,
        actor = by,
        ts = ts,
    }
end

H.load('modules/events/server.lua')
local E = CP.Events
local ROLL = E.rolledTypeOfTheDay()
local PICK = ROLL == 'patrol' and 'training' or 'patrol'   -- a type the server did not roll today
local MC = Config.MissionControls.controls

-- ============================================================================
--                            SHIPPED: NOTHING MOVES
-- ============================================================================

H.eq(MC.typeOfTheDay.on, false, 'typeOfTheDay ships off')
H.eq(defs.typeOfTheDay.kind, 'choice', 'one mission type picked')
H.ok(table.concat(defs.typeOfTheDay.choices(), ','):find('patrol', 1, true) ~= nil, 'every mission type offered')
H.eq(defs.typeOfTheDay.configValue(), nil, 'no pick: the server type')
H.ok(defs.typeOfTheDay.relaxes('patrol'), 'a pick relaxes (the setter is never doubled by it)')
Pick('sast', PICK, 'SUP1', TODAY - DAY + 3600)
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' }), ROLL, 'control off (as shipped): the server type')
H.eq(E.typeOfTheDay(), ROLL, 'no department: the server type')

-- ============================================================================
--                   A SAST PICK MADE YESTERDAY COUNTS TODAY
-- ============================================================================

on = true
E.forgetDeptTod()
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' }), PICK, 'a SAST officer: SAST\'s pick')
H.eq(E.typeOfTheDay(nil, 'fib', { citizenid = 'OFF2' }), ROLL, 'a FIB officer: the server type')
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'SUP1' }), ROLL, 'the setter himself: the server type')
H.eq(E.typeOfTheDay(nil, 'sast', { { citizenid = 'OFF1' }, { citizenid = 'SUP1' } }), ROLL,
    'a unit the setter is in: the server type')
H.eq(E.typeOfTheDay(nil, 'sast'), PICK, 'read for nobody (Live view): the pick')
local n = reads
E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' })
H.eq(reads, n, 'one read per department and day')

-- a pick made today is for tomorrow: today's type does not move
Pick('sast', ROLL, 'SUP2', NOW)
E.forgetDeptTod()
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' }), PICK, 'a change made today never moves today\'s type')
-- a reset yesterday after the pick: no department pick today
Pick('fib', PICK, 'SUP3', TODAY - DAY + 60)
Pick('fib', nil, 'SUP3', TODAY - DAY + 120, 'missionControlReset')
E.forgetDeptTod()
H.eq(E.typeOfTheDay(nil, 'fib', { citizenid = 'OFF2' }), ROLL, 'reset yesterday: the server type')
-- the admin switches the control off: the pick stops at once
on = false
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' }), ROLL, 'switched off: the server type at once')
on = true
-- Type of the Day off in Config.Events: nothing at all
Config.Events.typeOfTheDay = false
H.eq(E.typeOfTheDay(nil, 'sast', { citizenid = 'OFF1' }), nil, 'Events.typeOfTheDay off: no Type of the Day')
Config.Events.typeOfTheDay = true

-- ============================================================================
--                       ONE PICK PER DEPARTMENT PER DAY
-- ============================================================================

local allow = defs.typeOfTheDay.allow
H.eq(allow({ role = 'supervisor', dept = 'sast', value = 'patrol', row = nil }), nil, 'no pick yet: allowed')
H.eq(allow({ role = 'supervisor', dept = 'sast', value = 'patrol', row = { at = NOW - DAY } }), nil,
    'yesterday\'s pick: a new one for tomorrow is allowed')
H.eq(allow({ role = 'supervisor', dept = 'sast', value = 'patrol', row = { at = NOW } }), 'err.tod_picked_today',
    'already picked today: refused')
H.eq(allow({ role = 'admin', dept = 'sast', value = 'patrol', row = { at = NOW } }), nil, 'an admin may correct it')
local view = defs.typeOfTheDay.viewExtra('sast')
H.eq(view.todToday, PICK, 'the screen shows the type that counts today')
H.eq(view.todFor, CP.Schedule.dayKey(TODAY + DAY), 'the screen names the day the pick counts on (tomorrow)')
H.ok(CP.L('err.tod_picked_today') ~= 'err.tod_picked_today', 'the refusal has a text')

-- ============================================================================
--                   SCORING: SAST'S PATROL DOUBLES SAST ONLY
-- ============================================================================
-- Scoring.compute reads Events.typeOfTheDay with the participant's department and the run's participants.

H.load('modules/scaling/server.lua')
H.load('modules/scoring/server.lua')
local function Points(dept, cid, members)
    local p = {
        src = 1,
        department = dept,
        citizenid = nil,
        status = 'active',
        score = {},
        vehicle = { engine = 1000, body = 1000, seen = false },
        cid = cid,
    }
    local parts = { [1] = p }
    for i, m in ipairs(members or {}) do parts[i + 1] = m end
    local run = {
        id = 1,
        missionType = PICK,
        mission = { type = PICK, points = 100 },
        pointsBase = 100,
        payTier = { tier = 'standard', points = 1.0, cash = 1.0 },
        participants = parts,
        order = { 1 },
        shared = {},
        startedAt = os.time() - 300,
    }
    local b = CP.Scoring.compute(run, p, 'completed', { durationS = 300, departments = 1 })
    return b.final, b.tod
end
local sast, sastTod = Points('sast')
local fib, fibTod = Points('fib')
H.ok(sastTod == true and fibTod == false, 'a SAST officer\'s run of SAST\'s type is the Type of the Day, FIB\'s not')
H.eq(sast, fib * 2, 'SAST\'s pick doubles a SAST officer\'s points, not a FIB officer\'s')
local _, setterTod = Points('sast', nil, { { citizenid = 'SUP1', department = 'sast', status = 'active' } })
H.eq(setterTod, false, 'the setter in the run: not doubled')

return H
