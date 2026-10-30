-- CP.DeptNotices (server): a supervisor's department notices (step P13, the Mission control notices). A supervisor

CP.DeptNotices = CP.DeptNotices or {}
local DN = CP.DeptNotices
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'deptnotices'

local KEY = 'notices'

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function Int(v, lo, hi)
    local n = math.tointeger(tonumber(v) or 0.5)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false, nil end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

local function Corr() return CP.Corrections or {} end
local function McCfg() return type(Config.MissionControls) == 'table' and Config.MissionControls or {} end

-- Characters a department notice may hold (Config.MissionControls.noticeMaxLength, never above a staff notice's).
function DN.maxLength()
    local cap = math.floor(Num(Corr().NOTICE_MAX, 280))
    return math.max(1, math.min(cap, math.floor(Num(McCfg().noticeMaxLength, cap))))
end

-- Notices one supervisor may post a day (Config.MissionControls.noticesPerDay).
function DN.perDay() return math.max(0, math.floor(Num(McCfg().noticesPerDay, 5))) end

-- Notices that may run at once in one department (the staff notices' limit).
function DN.activeMax() return math.max(1, math.floor(Num(Corr().NOTICES_ACTIVE, 5))) end

-- Days a department notice may run (the staff notices' limit).
function DN.maxDays() return math.max(1, math.floor(Num(Corr().NOTICE_DAYS, 30))) end

-- ============================================================================
--                                 THE CONTROL
-- ============================================================================

local function DC() return CP.DeptControls end

local function Register()
    local dc = DC()
    if not (dc and dc.register) then return false end
    dc.register(KEY, {
        kind = 'action',
        bounded = false,
        viewExtra = function() return { maxLength = DN.maxLength(), perDay = DN.perDay() } end,
    })
    return true
end
Register()
DN.register = Register

-- ok, errKey, role, the department (his own; an admin's own department too).
local function CanUse(src)
    local dc = DC()
    if not (dc and dc.canChange) then return false, 'err.module_unavailable' end
    return dc.canChange(src, KEY, nil)
end

-- A running notice that is this department's own notice (posted by a supervisor for it alone).
local function OwnNotice(n, dept)
    return Corr().isDeptNotice and Corr().isDeptNotice(n.by) and type(n.departments) == 'table' and #n.departments == 1
        and n.departments[1] == dept
end

-- This department's notices still running: list | nil (database error).
local function Running(dept, now)
    local ok, rows = Call('Corrections', 'runningNotices', now)
    if not ok or type(rows) ~= 'table' then return nil end
    local out = {}
    for _, n in ipairs(rows) do
        if OwnNotice(n, dept) then out[#out + 1] = n end
    end
    return out
end
DN.running = Running

local function ActorOf(src)
    local _, info = Call('Qbx', 'getInfo', src)
    return type(info) == 'table' and info.citizenid or ('player:%d'):format(src)
end

-- What the Supervisor UI's Department notices card shows: nil, errKey when that player may not post (the control is
-- off, not a supervisor), else { department, short, maxLength, perDay, usedToday, activeMax, maxDays, notices }.
function DN.view(src)
    local n = math.tointeger(tonumber(src) or 0)
    if not n or n <= 0 then return nil, 'err.no_permission' end
    local ok, err, role, dept = CanUse(n)
    if not ok then return nil, err end
    local now = os.time()
    local rows = Running(dept, now)
    if not rows then return nil, 'err.internal' end
    local full = {}
    local okL, staff = Call('Leaderboard', 'staffNotices')
    for _, s in ipairs(okL and type(staff) == 'table' and staff or {}) do full[s.id] = s end
    local notices = {}
    for _, r in ipairs(rows) do
        local s = full[r.id] or {}
        notices[#notices + 1] = { id = r.id, text = s.text, expiresAt = s.expiresAt, createdAt = s.createdAt }
    end
    table.sort(notices, function(a, b) return a.id > b.id end)
    local d = type(Config.Departments) == 'table' and Config.Departments[dept] or {}
    local admin = role ~= 'supervisor'
    return {
        department = dept,
        short = type(d) == 'table' and d.short or dept,
        maxLength = DN.maxLength(),
        perDay = not admin and DN.perDay() or nil,
        usedToday = not admin and (Kit.dailyCount('deptNoticePost', { actor = ActorOf(n) }) or 0) or nil,
        activeMax = DN.activeMax(),
        maxDays = DN.maxDays(),
        notices = notices,
    }
end

-- ============================================================================
--                               NET: SUPERVISORS
-- ============================================================================

-- { text, days }: a notice for his own department only (forced), 1 to maxDays days.
Kit.supAction('server:sup:postNotice', 'missionControls', function(ctx)
    local _, _, role, dept = CanUse(ctx.src)
    if type(dept) ~= 'string' then return false, 'err.no_permission' end
    if not (Corr().noticeText and Corr().insertNotice) then return false, 'err.module_unavailable' end
    local text, errT = Corr().noticeText(ctx.payload.text, DN.maxLength())
    if not text then return false, errT end
    local days = Int(ctx.payload.days, 1, DN.maxDays())
    if not days then return false, 'err.notice_expiry' end
    if not CP.Net.rateOk(ctx.src, 'notice:post', 1, Corr().NOTICE_EVERY_MS or 60000) then
        return false, 'err.rate_limited'
    end
    if role == 'supervisor' then
        local used = Kit.dailyCount('deptNoticePost', { actor = ctx.actor })
        if used == nil then return false, 'err.internal' end
        if used >= DN.perDay() then return false, 'err.notice_per_day' end
    end
    local now = os.time()
    local running = Running(dept, now)
    if not running then return false, 'err.internal' end
    if #running >= DN.activeMax() then return false, 'err.dept_notice_too_many' end
    local by = U.clip(Corr().DEPT_NOTICE_PREFIX .. tostring(ctx.actor), 50)
    local id = Corr().insertNotice(text, { dept }, now + days * 86400, by, now)
    if not id then return false, 'err.internal' end
    ctx.audit('deptNoticePost', ('notice:%d'):format(id), nil, U.clip(text, 64), { category = 'board' })
    Call('Leaderboard', 'invalidate')
    return true, { id = id, department = dept }
end, {
    reason = 'optional',
    category = 'board',
    permission = function(src) return CanUse(src) end,
})

-- { id }: ends a running notice of his own department (any supervisor of it; admins: their own department's).
Kit.supAction('server:sup:endNotice', 'missionControls', function(ctx)
    local id = Int(ctx.payload.id, 1, 2147483647)
    if not id then return false, 'err.invalid_payload' end
    local _, _, _, dept = CanUse(ctx.src)
    if type(dept) ~= 'string' then return false, 'err.no_permission' end
    local running = Running(dept, os.time())
    if not running then return false, 'err.internal' end
    local found = false
    for _, r in ipairs(running) do
        if r.id == id then found = true end
    end
    if not found then return false, 'err.dept_notice_unknown' end
    local okK, errK = Kit.cas(
        'UPDATE cp_staff_notices SET removed_at = FROM_UNIXTIME(?) WHERE id = ? AND removed_at IS NULL',
        { os.time(), id })
    if not okK then return false, errK end
    ctx.audit('deptNoticeEnd', ('notice:%d'):format(id), nil, 'removed', { category = 'board' })
    Call('Leaderboard', 'invalidate')
    return true, { id = id }
end, {
    reason = 'optional',
    category = 'board',
    permission = function(src) return CanUse(src) end,
})

CP.Net.callback('sup:getDeptNotices', function(src) return DN.view(src) end, { rate = 3 })
