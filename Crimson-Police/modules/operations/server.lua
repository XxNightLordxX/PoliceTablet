-- CP.Operations (server): Cross-Department Missions.

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

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

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

local function Cfg()
    return type(Config.CrossDept) == 'table' and Config.CrossDept or {}
end

local function CfgInt(key, default)
    local v = tonumber(Cfg()[key])
    if not v or v ~= v or v < 0 or v == math.huge then return default end
    return math.floor(v)
end

local function GetOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    local ok, officer, errKey = Call('Access', 'getOfficer', src)
    if not ok then return nil, 'err.internal' end
    return officer, errKey
end

local function IsAdmin(src)
    if src == 0 then return true end
    local ok, v = Call('Access', 'isAdmin', src)
    return ok and v == true
end

local function OnRun(src)
    local ok, run = Call('Runs', 'getBySrc', src)
    if ok and type(run) == 'table' then return true end
    local ok2, on = Call('Runs', 'isOnMission', src)
    return ok2 and on == true
end

local function InArena(src)
    local ok, v = Call('Alerts', 'inArena', src)
    return ok and v == true
end

local function IsOnCall(src)
    local ok, v = Call('Calls', 'isOnCall', src)
    return ok and v == true
end

local function RunGet(runId)
    if not runId then return nil end
    local ok, run = Call('Runs', 'get', runId)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function ActiveSrcs(run)
    local ok, list = Call('Runs', 'activeSrcs', run)
    if ok and type(list) == 'table' then return list end
    local out = {}
    for _, s in ipairs(run.order or {}) do
        local p = run.participants and run.participants[s]
        if p and p.status == 'active' then out[#out + 1] = s end
    end
    return out
end

local function Notify(src, kind, key, vars, opts)
    Call('Tablet', 'notify', src, kind, key, vars, opts)
end

-- The same toast for a list of players: CP.Tablet.notifyMany (deduplicated; never a -1 broadcast), else one
-- CP.Tablet.notify per player.
local function NotifyMany(srcs, kind, key, vars)
    if type(srcs) ~= 'table' or #srcs == 0 then return end
    if CP.Tablet and type(CP.Tablet.notifyMany) == 'function' then
        Call('Tablet', 'notifyMany', srcs, kind, key, vars)
        return
    end
    for _, s in ipairs(srcs) do Notify(s, kind, key, vars) end
end

-- Clip to at most n characters without ending inside a UTF-8 sequence (the cp_audit columns count
-- characters; a byte clip of an accented reason would lose text or break the sequence).
local function ClipChars(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if not utf8.len(s) then return CP.U.clip(s, n) end
    if utf8.len(s) <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1)
end

local function Push(src, topic, data)
    Call('Tablet', 'push', src, topic, data)
end

local function OnlinePlayers()
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then return list end
    local out = {}
    if GetPlayers then
        for _, s in ipairs(GetPlayers()) do
            local n = ToSrc(s)
            if n then out[#out + 1] = n end
        end
    end
    return out
end

local function MissionDef(id)
    local ok, def = Call('Missions', 'get', id)
    if ok and type(def) == 'table' then return def end
    return nil
end

local function TypeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return type(t) == 'table' and t.label or tostring(key or '')
end

local function TierName(n)
    local ok, row = Call('Scaling', 'tierFor', n)
    if ok and type(row) == 'table' then return row.tier end
    local list = Config.Scaling or {}
    for _, r in ipairs(list) do
        if (tonumber(r.maxParticipants) or 0) >= n then return r.tier end
    end
    return list[#list] and list[#list].tier or 'standard'
end

local function MinFor(def)
    local min = math.max(2, CfgInt('minParticipants', 2), math.tointeger(tonumber(def and def.minOfficers) or 1) or 1)
    return math.min(min, math.max(2, CfgInt('maxParticipants', 8)))
end

local function MaxFor()
    return math.max(2, CfgInt('maxParticipants', 8))
end

local function CleanReason(reason)
    if type(reason) ~= 'string' then return nil, 'err.op_reason_required' end
    reason = CP.U.trim((reason:gsub('%c', ' ')))
    if reason == '' then return nil, 'err.op_reason_required' end
    -- Characters, not bytes (the UI counts characters; accented text is multi-byte).
    local len = utf8.len(reason)
    if not len then return nil, 'err.invalid_payload' end
    if len > REASON_MAX then return nil, 'err.op_reason_too_long' end
    return reason
end

-- ============================================================================
--              DATABASE (ordered, never blocks the state machine)
-- ============================================================================

local function DbRun(sql, params)
    dbQueue[#dbQueue + 1] = { sql = sql, params = params }
    if dbWorker then return end
    dbWorker = true
    CreateThread(function()
        while #dbQueue > 0 do
            local q = table.remove(dbQueue, 1)
            local ok, err = pcall(MySQL.update.await, q.sql, q.params)
            if not ok then
                CP.err(TAG, '%s write failed: %s', CP.Storage and CP.Storage.name() or 'database', tostring(err))
            end
        end
        dbWorker = false
    end)
end

local function DbStatus(id, status, final)
    if final then
        DbRun('UPDATE cp_operations SET status = ?, ended_at = FROM_UNIXTIME(?) WHERE id = ?',
            { status, os.time(), id })
    else
        DbRun('UPDATE cp_operations SET status = ? WHERE id = ?', { status, id })
    end
end

-- ============================================================================
--                              AUDIT AND WEBHOOK
-- ============================================================================

local function RoleOf(src)
    if src == 0 then return 'console' end
    return IsAdmin(src) and 'admin' or 'supervisor'
end

local function Audit(src, cur, action, oldV, newV, reason)
    local target = ClipChars(('#%s %s'):format(tostring(cur.id), tostring(cur.missionId)), 64)
    Call('Admin', 'audit', src == 0 and 'console' or src, RoleOf(src), 'operations', action, target,
        oldV ~= nil and ClipChars(tostring(oldV), 64) or nil, newV ~= nil and ClipChars(tostring(newV), 64) or nil,
        reason ~= nil and ClipChars(tostring(reason), 255) or nil)
end

local function Webhook(kind, cur, extra)
    local vars = { mission = cur.missionLabel, id = cur.id, launcher = cur.launcher or '?' }
    local fields = {
        {
            name = CP.L('sup.crossdept.webhook_field_mission'),
            value = ('%s (%s)'):format(cur.missionLabel, cur.missionId),
            inline = true,
        },
        { name = CP.L('sup.crossdept.webhook_field_launcher'), value = tostring(cur.launcher or '?'), inline = true },
    }
    if type(extra) == 'table' then
        for _, f in ipairs(extra) do fields[#fields + 1] = f end
    end
    Call('Admin', 'webhook', 'operations', CP.L('sup.crossdept.webhook_' .. kind .. '_title', vars),
        CP.L('sup.crossdept.webhook_' .. kind .. '_text', vars), fields)
end

-- ============================================================================
--                                NOTIFICATIONS
-- ============================================================================

local function PushData()
    return { id = op and op.id or false, status = op and op.status or false }
end

-- Pushes 'operation' + 'board' to every department member online ('operation' to admins too) and, with a
-- state, client:operation to every on-duty officer. Runs in its own thread (getOfficer may wait).
local function Broadcast(state, label, extra)
    local data = PushData()
    CreateThread(function()
        for _, p in ipairs(OnlinePlayers()) do
            p = ToSrc(p)
            if p then
                local okI, info = Call('Qbx', 'getInfo', p)
                local job = okI and type(info) == 'table' and type(info.job) == 'table' and info.job or nil
                local okD, dept = false, nil
                if job then okD, dept = Call('Access', 'departmentForJob', job.name) end
                if okD and dept then
                    Push(p, 'operation', data)
                    Push(p, 'board', data)
                    if state and job.onduty and GetOfficer(p) then
                        TriggerClientEvent(CP.e('client:operation'), p, state, label, extra)
                    end
                elseif IsAdmin(p) then
                    Push(p, 'operation', data)
                end
            end
        end
    end)
end

-- A toast for every online player who may launch / relaunch / cancel (supervisors with the permission, admins).
local function NotifySupervisors(kind, key, vars)
    CreateThread(function()
        local targets = {}
        for _, p in ipairs(OnlinePlayers()) do
            p = ToSrc(p)
            if p then
                local ok, allowed = Call('Permissions', 'can', p, 'launchCrossDept')
                if ok and allowed then targets[#targets + 1] = p end
            end
        end
        NotifyMany(targets, kind, key, vars)
    end)
end

-- ============================================================================
--                                 ELIGIBILITY
-- ============================================================================

function Ops.eligible(def)
    if type(def) ~= 'table' or type(def.id) ~= 'string' then return false, 'err.op_mission_unknown' end
    if def.isBoss == true or def.id == BOSS_ID then return false, 'err.op_mission_boss' end
    if def.status ~= nil and def.status ~= 'published' then return false, 'err.op_mission_disabled' end
    if CP.Missions and CP.Missions.isEnabled then
        local ok, enabled = Call('Missions', 'isEnabled', def.id)
        if not ok or not enabled then return false, 'err.op_mission_disabled' end
    end
    if type(def.departments) == 'table' and next(def.departments) ~= nil then
        return false, 'err.op_mission_departments'
    end
    if (tonumber(def.maxOfficers) or 1) < 2 then return false, 'err.op_mission_solo' end
    return true
end

local function EligibleMissions()
    local out = {}
    local ok, list = Call('Missions', 'list')
    if not ok or type(list) ~= 'table' then return out end
    for _, def in ipairs(list) do
        if Ops.eligible(def) then
            out[#out + 1] = {
                id = def.id,
                label = def.label or def.id,
                type = def.type,
                typeLabel = TypeLabel(def.type),
                difficulty = tonumber(def.difficulty) or 1,
                minOfficers = MinFor(def),
                maxOfficers = MaxFor(),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.label ~= b.label then return tostring(a.label) < tostring(b.label) end
        return a.id < b.id
    end)
    return out
end

-- ============================================================================
--                                    STATE
-- ============================================================================

function Ops.active()
    return op
end

function Ops.isLocked()
    return op ~= nil and ACTIVE[op.status] == true
end

function Ops.cooldownLeft()
    if not lastLaunchAt then return 0 end
    local left = lastLaunchAt + CfgInt('cooldown', 1800) - os.time()
    return left > 0 and left or 0
end

local function ActorOf(src)
    local officer = GetOfficer(src)
    local okI, info = Call('Qbx', 'getInfo', src)
    info = okI and type(info) == 'table' and info or nil
    local citizenid = (officer and officer.citizenid) or (info and info.citizenid)
    local name = (officer and officer.name) or (info and info.name) or (GetPlayerName and GetPlayerName(src))
        or ('#' .. tostring(src))
    return {
        src = src,
        citizenid = citizenid,
        name = CP.U.clip(name, 64),
        callsign = officer and officer.callsign or nil,
        departmentShort = officer and officer.departmentShort or nil,
    }
end

-- May src tap Start now? The person who opened this join window, an admin, or (when that person is
-- offline) anyone with the permission.
local function MayStart(src, cur)
    if src == 0 or IsAdmin(src) then return true end
    local okI, info = Call('Qbx', 'getInfo', src)
    local cid = okI and type(info) == 'table' and info.citizenid or nil
    if cid and cid == cur.windowBy then return true end
    local okS, ownerSrc = Call('Qbx', 'getByCitizenId', cur.windowBy)
    return not (okS and ownerSrc)
end

-- fromRun: the operation's run just ended (the idle clock starts now). Otherwise (a join window closed
-- without a run) the clock keeps counting from the launch or the end of the last run.
local function ToWaiting(cur, reason, fromRun)
    cur.status = 'waiting'
    cur.runId = nil
    cur.runMissingSince = nil
    cur.joinEndsAt = nil
    cur.joinClosed = nil
    cur.waitingReason = reason
    if fromRun or not cur.idleSince then cur.idleSince = os.time() end
    DbStatus(cur.id, 'waiting', false)
    Broadcast(nil)
    NotifySupervisors('warning', 'sup.crossdept.notify_waiting_' .. reason, { mission = cur.missionLabel })
    CP.log(TAG, 'operation %d waiting (%s)', cur.id, reason)
end

local function Finish(cur)
    if op ~= cur then return end
    op = nil
    cur.status = 'completed'
    cur.runId = nil
    DbStatus(cur.id, 'completed', true)
    Broadcast('ended', cur.missionLabel, { id = cur.id })
    Webhook('completed', cur)
    CP.log(TAG, 'operation %d completed', cur.id)
end

local function CancelInternal(cur, actorSrc, reason, auto)
    if op ~= cur then return false, 'err.op_none' end
    local before = cur.status
    op = nil                                   -- the board lock lifts at once
    cur.status = 'cancelled'
    local affected, seen = {}, {}
    local run = RunGet(cur.runId)
    cur.runId = nil
    if run then
        for _, s in ipairs(ActiveSrcs(run)) do
            if not seen[s] then seen[s] = true; affected[#affected + 1] = s end
        end
    elseif before == 'joining' then
        for _, p in ipairs(cur.participants) do
            if not seen[p.src] then seen[p.src] = true; affected[#affected + 1] = p.src end
        end
    end
    DbStatus(cur.id, 'cancelled', true)
    if run then
        -- Everyone still on the run leaves it: Abandoned, end reason cancelled (no cooldown, no penalty).
        for _, s in ipairs(affected) do
            Call('Runs', 'removeParticipant', run, s, 'cancelled')
        end
    end
    Broadcast('cancelled', cur.missionLabel, { id = cur.id })
    NotifyMany(affected, 'warning', 'officer.op.cancelled_participant', { mission = cur.missionLabel, reason = reason })
    Audit(actorSrc, cur, auto and 'opAutoCancel' or 'opCancel', before, 'cancelled', reason)
    CP.log(TAG, 'operation %d cancelled (%s)', cur.id, tostring(reason))
    return true, { id = cur.id }
end

-- ============================================================================
--                                    START
-- ============================================================================

local function DoStart(cur, actorSrc, auto)
    cur.joinClosed = true                      -- nobody joins while the participants are checked
    local valid, dropped = {}, {}
    for _, p in ipairs(CP.U.copy(cur.participants)) do
        local o = GetOfficer(p.src)
        if o and o.citizenid == p.citizenid and not OnRun(p.src) and not InArena(p.src) and not IsOnCall(p.src) then
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
        Notify(p.src, 'warning', 'officer.op.removed_at_start', { mission = cur.missionLabel })
    end

    local def = MissionDef(cur.missionId)
    local okE = Ops.eligible(def)
    if not okE then
        cur.joinClosed = nil
        if auto then CancelInternal(cur, 0, CP.L('sup.crossdept.reason_mission_unavailable'), true) end
        return false, 'err.op_mission_unavailable'
    end
    if #valid < MinFor(def) then
        cur.joinClosed = nil
        if auto then ToWaiting(cur, 'not_enough') elseif #dropped > 0 then Broadcast(nil) end
        return false, 'err.op_not_enough'
    end

    local srcs = {}
    for i, o in ipairs(valid) do srcs[i] = o.src end
    local seed = (os.time() ~ (GetGameTimer and GetGameTimer() or 0) ~ (cur.id * 7919)) & 0x7FFFFFFF
    local okP, index = Call('Draw', 'pickLocation', def, srcs, CP.U.rng(seed))
    if not okP or not index then
        cur.joinClosed = nil
        if auto then ToWaiting(cur, 'no_location') end
        return false, 'err.no_location'
    end
    if op ~= cur or cur.status ~= 'joining' then return false, 'err.op_not_joining' end

    local okC, run, createErr = Call('Runs', 'create', {
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
        if op == cur and auto then ToWaiting(cur, 'start_failed') end
        return false, createErr or 'err.run_create_failed'
    end
    if op ~= cur then
        -- Cancelled while the run was being created: nobody may stay on it.
        for _, s in ipairs(ActiveSrcs(run)) do Call('Runs', 'removeParticipant', run, s, 'cancelled') end
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
    DbStatus(cur.id, 'running', false)
    Broadcast('started', cur.missionLabel, { id = cur.id })
    NotifyMany(srcs, 'success', 'officer.op.started_participant', { mission = cur.missionLabel })
    if actorSrc then
        Audit(actorSrc, cur, 'opStart', cur.attempt, #valid, nil)
    else
        Webhook('started', cur,
            { { name = CP.L('sup.crossdept.webhook_field_participants'), value = tostring(#valid), inline = true } })
    end
    CP.log(TAG, 'operation %d started run %s with %d participant(s)', cur.id, tostring(run.id), #valid)
    return true, { runId = run.id, participants = #valid }
end

local function StartRun(actorSrc, auto)
    local cur = op
    if not cur or cur.status ~= 'joining' then return false, 'err.op_not_joining' end
    if cur.joinClosed or busy then return false, 'err.busy' end
    busy = true
    local okCall, ok, data = pcall(DoStart, cur, actorSrc, auto)
    busy = false
    if not okCall then
        CP.err(TAG, 'start of operation %d failed: %s', cur.id, tostring(ok))
        cur.joinClosed = nil
        if auto and op == cur and cur.status == 'joining' then ToWaiting(cur, 'start_failed') end
        return false, 'err.internal'
    end
    return ok, data
end

-- ============================================================================
--                     ACTIONS (permission already checked)
-- ============================================================================

local function DoLaunch(src, missionId)
    if not ready then return false, 'err.op_not_ready' end
    if Cfg().enabled == false then return false, 'err.op_disabled' end
    if op then return false, 'err.op_active' end
    if busy then return false, 'err.busy' end
    if Ops.cooldownLeft() > 0 then return false, 'err.op_cooldown' end
    local def = MissionDef(missionId)
    if not def then return false, 'err.op_mission_unknown' end
    local okE, why = Ops.eligible(def)
    if not okE then return false, why end

    busy = true
    local okCall, ok, data = pcall(function()
        local actor = ActorOf(src)
        if not actor.citizenid then return false, 'err.not_in_game' end
        if op then return false, 'err.op_active' end
        local now = os.time()
        local id = MySQL.insert.await(
            'INSERT INTO cp_operations (mission_id, launched_by, status, created_at) VALUES (?, ?, ?, FROM_UNIXTIME(?))',
            { def.id, CP.U.clip(actor.citizenid, 50), 'joining', now })
        id = math.tointeger(tonumber(id))
        if not id or id <= 0 then return false, 'err.internal' end
        lastLaunchAt = now
        op = {
            id = id,
            missionId = def.id,
            missionLabel = def.label or def.id,
            missionType = def.type,
            difficulty = tonumber(def.difficulty) or 1,
            launchedBy = actor.citizenid,
            launcher = actor.name,
            launcherCallsign = actor.callsign,
            launcherDepartment = actor.departmentShort,
            windowBy = actor.citizenid,
            status = 'joining',
            createdAt = now,
            joinEndsAt = now + CfgInt('joinWindow', 300),
            participants = {},
            runId = nil,
            idleSince = now,
            waitingReason = nil,
            attempt = 1,
        }
        Broadcast('launched', op.missionLabel, { id = id, relaunched = false })
        Audit(src, op, 'opLaunch', nil, def.id, nil)
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

local function DoStartNow(src)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if cur.status ~= 'joining' then return false, 'err.op_not_joining' end
    if not MayStart(src, cur) then return false, 'err.op_not_launcher' end
    return StartRun(src, false)
end

local function DoRelaunch(src)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if cur.status ~= 'waiting' then return false, 'err.op_not_waiting' end
    if busy then return false, 'err.busy' end
    local okE = Ops.eligible(MissionDef(cur.missionId))
    if not okE then return false, 'err.op_mission_unavailable' end
    local actor = ActorOf(src)
    if op ~= cur or cur.status ~= 'waiting' then return false, 'err.op_not_waiting' end
    local now = os.time()
    local before = cur.waitingReason
    cur.status = 'joining'
    cur.participants = {}
    cur.runId = nil
    cur.joinEndsAt = now + CfgInt('joinWindow', 300)
    cur.joinClosed = nil
    cur.waitingReason = nil
    cur.windowBy = actor.citizenid or cur.windowBy
    -- The idle clock (no run since ...) keeps running: a relaunch opens a join window, it is not a run.
    cur.idleSince = cur.idleSince or now
    cur.attempt = (cur.attempt or 1) + 1
    DbStatus(cur.id, 'joining', false)
    Broadcast('launched', cur.missionLabel, { id = cur.id, relaunched = true })
    Audit(src, cur, 'opRelaunch', before, cur.attempt, nil)
    return true, { id = cur.id }
end

local function DoCancel(src, reason, auto)
    local cur = op
    if not cur then return false, 'err.op_none' end
    if busy and not auto then return false, 'err.busy' end
    return CancelInternal(cur, src, reason, auto)
end

-- ============================================================================
--                               PUBLIC WRAPPERS
-- ============================================================================
-- Permission checked here for callers from other modules.

local function Allowed(src)
    if src == 0 then return true end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local ok, can, errKey = Call('Permissions', 'can', src, 'launchCrossDept')
    if not ok or not can then return false, errKey or 'err.no_permission' end
    return true
end

function Ops.launch(src, missionId)
    local ok, errKey = Allowed(src)
    if not ok then return false, errKey end
    return DoLaunch(src, missionId)
end

function Ops.startNow(src)
    local ok, errKey = Allowed(src)
    if not ok then return false, errKey end
    return DoStartNow(src)
end

function Ops.relaunch(src)
    local ok, errKey = Allowed(src)
    if not ok then return false, errKey end
    return DoRelaunch(src)
end

function Ops.cancel(src, reason)
    local ok, errKey = Allowed(src)
    if not ok then return false, errKey end
    local text, rErr = CleanReason(reason)
    if not text then return false, rErr end
    return DoCancel(src, text, false)
end

function Ops.join(src, opId)
    src = ToSrc(src)
    if not src then return false, 'err.invalid_payload' end
    local officer, errKey = GetOfficer(src)
    if not officer then return false, errKey or 'err.not_police' end
    local max = MaxFor()
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
    if InArena(src) then return false, 'err.in_arena' end
    if OnRun(src) then return false, 'err.already_on_run' end
    if IsOnCall(src) then
        return false, 'err.on_call'
    end -- may yield (active-call lookup)
    -- No yields below: the state is checked again and the change happens with it.
    cur, why = stateCheck()
    if not cur then return false, why end
    if OnRun(src) then return false, 'err.already_on_run' end
    local now = os.time()
    cur.participants[#cur.participants + 1] = {
        src = src,
        citizenid = officer.citizenid,
        name = CP.U.clip(officer.name or '?', 64),
        callsign = officer.callsign and CP.U.clip(officer.callsign, 32) or nil,
        department = officer.department,
        departmentShort = officer.departmentShort or '',
        rank = officer.rank or '',
        joinedAt = now,
    }
    Broadcast(nil)
    CP.log(TAG, 'operation %d: %d joined (%d/%d)', cur.id, src, #cur.participants, max)
    return true, { id = cur.id, joined = #cur.participants, max = max }
end

-- A joiner who drops, unloads or no longer qualifies leaves the join list (runs handle the run itself).
local function RemoveJoiner(src)
    src = ToSrc(src)
    local cur = op
    if not src or not cur or cur.status ~= 'joining' then return end
    for i = #cur.participants, 1, -1 do
        if cur.participants[i].src == src then
            table.remove(cur.participants, i)
            Broadcast(nil)
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
        Finish(cur)
    else
        local reason = state == 'failed' and 'failed' or 'abandoned'
        Webhook(reason, cur)
        ToWaiting(cur, reason, true)
    end
end

-- ============================================================================
--                                    VIEWS
-- ============================================================================

function Ops.boardCard(src)
    local cur = op
    if not cur then return nil end
    src = ToSrc(src)
    local now = os.time()
    local def = MissionDef(cur.missionId)
    local max = MaxFor()
    local joined, mine = 0, false
    local run = RunGet(cur.runId)
    if run then
        for _, s in ipairs(ActiveSrcs(run)) do
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
    -- joinBlocked (extra, docs/notes/run_ui.md): why this viewer cannot join, the error key Join would return.
    local joinBlocked = nil
    if not open then
        joinBlocked = 'err.op_join_closed'
    elseif mine then
        joinBlocked = 'err.op_already_joined'
    elseif joined >= max then
        joinBlocked = 'err.op_full'
    elseif src == nil then
        joinBlocked = 'err.invalid_payload'
    elseif InArena(src) then
        joinBlocked = 'err.in_arena'
    elseif OnRun(src) then
        joinBlocked = 'err.already_on_run'
    elseif IsOnCall(src) then
        joinBlocked = 'err.on_call'
    end
    return {
        id = cur.id,
        missionLabel = cur.missionLabel,
        launcher = cur.launcher or '?',
        status = cur.status,
        joined = joined,
        max = max,
        joinedByMe = mine,
        canJoin = joinBlocked == nil,
        joinBlocked = joinBlocked,
        joinEndsIn = open and (cur.joinEndsAt - now) or nil,
        missionType = cur.missionType,
        missionTypeLabel = TypeLabel(cur.missionType),
        description = def and def.description or nil,
        min = MinFor(def),
        runState = run and run.state or nil,
    }
end

local function OpView(cur, viewer, now)
    local def = MissionDef(cur.missionId)
    local min, max = MinFor(def), MaxFor()
    local participants = {}
    local run = RunGet(cur.runId)
    local runState, tier, tierExpected, remaining = nil, nil, true, nil
    if run then
        runState = run.state
        for _, s in ipairs(run.order or {}) do
            local p = run.participants and run.participants[s]
            if p then
                participants[#participants + 1] = {
                    src = s,
                    name = p.name or ('#' .. s),
                    callsign = p.callsign,
                    departmentShort = p.departmentShort or '',
                    department = p.department,
                    status = p.status == 'active' and 'active' or 'left',
                    arrived = p.arrived == true,
                }
            end
        end
        if run.state == 'in_progress' and type(run.tier) == 'table' and run.tier.tier then
            tier, tierExpected = run.tier.tier, false
        else
            tier = run.expectedTier or TierName(#participants)
        end
        local okR, left = Call('Runs', 'remaining', run)
        remaining = okR and tonumber(left) or nil
    else
        for _, p in ipairs(cur.participants) do
            participants[#participants + 1] = {
                src = p.src,
                name = p.name,
                callsign = p.callsign,
                departmentShort = p.departmentShort or '',
                department = p.department,
                status = cur.status == 'joining' and 'joined' or 'waiting',
                arrived = false,
            }
        end
        tier = TierName(math.max(#participants, min))
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
        elseif not MayStart(viewer, cur) then
            startBlocked = 'sup.crossdept.start_blocked_launcher'
        else
            canStart = true
        end
    end
    return {
        id = cur.id,
        missionId = cur.missionId,
        missionLabel = cur.missionLabel,
        missionType = cur.missionType,
        missionTypeLabel = TypeLabel(cur.missionType),
        difficulty = cur.difficulty,
        launcher = cur.launcher or '?',
        launcherCallsign = cur.launcherCallsign,
        launcherDepartment = cur.launcherDepartment,
        launchedAt = cur.createdAt,
        status = cur.status,
        runState = runState,
        runId = run and run.id or nil,
        participants = participants,
        departments = departments,
        joined = joined,
        max = max,
        min = min,
        joinEndsIn = joining and cur.joinEndsAt and math.max(0, cur.joinEndsAt - now) or nil,
        idleCancelIn = (cur.status == 'waiting')
                and math.max(0, (cur.idleSince or now) + CfgInt('idleCancel', 1800) - now)
            or nil,
        tier = tier,
        tierExpected = tierExpected,
        remaining = remaining,
        waitingReason = cur.waitingReason,
        attempt = cur.attempt or 1,
        canStart = canStart,
        startBlocked = startBlocked,
        canRelaunch = cur.status == 'waiting',
        canCancel = true,
    }
end

function Ops.view(src)
    local now = os.time()
    local out = {
        operation = nil,
        cooldownLeft = Ops.cooldownLeft(),
        cooldown = CfgInt('cooldown', 1800),
        joinWindow = CfgInt('joinWindow', 300),
        idleCancel = CfgInt('idleCancel', 1800),
        maxParticipants = MaxFor(),
        crossBonus = tonumber(Config.CrossDepartmentPoints) or 1.10,
        enabled = Cfg().enabled ~= false,
        canLaunch = false,
        launchBlocked = nil,
        serverTime = now,
    }
    if op then out.operation = OpView(op, src, now) end
    if not ready then
        out.launchBlocked = 'err.op_not_ready'
    elseif Cfg().enabled == false then
        out.launchBlocked = 'err.op_disabled'
    elseif op then
        out.launchBlocked = 'err.op_active'
    elseif out.cooldownLeft > 0 then
        out.launchBlocked = 'err.op_cooldown'
    else
        out.canLaunch = true
    end
    if not op then out.eligibleMissions = EligibleMissions() end
    return out
end

-- ============================================================================
--                                     NET
-- ============================================================================

local function ParseMissionId(payload)
    if type(payload) == 'table' then payload = payload.missionId end
    if type(payload) ~= 'string' or #payload == 0 or #payload > 40 or not payload:match('^[%a][%w_]*$') then
        return nil
    end
    return payload
end

local function ParseOpId(payload)
    if type(payload) == 'table' then payload = payload.operationId or payload.id end
    if payload == nil then return nil, true end
    if type(payload) ~= 'number' and type(payload) ~= 'string' then return nil, false end
    if type(payload) == 'string' and #payload > 12 then return nil, false end
    local n = math.tointeger(tonumber(payload))
    if not n or n <= 0 then return nil, false end
    return n, true
end

local function Guarded(scope, handler)
    return function(src, payload)
        if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
        local ok, errKey = CP.Permissions.can(src, 'launchCrossDept')
        if not ok then return false, errKey or 'err.no_permission' end
        if scope == 'admin' and not IsAdmin(src) then return false, 'err.no_permission' end
        return handler(src, payload)
    end
end

for _, scope in ipairs({ 'sup', 'admin' }) do
    CP.Net.action(('server:%s:opLaunch'):format(scope), Guarded(scope, function(src, payload)
        local missionId = ParseMissionId(payload)
        if not missionId then return false, 'err.invalid_payload' end
        return DoLaunch(src, missionId)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opStart'):format(scope), Guarded(scope, function(src)
        return DoStartNow(src)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opRelaunch'):format(scope), Guarded(scope, function(src)
        return DoRelaunch(src)
    end), { rate = 2 })

    CP.Net.action(('server:%s:opCancel'):format(scope), Guarded(scope, function(src, payload)
        if type(payload) ~= 'table' then return false, 'err.op_reason_required' end
        local reason, errKey = CleanReason(payload.reason)
        if not reason then return false, errKey end
        return DoCancel(src, reason, false)
    end), { rate = 2 })
end

CP.Net.action('server:joinOperation', function(src, payload)
    local opId, valid = ParseOpId(payload)
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
    RemoveJoiner(src)
end)

-- ============================================================================
--           TICK: join window, idle auto-cancel, a run that vanished
-- ============================================================================

function Ops._tick()
    local cur = op
    if not cur then return end
    local now = os.time()
    if cur.status == 'joining' then
        if not busy and not cur.joinClosed and cur.joinEndsAt and now >= cur.joinEndsAt then
            StartRun(nil, true)
        end
    elseif cur.status == 'running' then
        if RunGet(cur.runId) then
            cur.runMissingSince = nil
        elseif not cur.runMissingSince then
            cur.runMissingSince = now
        elseif now - cur.runMissingSince >= RUN_MISSING_GRACE then
            CP.warn(TAG, 'operation %d: run %s ended without a report; treating it as failed', cur.id,
                tostring(cur.runId))
            Ops.onRunEnded({ id = cur.runId, operationId = cur.id }, 'failed')
        end
    elseif cur.status == 'waiting' then
        if now - (cur.idleSince or now) >= CfgInt('idleCancel', 1800) then
            DoCancel(0, CP.L('sup.crossdept.reason_idle'), true)
        end
    end
end

-- ============================================================================
--                                   START-UP
-- ============================================================================
-- Restart safety, the last launch, listeners, the tick loop.

function Ops._init()
    CP.Migrations.ready()
    local ok, err = pcall(function()
        local n = MySQL.update.await(
            'UPDATE cp_operations SET status = \'cancelled\', ended_at = FROM_UNIXTIME(?) WHERE status IN (\'joining\', \'running\', \'waiting\')',
            { os.time() })
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
    if CP.Qbx and CP.Qbx.onPlayerUnload then CP.Qbx.onPlayerUnload(RemoveJoiner) end
    if CP.Access and CP.Access.onLost then CP.Access.onLost(function(src) RemoveJoiner(src) end) end
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
