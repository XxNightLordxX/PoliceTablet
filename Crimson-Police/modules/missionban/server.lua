-- CP.MissionBan (server): a supervisor's temporary mission ban of one officer (step P11, the Mission control

CP.MissionBan = CP.MissionBan or {}
local MB = CP.MissionBan
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'missionban'

local KEY = 'missionBan'
local HOURS_MAX = 168          -- the admin's max may not go past a week
local CITIZENID_MAX = 50
local NAME_MAX = 64

local Bans = nil               -- citizenid -> { until, by, name, dept, reason, at } (nil until read from the store)

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
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

local function Cid(v)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v)
    if s == '' or #s > CITIZENID_MAX or not s:match('^[%w_%-]+$') then return nil end
    return s
end

local function Decode(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return nil end
    local ok, t = pcall(json.decode, v)
    return ok and type(t) == 'table' and t or nil
end

local function McCfg() return type(Config.MissionControls) == 'table' and Config.MissionControls or {} end

-- Bans one supervisor may set a day (Config.MissionControls.missionBanPerDay).
function MB.perDay() return math.max(0, math.floor(Num(McCfg().missionBanPerDay, 3))) end

-- ============================================================================
--                                  THE STORE
-- ============================================================================

-- Every saved ban, read once (after the migrations) and then kept in memory.
local function Load()
    if Bans then return Bans end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, rows = pcall(MySQL.query.await,
        'SELECT citizenid, mission_ban FROM cp_officers WHERE mission_ban IS NOT NULL')
    if not ok then
        CP.err(TAG, 'reading the mission bans failed: %s', tostring(rows))
        return {}
    end
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local ban = Decode(r.mission_ban)
        if ban and Num(ban['until'], 0) > 0 then out[r.citizenid] = ban end
    end
    Bans = out
    return Bans
end

-- ok | false, errKey
local function Save(citizenid, ban)
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, n = pcall(MySQL.update.await, 'UPDATE cp_officers SET mission_ban = ? WHERE citizenid = ?',
        { ban and json.encode(ban) or nil, citizenid })
    if not ok then
        CP.err(TAG, 'saving the mission ban of %s failed: %s', citizenid, tostring(n))
        return false, 'err.internal'
    end
    if (tonumber(n) or 0) < 1 then return false, 'err.unknown_officer' end
    Load()[citizenid] = ban
    return true
end

-- The ban in force for this officer (until is still ahead), else nil.
function MB.get(citizenid, now)
    if type(citizenid) ~= 'string' then return nil end
    local ban = Load()[citizenid]
    if not ban or Num(ban['until'], 0) <= (now or os.time()) then return nil end
    return ban
end

-- The first of these officers ({ citizenid, src }) with a ban in force: officer, ban | nil.
function MB.first(officers, now)
    for _, o in ipairs(type(officers) == 'table' and officers or {}) do
        local ban = type(o) == 'table' and MB.get(o.citizenid, now) or nil
        if ban then return o, ban end
    end
    return nil
end

-- What the officer's screens show: { until, by (the name), reason, mine } or nil.
function MB.view(citizenid, now)
    local ban = MB.get(citizenid, now)
    if not ban then return nil end
    return { ['until'] = math.floor(Num(ban['until'], 0)), by = ban.name, reason = ban.reason }
end

-- Forget what is in memory (a storage switch or restore, tests): read again at the next lookup.
function MB.clearCache() Bans = nil end

-- Tell the officer's tablet (and his unit's) that the board changed.
local function PushBoard(citizenid)
    local ok, src = Call('Qbx', 'getByCitizenId', citizenid)
    src = ok and math.tointeger(tonumber(src) or 0) or 0
    if not src or src <= 0 then return end
    local okM, members = Call('Units', 'members', src)
    for _, s in ipairs(okM and type(members) == 'table' and #members > 0 and members or { src }) do
        Call('Tablet', 'push', s, 'board', { missionBan = true })
    end
end

-- ============================================================================
--                          THE CONTROL AND ITS RULES
-- ============================================================================

local function DC() return CP.DeptControls end

local function CanUse(src)
    local dc = DC()
    if not (dc and dc.canChange) then return false, 'err.module_unavailable' end
    return dc.canChange(src, KEY, nil)
end

local function Register()
    local dc = DC()
    if not (dc and dc.register) then return false end
    dc.register(KEY, {
        kind = 'action',
        integer = true,
        range = { 1, HOURS_MAX },
        viewExtra = function() return { perDay = MB.perDay() } end,
    })
    return true
end
Register()
MB.register = Register

local function IsAdmin(src) return CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src) == true end

-- The hours a supervisor may pick in his department: lo, hi | nil.
local function HoursRange(dept)
    local b = DC().bounds(dept, KEY)
    local lo = math.max(1, math.floor(Num(b.min, 1)))
    local hi = math.min(HOURS_MAX, math.floor(Num(b.max, 24)))
    if hi < lo then return nil end
    return lo, hi
end

-- The target as the rules need it: online, his department and grade (Qbox, on duty or not). info | nil, errKey.
local function Target(citizenid)
    local ok, src = Call('Qbx', 'getByCitizenId', citizenid)
    src = ok and math.tointeger(tonumber(src) or 0) or 0
    if not src or src <= 0 then return nil, 'err.mission_ban_offline' end
    local _, info = Call('Qbx', 'getInfo', src)
    if type(info) ~= 'table' or type(info.job) ~= 'table' then return nil, 'err.mission_ban_offline' end
    local _, dept = Call('Access', 'departmentForJob', info.job.name)
    return { src = src, dept = dept, grade = math.floor(Num(info.job.gradeLevel, 0)), name = info.name }
end

-- What the Department Report's officer dialog needs for Mission ban: nil when that player may not ban this officer
-- (the control is off, not a supervisor, his own character), else { min, max (hours), perDay, usedToday, ban }.
function MB.supView(src, citizenid)
    local n = math.tointeger(tonumber(src) or 0)
    if not n or n <= 0 then return nil end
    local ok, _, _, dept = CanUse(n)
    if not ok or Kit.isSelf(n, citizenid) ~= false then return nil end
    local admin = IsAdmin(n)
    local lo, hi = HoursRange(dept)
    if not lo then return nil end
    local ban = MB.get(citizenid)
    local actor = select(2, Call('Qbx', 'getInfo', n))
    actor = type(actor) == 'table' and actor.citizenid or nil
    local canLift = nil
    if ban then canLift = admin or ban.by == actor end
    return {
        min = lo,
        max = hi,
        perDay = not admin and MB.perDay() or nil,
        usedToday = not admin and (Kit.dailyCount('missionBan', { actor = actor }) or 0) or nil,
        ban = ban and MB.view(citizenid) or nil,
        canLift = canLift,
    }
end

-- ============================================================================
--                               NET: SUPERVISORS
-- ============================================================================

local function OfficerTarget(payload) return { citizenid = Cid(payload.citizenid) } end

-- { citizenid, hours, reason }: an officer of his own department with a lower grade, never himself, for min to max
-- hours; a supervisor at most Config.MissionControls.missionBanPerDay a day. Admins skip the department and grade
-- rules (the self rule stays).
Kit.supAction('server:sup:missionBan', 'missionControls', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    local _, _, _, dept = CanUse(ctx.src)
    local lo, hi = HoursRange(dept)
    local hours = math.tointeger(tonumber(ctx.payload.hours) or 0)
    if not lo or not hours or hours < lo or hours > hi then return false, 'err.mission_ban_hours' end
    local target, errT = Target(cid)
    if not target then return false, errT end
    local sup = ctx.role == 'supervisor'
    local by = select(2, Call('Access', 'getOfficer', ctx.src))
    if sup then
        if type(by) ~= 'table' then return false, 'err.no_permission' end
        if target.dept ~= by.department then return false, 'err.other_department' end
        if target.grade >= math.floor(Num(by.gradeLevel, 0)) then return false, 'err.mission_ban_grade' end
        local used = Kit.dailyCount('missionBan', { actor = ctx.actor })
        if used == nil then return false, 'err.internal' end
        if used >= MB.perDay() then return false, 'err.mission_ban_used' end
    end
    local now = os.time()
    local old = MB.get(cid, now)
    local name
    if type(by) == 'table' then
        name = ('%s %s'):format(by.rank or '', by.name or ''):gsub('^%s+', '')
    else
        local _, info = Call('Qbx', 'getInfo', ctx.src)
        name = type(info) == 'table' and info.name or ctx.actor
    end
    local ban = {
        ['until'] = now + hours * 3600,
        by = ctx.actor,
        name = U.clip(name, NAME_MAX),
        dept = target.dept,
        reason = ctx.reason,
        at = now,
    }
    local okS, errS = Save(cid, ban)
    if not okS then return false, errS end
    ctx.audit('missionBan', cid, old and tostring(old['until']) or nil, tostring(ban['until']), { category = 'flags' })
    ctx.notify(cid, 'warning', 'sup.notice.mission_banned', { hours = hours, name = ban.name })
    PushBoard(cid)
    return true, { citizenid = cid, ['until'] = ban['until'] }
end, {
    reason = true,
    self = OfficerTarget,
    targetRate = { 1, 3000 },
    category = 'flags',
    permission = function(src) return CanUse(src) end,
})

-- Lifts a ban in force early: the supervisor who set it, or an admin.
local function Lift(ctx, adminOnly)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    local ban = MB.get(cid)
    if not ban then return false, 'err.mission_ban_none' end
    if not adminOnly and ctx.role == 'supervisor' and ban.by ~= ctx.actor then
        return false, 'err.mission_ban_not_yours'
    end
    local okS, errS = Save(cid, nil)
    if not okS then return false, errS end
    ctx.audit('missionBanLift', cid, tostring(ban['until']), nil, { category = 'flags' })
    ctx.notify(cid, 'info', 'sup.notice.mission_ban_lifted', {})
    PushBoard(cid)
    return true, { citizenid = cid }
end

Kit.supAction('server:sup:liftMissionBan', 'missionControls', function(ctx) return Lift(ctx, false) end, {
    reason = true,
    self = OfficerTarget,
    targetRate = { 1, 3000 },
    category = 'flags',
    permission = function(src) return CanUse(src) end,
})

-- ============================================================================
--                                 NET: ADMINS
-- ============================================================================

-- Admin UI -> Officers -> Today & cooldowns: lift anyone's ban (also while the control is switched off).
Kit.action('server:admin:liftMissionBan', 'antiFarmOverride', function(ctx) return Lift(ctx, true) end, {
    reason = true,
    self = OfficerTarget,
    targetRate = { 1, 3000 },
    category = 'flags',
})

-- ============================================================================
--                                   START-UP
-- ============================================================================

CreateThread(function()
    local ok, err = pcall(Load)
    if not ok then CP.err(TAG, 'start: %s', tostring(err)) end
end)
