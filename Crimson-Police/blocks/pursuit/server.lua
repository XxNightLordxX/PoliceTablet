-- Objective block "pursuit" (server half)

local BLOCK = 'pursuit'
local U = CP.U

local REACH_SLACK = 2.0                  -- metres of position lag allowed around interaction ranges
local CUFF_RANGE = 3.0                   -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local STUN_RANGE = 30.0                  -- a stun needs a participant this close to the suspect...
local STUN_REPORT = 60.0                 -- ...and the reporter this close (the client only watches within 60 m)
local AIM_STOPPED = 25.0                 -- a suspect waiting at the stopped car gives up when aimed at from this close
local RAM_RANGE = 12.0                   -- a ram report needs the reporter this close to the suspect vehicle
local RAM_COOLDOWN_MS = 2500             -- one ram per participant and vehicle in this window
local RAM_SLACK_KMH = 40.0               -- a reported speed may exceed the server's own samples by this much
local RAM_MAX_KMH = 400.0
local LIGHTS_SLACK = 10.0
local FLEE_CLOSE = 15.0                  -- a waiting car flees when any participant gets this close
local FLEE_DAMAGE = 25.0                 -- ...or when its body health drops this much
local NEVER_MOVED_MS = 30000             -- a fleeing car that never got going can be stopped after this long
local MOVED_KMH = 15.0                   -- faster than this, a car has been moving
local STOP_NEAR = 50.0                   -- a stop only counts with a participant this close to the car
local SPEED_WINDOW_MS = 3500             -- server speed samples kept per participant (ram plausibility)
local SURRENDER_GRACE_MS = 3000          -- a kill this soon after an armed suspect gave up is a shot in flight
local SPAWN_GAP = 8.0                    -- metres between vehicles placed from one point
local ROUTE_BACK = 2                     -- racers start this many waypoints before the intercept point
local ROUTE_END = 30.0                   -- an open route is done this close to its last waypoint (as the host)
local FOLLOW_SEND_MS = 2000
local RESEND_MS = 15000
local UNDRIVEABLE_ENGINE = 100.0
local ARMED_BELOW = 0.5
local MAX_SEATS = 4
local MISSING_TICKS = 2                  -- ticks an entity must be missing before it counts as gone (as the engine)
local DEFAULT_ARREST_MS = 5000
local DEFAULT_FAST_S = 120
local CUSTOM_TIMED_MS = { 1000, 30000 }  -- custom missions: the arrest progress time (ms)
local DEFAULT_AHEAD = 50.0
local MAX_OFFSET = 250.0                 -- metres: spawnOffset is kept within this of the reference point
local APPROACH_CUE = 250.0               -- the HUD announces a violator this close to a participant
local PASS_RANGE = 300.0                 -- a violator has passed the observation point once ahead of it within this
local RAM_BOX = 15.0                     -- a fighting car slowed with a participant this close is boxed in...
local RAM_BOX_S = 1                      -- ...for this long before it may ram
local RAM_MS = 3000                      -- a ram lasts this long
local FOLLOW_BEHIND = 60.0               -- observe = follow: within this many metres...
local FOLLOW_SECONDS = 8                 -- ...for this long
-- Pursuit Sim card: "Gold under 40 m +50, Silver under 80 m +25, Bronze under 150 m +10". Passed as the
-- trusted per-occurrence hint of every medal award, so a medal is worth its card value on a mission whose
-- file does not list it (every custom mission: Config.Bonuses has no medal ids); a file that lists the id
-- with its own points keeps them (built-ins). Capped by Config.Builder.bonusCap.points on custom missions.
local MEDAL_POINTS = { medal_gold = 50, medal_silver = 25, medal_bronze = 10 }
-- Custom missions: bonus / penalty id fields hold a Config.Bonuses id or the block's own default id.
local ID_DEFAULTS = {
    detainBonus = 'racer_detained',
    allDetainedBonus = 'all_racers_detained',
    ['fastStop.id'] = 'vehicle_stopped_fast',
    ramPenaltyId = 'hard_ram',
}

-- Two-seat models: with more than 2 suspects per vehicle a 4-seat model is picked.
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
local ZoneSpeed
local function Now() return GetGameTimer() end

-- A card value passed as a points hint; at most Config.Builder.bonusCap.points on non-built-in missions.
local function CardPoints(ctx, v)
    if type(v) ~= 'number' then return nil end
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    if not (type(m) == 'table' and m.source == 'builtin') then
        local cap = tonumber(Config.Builder and Config.Builder.bonusCap and Config.Builder.bonusCap.points)
        if cap and v > cap then v = cap end
    end
    return v
end

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsNum(v) return type(v) == 'number' and v == v end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function Int(v) return math.max(0, math.floor((tonumber(v) or 0) + 0.5)) end
local function InRange(v, r, scale)
    scale = scale or 1
    return IsNum(v) and type(r) == 'table' and v >= r[1] * scale - 1e-9 and v <= r[2] * scale + 1e-9
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

local function HasHeading(p)
    local t = type(p)
    if t == 'vector4' then return true end
    return t == 'table' and (p.w ~= nil or p[4] ~= nil or p.heading ~= nil)
end

local function HeadingOf(p)
    if type(p) == 'vector4' then return p.w + 0.0 end
    if type(p) == 'table' then return (tonumber(p.w or p[4] or p.heading) or 0.0) + 0.0 end
    return 0.0
end

local function HeadingTo(a, b)
    local ax, ay = U.xyz(a)
    local bx, by = U.xyz(b)
    if not ax or not bx then return 0.0 end
    local dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0 then return 0.0 end
    return math.deg(math.atan(-dx, dy)) % 360.0
end

-- The point d metres from p along GTA heading h (0 = north, 90 = west).
local function Along(p, h, d)
    local x, y, z = U.xyz(p)
    local r = math.rad(h)
    return x - math.sin(r) * d, y + math.cos(r) * d, z + 0.0
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

-- A road route { points, loop } from a location key (or the table itself).
local function RouteOf(location, ref)
    if ref == nil or ref == false then return nil end
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' or IsVec(v) then return nil end
    local pts = PointList(nil, v)
    if #pts < 2 then return nil end
    return { points = pts, loop = v.loop == true }
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

-- An ACTIVE participant only: run.participants also keeps everyone who already left, and a kill by a
-- player who left the run is an outside kill (CP.Npc -> CP.AntiCheat.onNpcKilled flags it), not a
-- reason to fail the run for the officers still on it.
local function IsParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    for _, s in ipairs(ctx.participants() or {}) do
        if tonumber(s) == src then return true end
    end
    return false
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

local function U32(h)
    h = tonumber(h)
    if not h then return nil end
    return math.floor(h) & 0xFFFFFFFF
end

-- The officer reporting an aim must hold a weapon (server-side selected weapon when available).
local function HoldsWeapon(src)
    if not GetSelectedPedWeapon then return true end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local w = U32(GetSelectedPedWeapon(ped))
    return w ~= nil and w ~= 0 and w ~= U32(joaat('WEAPON_UNARMED'))
end

-- The vehicle a participant is in (server native), 0 when on foot or unknown.
local function PlayerVehicle(src)
    if not GetVehiclePedIsIn then return 0 end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    return GetVehiclePedIsIn(ped, false) or 0
end

local function Kmh(e)
    if not Exists(e) or not GetEntitySpeed then return 0.0 end
    return (tonumber(GetEntitySpeed(e)) or 0.0) * 3.6
end

local function HealthRatio(p)
    if not Exists(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local max = math.max(200, GetEntityMaxHealth and tonumber(GetEntityMaxHealth(p.entity)) or 0)
    return (hp - 100) / (max - 100)
end

local function NpcSet(ctx, netId, state)
    if CP.Npc and CP.Npc.setState then CP.Npc.setState(ctx.run, netId, state) end
end

local function Neutralised(p) return p.state == 'dead' or p.state == 'cuffed' end

-- Contact hand-off: a person still seated in a stopped car is the field_contact objective's to work.
local function Settled(p) return Neutralised(p) or p.state == 'seated' end

local function Median(list)
    local s = {}
    for i = 1, #list do s[i] = list[i] end
    table.sort(s)
    local n = #s
    if n == 0 then return 0 end
    if n % 2 == 1 then return s[(n + 1) // 2] end
    return (s[n // 2] + s[n // 2 + 1]) / 2
end

local function HasArmedWeight(setName)
    local set = type(setName) == 'string' and ((Config.Custody or {}).profileSets or {})[setName] or nil
    if type(set) ~= 'table' then return false end
    for role, weights in pairs(set) do
        if role ~= 'vehicle' and type(weights) == 'table' and (tonumber(weights.armed) or 0) > 0 then return true end
    end
    return false
end

-- Occupants roll hidden truths (and spawn as contacts) when the pursuit hands them to a field_contact or
-- names a profile set.
local function ProfileSetOf(obj)
    if type(obj.profileSet) == 'string' then return obj.profileSet end
    if obj.handoff == 'contact' then return 'traffic' end
    return nil
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Defaults(obj)
    local c = Cfg()
    local fa = Config.Blocks.flee_arrest
    if obj.minSeconds == nil then obj.minSeconds = 30 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.mode == nil then obj.mode = c.mode.default end
    if obj.vehicles == nil then obj.vehicles = c.vehicles[3] end
    if obj.models == nil then obj.models = U.copy(Config.Builder.allowed.vehicles) end
    if obj.peds == nil then obj.peds = U.copy(Config.Blocks.hostile_waves.peds) end
    if obj.suspectsPerVehicle == nil then obj.suspectsPerVehicle = c.suspects[3] end
    if obj.speed == nil then obj.speed = c.speed[3] end
    if obj.style == nil then obj.style = c.style.default end
    if obj.trigger == nil then obj.trigger = 'arrive' end
    if type(obj.stopped) ~= 'table' then obj.stopped = {} end
    if obj.stopped.speed == nil then obj.stopped.speed = 5.0 end
    if obj.stopped.seconds == nil then obj.stopped.seconds = 5 end
    if obj.footFlee == nil then obj.footFlee = c.footFlee[3] / 100 end
    if obj.surrenderOnAim == nil then obj.surrenderOnAim = true end
    if type(obj.arrest) ~= 'table' then obj.arrest = {} end
    if obj.arrest.label == nil then obj.arrest.label = CP.L('block.pursuit.arrest') end
    if obj.arrest.duration == nil then obj.arrest.duration = DEFAULT_ARREST_MS end
    if obj.complete == nil then obj.complete = 'all_detained' end
    if obj.ramSpeed == nil then obj.ramSpeed = 100 end
    if obj.ramPenaltyId == nil then obj.ramPenaltyId = 'hard_ram' end
    if obj.neverShoots == nil then obj.neverShoots = true end
    if obj.neverShoots == false and obj.weapons == nil then obj.weapons = U.copy(fa.weapons) end
    local stop = obj.mode ~= 'follow'
    local race = obj.complete == 'all_or_timeout_any'
    if obj.mode == 'follow' then
        if obj.hold == nil then obj.hold = c.holdDistance[3] end
        if type(obj.lost) ~= 'table' then obj.lost = {} end
        if obj.lost.distance == nil then obj.lost.distance = c.lostDistance[3] end
        if obj.lost.seconds == nil then obj.lost.seconds = c.lostSeconds[3] end
        if obj.duration == nil then obj.duration = c.duration[3] end
        if obj.medals == nil then obj.medals = { gold = 40, silver = 80, bronze = 150 } end
    end
    if obj.medals == nil then obj.medals = false end
    if obj.failIfUndriveable == nil then obj.failIfUndriveable = obj.mode == 'follow' end
    if obj.escape == nil then
        if stop and not race then
            obj.escape = { distance = fa.escapeDistance[3], seconds = fa.escapeSeconds[3] }
        else
            obj.escape = false
        end
    end
    if obj.detainBonus == nil then obj.detainBonus = (stop and race) and 'racer_detained' or false end
    if obj.allDetainedBonus == nil then obj.allDetainedBonus = (stop and race) and 'all_racers_detained' or false end
    if obj.fastStop == nil then
        obj.fastStop = (stop and not race) and { id = 'vehicle_stopped_fast', seconds = DEFAULT_FAST_S } or false
    elseif type(obj.fastStop) == 'table' then
        if obj.fastStop.id == nil then obj.fastStop.id = 'vehicle_stopped_fast' end
        if obj.fastStop.seconds == nil then obj.fastStop.seconds = DEFAULT_FAST_S end
    end
    -- ---- PARITY OPTIONS (responses, hand-off, observe, drive-by, ram, spawn offset) ----
    if obj.handoff == nil then obj.handoff = c.handoff.default end
    if type(obj.responses) == 'table' then
        for _, k in ipairs({ 'yield', 'flee', 'fight' }) do
            if obj.responses[k] == nil then obj.responses[k] = 0 end
        end
    end
    if obj.observe == nil or obj.observe == 'off' then obj.observe = false end
    if type(obj.observe) == 'table' then
        local ob = obj.observe
        -- kinds = { pace = 0.7, follow = 0.3 }: each violator rolls its violation (kind is then the default)
        if ob.kind == nil then ob.kind = type(ob.kinds) == 'table' and 'pace' or 'pace' end
        if ob.zoneSpeed == nil then ob.zoneSpeed = c.zoneSpeed[3] end
        if type(ob.over) ~= 'table' then ob.over = { c.overMin[3], c.overMax[3] } end
        if ob.behind == nil then ob.behind = ob.kind == 'follow' and FOLLOW_BEHIND or 80.0 end
        if ob.seconds == nil then ob.seconds = ob.kind == 'follow' and FOLLOW_SECONDS or 5 end
        if ob.tolerance == nil then ob.tolerance = c.paceTolerance[3] end
    end
    if obj.driveBy == nil then obj.driveBy = c.driveBy[3] / 100 end
    if obj.ram == nil then obj.ram = c.ram[3] / 100 end
    if obj.spawnOffset == nil or obj.spawnOffset == 0 then obj.spawnOffset = false end
    return obj
end

local function ArmedCount(obj)
    local o = Defaults(U.deepcopy(obj))
    local hidden = HasArmedWeight(ProfileSetOf(o))
    if o.neverShoots ~= false and not hidden then return 0 end
    return Int(o.vehicles) * Int(o.suspectsPerVehicle)
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    -- by field name: route is nil for a free flee, and ipairs over the values would stop at that hole
    for _, field in ipairs({ 'route', 'spawn', 'spawns' }) do
        local k = o[field]
        if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end
    end
    return out
end

local function TriggerOf(obj)
    local t = obj.trigger
    if type(t) == 'table' and IsNum(t.distance) then return 'distance', t end
    if type(t) == 'table' and IsNum(t.ahead) then return 'ahead', t end
    return 'arrive', t
end

local function CheckLocation(o, loc, li, strict)
    local function need(key)
        return Bad('block.pursuit.invalid.points_missing', { key = tostring(key), location = li })
    end
    local spawnPts = {}
    if o.spawns ~= nil then
        spawnPts = PointList(loc, o.spawns)
        if #spawnPts == 0 then return need(o.spawns) end
    end
    if o.spawn ~= nil then
        local one = PointList(loc, o.spawn)
        if #one == 0 then return need(o.spawn) end
        spawnPts[#spawnPts + 1] = one[1]
    end
    local route
    if o.route ~= nil and o.route ~= false then
        route = RouteOf(loc, o.route)
        if not route then return Bad('block.pursuit.invalid.route', { location = li }) end
    end
    if #spawnPts == 0 and not route and not (loc.start and loc.start.coords) then
        return need('spawn')
    end
    local ob = o.observe
    if type(ob) == 'table' and type(ob.zoneSpeed) == 'string' then
        local c = Cfg()
        if not InRange(loc[ob.zoneSpeed], c.zoneSpeed) then
            return Bad('block.pursuit.invalid.range',
                { field = 'observe.zoneSpeed (' .. ob.zoneSpeed .. ')', min = c.zoneSpeed[1], max = c.zoneSpeed[2] })
        end
    end
    if strict then
        local start = loc.start and loc.start.coords
        for _, p in ipairs(spawnPts) do
            if InNoBuild(p) then return Bad('block.pursuit.invalid.points_zone', { location = li }) end
            if start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return Bad('block.pursuit.invalid.points_start',
                    { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
        if route then
            for _, p in ipairs(route.points) do
                if InNoBuild(p) then return Bad('block.pursuit.invalid.points_zone', { location = li }) end
            end
            if route.loop
                and U.dist2d(route.points[1], route.points[#route.points]) > Config.Builder.route.loopClose then
                return Bad('block.pursuit.invalid.loop', { location = li, max = Config.Builder.route.loopClose })
            end
        end
    end
    return true
end

-- The parity options (Config.Blocks.pursuit ranges; chances as fractions in the file).
local function ValidateParity(o, c)
    if not U.contains(c.handoff.options, o.handoff) then return Bad('block.pursuit.invalid.handoff') end
    if o.handoff == 'contact' and o.mode ~= 'stop' then return Bad('block.pursuit.invalid.handoff') end
    if o.responses ~= nil then
        local r = o.responses
        if type(r) ~= 'table' then return Bad('block.pursuit.invalid.responses') end
        for _, k in ipairs({ 'yield', 'flee', 'fight' }) do
            if not IsNum(r[k]) or r[k] < 0 or r[k] > 1 then return Bad('block.pursuit.invalid.responses') end
        end
        if math.abs(r.yield + r.flee + r.fight - 1) > 0.001 then return Bad('block.pursuit.invalid.responses') end
    end
    for _, k in ipairs({ 'driveBy', 'ram' }) do
        if not InRange(o[k], c[k], 0.01) then
            return Bad('block.pursuit.invalid.range', { field = k, min = c[k][1] / 100, max = c[k][2] / 100 })
        end
    end
    if o.spawnOffset ~= false then
        if not IsNum(o.spawnOffset) or math.abs(o.spawnOffset) > MAX_OFFSET + 1e-9 then
            return Bad('block.pursuit.invalid.spawn_offset', { max = MAX_OFFSET })
        end
        if o.route == nil or o.route == false then
            return Bad('block.pursuit.invalid.spawn_offset', { max = MAX_OFFSET })
        end
    end
    if o.team ~= nil and (not IsInt(o.team) or o.team < 1 or o.team > 8) then
        return Bad('block.pursuit.invalid.range', { field = 'team', min = 1, max = 8 })
    end
    local set = ProfileSetOf(o)
    if set ~= nil and type(((Config.Custody or {}).profileSets or {})[set]) ~= 'table' then
        return Bad('block.pursuit.invalid.profile_set')
    end
    local ob = o.observe
    if ob ~= false then
        if type(ob) ~= 'table' or (ob.kind ~= 'pace' and ob.kind ~= 'follow') then
            return Bad('block.pursuit.invalid.observe')
        end
        if o.mode ~= 'stop' then return Bad('block.pursuit.invalid.observe') end
        if ob.kinds ~= nil then
            local k = ob.kinds
            if type(k) ~= 'table' then return Bad('block.pursuit.invalid.observe') end
            local sum = 0
            for name, w in pairs(k) do
                if (name ~= 'pace' and name ~= 'follow') or not IsNum(w) or w < 0 then
                    return Bad('block.pursuit.invalid.observe')
                end
                sum = sum + w
            end
            if sum <= 0 then return Bad('block.pursuit.invalid.observe') end
        end
        local zone = ob.zoneSpeed
        if type(zone) == 'string' then
            zone = c.zoneSpeed[3]
        end -- a location key: checked per location
        local over = ob.over
        if not InRange(zone, c.zoneSpeed) or type(over) ~= 'table' or not InRange(over[1], c.overMin)
            or not InRange(over[2], c.overMax) or over[1] > over[2] or not InRange(ob.tolerance, c.paceTolerance)
            or not IsNum(ob.behind) or ob.behind <= 0 or not IsNum(ob.seconds) or ob.seconds <= 0 then
            return Bad('block.pursuit.invalid.observe')
        end
        local kind = TriggerOf(o)
        if kind ~= 'distance' then return Bad('block.pursuit.invalid.observe') end
    end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.pursuit.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed
    local function range(field, v, r, scale)
        if InRange(v, r, scale) then return true end
        return Bad('block.pursuit.invalid.range',
            { field = field, min = r[1] * (scale or 1), max = r[2] * (scale or 1) })
    end
    local ok, why

    if not U.contains(c.mode.options, o.mode) then return Bad('block.pursuit.invalid.mode') end
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.pursuit.invalid.min_seconds') end
    ok, why = range('presenceRange', o.presenceRange, c.presenceRange)
    if not ok then return false, why end
    if not IsInt(o.vehicles) then
        return Bad('block.pursuit.invalid.range', { field = 'vehicles', min = c.vehicles[1], max = c.vehicles[2] })
    end
    ok, why = range('vehicles', o.vehicles, c.vehicles)
    if not ok then return false, why end
    if not IsInt(o.suspectsPerVehicle) then
        return Bad('block.pursuit.invalid.range',
            { field = 'suspectsPerVehicle', min = c.suspects[1], max = c.suspects[2] })
    end
    ok, why = range('suspectsPerVehicle', o.suspectsPerVehicle, c.suspects)
    if not ok then return false, why end
    ok, why = range('speed', o.speed, c.speed)
    if not ok then return false, why end
    if not U.contains(c.style.options, o.style) then return Bad('block.pursuit.invalid.style') end
    ok, why = range('footFlee', o.footFlee, c.footFlee, 0.01)
    if not ok then return false, why end
    if not AllAllowed(o.models, strict and allowed.vehicles or nil) then return Bad('block.pursuit.invalid.models') end
    if not AllAllowed(o.peds, strict and allowed.peds or nil) then return Bad('block.pursuit.invalid.peds') end
    if Int(o.suspectsPerVehicle) > 2 then
        local four = U.filter(o.models, function(m) return not TWO_SEATERS[tostring(m):lower()] end)
        if #four == 0 then return Bad('block.pursuit.invalid.seats') end
    end
    local t = o.trigger
    if t ~= 'arrive' then
        if type(t) ~= 'table' then return Bad('block.pursuit.invalid.trigger') end
        if t.distance ~= nil then
            if not IsNum(t.distance) or t.distance <= 0 or (t.lights ~= nil and type(t.lights) ~= 'boolean') then
                return Bad('block.pursuit.invalid.trigger')
            end
        elseif not IsNum(t.ahead) or t.ahead <= 0 then
            return Bad('block.pursuit.invalid.trigger')
        end
    end
    local s = o.stopped
    if type(s) ~= 'table' or not IsNum(s.speed) or s.speed <= 0 or not IsNum(s.seconds) or s.seconds <= 0 then
        return Bad('block.pursuit.invalid.stopped')
    end
    if type(o.surrenderOnAim) ~= 'boolean' or type(o.neverShoots) ~= 'boolean'
        or type(o.failIfUndriveable) ~= 'boolean' then
        return Bad('block.pursuit.invalid.flags')
    end
    if type(o.arrest.label) ~= 'string' or not IsNum(o.arrest.duration) or o.arrest.duration <= 0 then
        return Bad('block.pursuit.invalid.arrest')
    end
    if o.complete ~= 'all_detained' and o.complete ~= 'all_or_timeout_any' then
        return Bad('block.pursuit.invalid.complete')
    end
    if not IsNum(o.ramSpeed) or o.ramSpeed < 0 or type(o.ramPenaltyId) ~= 'string' or o.ramPenaltyId == '' then
        return Bad('block.pursuit.invalid.ram')
    end
    if
        o.escape ~= false
        and (
            type(o.escape) ~= 'table'
            or not IsNum(o.escape.distance)
            or o.escape.distance <= 0
            or not IsNum(o.escape.seconds)
            or o.escape.seconds <= 0
        )
    then
        return Bad('block.pursuit.invalid.escape')
    end
    for _, k in ipairs({ 'detainBonus', 'allDetainedBonus' }) do
        local v = o[k]
        if v ~= false and (type(v) ~= 'string' or v == '') then
            return Bad('block.pursuit.invalid.bonus', { field = k })
        end
    end
    if
        o.fastStop ~= false
        and (
            type(o.fastStop) ~= 'table'
            or type(o.fastStop.id) ~= 'string'
            or not IsNum(o.fastStop.seconds)
            or o.fastStop.seconds <= 0
        )
    then
        return Bad('block.pursuit.invalid.bonus', { field = 'fastStop' })
    end
    if strict then
        -- a standard id (valued only by the mission's capped bonuses list) or the block default, never an
        -- id another block values with a hint (e.g. a medal); "stopped within 2 minutes" at most
        local ids = {
            detainBonus = o.detainBonus,
            allDetainedBonus = o.allDetainedBonus,
            ['fastStop.id'] = o.fastStop and o.fastStop.id or false,
            ramPenaltyId = o.ramPenaltyId,
        }
        for _, field in ipairs({ 'detainBonus', 'allDetainedBonus', 'fastStop.id', 'ramPenaltyId' }) do
            local v = ids[field]
            if v ~= false and v ~= ID_DEFAULTS[field] and not (Config.Bonuses and Config.Bonuses[v]) then
                return Bad('block.pursuit.invalid.bonus_custom', { field = field, default = ID_DEFAULTS[field] })
            end
        end
        if o.fastStop and o.fastStop.seconds > DEFAULT_FAST_S then
            return Bad('block.pursuit.invalid.range', { field = 'fastStop.seconds', min = 1, max = DEFAULT_FAST_S })
        end
        if not InRange(o.arrest.duration, CUSTOM_TIMED_MS) then
            return Bad('block.pursuit.invalid.range',
                { field = 'arrest.duration', min = CUSTOM_TIMED_MS[1], max = CUSTOM_TIMED_MS[2] })
        end
    end
    if o.neverShoots == false and not AllAllowed(o.weapons, strict and allowed.weapons or nil) then
        return Bad('block.pursuit.invalid.weapons')
    end
    if o.mode == 'follow' then
        ok, why = range('hold', o.hold, c.holdDistance)
        if not ok then return false, why end
        if type(o.lost) ~= 'table' then return Bad('block.pursuit.invalid.lost') end
        ok, why = range('lost.distance', o.lost.distance, c.lostDistance)
        if not ok then return false, why end
        ok, why = range('lost.seconds', o.lost.seconds, c.lostSeconds)
        if not ok then return false, why end
        ok, why = range('duration', o.duration, c.duration)
        if not ok then return false, why end
        if o.lost.distance <= o.hold then return Bad('block.pursuit.invalid.lost') end
        local m = o.medals
        if
            m ~= false
            and (
                type(m) ~= 'table'
                or not IsNum(m.gold)
                or not IsNum(m.silver)
                or not IsNum(m.bronze)
                or not (m.gold > 0 and m.gold < m.silver and m.silver < m.bronze)
            )
        then
            return Bad('block.pursuit.invalid.medals')
        end
    end
    ok, why = ValidateParity(o, c)
    if not ok then return false, why end
    local armed = ArmedCount(o)
    if armed > Config.Builder.maxHostiles then
        return Bad('block.pursuit.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
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
        st.mode = ctx.obj.mode
        st.vehicles, st.vorder, st.peds = {}, {}, {}
        st.counts = { vehicles = 0, peds = 0 }
        st.rams, st.speeds, st.officerVeh = {}, {}, {}
        st.follow = { inRange = 0, lostFor = 0, sum = 0, samples = 0 }
        st.detained = 0
    end
    return st
end

local function VehTarget(ctx) return Int(ctx.obj.vehicles) end
local function OccTarget(ctx) return math.min(MAX_SEATS, math.max(1, Int(ctx.obj.suspectsPerVehicle))) end

local function StartPoint(ctx)
    local s = ctx.location and ctx.location.start
    return s and s.coords or nil
end

-- The point `offset` metres along an open route from the route point nearest ref (negative = upstream,
-- against the driving direction), kept within MAX_OFFSET, with the heading of the route there.
local function AlongRoute(route, ref, offset)
    local pts = route.points
    local k = NearestIndex(pts, ref)
    local left = math.min(MAX_OFFSET, math.abs(offset))
    local step = offset < 0 and -1 or 1
    local cur = pts[k]
    local i = k
    while left > 0 do
        local nxt = pts[i + step]
        if not nxt then break end
        local d = U.dist(cur, nxt)
        if d >= left then
            local t = left / d
            local ax, ay, az = U.xyz(cur)
            local bx, by, bz = U.xyz(nxt)
            cur = vector3(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t)
            break
        end
        left = left - d
        cur = nxt
        i = i + step
    end
    -- heading: the driving direction at that point (towards the following waypoint)
    local j = math.max(1, math.min(#pts - 1, step < 0 and i - 1 or i))
    local h = HeadingTo(pts[j], pts[j + 1])
    local x, y, z = U.xyz(cur)
    return vector4(x + 0.0, y + 0.0, z + 0.0, h)
end

-- Where the i-th vehicle is placed: spawnOffset > spawns > spawn > ahead of the start > on the route > near
-- the start.
local function PlaceFor(ctx, st, i)
    local obj, loc = ctx.obj, ctx.location
    if IsNum(obj.spawnOffset) and obj.spawnOffset ~= 0 then
        local route = RouteOf(loc, obj.route)
        local ref = StartPoint(ctx)
        if not ref then
            local party = Party(ctx)
            ref = party[1] and party[1].coords or nil
        end
        if route and ref then
            local p = AlongRoute(route, ref, obj.spawnOffset)
            local x, y, z = Along(p, p.w, -(i - 1) * SPAWN_GAP)
            return vector4(x, y, z, p.w)
        end
    end
    local pts = PointList(loc, obj.spawns)
    if #pts > 0 then
        if not st.spawnOrder or #st.spawnOrder ~= #pts then st.spawnOrder = RngOf(ctx):shuffle(Indices(#pts)) end
        local k = ((i - 1) % #pts) + 1
        local lap = (i - 1) // #pts
        local base = pts[st.spawnOrder[k]]
        local h = HeadingOf(base)
        local x, y, z = Along(base, h, -lap * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    local one = PointList(loc, obj.spawn)[1]
    if one then
        local h = HeadingOf(one)
        local x, y, z = Along(one, h, -(i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    local route = RouteOf(loc, obj.route)
    local kind, t = TriggerOf(obj)
    local start = StartPoint(ctx)
    if kind == 'ahead' and start then
        local h = HeadingOf(start)
        if not HasHeading(start) and route then
            local k = NearestIndex(route.points, start)
            local nxt = route.points[k + 1] or (route.loop and route.points[1]) or route.points[k]
            h = HeadingTo(start, nxt)
        end
        local x, y, z = Along(start, h, t.ahead + (i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    if route then
        local n = #route.points
        if route.loop then
            local k = start and NearestIndex(route.points, start) or 1
            local idx = ((k - 1 - ROUTE_BACK - (i - 1)) % n) + 1
            local h = HeadingTo(route.points[idx], route.points[(idx % n) + 1])
            local x, y, z = U.xyz(route.points[idx])
            return vector4(x + 0.0, y + 0.0, z + 0.0, h)
        end
        local h = HeadingTo(route.points[1], route.points[2])
        local x, y, z = Along(route.points[1], h, -(i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    if start then
        local h = HeadingOf(start)
        local x, y, z = Along(start, h, DEFAULT_AHEAD + (i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    return nil
end

local function PickModel(ctx, seats)
    local list = ctx.obj.models or {}
    if seats > 2 then
        local four = U.filter(list, function(m) return not TWO_SEATERS[tostring(m):lower()] end)
        if #four > 0 then list = four end
    end
    return RngOf(ctx):pick(list) or 'sultan'
end

local function SetPed(ctx, st, p, state)
    if p.state == state then return end
    p.state = state
    NpcSet(ctx, p.netId, state)
    st.dirty = true
end

local function Surrender(ctx, st, p)
    p.state = 'surrendered'
    p.close, p.far = 0, 0
    p.surrenderedAt = Now()
    NpcSet(ctx, p.netId, 'surrendered')
    local a = ctx.obj.arrest or {}
    if CP.Npc and CP.Npc.enableCuff then
        CP.Npc.enableCuff(ctx.run, p.netId, {
            label = a.label or CP.L('block.pursuit.arrest'),
            duration = tonumber(a.duration) or DEFAULT_ARREST_MS,
            maxDistance = CUFF_RANGE,
        })
    end
    st.dirty = true
end

local function Fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

-- An occupant whose car has stopped: out of the car, then (after the exit) flee, fight or wait.
local function OccupantStopped(ctx, st, p)
    if p.state ~= 'driving' then return end
    p.stoppedAt = Now()
    p.far, p.close = 0, 0
    local v = st.vehicles[p.vehicle]
    if st.mode == 'follow' then
        p.fleeRoll = true
    elseif v and v.yielded then
        p.fleeRoll = false           -- a car that pulled over: its people stay put
    else
        p.fleeRoll = RngOf(ctx):chance(tonumber(ctx.obj.footFlee) or 0)
    end
    -- hand-off to a contact: people who did not run stay seated for the stop (Order out, then by demeanour);
    -- the armed people of a fighting car get out and fight
    if ctx.obj.handoff == 'contact' and not p.fleeRoll and not (p.armed and v and v.fight) then
        p.state = 'seated'
        st.dirty = true
        return
    end
    SetPed(ctx, st, p, 'stopped')
end

local function SpawnedAll(ctx, st)
    if st.counts.vehicles < VehTarget(ctx) then return false end
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if #v.occupants < v.want then return false end
    end
    return true
end

local function CheckFastStop(ctx, st)
    local f = ctx.obj.fastStop
    if st.fastDone or type(f) ~= 'table' or not st.startedAt then return end
    if not SpawnedAll(ctx, st) then return end
    for _, key in ipairs(st.vorder) do
        local s = st.vehicles[key].state
        if s ~= 'stopped' and s ~= 'wrecked' then return end
    end
    st.fastDone = true
    if Now() - st.startedAt <= (tonumber(f.seconds) or DEFAULT_FAST_S) * 1000 then
        ctx.award(f.id, { count = 1 })
    end
end

-- run.shared.contacts: every stopped car (field_contact's stop mode reads it). Occupants are filled in
-- at the hand-off.
local function RecordContact(ctx, st, v)
    local run = ctx.run
    if not run or v.contact then return end
    run.shared = run.shared or {}
    run.shared.contacts = run.shared.contacts or {}
    v.contact = {
        vehicle = v.netId,
        occupants = {},
        observed = v.observed and U.copy(v.observed) or nil,
        forced = not v.yielded,
        profileSet = ProfileSetOf(ctx.obj),
    }
    run.shared.contacts[#run.shared.contacts + 1] = v.contact
end

local function StopVehicle(ctx, st, v, wrecked)
    if v.state == 'wrecked' or v.state == 'removed' then return end
    local was = v.state
    v.state = wrecked and 'wrecked' or 'stopped'
    v.stoppedAt = Now()
    v.ramming = nil
    st.dirty = true
    if was == 'stopped' then return end
    for _, key in ipairs(v.occupants) do
        local p = st.peds[key]
        if p then OccupantStopped(ctx, st, p) end
    end
    if st.mode == 'stop' then
        if not wrecked then
            RecordContact(ctx, st, v)
            if CP.Runs and CP.Runs.noteStat then CP.Runs.noteStat(ctx.run, nil, 'vehicles_stopped', 1) end
        end
        ctx.hud({ message = { text = CP.L('block.pursuit.msg_stopped'), kind = 'success' } })
        CheckFastStop(ctx, st)
    end
end

-- A run vehicle deleted from outside (sc-police /imp or a script): never stopped, never a wreck, never
-- vehicle_stopped_fast. The engine fails or ends the run by its own rule.
local function MarkRemoved(ctx, st, v)
    if v.state == 'removed' then return end
    v.state = 'removed'
    v.ramming = nil
    st.dirty = true
end

local function NearestSrc(ctx, coords)
    local best, bestD
    for _, e in ipairs(Party(ctx)) do
        local d = U.dist(e.coords, coords)
        if not bestD or d < bestD then best, bestD = e.src, d end
    end
    return best, bestD or math.huge
end

local function HasArmed(st, v)
    for _, key in ipairs(v.occupants) do
        local p = st.peds[key]
        if p and (p.armed or p.armedTruth) and not Neutralised(p) then return true end
    end
    return false
end

-- A fighting car: its armed people draw now (CP.Runs.arm for hidden contacts), and each rolls the drive-by
-- chance (participants only, within 40 m: the client targets the participant the server names).
local function StartFight(ctx, st, v)
    v.fight = true
    local driveBy = tonumber(ctx.obj.driveBy) or 0
    local r = v.truthRng or RngOf(ctx)
    for _, key in ipairs(v.occupants) do
        local p = st.peds[key]
        if p and p.armedTruth and not p.armed then
            if CP.Runs and CP.Runs.arm then CP.Runs.arm(ctx.run, p.netId) end
            p.armed = true
        end
        if p and p.armed and p.seat ~= -1 and driveBy > 0 and r:chance(driveBy) then p.driveBy = true end
    end
end

-- The response of one car when the trigger fires (rolled at spawn: yield, flee or fight).
local function Respond(ctx, st, v)
    local resp = v.response or 'flee'
    if resp == 'fight' and not HasArmed(st, v) then resp = 'flee' end
    v.fleeAt = Now()
    if resp == 'yield' then
        v.state = 'yielding'
        v.slowFor = 0
        return 'yield'
    end
    v.state = 'fleeing'
    if resp == 'fight' then StartFight(ctx, st, v) end
    return resp
end

local RESPONSE_MSG = {
    yield = { 'block.pursuit.msg_yield', 'success' },
    flee = { 'block.pursuit.msg_fleeing', 'warning' },
    fight = { 'block.pursuit.msg_fight', 'warning' },
}

local function FleeAll(ctx, st, why)
    if st.fled then return end
    st.fled = true
    st.fledAt = Now()
    local shown
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if v.state == 'waiting' or v.state == 'cruising' then
            local r = Respond(ctx, st, v)
            if not shown or r == 'fight' or (r == 'flee' and shown == 'yield') then shown = r end
        end
    end
    st.dirty = true
    if why ~= 'start' then
        local m = RESPONSE_MSG[shown or 'flee']
        ctx.hud({ message = { text = CP.L(m[1]), kind = m[2] } })
    end
end

-- ============================================================================
--                                   SPAWNING
-- ============================================================================

-- Each vehicle's hidden rolls come from its own stream of the run seed (objective index and vehicle
-- number), so every participant, and a re-run with the same seed, gets the same response and speed
-- whatever else was rolled first. The response stays on the server until the lights trigger fires.
-- The posted speed: a number, or a location key (each corridor has its own).
ZoneSpeed = function(ctx)
    local ob = ctx.obj.observe
    local z = type(ob) == 'table' and ob.zoneSpeed or nil
    if type(z) == 'string' then z = ctx.location and ctx.location[z] end
    return tonumber(z) or Cfg().zoneSpeed[3]
end

-- behind / seconds of one violator's observation (a follow uses its own when the kind is rolled).
local function ObserveParams(ob, kind)
    if kind == 'follow' and ob.kind ~= 'follow' then
        return tonumber(ob.followBehind) or FOLLOW_BEHIND, tonumber(ob.followSeconds) or FOLLOW_SECONDS
    end
    return tonumber(ob.behind) or 80.0, tonumber(ob.seconds) or 5
end

-- What the HUD asks of the officer for one violator: the same window the server grades.
local function Watch(ob, kind)
    local behindM, seconds = ObserveParams(ob, kind or ob.kind)
    return { behind = math.floor(behindM + 0.5), seconds = seconds }
end

local function VehicleRng(ctx, i)
    local seed = (tonumber(ctx.run and ctx.run.seed) or 1) * 7919 + (ctx.index or 0) * 104729 + i * 15485863
    local r = U.rng(seed)
    r:next()
    return r
end

local function RollVehicle(ctx, v)
    local obj = ctx.obj
    local r = VehicleRng(ctx, v.index)
    local rs = obj.responses
    if type(rs) == 'table' then
        local x = r:next()
        local y, f = tonumber(rs.yield) or 0, tonumber(rs.flee) or 0
        v.response = (x < y and 'yield') or (x < y + f and 'flee') or 'fight'
    else
        v.response = 'flee'
    end
    v.driveByRoll, v.ramRoll = r:next(), r:next()
    local ob = obj.observe
    if type(ob) == 'table' then
        v.observeKind = ob.kind
        if type(ob.kinds) == 'table' then
            local p, f = tonumber(ob.kinds.pace) or 0, tonumber(ob.kinds.follow) or 0
            v.observeKind = (r:next() * (p + f) < p) and 'pace' or 'follow'
        end
        local lo, hi = tonumber(ob.over[1]) or 20, tonumber(ob.over[2]) or 45
        v.zone = ZoneSpeed(ctx)
        v.targetKmh = v.zone + lo + math.floor(r:next() * (hi - lo + 1))
    end
    v.truthRng = r
end

-- The hidden truth of the next occupant (a profile set): rolled once per seat, kept on retries.
local function OccupantTruth(ctx, v, seat)
    local set = ProfileSetOf(ctx.obj)
    if not set or not (CP.Custody and CP.Custody.rollTruth) then return nil end
    v.truths = v.truths or {}
    local k = tostring(seat)
    if v.truths[k] == nil then
        v.truths[k] = CP.Custody.rollTruth(v.truthRng or RngOf(ctx), set, seat == -1 and 'driver' or 'passenger')
            or false
    end
    return v.truths[k] or nil
end

local function SpawnOccupant(ctx, st, v)
    local obj = ctx.obj
    local seat = #v.occupants - 1          -- -1 driver, then 0, 1, 2
    local truth = OccupantTruth(ctx, v, seat)
    local hidden = ProfileSetOf(obj) ~= nil
    local armed = obj.neverShoots == false or truth == 'armed'
    if not ctx.canSpawn(1, armed) then return nil end
    local r = RngOf(ctx)
    local x, y, z = U.xyz(EntCoords(v.entity) or v.coords)
    local opts = {
        model = r:pick(obj.peds) or Config.Blocks.hostile_waves.peds[1],
        coords = vector4(x + 0.0, y + 0.0, z + 0.0, HeadingOf(v.coords)),
        role = seat == -1 and 'driver' or 'suspect',
        armed = armed,
        cfg = {
            group = (armed and not hidden) and 'hostile' or 'neutral',
            vehicle = v.netId,
            seat = seat,
            block = BLOCK,
        },
        tag = 'vehicle' .. v.index .. '_seat' .. (seat + 2),
    }
    if armed then
        local hw = Config.Blocks.hostile_waves
        opts.weapon = r:pick(obj.weapons or Config.Blocks.flee_arrest.weapons) or Config.Blocks.flee_arrest.weapons[1]
        opts.accuracy, opts.armour = ctx.combat(hw.accuracy[3], hw.armour[3])
    end
    -- a contact: no weapon, accuracy or combat settings in its bag until CP.Runs.arm at the draw
    if hidden then opts.hidden = true end
    local ent, netId = ctx.spawnPed(opts)
    if not netId then return nil end
    if SetPedIntoVehicle and Exists(ent) and Exists(v.entity) then pcall(SetPedIntoVehicle, ent, v.entity, seat) end
    local key = tostring(netId)
    local p = {
        netId = netId,
        entity = ent,
        vehicle = v.key,
        seat = seat,
        armed = armed and not hidden,
        armedTruth = armed and hidden or nil,
        truth = truth,
        state = 'driving',
        far = 0,
        close = 0,
    }
    st.peds[key] = p
    v.occupants[#v.occupants + 1] = key
    st.counts.peds = st.counts.peds + 1
    NpcSet(ctx, netId, 'driving')
    if seat == -1 and v.state == 'fleeing' then
        v.fleeAt = Now()
    end -- a late driver gets the full grace
    if v.state == 'stopped' or v.state == 'wrecked' then OccupantStopped(ctx, st, p) end
    st.dirty = true
    return p
end

local function SpawnVehicle(ctx, st, i)
    local place = PlaceFor(ctx, st, i)
    if not place then
        CP.warn(BLOCK, 'no spawn point, route or start for the suspect vehicle in run %s',
            tostring(ctx.run and ctx.run.id))
        Fail(ctx, st, 'block.pursuit.fail_setup')
        return nil
    end
    local ent, netId = ctx.spawnVehicle({
        model = PickModel(ctx, OccTarget(ctx)),
        coords = place,
        role = 'suspect_vehicle',
        tag = 'vehicle' .. i,
    })
    if not netId then return nil end
    if SetVehicleDoorsLocked and Exists(ent) then pcall(SetVehicleDoorsLocked, ent, 2) end
    local key = tostring(netId)
    local v = {
        key = key,
        netId = netId,
        entity = ent,
        index = i,
        coords = place,
        state = 'waiting',
        occupants = {},
        want = OccTarget(ctx),
        slowFor = 0,
        moved = false,
        far = 0,
        body = Exists(ent) and GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(ent)) or nil,
    }
    RollVehicle(ctx, v)
    st.vehicles[key] = v
    st.vorder[#st.vorder + 1] = key
    st.counts.vehicles = st.counts.vehicles + 1
    if type(ctx.obj.observe) == 'table' then v.state = 'cruising' end
    if st.fled then
        if v.response == 'yield' then
            v.state = 'yielding'
        else
            v.state = 'fleeing'
        end
        v.fleeAt = Now()
    end
    st.dirty = true
    return v
end

-- Spawns what is missing: occupants of spawned vehicles first, then new vehicles (caps: wait, never cut).
local function SpawnMissing(ctx, st)
    if st.spawning or st.halted or st.failed then return false end
    st.spawning = true
    local ok = true
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        while ok and #v.occupants < v.want do
            if not SpawnOccupant(ctx, st, v) then ok = false end
        end
        if not ok then break end
    end
    while ok and st.counts.vehicles < VehTarget(ctx) do
        if not ctx.canSpawn(1, false) then ok = false break end
        local v = SpawnVehicle(ctx, st, st.counts.vehicles + 1)
        if not v then ok = false break end
        while ok and #v.occupants < v.want do
            if not SpawnOccupant(ctx, st, v) then ok = false end
        end
    end
    st.spawning = false
    return ok
end

-- ============================================================================
--                             CUFFS AND COMPLETION
-- ============================================================================

local function MarkCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    p.far, p.close = 0, 0
    st.detained = st.detained + 1
    st.dirty = true
    if ctx.obj.detainBonus then ctx.award(ctx.obj.detainBonus, { count = 1 }) end
end

local function BagCuffed(p)
    return CP.Npc and CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function Totals(ctx, st)
    local total, done = 0, 0
    local contact = ctx.obj.handoff == 'contact'
    for _, p in pairs(st.peds) do
        total = total + 1
        if Neutralised(p) or (contact and Settled(p)) then done = done + 1 end
    end
    local want = VehTarget(ctx) * OccTarget(ctx)
    for _, key in ipairs(st.vorder) do want = want - OccTarget(ctx) + st.vehicles[key].want end
    return done, math.max(total, want)
end

local function StoppedCount(st)
    local n = 0
    for _, key in ipairs(st.vorder) do
        local s = st.vehicles[key].state
        if s == 'stopped' or s == 'wrecked' then n = n + 1 end
    end
    return n
end

local function MedalFor(obj, avg)
    local m = obj.medals
    if type(m) ~= 'table' then return nil end
    if avg < m.gold then return 'medal_gold' end
    if avg < m.silver then return 'medal_silver' end
    if avg < m.bronze then return 'medal_bronze' end
    return nil
end

-- The objective that works the stops: the next field_contact after this one (else the next objective).
local function ContactIndex(ctx)
    local list = (ctx.run and ctx.run.mission and ctx.run.mission.objectives)
        or (ctx.mission and ctx.mission.objectives) or {}
    local me = ctx.index or 0
    for i = me + 1, #list do
        if type(list[i]) == 'table' and list[i].block == 'field_contact' then return i end
    end
    return me + 1
end

-- handoff = 'contact': the stopped cars and their people (seated, or caught and cuffed) go to the
-- field_contact objective (CP.Runs.adoptMany) before this objective completes, so their cuffs, custody
-- events and deaths reach it and never this finished pursuit.
local function HandOff(ctx, st)
    st.handedOff = true
    local to = ContactIndex(ctx)
    local ids = {}
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if v.state == 'stopped' then
            RecordContact(ctx, st, v)
            local occ = {}
            for _, pk in ipairs(v.occupants) do
                local p = st.peds[pk]
                if p and p.state ~= 'dead' then
                    occ[#occ + 1] = {
                        netId = p.netId,
                        seat = p.seat,
                        state = p.state == 'cuffed' and 'cuffed' or (p.ran and 'fleeing' or nil),
                        truth = p.truth,
                    }
                    ids[#ids + 1] = p.netId
                end
            end
            v.contact.occupants = occ
            v.contact.observed = v.observed and U.copy(v.observed) or nil
            ids[#ids + 1] = v.netId
        end
    end
    if CP.Runs and CP.Runs.adoptMany and ctx.run and ctx.run.objectives and ctx.run.objectives[to] then
        CP.Runs.adoptMany(ctx.run, ids, to)
    end
    st.adopted = ids
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.halted then return end
    if st.mode == 'follow' then
        local held = st.follow.inRange >= (tonumber(ctx.obj.duration) or 0)
        if not held and not st.targetGone then return end
        if not st.medalDone then
            st.medalDone = true
            st.average = st.follow.samples > 0 and st.follow.sum / st.follow.samples or 0
            -- A medal needs the full follow: a target that died early (e.g. rammed into a wall) must not
            -- turn a few seconds of close following into a Gold medal once minSeconds has passed.
            st.medal = held and MedalFor(ctx.obj, st.average) or nil
            if st.medal then ctx.award(st.medal, { count = 1, points = CardPoints(ctx, MEDAL_POINTS[st.medal]) }) end
        end
        if ctx.complete({ average = U.round(st.average), medal = st.medal }) ~= false then st.completed = true end
        return
    end
    if not SpawnedAll(ctx, st) then return end
    local contact = ctx.obj.handoff == 'contact'
    local total = 0
    for _, p in pairs(st.peds) do
        total = total + 1
        if not (contact and Settled(p) or Neutralised(p)) then return end
    end
    if contact then
        for _, key in ipairs(st.vorder) do
            local s = st.vehicles[key].state
            if s ~= 'stopped' and s ~= 'wrecked' then return end
        end
        if not st.handedOff then HandOff(ctx, st) end
    end
    -- Street Race Bust: Completed only with a racer detained. Racers that all died in crashes leave
    -- nothing to do, and the time limit then fails the run (onTimeout: none detained), as the card says.
    if ctx.obj.complete == 'all_or_timeout_any' and st.detained < 1 then return end
    if ctx.obj.allDetainedBonus and not st.allDone and total > 0 and st.detained >= total then
        st.allDone = true
        ctx.award(ctx.obj.allDetainedBonus, { count = 1 })
    end
    if ctx.complete({ detained = st.detained, total = total }) ~= false then st.completed = true end
end

-- ============================================================================
--                              PER-TICK WATCHING
-- ============================================================================

local function InVehicle(p)
    if not GetVehiclePedIsIn or not Exists(p.entity) then return false end
    return (GetVehiclePedIsIn(p.entity, false) or 0) ~= 0
end

local function CheckTrigger(ctx, st, list)
    if st.fled then return end
    local kind, t = TriggerOf(ctx.obj)
    if kind ~= 'distance' then
        FleeAll(ctx, st, 'start')
        return
    end
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        local c = EntCoords(v.entity)
        if c then
            local d = NearestOf(list, c)
            local body = GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(v.entity)) or nil
            local hit = v.body and body and v.body - body >= FLEE_DAMAGE
            -- a violator cruising past the observation point is only set off by the lights (or a hit)
            local close = v.state ~= 'cruising' and (d <= FLEE_CLOSE or (t.lights == false and d <= t.distance))
            if close or hit then
                FleeAll(ctx, st, 'trigger')
                return
            end
        end
    end
end

local function SampleSpeeds(ctx, st)
    local t = Now()
    local suspectCars = {}
    for _, key in ipairs(st.vorder) do
        local e = st.vehicles[key].entity
        if e then suspectCars[e] = true end
    end
    for _, src in ipairs(ctx.participants() or {}) do
        local veh = PlayerVehicle(src)
        if suspectCars[veh] then veh = 0 end
        local k = tostring(src)
        local list = st.speeds[k] or {}
        local keep = {}
        for _, s in ipairs(list) do
            if t - s.t <= SPEED_WINDOW_MS then keep[#keep + 1] = s end
        end
        if veh ~= 0 then
            keep[#keep + 1] = { t = t, kmh = Kmh(veh) }
            st.officerVeh[k] = veh
        end
        st.speeds[k] = keep
    end
end

-- A vehicle whose entity is gone: the engine decides (a removal reaches onEvent 'removed', a wreck
-- onEntityDead). Without an engine record (or with the record gone and no removal) it counts as wrecked.
local function VehicleMissing(ctx, st, v)
    v.missing = (v.missing or 0) + 1
    if v.missing < MISSING_TICKS then return end
    local run = ctx.run
    if run and run.removedVehicles and run.removedVehicles[v.netId] then
        MarkRemoved(ctx, st, v)
    elseif not (run and type(run.entities) == 'table' and run.entities[v.netId] ~= nil) then
        StopVehicle(ctx, st, v, true)
    end
end

-- GTA heading of a vehicle (0 = north, 90 = west).
local function Forward(e)
    local h = GetEntityHeading and tonumber(GetEntityHeading(e)) or 0.0
    local r = math.rad(h)
    return -math.sin(r), math.cos(r)
end

-- observe = pace | follow: a participant in a vehicle behind the violator (within behind metres) for the
-- window; the server samples the violator's speed every second and grades the median, which may be up to
-- tolerance under the lowest speed of the violation (zone + over[1]), so one dip does not fail a pace.
local function WatchObserve(ctx, st, v, c, dt)
    local ob = ctx.obj.observe
    if type(ob) ~= 'table' or v.observed then return end
    local kind = v.observeKind or ob.kind
    local behindM, seconds = ObserveParams(ob, kind)
    local fx, fy = Forward(v.entity)
    local cx, cy = U.xyz(c)
    local ok = false
    for _, e in ipairs(Party(ctx)) do
        local px, py = U.xyz(e.coords)
        local d = U.dist(e.coords, c)
        local behind = (px - cx) * fx + (py - cy) * fy < 0
        if d <= behindM and behind and PlayerVehicle(e.src) ~= 0 then
            ok = true
            break
        end
    end
    if not ok then
        v.samples, v.observeFor = nil, 0
        return
    end
    v.samples = v.samples or {}
    v.samples[#v.samples + 1] = Kmh(v.entity)
    v.observeFor = (v.observeFor or 0) + dt
    if v.observeFor < seconds then return end
    local zone = v.zone or ZoneSpeed(ctx)
    local med = Median(v.samples)
    if kind == 'pace' and med < zone + (tonumber(ob.over[1]) or 0) - (tonumber(ob.tolerance) or 0) then
        -- not fast enough over the window: keep pacing (a fresh window)
        v.samples, v.observeFor = nil, 0
        return
    end
    v.observed = { kind = kind, speed = U.round(med), zone = zone }
    st.dirty = true
    if kind == 'pace' then
        ctx.hud({
            message = {
                text = CP.L('block.pursuit.msg_paced', { speed = U.round(med), zone = zone }),
                kind = 'success',
            },
        })
    else
        ctx.hud({ message = { text = CP.L('block.pursuit.msg_followed'), kind = 'success' } })
    end
end

-- A cruising violator: the HUD cue as it approaches, and its blip only once it has passed the observation
-- point (ambient traffic is never marked).
local function WatchCruise(ctx, st, v, c, list)
    local ob = ctx.obj.observe
    if not v.cued and NearestOf(list, c) <= APPROACH_CUE then
        v.cued = true
        local key = (v.observeKind or (type(ob) == 'table' and ob.kind)) == 'follow'
                and 'block.pursuit.msg_approach_weave'
            or 'block.pursuit.msg_approach_speed'
        ctx.hud({ message = { text = CP.L(key, { speed = v.targetKmh or 0 }), kind = 'info' } })
    end
    if not v.passed then
        local obs = StartPoint(ctx)
        if obs then
            local fx, fy = Forward(v.entity)
            local cx, cy = U.xyz(c)
            local ox, oy = U.xyz(obs)
            if (cx - ox) * fx + (cy - oy) * fy > 0 and U.dist2d(c, obs) <= PASS_RANGE then
                v.passed = true
                st.dirty = true
            end
        end
    end
end

-- A fighting car slowed with a participant close (boxed in) rams the nearest participant vehicle once.
local function WatchRam(ctx, st, v, c, speed, dt)
    if v.ramming and Now() >= v.ramming.untilMs then
        v.ramming = nil
        st.dirty = true
    end
    if not v.fight or v.rammed then return end
    local target, d = NearestSrc(ctx, c)
    if target and d <= RAM_BOX and speed < ctx.obj.stopped.speed * 2 then
        v.boxedFor = (v.boxedFor or 0) + dt
        if v.boxedFor >= RAM_BOX_S then
            v.rammed = true
            if (v.ramRoll or 1) < (tonumber(ctx.obj.ram) or 0) and PlayerVehicle(target) ~= 0 then
                v.ramming = { target = target, untilMs = Now() + RAM_MS }
                st.dirty = true
            end
        end
    else
        v.boxedFor = 0
    end
end

local function WatchVehicles(ctx, st, dt, list)
    local s = ctx.obj.stopped
    local route = RouteOf(ctx.location, ctx.obj.route)
    local routeEnd = route and not route.loop and route.points[#route.points] or nil
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        local live = v.state == 'fleeing' or v.state == 'waiting' or v.state == 'cruising' or v.state == 'yielding'
        if live then
            if not Exists(v.entity) then
                VehicleMissing(ctx, st, v)
            else
                v.missing = 0
                local c = GetEntityCoords(v.entity)
                local speed = Kmh(v.entity)
                if v.state == 'cruising' then
                    WatchCruise(ctx, st, v, c, list)
                    WatchObserve(ctx, st, v, c, dt)
                elseif v.state == 'yielding' then
                    -- pulling over: counts as stopped once below the stop speed for the stop time
                    if speed < s.speed then
                        v.slowFor = v.slowFor + dt
                        if v.slowFor >= s.seconds then
                            v.yielded = true
                            StopVehicle(ctx, st, v, false)
                        end
                    else
                        v.slowFor = 0
                    end
                elseif v.state == 'fleeing' then
                    -- an open route ends in a free flee for good: a new host must not send the car back to it
                    if routeEnd and not v.routeDone and U.dist2d(c, routeEnd) <= ROUTE_END then
                        v.routeDone = true
                        st.dirty = true
                    end
                    if speed > math.max(MOVED_KMH, s.speed * 2) then v.moved = true end
                    WatchRam(ctx, st, v, c, speed, dt)
                    if st.mode == 'stop' and #v.occupants > 0 then
                        local counting = v.moved or (v.fleeAt and Now() - v.fleeAt >= NEVER_MOVED_MS)
                        local near = NearestOf(list, c) <= STOP_NEAR
                        if counting and near and speed < s.speed then
                            v.slowFor = v.slowFor + dt
                            if v.slowFor >= s.seconds then StopVehicle(ctx, st, v, false) end
                        else
                            v.slowFor = 0
                        end
                    end
                end
            end
        end
    end
end

-- Escapes, exits, give-ups (close, low health) and missed cuffs.
local function WatchPeds(ctx, st, dt, list)
    local obj = ctx.obj
    local esc = obj.escape
    local fa = Config.Blocks.flee_arrest
    local worst = 0
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            if p.state == 'surrendered' and BagCuffed(p) then
                MarkCuffed(ctx, st, p)
            elseif not Exists(p.entity) then
                p.missing = (p.missing or 0) + 1
                if p.missing >= MISSING_TICKS then
                    p.state = 'dead'
                    st.dirty = true
                end
            else
                p.missing = 0
                local v = st.vehicles[p.vehicle]
                local c = GetEntityCoords(p.entity)
                local near = NearestOf(list, c)
                if p.state == 'stopped' then
                    -- Only once the suspect is out of the car: CP.Npc's 'flee' for a ped still in the
                    -- driver's seat is a VEHICLE flee (the stopped car would drive off again), and a
                    -- surrendered ped in a seat cannot be cuffed. The host client retries the exit and
                    -- warps the ped out after a few tries, so this does not wait forever.
                    if not InVehicle(p) then
                        if p.fleeRoll then
                            p.ran = true
                            SetPed(ctx, st, p, 'fleeing')
                        elseif p.armed then
                            SetPed(ctx, st, p, 'hostile')
                        elseif not obj.surrenderOnAim then
                            Surrender(ctx, st, p)
                        end
                    end
                end
                local moving = p.state == 'fleeing' or p.state == 'hostile'
                    or (p.state == 'driving' and v and v.state == 'fleeing')
                if esc and moving and #list > 0 and near > esc.distance then
                    p.far = (p.far or 0) + dt
                    if p.far >= esc.seconds then
                        Fail(ctx, st, 'block.pursuit.fail_escaped')
                        return
                    end
                    if p.far > worst then worst = p.far end
                else
                    p.far = 0
                end
                local onFootNow = p.state == 'fleeing' or (p.state == 'stopped' and not InVehicle(p))
                if not p.armed and onFootNow and st.mode == 'stop' then
                    if near <= fa.closeDistance then
                        p.close = (p.close or 0) + dt
                        if p.close >= fa.closeSeconds then Surrender(ctx, st, p) end
                    else
                        p.close = 0
                    end
                end
                if p.armed and (p.state == 'hostile' or p.state == 'fleeing') then
                    local ratio = HealthRatio(p)
                    if ratio and ratio > 0 and ratio < ARMED_BELOW then Surrender(ctx, st, p) end
                end
            end
        end
        if st.failed then return end
    end
    local escaping = worst > 0 and esc and math.max(0, math.ceil(esc.seconds - worst)) or nil
    if escaping ~= st.escaping then
        st.escaping = escaping
        st.dirty = true
    end
end

-- Where a suspect is: its car while it still drives it, else the ped itself.
local function SuspectCoords(st, p)
    local v = st.vehicles[p.vehicle]
    local c
    if p.state == 'driving' and v and v.state ~= 'wrecked' then c = EntCoords(v.entity) end
    return c or EntCoords(p.entity)
end

-- Follow mode: the thing to follow is the suspect nearest the party (a car while it is driven, else on foot).
local function FollowTarget(st, list)
    local best, bestD
    for _, p in pairs(st.peds) do
        local c = not Neutralised(p) and Exists(p.entity) and SuspectCoords(st, p) or nil
        if c then
            local d = NearestOf(list, c)
            if not bestD or d < bestD then best, bestD = c, d end
        end
    end
    return best
end

local function WatchFollow(ctx, st, dt, list)
    local obj = ctx.obj
    if obj.failIfUndriveable then
        for _, veh in pairs(st.officerVeh) do
            if Exists(veh) and GetVehicleEngineHealth and (tonumber(GetVehicleEngineHealth(veh)) or 1000) <= 0 then
                Fail(ctx, st, 'block.pursuit.fail_undriveable')
                return
            end
        end
    end
    if not st.fled then return end
    local target = FollowTarget(st, list)
    if not target then
        if SpawnedAll(ctx, st) and st.counts.peds > 0 then st.targetGone = true end
        return
    end
    local d = NearestOf(list, target)
    if d == math.huge then return end
    local f = st.follow
    f.samples = f.samples + 1
    f.sum = f.sum + d
    f.last = d
    if d <= obj.hold then f.inRange = f.inRange + dt end
    if d > obj.lost.distance then
        f.lostFor = f.lostFor + dt
        if f.lostFor >= obj.lost.seconds then
            Fail(ctx, st, 'block.pursuit.fail_lost')
            return
        end
        st.dirty = true
    elseif f.lostFor > 0 then
        f.lostFor = 0
        st.dirty = true
    end
    if not st.followSentAt or Now() - st.followSentAt >= FOLLOW_SEND_MS then st.dirty = true end
end

-- ============================================================================
--                                CLIENT UPDATES
-- ============================================================================

local function Snapshot(ctx, st)
    local vehicles, suspects = {}, {}
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        local occ = {}
        for i, pk in ipairs(v.occupants) do occ[i] = st.peds[pk] and st.peds[pk].netId or nil end
        local observe = type(ctx.obj.observe) == 'table'
        vehicles[#vehicles + 1] = {
            netId = v.netId,
            index = v.index,
            state = v.state,
            occupants = occ,
            routeDone = v.routeDone,
            -- observe missions: the violator's blip only once it has passed the observation point
            blip = not observe or v.passed == true or (v.state ~= 'cruising'),
            cruise = v.state == 'cruising' and { speed = v.targetKmh, weave = v.observeKind == 'follow' } or nil,
            observe = v.state == 'cruising' and v.observeKind or nil,
            watch = v.state == 'cruising' and observe and Watch(ctx.obj.observe, v.observeKind) or nil,
            observed = v.observed and true or nil,
            ram = v.ramming and v.ramming.target or nil,
        }
    end
    for _, p in pairs(st.peds) do
        local v = st.vehicles[p.vehicle]
        local target
        if p.driveBy and v and v.state == 'fleeing' and v.fight then
            local c = EntCoords(v.entity)
            local src, d = NearestSrc(ctx, c or v.coords)
            if src and d <= 40.0 then target = src end
        end
        suspects[#suspects + 1] = {
            netId = p.netId,
            vehicle = v and v.netId or nil,
            seat = p.seat,
            state = p.state == 'seated' and 'driving' or p.state,
            armed = p.armed,
            driveBy = target,
        }
    end
    table.sort(suspects, function(a, b) return a.netId < b.netId end)
    local done, total = Totals(ctx, st)
    local trig, tt = TriggerOf(ctx.obj)
    local data = {
        kind = 'state',
        mode = st.mode,
        fled = st.fled == true,
        trigger = trig,
        lights = trig == 'distance' and type(tt) == 'table' and tt.lights ~= false,
        vehicles = vehicles,
        suspects = suspects,
        detained = st.detained,
        neutralised = done,
        total = total,
        stopped = StoppedCount(st),
        vtotal = math.max(VehTarget(ctx), st.counts.vehicles),
        escaping = st.escaping,
    }
    if st.mode == 'follow' then
        local f = st.follow
        data.follow = {
            inRange = math.floor(f.inRange),
            duration = ctx.obj.duration,
            hold = ctx.obj.hold,
            lost = f.lostFor > 0 and math.max(0, math.ceil(ctx.obj.lost.seconds - f.lostFor)) or nil,
            average = f.samples > 0 and U.round(f.sum / f.samples) or nil,
        }
    end
    return data
end

local function Flush(ctx, st)
    local t = Now()
    if st.dirty or not st.sentAt or t - st.sentAt >= RESEND_MS then
        st.dirty = false
        st.sentAt = t
        if st.mode == 'follow' then st.followSentAt = t end
        ctx.send(Snapshot(ctx, st))
    end
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function RecentMaxKmh(st, src)
    local best
    for _, s in ipairs(st.speeds[tostring(src)] or {}) do
        if Now() - s.t <= SPEED_WINDOW_MS and (not best or s.kmh > best) then best = s.kmh end
    end
    return best
end

local function RamEvent(ctx, st, src, ev)
    local v = st.vehicles[tostring(tonumber(ev.netId) or '')]
    if not v then return false, 'unknown_entity' end
    local speed = tonumber(ev.speed)
    if not speed or speed ~= speed or speed < 0 or speed > RAM_MAX_KMH then return false, 'bad_speed' end
    if GetVehiclePedIsIn and PlayerVehicle(src) == 0 then return false, 'not_in_vehicle' end
    local vc, sc = EntCoords(v.entity), ctx.coords(src)
    if not vc or not sc or U.dist(vc, sc) > RAM_RANGE + REACH_SLACK then return false, 'too_far' end
    local recent = RecentMaxKmh(st, src)
    if recent and speed > recent + RAM_SLACK_KMH then return false, 'implausible' end
    local k = tostring(src) .. ':' .. v.key
    local last = st.rams[k]
    if last and Now() - last < RAM_COOLDOWN_MS then return false, 'duplicate' end
    st.rams[k] = Now()
    local limit = tonumber(ctx.obj.ramSpeed) or 0
    if limit <= 0 or speed > limit then
        ctx.penalize(ctx.obj.ramPenaltyId, { count = 1 })
        st.ramCount = (st.ramCount or 0) + 1
    end
    if v.state == 'waiting' then FleeAll(ctx, st, 'ram') end
    return true
end

local function LightsEvent(ctx, st, src, ev)
    local kind, t = TriggerOf(ctx.obj)
    if kind ~= 'distance' then return false, 'wrong_trigger' end
    if st.fled then return false, 'duplicate' end
    local v = st.vehicles[tostring(tonumber(ev.netId) or '')]
    if not v then return false, 'unknown_entity' end
    if v.state ~= 'waiting' and v.state ~= 'cruising' then return false, 'wrong_state' end
    if GetVehiclePedIsIn and PlayerVehicle(src) == 0 then return false, 'not_in_vehicle' end
    local vc, sc = EntCoords(v.entity), ctx.coords(src)
    if not vc or not sc or U.dist(vc, sc) > t.distance + LIGHTS_SLACK then return false, 'too_far' end
    -- observe first: lights before the violation was observed are a stop without cause, personal to the
    -- officer whose lights started it; the stop itself goes on and is graded normally
    if type(ctx.obj.observe) == 'table' and not v.observed and not v.noCause then
        v.noCause = src
        ctx.penalize('stop_without_cause', { count = 1, src = src })
        ctx.hud({ message = { text = CP.L('block.pursuit.msg_no_cause'), kind = 'warning' } })
    end
    FleeAll(ctx, st, 'lights')
    return true
end

local function UndriveableEvent(ctx, st, src, ev)
    if st.mode ~= 'follow' or not ctx.obj.failIfUndriveable then return false, 'wrong_mode' end
    local netId = tonumber(ev.netId)
    if not netId or not NetworkGetEntityFromNetworkId then return false, 'unknown_entity' end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not Exists(veh) then return false, 'unknown_entity' end
    local mine = PlayerVehicle(src) == veh or st.officerVeh[tostring(src)] == veh
    if not mine then return false, 'not_own_vehicle' end
    local engine = GetVehicleEngineHealth and tonumber(GetVehicleEngineHealth(veh)) or 1000
    local tank = GetVehiclePetrolTankHealth and tonumber(GetVehiclePetrolTankHealth(veh)) or 1000
    if engine > UNDRIVEABLE_ENGINE and tank > 0 then return false, 'still_driveable' end
    Fail(ctx, st, 'block.pursuit.fail_undriveable')
    return true
end

local function OnFoot(p) return p.state == 'stopped' or p.state == 'fleeing' or p.state == 'hostile' end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    if st.failed or st.halted then return false, 'ended' end
    local t = ev.type
    local ok, why
    if t == 'ram' then
        ok, why = RamEvent(ctx, st, src, ev)
    elseif t == 'lights_near' then
        ok, why = LightsEvent(ctx, st, src, ev)
    elseif t == 'undriveable' then
        ok, why = UndriveableEvent(ctx, st, src, ev)
    elseif t == 'removed' then
        local v = st.vehicles[tostring(tonumber(ev.netId) or '')]
        if not v then return false, 'unknown_entity' end
        MarkRemoved(ctx, st, v)
        ok = true
    elseif t == 'aim' or t == 'stunned' or t == 'low_health' or t == 'cuffed' or t == 'shot' then
        local p = st.peds[tostring(tonumber(ev.netId) or '')]
        if not p then return false, 'unknown_entity' end
        if t == 'shot' then
            ok = true
        elseif t == 'cuffed' then
            if p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'surrendered' then return false, 'wrong_state' end
            if not BagCuffed(p) then return false, 'not_cuffed' end
            local pc, sc = EntCoords(p.entity), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > CUFF_RANGE + REACH_SLACK then return false, 'too_far' end
            MarkCuffed(ctx, st, p)
            if CP.Runs and CP.Runs.noteArrest and ctx.run then CP.Runs.noteArrest(ctx.run, src, p.netId) end
            ok = true
        else
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not OnFoot(p) then return false, 'wrong_state' end
            if t ~= 'low_health' and InVehicle(p) then return false, 'in_vehicle' end
            if t == 'aim' then
                if p.armed then return false, 'armed' end
                if not ctx.obj.surrenderOnAim and p.state == 'stopped' then return false, 'disabled' end
                local range = p.state == 'stopped' and AIM_STOPPED or Config.Blocks.flee_arrest.aimDistance[3]
                local pc, sc = EntCoords(p.entity), ctx.coords(src)
                if not pc or not sc or U.dist(pc, sc) > range + REACH_SLACK then return false, 'too_far' end
                if not HoldsWeapon(src) then return false, 'no_weapon' end
            elseif t == 'stunned' then
                local pc, sc = EntCoords(p.entity), ctx.coords(src)
                if not pc or not sc or U.dist(pc, sc) > STUN_REPORT + REACH_SLACK then return false, 'too_far' end
                if NearestOf(Party(ctx), pc) > STUN_RANGE then return false, 'too_far' end
            else
                if not p.armed then return false, 'unarmed' end
                local ratio = HealthRatio(p)
                if not ratio or ratio <= 0 or ratio >= ARMED_BELOW then return false, 'health_ok' end
            end
            Surrender(ctx, st, p)
            ok = true
        end
    else
        return false, 'unknown_event'
    end
    if ok then TryComplete(ctx, st) end
    Flush(ctx, st)
    return ok, why
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Prepare(ctx)
    local st = StateOf(ctx)
    if st.mode == 'follow' and ctx.obj.medals and ctx.run then
        ctx.run.flags = ctx.run.flags or {}
        ctx.run.flags.medals = true
    end
end

local function Start(ctx)
    local st = StateOf(ctx)
    st.halted = nil
    st.startedAt = st.startedAt or Now()
    -- team = n: this pursuit only runs with at least n participants when it starts (Traffic Enforcement's
    -- second violator); otherwise it completes at once with nothing spawned and nothing handed off
    if tonumber(ctx.obj.team) and #(ctx.participants() or {}) < tonumber(ctx.obj.team) and st.counts.vehicles == 0 then
        st.skipped = true
        if ctx.complete({ skipped = true }) ~= false then st.completed = true end
        return
    end
    Prepare(ctx)
    SpawnMissing(ctx, st)
    if not st.failed then CheckTrigger(ctx, st, Party(ctx)) end
    st.dirty = true
    Flush(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    if st.halted or st.failed or st.completed then return end
    if st.skipped then
        if ctx.complete({ skipped = true }) ~= false then st.completed = true end
        return
    end
    dt = tonumber(dt) or 1
    if not st.startedAt then st.startedAt = Now() end
    SpawnMissing(ctx, st)
    if st.failed then return end
    local list = Party(ctx)
    SampleSpeeds(ctx, st)
    CheckTrigger(ctx, st, list)
    WatchVehicles(ctx, st, dt, list)
    WatchPeds(ctx, st, dt, list)
    if st.failed then return end
    if st.mode == 'follow' then
        WatchFollow(ctx, st, dt, list)
        if st.failed then return end
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local key = tostring(netId)
    local v = st.vehicles[key]
    if v then
        StopVehicle(ctx, st, v, true)
        TryComplete(ctx, st)
        Flush(ctx, st)
        return
    end
    local p = st.peds[key]
    if not p or p.state == 'dead' then return end
    local prev = p.state
    p.state = 'dead'
    st.dirty = true
    local protected
    if prev == 'cuffed' then
        protected = true
    elseif prev == 'surrendered' then
        protected = not (p.armed and p.surrenderedAt and Now() - p.surrenderedAt < SURRENDER_GRACE_MS)
    else
        protected = not p.armed
    end
    if protected and IsParticipant(ctx, killerSrc) then
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
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            local c = SuspectCoords(st, p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        for _, key in ipairs(st.vorder) do
            local c = EntCoords(st.vehicles[key].entity)
            if c then best = math.min(best, U.dist(coords, c)) end
        end
    end
    if best == math.huge then
        local s = StartPoint(ctx)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    if st.mode == 'follow' then
        local held = math.floor(st.follow.inRange)
        local dur = tonumber(ctx.obj.duration) or 0
        return {
            {
                label = CP.L('block.pursuit.check_follow'),
                done = st.completed == true or held >= dur,
                value = math.min(held, dur),
                max = dur,
            },
        }
    end
    local vtotal = math.max(VehTarget(ctx), st.counts.vehicles)
    local stopped = StoppedCount(st)
    local _, total = Totals(ctx, st)
    return {
        {
            label = CP.L('block.pursuit.check_stopped'),
            done = vtotal > 0 and stopped >= vtotal,
            value = stopped,
            max = vtotal,
        },
        {
            label = CP.L('block.pursuit.check_detained'),
            done = total > 0 and st.detained >= total,
            value = st.detained,
            max = total,
        },
    }
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for key in pairs(st.peds) do ctx.delete(tonumber(key)) end
    for _, key in ipairs(st.vorder) do ctx.delete(st.vehicles[key].netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    Start(ctx)
end

local function Rescale(ctx)
    local st = StateOf(ctx)
    local want = OccTarget(ctx)
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if #v.occupants < v.want then v.want = math.max(#v.occupants, math.min(v.want, want)) end
    end
    st.dirty = true
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnTimeout(ctx)
    local st = StateOf(ctx)
    if st.mode == 'stop' and ctx.obj.complete == 'all_or_timeout_any' and st.detained >= 1 and not st.failed then
        return 'completed'
    end
    return nil
end

CP.Blocks.register(BLOCK, {
    defaults = Defaults,
    validate = Validate,
    armedCount = ArmedCount,
    requiredPoints = RequiredPoints,
    prepare = Prepare,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    onEntityDead = OnEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = StateOf(ctx)
        local k = tostring(src)
        st.speeds[k], st.officerVeh[k] = nil, nil
        for rk in pairs(st.rams) do
            if U.startsWith(rk, k .. ':') then st.rams[rk] = nil end
        end
        st.dirty = true
        Flush(ctx, st)
    end,
    rescale = Rescale,
    onTimeout = OnTimeout,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = function(ctx)
        local st = StateOf(ctx)
        st.halted = true
    end,
})
