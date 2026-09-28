-- modules/schedule/server.lua · CP.Schedule: server-time calendar, reset boundaries and the retention job.
--
-- Owns
--   * the reset-adjusted calendar: every "day" starts at Config.Time.resetHour (server local time),
--     every week at that hour on Config.Leaderboard.weekStartsOn, every month at that hour on the 1st
--   * the boundary listeners (daily, weekly, monthly) other modules subscribe to; checked every 30 s
--     and fired once when a boundary passes, never just because the resource started
--   * the retention job (Config.Retention) run at each daily reset (plus one catch-up run shortly after
--     start, see docs/notes/engine_a.md): cp_mission_runs rows older than runArchiveMonths are copied
--     into cp_mission_runs_archive and then deleted, cp_audit rows older than auditDays are deleted
--
-- Public API (server)
--   CP.Schedule.now() -> ts                          os.time()
--   CP.Schedule.dayKey(ts?) -> 'YYYY-MM-DD'          the reset-adjusted day
--   CP.Schedule.dayStart(ts?) -> ts                  resetHour on that day
--   CP.Schedule.weekStart(ts?) -> ts                 resetHour on Config.Leaderboard.weekStartsOn
--   CP.Schedule.weekKey(ts?) -> 'YYYY-MM-DD'         date of the week start
--   CP.Schedule.monthStart(ts?) -> ts                the 1st of the (reset-adjusted) month at resetHour
--   CP.Schedule.weekday(ts?) -> 'monday'..'sunday'   of the reset-adjusted day
--   CP.Schedule.sqlTime(ts) -> 'YYYY-MM-DD HH:MM:SS' (server local time, for DATETIME columns)
--   CP.Schedule.onDaily(fn(dayKey))
--   CP.Schedule.onWeekly(fn(weekKey, prevWeekStartTs))
--   CP.Schedule.onMonthly(fn(monthStartTs))
--
-- Test hooks (internal): CP.Schedule._check(ts?) runs one boundary check (the 30 s loop calls it);
-- CP.Schedule._runRetention(ts?) -> { archived = n, auditDeleted = n } runs the retention job now.
--
-- Contract interpretations: the retention job also runs once 120 s after start (idempotent catch-up);
-- at the daily reset it runs in its own thread after the daily listeners, so a slow archive never
-- delays them; a clock that moves back to an earlier day fires nothing.

CP.Schedule = CP.Schedule or {}
local Schedule = CP.Schedule

local TAG = 'schedule'
local CHECK_EVERY_MS = 30000
local RETENTION_CATCHUP_DELAY_MS = 120000

local WEEKDAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }  -- os.date wday order

local listeners = { daily = {}, weekly = {}, monthly = {} }
local last = nil          -- { day, week, weekStart, month } seen by the previous check
local retentionBusy = false

-- ── calendar helpers ────────────────────────────────────────────────────────
local function resetHour()
    local h = tonumber(Config.Time and Config.Time.resetHour) or 0
    h = math.floor(h)
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function weekStartIndex()
    local name = tostring((Config.Leaderboard and Config.Leaderboard.weekStartsOn) or 'monday'):lower()
    for i, n in ipairs(WEEKDAYS) do
        if n == name then return i end
    end
    return 2   -- monday
end

-- The calendar date (y, m, d) of the reset-adjusted day that contains ts.
-- Uses date arithmetic with os.time normalisation (not "- 3600 * h"), so DST shifts never move a day.
local function adjustedDate(ts)
    ts = ts or os.time()
    local t = os.date('*t', ts)
    if t.hour < resetHour() then
        local prev = os.date('*t', os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12, min = 0, sec = 0 }))
        return prev.year, prev.month, prev.day, prev.wday
    end
    return t.year, t.month, t.day, t.wday
end

local function atReset(y, m, d)
    return os.time({ year = y, month = m, day = d, hour = resetHour(), min = 0, sec = 0 })
end

function Schedule.now()
    return os.time()
end

function Schedule.dayKey(ts)
    local y, m, d = adjustedDate(ts)
    return ('%04d-%02d-%02d'):format(y, m, d)
end

function Schedule.dayStart(ts)
    local y, m, d = adjustedDate(ts)
    return atReset(y, m, d)
end

function Schedule.weekStart(ts)
    local y, m, d, wday = adjustedDate(ts)
    local back = (wday - weekStartIndex()) % 7
    return atReset(y, m, d - back)
end

function Schedule.weekKey(ts)
    return os.date('%Y-%m-%d', Schedule.weekStart(ts))
end

function Schedule.monthStart(ts)
    local y, m = adjustedDate(ts)
    return atReset(y, m, 1)
end

function Schedule.weekday(ts)
    local _, _, _, wday = adjustedDate(ts)
    return WEEKDAYS[wday]
end

function Schedule.sqlTime(ts)
    return os.date('%Y-%m-%d %H:%M:%S', math.floor(tonumber(ts) or os.time()))
end

-- ── listeners ───────────────────────────────────────────────────────────────
local function addListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'on%s expects a function, got %s', kind, type(fn))
        return false
    end
    local list = listeners[kind]
    list[#list + 1] = fn
    return true
end

function Schedule.onDaily(fn) return addListener('daily', fn) end
function Schedule.onWeekly(fn) return addListener('weekly', fn) end
function Schedule.onMonthly(fn) return addListener('monthly', fn) end

local function fire(kind, ...)
    for i, fn in ipairs(listeners[kind]) do
        local ok, err = pcall(fn, ...)
        if not ok then CP.err(TAG, '%s listener #%d failed: %s', kind, i, tostring(err)) end
    end
end

-- ── retention job ───────────────────────────────────────────────────────────
-- months months before ts, same wall-clock time (os.time normalises month underflow).
local function monthsBefore(ts, months)
    local t = os.date('*t', ts)
    return os.time({ year = t.year, month = t.month - months, day = t.day, hour = t.hour, min = t.min, sec = t.sec })
end

local function archiveRuns(nowTs)
    local months = math.floor(tonumber(Config.Retention and Config.Retention.runArchiveMonths) or 0)
    if months <= 0 then return 0 end
    local cutoff = monthsBefore(nowTs, months)
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS n, MAX(id) AS max_id FROM cp_mission_runs WHERE created_at < FROM_UNIXTIME(?)',
        { cutoff })
    local n = CP.U.num(row and row.n)
    local maxId = CP.U.num(row and row.max_id)
    if n <= 0 or maxId <= 0 then return 0 end
    -- INSERT IGNORE keeps a re-run idempotent if an earlier run copied rows but failed to delete them.
    MySQL.update.await(
        'INSERT IGNORE INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE id <= ? AND created_at < FROM_UNIXTIME(?)',
        { maxId, cutoff })
    -- Only rows that are safely in the archive are removed.
    local deleted = MySQL.update.await(
        'DELETE r FROM cp_mission_runs r INNER JOIN cp_mission_runs_archive a ON a.id = r.id WHERE r.id <= ? AND r.created_at < FROM_UNIXTIME(?)',
        { maxId, cutoff })
    return CP.U.num(deleted)
end

local function purgeAudit(nowTs)
    local days = math.floor(tonumber(Config.Retention and Config.Retention.auditDays) or 0)
    if days <= 0 then return 0 end
    local cutoff = nowTs - days * 86400
    return CP.U.num(MySQL.update.await('DELETE FROM cp_audit WHERE created_at < FROM_UNIXTIME(?)', { cutoff }))
end

local function runRetention(nowTs)
    if retentionBusy then
        CP.log(TAG, 'retention already running; skipped')
        return { archived = 0, auditDeleted = 0, skipped = true }
    end
    retentionBusy = true
    nowTs = nowTs or os.time()
    local result = { archived = 0, auditDeleted = 0 }
    local ok, err = pcall(function()
        CP.Migrations.ready()
        result.archived = archiveRuns(nowTs)
        result.auditDeleted = purgeAudit(nowTs)
    end)
    retentionBusy = false
    if not ok then
        CP.err(TAG, 'retention job failed: %s', tostring(err))
        result.error = tostring(err)
        return result
    end
    if result.archived > 0 or result.auditDeleted > 0 then
        print(('[crimson-police] retention: %d run rows archived, %d audit rows deleted'):format(result.archived, result.auditDeleted))
    end
    CP.log(TAG, 'retention done: archived=%d audit=%d', result.archived, result.auditDeleted)
    return result
end

Schedule._runRetention = runRetention

-- ── boundary check ──────────────────────────────────────────────────────────
local function snapshot(ts)
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
    local cur = snapshot(ts)
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
        fire('daily', cur.day)
        -- The retention job runs in its own thread so a slow archive never delays the reset listeners
        -- (Type of the Day, goals, streaks, the daily cash cap) or the next boundary check.
        CreateThread(function() runRetention(ts) end)
    end
    if cur.week ~= prev.week then
        fired.weekly = true
        CP.log(TAG, 'weekly reset: %s -> %s', prev.week, cur.week)
        fire('weekly', cur.week, prev.weekStart)
    end
    if cur.month ~= prev.month then
        fired.monthly = true
        CP.log(TAG, 'monthly reset: %s', os.date('%Y-%m-%d', cur.month))
        fire('monthly', cur.month)
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
    runRetention()
end)
