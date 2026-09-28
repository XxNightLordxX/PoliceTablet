-- tests/blocks_b_spec.lua · slice blocks_b: the server halves of hostile_waves, protect_rescue and
-- flee_arrest driven through a FAKE ctx (spies for complete/fail/award/penalize/spawnPed/canSpawn/
-- coords/send/hud), a stubbed CP.Npc and a tiny entity world. Also checks the locale part.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U
local cjson = require('cjson')

-- ── Fake world: every entity spawned through the fake ctx ───────────────────
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

-- ── CP.Npc stub (modules/npc is another slice) ──────────────────────────────
local NPC = { states = {}, cuffs = {}, rolls = {}, rollResult = true, damaged = {} }
CP.Npc = {
    setState = function(_, netId, state) NPC.states[netId] = state end,
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

-- ── Fake ctx ────────────────────────────────────────────────────────────────
local function makeCtx(id, obj, location, o)
    o = o or {}
    local impl = CP.Blocks.get(id)
    local index = o.index or 1
    local srcs = o.srcs or { 1 }
    local run = { id = 'run-' .. id .. '-' .. tostring(W.nextNet), seed = o.seed or 1234, participants = {},
        objectives = {}, entities = {}, state = 'in_progress' }
    for _, s in ipairs(srcs) do run.participants[s] = { src = s, status = 'active' } end
    local state = {}
    run.objectives[index] = { status = 'active', state = state }
    local S = { completeCalls = 0, completes = 0, fails = {}, awards = {}, penalties = {}, sends = {}, huds = {},
        spawned = {}, deleted = {}, can = true, minOk = true, active = srcs }
    local scaled = impl.defaults(obj)
    local ctx
    ctx = {
        run = run, index = index, obj = scaled, base = U.deepcopy(scaled), mission = o.mission or { source = 'builtin' },
        location = location, tier = { tier = 'standard' }, state = state, rng = U.rng(run.seed + index),
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
            W.ents[e] = { coords = vec3(opts.coords.x, opts.coords.y, opts.coords.z), health = opts.health or 200,
                maxHealth = opts.health or 200, exists = true, netId = n, opts = opts }
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

local function place(src, x, y, z)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
end
local function entOf(S, netId)
    for _, s in ipairs(S.spawned) do if s.netId == netId then return s.entity end end
end
local function posOf(S, netId) return W.ents[entOf(S, netId)].coords end
local function moveEnt(S, netId, x, y, z) W.ents[entOf(S, netId)].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0) end
local function setHealth(S, netId, hp) W.ents[entOf(S, netId)].health = hp end
local function nearTo(src, S, netId, dx)
    local c = posOf(S, netId)
    place(src, c.x + (dx or 1.0), c.y, c.z)
end
local function withRole(S, role)
    return U.filter(S.spawned, function(s) return s.opts.role == role end)
end
local function awardsOf(S, id)
    return U.filter(S.awards, function(a) return a.id == id end)
end
local function lastSend(S) return S.sends[#S.sends] end
local function lastHud(S, field)
    for i = #S.huds, 1, -1 do
        if S.huds[i][field] ~= nil then return S.huds[i][field] end
    end
end
local function advanceMs(ms) H.clockMs = H.clockMs + ms end

-- ── Locations ───────────────────────────────────────────────────────────────
local function hwLocation(n, cx, cy)
    cx, cy = cx or 1000.0, cy or 1000.0
    local spawns = {}
    for i = 1, n do
        local a = (i - 1) / n * 2 * math.pi
        spawns[i] = vec4(cx + 60 * math.cos(a), cy + 60 * math.sin(a), 30.0, 0.0)
    end
    return { label = 'Hideout', start = { coords = vec3(cx, cy, 30.0), radius = 80.0 }, spawns = spawns,
        bossSpot = vec4(cx, cy + 70, 30.0, 180.0) }
end

local prLoc = {
    label = 'Store', start = { coords = vec3(1960.0, 2000.0, 20.0), radius = 60.0 },
    hostages = { vec4(2000.0, 2000.0, 20.0, 0.0), vec4(2010.0, 2000.0, 20.0, 0.0), vec4(2020.0, 2000.0, 20.0, 0.0) },
    safe = vec3(2050.0, 2000.0, 20.0),
}

local doorLoc = {
    label = 'House', start = { coords = vec3(3000.0, 3000.0, 10.0), radius = 50.0 },
    door = vec4(3040.0, 3000.0, 10.0, 90.0),
    suspect = vec4(3045.0, 3000.0, 10.0, 90.0),
    fleeTo = { vec3(3060.0, 3000.0, 10.0), vec3(3100.0, 3000.0, 10.0) },
    associates = { vec4(3046.0, 3005.0, 10.0, 0.0), vec4(3046.0, 2995.0, 10.0, 0.0), vec4(3047.0, 3010.0, 10.0, 0.0) },
    yard = vec3(3050.0, 3020.0, 10.0),
}

local function scatterSpawns(n)
    local out = {}
    for i = 1, n do out[i] = vec4(4040.0 + (i - 1) * 20.0, 4000.0, 30.0, 0.0) end
    return out
end
local scatterLoc = {
    label = 'Breakout A', start = { coords = vec3(4000.0, 4000.0, 30.0), radius = 150.0 },
    spawns = scatterSpawns(6),
    routes = {
        { vec3(4100.0, 4000.0, 30.0), vec3(4300.0, 4000.0, 30.0) },
        { points = { vec3(4040.0, 4100.0, 30.0), vec3(4040.0, 4300.0, 30.0) } },
    },
}
local prisonLoc = {
    label = 'Inside', start = { coords = vec3(1900.0, 2600.0, 45.0), radius = 150.0 },
    spawns = { vec4(1770.0, 2570.0, 45.0, 0.0), vec4(1780.0, 2575.0, 45.0, 0.0) },
    routes = { { vec3(1900.0, 2700.0, 45.0) } },
}

local builtin, custom = { source = 'builtin' }, { source = 'custom' }

-- ════════════════════════════════════════════════════════════════════════════
-- hostile_waves
-- ════════════════════════════════════════════════════════════════════════════
do -- defaults
    local d = HW.defaults({ block = 'hostile_waves' })
    H.eq(d.minSeconds, 60, 'hw default minSeconds')
    H.eq(d.presenceRange, 150, 'hw default presenceRange from Config.Blocks')
    H.eq(d.spawns, 'spawns', 'hw default spawns key')
    H.eq(table.concat(d.waves, ','), '7,7,6', 'hw default waves')
    H.eq(d.nextWave.aliveAtMost, 2, 'hw default aliveAtMost')
    H.eq(d.nextWave.afterSeconds, 90, 'hw default afterSeconds')
    H.eq(d.accuracy, 25, 'hw default accuracy'); H.eq(d.armour, 0, 'hw default armour'); H.eq(d.health, 200, 'hw default health')
    H.eq(d.behaviour, 'balanced', 'hw default behaviour')
    H.near(d.surrender.chance, 0.30, 1e-9, 'hw default surrender chance'); H.eq(d.surrender.belowHealth, 0.25, 'hw belowHealth')
    H.eq(d.blockTraffic, 120.0, 'hw default blockTraffic')
    H.eq(d.boss, false, 'hw default no boss')
    H.eq(#d.weapons, 2, 'hw default weapons'); H.eq(#d.peds, 4, 'hw default peds')
    local b = HW.defaults({ boss = { model = 'g_m_y_lost_01' } }).boss
    H.eq(b.health, 400, 'boss default health'); H.eq(b.armour, 100, 'boss default armour')
    H.eq(b.weapon, 'WEAPON_ASSAULTRIFLE', 'boss default weapon'); H.eq(b.aliveBonus.id, 'kingpin_alive', 'boss bonus id')
    H.eq(b.aliveBonus.points, 50, 'boss bonus points'); H.near(b.surrender.chance, 0.30, 1e-9, 'boss surrender chance')
    H.eq(b.label, 'block.hostile_waves.boss_label', 'boss label from locale')
    local keep = HW.defaults({ waves = { 4 }, accuracy = 40 })
    H.eq(keep.waves[1], 4, 'hw keeps given waves'); H.eq(keep.accuracy, 40, 'hw keeps given accuracy')
end

do -- validate
    local loc = hwLocation(12)
    H.eq(HW.validate({ waves = { 7, 7, 6 } }, builtin, loc), true, 'hw valid builtin')
    H.eq(HW.validate({ waves = { 7, 7, 6 } }, custom, loc), true, 'hw valid custom (12 points >= 1.5 x 7)')
    local ok, why = HW.validate({ waves = { 20 } }, builtin, loc)
    H.eq(ok, false, 'hw wave too big'); H.eq(why, 'block.hostile_waves.invalid.range', 'hw wave reason')
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
    ok, why = HW.validate({ waves = { 7 } }, custom, hwLocation(8))
    H.eq(why, 'block.hostile_waves.invalid.spawns_count', 'custom needs 1.5 x largest wave spawn points')
    H.eq(HW.validate({ waves = { 7 } }, builtin, hwLocation(8)), true, 'builtin spawn count trusted')
    local nearStart = hwLocation(12); nearStart.spawns[1] = vec4(1010.0, 1000.0, 30.0, 0.0)
    ok, why = HW.validate({}, custom, nearStart)
    H.eq(why, 'block.hostile_waves.invalid.spawns_start', 'custom spawn too close to start')
    local noSpawns = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 50.0 } }
    ok, why = HW.validate({}, builtin, noSpawns)
    H.eq(why, 'block.hostile_waves.invalid.spawns_missing', 'spawns missing')
    ok, why = HW.validate({}, { source = 'builtin', locations = { loc, noSpawns } })
    H.eq(ok, false, 'validate walks mission.locations'); H.eq(why, 'block.hostile_waves.invalid.spawns_missing', 'second location missing')
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
    H.eq(rp[1], 'spawns', 'required spawns'); H.eq(rp[2], 'bossSpot', 'required boss spot')
    H.eq(HW.onTimeout({}), nil, 'hw onTimeout fails')
end

do -- waves: start, distinct points, combat values, next wave by count and by time, low health, cuffs, completion
    local loc = hwLocation(12)
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 7, 7, 6 } }, loc)
    HW.prepare(ctx)
    HW.start(ctx)
    H.eq(#S.spawned, 7, 'wave 1 spawned at start')
    local seen, distinct = {}, 0
    for _, s in ipairs(S.spawned) do
        local k = ('%.2f,%.2f'):format(s.opts.coords.x, s.opts.coords.y)
        if not seen[k] then seen[k] = true; distinct = distinct + 1 end
        H.eq(s.opts.armed, true, 'hostile armed'); H.eq(s.opts.role, 'hostile', 'hostile role')
        H.eq(s.opts.accuracy, 35, 'accuracy + tier via ctx.combat'); H.eq(s.opts.armour, 25, 'armour + tier via ctx.combat')
        H.ok(U.contains(ctx.obj.weapons, s.opts.weapon), 'weapon from the list')
        H.ok(U.contains(ctx.obj.peds, s.opts.model), 'model from the list')
        H.eq(NPC.states[s.netId], 'hostile', 'bag state hostile')
    end
    H.eq(distinct, 7, 'wave 1 uses 7 distinct spawn points')
    H.eq(#lastSend(S).peds, 7, 'client snapshot lists 7 peds')
    H.eq(lastSend(S).waves, 3, 'client snapshot waves')
    H.eq(lastHud(S, 'max'), 20, 'HUD max = 20 hostiles')
    H.eq(lastHud(S, 'detail'), 'block.hostile_waves.detail', 'HUD detail line')

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
    H.eq(ok, false, 'full health rejected'); H.eq(why, 'health_ok', 'health_ok reason')
    setHealth(S, h1, 110)
    NPC.rollResult = true
    ok = HW.onEvent(ctx, 1, { type = 'low_health', netId = h1 })
    H.eq(ok, true, 'low health accepted')
    H.eq(NPC.states[h1], 'surrendered', 'surrendered after a won roll')
    H.near(NPC.rolls[#NPC.rolls].chance, 0.30, 1e-9, 'rolled with surrender.chance')
    H.ok(NPC.cuffs[h1] ~= nil, 'Cuff suspect enabled')
    ok, why = HW.onEvent(ctx, 1, { type = 'low_health', netId = h1 })
    H.eq(why, 'wrong_state', 'no second roll for a surrendered hostile')
    setHealth(S, h2, 120)
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
    place(1, 1000, 1000, 30)
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'not_cuffed', 'cuffed event without a cuffed bag')
    NPC.states[h1] = 'cuffed'
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'too_far', 'cuff reporter too far')
    nearTo(1, S, h1)
    H.eq(HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 }), true, 'cuff accepted')
    H.eq(#awardsOf(S, 'hostile_arrested'), 1, 'hostile_arrested +1')
    H.eq(awardsOf(S, 'hostile_arrested')[1].opts.count, 1, 'award count 1')
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h1 })
    H.eq(why, 'duplicate', 'second cuff event')
    ok, why = HW.onEvent(ctx, 1, { type = 'cuffed', netId = h2 })
    H.eq(why, 'wrong_state', 'cuff on a hostile that never surrendered')
    H.eq(HW.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event accepted')

    -- a cuff whose event never arrived is picked up from the bag
    local h3 = S.spawned[10].netId
    setHealth(S, h3, 105); NPC.rollResult = true
    HW.onEvent(ctx, 1, { type = 'low_health', netId = h3 })
    NPC.states[h3] = 'cuffed'
    HW.tick(ctx, 1)
    H.eq(#awardsOf(S, 'hostile_arrested'), 2, 'missed cuff event picked up by tick')

    -- a surrendered hostile killed by a non-participant: no fail
    local h4 = S.spawned[11].netId
    setHealth(S, h4, 105); HW.onEvent(ctx, 1, { type = 'low_health', netId = h4 })
    advanceMs(5000)
    HW.onEntityDead(ctx, h4, 77)
    H.eq(#S.fails, 0, 'outsider kill of a surrendered hostile does not fail')

    -- checklist while running
    local cl = HW.checklist(ctx)
    H.eq(cl[1].max, 20, 'checklist max'); H.eq(cl[1].done, false, 'checklist not done')

    -- neutralise the rest -> completion (minSeconds first refuses)
    S.minOk = false
    for _, s in ipairs(S.spawned) do
        if NPC.states[s.netId] ~= 'cuffed' then HW.onEntityDead(ctx, s.netId, 1) end
    end
    HW.tick(ctx, 1)
    H.eq(S.completeCalls >= 1, true, 'complete tried'); H.eq(S.completes, 0, 'refused before minSeconds')
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
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 3 } }, hwLocation(12))
    HW.start(ctx)
    local a, b = S.spawned[1].netId, S.spawned[2].netId
    NPC.rollResult = true
    setHealth(S, a, 110); HW.onEvent(ctx, 1, { type = 'low_health', netId = a })
    HW.onEntityDead(ctx, a, 1)
    H.eq(#S.fails, 0, 'kill within the surrender grace is not a fail')
    setHealth(S, b, 110); HW.onEvent(ctx, 1, { type = 'low_health', netId = b })
    advanceMs(4000)
    HW.onEntityDead(ctx, b, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed a surrendered hostile')
    HW.tick(ctx, 1)
    H.eq(S.completes, 0, 'failed objective never completes')
end

do -- server-dispatched 'damaged' events trigger the same health check (one roll per hostile)
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 3 } }, hwLocation(12))
    HW.start(ctx)
    local a, b = S.spawned[1].netId, S.spawned[2].netId
    local rolls = #NPC.rolls
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'damaged at full health accepted')
    H.eq(#NPC.rolls, rolls, 'no roll at full health')
    setHealth(S, a, 110); NPC.rollResult = true
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'damaged under the threshold')
    H.eq(NPC.states[a], 'surrendered', 'damaged path rolled and surrendered')
    H.eq(HW.onEvent(ctx, 1, { type = 'damaged', netId = a, attacker = 1 }), true, 'later damage accepted')
    H.eq(#NPC.rolls, rolls + 1, 'still one roll')
    local ok, why = HW.onEvent(ctx, 1, { type = 'damaged', netId = 31337 })
    H.eq(why, 'unknown_entity', 'damaged unknown entity')
    H.eq(NPC.states[b], 'hostile', 'other hostile untouched')
end

do -- caps: the wave waits (never cut), big waves spread over ticks
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 12 } }, hwLocation(12))
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
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 7, 7, 6 } }, hwLocation(12))
    HW.start(ctx)
    for i = 1, 5 do HW.onEntityDead(ctx, S.spawned[i].netId, 1) end
    S.canLimit = 3
    HW.tick(ctx, 1)
    H.eq(#withRole(S, 'hostile'), 10, 'wave 2 partly spawned (3 of 7)')
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
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 4 }, boss = { model = 'g_m_y_lost_01', spawn = 'bossSpot' } }, hwLocation(12))
    HW.start(ctx)
    H.eq(#S.spawned, 4, 'boss waits for the last wave')
    HW.onEntityDead(ctx, S.spawned[1].netId, 1)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 4, 'boss waits while more than aliveAtMost are left')
    HW.onEntityDead(ctx, S.spawned[2].netId, 1)
    HW.tick(ctx, 1)
    H.eq(#S.spawned, 5, 'boss spawns when the last wave is down to aliveAtMost')
    local boss = S.spawned[5]
    H.eq(boss.opts.role, 'boss', 'boss role'); H.eq(boss.opts.health, 400, 'boss health')
    H.eq(boss.opts.armour, 100, 'boss armour not scaled'); H.eq(boss.opts.accuracy, 25, 'boss accuracy not scaled')
    H.eq(boss.opts.weapon, 'WEAPON_ASSAULTRIFLE', 'boss weapon')
    H.near(boss.opts.coords.y, 1070, 0.01, 'boss at its own spawn point')
    local cl = HW.checklist(ctx)
    H.eq(#cl, 2, 'boss checklist line'); H.eq(cl[2].done, false, 'boss not done')
    HW.onEntityDead(ctx, S.spawned[3].netId, 1)
    HW.onEntityDead(ctx, S.spawned[4].netId, 1)
    HW.tick(ctx, 1)
    H.eq(S.completes, 0, 'not complete while the boss is up')
    H.eq(lastHud(S, 'detail'), 'block.hostile_waves.detail_boss', 'boss HUD line')
    setHealth(S, boss.netId, 150); NPC.rollResult = true
    H.eq(HW.onEvent(ctx, 1, { type = 'low_health', netId = boss.netId }), true, 'boss low health')
    H.eq(NPC.states[boss.netId], 'surrendered', 'boss surrendered')
    NPC.states[boss.netId] = 'cuffed'
    nearTo(1, S, boss.netId)
    H.eq(HW.onEvent(ctx, 1, { type = 'cuffed', netId = boss.netId }), true, 'boss cuffed')
    local ka = awardsOf(S, 'kingpin_alive')
    H.eq(#ka, 1, 'kingpin_alive awarded'); H.eq(ka[1].opts.points, 50, 'kingpin_alive points hint')
    H.eq(#awardsOf(S, 'hostile_arrested'), 0, 'boss is not a hostile_arrested')
    HW.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete after the boss')
end

do -- restart (test control) removes and respawns
    place(1, 1000, 1000, 30)
    local ctx, S = makeCtx('hostile_waves', { waves = { 3, 3 } }, hwLocation(12))
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

-- ════════════════════════════════════════════════════════════════════════════
-- protect_rescue
-- ════════════════════════════════════════════════════════════════════════════
do -- defaults and validate
    local d = PR.defaults({})
    H.eq(d.minSeconds, 15, 'pr minSeconds'); H.eq(d.presenceRange, 150, 'pr presenceRange')
    H.eq(d.count, 3, 'pr count'); H.eq(d.freeTime, 6000, 'pr freeTime ms'); H.eq(d.hitPenalty, 50, 'pr hitPenalty')
    H.eq(d.restrained, true, 'pr restrained'); H.eq(d.failIfDies, true, 'pr failIfDies'); H.eq(d.safeRadius, 6.0, 'pr safeRadius')
    H.eq(d.npcs, 'hostages', 'pr npcs key'); H.eq(d.safe, 'safe', 'pr safe key')
    H.eq(d.target.label, 'block.protect_rescue.cut_restraints', 'pr target label locale'); H.eq(d.target.distance, 2.0, 'pr target distance')
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
    H.eq(rp[1], 'hostages', 'pr required npcs'); H.eq(rp[2], 'safe', 'pr required safe')
    H.eq(PR.onTimeout({}), nil, 'pr onTimeout fails')
end

do -- spawn in prepare (waiting for room), damage while not current, free, walk to safety
    place(1, 1990, 2000, 20)
    local ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    S.can = false
    PR.prepare(ctx)
    H.eq(#S.spawned, 0, 'no room in prepare')
    S.can = true
    H.step(1000)
    H.eq(#S.spawned, 3, 'hostages spawned by the retry once there is room')
    for _, s in ipairs(S.spawned) do
        H.eq(s.opts.armed, false, 'hostage unarmed'); H.eq(s.opts.role, 'hostage', 'hostage role')
        H.eq(NPC.states[s.netId], 'restrained', 'hostage restrained'); H.eq(s.opts.cfg.group, 'neutral', 'hostage neutral group')
    end
    local h1, h2, h3 = S.spawned[1].netId, S.spawned[2].netId, S.spawned[3].netId
    H.eq(#NPC.damaged, 1, 'onDamaged listener registered once')
    -- hostile fire while objective 1 is current: hurt, no penalty
    NPC.damaged[1](ctx.run, h2, nil)
    H.eq(#S.penalties, 0, 'NPC damage costs nothing')
    -- participant fire: -hitPenalty, the same bullet via two channels counts once
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 1, 'participant hit penalised')
    H.eq(S.penalties[1].id, 'hostage_hit', 'penalty id'); H.eq(S.penalties[1].opts.points, -50, 'penalty value hint')
    H.eq(S.penalties[1].opts.src, nil, 'hostage_hit is shared')
    H.eq(PR.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event accepted')
    H.eq(#S.penalties, 1, 'same hit through shot + onDamaged counts once')
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 1, 'the same bullet reported twice by onDamaged counts once')
    advanceMs(1500)
    NPC.damaged[1](ctx.run, h1, 1)
    H.eq(#S.penalties, 2, 'a later hit counts again')
    NPC.damaged[1](ctx.run, h1, 55)
    H.eq(#S.penalties, 2, 'non-participant hit costs nothing')
    -- 'shot' / 'damaged' can also arrive as client evidence (same shape through server:objective):
    -- while CP.Npc.onDamaged is listened to they are acknowledged and change nothing
    advanceMs(1500)
    H.eq(PR.onEvent(ctx, 1, { type = 'damaged', netId = h1, attacker = 1 }), true, 'damaged event acknowledged')
    H.eq(PR.onEvent(ctx, 1, { type = 'shot', netId = h1, src = 1 }), true, 'shot event acknowledged')
    H.eq(#S.penalties, 2, 'forgeable shot/damaged events never cost hostage_hit')

    PR.start(ctx)
    H.eq(lastHud(S, 'detail'), 'block.protect_rescue.detail', 'pr HUD line when current')
    local ok, why = PR.onEvent(ctx, 1, { type = 'free_start', netId = h1 })
    H.eq(why, 'too_far', 'free_start from the start point is too far')
    nearTo(1, S, h1)
    H.eq(PR.onEvent(ctx, 1, { type = 'free_start', netId = h1 }), true, 'free_start in range')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h1 })
    H.eq(why, 'too_fast', 'freed right away is too fast')
    advanceMs(6000)
    H.eq(PR.onEvent(ctx, 1, { type = 'freed', netId = h1 }), true, 'freed after freeTime')
    H.eq(NPC.states[h1], 'freed', 'bag freed')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h1 })
    H.eq(why, 'duplicate', 'freed twice')
    nearTo(1, S, h2)
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = h2 })
    H.eq(why, 'not_started', 'freed without free_start')
    ok, why = PR.onEvent(ctx, 1, { type = 'freed', netId = 424242 })
    H.eq(why, 'unknown_entity', 'freed unknown hostage')
    local cl = PR.checklist(ctx)
    H.eq(cl[1].value, 1, 'checklist freed 1'); H.eq(cl[1].max, 3, 'checklist max 3'); H.eq(cl[2].value, 0, 'none safe yet')

    moveEnt(S, h1, 2051, 2001, 20)
    PR.tick(ctx, 1)
    H.eq(NPC.states[h1], 'safe', 'freed hostage safe within safeRadius')
    H.eq(S.completes, 0, 'not complete until every hostage is safe')
    for _, h in ipairs({ h2, h3 }) do
        nearTo(1, S, h)
        PR.onEvent(ctx, 1, { type = 'free_start', netId = h })
        advanceMs(6000)
        H.eq(PR.onEvent(ctx, 1, { type = 'freed', netId = h }), true, 'free the others')
        moveEnt(S, h, 2049, 1999, 20)
    end
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete when every hostage is safe')
    H.eq(#awardsOf(S, 'no_hostage_hurt'), 0, 'hurt hostages: no no_hostage_hurt')
    H.eq(#S.fails, 0, 'no fail')
end

do -- clean rescue: no_hostage_hurt once, completion retried after minSeconds
    place(1, 1990, 2000, 20)
    local ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.start(ctx)
    for _, s in ipairs(S.spawned) do
        nearTo(1, S, s.netId)
        PR.onEvent(ctx, 1, { type = 'free_start', netId = s.netId })
        advanceMs(5000)
        PR.onEvent(ctx, 1, { type = 'freed', netId = s.netId })
        moveEnt(S, s.netId, 2050, 2000, 20)
    end
    H.near(PR.presence(ctx, 1, vec3(2050, 2010, 20)), 10, 0.01, 'pr presence = nearest hostage')
    S.minOk = false
    PR.tick(ctx, 1)
    H.eq(S.completes, 0, 'refused before minSeconds')
    S.minOk = true
    PR.tick(ctx, 1)
    H.eq(S.completes, 1, 'completed next tick')
    H.eq(#awardsOf(S, 'no_hostage_hurt'), 1, 'no_hostage_hurt awarded once')
end

do -- deaths
    local ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[1].netId, nil)
    H.eq(S.fails[1], 'block.protect_rescue.fail_died', 'hostage death fails (failIfDies)')

    ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[2].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed a hostage')

    ctx, S = makeCtx('protect_rescue', { failIfDies = false }, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.onEntityDead(ctx, S.spawned[1].netId, nil)
    H.eq(#S.fails, 0, 'failIfDies = false: no fail')
    PR.onEntityDead(ctx, S.spawned[2].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant kill fails even with failIfDies = false')

    ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    W.ents[S.spawned[3].entity].exists = false
    PR.start(ctx)
    H.eq(S.fails[1], 'block.protect_rescue.fail_died', 'a vanished hostage counts as dead')
end

do -- rescale before spawning, restrained = false, restart
    local ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    S.can = false
    PR.prepare(ctx)
    ctx.obj = PR.defaults({ count = 2 })
    PR.rescale(ctx)
    S.can = true
    PR.start(ctx)
    H.eq(#S.spawned, 2, 'rescale: only the new count spawns')
    H.step(1000)
    H.eq(#S.spawned, 2, 'retry thread spawns nothing more')

    ctx, S = makeCtx('protect_rescue', { restrained = false }, prLoc, { index = 2 })
    PR.prepare(ctx)
    H.eq(NPC.states[S.spawned[1].netId], 'idle', 'not restrained: idle until current')
    PR.start(ctx)
    H.eq(NPC.states[S.spawned[1].netId], 'freed', 'not restrained: walk to safety at start')

    ctx, S = makeCtx('protect_rescue', {}, prLoc, { index = 2 })
    PR.prepare(ctx)
    PR.start(ctx)
    PR.restart(ctx)
    H.eq(#S.deleted, 3, 'pr restart deleted hostages')
    H.eq(#S.spawned, 6, 'pr restart respawned hostages')
    H.eq(NPC.states[S.spawned[6].netId], 'restrained', 'respawned restrained')
end

-- ════════════════════════════════════════════════════════════════════════════
-- flee_arrest
-- ════════════════════════════════════════════════════════════════════════════
do -- defaults, validate, armedCount, requiredPoints
    local d = FA.defaults({})
    H.eq(d.mode, 'door', 'fa default mode'); H.eq(d.minSeconds, 30, 'fa minSeconds'); H.eq(d.presenceRange, 250, 'fa presence')
    H.near(d.responses.surrender, 0.5, 1e-9, 'surrender 0.5'); H.near(d.responses.flee, 0.3, 1e-9, 'flee 0.3')
    H.near(d.responses.fight, 0.2, 1e-9, 'fight 0.2')
    H.eq(d.associates.count, 1, 'one associate'); H.eq(d.associates.spawns, 'associates', 'associate key')
    H.eq(d.associates.weapons[1], 'WEAPON_PISTOL', 'associate weapons')
    H.eq(d.knock.label, 'block.flee_arrest.knock', 'knock label locale'); H.eq(d.knock.duration, 3000, 'knock duration')
    H.eq(d.cuff.duration, 5000, 'cuff duration'); H.eq(d.cuff.label, 'block.flee_arrest.cuff', 'cuff label locale')
    H.eq(d.escape.distance, 400, 'escape distance'); H.eq(d.escape.seconds, 20, 'escape seconds')
    H.eq(d.givesUp.aim, 10.0, 'aim distance'); H.eq(d.givesUp.stun, true, 'stun'); H.eq(d.givesUp.close.distance, 3.0, 'close distance')
    H.eq(d.givesUp.close.seconds, 3, 'close seconds'); H.eq(d.armedGivesUp.stun, true, 'armed stun')
    H.eq(d.armedGivesUp.belowHealth, 0.5, 'armed below health'); H.eq(d.aliveBonus.id, 'suspect_alive', 'alive bonus id')
    H.eq(d.fireWithin, 15.0, 'fireWithin'); H.eq(d.door, 'door', 'door key'); H.eq(d.fleeTo, 'fleeTo', 'fleeTo key')
    local s = FA.defaults({ mode = 'scatter' })
    H.eq(s.suspects, 5, 'scatter suspects'); H.near(s.armedShare, 0.4, 1e-9, 'scatter armedShare')
    H.eq(s.models[1], 's_m_y_prisoner_01', 'prison model'); H.eq(s.spawns, 'spawns', 'scatter spawns'); H.eq(s.routes, 'routes', 'routes')
    local l = FA.defaults({ givesUp = { 'aim', 'close' } })
    H.eq(l.givesUp.aim, 10.0, 'list form aim'); H.eq(l.givesUp.stun, false, 'list form no stun')
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
    H.eq(FA.armedCount({ responses = { surrender = 0.5, flee = 0.5, fight = 0 }, associates = { count = 2 } }), 2, 'door without fight')
    H.eq(FA.armedCount({ mode = 'scatter' }), 5, 'scatter: every suspect counts when armedShare > 0')
    H.eq(FA.armedCount({ mode = 'scatter', armedShare = 0 }), 0, 'scatter unarmed')
    local rp = FA.requiredPoints({})
    H.eq(table.concat(rp, ','), 'door,suspect,fleeTo,associates', 'door required points')
    H.eq(table.concat(FA.requiredPoints({ mode = 'scatter' }), ','), 'spawns,routes', 'scatter required points')
    H.eq(FA.onTimeout({}), nil, 'fa onTimeout fails')
end

local function knockOpen(ctx, S)
    place(1, 3041, 3000, 10)
    FA.onEvent(ctx, 1, { type = 'knock_start' })
    advanceMs(3000)
    return FA.onEvent(ctx, 1, { type = 'knock' })
end

do -- door: surrender at the door, knock checks, cuff, associate, completion
    place(1, 3000, 3000, 10)
    local ctx, S = makeCtx('flee_arrest', { responses = { surrender = 1, flee = 0, fight = 0 } }, doorLoc)
    FA.prepare(ctx)
    FA.start(ctx)
    H.eq(#S.spawned, 2, 'suspect + 1 associate spawned')
    local sus, asc = withRole(S, 'suspect')[1], withRole(S, 'associate')[1]
    H.eq(sus.opts.armed, false, 'surrendering suspect unarmed'); H.eq(asc.opts.armed, true, 'associate armed')
    H.eq(asc.opts.weapon, 'WEAPON_PISTOL', 'associate pistol'); H.eq(asc.opts.accuracy, 35, 'associate accuracy + tier')
    H.eq(asc.opts.armour, 25, 'associate armour + tier')
    H.near(sus.opts.coords.x, 3045, 0.01, 'suspect inside at the suspect point')
    H.eq(lastHud(S, 'detail'), 'block.flee_arrest.detail_knock', 'HUD asks to knock')
    FA.tick(ctx, 1)
    H.eq(S.completes, 0, 'nothing before the knock')
    local ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'too_far', 'knock from the start is too far')
    place(1, 3041, 3000, 10)
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'not_started', 'knock without knock_start')
    H.eq(FA.onEvent(ctx, 1, { type = 'knock_start' }), true, 'knock_start at the door')
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'too_fast', 'knock finished too fast')
    advanceMs(3000)
    H.eq(FA.onEvent(ctx, 1, { type = 'knock' }), true, 'knock accepted')
    ok, why = FA.onEvent(ctx, 1, { type = 'knock' })
    H.eq(why, 'duplicate', 'second knock')
    H.eq(NPC.states[sus.netId], 'surrendered', 'suspect surrendered at the door')
    H.near(posOf(S, sus.netId).x, 3039, 0.01, 'suspect placed 1 m outside the door')
    H.eq(NPC.cuffs[sus.netId].duration, 5000, 'cuff enabled with cuff.duration')
    H.eq(NPC.states[asc.netId], 'hostile', 'associate fights')
    H.eq(lastHud(S, 'message').text, 'block.flee_arrest.response_surrender', 'response message')
    H.eq(lastSend(S).knocked, true, 'clients told about the knock')

    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = asc.netId })
    H.eq(why, 'armed', 'aiming does not make an armed associate give up')
    NPC.states[sus.netId] = 'cuffed'
    place(1, 3039.5, 3000, 10)
    H.eq(FA.onEvent(ctx, 1, { type = 'cuffed', netId = sus.netId }), true, 'suspect cuffed')
    local sa = awardsOf(S, 'suspect_alive')
    H.eq(#sa, 1, 'suspect_alive awarded'); H.eq(sa[1].opts.count, 1, 'count 1')
    local cl = FA.checklist(ctx)
    H.eq(cl[1].done, true, 'checklist knock'); H.eq(cl[2].done, true, 'checklist suspect'); H.eq(cl[3].done, false, 'associate left')
    H.near(FA.presence(ctx, 1, vec3(3046, 3015, 10)), 10, 0.01, 'presence = nearest suspect not cuffed')
    FA.onEntityDead(ctx, asc.netId, 1)
    H.eq(#S.fails, 0, 'killing an armed associate is fine')
    FA.tick(ctx, 1)
    H.eq(S.completes, 1, 'door complete')
    H.eq(#awardsOf(S, 'suspect_alive'), 1, 'associates earn nothing')
end

do -- door: flee response, aim and escape
    place(1, 3000, 3000, 10)
    local ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    H.eq(#S.spawned, 1, 'no associates')
    local sus = S.spawned[1]
    H.eq(knockOpen(ctx, S), true, 'knock')
    H.eq(NPC.states[sus.netId], 'fleeing', 'suspect flees')
    H.eq(type(sus.opts.cfg.fleePoints), 'table', 'flee points in the bag cfg')
    place(1, 3000, 3000, 10)
    local ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId })
    H.eq(why, 'too_far', 'aim from 45 m is too far')
    nearTo(1, S, sus.netId, 5.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId }), true, 'aim within 10 m')
    H.eq(NPC.states[sus.netId], 'surrendered', 'gave up on aim')
    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = sus.netId })
    H.eq(why, 'duplicate', 'aim again')

    -- escape: more than escape.distance from every participant for escape.seconds
    place(1, 3000, 3000, 10)
    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    knockOpen(ctx, S)
    place(1, 3600, 3000, 10)
    for _ = 1, 10 do FA.tick(ctx, 1) end
    H.eq(lastHud(S, 'detail'), 'block.flee_arrest.escaping', 'escape warning on the HUD')
    H.eq(lastSend(S).escaping, 10, 'escape countdown sent to clients')
    place(1, 3050, 3000, 10)
    FA.tick(ctx, 1)
    place(1, 3600, 3000, 10)
    for _ = 1, 19 do FA.tick(ctx, 1) end
    H.eq(#S.fails, 0, 'coming back reset the escape timer')
    FA.tick(ctx, 1)
    H.eq(S.fails[1], 'block.flee_arrest.fail_escaped', 'suspect escaped')

    -- killing the unarmed fleeing suspect fails
    place(1, 3000, 3000, 10)
    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 1, fight = 0 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    knockOpen(ctx, S)
    FA.onEntityDead(ctx, S.spawned[1].netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'killed an unarmed fleeing suspect')
end

do -- door: fight response, stun, low health, death before the knock
    place(1, 3000, 3000, 10)
    local ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    local sus = S.spawned[1]
    H.eq(sus.opts.armed, true, 'fighting suspect armed'); H.eq(sus.opts.weapon, 'WEAPON_PISTOL', 'with a pistol')
    knockOpen(ctx, S)
    H.eq(NPC.states[sus.netId], 'hostile', 'suspect fights')
    place(1, 3200, 3000, 10)
    local ok, why = FA.onEvent(ctx, 1, { type = 'stunned', netId = sus.netId })
    H.eq(why, 'too_far', 'stun needs a participant nearby')
    nearTo(1, S, sus.netId, 8.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = sus.netId }), true, 'armed suspect gives up when stunned')
    H.eq(NPC.states[sus.netId], 'surrendered', 'surrendered after stun')

    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    knockOpen(ctx, S)
    nearTo(1, S, sus.netId, 20.0)
    ok, why = FA.onEvent(ctx, 1, { type = 'low_health', netId = sus.netId })
    H.eq(why, 'health_ok', 'low_health refused at full health')
    setHealth(S, sus.netId, 140)
    FA.tick(ctx, 1)
    H.eq(NPC.states[sus.netId], 'surrendered', 'armed suspect gives up below 50% health (server poll)')

    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    knockOpen(ctx, S)
    H.eq(FA.onEvent(ctx, 1, { type = 'damaged', netId = sus.netId, attacker = 1 }), true, 'damaged at full health accepted')
    H.eq(NPC.states[sus.netId], 'hostile', 'still fighting')
    setHealth(S, sus.netId, 130)
    H.eq(FA.onEvent(ctx, 1, { type = 'damaged', netId = sus.netId, attacker = 1 }), true, 'damaged below 50%')
    H.eq(NPC.states[sus.netId], 'surrendered', 'damaged path makes the armed suspect give up')

    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 }, associates = { count = 0 } }, doorLoc)
    FA.start(ctx)
    sus = S.spawned[1]
    knockOpen(ctx, S)
    FA.onEntityDead(ctx, sus.netId, 1)
    H.eq(#S.fails, 0, 'killing the suspect while he fights is allowed')
    FA.tick(ctx, 1)
    H.eq(S.completes, 1, 'complete: suspect killed while fighting')
    H.eq(#awardsOf(S, 'suspect_alive'), 0, 'no suspect_alive for a dead suspect')

    place(1, 3000, 3000, 10)
    ctx, S = makeCtx('flee_arrest', { responses = { surrender = 0, flee = 0, fight = 1 } }, doorLoc)
    FA.start(ctx)
    FA.onEntityDead(ctx, withRole(S, 'associate')[1].netId, 1)
    H.eq(ctx.state.knocked, true, 'a death before the knock reveals the response')
    H.eq(NPC.states[withRole(S, 'suspect')[1].netId], 'hostile', 'suspect reacts')
end

do -- door: associates wait for room and rescale
    place(1, 3000, 3000, 10)
    local ctx, S = makeCtx('flee_arrest', { responses = { surrender = 1, flee = 0, fight = 0 }, associates = { count = 3 } }, doorLoc)
    S.canLimit = 2
    FA.start(ctx)
    H.eq(#S.spawned, 2, 'suspect + 1 associate fit')
    ctx.obj = FA.defaults({ responses = { surrender = 1, flee = 0, fight = 0 }, associates = { count = 2 } })
    FA.rescale(ctx)
    S.canLimit = nil
    FA.tick(ctx, 1)
    H.eq(#withRole(S, 'associate'), 2, 'rescale: associates topped up to the new count')
    FA.tick(ctx, 1)
    H.eq(#withRole(S, 'associate'), 2, 'no extra associates')
end

do -- scatter: spawn, armed share, fire range, aim/stun/close/health give-ups, cuffs, completion
    place(1, 4000, 4000, 30)
    local ctx, S = makeCtx('flee_arrest', { mode = 'scatter', aliveBonus = { id = 'inmate_alive', points = 10, each = true } }, scatterLoc)
    FA.prepare(ctx)
    FA.start(ctx)
    H.eq(#S.spawned, 5, '5 inmates')
    local armed = U.filter(S.spawned, function(s) return s.opts.armed end)
    local unarmed = U.filter(S.spawned, function(s) return not s.opts.armed end)
    H.eq(#armed, 2, '2 in every 5 armed')
    for _, s in ipairs(S.spawned) do
        H.eq(s.opts.role, 'inmate', 'inmate role'); H.eq(s.opts.model, 's_m_y_prisoner_01', 'prison clothes')
        H.eq(NPC.states[s.netId], 'fleeing', 'inmates flee'); H.ok(s.opts.cfg.route == 1 or s.opts.cfg.route == 2, 'route assigned')
        H.eq(type(s.opts.cfg.fleePoints), 'table', 'route points in cfg')
    end
    for _, s in ipairs(armed) do H.eq(s.opts.weapon, 'WEAPON_PISTOL', 'armed with a pistol') end
    H.eq(lastHud(S, 'detail'), 'block.flee_arrest.detail_scatter', 'scatter HUD line')

    local a1, a2 = armed[1].netId, armed[2].netId
    local c = posOf(S, a1)
    place(1, c.x, c.y + 10, c.z)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a1], 'hostile', 'armed inmate fires when a participant is within fireWithin')
    place(1, c.x, c.y + 30, c.z)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a1], 'fleeing', 'back to fleeing once clear')
    local ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = a1 })
    H.eq(why, 'armed', 'armed inmates ignore aim')
    nearTo(1, S, a1, 5.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = a1 }), true, 'armed inmate stunned')
    H.eq(NPC.states[a1], 'surrendered', 'armed inmate gave up')
    nearTo(1, S, a2, 12.0)
    setHealth(S, a2, 140)
    FA.tick(ctx, 1)
    H.eq(NPC.states[a2], 'surrendered', 'armed inmate below 50% gives up')

    local u1, u2, u3 = unarmed[1].netId, unarmed[2].netId, unarmed[3].netId
    nearTo(1, S, u1, 20.0)
    ok, why = FA.onEvent(ctx, 1, { type = 'aim', netId = u1 })
    H.eq(why, 'too_far', 'aim from 20 m refused')
    nearTo(1, S, u1, 6.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'aim', netId = u1 }), true, 'aim within 10 m')
    nearTo(1, S, u2, 2.0)
    FA.tick(ctx, 1); FA.tick(ctx, 1)
    H.eq(NPC.states[u2], 'fleeing', 'close for 2 s: not yet')
    FA.tick(ctx, 1)
    H.eq(NPC.states[u2], 'surrendered', 'close for 3 s: gives up')
    nearTo(1, S, u3, 8.0)
    H.eq(FA.onEvent(ctx, 1, { type = 'stunned', netId = u3 }), true, 'unarmed inmate stunned')

    local cl = FA.checklist(ctx)
    H.eq(cl[1].max, 5, 'scatter checklist max'); H.eq(cl[1].value, 0, 'none in custody yet')
    for _, s in ipairs(S.spawned) do NPC.states[s.netId] = 'cuffed' end
    FA.tick(ctx, 1)
    local ia = awardsOf(S, 'inmate_alive')
    H.eq(#ia, 5, 'inmate_alive for every inmate cuffed alive'); H.eq(ia[1].opts.points, 10, 'inmate_alive points hint')
    H.eq(S.completes, 1, 'scatter complete when every inmate is in custody')
    H.eq(#S.fails, 0, 'no fail')
end

do -- scatter: caps, rescale, escape, no spawn inside the prison, killing an unarmed inmate
    place(1, 4000, 4000, 30)
    local ctx, S = makeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    S.can = false
    FA.start(ctx)
    H.eq(#S.spawned, 0, 'scatter waits for room')
    S.can = true
    FA.tick(ctx, 1)
    H.eq(#S.spawned, 5, 'scatter spawned when room frees')

    ctx, S = makeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
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

    ctx, S = makeCtx('flee_arrest', { mode = 'scatter', escape = { distance = 600, seconds = 30 } }, scatterLoc)
    FA.start(ctx)
    place(1, 5000, 5000, 30)
    for _ = 1, 29 do FA.tick(ctx, 1) end
    H.eq(#S.fails, 0, 'not escaped before escape.seconds')
    FA.tick(ctx, 1)
    H.eq(S.fails[1], 'block.flee_arrest.fail_escaped', 'inmate escaped after 30 s beyond 600 m')

    place(1, 1900, 2600, 45)
    ctx, S = makeCtx('flee_arrest', { mode = 'scatter' }, prisonLoc)
    FA.start(ctx)
    H.eq(#S.spawned, 0, 'nothing spawns inside the prison walls')
    H.eq(S.fails[1], 'block.flee_arrest.fail_setup', 'no usable spawn point fails the setup')

    local mixed = { label = 'Mixed', start = scatterLoc.start, routes = scatterLoc.routes,
        spawns = { vec4(1770.0, 2570.0, 45.0, 0.0), vec4(4040.0, 4000.0, 30.0, 0.0), vec4(4060.0, 4000.0, 30.0, 0.0) } }
    ctx, S = makeCtx('flee_arrest', { mode = 'scatter', suspects = 4 }, mixed)
    FA.start(ctx)
    H.eq(#S.spawned, 4, 'mixed points: all inmates spawned')
    local inside = 0
    for _, s in ipairs(S.spawned) do if s.opts.coords.x < 2000 then inside = inside + 1 end end
    H.eq(inside, 0, 'the point inside the prison is never used')

    place(1, 4000, 4000, 30)
    ctx, S = makeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    FA.start(ctx)
    local un = U.filter(S.spawned, function(s) return not s.opts.armed end)[1]
    FA.onEntityDead(ctx, un.netId, 77)
    H.eq(#S.fails, 0, 'an outsider kill is not a participant kill')
    local un2 = U.filter(S.spawned, function(s) return not s.opts.armed end)[2]
    FA.onEntityDead(ctx, un2.netId, 1)
    H.eq(S.fails[1], 'run.fail_killed_unarmed', 'participant killed an unarmed inmate')

    ctx, S = makeCtx('flee_arrest', { mode = 'scatter' }, scatterLoc)
    FA.start(ctx)
    FA.restart(ctx)
    H.eq(#S.deleted, 5, 'fa restart deleted inmates'); H.eq(#S.spawned, 10, 'fa restart respawned inmates')
    FA.stop(ctx)
    FA.tick(ctx, 1)
    H.eq(#S.spawned, 10, 'stopped: nothing more')
end

-- ════════════════════════════════════════════════════════════════════════════
-- locale part: valid JSON, every referenced key present
-- ════════════════════════════════════════════════════════════════════════════
do
    local f = assert(io.open(H.root .. 'locales/parts/blocks_b.json', 'r'))
    local raw = f:read('a'); f:close()
    local ok, parts = pcall(cjson.decode, raw)
    H.ok(ok and type(parts) == 'table', 'blocks_b.json is valid JSON')
    local files = {
        'blocks/hostile_waves/server.lua', 'blocks/hostile_waves/client.lua',
        'blocks/protect_rescue/server.lua', 'blocks/protect_rescue/client.lua',
        'blocks/flee_arrest/server.lua', 'blocks/flee_arrest/client.lua',
    }
    local n = 0
    for _, rel in ipairs(files) do
        local h = assert(io.open(H.root .. rel, 'r'))
        local src = h:read('a'); h:close()
        for key in src:gmatch("'(block%.[%w_%.]+)'") do
            n = n + 1
            H.ok(parts[key] ~= nil, 'locale key present: ' .. key)
        end
        for key in src:gmatch("'(run%.[%w_%.]+)'") do
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
