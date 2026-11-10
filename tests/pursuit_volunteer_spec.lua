-- Pursuit's volunteer slot (docs/dev/ARCHITECTURE.md §7.3): Street Race Bust's driver (stop mode, no contact
-- hand-off) played by a volunteer in his own car. The real engine and block; CP.Volunteers.matchView (ctx.volunteer())
-- and CP.Opponents.view / caseOf are stubs the spec sets, so only the block's own rules are under test here.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

H.load('blocks/pursuit/server.lua')
for _, b in ipairs({ 'field_contact' }) do H.load('blocks/' .. b .. '/server.lua') end
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/missions.lua')
local Missions = CP.Missions
Missions.loadAll()
CP.warn = realWarn
H.load('modules/runs/spawn.lua')
local P = CP.Blocks.get('pursuit')

-- ============================================================================
--                                   THE SLOT
-- ============================================================================

do
    local def = Missions.get('street_race_bust')
    local loc = def.locations[1]
    H.eq(type(P.volunteerSlot), 'function', 'pursuit offers a volunteer slot')
    local found = false
    for _, id in ipairs(CP.Blocks.withSlot()) do if id == 'pursuit' then found = true end end
    H.ok(found, 'CP.Blocks.withSlot() lists pursuit')
    local slot = P.volunteerSlot(def.objectives[1], def, loc)
    H.eq(slot and slot.role, 'driver', 'Street Race Bust: the racer is a driver slot')
    local grid = loc.spawns[1]
    H.ok(slot and math.abs(slot.meet.x - grid.x) < 0.01 and math.abs(slot.meet.y - grid.y) < 0.01,
        'the meet point is the first grid slot')
    for _, id in ipairs({ 'stolen_vehicle_takedown', 'pursuit_sim', 'traffic_enforcement' }) do
        local m = Missions.get(id)
        for _, obj in ipairs(m.objectives) do
            if obj.block == 'pursuit' then
                H.eq(P.volunteerSlot(obj, m, m.locations[1]), nil,
                    id .. ': follow, contact hand-off or observe: no slot')
            end
        end
    end
end

-- ============================================================================
--                                   THE RUNS
-- ============================================================================

local view = nil                  -- what ctx.volunteer() answers
local case = nil                  -- what CP.Opponents.view answers
local rec = nil                   -- his server-only record (CP.Opponents.caseOf)
CP.Volunteers = CP.Volunteers or {}
CP.Volunteers.matchView = function(_, index) return index == 1 and view and U.copy(view) or nil end
CP.Opponents = CP.Opponents or {}
local realView, realCaseOf = CP.Opponents.view, CP.Opponents.caseOf
CP.Opponents.view = function() return case end
CP.Opponents.caseOf = function()
    return rec and { index = 1, order = { 'VOL1' }, suspects = { VOL1 = rec } } or nil
end

local function Secs(n) W.tick(n) end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end
local function Cars(run) return #(run.objectives[1].state.vorder or {}) end
local function Real(phase) return { role = 'driver', mode = 'players_when_available', phase = phase, real = true } end
local function Case(state, share)
    return {
        index = 1,
        order = { 'VOL1' },
        suspects = { VOL1 = { cid = 'VOL1', label = 'A', state = state, share = share } },
    }
end
local function Opp(run, kind) CP.Runs.dispatch(run, 1, nil, { type = kind, cid = 'VOL1', label = 'A' }) end

local def = Missions.get('street_race_bust')
local loc = def.locations[1]
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

-- A volunteer drives: no NPC racer (driverNpcCars ships false), the pointer stays on the grid until his first
-- report, then his last-reported point only; a detain with a share completes the objective.
do
    H.eq(Config.RealPlayers.volunteer.driverNpcCars, false, 'driverNpcCars ships false')
    H.eq(Config.RealPlayers.volunteer.driverReportEvery, 30, 'a last-reported point every 30 s')
    view, case, rec =
        Real('travel'), Case('free'), { label = 'A', state = 'free', src = 9, lastCoords = loc.start.coords }
    local run = Run()
    Secs(3)
    H.eq(Cars(run), 0, 'a volunteer drives: no NPC racer is made')
    local ctx = CP.Runs.ctx(run, 1)
    local mk = P.marker(ctx)
    H.eq(mk and mk.kind, 'point', 'while he travels the pointer is the grid point')
    H.ok(mk and math.abs(mk.coords.x - loc.spawns[1].x) < 0.01, 'the grid point, never where he is')
    view = Real('engaged')
    local there = { x = 100.0, y = 200.0, z = 30.0 }
    rec.lastCoords = there
    Secs(1)
    mk = P.marker(ctx)
    H.eq(mk and mk.kind, 'targets', 'once engaged the pointer is his last-reported point')
    H.eq(mk and mk.targets[1] and mk.targets[1].key, 'last:driver', 'keyed last:driver')
    H.eq(mk and mk.targets[1] and mk.targets[1].coords.x, 100.0, 'where the server last saw him')
    rec.lastCoords = { x = 900.0, y = 900.0, z = 30.0 }
    Secs(10)
    H.eq(P.marker(ctx).targets[1].coords.x, 100.0, 'between reports the point stays: never followed live')
    Secs(25)
    H.eq(P.marker(ctx).targets[1].coords.x, 900.0, 'the next report moves it')
    local check = P.checklist(ctx)
    H.eq(check[1].max, 1, 'his car is the one to stop')
    H.eq(run.objectives[1].status, 'active', 'the objective runs until he is caught')
    case = Case('detained', 0)
    Opp(run, 'opp_detained')
    Secs(1)
    H.eq(run.objectives[1].status, 'active', 'an AFK catch (share 0) never completes it (afkCatchVoids ships true)')
    case = Case('detained', 1)
    Opp(run, 'opp_detained')
    Secs(6)  -- the objective's minSeconds (45)
    H.eq(run.objectives[1].status, 'done', 'detained with a share: the race driver is in custody')
    H.eq(ctx.state.detained, 1, 'he counts as one detained racer')
    EndRun(run)
end

-- He got away (CP.Opponents' lost rule): the objective fails like an escaped NPC.
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

-- driverNpcCars = true: the other racers still come; he takes one car's place.
do
    Config.RealPlayers.volunteer.driverNpcCars = true
    view, case, rec = Real('in_position'), Case('free'), nil
    local run = Run()
    Secs(3)
    H.eq(Cars(run), 2, 'driverNpcCars true: two NPC racers beside him')
    Config.RealPlayers.volunteer.driverNpcCars = false
    EndRun(run)
end

-- Still asking: no racer yet; nobody said yes (the NPC plays him): the racers come, as today.
do
    view, case, rec = { role = 'driver', phase = 'asking', real = false }, nil, nil
    local run = Run()
    Secs(3)
    H.eq(Cars(run), 0, 'while volunteers are asked no racer is made')
    H.eq(run.objectives[1].state.fled, nil, 'and the race has not started')
    view = { role = 'driver', phase = 'npc', real = false }
    Secs(3)
    H.eq(Cars(run), 3, 'the NPCs play: three racers, as today')
    H.eq(run.objectives[1].state.fled, true, 'and they race')
    EndRun(run)
end

-- The run ends for want of a volunteer (phase void): nothing spawns. No match: exactly as today.
do
    view = { role = 'driver', phase = 'void', real = false }
    local run = Run()
    Secs(3)
    H.eq(Cars(run), 0, 'void: no racer is made while the run ends')
    EndRun(run)
    view = nil
    run = Run()
    Secs(3)
    H.eq(Cars(run), 3, 'no volunteer: three NPC racers')
    EndRun(run)
end

CP.Opponents.view, CP.Opponents.caseOf = realView, realCaseOf
return H
