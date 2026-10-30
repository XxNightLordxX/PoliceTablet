-- CP.SupAwards (server): a supervisor gives points to an officer of his own department (step P22, the Mission

CP.SupAwards = CP.SupAwards or {}
local SA = CP.SupAwards
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'supawards'

local KEY = 'awardPoints'
local CITIZENID_MAX = 50
local POINTS_HARD_MAX = 10000      -- never above what one admin adjustment may move (CP.Corrections.adjustMax)

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

local function McCfg() return type(Config.MissionControls) == 'table' and Config.MissionControls or {} end

local function HardMax()
    local ok, n = Call('Corrections', 'adjustMax')
    return ok and math.tointeger(n) or POINTS_HARD_MAX
end

-- Points one supervisor may give a day in all (Config.MissionControls.awardPointsPerDay; 0 = no limit).
function SA.perDay() return math.max(0, math.floor(Num(McCfg().awardPointsPerDay, 100))) end

-- Config.AdminControl.pointAdjust: false stops the admin tool's deductions and every supervisor award.
local function AdjustOn()
    local c = Config.AdminControl
    return not (type(c) == 'table' and c.pointAdjust == false)
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
        range = { 1, HardMax() },
        viewExtra = function() return { perDay = SA.perDay() } end,
    })
    return true
end
Register()
SA.register = Register

local function IsAdmin(src) return CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src) == true end

-- The points one award may give in his department: lo, hi | nil.
local function PointsRange(dept)
    local b = DC().bounds(dept, KEY)
    local lo = math.max(1, math.floor(Num(b.min, 1)))
    local hi = math.min(HardMax(), math.floor(Num(b.max, 50)))
    if hi < lo then return nil end
    return lo, hi
end

-- The officer's department: his Qbox job while online, else cp_officers.department.
local function DeptOf(citizenid)
    local okS, src = Call('Qbx', 'getByCitizenId', citizenid)
    src = okS and math.tointeger(tonumber(src) or 0) or 0
    if src and src > 0 then
        local _, info = Call('Qbx', 'getInfo', src)
        if type(info) == 'table' and type(info.job) == 'table' then
            local _, dept = Call('Access', 'departmentForJob', info.job.name)
            if type(dept) == 'string' then return dept end
        end
    end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, d = pcall(MySQL.scalar.await, 'SELECT department FROM cp_officers WHERE citizenid = ? LIMIT 1',
        { citizenid })
    if ok and type(d) == 'string' and d ~= '' then return d end
    return nil
end

-- Points this player gave today (manual award rows with his license's characters as breakdown.by).
local function UsedToday(src, actor)
    return Kit.dailySum({ missionIds = { 'manual_award' }, actor = actor, src = src })
end

local function ActorOf(src)
    local _, info = Call('Qbx', 'getInfo', src)
    return type(info) == 'table' and info.citizenid or nil
end

-- What the Department Report's officer dialog needs for Give points: nil when that player may not give this officer
-- points (the control or AdminControl.pointAdjust off, not a supervisor, his own character, another department),
-- else { min, max, perDay, usedToday, confirmAbove } (an admin: no per-day count).
function SA.supView(src, citizenid)
    local n = math.tointeger(tonumber(src) or 0)
    if not n or n <= 0 or not AdjustOn() then return nil end
    local cid = Cid(citizenid)
    if not cid then return nil end
    local ok, _, _, dept = CanUse(n)
    if not ok or Kit.isSelf(n, cid) ~= false then return nil end
    local admin = IsAdmin(n)
    if not admin and DeptOf(cid) ~= dept then return nil end
    local lo, hi = PointsRange(dept)
    if not lo then return nil end
    local perDay = not admin and SA.perDay() or nil
    local _, above = Call('Corrections', 'confirmAbove')
    return {
        min = lo,
        max = hi,
        perDay = perDay ~= 0 and perDay or nil,
        usedToday = perDay and perDay ~= 0 and (UsedToday(n, ActorOf(n)) or 0) or nil,
        confirmAbove = math.tointeger(above),
    }
end

-- ============================================================================
--                               NET: SUPERVISORS
-- ============================================================================

local function OfficerTarget(payload) return { citizenid = Cid(payload.citizenid), strict = true } end

local function Confirm(p)
    local _, word = Call('Corrections', 'adjustConfirm', p)
    return word
end

-- { citizenid, points, reason, confirm? }: min to max points to an officer of his own department, never one of his
-- own characters; a supervisor gives at most Config.MissionControls.awardPointsPerDay points a day. Admins skip the
-- department and the per-day rule (the self rule and Config.AdminControl's limits stay).
Kit.supAction('server:sup:awardPoints', 'missionControls', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    if not AdjustOn() then return false, 'err.award_off' end
    local _, _, _, dept = CanUse(ctx.src)
    local lo, hi = PointsRange(dept)
    local points = math.tointeger(tonumber(ctx.payload.points) or 0)
    if not lo or not points or points < lo or points > hi then return false, 'err.award_points_range' end
    if ctx.role == 'supervisor' then
        local target = DeptOf(cid)
        if not target then return false, 'err.unknown_officer' end
        if target ~= dept then return false, 'err.other_department' end
        local perDay = SA.perDay()
        if perDay > 0 then
            local used = UsedToday(ctx.src, ctx.actor)
            if used == nil then return false, 'err.internal' end
            if used + points > perDay then return false, 'err.award_daily_limit' end
        end
    end
    if not (CP.Corrections and CP.Corrections.adjust) then return false, 'err.module_unavailable' end
    return CP.Corrections.adjust(ctx, cid, points)
end, {
    reason = true,
    self = OfficerTarget,
    targetRate = { 1, 10000 },
    confirm = Confirm,
    permission = function(src) return CanUse(src) end,
})
