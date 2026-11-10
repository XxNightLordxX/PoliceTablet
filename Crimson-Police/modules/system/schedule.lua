-- CP.Schedule: server-time calendar, reset boundaries and the timed jobs (Admin UI -> System -> Jobs).

-- Owns
--   * the reset-adjusted calendar: every "day" starts at Config.Time.resetHour (server local time),
--     every week at that hour on Config.Leaderboard.weekStartsOn, every month at that hour on the 1st
--   * the timed jobs: every module registers each of its timed jobs here (Schedule.job), with what it does, when it
--     runs, the settings that steer it and whether an admin may run it now. The boundary check (every 60 s) runs the
--     daily, weekly and monthly jobs once when a boundary passes, never just because the resource started. A job that
--     runs every few minutes keeps its own loop and runs through the runner Schedule.job returns. Each job's last
--     result (when, by whom, what it did, how long, an error or why it was skipped) is kept for the Jobs screen.
--   * the clean-up job (Config.Retention), run at each daily reset (plus one catch-up run shortly after start, see
--     docs/dev/ARCHITECTURE.md §5.6): cp_mission_runs rows older than runArchiveMonths are copied into
--     cp_mission_runs_archive and then deleted, cp_audit rows older than auditDays are deleted
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
--   CP.Schedule.job(id, def) -> runner | false       registers a timed job; def:
--       when = 'daily' | 'weekly' | 'monthly' | 'every'
--       every = seconds ('every' jobs: the module's own loop calls the runner this often)
--       run = fn(ctx) -> result                      ctx = { at, by, manual, day, week, prevWeekStart, monthStart };
--                                                    result: a number (rows, toasts), a table of counts or nil
--       on = fn() -> bool                            optional: false = switched off in its settings (skipped)
--       settings = { 'Retention.auditDays', ... }    the settings that steer it (shown on the Jobs screen)
--       manual = true                                an admin may run it now from the Jobs screen
--       order = n                                    daily jobs run in this order on one thread (default 50)
--     The runner (fn(ctx?) -> the run's result) runs the job now with its bookkeeping.
--   CP.Schedule.run(id, ctx?) -> result              the same, by id (nil for an unknown id)
--   CP.Schedule.jobsView() -> view                   Admin UI -> System -> Jobs (JobsView in web/src/types/admin_system.ts)
--
-- Test hooks (internal): CP.Schedule._check(ts?) runs one boundary check (the 60 s loop calls it);
-- CP.Schedule._runRetention(ts?, by?) -> { archived = n, auditDeleted = n, ... } runs the clean-up job now.
--
-- Contract interpretations: the clean-up job also runs once 120 s after start (idempotent catch-up); the daily jobs
-- run one after another in their own thread (the daily backup first, the clean-up last), so a slow backup or archive
-- never delays the boundary check or the weekly and monthly jobs, and the backup never races the clean-up for the busy
-- lock; a reset that comes while that thread still runs starts no second one; a clock that moves back to an earlier
-- day fires nothing. A job that is still running is never started twice (the second start is skipped).

CP.Schedule = CP.Schedule or {}
local Schedule = CP.Schedule

local TAG = 'schedule'
local CHECK_EVERY_MS = 60000
local RETENTION_CATCHUP_DELAY_MS = 120000
local SETTINGS_WAIT_MS = 15000               -- the first check waits this long at most for the settings changed in game
local IDLE_WAIT_MS = 60000                   -- the clean-up waits this long at most for an admin's bulk job to end
local REQUEST_KEEP_DAYS = 7                  -- cp_admin_requests (one admin request acts once) are kept this long
local DEFAULT_ORDER = 50

local WEEKDAYS = { 'sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday' }  -- os.date wday order
local WHEN = { daily = true, weekly = true, monthly = true, every = true }

local jobs = {}           -- id -> { id, def, seq, running, last }
local jobList = {}        -- in registration order
local dailyBusy = false   -- the daily jobs' thread of the last reset still runs
local last = nil          -- { day, week, weekStart, month } seen by the previous check

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
--                                   THE JOBS
-- ============================================================================

local function Skipped(res)
    if type(res) ~= 'table' or not res.skipped then return nil end
    return res.skipped == true and 'busy' or tostring(res.skipped)
end

-- One run of a job with its bookkeeping: never two at once, an error is contained and logged, the result is kept.
local function RunJob(job, ctx)
    ctx = type(ctx) == 'table' and ctx or {}
    ctx.at = ctx.at or os.time()
    if job.running then
        CP.log(TAG, 'job %s is still running; skipped', job.id)
        return { skipped = 'running' }
    end
    if job.def.on then
        local okOn, on = pcall(job.def.on)
        if okOn and on == false then
            job.last = { at = ctx.at, by = ctx.by, skipped = 'off', durationMs = 0 }
            return { skipped = 'off' }
        end
    end
    job.running = true
    local started = GetGameTimer()
    local ok, res = pcall(job.def.run, ctx)
    job.running = false
    local entry = { at = ctx.at, by = ctx.by, durationMs = math.max(0, GetGameTimer() - started) }
    if not ok then
        entry.error = tostring(res)
        CP.err(TAG, 'job %s failed: %s', job.id, entry.error)
        res = { error = entry.error }
    elseif type(res) == 'table' then
        entry.skipped = Skipped(res)
        entry.error = res.error and tostring(res.error) or nil
        local counts = {}
        for k, v in pairs(res) do
            if type(v) == 'number' then counts[k] = v end
        end
        entry.result = counts
    elseif type(res) == 'number' then
        entry.result = { n = res }
    end
    job.last = entry
    return res
end

function Schedule.job(id, def)
    if type(id) ~= 'string' or id == '' or type(def) ~= 'table' or type(def.run) ~= 'function'
        or not WHEN[def.when] then
        CP.warn(TAG, 'job %s needs an id, a run function and when = daily, weekly, monthly or every', tostring(id))
        return false
    end
    local job = jobs[id]
    if job then
        job.def = def   -- the module file ran again: the newest definition, the same place in the list
    else
        job = { id = id, def = def, seq = #jobList + 1 }
        jobs[id] = job
        jobList[#jobList + 1] = job
    end
    return function(ctx) return RunJob(job, ctx) end
end

function Schedule.run(id, ctx)
    local job = jobs[id]
    if not job then return nil end
    return RunJob(job, ctx)
end

-- The jobs of one boundary, in their order.
local function JobsOf(when)
    local out = {}
    for _, job in ipairs(jobList) do
        if job.def.when == when then out[#out + 1] = job end
    end
    table.sort(out, function(a, b)
        local oa, ob = tonumber(a.def.order) or DEFAULT_ORDER, tonumber(b.def.order) or DEFAULT_ORDER
        if oa ~= ob then return oa < ob end
        return a.seq < b.seq
    end)
    return out
end

-- ============================================================================
--                               THE CLEAN-UP JOB
-- ============================================================================
-- months months before ts, same wall-clock time (os.time normalises month underflow).
local function MonthsBefore(ts, months)
    local t = os.date('*t', ts)
    return os.time({ year = t.year, month = t.month - months, day = t.day, hour = t.hour, min = t.min, sec = t.sec })
end

-- Rows that may move to the archive: never one whose money or item rewards are unfinished (held, pending or paying
-- cash, a completed run row still 'none' with cash the login payment owes; held, pending or giving rewards), so owed money never vanishes from the Payments screen and the login payment.
local ARCHIVE_OK = [[r.cash_status NOT IN ('held', 'pending', 'paying')
    AND NOT (r.cash_status = 'none' AND r.state = 'completed' AND r.cash_base > 0 AND r.voided = 0
        AND r.mission_type NOT IN ('manual_award', 'goal'))
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

local function RunRetention(nowTs)
    -- the lock is read after the wait for the store (a lock the start takes holds before this goes on); a start
    -- that failed cleans nothing up
    if CP.Migrations and CP.Migrations.started and not CP.Migrations.started() then
        return { archived = 0, auditDeleted = 0, skipped = 'not_started' }
    end
    local held = JobsHeld()
    if held then
        CP.log(TAG, 'retention waits: maintenance lock (%s)', tostring(held))
        return { archived = 0, auditDeleted = 0, skipped = 'maintenance' }
    end
    nowTs = nowTs or os.time()
    local result = { archived = 0, kept = 0, auditDeleted = 0, requestsDeleted = 0, historyDeleted = 0 }
    local Kit = CP.AdminKit
    local ok, err
    if Kit and Kit.waitIdle and Kit.lock and Kit.unlock then
        if not Kit.waitIdle(IDLE_WAIT_MS) or not Kit.lock('cleanup') then
            CP.warn(TAG, 'retention skipped: an admin bulk job held the busy lock for too long')
            result.skipped = 'busy'
            return result
        end
        ok, err = pcall(RetentionWork, nowTs, result)
        Kit.unlock('cleanup')
    else
        ok, err = pcall(RetentionWork, nowTs, result)
    end
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

-- The next run of a job (nil for an 'every' job that has not run yet).
local function NextRunAt(job, now)
    local when = job.def.when
    if when == 'daily' then return Schedule.dayStart(Schedule.dayStart(now) + 25 * 3600) end
    if when == 'weekly' then return Schedule.weekStart(Schedule.weekStart(now) + 7 * 86400 + 12 * 3600) end
    if when == 'monthly' then return Schedule.monthStart(Schedule.monthStart(now) + 32 * 86400) end
    local every = tonumber(job.def.every) or 0
    if job.last and every > 0 then return job.last.at + every end
    return nil
end

-- The value of a Config path ('Retention.auditDays', 'RealPlayers.volunteer.strikeHours').
local function ConfigValue(path)
    local v = Config
    for part in tostring(path):gmatch('[^%.]+') do
        if type(v) ~= 'table' then return nil end
        v = v[part]
    end
    if type(v) == 'table' then return nil end
    return v
end

local function RunNowMinutes()
    return math.floor(CP.Num(Config.Jobs and Config.Jobs.runNowMinutes, 10, 1, 1440))
end

-- Admin UI -> System -> Jobs.
function Schedule.jobsView()
    local now = os.time()
    local list = {}
    for _, job in ipairs(jobList) do
        local def = job.def
        local on = true
        if def.on then
            local ok, v = pcall(def.on)
            on = not (ok and v == false)
        end
        local settings = {}
        for _, path in ipairs(type(def.settings) == 'table' and def.settings or {}) do
            settings[#settings + 1] = { path = path, value = ConfigValue(path) }
        end
        list[#list + 1] = {
            id = job.id,
            when = def.when,
            every = def.when == 'every' and math.floor(tonumber(def.every) or 0) or nil,
            on = on,
            manual = def.manual == true,
            running = job.running == true,
            nextRunAt = NextRunAt(job, now),
            last = job.last,
            settings = settings,
        }
    end
    return {
        jobs = list,
        resetHour = ResetHour(),
        weekStartsOn = WEEKDAYS[WeekStartIndex()],
        runNowMinutes = RunNowMinutes(),
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

local function RunAll(when, ctx)
    for _, job in ipairs(JobsOf(when)) do
        local c = {}
        for k, v in pairs(ctx) do c[k] = v end
        RunJob(job, c)
    end
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
        -- The daily jobs run in their own thread, one after another, so a slow backup or archive never delays the
        -- weekly and monthly jobs or the next boundary check.
        if dailyBusy then
            CP.warn(TAG, 'the daily jobs of the previous reset are still running; skipped for %s', cur.day)
        else
            dailyBusy = true
            local day = cur.day
            CreateThread(function()
                local ok, err = pcall(RunAll, 'daily', { at = ts, day = day })
                if not ok then CP.err(TAG, 'the daily jobs failed: %s', tostring(err)) end
                dailyBusy = false
            end)
        end
    end
    if cur.week ~= prev.week then
        fired.weekly = true
        CP.log(TAG, 'weekly reset: %s -> %s', prev.week, cur.week)
        RunAll('weekly', { at = ts, week = cur.week, prevWeekStart = prev.weekStart })
    end
    if cur.month ~= prev.month then
        fired.monthly = true
        CP.log(TAG, 'monthly reset: %s', os.date('%Y-%m-%d', cur.month))
        RunAll('monthly', { at = ts, monthStart = cur.month })
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

-- ============================================================================
--                          ADMIN UI -> SYSTEM -> JOBS
-- ============================================================================
-- The list, and Run now: the job's own code with the same skip rules as its scheduled run. Admins only (the jobs
-- permission), reason required, each job once per Config.Jobs.runNowMinutes whichever admin asks, refused while an
-- admin's long job runs or a maintenance lock is held, audited (jobRun).

local REFUSED = {
    busy = 'err.admin_busy',
    running = 'err.job_running',
    off = 'err.job_off',
    maintenance = 'err.maintenance',
    not_started = 'err.not_started',
}

if CP.AdminKit and CP.AdminKit.action then
    local Kit = CP.AdminKit
    Kit.callback('admin:getJobs', 'jobs', function() return Schedule.jobsView() end, { rate = 2 })
    Kit.action('server:admin:runJobNow', 'jobs', function(ctx)
        local id = type(ctx.payload) == 'table' and ctx.payload.id or nil
        local job = type(id) == 'string' and jobs[id] or nil
        if not job then return false, 'err.job_unknown' end
        if job.def.manual ~= true then return false, 'err.job_not_manual' end
        if job.running then return false, 'err.job_running' end
        if Kit.busy() then return false, 'err.admin_busy' end
        if JobsHeld() then return false, 'err.maintenance' end
        if not Kit.targetOk('server:admin:runJobNow', id, 1, RunNowMinutes() * 60000) then
            return false, 'err.rate_limited'
        end
        local res = RunJob(job, { by = ctx.actor, manual = true })
        local entry = job.last or {}
        local counts = {}
        for k, v in pairs(entry.result or {}) do counts[#counts + 1] = ('%s %s'):format(k, tostring(v)) end
        table.sort(counts)
        ctx.audit('jobRun', id, nil, #counts > 0 and table.concat(counts, ', ') or entry.skipped or entry.error)
        local skipped = Skipped(res)
        if skipped then return false, REFUSED[skipped] or 'err.job_running' end
        if entry.error then return false, 'err.timed_job_failed' end
        return true, Schedule.jobsView()
    end, { reason = true, rate = 1 })
end

Schedule._runRetention = function(ts, by) return Schedule.run('cleanup', { at = ts, by = by }) end

-- The clean-up job: the last daily job, so the daily backup has copied the rows first.
Schedule.job('cleanup', {
    when = 'daily',
    order = 90,
    manual = true,
    settings = { 'Retention.runArchiveMonths', 'Retention.auditDays' },
    run = function(ctx) return RunRetention(ctx.at) end,
})

-- Catch-up clean-up once after start, so a server that always restarts across the reset hour
-- still archives. Idempotent: it only moves rows that are already past the cutoff.
CreateThread(function()
    Wait(RETENTION_CATCHUP_DELAY_MS)
    Schedule.run('cleanup')
end)
