-- CP.AdminHome (server): Admin UI -> Home's "Needs attention" panel in one batched callback
-- (admin:getNeedsAttention): the Problems lines, today's refused mission starts, the open disputes, the flagged runs
-- waiting for a review and the open real-suspect cases. Config.AdminUi.needsAttention (shipped false = no panel).

CP.AdminHome = CP.AdminHome or {}
local AH = CP.AdminHome
local TAG = 'adminhome'

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false, nil end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

-- A whole count of at least 0 (anything else = 0).
local function Count(ok, v)
    local n = ok and tonumber(v) or nil
    if not n or n ~= n or n < 0 or n == math.huge then return 0 end
    return math.floor(n)
end

function AH.enabled()
    return type(Config.AdminUi) == 'table' and Config.AdminUi.needsAttention == true
end

-- The refused mission starts on the server's day (CP.Schedule, the daily reset), as Home's "Refused starts today".
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

-- The flagged runs an admin still has to approve or void (Leaderboards -> Flagged runs): one per run, the admin's
-- own runs left out as on that card. CP.Admin.flaggedCount counts them all (the card's rows stop at 200).
local function FlaggedRuns(src)
    local okI, info = Call('Qbx', 'getInfo', src)
    local cid = okI and type(info) == 'table' and type(info.citizenid) == 'string' and info.citizenid or ''
    return Count(Call('Admin', 'flaggedCount', cid))
end

-- The open real-suspect cases, or nil when the admin has no Player suspects screen (no antiFarmOverride key, or live
-- crimes and volunteers both off, or Config.RealSuspects.adminScreen = false).
local function OpenCases(src)
    local okP, can = Call('Permissions', 'can', src, 'antiFarmOverride')
    if not (okP and can == true) then return nil end
    local rs = type(Config.RealSuspects) == 'table' and Config.RealSuspects or {}
    local on = (type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true)
        or (type(Config.Volunteers) == 'table' and Config.Volunteers.enabled == true)
    if rs.adminScreen == false or not on then return nil end
    local ok, list = Call('Opponents', 'cases')
    if not ok or type(list) ~= 'table' then return 0 end
    local n = 0
    for _, c in ipairs(list) do
        if c.open == true then n = n + 1 end
    end
    return n
end

-- Everything the panel shows, for one admin (src). rsCases is nil when that line is not his to see.
function AH.needsAttention(src)
    return {
        problems = Count(Call('Problems', 'total')),
        refusedToday = RefusedToday(),
        disputes = Count(Call('Disputes', 'openCount')),
        flagged = FlaggedRuns(src),
        rsCases = OpenCases(src),
    }
end

-- ============================================================================
--                                     NET
-- ============================================================================

if CP.AdminKit and CP.AdminKit.callback then
    CP.AdminKit.callback('admin:getNeedsAttention', 'openAdmin', function(ctx)
        if not AH.enabled() then return nil, 'err.needs_attention_off' end
        return AH.needsAttention(ctx.src)
    end, { rate = 2 })
end
