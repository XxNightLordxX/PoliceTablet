-- Objective block "escort" (server half)

local BLOCK = 'escort'
local U = CP.U

local WP_REACH = 20.0             -- metres: a waypoint counts as passed
local WP_LOOKAHEAD = 4            -- waypoints checked ahead of the next one (skipped corners)
local AMBUSH_TRIGGER = 120.0      -- a wave triggers when the truck is this close to its point
local AMBUSH_ROUTE = 150.0        -- builder check: an ambush point this close to the route
local STOPPED_MPS = 1.0           -- below this speed (3.6 km/h) the truck is stopped
local MOVED_MPS = 3.0
local START_GRACE_MS = 30000
local HOST_RANGE = 400.0          -- metres: the host's client has the truck to drive (OneSync culls at 424 m)
local WARN_STOPPED = 5            -- the stopped countdown shows after this many seconds
local CAR_GAP = 7.0               -- metres between ambush cars along the road
local CAR_SIDE = 4.5              -- metres from the road centre line
local DESTROYED_ENGINE = -3999.0
local HEALTHY_SHARE = 0.5
local DRIVER_MODEL = 's_m_m_armoured_01'
local DRIVER_HEALTH = 400
local DRIVER_ARMOUR = 100
local RESEND_MS = 15000
local CUFF_RANGE = 3.0
local REACH_SLACK = 2.0
local MISSING_TICKS = 2           -- ticks an entity must be missing before it counts as gone (as the engine)

local TWO_SEATERS = {
    elegy2 = true,
    dominator = true,
    dominator2 = true,
    banshee = true,
    infernus = true,
    comet2 = true,
    carbonizzare = true,
    zentorno = true,
    adder = true,
    turismor = true,
    entityxf = true,
    jester = true,
    massacro = true,
    ninef = true,
    coquette = true,
    feltzer2 = true,
    gauntlet = true,
    ruiner = true,
    vigero = true,
    t20 = true,
    osiris = true,
    reaper = true,
    cheetah = true,
    bullet = true,
    vacca = true,
    voltic = true,
    penumbra = true,
}

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function Int(v) return math.max(0, math.floor((tonumber(v) or 0) + 0.5)) end
local function InRange(v, r)
    return IsNum(v) and type(r) == 'table' and v >= r[1] - 1e-9 and v <= r[2] + 1e-9
end

local function Bad(key, vars)
    return false, CP.L(key, vars)
end

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

local function HasHeading(p)
    local t = type(p)
    if t == 'vector4' then return true end
    return t == 'table' and (p.w ~= nil or p[4] ~= nil or p.heading ~= nil)
end

local function HeadingTo(a, b)
    local ax, ay = U.xyz(a)
    local bx, by = U.xyz(b)
    if not ax or not bx then return 0.0 end
    local dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0 then return 0.0 end
    return math.deg(math.atan(-dx, dy)) % 360.0
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

-- The road route of a location: { points, stops = { [waypoint] = wait }, stopList, raw }.
local function RouteOf(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' or IsVec(v) then return nil end
    local pts = PointList(nil, v)
    if #pts < 2 then return nil end
    local stops, list = {}, {}
    if type(v.stops) == 'table' then
        for _, s in ipairs(v.stops) do
            if type(s) == 'table' then
                list[#list + 1] = s
                local at = tonumber(s.at)
                if at then stops[math.floor(at)] = tonumber(s.wait) or Cfg().stopWait[3] end
            end
        end
    end
    return { points = pts, stops = stops, stopList = list }
end

local function RouteLength(pts)
    local len = 0.0
    for i = 2, #pts do len = len + U.dist(pts[i - 1], pts[i]) end
    return len
end

local function NearestIndex(pts, coords)
    local best, bi = math.huge, 1
    for i = 1, #pts do
        local d = U.dist2d(pts[i], coords)
        if d < best then best, bi = d, i end
    end
    return bi
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function AllAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if allowed and not U.contains(allowed, v) then return false end
    end
    return true
end

local function Indices(n)
    local t = {}
    for i = 1, n do t[i] = i end
    return t
end

-- An ACTIVE participant only: a player who already left the run is an outside killer (flagged by
-- CP.Npc / CP.AntiCheat), not a reason to fail the run for the officers still on it.
local function IsParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    for _, s in ipairs(ctx.participants() or {}) do
        if tonumber(s) == src then return true end
    end
    return false
end

-- Only the run host's client drives the truck, and only while it streams the truck.
local function HostNear(ctx, c)
    local host = ctx.host and ctx.host()
    local hc = host and ctx.coords(host)
    return hc ~= nil and U.dist(hc, c) <= HOST_RANGE
end

local function RngOf(ctx)
    local st = ctx.state
    if not st.rng then
        st.rng = ctx.rng or U.rng(((ctx.run and ctx.run.seed) or 1) + (ctx.index or 0))
    end
    return st.rng
end

local function Exists(e) return e ~= nil and e ~= 0 and DoesEntityExist(e) end

local function EntCoords(e)
    if Exists(e) then return GetEntityCoords(e) end
    return nil
end

local function NpcSet(ctx, netId, state)
    if CP.Npc and CP.Npc.setState then CP.Npc.setState(ctx.run, netId, state) end
end

local function Neutralised(p) return p.state == 'dead' or p.state == 'cuffed' end

local function FourSeaters(list)
    return U.filter(list or {}, function(m) return type(m) == 'string' and not TWO_SEATERS[m:lower()] end)
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Defaults(obj)
    local c = Cfg()
    local hw = Config.Blocks.hostile_waves
    if obj.minSeconds == nil then obj.minSeconds = 60 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.route == nil then obj.route = 'route' end
    if obj.vehicle == nil then obj.vehicle = c.vehicle end
    if obj.driver == nil then obj.driver = DRIVER_MODEL end
    if obj.speed == nil then obj.speed = c.speed[3] end
    if obj.style == nil then obj.style = c.style.default end
    if obj.toughness == nil then obj.toughness = c.toughness[3] end
    if obj.stoppedFail == nil then obj.stoppedFail = c.stoppedFail[3] end
    if obj.arrival == nil then obj.arrival = c.arrival[3] + 0.0 end
    if obj.ambushPoints == nil then obj.ambushPoints = 'ambushPoints' end
    if type(obj.ambush) ~= 'table' then obj.ambush = {} end
    local a = obj.ambush
    if a.waves == nil then a.waves = c.ambushWaves[3] end
    if a.carsPerWave == nil then a.carsPerWave = c.carsPerWave[3] end
    if a.perCar == nil then a.perCar = c.perCar[3] end
    if a.models == nil then
        local four = FourSeaters(Config.Builder.allowed.vehicles)
        a.models = #four > 0 and four or U.copy(Config.Builder.allowed.vehicles)
    end
    if a.peds == nil then a.peds = U.copy(hw.peds) end
    if a.weapons == nil then a.weapons = U.copy(hw.weapons) end
    if a.accuracy == nil then a.accuracy = hw.accuracy[3] end
    if a.armour == nil then a.armour = hw.armour[3] end
    if a.health == nil then a.health = hw.health[3] end
    if obj.clearRadius == nil then obj.clearRadius = 100.0 end
    return obj
end

local function ArmedCount(obj)
    local o = Defaults(U.deepcopy(obj))
    return Int(o.ambush.waves) * Int(o.ambush.carsPerWave) * Int(o.ambush.perCar)
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    for _, k in ipairs({ o.route, o.ambushPoints }) do
        if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end
    end
    return out
end

local function CheckLocation(o, loc, li, strict)
    local c = Cfg()
    local route = RouteOf(loc, o.route)
    if not route then return Bad('block.escort.invalid.route', { location = li }) end
    local pts = route.points
    if #route.stopList > c.stops[2] then
        return Bad('block.escort.invalid.stops', { location = li, max = c.stops[2] })
    end
    for _, s in ipairs(route.stopList) do
        if not IsInt(s.at) or s.at < 2 or s.at >= #pts then
            return Bad('block.escort.invalid.stops', { location = li, max = c.stops[2] })
        end
        local wait = s.wait == nil and c.stopWait[3] or s.wait
        if not InRange(wait, c.stopWait) then
            return Bad('block.escort.invalid.range', { field = 'stops.wait', min = c.stopWait[1], max = c.stopWait[2] })
        end
    end
    local amb = PointList(loc, o.ambushPoints)
    if #amb == 0 then
        return Bad('block.escort.invalid.points_missing', { key = tostring(o.ambushPoints), location = li })
    end
    if strict then
        local r = Config.Builder.route
        local len = RouteLength(pts)
        if len < r.minLength or len > r.maxLength then
            return Bad('block.escort.invalid.route_length', { location = li, min = r.minLength, max = r.maxLength })
        end
        if U.dist2d(pts[1], pts[#pts]) < r.minStartEndGap then
            return Bad('block.escort.invalid.route_ends', { location = li, min = r.minStartEndGap })
        end
        for _, p in ipairs(pts) do
            if InNoBuild(p) then return Bad('block.escort.invalid.points_zone', { location = li }) end
        end
        if #amb < c.ambushPoints[1] or #amb > c.ambushPoints[2] then
            return Bad('block.escort.invalid.ambush_count',
                { location = li, min = c.ambushPoints[1], max = c.ambushPoints[2] })
        end
        for i, p in ipairs(amb) do
            if InNoBuild(p) then return Bad('block.escort.invalid.points_zone', { location = li }) end
            if U.distToPolyline(p, pts) > AMBUSH_ROUTE then
                return Bad('block.escort.invalid.ambush_route', { location = li, max = AMBUSH_ROUTE })
            end
            for j = i + 1, #amb do
                if U.dist(p, amb[j]) < c.ambushGap then
                    return Bad('block.escort.invalid.ambush_gap', { location = li, min = c.ambushGap })
                end
            end
        end
    end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.escort.invalid.objective') end
    local c = Cfg()
    local hw = Config.Blocks.hostile_waves
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed
    local function range(field, v, r)
        if InRange(v, r) then return true end
        return Bad('block.escort.invalid.range', { field = field, min = r[1], max = r[2] })
    end
    local ok, why
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.escort.invalid.min_seconds') end
    ok, why = range('presenceRange', o.presenceRange, c.presenceRange)
    if not ok then return false, why end
    if type(o.vehicle) ~= 'string' or (strict and not U.contains(allowed.escortVehicles, o.vehicle)) then
        return Bad('block.escort.invalid.vehicle')
    end
    if type(o.driver) ~= 'string' or o.driver == '' then return Bad('block.escort.invalid.driver') end
    -- custom missions: the block's own driver model or an allowed ped (Config.Builder.allowed.peds)
    if strict and o.driver ~= DRIVER_MODEL and not U.contains(allowed.peds or {}, o.driver) then
        return Bad('block.escort.invalid.driver_allowed', { default = DRIVER_MODEL })
    end
    ok, why = range('speed', o.speed, c.speed)
    if not ok then return false, why end
    if not U.contains(c.style.options, o.style) then return Bad('block.escort.invalid.style') end
    ok, why = range('toughness', o.toughness, c.toughness)
    if not ok then return false, why end
    ok, why = range('stoppedFail', o.stoppedFail, c.stoppedFail)
    if not ok then return false, why end
    ok, why = range('arrival', o.arrival, c.arrival)
    if not ok then return false, why end
    if not IsNum(o.clearRadius) or o.clearRadius <= 0 then return Bad('block.escort.invalid.clear_radius') end
    local a = o.ambush
    for _, f in ipairs({ { 'waves', c.ambushWaves }, { 'carsPerWave', c.carsPerWave }, { 'perCar', c.perCar } }) do
        local v = a[f[1]]
        if not IsInt(v) then
            return Bad('block.escort.invalid.range', { field = 'ambush.' .. f[1], min = f[2][1], max = f[2][2] })
        end
        ok, why = range('ambush.' .. f[1], v, f[2])
        if not ok then return false, why end
    end
    if not AllAllowed(a.models, strict and allowed.vehicles or nil) then return Bad('block.escort.invalid.models') end
    if a.perCar > 2 and #FourSeaters(a.models) == 0 then return Bad('block.escort.invalid.seats') end
    if not AllAllowed(a.peds, strict and allowed.peds or nil) then return Bad('block.escort.invalid.peds') end
    if not AllAllowed(a.weapons, strict and allowed.weapons or nil) then return Bad('block.escort.invalid.weapons') end
    ok, why = range('ambush.accuracy', a.accuracy, hw.accuracy)
    if not ok then return false, why end
    ok, why = range('ambush.armour', a.armour, hw.armour)
    if not ok then return false, why end
    ok, why = range('ambush.health', a.health, hw.health)
    if not ok then return false, why end
    local armed = ArmedCount(o)
    if armed > Config.Builder.maxHostiles then
        return Bad('block.escort.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
    end
    if type(location) == 'table' then return CheckLocation(o, location, 1, strict) end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            ok, why = CheckLocation(o, loc, li, strict)
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
        st.truck = { wp = 2, served = {}, stoppedFor = 0, moved = false, gen = 1, health = 100, baseline = 1000.0 }
        st.waves, st.cars, st.peds = {}, {}, {}
        local route = RouteOf(ctx.location, ctx.obj.route)
        st.points = route and route.points or {}
        st.stops = route and route.stops or {}
    end
    return st
end

local function Fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

local function Message(ctx, key, vars, kind)
    ctx.hud({ message = { text = CP.L(key, vars), kind = kind or 'info' } })
end

-- Waves in route order at distinct random ambush points (reused in order when there are more waves).
local function PlanWaves(ctx, st)
    if st.planned then return end
    st.planned = true
    local pts = PointList(ctx.location, ctx.obj.ambushPoints)
    local n = Int(ctx.obj.ambush.waves)
    if #pts == 0 and #st.points >= 3 then
        -- no ambush points at this location: spread them over the middle of the route
        for i = 1, n do
            local idx = math.max(2, math.min(#st.points - 1, math.floor(#st.points * (0.2 + 0.6 * i / (n + 1)))))
            pts[#pts + 1] = st.points[idx]
        end
    end
    if #pts == 0 then return end
    local order = RngOf(ctx):shuffle(Indices(#pts))
    local chosen = {}
    for i = 1, n do chosen[i] = pts[order[((i - 1) % #order) + 1]] end
    local list = {}
    for i, p in ipairs(chosen) do
        list[i] = { point = p, wp = #st.points > 0 and NearestIndex(st.points, p) or 1, lap = (i - 1) // #order }
    end
    table.sort(list, function(a, b)
        if a.lap ~= b.lap then return a.lap < b.lap end
        return a.wp < b.wp
    end)
    for k, w in ipairs(list) do
        st.waves[k] = { k = k, point = w.point, wp = w.wp, triggered = false, dropped = false, cars = {} }
    end
end

-- ============================================================================
--                                   SPAWNING
-- ============================================================================

local function SpawnTruck(ctx, st)
    local tr = st.truck
    if tr.netId then return true end
    if #st.points < 2 then
        CP.warn(BLOCK, 'no road route at %s for run %s', tostring(ctx.obj.route), tostring(ctx.run and ctx.run.id))
        Fail(ctx, st, 'block.escort.fail_setup')
        return false
    end
    if not ctx.canSpawn(2, false) then return false end
    local p1, p2 = st.points[1], st.points[2]
    local x, y, z = U.xyz(p1)
    local place = vector4(x + 0.0, y + 0.0, z + 0.0, HeadingTo(p1, p2))
    local ent, netId = ctx.spawnVehicle({
        model = ctx.obj.vehicle,
        coords = place,
        role = 'escort',
        tag = 'truck',
        cfg = { toughness = ctx.obj.toughness },
    })
    if not netId then return false end
    if SetVehicleDoorsLocked and Exists(ent) then pcall(SetVehicleDoorsLocked, ent, 2) end
    tr.netId, tr.entity = netId, ent
    st.dirty = true
    return true
end

local function SpawnDriver(ctx, st)
    local tr = st.truck
    if not tr.netId or tr.driver then return true end
    if not ctx.canSpawn(1, false) then return false end
    local x, y, z = U.xyz(EntCoords(tr.entity) or st.points[1])
    local ent, netId = ctx.spawnPed({
        model = ctx.obj.driver,
        coords = vector4(x + 0.0, y + 0.0, z + 0.0, 0.0),
        role = 'escort_driver',
        armed = false,
        health = DRIVER_HEALTH,
        armour = DRIVER_ARMOUR,
        cfg = { group = 'neutral', vehicle = tr.netId, seat = -1, block = BLOCK },
        tag = 'driver',
    })
    if not netId then return false end
    if SetPedIntoVehicle and Exists(ent) and Exists(tr.entity) then pcall(SetPedIntoVehicle, ent, tr.entity, -1) end
    tr.driver = { netId = netId, entity = ent }
    NpcSet(ctx, netId, 'driving')
    st.dirty = true
    return true
end

local function CarPlacement(st, w, c)
    local p = w.point
    local h
    if HasHeading(p) then
        h = HeadingOf(p)
    elseif #st.points >= 2 then
        local i = math.min(w.wp, #st.points - 1)
        h = HeadingTo(st.points[i], st.points[i + 1])
    else
        h = 0.0
    end
    local r = math.rad(h)
    local fx, fy = -math.sin(r), math.cos(r)       -- forward (along the road)
    local rx, ry = math.cos(r), math.sin(r)        -- right of the road
    local x, y, z = U.xyz(p)
    local ahead = (c - 1) * CAR_GAP
    local side = (c % 2 == 1) and CAR_SIDE or -CAR_SIDE
    return vector4(x + fx * ahead + rx * side, y + fy * ahead + ry * side, z + 0.5, (h + 180.0) % 360.0)
end

local function SpawnAttacker(ctx, st, car, w)
    if not ctx.canSpawn(1, true) then return false end
    local a = ctx.obj.ambush
    local r = RngOf(ctx)
    local seat = #car.crew - 1
    local x, y, z = U.xyz(EntCoords(car.entity) or car.coords)
    local acc, arm = ctx.combat(a.accuracy, a.armour)
    local ent, netId = ctx.spawnPed({
        model = r:pick(a.peds) or Config.Blocks.hostile_waves.peds[1],
        coords = vector4(x + 0.0, y + 0.0, z + 0.0, HeadingOf(car.coords)),
        role = 'attacker',
        armed = true,
        weapon = r:pick(a.weapons) or Config.Blocks.hostile_waves.weapons[1],
        accuracy = acc,
        armour = arm,
        health = a.health,
        cfg = { group = 'hostile', behaviour = 'push', vehicle = car.netId, seat = seat, wave = w.k, block = BLOCK },
        tag = 'wave' .. w.k,
    })
    if not netId then return false end
    if SetPedIntoVehicle and Exists(ent) and Exists(car.entity) then pcall(SetPedIntoVehicle, ent, car.entity, seat) end
    local key = tostring(netId)
    st.peds[key] = { netId = netId, entity = ent, wave = w.k, state = 'hostile' }
    car.crew[#car.crew + 1] = key
    NpcSet(ctx, netId, 'hostile')
    st.dirty = true
    return true
end

-- Spawns what a triggered wave still misses; a car and its crew spawn together once the caps allow.
local function SpawnWave(ctx, st, w)
    local ok = true
    for _, ck in ipairs(w.cars) do
        local car = st.cars[ck]
        while ok and #car.crew < car.want do
            if not SpawnAttacker(ctx, st, car, w) then ok = false end
        end
        if not ok then return false end
    end
    local perCar = math.min(4, math.max(1, Int(ctx.obj.ambush.perCar)))
    while #w.cars < w.want do
        if not (ctx.canSpawn(perCar + 1, false) and ctx.canSpawn(perCar, true)) then return false end
        local c = #w.cars + 1
        local place = CarPlacement(st, w, c)
        local models = ctx.obj.ambush.models
        if perCar > 2 then
            local four = FourSeaters(models)
            if #four > 0 then models = four end
        end
        local ent, netId = ctx.spawnVehicle({
            model = RngOf(ctx):pick(models) or 'sultan',
            coords = place,
            role = 'ambush_car',
            tag = 'wave' .. w.k,
        })
        if not netId then return false end
        -- nothing a non-participant can take: the crew can still get out, nobody can get in
        if SetVehicleDoorsLocked and Exists(ent) then pcall(SetVehicleDoorsLocked, ent, 2) end
        local key = tostring(netId)
        local car = { netId = netId, entity = ent, coords = place, wave = w.k, want = perCar, crew = {} }
        st.cars[key] = car
        w.cars[#w.cars + 1] = key
        st.dirty = true
        while #car.crew < car.want do
            if not SpawnAttacker(ctx, st, car, w) then return false end
        end
    end
    return true
end

local function WaveSpawned(st, w)
    if #w.cars < (w.want or 0) then return false end
    for _, ck in ipairs(w.cars) do
        local car = st.cars[ck]
        if #car.crew < car.want then return false end
    end
    return true
end

local function WaveDone(st, w)
    if not w.triggered or not WaveSpawned(st, w) then return false end
    for _, ck in ipairs(w.cars) do
        for _, pk in ipairs(st.cars[ck].crew) do
            local p = st.peds[pk]
            if p and not Neutralised(p) then return false end
        end
    end
    return true
end

local function SpawnMissing(ctx, st)
    if st.spawning or st.halted or st.failed then return end
    st.spawning = true
    if SpawnTruck(ctx, st) and SpawnDriver(ctx, st) then
        for _, w in ipairs(st.waves) do
            if w.triggered and not w.dropped and not WaveSpawned(st, w) then
                if not SpawnWave(ctx, st, w) then break end
            end
        end
    end
    st.spawning = false
end

-- ============================================================================
--                                TRUCK PROGRESS
-- ============================================================================
-- Server-side health is the owner's sync data: a truck made with CreateVehicleServerSetter reads 0
-- (entity, engine and body health) until a client has taken it over and synced it. Until a positive
-- value was seen once, the truck counts as untouched (100 %) and a 0 is not "destroyed" (the engine's
-- own wreck check follows the same rule).
local function TruckHealth(ctx, st)
    local tr = st.truck
    local e = tr.entity
    local engine = GetVehicleEngineHealth and tonumber(GetVehicleEngineHealth(e)) or 1000.0
    local body = GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(e)) or 1000.0
    if not tr.synced then
        local hp = GetEntityHealth and tonumber(GetEntityHealth(e)) or 1
        if engine > 0 or body > 0 or (hp and hp > 0) then
            tr.synced = true
        else
            return 100, engine
        end
    end
    local base = math.max(1.0, tr.baseline or 1000.0)
    return math.max(0, math.min(100, math.floor(math.min(engine, body) / base * 100 + 0.5))), engine
end

local function Advance(ctx, st, c)
    local tr = st.truck
    local pts = st.points
    for k = 0, WP_LOOKAHEAD do
        local i = tr.wp + k
        if i > #pts then break end
        if U.dist2d(c, pts[i]) <= WP_REACH then
            local target = i + 1
            for j = tr.wp, i do
                if st.stops[j] and not tr.served[j] and j < #pts then
                    tr.served[j] = true
                    tr.stop = { at = j, left = st.stops[j] }
                    target = j + 1
                    Message(ctx, 'block.escort.msg_stop', { seconds = st.stops[j] }, 'info')
                    break
                end
            end
            tr.wp = target
            st.dirty = true
            return
        end
    end
end

local function TriggerWaves(ctx, st, c)
    local tr = st.truck
    for _, w in ipairs(st.waves) do
        if not w.triggered and not w.dropped then
            if U.dist(c, w.point) <= AMBUSH_TRIGGER or tr.wp > w.wp + 1 then
                w.triggered = true
                w.want = Int(ctx.obj.ambush.carsPerWave)
                st.dirty = true
                Message(ctx, 'block.escort.msg_ambush', nil, 'warning')
            end
        end
    end
end

local function AttackersNear(st, c, radius)
    local n = 0
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            local pc = EntCoords(p.entity)
            if pc and U.dist(pc, c) <= radius then n = n + 1 end
        end
    end
    return n
end

local function PendingWaves(st)
    for _, w in ipairs(st.waves) do
        if w.triggered and not w.dropped and not WaveSpawned(st, w) then return true end
    end
    return false
end

-- Armored Truck Escort objective 2, "neutralise each ambush wave": a triggered wave whose attackers are
-- not all killed or cuffed keeps the objective open, however far behind the truck they were left.
local function OpenWaves(st)
    for _, w in ipairs(st.waves) do
        if w.triggered and not w.dropped and not WaveDone(st, w) then return true end
    end
    return false
end

local function WatchTruck(ctx, st, dt)
    local tr = st.truck
    if not tr.netId then return end
    local e = tr.entity
    if not Exists(e) then
        tr.missing = (tr.missing or 0) + 1
        if tr.missing >= MISSING_TICKS then Fail(ctx, st, 'block.escort.fail_destroyed') end
        return
    end
    tr.missing = 0
    local health, engine = TruckHealth(ctx, st)
    local hp = GetEntityHealth and tonumber(GetEntityHealth(e)) or 1
    if hp and hp > 0 then tr.hpSeen = true end
    if (hp and hp <= 0 and tr.hpSeen) or engine <= DESTROYED_ENGINE then
        Fail(ctx, st, 'block.escort.fail_destroyed')
        return
    end
    if health ~= tr.health then
        if math.abs(health - (tr.sentHealth or 100)) >= 5 or health == 0 then st.dirty = true end
        tr.health = health
    end
    local c = GetEntityCoords(e)
    if not tr.arrived then
        Advance(ctx, st, c)
        TriggerWaves(ctx, st, c)
        -- 2D, like the waypoints: the destination is a point on the road map, and a route's z (recorded
        -- or estimated) must not shrink the arrival circle (docs/notes/missions_b.md). Only on the final
        -- stretch: a route may pass its destination earlier (the other carriageway, a road under a bridge).
        if tr.wp >= #st.points and U.dist2d(c, st.points[#st.points]) <= ctx.obj.arrival then
            tr.arrived = true
            tr.arrivalHealth = health          -- truck_healthy: "the truck ARRIVES above 50% health"
            tr.stop = nil
            tr.stoppedFor = 0
            st.dirty = true
            for _, w in ipairs(st.waves) do
                if not w.triggered then w.dropped = true end
            end
            Message(ctx, 'block.escort.msg_arrived', { radius = math.floor(ctx.obj.clearRadius + 0.5) }, 'success')
        end
    end
    if tr.arrived then return end
    if tr.stop then
        tr.stop.left = tr.stop.left - dt
        tr.stoppedFor = 0
        if tr.stop.left <= 0 then
            tr.stop = nil
            tr.gen = tr.gen + 1
        end
        st.dirty = true
        return
    end
    local speed = GetEntitySpeed and tonumber(GetEntitySpeed(e)) or 0.0
    if speed >= MOVED_MPS then tr.moved = true end
    -- the truck only moves while the host can drive it: stopped time counts only then, and the start
    -- grace runs from the host's first time near (a partner may start the run far from the leader)
    local near = HostNear(ctx, c)
    if near and not tr.nearAt then tr.nearAt = Now() end
    local counting = near and (tr.moved or Now() - tr.nearAt >= START_GRACE_MS)
    if counting and speed < STOPPED_MPS then
        tr.stoppedFor = tr.stoppedFor + dt
        if tr.stoppedFor >= ctx.obj.stoppedFail then
            Fail(ctx, st, 'block.escort.fail_stopped')
            return
        end
        if tr.stoppedFor >= WARN_STOPPED then st.dirty = true end
    elseif tr.stoppedFor > 0 then
        if tr.stoppedFor >= WARN_STOPPED then st.dirty = true end
        tr.stoppedFor = 0
    end
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.halted then return end
    local tr = st.truck
    if not tr.arrived or not Exists(tr.entity) or PendingWaves(st) or OpenWaves(st) then return end
    if AttackersNear(st, GetEntityCoords(tr.entity), ctx.obj.clearRadius) > 0 then return end
    if not st.healthDone then
        st.healthDone = true
        local health = tr.arrivalHealth or TruckHealth(ctx, st)
        if health > HEALTHY_SHARE * 100 then ctx.award('truck_healthy', { count = 1 }) end
    end
    if ctx.complete({ health = tr.health }) ~= false then st.completed = true end
end

-- ============================================================================
--                                CLIENT UPDATES
-- ============================================================================

local function Snapshot(ctx, st)
    local tr = st.truck
    local waves, attackers = {}, {}
    for _, w in ipairs(st.waves) do
        if not w.dropped then
            local alive = 0
            for _, ck in ipairs(w.cars) do
                for _, pk in ipairs(st.cars[ck].crew) do
                    local p = st.peds[pk]
                    if p and not Neutralised(p) then alive = alive + 1 end
                end
            end
            waves[#waves + 1] = { k = w.k, triggered = w.triggered, done = WaveDone(st, w), alive = alive }
        end
    end
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then attackers[#attackers + 1] = p.netId end
    end
    table.sort(attackers)
    tr.sentHealth = tr.health
    return {
        kind = 'state',
        truck = {
            netId = tr.netId,
            driver = tr.driver and tr.driver.netId or nil,
            wp = tr.wp,
            gen = tr.gen,
            stop = tr.stop and { at = tr.stop.at, left = math.max(0, math.ceil(tr.stop.left)) } or nil,
            arrived = tr.arrived == true,
            toughened = tr.toughened == true,
            health = tr.health,
            stoppedFor = tr.stoppedFor >= WARN_STOPPED and math.floor(tr.stoppedFor) or 0,
            stoppedFail = ctx.obj.stoppedFail,
        },
        waves = waves,
        attackers = attackers,
        completed = st.completed == true,
    }
end

local function Flush(ctx, st)
    local t = Now()
    if st.dirty or not st.sentAt or t - st.sentAt >= RESEND_MS then
        st.dirty = false
        st.sentAt = t
        ctx.send(Snapshot(ctx, st))
    end
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    if st.failed or st.halted then return false, 'ended' end
    local t = ev.type
    local netId = tonumber(ev.netId)
    if t == 'toughened' then
        local tr = st.truck
        if not tr.netId or netId ~= tr.netId then return false, 'unknown_entity' end
        if tr.toughened then return false, 'duplicate' end
        if ctx.isHost and not ctx.isHost(src) then return false, 'not_host' end
        tr.toughened = true
        tr.baseline = 1000.0 * (tonumber(ctx.obj.toughness) or 1.0)
        tr.health = TruckHealth(ctx, st)
        st.dirty = true
        Flush(ctx, st)
        return true
    elseif t == 'cuffed' or t == 'shot' then
        local p = netId and st.peds[tostring(netId)] or nil
        if not p then return false, 'unknown_entity' end
        if t == 'shot' then return true end
        if p.state == 'cuffed' then return false, 'duplicate' end
        if not (CP.Npc and CP.Npc.getState and CP.Npc.getState(netId) == 'cuffed') then return false, 'not_cuffed' end
        local pc, sc = EntCoords(p.entity), ctx.coords(src)
        if not pc or not sc or U.dist(pc, sc) > CUFF_RANGE + REACH_SLACK then return false, 'too_far' end
        p.state = 'cuffed'
        st.dirty = true
        TryComplete(ctx, st)
        Flush(ctx, st)
        return true
    end
    return false, 'unknown_event'
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Start(ctx)
    local st = StateOf(ctx)
    st.halted = nil
    PlanWaves(ctx, st)
    SpawnMissing(ctx, st)
    st.dirty = true
    Flush(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    if st.halted or st.failed or st.completed then return end
    dt = tonumber(dt) or 1
    PlanWaves(ctx, st)
    SpawnMissing(ctx, st)
    if st.failed then return end
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            if not Exists(p.entity) then
                p.missing = (p.missing or 0) + 1
                if p.missing >= MISSING_TICKS then
                    p.state = 'dead'
                    st.dirty = true
                end
            elseif CP.Npc and CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed' then
                p.state = 'cuffed'
                st.dirty = true
            end
        end
    end
    WatchTruck(ctx, st, dt)
    if st.failed then return end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local tr = st.truck
    if tr.netId and netId == tr.netId then
        -- the truck stays parked at the destination while a later objective runs: no longer a fail
        if st.completed or st.halted then return end
        Fail(ctx, st, 'block.escort.fail_destroyed')
        return
    end
    if tr.driver and netId == tr.driver.netId then
        if tr.driver.dead then return end
        tr.driver.dead = true
        st.dirty = true
        if IsParticipant(ctx, killerSrc) then
            Fail(ctx, st, 'run.fail_killed_unarmed')
            return
        end
        -- the objective is over (a later one runs): no message over that objective
        if st.completed or st.halted then return end
        Message(ctx, 'block.escort.msg_driver_down', nil, 'error')
        Flush(ctx, st)
        return
    end
    local key = tostring(netId)
    local p = st.peds[key]
    if p then
        if p.state == 'dead' then return end
        p.state = 'dead'
        st.dirty = true
        for _, w in ipairs(st.waves) do
            if w.k == p.wave and not w.cleared and WaveDone(st, w) then
                w.cleared = true
                Message(ctx, 'block.escort.msg_wave_clear', nil, 'success')
            end
        end
        TryComplete(ctx, st)
        Flush(ctx, st)
        return
    end
    local car = st.cars[key]
    if car then
        car.wrecked = true
        st.dirty = true
        Flush(ctx, st)
    end
end

local function Presence(ctx, src, coords)
    local st = StateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local c = EntCoords(st.truck.entity) or st.points[1]
        or (ctx.location and ctx.location.start and ctx.location.start.coords)
    if not c then return 0 end
    return U.dist(coords, c)
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local total, done = 0, 0
    for _, w in ipairs(st.waves) do
        if not w.dropped then
            total = total + 1
            if WaveDone(st, w) then done = done + 1 end
        end
    end
    local tr = st.truck
    return {
        { label = CP.L('block.escort.check_escort'), done = tr.arrived == true },
        { label = CP.L('block.escort.check_waves'), done = done >= total, value = done, max = total },
        { label = CP.L('block.escort.check_clear'), done = st.completed == true },
    }
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for key in pairs(st.peds) do ctx.delete(tonumber(key)) end
    for key in pairs(st.cars) do ctx.delete(tonumber(key)) end
    if st.truck.driver then ctx.delete(st.truck.driver.netId) end
    if st.truck.netId then ctx.delete(st.truck.netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    Start(ctx)
end

local function Rescale(ctx)
    local st = StateOf(ctx)
    local total = Int(ctx.obj.ambush.waves)
    local cars = Int(ctx.obj.ambush.carsPerWave)
    local perCar = math.min(4, math.max(1, Int(ctx.obj.ambush.perCar)))
    local triggered = 0
    for _, w in ipairs(st.waves) do
        if w.triggered then triggered = triggered + 1 end
    end
    local allowedLeft = math.max(0, total - triggered)
    for _, w in ipairs(st.waves) do
        if w.triggered then
            if w.want and #w.cars < w.want then w.want = math.max(#w.cars, math.min(w.want, cars)) end
            for _, ck in ipairs(w.cars) do
                local car = st.cars[ck]
                if #car.crew < car.want then car.want = math.max(#car.crew, math.min(car.want, perCar)) end
            end
        elseif not w.dropped then
            if allowedLeft > 0 then
                allowedLeft = allowedLeft - 1
            else
                w.dropped = true
            end
        end
    end
    st.dirty = true
    TryComplete(ctx, st)
    Flush(ctx, st)
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
    rescale = Rescale,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = function(ctx)
        local st = StateOf(ctx)
        st.halted = true
    end,
})
