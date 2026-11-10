-- Volunteer modes: Config.RealPlayers.volunteer.modes / missionModes, the volunteerSlot registry, who is free (a
-- 'players_only' accept holds one), the Mission Board card and "Real suspect OK", the draw filter, the pushed-mission
-- refusal, run.volunteer, the release at the run's end and the start-up check. Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
Config.Draw.avoidLastLocations = 0

-- ============================================================================
--                                    STUBS
-- ============================================================================

local officers = {
    [1] = { citizenid = 'VM00001' },
    [2] = { citizenid = 'VM00002' },
}
for src in pairs(officers) do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
CP.Access = {
    getOfficer = function(src)
        local p = officers[src]
        if not p then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = p.citizenid,
            name = 'Officer ' .. src,
            department = 'sast',
            departmentShort = 'SAST',
            job = 'police',
            rank = 'Trooper',
        }
    end,
    isAdmin = function() return false end,
    departmentForJob = function(name) return name == 'police' and { key = 'sast' } or nil end,
    offDepartmentForJob = function() return nil end,
}
CP.Units = {
    unitOf = function() return nil end,
    members = function(src) return { src } end,
    isLeader = function() return false end,
}
local created, runs = {}, {}
CP.Runs = {
    isOnMission = function() return false end,
    getBySrc = function() return nil end,
    capsOk = function() return true end,
    cooldowns = function() return { types = {}, missions = {} } end,
    completionsLastHour = function() return 0 end,
    completionsToday = function() return 0 end,
    create = function(opts)
        local run = { id = ('run-%d'):format(#created + 1), mission = opts.mission, state = 'accepted' }
        created[#created + 1] = opts
        runs[run.id] = run
        return run
    end,
    get = function(id) return runs[id] end,
    all = function() return runs end,
}
CP.Cash = {
    range = function() return 200, 300 end,
}

-- the volunteers' side (as in tests/volunteers_spec.lua)
local infos = {}
CP.Qbx = {
    getInfo = function(src) return infos[src] end,
    onPlayerUnload = function() end,
    onDutyChange = function() end,
    onJobChange = function() end,
}
CP.Opponents = {
    eligible = function() return true end,
    excluded = function() return false end,
    sampleCrew = function() return true end,
    unsampleCrew = function() return true end,
}
local function Civilian(src, cid)
    infos[src] = { citizenid = cid, license = 'license:' .. cid, name = 'Civ ' .. src, job = { name = 'unemployed' } }
end

-- blocks: one offers the runner where the location has a door, one offers nothing, one offers a broken slot
CP.Blocks.register('vm_runner', {
    volunteerSlot = function(_, _, location)
        if location.door then return { role = 'runner', meet = location.door } end
        return nil
    end,
})
CP.Blocks.register('vm_plain', {})
CP.Blocks.register('vm_broken', { volunteerSlot = 'runner' })
CP.Blocks.register('vm_wrong_role', {
    volunteerSlot = function() return { role = 'hostage' } end,
})

local function Loc(x, door)
    return { label = 'L' .. x, start = { coords = vec3(x + 0.0, 0.0, 30.0), radius = 40.0 }, door = door }
end
local enabled = {}
local missions = {
    {
        id = 'warrant_x',
        type = 'investigation',
        locations = { Loc(1000, vec3(1000.0, 5.0, 30.0)), Loc(3000) },
        objectives = { { block = 'vm_plain' }, { block = 'vm_runner' } },
    },
    { id = 'search_y', type = 'investigation', locations = { Loc(5000) }, objectives = { { block = 'vm_plain' } } },
    { id = 'odd_z', type = 'patrol', locations = { Loc(7000) }, objectives = { { block = 'vm_wrong_role' } } },
}
for _, d in ipairs(missions) do
    d.label, d.minOfficers, d.maxOfficers, d.difficulty, d.cooldown = d.id, 1, 4, 1, 900
    enabled[d.id] = true
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
    isEnabled = function(id) return enabled[id] == true end,
}

H.load('modules/realplayers/volunteers.lua')
H.load('modules/system/schedule.lua')
H.load('modules/draw/server.lua')
H.step(0)
local V, D = CP.Volunteers, CP.Draw
local WARRANT, SEARCH = missions[1], missions[2]

local function Ids(list)
    local out = {}
    for _, d in ipairs(list) do out[#out + 1] = d.id end
    table.sort(out)
    return table.concat(out, ',')
end
local function Card(src, key)
    for _, c in ipairs(D.boardCards(src).cards) do if c.key == key then return c end end
    return nil
end
local function Modes(types, byMission)
    Config.RealPlayers.volunteer.modes = { patrol = 'npc', training = 'npc', investigation = 'npc', tactical = 'npc' }
    for k, v in pairs(types or {}) do Config.RealPlayers.volunteer.modes[k] = v end
    Config.RealPlayers.volunteer.missionModes = byMission or {}
end

-- ============================================================================
--                1. SHIPPED: EVERY MODE 'npc', NOTHING CHANGES
-- ============================================================================

do
    local c = Config.RealPlayers.volunteer
    H.eq(c.enabled, false, 'volunteers ship off')
    for _, t in ipairs({ 'patrol', 'training', 'investigation', 'tactical' }) do
        H.eq(c.modes[t], 'npc', 'the ' .. t .. ' type ships npc')
    end
    H.ok(type(c.missionModes) == 'table' and next(c.missionModes) == nil, 'no mission has its own mode')
    H.eq(V.modeOf(WARRANT), 'npc', 'off: npc')
    Config.RealPlayers.volunteer.missionModes = { warrant_x = 'players_only' }
    H.eq(V.modeOf(WARRANT), 'npc', 'off: a mode set in config.lua changes nothing')
    H.eq(Ids(D.pool('investigation', { 1 })), 'search_y,warrant_x', 'off: the pool is the same')
    H.eq(Card(1, 'investigation').realSuspect, nil, 'off: the card says nothing about real suspects')
    Config.RealPlayers.volunteer.missionModes = {}
    Config.RealPlayers.volunteer.enabled = true
    H.eq(V.modeOf(WARRANT), 'npc', 'on with every mode npc: npc')
    H.eq(Ids(D.pool('investigation', { 1 })), 'search_y,warrant_x', 'on with every mode npc: the same pool')
    H.eq(Card(1, 'investigation').realSuspect, nil, 'on with every mode npc: no real-suspect card')
end

-- ============================================================================
--                   2. THE volunteerSlot REGISTRY AND MODES
-- ============================================================================

do
    H.eq(table.concat(CP.Blocks.withSlot(), ','), 'vm_runner,vm_wrong_role', 'the blocks that offer a slot')
    H.eq(CP.Blocks.get('vm_broken').volunteerSlot, nil, 'a volunteerSlot that is no function is dropped')
    local slot = V.slotOf(WARRANT, 1)
    H.ok(slot and slot.role == 'runner' and slot.obj == 2, 'location 1: the runner of objective 2')
    H.eq(V.slotOf(WARRANT, 2), nil, 'location 2 has no door: no slot')
    H.eq(V.slotOf(missions[3], 1), nil, 'a role no volunteer can pick is no slot')
    H.ok(V.canTake(WARRANT) and not V.canTake(SEARCH), 'canTake: only a mission with a slot')
    Modes({ investigation = 'players_when_available' }, { search_y = 'players_only', odd_z = 'bogus' })
    H.eq(V.modeOf(WARRANT), 'players_when_available', 'the type\'s mode')
    H.eq(V.modeOf(SEARCH), 'players_only', 'a mission\'s own mode beats its type')
    H.eq(V.modeOf(missions[3]), 'npc', 'a value that is no mode counts as npc')
    H.eq(V.modeOf({ id = 'boss', type = 'tactical', isBoss = true }), 'npc', 'never the Weekly Boss')
end

-- ============================================================================
--                              3. 'players_only'
-- ============================================================================
-- THE DRAW FILTER, THE CARD AND WHO IS FREE.

Civilian(11, 'CIV00011')
do
    Modes({}, { warrant_x = 'players_only' })
    H.eq(Ids(D.pool('investigation', { 1 })), 'search_y', 'without "Real suspect OK" a players_only mission is out')
    H.eq(Ids(D.pool('investigation', { 1 }, { realSuspect = true })), 'search_y', 'ticked, but nobody is free')
    local card = Card(1, 'investigation')
    H.eq(card.realSuspect, nil, 'no volunteer: the card does not offer it')

    H.eq(V.join(11, { runner = true }), true, 'a volunteer who plays the runner')
    H.eq(Ids(D.pool('investigation', { 1 }, { realSuspect = true })), 'search_y,warrant_x', 'ticked: it is in')
    H.eq(Ids(D.pool('investigation', { 1 })), 'search_y', 'not ticked: still out')
    card = Card(1, 'investigation')
    H.ok(card.realSuspect and card.realSuspect.required == false and card.realSuspect.available == 1,
        'the card: Real suspect OK offered, not required, one volunteer free')
    H.eq(card.pool, 2, 'the card counts the mission')

    -- a type set to players_only: only missions a volunteer can play, only while one is free
    Modes({ investigation = 'players_only' })
    card = Card(1, 'investigation')
    H.ok(card.realSuspect and card.realSuspect.required == true, 'every mission needs the tick')
    H.eq(card.pool, 1, 'the mission with no slot is never drawn')
    V.setRoles(11, { driver = true })
    card = Card(1, 'investigation')
    H.ok(card.locked and card.locked.reason == 'No volunteer suspect is free for Investigation right now',
        'nobody who fits: the card is locked and says why')
    local list, reason = D.pool('investigation', { 1 })
    H.ok(#list == 0 and reason == 'board.locked_real_suspect', 'not ticked: the reason is the tick')
    V.setRoles(11, { runner = true })
end

-- ============================================================================
--                                  4. ACCEPT
-- ============================================================================
-- THE TICK, THE HELD VOLUNTEER, run.volunteer, RELEASE.

do
    Modes({ investigation = 'players_only' })
    local ok, err = D.accept(1, 'investigation', {})
    H.ok(ok == false and err == 'err.real_suspect_needed', 'no tick: refused with the reason')
    H.eq(#created, 0, 'no run')

    ok = D.accept(1, 'investigation', { realSuspect = true })
    H.eq(ok, true, 'ticked with a free volunteer: accepted')
    local opts = created[1]
    H.ok(opts and opts.mission.id == 'warrant_x' and opts.locationIndex == 1, 'drawn: the location with the slot')
    H.ok(
        opts.volunteer and opts.volunteer.mode == 'players_only' and opts.volunteer.role == 'runner'
            and opts.volunteer.obj == 2,
        'the run carries the slot (mode, role, objective)'
    )
    H.eq(opts.volunteer.cid, nil, 'never who plays him')
    H.eq(V.reservedFor('run-1'), 'CIV00011', 'the volunteer is held for that run')
    H.eq(#V.available(), 0, 'held: nobody else can count on him')
    H.ok(Card(2, 'investigation').locked ~= nil, 'another unit\'s card is locked meanwhile')
    ok, err = D.accept(2, 'investigation', { realSuspect = true })
    H.ok(ok == false and err == 'err.volunteer_none', 'another unit: nobody free')

    CP.Hooks.fire('run:ended', runs['run-1'], 'completed')
    H.eq(V.reservedFor('run-1'), nil, 'the run ended: he is free again')
    H.eq(#V.available(), 1, 'available again')

    -- Z6: his window ends before the next sweep: the draw no longer counts on him
    local keepTime = H.time
    local entry = V.list()[1]
    H.time = entry.untilAt
    H.eq(#V.available(), 0, 'his window has ended (no sweep yet): not available')
    H.eq(select(2, V.drawGate(WARRANT, true)), 'no_volunteer', 'and a players_only mission stays closed')
    H.time = keepTime
    H.eq(#V.available(), 1, 'inside his window: available')

    -- a hold ends when his listing ends
    H.ok(V.reserve('tok', WARRANT, 1) == 'CIV00011', 'held by a pending accept')
    V.stop(11)
    H.eq(V.reservedFor('tok'), nil, 'he stopped volunteering: the hold is gone')
    H.eq(V.reserve('tok', WARRANT, 1), nil, 'nobody to hold')
end

-- ============================================================================
--               5. 'players_when_available' AND PUSHED MISSIONS
-- ============================================================================

do
    Modes({ investigation = 'players_when_available' })
    enabled.search_y = false
    local before = #created
    for id in pairs(runs) do D.release(id) end
    H.eq(D.accept(1, 'investigation', {}), true, 'no tick: accepted')
    H.eq(created[before + 1].volunteer, nil, 'no tick: the NPC plays him')
    -- the location is drawn at random: location 1 has the runner's slot, location 2 none (the NPC there)
    local seen = {}
    for n = 1, 40 do
        for id in pairs(runs) do
            D.release(id)
        end -- the locations are free again
        H.eq(D.accept(1, 'investigation', { realSuspect = true }), true, 'ticked, nobody listed: accepted')
        local opts = created[#created]
        local v = opts.volunteer
        if opts.locationIndex == 1 then
            H.ok(v and v.mode == 'players_when_available' and v.role == 'runner' and v.obj == 2,
                'ticked, a location with a slot: marked for a match')
        else
            H.eq(v, nil, 'ticked, a location with no slot: the NPC')
        end
        H.eq(V.reservedFor('run-' .. #created), nil, 'nobody is held for players_when_available')
        seen[opts.locationIndex] = true
        if seen[1] and seen[2] and n > 1 then break end
    end
    H.ok(seen[1] and seen[2], 'players_when_available keeps both locations (no slot = the NPC)')
    enabled.search_y = true

    Modes({}, { warrant_x = 'players_only' })
    local def, err = D.checkMission('warrant_x', 'investigation', { 1 })
    H.ok(def == nil and err == 'err.mc_push_volunteer', 'a players_only mission is never pushed')
    H.ok(D.checkMission('search_y', 'investigation', { 1 }) ~= nil, 'another mission still is')
end

-- ============================================================================
--                            6. THE START-UP CHECK
-- ============================================================================

do
    local function Texts()
        local out = {}
        for _, l in ipairs(V._modesHealth()) do out[#out + 1] = l.level .. ':' .. l.text end
        return table.concat(out, '\n')
    end
    Config.RealPlayers.volunteer.enabled = false
    H.ok(Texts():find('ok:Volunteer suspects are off', 1, true) ~= nil, 'off: one ok line')
    Config.RealPlayers.volunteer.enabled = true
    Modes({ patrol = 'players_only', ghost = 'npc' },
        { search_y = 'players_when_available', nope = 'npc', warrant_x = 'everyone' })
    local t = Texts()
    H.ok(t:find('warn:Config.RealPlayers.volunteer names ghost', 1, true) ~= nil, 'an unknown type is named')
    H.ok(t:find('warn:Config.RealPlayers.volunteer names nope', 1, true) ~= nil, 'an unknown mission is named')
    H.ok(t:find('sets warrant_x to \'everyone\'', 1, true) ~= nil, 'a value that is no mode is named')
    H.ok(t:find('patrol is set to players_only, but none of its missions', 1, true) ~= nil,
        'players_only with no slot: never offered')
    H.ok(t:find('search_y is set to players_when_available, but none', 1, true) ~= nil,
        'players_when_available with no slot: the NPC')
    Modes({}, { warrant_x = 'players_only' })
    H.ok(Texts():find('ok:Volunteer suspects: 1 missions', 1, true) ~= nil, 'the ok line counts the missions')
    H.ok(Texts():find('warn:', 1, true) == nil, 'a good setting: no warning')
end

-- ============================================================================
--                                 7. SETTINGS
-- ============================================================================

do
    H.load('modules/settings/server.lua')
    local S = CP.Settings
    H.ok(S.check('RealPlayers.volunteer.modes', { patrol = 'players_only' }), 'a mode per type is accepted')
    H.ok(not S.check('RealPlayers.volunteer.modes', { patrol = 'everyone' }), 'a value that is no mode is refused')
    H.ok(not S.check('RealPlayers.volunteer.modes', { heist = 'npc' }), 'a key that is no mission type is refused')
    H.ok(S.check('RealPlayers.volunteer.missionModes', { warrant_service = 'players_when_available' }),
        'a mode per mission is accepted')
    for _, path in ipairs({ 'RealPlayers.volunteer.modes', 'RealPlayers.volunteer.missionModes' }) do
        local e = S.entry(path) or {}
        H.ok(type(e.desc) == 'string' and e.desc ~= '', path .. ' has a description')
        H.ok(not e.restart and not e.money, path .. ' applies live and is no money switch')
    end
end

return H
