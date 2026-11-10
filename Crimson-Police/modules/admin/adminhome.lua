-- CP.AdminHome (server): Admin UI -> Home, a dashboard in one batched callback (admin:getHome): live now (officers on

-- CP.AdminHome (server): Admin UI -> Home, a dashboard in one batched callback (admin:getHome): live now (officers on
-- duty, the runs going, the queues waiting: flagged runs, profiles, disputes, stuck payments, player suspect cases),
-- the alerts (Problems lines, today's refused starts, Config health, the last mission load) and the shortcuts of
-- Config.AdminUi.homeShortcuts.

CP.AdminHome = CP.AdminHome or {}
local AH = CP.AdminHome
local TAG = 'adminhome'

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

-- A whole count of at least 0 (anything else = 0).
local function Count(ok, v)
    local n = ok and tonumber(v) or nil
    if not n or n ~= n or n < 0 or n == math.huge then return 0 end
    return math.floor(n)
end

-- The refused mission starts on the server's day (CP.Schedule, the daily reset), as Home's Refused starts today alert.
local function RefusedToday()
    local okL, list = Call('Refusals', 'list')
    local okNow, now = Call('Schedule', 'now')
    local okDay, dayStart = Call('Schedule', 'dayStart', okNow and now or os.time())
    if not okL or type(list) ~= 'table' or not okDay or type(dayStart) ~= 'number' then return 0 end
    local n = 0
    for _, r in ipairs(list) do
        if (tonumber(r.at) or 0) >= dayStart then n = n + 1 end
    end
    return n
end

-- The flagged runs an admin still has to approve or void (Review -> Flagged runs): one per run, the admin's
-- own runs left out as on that card. CP.Admin.flaggedCount counts them all (the card's rows stop at 200).
local function FlaggedRuns(src)
    local okI, info = Call('Qbx', 'getInfo', src)
    local cid = okI and type(info) == 'table' and type(info.citizenid) == 'string' and info.citizenid or ''
    return Count(Call('Admin', 'flaggedCount', cid))
end

-- The open real-suspect cases, or nil when the admin has no Player suspects screen (no antiFarmOverride key, or live
-- crimes and volunteers both off, or Config.RealPlayers.adminScreen = false).
local function OpenCases(src)
    local okP, can = Call('Permissions', 'can', src, 'antiFarmOverride')
    if not (okP and can == true) then return nil end
    local rs, on = CP.RealPlayers()
    if rs.adminScreen == false or not on then return nil end
    local ok, list = Call('Opponents', 'cases')
    if not ok or type(list) ~= 'table' then return 0 end
    local n = 0
    for _, c in ipairs(list) do
        if c.open == true then n = n + 1 end
    end
    return n
end

-- The officers on duty now: the total and each department's count (CP.Admin.onDutyCounts, as Departments shows).
local function OnDuty()
    local ok, counts = Call('Admin', 'onDutyCounts')
    counts = ok and type(counts) == 'table' and counts or {}
    local okD, depts = Call('Access', 'departments')
    local out, total = {}, 0
    for _, d in ipairs(okD and type(depts) == 'table' and depts or {}) do
        local n = Count(true, counts[d.key])
        total = total + n
        out[#out + 1] = { key = d.key, label = d.short or d.label or d.key, n = n }
    end
    return total, out
end

-- The runs going (CP.LiveCtl.liveRuns, the Live screen's list): the count and the first LIVE_ROWS as chips, or nil
-- when the admin has no liveRuns key (no Live screen actions: Home shows no runs).
local LIVE_ROWS = 6
local function Runs(src)
    local okP, can = Call('Permissions', 'can', src, 'liveRuns', nil, { admin = true })
    if not (okP and can == true) then return nil end
    local ok, list = Call('LiveCtl', 'liveRuns', src)
    list = ok and type(list) == 'table' and list or {}
    local rows = {}
    for i = 1, math.min(#list, LIVE_ROWS) do
        local r, people = list[i], 0
        for _, p in ipairs(type(r.participants) == 'table' and r.participants or {}) do
            if p.status == 'active' then people = people + 1 end
        end
        rows[i] = {
            runId = r.runId,
            missionLabel = tostring(r.missionLabel or r.missionId or ''),
            people = people,
            test = r.test == true,
        }
    end
    return { n = #list, rows = rows }
end

-- Config health (CP.ConfigHealth.run, every check): how many warning and error lines. Read again at most every
-- HEALTH_CACHE_S seconds (Home refreshes on pushes; Permissions -> Config health always runs the checks again).
local HEALTH_CACHE_S = 30
local healthCache = { at = -math.huge }
local function Health()
    local now = os.time()
    if now - healthCache.at < HEALTH_CACHE_S then return healthCache.value end
    local ok, items = Call('ConfigHealth', 'run')
    local value = nil
    if ok and type(items) == 'table' then
        value = { warn = 0, error = 0 }
        for _, item in ipairs(items) do
            if item.level == 'warn' or item.level == 'error' then value[item.level] = value[item.level] + 1 end
        end
    end
    healthCache = { at = now, value = value }
    return value
end

-- The last mission load (CP.Missions.loadSummary): loaded, refused (missions and edited built-ins), its error.
local function Load()
    local ok, sum = Call('Missions', 'loadSummary')
    if not ok or type(sum) ~= 'table' then return nil end
    local failed = type(sum.failed) == 'table' and #sum.failed or 0
    local over = type(sum.overrideFailed) == 'table' and #sum.overrideFailed or 0
    return { loaded = Count(true, sum.loaded), refused = failed + over, error = sum.error ~= nil and sum.error ~= false }
end

local function Setup()
    local ok, pending = Call('Setup', 'pending')
    return ok and pending == true
end

-- Config.AdminUi.homeShortcuts: the known keys in their order, each once (nil = the shipped five, {} = none).
AH.SHORTCUTS = { 'newMission', 'missionSwitch', 'pay', 'points', 'settings', 'live', 'review', 'activity' }
local SHIPPED = { 'newMission', 'missionSwitch', 'pay', 'points', 'settings' }
local SHORTCUTS_MAX = 8

function AH.shortcuts()
    local cfg = type(Config.AdminUi) == 'table' and Config.AdminUi.homeShortcuts or nil
    if cfg == nil then cfg = SHIPPED end
    local known, seen, out = {}, {}, {}
    for _, k in ipairs(AH.SHORTCUTS) do known[k] = true end
    for _, k in ipairs(type(cfg) == 'table' and cfg or {}) do
        if known[k] and not seen[k] and #out < SHORTCUTS_MAX then
            seen[k] = true
            out[#out + 1] = k
        end
    end
    return out
end

-- Everything Home shows, for one admin (src). queues.rsCases is nil when that line is not his to see; live.runs is
-- nil without the liveRuns key.
function AH.home(src)
    local onDuty, departments = OnDuty()
    return {
        live = { onDuty = onDuty, departments = departments, runs = Runs(src) },
        queues = {
            flagged = FlaggedRuns(src),
            profiles = Count(Call('Profile', 'reviewCount')),
            disputes = Count(Call('Disputes', 'openCount')),
            payments = Count(Call('Payments', 'stuckCount')),
            rsCases = OpenCases(src),
        },
        alerts = {
            problems = Count(Call('Problems', 'total')),
            refusedToday = RefusedToday(),
            health = Health(),
            load = Load(),
        },
        shortcuts = AH.shortcuts(),
        -- true while the First-start setup shows on Home (CP.Setup: Config.AdminUi.setupScreen, not done yet)
        setup = Setup(),
        serverTime = os.time(),
    }
end

-- ============================================================================
--                                     NET
-- ============================================================================

if CP.AdminKit and CP.AdminKit.callback then
    CP.AdminKit.callback('admin:getHome', 'openAdmin', function(ctx)
        return AH.home(ctx.src)
    end, { rate = 2 })
end
