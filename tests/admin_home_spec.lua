-- Admin UI -> Home's Needs attention panel (step H5): admin:getNeedsAttention answers the Problems lines, today's

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/adminkit, modules/adminhome. Stand-in: CP.Access, CP.Permissions, CP.Qbx, CP.Schedule,
-- CP.Disputes, CP.Admin, CP.Opponents (each answers what the spec sets below).

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local admins = { [1] = true }
local keys = { antiFarmOverride = true }
CP.Access = {
    isAdmin = function(src) return admins[src] == true end,
}
CP.Permissions = {
    can = function(src, key)
        if not admins[src] then return false, 'err.no_permission' end
        if key == 'openAdmin' then return true end
        return keys[key] == true
    end,
    probe = function() end,
}
CP.Qbx = {
    getInfo = function(src) return src == 1 and { citizenid = 'ADM00001' } or nil end,
}
local DAY = 1700000000
CP.Schedule = {
    now = function() return DAY + 3600 end,
    dayStart = function() return DAY end,
}
local openDisputes = 2
CP.Disputes = {
    openCount = function() return openDisputes end,
}
local flaggedAsked
CP.Admin = {
    -- the real count (Admin.flaggedCount), never the capped queue rows (Admin.flaggedRows stops at 200)
    flaggedRows = function() return { { rowId = 1, runUuid = 'run-a' } } end,
    flaggedCount = function(cid)
        flaggedAsked = { cid = cid }
        return 250
    end,
}
CP.Opponents = {
    cases = function() return { { open = true }, { open = false }, { open = true } } end,
}

H.load('modules/adminkit/server.lua')
H.load('modules/adminhome/server.lua')

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 6000
    local r = H.callback('crimson-police:' .. name, src, args or {})
    if type(r) ~= 'table' then return nil, 'no reply' end
    if r.ok then return r.data end
    return nil, r.error
end

-- ============================================================================
--                                    STEPS
-- ============================================================================

do -- needsAttention ships off: the request is refused
    H.eq(Config.AdminUi.needsAttention, false, 'shipped false')
    local data, err = Cb('admin:getNeedsAttention', 1)
    H.ok(data == nil and err == 'err.needs_attention_off', 'off: err.needs_attention_off')
end

do -- one request answers every line
    Config.AdminUi.needsAttention = true
    Config.LiveCrime = Config.LiveCrime or {}
    local liveWas = Config.LiveCrime.enabled
    Config.LiveCrime.enabled = true
    CP.warn('adminhome_spec', 'a problem line')
    CP.Refusals.note({ citizenid = 'CIDREF', name = 'Ref Used', missionId = 'patrol_a', reason = 'err.in_arena' })
    local data = Cb('admin:getNeedsAttention', 1)
    H.ok(data ~= nil, 'an admin reads the panel')
    H.eq(data.problems, CP.Problems.total(), 'Problems: the lines since the start')
    H.ok(data.problems >= 1, 'the problem line counts')
    H.ok(data.refusedToday >= 1, 'a refused start of today counts')
    H.eq(data.disputes, 2, 'the open disputes')
    H.eq(data.flagged, 250, 'flagged: the full count, past the 200 rows the queue card shows')
    H.eq(flaggedAsked.cid, 'ADM00001', 'flagged: the admin\'s own runs left out')
    H.eq(data.rsCases, 2, 'the open player suspect cases only')

    -- no Player suspects screen: no such line
    keys.antiFarmOverride = false
    H.eq(Cb('admin:getNeedsAttention', 1).rsCases, nil, 'no antiFarmOverride key: no player suspects line')
    keys.antiFarmOverride = true
    Config.LiveCrime.enabled = false
    local volWas = type(Config.Volunteers) == 'table' and Config.Volunteers.enabled
    if type(Config.Volunteers) == 'table' then Config.Volunteers.enabled = false end
    H.eq(Cb('admin:getNeedsAttention', 1).rsCases, nil, 'live crimes and volunteers off: no player suspects line')
    if type(Config.Volunteers) == 'table' then Config.Volunteers.enabled = volWas end
    Config.LiveCrime.enabled = liveWas

    -- a module that fails counts 0, the others still answer
    CP.Disputes.openCount = function() error('boom') end
    local again = Cb('admin:getNeedsAttention', 1)
    H.ok(again ~= nil and again.disputes == 0 and again.flagged == 250, 'a failing count is 0, the rest answers')
    CP.Disputes.openCount = function() return openDisputes end
end

do -- anyone but an admin is refused
    local data, err = Cb('admin:getNeedsAttention', 7)
    H.ok(data == nil and err == 'err.no_permission', 'an officer is refused')
    Config.AdminUi.needsAttention = false
end

return H
