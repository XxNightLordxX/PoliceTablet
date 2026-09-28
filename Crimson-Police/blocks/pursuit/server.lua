--[[ blocks/pursuit/server.lua · objective block "pursuit" (server half)

  What it does
    Suspect vehicles (networked, ctx.spawnVehicle) with their occupants (ctx.spawnPed, seated with the
    server SetPedIntoVehicle and again by the run host) drive away from the participants. The run
    host's client drives them: along a recorded road route waypoint by waypoint (route = location key
    { points, loop }; a loop is raced lap after lap, an open flee route ends in a free flee) or in a
    free flee (route = nil). Two modes:
    - stop (Street Race Bust, Stolen Vehicle Takedown): stop every vehicle. A vehicle is stopped when
      the server sees it below stopped.speed km/h (GetEntitySpeed) for stopped.seconds in a row, once
      it has been moving (or NEVER_MOVED_MS after it fled), or when it is wrecked. Its occupants get
      out; each one rolls footFlee (ctx.rng) to run on foot. The others wait by the car and surrender
      when a participant aims at them (surrenderOnAim) or at once (surrenderOnAim = false: racers).
      Suspects give up when aimed at (AIM_STOPPED by the car, Config.Blocks.flee_arrest.aimDistance
      when running), when stunned, or when a participant stays within flee_arrest.closeDistance for
      closeSeconds. Surrendered suspects are arrested with CP.Npc.enableCuff (arrest.label /
      arrest.duration: "Detain driver" 3 s on Street Race Bust). Done when every suspect is
      neutralised (cuffed, or dead without a participant kill). complete = 'all_or_timeout_any'
      (Street Race Bust) also needs at least one suspect detained before it completes early, and
      completes at the time limit when at least one was detained (onTimeout); none detained fails.
      A suspect more than escape.distance from every participant for escape.seconds escapes: fail.
      Occupants only switch from 'stopped' to fleeing / hostile / surrendered once they are out of
      the car (the host client retries the exit and finally warps them out).
    - follow (Pursuit Sim): stay within hold metres of the suspect vehicle (or its driver on foot
      after a wreck) for a total of duration seconds. More than lost.distance from every participant
      for lost.seconds straight fails, and so does the officer's vehicle becoming undriveable
      (failIfUndriveable). The average distance sets the medal, awarded only when the full duration
      was held; run.flags.medals = true. A target that died without a participant kill ends the
      objective without a medal.
    Vehicles start when the objective starts (trigger 'arrive' or { ahead }) or, with trigger
    { distance, lights }, when a participant with lights on is within distance (client evidence
    'lights_near', checked with server coords), when any participant gets within FLEE_CLOSE, or when
    the car is hit. Rams of a suspect vehicle above ramSpeed km/h (0 = any contact) are penalised.
    Killing an unarmed, surrendered or cuffed suspect (a participant kill) fails the run.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.pursuit)
    minSeconds [30] · presenceRange [presenceRange[3] = 400] · label
    mode               'stop' | 'follow'                                   [mode.default = 'stop']
    vehicles           suspect vehicles (scales)                           [vehicles[3] = 1]
    models             vehicle models                                      [Config.Builder.allowed.vehicles]
    peds               suspect ped models (added field)                    [Config.Blocks.hostile_waves.peds]
    suspectsPerVehicle occupants per vehicle, driver included, max 4        [suspects[3] = 1]
    spawn / spawns     vec4 key / list key; else placed on the route (loop: ROUTE_BACK waypoints
                       before the intercept start), else ahead of the start
    route              location key of a road route { points, loop }       [nil = free flee]
    speed [speed[3] = 120] km/h · style 'cautious' | 'reckless'            [style.default = 'reckless']
    trigger            'arrive' | { distance = 60.0, lights = true } | { ahead = 50.0 }   ['arrive']
    stopped            { speed [5.0] km/h, seconds [5] }
    footFlee [footFlee[3] / 100 = 0.2] · surrenderOnAim [true]
    arrest             { label [locale block.pursuit.arrest], duration [5000] ms }
    follow mode        hold [holdDistance[3] = 150] · lost { distance [250], seconds [10] }
                       duration [180] s · medals { gold [40], silver [80], bronze [150] } | false
                       failIfUndriveable (added) [true in follow mode, false in stop mode]
    escape             { distance, seconds } | false   [stop + 'all_detained': flee_arrest escape
                       defaults 400 m / 20 s; otherwise false]
    complete           'all_detained' | 'all_or_timeout_any'              ['all_detained']
    ramSpeed [100] km/h (0 = any contact) · ramPenaltyId ['hard_ram'] · neverShoots [true]
    weapons (added, only with neverShoots = false)                        [Config.Blocks.flee_arrest.weapons]
    detainBonus (added)      id per detained suspect   ['racer_detained' with 'all_or_timeout_any', else false]
    allDetainedBonus (added) id when all detained      ['all_racers_detained' with 'all_or_timeout_any', else false]
    fastStop (added)         { id, seconds } | false   [stop + 'all_detained': { 'vehicle_stopped_fast', 120 }]

  Evidence accepted (onEvent)
    { type = 'ram', netId, speed }      the reporter's vehicle touched suspect vehicle netId at speed km/h;
                                        reporter in a vehicle within RAM_RANGE (server coords), speed
                                        plausible against the server's samples, once per RAM_COOLDOWN_MS
    { type = 'lights_near', netId }     lights/siren on within trigger.distance of a waiting car
    { type = 'aim', netId }             an unarmed suspect on foot aimed at (server distance + weapon check)
    { type = 'stunned', netId }         a suspect seen stunned; a participant within STUN_RANGE and the
                                        reporter within STUN_REPORT (server coords)
    { type = 'low_health', netId }      an armed suspect (neverShoots = false) re-checked below 50 % health
    { type = 'undriveable', netId }     follow mode: the reporter's vehicle, confirmed by server engine/tank health
    { type = 'cuffed', netId }          CP.Npc after a validated cuff (the cp bag says cuffed)
    { type = 'shot', netId, src }       CP.Npc: a surrendered/cuffed suspect was shot (penalty recorded there)

  Bonus / penalty ids recorded (shared)
    ramPenaltyId ['hard_ram'; Pursuit Sim 'ram'] ctx.penalize count 1 per counted ram
    detainBonus ['racer_detained'] ctx.award count 1 per detained suspect
    allDetainedBonus ['all_racers_detained'] once when every suspect was detained
    fastStop.id ['vehicle_stopped_fast'] once when every vehicle stopped within fastStop.seconds of the start
    medal_gold | medal_silver | medal_bronze   follow mode, by average distance (medals)
  Fail reason keys: block.pursuit.fail_escaped · block.pursuit.fail_lost · block.pursuit.fail_undriveable ·
    block.pursuit.fail_setup · run.fail_killed_unarmed

  ctx.state
    block, mode, rng, vehicles = { [tostring(netId)] = { key, netId, entity, index, state = 'waiting'|
    'fleeing'|'stopped'|'wrecked', occupants = { pedKey }, want, slowFor, moved, fleeAt, body } }, vorder,
    peds = { [tostring(netId)] = { netId, entity, vehicle, seat, armed, state = 'driving'|'stopped'|
    'fleeing'|'hostile'|'surrendered'|'cuffed'|'dead', fleeRoll, stoppedAt, far, close } }, counts,
    fled, startedAt, detained, rams, speeds, officerVeh, follow = { inRange, lostFor, sum, samples },
    medal, escaping, dirty, completed, failed, halted
]]

local BLOCK = 'pursuit'
local U = CP.U

local REACH_SLACK        = 2.0      -- metres of position lag allowed around interaction ranges
local CUFF_RANGE         = 3.0      -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local STUN_RANGE         = 30.0     -- a stun needs a participant this close to the suspect...
local STUN_REPORT        = 60.0     -- ...and the reporter this close (the client only watches within 60 m)
local AIM_STOPPED        = 25.0     -- a suspect waiting at the stopped car gives up when aimed at from this close
local RAM_RANGE          = 12.0     -- a ram report needs the reporter this close to the suspect vehicle
local RAM_COOLDOWN_MS    = 2500     -- one ram per participant and vehicle in this window
local RAM_SLACK_KMH      = 40.0     -- a reported speed may exceed the server's own samples by this much
local RAM_MAX_KMH        = 400.0
local LIGHTS_SLACK       = 10.0
local FLEE_CLOSE         = 15.0     -- a waiting car flees when any participant gets this close
local FLEE_DAMAGE        = 25.0     -- ...or when its body health drops this much
local NEVER_MOVED_MS     = 30000    -- a fleeing car that never got going can be stopped after this long
local MOVED_KMH          = 15.0     -- faster than this, a car has been moving
local STOP_NEAR          = 50.0     -- a stop only counts with a participant this close to the car
local SPEED_WINDOW_MS    = 3500     -- server speed samples kept per participant (ram plausibility)
local SURRENDER_GRACE_MS = 3000     -- a kill this soon after an armed suspect gave up is a shot in flight
local SPAWN_GAP          = 8.0      -- metres between vehicles placed from one point
local ROUTE_BACK         = 2        -- racers start this many waypoints before the intercept point
local FOLLOW_SEND_MS     = 2000
local RESEND_MS          = 15000
local UNDRIVEABLE_ENGINE = 100.0
local ARMED_BELOW        = 0.5
local MAX_SEATS          = 4
local MISSING_TICKS      = 2        -- ticks an entity must be missing before it counts as gone (as the engine)
local DEFAULT_ARREST_MS  = 5000
local DEFAULT_FAST_S     = 120
local DEFAULT_AHEAD      = 50.0

-- Two-seat models: with more than 2 suspects per vehicle a 4-seat model is picked.
local TWO_SEATERS = {
    elegy2 = true, dominator = true, dominator2 = true, banshee = true, infernus = true, comet2 = true,
    carbonizzare = true, zentorno = true, adder = true, turismor = true, entityxf = true, jester = true,
    massacro = true, ninef = true, coquette = true, feltzer2 = true, gauntlet = true, ruiner = true,
    vigero = true, t20 = true, osiris = true, reaper = true, cheetah = true, bullet = true, vacca = true,
    voltic = true, penumbra = true,
}

local function cfg() return Config.Blocks[BLOCK] end
local function now() return GetGameTimer() end

-- ── Small helpers ───────────────────────────────────────────────────────────
local function isNum(v) return type(v) == 'number' and v == v end
local function isInt(v) return isNum(v) and math.floor(v) == v end
local function int(v) return math.max(0, math.floor((tonumber(v) or 0) + 0.5)) end
local function inRange(v, r, scale)
    scale = scale or 1
    return isNum(v) and type(r) == 'table' and v >= r[1] * scale - 1e-9 and v <= r[2] * scale + 1e-9
end

local function bad(key, vars)
    return false, CP.L(key, vars)
end

local function isVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return isNum(x) and isNum(y) and isNum(z)
end

local function hasHeading(p)
    local t = type(p)
    if t == 'vector4' then return true end
    return t == 'table' and (p.w ~= nil or p[4] ~= nil or p.heading ~= nil)
end

local function headingOf(p)
    if type(p) == 'vector4' then return p.w + 0.0 end
    if type(p) == 'table' then return (tonumber(p.w or p[4] or p.heading) or 0.0) + 0.0 end
    return 0.0
end

local function headingTo(a, b)
    local ax, ay = U.xyz(a)
    local bx, by = U.xyz(b)
    if not ax or not bx then return 0.0 end
    local dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0 then return 0.0 end
    return math.deg(math.atan(-dx, dy)) % 360.0
end

-- The point d metres from p along GTA heading h (0 = north, 90 = west).
local function along(p, h, d)
    local x, y, z = U.xyz(p)
    local r = math.rad(h)
    return x - math.sin(r) * d, y + math.cos(r) * d, z + 0.0
end

local function pointList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if v == nil then return {} end
    if isVec(v) then return { v } end
    if type(v) ~= 'table' then return {} end
    if type(v.points) == 'table' then v = v.points end
    local out = {}
    for i = 1, #v do
        local p = v[i]
        if isVec(p) then
            out[#out + 1] = p
        elseif type(p) == 'table' and isVec(p.coords) then
            out[#out + 1] = p.coords
        end
    end
    return out
end

-- A road route { points, loop } from a location key (or the table itself).
local function routeOf(location, ref)
    if ref == nil or ref == false then return nil end
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' or isVec(v) then return nil end
    local pts = pointList(nil, v)
    if #pts < 2 then return nil end
    return { points = pts, loop = v.loop == true }
end

local function nearestIndex(pts, coords)
    local best, bi = math.huge, 1
    for i = 1, #pts do
        local d = U.dist2d(pts[i], coords)
        if d < best then best, bi = d, i end
    end
    return bi
end

local function inNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function allAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if allowed and not U.contains(allowed, v) then return false end
    end
    return true
end

local function indices(n)
    local t = {}
    for i = 1, n do t[i] = i end
    return t
end

-- An ACTIVE participant only: run.participants also keeps everyone who already left, and a kill by a
-- player who left the run is an outside kill (CP.Npc -> CP.AntiCheat.onNpcKilled flags it), not a
-- reason to fail the run for the officers still on it.
local function isParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    for _, s in ipairs(ctx.participants() or {}) do
        if tonumber(s) == src then return true end
    end
    return false
end

local function rngOf(ctx)
    local st = ctx.state
    if not st.rng then
        st.rng = ctx.rng or U.rng(((ctx.run and ctx.run.seed) or 1) + (ctx.index or 0))
    end
    return st.rng
end

local function exists(e) return e ~= nil and e ~= 0 and DoesEntityExist(e) end

local function entCoords(e)
    if exists(e) then return GetEntityCoords(e) end
    return nil
end

local function party(ctx)
    local out = {}
    for _, src in ipairs(ctx.participants() or {}) do
        local c = ctx.coords(src)
        if c then out[#out + 1] = { src = src, coords = c } end
    end
    return out
end

local function nearestOf(list, coords)
    local best = math.huge
    if not coords then return best end
    for i = 1, #list do
        local d = U.dist(list[i].coords, coords)
        if d < best then best = d end
    end
    return best
end

local function u32(h)
    h = tonumber(h)
    if not h then return nil end
    return math.floor(h) & 0xFFFFFFFF
end

-- The officer reporting an aim must hold a weapon (server-side selected weapon when available).
local function holdsWeapon(src)
    if not GetSelectedPedWeapon then return true end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end
    local w = u32(GetSelectedPedWeapon(ped))
    return w ~= nil and w ~= 0 and w ~= u32(joaat('WEAPON_UNARMED'))
end

-- The vehicle a participant is in (server native), 0 when on foot or unknown.
local function playerVehicle(src)
    if not GetVehiclePedIsIn then return 0 end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return 0 end
    return GetVehiclePedIsIn(ped, false) or 0
end

local function kmh(e)
    if not exists(e) or not GetEntitySpeed then return 0.0 end
    return (tonumber(GetEntitySpeed(e)) or 0.0) * 3.6
end

local function healthRatio(p)
    if not exists(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local max = math.max(200, GetEntityMaxHealth and tonumber(GetEntityMaxHealth(p.entity)) or 0)
    return (hp - 100) / (max - 100)
end

local function npcSet(ctx, netId, state)
    if CP.Npc and CP.Npc.setState then CP.Npc.setState(ctx.run, netId, state) end
end

local function neutralised(p) return p.state == 'dead' or p.state == 'cuffed' end

-- ── Defaults and validation ─────────────────────────────────────────────────
local function defaults(obj)
    local c = cfg()
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
    return obj
end

local function armedCount(obj)
    local o = defaults(U.deepcopy(obj))
    if o.neverShoots ~= false then return 0 end
    return int(o.vehicles) * int(o.suspectsPerVehicle)
end

local function requiredPoints(obj)
    local o = defaults(U.deepcopy(obj))
    local out = {}
    for _, k in ipairs({ o.route, o.spawn, o.spawns }) do
        if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end
    end
    return out
end

local function triggerOf(obj)
    local t = obj.trigger
    if type(t) == 'table' and isNum(t.distance) then return 'distance', t end
    if type(t) == 'table' and isNum(t.ahead) then return 'ahead', t end
    return 'arrive', t
end

local function checkLocation(o, loc, li, strict)
    local function need(key)
        return bad('block.pursuit.invalid.points_missing', { key = tostring(key), location = li })
    end
    local spawnPts = {}
    if o.spawns ~= nil then
        spawnPts = pointList(loc, o.spawns)
        if #spawnPts == 0 then return need(o.spawns) end
    end
    if o.spawn ~= nil then
        local one = pointList(loc, o.spawn)
        if #one == 0 then return need(o.spawn) end
        spawnPts[#spawnPts + 1] = one[1]
    end
    local route
    if o.route ~= nil and o.route ~= false then
        route = routeOf(loc, o.route)
        if not route then return bad('block.pursuit.invalid.route', { location = li }) end
    end
    if #spawnPts == 0 and not route and not (loc.start and loc.start.coords) then
        return need('spawn')
    end
    if strict then
        local start = loc.start and loc.start.coords
        for _, p in ipairs(spawnPts) do
            if inNoBuild(p) then return bad('block.pursuit.invalid.points_zone', { location = li }) end
            if start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return bad('block.pursuit.invalid.points_start', { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
        if route then
            for _, p in ipairs(route.points) do
                if inNoBuild(p) then return bad('block.pursuit.invalid.points_zone', { location = li }) end
            end
            if route.loop and U.dist2d(route.points[1], route.points[#route.points]) > Config.Builder.route.loopClose then
                return bad('block.pursuit.invalid.loop', { location = li, max = Config.Builder.route.loopClose })
            end
        end
    end
    return true
end

local function validate(obj, mission, location)
    if type(obj) ~= 'table' then return bad('block.pursuit.invalid.objective') end
    local c = cfg()
    local o = defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed
    local function range(field, v, r, scale)
        if inRange(v, r, scale) then return true end
        return bad('block.pursuit.invalid.range', { field = field, min = r[1] * (scale or 1), max = r[2] * (scale or 1) })
    end
    local ok, why

    if not U.contains(c.mode.options, o.mode) then return bad('block.pursuit.invalid.mode') end
    if not isNum(o.minSeconds) or o.minSeconds < 0 then return bad('block.pursuit.invalid.min_seconds') end
    ok, why = range('presenceRange', o.presenceRange, c.presenceRange); if not ok then return false, why end
    if not isInt(o.vehicles) then return bad('block.pursuit.invalid.range', { field = 'vehicles', min = c.vehicles[1], max = c.vehicles[2] }) end
    ok, why = range('vehicles', o.vehicles, c.vehicles); if not ok then return false, why end
    if not isInt(o.suspectsPerVehicle) then return bad('block.pursuit.invalid.range', { field = 'suspectsPerVehicle', min = c.suspects[1], max = c.suspects[2] }) end
    ok, why = range('suspectsPerVehicle', o.suspectsPerVehicle, c.suspects); if not ok then return false, why end
    ok, why = range('speed', o.speed, c.speed); if not ok then return false, why end
    if not U.contains(c.style.options, o.style) then return bad('block.pursuit.invalid.style') end
    ok, why = range('footFlee', o.footFlee, c.footFlee, 0.01); if not ok then return false, why end
    if not allAllowed(o.models, strict and allowed.vehicles or nil) then return bad('block.pursuit.invalid.models') end
    if not allAllowed(o.peds, strict and allowed.peds or nil) then return bad('block.pursuit.invalid.peds') end
    if int(o.suspectsPerVehicle) > 2 then
        local four = U.filter(o.models, function(m) return not TWO_SEATERS[tostring(m):lower()] end)
        if #four == 0 then return bad('block.pursuit.invalid.seats') end
    end
    local t = o.trigger
    if t ~= 'arrive' then
        if type(t) ~= 'table' then return bad('block.pursuit.invalid.trigger') end
        if t.distance ~= nil then
            if not isNum(t.distance) or t.distance <= 0 or (t.lights ~= nil and type(t.lights) ~= 'boolean') then
                return bad('block.pursuit.invalid.trigger')
            end
        elseif not isNum(t.ahead) or t.ahead <= 0 then
            return bad('block.pursuit.invalid.trigger')
        end
    end
    local s = o.stopped
    if type(s) ~= 'table' or not isNum(s.speed) or s.speed <= 0 or not isNum(s.seconds) or s.seconds <= 0 then
        return bad('block.pursuit.invalid.stopped')
    end
    if type(o.surrenderOnAim) ~= 'boolean' or type(o.neverShoots) ~= 'boolean' or type(o.failIfUndriveable) ~= 'boolean' then
        return bad('block.pursuit.invalid.flags')
    end
    if type(o.arrest.label) ~= 'string' or not isNum(o.arrest.duration) or o.arrest.duration <= 0 then
        return bad('block.pursuit.invalid.arrest')
    end
    if o.complete ~= 'all_detained' and o.complete ~= 'all_or_timeout_any' then return bad('block.pursuit.invalid.complete') end
    if not isNum(o.ramSpeed) or o.ramSpeed < 0 or type(o.ramPenaltyId) ~= 'string' or o.ramPenaltyId == '' then
        return bad('block.pursuit.invalid.ram')
    end
    if o.escape ~= false and (type(o.escape) ~= 'table' or not isNum(o.escape.distance) or o.escape.distance <= 0
        or not isNum(o.escape.seconds) or o.escape.seconds <= 0) then
        return bad('block.pursuit.invalid.escape')
    end
    for _, k in ipairs({ 'detainBonus', 'allDetainedBonus' }) do
        local v = o[k]
        if v ~= false and (type(v) ~= 'string' or v == '') then return bad('block.pursuit.invalid.bonus', { field = k }) end
    end
    if o.fastStop ~= false and (type(o.fastStop) ~= 'table' or type(o.fastStop.id) ~= 'string' or not isNum(o.fastStop.seconds) or o.fastStop.seconds <= 0) then
        return bad('block.pursuit.invalid.bonus', { field = 'fastStop' })
    end
    if o.neverShoots == false and not allAllowed(o.weapons, strict and allowed.weapons or nil) then
        return bad('block.pursuit.invalid.weapons')
    end
    if o.mode == 'follow' then
        ok, why = range('hold', o.hold, c.holdDistance); if not ok then return false, why end
        if type(o.lost) ~= 'table' then return bad('block.pursuit.invalid.lost') end
        ok, why = range('lost.distance', o.lost.distance, c.lostDistance); if not ok then return false, why end
        ok, why = range('lost.seconds', o.lost.seconds, c.lostSeconds); if not ok then return false, why end
        ok, why = range('duration', o.duration, c.duration); if not ok then return false, why end
        if o.lost.distance <= o.hold then return bad('block.pursuit.invalid.lost') end
        local m = o.medals
        if m ~= false and (type(m) ~= 'table' or not isNum(m.gold) or not isNum(m.silver) or not isNum(m.bronze)
            or not (m.gold > 0 and m.gold < m.silver and m.silver < m.bronze)) then
            return bad('block.pursuit.invalid.medals')
        end
    end
    local armed = armedCount(o)
    if armed > Config.Builder.maxHostiles then
        return bad('block.pursuit.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
    end
    if type(location) == 'table' then return checkLocation(o, location, 1, strict) end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            ok, why = checkLocation(o, loc, li, strict)
            if not ok then return false, why end
        end
    end
    return true
end

-- ── Run state ───────────────────────────────────────────────────────────────
local function stateOf(ctx)
    defaults(ctx.obj)
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

local function vehTarget(ctx) return int(ctx.obj.vehicles) end
local function occTarget(ctx) return math.min(MAX_SEATS, math.max(1, int(ctx.obj.suspectsPerVehicle))) end

local function startPoint(ctx)
    local s = ctx.location and ctx.location.start
    return s and s.coords or nil
end

-- Where the i-th vehicle is placed: spawns > spawn > ahead of the start > on the route > near the start.
local function placeFor(ctx, st, i)
    local obj, loc = ctx.obj, ctx.location
    local pts = pointList(loc, obj.spawns)
    if #pts > 0 then
        if not st.spawnOrder or #st.spawnOrder ~= #pts then st.spawnOrder = rngOf(ctx):shuffle(indices(#pts)) end
        local k = ((i - 1) % #pts) + 1
        local lap = (i - 1) // #pts
        local base = pts[st.spawnOrder[k]]
        local h = headingOf(base)
        local x, y, z = along(base, h, -lap * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    local one = pointList(loc, obj.spawn)[1]
    if one then
        local h = headingOf(one)
        local x, y, z = along(one, h, -(i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    local route = routeOf(loc, obj.route)
    local kind, t = triggerOf(obj)
    local start = startPoint(ctx)
    if kind == 'ahead' and start then
        local h = headingOf(start)
        if not hasHeading(start) and route then
            local k = nearestIndex(route.points, start)
            local nxt = route.points[k + 1] or (route.loop and route.points[1]) or route.points[k]
            h = headingTo(start, nxt)
        end
        local x, y, z = along(start, h, t.ahead + (i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    if route then
        local n = #route.points
        if route.loop then
            local k = start and nearestIndex(route.points, start) or 1
            local idx = ((k - 1 - ROUTE_BACK - (i - 1)) % n) + 1
            local h = headingTo(route.points[idx], route.points[(idx % n) + 1])
            local x, y, z = U.xyz(route.points[idx])
            return vector4(x + 0.0, y + 0.0, z + 0.0, h)
        end
        local h = headingTo(route.points[1], route.points[2])
        local x, y, z = along(route.points[1], h, -(i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    if start then
        local h = headingOf(start)
        local x, y, z = along(start, h, DEFAULT_AHEAD + (i - 1) * SPAWN_GAP)
        return vector4(x, y, z, h)
    end
    return nil
end

local function pickModel(ctx, seats)
    local list = ctx.obj.models or {}
    if seats > 2 then
        local four = U.filter(list, function(m) return not TWO_SEATERS[tostring(m):lower()] end)
        if #four > 0 then list = four end
    end
    return rngOf(ctx):pick(list) or 'sultan'
end

local function setPed(ctx, st, p, state)
    if p.state == state then return end
    p.state = state
    npcSet(ctx, p.netId, state)
    st.dirty = true
end

local function surrender(ctx, st, p)
    p.state = 'surrendered'
    p.close, p.far = 0, 0
    p.surrenderedAt = now()
    npcSet(ctx, p.netId, 'surrendered')
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

local function fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

-- An occupant whose car has stopped: out of the car, then (after the exit) flee, fight or wait.
local function occupantStopped(ctx, st, p)
    if p.state ~= 'driving' then return end
    p.stoppedAt = now()
    p.far, p.close = 0, 0
    if st.mode == 'follow' then
        p.fleeRoll = true
    else
        p.fleeRoll = rngOf(ctx):chance(tonumber(ctx.obj.footFlee) or 0)
    end
    setPed(ctx, st, p, 'stopped')
end

local function spawnedAll(ctx, st)
    if st.counts.vehicles < vehTarget(ctx) then return false end
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if #v.occupants < v.want then return false end
    end
    return true
end

local function checkFastStop(ctx, st)
    local f = ctx.obj.fastStop
    if st.fastDone or type(f) ~= 'table' or not st.startedAt then return end
    if not spawnedAll(ctx, st) then return end
    for _, key in ipairs(st.vorder) do
        local s = st.vehicles[key].state
        if s ~= 'stopped' and s ~= 'wrecked' then return end
    end
    st.fastDone = true
    if now() - st.startedAt <= (tonumber(f.seconds) or DEFAULT_FAST_S) * 1000 then
        ctx.award(f.id, { count = 1 })
    end
end

local function stopVehicle(ctx, st, v, wrecked)
    if v.state == 'wrecked' then return end
    local was = v.state
    v.state = wrecked and 'wrecked' or 'stopped'
    v.stoppedAt = now()
    st.dirty = true
    if was == 'stopped' then return end
    for _, key in ipairs(v.occupants) do
        local p = st.peds[key]
        if p then occupantStopped(ctx, st, p) end
    end
    if st.mode == 'stop' then
        ctx.hud({ message = { text = CP.L('block.pursuit.msg_stopped'), kind = 'success' } })
        checkFastStop(ctx, st)
    end
end

local function fleeAll(ctx, st, why)
    if st.fled then return end
    st.fled = true
    st.fledAt = now()
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if v.state == 'waiting' then
            v.state = 'fleeing'
            v.fleeAt = now()
        end
    end
    st.dirty = true
    if why ~= 'start' then
        ctx.hud({ message = { text = CP.L('block.pursuit.msg_fleeing'), kind = 'warning' } })
    end
end

-- ── Spawning ────────────────────────────────────────────────────────────────
local function spawnOccupant(ctx, st, v)
    local obj = ctx.obj
    local armed = obj.neverShoots == false
    if not ctx.canSpawn(1, armed) then return nil end
    local seat = #v.occupants - 1          -- -1 driver, then 0, 1, 2
    local r = rngOf(ctx)
    local x, y, z = U.xyz(entCoords(v.entity) or v.coords)
    local opts = {
        model = r:pick(obj.peds) or Config.Blocks.hostile_waves.peds[1],
        coords = vector4(x + 0.0, y + 0.0, z + 0.0, headingOf(v.coords)),
        role = seat == -1 and 'driver' or 'suspect', armed = armed,
        cfg = { group = armed and 'hostile' or 'neutral', vehicle = v.netId, seat = seat, block = BLOCK },
        tag = 'vehicle' .. v.index .. '_seat' .. (seat + 2),
    }
    if armed then
        local hw = Config.Blocks.hostile_waves
        opts.weapon = r:pick(obj.weapons) or Config.Blocks.flee_arrest.weapons[1]
        opts.accuracy, opts.armour = ctx.combat(hw.accuracy[3], hw.armour[3])
    end
    local ent, netId = ctx.spawnPed(opts)
    if not netId then return nil end
    if SetPedIntoVehicle and exists(ent) and exists(v.entity) then pcall(SetPedIntoVehicle, ent, v.entity, seat) end
    local key = tostring(netId)
    local p = { netId = netId, entity = ent, vehicle = v.key, seat = seat, armed = armed, state = 'driving', far = 0, close = 0 }
    st.peds[key] = p
    v.occupants[#v.occupants + 1] = key
    st.counts.peds = st.counts.peds + 1
    npcSet(ctx, netId, 'driving')
    if seat == -1 and v.state == 'fleeing' then v.fleeAt = now() end   -- a late driver gets the full grace
    if v.state == 'stopped' or v.state == 'wrecked' then occupantStopped(ctx, st, p) end
    st.dirty = true
    return p
end

local function spawnVehicle(ctx, st, i)
    local place = placeFor(ctx, st, i)
    if not place then
        CP.warn(BLOCK, 'no spawn point, route or start for the suspect vehicle in run %s', tostring(ctx.run and ctx.run.id))
        fail(ctx, st, 'block.pursuit.fail_setup')
        return nil
    end
    local ent, netId = ctx.spawnVehicle({
        model = pickModel(ctx, occTarget(ctx)), coords = place, role = 'suspect_vehicle', tag = 'vehicle' .. i,
    })
    if not netId then return nil end
    if SetVehicleDoorsLocked and exists(ent) then pcall(SetVehicleDoorsLocked, ent, 2) end
    local key = tostring(netId)
    local v = {
        key = key, netId = netId, entity = ent, index = i, coords = place, state = 'waiting', occupants = {},
        want = occTarget(ctx), slowFor = 0, moved = false, far = 0,
        body = exists(ent) and GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(ent)) or nil,
    }
    st.vehicles[key] = v
    st.vorder[#st.vorder + 1] = key
    st.counts.vehicles = st.counts.vehicles + 1
    if st.fled then
        v.state = 'fleeing'
        v.fleeAt = now()
    end
    st.dirty = true
    return v
end

-- Spawns what is missing: occupants of spawned vehicles first, then new vehicles (caps: wait, never cut).
local function spawnMissing(ctx, st)
    if st.spawning or st.halted or st.failed then return false end
    st.spawning = true
    local ok = true
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        while ok and #v.occupants < v.want do
            if not spawnOccupant(ctx, st, v) then ok = false end
        end
        if not ok then break end
    end
    while ok and st.counts.vehicles < vehTarget(ctx) do
        if not ctx.canSpawn(1, false) then ok = false break end
        local v = spawnVehicle(ctx, st, st.counts.vehicles + 1)
        if not v then ok = false break end
        while ok and #v.occupants < v.want do
            if not spawnOccupant(ctx, st, v) then ok = false end
        end
    end
    st.spawning = false
    return ok
end

-- ── Cuffs and completion ────────────────────────────────────────────────────
local function markCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    p.far, p.close = 0, 0
    st.detained = st.detained + 1
    st.dirty = true
    if ctx.obj.detainBonus then ctx.award(ctx.obj.detainBonus, { count = 1 }) end
end

local function bagCuffed(p)
    return CP.Npc and CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function totals(ctx, st)
    local total, done = 0, 0
    for _, p in pairs(st.peds) do
        total = total + 1
        if neutralised(p) then done = done + 1 end
    end
    local want = vehTarget(ctx) * occTarget(ctx)
    for _, key in ipairs(st.vorder) do want = want - occTarget(ctx) + st.vehicles[key].want end
    return done, math.max(total, want)
end

local function stoppedCount(st)
    local n = 0
    for _, key in ipairs(st.vorder) do
        local s = st.vehicles[key].state
        if s == 'stopped' or s == 'wrecked' then n = n + 1 end
    end
    return n
end

local function medalFor(obj, avg)
    local m = obj.medals
    if type(m) ~= 'table' then return nil end
    if avg < m.gold then return 'medal_gold' end
    if avg < m.silver then return 'medal_silver' end
    if avg < m.bronze then return 'medal_bronze' end
    return nil
end

local function tryComplete(ctx, st)
    if st.completed or st.failed or st.halted then return end
    if st.mode == 'follow' then
        local held = st.follow.inRange >= (tonumber(ctx.obj.duration) or 0)
        if not held and not st.targetGone then return end
        if not st.medalDone then
            st.medalDone = true
            st.average = st.follow.samples > 0 and st.follow.sum / st.follow.samples or 0
            -- A medal needs the full follow: a target that died early (e.g. rammed into a wall) must not
            -- turn a few seconds of close following into a Gold medal once minSeconds has passed.
            st.medal = held and medalFor(ctx.obj, st.average) or nil
            if st.medal then ctx.award(st.medal, { count = 1 }) end
        end
        if ctx.complete({ average = U.round(st.average), medal = st.medal }) ~= false then st.completed = true end
        return
    end
    if not spawnedAll(ctx, st) then return end
    local total = 0
    for _, p in pairs(st.peds) do
        total = total + 1
        if not neutralised(p) then return end
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

-- ── Per-tick watching ───────────────────────────────────────────────────────
local function inVehicle(p)
    if not GetVehiclePedIsIn or not exists(p.entity) then return false end
    return (GetVehiclePedIsIn(p.entity, false) or 0) ~= 0
end

local function checkTrigger(ctx, st, list)
    if st.fled then return end
    local kind, t = triggerOf(ctx.obj)
    if kind ~= 'distance' then
        fleeAll(ctx, st, 'start')
        return
    end
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        local c = entCoords(v.entity)
        if c then
            local d = nearestOf(list, c)
            local body = GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(v.entity)) or nil
            local hit = v.body and body and v.body - body >= FLEE_DAMAGE
            if d <= FLEE_CLOSE or hit or (t.lights == false and d <= t.distance) then
                fleeAll(ctx, st, 'trigger')
                return
            end
        end
    end
end

local function sampleSpeeds(ctx, st)
    local t = now()
    local suspectCars = {}
    for _, key in ipairs(st.vorder) do
        local e = st.vehicles[key].entity
        if e then suspectCars[e] = true end
    end
    for _, src in ipairs(ctx.participants() or {}) do
        local veh = playerVehicle(src)
        if suspectCars[veh] then veh = 0 end
        local k = tostring(src)
        local list = st.speeds[k] or {}
        local keep = {}
        for _, s in ipairs(list) do
            if t - s.t <= SPEED_WINDOW_MS then keep[#keep + 1] = s end
        end
        if veh ~= 0 then
            keep[#keep + 1] = { t = t, kmh = kmh(veh) }
            st.officerVeh[k] = veh
        end
        st.speeds[k] = keep
    end
end

local function watchVehicles(ctx, st, dt, list)
    local s = ctx.obj.stopped
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if v.state == 'fleeing' or v.state == 'waiting' then
            if not exists(v.entity) then
                v.missing = (v.missing or 0) + 1
                if v.missing >= MISSING_TICKS then stopVehicle(ctx, st, v, true) end
            elseif v.state == 'fleeing' then
                v.missing = 0
                local speed = kmh(v.entity)
                if speed > math.max(MOVED_KMH, s.speed * 2) then v.moved = true end
                if st.mode == 'stop' and #v.occupants > 0 then
                    local counting = v.moved or (v.fleeAt and now() - v.fleeAt >= NEVER_MOVED_MS)
                    local near = nearestOf(list, GetEntityCoords(v.entity)) <= STOP_NEAR
                    if counting and near and speed < s.speed then
                        v.slowFor = v.slowFor + dt
                        if v.slowFor >= s.seconds then stopVehicle(ctx, st, v, false) end
                    else
                        v.slowFor = 0
                    end
                end
            end
        end
    end
end

-- Escapes, exits, give-ups (close, low health) and missed cuffs.
local function watchPeds(ctx, st, dt, list)
    local obj = ctx.obj
    local esc = obj.escape
    local fa = Config.Blocks.flee_arrest
    local worst = 0
    for _, p in pairs(st.peds) do
        if not neutralised(p) then
            if p.state == 'surrendered' and bagCuffed(p) then
                markCuffed(ctx, st, p)
            elseif not exists(p.entity) then
                p.missing = (p.missing or 0) + 1
                if p.missing >= MISSING_TICKS then
                    p.state = 'dead'
                    st.dirty = true
                end
            else
                p.missing = 0
                local v = st.vehicles[p.vehicle]
                local c = GetEntityCoords(p.entity)
                local near = nearestOf(list, c)
                if p.state == 'stopped' then
                    -- Only once the suspect is out of the car: CP.Npc's 'flee' for a ped still in the
                    -- driver's seat is a VEHICLE flee (the stopped car would drive off again), and a
                    -- surrendered ped in a seat cannot be cuffed. The host client retries the exit and
                    -- warps the ped out after a few tries, so this does not wait forever.
                    if not inVehicle(p) then
                        if p.fleeRoll then
                            setPed(ctx, st, p, 'fleeing')
                        elseif p.armed then
                            setPed(ctx, st, p, 'hostile')
                        elseif not obj.surrenderOnAim then
                            surrender(ctx, st, p)
                        end
                    end
                end
                local moving = p.state == 'fleeing' or p.state == 'hostile'
                    or (p.state == 'driving' and v and v.state == 'fleeing')
                if esc and moving and #list > 0 and near > esc.distance then
                    p.far = (p.far or 0) + dt
                    if p.far >= esc.seconds then
                        fail(ctx, st, 'block.pursuit.fail_escaped')
                        return
                    end
                    if p.far > worst then worst = p.far end
                else
                    p.far = 0
                end
                local onFootNow = p.state == 'fleeing' or (p.state == 'stopped' and not inVehicle(p))
                if not p.armed and onFootNow and st.mode == 'stop' then
                    if near <= fa.closeDistance then
                        p.close = (p.close or 0) + dt
                        if p.close >= fa.closeSeconds then surrender(ctx, st, p) end
                    else
                        p.close = 0
                    end
                end
                if p.armed and (p.state == 'hostile' or p.state == 'fleeing') then
                    local ratio = healthRatio(p)
                    if ratio and ratio > 0 and ratio < ARMED_BELOW then surrender(ctx, st, p) end
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

-- Follow mode: the thing to follow is the car while its driver is in it, else the nearest suspect on foot.
local function followTarget(st)
    local v = st.vehicles[st.vorder[1] or '']
    if v and v.state ~= 'wrecked' and exists(v.entity) then
        for _, key in ipairs(v.occupants) do
            local p = st.peds[key]
            if p and p.seat == -1 and p.state == 'driving' then return GetEntityCoords(v.entity) end
        end
    end
    local best
    for _, p in pairs(st.peds) do
        if not neutralised(p) and exists(p.entity) then
            best = best or GetEntityCoords(p.entity)
        end
    end
    return best
end

local function watchFollow(ctx, st, dt, list)
    local obj = ctx.obj
    if obj.failIfUndriveable then
        for _, veh in pairs(st.officerVeh) do
            if exists(veh) and GetVehicleEngineHealth and (tonumber(GetVehicleEngineHealth(veh)) or 1000) <= 0 then
                fail(ctx, st, 'block.pursuit.fail_undriveable')
                return
            end
        end
    end
    if not st.fled then return end
    local target = followTarget(st)
    if not target then
        if spawnedAll(ctx, st) and st.counts.peds > 0 then st.targetGone = true end
        return
    end
    local d = nearestOf(list, target)
    if d == math.huge then return end
    local f = st.follow
    f.samples = f.samples + 1
    f.sum = f.sum + d
    f.last = d
    if d <= obj.hold then f.inRange = f.inRange + dt end
    if d > obj.lost.distance then
        f.lostFor = f.lostFor + dt
        if f.lostFor >= obj.lost.seconds then
            fail(ctx, st, 'block.pursuit.fail_lost')
            return
        end
        st.dirty = true
    elseif f.lostFor > 0 then
        f.lostFor = 0
        st.dirty = true
    end
    if not st.followSentAt or now() - st.followSentAt >= FOLLOW_SEND_MS then st.dirty = true end
end

-- ── Client updates ──────────────────────────────────────────────────────────
local function snapshot(ctx, st)
    local vehicles, suspects = {}, {}
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        local occ = {}
        for i, pk in ipairs(v.occupants) do occ[i] = st.peds[pk] and st.peds[pk].netId or nil end
        vehicles[#vehicles + 1] = { netId = v.netId, index = v.index, state = v.state, occupants = occ }
    end
    for _, p in pairs(st.peds) do
        local v = st.vehicles[p.vehicle]
        suspects[#suspects + 1] = { netId = p.netId, vehicle = v and v.netId or nil, seat = p.seat, state = p.state, armed = p.armed }
    end
    table.sort(suspects, function(a, b) return a.netId < b.netId end)
    local done, total = totals(ctx, st)
    local trig, tt = triggerOf(ctx.obj)
    local data = {
        kind = 'state', mode = st.mode, fled = st.fled == true, trigger = trig,
        lights = trig == 'distance' and type(tt) == 'table' and tt.lights ~= false,
        vehicles = vehicles, suspects = suspects, detained = st.detained, neutralised = done, total = total,
        stopped = stoppedCount(st), vtotal = math.max(vehTarget(ctx), st.counts.vehicles), escaping = st.escaping,
    }
    if st.mode == 'follow' then
        local f = st.follow
        data.follow = {
            inRange = math.floor(f.inRange), duration = ctx.obj.duration, hold = ctx.obj.hold,
            lost = f.lostFor > 0 and math.max(0, math.ceil(ctx.obj.lost.seconds - f.lostFor)) or nil,
            average = f.samples > 0 and U.round(f.sum / f.samples) or nil,
        }
    end
    return data
end

local function flush(ctx, st)
    local t = now()
    if st.dirty or not st.sentAt or t - st.sentAt >= RESEND_MS then
        st.dirty = false
        st.sentAt = t
        if st.mode == 'follow' then st.followSentAt = t end
        ctx.send(snapshot(ctx, st))
    end
end

-- ── Evidence ────────────────────────────────────────────────────────────────
local function recentMaxKmh(st, src)
    local best
    for _, s in ipairs(st.speeds[tostring(src)] or {}) do
        if now() - s.t <= SPEED_WINDOW_MS and (not best or s.kmh > best) then best = s.kmh end
    end
    return best
end

local function ramEvent(ctx, st, src, ev)
    local v = st.vehicles[tostring(tonumber(ev.netId) or '')]
    if not v then return false, 'unknown_entity' end
    local speed = tonumber(ev.speed)
    if not speed or speed ~= speed or speed < 0 or speed > RAM_MAX_KMH then return false, 'bad_speed' end
    if GetVehiclePedIsIn and playerVehicle(src) == 0 then return false, 'not_in_vehicle' end
    local vc, sc = entCoords(v.entity), ctx.coords(src)
    if not vc or not sc or U.dist(vc, sc) > RAM_RANGE + REACH_SLACK then return false, 'too_far' end
    local recent = recentMaxKmh(st, src)
    if recent and speed > recent + RAM_SLACK_KMH then return false, 'implausible' end
    local k = tostring(src) .. ':' .. v.key
    local last = st.rams[k]
    if last and now() - last < RAM_COOLDOWN_MS then return false, 'duplicate' end
    st.rams[k] = now()
    local limit = tonumber(ctx.obj.ramSpeed) or 0
    if limit <= 0 or speed > limit then
        ctx.penalize(ctx.obj.ramPenaltyId, { count = 1 })
        st.ramCount = (st.ramCount or 0) + 1
    end
    if v.state == 'waiting' then fleeAll(ctx, st, 'ram') end
    return true
end

local function lightsEvent(ctx, st, src, ev)
    local kind, t = triggerOf(ctx.obj)
    if kind ~= 'distance' then return false, 'wrong_trigger' end
    if st.fled then return false, 'duplicate' end
    local v = st.vehicles[tostring(tonumber(ev.netId) or '')]
    if not v then return false, 'unknown_entity' end
    if v.state ~= 'waiting' then return false, 'wrong_state' end
    if GetVehiclePedIsIn and playerVehicle(src) == 0 then return false, 'not_in_vehicle' end
    local vc, sc = entCoords(v.entity), ctx.coords(src)
    if not vc or not sc or U.dist(vc, sc) > t.distance + LIGHTS_SLACK then return false, 'too_far' end
    fleeAll(ctx, st, 'lights')
    return true
end

local function undriveableEvent(ctx, st, src, ev)
    if st.mode ~= 'follow' or not ctx.obj.failIfUndriveable then return false, 'wrong_mode' end
    local netId = tonumber(ev.netId)
    if not netId or not NetworkGetEntityFromNetworkId then return false, 'unknown_entity' end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not exists(veh) then return false, 'unknown_entity' end
    local mine = playerVehicle(src) == veh or st.officerVeh[tostring(src)] == veh
    if not mine then return false, 'not_own_vehicle' end
    local engine = GetVehicleEngineHealth and tonumber(GetVehicleEngineHealth(veh)) or 1000
    local tank = GetVehiclePetrolTankHealth and tonumber(GetVehiclePetrolTankHealth(veh)) or 1000
    if engine > UNDRIVEABLE_ENGINE and tank > 0 then return false, 'still_driveable' end
    fail(ctx, st, 'block.pursuit.fail_undriveable')
    return true
end

local function onFoot(p) return p.state == 'stopped' or p.state == 'fleeing' or p.state == 'hostile' end

local function onEvent(ctx, src, ev)
    local st = stateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    if st.failed or st.halted then return false, 'ended' end
    local t = ev.type
    local ok, why
    if t == 'ram' then
        ok, why = ramEvent(ctx, st, src, ev)
    elseif t == 'lights_near' then
        ok, why = lightsEvent(ctx, st, src, ev)
    elseif t == 'undriveable' then
        ok, why = undriveableEvent(ctx, st, src, ev)
    elseif t == 'aim' or t == 'stunned' or t == 'low_health' or t == 'cuffed' or t == 'shot' then
        local p = st.peds[tostring(tonumber(ev.netId) or '')]
        if not p then return false, 'unknown_entity' end
        if t == 'shot' then
            ok = true
        elseif t == 'cuffed' then
            if p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'surrendered' then return false, 'wrong_state' end
            if not bagCuffed(p) then return false, 'not_cuffed' end
            local pc, sc = entCoords(p.entity), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > CUFF_RANGE + REACH_SLACK then return false, 'too_far' end
            markCuffed(ctx, st, p)
            ok = true
        else
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not onFoot(p) then return false, 'wrong_state' end
            if t ~= 'low_health' and inVehicle(p) then return false, 'in_vehicle' end
            if t == 'aim' then
                if p.armed then return false, 'armed' end
                if not ctx.obj.surrenderOnAim and p.state == 'stopped' then return false, 'disabled' end
                local range = p.state == 'stopped' and AIM_STOPPED or Config.Blocks.flee_arrest.aimDistance[3]
                local pc, sc = entCoords(p.entity), ctx.coords(src)
                if not pc or not sc or U.dist(pc, sc) > range + REACH_SLACK then return false, 'too_far' end
                if not holdsWeapon(src) then return false, 'no_weapon' end
            elseif t == 'stunned' then
                local pc, sc = entCoords(p.entity), ctx.coords(src)
                if not pc or not sc or U.dist(pc, sc) > STUN_REPORT + REACH_SLACK then return false, 'too_far' end
                if nearestOf(party(ctx), pc) > STUN_RANGE then return false, 'too_far' end
            else
                if not p.armed then return false, 'unarmed' end
                local ratio = healthRatio(p)
                if not ratio or ratio <= 0 or ratio >= ARMED_BELOW then return false, 'health_ok' end
            end
            surrender(ctx, st, p)
            ok = true
        end
    else
        return false, 'unknown_event'
    end
    if ok then tryComplete(ctx, st) end
    flush(ctx, st)
    return ok, why
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function prepare(ctx)
    local st = stateOf(ctx)
    if st.mode == 'follow' and ctx.obj.medals and ctx.run then
        ctx.run.flags = ctx.run.flags or {}
        ctx.run.flags.medals = true
    end
end

local function start(ctx)
    local st = stateOf(ctx)
    st.halted = nil
    st.startedAt = st.startedAt or now()
    prepare(ctx)
    spawnMissing(ctx, st)
    if not st.failed then checkTrigger(ctx, st, party(ctx)) end
    st.dirty = true
    flush(ctx, st)
end

local function tick(ctx, dt)
    local st = stateOf(ctx)
    if st.halted or st.failed or st.completed then return end
    dt = tonumber(dt) or 1
    if not st.startedAt then st.startedAt = now() end
    spawnMissing(ctx, st)
    if st.failed then return end
    local list = party(ctx)
    sampleSpeeds(ctx, st)
    checkTrigger(ctx, st, list)
    watchVehicles(ctx, st, dt, list)
    watchPeds(ctx, st, dt, list)
    if st.failed then return end
    if st.mode == 'follow' then
        watchFollow(ctx, st, dt, list)
        if st.failed then return end
    end
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function onEntityDead(ctx, netId, killerSrc)
    local st = stateOf(ctx)
    local key = tostring(netId)
    local v = st.vehicles[key]
    if v then
        stopVehicle(ctx, st, v, true)
        tryComplete(ctx, st)
        flush(ctx, st)
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
        protected = not (p.armed and p.surrenderedAt and now() - p.surrenderedAt < SURRENDER_GRACE_MS)
    else
        protected = not p.armed
    end
    if protected and isParticipant(ctx, killerSrc) then
        fail(ctx, st, 'run.fail_killed_unarmed')
        return
    end
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function presence(ctx, src, coords)
    local st = stateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    for _, p in pairs(st.peds) do
        if not neutralised(p) then
            local v = st.vehicles[p.vehicle]
            local c
            if p.state == 'driving' and v and v.state ~= 'wrecked' then c = entCoords(v.entity) end
            c = c or entCoords(p.entity)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        for _, key in ipairs(st.vorder) do
            local c = entCoords(st.vehicles[key].entity)
            if c then best = math.min(best, U.dist(coords, c)) end
        end
    end
    if best == math.huge then
        local s = startPoint(ctx)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function checklist(ctx)
    local st = stateOf(ctx)
    if st.mode == 'follow' then
        local held = math.floor(st.follow.inRange)
        local dur = tonumber(ctx.obj.duration) or 0
        return { { label = CP.L('block.pursuit.check_follow'), done = st.completed == true or held >= dur, value = math.min(held, dur), max = dur } }
    end
    local vtotal = math.max(vehTarget(ctx), st.counts.vehicles)
    local stopped = stoppedCount(st)
    local _, total = totals(ctx, st)
    return {
        { label = CP.L('block.pursuit.check_stopped'), done = vtotal > 0 and stopped >= vtotal, value = stopped, max = vtotal },
        { label = CP.L('block.pursuit.check_detained'), done = total > 0 and st.detained >= total, value = st.detained, max = total },
    }
end

local function restart(ctx)
    local st = stateOf(ctx)
    for key in pairs(st.peds) do ctx.delete(tonumber(key)) end
    for _, key in ipairs(st.vorder) do ctx.delete(st.vehicles[key].netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    start(ctx)
end

local function rescale(ctx)
    local st = stateOf(ctx)
    local want = occTarget(ctx)
    for _, key in ipairs(st.vorder) do
        local v = st.vehicles[key]
        if #v.occupants < v.want then v.want = math.max(#v.occupants, math.min(v.want, want)) end
    end
    st.dirty = true
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function onTimeout(ctx)
    local st = stateOf(ctx)
    if st.mode == 'stop' and ctx.obj.complete == 'all_or_timeout_any' and st.detained >= 1 and not st.failed then
        return 'completed'
    end
    return nil
end

CP.Blocks.register(BLOCK, {
    defaults = defaults,
    validate = validate,
    armedCount = armedCount,
    requiredPoints = requiredPoints,
    prepare = prepare,
    start = start,
    tick = tick,
    onEvent = onEvent,
    onEntityDead = onEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = stateOf(ctx)
        local k = tostring(src)
        st.speeds[k], st.officerVeh[k] = nil, nil
        for rk in pairs(st.rams) do
            if U.startsWith(rk, k .. ':') then st.rams[rk] = nil end
        end
        st.dirty = true
        flush(ctx, st)
    end,
    rescale = rescale,
    onTimeout = onTimeout,
    presence = presence,
    checklist = checklist,
    restart = restart,
    stop = function(ctx)
        local st = stateOf(ctx)
        st.halted = true
    end,
})
