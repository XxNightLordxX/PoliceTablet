-- CP.Volunteers (server, step V20): the volunteer list behind Config.Volunteers.command (default /crimsonheat). A

CP.Volunteers = CP.Volunteers or {}
local V = CP.Volunteers
local TAG = 'volunteers'

local ROLES = { 'runner', 'driver', 'fugitive' }   -- the suspects a volunteer can play (§7.3 volunteerSlot roles)
local SWEEP_MS = 15000                             -- the window and duty check, only while someone volunteers
local AFK_KEY = 'volunteers'                       -- CP.Opponents.sampleCrew key: AFK samples of every volunteer

local listed = {}       -- [citizenid] = { cid, src, who, name, roles = { [role] = true }, since, untilAt } (os.time)
local cidOf = {}        -- [server id] = citizenid of a listed volunteer
local whoOf = {}        -- [citizenid] = the player key strikes are kept under (his license, else 'cid:<citizenid>')
local strikesOf = {}    -- [who] = { os.time(), ... } strikes within strikeHours
local blockedUntil = {} -- [who] = os.time() the strikes block ends
local sweep = { on = false, token = 0 }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.Volunteers or {} end

local function On() return Cfg().enabled == true end

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

local function WindowSeconds() return math.floor(Num(Cfg().windowMinutes, 60, 1, 1440) * 60) end

local function MaxStrikes() return math.floor(Num(Cfg().strikes, 3, 1, 100)) end

local function Note(src, kind, key, vars)
    if src then TriggerClientEvent(CP.e('client:volunteerNote'), src, kind, key, vars) end
end

local function WhoOf(info)
    if type(info.license) == 'string' and info.license ~= '' then return info.license end
    return 'cid:' .. tostring(info.citizenid)
end

-- The roles picked, in ROLES order -> { [role] = true } or nil when none is valid.
local function RolesOf(v)
    if type(v) ~= 'table' then return nil end
    local out, any = {}, false
    for _, role in ipairs(ROLES) do
        if v[role] == true then out[role], any = true, true end
    end
    return any and out or nil
end

local function RoleList(roles)
    local out = {}
    for _, role in ipairs(ROLES) do
        if roles and roles[role] then out[#out + 1] = role end
    end
    return out
end

-- Strikes still inside strikeHours (older ones dropped) -> the count.
local function StrikeCount(who, now)
    local list = strikesOf[who]
    if not list then return 0 end
    local since = now - math.floor(Num(Cfg().strikeHours, 24, 1, 8760) * 3600)
    local kept = {}
    for _, at in ipairs(list) do
        if at > since then kept[#kept + 1] = at end
    end
    strikesOf[who] = #kept > 0 and kept or nil
    return #kept
end

local function BlockedAt(who, now)
    local t = blockedUntil[who]
    if t and t > now then return t end
    blockedUntil[who] = nil
    return nil
end

-- ============================================================================
--                                   THE LIST
-- ============================================================================

local function DeptDuty(info)
    local job = info and info.job
    if type(job) ~= 'table' or job.onduty ~= true or type(job.name) ~= 'string' or not CP.Access then return false end
    if CP.Access.departmentForJob and CP.Access.departmentForJob(job.name) then return true end
    return CP.Access.offDepartmentForJob ~= nil and CP.Access.offDepartmentForJob(job.name) ~= nil
end

-- Takes the volunteer off the list. why: stopped, expired, on_duty, excluded, strikes, disabled, left. Everyone but
-- one who left is told why.
local function End(cid, why)
    local v = listed[cid]
    if not v then return false end
    listed[cid] = nil
    if v.src and cidOf[v.src] == cid then cidOf[v.src] = nil end
    if CP.Opponents and CP.Opponents.unsampleCrew then pcall(CP.Opponents.unsampleCrew, AFK_KEY, { cid }) end
    if why ~= 'left' then Note(v.src, why == 'stopped' and 'inform' or 'warning', 'volunteer.ended.' .. why) end
    CP.log(TAG, '%s stopped volunteering (%s)', cid, why)
    return true
end

local function Sweep()
    local now = os.time()
    for cid, v in pairs(listed) do
        if not On() then
            End(cid, 'disabled')
        elseif now >= v.untilAt then
            End(cid, 'expired')
        elseif CP.Opponents and CP.Opponents.excluded and CP.Opponents.excluded(cid) then
            End(cid, 'excluded')
        elseif BlockedAt(v.who, now) then
            End(cid, 'strikes')
        elseif DeptDuty(CP.Qbx and CP.Qbx.getInfo and v.src and CP.Qbx.getInfo(v.src)) then
            End(cid, 'on_duty')
        end
    end
end

local function StartSweep()
    if sweep.on then return end
    sweep.on = true
    sweep.token = sweep.token + 1
    local token = sweep.token
    CreateThread(function()
        while sweep.token == token and next(listed) ~= nil do
            Wait(SWEEP_MS)
            if sweep.token ~= token then return end
            local ok, err = pcall(Sweep)
            if not ok then CP.err(TAG, 'the volunteer check failed: ' .. tostring(err)) end
        end
        if sweep.token == token then sweep.on = false end
    end)
end

-- ============================================================================
--                                   THE API
-- ============================================================================

-- Whether src may volunteer now -> ok, reason, info, untilAt. Reasons: off, not_loaded, the CP.Opponents.eligible
-- reasons (in_case, instance, arena_flag, on_duty, job_hop, afk, admin, excluded), excluded (an admin's Exclude),
-- blocked (strikes; untilAt = when the block ends).
function V.check(src)
    if not On() then return false, 'off' end
    local n = ToSrc(src)
    local info = n and CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) ~= 'table' or type(info.citizenid) ~= 'string' or info.citizenid == '' then
        return false, 'not_loaded'
    end
    local Opp = CP.Opponents
    if Opp and Opp.eligible then
        local ok, why = Opp.eligible(n)
        if not ok then return false, why or 'not_loaded', info end
    end
    if Opp and Opp.excluded and Opp.excluded(info.citizenid) then return false, 'excluded', info end
    local now = os.time()
    local untilAt = BlockedAt(WhoOf(info), now) or BlockedAt('cid:' .. info.citizenid, now)
    if untilAt then return false, 'blocked', info, untilAt end
    return true, nil, info
end

-- Puts src on the list for windowMinutes -> true, untilAt | false, reason.
function V.join(src, roles)
    local n = ToSrc(src)
    local ok, why, info, untilAt = V.check(n)
    if not ok then return false, why, untilAt end
    local cid = info.citizenid
    if listed[cid] then return false, 'already' end
    local picked = RolesOf(roles)
    if not picked then return false, 'no_role' end
    local now = os.time()
    local old = cidOf[n]
    if old and old ~= cid then End(old, 'left') end
    local who = WhoOf(info)
    whoOf[cid] = who
    listed[cid] = {
        cid = cid,
        src = n,
        who = who,
        name = info.name,
        roles = picked,
        since = now,
        untilAt = now + WindowSeconds(),
    }
    cidOf[n] = cid
    if CP.Opponents and CP.Opponents.sampleCrew then pcall(CP.Opponents.sampleCrew, AFK_KEY, { cid }) end
    StartSweep()
    CP.log(TAG, '%s volunteers (%s)', cid, table.concat(RoleList(picked), ', '))
    return true, listed[cid].untilAt
end

-- A fresh window from now, after the same checks as joining -> true, untilAt | false, reason.
function V.renew(src)
    local n = ToSrc(src)
    local cid = n and cidOf[n]
    local v = cid and listed[cid]
    if not v then return false, 'not_listed' end
    local ok, why, _, untilAt = V.check(n)
    if not ok then return false, why, untilAt end
    v.untilAt = os.time() + WindowSeconds()
    return true, v.untilAt
end

-- Changes the suspects a volunteer plays -> true | false, reason.
function V.setRoles(src, roles)
    local n = ToSrc(src)
    local v = n and cidOf[n] and listed[cidOf[n]]
    if not v then return false, 'not_listed' end
    local picked = RolesOf(roles)
    if not picked then return false, 'no_role' end
    v.roles = picked
    return true
end

-- The volunteer stops himself -> true | false, 'not_listed'.
function V.stop(src)
    local n = ToSrc(src)
    local cid = n and cidOf[n]
    if not cid or not listed[cid] then return false, 'not_listed' end
    End(cid, 'stopped')
    return true
end

-- A strike for this citizenid (later steps: a no-show, walking away from a case he said yes to). Reaching
-- Config.Volunteers.strikes within strikeHours blocks the player for blockHours and ends his listing.
-- -> count, blockedUntil|nil.
function V.strike(cid, why)
    if type(cid) ~= 'string' or cid == '' then return 0 end
    local who = whoOf[cid] or ('cid:' .. cid)
    local now = os.time()
    local list = strikesOf[who] or {}
    list[#list + 1] = now
    strikesOf[who] = list
    local count = StrikeCount(who, now)
    local v = listed[cid]
    CP.log(TAG, 'strike %d for %s (%s)', count, cid, tostring(why))
    if count >= MaxStrikes() then
        strikesOf[who] = nil
        local untilAt = now + math.floor(Num(Cfg().blockHours, 24, 1, 8760) * 3600)
        blockedUntil[who] = untilAt
        for other, entry in pairs(listed) do
            if entry.who == who then End(other, 'strikes') end
        end
        return count, untilAt
    end
    if v then Note(v.src, 'warning', 'volunteer.strike', { count = count, max = MaxStrikes() }) end
    return count, nil
end

function V.isListed(cid) return listed[cid] ~= nil end

-- Every volunteer on the list, as copies: { cid, src, name, roles = { role, ... }, since, untilAt }.
function V.list()
    local out = {}
    for cid, v in pairs(listed) do
        out[#out + 1] = {
            cid = cid,
            src = v.src,
            name = v.name,
            roles = RoleList(v.roles),
            since = v.since,
            untilAt = v.untilAt,
        }
    end
    table.sort(out, function(a, b) return a.since < b.since or (a.since == b.since and a.cid < b.cid) end)
    return out
end

-- Strikes within strikeHours of this citizenid's player.
function V.strikes(cid)
    return StrikeCount(whoOf[cid] or ('cid:' .. tostring(cid)), os.time())
end

V.roles = ROLES
V.endListing = End
V._sweep = Sweep

-- ============================================================================
--                             THE COMMAND'S EVENT
-- ============================================================================

-- What the command's menu shows: on the list (minutes left and his picks) or the start (the window and strikes).
local function MenuOf(src, info)
    local cid = cidOf[src]
    local v = cid and listed[cid]
    local strikes = V.strikes(cid or info.citizenid)
    if v then
        return {
            active = true,
            minutesLeft = math.max(1, math.ceil((v.untilAt - os.time()) / 60)),
            roles = RoleList(v.roles),
            strikes = strikes,
            maxStrikes = MaxStrikes(),
        }
    end
    return {
        active = false,
        minutes = math.floor(WindowSeconds() / 60),
        roles = ROLES,
        strikes = strikes,
        maxStrikes = MaxStrikes(),
    }
end

local REFUSAL = {
    off = true,
    not_loaded = true,
    in_case = true,
    instance = true,
    arena_flag = true,
    on_duty = true,
    job_hop = true,
    afk = true,
    admin = true,
    excluded = true,
    blocked = true,
    already = true,
    no_role = true,
    not_listed = true,
}

local function Refused(src, why, untilAt)
    local key = REFUSAL[why] and ('volunteer.refused.' .. why) or 'volunteer.refused.other'
    local vars = untilAt and { hours = math.max(1, math.ceil((untilAt - os.time()) / 3600)) } or nil
    Note(src, 'error', key, vars)
end

local ACTIONS = {
    open = function(src)
        if not On() then return Refused(src, 'off') end
        local listedCid = cidOf[src]
        if listedCid and listed[listedCid] then
            return TriggerClientEvent(CP.e('client:volunteerMenu'), src, MenuOf(src, { citizenid = listedCid }))
        end
        local ok, why, info, untilAt = V.check(src)
        if not ok then return Refused(src, why, untilAt) end
        TriggerClientEvent(CP.e('client:volunteerMenu'), src, MenuOf(src, info))
    end,
    join = function(src, data)
        local ok, res, untilAt = V.join(src, type(data) == 'table' and data.roles or nil)
        if not ok then return Refused(src, res, untilAt) end
        Note(src, 'success', 'volunteer.started', { minutes = math.floor(WindowSeconds() / 60) })
    end,
    renew = function(src)
        local ok, res, untilAt = V.renew(src)
        if not ok then return Refused(src, res, untilAt) end
        Note(src, 'success', 'volunteer.renewed', { minutes = math.floor(WindowSeconds() / 60) })
    end,
    roles = function(src, data)
        local ok, res = V.setRoles(src, type(data) == 'table' and data.roles or nil)
        if not ok then return Refused(src, res) end
        Note(src, 'success', 'volunteer.roles_saved')
    end,
    stop = function(src)
        local ok, res = V.stop(src)
        if not ok then return Refused(src, res) end
    end,
}

RegisterNetEvent(CP.e('server:volunteer'), function(action, data)
    local src = ToSrc(source)
    if not src then return end
    if CP.Net and CP.Net.rateOk and not CP.Net.rateOk(src, 'volunteer', 4, 2000) then return end
    local fn = type(action) == 'string' and ACTIONS[action] or nil
    if not fn then return end
    local ok, err = pcall(fn, src, data)
    if not ok then CP.err(TAG, ('volunteer action %s failed: %s'):format(action, tostring(err))) end
end)

-- ============================================================================
--                                   THE ENDS
-- ============================================================================

local function Gone(src)
    src = ToSrc(src)
    local cid = src and cidOf[src]
    if cid then End(cid, 'left') end
end

AddEventHandler('playerDropped', function() Gone(source) end)

CP.Hooks.on('settings:changed', function()
    if On() then return end
    for cid in pairs(listed) do End(cid, 'disabled') end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    listed, cidOf = {}, {}
    sweep.token = sweep.token + 1
    sweep.on = false
end)

CreateThread(function()
    Wait(0)
    local Q = CP.Qbx
    if not (Q and Q.onPlayerUnload and Q.onDutyChange and Q.onJobChange) then return end
    Q.onPlayerUnload(Gone)
    local function Duty(src, job)
        src = ToSrc(src)
        local cid = src and cidOf[src]
        if not cid then return end
        if DeptDuty(job and { job = job } or Q.getInfo(src)) then End(cid, 'on_duty') end
    end
    Q.onDutyChange(function(src, onDuty) if onDuty then Duty(src) end end)
    Q.onJobChange(function(src, job) Duty(src, type(job) == 'table' and job or nil) end)
end)
