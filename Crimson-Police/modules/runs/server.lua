-- CP.Runs (server): the run engine.

CP.Runs = CP.Runs or {}
local Runs = CP.Runs
local U = CP.U
local TAG = 'runs'

local BOSS_ID = 'weekly_boss_kingpin'
local SPAWN_WAIT_MS = 3000          -- wait for a server-created entity to exist
local LATE_SPAWN_MS = 30000         -- an entity that appears after SPAWN_WAIT_MS is still deleted within this
local TICK_STUCK_MS = 30000         -- a run tick still busy after this long is reported once
local COOLDOWN_LOAD_WAIT_MS = 5000  -- concurrent callers wait this long for a cooldown rebuild in flight
local HOST_STALE_MS = 15000         -- a host silent this long hands the AI to the next participant
local ENDED_KEEP_S = 900            -- ended runs kept for reclassify (the dodge window is 60 s)
local HOURLY_CACHE_S = 10
local MAX_PED_HITS = 10             -- pedestrian hits counted per participant per run
local VEHICLE_SAMPLE_MS = 3000      -- vehicle telemetry accepted at most this often
local PED_HIT_RANGE = 30.0          -- metres between the participant and the ped they hit
local TIMER_RESYNC_S = 30
local PUSH_THROTTLE_MS = 2000
local MISSING_TICKS = 2             -- ticks an entity must be missing before it counts as gone
local EVIDENCE_MAX_KEYS = 32
local EVIDENCE_MAX_DEPTH = 3
local EVIDENCE_MAX_STRING = 256
local ORPHAN_KEEP_S = 7 * 86400
local REMOVAL_KEEP_S = 15           -- a recorded removal (sc-police /imp) is matched to a vanished car this long
local DAY_CACHE_S = 10              -- completionsToday cache
local PLATE_TRIES = 5               -- rerolls when player_vehicles already has a mission plate
local PLATE_CHARS = 'ABCDEFGHJKLMNPQRSTUVWXYZ0123456789'
local SCENE_EXTEND_S = 60           -- pauseFastClock: the time limit grows by this...
local SCENE_EXTEND_PER_BODY_S = 20  -- ...plus this per body kept
-- Service-record counts per participant row (cp_mission_runs, 003_run_stats.sql); arrests go through noteArrest.
local STAT_KEYS = {
    'arrests',
    'citations',
    'impounds',
    'rescues',
    'vehicles_stopped',
    'evidence',
    'decisions_ok',
    'decisions_best',
    'decisions_bad',
    'lethal',
}
local MEDALS = { medal_gold = 1, medal_silver = 2, medal_bronze = 3 }
local VERDICTS = { best = true, ok = true, wrong = true, critical = true }

-- ARCHITECTURE §4.3: end reason -> result, cooldowns.
local RESULT = {
    quit = 'abandoned',
    off_route = 'abandoned',
    start_timeout = 'abandoned',
    idle = 'abandoned',
    job_change = 'abandoned',
    off_duty = 'abandoned',
    suspended = 'abandoned',
    real_call_cancelled = 'abandoned',
    real_call = 'abandoned',
    force_recall = 'abandoned',
    cancelled = 'abandoned',
    downed = 'failed',
    disconnected = 'failed',
    completed = 'completed',
    time_limit = 'failed',
    mission_failed = 'failed',
    vehicle_removed_external = 'abandoned',   -- a run vehicle removed by someone outside the run: not counted
}
local function Set(list)
    local out = {}
    for _, v in ipairs(list) do out[v] = true end
    return out
end
local TYPE_COOLDOWN = Set({
    'quit',
    'off_route',
    'start_timeout',
    'idle',
    'job_change',
    'off_duty',
    'suspended',
    'real_call_cancelled',
    'downed',
    'disconnected',
})
local MISSION_COOLDOWN = Set({
    'quit',
    'off_route',
    'start_timeout',
    'idle',
    'job_change',
    'off_duty',
    'suspended',
    'real_call_cancelled',
    'downed',
    'disconnected',
    'completed',
    'time_limit',
    'mission_failed',
})
local TELEMETRY_KINDS = Set({ 'vehicle', 'ped_hit', 'lights_siren', 'weapon_fired', 'area' })
local AREA_MAX = 96                                                  -- bytes of a street · zone text a client reports for its own view
local LOST_REASONS = Set({ 'off_duty', 'job_change', 'suspended' })  -- CP.Access.recheck / onLost reasons

local runs = {}          -- runId -> run (accepted or in_progress)
local bySrc = {}         -- src -> runId (active participants only)
local ctxCache = {}      -- runId -> { [objectiveIndex] = ctx }
local endedRuns = {}     -- runId -> { at, run }
local cooldownCache = {} -- citizenid -> { types = {}, missions = {}, loaded = bool }
local hourCache = {}     -- citizenid -> { n, at }
local orphans = {}       -- citizenid -> { names = { [item] = true }, at, sweptAt }
local dayCache = {}      -- citizenid .. '|' .. type -> { n, at }
local removals = {}      -- netId -> { src, via, dist, at } (noteExternalRemoval)
local warned = {}
local dbReady = false

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function WarnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

-- Call CP.<mod>.<fn>(...) when it exists; returns true plus its results, or false.
local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function Db()
    if dbReady then return true end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    dbReady = true
    return true
end

local function PlayerOnline(src)
    return src and GetPlayerName(src) ~= nil
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function Int(v, lo, hi)
    local n = math.floor(Num(v, 0) + 0.0)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local function limits() return Config.Limits or {} end
local function AbandonCooldown() return Num(limits().abandonCooldown, 300) end
local function CorpseCleanup() return Num(limits().corpseCleanup, 30) end

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    return type(v.x or v[1]) == 'number' and type(v.y or v[2]) == 'number' and type(v.z or v[3]) == 'number'
end

local function Vec3Of(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function ModelHash(model)
    if type(model) == 'number' then return math.tointeger(model) or math.floor(model) end
    if type(model) == 'string' and model ~= '' then return joaat(model) end
    return nil
end

local function Label(key, vars)
    return CP.L(key, vars)
end

local function Fire(name, ...)
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire(name, ...) end
end

-- A HUD or objective payload with its CP.Lt texts turned into tokens (each client resolves them).
local function Tokens(v)
    if CP.Locale and CP.Locale.tokenize then return CP.Locale.tokenize(v) end
    return v
end

-- ============================================================================
--                                    TIERS
-- ============================================================================

local function TierFor(n)
    if CP.Scaling and CP.Scaling.tierFor then return CP.Scaling.tierFor(n) end
    local rows = Config.Scaling or {}
    for i = 1, #rows do
        if Num(rows[i].maxParticipants, 0) >= n then return rows[i] end
    end
    return rows[#rows]
end

local function TierByName(name)
    if name == nil then return nil end
    if CP.Scaling and CP.Scaling.tierByName then return CP.Scaling.tierByName(name) end
    for _, row in ipairs(Config.Scaling or {}) do
        if row.tier == name or row == name then return row end
    end
    return nil
end

local function LowerTier(a, b)
    if CP.Scaling and CP.Scaling.lower then return CP.Scaling.lower(a, b) end
    if not a then return b end
    if not b then return a end
    local rows = Config.Scaling or {}
    local ia, ib = 1, 1
    for i = 1, #rows do
        if rows[i].tier == a.tier then ia = i end
        if rows[i].tier == b.tier then ib = i end
    end
    return ib < ia and b or a
end

local function TierName(row)
    return type(row) == 'table' and row.tier or nil
end

local function ForcedTier(run)
    return run.test and run.test.forcedTier and TierByName(run.test.forcedTier) or nil
end

-- ============================================================================
--                                 PARTICIPANTS
-- ============================================================================

function Runs.activeSrcs(run)
    local out = {}
    if type(run) ~= 'table' or not run.order then return out end
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if p and p.status == 'active' then out[#out + 1] = src end
    end
    return out
end

function Runs.isParticipant(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src then return false end
    local p = run.participants and run.participants[src]
    return p ~= nil and p.status == 'active'
end

function Runs.host(run)
    return type(run) == 'table' and run.host or nil
end

function Runs.get(runId)
    if type(runId) ~= 'string' then return nil end
    return runs[runId]
end

function Runs.getBySrc(src)
    src = ToSrc(src)
    local id = src and bySrc[src]
    local run = id and runs[id]
    if not run then return nil end
    local p = run.participants[src]
    if not p or p.status ~= 'active' then return nil end
    return run, p
end

function Runs.isOnMission(src)
    return Runs.getBySrc(src) ~= nil
end

function Runs.all()
    local out = {}
    for _, run in pairs(runs) do
        if run.state ~= 'ended' then out[#out + 1] = run end
    end
    table.sort(out, function(a, b) return (a.acceptedAt or 0) < (b.acceptedAt or 0) end)
    return out
end

local function ParticipantsList(run)
    local out = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if p then
            out[#out + 1] = {
                src = src,
                name = p.name,
                callsign = p.callsign,
                departmentShort = p.departmentShort or '',
                status = p.status,
                arrived = p.arrived == true,
            }
        end
    end
    return out
end

local function ActiveDepartments(run, extra)
    local seen, n = {}, 0
    local function add(d)
        if d and not seen[d] then seen[d] = true; n = n + 1 end
    end
    for _, s in ipairs(Runs.activeSrcs(run)) do add(run.participants[s].department) end
    if extra then add(extra.department) end
    return n, seen
end

local function RefreshDepartments(run)
    local _, seen = ActiveDepartments(run)
    run.departments = seen
end

-- ============================================================================
--                                  MESSAGING
-- ============================================================================

local function EventName(name)
    if type(name) ~= 'string' then return nil end
    if U.startsWith(name, 'client:') then return CP.e(name) end
    return name
end

function Runs.send(run, name, ...)
    local ev = EventName(name)
    if type(run) ~= 'table' or not ev then return end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        TriggerClientEvent(ev, src, ...)
    end
end

function Runs.objectiveEvent(run, index, data)
    if type(run) ~= 'table' or run.state ~= 'in_progress' then return end
    Runs.send(run, 'client:objective', run.id, index, { action = 'update', data = Tokens(data) })
end

-- Text fields may be CP.Lt texts ({ key, vars }): they go out as tokens and each client resolves them.
function Runs.hud(run, patch)
    if type(run) ~= 'table' or type(patch) ~= 'table' then return end
    Runs.send(run, 'client:hud', run.id, Tokens(patch))
end

function Runs.hudFor(run, src, patch)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src or type(patch) ~= 'table' then return end
    TriggerClientEvent(CP.e('client:hud'), src, run.id, Tokens(patch))
end

local function BroadcastParticipants(run)
    Runs.send(run, 'client:participants', run.id, ParticipantsList(run))
end

local function Notify(src, kind, key, vars)
    if Has('Tablet', 'notify') then Call('Tablet', 'notify', src, kind, key, vars) end
end

-- Push topic 'run' (the view) to every active participant, or to the given list.
local function PushRun(run, srcs)
    if not Has('Tablet', 'push') then return end
    for _, src in ipairs(srcs or Runs.activeSrcs(run)) do
        local ok, view = pcall(Runs.view, run, src)
        if ok then
            Call('Tablet', 'push', src, 'run', view)
        else
            CP.err(TAG, 'view for %s failed: %s', tostring(src), tostring(view))
        end
    end
    run.pushedAt = GetGameTimer()
end

local function PushNone(src)
    if Has('Tablet', 'push') then Call('Tablet', 'push', src, 'run', nil) end
end

-- ============================================================================
--                                    TIMER
-- ============================================================================

local function SyncTimer(run)
    local t = run.timer
    if not t or not t.running then return end
    local now = GetGameTimer()
    if not t.paused and t.lastTick then
        t.remaining = t.remaining - (now - t.lastTick) / 1000
        if t.remaining < 0 then t.remaining = 0 end
    end
    t.lastTick = now
end

function Runs.remaining(run)
    if type(run) ~= 'table' or not run.timer or not run.timer.running then return nil end
    SyncTimer(run)
    return run.timer.remaining
end

local function TimerPatch(run)
    local r = Runs.remaining(run)
    if r == nil then return false end
    return { remaining = math.max(0, math.ceil(r)), paused = run.timer.paused == true }
end

local function SendTimer(run)
    run.timerSentAt = os.time()
    Runs.hud(run, { timer = TimerPatch(run) })
end

function Runs.adjustTimer(run, seconds)
    seconds = Num(seconds, 0)
    if type(run) ~= 'table' or not run.timer or run.state == 'ended' or seconds == 0 then return end
    SyncTimer(run)
    run.timer.remaining = math.max(0, run.timer.remaining + seconds)
    if not run.timer.running then
        run.timeLimit = math.max(0, math.floor(run.timer.remaining))
        return
    end
    CP.log(TAG, 'run %s timer %+d s -> %.1f s', run.id, seconds, run.timer.remaining)
    SendTimer(run)
end

function Runs.pauseTimer(run, paused)
    if type(run) ~= 'table' or not run.timer or run.state == 'ended' then return end
    SyncTimer(run)
    run.timer.paused = paused == true
    run.timer.lastTick = GetGameTimer()
    if run.timer.running then SendTimer(run) end
end

-- ============================================================================
--                      BLOCKS AND CTX (ARCHITECTURE §7.1)
-- ============================================================================

local function BlockOf(run, i)
    local o = run.objectives[i]
    local obj = (o and o.obj) or (run.mission.objectives or {})[i]
    if type(obj) ~= 'table' or type(obj.block) ~= 'string' then return nil end
    return CP.Blocks.get(obj.block)
end

local function PedCoords(src)
    src = ToSrc(src)
    if not src then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local ObjectiveHud -- forward declaration (defined with the HUD helpers below)

local function GetCtx(run, i)
    local cache = ctxCache[run.id]
    if not cache then
        cache = {}
        ctxCache[run.id] = cache
    end
    local o = run.objectives[i]
    local ctx = cache[i]
    if not ctx then
        ctx = {
            run = run,
            index = i,
            mission = run.mission,
            location = run.location,
            base = (run.mission.objectives or {})[i],
            rng = U.rng((tonumber(run.seed) or 1) + i),
        }
        ctx.complete = function(data) return Runs.objectiveComplete(run, i, data) end
        ctx.fail = function(reasonKey) return Runs.failRun(run, reasonKey) end
        ctx.award = function(id, opts) return Runs.award(run, id, opts) end
        ctx.penalize = function(id, opts) return Runs.penalize(run, id, opts) end
        ctx.send = function(data) return Runs.objectiveEvent(run, i, data) end
        ctx.hud = function(patch) return ObjectiveHud(run, i, patch) end
        ctx.spawnPed = function(opts)
            opts = type(opts) == 'table' and opts or {}
            opts.obj = i
            return Runs.spawnPed(run, opts)
        end
        ctx.spawnVehicle = function(opts)
            opts = type(opts) == 'table' and opts or {}
            opts.obj = i
            return Runs.spawnVehicle(run, opts)
        end
        ctx.spawnObject = function(opts)
            opts = type(opts) == 'table' and opts or {}
            opts.obj = i
            return Runs.spawnObject(run, opts)
        end
        ctx.canSpawn = function(n, armed) return Runs.canSpawn(run, n, armed) end
        ctx.delete = function(netId) return Runs.deleteEntity(run, netId) end
        ctx.participants = function() return Runs.activeSrcs(run) end
        ctx.coords = function(src) return PedCoords(src) end
        ctx.combat = function(acc, armour)
            if CP.Scaling and CP.Scaling.combat then return CP.Scaling.combat(acc, armour, run.tier, run) end
            return acc, armour
        end
        ctx.isHost = function(src) return ToSrc(src) == run.host end
        ctx.host = function() return run.host end
        cache[i] = ctx
    end
    ctx.obj = (o and o.obj) or ctx.base
    ctx.tier = run.tier
    ctx.state = o and o.state or {}
    return ctx
end

-- Call a block hook of objective i (pcall). Returns ok, results...
local function CallBlock(run, i, hook, ...)
    local impl = BlockOf(run, i)
    if not impl or type(impl[hook]) ~= 'function' then return false end
    local ctx = GetCtx(run, i)
    local res = table.pack(pcall(impl[hook], ctx, ...))
    if not res[1] then
        CP.err(TAG, 'block %s.%s (run %s, objective %d) failed: %s', tostring(impl.id), hook, run.id, i,
            tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

-- The engine's own ctx of objective `index` (the same table every block hook gets, ctx.state included),
-- e.g. for CP.AntiCheat's presence sampling through the block's presence(ctx, src, coords). nil for an
-- ended run or an unknown objective.
function Runs.ctx(run, index)
    if type(run) ~= 'table' or run.state == 'ended' or type(run.objectives) ~= 'table' then return nil end
    index = math.tointeger(tonumber(index) or -1)
    if not index or not run.objectives[index] or runs[run.id] ~= run then return nil end
    return GetCtx(run, index)
end

-- ============================================================================
--                                HUD OBJECTIVES
-- ============================================================================

local function ObjectiveLabel(run, i)
    local o = run.objectives[i]
    local obj = (o and o.obj) or (run.mission.objectives or {})[i] or {}
    local l = obj.label
    if type(l) == 'string' and l ~= '' then
        if CP.Locale and CP.Locale.has and CP.Locale.has(l) then return CP.L(l) end
        return l
    end
    return Label('run.objective_default', { n = i })
end

local function ChecklistOf(run, i)
    local ok, items = CallBlock(run, i, 'checklist')
    if ok and type(items) == 'table' then return items end
    return nil
end

local function ApplyChecklist(entry, items)
    if type(items) ~= 'table' or #items == 0 then return end
    local first = items[1]
    if type(first) == 'table' and type(first.max) == 'number' and first.max > 0 then
        entry.value = Num(first.value, 0)
        entry.max = first.max
    end
    local extra = {}
    for k = 2, #items do
        local it = items[k]
        if type(it) == 'table' and it.label then
            if type(it.max) == 'number' and it.max > 0 then
                extra[#extra + 1] = ('%s %d/%d'):format(tostring(it.label), math.floor(Num(it.value, 0)),
                    math.floor(it.max))
            else
                extra[#extra + 1] = tostring(it.label)
            end
        end
    end
    if #extra > 0 then entry.detail = table.concat(extra, ' · ') end
end

-- HudState.objectives (§9.3). includePending: labels before the run is in progress (Active Mission).
local function HudObjectives(run, includePending)
    local out = {}
    local started = run.state == 'in_progress'
    if not started and not includePending then return out end
    for i = 1, #(run.mission.objectives or {}) do
        local o = run.objectives[i] or {}
        local entry = {
            label = ObjectiveLabel(run, i),
            done = o.status == 'done',
            current = started and i == run.objectiveIndex and o.status == 'active',
        }
        if started then
            if o.status == 'done' then
                ApplyChecklist(entry, o.final)
            elseif entry.current then
                ApplyChecklist(entry, ChecklistOf(run, i))
            end
            local h = o.hud
            if type(h) == 'table' and o.status ~= 'done' then
                if type(h.value) == 'number' then entry.value = h.value end
                if type(h.max) == 'number' then entry.max = h.max end
                if type(h.detail) == 'string' and h.detail ~= '' then entry.detail = h.detail end
            end
        end
        out[#out + 1] = entry
    end
    return out
end

-- The Business Check tablet log of the current objective (view.log): its point, or '' when none is asked.
local function LogKey(run)
    local cur = run.objectives[run.objectiveIndex]
    local lg = cur and cur.status == 'active' and type(cur.state) == 'table' and cur.state.log or nil
    if type(lg) ~= 'table' or lg.point == nil then return '' end
    return tostring(lg.point)
end

local function RefreshHud(run, force)
    if run.state ~= 'in_progress' then return end
    local list = HudObjectives(run, false)
    local ok, key = pcall(json.encode, list)
    if not ok then key = tostring(GetGameTimer()) end
    -- A new (or closed) tablet log point is pushed at once, not with the throttled progress push, so the
    -- Active Mission log panel moves on right away (docs/notes/run_ui.md).
    local lk = LogKey(run)
    local logChanged = lk ~= (run.logKey or '')
    run.logKey = lk
    if force or key ~= run.hudKey then
        run.hudKey = key
        Runs.hud(run, { objectives = list })
        if force or logChanged or not run.pushedAt or GetGameTimer() - run.pushedAt >= PUSH_THROTTLE_MS then
            PushRun(run)
        end
    elseif logChanged then
        PushRun(run)
    end
end

-- ctx.hud: detail/value/max belong to objective i's HUD entry; everything else is a top-level HUD patch.
ObjectiveHud = function(run, i, patch)
    if type(run) ~= 'table' or type(patch) ~= 'table' or run.state == 'ended' then return end
    local o = run.objectives[i]
    if not o then return end
    local rest, touched = {}, false
    for k, v in pairs(patch) do
        if k == 'detail' or k == 'value' or k == 'max' then
            o.hud = o.hud or {}
            if v == false then o.hud[k] = nil else o.hud[k] = Tokens(v) end
            touched = true
        else
            rest[k] = v
        end
    end
    if touched then RefreshHud(run) end
    if next(rest) ~= nil then Runs.hud(run, rest) end
end

-- ============================================================================
--                         ENTITIES (ARCHITECTURE §6.1)
-- ============================================================================
-- The NPC state of an entity from the server's own record, never from the replicated cp bag (a client can
-- write the bag of an entity it owns): CP.Npc.getState, else the engine's copy of the bag it wrote (e.bag).
local function NpcState(netId, e)
    local ok, st = Call('Npc', 'getState', netId)
    if ok and st ~= nil then return st end
    return type(e.bag) == 'table' and e.bag.state or nil
end

local function EntityCounts(run)
    local total, armedAlive = 0, 0
    for netId, e in pairs(run.entities) do
        total = total + 1
        -- a hidden contact's weapon counts before it is drawn (armedTruth never leaves the server)
        if (e.armed or e.armedTruth) and not e.dead then
            local st = NpcState(netId, e)
            if st ~= 'cuffed' and st ~= 'dead' then armedAlive = armedAlive + 1 end
        end
    end
    return total, armedAlive
end

-- Spawns still waiting for their entity to exist count toward the caps too, so two spawns that interleave
-- (a block tick and a net event) can never pass the caps together.
local function PendingOf(run)
    local ps = run.pendingSpawns
    if not ps then
        ps = { total = 0, armed = 0 }
        run.pendingSpawns = ps
    end
    return ps
end

function Runs.canSpawn(run, n, armed)
    if type(run) ~= 'table' or run.state == 'ended' then return false end
    n = math.max(0, math.floor(Num(n, 1)))
    local total, armedAlive = EntityCounts(run)
    local ps = PendingOf(run)
    if total + ps.total + n > Num(limits().maxEntities, 80) then return false end
    if armed and armedAlive + ps.armed + n > Num(limits().maxArmedAlive, 25) then return false end
    return true
end

-- Run fn (which creates and tracks one entity) while it counts as a pending spawn.
local function WithPending(run, armed, fn)
    local ps = PendingOf(run)
    ps.total = ps.total + 1
    if armed then ps.armed = ps.armed + 1 end
    local ok, entity, netId = pcall(fn)
    ps.total = math.max(0, ps.total - 1)
    if armed then ps.armed = math.max(0, ps.armed - 1) end
    if not ok then
        CP.err(TAG, 'run %s: spawn failed: %s', tostring(run.id), tostring(entity))
        return nil
    end
    return entity, netId
end

local function WaitExists(entity)
    if not entity or entity == 0 then return false end
    local deadline = GetGameTimer() + SPAWN_WAIT_MS
    while not DoesEntityExist(entity) do
        if GetGameTimer() >= deadline then return false end
        Wait(0)
    end
    return true
end

-- A server-created entity that did not exist in time may still appear later (the RPC reaches a client
-- late): delete it when it does, so nothing is left behind. The model check keeps a reused handle safe.
local function SameHash(a, b)
    a, b = math.tointeger(tonumber(a) or 0), math.tointeger(tonumber(b) or 0)
    if not a or not b then return false end
    return (a & 0xFFFFFFFF) == (b & 0xFFFFFFFF)   -- signed or unsigned 32-bit forms
end

local function DeleteWhenItAppears(entity, hash)
    if not entity or entity == 0 then return end
    CreateThread(function()
        local deadline = GetGameTimer() + LATE_SPAWN_MS
        while GetGameTimer() < deadline do
            if DoesEntityExist(entity) then
                if not hash or not GetEntityModel or SameHash(GetEntityModel(entity), hash) then
                    DeleteEntity(entity)
                    CP.log(TAG, 'late entity %s deleted', tostring(entity))
                end
                return
            end
            Wait(500)
        end
    end)
end

local function NetIdOf(entity)
    local deadline = GetGameTimer() + SPAWN_WAIT_MS
    local netId = NetworkGetNetworkIdFromEntity(entity)
    while (not netId or netId == 0) and GetGameTimer() < deadline do
        Wait(0)
        netId = NetworkGetNetworkIdFromEntity(entity)
    end
    if not netId or netId == 0 then return nil end
    return netId
end

local function SplitCoords(c)
    local x, y, z = U.xyz(c)
    if not x then return nil end
    local h = 0.0
    if type(c) == 'vector4' then
        h = c.w
    elseif type(c) == 'table' then
        h = tonumber(c.w or c[4] or c.heading) or 0.0
    end
    return x + 0.0, y + 0.0, z + 0.0, h + 0.0
end

local function Track(run, entity, kind, opts, extraCfg)
    if not WaitExists(entity) then
        CP.warn(TAG, 'run %s: %s %s did not appear within %d ms', run.id, kind, tostring(opts.model), SPAWN_WAIT_MS)
        DeleteWhenItAppears(entity, ModelHash(opts.model))
        return nil
    end
    if run.state == 'ended' then
        DeleteEntity(entity)
        return nil
    end
    local netId = NetIdOf(entity)
    if not netId then
        DeleteEntity(entity)
        CP.warn(TAG, 'run %s: %s %s got no network id', run.id, kind, tostring(opts.model))
        return nil
    end
    local cfg = {}
    if type(extraCfg) == 'table' then for k, v in pairs(extraCfg) do cfg[k] = v end end
    if type(opts.cfg) == 'table' then for k, v in pairs(opts.cfg) do cfg[k] = v end end
    local hidden = opts.hidden == true
    local hiddenCfg = nil
    if hidden then
        -- a contact: nothing truth-derived goes in the replicated bag until arm() at the draw
        hiddenCfg = cfg
        cfg = { model = cfg.model }
    end
    local bag = {
        run = run.id,
        obj = opts.obj,
        role = opts.role,
        state = 'idle',
        armed = (not hidden) and opts.armed == true,
        cfg = cfg,
        tag = opts.tag,
    }
    Entity(entity).state:set('cp', bag, true)
    -- bag: the server's copy of what was written (CP.Npc seeds its record from it and mirrors every later
    -- write back into it); the replicated bag is never read back on the server.
    run.entities[netId] = {
        entity = entity,
        kind = kind,
        obj = opts.obj,
        role = opts.role,
        armed = (not hidden) and opts.armed == true,
        armedTruth = hidden and opts.armed == true or nil,
        hiddenCfg = hiddenCfg,
        dead = false,
        deadAt = nil,
        tag = opts.tag,
        model = opts.model,
        missing = 0,
        bag = U.deepcopy(bag),
    }
    if run.state == 'ended' then
        Runs.deleteEntity(run, netId)
        return nil
    end
    return entity, netId
end

function Runs.spawnPed(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = ModelHash(opts.model)
    local x, y, z, h = SplitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnPed needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, opts.armed == true) then return nil end
    local entity, netId = WithPending(run, opts.armed == true, function()
        local ped = CreatePed(4, hash, x, y, z, h, true, true)
        return Track(run, ped, 'ped', opts, {
            weapon = opts.weapon,
            accuracy = opts.accuracy,
            armour = opts.armour,
            health = opts.health,
            model = opts.model,
        })
    end)
    if not entity then return nil end
    -- opts.hidden (a contact): no weapon and no armour until arm(run, netId) at the draw
    if opts.hidden ~= true then
        if opts.armed and opts.weapon then
            local w = ModelHash(opts.weapon)
            if w then GiveWeaponToPed(entity, w, 250, false, true) end
        end
        local armour = Num(opts.armour, 0)
        if armour > 0 then SetPedArmour(entity, math.floor(armour)) end
    end
    CP.log(TAG, 'run %s: ped %s (%s) netId %d', run.id, tostring(opts.model), tostring(opts.role), netId)
    return entity, netId
end

-- Vehicle type for CreateVehicleServerSetter ('automobile' for every allowed mission model).
local VEHICLE_TYPES = { stockade = 'automobile', stockade3 = 'automobile' }

local function PlateCfg()
    local p = Config.Custody and Config.Custody.plates or {}
    local prefix = type(p.prefix) == 'string' and p.prefix:upper():gsub('[^%w]', '') or 'CP'
    local length = math.floor(Num(p.length, 8))
    if length > 8 then length = 8 end
    if #prefix >= length then prefix = prefix:sub(1, math.max(0, length - 1)) end
    return prefix, length
end

-- Whether a plate is in the reserved mission pattern (Config.Custody.plates).
function Runs.isMissionPlate(plate)
    if type(plate) ~= 'string' then return false end
    local prefix, length = PlateCfg()
    if #plate ~= length or plate:sub(1, #prefix) ~= prefix then return false end
    return plate:sub(#prefix + 1):match('^[A-Z0-9]*$') ~= nil
end

-- Plates come from a stream of their own, never from the run seed: a plate is visible to every client, and a
-- plate drawn from the seed would let a client work the seed out and replay the hidden server rolls (ctx.rng).
local function RollPlate(run)
    if not run.plateRng then
        local seed = U.hash(('%s:plate:%s:%s'):format(U.uuid(), tostring(run.id), tostring(GetGameTimer())))
        run.plateRng = U.rng(seed & 0x7FFFFFFF)
    end
    local prefix, length = PlateCfg()
    local out = { prefix }
    for _ = #prefix + 1, length do
        local i = run.plateRng:int(1, #PLATE_CHARS)
        out[#out + 1] = PLATE_CHARS:sub(i, i)
    end
    return table.concat(out)
end

-- A plate in the reserved pattern that no player owns (player_vehicles, read-only through CP.Qbx): the plate
-- the mission asks for when it is in the pattern, else a roll. When the lookup fails the pattern alone is
-- used; after PLATE_TRIES owned plates the last roll is used.
local function MissionPlate(run, wanted)
    local plate = Runs.isMissionPlate(wanted) and wanted or RollPlate(run)
    if not Has('Qbx', 'plateOwned') then return plate end
    for _ = 1, PLATE_TRIES do
        local ok, owned = Call('Qbx', 'plateOwned', plate)
        if not ok or owned ~= true then return plate end
        CP.log(TAG, 'run %s: plate %s belongs to a player; rerolled', run.id, plate)
        plate = RollPlate(run)
    end
    return plate
end

function Runs.spawnVehicle(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = ModelHash(opts.model)
    local x, y, z, h = SplitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnVehicle needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, false) then return nil end
    local entity, netId = WithPending(run, false, function()
        local veh
        if CreateVehicleServerSetter then
            local vtype = opts.vehicleType or (type(opts.model) == 'string' and VEHICLE_TYPES[opts.model:lower()])
                or 'automobile'
            veh = CreateVehicleServerSetter(hash, vtype, x, y, z, h)
        else
            veh = CreateVehicle(hash, x, y, z, h, true, true)
        end
        return Track(run, veh, 'vehicle', opts, { model = opts.model })
    end)
    if not entity then return nil end
    -- every mission vehicle carries a reserved plate no player owns (a plate the mission asks for is used
    -- only when it is in that pattern and no player owns it), so nothing done to a mission car can reach a
    -- player's own car
    local plate = MissionPlate(run, type(opts.plate) == 'string' and opts.plate:upper() or nil)
    if run.state == 'ended' then return nil end
    local e = run.entities[netId]
    if e then e.plate = plate end
    if SetVehicleNumberPlateText then SetVehicleNumberPlateText(entity, plate) end
    return entity, netId
end

function Runs.spawnObject(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = ModelHash(opts.model)
    local x, y, z, h = SplitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnObject needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, false) then return nil end
    local entity, netId = WithPending(run, false, function()
        local obj = CreateObjectNoOffset(hash, x, y, z, true, true, false)
        return Track(run, obj, 'object', opts, { model = opts.model })
    end)
    if not entity then return nil end
    if type(opts.coords) == 'vector4' or (type(opts.coords) == 'table' and (opts.coords.w or opts.coords[4])) then
        SetEntityHeading(entity, h)
    end
    if opts.frozen ~= false then FreezeEntityPosition(entity, true) end
    return entity, netId
end

function Runs.deleteEntity(run, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    if type(run) ~= 'table' or not netId then return false end
    local e = run.entities[netId]
    if not e then return false end
    run.entities[netId] = nil
    if run.held then
        for i, h in ipairs(run.held) do
            if h == netId then
                table.remove(run.held, i)
                break
            end
        end
    end
    if e.entity and DoesEntityExist(e.entity) then DeleteEntity(e.entity) end
    return true
end

-- The draw of a hidden contact (spawnPed opts.hidden): the weapon, armour and combat settings go to the ped
-- and its cp bag now, once. false when the entity is unknown, dead or not armed in truth.
function Runs.arm(run, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    if type(run) ~= 'table' or run.state == 'ended' or not netId then return false end
    local e = run.entities[netId]
    if not e or e.dead or e.kind ~= 'ped' then return false end
    if e.armedGiven then return true end
    if not e.armedTruth and not e.armed then return false end
    e.armedGiven = true
    local cfg = type(e.hiddenCfg) == 'table' and e.hiddenCfg or {}
    local entity = e.entity
    if entity and DoesEntityExist(entity) then
        local w = ModelHash(cfg.weapon)
        if w then GiveWeaponToPed(entity, w, 250, false, true) end
        local armour = Num(cfg.armour, 0)
        if armour > 0 then SetPedArmour(entity, math.floor(armour)) end
    end
    e.armed = true
    -- the bag through CP.Npc when it runs this ped (its record is the server's truth), else directly
    local okN, written = false, false
    if Has('Npc', 'setState') then
        okN, written = Call('Npc', 'setState', run, netId, NpcState(netId, e) or 'idle', { armed = true, cfg = cfg })
    end
    if not (okN and written) then
        local bag = U.deepcopy(e.bag or {})
        bag.armed = true
        bag.cfg = type(bag.cfg) == 'table' and bag.cfg or {}
        for k, v in pairs(cfg) do bag.cfg[k] = v end
        bag.seq = (tonumber(bag.seq) or 0) + 1
        if entity and DoesEntityExist(entity) then
            local ok = pcall(function() Entity(entity).state:set('cp', bag, true) end)
            if ok then e.bag = bag end
        end
    end
    CP.log(TAG, 'run %s: contact %d armed', run.id, netId)
    return true
end

-- ============================================================================
--                     ADOPTION (one objective to another)
-- ============================================================================
-- An entity moves from the objective that spawned it to objective toIndex (a pursuit handing its stopped car
-- and people to a field_contact): deaths, CP.Npc evidence and custody events go to the adopter only.

local function AdoptOne(run, netId, toIndex)
    local e = run.entities[netId]
    if not e then return false end
    local from = e.obj
    e.obj = toIndex
    if type(e.bag) == 'table' then e.bag.obj = toIndex end
    local okN, npcDone = false, false
    if e.kind == 'ped' and Has('Npc', 'adopt') then okN, npcDone = Call('Npc', 'adopt', netId, toIndex) end
    if not (okN and npcDone) and e.entity and DoesEntityExist(e.entity) and type(e.bag) == 'table' then
        pcall(function() Entity(e.entity).state:set('cp', U.deepcopy(e.bag), true) end)
    end
    if run.host then
        TriggerClientEvent(CP.e('client:objective'), run.host, run.id, toIndex,
            { action = 'adopt', op = 'adopt', netId = netId, obj = toIndex, from = from })
    end
    CP.log(TAG, 'run %s: %s %d moved from objective %s to %d', run.id, tostring(e.kind), netId, tostring(from), toIndex)
    return true
end

function Runs.adopt(run, netId, toIndex)
    netId = math.tointeger(tonumber(netId) or -1)
    toIndex = math.tointeger(tonumber(toIndex) or -1)
    if type(run) ~= 'table' or run.state == 'ended' or not netId or not toIndex then return false end
    if not run.objectives[toIndex] then return false end
    return AdoptOne(run, netId, toIndex)
end

function Runs.adoptMany(run, netIds, toIndex)
    if type(netIds) ~= 'table' then return 0 end
    local n = 0
    for _, netId in ipairs(netIds) do
        if Runs.adopt(run, netId, toIndex) then n = n + 1 end
    end
    return n
end

-- The objective that owns an entity now (after any adoption), or nil.
function Runs.ownerOf(run, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    local e = type(run) == 'table' and netId and run.entities[netId] or nil
    return e and e.obj or nil
end

-- An event about one entity (custody: handed_over, impounded, removed) for the objective that owns it.
function Runs.entityEvent(run, netId, ev)
    local obj = Runs.ownerOf(run, netId)
    if not obj or type(ev) ~= 'table' then return false, 'no_owner' end
    return Runs.dispatch(run, obj, ev.src, ev)
end

-- ============================================================================
--                       HELD BODIES (Process the scene)
-- ============================================================================
-- opts = { roles = { 'hostile', ... }, max = n }: dead peds of those roles are kept, oldest first out.

function Runs.holdBodies(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' then return false end
    opts = type(opts) == 'table' and opts or {}
    local roles = nil
    if type(opts.roles) == 'table' and #opts.roles > 0 then
        roles = {}
        for _, r in ipairs(opts.roles) do roles[tostring(r)] = true end
    end
    run.holdBodies = { roles = roles, max = math.max(0, math.floor(Num(opts.max, 4))) }
    run.held = run.held or {}
    return true
end

local function HoldBody(run, netId)
    local hb = run.holdBodies
    local e = run.entities[netId]
    if not hb or not e or e.kind ~= 'ped' or e.held then return end
    if hb.roles and not hb.roles[tostring(e.role)] then return end
    if hb.max <= 0 then return end
    e.held = true
    run.held[#run.held + 1] = netId
    while #run.held > hb.max do
        local oldest = table.remove(run.held, 1)
        Runs.deleteEntity(run, oldest)
    end
end

function Runs.heldBodies(run)
    local out = {}
    if type(run) ~= 'table' or not run.held then return out end
    for _, netId in ipairs(run.held) do
        local e = run.entities[netId]
        if e then
            local coords = e.entity and DoesEntityExist(e.entity) and GetEntityCoords(e.entity) or e.lastCoords
            out[#out + 1] = { netId = netId, role = e.role, coords = coords }
        end
    end
    return out
end

function Runs.releaseBody(run, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    if type(run) ~= 'table' or not netId then return false end
    local e = run.entities[netId]
    if not e or not e.held then return false end
    return Runs.deleteEntity(run, netId)
end

-- Process the scene started: the fast-completion clock stops and the time limit grows by 60 s plus 20 s per
-- body kept. Once per run.
function Runs.pauseFastClock(run)
    if type(run) ~= 'table' or run.state ~= 'in_progress' or run.fastClockAt then return false end
    run.fastClockAt = os.time()
    local bodies = run.held and #run.held or 0
    Runs.adjustTimer(run, SCENE_EXTEND_S + SCENE_EXTEND_PER_BODY_S * bodies)
    return true
end

-- filter: function(e, netId) -> boolean, or { obj, kind, role, tag, armed, alive, dead }
function Runs.entitiesFor(run, filter)
    local out = {}
    if type(run) ~= 'table' or not run.entities then return out end
    for netId, e in pairs(run.entities) do
        local keep = true
        if type(filter) == 'function' then
            local ok, res = pcall(filter, e, netId)
            keep = ok and res and true or false
        elseif type(filter) == 'table' then
            if filter.obj ~= nil and e.obj ~= filter.obj then keep = false end
            if filter.kind ~= nil and e.kind ~= filter.kind then keep = false end
            if filter.role ~= nil and e.role ~= filter.role then keep = false end
            if filter.tag ~= nil and e.tag ~= filter.tag then keep = false end
            if filter.armed ~= nil and e.armed ~= filter.armed then keep = false end
            if filter.alive == true and e.dead then keep = false end
            if filter.dead == true and not e.dead then keep = false end
        end
        if keep then
            out[#out + 1] = {
                netId = netId,
                entity = e.entity,
                kind = e.kind,
                obj = e.obj,
                role = e.role,
                armed = e.armed,
                dead = e.dead,
                deadAt = e.deadAt,
                tag = e.tag,
            }
        end
    end
    table.sort(out, function(a, b) return a.netId < b.netId end)
    return out
end

function Runs.entityDied(run, netId, killerSrc)
    netId = math.tointeger(tonumber(netId) or -1)
    if type(run) ~= 'table' or not netId then return end
    local e = run.entities[netId]
    if not e or e.dead then return end
    e.dead = true
    e.deadAt = os.time()
    run.stats.entitiesDied = (run.stats.entitiesDied or 0) + 1
    if e.kind == 'ped' then
        run.stats.npcDeaths = (run.stats.npcDeaths or 0) + 1
        local k = ToSrc(killerSrc)
        if k and run.participants[k] then
            run.stats.kills = run.stats.kills or {}
            run.stats.kills[k] = (run.stats.kills[k] or 0) + 1
        end
        if e.entity and DoesEntityExist(e.entity) then e.lastCoords = GetEntityCoords(e.entity) end
        if run.holdBodies then HoldBody(run, netId) end
    elseif e.kind == 'vehicle' then
        run.stats.vehiclesWrecked = (run.stats.vehiclesWrecked or 0) + 1
    end
    CP.log(TAG, 'run %s: %s %d died (killer %s)', run.id, e.kind, netId, tostring(killerSrc))
    if run.state == 'in_progress' and e.obj and run.objectives[e.obj] then
        CallBlock(run, e.obj, 'onEntityDead', netId, ToSrc(killerSrc))
    end
end

-- Server-side health comes from the owner's sync data: a server-created entity reads 0 until a client has
-- created and synced it. A health of 0 therefore only counts after a positive value was seen once.
local function HealthGone(e)
    local h = GetEntityHealth and tonumber(GetEntityHealth(e.entity)) or nil
    if not h then return false end
    if h > 0 then
        e.healthSeen = true
        return false
    end
    return e.healthSeen == true
end

local function VehicleWrecked(e)
    if GetVehicleEngineHealth and (tonumber(GetVehicleEngineHealth(e.entity)) or 0) <= -3999.0 then return true end
    return HealthGone(e)
end

local function DeleteAllEntities(run)
    for netId, e in pairs(run.entities) do
        run.entities[netId] = nil
        if e.entity and DoesEntityExist(e.entity) then DeleteEntity(e.entity) end
    end
    run.held = nil
end

-- The last server-side health sample of a run vehicle (each tick while it exists).
local function SampleHealth(e)
    local engine = GetVehicleEngineHealth and tonumber(GetVehicleEngineHealth(e.entity)) or nil
    local body = GetVehicleBodyHealth and tonumber(GetVehicleBodyHealth(e.entity)) or nil
    e.lastHealth = { engine = engine or 1000.0, body = body or 1000.0 }
end

-- A vanished run vehicle whose last sample was healthy was removed (deleted by a script or sc-police's /imp),
-- not wrecked: only a last sample at 0 health (or below) counts as wrecked, as before.
local function RemovedNotWrecked(e)
    local h = e.lastHealth
    if not h then return true end
    return h.engine > 0 and h.body > 0
end

-- sc-police's police:server:Impound (modules/integrations/sc_police) or any other recorded removal of a run
-- vehicle: remembered REMOVAL_KEEP_S so the vanished car can be matched to who removed it.
function Runs.noteExternalRemoval(netId, src, via, dist)
    netId = math.tointeger(tonumber(netId) or -1)
    if not netId or netId <= 0 then return false end
    removals[netId] = {
        src = ToSrc(src),
        via = type(via) == 'string' and via or 'unknown',
        dist = tonumber(dist),
        at = os.time(),
    }
    return true
end

local function TakeRemoval(netId)
    local r = removals[netId]
    removals[netId] = nil
    if r and os.time() - r.at <= REMOVAL_KEEP_S then return r end
    return nil
end

local function AuditRemoval(run, netId, src, via)
    local who = 'unknown'
    if src then
        local ok, info = Call('Qbx', 'getInfo', src)
        who = ok and type(info) == 'table' and info.citizenid or ('player:%d'):format(src)
    end
    CP.warn(TAG, 'run %s: vehicle %d was removed by %s (%s); the run ends as not counted', run.id, netId, who, via)
    if Has('Admin', 'audit') then
        Call('Admin', 'audit', src or 'console', nil, 'audit', 'vehicleRemoved', run.id, tostring(netId), via, who)
    end
end

-- A run vehicle that vanished with a healthy last sample. A participant's recorded removal fails the mission
-- and flags the run (sc_impound); anyone else's, or nothing recorded, ends the run as not counted.
local function VehicleRemoved(run, netId, e)
    local r = TakeRemoval(netId)
    local src = r and r.src or nil
    local via = r and r.via or 'unknown'
    run.removedVehicles = run.removedVehicles or {}
    run.removedVehicles[netId] = { src = src, via = via }
    local participant = src and via ~= 'unknown' and Runs.isParticipant(run, src)
    if participant then
        local detail = ('vehicle %d removed by %s (%s)'):format(netId, tostring(src), via)
        if Has('AntiCheat', 'flag') then
            Call('AntiCheat', 'flag', run, src, 'sc_impound', detail)
        elseif not run.flagged then
            run.flagged = { reason = 'sc_impound', detail = detail }
        end
    end
    if e.obj and run.objectives[e.obj] and run.objectives[e.obj].prepared then
        CallBlock(run, e.obj, 'onEvent', src, { type = 'removed', netId = netId, src = src, via = via })
    end
    if run.state ~= 'in_progress' then return end
    if participant then
        Runs.failRun(run, 'reason.vehicle_removed')
        return
    end
    AuditRemoval(run, netId, src, via)
    for _, s in ipairs(Runs.activeSrcs(run)) do
        Runs.removeParticipant(run, s, 'vehicle_removed_external', { notify = 'run.vehicle_removed_external' })
        if run.state == 'ended' then return end
    end
end

local function EntityBookkeeping(run)
    local died, gone, cleanup = {}, {}, {}
    local now = os.time()
    local pedDeathsByNpc = Has('Npc', 'onDeath')
    for netId, e in pairs(run.entities) do
        if not e.entity or not DoesEntityExist(e.entity) then
            e.missing = (e.missing or 0) + 1
            if e.missing >= MISSING_TICKS then gone[#gone + 1] = netId end
        else
            e.missing = 0
            if not e.dead then
                if e.kind == 'vehicle' then SampleHealth(e) end
                if e.kind == 'vehicle' and VehicleWrecked(e) then
                    died[#died + 1] = netId
                elseif e.kind == 'ped' and not pedDeathsByNpc and HealthGone(e) then
                    died[#died + 1] = netId
                end
            elseif e.deadAt and not e.held and now - e.deadAt >= CorpseCleanup() then
                cleanup[#cleanup + 1] = netId
            end
        end
    end
    for _, netId in ipairs(died) do Runs.entityDied(run, netId, nil) end
    for _, netId in ipairs(gone) do
        local e = run.entities[netId]
        if e then
            local removed = false
            if not e.dead then
                if e.kind == 'vehicle' and RemovedNotWrecked(e) then
                    removed = true
                else
                    CP.log(TAG, 'run %s: %s %d vanished; counted as dead', run.id, e.kind, netId)
                    Runs.entityDied(run, netId, nil)
                end
            end
            run.entities[netId] = nil
            if run.held then
                for i, h in ipairs(run.held) do
                    if h == netId then
                        table.remove(run.held, i)
                        break
                    end
                end
            end
            if removed then
                CP.log(TAG, 'run %s: vehicle %d vanished with a healthy last sample: removed', run.id, netId)
                VehicleRemoved(run, netId, e)
                if run.state ~= 'in_progress' then return end
            end
        end
    end
    for _, netId in ipairs(cleanup) do Runs.deleteEntity(run, netId) end
end

-- ============================================================================
--              ITEMS (ox_inventory; docs/CRIMSON_ARENA.md rule 4)
-- ============================================================================

local function InventoryUp()
    return GetResourceState('ox_inventory') == 'started'
end

local function InArena(src)
    local ok, res = Call('Alerts', 'inArena', src)
    return ok and res == true
end

local function AddOrphan(citizenid, name)
    if not citizenid or not name then return end
    local o = orphans[citizenid]
    if not o then
        o = { names = {}, at = os.time(), sweptAt = 0 }
        orphans[citizenid] = o
    end
    o.names[name] = true
end

local function GiveItems(run, p)
    local items = run.mission.items
    if type(items) ~= 'table' or #items == 0 then return end
    if not InventoryUp() then
        WarnOnce('inv_give', 'ox_inventory is not started: mission items are not given')
        return
    end
    if InArena(p.src) then return end
    for _, it in ipairs(items) do
        local name = type(it) == 'table' and it.name or nil
        local count = math.max(1, math.floor(Num(type(it) == 'table' and it.count, 1)))
        if type(name) == 'string' and name ~= '' then
            local ok, success, response = pcall(function()
                return exports.ox_inventory:AddItem(p.src, name, count, { cpRun = run.id, cpItem = true })
            end)
            if ok and success then
                p.items[#p.items + 1] = { name = name, count = count }
            else
                CP.warn(TAG, 'could not give %dx %s to %d for run %s: %s', count, name, p.src, run.id,
                    tostring(ok and response or success))
            end
        end
    end
end

local function SlotList(result, name)
    if type(result) ~= 'table' then return {} end
    if result[1] ~= nil then return result end
    if type(result[name]) == 'table' then return result[name] end
    return {}
end

-- Remove every slot of `name` whose metadata matches `meta` (and passes keep()). Returns the count removed.
local function RemoveSlots(src, name, meta, skip)
    local ok, result = pcall(function() return exports.ox_inventory:Search(src, 'slots', name, meta) end)
    if not ok then
        CP.warn(TAG, 'ox_inventory Search failed for %d: %s', src, tostring(result))
        return 0, false
    end
    local removed = 0
    for _, slot in ipairs(SlotList(result, name)) do
        if type(slot) == 'table' and slot.slot and not (skip and skip(slot)) then
            local count = math.floor(Num(slot.count, 1))
            local okRm, success = pcall(function()
                return exports.ox_inventory:RemoveItem(src, name, count, nil, slot.slot)
            end)
            if okRm and success then removed = removed + count end
        end
    end
    return removed, true
end

local function RemoveItems(run, p)
    if not p.items or #p.items == 0 then return end
    local items = p.items
    p.items = {}
    local online = PlayerOnline(p.src) and InventoryUp() and not InArena(p.src)
    for _, it in ipairs(items) do
        local removed = 0
        if online then removed = RemoveSlots(p.src, it.name, { cpRun = run.id }) end
        if removed < it.count then
            AddOrphan(p.citizenid, it.name)
            CP.log(TAG, 'run %s: %s of %dx %s not found on %s; kept for a later sweep', run.id, it.count - removed,
                it.count, it.name, tostring(p.citizenid))
        end
    end
end

local function MissionItemNames()
    local names = {}
    local ok, defs = Call('Missions', 'all')
    if ok and type(defs) == 'table' then
        for _, def in pairs(defs) do
            for _, it in ipairs(type(def.items) == 'table' and def.items or {}) do
                if type(it) == 'table' and type(it.name) == 'string' then names[it.name] = true end
            end
        end
    end
    return names
end

-- Remove Crimson-Police mission items (metadata.cpItem) of every run the player is not active in.
local function SweepPlayer(src, citizenid)
    if not PlayerOnline(src) or not InventoryUp() or InArena(src) then return false end
    local names = MissionItemNames()
    local o = citizenid and orphans[citizenid]
    if o then for n in pairs(o.names) do names[n] = true end end
    local complete = true
    for name in pairs(names) do
        local _, ok = RemoveSlots(src, name, { cpItem = true }, function(slot)
            local meta = slot.metadata
            local run = type(meta) == 'table' and meta.cpRun ~= nil and runs[meta.cpRun] or nil
            local keep = run ~= nil and Runs.isParticipant(run, src)
            if keep then complete = false end
            return keep
        end)
        if not ok then complete = false end
    end
    if o then
        o.sweptAt = os.time()
        if complete then orphans[citizenid] = nil end
    end
    return complete
end

-- Mission items stay with the participant they were given to (Hard rule 14, Hard rule 19): an ox_inventory
-- swapItems hook refuses every move of a cpItem out of its holder's own inventory (give to a player, drop,
-- stash, glovebox, trunk). Moves inside the holder's inventory are allowed. Server-side exports (our own
-- removal, Crimson-Arena's stash) do not go through swapItems.
local function IsMissionItem(slot)
    return type(slot) == 'table' and type(slot.metadata) == 'table' and slot.metadata.cpItem == true
end

function Runs._swapItemsHook(payload)
    if type(payload) ~= 'table' then return true end
    local from, to = payload.fromInventory, payload.toInventory
    local leaves = payload.action == 'give' or from ~= to or payload.fromType ~= payload.toType
    if not leaves then return true end
    if IsMissionItem(payload.fromSlot) then return false end
    -- a swap sends the item in the target slot the other way
    if payload.action == 'swap' and IsMissionItem(payload.toSlot) then return false end
    return true
end

local itemHookId = nil
local function RegisterItemHook()
    if itemHookId ~= nil then return true end
    if not InventoryUp() then return false end
    local ok, id = pcall(function()
        return exports.ox_inventory:registerHook('swapItems', function(payload)
            local okH, allowed = pcall(Runs._swapItemsHook, payload)
            if not okH then return true end
            return allowed
        end, {})
    end)
    if not ok then
        WarnOnce('inv_hook', 'could not register the ox_inventory swapItems hook: %s', tostring(id))
        return false
    end
    itemHookId = id or true
    return true
end

local function CitizenOf(src)
    local ok, info = Call('Qbx', 'getInfo', src)
    return ok and type(info) == 'table' and info.citizenid or nil
end

-- ============================================================================
--                                  COOLDOWNS
-- ============================================================================

local function CdEntry(citizenid)
    local c = cooldownCache[citizenid]
    if not c then
        c = { types = {}, missions = {}, loaded = false }
        cooldownCache[citizenid] = c
    end
    return c
end

local function MissionCooldownOf(missionId)
    local ok, def = Call('Missions', 'get', missionId)
    if ok and type(def) == 'table' then return Num(def.cooldown, 0) end
    return 0
end

local function RebuildWindow()
    local window = AbandonCooldown()
    local ok, defs = Call('Missions', 'all')
    if ok and type(defs) == 'table' then
        for _, def in pairs(defs) do
            local c = Num(def.cooldown, 0)
            if c > window then window = c end
        end
    end
    return math.max(60, math.floor(window))
end

local function LoadCooldowns(citizenid)
    local c = CdEntry(citizenid)
    if c.loaded then return c end
    if c.loading then
        -- Another caller is rebuilding right now: wait for it instead of answering from a half-built cache.
        local deadline = GetGameTimer() + COOLDOWN_LOAD_WAIT_MS
        while c.loading and GetGameTimer() < deadline do Wait(50) end
        return c
    end
    c.loading = true
    Db()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT mission_type, mission_id, end_reason, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_mission_runs
        WHERE citizenid = ? AND created_at >= NOW() - INTERVAL ? SECOND
          AND mission_type NOT IN ('manual_award', 'goal')
    ]], { citizenid, RebuildWindow() })
    c.loading = false
    if not ok then
        CP.err(TAG, 'cooldown rebuild for %s failed: %s', tostring(citizenid), tostring(rows))
        return c
    end
    c.loaded = true
    for _, row in ipairs(rows or {}) do
        local ts = U.num(row.created_ts)
        local reason = row.end_reason
        if MISSION_COOLDOWN[reason] then
            local untilTs = ts + MissionCooldownOf(row.mission_id)
            if untilTs > (c.missions[row.mission_id] or 0) then c.missions[row.mission_id] = untilTs end
        end
        if TYPE_COOLDOWN[reason] and row.mission_id ~= BOSS_ID then
            local untilTs = ts + AbandonCooldown()
            if untilTs > (c.types[row.mission_type] or 0) then c.types[row.mission_type] = untilTs end
        end
    end
    CP.log(TAG, 'cooldowns of %s rebuilt from %d row(s)', tostring(citizenid), #(rows or {}))
    return c
end

function Runs.cooldowns(citizenid)
    local out = { types = {}, missions = {} }
    if type(citizenid) ~= 'string' or citizenid == '' then return out end
    local c = LoadCooldowns(citizenid)
    local now = os.time()
    for k, v in pairs(c.types) do
        if v > now then out.types[k] = v else c.types[k] = nil end
    end
    for k, v in pairs(c.missions) do
        if v > now then out.missions[k] = v else c.missions[k] = nil end
    end
    return out
end

function Runs.onCooldown(citizenid, missionType, missionId)
    local cd = Runs.cooldowns(citizenid)
    local untilTs = nil
    local t = missionType and cd.types[missionType]
    local m = missionId and cd.missions[missionId]
    if t then untilTs = t end
    if m and (not untilTs or m > untilTs) then untilTs = m end
    return untilTs ~= nil, untilTs
end

local function ApplyCooldowns(run, p, endReason)
    if run.test or not p.citizenid then return end
    local c = CdEntry(p.citizenid)
    local now = os.time()
    if MISSION_COOLDOWN[endReason] then
        local secs = Num(run.mission.cooldown, 0)
        if secs > 0 then
            local untilTs = now + math.floor(secs)
            if untilTs > (c.missions[run.missionId] or 0) then c.missions[run.missionId] = untilTs end
        end
    end
    if TYPE_COOLDOWN[endReason] and not run.isBoss then
        local untilTs = now + math.floor(AbandonCooldown())
        if untilTs > (c.types[run.missionType] or 0) then c.types[run.missionType] = untilTs end
    end
end

function Runs.completionsLastHour(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    local cached = hourCache[citizenid]
    local now = os.time()
    if cached and now - cached.at < HOURLY_CACHE_S then return cached.n end
    Db()
    local ok, n = pcall(MySQL.scalar.await, [[
        SELECT COUNT(*) AS n FROM cp_mission_runs
        WHERE citizenid = ? AND state = 'completed' AND mission_type NOT IN ('manual_award', 'goal')
          AND created_at >= NOW() - INTERVAL 3600 SECOND
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'completionsLastHour(%s) failed: %s', citizenid, tostring(n))
        return cached and cached.n or 0
    end
    local count = math.floor(U.num(n))
    hourCache[citizenid] = { n = count, at = now }
    return count
end

local function DayStart()
    local ok, ts = Call('Schedule', 'dayStart', os.time())
    if ok and tonumber(ts) then return math.floor(tonumber(ts)) end
    local t = os.date('*t')
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
end

-- Completed runs since the daily reset (Config.Limits.maxCompletionsDay, Config.MissionTypes dailyLimit):
-- no manual awards, goal rows or Cross-Department Missions. Cached DAY_CACHE_S; cleared on a completion.
function Runs.completionsToday(citizenid, missionType)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    local key = citizenid .. '|' .. tostring(missionType or '*')
    local cached = dayCache[key]
    local now = os.time()
    if cached and now - cached.at < DAY_CACHE_S then return cached.n end
    Db()
    local sql = [[
        SELECT COUNT(*) AS n FROM cp_mission_runs
        WHERE citizenid = ? AND state = 'completed' AND mission_type NOT IN ('manual_award', 'goal')
          AND operation_id IS NULL AND created_at >= FROM_UNIXTIME(?)
    ]]
    local params = { citizenid, DayStart() }
    if type(missionType) == 'string' then
        sql = sql .. ' AND mission_type = ?'
        params[#params + 1] = missionType
    end
    local ok, n = pcall(MySQL.scalar.await, sql, params)
    if not ok then
        CP.err(TAG, 'completionsToday(%s) failed: %s', citizenid, tostring(n))
        return cached and cached.n or 0
    end
    local count = math.floor(U.num(n))
    dayCache[key] = { n = count, at = now }
    return count
end

local function ClearDayCache(citizenid)
    local prefix = citizenid .. '|'
    for k in pairs(dayCache) do
        if k:sub(1, #prefix) == prefix then dayCache[k] = nil end
    end
end

-- ============================================================================
--                                     CAPS
-- ============================================================================

function Runs.capsOk(missionType)
    local total, tactical = 0, 0
    for _, run in pairs(runs) do
        if run.state ~= 'ended' and not run.test and not run.operationId then
            total = total + 1
            if run.missionType == 'tactical' then tactical = tactical + 1 end
        end
    end
    if total >= Num(limits().maxConcurrentRuns, 12) then return false, 'err.server_busy' end
    local isTactical = missionType == 'tactical' or missionType == 'weekly_boss'
    if isTactical and tactical >= Num(limits().maxConcurrentTactical, 4) then return false, 'err.server_busy' end
    return true
end

-- ============================================================================
--                          SCORING, CASH AND THE ROW
-- ============================================================================

local function ObjectivesProgress(run)
    local total = #(run.mission.objectives or {})
    local done = 0
    for i = 1, total do
        local o = run.objectives[i]
        if o and o.status == 'done' then done = done + 1 end
    end
    return done, total
end

local function ComputePoints(run, p, result, opts)
    local ok, bd = Call('Scoring', 'compute', run, p, result, opts)
    if not ok or type(bd) ~= 'table' then
        if not Has('Scoring', 'compute') then
            WarnOnce('scoring', 'CP.Scoring.compute is not available: rows get 0 points')
        end
        bd = {
            P = run.pointsBase or 0,
            bonuses = {},
            penalties = {},
            subtotal = 0,
            mTeam = 1.0,
            mCross = 1.0,
            mStreak = 1.0,
            capped = false,
            tod = false,
            failedShare = opts.failedShare,
            final = 0,
        }
    end
    if type(bd.bonuses) ~= 'table' then bd.bonuses = {} end
    if type(bd.penalties) ~= 'table' then bd.penalties = {} end
    bd.P = Num(bd.P, run.pointsBase or 0)
    local final = math.floor(Num(bd.final, 0))
    if final < 0 or result == 'abandoned' then final = 0 end
    bd.final = final
    return bd
end

local function ComputeCash(run, p, result)
    local ok, amount, cb = Call('Cash', 'compute', run, p)
    local payTier = run.payTier or TierByName(run.expectedTier)
    if not ok then
        if not Has('Cash', 'compute') then WarnOnce('cash', 'CP.Cash.compute is not available: rows pay $0') end
        amount, cb = 0, nil
    end
    if type(cb) ~= 'table' then
        cb = {
            B = run.cashBase or 0,
            mTier = payTier and Num(payTier.cash, 1.0) or 1.0,
            mMod = run.modifier and Num(Config.Events and Config.Events.modifierCash, 1.0) or 1.0,
        }
    end
    local amt = U.round(Num(cb.amount, Num(amount, 0)))
    if result ~= 'completed' or amt < 0 then amt = 0 end
    cb.amount = amt
    cb.B = Num(cb.B, run.cashBase or 0)
    cb.mTier = Num(cb.mTier, 1.0)
    cb.mMod = Num(cb.mMod, 1.0)
    return amt, cb
end

local function SumPoints(list, abs)
    local s = 0
    for _, e in ipairs(list or {}) do
        local v = Num(type(e) == 'table' and e.points, 0)
        if abs then v = math.abs(v) end
        s = s + v
    end
    return U.round(s)
end

local function DepartmentAtEnd(p)
    local ok, info = Call('Qbx', 'getInfo', p.src)
    if ok and type(info) == 'table' and info.citizenid == p.citizenid and type(info.job) == 'table' then
        local okD, dept = Call('Access', 'departmentForJob', info.job.name)
        if okD and dept then return dept end
    end
    return p.department
end

local INSERT_COLUMNS = {
    'run_uuid',
    'operation_id',
    'mission_type',
    'mission_id',
    'mission_version',
    'location_label',
    'citizenid',
    'department',
    'season_id',
    'participants',
    'departments_n',
    'tier',
    'modifier',
    'state',
    'end_reason',
    'points_base',
    'bonus_points',
    'penalty_points',
    'final_points',
    'cash_base',
    'cash_multiplier',
    'cash_paid',
    'cash_status',
    'duration_s',
    'breakdown',
    'flagged',
    'flag_reason',
    'location_index',
    'arrests',
    'citations',
    'impounds',
    'rescues',
    'vehicles_stopped',
    'evidence',
    'decisions_ok',
    'decisions_bad',
    'decisions_best',
    'lethal',
    'medal',
    'mission_call_id',
    'response_s',
}

-- NULL literals for nil values so the parameter list never has holes.
local function InsertRow(row)
    Db()
    local values, params = {}, {}
    for i, col in ipairs(INSERT_COLUMNS) do
        local v = row[col]
        if v == nil then
            values[i] = 'NULL'
        else
            values[i] = '?'
            params[#params + 1] = v
        end
    end
    local sql = ('INSERT INTO cp_mission_runs (%s) VALUES (%s)'):format(table.concat(INSERT_COLUMNS, ', '),
        table.concat(values, ', '))
    local ok, id = pcall(MySQL.insert.await, sql, params)
    if not ok then
        CP.err(TAG, 'row insert failed for %s (run %s): %s', tostring(row.citizenid), tostring(row.run_uuid),
            tostring(id))
        return nil
    end
    return tonumber(id)
end

-- The participant's service-record counts for the row and RunResult.stats (every key, 0 when none).
local function StatsOf(run, p)
    local out = {}
    for _, k in ipairs(STAT_KEYS) do out[k] = math.floor(Num(p.stats and p.stats[k], 0)) end
    local kills = run.stats and run.stats.kills and Num(run.stats.kills[p.src], 0) or 0
    if kills > out.lethal then out.lethal = math.floor(kills) end
    return out
end

-- 1 gold, 2 silver, 3 bronze (the checkpoint_route medal awards), or nil.
local function MedalOf(run, p)
    local best = nil
    for id, n in pairs(MEDALS) do
        local count = Num(run.score and run.score.shared[id], 0) + Num(p.score and p.score[id], 0)
        if count > 0 and (not best or n < best) then best = n end
    end
    return best
end

-- The decision ledger as RunResult.decisions (DecisionEntry, web/src/types/run_ui.ts).
local function DecisionsView(run)
    local out = {}
    for _, d in ipairs(run.decisions or {}) do
        out[#out + 1] = {
            contact = d.contact,
            kind = d.kind,
            choice = d.choice,
            best = d.best,
            verdict = d.verdict,
            by = d.by,
            truth = d.truth,
            facts = U.copy(d.facts or {}),
            points = d.points,
            discoverable = d.discoverable,
            knownAtS = d.knownAtS,
        }
    end
    return out
end

local function ResponseS(run, p)
    if not run.missionCall or not p.arrivedAt then return nil end
    return math.max(0, math.floor(p.arrivedAt - (run.acceptedAt or p.arrivedAt)))
end

local function MissionCallView(run, p)
    local mc = run.missionCall
    if not mc then return nil end
    local responseS = ResponseS(run, p)
    return {
        code = mc.code,
        responseS = responseS,
        targetS = mc.targetS,
        rapid = (p.score and Num(p.score.rapid_response, 0) > 0) or false,
    }
end

local function ReadCashStatus(rowId)
    local ok, row = pcall(MySQL.single.await, 'SELECT cash_status, cash_paid FROM cp_mission_runs WHERE id = ?',
        { rowId })
    if ok and type(row) == 'table' then return row.cash_status, math.floor(U.num(row.cash_paid)) end
    return nil
end

local function StoreCashStatus(rowId, status)
    pcall(MySQL.update.await,
        'UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, \'$.cash.status\', ?) WHERE id = ? AND breakdown IS NOT NULL',
        { status, rowId })
end

-- Work out one participant's result (RunResult §9.6), write the row, pay, fire the hooks.
-- others = srcs still active at this moment (excluding p). Returns rowId|nil, runResult.
local function Settle(run, p, result, endReason, others)
    p.result, p.endReason = result, endReason
    local team = #others + 1
    local nDepts = 0
    do
        local seen = {}
        for _, s in ipairs(others) do
            local q = run.participants[s]
            if q and q.department and not seen[q.department] then seen[q.department] = true; nDepts = nDepts + 1 end
        end
        if p.department and not seen[p.department] then nDepts = nDepts + 1 end
        if nDepts < 1 then nDepts = 1 end
    end
    local done, total = ObjectivesProgress(run)
    local endTs = run.endedAt or os.time()
    local duration = run.startedAt and math.max(0, endTs - run.startedAt) or 0
    local opts = {
        objectivesDone = done,
        objectivesTotal = total,
        failedShare = result == 'failed' and (total > 0 and done / total or 0) or nil,
        durationS = duration,
        participants = team,
        departments = nDepts,
        endReason = endReason,
        -- Process the scene stopped the fast-completion clock (pauseFastClock)
        fastDurationS = run.fastClockAt and run.startedAt and math.max(0, run.fastClockAt - run.startedAt) or nil,
    }
    local points = ComputePoints(run, p, result, opts)

    if (result == 'completed' or result == 'failed') and #run.order >= 2 and Has('AntiCheat', 'presenceOk') then
        local ok, present = Call('AntiCheat', 'presenceOk', run, p)
        if ok and present == false and not p.flagged then
            -- Through CP.AntiCheat.flag so the flag is audited and posted like every other one (the Review
            -- Queue reads its detail there); the local record is the fallback and the test-run preview.
            if not run.test and Has('AntiCheat', 'flag') then
                local okS, share = Call('AntiCheat', 'presenceShare', p)
                local detail = ('%s in range for %s of the run (needs %d%%)'):format(tostring(p.name or p.citizenid),
                    (okS and tonumber(share)) and ('%d%%'):format(math.floor(tonumber(share) * 100 + 0.5)) or '?',
                    math.floor(Num(Config.AntiCheat and Config.AntiCheat.presenceShare, 0.70) * 100 + 0.5))
                Call('AntiCheat', 'flag', run, p.src, 'presence', detail)
            end
            if not p.flagged then p.flagged = { reason = 'presence' } end
        end
    end

    local amount, cash = ComputeCash(run, p, result)
    local flag = p.flagged or run.flagged
    local isTest = run.test ~= nil
    local status = 'none'
    if not isTest and flag and result == 'completed' then status = 'held' end
    cash.status = status

    local payTier = run.payTier or TierByName(run.expectedTier)
    local rr = {
        runId = run.id,
        missionLabel = run.mission.label,
        missionType = run.missionType,
        result = result,
        endReason = endReason,
        test = isTest,
        tier = TierName(run.tier) or run.expectedTier,
        payTier = TierName(payTier) or run.expectedTier,
        participants = team,
        departments = nDepts,
        durationS = duration,
        points = points,
        cash = cash,
        flagged = flag and { reason = tostring(flag.reason or 'flagged') } or nil,
        failReason = (endReason == 'mission_failed' and run.failReason) or nil,
        decisions = DecisionsView(run),
        stats = StatsOf(run, p),
        missionCall = MissionCallView(run, p),
        progress = nil,
        items = {},
    }
    rr.stats.lethal = nil   -- private: the officer's own clean-arrest rate only, never on the result screen
    if isTest then return nil, rr end

    local seasonId = nil
    local okS, season = Call('Challenge', 'currentSeason')
    if okS and type(season) == 'table' then seasonId = tonumber(season.id) end

    local okJ, breakdownJson = pcall(json.encode, U.serialize(rr))
    local row = {
        run_uuid = run.id,
        operation_id = tonumber(run.operationId),
        mission_type = U.clip(run.missionType, 32),
        mission_id = U.clip(run.missionId, 40),
        mission_version = tonumber(run.version) and Int(run.version, -32768, 32767) or nil,
        location_label = U.clip(run.location and run.location.label or nil, 64),
        citizenid = U.clip(p.citizenid, 50),
        department = U.clip(DepartmentAtEnd(p) or 'unknown', 32),
        season_id = seasonId,
        participants = Int(team, 1, 127),
        departments_n = Int(nDepts, 1, 127),
        tier = TierName(payTier) or 'standard',
        modifier = U.clip(run.modifier, 20),
        state = result,
        end_reason = U.clip(endReason, 24),
        points_base = Int(points.P, -32768, 32767),
        bonus_points = Int(SumPoints(points.bonuses, false), -32768, 32767),
        penalty_points = Int(SumPoints(points.penalties, true), -32768, 32767),
        final_points = Int(points.final, 0, 32767),
        cash_base = Int(cash.B, 0, 2147483647),
        cash_multiplier = math.floor(U.clamp(cash.mTier * cash.mMod, 0, 99.99) * 100 + 0.5) / 100,
        cash_paid = 0,
        cash_status = status,
        duration_s = Int(duration, 0, 32767),
        breakdown = okJ and breakdownJson or nil,
        flagged = flag and 1 or 0,
        flag_reason = flag and U.clip(tostring(flag.reason or 'flagged'), 64) or nil,
        location_index = run.locationIndex and Int(run.locationIndex, -128, 127) or nil,
        medal = MedalOf(run, p),
        mission_call_id = run.missionCall and tonumber(run.missionCall.id) and math.floor(tonumber(run.missionCall.id))
            or nil,
        response_s = ResponseS(run, p) and Int(ResponseS(run, p), 0, 32767) or nil,
    }
    local stats = StatsOf(run, p)
    for _, k in ipairs(STAT_KEYS) do row[k] = Int(stats[k], 0, 32767) end
    local rowId = InsertRow(row)
    p.rowId = rowId
    if not rowId then return nil, rr end
    row.id = rowId
    if result == 'completed' then
        hourCache[p.citizenid] = nil
        ClearDayCache(p.citizenid)
    end

    if result == 'completed' and not flag and amount > 0 and Has('Cash', 'pay') then
        Call('Cash', 'pay', rowId)
        local st, paid = ReadCashStatus(rowId)
        if st then
            cash.status = st
            cash.paid = paid
            row.cash_status, row.cash_paid = st, paid
            if st ~= status then StoreCashStatus(rowId, st) end
        end
    end
    if (result == 'completed' or result == 'failed') and not flag then
        Call('Scoring', 'onRowCounted', p.citizenid, row)
        if result == 'completed' then Call('Goals', 'onRunCompleted', p.citizenid) end
    end
    if result == 'completed' or result == 'abandoned' then
        Call('Draw', 'recordLast', p.citizenid, run.missionType, run.missionId)
    end
    -- listeners may add to rr (CP.Scoring the progress, CP.Rewards the items); they may yield
    Fire('row:settled', run, p, rowId, row, rr)
    return rowId, rr
end

-- ============================================================================
--                              LIFECYCLE HELPERS
-- ============================================================================

local function Responsive(src)
    if not PlayerOnline(src) then return false end
    if GetPlayerLastMsg then return Num(GetPlayerLastMsg(src), 0) <= HOST_STALE_MS end
    return true
end

-- Host succession follows the join order. needFresh: only hand over to a responsive participant.
local function MigrateHost(run, reason, needFresh)
    local current = run.host
    local candidates = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if p and p.status == 'active' and src ~= current then candidates[#candidates + 1] = src end
    end
    local stillOk = current and run.participants[current] and run.participants[current].status == 'active'
    local pick = nil
    for _, src in ipairs(candidates) do
        if Responsive(src) then pick = src; break end
    end
    if not pick then
        if stillOk or needFresh then return false end
        pick = candidates[1]
    end
    if not pick or pick == current then return false end
    run.host = pick
    CP.log(TAG, 'run %s: host %s -> %s (%s)', run.id, tostring(current), tostring(pick), tostring(reason))
    Runs.send(run, 'client:hostChanged', run.id, pick)
    return true
end

local function StopObjectives(run)
    for i = 1, #(run.mission.objectives or {}) do
        local o = run.objectives[i]
        if o and o.prepared and not o.stopped then
            o.stopped = true
            CallBlock(run, i, 'stop')
        end
    end
end

-- Only a normal run locked a unit (CP.Draw's accept): test and operation runs never unlock one (an
-- operation's first joiner may be in a unit that is locked for another run; docs/notes/teams.md).
local function UnlockUnit(run)
    if run.test or run.operationId or not run.unit then return end
    Call('Units', 'unlock', run.unit)
end

-- Delete everything the run owns (entities, reservation) and forget it. Participants still active
-- are handled by the caller.
local function CleanupRun(run)
    StopObjectives(run)
    DeleteAllEntities(run)
    Call('Draw', 'release', run.id)
    runs[run.id] = nil
    ctxCache[run.id] = nil
    endedRuns[run.id] = { at = os.time(), run = run }
end

local function AfterRunEnded(run, state)
    Fire('run:ended', run, state, run.endReason)
    UnlockUnit(run)
    if run.operationId then Call('Operations', 'onRunEnded', run, state) end
    if run.test then Call('Testing', 'onRunEnded', run, state, run.endReason) end
    if not run.test then Call('Leaderboard', 'invalidate') end
end

-- Rescale for the team that is left: tier (counts) and pay tier can only go down.
local function rescale(run, endReason)
    if run.state ~= 'in_progress' then
        if run.state == 'accepted' and not ForcedTier(run) then
            local n = #Runs.activeSrcs(run)
            local old = run.expectedTier
            if n > 0 then run.expectedTier = TierName(TierFor(n)) or run.expectedTier end
            if run.expectedTier ~= old then
                Runs.send(run, 'client:tierChanged', run.id, run.expectedTier, run.expectedTier)
            end
        end
        return
    end
    if ForcedTier(run) then return end
    local n = #Runs.activeSrcs(run)
    if n <= 0 then return end
    local newTier = TierFor(n)
    local rescaleCfg = Config.Rescale or {}
    local oldTier, oldPay = run.tier, run.payTier
    if rescaleCfg.enabled ~= false then run.tier = LowerTier(run.tier, newTier) end
    local keep = U.contains(rescaleCfg.keepPayTierFor or {}, endReason)
    if not keep then run.payTier = LowerTier(run.payTier, newTier) end
    local tierChanged = TierName(oldTier) ~= TierName(run.tier)
    local payChanged = TierName(oldPay) ~= TierName(run.payTier)
    if tierChanged then
        local scaled
        if CP.Scaling and CP.Scaling.apply then
            local ok, list = pcall(CP.Scaling.apply, run.mission, run.tier)
            if ok and type(list) == 'table' then scaled = list end
        end
        scaled = scaled or U.deepcopy(run.mission.objectives)
        for i = 1, #(run.mission.objectives or {}) do
            local o = run.objectives[i]
            if o and o.status ~= 'done' and scaled[i] then
                o.obj = scaled[i]
                CallBlock(run, i, 'rescale')
                if run.state == 'ended' then return end
            end
        end
        run.scaled = scaled
    end
    if tierChanged or payChanged then
        CP.log(TAG, 'run %s: tier %s -> %s, pay tier %s -> %s (%s)', run.id, tostring(TierName(oldTier)),
            tostring(TierName(run.tier)), tostring(TierName(oldPay)), tostring(TierName(run.payTier)), endReason)
        Runs.send(run, 'client:tierChanged', run.id, TierName(run.tier), TierName(run.payTier),
            tierChanged and run.scaled or nil)
    end
end

-- ============================================================================
--                                    CREATE
-- ============================================================================

local function MemberOfficer(m)
    if type(m) == 'table' then return m end
    local src = ToSrc(m)
    if not src then return nil end
    local ok, officer = Call('Access', 'getOfficer', src)
    if ok and type(officer) == 'table' then return officer end
    local okI, info = Call('Qbx', 'getInfo', src)
    if okI and type(info) == 'table' then
        return {
            src = src,
            citizenid = info.citizenid,
            name = info.name,
            callsign = info.callsign,
            rank = info.job and info.job.gradeName,
            job = info.job and info.job.name,
        }
    end
    return nil
end

local function BaseCash(mission, missionType, isBoss)
    local ok, b = Call('Payouts', 'baseFor', mission)
    if ok and tonumber(b) then return math.max(0, math.floor(tonumber(b) + 0.5)) end
    WarnOnce('payouts', 'CP.Payouts.baseFor is not available: using the config payouts')
    if isBoss then
        return math.floor(Num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.payout, 0))
    end
    local t = Config.MissionTypes and Config.MissionTypes[missionType]
    local stars = (Config.Difficulty and Config.Difficulty.cashByStars or {})[mission.difficulty or 1] or 1.0
    return math.floor(Num(t and t.payout, 0) * stars + 0.5)
end

local function BasePoints(mission, missionType, isBoss)
    local ok, P = Call('Scoring', 'P', mission)
    if ok and tonumber(P) then return tonumber(P) end
    if isBoss then return Num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.points, 0) end
    local t = Config.MissionTypes and Config.MissionTypes[missionType]
    local stars = (Config.Difficulty and Config.Difficulty.pointsByStars or {})[mission.difficulty or 1] or 1.0
    return Num(t and t.points, 0) * stars
end

function Runs.create(opts)
    if type(opts) ~= 'table' or type(opts.mission) ~= 'table' then return nil, 'err.invalid_mission' end
    local mission = opts.mission
    if type(mission.id) ~= 'string' or type(mission.objectives) ~= 'table' or #mission.objectives == 0 then
        return nil, 'err.invalid_mission'
    end
    local locationIndex = math.tointeger(tonumber(opts.locationIndex) or -1)
    local location = locationIndex and type(mission.locations) == 'table' and mission.locations[locationIndex]
    if type(location) ~= 'table' or type(location.start) ~= 'table' or not IsVec(location.start.coords) then
        return nil, 'err.invalid_location'
    end
    if type(opts.members) ~= 'table' or #opts.members == 0 then return nil, 'err.no_members' end

    local isBoss = opts.isBoss == true or mission.isBoss == true
    local missionType = opts.missionType
    if isBoss or missionType == 'weekly_boss' then missionType = 'tactical' end
    missionType = missionType or mission.type
    local test = type(opts.test) == 'table' and U.copy(opts.test) or nil

    local officers, seen = {}, {}
    for _, m in ipairs(opts.members) do
        local o = MemberOfficer(m)
        local src = o and ToSrc(o.src)
        if not src or not o.citizenid then return nil, 'err.member_unavailable' end
        if not seen[src] then
            seen[src] = true
            if Runs.isOnMission(src) then
                return nil, (src == ToSrc(opts.leaderSrc)) and 'err.already_on_run' or 'err.member_on_run'
            end
            if InArena(src) then return nil, 'err.in_arena' end
            officers[#officers + 1] = o
        end
    end
    if not test and not opts.operationId then
        local ok, errKey = Runs.capsOk(missionType)
        if not ok then return nil, errKey end
    end

    local id = U.uuid()
    local now = os.time()
    local seed = U.hash(id .. ':' .. tostring(GetGameTimer()) .. ':' .. tostring(now)) & 0x7FFFFFFF
    if seed == 0 then seed = 1 end
    local leader = ToSrc(opts.leaderSrc)
    if not leader or not seen[leader] then leader = ToSrc(officers[1].src) end

    local run = {
        id = id,
        mission = mission,
        missionId = mission.id,
        missionType = missionType,
        isBoss = isBoss,
        version = mission.source == 'custom' and mission.version or nil,
        locationIndex = locationIndex,
        location = location,
        state = 'accepted',
        test = test,
        operationId = opts.operationId,
        seed = seed,
        host = leader,
        leader = leader,
        participants = {},
        order = {},
        expectedTier = nil,
        tier = nil,
        payTier = nil,
        modifier = nil,
        cashBase = 0,
        pointsBase = 0,
        departments = {},
        acceptedAt = now,
        startedAt = nil,
        endedAt = nil,
        timeLimit = math.floor(Num(mission.timeLimit, 600)),
        timer = { remaining = 0, paused = false, lastTick = nil, running = false },
        objectiveIndex = 1,
        objectives = {},
        shared = {},
        entities = {},
        stats = { downs = 0, weaponsFired = 0 },
        score = { shared = {}, values = {}, kinds = {} },
        flags = { medals = false },
        flagged = nil,
        reserved = { missionId = mission.id, locationIndex = locationIndex },
        startTimeout = math.floor(Num(mission.startTimeout, Num(limits().startTimeout, 600))),
        pedHits = {},
        quietPatrol = mission.quietPatrol == true,
        decisions = {},
        arrested = {},
        missionCall = nil,
    }
    -- A claimed mission call (CP.MissionCalls): { id, code, area, targetS, staff }. Rapid response needs a
    -- server-posted call (staff = paged or created, never) and a target.
    if type(opts.missionCall) == 'table' then
        local mc = opts.missionCall
        run.missionCall = {
            id = tonumber(mc.id),
            code = type(mc.code) == 'string' and U.clip(mc.code, 12) or nil,
            area = type(mc.area) == 'string' and mc.area or nil,
            targetS = tonumber(mc.targetS) and math.max(0, math.floor(tonumber(mc.targetS))) or nil,
            staff = mc.staff == true,
        }
    end
    for i = 1, #mission.objectives do
        run.objectives[i] = { status = 'pending', state = {} }
    end

    local forced = test and test.forcedTier and TierByName(test.forcedTier)
    run.expectedTier = TierName(forced) or TierName(TierFor(#officers)) or 'standard'

    for _, o in ipairs(officers) do
        local src = ToSrc(o.src)
        local okF, first = Call('Scoring', 'isFirstRunSinceDuty', src)
        run.participants[src] = {
            src = src,
            citizenid = o.citizenid,
            name = U.clip(o.name, 64),
            callsign = o.callsign and U.clip(o.callsign, 32) or nil,
            rank = o.rank,
            department = o.department,
            departmentShort = o.departmentShort,
            job = o.job,
            isOfficer = o.department ~= nil and o.job ~= nil,
            status = 'active',
            joinedAt = now,
            arrived = false,
            arrivedAt = nil,
            endReason = nil,
            result = nil,
            rowId = nil,
            score = {},
            vehicle = { lastNetId = nil, engine = 1000.0, body = 1000.0, seen = false },
            presence = { inRange = 0, total = 0 },
            lastEvent = nil,
            flagged = nil,
            firstRunSinceDuty = okF and first == true or false,
            items = {},
            deadline = now + run.startTimeout,
            telemetry = { lights = false, weapon = false, pedHits = 0, vehicleAt = nil },
            stats = {},
        }
        run.order[#run.order + 1] = src
    end
    RefreshDepartments(run)

    -- Economy locked at accept.
    run.cashBase = BaseCash(mission, missionType, isBoss)
    run.pointsBase = BasePoints(mission, missionType, isBoss)
    if not test and not opts.operationId and not isBoss then
        local ok, key = Call('Events', 'rollModifier', run)
        if ok and type(key) == 'string' then run.modifier = key end
    end
    if run.modifier == 'time_crunch' then
        local cut = Num(Config.Events and Config.Events.timeCrunchCut, 0.25)
        run.timeLimit = math.max(1, U.round(run.timeLimit * (1 - cut)))
    end
    run.timer.remaining = run.timeLimit

    if not test and not opts.operationId then
        local okU, unit = Call('Units', 'unitOf', leader)
        if okU and type(unit) == 'table' then run.unit = unit end
    end

    -- A member who started responding to a real call during the accept's lookups is refused (SPEC
    -- Availability). CP.Calls.isOnCall may itself yield (active-call lookup), so it runs before the
    -- no-yield block below.
    if not test and not opts.operationId then
        for _, src in ipairs(run.order) do
            local okC, onCall = Call('Calls', 'isOnCall', src)
            if okC and onCall == true then
                return nil, (src == leader) and 'err.on_call' or 'err.member_on_call'
            end
        end
    end

    -- The lookups above may yield (database, other modules). Re-check, with no yield until the run is
    -- registered, what another accept could have changed meanwhile: nobody ends up on two runs, two
    -- racing accepts never pass the server caps together, and a Cross-Department Mission launched during
    -- the accept locks out every other new mission, the Weekly Boss included (Hard rule 7). A member who
    -- disconnected or switched character meanwhile had no run for playerDropped to leave, so they are
    -- refused here.
    for _, src in ipairs(run.order) do
        if Runs.isOnMission(src) then
            return nil, (src == leader) and 'err.already_on_run' or 'err.member_on_run'
        end
        if not PlayerOnline(src) then return nil, 'err.member_unavailable' end
        local cid = CitizenOf(src)
        if cid and cid ~= run.participants[src].citizenid then return nil, 'err.member_unavailable' end
    end
    if not test and not opts.operationId then
        local okLock, locked = Call('Operations', 'isLocked')
        if okLock and locked == true then return nil, 'err.operation_locked' end
        local okCaps, capsErr = Runs.capsOk(missionType)
        if not okCaps then return nil, capsErr end
    end

    runs[id] = run
    for _, src in ipairs(run.order) do bySrc[src] = id end
    Call('Draw', 'reserve', id, mission.id, locationIndex)

    for _, src in ipairs(run.order) do GiveItems(run, run.participants[src]) end

    local clientMission = U.copy(mission)
    clientMission.locations = nil
    -- The clients get their own shared seed: the run seed drives the hidden server rolls (ctx.rng), and
    -- shared/utils.lua would let a client replay them.
    local clientSeed = U.hash(U.uuid() .. ':client:' .. tostring(GetGameTimer())) & 0x7FFFFFFF
    if clientSeed == 0 or clientSeed == seed then clientSeed = (seed % 0x7FFFFFFE) + 1 end
    local startRoute = not (test and test.useStartRoute == false)
    local data = {
        missionId = mission.id,
        mission = clientMission,
        locationIndex = locationIndex,
        location = location,
        start = { coords = location.start.coords, radius = location.start.radius },
        expectedTier = run.expectedTier,
        seed = clientSeed,
        host = run.host,
        test = test,
        modifier = run.modifier,
        participants = ParticipantsList(run),
        startRoute = startRoute,
        startTimeout = run.startTimeout,
        isBoss = isBoss,
        timeLimit = run.timeLimit,
    }
    for _, src in ipairs(run.order) do
        TriggerClientEvent(CP.e('client:start'), src, id, data)
        Call('Route', 'begin', run, src)
        Notify(src, 'info', 'run.accepted', { mission = mission.label or mission.id })
    end
    CP.log(TAG, 'run %s created: %s #%d (%s, %d participant(s), expected %s, modifier %s%s)', id, mission.id,
        locationIndex, missionType, #run.order, run.expectedTier, tostring(run.modifier), test and ', test' or '')
    Fire('run:created', run)
    PushRun(run)
    return run
end

-- ============================================================================
--                                 IN PROGRESS
-- ============================================================================

local function StartObjective(run, i)
    local o = run.objectives[i]
    if not o or run.state ~= 'in_progress' then return end
    run.objectiveIndex = i
    o.status = 'active'
    o.startedAt = os.time()
    o.startedAtMs = GetGameTimer()
    -- area = the objective's reference point: each participant's client turns it into street and zone
    -- names for its own Active Mission view (view.area; Radio Silence shows only those).
    local okA, area = pcall(Runs.anchor, run)
    Runs.send(run, 'client:objective', run.id, i, { action = 'start', area = okA and area or nil })
    CallBlock(run, i, 'start')
    if run.state ~= 'in_progress' then return end
    RefreshHud(run, true)
end

local function StartRun(run)
    if run.state ~= 'accepted' then return end
    run.state = 'in_progress'
    run.startedAt = os.time()
    local active = Runs.activeSrcs(run)
    local tier = ForcedTier(run) or TierFor(math.max(1, #active))
    run.tier, run.payTier = tier, tier
    local scaled
    if CP.Scaling and CP.Scaling.apply then
        local ok, list = pcall(CP.Scaling.apply, run.mission, tier)
        if ok and type(list) == 'table' then
            scaled = list
        else
            CP.err(TAG, 'CP.Scaling.apply failed: %s', tostring(list))
        end
    end
    scaled = scaled or U.deepcopy(run.mission.objectives)
    run.scaled = scaled
    for i = 1, #run.mission.objectives do
        run.objectives[i].obj = scaled[i] or run.mission.objectives[i]
    end
    run.timer = { remaining = run.timeLimit, paused = false, lastTick = GetGameTimer(), running = false }
    Runs.send(run, 'client:inProgress', run.id, {
        tier = TierName(tier),
        payTier = TierName(tier),
        objectives = scaled,
        timeLimit = run.timeLimit,
        remaining = run.timeLimit,
    })
    CP.log(TAG, 'run %s in progress at tier %s (%d participant(s))', run.id, tostring(TierName(tier)), #active)
    for i = 1, #run.mission.objectives do
        run.objectives[i].prepared = true
        Runs.send(run, 'client:objective', run.id, i, { action = 'prepare' })
        CallBlock(run, i, 'prepare')
        if run.state ~= 'in_progress' then return end
    end
    Fire('run:inProgress', run)
    if run.state ~= 'in_progress' then return end
    run.timer.lastTick = GetGameTimer()
    run.timer.running = true
    SendTimer(run)
    StartObjective(run, 1)
end

function Runs.markArrived(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src or run.state == 'ended' then return end
    local p = run.participants[src]
    if not p or p.status ~= 'active' or p.arrived then return end
    p.arrived = true
    p.arrivedAt = os.time()
    Call('Alerts', 'set', src, run)
    Runs.hudFor(run, src, { route = { status = 'arrived', distance = 0 } })
    CP.log(TAG, 'run %s: %d arrived at the start', run.id, src)
    -- rapid response: a server-posted mission call reached within its response target (points only, personal)
    local mc = run.missionCall
    if mc and not mc.staff and mc.targetS and not run.test
        and p.arrivedAt - (run.acceptedAt or p.arrivedAt) <= mc.targetS then
        Runs.award(run, 'rapid_response', { src = src })
    end
    local first = run.state == 'accepted'
    if first then StartRun(run) end
    if run.state == 'ended' then return end
    Fire('run:arrived', run, src, first)
    if run.state == 'ended' then return end
    BroadcastParticipants(run)
    if not first then PushRun(run) end
end

-- ============================================================================
--                                  OBJECTIVES
-- ============================================================================

local function CompleteObjective(run, index, data, bypass)
    if type(run) ~= 'table' or run.state ~= 'in_progress' then return false end
    index = math.tointeger(tonumber(index) or -1)
    if index ~= run.objectiveIndex then return false end
    local o = run.objectives[index]
    if not o or o.status ~= 'active' then return false end
    if not bypass then
        local obj = o.obj or {}
        local minSec = Num(obj.minSeconds, 0)
        local elapsed = (GetGameTimer() - (o.startedAtMs or GetGameTimer())) / 1000
        if elapsed < minSec then
            if not o.tooFastFlagged and not run.test and elapsed < minSec - 1 then
                o.tooFastFlagged = true
                local detail = ('objective %d after %.1f s (min %g s)'):format(index, elapsed, minSec)
                CP.log(TAG, 'run %s: %s: too_fast', run.id, detail)
                if Has('AntiCheat', 'flag') then
                    Call('AntiCheat', 'flag', run, nil, 'too_fast', detail)
                elseif not run.flagged then
                    run.flagged = { reason = 'too_fast', detail = detail }
                end
            end
            return false
        end
    end
    o.final = ChecklistOf(run, index)
    o.status = 'done'
    o.doneAt = os.time()
    o.data = data
    o.hud = nil
    if not o.stopped then
        o.stopped = true
        Runs.send(run, 'client:objective', run.id, index, { action = 'stop' })
        CallBlock(run, index, 'stop')
    end
    if run.state ~= 'in_progress' then return true end
    CP.log(TAG, 'run %s objective %d done', run.id, index)
    Runs.hud(run, {
        message = {
            text = Label('run.objective_complete', { label = ObjectiveLabel(run, index) }),
            kind = 'success',
        },
    })
    if index < #run.mission.objectives then
        StartObjective(run, index + 1)
    else
        Runs.endRun(run, 'completed', 'completed')
    end
    return true
end

function Runs.objectiveComplete(run, index, data)
    return CompleteObjective(run, index, data, false)
end

function Runs.failRun(run, reasonKey)
    if type(run) ~= 'table' or run.state == 'ended' then return end
    run.failReason = type(reasonKey) == 'string' and reasonKey or nil
    CP.log(TAG, 'run %s failed: %s', run.id, tostring(reasonKey))
    Runs.endRun(run, 'failed', 'mission_failed')
end

function Runs.dispatch(run, index, src, ev)
    if type(run) ~= 'table' or run.state ~= 'in_progress' then return false, 'not_in_progress' end
    index = math.tointeger(tonumber(index) or -1)
    local o = index and run.objectives[index]
    if not o or not o.prepared then return false, 'bad_objective' end
    if type(ev) ~= 'table' then return false, 'bad_event' end
    local impl = BlockOf(run, index)
    if not impl or type(impl.onEvent) ~= 'function' then return false, 'no_handler' end
    local ok, res, reason = CallBlock(run, index, 'onEvent', ToSrc(src), ev)
    if not ok then return false, 'error' end
    if run.state == 'in_progress' then RefreshHud(run) end
    if res == false then return false, reason end
    return true
end

local function Timeout(run)
    local i = run.objectiveIndex
    local o = run.objectives[i]
    local ok, res = CallBlock(run, i, 'onTimeout')
    if run.state ~= 'in_progress' then return end
    if ok and res == 'completed' and o and o.status == 'active' then
        CP.log(TAG, 'run %s: time limit reached, objective %d completes on timeout', run.id, i)
        o.final = ChecklistOf(run, i)
        o.status = 'done'
        o.doneAt = os.time()
        Runs.endRun(run, 'completed', 'completed')
    else
        Runs.endRun(run, 'failed', 'time_limit')
    end
end

-- ============================================================================
--                               AWARD / PENALIZE
-- ============================================================================

local function Record(run, id, opts, kind)
    if type(run) ~= 'table' or type(id) ~= 'string' or id == '' or run.state == 'ended' then return false end
    opts = type(opts) == 'table' and opts or {}
    local count = math.floor(Num(opts.count, 1))
    if count <= 0 then return false end
    local src = ToSrc(opts.src)
    if src then
        local p = run.participants[src]
        if not p then return false end
        p.score[id] = (p.score[id] or 0) + count
    else
        run.score.shared[id] = (run.score.shared[id] or 0) + count
    end
    if opts.points ~= nil and tonumber(opts.points) then
        local v = tonumber(opts.points)
        if kind == 'penalty' then v = -math.abs(v) end
        run.score.values[id] = v
    end
    run.score.kinds[id] = kind
    CP.log(TAG, 'run %s: %s %s x%d%s', run.id, kind, id, count, src and (' for ' .. src) or '')
    return true
end

function Runs.award(run, id, opts) return Record(run, id, opts, 'bonus') end
function Runs.penalize(run, id, opts) return Record(run, id, opts, 'penalty') end

-- ============================================================================
--                         SERVICE RECORD AND DECISIONS
-- ============================================================================

local STAT_SET = Set(STAT_KEYS)

local function AddStat(p, key, n)
    p.stats = p.stats or {}
    p.stats[key] = (p.stats[key] or 0) + n
end

-- A service-record count (citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok,
-- decisions_best, decisions_bad, lethal) for src, or for every active participant when src is nil. Written
-- to each row; only completed rows are ever summed. Arrests go through noteArrest.
function Runs.noteStat(run, src, key, n)
    if type(run) ~= 'table' or run.state == 'ended' or not STAT_SET[key] or key == 'arrests' then return false end
    n = math.floor(Num(n, 1))
    if n == 0 then return false end
    if src == nil then
        local any = false
        for _, s in ipairs(Runs.activeSrcs(run)) do
            AddStat(run.participants[s], key, n)
            any = true
        end
        return any
    end
    src = ToSrc(src)
    local p = src and run.participants[src]
    if not p or p.status ~= 'active' then return false end
    AddStat(p, key, n)
    return true
end

-- One arrest per person per run, credited to the first officer who cuffed them or decided Arrest (a
-- validated cuff of a mission suspect, or an Arrest graded best or ok). false for a repeat.
function Runs.noteArrest(run, src, netId)
    if type(run) ~= 'table' or run.state == 'ended' then return false end
    src = ToSrc(src)
    netId = math.tointeger(tonumber(netId) or -1)
    local p = src and run.participants[src]
    if not p or p.status ~= 'active' or not netId then return false end
    run.arrested = run.arrested or {}
    if run.arrested[netId] then return false end
    run.arrested[netId] = src
    AddStat(p, 'arrests', 1)
    return true
end

-- A graded disposition (CP.Custody grades; the engine records). entry = { contact, kind, choice, verdict,
-- bonusId, points, truthKey, bestChoice, facts, discoverable, knownAt, failKey, netId }. The bonus or
-- penalty is personal to the decider; points = 0 records the grade without points (a revealed fact, a
-- caught runner). 'critical' fails the case for everyone with failKey.
function Runs.decide(run, src, entry)
    if type(run) ~= 'table' or run.state ~= 'in_progress' or type(entry) ~= 'table' then return false end
    src = ToSrc(src)
    local p = src and run.participants[src]
    if not p or p.status ~= 'active' or not VERDICTS[entry.verdict] then return false end
    local verdict = entry.verdict
    run.decisions = run.decisions or {}
    local points = entry.points ~= nil and Num(entry.points, 0) or nil
    local bonusCfg = type(entry.bonusId) == 'string' and Config.Bonuses and Config.Bonuses[entry.bonusId] or nil
    local value = points
    if value == nil and type(bonusCfg) == 'table' and bonusCfg.kind ~= 'pct' then value = Num(bonusCfg.value, 0) end
    local rec = {
        contact = tostring(entry.contact or ''),
        kind = entry.kind == 'vehicle' and 'vehicle' or 'person',
        choice = tostring(entry.choice or ''),
        best = tostring(entry.bestChoice or ''),
        verdict = verdict,
        by = p.name or ('#' .. src),
        bySrc = src,
        truth = tostring(entry.truthKey or ''),
        facts = type(entry.facts) == 'table' and U.copy(entry.facts) or {},
        points = math.floor(value or 0),
        discoverable = entry.discoverable ~= false,
        knownAtS = entry.knownAt and run.startedAt and math.max(0, math.floor(Num(entry.knownAt, 0) - run.startedAt))
            or nil,
        bonusId = entry.bonusId,
        netId = math.tointeger(tonumber(entry.netId) or -1),
    }
    run.decisions[#run.decisions + 1] = rec
    if verdict == 'best' or verdict == 'ok' then Runs.noteStat(run, src, 'decisions_ok', 1) end
    if verdict == 'best' then Runs.noteStat(run, src, 'decisions_best', 1) end
    if verdict == 'wrong' or verdict == 'critical' then Runs.noteStat(run, src, 'decisions_bad', 1) end
    if rec.choice == 'arrest' and (verdict == 'best' or verdict == 'ok') and rec.netId and rec.netId > 0 then
        Runs.noteArrest(run, src, rec.netId)
    end
    if type(entry.bonusId) == 'string' and entry.bonusId ~= '' and points ~= 0 then
        local negative = (value or 0) < 0 or verdict == 'wrong' or verdict == 'critical'
        local opts = { src = src, points = points }
        if negative then Runs.penalize(run, entry.bonusId, opts) else Runs.award(run, entry.bonusId, opts) end
    end
    CP.log(TAG, 'run %s: %s decided %s for %s (%s)', run.id, tostring(src), rec.choice, rec.contact, verdict)
    if verdict == 'critical' then
        Runs.failRun(run, type(entry.failKey) == 'string' and entry.failKey or 'reason.known_error')
    end
    return true
end

-- ============================================================================
--                              LEAVING AND ENDING
-- ============================================================================
-- CRIMSON_ARENA rule 1: an in-arena participant's bag is never touched (it may still hold our value while
-- only the routing bucket has moved); only CP.Alerts' intent is dropped. Everyone else: CP.Alerts.clear.
local function ReleaseFlag(src)
    if InArena(src) then
        Call('Alerts', 'forget', src)
    else
        Call('Alerts', 'clear', src)
    end
end

function Runs.removeParticipant(run, src, endReason, opts)
    src = ToSrc(src)
    opts = type(opts) == 'table' and opts or {}
    if type(run) ~= 'table' or not src or run.state == 'ended' then return nil end
    local p = run.participants[src]
    if not p or p.status ~= 'active' then return nil end
    if not RESULT[endReason] then
        CP.warn(TAG, 'unknown end reason %s for %d; using quit', tostring(endReason), src)
        endReason = 'quit'
    end
    local result = RESULT[endReason]
    local wasInProgress = run.state == 'in_progress'

    -- Synchronous part: nothing below yields until the row is written.
    p.status = 'left'
    p.endReason, p.result = endReason, result
    p.leftAt = os.time()
    if bySrc[src] == run.id then bySrc[src] = nil end
    if endReason == 'downed' then run.stats.downs = (run.stats.downs or 0) + 1 end
    ApplyCooldowns(run, p, endReason)

    local others = Runs.activeSrcs(run)
    RefreshDepartments(run)
    CP.log(TAG, 'run %s: %d left (%s -> %s), %d left in the run', run.id, src, endReason, result, #others)

    if not opts.keepFlag then ReleaseFlag(src) end
    Call('Route', 'stop', run, src)
    Fire('participant:left', run, src, endReason)
    if wasInProgress then
        local i = run.objectiveIndex
        if run.objectives[i] and run.objectives[i].status == 'active' then
            CallBlock(run, i, 'onParticipantLeft', src)
        end
    end

    local lastOut = #others == 0
    if lastOut then
        run.state = 'ended'
        run.endedAt = os.time()
        run.endReason = endReason
        run.endState = result == 'failed' and 'failed' or 'abandoned'
        CleanupRun(run)
    else
        if run.host == src then MigrateHost(run, 'left') end
        if run.state ~= 'ended' then rescale(run, endReason) end
    end
    RemoveItems(run, p)

    -- Result, row, payment, hooks.
    local rowId, rr = Settle(run, p, result, endReason, others)
    if not opts.silent then
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, result, endReason, rr)
        local key = opts.notify
        if key then Notify(src, 'warning', key) end
    else
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, result, endReason, nil)
    end
    PushNone(src)

    if lastOut then
        local state = run.endState
        CP.log(TAG, 'run %s ended: nobody left (%s)', run.id, state)
        AfterRunEnded(run, state)
    else
        if not run.test and (result == 'completed' or result == 'failed') then Call('Leaderboard', 'invalidate') end
        if run.state ~= 'ended' then
            BroadcastParticipants(run)
            for _, s in ipairs(others) do Notify(s, 'info', 'run.partner_left', { name = p.name or ('#' .. src) }) end
            RefreshHud(run, true)
            PushRun(run)
        end
    end
    return rowId
end

-- Participants who are down when the run ends have Failed (Hard rule 18), whatever the run's end state:
-- they leave first with end_reason 'downed' through CP.Downed (which also starts the pick-up / EMS flow)
-- or, without it, directly. The downed poll only sees runs that have not ended, so this is the last point
-- where the down can be caught. Returns false when these leaves ended the run (nobody was left).
local function RemoveDownedBeforeEnd(run)
    if not Has('Qbx', 'isDowned') then return true end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        local p = run.participants[src]
        local okD, down = Call('Qbx', 'isDowned', src)
        if p and p.status == 'active' and okD and down == true and not InArena(src) then
            CP.log(TAG, 'run %s is ending: %d is down and has Failed', run.id, src)
            Call('Downed', 'handle', run, src)
            if p.status == 'active' and run.state ~= 'ended' then
                local okP, pending = Call('Downed', 'isPending', src)
                Runs.removeParticipant(run, src, 'downed', { keepFlag = okP and pending == true })
            end
            if run.state == 'ended' then return false end
        end
    end
    return true
end

function Runs.endRun(run, state, endReason)
    if type(run) ~= 'table' or run.state == 'ended' or run.ending then return end
    if state ~= 'completed' and state ~= 'failed' then state = 'failed' end
    endReason = RESULT[endReason] and endReason or (state == 'completed' and 'completed' or 'mission_failed')
    run.ending = true
    local okDown, open = pcall(RemoveDownedBeforeEnd, run)
    run.ending = nil
    if not okDown then CP.err(TAG, 'run %s: downed check at the end failed: %s', tostring(run.id), tostring(open)) end
    if run.state == 'ended' or (okDown and open == false) then return end
    SyncTimer(run)
    run.state = 'ended'
    run.endedAt = os.time()
    run.endState = state
    run.endReason = endReason
    if run.timer then run.timer.running = false end

    local finals = Runs.activeSrcs(run)
    for _, src in ipairs(finals) do
        local p = run.participants[src]
        p.status = 'left'
        p.leftAt = run.endedAt
        p.result, p.endReason = state, endReason
        if bySrc[src] == run.id then bySrc[src] = nil end
        ApplyCooldowns(run, p, endReason)
    end
    CP.log(TAG, 'run %s ended %s (%s) for %d participant(s)', run.id, state, endReason, #finals)
    CleanupRun(run)
    for _, src in ipairs(finals) do
        ReleaseFlag(src)
        Call('Route', 'stop', run, src)
        RemoveItems(run, run.participants[src])
    end
    for _, src in ipairs(finals) do
        local p = run.participants[src]
        local others = {}
        for _, s in ipairs(finals) do if s ~= src then others[#others + 1] = s end end
        local _, rr = Settle(run, p, state, endReason, others)
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, state, endReason, rr)
        PushNone(src)
    end
    AfterRunEnded(run, state)
end

-- Which stored end reasons a reclassification may replace: an un-marked real call only turns a real_call
-- leave into real_call_cancelled (a force recall or a cancelled operation never becomes a normal abandon).
local RECLASSIFY_FROM = {
    real_call_cancelled = { list = { real_call = true }, sql = '(\'real_call\')' },
}
local RECLASSIFY_ANY = {
    list = { real_call = true, force_recall = true, cancelled = true },
    sql = '(\'real_call\', \'force_recall\', \'cancelled\')',
}

function Runs.reclassify(citizenid, runId, newEndReason)
    if type(citizenid) ~= 'string' or type(runId) ~= 'string' or not RESULT[newEndReason] then return false end
    local from = RECLASSIFY_FROM[newEndReason] or RECLASSIFY_ANY
    local run = runs[runId] or (endedRuns[runId] and endedRuns[runId].run)
    local p
    if run then
        for _, q in pairs(run.participants) do
            if q.citizenid == citizenid then p = q; break end
        end
    end
    if p then
        if p.status == 'active' then return false end
        if p.endReason == newEndReason then return true end
        if not from.list[p.endReason] then return false end
    end
    if run and run.test then
        if p then p.endReason, p.result = newEndReason, RESULT[newEndReason] end
        return p ~= nil
    end
    Db()
    local ok, n = pcall(
        MySQL.update.await,
        [[
        UPDATE cp_mission_runs SET end_reason = ?, state = ?, breakdown = JSON_SET(breakdown, '$.endReason', ?)
        WHERE run_uuid = ? AND citizenid = ? AND end_reason IN ]] .. from.sql,
        { newEndReason, RESULT[newEndReason], newEndReason, runId, citizenid }
    )
    if not ok then
        CP.err(TAG, 'reclassify %s/%s failed: %s', citizenid, runId, tostring(n))
        return false
    end
    if not n or n < 1 then return false end
    local missionType, missionId, cooldown, isBoss
    if run then
        missionType, missionId, cooldown, isBoss =
            run.missionType, run.missionId, Num(run.mission.cooldown, 0), run.isBoss
    else
        local okR, row = pcall(MySQL.single.await,
            'SELECT mission_type, mission_id FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ? LIMIT 1',
            { runId, citizenid })
        if okR and type(row) == 'table' then
            missionType, missionId = row.mission_type, row.mission_id
            cooldown = MissionCooldownOf(missionId)
            isBoss = missionId == BOSS_ID
        end
    end
    if missionType then
        local c = CdEntry(citizenid)
        local now = os.time()
        if MISSION_COOLDOWN[newEndReason] and cooldown and cooldown > 0 then
            c.missions[missionId] = math.max(c.missions[missionId] or 0, now + math.floor(cooldown))
        end
        if TYPE_COOLDOWN[newEndReason] and not isBoss then
            c.types[missionType] = math.max(c.types[missionType] or 0, now + math.floor(AbandonCooldown()))
        end
    end
    if p then p.endReason, p.result = newEndReason, RESULT[newEndReason] end
    if run and run.state == 'in_progress' and not ForcedTier(run) then
        local n2 = #Runs.activeSrcs(run)
        if n2 > 0 then
            local old = run.payTier
            run.payTier = LowerTier(run.payTier, TierFor(n2))
            if TierName(old) ~= TierName(run.payTier) then
                Runs.send(run, 'client:tierChanged', run.id, TierName(run.tier), TierName(run.payTier))
                PushRun(run)
            end
        end
    end
    CP.log(TAG, 'run %s: %s reclassified as %s', runId, citizenid, newEndReason)
    return true
end

-- ============================================================================
--                                    VIEWS
-- ============================================================================

local function ModifierView(run)
    if not run.modifier then return nil end
    return { key = run.modifier, label = Label('modifier.' .. run.modifier) }
end

local function ExpectedFor(run)
    local tier = run.payTier or TierByName(run.expectedTier) or TierFor(math.max(1, #Runs.activeSrcs(run)))
    local P = Num(run.pointsBase, 0)
    local ev = Config.Events or {}
    local modPts = run.modifier and Num(ev.modifierPoints, 0) * P or 0
    local nDepts = ActiveDepartments(run)
    local mCross = nDepts >= 2 and Num(Config.CrossDepartmentPoints, 1.10) or 1.0
    local cap = Num(Config.Scoring and Config.Scoring.scoreCap, 2.0) * P
    local pts = math.min(cap, (P + modPts) * Num(tier and tier.points, 1.0) * mCross)
    if ev.typeOfTheDay ~= false then
        local ok, tod = Call('Events', 'typeOfTheDay')
        if ok and tod ~= nil and tod == run.missionType then pts = pts * Num(ev.todMultiplier, 2.0) end
    end
    local cash = U.round(
        Num(run.cashBase, 0) * Num(tier and tier.cash, 1.0) * (run.modifier and Num(ev.modifierCash, 1.0) or 1.0))
    return { cash = cash, points = math.floor(pts) }
end

local function RouteFor(run, src, p)
    local route = { status = 'disabled' }
    local recalcs = math.floor(Num(Config.Route and Config.Route.maxRecalcs, 2))
    local ok, st = Call('Route', 'status', run, src)
    if ok and type(st) == 'table' then
        route.status = st.status or route.status
        route.secondsLeft = tonumber(st.secondsLeft)
        route.distance = tonumber(st.distance)
        if tonumber(st.recalcsLeft) then recalcs = math.floor(tonumber(st.recalcsLeft)) end
    elseif p and p.arrived then
        route.status, route.distance = 'arrived', 0
    elseif not (run.test and run.test.useStartRoute == false) then
        route.status = 'on'
    end
    if p and p.arrived and route.status ~= 'off' then route.status = 'arrived' end
    return route, recalcs
end

function Runs.view(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or run.state == 'ended' then return nil end
    local p = src and run.participants[src]
    local started = run.state == 'in_progress'
    local route, recalcs = RouteFor(run, src, p)
    local partners = ParticipantsList(run)
    local logView = nil
    if started then
        local cur = run.objectives[run.objectiveIndex]
        local lg = cur and cur.status == 'active' and type(cur.state) == 'table' and cur.state.log or nil
        if type(lg) == 'table' and lg.point ~= nil and type(lg.choices) == 'table' then
            logView = { point = lg.point, choices = lg.choices }
        end
    end
    local remaining = Runs.remaining(run)
    local startIn = nil
    if not started and p and not p.arrived and p.deadline then startIn = math.max(0, p.deadline - os.time()) end
    -- Street · zone of the current objective (else of the start), as this viewer's own client resolved it.
    local area = nil
    if p and type(p.area) == 'table' then
        area = (started and p.area[run.objectiveIndex]) or p.area[0]
    end
    local mcView = nil
    if run.missionCall then
        local arrivedS = p and p.arrivedAt and math.max(0, p.arrivedAt - (run.acceptedAt or p.arrivedAt)) or nil
        mcView = { code = run.missionCall.code, targetS = run.missionCall.targetS, arrivedS = arrivedS }
    end
    local contact = nil
    if started and Has('Custody', 'view') then
        local okC, cv = Call('Custody', 'view', run, run.objectiveIndex, src)
        if okC and type(cv) == 'table' then contact = cv end
    end
    local intel = run.shared and run.shared.intel or nil
    if intel ~= nil and CP.Locale and CP.Locale.resolve then intel = CP.Locale.resolve(Tokens(intel)) end
    if type(intel) ~= 'string' or intel == '' then intel = nil end
    local objectives = HudObjectives(run, true)
    if CP.Locale and CP.Locale.resolveAll then objectives = CP.Locale.resolveAll(objectives) end
    return {
        -- Optional extras for the Active Mission screen (web/src/types/run_ui.ts): the viewer, the boss flag,
        -- the operation, the seconds left to reach the start and the area (street · zone).
        me = src,
        isBoss = run.isBoss == true,
        operationId = run.operationId,
        startIn = startIn,
        area = area,
        runId = run.id,
        missionLabel = run.mission.label or run.missionId,
        description = run.mission.description or '',
        missionType = run.missionType,
        state = run.state,
        tier = started and TierName(run.tier) or run.expectedTier,
        tierExpected = not started,
        payTier = started and TierName(run.payTier) or run.expectedTier,
        route = route,
        objectives = objectives,
        remaining = remaining and math.max(0, math.ceil(remaining)) or nil,
        paused = run.timer and run.timer.paused == true or false,
        partners = partners,
        expected = ExpectedFor(run),
        modifier = ModifierView(run),
        test = run.test ~= nil,
        recalcsLeft = recalcs,
        radioSilence = run.modifier == 'radio_silence',
        log = logView,
        intel = intel,
        missionCall = mcView,
        contact = contact,
    }
end

function Runs.summary(run)
    if type(run) ~= 'table' then return nil end
    local list = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        list[#list + 1] = {
            src = src,
            name = p.name,
            callsign = p.callsign,
            departmentShort = p.departmentShort or '',
            status = p.status,
        }
    end
    local remaining = Runs.remaining(run)
    return {
        runId = run.id,
        missionType = run.missionType,
        missionLabel = run.mission.label or run.missionId,
        tier = TierName(run.tier) or run.expectedTier,
        state = run.state,
        remaining = remaining and math.max(0, math.ceil(remaining)) or nil,
        test = run.test ~= nil,
        operationId = run.operationId,
        participants = list,
    }
end

-- ============================================================================
--                           TEST HOOKS (CP.Testing)
-- ============================================================================

function Runs.testSkip(run)
    if type(run) ~= 'table' or not run.test or run.state ~= 'in_progress' then return false end
    return CompleteObjective(run, run.objectiveIndex, { skipped = true }, true)
end

function Runs.testRestart(run)
    if type(run) ~= 'table' or not run.test or run.state ~= 'in_progress' then return false end
    local i = run.objectiveIndex
    local o = run.objectives[i]
    if not o or o.status ~= 'active' then return false end
    local impl = BlockOf(run, i)
    if impl and type(impl.restart) == 'function' then
        CallBlock(run, i, 'restart')
    else
        CallBlock(run, i, 'stop')
        Runs.send(run, 'client:objective', run.id, i, { action = 'stop' })
        for netId, e in pairs(run.entities) do
            if e.obj == i then Runs.deleteEntity(run, netId) end
        end
        for k in pairs(o.state) do o.state[k] = nil end
        o.hud = nil
        Runs.send(run, 'client:objective', run.id, i, { action = 'prepare' })
        CallBlock(run, i, 'prepare')
        if run.state ~= 'in_progress' then return true end
        Runs.send(run, 'client:objective', run.id, i, { action = 'start' })
        CallBlock(run, i, 'start')
    end
    o.startedAtMs = GetGameTimer()
    o.tooFastFlagged = nil
    if run.state == 'in_progress' then RefreshHud(run, true) end
    return true
end

local ANCHOR_KEYS = {
    'anchor',
    'checkpoints',
    'points',
    'spawns',
    'npcs',
    'targets',
    'door',
    'suspect',
    'spawn',
    'center',
    'route',
    'safe',
    'scene',
}

local function FirstPoint(location, v, depth)
    depth = depth or 0
    if depth > 3 or v == nil then return nil end
    if type(v) == 'string' then
        if v == 'shared:devices' then return nil end
        return FirstPoint(location, location and location[v], depth + 1)
    end
    if IsVec(v) then return Vec3Of(v) end
    if type(v) == 'table' then
        if v.coords and IsVec(v.coords) then return Vec3Of(v.coords) end
        if type(v.points) == 'table' then return FirstPoint(location, v.points, depth + 1) end
        if v[1] ~= nil then return FirstPoint(location, v[1], depth + 1) end
    end
    return nil
end

function Runs.anchor(run)
    if type(run) ~= 'table' then return nil end
    local start = Vec3Of(run.location.start.coords)
    if run.state ~= 'in_progress' then return start end
    local i = run.objectiveIndex
    local o = run.objectives[i]
    local obj = o and o.obj or {}
    if run.shared and type(run.shared.devices) == 'table' and obj.targets == 'shared:devices' then
        for _, d in ipairs(run.shared.devices) do
            if d.coords and IsVec(d.coords) then return Vec3Of(d.coords) end
        end
    end
    for _, key in ipairs(ANCHOR_KEYS) do
        local pt = FirstPoint(run.location, obj[key])
        if pt then return pt end
    end
    for _, e in ipairs(Runs.entitiesFor(run, { obj = i, alive = true })) do
        if e.entity and DoesEntityExist(e.entity) then return GetEntityCoords(e.entity) end
    end
    return start
end

-- ============================================================================
--                  NET: evidence, telemetry, abandon, getRun
-- ============================================================================

local function Sanitize(v, depth)
    local t = type(v)
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return nil, false end
        return v, true
    end
    if t == 'boolean' then return v, true end
    if t == 'string' then
        if #v > EVIDENCE_MAX_STRING then return nil, false end
        return v, true
    end
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then return v, true end
    if t == 'table' then
        if depth >= EVIDENCE_MAX_DEPTH then return nil, false end
        local out, n = {}, 0
        for k, val in pairs(v) do
            n = n + 1
            if n > EVIDENCE_MAX_KEYS then return nil, false end
            if type(k) ~= 'string' and type(k) ~= 'number' then return nil, false end
            if type(k) == 'string' and #k > 64 then return nil, false end
            local clean, ok = Sanitize(val, depth + 1)
            if not ok then return nil, false end
            out[k] = clean
        end
        return out, true
    end
    return nil, false
end
local function CleanEvidence(v)
    local out, ok = Sanitize(v, 0)
    return ok and out or nil
end

local function RecheckOk(run, p)
    if run.test and not p.isOfficer then return true end
    if not Has('Access', 'recheck') then return true end
    local ok, qualifies, reason = Call('Access', 'recheck', p.src, p.job)
    if ok and qualifies == false then
        Runs.removeParticipant(run, p.src, LOST_REASONS[reason] and reason or 'job_change')
        return false
    end
    return true
end

RegisterNetEvent(CP.e('server:objective'), function(runId, index, evidence)
    local src = source
    src = ToSrc(src)
    if not src then return end
    if not CP.Net.rateOk(src, 'runs:objective', 12, 1000) then return end
    if type(runId) ~= 'string' or #runId > 64 then return end
    index = math.tointeger(tonumber(index) or -1)
    local run = runs[runId]
    if not run then
        CP.log(TAG, 'objective event from %d for unknown run %s', src, runId)
        return
    end
    local p = run.participants[src]
    if not p or p.status ~= 'active' then
        CP.warn(TAG, 'objective event from %d who is not an active participant of run %s', src, runId)
        return
    end
    if run.state ~= 'in_progress' or not index or index < 1 then
        CP.log(TAG, 'run %s: objective event %s from %d ignored (state %s)', runId, tostring(index), src, run.state)
        return
    end
    local ev = CleanEvidence(evidence)
    if type(ev) ~= 'table' or type(ev.type) ~= 'string' or #ev.type > 32 then
        CP.log(TAG, 'run %s: malformed evidence from %d', runId, src)
        return
    end
    if InArena(src) then return end
    -- CP.AntiCheat sees every well-formed event, also one for an objective past the last (an executor's
    -- event for a later objective flags the run 'unexpected_event' there). A check that failed drops the
    -- event: it would otherwise skip the speed and duplicate checks.
    if Has('AntiCheat', 'checkEvent') then
        local okCall, ok, reason = Call('AntiCheat', 'checkEvent', run, src, index, ev)
        if not okCall or ok == false then
            CP.log(TAG, 'run %s: evidence %s from %d rejected by anticheat (%s)', runId, ev.type, src,
                tostring(okCall and reason or 'check failed'))
            return
        end
    end
    local o = run.objectives[index]
    if not o or index ~= run.objectiveIndex or o.status ~= 'active' then
        CP.log(TAG, 'run %s: evidence for objective %d from %d is out of order (current %d)', runId, index, src,
            run.objectiveIndex)
        return
    end
    if not RecheckOk(run, p) then return end
    -- The re-check may yield: the participant, the run or the objective may have changed meanwhile.
    if run.state ~= 'in_progress' or p.status ~= 'active' or index ~= run.objectiveIndex or o.status ~= 'active' then
        return
    end
    local okCall, ok, reason = CallBlock(run, index, 'onEvent', src, ev)
    if okCall and ok == false then
        CP.log(TAG, 'run %s: block rejected %s from %d (%s)', runId, ev.type, src, tostring(reason))
    end
    -- The event may have moved the objective on (a logged door, a new tablet log point): the HUD and
    -- the Active Mission view follow now instead of on the next tick.
    if run.state == 'in_progress' then RefreshHud(run) end
end)

-- An entity one of the runs spawned (the engine's registry, never the cp bag: a client can put a cp bag
-- on its own vehicle or on a pedestrian it runs over to dodge the damage and pedestrian penalties).
local function IsRunEntity(entity, netId)
    for _, run in pairs(runs) do
        local e = run.entities[netId]
        if e and (e.entity == nil or e.entity == entity) then return true end
    end
    return false
end

local function RecordVehicle(p, veh, netId)
    local engine = Num(GetVehicleEngineHealth(veh), 1000.0)
    local body = Num(GetVehicleBodyHealth(veh), 1000.0)
    local v = p.vehicle
    v.lastNetId = netId
    v.seen = true
    if engine < v.engine then v.engine = engine end
    if body < v.body then v.body = body end
end

local function TelemetryVehicle(run, p, data)
    local now = GetGameTimer()
    if p.telemetry.vehicleAt and now - p.telemetry.vehicleAt < VEHICLE_SAMPLE_MS then return end
    local netId = type(data) == 'table' and math.tointeger(tonumber(data.netId) or -1)
    if not netId or netId <= 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) or GetEntityType(veh) ~= 2 then return end
    if GetPedInVehicleSeat(veh, -1) ~= GetPlayerPed(p.src) then return end
    if IsRunEntity(veh, netId) then return end
    p.telemetry.vehicleAt = now
    RecordVehicle(p, veh, netId)
end

-- The server's own sample (every VEHICLE_SAMPLE_MS per active participant, from tickRun): the vehicle the
-- participant is driving, read with server natives. The no-damage bonus and the heavy-damage penalty never
-- depend on the client choosing to report; its telemetry only adds samples in between.
local function SampleVehicle(run, p, nowMs)
    if p.vehicleSampledAt and nowMs - p.vehicleSampledAt < VEHICLE_SAMPLE_MS then return end
    p.vehicleSampledAt = nowMs
    local me = GetPlayerPed(p.src)
    if not me or me == 0 then return end
    local veh = GetVehiclePedIsIn(me, false)
    if not veh or veh == 0 or not DoesEntityExist(veh) or GetEntityType(veh) ~= 2 then return end
    if GetPedInVehicleSeat(veh, -1) ~= me then return end
    local netId = NetworkGetNetworkIdFromEntity(veh)
    if IsRunEntity(veh, netId) then return end
    RecordVehicle(p, veh, netId)
end

local function TelemetryPedHit(run, p, data)
    if p.telemetry.pedHits >= MAX_PED_HITS then return end
    local netId = type(data) == 'table' and math.tointeger(tonumber(data.netId) or -1)
    if not netId or netId <= 0 or run.pedHits[netId] then return end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) or GetEntityType(ped) ~= 1 then return end
    if IsPedAPlayer(ped) then return end
    if IsRunEntity(ped, netId) then return end
    local me = GetPlayerPed(p.src)
    if not me or me == 0 or GetVehiclePedIsIn(me, false) == 0 then return end
    if U.dist(GetEntityCoords(me), GetEntityCoords(ped)) > PED_HIT_RANGE then return end
    run.pedHits[netId] = true
    p.telemetry.pedHits = p.telemetry.pedHits + 1
    Runs.penalize(run, 'pedestrian_hit', { src = p.src })
end

-- The street and zone names of the start (index 0) or of the current objective, resolved by this
-- participant's own client (the server has no street-name natives). Display text for that participant's
-- own view only, never shown to anyone else; the first text per index is kept.
local function TelemetryArea(run, p, data)
    local index = type(data) == 'table' and math.tointeger(tonumber(data.index) or -1)
    local text = type(data) == 'table' and data.text or nil
    if not index or index < 0 or type(text) ~= 'string' then return end
    if index > 0 and (run.state ~= 'in_progress' or index ~= run.objectiveIndex) then return end
    text = U.trim((text:gsub('%c', ' '):gsub('%s+', ' ')))
    if text == '' or #text > AREA_MAX then return end
    p.area = p.area or {}
    if p.area[index] ~= nil then return end
    p.area[index] = text
    PushRun(run, { p.src })
end

-- A participant fired a weapon during the run (costs no_weapons_fired). Counted once per participant.
-- Sources: the client's weapon_fired telemetry (misses too) and server-side proof of gunfire on mission
-- NPCs (CP.Npc: weaponDamageEvent hits and weapon kills by an active participant).
function Runs.noteWeaponFired(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src or run.state == 'ended' then return false end
    local p = run.participants[src]
    if not p or p.status ~= 'active' then return false end
    if p.firedWeapon then return true end
    p.telemetry.weapon = true
    p.firedWeapon = true
    run.stats.weaponsFired = (run.stats.weaponsFired or 0) + 1
    CP.log(TAG, 'run %s: %d fired a weapon', run.id, src)
    return true
end

RegisterNetEvent(CP.e('server:telemetry'), function(runId, kind, data)
    local src = source
    src = ToSrc(src)
    if not src then return end
    if not CP.Net.rateOk(src, 'runs:telemetry', 8, 1000) then return end
    if type(runId) ~= 'string' or #runId > 64 or not TELEMETRY_KINDS[kind] then return end
    if data ~= nil and type(data) ~= 'table' then return end
    local run = runs[runId]
    local p = run and run.participants[src]
    if not p or p.status ~= 'active' or run.state == 'ended' then return end
    if InArena(src) then return end
    if kind == 'vehicle' then
        TelemetryVehicle(run, p, data)
    elseif kind == 'ped_hit' then
        TelemetryPedHit(run, p, data)
    elseif kind == 'lights_siren' then
        -- quietPatrol missions only, and only once the run is in progress: the drive to the start is free
        if run.quietPatrol and run.state == 'in_progress' and not p.telemetry.lights then
            local me = GetPlayerPed(src)
            if me and me ~= 0 and GetVehiclePedIsIn(me, false) ~= 0 then
                p.telemetry.lights = true
                Runs.penalize(run, 'lights_siren', { src = src })
            end
        end
    elseif kind == 'area' then
        TelemetryArea(run, p, data)
    elseif kind == 'weapon_fired' then
        Runs.noteWeaponFired(run, src)
    end
end)

CP.Net.action('server:abandon', function(src, payload)
    local runId = payload
    if type(payload) == 'table' then runId = payload.runId end
    if type(runId) ~= 'string' or #runId > 64 then return false, 'err.invalid_payload' end
    local run = runs[runId]
    if not run then return false, 'err.invalid_run' end
    if not Runs.isParticipant(run, src) then return false, 'err.not_on_run' end
    Runs.removeParticipant(run, src, 'quit')
    return true, { runId = runId }
end, { rate = 2 })

CP.Net.callback('getRun', function(src)
    local run = Runs.getBySrc(src)
    if not run then return nil end
    return Runs.view(run, src)
end, { rate = 6 })

exports('IsOnMission', function(src)
    return Runs.isOnMission(src)
end)

-- ============================================================================
--                                    LOOPS
-- ============================================================================

local function TickRun(run, nowMs)
    if run.state == 'ended' then return end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        if InArena(src) then
            Runs.removeParticipant(run, src, 'quit', { notify = 'run.left_for_arena' })
            if run.state == 'ended' then return end
        end
    end
    local now = os.time()
    for _, src in ipairs(Runs.activeSrcs(run)) do
        local p = run.participants[src]
        if not p.arrived and p.deadline and now >= p.deadline then
            Runs.removeParticipant(run, src, 'start_timeout')
            if run.state == 'ended' then return end
        end
    end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        local p = run.participants[src]
        if p and PlayerOnline(src) then SampleVehicle(run, p, nowMs) end
    end
    if run.state ~= 'in_progress' then return end

    local dt = (nowMs - (run.lastTickMs or nowMs)) / 1000
    run.lastTickMs = nowMs
    SyncTimer(run)
    EntityBookkeeping(run)
    if run.state ~= 'in_progress' then return end

    local host = run.host
    local hp = host and run.participants[host]
    if not hp or hp.status ~= 'active' or not PlayerOnline(host) then
        MigrateHost(run, 'offline', false)
    elseif not Responsive(host) then
        MigrateHost(run, 'unresponsive', true)
    end

    local i = run.objectiveIndex
    local o = run.objectives[i]
    if o and o.status == 'active' then
        CallBlock(run, i, 'tick', dt > 0 and dt or 1.0)
        if run.state ~= 'in_progress' then return end
    end
    if run.timer.running and not run.timer.paused and Runs.remaining(run) <= 0 then
        Timeout(run)
        return
    end
    RefreshHud(run)
    if run.timerSentAt and now - run.timerSentAt >= TIMER_RESYNC_S then SendTimer(run) end
end

-- Every run ticks in its own thread: a block tick that waits (a wave spawning, a row being written) never
-- delays the timers and checks of the other runs. A run whose previous tick is still busy is skipped.
function Runs._tick()
    for _, run in ipairs(Runs.all()) do
        local nowMs = GetGameTimer()
        if run.ticking then
            if not run.tickStuckWarned and nowMs - (run.tickStartedAt or nowMs) > TICK_STUCK_MS then
                run.tickStuckWarned = true
                CP.warn(TAG, 'the tick of run %s has been busy for over %d s', tostring(run.id), TICK_STUCK_MS // 1000)
            end
        else
            run.ticking, run.tickStartedAt = true, nowMs
            CreateThread(function()
                local ok, err = pcall(TickRun, run, GetGameTimer())
                run.ticking = false
                if not ok then CP.err(TAG, 'tick of run %s failed: %s', tostring(run.id), tostring(err)) end
            end)
        end
    end
end

function Runs._jobRecheck()
    for _, run in ipairs(Runs.all()) do
        for _, src in ipairs(Runs.activeSrcs(run)) do
            if run.state == 'ended' then break end
            local p = run.participants[src]
            if p and p.status == 'active' then RecheckOk(run, p) end
        end
    end
end

local function Maintenance()
    local now = os.time()
    for id, e in pairs(endedRuns) do
        if now - e.at > ENDED_KEEP_S then endedRuns[id] = nil end
    end
    for cid, h in pairs(hourCache) do
        if now - h.at > HOURLY_CACHE_S * 6 then hourCache[cid] = nil end
    end
    for cid, c in pairs(cooldownCache) do
        if c.loaded and next(c.types) == nil and next(c.missions) == nil then
            local src = nil
            local ok, s = Call('Qbx', 'getByCitizenId', cid)
            if ok then src = s end
            if not src then cooldownCache[cid] = nil end
        end
    end
    for cid, o in pairs(orphans) do
        if now - o.at > ORPHAN_KEEP_S then
            orphans[cid] = nil
        else
            local ok, src = Call('Qbx', 'getByCitizenId', cid)
            src = ok and ToSrc(src) or nil
            if src and not Runs.isOnMission(src) then
                local cleared = CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table'
                    and CP.Alerts.foreignClearedAt[src]
                local due = now - (o.sweptAt or 0) >= 60
                    or (cleared and now - cleared >= 10 and (o.sweptAt or 0) < cleared + 10)
                if due then SweepPlayer(src, cid) end
            end
        end
    end
end

-- Faster reaction to an arena exit for players with orphaned items (10 s after the foreign flag cleared).
local function ArenaExitSweeps()
    if not (CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table') then return end
    local now = os.time()
    for cid, o in pairs(orphans) do
        local ok, src = Call('Qbx', 'getByCitizenId', cid)
        src = ok and ToSrc(src) or nil
        local cleared = src and CP.Alerts.foreignClearedAt[src]
        if cleared and now - cleared >= 10 and (o.sweptAt or 0) < cleared + 10 and not Runs.isOnMission(src) then
            SweepPlayer(src, cid)
        end
    end
end

CreateThread(function()
    local n = 0
    while true do
        Wait(1000)
        Runs._tick()
        n = n + 1
        if n % 5 == 0 and next(orphans) ~= nil then pcall(ArenaExitSweeps) end
    end
end)

CreateThread(function()
    while true do
        Wait(math.max(1, math.floor(Num(Config.AntiCheat and Config.AntiCheat.jobRecheck, 10))) * 1000)
        local ok, err = pcall(Runs._jobRecheck)
        if not ok then CP.err(TAG, 'job recheck failed: %s', tostring(err)) end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        local ok, err = pcall(Maintenance)
        if not ok then CP.err(TAG, 'maintenance failed: %s', tostring(err)) end
    end
end)

-- ============================================================================
--                      LEAVING THE SERVER, LOSING ACCESS
-- ============================================================================

local function DropFromRun(src, reason)
    local run = Runs.getBySrc(src)
    if run then Runs.removeParticipant(run, src, reason) end
end

AddEventHandler('playerDropped', function()
    local src = source
    src = ToSrc(src)
    if not src then return end
    DropFromRun(src, 'disconnected')
end)

local hooked = false
local function RegisterHooks()
    if hooked then return true end
    if not (CP.Access and CP.Access.onLost and CP.Qbx and CP.Qbx.onPlayerUnload) then return false end
    hooked = true
    CP.Access.onLost(function(src, endReason)
        src = ToSrc(src)
        local run, p = Runs.getBySrc(src)
        if not run then return end
        if run.test and not p.isOfficer then return end
        if not LOST_REASONS[endReason] then endReason = 'job_change' end
        -- Duty signals can be stale or superseded (INTEGRATIONS: SetDuty re-entrancy / ordering): an off-duty
        -- signal only removes the officer while the live check still agrees at this moment.
        if endReason == 'off_duty' and Has('Access', 'recheck') then
            local ok, qualifies, reason = Call('Access', 'recheck', src, p.job)
            if ok and qualifies ~= false then
                CP.log(TAG, 'off-duty signal for %d ignored: back on duty', src)
                return
            end
            if ok and LOST_REASONS[reason] then endReason = reason end
        end
        Runs.removeParticipant(run, src, endReason)
    end)
    CP.Qbx.onPlayerUnload(function(src)
        DropFromRun(ToSrc(src), 'disconnected')
    end)
    if CP.Qbx.onPlayerLoaded then
        CP.Qbx.onPlayerLoaded(function(src)
            src = ToSrc(src)
            if not src then return end
            SetTimeout(5000, function()
                local cid = CitizenOf(src)
                if cid then
                    Runs.cooldowns(cid)
                    if not Runs.isOnMission(src) then SweepPlayer(src, cid) end
                end
            end)
        end)
    end
    return true
end

CreateThread(function()
    Wait(0)
    for _ = 1, 60 do
        if RegisterItemHook() then break end
        Wait(1000)
    end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'ox_inventory' then return end
    itemHookId = nil                           -- a restarted ox_inventory drops its hooks
    SetTimeout(1000, RegisterItemHook)
end)

CreateThread(function()
    Wait(0)
    for _ = 1, 30 do
        if RegisterHooks() then break end
        Wait(1000)
    end
    if not hooked then
        CP.warn(TAG,
            'CP.Access.onLost / CP.Qbx.onPlayerUnload are not available: job and unload checks rely on the recheck loop')
    end
    -- Leftover mission items from a crash: sweep the players who are online now.
    Wait(15000)
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then
        for _, src in ipairs(list) do
            src = ToSrc(src)
            if src and not Runs.isOnMission(src) then
                local cid = CitizenOf(src)
                if cid then pcall(SweepPlayer, src, cid) end
            end
        end
    end
end)

-- ============================================================================
--               RESOURCE STOP: delete everything, write nothing
-- ============================================================================

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for id, run in pairs(runs) do
        run.state = 'ended'
        for _, src in ipairs(run.order) do
            local p = run.participants[src]
            if p and p.status == 'active' then pcall(RemoveItems, run, p) end
        end
        pcall(DeleteAllEntities, run)
        runs[id] = nil
    end
    bySrc = {}
end)
