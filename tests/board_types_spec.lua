-- Mission Board controls (step P10): types switches mission types or single missions off for a department (its
-- officers see the type locked, other departments still take it; a unit with a member of that department is refused),
-- featuredType recommends one type to a department's officers. Plain stubs: CP.DeptControls answers saved values.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

-- ============================================================================
--                                    STUBS
-- ============================================================================

local players = {
    [1] = { citizenid = 'BT00001', department = 'sast' },
    [2] = { citizenid = 'BT00002', department = 'fib' },
    [3] = { citizenid = 'BT00003', department = 'sast' },
}
for src in pairs(players) do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
local units = {}

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
    completionsLastHour = function() return 0 end,
    completionsToday = function() return 0 end,
    all = function() return {} end,
}
CP.Cash = {
    range = function() return 200, 300 end,
}

-- Mission controls: register keeps the definitions; get answers the value saved for that department (clamped like
-- the real CP.DeptControls does), else the config value.
local defs, saved = {}, {}
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    get = function(dept, key)
        local def = defs[key]
        local v = saved[(dept or '*') .. '|' .. key]
        if v == nil then return def.configValue() end
        if def.clamp then v = def.clamp(v) end
        return v
    end,
}

local function Loc(x, y)
    return { label = ('(%d, %d)'):format(x, y), start = { coords = vec3(x + 0.0, y + 0.0, 30.0), radius = 40.0 } }
end
local missions = {
    { id = 'raid_a', label = 'Raid A', type = 'tactical', locations = { Loc(1000, 1000) } },
    { id = 'raid_b', label = 'Raid B', type = 'tactical', locations = { Loc(1000, 1600) } },
    { id = 'beat_a', label = 'Beat A', type = 'patrol', locations = { Loc(2000, 1000) } },
    { id = 'beat_b', label = 'Beat B', type = 'patrol', locations = { Loc(2000, 1600) } },
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
    list = function() return missions end,
    isEnabled = function() return true end,
}

H.load('modules/schedule/server.lua')
H.load('modules/draw/server.lua')
local D = CP.Draw

local function Card(src, key)
    for _, c in ipairs(D.boardCards(src).cards) do if c.key == key then return c end end
    return nil
end
local function Ids(list)
    local out = {}
    for _, d in ipairs(list) do out[#out + 1] = d.id end
    table.sort(out)
    return table.concat(out, ',')
end

-- ============================================================================
--                     1. WHAT DRAW REGISTERS (SHIPPED OFF)
-- ============================================================================

do
    local MC = Config.MissionControls.controls
    H.ok(MC.types.on == false and MC.featuredType.on == false, 'both controls ship off')
    H.ok(defs.types.kind == 'map' and not defs.types.serverWide and (defs.types.scope or 'between') == 'between',
        'types: per department, read between runs')
    H.eq(defs.featuredType.kind, 'choice', 'featuredType: one type picked')
    H.eq(table.concat(defs.featuredType.choices(), ','), 'patrol,training,investigation,tactical',
        'featuredType: every mission type, in the board order')
    H.ok(not defs.types.relaxes({ tactical = false }, {}) and not defs.featuredType.relaxes('tactical'),
        'neither relaxes a rule: the supervisor who set them gets them too')
    local clean, err = defs.types.check({ tactical = false, patrol = true, missions = { beat_a = false } })
    H.ok(clean and clean.tactical == false and clean.patrol == nil and clean.missions.beat_a == false,
        'check keeps what is off, drops what is on')
    clean, err = defs.types.check({ nope = false })
    H.ok(clean == nil and err == 'err.control_value', 'an unknown type is refused')
    clean, err = defs.types.check({ missions = { gone = false } })
    H.ok(clean == nil and err == 'err.control_value', 'an unknown mission is refused')
    clean, err = defs.types.check({ patrol = false, training = false, investigation = false, tactical = false })
    H.ok(clean == nil and err == 'err.control_types_all_off', 'every type off is refused')
    clean = defs.types.clamp({ gone_type = false, tactical = false, missions = { gone = false } })
    H.ok(clean.tactical == false and clean.gone_type == nil and clean.missions == nil,
        'a saved value leaves out what no longer exists')
    H.eq(#defs.types.viewExtra('sast').missions, 4, 'the screen lists the missions one by one')
    local c = Card(1, 'tactical')
    H.ok(c and c.locked == nil and not c.offByCommand and not c.featured, 'nothing set: the board as today')
end

-- ============================================================================
--                  2. TACTICAL OFF FOR SAST, FEATURED PATROL
-- ============================================================================

do
    saved['sast|types'] = { tactical = false }
    local ok, err = D.check(1, 'tactical')
    H.ok(ok == false and err == 'err.type_off_department', 'Tactical off for SAST: a SAST officer is refused')
    H.eq(D.check(2, 'tactical'), true, 'an FIB officer takes it')
    H.eq(D.check(1, 'patrol'), true, 'another type is fine for SAST')
    units[1] = { leader = 2, members = { 2, 1 } }
    ok, err = D.check(2, 'tactical')
    H.ok(ok == false and err == 'err.type_off_department', 'an FIB-led unit with a SAST member is refused')
    H.eq(#D.pool('tactical', { 2, 1 }), 0, 'and nothing of the type is drawn for it')
    local c = Card(2, 'tactical')
    H.ok(c.locked and c.offByCommand == true and c.locked.reason:find('SAST', 1, true) ~= nil,
        'the FIB leader sees it locked, naming SAST')
    units[1] = nil
    c = Card(1, 'tactical')
    H.ok(c.locked and c.offByCommand == true and c.locked.reason == 'Off for SAST by command',
        'a SAST officer sees "Off for SAST by command"')
    H.ok(Card(2, 'tactical').locked == nil, 'the FIB board is unchanged')

    -- one mission off for SAST: not drawn for a unit with a SAST member, still drawn for FIB alone
    saved['sast|types'] = { missions = { beat_a = false } }
    H.eq(Ids(D.pool('patrol', { 2 })), 'beat_a,beat_b', 'FIB alone: both patrols')
    H.eq(Ids(D.pool('patrol', { 2, 1 })), 'beat_b', 'a unit with a SAST member: the switched-off mission is left out')
    H.eq(D.check(1, 'patrol'), true, 'the type itself stays on')
    saved['sast|types'] = nil

    saved['sast|featuredType'] = 'patrol'
    H.eq(Card(1, 'patrol').featured, true, 'featured Patrol: on a SAST officer\'s card')
    H.eq(Card(1, 'tactical').featured, nil, 'only on that type')
    H.eq(Card(2, 'patrol').featured, nil, 'never on an FIB officer\'s card')
    H.eq(Card(1, 'patrol').points, Card(2, 'patrol').points, 'no points')
    saved['sast|featuredType'] = 'gone_type'
    H.eq(D.featuredFor('sast'), nil, 'a type that no longer exists features nothing')
    saved['sast|featuredType'] = nil
end

return H
