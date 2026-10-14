-- CP.Schedule: server-time calendar, reset boundaries and the retention job.

CP.Schedule = CP.Schedule or {}
local Schedule = CP.Schedule

local TAG = 'schedule'
local CHECK_EVERY_MS = 30000
local RETENTION_CATCHUP_DELAY_MS = 120000
local SETTINGS_WAIT_MS = 15000               -- the first check waits this long at most for the settings changed in game
local IDLE_WAIT_MS = 60000                   -- the clean-up waits this long at most for an admin's bulk job to end
local REQUEST_KEEP_DAYS = 7                  -- cp_admin_requests (one admin request acts once) are kept this long
local CLEANUP_NOW_EVERY_MS = 10 * 60 * 1000  -- Run clean-up now: once per 10 minutes, whichever admin asks

local WEEKDAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }  -- os.date wday order

local listeners = { daily = {}, weekly = {}, monthly = {} }
local last = nil          -- { day, week, weekStart, month } seen by the previous check
local retentionBusy = false
local lastCleanup = nil   -- the last clean-up's result (Admin UI -> System -> Clean-up)

-- The maintenance lock (a storage copy or switch, a backup restore, a store left behind) holds every job back.
local function JobsHeld()
    if not (CP.Maintenance and CP.Maintenance.active) then return nil end
    local ok, kind = pcall(CP.Maintenance.active)
    return ok and kind or nil
end

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

-- Rows that may move to the archive: never one whose money or item rewards are unfinished (held, pending or paying
-- cash; held, pending or giving rewards), so owed money never vanishes from the Payments screen and the login payment.
local ARCHIVE_OK = [[r.cash_status NOT IN ('held', 'pending', 'paying')
    AND NOT EXISTS (SELECT 1 FROM cp_item_rewards i WHERE i.row_id = r.id AND i.status IN ('held', 'pending', 'giving'))]]

-- archived, kept (old rows left in place because they are unfinished)
local function ArchiveRuns(nowTs)
    local months = math.floor(tonumber(Config.Retention and Config.Retention.runArchiveMonths) or 0)
    if months <= 0 then return 0, 0 end
    local cutoff = MonthsBefore(nowTs, months)
    local all = CP.U.num(MySQL.scalar.await(
        'SELECT COUNT(*) AS n FROM cp_mission_runs r WHERE r.created_at < FROM_UNIXTIME(?)', { cutoff }))
    local row = MySQL.single.await(
        'SELECT COUNT(*) AS n, MAX(r.id) AS max_id FROM cp_mission_runs r WHERE r.created_at < FROM_UNIXTIME(?) AND '
            .. ARCHIVE_OK,
        { cutoff }
    )
    local n = CP.U.num(row and row.n)
    local maxId = CP.U.num(row and row.max_id)
    local kept = math.max(0, all - n)
    if n <= 0 or maxId <= 0 then return 0, kept end
    -- INSERT IGNORE keeps a re-run idempotent if an earlier run copied rows but failed to delete them.
    local copied = CP.U.num(MySQL.update.await(
        'INSERT IGNORE INTO cp_mission_runs_archive SELECT r.* FROM cp_mission_runs r WHERE r.id <= ? AND r.created_at < FROM_UNIXTIME(?) AND '
            .. ARCHIVE_OK,
        { maxId, cutoff }
    ))
    -- Only rows whose own copy is in the archive are removed: the archive row must match on id AND
    -- run_uuid, citizenid and created_at (and the cash state, so a row an admin changed in between stays). A live
    -- row whose id collides with a different archived row (an AUTO_INCREMENT counter reset after a restore) was
    -- skipped by INSERT IGNORE and stays in place.
    local deleted = CP.U.num(MySQL.update.await(
        'DELETE r FROM cp_mission_runs r INNER JOIN cp_mission_runs_archive a ON a.id = r.id AND a.run_uuid = r.run_uuid AND a.citizenid = r.citizenid AND a.created_at = r.created_at AND a.cash_status = r.cash_status AND a.cash_paid = r.cash_paid WHERE r.id <= ? AND r.created_at < FROM_UNIXTIME(?) AND '
            .. ARCHIVE_OK,
        { maxId, cutoff }
    ))
    if deleted < n then
        CP.warn(TAG,
            'retention: %d of %d old run rows could not be archived (copied %d; an id already in cp_mission_runs_archive holds a different row); they stay in cp_mission_runs',
            n - deleted, n, copied)
    end
    return deleted, kept
end

local function PurgeAudit(nowTs)
    local days = math.floor(tonumber(Config.Retention and Config.Retention.auditDays) or 0)
    if days <= 0 then return 0 end
    local cutoff = nowTs - days * 86400
    return CP.U.num(MySQL.update.await('DELETE FROM cp_audit WHERE created_at < FROM_UNIXTIME(?)', { cutoff }))
end

-- One admin request acts once (cp_admin_requests): kept a week, then purged.
local function PurgeRequests(nowTs)
    return CP.U.num(MySQL.update.await('DELETE FROM cp_admin_requests WHERE created_at < FROM_UNIXTIME(?)',
        { nowTs - REQUEST_KEEP_DAYS * 86400 }))
end

-- The settings history follows the audit retention.
local function PurgeSettingsHistory(nowTs)
    local days = math.floor(tonumber(Config.Retention and Config.Retention.auditDays) or 0)
    if days <= 0 then return 0 end
    return CP.U.num(MySQL.update.await('DELETE FROM cp_settings_history WHERE created_at < FROM_UNIXTIME(?)',
        { nowTs - days * 86400 }))
end

-- The work of one clean-up, under the shared busy lock (a bulk void in flight is never archived half done).
local function RetentionWork(nowTs, result)
    CP.Migrations.ready()
    result.archived, result.kept = ArchiveRuns(nowTs)
    result.auditDeleted = PurgeAudit(nowTs)
    result.requestsDeleted = PurgeRequests(nowTs)
    result.historyDeleted = PurgeSettingsHistory(nowTs)
end

local function RunRetention(nowTs, by)
    if retentionBusy then
        CP.log(TAG, 'retention already running; skipped')
        return { archived = 0, auditDeleted = 0, skipped = true }
    end
    local held = JobsHeld()
    if held then
        CP.log(TAG, 'retention waits: maintenance lock (%s)', tostring(held))
        return { archived = 0, auditDeleted = 0, skipped = 'maintenance' }
    end
    retentionBusy = true
    nowTs = nowTs or os.time()
    local started = GetGameTimer()
    local result = { archived = 0, kept = 0, auditDeleted = 0, requestsDeleted = 0, historyDeleted = 0 }
    local Kit = CP.AdminKit
    local ok, err
    if Kit and Kit.waitIdle and Kit.lock and Kit.unlock then
        if not Kit.waitIdle(IDLE_WAIT_MS) or not Kit.lock('cleanup') then
            retentionBusy = false
            CP.warn(TAG, 'retention skipped: an admin bulk job held the busy lock for too long')
            result.skipped = 'busy'
            lastCleanup = { at = nowTs, by = by, skipped = 'busy', durationMs = 0 }
            return result
        end
        ok, err = pcall(RetentionWork, nowTs, result)
        Kit.unlock('cleanup')
    else
        ok, err = pcall(RetentionWork, nowTs, result)
    end
    retentionBusy = false
    lastCleanup = {
        at = nowTs,
        by = by,
        archived = result.archived,
        kept = result.kept,
        auditDeleted = result.auditDeleted,
        requestsDeleted = result.requestsDeleted,
        historyDeleted = result.historyDeleted,
        durationMs = math.max(0, GetGameTimer() - started),
        error = not ok and tostring(err) or nil,
    }
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

-- The next nightly clean-up: the next daily reset.
local function NextResetAt(ts)
    local start = Schedule.dayStart(ts)
    return Schedule.dayStart(start + 25 * 3600)
end

-- Admin UI -> System -> Clean-up (CleanupView in web/src/types/admin_economy.ts).
function Schedule.cleanupView()
    local r = Config.Retention or {}
    return {
        last = lastCleanup,
        running = retentionBusy,
        nextRunAt = NextResetAt(os.time()),
        runArchiveMonths = math.floor(tonumber(r.runArchiveMonths) or 0),
        auditDays = math.floor(tonumber(r.auditDays) or 0),
        requestDays = REQUEST_KEEP_DAYS,
    }
end

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
    -- the reset hour and the first day of the week may be changed in game: record the period with those values
    if CP.Settings and CP.Settings.waitLoaded then CP.Settings.waitLoaded(SETTINGS_WAIT_MS) end
    Schedule._check()   -- records the current period only
    while true do
        Wait(CHECK_EVERY_MS)
        -- every scheduled job waits while a maintenance lock is held
        if not JobsHeld() then
            local ok, err = pcall(Schedule._check)
            if not ok then CP.err(TAG, 'boundary check failed: %s', tostring(err)) end
        end
    end
end)

-- Admin UI -> System -> Clean-up: the last result, and Run clean-up now (the same code as the nightly job, with
-- the same skip rules). Admins only, reason required, once per 10 minutes, refused while a long job runs.
if CP.AdminKit and CP.AdminKit.action then
    local Kit = CP.AdminKit
    Kit.callback('admin:getCleanup', 'cleanup', function() return Schedule.cleanupView() end, { rate = 2 })
    Kit.action('server:admin:runCleanupNow', 'cleanup', function(ctx)
        if retentionBusy then return false, 'err.cleanup_running' end
        if Kit.busy() then return false, 'err.admin_busy' end
        if not Kit.targetOk('server:admin:runCleanupNow', 'all', 1, CLEANUP_NOW_EVERY_MS) then
            return false, 'err.rate_limited'
        end
        local res = RunRetention(os.time(), ctx.actor)
        if res.skipped then return false, res.skipped == 'busy' and 'err.admin_busy' or 'err.cleanup_running' end
        ctx.audit('cleanupRun', nil, nil, ('%d archived, %d audit'):format(res.archived or 0, res.auditDeleted or 0))
        if res.error then return false, 'err.cleanup_failed' end
        return true, Schedule.cleanupView()
    end, { reason = true, rate = 1 })
end

-- Catch-up retention once after start, so a server that always restarts across the reset hour
-- still archives. Idempotent: it only moves rows that are already past the cutoff.
CreateThread(function()
    Wait(RETENTION_CATCHUP_DELAY_MS)
    RunRetention()
end)
