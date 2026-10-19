-- flee_arrest through the spawn director (Config.Spawning, PLAN S11) on the real engine, the real block and the

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
H.load('modules/spawn/server.lua')
local FA = CP.Blocks.get('flee_arrest')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end
H.eq(cfg.associatesAtKnock, true, 'a warrant\'s associates appear at the knock (ships on)')

-- ============================================================================
--                          CONSOLE, WARNINGS, SPAWNS
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

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- every ped the engine creates: where, the nearest officer (2D) at that moment, and the nearest other ped of the
-- run standing then (never two inside each other)
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
    local other = math.huge
    for _, s in ipairs(spawns) do
        local m = W.ent(s.handle)
        if m and m.exists then
            local d = math.sqrt((m.coords.x - x) ^ 2 + (m.coords.y - y) ^ 2)
            if d < other then other = d end
        end
    end
    local handle = realCreatePed(t, model, x, y, z, h, ...)
    spawns[#spawns + 1] = { handle = handle, x = x, y = y, z = z, near = near, other = other }
    return handle
end

local function Secs(n) W.tick(n) end
local function Place(src, p) W.place(src, p.x, p.y, p.z) end
local function SpawnedSince(from)
    local out = {}
    for i = (from or 0) + 1, #spawns do out[#out + 1] = spawns[i] end
    return out
end
local function Nearest(list, key)
    local m = math.huge
    for _, s in ipairs(list) do if s[key or 'near'] < m then m = s[key or 'near'] end end
    return m
end
local function Event(src, run, ev) H.fire('crimson-police:server:objective', src, run.id, 1, ev) end
local function EndRun(run) if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end Secs(1) end

-- A run of mission id at its location li with only objective index (obj's changes), then one that holds the run
-- open; opts.before = an objective put first. The officers stand where the spec put them.
local function Run(id, li, srcs, opts)
    opts = opts or {}
    local def = Missions.get(id)
    local m = {}
    for k, v in pairs(def) do m[k] = v end
    m.locations = { opts.location or def.locations[li] }
    local obj = U.deepcopy(def.objectives[opts.index or 1])
    for k, v in pairs(opts.obj or {}) do obj[k] = v end
    m.objectives = { obj, { block = 'stub_hold', label = 'Hold' } }
    if opts.before then table.insert(m.objectives, 1, opts.before) end
    m.scaling = opts.scaling or {}
    officers = srcs
    spawns = {}
    local run = W.start(srcs, m, { test = { adminSrc = srcs[1], forcedTier = opts.tier or 'standard' } })
    return run
end
local function Peds(run, role)
    local out = {}
    for _, e in ipairs(CP.Runs.entitiesFor(run, { kind = 'ped', role = role })) do out[#out + 1] = e end
    return out
end
-- Knock and announce: officer src at the door, a 3 s knock.
local function Knock(run, src, door)
    Place(src, door)
    Event(src, run, { type = 'knock_start' })
    Secs(3)
    Event(src, run, { type = 'knock' })
end
-- Degrees between the officer at the door's way in (from the start to the door) and his line to p.
local function OffWayIn(loc, p)
    local s, d = loc.start.coords, loc.door
    local fx, fy = d.x - s.x, d.y - s.y
    local vx, vy = p.x - d.x, p.y - d.y
    local c = (fx * vx + fy * vy) / (math.sqrt(fx * fx + fy * fy) * math.sqrt(vx * vx + vy * vy))
    return math.deg(math.acos(math.max(-1, math.min(1, c))))
end

local SURRENDER = { responses = { surrender = 1, flee = 0, fight = 0 } }

-- ============================================================================
--              WARRANT SERVICE: THE ASSOCIATES COME AT THE KNOCK
-- ============================================================================
-- Before (a1 4.1 item 4) the suspect and his armed associates appeared when the first officer was 50 m out, 7-17 m
-- beside the door: at the knock they turned hostile on the knocker's flank.

do
    local loc = Missions.get('warrant_service').locations[2]
    H.eq(loc.label, 'Forum Drive, Strawberry', 'location 2 is Forum Drive')
    Place(1, loc.start.coords)
    Place(2, loc.start.coords)
    local run = Run('warrant_service', 2, { 1, 2 }, { obj = SURRENDER })
    H.eq(run.state, 'in_progress', 'the run started at the street')
    Secs(5)
    H.eq(#spawns, 1, 'only the suspect waits (inside, at the door): no associate before the knock')
    H.eq(#Peds(run, 'associate'), 0, 'no associate in the run yet')
    Knock(run, 1, loc.door)
    Secs(1)
    local asc = Peds(run, 'associate')
    H.eq(#asc, 1, 'the associate comes out at the knock')
    local after = SpawnedSince(1)
    H.ok(Nearest(after) >= 15.0, ('15 m or more from every officer (nearest %.1f m)'):format(Nearest(after)))
    for _, sp in ipairs(after) do
        H.ok(OffWayIn(loc, sp) <= cfg.behindAngle,
            ('never behind the officer at the door (%.0f degrees off his way in)'):format(OffWayIn(loc, sp)))
    end
    H.eq(#LinesWith('associates[1] skipped: 7 m from Officer 1'), 1,
        'the console names the point 7 m from the knocker (associates[1])')
    H.eq(CP.Npc.getState(asc[1].netId), 'hostile', 'he fights at once')
    EndRun(run)
end

-- A heavier unit: two associates, never within 15 m of an officer, however long they wait.
do
    local loc = Missions.get('warrant_service').locations[2]
    Place(1, loc.start.coords)
    Place(2, loc.start.coords)
    local run = Run('warrant_service', 2, { 1, 2 },
        { obj = SURRENDER, tier = 'heavy', scaling = { 'objectives.1.associates.count' } })
    local want = CP.Runs.ctx(run, 1).obj.associates.count
    H.eq(want, 2, 'the heavy tier asks for two associates')
    Knock(run, 1, loc.door)
    Place(2, loc.door)
    Secs(30)
    local after = SpawnedSince(1)
    H.ok(#after >= 1, ('associates came out (%d)'):format(#after))
    H.ok(Nearest(after) >= 15.0, ('none within 15 m of an officer (nearest %.1f m)'):format(Nearest(after)))
    H.ok(Nearest(after, 'other') > 1.5, ('none on another person (nearest %.1f m)'):format(Nearest(after, 'other')))
    EndRun(run)
end

-- Grove Street: all four associate points lie on the flank of an officer at the door (106-111 degrees off his way
-- in, a1 4.1 item 4). The ones behind him wait while he stands there; from the street they come out.
do
    local loc = Missions.get('warrant_service').locations[1]
    H.eq(loc.label, 'Grove Street, Davis', 'location 1 is Grove Street')
    Place(1, loc.start.coords)
    Place(2, loc.start.coords)
    local run = Run('warrant_service', 1, { 1, 2 }, { obj = SURRENDER })
    Knock(run, 1, loc.door)
    Secs(5)
    for _, sp in ipairs(SpawnedSince(1)) do
        H.ok(OffWayIn(loc, sp) <= cfg.behindAngle and sp.near >= 15.0,
            ('an associate at Grove Street only ahead of and away from him (%.0f degrees, %.1f m)'):format(
                OffWayIn(loc, sp), sp.near))
    end
    H.eq(#LinesWith('associates[4] skipped: behind Officer 1'), 1, 'associates[4], 17 m away but behind him, waits')
    -- the suspect gave up at the door; the knocker walks him back to the street
    Place(1, loc.start.coords)
    Secs(2)
    H.eq(#Peds(run, 'associate'), 1, 'from the street the associate comes out')
    H.ok(Nearest(SpawnedSince(1)) >= 15.0, 'away from both officers')
    EndRun(run)
end

-- Off switches: associatesAtKnock = false, or the whole director off: they wait at their points from the start, as
-- before.
do
    local loc = Missions.get('warrant_service').locations[2]
    for _, case in ipairs({ { 'associatesAtKnock', false }, { 'enabled', false } }) do
        cfg[case[1]] = case[2]
        Place(1, loc.start.coords)
        Place(2, loc.start.coords)
        local run = Run('warrant_service', 2, { 1, 2 }, { obj = SURRENDER })
        Secs(1)
        H.eq(#Peds(run, 'associate'), 1, case[1] .. ' = false: the associate waits at his point from the start')
        EndRun(run)
        Reset()
    end
end

-- ============================================================================
--        THE SURRENDERING SUSPECT IS PUT ON THE GROUND AT THE DOOR STEP
-- ============================================================================
-- The server stands him in front of the door (SetEntityCoords): he waits frozen there until an officer's game has
-- put him on the ground (CP.Spawn.again, Config.Spawning.place).

do
    local loc = Missions.get('warrant_service').locations[2]
    Place(1, loc.start.coords)
    Place(2, loc.start.coords)
    local run = Run('warrant_service', 2, { 1, 2 }, { obj = SURRENDER })
    local sus = Peds(run, 'suspect')[1]
    local first = W.bags[sus.entity].cp.place
    H.ok(first and first.token, 'like every new person he waited for his placement where he appeared')
    -- an officer's game placed him there (the ask is over)
    H.fire('crimson-police:server:spawnPlaced', 2, run.id,
        { netId = sus.netId, token = first.token, result = 'placed', reason = 'ok', z = first.z })
    H.eq(W.bags[sus.entity].cp.place, nil, 'placed: the ask left his bag')
    local waitedAt = W.ent(sus.entity).coords
    Knock(run, 1, loc.door)
    H.eq(CP.Npc.getState(sus.netId), 'surrendered', 'he gave up at the door')
    local at = W.ent(sus.entity).coords
    local place = W.bags[sus.entity].cp.place
    H.ok(place ~= nil, 'moved to the door step: a new placement ask in his bag')
    H.ok(place and place.token ~= first.token, 'with a new token (an old answer is never taken)')
    H.ok(
        place and math.abs(place.x - at.x) < 0.01 and math.abs(place.y - at.y) < 0.01
            and math.abs(place.z - at.z) < 0.01,
        'at the door step, where the server stood him'
    )
    H.ok(
        place and place.from and math.abs(place.from.x - waitedAt.x) < 0.01
            and math.abs(place.from.y - waitedAt.y) < 0.01,
        'from = where he waited (the placer moves him first when the move has not reached its game yet)'
    )
    H.eq(place and place.kind, 'ped', 'a person')
    H.eq(CP.Spawn.waiting(run.id) >= 1, true, 'the server waits for an officer\'s game')
    H.fire('crimson-police:server:spawnPlaced', 1, run.id,
        { netId = sus.netId, token = place.token, result = 'placed', reason = 'snap', z = at.z - 0.4 })
    H.eq(W.bags[sus.entity].cp.place, nil, 'the knocker\'s game put him on the ground: the ask is over')
    H.eq(W.bags[sus.entity].cp.state, 'surrendered', 'and he is still surrendered')
    EndRun(run)
end

-- ============================================================================
--                                   SCATTER
-- ============================================================================
-- A POINT OF HIS OWN FOR EACH, NEVER ON ANOTHER PERSON.
-- Before (a1 4.1 item 2) the 2-3 cooks / runners of a raid appeared on ONE point, the extra ones 1.25 m copies of it
-- at the same height: people inside each other.

do
    local def = Missions.get('drug_lab_raid')
    local loc = def.locations[1]
    H.eq(#loc.cook, 1, 'Cabin, Raton Canyon has one cook point')
    -- an officer 300 m away: nobody appears yet (ctx.whenNear: activateRange 150 m)
    local far = vec3(loc.cook[1].x + 300.0, loc.cook[1].y, loc.cook[1].z)
    W.place(1, far.x, far.y, far.z)
    local run = Run('drug_lab_raid', 1, { 1 }, { index = 3, obj = { suspects = 3 } })
    warns = {}
    Secs(5)
    H.eq(#spawns, 0, 'nobody appears while no officer is within 150 m of the cook point')
    -- he drives up to the start, 57 m from the point
    Place(1, loc.start.coords)
    Secs(1)
    H.eq(#spawns, 1, 'one cook on the one point, at once')
    H.ok(Nearest(spawns) >= 40.0, ('40 m or more from the officer (%.1f m)'):format(Nearest(spawns)))
    H.eq(#WarnsWith('cook has 1 point(s) for 3 inmate(s)'), 1, 'one warning: the list is shorter than the cooks')
    Secs(5)
    H.eq(#spawns, 1, 'the others wait while he stands on the point')
    H.eq(#WarnsWith('cook has 1 point(s)'), 1, 'said once')
    -- the first cook runs off: the next comes out of the same spot
    local c1 = W.ent(spawns[1].handle)
    c1.coords = vec3(c1.coords.x + 30.0, c1.coords.y, c1.coords.z)
    Secs(1)
    H.eq(#spawns, 2, 'the next cook comes out once the point is free')
    H.ok(Nearest(spawns, 'other') > 1.5, ('never on another person (nearest %.1f m)'):format(Nearest(spawns, 'other')))
    H.eq(CP.Runs.ctx(run, 1).obj.suspects, 3, 'the count is unchanged')
    EndRun(run)
end

-- Gang Hideout Raid: the runners' only point is the lieutenant's spot, where he lies (a1: 0.00 m apart at all 7
-- hideouts). Nobody appears on him: after waveDelayMax the last resort (a ring round the point, never on him, and the
-- escape routes' first points) is offered to the director.
CP.Blocks.register('stub_body', {
    start = function(ctx)
        ctx.spawnPed({ model = 'g_m_y_ballaorig_01', coords = ctx.obj.at, role = 'boss', armed = false })
        ctx.complete()
    end,
})
do
    local def = Missions.get('gang_hideout_raid')
    local loc = def.locations[1]
    H.ok(D2(loc.runners[1], loc.lieutenant) < 0.01,
        'Yard, Murrieta Heights: the runners hide on the lieutenant\'s spot')
    Place(1, loc.start.coords)
    local run = Run('gang_hideout_raid', 1, { 1 }, {
        index = 3,
        obj = { suspects = 3 },
        before = { block = 'stub_body', label = 'Lieutenant', at = loc.lieutenant },
    })
    local body = Peds(run, 'boss')[1]
    H.ok(body ~= nil, 'the lieutenant lies on his spot')
    Secs(15)
    H.eq(#Peds(run, 'inmate'), 0, 'no runner appears on him')
    Secs(8)
    local runners = Peds(run, 'inmate')
    H.ok(#runners >= 1, ('after waveDelayMax the runners bolt from the last resort (%d)'):format(#runners))
    for _, r in ipairs(runners) do
        local c = W.ent(r.entity).coords
        H.ok(D2(c, loc.lieutenant) > 1.5, ('never on the lieutenant (%.2f m)'):format(D2(c, loc.lieutenant)))
    end
    H.ok(Nearest(SpawnedSince(1), 'other') > 1.5, 'nor on each other')
    H.ok(Nearest(SpawnedSince(1)) >= 20.0,
        ('and 20 m or more from the officer (%.1f m)'):format(Nearest(SpawnedSince(1))))
    EndRun(run)
end

-- ============================================================================
--                                A WORN-OUT ASK
-- ============================================================================
-- THE SUSPECTS WHO CANNOT APPEAR ARE LEFT OUT.
-- The officer stands on the only cook point: the first cook came out while he was away, he is cuffed, and the
-- others cannot come out for leaveOutAfter (45 s): they are left out and the objective can end.

do
    local def = Missions.get('drug_lab_raid')
    local loc = def.locations[1]
    Place(1, loc.start.coords)
    local tight = {}
    for k, v in pairs(loc) do tight[k] = v end
    tight.escapes = { { loc.cook[1] } }
    local run = Run('drug_lab_raid', 1, { 1 }, { index = 3, obj = { suspects = 2 }, location = tight })
    warns = {}
    Secs(1)
    local cook = Peds(run, 'inmate')[1]
    H.ok(cook ~= nil, 'the first cook came out')
    -- caught on his point; the officer stays beside him
    W.near(1, run, cook.netId, 1.0)
    Event(1, run, { type = 'aim', netId = cook.netId })
    Secs(6)
    H.fire('crimson-police:server:npcCuff', 1, run.id, cook.netId)
    Secs(1)
    H.eq(CP.Npc.getState(cook.netId), 'cuffed', 'he is cuffed')
    Secs(40)
    H.eq(#Peds(run, 'inmate'), 1, 'the second cook still cannot come out (the point is taken, the officer is on it)')
    Secs(10)
    H.eq(#WarnsWith('1 inmate(s) left out'), 1, 'after leaveOutAfter the second is left out, with a warning')
    Secs(10)
    H.eq(run.objectives[1].status, 'done', 'the objective ends with the one cook caught')
    EndRun(run)
end

-- ============================================================================
--                     THE DOOR SUSPECT: NEVER AT THE START
-- ============================================================================
-- A location with no suspect point: before, he appeared on the start marker, where the officers arrive.

do
    local loc = {}
    for k, v in pairs(Missions.get('warrant_service').locations[2]) do loc[k] = v end
    local ctx = {
        obj = FA.defaults(U.deepcopy(SURRENDER)),
        location = loc,
        state = {},
        run = { id = 'run-nosuspect', missionId = 'warrant_service', entities = {} },
        index = 1,
        rng = U.rng(7),
        canSpawn = function() return true end,
        spawnPed = function(o)
            spawns[#spawns + 1] = o
            return nil
        end,
        send = function() end,
        hud = function() end,
        participants = function() return {} end,
        coords = function() return nil end,
        choosePoints = function(list, n) return { table.unpack(list, 1, n) } end,
        whenNear = function() return true end,
    }
    ctx.obj.suspect = 'nobody'
    spawns, warns = {}, {}
    FA.start(ctx)
    H.eq(#spawns, 0, 'no suspect point: nobody appears, not on the start marker either')
    H.eq(#WarnsWith('has no nobody point: nobody waits at the door (never at the start point)'), 1,
        'one warning names the missing point')
    H.eq(FA.checklist(ctx)[2].done, true, 'the warrant goes on without him (nothing to arrest)')
end
_G.print = realPrint
return H
