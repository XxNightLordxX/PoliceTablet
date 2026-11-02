-- CP.CrimTab (server, step G2): the criminal tablet for players who play real suspects (Config.CriminalTablet). It is

CP.CrimTab = CP.CrimTab or {}
local C = CP.CrimTab
local TAG = 'crimtab'

local history = {} -- [citizenid] = { { endedAt, missionType, role, outcome, dropout, result }, ... } newest first

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.CriminalTablet or {} end

local function On() return Cfg().enabled == true end

local function VolCfg() return Config.Volunteers or {} end

local function Num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then v = default end
    if lo and v < lo then v = lo end
    if hi and v > hi then v = hi end
    return v
end

local function ToSrc(src)
    local n = tonumber(src)
    if not n or n < 1 or n ~= math.floor(n) then return nil end
    return n
end

local function HistorySize() return math.floor(Num(Cfg().historySize, 20, 1, 100)) end

-- A police job of Config.Departments (on or off duty).
local function PoliceJob(job)
    if type(job) ~= 'table' or type(job.name) ~= 'string' or not CP.Access then return false end
    if CP.Access.departmentForJob and CP.Access.departmentForJob(job.name) then return true end
    return CP.Access.offDepartmentForJob ~= nil and CP.Access.offDepartmentForJob(job.name) ~= nil
end

local function TypeLabel(key)
    local t = type(Config.MissionTypes) == 'table' and Config.MissionTypes[key] or nil
    if type(t) == 'table' and type(t.label) == 'string' then return t.label end
    return type(key) == 'string' and key or nil
end

-- 1500 -> '1,500'
local function Dollars(n)
    local s = tostring(math.floor(Num(n, 0, 0)))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    return (out:gsub('^,', ''))
end

-- What Pay volunteer suspects (Config.FeatureRewards.suspect, step G3) pays for a fair case of missionType (its byType
-- amounts, step H1), as the Jobs card's Reward line; nil while it is off (the card says Crimson-Police pays nothing).
function C.rewardText(missionType)
    local FR = CP.FeatureRewards
    if not (FR and FR.enabled and FR.enabled('suspect')) then return nil end
    local away = FR.money('suspect', { outcome = 'got_away', missionType = missionType })
    local caught = FR.money('suspect', { outcome = 'detained', missionType = missionType })
    local cfg = FR.cfg('suspect') or {}
    local items = type(cfg.items) == 'table' and next(cfg.items) ~= nil and (Config.Rewards or {}).enabled == true
    if away <= 0 and caught <= 0 and not items then return nil end
    local text = CP.L('crimtab.jobs.reward_money', { away = Dollars(away), caught = Dollars(caught) })
    if items then text = text .. ' ' .. CP.L('crimtab.jobs.reward_items') end
    return text
end

-- ============================================================================
--                                   THE API
-- ============================================================================

-- Whether src may use the criminal tablet now -> ok, errKey, info. Never on police duty; access 'everyone' (shipped)
-- = any job but a police job, 'granted' = the criminalTablet extra grant (Admin UI -> Permissions -> Extra grants).
function C.canUse(src)
    if not On() then return false, 'err.crimtab_off' end
    local n = ToSrc(src)
    local info = n and CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) ~= 'table' or type(info.citizenid) ~= 'string' or info.citizenid == '' then
        return false, 'err.crimtab_not_loaded'
    end
    local police = PoliceJob(info.job)
    if police and info.job.onduty == true then return false, 'err.crimtab_on_duty' end
    if Cfg().access == 'granted' then
        local P = CP.Permissions
        if not (P and P.granted and P.granted(n, 'criminalTablet')) then return false, 'err.crimtab_no_access' end
    elseif police then
        return false, 'err.crimtab_police'
    end
    return true, nil, info
end

-- Config.CriminalTablet.replaceCommand: the volunteer command opens this tablet for src instead of its menu.
function C.replacesCommand(src)
    if Cfg().replaceCommand ~= true then return false end
    return (C.canUse(src)) == true
end

-- His past cases (newest first, copies).
function C.historyOf(cid)
    local out = {}
    for i, h in ipairs(history[cid] or {}) do out[i] = CP.U.copy(h) end
    return out
end

-- A volunteer case ended (CP.Volunteers' server-only volunteerEnded payload): one line of his History.
function C.record(payload)
    if type(payload) ~= 'table' or type(payload.citizenid) ~= 'string' or payload.citizenid == '' then return false end
    local list = history[payload.citizenid] or {}
    table.insert(list, 1, {
        endedAt = tonumber(payload.endedAt) or os.time(),
        missionType = TypeLabel(payload.missionType),
        role = payload.role,
        outcome = payload.outcome,
        dropout = payload.dropout,
        result = payload.result,
    })
    for i = #list, HistorySize() + 1, -1 do list[i] = nil end
    history[payload.citizenid] = list
    return true
end

-- Everything the tablet shows -> view | nil, errKey.
function C.view(src)
    local ok, err, info = C.canUse(src)
    if not ok then return nil, err end
    local V = CP.Volunteers or {}
    local cid = info.citizenid
    local vc = VolCfg()
    local volOn = vc.enabled == true
    local listing = V.listingOf and V.listingOf(src) or { listed = false, roles = {} }
    local canJoin, why, _, blockedAt = false, 'off', nil, nil
    if volOn and V.check then canJoin, why, _, blockedAt = V.check(src) end
    local strikes = V.strikeInfo and V.strikeInfo(cid) or { strikes = {} }
    local ask = volOn and V.askOf and V.askOf(cid) or nil
    if ask then
        ask.reward = C.rewardText(ask.missionType)
        ask.missionType = TypeLabel(ask.missionType)
    end
    local case = V.caseOf and V.caseOf(cid) or nil
    return {
        now = os.time(),
        volunteersOn = volOn,
        name = info.name,
        status = {
            listed = listing.listed == true,
            untilAt = listing.untilAt,
            roles = listing.roles or {},
            allRoles = V.roles or { 'runner', 'driver', 'fugitive' },
            canJoin = listing.listed ~= true and canJoin == true,
            why = (listing.listed ~= true and not canJoin) and why or nil,
            blockedUntil = blockedAt or strikes.blockedUntil,
        },
        jobs = ask and { ask } or {},
        active = case,
        history = C.historyOf(cid),
        strikes = strikes.strikes or {},
        rules = {
            windowMinutes = math.floor(Num(vc.windowMinutes, 60, 1, 1440)),
            strikes = math.floor(Num(vc.strikes, 3, 1, 100)),
            strikeHours = math.floor(Num(vc.strikeHours, 24, 1, 8760)),
            blockHours = math.floor(Num(vc.blockHours, 24, 1, 8760)),
            askSeconds = math.floor(Num(vc.askSeconds, 30, 10, 120)),
            travelMinutes = math.ceil(Num(vc.travelSeconds, 300, 60, 1800) / 60),
            cancelGraceSeconds = math.floor(Num(vc.cancelGraceSeconds, 60, 0, 600)),
        },
    }
end

-- ============================================================================
--                                 THE ACTIONS
-- ============================================================================
-- Each goes through CP.Volunteers with every check it already has (the window, strikes, duty, the question's token
-- and time); a refusal answers its volunteer.refused.* text.

local function Refusal(why)
    if why == 'blocked' then
        return 'err.crimtab_blocked'
    end -- Home shows when the block ends
    local V = CP.Volunteers
    return V and V.refusalKey and V.refusalKey(why) or 'volunteer.refused.other'
end

local ROLE_SET = { runner = true, driver = true, fugitive = true }

-- The roles ticked, as the set CP.Volunteers takes: { runner = true, ... } from a list or a set.
local function Roles(v)
    if type(v) ~= 'table' then return nil end
    local out = {}
    for k, val in pairs(v) do
        if type(k) == 'number' and type(val) == 'string' and ROLE_SET[val] then out[val] = true end
        if type(k) == 'string' and ROLE_SET[k] and val == true then out[k] = true end
    end
    return out
end

local ACTIONS = {
    join = function(src, p)
        local ok, why = CP.Volunteers.join(src, Roles(p.roles))
        if not ok then return false, Refusal(why) end
        return true
    end,
    renew = function(src)
        local ok, why = CP.Volunteers.renew(src)
        if not ok then return false, Refusal(why) end
        return true
    end,
    roles = function(src, p)
        local ok, why = CP.Volunteers.setRoles(src, Roles(p.roles))
        if not ok then return false, Refusal(why) end
        return true
    end,
    stop = function(src)
        if CP.Volunteers.cancelCase then CP.Volunteers.cancelCase(src) end
        local ok, why = CP.Volunteers.stop(src)
        if not ok then return false, Refusal(why) end
        return true
    end,
    answer = function(src, p)
        if type(p.token) ~= 'string' or #p.token > 32 then return false, 'err.invalid_payload' end
        local ok, why = CP.Volunteers.answer(src, { token = p.token, yes = p.yes == true })
        if not ok then return false, why == 'late' and 'volunteer.ask.too_late' or 'err.crimtab_job_gone' end
        return true
    end,
    cancel = function(src)
        local ok = CP.Volunteers.cancelCase(src)
        if not ok then return false, 'volunteer.refused.no_case' end
        return true
    end,
}

-- payload = { what = 'join' | 'renew' | 'roles' | 'stop' | 'answer' | 'cancel', roles, token, yes } -> the fresh view.
local function Act(src, payload)
    if type(payload) ~= 'table' or type(payload.what) ~= 'string' then return false, 'err.invalid_payload' end
    local fn = ACTIONS[payload.what]
    if not fn then return false, 'err.invalid_payload' end
    local ok, err = C.canUse(src)
    if not ok then return false, err end
    if not CP.Volunteers or not CP.Volunteers.join then return false, 'err.crimtab_off' end
    if payload.what ~= 'stop' and payload.what ~= 'cancel' and (Config.Volunteers or {}).enabled ~= true then
        return false, 'volunteer.refused.off'
    end
    local done, why = fn(src, payload)
    if not done then return false, why end
    CP.log(TAG, '%d: %s', src, payload.what)
    return true, C.view(src)
end
C._act = Act

if CP.Net and CP.Net.callback then
    CP.Net.callback('crimtab:get', function(src) return C.view(src) end, { rate = 4 })
    CP.Net.action('server:crimtab:act', Act, { rate = 4 })
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

AddEventHandler(CP.e('server:volunteerEnded'), function(payload)
    local ok, err = pcall(C.record, payload)
    if not ok then CP.err(TAG, 'the History line failed: %s', tostring(err)) end
end)

-- On police duty, or a police job without access: the open tablet closes (the client only acts while it is open).
local function Recheck(src)
    src = ToSrc(src)
    if not src or not On() then return end
    if not C.canUse(src) then TriggerClientEvent(CP.e('client:crimtabClose'), src) end
end
C._recheck = Recheck

CreateThread(function()
    Wait(0)
    local Q = CP.Qbx
    if not (Q and Q.onDutyChange and Q.onJobChange) then return end
    Q.onDutyChange(function(src, onDuty) if onDuty then Recheck(src) end end)
    Q.onJobChange(function(src) Recheck(src) end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    history = {}
end)
