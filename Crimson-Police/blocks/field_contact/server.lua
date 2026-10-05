-- Objective block "field_contact" (server half): parked cars, a scene contact or a stop, worked with police
-- actions and graded dispositions (CP.Custody). Modes: parked, scene, stop.

local BLOCK = 'field_contact'
local U = CP.U

local REACH_SLACK = 2.0                  -- metres of position lag allowed around interaction ranges
local AIM_RANGE = 10.0                   -- a fleeing person gives up when aimed at this close
local STUN_RANGE = 30.0                  -- a stun needs a participant this close to the person
local CLOSE_RANGE = 3.0                  -- ...or a participant stays this close...
local CLOSE_SECONDS = 3                  -- ...for this long
local RETURN_OFFSET = 14.0               -- metres from the car where a returning driver appears
local THIEF_OFFSET = 30.0                -- metres from the car where the thief waits
local RETURN_WALK_S = 8                  -- seconds a returning driver takes to reach the car
local DEFAULT_MODELS = { 'a_m_y_stbla_01', 'a_m_m_eastsa_02', 'a_m_y_mexthug_01', 'a_f_y_eastsa_03', 'a_m_m_salton_02' }
local DEFAULT_CARS = { 'asea', 'primo', 'emperor', 'tornado', 'stanier' }
local DEFAULT_SCENE = { occupied_car = 0.5, loitering = 0.3, casing = 0.2 }
local PERSON_ACTIONS = { 'talk', 'frisk', 'detain', 'searchPerson', 'release', 'cite', 'arrest' }
local STOP_PERSON_ACTIONS = { 'talk', 'frisk', 'detain', 'searchPerson', 'warn', 'cite', 'release', 'arrest' }
local PARKED_ACTIONS = { 'inspect', 'runPlate', 'lookInside', 'noAction', 'cite', 'impound' }
local CAR_ACTIONS = { 'lookInside', 'runPlate', 'orderOut', 'searchVehicle', 'noAction', 'impound' }
local SCENE_ROLES = { 'occupied_car', 'loitering', 'casing' }

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function InRange(v, r, scale)
    scale = scale or 1
    return IsNum(v) and type(r) == 'table' and v >= r[1] * scale - 1e-9 and v <= r[2] * scale + 1e-9
end

local function Bad(key, vars) return false, CP.L(key, vars) end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return IsNum(x) and IsNum(y) and IsNum(z)
end

local function HeadingOf(p)
    if type(p) == 'vector4' then return p.w + 0.0 end
    if type(p) == 'table' then return (tonumber(p.w or p[4] or p.heading) or 0.0) + 0.0 end
    return 0.0
end

local function ToVec4(p, dx, dy)
    local x, y, z = U.xyz(p)
    return vector4(x + (dx or 0.0), y + (dy or 0.0), z + 0.0, HeadingOf(p))
end

local function PointList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if v == nil then return {} end
    if IsVec(v) then return { v } end
    if type(v) ~= 'table' then return {} end
    if type(v.points) == 'table' then v = v.points end
    local out = {}
    for i = 1, #v do
        local p = v[i]
        if IsVec(p) then
            out[#out + 1] = p
        elseif type(p) == 'table' and IsVec(p.coords) then
            out[#out + 1] = p.coords
        end
    end
    return out
end

-- Kerb spots of the parked mode: { coords = vec4, rule, street }.
local function SpotList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' then return {} end
    local out = {}
    for i = 1, #v do
        local s = v[i]
        if type(s) == 'table' and IsVec(s.coords) then out[#out + 1] = s end
    end
    return out
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function TrustedFile(ctx)
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    return type(m) == 'table' and m.source == 'builtin'
end

-- The mission's card lists this bonus id (card bonuses such as vehicle_impounded are only recorded then).
local function CardLists(ctx, id)
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    for _, b in ipairs(type(m) == 'table' and type(m.bonuses) == 'table' and m.bonuses or {}) do
        if type(b) == 'table' and b.id == id then return true end
    end
    return false
end

local function WeightedKey(rng, weights)
    local keys, total = {}, 0
    for k, w in pairs(weights or {}) do
        if IsNum(w) and w > 0 then
            keys[#keys + 1] = k
            total = total + w
        end
    end
    if total <= 0 then return nil end
    table.sort(keys)
    local x = rng:next() * total
    for _, k in ipairs(keys) do
        x = x - weights[k]
        if x < 0 then return k end
    end
    return keys[#keys]
end

local function Party(ctx)
    local out = {}
    for _, src in ipairs(ctx.participants() or {}) do
        local c = ctx.coords(src)
        if c then out[#out + 1] = { src = src, coords = c } end
    end
    return out
end

local function NearestOf(list, coords)
    local best = math.huge
    if not coords then return best end
    for i = 1, #list do
        local d = U.dist(list[i].coords, coords)
        if d < best then best = d end
    end
    return best
end

local function EntCoords(ctx, netId)
    local e = ctx.run.entities[netId]
    if e and e.entity and DoesEntityExist(e.entity) then return GetEntityCoords(e.entity), e.entity end
    return nil
end

local function HoldsWeapon(src)
    if not GetSelectedPedWeapon then return true end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local w = math.floor(tonumber(GetSelectedPedWeapon(ped)) or 0) & 0xFFFFFFFF
    return w ~= 0 and w ~= (math.floor(joaat('WEAPON_UNARMED')) & 0xFFFFFFFF)
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Defaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 30 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.mode == nil then obj.mode = c.mode.default end
    if obj.people == nil then obj.people = c.people[3] end
    if obj.cars == nil then obj.cars = obj.mode == 'parked' and c.minSpots or c.cars[3] end
    if obj.profileSet == nil then
        obj.profileSet = (obj.mode == 'parked' and 'parking') or (obj.mode == 'stop' and 'traffic') or 'scene'
    end
    if obj.spots == nil and obj.mode == 'parked' then obj.spots = 'spots' end
    if obj.car == nil and obj.mode == 'scene' then obj.car = 'car' end
    if obj.peopleSpots == nil and obj.mode == 'scene' then obj.peopleSpots = 'peopleSpots' end
    if obj.fleeTo == nil then obj.fleeTo = 'fleeTo' end
    if obj.transport == nil then obj.transport = 'transport' end
    if obj.scene == nil then obj.scene = U.copy(DEFAULT_SCENE) end
    if obj.approach == nil then obj.approach = c.approach[3] + 0.0 end
    if obj.probableCause == nil then obj.probableCause = c.probableCause.default end
    if obj.custody == nil then obj.custody = c.custody.default end
    if type(obj.returning) ~= 'table' then obj.returning = {} end
    if obj.returning.chance == nil then obj.returning.chance = c.returning[3] / 100 end
    if obj.returning.max == nil then obj.returning.max = 1 end
    if type(obj.thief) ~= 'table' then obj.thief = {} end
    if obj.thief.chance == nil then obj.thief.chance = 0.5 end
    if obj.thief.runAt == nil then obj.thief.runAt = 15.0 end
    if obj.escapeFails == nil then obj.escapeFails = c.escapeFails.default end
    if type(obj.escape) ~= 'table' then obj.escape = {} end
    local fa = Config.Blocks.flee_arrest
    if obj.escape.distance == nil then obj.escape.distance = fa.escapeDistance[3] end
    if obj.escape.seconds == nil then obj.escape.seconds = fa.escapeSeconds[3] end
    if obj.revealed == nil then obj.revealed = {} end
    if obj.bestPoints == nil then obj.bestPoints = c.bestPoints[3] end
    if obj.allCorrect == nil then obj.allCorrect = { id = 'all_correct' } end
    if obj.models == nil then obj.models = U.copy(DEFAULT_MODELS) end
    if obj.vehicles == nil then obj.vehicles = U.copy(DEFAULT_CARS) end
    if obj.weapons == nil then obj.weapons = U.copy(fa.weapons) end
    if type(obj.aliveBonus) ~= 'table' then obj.aliveBonus = { id = 'subject_alive' } end
    return obj
end

local function HasArmedWeight(setName)
    local set = ((Config.Custody or {}).profileSets or {})[setName] or {}
    for role, weights in pairs(set) do
        if role ~= 'vehicle' and type(weights) == 'table' and (tonumber(weights.armed) or 0) > 0 then return true end
    end
    return false
end

-- People rolled armed at run time count at their configured maximum when the truth set can roll armed.
local function ArmedCount(obj)
    local o = Defaults(U.deepcopy(obj))
    if o.mode == 'parked' or not HasArmedWeight(o.profileSet) then return 0 end
    if o.mode == 'stop' then return 3 end
    return math.floor(tonumber(o.people) or 0)
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    if o.mode == 'parked' then return { o.spots } end
    if o.mode == 'scene' then
        local out = { o.peopleSpots }
        if (tonumber(o.cars) or 0) > 0 then table.insert(out, 1, o.car) end
        return out
    end
    return {}
end

local function CheckLocation(o, loc, li, strict)
    local c = Cfg()
    local start = loc.start and loc.start.coords
    local function pointOk(p)
        if InNoBuild(p) then return Bad('block.field_contact.invalid.points_zone', { location = li }) end
        if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
            return Bad('block.field_contact.invalid.points_start',
                { location = li, min = Config.Builder.minSpawnFromStart })
        end
        return true
    end
    if o.mode == 'parked' then
        local spots = SpotList(loc, o.spots)
        local need = strict and math.max(c.minSpots, o.cars) or o.cars
        if #spots < need then
            return Bad('block.field_contact.invalid.spots', { location = li, min = need, have = #spots })
        end
        local rules = (Config.Custody or {}).parkingRules or {}
        for _, s in ipairs(spots) do
            if rules[s.rule] == nil then return Bad('block.field_contact.invalid.rule', { location = li }) end
            local ok, why = pointOk(s.coords)
            if not ok then return false, why end
        end
        return true
    end
    if o.mode == 'scene' then
        local people = PointList(loc, o.peopleSpots)
        local need = strict and 3 or 1
        if #people < need then
            return Bad('block.field_contact.invalid.people_spots', { location = li, min = need, have = #people })
        end
        for _, p in ipairs(people) do
            local ok, why = pointOk(p)
            if not ok then return false, why end
        end
        if (tonumber(o.cars) or 0) > 0 then
            local car = PointList(loc, o.car)[1]
            if not car then return Bad('block.field_contact.invalid.car', { location = li }) end
            local ok, why = pointOk(car)
            if not ok then return false, why end
        end
    end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.field_contact.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    if not U.contains(c.mode.options, o.mode) then return Bad('block.field_contact.invalid.mode') end
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.field_contact.invalid.min_seconds') end
    local function range(field, v, r, scale)
        if InRange(v, r, scale) then return true end
        local s = scale or 1
        return Bad('block.field_contact.invalid.range', { field = field, min = r[1] * s, max = r[2] * s })
    end
    local checks = {
        { 'presenceRange', o.presenceRange, c.presenceRange },
        { 'approach', o.approach, c.approach },
        { 'bestPoints', o.bestPoints, c.bestPoints },
        { 'returning.chance', o.returning.chance, c.returning, 0.01 },
        { 'escape.distance', o.escape.distance, Config.Blocks.flee_arrest.escapeDistance },
        { 'escape.seconds', o.escape.seconds, Config.Blocks.flee_arrest.escapeSeconds },
    }
    for _, ch in ipairs(checks) do
        local ok, why = range(ch[1], ch[2], ch[3], ch[4])
        if not ok then return false, why end
    end
    if o.mode == 'scene' then
        if not IsInt(o.people) or not InRange(o.people, c.people) then
            return Bad('block.field_contact.invalid.range', { field = 'people', min = c.people[1], max = c.people[2] })
        end
        if not IsInt(o.cars) or o.cars < 0 or o.cars > 1 then
            return Bad('block.field_contact.invalid.range', { field = 'cars', min = 0, max = 1 })
        end
    elseif o.mode == 'parked' then
        if not IsInt(o.cars) or not InRange(o.cars, c.cars) or o.cars < 1 then
            return Bad('block.field_contact.invalid.range', { field = 'cars', min = 1, max = c.cars[2] })
        end
    end
    if not U.contains(c.profileSet.options, o.profileSet) then return Bad('block.field_contact.invalid.profile_set') end
    if not U.contains(c.custody.options, o.custody) then return Bad('block.field_contact.invalid.custody') end
    if type(o.probableCause) ~= 'boolean' or type(o.escapeFails) ~= 'boolean' then
        return Bad('block.field_contact.invalid.objective')
    end
    if type(o.revealed) ~= 'table' then return Bad('block.field_contact.invalid.objective') end
    if o.allCorrect ~= false and (type(o.allCorrect) ~= 'table' or type(o.allCorrect.id) ~= 'string') then
        return Bad('block.field_contact.invalid.objective')
    end
    if strict and o.allCorrect and o.allCorrect.points ~= nil then
        return Bad('block.field_contact.invalid.bonus_custom', { id = o.allCorrect.id })
    end
    local armed = ArmedCount(o)
    if armed > Config.Builder.maxHostiles then
        return Bad('block.field_contact.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
    end
    if type(location) == 'table' then return CheckLocation(o, location, 1, strict) end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            local ok, why = CheckLocation(o, loc, li, strict)
            if not ok then return false, why end
        end
    end
    return true
end

-- ============================================================================
--                                  RUN STATE
-- ============================================================================

local function StateOf(ctx)
    Defaults(ctx.obj)
    local st = ctx.state
    if not st.block then
        st.block = BLOCK
        st.mode = ctx.obj.mode
        st.contacts = {}                 -- [netId] = { netId, kind, label, role, far, close }
        st.order = {}
        st.returning = 0
        st.awarded = {}
        st.procedure = {}
    end
    return st
end

local function RngOf(ctx)
    local st = ctx.state
    if not st.rng then st.rng = ctx.rng or U.rng(((ctx.run and ctx.run.seed) or 1) + (ctx.index or 0)) end
    return st.rng
end

local function Track(st, netId, kind, c)
    st.contacts[netId] = { netId = netId, kind = kind, label = c and c.label or '?', far = 0, close = 0 }
    st.order[#st.order + 1] = netId
    st.dirty = true
end

local function TransportPoint(ctx)
    local t = ctx.obj.transport
    local p = t and PointList(ctx.location, t)[1]
    return p and ToVec4(p) or nil
end

local function SpawnPerson(ctx, st, point, profile, extra)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local armed = profile.truth == 'armed'
    local opts = {
        model = r:pick(obj.models) or DEFAULT_MODELS[1],
        coords = point,
        role = extra.role or 'subject',
        armed = armed,
        hidden = true,
        cfg = { group = 'neutral' },
        tag = ('contact%d'):format(#st.order + 1),
    }
    if armed then
        opts.weapon = r:pick(obj.weapons) or 'WEAPON_PISTOL'
        opts.accuracy, opts.armour = ctx.combat(Config.Blocks.hostile_waves.accuracy[3], 0)
    end
    local ent, netId = ctx.spawnPed(opts)
    if not netId then return nil end
    local c = CP.Custody.register(ctx.run, ctx.index, netId, {
        kind = 'person',
        role = extra.role or 'subject',
        truth = profile.truth,
        demeanour = profile.demeanour,
        cues = profile.cues,
        vehicleOf = extra.vehicleOf,
        actions = extra.actions or PERSON_ACTIONS,
        allowWarn = extra.allowWarn,
        custody = obj.custody,
        consensual = extra.consensual,
        transportPoint = TransportPoint(ctx),
        evading = extra.evading,
    })
    Track(st, netId, 'person', c)
    return netId, ent, c
end

local function SpawnCar(ctx, st, point, truth, extra)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local ent, netId = ctx.spawnVehicle({
        model = r:pick(obj.vehicles) or DEFAULT_CARS[1],
        coords = point,
        role = extra.role or 'contact_car',
        tag = ('car%d'):format(#st.order + 1),
    })
    if not netId then return nil end
    if SetVehicleDoorsLocked then SetVehicleDoorsLocked(ent, 2) end
    local c = CP.Custody.register(ctx.run, ctx.index, netId, {
        kind = 'vehicle',
        role = extra.role or 'contact_car',
        truth = truth,
        level = extra.level,
        spot = extra.spot,
        actions = extra.actions or CAR_ACTIONS,
        revealed = extra.revealed,
        state = 'stopped',
    })
    Track(st, netId, 'vehicle', c)
    return netId, ent, c
end

-- ============================================================================
--                                    PARKED
-- ============================================================================

local function SpawnParked(ctx, st)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local rules = (Config.Custody or {}).parkingRules or {}
    if not st.spots then
        local list = SpotList(ctx.location, obj.spots)
        st.spots = r:sample(list, math.min(#list, math.floor(tonumber(obj.cars) or 1)))
        st.truths = {}
        for i, spot in ipairs(st.spots) do
            local truth = CP.Custody.rollTruth(r, obj.profileSet, 'vehicle')
            -- a free spot is legal, or the car is stolen
            if truth == 'violation' and not rules[spot.rule] then truth = 'legal' end
            st.truths[i] = truth
        end
        st.spawnedCars = 0
    end
    while st.spawnedCars < #st.spots do
        if not ctx.canSpawn(1, false) then return false end
        local i = st.spawnedCars + 1
        local spot = st.spots[i]
        local netId = SpawnCar(ctx, st, ToVec4(spot.coords), st.truths[i], {
            role = 'parked',
            level = rules[spot.rule] or nil,
            spot = { rule = spot.rule, street = spot.street },
            actions = PARKED_ACTIONS,
        })
        if not netId then return false end
        st.spawnedCars = i
        if st.stopped then return false end
    end
    return true
end

-- ============================================================================
--                                    SCENE
-- ============================================================================

local function SpawnScene(ctx, st)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local loc = ctx.location
    if not st.plan then
        st.variant = WeightedKey(r, obj.scene) or 'loitering'
        local wantCar = (tonumber(obj.cars) or 0) > 0 and PointList(loc, obj.car)[1] ~= nil
        if st.variant == 'occupied_car' and not wantCar then st.variant = 'loitering' end
        st.plan = {
            car = wantCar,
            carTruth = wantCar and CP.Custody.rollTruth(r, obj.profileSet, 'vehicle') or nil,
            people = {},
        }
        local pts = PointList(loc, obj.peopleSpots)
        local order = r:shuffle(pts)
        for i = 1, math.max(1, math.floor(tonumber(obj.people) or 1)) do
            local ownsCar = wantCar and st.variant ~= 'casing'
            st.plan.people[i] = {
                point = order[((i - 1) % #order) + 1],
                profile = CP.Custody.rollProfile(r, obj.profileSet, 'person', ownsCar),
                seated = st.variant == 'occupied_car' and i == 1,
                ownsCar = ownsCar,
            }
        end
        st.spawnedPeople = 0
    end
    if st.plan.car and not st.carNet then
        if not ctx.canSpawn(1, false) then return false end
        local netId = SpawnCar(ctx, st, ToVec4(PointList(loc, obj.car)[1]), st.plan.carTruth,
            { role = 'scene_car', actions = CAR_ACTIONS })
        if not netId then return false end
        st.carNet = netId
    end
    while st.spawnedPeople < #st.plan.people do
        local i = st.spawnedPeople + 1
        local pl = st.plan.people[i]
        if not ctx.canSpawn(1, pl.profile.truth == 'armed') then return false end
        local netId, ent = SpawnPerson(ctx, st, ToVec4(pl.point), pl.profile, {
            role = pl.seated and 'driver' or 'subject',
            vehicleOf = pl.ownsCar and st.carNet or nil,
            consensual = true,
        })
        if not netId then return false end
        if pl.seated and st.carNet and SetPedIntoVehicle then
            local _, car = EntCoords(ctx, st.carNet)
            if car then SetPedIntoVehicle(ent, car, -1) end
        end
        if i == 1 and st.carNet then
            local car = CP.Custody.get(ctx.run, st.carNet)
            if car and pl.ownsCar then car.owner = netId end
        end
        st.spawnedPeople = i
        if st.stopped then return false end
    end
    return true
end

-- ============================================================================
--                                     STOP
-- ============================================================================
-- run.shared.contacts (written by pursuit): { vehicle = netId, occupants = { { netId, seat, state, truth } },
-- observed = { kind, speed, zone } | nil, forced = bool, profileSet = name, taken = objective index | nil }.

local function OccupantProfile(ctx, set, occ, role, rng)
    local truth = occ.truth
    return CP.Custody.rollProfile(rng, set, role, true, truth)
end

-- A person the pursuit spawned visibly armed keeps that; one rolled armed now gets a hidden weapon for its draw.
local function HideWeapon(ctx, netId)
    local e = ctx.run.entities[netId]
    if not e or e.armed or e.armedTruth then return end
    e.armedTruth = true
    e.hiddenCfg = e.hiddenCfg or {}
    e.hiddenCfg.weapon = e.hiddenCfg.weapon or RngOf(ctx):pick(ctx.obj.weapons) or 'WEAPON_PISTOL'
end

local function TakeStops(ctx, st)
    local run = ctx.run
    local list = run.shared and run.shared.contacts
    if type(list) ~= 'table' then return 0 end
    local r = RngOf(ctx)
    local n = 0
    for _, entry in ipairs(list) do
        local veh = tonumber(entry.vehicle)
        local owner = veh and CP.Runs.ownerOf(run, veh)
        local mine = owner == ctx.index or (entry.taken == nil and owner and owner < ctx.index)
        if veh and run.entities[veh] and not run.entities[veh].dead and mine and entry.taken == nil then
            entry.taken = ctx.index
            if owner ~= ctx.index then CP.Runs.adopt(run, veh, ctx.index) end
            local set = entry.profileSet or ctx.obj.profileSet
            local stolen = U.contains(ctx.obj.revealed, 'stolen')
            local carTruth = stolen and 'stolen' or entry.truth or CP.Custody.rollTruth(r, set, 'vehicle')
            local car = CP.Custody.register(run, ctx.index, veh, {
                kind = 'vehicle',
                role = 'stopped_car',
                truth = carTruth,
                actions = CAR_ACTIONS,
                revealed = ctx.obj.revealed,
                state = 'stopped',
            })
            Track(st, veh, 'vehicle', car)
            for _, occ in ipairs(type(entry.occupants) == 'table' and entry.occupants or {}) do
                local netId = tonumber(type(occ) == 'table' and occ.netId or occ)
                if netId and run.entities[netId] and not run.entities[netId].dead then
                    if CP.Runs.ownerOf(run, netId) ~= ctx.index then CP.Runs.adopt(run, netId, ctx.index) end
                    local role = (type(occ) == 'table' and occ.seat == -1) and 'driver' or 'passenger'
                    local profile = OccupantProfile(ctx, set, type(occ) == 'table' and occ or {}, role, r)
                    if profile.truth == 'armed' then HideWeapon(ctx, netId) end
                    local state = type(occ) == 'table' and occ.state or nil
                    local c = CP.Custody.register(run, ctx.index, netId, {
                        kind = 'person',
                        role = role,
                        truth = profile.truth,
                        demeanour = profile.demeanour,
                        cues = profile.cues,
                        vehicleOf = veh,
                        actions = STOP_PERSON_ACTIONS,
                        allowWarn = true,
                        custody = ctx.obj.custody,
                        observed = role == 'driver' and entry.observed ~= nil or nil,
                        evading = entry.forced == true or state == 'fleeing' or state == 'cuffed',
                        ran = state == 'fleeing' or state == 'cuffed',
                        caught = state == 'cuffed',
                        state = (state == 'cuffed' and 'cuffed') or (state == 'fleeing' and 'fleeing') or 'idle',
                        transportPoint = TransportPoint(ctx),
                    })
                    if c and role == 'driver' and not stolen then car.owner = netId end
                    Track(st, netId, 'person', c)
                end
            end
            n = n + 1
        end
    end
    return n
end

-- ============================================================================
--                             SPAWNING (with caps)
-- ============================================================================

local function GuardedSpawn(ctx, st, fn)
    if st.spawning or st.stopped or st.spawned then return st.spawned end
    st.spawning = true
    local okCall, ok = pcall(fn, ctx, st)
    st.spawning = false
    if not okCall then
        CP.err(BLOCK, 'spawning for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(ok))
        return false
    end
    if ok then st.spawned = true end
    return ok
end

local function Spawn(ctx, st)
    if st.mode == 'parked' then return GuardedSpawn(ctx, st, SpawnParked) end
    if st.mode == 'scene' then return GuardedSpawn(ctx, st, SpawnScene) end
    if st.spawned then return true end
    TakeStops(ctx, st)
    st.stopTries = (st.stopTries or 0) + 1
    -- a stop with nothing handed over (the car was lost) has nothing to work after a few ticks
    if #st.order > 0 or st.stopTries >= 3 then st.spawned = true end
    return st.spawned
end

-- ============================================================================
--                        REACTIONS, RUNNERS AND ESCAPES
-- ============================================================================

local function FleePoints(ctx, netId)
    local list = ctx.location and ctx.location[ctx.obj.fleeTo]
    if type(list) ~= 'table' or #list == 0 then return nil end
    local route = list[((netId - 1) % #list) + 1]
    return U.serialize(PointList(nil, route))
end

-- Scene mode: the first participant within approach sets every person off by demeanour (walk away, run, a
-- tell and a draw, or they stay and talk).
local function Approach(ctx, st, party)
    if st.approached or st.mode ~= 'scene' then return end
    local near = false
    for _, t in pairs(st.contacts) do
        if t.kind == 'person' then
            local pc = EntCoords(ctx, t.netId)
            if pc and NearestOf(party, pc) <= ctx.obj.approach then near = true end
        end
    end
    if not near then return end
    st.approached = true
    for _, netId in ipairs(st.order) do
        local c = CP.Custody.get(ctx.run, netId)
        if c and c.kind == 'person' and c.state == 'idle' then
            local d = c.demeanour
            if d == 'hostile' then
                CP.Custody.act(ctx.run, netId, 'tell_then_draw')
            elseif d == 'runner' then
                CP.Custody.act(ctx.run, netId, 'flee_on_approach', { points = FleePoints(ctx, netId) })
            elseif d == 'evasive' then
                CP.Custody.act(ctx.run, netId, 'walk_away', { points = FleePoints(ctx, netId) })
            elseif not c.seat then
                local ent = ctx.run.entities[netId] and ctx.run.entities[netId].entity
                local inCar = ent and GetVehiclePedIsIn(ent, false) or 0
                if not inCar or inCar == 0 then
                    c.state = 'contacted'
                    CP.Npc.setState(ctx.run, netId, 'contacted',
                        { contact = { label = c.label, kind = c.kind, actions = U.copy(c.actions) } })
                end
            end
        end
    end
    st.dirty = true
end

local function Surrender(ctx, st, c)
    local run = ctx.run
    if c.state == 'fleeing' or c.state == 'hostile' then
        c.state = 'surrendered'
        if CP.Runs.notePerson then CP.Runs.notePerson(run, c.netId, { did = 'surrendered' }) end
        CP.Npc.setState(run, c.netId, 'surrendered',
            { contact = { label = c.label, kind = c.kind, actions = U.copy(c.actions) } })
        CP.Npc.enableCuff(run, c.netId, { label = CP.L('npc.cuff'), duration = 5000 })
    elseif c.walking then
        -- a walking person stops: consensual contact, free to leave, still there to talk to
        c.walking = false
        c.state = 'contacted'
        CP.Npc.setState(run, c.netId, 'contacted',
            { contact = { label = c.label, kind = c.kind, actions = U.copy(c.actions) } })
    end
    st.dirty = true
end

local function Fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

-- Parked mode: the thief near a stolen car runs once an officer is within thief.runAt.
local function ThiefWatch(ctx, st, party)
    local th = st.thief
    if not th or th.ran then return end
    local c = CP.Custody.get(ctx.run, th.netId)
    local pc = EntCoords(ctx, th.netId)
    if not c or not pc then return end
    if NearestOf(party, pc) <= (tonumber(ctx.obj.thief.runAt) or 15.0) then
        th.ran = true
        CP.Custody.act(ctx.run, th.netId, 'flee_on_approach', { points = FleePoints(ctx, th.netId) })
    end
end

local function Escaped(ctx, st, c, t)
    t.escaped = true
    CP.Custody.markGone(ctx.run, c.netId, 'escaped')
    if ctx.obj.escapeFails then
        Fail(ctx, st, 'block.field_contact.fail_escaped')
        return
    end
    ctx.penalize('missed_arrest', { count = 1 })
    ctx.delete(c.netId)
    ctx.hud({ message = { text = CP.Lt('block.field_contact.escaped', { label = c.label }), kind = 'warning' } })
end

local function Watch(ctx, st, dt)
    local party = Party(ctx)
    Approach(ctx, st, party)
    ThiefWatch(ctx, st, party)
    local esc = ctx.obj.escape
    local worst = 0
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local c = CP.Custody.get(ctx.run, netId)
        if t and c and t.kind == 'person' and not t.escaped and not c.dead then
            local pc = EntCoords(ctx, netId)
            if pc and (c.state == 'fleeing' or c.walking) then
                local near = NearestOf(party, pc)
                if #party > 0 and near > esc.distance then
                    t.far = (t.far or 0) + dt
                    if c.walking then
                        -- walking off a consensual contact is lawful: they leave, nobody is penalised
                        if t.far >= esc.seconds then
                            t.escaped = true
                            CP.Custody.markGone(ctx.run, netId, 'walked')
                            ctx.delete(netId)
                            st.dirty = true
                        end
                    elseif t.far >= esc.seconds then
                        Escaped(ctx, st, c, t)
                        if st.failed then return end
                    elseif t.far > worst then
                        worst = t.far
                    end
                else
                    t.far = 0
                end
                if not t.escaped and near <= CLOSE_RANGE then
                    t.close = (t.close or 0) + dt
                    if t.close >= CLOSE_SECONDS and (c.walking or not ctx.run.entities[netId].armedGiven) then
                        Surrender(ctx, st, c)
                        t.close = 0
                    end
                else
                    t.close = 0
                end
            elseif not pc and not c.dead and c.state ~= 'handed_over' and c.state ~= 'released' then
                -- vanished without a death: gone
                t.escaped = true
                CP.Custody.markGone(ctx.run, netId, 'vanished')
            end
        end
    end
    local escaping = worst > 0 and math.max(0, math.ceil(esc.seconds - worst)) or nil
    if escaping ~= st.escaping then
        st.escaping = escaping
        st.dirty = true
    end
end

-- ============================================================================
--                   RETURNING DRIVER AND THE THIEF (parked)
-- ============================================================================

local function SpawnNear(ctx, st, carNet, offset, profile, extra)
    local cc = EntCoords(ctx, carNet)
    if not cc then return nil end
    local r = RngOf(ctx)
    local a = r:next() * math.pi * 2
    local point = vector4(cc.x + math.cos(a) * offset, cc.y + math.sin(a) * offset, cc.z + 0.0, 0.0)
    return SpawnPerson(ctx, st, point, profile, extra)
end

local function ReturningDriver(ctx, st, car, choice)
    local ret = ctx.obj.returning
    if st.mode ~= 'parked' or car.truth == 'stolen' then return end
    if st.returning >= (tonumber(ret.max) or 1) then return end
    local r = RngOf(ctx)
    if not r:chance(tonumber(ret.chance) or 0) then return end
    if not ctx.canSpawn(1, false) then return end
    st.returning = st.returning + 1
    local x = r:next()
    local outcome = x < 0.6 and 'takes' or (x < 0.9 and 'argues' or 'drives_off')
    if outcome == 'drives_off' and choice ~= 'cite' then outcome = 'takes' end
    local profile = { truth = 'clean', demeanour = 'compliant', cues = {} }
    local netId, _, c = SpawnNear(ctx, st, car.netId, RETURN_OFFSET, profile,
        { role = 'returning_driver', actions = { 'explain' }, consensual = true })
    if not netId then return end
    local t = st.contacts[netId]
    t.returning = { outcome = outcome, car = car.netId, at = Now() }
    c.state = 'contacted'
    c.decided = { choice = 'none', by = '', bySrc = nil, verdict = 'ok' }
    CP.Npc.setState(ctx.run, netId, 'contacted',
        { contact = { label = c.label, kind = 'person', actions = { 'explain' } } })
    CP.Custody.act(ctx.run, netId, 'walk_to', { veh = car.netId })
    if outcome == 'argues' then c.arguing = true end
    ctx.hud({
        message = {
            text = CP.Lt('block.field_contact.returning_' .. outcome, { label = c.label }),
            kind = 'info',
        },
    })
    st.dirty = true
end

local function ReturningTick(ctx, st)
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local rd = t and t.returning
        if rd and not rd.done and Now() - rd.at >= RETURN_WALK_S * 1000 then
            local c = CP.Custody.get(ctx.run, netId)
            if rd.outcome == 'takes' or (rd.outcome == 'argues' and c and not c.arguing) then
                rd.done = true
                CP.Custody.act(ctx.run, netId, 'leave')
                SetTimeout(30000, function() if ctx.run.state ~= 'ended' then ctx.delete(netId) end end)
            elseif rd.outcome == 'drives_off' then
                rd.done = true
                local _, car = EntCoords(ctx, rd.car)
                local ent = ctx.run.entities[netId] and ctx.run.entities[netId].entity
                if car and ent and SetPedIntoVehicle then SetPedIntoVehicle(ent, car, -1) end
                local carC = CP.Custody.get(ctx.run, rd.car)
                if carC then
                    carC.state = 'released'
                    CP.Npc.setState(ctx.run, rd.car, 'released',
                        { contact = { label = carC.label, kind = 'vehicle', actions = {} } })
                end
                CP.Custody.act(ctx.run, netId, 'drive_off', { veh = rd.car })
                SetTimeout(30000, function()
                    if ctx.run.state ~= 'ended' then
                        ctx.delete(netId)
                        ctx.delete(rd.car)
                    end
                end)
            end
            st.dirty = true
        end
    end
end

local function MaybeThief(ctx, st, car)
    if st.mode ~= 'parked' or st.thiefRolled or car.truth ~= 'stolen' then return end
    st.thiefRolled = true
    local r = RngOf(ctx)
    if not r:chance(tonumber(ctx.obj.thief.chance) or 0) then return end
    local profile = { truth = 'evading', demeanour = 'runner', cues = {} }
    local netId, _, c = SpawnNear(ctx, st, car.netId, THIEF_OFFSET, profile, {
        role = 'thief',
        actions = { 'talk', 'searchPerson', 'release', 'cite', 'arrest' },
        evading = true,
    })
    if not netId then return end
    c.vehicleOf = nil
    st.thief = { netId = netId, ran = false }
end

-- ============================================================================
--                                  COMPLETION
-- ============================================================================

local function Resolved(ctx, st, t, c)
    if not c then return true end
    if t.escaped or c.dead or c.escaped then return true end
    if t.returning then return t.returning.done == true end
    if c.chain and not c.decided then return c.state == 'handed_over' end
    if not c.decided then return false end
    if c.decided.choice == 'arrest' then
        if c.custody == 'handover' then return c.state == 'handed_over' end
        return true
    end
    return true
end

local function Totals(ctx, st)
    local done, total = 0, 0
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        if not t.returning then
            total = total + 1
            if Resolved(ctx, st, t, CP.Custody.get(ctx.run, netId)) then done = done + 1 end
        end
    end
    return done, total
end

-- procedure_complete: once per officer, every person they arrested was ID-checked and searched before transport.
local function Procedure(ctx, st)
    local by = {}
    for _, netId in ipairs(st.order) do
        local c = CP.Custody.get(ctx.run, netId)
        if c and c.kind == 'person' and c.decided and c.decided.choice == 'arrest' and c.arrestedBy then
            local ok = c.done.talk and c.done.searchPerson
            if by[c.arrestedBy] == nil then by[c.arrestedBy] = true end
            if not ok then by[c.arrestedBy] = false end
        end
    end
    local run = ctx.run
    run.shared.procedureAwarded = run.shared.procedureAwarded or {}
    for src, ok in pairs(by) do
        if ok and not run.shared.procedureAwarded[src] then
            run.shared.procedureAwarded[src] = true
            ctx.award('procedure_complete', { src = src })
        end
    end
end

local function AllCorrect(ctx, st)
    local ac = ctx.obj.allCorrect
    if not ac then return end
    local n = 0
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local c = CP.Custody.get(ctx.run, netId)
        if c and not t.returning and not c.chain then
            if not c.decided or c.decided.verdict ~= 'best' then return end
            n = n + 1
        end
    end
    if n > 0 then ctx.award(ac.id, { count = 1, points = TrustedFile(ctx) and ac.points or nil }) end
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.stopped or not st.spawned then return end
    local done, total = Totals(ctx, st)
    if done < total then return end
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        if t.returning and not t.returning.done then return end
    end
    if not st.finalised then
        st.finalised = true
        AllCorrect(ctx, st)
        Procedure(ctx, st)
    end
    if ctx.complete({ decided = done, total = total }) ~= false then st.completed = true end
end

-- ============================================================================
--                            HUD AND CLIENT UPDATES
-- ============================================================================

local function Flush(ctx, st)
    local done, total = Totals(ctx, st)
    if st.dirty then
        st.dirty = false
        local list = {}
        for _, netId in ipairs(st.order) do
            local t = st.contacts[netId]
            local c = CP.Custody.get(ctx.run, netId)
            list[#list + 1] = {
                netId = netId,
                kind = t.kind,
                label = t.label,
                done = Resolved(ctx, st, t, c),
                spot = c and c.spot and c.spot.street or nil,
            }
        end
        ctx.send({ contacts = list, mode = st.mode, escaping = st.escaping, approached = st.approached == true })
    end
    local text
    if st.escaping then
        text = CP.Lt('block.field_contact.escaping', { seconds = st.escaping })
    elseif not st.spawned then
        text = CP.Lt('block.field_contact.detail_wait')
    else
        text = CP.Lt('block.field_contact.detail', { done = done, total = total })
    end
    local key = ('%s:%d:%d'):format(tostring(st.escaping), done, total)
    if key ~= st.hudKey then
        st.hudKey = key
        ctx.hud({ detail = text, value = done, max = total })
    end
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnAction(ctx, st, src, ev)
    local c = CP.Custody.get(ctx.run, ev.netId)
    if not c then return true end
    if ev.action == 'inspect' and c.kind == 'vehicle' then MaybeThief(ctx, st, c) end
    st.dirty = true
    return true
end

local function OnDecide(ctx, st, src, ev)
    local c = CP.Custody.get(ctx.run, ev.netId)
    if not c then return true end
    if c.kind == 'vehicle' and (ev.choice == 'cite' or ev.choice == 'impound') then
        ReturningDriver(ctx, st, c, ev.choice)
    end
    -- vehicle_impounded (a card bonus, e.g. Stolen Vehicle Takedown): each car lawfully impounded, shared
    local good = ev.verdict == 'best' or ev.verdict == 'ok'
    if c.kind == 'vehicle' and ev.choice == 'impound' and good and CardLists(ctx, 'vehicle_impounded') then
        ctx.award('vehicle_impounded', { count = 1 })
    end
    st.dirty = true
    return true
end

local function OnCuffed(ctx, st, src, ev)
    local c = CP.Custody.get(ctx.run, ev.netId)
    if not c then return false, 'unknown_entity' end
    local ranOrDrew = c.ran or c.drew
    CP.Custody.onCuffed(ctx.run, ev.netId, src)
    -- a Cuff suspect on a person who ran or drew is their arrest (one per person) and the catch bonus
    if ranOrDrew then
        CP.Runs.noteArrest(ctx.run, src, ev.netId)
        if not st.awarded[ev.netId] then
            st.awarded[ev.netId] = true
            local ab = ctx.obj.aliveBonus
            ctx.award(ab.id or 'subject_alive', { count = 1, points = TrustedFile(ctx) and ab.points or nil })
        end
    end
    st.dirty = true
    return true
end

local function OnGiveUp(ctx, st, src, ev)
    local t = st.contacts[tonumber(ev.netId)]
    local c = t and CP.Custody.get(ctx.run, t.netId)
    if not c then return false, 'unknown_entity' end
    if not (c.state == 'fleeing' or c.walking or (c.state == 'hostile' and ev.type == 'stunned')) then
        return false, 'wrong_state'
    end
    local pc, sc = EntCoords(ctx, t.netId), ctx.coords(src)
    if not pc or not sc then return false, 'too_far' end
    if ev.type == 'aim' then
        if c.state == 'hostile' then return false, 'armed' end
        if U.dist(pc, sc) > AIM_RANGE + REACH_SLACK then return false, 'too_far' end
        if not HoldsWeapon(src) then return false, 'no_weapon' end
    else
        if U.dist(pc, sc) > STUN_RANGE + REACH_SLACK then return false, 'too_far' end
    end
    Surrender(ctx, st, c)
    return true
end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local ok, why = true, nil
    local t = ev.type
    if t == 'action' then
        ok, why = OnAction(ctx, st, src, ev)
    elseif t == 'decide' then
        ok, why = OnDecide(ctx, st, src, ev)
    elseif t == 'cuffed' then
        ok, why = OnCuffed(ctx, st, src, ev)
    elseif t == 'aim' or t == 'stunned' then
        ok, why = OnGiveUp(ctx, st, src, ev)
    elseif t == 'handed_over' or t == 'impounded' then
        st.dirty = true
    elseif t == 'removed' then
        -- a run vehicle removed from outside (sc-police /imp): never an Impound disposition
        local c = CP.Custody.get(ctx.run, ev.netId)
        if c then CP.Custody.markGone(ctx.run, ev.netId, 'removed') end
        st.dirty = true
    elseif t == 'shot' or t == 'damaged' then
        ok = true
    else
        return false, 'unknown_event'
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
    return ok, why
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Start(ctx)
    local st = StateOf(ctx)
    st.stopped = nil
    Spawn(ctx, st)
    st.dirty = true
    Flush(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    if st.stopped or st.failed then return end
    if not st.completed then
        Spawn(ctx, st)
        Watch(ctx, st, tonumber(dt) or 1)
        if st.failed then return end
        ReturningTick(ctx, st)
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local t = st.contacts[netId]
    if not t then return end
    local c = CP.Custody.get(ctx.run, netId)
    if not c or c.dead then return end
    local drew = ctx.run.entities[netId] and ctx.run.entities[netId].armedGiven
    local prev = c.state
    CP.Custody.markDead(ctx.run, netId)
    st.dirty = true
    -- killing a person who never drew a weapon fails the case (compliant, surrendered, in custody or unarmed)
    if c.kind == 'person' and killerSrc and ctx.run.participants[killerSrc] and not (drew and prev == 'hostile') then
        Fail(ctx, st, 'run.fail_killed_unarmed')
        return
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function Presence(ctx, src, coords)
    local st = StateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local c = CP.Custody.get(ctx.run, netId)
        if not Resolved(ctx, st, t, c) then
            local pc = EntCoords(ctx, netId)
            if pc then
                local d = U.dist(coords, pc)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local ref = ctx.location and ctx.location.start and ctx.location.start.coords
        best = ref and U.dist(coords, ref) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local done, total = Totals(ctx, st)
    return {
        {
            label = CP.L('block.field_contact.check_decided'),
            done = st.spawned == true and total > 0 and done >= total,
            value = done,
            max = total,
        },
    }
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for _, netId in ipairs(st.order) do ctx.delete(netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    Start(ctx)
end

local function OnTimeout(ctx)
    -- every contact still undecided counts as missed (never a fail of its own)
    CP.Custody.closeObjective(ctx.run, ctx.index)
    return nil
end

CP.Blocks.register(BLOCK, {
    defaults = Defaults,
    validate = Validate,
    armedCount = ArmedCount,
    requiredPoints = RequiredPoints,
    prepare = function(ctx) StateOf(ctx) end,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    onEntityDead = OnEntityDead,
    onParticipantLeft = function(ctx)
        local st = StateOf(ctx)
        st.dirty = true
        Flush(ctx, st)
    end,
    rescale = function(ctx)
        local st = StateOf(ctx)
        st.dirty = true
        Flush(ctx, st)
    end,
    onTimeout = OnTimeout,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = function(ctx)
        local st = StateOf(ctx)
        st.stopped = true
    end,
})
