-- Modules/missioncalls (WP4): posting, areas, claims and the claim window, the priority window, staff calls,
-- statuses, re-dispatch, lapses, mute, the eligibility cache and its cost, never SC-Dispatch, realCallSummary.

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_missioncalls'
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U
H.time = os.time({ year = 2026, month = 9, day = 23, hour = 15, min = 0, sec = 0 })   -- a Wednesday
local cjson = require('cjson')

local function ReadFile(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local players = {}       -- src -> { cid, name, callsign, dept, offduty, suspended }
local units = {}         -- { id, leader, members = { src }, locked }
local onRun, onCall, arena = {}, {}, {}
local cooldowns, hourly, daily = {}, {}, {}
local capBusy = {}
local notes, pushes, audits = {}, {}, {}
local runs, created = {}, {}
local opLocked = false
local subcommands = {}

local function AddPlayer(src, coords, t)
    t = t or {}
    players[src] = {
        cid = t.cid or ('MC%03d'):format(src),
        name = t.name or ('Officer ' .. src),
        callsign = t.callsign or ('2L-%02d'):format(src),
        dept = t.dept or 'sast',
        short = t.short or 'SAST',
        sup = t.sup,
    }
    H.players[src] = { coords = coords or vec3(0.0, 0.0, 0.0) }
end

local function Cid(src) return players[src].cid end

CP.Access = {
    getOfficer = function(src)
        local p = players[src]
        if not p then return nil, 'err.not_police' end
        if p.offduty then return nil, 'err.not_on_duty' end
        if p.suspended then return nil, 'err.suspended' end
        return {
            src = src,
            citizenid = p.cid,
            name = p.name,
            callsign = p.callsign,
            department = p.dept,
            departmentShort = p.short,
            job = 'police',
            rank = 'Trooper',
            isSupervisor = p.sup == true,
        }
    end,
    isAdmin = function(src) return src == 0 or src == 99 end,
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
CP.Calls = {
    isOnCall = function(src) return onCall[src] == true end,
}
CP.Alerts = {
    inArena = function(src) return arena[src] == true end,
}
CP.Runs = {
    isOnMission = function(src) return onRun[src] ~= nil end,
    getBySrc = function(src) return onRun[src] end,
    capsOk = function(t) return not capBusy[t] end,
    cooldowns = function(cid) return cooldowns[cid] or { types = {}, missions = {} } end,
    completionsLastHour = function(cid) return hourly[cid] or 0 end,
    completionsToday = function(cid, t) return daily[cid .. '|' .. tostring(t or '*')] or 0 end,
    create = function(opts)
        local run = {
            id = ('mc-run-%d'):format(#created + 1),
            mission = opts.mission,
            missionId = opts.mission.id,
            locationIndex = opts.locationIndex,
            missionType = opts.missionType,
            state = 'accepted',
            missionCall = opts.missionCall,
            participants = {},
        }
        for _, o in ipairs(opts.members) do
            run.participants[o.src] = { src = o.src, citizenid = o.citizenid, arrived = false }
        end
        created[#created + 1] = opts
        runs[run.id] = run
        return run
    end,
    get = function(id) return runs[id] end,
    all = function() return runs end,
}
CP.Cash = {
    range = function() return 250, 310 end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars)
        notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
        return true
    end,
    push = function(src, topic, data)
        pushes[#pushes + 1] = { src = src, topic = topic, data = data }
        return true
    end,
}
CP.Permissions = {
    can = function(src, action)
        if src == 0 or src == 99 then return true end
        if action == 'missionCalls' and players[src] and players[src].sup then return true end
        return false, 'err.no_permission'
    end,
}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            role = role,
            category = category,
            action = action,
            target = target,
            reason = reason,
        }
    end,
    registerSubcommand = function(name, fn, help) subcommands[name] = { fn = fn, help = help } return true end,
}
CP.Events = {
    typeOfTheDay = function() return 'patrol' end,
}
CP.Operations = {
    isLocked = function() return opLocked end,
    active = function() return opLocked and { missionLabel = 'Prison Break' } or nil end,
}

-- SC-Dispatch spy: nothing of a mission call may ever reach it.
local scdCalls = {}
H.exportsMock['sc-dispatch'] = setmetatable({}, {
    __index = function(_, k)
        return function(...) scdCalls[#scdCalls + 1] = k end
    end,
})

-- ============================================================================
--                               FIXTURE MISSIONS
-- ============================================================================
-- Locations around the area centres of Config.MissionCalls.areas, at least 250 m apart (zone clearance 200 m).

local OFF = {
    { 0, 0 },
    { 250, 0 },
    { 0, 250 },
    { -250, 0 },
    { 0, -250 },
    { 250, 250 },
    { -250, -250 },
    { 250, -250 },
    { -250, 250 },
    { 500, 0 },
    { 0, 500 },
    { -500, 0 },
    { 0, -500 },
    { 500, 250 },
    { 250, 500 },
    { -500, 250 },
}
local CENTRE = {}
for _, a in ipairs(Config.MissionCalls.areas) do CENTRE[a.key] = a.center end
local used = {}
local function Locs(spec)
    local out = {}
    for _, s in ipairs(spec) do
        local area, n = s[1], s[2]
        for _ = 1, n do
            used[area] = (used[area] or 0) + 1
            local o = OFF[used[area]]
            local c = CENTRE[area]
            out[#out + 1] = {
                label = ('%s %d'):format(area, used[area]),
                start = { coords = vec3(c.x + o[1], c.y + o[2], 30.0), radius = 40.0 },
            }
        end
    end
    return out
end
local defs, byId = {}, {}
local function Def(id, mtype, min, max, spec)
    local d = {
        id = id,
        label = 'Label ' .. id,
        type = mtype,
        minOfficers = min,
        maxOfficers = max,
        difficulty = 1,
        cooldown = 900,
        locations = Locs(spec),
        objectives = { { block = 'checkpoint_route' } },
    }
    defs[#defs + 1] = d
    byId[id] = d
end
Def('patrol_a', 'patrol', 1, 2, { { 'south_ls', 3 }, { 'downtown', 1 } })
Def('patrol_b', 'patrol', 1, 2, { { 'south_ls', 2 }, { 'downtown', 2 } })
Def('patrol_c', 'patrol', 1, 4, { { 'downtown', 3 } })
Def('inv_solo_a', 'investigation', 1, 2, { { 'vinewood', 2 }, { 'south_ls', 2 } })
Def('inv_solo_b', 'investigation', 1, 1, { { 'vinewood', 2 } })
Def('inv_team', 'investigation', 2, 4, { { 'downtown', 3 } })
Def('tac_a', 'tactical', 2, 4, { { 'south_ls', 3 } })
Def('tac_b', 'tactical', 2, 4, { { 'south_ls', 3 } })
Def('tac_c', 'tactical', 1, 4, { { 'east_ls', 2 } })
Def('train_a', 'training', 1, 4, { { 'vinewood', 1 } })
CP.Missions = {
    byType = function(t)
        local out = {}
        for _, d in ipairs(defs) do if d.type == t then out[#out + 1] = d end end
        return out
    end,
    get = function(id) return byId[id] end,
    isEnabled = function(id) return byId[id] ~= nil end,
}

-- sc-dispatch's table (read-only, MariaDB in every storage mode), empty until the realCallSummary checks
do
    local f = assert(io.open('tests/fixtures/core/mdt_dispatch.sql', 'r'))
    H.sql(f:read('a'))
    f:close()
    H.sql('DELETE FROM mdt_dispatch')
end

H.load('modules/schedule/server.lua')
H.load('modules/draw/server.lua')
H.load('modules/integrations/sc_dispatch/server.lua')
H.load('modules/missioncalls/server.lua')
local MC = CP.MissionCalls
local D = CP.Draw
H.advance(500)
MC._setRng(U.rng(12345))

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local reqN = 0
local function Fire(name, src, payload)
    reqN = reqN + 1
    local id = 'q' .. reqN
    H.fire('crimson-police:' .. name, src, payload, id)
    return id
end
local function Reply(id)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return true, e.args[2], e.args[3] end
    end
    return false
end
-- An action and its answer (claims wait for their window).
local function Act(name, src, payload, waitMs)
    H.clockMs = H.clockMs + 2000
    local id = Fire(name, src, payload)
    local waited = 0
    while not Reply(id) and waited < (waitMs or 5000) do
        H.advance(100)
        waited = waited + 100
    end
    local _, ok, data = Reply(id)
    return ok, data
end
local function Claim(src, callId) return Act('server:claimMissionCall', src, { callId = callId }) end
local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1000
    return H.callback('crimson-police:' .. name, src, args)
end

local function Reset()
    for id in pairs(runs) do CP.Draw.release(id) end
    for k in pairs(runs) do runs[k] = nil end
    for k in pairs(created) do created[k] = nil end
    MC._reset()
    MC._setRng(U.rng(777))
    MC._setNextPost(H.time + 10 ^ 9)
    units, onRun, onCall, arena, cooldowns, hourly, daily, capBusy = {}, {}, {}, {}, {}, {}, {}, {}
    notes, pushes, audits = {}, {}, {}
    opLocked = false
    H.events = {}
    for src in pairs(players) do players[src] = nil end
    for src in pairs(H.players) do H.players[src] = nil end
    CP.Units.readyCheck = nil
    Config.MissionCalls.claimWindowMs = 1500
    CP.Dispatch._resetSummary()
end

local function NewCall(typeKey, area)
    local cd = Config.MissionCalls.staffCooldown
    Config.MissionCalls.staffCooldown = 0
    local ok, data = MC.create(0, typeKey, area)
    Config.MissionCalls.staffCooldown = cd
    assert(ok, 'staff create failed: ' .. tostring(data))
    local call = MC._calls()[data.id]
    call.staff, call.issuer, call.issuerCid = false, nil, nil   -- behave like a server call
    return call
end

local function Find(list, pred)
    for _, v in ipairs(list) do if pred(v) then return v end end
    return nil
end

local function CardOf(src, callId)
    local v = MC.list(src)
    return v and Find(v.calls, function(c) return c.id == callId end), v
end

local function CallRow(id)
    return MySQL.single.await('SELECT * FROM cp_mission_calls WHERE id = ?', { id })
end

local function Toasts(src)
    local n = 0
    for _, e in ipairs(H.events) do
        if e.name == 'crimson-police:client:missionCall' and (src == nil or e.target == src) then n = n + 1 end
    end
    return n
end

-- ============================================================================
--                                   POSTING
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    for i = 1, 5 do AddPlayer(i, vec3(S.x + 20 * i, S.y, 30.0)) end
    AddPlayer(6, vec3(S.x, S.y, 30.0))
    AddPlayer(7, vec3(S.x, S.y, 30.0))
    units = { { id = 1, leader = 6, members = { 6, 7 } } }
    -- 5 solo + 1 unit = 6 idle units, minus on a run, on a call, in the arena, suspended
    onRun[1] = { id = 'x' }
    onCall[2] = true
    arena[3] = true
    players[4].suspended = true
    local idle = MC._idleUnits()
    H.eq(#idle, 2, 'idle units: solo 5 and the unit of 6 and 7 (on run, on call, in arena, suspended excluded)')
    onCall[7] = true
    H.eq(#MC._idleUnits(), 1, 'a unit with a member on a real call is not idle')
    onCall[7] = nil
    onRun[1], onCall[2], arena[3], players[4].suspended = nil, nil, nil, nil
    H.eq(#MC._idleUnits(), 6, 'six idle units')

    -- target = min(maxOpen, max(1, ceil(idle / unitsPerCall))): 6 idle -> 3
    MC._setNextPost(0)
    local posted = 0
    for _ = 1, 10 do
        MC._setNextPost(0)
        MC._tick()
    end
    for _, c in pairs(MC._calls()) do if c.status == 'open' then posted = posted + 1 end end
    H.eq(posted, 3, 'six idle units: three open calls')
    -- no duplicate type and area, Training never
    local seen = {}
    for _, c in pairs(MC._calls()) do
        local k = c.type .. '|' .. tostring(c.area)
        H.ok(not seen[k], 'no two open calls share type and area: ' .. k)
        seen[k] = true
        H.ok(c.type ~= 'training' and c.type ~= 'weekly_boss', 'never Training or the boss')
        H.ok(c.titleIdx >= 1 and c.titleIdx <= Config.MissionCalls.titles[c.type], 'title from the type\'s pool')
        H.eq(c.staff, false, 'server calls are not staff calls')
    end
    -- the spacing: one new call at most every spawnEvery
    Reset()
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    AddPlayer(3, vec3(S.x, S.y, 30.0))
    MC._setNextPost(0)
    MC._tick()
    local n1 = 0
    for _ in pairs(MC._calls()) do n1 = n1 + 1 end
    H.eq(n1, 1, 'first check posts one call')
    local oldTime = H.time
    H.time = H.time + 59
    MC._tick()
    local n2 = 0
    for _ in pairs(MC._calls()) do n2 = n2 + 1 end
    H.eq(n2, 1, 'never another within 60 s (target is 2)')
    H.time = oldTime + 151
    MC._tick()
    local n3 = 0
    for _ in pairs(MC._calls()) do n3 = n3 + 1 end
    H.eq(n3, 2, 'a second call once spawnEvery passed')
    H.time = oldTime

    -- weights: over many posts Patrol 5 : Investigation 3 : Tactical 2 (only types an idle unit could claim)
    Reset()
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    units = { { id = 1, leader = 1, members = { 1, 2 } } }
    local counts = {}
    for i = 1, 300 do
        MC._reset()
        MC._setRng(U.rng(U.hash('w' .. i)))
        MC._tick()
        for _, c in pairs(MC._calls()) do counts[c.type] = (counts[c.type] or 0) + 1 end
    end
    H.ok((counts.patrol or 0) > 120 and (counts.patrol or 0) < 180, 'patrol about half: ' .. tostring(counts.patrol))
    H.ok((counts.tactical or 0) > 35 and (counts.tactical or 0) < 85,
        'tactical about a fifth: ' .. tostring(counts.tactical))
    H.eq(counts.training, nil, 'training never called')
    -- a type at its run cap is skipped; a type no idle unit could claim is skipped
    capBusy.patrol, capBusy.investigation = true, true
    for i = 1, 30 do
        MC._reset()
        MC._setRng(U.rng(U.hash('cap' .. i)))
        MC._tick()
        for _, c in pairs(MC._calls()) do H.eq(c.type, 'tactical', 'capped types skipped') end
    end
    capBusy = {}
    units = {}
    players[2] = nil
    H.players[2] = nil
    -- a solo officer can't claim tactical (tac_c is solo-capable: 1-4) but can; cooldown on every type: nothing posted
    cooldowns[Cid(1)] = {
        types = { patrol = H.time + 999, investigation = H.time + 999, tactical = H.time + 999 },
        missions = {},
    }
    MC._reset()
    MC._tick()
    H.eq(next(MC._calls()), nil, 'no call that no idle unit could claim')
    cooldowns = {}

    -- a Cross-Department Mission: nothing posted, open calls withdrawn
    MC._reset()
    MC._tick()
    H.ok(next(MC._calls()) ~= nil, 'a call is open')
    opLocked = true
    MC._tick()
    H.eq(next(MC._calls()), nil, 'withdrawn when a Cross-Department Mission is active')
    MC._setNextPost(0)
    MC._tick()
    H.eq(next(MC._calls()), nil, 'nothing posted while it is active')
    local ok, err = MC.create(0, 'patrol', nil)
    H.eq(ok, false, 'staff create refused too')
    H.eq(err, 'err.operation_locked', 'operation lock key')
    opLocked = false
end

-- ============================================================================
--                                    AREAS
-- ============================================================================

do
    Reset()
    H.eq(MC.areaOf(vec3(CENTRE.vinewood.x + 100, CENTRE.vinewood.y, 0.0)), 'vinewood', 'nearest centre')
    AddPlayer(1, vec3(CENTRE.vinewood.x, CENTRE.vinewood.y, 30.0))
    -- solo Investigation: inv_solo_a (vinewood 2, south 2) and inv_solo_b (vinewood 2)
    local vine = NewCall('investigation', 'vinewood')
    local south = NewCall('investigation', 'south_ls')
    H.eq(MC.areaFor(1, vine), 'vinewood', 'vinewood: 2 missions, 4 locations -> named')
    H.eq(MC.areaFor(1, south), nil, 'south: only one mission for a solo officer -> county-wide')
    local card = CardOf(1, south.id)
    H.eq(card.area, nil, 'the card says county-wide')
    H.ok(card.distance ~= nil, 'county-wide: distance to the nearest eligible area')
    local cardV = CardOf(1, vine.id)
    H.eq(cardV.area.key, 'vinewood', 'named area on the card')
    H.eq(cardV.area.label, 'Vinewood', 'area label')
    H.ok(cardV.distance < 5, 'distance to the area centre (the officer stands on it)')
    H.eq(cardV.crew, 'solo', 'crew solo')

    -- property: over fixture pools, unit sizes and cooldown states, a named area always has minMissions and
    -- minLocations for the viewer, and a claimable call never draws from a pool smaller than the board's
    local minM, minL = Config.MissionCalls.minMissionsPerArea, Config.MissionCalls.minLocationsPerArea
    AddPlayer(2, vec3(0.0, 0.0, 30.0))
    AddPlayer(3, vec3(0.0, 0.0, 30.0))
    local checked = 0
    local cdStates = {
        {},
        { inv_solo_b = H.time + 900 },
        { patrol_c = H.time + 900 },
        { tac_a = H.time + 900 },
    }
    for _, size in ipairs({ 1, 2, 3 }) do
        units = {}
        if size > 1 then
            local m = { 1 }
            for i = 2, size do m[#m + 1] = i end
            units = { { id = 1, leader = 1, members = m } }
        end
        for _, cd in ipairs(cdStates) do
            cooldowns[Cid(1)] = { types = {}, missions = cd }
            MC._invalidate(nil)
            for _, typeKey in ipairs({ 'patrol', 'investigation', 'tactical' }) do
                local board = D.pool(typeKey, CP.Units.members(1))
                for _, a in ipairs(Config.MissionCalls.areas) do
                    local call = { type = typeKey, area = a.key, excluded = {}, lostBy = {} }
                    local named = MC.areaFor(1, call)
                    local areaPool = D.pool(typeKey, CP.Units.members(1), { area = a.key })
                    if named then
                        local locs = 0
                        for _, d in ipairs(areaPool) do
                            for i = 1, #d.locations do
                                if D._locationArea(d, i) == a.key then locs = locs + 1 end
                            end
                        end
                        H.ok(#areaPool >= minM, ('named %s/%s holds %d missions'):format(typeKey, a.key, #areaPool))
                        H.ok(locs >= minL, ('named %s/%s holds %d locations'):format(typeKey, a.key, locs))
                        H.ok(#areaPool >= math.min(#board, minM), 'never narrower than the board')
                    end
                    checked = checked + 1
                end
            end
        end
    end
    H.ok(checked > 200, 'property checked over ' .. checked .. ' cases')
    cooldowns, units = {}, {}

    -- admin:getAreaCoverage matches the fixture
    local cov = Cb('admin:getAreaCoverage', 99)
    H.eq(cov.ok, true, 'coverage for admins')
    H.eq(cov.data.cells.patrol.south_ls.missions, 2, 'patrol south: 2 missions')
    H.eq(cov.data.cells.patrol.south_ls.locations, 5, 'patrol south: 5 locations')
    H.eq(cov.data.cells.patrol.downtown.missions, 3, 'patrol downtown: 3 missions')
    H.eq(cov.data.cells.investigation.vinewood.locations, 4, 'investigation vinewood: 4 locations')
    H.eq(cov.data.cells.tactical.east_ls.missions, 1, 'tactical east: 1 mission')
    H.eq(cov.data.cells.training.vinewood.missions, 1, 'training vinewood')
    H.eq(Cb('admin:getAreaCoverage', 1).ok, false, 'officers refused')
end

-- ============================================================================
--                        CLAIM REFUSALS AND RATE LIMIT
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    local call = NewCall('patrol', 'south_ls')
    local cid = Cid(1)
    local cases = {
        {
            function() players[1].offduty = true end,
            function() players[1].offduty = nil end,
            'err.not_on_duty',
        },
        {
            function() units = { { id = 1, leader = 2, members = { 2, 1 } } } end,
            function() units = {} end,
            'err.not_leader',
        },
        {
            function() onRun[1] = { id = 'r' } end,
            function() onRun[1] = nil end,
            'err.already_on_run',
        },
        {
            function() onCall[1] = true end,
            function() onCall[1] = nil end,
            'err.on_call',
        },
        {
            function() arena[1] = true end,
            function() arena[1] = nil end,
            'err.in_arena',
        },
        {
            function() hourly[cid] = 99 end,
            function() hourly[cid] = nil end,
            'err.hourly_cap',
        },
        {
            function() Config.Limits.maxCompletionsDay, daily[cid .. '|*'] = 2, 2 end,
            function() Config.Limits.maxCompletionsDay, daily[cid .. '|*'] = 0, nil end,
            'err.daily_cap',
        },
        {
            function() cooldowns[cid] = { types = { patrol = H.time + 60 }, missions = {} } end,
            function() cooldowns[cid] = nil end,
            'err.type_cooldown',
        },
        {
            function() capBusy.patrol = true end,
            function() capBusy.patrol = nil end,
            'err.server_busy',
        },
        {
            function() opLocked = true end,
            function() opLocked = false end,
            'err.operation_locked',
        },
        {
            function()
                cooldowns[cid] = {
                    types = {},
                    missions = { patrol_a = H.time + 60, patrol_b = H.time + 60, patrol_c = H.time + 60 },
                }
            end,
            function() cooldowns[cid] = nil end,
            'err.mc_no_missions_here',
        },
    }
    for _, c in ipairs(cases) do
        c[1]()
        MC._invalidate(nil)
        local ok, err = Claim(1, call.id)
        H.eq(ok, false, 'refused: ' .. c[3])
        H.eq(err, c[3], 'own key: ' .. c[3])
        c[2]()
    end
    -- unit members: the member variants
    units = { { id = 1, leader = 1, members = { 1, 2 } } }
    onCall[2] = true
    local _, errM = Claim(1, call.id)
    H.eq(errM, 'err.member_on_call', 'member on a real call')
    onCall[2] = nil
    units[1].locked = true
    local _, errL = Claim(1, call.id)
    H.eq(errL, 'err.unit_locked', 'a locked unit')
    units = {}
    -- the rate limit: one claim per claimRate per player
    H.clockMs = H.clockMs + 5000
    local id1 = Fire('server:claimMissionCall', 1, { callId = 999999 })
    local id2 = Fire('server:claimMissionCall', 1, { callId = 999999 })
    H.advance(200)
    local _, ok1, e1 = Reply(id1)
    local _, ok2, e2 = Reply(id2)
    H.eq(e1, 'err.mc_gone', 'unknown call')
    H.eq(ok2, false, 'second claim within claimRate refused')
    H.eq(e2, 'err.rate_limited', 'rate limited')
    H.ok(ok1 == false, 'first answer ok=false')
end

-- ============================================================================
--                   THE CLAIM WINDOW, THE WINNER, THE LOSERS
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x + 2000, S.y, 30.0), { callsign = '2L-14' })                 -- far
    AddPlayer(2, vec3(S.x + 100, S.y, 30.0), { callsign = '2L-21', short = 'SAST' })  -- near
    local call = NewCall('patrol', 'south_ls')
    -- two claims 400 ms apart: the unit nearer the area wins
    H.clockMs = H.clockMs + 3000
    local a = Fire('server:claimMissionCall', 1, { callId = call.id })
    H.advance(400)
    local b = Fire('server:claimMissionCall', 2, { callId = call.id })
    H.advance(3000)
    local _, okA, errA = Reply(a)
    local _, okB, dataB = Reply(b)
    H.eq(okB, true, 'the nearer unit wins')
    H.ok(type(dataB) == 'table' and dataB.runId ~= nil, 'the winner gets the run')
    H.eq(okA, false, 'the first click lost')
    H.eq(errA, 'err.mc_taken_by', 'loser key')
    local toast = Find(notes, function(n) return n.src == 1 and n.key:find('mc.toast.lost_', 1, true) == 1 end)
    H.eq(toast and toast.key, 'mc.toast.lost_distance', 'the loser is told the rule: a closer unit')
    H.eq(toast.vars.callsign, '2L-21', 'with the winner\'s callsign')
    H.eq(toast.vars.department, 'SAST', 'and department')
    local card = CardOf(1, call.id)
    H.eq(card.status, 'claimed', 'claimed on the loser\'s screen')
    H.eq(card.lostBy, 'distance', 'lostBy distance')
    H.eq(card.claimedBy.callsign, '2L-21', 'claimedBy')
    -- the run: missionCall, drawn in the area, response target
    local opts = created[#created]
    H.eq(opts.missionCall.id, call.id, 'run.missionCall.id = the call row')
    H.eq(opts.missionCall.code, call.code, 'the call code')
    H.eq(opts.missionCall.area, 'south_ls', 'the named area')
    H.eq(opts.missionCall.staff, false, 'a server call earns rapid response')
    H.eq(D._locationArea(opts.mission, opts.locationIndex), 'south_ls', 'the drawn start is in the area')
    H.ok(opts.missionCall.targetS and opts.missionCall.targetS >= 45, 'a response target')
    local row = CallRow(call.id)
    H.eq(row.status, 'claimed', 'the row is claimed')
    H.eq(row.claimed_by, Cid(2), 'claimed_by the winning leader')
    H.eq(tonumber(row.claimants), 2, 'two claims in the window')
    H.eq(row.run_uuid, runs[dataB.runId].id, 'the row has the run')
    local won = Find(notes, function(n) return n.src == 2 and n.key == 'mc.toast.won' end)
    H.ok(won ~= nil and won.vars.code == call.code, 'the winner gets the confirm toast with the code')

    -- equal distance: fewer recent claims wins (officer 2 won one call this hour)
    Reset()
    AddPlayer(1, vec3(S.x + 300, S.y, 30.0))
    AddPlayer(2, vec3(S.x + 300, S.y, 30.0))
    local first = NewCall('patrol', 'south_ls')
    local okW = Claim(2, first.id)
    H.eq(okW, true, 'officer 2 wins a first call')
    onRun[2] = nil
    local second = NewCall('patrol', 'downtown')
    second.area = 'south_ls'
    H.clockMs = H.clockMs + 3000
    local c2 = Fire('server:claimMissionCall', 2, { callId = second.id })
    H.advance(300)
    local c1 = Fire('server:claimMissionCall', 1, { callId = second.id })
    H.advance(3000)
    local _, ok1 = Reply(c1)
    local _, ok2, e2 = Reply(c2)
    H.eq(ok1, true, 'equal distance: the unit with fewer recent claims wins')
    H.eq(e2, 'err.mc_taken_by', 'the busier unit loses')
    H.eq(CardOf(2, second.id).lostBy, 'recent', 'lostBy recent')

    -- claimWindowMs = 0: pure first click
    Reset()
    Config.MissionCalls.claimWindowMs = 0
    AddPlayer(1, vec3(S.x + 2000, S.y, 30.0))
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    local pure = NewCall('patrol', 'south_ls')
    H.clockMs = H.clockMs + 3000
    local p1 = Fire('server:claimMissionCall', 1, { callId = pure.id })
    local p2 = Fire('server:claimMissionCall', 2, { callId = pure.id })
    H.advance(1000)
    local _, okP1 = Reply(p1)
    local _, okP2, eP2 = Reply(p2)
    H.eq(okP1, true, 'first click wins with no window')
    H.eq(okP2, false, 'the nearer but later claim loses')
    H.eq(eP2, 'err.mc_taken_by', 'taken')
    Config.MissionCalls.claimWindowMs = 1500
end

-- ============================================================================
--                             THE PRIORITY WINDOW
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x + 100, S.y, 30.0))    -- near
    AddPlayer(2, vec3(S.x + 4000, S.y, 30.0))   -- far
    Config.MissionCalls.types.investigation.weight = 0
    Config.MissionCalls.types.tactical.weight = 0
    MC._setNextPost(0)
    -- only south_ls can be drawn for patrol with areas weighted towards the idle units; force it
    local call
    for i = 1, 40 do
        MC._reset()
        MC._setRng(U.rng(U.hash('prio' .. i)))
        MC._tick()
        local c = select(2, next(MC._calls()))
        if c and c.area == 'south_ls' then call = c break end
    end
    Config.MissionCalls.types.investigation.weight = 3
    Config.MissionCalls.types.tactical.weight = 2
    H.ok(call ~= nil, 'a south_ls patrol call was posted')
    H.ok(call.priorityUntil == H.time + 15, 'a near unit was idle: nearest units first for 15 s')
    local farCard = CardOf(2, call.id)
    H.eq(farCard.status, 'priority', 'the far unit sees Nearest units first')
    H.eq(farCard.priorityEndsIn, 15, 'with the countdown')
    local okF, errF = Claim(2, call.id)
    H.eq(okF, false, 'far unit refused during the priority window')
    H.eq(errF, 'err.mc_priority', 'priority key')
    H.eq(CardOf(1, call.id).status, 'ready', 'the near unit may claim')
    local oldTime = H.time
    H.time = H.time + 16
    local okF2 = Claim(2, call.id)
    H.eq(okF2, true, 'after 15 s the far unit may claim')
    H.time = oldTime
    -- no near unit idle at posting: no window
    Reset()
    AddPlayer(2, vec3(S.x + 4000, S.y, 30.0))
    Config.MissionCalls.types.investigation.weight = 0
    Config.MissionCalls.types.tactical.weight = 0
    MC._setNextPost(0)
    MC._tick()
    Config.MissionCalls.types.investigation.weight = 3
    Config.MissionCalls.types.tactical.weight = 2
    local c2 = select(2, next(MC._calls()))
    H.ok(c2 ~= nil and c2.priorityUntil == nil, 'nobody near at posting: no priority window')
    local okFar, errFar = Claim(2, c2.id)
    H.eq(okFar, true, 'the far unit may claim at once: ' .. tostring(errFar))
end

-- ============================================================================
--                   THE READY CHECK: CLAIMING, DECLINE, NEXT
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0), { callsign = '2L-14' })
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    AddPlayer(3, vec3(S.x + 900, S.y, 30.0), { callsign = '2L-33' })
    AddPlayer(4, vec3(S.x + 900, S.y, 30.0))
    AddPlayer(5, vec3(S.x + 1200, S.y, 30.0))
    units = { { id = 1, leader = 1, members = { 1, 2 } }, { id = 2, leader = 3, members = { 3, 4 } } }
    local checks = {}
    CP.Units.readyCheck = function(unit, typeKey, onReady, onCancel)
        checks[#checks + 1] = { unit = unit, onReady = onReady, onCancel = onCancel }
        return true
    end
    local call = NewCall('tactical', 'south_ls')
    H.clockMs = H.clockMs + 3000
    local a = Fire('server:claimMissionCall', 1, { callId = call.id })
    H.advance(200)
    local b = Fire('server:claimMissionCall', 3, { callId = call.id })
    H.advance(3000)
    local _, okA, dA = Reply(a)
    local _, okB, eB = Reply(b)
    H.eq(okA, true, 'the nearer unit won the window')
    H.eq(dA and dA.pending, true, 'its ready check runs')
    H.eq(eB, 'err.mc_taken_by', 'the other unit lost')
    H.eq(#checks, 1, 'one ready check')
    local other = CardOf(5, call.id)
    H.eq(other.status, 'claiming', 'other officers see claiming')
    H.eq(other.claiming.callsign, '2L-14', 'with the winning callsign')
    H.ok(other.claiming.expiresIn > 0, 'and the ready countdown')
    local okC, eC = Claim(5, call.id)
    H.eq(eC, 'err.mc_claiming', 'no claim while the winner confirms')
    local before = call.offerEnds
    H.time = H.time + 8
    -- declined: back to open for the time it had left, the next ranked claimant is tried
    checks[1].onCancel('err.ready_declined', { 2 })
    H.eq(call.offerEnds, before + 8, 'the offer gets back the time spent confirming')
    H.eq(#checks, 2, 'the next-ranked unit gets its ready check')
    H.eq(call.status, 'claiming', 'claiming again, for the next unit')
    H.ok(Find(notes, function(n)
        return n.src == 3 and n.key == 'mc.toast.next_in_line'
    end) ~= nil, 'the next unit is told the call is theirs')
    checks[2].onReady()
    H.eq(call.status, 'claimed', 'claimed by the next unit')
    H.eq(call.winner.callsign, '2L-33', 'the second unit won')
    H.eq(CardOf(3, call.id).lostBy, nil, 'the unit that took its turn and won is no longer shown as a loser')
    H.eq(CallRow(call.id).status, 'claimed', 'the row is claimed')
    H.eq(CallRow(call.id).claimed_by, Cid(3), 'by the second leader')
    H.ok(call.excluded[Cid(1)] and call.excluded[Cid(2)], 'the declining unit can\'t claim it again')
    H.eq(#created, 1, 'exactly one run')
    -- a decline with nobody else in the window: open again, the decliner excluded
    local call2 = NewCall('tactical', 'south_ls')
    units[2].locked = false
    onRun = {}
    local okD, dD = Claim(1, call2.id)
    H.eq(dD and dD.pending, true, 'pending')
    checks[#checks].onCancel('err.ready_declined', { 2 })
    H.eq(call2.status, 'open', 'declined and nobody else: open again')
    local _, eX = Claim(1, call2.id)
    H.eq(eX, 'err.mc_excluded', 'the declining unit is refused')
    H.eq(CallRow(call2.id).status, 'open', 'the row is open again')
    CP.Units.readyCheck = nil
end

-- ============================================================================
--                       LAPSE, RECENT, WITHDRAW, TITLES
-- ============================================================================

do
    Reset()
    AddPlayer(1, CENTRE.downtown)
    local calls = {}
    for i = 1, 7 do
        calls[i] = NewCall('patrol', nil)
        H.time = H.time + 1
    end
    H.time = H.time + 180
    MC._tick()
    H.eq(calls[1].status, 'lapsed', 'lapsed after offerTime')
    local card = CardOf(1, calls[1].id)
    H.eq(card and card.status, 'lapsed', 'shown as Lapsed')
    H.eq(CallRow(calls[1].id).status, 'lapsed', 'the row lapsed')
    H.time = H.time + 11
    MC._tick()
    H.eq(CardOf(1, calls[1].id), nil, 'removed after lapsedShown')
    local v = MC.list(1)
    H.eq(#v.recent, 5, 'Recent calls holds the last 5')
    H.eq(v.recent[1].outcome, 'lapsed', 'with the outcome')

    -- withdraw: reason required, audited (operations), removed at once
    local w = NewCall('patrol', 'downtown')
    AddPlayer(9, CENTRE.downtown, { sup = true })
    local okR, eR = Act('server:sup:mcWithdraw', 9, { callId = w.id })
    H.eq(eR, 'err.reason_required', 'a reason is required')
    local okW = Act('server:sup:mcWithdraw', 9, { callId = w.id, reason = 'duplicate' })
    H.eq(okW, true, 'withdrawn')
    H.eq(CardOf(1, w.id), nil, 'removed at once')
    H.eq(CallRow(w.id).status, 'withdrawn', 'the row')
    H.eq(CallRow(w.id).reason, 'duplicate', 'with the reason')
    local au = Find(audits, function(x) return x.action == 'mcWithdraw' end)
    H.ok(au and au.category == 'operations', 'audited in category operations')
    H.eq(Act('server:sup:mcWithdraw', 1, { callId = w.id, reason = 'x' }), false, 'officers can\'t withdraw')

    -- titles: the type's pool, never a mission name
    local part = cjson.decode(ReadFile(H.root .. 'locales/parts/missioncalls.json'))
    local labels = {}
    for _, f in ipairs(CP.U.keys({ beat_patrol = 1 })) do labels[#labels + 1] = f end
    local index = ReadFile(H.root .. 'missions/builtin/index.lua') or ''
    for id in index:gmatch('\'([%w_]+)\'') do
        local src = ReadFile(H.root .. 'missions/builtin/' .. id .. '.lua') or ''
        local label = src:match('\n%s*label%s*=%s*\'([^\']+)\'')
        if label then labels[#labels + 1] = label:lower() end
    end
    H.ok(#labels > 10, 'mission labels read: ' .. #labels)
    for typeKey, n in pairs(Config.MissionCalls.titles) do
        for i = 1, n do
            local title = part[('mc.title.%s.%d'):format(typeKey, i)]
            H.ok(type(title) == 'string' and title ~= '', ('title %s.%d exists'):format(typeKey, i))
            for _, l in ipairs(labels) do
                H.ok(not (title or ''):lower():find(l, 1, true), ('title %s.%d never names %s'):format(typeKey, i, l))
            end
        end
    end
end

-- ============================================================================
--                                 STAFF CALLS
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(9, vec3(S.x, S.y, 30.0), { sup = true })  -- the supervisor
    AddPlayer(10, vec3(S.x, S.y, 30.0))                 -- in the supervisor's unit
    AddPlayer(11, vec3(S.x, S.y, 30.0))                 -- another unit's leader
    AddPlayer(12, vec3(S.x, S.y, 30.0))
    units = { { id = 1, leader = 10, members = { 10, 9 } }, { id = 2, leader = 11, members = { 11, 12 } } }
    -- page refused for the issuer's own unit
    local okP, eP = Act('server:sup:mcPage', 9, { type = 'patrol', area = 'south_ls', leaderSrc = 10 })
    H.eq(okP, false, 'page refused for the issuer\'s unit')
    H.eq(eP, 'err.mc_page_self', 'page self key')
    local _, eL = Act('server:sup:mcPage', 9, { type = 'patrol', area = 'south_ls', leaderSrc = 12 })
    H.eq(eL, 'err.mc_page_not_leader', 'only leaders or solo officers are paged')
    local _, eT = Act('server:sup:mcPage', 9, { type = 'training', area = 'south_ls', leaderSrc = 11 })
    H.eq(eT, 'err.mc_type_not_callable', 'training is never a call')
    local okP2, dP2 = Act('server:sup:mcPage', 9, { type = 'patrol', area = 'south_ls', leaderSrc = 11 })
    H.eq(okP2, true, 'paged another unit')
    local paged = MC._calls()[dP2.id]
    H.eq(Toasts(11) + Toasts(12), 2, 'only the paged unit gets the toast')
    H.eq(Toasts(10), 0, 'nobody else')
    -- only the paged unit for pageTime, then everyone (but never the issuer's unit)
    AddPlayer(13, vec3(S.x, S.y, 30.0))
    local _, e13 = Claim(13, paged.id)
    H.eq(e13, 'err.mc_paged', 'others wait for pageTime')
    local oldTime = H.time
    H.time = H.time + 31
    local _, e10 = Claim(10, paged.id)
    H.eq(e10, 'err.mc_own_call', 'the issuer\'s unit can\'t claim it, even after pageTime')
    H.eq(CardOf(10, paged.id).status, 'locked', 'locked for the issuer\'s unit')
    -- leaving the unit to claim doesn't help: every member's citizenid is checked
    units[1] = { id = 1, leader = 10, members = { 10 } }
    units[3] = { id = 3, leader = 13, members = { 13, 9 } }
    local _, e13b = Claim(13, paged.id)
    H.eq(e13b, 'err.mc_own_call', 'a unit with the issuer in it is refused')
    units[3] = nil
    local ok13, e13c = Claim(13, paged.id)
    H.eq(ok13, true, 'after pageTime anyone else may claim: ' .. tostring(e13c))
    H.eq(created[#created].missionCall.staff, true, 'a paged call never earns rapid response')
    H.time = oldTime
    local au = Find(audits, function(x) return x.action == 'mcPage' end)
    H.ok(au and au.category == 'operations', 'page audited (operations)')

    -- create: staffCooldown per issuer, audited, the issuer's unit refused for the whole offer
    onRun = {}
    local okC, dC = Act('server:sup:mcCreate', 9, { type = 'investigation', area = 'vinewood' })
    H.eq(okC, true, 'created')
    local _, eC2 = Act('server:sup:mcCreate', 9, { type = 'patrol', area = 'downtown' })
    H.eq(eC2, 'err.mc_staff_cooldown', 'staffCooldown')
    H.time = H.time + 121
    H.eq((Act('server:sup:mcCreate', 9, { type = 'patrol', area = 'downtown' })), true, 'after the cooldown')
    local createdCall = MC._calls()[dC.id]
    H.eq(createdCall.staff, true, 'a staff call')
    units[1] = { id = 1, leader = 10, members = { 10, 9 } }
    local _, eOwn = Claim(10, createdCall.id)
    H.eq(eOwn, 'err.mc_own_call', 'the issuer\'s unit can\'t claim a created call')
    H.ok(Find(audits, function(x) return x.action == 'mcCreate' end) ~= nil, 'create audited')
    H.eq(CardOf(11, createdCall.id).rapidPoints, 0, 'no rapid response on a staff call card')
    local _, eA = Act('server:admin:mcCreate', 9, { type = 'patrol' })
    H.eq(eA, 'err.no_permission', 'admin actions need an admin')
    -- the console command
    local sub = subcommands.missioncall
    H.ok(sub ~= nil, 'the missioncall subcommand is registered')
    local okS, keyS = sub.fn(0, { 'tactical', 'east_ls' })
    H.eq(okS, true, 'console create')
    H.eq(keyS, 'admin.cmd.missioncall_done', 'reply key')
    local okS2, keyS2 = sub.fn(0, { 'patrol', 'nowhere' })
    H.eq(okS2, false, 'unknown area')
    H.eq(keyS2, 'err.mc_unknown_area', 'unknown area key')
    H.eq(sub.help, 'admin.cmd.usage_missioncall', 'help key')
    -- the supervisor view
    local sv = Cb('sup:getMissionCalls', 9)
    H.eq(sv.ok, true, 'supervisor view')
    H.ok(#sv.data.open >= 1, 'open calls listed')
    H.ok(#sv.data.today >= 3, 'today\'s calls from the database')
    H.eq(Cb('sup:getMissionCalls', 13).ok, false, 'officers refused')
end

-- After pageTime a paged call is offered to everyone: the other idle units get the toast then (once), never
-- the paged unit again or the issuer's unit. The supervisor view shows the call's own area.
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(9, vec3(S.x, S.y, 30.0), { sup = true })
    AddPlayer(10, vec3(S.x, S.y, 30.0))
    AddPlayer(11, vec3(S.x, S.y, 30.0))
    AddPlayer(12, vec3(S.x, S.y, 30.0))
    AddPlayer(13, vec3(S.x, S.y, 30.0))
    units = { { id = 1, leader = 10, members = { 10, 9 } }, { id = 2, leader = 11, members = { 11, 12 } } }
    local okP, dP = Act('server:sup:mcPage', 9, { type = 'investigation', area = 'south_ls', leaderSrc = 11 })
    H.eq(okP, true, 'paged')
    H.eq(Toasts(13), 0, 'during pageTime only the paged unit hears it')
    H.events = {}
    local oldTime = H.time
    H.time = H.time + 10
    MC._tick()
    H.eq(Toasts(13), 0, 'still inside pageTime: no toast for others')
    H.time = oldTime + 31
    MC._tick()
    H.eq(Toasts(13), 1, 'pageTime over: the other idle units get the toast')
    H.eq(Toasts(11) + Toasts(12), 0, 'the paged unit is not told twice')
    H.eq(Toasts(10) + Toasts(9), 0, 'the issuer\'s unit never')
    H.time = H.time + 10
    MC._tick()
    H.eq(Toasts(13), 1, 'only once')
    local sv = Cb('sup:getMissionCalls', 9)
    local card = Find(sv.data.open, function(c) return c.id == dP.id end)
    H.eq(card and card.area and card.area.key, 'south_ls', 'staff see the call\'s own area')
    H.eq(MC.areaFor(9, MC._calls()[dP.id]), nil, 'though as an officer in a unit of 2 it is county-wide')
    H.time = oldTime
end

-- ============================================================================
--                                 RE-DISPATCH
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x, S.y, 30.0))
    AddPlayer(3, vec3(S.x, S.y, 30.0))
    units = { { id = 1, leader = 1, members = { 1, 2 } } }
    local call = NewCall('patrol', 'south_ls')
    local ok, data = Claim(1, call.id)
    H.eq(ok, true, 'claimed: ' .. tostring(data))
    local run = runs[data.runId]
    run.state = 'ended'
    units[1].locked = false   -- the engine unlocks the unit at the run end
    CP.Hooks.fire('run:ended', run, 'abandoned', 'quit')
    H.eq(call.status, 'open', 'abandoned before arrival: reopened')
    H.eq(call.redispatched, true, 'tagged Re-dispatched')
    H.eq(call.offerEnds, H.time + 120, 'for reopen.time')
    H.eq(CardOf(3, call.id).redispatched, true, 'the card shows it')
    local _, eOld = Claim(1, call.id)
    H.eq(eOld, 'err.mc_excluded', 'the old claim\'s members are refused')
    local ok3, d3 = Claim(3, call.id)
    H.eq(ok3, true, 'another unit claims the re-dispatched call: ' .. tostring(d3))
    -- after arrival it closes with the outcome; it never reopens twice
    local run3 = runs[d3.runId]
    run3.participants[3].arrived = true
    CP.Hooks.fire('run:arrived', run3, 3, true)
    CP.Hooks.fire('run:ended', run3, 'completed', 'completed')
    H.eq(MC._calls()[call.id], nil, 'closed')
    local row = CallRow(call.id)
    H.eq(row.status, 'closed', 'the row closed')
    H.eq(row.outcome, 'completed', 'with the run\'s outcome')
    H.eq(CP.U.truthy(row.reopened), true, 'reopened recorded')
    -- a second abandonment of a re-dispatched call closes it
    local c2 = NewCall('patrol', 'south_ls')
    onRun = {}
    local _, d4 = Claim(3, c2.id)
    runs[d4.runId].state = 'ended'
    CP.Hooks.fire('run:ended', runs[d4.runId], 'abandoned', 'off_route')
    H.eq(c2.status, 'open', 'first drop: reopened')
    local _, d5 = Claim(1, c2.id)
    runs[d5.runId].state = 'ended'
    CP.Hooks.fire('run:ended', runs[d5.runId], 'abandoned', 'quit')
    H.eq(MC._calls()[c2.id], nil, 'second drop: closed, never reopened twice')
    H.eq(CallRow(c2.id).outcome, 'abandoned', 'outcome abandoned')
end

-- ============================================================================
--                    MUTE, WATCHERS, CACHE COST AND BUDGET
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x + 50, S.y, 30.0))
    MySQL.insert.await('INSERT INTO cp_officers (citizenid, calls_muted) VALUES (?, 1)', { Cid(2) })
    MC._setNextPost(0)
    MC._tick()
    H.eq(Toasts(1), 1, 'an idle officer gets the call toast')
    H.eq(Toasts(2), 0, 'calls_muted = 1: no toast')
    -- DispatchView only for officers with the tablet open (the Dispatch screen asked for it)
    pushes = {}
    Cb('getMissionCalls', 1)
    NewCall('investigation', 'vinewood')
    MC._pushAll()
    H.ok(Find(pushes, function(p) return p.src == 1 and p.topic == 'calls' end) ~= nil, 'the open tablet gets the push')
    H.eq(Find(pushes, function(p) return p.src == 2 end), nil, 'a closed tablet gets nothing')
    H.fire('crimson-police:server:mcWatch', 1, false)
    -- the tablet's own close (server:tabletClosed in modules/tablet fires 'tablet:closed') ends a watch the same way
    Cb('getMissionCalls', 2)
    CP.Hooks.fire('tablet:closed', 2)
    pushes = {}
    NewCall('investigation', 'vinewood')
    MC._pushAll()
    H.eq(Find(pushes, function(p) return p.src == 1 end), nil, 'mcWatch false (older clients): no more pushes')
    H.eq(Find(pushes, function(p) return p.src == 2 end), nil, 'tablet:closed: no more pushes')
    H.eq(#pushes, 0, 'the tablets closed: nothing is pushed')

    -- 30 on-duty officers: 10 units of 2 and 10 solo, 4 open calls, every tablet open, a claim race
    Reset()
    local src = 0
    for u = 1, 10 do
        local a, b = src + 1, src + 2
        AddPlayer(a, vec3(S.x + u * 40, S.y, 30.0))
        AddPlayer(b, vec3(S.x + u * 40, S.y + 10, 30.0))
        units[#units + 1] = { id = u, leader = a, members = { a, b } }
        src = b
    end
    for _ = 1, 10 do
        src = src + 1
        AddPlayer(src, vec3(S.x - src * 30, S.y, 30.0))
    end
    -- warm-up: every officer's eligibility (the no-repeat histories) is read once, as when they go on duty
    for s = 1, 30 do
        Cb('getMissionCalls', s)
        MC.eligibility(s)
    end
    -- the spy: cp_mission_runs reads from here on
    local reads = 0
    local q, sgl, sc = MySQL.query.await, MySQL.single.await, MySQL.scalar.await
    local function Spy(fn)
        return function(sql, ...)
            if type(sql) == 'string' and sql:find('cp_mission_runs', 1, true) then reads = reads + 1 end
            return fn(sql, ...)
        end
    end
    MySQL.query.await, MySQL.single.await, MySQL.scalar.await = Spy(q), Spy(sgl), Spy(sc)
    local t0 = os.clock()
    local ticks = 0
    for i = 1, 4 do
        MC._setNextPost(0)
        MC._tick()
        ticks = ticks + 1
    end
    local open = 0
    for _ in pairs(MC._calls()) do open = open + 1 end
    H.eq(open, 4, 'four open calls')
    for s = 1, 30 do
        MC.list(s)
    end -- every viewer's DispatchView
    MC._pushAll()
    local target
    for _, c in pairs(MC._calls()) do target = target or c end
    local okA = MC.claimableCount(1)
    H.ok(okA >= 0, 'claimable count from the cache')
    local cpu = os.clock() - t0
    MySQL.query.await, MySQL.single.await, MySQL.scalar.await = q, sgl, sc
    H.eq(reads, 0, 'no cp_mission_runs query per call or per viewer after the warm-up')
    -- the claim race (two units within the window), then one more check with every tablet open
    local t1 = os.clock()
    H.clockMs = H.clockMs + 3000
    local r1 = Fire('server:claimMissionCall', 1, { callId = target.id })
    local r2 = Fire('server:claimMissionCall', 3, { callId = target.id })
    H.advance(2000)
    MC._tick()
    MC._pushAll()
    ticks = ticks + 1
    cpu = cpu + (os.clock() - t1)
    H.ok(Reply(r1) and Reply(r2), 'both claims answered')
    -- one check every checkEvery seconds; FXServer runs 20 server frames a second (50 ms)
    local frames = ticks * Config.MissionCalls.checkEvery * 20
    local perFrameMs = cpu * 1000 / frames
    print(('    REPORT mission calls: %.2f ms CPU for %d checks with 30 officers, %.4f ms per server frame'):format(
        cpu * 1000, ticks, perFrameMs))
    H.ok(perFrameMs < 0.25, ('under 0.25 ms per server frame (%.4f ms)'):format(perFrameMs))
end

-- The hourly and daily counts of the accept checks come from CP.Runs, whose own cache reads cp_mission_runs
-- again every 10 s: the eligibility cache keeps them until a row settles (or, at a cap, re-reads them now and
-- then), so posting and the cards never ask for them per call or per viewer.
do
    Reset()
    local S = CENTRE.south_ls
    for s = 1, 6 do AddPlayer(s, vec3(S.x + s * 40, S.y, 30.0)) end
    units = { { id = 1, leader = 1, members = { 1, 2 } } }
    Config.Limits.maxCompletionsDay = 5
    local reads = 0
    local lastHour, today = CP.Runs.completionsLastHour, CP.Runs.completionsToday
    CP.Runs.completionsLastHour = function(cid) reads = reads + 1 return lastHour(cid) end
    CP.Runs.completionsToday = function(cid, t) reads = reads + 1 return today(cid, t) end
    MC._setNextPost(0)
    MC._tick()
    for s = 1, 6 do Cb('getMissionCalls', s) end
    local warm = reads
    H.ok(warm > 0, 'the counts are read once (warm-up)')
    local oldTime = H.time
    for _ = 1, 12 do
        H.time = H.time + 10
        MC._setNextPost(0)
        MC._tick()
        for s = 1, 6 do MC.list(s) end
        MC.claimableCount(1)
    end
    H.eq(reads, warm, 'two minutes of checks and cards: no count read again')
    -- a settled row of officer 3: only their counts are read again
    CP.Hooks.fire('row:settled', { id = 'r' }, { citizenid = Cid(3) })
    MC.list(3)
    H.ok(reads > warm, 'a settled row reads that officer\'s counts again')
    local afterSettle = reads
    MC.list(4)
    H.eq(reads, afterSettle, 'the others keep theirs')
    -- an officer at the hourly cap is re-read now and then, so the lock lifts when the hour has passed
    hourly[Cid(5)] = 99
    CP.Hooks.fire('row:settled', { id = 'r' }, { citizenid = Cid(5) })
    MC.list(5)
    H.eq(CardOf(5, select(2, next(MC._calls())).id).locked ~= nil, true, 'at the hourly cap: locked')
    hourly[Cid(5)] = nil
    H.time = H.time + 61
    local card5 = CardOf(5, select(2, next(MC._calls())).id)
    H.eq(card5.locked, nil, 'the hour passed: the lock lifted without a settled row')
    -- a claim checks the counts fresh
    local r0 = reads
    local call = select(2, next(MC._calls()))
    Claim(6, call.id)
    H.ok(reads > r0, 'a claim reads the counts fresh')
    CP.Runs.completionsLastHour, CP.Runs.completionsToday = lastHour, today
    Config.Limits.maxCompletionsDay = 0
    H.time = oldTime
end

-- ============================================================================
--                        NEVER SC-DISPATCH, REAL CALLS
-- ============================================================================

do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(9, vec3(S.x, S.y, 30.0), { sup = true })
    scdCalls = {}
    H.events = {}
    MC._setNextPost(0)
    MC._tick()
    local call = select(2, next(MC._calls()))
    local _, data = Claim(1, call.id)
    local run = runs[data.runId]
    run.state = 'ended'
    CP.Hooks.fire('run:ended', run, 'abandoned', 'quit')
    Act('server:sup:mcWithdraw', 9, { callId = call.id, reason = 'test' })
    Act('server:sup:mcCreate', 9, { type = 'patrol' })
    H.time = H.time + 400
    MC._tick()
    H.eq(#scdCalls, 0, 'no sc-dispatch export was called (no AddNotification)')
    for _, e in ipairs(H.events) do
        H.ok(not tostring(e.name):find('dispatch', 1, true), 'no dispatch event: ' .. tostring(e.name))
        H.ok(not tostring(e.name):find('police:', 1, true) or tostring(e.name):find('crimson-police:', 1, true) == 1,
            'no police:* event')
    end

    -- realCallSummary: mdt_dispatch in MariaDB, npccall- ids left out, cached 15 s, nil on error
    local f = assert(io.open('tests/fixtures/core/mdt_dispatch.sql', 'r'))
    H.sql(f:read('a'))
    f:close()
    H.sql([[INSERT INTO mdt_dispatch (id, type, message, active, unique_id, priority) VALUES
        (20, '10-99', 'priority one', 1, 'p1_1', 1), (21, '10-99', 'npc p1', 1, 'npccall-21-1', 1)]])
    local R = CP.Dispatch
    R._resetSummary()
    local s1 = R.realCallSummary()
    H.eq(s1 and s1.total, 5, 'active real calls: ids 1, 2, 4, 6 and 20 (npccall- ids and inactive left out)')
    H.eq(s1 and s1.p1, 1, 'one Priority 1')
    H.sql('INSERT INTO mdt_dispatch (id, type, message, active, unique_id) VALUES (22, \'911\', \'new\', 1, \'n22\')')
    H.eq(R.realCallSummary().total, 5, 'cached for 15 s')
    H.time = H.time + 16
    H.eq(R.realCallSummary().total, 6, 'refreshed after 15 s')
    H.sql('RENAME TABLE mdt_dispatch TO mdt_dispatch_off')
    H.time = H.time + 16
    H.eq(R.realCallSummary(), nil, 'a failed lookup: nil (the strip is hidden)')
    H.sql('RENAME TABLE mdt_dispatch_off TO mdt_dispatch')
    H.eq(MC.list(1).realCalls, nil, 'the Dispatch view hides the strip')
    H.time = H.time + 16
    H.eq(MC.list(1).realCalls.total, 6, 'the strip is back')
    H.sql('DELETE FROM mdt_dispatch')

    -- stats: answered calls and the average response from completed rows
    local ins = [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base, mission_call_id, response_s, breakdown) VALUES (?, 'patrol', 'patrol_a', ?, 'sast', ?,
        ?, 60, ?, ?, ?)]]
    local rapid = '{"points":{"bonuses":[{"id":"rapid_response","points":6}]}}'
    MySQL.insert.await(ins, { 'st-1', 'STAT1', 'completed', 'completed', 1, 100, rapid })
    MySQL.insert.await(ins, { 'st-2', 'STAT1', 'completed', 'completed', 2, 200, '{"points":{"bonuses":[]}}' })
    MySQL.insert.await([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department,
        state, end_reason, points_base, mission_call_id) VALUES ('st-3', 'patrol', 'patrol_a', 'STAT1', 'sast',
        'abandoned', 'quit', 60, 3)]], {})
    local st = MC.stats('STAT1')
    H.eq(st.answered, 2, 'answered: completed claimed runs only')
    H.eq(st.avgResponse, 150, 'average response')
    H.eq(st.rapid, 1, 'rapid responses')
    H.eq(MC.stats('NOBODY').answered, 0, 'nobody: 0')
end

-- ============================================================================
--                          HOME EXTRAS AND THE BOARD
-- ============================================================================

do
    Reset()
    AddPlayer(1, CENTRE.downtown)
    NewCall('patrol', 'downtown')
    NewCall('patrol', 'south_ls')
    local extras = {}
    CP.Hooks.fire('home:extras', Cid(1), 1, extras)
    H.eq(extras.callsOpen, 2, 'Home: mission calls open')
    local board = D.boardCards(1)
    H.eq(board.callsOpen, 2, 'the board: n mission calls open')
    units = { { id = 1, leader = 2, members = { 2, 1 } } }
    AddPlayer(2, CENTRE.downtown)
    H.eq(MC.claimableCount(1), 0, 'a member who is not the leader can claim none')
    units = {}
end

-- ============================================================================
--                    HISTORY CLEAN-UP AND MDT COMMENDATIONS
-- ============================================================================

do
    Reset()
    local days = Config.Retention.missionCallDays
    H.ok(days > 0, 'retention configured')
    MySQL.insert.await([[INSERT INTO cp_mission_calls (code, mission_type, priority, status, created_at)
        VALUES ('MC-OLD', 'patrol', 3, 'lapsed', FROM_UNIXTIME(?))]], { H.time - (days + 2) * 86400 })
    MySQL.insert.await([[INSERT INTO cp_mission_calls (code, mission_type, priority, status, created_at)
        VALUES ('MC-NEW', 'patrol', 3, 'lapsed', FROM_UNIXTIME(?))]], { H.time - 86400 })
    CP.Schedule._check(H.time)
    H.time = H.time + 86400
    CP.Schedule._check(H.time)
    H.advance(500)
    local old = MySQL.scalar.await('SELECT COUNT(*) FROM cp_mission_calls WHERE code = \'MC-OLD\'', {})
    local new = MySQL.scalar.await('SELECT COUNT(*) FROM cp_mission_calls WHERE code = \'MC-NEW\'', {})
    H.eq(tonumber(old), 0, 'the daily clean-up deletes calls older than missionCallDays')
    H.eq(tonumber(new), 1, 'and keeps the recent ones')

    -- MDT commendations: employee_incidents, read-only, nil on error
    H.eq(CP.Dispatch.mdtCommendations('MDT1'), nil, 'no employee_incidents table: nil')
    H.sql([[CREATE TABLE IF NOT EXISTS employee_incidents (id INT AUTO_INCREMENT PRIMARY KEY,
        citizenid VARCHAR(50), type VARCHAR(32), title VARCHAR(255), issued_by VARCHAR(64),
        created_at DATETIME DEFAULT CURRENT_TIMESTAMP)]])
    H.sql([[INSERT INTO employee_incidents (citizenid, type, title, issued_by, created_at) VALUES
        ('MDT1', 'commendation', 'Bravery', 'Chief Ray', '2026-09-01 10:00:00'),
        ('MDT1', 'reprimand', 'Late', 'Chief Ray', '2026-09-02 10:00:00'),
        ('MDT1', 'commendation', 'Promotion', 'Chief Ray', '2026-09-03 10:00:00')]])
    local list = CP.Dispatch.mdtCommendations('MDT1')
    H.eq(list and #list, 2, 'commendations only')
    H.eq(list and list[1].title, 'Promotion', 'newest first')
    H.eq(list and list[1].by, 'Chief Ray', 'issued by')
    H.ok(list and list[1].at > 0, 'a timestamp')
    H.sql('DROP TABLE employee_incidents')
end

-- ============================================================================
--            QBOX LOOKUPS PER CHECK (THE REAL CP.Access AND CP.Qbx)
-- ============================================================================
-- With the real CP.Access and CP.Qbx a check copies only the on-duty officers' Player objects out of qbx_core:
-- civilians are skipped by the job map (kept by qbx_core's events), each officer is looked up once, and each unit
-- is built once per check.

do
    Reset()
    local S = CENTRE.south_ls
    local qbx = {}
    local function QbxPlayer(src, job, onduty)
        qbx[src] = {
            PlayerData = {
                source = src,
                citizenid = ('QB%04d'):format(src),
                charinfo = { firstname = 'Qb', lastname = tostring(src) },
                job = { name = job, label = job, onduty = onduty, grade = { name = 'Trooper', level = 1 } },
                metadata = {},
            },
        }
        H.players[src] = H.players[src] or { coords = vec3(S.x + src, S.y, 30.0) }
    end
    local lookups = 0
    H.exportsMock.qbx_core = {
        GetPlayer = function(src)
            lookups = lookups + 1
            return qbx[tonumber(src)]
        end,
        GetQBPlayers = function() return qbx end,
        GetJobs = function() return {} end,
    }
    local Stub = CP.Access
    CP.Access = nil
    H.load('modules/integrations/qbx/server.lua')
    H.load('modules/access/server.lua')
    -- six on-duty officers (a unit of 1 and 2, four solo) and 100 civilians, all loaded the way qbx_core loads them
    for s = 1, 6 do QbxPlayer(s, 'sast', true) end
    for s = 101, 200 do QbxPlayer(s, 'unemployed', false) end
    units = { { id = 1, leader = 1, members = { 1, 2 } } }
    for s, p in pairs(qbx) do
        TriggerEvent('QBCore:Server:PlayerLoaded', U.copy(p))
        H.ok(CP.Qbx.knownJob(s) ~= nil, 'PlayerLoaded fills the job map: ' .. s)
    end
    H.advance(100)

    -- (a) a check with nothing to post: one lookup per on-duty officer, none for a civilian
    lookups = 0
    MC._tick()
    H.ok(lookups <= 6,
        ('one check: at most one GetPlayer per on-duty officer (%d for 6 officers, 100 civilians)'):format(lookups))
    lookups = 0
    local idle = MC._idleUnits()
    H.eq(#idle, 5, 'the unit and four solo officers are idle')
    H.ok(lookups <= 6, 'the idle units: no lookup for a civilian, none twice for a unit member')
    local sv = MC.supView(0)
    H.eq(#sv.units, 5, 'the supervisor view lists the five idle units')
    local first = Find(sv.units, function(u) return u.src == 1 end)
    H.eq(first and first.name, 'Qb 1', 'with the leader\'s name from the idle unit')
    H.eq(first and first.size, 2, 'and its size')

    -- (b) a civilian whose job becomes a department job only through qbx_core's SetPlayerData
    qbx[150].PlayerData.job = { name = 'sast', label = 'SAST', onduty = true, grade = { name = 'Trooper', level = 1 } }
    H.eq(CP.Access.maybeOfficer(150), false, 'before qbx_core sends the change: a known civilian')
    TriggerEvent('QBCore:Player:SetPlayerData', U.copy(qbx[150].PlayerData))
    H.eq(CP.Qbx.knownJob(150), 'sast', 'SetPlayerData updates the job map')
    MC._tick()
    H.ok(Find(MC._idleUnits(), function(u)
        return u.leader == 150
    end) ~= nil, 'made police through SetPlayerData only: an idle unit on the next check')

    -- (c) a player qbx_core never told us about gets the full getOfficer check
    QbxPlayer(300, 'sast', true)
    H.eq(CP.Qbx.knownJob(300), nil, 'no job known for 300')
    H.eq(CP.Access.maybeOfficer(300), true, 'an unknown job: maybe an officer')
    H.ok(Find(MC._idleUnits(), function(u) return u.leader == 300 end) ~= nil, 'the full check finds the officer')
    H.eq(CP.Qbx.knownJob(300), 'sast', 'and the lookup fills the job map')
    -- a job the map still has as a department job is checked in full too (getOfficer refuses it)
    qbx[300].PlayerData.job.onduty = false
    TriggerEvent('QBCore:Player:SetPlayerData', U.copy(qbx[300].PlayerData))   -- qbx_core's UpdatePlayerData
    H.eq(Find(MC._idleUnits(), function(u) return u.leader == 300 end), nil, 'off duty: no idle unit')

    -- (d) a check that posts a call builds each unit once (the accept checks of CP.Draw build their own)
    for k in pairs(qbx) do if k >= 150 then qbx[k] = nil H.players[k] = nil end end
    local inDraw, builds = 0, 0
    local realMembers = CP.Units.members
    CP.Units.members = function(src)
        if inDraw == 0 then builds = builds + 1 end
        return realMembers(src)
    end
    local realDraw = {}
    for k, fn in pairs(CP.Draw) do
        if type(fn) == 'function' then
            realDraw[k] = fn
            CP.Draw[k] = function(...)
                inDraw = inDraw + 1
                local r = table.pack(pcall(fn, ...))
                inDraw = inDraw - 1
                if not r[1] then error(r[2], 0) end
                return table.unpack(r, 2, r.n)
            end
        end
    end
    MC._reset()
    MC._setNextPost(0)
    builds = 0
    MC._tick()
    local posted = 0
    for _ in pairs(MC._calls()) do posted = posted + 1 end
    H.eq(posted, 1, 'the check posted a call')
    H.ok(Toasts() > 0, 'and toasted the idle units')
    H.eq(builds, 5, 'five idle units: five unit builds in the whole check (posting and toasts reuse them)')
    for k, fn in pairs(realDraw) do CP.Draw[k] = fn end
    CP.Units.members = realMembers
    CP.Access = Stub
end

-- ============================================================================
--                TWISTS CHOSEN WHEN CLAIMING A CALL (PLAN M8b)
-- ============================================================================
-- The real CP.Events offer and check (this spec stubs CP.Events otherwise): the card offers the type's twists, the
-- claim checks the leader's choice before it joins the window, and the run gets it.

do
    local stub = CP.Events
    CP.Events = {}
    H.load('modules/events/server.lua')
    local real = CP.Events
    CP.Events = stub
    stub.twistOffer, stub.checkTwists, stub.twistFits = real.twistOffer, real.checkTwists, real.twistFits

    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x + 100, S.y, 30.0))
    local call = NewCall('patrol', 'south_ls')
    local card, view = CardOf(1, call.id)
    local keys = {}
    for i, t in ipairs(card.twists or {}) do keys[i] = t.key end
    H.eq(table.concat(keys, ','), 'time_crunch,radio_silence',
        'the call card offers its type\'s twists (no Armored Hostiles: no armed NPCs in the pool)')
    H.ok(view.twistMax and view.twistMax.points == 0.70 and view.twistMax.cash == 1.95, 'and the caps')

    local ok, err = Act('server:claimMissionCall', 1, { callId = call.id, twists = { 'armored_hostiles' } })
    H.eq(ok, false, 'a twist the type does not offer is refused')
    H.eq(err, 'err.twist_unavailable', '...as not available')
    H.eq(call.window, nil, 'the refused claim never joined the claim window')
    ok, err = Act('server:claimMissionCall', 1, { callId = call.id, twists = 'radio_silence' })
    H.eq(err, 'err.invalid_payload', 'twists must be a list')

    local before = #created
    local data
    ok, data = Act('server:claimMissionCall', 1, { callId = call.id, twists = { 'radio_silence', 'time_crunch' } })
    H.eq(ok, true, 'the claim with two twists wins')
    H.ok(type(data) == 'table' and data.runId ~= nil, 'a run')
    local opts = created[before + 1]
    H.eq(opts and table.concat(opts.twists or {}, ','), 'time_crunch,radio_silence',
        'the run is made with the chosen twists (CP.Runs.create opts.twists)')
    CP.Events = stub
    stub.twistOffer, stub.checkTwists, stub.twistFits = nil, nil, nil
end

-- Step P3: the noRepeat Mission control switched off (CP.Draw.limits): a call's eligible pool keeps the unit's last
-- mission (every member brings an empty history).
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x + 100, S.y, 30.0))
    D.recordLast(Cid(1), 'patrol', 'patrol_a')
    local st = MC.eligibility(1).types.patrol
    H.eq(st.eligible, st.board - 1, 'the rule on: the last patrol is not eligible')
    local limits = D.limits
    D.limits = function(o)
        local l = limits(o)
        l.noRepeat = false
        return l
    end
    CP.Hooks.fire('deptControls:changed', { key = 'noRepeat' })
    st = MC.eligibility(1).types.patrol
    H.eq(st.eligible, st.board, 'the rule off: a change empties the cache and the whole pool is eligible')
    D.limits = limits
    CP.Hooks.fire('deptControls:changed', { key = 'noRepeat' })
end

-- Step P10: a mission type command switched off for a department (the types Mission control, CP.Draw.offFor): its
-- officers get no pop-up for a call of that type and cannot claim it; another department's officer still does.
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(4, vec3(S.x + 50, S.y, 30.0), { dept = 'fib', short = 'FIB' })
    local keepDC = CP.DeptControls
    CP.DeptControls = {
        def = function(key) return key == 'types' end,
        get = function(dept, key) return key == 'types' and dept == 'sast' and { patrol = false } or nil end,
    }
    CP.Hooks.fire('deptControls:changed', { key = 'types' })
    local pc = NewCall('patrol', 'south_ls')
    H.eq(Toasts(1), 0, 'Patrol off for SAST: no pop-up for the SAST officer')
    H.eq(Toasts(4), 1, '...the FIB officer gets it')
    local ok, err = Claim(1, pc.id)
    H.ok(ok == false and err == 'err.type_off_department', 'and the SAST officer cannot claim it')
    CP.DeptControls = keepDC
    CP.Hooks.fire('deptControls:changed', { key = 'types' })
end

-- Step P11: a supervisor's mission ban (CP.MissionBan) runs through the accept check: no pop-up and no claim for the
-- banned officer; another officer still gets the call.
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(4, vec3(S.x + 50, S.y, 30.0), { dept = 'fib', short = 'FIB' })
    local banned = Cid(1)
    CP.MissionBan = {
        first = function(officers)
            for _, o in ipairs(officers) do
                if o.citizenid == banned then return o, { ['until'] = os.time() + 3600, name = 'Sgt Doe' } end
            end
            return nil
        end,
    }
    local pc = NewCall('patrol', 'south_ls')
    H.eq(Toasts(1), 0, 'mission ban: no pop-up for the banned officer')
    H.eq(Toasts(4), 1, '...the other officer gets it')
    local ok, err = Claim(1, pc.id)
    H.ok(ok == false and err == 'err.mission_banned', 'and the banned officer cannot claim it')
    CP.MissionBan = nil
end

-- Step P12: a department's own call lane (the callLane Mission control) and its staff call wait (staffCallWait). A
-- stand-in CP.DeptControls gives SAST a lane (Patrol only, South LS, every 120-240 s, two open at most).
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x + 30, S.y, 30.0))
    AddPlayer(4, vec3(S.x + 50, S.y, 30.0), { dept = 'fib', short = 'FIB' })
    local keepDC = CP.DeptControls
    local lane = { spawnEvery = { 120, 240 }, maxOpen = 2, areas = { 'south_ls' }, types = { patrol = 5 } }
    local wait = nil
    local setter = 'NOBODY'
    CP.DeptControls = {
        get = function(dept, key)
            if key == 'callLane' and dept == 'sast' then return lane, { setBy = 'SUP1' } end
            if key == 'staffCallWait' and dept == 'sast' then return wait end
            return nil
        end,
        heldBy = function(officers)
            for _, o in ipairs(officers) do if o.citizenid == setter then return true end end
            return false
        end,
    }
    local function LaneCalls(dept)
        local out = {}
        for _, c in pairs(MC._calls()) do
            if c.department == dept and c.status == 'open' then out[#out + 1] = c end
        end
        return out
    end
    local t0 = H.time
    local keepOffer = Config.MissionCalls.offerTime
    Config.MissionCalls.offerTime = 3600   -- the calls stay open through the whole check
    MC._tick()
    local list = LaneCalls('sast')
    H.eq(#list, 1, 'lane: the first check posts one SAST lane call')
    local lc = list[1]
    H.ok(lc and lc.type == 'patrol' and lc.area == 'south_ls', 'lane: Patrol in South LS, as the lane picked')
    H.eq(#LaneCalls(nil), 0, 'lane: the server flow (not due) posted nothing')
    H.eq(CallRow(lc.id).department, 'sast', 'lane: the row keeps the department (migration 013)')
    H.eq(Toasts(1), 1, 'lane: the SAST officer gets the pop-up')
    H.eq(Toasts(4), 0, 'lane: the FIB officer never does')
    H.eq(CardOf(4, lc.id), nil, 'lane: the call is not on the FIB officer\'s Dispatch')
    local card = CardOf(1, lc.id)
    H.ok(card and card.department == 'sast' and card.departmentShort == 'SAST', 'lane: the SAST card is tagged SAST')
    H.eq(MC.claimableCount(4), 0, 'lane: nothing claimable for FIB')
    local ok, err = Claim(4, lc.id)
    H.ok(ok == false and err == 'err.mc_other_department', 'lane: the FIB officer cannot claim it')
    setter = Cid(2)
    ok, err = Claim(2, lc.id)
    H.ok(ok == false and err == 'err.mc_own_call', 'lane: the one who set the lane cannot claim its calls')
    setter = 'NOBODY'
    H.time = t0 + 60
    MC._tick()
    H.eq(#LaneCalls('sast'), 1, 'lane: no second call inside the lane gap')
    H.time = t0 + 241
    MC._tick()
    H.eq(#LaneCalls('sast'), 2, 'lane: a second call once the gap passed')
    H.time = t0 + 600
    MC._tick()
    H.eq(#LaneCalls('sast'), 2, 'lane: never more than its maxOpen open')
    local sup = MC.supView(4)
    H.eq(#sup.lanes, 0, 'lane: an FIB viewer sees no SAST lane on the staff panel')
    sup = MC.supView(1)
    H.ok(#sup.lanes == 1 and sup.lanes[1].departmentShort == 'SAST' and sup.lanes[1].open == 2,
        'lane: a SAST viewer sees his lane with its two open calls')
    Config.MissionCalls.offerTime = keepOffer

    -- every call counts against Config.MissionCalls.maxOpen; the server flow counts only its own calls
    Reset()
    H.time = t0
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x + 30, S.y, 30.0))
    MC._setNextPost(0)
    MC._tick()
    H.ok(#LaneCalls(nil) == 1 and #LaneCalls('sast') == 1,
        'two idle units (server target 1): one server call and one lane call')
    local keepMax = Config.MissionCalls.maxOpen
    Config.MissionCalls.maxOpen = 2
    H.time = t0 + 300
    MC._tick()
    H.eq(#LaneCalls(nil) + #LaneCalls('sast'), 2, 'the board never goes past maxOpen with lane calls in it')
    Config.MissionCalls.maxOpen = keepMax

    -- the lane value check: callable types only, the admin's gap bounds, a known area
    local b = { min = 120, max = 600 }
    H.ok(MC._cleanLane(lane, b, true) ~= nil, 'check: the lane above is good')
    H.eq(MC._cleanLane({ spawnEvery = { 60, 240 }, maxOpen = 1, types = { patrol = 1 } }, b, true), nil,
        'check: a gap under the admin\'s min is refused')
    H.eq(MC._cleanLane({ spawnEvery = { 120, 240 }, maxOpen = 1, types = { training = 1 } }, b, true), nil,
        'check: Training is never callable')
    H.eq(MC._cleanLane({ spawnEvery = { 120, 240 }, maxOpen = 1, areas = { 'mars' }, types = { patrol = 1 } }, b, true),
        nil, 'check: an unknown area is refused')
    H.eq(MC._cleanLane({ spawnEvery = { 120, 240 }, maxOpen = 3, types = { patrol = 1 } }, b, true), nil,
        'check: more open calls than callLaneMaxOpen is refused')
    local moved = MC._cleanLane({ spawnEvery = { 60, 900 }, maxOpen = 1, types = { patrol = 1 } }, b, false)
    H.ok(moved and moved.spawnEvery[1] == 120 and moved.spawnEvery[2] == 600, 'clamp: a saved gap moves inside')

    -- staffCallWait: SAST's 60 s instead of the config 120 s
    Reset()
    H.time = t0
    AddPlayer(3, vec3(S.x, S.y, 30.0), { sup = true })
    wait = 60
    H.ok((MC.create(3, 'patrol', 'south_ls')), 'staff wait: the first call')
    H.time = t0 + 59
    local okW, errW = MC.create(3, 'patrol', 'south_ls')
    H.ok(okW == false and errW == 'err.mc_staff_cooldown', 'staff wait: refused inside 60 s')
    H.time = t0 + 61
    H.ok((MC.create(3, 'patrol', 'south_ls')), 'staff wait: SAST\'s 60 s passed')
    wait = nil
    H.time = t0 + 122
    okW, errW = MC.create(3, 'patrol', 'south_ls')
    H.ok(okW == false and errW == 'err.mc_staff_cooldown', 'staff wait: the control off, config 120 s again')
    H.time = t0 + 182
    H.ok((MC.create(3, 'patrol', 'south_ls')), 'staff wait: 120 s after the last call')
    H.time = t0 + 250
    okW, errW = MC.create(3, 'patrol', 'south_ls')
    H.ok(okW == false and errW == 'err.mc_staff_cooldown', 'staff wait: config 120 s applies')
    H.time = t0
    CP.DeptControls = keepDC
end

-- Step O9: callAlerts 'favourites' (My options -> Dispatch): a call of another type shows on Dispatch with no pop-up;
-- calls_muted still silences every call (the mute section above); with no favourite picked every call pops up.
do
    Reset()
    local S = CENTRE.south_ls
    AddPlayer(1, vec3(S.x, S.y, 30.0))
    AddPlayer(2, vec3(S.x + 50, S.y, 30.0))
    local keepOptions = CP.Options
    CP.Options = setmetatable({}, { __index = keepOptions })
    local favs = { [Cid(1)] = { 'investigation' }, [Cid(2)] = { 'patrol' } }
    CP.Options.effective = function(cid) return { callAlerts = 'favourites', favouriteTypes = favs[cid] or {} } end
    MC._forgetMuted(Cid(1))
    MC._forgetMuted(Cid(2))
    local pc = NewCall('patrol', 'south_ls')
    H.eq(Toasts(1), 0, 'favourites (Investigation): a Patrol call has no pop-up')
    H.ok(CardOf(1, pc.id) ~= nil, '...and still shows on Dispatch')
    H.eq(Toasts(2), 0, 'calls_muted wins over a favourite type')
    H.events = {}
    NewCall('investigation', 'south_ls')
    H.eq(Toasts(1), 1, 'favourites: a call of a favourite type pops up')
    favs[Cid(1)] = {}
    H.events = {}
    NewCall('patrol', 'south_ls')
    H.eq(Toasts(1), 0, 'the answer is cached for 30 s, like calls_muted')
    MC._forgetMuted(Cid(1))
    H.events = {}
    NewCall('patrol', 'south_ls')
    H.eq(Toasts(1), 1, 'favourites with none picked: every call pops up')
    CP.Options = keepOptions
    MC._forgetMuted(Cid(1))
    MC._forgetMuted(Cid(2))
end

return H
