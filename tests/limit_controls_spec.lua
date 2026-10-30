-- The no-repeat rule, the hourly cap and the daily cap as Mission controls (step P3): noRepeat, hourlyCap and

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_limit_controls'
H.resetDatabase()
H.boot({ side = 'server' })

local U = CP.U

-- ============================================================================
--                                    STUBS
-- ============================================================================

local players = {
    [1] = { citizenid = 'LC00001', department = 'sast' },
    [2] = { citizenid = 'LC00002', department = 'fib' },
    [3] = { citizenid = 'LC00003', department = 'sast' },   -- the supervisor who set the changes (the self rule)
}
for src in pairs(players) do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
local units = {}
local hourly, daily = {}, {}

CP.Access = {
    getOfficer = function(src)
        local p = players[src]
        if not p then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.citizenid,
            name = 'Officer ' .. src,
            department = p.department,
            departmentShort = p.department:upper(),
            job = p.department,
            rank = 'Trooper',
        }
    end,
    isAdmin = function() return false end,
}
CP.Units = {
    unitOf = function(src)
        for _, u in ipairs(units) do
            for _, m in ipairs(u.members) do if m == src then return u end end
        end
        return nil
    end,
    members = function(src)
        local u = CP.Units.unitOf(src)
        return u and u.members or { src }
    end,
    isLeader = function(src)
        local u = CP.Units.unitOf(src)
        return u ~= nil and u.leader == src
    end,
}
CP.Runs = {
    isOnMission = function() return false end,
    getBySrc = function() return nil end,
    capsOk = function() return true end,
    cooldowns = function() return { types = {}, missions = {} } end,
    completionsLastHour = function(cid) return hourly[cid] or 0 end,
    completionsToday = function(cid, t) return t == nil and (daily[cid] or 0) or 0 end,
    all = function() return {} end,
}
CP.Cash = {
    range = function() return 200, 300 end,
}

-- Mission controls: register keeps the definitions; get answers the saved value, or the config value for a list
-- of officers holding the setter while the value relaxes the rule (what the real self rule does).
local defs, saved, reads = {}, {}, {}
local SETTER = players[3].citizenid
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    get = function(dept, key, officers)
        reads[#reads + 1] = { dept = dept, key = key }
        local def = defs[key]
        local configValue = def.configValue()
        local v = saved[key]
        if v == nil then return configValue end
        for _, o in ipairs(type(officers) == 'table' and officers or {}) do
            if o.citizenid == SETTER and def.relaxes(v, configValue) then return configValue end
        end
        return v
    end,
}

local function Loc(x, y)
    return { label = ('(%d, %d)'):format(x, y), start = { coords = vec3(x + 0.0, y + 0.0, 30.0), radius = 40.0 } }
end
local missions = {
    { id = 'beat_a', type = 'patrol', locations = { Loc(1000, 1000), Loc(1300, 1000) } },
    { id = 'beat_b', type = 'patrol', locations = { Loc(1000, 1600), Loc(1300, 1600) } },
}
for _, d in ipairs(missions) do
    d.minOfficers, d.maxOfficers, d.difficulty, d.cooldown = 1, 4, 1, 900
    d.objectives = { { block = 'checkpoint_route' } }
end
CP.Missions = {
    byType = function(t)
        local out = {}
        for _, d in ipairs(missions) do if d.type == t then out[#out + 1] = d end end
        return out
    end,
    get = function(id)
        for _, d in ipairs(missions) do if d.id == id then return d end end
        return nil
    end,
    isEnabled = function() return true end,
}

H.load('modules/schedule/server.lua')
H.load('modules/draw/server.lua')
local D = CP.Draw

-- ============================================================================
--                            1. WHAT DRAW REGISTERS
-- ============================================================================

do
    for _, key in ipairs({ 'noRepeat', 'hourlyCap', 'dailyCap' }) do
        local d = defs[key]
        H.ok(d ~= nil and d.serverWide == true and d.master == false and (d.scope or 'between') == 'between',
            key .. ': registered server-wide, outside the master switch, read between runs')
    end
    H.eq(defs.noRepeat.kind, 'bool', 'noRepeat is a switch')
    H.ok(defs.hourlyCap.kind == 'number' and defs.hourlyCap.integer, 'hourlyCap is a whole number')
    H.ok(defs.dailyCap.kind == 'number' and defs.dailyCap.integer, 'dailyCap is a whole number')
    H.eq(defs.noRepeat.configValue(), true, 'noRepeat config value: the rule is on')
    H.eq(defs.hourlyCap.configValue(), Config.Limits.maxCompletionsHour, 'hourlyCap config value: maxCompletionsHour')
    H.eq(defs.dailyCap.configValue(), Config.Limits.maxCompletionsDay, 'dailyCap config value: maxCompletionsDay')
    H.ok(defs.noRepeat.relaxes(false, true) and not defs.noRepeat.relaxes(true, true), 'off relaxes the rule')
    H.ok(defs.hourlyCap.relaxes(10, 8) and not defs.hourlyCap.relaxes(6, 8), 'a higher hourly cap relaxes it')
    H.ok(defs.dailyCap.relaxes(0, 5) and defs.dailyCap.relaxes(9, 5) and not defs.dailyCap.relaxes(3, 5),
        'no daily cap or a higher one relaxes it')
    H.ok(not defs.dailyCap.relaxes(3, 0), 'with no daily cap in config any cap is stricter')
    local l = D.limits({ { citizenid = players[1].citizenid } })
    H.ok(l.noRepeat == true and l.hour == 8 and l.day == 0, 'nothing changed: today\'s rules (on, 8 an hour, no cap)')
    reads = {}
    D.limits({ { citizenid = players[2].citizenid } })
    for _, r in ipairs(reads) do H.eq(r.dept, nil, r.key .. ': read server-wide, not per department') end
end

-- ============================================================================
--                      2. THE NO-REPEAT RULE SWITCHED OFF
-- ============================================================================

local function Draws(srcs, tag)
    local n = {}
    for s = 1, 60 do
        local def = D.draw('patrol', srcs, { rng = U.rng(U.hash(tag .. s)) })
        if def then n[def.id] = (n[def.id] or 0) + 1 end
    end
    return n
end

do
    D.recordLast(players[1].citizenid, 'patrol', 'beat_a')
    D.recordLast(players[2].citizenid, 'patrol', 'beat_a')
    D.recordLast(players[3].citizenid, 'patrol', 'beat_b')
    H.eq(Draws({ 1 }, 'on').beat_a, nil, 'the rule on: a solo officer never draws his last mission')
    saved.noRepeat = false
    H.ok((Draws({ 1 }, 'off').beat_a or 0) > 0, 'the rule off: a SAST officer may draw his last mission again')
    H.ok((Draws({ 2 }, 'off').beat_a or 0) > 0, 'and an FIB officer (server-wide)')
    H.eq(Draws({ 3 }, 'self').beat_b, nil, 'the supervisor who switched it off keeps the rule (self rule)')
    H.eq(Draws({ 1, 3 }, 'unit').beat_b, nil, 'and so does a unit he is in')
    saved.noRepeat = nil
    H.eq(Draws({ 2 }, 'back').beat_a, nil, 'reset: the rule is back')
end

-- ============================================================================
--                         3. THE HOURLY AND DAILY CAPS
-- ============================================================================

do
    local cid1, cid2 = players[1].citizenid, players[2].citizenid
    hourly[cid1], hourly[cid2] = 6, 6
    H.eq(D.check(1, 'patrol'), true, 'config cap 8: a 7th completion this hour is allowed')
    saved.hourlyCap = 6
    local ok, err = D.check(1, 'patrol')
    H.ok(ok == false and err == 'err.hourly_cap', 'hourly cap 6: the 7th SAST completion is refused')
    ok, err = D.check(2, 'patrol')
    H.ok(ok == false and err == 'err.hourly_cap', 'and the 7th FIB completion (server-wide)')
    local card, lockMax
    local realL = CP.L
    CP.L = function(key, vars)
        if key == 'board.locked_hourly' then lockMax = vars and vars.max end
        return realL(key, vars)
    end
    for _, c in ipairs(D.boardCards(2).cards) do if c.key == 'patrol' then card = c end end
    CP.L = realL
    H.ok(card and card.locked ~= nil and lockMax == 6, 'the board lock names the cap of 6')
    -- the mission calls pass their own counts (CP.MissionCalls' cache): the same cap applies
    local counts = {
        lastHour = function() return 6 end,
        today = function() return 0 end,
    }
    ok, err = D.check(2, 'patrol', counts)
    H.ok(ok == false and err == 'err.hourly_cap', 'a mission call claim follows the same cap')
    saved.hourlyCap = 12
    hourly[cid1] = 9
    H.eq(D.check(1, 'patrol'), true, 'hourly cap 12: a 10th completion is allowed')
    hourly[players[3].citizenid] = 9
    ok, err = D.check(3, 'patrol')
    H.ok(ok == false and err == 'err.hourly_cap', 'the supervisor who raised it keeps 8 himself')
    saved.hourlyCap, hourly = nil, {}

    daily[cid1], daily[cid2] = 3, 3
    H.eq(D.check(1, 'patrol'), true, 'config: no daily cap')
    saved.dailyCap = 3
    ok, err = D.check(1, 'patrol')
    H.ok(ok == false and err == 'err.daily_cap', 'daily cap 3: the 4th SAST completion today is refused')
    ok, err = D.check(2, 'patrol', {
        lastHour = function() return 0 end,
        today = function() return 3 end,
    })
    H.ok(ok == false and err == 'err.daily_cap', 'an FIB mission call claim too')
    for _, c in ipairs(D.boardCards(1).cards) do if c.key == 'patrol' then card = c end end
    H.ok(card and card.locked and card.locked.daily == true, 'the board shows the daily lock')
    saved.dailyCap = 4
    H.eq(D.check(1, 'patrol'), true, 'daily cap 4: allowed again')
    saved.dailyCap, daily = nil, {}
end

return H
