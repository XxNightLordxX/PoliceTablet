-- Admin UI -> Home, the dashboard: admin:getHome answers everything Home shows in one request: live now (officers on

-- Admin UI -> Home, the dashboard: admin:getHome answers everything Home shows in one request: live now (officers on
-- duty by department, the runs going for an admin with the liveRuns key), the queues (flagged runs, one per run with
-- the admin's own left out, profiles, open disputes, stuck payments, open player suspect cases only with the Player
-- suspects screen), the alerts (Problems lines, today's refused starts, Config health, the last mission load) and
-- the shortcuts of Config.AdminUi.homeShortcuts (shipped: today's five tiles); refused for anyone but an admin.

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/adminkit, modules/adminhome. Stand-in: CP.Access, CP.Permissions, CP.Qbx, CP.Schedule,
-- CP.Disputes, CP.Admin, CP.Opponents, CP.Profile, CP.Payments, CP.LiveCtl, CP.ConfigHealth, CP.Missions (each answers
-- what the spec sets below).

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local admins = { [1] = true }
local keys = { antiFarmOverride = true, liveRuns = true }
CP.Access = {
    isAdmin = function(src) return admins[src] == true end,
    departments = function()
        return { { key = 'lspd', label = 'Los Santos PD', short = 'LSPD' }, { key = 'bcso', label = 'BCSO' } }
    end,
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
    onDutyCounts = function() return { lspd = 3, ghost = 9 } end,
}
CP.Profile = {
    reviewCount = function() return 4 end,
}
CP.Payments = {
    stuckCount = function() return 1 end,
}
local runs = {}
for i = 1, 8 do
    runs[i] = {
        runId = 'run-' .. i,
        missionLabel = 'Patrol ' .. i,
        test = i == 2,
        participants = { { status = 'active' }, { status = 'left' }, { status = 'active' } },
    }
end
local liveAsked
CP.LiveCtl = {
    liveRuns = function(src)
        liveAsked = src
        return runs
    end,
}
local healthRuns = 0
CP.ConfigHealth = {
    run = function()
        healthRuns = healthRuns + 1
        return { { level = 'ok' }, { level = 'warn' }, { level = 'error' }, { level = 'warn' } }
    end,
}
CP.Missions = {
    loadSummary = function() return { loaded = 40, failed = { { id = 'a' } }, overrideFailed = { { id = 'b' } } } end,
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

do -- the shortcuts ship as today's five tiles; the panel has no switch
    H.eq(Config.AdminUi.needsAttention, nil, 'no needsAttention switch')
    H.eq(table.concat(Config.AdminUi.homeShortcuts, ','), 'newMission,missionSwitch,pay,points,settings',
        'homeShortcuts ships the five tiles Home had')
    H.eq(table.concat(CP.AdminHome.SHORTCUTS, ','), 'newMission,missionSwitch,pay,points,settings,live,review,activity',
        'every shortcut a city may pick')
    H.ok(not pcall(Cb, 'admin:getNeedsAttention', 1), 'the old Needs attention request is gone (one Home request)')
end

do -- one request answers the whole dashboard
    Config.RealPlayers.liveCrime = Config.RealPlayers.liveCrime or {}
    local liveWas = Config.RealPlayers.liveCrime.enabled
    Config.RealPlayers.liveCrime.enabled = true
    CP.warn('adminhome_spec', 'a problem line')
    CP.Refusals.note({ citizenid = 'CIDREF', name = 'Ref Used', missionId = 'patrol_a', reason = 'err.in_arena' })
    local data = Cb('admin:getHome', 1)
    H.ok(data ~= nil, 'an admin reads Home')
    -- live now
    H.eq(data.live.onDuty, 3, 'officers on duty: the departments\' counts only')
    H.eq(#data.live.departments, 2, 'one line per department')
    H.ok(data.live.departments[1].label == 'LSPD' and data.live.departments[2].n == 0, 'the short name, 0 counts')
    H.eq(data.live.runs.n, 8, 'every run going counts')
    H.eq(#data.live.runs.rows, 6, 'the first six runs as chips')
    H.eq(liveAsked, 1, 'the Live screen\'s own list, for this admin')
    H.ok(data.live.runs.rows[1].people == 2 and data.live.runs.rows[2].test == true, 'people on it, a test run')
    -- the queues
    H.eq(data.queues.flagged, 250, 'flagged: the full count, past the 200 rows the queue card shows')
    H.eq(flaggedAsked.cid, 'ADM00001', 'flagged: the admin\'s own runs left out')
    H.eq(data.queues.profiles, 4, 'profiles waiting for review')
    H.eq(data.queues.disputes, 2, 'the open disputes')
    H.eq(data.queues.payments, 1, 'stuck payments')
    H.eq(data.queues.rsCases, 2, 'the open player suspect cases only')
    -- the alerts
    H.eq(data.alerts.problems, CP.Problems.total(), 'Problems: the lines since the start')
    H.ok(data.alerts.problems >= 1, 'the problem line counts')
    H.ok(data.alerts.refusedToday >= 1, 'a refused start of today counts')
    H.ok(data.alerts.health.warn == 2 and data.alerts.health.error == 1, 'Config health: warnings and errors')
    H.ok(data.alerts.load.loaded == 40 and data.alerts.load.refused == 2, 'the last load: loaded and refused')
    H.eq(data.alerts.load.error, false, 'the last load had no error')
    H.eq(table.concat(data.shortcuts, ','), 'newMission,missionSwitch,pay,points,settings', 'the shipped shortcuts')

    -- Config health runs at most every 30 seconds for Home (pushes refresh it often)
    local before = healthRuns
    Cb('admin:getHome', 1)
    H.eq(healthRuns, before, 'Config health is not run again within 30 s')

    -- no Player suspects screen: no such line
    keys.antiFarmOverride = false
    H.eq(Cb('admin:getHome', 1).queues.rsCases, nil, 'no antiFarmOverride key: no player suspects line')
    keys.antiFarmOverride = true
    Config.RealPlayers.liveCrime.enabled = false
    local volWas = type(Config.RealPlayers.volunteer) == 'table' and Config.RealPlayers.volunteer.enabled
    if type(Config.RealPlayers.volunteer) == 'table' then Config.RealPlayers.volunteer.enabled = false end
    H.eq(Cb('admin:getHome', 1).queues.rsCases, nil, 'live crimes and volunteers off: no player suspects line')
    if type(Config.RealPlayers.volunteer) == 'table' then Config.RealPlayers.volunteer.enabled = volWas end
    Config.RealPlayers.liveCrime.enabled = liveWas

    -- no liveRuns key: no runs
    keys.liveRuns = false
    H.eq(Cb('admin:getHome', 1).live.runs, nil, 'no liveRuns key: Home shows no runs')
    keys.liveRuns = true

    -- a module that fails counts 0, the others still answer
    CP.Disputes.openCount = function() error('boom') end
    local again = Cb('admin:getHome', 1)
    H.ok(again ~= nil and again.queues.disputes == 0 and again.queues.flagged == 250, 'a failing count is 0')
    CP.Disputes.openCount = function() return openDisputes end
end

do -- Config.AdminUi.homeShortcuts: the known keys in its order, each once; {} = none; nil = the shipped five
    local was = Config.AdminUi.homeShortcuts
    Config.AdminUi.homeShortcuts = { 'review', 'pay', 'review', 'nope', 'activity' }
    H.eq(table.concat(Cb('admin:getHome', 1).shortcuts, ','), 'review,pay,activity', 'the order given, each once')
    Config.AdminUi.homeShortcuts = {}
    H.eq(#Cb('admin:getHome', 1).shortcuts, 0, '{} = no shortcuts')
    Config.AdminUi.homeShortcuts = nil
    H.eq(#Cb('admin:getHome', 1).shortcuts, 5, 'unset: the shipped five')
    Config.AdminUi.homeShortcuts = was
end

do -- anyone but an admin is refused
    local data, err = Cb('admin:getHome', 7)
    H.ok(data == nil and err == 'err.no_permission', 'an officer is refused')
end

return H
