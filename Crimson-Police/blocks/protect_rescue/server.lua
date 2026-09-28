--[[ blocks/protect_rescue/server.lua · objective block "protect_rescue" (server half)

  What it does
    Spawns the NPCs to protect (hostages) when the run moves to In progress (prepare), kneeling with
    their hands tied (state 'restrained', relationship group CRIMSONPOLICE_NEUTRAL through the cp
    bag cfg; they are not invincible and can die). When this objective becomes current (in Hostage
    Rescue: after the hostiles of objective 1 are neutralised) participants free each hostage with
    ox_target "Cut restraints" (freeTime progress): the client reports 'free_start' then 'freed'
    and the server checks the distance (server-side coordinates) and the elapsed time. A freed
    hostage walks to the safe marker (host AI, CP.Npc task follow) and becomes 'safe' once the
    server sees it within safeRadius of it. Completed when every hostage is safe.
    With restrained = false the hostages start cowering ('idle') and walk to safety when the
    objective starts. Hostages are watched for the whole run, also while an earlier objective is
    current: damage by a participant costs hitPenalty (penalty hostage_hit, shared), any damage
    loses the no_hostage_hurt bonus, a death fails the run (failIfDies), and a hostage killed by a
    participant always fails it (run.fail_killed_unarmed).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.protect_rescue)
    minSeconds [15] · presenceRange [presenceRange[3] = 150] · label
    npcs        location key: list of vec4 (hostage spots; reused with an offset when fewer than count) ['hostages']
    count       hostages                                         [npcs[3] = 3]
    peds        ped models                                       [Config.Blocks.protect_rescue.peds]
    restrained  hands tied until freed                           [restrained.default = true]
    freeTime    ms of "Cut restraints" progress                  [freeTime[3] * 1000 = 6000]
    target      { label [locale block.protect_rescue.cut_restraints], icon ['fas fa-scissors'], distance [2.0] }
    safe        location key: vec3 (the safe marker)             ['safe']
    safeRadius  metres                                           [6.0]
    hitPenalty  points per hit by participant fire (0 = off)     [hitPenalty[3] = 50]
    failIfDies  a hostage death fails the run                    [failIfDies.default = true]

  Evidence accepted (onEvent)
    { type = 'free_start', netId }   a participant started cutting (within target.distance + slack)
    { type = 'freed', netId }        cutting finished: same participant, in range, at least
                                     FREE_SHARE × freeTime after its free_start (one pending cut
                                     per participant: a new free_start replaces the previous one)
    { type = 'shot', netId, src }    CP.Npc (CP.Runs.dispatch): a participant shot a restrained hostage
    { type = 'damaged', netId, attacker }  CP.Npc (CP.Runs.dispatch): a hostage took damage
    CP.Npc.onDamaged(run, netId, attackerSrc) is the damage channel: it is server-only and fires for
    every hit on a hostage. While it is listened to, 'shot' / 'damaged' are acknowledged without
    effect, because onEvent cannot tell a dispatch from the same shape sent as client evidence
    (a client could otherwise cost the team hostage_hit). Without onDamaged they count instead.
    One hit per hostage and attacker is counted per HIT_WINDOW_MS (one bullet, one penalty).
    no_hostage_hurt is recorded only once minSeconds has passed since the start (a completion
    refused as too fast must not keep a bonus a later hit would have cost).

  Bonus / penalty ids recorded (shared)
    hostage_hit      ctx.penalize, count 1 per counted hit by participant fire (points hint -hitPenalty)
    no_hostage_hurt  ctx.award once at completion when no hostage was ever damaged
  Fail reason keys: block.protect_rescue.fail_died · run.fail_killed_unarmed

  ctx.state
    block, rng, peds = { [tostring(netId)] = { netId, entity, index, state, hurt } }, spawned, order,
    freeing = { [netIdKey] = { [srcKey] = ms } }, lastHit = { ['netId:src'] = ms }, hurt, hits,
    bonusGiven, current, startedAt, dirty, hudText, completed, failed, stopped
]]

local BLOCK = 'protect_rescue'
local U = CP.U

local REACH_SLACK    = 2.0     -- metres of position lag allowed around interaction ranges
local TARGET_RANGE   = 2.0     -- default ox_target distance for "Cut restraints"
local FREE_SHARE     = 0.8     -- 'freed' must arrive at least this share of freeTime after 'free_start'
local HIT_WINDOW_MS  = 1000    -- one counted hit per hostage and attacker in this window
local REUSE_OFFSET   = 1.0     -- metres between hostages sharing a spot
local SAFE_RADIUS    = 6.0
local DEFAULT_ICON   = 'fas fa-scissors'
local RETRY_MS       = 1000    -- prepare-time spawns waiting for room retry this often

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

-- ── Defaults and validation ─────────────────────────────────────────────────
local function defaults(obj)
    local c = cfg()
    if obj.minSeconds == nil then obj.minSeconds = 15 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.npcs == nil then obj.npcs = 'hostages' end
    if obj.count == nil then obj.count = c.npcs[3] end
    if obj.peds == nil then obj.peds = U.copy(c.peds) end
    if obj.restrained == nil then obj.restrained = c.restrained.default end
    if obj.freeTime == nil then obj.freeTime = c.freeTime[3] * 1000 end
    if type(obj.target) ~= 'table' then obj.target = {} end
    if obj.target.label == nil then obj.target.label = CP.L('block.protect_rescue.cut_restraints') end
    if obj.target.icon == nil then obj.target.icon = DEFAULT_ICON end
    if obj.target.distance == nil then obj.target.distance = TARGET_RANGE end
    if obj.safe == nil then obj.safe = 'safe' end
    if obj.safeRadius == nil then obj.safeRadius = SAFE_RADIUS end
    if obj.hitPenalty == nil then obj.hitPenalty = c.hitPenalty[3] end
    if obj.failIfDies == nil then obj.failIfDies = c.failIfDies.default end
    return obj
end

local function checkLocation(o, loc, li, strict)
    local pts = pointList(loc, o.npcs)
    if #pts == 0 then
        return bad('block.protect_rescue.invalid.points_missing', { key = tostring(o.npcs), location = li })
    end
    if #pointList(loc, o.safe) == 0 then
        return bad('block.protect_rescue.invalid.points_missing', { key = tostring(o.safe), location = li })
    end
    if strict and #pts < o.count then
        return bad('block.protect_rescue.invalid.points_count', { location = li, min = o.count, have = #pts })
    end
    -- no-build zones for every mission (docs/CRIMSON_ARENA.md rule 7); NPC spots are spawn points, so
    -- custom missions also keep them Config.Builder.minSpawnFromStart away from the start
    local start = loc.start and loc.start.coords
    for _, p in ipairs(pts) do
        if inNoBuild(p) then return bad('block.protect_rescue.invalid.points_zone', { location = li }) end
        if strict and start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
            return bad('block.protect_rescue.invalid.points_start', { location = li, min = Config.Builder.minSpawnFromStart })
        end
    end
    if inNoBuild(pointList(loc, o.safe)[1]) then return bad('block.protect_rescue.invalid.points_zone', { location = li }) end
    return true
end

local function validate(obj, mission, location)
    if type(obj) ~= 'table' then return bad('block.protect_rescue.invalid.objective') end
    local c = cfg()
    local o = defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')

    if not isNum(o.minSeconds) or o.minSeconds < 0 then return bad('block.protect_rescue.invalid.min_seconds') end
    if not inRange(o.presenceRange, c.presenceRange) then
        return bad('block.protect_rescue.invalid.range', { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
    end
    if not isInt(o.count) or not inRange(o.count, c.npcs) then
        return bad('block.protect_rescue.invalid.range', { field = 'count', min = c.npcs[1], max = c.npcs[2] })
    end
    if not allAllowed(o.peds, strict and Config.Builder.allowed.peds or nil) then return bad('block.protect_rescue.invalid.peds') end
    if type(o.restrained) ~= 'boolean' then return bad('block.protect_rescue.invalid.flags') end
    if type(o.failIfDies) ~= 'boolean' then return bad('block.protect_rescue.invalid.flags') end
    if not inRange(o.freeTime, c.freeTime, 1000) then
        return bad('block.protect_rescue.invalid.range', { field = 'freeTime', min = c.freeTime[1], max = c.freeTime[2] })
    end
    if type(o.target.label) ~= 'string' or o.target.label == '' or not isNum(o.target.distance) or o.target.distance <= 0 then
        return bad('block.protect_rescue.invalid.target')
    end
    if not isNum(o.safeRadius) or o.safeRadius <= 0 then return bad('block.protect_rescue.invalid.safe_radius') end
    if not inRange(o.hitPenalty, c.hitPenalty) then
        return bad('block.protect_rescue.invalid.range', { field = 'hitPenalty', min = c.hitPenalty[1], max = c.hitPenalty[2] })
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

local function requiredPoints(obj)
    local o = defaults(U.deepcopy(obj))
    local out = {}
    if type(o.npcs) == 'string' then out[#out + 1] = o.npcs end
    if type(o.safe) == 'string' then out[#out + 1] = o.safe end
    return out
end

-- ── Run state ───────────────────────────────────────────────────────────────
local ctxByState = setmetatable({}, { __mode = 'k' })
local listening = false

local function stateOf(ctx)
    defaults(ctx.obj)
    local st = ctx.state
    if not st.block then
        st.block = BLOCK
        st.peds = {}
        st.spawned = 0
        st.freeing = {}
        st.lastHit = {}
        st.hurt = false
        st.hits = 0
    end
    ctxByState[st] = ctx
    return st
end

local function target(ctx)
    return math.max(0, math.floor((tonumber(ctx.obj.count) or 0) + 0.5))
end

local function safePoint(ctx)
    return pointList(ctx.location, ctx.obj.safe)[1]
end

local function tally(st)
    local living, freed, safe = 0, 0, 0
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            living = living + 1
            if p.state == 'freed' or p.state == 'safe' then freed = freed + 1 end
            if p.state == 'safe' then safe = safe + 1 end
        end
    end
    return living, freed, safe
end

local function updateHud(ctx, st)
    local living, _, safe = tally(st)
    local total = math.max(living, target(ctx) - (st.spawned - living))
    local text = CP.L('block.protect_rescue.detail', { safe = safe, total = total })
    if text ~= st.hudText then
        st.hudText = text
        ctx.hud({ detail = text, value = safe, max = total })
    end
end

local function flush(ctx, st)
    if st.dirty then
        st.dirty = false
        local list = {}
        for _, p in pairs(st.peds) do
            list[#list + 1] = { netId = p.netId, state = p.state, index = p.index }
        end
        table.sort(list, function(a, b) return a.index < b.index end)
        ctx.send({ peds = list })
    end
    if st.current then updateHud(ctx, st) end
end

local function setPed(ctx, st, p, state)
    p.state = state
    CP.Npc.setState(ctx.run, p.netId, state)
    st.dirty = true
end

local function spawnLoop(ctx, st, want, pts)
    local ok = true
    while st.spawned < want do
        if not ctx.canSpawn(1, false) then ok = false break end
        local i = st.spawned + 1
        local k = ((i - 1) % #pts) + 1
        local lap = (i - 1) // #pts
        local base = pts[st.order[k]]
        local point = lap == 0 and toVec4(base) or toVec4(base, math.cos(lap + k) * REUSE_OFFSET * lap, math.sin(lap + k) * REUSE_OFFSET * lap)
        local initial = ctx.obj.restrained ~= false and 'restrained' or 'idle'
        local model = rngOf(ctx):pick(ctx.obj.peds) or cfg().peds[1]
        local ent, netId = ctx.spawnPed({
            model = model, coords = point, role = 'hostage', armed = false,
            cfg = { group = 'neutral', restrained = initial == 'restrained' },
            tag = 'hostage' .. i,
        })
        if not netId then ok = false break end
        st.peds[tostring(netId)] = { netId = netId, entity = ent, index = i, state = initial, hurt = false }
        st.spawned = i
        CP.Npc.setState(ctx.run, netId, initial)
        st.dirty = true
        if st.stopped then ok = false break end
    end
    return ok
end

-- Spawns the hostages still missing (distinct spots first); false while waiting for room. The
-- spawning flag (re-entry while ctx.spawnPed yields) is always cleared, even when a spawn throws.
local function spawnMissing(ctx, st)
    local want = target(ctx)
    if st.spawned >= want then return true end
    if st.spawning or st.stopped then return false end
    local pts = pointList(ctx.location, ctx.obj.npcs)
    if #pts == 0 then
        local s = ctx.location and ctx.location.start and ctx.location.start.coords
        if s then pts = { s } end
        CP.warn(BLOCK, 'no hostage points at %s for run %s; using the start point', tostring(ctx.obj.npcs), tostring(ctx.run and ctx.run.id))
    end
    if #pts == 0 then return false end
    if not st.order or #st.order ~= #pts then
        local idx = {}
        for i = 1, #pts do idx[i] = i end
        st.order = rngOf(ctx):shuffle(idx)
    end
    st.spawning = true
    local okCall, ok = pcall(spawnLoop, ctx, st, want, pts)
    st.spawning = false
    if not okCall then
        CP.err(BLOCK, 'spawning hostages for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(ok))
        return false
    end
    return ok and st.spawned >= want
end

-- ── Damage and deaths (also while another objective is current) ─────────────
local function hit(ctx, st, key, attacker)
    local p = st.peds[key]
    if not p or p.state == 'dead' then return false end
    p.hurt = true
    if not st.hurt then
        st.hurt = true
        st.dirty = true
    end
    attacker = tonumber(attacker)
    local pen = tonumber(ctx.obj.hitPenalty) or 0
    if not attacker or pen <= 0 or not isParticipant(ctx, attacker) then return true end
    local k = key .. ':' .. tostring(attacker)
    local t = now()
    local last = st.lastHit[k]
    if last and t - last < HIT_WINDOW_MS then return true end
    st.lastHit[k] = t
    st.hits = (st.hits or 0) + 1
    ctx.penalize('hostage_hit', { count = 1, points = -pen })
    return true
end

local function died(ctx, st, key, killerSrc)
    local p = st.peds[key]
    if not p or p.state == 'dead' then return end
    p.state = 'dead'
    p.hurt = true
    st.hurt = true
    st.dirty = true
    if st.failed then return end
    if isParticipant(ctx, killerSrc) then
        st.failed = true
        ctx.fail('run.fail_killed_unarmed')
    elseif ctx.obj.failIfDies ~= false then
        st.failed = true
        ctx.fail('block.protect_rescue.fail_died')
    end
end

-- Hostage entities that vanished without a death event count as dead.
local function checkGone(ctx, st)
    for key, p in pairs(st.peds) do
        if p.state ~= 'dead' and (not p.entity or not DoesEntityExist(p.entity)) then
            died(ctx, st, key, nil)
        end
    end
end

local function findState(run, netId)
    if type(run) ~= 'table' or type(run.objectives) ~= 'table' then return nil end
    local key = tostring(netId)
    for _, o in pairs(run.objectives) do
        local st = type(o) == 'table' and o.state or nil
        if type(st) == 'table' and st.block == BLOCK and type(st.peds) == 'table' and st.peds[key] then return st end
    end
    return nil
end

local function listen()
    if listening or not CP.Npc or not CP.Npc.onDamaged then return end
    listening = true
    CP.Npc.onDamaged(function(run, netId, attackerSrc)
        local st = findState(run, netId)
        local ctx = st and ctxByState[st]
        if not ctx then return end
        hit(ctx, st, tostring(netId), attackerSrc)
        flush(ctx, st)
    end)
end

local function tryComplete(ctx, st)
    if st.completed or st.failed or st.stopped or not st.current then return end
    if st.spawned < target(ctx) then return end
    local living = 0
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            living = living + 1
            if p.state ~= 'safe' then return end
        end
    end
    -- The bonus must be recorded before ctx.complete (completing the last objective ends the run
    -- and scores it), but a completion refused for minSeconds would leave it recorded while a
    -- hostage can still be hurt: award it only once the minimum time has passed.
    local minMs = (tonumber(ctx.obj.minSeconds) or 0) * 1000
    local early = st.startedAt ~= nil and now() - st.startedAt < minMs
    if not early and not st.hurt and not st.bonusGiven then
        st.bonusGiven = true
        ctx.award('no_hostage_hurt', { count = 1 })
    end
    if ctx.complete({ safe = living, hits = st.hits or 0 }) ~= false then
        st.completed = true
    end
end

local function releaseIdle(ctx, st)
    if ctx.obj.restrained ~= false then return end
    for _, p in pairs(st.peds) do
        if p.state == 'idle' then setPed(ctx, st, p, 'freed') end
    end
end

-- ── Hooks ───────────────────────────────────────────────────────────────────
local function prepare(ctx)
    local st = stateOf(ctx)
    listen()
    if not spawnMissing(ctx, st) then
        CreateThread(function()
            while not st.stopped and not st.failed and st.spawned < target(ctx)
                and not (ctx.run and ctx.run.state == 'ended') do
                Wait(RETRY_MS)
                if not st.current then spawnMissing(ctx, st) end
                flush(ctx, st)
            end
        end)
    end
    flush(ctx, st)
end

local function start(ctx)
    local st = stateOf(ctx)
    listen()
    st.current = true
    st.startedAt = st.startedAt or now()
    spawnMissing(ctx, st)
    checkGone(ctx, st)
    if st.failed then return end
    releaseIdle(ctx, st)
    st.dirty = true
    flush(ctx, st)
end

local function tick(ctx)
    local st = stateOf(ctx)
    if st.stopped or st.failed then return end
    st.current = true
    if not st.completed then
        spawnMissing(ctx, st)
        releaseIdle(ctx, st)
        checkGone(ctx, st)
        if st.failed then return end
        local safe = safePoint(ctx)
        local r = tonumber(ctx.obj.safeRadius) or SAFE_RADIUS
        if safe then
            for _, p in pairs(st.peds) do
                if p.state == 'freed' then
                    local c = pedCoords(p)
                    if c and U.dist(c, safe) <= r then setPed(ctx, st, p, 'safe') end
                end
            end
        end
    end
    tryComplete(ctx, st)
    flush(ctx, st)
end

local function inReach(ctx, src, p)
    local pc, sc = pedCoords(p), ctx.coords(src)
    local reach = (tonumber(ctx.obj.target.distance) or TARGET_RANGE) + REACH_SLACK
    return pc ~= nil and sc ~= nil and U.dist(pc, sc) <= reach
end

local function onEvent(ctx, src, ev)
    local st = stateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local netId = tonumber(ev.netId)
    local key = netId and tostring(netId) or nil
    local p = key and st.peds[key] or nil
    local t = ev.type
    local ok, why = true, nil
    if t == 'free_start' or t == 'freed' then
        if not p then return false, 'unknown_entity' end
        if p.state == 'freed' or p.state == 'safe' then return false, 'duplicate' end
        if p.state ~= 'restrained' then return false, 'wrong_state' end
        if not inReach(ctx, src, p) then return false, 'too_far' end
        local sk = tostring(src)
        if t == 'free_start' then
            -- one cut at a time per participant (one progress bar): a new start replaces the last one
            for _, bySrc in pairs(st.freeing) do bySrc[sk] = nil end
            st.freeing[key] = st.freeing[key] or {}
            st.freeing[key][sk] = now()
        else
            local started = st.freeing[key] and st.freeing[key][sk]
            if not started then return false, 'not_started' end
            if now() - started < (tonumber(ctx.obj.freeTime) or 0) * FREE_SHARE then return false, 'too_fast' end
            st.freeing[key] = nil
            setPed(ctx, st, p, 'freed')
        end
    elseif t == 'shot' or t == 'damaged' then
        if not p then return false, 'unknown_entity' end
        -- onEvent cannot tell a CP.Npc dispatch from client evidence (server:objective delivers the
        -- same shape), and a client must never be able to cost the team hostage_hit or the
        -- no_hostage_hurt bonus. CP.Npc.onDamaged, which is server-only, reports every hit on a
        -- hostage (both events are always sent together with it), so while it is listened to these
        -- events are acknowledged and change nothing. Without it they are the only damage channel.
        if listening then
            flush(ctx, st)
            return true
        end
        local attacker = ev.src or ev.attacker
        if t == 'shot' and attacker == nil then attacker = src end
        hit(ctx, st, key, attacker)
    else
        return false, 'unknown_event'
    end
    tryComplete(ctx, st)
    flush(ctx, st)
    return ok, why
end

local function onEntityDead(ctx, netId, killerSrc)
    local st = stateOf(ctx)
    died(ctx, st, tostring(netId), killerSrc)
    flush(ctx, st)
end

local function presence(ctx, src, coords)
    local st = stateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local best = math.huge
    for _, p in pairs(st.peds) do
        if p.state ~= 'dead' then
            local c = pedCoords(p)
            if c then
                local d = U.dist(coords, c)
                if d < best then best = d end
            end
        end
    end
    if best == math.huge then
        local s = safePoint(ctx) or (ctx.location and ctx.location.start and ctx.location.start.coords)
        best = s and U.dist(coords, s) or 0
    end
    return best
end

local function checklist(ctx)
    local st = stateOf(ctx)
    local living, freed, safe = tally(st)
    local total = math.max(living, target(ctx) - (st.spawned - living))
    return {
        { label = CP.L('block.protect_rescue.check_freed'), done = total > 0 and freed >= total, value = freed, max = total },
        { label = CP.L('block.protect_rescue.check_safe'), done = total > 0 and safe >= total, value = safe, max = total },
    }
end

local function restart(ctx)
    local st = stateOf(ctx)
    for _, p in pairs(st.peds) do ctx.delete(p.netId) end
    local keep, current = st.rng, st.current
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    st = stateOf(ctx)
    st.current = current
    if current then st.startedAt = now() end
    spawnMissing(ctx, st)
    if current then releaseIdle(ctx, st) end
    st.dirty = true
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
    st.current = false
end

CP.Blocks.register(BLOCK, {
    defaults = defaults,
    validate = validate,
    armedCount = function() return 0 end,
    requiredPoints = requiredPoints,
    prepare = prepare,
    start = start,
    tick = tick,
    onEvent = onEvent,
    onEntityDead = onEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = stateOf(ctx)
        for _, bySrc in pairs(st.freeing) do bySrc[tostring(src)] = nil end
    end,
    rescale = rescale,
    onTimeout = function() return nil end,
    presence = presence,
    checklist = checklist,
    restart = restart,
    stop = stop,
})
