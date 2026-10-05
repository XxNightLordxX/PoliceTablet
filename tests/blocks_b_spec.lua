-- Slice blocks_b: the server halves of hostile_waves, protect_rescue and flee_arrest driven through a FAKE ctx (spies
-- for complete/fail/award/penalize/spawnPed/canSpawn/ coords/send/hud), a stubbed CP.Npc and a tiny entity world. Also
-- checks the locale part.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U
local cjson = require('cjson')

-- ============================================================================
--            FAKE WORLD: every entity spawned through the fake ctx
-- ============================================================================

local W = { ents = {}, nextEnt = 1000, nextNet = 5000 }
local playerCoords = GetEntityCoords
_G.GetEntityCoords = function(e)
    local x = W.ents[e]
    if x then return x.coords end
    return playerCoords(e)
end
_G.GetEntityHealth = function(e) local x = W.ents[e]; return x and x.health or 0 end
_G.GetEntityMaxHealth = function(e) local x = W.ents[e]; return x and x.maxHealth or 0 end
_G.DoesEntityExist = function(e)
    local x = W.ents[e]
    if x then return x.exists end
    return true
end
_G.SetEntityCoords = function(e, x, y, z) if W.ents[e] then W.ents[e].coords = vec3(x, y, z) end end
_G.SetEntityHeading = function(e, h) if W.ents[e] then W.ents[e].heading = h end end
W.weapons = {}
_G.GiveWeaponToPed = function(e, w, ammo, hidden, inHand)
    W.weapons[#W.weapons + 1] = { e = e, w = w, ammo = ammo, hidden = hidden, inHand = inHand }
end

-- ============================================================================
--                  CP.Npc STUB (modules/npc is another slice)
-- ============================================================================

local NPC = { states = {}, extra = {}, cuffs = {}, rolls = {}, rollResult = true, damaged = {} }
CP.Npc = {
    setState = function(_, netId, state, extra)
        NPC.states[netId] = state
        NPC.extra[netId] = extra
    end,
    getState = function(netId) return NPC.states[netId] end,
    rollSurrender = function(_, netId, chance)
        NPC.rolls[#NPC.rolls + 1] = { netId = netId, chance = chance }
        return NPC.rollResult
    end,
    enableCuff = function(_, netId, opts) NPC.cuffs[netId] = opts end,
    onDamaged = function(fn) NPC.damaged[#NPC.damaged + 1] = fn end,
}

H.load('blocks/hostile_waves/server.lua')
H.load('blocks/protect_rescue/server.lua')
H.load('blocks/flee_arrest/server.lua')
local HW = CP.Blocks.get('hostile_waves')
local PR = CP.Blocks.get('protect_rescue')
local FA = CP.Blocks.get('flee_arrest')
H.ok(HW and PR and FA, 'three blocks registered')

-- ============================================================================
--                                   FAKE CTX
-- ============================================================================

local function MakeCtx(id, obj, location, o)
    o = o or {}
    local impl = CP.Blocks.get(id)
    local index = o.index or 1
    local srcs = o.srcs or { 1 }
    local run = {
        id = 'run-' .. id .. '-' .. tostring(W.nextNet),
        seed = o.seed or 1234,
        participants = {},
        objectives = {},
        entities = {},
        state = 'in_progress',
    }
    for _, s in ipairs(srcs) do run.participants[s] = { src = s, status = 'active' } end
    local state = {}
    run.objectives[index] = { status = 'active', state = state }
    local S = {
        completeCalls = 0,
        completes = 0,
        fails = {},
        awards = {},
        penalties = {},
        sends = {},
        huds = {},
        spawned = {},
        deleted = {},
        can = true,
        minOk = true,
        active = srcs,
    }
    local scaled = impl.defaults(obj)
    local ctx
    ctx = {
        run = run,
        index = index,
        obj = scaled,
        base = U.deepcopy(scaled),
        mission = o.mission or { source = 'builtin' },
        location = location,
        tier = { tier = 'standard' },
        state = state,
        rng = U.rng(run.seed + index),
        complete = function(data)
            S.completeCalls = S.completeCalls + 1
            if S.minOk then S.completes = S.completes + 1; S.completeData = data; return true end
            return false
        end,
        fail = function(key) S.fails[#S.fails + 1] = key end,
        award = function(bid, opts) S.awards[#S.awards + 1] = { id = bid, opts = opts or {} } end,
        penalize = function(pid, opts) S.penalties[#S.penalties + 1] = { id = pid, opts = opts or {} } end,
        send = function(d) S.sends[#S.sends + 1] = d end,
        hud = function(p) S.huds[#S.huds + 1] = p end,
        spawnPed = function(opts)
            W.nextEnt, W.nextNet = W.nextEnt + 1, W.nextNet + 1
            local e, n = W.nextEnt, W.nextNet
            W.ents[e] = {
                coords = vec3(opts.coords.x, opts.coords.y, opts.coords.z),
                health = opts.health or 200,
                maxHealth = opts.health or 200,
                exists = true,
                netId = n,
                opts = opts,
            }
            S.spawned[#S.spawned + 1] = { entity = e, netId = n, opts = opts }
            run.entities[n] = { entity = e, obj = index, role = opts.role, armed = opts.armed }
            return e, n
        end,
        canSpawn = function()
            if S.canLimit then
                if S.canLimit <= 0 then return false end
                S.canLimit = S.canLimit - 1
                return true
            end
            return S.can
        end,
        delete = function(netId)
            S.deleted[#S.deleted + 1] = netId
            for _, x in pairs(W.ents) do if x.netId == netId then x.exists = false end end
        end,
        participants = function() return S.active end,
        coords = function(src) local p = H.players[src]; return p and p.coords end,
        combat = function(acc, arm) return acc + 10, arm + 25 end,
        isHost = function(src) return src == srcs[1] end,
        host = function() return srcs[1] end,
    }
    return ctx, S, impl
end

local function Place(src, x, y, z)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
end
local function EntOf(S, netId)
    for _, s in ipairs(S.spawned) do if s.netId == netId then return s.entity end end
end
local function PosOf(S, netId) return W.ents[EntOf(S, netId)].coords end
local function MoveEnt(S, netId, x, y, z) W.ents[EntOf(S, netId)].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0) end
local function SetHealth(S, netId, hp) W.ents[EntOf(S, netId)].health = hp end
local function NearTo(src, S, netId, dx)
    local c = PosOf(S, netId)
    Place(src, c.x + (dx or 1.0), c.y, c.z)
end
local function WithRole(S, role)
    return U.filter(S.spawned, function(s) return s.opts.role == role end)
end
local function AwardsOf(S, id)
    return U.filter(S.awards, function(a) return a.id == id end)
end
local function LastSend(S) return S.sends[#S.sends] end
local function LastHud(S, field)
    for i = #S.huds, 1, -1 do
        if S.huds[i][field] ~= nil then return S.huds[i][field] end
    end
end
local function AdvanceMs(ms) H.clockMs = H.clockMs + ms end

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

local function HwLocation(n, cx, cy)
    cx, cy = cx or 1000.0, cy or 1000.0
    local spawns = {}
    for i = 1, n do
        local a = (i - 1) / n * 2 * math.pi
        spawns[i] = vec4(cx + 60 * math.cos(a), cy + 60 * math.sin(a), 30.0, 0.0)
    end
    return {
        label = 'Hideout',
        start = { coords = vec3(cx, cy, 30.0), radius = 80.0 },
        spawns = spawns,
        bossSpot = vec4(cx, cy + 70, 30.0, 180.0),
    }
end

local prLoc = {
    label = 'Store',
    start = { coords = vec3(1960.0, 2000.0, 20.0), radius = 60.0 },
    hostages = { vec4(2000.0, 2000.0, 20.0, 0.0), vec4(2010.0, 2000.0, 20.0, 0.0), vec4(2020.0, 2000.0, 20.0, 0.0) },
    safe = vec3(2050.0, 2000.0, 20.0),
}

local doorLoc = {
    label = 'House',
    start = { coords = vec3(3000.0, 3000.0, 10.0), radius = 50.0 },
    door = vec4(3040.0, 3000.0, 10.0, 90.0),
    suspect = vec4(3045.0, 3000.0, 10.0, 90.0),
    fleeTo = { vec3(3060.0, 3000.0, 10.0), vec3(3100.0, 3000.0, 10.0) },
    associates = { vec4(3046.0, 3005.0, 10.0, 0.0), vec4(3046.0, 2995.0, 10.0, 0.0), vec4(3047.0, 3010.0, 10.0, 0.0) },
    yard = vec3(3050.0, 3020.0, 10.0),
}

local function ScatterSpawns(n)
    local out = {}
    for i = 1, n do out[i] = vec4(4040.0 + (i - 1) * 20.0, 4000.0, 30.0, 0.0) end
    return out
end
local scatterLoc = {
    label = 'Breakout A',
    start = { coords = vec3(4000.0, 4000.0, 30.0), radius = 150.0 },
    spawns = ScatterSpawns(6),
    routes = {
        { vec3(4100.0, 4000.0, 30.0), vec3(4300.0, 4000.0, 30.0) },
        { points = { vec3(4040.0, 4100.0, 30.0), vec3(4040.0, 4300.0, 30.0) } },
    },
}
local prisonLoc = {
    label = 'Inside',
    start = { coords = vec3(1900.0, 2600.0, 45.0), radius = 150.0 },
    spawns = { vec4(1770.0, 2570.0, 45.0, 0.0), vec4(1780.0, 2575.0, 45.0, 0.0) },
    routes = { { vec3(1900.0, 2700.0, 45.0) } },
}

local builtin, custom = { source = 'builtin' }, { source = 'custom' }

-- ============================================================================
--                                hostile_waves
-- ============================================================================

do -- defaults
    local d = HW.defaults({ block = 'hostile_waves' })
    H.eq(d.minSeconds, 60, 'hw default minSeconds')
    H.eq(d.presenceRange, 150, 'hw default presenceRange from Config.Blocks')
    H.eq(d.spawns, 'spawns', 'hw default spawns key')
    H.eq(table.concat(d.waves, ','), '7,7,6', 'hw default waves')
    H.eq(d.nextWave.aliveAtMost, 2, 'hw default aliveAtMost')
    H.eq(d.nextWave.afterSeconds, 90, 'hw default afterSeconds')
    H.eq(d.accuracy, 25, 'hw default accuracy')
    H.eq(d.armour, 0, 'hw default armour')
    H.eq(d.health, 200, 'hw default health')
    H.eq(d.behaviour, 'balanced', 'hw default behaviour')
    H.near(d.surrender.chance, 0.30, 1e-9, 'hw default surrender chance')
    H.eq(d.surrender.belowHealth, 0.25, 'hw belowHealth')
    H.eq(d.blockTraffic, 120.0, 'hw default blockTraffic')
    H.eq(d.boss, false, 'hw default no boss')
    H.eq(#d.weapons, 2, 'hw default weapons')
    H.eq(#d.peds, 4, 'hw default peds')
    local b = HW.defaults({ boss = { model = 'g_m_y_lost_01' } }).boss
    H.eq(b.health, 400, 'boss default health')
    H.eq(b.armour, 100, 'boss default armour')
    H.eq(b.weapon, 'WEAPON_ASSAULTRIFLE', 'boss default weapon')
    H.eq(b.aliveBonus.id, 'kingpin_alive', 'boss bonus id')
    H.eq(b.aliveBonus.points, 50, 'boss bonus points')
    H.near(b.surrender.chance, 0.30, 1e-9, 'boss surrender chance')
    H.eq(b.label, 'block.hostile_waves.boss_label', 'boss label from locale')
    local keep = HW.defaults({ waves = { 4 }, accuracy = 40 })
    H.eq(keep.waves[1], 4, 'hw keeps given waves')
    H.eq(keep.accuracy, 40, 'hw keeps given accuracy')
end

do -- validate
    local loc = HwLocation(12)
    H.eq(HW.validate({ waves = { 7, 7, 6 } }, builtin, loc), true, 'hw valid builtin')
    H.eq(HW.validate({ waves = { 7, 7, 6 } }, custom, loc), true, 'hw valid custom (12 points >= 1.5 x 7)')
    local ok, why = HW.validate({ waves = { 20 } }, builtin, loc)
    H.eq(ok, false, 'hw wave too big')
    H.eq(why, 'block.hostile_waves.invalid.range', 'hw wave reason')
    H.eq(HW.validate({ waves = { 1, 1, 1, 1, 1, 1, 1 } }, builtin, loc), false, 'hw too many waves')
    H.eq(HW.validate({ accuracy = 99 }, builtin, loc), false, 'hw accuracy out of range')
    H.eq(HW.validate({ health = 50 }, builtin, loc), false, 'hw health out of range')
    ok, why = HW.validate({ behaviour = 'crazy' }, builtin, loc)
    H.eq(why, 'block.hostile_waves.invalid.behaviour', 'hw bad behaviour')
    H.eq(HW.validate({ surrender = { chance = 1.5 } }, builtin, loc), false, 'hw surrender chance > 1')
    H.eq(HW.validate({ nextWave = { aliveAtMost = 9 } }, builtin, loc), false, 'hw aliveAtMost out of range')
    H.eq(HW.validate({ weapons = { 'WEAPON_RPG' } }, builtin, loc), true, 'builtin weapon list not limited to allowed')
    ok, why = HW.validate({ weapons = { 'WEAPON_RPG' } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.weapons', 'custom weapon must be allowed')
    ok, why = HW.validate({ peds = { 'a_m_y_hipster_01' } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.peds', 'custom ped must be allowed')
    ok, why = HW.validate({ waves = { 7 } }, custom, HwLocation(8))
    H.eq(why, 'block.hostile_waves.invalid.spawns_count', 'custom needs 1.5 x largest wave spawn points')
    H.eq(HW.validate({ waves = { 7 } }, builtin, HwLocation(8)), true, 'builtin spawn count trusted')
    local nearStart = HwLocation(12)
    nearStart.spawns[1] = vec4(1010.0, 1000.0, 30.0, 0.0)
    ok, why = HW.validate({}, custom, nearStart)
    H.eq(why, 'block.hostile_waves.invalid.spawns_start', 'custom spawn too close to start')
    local noSpawns = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 50.0 } }
    ok, why = HW.validate({}, builtin, noSpawns)
    H.eq(why, 'block.hostile_waves.invalid.spawns_missing', 'spawns missing')
    ok, why = HW.validate({}, { source = 'builtin', locations = { loc, noSpawns } })
    H.eq(ok, false, 'validate walks mission.locations')
    H.eq(why, 'block.hostile_waves.invalid.spawns_missing', 'second location missing')
    H.eq(HW.validate({ boss = { health = 999 } }, builtin, loc), false, 'boss health out of range')
    H.eq(HW.validate({ boss = { spawn = 'nowhere' } }, builtin, loc), false, 'boss spawn key missing')
    H.eq(HW.validate({ boss = { spawn = 'bossSpot' } }, builtin, loc), true, 'boss with spawn key ok')
    ok, why = HW.validate({ waves = { 15, 15, 15 } }, builtin, loc)
    H.eq(why, 'block.hostile_waves.invalid.armed_budget', 'armed budget 40')
    H.eq(HW.validate({ blockTraffic = 500 }, builtin, loc), false, 'blockTraffic out of range')
    H.eq(HW.validate({ presenceRange = 10 }, builtin, loc), false, 'presenceRange out of range')
    H.eq(HW.validate('x', builtin, loc), false, 'non-table objective')
    H.eq(HW.armedCount({ waves = { 8, 8, 7, 7 }, boss = {} }), 31, 'kingpin armed count')
    H.eq(HW.armedCount({}), 20, 'gang shootout armed count')
    local rp = HW.requiredPoints({ boss = { spawn = 'bossSpot' } })
    H.eq(rp[1], 'spawns', 'required spawns')
    H.eq(rp[2], 'bossSpot', 'required boss spot')
    H.eq(HW.onTimeout({}), nil, 'hw onTimeout fails')

    -- custom missions: the boss bonus is the block's kingpin_alive (its own constant) or a Config.Bonuses id,
    -- never a value from the file; the optional cuff takes 1-30 s and reaches no further than 3 m
    local bossWith = function(ab) return { boss = { model = 'g_m_y_lost_01', aliveBonus = ab } } end
    H.eq(HW.validate({ boss = { model = 'g_m_y_lost_01' } }, custom, loc), true,
        'hw custom: boss with the default kingpin_alive')
    H.eq(HW.validate(HW.defaults({ boss = { model = 'g_m_y_lost_01' } }), custom, loc), true,
        'hw custom: defaulted boss (kingpin_alive, 50) passes')
    ok, why = HW.validate(bossWith({ id = 'kingpin_alive', points = 100000 }), custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.boss_bonus_custom', 'hw custom: a file value on kingpin_alive rejected')
    ok, why = HW.validate(bossWith({ id = 'boss_bonus', points = 40 }), custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.boss_bonus_custom', 'hw custom: an id outside Config.Bonuses rejected')
    ok, why = HW.validate(bossWith({ id = 'medal_gold' }), custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.boss_bonus_custom', 'hw custom: a medal id rejected')
    H.eq(HW.validate(bossWith({ id = 'hostile_arrested' }), custom, loc), true,
        'hw custom: a Config.Bonuses id without points passes')
    ok, why = HW.validate(bossWith({ id = 'hostile_arrested', points = 45 }), custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.boss_bonus_custom',
        'hw custom: a Config.Bonuses id with its own points rejected')
    ok, why = HW.validate(bossWith({ id = 'kingpin_alive', pctOfPoints = 0.9 }), custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.boss_bonus_custom', 'hw custom: pctOfPoints rejected')
    H.eq(HW.validate(bossWith({ id = 'boss_bonus', points = 999 }), builtin, loc), true,
        'hw builtin: its own boss bonus value is trusted')
    ok, why = HW.validate({ cuff = { duration = 100 } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.range', 'hw custom: a 0.1 s cuff rejected')
    ok, why = HW.validate({ cuff = { duration = 90000 } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.range', 'hw custom: a 90 s cuff rejected')
    ok, why = HW.validate({ cuff = { maxDistance = 40.0 } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.range', 'hw custom: a 40 m cuff rejected')
    H.eq(HW.validate({ cuff = { duration = 4000, maxDistance = 2.5 } }, custom, loc), true,
        'hw custom: cuff within range passes')
    H.eq(HW.validate({ cuff = { duration = 100, maxDistance = 40.0 } }, builtin, loc), true, 'hw builtin: cuff trusted')
end

do -- waves: start, distinct points, combat values, next wave by count and by time, low health, cuffs, completion
    local loc = HwLocation(12)
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 7, 7, 6 } }, loc)
    HW.prepare(ctx)
    HW.start(ctx)
    H.eq(#S.spawned, 7, 'wave 1 spawned at start')
    local seen, distinct = {}, 0
    for _, s in ipairs(S.spawned) do
        local k = ('%.2f,%.2f'):format(s.opts.coords.x, s.opts.coords.y)
        if not seen[k] then seen[k] = true; distinct = distinct + 1 end
        H.eq(s.opts.armed, true, 'hostile armed')
        H.eq(s.opts.role, 'hostile', 'hostile role')
        H.eq(s.opts.accuracy, 35, 'accuracy + tier via ctx.combat')
        H.eq(s.opts.armour, 25, 'armour + tier via ctx.combat')
        H.ok(U.contains(ctx.obj.weapons, s.opts.weapon), 'weapon from the list')
        H.ok(U.contains(ctx.obj.peds, s.opts.model), 'model from the list')
        H.eq(NPC.states[s.netId], 'hostile', 'bag state hostile')
    end
    H.eq(distinct, 7, 'wave 1 uses 7 distinct spawn points')
    H.eq(#LastSend(S).peds, 7, 'client snapshot lists 7 peds')
    H.eq(LastSend(S).waves, 3, 'client snapshot waves')
    H.eq(LastHud(S, 'max'), 20, 'HUD max = 20 hostiles')
    H.eq(LastHud(S, 'detail'), 'block.hostile_waves.detail', 'HUD detail line')

    -- presence: nearest living hostile
    H.near(HW.presence(ctx, 1, vec3(1000, 1000, 30)), 60, 0.01, 'presence = nearest living hostile')

    for i = 1, 4 do HW.onEntityDead(ctx, S.spawned[i].netId, 1) end
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 7, '3 alive > aliveAtMost: no wave 2 yet')
    HW.onEntityDead(ctx, S.spawned[5].netId, 1)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 14, 'wave 2 when 2 are left')
    H.eq(#S.fails, 0, 'killing hostiles never fails')
    for _ = 1, 89 do HW.tick(ctx, 1) end
    H.eq(#S.spawned, 14, 'no wave 3 before afterSeconds')
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 20, 'wave 3 after afterSeconds')
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 20, 'no more than the 3 waves')

    -- low health -> one roll per hostile
    local h1, h2 = S.spawned[8].netId, S.spawned[9].netId
    local ok, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = h1 })
    H.eq(ok, false, 'full health rejected')
    H.eq(why, 'health_ok', 'health_ok reason')
    SetHealth(S, h1, 110)
    NPC.rollResult = true
    ok = HW.onEvent(ctx, 1, { type = 'low_health', netId = h1 })
    H.eq(ok, true, 'low health accepted')
    H.eq(NPC.states[h1], 'surrendered', 'surrendered after a won roll')
    H.near(NPC.rolls[#NPC.rolls].chance, 0.30, 1e-9, 'rolled with surrender.chance')
    H.ok(NPC.cuffs[h1] ~= nil, 'Cuff suspect enabled')
    ok, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = h1 })
    H.eq(why, 'wrong_state', 'no second roll for a surrendered hostile')
    SetHealth(S, h2, 120)
    NPC.rollResult = false
    H.eq(HW.onEvent(ctx, 1, { type = 'low_health', netId = h2 }), true, 'lost roll accepted')
    H.eq(NPC.states[h2], 'hostile', 'lost roll stays hostile')
    ok, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = h2 })
    H.eq(why, 'duplicate', 'one roll per hostile')
    ok, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = 999999 })
    H.eq(why, 'unknown_entity', 'unknown netId')
    ok, why = HW.onEvent(ctx, 1, { type = 'teleport' })
    H.eq(why, 'unknown_event', 'unknown event type')

    -- cuff: bag must say cuffed, cuffing participant in range, once
    Place(1, 1000, 1000, 30)
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'not_cuffed', 'cuffed event without a cuffed bag')
    NPC.states[h1] = 'cuffed'
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'too_far', 'cuff reporter too far')
    NearTo(1, S, h1)
    local savedRunsHW, arrestsHW = CP.Runs, {}
    CP.Runs = setmetatable({
        noteArrest = function(run, src, netId) arrestsHW[#arrestsHW + 1] = { src = src, netId = netId } end,
    }, { __index = savedRunsHW or {} })
    H.eq(HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 }), true, 'cuff accepted')
    CP.Runs = savedRunsHW
    H.ok(#arrestsHW == 1 and arrestsHW[1].src == 1 and arrestsHW[1].netId == h1, 'hw: the cuff notes one arrest')
    H.eq(#AwardsOf(S, 'hostile_arrested'), 1, 'hostile_arrested +1')
    H.eq(AwardsOf(S, 'hostile_arrested')[1].opts.count, 1, 'award count 1')
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'duplicate', 'second cuff event')
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h2 })
    H.eq(why, 'wrong_state', 'cuff on a hostile that never surrendered')
    H.eq(HW.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event accepted')

    -- a cuff whose event never arrived is picked up from the bag
    local h3 = S.spawned[10].netId
    SetHealth(S, h3, 105)
    NPC.rollResult = true
    HW.onEvent(ctx, 1, { type = 'low_health', netId = h3 })
    NPC.states[h3] = 'cuffed'
    HW.tick(ctx, 1)
    H.eq(#AwardsOf(S, 'hostile_arrested'), 2, 'missed cuff event picked up by tick')

    -- a surrendered hostile killed by a non-participant: no fail
    local h4 = S.spawned[11].netId
    SetHealth(S, h4, 105)
    HW.onEvent(ctx, 1, { type = 'low_health', netId = h4 })
    AdvanceMs(5000)
    HW.onEntityDead(ctx, h4, 77)
    H.eq(#S.fails, 0, 'outsider kill of a surrendered hostile does not fail')

    -- checklist while running
    local cl = HW.checklist(ctx)
    H.eq(cl[1].max, 20, 'checklist max')
    H.eq(cl[1].done, false, 'checklist not done')

    -- neutralise the rest -> completion (minSeconds first refuses)
    S.minOk = false
    for _, s in ipairs(S.spawned) do
        if NPC.states[s.netId] ~= 'cuffed' then HW.onEntityDead(ctx, s.netId, 1) end
    end
    HW.tick(ctx, 1)
    H.eq(S.completeCalls >= 1, true, 'complete tried')
    H.eq(S.completes, 0, 'refused before minSeconds')
    S.minOk = true
    HW.tick(ctx, 1)
    H.eq(S.completes, 1, 'completed on a later tick')
    H.eq(S.completeData.arrested, 2, 'completion data: 2 arrested')
    HW.tick(ctx, 1)
    H.eq(S.completes, 1, 'completed once')
    H.eq(HW.checklist(ctx)[1].done, true, 'checklist done')
    H.near(HW.presence(ctx, 1, vec3(1000, 1030, 30)), 30, 0.01, 'presence between waves / after: start point')
    H.eq(#S.fails, 0, 'no fail on the way')
    HW.stop(ctx)
end

do -- killing a surrendered hostile (after the grace) fails; inside the grace it does not
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 3 } }, HwLocation(12))
    HW.start(ctx)
    local a, b = S.spawned[1].netId, S.spawned[2].netId
    NPC.rollResult = true
    SetHealth(S, a, 110)
    HW.onEvent(ctx, 1, { type = 'low_health', netId = a })
    HW.onEntityDead(ctx, a, 1)
    H.eq(#S.fails, 0, 'kill within the surrender grace is not a fail')
    SetHealth(S, b, 110)
    HW.onEvent(ctx, 1, { type = 'low_health', netId = b })
    AdvanceMs(4000)
    HW.onEntityDead(ctx, b, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed a surrendered hostile')
    HW.tick(ctx, 1)
    H.eq(S.completes, 0, 'failed objective never completes')
end

do -- server-dispatched 'damaged' events trigger the same health check (one roll per hostile)
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 3 } }, HwLocation(12))
    HW.start(ctx)
    local a, b = S.spawned[1].netId, S.spawned[2].netId
    local rolls = #NPC.rolls
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'damaged at full health accepted')
    H.eq(#NPC.rolls, rolls, 'no roll at full health')
    SetHealth(S, a, 110)
    NPC.rollResult = true
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'damaged under the threshold')
    H.eq(NPC.states[a], 'surrendered', 'damaged path rolled and surrendered')
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'later damage accepted')
    H.eq(#NPC.rolls, rolls + 1, 'still one roll')
    local ok, why = HW.onEvent(ctx, 1, { type = 'damaged', netId = 31337 })
    H.eq(why, 'unknown_entity', 'damaged unknown entity')
    H.eq(NPC.states[b], 'hostile', 'other hostile untouched')
end

do -- caps: the wave waits (never cut), big waves spread over ticks
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 12 } }, HwLocation(12))
    S.can = false
    HW.start(ctx)
    H.eq(#S.spawned, 0, 'no room: nothing spawned')
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 0, 'still waiting')
    S.can = true
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 8, 'spawn budget per tick')
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 12, 'the rest next tick, count never cut')
end

do -- rescale: a partly spawned wave only gets what is missing for the new counts
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 7, 7, 6 } }, HwLocation(12))
    HW.start(ctx)
    for i = 1, 5 do HW.onEntityDead(ctx, S.spawned[i].netId, 1) end
    S.canLimit = 3
    HW.tick(ctx, 1)
    H.eq(#WithRole(S, 'hostile'), 10, 'wave 2 partly spawned (3 of 7)')
    ctx.obj = HW.defaults({ waves = { 5, 5, 4 } })
    HW.rescale(ctx)
    S.canLimit = nil
    HW.tick(ctx, 1)
    local w2 = U.filter(S.spawned, function(s) return s.opts.tag == 'wave2' end)
    H.eq(#w2, 5, 'wave 2 topped up to the new total only')
    for i = 1, 3 do HW.onEntityDead(ctx, w2[i].netId, 1) end
    HW.onEntityDead(ctx, S.spawned[6].netId, 1)
    HW.onEntityDead(ctx, S.spawned[7].netId, 1)
    HW.tick(ctx, 1)
    local w3 = U.filter(S.spawned, function(s) return s.opts.tag == 'wave3' end)
    H.eq(#w3, 4, 'wave 3 uses the rescaled count')
    H.eq(HW.checklist(ctx)[1].max, 16, 'totals follow the rescale (7 already out + 5 + 4)')
end

do -- boss after the last wave: does not scale, kingpin_alive when cuffed
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 4 }, boss = { model = 'g_m_y_lost_01', spawn = 'bossSpot' } },
        HwLocation(12))
    HW.start(ctx)
    H.eq(#S.spawned, 4, 'boss waits for the last wave')
    HW.onEntityDead(ctx, S.spawned[1].netId, 1)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 4, 'boss waits while more than aliveAtMost are left')
    HW.onEntityDead(ctx, S.spawned[2].netId, 1)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 5, 'boss spawns when the last wave is down to aliveAtMost')
    local boss = S.spawned[5]
    H.eq(boss.opts.role, 'boss', 'boss role')
    H.eq(boss.opts.health, 400, 'boss health')
    H.eq(boss.opts.armour, 100, 'boss armour not scaled')
    H.eq(boss.opts.accuracy, 25, 'boss accuracy not scaled')
    H.eq(boss.opts.weapon, 'WEAPON_ASSAULTRIFLE', 'boss weapon')
    H.near(boss.opts.coords.y, 1070, 0.01, 'boss at its own spawn point')
    local cl = HW.checklist(ctx)
    H.eq(#cl, 2, 'boss checklist line')
    H.eq(cl[2].done, false, 'boss not done')
    HW.onEntityDead(ctx, S.spawned[3].netId, 1)
    HW.onEntityDead(ctx, S.spawned[4].netId, 1)
    HW.tick(ctx, 1)
    H.eq(S.completes, 0, 'not complete while the boss is up')
    H.eq(LastHud(S, 'detail'), 'block.hostile_waves.detail_boss', 'boss HUD line')
    SetHealth(S, boss.netId, 150)
    NPC.rollResult = true
    H.eq(HW.onEvent(ctx, 1, { type = 'low_health', netId = boss.netId }), true, 'boss low health')
    H.eq(NPC.states[boss.netId], 'surrendered', 'boss surrendered')
    NPC.states[boss.netId] = 'cuffed'
    NearTo(1, S, boss.netId)
    H.eq(HW.onEvent(ctx, 1, { type = 'cuffed', netId = boss.netId }), true, 'boss cuffed')
    local ka = AwardsOf(S, 'kingpin_alive')
    H.eq(#ka, 1, 'kingpin_alive awarded')
    H.eq(ka[1].opts.points, 50, 'kingpin_alive points hint')
    H.eq(#AwardsOf(S, 'hostile_arrested'), 0, 'boss is not a hostile_arrested')
    HW.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete after the boss')
end

-- The boss bonus hint on a custom mission: only the block's own constant (kingpin_alive +50), never the file's
-- points; a Config.Bonuses id gets no hint (its value comes from the mission's capped bonuses list).
do
    local function CuffBoss(ab, mission)
        Place(1, 1000, 1000, 30)
        local ctx, S = MakeCtx('hostile_waves',
            { waves = { 1 }, boss = { model = 'g_m_y_lost_01', spawn = 'bossSpot', aliveBonus = ab } }, HwLocation(12),
            { mission = mission })
        HW.start(ctx)
        HW.onEntityDead(ctx, S.spawned[1].netId, 1)
        HW.tick(ctx, 1)
        local boss = WithRole(S, 'boss')[1]
        SetHealth(S, boss.netId, 150)
        NPC.rollResult = true
        HW.onEvent(ctx, 1, { type = 'low_health', netId = boss.netId })
        NPC.states[boss.netId] = 'cuffed'
        NearTo(1, S, boss.netId)
        HW.onEvent(ctx, 1, { type = 'cuffed', netId = boss.netId })
        return S
    end
    local S = CuffBoss({ id = 'kingpin_alive', points = 100000 }, custom)
    local ka = AwardsOf(S, 'kingpin_alive')
    H.eq(#ka, 1, 'custom boss: kingpin_alive awarded')
    H.eq(ka[1] and ka[1].opts.points, 50, 'custom boss: the hint is the block constant 50, never the file value')
    S = CuffBoss({ id = 'hostile_arrested', points = 45 }, custom)
    local ha = AwardsOf(S, 'hostile_arrested')
    H.eq(#ha, 1, 'custom boss with a Config.Bonuses id: that id is awarded (the wave hostile was killed, not cuffed)')
    H.eq(ha[1] and ha[1].opts.points, nil,
        'custom boss with a Config.Bonuses id: no hint (valued by the capped card list only)')
    S = CuffBoss({ id = 'boss_bonus', points = 77 }, builtin)
    local bb = AwardsOf(S, 'boss_bonus')
    H.eq(bb[1] and bb[1].opts.points, 77, 'built-in boss: the file value stays the hint')
end

do -- restart (test control) removes and respawns
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 3, 3 } }, HwLocation(12))
    HW.start(ctx)
    HW.onEntityDead(ctx, S.spawned[1].netId, 1)
    HW.restart(ctx)
    H.eq(#S.deleted, 3, 'restart deleted the spawned hostiles')
    H.eq(#S.spawned, 6, 'restart respawned wave 1')
    H.eq(ctx.state.wave, 1, 'restart back at wave 1')
    HW.stop(ctx)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 6, 'stopped objective does nothing')
end

-- ============================================================================
--                                protect_rescue
-- ============================================================================

do -- defaults and validate
    local d = PR.defaults({})
    H.eq(d.minSeconds, 15, 'pr minSeconds')
    H.eq(d.presenceRange, 150, 'pr presenceRange')
    H.eq(d.count, 3, 'pr count')
    H.eq(d.freeTime, 6000, 'pr freeTime ms')
    H.eq(d.hitPenalty, 50, 'pr hitPenalty')
    H.eq(d.restrained, true, 'pr restrained')
    H.eq(d.failIfDies, true, 'pr failIfDies')
    H.eq(d.safeRadius, 6.0, 'pr safeRadius')
    H.eq(d.npcs, 'hostages', 'pr npcs key')
    H.eq(d.safe, 'safe', 'pr safe key')
    H.eq(d.target.label, 'block.protect_rescue.cut_restraints', 'pr target label locale')
    H.eq(d.target.distance, 2.0, 'pr target distance')
    H.eq(#d.peds, 2, 'pr peds')
    H.eq(PR.validate({}, builtin, prLoc), true, 'pr valid')
    H.eq(PR.validate({}, custom, prLoc), true, 'pr valid custom')
    local ok, why = PR.validate({ count = 9 }, builtin, prLoc)
    H.eq(why, 'block.protect_rescue.invalid.range', 'pr count out of range')
    H.eq(PR.validate({ freeTime = 60000 }, builtin, prLoc), false, 'pr freeTime out of range')
    H.eq(PR.validate({ hitPenalty = 150 }, builtin, prLoc), false, 'pr hitPenalty out of range')
    H.eq(PR.validate({ restrained = 'yes' }, builtin, prLoc), false, 'pr restrained must be boolean')
    H.eq(PR.validate({ safeRadius = 0 }, builtin, prLoc), false, 'pr safe radius > 0')
    ok, why = PR.validate({ safe = 'exit' }, builtin, prLoc)
    H.eq(why, 'block.protect_rescue.invalid.points_missing', 'pr safe point missing')
    ok, why = PR.validate({ peds = { 'a_m_y_hipster_01' } }, custom, prLoc)
    H.eq(why, 'block.protect_rescue.invalid.peds', 'pr custom ped must be allowed')
    ok, why = PR.validate({ count = 4 }, custom, prLoc)
    H.eq(why, 'block.protect_rescue.invalid.points_count', 'pr custom needs a spot per NPC')
    H.eq(PR.validate({ count = 4 }, builtin, prLoc), true, 'pr builtin may reuse spots')
    H.eq(PR.armedCount({}), 0, 'pr armed count')
    local rp = PR.requiredPoints({})
    H.eq(rp[1], 'hostages', 'pr required npcs')
    H.eq(rp[2], 'safe', 'pr required safe')
    H.eq(PR.onTimeout({}), nil, 'pr onTimeout fails')
end

do -- spawn in prepare (waiting for room), damage while not current, free, walk to safety
    Place(1, 1990, 2000, 20)
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    S.can = false
    PR.prepare(ctx)
    H.eq(#S.spawned, 0, 'no room in prepare')
    S.can = true
    H.step(1000)
    H.eq(#S.spawned, 3, 'hostages spawned by the retry once there is room')
    for _, s in ipairs(S.spawned) do
        H.eq(s.opts.armed, false, 'hostage unarmed')
        H.eq(s.opts.role, 'hostage', 'hostage role')
        H.eq(NPC.states[s.netId], 'restrained', 'hostage restrained')
        H.eq(s.opts.cfg.group, 'neutral', 'hostage neutral group')
    end
    local h1, h2, h3 = S.spawned[1].netId, S.spawned[2].netId, S.spawned[3].netId
    H.eq(#NPC.damaged, 1, 'onDamaged listener registered once')
    -- hostile fire while objective 1 is current: hurt, no penalty
    NPC.damaged[1](ctx.run, h2, nil)
    H.eq(#S.penalties, 0, 'NPC damage costs nothing')
    -- participant fire: -hitPenalty, the same bullet via two channels counts once
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 1, 'participant hit penalised')
    H.eq(S.penalties[1].id, 'hostage_hit', 'penalty id')
    H.eq(S.penalties[1].opts.points, -50, 'penalty value hint')
    H.eq(S.penalties[1].opts.src, nil, 'hostage_hit is shared')
    H.eq(PR.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event accepted')
    H.eq(#S.penalties, 1, 'same hit through shot + onDamaged counts once')
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 1, 'the same bullet reported twice by onDamaged counts once')
    AdvanceMs(1500)
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 2, 'a later hit counts again')
    NPC.damaged[1](ctx.run, h1, 55)
    H.eq(#S.penalties, 2, 'non-participant hit costs nothing')
    -- 'shot' / 'damaged' can also arrive as client evidence (same shape through server:objective):
    -- while CP.Npc.onDamaged is listened to they are acknowledged and change nothing
    AdvanceMs(1500)
    H.eq(PR.onEvent(ctx, 1, { type = 'damaged', netId = h1, attacker = 1 }), true, 'damaged event acknowledged')
    H.eq(PR.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event acknowledged')
    H.eq(#S.penalties, 2, 'forgeable shot/damaged events never cost hostage_hit')

    PR.start(ctx)
    H.eq(LastHud(S, 'detail'), 'block.protect_rescue.detail', 'pr HUD line when current')
    local ok, why = PR.onEvent(ctx, 1, { type = 'free_start', netId = h1 })
    H.eq(why, 'too_far', 'free_start from the start point is too far')
    NearTo(1, S, h1)
    H.eq(PR.onEvent(ctx, 1, { type = 'free_start', netId = h1 }), true, 'free_start in range')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h1 })
    H.eq(why, 'too_fast', 'freed right away is too fast')
    AdvanceMs(6000)
    H.eq(PR.onEvent(ctx, 1, { type = 'freed', netId = h1 }), true, 'freed after freeTime')
    H.eq(NPC.states[h1], 'freed', 'bag freed')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h1 })
    H.eq(why, 'duplicate', 'freed twice')
    NearTo(1, S, h2)
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h2 })
    H.eq(why, 'not_started', 'freed without free_start')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = 424242 })
    H.eq(why, 'unknown_entity', 'freed unknown hostage')
    local cl = PR.checklist(ctx)
    H.eq(cl[1].value, 1, 'checklist freed 1')
    H.eq(cl[1].max, 3, 'checklist max 3')
    H.eq(cl[2].value, 0, 'none safe yet')

    -- the service record: one rescue for every participant per hostage brought to safety
    local savedRuns, rescues = CP.Runs, {}
    CP.Runs = setmetatable({
        noteStat = function(run, src, key, n) rescues[#rescues + 1] = { src = src, key = key, n = n } end,
    }, { __index = savedRuns or {} })
    MoveEnt(S, h1, 2051, 2001, 20)
    PR.tick(ctx, 1)
    H.eq(NPC.states[h1], 'safe', 'freed hostage safe within safeRadius')
    H.eq(S.completes, 0, 'not complete until every hostage is safe')
    for _, h in ipairs({ h2, h3 }) do
        NearTo(1, S, h)
        PR.onEvent(ctx, 1, { type = 'free_start', netId = h })
        AdvanceMs(6000)
        H.eq(PR.onEvent(ctx, 1, { type = 'freed', netId = h }), true, 'free the others')
        MoveEnt(S, h, 2049, 1999, 20)
    end
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete when every hostage is safe')
    CP.Runs = savedRuns
    H.eq(#rescues, 3, 'pr: one rescues stat per hostage at the safe marker')
    H.ok(rescues[1] and rescues[1].key == 'rescues' and rescues[1].src == nil and rescues[1].n == 1,
        'pr: rescues counts for every participant')
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 0, 'hurt hostages: no no_hostage_hurt')
    H.eq(#S.fails, 0, 'no fail')
end

do -- hostage_hit: a hit by someone who left the run is not participant fire
    Place(1, 1990, 2000, 20)
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2, srcs = { 1, 2 } })
    PR.prepare(ctx)
    local h1 = S.spawned[1].netId
    ctx.run.participants[2].status = 'left'
    S.active = { 1 }
    NPC.damaged[1](ctx.run, h1, 2)
    H.eq(#S.penalties, 0, 'a hit by a participant who left costs nothing')
    H.eq(ctx.state.hurt, true, 'the hostage still counts as hurt')
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 1, 'an active participant hit still costs hostage_hit')
end

do -- clean rescue: no_hostage_hurt once, completion retried after minSeconds
    Place(1, 1990, 2000, 20)
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.start(ctx)
    for _, s in ipairs(S.spawned) do
        NearTo(1, S, s.netId)
        PR.onEvent(ctx, 1, { type = 'free_start', netId = s.netId })
        AdvanceMs(5000)
        PR.onEvent(ctx, 1, { type = 'freed', netId = s.netId })
        MoveEnt(S, s.netId, 2050, 2000, 20)
    end
    H.near(PR.presence(ctx, 1, vec3(2050, 2010, 20)), 10, 0.01, 'pr presence = nearest hostage')
    S.minOk = false
    PR.tick(ctx, 1)
    H.eq(S.completes, 0, 'refused before minSeconds')
    S.minOk = true
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'completed next tick')
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 1, 'no_hostage_hurt awarded once')
end

do -- deaths
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[1].netId, nil)
    H.eq(S.fails[1], 'block.protect_rescue.fail_died', 'hostage death fails (failIfDies)')

    ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[2].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed a hostage')

    ctx, S = MakeCtx('protect_rescue', { failIfDies = false }, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[1].netId, nil)
    H.eq(#S.fails, 0, 'failIfDies = false: no fail')
    PR.onEntityDead(ctx, S.spawned[2].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant kill fails even with failIfDies = false')

    ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    W.ents[S.spawned[3].entity].exists = false
    PR.start(ctx)
    H.eq(S.fails[1], 'block.protect_rescue.fail_died', 'a vanished hostage counts as dead')
end

do -- rescale before spawning, restrained = false, restart
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    S.can = false
    PR.prepare(ctx)
    ctx.obj = PR.defaults({ count = 2 })
    PR.rescale(ctx)
    S.can = true
    PR.start(ctx)
    H.eq(#S.spawned, 2, 'rescale: only the new count spawns')
    H.step(1000)
    H.eq(#S.spawned, 2, 'retry thread spawns nothing more')

    ctx, S = MakeCtx('protect_rescue', { restrained = false }, prLoc, { index = 2 })
    PR.prepare(ctx)
    H.eq(NPC.states[S.spawned[1].netId], 'idle', 'not restrained: idle until current')
    PR.start(ctx)
    H.eq(NPC.states[S.spawned[1].netId], 'freed', 'not restrained: walk to safety at start')

    ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.start(ctx)
    PR.restart(ctx)
    H.eq(#S.deleted, 3, 'pr restart deleted hostages')
    H.eq(#S.spawned, 6, 'pr restart respawned hostages')
    H.eq(NPC.states[S.spawned[6].netId], 'restrained', 'respawned restrained')
end

-- ============================================================================
--                                 flee_arrest
-- ============================================================================

do -- defaults, validate, armedCount, requiredPoints
    local d = FA.defaults({})
    H.eq(d.mode, 'door', 'fa default mode')
    H.eq(d.minSeconds, 30, 'fa minSeconds')
    H.eq(d.presenceRange, 250, 'fa presence')
    H.near(d.responses.surrender, 0.5, 1e-9, 'surrender 0.5')
    H.near(d.responses.flee, 0.3, 1e-9, 'flee 0.3')
    H.near(d.responses.fight, 0.2, 1e-9, 'fight 0.2')
    H.eq(d.associates.count, 1, 'one associate')
    H.eq(d.associates.spawns, 'associates', 'associate key')
    H.eq(d.associates.weapons[1], 'WEAPON_PISTOL', 'associate weapons')
    H.eq(d.knock.label, 'block.flee_arrest.knock', 'knock label locale')
    H.eq(d.knock.duration, 3000, 'knock duration')
    H.eq(d.cuff.duration, 5000, 'cuff duration')
    H.eq(d.cuff.label, 'block.flee_arrest.cuff', 'cuff label locale')
    H.eq(d.escape.distance, 400, 'escape distance')
    H.eq(d.escape.seconds, 20, 'escape seconds')
    H.eq(d.givesUp.aim, 10.0, 'aim distance')
    H.eq(d.givesUp.stun, true, 'stun')
    H.eq(d.givesUp.close.distance, 3.0, 'close distance')
    H.eq(d.givesUp.close.seconds, 3, 'close seconds')
    H.eq(d.armedGivesUp.stun, true, 'armed stun')
    H.eq(d.armedGivesUp.belowHealth, 0.5, 'armed below health')
    H.eq(d.aliveBonus.id, 'suspect_alive', 'alive bonus id')
    H.eq(d.fireWithin, 15.0, 'fireWithin')
    H.eq(d.door, 'door', 'door key')
    H.eq(d.fleeTo, 'fleeTo', 'fleeTo key')
    local s = FA.defaults({ mode = 'scatter' })
    H.eq(s.suspects, 5, 'scatter suspects')
    H.near(s.armedShare, 0.4, 1e-9, 'scatter armedShare')
    H.eq(s.models[1], 's_m_y_prisoner_01', 'prison model')
    H.eq(s.spawns, 'spawns', 'scatter spawns')
    H.eq(s.routes, 'routes', 'routes')
    local l = FA.defaults({ givesUp = { 'aim', 'close' } })
    H.eq(l.givesUp.aim, 10.0, 'list form aim')
    H.eq(l.givesUp.stun, false, 'list form no stun')
    H.eq(type(l.givesUp.close), 'table', 'list form close')
    local p = FA.defaults({ responses = { surrender = 0.7, flee = 0.3 } })
    H.eq(p.responses.fight, 0, 'partial responses: missing ones are 0')

    H.eq(FA.validate({}, builtin, doorLoc), true, 'fa door valid')
    H.eq(FA.validate({}, custom, doorLoc), true, 'fa door valid custom')
    local ok, why = FA.validate({ responses = { surrender = 0.6, flee = 0.3, fight = 0.3 } }, builtin, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.responses', 'responses must add up to 1')
    H.eq(FA.validate({ escape = { distance = 50 } }, builtin, doorLoc), false, 'escape distance out of range')
    H.eq(FA.validate({ escape = { seconds = 5 } }, builtin, doorLoc), false, 'escape seconds out of range')
    H.eq(FA.validate({ givesUp = { aim = 30 } }, builtin, doorLoc), false, 'aim distance out of range')
    ok, why = FA.validate({ mode = 'chase' }, builtin, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.mode', 'bad mode')
    ok, why = FA.validate({ door = 'backdoor' }, builtin, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.points_missing', 'door point missing')
    ok, why = FA.validate({ models = { 'a_m_y_hipster_01' } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.models', 'custom model must be allowed')
    ok, why = FA.validate({ associates = { count = 5 } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.points_count', 'custom associates need spawn points')
    H.eq(FA.validate({ mode = 'scatter' }, builtin, scatterLoc), true, 'fa scatter valid')
    ok, why = FA.validate({ mode = 'scatter' }, builtin, prisonLoc)
    H.eq(why, 'block.flee_arrest.invalid.points_zone', 'scatter spawns inside the prison refused, even builtin')
    H.eq(FA.validate({ mode = 'scatter', suspects = 20 }, builtin, scatterLoc), false, 'suspects out of range')
    H.eq(FA.validate({ mode = 'scatter', armedShare = 1.5 }, builtin, scatterLoc), false, 'armedShare out of range')
    ok, why = FA.validate({ mode = 'scatter', routes = 'escape' }, builtin, scatterLoc)
    H.eq(why, 'block.flee_arrest.invalid.points_missing', 'routes missing')
    H.eq(FA.armedCount({}), 2, 'door: associate + suspect who may fight')
    H.eq(FA.armedCount({ responses = { surrender = 0.5, flee = 0.5, fight = 0 }, associates = { count = 2 } }), 2,
        'door without fight')
    H.eq(FA.armedCount({ mode = 'scatter' }), 5, 'scatter: every suspect counts when armedShare > 0')
    H.eq(FA.armedCount({ mode = 'scatter', armedShare = 0 }), 0, 'scatter unarmed')
    local rp = FA.requiredPoints({})
    H.eq(table.concat(rp, ','), 'door,suspect,fleeTo,associates', 'door required points')
    H.eq(table.concat(FA.requiredPoints({ mode = 'scatter' }), ','), 'spawns,routes', 'scatter required points')
    H.eq(FA.onTimeout({}), nil, 'fa onTimeout fails')

    -- custom missions: a standard alive-bonus id with no value of its own, the fixed 3 m / 3 s give-up rule,
    -- 1-30 s knock and cuff, a cuff no further than 3 m
    ok, why = FA.validate({ aliveBonus = { id = 'suspect_alive', points = 100000 } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.alive_bonus_custom', 'fa custom: aliveBonus.points rejected')
    ok, why = FA.validate({ aliveBonus = { id = 'suspect_alive', pctOfPoints = 0.5 } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.alive_bonus_custom', 'fa custom: aliveBonus.pctOfPoints rejected')
    ok, why = FA.validate({ aliveBonus = { id = 'inmate_alive' } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.alive_bonus_custom', 'fa custom: an id outside Config.Bonuses rejected')
    ok, why = FA.validate({ aliveBonus = { id = 'medal_gold' } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.alive_bonus_custom', 'fa custom: a medal id rejected')
    H.eq(FA.validate({ aliveBonus = { id = 'suspect_alive' } }, custom, doorLoc), true,
        'fa custom: suspect_alive without points passes')
    H.eq(FA.validate({ aliveBonus = { id = 'inmate_alive', points = 10, each = true } }, builtin, doorLoc), true,
        'fa builtin: Prison Break bonus trusted')
    ok, why = FA.validate({ givesUp = { aim = 10, stun = true, close = { distance = 500, seconds = 0.1 } } }, custom,
        doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.gives_up_close', 'fa custom: 500 m / 0.1 s give-up rejected')
    ok, why = FA.validate({ givesUp = { aim = 10, stun = true, close = { distance = 3.0, seconds = 1 } } }, custom,
        doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.gives_up_close', 'fa custom: 3 m / 1 s give-up rejected')
    H.eq(FA.validate({ givesUp = { aim = 10, stun = true, close = false } }, custom, doorLoc), true,
        'fa custom: close rule off passes')
    H.eq(FA.validate({ givesUp = { 'aim', 'stun', 'close' } }, custom, doorLoc), true,
        'fa custom: builder list form (3 m / 3 s) passes')
    H.eq(FA.validate(
        { givesUp = { aim = 10, stun = true, close = { distance = 500, seconds = 0.1 } } },
        builtin,
        doorLoc
    ), true, 'fa builtin: give-up trusted')
    for _, case in ipairs({
        { { knock = { duration = 100 } }, 'knock 0.1 s' },
        { { knock = { duration = 60000 } }, 'knock 60 s' },
        { { cuff = { duration = 300 } }, 'cuff 0.3 s' },
        { { cuff = { duration = 45000 } }, 'cuff 45 s' },
        { { cuff = { maxDistance = 25.0 } }, 'cuff from 25 m' },
    }) do
        ok, why = FA.validate(case[1], custom, doorLoc)
        H.eq(why, 'block.flee_arrest.invalid.range', 'fa custom: ' .. case[2] .. ' rejected')
        H.eq(FA.validate(case[1], builtin, doorLoc), true, 'fa builtin: ' .. case[2] .. ' trusted')
    end
end

-- aliveBonus.points is passed as a hint only for built-in files (Prison Break's inmate_alive +10 each)
do
    local function CuffAtDoor(mission)
        Place(1, 3000, 3000, 10)
        local ctx, S = MakeCtx('flee_arrest', {
            responses = { surrender = 1, flee = 0, fight = 0 },
            associates = { count = 0 },
            aliveBonus = { id = 'suspect_alive', points = 999 },
        }, doorLoc, { mission = mission })
        FA.prepare(ctx)
        FA.start(ctx)
        Place(1, 3041, 3000, 10)
        FA.onEvent(ctx, 1, { type = 'knock_start' })
        AdvanceMs(3000)
        FA.onEvent(ctx, 1, { type = 'knock' })
        local sus = WithRole(S, 'suspect')[1]
        NPC.states[sus.netId] = 'cuffed'
        Place(1, 3039.5, 3000, 10)
        FA.onEvent(ctx, 1, { type = 'cuffed', netId = sus.netId })
        return AwardsOf(S, 'suspect_alive')
    end
    local c = CuffAtDoor(custom)
    H.eq(#c, 1, 'fa custom: suspect_alive awarded')
    H.eq(c[1] and c[1].opts.points, nil, 'fa custom: the file points are never passed as a hint')
    local b = CuffAtDoor(builtin)
    H.eq(b[1] and b[1].opts.points, 999, 'fa builtin: the file points stay the hint')
end

local function KnockOpen(ctx, S)
    Place(1, 3041, 3000, 10)
    FA.onEvent(ctx, 1, { type = 'knock_start' })
    AdvanceMs(3000)
    return FA.onEvent(ctx, 1, { type = 'knock' })
end

do -- door: surrender at the door, knock checks, cuff, associate, completion
    Place(1, 3000, 3000, 10)
    local ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 1, flee = 0, fight = 0 } }, doorLoc)
    FA.prepare(ctx)
    FA.start(ctx)
    H.eq(#S.spawned, 2, 'suspect + 1 associate spawned')
    local sus, asc = WithRole(S, 'suspect')[1], WithRole(S, 'associate')[1]
    H.eq(sus.opts.armed, false, 'surrendering suspect unarmed')
    H.eq(asc.opts.armed, true, 'associate armed')
    H.eq(asc.opts.weapon, 'WEAPON_PISTOL', 'associate pistol')
    H.eq(asc.opts.accuracy, 35, 'associate accuracy + tier')
    H.eq(asc.opts.armour, 25, 'associate armour + tier')
    H.near(sus.opts.coords.x, 3045, 0.01, 'suspect inside at the suspect point')
    H.eq(LastHud(S, 'detail'), 'block.flee_arrest.detail_knock', 'HUD asks to knock')
    FA.tick(ctx, 1)
    H.eq(S.completes, 0, 'nothing before the knock')
    local ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'too_far', 'knock from the start is too far')
    Place(1, 3041, 3000, 10)
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'not_started', 'knock without knock_start')
    H.eq(FA.onEvent(ctx, 1, { type = 'knock_start' }), true, 'knock_start at the door')
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'too_fast', 'knock finished too fast')
    AdvanceMs(3000)
    H.eq(FA.onEvent(ctx, 1, { type = 'knock' }), true, 'knock accepted')
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'duplicate', 'second knock')
    H.eq(NPC.states[sus.netId], 'surrendered', 'suspect surrendered at the door')
    H.near(PosOf(S, sus.netId).x, 3039, 0.01, 'suspect placed 1 m outside the door')
    H.eq(NPC.cuffs[sus.netId].duration, 5000, 'cuff enabled with cuff.duration')
    H.eq(NPC.states[asc.netId], 'hostile', 'associate fights')
    H.eq(LastHud(S, 'message').text, 'block.flee_arrest.response_surrender', 'response message')
    H.eq(LastSend(S).knocked, true, 'clients told about the knock')

    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = asc.netId })
    H.eq(why, 'armed', 'aiming does not make an armed associate give up')
    NPC.states[sus.netId] = 'cuffed'
    Place(1, 3039.5, 3000, 10)
    local savedRunsFA, arrestsFA = CP.Runs, {}
    CP.Runs = setmetatable({
        noteArrest = function(run, src, netId) arrestsFA[#arrestsFA + 1] = { src = src, netId = netId } end,
    }, { __index = savedRunsFA or {} })
    H.eq(FA.onEvent(ctx, 1, { type = 'cuffed', netId = sus.netId }), true, 'suspect cuffed')
    CP.Runs = savedRunsFA
    H.ok(#arrestsFA == 1 and arrestsFA[1].src == 1 and arrestsFA[1].netId == sus.netId, 'fa: the cuff notes one arrest')
    local sa = AwardsOf(S, 'suspect_alive')
    H.eq(#sa, 1, 'suspect_alive awarded')
    H.eq(sa[1].opts.count, 1, 'count 1')
    local cl = FA.checklist(ctx)
    H.eq(cl[1].done, true, 'checklist knock')
    H.eq(cl[2].done, true, 'checklist suspect')
    H.eq(cl[3].done, false, 'associate left')
    H.near(FA.presence(ctx, 1, vec3(3046, 3015, 10)), 10, 0.01, 'presence = nearest suspect not cuffed')
    FA.onEntityDead(ctx, asc.netId, 1)
    H.eq(#S.fails, 0, 'killing an armed associate is fine')
    FA.tick(ctx, 1)
    H.eq(S.completes, 1, 'door complete')
    H.eq(#AwardsOf(S, 'suspect_alive'), 1, 'associates earn nothing')
end

do -- door: a suspect who waits on the door step (the built-in houses) is placed outside, never inside
    local function SurrenderAt(loc)
        Place(1, 3000, 3000, 10)
        local ctx, S = MakeCtx('flee_arrest',
            { responses = { surrender = 1, flee = 0, fight = 0 }, associates = { count = 0 } }, loc)
        FA.start(ctx)
        local sus = WithRole(S, 'suspect')[1]
        H.eq(KnockOpen(ctx, S), true, 'door placement: knock')
        H.eq(NPC.states[sus.netId], 'surrendered', 'door placement: surrendered')
        return PosOf(S, sus.netId), W.ents[EntOf(S, sus.netId)].heading
    end
    -- the Warrant Service layout: door heading faces out (west, towards the start), the suspect 0.3 m out
    -- and 1.2 m beside the door. The old "1 m past the door, away from where he waited" moved him inside.
    local step = {
        label = 'Step',
        start = doorLoc.start,
        door = vec4(3040.0, 3000.0, 10.0, 90.0),
        suspect = vec4(3039.7, 3001.2, 10.0, 90.0),
        fleeTo = doorLoc.fleeTo,
        associates = doorLoc.associates,
        yard = doorLoc.yard,
    }
    local p, h = SurrenderAt(step)
    H.near(p.x, 3039.0, 0.01, 'door step: 1 m in front of the door (out = the door heading)')
    H.near(p.y, 3000.0, 0.01, 'door step: in line with the door')
    H.near(h or -1, 90.0, 0.01, 'door step: facing out')
    -- a door heading that points into the house (placed while facing the door): the start decides "out"
    local inward = {
        label = 'Inward',
        start = doorLoc.start,
        door = vec4(3040.0, 3000.0, 10.0, 270.0),
        suspect = vec4(3045.0, 3000.0, 10.0, 270.0),
        fleeTo = doorLoc.fleeTo,
        associates = doorLoc.associates,
        yard = doorLoc.yard,
    }
    p, h = SurrenderAt(inward)
    H.near(p.x, 3039.0, 0.01, 'inward heading: turned round towards the start')
    H.near(h or -1, 90.0, 0.01, 'inward heading: facing out')
    -- a door without a heading faces the start
    local plain = {
        label = 'Plain',
        start = { coords = vec3(3040.0, 2950.0, 10.0), radius = 50.0 },
        door = vec3(3040.0, 3000.0, 10.0),
        suspect = vec4(3041.2, 3000.3, 10.0, 0.0),
        fleeTo = doorLoc.fleeTo,
        associates = doorLoc.associates,
        yard = doorLoc.yard,
    }
    p = SurrenderAt(plain)
    H.near(p.x, 3040.0, 0.01, 'door without heading: in line with the door')
    H.near(p.y, 2999.0, 0.01, 'door without heading: 1 m towards the start')
end

do -- door: flee response, aim and escape
    Place(1, 3000, 3000, 10)
    local ctx, S = MakeCtx('flee_arrest',
        { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    H.eq(#S.spawned, 1, 'no associates')
    local sus = S.spawned[1]
    H.eq(KnockOpen(ctx, S), true, 'knock')
    H.eq(NPC.states[sus.netId], 'fleeing', 'suspect flees')
    H.eq(type(sus.opts.cfg.fleePoints), 'table', 'flee points in the bag cfg')
    Place(1, 3000, 3000, 10)
    local ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId })
    H.eq(why, 'too_far', 'aim from 45 m is too far')
    NearTo(1, S, sus.netId, 5.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId }), true, 'aim within 10 m')
    H.eq(NPC.states[sus.netId], 'surrendered', 'gave up on aim')
    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId })
    H.eq(why, 'duplicate', 'aim again')

    -- escape: more than escape.distance from every participant for escape.seconds
    Place(1, 3000, 3000, 10)
    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } },
        doorLoc)
    FA.start(ctx)
    KnockOpen(ctx, S)
    Place(1, 3600, 3000, 10)
    for _ = 1, 10 do FA.tick(ctx, 1) end
    H.eq(LastHud(S, 'detail'), 'block.flee_arrest.escaping', 'escape warning on the HUD')
    H.eq(LastSend(S).escaping, 10, 'escape countdown sent to clients')
    Place(1, 3050, 3000, 10)
    FA.tick(ctx, 1)
    Place(1, 3600, 3000, 10)
    for _ = 1, 19 do FA.tick(ctx, 1) end
    H.eq(#S.fails, 0, 'coming back reset the escape timer')
    FA.tick(ctx, 1)
    H.eq(S.fails[1], 'block.flee_arrest.fail_escaped', 'suspect escaped')

    -- killing the unarmed fleeing suspect fails
    Place(1, 3000, 3000, 10)
    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } },
        doorLoc)
    FA.start(ctx)
    KnockOpen(ctx, S)
    FA.onEntityDead(ctx, S.spawned[1].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'killed an unarmed fleeing suspect')
end

do -- door: fight response, stun, low health, death before the knock
    Place(1, 3000, 3000, 10)
    local ctx, S = MakeCtx('flee_arrest',
        { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    local sus = S.spawned[1]
    H.eq(sus.opts.armed, true, 'fighting suspect armed (counts toward the armed cap)')
    H.eq(sus.opts.weapon, nil, 'fighting suspect: no pistol in sight before the knock')
    local given = #W.weapons
    FA.tick(ctx, 1)
    H.eq(#W.weapons, given, 'fighting suspect: still no pistol while he waits')
    KnockOpen(ctx, S)
    H.eq(NPC.states[sus.netId], 'hostile', 'suspect fights')
    local gw = W.weapons[#W.weapons]
    H.eq(#W.weapons, given + 1, 'fighting suspect: the pistol is given at the knock')
    H.ok(gw and gw.e == sus.entity and gw.w == joaat('WEAPON_PISTOL') and gw.inHand == true,
        'fighting suspect: the pistol in hand')
    local ex = NPC.extra[sus.netId]
    H.eq(ex and ex.cfg and ex.cfg.weapon, 'WEAPON_PISTOL', 'fighting suspect: the bag cfg gets the pistol (new host)')
    Place(1, 3200, 3000, 10)
    local ok, why = FA.onEvent(ctx, 1, { type = 'stunned', netId = sus.netId })
    H.eq(why, 'too_far', 'stun needs a participant nearby')
    NearTo(1, S, sus.netId, 8.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = sus.netId }), true, 'armed suspect gives up when stunned')
    H.eq(NPC.states[sus.netId], 'surrendered', 'surrendered after stun')

    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } },
        doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    KnockOpen(ctx, S)
    NearTo(1, S, sus.netId, 20.0)
    ok, why = FA.onEvent(ctx, 1, { type = 'low_health', netId = sus.netId })
    H.eq(why, 'health_ok', 'low_health refused at full health')
    SetHealth(S, sus.netId, 140)
    FA.tick(ctx, 1)
    H.eq(NPC.states[sus.netId], 'surrendered', 'armed suspect gives up below 50% health (server poll)')

    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } },
        doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    KnockOpen(ctx, S)
    H.eq(FA.onEvent(ctx, 1, { type = 'damaged', netId = sus.netId, attacker = 1 }), true,
        'damaged at full health accepted')
    H.eq(NPC.states[sus.netId], 'hostile', 'still fighting')
    SetHealth(S, sus.netId, 130)
    H.eq(FA.onEvent(ctx, 1, { type = 'damaged', netId = sus.netId, attacker = 1 }), true, 'damaged below 50%')
    H.eq(NPC.states[sus.netId], 'surrendered', 'damaged path makes the armed suspect give up')

    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } },
        doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    KnockOpen(ctx, S)
    FA.onEntityDead(ctx, sus.netId, 1)
    H.eq(#S.fails, 0, 'killing the suspect while he fights is allowed')
    FA.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete: suspect killed while fighting')
    H.eq(#AwardsOf(S, 'suspect_alive'), 0, 'no suspect_alive for a dead suspect')

    Place(1, 3000, 3000, 10)
    ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 } }, doorLoc)
    FA.start(ctx)
    FA.onEntityDead(ctx, WithRole(S, 'associate')[1].netId, 1)
    H.eq(ctx.state.knocked, true, 'a death before the knock reveals the response')
    H.eq(NPC.states[WithRole(S, 'suspect')[1].netId], 'hostile', 'suspect reacts')
end

do -- door: associates wait for room and rescale
    Place(1, 3000, 3000, 10)
    local ctx, S = MakeCtx('flee_arrest',
        { responses = { surrender = 1, flee = 0, fight = 0 }, associates = { count = 3 } }, doorLoc)
    S.canLimit = 2
    FA.start(ctx)
    H.eq(#S.spawned, 2, 'suspect + 1 associate fit')
    ctx.obj = FA.defaults({ responses = { surrender = 1, flee = 0, fight = 0 }, associates = { count = 2 } })
    FA.rescale(ctx)
    S.canLimit = nil
    FA.tick(ctx, 1)
    H.eq(#WithRole(S, 'associate'), 2, 'rescale: associates topped up to the new count')
    FA.tick(ctx, 1)
    H.eq(#WithRole(S, 'associate'), 2, 'no extra associates')
end

do -- scatter: spawn, armed share, fire range, aim/stun/close/health give-ups, cuffs, completion
    Place(1, 4000, 4000, 30)
    local ctx, S = MakeCtx('flee_arrest',
        { mode = 'scatter', aliveBonus = { id = 'inmate_alive', points = 10, each = true } }, scatterLoc)
    FA.prepare(ctx)
    FA.start(ctx)
    H.eq(#S.spawned, 5, '5 inmates')
    local armed = U.filter(S.spawned, function(s) return s.opts.armed end)
    local unarmed = U.filter(S.spawned, function(s) return not s.opts.armed end)
    H.eq(#armed, 2, '2 in every 5 armed')
    for _, s in ipairs(S.spawned) do
        H.eq(s.opts.role, 'inmate', 'inmate role')
        H.eq(s.opts.model, 's_m_y_prisoner_01', 'prison clothes')
        H.eq(NPC.states[s.netId], 'fleeing', 'inmates flee')
        H.ok(s.opts.cfg.route == 1 or s.opts.cfg.route == 2, 'route assigned')
        H.eq(type(s.opts.cfg.fleePoints), 'table', 'route points in cfg')
    end
    for _, s in ipairs(armed) do H.eq(s.opts.weapon, 'WEAPON_PISTOL', 'armed with a pistol') end
    H.eq(LastHud(S, 'detail'), 'block.flee_arrest.detail_scatter', 'scatter HUD line')

    local a1, a2 = armed[1].netId, armed[2].netId
    local c = PosOf(S, a1)
    Place(1, c.x, c.y + 10, c.z)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a1], 'hostile', 'armed inmate fires when a participant is within fireWithin')
    Place(1, c.x, c.y + 30, c.z)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a1], 'fleeing', 'back to fleeing once clear')
    local ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = a1 })
    H.eq(why, 'armed', 'armed inmates ignore aim')
    NearTo(1, S, a1, 5.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = a1 }), true, 'armed inmate stunned')
    H.eq(NPC.states[a1], 'surrendered', 'armed inmate gave up')
    NearTo(1, S, a2, 12.0)
    SetHealth(S, a2, 140)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a2], 'surrendered', 'armed inmate below 50% gives up')

    local u1, u2, u3 = unarmed[1].netId, unarmed[2].netId, unarmed[3].netId
    NearTo(1, S, u1, 20.0)
    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = u1 })
    H.eq(why, 'too_far', 'aim from 20 m refused')
    NearTo(1, S, u1, 6.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'aim', netId = u1 }), true, 'aim within 10 m')
    NearTo(1, S, u2, 2.0)
    FA.tick(ctx, 1)
    FA.tick(ctx, 1)
    H.eq(NPC.states[u2], 'fleeing', 'close for 2 s: not yet')
    FA.tick(ctx, 1)
    H.eq(NPC.states[u2], 'surrendered', 'close for 3 s: gives up')
    NearTo(1, S, u3, 8.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = u3 }), true, 'unarmed inmate stunned')

    local cl = FA.checklist(ctx)
    H.eq(cl[1].max, 5, 'scatter checklist max')
    H.eq(cl[1].value, 0, 'none in custody yet')
    for _, s in ipairs(S.spawned) do NPC.states[s.netId] = 'cuffed' end
    FA.tick(ctx, 1)
    local ia = AwardsOf(S, 'inmate_alive')
    H.eq(#ia, 5, 'inmate_alive for every inmate cuffed alive')
    H.eq(ia[1].opts.points, 10, 'inmate_alive points hint')
    H.eq(S.completes, 1, 'scatter complete when every inmate is in custody')
    H.eq(#S.fails, 0, 'no fail')
end

do -- scatter: caps, rescale, escape, no spawn inside the prison, killing an unarmed inmate
    Place(1, 4000, 4000, 30)
    local ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    S.can = false
    FA.start(ctx)
    H.eq(#S.spawned, 0, 'scatter waits for room')
    S.can = true
    FA.tick(ctx, 1)
    H.eq(#S.spawned, 5, 'scatter spawned when room frees')

    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    S.canLimit = 3
    FA.start(ctx)
    H.eq(#S.spawned, 3, '3 of 5 fit')
    ctx.obj = FA.defaults({ mode = 'scatter', suspects = 4 })
    FA.rescale(ctx)
    S.canLimit = nil
    FA.tick(ctx, 1)
    H.eq(#S.spawned, 4, 'rescale: only the missing inmate')
    local armedN = #U.filter(S.spawned, function(s) return s.opts.armed end)
    H.ok(armedN <= 2, 'armed never above round(4 x 0.4)')
    H.eq(FA.checklist(ctx)[1].max, 4, 'checklist follows the rescale')

    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter', escape = { distance = 600, seconds = 30 } }, scatterLoc)
    FA.start(ctx)
    Place(1, 5000, 5000, 30)
    for _ = 1, 29 do FA.tick(ctx, 1) end
    H.eq(#S.fails, 0, 'not escaped before escape.seconds')
    FA.tick(ctx, 1)
    H.eq(S.fails[1], 'block.flee_arrest.fail_escaped', 'inmate escaped after 30 s beyond 600 m')

    Place(1, 1900, 2600, 45)
    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, prisonLoc)
    FA.start(ctx)
    H.eq(#S.spawned, 0, 'nothing spawns inside the prison walls')
    H.eq(S.fails[1], 'block.flee_arrest.fail_setup', 'no usable spawn point fails the setup')

    local mixed = {
        label = 'Mixed',
        start = scatterLoc.start,
        routes = scatterLoc.routes,
        spawns = { vec4(1770.0, 2570.0, 45.0, 0.0), vec4(4040.0, 4000.0, 30.0, 0.0), vec4(4060.0, 4000.0, 30.0, 0.0) },
    }
    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter', suspects = 4 }, mixed)
    FA.start(ctx)
    H.eq(#S.spawned, 4, 'mixed points: all inmates spawned')
    local inside = 0
    for _, s in ipairs(S.spawned) do if s.opts.coords.x < 2000 then inside = inside + 1 end end
    H.eq(inside, 0, 'the point inside the prison is never used')

    Place(1, 4000, 4000, 30)
    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    FA.start(ctx)
    local un = U.filter(S.spawned, function(s) return not s.opts.armed end)[1]
    FA.onEntityDead(ctx, un.netId, 77)
    H.eq(#S.fails, 0, 'an outsider kill is not a participant kill')
    local un2 = U.filter(S.spawned, function(s) return not s.opts.armed end)[2]
    FA.onEntityDead(ctx, un2.netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed an unarmed inmate')

    ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    FA.start(ctx)
    FA.restart(ctx)
    H.eq(#S.deleted, 5, 'fa restart deleted inmates')
    H.eq(#S.spawned, 10, 'fa restart respawned inmates')
    FA.stop(ctx)
    FA.tick(ctx, 1)
    H.eq(#S.spawned, 10, 'stopped: nothing more')
end

-- ============================================================================
--                PARITY OPTIONS: flee_arrest and hostile_waves
-- ============================================================================
-- Demeanour weights, feint, custody hand-over; behaviour and spawn sets per seed, the intel line, feel.

local function Tick(impl, ctx, n)
    for _ = 1, n or 1 do
        AdvanceMs(1000)
        impl.tick(ctx, 1)
    end
end

do -- flee_arrest: validation of the new options
    H.eq(FA.validate({ demeanour = 'runner' }, custom, doorLoc), true, 'fa parity: a fixed demeanour validates')
    H.eq(FA.validate({ demeanour = { compliant = 50, runner = 50 } }, custom, doorLoc), true,
        'fa parity: weights validate')
    local ok, why = FA.validate({ demeanour = 'sleepy' }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.demeanour', 'fa parity: an unknown demeanour refused')
    ok, why = FA.validate({ demeanour = { bored = 1 } }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.demeanour', 'fa parity: an unknown weight refused')
    H.eq(FA.validate({ feint = 0.6 }, custom, doorLoc), false, 'fa parity: feint above 50% refused')
    ok, why = FA.validate({ custody = 'jail' }, custom, doorLoc)
    H.eq(why, 'block.flee_arrest.invalid.custody', 'fa parity: an unknown custody refused')
    H.eq(FA.defaults({}).custody, 'cuff', 'fa parity: cuff only by default')
    H.eq(FA.defaults({}).feint, 0, 'fa parity: no feint by default')
end

do -- demeanour weights decide the door response, from the seed
    local function Door(dem, seed)
        H.clockMs = 5000000
        local ctx, S = MakeCtx('flee_arrest', { demeanour = dem, associates = { count = 0 } }, doorLoc, { seed = seed })
        FA.start(ctx)
        return ctx.state.response, ctx.state.demeanour
    end
    H.eq(Door('runner', 1), 'flee', 'fa parity: a runner flees at the knock')
    H.eq(Door('compliant', 1), 'surrender', 'fa parity: a compliant suspect surrenders')
    H.eq(Door('hostile', 1), 'fight', 'fa parity: a hostile suspect fights (armed)')
    local seen = {}
    for i = 1, 20 do
        local seed = 100003 * i + 7919
        local r = Door({ compliant = 50, runner = 50 }, seed)
        seen[r] = (seen[r] or 0) + 1
        H.eq(Door({ compliant = 50, runner = 50 }, seed), r, 'fa parity: the same seed rolls the same demeanour')
    end
    H.ok((seen.surrender or 0) > 0 and (seen.flee or 0) > 0, 'fa parity: weights of 50/50 give both')
    -- scatter: a compliant inmate gives up at once, a runner runs
    H.clockMs = 5100000
    local ctx, S = MakeCtx('flee_arrest', { mode = 'scatter', suspects = 2, armedShare = 0, demeanour = 'compliant' },
        scatterLoc)
    FA.start(ctx)
    for _, s in ipairs(WithRole(S, 'inmate')) do
        H.eq(NPC.states[s.netId], 'surrendered', 'fa parity: a compliant inmate surrenders')
    end
end

do -- feint: only unarmed, only when nobody is within 6 m or aiming for 5 s; killing a feinting suspect still fails
    H.clockMs = 5200000
    -- the people debrief (CP.Runs.notePerson): a person with a demeanour, and what they did
    local savedRunsDb, notes = CP.Runs, {}
    CP.Runs = setmetatable({
        notePerson = function(run, netId, patch)
            local e = notes[netId] or { did = {} }
            notes[netId] = e
            e.label, e.demeanour = patch.label or e.label, patch.demeanour or e.demeanour
            if patch.did and e.did[#e.did] ~= patch.did then e.did[#e.did + 1] = patch.did end
            return true
        end,
    }, { __index = savedRunsDb or {} })
    local ctx, S = MakeCtx('flee_arrest',
        { mode = 'scatter', suspects = 1, armedShare = 0, feint = 0.5, demeanour = 'runner' }, scatterLoc,
        { seed = 77 })
    FA.start(ctx)
    local p = WithRole(S, 'inmate')[1]
    local st = ctx.state
    NearTo(1, S, p.netId, 5.0)
    H.players[1].weapon = 'WEAPON_PISTOL'
    FA.onEvent(ctx, 1, { type = 'aim', netId = p.netId })
    H.eq(NPC.states[p.netId], 'surrendered', 'fa feint: gave up when aimed at')
    local rec = st.peds[tostring(p.netId)]
    rec.feintRoll = true   -- this suspect is the one who feints (the roll itself is tested by its weight below)
    NearTo(1, S, p.netId, 3.0)
    Tick(FA, ctx, 8)
    H.eq(NPC.states[p.netId], 'surrendered', 'fa feint: an officer within 6 m keeps him down')
    NearTo(1, S, p.netId, 12.0)
    for _ = 1, 8 do
        FA.onEvent(ctx, 1, { type = 'aim', netId = p.netId })   -- covered from 12 m
        Tick(FA, ctx, 1)
    end
    H.eq(NPC.states[p.netId], 'surrendered', 'fa feint: an officer aiming keeps him down')
    Tick(FA, ctx, 4)
    H.eq(NPC.states[p.netId], 'surrendered', 'fa feint: not while the last aim is under 5 s old')
    Tick(FA, ctx, 7)
    H.eq(NPC.states[p.netId], 'fleeing', 'fa feint: nobody close and nobody aiming for 5 s: he bolts')
    H.eq(rec.feinted, true, 'fa feint: marked as a feint')
    FA.onEntityDead(ctx, p.netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'fa feint: killing a feinting (unarmed) suspect still fails')
    local note = notes[p.netId]
    CP.Runs = savedRunsDb
    H.eq(note and note.demeanour, 'runner', 'fa debrief: the demeanour is noted')
    H.eq(note and note.label, CP.L('block.flee_arrest.person_inmate', { n = 1 }), 'fa debrief: under a readable label')
    H.eq(note and table.concat(note.did, ','), 'ran,surrendered,feinted,ran,killed',
        'fa debrief: what he did, in order (the engine keeps each once)')
    -- an armed suspect never rolls a feint
    local ctx2, S2 = MakeCtx('flee_arrest', { mode = 'scatter', suspects = 1, armedShare = 1.0, feint = 0.5 },
        scatterLoc, { seed = 78 })
    FA.start(ctx2)
    local a = WithRole(S2, 'inmate')[1]
    SetHealth(S2, a.netId, 110)
    FA.onEvent(ctx2, 1, { type = 'low_health', netId = a.netId })
    H.eq(ctx2.state.peds[tostring(a.netId)].feintRoll, false, 'fa feint: never for an armed suspect')
    -- the roll follows its weight: 0 never feints
    local ctx3, S3 = MakeCtx('flee_arrest',
        { mode = 'scatter', suspects = 1, armedShare = 0, feint = 0, demeanour = 'compliant' }, scatterLoc)
    FA.start(ctx3)
    H.eq(ctx3.state.peds[tostring(WithRole(S3, 'inmate')[1].netId)].feintRoll, false, 'fa feint: chance 0 never feints')
end

do -- custody = 'handover': the objective completes only once the cuffed suspect is handed over
    H.clockMs = 5300000
    local chains = {}
    local saved = CP.Custody
    CP.Custody = {
        enableChain = function(run, netId, opts) chains[#chains + 1] = netId return true end,
    }
    local ctx, S = MakeCtx('flee_arrest',
        { mode = 'scatter', suspects = 1, armedShare = 0, custody = 'handover', demeanour = 'compliant' }, scatterLoc)
    FA.start(ctx)
    local p = WithRole(S, 'inmate')[1]
    NPC.states[p.netId] = 'cuffed'
    NearTo(1, S, p.netId, 1.0)
    FA.onEvent(ctx, 1, { type = 'cuffed', netId = p.netId })
    H.eq(chains[1], p.netId, 'fa custody: the custody chain starts after the cuff')
    Tick(FA, ctx, 2)
    H.eq(S.completes, 0, 'fa custody: cuffed is not enough with a hand-over')
    local ok = FA.onEvent(ctx, 1, { type = 'handed_over', netId = p.netId })
    H.eq(ok, true, 'fa custody: handed over')
    H.eq(S.completes, 1, 'fa custody: complete once handed over')
    CP.Custody = saved
end

do -- hostile_waves: behaviour and spawn sets per seed, the intel line, NpcDifficulty feel only
    local setsLoc = HwLocation(12, 6000.0, 6000.0)
    setsLoc.front, setsLoc.house, setsLoc.garage = {}, {}, {}
    for i = 1, 6 do
        setsLoc.front[i] = vec4(6000.0 + i * 5.0, 6060.0, 30.0, 180.0)
        setsLoc.house[i] = vec4(6000.0 + i * 5.0, 6000.0, 30.0, 180.0)
        setsLoc.garage[i] = vec4(6000.0 + i * 5.0, 5940.0, 30.0, 0.0)
    end
    local function Roll(seed)
        H.clockMs = 6000000
        local ctx, S = MakeCtx('hostile_waves', {
            waves = { 4 },
            behaviour = { hold = 0.3, balanced = 0.5, push = 0.2 },
            spawnSets = { keys = { 'front', 'house', 'garage' }, use = 2, intel = true },
        }, setsLoc, { seed = seed })
        HW.start(ctx)
        return ctx, S
    end
    local ctx, S = Roll(31)
    local st = ctx.state
    H.eq(#st.sets, 2, 'hw parity: two of the three spawn sets per run')
    local again = Roll(31)
    H.eq(table.concat(again.state.sets, ','), table.concat(st.sets, ','), 'hw parity: the same seed, the same sets')
    H.eq(again.state.behaviour, st.behaviour, 'hw parity: the same seed, the same behaviour')
    local used = {}
    for _, k in ipairs(st.sets) do for _, p in ipairs(setsLoc[k]) do used[#used + 1] = p end end
    for _, s in ipairs(S.spawned) do
        local inSet = false
        for _, p in ipairs(used) do if U.dist2d(p, s.opts.coords) < 3.0 then inSet = true end end
        H.ok(inSet, 'hw parity: every hostile spawns in one of the rolled sets')
        H.eq(s.opts.cfg.behaviour, st.behaviour, 'hw parity: every hostile has the rolled behaviour')
    end
    local intel = ctx.run.shared.intel
    H.eq(type(intel) == 'table' and intel.key, 'block.hostile_waves.intel',
        'hw parity: an intel line token for the run')
    local names = {}
    for _, k in ipairs(st.sets) do
        local key = ('block.hostile_waves.set.%s'):format(k)
        names[#names + 1] = CP.Locale.has(key) and CP.L(key) or k
    end
    H.eq(intel and intel.vars and intel.vars.sets,
        CP.L('block.hostile_waves.intel_and', { first = names[1], last = names[2] }),
        'hw parity: the intel line names the two rolled sets')
    local behaviours, setsSeen = {}, {}
    for seed = 1, 30 do
        local c = Roll(seed)
        behaviours[c.state.behaviour] = true
        setsSeen[table.concat(c.state.sets, ',')] = true
    end
    H.ok(behaviours.hold and behaviours.balanced and behaviours.push, 'hw parity: every behaviour comes up over seeds')
    H.ok(U.count(setsSeen) >= 2, 'hw parity: different runs use different sets')
    -- feel: 'hard' raises health, surrender chance moves; the counts and awards stay the same
    local savedPreset = Config.NpcDifficulty.preset
    CP.Scaling = CP.Scaling or {}
    local savedFeel = CP.Scaling.feel
    CP.Scaling.feel = function() return { healthMult = 1.15, surrenderMult = 0.7, fleeMult = 1.2 } end
    local hard, SH = Roll(31)
    CP.Scaling.feel = savedFeel
    H.eq(#SH.spawned, #S.spawned, 'hw feel: the same number of hostiles under a harder preset')
    H.eq(SH.spawned[1].opts.health, math.floor(200 * 1.15 + 0.5), 'hw feel: health x healthMult')
    H.eq(S.spawned[1].opts.health, 200, 'hw feel: normal health otherwise')
    Config.NpcDifficulty.preset = savedPreset
    -- validation
    local ok, why = HW.validate({ spawnSets = { keys = { 'front' }, use = 2 } }, builtin, setsLoc)
    H.eq(why, 'block.hostile_waves.invalid.spawn_sets', 'hw parity: using more sets than exist refused')
    ok, why = HW.validate({ behaviour = { sleep = 1 } }, builtin, setsLoc)
    H.eq(why, 'block.hostile_waves.invalid.behaviour', 'hw parity: an unknown behaviour weight refused')
    H.eq(HW.validate(
        { behaviour = { hold = 1, push = 1 }, spawnSets = { keys = { 'front', 'house' }, use = 1 } },
        builtin,
        setsLoc
    ), true, 'hw parity: weights and sets validate')
    ok, why = HW.validate({ spawnSets = { keys = { 'front', 'cellar' }, use = 1 } }, builtin, setsLoc)
    H.eq(why, 'block.hostile_waves.invalid.spawns_missing', 'hw parity: a set with no points refused')
end

-- ============================================================================
--                         REVIEW FIXES (server halves)
-- ============================================================================

do -- hostile_waves: the server polls hostile health every tick (a report that beat the sync still rolls)
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 3 } }, HwLocation(12))
    HW.start(ctx)
    local a, b = S.spawned[1].netId, S.spawned[2].netId
    local rolls = #NPC.rolls
    local _, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = a })
    H.eq(why, 'health_ok', 'early report refused: the server has not seen the damage yet')
    NPC.rollResult = true
    SetHealth(S, a, 110)
    HW.tick(ctx, 1)
    H.eq(NPC.states[a], 'surrendered', 'tick poll rolled once the server saw the damage')
    H.eq(#NPC.rolls, rolls + 1, 'one roll for the polled hostile')
    H.ok(NPC.cuffs[a] ~= nil, 'the polled surrender enables Cuff suspect')
    NPC.rollResult = false
    SetHealth(S, b, 105)
    HW.tick(ctx, 1)
    HW.tick(ctx, 1)
    H.eq(#NPC.rolls, rolls + 2, 'a hostile nobody reported is rolled by the poll, once')
    H.eq(NPC.states[b], 'hostile', 'lost roll: still hostile')
    _, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = b })
    H.eq(why, 'duplicate', 'a later report does not roll again')
    local ctx0, S0 = MakeCtx('hostile_waves', { waves = { 2 }, surrender = { chance = 0 } }, HwLocation(12))
    HW.start(ctx0)
    SetHealth(S0, S0.spawned[1].netId, 101)
    local before = #NPC.rolls
    HW.tick(ctx0, 1)
    H.eq(#NPC.rolls, before, 'surrender chance 0: never rolled')
end

do -- a spawn that throws never freezes spawning (the re-entry flag is always cleared)
    local function ThrowOnce(ctx)
        local real, left = ctx.spawnPed, 1
        ctx.spawnPed = function(opts)
            if left > 0 then left = left - 1; error('CreatePed failed (test)') end
            return real(opts)
        end
    end
    Place(1, 1000, 1000, 30)
    local ctx, S = MakeCtx('hostile_waves', { waves = { 3 } }, HwLocation(12))
    ThrowOnce(ctx)
    HW.start(ctx)
    H.eq(#S.spawned, 0, 'hw: nothing from the throwing spawn')
    H.eq(ctx.state.spawning, false, 'hw: spawning flag cleared after the error')
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 3, 'hw: the next tick spawns the wave')

    local pctx, PS = MakeCtx('protect_rescue', {}, prLoc, { index = 2 })
    ThrowOnce(pctx)
    PR.prepare(pctx)
    H.eq(#PS.spawned, 0, 'pr: nothing from the throwing spawn')
    H.eq(pctx.state.spawning, false, 'pr: spawning flag cleared after the error')
    H.step(1000)
    H.eq(#PS.spawned, 3, 'pr: the prepare retry spawns every hostage')

    local sctx, SS = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    ThrowOnce(sctx)
    FA.start(sctx)
    H.eq(#SS.spawned, 0, 'fa scatter: nothing from the throwing spawn')
    H.eq(sctx.state.spawning, false, 'fa scatter: spawning flag cleared')
    FA.tick(sctx, 1)
    H.eq(#SS.spawned, 5, 'fa scatter: the next tick spawns every inmate')
    H.eq(#U.filter(SS.spawned, function(s) return s.opts.armed end), 2, 'fa scatter: still exactly 2 armed')

    Place(1, 3000, 3000, 10)
    local dctx, DS = MakeCtx('flee_arrest', {}, doorLoc)
    ThrowOnce(dctx)
    FA.start(dctx)
    H.eq(#DS.spawned, 0, 'fa door: nothing from the throwing spawn')
    FA.tick(dctx, 1)
    H.eq(#DS.spawned, 2, 'fa door: suspect and associate on the next tick')
end

do -- protect_rescue: no_hostage_hurt waits for minSeconds; one pending cut per participant
    local srcs = { 1, 2, 3 }
    local function FreeAll(ctx, S)
        for i, s in ipairs(S.spawned) do
            NearTo(srcs[i], S, s.netId)
            PR.onEvent(ctx, srcs[i], { type = 'free_start', netId = s.netId })
        end
        AdvanceMs(6000)
        for i, s in ipairs(S.spawned) do
            H.eq(PR.onEvent(ctx, srcs[i], { type = 'freed', netId = s.netId }), true,
                'freed by participant ' .. srcs[i])
            MoveEnt(S, s.netId, 2050, 2000, 20)
        end
    end
    local ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2, srcs = srcs })
    PR.prepare(ctx)
    PR.start(ctx)
    -- one participant cannot run two cuts at once
    local h1, h2 = S.spawned[1].netId, S.spawned[2].netId
    NearTo(1, S, h1)
    PR.onEvent(ctx, 1, { type = 'free_start', netId = h1 })
    NearTo(1, S, h2)
    PR.onEvent(ctx, 1, { type = 'free_start', netId = h2 })
    AdvanceMs(6000)
    NearTo(1, S, h1)
    local _, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h1 })
    H.eq(why, 'not_started', 'a second free_start replaced the first cut')
    NearTo(1, S, h2)
    H.eq(PR.onEvent(ctx, 1, { type = 'freed', netId = h2 }), true, 'the latest cut still counts')

    -- a completion refused as too fast records no bonus; a hit before the real completion costs it
    ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2, srcs = srcs })
    PR.prepare(ctx)
    PR.start(ctx)
    FreeAll(ctx, S)
    S.minOk = false
    PR.tick(ctx, 1)
    H.eq(S.completes, 0, 'refused before minSeconds')
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 0, 'no bonus recorded by a refused early completion')
    NPC.damaged[1](ctx.run, S.spawned[1].netId, nil)
    AdvanceMs(10000)
    S.minOk = true
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'completed after minSeconds')
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 0, 'hurt after the refused attempt: no no_hostage_hurt')

    ctx, S = MakeCtx('protect_rescue', {}, prLoc, { index = 2, srcs = srcs })
    PR.prepare(ctx)
    PR.start(ctx)
    FreeAll(ctx, S)
    S.minOk = false
    PR.tick(ctx, 1)
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 0, 'clean but early: nothing yet')
    AdvanceMs(10000)
    S.minOk = true
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'clean rescue completed')
    H.eq(#AwardsOf(S, 'no_hostage_hurt'), 1, 'clean rescue: no_hostage_hurt once minSeconds passed')
end

do -- flee_arrest: every NPC spawns calm (neutral) until the server makes it hostile
    Place(1, 3000, 3000, 10)
    local ctx, S = MakeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 } }, doorLoc)
    FA.start(ctx)
    for _, s in ipairs(S.spawned) do H.eq(s.opts.cfg.group, 'neutral', 'door NPC spawns neutral: ' .. s.opts.role) end
    H.eq(WithRole(S, 'suspect')[1].opts.armed, true, 'the fighting suspect still carries his pistol')
    H.eq(NPC.states[WithRole(S, 'associate')[1].netId], nil, 'associate not hostile before the knock')
    KnockOpen(ctx, S)
    H.eq(NPC.states[WithRole(S, 'associate')[1].netId], 'hostile', 'associate turns hostile at the knock')
    local sctx, SS = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    FA.start(sctx)
    for _, s in ipairs(SS.spawned) do
        H.eq(s.opts.cfg.group, 'neutral', 'inmate spawns neutral (armed: ' .. tostring(s.opts.armed) .. ')')
    end
end

do -- flee_arrest: a stun report must come from a participant near the suspect
    Place(1, 4000, 4000, 30)
    Place(2, 4000, 4000, 30)
    local ctx, S = MakeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc, { srcs = { 1, 2 } })
    FA.start(ctx)
    local a = U.filter(S.spawned, function(s) return s.opts.armed end)[1].netId
    NearTo(2, S, a, 5.0)
    local c = PosOf(S, a)
    Place(1, c.x + 120.0, c.y, c.z)
    local _, why = FA.onEvent(ctx, 1, { type = 'stunned', netId = a })
    H.eq(why, 'too_far', 'a far-away participant cannot report a stun for someone else')
    H.eq(NPC.states[a], 'fleeing', 'the armed inmate did not give up')
    H.eq(FA.onEvent(ctx, 2, { type = 'stunned', netId = a }), true, 'the participant next to him can')
    H.eq(NPC.states[a], 'surrendered', 'armed inmate gave up after the stun')
end

do -- validation guardrails added in review
    local loc = HwLocation(12)
    loc.bossZone = vec4(470.0, -974.0, 30.0, 0.0)          -- Mission Row PD no-build zone
    loc.bossNear = vec4(1005.0, 1000.0, 30.0, 0.0)         -- 5 m from the start
    local ok, why = HW.validate({ boss = { spawn = 'bossZone' } }, builtin, loc)
    H.eq(why, 'block.hostile_waves.invalid.spawns_zone', 'boss spot in a no-build zone refused (builtin too)')
    ok, why = HW.validate({ boss = { spawn = 'bossNear' } }, custom, loc)
    H.eq(why, 'block.hostile_waves.invalid.spawns_start', 'custom boss spot too close to the start')
    H.eq(HW.validate({ boss = { spawn = 'bossNear' } }, builtin, loc), true, 'builtin boss spot near the start trusted')
    ok, why = HW.validate({ spawns = { vec4(470.0, -974.0, 30.0, 0.0) } }, builtin, loc)
    H.eq(why, 'block.hostile_waves.invalid.spawns_zone', 'inline spawn point in a no-build zone refused (builtin too)')

    local near = {
        label = 'Store',
        start = { coords = vec3(1995.0, 2000.0, 20.0), radius = 60.0 },
        hostages = prLoc.hostages,
        safe = prLoc.safe,
    }
    ok, why = PR.validate({}, custom, near)
    H.eq(why, 'block.protect_rescue.invalid.points_start', 'custom hostage spots within 30 m of the start refused')
    H.eq(PR.validate({}, builtin, near), true, 'builtin hostage spots near the start trusted (inside a store)')
    local zoned = {
        label = 'Clinic',
        start = { coords = vec3(250.0, -595.0, 43.0), radius = 60.0 },
        hostages = { vec4(308.0, -595.0, 43.0, 0.0) },
        safe = vec3(150.0, -595.0, 43.0),
    }
    ok, why = PR.validate({ count = 1 }, builtin, zoned)
    H.eq(why, 'block.protect_rescue.invalid.points_zone', 'hostage spot in a no-build zone refused (builtin too)')

    local badRoute = {
        label = 'Breakout B',
        start = scatterLoc.start,
        spawns = scatterLoc.spawns,
        routes = { { vec3(4100.0, 4000.0, 30.0), vec3(2344.0, 2565.0, 46.0) } },
    } -- into the Crimson-Arena match area
    ok, why = FA.validate({ mode = 'scatter' }, builtin, badRoute)
    H.eq(why, 'block.flee_arrest.invalid.route_zone', 'escape route through a no-build zone refused')
    local d = U.copy(doorLoc)
    d.door = vec4(470.0, -974.0, 30.0, 0.0)
    ok, why = FA.validate({}, builtin, d)
    H.eq(why, 'block.flee_arrest.invalid.route_zone', 'door marker in a no-build zone refused')
    d = U.copy(doorLoc)
    d.fleeTo = { vec3(3060.0, 3000.0, 10.0), vec3(308.0, -595.0, 43.0) }
    ok, why = FA.validate({}, builtin, d)
    H.eq(why, 'block.flee_arrest.invalid.route_zone', 'fleeTo point in a no-build zone refused')
    d = U.copy(doorLoc)
    d.suspect = vec4(1560.0, 815.0, 76.0, 0.0)
    ok, why = FA.validate({}, builtin, d)
    H.eq(why, 'block.flee_arrest.invalid.points_zone', 'door-mode suspect in a no-build zone refused (builtin too)')
    H.eq(FA.validate({}, builtin, doorLoc), true, 'the normal door location is still valid')
end

-- ============================================================================
--                                      ═
-- ============================================================================
-- client halves (stubbed natives, undefined globals are errors): host control before every task,
-- traffic block, blips, targets, progress cancelled on stop

-- ============================================================================
--                                      ═
-- ============================================================================

do
    local saved = {}
    for _, k in ipairs({ 'GetEntityCoords', 'GetEntityHealth', 'GetEntityMaxHealth', 'DoesEntityExist' }) do
        saved[k] = _G[k]
    end
    local savedNpc = { apply = CP.Npc.apply, task = CP.Npc.task }
    local ME = 1
    local CE, byNet = {}, {}
    local blips, nextBlip = {}, 0
    local roads = { zones = {}, removed = {}, off = {}, back = {}, cleared = 0 }
    local targets, zones, removedZones = {}, {}, {}
    local tasks, controlCalls = {}, 0
    local aiming, targetting, stunned = {}, {}, {}
    local progress = { active = false, cancel = false, cancelled = 0 }
    local function NewBlip() nextBlip = nextBlip + 1; blips[nextBlip] = true; return nextBlip end
    local function OpenBlips() local n = 0 for _ in pairs(blips) do n = n + 1 end return n end
    local function AddEnt(netId, handle, coords, bag)
        CE[handle] = { coords = coords, health = 200, maxHealth = 200, bag = bag, control = false, grant = false }
        byNet[netId] = handle
    end
    local function TasksFor(e, action)
        return U.filter(tasks, function(t) return t.e == e and (action == nil or t.action == action) end)
    end
    local function Steps(n, ms) for _ = 1, n do H.step(ms or 1000) end end
    local stub = {
        PlayerPedId = function() return ME end,
        PlayerId = function() return 0 end,
        NetworkDoesNetworkIdExist = function(n) return byNet[n] ~= nil end,
        NetworkGetEntityFromNetworkId = function(n) return byNet[n] or 0 end,
        DoesEntityExist = function(e) return e == ME or CE[e] ~= nil end,
        GetEntityCoords = function(e)
            if e == ME then return H.players[1].coords end
            return CE[e] and CE[e].coords or vec3(0.0, 0.0, 0.0)
        end,
        GetEntityHealth = function(e) return CE[e] and CE[e].health or 0 end,
        GetEntityMaxHealth = function(e) return CE[e] and CE[e].maxHealth or 0 end,
        Entity = function(e) return { state = { cp = CE[e] and CE[e].bag or nil } } end,
        NetworkHasControlOfEntity = function(e) return CE[e] ~= nil and CE[e].control == true end,
        AddRoadNodeSpeedZone = function(...) roads.zones[#roads.zones + 1] = { ... }; return #roads.zones end,
        RemoveRoadNodeSpeedZone = function(id) roads.removed[#roads.removed + 1] = id end,
        SetRoadsInArea = function(...) roads.off[#roads.off + 1] = { ... } end,
        SetRoadsBackToOriginal = function(...) roads.back[#roads.back + 1] = { ... } end,
        ClearAreaOfVehicles = function() roads.cleared = roads.cleared + 1 end,
        AddBlipForEntity = function() return NewBlip() end,
        AddBlipForCoord = function() return NewBlip() end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipScale = function() end,
        SetBlipAsShortRange = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,
        DoesBlipExist = function(b) return blips[b] == true end,
        RemoveBlip = function(b) blips[b] = nil end,
        DrawMarker = function() end,
        IsPedBeingStunned = function(e) return stunned[e] == true end,
        IsPlayerFreeAimingAtEntity = function(_, e) return aiming[e] == true end,
        IsPlayerTargettingEntity = function(_, e) return targetting[e] == true end,
    }
    for k, v in pairs(stub) do _G[k] = v end
    lib.progressBar = function(opts)
        progress.last, progress.active, progress.cancel = opts, true, false
        Wait(opts.duration)
        progress.active = false
        return not progress.cancel
    end
    lib.progressActive = function() return progress.active end
    lib.cancelProgress = function() progress.cancel = true; progress.cancelled = progress.cancelled + 1 end
    H.exportsMock.ox_target = {
        addLocalEntity = function(ent, opts) targets[ent] = opts end,
        removeLocalEntity = function(ent) targets[ent] = nil end,
        addSphereZone = function(o) zones[#zones + 1] = o; return #zones end,
        removeZone = function(id) removedZones[id] = true end,
    }
    CP.Npc.apply = function(e) return CE[e] ~= nil and CE[e].control == true end
    CP.Npc.task = function(e, action, args)
        if not (CE[e] and CE[e].control) then return false end
        tasks[#tasks + 1] = { e = e, action = action, args = args }
        return true
    end
    local function ClientCtx(obj, location, o)
        o = o or {}
        local c = {
            runId = 'crun-' .. tostring(o.tag),
            index = o.index or 1,
            obj = obj,
            base = obj,
            mission = {},
            location = location,
            isHost = o.isHost ~= false,
            test = false,
            radioSilence = o.radioSilence == true,
            state = {},
            participants = { 1 },
            seed = 1,
        }
        c.reports, c.lines = {}, {}
        c.report = function(ev) c.reports[#c.reports + 1] = ev end
        c.hudDetail = function(text) c.lines[#c.lines + 1] = text or false end
        c.control = function(e)
            controlCalls = controlCalls + 1
            if CE[e] and CE[e].grant then CE[e].control = true end
            return CE[e] ~= nil and CE[e].control == true
        end
        c.getEntity = function(n) return byNet[n] end
        return c
    end
    local function ReportsOf(c, kind)
        return U.filter(c.reports, function(r) return r.type == kind end)
    end

    CP.Blocks._list.hostile_waves, CP.Blocks._list.protect_rescue, CP.Blocks._list.flee_arrest = nil, nil, nil
    setmetatable(_G, {
        __index = function(_, k) error('undefined global ' .. tostring(k), 2) end,
    })
    H.load('blocks/hostile_waves/client.lua')
    H.load('blocks/protect_rescue/client.lua')
    H.load('blocks/flee_arrest/client.lua')
    local HWc, PRc, FAc = CP.Blocks.get('hostile_waves'), CP.Blocks.get('protect_rescue'), CP.Blocks.get('flee_arrest')
    H.ok(HWc ~= HW and PRc ~= PR and FAc ~= FA and HWc.update and PRc.update and FAc.update, 'client halves registered')
    Place(1, 1990, 2000, 20)

    -- protect_rescue: a freed hostage owned by another client still gets its follow task
    local pc = ClientCtx(U.deepcopy(PR.defaults({})), prLoc, { tag = 'pr', index = 2 })
    AddEnt(7001, 71, vec3(2000.0, 2000.0, 20.0), { state = 'restrained', cfg = { group = 'neutral' } })
    PRc.prepare(pc)
    PRc.update(pc, { peds = { { netId = 7001, state = 'restrained', index = 1 } } })
    Steps(1)
    H.eq(#TasksFor(71), 0, 'pr: no control, no task')
    H.ok(controlCalls > 0, 'pr: control requested')
    CE[71].grant = true
    Steps(1)
    H.eq(#TasksFor(71, 'kneel'), 1, 'pr: restrained hostage kneels once control arrives')
    CE[71].control, CE[71].grant = false, false          -- the officer who cuts the restraints owns it now
    CE[71].bag = { state = 'freed', cfg = { group = 'neutral' } }
    PRc.update(pc, { peds = { { netId = 7001, state = 'freed', index = 1 } } })
    Steps(3)
    H.eq(#TasksFor(71, 'follow'), 0, 'pr: follow cannot be issued without control')
    CE[71].grant = true
    Steps(1)
    local follow = TasksFor(71, 'follow')
    H.eq(#follow, 1, 'pr: follow issued as soon as control is back (not lost for good)')
    H.near(follow[1] and follow[1].args.coords.x or 0, 2050, 0.01, 'pr: follow to the safe marker')
    -- Cut restraints target, progress cancelled when the objective stops mid-cut
    CE[71].bag = { state = 'restrained' }
    PRc.update(pc, { peds = { { netId = 7001, state = 'restrained', index = 1 } } })
    PRc.start(pc)
    Steps(1)
    local opt = targets[71] and targets[71][1]
    H.ok(opt and opt.name == 'crimson-police:cut_restraints', 'pr: Cut restraints target on the restrained hostage')
    H.eq(opt and opt.canInteract(71), true, 'pr: target usable while current')
    opt.onSelect()
    H.eq(#ReportsOf(pc, 'free_start'), 1, 'pr: free_start reported')
    H.eq(progress.active, true, 'pr: progress bar running')
    PRc.stop(pc)
    H.eq(progress.cancelled, 1, 'pr: stop cancels the running progress bar')
    H.eq(targets[71], nil, 'pr: stop removes the target')
    H.eq(OpenBlips(), 0, 'pr: stop removes the blips')
    Steps(8)
    H.eq(#ReportsOf(pc, 'freed'), 0, 'pr: no freed report after the cancelled cut')

    -- flee_arrest: fleeing inmate re-tasked once control arrives; lock-on aim counts as aiming
    Place(1, 4000, 4000, 30)
    local fc = ClientCtx(U.deepcopy(FA.defaults({ mode = 'scatter' })), scatterLoc, { tag = 'fa' })
    AddEnt(7101, 81, vec3(4040.0, 4000.0, 30.0), { state = 'fleeing', cfg = {} })
    FAc.prepare(fc)
    FAc.start(fc)
    FAc.update(fc,
        { peds = { { netId = 7101, role = 'inmate', state = 'fleeing', armed = false, route = 1 } }, mode = 'scatter' })
    Steps(2)
    H.eq(#TasksFor(81, 'flee'), 0, 'fa: no control, no flee task')
    CE[81].grant = true
    Steps(2)
    local flee = TasksFor(81, 'flee')
    H.eq(#flee, 1, 'fa: flee issued once control arrives')
    H.eq(flee[1] and #flee[1].args.points or 0, 2, 'fa: along its escape route')
    Place(1, 4045, 4000, 30)
    targetting[81] = true
    Steps(2)
    H.ok(#ReportsOf(fc, 'aim') >= 1, 'fa: lock-on aim within givesUp.aim reported')
    FAc.stop(fc)
    -- door: knock progress cancelled when the objective stops, zone removed
    Place(1, 3041, 3000, 10)
    local dc = ClientCtx(U.deepcopy(FA.defaults({})), doorLoc, { tag = 'door' })
    FAc.prepare(dc)
    FAc.start(dc)
    local zone = zones[#zones]
    H.ok(zone and zone.name:find('crimson-police:knock', 1, true) == 1, 'fa: knock zone named crimson-police:*')
    zone.options[1].onSelect()
    H.eq(#ReportsOf(dc, 'knock_start'), 1, 'fa: knock_start reported')
    FAc.stop(dc)
    H.eq(progress.cancelled, 2, 'fa: stop cancels the knock progress bar')
    H.eq(removedZones[#zones], true, 'fa: stop removes the knock zone')
    Steps(4)
    H.eq(#ReportsOf(dc, 'knock'), 0, 'fa: no knock report after the cancelled progress')
    -- door: a test restart after the knock (the server sends knocked = false again) re-arms the door
    local rc = ClientCtx(U.deepcopy(FA.defaults({})), doorLoc, { tag = 'door-restart' })
    FAc.prepare(rc)
    FAc.start(rc)
    local firstZone = #zones
    FAc.update(rc, { peds = {}, mode = 'door', knocked = true, response = 'surrender' })
    H.eq(removedZones[firstZone], true, 'fa restart: the knock removes the door zone')
    FAc.update(rc, { peds = {}, mode = 'door', knocked = false })
    H.eq(#zones, firstZone + 1, 'fa restart: a new Knock and announce zone after the restart')
    H.eq(zones[#zones].options[1].canInteract(), true, 'fa restart: the knock can be used again')
    zones[#zones].options[1].onSelect()
    Steps(4)
    H.eq(#ReportsOf(rc, 'knock'), 1, 'fa restart: the knock is reported again')
    FAc.stop(rc)
    H.eq(removedZones[#zones], true, 'fa restart: stop removes the new zone')
    -- the objective stops while the host loop waits for control of an inmate: nothing after the cleanup
    Place(1, 4000, 4000, 30)
    local sc = ClientCtx(U.deepcopy(FA.defaults({ mode = 'scatter' })), scatterLoc, { tag = 'fa-stop' })
    local slow = false
    sc.control = function(e)
        if slow then Wait(0) end
        CE[e].control = true
        return true
    end
    AddEnt(7102, 82, vec3(4040.0, 4000.0, 30.0), { state = 'fleeing', cfg = {} })
    FAc.prepare(sc)
    FAc.start(sc)
    FAc.update(sc, {
        peds = { { netId = 7102, role = 'inmate', state = 'fleeing', armed = true, route = 1 } },
        mode = 'scatter',
        escaping = 12,
    })
    local base = OpenBlips()
    Steps(1)
    H.eq(OpenBlips() - base, 1, 'fa stop: a blip on the inmate')
    H.eq(sc.lines[#sc.lines], CP.L('block.flee_arrest.escaping', { seconds = 12 }), 'fa stop: the escape line')
    local before = #tasks
    CE[82].bag.state, CE[82].control, slow = 'hostile', false, true  -- turns to fight; control is elsewhere
    Steps(1)
    FAc.stop(sc)                                                     -- ...and the objective stops meanwhile
    H.eq(OpenBlips() - base, 0, 'fa stop: stop removes the blips')
    Steps(4)
    H.eq(OpenBlips() - base, 0, 'fa stop: the loop pass resumed after the cleanup draws no blip')
    H.eq(sc.lines[#sc.lines], false, 'fa stop: ...and writes no HUD line')
    H.eq(#tasks, before, 'fa stop: ...and tasks nobody')

    -- hostile_waves: traffic blocked around the start and restored at stop; apply/combat retried
    Place(1, 1000, 1000, 30)
    local hloc = HwLocation(12)
    local hc = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hw' })
    AddEnt(7201, 91, vec3(1060.0, 1000.0, 30.0), { state = 'hostile', cfg = { behaviour = 'balanced' } })
    HWc.prepare(hc)
    HWc.start(hc)
    H.eq(#roads.zones, 1, 'hw: road speed zone added')
    H.eq(#roads.off, 1, 'hw: roads switched off in the box')
    H.eq(roads.cleared, 1, 'hw: area cleared of ambient vehicles once')
    H.near(roads.zones[1][4], 120.0, 0.01, 'hw: traffic blocked within blockTraffic metres')
    HWc.update(hc, { peds = { { netId = 7201, role = 'hostile', state = 'hostile', wave = 1 } } })
    Steps(2)
    H.eq(#TasksFor(91, 'combat'), 0, 'hw: no control, no combat task')
    H.eq(OpenBlips(), 1, 'hw: hostile blip')
    CE[91].grant = true
    Steps(1)
    H.eq(#TasksFor(91, 'combat'), 1, 'hw: combat task once control arrives')
    CE[91].health = 110
    Steps(1)
    H.eq(#ReportsOf(hc, 'low_health'), 1, 'hw: host reports the low health once')
    HWc.stop(hc)
    H.eq(#roads.removed, 1, 'hw: speed zone removed at stop')
    H.eq(#roads.back, 1, 'hw: roads back to original at stop')
    H.eq(OpenBlips(), 0, 'hw: blips removed at stop')
    local rc = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hw2', radioSilence = true })
    HWc.prepare(rc)
    HWc.start(rc)
    HWc.update(rc, { peds = { { netId = 7201, role = 'hostile', state = 'hostile', wave = 1 } } })
    Steps(1)
    H.eq(OpenBlips(), 0, 'hw: radio silence, no blips')
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.eq(#roads.back, 2, 'hw: resource stop restores the traffic too')
    -- the objective stops while the host loop waits for control of a hostile: nothing after the cleanup
    local wc = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hw-stop' })
    local slowHw = false
    wc.control = function(e)
        if slowHw then Wait(0) end
        CE[e].control = true
        return true
    end
    AddEnt(7202, 92, vec3(1040.0, 1000.0, 30.0), { state = 'hostile', cfg = { behaviour = 'balanced' } })
    HWc.prepare(wc)
    HWc.start(wc)
    HWc.update(wc, { peds = { { netId = 7202, role = 'hostile', state = 'hostile', wave = 1 } } })
    local hwBase = OpenBlips()
    CE[92].control, slowHw = false, true
    Steps(1)
    local hwTasks = #tasks
    HWc.stop(wc)
    H.eq(OpenBlips() - hwBase, 0, 'hw stop: stop removes the blips')
    Steps(4)
    H.eq(OpenBlips() - hwBase, 0, 'hw stop: the loop pass resumed after the cleanup draws no blip')
    H.eq(#tasks, hwTasks, 'hw stop: ...and tasks nobody')

    -- traffic stays blocked while a later objective of the run follows (Gang Shootout "Secure the scene"),
    -- and is restored when the last objective stops, when the run is over, or on resource stop
    do
        local savedRuns = CP.Runs
        local curRun = { id = 'crun-hwhold', objectives = { {}, {} } }
        CP.Runs = {
            current = function() return curRun end,
        }
        local z0, b0 = #roads.zones, #roads.back
        local o1 = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hwhold' })
        HWc.prepare(o1)
        HWc.start(o1)
        H.eq(#roads.zones, z0 + 1, 'hw hold: traffic blocked when objective 1 starts')
        HWc.stop(o1)
        H.eq(#roads.back, b0, 'hw hold: objective 1 of 2 stopped, traffic stays blocked')
        H.eq(#roads.removed, #roads.zones - 1, 'hw hold: the speed zone is kept')
        Steps(3)
        H.eq(#roads.back, b0, 'hw hold: still blocked while the run goes on')
        local o2 = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hwhold', index = 2 })
        HWc.prepare(o2)
        HWc.start(o2)
        H.eq(#roads.zones, z0 + 1,
            'hw hold: a later hostile_waves objective at the same place takes the held block over')
        HWc.stop(o2)
        H.eq(#roads.back, b0 + 1, 'hw hold: restored when the last objective stops')
        Steps(2)
        H.eq(#roads.back, b0 + 1, 'hw hold: restored once only')
        local o3 = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hwhold' })
        HWc.prepare(o3)
        HWc.start(o3)
        HWc.stop(o3)
        H.eq(#roads.back, b0 + 1, 'hw hold: held again after objective 1')
        curRun = nil
        Steps(1)
        H.eq(#roads.back, b0 + 2, 'hw hold: restored once the run is over (no current run)')
        curRun = { id = 'crun-hwother', objectives = { {}, {} } }
        local o4 = ClientCtx(U.deepcopy(HW.defaults({ waves = { 2 } })), hloc, { tag = 'hwrs' })
        CP.Runs = {
            current = function() return { id = 'crun-hwrs', objectives = { {}, {} } } end,
        }
        HWc.prepare(o4)
        HWc.start(o4)
        HWc.stop(o4)
        H.eq(#roads.back, b0 + 2, 'hw hold: held for run hwrs')
        TriggerEvent('onResourceStop', 'Crimson-Police')
        H.eq(#roads.back, b0 + 3, 'hw hold: resource stop restores a held block')
        CP.Runs = savedRuns
    end

    setmetatable(_G, nil)
    for k, v in pairs(saved) do _G[k] = v end
    CP.Npc.apply, CP.Npc.task = savedNpc.apply, savedNpc.task
end

-- ============================================================================
--            LOCALE PART: valid JSON, every referenced key present
-- ============================================================================

do
    local f = assert(io.open(H.root .. 'locales/parts/blocks_b.json', 'r'))
    local raw = f:read('a')
    f:close()
    local ok, parts = pcall(cjson.decode, raw)
    H.ok(ok and type(parts) == 'table', 'blocks_b.json is valid JSON')
    local files = {
        'blocks/hostile_waves/server.lua',
        'blocks/hostile_waves/client.lua',
        'blocks/protect_rescue/server.lua',
        'blocks/protect_rescue/client.lua',
        'blocks/flee_arrest/server.lua',
        'blocks/flee_arrest/client.lua',
    }
    local n = 0
    for _, rel in ipairs(files) do
        local h = assert(io.open(H.root .. rel, 'r'))
        local src = h:read('a')
        h:close()
        for key in src:gmatch('\'(block%.[%w_%.]+)\'') do
            n = n + 1
            H.ok(parts[key] ~= nil, 'locale key present: ' .. key)
        end
        for key in src:gmatch('\'(run%.[%w_%.]+)\'') do
            n = n + 1
            H.ok(parts[key] ~= nil, 'locale key present: ' .. key)
        end
    end
    H.ok(n > 60, 'locale keys found in the sources')
    for _, id in ipairs({ 'bonus.kingpin_alive', 'bonus.inmate_alive', 'penalty.hostage_hit' }) do
        H.ok(parts[id] ~= nil, 'label for block-recorded id ' .. id)
    end
end

return H
