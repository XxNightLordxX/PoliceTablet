-- Objective block "hostile_waves" (server half)

local BLOCK = 'hostile_waves'
local U = CP.U

local REACH_SLACK = 2.0                  -- metres of position lag allowed around interaction ranges
local CUFF_RANGE = 3.0                   -- CP.Npc.enableCuff default maxDistance (ARCHITECTURE §5.11)
local SPAWNS_PER_TICK = 8                -- big waves are spread over a few ticks (never fewer in total)
local OCCUPIED_RADIUS = 3.0              -- a spawn point this close to a living hostile counts as in use
local REUSE_OFFSET = 1.25                -- metres between peds that share a reused spawn point
local SURRENDER_GRACE_MS = 3000          -- a kill this soon after a surrender is a shot already in flight
local DEFAULT_WAVES = { 7, 7, 6 }
local DEFAULT_BELOW = 0.25
local BOSS_WEAPON = 'WEAPON_ASSAULTRIFLE'
local BOSS_BONUS = { id = 'kingpin_alive', points = 50 }
local CUSTOM_TIMED_MS = { 1000, 30000 }  -- custom missions: the cuff progress time (ms)

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

-- The points hint of the boss bonus: a built-in file may value its own id (the Kingpin card); on any other
-- mission only the block's own constant counts (BOSS_BONUS: kingpin_alive +50, capped by the scoring for
-- custom missions), so a mission file can never raise its points.
local function BossBonusPoints(ctx, ab)
    local m = ctx.mission or (ctx.run and ctx.run.mission)
    if type(m) == 'table' and m.source == 'builtin' then return ab.points end
    if ab.id == BOSS_BONUS.id then return BOSS_BONUS.points end
    return nil
end

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

-- A location key (or inline value) as a list of points: vec, list of vecs, { points = {...} },
-- or a list of { coords = vec } entries.
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

local function StartCoords(ctx)
    local s = ctx.location and ctx.location.start
    return s and s.coords
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

-- Health as a share of the part above GTA's 100-point death threshold (nil when unknown or dead).
local function HealthRatio(p)
    if not p.entity or not DoesEntityExist(p.entity) then return nil end
    local hp = tonumber(GetEntityHealth(p.entity)) or 0
    if hp <= 0 then return nil end
    local serverMax = ServerMaxHealth(p.entity)
    local max = math.max(tonumber(p.maxHealth) or 200, serverMax or 0)
    if max > 100 then return (hp - 100) / (max - 100) end
    return hp / math.max(max, 1)
end

local function Neutralised(p)
    return p.state == 'dead' or p.state == 'cuffed'
end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function Defaults(obj)
    local c = Cfg()
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
    if type(obj.spawnSets) == 'table' then
        local ss = obj.spawnSets
        if ss.use == nil then ss.use = c.spawnSetsUsed[3] end
        if ss.intel == nil then ss.intel = true end
    end
    return obj
end

local BEHAVIOURS = { 'hold', 'balanced', 'push' }

-- behaviour: one name, or weights { hold, balanced, push } rolled once per run from the seed.
local function BehaviourOk(b, c)
    if type(b) == 'string' then return U.contains(c.behaviour.options, b) end
    if type(b) ~= 'table' then return false end
    local sum = 0
    for k, w in pairs(b) do
        if not U.contains(BEHAVIOURS, k) or not IsNum(w) or w < 0 then return false end
        sum = sum + w
    end
    return sum > 0
end

local function MaxWave(o)
    local m = 0
    for _, n in ipairs(o.waves or {}) do
        if IsNum(n) and n > m then m = n end
    end
    return m
end

local function ArmedCount(obj)
    local o = Defaults(U.deepcopy(obj))
    local n = 0
    for _, w in ipairs(o.waves or {}) do n = n + (tonumber(w) or 0) end
    if type(o.boss) == 'table' then n = n + 1 end
    return math.floor(n)
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    if type(o.spawnSets) == 'table' and type(o.spawnSets.keys) == 'table' then
        for _, k in ipairs(o.spawnSets.keys) do
            if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end
        end
    elseif type(o.spawns) == 'string' then
        out[#out + 1] = o.spawns
    end
    if type(o.boss) == 'table' and type(o.boss.spawn) == 'string' and o.boss.spawn ~= o.spawns then
        out[#out + 1] = o.boss.spawn
    end
    return out
end

local function SetPoints(o, loc, keys)
    local out = {}
    for _, k in ipairs(keys or {}) do
        for _, p in ipairs(PointList(loc, k)) do out[#out + 1] = p end
    end
    return out
end

local function CheckLocation(o, loc, li, strict)
    local c = Cfg()
    local pts = PointList(loc, o.spawns)
    if type(o.spawnSets) == 'table' then
        for _, k in ipairs(o.spawnSets.keys) do
            if #PointList(loc, k) == 0 then
                return Bad('block.hostile_waves.invalid.spawns_missing', { key = tostring(k), location = li })
            end
        end
        -- every set must hold the largest wave on its own share of the points used per run
        pts = SetPoints(o, loc, o.spawnSets.keys)
    end
    if #pts == 0 then
        return Bad('block.hostile_waves.invalid.spawns_missing', { key = tostring(o.spawns), location = li })
    end
    local start = loc.start and loc.start.coords
    -- no-build zones for every mission (docs/CRIMSON_ARENA.md rule 7: the loader only sees location
    -- keys, not points written into the objective); the distance from the start for custom missions
    local function spawnOk(list)
        for _, p in ipairs(list) do
            if InNoBuild(p) then
                return Bad('block.hostile_waves.invalid.spawns_zone', { location = li })
            end
            if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return Bad('block.hostile_waves.invalid.spawns_start',
                    { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
        return true
    end
    if strict then
        local need = math.ceil(c.spawnPointsPerHostile * MaxWave(o) - 1e-9)
        if #pts < need then
            return Bad('block.hostile_waves.invalid.spawns_count', { location = li, min = need, have = #pts })
        end
    end
    local ok, why = spawnOk(pts)
    if not ok then return false, why end
    if type(o.boss) == 'table' and o.boss.spawn ~= nil then
        local bp = PointList(loc, o.boss.spawn)
        if #bp == 0 then
            return Bad('block.hostile_waves.invalid.spawns_missing', { key = tostring(o.boss.spawn), location = li })
        end
        -- the boss spot is a spawn point too: the same guardrails as the wave spawns
        ok, why = spawnOk(bp)
        if not ok then return false, why end
    end
    return true
end

-- Built-in files are trusted for model/weapon lists, the spawn-point count and the distance from the
-- start (they follow the mission cards); no-build zones, ranges and the armed budget apply to every
-- mission; custom and draft missions get every Mission Builder guardrail.
local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.hostile_waves.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local allowed = Config.Builder.allowed

    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.hostile_waves.invalid.min_seconds') end
    if not InRange(o.presenceRange, c.presenceRange) then
        return Bad('block.hostile_waves.invalid.range',
            { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if type(o.waves) ~= 'table' or #o.waves < c.waves[1] or #o.waves > c.waves[2] then
        return Bad('block.hostile_waves.invalid.range', { field = 'waves', min = c.waves[1], max = c.waves[2] })
    end
    for _, n in ipairs(o.waves) do
        if not IsInt(n) or not InRange(n, c.perWave) then
            return Bad('block.hostile_waves.invalid.range',
                { field = 'perWave', min = c.perWave[1], max = c.perWave[2] })
        end
    end
    if not InRange(o.nextWave.aliveAtMost, c.nextWaveAlive) then
        return Bad('block.hostile_waves.invalid.range',
            { field = 'nextWave.aliveAtMost', min = c.nextWaveAlive[1], max = c.nextWaveAlive[2] })
    end
    if not InRange(o.nextWave.afterSeconds, c.nextWaveAfter) then
        return Bad('block.hostile_waves.invalid.range',
            { field = 'nextWave.afterSeconds', min = c.nextWaveAfter[1], max = c.nextWaveAfter[2] })
    end
    if not AllAllowed(o.weapons, strict and allowed.weapons or nil) then
        return Bad('block.hostile_waves.invalid.weapons')
    end
    if not AllAllowed(o.peds, strict and allowed.peds or nil) then return Bad('block.hostile_waves.invalid.peds') end
    if not InRange(o.accuracy, c.accuracy) then
        return Bad('block.hostile_waves.invalid.range',
            { field = 'accuracy', min = c.accuracy[1], max = c.accuracy[2] })
    end
    if not InRange(o.armour, c.armour) then
        return Bad('block.hostile_waves.invalid.range', { field = 'armour', min = c.armour[1], max = c.armour[2] })
    end
    if not InRange(o.health, c.health) then
        return Bad('block.hostile_waves.invalid.range', { field = 'health', min = c.health[1], max = c.health[2] })
    end
    if not BehaviourOk(o.behaviour, c) then return Bad('block.hostile_waves.invalid.behaviour') end
    if o.spawnSets ~= nil then
        local ss = o.spawnSets
        if type(ss) ~= 'table' or type(ss.keys) ~= 'table' or #ss.keys < 1 or #ss.keys > c.spawnSets[2]
            or not IsInt(ss.use) or not InRange(ss.use, c.spawnSetsUsed) or ss.use > #ss.keys
            or type(ss.intel) ~= 'boolean' then
            return Bad('block.hostile_waves.invalid.spawn_sets')
        end
        for _, k in ipairs(ss.keys) do
            if type(k) ~= 'string' or k == '' then return Bad('block.hostile_waves.invalid.spawn_sets') end
        end
    end
    local s = o.surrender
    if not IsNum(s.belowHealth) or s.belowHealth <= 0 or s.belowHealth > 1
        or not InRange(s.chance, c.surrender, 0.01) then
        return Bad('block.hostile_waves.invalid.surrender')
    end
    if o.boss ~= false then
        local b = o.boss
        if type(b) ~= 'table' then return Bad('block.hostile_waves.invalid.boss') end
        if not InRange(b.health, c.health) or not InRange(b.armour, c.armour)
            or not InRange(b.accuracy, c.accuracy) then
            return Bad('block.hostile_waves.invalid.boss')
        end
        if not AllAllowed({ b.weapon }, strict and allowed.weapons or nil)
            or not AllAllowed({ b.model }, strict and allowed.peds or nil) then
            return Bad('block.hostile_waves.invalid.boss')
        end
        if not BehaviourOk(b.behaviour, c) then return Bad('block.hostile_waves.invalid.boss') end
        if type(b.surrender) ~= 'table' or not IsNum(b.surrender.belowHealth) or b.surrender.belowHealth <= 0
            or b.surrender.belowHealth > 1 or not InRange(b.surrender.chance, c.surrender, 0.01) then
            return Bad('block.hostile_waves.invalid.boss')
        end
        if type(b.aliveBonus.id) ~= 'string' or b.aliveBonus.id == '' then
            return Bad('block.hostile_waves.invalid.boss')
        end
        -- custom missions: the boss bonus is the block's own kingpin_alive (its constant value) or a
        -- standard Config.Bonuses id (valued by the mission's capped bonuses list); never a file value
        if strict then
            local ab = b.aliveBonus
            local own = ab.id == BOSS_BONUS.id and (ab.points == nil or ab.points == BOSS_BONUS.points)
            local std = ab.id ~= BOSS_BONUS.id and ab.points == nil and Config.Bonuses ~= nil
                and Config.Bonuses[ab.id] ~= nil
            if ab.pctOfPoints ~= nil or not (own or std) then
                return Bad('block.hostile_waves.invalid.boss_bonus_custom', { id = ab.id, default = BOSS_BONUS.id })
            end
        end
    end
    -- custom missions: the optional cuff action takes 1-30 s and reaches no further than CP.Npc's range
    if strict and type(o.cuff) == 'table' then
        if o.cuff.duration ~= nil and not InRange(o.cuff.duration, CUSTOM_TIMED_MS) then
            return Bad('block.hostile_waves.invalid.range',
                { field = 'cuff.duration', min = CUSTOM_TIMED_MS[1], max = CUSTOM_TIMED_MS[2] })
        end
        local md = o.cuff.maxDistance
        if md ~= nil and not (IsNum(md) and md > 0 and md <= CUFF_RANGE + 1e-9) then
            return Bad('block.hostile_waves.invalid.range', { field = 'cuff.maxDistance', min = 0, max = CUFF_RANGE })
        end
    end
    if not InRange(o.blockTraffic, c.blockTraffic) then
        return Bad('block.hostile_waves.invalid.range',
            { field = 'blockTraffic', min = c.blockTraffic[1], max = c.blockTraffic[2] })
    end
    local armed = ArmedCount(o)
    if armed > Config.Builder.maxHostiles then
        return Bad('block.hostile_waves.invalid.armed_budget', { max = Config.Builder.maxHostiles, have = armed })
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

-- The run's tactics: behaviour and spawn sets rolled once from the run seed (their own stream, so they are
-- the same whatever else was rolled), and the intel line every participant sees on Active Mission.
local function RollTactics(ctx, st)
    local seed = (tonumber(ctx.run and ctx.run.seed) or 1) * 6151 + (ctx.index or 0) * 92821 + 17
    local r = U.rng(seed)
    r:next()
    local b = ctx.obj.behaviour
    if type(b) == 'table' then
        local total = 0
        for _, k in ipairs(BEHAVIOURS) do total = total + (tonumber(b[k]) or 0) end
        local x = r:next() * total
        st.behaviour = 'balanced'
        for _, k in ipairs(BEHAVIOURS) do
            x = x - (tonumber(b[k]) or 0)
            if (tonumber(b[k]) or 0) > 0 and x < 0 then
                st.behaviour = k
                break
            end
        end
    else
        st.behaviour = b
    end
    local ss = ctx.obj.spawnSets
    if type(ss) == 'table' and type(ss.keys) == 'table' then
        local picked = r:sample(ss.keys, math.min(ss.use or 1, #ss.keys))
        -- in the file's order, so the intel line reads the same way every time
        local order = {}
        for _, k in ipairs(ss.keys) do if U.contains(picked, k) then order[#order + 1] = k end end
        st.sets = order
        if ss.intel ~= false and ctx.run then
            local names = {}
            for _, k in ipairs(order) do
                local key = ('block.hostile_waves.set.%s'):format(k)
                names[#names + 1] = CP.Locale and CP.Locale.has and CP.Locale.has(key) and CP.L(key) or k
            end
            local list = #names > 1
                    and CP.L('block.hostile_waves.intel_and', {
                        first = table.concat(names, ', ', 1, #names - 1),
                        last = names[#names],
                    })
                or names[1]
            ctx.run.shared = ctx.run.shared or {}
            ctx.run.shared.intel = CP.Lt and CP.Lt('block.hostile_waves.intel', { sets = list })
                or CP.L('block.hostile_waves.intel', { sets = list })
        end
    end
end

local function StateOf(ctx)
    Defaults(ctx.obj)
    local st = ctx.state
    if not st.block then
        st.block = BLOCK
        st.peds = {}
        st.waves = {}
        st.wave = 0
        st.arrested = 0
        RollTactics(ctx, st)
    end
    return st
end

local function Behaviour(ctx, st)
    return st.behaviour or (type(ctx.obj.behaviour) == 'string' and ctx.obj.behaviour) or 'balanced'
end

-- Config.NpcDifficulty feel: health and surrender only; never points, cash or counts.
local function Feel()
    if CP.Scaling and CP.Scaling.feel then return CP.Scaling.feel() end
    return { healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 }
end

local function WaveCount(ctx)
    return type(ctx.obj.waves) == 'table' and #ctx.obj.waves or 0
end

local function WaveTarget(ctx, w)
    local n = tonumber(ctx.obj.waves[w]) or 0
    return math.max(0, math.floor(n + 0.5))
end

-- A wave's size for display and totals: already spawned NPCs stay, so never below what spawned.
local function WaveSize(ctx, st, w)
    local ws = st.waves[w]
    return math.max(ws and ws.spawned or 0, WaveTarget(ctx, w))
end

local function HasBoss(ctx)
    return type(ctx.obj.boss) == 'table'
end

local function BossPed(st)
    return st.boss and st.peds[tostring(st.boss.netId)] or nil
end

local function AliveInWave(st, w)
    local n = 0
    for _, p in pairs(st.peds) do
        if p.role == 'hostile' and p.wave == w and not Neutralised(p) then n = n + 1 end
    end
    return n
end

local function Remaining(st)
    local n = 0
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then n = n + 1 end
    end
    return n
end

local function Totals(ctx, st)
    local total = 0
    for w = 1, WaveCount(ctx) do total = total + WaveSize(ctx, st, w) end
    local done = 0
    for _, p in pairs(st.peds) do
        if p.role == 'hostile' and Neutralised(p) then done = done + 1 end
    end
    return done, total
end

-- Distinct points first, points with no living hostile on them before occupied ones; a wave larger
-- than the list reuses points in the same order with a small ring offset.
local function PickPoints(ctx, st, n)
    local all = st.sets and SetPoints(ctx.obj, ctx.location, st.sets) or PointList(ctx.location, ctx.obj.spawns)
    if #all == 0 then
        local s = StartCoords(ctx)
        if s then all = { s } end
        CP.warn(BLOCK, 'no spawn points at %s for run %s; using the start point', tostring(ctx.obj.spawns),
            tostring(ctx.run and ctx.run.id))
    end
    if #all == 0 or n <= 0 then return {} end
    local living = {}
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            local c = PedCoords(p)
            if c then living[#living + 1] = c end
        end
    end
    local free, used = {}, {}
    for _, p in ipairs(RngOf(ctx):shuffle(all)) do
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
            out[i] = ToVec4(free[k])
        else
            local a = lap * 2.39996 + k
            out[i] = ToVec4(free[k], math.cos(a) * REUSE_OFFSET * lap, math.sin(a) * REUSE_OFFSET * lap)
        end
    end
    return out
end

local function SpawnHostile(ctx, st, w, point)
    local obj = ctx.obj
    local r = RngOf(ctx)
    local c = Cfg()
    local model = r:pick(obj.peds) or c.peds[1]
    local weapon = r:pick(obj.weapons) or c.weapons[1]
    local acc, arm = ctx.combat(obj.accuracy, obj.armour)
    local health = math.floor((tonumber(obj.health) or 200) * (tonumber(Feel().healthMult) or 1.0) + 0.5)
    local ent, netId = ctx.spawnPed({
        model = model,
        coords = point,
        role = 'hostile',
        armed = true,
        weapon = weapon,
        accuracy = acc,
        armour = arm,
        health = health,
        cfg = { behaviour = Behaviour(ctx, st), group = 'hostile', wave = w },
        tag = 'wave' .. w,
    })
    if not netId then return false end
    st.peds[tostring(netId)] = {
        netId = netId,
        entity = ent,
        role = 'hostile',
        wave = w,
        state = 'hostile',
        maxHealth = health,
    }
    CP.Npc.setState(ctx.run, netId, 'hostile')
    st.dirty = true
    return true
end

local function SpawnBoss(ctx, st)
    if st.boss then return true end
    if not ctx.canSpawn(1, true) then return false end
    local b = ctx.obj.boss
    local point = PointList(ctx.location, b.spawn)[1]
    point = point and ToVec4(point) or PickPoints(ctx, st, 1)[1]
    if not point then return false end
    local health = math.floor((tonumber(b.health) or 300) * (tonumber(Feel().healthMult) or 1.0) + 0.5)
    local behaviour = type(b.behaviour) == 'string' and b.behaviour or Behaviour(ctx, st)
    local ent, netId = ctx.spawnPed({
        model = b.model,
        coords = point,
        role = 'boss',
        armed = true,
        weapon = b.weapon,
        accuracy = b.accuracy,
        armour = b.armour,
        health = health,
        cfg = { behaviour = behaviour, group = 'hostile', boss = true, label = b.label },
        tag = 'boss',
    })
    if not netId then return false end
    st.peds[tostring(netId)] = { netId = netId, entity = ent, role = 'boss', state = 'hostile', maxHealth = health }
    st.boss = { netId = netId }
    CP.Npc.setState(ctx.run, netId, 'hostile')
    st.dirty = true
    return true
end

local function StartWave(ctx, st, w)
    st.wave = w
    local ws = st.waves[w] or { spawned = 0, elapsed = 0 }
    st.waves[w] = ws
    ws.points = ws.points or PickPoints(ctx, st, WaveTarget(ctx, w))
    st.dirty = true
end

-- Spawns what is still missing of wave w; returns (fully spawned, spawn budget left).
local function SpawnWave(ctx, st, w, budget)
    local ws = st.waves[w]
    local target = WaveTarget(ctx, w)
    while ws.spawned < target and budget > 0 do
        if not ctx.canSpawn(1, true) then return false, budget end
        local i = ws.spawned + 1
        local point = ws.points[i]
        if not point then
            point = PickPoints(ctx, st, 1)[1]
            ws.points[i] = point
        end
        if not point or not SpawnHostile(ctx, st, w, point) then return false, budget end
        ws.spawned = i
        budget = budget - 1
        if st.stopped then return false, 0 end
    end
    return ws.spawned >= target, budget
end

local function AdvanceLoop(ctx, st, n)
    if st.wave == 0 then StartWave(ctx, st, 1) end
    local budget = SPAWNS_PER_TICK
    while not st.stopped do
        local w = st.wave
        local full
        full, budget = SpawnWave(ctx, st, w, budget)
        if not full then break end
        local nw = ctx.obj.nextWave
        local ready = AliveInWave(st, w) <= (tonumber(nw.aliveAtMost) or 0)
            or st.waves[w].elapsed >= (tonumber(nw.afterSeconds) or math.huge)
        if not ready then break end
        if w < n then
            StartWave(ctx, st, w + 1)
            if budget <= 0 then break end
        else
            if HasBoss(ctx) and not st.boss then SpawnBoss(ctx, st) end
            break
        end
    end
end

-- The spawning flag guards against re-entry while ctx.spawnPed yields; it is always cleared, even
-- when a spawn throws, so one bad spawn can never freeze the waves for the rest of the run.
local function Advance(ctx, st)
    if st.spawning or st.stopped or st.failed then return end
    local n = WaveCount(ctx)
    if n == 0 then return end
    st.spawning = true
    local ok, err = pcall(AdvanceLoop, ctx, st, n)
    st.spawning = false
    if not ok then CP.err(BLOCK, 'spawning for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(err)) end
end

local function AllOut(ctx, st)
    local n = WaveCount(ctx)
    if st.wave < n then return false end
    for w = 1, n do
        local ws = st.waves[w]
        if not ws or ws.spawned < WaveTarget(ctx, w) then return false end
    end
    if HasBoss(ctx) and not st.boss then return false end
    return true
end

-- ============================================================================
--                            HUD AND CLIENT UPDATES
-- ============================================================================

local function UpdateHud(ctx, st)
    local done, total = Totals(ctx, st)
    local left = total - done
    local b = BossPed(st)
    local text
    if b and not Neutralised(b) then
        text = CP.L('block.hostile_waves.detail_boss', { boss = ctx.obj.boss.label, left = left })
    elseif AllOut(ctx, st) and Remaining(st) == 0 then
        text = CP.L('block.hostile_waves.detail_clear')
    else
        text = CP.L('block.hostile_waves.detail', { wave = math.max(st.wave, 1), waves = WaveCount(ctx), left = left })
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
            list[#list + 1] = { netId = p.netId, role = p.role, state = p.state, wave = p.wave }
        end
        table.sort(list, function(a, b) return a.netId < b.netId end)
        ctx.send({ peds = list, wave = st.wave, waves = WaveCount(ctx) })
    end
    UpdateHud(ctx, st)
end

-- ============================================================================
--                        SURRENDER, CUFFING, COMPLETION
-- ============================================================================

local function SurrenderCfg(ctx, p)
    if p.role == 'boss' and HasBoss(ctx) then return ctx.obj.boss.surrender end
    return ctx.obj.surrender
end

local function Surrender(ctx, st, p)
    p.state = 'surrendered'
    p.surrenderedAt = Now()
    CP.Npc.setState(ctx.run, p.netId, 'surrendered')
    local cuff = type(ctx.obj.cuff) == 'table' and ctx.obj.cuff or {}
    CP.Npc.enableCuff(ctx.run, p.netId, {
        label = cuff.label or CP.L('block.hostile_waves.cuff'),
        duration = cuff.duration,
        maxDistance = cuff.maxDistance,
    })
    st.dirty = true
end

local function RollSurrender(ctx, p, chance)
    if CP.Npc.rollSurrender then return CP.Npc.rollSurrender(ctx.run, p.netId, chance) == true end
    return RngOf(ctx):chance(chance)
end

local function CheckLowHealth(ctx, st, p)
    if p.state ~= 'hostile' then return false, 'wrong_state' end
    if p.rolled then return false, 'duplicate' end
    local s = SurrenderCfg(ctx, p)
    local ratio = HealthRatio(p)
    if not ratio or ratio <= 0 then return false, 'no_health' end
    if ratio >= (tonumber(s.belowHealth) or 0) then return false, 'health_ok' end
    p.rolled = true
    st.dirty = true
    local chance = math.min(1.0, (tonumber(s.chance) or 0) * (tonumber(Feel().surrenderMult) or 1.0))
    if chance > 0 and RollSurrender(ctx, p, chance) then Surrender(ctx, st, p) end
    return true
end

local function MarkCuffed(ctx, st, p)
    if p.state == 'cuffed' then return end
    p.state = 'cuffed'
    st.dirty = true
    if p.role == 'boss' then
        local ab = ctx.obj.boss and ctx.obj.boss.aliveBonus or BOSS_BONUS
        ctx.award(ab.id, { count = 1, points = BossBonusPoints(ctx, ab) })
    else
        st.arrested = (st.arrested or 0) + 1
        ctx.award('hostile_arrested', { count = 1 })
    end
end

local function BagCuffed(p)
    return CP.Npc.getState and CP.Npc.getState(p.netId) == 'cuffed'
end

local function OnCuffed(ctx, st, src, p)
    if not p then return false, 'unknown_entity' end
    if p.state == 'cuffed' then return false, 'duplicate' end
    if p.state ~= 'surrendered' then return false, 'wrong_state' end
    if not BagCuffed(p) then return false, 'not_cuffed' end
    local pc, sc = PedCoords(p), ctx.coords(src)
    local reach = ((type(ctx.obj.cuff) == 'table' and ctx.obj.cuff.maxDistance) or CUFF_RANGE) + REACH_SLACK
    if not pc or not sc or U.dist(pc, sc) > reach then return false, 'too_far' end
    MarkCuffed(ctx, st, p)
    if CP.Runs and CP.Runs.noteArrest and ctx.run then CP.Runs.noteArrest(ctx.run, src, p.netId) end
    return true
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.stopped then return end
    if not AllOut(ctx, st) or Remaining(st) > 0 then return end
    local done, total = Totals(ctx, st)
    if ctx.complete({ neutralised = done, total = total, arrested = st.arrested or 0 }) ~= false then
        st.completed = true
    end
end

-- Entities gone without a death event, and cuffs whose event did not arrive.
local function Refresh(ctx, st)
    for _, p in pairs(st.peds) do
        if not Neutralised(p) then
            if not p.entity or not DoesEntityExist(p.entity) then
                p.state = 'dead'
                st.dirty = true
            elseif p.state == 'surrendered' and BagCuffed(p) then
                MarkCuffed(ctx, st, p)
            end
        end
    end
end

-- Server-side health poll (every tick): a hostile under belowHealth gets its one roll even when the
-- host's 'low_health' report reached the server before the damage did (the server's copy of the
-- health lags the owner's) or never arrived at all. The report only makes the roll come sooner.
local function PollHealth(ctx, st)
    for _, p in pairs(st.peds) do
        if p.state == 'hostile' and not p.rolled and (tonumber(SurrenderCfg(ctx, p).chance) or 0) > 0 then
            CheckLowHealth(ctx, st, p)
        end
    end
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function Start(ctx)
    local st = StateOf(ctx)
    st.stopped = nil
    Advance(ctx, st)
    Flush(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    if st.stopped or st.failed then return end
    if not st.completed then
        local ws = st.waves[st.wave]
        if ws then ws.elapsed = ws.elapsed + (tonumber(dt) or 1) end
        Refresh(ctx, st)
        PollHealth(ctx, st)
        Advance(ctx, st)
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local netId = tonumber(ev.netId)
    local p = netId and st.peds[tostring(netId)] or nil
    local ok, why
    if ev.type == 'low_health' then
        if not p then return false, 'unknown_entity' end
        ok, why = CheckLowHealth(ctx, st, p)
    elseif ev.type == 'cuffed' then
        ok, why = OnCuffed(ctx, st, src, p)
    elseif ev.type == 'shot' then
        if not p then return false, 'unknown_entity' end
        ok = true
    elseif ev.type == 'damaged' then
        if not p then return false, 'unknown_entity' end
        if p.state == 'hostile' and not p.rolled then CheckLowHealth(ctx, st, p) end
        ok = true
    else
        return false, 'unknown_event'
    end
    TryComplete(ctx, st)
    Flush(ctx, st)
    return ok, why
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local p = st.peds[tostring(netId)]
    if not p or p.state == 'dead' then return end
    local prev = p.state
    p.state = 'dead'
    st.dirty = true
    local protected = prev == 'cuffed'
        or (prev == 'surrendered' and not (p.surrenderedAt and Now() - p.surrenderedAt < SURRENDER_GRACE_MS))
    if protected and not st.failed and IsParticipant(ctx, killerSrc) then
        st.failed = true
        ctx.fail('run.fail_killed_unarmed')
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
            local c = PedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local s = StartCoords(ctx)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local done, total = Totals(ctx, st)
    local list = {
        {
            label = CP.L('block.hostile_waves.check_hostiles'),
            done = total > 0 and done >= total and AllOut(ctx, st),
            value = done,
            max = total,
        },
    }
    if HasBoss(ctx) then
        local b = BossPed(st)
        local bossDone = b ~= nil and Neutralised(b)
        list[#list + 1] = {
            label = CP.L('block.hostile_waves.check_boss', { boss = ctx.obj.boss.label }),
            done = bossDone,
            value = bossDone and 1 or 0,
            max = 1,
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
    st = StateOf(ctx)
    st.dirty = true
    Advance(ctx, st)
    Flush(ctx, st)
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
    onParticipantLeft = function(ctx) Flush(ctx, StateOf(ctx)) end,
    rescale = Rescale,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    restart = Restart,
    stop = Stop,
})
