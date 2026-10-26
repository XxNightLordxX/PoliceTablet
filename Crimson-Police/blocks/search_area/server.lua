-- Objective block "search_area" (server half)

local BLOCK = 'search_area'
local U = CP.U

local CLUE_RANGE = 2.5              -- ox_target distance of a clue
local REACH_SLACK = 2.0             -- metres of position lag allowed around interaction ranges
local TIMED_SHARE = 0.8             -- a timed interaction must last at least this share of its duration
local STUN_RANGE = 30.0             -- a stun needs a participant this close to the fugitive...
local STUN_REPORT = 40.0            -- ...and the reporter this close (the client only watches within 40 m)
local CUFF_RANGE = 3.0              -- CP.Npc.enableCuff default maxDistance
local CENTER_SHARE = 0.7            -- the new centre lies within this share of the new radius of a fugitive
local CENTER_TRIES = 12
local REUSE_OFFSET = 1.5
local RESEND_MS = 15000
local DEFAULT_PROPS = { 'prop_cs_heist_bag_02', 'prop_npc_phone_02', 'witness' } -- also the only ones custom missions may use
local CUSTOM_TIMED_MS = { 1000, 30000 } -- custom missions: clue check and cuff progress times (ms)
local DEFAULT_CLUE_MS = 4000
local DEFAULT_CUFF_MS = 5000
local DEFAULT_ESCAPE = { distance = 300, seconds = 30 }
local MIN_SPOTS = 6                 -- clue and hiding spots per location (strict: custom missions)
local MISSING_TICKS = 2             -- ticks an entity must be missing before it counts as gone (as the engine)

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

local function ToVec3(p)
    local x, y, z = U.xyz(p)
    return vector3(x + 0.0, y + 0.0, z + 0.0)
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

local function CenterOf(location, ref)
    local p = PointList(location, ref)[1]
    if p then return p end
    local s = location and location.start
    return s and s.coords or nil
end

local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if U.dist2d(p, z.coords) <= (z.radius or 0) then return true end
    end
    return false
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

local function NpcSet(ctx, netId, state, extra)
    if CP.Npc and CP.Npc.setState then CP.Npc.setState(ctx.run, netId, state, extra) end
end

local function Neutralised(f) return f.state == 'dead' or f.state == 'cuffed' end

-- ============================================================================
--                           DEFAULTS AND VALIDATION
-- ============================================================================

local function NormaliseGivesUp(g)
    local fa = Config.Blocks.flee_arrest
    if g == false then return { stun = false, close = false } end
    if type(g) ~= 'table' then g = {} end
    if type(g[1]) == 'string' then
        local list = g
        g = { stun = U.contains(list, 'stun'), close = U.contains(list, 'close') and {} or false }
    end
    if g.stun == nil then g.stun = true end
    if g.close == nil or g.close == true then g.close = {} end
    if type(g.close) == 'table' then
        if g.close.distance == nil then g.close.distance = fa.closeDistance end
        if g.close.seconds == nil then g.close.seconds = fa.closeSeconds end
    end
    return g
end

local function Defaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 60 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.center == nil then obj.center = 'center' end
    if obj.startRadius == nil then obj.startRadius = c.startRadius[3] end
    if obj.shrinkTo == nil then obj.shrinkTo = U.copy(c.shrinkTo) end
    if obj.clues == nil then obj.clues = 'clues' end
    if obj.clueCount == nil then obj.clueCount = c.clues[3] end
    if obj.clueProps == nil then obj.clueProps = U.copy(DEFAULT_PROPS) end
    if obj.witnessModel == nil then obj.witnessModel = Config.Blocks.protect_rescue.peds[1] end
    if type(obj.clueProgress) ~= 'table' then obj.clueProgress = {} end
    if obj.clueProgress.label == nil then obj.clueProgress.label = CP.L('block.search_area.clue_progress') end
    if obj.clueProgress.duration == nil then obj.clueProgress.duration = DEFAULT_CLUE_MS end
    if obj.hiding == nil then obj.hiding = 'hiding' end
    if obj.fugitives == nil then obj.fugitives = c.fugitives[3] end
    if obj.peds == nil then obj.peds = U.copy(Config.Blocks.hostile_waves.peds) end
    if obj.runDistance == nil then obj.runDistance = c.runDistance[3] + 0.0 end
    obj.givesUp = NormaliseGivesUp(obj.givesUp)
    if type(obj.escape) ~= 'table' then obj.escape = U.copy(DEFAULT_ESCAPE) end
    if obj.escape.distance == nil then obj.escape.distance = DEFAULT_ESCAPE.distance end
    if obj.escape.seconds == nil then obj.escape.seconds = DEFAULT_ESCAPE.seconds end
    if type(obj.cuff) ~= 'table' then obj.cuff = {} end
    if obj.cuff.label == nil then obj.cuff.label = CP.L('block.search_area.cuff') end
    if obj.cuff.duration == nil then obj.cuff.duration = DEFAULT_CUFF_MS end
    return obj
end

local function RequiredPoints(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    for _, k in ipairs({ o.center, o.clues, o.hiding }) do
        if type(k) == 'string' and not U.contains(out, k) then out[#out + 1] = k end
    end
    return out
end

-- What appears at each location key this objective uses, for the spawn point check (Admin UI -> Testing,
-- modules/testing; ARCHITECTURE 7.1 pointKinds): the fugitives hide at people's points, the clues are
-- objects, the search circle's centre is a marker.
local function PointKinds(obj)
    local o = Defaults(U.deepcopy(obj))
    local out = {}
    if type(o.center) == 'string' then out[#out + 1] = { key = o.center, kind = 'marker' } end
    if type(o.clues) == 'string' then out[#out + 1] = { key = o.clues, kind = 'prop' } end
    if type(o.hiding) == 'string' then out[#out + 1] = { key = o.hiding, kind = 'ped' } end
    return out
end

local function CheckLocation(o, loc, li, strict)
    local center = CenterOf(loc, o.center)
    if not center then
        return Bad('block.search_area.invalid.points_missing', { key = tostring(o.center), location = li })
    end
    local clues = PointList(loc, o.clues)
    local hiding = PointList(loc, o.hiding)
    local needClues = strict and math.max(MIN_SPOTS, o.clueCount) or o.clueCount
    local needHiding = strict and MIN_SPOTS or 1
    if #clues < needClues then
        return Bad('block.search_area.invalid.points_count',
            { key = tostring(o.clues), location = li, min = needClues, have = #clues })
    end
    if #hiding < needHiding then
        return Bad('block.search_area.invalid.points_count',
            { key = tostring(o.hiding), location = li, min = needHiding, have = #hiding })
    end
    for _, list in ipairs({ clues, hiding }) do
        for _, p in ipairs(list) do
            if U.dist2d(p, center) > o.startRadius then
                return Bad('block.search_area.invalid.outside', { location = li, radius = o.startRadius })
            end
            if strict and InNoBuild(p) then return Bad('block.search_area.invalid.points_zone', { location = li }) end
        end
    end
    if strict then
        local start = loc.start and loc.start.coords
        for _, p in ipairs(hiding) do
            if start and U.dist(p, start) < Config.Builder.minSpawnFromStart then
                return Bad('block.search_area.invalid.points_start',
                    { location = li, min = Config.Builder.minSpawnFromStart })
            end
        end
    end
    return true
end

local function Validate(obj, mission, location)
    if type(obj) ~= 'table' then return Bad('block.search_area.invalid.objective') end
    local c = Cfg()
    local o = Defaults(U.deepcopy(obj))
    local strict = not (type(mission) == 'table' and mission.source == 'builtin')
    local function range(field, v, r)
        if InRange(v, r) then return true end
        return Bad('block.search_area.invalid.range', { field = field, min = r[1], max = r[2] })
    end
    local ok, why
    if not IsNum(o.minSeconds) or o.minSeconds < 0 then return Bad('block.search_area.invalid.min_seconds') end
    ok, why = range('presenceRange', o.presenceRange, c.presenceRange)
    if not ok then return false, why end
    ok, why = range('startRadius', o.startRadius, c.startRadius)
    if not ok then return false, why end
    if not IsInt(o.clueCount) then
        return Bad('block.search_area.invalid.range', { field = 'clueCount', min = c.clues[1], max = c.clues[2] })
    end
    ok, why = range('clueCount', o.clueCount, c.clues)
    if not ok then return false, why end
    if not IsInt(o.fugitives) then
        return Bad('block.search_area.invalid.range',
            { field = 'fugitives', min = c.fugitives[1], max = c.fugitives[2] })
    end
    ok, why = range('fugitives', o.fugitives, c.fugitives)
    if not ok then return false, why end
    ok, why = range('runDistance', o.runDistance, c.runDistance)
    if not ok then return false, why end
    if type(o.shrinkTo) ~= 'table' or #o.shrinkTo == 0 then return Bad('block.search_area.invalid.shrink') end
    local prev = o.startRadius
    for _, r in ipairs(o.shrinkTo) do
        if not IsNum(r) or r <= 0 or r >= prev then return Bad('block.search_area.invalid.shrink') end
        prev = r
    end
    if type(o.clueProps) ~= 'table' or #o.clueProps == 0 then return Bad('block.search_area.invalid.props') end
    for _, m in ipairs(o.clueProps) do
        if type(m) ~= 'string' or m == '' then return Bad('block.search_area.invalid.props') end
        -- custom missions: only the block's own clue props (and the witness)
        if strict and not U.contains(DEFAULT_PROPS, m) then
            return Bad('block.search_area.invalid.props_allowed', { props = table.concat(DEFAULT_PROPS, ', ') })
        end
    end
    if
        type(o.witnessModel) ~= 'string'
        or (
            strict
            and U.contains(o.clueProps, 'witness')
            and not U.contains(Config.Builder.allowed.peds, o.witnessModel)
        )
    then
        return Bad('block.search_area.invalid.models')
    end
    if type(o.peds) ~= 'table' or #o.peds == 0 then return Bad('block.search_area.invalid.models') end
    for _, m in ipairs(o.peds) do
        if type(m) ~= 'string' or (strict and not U.contains(Config.Builder.allowed.peds, m)) then
            return Bad('block.search_area.invalid.models')
        end
    end
    if type(o.clueProgress.label) ~= 'string' or not IsNum(o.clueProgress.duration) or o.clueProgress.duration <= 0 then
        return Bad('block.search_area.invalid.progress')
    end
    if strict then
        ok, why = range('clueProgress.duration', o.clueProgress.duration, CUSTOM_TIMED_MS)
        if not ok then return false, why end
    end
    local g = o.givesUp
    if
        type(g.stun) ~= 'boolean'
        or (
            g.close ~= false
            and (
                type(g.close) ~= 'table'
                or not IsNum(g.close.distance)
                or g.close.distance <= 0
                or not IsNum(g.close.seconds)
                or g.close.seconds <= 0
            )
        )
    then
        return Bad('block.search_area.invalid.gives_up')
    end
    -- custom missions: "a participant stays within 3 m for 3 s" (Config.Blocks.flee_arrest closeDistance /
    -- closeSeconds) is fixed, only on or off
    local fa = Config.Blocks.flee_arrest
    if strict and g.close ~= false
        and (math.abs(g.close.distance - fa.closeDistance) > 1e-6 or math.abs(g.close.seconds - fa.closeSeconds) > 1e-6) then
        return Bad('block.search_area.invalid.gives_up_close',
            { distance = fa.closeDistance, seconds = fa.closeSeconds })
    end
    if not IsNum(o.escape.distance) or o.escape.distance <= o.runDistance or not IsNum(o.escape.seconds)
        or o.escape.seconds <= 0 then
        return Bad('block.search_area.invalid.escape')
    end
    if type(o.cuff.label) ~= 'string' or not IsNum(o.cuff.duration) or o.cuff.duration <= 0 then
        return Bad('block.search_area.invalid.cuff')
    end
    if strict then
        ok, why = range('cuff.duration', o.cuff.duration, CUSTOM_TIMED_MS)
        if not ok then return false, why end
        local md = o.cuff.maxDistance
        if md ~= nil and not (IsNum(md) and md > 0 and md <= CUFF_RANGE + 1e-9) then
            return Bad('block.search_area.invalid.range', { field = 'cuff.maxDistance', min = 0, max = CUFF_RANGE })
        end
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
        st.clues, st.fugitives, st.slots = {}, {}, {}
        st.count, st.arrests, st.checked = 0, 0, 0
        local c = CenterOf(ctx.location, ctx.obj.center)
        st.circle = { center = c and ToVec3(c) or nil, radius = tonumber(ctx.obj.startRadius) or 600, n = 0 }
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

local function FugTarget(ctx) return Int(ctx.obj.fugitives) end

-- ============================================================================
--                                   SPAWNING
-- ============================================================================

local function PlanClues(ctx, st)
    if st.cluesPlanned then return end
    st.cluesPlanned = true
    local spots = PointList(ctx.location, ctx.obj.clues)
    local props = ctx.obj.clueProps
    local picked = RngOf(ctx):sample(Indices(#spots), Int(ctx.obj.clueCount))
    for i, si in ipairs(picked) do
        local model = props[((i - 1) % #props) + 1]
        st.clues[i] = {
            i = i,
            coords = spots[si],
            name = ('%s[%d]'):format(tostring(ctx.obj.clues), si),
            kind = model == 'witness' and 'witness' or 'prop',
            model = model == 'witness' and ctx.obj.witnessModel or model,
            status = 'pending',
            starts = {},
        }
    end
end

local function SpawnClue(ctx, st, cl)
    if cl.netId or cl.status ~= 'pending' then return true end
    if not ctx.canSpawn(1, false) then return false end
    local ent, netId
    if cl.kind == 'witness' then
        ent, netId = ctx.spawnPed({
            model = cl.model,
            coords = ToVec4(cl.coords),
            role = 'witness',
            armed = false,
            cfg = { group = 'neutral', witness = true, block = BLOCK },
            tag = 'clue' .. cl.i,
        })
        if netId then NpcSet(ctx, netId, 'idle') end
    else
        ent, netId = ctx.spawnObject({
            model = cl.model,
            coords = ToVec4(cl.coords),
            role = 'clue',
            tag = 'clue' .. cl.i,
            frozen = true,
        })
    end
    if not netId then return false end
    cl.netId, cl.entity = netId, ent
    st.dirty = true
    return true
end

-- Fugitive i's hiding spot: point order[k] of the hiding list (k = (i - 1) % #spots + 1), a ring REUSE_OFFSET metres
-- further out per lap when there are more fugitives than spots; its index in the list and its console name.
local function Slot(ctx, st, spots, i)
    local k = ((i - 1) % #spots) + 1
    local lap = (i - 1) // #spots
    local idx = st.order[k]
    local spot = spots[idx]
    local name = ('%s[%d]'):format(tostring(ctx.obj.hiding), idx)
    if lap == 0 then return ToVec4(spot), idx, name end
    local a = lap * 2.39996 + k
    return ToVec4(spot, math.cos(a) * REUSE_OFFSET * lap, math.sin(a) * REUSE_OFFSET * lap),
        idx,
        ('%s +%.1f m'):format(name, REUSE_OFFSET * lap)
end

-- Fugitive i on place (spot idx of the hiding list); alt = the other points the placer may move him to (CP.Spawn).
local function SpawnFugitive(ctx, st, i, place, idx, alt)
    local ent, netId = ctx.spawnPed({
        model = RngOf(ctx):pick(ctx.obj.peds) or Config.Blocks.hostile_waves.peds[1],
        coords = place,
        role = 'fugitive',
        armed = false,
        cfg = { group = 'neutral', hidden = true, block = BLOCK },
        tag = 'fugitive' .. i,
        alt = alt,
    })
    if not netId then return false end
    st.fugitives[tostring(netId)] = {
        netId = netId,
        entity = ent,
        spot = place,
        spotIndex = idx,
        state = 'idle',
        far = 0,
        close = 0,
        index = i,
    }
    st.slots[i] = true
    st.count = st.count + 1
    NpcSet(ctx, netId, 'idle')
    st.dirty = true
    return true
end

-- ============================================================================
--                          WHEN AND WHERE THEY APPEAR
-- ============================================================================
-- The spawn director, Config.Spawning (PLAN S16, owner request of 2026-10-19: "make it be progressive", "make sure
-- they dont spawn around the player"). Before, every fugitive and clue appeared when the search started, 276-560 m from
-- the officers: beyond the 424 m a player's game simulates, and wherever an officer happened to stand later. With the
-- director on nothing appears when the search starts. Each fugitive has his hiding spot from the start (Slot: the
-- circle shrinks towards it) and appears there once an officer is within activateRange of it (ctx.whenNear) and every
-- officer is minDistance or more from it (ctx.choosePoints; never closer: no hardMin for him). An officer standing
-- closer keeps him waiting; after waveDelayMax of that he hides on another free hiding spot inside the current circle
-- that an officer is near and that is far enough (one console line). Each clue appears once an officer is within
-- activateRange of it while every officer is minDistance or more from it, or, closer, where no officer's game can see
-- it (opts.unseen; hardMin after waveDelayMax). A clue or a fugitive that appeared stays. Config.Spawning.enabled =
-- false: everything when the search starts, as before.

local function SpawnCfg() return type(Config.Spawning) == 'table' and Config.Spawning or {} end

local function Directed() return SpawnCfg().enabled ~= false end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v then return default end
    return v
end

-- The other free hiding spots fugitive i may hide on instead of his own: no fugitive's own spot, none a fugitive
-- appeared on, inside the current circle and with an officer near it (ctx.whenNear), in list order.
local function OtherSpots(ctx, st, spots, i)
    local taken = {}
    for j = 1, math.max(FugTarget(ctx), i) do
        local _, idx = Slot(ctx, st, spots, j)
        taken[idx] = true
    end
    for _, f in pairs(st.fugitives) do
        if f.spotIndex then taken[f.spotIndex] = true end
    end
    local c = st.circle
    local out = {}
    for idx, spot in ipairs(spots) do
        if not taken[idx] and (not c.center or U.dist2d(spot, c.center) <= c.radius) and ctx.whenNear(spot) == true then
            out[#out + 1] = {
                coords = ToVec4(spot),
                label = ('%s[%d]'):format(tostring(ctx.obj.hiding), idx),
                index = idx,
            }
        end
    end
    return out
end

-- true once the search is over (completed, failed or stopped): nothing more may appear for it.
local function Over(st) return st.halted or st.failed or st.completed end

-- Fugitive i, if he may appear now (see above); false only when there was no room (canSpawn) or the spawn failed.
-- st.fugWait[i] is his clock (GetGameTimer), counted while an officer is near his spot and too close to it.
local function SpawnFugitiveNear(ctx, st, spots, i)
    local own, idx, name = Slot(ctx, st, spots, i)
    st.fugWait = st.fugWait or {}
    local near, best = ctx.whenNear(own)
    if near ~= true then
        st.fugWait[i] = nil
        return true
    end
    local now = Now()
    local since = st.fugWait[i] or now
    local waited = (now - since) / 1000
    local cands = { { coords = own, label = name, index = idx, own = true } }
    for _, c in ipairs(OtherSpots(ctx, st, spots, i)) do cands[#cands + 1] = c end
    -- the officers' line is measured to his own spot, so it is never behind one of them
    local chosen, _, spare = ctx.choosePoints(cands, 1, { name = 'the fugitive', centre = own, ordered = true })
    -- the search may have ended while the director waited (Over)
    if Over(st) then return true end
    local pick = type(chosen) == 'table' and chosen[1] or nil
    if pick and not pick.own and waited < math.max(0, Num(SpawnCfg().waveDelayMax, 20)) then pick = nil end
    if not pick then
        st.fugWait[i] = since
        return true
    end
    if not ctx.canSpawn(1, false) then return false end
    local alt = {}
    for _, c in ipairs(spare or {}) do
        if c.index ~= pick.index then alt[#alt + 1] = { coords = c.coords, label = c.label } end
    end
    if not SpawnFugitive(ctx, st, i, pick.coords, pick.index, alt) then return false end
    st.fugWait[i] = nil
    if not pick.own and SpawnCfg().log ~= false then
        CP.log(BLOCK, 'run %s: fugitive %d hides on %s instead of %s: an officer stood %.0f m from it for %.0f s',
            tostring(ctx.run and ctx.run.id), i, pick.label, name, tonumber(best) or -1, waited)
    end
    return true
end

-- Clue cl, if it may appear now (see above). cl.waitMs is its clock (GetGameTimer), counted while an officer is near.
local function ClueReady(ctx, cl)
    if ctx.whenNear(cl.coords) ~= true then
        cl.waitMs = nil
        return false
    end
    local now = Now()
    cl.waitMs = cl.waitMs or now
    local chosen = ctx.choosePoints({ { coords = cl.coords, label = cl.name } }, 1, {
        name = 'clue ' .. cl.i,
        wave = 'clue ' .. cl.i,
        since = os.time() - math.floor((now - cl.waitMs) / 1000),
        unseen = true,
    })
    if type(chosen) == 'table' and chosen[1] then
        cl.waitMs = nil
        return true
    end
    return false
end

-- Everything at once, when the search starts (the director off), as before.
local function SpawnAll(ctx, st, spots)
    for i = 1, FugTarget(ctx) do
        if not st.slots[i] then
            if not ctx.canSpawn(1, false) then return end
            local place, idx = Slot(ctx, st, spots, i)
            if not SpawnFugitive(ctx, st, i, place, idx) then return end
        end
    end
    for _, cl in ipairs(st.clues) do
        if not SpawnClue(ctx, st, cl) then return end
    end
end

-- Each fugitive and clue once an officer is near it (the director on).
local function SpawnNear(ctx, st, spots)
    for i = 1, FugTarget(ctx) do
        if not st.slots[i] then
            if not SpawnFugitiveNear(ctx, st, spots, i) then return end
            if Over(st) then return end
        end
    end
    for _, cl in ipairs(st.clues) do
        if cl.status == 'pending' and not cl.netId and ClueReady(ctx, cl) then
            -- ClueReady may have waited up to losTimeoutMs for an officer's game (opts.unseen): the last fugitive can
            -- be cuffed or the objective stopped meanwhile, and then no clue is made for a search that is over
            if Over(st) then return end
            if not SpawnClue(ctx, st, cl) then return end
            if Over(st) then return end
        end
    end
end

-- Spawns the fugitives and clues still missing. The spawning flag (re-entry while a spawn or the director yields) is
-- always cleared, even when a spawn throws.
local function SpawnMissing(ctx, st)
    if st.spawning or st.halted or st.failed then return end
    local spots = PointList(ctx.location, ctx.obj.hiding)
    if #spots == 0 then
        CP.warn(BLOCK, 'no hiding spots at %s for run %s', tostring(ctx.obj.hiding), tostring(ctx.run and ctx.run.id))
        Fail(ctx, st, 'block.search_area.fail_setup')
        return
    end
    PlanClues(ctx, st)
    if not st.order or #st.order ~= #spots then st.order = RngOf(ctx):shuffle(Indices(#spots)) end
    st.spawning = true
    local ok, err = pcall(Directed() and SpawnNear or SpawnAll, ctx, st, spots)
    st.spawning = false
    if not ok then
        CP.err(BLOCK, 'spawning for run %s failed: %s', tostring(ctx.run and ctx.run.id), tostring(err))
    end
end

-- ============================================================================
--                                    CIRCLE
-- ============================================================================

-- Where the circle shrinks to: a hidden fugitive (one still waiting for an officer to come near his hiding spot hides
-- there), else a running one; nil when none is left.
local function FugitiveAnchor(ctx, st)
    local hidden, running = {}, {}
    for _, f in pairs(st.fugitives) do
        if not Neutralised(f) and f.state ~= 'surrendered' then
            local e = { index = f.index, f = f }
            if f.state == 'idle' then hidden[#hidden + 1] = e else running[#running + 1] = e end
        end
    end
    local spots = PointList(ctx.location, ctx.obj.hiding)
    if #spots > 0 and st.order and #st.order == #spots then
        for i = 1, FugTarget(ctx) do
            if not st.slots[i] then hidden[#hidden + 1] = { index = i, spot = (Slot(ctx, st, spots, i)) } end
        end
    end
    local list = #hidden > 0 and hidden or running
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.index < b.index end)
    local e = RngOf(ctx):pick(list)
    if e.f then return EntCoords(e.f.entity) or e.f.spot end
    return e.spot
end

local function Shrink(ctx, st)
    local c = st.circle
    local list = ctx.obj.shrinkTo or {}
    c.n = c.n + 1
    local r = tonumber(list[math.min(c.n, #list)])
    if not r or c.n > #list or not c.center then
        st.dirty = true
        return
    end
    local anchor = FugitiveAnchor(ctx, st)
    local old, oldR = c.center, c.radius
    local center = old
    if anchor then
        local ax, ay, az = U.xyz(anchor)
        local rng = RngOf(ctx)
        local pick
        for _ = 1, CENTER_TRIES do
            local ang = rng:next() * 2 * math.pi
            local mag = rng:next() * r * CENTER_SHARE
            local cand = vector3(ax + math.cos(ang) * mag, ay + math.sin(ang) * mag, az + 0.0)
            pick = cand
            if U.dist2d(cand, old) + r <= oldR then break end
        end
        center = pick
    end
    c.center, c.radius = center, r
    st.dirty = true
    Message(ctx, 'block.search_area.msg_shrink', { radius = r }, 'info')
end

local function ClueDone(ctx, st, cl, status)
    if cl.status ~= 'pending' then return end
    cl.status = status
    st.dirty = true
    if status == 'done' then st.checked = st.checked + 1 end
    Shrink(ctx, st)
    if not st.cluesFirst and st.arrests == 0 and st.checked >= #st.clues and #st.clues > 0 then
        st.cluesFirst = true
        ctx.award('clues_first', { count = 1 })
    end
end

-- ============================================================================
--                                  FUGITIVES
-- ============================================================================

local function SetFug(ctx, st, f, state)
    if f.state == state then return end
    f.state = state
    NpcSet(ctx, f.netId, state)
    st.dirty = true
end

-- task: the one-off task he gives up with (CP.Npc.wornOut's 'handsUp'); nil = he kneels.
local function Surrender(ctx, st, f, task)
    f.state = 'surrendered'
    f.close, f.far = 0, 0
    NpcSet(ctx, f.netId, 'surrendered', task and { task = task } or nil)
    local cuff = ctx.obj.cuff
    if CP.Npc and CP.Npc.enableCuff then
        CP.Npc.enableCuff(ctx.run, f.netId, {
            label = cuff.label or CP.L('block.search_area.cuff'),
            duration = tonumber(cuff.duration) or DEFAULT_CUFF_MS,
            maxDistance = cuff.maxDistance or CUFF_RANGE,
        })
    end
    st.dirty = true
end

local function MarkCuffed(ctx, st, f)
    if f.state == 'cuffed' then return end
    f.state = 'cuffed'
    f.far, f.close = 0, 0
    st.arrests = st.arrests + 1
    st.dirty = true
end

local function BagCuffed(f)
    return CP.Npc and CP.Npc.getState and CP.Npc.getState(f.netId) == 'cuffed'
end

local function Watch(ctx, st, dt, list)
    local obj = ctx.obj
    local esc, gu = obj.escape, obj.givesUp
    local worst = 0
    if not st.entered and st.circle.center then
        for _, p in ipairs(list) do
            if U.dist2d(p.coords, st.circle.center) <= (tonumber(obj.startRadius) or 600) then
                st.entered = true
                st.dirty = true
                break
            end
        end
    end
    for _, f in pairs(st.fugitives) do
        if not Neutralised(f) then
            if f.state == 'surrendered' and BagCuffed(f) then
                MarkCuffed(ctx, st, f)
            elseif not Exists(f.entity) then
                f.missing = (f.missing or 0) + 1
                if f.missing >= MISSING_TICKS then
                    f.state = 'dead'
                    st.dirty = true
                end
            else
                f.missing = 0
                local near = NearestOf(list, GetEntityCoords(f.entity))
                if f.state == 'idle' and near <= obj.runDistance then
                    f.ran = true
                    SetFug(ctx, st, f, 'fleeing')
                    Message(ctx, 'block.search_area.msg_running', nil, 'warning')
                end
                if f.state == 'fleeing' then
                    if #list > 0 and near > esc.distance then
                        f.far = (f.far or 0) + dt
                        if f.far >= esc.seconds then
                            Fail(ctx, st, 'block.search_area.fail_escaped')
                            return
                        end
                        if f.far > worst then worst = f.far end
                    else
                        f.far = 0
                    end
                    if type(gu.close) == 'table' then
                        if near <= gu.close.distance then
                            f.close = (f.close or 0) + dt
                            if f.close >= gu.close.seconds then Surrender(ctx, st, f) end
                        else
                            f.close = 0
                        end
                    end
                    -- worn out (Config.Flee): he gives up once a participant is within giveUpRange
                    if f.state == 'fleeing' and CP.Npc and CP.Npc.wornOut then
                        local tired, task = CP.Npc.wornOut(f.netId, near)
                        if tired then Surrender(ctx, st, f, task) end
                    end
                end
            end
        end
    end
    for _, cl in ipairs(st.clues) do
        if cl.status == 'pending' and cl.netId then
            if Exists(cl.entity) then
                cl.missing = 0
            else
                cl.missing = (cl.missing or 0) + 1
                if cl.missing >= MISSING_TICKS then ClueDone(ctx, st, cl, 'lost') end
            end
        end
    end
    local escaping = worst > 0 and math.max(0, math.ceil(esc.seconds - worst)) or nil
    if escaping ~= st.escaping then
        st.escaping = escaping
        st.dirty = true
    end
end

local function Totals(ctx, st)
    local done, total = 0, 0
    for _, f in pairs(st.fugitives) do
        total = total + 1
        if Neutralised(f) then done = done + 1 end
    end
    return done, math.max(total, FugTarget(ctx))
end

local function TryComplete(ctx, st)
    if st.completed or st.failed or st.halted then return end
    if st.count < FugTarget(ctx) then return end
    for _, f in pairs(st.fugitives) do
        if not Neutralised(f) then return end
    end
    if ctx.complete({ arrests = st.arrests, clues = st.checked }) ~= false then st.completed = true end
end

-- ============================================================================
--                                CLIENT UPDATES
-- ============================================================================

local function Snapshot(ctx, st)
    local clues, fugitives = {}, {}
    for _, cl in ipairs(st.clues) do
        local x, y, z = U.xyz(cl.coords)
        clues[#clues + 1] = {
            i = cl.i,
            x = x,
            y = y,
            z = z,
            kind = cl.kind,
            model = cl.model,
            netId = cl.netId,
            status = cl.status,
        }
    end
    for _, f in pairs(st.fugitives) do
        fugitives[#fugitives + 1] = { netId = f.netId, state = f.state }
    end
    table.sort(fugitives, function(a, b) return a.netId < b.netId end)
    local c = st.circle
    local cx, cy, cz = U.xyz(c.center)
    local done, total = Totals(ctx, st)
    return {
        kind = 'state',
        circle = c.center and { x = cx, y = cy, z = cz, r = c.radius, n = c.n } or nil,
        clues = clues,
        fugitives = fugitives,
        checked = st.checked,
        clueTotal = #st.clues,
        arrests = st.arrests,
        neutralised = done,
        total = total,
        entered = st.entered == true,
        escaping = st.escaping,
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

local function ClueEvent(ctx, st, src, ev)
    local cl = st.clues[tonumber(ev.clue) or 0]
    if not cl then return false, 'unknown_clue' end
    if cl.status ~= 'pending' then return false, 'duplicate' end
    if not cl.netId then return false, 'not_spawned' end
    local sc = ctx.coords(src)
    if not sc or U.dist(sc, cl.coords) > CLUE_RANGE + REACH_SLACK then return false, 'too_far' end
    local sk = tostring(src)
    if ev.type == 'clue_start' then
        cl.starts[sk] = Now()
        return true
    end
    local started = cl.starts[sk]
    if not started then return false, 'not_started' end
    if Now() - started < (tonumber(ctx.obj.clueProgress.duration) or 0) * TIMED_SHARE then return false, 'too_fast' end
    ClueDone(ctx, st, cl, 'done')
    return true
end

local function OnEvent(ctx, src, ev)
    local st = StateOf(ctx)
    if type(ev) ~= 'table' then return false, 'bad_event' end
    if st.failed or st.halted then return false, 'ended' end
    local t = ev.type
    local ok, why
    if t == 'clue_start' or t == 'clue' then
        ok, why = ClueEvent(ctx, st, src, ev)
    elseif t == 'stunned' or t == 'cuffed' or t == 'shot' then
        local f = st.fugitives[tostring(tonumber(ev.netId) or '')]
        if not f then return false, 'unknown_entity' end
        if t == 'shot' then
            ok = true
        elseif t == 'stunned' then
            if f.state == 'surrendered' or f.state == 'cuffed' then return false, 'duplicate' end
            if f.state ~= 'fleeing' and f.state ~= 'idle' then return false, 'wrong_state' end
            if not ctx.obj.givesUp.stun then return false, 'disabled' end
            local fc, sc = EntCoords(f.entity), ctx.coords(src)
            if not fc or not sc or U.dist(fc, sc) > STUN_REPORT + REACH_SLACK then return false, 'too_far' end
            if NearestOf(Party(ctx), fc) > STUN_RANGE then return false, 'too_far' end
            -- Config.AntiCheat.stunNeedsProof: a stun the server did not see adds a note or a flag, or is refused
            if CP.Npc and CP.Npc.stunCheck and not CP.Npc.stunCheck(ctx.run, src, f.netId) then
                return false, 'no_stun'
            end
            f.ran = true
            Surrender(ctx, st, f)
            ok = true
        else
            if f.state == 'cuffed' then return false, 'duplicate' end
            if f.state ~= 'surrendered' then return false, 'wrong_state' end
            if not BagCuffed(f) then return false, 'not_cuffed' end
            local pc, sc = EntCoords(f.entity), ctx.coords(src)
            if not pc or not sc
                or U.dist(pc, sc) > (tonumber(ctx.obj.cuff.maxDistance) or CUFF_RANGE) + REACH_SLACK then
                return false, 'too_far'
            end
            MarkCuffed(ctx, st, f)
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

local function Start(ctx)
    local st = StateOf(ctx)
    st.halted = nil
    SpawnMissing(ctx, st)
    st.dirty = true
    Flush(ctx, st)
end

local function Tick(ctx, dt)
    local st = StateOf(ctx)
    if st.halted or st.failed or st.completed then return end
    SpawnMissing(ctx, st)
    if st.failed then return end
    Watch(ctx, st, tonumber(dt) or 1, Party(ctx))
    if st.failed then return end
    TryComplete(ctx, st)
    Flush(ctx, st)
end

local function OnEntityDead(ctx, netId, killerSrc)
    local st = StateOf(ctx)
    local key = tostring(netId)
    local f = st.fugitives[key]
    if f then
        if f.state == 'dead' then return end
        f.state = 'dead'
        st.dirty = true
        if IsParticipant(ctx, killerSrc) then
            Fail(ctx, st, 'run.fail_killed_unarmed')
            return
        end
        TryComplete(ctx, st)
        Flush(ctx, st)
        return
    end
    for _, cl in ipairs(st.clues) do
        if cl.netId == netId and cl.kind == 'witness' then
            if IsParticipant(ctx, killerSrc) then
                Fail(ctx, st, 'run.fail_killed_unarmed')
                return
            end
            -- the search is over (a later objective runs): no circle to shrink, no message over that objective
            if st.completed or st.halted then return end
            ClueDone(ctx, st, cl, 'lost')
            Flush(ctx, st)
            return
        end
    end
end

local function Presence(ctx, src, coords)
    local st = StateOf(ctx)
    coords = coords or ctx.coords(src)
    if not coords then return math.huge end
    local c = st.circle
    if not c.center then return 0 end
    return math.max(0, U.dist2d(coords, c.center) - c.radius)
end

local function Checklist(ctx)
    local st = StateOf(ctx)
    local done, total = Totals(ctx, st)
    local clueTotal = math.max(#st.clues, Int(ctx.obj.clueCount))
    local handled = 0
    for _, cl in ipairs(st.clues) do
        if cl.status ~= 'pending' then handled = handled + 1 end
    end
    return {
        {
            label = CP.L('block.search_area.check_clues'),
            done = clueTotal > 0 and handled >= clueTotal,
            value = st.checked,
            max = clueTotal,
        },
        {
            label = CP.L('block.search_area.check_fugitives'),
            done = total > 0 and done >= total and st.count >= FugTarget(ctx),
            value = done,
            max = total,
        },
    }
end

local function Restart(ctx)
    local st = StateOf(ctx)
    for key in pairs(st.fugitives) do ctx.delete(tonumber(key)) end
    for _, cl in ipairs(st.clues) do
        if cl.netId then ctx.delete(cl.netId) end
    end
    local keep = st.rng
    for k in pairs(st) do st[k] = nil end
    st.rng = keep
    Start(ctx)
end

local function Rescale(ctx)
    local st = StateOf(ctx)
    st.dirty = true
    TryComplete(ctx, st)
    Flush(ctx, st)
end

-- ============================================================================
--                              OBJECTIVE POINTER
-- ============================================================================
-- CP.Runs.marker (docs/ARCHITECTURE.md §5.44; the owner: "ensure all objectives as they come up mark on the map").
-- Until an officer has entered the search: the current circle (it shrinks with every clue) in
-- Config.Markers.kinds.searchArea, key 'center' (the client half hands its centre blip over with it), so each officer's
-- GPS line goes to the middle until he is inside. Then whoever runs or gave up, at the server's position and keyed by
-- net id (a runner out of an officer's game still shows); else every clue still to check, keyed 'c<n>' and numbered
-- like its blip, so each officer's line goes to his nearest; with nobody running and no clue left, the circle again
-- (the fugitives hide inside it). Under Radio Silence the circle stays the pointer (Config.Markers.radioSilence
-- 'area' shows it without a line and hides people and clues; 'full' shows everything as without it).

local function Runners(st)
    local out = {}
    for _, f in pairs(st.fugitives) do
        if (f.state == 'fleeing' or f.state == 'surrendered') and EntCoords(f.entity) then out[#out + 1] = f end
    end
    table.sort(out, function(a, b) return a.netId < b.netId end)
    return out
end

local function Marker(ctx)
    local st = StateOf(ctx)
    local c = st.circle
    if not c.center then return nil end
    local area = {
        kind = 'area',
        key = 'center',
        look = 'searchArea',
        coords = c.center,
        radius = c.radius,
        label = CP.Lt('block.search_area.blip_area', { radius = math.floor(c.radius + 0.5) }),
    }
    local mode = type(Config.Markers) == 'table' and Config.Markers.radioSilence or nil
    if not st.entered or (ctx.radioSilence and mode ~= 'full') then return area end
    local targets = {}
    for _, f in ipairs(Runners(st)) do
        targets[#targets + 1] = {
            key = f.netId,
            netId = f.netId,
            coords = EntCoords(f.entity),
            look = f.state == 'fleeing' and 'fleeing' or 'suspect',
            -- one who gave up: kinds.suspect.surrenderedScale, as the client half draws him near
            variant = f.state == 'surrendered' and 'surrendered' or nil,
            label = CP.Lt('block.search_area.blip_fugitive'),
        }
    end
    if #targets == 0 then
        for _, cl in ipairs(st.clues) do
            if cl.status == 'pending' then
                targets[#targets + 1] = {
                    key = 'c' .. cl.i,
                    coords = cl.coords,
                    look = 'clue',
                    number = cl.i,
                    label = CP.Lt('block.search_area.blip_clue'),
                }
            end
        end
    end
    if #targets == 0 then return area end
    return { kind = 'targets', targets = targets }
end

CP.Blocks.register(BLOCK, {
    defaults = Defaults,
    validate = Validate,
    armedCount = function() return 0 end,
    requiredPoints = RequiredPoints,
    pointKinds = PointKinds,
    prepare = function(ctx) StateOf(ctx) end,
    start = Start,
    tick = Tick,
    onEvent = OnEvent,
    onEntityDead = OnEntityDead,
    onParticipantLeft = function(ctx, src)
        local st = StateOf(ctx)
        for _, cl in ipairs(st.clues) do cl.starts[tostring(src)] = nil end
        st.dirty = true
        Flush(ctx, st)
    end,
    rescale = Rescale,
    onTimeout = function() return nil end,
    presence = Presence,
    checklist = Checklist,
    marker = Marker,
    restart = Restart,
    stop = function(ctx)
        local st = StateOf(ctx)
        st.halted = true
    end,
})
