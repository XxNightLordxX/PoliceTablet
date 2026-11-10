-- flee_arrest's volunteer slot (docs/ARCHITECTURE.md §7.3): Warrant Service's wanted person at the door played
-- by a volunteer runner. The real engine and block; CP.Volunteers.matchView (ctx.volunteer()) and CP.Opponents.view
-- are stubs the spec sets, so only the block's own rules are under test here.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

for _, b in ipairs({ 'interact_points', 'flee_arrest', 'process_scene' }) do H.load('blocks/' .. b .. '/server.lua') end
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/server.lua')
local Missions = CP.Missions
Missions.loadAll()
CP.warn = realWarn
H.load('modules/spawn/server.lua')
local FA = CP.Blocks.get('flee_arrest')

-- ============================================================================
--                                   THE SLOT
-- ============================================================================

do
    local def = Missions.get('warrant_service')
    local loc = def.locations[2]
    H.eq(type(FA.volunteerSlot), 'function', 'flee_arrest offers a volunteer slot')
    local found = false
    for _, id in ipairs(CP.Blocks.withSlot()) do if id == 'flee_arrest' then found = true end end
    H.ok(found, 'CP.Blocks.withSlot() lists flee_arrest')
    local slot = FA.volunteerSlot(def.objectives[1], def, loc)
    H.eq(slot and slot.role, 'runner', 'Warrant Service: the wanted person is a runner slot')
    H.ok(slot and math.abs(slot.meet.x - loc.suspect.x) < 0.01 and math.abs(slot.meet.y - loc.suspect.y) < 0.01,
        'the meet point is his door-step point')
    local noSuspect = U.copy(loc)
    noSuspect.suspect = nil
    H.eq(FA.volunteerSlot(def.objectives[1], def, noSuspect), nil, 'no suspect point: no slot')
    local pb = Missions.get('prison_break')
    for _, obj in ipairs(pb.objectives) do
        if obj.block == 'flee_arrest' then
            H.eq(FA.volunteerSlot(obj, pb, pb.locations[1]), nil, 'scatter mode (Prison Break): no slot')
        end
    end
end

-- ============================================================================
--                                   THE RUNS
-- ============================================================================

local view = nil                  -- what ctx.volunteer() answers
local case = nil                  -- what CP.Opponents.view answers
CP.Volunteers = CP.Volunteers or {}
CP.Volunteers.matchView = function(_, index) return index == 1 and view and U.copy(view) or nil end
CP.Opponents = CP.Opponents or {}
local realView = CP.Opponents.view
CP.Opponents.view = function() return case end

local function Secs(n) W.tick(n) end
local function Place(src, p) W.place(src, p.x, p.y, p.z) end
local function Event(src, run, ev) H.fire('crimson-police:server:objective', src, run.id, 1, ev) end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end
local function Peds(run, role) return CP.Runs.entitiesFor(run, { kind = 'ped', role = role }) end
local function Knock(run, src, door)
    Place(src, door)
    Event(src, run, { type = 'knock_start' })
    Secs(3)
    Event(src, run, { type = 'knock' })
end
local function Real(phase) return { role = 'runner', mode = 'players_when_available', phase = phase, real = true } end
local function Case(state, share)
    return {
        index = 1,
        order = { 'VOL1' },
        suspects = { VOL1 = { cid = 'VOL1', label = 'A', state = state, share = share } },
    }
end
local function Opp(run, kind) CP.Runs.dispatch(run, 1, nil, { type = kind, cid = 'VOL1', label = 'A' }) end

local loc = Missions.get('warrant_service').locations[2]
local function Run()
    local def = Missions.get('warrant_service')
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { loc }
    m.objectives = { U.deepcopy(def.objectives[1]), { block = 'stub_hold', label = 'Hold' } }
    m.scaling = {}
    Place(1, loc.start.coords)
    Place(2, loc.start.coords)
    return W.start({ 1, 2 }, m, { test = { adminSrc = 1, forcedTier = 'standard' } })
end

-- A volunteer plays him: no NPC at the door, no armed associate (doorAssociates ships false), the door stays the
-- pointer, and a detain with a share completes the objective.
do
    view, case = Real('travel'), Case('free')
    local run = Run()
    Secs(2)
    H.eq(#Peds(run, 'suspect'), 0, 'a volunteer plays the wanted person: no NPC waits at the door')
    Knock(run, 1, loc.door)
    Secs(3)
    H.eq(#Peds(run, 'associate'), 0, 'doorAssociates false: no armed associate comes out at the knock')
    local ctx = CP.Runs.ctx(run, 1)
    H.eq(ctx.state.knocked, true, 'the knock is taken')
    local mk = FA.marker(ctx)
    H.eq(mk and mk.key, 'door', 'the pointer stays on the door: never where the real player is')
    H.eq(run.objectives[1].status, 'active', 'the objective runs until he is caught')
    view = Real('engaged')
    case = Case('detained', 0)
    Opp(run, 'opp_detained')
    Secs(1)
    H.eq(run.objectives[1].status, 'active', 'an AFK catch (share 0) never completes it (afkCatchVoids ships true)')
    case = Case('detained', 1)
    Opp(run, 'opp_detained')
    H.eq(run.objectives[1].status, 'done', 'detained with a share: the wanted person is in custody')
    EndRun(run)
end

-- afkCatchVoids = false: the AFK catch counts like any other.
do
    Config.Volunteers.afkCatchVoids = false
    view, case = Real('engaged'), Case('free')
    local run = Run()
    Knock(run, 1, loc.door)
    case = Case('detained', 0)
    Opp(run, 'opp_detained')
    Secs(30)  -- the objective's minSeconds
    H.eq(run.objectives[1].status, 'done', 'afkCatchVoids false: an AFK catch completes the objective')
    Config.Volunteers.afkCatchVoids = true
    EndRun(run)
end

-- He got away (CP.Opponents' lost rule): the warrant fails like an escaped NPC.
do
    view, case = Real('engaged'), Case('free')
    local run = Run()
    Knock(run, 1, loc.door)
    case = Case('lost')
    Opp(run, 'opp_lost')
    Secs(1)
    H.eq(run.state, 'ended', 'the volunteer got away: the run ends')
    H.eq(run.objectives[1].status ~= 'done', true, 'the objective is not done')
    EndRun(run)
end

-- doorAssociates = true: the associates come out at the knock as usual.
do
    Config.Volunteers.doorAssociates = true
    view, case = Real('in_position'), Case('free')
    local run = Run()
    Knock(run, 1, loc.door)
    Secs(3)
    H.eq(#Peds(run, 'suspect'), 0, 'still no NPC at the door')
    H.eq(#Peds(run, 'associate'), 1, 'doorAssociates true: the associate comes out at the knock')
    Config.Volunteers.doorAssociates = false
    EndRun(run)
end

-- Still asking: nobody at the door yet; nobody said yes (the NPC plays him): the NPC appears, as today.
do
    view, case = { role = 'runner', phase = 'asking', real = false }, nil
    local run = Run()
    Secs(2)
    H.eq(#Peds(run, 'suspect'), 0, 'while volunteers are asked nobody waits at the door')
    view = { role = 'runner', phase = 'npc', real = false }
    Secs(2)
    H.eq(#Peds(run, 'suspect'), 1, 'the NPC plays him: he waits at the door as today')
    EndRun(run)
end

-- The run ends for want of a volunteer (phase void): nothing spawns.
do
    view, case = { role = 'runner', phase = 'void', real = false }, nil
    local run = Run()
    Secs(2)
    H.eq(#Peds(run, 'suspect') + #Peds(run, 'associate'), 0, 'void: nobody is spawned while the run ends')
    EndRun(run)
end

-- No match (Config.Volunteers off or mode npc): exactly as today.
do
    view, case = nil, nil
    local run = Run()
    Secs(2)
    H.eq(#Peds(run, 'suspect'), 1, 'no volunteer: the NPC waits at the door')
    EndRun(run)
end

-- Z10: presence measures to the volunteer runner's last server position, not to the door
do
    local realCaseOf = CP.Opponents.caseOf
    CP.Opponents.caseOf = function() return case end
    view, case = Real('engaged'), Case('free')
    local run = Run()
    Knock(run, 1, loc.door)
    local far = vec3(loc.door.x + 900.0, loc.door.y, loc.door.z)
    case.suspects.VOL1.lastCoords = vec3(far.x + 10.0, far.y, far.z)
    local ctx = CP.Runs.ctx(run, 1)
    local d = FA.presence(ctx, 1, far)
    H.ok(d < 50, 'Z10: an officer chasing the volunteer is in range of him (' .. tostring(d) .. ' m)')
    case.suspects.VOL1.lastCoords = nil
    H.ok(FA.presence(ctx, 1, far) > 800, 'Z10: without his position the door is the reference')
    CP.Opponents.caseOf = realCaseOf
    EndRun(run)
end

CP.Opponents.view = realView
return H
