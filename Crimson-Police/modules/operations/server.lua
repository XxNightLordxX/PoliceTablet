-- modules/operations/server.lua · CP.Operations (server): Cross-Department Missions.
--
-- Owns: the one active Cross-Department Mission ("operation"), the board lock for every department
-- while it is active, its join window, the start of its run through CP.Runs.create, fail → relaunch /
-- cancel, the idle auto-cancel, the server-wide launch cooldown, the cp_operations rows, the
-- operation notifications (client:operation to every on-duty officer, CP.Tablet.notify to the people
-- concerned, pushes 'operation' and 'board') and the operations audit / webhook entries.
-- SPEC "Cross-Department Missions", "Supervisor & admin actions" (launch row), "Data model" cp_operations.
--
-- Life cycle (cp_operations.status):
--   joining  launched (or relaunched): officers of every department join, up to Config.CrossDept.maxParticipants;
--            joining closes when the launcher taps Start now or after Config.CrossDept.joinWindow seconds.
--            At window end the run starts by itself with enough participants, otherwise → waiting.
--   running  the run exists (accepted → in progress). Operation runs ignore cooldowns, the no-repeat rule,
--            the hourly cap and the server cap and roll no modifier (CP.Runs / CP.Events decide that from
--            run.operationId). Nobody can join any more.
--   waiting  the run failed, every participant left, or the window closed without enough participants /
--            without a free location: still active (the board stays locked); any supervisor may relaunch
--            (a new join window) or cancel. Config.CrossDept.idleCancel seconds with no run (counted from the
--            launch or the end of the last run; a relaunch does not reset it) → auto-cancel once no join
--            window is open.
--   completed  the run was Completed: the lock lifts.            (final, ended_at set)
--   cancelled  cancelled by a supervisor/admin, by the idle rule, or by a restart.   (final, ended_at set)
-- The board lock (isLocked) holds for joining, running and waiting. Cancelling a running operation ends
-- every participant still on the run with end reason 'cancelled' (no cooldown, no penalty).
-- A launch starts the server-wide cooldown Config.CrossDept.cooldown, counted from cp_operations.created_at
-- of the last launch (persisted, so a restart keeps it); a relaunch is not a new launch.
-- Restart safety: rows left joining/running/waiting by a previous server start are marked cancelled.
--
-- Public API (docs/ARCHITECTURE.md §5.17)
--   CP.Operations.active() -> op|nil       the live operation table (read only):
--       op = { id, missionId, missionLabel, missionType, status, launchedBy (citizenid), launcher (name),
--              createdAt, joinEndsAt|nil, participants = { { src, citizenid, name, callsign, department,
--              departmentShort, rank, joinedAt } }, runId|nil, idleSince, waitingReason|nil, attempt }
--   CP.Operations.isLocked() -> boolean     an operation is joining, running or waiting
--   CP.Operations.boardCard(src) -> card|nil   BoardData.operation (§9.4) + missionType, missionTypeLabel,
--       description, min, runState
--   CP.Operations.launch(src, missionId) -> ok, data|errKey      (permission launchCrossDept)
--   CP.Operations.startNow(src) -> ok, data|errKey               (the one who opened the join window, an admin,
--                                                                 or anyone allowed when that person is offline)
--   CP.Operations.relaunch(src) -> ok, data|errKey
--   CP.Operations.cancel(src, reason) -> ok, data|errKey         src 0 = the server (no permission check)
--   CP.Operations.join(src, opId) -> ok, data|errKey             officers of any department (server:joinOperation)
--   CP.Operations.onRunEnded(run, state)                         (hook, CP.Runs) state 'completed' | other
--   CP.Operations.view(src) -> OperationView (callback sup:getOperation, shape below)
--   CP.Operations.cooldownLeft() -> seconds until the next launch is allowed (0 = now)
--   CP.Operations.eligible(def) -> ok, errKey   launchable: published and enabled, departments empty
--       (open to every department), maxOfficers >= 2, never the Weekly Boss
-- Net (CP.Net; every sup/admin action checks CP.Permissions.can(src, 'launchCrossDept') first, the admin
-- ones also require an admin)
--   actions server:sup:opLaunch / server:admin:opLaunch   { missionId }  -> { id }
--           server:sup:opStart / server:admin:opStart     -              -> { runId, participants }
--           server:sup:opRelaunch / server:admin:opRelaunch -            -> { id }
--           server:sup:opCancel / server:admin:opCancel   { reason }     -> { id }   (reason 1-200 characters)
--           server:joinOperation                          operationId | { operationId } -> { id, joined, max }
--   callback sup:getOperation -> OperationView
--       { operation = null | { id, missionId, missionLabel, missionType, missionTypeLabel, difficulty,
--           launcher, launcherCallsign, launcherDepartment, launchedAt, status, runState, runId,
--           participants = { { src, name, callsign, departmentShort, department, status, arrived } },
--           departments = { { short, count } }, joined, max, min, joinEndsIn, idleCancelIn, tier,
--           tierExpected, remaining, waitingReason, attempt, canStart, startBlocked, canRelaunch, canCancel },
--         cooldownLeft, cooldown, joinWindow, idleCancel, maxParticipants, crossBonus (Config.CrossDepartmentPoints),
--         enabled, canLaunch, launchBlocked, serverTime,
--         eligibleMissions = { { id, label, type, typeLabel, difficulty, minOfficers, maxOfficers } } (no operation only) }
-- Client event: crimson-police:client:operation (state 'launched'|'started'|'ended'|'cancelled', missionLabel,
-- extra = { id, relaunched }) to every on-duty officer. Pushes: 'operation' and 'board' ({ id|false, status|false })
-- to every department member online (and 'operation' to online admins).

CP.Operations = CP.Operations or {}
local Ops = CP.Operations
local TAG = 'operations'

local BOSS_ID = 'weekly_boss_kingpin'
local REASON_MAX = 200
local TICK_ACTIVE_MS = 1000
local TICK_IDLE_MS = 5000
local RUN_MISSING_GRACE = 60     -- seconds a running operation's run may be missing before it counts as ended
local ACTIVE = { joining = true, running = true, waiting = true }

local op = nil                   -- the active operation (status joining | running | waiting)
local lastLaunchAt = nil         -- os.time() of the last launch (MAX(cp_operations.created_at))
local ready = false
local busy = false               -- a launch / start / cancel is being processed
local dbQueue, dbWorker = {}, false

-- ── helpers ─────────────────────────────────────────────────────────────────
local function toSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

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

local function cfg()
    return type(Config.CrossDept) == 'table' and Config.CrossDept or {}
end

local function cfgInt(key, default)
    local v = tonumber(cfg()[key])
    if not v or v ~= v or v < 0 or v == math.huge then return default end
    return math.floor(v)
end

local function getOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    local ok, officer, errKey = call('Access', 'getOfficer', src)
    if not ok then return nil, 'err.internal' end
    return officer, errKey
end

local function isAdmin(src)
    if src == 0 then return true end
    local ok, v = call('Access', 'isAdmin', src)
    return ok and v == true
end

local function onRun(src)
    local ok, run = call('Runs', 'getBySrc', src)
    if ok and type(run) == 'table' then return true end
    local ok2, on = call('Runs', 'isOnMission', src)
    return ok2 and on == true
end

local function inArena(src)
    local ok, v = call('Alerts', 'inArena', src)
    return ok and v == true
end

local function isOnCall(src)
    local ok, v = call('Calls', 'isOnCall', src)
    return ok and v == true
end

local function runGet(runId)
    if not runId then return nil end
    local ok, run = call('Runs', 'get', runId)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function activeSrcs(run)
    local ok, list = call('Runs', 'activeSrcs', run)
    if ok and type(list) == 'table' then return list end
    local out = {}
    for _, s in ipairs(run.order or {}) do
        local p = run.participants and run.participants[s]
        if p and p.status == 'active' then out[#out + 1] = s end
    end
    return out
end

local function notify(src, kind, key, vars, opts)
    call('Tablet', 'notify', src, kind, key, vars, opts)
end

local function notifyMany(srcs, kind, key, vars)
    for _, s in ipairs(srcs) do notify(s, kind, key, vars) end
end

local function push(src, topic, data)
    call('Tablet', 'push', src, topic, data)
end

local function onlinePlayers()
    local ok, list = call('Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then return list end
    local out = {}
    if GetPlayers then
        for _, s in ipairs(GetPlayers()) do
            local n = toSrc(s)
            if n then out[#out + 1] = n end
        end
    end
    return out
end

local function missionDef(id)
    local ok, def = call('Missions', 'get', id)
    if ok and type(def) == 'table' then return def end
    return nil
end

local function typeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return type(t) == 'table' and t.label or tostring(key or '')
end

local function tierName(n)
    local ok, row = call('Scaling', 'tierFor', n)
    if ok and type(row) == 'table' then return row.tier end
    local list = Config.Scaling or {}
    for _, r in ipairs(list) do
        if (tonumber(r.maxParticipants) or 0) >= n then return r.tier end
    end
    return list[#list] and list[#list].tier or 'standard'
end

local function minFor(def)
    local min = math.max(2, cfgInt('minParticipants', 2), math.tointeger(tonumber(def and def.minOfficers) or 1) or 1)
    return math.min(min, math.max(2, cfgInt('maxParticipants', 8)))
end

local function maxFor()
    return math.max(2, cfgInt('maxParticipants', 8))
end

local function cleanReason(reason)
    if type(reason) ~= 'string' then return nil, 'err.op_reason_required' end
    reason = CP.U.trim((reason:gsub('%c', ' ')))
    if reason == '' then return nil, 'err.op_reason_required' end
    -- Characters, not bytes (the UI counts characters; accented text is multi-byte).
    local len = utf8.len(reason)
    if not len then return nil, 'err.invalid_payload' end
    if len > REASON_MAX then return nil, 'err.op_reason_too_long' end
    return reason
end

-- ── database (ordered, never blocks the state machine) ───────────────────────
local function dbRun(sql, params)
    dbQueue[#dbQueue + 1] = { sql = sql, params = params }
    if dbWorker then return end
    dbWorker = true
    CreateThread(function()
        while #dbQueue > 0 do
            local q = table.remove(dbQueue, 1)
            local ok, err = pcall(MySQL.update.await, q.sql, q.params)
            if not ok then CP.err(TAG, 'database write failed: %s', tostring(err)) end
        end
        dbWorker = false
    end)
end

local function dbStatus(id, status, final)
    if final then
        dbRun('UPDATE cp_operations SET status = ?, ended_at = FROM_UNIXTIME(?) WHERE id = ?', { status, os.time(), id })
    else
        dbRun('UPDATE cp_operations SET status = ? WHERE id = ?', { status, id })
    end
end

-- ── audit and webhook ───────────────────────────────────────────────────────
local function roleOf(src)
    if src == 0 then return 'console' end
    return isAdmin(src) and 'admin' or 'supervisor'
end

local function audit(src, cur, action, oldV, newV, reason)
    local target = CP.U.clip(('#%s %s'):format(tostring(cur.id), tostring(cur.missionId)), 64)
    call('Admin', 'audit', src == 0 and 'console' or src, roleOf(src), 'operations', action, target,
        oldV ~= nil and CP.U.clip(tostring(oldV), 64) or nil, newV ~= nil and CP.U.clip(tostring(newV), 64) or nil,
        reason ~= nil and CP.U.clip(tostring(reason), 255) or nil)
end

local function webhook(kind, cur, extra)
    local vars = { mission = cur.missionLabel, id = cur.id, launcher = cur.launcher or '?' }
    local fields = {
        { name = CP.L('sup.crossdept.webhook_field_mission'), value = ('%s (%s)'):format(cur.missionLabel, cur.missionId), inline = true },
        { name = CP.L('sup.crossdept.webhook_field_launcher'), value = tostring(cur.launcher or '?'), inline = true },
    }
    if type(extra) == 'table' then
        for _, f in ipairs(extra) do fields[#fields + 1] = f end
    end
    call('Admin', 'webhook', 'operations', CP.L('sup.crossdept.webhook_' .. kind .. '_title', vars),
        CP.L('sup.crossdept.webhook_' .. kind .. '_text', vars), fields)
end

-- ── notifications ───────────────────────────────────────────────────────────
local function pushData()
    return { id = op and op.id or false, status = op and op.status or false }
end

-- Pushes 'operation' + 'board' to every department member online ('operation' to admins too) and, with a
-- state, client:operation to every on-duty officer. Runs in its own thread (getOfficer may wait).
local function broadcast(state, label, extra)
    local data = pushData()
    CreateThread(function()
        for _, p in ipairs(onlinePlayers()) do
            p = toSrc(p)
            if p then
                local okI, info = call('Qbx', 'getInfo', p)
                local job = okI and type(info) == 'table' and type(info.job) == 'table' and info.job or nil
                local okD, dept = false, nil
                if job then okD, dept = call('Access', 'departmentForJob', job.name) end
                if okD and dept then
                    push(p, 'operation', data)
                    push(p, 'board', data)
                    if state and job.onduty and getOfficer(p) then
                        TriggerClientEvent(CP.e('client:operation'), p, state, label, extra)
                    end
                elseif isAdmin(p) then
                    push(p, 'operation', data)
                end
            end
        end
    end)
end

-- A toast for every online player who may launch / relaunch / cancel (supervisors with the permission, admins).
local function notifySupervisors(kind, key, vars)
    CreateThread(function()
        for _, p in ipairs(onlinePlayers()) do
            p = toSrc(p)
            if p then
                local ok, allowed = call('Permissions', 'can', p, 'launchCrossDept')
                if ok and allowed then notify(p, kind, key, vars) end
            end
        end
    end)
end

-- ── eligibility ─────────────────────────────────────────────────────────────
function Ops.eligible(def)
    if type(def) ~= 'table' or type(def.id) ~= 'string' then return false, 'err.op_mission_unknown' end
    if def.isBoss == true or def.id == BOSS_ID then return false, 'err.op_mission_boss' end
    if def.status ~= nil and def.status ~= 'published' then return false, 'err.op_mission_disabled' end
    if CP.Missions and CP.Missions.isEnabled then
        local ok, enabled = call('Missions', 'isEnabled', def.id)
        if not ok or not enabled then return false, 'err.op_mission_disabled' end
    end
    if type(def.departments) == 'table' and next(def.departments) ~= nil then return false, 'err.op_mission_departments' end
    if (tonumber(def.maxOfficers) or 1) < 2 then return false, 'err.op_mission_solo' end
    return true
end

local function eligibleMissions()
    local out = {}
    local ok, list = call('Missions', 'list')
    if not ok or type(list) ~= 'table' then return out end
    for _, def in ipairs(list) do
        if Ops.eligible(def) then
            out[#out + 1] = {
                id = def.id, label = def.label or def.id, type = def.type, typeLabel = typeLabel(def.type),
                difficulty = tonumber(def.difficulty) or 1,
                minOfficers = minFor(def), maxOfficers = maxFor(),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.label ~= b.label then return tostring(a.label) < tostring(b.label) end
        return a.id < b.id
    end)
    return out
end

-- ── state ───────────────────────────────────────────────────────────────────
function Ops.active()
    return op
end

function Ops.isLocked()
    return op ~= nil and ACTIVE[op.status] == true
end

function Ops.cooldownLeft()
    if not lastLaunchAt then return 0 end
    local left = lastLaunchAt + cfgInt('cooldown', 1800) - os.time()
    return left > 0 and left or 0
end

local function actorOf(src)
    local officer = getOfficer(src)
    local okI, info = call('Qbx', 'getInfo', src)
    info = okI and type(info) == 'table' and info or nil
    local citizenid = (officer and officer.citizenid) or (info and info.citizenid)
    local name = (officer and officer.name) or (info and info.name) or (GetPlayerName and GetPlayerName(src)) or ('#' .. tostring(src))
    return {
        src = src, citizenid = citizenid, name = CP.U.clip(name, 64),
        callsign = officer and officer.callsign or nil, departmentShort = officer and officer.departmentShort or nil,
    }
end

-- May src tap Start now? The person who opened this join window, an admin, or (when that person is
-- offline) anyone with the permission.
local function mayStart(src, cur)
    if src == 0 or isAdmin(src) then return true end
    local okI, info = call('Qbx', 'getInfo', src)
    local cid = okI and type(info) == 'table' and info.citizenid or nil
    if cid and cid == cur.windowBy then return true end
    local okS, ownerSrc = call('Qbx', 'getByCitizenId', cur.windowBy)
    return not (okS and ownerSrc)
end

-- fromRun: the operation's run just ended (the idle clock starts now). Otherwise (a join window closed
-- without a run) the clock keeps counting from the launch or the end of the last run.
local function toWaiting(cur, reason, fromRun)
    cur.status = 'waiting'
    cur.runId = nil
    cur.runMissingSince = nil
    cur.joinEndsAt = nil
    cur.joinClosed = nil
    cur.waitingReason = reason
    if fromRun or not cur.idleSince then cur.idleSince = os.time() end
    dbStatus(cur.id, 'waiting', false)
    broadcast(nil)
    notifySupervisors('warning', 'sup.crossdept.notify_waiting_' .. reason, { mission = cur.missionLabel })
    CP.log(TAG, 'operation %d waiting (%s)', cur.id, reason)
end

local function finish(cur)
    if op ~= cur then return end
    op = nil
    cur.status = 'completed'
    cur.runId = nil
    dbStatus(cur.id, 'completed', true)
    broadcast('ended', cur.missionLabel, { id = cur.id })
    webhook('completed', cur)
    CP.log(TAG, 'operation %d completed', cur.id)
end

local function cancelInternal(cur, actorSrc, reason, auto)
    if op ~= cur then return false, 'err.op_none' end
    local before = cur.status
    op = nil                                   -- the board lock lifts at once
    cur.status = 'cancelled'
    local affected, seen = {}, {}
    local run = runGet(cur.runId)
    cur.runId = nil
    if run then
        for _, s in ipairs(activeSrcs(run)) do
            if not seen[s] then seen[s] = true; affected[#affected + 1] = s end
        end
    elseif before == 'joining' then
        for _, p in ipairs(cur.participants) do
            if not seen[p.src] then seen[p.src] = true; affected[#affected + 1] = p.src end
        end
    end
    dbStatus(cur.id, 'cancelled', true)
    if run then
        -- Everyone still on the run leaves it: Abandoned, end reason cancelled (no cooldown, no penalty).
        for _, s in ipairs(affected) do
            call('Runs', 'removeParticipant', run, s, 'cancelled')
        end
    end
    broadcast('cancelled', cur.missionLabel, { id = cur.id })
    notifyMany(affected, 'warning', 'officer.op.cancelled_participant', { mission = cur.missionLabel, reason = reason })
    audit(actorSrc, cur, auto and 'opAutoCancel' or 'opCancel', before, 'cancelled', reason)
    CP.log(TAG, 'operation %d cancelled (%s)', cur.id, tostring(reason))
    return true, { id = cur.id }
end

-- ── start ───────────────────────────────────────────────────────────────────
local function doStart(cur, actorSrc, auto)
    cur.joinClosed = true                      -- nobody joins while the participants are checked
    local valid, dropped = {}, {}
    for _, p in ipairs(CP.U.copy(cur.participants)) do
        local o = getOfficer(p.src)
        if o and o.citizenid == p.citizenid and not onRun(p.src) and not inArena(p.src) and not isOnCall(p.src) then
            valid[#valid + 1] = o
        else
            dropped[#dropped + 1] = p
        end
    end
    if op ~= cur or cur.status ~= 'joining' then return false, 'err.op_not_joining' end
    for _, p in ipairs(dropped) do
        for i = #cur.participants, 1, -1 do
            if cur.participants[i].src == p.src then table.remove(cur.participants, i) end
        end
        notify(p.src, 'warning', 'officer.op.removed_at_start', { mission = cur.missionLabel })
    end

    local def = missionDef(cur.missionId)
    local okE = Ops.eligible(def)
    if not okE then
        cur.joinClosed = nil
        if auto then cancelInternal(cur, 0, CP.L('sup.crossdept.reason_mission_unavailable'), true) end
        return false, 'err.op_mission_unavailable'
    end
    if #valid < minFor(def) then
        cur.joinClosed = nil
        if auto then toWaiting(cur, 'not_enough') elseif #dropped > 0 then broadcast(nil) end
        return false, 'err.op_not_enough'
    end

    local srcs = {}
    for i, o in ipairs(valid) do srcs[i] = o.src end
    local seed = (os.time() ~ (GetGameTimer and GetGameTimer() or 0) ~ (cur.id * 7919)) & 0x7FFFFFFF
    local okP, index = call('Draw', 'pickLocation', def, srcs, CP.U.rng(seed))
    if not okP or not index then
        cur.joinClosed = nil
        if auto then toWaiting(cur, 'no_location') end
        return false, 'err.no_location'
    end
    if op ~= cur or cur.status ~= 'joining' then return false, 'err.op_not_joining' end

    local okC, run, createErr = call('Runs', 'create', {
        mission = def,
        locationIndex = index,
        missionType = def.type,
        members = valid,
        leaderSrc = srcs[1],                   -- the first joiner leads the run
        operationId = cur.id,
        test = nil,
        isBoss = false,
    })
    if not okC or type(run) ~= 'table' then
        cur.joinClosed = nil
        if op == cur and auto then toWaiting(cur, 'start_failed') end
        return false, createErr or 'err.run_create_failed'
    end
    if op ~= cur then
        -- Cancelled while the run was being created: nobody may stay on it.
        for _, s in ipairs(activeSrcs(run)) do call('Runs', 'removeParticipant', run, s, 'cancelled') end
        return false, 'err.op_not_joining'
    end

    cur.status = 'running'
    cur.runId = run.id
    cur.runMissingSince = nil
    cur.joinEndsAt = nil
    cur.joinClosed = nil
    cur.waitingReason = nil
    cur.startedAt = os.time()
    cur.idleSince = nil                        -- a run exists: not idle
    dbStatus(cur.id, 'running', false)
    broadcast('started', cur.missionLabel, { id = cur.id })
    notifyMany(srcs, 'success', 'officer.op.started_participant', { mission = cur.missionLabel })
    if actorSrc then
        audit(actorSrc, cur, 'opStart', cur.attempt, #valid, nil)
    else
        webhook('started', cur, { { name = CP.L('sup.crossdept.webhook_field_participants'), value = tostring(#valid), inline = true } })
    end
    CP.log(TAG, 'operation %d started run %s with %d participant(s)', cur.id, tostring(run.id), #valid)
    return true, { runId = run.id, participants = #valid }
end

local function startRun(actorSrc, auto)
    local cur = op
    if not cur or cur.status ~= 'joining' then return false, 'err.op_not_joining' end
    if cur.joinClosed or busy then return false, 'err.busy' end
    busy = true
    local okCall, ok, data = pcall(doStart, cur, actorSrc, auto)
    busy = false
    if not okCall then
        CP.err(TAG, 'start of operation %d failed: %s', cur.id, tostring(ok))
        cur.joinClosed = nil
        if auto and op == cur and cur.status == 'joining' then toWaiting(cur, 'start_failed') end
        return false, 'err.internal'
    end
    return ok, data
end

-- ── actions (permission already checked) ────────────────────────────────────
local function doLaunch(src, missionId)
    if not ready then return false, 'err.op_not_ready' end
    if cfg().enabled == false then return false, 'err.op_disabled' end
    if op then return false, 'err.op_active' end
    if busy then return false, 'err.busy' end
    if Ops.cooldownLeft() > 0 then return false, 'err.op_cooldown' end
    local def = missionDef(missionId)
    if not def then return false, 'err.op_mission_unknown' end
    local okE, why = Ops.eligible(def)
    if not okE then return false, why end

    busy = true
    local okCall, ok, data = pcall(function()
        local actor = actorOf(src)
        if not actor.citizenid then return false, 'err.not_in_game' end
        if op then return false, 'err.op_active' end
        local now = os.time()
        local id = MySQL.insert.await('INSERT INTO cp_operations (mission_id, launched_by, status, created_at) VALUES (?, ?, ?, FROM_UNIXTIME(?))',
            { def.id, CP.U.clip(actor.citizenid, 50), 'joining', now })
        id = math.tointeger(tonumber(id))
        if not id or id <= 0 then return false, 'err.internal' end
        lastLaunchAt = now
        op = {
            id = id, missionId = def.id, missionLabel = def.label or def.id, missionType = def.type,
            difficulty = tonumber(def.difficulty) or 1,
            launchedBy = actor.citizenid, launcher = actor.name, launcherCallsign = actor.callsign,
            launcherDepartment = actor.departmentShort,
            windowBy = actor.citizenid,
            status = 'joining', createdAt = now, joinEndsAt = now + cfgInt('joinWindow', 300),
            participants = {}, runId = nil, idleSince = now, waitingReason = nil, attempt = 1,
        }
        broadcast('launched', op.missionLabel, { id = id, relaunched = false })
        audit(src, op, 'opLaunch', nil, def.id, nil)
        CP.log(TAG, 'operation %d launched by %s: %s', id, tostring(actor.citizenid), def.id)
        return true, { id = id }
    end)
    busy = false
    if not okCall then
        CP.err(TAG, 'launch failed: %s', tostring(ok))
        return false, 'err.internal'
    end
    return ok, data
end

local function doStartNow(src)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if cur.status ~= 'joining' then return false, 'err.op_not_joining' end
    if not mayStart(src, cur) then return false, 'err.op_not_launcher' end
    return startRun(src, false)
end

local function doRelaunch(src)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if cur.status ~= 'waiting' then return false, 'err.op_not_waiting' end
    if busy then return false, 'err.busy' end
    local okE = Ops.eligible(missionDef(cur.missionId))
    if not okE then return false, 'err.op_mission_unavailable' end
    local actor = actorOf(src)
    if op ~= cur or cur.status ~= 'waiting' then return false, 'err.op_not_waiting' end
    local now = os.time()
    local before = cur.waitingReason
    cur.status = 'joining'
    cur.participants = {}
    cur.runId = nil
    cur.joinEndsAt = now + cfgInt('joinWindow', 300)
    cur.joinClosed = nil
    cur.waitingReason = nil
    cur.windowBy = actor.citizenid or cur.windowBy
    -- The idle clock (no run since ...) keeps running: a relaunch opens a join window, it is not a run.
    cur.idleSince = cur.idleSince or now
    cur.attempt = (cur.attempt or 1) + 1
    dbStatus(cur.id, 'joining', false)
    broadcast('launched', cur.missionLabel, { id = cur.id, relaunched = true })
    audit(src, cur, 'opRelaunch', before, cur.attempt, nil)
    return true, { id = cur.id }
end

local function doCancel(src, reason, auto)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if busy and not auto then return false, 'err.busy' end
    return cancelInternal(cur, src, reason, auto)
end

-- ── public wrappers (permission checked here for callers from other modules) ─
local function allowed(src)
    if src == 0 then return true end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local ok, can, errKey = call('Permissions', 'can', src, 'launchCrossDept')
    if not ok or not can then return false, errKey or 'err.no_permission' end
    return true
end

function Ops.launch(src, missionId)
    local ok, errKey = allowed(src)
    if not ok then return false, errKey end
    return doLaunch(src, missionId)
end

function Ops.startNow(src)
    local ok, errKey = allowed(src)
    if not ok then return false, errKey end
    return doStartNow(src)
end

function Ops.relaunch(src)
    local ok, errKey = allowed(src)
    if not ok then return false, errKey end
    return doRelaunch(src)
end

function Ops.cancel(src, reason)
    local ok, errKey = allowed(src)
    if not ok then return false, errKey end
    local text, rErr = cleanReason(reason)
    if not text then return false, rErr end
    return doCancel(src, text, false)
end

function Ops.join(src, opId)
    src = toSrc(src)
    if not src then return false, 'err.invalid_payload' end
    local officer, errKey = getOfficer(src)
    if not officer then return false, errKey or 'err.not_police' end
    local max = maxFor()
    -- The operation's state; run once before and once after the checks that may yield.
    local function stateCheck()
        local c = op
        if not c then return nil, 'err.op_none' end
        if opId ~= nil and opId ~= c.id then return nil, 'err.op_not_found' end
        if c.status ~= 'joining' or c.joinClosed or not c.joinEndsAt or os.time() >= c.joinEndsAt then
            return nil, 'err.op_join_closed'
        end
        for _, p in ipairs(c.participants) do
            if p.src == src or p.citizenid == officer.citizenid then return nil, 'err.op_already_joined' end
        end
        if #c.participants >= max then return nil, 'err.op_full' end
        return c
    end
    local cur, why = stateCheck()
    if not cur then return false, why end
    if inArena(src) then return false, 'err.in_arena' end
    if onRun(src) then return false, 'err.already_on_run' end
    if isOnCall(src) then return false, 'err.on_call' end          -- may yield (active-call lookup)
    -- No yields below: the state is checked again and the change happens with it.
    cur, why = stateCheck()
    if not cur then return false, why end
    if onRun(src) then return false, 'err.already_on_run' end
    local now = os.time()
    cur.participants[#cur.participants + 1] = {
        src = src, citizenid = officer.citizenid, name = CP.U.clip(officer.name or '?', 64),
        callsign = officer.callsign and CP.U.clip(officer.callsign, 32) or nil,
        department = officer.department, departmentShort = officer.departmentShort or '', rank = officer.rank or '',
        joinedAt = now,
    }
    broadcast(nil)
    CP.log(TAG, 'operation %d: %d joined (%d/%d)', cur.id, src, #cur.participants, max)
    return true, { id = cur.id, joined = #cur.participants, max = max }
end

-- A joiner who drops, unloads or no longer qualifies leaves the join list (runs handle the run itself).
local function removeJoiner(src)
    src = toSrc(src)
    local cur = op
    if not src or not cur or cur.status ~= 'joining' then return end
    for i = #cur.participants, 1, -1 do
        if cur.participants[i].src == src then
            table.remove(cur.participants, i)
            broadcast(nil)
            CP.log(TAG, 'operation %d: %d left the join list', cur.id, src)
        end
    end
end

function Ops.onRunEnded(run, state)
    local cur = op
    if not cur or type(run) ~= 'table' then return end
    if not cur.runId or run.id ~= cur.runId then return end
    if run.operationId ~= nil and run.operationId ~= cur.id then return end
    cur.runId = nil
    cur.runMissingSince = nil
    cur.lastRun = { runId = run.id, state = state, endedAt = os.time() }
    if state == 'completed' then
        finish(cur)
    else
        local reason = state == 'failed' and 'failed' or 'abandoned'
        webhook(reason, cur)
        toWaiting(cur, reason, true)
    end
end

-- ── views ───────────────────────────────────────────────────────────────────
function Ops.boardCard(src)
    local cur = op
    if not cur then return nil end
    src = toSrc(src)
    local now = os.time()
    local def = missionDef(cur.missionId)
    local max = maxFor()
    local joined, mine = 0, false
    local run = runGet(cur.runId)
    if run then
        for _, s in ipairs(activeSrcs(run)) do
            joined = joined + 1
            if s == src then mine = true end
        end
    else
        joined = #cur.participants
        for _, p in ipairs(cur.participants) do
            if p.src == src then mine = true end
        end
    end
    local open = cur.status == 'joining' and not cur.joinClosed and cur.joinEndsAt ~= nil and cur.joinEndsAt > now
    local canJoin = open and not mine and joined < max and src ~= nil and not onRun(src) and not inArena(src) and not isOnCall(src)
    return {
        id = cur.id, missionLabel = cur.missionLabel, launcher = cur.launcher or '?', status = cur.status,
        joined = joined, max = max, joinedByMe = mine, canJoin = canJoin == true,
        joinEndsIn = open and (cur.joinEndsAt - now) or nil,
        missionType = cur.missionType, missionTypeLabel = typeLabel(cur.missionType),
        description = def and def.description or nil, min = minFor(def), runState = run and run.state or nil,
    }
end

local function opView(cur, viewer, now)
    local def = missionDef(cur.missionId)
    local min, max = minFor(def), maxFor()
    local participants = {}
    local run = runGet(cur.runId)
    local runState, tier, tierExpected, remaining = nil, nil, true, nil
    if run then
        runState = run.state
        for _, s in ipairs(run.order or {}) do
            local p = run.participants and run.participants[s]
            if p then
                participants[#participants + 1] = {
                    src = s, name = p.name or ('#' .. s), callsign = p.callsign, departmentShort = p.departmentShort or '',
                    department = p.department, status = p.status == 'active' and 'active' or 'left', arrived = p.arrived == true,
                }
            end
        end
        if run.state == 'in_progress' and type(run.tier) == 'table' and run.tier.tier then
            tier, tierExpected = run.tier.tier, false
        else
            tier = run.expectedTier or tierName(#participants)
        end
        local okR, left = call('Runs', 'remaining', run)
        remaining = okR and tonumber(left) or nil
    else
        for _, p in ipairs(cur.participants) do
            participants[#participants + 1] = {
                src = p.src, name = p.name, callsign = p.callsign, departmentShort = p.departmentShort or '',
                department = p.department, status = cur.status == 'joining' and 'joined' or 'waiting', arrived = false,
            }
        end
        tier = tierName(math.max(#participants, min))
    end
    local counts, order = {}, {}
    local joined = 0
    for _, p in ipairs(participants) do
        if p.status ~= 'left' then
            joined = joined + 1
            local k = p.departmentShort ~= '' and p.departmentShort or '?'
            if not counts[k] then counts[k] = 0; order[#order + 1] = k end
            counts[k] = counts[k] + 1
        end
    end
    table.sort(order)
    local departments = {}
    for _, k in ipairs(order) do departments[#departments + 1] = { short = k, count = counts[k] } end

    local joining = cur.status == 'joining'
    local canStart, startBlocked = false, nil
    if joining then
        if cur.joinClosed then
            startBlocked = 'sup.crossdept.start_blocked_starting'
        elseif #cur.participants < min then
            startBlocked = 'sup.crossdept.start_blocked_min'
        elseif not mayStart(viewer, cur) then
            startBlocked = 'sup.crossdept.start_blocked_launcher'
        else
            canStart = true
        end
    end
    return {
        id = cur.id, missionId = cur.missionId, missionLabel = cur.missionLabel, missionType = cur.missionType,
        missionTypeLabel = typeLabel(cur.missionType), difficulty = cur.difficulty,
        launcher = cur.launcher or '?', launcherCallsign = cur.launcherCallsign, launcherDepartment = cur.launcherDepartment,
        launchedAt = cur.createdAt, status = cur.status, runState = runState, runId = run and run.id or nil,
        participants = participants, departments = departments, joined = joined, max = max, min = min,
        joinEndsIn = joining and cur.joinEndsAt and math.max(0, cur.joinEndsAt - now) or nil,
        idleCancelIn = (cur.status == 'waiting') and math.max(0, (cur.idleSince or now) + cfgInt('idleCancel', 1800) - now) or nil,
        tier = tier, tierExpected = tierExpected, remaining = remaining,
        waitingReason = cur.waitingReason, attempt = cur.attempt or 1,
        canStart = canStart, startBlocked = startBlocked,
        canRelaunch = cur.status == 'waiting', canCancel = true,
    }
end

function Ops.view(src)
    local now = os.time()
    local out = {
        operation = nil, cooldownLeft = Ops.cooldownLeft(), cooldown = cfgInt('cooldown', 1800),
        joinWindow = cfgInt('joinWindow', 300), idleCancel = cfgInt('idleCancel', 1800), maxParticipants = maxFor(),
        crossBonus = tonumber(Config.CrossDepartmentPoints) or 1.10,
        enabled = cfg().enabled ~= false, canLaunch = false, launchBlocked = nil, serverTime = now,
    }
    if op then out.operation = opView(op, src, now) end
    if not ready then
        out.launchBlocked = 'err.op_not_ready'
    elseif cfg().enabled == false then
        out.launchBlocked = 'err.op_disabled'
    elseif op then
        out.launchBlocked = 'err.op_active'
    elseif out.cooldownLeft > 0 then
        out.launchBlocked = 'err.op_cooldown'
    else
        out.canLaunch = true
    end
    if not op then out.eligibleMissions = eligibleMissions() end
    return out
end

-- ── net ─────────────────────────────────────────────────────────────────────
local function parseMissionId(payload)
    if type(payload) == 'table' then payload = payload.missionId end
    if type(payload) ~= 'string' or #payload == 0 or #payload > 40 or not payload:match('^[%a][%w_]*$') then return nil end
    return payload
end

local function parseOpId(payload)
    if type(payload) == 'table' then payload = payload.operationId or payload.id end
    if payload == nil then return nil, true end
    if type(payload) ~= 'number' and type(payload) ~= 'string' then return nil, false end
    if type(payload) == 'string' and #payload > 12 then return nil, false end
    local n = math.tointeger(tonumber(payload))
    if not n or n <= 0 then return nil, false end
    return n, true
end

local function guarded(scope, handler)
    return function(src, payload)
        if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
        local ok, errKey = CP.Permissions.can(src, 'launchCrossDept')
        if not ok then return false, errKey or 'err.no_permission' end
        if scope == 'admin' and not isAdmin(src) then return false, 'err.no_permission' end
        return handler(src, payload)
    end
end

for _, scope in ipairs({ 'sup', 'admin' }) do
    CP.Net.action(('server:%s:opLaunch'):format(scope), guarded(scope, function(src, payload)
        local missionId = parseMissionId(payload)
        if not missionId then return false, 'err.invalid_payload' end
        return doLaunch(src, missionId)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opStart'):format(scope), guarded(scope, function(src)
        return doStartNow(src)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opRelaunch'):format(scope), guarded(scope, function(src)
        return doRelaunch(src)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opCancel'):format(scope), guarded(scope, function(src, payload)
        if type(payload) ~= 'table' then return false, 'err.op_reason_required' end
        local reason, errKey = cleanReason(payload.reason)
        if not reason then return false, errKey end
        return doCancel(src, reason, false)
    end), { rate = 2 })
end

CP.Net.action('server:joinOperation', function(src, payload)
    local opId, valid = parseOpId(payload)
    if not valid then return false, 'err.invalid_payload' end
    return Ops.join(src, opId)
end, { rate = 3 })

CP.Net.callback('sup:getOperation', function(src)
    if not (CP.Permissions and CP.Permissions.can) then return nil, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, 'launchCrossDept')
    if not ok then return nil, errKey or 'err.no_permission' end
    return Ops.view(src)
end, { rate = 4 })

AddEventHandler('playerDropped', function()
    local src = source
    removeJoiner(src)
end)

-- ── tick: join window, idle auto-cancel, a run that vanished ─────────────────
function Ops._tick()
    local cur = op
    if not cur then return end
    local now = os.time()
    if cur.status == 'joining' then
        if not busy and not cur.joinClosed and cur.joinEndsAt and now >= cur.joinEndsAt then
            startRun(nil, true)
        end
    elseif cur.status == 'running' then
        if runGet(cur.runId) then
            cur.runMissingSince = nil
        elseif not cur.runMissingSince then
            cur.runMissingSince = now
        elseif now - cur.runMissingSince >= RUN_MISSING_GRACE then
            CP.warn(TAG, 'operation %d: run %s ended without a report; treating it as failed', cur.id, tostring(cur.runId))
            Ops.onRunEnded({ id = cur.runId, operationId = cur.id }, 'failed')
        end
    elseif cur.status == 'waiting' then
        if now - (cur.idleSince or now) >= cfgInt('idleCancel', 1800) then
            doCancel(0, CP.L('sup.crossdept.reason_idle'), true)
        end
    end
end

-- ── start-up: restart safety, the last launch, listeners, the tick loop ─────
function Ops._init()
    CP.Migrations.ready()
    local ok, err = pcall(function()
        local n = MySQL.update.await("UPDATE cp_operations SET status = 'cancelled', ended_at = FROM_UNIXTIME(?) WHERE status IN ('joining', 'running', 'waiting')", { os.time() })
        if (tonumber(n) or 0) > 0 then
            CP.log(TAG, '%d operation(s) left active by the last server start marked cancelled', tonumber(n))
        end
        local ts = MySQL.scalar.await('SELECT UNIX_TIMESTAMP(MAX(created_at)) AS last_ts FROM cp_operations')
        lastLaunchAt = tonumber(ts)
    end)
    if not ok then CP.err(TAG, 'could not read cp_operations: %s', tostring(err)) end
    ready = true
end

CreateThread(function()
    Wait(0)
    Ops._init()
    if CP.Qbx and CP.Qbx.onPlayerUnload then CP.Qbx.onPlayerUnload(removeJoiner) end
    if CP.Access and CP.Access.onLost then CP.Access.onLost(function(src) removeJoiner(src) end) end
    while true do
        Wait(op and TICK_ACTIVE_MS or TICK_IDLE_MS)
        local okT, errT = pcall(Ops._tick)
        if not okT then CP.err(TAG, 'tick failed: %s', tostring(errT)) end
    end
end)

-- Test hooks (tests/teams_spec.lua).
function Ops._reset()
    op, lastLaunchAt, busy = nil, nil, false
end
function Ops._setLastLaunch(ts) lastLaunchAt = ts end
