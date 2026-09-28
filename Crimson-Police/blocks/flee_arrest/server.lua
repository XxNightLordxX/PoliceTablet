--[[ blocks/flee_arrest/server.lua · objective block "flee_arrest" (server half)

  What it does
    Suspects who must be taken into custody ("Cuff suspect", CP.Npc.enableCuff) after they give up.
    Two modes:
    - door (Warrant Service): the suspect waits inside at `suspect`, armed associates at
      `associates.spawns` (count scales). Participants use ox_target "Knock and announce" at the
      `door` (knock.duration progress; 'knock_start' then 'knock', both checked with server-side
      distance and the elapsed time). The suspect's response is rolled with the objective rng when
      the objective starts and revealed at the knock (or when a door-mode NPC dies first):
      surrender (placed just outside the door, hands up), flee (runs out the back along `fleeTo`)
      or fight (spawned with a pistol from `weapons`). Associates always fight. Done when the
      suspect is cuffed (or was killed while armed and fighting) and every associate is
      neutralised (killed, or gave up and cuffed).
    - scatter (Prison Break): `suspects` inmates (scale) in prison clothes spawn at `spawns`
      (already outside the fence; spawn points inside a Config.Builder.noBuildZones zone are never
      used) and flee along the `routes`; round(suspects × armedShare) of them carry a pistol and turn
      to fight while a participant is within fireWithin. Done when every inmate is neutralised.
    Unarmed suspects give up when a participant aims at them within givesUp.aim metres (client
    'aim' report, server distance check), when stunned (client 'stunned' report, a participant must
    be within STUN_RANGE) or when a participant stays within givesUp.close.distance for
    givesUp.close.seconds (server-side distance sampling every tick). Armed suspects give up only
    when stunned (armedGivesUp.stun) or below armedGivesUp.belowHealth health (server polls health).
    A suspect or inmate more than escape.distance from every participant for escape.seconds
    escapes: the run fails. Killing an unarmed, surrendered or cuffed suspect/inmate (a participant
    kill) fails the run for everyone.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.flee_arrest)
    minSeconds [30] · presenceRange [presenceRange[3] = 250] · label
    mode          'door' | 'scatter'                                    ['door']
    door mode     door ['door'] vec4 key · suspect ['suspect'] vec4 key · fleeTo ['fleeTo'] list key
                  knock { label [locale block.flee_arrest.knock], duration [3000] ms }
                  responses { surrender [0.5], flee [0.3], fight [0.2] } (Config responses / 100)
                  associates { count [1], spawns ['associates'], weapons [= weapons],
                    accuracy [hostile_waves.accuracy[3] = 25], armour [hostile_waves.armour[3] = 0] }
    scatter mode  spawns ['spawns'] list key · routes ['routes'] list of lists of vec3 (or { points })
                  suspects [5] · armedShare [0.4]
    common        models [door: Config.Blocks.hostile_waves.peds; scatter: { 's_m_y_prisoner_01' }]
                  weapons [Config.Blocks.flee_arrest.weapons] · accuracy / armour (armed suspects)
                    [hostile_waves defaults, + tier via ctx.combat] · fireWithin [15.0]
                  escape { distance [escapeDistance[3] = 400], seconds [escapeSeconds[3] = 20] }
                  givesUp { aim [aimDistance[3] = 10.0] | false, stun [true],
                    close { distance [closeDistance = 3.0], seconds [closeSeconds = 3] } | false }
                    (the builder's list form { 'aim', 'stun', 'close' } is accepted)
                  armedGivesUp { stun [true], belowHealth [0.5] | false }
                  cuff { label [locale block.flee_arrest.cuff], duration [5000], maxDistance }
                  aliveBonus { id ['suspect_alive'], points (hint for ids outside Config.Bonuses), each }

  Evidence accepted (onEvent)
    { type = 'knock_start' } / { type = 'knock' }  door mode, within KNOCK_RANGE + slack of the door;
                                     'knock' at least TIMED_SHARE × knock.duration after 'knock_start'
    { type = 'aim', netId }          an unarmed fleeing suspect aimed at within givesUp.aim (+ slack)
    { type = 'stunned', netId }      IsPedBeingStunned seen by a client; a participant within STUN_RANGE
    { type = 'low_health', netId }   an armed suspect: re-checked with server-side health
    { type = 'cuffed', netId }       CP.Npc (CP.Runs.dispatch) after a validated cuff (cp bag says cuffed)
    { type = 'shot', netId, src }    CP.Npc: a surrendered/cuffed suspect was shot (penalty recorded there)

  Bonus / penalty ids recorded (shared)
    aliveBonus.id ['suspect_alive'; Prison Break: 'inmate_alive'] ctx.award count 1 for every suspect or
    inmate cuffed alive (associates earn nothing)
  Fail reason keys: block.flee_arrest.fail_escaped · block.flee_arrest.fail_setup (no usable spawn point
    outside the no-build zones) · run.fail_killed_unarmed

  ctx.state
    block, mode, rng, response, knocked, knockStart = { [src] = ms }, peds = { [tostring(netId)] =
    { netId, entity, role = 'suspect'|'associate'|'inmate', armed, state, route, far, close,
    surrenderedAt } }, counts = { suspect, associate, inmate, armedInmates }, pointOrder,
    assocOrder, routeOrder, nextArmed, escaping, dirty, hudText, completed, failed, stopped
]]

local BLOCK = 'flee_arrest'
local U = CP.U

local REACH_SLACK        = 2.0     -- metres of position lag allowed around interaction ranges
local KNOCK_RANGE        = 2.5     -- ox_target distance of "Knock and announce"
local CUFF_RANGE         = 3.0     -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local STUN_RANGE         = 30.0    -- a stun needs a participant this close to the suspect
local TIMED_SHARE        = 0.8     -- a timed interaction must last at least this share of its duration
local FIRE_RELEASE       = 1.5     -- an armed inmate goes back to fleeing beyond fireWithin × this
local DOOR_STEP          = 1.0     -- metres outside the door where a surrendering suspect stands
local REUSE_OFFSET       = 1.25
local SURRENDER_GRACE_MS = 3000    -- a kill this soon after an armed suspect gave up is a shot in flight
local DEFAULT_KNOCK_MS   = 3000
local DEFAULT_CUFF_MS    = 5000
local DEFAULT_SUSPECTS   = 5
local DEFAULT_SHARE      = 0.4
local DEFAULT_FIRE       = 15.0
local DEFAULT_BELOW      = 0.5
local PRISON_MODEL       = 's_m_y_prisoner_01'

local function cfg() return Config.Blocks[BLOCK] end
local function now() return GetGameTimer() end

-- ── Small helpers ───────────────────────────────────────────────────────────
local function isNum(v) return type(v) == 'number' and v == v end
local function isInt(v) return isNum(v) and math.floor(v) == v end
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

local function headingOf(p)
    if type(p) == 'vector4' then return p.w + 0.0 end
    if type(p) == 'table' then return (tonumber(p.w or p[4] or p.heading) or 0.0) + 0.0 end
    return 0.0
end

local function toVec4(p, dx, dy)
    local x, y, z = U.xyz(p)
    return vector4(x + (dx or 0.0), y + (dy or 0.0), z + 0.0, headingOf(p))
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

-- routes: a list of routes (each a list of vec3 or { points = {...} }); a bare list of points is one route.
local function routeList(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' then return {} end
    if type(v.points) == 'table' or isVec(v[1]) then
        local one = pointList(nil, v)
        return #one > 0 and { one } or {}
    end
    local out = {}
    for i = 1, #v do
        local r = pointList(nil, v[i])
        if #r > 0 then out[#out + 1] = r end
    end
    return out
end

local function inNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
end

local function outsideZones(points)
    return U.filter(points, function(p) return not inNoBuild(p) end)
end

local function allAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if allowed and not U.contains(allowed, v) then return false end
    end
    return true
end

local function isParticipant(ctx, src)
    src = tonumber(src)
    if not src then return false end
    if ctx.run and type(ctx.run.participants) == 'table' and ctx.run.participants[src] then return true end
    for _, s in ipairs(ctx.participants() or {}) do
        if s == src then return true end
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

local function pedCoords(p)
    if p.entity and DoesEntityExist(p.entity) then return GetEntityCoords(p.entity) end
    return nil
end

local function healthRatio(p)
    if not p.entity or not DoesEntityExist(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local serverMax = GetEntityMaxHealth and tonumber(GetEntityMaxHealth(p.entity)) or 0
    local max = math.max(tonumber(p.maxHealth) or 200, serverMax or 0)
    if max > 100 then return (hp - 100) / (max - 100) end
    return hp / math.max(max, 1)
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

local function neutralised(p)
    return p.state == 'dead' or p.state == 'cuffed'
end

-- ── Defaults and validation ─────────────────────────────────────────────────
local function normaliseGivesUp(g, c)
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

local function defaults(obj)
    local c = cfg()
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
    obj.givesUp = normaliseGivesUp(obj.givesUp, c)
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

local function armedCount(obj)
    local o = defaults(U.deepcopy(obj))
    if o.mode == 'scatter' then
        return (tonumber(o.armedShare) or 0) > 0 and math.floor(tonumber(o.suspects) or 0) or 0
    end
    local n = math.floor(tonumber(o.associates.count) or 0)
    if (tonumber(o.responses.fight) or 0) > 0 then n = n + 1 end
    return n
end

local function requiredPoints(obj)
    local o = defaults(U.deepcopy(obj))
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

local function checkLocation(o, loc, li, strict)
    local start = loc.start and loc.start.coords
    local function spawnOk(list)
        for _, p in ipairs(list) do
            if inNoBuild(p) then return bad('block.flee_arrest.invalid.points_zone', { location = li }) end
            if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return bad('block.flee_arrest.invalid.points_start', { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
        return true
    end
    local function need(key)
        return bad('block.flee_arrest.invalid.points_missing', { key = tostring(key), location = li })
    end
    if o.mode == 'scatter' then
        local pts = pointList(loc, o.spawns)
        if #pts == 0 then return need(o.spawns) end
        -- nothing ever spawns inside the prison walls (or any no-build zone): checked for every mission
        local ok, why = spawnOk(pts)
        if not ok then return false, why end
        if #routeList(loc, o.routes) == 0 then return need(o.routes) end
        return true
    end
    if #pointList(loc, o.door) == 0 then return need(o.door) end
    local sp = pointList(loc, o.suspect)
    if #sp == 0 then return need(o.suspect) end
    if (tonumber(o.responses.flee) or 0) > 0 and #pointList(loc, o.fleeTo) == 0 then return need(o.fleeTo) end
    local count = math.floor(tonumber(o.associates.count) or 0)
    local ap = {}
    if count > 0 then
        ap = pointList(loc, o.associates.spawns)
        if #ap == 0 then return need(o.associates.spawns) end
        if strict and #ap < count then
            return bad('block.flee_arrest.invalid.points_count', { location = li, min = count, have = #ap })
        end
    end
    if strict then
        local ok, why = spawnOk(sp)
        if not ok then return false, why end
        ok, why = spawnOk(ap)
        if not ok then return false, why end
    end
    return true
end

local function validate(obj, mission, location)
    if type(obj) ~= 'table' then return bad('block.flee_arrest.invalid.objective') end
    local c = cfg()
    local hw = Config.Blocks.hostile_waves
    local o = defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed

    if o.mode ~= 'door' and o.mode ~= 'scatter' then return bad('block.flee_arrest.invalid.mode') end
    if not isNum(o.minSeconds) or o.minSeconds < 0 then return bad('block.flee_arrest.invalid.min_seconds') end
    if not inRange(o.presenceRange, c.presenceRange) then
        return bad('block.flee_arrest.invalid.range', { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if not inRange(o.escape.distance, c.escapeDistance) then
        return bad('block.flee_arrest.invalid.range', { field = 'escape.distance', min = c.escapeDistance[1], max = c.escapeDistance[2] })
    end
    if not inRange(o.escape.seconds, c.escapeSeconds) then
        return bad('block.flee_arrest.invalid.range', { field = 'escape.seconds', min = c.escapeSeconds[1], max = c.escapeSeconds[2] })
    end
    local g = o.givesUp
    if g.aim ~= false and not inRange(g.aim, c.aimDistance) then
        return bad('block.flee_arrest.invalid.range', { field = 'givesUp.aim', min = c.aimDistance[1], max = c.aimDistance[2] })
    end
    if type(g.stun) ~= 'boolean' then return bad('block.flee_arrest.invalid.gives_up') end
    if g.close ~= false and (type(g.close) ~= 'table' or not isNum(g.close.distance) or g.close.distance <= 0
        or not isNum(g.close.seconds) or g.close.seconds <= 0) then
        return bad('block.flee_arrest.invalid.gives_up')
    end
    local ag = o.armedGivesUp
    if type(ag.stun) ~= 'boolean' or (ag.belowHealth ~= false and (not isNum(ag.belowHealth) or ag.belowHealth <= 0 or ag.belowHealth >= 1)) then
        return bad('block.flee_arrest.invalid.gives_up')
    end
    if not isNum(o.fireWithin) or o.fireWithin <= 0 then return bad('block.flee_arrest.invalid.fire_within') end
    if not isNum(o.cuff.duration) or o.cuff.duration <= 0 or type(o.cuff.label) ~= 'string' then
        return bad('block.flee_arrest.invalid.cuff')
    end
    if not allAllowed(o.weapons, strict and allowed.weapons or nil) then return bad('block.flee_arrest.invalid.weapons') end
    if not allAllowed(o.models, strict and allowed.peds or nil) then return bad('block.flee_arrest.invalid.models') end
    if not inRange(o.accuracy, hw.accuracy) or not inRange(o.armour, hw.armour) then
        return bad('block.flee_arrest.invalid.combat')
    end
    if type(o.aliveBonus.id) ~= 'string' or o.aliveBonus.id == '' then return bad('block.flee_arrest.invalid.alive_bonus') end
    if o.mode == 'door' then
        local r = o.responses
        for _, k in ipairs({ 'surrender', 'flee', 'fight' }) do
            if not isNum(r[k]) or r[k] < 0 or r[k] > 1 then return bad('block.flee_arrest.invalid.responses') end
        end
        if math.abs(r.surrender + r.flee + r.fight - 1) > 0.001 then return bad('block.flee_arrest.invalid.responses') end
        if not isNum(o.knock.duration) or o.knock.duration <= 0 or type(o.knock.label) ~= 'string' then
            return bad('block.flee_arrest.invalid.knock')
        end
        local a = o.associates
        if not isInt(a.count) or a.count < 0 or a.count > c.suspects[2] then
            return bad('block.flee_arrest.invalid.range', { field = 'associates.count', min = 0, max = c.suspects[2] })
        end
        if a.count > 0 then
            if not allAllowed(a.weapons, strict and allowed.weapons or nil) then return bad('block.flee_arrest.invalid.weapons') end
            if not inRange(a.accuracy, hw.accuracy) or not inRange(a.armour, hw.armour) then
                return bad('block.flee_arrest.invalid.combat')
            end
        end
    else
        if not isInt(o.suspects) or not inRange(o.suspects, c.suspects) then
            return bad('block.flee_arrest.invalid.range', { field = 'suspects', min = c.suspects[1], max = c.suspects[2] })
        end
        if not inRange(o.armedShare, c.armedChance, 0.01) then
            return bad('block.flee_arrest.invalid.range', { field = 'armedShare', min = c.armedChance[1] / 100, max = c.armedChance[2] / 100 })
        end
    end
    local armed = armedCount(o)
    if armed > Config.Builder.maxHostiles then
        return bad('block.flee_arrest.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
    end
    if type(location) == 'table' then
        return checkLocation(o, location, 1, strict)
    end
    if type(mission) == 'table' and type(mission.locations) == 'table' then
        for li, loc in ipairs(mission.locations) do
            local ok, why = checkLocation(o, loc, li, strict)
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
        st.peds = {}
        st.counts = { suspect = 0, associate = 0, inmate = 0, armedInmates = 0 }
        st.knockStart = {}
        st.knocked = false
    end
    return st
end

local function int(v) return math.max(0, math.floor((tonumber(v) or 0) + 0.5)) end

local function assocTarget(ctx)
    return ctx.obj.mode == 'door' and int(ctx.obj.associates and ctx.obj.associates.count) or 0
end

local function inmateTarget(ctx)
    return ctx.obj.mode == 'scatter' and int(ctx.obj.suspects) or 0
end

local function indices(n)
    local t = {}
    for i = 1, n do t[i] = i end
    return t
end

local function placed(pts, order, i)
    local k = ((i - 1) % #pts) + 1
    local lap = (i - 1) // #pts
    local base = pts[order[k] or k]
    if lap == 0 then return toVec4(base) end
    local a = lap * 2.39996 + k
    return toVec4(base, math.cos(a) * REUSE_OFFSET * lap, math.sin(a) * REUSE_OFFSET * lap)
end

local function setPed(ctx, st, p, state)
    if p.state == state then return end
    p.state = state
    CP.Npc.setState(ctx.run, p.netId, state)
    st.dirty = true
end

local function surrenderPed(ctx, st, p)
    p.state = 'surrendered'
    p.close, p.far = 0, 0
    p.surrenderedAt = now()
    CP.Npc.setState(ctx.run, p.netId, 'surrendered')
    local cuff = ctx.obj.cuff
    CP.Npc.enableCuff(ctx.run, p.netId, {
        label = cuff.label or CP.L('block.flee_arrest.cuff'),
        duration = cuff.duration, maxDistance = cuff.maxDistance,
    })
    st.dirty = true
end

local function spawnOne(ctx, st, role, point, armed, extra)
    local obj = ctx.obj
    local r = rngOf(ctx)
    local opts = {
        model = r:pick(obj.models) or PRISON_MODEL, coords = point, role = role, armed = armed == true,
        cfg = extra or {}, tag = role .. (st.counts[role] + 1),
    }
    if armed then
        local assoc = role == 'associate' and obj.associates or nil
        opts.weapon = r:pick((assoc and assoc.weapons) or obj.weapons) or cfg().weapons[1]
        opts.accuracy, opts.armour = ctx.combat((assoc and assoc.accuracy) or obj.accuracy, (assoc and assoc.armour) or obj.armour)
    end
    opts.cfg.group = armed and 'hostile' or 'neutral'
    local ent, netId = ctx.spawnPed(opts)
    if not netId then return nil end
    local p = { netId = netId, entity = ent, role = role, armed = armed == true, state = 'idle', far = 0, close = 0 }
    st.peds[tostring(netId)] = p
    st.counts[role] = st.counts[role] + 1
    st.dirty = true
    return p
end

-- ── Door mode ───────────────────────────────────────────────────────────────
local function rollResponse(ctx)
    local rs = ctx.obj.responses
    local x = rngOf(ctx):next()
    local s, f = tonumber(rs.surrender) or 0, tonumber(rs.flee) or 0
    if x < s then return 'surrender' end
    if x < s + f then return 'flee' end
    return 'fight'
end

-- Stand the suspect just outside the door (on the far side from where he waited), facing out.
local function moveToDoor(ctx, p)
    local door = pointList(ctx.location, ctx.obj.door)[1]
    if not door or not p.entity or not DoesEntityExist(p.entity) then return end
    local dx, dy, dz = U.xyz(door)
    local sx, sy = U.xyz(GetEntityCoords(p.entity))
    local vx, vy = dx - sx, dy - sy
    local len = math.sqrt(vx * vx + vy * vy)
    local h = headingOf(door)
    local ox, oy = 0.0, 0.0
    if len > 0.01 then
        ox, oy = vx / len * DOOR_STEP, vy / len * DOOR_STEP
        h = math.deg(math.atan(-vx, vy)) % 360.0
    end
    SetEntityCoords(p.entity, dx + ox, dy + oy, dz + 0.0, false, false, false, false)
    SetEntityHeading(p.entity, h + 0.0)
end

local function applyResponse(ctx, st, p)
    if p.role == 'associate' then
        setPed(ctx, st, p, 'hostile')
    elseif st.response == 'surrender' then
        moveToDoor(ctx, p)
        surrenderPed(ctx, st, p)
    elseif st.response == 'flee' then
        setPed(ctx, st, p, 'fleeing')
    else
        setPed(ctx, st, p, 'hostile')
    end
end

local RESPONSE_TEXT = {
    surrender = 'block.flee_arrest.response_surrender',
    flee = 'block.flee_arrest.response_flee',
    fight = 'block.flee_arrest.response_fight',
}

local function reveal(ctx, st)
    if st.knocked then return end
    st.knocked = true
    for _, p in pairs(st.peds) do
        if p.state == 'idle' then applyResponse(ctx, st, p) end
    end
    st.dirty = true
    ctx.hud({ message = { text = CP.L(RESPONSE_TEXT[st.response] or RESPONSE_TEXT.fight), kind = 'warning' } })
end

local function spawnDoor(ctx, st)
    if st.spawning or st.stopped then return false end
    local obj = ctx.obj
    if not st.response then st.response = rollResponse(ctx) end
    st.spawning = true
    local ok = true
    if st.counts.suspect < 1 then
        local armed = st.response == 'fight'
        local point = pointList(ctx.location, obj.suspect)[1] or (ctx.location and ctx.location.start and ctx.location.start.coords)
        if point and ctx.canSpawn(1, armed) then
            local fleeTo = U.serialize(pointList(ctx.location, obj.fleeTo))
            local p = spawnOne(ctx, st, 'suspect', toVec4(point), armed, { fleePoints = fleeTo })
            if p and st.knocked then applyResponse(ctx, st, p) end
            ok = p ~= nil
        else
            ok = false
        end
    end
    local want = assocTarget(ctx)
    if ok and st.counts.associate < want then
        local pts = pointList(ctx.location, obj.associates.spawns)
        if #pts == 0 then pts = pointList(ctx.location, obj.suspect) end
        if #pts == 0 then
            ok = false
        else
            if not st.assocOrder or #st.assocOrder ~= #pts then st.assocOrder = rngOf(ctx):shuffle(indices(#pts)) end
            while st.counts.associate < want do
                if not ctx.canSpawn(1, true) then ok = false break end
                local p = spawnOne(ctx, st, 'associate', placed(pts, st.assocOrder, st.counts.associate + 1), true, {})
                if not p then ok = false break end
                if st.knocked then applyResponse(ctx, st, p) end
                if st.stopped then ok = false break end
            end
        end
    end
    st.spawning = false
    return ok
end

-- ── Scatter mode ────────────────────────────────────────────────────────────
local function spawnScatter(ctx, st)
    if st.spawning or st.stopped then return false end
    local obj = ctx.obj
    local want = inmateTarget(ctx)
    if st.counts.inmate >= want then return true end
    local pts = outsideZones(pointList(ctx.location, obj.spawns))
    if #pts == 0 then
        if not st.failed then
            CP.warn(BLOCK, 'no spawn point outside the no-build zones at %s for run %s', tostring(obj.spawns), tostring(ctx.run and ctx.run.id))
            st.failed = true
            ctx.fail('block.flee_arrest.fail_setup')
        end
        return false
    end
    local routes = routeList(ctx.location, obj.routes)
    if not st.pointOrder or #st.pointOrder ~= #pts then st.pointOrder = rngOf(ctx):shuffle(indices(#pts)) end
    if #routes > 0 and (not st.routeOrder or #st.routeOrder ~= #routes) then st.routeOrder = rngOf(ctx):shuffle(indices(#routes)) end
    local share = tonumber(obj.armedShare) or 0
    st.spawning = true
    local ok = true
    while st.counts.inmate < want do
        if st.nextArmed == nil then
            -- exactly round(want × share) armed overall: the chance is the share still to place
            local armedLeft = math.max(0, U.round(want * share) - st.counts.armedInmates)
            local slotsLeft = want - st.counts.inmate
            st.nextArmed = armedLeft > 0 and (armedLeft >= slotsLeft or rngOf(ctx):next() < armedLeft / slotsLeft)
        end
        local armed = st.nextArmed
        if not ctx.canSpawn(1, armed) then ok = false break end
        local i = st.counts.inmate + 1
        local routeIdx = st.routeOrder and st.routeOrder[((i - 1) % #st.routeOrder) + 1] or nil
        local p = spawnOne(ctx, st, 'inmate', placed(pts, st.pointOrder, i), armed, {
            route = routeIdx, outfit = 'prison', fleePoints = routeIdx and U.serialize(routes[routeIdx]) or nil,
        })
        if not p then ok = false break end
        st.nextArmed = nil
        p.route = routeIdx
        if armed then st.counts.armedInmates = st.counts.armedInmates + 1 end
        setPed(ctx, st, p, 'fleeing')
        if st.stopped then ok = false break end
    end
    st.spawning = false
    return ok
end

-- ── Neutralising, cuffs, completion ─────────────────────────────────────────
local function markCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    p.far, p.close = 0, 0
    st.dirty = true
    if p.role ~= 'associate' then
        local ab = ctx.obj.aliveBonus
        ctx.award(ab.id, { count = 1, points = ab.points })
    end
end

local function bagCuffed(p)
    return CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function totals(ctx, st)
    local total, done = 0, 0
    for _, p in pairs(st.peds) do
        total = total + 1
        if neutralised(p) then done = done + 1 end
    end
    local want = st.mode == 'scatter' and inmateTarget(ctx) or (1 + assocTarget(ctx))
    return done, math.max(total, want)
end

local function allSpawned(ctx, st)
    if st.mode == 'scatter' then return st.counts.inmate >= inmateTarget(ctx) end
    return st.counts.suspect >= 1 and st.counts.associate >= assocTarget(ctx)
end

local function tryComplete(ctx, st)
    if st.completed or st.failed or st.stopped then return end
    if st.mode == 'door' and not st.knocked then return end
    if not allSpawned(ctx, st) then return end
    for _, p in pairs(st.peds) do
        if not neutralised(p) then return end
    end
    local done, total = totals(ctx, st)
    local arrested = 0
    for _, p in pairs(st.peds) do
        if p.state == 'cuffed' then arrested = arrested + 1 end
    end
    if ctx.complete({ neutralised = done, total = total, arrested = arrested }) ~= false then
        st.completed = true
    end
end

local function fail(ctx, st, key)
    if st.failed then return end
    st.failed = true
    ctx.fail(key)
end

-- Every tick: escapes, the close rule, armed give-ups and fire range, vanished NPCs, missed cuffs.
local function watch(ctx, st, dt)
    local obj = ctx.obj
    local list = party(ctx)
    local esc, gu, ag = obj.escape, obj.givesUp, obj.armedGivesUp
    local worst = 0
    for _, p in pairs(st.peds) do
        if not neutralised(p) then
            if p.state == 'surrendered' and bagCuffed(p) then
                markCuffed(ctx, st, p)
            elseif not p.entity or not DoesEntityExist(p.entity) then
                p.state = 'dead'
                st.dirty = true
            else
                local near = nearestOf(list, GetEntityCoords(p.entity))
                local moving = p.state == 'fleeing' or p.state == 'hostile'
                if p.role ~= 'associate' and moving and #list > 0 and near > esc.distance then
                    p.far = (p.far or 0) + dt
                    if p.far >= esc.seconds then
                        fail(ctx, st, 'block.flee_arrest.fail_escaped')
                        return
                    end
                    if p.far > worst then worst = p.far end
                else
                    p.far = 0
                end
                if not p.armed and p.state == 'fleeing' and type(gu.close) == 'table' then
                    if near <= gu.close.distance then
                        p.close = (p.close or 0) + dt
                        if p.close >= gu.close.seconds then surrenderPed(ctx, st, p) end
                    else
                        p.close = 0
                    end
                end
                if p.armed and moving then
                    local ratio = ag.belowHealth and healthRatio(p) or nil
                    if ratio and ratio > 0 and ratio < ag.belowHealth then
                        surrenderPed(ctx, st, p)
                    elseif p.role == 'inmate' then
                        if p.state == 'fleeing' and near <= obj.fireWithin then
                            setPed(ctx, st, p, 'hostile')
                        elseif p.state == 'hostile' and near > obj.fireWithin * FIRE_RELEASE then
                            setPed(ctx, st, p, 'fleeing')
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

-- ── HUD and client updates ──────────────────────────────────────────────────
local function updateHud(ctx, st)
    local done, total = totals(ctx, st)
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

local function flush(ctx, st)
    if st.dirty then
        st.dirty = false
        local list = {}
        for _, p in pairs(st.peds) do
            list[#list + 1] = { netId = p.netId, role = p.role, state = p.state, armed = p.armed, route = p.route }
        end
        table.sort(list, function(a, b) return a.netId < b.netId end)
        ctx.send({
            peds = list, mode = st.mode, knocked = st.knocked == true, escaping = st.escaping,
            response = st.knocked and st.response or nil,
        })
    end
    updateHud(ctx, st)
end

-- ── Evidence ────────────────────────────────────────────────────────────────
local function knockEvent(ctx, st, src, t)
    if st.mode ~= 'door' then return false, 'wrong_mode' end
    if st.knocked then return false, 'duplicate' end
    local door = pointList(ctx.location, ctx.obj.door)[1]
    local sc = ctx.coords(src)
    if not door or not sc or U.dist(sc, door) > KNOCK_RANGE + REACH_SLACK then return false, 'too_far' end
    local sk = tostring(src)
    if t == 'knock_start' then
        st.knockStart[sk] = now()
        return true
    end
    local started = st.knockStart[sk]
    if not started then return false, 'not_started' end
    if now() - started < (tonumber(ctx.obj.knock.duration) or 0) * TIMED_SHARE then return false, 'too_fast' end
    reveal(ctx, st)
    return true
end

local function moving(p) return p.state == 'fleeing' or p.state == 'hostile' end

local function onEvent(ctx, src, ev)
    local st = stateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local t = ev.type
    local ok, why
    if t == 'knock_start' or t == 'knock' then
        ok, why = knockEvent(ctx, st, src, t)
    else
        local netId = tonumber(ev.netId)
        local p = netId and st.peds[tostring(netId)] or nil
        if not p then return false, (t == 'aim' or t == 'stunned' or t == 'low_health' or t == 'cuffed' or t == 'shot') and 'unknown_entity' or 'unknown_event' end
        if t == 'aim' then
            local gu = ctx.obj.givesUp
            if p.armed then return false, 'armed' end
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'fleeing' then return false, 'wrong_state' end
            if not gu.aim then return false, 'disabled' end
            local pc, sc = pedCoords(p), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > gu.aim + REACH_SLACK then return false, 'too_far' end
            if not holdsWeapon(src) then return false, 'no_weapon' end
            surrenderPed(ctx, st, p)
            ok = true
        elseif t == 'stunned' then
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not moving(p) then return false, 'wrong_state' end
            local allowed
            if p.armed then allowed = ctx.obj.armedGivesUp.stun == true else allowed = ctx.obj.givesUp.stun == true end
            if not allowed then return false, 'disabled' end
            if nearestOf(party(ctx), pedCoords(p)) > STUN_RANGE then return false, 'too_far' end
            surrenderPed(ctx, st, p)
            ok = true
        elseif t == 'low_health' then
            if not p.armed then return false, 'unarmed' end
            if p.state == 'surrendered' or p.state == 'cuffed' then return false, 'duplicate' end
            if not moving(p) then return false, 'wrong_state' end
            local below = ctx.obj.armedGivesUp.belowHealth
            if not below then return false, 'disabled' end
            local ratio = healthRatio(p)
            if not ratio or ratio <= 0 or ratio >= below then return false, 'health_ok' end
            surrenderPed(ctx, st, p)
            ok = true
        elseif t == 'cuffed' then
            if p.state == 'cuffed' then return false, 'duplicate' end
            if p.state ~= 'surrendered' then return false, 'wrong_state' end
            if not bagCuffed(p) then return false, 'not_cuffed' end
            local pc, sc = pedCoords(p), ctx.coords(src)
            if not pc or not sc or U.dist(pc, sc) > (tonumber(ctx.obj.cuff.maxDistance) or CUFF_RANGE) + REACH_SLACK then
                return false, 'too_far'
            end
            markCuffed(ctx, st, p)
            ok = true
        elseif t == 'shot' then
            ok = true
        else
            return false, 'unknown_event'
        end
    end
    tryComplete(ctx, st)
    flush(ctx, st)
    return ok, why
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function spawn(ctx, st)
    if st.mode == 'scatter' then return spawnScatter(ctx, st) end
    return spawnDoor(ctx, st)
end

local function start(ctx)
    local st = stateOf(ctx)
    st.stopped = nil
    spawn(ctx, st)
    st.dirty = true
    flush(ctx, st)
end

local function tick(ctx, dt)
    local st = stateOf(ctx)
    if st.stopped or st.failed then return end
    if not st.completed then
        spawn(ctx, st)
        if st.failed then return end
        watch(ctx, st, tonumber(dt) or 1)
        if st.failed then return end
    end
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function onEntityDead(ctx, netId, killerSrc)
    local st = stateOf(ctx)
    local p = st.peds[tostring(netId)]
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
    if st.mode == 'door' and not st.knocked then reveal(ctx, st) end
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
            local c = pedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local ref = (st.mode == 'door' and pointList(ctx.location, ctx.obj.door)[1])
            or (ctx.location and ctx.location.start and ctx.location.start.coords)
        best = ref and U.dist(coords, ref) or 0
    end
    return best
end

local function checklist(ctx)
    local st = stateOf(ctx)
    if st.mode == 'scatter' then
        local done, total = totals(ctx, st)
        return { { label = CP.L('block.flee_arrest.check_scatter'), done = total > 0 and done >= total and allSpawned(ctx, st), value = done, max = total } }
    end
    local suspectDone, assocDone = false, 0
    for _, p in pairs(st.peds) do
        if p.role == 'suspect' and neutralised(p) then suspectDone = true end
        if p.role == 'associate' and neutralised(p) then assocDone = assocDone + 1 end
    end
    local list = {
        { label = CP.L('block.flee_arrest.check_knock'), done = st.knocked == true, value = st.knocked and 1 or 0, max = 1 },
        { label = CP.L('block.flee_arrest.check_suspect'), done = suspectDone, value = suspectDone and 1 or 0, max = 1 },
    }
    local want = math.max(assocTarget(ctx), st.counts.associate)
    if want > 0 then
        list[#list + 1] = { label = CP.L('block.flee_arrest.check_associates'), done = assocDone >= want, value = assocDone, max = want }
    end
    return list
end

local function restart(ctx)
    local st = stateOf(ctx)
    for _, p in pairs(st.peds) do ctx.delete(p.netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    start(ctx)
end

local function rescale(ctx)
    local st = stateOf(ctx)
    st.dirty = true
    flush(ctx, st)
end

local function stop(ctx)
    local st = stateOf(ctx)
    st.stopped = true
end

CP.Blocks.register(BLOCK, {
    defaults = defaults,
    validate = validate,
    armedCount = armedCount,
    requiredPoints = requiredPoints,
    prepare = function(ctx) stateOf(ctx) end,
    start = start,
    tick = tick,
    onEvent = onEvent,
    onEntityDead = onEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = stateOf(ctx)
        st.knockStart[tostring(src)] = nil
        flush(ctx, st)
    end,
    rescale = rescale,
    onTimeout = function() return nil end,
    presence = presence,
    checklist = checklist,
    restart = restart,
    stop = stop,
})
