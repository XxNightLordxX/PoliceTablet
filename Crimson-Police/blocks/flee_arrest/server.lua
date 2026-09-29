-- Objective block "flee_arrest" (server half)

local BLOCK = 'flee_arrest'
local U = CP.U

local REACH_SLACK = 2.0                  -- metres of position lag allowed around interaction ranges
local KNOCK_RANGE = 2.5                  -- ox_target distance of "Knock and announce"
local CUFF_RANGE = 3.0                   -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local STUN_RANGE = 30.0                  -- a stun needs a participant this close to the suspect
local STUN_REPORT_RANGE = 50.0           -- ...and the reporter this close (clients only look within 40 m)
local TIMED_SHARE = 0.8                  -- a timed interaction must last at least this share of its duration
local FIRE_RELEASE = 1.5                 -- an armed inmate goes back to fleeing beyond fireWithin × this
local DOOR_STEP = 1.0                    -- metres outside the door where a surrendering suspect stands
local DOOR_FLIP_DOT = 0.25               -- the door heading is turned round when the start is this clearly behind it
local REUSE_OFFSET = 1.25
local SURRENDER_GRACE_MS = 3000          -- a kill this soon after an armed suspect gave up is a shot in flight
local DEFAULT_KNOCK_MS = 3000
local DEFAULT_CUFF_MS = 5000
local DEFAULT_SUSPECTS = 5
local DEFAULT_SHARE = 0.4
local DEFAULT_FIRE = 15.0
local DEFAULT_BELOW = 0.5
local PRISON_MODEL = 's_m_y_prisoner_01'
local CUSTOM_TIMED_MS = { 1000, 30000 }  -- custom missions: knock and cuff progress times (ms)

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

-- routes: a list of routes (each a list of vec3 or { points = {...} }); a bare list of points is one route.
local function RouteList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' then return {} end
    if type(v.points) == 'table' or IsVec(v[1]) then
        local one = PointList(nil, v)
        return #one > 0 and { one } or {}
    end
    local out = {}
    for i = 1, #v do
        local r = PointList(nil, v[i])
        if #r > 0 then out[#out + 1] = r end
    end
    return out
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function OutsideZones(points)
    return U.filter(points, function(p) return not InNoBuild(p) end)
end

local function AllAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if allowed and not U.contains(allowed, v) then return false end
    end
    return true
end

-- Only a built-in mission file may pass its own bonus values (aliveBonus.points) as a value hint.
local function TrustedFile(ctx)
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    return type(m) == 'table' and m.source == 'builtin'
end

-- Custom missions: timed actions (knock, cuff) take 1-30 s like every builder progress time, and a cuff
-- can never reach further than CP.Npc.enableCuff's own range.
local function CustomTimed(field, ms)
    if InRange(ms, CUSTOM_TIMED_MS) then return true end
    return Bad('block.flee_arrest.invalid.range', { field = field, min = CUSTOM_TIMED_MS[1], max = CUSTOM_TIMED_MS[2] })
end

local function CustomCuffRange(v)
    if v == nil or (IsNum(v) and v > 0 and v <= CUFF_RANGE + 1e-9) then return true end
    return Bad('block.flee_arrest.invalid.range', { field = 'cuff.maxDistance', min = 0, max = CUFF_RANGE })
end

local function IsParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    if ctx.run and type(ctx.run.participants) == 'table' and ctx.run.participants[src] then return true end
    for _, s in ipairs(ctx.participants() or {}) do
        if s == src then return true end
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

local function PedCoords(p)
    if p.entity and DoesEntityExist(p.entity) then return GetEntityCoords(p.entity) end
    return nil
end

-- Server-side max health (GetEntityMaxHealth, else GetPedMaxHealth; 0 when neither answers).
local function ServerMaxHealth(e)
    local m = GetEntityMaxHealth and tonumber(GetEntityMaxHealth(e)) or nil
    if (not m or m <= 0) and GetPedMaxHealth then m = tonumber(GetPedMaxHealth(e)) end
    return m or 0
end

local function HealthRatio(p)
    if not p.entity or not DoesEntityExist(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local serverMax = ServerMaxHealth(p.entity)
    local max = math.max(tonumber(p.maxHealth) or 200, serverMax or 0)
    if max > 100 then return (hp - 100) / (max - 100) end
    return hp / math.max(max, 1)
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

local function Neutralised(p)
    return p.state == 'dead' or p.state == 'cuffed'
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function NormaliseGivesUp(g, c)
    if g == nil then g = {} end
    if g == false then return { aim = false, stun = false, close = false } end
    if type(g) ~= 'table' then g = {} end
    if type(g[1]) == 'string' then
        local list = g
        g = {
            aim = U.contains(list, 'aim') and c.aimDistance[3] + 0.0 or false,
            stun = U.contains(list, 'stun'),
            close = U.contains(list, 'close') and { distance = c.closeDistance, seconds = c.closeSeconds } or false,
        }
    end
    if g.aim == nil or g.aim == true then g.aim = c.aimDistance[3] + 0.0 end
    if g.stun == nil then g.stun = true end
    if g.close == nil or g.close == true then g.close = {} end
    if type(g.close) == 'table' then
        if g.close.distance == nil then g.close.distance = c.closeDistance end
        if g.close.seconds == nil then g.close.seconds = c.closeSeconds end
    end
    return g
end

local function Defaults(obj)
    local c = Cfg()
    local hw = Config.Blocks.hostile_waves
    if obj.minSeconds == nil then obj.minSeconds = 30 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.mode == nil then obj.mode = 'door' end
    if obj.weapons == nil then obj.weapons = U.copy(c.weapons) end
    if obj.models == nil then
        obj.models = obj.mode == 'scatter' and { PRISON_MODEL } or U.copy(hw.peds)
    end
    if obj.accuracy == nil then obj.accuracy = hw.accuracy[3] end
    if obj.armour == nil then obj.armour = hw.armour[3] end
    if obj.fireWithin == nil then obj.fireWithin = DEFAULT_FIRE end
    if type(obj.escape) ~= 'table' then obj.escape = {} end
    if obj.escape.distance == nil then obj.escape.distance = c.escapeDistance[3] end
    if obj.escape.seconds == nil then obj.escape.seconds = c.escapeSeconds[3] end
    obj.givesUp = NormaliseGivesUp(obj.givesUp, c)
    if obj.armedGivesUp == false then obj.armedGivesUp = { stun = false, belowHealth = false } end
    if type(obj.armedGivesUp) ~= 'table' then obj.armedGivesUp = {} end
    if obj.armedGivesUp.stun == nil then obj.armedGivesUp.stun = true end
    if obj.armedGivesUp.belowHealth == nil then obj.armedGivesUp.belowHealth = DEFAULT_BELOW end
    if type(obj.cuff) ~= 'table' then obj.cuff = {} end
    if obj.cuff.label == nil then obj.cuff.label = CP.L('block.flee_arrest.cuff') end
    if obj.cuff.duration == nil then obj.cuff.duration = DEFAULT_CUFF_MS end
    if type(obj.aliveBonus) ~= 'table' then obj.aliveBonus = {} end
    if obj.aliveBonus.id == nil then obj.aliveBonus.id = 'suspect_alive' end
    if obj.mode == 'door' then
        if obj.door == nil then obj.door = 'door' end
        if obj.suspect == nil then obj.suspect = 'suspect' end
        if obj.fleeTo == nil then obj.fleeTo = 'fleeTo' end
        if type(obj.knock) ~= 'table' then obj.knock = {} end
        if obj.knock.label == nil then obj.knock.label = CP.L('block.flee_arrest.knock') end
        if obj.knock.duration == nil then obj.knock.duration = DEFAULT_KNOCK_MS end
        if type(obj.responses) ~= 'table' then
            obj.responses = {
                surrender = c.responses.surrender / 100,
                flee = c.responses.flee / 100,
                fight = c.responses.fight / 100,
            }
        else
            if obj.responses.surrender == nil then obj.responses.surrender = 0 end
            if obj.responses.flee == nil then obj.responses.flee = 0 end
            if obj.responses.fight == nil then obj.responses.fight = 0 end
        end
        if type(obj.associates) ~= 'table' then obj.associates = {} end
        local a = obj.associates
        if a.count == nil then a.count = 1 end
        if a.spawns == nil then a.spawns = 'associates' end
        if a.weapons == nil then a.weapons = U.copy(obj.weapons) end
        if a.accuracy == nil then a.accuracy = hw.accuracy[3] end
        if a.armour == nil then a.armour = hw.armour[3] end
    else
        if obj.spawns == nil then obj.spawns = 'spawns' end
        if obj.routes == nil then obj.routes = 'routes' end
        if obj.suspects == nil then obj.suspects = DEFAULT_SUSPECTS end
        if obj.armedShare == nil then obj.armedShare = DEFAULT_SHARE end
    end
    return obj
end

local function ArmedCount(obj)
    local o = Defaults(U.deepcopy(obj))
    if o.mode == 'scatter' then
        return (tonumber(o.armedShare) or 0) > 0 and math.floor(tonumber(o.suspects) or 0) or 0
    end
    local n = math.floor(tonumber(o.associates.count) or 0)
    if (tonumber(o.responses.fight) or 0) > 0 then n = n + 1 end
    return n
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    local function add(k) if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end end
    if o.mode == 'scatter' then
        add(o.spawns)
        add(o.routes)
    else
        add(o.door)
        add(o.suspect)
        if (tonumber(o.responses.flee) or 0) > 0 then add(o.fleeTo) end
        if (tonumber(o.associates.count) or 0) > 0 then add(o.associates.spawns) end
    end
    return out
end

local function CheckLocation(o, loc, li, strict)
    local start = loc.start and loc.start.coords
    local function spawnOk(list)
        for _, p in ipairs(list) do
            if InNoBuild(p) then return Bad('block.flee_arrest.invalid.points_zone', { location = li }) end
            if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return Bad('block.flee_arrest.invalid.points_start',
                    { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
        return true
    end
    -- markers and route waypoints: never inside a no-build zone (docs/CRIMSON_ARENA.md rule 7), for
    -- every mission (the loader only sees location keys, not points written into the objective)
    local function pathOk(list)
        for _, p in ipairs(list) do
            if InNoBuild(p) then return Bad('block.flee_arrest.invalid.route_zone', { location = li }) end
        end
        return true
    end
    local function need(key)
        return Bad('block.flee_arrest.invalid.points_missing', { key = tostring(key), location = li })
    end
    if o.mode == 'scatter' then
        local pts = PointList(loc, o.spawns)
        if #pts == 0 then return need(o.spawns) end
        -- nothing ever spawns inside the prison walls (or any no-build zone): checked for every mission
        local ok, why = spawnOk(pts)
        if not ok then return false, why end
        local routes = RouteList(loc, o.routes)
        if #routes == 0 then return need(o.routes) end
        for _, r in ipairs(routes) do
            ok, why = pathOk(r)
            if not ok then return false, why end
        end
        return true
    end
    local door = PointList(loc, o.door)
    if #door == 0 then return need(o.door) end
    local sp = PointList(loc, o.suspect)
    if #sp == 0 then return need(o.suspect) end
    if (tonumber(o.responses.flee) or 0) > 0 and #PointList(loc, o.fleeTo) == 0 then return need(o.fleeTo) end
    do
        local ok, why = pathOk(door)
        if ok then ok, why = pathOk(PointList(loc, o.fleeTo)) end
        if not ok then return false, why end
    end
    local count = math.floor(tonumber(o.associates.count) or 0)
    local ap = {}
    if count > 0 then
        ap = PointList(loc, o.associates.spawns)
        if #ap == 0 then return need(o.associates.spawns) end
        if strict and #ap < count then
            return Bad('block.flee_arrest.invalid.points_count', { location = li, min = count, have = #ap })
        end
    end
    -- no-build zones for every mission; the distance from the start only for custom missions
    local ok, why = spawnOk(sp)
    if not ok then return false, why end
    ok, why = spawnOk(ap)
    if not ok then return false, why end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.flee_arrest.invalid.objective') end
    local c = Cfg()
    local hw = Config.Blocks.hostile_waves
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed

    if o.mode ~= 'door' and o.mode ~= 'scatter' then return Bad('block.flee_arrest.invalid.mode') end
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.flee_arrest.invalid.min_seconds') end
    if not InRange(o.presenceRange, c.presenceRange) then
        return Bad('block.flee_arrest.invalid.range',
            { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if not InRange(o.escape.distance, c.escapeDistance) then
        return Bad('block.flee_arrest.invalid.range',
            { field = 'escape.distance', min = c.escapeDistance[1], max = c.escapeDistance[2] })
    end
    if not InRange(o.escape.seconds, c.escapeSeconds) then
        return Bad('block.flee_arrest.invalid.range',
            { field = 'escape.seconds', min = c.escapeSeconds[1], max = c.escapeSeconds[2] })
    end
    local g = o.givesUp
    if g.aim ~= false and not InRange(g.aim, c.aimDistance) then
        return Bad('block.flee_arrest.invalid.range',
            { field = 'givesUp.aim', min = c.aimDistance[1], max = c.aimDistance[2] })
    end
    if type(g.stun) ~= 'boolean' then return Bad('block.flee_arrest.invalid.gives_up') end
    if
        g.close ~= false
        and (
            type(g.close) ~= 'table'
            or not IsNum(g.close.distance)
            or g.close.distance <= 0
            or not IsNum(g.close.seconds)
            or g.close.seconds <= 0
        )
    then
        return Bad('block.flee_arrest.invalid.gives_up')
    end
    -- custom missions: "a participant stays within 3 m for 3 s" is fixed (Config.Blocks closeDistance /
    -- closeSeconds), only on or off
    if strict and g.close ~= false
        and (math.abs(g.close.distance - c.closeDistance) > 1e-6 or math.abs(g.close.seconds - c.closeSeconds) > 1e-6) then
        return Bad('block.flee_arrest.invalid.gives_up_close', { distance = c.closeDistance, seconds = c.closeSeconds })
    end
    local ag = o.armedGivesUp
    if type(ag.stun) ~= 'boolean'
        or (ag.belowHealth ~= false and (not IsNum(ag.belowHealth) or ag.belowHealth <= 0 or ag.belowHealth >= 1)) then
        return Bad('block.flee_arrest.invalid.gives_up')
    end
    if not IsNum(o.fireWithin) or o.fireWithin <= 0 then return Bad('block.flee_arrest.invalid.fire_within') end
    if not IsNum(o.cuff.duration) or o.cuff.duration <= 0 or type(o.cuff.label) ~= 'string' then
        return Bad('block.flee_arrest.invalid.cuff')
    end
    if strict then
        local ok, why = CustomTimed('cuff.duration', o.cuff.duration)
        if ok then ok, why = CustomCuffRange(o.cuff.maxDistance) end
        if not ok then return false, why end
    end
    if not AllAllowed(o.weapons, strict and allowed.weapons or nil) then
        return Bad('block.flee_arrest.invalid.weapons')
    end
    if not AllAllowed(o.models, strict and allowed.peds or nil) then return Bad('block.flee_arrest.invalid.models') end
    if not InRange(o.accuracy, hw.accuracy) or not InRange(o.armour, hw.armour) then
        return Bad('block.flee_arrest.invalid.combat')
    end
    if type(o.aliveBonus.id) ~= 'string' or o.aliveBonus.id == '' then
        return Bad('block.flee_arrest.invalid.alive_bonus')
    end
    -- custom missions: the alive bonus is a standard id (valued by the mission's capped bonuses list),
    -- never a value of its own
    if
        strict
        and (
            o.aliveBonus.points ~= nil
            or o.aliveBonus.pctOfPoints ~= nil
            or not (Config.Bonuses and Config.Bonuses[o.aliveBonus.id])
        )
    then
        return Bad('block.flee_arrest.invalid.alive_bonus_custom', { id = o.aliveBonus.id })
    end
    if o.mode == 'door' then
        local r = o.responses
        for _, k in ipairs({ 'surrender', 'flee', 'fight' }) do
            if not IsNum(r[k]) or r[k] < 0 or r[k] > 1 then return Bad('block.flee_arrest.invalid.responses') end
        end
        if math.abs(r.surrender + r.flee + r.fight - 1) > 0.001 then
            return Bad('block.flee_arrest.invalid.responses')
        end
        if not IsNum(o.knock.duration) or o.knock.duration <= 0 or type(o.knock.label) ~= 'string' then
            return Bad('block.flee_arrest.invalid.knock')
        end
        if strict then
            local ok, why = CustomTimed('knock.duration', o.knock.duration)
            if not ok then return false, why end
        end
        local a = o.associates
        if not IsInt(a.count) or a.count < 0 or a.count > c.suspects[2] then
            return Bad('block.flee_arrest.invalid.range', { field = 'associates.count', min = 0, max = c.suspects[2] })
        end
        if a.count > 0 then
            if not AllAllowed(a.weapons, strict and allowed.weapons or nil) then
                return Bad('block.flee_arrest.invalid.weapons')
            end
            if not InRange(a.accuracy, hw.accuracy) or not InRange(a.armour, hw.armour) then
                return Bad('block.flee_arrest.invalid.combat')
            end
        end
    else
        if not IsInt(o.suspects) or not InRange(o.suspects, c.suspects) then
            return Bad('block.flee_arrest.invalid.range',
                { field = 'suspects', min = c.suspects[1], max = c.suspects[2] })
        end
        if not InRange(o.armedShare, c.armedChance, 0.01) then
            return Bad('block.flee_arrest.invalid.range',
                { field = 'armedShare', min = c.armedChance[1] / 100, max = c.armedChance[2] / 100 })
        end
    end
    local armed = ArmedCount(o)
    if armed > Config.Builder.maxHostiles then
        return Bad('block.flee_arrest.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
    end
    if type(location) == 'table' then
        return CheckLocation(o, location, 1, strict)
    end
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
        st.peds = {}
        st.counts = { suspect = 0, associate = 0, inmate = 0, armedInmates = 0 }
        st.knockStart = {}
        st.knocked = false
    end
    return st
end

local function Int(v) return math.max(0, math.floor((tonumber(v) or 0) + 0.5)) end

local function AssocTarget(ctx)
    return ctx.obj.mode == 'door' and Int(ctx.obj.associates and ctx.obj.associates.count) or 0
end

local function InmateTarget(ctx)
    return ctx.obj.mode == 'scatter' and Int(ctx.obj.suspects) or 0
end

local function Indices(n)
    local t = {}
    for i = 1, n do t[i] = i end
    return t
end

local function Placed(pts, order, i)
    local k = ((i - 1) % #pts) + 1
    local lap = (i - 1) // #pts
    local base = pts[order[k] or k]
    if lap == 0 then return ToVec4(base) end
    local a = lap * 2.39996 + k
    return ToVec4(base, math.cos(a) * REUSE_OFFSET * lap, math.sin(a) * REUSE_OFFSET * lap)
end

local function SetPed(ctx, st, p, state, extra)
    if p.state == state then return end
    p.state = state
    CP.Npc.setState(ctx.run, p.netId, state, extra)
    st.dirty = true
end

local function SurrenderPed(ctx, st, p)
    p.state = 'surrendered'
    p.close, p.far = 0, 0
    p.surrenderedAt = Now()
    CP.Npc.setState(ctx.run, p.netId, 'surrendered')
    local cuff = ctx.obj.cuff
    CP.Npc.enableCuff(ctx.run, p.netId, {
        label = cuff.label or CP.L('block.flee_arrest.cuff'),
        duration = cuff.duration,
        maxDistance = cuff.maxDistance,
    })
    st.dirty = true
end

-- holster: an armed ped whose weapon stays out of sight (not given) until DrawWeapon; it still counts as armed.
local function SpawnOne(ctx, st, role, point, armed, extra, holster)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local opts = {
        model = r:pick(obj.models) or PRISON_MODEL,
        coords = point,
        role = role,
        armed = armed == true,
        cfg = extra or {},
        tag = role .. (st.counts[role] + 1),
    }
    if armed then
        local assoc = role == 'associate' and obj.associates or nil
        opts.weapon = r:pick((assoc and assoc.weapons) or obj.weapons) or Cfg().weapons[1]
        opts.accuracy, opts.armour = ctx.combat((assoc and assoc.accuracy) or obj.accuracy,
            (assoc and assoc.armour) or obj.armour)
    end
    -- Every flee_arrest NPC starts calm (CRIMSONPOLICE_NEUTRAL), armed or not: door-mode NPCs wait
    -- inside until the knock reveals the response, and armed inmates only open fire within
    -- fireWithin. They join CRIMSONPOLICE_HOSTILE (which hates PLAYER) only when the server turns
    -- them 'hostile' (CP.Npc's combat task sets the group; apply reads the state first).
    opts.cfg.group = 'neutral'
    local weapon = opts.weapon
    if holster then opts.weapon = nil end
    local ent, netId = ctx.spawnPed(opts)
    if not netId then return nil end
    local p = { netId = netId, entity = ent, role = role, armed = armed == true, state = 'idle', far = 0, close = 0 }
    if holster then p.weapon = weapon end
    st.peds[tostring(netId)] = p
    st.counts[role] = st.counts[role] + 1
    st.dirty = true
    return p
end

-- ============================================================================
--                                  DOOR MODE
-- ============================================================================

local function RollResponse(ctx)
    local rs = ctx.obj.responses
    local x = RngOf(ctx):next()
    local s, f = tonumber(rs.surrender) or 0, tonumber(rs.flee) or 0
    if x < s then return 'surrender' end
    if x < s + f then return 'flee' end
    return 'fight'
end

local function HasHeading(p)
    if type(p) == 'vector4' then return true end
    return type(p) == 'table' and tonumber(p.w or p[4] or p.heading) ~= nil
end

-- The unit vector pointing out of the door (towards the street). The door's vec4 heading is its facing;
-- it is turned round when the location start (where the officers come from) lies clearly behind it (a
-- door placed while facing the house). A door without a heading faces the start; with no start either,
-- "out" is the side away from where the suspect waited.
local function DoorOutward(ctx, door, fromX, fromY)
    local dx, dy = U.xyz(door)
    local start = ctx.location and ctx.location.start and ctx.location.start.coords
    local tx, ty, tl = 0.0, 0.0, 0.0
    if start then
        local sx, sy = U.xyz(start)
        if sx then
            tx, ty = sx - dx, sy - dy
            tl = math.sqrt(tx * tx + ty * ty)
        end
    end
    if HasHeading(door) then
        local r = math.rad(HeadingOf(door))
        local fx, fy = -math.sin(r), math.cos(r)
        if tl > 1.0 and (fx * tx + fy * ty) / tl < -DOOR_FLIP_DOT then fx, fy = -fx, -fy end
        return fx, fy
    end
    if tl > 1.0 then return tx / tl, ty / tl end
    if fromX then
        local vx, vy = dx - fromX, dy - fromY
        local len = math.sqrt(vx * vx + vy * vy)
        if len > 0.01 then return vx / len, vy / len end
    end
    return nil
end

-- Stand the suspect DOOR_STEP in front of the door, facing out. Where he waited does not matter: inside
-- (the card: "the suspect inside") or on the door step next to the door (the built-in houses have no
-- interior a ped can walk out of, docs/notes/missions_b.md), he always ends up outside, never behind the
-- facade.
local function MoveToDoor(ctx, p)
    local door = PointList(ctx.location, ctx.obj.door)[1]
    if not door or not p.entity or not DoesEntityExist(p.entity) then return end
    local dx, dy, dz = U.xyz(door)
    local sx, sy = U.xyz(GetEntityCoords(p.entity))
    local ox, oy = DoorOutward(ctx, door, sx, sy)
    local h = HeadingOf(door)
    local px, py = dx, dy
    if ox then
        px, py = dx + ox * DOOR_STEP, dy + oy * DOOR_STEP
        h = math.deg(math.atan(-ox, oy)) % 360.0
    end
    SetEntityCoords(p.entity, px + 0.0, py + 0.0, dz + 0.0, false, false, false, false)
    SetEntityHeading(p.entity, h + 0.0)
end

-- The holstered pistol of the fighting door suspect, given in hand now; the bag cfg gets it too, so a
-- new host's CP.Npc.apply draws it. Returns the setState extra (nil when nothing was holstered).
local function DrawWeapon(p)
    local w = p.weapon
    if not w then return nil end
    p.weapon = nil
    if GiveWeaponToPed and p.entity and DoesEntityExist(p.entity) then
        GiveWeaponToPed(p.entity, joaat(w), 250, false, true)
    end
    return { cfg = { weapon = w } }
end

local function ApplyResponse(ctx, st, p)
    if p.role == 'associate' then
        SetPed(ctx, st, p, 'hostile')
    elseif st.response == 'surrender' then
        MoveToDoor(ctx, p)
        SurrenderPed(ctx, st, p)
    elseif st.response == 'flee' then
        SetPed(ctx, st, p, 'fleeing')
    else
        SetPed(ctx, st, p, 'hostile', DrawWeapon(p))
    end
end

local RESPONSE_TEXT = {
    surrender = 'block.flee_arrest.response_surrender',
    flee = 'block.flee_arrest.response_flee',
    fight = 'block.flee_arrest.response_fight',
}

local function Reveal(ctx, st)
    if st.knocked then return end
    st.knocked = true
    for _, p in pairs(st.peds) do
        if p.state == 'idle' then ApplyResponse(ctx, st, p) end
    end
    st.dirty = true
    ctx.hud({ message = { text = CP.L(RESPONSE_TEXT[st.response] or RESPONSE_TEXT.fight), kind = 'warning' } })
end

local function SpawnDoorLoop(ctx, st)
    local obj = ctx.obj
    local ok = true
    if st.counts.suspect < 1 then
        local armed = st.response == 'fight'
        local point = PointList(ctx.location, obj.suspect)[1]
            or (ctx.location and ctx.location.start and ctx.location.start.coords)
        if point and ctx.canSpawn(1, armed) then
            local fleeTo = U.serialize(PointList(ctx.location, obj.fleeTo))
            -- a pistol in hand before the knock would give the secret response away
            local p = SpawnOne(ctx, st, 'suspect', ToVec4(point), armed, { fleePoints = fleeTo }, not st.knocked)
            if p and st.knocked then ApplyResponse(ctx, st, p) end
            ok = p ~= nil
        else
            ok = false
        end
    end
    local want = AssocTarget(ctx)
    if ok and st.counts.associate < want then
        local pts = PointList(ctx.location, obj.associates.spawns)
        if #pts == 0 then pts = PointList(ctx.location, obj.suspect) end
        if #pts == 0 then
            ok = false
        else
            if not st.assocOrder or #st.assocOrder ~= #pts then st.assocOrder = RngOf(ctx):shuffle(Indices(#pts)) end
            while st.counts.associate < want do
                if not ctx.canSpawn(1, true) then ok = false break end
                local p = SpawnOne(ctx, st, 'associate', Placed(pts, st.assocOrder, st.counts.associate + 1), true, {})
                if not p then ok = false break end
                if st.knocked then ApplyResponse(ctx, st, p) end
                if st.stopped then ok = false break end
            end
        end
    end
    return ok
end

-- The spawning flag (re-entry while ctx.spawnPed yields) is always cleared, even when a spawn
-- throws, so one failed spawn can never stop the objective from spawning again on the next tick.
local function GuardedSpawn(ctx, st, loop)
    st.spawning = true
    local okCall, ok = pcall(loop, ctx, st)
    st.spawning = false
    if not okCall then
        CP.err(BLOCK, 'spawning for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(ok))
        return false
    end
    return ok
end

local function SpawnDoor(ctx, st)
    if st.spawning or st.stopped then return false end
    if not st.response then st.response = RollResponse(ctx) end
    return GuardedSpawn(ctx, st, SpawnDoorLoop)
end

-- ============================================================================
--                                 SCATTER MODE
-- ============================================================================

local SpawnScatterLoop

local function SpawnScatter(ctx, st)
    if st.spawning or st.stopped then return false end
    local obj = ctx.obj
    local want = InmateTarget(ctx)
    if st.counts.inmate >= want then return true end
    local pts = OutsideZones(PointList(ctx.location, obj.spawns))
    if #pts == 0 then
        if not st.failed then
            CP.warn(BLOCK, 'no spawn point outside the no-build zones at %s for run %s', tostring(obj.spawns),
                tostring(ctx.run and ctx.run.id))
            st.failed = true
            ctx.fail('block.flee_arrest.fail_setup')
        end
        return false
    end
    local routes = RouteList(ctx.location, obj.routes)
    if not st.pointOrder or #st.pointOrder ~= #pts then st.pointOrder = RngOf(ctx):shuffle(Indices(#pts)) end
    if #routes > 0 and (not st.routeOrder or #st.routeOrder ~= #routes) then
        st.routeOrder = RngOf(ctx):shuffle(Indices(#routes))
    end
    return GuardedSpawn(ctx, st, function()
        return SpawnScatterLoop(ctx, st, want, pts, routes)
    end)
end

SpawnScatterLoop = function(ctx, st, want, pts, routes)
    local share = tonumber(ctx.obj.armedShare) or 0
    local ok = true
    while st.counts.inmate < want do
        if st.nextArmed == nil then
            -- exactly round(want × share) armed overall: the chance is the share still to place
            local armedLeft = math.max(0, U.round(want * share) - st.counts.armedInmates)
            local slotsLeft = want - st.counts.inmate
            st.nextArmed = armedLeft > 0 and (armedLeft >= slotsLeft or RngOf(ctx):next() < armedLeft / slotsLeft)
        end
        local armed = st.nextArmed
        if not ctx.canSpawn(1, armed) then ok = false break end
        local i = st.counts.inmate + 1
        local routeIdx = st.routeOrder and st.routeOrder[((i - 1) % #st.routeOrder) + 1] or nil
        local p = SpawnOne(ctx, st, 'inmate', Placed(pts, st.pointOrder, i), armed, {
            route = routeIdx,
            outfit = 'prison',
            fleePoints = routeIdx and U.serialize(routes[routeIdx]) or nil,
        })
        if not p then ok = false break end
        st.nextArmed = nil
        p.route = routeIdx
        if armed then st.counts.armedInmates = st.counts.armedInmates + 1 end
        SetPed(ctx, st, p, 'fleeing')
        if st.stopped then ok = false break end
    end
    return ok
end

-- ============================================================================
--                       NEUTRALISING, CUFFS, COMPLETION
-- ============================================================================

local function MarkCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    p.far, p.close = 0, 0
    st.dirty = true
    if p.role ~= 'associate' then
        local ab = ctx.obj.aliveBonus
        -- aliveBonus.points is a mission-file value: only built-in files may value their own id with it
        -- (custom missions value a Config.Bonuses id through their capped bonuses list instead)
        ctx.award(ab.id, { count = 1, points = TrustedFile(ctx) and ab.points or nil })
    end
end

local function BagCuffed(p)
    return CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function Totals(ctx, st)
    local total, done = 0, 0
    for _, p in pairs(st.peds) do
        total = total + 1
        if Neutralised(p) then done = done + 1 end
    end
    local want = st.mode == 'scatter' and InmateTarget(ctx) or (1 + AssocTarget(ctx))
    return done, math.max(total, want)
end

local function AllSpawned(ctx, st)
    if st.mode == 'scatter' then return st.counts.inmate >= InmateTarget(ctx) end
    return st.counts.suspect >= 1 and st.counts.associate >= AssocTarget(ctx)
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.stopped then return end
    if st.mode == 'door' and not st.knocked then return end
    if not AllSpawned(ctx, st) then return end
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then return end
    end
    local done, total = Totals(ctx, st)
    local arrested = 0
    for _, p in pairs(st.peds) do
        if p.state == 'cuffed' then arrested = arrested + 1 end
    end
    if ctx.complete({ neutralised = done, total = total, arrested = arrested }) ~= false then
        st.completed = true
    end
end

local function Fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

-- Every tick: escapes, the close rule, armed give-ups and fire range, vanished NPCs, missed cuffs.
local function Watch(ctx, st, dt)
    local obj = ctx.obj
    local list = Party(ctx)
    local esc, gu, ag = obj.escape, obj.givesUp, obj.armedGivesUp
    local worst = 0
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            if p.state == 'surrendered' and BagCuffed(p) then
                MarkCuffed(ctx, st, p)
            elseif not p.entity or not DoesEntityExist(p.entity) then
                p.state = 'dead'
                st.dirty = true
            else
                local near = NearestOf(list, GetEntityCoords(p.entity))
                local moving = p.state == 'fleeing' or p.state == 'hostile'
                if p.role ~= 'associate' and moving and #list > 0 and near > esc.distance then
                    p.far = (p.far or 0) + dt
                    if p.far >= esc.seconds then
                        Fail(ctx, st, 'block.flee_arrest.fail_escaped')
                        return
                    end
                    if p.far > worst then worst = p.far end
                else
                    p.far = 0
                end
                if not p.armed and p.state == 'fleeing' and type(gu.close) == 'table' then
                    if near <= gu.close.distance then
                        p.close = (p.close or 0) + dt
                        if p.close >= gu.close.seconds then SurrenderPed(ctx, st, p) end
                    else
                        p.close = 0
                    end
                end
                if p.armed and moving then
                    local ratio = ag.belowHealth and HealthRatio(p) or nil
                    if ratio and ratio > 0 and ratio < ag.belowHealth then
                        SurrenderPed(ctx, st, p)
                    elseif p.role == 'inmate' then
                        if p.state == 'fleeing' and near <= obj.fireWithin then
                            SetPed(ctx, st, p, 'hostile')
                        elseif p.state == 'hostile' and near > obj.fireWithin * FIRE_RELEASE then
                            SetPed(ctx, st, p, 'fleeing')
                        end
                    end
                end
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
--                            HUD AND CLIENT UPDATES
-- ============================================================================

local function UpdateHud(ctx, st)
    local done, total = Totals(ctx, st)
    local text
    if st.escaping then
        text = CP.L('block.flee_arrest.escaping', { seconds = st.escaping })
    elseif st.mode == 'door' and not st.knocked then
        text = CP.L('block.flee_arrest.detail_knock')
    elseif st.mode == 'door' then
        text = CP.L('block.flee_arrest.detail_door', { done = done, total = total })
    else
        text = CP.L('block.flee_arrest.detail_scatter', { done = done, total = total })
    end
    if text ~= st.hudText or st.hudDone ~= done or st.hudTotal ~= total then
        st.hudText, st.hudDone, st.hudTotal = text, done, total
        ctx.hud({ detail = text, value = done, max = total })
    end
end

local function Flush(ctx, st)
    if st.dirty then
        st.dirty = false
        local list = {}
        for _, p in pairs(st.peds) do
            list[#list + 1] = { netId = p.netId, role = p.role, state = p.state, armed = p.armed, route = p.route }
        end
        table.sort(list, function(a, b) return a.netId < b.netId end)
        ctx.send({
            peds = list,
            mode = st.mode,
            knocked = st.knocked == true,
            escaping = st.escaping,
            response = st.knocked and st.response or nil,
        })
    end
    UpdateHud(ctx, st)
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function KnockEvent(ctx, st, src, t)
    if st.mode ~= 'door' then return false, 'wrong_mode' end
    if st.knocked then return false, 'duplicate' end
    local door = PointList(ctx.location, ctx.obj.door)[1]
    local sc = ctx.coords(src)
    if not door or not sc or U.dist(sc, door) > KNOCK_RANGE + REACH_SLACK then return false, 'too_far' end
    local sk = tostring(src)
    if t == 'knock_start' then
        st.knockStart[sk] = Now()
        return true
    end
    local started = st.knockStart[sk]
    if not started then return false, 'not_started' end
    if Now() - started < (tonumber(ctx.obj.knock.duration) or 0) * TIMED_SHARE then return false, 'too_fast' end
    Reveal(ctx, st)
    return true
end

local function Moving(p) return p.state == 'fleeing' or p.state == 'hostile' end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local t = ev.type
    local ok, why
    if t == 'knock_start' or t == 'knock' then
        ok, why = KnockEvent(ctx, st, src, t)
    else
        local netId = tonumber(ev.netId)
        local p = netId and st.peds[tostring(netId)] or nil
        local known = t == 'aim' or t == 'stunned' or t == 'low_health' or t == 'cuffed' or t == 'shot'
            or t == 'damaged'
        if not p then return false, known and 'unknown_entity' or 'unknown_event' end
        if t == 'aim' then
            local gu = ctx.obj.givesUp
            if p.armed then return false, 'armed' end
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'fleeing' then return false, 'wrong_state' end
            if not gu.aim then return false, 'disabled' end
            local pc, sc = PedCoords(p), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > gu.aim + REACH_SLACK then return false, 'too_far' end
            if not HoldsWeapon(src) then return false, 'no_weapon' end
            SurrenderPed(ctx, st, p)
            ok = true
        elseif t == 'stunned' then
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not Moving(p) then return false, 'wrong_state' end
            local allowed
            if p.armed then allowed = ctx.obj.armedGivesUp.stun == true else allowed = ctx.obj.givesUp.stun == true end
            if not allowed then return false, 'disabled' end
            local pc, sc = PedCoords(p), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > STUN_REPORT_RANGE then return false, 'too_far' end
            if NearestOf(Party(ctx), pc) > STUN_RANGE then return false, 'too_far' end
            SurrenderPed(ctx, st, p)
            ok = true
        elseif t == 'low_health' then
            if not p.armed then return false, 'unarmed' end
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not Moving(p) then return false, 'wrong_state' end
            local below = ctx.obj.armedGivesUp.belowHealth
            if not below then return false, 'disabled' end
            local ratio = HealthRatio(p)
            if not ratio or ratio <= 0 or ratio >= below then return false, 'health_ok' end
            SurrenderPed(ctx, st, p)
            ok = true
        elseif t == 'cuffed' then
            if p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'surrendered' then return false, 'wrong_state' end
            if not BagCuffed(p) then return false, 'not_cuffed' end
            local pc, sc = PedCoords(p), ctx.coords(src)
            if not pc or not sc
                or U.dist(pc, sc) > (tonumber(ctx.obj.cuff.maxDistance) or CUFF_RANGE) + REACH_SLACK then
                return false, 'too_far'
            end
            MarkCuffed(ctx, st, p)
            ok = true
        elseif t == 'shot' then
            ok = true
        elseif t == 'damaged' then
            local below = ctx.obj.armedGivesUp.belowHealth
            if p.armed and Moving(p) and below then
                local ratio = HealthRatio(p)
                if ratio and ratio > 0 and ratio < below then SurrenderPed(ctx, st, p) end
            end
            ok = true
        else
            return false, 'unknown_event'
        end
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
    return ok, why
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Spawn(ctx, st)
    if st.mode == 'scatter' then return SpawnScatter(ctx, st) end
    return SpawnDoor(ctx, st)
end

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
        if st.failed then return end
        Watch(ctx, st, tonumber(dt) or 1)
        if st.failed then return end
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local p = st.peds[tostring(netId)]
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
    if st.mode == 'door' and not st.knocked then Reveal(ctx, st) end
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
            local c = PedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local ref = (st.mode == 'door' and PointList(ctx.location, ctx.obj.door)[1])
            or (ctx.location and ctx.location.start and ctx.location.start.coords)
        best = ref and U.dist(coords, ref) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    if st.mode == 'scatter' then
        local done, total = Totals(ctx, st)
        return {
            {
                label = CP.L('block.flee_arrest.check_scatter'),
                done = total > 0 and done >= total and AllSpawned(ctx, st),
                value = done,
                max = total,
            },
        }
    end
    local suspectDone, assocDone = false, 0
    for _, p in pairs(st.peds) do
        if p.role == 'suspect' and Neutralised(p) then suspectDone = true end
        if p.role == 'associate' and Neutralised(p) then assocDone = assocDone + 1 end
    end
    local list = {
        {
            label = CP.L('block.flee_arrest.check_knock'),
            done = st.knocked == true,
            value = st.knocked and 1 or 0,
            max = 1,
        },
        {
            label = CP.L('block.flee_arrest.check_suspect'),
            done = suspectDone,
            value = suspectDone and 1 or 0,
            max = 1,
        },
    }
    local want = math.max(AssocTarget(ctx), st.counts.associate)
    if want > 0 then
        list[#list + 1] = {
            label = CP.L('block.flee_arrest.check_associates'),
            done = assocDone >= want,
            value = assocDone,
            max = want,
        }
    end
    return list
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for _, p in pairs(st.peds) do ctx.delete(p.netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    Start(ctx)
end

local function Rescale(ctx)
    local st = StateOf(ctx)
    st.dirty = true
    Flush(ctx, st)
end

local function Stop(ctx)
    local st = StateOf(ctx)
    st.stopped = true
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
    onParticipantLeft = function(ctx, src)
        local st = StateOf(ctx)
        st.knockStart[tostring(src)] = nil
        Flush(ctx, st)
    end,
    rescale = Rescale,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = Stop,
})
