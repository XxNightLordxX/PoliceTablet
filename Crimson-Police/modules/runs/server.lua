--[[ modules/runs/server.lua · CP.Runs (server): the run engine.

  Owns
    The run lifecycle (accepted -> in_progress -> ended), per-participant end reasons and results
    (ARCHITECTURE §4.3), the start timeout, abandon, cooldowns (in memory, rebuilt from cp_mission_runs
    after a restart), the server run caps, the run host and host succession, rescaling when the team
    shrinks, the mission timer, objective sequencing through the blocks (§7.1), every networked entity a
    run spawns (OneSync server natives, the `cp` state bag, caps, corpse cleanup), mission items
    (ox_inventory, tagged { cpRun, cpItem }, orphan sweeps), the cp_mission_runs row of every participant
    (points and cash breakdown JSON), telemetry (vehicle damage, pedestrian hits, lights and siren,
    weapons fired), the Active Mission view and the live-run summary. Test runs write nothing and start
    no cooldown. A resource stop deletes every entity and writes nothing.

  Public API (server, ARCHITECTURE §5.10)
    CP.Runs.create(opts) -> run|nil, errKey
        opts = { mission, locationIndex, missionType, members = { officer|src }, leaderSrc, operationId,
                 test = { adminSrc, useStartRoute, forcedTier, draft }|nil, isBoss }
    CP.Runs.get(runId) -> run|nil          CP.Runs.getBySrc(src) -> run, participant (active only)
    CP.Runs.all() -> { run, ... }          CP.Runs.isOnMission(src) -> boolean  (+ export IsOnMission)
    CP.Runs.capsOk(missionType) -> ok, errKey
    CP.Runs.cooldowns(citizenid) -> { types = { [type] = untilTs }, missions = { [id] = untilTs } }
    CP.Runs.onCooldown(citizenid, missionType, missionId) -> boolean, untilTs
    CP.Runs.completionsLastHour(citizenid) -> integer
    CP.Runs.markArrived(run, src)                              (hook from CP.Route)
    CP.Runs.removeParticipant(run, src, endReason, opts) -> rowId|nil   opts = { keepFlag, silent, notify }
    CP.Runs.reclassify(citizenid, runId, newEndReason) -> boolean      (hook from CP.Calls)
    CP.Runs.endRun(run, state, endReason)                      state 'completed'|'failed'
    CP.Runs.failRun(run, reasonKey)
    CP.Runs.objectiveComplete(run, index, data) -> boolean
    CP.Runs.dispatch(run, index, src, ev) -> ok, reason
    CP.Runs.entityDied(run, netId, killerSrc)
    CP.Runs.award(run, id, opts) / CP.Runs.penalize(run, id, opts)   opts = { src, count = 1, points }
    CP.Runs.adjustTimer(run, seconds) / pauseTimer(run, paused) / remaining(run) -> seconds|nil
    CP.Runs.spawnPed(run, opts) / spawnVehicle(run, opts) / spawnObject(run, opts) -> entity, netId
    CP.Runs.deleteEntity(run, netId) / entitiesFor(run, filter) -> list / canSpawn(run, n, armed) -> boolean
    CP.Runs.send(run, eventName, ...) / objectiveEvent(run, index, data) / hud(run, patch) / hudFor(run, src, patch)
    CP.Runs.view(run, src) -> ActiveMissionView (§9.4) / summary(run) -> LiveRun (§9.5)
    CP.Runs.isParticipant(run, src) / activeSrcs(run) -> { src... } / host(run) -> src
    CP.Runs.testSkip(run) / testRestart(run) / anchor(run) -> vec3    (test runs only)
    Internal (same slice, used by tests): CP.Runs._tick() one 1 s tick, CP.Runs._jobRecheck() one recheck pass
  Net
    callback 'getRun' -> ActiveMissionView|nil for the caller's run
    action   'server:abandon' (runId) -> removeParticipant(run, src, 'quit')
    event    'crimson-police:server:objective' (runId, index, evidence) -> CP.AntiCheat.checkEvent -> block onEvent
    event    'crimson-police:server:telemetry' (runId, kind, data)  kinds vehicle | ped_hit | lights_siren | weapon_fired
    client events sent: client:start, client:inProgress, client:objective, client:hud, client:tierChanged,
    client:hostChanged, client:participants, client:runEnded; push topic 'run' (view, or nil when it ended)
  Loops
    1 s: timers, the current objective's block tick, time limit, start timeouts, arena re-check, entity
    bookkeeping (vanished entities, wrecked vehicles, corpse cleanup after Config.Limits.corpseCleanup),
    host liveness, HUD refresh. Config.AntiCheat.jobRecheck s: CP.Access.recheck. 60 s: orphan item sweeps
    and cache pruning.

  Contract interpretations (details in docs/notes/engine_b.md)
    * ctx.award/penalize accept opts.points, a per-occurrence value hint kept in run.score.values[id]
      (blocks pass it for ids whose value comes from block settings, e.g. hostage_hit).
    * ctx.hud({ detail, value, max }) belongs to that objective's HUD entry; other keys (message, ...)
      are top-level HUD fields. The full objectives list is resent whenever it changes.
    * Objective entities are never deleted when their objective completes, only at run end.
    * An early ctx.complete() is refused and flags the run too_fast once per objective (not on tests).
    * Flagged rows keep their computed points and cash (held) so an approval can release them.
    * penalty_points stores the positive sum of the penalties; bonus_points the sum of the bonuses.
    * Engine-recorded personal ids: pedestrian_hit and lights_siren (penalize), weapons fired go to
      run.stats.weaponsFired / p.firedWeapon, vehicle damage to p.vehicle.
]]

CP.Runs = CP.Runs or {}
local Runs = CP.Runs
local U = CP.U
local TAG = 'runs'

local BOSS_ID = 'weekly_boss_kingpin'
local LIGHTS_MISSIONS = { beat_patrol = true, business_check = true }
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

-- ARCHITECTURE §4.3: end reason -> result, cooldowns.
local RESULT = {
    quit = 'abandoned', off_route = 'abandoned', start_timeout = 'abandoned', idle = 'abandoned',
    job_change = 'abandoned', off_duty = 'abandoned', suspended = 'abandoned',
    real_call_cancelled = 'abandoned', real_call = 'abandoned', force_recall = 'abandoned', cancelled = 'abandoned',
    downed = 'failed', disconnected = 'failed',
    completed = 'completed', time_limit = 'failed', mission_failed = 'failed',
}
local function set(list)
    local out = {}
    for _, v in ipairs(list) do out[v] = true end
    return out
end
local TYPE_COOLDOWN = set({ 'quit', 'off_route', 'start_timeout', 'idle', 'job_change', 'off_duty', 'suspended',
    'real_call_cancelled', 'downed', 'disconnected' })
local MISSION_COOLDOWN = set({ 'quit', 'off_route', 'start_timeout', 'idle', 'job_change', 'off_duty', 'suspended',
    'real_call_cancelled', 'downed', 'disconnected', 'completed', 'time_limit', 'mission_failed' })
local TELEMETRY_KINDS = set({ 'vehicle', 'ped_hit', 'lights_siren', 'weapon_fired' })
local LOST_REASONS = set({ 'off_duty', 'job_change', 'suspended' })   -- CP.Access.recheck / onLost reasons

local runs = {}          -- runId -> run (accepted or in_progress)
local bySrc = {}         -- src -> runId (active participants only)
local ctxCache = {}      -- runId -> { [objectiveIndex] = ctx }
local endedRuns = {}     -- runId -> { at, run }
local cooldownCache = {} -- citizenid -> { types = {}, missions = {}, loaded = bool }
local hourCache = {}     -- citizenid -> { n, at }
local orphans = {}       -- citizenid -> { names = { [item] = true }, at, sweptAt }
local warned = {}
local dbReady = false

-- ── small helpers ───────────────────────────────────────────────────────────
local function toSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

-- Call CP.<mod>.<fn>(...) when it exists; returns true plus its results, or false.
local function call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function db()
    if dbReady then return true end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    dbReady = true
    return true
end

local function playerOnline(src)
    return src and GetPlayerName(src) ~= nil
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function int(v, lo, hi)
    local n = math.floor(num(v, 0) + 0.0)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    return n
end

local function limits() return Config.Limits or {} end
local function abandonCooldown() return num(limits().abandonCooldown, 300) end
local function corpseCleanup() return num(limits().corpseCleanup, 30) end

local function isVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    if t ~= 'table' then return false end
    return type(v.x or v[1]) == 'number' and type(v.y or v[2]) == 'number' and type(v.z or v[3]) == 'number'
end

local function vec3Of(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function modelHash(model)
    if type(model) == 'number' then return math.tointeger(model) or math.floor(model) end
    if type(model) == 'string' and model ~= '' then return joaat(model) end
    return nil
end

local function label(key, vars)
    return CP.L(key, vars)
end

-- ── tiers ───────────────────────────────────────────────────────────────────
local function tierFor(n)
    if CP.Scaling and CP.Scaling.tierFor then return CP.Scaling.tierFor(n) end
    local rows = Config.Scaling or {}
    for i = 1, #rows do
        if num(rows[i].maxParticipants, 0) >= n then return rows[i] end
    end
    return rows[#rows]
end

local function tierByName(name)
    if name == nil then return nil end
    if CP.Scaling and CP.Scaling.tierByName then return CP.Scaling.tierByName(name) end
    for _, row in ipairs(Config.Scaling or {}) do
        if row.tier == name or row == name then return row end
    end
    return nil
end

local function lowerTier(a, b)
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

local function tierName(row)
    return type(row) == 'table' and row.tier or nil
end

local function forcedTier(run)
    return run.test and run.test.forcedTier and tierByName(run.test.forcedTier) or nil
end

-- ── participants ────────────────────────────────────────────────────────────
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
    src = toSrc(src)
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
    src = toSrc(src)
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

local function participantsList(run)
    local out = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if p then
            out[#out + 1] = {
                src = src, name = p.name, callsign = p.callsign, departmentShort = p.departmentShort or '',
                status = p.status, arrived = p.arrived == true,
            }
        end
    end
    return out
end

local function activeDepartments(run, extra)
    local seen, n = {}, 0
    local function add(d)
        if d and not seen[d] then seen[d] = true; n = n + 1 end
    end
    for _, s in ipairs(Runs.activeSrcs(run)) do add(run.participants[s].department) end
    if extra then add(extra.department) end
    return n, seen
end

local function refreshDepartments(run)
    local _, seen = activeDepartments(run)
    run.departments = seen
end

-- ── messaging ───────────────────────────────────────────────────────────────
local function eventName(name)
    if type(name) ~= 'string' then return nil end
    if U.startsWith(name, 'client:') then return CP.e(name) end
    return name
end

function Runs.send(run, name, ...)
    local ev = eventName(name)
    if type(run) ~= 'table' or not ev then return end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        TriggerClientEvent(ev, src, ...)
    end
end

function Runs.objectiveEvent(run, index, data)
    if type(run) ~= 'table' or run.state ~= 'in_progress' then return end
    Runs.send(run, 'client:objective', run.id, index, { action = 'update', data = data })
end

function Runs.hud(run, patch)
    if type(run) ~= 'table' or type(patch) ~= 'table' then return end
    Runs.send(run, 'client:hud', run.id, patch)
end

function Runs.hudFor(run, src, patch)
    src = toSrc(src)
    if type(run) ~= 'table' or not src or type(patch) ~= 'table' then return end
    TriggerClientEvent(CP.e('client:hud'), src, run.id, patch)
end

local function broadcastParticipants(run)
    Runs.send(run, 'client:participants', run.id, participantsList(run))
end

local function notify(src, kind, key, vars)
    if has('Tablet', 'notify') then call('Tablet', 'notify', src, kind, key, vars) end
end

-- Push topic 'run' (the view) to every active participant, or to the given list.
local function pushRun(run, srcs)
    if not has('Tablet', 'push') then return end
    for _, src in ipairs(srcs or Runs.activeSrcs(run)) do
        local ok, view = pcall(Runs.view, run, src)
        if ok then
            call('Tablet', 'push', src, 'run', view)
        else
            CP.err(TAG, 'view for %s failed: %s', tostring(src), tostring(view))
        end
    end
    run.pushedAt = GetGameTimer()
end

local function pushNone(src)
    if has('Tablet', 'push') then call('Tablet', 'push', src, 'run', nil) end
end

-- ── timer ───────────────────────────────────────────────────────────────────
local function syncTimer(run)
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
    syncTimer(run)
    return run.timer.remaining
end

local function timerPatch(run)
    local r = Runs.remaining(run)
    if r == nil then return false end
    return { remaining = math.max(0, math.ceil(r)), paused = run.timer.paused == true }
end

local function sendTimer(run)
    run.timerSentAt = os.time()
    Runs.hud(run, { timer = timerPatch(run) })
end

function Runs.adjustTimer(run, seconds)
    seconds = num(seconds, 0)
    if type(run) ~= 'table' or not run.timer or run.state == 'ended' or seconds == 0 then return end
    syncTimer(run)
    run.timer.remaining = math.max(0, run.timer.remaining + seconds)
    if not run.timer.running then
        run.timeLimit = math.max(0, math.floor(run.timer.remaining))
        return
    end
    CP.log(TAG, 'run %s timer %+d s -> %.1f s', run.id, seconds, run.timer.remaining)
    sendTimer(run)
end

function Runs.pauseTimer(run, paused)
    if type(run) ~= 'table' or not run.timer or run.state == 'ended' then return end
    syncTimer(run)
    run.timer.paused = paused == true
    run.timer.lastTick = GetGameTimer()
    if run.timer.running then sendTimer(run) end
end

-- ── blocks and ctx (ARCHITECTURE §7.1) ──────────────────────────────────────
local function blockOf(run, i)
    local o = run.objectives[i]
    local obj = (o and o.obj) or (run.mission.objectives or {})[i]
    if type(obj) ~= 'table' or type(obj.block) ~= 'string' then return nil end
    return CP.Blocks.get(obj.block)
end

local function pedCoords(src)
    src = toSrc(src)
    if not src then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local objectiveHud   -- forward declaration (defined with the HUD helpers below)

local function getCtx(run, i)
    local cache = ctxCache[run.id]
    if not cache then
        cache = {}
        ctxCache[run.id] = cache
    end
    local o = run.objectives[i]
    local ctx = cache[i]
    if not ctx then
        ctx = {
            run = run, index = i, mission = run.mission, location = run.location,
            base = (run.mission.objectives or {})[i],
            rng = U.rng((tonumber(run.seed) or 1) + i),
        }
        ctx.complete = function(data) return Runs.objectiveComplete(run, i, data) end
        ctx.fail = function(reasonKey) return Runs.failRun(run, reasonKey) end
        ctx.award = function(id, opts) return Runs.award(run, id, opts) end
        ctx.penalize = function(id, opts) return Runs.penalize(run, id, opts) end
        ctx.send = function(data) return Runs.objectiveEvent(run, i, data) end
        ctx.hud = function(patch) return objectiveHud(run, i, patch) end
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
        ctx.coords = function(src) return pedCoords(src) end
        ctx.combat = function(acc, armour)
            if CP.Scaling and CP.Scaling.combat then return CP.Scaling.combat(acc, armour, run.tier, run) end
            return acc, armour
        end
        ctx.isHost = function(src) return toSrc(src) == run.host end
        ctx.host = function() return run.host end
        cache[i] = ctx
    end
    ctx.obj = (o and o.obj) or ctx.base
    ctx.tier = run.tier
    ctx.state = o and o.state or {}
    return ctx
end

-- Call a block hook of objective i (pcall). Returns ok, results...
local function callBlock(run, i, hook, ...)
    local impl = blockOf(run, i)
    if not impl or type(impl[hook]) ~= 'function' then return false end
    local ctx = getCtx(run, i)
    local res = table.pack(pcall(impl[hook], ctx, ...))
    if not res[1] then
        CP.err(TAG, 'block %s.%s (run %s, objective %d) failed: %s', tostring(impl.id), hook, run.id, i, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

-- ── HUD objectives ──────────────────────────────────────────────────────────
local function objectiveLabel(run, i)
    local o = run.objectives[i]
    local obj = (o and o.obj) or (run.mission.objectives or {})[i] or {}
    local l = obj.label
    if type(l) == 'string' and l ~= '' then
        if CP.Locale and CP.Locale.has and CP.Locale.has(l) then return CP.L(l) end
        return l
    end
    return label('run.objective_default', { n = i })
end

local function checklistOf(run, i)
    local ok, items = callBlock(run, i, 'checklist')
    if ok and type(items) == 'table' then return items end
    return nil
end

local function applyChecklist(entry, items)
    if type(items) ~= 'table' or #items == 0 then return end
    local first = items[1]
    if type(first) == 'table' and type(first.max) == 'number' and first.max > 0 then
        entry.value = num(first.value, 0)
        entry.max = first.max
    end
    local extra = {}
    for k = 2, #items do
        local it = items[k]
        if type(it) == 'table' and it.label then
            if type(it.max) == 'number' and it.max > 0 then
                extra[#extra + 1] = ('%s %d/%d'):format(tostring(it.label), math.floor(num(it.value, 0)), math.floor(it.max))
            else
                extra[#extra + 1] = tostring(it.label)
            end
        end
    end
    if #extra > 0 then entry.detail = table.concat(extra, ' · ') end
end

-- HudState.objectives (§9.3). includePending: labels before the run is in progress (Active Mission).
local function hudObjectives(run, includePending)
    local out = {}
    local started = run.state == 'in_progress'
    if not started and not includePending then return out end
    for i = 1, #(run.mission.objectives or {}) do
        local o = run.objectives[i] or {}
        local entry = {
            label = objectiveLabel(run, i),
            done = o.status == 'done',
            current = started and i == run.objectiveIndex and o.status == 'active',
        }
        if started then
            if o.status == 'done' then
                applyChecklist(entry, o.final)
            elseif entry.current then
                applyChecklist(entry, checklistOf(run, i))
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

local function refreshHud(run, force)
    if run.state ~= 'in_progress' then return end
    local list = hudObjectives(run, false)
    local ok, key = pcall(json.encode, list)
    if not ok then key = tostring(GetGameTimer()) end
    if force or key ~= run.hudKey then
        run.hudKey = key
        Runs.hud(run, { objectives = list })
        if force or not run.pushedAt or GetGameTimer() - run.pushedAt >= PUSH_THROTTLE_MS then pushRun(run) end
    end
end

-- ctx.hud: detail/value/max belong to objective i's HUD entry; everything else is a top-level HUD patch.
objectiveHud = function(run, i, patch)
    if type(run) ~= 'table' or type(patch) ~= 'table' or run.state == 'ended' then return end
    local o = run.objectives[i]
    if not o then return end
    local rest, touched = {}, false
    for k, v in pairs(patch) do
        if k == 'detail' or k == 'value' or k == 'max' then
            o.hud = o.hud or {}
            if v == false then o.hud[k] = nil else o.hud[k] = v end
            touched = true
        else
            rest[k] = v
        end
    end
    if touched then refreshHud(run) end
    if next(rest) ~= nil then Runs.hud(run, rest) end
end

-- ── entities (ARCHITECTURE §6.1) ────────────────────────────────────────────
local function entityCounts(run)
    local total, armedAlive = 0, 0
    for _, e in pairs(run.entities) do
        total = total + 1
        if e.armed and not e.dead then
            local st
            if e.entity and DoesEntityExist(e.entity) then
                local bag = Entity(e.entity).state.cp
                st = type(bag) == 'table' and bag.state or nil
            end
            if st ~= 'cuffed' and st ~= 'dead' then armedAlive = armedAlive + 1 end
        end
    end
    return total, armedAlive
end

-- Spawns still waiting for their entity to exist count toward the caps too, so two spawns that interleave
-- (a block tick and a net event) can never pass the caps together.
local function pendingOf(run)
    local ps = run.pendingSpawns
    if not ps then
        ps = { total = 0, armed = 0 }
        run.pendingSpawns = ps
    end
    return ps
end

function Runs.canSpawn(run, n, armed)
    if type(run) ~= 'table' or run.state == 'ended' then return false end
    n = math.max(0, math.floor(num(n, 1)))
    local total, armedAlive = entityCounts(run)
    local ps = pendingOf(run)
    if total + ps.total + n > num(limits().maxEntities, 80) then return false end
    if armed and armedAlive + ps.armed + n > num(limits().maxArmedAlive, 25) then return false end
    return true
end

-- Run fn (which creates and tracks one entity) while it counts as a pending spawn.
local function withPending(run, armed, fn)
    local ps = pendingOf(run)
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

local function waitExists(entity)
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
local function sameHash(a, b)
    a, b = math.tointeger(tonumber(a) or 0), math.tointeger(tonumber(b) or 0)
    if not a or not b then return false end
    return (a & 0xFFFFFFFF) == (b & 0xFFFFFFFF)   -- signed or unsigned 32-bit forms
end

local function deleteWhenItAppears(entity, hash)
    if not entity or entity == 0 then return end
    CreateThread(function()
        local deadline = GetGameTimer() + LATE_SPAWN_MS
        while GetGameTimer() < deadline do
            if DoesEntityExist(entity) then
                if not hash or not GetEntityModel or sameHash(GetEntityModel(entity), hash) then
                    DeleteEntity(entity)
                    CP.log(TAG, 'late entity %s deleted', tostring(entity))
                end
                return
            end
            Wait(500)
        end
    end)
end

local function netIdOf(entity)
    local deadline = GetGameTimer() + SPAWN_WAIT_MS
    local netId = NetworkGetNetworkIdFromEntity(entity)
    while (not netId or netId == 0) and GetGameTimer() < deadline do
        Wait(0)
        netId = NetworkGetNetworkIdFromEntity(entity)
    end
    if not netId or netId == 0 then return nil end
    return netId
end

local function splitCoords(c)
    local x, y, z = U.xyz(c)
    if not x then return nil end
    local h = 0.0
    if type(c) == 'vector4' then h = c.w
    elseif type(c) == 'table' then h = tonumber(c.w or c[4] or c.heading) or 0.0 end
    return x + 0.0, y + 0.0, z + 0.0, h + 0.0
end

local function track(run, entity, kind, opts, extraCfg)
    if not waitExists(entity) then
        CP.warn(TAG, 'run %s: %s %s did not appear within %d ms', run.id, kind, tostring(opts.model), SPAWN_WAIT_MS)
        deleteWhenItAppears(entity, modelHash(opts.model))
        return nil
    end
    if run.state == 'ended' then
        DeleteEntity(entity)
        return nil
    end
    local netId = netIdOf(entity)
    if not netId then
        DeleteEntity(entity)
        CP.warn(TAG, 'run %s: %s %s got no network id', run.id, kind, tostring(opts.model))
        return nil
    end
    local cfg = {}
    if type(extraCfg) == 'table' then for k, v in pairs(extraCfg) do cfg[k] = v end end
    if type(opts.cfg) == 'table' then for k, v in pairs(opts.cfg) do cfg[k] = v end end
    local bag = {
        run = run.id, obj = opts.obj, role = opts.role, state = 'idle', armed = opts.armed == true,
        cfg = cfg, tag = opts.tag,
    }
    Entity(entity).state:set('cp', bag, true)
    run.entities[netId] = {
        entity = entity, kind = kind, obj = opts.obj, role = opts.role, armed = opts.armed == true,
        dead = false, deadAt = nil, tag = opts.tag, model = opts.model, missing = 0,
    }
    if run.state == 'ended' then
        Runs.deleteEntity(run, netId)
        return nil
    end
    return entity, netId
end

function Runs.spawnPed(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = modelHash(opts.model)
    local x, y, z, h = splitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnPed needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, opts.armed == true) then return nil end
    local entity, netId = withPending(run, opts.armed == true, function()
        local ped = CreatePed(4, hash, x, y, z, h, true, true)
        return track(run, ped, 'ped', opts, {
            weapon = opts.weapon, accuracy = opts.accuracy, armour = opts.armour, health = opts.health, model = opts.model,
        })
    end)
    if not entity then return nil end
    if opts.armed and opts.weapon then
        local w = modelHash(opts.weapon)
        if w then GiveWeaponToPed(entity, w, 250, false, true) end
    end
    local armour = num(opts.armour, 0)
    if armour > 0 then SetPedArmour(entity, math.floor(armour)) end
    CP.log(TAG, 'run %s: ped %s (%s) netId %d', run.id, tostring(opts.model), tostring(opts.role), netId)
    return entity, netId
end

-- Vehicle type for CreateVehicleServerSetter ('automobile' for every allowed mission model).
local VEHICLE_TYPES = { stockade = 'automobile', stockade3 = 'automobile' }

function Runs.spawnVehicle(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = modelHash(opts.model)
    local x, y, z, h = splitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnVehicle needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, false) then return nil end
    local entity, netId = withPending(run, false, function()
        local veh
        if CreateVehicleServerSetter then
            local vtype = opts.vehicleType or (type(opts.model) == 'string' and VEHICLE_TYPES[opts.model:lower()]) or 'automobile'
            veh = CreateVehicleServerSetter(hash, vtype, x, y, z, h)
        else
            veh = CreateVehicle(hash, x, y, z, h, true, true)
        end
        return track(run, veh, 'vehicle', opts, { model = opts.model })
    end)
    if not entity then return nil end
    if type(opts.plate) == 'string' and opts.plate ~= '' and SetVehicleNumberPlateText then
        SetVehicleNumberPlateText(entity, opts.plate:sub(1, 8))
    end
    return entity, netId
end

function Runs.spawnObject(run, opts)
    if type(run) ~= 'table' or run.state == 'ended' or type(opts) ~= 'table' then return nil end
    local hash = modelHash(opts.model)
    local x, y, z, h = splitCoords(opts.coords)
    if not hash or not x then
        CP.warn(TAG, 'run %s: spawnObject needs a model and coords', run.id)
        return nil
    end
    if not Runs.canSpawn(run, 1, false) then return nil end
    local entity, netId = withPending(run, false, function()
        local obj = CreateObjectNoOffset(hash, x, y, z, true, true, false)
        return track(run, obj, 'object', opts, { model = opts.model })
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
    if e.entity and DoesEntityExist(e.entity) then DeleteEntity(e.entity) end
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
            out[#out + 1] = { netId = netId, entity = e.entity, kind = e.kind, obj = e.obj, role = e.role,
                armed = e.armed, dead = e.dead, deadAt = e.deadAt, tag = e.tag }
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
        local k = toSrc(killerSrc)
        if k and run.participants[k] then
            run.stats.kills = run.stats.kills or {}
            run.stats.kills[k] = (run.stats.kills[k] or 0) + 1
        end
    elseif e.kind == 'vehicle' then
        run.stats.vehiclesWrecked = (run.stats.vehiclesWrecked or 0) + 1
    end
    CP.log(TAG, 'run %s: %s %d died (killer %s)', run.id, e.kind, netId, tostring(killerSrc))
    if run.state == 'in_progress' and e.obj and run.objectives[e.obj] then
        callBlock(run, e.obj, 'onEntityDead', netId, toSrc(killerSrc))
    end
end

-- Server-side health comes from the owner's sync data: a server-created entity reads 0 until a client has
-- created and synced it. A health of 0 therefore only counts after a positive value was seen once.
local function healthGone(e)
    local h = GetEntityHealth and tonumber(GetEntityHealth(e.entity)) or nil
    if not h then return false end
    if h > 0 then
        e.healthSeen = true
        return false
    end
    return e.healthSeen == true
end

local function vehicleWrecked(e)
    if GetVehicleEngineHealth and (tonumber(GetVehicleEngineHealth(e.entity)) or 0) <= -3999.0 then return true end
    return healthGone(e)
end

local function deleteAllEntities(run)
    for netId, e in pairs(run.entities) do
        run.entities[netId] = nil
        if e.entity and DoesEntityExist(e.entity) then DeleteEntity(e.entity) end
    end
end

local function entityBookkeeping(run)
    local died, gone, cleanup = {}, {}, {}
    local now = os.time()
    local pedDeathsByNpc = has('Npc', 'onDeath')
    for netId, e in pairs(run.entities) do
        if not e.entity or not DoesEntityExist(e.entity) then
            e.missing = (e.missing or 0) + 1
            if e.missing >= MISSING_TICKS then gone[#gone + 1] = netId end
        else
            e.missing = 0
            if not e.dead then
                if e.kind == 'vehicle' and vehicleWrecked(e) then
                    died[#died + 1] = netId
                elseif e.kind == 'ped' and not pedDeathsByNpc and healthGone(e) then
                    died[#died + 1] = netId
                end
            elseif e.deadAt and now - e.deadAt >= corpseCleanup() then
                cleanup[#cleanup + 1] = netId
            end
        end
    end
    for _, netId in ipairs(died) do Runs.entityDied(run, netId, nil) end
    for _, netId in ipairs(gone) do
        local e = run.entities[netId]
        if e then
            if not e.dead then
                CP.log(TAG, 'run %s: %s %d vanished; counted as dead', run.id, e.kind, netId)
                Runs.entityDied(run, netId, nil)
            end
            run.entities[netId] = nil
        end
    end
    for _, netId in ipairs(cleanup) do Runs.deleteEntity(run, netId) end
end

-- ── items (ox_inventory; docs/CRIMSON_ARENA.md rule 4) ──────────────────────
local function inventoryUp()
    return GetResourceState('ox_inventory') == 'started'
end

local function inArena(src)
    local ok, res = call('Alerts', 'inArena', src)
    return ok and res == true
end

local function addOrphan(citizenid, name)
    if not citizenid or not name then return end
    local o = orphans[citizenid]
    if not o then
        o = { names = {}, at = os.time(), sweptAt = 0 }
        orphans[citizenid] = o
    end
    o.names[name] = true
end

local function giveItems(run, p)
    local items = run.mission.items
    if type(items) ~= 'table' or #items == 0 then return end
    if not inventoryUp() then
        warnOnce('inv_give', 'ox_inventory is not started: mission items are not given')
        return
    end
    if inArena(p.src) then return end
    for _, it in ipairs(items) do
        local name = type(it) == 'table' and it.name or nil
        local count = math.max(1, math.floor(num(type(it) == 'table' and it.count, 1)))
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

local function slotList(result, name)
    if type(result) ~= 'table' then return {} end
    if result[1] ~= nil then return result end
    if type(result[name]) == 'table' then return result[name] end
    return {}
end

-- Remove every slot of `name` whose metadata matches `meta` (and passes keep()). Returns the count removed.
local function removeSlots(src, name, meta, skip)
    local ok, result = pcall(function() return exports.ox_inventory:Search(src, 'slots', name, meta) end)
    if not ok then
        CP.warn(TAG, 'ox_inventory Search failed for %d: %s', src, tostring(result))
        return 0, false
    end
    local removed = 0
    for _, slot in ipairs(slotList(result, name)) do
        if type(slot) == 'table' and slot.slot and not (skip and skip(slot)) then
            local count = math.floor(num(slot.count, 1))
            local okRm, success = pcall(function()
                return exports.ox_inventory:RemoveItem(src, name, count, nil, slot.slot)
            end)
            if okRm and success then removed = removed + count end
        end
    end
    return removed, true
end

local function removeItems(run, p)
    if not p.items or #p.items == 0 then return end
    local items = p.items
    p.items = {}
    local online = playerOnline(p.src) and inventoryUp() and not inArena(p.src)
    for _, it in ipairs(items) do
        local removed = 0
        if online then removed = removeSlots(p.src, it.name, { cpRun = run.id }) end
        if removed < it.count then
            addOrphan(p.citizenid, it.name)
            CP.log(TAG, 'run %s: %s of %dx %s not found on %s; kept for a later sweep', run.id, it.count - removed, it.count, it.name, tostring(p.citizenid))
        end
    end
end

local function activeRunIds()
    local ids = {}
    for id in pairs(runs) do ids[id] = true end
    return ids
end

local function missionItemNames()
    local names = {}
    local ok, defs = call('Missions', 'all')
    if ok and type(defs) == 'table' then
        for _, def in pairs(defs) do
            for _, it in ipairs(type(def.items) == 'table' and def.items or {}) do
                if type(it) == 'table' and type(it.name) == 'string' then names[it.name] = true end
            end
        end
    end
    return names
end

-- Remove Crimson-Police mission items (metadata.cpItem) of runs that are no longer active.
local function sweepPlayer(src, citizenid)
    if not playerOnline(src) or not inventoryUp() or inArena(src) then return false end
    local names = missionItemNames()
    local o = citizenid and orphans[citizenid]
    if o then for n in pairs(o.names) do names[n] = true end end
    local live = activeRunIds()
    local complete = true
    for name in pairs(names) do
        local _, ok = removeSlots(src, name, { cpItem = true }, function(slot)
            local meta = slot.metadata
            return type(meta) == 'table' and meta.cpRun ~= nil and live[meta.cpRun] == true
        end)
        if not ok then complete = false end
    end
    if o then
        o.sweptAt = os.time()
        if complete then orphans[citizenid] = nil end
    end
    return complete
end

local function citizenOf(src)
    local ok, info = call('Qbx', 'getInfo', src)
    return ok and type(info) == 'table' and info.citizenid or nil
end

-- ── cooldowns ───────────────────────────────────────────────────────────────
local function cdEntry(citizenid)
    local c = cooldownCache[citizenid]
    if not c then
        c = { types = {}, missions = {}, loaded = false }
        cooldownCache[citizenid] = c
    end
    return c
end

local function missionCooldownOf(missionId)
    local ok, def = call('Missions', 'get', missionId)
    if ok and type(def) == 'table' then return num(def.cooldown, 0) end
    return 0
end

local function rebuildWindow()
    local window = abandonCooldown()
    local ok, defs = call('Missions', 'all')
    if ok and type(defs) == 'table' then
        for _, def in pairs(defs) do
            local c = num(def.cooldown, 0)
            if c > window then window = c end
        end
    end
    return math.max(60, math.floor(window))
end

local function loadCooldowns(citizenid)
    local c = cdEntry(citizenid)
    if c.loaded then return c end
    if c.loading then
        -- Another caller is rebuilding right now: wait for it instead of answering from a half-built cache.
        local deadline = GetGameTimer() + COOLDOWN_LOAD_WAIT_MS
        while c.loading and GetGameTimer() < deadline do Wait(50) end
        return c
    end
    c.loading = true
    db()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT mission_type, mission_id, end_reason, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_mission_runs
        WHERE citizenid = ? AND created_at >= NOW() - INTERVAL ? SECOND
          AND mission_type NOT IN ('manual_award', 'goal')
    ]], { citizenid, rebuildWindow() })
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
            local untilTs = ts + missionCooldownOf(row.mission_id)
            if untilTs > (c.missions[row.mission_id] or 0) then c.missions[row.mission_id] = untilTs end
        end
        if TYPE_COOLDOWN[reason] and row.mission_id ~= BOSS_ID then
            local untilTs = ts + abandonCooldown()
            if untilTs > (c.types[row.mission_type] or 0) then c.types[row.mission_type] = untilTs end
        end
    end
    CP.log(TAG, 'cooldowns of %s rebuilt from %d row(s)', tostring(citizenid), #(rows or {}))
    return c
end

function Runs.cooldowns(citizenid)
    local out = { types = {}, missions = {} }
    if type(citizenid) ~= 'string' or citizenid == '' then return out end
    local c = loadCooldowns(citizenid)
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

local function applyCooldowns(run, p, endReason)
    if run.test or not p.citizenid then return end
    local c = cdEntry(p.citizenid)
    local now = os.time()
    if MISSION_COOLDOWN[endReason] then
        local secs = num(run.mission.cooldown, 0)
        if secs > 0 then
            local untilTs = now + math.floor(secs)
            if untilTs > (c.missions[run.missionId] or 0) then c.missions[run.missionId] = untilTs end
        end
    end
    if TYPE_COOLDOWN[endReason] and not run.isBoss then
        local untilTs = now + math.floor(abandonCooldown())
        if untilTs > (c.types[run.missionType] or 0) then c.types[run.missionType] = untilTs end
    end
end

function Runs.completionsLastHour(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    local cached = hourCache[citizenid]
    local now = os.time()
    if cached and now - cached.at < HOURLY_CACHE_S then return cached.n end
    db()
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

-- ── caps ────────────────────────────────────────────────────────────────────
function Runs.capsOk(missionType)
    local total, tactical = 0, 0
    for _, run in pairs(runs) do
        if run.state ~= 'ended' and not run.test and not run.operationId then
            total = total + 1
            if run.missionType == 'tactical' then tactical = tactical + 1 end
        end
    end
    if total >= num(limits().maxConcurrentRuns, 12) then return false, 'err.server_busy' end
    local isTactical = missionType == 'tactical' or missionType == 'weekly_boss'
    if isTactical and tactical >= num(limits().maxConcurrentTactical, 4) then return false, 'err.server_busy' end
    return true
end

-- ── scoring, cash and the row ───────────────────────────────────────────────
local function objectivesProgress(run)
    local total = #(run.mission.objectives or {})
    local done = 0
    for i = 1, total do
        local o = run.objectives[i]
        if o and o.status == 'done' then done = done + 1 end
    end
    return done, total
end

local function computePoints(run, p, result, opts)
    local ok, bd = call('Scoring', 'compute', run, p, result, opts)
    if not ok or type(bd) ~= 'table' then
        if not has('Scoring', 'compute') then warnOnce('scoring', 'CP.Scoring.compute is not available: rows get 0 points') end
        bd = {
            P = run.pointsBase or 0, bonuses = {}, penalties = {}, subtotal = 0, mTeam = 1.0, mCross = 1.0,
            mStreak = 1.0, capped = false, tod = false, failedShare = opts.failedShare, final = 0,
        }
    end
    if type(bd.bonuses) ~= 'table' then bd.bonuses = {} end
    if type(bd.penalties) ~= 'table' then bd.penalties = {} end
    bd.P = num(bd.P, run.pointsBase or 0)
    local final = math.floor(num(bd.final, 0))
    if final < 0 or result == 'abandoned' then final = 0 end
    bd.final = final
    return bd
end

local function computeCash(run, p, result)
    local ok, amount, cb = call('Cash', 'compute', run, p)
    local payTier = run.payTier or tierByName(run.expectedTier)
    if not ok then
        if not has('Cash', 'compute') then warnOnce('cash', 'CP.Cash.compute is not available: rows pay $0') end
        amount, cb = 0, nil
    end
    if type(cb) ~= 'table' then
        cb = {
            B = run.cashBase or 0,
            mTier = payTier and num(payTier.cash, 1.0) or 1.0,
            mMod = run.modifier and num(Config.Events and Config.Events.modifierCash, 1.0) or 1.0,
        }
    end
    local amt = math.floor(num(cb.amount, num(amount, 0)) + 0.5)
    if result ~= 'completed' or amt < 0 then amt = 0 end
    cb.amount = amt
    cb.B = num(cb.B, run.cashBase or 0)
    cb.mTier = num(cb.mTier, 1.0)
    cb.mMod = num(cb.mMod, 1.0)
    return amt, cb
end

local function sumPoints(list, abs)
    local s = 0
    for _, e in ipairs(list or {}) do
        local v = num(type(e) == 'table' and e.points, 0)
        if abs then v = math.abs(v) end
        s = s + v
    end
    return math.floor(s + 0.5)
end

local function departmentAtEnd(p)
    local ok, info = call('Qbx', 'getInfo', p.src)
    if ok and type(info) == 'table' and info.citizenid == p.citizenid and type(info.job) == 'table' then
        local okD, dept = call('Access', 'departmentForJob', info.job.name)
        if okD and dept then return dept end
    end
    return p.department
end

local INSERT_COLUMNS = {
    'run_uuid', 'operation_id', 'mission_type', 'mission_id', 'mission_version', 'location_label', 'citizenid',
    'department', 'season_id', 'participants', 'departments_n', 'tier', 'modifier', 'state', 'end_reason',
    'points_base', 'bonus_points', 'penalty_points', 'final_points', 'cash_base', 'cash_multiplier', 'cash_paid',
    'cash_status', 'duration_s', 'breakdown', 'flagged', 'flag_reason',
}

-- NULL literals for nil values so the parameter list never has holes.
local function insertRow(row)
    db()
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
    local sql = ('INSERT INTO cp_mission_runs (%s) VALUES (%s)'):format(table.concat(INSERT_COLUMNS, ', '), table.concat(values, ', '))
    local ok, id = pcall(MySQL.insert.await, sql, params)
    if not ok then
        CP.err(TAG, 'row insert failed for %s (run %s): %s', tostring(row.citizenid), tostring(row.run_uuid), tostring(id))
        return nil
    end
    return tonumber(id)
end

local function readCashStatus(rowId)
    local ok, row = pcall(MySQL.single.await, 'SELECT cash_status, cash_paid FROM cp_mission_runs WHERE id = ?', { rowId })
    if ok and type(row) == 'table' then return row.cash_status, math.floor(U.num(row.cash_paid)) end
    return nil
end

local function storeCashStatus(rowId, status)
    pcall(MySQL.update.await, "UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.status', ?) WHERE id = ? AND breakdown IS NOT NULL", { status, rowId })
end

-- Work out one participant's result (RunResult §9.6), write the row, pay, fire the hooks.
-- others = srcs still active at this moment (excluding p). Returns rowId|nil, runResult.
local function settle(run, p, result, endReason, others)
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
    local done, total = objectivesProgress(run)
    local endTs = run.endedAt or os.time()
    local duration = run.startedAt and math.max(0, endTs - run.startedAt) or 0
    local opts = {
        objectivesDone = done, objectivesTotal = total,
        failedShare = result == 'failed' and (total > 0 and done / total or 0) or nil,
        durationS = duration, participants = team, departments = nDepts, endReason = endReason,
    }
    local points = computePoints(run, p, result, opts)

    if (result == 'completed' or result == 'failed') and #run.order >= 2 and has('AntiCheat', 'presenceOk') then
        local ok, present = call('AntiCheat', 'presenceOk', run, p)
        if ok and present == false and not p.flagged then
            -- Through CP.AntiCheat.flag so the flag is audited and posted like every other one (the Review
            -- Queue reads its detail there); the local record is the fallback and the test-run preview.
            if not run.test and has('AntiCheat', 'flag') then
                local okS, share = call('AntiCheat', 'presenceShare', p)
                local detail = ('%s in range for %s of the run (needs %d%%)'):format(tostring(p.name or p.citizenid),
                    (okS and tonumber(share)) and ('%d%%'):format(math.floor(tonumber(share) * 100 + 0.5)) or '?',
                    math.floor(num(Config.AntiCheat and Config.AntiCheat.presenceShare, 0.70) * 100 + 0.5))
                call('AntiCheat', 'flag', run, p.src, 'presence', detail)
            end
            if not p.flagged then p.flagged = { reason = 'presence' } end
        end
    end

    local amount, cash = computeCash(run, p, result)
    local flag = p.flagged or run.flagged
    local isTest = run.test ~= nil
    local status = 'none'
    if not isTest and flag and result == 'completed' then status = 'held' end
    cash.status = status

    local payTier = run.payTier or tierByName(run.expectedTier)
    local rr = {
        runId = run.id, missionLabel = run.mission.label, missionType = run.missionType,
        result = result, endReason = endReason, test = isTest,
        tier = tierName(run.tier) or run.expectedTier, payTier = tierName(payTier) or run.expectedTier,
        participants = team, departments = nDepts, durationS = duration,
        points = points, cash = cash,
        flagged = flag and { reason = tostring(flag.reason or 'flagged') } or nil,
        failReason = (endReason == 'mission_failed' and run.failReason) or nil,
    }
    if isTest then return nil, rr end

    local seasonId = nil
    local okS, season = call('Challenge', 'currentSeason')
    if okS and type(season) == 'table' then seasonId = tonumber(season.id) end

    local okJ, breakdownJson = pcall(json.encode, U.serialize(rr))
    local row = {
        run_uuid = run.id,
        operation_id = tonumber(run.operationId),
        mission_type = U.clip(run.missionType, 32),
        mission_id = U.clip(run.missionId, 40),
        mission_version = tonumber(run.version) and int(run.version, -32768, 32767) or nil,
        location_label = U.clip(run.location and run.location.label or nil, 64),
        citizenid = U.clip(p.citizenid, 50),
        department = U.clip(departmentAtEnd(p) or 'unknown', 32),
        season_id = seasonId,
        participants = int(team, 1, 127),
        departments_n = int(nDepts, 1, 127),
        tier = tierName(payTier) or 'standard',
        modifier = U.clip(run.modifier, 20),
        state = result,
        end_reason = U.clip(endReason, 24),
        points_base = int(points.P, -32768, 32767),
        bonus_points = int(sumPoints(points.bonuses, false), -32768, 32767),
        penalty_points = int(sumPoints(points.penalties, true), -32768, 32767),
        final_points = int(points.final, 0, 32767),
        cash_base = int(cash.B, 0, 2147483647),
        cash_multiplier = math.floor(U.clamp(cash.mTier * cash.mMod, 0, 99.99) * 100 + 0.5) / 100,
        cash_paid = 0,
        cash_status = status,
        duration_s = int(duration, 0, 32767),
        breakdown = okJ and breakdownJson or nil,
        flagged = flag and 1 or 0,
        flag_reason = flag and U.clip(tostring(flag.reason or 'flagged'), 64) or nil,
    }
    local rowId = insertRow(row)
    p.rowId = rowId
    if not rowId then return nil, rr end
    row.id = rowId
    if result == 'completed' then hourCache[p.citizenid] = nil end

    if result == 'completed' and not flag and amount > 0 and has('Cash', 'pay') then
        call('Cash', 'pay', rowId)
        local st, paid = readCashStatus(rowId)
        if st then
            cash.status = st
            cash.paid = paid
            row.cash_status, row.cash_paid = st, paid
            if st ~= status then storeCashStatus(rowId, st) end
        end
    end
    if (result == 'completed' or result == 'failed') and not flag then
        call('Scoring', 'onRowCounted', p.citizenid, row)
        if result == 'completed' then call('Goals', 'onRunCompleted', p.citizenid) end
    end
    if result == 'completed' or result == 'abandoned' then
        call('Draw', 'recordLast', p.citizenid, run.missionType, run.missionId)
    end
    return rowId, rr
end

-- ── lifecycle helpers ───────────────────────────────────────────────────────
local function responsive(src)
    if not playerOnline(src) then return false end
    if GetPlayerLastMsg then return num(GetPlayerLastMsg(src), 0) <= HOST_STALE_MS end
    return true
end

-- Host succession follows the join order. needFresh: only hand over to a responsive participant.
local function migrateHost(run, reason, needFresh)
    local current = run.host
    local candidates = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if p and p.status == 'active' and src ~= current then candidates[#candidates + 1] = src end
    end
    local stillOk = current and run.participants[current] and run.participants[current].status == 'active'
    local pick = nil
    for _, src in ipairs(candidates) do
        if responsive(src) then pick = src; break end
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

local function stopObjectives(run)
    for i = 1, #(run.mission.objectives or {}) do
        local o = run.objectives[i]
        if o and o.prepared and not o.stopped then
            o.stopped = true
            callBlock(run, i, 'stop')
        end
    end
end

local function unlockUnit(run)
    if run.test or not run.unit then return end
    call('Units', 'unlock', run.unit)
end

-- Delete everything the run owns (entities, reservation) and forget it. Participants still active
-- are handled by the caller.
local function cleanupRun(run)
    stopObjectives(run)
    deleteAllEntities(run)
    call('Draw', 'release', run.id)
    runs[run.id] = nil
    ctxCache[run.id] = nil
    endedRuns[run.id] = { at = os.time(), run = run }
end

local function afterRunEnded(run, state)
    unlockUnit(run)
    if run.operationId then call('Operations', 'onRunEnded', run, state) end
    if run.test then call('Testing', 'onRunEnded', run, state, run.endReason) end
    if not run.test then call('Leaderboard', 'invalidate') end
end

-- Rescale for the team that is left: tier (counts) and pay tier can only go down.
local function rescale(run, endReason)
    if run.state ~= 'in_progress' then
        if run.state == 'accepted' and not forcedTier(run) then
            local n = #Runs.activeSrcs(run)
            local old = run.expectedTier
            if n > 0 then run.expectedTier = tierName(tierFor(n)) or run.expectedTier end
            if run.expectedTier ~= old then
                Runs.send(run, 'client:tierChanged', run.id, run.expectedTier, run.expectedTier)
            end
        end
        return
    end
    if forcedTier(run) then return end
    local n = #Runs.activeSrcs(run)
    if n <= 0 then return end
    local newTier = tierFor(n)
    local rescaleCfg = Config.Rescale or {}
    local oldTier, oldPay = run.tier, run.payTier
    if rescaleCfg.enabled ~= false then run.tier = lowerTier(run.tier, newTier) end
    local keep = U.contains(rescaleCfg.keepPayTierFor or {}, endReason)
    if not keep then run.payTier = lowerTier(run.payTier, newTier) end
    local tierChanged = tierName(oldTier) ~= tierName(run.tier)
    local payChanged = tierName(oldPay) ~= tierName(run.payTier)
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
                callBlock(run, i, 'rescale')
                if run.state == 'ended' then return end
            end
        end
        run.scaled = scaled
    end
    if tierChanged or payChanged then
        CP.log(TAG, 'run %s: tier %s -> %s, pay tier %s -> %s (%s)', run.id, tostring(tierName(oldTier)), tostring(tierName(run.tier)),
            tostring(tierName(oldPay)), tostring(tierName(run.payTier)), endReason)
        Runs.send(run, 'client:tierChanged', run.id, tierName(run.tier), tierName(run.payTier), tierChanged and run.scaled or nil)
    end
end

-- ── create ──────────────────────────────────────────────────────────────────
local function memberOfficer(m)
    if type(m) == 'table' then return m end
    local src = toSrc(m)
    if not src then return nil end
    local ok, officer = call('Access', 'getOfficer', src)
    if ok and type(officer) == 'table' then return officer end
    local okI, info = call('Qbx', 'getInfo', src)
    if okI and type(info) == 'table' then
        return { src = src, citizenid = info.citizenid, name = info.name, callsign = info.callsign,
            rank = info.job and info.job.gradeName, job = info.job and info.job.name }
    end
    return nil
end

local function baseCash(mission, missionType, isBoss)
    local ok, b = call('Payouts', 'baseFor', mission)
    if ok and tonumber(b) then return math.max(0, math.floor(tonumber(b) + 0.5)) end
    warnOnce('payouts', 'CP.Payouts.baseFor is not available: using the config payouts')
    if isBoss then return math.floor(num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.payout, 0)) end
    local t = Config.MissionTypes and Config.MissionTypes[missionType]
    local stars = (Config.Difficulty and Config.Difficulty.cashByStars or {})[mission.difficulty or 1] or 1.0
    return math.floor(num(t and t.payout, 0) * stars + 0.5)
end

local function basePoints(mission, missionType, isBoss)
    local ok, P = call('Scoring', 'P', mission)
    if ok and tonumber(P) then return tonumber(P) end
    if isBoss then return num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.points, 0) end
    local t = Config.MissionTypes and Config.MissionTypes[missionType]
    local stars = (Config.Difficulty and Config.Difficulty.pointsByStars or {})[mission.difficulty or 1] or 1.0
    return num(t and t.points, 0) * stars
end

function Runs.create(opts)
    if type(opts) ~= 'table' or type(opts.mission) ~= 'table' then return nil, 'err.invalid_mission' end
    local mission = opts.mission
    if type(mission.id) ~= 'string' or type(mission.objectives) ~= 'table' or #mission.objectives == 0 then
        return nil, 'err.invalid_mission'
    end
    local locationIndex = math.tointeger(tonumber(opts.locationIndex) or -1)
    local location = locationIndex and type(mission.locations) == 'table' and mission.locations[locationIndex]
    if type(location) ~= 'table' or type(location.start) ~= 'table' or not isVec(location.start.coords) then
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
        local o = memberOfficer(m)
        local src = o and toSrc(o.src)
        if not src or not o.citizenid then return nil, 'err.member_unavailable' end
        if not seen[src] then
            seen[src] = true
            if Runs.isOnMission(src) then
                return nil, (src == toSrc(opts.leaderSrc)) and 'err.already_on_run' or 'err.member_on_run'
            end
            if inArena(src) then return nil, 'err.in_arena' end
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
    local leader = toSrc(opts.leaderSrc)
    if not leader or not seen[leader] then leader = toSrc(officers[1].src) end

    local run = {
        id = id, mission = mission, missionId = mission.id, missionType = missionType,
        isBoss = isBoss, version = mission.source == 'custom' and mission.version or nil,
        locationIndex = locationIndex, location = location,
        state = 'accepted', test = test, operationId = opts.operationId,
        seed = seed, host = leader, leader = leader,
        participants = {}, order = {},
        expectedTier = nil, tier = nil, payTier = nil, modifier = nil,
        cashBase = 0, pointsBase = 0, departments = {},
        acceptedAt = now, startedAt = nil, endedAt = nil,
        timeLimit = math.floor(num(mission.timeLimit, 600)),
        timer = { remaining = 0, paused = false, lastTick = nil, running = false },
        objectiveIndex = 1, objectives = {}, shared = {}, entities = {},
        stats = { downs = 0, weaponsFired = 0 },
        score = { shared = {}, values = {}, kinds = {} },
        flags = { medals = false }, flagged = nil,
        reserved = { missionId = mission.id, locationIndex = locationIndex },
        startTimeout = math.floor(num(mission.startTimeout, num(limits().startTimeout, 600))),
        pedHits = {},
    }
    for i = 1, #mission.objectives do
        run.objectives[i] = { status = 'pending', state = {} }
    end

    local forced = test and test.forcedTier and tierByName(test.forcedTier)
    run.expectedTier = tierName(forced) or tierName(tierFor(#officers)) or 'standard'

    for _, o in ipairs(officers) do
        local src = toSrc(o.src)
        local okF, first = call('Scoring', 'isFirstRunSinceDuty', src)
        run.participants[src] = {
            src = src, citizenid = o.citizenid, name = U.clip(o.name, 64), callsign = o.callsign and U.clip(o.callsign, 32) or nil,
            rank = o.rank, department = o.department, departmentShort = o.departmentShort, job = o.job,
            isOfficer = o.department ~= nil and o.job ~= nil,
            status = 'active', joinedAt = now, arrived = false, arrivedAt = nil,
            endReason = nil, result = nil, rowId = nil,
            score = {},
            vehicle = { lastNetId = nil, engine = 1000.0, body = 1000.0, seen = false },
            presence = { inRange = 0, total = 0 },
            lastEvent = nil, flagged = nil,
            firstRunSinceDuty = okF and first == true or false,
            items = {},
            deadline = now + run.startTimeout,
            telemetry = { lights = false, weapon = false, pedHits = 0, vehicleAt = nil },
        }
        run.order[#run.order + 1] = src
    end
    refreshDepartments(run)

    -- Economy locked at accept.
    run.cashBase = baseCash(mission, missionType, isBoss)
    run.pointsBase = basePoints(mission, missionType, isBoss)
    if not test and not opts.operationId and not isBoss then
        local ok, key = call('Events', 'rollModifier', run)
        if ok and type(key) == 'string' then run.modifier = key end
    end
    if run.modifier == 'time_crunch' then
        local cut = num(Config.Events and Config.Events.timeCrunchCut, 0.25)
        run.timeLimit = math.max(1, U.round(run.timeLimit * (1 - cut)))
    end
    run.timer.remaining = run.timeLimit

    local okU, unit = call('Units', 'unitOf', leader)
    if okU and type(unit) == 'table' then run.unit = unit end

    -- The lookups above may yield (database, other modules). Re-check, with no yield until the run is
    -- registered, what another accept could have changed meanwhile: nobody ends up on two runs and two
    -- racing accepts never pass the server caps together.
    for _, src in ipairs(run.order) do
        if Runs.isOnMission(src) then
            return nil, (src == leader) and 'err.already_on_run' or 'err.member_on_run'
        end
    end
    if not test and not opts.operationId then
        local okCaps, capsErr = Runs.capsOk(missionType)
        if not okCaps then return nil, capsErr end
    end

    runs[id] = run
    for _, src in ipairs(run.order) do bySrc[src] = id end
    call('Draw', 'reserve', id, mission.id, locationIndex)

    for _, src in ipairs(run.order) do giveItems(run, run.participants[src]) end

    local clientMission = U.copy(mission)
    clientMission.locations = nil
    local startRoute = not (test and test.useStartRoute == false)
    local data = {
        missionId = mission.id, mission = clientMission, locationIndex = locationIndex, location = location,
        start = { coords = location.start.coords, radius = location.start.radius },
        expectedTier = run.expectedTier, seed = seed, host = run.host, test = test, modifier = run.modifier,
        participants = participantsList(run), startRoute = startRoute, startTimeout = run.startTimeout,
        isBoss = isBoss, timeLimit = run.timeLimit,
    }
    for _, src in ipairs(run.order) do
        TriggerClientEvent(CP.e('client:start'), src, id, data)
        call('Route', 'begin', run, src)
        notify(src, 'info', 'run.accepted', { mission = mission.label or mission.id })
    end
    CP.log(TAG, 'run %s created: %s #%d (%s, %d participant(s), expected %s, modifier %s%s)', id, mission.id,
        locationIndex, missionType, #run.order, run.expectedTier, tostring(run.modifier), test and ', test' or '')
    pushRun(run)
    return run
end

-- ── In progress ─────────────────────────────────────────────────────────────
local function startObjective(run, i)
    local o = run.objectives[i]
    if not o or run.state ~= 'in_progress' then return end
    run.objectiveIndex = i
    o.status = 'active'
    o.startedAt = os.time()
    o.startedAtMs = GetGameTimer()
    Runs.send(run, 'client:objective', run.id, i, { action = 'start' })
    callBlock(run, i, 'start')
    if run.state ~= 'in_progress' then return end
    refreshHud(run, true)
end

local function startRun(run)
    if run.state ~= 'accepted' then return end
    run.state = 'in_progress'
    run.startedAt = os.time()
    local active = Runs.activeSrcs(run)
    local tier = forcedTier(run) or tierFor(math.max(1, #active))
    run.tier, run.payTier = tier, tier
    local scaled
    if CP.Scaling and CP.Scaling.apply then
        local ok, list = pcall(CP.Scaling.apply, run.mission, tier)
        if ok and type(list) == 'table' then scaled = list else CP.err(TAG, 'CP.Scaling.apply failed: %s', tostring(list)) end
    end
    scaled = scaled or U.deepcopy(run.mission.objectives)
    run.scaled = scaled
    for i = 1, #run.mission.objectives do
        run.objectives[i].obj = scaled[i] or run.mission.objectives[i]
    end
    run.timer = { remaining = run.timeLimit, paused = false, lastTick = GetGameTimer(), running = false }
    Runs.send(run, 'client:inProgress', run.id, {
        tier = tierName(tier), payTier = tierName(tier), objectives = scaled,
        timeLimit = run.timeLimit, remaining = run.timeLimit,
    })
    CP.log(TAG, 'run %s in progress at tier %s (%d participant(s))', run.id, tostring(tierName(tier)), #active)
    for i = 1, #run.mission.objectives do
        run.objectives[i].prepared = true
        Runs.send(run, 'client:objective', run.id, i, { action = 'prepare' })
        callBlock(run, i, 'prepare')
        if run.state ~= 'in_progress' then return end
    end
    run.timer.lastTick = GetGameTimer()
    run.timer.running = true
    sendTimer(run)
    startObjective(run, 1)
end

function Runs.markArrived(run, src)
    src = toSrc(src)
    if type(run) ~= 'table' or not src or run.state == 'ended' then return end
    local p = run.participants[src]
    if not p or p.status ~= 'active' or p.arrived then return end
    p.arrived = true
    p.arrivedAt = os.time()
    call('Alerts', 'set', src, run)
    Runs.hudFor(run, src, { route = { status = 'arrived', distance = 0 } })
    CP.log(TAG, 'run %s: %d arrived at the start', run.id, src)
    local first = run.state == 'accepted'
    if first then startRun(run) end
    if run.state == 'ended' then return end
    broadcastParticipants(run)
    if not first then pushRun(run) end
end

-- ── objectives ──────────────────────────────────────────────────────────────
local function completeObjective(run, index, data, bypass)
    if type(run) ~= 'table' or run.state ~= 'in_progress' then return false end
    index = math.tointeger(tonumber(index) or -1)
    if index ~= run.objectiveIndex then return false end
    local o = run.objectives[index]
    if not o or o.status ~= 'active' then return false end
    if not bypass then
        local obj = o.obj or {}
        local minSec = num(obj.minSeconds, 0)
        local elapsed = (GetGameTimer() - (o.startedAtMs or GetGameTimer())) / 1000
        if elapsed < minSec then
            if not o.tooFastFlagged and not run.test and elapsed < minSec - 1 then
                o.tooFastFlagged = true
                local detail = ('objective %d after %.1f s (min %d s)'):format(index, elapsed, minSec)
                CP.log(TAG, 'run %s: %s: too_fast', run.id, detail)
                if has('AntiCheat', 'flag') then
                    call('AntiCheat', 'flag', run, nil, 'too_fast', detail)
                elseif not run.flagged then
                    run.flagged = { reason = 'too_fast', detail = detail }
                end
            end
            return false
        end
    end
    o.final = checklistOf(run, index)
    o.status = 'done'
    o.doneAt = os.time()
    o.data = data
    o.hud = nil
    if not o.stopped then
        o.stopped = true
        Runs.send(run, 'client:objective', run.id, index, { action = 'stop' })
        callBlock(run, index, 'stop')
    end
    if run.state ~= 'in_progress' then return true end
    CP.log(TAG, 'run %s objective %d done', run.id, index)
    Runs.hud(run, { message = { text = label('run.objective_complete', { label = objectiveLabel(run, index) }), kind = 'success' } })
    if index < #run.mission.objectives then
        startObjective(run, index + 1)
    else
        Runs.endRun(run, 'completed', 'completed')
    end
    return true
end

function Runs.objectiveComplete(run, index, data)
    return completeObjective(run, index, data, false)
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
    local impl = blockOf(run, index)
    if not impl or type(impl.onEvent) ~= 'function' then return false, 'no_handler' end
    local ok, res, reason = callBlock(run, index, 'onEvent', toSrc(src), ev)
    if not ok then return false, 'error' end
    if res == false then return false, reason end
    return true
end

local function timeout(run)
    local i = run.objectiveIndex
    local o = run.objectives[i]
    local ok, res = callBlock(run, i, 'onTimeout')
    if run.state ~= 'in_progress' then return end
    if ok and res == 'completed' and o and o.status == 'active' then
        CP.log(TAG, 'run %s: time limit reached, objective %d completes on timeout', run.id, i)
        o.final = checklistOf(run, i)
        o.status = 'done'
        o.doneAt = os.time()
        Runs.endRun(run, 'completed', 'completed')
    else
        Runs.endRun(run, 'failed', 'time_limit')
    end
end

-- ── award / penalize ────────────────────────────────────────────────────────
local function record(run, id, opts, kind)
    if type(run) ~= 'table' or type(id) ~= 'string' or id == '' or run.state == 'ended' then return false end
    opts = type(opts) == 'table' and opts or {}
    local count = math.floor(num(opts.count, 1))
    if count <= 0 then return false end
    local src = toSrc(opts.src)
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

function Runs.award(run, id, opts) return record(run, id, opts, 'bonus') end
function Runs.penalize(run, id, opts) return record(run, id, opts, 'penalty') end

-- ── leaving and ending ──────────────────────────────────────────────────────
function Runs.removeParticipant(run, src, endReason, opts)
    src = toSrc(src)
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
    applyCooldowns(run, p, endReason)

    local others = Runs.activeSrcs(run)
    refreshDepartments(run)
    CP.log(TAG, 'run %s: %d left (%s -> %s), %d left in the run', run.id, src, endReason, result, #others)

    if not opts.keepFlag then call('Alerts', 'clear', src) end
    call('Route', 'stop', run, src)
    if wasInProgress then
        local i = run.objectiveIndex
        if run.objectives[i] and run.objectives[i].status == 'active' then callBlock(run, i, 'onParticipantLeft', src) end
    end

    local lastOut = #others == 0
    if lastOut then
        run.state = 'ended'
        run.endedAt = os.time()
        run.endReason = endReason
        run.endState = result == 'failed' and 'failed' or 'abandoned'
        cleanupRun(run)
    else
        if run.host == src then migrateHost(run, 'left') end
        if run.state ~= 'ended' then rescale(run, endReason) end
    end
    removeItems(run, p)

    -- Result, row, payment, hooks.
    local rowId, rr = settle(run, p, result, endReason, others)
    if not opts.silent then
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, result, endReason, rr)
        local key = opts.notify
        if key then notify(src, 'warning', key) end
    else
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, result, endReason, nil)
    end
    pushNone(src)

    if lastOut then
        local state = run.endState
        CP.log(TAG, 'run %s ended: nobody left (%s)', run.id, state)
        afterRunEnded(run, state)
    else
        if not run.test and (result == 'completed' or result == 'failed') then call('Leaderboard', 'invalidate') end
        if run.state ~= 'ended' then
            broadcastParticipants(run)
            for _, s in ipairs(others) do notify(s, 'info', 'run.partner_left', { name = p.name or ('#' .. src) }) end
            refreshHud(run, true)
            pushRun(run)
        end
    end
    return rowId
end

function Runs.endRun(run, state, endReason)
    if type(run) ~= 'table' or run.state == 'ended' then return end
    if state ~= 'completed' and state ~= 'failed' then state = 'failed' end
    endReason = RESULT[endReason] and endReason or (state == 'completed' and 'completed' or 'mission_failed')
    syncTimer(run)
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
        applyCooldowns(run, p, endReason)
    end
    CP.log(TAG, 'run %s ended %s (%s) for %d participant(s)', run.id, state, endReason, #finals)
    cleanupRun(run)
    for _, src in ipairs(finals) do
        call('Alerts', 'clear', src)
        call('Route', 'stop', run, src)
        removeItems(run, run.participants[src])
    end
    for _, src in ipairs(finals) do
        local p = run.participants[src]
        local others = {}
        for _, s in ipairs(finals) do if s ~= src then others[#others + 1] = s end end
        local _, rr = settle(run, p, state, endReason, others)
        TriggerClientEvent(CP.e('client:runEnded'), src, run.id, state, endReason, rr)
        pushNone(src)
    end
    afterRunEnded(run, state)
end

-- Which stored end reasons a reclassification may replace: an un-marked real call only turns a real_call
-- leave into real_call_cancelled (a force recall or a cancelled operation never becomes a normal abandon).
local RECLASSIFY_FROM = {
    real_call_cancelled = { list = { real_call = true }, sql = "('real_call')" },
}
local RECLASSIFY_ANY = { list = { real_call = true, force_recall = true, cancelled = true }, sql = "('real_call', 'force_recall', 'cancelled')" }

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
    db()
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs SET end_reason = ?, state = ?, breakdown = JSON_SET(breakdown, '$.endReason', ?)
        WHERE run_uuid = ? AND citizenid = ? AND end_reason IN ]] .. from.sql, { newEndReason, RESULT[newEndReason], newEndReason, runId, citizenid })
    if not ok then
        CP.err(TAG, 'reclassify %s/%s failed: %s', citizenid, runId, tostring(n))
        return false
    end
    if not n or n < 1 then return false end
    local missionType, missionId, cooldown, isBoss
    if run then
        missionType, missionId, cooldown, isBoss = run.missionType, run.missionId, num(run.mission.cooldown, 0), run.isBoss
    else
        local okR, row = pcall(MySQL.single.await, 'SELECT mission_type, mission_id FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ? LIMIT 1', { runId, citizenid })
        if okR and type(row) == 'table' then
            missionType, missionId = row.mission_type, row.mission_id
            cooldown = missionCooldownOf(missionId)
            isBoss = missionId == BOSS_ID
        end
    end
    if missionType then
        local c = cdEntry(citizenid)
        local now = os.time()
        if MISSION_COOLDOWN[newEndReason] and cooldown and cooldown > 0 then
            c.missions[missionId] = math.max(c.missions[missionId] or 0, now + math.floor(cooldown))
        end
        if TYPE_COOLDOWN[newEndReason] and not isBoss then
            c.types[missionType] = math.max(c.types[missionType] or 0, now + math.floor(abandonCooldown()))
        end
    end
    if p then p.endReason, p.result = newEndReason, RESULT[newEndReason] end
    if run and run.state == 'in_progress' and not forcedTier(run) then
        local n2 = #Runs.activeSrcs(run)
        if n2 > 0 then
            local old = run.payTier
            run.payTier = lowerTier(run.payTier, tierFor(n2))
            if tierName(old) ~= tierName(run.payTier) then
                Runs.send(run, 'client:tierChanged', run.id, tierName(run.tier), tierName(run.payTier))
                pushRun(run)
            end
        end
    end
    CP.log(TAG, 'run %s: %s reclassified as %s', runId, citizenid, newEndReason)
    return true
end

-- ── views ───────────────────────────────────────────────────────────────────
local function modifierView(run)
    if not run.modifier then return nil end
    return { key = run.modifier, label = label('modifier.' .. run.modifier) }
end

local function expectedFor(run)
    local tier = run.payTier or tierByName(run.expectedTier) or tierFor(math.max(1, #Runs.activeSrcs(run)))
    local P = num(run.pointsBase, 0)
    local ev = Config.Events or {}
    local modPts = run.modifier and num(ev.modifierPoints, 0) * P or 0
    local nDepts = activeDepartments(run)
    local mCross = nDepts >= 2 and num(Config.CrossDepartmentPoints, 1.10) or 1.0
    local cap = num(Config.Scoring and Config.Scoring.scoreCap, 2.0) * P
    local pts = math.min(cap, (P + modPts) * num(tier and tier.points, 1.0) * mCross)
    if ev.typeOfTheDay ~= false then
        local ok, tod = call('Events', 'typeOfTheDay')
        if ok and tod ~= nil and tod == run.missionType then pts = pts * num(ev.todMultiplier, 2.0) end
    end
    local cash = U.round(num(run.cashBase, 0) * num(tier and tier.cash, 1.0) * (run.modifier and num(ev.modifierCash, 1.0) or 1.0))
    return { cash = cash, points = math.floor(pts) }
end

local function routeFor(run, src, p)
    local route = { status = 'disabled' }
    local recalcs = math.floor(num(Config.Route and Config.Route.maxRecalcs, 2))
    local ok, st = call('Route', 'status', run, src)
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
    src = toSrc(src)
    if type(run) ~= 'table' or run.state == 'ended' then return nil end
    local p = src and run.participants[src]
    local started = run.state == 'in_progress'
    local route, recalcs = routeFor(run, src, p)
    local partners = participantsList(run)
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
    return {
        -- Optional extras for the Active Mission screen (web/src/types/run_ui.ts): the viewer, the boss flag,
        -- the operation and the seconds left to reach the start.
        me = src, isBoss = run.isBoss == true, operationId = run.operationId, startIn = startIn,
        runId = run.id,
        missionLabel = run.mission.label or run.missionId,
        description = run.mission.description or '',
        missionType = run.missionType,
        state = run.state,
        tier = started and tierName(run.tier) or run.expectedTier,
        tierExpected = not started,
        payTier = started and tierName(run.payTier) or run.expectedTier,
        route = route,
        objectives = hudObjectives(run, true),
        remaining = remaining and math.max(0, math.ceil(remaining)) or nil,
        paused = run.timer and run.timer.paused == true or false,
        partners = partners,
        expected = expectedFor(run),
        modifier = modifierView(run),
        test = run.test ~= nil,
        recalcsLeft = recalcs,
        radioSilence = run.modifier == 'radio_silence',
        log = logView,
    }
end

function Runs.summary(run)
    if type(run) ~= 'table' then return nil end
    local list = {}
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        list[#list + 1] = { src = src, name = p.name, callsign = p.callsign, departmentShort = p.departmentShort or '', status = p.status }
    end
    local remaining = Runs.remaining(run)
    return {
        runId = run.id, missionType = run.missionType, missionLabel = run.mission.label or run.missionId,
        tier = tierName(run.tier) or run.expectedTier, state = run.state,
        remaining = remaining and math.max(0, math.ceil(remaining)) or nil,
        test = run.test ~= nil, operationId = run.operationId, participants = list,
    }
end

-- ── test hooks (CP.Testing) ─────────────────────────────────────────────────
function Runs.testSkip(run)
    if type(run) ~= 'table' or not run.test or run.state ~= 'in_progress' then return false end
    return completeObjective(run, run.objectiveIndex, { skipped = true }, true)
end

function Runs.testRestart(run)
    if type(run) ~= 'table' or not run.test or run.state ~= 'in_progress' then return false end
    local i = run.objectiveIndex
    local o = run.objectives[i]
    if not o or o.status ~= 'active' then return false end
    local impl = blockOf(run, i)
    if impl and type(impl.restart) == 'function' then
        callBlock(run, i, 'restart')
    else
        callBlock(run, i, 'stop')
        Runs.send(run, 'client:objective', run.id, i, { action = 'stop' })
        for netId, e in pairs(run.entities) do
            if e.obj == i then Runs.deleteEntity(run, netId) end
        end
        for k in pairs(o.state) do o.state[k] = nil end
        o.hud = nil
        Runs.send(run, 'client:objective', run.id, i, { action = 'prepare' })
        callBlock(run, i, 'prepare')
        if run.state ~= 'in_progress' then return true end
        Runs.send(run, 'client:objective', run.id, i, { action = 'start' })
        callBlock(run, i, 'start')
    end
    o.startedAtMs = GetGameTimer()
    o.tooFastFlagged = nil
    if run.state == 'in_progress' then refreshHud(run, true) end
    return true
end

local ANCHOR_KEYS = { 'anchor', 'checkpoints', 'points', 'spawns', 'npcs', 'targets', 'door', 'suspect', 'spawn', 'center', 'route', 'safe', 'scene' }

local function firstPoint(location, v, depth)
    depth = depth or 0
    if depth > 3 or v == nil then return nil end
    if type(v) == 'string' then
        if v == 'shared:devices' then return nil end
        return firstPoint(location, location and location[v], depth + 1)
    end
    if isVec(v) then return vec3Of(v) end
    if type(v) == 'table' then
        if v.coords and isVec(v.coords) then return vec3Of(v.coords) end
        if type(v.points) == 'table' then return firstPoint(location, v.points, depth + 1) end
        if v[1] ~= nil then return firstPoint(location, v[1], depth + 1) end
    end
    return nil
end

function Runs.anchor(run)
    if type(run) ~= 'table' then return nil end
    local start = vec3Of(run.location.start.coords)
    if run.state ~= 'in_progress' then return start end
    local i = run.objectiveIndex
    local o = run.objectives[i]
    local obj = o and o.obj or {}
    if run.shared and type(run.shared.devices) == 'table' and obj.targets == 'shared:devices' then
        for _, d in ipairs(run.shared.devices) do
            if d.coords and isVec(d.coords) then return vec3Of(d.coords) end
        end
    end
    for _, key in ipairs(ANCHOR_KEYS) do
        local pt = firstPoint(run.location, obj[key])
        if pt then return pt end
    end
    for _, e in ipairs(Runs.entitiesFor(run, { obj = i, alive = true })) do
        if e.entity and DoesEntityExist(e.entity) then return GetEntityCoords(e.entity) end
    end
    return start
end

-- ── net: evidence, telemetry, abandon, getRun ───────────────────────────────
local function sanitize(v, depth)
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
            local clean, ok = sanitize(val, depth + 1)
            if not ok then return nil, false end
            out[k] = clean
        end
        return out, true
    end
    return nil, false
end
local function cleanEvidence(v)
    local out, ok = sanitize(v, 0)
    return ok and out or nil
end

local function recheckOk(run, p)
    if run.test and not p.isOfficer then return true end
    if not has('Access', 'recheck') then return true end
    local ok, qualifies, reason = call('Access', 'recheck', p.src, p.job)
    if ok and qualifies == false then
        Runs.removeParticipant(run, p.src, LOST_REASONS[reason] and reason or 'job_change')
        return false
    end
    return true
end

RegisterNetEvent(CP.e('server:objective'), function(runId, index, evidence)
    local src = source
    src = toSrc(src)
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
    local ev = cleanEvidence(evidence)
    if type(ev) ~= 'table' or type(ev.type) ~= 'string' or #ev.type > 32 then
        CP.log(TAG, 'run %s: malformed evidence from %d', runId, src)
        return
    end
    if inArena(src) then return end
    -- CP.AntiCheat sees every well-formed event, also one for an objective past the last (an executor's
    -- event for a later objective flags the run 'unexpected_event' there).
    if has('AntiCheat', 'checkEvent') then
        local okCall, ok, reason = call('AntiCheat', 'checkEvent', run, src, index, ev)
        if okCall and ok == false then
            CP.log(TAG, 'run %s: evidence %s from %d rejected by anticheat (%s)', runId, ev.type, src, tostring(reason))
            return
        end
    end
    local o = run.objectives[index]
    if not o or index ~= run.objectiveIndex or o.status ~= 'active' then
        CP.log(TAG, 'run %s: evidence for objective %d from %d is out of order (current %d)', runId, index, src, run.objectiveIndex)
        return
    end
    if not recheckOk(run, p) then return end
    -- The re-check may yield: the participant, the run or the objective may have changed meanwhile.
    if run.state ~= 'in_progress' or p.status ~= 'active' or index ~= run.objectiveIndex or o.status ~= 'active' then return end
    local okCall, ok, reason = callBlock(run, index, 'onEvent', src, ev)
    if okCall and ok == false then
        CP.log(TAG, 'run %s: block rejected %s from %d (%s)', runId, ev.type, src, tostring(reason))
    end
end)

local function isRunEntity(entity, netId)
    local bag = Entity(entity).state.cp
    if bag ~= nil then return true end
    for _, run in pairs(runs) do
        if run.entities[netId] then return true end
    end
    return false
end

local function telemetryVehicle(run, p, data)
    local now = GetGameTimer()
    if p.telemetry.vehicleAt and now - p.telemetry.vehicleAt < VEHICLE_SAMPLE_MS then return end
    local netId = type(data) == 'table' and math.tointeger(tonumber(data.netId) or -1)
    if not netId or netId <= 0 then return end
    local veh = NetworkGetEntityFromNetworkId(netId)
    if not veh or veh == 0 or not DoesEntityExist(veh) or GetEntityType(veh) ~= 2 then return end
    if GetPedInVehicleSeat(veh, -1) ~= GetPlayerPed(p.src) then return end
    if isRunEntity(veh, netId) then return end
    p.telemetry.vehicleAt = now
    local engine = num(GetVehicleEngineHealth(veh), 1000.0)
    local body = num(GetVehicleBodyHealth(veh), 1000.0)
    local v = p.vehicle
    v.lastNetId = netId
    v.seen = true
    if engine < v.engine then v.engine = engine end
    if body < v.body then v.body = body end
end

local function telemetryPedHit(run, p, data)
    if p.telemetry.pedHits >= MAX_PED_HITS then return end
    local netId = type(data) == 'table' and math.tointeger(tonumber(data.netId) or -1)
    if not netId or netId <= 0 or run.pedHits[netId] then return end
    local ped = NetworkGetEntityFromNetworkId(netId)
    if not ped or ped == 0 or not DoesEntityExist(ped) or GetEntityType(ped) ~= 1 then return end
    if IsPedAPlayer(ped) then return end
    if isRunEntity(ped, netId) then return end
    local me = GetPlayerPed(p.src)
    if not me or me == 0 or GetVehiclePedIsIn(me, false) == 0 then return end
    if U.dist(GetEntityCoords(me), GetEntityCoords(ped)) > PED_HIT_RANGE then return end
    run.pedHits[netId] = true
    p.telemetry.pedHits = p.telemetry.pedHits + 1
    Runs.penalize(run, 'pedestrian_hit', { src = p.src })
end

RegisterNetEvent(CP.e('server:telemetry'), function(runId, kind, data)
    local src = source
    src = toSrc(src)
    if not src then return end
    if not CP.Net.rateOk(src, 'runs:telemetry', 8, 1000) then return end
    if type(runId) ~= 'string' or #runId > 64 or not TELEMETRY_KINDS[kind] then return end
    if data ~= nil and type(data) ~= 'table' then return end
    local run = runs[runId]
    local p = run and run.participants[src]
    if not p or p.status ~= 'active' or run.state == 'ended' then return end
    if inArena(src) then return end
    if kind == 'vehicle' then
        telemetryVehicle(run, p, data)
    elseif kind == 'ped_hit' then
        telemetryPedHit(run, p, data)
    elseif kind == 'lights_siren' then
        if LIGHTS_MISSIONS[run.missionId] and not p.telemetry.lights then
            local me = GetPlayerPed(src)
            if me and me ~= 0 and GetVehiclePedIsIn(me, false) ~= 0 then
                p.telemetry.lights = true
                Runs.penalize(run, 'lights_siren', { src = src })
            end
        end
    elseif kind == 'weapon_fired' then
        if not p.telemetry.weapon then
            p.telemetry.weapon = true
            p.firedWeapon = true
            run.stats.weaponsFired = (run.stats.weaponsFired or 0) + 1
            CP.log(TAG, 'run %s: %d fired a weapon', run.id, src)
        end
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

-- ── loops ───────────────────────────────────────────────────────────────────
local function tickRun(run, nowMs)
    if run.state == 'ended' then return end
    for _, src in ipairs(Runs.activeSrcs(run)) do
        if inArena(src) then
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
    if run.state ~= 'in_progress' then return end

    local dt = (nowMs - (run.lastTickMs or nowMs)) / 1000
    run.lastTickMs = nowMs
    syncTimer(run)
    entityBookkeeping(run)
    if run.state ~= 'in_progress' then return end

    local host = run.host
    local hp = host and run.participants[host]
    if not hp or hp.status ~= 'active' or not playerOnline(host) then
        migrateHost(run, 'offline', false)
    elseif not responsive(host) then
        migrateHost(run, 'unresponsive', true)
    end

    local i = run.objectiveIndex
    local o = run.objectives[i]
    if o and o.status == 'active' then
        callBlock(run, i, 'tick', dt > 0 and dt or 1.0)
        if run.state ~= 'in_progress' then return end
    end
    if run.timer.running and not run.timer.paused and Runs.remaining(run) <= 0 then
        timeout(run)
        return
    end
    refreshHud(run)
    if run.timerSentAt and now - run.timerSentAt >= TIMER_RESYNC_S then sendTimer(run) end
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
                local ok, err = pcall(tickRun, run, GetGameTimer())
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
            if p and p.status == 'active' then recheckOk(run, p) end
        end
    end
end

local function maintenance()
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
            local ok, s = call('Qbx', 'getByCitizenId', cid)
            if ok then src = s end
            if not src then cooldownCache[cid] = nil end
        end
    end
    for cid, o in pairs(orphans) do
        if now - o.at > ORPHAN_KEEP_S then
            orphans[cid] = nil
        else
            local ok, src = call('Qbx', 'getByCitizenId', cid)
            src = ok and toSrc(src) or nil
            if src and not Runs.isOnMission(src) then
                local cleared = CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table' and CP.Alerts.foreignClearedAt[src]
                local due = now - (o.sweptAt or 0) >= 60 or (cleared and now - cleared >= 10 and (o.sweptAt or 0) < cleared + 10)
                if due then sweepPlayer(src, cid) end
            end
        end
    end
end

-- Faster reaction to an arena exit for players with orphaned items (10 s after the foreign flag cleared).
local function arenaExitSweeps()
    if not (CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table') then return end
    local now = os.time()
    for cid, o in pairs(orphans) do
        local ok, src = call('Qbx', 'getByCitizenId', cid)
        src = ok and toSrc(src) or nil
        local cleared = src and CP.Alerts.foreignClearedAt[src]
        if cleared and now - cleared >= 10 and (o.sweptAt or 0) < cleared + 10 and not Runs.isOnMission(src) then
            sweepPlayer(src, cid)
        end
    end
end

CreateThread(function()
    local n = 0
    while true do
        Wait(1000)
        Runs._tick()
        n = n + 1
        if n % 5 == 0 and next(orphans) ~= nil then pcall(arenaExitSweeps) end
    end
end)

CreateThread(function()
    while true do
        Wait(math.max(1, math.floor(num(Config.AntiCheat and Config.AntiCheat.jobRecheck, 10))) * 1000)
        local ok, err = pcall(Runs._jobRecheck)
        if not ok then CP.err(TAG, 'job recheck failed: %s', tostring(err)) end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        local ok, err = pcall(maintenance)
        if not ok then CP.err(TAG, 'maintenance failed: %s', tostring(err)) end
    end
end)

-- ── leaving the server, losing access ───────────────────────────────────────
local function dropFromRun(src, reason)
    local run = Runs.getBySrc(src)
    if run then Runs.removeParticipant(run, src, reason) end
end

AddEventHandler('playerDropped', function()
    local src = source
    src = toSrc(src)
    if not src then return end
    dropFromRun(src, 'disconnected')
end)

local hooked = false
local function registerHooks()
    if hooked then return true end
    if not (CP.Access and CP.Access.onLost and CP.Qbx and CP.Qbx.onPlayerUnload) then return false end
    hooked = true
    CP.Access.onLost(function(src, endReason)
        src = toSrc(src)
        local run, p = Runs.getBySrc(src)
        if not run then return end
        if run.test and not p.isOfficer then return end
        if not LOST_REASONS[endReason] then endReason = 'job_change' end
        -- Duty signals can be stale or superseded (INTEGRATIONS: SetDuty re-entrancy / ordering): an off-duty
        -- signal only removes the officer while the live check still agrees at this moment.
        if endReason == 'off_duty' and has('Access', 'recheck') then
            local ok, qualifies, reason = call('Access', 'recheck', src, p.job)
            if ok and qualifies ~= false then
                CP.log(TAG, 'off-duty signal for %d ignored: back on duty', src)
                return
            end
            if ok and LOST_REASONS[reason] then endReason = reason end
        end
        Runs.removeParticipant(run, src, endReason)
    end)
    CP.Qbx.onPlayerUnload(function(src)
        dropFromRun(toSrc(src), 'disconnected')
    end)
    if CP.Qbx.onPlayerLoaded then
        CP.Qbx.onPlayerLoaded(function(src)
            src = toSrc(src)
            if not src then return end
            SetTimeout(5000, function()
                local cid = citizenOf(src)
                if cid then
                    Runs.cooldowns(cid)
                    if not Runs.isOnMission(src) then sweepPlayer(src, cid) end
                end
            end)
        end)
    end
    return true
end

CreateThread(function()
    Wait(0)
    for _ = 1, 30 do
        if registerHooks() then break end
        Wait(1000)
    end
    if not hooked then CP.warn(TAG, 'CP.Access.onLost / CP.Qbx.onPlayerUnload are not available: job and unload checks rely on the recheck loop') end
    -- Leftover mission items from a crash: sweep the players who are online now.
    Wait(15000)
    local ok, list = call('Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then
        for _, src in ipairs(list) do
            src = toSrc(src)
            if src and not Runs.isOnMission(src) then
                local cid = citizenOf(src)
                if cid then pcall(sweepPlayer, src, cid) end
            end
        end
    end
end)

-- ── resource stop: delete everything, write nothing ─────────────────────────
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for id, run in pairs(runs) do
        run.state = 'ended'
        for _, src in ipairs(run.order) do
            local p = run.participants[src]
            if p and p.status == 'active' then pcall(removeItems, run, p) end
        end
        pcall(deleteAllEntities, run)
        runs[id] = nil
    end
    bySrc = {}
end)
