-- search_area's volunteer slot (docs/ARCHITECTURE.md §7.3): Manhunt's fugitive played by a volunteer who hides
-- inside the search circle. The real engine and block; CP.Volunteers.matchView (ctx.volunteer()), its caseArea /
-- caseNote / outOfBounds and CP.Opponents.view / caseOf are stubs the spec sets, so only the block's rules are tested.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

H.load('blocks/search_area/server.lua')
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/server.lua')
local Missions = CP.Missions
Missions.loadAll()
CP.warn = realWarn
H.load('modules/spawn/server.lua')
local S = CP.Blocks.get('search_area')

local def = Missions.get('manhunt')
local loc = def.locations[1]

-- ============================================================================
--                                   THE SLOT
-- ============================================================================

do
    H.eq(type(S.volunteerSlot), 'function', 'search_area offers a volunteer slot')
    local found = false
    for _, id in ipairs(CP.Blocks.withSlot()) do if id == 'search_area' then found = true end end
    H.ok(found, 'CP.Blocks.withSlot() lists search_area')
    local slot = S.volunteerSlot(def.objectives[1], def, loc)
    H.eq(slot and slot.role, 'fugitive', 'Manhunt: the fugitive is a fugitive slot')
    local spot = loc.hiding[1]
    H.ok(slot and math.abs(slot.meet.x - spot.x) < 0.01 and math.abs(slot.meet.y - spot.y) < 0.01,
        'the meet point is the first hiding spot (inside the circle)')
end

-- ============================================================================
--                                   THE RUNS
-- ============================================================================

local view, case, rec = nil, nil, nil
local areas, notes, outs = {}, {}, 0
CP.Volunteers = CP.Volunteers or {}
local realV = {}
for _, k in ipairs({ 'matchView', 'caseArea', 'caseNote', 'outOfBounds' }) do realV[k] = CP.Volunteers[k] end
CP.Volunteers.matchView = function(_, index) return index == 1 and view and U.copy(view) or nil end
CP.Volunteers.caseArea = function(_, a)
    areas[#areas + 1] = a or false
    return true
end
CP.Volunteers.caseNote = function(_, kind, key)
    notes[#notes + 1] = key
    return true
end
CP.Volunteers.outOfBounds = function()
    outs = outs + 1
    return true
end
CP.Opponents = CP.Opponents or {}
local realView, realCaseOf = CP.Opponents.view, CP.Opponents.caseOf
CP.Opponents.view = function() return case end
CP.Opponents.caseOf = function()
    return rec and { index = 1, order = { 'VOL1' }, suspects = { VOL1 = rec } } or nil
end

local function Secs(n) W.tick(n) end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end
local function Fugs(run) return run.objectives[1].state.count or 0 end
local function Real(phase) return { role = 'fugitive', mode = 'players_when_available', phase = phase, real = true } end
local function Case(state, share)
    return {
        index = 1,
        order = { 'VOL1' },
        suspects = { VOL1 = { cid = 'VOL1', label = 'A', state = state, share = share } },
    }
end
local function Opp(run, kind) CP.Runs.dispatch(run, 1, nil, { type = kind, cid = 'VOL1', label = 'A' }) end
local function Rec(at) return { label = 'A', state = 'free', src = 9, lastCoords = at } end

local function Run()
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { loc }
    m.objectives = { U.deepcopy(def.objectives[1]), { block = 'stub_hold', label = 'Hold' } }
    m.scaling = {}
    local s = loc.start.coords
    W.place(1, s.x, s.y, s.z)
    W.place(2, s.x, s.y, s.z)
    return W.start({ 1, 2 }, m, { test = { adminSrc = 1, forcedTier = 'standard' } })
end

local spawning = Config.Spawning.enabled
Config.Spawning.enabled = false  -- everything when the search starts: the clues are there to check

-- A volunteer hides: no NPC fugitive (fugitiveNpcs ships false), his own map gets the circle, a clue shrinks the
-- circle towards where the server last saw him, and a detain with a share completes the objective.
do
    H.eq(Config.Volunteers.fugitiveNpcs, false, 'fugitiveNpcs ships false')
    H.eq(Config.Volunteers.fugitiveOutSeconds, 30, 'the circle rule allows 30 s outside')
    local spot = loc.hiding[3]
    view, case, rec = Real('in_position'), Case('free'), Rec(spot)
    areas = {}
    local run = Run()
    Secs(3)
    H.eq(Fugs(run), 0, 'a volunteer hides: no NPC fugitive is made')
    H.eq(areas[1] and areas[1].r, 600, 'his own map gets the 600 m circle')
    local ctx = CP.Runs.ctx(run, 1)
    local mk = S.marker(ctx)
    local onlyClues = mk ~= nil
    for _, t in ipairs(mk and mk.targets or {}) do
        if not (type(t.key) == 'string' and t.key:sub(1, 1) == 'c') then onlyClues = false end
    end
    H.ok(onlyClues, 'officers see the circle and the clues, never where he is')
    -- check one clue (the bag): the circle shrinks to 300 m around him
    local cl = ctx.state.clues[1]
    local cx, cy, cz = U.xyz(cl.coords)
    W.place(1, cx, cy, cz)
    CP.Runs.dispatch(run, 1, 1, { type = 'clue_start', clue = 1 })
    Secs(4)
    CP.Runs.dispatch(run, 1, 1, { type = 'clue', clue = 1 })
    Secs(1)
    local c = ctx.state.circle
    H.eq(c.radius, 300, 'the clue shrinks the circle to 300 m')
    H.ok(U.dist2d(c.center, spot) <= 300 * 0.7 + 0.01, 'the new circle is centred near where the server last saw him')
    H.eq(areas[#areas] and areas[#areas].r, 300, 'his map circle is redrawn at 300 m')
    local check = S.checklist(ctx)
    H.eq(check[2].max, 1, 'he is the one fugitive to catch')
    H.eq(run.objectives[1].status, 'active', 'the objective runs until he is caught')
    case = Case('detained', 0)
    Opp(run, 'opp_detained')
    Secs(1)
    H.eq(run.objectives[1].status, 'active', 'an AFK catch (share 0) never completes it (afkCatchVoids ships true)')
    case = Case('detained', 1)
    Opp(run, 'opp_detained')
    Secs(60)  -- the objective's minSeconds
    H.eq(run.objectives[1].status, 'done', 'detained with a share: the fugitive is in custody')
    H.eq(ctx.state.arrests, 1, 'he counts as one arrest')
    H.eq(areas[#areas], false, 'his map circle is removed once he is caught')
    EndRun(run)
end

-- The circle rule: once inside, outside the circle a warning, then after fugitiveOutSeconds his part is void (once).
-- Back inside in time resets it; 0 switches the rule off.
do
    view, case, rec = Real('engaged'), Case('free'), Rec(loc.hiding[1])
    notes, outs = {}, 0
    local run = Run()
    Secs(2)
    rec.lastCoords = { x = loc.center.x + 700.0, y = loc.center.y, z = loc.center.z }
    Secs(10)
    H.eq(notes[1], 'volunteer.case.out_warn', 'outside the circle: he is warned')
    H.eq(outs, 0, 'not void before fugitiveOutSeconds')
    rec.lastCoords = loc.hiding[1]
    Secs(2)
    rec.lastCoords = { x = loc.center.x + 700.0, y = loc.center.y, z = loc.center.z }
    Secs(25)
    H.eq(outs, 0, 'back inside in time: the clock started again')
    Secs(10)
    H.eq(outs, 1, 'outside for 30 s: his part is void (CP.Volunteers.outOfBounds)')
    Secs(10)
    H.eq(outs, 1, 'only once')
    EndRun(run)
    Config.Volunteers.fugitiveOutSeconds = 0
    outs = 0
    rec = Rec(loc.hiding[1])
    run = Run()
    Secs(2)
    rec.lastCoords = { x = loc.center.x + 700.0, y = loc.center.y, z = loc.center.z }
    Secs(40)
    H.eq(outs, 0, 'fugitiveOutSeconds = 0: no circle rule')
    Config.Volunteers.fugitiveOutSeconds = 30
    EndRun(run)
end

-- Travelling to his spot he may be outside the circle: no rule before in_position, and never before he was inside.
do
    view, case, rec = Real('travel'), Case('free'), Rec({ x = loc.center.x + 900.0, y = loc.center.y, z = 30.0 })
    outs = 0
    local run = Run()
    Secs(40)
    H.eq(outs, 0, 'travelling: no circle rule')
    view = Real('engaged')  -- contact before he reached the circle
    Secs(40)
    H.eq(outs, 0, 'never inside yet: no circle rule')
    EndRun(run)
end

-- He got away (CP.Opponents' lost rule): the objective fails like an escaped fugitive.
do
    view, case, rec = Real('engaged'), Case('free'), nil
    local run = Run()
    Secs(2)
    case = Case('lost')
    Opp(run, 'opp_lost')
    Secs(1)
    H.eq(run.state, 'ended', 'the volunteer got away: the run ends')
    H.eq(run.objectives[1].status ~= 'done', true, 'the objective is not done')
    EndRun(run)
end

-- fugitiveNpcs = true with two fugitives: one NPC hides beside him.
do
    Config.Volunteers.fugitiveNpcs = true
    view, case, rec = Real('in_position'), Case('free'), nil
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { loc }
    local o = U.deepcopy(def.objectives[1])
    o.fugitives = 2
    m.objectives = { o, { block = 'stub_hold', label = 'Hold' } }
    m.scaling = {}
    W.place(1, loc.start.coords.x, loc.start.coords.y, loc.start.coords.z)
    local run = W.start({ 1 }, m, { test = { adminSrc = 1, forcedTier = 'standard' } })
    Secs(3)
    H.eq(Fugs(run), 1, 'fugitiveNpcs true: one NPC fugitive beside him')
    H.eq(S.checklist(CP.Runs.ctx(run, 1))[2].max, 2, 'two fugitives to catch')
    Config.Volunteers.fugitiveNpcs = false
    EndRun(run)
end

-- Still asking: no fugitive yet and nothing completes; nobody said yes (the NPC plays him): as today.
do
    view, case, rec = { role = 'fugitive', phase = 'asking', real = false }, nil, nil
    local run = Run()
    Secs(3)
    H.eq(Fugs(run), 0, 'while volunteers are asked no fugitive is made')
    H.eq(run.objectives[1].status, 'active', 'and the search cannot complete')
    view = { role = 'fugitive', phase = 'npc', real = false }
    Secs(3)
    H.eq(Fugs(run), 1, 'the NPC plays: one fugitive, as today')
    EndRun(run)
    view = { role = 'fugitive', phase = 'void', real = false }
    run = Run()
    Secs(3)
    H.eq(Fugs(run), 0, 'void: no fugitive is made while the run ends')
    EndRun(run)
    view = nil
    run = Run()
    Secs(3)
    H.eq(Fugs(run), 1, 'no volunteer: one NPC fugitive')
    EndRun(run)
end

Config.Spawning.enabled = spawning
CP.Opponents.view, CP.Opponents.caseOf = realView, realCaseOf
for k, v in pairs(realV) do CP.Volunteers[k] = v end
return H
