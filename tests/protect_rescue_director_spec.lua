-- Hostage Rescue's hostages through the spawn director (Config.Spawning.hostagesAt, PLAN S15) on the real engine, the
-- real blocks and the built-in mission file: they appear when their own objective starts (after the fight), not at
-- run start, never within minDistanceIndoor (15 m) of an officer, and after hostagesWaitMax on their spots anyway.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

for _, b in ipairs({
    'checkpoint_route',
    'interact_points',
    'skill_check',
    'hostile_waves',
    'protect_rescue',
    'flee_arrest',
    'pursuit',
    'escort',
    'search_area',
}) do
    H.load('blocks/' .. b .. '/server.lua')
end
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/server.lua')
local Missions = CP.Missions
local summary = Missions.loadAll()
CP.warn = realWarn
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission')

local cfg = Config.Spawning
H.eq(cfg.hostagesAt, 'objective', 'shipped: the hostages appear when their objective starts')
H.eq(cfg.hostagesWaitMax, 10, 'shipped: officers standing too close keep them waiting at most 10 s')

local warns = {}
CP.warn = function(tag, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    warns[#warns + 1] = { tag = tag, text = ok and text or fmt }
    return realWarn(tag, fmt, ...)
end
local function WarnsWith(text)
    local out = {}
    for _, w in ipairs(warns) do if w.text:find(text, 1, true) then out[#out + 1] = w end end
    return out
end

local function Secs(n) W.tick(n) end
local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local def = Missions.get('hostage_rescue')
local loc = def.locations[1]
H.eq(loc.label, 'Fleeca Bank, Legion Square', 'location 1 is the Legion Square Fleeca')
H.eq(def.objectives[2].block, 'protect_rescue', 'objective 2 frees the hostages')

-- The real Hostage Rescue at Legion Square (the fight, then the hostages), the officers at the start.
local function Rescue(srcs)
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { loc }
    for _, src in ipairs(srcs) do W.place(src, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z) end
    return W.start(srcs, m, { test = { adminSrc = srcs[1], forcedTier = 'standard' } })
end
local function Hostages(run)
    local out = {}
    for _, e in ipairs(CP.Runs.entitiesFor(run, { obj = 2, kind = 'ped' })) do
        if e.role == 'hostage' then out[#out + 1] = e end
    end
    return out
end
local function HostagesAnywhere(run)
    local n = 0
    for _, e in pairs(run.entities) do if e.role == 'hostage' then n = n + 1 end end
    return n
end
-- Every hostile of the fight down (an officer's shot), then the ticks until objective 2 is current.
local function EndFight(run)
    for _ = 1, 30 do
        for _, e in ipairs(CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })) do
            local m = W.ent(e.entity)
            if m and m.exists and (m.health or 0) > 0 then
                m.killer = 100
                m.health = 0
            end
        end
        Secs(1)
        if run.objectiveIndex == 2 or run.state == 'ended' then return end
    end
end
-- The nearest officer's distance (on the map) of every hostage, the smallest one.
local function Nearest(run, srcs)
    local best = math.huge
    for _, h in ipairs(Hostages(run)) do
        local c = W.ent(h.entity).coords
        for _, src in ipairs(srcs) do
            local d = D2(c, H.players[src].coords)
            if d < best then best = d end
        end
    end
    return best
end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end

-- ============================================================================
--               THE SHIPPED TIMING: WHEN THEIR OBJECTIVE STARTS
-- ============================================================================

do -- officers on the street outside: nobody during the fight, all three as the fight ends, 15 m or more away
    local before = #warns
    local run = Rescue({ 1, 2 })
    H.eq(run.state, 'in_progress', 'the run is in progress')
    H.eq(HostagesAnywhere(run), 0, 'no hostage at run start')
    Secs(5)
    H.ok(#CP.Runs.entitiesFor(run, { obj = 1, kind = 'ped' }) > 0, 'the hostage takers are in the bank')
    H.eq(HostagesAnywhere(run), 0, 'no hostage while the fight runs')
    H.eq(#WarnsWith('in prepare'), 0, 'the engine has nothing to say about prepare')
    EndFight(run)
    H.eq(run.objectiveIndex, 2, 'the fight is over: objective 2 is current')
    local hs = Hostages(run)
    H.eq(#hs, 3, 'all three hostages appear when their objective starts')
    H.ok(Nearest(run, { 1, 2 }) >= 15.0,
        ('never within minDistanceIndoor of an officer (nearest %.1f m)'):format(Nearest(run, { 1, 2 })))
    for i, h in ipairs(hs) do
        local c = W.ent(h.entity).coords
        local on = false
        for _, p in ipairs(loc.hostages) do on = on or D2(c, p) < 0.01 end
        H.ok(on, ('hostage %d kneels on one of the bank\'s hostage points'):format(i))
    end
    H.eq(#warns - before, 0, 'no warning')
    EndRun(run)
end

do -- an officer inside, beside the hostages, when the fight ends: they wait until he steps back
    local run = Rescue({ 1 })
    Secs(3)
    local h1 = loc.hostages[1]
    W.place(1, h1.x + 4.0, h1.y, h1.z)
    EndFight(run)
    H.eq(run.objectiveIndex, 2, 'objective 2 is current')
    H.eq(#Hostages(run), 0, 'an officer 4 m from their points: no hostage pops up next to him')
    Secs(3)
    H.eq(#Hostages(run), 0, 'still none while he stands there')
    -- out of the door, 20 m from every point
    W.place(1, h1.x + 22.0, h1.y + 4.0, h1.z)
    Secs(2)
    H.eq(#Hostages(run), 3, 'he stepped back: all three appear')
    H.ok(Nearest(run, { 1 }) >= 15.0, ('15 m or more from him (nearest %.1f m)'):format(Nearest(run, { 1 })))
    H.eq(#WarnsWith('hostagesWaitMax'), 0, 'no warning: they did not have to come closer')
    EndRun(run)
end

do -- an officer who stays beside them: after hostagesWaitMax (10 s) they appear on their points anyway
    local run = Rescue({ 1 })
    Secs(3)
    local h1 = loc.hostages[1]
    W.place(1, h1.x + 4.0, h1.y, h1.z)
    EndFight(run)
    H.eq(run.objectiveIndex, 2, 'objective 2 is current')
    Secs(6)
    H.eq(#Hostages(run), 0, 'none after 6 s')
    Secs(6)
    H.eq(#Hostages(run), 3, 'after hostagesWaitMax they appear anyway (the rescue never stalls)')
    local w = WarnsWith('Config.Spawning.hostagesWaitMax')
    H.eq(#w, 1, 'with one warning')
    H.ok(w[1] and w[1].text:find('Fleeca Bank, Legion Square', 1, true) ~= nil, 'naming the place')
    Secs(3)
    H.eq(#WarnsWith('Config.Spawning.hostagesWaitMax'), 1, 'said once')
    EndRun(run)
end

-- ============================================================================
--                     'runStart': AS BEFORE, AT RUN START
-- ============================================================================

do
    cfg.hostagesAt = 'runStart'
    local before = #warns
    local run = Rescue({ 1 })
    H.eq(#Hostages(run), 3, 'runStart: all three hostages at run start, before the fight')
    H.eq(run.objectiveIndex, 1, 'while objective 1 (the fight) is current')
    H.eq(#WarnsWith('in prepare'), 0, 'runStart asked for it: the engine does not warn')
    H.eq(#warns - before, 0, 'no warning at all')
    EndRun(run)
    cfg.hostagesAt = 'objective'
    -- the spawn director switched off: as before too
    cfg.enabled = false
    run = Rescue({ 1 })
    H.eq(#Hostages(run), 3, 'enabled = false: all three at run start, as before')
    EndRun(run)
    cfg.enabled = true
end

-- ============================================================================
--                                  THE ENGINE
-- ============================================================================
-- A BLOCK THAT MAKES ENTITIES IN PREPARE IS SAID ONCE.

do
    CP.Blocks.register('stub_prepare_spawn', {
        prepare = function(ctx)
            ctx.spawnPed({ model = 'a_m_y_hipster_01', coords = vec4(400.0, 400.0, 30.0, 0.0), role = 'subject' })
        end,
        start = function() end,
    })
    local m = W.mission({ { block = 'stub_prepare_spawn', label = 'Early' }, { block = 'stub_hold', label = 'Hold' } })
    W.place(1, 100.0, 100.0, 30.0)
    local run = W.start({ 1 }, m)
    local w = WarnsWith('in prepare')
    H.eq(#w, 1, 'a block that makes an entity in prepare: one warning')
    H.ok(w[1] and w[1].text:find('stub_prepare_spawn', 1, true) ~= nil, 'naming the block')
    H.ok(w[1] and w[1].text:find('made 1 entity', 1, true) ~= nil, 'and how many it made')
    EndRun(run)
    run = W.start({ 1 }, m)
    H.eq(#WarnsWith('in prepare'), 1, 'said once per block, not every run')
    EndRun(run)
end

return H
