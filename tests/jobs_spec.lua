-- One jobs engine (modules/system/schedule.lua): every timed job of the resource registers through
-- CP.Schedule.job, the daily, weekly and monthly ones run at their boundary in their order, a job on its own timer
-- runs through its runner, each keeps its last result, and Admin UI -> System -> Jobs lists them with Run now.

-- One jobs engine (modules/system/schedule.lua): every timed job of the resource registers through
-- CP.Schedule.job, the daily, weekly and monthly ones run at their boundary in their order, a job on its own timer
-- runs through its runner, each keeps its last result, and Admin UI -> System -> Jobs lists them with Run now.
-- Plain Lua: CP.AdminKit and CP.Maintenance are stubs, the jobs are the spec's own (tests/e2e_spec.lua runs the real
-- resource's jobs through the same engine).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local function Read(rel)
    local fh = io.open(H.root .. rel, 'r')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local callbacks, actions, audits, rate = {}, {}, {}, {}
local busyKind, held = nil, nil
CP.AdminKit = {
    callback = function(name, perm, fn) callbacks[name] = { perm = perm, fn = fn } end,
    action = function(name, perm, fn, opts) actions[name] = { perm = perm, fn = fn, opts = opts } end,
    busy = function() return busyKind end,
    waitIdle = function() return busyKind == nil end,
    lock = function() return busyKind == nil end,
    unlock = function() end,
    targetOk = function(name, target, n, windowMs)
        local key = name .. ':' .. tostring(target)
        rate.windowMs = windowMs
        if rate[key] then return false end
        rate[key] = true
        return true
    end,
}
CP.Maintenance = {
    active = function() return held end,
}

H.load('modules/system/schedule.lua')
local S = CP.Schedule

local function RunNow(id, actor)
    local ctx = {
        payload = { id = id, reason = 'test' },
        actor = actor or 'ADM00001',
        audit = function(action, target, _, detail) audits[#audits + 1] = { action, target, detail } end,
    }
    return actions['server:admin:runJobNow'].fn(ctx)
end

local function JobOf(view, id)
    for _, j in ipairs(view.jobs) do if j.id == id then return j end end
    return nil
end

-- ============================================================================
--                   1. THE SYSTEM MODULE AND THE ONE WAY IN
-- ============================================================================

do
    for _, f in ipairs({ 'memsql', 'storage', 'migrations', 'schedule' }) do
        H.ok(Read('modules/system/' .. f .. '.lua') ~= nil, 'modules/system/' .. f .. '.lua')
    end
    for _, old in ipairs({
        'modules/storage/server.lua',
        'modules/migrations/server.lua',
        'modules/schedule/server.lua',
    }) do
        H.eq(Read(old), nil, 'gone: ' .. old)
    end
    local manifest = Read('fxmanifest.lua')
    local storageAt = manifest:find('\'modules/system/storage.lua\'', 1, true)
    local kitAt = manifest:find('\'modules/admin/adminkit.lua\'', 1, true)
    local schedAt = manifest:find('\'modules/system/schedule.lua\'', 1, true)
    local globAt = manifest:find('\'modules/access/access.lua\'', 1, true)
    H.ok(storageAt and kitAt and schedAt and globAt and storageAt < kitAt and kitAt < schedAt and schedAt < globAt,
        'fxmanifest: storage first, then CP.AdminKit, then the jobs engine before every module')
    -- the old ways in are gone everywhere: every timed job registers with CP.Schedule.job
    local p = io.popen(
        'cd ' .. H.root .. ' && grep -rlE "onDailyJob|Schedule\\.on(Daily|Weekly|Monthly)|cleanupView'
            .. '|admin:getCleanup|runCleanupNow" modules web/src 2>/dev/null'
    )
    local hits = p:read('a')
    p:close()
    H.eq(hits, '', 'no module or screen uses the old listeners or the Clean-up tab')
    local REGISTERED = {
        { 'modules/admin/sysadmin.lua', 'backup' },
        { 'modules/system/schedule.lua', 'cleanup' },
        { 'modules/dispatch/missioncalls.lua', 'mission_calls' },
        { 'modules/realplayers/pairs.lua', 'pvp_pairs' },
        { 'modules/realplayers/saved.lua', 'pvp_cases' },
        { 'modules/realplayers/volunteers.lua', 'volunteer_strikes' },
        { 'modules/money/payments.lua', 'low_balance' },
        { 'modules/progression/challenge.lua', 'season_end' },
        { 'modules/progression/challenge.lua', 'bounty_week' },
        { 'modules/progression/leaderboard.lua', 'board_week' },
        { 'modules/progression/leaderboard.lua', 'board_month' },
        { 'modules/money/cash.lua', 'cash_forfeiture' },
        { 'modules/money/rewards.lua', 'reward_forfeiture' },
    }
    local part = require('cjson').decode(Read('locales/parts/admin_system.json'))
    for _, r in ipairs(REGISTERED) do
        local src = Read(r[1]) or ''
        H.ok(src:find('Schedule.job(\'' .. r[2] .. '\'', 1, true) ~= nil, r[1] .. ' registers the job ' .. r[2])
        H.ok(part['sysadmin.jobs.name.' .. r[2]] and part['sysadmin.jobs.desc.' .. r[2]],
            'the Jobs screen names and explains ' .. r[2])
    end
    H.eq(Config.Jobs.runNowMinutes, 10, 'Config.Jobs.runNowMinutes ships 10 (Run now once per 10 minutes, as before)')
    H.ok(callbacks['admin:getJobs'] and callbacks['admin:getJobs'].perm == 'jobs', 'admin:getJobs needs jobs')
    local act = actions['server:admin:runJobNow']
    H.ok(act and act.perm == 'jobs' and act.opts.reason == true, 'server:admin:runJobNow needs jobs and a reason')
end

-- ============================================================================
--                    2. THE BOUNDARIES RUN EACH KIND OF JOB
-- ============================================================================

local T0 = os.time({ year = 2026, month = 9, day = 27, hour = 12 })   -- a Sunday
local order, seen = {}, {}
do
    Config.Time.resetHour = 0
    Config.Leaderboard.weekStartsOn = 'monday'
    H.eq(S.job('bad', { when = 'hourly', run = function() end }), false, 'an unknown when is refused')
    H.eq(S.job('bad', { when = 'daily' }), false, 'a job needs a run function')
    -- the clean-up's own code is covered by engine_a_spec and admin_economy_spec: here it only records its turn
    S.job('cleanup', {
        when = 'daily',
        order = 90,
        manual = true,
        run = function() order[#order + 1] = 'cleanup' end,
    })
    S._check(T0)   -- the spec's clock: the period the load recorded may be an earlier one
    order = {}
    S.job('late', {
        when = 'daily',
        order = 60,
        run = function() order[#order + 1] = 'late' end,
    })
    S.job('first', {
        when = 'daily',
        order = 10,
        run = function(ctx)
            order[#order + 1] = 'first'
            seen.day = ctx.day
        end,
    })
    S.job('broken', {
        when = 'daily',
        run = function() error('boom') end,
    })
    S.job('off', {
        when = 'daily',
        manual = true,
        on = function() return false end,
        run = function() order[#order + 1] = 'off' end,
    })
    S.job('week', {
        when = 'weekly',
        settings = { 'Leaderboard.weekStartsOn' },
        run = function(ctx)
            seen.week, seen.prev = ctx.week, ctx.prevWeekStart
        end,
    })
    S.job('month', {
        when = 'monthly',
        run = function(ctx) seen.month = ctx.monthStart end,
    })

    S._check(T0 + 60)
    H.eq(#order, 0, 'nothing runs within the same day')
    local mon = os.time({ year = 2026, month = 9, day = 28, hour = 0, min = 0, sec = 30 })
    local fired = S._check(mon)
    H.ok(fired.daily and fired.weekly and not fired.monthly, 'a day and a week went by')
    H.eq(table.concat(order, ','), 'first,late,cleanup', 'the daily jobs run in their order, the clean-up last')
    H.eq(seen.day, '2026-09-28', 'a daily job gets the new day')
    H.eq(seen.week, '2026-09-28', 'a weekly job gets the new week')
    H.eq(seen.prev, os.time({ year = 2026, month = 9, day = 21, hour = 0 }), 'and the start of the week before')
    local oct = os.time({ year = 2026, month = 10, day = 1, hour = 0, min = 0, sec = 30 })
    S._check(oct)
    H.eq(seen.month, os.time({ year = 2026, month = 10, day = 1, hour = 0 }), 'a monthly job gets the month start')

    local v = S.jobsView()
    local broken = JobOf(v, 'broken')
    H.ok(broken.last and broken.last.error and broken.last.error:find('boom', 1, true),
        'a job that fails keeps its error, and the next ones still ran')
    local off = JobOf(v, 'off')
    H.ok(not off.on and off.last.skipped == 'off', 'a job switched off in its settings is skipped and says so')
    local now = os.time()
    H.eq(JobOf(v, 'first').nextRunAt, S.dayStart(S.dayStart(now) + 25 * 3600), 'daily: the next daily reset')
    H.eq(JobOf(v, 'week').nextRunAt, S.weekStart(S.weekStart(now) + 8 * 86400), 'weekly: the next week start')
    H.eq(JobOf(v, 'month').nextRunAt, S.monthStart(S.monthStart(now) + 32 * 86400), 'monthly: the next 1st')
    H.eq(JobOf(v, 'week').settings[1].path, 'Leaderboard.weekStartsOn', 'a job lists its settings')
    H.eq(JobOf(v, 'week').settings[1].value, 'monday', 'with their values now')
    H.eq(v.resetHour, 0, 'the view says when the day starts')
    H.eq(v.weekStartsOn, 'monday', 'and the week')
end

-- ============================================================================
--              3. A JOB ON ITS OWN TIMER AND A JOB STILL RUNNING
-- ============================================================================

do
    local calls = 0
    local runner = S.job('every', {
        when = 'every',
        every = 600,
        manual = true,
        run = function()
            calls = calls + 1
            return 3
        end,
    })
    H.eq(type(runner), 'function', 'Schedule.job gives the module its runner')
    H.eq(runner(), 3, 'the runner gives back the job\'s own result')
    local j = JobOf(S.jobsView(), 'every')
    H.ok(j.last and j.last.result.n == 3 and j.last.by == nil, 'its last result is kept (on its timer)')
    H.eq(j.nextRunAt, j.last.at + 600, 'and its next run is the last one plus its interval')

    local slow = S.job('slow', {
        when = 'daily',
        manual = true,
        run = function() Wait(5000) end,
    })
    local first
    CreateThread(function() first = slow() end)
    H.eq(S.run('slow').skipped, 'running', 'a job still running is not started twice')
    local ok, e = RunNow('slow')
    H.ok(not ok and e == 'err.job_running', 'Run now says it is still running')
    H.advance(6000)
    H.eq(first, nil, 'the first run finished')
end

-- ============================================================================
--                         4. RUN NOW (SYSTEM -> JOBS)
-- ============================================================================

do
    local ok, e = RunNow('nope')
    H.ok(not ok and e == 'err.job_unknown', 'an unknown job')
    ok, e = RunNow('week')
    H.ok(not ok and e == 'err.job_not_manual', 'a weekly reset only runs at its own time')
    ok, e = RunNow('off')
    H.ok(not ok and e == 'err.job_off', 'a job switched off in its settings')
    busyKind = 'bulkVoid'
    ok, e = RunNow('every')
    H.ok(not ok and e == 'err.admin_busy', 'refused while an admin\'s long job runs')
    busyKind, held = nil, 'storage'
    ok, e = RunNow('every')
    H.ok(not ok and e == 'err.maintenance', 'refused while a maintenance lock is held')
    held = nil
    Config.Jobs.runNowMinutes = 25
    local view
    ok, view = RunNow('every', 'ADM00009')
    H.ok(ok and JobOf(view, 'every').last.by == 'ADM00009', 'Run now runs it and the list shows who ran it')
    H.eq(rate.windowMs, 25 * 60000, 'each job once per Config.Jobs.runNowMinutes')
    local a = audits[#audits]
    H.ok(a and a[1] == 'jobRun' and a[2] == 'every' and a[3] == 'n 3', 'audited: jobRun, the job and what it did')
    ok, e = RunNow('every')
    H.ok(not ok and e == 'err.rate_limited', 'a second press inside the window is refused')
    ok = RunNow('cleanup')
    H.ok(ok, 'the window is per job: another job still runs now')
    ok, e = RunNow('broken')
    H.ok(not ok and e == 'err.job_not_manual', 'a job without Run now stays on its timer')
    S.job('fails', {
        when = 'daily',
        manual = true,
        run = function() error('bad day') end,
    })
    ok, e = RunNow('fails')
    H.ok(not ok and e == 'err.timed_job_failed', 'a job that fails when run now says so')
    H.ok(audits[#audits][3]:find('bad day', 1, true) ~= nil, 'and the audit row keeps the error')
    Config.Jobs.runNowMinutes = 10
end

return H
