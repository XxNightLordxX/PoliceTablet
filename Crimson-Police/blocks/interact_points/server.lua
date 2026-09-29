-- Objective block "interact_points" (server half)

local BLOCK = 'interact_points'

local REACH_SLACK = 3.0                                      -- metres beyond the target radius (server coordinates lag)
local DWELL_SLACK = 1.5                                      -- seconds of tolerance on the progress duration
local TARGET_RADIUS = 1.5                                    -- default ox_target sphere radius
local TARGET_ICON = 'fa-solid fa-clipboard-check'
local SEARCH_ICON = 'fa-solid fa-magnifying-glass'
local DEVICE_PROP = 'prop_ld_bomb'                           -- default device model for hidden = { ... }
local DEVICE_PROPS = { DEVICE_PROP, 'prop_c4_final_green' }  -- the only device models custom missions may use
local SHARED_TAG = 'shared:devices'

local function Cfg() return Config.Blocks[BLOCK] end
local function Now() return GetGameTimer() end

local function Idx(v)
    local n = tonumber(v)
    return n and math.tointeger(n) or nil
end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    local x, y, z = v.x or v[1], v.y or v[2], v.z or v[3]
    return type(x) == 'number' and type(y) == 'number' and type(z) == 'number'
end

local function Vec3Of(v)
    local x, y, z = CP.U.xyz(v)
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function Plain(v)
    local x, y, z = CP.U.xyz(v)
    return { x = x, y = y, z = z }
end

local function HeadingOf(v)
    if type(v) == 'vector4' then return v.w end
    if type(v) == 'table' then return tonumber(v.w or v[4]) end
    return nil
end

local function Bad(key, vars)
    return false, CP.L(key, vars)
end

local function InRange(v, r)
    return type(v) == 'number' and type(r) == 'table' and v >= r[1] and v <= r[2]
end

-- Config.Builder.noBuildZones: no marker, target point or route waypoint inside them.
local function InNoBuild(p)
    for _, z in ipairs((Config.Builder and Config.Builder.noBuildZones) or {}) do
        if CP.U.dist2d(p, z.coords) <= (tonumber(z.radius) or 0) then return true end
    end
    return false
end

-- A label from a mission file: a locale key when one exists, otherwise the text as written.
local function Txt(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if CP.Locale.has(s) then return CP.L(s) end
    return s
end

-- ============================================================================
--                                    POINTS
-- ============================================================================

local function NormPoint(v)
    if IsVec(v) then
        return { coords = Vec3Of(v), heading = HeadingOf(v) }
    end
    if type(v) == 'table' and IsVec(v.coords) then
        return {
            coords = Vec3Of(v.coords),
            heading = tonumber(v.heading) or HeadingOf(v.coords),
            label = type(v.label) == 'string' and v.label or nil,
        }
    end
    return nil
end

local function ResolvePoints(obj, location)
    local src = obj.points
    if type(src) == 'string' then src = type(location) == 'table' and location[src] or nil end
    if src == nil then return nil end
    if IsVec(src) or (type(src) == 'table' and src.coords ~= nil) then
        local p = NormPoint(src)
        return p and { p } or nil
    end
    if type(src) ~= 'table' then return nil end
    local out = {}
    for i = 1, #src do
        local p = NormPoint(src[i])
        if not p then return nil end
        out[i] = p
    end
    return out
end

local function AnchorIndex(pool, location)
    local start = type(location) == 'table' and location.start or nil
    if type(start) ~= 'table' or not IsVec(start.coords) then return nil end
    local limit = tonumber(start.radius) or 0.0
    local best, bestD
    for i, p in ipairs(pool) do
        local d = CP.U.dist(p.coords, start.coords)
        if d <= limit and (not bestD or d < bestD) then best, bestD = i, d end
    end
    return best
end

local function PickIndices(n, use, count, anchor, rng)
    local out = {}
    if use ~= 'random' then
        for i = 1, n do out[i] = i end
        return out
    end
    count = math.max(0, math.min(count or n, n))
    local pool = {}
    for i = 1, n do
        if i ~= anchor then pool[#pool + 1] = i end
    end
    local want = count
    if anchor and count > 0 then
        out[1] = anchor
        want = count - 1
    end
    for _, i in ipairs(rng:sample(pool, want)) do out[#out + 1] = i end
    local base = anchor or 1
    table.sort(out, function(a, b) return ((a - base) % n) < ((b - base) % n) end)
    return out
end

-- ============================================================================
--                             OUTCOMES AND LOGGING
-- ============================================================================

local function ChoiceList(obj)
    local lr = obj.logResult
    if type(lr) ~= 'table' or type(lr.choices) ~= 'table' then return nil end
    local out = {}
    for i, c in ipairs(lr.choices) do
        if type(c) == 'string' then
            out[i] = { id = c }
        elseif type(c) == 'table' and type(c.id) == 'string' then
            out[i] = { id = c.id, label = c.label }
        else
            return nil
        end
    end
    return out
end

local function ChoiceLabel(c)
    local key = 'block.interact_points.log.' .. c.id
    if CP.Locale.has(key) then return CP.L(key) end
    return Txt(c.label) or c.id
end

-- The outcomes the server rolls: roll.outcomes, or (logResult without roll) one per choice.
local function OutcomeList(obj)
    if type(obj.roll) == 'table' and type(obj.roll.outcomes) == 'table' and #obj.roll.outcomes > 0 then
        return obj.roll.outcomes
    end
    local choices = ChoiceList(obj)
    if choices then
        local out = {}
        for i, c in ipairs(choices) do out[i] = { id = c.id, chance = 1 / #choices, label = c.label } end
        return out
    end
    return nil
end

local function OutcomeDef(obj, id)
    for _, o in ipairs(OutcomeList(obj) or {}) do
        if o.id == id then return o end
    end
    return nil
end

local function OutcomeLabel(obj, id)
    local key = 'block.interact_points.outcome.' .. tostring(id)
    if CP.Locale.has(key) then return CP.L(key) end
    local o = OutcomeDef(obj, id)
    return (o and Txt(o.label)) or CP.L('block.interact_points.outcome.generic', { outcome = tostring(id) })
end

local function CorrectChoice(obj, outcomeId)
    local lr = obj.logResult
    if type(lr) == 'table' and type(lr.correct) == 'table' and lr.correct[outcomeId] ~= nil then
        return lr.correct[outcomeId]
    end
    return outcomeId
end

local function RollOne(rng, outcomes)
    local total = 0.0
    for _, o in ipairs(outcomes) do total = total + (tonumber(o.chance) or 0) end
    if total <= 0 then return outcomes[1] and outcomes[1].id end
    local r = rng:next() * total
    local acc = 0.0
    for _, o in ipairs(outcomes) do
        acc = acc + (tonumber(o.chance) or 0)
        if r < acc then return o.id end
    end
    return outcomes[#outcomes].id
end

-- ============================================================================
--                                    STATE
-- ============================================================================

local function Ensure(ctx)
    local st = ctx.state
    if st.points then return st end
    local obj = ctx.obj
    local pool = ResolvePoints(obj, ctx.location)
    if not pool or #pool == 0 then
        CP.err('blocks', 'interact_points: objective %s has no usable points (%s)', tostring(ctx.index),
            tostring(obj.points))
        pool = {}
        st.broken = true
    end
    local anchor = (obj.use == 'random') and AnchorIndex(pool, ctx.location) or nil
    st.points = {}
    for n, i in ipairs(PickIndices(#pool, obj.use, Idx(obj.count), anchor, ctx.rng)) do
        local p = pool[i]
        st.points[n] = { coords = p.coords, heading = p.heading, label = p.label, status = 'pending' }
    end
    if type(obj.hidden) == 'table' then
        st.hidden = true
        local count = math.max(0, math.min(Idx(obj.hidden.count) or 1, #st.points))
        if (Idx(obj.hidden.count) or 1) > #st.points then
            CP.warn('blocks', 'interact_points: %d hidden devices but only %d spots; using %d',
                Idx(obj.hidden.count) or 1, #st.points, count)
        end
        local all = {}
        for n = 1, #st.points do all[n] = n end
        for _, n in ipairs(ctx.rng:sample(all, count)) do st.points[n].device = true end
        st.total, st.found = count, 0
    else
        local outcomes = OutcomeList(obj)
        if outcomes then
            for _, p in ipairs(st.points) do p.outcome = RollOne(ctx.rng, outcomes) end
        end
        st.total, st.found = #st.points, 0
    end
    st.logQueue, st.log = {}, nil
    st.near, st.pendingSpawns = {}, {}
    return st
end

local function ActiveCount(st)
    local n = 0
    for _, p in ipairs(st.points) do
        if p.status ~= 'dropped' then n = n + 1 end
    end
    return n
end

local function DoneCount(st)
    local n = 0
    for _, p in ipairs(st.points) do
        if p.status == 'done' then n = n + 1 end
    end
    return n
end

local function RefreshLog(ctx, st)
    local n = st.logQueue[1]
    if not n then
        st.log = nil
        return
    end
    local choices = {}
    for i, c in ipairs(ChoiceList(ctx.obj) or {}) do choices[i] = { id = c.id, label = ChoiceLabel(c) } end
    st.log = { point = n, choices = choices }
end

local function SendState(ctx, st)
    local pts = {}
    for n, p in ipairs(st.points) do
        local e = { coords = Plain(p.coords), heading = p.heading, label = p.label, status = p.status }
        if p.status ~= 'pending' and p.outcome ~= nil then
            e.outcome = p.outcome
            e.outcomeLabel = OutcomeLabel(ctx.obj, p.outcome)
        end
        if p.status == 'followup' then
            local o = OutcomeDef(ctx.obj, p.outcome)
            local f = o and o.followUp or {}
            e.followUp = { label = Txt(f.label), duration = tonumber(f.duration) }
        end
        if p.found then e.found = true end
        pts[n] = e
    end
    ctx.send({
        kind = 'state',
        points = pts,
        hidden = st.hidden == true,
        found = st.found,
        total = st.hidden and st.total or ActiveCount(st),
        done = DoneCount(st),
        log = st.log,
    })
end

local function TryComplete(ctx, st)
    if st.completed then return true end
    local ok = ctx.complete({ found = st.found, done = DoneCount(st) })
    if ok ~= false then st.completed = true end
    return st.completed
end

local function FastBonus(ctx, st)
    local fb = ctx.obj.fastBonus
    if st.fastChecked or type(fb) ~= 'table' or type(fb.id) ~= 'string' then return end
    st.fastChecked = true
    local seconds = tonumber(fb.seconds) or 0
    if (Now() - (st.startMs or Now())) / 1000 <= seconds then
        st.fastAwarded = true
        ctx.award(fb.id)
    end
end

local function RemoveShared(run, netId)
    local list = run.shared and run.shared.devices
    if type(list) ~= 'table' then return end
    for i = #list, 1, -1 do
        if list[i].netId == netId then table.remove(list, i) end
    end
end

local function SpawnDevice(ctx, st, n)
    if not ctx.canSpawn(1, false) then return false end
    local p = st.points[n]
    local hidden = ctx.obj.hidden or {}
    local coords = p.coords
    if p.heading then coords = vector4(p.coords.x, p.coords.y, p.coords.z, p.heading + 0.0) end
    local _, netId = ctx.spawnObject({
        model = hidden.prop or DEVICE_PROP,
        coords = coords,
        role = 'device',
        tag = SHARED_TAG,
        frozen = true,
    })
    if not netId then return false end
    p.netId = netId
    ctx.run.shared = ctx.run.shared or {}
    ctx.run.shared.devices = ctx.run.shared.devices or {}
    ctx.run.shared.devices[#ctx.run.shared.devices + 1] = {
        netId = netId,
        coords = Vec3Of(p.coords),
        point = n,
        model = hidden.prop or DEVICE_PROP,
        heading = p.heading, -- lets skill_check re-create a deleted prop
    }
    return true
end

local function ProcessSpawns(ctx, st)
    local changed = false
    while #st.pendingSpawns > 0 do
        if not SpawnDevice(ctx, st, st.pendingSpawns[1]) then break end
        table.remove(st.pendingSpawns, 1)
        changed = true
    end
    return changed
end

local function WorkDone(st)
    if st.hidden then return st.found >= st.total end
    for _, p in ipairs(st.points) do
        if p.status ~= 'done' and p.status ~= 'dropped' then return false end
    end
    return true
end

local function CheckDone(ctx, st)
    if st.completed or st.failed then return end
    if not WorkDone(st) then return end
    FastBonus(ctx, st)
    if #st.pendingSpawns > 0 then return end
    st.ready = true
    TryComplete(ctx, st)
end

-- After the main (and follow-up) action: wait for the log, or done.
local function Resolve(ctx, st, n)
    local p = st.points[n]
    if ChoiceList(ctx.obj) and p.outcome ~= nil then
        p.status = 'log'
        st.logQueue[#st.logQueue + 1] = n
        RefreshLog(ctx, st)
    else
        p.status = 'done'
    end
end

local function Reach(ctx)
    local target = type(ctx.obj.target) == 'table' and ctx.obj.target or {}
    return (tonumber(target.radius) or TARGET_RADIUS) + REACH_SLACK
end

-- Seconds the server has sampled src at point n while the point was in `status` (pending or followup).
local function HeldFor(st, src, n, status)
    local bySrc = st.near[src]
    local e = bySrc and bySrc[n]
    if not e or e.status ~= status then return 0 end
    return (Now() - e.at) / 1000
end

local function MarkNear(st, src, n, status, t)
    local bySrc = st.near[src] or {}
    st.near[src] = bySrc
    bySrc[n] = { at = t, status = status }
end

-- ============================================================================
--                                   EVIDENCE
-- ============================================================================

local function OnInteract(ctx, st, src, ev)
    local n = Idx(ev.point)
    local p = n and st.points[n]
    if not p then return false, 'bad_point' end
    if p.status ~= 'pending' then return false, 'wrong_state' end
    local c = ctx.coords(src)
    if not c or CP.U.dist(c, p.coords) > Reach(ctx) then return false, 'too_far' end
    local need = (tonumber(ctx.obj.progress and ctx.obj.progress.duration) or 0) / 1000 - DWELL_SLACK
    if need > 0 and HeldFor(st, src, n, 'pending') < need then return false, 'too_quick' end

    p.by, p.checkedAt = src, Now()
    if st.hidden then
        p.status = 'done'
        if p.device then
            p.found = true
            st.found = st.found + 1
            st.pendingSpawns[#st.pendingSpawns + 1] = n
            ProcessSpawns(ctx, st)
        end
    else
        local o = p.outcome ~= nil and OutcomeDef(ctx.obj, p.outcome) or nil
        if o and type(o.followUp) == 'table' then
            p.status = 'followup'
            MarkNear(st, src, n, 'followup', p.checkedAt) -- the checker is at the door now
        else
            Resolve(ctx, st, n)
        end
    end
    SendState(ctx, st)
    CheckDone(ctx, st)
    return true
end

local function OnFollowUp(ctx, st, src, ev)
    local n = Idx(ev.point)
    local p = n and st.points[n]
    if not p then return false, 'bad_point' end
    if p.status ~= 'followup' then return false, 'wrong_state' end
    local c = ctx.coords(src)
    if not c or CP.U.dist(c, p.coords) > Reach(ctx) then return false, 'too_far' end
    local o = OutcomeDef(ctx.obj, p.outcome)
    local f = o and o.followUp or {}
    local need = (tonumber(f.duration) or 0) / 1000 - DWELL_SLACK
    if need > 0 and HeldFor(st, src, n, 'followup') < need then return false, 'too_quick' end
    p.followedBy = src
    Resolve(ctx, st, n)
    SendState(ctx, st)
    CheckDone(ctx, st)
    return true
end

local function OnLog(ctx, st, src, ev)
    local n = Idx(ev.point)
    local p = n and st.points[n]
    if not p then return false, 'bad_point' end
    if p.status ~= 'log' then return false, 'wrong_state' end
    local choice = type(ev.choice) == 'string' and ev.choice or nil
    local valid = false
    for _, c in ipairs(ChoiceList(ctx.obj) or {}) do
        if c.id == choice then valid = true end
    end
    if not valid then return false, 'bad_choice' end
    p.logged, p.loggedBy = choice, src
    p.status = 'done'
    if choice == CorrectChoice(ctx.obj, p.outcome) then
        p.correct = true
        ctx.award('correct_log')
    else
        p.correct = false
        ctx.penalize('wrong_log')
    end
    for i = #st.logQueue, 1, -1 do
        if st.logQueue[i] == n then table.remove(st.logQueue, i) end
    end
    RefreshLog(ctx, st)
    SendState(ctx, st)
    CheckDone(ctx, st)
    return true
end

-- ============================================================================
--                                    BLOCK
-- ============================================================================

local function ApplyDefaults(obj)
    local c = Cfg()
    if obj.minSeconds == nil then obj.minSeconds = 5 end
    if obj.presenceRange == nil then obj.presenceRange = c.presenceRange[3] end
    if obj.label == nil then obj.label = CP.L('block.interact_points.label') end
    if obj.use == nil then obj.use = c.use.default end
    if type(obj.target) ~= 'table' then obj.target = {} end
    if obj.target.radius == nil then obj.target.radius = TARGET_RADIUS end
    if obj.target.icon == nil then obj.target.icon = (type(obj.hidden) == 'table') and SEARCH_ICON or TARGET_ICON end
    if type(obj.progress) ~= 'table' then obj.progress = {} end
    if obj.progress.label == nil then obj.progress.label = c.label end
    if obj.progress.duration == nil then obj.progress.duration = c.progress[3] * 1000 end
    if obj.progress.anim == nil then obj.progress.anim = c.animation end
    if type(obj.hidden) == 'table' then
        if obj.hidden.count == nil then obj.hidden.count = 1 end
        if obj.hidden.prop == nil then obj.hidden.prop = DEVICE_PROP end
    end
    return obj
end

local function DurationOk(ms, c)
    return type(ms) == 'number' and ms >= c.progress[1] * 1000 and ms <= c.progress[2] * 1000
end

-- A named animation must be in Config.Builder.allowed.animations. Built-in files may also give a raw
-- { scenario } or { dict, clip }; custom missions only the allowed names (Mission Builder guardrails).
local function AnimOk(a, strict)
    if type(a) == 'string' then
        return CP.U.contains(Config.Builder and Config.Builder.allowed and Config.Builder.allowed.animations, a)
    end
    if type(a) == 'table' and not strict then
        return type(a.scenario) == 'string' or (type(a.dict) == 'string' and type(a.clip) == 'string')
    end
    return false
end

CP.Blocks.register(BLOCK, {
    defaults = ApplyDefaults,

    validate = function(obj, mission, location)
        local c = Cfg()
        if type(obj) ~= 'table' then return Bad('block.interact_points.invalid.objective') end
        obj = ApplyDefaults(CP.U.deepcopy(obj))
        local strict = not (type(mission) == 'table' and mission.source == 'builtin')
        if type(obj.points) ~= 'string' and type(obj.points) ~= 'table' and type(obj.points) ~= 'vector3'
            and type(obj.points) ~= 'vector4' then
            return Bad('block.interact_points.invalid.points')
        end
        if not CP.U.contains(c.use.options, obj.use) then return Bad('block.interact_points.invalid.use') end
        if obj.use == 'random' then
            local n = Idx(obj.count)
            if not n or not InRange(n, c.points) then
                return Bad('block.interact_points.invalid.range',
                    { field = 'count', min = c.points[1], max = c.points[2] })
            end
        end
        if not DurationOk(obj.progress.duration, c) then
            return Bad('block.interact_points.invalid.range',
                { field = 'progress.duration', min = c.progress[1] * 1000, max = c.progress[2] * 1000 })
        end
        if not AnimOk(obj.progress.anim, strict) then return Bad('block.interact_points.invalid.anim') end
        if type(obj.target.radius) ~= 'number' or obj.target.radius <= 0 or obj.target.radius > 10 then
            return Bad('block.interact_points.invalid.range', { field = 'target.radius', min = 0.1, max = 10 })
        end
        if not InRange(obj.presenceRange, c.presenceRange) then
            return Bad('block.interact_points.invalid.range',
                { field = 'presenceRange', min = c.presenceRange[1], max = c.presenceRange[2] })
        end
        if type(obj.minSeconds) ~= 'number' or obj.minSeconds < 0 then
            return Bad('block.interact_points.invalid.min_seconds')
        end
        -- roll
        local outcomeIds = {}
        if obj.roll ~= nil then
            if type(obj.roll) ~= 'table' or type(obj.roll.outcomes) ~= 'table' or #obj.roll.outcomes == 0 then
                return Bad('block.interact_points.invalid.roll')
            end
            local sum = 0.0
            for _, o in ipairs(obj.roll.outcomes) do
                if type(o) ~= 'table' or type(o.id) ~= 'string' or outcomeIds[o.id] then
                    return Bad('block.interact_points.invalid.roll')
                end
                if type(o.chance) ~= 'number' or o.chance < 0 or o.chance > 1 then
                    return Bad('block.interact_points.invalid.roll')
                end
                if o.followUp ~= nil and (type(o.followUp) ~= 'table' or not DurationOk(o.followUp.duration, c)) then
                    return Bad('block.interact_points.invalid.follow_up')
                end
                outcomeIds[o.id] = true
                sum = sum + o.chance
            end
            if math.abs(sum - 1.0) > 0.01 then return Bad('block.interact_points.invalid.chances') end
        end
        -- logResult
        if obj.logResult ~= nil and obj.logResult ~= false then
            local choices = ChoiceList(obj)
            if not choices or not InRange(#choices, c.logChoices) then
                return Bad('block.interact_points.invalid.log_choices',
                    { min = c.logChoices[1], max = c.logChoices[2] })
            end
            local ids = {}
            for _, ch in ipairs(choices) do
                if ids[ch.id] then
                    return Bad('block.interact_points.invalid.log_choices',
                        { min = c.logChoices[1], max = c.logChoices[2] })
                end
                ids[ch.id] = true
            end
            local correct = obj.logResult.correct
            if correct ~= nil and type(correct) ~= 'table' then
                return Bad('block.interact_points.invalid.log_correct')
            end
            if obj.roll ~= nil then
                for id in pairs(outcomeIds) do
                    local want = (correct and correct[id]) or id
                    if not ids[want] then return Bad('block.interact_points.invalid.log_correct') end
                end
            elseif correct then
                for _, want in pairs(correct) do
                    if not ids[want] then return Bad('block.interact_points.invalid.log_correct') end
                end
            end
        end
        -- hidden
        if obj.hidden ~= nil then
            if type(obj.hidden) ~= 'table' then return Bad('block.interact_points.invalid.hidden') end
            local n = Idx(obj.hidden.count)
            if not n or n < 1 or type(obj.hidden.prop) ~= 'string' or obj.hidden.prop == '' then
                return Bad('block.interact_points.invalid.hidden')
            end
            if obj.roll ~= nil or (obj.logResult ~= nil and obj.logResult ~= false) then
                return Bad('block.interact_points.invalid.hidden_exclusive')
            end
            -- custom missions: only the block's own device models
            if strict and not CP.U.contains(DEVICE_PROPS, obj.hidden.prop) then
                return Bad('block.interact_points.invalid.hidden_prop', { props = table.concat(DEVICE_PROPS, ', ') })
            end
        end
        if obj.fastBonus ~= nil then
            local fb = obj.fastBonus
            if type(fb) ~= 'table' or type(fb.id) ~= 'string' or type(fb.seconds) ~= 'number' or fb.seconds <= 0 then
                return Bad('block.interact_points.invalid.fast_bonus')
            end
            -- custom missions: a standard id, valued only by the mission's own capped bonuses list
            if strict and not (Config.Bonuses and Config.Bonuses[fb.id]) then
                return Bad('block.interact_points.invalid.fast_bonus_custom', { id = fb.id })
            end
        end
        -- points per location
        local locations = {}
        if type(location) == 'table' then
            locations[1] = location
        elseif type(mission) == 'table' and type(mission.locations) == 'table' then
            locations = mission.locations
        end
        for li, loc in ipairs(locations) do
            local pts = ResolvePoints(obj, loc)
            if not pts or #pts == 0 then
                return Bad('block.interact_points.invalid.points_missing',
                    { key = tostring(obj.points), location = li })
            end
            local used = (obj.use == 'random') and Idx(obj.count) or #pts
            if #pts < used or not InRange(used, c.points) then
                return Bad('block.interact_points.invalid.points_count',
                    { location = li, min = c.points[1], max = c.points[2], have = #pts })
            end
            for _, p in ipairs(pts) do
                if InNoBuild(p.coords) then
                    return Bad('block.interact_points.invalid.points_zone', { location = li })
                end
            end
            if obj.hidden and Idx(obj.hidden.count) > used then
                return Bad('block.interact_points.invalid.hidden_count', { location = li, have = used })
            end
        end
        return true
    end,

    armedCount = function(obj)
        return 0
    end,

    requiredPoints = function(obj)
        if type(obj.points) == 'string' then return { obj.points } end
        return {}
    end,

    prepare = function(ctx)
        Ensure(ctx)
    end,

    start = function(ctx)
        local st = Ensure(ctx)
        st.startMs = Now()
        st.resent = false
        SendState(ctx, st)
        if #st.points == 0 then
            st.ready = true
            TryComplete(ctx, st)
        end
    end,

    tick = function(ctx, dt)
        local st = Ensure(ctx)
        if st.completed or st.failed then return end
        if not st.resent then
            st.resent = true
            SendState(ctx, st)
        end
        if #st.pendingSpawns > 0 and ProcessSpawns(ctx, st) then
            SendState(ctx, st)
            CheckDone(ctx, st)
        end
        if st.ready or (#st.points == 0) then
            TryComplete(ctx, st)
            return
        end
        -- Server-side dwell: who has been at which open point (main action or follow-up), since when.
        local r = Reach(ctx)
        local t = Now()
        for _, src in ipairs(ctx.participants()) do
            local c = ctx.coords(src)
            local bySrc = st.near[src] or {}
            st.near[src] = bySrc
            for n, p in ipairs(st.points) do
                local open = p.status == 'pending' or p.status == 'followup'
                if c and open and CP.U.dist(c, p.coords) <= r then
                    local e = bySrc[n]
                    if not e or e.status ~= p.status then bySrc[n] = { at = t, status = p.status } end
                else
                    bySrc[n] = nil
                end
            end
        end
    end,

    onEvent = function(ctx, src, ev)
        local st = Ensure(ctx)
        if type(ev) ~= 'table' then return false, 'bad_event' end
        if st.completed or st.failed then return false, 'objective_over' end
        if ev.type == 'interact' then return OnInteract(ctx, st, src, ev) end
        if ev.type == 'followup' then return OnFollowUp(ctx, st, src, ev) end
        if ev.type == 'log' then return OnLog(ctx, st, src, ev) end
        return false, 'unknown_event'
    end,

    -- Device props are objects, not peds or vehicles: nothing of this objective can die.
    onEntityDead = function(ctx, netId, killerSrc)
        return nil
    end,

    onParticipantLeft = function(ctx, src)
        Ensure(ctx).near[src] = nil
    end,

    -- Hidden devices not found yet (never spawned) shrink to the new count; for a scaled random
    -- count, points not started yet are dropped. Nothing already found or done is removed.
    rescale = function(ctx)
        local st = Ensure(ctx)
        if st.completed then return end
        local changed = false
        if st.hidden then
            local want = math.max(0, math.min(Idx(ctx.obj.hidden and ctx.obj.hidden.count) or st.total, #st.points))
            local keep = math.max(want, st.found)
            for n = #st.points, 1, -1 do
                if st.total <= keep then break end
                local p = st.points[n]
                if p.device and not p.found then
                    p.device = nil
                    st.total = st.total - 1
                    changed = true
                end
            end
        elseif ctx.obj.use == 'random' then
            local want = Idx(ctx.obj.count)
            if want then
                local active = ActiveCount(st)
                for n = #st.points, 1, -1 do
                    if active <= want then break end
                    if st.points[n].status == 'pending' then
                        st.points[n].status = 'dropped'
                        active = active - 1
                        changed = true
                    end
                end
            end
        end
        if changed then
            SendState(ctx, st)
            CheckDone(ctx, st)
        end
    end,

    -- The time limit fails the run (no alternative outcome for this block).
    onTimeout = function(ctx)
        Ensure(ctx).timedOut = true
        return nil
    end,

    -- The nearest point not yet done (points waiting for their tablet log are done on foot).
    presence = function(ctx, src, coords)
        local st = Ensure(ctx)
        local best
        if not (st.hidden and st.found >= st.total) then
            for _, p in ipairs(st.points) do
                if p.status == 'pending' or p.status == 'followup' then
                    local d = CP.U.dist(coords, p.coords)
                    if not best or d < best then best = d end
                end
            end
        end
        return best or 0.0
    end,

    checklist = function(ctx)
        local st = Ensure(ctx)
        if st.hidden then
            return {
                {
                    label = CP.L('block.interact_points.checklist.devices'),
                    done = st.found >= st.total,
                    value = st.found,
                    max = st.total,
                },
            }
        end
        local done, total = DoneCount(st), ActiveCount(st)
        return {
            { label = CP.L('block.interact_points.checklist.points'), done = done >= total, value = done, max = total },
        }
    end,

    -- Test control: remove the device props this objective spawned and start every point again
    -- (same points, outcomes and hiding spots).
    restart = function(ctx)
        local st = Ensure(ctx)
        for _, p in ipairs(st.points) do
            if p.netId then
                ctx.delete(p.netId)
                RemoveShared(ctx.run, p.netId)
                p.netId = nil
            end
            if p.status ~= 'dropped' then p.status = 'pending' end
            p.found, p.by, p.checkedAt, p.logged, p.loggedBy, p.correct, p.followedBy =
                nil, nil, nil, nil, nil, nil, nil
        end
        st.found = 0
        st.pendingSpawns, st.logQueue, st.log, st.near = {}, {}, nil, {}
        st.ready, st.completed, st.failed = false, false, false
        st.fastChecked, st.fastAwarded = false, false
        st.startMs = Now()
        SendState(ctx, st)
    end,

    stop = function(ctx)
        ctx.state.near = {}
    end,
})
