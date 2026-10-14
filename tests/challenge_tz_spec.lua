-- Season weeks of CP.Challenge when the database and the game server run in different time zones: a run
-- near the weekly reset counts in the week of the server's calendar, whatever the database's zone is.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ============================================================================
--                           OTHER ZONES (CHILD RUNS)
-- ============================================================================
-- The parent runs the checks again under three zones MariaDB does not use (MariaDB keeps the machine's
-- UTC). Shadow mode compares with MariaDB's UTC dates, so it stays in one zone.

local CHILD = os.getenv('CP_TZ_CHILD') == '1'
if not CHILD and H.storage ~= 'shadow' then
    for _, tz in ipairs({ 'America/New_York', 'Europe/Berlin', 'Asia/Kolkata' }) do
        local p = io.popen(
            ('TZ=\'%s\' CP_TZ_CHILD=1 lua5.4 tests/run.lua --child tests/challenge_tz_spec.lua 2>&1'):format(tz))
        local out = p:read('a')
        p:close()
        local pass, fail = out:match('RESULT (%d+) (%d+)')
        H.ok(pass ~= nil and tonumber(pass) > 0, ('%s: the child ran its checks'):format(tz))
        H.eq(tonumber(fail), 0, ('%s: no week was wrong'):format(tz))
        for line in out:gmatch('[^\n]+') do
            if line:find('FAIL', 1, true) then print(('  [%s]%s'):format(tz, line)) end
        end
    end
end

-- ============================================================================
--                                    SETUP
-- ============================================================================

local function Ts(y, m, d, h, mi, s)
    return os.time({ year = y, month = m, day = d, hour = h or 12, min = mi or 0, sec = s or 0 })
end
H.time = Ts(2026, 9, 23, 12)

Config.Departments = {
    sast = { label = 'San Andreas State Troopers', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3 },
}
CP.Access = {
    getOfficer = function() return nil, 'err.not_police' end,
    isAdmin = function() return false end,
    isSupervisor = function() return false end,
    department = function(key) return { key = key, label = 'SAST', short = 'SAST', theme = {} } end,
    departments = function() return { CP.Access.department('sast') } end,
}
CP.Admin = {
    audit = function() end,
    webhook = function() return true end,
}
CP.Tablet = { notify = function() end }

H.load('modules/permissions/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/challenge/server.lua')
local C = CP.Challenge

for _, t in ipairs({ 'cp_mission_runs', 'cp_seasons', 'cp_dept_bounties' }) do H.sql('DELETE FROM ' .. t) end
H.sql('INSERT INTO cp_seasons (name, starts_at, active) VALUES (?, FROM_UNIXTIME(?), 1)',
    { 'Zone Season', Ts(2026, 9, 10, 12) })
local SID = C.currentSeason(true).id

local uuidN = 0
local function Row(at)
    uuidN = uuidN + 1
    H.sql([[
INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, participants, departments_n,
  state, end_reason, points_base, final_points, cash_paid, cash_status, cash_base, cash_multiplier, flagged, voided,
  season_id, created_at)
VALUES (?, 'tactical', 'gang_shootout', 'S1', 'sast', 1, 1, 'completed', 'completed', 60, 100, 0, 'none', 0, 1.0, 0, 0,
  ?, FROM_UNIXTIME(?))]], { ('tz-%04d'):format(uuidN), SID, at })
end

local function Tactical(data, n)
    local w = data.weeks[n]
    return (w and w.sast and w.sast.tactical) or 0
end

-- ============================================================================
--                                    CHECKS
-- ============================================================================

-- reset hour 0: week 2 starts Monday 14 Sep 00:00 on the server's calendar
do
    Config.Time.resetHour = 0
    local season = C.seasonById(SID)
    local cases = {
        { Ts(2026, 9, 13, 22), 1, 'Sunday 22:00' },
        { Ts(2026, 9, 13, 23, 59, 59), 1, 'Sunday 23:59:59' },
        { Ts(2026, 9, 14, 0, 0, 0), 2, 'Monday 00:00:00' },
        { Ts(2026, 9, 14, 1), 2, 'Monday 01:00' },
        { Ts(2026, 9, 20, 23, 30), 2, 'Sunday 20 Sep 23:30' },
        { Ts(2026, 9, 21, 0, 15), 3, 'Monday 21 Sep 00:15' },
    }
    for _, c in ipairs(cases) do
        H.eq(C._weekIndex(season, c[1]), c[2], c[3] .. ': week by the server calendar')
        Row(c[1])
    end
    local data = C._collect(SID, true)
    H.eq(Tactical(data, 1), 2, 'week 1 holds the two Sunday runs')
    H.eq(Tactical(data, 2), 3, 'week 2 holds the Monday runs and the late Sunday of week 2')
    H.eq(Tactical(data, 3), 1, 'week 3 holds the Monday 21 Sep run')
    H.eq(data.weeks[2].sast.points, 300, 'week 2 points')
end

-- reset hour 6: Monday 05:00 is still week 1
do
    H.sql('DELETE FROM cp_mission_runs')
    Config.Time.resetHour = 6
    Row(Ts(2026, 9, 14, 5, 59, 59))
    Row(Ts(2026, 9, 14, 6, 0, 0))
    Row(Ts(2026, 9, 14, 7))
    local data = C._collect(SID, true)
    H.eq(Tactical(data, 1), 1, 'reset hour 6: 05:59:59 is week 1')
    H.eq(Tactical(data, 2), 2, 'reset hour 6: 06:00 and 07:00 are week 2')
    Config.Time.resetHour = 0
end

return H
