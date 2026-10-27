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
-- open; opts.before = an objective put first; opts.seed = the run seed (W.start's fixed one by default). The officers
-- stand where the spec put them.
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
    local run = W.start(srcs, m,
        { seed = opts.seed, test = { adminSrc = srcs[1], forcedTier = opts.tier or 'standard' } })
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
-- at the same height: people inside each other. The built-in raids have a point for each since S21; a list shorter
-- than its people (a custom mission's, or the raids' before S21: one cook point, the runners on the lieutenant's spot)
-- still works as below.

-- loc with key's list cut to points (the lists as they were before S21)
local function Cut(loc, key, points)
    local out = {}
    for k, v in pairs(loc) do out[k] = v end
    out[key] = points
    return out
end

do
    local def = Missions.get('drug_lab_raid')
    local loc = Cut(def.locations[1], 'cook', { def.locations[1].cook[1] })
    H.eq(#loc.cook, 1, 'Cabin, Raton Canyon cut to one cook point')
    -- an officer 300 m away: nobody appears yet (ctx.whenNear: activateRange 150 m)
    local far = vec3(loc.cook[1].x + 300.0, loc.cook[1].y, loc.cook[1].z)
    W.place(1, far.x, far.y, far.z)
    local run = Run('drug_lab_raid', 1, { 1 }, { index = 3, obj = { suspects = 3 }, location = loc })
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

-- Gang Hideout Raid as it was before S21: the runners' only point is the lieutenant's spot, where he lies (a1: 0.00 m
-- apart at all 7 hideouts). Nobody appears on him: after waveDelayMax the last resort (a ring round the point, never on
-- him, and the escape routes' first points) is offered to the director.
CP.Blocks.register('stub_body', {
    start = function(ctx)
        ctx.spawnPed({ model = 'g_m_y_ballaorig_01', coords = ctx.obj.at, role = 'boss', armed = false })
        ctx.complete()
    end,
})
do
    local def = Missions.get('gang_hideout_raid')
    local loc = Cut(def.locations[1], 'runners', { def.locations[1].lieutenant })
    H.ok(D2(loc.runners[1], loc.lieutenant) < 0.01,
        'Yard, Murrieta Heights cut to the runners hiding on the lieutenant\'s spot')
    Place(1, loc.start.coords)
    local run = Run('gang_hideout_raid', 1, { 1 }, {
        index = 3,
        obj = { suspects = 3 },
        location = loc,
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

-- PLAN S21: THE BUILT-IN RAIDS AND PRISON BREAK'S SOUTH-WEST FENCE HAVE A POINT FOR EACH.
-- With the shipped files, as many people as the list has points, and at least as many as the largest team brings (the
-- real CP.Scaling count, the scaling entry's max applied: Gang Hideout Raid 4 runners for 3, the lieutenant lying on
-- his spot; Drug Lab Raid 3 cooks for 2; the south-west fence 8 inmates for 8), all come out at once, each on a point
-- of the file of his own, with the officer arriving at the start (Prison Break: 100 m out on the start's side, as the
-- start marker is 30-56 m from its points); no "has N point(s)" warning, nobody on another person or on the lieutenant,
-- and each runs the escape route that starts nearest him (OwnRoute).

-- the most people objective index of def brings: the real CP.Scaling count, the scaling entry's max applied
local function Most(def, index)
    local base, max = def.objectives[index].suspects, nil
    for _, e in ipairs(def.scaling or {}) do
        if type(e) == 'table' and e.path == ('objectives.%d.suspects'):format(index) then max = e.max end
    end
    local most = 0
    for n = def.minOfficers, def.maxOfficers do
        local k = CP.Scaling.scaleCount(base, CP.Scaling.tierFor(n))
        most = math.max(most, max and math.min(k, max) or k)
    end
    return most
end
-- the first point of the escape route the person e of run was given (his bag's fleePoints)
local function FleeStart(run, e)
    local rec = run.entities[e.netId]
    local f = rec and rec.bag and rec.bag.cfg and rec.bag.cfg.fleePoints
    return type(f) == 'table' and f[1] or nil
end
-- Config.Flee.nearestRoute: the route e runs starts nearest where he appeared (routes that start within 5 m of as near
-- tie), so he never runs back across the site to a route that starts on its other side.
local function OwnRoute(tag, run, routes, e)
    local p = W.ent(e.entity).coords
    local start, best = FleeStart(run, e), math.huge
    for _, r in ipairs(routes) do best = math.min(best, U.dist(p, r[1])) end
    local d = start and U.dist(p, start) or math.huge
    H.ok(d <= best + 5.0,
        ('%s: runs the escape route that starts nearest him (%.1f m away, the nearest %.1f m)'):format(tag, d, best))
end

do
    local cases = {}
    for li = 1, 7 do cases[#cases + 1] = { id = 'gang_hideout_raid', li = li, index = 3, key = 'runners' } end
    for li = 1, 7 do cases[#cases + 1] = { id = 'drug_lab_raid', li = li, index = 3, key = 'cook' } end
    cases[#cases + 1] = { id = 'prison_break', li = 6, index = 1, key = 'spawns', out = 100.0 }
    for _, c in ipairs(cases) do
        local def = Missions.get(c.id)
        local loc = def.locations[c.li]
        local pts, tag = loc[c.key], ('%s %s'):format(c.id, loc.label)
        local want = math.max(#pts, Most(def, c.index))
        local at = loc.start.coords
        if c.out then
            local p1 = pts[1]
            local d = D2(at, p1)
            at = vec3(p1.x + (at.x - p1.x) / d * c.out, p1.y + (at.y - p1.y) / d * c.out, at.z)
        end
        Place(1, at)
        warns = {}
        local run = Run(c.id, c.li, { 1 }, {
            index = c.index,
            obj = { suspects = want },
            before = loc.lieutenant and { block = 'stub_body', label = 'Lieutenant', at = loc.lieutenant } or nil,
        })
        Secs(3)
        local out = Peds(run, 'inmate')
        H.eq(#out, want, ('%s: all %d come out at once'):format(tag, want))
        H.eq(#WarnsWith('point(s) for'), 0, tag .. ': no "too few points" warning')
        local used = {}
        local routes = loc[def.objectives[c.index].routes]
        for _, r in ipairs(out) do
            local p = W.ent(r.entity).coords
            local own
            for i, q in ipairs(pts) do if D2(p, q) < 0.05 then own = i end end
            H.ok(own ~= nil and not used[own], ('%s: on a %s point of his own (%s)'):format(tag, c.key, tostring(own)))
            if own then used[own] = true end
            OwnRoute(('%s %s[%s]'):format(tag, c.key, tostring(own)), run, routes, r)
            if loc.lieutenant then
                H.ok(D2(p, loc.lieutenant) >= 3.0,
                    ('%s: %.1f m from the lieutenant (3 m+)'):format(tag, D2(p, loc.lieutenant)))
            end
        end
        H.ok(Nearest(SpawnedSince(loc.lieutenant and 1 or 0), 'other') >= 3.0,
            ('%s: 3 m or more from each other (%.1f m)'):format(tag,
                Nearest(SpawnedSince(loc.lieutenant and 1 or 0), 'other')))
        H.ok(Nearest(SpawnedSince(loc.lieutenant and 1 or 0)) >= Config.Spawning.minDistance,
            ('%s: %.0f m or more from the officer'):format(tag, Config.Spawning.minDistance))
        EndRun(run)
    end
end

-- S21 REVIEW: A COOK RUNS THE ROUTE THAT STARTS AT HIS OWN POINT, NEVER ACROSS THE LAB.
-- Drug Lab Raid #1 (Cabin, Raton Canyon): its two escape routes start 73 m apart on either side of the lab, cook[2] on
-- the first one's first point and cook[3] on the second one's. Objective 3 starts where the fight ended: the officer
-- stands at the lab, on the hiding spot. The two cooks appear by cook[2] and cook[3] once waveDelayMax has passed (at
-- least hardMin from him; the second on the ring round his point, as the two lie on either side of the officer, wider
-- than maxSpread), and each runs the route that starts by him, never the one on the other side (through the lab and
-- past the officer), whatever order the run deals the routes in (8 seeds). With
-- Config.Flee.nearestRoute = false the routes take turns wherever he appears, so some seed sends a cook across.
do
    local def = Missions.get('drug_lab_raid')
    local loc = def.locations[1]
    H.ok(
        D2(loc.cook[2], loc.escapes[1][1]) < 1.0 and D2(loc.cook[3], loc.escapes[2][1]) < 1.0
            and D2(loc.escapes[1][1], loc.escapes[2][1]) > 70.0,
        'Raton Canyon: cook[2] and cook[3] stand on the two routes\' first points, 70 m+ apart'
    )
    -- one run with the officer at the lab: the cooks out, those on their own route's start, those sent 70 m+ across
    local function Cooks(seed)
        Place(1, loc.cook[1])
        local run = Run('drug_lab_raid', 1, { 1 }, { index = 3, obj = { suspects = 2 }, seed = seed })
        Secs(Config.Spawning.waveDelayMax + 5)
        local out, own, across = Peds(run, 'inmate'), 0, 0
        for _, e in ipairs(out) do
            local p, start = W.ent(e.entity).coords, FleeStart(run, e)
            if start and D2(p, start) < 5.0 then own = own + 1 end
            if start and D2(p, start) > 70.0 then across = across + 1 end
        end
        local nearest = Nearest(SpawnedSince(0))
        EndRun(run)
        return #out, own, across, nearest
    end
    for seed = 1, 8 do
        local n, own, across, nearest = Cooks(seed)
        H.eq(n, 2, ('seed %d: both cooks come out after waveDelayMax'):format(seed))
        H.ok(nearest >= Config.Spawning.hardMin,
            ('seed %d: %.0f m or more from the officer (%.1f m)'):format(seed, Config.Spawning.hardMin, nearest))
        H.eq(own, 2, ('seed %d: each cook runs the route that starts by him (within 5 m)'):format(seed))
        H.eq(across, 0, ('seed %d: no cook is sent across the lab to the other route'):format(seed))
    end
    Config.Flee.nearestRoute = false
    local crossed = 0
    for seed = 1, 8 do crossed = crossed + select(3, Cooks(seed)) end
    Config.Flee.nearestRoute = true
    H.ok(crossed > 0, ('nearestRoute = false: the routes take turns, %d cook(s) sent across in 8 runs'):format(crossed))
end

-- S21 REVIEW: GANG HIDEOUT RAID WITH THE OFFICER AT THE LIEUTENANT'S BODY.
-- Objective 3 (Catch the runners) starts right after the lieutenant fight at the back of the house, the officers at his
-- body, and most runner points lie within minDistance (40 m) of it (East Vinewood: all 4, 7.7-29.5 m). So not all
-- come out at once there: a runner appears once the director allows his point, at least minDistance from the officer,
-- or once waveDelayMax has passed at least hardMin (20 m); none on the lieutenant or on another runner, each on the
-- escape route that starts nearest him. The ones still waiting come out once the officer moves off (to the start).
-- The largest team's 3 runners at every hideout.
do
    local def = Missions.get('gang_hideout_raid')
    local routesKey = def.objectives[3].routes
    local most = Most(def, 3)
    H.eq(most, 3, 'Gang Hideout Raid: the largest team brings 3 runners')
    for li = 1, 7 do
        local loc = def.locations[li]
        local tag = ('gang_hideout_raid %s, the officer at the lieutenant'):format(loc.label)
        Place(1, loc.lieutenant)
        local run = Run('gang_hideout_raid', li, { 1 }, {
            index = 3,
            obj = { suspects = 3 },
            before = { block = 'stub_body', label = 'Lieutenant', at = loc.lieutenant },
        })
        Secs(Config.Spawning.waveDelayMax - 2)
        local early = SpawnedSince(1)
        H.ok(Nearest(early) >= Config.Spawning.minDistance,
            ('%s: before waveDelayMax only points %.0f m+ from him (%d out, nearest %.1f m)'):format(tag,
                Config.Spawning.minDistance, #early, Nearest(early)))
        Secs(6)
        local out = Peds(run, 'inmate')
        H.ok(#out >= 1, ('%s: after waveDelayMax the runners on points 20 m+ from him come out (%d)'):format(tag, #out))
        H.ok(Nearest(SpawnedSince(1)) >= Config.Spawning.hardMin,
            ('%s: %.0f m or more from him (%.1f m)'):format(tag, Config.Spawning.hardMin, Nearest(SpawnedSince(1))))
        H.ok(Nearest(SpawnedSince(1), 'other') >= 3.0,
            ('%s: 3 m or more from each other (%.1f m)'):format(tag, Nearest(SpawnedSince(1), 'other')))
        for _, e in ipairs(out) do
            local p = W.ent(e.entity).coords
            H.ok(D2(p, loc.lieutenant) >= 3.0, ('%s: %.1f m from the lieutenant'):format(tag, D2(p, loc.lieutenant)))
            OwnRoute(tag, run, loc[routesKey], e)
        end
        -- he walks back to the start: the ones still waiting come out
        Place(1, loc.start.coords)
        Secs(3)
        out = Peds(run, 'inmate')
        H.eq(#out, 3, ('%s: all 3 out once he moves off'):format(tag))
        for _, e in ipairs(out) do OwnRoute(tag, run, loc[routesKey], e) end
        H.ok(Nearest(SpawnedSince(1), 'other') >= 3.0, ('%s: still 3 m or more apart'):format(tag))
        EndRun(run)
    end
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
    tight.cook = { loc.cook[1] }
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
-- A CLIENT CANNOT SKIP THE VAN WALK (K1).
-- custody = 'handover': after the real cuff, only CP.Custody's hand-over at the van sends handed_over. The same
-- event sent by a client (server:objective) is refused, so the suspect is not handed over and the objective goes on.

do
    local def = Missions.get('drug_lab_raid')
    local loc = def.locations[1]
    Place(1, loc.start.coords)
    local tight = {}
    for k, v in pairs(loc) do tight[k] = v end
    tight.cook = { loc.cook[1] }
    tight.escapes = { { loc.cook[1] } }
    local run = Run('drug_lab_raid', 1, { 1 },
        { index = 3, obj = { suspects = 1, custody = 'handover' }, location = tight })
    Secs(1)
    local cook = Peds(run, 'inmate')[1]
    H.ok(cook ~= nil, 'k1: the cook came out')
    W.near(1, run, cook.netId, 1.0)
    Event(1, run, { type = 'aim', netId = cook.netId })
    Secs(6)
    H.fire('crimson-police:server:npcCuff', 1, run.id, cook.netId)
    Secs(1)
    local p = run.objectives[1].state.peds[tostring(cook.netId)]
    H.eq(p and p.state, 'cuffed', 'k1: the real cuff')
    H.eq(p and p.chain, true, 'k1: the custody chain starts (hand over at the van)')
    Event(1, run, { type = 'handed_over', netId = cook.netId })
    Secs(2)
    H.ok(p and not p.handedOver, 'k1: a client handed_over does not hand him over')
    H.ok(run.objectives[1].status ~= 'done', 'k1: the objective is not done without the van walk')
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

-- ============================================================================
--                 THE SPAWN CAP IS CHECKED BEFORE THE DIRECTOR
-- ============================================================================
-- Q11 (loop audit server-runs-2): while the run is at Config.Limits.maxEntities or maxArmedAlive, a Prison Break
-- scatter and a warrant's associates at the knock ask neither the director nor the officers' games what they see
-- (before, every 1 s tick did both and threw the answer away). Once there is room they come out through the director.

do
    local limits = Config.Limits
    local keepTotal, keepArmed = limits.maxEntities, limits.maxArmedAlive
    local picks, asks = 0, 0
    local realChoose, realAwait = CP.Runs.choosePoints, lib.callback.await
    CP.Runs.choosePoints = function(run, candidates, n, opts)
        if type(opts) == 'table' and opts.obj == 1 then picks = picks + 1 end
        return realChoose(run, candidates, n, opts)
    end
    -- the officers' games answer that they see every point
    lib.callback.await = function(name, src, args)
        if name ~= 'crimson-police:client:spawn:visible' then return realAwait(name, src, args) end
        asks = asks + 1
        local out = {}
        for k = 1, #args.points do out[k] = true end
        return out
    end

    -- Prison Break, the south-west fence: two inmates (both armed for the armed cap), the officer 100 m out
    local def = Missions.get('prison_break')
    local loc = def.locations[6]
    local p1, s = loc.spawns[1], loc.start.coords
    local d = D2(s, p1)
    local at = vec3(p1.x + (s.x - p1.x) / d * 100.0, p1.y + (s.y - p1.y) / d * 100.0, s.z)
    for _, c in ipairs({
        { tag = 'scatter at maxEntities', key = 'maxEntities', share = 0.0 },
        { tag = 'scatter at maxArmedAlive', key = 'maxArmedAlive', share = 1.0 },
    }) do
        limits[c.key] = 0
        Place(1, at)
        local run = Run('prison_break', 6, { 1 }, { obj = { suspects = 2, armedShare = c.share } })
        local want = CP.Runs.ctx(run, 1).obj.suspects
        picks, asks = 0, 0
        Secs(30)
        H.eq(picks, 0, c.tag .. ': 30 ticks at the cap ask the director nothing')
        H.eq(asks, 0, c.tag .. ': and no officer\'s game is asked what it sees')
        H.eq(#Peds(run, 'inmate'), 0, c.tag .. ': nobody appeared')
        limits.maxEntities, limits.maxArmedAlive = keepTotal, keepArmed
        Secs(2)
        local out = Peds(run, 'inmate')
        H.eq(#out, want, ('%s: room again: all %d come out'):format(c.tag, want))
        H.ok(picks > 0, ('%s: through the director (%d picks)'):format(c.tag, picks))
        H.ok(Nearest(spawns) >= cfg.minDistance,
            ('%s: %.0f m or more from the officer (%.1f m)'):format(c.tag, cfg.minDistance, Nearest(spawns)))
        H.eq(W.count(out, function(e) return e.armed == true end), c.share > 0 and want or 0,
            c.tag .. ': armed as the share says')
        EndRun(run)
    end

    -- Warrant Service, Forum Drive: the associate at the knock waits for room, then comes out as before
    loc = Missions.get('warrant_service').locations[2]
    for _, c in ipairs({
        { tag = 'associates at maxArmedAlive', key = 'maxArmedAlive', cap = 0 },
        { tag = 'associates at maxEntities', key = 'maxEntities', cap = 1 },
    }) do
        Place(1, loc.start.coords)
        Place(2, loc.start.coords)
        local run = Run('warrant_service', 2, { 1, 2 }, { obj = SURRENDER })
        Secs(5)
        H.eq(#spawns, 1, c.tag .. ': only the suspect waits at the door')
        limits[c.key] = c.cap
        Knock(run, 1, loc.door)
        picks, asks = 0, 0
        Secs(30)
        H.eq(picks, 0, c.tag .. ': 30 ticks at the cap ask the director nothing')
        H.eq(asks, 0, c.tag .. ': and no officer\'s game is asked what it sees')
        H.eq(#Peds(run, 'associate'), 0, c.tag .. ': no associate yet')
        limits.maxEntities, limits.maxArmedAlive = keepTotal, keepArmed
        Secs(1)
        H.eq(#Peds(run, 'associate'), 1, c.tag .. ': room again: the associate comes out')
        H.ok(picks > 0, ('%s: through the director (%d picks)'):format(c.tag, picks))
        H.ok(Nearest(SpawnedSince(1)) >= 15.0,
            ('%s: 15 m or more from every officer (%.1f m)'):format(c.tag, Nearest(SpawnedSince(1))))
        EndRun(run)
    end
    CP.Runs.choosePoints, lib.callback.await = realChoose, realAwait
end
_G.print = realPrint
return H
