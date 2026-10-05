-- The parity-plus built-in missions (parking_patrol, traffic_enforcement, suspicious_activity, drug_lab_raid,
-- gang_hideout_raid) and the changed cards: files, guardrails, and end-to-end runs at every tier they support.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U

local NEW = { 'parking_patrol', 'traffic_enforcement', 'suspicious_activity', 'drug_lab_raid', 'gang_hideout_raid' }

-- ============================================================================
--                               THE REAL LOADER
-- ============================================================================

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
for _, f in ipairs(summary.failed or {}) do print('  loader: ' .. tostring(f.id) .. ': ' .. tostring(f.error)) end
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission')
for _, id in ipairs(NEW) do
    H.ok(Missions.get(id) ~= nil, id .. ': loaded by the real loader')
end

local VMT = getmetatable(vec3(0, 0, 0))
local function IsVec(v) return type(v) == 'table' and getmetatable(v) == VMT end
local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local function RawDef(id)
    local src = LoadResourceFile('Crimson-Police', 'missions/builtin/' .. id .. '.lua')
    local def
    local env = {
        RegisterMission = function(d) def = d end,
        vec3 = vec3,
        vec4 = vec4,
        vector3 = vector3,
        vector4 = vector4,
        math = math,
    }
    assert(load(src, '@' .. id, 't', env))()
    return def, src
end

-- ============================================================================
--                          1. THE FILES AND THE CARDS
-- ============================================================================

-- design 2.5.1 / A8: type, officers, stars, time limit, cooldown
local CARDS = {
    parking_patrol = { type = 'patrol', min = 1, max = 1, stars = 1, timeLimit = 600, cooldown = 600 },
    traffic_enforcement = { type = 'patrol', min = 1, max = 2, stars = 2, timeLimit = 720, cooldown = 900 },
    suspicious_activity = { type = 'investigation', min = 1, max = 2, stars = 2, timeLimit = 600, cooldown = 900 },
    drug_lab_raid = { type = 'tactical', min = 2, max = 4, stars = 3, timeLimit = 720, cooldown = 1200 },
    gang_hideout_raid = { type = 'tactical', min = 2, max = 4, stars = 3, timeLimit = 720, cooldown = 1200 },
}
-- location keys ped / vehicle spawns sit at (each one 30 m or more from the start)
local SPAWN_KEYS = {
    parking_patrol = { 'spots' },
    suspicious_activity = { 'car', 'people' },
    drug_lab_raid = { 'inside', 'yard', 'cook' },
    gang_hideout_raid = { 'front', 'house', 'garage', 'lieutenant', 'runners' },
    traffic_enforcement = {},
}

local function EachPoint(v, fn)
    if IsVec(v) then fn(v) return end
    if type(v) ~= 'table' then return end
    if IsVec(v.coords) then fn(v.coords) return end
    for _, x in pairs(v) do EachPoint(x, fn) end
end

for _, id in ipairs(NEW) do
    local def, src = RawDef(id)
    local c = CARDS[id]
    H.ok(src:match('^%-%-%[%[ Crimson%-Police · built%-in mission') ~= nil, id .. ': the built-in header')
    H.eq(def.type, c.type, id .. ': type')
    H.eq(def.minOfficers, c.min, id .. ': minOfficers')
    H.eq(def.maxOfficers, c.max, id .. ': maxOfficers')
    H.eq(def.difficulty, c.stars, id .. ': stars')
    H.eq(def.timeLimit, c.timeLimit, id .. ': time limit')
    H.eq(def.cooldown, c.cooldown, id .. ': cooldown')
    H.ok(#def.locations >= 6, id .. ': 6+ locations (' .. #def.locations .. ')')
    for li, loc in ipairs(def.locations) do
        for _, key in ipairs(SPAWN_KEYS[id]) do
            EachPoint(loc[key], function(p)
                H.ok(D2(p, loc.start.coords) >= 30.0, ('%s: location %d %s point %.0f m from the start (30 m+)'):format(
                    id, li, key, D2(p, loc.start.coords)))
            end)
        end
        for lj = li + 1, #def.locations do
            H.ok(D2(loc.start.coords, def.locations[lj].start.coords) >= 100.0,
                ('%s: locations %d and %d are 100 m+ apart'):format(id, li, lj))
        end
    end
    H.eq(def.payout, nil, id .. ': no payout field')
    H.eq(def.rewards, nil, id .. ': no reward field')
end
do
    local pp = RawDef('parking_patrol')
    H.eq(pp.quietPatrol, true, 'parking_patrol: a quiet patrol (lights cost -10)')
    for li, loc in ipairs(pp.locations) do
        H.ok(#loc.spots >= 10, ('parking_patrol: district %d has 10+ kerb spots'):format(li))
        local rules = {}
        for _, s in ipairs(loc.spots) do
            rules[s.rule] = true
            H.ok(Config.Custody.parkingRules[s.rule] ~= nil, 'parking_patrol: every spot has a posted rule')
            H.ok(type(s.street) == 'string' and s.street ~= '', 'parking_patrol: every spot names its street')
        end
        H.ok(rules.free and rules.metered and rules.hydrant, ('parking_patrol: district %d mixes the rules'):format(li))
        local d = D2(loc.spots[1].coords, loc.start.coords)
        H.ok(d >= 30 and d <= 60,
            ('parking_patrol: the entry point is 30-60 m before the first spot (%.0f m)'):format(d))
    end
    H.eq(RawDef('beat_patrol').quietPatrol, true, 'beat_patrol still gets the lights penalty (quietPatrol)')
    H.eq(RawDef('business_check').quietPatrol, true, 'business_check still gets the lights penalty (quietPatrol)')
    local te = RawDef('traffic_enforcement')
    for li, loc in ipairs(te.locations) do
        local pts = loc.route.points
        local len = 0
        for i = 2, #pts do len = len + D2(pts[i - 1], pts[i]) end
        H.ok(len >= 2000 and len <= 6200, ('traffic_enforcement: corridor %d is 2-6 km (%.0f m)'):format(li, len))
        H.ok(type(loc.speed) == 'number', ('traffic_enforcement: corridor %d has its posted speed'):format(li))
    end
    local sa = RawDef('suspicious_activity')
    for li, loc in ipairs(sa.locations) do
        H.ok(#loc.people >= 3, ('suspicious_activity: scene %d has 3+ person spots'):format(li))
        H.ok(#loc.fleeTo >= 2, ('suspicious_activity: scene %d has 2+ escape paths'):format(li))
        local d = D2(loc.car, loc.start.coords)
        H.ok(d >= 40 and d <= 60, ('suspicious_activity: the start is 40-60 m from the scene (%.0f m)'):format(d))
    end
    for _, id in ipairs({ 'drug_lab_raid', 'gang_hideout_raid' }) do
        local rd = RawDef(id)
        H.eq(rd.vehiclePenalties, false, id .. ': no heavy vehicle-damage penalty')
        for li, loc in ipairs(rd.locations) do
            H.eq(#loc.entries, 2, ('%s: location %d has 2 entry points'):format(id, li))
            H.ok(#(loc.stashes or loc.caches) >= 6, ('%s: location %d has 6+ stash spots'):format(id, li))
            H.ok(#loc.escapes >= 2, ('%s: location %d has 2+ escape routes'):format(id, li))
            local ref = loc.lab or loc.lieutenant
            local lim = id == 'drug_lab_raid' and 80 or 100
            H.ok(D2(loc.start.coords, ref) <= lim, ('%s: location %d starts within %d m'):format(id, li, lim))
        end
    end
    local dl = RawDef('drug_lab_raid')
    local sc = dl.objectives[5]
    H.eq(sc.block, 'skill_check', 'drug_lab_raid: Shut down the lab is a skill check')
    H.ok(type(sc.onFail) == 'table' and sc.onFail.setback.penalty == 'lab_fire',
        'drug_lab_raid: the toxic fire is a setback with lab_fire, never a fail')
    H.eq(dl.objectives[1].together.count, 2, 'drug_lab_raid: breach together (2 officers)')
    H.eq(dl.objectives[4].fastBonus.after, 1, 'drug_lab_raid: stash_found_fast is timed from the breach')
    local gh = RawDef('gang_hideout_raid')
    H.eq(gh.objectives[4].fastBonus.after, 1, 'gang_hideout_raid: stash_found_fast is timed from the breach')
    H.eq(gh.objectives[2].spawnSets.use, 2, 'gang_hideout_raid: 2 of the 3 spawn sets per run')
    H.eq(gh.objectives[2].boss.aliveBonus.id, 'lieutenant_alive', 'gang_hideout_raid: the lieutenant alive bonus')
    local svt = RawDef('stolen_vehicle_takedown')
    H.eq(svt.objectives[1].handoff, 'contact', 'stolen_vehicle_takedown: the stop hands off to a contact')
    H.eq(svt.objectives[2].block, 'field_contact', 'stolen_vehicle_takedown: steps 2-4 are a field_contact stop')
    H.eq(svt.objectives[2].revealed[1], 'stolen', 'stolen_vehicle_takedown: the stolen plate is known from the start')
    local ws = RawDef('warrant_service')
    H.eq(ws.objectives[2].finds.chance, 0.6, 'warrant_service: the property search rolls a find (60%)')
    H.eq(ws.objectives[3].block, 'process_scene', 'warrant_service: then Process the scene')
    local gs = RawDef('gang_shootout')
    H.eq(gs.objectives[3].block, 'process_scene', 'gang_shootout: Process the scene')
    H.eq(gs.objectives[3].bodies, 4, 'gang_shootout: at most 4 bodies kept')
end

-- ============================================================================
--                                2. RUN HELPERS
-- ============================================================================

local function Report(src, run, index, ev) H.fire('crimson-police:server:objective', src, run.id, index, ev) end
local function Obj(run, i) return run.objectives[i or run.objectiveIndex] end
local function Ctx(run, i) return CP.Runs.ctx(run, i or run.objectiveIndex) end
local function Secs(n) W.tick(n) end
local function Tiers(def)
    local out = {}
    for _, row in ipairs(Config.Scaling) do
        local lo = 1
        for _, r in ipairs(Config.Scaling) do if r == row then break end lo = r.maxParticipants + 1 end
        if lo <= def.maxOfficers and row.maxParticipants >= def.minOfficers then
            out[#out + 1] = {
                tier = row.tier,
                count = math.max(def.minOfficers, math.min(def.maxOfficers, row.maxParticipants)),
            }
        end
    end
    return out
end
local function Members(n)
    local out = {}
    for i = 1, n do out[i] = i end
    return out
end
local function Start(def, n, tier, seed)
    local members = Members(n)
    for _, s in ipairs(members) do W.place(s, def.locations[1].start.coords.x, def.locations[1].start.coords.y) end
    local run = W.start(members, def, { test = { adminSrc = 1, forcedTier = tier }, seed = seed })
    for _, s in ipairs(members) do
        local c = run.location.start.coords
        W.place(s, c.x, c.y, c.z)
    end
    return run
end
local function RoadNear(dist)
    return function(_, args)
        return { coords = { x = args.near.x + dist, y = args.near.y, z = args.near.z }, heading = 90.0 }
    end
end
W.roadPoint = RoadNear(160.0)

-- Park every service vehicle that is on its way (the host client would drive it there).
local function ParkServices(run)
    for _, s in ipairs(CP.Custody._servicesOf and CP.Custody._servicesOf(run) or {}) do
        if s.status == 'coming' and s.veh and s.dest then
            local m = W.model(run, s.veh)
            if m then
                m.coords = vec3(s.dest.x + 3.0, s.dest.y, s.dest.z)
                m.velocity = nil
            end
        end
    end
    Secs(2)
end
local function Service(run, kind)
    local b
    for _, s in ipairs(CP.Custody._servicesOf and CP.Custody._servicesOf(run) or {}) do
        if s.kind == kind and s.status ~= 'gone' then b = s end
    end
    return b
end

-- Catch someone on foot: aim within 10 m, then Cuff suspect (5 s within reach).
local function Catch(src, run, index, netId)
    W.near(src, run, netId, 5.0)
    Report(src, run, index, { type = 'aim', netId = netId })
    W.near(src, run, netId, 1.0)
    Secs(6)
    H.fire('crimson-police:server:npcCuff', src, run.id, netId)
    Secs(1)
end

-- An arrested contact with custody = 'handover': search, escort, walk to the van, hand over.
local function HandOver(src, run, c)
    W.near(src, run, c.netId)
    if not c.searched then W.act(src, run, c.netId, 'searchPerson') end
    W.act(src, run, c.netId, 'escort')
    ParkServices(run)
    local van = Service(run, 'transport')
    if not van then Secs(3) van = Service(run, 'transport') end
    if not van then return false end
    if van.status ~= 'parked' then
        Secs(62)                               -- the service timeout places the van
    end
    local vc = W.at(run, van.veh)
    if not vc then return false end
    W.place(src, vc.x + 2.0, vc.y, vc.z)
    local pm = W.model(run, c.netId)
    if pm then pm.coords = vec3(vc.x + 3.0, vc.y, vc.z) end
    W.act(src, run, 0, 'handover')
    Secs(1)
    return c.state == 'handed_over'
end

-- The Best choice for a contact from its (server-side) truth.
local PERSON_BEST = {
    clean = 'release',
    minor = 'cite',
    suspended = 'cite',
    warrant = 'arrest',
    armed = 'arrest',
    narcotics = 'arrest',
    tools = 'arrest',
    intoxicated = 'arrest',
    evading = 'arrest',
}
local function BestCar(c)
    if c.truth == 'stolen' then return 'impound' end
    if c.truth == 'violation' then return c.level == 'impound' and 'impound' or 'cite' end
    if c.role == 'parked' then return 'noAction' end
    return c.truth == 'legal' and 'noAction' or 'impound'
end

-- Work one person to a decision: find the facts lawfully, then decide what the truth needs.
local function WorkPerson(src, run, index, c)
    if c.decided or c.state == 'dead' or c.state == 'handed_over' or c.state == 'gone' then return end
    if c.state == 'hostile' then
        local m = W.model(run, c.netId)
        m.killer = src * 100
        m.health = 0
        Secs(2)
        return
    end
    if c.state == 'fleeing' or c.state == 'walking' or c.state == 'surrendered' then Catch(src, run, index, c.netId) end
    if c.vehicleOf then
        local car = W.model(run, c.vehicleOf)
        if car then W.leaveCar(run.entities[c.netId].entity) end
    end
    W.near(src, run, c.netId)
    if c.state ~= 'cuffed' then
        W.act(src, run, c.netId, 'talk')
        W.act(src, run, c.netId, 'frisk')
    end
    local truth = c.truth
    if c.evading and PERSON_BEST[truth] ~= 'arrest' then truth = 'evading' end
    if c.observed and c.role == 'driver' and truth == 'clean' then
        truth = 'minor'
    end -- an observed violation
    local choice = PERSON_BEST[truth] or 'release'
    if choice == 'arrest' and c.state ~= 'cuffed' then
        W.act(src, run, c.netId, 'detain')
        W.act(src, run, c.netId, 'searchPerson')
    end
    W.near(src, run, c.netId)
    W.decide(src, run, c.netId, choice, { offence = 'loitering', confirmed = true })
    if choice == 'arrest' and c.custody == 'handover' then HandOver(src, run, c) end
end

local function WorkCar(src, run, c)
    if c.decided or c.state == 'gone' or c.state == 'impounded' then return end
    W.near(src, run, c.netId)
    if c.role == 'parked' then W.act(src, run, c.netId, 'inspect') end
    W.act(src, run, c.netId, 'runPlate')
    W.near(src, run, c.netId)
    W.decide(src, run, c.netId, BestCar(c), { offence = 'expired_meter', confirmed = true })
end

local function Contacts(run, index)
    local out = {}
    for _, c in ipairs(CP.Custody.contactsOf(run, index)) do out[#out + 1] = c end
    return out
end

-- Work every contact of a field_contact objective until it completes.
local function WorkContacts(src, run, index)
    for _ = 1, 4 do
        if Obj(run, index).status == 'done' or run.state ~= 'in_progress' then return end
        for _, c in ipairs(Contacts(run, index)) do
            if c.kind == 'person' then WorkPerson(src, run, index, c) end
        end
        for _, c in ipairs(Contacts(run, index)) do
            if c.kind == 'vehicle' then WorkCar(src, run, c) end
        end
        Secs(3)
        if Obj(run, index).status ~= 'done' then
            ParkServices(run)
            Secs(62)                           -- tow trucks fade the car, vans are placed
        end
    end
end

local function LedgerOk(run, what)
    local bad = 0
    for _, d in ipairs(run.decisions or {}) do
        if d.verdict == 'wrong' or d.verdict == 'critical' then bad = bad + 1 end
    end
    H.ok(#(run.decisions or {}) > 0, what .. ': the decision ledger has entries')
    H.eq(bad, 0, what .. ': no wrong decision in the ledger')
end

-- Kill every living hostile / boss of objective index until it completes (believable pace).
local function ClearHostiles(run, index, killer)
    for _ = 1, 60 do
        if Obj(run, index).status == 'done' or run.state ~= 'in_progress' then return end
        for _, e in ipairs(CP.Runs.entitiesFor(run, { obj = index, kind = 'ped', alive = true })) do
            local m = W.ent(e.entity)
            if m and m.exists and (m.health or 0) > 0 then
                m.killer = killer * 100
                m.health = 0
            end
        end
        Secs(3)
    end
end

-- Breach together: officers 1 and 2 at the two entries within the window (solo: one officer, solo time).
local function Breach(run, n)
    local loc = run.location
    local members = CP.Runs.activeSrcs(run)
    if #members >= 2 then
        for i = 1, 2 do W.place(members[i], loc.entries[i].x, loc.entries[i].y, loc.entries[i].z) end
        Secs(4)
        Report(members[1], run, n, { type = 'interact', point = 1 })
        Report(members[2], run, n, { type = 'interact', point = 2 })
    else
        for i = 1, 2 do
            W.place(members[1], loc.entries[i].x, loc.entries[i].y, loc.entries[i].z)
            Secs(9)
            Report(members[1], run, n, { type = 'interact', point = i })
        end
    end
    Secs(1)
end

-- Catch every flee_arrest suspect of objective n.
local function CatchAll(run, n, src)
    for _ = 1, 3 do
        if Obj(run, n).status == 'done' then return end
        local st = Ctx(run, n).state
        for _, p in pairs(st.peds or {}) do
            if p.state ~= 'cuffed' and p.state ~= 'dead' then Catch(src, run, n, p.netId) end
        end
        Secs(2)
    end
end

-- Search every spot of an interact_points hidden search; seize each find where it asks for it.
local function SearchAll(run, n, src)
    local st = Ctx(run, n).state
    for i, p in ipairs(st.points) do
        if p.status == 'pending' then
            W.place(src, p.coords.x, p.coords.y, p.coords.z)
            Secs(5)
            Report(src, run, n, { type = 'interact', point = i })
            Secs(1)
            if p.status == 'followup' then
                Secs(7)
                Report(src, run, n, { type = 'followup', point = i })
                Secs(1)
            end
        end
    end
    Secs(1)
end

local function ShutDown(run, n, src, misses)
    local lab = run.location.lab
    W.place(src, lab.x, lab.y, lab.z)
    Secs(1)
    for _ = 1, misses or 0 do
        H.advance(400)
        Report(src, run, n, { type = 'check', target = 1, index = 1, success = false })
    end
    for k = 1, 3 do
        H.advance(400)
        Report(src, run, n, { type = 'check', target = 1, index = k, success = true })
    end
    Secs(1)
end

local function ProcessAll(run, n, src)
    if Obj(run, n).status == 'done' then return end
    local st = Ctx(run, n).state
    for _, netId in ipairs(st.order or {}) do
        local b = st.bodies[netId]
        local c = W.at(run, netId) or b.coords
        W.place(src, c.x, c.y, c.z)
        for _, step in ipairs({ 'tag', 'bag' }) do
            Report(src, run, n, { type = step .. '_begin', netId = netId })
            Secs(step == 'tag' and 6 or 7)
            Report(src, run, n, { type = step, netId = netId })
            Secs(1)
        end
    end
    ParkServices(run)
    local van = Service(run, 'coroner')
    if van and van.status ~= 'parked' then Secs(62) end
    local vc = van and W.at(run, van.veh) or run.location.scene
    if vc then W.place(src, vc.x + 1.0, vc.y, vc.z) end
    Report(src, run, n, { type = 'release_begin' })
    Secs(9)
    Report(src, run, n, { type = 'release' })
    Secs(2)
end

-- ============================================================================
--                 3. ILLEGAL PARKING PATROL (solo, every tier)
-- ============================================================================

do
    local def = U.deepcopy(Missions.get('parking_patrol'))
    def.objectives[1].returning = { chance = 0, max = 1 }   -- the returning driver and the thief are WP2's specs
    def.objectives[1].thief = { chance = 0, runAt = 15.0 }
    for _, t in ipairs(Tiers(def)) do
        local run = Start(def, t.count, t.tier)
        Secs(2)
        local cars = W.cars(run, 1)
        H.eq(#cars, 5, 'parking_patrol ' .. t.tier .. ': five parked cars')
        WorkContacts(1, run, 1)
        H.eq(run.state, 'ended', 'parking_patrol ' .. t.tier .. ': completed end to end')
        H.eq(run.endState, 'completed', 'parking_patrol ' .. t.tier .. ': completed')
        H.eq(#(run.decisions or {}), 5, 'parking_patrol ' .. t.tier .. ': five decisions in the ledger')
        LedgerOk(run, 'parking_patrol ' .. t.tier)
        H.eq(run.score.shared.vehicle_impounded, nil,
            'parking_patrol ' .. t.tier .. ': vehicle_impounded is not on its card, so an impound records none')
    end
end

-- ============================================================================
--               4. SUSPICIOUS ACTIVITY (every tier it supports)
-- ============================================================================

do
    local def = Missions.get('suspicious_activity')
    for _, t in ipairs(Tiers(def)) do
        local run = Start(def, t.count, t.tier, 555001)
        Secs(1)
        local loc = run.location
        W.place(1, loc.car.x + 10.0, loc.car.y, loc.car.z)
        Secs(3)
        H.ok(#W.people(run, 1) >= 1, 'suspicious_activity ' .. t.tier .. ': people at the scene')
        WorkContacts(1, run, 1)
        H.eq(run.state, 'ended', 'suspicious_activity ' .. t.tier .. ': completed end to end')
        H.eq(run.endState, 'completed', 'suspicious_activity ' .. t.tier .. ': completed')
        LedgerOk(run, 'suspicious_activity ' .. t.tier)
    end
end

-- ============================================================================
--                            5. TRAFFIC ENFORCEMENT
-- ============================================================================
-- One violator solo, two with two officers.

-- Pace the violator: the officer drives 50 m behind it over the window, then lights it up; it yields.
local function PaceAndStop(run, n, srcs)
    local ctx = Ctx(run, n)
    local st = ctx.state
    local key = st.vorder and st.vorder[1]
    local v = key and st.vehicles[key]
    if not v then return nil end
    local car = W.model(run, v.netId)
    local cruiser = H.entity(40000 + n, { kind = 'vehicle', coords = vec3(0.0, 0.0, 30.0) })
    H.players[srcs[1]].vehicle = cruiser.handle
    local route = run.location.route.points
    local k0 = 1
    local best = math.huge
    for i, p in ipairs(route) do
        local d = D2(p, run.location.start.coords)
        if d < best then best, k0 = d, i end
    end
    local a, b = route[k0], route[math.min(#route, k0 + 1)]
    local len = D2(a, b)
    local ux, uy = (b.x - a.x) / len, (b.y - a.y) / len
    local h = math.deg(math.atan(-ux, uy)) % 360.0
    for i = 1, 8 do
        local px, py = a.x + ux * (i * 4.0), a.y + uy * (i * 4.0)
        car.coords = vec3(px, py, a.z)
        car.heading = h
        car.velocity = nil
        car.speed = (v.targetKmh or 120) / 3.6
        W.place(srcs[1], px - ux * 50.0, py - uy * 50.0, a.z)
        Secs(1)
    end
    W.place(srcs[1], car.coords.x - ux * 30.0, car.coords.y - uy * 30.0, a.z)
    Report(srcs[1], run, n, { type = 'lights_near', netId = v.netId })
    car.speed = 0.0
    Secs(7)
    H.players[srcs[1]].vehicle = nil
    return v
end

do
    local def = U.deepcopy(Missions.get('traffic_enforcement'))
    def.objectives[1].responses = { yield = 1.0, flee = 0, fight = 0 }   -- the stop itself; responses: blocks_c
    def.objectives[3].responses = { yield = 1.0, flee = 0, fight = 0 }
    for _, t in ipairs(Tiers(def)) do
        local run = Start(def, t.count, t.tier, 777001)
        Secs(1)
        local srcs = CP.Runs.activeSrcs(run)
        local v = PaceAndStop(run, 1, srcs)
        H.ok(v ~= nil and v.observed ~= nil, 'traffic_enforcement ' .. t.tier .. ': the violator was observed')
        H.eq(v and v.state, 'stopped', 'traffic_enforcement ' .. t.tier .. ': the yielding car pulled over')
        Secs(10)
        H.eq(run.objectiveIndex, 2, 'traffic_enforcement ' .. t.tier .. ': the stop is worked by field_contact')
        H.eq(CP.Runs.ownerOf(run, v and v.netId), 2, 'traffic_enforcement ' .. t.tier .. ': the car was adopted')
        local car = W.cars(run, 2)[1]
        if car then
            W.near(1, run, car.netId)
            W.act(1, run, car.netId, 'orderOut')
            Secs(4)
        end
        WorkContacts(1, run, 2)
        local second = run.objectiveIndex >= 3 and Ctx(run, 3) and Ctx(run, 3).state
        if t.count >= 2 then
            H.eq(run.objectiveIndex, 3, 'traffic_enforcement ' .. t.tier .. ': a second violator with two officers')
            Secs(2)
            local v2 = PaceAndStop(run, 3, srcs)
            H.ok(v2 ~= nil, 'traffic_enforcement ' .. t.tier .. ': the second violator spawned')
            Secs(10)
            local car2 = W.cars(run, 4)[1]
            if car2 then
                W.near(1, run, car2.netId)
                W.act(1, run, car2.netId, 'orderOut')
                Secs(4)
            end
            WorkContacts(1, run, 4)
        end
        Secs(3)
        H.eq(run.state, 'ended', 'traffic_enforcement ' .. t.tier .. ': completed end to end')
        H.eq(run.endState, 'completed', 'traffic_enforcement ' .. t.tier .. ': completed')
        if t.count == 1 then
            H.eq(second and second.skipped, true, 'traffic_enforcement solo: no second violator (one officer)')
            local cars = 0
            for _, e in pairs(run.entities or {}) do
                if e.kind == 'vehicle' and e.role == 'suspect_vehicle' then cars = cars + 1 end
            end
            H.ok(cars <= 1, 'traffic_enforcement solo: one violator only')
        end
        LedgerOk(run, 'traffic_enforcement ' .. t.tier)
    end
end

-- ============================================================================
--                               6. DRUG LAB RAID
-- ============================================================================
-- Every tier; the toxic fire is a setback.

do
    local def = Missions.get('drug_lab_raid')
    for i, t in ipairs(Tiers(def)) do
        local run = Start(def, t.count, t.tier, 880001 + i)
        Secs(1)
        Breach(run, 1)
        H.eq(Obj(run, 1).status, 'done', 'drug_lab_raid ' .. t.tier .. ': breached together')
        W.place(1, run.location.start.coords.x, run.location.start.coords.y)
        Secs(46)
        ClearHostiles(run, 2, 1)
        H.eq(Obj(run, 2).status, 'done', 'drug_lab_raid ' .. t.tier .. ': the lab crew neutralised')
        H.ok(run.shared.intel ~= nil, 'drug_lab_raid ' .. t.tier .. ': the intel line is set')
        Secs(2)
        CatchAll(run, 3, 1)
        Secs(10)
        H.eq(Obj(run, 3).status, 'done', 'drug_lab_raid ' .. t.tier .. ': the cooks caught')
        SearchAll(run, 4, 1)
        Secs(10)
        H.eq(Obj(run, 4).status, 'done', 'drug_lab_raid ' .. t.tier .. ': the stash found and seized')
        if Obj(run, 5).status ~= 'done' then ShutDown(run, 5, 1, 0) end
        Secs(6)
        H.eq(Obj(run, 5).status, 'done', 'drug_lab_raid ' .. t.tier .. ': the lab shut down')
        ProcessAll(run, 6, 1)
        H.eq(run.state, 'ended', 'drug_lab_raid ' .. t.tier .. ': completed end to end')
        H.eq(run.endState, 'completed', 'drug_lab_raid ' .. t.tier .. ': completed')
    end
    -- toxic fire: two misses in a row start a setback, cost the officer who missed lab_fire, allow a retry
    local run = Start(def, 2, 'reinforced', 889001)
    Secs(1)
    Breach(run, 1)
    W.place(1, run.location.start.coords.x, run.location.start.coords.y)
    Secs(46)
    ClearHostiles(run, 2, 1)
    Secs(2)
    CatchAll(run, 3, 1)
    Secs(10)
    SearchAll(run, 4, 1)
    Secs(10)
    H.eq(run.objectiveIndex, 5, 'toxic fire: at Shut down the lab')
    local lab = run.location.lab
    W.place(2, lab.x, lab.y, lab.z)
    Secs(1)
    H.advance(400)
    Report(2, run, 5, { type = 'check', target = 1, index = 1, success = false })
    H.advance(400)
    Report(2, run, 5, { type = 'check', target = 1, index = 1, success = false })
    local st = Ctx(run, 5).state
    H.eq(st.targets[1].status, 'setback', 'toxic fire: a setback')
    H.eq(run.state, 'in_progress', 'toxic fire: never a fail')
    H.eq(run.participants[2].score.lab_fire, 1, 'toxic fire: lab_fire for the officer whose checks missed')
    H.eq(run.participants[1].score.lab_fire, nil, 'toxic fire: never for the partner')
    W.place(1, lab.x, lab.y, lab.z)
    Secs(11)
    Report(1, run, 5, { type = 'recover' })
    Report(1, run, 5, { type = 'recover', target = 1 })
    H.eq(st.targets[1].status, 'cooldown', 'toxic fire: ventilated')
    Secs(31)
    H.eq(st.targets[1].status, 'armed', 'toxic fire: the shutdown can be tried again after 30 s')
    ShutDown(run, 5, 1, 0)
    Secs(6)
    H.eq(Obj(run, 5).status, 'done', 'toxic fire: shut down on the retry')
    CP.Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                7. GANG HIDEOUT RAID (every tier it supports)
-- ============================================================================

do
    local def = Missions.get('gang_hideout_raid')
    for i, t in ipairs(Tiers(def)) do
        local run = Start(def, t.count, t.tier, 990001 + i)
        Secs(1)
        Breach(run, 1)
        H.eq(Obj(run, 1).status, 'done', 'gang_hideout_raid ' .. t.tier .. ': breached together')
        W.place(1, run.location.start.coords.x, run.location.start.coords.y)
        Secs(61)
        ClearHostiles(run, 2, 1)
        H.eq(Obj(run, 2).status, 'done', 'gang_hideout_raid ' .. t.tier .. ': the gang and the lieutenant neutralised')
        local intel = run.shared.intel
        H.ok(type(intel) == 'table' and intel.key == 'block.hostile_waves.intel',
            'gang_hideout_raid ' .. t.tier .. ': the intel line names the rolled sets')
        Secs(2)
        CatchAll(run, 3, 1)
        Secs(10)
        H.eq(Obj(run, 3).status, 'done', 'gang_hideout_raid ' .. t.tier .. ': the runners caught')
        SearchAll(run, 4, 1)
        Secs(10)
        H.eq(Obj(run, 4).status, 'done', 'gang_hideout_raid ' .. t.tier .. ': the weapons cache seized')
        ProcessAll(run, 5, 1)
        H.eq(run.state, 'ended', 'gang_hideout_raid ' .. t.tier .. ': completed end to end')
        H.eq(run.endState, 'completed', 'gang_hideout_raid ' .. t.tier .. ': completed')
    end
end

-- ============================================================================
--                               8. CHANGED CARDS
-- ============================================================================
-- STOLEN VEHICLE TAKEDOWN, WARRANT SERVICE, GANG SHOOTOUT.

do -- Stolen Vehicle Takedown: the stop hands off to a contact; the stolen car is impounded
    local def = U.deepcopy(Missions.get('stolen_vehicle_takedown'))
    def.objectives[1].responses = { yield = 1.0, flee = 0, fight = 0 }
    local run = Start(def, 1, 'standard', 660001)
    Secs(1)
    local st = Ctx(run, 1).state
    local v = st.vehicles[st.vorder[1]]
    local car = W.model(run, v.netId)
    local cruiser = H.entity(41001, { kind = 'vehicle', coords = car.coords })
    H.players[1].vehicle = cruiser.handle
    W.place(1, car.coords.x + 20.0, car.coords.y, car.coords.z)
    Report(1, run, 1, { type = 'lights_near', netId = v.netId })
    car.speed = 0.0
    Secs(12)
    H.players[1].vehicle = nil
    H.eq(v.state, 'stopped', 'svt: the car pulled over (yield)')
    H.eq(run.objectiveIndex, 2, 'svt: the contact works the stop')
    local cars = W.cars(run, 2)
    H.eq(#cars, 1, 'svt: the stolen car is a contact')
    H.eq(cars[1] and cars[1].truth, 'stolen', 'svt: the stolen plate is known from the start')
    W.near(1, run, cars[1].netId)
    W.act(1, run, cars[1].netId, 'orderOut')
    Secs(4)
    WorkContacts(1, run, 2)
    H.eq(run.state, 'ended', 'svt: completed end to end')
    H.eq(run.endState, 'completed', 'svt: completed')
    local impounded = 0
    for _, d in ipairs(run.decisions or {}) do if d.choice == 'impound' then impounded = impounded + 1 end end
    H.eq(impounded, 1, 'svt: the stolen car impounded')
    for _, d in ipairs(run.decisions or {}) do
        if d.choice == 'impound' then H.eq(d.points, 0, 'svt: a revealed stolen plate earns no correct_disposition') end
    end
    H.eq(run.score.shared.vehicle_impounded, 1, 'svt: the card bonus vehicle_impounded, once for the car')
    local rr = H.findEvents('crimson-police:client:runEnded')
    local points = rr[#rr] and rr[#rr].args[4] and rr[#rr].args[4].points or {}
    local found = nil
    for _, b in ipairs(points.bonuses or {}) do
        if b.id == 'vehicle_impounded' then found = b end
    end
    H.eq(found and found.points, 10, 'svt: the result card pays vehicle_impounded +10')
end

do -- Warrant Service: the property search rolls finds (virtual evidence); nobody died: the scene completes at once
    local def = U.deepcopy(Missions.get('warrant_service'))
    def.objectives[2].finds = { chance = 1.0, pool = { 'narcotics' } }
    def.objectives[1] = { block = 'stub_hold', label = 'Serve the warrant', minSeconds = 0 }
    local run = Start(def, 2, 'reinforced', 440001)
    Secs(1)
    CP.Runs.objectiveComplete(run, 1)
    Secs(2)
    local yard = CP.Runs.ctx(run, 2).state.points[1].coords
    W.place(1, yard.x, yard.y, yard.z)
    Secs(10)
    Report(1, run, 2, { type = 'interact', point = 1 })
    Secs(3)
    H.eq(run.participants[1].stats and run.participants[1].stats.evidence, 1, 'warrant_service: the find is evidence')
    H.eq(run.shared.evidence and run.shared.evidence[1].kind, 'narcotics', 'warrant_service: shown as virtual evidence')
    Secs(6)
    H.eq(run.state, 'ended', 'warrant_service: nobody died, Process the scene completes at once')
    H.eq(run.score.shared.all_taken_alive, 1, 'warrant_service: nobody killed +15')
end

do -- Gang Shootout: Process the scene keeps at most 4 bodies
    local def = Missions.get('gang_shootout')
    local run = Start(def, 1, 'standard', 330001)
    Secs(61)
    ClearHostiles(run, 1, 1)
    H.eq(Obj(run, 1).status, 'done', 'gang_shootout: every hostile neutralised')
    H.ok(#CP.Runs.heldBodies(run) <= 4, 'gang_shootout: at most 4 bodies kept (' .. #CP.Runs.heldBodies(run) .. ')')
    local scene = run.location.scene
    W.place(1, scene.x, scene.y, scene.z)
    Secs(10)
    Report(1, run, 2, { type = 'interact', point = 1 })
    Secs(2)
    H.eq(run.objectiveIndex, 3, 'gang_shootout: Process the scene is current')
    ProcessAll(run, 3, 1)
    H.eq(run.state, 'ended', 'gang_shootout: completed after processing the scene')
    H.eq(run.endState, 'completed', 'gang_shootout: completed')
end

return H
