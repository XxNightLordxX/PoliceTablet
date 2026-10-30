-- A mission a supervisor pushes to a unit (step P19, the pushMission Mission control): the paged call names that
-- mission, only the paged unit sees its name and may accept or decline it; the accept runs every rule but skips the
-- random draw. Plain stubs (no database): MySQL answers the call rows, CP.AdminKit counts today's pushes.

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

H.load('modules/deptcontrols/server.lua')
H.load('modules/draw/server.lua')
H.load('modules/missioncalls/server.lua')
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
local function Page(src, leader, missionId, area)
    return MC.page(src, 'patrol', area or 'south_ls', leader, { missionId = missionId })
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
local master = Config.Permissions.supervisor.missionControls

-- ============================================================================
--                            SHIPPED: NOTHING MOVES
-- ============================================================================

H.eq(controls.pushMission.on, false, 'pushMission ships off')
H.eq(Config.MissionControls.pushMissionPerDay, 5, 'five pushes a supervisor a day')
H.eq(CP.DeptControls.def('pushMission').kind, 'action', 'an action control (no saved value)')
H.eq(select(2, Page(9, 11, 'pm_patrol_a')), 'err.no_permission', 'shipped: a supervisor can not push')
H.eq(select(2, Page(99, 11, 'pm_patrol_a')), 'err.control_off', 'shipped: nor can an admin')
H.eq(#audits, 0, 'nothing posted')
local okR = Page(9, 11, nil)
H.eq(okR, true, 'a page without a mission works as today')
H.eq(audits[#audits].action, 'mcPage', 'audited as a page')
H.eq(MC.supView(9).push, nil, 'the Page dialog offers no mission while the control is off')

-- ============================================================================
--                                 ON: THE PUSH
-- ============================================================================

Config.Permissions.supervisor.missionControls = true
controls.pushMission.on = true
MC._reset()
MC._setNextPost(H.time + 10 ^ 9)   -- no server calls in this spec
audits = {}
H.events = {}
H.ok(MC.supView(9).push ~= nil and #MC.supView(9).push.missions == 4, 'the Page dialog lists the missions')
H.eq(select(2, Page(9, 10, 'pm_patrol_a')), 'err.mc_page_self', 'never the issuer\'s own unit')
H.eq(select(2, Page(9, 21, 'pm_patrol_a')), 'err.mc_push_department', 'a supervisor: his own department only')
H.eq(select(2, Page(9, 11, 'pm_inv_a')), 'err.mc_push_type', 'the mission is of the call\'s type')
H.eq(select(2, Page(9, 11, 'pm_patrol_c', 'downtown')), 'err.mc_push_size', 'every accept rule: the unit size')
H.eq(select(2, Page(9, 11, 'pm_patrol_b', 'downtown')), 'err.mc_push_area', 'a start in the named area')
cooldowns.PM011 = { types = {}, missions = { pm_patrol_a = os.time() + 600 } }
H.eq(select(2, Page(9, 11, 'pm_patrol_a')), 'err.pool_cooldown', 'a member\'s mission cooldown stays')
cooldowns.PM011 = nil
H.eq(#audits, 0, 'nothing refused was posted')

local ok, data = Page(9, 11, 'pm_patrol_a')
H.eq(ok, true, 'pushed pm_patrol_a to the unit of 11')
local call = MC._calls()[data.id]
H.eq(call.missionId, 'pm_patrol_a', 'the call names the mission')
local au = Find(audits, function(a) return a.action == 'mcPush' end)
H.ok(au and au.old == 'pm_patrol_a' and au.category == 'operations', 'the audit names the mission')
local t11 = Toasts(11)
H.ok(#t11 == 1 and t11[1].pushed == true and t11[1].missionLabel == 'Label pm_patrol_a',
    'the paged unit is told the mission')
H.eq(#Toasts(13), 0, 'nobody else gets a toast')
local c11 = CardOf(11, call.id)
H.ok(c11 and c11.pushed and c11.missionLabel == 'Label pm_patrol_a' and c11.status == 'ready',
    'the paged unit sees the mission on Dispatch')
H.eq(CardOf(13, call.id), nil, 'other officers never see the call')
local sv = MC.supView(9)
local sc = Find(sv.open, function(c) return c.id == call.id end)
H.ok(sc and sc.pushed and sc.missionLabel == nil, 'staff see a pushed call, not the mission name')
H.time = H.time + 60
MC._tick()
H.eq(#Toasts(13), 0, 'after the page time it is still the paged unit\'s alone')
H.eq(select(2, MC.claim(13, call.id)), 'err.mc_paged', 'another unit can not claim it')
local okC, res = MC.claim(11, call.id)
H.eq(okC, true, 'the paged unit accepts')
H.ok(res and res.runId ~= nil, 'a run started')
local last = created[#created]
H.eq(last.mission.id, 'pm_patrol_a', 'the pushed mission, not a draw')
H.eq(last.missionCall.staff, true, 'a staff call: never rapid response')

-- ============================================================================
--                           DECLINE, PER DAY, ADMINS
-- ============================================================================

local _, d2 = Page(9, 13, 'pm_patrol_b')
H.eq(select(2, MC.decline(11, d2.id)), 'err.mc_paged', 'only the paged unit may decline')
H.eq(MC.decline(13, d2.id), true, 'the unit declines')
H.eq(MC._calls()[d2.id], nil, 'a declined push ends')
H.ok(Find(notes, function(n)
    return n.src == 9 and n.key == 'mc.toast.push_declined'
end) ~= nil, 'the supervisor is told')
Config.MissionControls.pushMissionPerDay = 2
H.eq(select(2, Page(9, 13, 'pm_patrol_b')), 'err.mc_push_used', 'pushMissionPerDay a supervisor a day')
H.eq((Page(99, 13, 'pm_patrol_b')), true, 'admins any')
H.eq(MC.supView(9).push.usedToday, 2, 'the dialog shows today\'s pushes')
Config.MissionControls.pushMissionPerDay = 5
Config.Permissions.supervisor.missionControls = master
controls.pushMission.on = false

return H
