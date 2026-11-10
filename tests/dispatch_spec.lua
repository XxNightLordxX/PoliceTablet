-- The one dispatch flow: every kind of call on one list, one answer and one staff post (modules/dispatch).

-- Every kind of call (the server's random calls, a department's lane, a staff call posted to everyone, a call paged
-- to one unit, a mission pushed to one unit) is a call on the one list of CP.MissionCalls; officers answer every kind
-- through server:answerMissionCall (claim or decline) and staff post every kind through server:<sup|admin>:mcPost.
-- Each kind keeps its own rules: checkEvery, laneMaxOpen and pushPerDay in Config.MissionCalls, the departments of
-- the pushMission control, the claim checks. The old routes and the old MissionControls keys are gone; calls, alerts
-- and missioncalls live in modules/dispatch. Plain stubs, the real deptcontrols, draw and dispatch modules. No
-- database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local rowId = 0
MySQL.insert.await = function()
    rowId = rowId + 1
    return rowId
end
MySQL.update.await = function() return 1 end
MySQL.scalar.await = function() return 0 end
MySQL.query.await = function() return {} end
MySQL.single.await = function() return nil end
CP.Migrations = {
    ready = function() return true end,
}
CP.Schedule = {
    dayKey = function(ts) return os.date('!%Y-%m-%d', ts or os.time()) end,
    dayStart = function(ts)
        ts = ts or os.time()
        return ts - ts % 86400
    end,
}

local players, units, audits, notes, created = {}, {}, {}, {}, {}
local cooldowns = {}
local function AddPlayer(src, coords, t)
    t = t or {}
    players[src] = { cid = t.cid or ('PM%03d'):format(src), dept = t.dept or 'sast', sup = t.sup }
    H.players[src] = { coords = coords }
end

CP.Access = {
    getOfficer = function(src)
        local p = players[src]
        if not p then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.cid,
            name = 'Officer ' .. src,
            callsign = ('2L-%02d'):format(src),
            department = p.dept,
            departmentShort = p.dept:upper(),
            isSupervisor = p.sup == true,
        }
    end,
    isAdmin = function(src) return src == 0 or src == 99 end,
}
CP.Qbx = {
    getInfo = function(src) return players[src] and { citizenid = players[src].cid } or nil end,
}
local function UnitOfSrc(src)
    for _, u in ipairs(units) do
        for _, m in ipairs(u.members) do if m == src then return u end end
    end
    return nil
end
CP.Units = {
    unitOf = UnitOfSrc,
    members = function(src)
        local u = UnitOfSrc(src)
        return u and u.members or { src }
    end,
    isLeader = function(src)
        local u = UnitOfSrc(src)
        return u ~= nil and u.leader == src
    end,
    lock = function(u) u.locked = true end,
    unlock = function(u) u.locked = false end,
}
CP.Runs = {
    isOnMission = function() return false end,
    getBySrc = function() return nil end,
    capsOk = function() return true end,
    cooldowns = function(cid) return cooldowns[cid] or { types = {}, missions = {} } end,
    completionsLastHour = function() return 0 end,
    completionsToday = function() return 0 end,
    create = function(opts)
        created[#created + 1] = opts
        return { id = ('pm-run-%d'):format(#created), participants = {} }
    end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars)
        notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
        return true
    end,
    push = function() return true end,
}
CP.Permissions = {
    can = function(src, action)
        if src == 0 or src == 99 then return true end
        local p = players[src]
        if p and p.sup and (action == 'missionCalls' or action == 'missionControls') then
            if action == 'missionControls' and Config.Permissions.supervisor.missionControls ~= true then
                return false, 'err.no_permission'
            end
            return true
        end
        return false, 'err.no_permission'
    end,
}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = type(actor) == 'number' and players[actor] and players[actor].cid or actor,
            role = role,
            category = category,
            action = action,
            target = target,
            old = old,
            new = new,
            reason = reason,
        }
    end,
}
CP.AdminKit = {
    callback = function() return true end,
    dailyCount = function(action, opts)
        local n = 0
        for _, a in ipairs(audits) do
            if a.action == action and (opts.actor == nil or a.actor == opts.actor) then n = n + 1 end
        end
        return n
    end,
}
CP.Events = {
    typeOfTheDay = function() return nil end,
}
CP.Cash = {
    range = function() return 250, 310 end,
}
CP.Operations = {
    isLocked = function() return false end,
}

-- two patrol missions in South LS, one in Downtown (a patrol for 1-2 officers each)
local CENTRE = {}
for _, a in ipairs(Config.MissionCalls.areas) do CENTRE[a.key] = a.center end
local function Loc(area, dx)
    local c = CENTRE[area]
    return { label = area .. dx, start = { coords = vec3(c.x + dx, c.y, 30.0), radius = 40.0 } }
end
local byId, list = {}, {}
local function Def(id, mtype, max, locs)
    local d = { id = id, label = 'Label ' .. id, type = mtype, minOfficers = 1, maxOfficers = max, locations = locs }
    byId[id], list[#list + 1] = d, d
end
Def('pm_patrol_a', 'patrol', 2, { Loc('south_ls', 0), Loc('south_ls', 300) })
Def('pm_patrol_b', 'patrol', 2, { Loc('south_ls', 600), Loc('south_ls', 900) })
Def('pm_patrol_c', 'patrol', 1, { Loc('downtown', 0) })
Def('pm_inv_a', 'investigation', 2, { Loc('south_ls', 1200) })
CP.Missions = {
    byType = function(t)
        local out = {}
        for _, d in ipairs(list) do if d.type == t then out[#out + 1] = d end end
        return out
    end,
    get = function(id) return byId[id] end,
    isEnabled = function(id) return byId[id] ~= nil end,
}

H.load('modules/supervisor/deptcontrols.lua')
H.load('modules/runs/draw.lua')
H.load('modules/dispatch/missioncalls.lua')
local MC = CP.MissionCalls
MC._setNextPost(H.time + 10 ^ 9)
Config.MissionCalls.claimWindowMs = 0

local function Find(t, pred)
    for _, v in ipairs(t) do if pred(v) then return v end end
    return nil
end
local function Toasts(src)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == 'crimson-police:client:missionCall' and e.target == src then out[#out + 1] = e.args[1] end
    end
    return out
end
local function CardOf(src, id)
    local v = MC.list(src)
    return v and Find(v.calls, function(c) return c.id == id end)
end

local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    local rid = ('fm7-%d'):format(#H.events + 1)
    H.fire('crimson-police:' .. name, src, payload, rid)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == rid then return e.args[2], e.args[3] end
    end
    return nil, 'no answer'
end
local function Read(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local S = CENTRE.south_ls
AddPlayer(9, vec3(S.x, S.y, 30.0), { sup = true })    -- the SAST supervisor
AddPlayer(10, vec3(S.x, S.y, 30.0))                   -- in his unit
AddPlayer(11, vec3(S.x + 50, S.y, 30.0))              -- another SAST unit's leader
AddPlayer(12, vec3(S.x + 60, S.y, 30.0))
AddPlayer(13, vec3(S.x + 70, S.y, 30.0))              -- a solo SAST officer
AddPlayer(21, vec3(S.x + 80, S.y, 30.0), { dept = 'fib' })
units = { { id = 1, leader = 10, members = { 10, 9 } }, { id = 2, leader = 11, members = { 11, 12 } } }
local controls = Config.MissionControls.controls

-- ============================================================================
--                        ONE MODULE, ONE CONFIG SECTION
-- ============================================================================

local ROOT = H.root .. '/'
for _, part in ipairs({ 'calls', 'alerts', 'missioncalls' }) do
    H.ok(Read(ROOT .. 'modules/dispatch/' .. part .. '.lua') ~= nil, 'modules/dispatch/' .. part .. '.lua')
    H.eq(Read(ROOT .. 'modules/' .. part .. '/server.lua'), nil, 'modules/' .. part .. '/server.lua is gone')
end
H.ok(Read(ROOT .. 'modules/dispatch/client/missioncalls.lua') ~= nil, 'the client part in modules/dispatch/client')
H.eq(Read(ROOT .. 'modules/missioncalls/client.lua'), nil, 'modules/missioncalls/client.lua is gone')
local manifest = Read(ROOT .. 'fxmanifest.lua')
H.ok(manifest:find('\'modules/dispatch/*.lua\'', 1, true) ~= nil, 'the manifest loads the server parts')
H.ok(manifest:find('\'modules/dispatch/client/*.lua\'', 1, true) ~= nil, 'and the client part')
local mcSrc = Read(ROOT .. 'modules/dispatch/missioncalls.lua')
H.eq(mcSrc:find('local function Num(', 1, true), nil, 'no private Num copy (CP.Num)')

H.eq(Config.MissionCalls.laneMaxOpen, 2, 'the lane open-at-once cap ships 2, in MissionCalls')
H.eq(Config.MissionCalls.pushPerDay, 5, 'pushes a supervisor a day ship 5, in MissionCalls')
H.eq(Config.MissionControls.callLaneMaxOpen, nil, 'MissionControls.callLaneMaxOpen is gone')
H.eq(Config.MissionControls.pushMissionPerDay, nil, 'MissionControls.pushMissionPerDay is gone')
H.eq(Config.MissionCalls.checkEvery, 10, 'the server still checks every 10 s')
local cfgText = Read(ROOT .. 'config/config.lua')
H.ok(cfgText:find('all on one Dispatch list', 1, true) ~= nil, 'the section comment names the one list')

-- the old routes are gone, the merged ones registered
for _, old in ipairs({
    'server:claimMissionCall',
    'server:declineMissionCall',
    'server:mcWatch',
    'server:sup:mcCreate',
    'server:sup:mcPage',
    'server:admin:mcCreate',
    'server:admin:mcPage',
}) do
    H.eq(H.handlers['crimson-police:' .. old], nil, old .. ' is gone')
end
for _, new in ipairs({ 'server:answerMissionCall', 'server:sup:mcPost', 'server:admin:mcPost', 'server:sup:mcWithdraw' }) do
    H.ok(H.handlers['crimson-police:' .. new] ~= nil, new .. ' is registered')
end

-- ============================================================================
--                EACH OLD KIND THROUGH THE ONE POST AND ANSWER
-- ============================================================================

-- a staff call to everyone (was mcCreate)
local ok, data = Act('server:sup:mcPost', 9, { type = 'patrol', area = 'south_ls' })
H.eq(ok, true, 'mcPost without a unit posts an open call')
local open = MC._calls()[data.id]
H.ok(open and open.staff == true and open.pagedCid == nil and open.missionId == nil, 'an open staff call')
H.eq(audits[#audits].action, 'mcCreate', 'audited as before (mcCreate)')
H.ok(type(data.view) == 'table', 'the reply carries the panel view')
H.ok(CardOf(13, open.id) ~= nil and CardOf(11, open.id) ~= nil, 'every unit sees it on the one list')
H.eq((select(2, Act('server:sup:mcPost', 9, { type = 'patrol' }))), 'err.mc_staff_cooldown',
    'the wait between staff calls stays')
H.eq((select(2, Act('server:admin:mcPost', 99, { type = 'patrol', skipWait = true }))), 'err.reason_required',
    'Post anyway still needs a reason')

-- answer = claim on that call (was claimMissionCall)
local okC, res = Act('server:answerMissionCall', 13, { callId = open.id, answer = 'claim' })
H.eq(okC, true, 'answer claim takes the open call')
H.ok(res and res.runId ~= nil, 'and starts a run')
H.eq(created[#created].missionCall.staff, true, 'a staff call: never rapid response')
H.eq((select(2, Act('server:answerMissionCall', 11, { callId = open.id, answer = 'maybe' }))), 'err.invalid_payload',
    'an unknown answer is refused')

-- a page to one unit (was mcPage)
H.time = H.time + 600
ok, data = Act('server:sup:mcPost', 9, { type = 'patrol', area = 'south_ls', leaderSrc = 11 })
H.eq(ok, true, 'mcPost with a unit pages it')
local paged = MC._calls()[data.id]
H.eq(paged.pagedCid, 'PM011', 'paged to the unit of 11')
H.eq(audits[#audits].action, 'mcPage', 'audited as before (mcPage)')
H.eq((select(2, Act('server:answerMissionCall', 11, { callId = paged.id, answer = 'decline' }))), 'err.mc_not_open',
    'decline is only for a pushed mission')
H.eq((select(2, Act('server:sup:mcPost', 9, { type = 'patrol', missionId = 'pm_patrol_a' }))), 'err.mc_page_target',
    'a mission needs a unit to push it to')

-- a pushed mission (was mcPage with missionId), declined through the one answer (was declineMissionCall)
H.eq((select(2, Act('server:sup:mcPost', 9, { type = 'patrol', leaderSrc = 13, missionId = 'pm_patrol_a' }))),
    'err.no_permission', 'shipped: the pushMission control is off')
Config.Permissions.supervisor.missionControls = true
controls.pushMission.on = true
H.eq((select(2, Act('server:sup:mcPost', 9, { type = 'patrol', leaderSrc = 21, missionId = 'pm_patrol_a' }))),
    'err.mc_push_department', 'his own department only')
ok, data = Act('server:sup:mcPost', 9,
    { type = 'patrol', area = 'south_ls', leaderSrc = 13, missionId = 'pm_patrol_b' })
H.eq(ok, true, 'mcPost with a unit and a mission pushes it')
local pushed = MC._calls()[data.id]
H.eq(pushed.missionId, 'pm_patrol_b', 'the call names the mission')
H.eq(audits[#audits].action, 'mcPush', 'audited as before (mcPush)')
H.eq((select(2, Act('server:answerMissionCall', 11, { callId = pushed.id, answer = 'decline' }))), 'err.mc_paged',
    'only the pushed unit declines')
local okD, dd = Act('server:answerMissionCall', 13, { callId = pushed.id, answer = 'decline' })
H.eq(okD, true, 'answer decline ends the pushed call')
H.ok(dd and type(dd.view) == 'table', 'with the fresh Dispatch view')
H.eq(MC._calls()[pushed.id], nil, 'the declined call is gone')

-- pushPerDay is read from Config.MissionCalls
Config.MissionCalls.pushPerDay = 1
H.eq((select(2, Act('server:sup:mcPost', 9, { type = 'patrol', leaderSrc = 13, missionId = 'pm_patrol_a' }))),
    'err.mc_push_used', 'MissionCalls.pushPerDay caps the pushes')
Config.MissionCalls.pushPerDay = 5
H.eq(MC.supView(9).push.perDay, 5, 'the dialog shows the per-day cap')
controls.pushMission.on = false

-- the lane's open-at-once cap is read from Config.MissionCalls
local b = { min = 120, max = 600 }
local lane3 = { spawnEvery = { 120, 240 }, maxOpen = 3, types = { patrol = 1 } }
H.eq(MC._cleanLane(lane3, b, true), nil, 'laneMaxOpen 2: a lane of 3 open is refused')
Config.MissionCalls.laneMaxOpen = 3
H.ok(MC._cleanLane(lane3, b, true) ~= nil, 'laneMaxOpen 3: allowed')
Config.MissionCalls.laneMaxOpen = 2

-- the server's own random calls land on the same list and are claimed the same way
MC._reset()
units = {}
MC._setNextPost(0)
H.time = H.time + 600
MC._tick()
local random
for _, c in pairs(MC._calls()) do if not c.staff then random = c end end
H.ok(random ~= nil, 'the server posts its own call (checkEvery)')
if random then
    local okR = Act('server:answerMissionCall', 11, { callId = random.id })
    H.eq(okR, true, 'and it is claimed through the same answer (claim is the default answer)')
end

return H
