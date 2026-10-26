-- Objective block "field_contact" (server half): parked cars, a scene contact or a stop, worked with police
-- actions and graded dispositions (CP.Custody). Modes: parked, scene, stop.

local BLOCK = 'field_contact'
local U = CP.U

local REACH_SLACK = 2.0                  -- metres of position lag allowed around interaction ranges
local AIM_RANGE = 10.0                   -- a fleeing person gives up when aimed at this close
local STUN_RANGE = 30.0                  -- a stun needs a participant this close to the person
local CLOSE_RANGE = 3.0                  -- ...or a participant stays this close...
local CLOSE_SECONDS = 3                  -- ...for this long
local RETURN_OFFSET = 14.0               -- metres from the car where a returning driver appears (director off)
local THIEF_OFFSET = 30.0                -- metres from the car where the thief waits (director off)
local RETURN_WALK_S = 8                  -- seconds a returning driver takes to reach the car (director off)
local WALK_IN_CALLBACK = 'crimson-police:client:spawn:walkIn'
local WALK_IN_POLL_MS = 50               -- milliseconds between looks at the officer's answer
local WALK_IN_MARGIN_MS = 250            -- of losTimeoutMs, kept for the answer's way back
local RING_SLACK = 1.0                   -- metres an answer may sit outside contactRing (the game's rounding)
local OFFICER_SLACK = 5.0                -- metres an officer may have walked towards it while his game looked
local WALK_IN_Z_MAX = 15.0               -- metres an answer may sit over or under the car
local RING_TRIES = 12                    -- points round the car tried when his game gives none
local WALK_IN_ALT = 4                    -- other points kept for the placer (Config.Spawning.place)
local ARRIVE_M = 4.0                     -- metres from the car: a returning driver has walked up to it
local WALK_MPS = 1.0                     -- metres a second he walks: at the latest after the walk at this pace...
local ARRIVE_PAUSE_S = 3                 -- ...and this long at the car, he takes the ticket, argues or drives off
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

-- What appears at each location key this objective uses, for the spawn point check (Admin UI -> Testing,
-- modules/testing; ARCHITECTURE 7.1 pointKinds): the parked or scene cars and the prisoner van's
-- stand-by spot are vehicles, the scene's people are people, the flee route is a path.
local function PointKinds(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    local car = type(o.vehicles) == 'table' and type(o.vehicles[1]) == 'string' and o.vehicles[1] or nil
    local function add(k, kind, model)
        if type(k) == 'string' then out[#out + 1] = { key = k, kind = kind, model = model } end
    end
    if o.mode == 'parked' then
        add(o.spots, 'vehicle', car)
    elseif o.mode == 'scene' then
        add(o.car, 'vehicle', car)
        add(o.peopleSpots, 'ped')
    end
    add(o.fleeTo, 'path')
    add(o.transport, 'vehicle')
    return out
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
        alt = extra.alt,
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
--                             WHEN A SCENE APPEARS
-- ============================================================================
-- The spawn director, Config.Spawning.
-- With the spawn director on, a scene (the scene mode's car and people, each parked car) appears once an officer is
-- within activateRange of it while every officer is further than the objective's approach distance plus
-- sceneOutside from it: it is there before the officers are on top of it. An officer standing closer keeps it waiting;
-- after waveDelayMax the distance drops to hardMin (never lower), after sceneWaitMax it appears anyway with one warning
-- (0 = it waits for ever). Nobody within activateRange: nothing waits (the clock starts when an officer gets there).

local function SpawnCfg() return type(Config.Spawning) == 'table' and Config.Spawning or {} end

-- The spawn director decides when and where this block's people appear (off: as before).
local function Directed() return SpawnCfg().enabled ~= false end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v
end

local function RunTag(ctx)
    local run = ctx.run or {}
    local loc = ctx.location or {}
    return tostring(run.id), tostring(run.missionId), tostring(loc.label or '?')
end

-- One console line per key (a scene that waits asks again every second).
local function SayOnce(st, key)
    st.said = st.said or {}
    if st.said[key] then return false end
    st.said[key] = true
    return true
end

-- true when the scene name (its points) may appear now (see above); with the director off always.
local function SceneReady(ctx, st, name, points)
    if not Directed() then return true end
    local cfg = SpawnCfg()
    local near, closest = false, math.huge
    for _, p in ipairs(points) do
        local n, best = ctx.whenNear(p)
        if n == true then near = true end
        if tonumber(best) and best < closest then closest = best end
    end
    st.sceneWait = st.sceneWait or {}
    if not near then
        st.sceneWait[name] = nil
        return false
    end
    local now = Now()
    local since = st.sceneWait[name] or now
    st.sceneWait[name] = since
    local waited = (now - since) / 1000
    local base = math.max(0, Num(ctx.obj.approach, 25.0) + Num(cfg.sceneOutside, 10.0))
    local need = base
    if waited >= Num(cfg.waveDelayMax, 20) then need = math.min(base, math.max(0, Num(cfg.hardMin, 20.0))) end
    local id, mission, place = RunTag(ctx)
    if closest > need then
        st.sceneWait[name] = nil
        if closest <= base and cfg.log ~= false and SayOnce(st, 'closer|' .. name) then
            CP.warn(BLOCK,
                'run %s (%s, %s): %s waited %.0f s for the officers to step back to %.0f m; it appeared %.0f m from one (never under Config.Spawning.hardMin)',
                id, mission, place, name, waited, base, closest)
        end
        return true
    end
    local maxWait = math.max(0, Num(cfg.sceneWaitMax, 45))
    if maxWait > 0 and waited >= maxWait then
        st.sceneWait[name] = nil
        CP.warn(BLOCK,
            'run %s (%s, %s): %s appeared %.0f m from an officer after %.0f s of waiting (Config.Spawning.sceneWaitMax); move the start of this place further out',
            id, mission, place, name, closest, waited)
        return true
    end
    if cfg.log ~= false and SayOnce(st, 'wait|' .. name) then
        CP.log(BLOCK, 'run %s: %s waits: an officer is %.0f m from it, it appears beyond %.0f m', id, name, closest,
            need)
    end
    return false
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
        local key = type(obj.spots) == 'string' and obj.spots or 'spots'
        st.spots = r:sample(list, math.min(#list, math.floor(tonumber(obj.cars) or 1)))
        st.truths = {}
        st.spotNames = {}
        for i, spot in ipairs(st.spots) do
            local truth = CP.Custody.rollTruth(r, obj.profileSet, 'vehicle')
            -- a free spot is legal, or the car is stolen
            if truth == 'violation' and not rules[spot.rule] then truth = 'legal' end
            st.truths[i] = truth
            local at = i
            for j, s2 in ipairs(list) do
                if s2 == spot then at = j end
            end
            st.spotNames[i] = ('%s[%d]'):format(key, at)
        end
        st.spawnedCars = 0
        st.carAt = {}
        st.planned = #st.spots
    end
    -- each car once an officer is near it but not on top of it (the director), in any order
    for i, spot in ipairs(st.spots) do
        if not st.carAt[i] and SceneReady(ctx, st, st.spotNames[i], { spot.coords }) then
            if not ctx.canSpawn(1, false) then return false end
            local netId = SpawnCar(ctx, st, ToVec4(spot.coords), st.truths[i], {
                role = 'parked',
                level = rules[spot.rule] or nil,
                spot = { rule = spot.rule, street = spot.street },
                actions = PARKED_ACTIONS,
            })
            if not netId then return false end
            st.carAt[i] = netId
            st.spawnedCars = st.spawnedCars + 1
            if st.stopped then return false end
        end
    end
    return st.spawnedCars >= #st.spots
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
        st.planned = (st.plan.car and 1 or 0) + #st.plan.people
    end
    -- the whole scene at once, once an officer is near it but not on top of it (the director)
    if not st.sceneGo then
        local pts = {}
        if st.plan.car then pts[#pts + 1] = PointList(loc, obj.car)[1] end
        for _, pl in ipairs(st.plan.people) do pts[#pts + 1] = pl.point end
        if not SceneReady(ctx, st, 'the scene', pts) then return false end
        st.sceneGo = true
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

-- task: the one-off task a runner gives up with (CP.Npc.wornOut's 'handsUp'); nil = he kneels.
local function Surrender(ctx, st, c, task)
    local run = ctx.run
    if c.state == 'fleeing' or c.state == 'hostile' then
        c.state = 'surrendered'
        if CP.Runs.notePerson then CP.Runs.notePerson(run, c.netId, { did = 'surrendered' }) end
        CP.Npc.setState(run, c.netId, 'surrendered',
            { contact = { label = c.label, kind = c.kind, actions = U.copy(c.actions) }, task = task })
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
                -- worn out (Config.Flee): a runner gives up once a participant is within giveUpRange (a person who
                -- walks off a consensual contact is not running; CP.Npc's flee clock never tires one in a car)
                if not t.escaped and c.state == 'fleeing' and not c.walking and CP.Npc.wornOut then
                    local tired, task = CP.Npc.wornOut(netId, near)
                    if tired then
                        Surrender(ctx, st, c, task)
                        t.close = 0
                    end
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

-- With the spawn director on (Config.Spawning), the returning driver and the thief appear contactRing metres from the
-- car, on a footpath point the game of the officer at the car picks (modules/spawn/client.lua Spawn.walkIn: in front of
-- him, out of his sight first), and walk up to the car once an officer's game has put them on the ground (WalkTick).
-- No usable answer within losTimeoutMs: points round the car at those distances, ring[1] or more from every officer,
-- the ones in front of him first. The ask waits for his game, so the person appears a moment later, in a thread;
-- st.walkIns counts the ones on the way and the objective does not end before they are there. Director off: 14 m
-- (driver) or 30 m (thief) from the car at a random angle, at once, as before.

local function Ring()
    local r = SpawnCfg().contactRing
    local a = type(r) == 'table' and Num(r[1], nil) or nil
    local b = type(r) == 'table' and Num(r[2], nil) or nil
    a, b = math.max(0, a or 25.0), math.max(0, b or 40.0)
    if b < a then a, b = b, a end
    return a, b
end

-- The officer whose game picks the point: src when he is an active participant with a ped, else the one nearest the
-- car (nil: nobody).
local function AskedOfficer(ctx, src, cc)
    local party = Party(ctx)
    for _, p in ipairs(party) do
        if p.src == src then return p end
    end
    local best, bestD = nil, math.huge
    for _, p in ipairs(party) do
        local d = U.dist2d(p.coords, cc)
        if d < bestD then best, bestD = p, d end
    end
    return best
end

-- The officer's game's answer (a list of { x, y, z }), or nil when it gave none within losTimeoutMs.
local function AskWalkIn(src, cc, r1, r2)
    if type(lib) ~= 'table' or type(lib.callback) ~= 'table' or type(lib.callback.await) ~= 'function' then
        return nil
    end
    local timeout = math.max(100, math.min(5000, Num(SpawnCfg().losTimeoutMs, 1500)))
    local args = {
        car = { x = cc.x + 0.0, y = cc.y + 0.0, z = cc.z + 0.0 },
        ring = { r1, r2 },
        ms = math.max(50, timeout - WALK_IN_MARGIN_MS),
    }
    local done, reply = false, nil
    CreateThread(function()
        local ok, res = pcall(lib.callback.await, WALK_IN_CALLBACK, src, args)
        reply = ok and type(res) == 'table' and res or nil
        done = true
    end)
    local deadline = Now() + timeout
    while not done and Now() < deadline do Wait(WALK_IN_POLL_MS) end
    return done and reply or nil
end

-- A point of the answer the server takes: ring metres from the car (RING_SLACK), not far over or under it, ring[1]
-- (less OFFICER_SLACK) or more from every officer, outside the no-build zones.
local function Usable(p, cc, r1, r2, party)
    if type(p) ~= 'table' then return nil end
    local x, y, z = Num(p.x, nil), Num(p.y, nil), Num(p.z, nil)
    if not (x and y and z) then return nil end
    local v = vector3(x + 0.0, y + 0.0, z + 0.0)
    local d = U.dist2d(v, cc)
    if d < r1 - RING_SLACK or d > r2 + RING_SLACK or math.abs(z - cc.z) > WALK_IN_Z_MAX then return nil end
    for _, o in ipairs(party) do
        if U.dist2d(o.coords, v) < r1 - OFFICER_SLACK then return nil end
    end
    if InNoBuild(v) then return nil end
    return v
end

-- true when v lies in front of the officer o (within 90 degrees of where his ped faces); true when that is unknown.
local function InFront(o, v)
    if not o or not GetPlayerPed or not GetEntityHeading then return true end
    local ok, h = pcall(function() return GetEntityHeading(GetPlayerPed(o.src)) end)
    h = ok and Num(h, nil) or nil
    if not h then return true end
    local r = math.rad(h)
    return (v.x - o.coords.x) * -math.sin(r) + (v.y - o.coords.y) * math.cos(r) >= 0
end

-- No answer: RING_TRIES points round the car from the angle a0, at ring[1], halfway and ring[2] in turn, the ones
-- ring[1] or more from every officer (in front of the asked one first); with none that far, the one furthest from
-- them.
local function RingPoints(cc, r1, r2, a0, party, asked)
    local front, back, best, bestD = {}, {}, nil, -1
    for k = 0, RING_TRIES - 1 do
        local a = a0 + k * 2 * math.pi / RING_TRIES
        local d = r1 + (r2 - r1) * (k % 3) / 2
        local v = vector3(cc.x + math.cos(a) * d, cc.y + math.sin(a) * d, cc.z + 0.0)
        local nearest = math.huge
        for _, o in ipairs(party) do nearest = math.min(nearest, U.dist2d(o.coords, v)) end
        if nearest >= r1 then
            if InFront(asked, v) then front[#front + 1] = v else back[#back + 1] = v end
        elseif nearest > bestD then
            best, bestD = v, nearest
        end
    end
    for _, v in ipairs(back) do front[#front + 1] = v end
    if #front == 0 and best then front[1] = best end
    return front
end

-- The heading that faces from v to the car at cc.
local function Facing(v, cc)
    return (math.deg(math.atan(-(cc.x - v.x), cc.y - v.y)) % 360) + 0.0
end

-- Spawns a person (profile, extra) for the car carNet (see above); after(netId, ent, c, walksIn) once he is there
-- (walksIn: the director placed him, WalkTick walks him up). src: the officer at the car.
local function SpawnNear(ctx, st, carNet, offset, profile, extra, src, after)
    local cc = EntCoords(ctx, carNet)
    if not cc then return end
    local r = RngOf(ctx)
    local a = r:next() * math.pi * 2
    if not Directed() then
        local point = vector4(cc.x + math.cos(a) * offset, cc.y + math.sin(a) * offset, cc.z + 0.0, 0.0)
        local netId, ent, c = SpawnPerson(ctx, st, point, profile, extra)
        if netId then after(netId, ent, c, false) end
        return
    end
    local contacts = st.contacts
    st.walkIns = (st.walkIns or 0) + 1
    CreateThread(function()
        local ok, err = pcall(function()
            local r1, r2 = Ring()
            local party = Party(ctx)
            local asked = AskedOfficer(ctx, src, cc)
            local points = {}
            local reply = asked and AskWalkIn(asked.src, cc, r1, r2) or nil
            for _, p in ipairs(type(reply) == 'table' and reply or {}) do
                local v = Usable(p, cc, r1, r2, Party(ctx))
                if v then points[#points + 1] = v end
            end
            local from = 'his game'
            if #points == 0 then
                from = 'round the car'
                party = Party(ctx)
                points = RingPoints(cc, r1, r2, a, party, asked)
            end
            if st.contacts ~= contacts or st.stopped or st.failed or st.completed or ctx.run.state == 'ended' then
                return
            end
            local v = points[1]
            if not v then return end
            local alt = {}
            for i = 2, math.min(#points, WALK_IN_ALT + 1) do
                alt[#alt + 1] = vector4(points[i].x, points[i].y, points[i].z, Facing(points[i], cc))
            end
            local opts = U.copy(extra)
            opts.alt = alt
            local netId, ent, c = SpawnPerson(ctx, st, vector4(v.x, v.y, v.z, Facing(v, cc)), profile, opts)
            if not netId then return end
            st.contacts[netId].walk = { car = carNet }
            CP.log(BLOCK, 'run %s: %s appears %.0f m from the car (%s), %.0f m from the nearest officer',
                tostring(ctx.run.id), tostring(extra.role), U.dist2d(v, cc), from, NearestOf(party, v))
            after(netId, ent, c, true)
            st.dirty = true
        end)
        if st.contacts == contacts then st.walkIns = math.max(0, (st.walkIns or 1) - 1) end
        if not ok then
            CP.err(BLOCK, 'run %s: a %s for the car failed: %s', tostring(ctx.run and ctx.run.id), tostring(extra.role),
                tostring(err))
        end
    end)
end

-- true while netId still waits frozen for an officer's game to put it on the ground (Config.Spawning.place).
local function Holding(netId)
    local sp = CP.Spawn
    return type(sp) == 'table' and type(sp.holding) == 'function' and sp.holding(netId) == true
end

-- A person the director placed walks up to his car once his officer's game has put him on the ground (a thief
-- that has bolted meanwhile no longer does). His walk may take RETURN_WALK_S plus the distance at WALK_MPS.
local function WalkTick(ctx, st)
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local w = t and t.walk
        if w and not w.started and not Holding(netId) then
            w.started = Now()
            local c = CP.Custody.get(ctx.run, netId)
            local pc, cc = EntCoords(ctx, netId), EntCoords(ctx, w.car)
            local d = (pc and cc) and U.dist2d(pc, cc) or 0
            w.ms = math.floor((RETURN_WALK_S + d / WALK_MPS) * 1000)
            if c and (c.state == 'idle' or c.state == 'contacted') then
                CP.Custody.act(ctx.run, netId, 'walk_to', { veh = w.car })
            end
        end
    end
end

-- true once a walking person reached his car (ARRIVE_M) or has walked as long as it takes (WalkTick).
local function WalkedUp(ctx, t, netId, carNet)
    local w = t.walk
    if not w or not w.started then return false end
    local pc, cc = EntCoords(ctx, netId), EntCoords(ctx, carNet)
    if pc and cc and U.dist2d(pc, cc) <= ARRIVE_M then return true end
    return Now() - w.started >= (w.ms or 0)
end

local function TellReturning(ctx, c, outcome)
    ctx.hud({
        message = {
            text = CP.Lt('block.field_contact.returning_' .. outcome, { label = c.label }),
            kind = 'info',
        },
    })
end

local function ReturningDriver(ctx, st, car, choice, src)
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
    SpawnNear(ctx, st, car.netId, RETURN_OFFSET, profile,
        { role = 'returning_driver', actions = { 'explain' }, consensual = true }, src, function(netId, _, c, walksIn)
            local t = st.contacts[netId]
            t.returning = { outcome = outcome, car = car.netId, at = Now(), walksIn = walksIn }
            c.state = 'contacted'
            c.decided = { choice = 'none', by = '', bySrc = nil, verdict = 'ok' }
            CP.Npc.setState(ctx.run, netId, 'contacted',
                { contact = { label = c.label, kind = 'person', actions = { 'explain' } } })
            if outcome == 'argues' then c.arguing = true end
            -- walking in: he says what he does once he is at the car (ReturningTick)
            if not walksIn then
                CP.Custody.act(ctx.run, netId, 'walk_to', { veh = car.netId })
                TellReturning(ctx, c, outcome)
            end
            st.dirty = true
        end)
end

local function ReturningTick(ctx, st)
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local rd = t and t.returning
        local due = rd and not rd.done and Now() - rd.at >= RETURN_WALK_S * 1000
        if rd and not rd.done and rd.walksIn then
            due = false
            if not rd.arrived and WalkedUp(ctx, t, netId, rd.car) then
                rd.arrived = Now()
                local c = CP.Custody.get(ctx.run, netId)
                -- an officer who met him on his walk and explained the citation calmed him: he takes the ticket
                local said = rd.outcome
                if said == 'argues' and c and not c.arguing then said = 'takes' end
                if c then TellReturning(ctx, c, said) end
            end
            due = rd.arrived ~= nil and Now() - rd.arrived >= ARRIVE_PAUSE_S * 1000
        end
        if due then
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

local function MaybeThief(ctx, st, car, src)
    if st.mode ~= 'parked' or st.thiefRolled or car.truth ~= 'stolen' then return end
    st.thiefRolled = true
    local r = RngOf(ctx)
    if not r:chance(tonumber(ctx.obj.thief.chance) or 0) then return end
    local profile = { truth = 'evading', demeanour = 'runner', cues = {} }
    SpawnNear(ctx, st, car.netId, THIEF_OFFSET, profile, {
        role = 'thief',
        actions = { 'talk', 'searchPerson', 'release', 'cite', 'arrest' },
        evading = true,
    }, src, function(netId, _, c)
        c.vehicleOf = nil
        st.thief = { netId = netId, ran = false }
    end)
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

-- The planned contacts that have not appeared yet (a parked car still waiting for an officer to get near, a scene
-- not out yet). The HUD and the checklist add them to Totals, so a thief who appears before the last parked car
-- does not hide one of the cars from the count.
local function StillToCome(st)
    local have = 0
    if st.mode == 'parked' then
        have = st.spawnedCars or 0
    elseif st.mode == 'scene' then
        have = (st.carNet and 1 or 0) + (st.spawnedPeople or 0)
    end
    return math.max(0, (st.planned or 0) - have)
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
    -- a returning driver or a thief on his way (SpawnNear)
    if (st.walkIns or 0) > 0 then return end
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
    -- the contacts the objective will have (a parked car still waiting for an officer to get near counts)
    total = total + StillToCome(st)
    local text
    if st.escaping then
        text = CP.Lt('block.field_contact.escaping', { seconds = st.escaping })
    elseif not st.spawned and #st.order == 0 then
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
--                              OBJECTIVE POINTER
-- ============================================================================
-- The owner (2026-10-19): "ensure all objectives as they come up mark on the map" (CP.Runs.marker,
-- docs/ARCHITECTURE.md §5.44). Every contact not yet decided, at the server's position, so one too far away for an
-- officer's game still shows (Config.Markers.farTargets): a car in kinds.contactVehicle, a person in kinds.contact, or
-- kinds.fleeing (orange) while he runs and kinds.suspect (red) once he draws or gave up after running. Keyed by net id
-- (the client half hands its own blip of each over), in the order they appeared, so the shape never changes by
-- itself; each officer's game routes him to his nearest. Parked mode: each chosen kerb spot whose car has not appeared
-- yet (it appears once an officer is near it) at the spot itself, key 'spot<n>'. Scene mode before the scene is out:
-- a pin where it will be, named after the objective.

local PERSON_LOOK = { fleeing = 'fleeing', hostile = 'suspect', surrendered = 'suspect' }

local function ObjectiveLabel(ctx)
    local l = ctx.obj.label
    if type(l) ~= 'string' or l == '' then return nil end
    if CP.Locale.has(l) then return CP.Lt(l) end
    return l
end

local function Marker(ctx)
    local st = StateOf(ctx)
    local targets = {}
    for _, netId in ipairs(st.order) do
        local t = st.contacts[netId]
        local c = CP.Custody.get(ctx.run, netId)
        local pc = t and not t.escaped and not Resolved(ctx, st, t, c) and EntCoords(ctx, netId) or nil
        if pc then
            targets[#targets + 1] = {
                key = netId,
                netId = netId,
                coords = pc,
                look = t.kind == 'vehicle' and 'contactVehicle' or PERSON_LOOK[c and c.state] or 'contact',
                label = CP.Lt('block.field_contact.blip', { label = t.label }),
            }
        end
    end
    if st.mode == 'parked' and st.spots then
        for i, spot in ipairs(st.spots) do
            if not st.carAt[i] then
                targets[#targets + 1] = {
                    key = 'spot' .. i,
                    coords = spot.coords,
                    look = 'contactVehicle',
                    label = CP.Lt('block.field_contact.blip_spot'),
                }
            end
        end
    end
    if #targets == 0 and st.mode == 'scene' and not st.sceneGo then
        local obj = ctx.obj
        local at = PointList(ctx.location, obj.car)[1] or (st.plan and st.plan.people[1] and st.plan.people[1].point)
            or PointList(ctx.location, obj.peopleSpots)[1]
        if at then return { kind = 'point', look = 'objective', coords = at, label = ObjectiveLabel(ctx) } end
        return nil
    end
    return { kind = 'targets', targets = targets }
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnAction(ctx, st, src, ev)
    local c = CP.Custody.get(ctx.run, ev.netId)
    if not c then return true end
    if ev.action == 'inspect' and c.kind == 'vehicle' then MaybeThief(ctx, st, c, src) end
    st.dirty = true
    return true
end

local function OnDecide(ctx, st, src, ev)
    local c = CP.Custody.get(ctx.run, ev.netId)
    if not c then return true end
    if c.kind == 'vehicle' and (ev.choice == 'cite' or ev.choice == 'impound') then
        ReturningDriver(ctx, st, c, ev.choice, src)
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
    -- CP.Npc's cuff handler records the cuff (state, reach, handcuffs) before it sends this event
    if not (CP.Npc and CP.Npc.getState and CP.Npc.getState(ev.netId) == 'cuffed') then return false, 'not_cuffed' end
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
        -- the server must have seen the stun too (Config.AntiCheat.stunNeedsProof)
        if CP.Npc and CP.Npc.stunProof and not CP.Npc.stunProof(t.netId) then return false, 'no_stun' end
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
        WalkTick(ctx, st)
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
    total = total + StillToCome(st)
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
    pointKinds = PointKinds,
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
    marker = Marker,
    restart = Restart,
    stop = function(ctx)
        local st = StateOf(ctx)
        st.stopped = true
    end,
})
