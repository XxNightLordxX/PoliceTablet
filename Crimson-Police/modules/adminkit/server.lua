-- CP.AdminKit (server): the one wrapper every new admin action goes through (permission, rate, request id, reason,
-- typed word, preview, self, compare-and-set, audit, caches, toasts), bulk jobs, day counts and the busy lock.
-- CP.Maintenance: the maintenance lock of a storage copy or switch, a backup restore or a store left behind.

CP.AdminKit = CP.AdminKit or {}
CP.Maintenance = CP.Maintenance or {}
local Kit = CP.AdminKit
local Maint = CP.Maintenance
local U = CP.U
local TAG = 'adminkit'

local REASON_MAX = 255           -- characters (cp_audit.reason is VARCHAR(255) utf8mb4)
local PREVIEW_TTL = 120          -- seconds a preview token stays valid
local PREVIEW_MAX = 200          -- tokens kept at once (the oldest go first)
local JOB_BATCH = 50             -- rows per batch: WHERE id IN (50 placeholders), never UPDATE ... LIMIT
local JOB_RESUME_DELAY_MS = 5000 -- after start, so every module has registered its job kinds
local REQUEST_ID_PATTERN = '^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$'
local MAINT_KINDS = { storage = true, restore = true, left_behind = true }

local actions = {}           -- name -> { permKey, fn, opts } (AdminKit.run calls them directly)
local previews = {}          -- token -> { src, kind, hash, effect, expires }
local previewOrder = {}
local busy = nil             -- { kind, info, since } while one long job, copy, backup or restore runs
local jobKinds = {}          -- kind -> { batch = fn(job, ids), finish = fn(job), rollback = fn(job), label }
local maintenance = nil      -- { kind, info, since }

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n < 0 then return nil end
    return n
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false, nil end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

local function CitizenOf(src)
    local n = ToSrc(src)
    if not n or n == 0 then return nil end
    local ok, info = Call('Qbx', 'getInfo', n)
    if ok and type(info) == 'table' and type(info.citizenid) == 'string' and info.citizenid ~= '' then
        return info.citizenid
    end
    return nil
end

local function ActorId(src)
    local n = ToSrc(src) or 0
    if n == 0 then return 'console' end
    return CitizenOf(n) or ('player:%d'):format(n)
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function Encode(v)
    local ok, s = pcall(json.encode, v)
    if ok then return s end
    return nil
end

local function Decode(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return nil end
    local ok, t = pcall(json.decode, v)
    if ok then return t end
    return nil
end

-- Order-free fingerprint of a list of ids (numbers or texts).
local function IdsHash(ids)
    local list = {}
    for _, v in ipairs(type(ids) == 'table' and ids or {}) do list[#list + 1] = tostring(v) end
    table.sort(list)
    return ('%d:%s'):format(#list, U.hashHex(table.concat(list, ',')))
end

function Kit.uuid() return U.uuid() end

function Kit.validRequestId(v) return type(v) == 'string' and v:lower():match(REQUEST_ID_PATTERN) ~= nil end

-- ============================================================================
--                           R: REASON, T: TYPED WORD
-- ============================================================================

-- A reason: trimmed, 1 to 255 characters (UTF-8 characters, not bytes), no control characters.
function Kit.reason(v, optional)
    if v == nil or (type(v) == 'string' and U.trim(v) == '') then
        if optional then return nil end
        return nil, 'err.reason_required'
    end
    if type(v) ~= 'string' then return nil, 'err.reason_required' end
    local s = U.trim(v):gsub('[%c]', ' ')
    local n = utf8.len(s)
    if not n then return nil, 'err.reason_invalid' end
    if n > REASON_MAX then return nil, 'err.reason_too_long' end
    return s
end

-- The typed word the dialog asked for (trimmed, any case).
function Kit.confirmOk(given, word)
    if type(word) ~= 'string' or word == '' then return true end
    if type(given) ~= 'string' then return false end
    return U.trim(given):upper() == U.trim(word):upper()
end

-- ============================================================================
--                                 V: PREVIEWS
-- ============================================================================

local function DropExpired()
    local now = os.time()
    local keep = {}
    for _, token in ipairs(previewOrder) do
        local p = previews[token]
        if p and p.expires > now then keep[#keep + 1] = token else previews[token] = nil end
    end
    while #keep > PREVIEW_MAX do
        previews[table.remove(keep, 1)] = nil
    end
    previewOrder = keep
end

-- A token for the exact effect a read callback showed: bound to the admin, the kind and the affected ids.
function Kit.preview(src, kind, ids, effect)
    DropExpired()
    local token = U.uuid()
    previews[token] = {
        src = ToSrc(src) or 0,
        kind = tostring(kind),
        hash = IdsHash(ids),
        effect = effect,
        expires = os.time() + PREVIEW_TTL,
    }
    previewOrder[#previewOrder + 1] = token
    return token, previews[token].expires
end

-- ok, effect | false, errKey. A token is used once; a different admin, kind or set of ids refuses it.
function Kit.consume(src, token, kind, ids)
    if type(token) ~= 'string' or token == '' then return false, 'err.preview_missing' end
    local p = previews[token]
    if not p then return false, 'err.preview_expired' end
    if p.expires <= os.time() then
        previews[token] = nil
        return false, 'err.preview_expired'
    end
    if p.src ~= (ToSrc(src) or 0) or p.kind ~= tostring(kind) then return false, 'err.preview_missing' end
    if ids ~= nil and p.hash ~= IdsHash(ids) then
        previews[token] = nil
        return false, 'err.preview_stale'
    end
    previews[token] = nil
    return true, p.effect
end

-- ============================================================================
--                          S: THE ADMIN'S OWN RECORDS
-- ============================================================================
-- "Self" is every character of the acting player's license. The console is never self.

-- true when citizenid is one of src's characters; nil + 'err.self_unknown' when strict and a license is missing.
function Kit.isSelf(src, citizenid, strict)
    local n = ToSrc(src) or 0
    if n == 0 then return false end
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if CitizenOf(n) == citizenid then return true end
    local _, mine = Call('Access', 'licenseOfSrc', n)
    local _, theirs = Call('Access', 'licenseOf', citizenid)
    if type(mine) ~= 'string' or type(theirs) ~= 'string' then
        if strict then return nil, 'err.self_unknown' end
        return false, nil, true
    end
    return mine == theirs
end

-- true when any of src's characters took part in runUuid (live or archived rows) or is on it now.
function Kit.selfRun(src, runUuid)
    local n = ToSrc(src) or 0
    if n == 0 or type(runUuid) ~= 'string' or runUuid == '' then return false end
    local _, cids = Call('Access', 'selfCitizenids', n)
    if type(cids) ~= 'table' then cids = { CitizenOf(n) } end
    local ok, run = Call('Runs', 'get', runUuid)
    for _, cid in ipairs(cids) do
        if type(cid) == 'string' then
            if Has('Permissions', 'tookPart') and CP.Permissions.tookPart(cid, runUuid) then return true end
            if ok and type(run) == 'table' and type(run.participants) == 'table' then
                for _, p in pairs(run.participants) do
                    if type(p) == 'table' and p.citizenid == cid then return true end
                end
            end
        end
    end
    return false
end

-- ============================================================================
--                      K: COMPARE-AND-SET, I: ONE REQUEST
-- ============================================================================

-- An UPDATE whose WHERE names the expected old state: true when exactly one row changed, else err.state_changed.
function Kit.cas(sql, params)
    Db()
    local ok, n = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'compare-and-set failed: %s', tostring(n))
        return false, 'err.internal'
    end
    if (tonumber(n) or 0) < 1 then return false, 'err.state_changed' end
    return true
end

-- 'new' (go ahead), 'done' (stored result), 'busy' (the first copy is still running), or nil + errKey.
function Kit.claimRequest(requestId, action, src)
    if not Kit.validRequestId(requestId) then return nil, 'err.request_id' end
    Db()
    local rid = requestId:lower()
    local ok, n = pcall(MySQL.update.await,
        'INSERT IGNORE INTO cp_admin_requests (request_id, action, actor, created_at) VALUES (?, ?, ?, NOW())',
        { rid, tostring(action):sub(1, 40), ActorId(src) })
    if not ok then
        CP.err(TAG, 'request id %s could not be stored: %s', rid, tostring(n))
        return nil, 'err.internal'
    end
    if (tonumber(n) or 0) >= 1 then return 'new' end
    local okR, row = pcall(MySQL.single.await, 'SELECT action, result FROM cp_admin_requests WHERE request_id = ?',
        { rid })
    if not okR or type(row) ~= 'table' then return nil, 'err.internal' end
    if row.action ~= tostring(action):sub(1, 40) then return nil, 'err.request_id' end
    local stored = Decode(row.result)
    if type(stored) ~= 'table' then return 'busy' end
    return 'done', stored
end

function Kit.finishRequest(requestId, ok, data)
    if not Kit.validRequestId(requestId) then return end
    local payload = Encode({ ok = ok == true, data = data }) or Encode({ ok = ok == true })
    pcall(MySQL.update.await, 'UPDATE cp_admin_requests SET result = ? WHERE request_id = ?',
        { payload, requestId:lower() })
end

-- Nothing happened (a guard refused before the action): the same id may be sent again.
function Kit.releaseRequest(requestId)
    if not Kit.validRequestId(requestId) then return end
    pcall(MySQL.update.await, 'DELETE FROM cp_admin_requests WHERE request_id = ? AND result IS NULL',
        { requestId:lower() })
end

-- ============================================================================
--                        A: AUDIT, C: CACHES, N: TOASTS
-- ============================================================================

-- The audit row written now (the caller waits): its id, or false when the insert failed.
function Kit.auditSync(src, category, action, target, old, new, reason, opts)
    if not Has('Admin', 'auditSync') then return false end
    local n = ToSrc(src) or 0
    local actor = n > 0 and n or 'console'
    local role = n > 0 and 'admin' or 'console'
    local _, id = Call('Admin', 'auditSync', actor, role, category or 'audit', action, target, old, new, reason, opts)
    return id or false
end

-- admin:changed { kind, citizenid?, missionId? }: each module clears the caches it owns.
function Kit.changed(kind, citizenid, missionId)
    CP.Hooks.fire('admin:changed', { kind = kind, citizenid = citizenid, missionId = missionId })
end

-- A toast to an officer who is online (nothing when they are not).
function Kit.notify(citizenid, kind, key, vars)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local ok, s = Call('Qbx', 'getByCitizenId', citizenid)
    if not ok or not ToSrc(s) or ToSrc(s) == 0 then return false end
    local okN = Call('Tablet', 'notify', s, kind, key, vars)
    return okN
end

-- ============================================================================
--                      L AND DAY COUNTS (FROM SAVED ROWS)
-- ============================================================================

function Kit.dayStart(ts)
    ts = ts or Now()
    if CP.Schedule and CP.Schedule.dayStart then return CP.Schedule.dayStart(ts) end
    return ts - ts % 86400
end

function Kit.weekStart(ts)
    ts = ts or Now()
    if CP.Schedule and CP.Schedule.weekStart then return CP.Schedule.weekStart(ts) end
    return Kit.dayStart(ts)
end

-- n per window per target, whichever admin acts: the same key for every admin.
function Kit.targetOk(name, target, n, windowMs)
    return CP.Net.rateOk('target', ('%s:%s'):format(tostring(name), tostring(target)), n, windowMs)
end

-- cp_audit rows of action since the daily reset (or opts.since). opts: { target, actor, since }.
function Kit.dailyCount(action, opts)
    opts = opts or {}
    Db()
    local sql = 'SELECT COUNT(*) AS n FROM cp_audit WHERE action = ? AND created_at >= FROM_UNIXTIME(?)'
    local params = { tostring(action), opts.since or Kit.dayStart() }
    if opts.target ~= nil then
        sql = sql .. ' AND target = ?'
        params[#params + 1] = tostring(opts.target)
    end
    if opts.actor ~= nil then
        sql = sql .. ' AND actor = ?'
        params[#params + 1] = tostring(opts.actor)
    end
    local ok, n = pcall(MySQL.scalar.await, sql, params)
    if not ok then
        CP.err(TAG, 'day count of %s failed: %s', tostring(action), tostring(n))
        return nil
    end
    return math.floor(U.num(n))
end

-- The sum of a column of today's manual rows (manual_adjust, manual_cash ...) written by one actor.
-- opts: { missionIds = { 'manual_adjust' }, actor, src, column = 'final_points' | 'cash_base', negative, since }.
-- breakdown.by holds the actor; with src, every character of that player's license counts as the actor (one player,
-- one limit). The absolute value of signed points is summed in Lua.
function Kit.dailySum(opts)
    opts = opts or {}
    Db()
    local ids = type(opts.missionIds) == 'table' and opts.missionIds or { 'manual_adjust' }
    local marks = {}
    for i = 1, #ids do marks[i] = '?' end
    local column = opts.column == 'cash_base' and 'cash_base' or 'final_points'
    local sql = ([[SELECT %s AS v FROM cp_mission_runs WHERE mission_type = 'manual_award' AND mission_id IN (%s)
        AND voided = 0 AND created_at >= FROM_UNIXTIME(?)]]):format(column, table.concat(marks, ', '))
    local params = {}
    for i, v in ipairs(ids) do params[i] = v end
    params[#params + 1] = opts.since or Kit.dayStart()
    local actors, seen = {}, {}
    local function add(a)
        if a ~= nil and not seen[tostring(a)] then
            seen[tostring(a)] = true
            actors[#actors + 1] = tostring(a)
        end
    end
    add(opts.actor)
    local n = ToSrc(opts.src) or 0
    if n ~= 0 then
        add(ActorId(n))
        local okC, cids = Call('Access', 'selfCitizenids', n)
        for _, cid in ipairs(okC and type(cids) == 'table' and cids or {}) do add(cid) end
    end
    if #actors > 0 then
        local am = {}
        for i, a in ipairs(actors) do
            am[i] = '?'
            params[#params + 1] = a
        end
        sql = sql .. (' AND JSON_VALUE(breakdown, \'$.by\') IN (%s)'):format(table.concat(am, ', '))
    end
    local ok, rows = pcall(MySQL.query.await, sql, params)
    if not ok then
        CP.err(TAG, 'day sum failed: %s', tostring(rows))
        return nil
    end
    local sum = 0
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do sum = sum + math.abs(math.floor(U.num(r.v))) end
    return sum
end

-- ============================================================================
--                                THE BUSY LOCK
-- ============================================================================
-- One long piece of work server-wide: a bulk job, a storage copy, a backup or a restore. The nightly archive and the
-- forfeiture job wait for it (waitIdle) so they never meet a change half done.

function Kit.busy()
    if not busy then return nil end
    return busy.kind, busy.info, busy.since
end

function Kit.lock(kind, info)
    if busy then return false, 'err.admin_busy', busy.kind end
    busy = { kind = tostring(kind), info = info, since = os.time() }
    return true
end

function Kit.unlock(kind)
    if busy and (kind == nil or busy.kind == tostring(kind)) then busy = nil end
end

-- Waits until nothing holds the lock (up to timeoutMs, 0 = do not wait): true when free.
function Kit.waitIdle(timeoutMs)
    local waited = 0
    while busy and waited < (timeoutMs or 0) do
        Wait(250)
        waited = waited + 250
    end
    return busy == nil
end

-- fn() with the lock held; the lock is always released.
function Kit.withLock(kind, fn, info)
    local ok, err = Kit.lock(kind, info)
    if not ok then return false, err end
    local res = table.pack(pcall(fn))
    Kit.unlock(kind)
    if not res[1] then
        CP.err(TAG, '%s failed: %s', tostring(kind), tostring(res[2]))
        return false, 'err.internal'
    end
    return table.unpack(res, 2, res.n)
end

-- ============================================================================
--                                 J: BULK JOBS
-- ============================================================================
-- A job changes a fixed list of row ids in batches of 50 with a Wait(0) between them. Its state is saved in
-- cp_admin_jobs after every batch, so a job a crash interrupted is finished (or rolled back) at the next start.
-- handlers = { batch = fn(job, ids) -> ok, err; finish = fn(job); rollback = fn(job); label = locale key }.

function Kit.registerJob(kind, handlers)
    if type(kind) ~= 'string' or kind == '' or #kind > 24 or type(handlers) ~= 'table' then return false end
    if type(handlers.batch) ~= 'function' then return false end
    jobKinds[kind] = handlers
    return true
end

local function JobRow(id)
    local ok, row = pcall(MySQL.single.await, [[SELECT id, kind, state, filter, detail, done, total, actor, reason,
        UNIX_TIMESTAMP(created_at) AS created_ts, UNIX_TIMESTAMP(updated_at) AS updated_ts FROM cp_admin_jobs
        WHERE id = ?]], { id })
    if not ok or type(row) ~= 'table' then return nil end
    return {
        id = row.id,
        kind = row.kind,
        state = row.state,
        filter = Decode(row.filter) or {},
        detail = Decode(row.detail) or {},
        done = math.floor(U.num(row.done)),
        total = math.floor(U.num(row.total)),
        actor = row.actor,
        reason = row.reason,
        createdAt = math.floor(U.num(row.created_ts)),
        updatedAt = math.floor(U.num(row.updated_ts)),
    }
end

function Kit.job(id)
    if type(id) ~= 'string' or #id > 36 then return nil end
    Db()
    return JobRow(id)
end

-- The latest jobs, newest first. opts: { kind, limit (≤ 50) }.
function Kit.jobs(opts)
    opts = opts or {}
    Db()
    local limit = math.min(50, math.max(1, math.tointeger(tonumber(opts.limit) or 20) or 20))
    local sql = 'SELECT id FROM cp_admin_jobs'
    local params = {}
    if type(opts.kind) == 'string' then
        sql = sql .. ' WHERE kind = ?'
        params[1] = opts.kind
    end
    sql = ('%s ORDER BY created_at DESC, id DESC LIMIT %d'):format(sql, limit)
    local ok, rows = pcall(MySQL.query.await, sql, params)
    local out = {}
    if ok and type(rows) == 'table' then
        for _, r in ipairs(rows) do out[#out + 1] = JobRow(r.id) end
    end
    return out
end

local function Progress(job, state)
    local data = {
        id = job.id,
        kind = job.kind,
        state = state or job.state,
        done = job.done,
        total = job.total,
    }
    if Has('Tablet', 'pushAdmins') then Call('Tablet', 'pushAdmins', 'adminjob', data) end
    CP.Hooks.fire('adminjob:progress', data)
end

local function SetJobState(job, state)
    job.state = state
    pcall(MySQL.update.await, 'UPDATE cp_admin_jobs SET state = ?, done = ?, updated_at = NOW() WHERE id = ?',
        { state, job.done, job.id })
    Progress(job, state)
end

-- Works through the ids from job.done on. Runs in the caller's thread.
local function RunJob(job, handlers)
    local ids = type(job.detail.ids) == 'table' and job.detail.ids or {}
    job.total = #ids
    local i = job.done + 1
    while i <= #ids do
        local slice = {}
        for k = i, math.min(#ids, i + JOB_BATCH - 1) do slice[#slice + 1] = ids[k] end
        local ok, okB, errB = pcall(handlers.batch, job, slice)
        if not ok or okB == false then
            CP.err(TAG, 'job %s (%s) stopped at row %d: %s', job.id, job.kind, i, tostring(ok and errB or okB))
            SetJobState(job, 'failed')
            return false, 'err.job_failed'
        end
        job.done = i + #slice - 1
        pcall(MySQL.update.await, 'UPDATE cp_admin_jobs SET done = ?, updated_at = NOW() WHERE id = ?',
            { job.done, job.id })
        Progress(job, 'running')
        i = job.done + 1
        if i <= #ids then Wait(0) end
    end
    if type(handlers.finish) == 'function' then
        local ok, err = pcall(handlers.finish, job)
        if not ok then CP.err(TAG, 'job %s (%s) finish failed: %s', job.id, job.kind, tostring(err)) end
    end
    SetJobState(job, 'done')
    return true, job.id
end

-- Starts a job: ok, jobId | false, errKey. spec = { kind, src, reason, ids, filter, detail, wait = true }.
-- With wait the caller's thread runs it to the end; otherwise it runs in its own thread.
function Kit.startJob(spec)
    if type(spec) ~= 'table' then return false, 'err.invalid_payload' end
    local handlers = jobKinds[spec.kind]
    if not handlers then return false, 'err.job_kind' end
    local ids = type(spec.ids) == 'table' and spec.ids or {}
    local okL, errL = Kit.lock('job', { kind = spec.kind })
    if not okL then return false, errL end
    Db()
    local id = spec.id or U.uuid()
    local detail = type(spec.detail) == 'table' and U.deepcopy(spec.detail) or {}
    detail.ids = ids
    local ok, err = pcall(MySQL.insert.await, [[INSERT INTO cp_admin_jobs (id, kind, state, filter, detail, done,
        total, actor, reason, created_at, updated_at) VALUES (?, ?, 'running', ?, ?, 0, ?, ?, ?, NOW(), NOW())]], {
        id,
        spec.kind,
        Encode(spec.filter or {}),
        Encode(detail),
        #ids,
        ActorId(spec.src),
        spec.reason and tostring(spec.reason):sub(1, REASON_MAX) or nil,
    })
    if not ok then
        Kit.unlock('job')
        CP.err(TAG, 'job %s could not be saved: %s', tostring(spec.kind), tostring(err))
        return false, 'err.internal'
    end
    local job = {
        id = id,
        kind = spec.kind,
        state = 'running',
        filter = spec.filter or {},
        detail = detail,
        done = 0,
        total = #ids,
        actor = ActorId(spec.src),
        reason = spec.reason,
        src = ToSrc(spec.src),
    }
    Progress(job, 'running')
    if spec.wait then
        local okR, res, e = pcall(RunJob, job, handlers)
        Kit.unlock('job')
        if not okR then return false, 'err.internal' end
        return res, e
    end
    CreateThread(function()
        local okR, errR = pcall(RunJob, job, handlers)
        if not okR then CP.err(TAG, 'job %s crashed: %s', id, tostring(errR)) end
        Kit.unlock('job')
    end)
    return true, id
end

-- At start: a job a crash interrupted is finished when its kind can go on, else rolled back, else marked failed.
function Kit._resumeJobs()
    -- a job of this run holds the lock: nothing was interrupted
    if busy then return 0 end
    Db()
    local ok, rows = pcall(MySQL.query.await,
        'SELECT id FROM cp_admin_jobs WHERE state = \'running\' ORDER BY created_at')
    if not ok or type(rows) ~= 'table' then return 0 end
    local n = 0
    for _, r in ipairs(rows) do
        local job = JobRow(r.id)
        local handlers = job and jobKinds[job.kind]
        if busy then break end
        if job and handlers and type(job.detail.ids) == 'table' and Kit.lock('job', { kind = job.kind }) then
            n = n + 1
            job.resumed = true
            CP.warn(TAG, 'finishing the %s job %s a restart interrupted (%d of %d rows done)', job.kind, job.id,
                job.done, job.total)
            local okR = pcall(RunJob, job, handlers)
            Kit.unlock('job')
            if not okR then CP.err(TAG, 'job %s could not be finished', job.id) end
            if Has('Tablet', 'notifyAdmins') then
                Call('Tablet', 'notifyAdmins', 'warning', 'adminkit.job_resumed', {})
            end
        elseif job then
            if handlers and type(handlers.rollback) == 'function' then
                pcall(handlers.rollback, job)
                SetJobState(job, 'rolledback')
            else
                SetJobState(job, 'failed')
            end
            CP.warn(TAG, 'the %s job %s a restart interrupted could not go on and was stopped', job.kind, job.id)
            if Has('Tablet', 'notifyAdmins') then
                Call('Tablet', 'notifyAdmins', 'warning', 'adminkit.job_stopped', {})
            end
        end
    end
    return n
end

-- ============================================================================
--                              THE ACTION WRAPPER
-- ============================================================================
-- Kit.action(name, permKey, fn, opts) registers CP.Net.action(name). The guards run in this order: M (maintenance),
-- P (permission: admins and the console only), L (opts.rate, opts.targetRate), I (opts.requestId), R (opts.reason),
-- T (opts.confirm), S (opts.self), then fn(ctx), then A (opts.audit when fn wrote none), C and N through ctx.
-- V and K are helpers fn calls (ctx.consume, Kit.cas) because only the action knows its ids and its old state.
--   opts.rate          calls per second per player (CP.Net.action)
--   opts.targetRate    { n, windowMs, field = 'citizenid' }: n per window per target across every admin
--   opts.requestId     true: payload.requestId (UUID v4) acts once; a repeat gets the first result
--   opts.reason        true (required) | 'optional'
--   opts.confirm       a word, or fn(payload, ctx) -> word|nil: payload.confirm must match it
--   opts.self          fn(payload, ctx) -> { citizenid?, runUuid?, strict? }: the admin's own records are refused
--   opts.audit         an audit action written after success when fn wrote none; opts.category its webhook
--   opts.maintenance   true: allowed during a maintenance lock (status reads, ending the lock)
-- fn(ctx) -> ok, data | false, errKey. ctx = { src, payload, name, reason, requestId, actor, role, target, old, new,
-- audit(action, target, old, new, aopts), consume(token, kind, ids), changed(kind, citizenid, missionId),
-- notify(citizenid, kind, key, vars) }.

local function Refuse(ctx, err)
    if ctx.claimed then Kit.releaseRequest(ctx.requestId) end
    return false, err
end

local function Guard(entry, src, payload)
    local name, permKey, opts = entry.name, entry.permKey, entry.opts
    local p = type(payload) == 'table' and payload or {}
    local n = ToSrc(src)
    if not n then return false, 'err.no_permission' end
    local ctx = { src = n, payload = p, name = name, actor = ActorId(n), role = n == 0 and 'console' or 'admin' }
    -- M
    if not opts.maintenance and Maint.active() then return false, 'err.maintenance' end
    -- P: an admin key (supervisors never pass) and the admin rule itself
    if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(n)) then return false, 'err.no_permission' end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local okP, errP = CP.Permissions.can(n, permKey)
    if not okP then return false, errP or 'err.no_permission' end
    -- L (per target)
    local tr = opts.targetRate
    if type(tr) == 'table' then
        local field = tr.field or 'citizenid'
        local target = p[field]
        if target ~= nil and not Kit.targetOk(name, target, tr[1] or tr.n or 1, tr[2] or tr.windowMs or 10000) then
            return false, 'err.rate_limited'
        end
    end
    -- I
    if opts.requestId then
        local state, stored = Kit.claimRequest(p.requestId, name, n)
        if not state then return false, stored end
        if state == 'busy' then return false, 'err.request_busy' end
        if state == 'done' then return 'stored', stored end
        ctx.requestId = p.requestId:lower()
        ctx.claimed = true
    end
    -- R
    if opts.reason then
        local reason, errR = Kit.reason(p.reason, opts.reason == 'optional')
        if errR then return Refuse(ctx, errR) end
        ctx.reason = reason
    end
    -- T
    if opts.confirm ~= nil then
        local word = opts.confirm
        if type(word) == 'function' then
            local okW, w = pcall(word, p, ctx)
            if not okW then return Refuse(ctx, 'err.internal') end
            word = w
        end
        if word ~= nil and not Kit.confirmOk(p.confirm, tostring(word)) then
            return Refuse(ctx, 'err.confirm_mismatch')
        end
        ctx.confirmWord = word
    end
    -- S
    if type(opts.self) == 'function' and n ~= 0 then
        local okS, who = pcall(opts.self, p, ctx)
        if not okS then return Refuse(ctx, 'err.internal') end
        if type(who) == 'table' then
            if who.citizenid ~= nil then
                local self, errS, unknown = Kit.isSelf(n, who.citizenid, who.strict)
                if self == nil then return Refuse(ctx, errS) end
                if self then return Refuse(ctx, 'err.self_target') end
                if unknown then ctx.licenceUnknown = true end
            end
            if who.runUuid ~= nil and Kit.selfRun(n, who.runUuid) then return Refuse(ctx, 'err.own_run') end
        end
    end
    return true, ctx
end

local function MakeCtx(ctx, entry)
    ctx.audit = function(action, target, old, new, aopts)
        aopts = type(aopts) == 'table' and aopts or {}
        local reason = aopts.reason or ctx.reason
        if ctx.licenceUnknown and reason then reason = ('%s (%s)'):format(reason, CP.L('adminkit.licence_unknown')) end
        local id = Kit.auditSync(ctx.src, aopts.category or entry.opts.category or 'audit', action, target, old, new,
            reason, aopts)
        if id then ctx.audited = true end
        return id
    end
    ctx.consume = function(token, kind, ids) return Kit.consume(ctx.src, token, kind, ids) end
    ctx.changed = Kit.changed
    ctx.notify = Kit.notify
    return ctx
end

local function Run(entry, src, payload)
    local okG, ctx = Guard(entry, src, payload)
    if okG == 'stored' then
        if ctx.ok then return true, ctx.data end
        return false, ctx.data or 'err.refused'
    end
    if not okG then return false, ctx end
    MakeCtx(ctx, entry)
    local res = table.pack(pcall(entry.fn, ctx))
    local ok, data
    if not res[1] then
        CP.err(TAG, '%s failed: %s', entry.name, tostring(res[2]))
        ok, data = false, 'err.internal'
    else
        ok, data = res[2] == true, res[3]
        if not ok and data == nil then data = 'err.refused' end
    end
    if ok and entry.opts.audit and not ctx.audited then
        ctx.audit(entry.opts.audit, ctx.target, ctx.old, ctx.new)
    end
    if ctx.claimed then Kit.finishRequest(ctx.requestId, ok, data) end
    return ok, data
end

function Kit.action(name, permKey, fn, opts)
    if type(name) ~= 'string' or type(permKey) ~= 'string' or type(fn) ~= 'function' then
        CP.err(TAG, 'AdminKit.action(%s) needs a name, a permission key and a function', tostring(name))
        return false
    end
    opts = type(opts) == 'table' and opts or {}
    local entry = { name = name, permKey = permKey, fn = fn, opts = opts }
    actions[name] = entry
    CP.Net.action(name, function(src, payload)
        return Run(entry, src, payload)
    end, { rate = opts.rate or 2, maintenance = opts.maintenance })
    return true
end

-- A registered action called directly (the console, another module, tests): the same guards.
function Kit.run(name, src, payload)
    local entry = actions[name]
    if not entry then return false, 'err.unknown_action' end
    return Run(entry, src, payload)
end

-- A read callback for admins only (permKey checked like an action; reads keep working during maintenance).
-- fn(ctx) -> data | nil, errKey.
function Kit.callback(name, permKey, fn, opts)
    opts = type(opts) == 'table' and opts or {}
    CP.Net.callback(name, function(src, args)
        local n = ToSrc(src)
        if not n or not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(n)) then
            return nil, 'err.no_permission'
        end
        local okP, errP = CP.Permissions.can(n, permKey)
        if not okP then return nil, errP or 'err.no_permission' end
        local ctx = { src = n, args = type(args) == 'table' and args or {}, name = name, actor = ActorId(n) }
        ctx.preview = function(kind, ids, effect) return Kit.preview(n, kind, ids, effect) end
        return fn(ctx)
    end, { rate = opts.rate or 3 })
end

function Kit._actions() return actions end

-- ============================================================================
--                                CP.MAINTENANCE
-- ============================================================================
-- While a lock is held the net gate (shared/net.lua) refuses every action but the few marked maintenance = true,
-- runs, claims, tests and operations refuse at their own checks, and payments and scheduled jobs wait.
-- storage and restore end with a restart by the owner; left_behind stays until this store is used again.

local function MaintView()
    if not maintenance then return nil end
    return {
        kind = maintenance.kind,
        since = maintenance.since,
        restart = maintenance.info and maintenance.info.restart == true or nil,
        by = maintenance.info and maintenance.info.by or nil,
    }
end

local function MaintPush()
    TriggerClientEvent(CP.e('client:push'), -1, 'maintenance', MaintView() or false)
    CP.Hooks.fire('maintenance:changed', MaintView())
end

-- ok | false, errKey. info = { by = actor, restart = bool, ... } (shown to admins).
function Maint.begin(kind, info)
    if not MAINT_KINDS[kind] then return false, 'err.invalid_payload' end
    if maintenance and maintenance.kind ~= kind then return false, 'err.maintenance' end
    maintenance = { kind = kind, info = type(info) == 'table' and info or {}, since = os.time() }
    CP.warn(TAG, 'maintenance lock on (%s): new runs, claims, tests, operations and payments wait', kind)
    MaintPush()
    return true
end

function Maint.finish(kind)
    if not maintenance then return true end
    if kind ~= nil and maintenance.kind ~= kind then return false, 'err.maintenance' end
    CP.warn(TAG, 'maintenance lock off (%s)', maintenance.kind)
    maintenance = nil
    MaintPush()
    return true
end

-- kind, info | nil
function Maint.active()
    if not maintenance then return nil end
    return maintenance.kind, maintenance.info
end

function Maint.view() return MaintView() end

-- The work is done and only a restart by the owner ends the lock: the Admin UI and one console line say so.
-- Crimson-Police never restarts itself.
function Maint.askRestart(kind)
    if not maintenance or (kind ~= nil and maintenance.kind ~= kind) then return false end
    maintenance.info.restart = true
    CP.warn(TAG, '%s', CP.L('adminkit.restart_now', { resource = CP.resource }))
    MaintPush()
    return true
end

-- ============================================================================
--                                    START
-- ============================================================================

CreateThread(function()
    Wait(JOB_RESUME_DELAY_MS)
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, err = pcall(Kit._resumeJobs)
    if not ok then CP.err(TAG, 'resuming admin jobs failed: %s', tostring(err)) end
end)

-- Test hooks (not part of the contract).
Kit._reset = function()
    previews, previewOrder, busy, maintenance = {}, {}, nil, nil
end
Kit._jobKinds = function() return jobKinds end
