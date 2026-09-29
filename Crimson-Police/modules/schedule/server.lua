-- CP.Schedule: server-time calendar, reset boundaries and the retention job.

CP.Schedule = CP.Schedule or {}
local Schedule = CP.Schedule

local TAG = 'schedule'
local CHECK_EVERY_MS = 30000
local RETENTION_CATCHUP_DELAY_MS = 120000

local WEEKDAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }  -- os.date wday order

local listeners = { daily = {}, weekly = {}, monthly = {} }
local last = nil          -- { day, week, weekStart, month } seen by the previous check
local retentionBusy = false

-- ============================================================================
--                               CALENDAR HELPERS
-- ============================================================================

local function ResetHour()
    local h = tonumber(Config.Time and Config.Time.resetHour) or 0
    h = math.floor(h)
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function WeekStartIndex()
    local name = tostring((Config.Leaderboard and Config.Leaderboard.weekStartsOn) or 'monday'):lower()
    for i, n in ipairs(WEEKDAYS) do
        if n == name then return i end
    end
    return 2   -- monday
end

-- The calendar date (y, m, d) of the reset-adjusted day that contains ts.
-- Uses date arithmetic with os.time normalisation (not "- 3600 * h"), so DST shifts never move a day.
local function AdjustedDate(ts)
    ts = ts or os.time()
    local t = os.date('*t', ts)
    if t.hour < ResetHour() then
        local prev = os.date('*t',
            os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12, min = 0, sec = 0 }))
        return prev.year, prev.month, prev.day, prev.wday
    end
    return t.year, t.month, t.day, t.wday
end

local function AtReset(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = ResetHour(), min = 0, sec = 0 })
end

function Schedule.now()
    return os.time()
end

function Schedule.dayKey(ts)
    local y, m, d = AdjustedDate(ts)
    return ('%04d-%02d-%02d'):format(y, m, d)
end

function Schedule.dayStart(ts)
    local y, m, d = AdjustedDate(ts)
    return AtReset(y, m, d)
end

function Schedule.weekStart(ts)
    local y, m, d, wday = AdjustedDate(ts)
    local back = (wday - WeekStartIndex()) % 7
    return AtReset(y, m, d - back)
end

function Schedule.weekKey(ts)
    return os.date('%Y-%m-%d', Schedule.weekStart(ts))
end

function Schedule.monthStart(ts)
    local y, m = AdjustedDate(ts)
    return AtReset(y, m, 1)
end

function Schedule.weekday(ts)
    local _, _, _, wday = AdjustedDate(ts)
    return WEEKDAYS[wday]
end

function Schedule.sqlTime(ts)
    return os.date('%Y-%m-%d %H:%M:%S', math.floor(tonumber(ts) or os.time()))
end

-- ============================================================================
--                                  LISTENERS
-- ============================================================================

local function AddListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'on%s expects a function, got %s', kind, type(fn))
        return false
    end
    local list = listeners[kind]
    list[#list + 1] = fn
    return true
end

function Schedule.onDaily(fn) return AddListener('daily', fn) end
function Schedule.onWeekly(fn) return AddListener('weekly', fn) end
function Schedule.onMonthly(fn) return AddListener('monthly', fn) end

local function Fire(kind, ...)
    for i, fn in ipairs(listeners[kind]) do
        local ok, err = pcall(fn, ...)
        if not ok then CP.err(TAG, '%s listener #%d failed: %s', kind, i, tostring(err)) end
    end
end

-- ============================================================================
--                                RETENTION JOB
-- ============================================================================
-- months months before ts, same wall-clock time (os.time normalises month underflow).
local function MonthsBefore(ts, months)
    local t = os.date('*t', ts)
    return os.time({ year = t.year, month = t.month - months, day = t.day, hour = t.hour, min = t.min, sec = t.sec })
end

local function ArchiveRuns(nowTs)
    local months = math.floor(tonumber(Config.Retention and Config.Retention.runArchiveMonths) or 0)
    if months <= 0 then return 0 end
    local cutoff = MonthsBefore(nowTs, months)
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS n, MAX(id) AS max_id FROM cp_mission_runs WHERE created_at < FROM_UNIXTIME(?)', { cutoff })
    local n = CP.U.num(row and row.n)
    local maxId = CP.U.num(row and row.max_id)
    if n <= 0 or maxId <= 0 then return 0 end
    -- INSERT IGNORE keeps a re-run idempotent if an earlier run copied rows but failed to delete them.
    local copied = CP.U.num(MySQL.update.await(
        'INSERT IGNORE INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE id <= ? AND created_at < FROM_UNIXTIME(?)',
        { maxId, cutoff }))
    -- Only rows whose own copy is in the archive are removed: the archive row must match on id AND
    -- run_uuid, citizenid and created_at. A live row whose id collides with a different archived row (an
    -- AUTO_INCREMENT counter reset after a restore) was skipped by INSERT IGNORE and stays in place.
    local deleted = CP.U.num(MySQL.update.await(
        'DELETE r FROM cp_mission_runs r INNER JOIN cp_mission_runs_archive a ON a.id = r.id AND a.run_uuid = r.run_uuid AND a.citizenid = r.citizenid AND a.created_at = r.created_at WHERE r.id <= ? AND r.created_at < FROM_UNIXTIME(?)',
        { maxId, cutoff }))
    if deleted < n then
        CP.warn(TAG,
            'retention: %d of %d old run rows could not be archived (copied %d; an id already in cp_mission_runs_archive holds a different row); they stay in cp_mission_runs',
            n - deleted, n, copied)
    end
    return deleted
end

local function PurgeAudit(nowTs)
    local days = math.floor(tonumber(Config.Retention and Config.Retention.auditDays) or 0)
    if days <= 0 then return 0 end
    local cutoff = nowTs - days * 86400
    return CP.U.num(MySQL.update.await('DELETE FROM cp_audit WHERE created_at < FROM_UNIXTIME(?)', { cutoff }))
end

local function RunRetention(nowTs)
    if retentionBusy then
        CP.log(TAG, 'retention already running; skipped')
        return { archived = 0, auditDeleted = 0, skipped = true }
    end
    retentionBusy = true
    nowTs = nowTs or os.time()
    local result = { archived = 0, auditDeleted = 0 }
    local ok, err = pcall(function()
        CP.Migrations.ready()
        result.archived = ArchiveRuns(nowTs)
        result.auditDeleted = PurgeAudit(nowTs)
    end)
    retentionBusy = false
    if not ok then
        CP.err(TAG, 'retention job failed: %s', tostring(err))
        result.error = tostring(err)
        return result
    end
    if result.archived > 0 or result.auditDeleted > 0 then
        print(('[crimson-police] retention: %d run rows archived, %d audit rows deleted'):format(result.archived,
            result.auditDeleted))
    end
    CP.log(TAG, 'retention done: archived=%d audit=%d', result.archived, result.auditDeleted)
    return result
end

Schedule._runRetention = RunRetention

-- ============================================================================
--                                BOUNDARY CHECK
-- ============================================================================

local function Snapshot(ts)
    return {
        day = Schedule.dayKey(ts),
        week = Schedule.weekKey(ts),
        weekStart = Schedule.weekStart(ts),
        month = Schedule.monthStart(ts),
    }
end

-- One check; the first call only records the current period (nothing fires on start).
function Schedule._check(ts)
    ts = ts or os.time()
    local cur = Snapshot(ts)
    if not last then
        last = cur
        return { daily = false, weekly = false, monthly = false }
    end
    local prev = last
    last = cur
    local fired = { daily = false, weekly = false, monthly = false }
    if cur.day < prev.day then
        -- The clock went backwards (manual change or NTP step): record it, fire nothing.
        CP.warn(TAG, 'server clock moved back from %s to %s; no reset fired', prev.day, cur.day)
        return fired
    end
    if cur.day ~= prev.day then
        fired.daily = true
        CP.log(TAG, 'daily reset: %s -> %s', prev.day, cur.day)
        Fire('daily', cur.day)
        -- The retention job runs in its own thread so a slow archive never delays the reset listeners
        -- (Type of the Day, goals, streaks, the daily cash cap) or the next boundary check.
        CreateThread(function() RunRetention(ts) end)
    end
    if cur.week ~= prev.week then
        fired.weekly = true
        CP.log(TAG, 'weekly reset: %s -> %s', prev.week, cur.week)
        Fire('weekly', cur.week, prev.weekStart)
    end
    if cur.month ~= prev.month then
        fired.monthly = true
        CP.log(TAG, 'monthly reset: %s', os.date('%Y-%m-%d', cur.month))
        Fire('monthly', cur.month)
    end
    return fired
end

CreateThread(function()
    Schedule._check()   -- records the current period only
    while true do
        Wait(CHECK_EVERY_MS)
        local ok, err = pcall(Schedule._check)
        if not ok then CP.err(TAG, 'boundary check failed: %s', tostring(err)) end
    end
end)

-- Catch-up retention once after start, so a server that always restarts across the reset hour
-- still archives. Idempotent: it only moves rows that are already past the cutoff.
CreateThread(function()
    Wait(RETENTION_CATCHUP_DELAY_MS)
    RunRetention()
end)
