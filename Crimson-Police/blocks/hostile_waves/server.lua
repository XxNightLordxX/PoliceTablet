--[[ blocks/hostile_waves/server.lua · objective block "hostile_waves" (server half)

  What it does
    Spawns armed hostiles in waves at the location's spawn points (networked, OneSync, through
    ctx.spawnPed) and completes when every hostile, and the optional boss, is neutralised: killed, or
    surrendered and cuffed ("Cuff suspect", CP.Npc.enableCuff). The next wave spawns when
    nextWave.aliveAtMost or fewer hostiles of the current wave are not yet neutralised, or
    nextWave.afterSeconds after the wave began. The boss (if any) arrives after the last wave by the
    same rule; it never scales. A hostile under surrender.belowHealth health gets exactly one
    surrender roll (CP.Npc.rollSurrender with surrender.chance) when the host reports it and the
    server confirms the health. Spawn points are picked with the objective rng: distinct points,
    free ones (no living hostile on them) first, reused (with a small offset) only when a wave is
    larger than the point list. Spawning respects the run caps (ctx.canSpawn: a wave that does not fit
    waits and is re-checked every tick, counts are never cut) and rescale (only the NPCs still missing
    for the new ctx.obj counts are spawned). The client half blocks NPC traffic within blockTraffic
    metres of the start while the objective runs.
    Used by Gang Shootout (3 waves 7/7/6), Hostage Rescue (1 wave of 4 inside) and Weekly Boss:
    Kingpin (4 waves 8/8/7/7 then the Kingpin).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.hostile_waves)
    minSeconds [60] · presenceRange [presenceRange[3] = 150] · label
    spawns        location key: list of vec4                               ['spawns']
    waves         base hostiles per wave (scaled by the engine)             [{ 7, 7, 6 }]
    nextWave      { aliveAtMost [nextWaveAlive[3] = 2], afterSeconds [nextWaveAfter[3] = 90] }
    weapons       weapon names, one picked per hostile                      [Config.Blocks.hostile_waves.weapons]
    peds          ped models, one picked per hostile                        [Config.Blocks.hostile_waves.peds]
    accuracy      [accuracy[3] = 25] · armour [armour[3] = 0]   (+ tier and Armored Hostiles via ctx.combat)
    health        [health[3] = 200]
    behaviour     'hold' | 'balanced' | 'push'                              [behaviour.default = 'balanced']
    surrender     { belowHealth [0.25], chance [surrender[3] / 100 = 0.30] }  (false = never)
    boss          false [boss.default] or { model [first of peds], label [locale block.hostile_waves.boss_label],
                  health [health[2] = 400], armour [armour[2] = 100], weapon ['WEAPON_ASSAULTRIFLE'],
                  accuracy [accuracy], behaviour [behaviour], spawn (location key; nil = a spawn point),
                  surrender [= surrender], aliveBonus { id ['kingpin_alive'], points [50] } }
                  The boss does not scale: its accuracy and armour are used as written.
    cuff          optional { label, duration, maxDistance } passed to CP.Npc.enableCuff
    blockTraffic  metres around location.start.coords (client half)     [blockTraffic[3] = 120.0]

  Evidence accepted (onEvent)
    { type = 'low_health', netId }   host client: a hostile looks under belowHealth. The server re-checks
                                     GetEntityHealth against the configured / GetEntityMaxHealth max
                                     (health above the 100-point death threshold), then rolls once.
    { type = 'cuffed', netId }       CP.Npc (via CP.Runs.dispatch) after a validated "Cuff suspect"; the
                                     cp bag must say cuffed. A cuff the event missed is picked up by tick.
    { type = 'shot', netId, src }    CP.Npc: a participant shot a surrendered/cuffed hostile
                                     (shot_surrendered is recorded by CP.Npc); accepted, nothing else.

  Bonus / penalty ids recorded (shared)
    hostile_arrested   ctx.award, count 1 for every hostile cuffed
    kingpin_alive      ctx.award (boss.aliveBonus.id, points hint boss.aliveBonus.points) when the boss is cuffed
  Fail reason keys
    run.fail_killed_unarmed  a participant killed a surrendered or cuffed hostile (a kill within
                             SURRENDER_GRACE_MS of the surrender is a shot already in flight: not a fail)

  ctx.state
    block, rng, peds = { [tostring(netId)] = { netId, entity, role = 'hostile'|'boss', wave, state,
    rolled, maxHealth, surrenderedAt } }, waves = { [w] = { spawned, elapsed, points } }, wave,
    boss = { netId } | nil, arrested, dirty, hudText, completed, failed, stopped
]]

local BLOCK = 'hostile_waves'
local U = CP.U

local REACH_SLACK        = 2.0    -- metres of position lag allowed around interaction ranges
local CUFF_RANGE         = 3.0    -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local SPAWNS_PER_TICK    = 8      -- big waves are spread over a few ticks (never fewer in total)
local OCCUPIED_RADIUS    = 3.0    -- a spawn point this close to a living hostile counts as in use
local REUSE_OFFSET       = 1.25   -- metres between peds that share a reused spawn point
local SURRENDER_GRACE_MS = 3000   -- a kill this soon after a surrender is a shot already in flight
local DEFAULT_WAVES      = { 7, 7, 6 }
local DEFAULT_BELOW      = 0.25
local BOSS_WEAPON        = 'WEAPON_ASSAULTRIFLE'
local BOSS_BONUS         = { id = 'kingpin_alive', points = 50 }

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

-- A location key (or inline value) as a list of points: vec, list of vecs, { points = {...} },
-- or a list of { coords = vec } entries.
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

local function startCoords(ctx)
    local s = ctx.location and ctx.location.start
    return s and s.coords
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

-- Health as a share of the part above GTA's 100-point death threshold (nil when unknown or dead).
local function healthRatio(p)
    if not p.entity or not DoesEntityExist(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local serverMax = GetEntityMaxHealth and tonumber(GetEntityMaxHealth(p.entity)) or 0
    local max = math.max(tonumber(p.maxHealth) or 200, serverMax or 0)
    if max > 100 then return (hp - 100) / (max - 100) end
    return hp / math.max(max, 1)
end

local function neutralised(p)
    return p.state == 'dead' or p.state == 'cuffed'
end

-- ── Defaults and validation ─────────────────────────────────────────────────
local function defaults(obj)
    local c = cfg()
    if obj.minSeconds == nil then obj.minSeconds = 60 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.spawns == nil then obj.spawns = 'spawns' end
    if obj.waves == nil then obj.waves = U.copy(DEFAULT_WAVES) end
    if type(obj.nextWave) ~= 'table' then obj.nextWave = {} end
    if obj.nextWave.aliveAtMost == nil then obj.nextWave.aliveAtMost = c.nextWaveAlive[3] end
    if obj.nextWave.afterSeconds == nil then obj.nextWave.afterSeconds = c.nextWaveAfter[3] end
    if obj.weapons == nil then obj.weapons = U.copy(c.weapons) end
    if obj.peds == nil then obj.peds = U.copy(c.peds) end
    if obj.accuracy == nil then obj.accuracy = c.accuracy[3] end
    if obj.armour == nil then obj.armour = c.armour[3] end
    if obj.health == nil then obj.health = c.health[3] end
    if obj.behaviour == nil then obj.behaviour = c.behaviour.default end
    if obj.surrender == false then obj.surrender = { belowHealth = DEFAULT_BELOW, chance = 0 } end
    if type(obj.surrender) ~= 'table' then obj.surrender = {} end
    if obj.surrender.belowHealth == nil then obj.surrender.belowHealth = DEFAULT_BELOW end
    if obj.surrender.chance == nil then obj.surrender.chance = c.surrender[3] / 100 end
    if obj.boss == nil or obj.boss == true then
        obj.boss = obj.boss == true and {} or c.boss.default
    end
    if type(obj.boss) == 'table' then
        local b = obj.boss
        if b.model == nil then b.model = (type(obj.peds) == 'table' and obj.peds[1]) or c.peds[1] end
        if b.label == nil then b.label = CP.L('block.hostile_waves.boss_label') end
        if b.health == nil then b.health = c.health[2] end
        if b.armour == nil then b.armour = c.armour[2] end
        if b.weapon == nil then b.weapon = BOSS_WEAPON end
        if b.accuracy == nil then b.accuracy = obj.accuracy end
        if b.behaviour == nil then b.behaviour = obj.behaviour end
        if b.surrender == false then b.surrender = { belowHealth = obj.surrender.belowHealth, chance = 0 } end
        if type(b.surrender) ~= 'table' then b.surrender = {} end
        if b.surrender.belowHealth == nil then b.surrender.belowHealth = obj.surrender.belowHealth end
        if b.surrender.chance == nil then b.surrender.chance = obj.surrender.chance end
        if type(b.aliveBonus) ~= 'table' then b.aliveBonus = U.copy(BOSS_BONUS) end
        if b.aliveBonus.id == nil then b.aliveBonus.id = BOSS_BONUS.id end
    end
    if obj.blockTraffic == nil then obj.blockTraffic = c.blockTraffic[3] + 0.0 end
    return obj
end

local function maxWave(o)
    local m = 0
    for _, n in ipairs(o.waves or {}) do
        if isNum(n) and n > m then m = n end
    end
    return m
end

local function armedCount(obj)
    local o = defaults(U.deepcopy(obj))
    local n = 0
    for _, w in ipairs(o.waves or {}) do n = n + (tonumber(w) or 0) end
    if type(o.boss) == 'table' then n = n + 1 end
    return math.floor(n)
end

local function requiredPoints(obj)
    local o = defaults(U.deepcopy(obj))
    local out = {}
    if type(o.spawns) == 'string' then out[#out + 1] = o.spawns end
    if type(o.boss) == 'table' and type(o.boss.spawn) == 'string' and o.boss.spawn ~= o.spawns then
        out[#out + 1] = o.boss.spawn
    end
    return out
end

local function checkLocation(o, loc, li, strict)
    local c = cfg()
    local pts = pointList(loc, o.spawns)
    if #pts == 0 then
        return bad('block.hostile_waves.invalid.spawns_missing', { key = tostring(o.spawns), location = li })
    end
    if strict then
        local need = math.ceil(c.spawnPointsPerHostile * maxWave(o) - 1e-9)
        if #pts < need then
            return bad('block.hostile_waves.invalid.spawns_count', { location = li, min = need, have = #pts })
        end
        local start = loc.start and loc.start.coords
        for _, p in ipairs(pts) do
            if start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return bad('block.hostile_waves.invalid.spawns_start', { location = li, min = Config.Builder.minSpawnFromStart })
            end
            if inNoBuild(p) then
                return bad('block.hostile_waves.invalid.spawns_zone', { location = li })
            end
        end
    end
    if type(o.boss) == 'table' and o.boss.spawn ~= nil and #pointList(loc, o.boss.spawn) == 0 then
        return bad('block.hostile_waves.invalid.spawns_missing', { key = tostring(o.boss.spawn), location = li })
    end
    return true
end

-- Built-in files are trusted for model/weapon lists and placement guardrails (they follow the
-- mission cards); custom and draft missions get every Mission Builder guardrail.
local function validate(obj, mission, location)
    if type(obj) ~= 'table' then return bad('block.hostile_waves.invalid.objective') end
    local c = cfg()
    local o = defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed

    if not isNum(o.minSeconds) or o.minSeconds < 0 then return bad('block.hostile_waves.invalid.min_seconds') end
    if not inRange(o.presenceRange, c.presenceRange) then
        return bad('block.hostile_waves.invalid.range', { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if type(o.waves) ~= 'table' or #o.waves < c.waves[1] or #o.waves > c.waves[2] then
        return bad('block.hostile_waves.invalid.range', { field = 'waves', min = c.waves[1], max = c.waves[2] })
    end
    for _, n in ipairs(o.waves) do
        if not isInt(n) or not inRange(n, c.perWave) then
            return bad('block.hostile_waves.invalid.range', { field = 'perWave', min = c.perWave[1], max = c.perWave[2] })
        end
    end
    if not inRange(o.nextWave.aliveAtMost, c.nextWaveAlive) then
        return bad('block.hostile_waves.invalid.range', { field = 'nextWave.aliveAtMost', min = c.nextWaveAlive[1], max = c.nextWaveAlive[2] })
    end
    if not inRange(o.nextWave.afterSeconds, c.nextWaveAfter) then
        return bad('block.hostile_waves.invalid.range', { field = 'nextWave.afterSeconds', min = c.nextWaveAfter[1], max = c.nextWaveAfter[2] })
    end
    if not allAllowed(o.weapons, strict and allowed.weapons or nil) then return bad('block.hostile_waves.invalid.weapons') end
    if not allAllowed(o.peds, strict and allowed.peds or nil) then return bad('block.hostile_waves.invalid.peds') end
    if not inRange(o.accuracy, c.accuracy) then
        return bad('block.hostile_waves.invalid.range', { field = 'accuracy', min = c.accuracy[1], max = c.accuracy[2] })
    end
    if not inRange(o.armour, c.armour) then
        return bad('block.hostile_waves.invalid.range', { field = 'armour', min = c.armour[1], max = c.armour[2] })
    end
    if not inRange(o.health, c.health) then
        return bad('block.hostile_waves.invalid.range', { field = 'health', min = c.health[1], max = c.health[2] })
    end
    if not U.contains(c.behaviour.options, o.behaviour) then return bad('block.hostile_waves.invalid.behaviour') end
    local s = o.surrender
    if not isNum(s.belowHealth) or s.belowHealth <= 0 or s.belowHealth > 1 or not inRange(s.chance, c.surrender, 0.01) then
        return bad('block.hostile_waves.invalid.surrender')
    end
    if o.boss ~= false then
        local b = o.boss
        if type(b) ~= 'table' then return bad('block.hostile_waves.invalid.boss') end
        if not inRange(b.health, c.health) or not inRange(b.armour, c.armour) or not inRange(b.accuracy, c.accuracy) then
            return bad('block.hostile_waves.invalid.boss')
        end
        if not allAllowed({ b.weapon }, strict and allowed.weapons or nil) or not allAllowed({ b.model }, strict and allowed.peds or nil) then
            return bad('block.hostile_waves.invalid.boss')
        end
        if not U.contains(c.behaviour.options, b.behaviour) then return bad('block.hostile_waves.invalid.boss') end
        if type(b.surrender) ~= 'table' or not isNum(b.surrender.belowHealth) or b.surrender.belowHealth <= 0
            or b.surrender.belowHealth > 1 or not inRange(b.surrender.chance, c.surrender, 0.01) then
            return bad('block.hostile_waves.invalid.boss')
        end
        if type(b.aliveBonus.id) ~= 'string' or b.aliveBonus.id == '' then return bad('block.hostile_waves.invalid.boss') end
    end
    if not inRange(o.blockTraffic, c.blockTraffic) then
        return bad('block.hostile_waves.invalid.range', { field = 'blockTraffic', min = c.blockTraffic[1], max = c.blockTraffic[2] })
    end
    local armed = armedCount(o)
    if armed > Config.Builder.maxHostiles then
        return bad('block.hostile_waves.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
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
        st.peds = {}
        st.waves = {}
        st.wave = 0
        st.arrested = 0
    end
    return st
end

local function waveCount(ctx)
    return type(ctx.obj.waves) == 'table' and #ctx.obj.waves or 0
end

local function waveTarget(ctx, w)
    local n = tonumber(ctx.obj.waves[w]) or 0
    return math.max(0, math.floor(n + 0.5))
end

-- A wave's size for display and totals: already spawned NPCs stay, so never below what spawned.
local function waveSize(ctx, st, w)
    local ws = st.waves[w]
    return math.max(ws and ws.spawned or 0, waveTarget(ctx, w))
end

local function hasBoss(ctx)
    return type(ctx.obj.boss) == 'table'
end

local function bossPed(st)
    return st.boss and st.peds[tostring(st.boss.netId)] or nil
end

local function aliveInWave(st, w)
    local n = 0
    for _, p in pairs(st.peds) do
        if p.role == 'hostile' and p.wave == w and not neutralised(p) then n = n + 1 end
    end
    return n
end

local function remaining(st)
    local n = 0
    for _, p in pairs(st.peds) do
        if not neutralised(p) then n = n + 1 end
    end
    return n
end

local function totals(ctx, st)
    local total = 0
    for w = 1, waveCount(ctx) do total = total + waveSize(ctx, st, w) end
    local done = 0
    for _, p in pairs(st.peds) do
        if p.role == 'hostile' and neutralised(p) then done = done + 1 end
    end
    return done, total
end

-- Distinct points first, points with no living hostile on them before occupied ones; a wave larger
-- than the list reuses points in the same order with a small ring offset.
local function pickPoints(ctx, st, n)
    local all = pointList(ctx.location, ctx.obj.spawns)
    if #all == 0 then
        local s = startCoords(ctx)
        if s then all = { s } end
        CP.warn(BLOCK, 'no spawn points at %s for run %s; using the start point', tostring(ctx.obj.spawns), tostring(ctx.run and ctx.run.id))
    end
    if #all == 0 or n <= 0 then return {} end
    local living = {}
    for _, p in pairs(st.peds) do
        if not neutralised(p) then
            local c = pedCoords(p)
            if c then living[#living + 1] = c end
        end
    end
    local free, used = {}, {}
    for _, p in ipairs(rngOf(ctx):shuffle(all)) do
        local busy = false
        for i = 1, #living do
            if U.dist(p, living[i]) <= OCCUPIED_RADIUS then busy = true break end
        end
        if busy then used[#used + 1] = p else free[#free + 1] = p end
    end
    for _, p in ipairs(used) do free[#free + 1] = p end
    local out = {}
    for i = 1, n do
        local k = ((i - 1) % #free) + 1
        local lap = (i - 1) // #free
        if lap == 0 then
            out[i] = toVec4(free[k])
        else
            local a = lap * 2.39996 + k
            out[i] = toVec4(free[k], math.cos(a) * REUSE_OFFSET * lap, math.sin(a) * REUSE_OFFSET * lap)
        end
    end
    return out
end

local function spawnHostile(ctx, st, w, point)
    local obj = ctx.obj
    local r = rngOf(ctx)
    local c = cfg()
    local model = r:pick(obj.peds) or c.peds[1]
    local weapon = r:pick(obj.weapons) or c.weapons[1]
    local acc, arm = ctx.combat(obj.accuracy, obj.armour)
    local ent, netId = ctx.spawnPed({
        model = model, coords = point, role = 'hostile', armed = true, weapon = weapon,
        accuracy = acc, armour = arm, health = obj.health,
        cfg = { behaviour = obj.behaviour, group = 'hostile', wave = w },
        tag = 'wave' .. w,
    })
    if not netId then return false end
    st.peds[tostring(netId)] = { netId = netId, entity = ent, role = 'hostile', wave = w, state = 'hostile', maxHealth = obj.health }
    CP.Npc.setState(ctx.run, netId, 'hostile')
    st.dirty = true
    return true
end

local function spawnBoss(ctx, st)
    if st.boss then return true end
    if not ctx.canSpawn(1, true) then return false end
    local b = ctx.obj.boss
    local point = pointList(ctx.location, b.spawn)[1]
    point = point and toVec4(point) or pickPoints(ctx, st, 1)[1]
    if not point then return false end
    local ent, netId = ctx.spawnPed({
        model = b.model, coords = point, role = 'boss', armed = true, weapon = b.weapon,
        accuracy = b.accuracy, armour = b.armour, health = b.health,
        cfg = { behaviour = b.behaviour, group = 'hostile', boss = true, label = b.label },
        tag = 'boss',
    })
    if not netId then return false end
    st.peds[tostring(netId)] = { netId = netId, entity = ent, role = 'boss', state = 'hostile', maxHealth = b.health }
    st.boss = { netId = netId }
    CP.Npc.setState(ctx.run, netId, 'hostile')
    st.dirty = true
    return true
end

local function startWave(ctx, st, w)
    st.wave = w
    local ws = st.waves[w] or { spawned = 0, elapsed = 0 }
    st.waves[w] = ws
    ws.points = ws.points or pickPoints(ctx, st, waveTarget(ctx, w))
    st.dirty = true
end

-- Spawns what is still missing of wave w; returns (fully spawned, spawn budget left).
local function spawnWave(ctx, st, w, budget)
    local ws = st.waves[w]
    local target = waveTarget(ctx, w)
    while ws.spawned < target and budget > 0 do
        if not ctx.canSpawn(1, true) then return false, budget end
        local i = ws.spawned + 1
        local point = ws.points[i]
        if not point then
            point = pickPoints(ctx, st, 1)[1]
            ws.points[i] = point
        end
        if not point or not spawnHostile(ctx, st, w, point) then return false, budget end
        ws.spawned = i
        budget = budget - 1
        if st.stopped then return false, 0 end
    end
    return ws.spawned >= target, budget
end

local function advance(ctx, st)
    if st.spawning or st.stopped or st.failed then return end
    local n = waveCount(ctx)
    if n == 0 then return end
    st.spawning = true
    if st.wave == 0 then startWave(ctx, st, 1) end
    local budget = SPAWNS_PER_TICK
    while not st.stopped do
        local w = st.wave
        local full
        full, budget = spawnWave(ctx, st, w, budget)
        if not full then break end
        local nw = ctx.obj.nextWave
        local ready = aliveInWave(st, w) <= (tonumber(nw.aliveAtMost) or 0)
            or st.waves[w].elapsed >= (tonumber(nw.afterSeconds) or math.huge)
        if not ready then break end
        if w < n then
            startWave(ctx, st, w + 1)
            if budget <= 0 then break end
        else
            if hasBoss(ctx) and not st.boss then spawnBoss(ctx, st) end
            break
        end
    end
    st.spawning = false
end

local function allOut(ctx, st)
    local n = waveCount(ctx)
    if st.wave < n then return false end
    for w = 1, n do
        local ws = st.waves[w]
        if not ws or ws.spawned < waveTarget(ctx, w) then return false end
    end
    if hasBoss(ctx) and not st.boss then return false end
    return true
end

-- ── HUD and client updates ──────────────────────────────────────────────────
local function updateHud(ctx, st)
    local done, total = totals(ctx, st)
    local left = total - done
    local b = bossPed(st)
    local text
    if b and not neutralised(b) then
        text = CP.L('block.hostile_waves.detail_boss', { boss = ctx.obj.boss.label, left = left })
    elseif allOut(ctx, st) and remaining(st) == 0 then
        text = CP.L('block.hostile_waves.detail_clear')
    else
        text = CP.L('block.hostile_waves.detail', { wave = math.max(st.wave, 1), waves = waveCount(ctx), left = left })
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
            list[#list + 1] = { netId = p.netId, role = p.role, state = p.state, wave = p.wave }
        end
        table.sort(list, function(a, b) return a.netId < b.netId end)
        ctx.send({ peds = list, wave = st.wave, waves = waveCount(ctx) })
    end
    updateHud(ctx, st)
end

-- ── Surrender, cuffing, completion ──────────────────────────────────────────
local function surrenderCfg(ctx, p)
    if p.role == 'boss' and hasBoss(ctx) then return ctx.obj.boss.surrender end
    return ctx.obj.surrender
end

local function surrender(ctx, st, p)
    p.state = 'surrendered'
    p.surrenderedAt = now()
    CP.Npc.setState(ctx.run, p.netId, 'surrendered')
    local cuff = type(ctx.obj.cuff) == 'table' and ctx.obj.cuff or {}
    CP.Npc.enableCuff(ctx.run, p.netId, {
        label = cuff.label or CP.L('block.hostile_waves.cuff'),
        duration = cuff.duration, maxDistance = cuff.maxDistance,
    })
    st.dirty = true
end

local function rollSurrender(ctx, p, chance)
    if CP.Npc.rollSurrender then return CP.Npc.rollSurrender(ctx.run, p.netId, chance) == true end
    return rngOf(ctx):chance(chance)
end

local function checkLowHealth(ctx, st, p)
    if p.state ~= 'hostile' then return false, 'wrong_state' end
    if p.rolled then return false, 'duplicate' end
    local s = surrenderCfg(ctx, p)
    local ratio = healthRatio(p)
    if not ratio or ratio <= 0 then return false, 'no_health' end
    if ratio >= (tonumber(s.belowHealth) or 0) then return false, 'health_ok' end
    p.rolled = true
    st.dirty = true
    local chance = tonumber(s.chance) or 0
    if chance > 0 and rollSurrender(ctx, p, chance) then surrender(ctx, st, p) end
    return true
end

local function markCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    st.dirty = true
    if p.role == 'boss' then
        local ab = ctx.obj.boss and ctx.obj.boss.aliveBonus or BOSS_BONUS
        ctx.award(ab.id, { count = 1, points = ab.points })
    else
        st.arrested = (st.arrested or 0) + 1
        ctx.award('hostile_arrested', { count = 1 })
    end
end

local function bagCuffed(p)
    return CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function onCuffed(ctx, st, src, p)
    if not p then return false, 'unknown_entity' end
    if p.state == 'cuffed' then return false, 'duplicate' end
    if p.state ~= 'surrendered' then return false, 'wrong_state' end
    if not bagCuffed(p) then return false, 'not_cuffed' end
    local pc, sc = pedCoords(p), ctx.coords(src)
    local reach = ((type(ctx.obj.cuff) == 'table' and ctx.obj.cuff.maxDistance) or CUFF_RANGE) + REACH_SLACK
    if not pc or not sc or U.dist(pc, sc) > reach then return false, 'too_far' end
    markCuffed(ctx, st, p)
    return true
end

local function tryComplete(ctx, st)
    if st.completed or st.failed or st.stopped then return end
    if not allOut(ctx, st) or remaining(st) > 0 then return end
    local done, total = totals(ctx, st)
    if ctx.complete({ neutralised = done, total = total, arrested = st.arrested or 0 }) ~= false then
        st.completed = true
    end
end

-- Entities gone without a death event, and cuffs whose event did not arrive.
local function refresh(ctx, st)
    for _, p in pairs(st.peds) do
        if not neutralised(p) then
            if not p.entity or not DoesEntityExist(p.entity) then
                p.state = 'dead'
                st.dirty = true
            elseif p.state == 'surrendered' and bagCuffed(p) then
                markCuffed(ctx, st, p)
            end
        end
    end
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function start(ctx)
    local st = stateOf(ctx)
    st.stopped = nil
    advance(ctx, st)
    flush(ctx, st)
end

local function tick(ctx, dt)
    local st = stateOf(ctx)
    if st.stopped or st.failed then return end
    if not st.completed then
        local ws = st.waves[st.wave]
        if ws then ws.elapsed = ws.elapsed + (tonumber(dt) or 1) end
        refresh(ctx, st)
        advance(ctx, st)
    end
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function onEvent(ctx, src, ev)
    local st = stateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local netId = tonumber(ev.netId)
    local p = netId and st.peds[tostring(netId)] or nil
    local ok, why
    if ev.type == 'low_health' then
        if not p then return false, 'unknown_entity' end
        ok, why = checkLowHealth(ctx, st, p)
    elseif ev.type == 'cuffed' then
        ok, why = onCuffed(ctx, st, src, p)
    elseif ev.type == 'shot' then
        if not p then return false, 'unknown_entity' end
        ok = true
    else
        return false, 'unknown_event'
    end
    tryComplete(ctx, st)
    flush(ctx, st)
    return ok, why
end

local function onEntityDead(ctx, netId, killerSrc)
    local st = stateOf(ctx)
    local p = st.peds[tostring(netId)]
    if not p or p.state == 'dead' then return end
    local prev = p.state
    p.state = 'dead'
    st.dirty = true
    local protected = prev == 'cuffed'
        or (prev == 'surrendered' and not (p.surrenderedAt and now() - p.surrenderedAt < SURRENDER_GRACE_MS))
    if protected and not st.failed and isParticipant(ctx, killerSrc) then
        st.failed = true
        ctx.fail('run.fail_killed_unarmed')
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
            local c = pedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local s = startCoords(ctx)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function checklist(ctx)
    local st = stateOf(ctx)
    local done, total = totals(ctx, st)
    local list = {
        { label = CP.L('block.hostile_waves.check_hostiles'), done = total > 0 and done >= total and allOut(ctx, st), value = done, max = total },
    }
    if hasBoss(ctx) then
        local b = bossPed(st)
        local bossDone = b ~= nil and neutralised(b)
        list[#list + 1] = { label = CP.L('block.hostile_waves.check_boss', { boss = ctx.obj.boss.label }), done = bossDone, value = bossDone and 1 or 0, max = 1 }
    end
    return list
end

local function restart(ctx)
    local st = stateOf(ctx)
    for _, p in pairs(st.peds) do ctx.delete(p.netId) end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    st = stateOf(ctx)
    st.dirty = true
    advance(ctx, st)
    flush(ctx, st)
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
    onParticipantLeft = function(ctx) flush(ctx, stateOf(ctx)) end,
    rescale = rescale,
    onTimeout = function() return nil end,
    presence = presence,
    checklist = checklist,
    restart = restart,
    stop = stop,
})
