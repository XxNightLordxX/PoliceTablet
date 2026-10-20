-- The raids' crew staged ahead (hostile_waves stage = true, PLAN S4) on the real engine, the real blocks and the real

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
local Runs = CP.Runs

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
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission (stage = true loads)')
local HW = CP.Blocks.get('hostile_waves')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end

-- ============================================================================
--                       THE SHIPPED VALUES AND THE FILES
-- ============================================================================

H.eq(cfg.stageWakeRange, 12.0, 'a calm crew wakes when an officer comes within 12 m of one of them')
H.eq(cfg.stageAhead, true, 'staging ahead ships on')
for _, id in ipairs({ 'drug_lab_raid', 'gang_hideout_raid' }) do
    local def = Missions.get(id)
    H.eq(def.objectives[2].block, 'hostile_waves', id .. ': objective 2 is the fight')
    H.eq(def.objectives[2].stage, true, id .. ': the fight after the breach is staged in the file')
    H.eq(def.objectives[2].indoor, true, id .. ': and marked indoor')
    H.eq(def.objectives[1].points, 'entries', id .. ': objective 1 is the breach at the entries')
end
for _, id in ipairs({ 'gang_shootout', 'hostage_rescue', 'weekly_boss_kingpin' }) do
    for i, o in ipairs(Missions.get(id).objectives) do
        H.ok(o.stage == nil, ('%s: objective %d is not staged (only the raids are)'):format(id, i))
    end
end

-- ============================================================================
--                           CONSOLE, SPAWNS, WEAPONS
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    -- the harness's own failure lines still reach the runner
    if line:find('^  FAIL ') then realPrint(line) end
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end

-- every ped the engine creates, with the nearest officer (on the map) at that moment
local officers = {}
local spawns = {}
local realCreatePed = CreatePed
_G.CreatePed = function(t, model, x, y, z, h, ...)
    local near = math.huge
    for _, src in ipairs(officers) do
        local c = H.players[src].coords
        local d = math.sqrt((c.x - x) ^ 2 + (c.y - y) ^ 2)
        if d < near then near = d end
    end
    local handle = realCreatePed(t, model, x, y, z, h, ...)
    spawns[#spawns + 1] = { handle = handle, x = x, y = y, z = z, near = near, at = H.clockMs }
    return handle
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function Secs(n) W.tick(n) end
local function Place(src, p) W.place(src, p.x, p.y, p.z) end
local function Nearest(list)
    local m = math.huge
    for _, s in ipairs(list) do if s.near < m then m = s.near end end
    return m
end
local function SpawnedSince(from)
    local out = {}
    for i = (from or 0) + 1, #spawns do out[#out + 1] = spawns[i] end
    return out
end

-- A run of mission id at its location li: the breach (objective 1), the fight (objective 2, with obj's changes) and an
-- objective that holds the run open; the officers stand where the spec put them when it starts.
local function Raid(id, li, srcs, opts)
    opts = opts or {}
    local def = Missions.get(id)
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { def.locations[li] }
    local fight = U.deepcopy(def.objectives[2])
    for k, v in pairs(opts.obj or {}) do fight[k] = v end
    m.objectives = { U.deepcopy(def.objectives[1]), fight, { block = 'stub_hold', label = 'Hold' } }
    officers = srcs
    spawns = {}
    local run = W.start(srcs, m,
        { test = { adminSrc = srcs[1], forcedTier = opts.tier or 'standard' }, seed = opts.seed or 11 })
    return run, def.locations[li]
end
local function Fight(run) return Runs.ctx(run, 2) end
-- the fight's people, as the block keeps them
local function Crew(run)
    local out = {}
    for _, p in pairs(Fight(run).state.peds or {}) do out[#out + 1] = p end
    table.sort(out, function(a, b) return a.netId < b.netId end)
    return out
end
local function Staged(run)
    local out = {}
    for _, p in ipairs(Crew(run)) do if p.staged then out[#out + 1] = p end end
    return out
end
local function BagOf(p) return (W.bags[p.entity] or {}).cp or {} end
local function WeaponsFor(handle)
    local n = 0
    for _, w in ipairs(W.weapons) do if w.h == handle then n = n + 1 end end
    return n
end
local function At(p) return W.ent(p.entity).coords end
local function EndRun(run) if run.state ~= 'ended' then Runs.endRun(run, 'failed', 'test') end Secs(1) end

-- Both officers stack up at the two entries and breach together (the officers' interact events, as their games send
-- them after the progress bar).
local function Breach(run, loc, srcs)
    srcs = srcs or { 1, 2 }
    local ctx1 = Runs.ctx(run, 1)
    for k, src in ipairs(srcs) do Place(src, loc.entries[k]) end
    Secs(3)
    for k, src in ipairs(srcs) do
        local n = nil
        for i, p in ipairs(ctx1.state.points or {}) do
            if D2(p.coords, loc.entries[k]) < 0.1 then n = i end
        end
        H.fire(CP.e('server:objective'), src, run.id, 1, { type = 'interact', point = n })
    end
    H.step(0)
end

local function KillAll(run, obj)
    for _, e in ipairs(Runs.entitiesFor(run, { obj = obj or 2, kind = 'ped', alive = true })) do
        local m = W.ent(e.entity)
        if m and m.exists and (m.health or 0) > 0 then
            m.killer = 100
            m.health = 0
        end
    end
    Secs(2)
end

-- The last update the fight's client half got (server -> clients, objective 2).
local function LastUpdate(run)
    local last = nil
    for _, e in ipairs(H.findEvents(CP.e('client:objective'))) do
        if e.args[1] == run.id and e.args[2] == 2 and type(e.args[3]) == 'table' and e.args[3].action == 'update' then
            last = e.args[3].data
        end
    end
    return last
end

-- ============================================================================
--                   DRUG LAB RAID, WAREHOUSE, CYPRESS FLATS
-- ============================================================================
-- THE CREW IS INSIDE BEFORE THE BREACH.
-- The owner's check: before S4 the crew appeared the moment the breach completed (a1 4.1 item 1: 2.6-10.5 m from the
-- breach team); now they are placed while the officers drive in, and only wake when the fight starts.

do
    Reset()
    local def = Missions.get('drug_lab_raid')
    local loc = def.locations[3]
    H.eq(loc.label, 'Warehouse, Cypress Flats', 'location 3 is the Cypress Flats warehouse')
    Place(1, loc.start.coords)
    W.place(2, loc.start.coords.x + 3.0, loc.start.coords.y, loc.start.coords.z)
    local run = Raid('drug_lab_raid', 3, { 1, 2 })
    H.eq(run.state, 'in_progress', 'the run is in progress')
    H.eq(run.objectiveIndex, 1, 'objective 1 (the breach) is current')
    H.eq(#spawns, 0, 'nobody is placed before the first tick')

    Secs(1)
    local ctx = Fight(run)
    local goal = ctx.obj.waves[1]
    local staged = Staged(run)
    H.ok(goal >= 5, ('wave 1 has %d people at the standard tier'):format(goal))
    H.eq(#staged, goal, 'the whole of wave 1 is placed in the first tick, while the officers are at the start')
    H.eq(#spawns, goal, 'and nobody else')
    H.ok(Nearest(spawns) >= 15.0,
        ('every one at least minDistanceIndoor (15 m) from both officers (nearest %.1f m)'):format(Nearest(spawns)))
    H.eq(run.objectiveIndex, 1, 'the breach is still the current objective')
    H.eq(run.objectives[2].status, 'pending', 'the fight is still pending')
    H.eq(run.objectives[2].staged, true, 'the engine marked the fight staged')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead (objective 1 running)'), 1, 'one console line')
    local inside = 0
    for _, p in ipairs(staged) do
        for _, q in ipairs(loc.inside) do if D2(At(p), q) < 0.01 then inside = inside + 1 end end
    end
    H.ok(inside >= 1, ('the cooks\' guards are inside: %d of them on the "inside" points'):format(inside))
    local calm, unarmed, noBagWeapon, owned = 0, 0, 0, 0
    for _, p in ipairs(staged) do
        if CP.Npc.getState(p.netId) == 'idle' and p.state == 'idle' then calm = calm + 1 end
        if WeaponsFor(p.entity) == 0 and (W.ent(p.entity).armour or 0) == 0 then unarmed = unarmed + 1 end
        local bag = BagOf(p)
        if bag.armed == false and bag.state == 'idle' and (bag.cfg or {}).weapon == nil
            and (bag.cfg or {}).accuracy == nil then
            noBagWeapon = noBagWeapon + 1
        end
        if Runs.ownerOf(run, p.netId) == 2 then owned = owned + 1 end
    end
    H.eq(calm, goal, 'every staged one is calm (CP.Npc state idle)')
    H.eq(unarmed, goal, 'with no weapon and no armour given')
    H.eq(noBagWeapon, goal, 'and nothing of his weapon or fight settings in his replicated bag (he stands there calm)')
    H.eq(owned, goal, 'they belong to the fight (objective 2), so a failure or the end deletes them')
    H.eq(run.entities[staged[1].netId].armedTruth, true, 'the engine still counts each as armed (the armed cap)')
    H.eq(run.objectives[2].hud, nil, 'the HUD shows nothing of the fight before it starts')
    H.ok(LastUpdate(run) ~= nil and LastUpdate(run).awake == nil, 'the clients get the crew (calm, no awake flag)')

    Secs(5)
    H.eq(#Staged(run), goal, 'nothing more is placed while the officers wait at the start')
    H.eq(#LinesWith('staged hostile(s) woke'), 0, 'nobody wakes')

    -- they stack up at the entries: within 12 m of the guards inside, but at the breach entries
    Place(1, loc.entries[1])
    Place(2, loc.entries[2])
    local closest = math.huge
    for _, p in ipairs(Staged(run)) do
        for _, src in ipairs({ 1, 2 }) do closest = math.min(closest, D2(At(p), H.players[src].coords)) end
    end
    H.ok(closest < 12.0, ('a guard inside is %.1f m from the breach team'):format(closest))
    Secs(4)
    H.eq(#LinesWith('staged hostile(s) woke'), 0, 'officers at the breach entries do not wake them')
    for _, p in ipairs(Staged(run)) do H.eq(CP.Npc.getState(p.netId), 'idle', 'still calm at the door') end

    -- the breach: the fight starts and the crew wakes
    local before = #spawns
    Breach(run, loc)
    H.eq(run.objectives[1].status, 'done', 'the breach is done')
    H.eq(run.objectiveIndex, 2, 'the fight is current')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: ' .. goal .. ' staged hostile(s) woke: the fight started'), 1,
        'one console line: the whole crew woke when the fight started')
    local woke, armed, bagArmed = 0, 0, 0
    for _, p in ipairs(Staged(run)) do
        if CP.Npc.getState(p.netId) == 'hostile' and p.state == 'hostile' then woke = woke + 1 end
        if WeaponsFor(p.entity) == 1 then armed = armed + 1 end
        local bag = BagOf(p)
        local w = (bag.cfg or {}).weapon
        if bag.armed == true and bag.state == 'hostile' and type(w) == 'string' and w ~= ''
            and (bag.cfg or {}).accuracy ~= nil then
            bagArmed = bagArmed + 1
        end
    end
    H.eq(woke, goal, 'every staged one is hostile now')
    H.eq(armed, goal, 'each got his weapon now, once')
    H.eq(bagArmed, goal, 'and his weapon and fight settings in his bag')
    H.eq(#SpawnedSince(before), 0, 'nobody new appears at the breach: wave 1 was already there (no second wave)')
    H.eq(ctx.state.waves[1].spawned, goal, 'wave 1 counts the staged crew')
    H.ok(type(run.objectives[2].hud) == 'table' and run.objectives[2].hud.max ~= nil, 'the HUD shows the fight now')
    H.eq(LastUpdate(run) and LastUpdate(run).awake, nil, 'the client half runs it as the current objective')

    -- the fight goes on through the director as always: wave 2 at 15 m or more from the officers
    local t = 0
    while run.objectives[2].status ~= 'done' and t < 400 do
        KillAll(run, 2)
        t = t + 2
    end
    H.eq(run.objectives[2].status, 'done', 'the fight is won')
    local later = SpawnedSince(before)
    H.ok(#later >= 1, ('wave 2 came after the staged wave (%d)'):format(#later))
    H.ok(Nearest(later) >= 15.0, ('none of wave 2 within 15 m of the officers (nearest %.1f m)'):format(Nearest(later)))
    local total = 0
    for _, n in ipairs(ctx.obj.waves) do total = total + n end
    H.eq(goal + #later, total, 'every hostile of the fight appeared once: the staged ones counted toward it')
    H.eq(run.objectiveIndex, 3, 'the run moved on')
    EndRun(run)
end

-- ============================================================================
--                     THE OFFICERS ALREADY AT THE ENTRIES
-- ============================================================================
-- ONLY THE POINTS 15 M AWAY ARE USED.
-- No staged NPC within 15 m of an officer; the rest of wave 1 comes when the fight starts, as before.

for _, case in ipairs({ { 'drug_lab_raid', 1 }, { 'gang_hideout_raid', 5 } }) do
    Reset()
    local id, li = case[1], case[2]
    local loc = Missions.get(id).locations[li]
    Place(1, loc.entries[1])
    Place(2, loc.entries[2])
    local run = Raid(id, li, { 1, 2 }, { seed = 7 })
    Secs(3)
    local ctx = Fight(run)
    local n = #Staged(run)
    H.ok(n >= 1 and n < ctx.obj.waves[1],
        ('%s %s: %d of wave 1 (%d) staged, on the points far enough'):format(id, loc.label, n, ctx.obj.waves[1]))
    H.ok(Nearest(spawns) >= 15.0, ('%s: none within 15 m of an officer (nearest %.1f m)'):format(id, Nearest(spawns)))
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: '), 0, id .. ': and nobody woke')
    Breach(run, loc)
    H.eq(run.objectiveIndex, 2, id .. ': the fight started')
    H.ok(Nearest(spawns) >= 15.0,
        ('%s: nobody of wave 1 within 15 m at the breach either (nearest %.1f m)'):format(id, Nearest(spawns)))
    for _, p in ipairs(Crew(run)) do H.eq(p.state, 'hostile', id .. ': the whole crew fights') end
    EndRun(run)
end

-- ============================================================================
--                          AN EARLY WAKE: ONE IS HURT
-- ============================================================================

do
    Reset()
    local loc = Missions.get('drug_lab_raid').locations[3]
    Place(1, loc.start.coords)
    W.place(2, loc.start.coords.x + 3.0, loc.start.coords.y, loc.start.coords.z)
    local run = Raid('drug_lab_raid', 3, { 1, 2 })
    Secs(2)
    local staged = Staged(run)
    local goal = #staged
    H.ok(goal >= 5, 'the crew is staged')
    -- an officer shoots one through a window: the server's copy of his health drops
    W.ent(staged[2].entity).health = 150
    Secs(1)
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: ' .. goal .. ' staged hostile(s) woke: one of them was hurt'),
        1, 'one hurt: the whole crew wakes at once, one console line')
    for _, p in ipairs(Staged(run)) do
        H.eq(CP.Npc.getState(p.netId), 'hostile', 'every one of them is hostile')
        H.eq(BagOf(p).armed, true, 'and armed')
    end
    H.eq(run.objectiveIndex, 1, 'the breach is still current (they fight before it)')
    H.eq(LastUpdate(run) and LastUpdate(run).awake, true, 'the clients are told the crew woke (they run it now)')
    H.eq(run.objectives[2].hud, nil, 'the HUD stays the breach\'s')
    local before = #spawns
    Secs(5)
    H.eq(#spawns, before, 'nothing more is staged once they woke')
    Breach(run, loc)
    H.eq(run.objectiveIndex, 2, 'the breach completes: the fight starts')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: ' .. goal .. ' staged hostile(s) woke: the fight started'), 0,
        'they were awake already: no second wake')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: '), 1, 'one wake line in all')
    H.eq(Fight(run).state.waves[1].spawned, goal, 'wave 1 is still the staged crew')
    EndRun(run)
end

-- ============================================================================
--                  AN EARLY WAKE: ONE IS KILLED, ONE IS SHOT
-- ============================================================================

do
    Reset()
    local loc = Missions.get('drug_lab_raid').locations[3]
    Place(1, loc.start.coords)
    W.place(2, loc.start.coords.x + 3.0, loc.start.coords.y, loc.start.coords.z)
    local run = Raid('drug_lab_raid', 3, { 1, 2 })
    Secs(2)
    local staged = Staged(run)
    local m = W.ent(staged[1].entity)
    m.killer, m.health = 100, 0
    Secs(2)
    H.eq(#LinesWith(
        'run ' .. run.id .. ': objective 2: ' .. (#staged - 1) .. ' staged hostile(s) woke: one of them was killed'
    ), 1, 'one is killed: the others wake')
    H.eq(staged[1].state, 'dead', 'he counts as dead for the fight')
    H.eq(run.state, 'in_progress', 'a calm armed crew member is no surrendered suspect: no fail')
    for i = 2, #staged do H.eq(CP.Npc.getState(staged[i].netId), 'hostile', 'the others are hostile') end
    EndRun(run)

    -- the block's own damaged event (CP.Npc's dispatch) wakes them the same way
    run = Raid('drug_lab_raid', 3, { 1, 2 })
    Secs(2)
    staged = Staged(run)
    H.eq(Runs.dispatch(run, 2, 1, { type = 'damaged', netId = staged[3].netId, attacker = 1 }), true,
        'a damaged event reaches the pending fight')
    H.eq(
        #LinesWith('run ' .. run.id .. ': objective 2: ' .. #staged .. ' staged hostile(s) woke: one of them was hurt'),
        1, 'and wakes the crew')
    EndRun(run)
end

-- ============================================================================
--                                AN EARLY WAKE
-- ============================================================================
-- AN OFFICER WALKS UP TO ONE AWAY FROM THE ENTRIES.

do
    Reset()
    local loc = Missions.get('drug_lab_raid').locations[3]
    Place(1, loc.start.coords)
    W.place(2, loc.start.coords.x + 3.0, loc.start.coords.y, loc.start.coords.z)
    local run = Raid('drug_lab_raid', 3, { 1, 2 })
    Secs(2)
    -- the staged one furthest from the entries; officer 2 walks round to 8 m from him, away from the doors
    local far, farD = nil, -1
    for _, p in ipairs(Staged(run)) do
        local d = math.min(D2(At(p), loc.entries[1]), D2(At(p), loc.entries[2]))
        if d > farD then far, farD = p, d end
    end
    H.ok(farD > 16.0, ('one of them stands %.1f m from the nearest entry'):format(farD))
    local c = At(far)
    local ex, ey = c.x - loc.entries[1].x, c.y - loc.entries[1].y
    local len = math.sqrt(ex * ex + ey * ey)
    W.place(2, c.x + ex / len * 8.0, c.y + ey / len * 8.0, c.z)
    Secs(1)
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: '), 1, 'he is 8 m from one of them: the crew wakes')
    H.eq(#LinesWith('woke: officer 2 came within 8 m of one'), 1, 'the console names the officer and how close')
    EndRun(run)

    -- stageWakeRange = 0: walking up never wakes them, a hurt one still does
    cfg.stageWakeRange = 0
    run = Raid('drug_lab_raid', 3, { 1, 2 })
    Secs(2)
    local p = Staged(run)[1]
    local pc = At(p)
    W.place(2, pc.x + 2.0, pc.y, pc.z)
    Secs(3)
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: '), 0, 'stageWakeRange 0: an officer 2 m away wakes nobody')
    W.ent(p.entity).health = 120
    Secs(1)
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2: '), 1, 'a hurt one still wakes them')
    EndRun(run)
end

-- ============================================================================
--                  STAGING OFF: THE FIGHT STARTS AS BEFORE S4
-- ============================================================================

for _, off in ipairs({ { 'stageAhead', false }, { 'enabled', false }, { 'obj', false } }) do
    Reset()
    local loc = Missions.get('drug_lab_raid').locations[3]
    Place(1, loc.start.coords)
    W.place(2, loc.start.coords.x + 3.0, loc.start.coords.y, loc.start.coords.z)
    local opts = {}
    if off[1] == 'obj' then opts.obj = { stage = false } else cfg[off[1]] = off[2] end
    local run = Raid('drug_lab_raid', 3, { 1, 2 }, opts)
    Secs(4)
    local what = off[1] == 'obj' and 'stage = false in the file' or ('Config.Spawning.%s = false'):format(off[1])
    H.eq(#spawns, 0, what .. ': nobody is placed during the breach')
    H.eq(run.objectives[2].staged, nil, what .. ': the fight is not staged')
    Breach(run, loc)
    H.eq(run.objectiveIndex, 2, what .. ': the breach starts the fight')
    H.ok(#spawns >= 1, what .. ': the crew appears when the fight starts')
    local calm = 0
    for _, p in ipairs(Crew(run)) do if p.staged or p.state ~= 'hostile' then calm = calm + 1 end end
    H.eq(calm, 0, what .. ': hostile at once, as before')
    EndRun(run)
end

-- ============================================================================
--                         THE MISSION BUILDER'S CHECK
-- ============================================================================

do
    Reset()
    local loc = Missions.get('drug_lab_raid').locations[3]
    local builtin = { source = 'builtin' }
    local custom = { source = 'custom' }
    H.eq(HW.validate({ spawns = 'inside', stage = true }, builtin, loc), true, 'stage = true is fine')
    H.eq(HW.validate({ spawns = 'inside', stage = false }, builtin, loc), true, 'and false (the default)')
    local ok, why = HW.validate({ spawns = 'inside', stage = 'yes' }, builtin, loc)
    H.eq(ok, false, 'stage must be true or false')
    H.eq(why, CP.L('block.hostile_waves.invalid.stage'), 'with its own reason')
    H.ok(CP.L('block.hostile_waves.invalid.stage'):find('stage must be true', 1, true) ~= nil, 'in plain words')
    H.eq(select(2, HW.validate({ spawns = 'inside', stage = 1 }, custom, loc)),
        CP.L('block.hostile_waves.invalid.stage'), 'a custom mission gets the same check')
    H.ok(type(HW.stage) == 'function', 'the block exposes the stage hook')
end

_G.print = realPrint
Reset()
return H
