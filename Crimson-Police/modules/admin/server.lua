--[[ modules/admin/server.lua · CP.Admin (server): supervisor and admin actions, /CrimsonPoliceAdmin, the
  audit log (cp_audit) and the Discord webhooks.

  Owns
    * the /CrimsonPoliceAdmin command (Config.Tablet.adminCommand, registered at runtime) with every
      subcommand of the spec, usable from the server console (src 0) and in game (ace Config.AdminAce):
        (no args)                                        open the Admin UI (in game)
        help                                             list the subcommands
        payout type <type> <amount|clear> <reason...>    CP.Payouts.setType
        payout mission <missionId> <amount|clear> <reason...>  CP.Payouts.setMission
        award <citizenid> <points> <reason...>           CP.Scoring.manualAward
        season start <name...> | season end              CP.Challenge.startSeason / endSeason
        suspend <citizenid> <days> [reason...]           CP.Access.suspend (0 days lifts it), audited here
        reload                                           CP.Missions.reload, audited here
        test <missionId> [tier] [location|random]        CP.Testing.start (in game only)
      Replies: print() on the console, CP.Tablet.notify in game.
    * cp_audit rows (values clipped to the column sizes) and the category webhooks read at call time
      from the convars cp_webhook_audit / cp_webhook_flags / cp_webhook_builder / cp_webhook_operations /
      cp_webhook_board (missing or empty = off; only https:// urls), posted with PerformHttpRequest as
      Discord embeds through a rate-limited queue (one post per url every 2.1 s, 429 retry_after honoured,
      5xx/network errors retried, at most 100 queued).
    * flagged-run review (approve / void), voiding any run, force recall, manual award and suspension
      actions, and the supervisor/admin read callbacks listed below.

  Public API (docs/ARCHITECTURE.md §5.25)
    CP.Admin.audit(actor, role, category, action, target, old, new, reason) -> auditId|nil
        actor: src (number; 0 = console), citizenid (string) or 'console'. role: 'supervisor'|'admin'|
        'console'; anything else (e.g. 'officer', 'system') is stored as 'console' = an automatic entry
        (the cp_audit enum has no other value). category: 'audit'|'flags'|'builder'|'operations'; 'board'
        is stored as 'audit' and posted to the board webhook. action <= 40 chars, target/old/new <= 64,
        reason <= 255 (clipped). Posts the category webhook. Called outside a coroutine it writes from a
        new thread and returns nil.
    CP.Admin.webhook(category, title, description, fields) -> queued (boolean)
        category: audit|flags|builder|operations|board. fields: { { name, value, inline }, ... } (or
        { name, value } pairs); texts are already translated. false when that webhook is off.
    CP.Admin.approveFlagged(src, rowId, reason, opts) -> ok, data|errKey
    CP.Admin.voidFlagged(src, rowId, reason) -> ok, data|errKey
    CP.Admin.voidRun(src, rowIdOrRunUuid, reason) -> ok, data|errKey      (permission voidAnyRun)
        approve: flagged = 0 (flag_reason kept), CP.Cash.release when cash is held,
        CP.Scoring.onRowApproved, CP.Leaderboard.invalidate. void: voided = 1, CP.Scoring.onRowVoided,
        cash untouched (held cash is forfeited by CP.Cash after the dispute window; a paid run is not
        clawed back), CP.AntiCheat.onVoided for mission rows, invalidate. Reason required. Reviewers who
        took part are refused (CP.Permissions.canReviewRun, err.own_run); supervisors only for runs
        involving their department (err.other_department).
        opts (approveFlagged, used by CP.Disputes): { skipPermission = true, noAudit = true, quiet = true (no toast) }
    CP.Admin.forceRecall(src, runId, targetSrc, reason) -> ok, data|errKey
    CP.Admin.getRow(rowId) -> row|nil, errKey        one cp_mission_runs row (flagged/voided as booleans)
    CP.Admin.runDepartments(runUuid) -> { deptKey, ... }   departments of every row (and live participant)
    CP.Admin.resolveCitizenId(input) -> citizenid|nil  the stored form (cp_officers, else an online player)
    CP.Admin.missionLabel(missionId) -> text
    CP.Admin.command(src, args) -> the /CrimsonPoliceAdmin handler (also used by tests)

  Net (docs/ARCHITECTURE.md §8.3)
    actions
      server:sup:forceRecall     { runId, src, reason? }                forceRecall (runs involving their dept)
      server:sup:reviewFlagged   { rowId, decision = 'approve'|'void', reason }   reviewFlagged
      server:admin:reviewFlagged { rowId, decision, reason }            admin
      server:admin:voidRun       { rowId } | { runUuid }, reason         voidAnyRun
      server:admin:awardPoints   { citizenid, points, reason }           manualAward -> CP.Scoring.manualAward
      server:admin:suspend       { citizenid, days, reason }             suspend -> CP.Access.suspend (audited)
    callbacks (shapes in docs/notes/oversight.md and web/src/types/oversight.ts)
      getMissionList             viewMissionList -> MissionListData
      sup:getLiveRuns            viewMissionList -> { runs = { LiveRun + extras }, serverTime, canRecall }
      sup:getReviewQueue         reviewFlagged|handleDisputes -> { flagged, disputes, canReview, canHandle }
      admin:getFlagged           admin -> { flagged }
      admin:searchOfficers       { query } -> { officers }
      admin:getOfficer           { citizenid } -> OfficerDetail
      admin:getDepartments       -> { departments, cashSource, showSociety }
      admin:getPermissions       -> { supervisor = { { action, enabled } }, adminOnly, always }
      admin:getAudit             { category, action, actor, from, to, page } -> AuditPage
      admin:exportAudit          same filters -> { csv, rows, truncated }
]]

CP.Admin = CP.Admin or {}
local Admin = CP.Admin
local U = CP.U
local TAG = 'admin'

local MAX_AWARD = 10000            -- points per manual award (typo guard; the column holds 32767)
local MAX_REASON = 255
local AUDIT_PAGE = 50
local EXPORT_MAX = 5000
local FLAGGED_LIMIT = 200
local SEARCH_LIMIT = 25
local RECENT_RUNS = 25
local WEBHOOK_GAP_MS = 2100        -- Discord: at most 30 posts a minute per webhook
local WEBHOOK_QUEUE_MAX = 100
local WEBHOOK_RETRIES = 3
local NON_MISSION_TYPES = { manual_award = true, goal = true }

local ROLES = { supervisor = true, admin = true, console = true }
local CATEGORIES = { audit = true, flags = true, builder = true, operations = true }
local WEBHOOK_CONVARS = {
    audit = 'cp_webhook_audit', flags = 'cp_webhook_flags', builder = 'cp_webhook_builder',
    operations = 'cp_webhook_operations', board = 'cp_webhook_board',
}
local WEBHOOK_COLOURS = { audit = 0xA4161A, flags = 0xF59E0B, builder = 0x3B82F6, operations = 0x8B5CF6, board = 0xF2C230 }
-- ARCHITECTURE §5.3: always admin-only, whatever Config.Permissions says.
local ADMIN_ONLY = {
    'setMissionPayout', 'clearPayout', 'manualAward', 'handleFailedDispute', 'voidAnyRun', 'seasons',
    'bountyOverride', 'suspend', 'reloadMissions', 'testRun', 'openAdmin',
}
local SUPERVISOR_ALWAYS = { 'viewMissionList' }
-- Config.Permissions.supervisor in the spec's order (the Permissions screen lists them this way).
local SUPERVISOR_ORDER = {
    'setTypePayout', 'launchCrossDept', 'forceRecall', 'reviewFlagged', 'handleDisputes', 'builderEdit',
    'builderPublish', 'builderArchive', 'builderEditAny', 'builderRollback', 'breakEditLock',
}

local warned = {}

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

-- pcall CP.<mod>.<fn>(...): true + results, or false when missing/failed.
local function call(modName, fnName, ...)
    if not has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

-- A whole number in [lo, hi], or nil.
local function int(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function cleanText(v, max)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v:gsub('[%c]', ' '))
    if s == '' then return nil end
    return U.clip(s, max or MAX_REASON)
end

local function str(v, n)
    if v == nil then return nil end
    if type(v) == 'table' then
        local ok, s = pcall(json.encode, U.serialize(v))
        v = ok and s or tostring(v)
    end
    return U.clip(tostring(v), n)
end

local function validUuid(v)
    return type(v) == 'string' and #v > 0 and #v <= 36 and v:match('^[%w%-]+$') ~= nil
end

local function query(sql, params)
    db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function single(sql, params)
    db()
    local ok, res = pcall(MySQL.single.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil, false
    end
    return type(res) == 'table' and res or nil, true
end

local function update(sql, params)
    db()
    local ok, res = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(res))
        return nil
    end
    return tonumber(res) or 0
end

local function likeArg(s)
    s = s:gsub('\\', '\\\\'):gsub('%%', '\\%%'):gsub('_', '\\_')
    return '%' .. s .. '%'
end

local function roleOf(src)
    local n = tonumber(src)
    if n == 0 then return 'console' end
    if CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(n) then return 'admin' end
    return 'supervisor'
end

local function can(src, action, ctx)
    if not has('Permissions', 'can') then return false, 'err.no_permission' end
    local ok, allowed, errKey = call('Permissions', 'can', src, action, ctx)
    if not ok then return false, 'err.internal' end
    if not allowed then return false, errKey or 'err.no_permission' end
    return true
end

local function isAdmin(src)
    return CP.Access ~= nil and CP.Access.isAdmin ~= nil and CP.Access.isAdmin(src) == true
end

local function notify(src, kind, key, vars)
    if toSrc(src) and has('Tablet', 'notify') then call('Tablet', 'notify', src, kind, key, vars) end
end

local function onlineSrc(citizenid)
    if type(citizenid) ~= 'string' or not has('Qbx', 'getByCitizenId') then return nil end
    local ok, s = call('Qbx', 'getByCitizenId', citizenid)
    return ok and toSrc(s) or nil
end

-- The character citizenid of a player src (nil for the console or a player without a character).
local function citizenOf(src)
    local n = toSrc(src)
    if not n then return nil end
    local ok, info = call('Qbx', 'getInfo', n)
    if ok and type(info) == 'table' and type(info.citizenid) == 'string' and info.citizenid ~= '' then return info.citizenid end
    return nil
end

-- Whether citizenid is (or was) a participant of the still-running run runUuid. Their own row is only
-- written when they leave, so the cp_mission_runs check alone misses a reviewer who is still on the run.
local function inLiveRun(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' or type(runUuid) ~= 'string' or not has('Runs', 'get') then return false end
    local ok, run = call('Runs', 'get', runUuid)
    if not ok or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    for _, p in pairs(run.participants) do
        if type(p) == 'table' and p.citizenid == citizenid then return true end
    end
    return false
end

-- A mission definition by id (ids are lower case; a typed 'Gang_Shootout' still finds it).
local function findMission(id)
    if type(id) ~= 'string' or id == '' or #id > 64 or not has('Missions', 'get') then return nil end
    local ok, def = call('Missions', 'get', id)
    if ok and type(def) == 'table' then return def end
    local low = id:lower()
    if low ~= id then
        ok, def = call('Missions', 'get', low)
        if ok and type(def) == 'table' then return def end
    end
    return nil
end

local function deptShort(key)
    if type(key) ~= 'string' then return '' end
    local d = CP.Access and CP.Access.department and CP.Access.department(key)
    return d and d.short or key:upper()
end

local function typeLabel(t)
    local mt = Config.MissionTypes and Config.MissionTypes[t]
    return mt and mt.label or tostring(t or '')
end

function Admin.missionLabel(missionId)
    if missionId == 'manual_award' then return CP.L('admin.mission.manual_award') end
    if missionId == 'goal' then return CP.L('admin.mission.goal') end
    local def = has('Missions', 'get') and CP.Missions.get(missionId) or nil
    if type(def) == 'table' and def.label then return def.label end
    return tostring(missionId or '')
end

local function actionLabel(action)
    local key = 'admin.action.' .. tostring(action)
    if CP.Locale and CP.Locale.has and CP.Locale.has(key) then return CP.L(key) end
    return tostring(action)
end

local function flagLabel(reason)
    local key = 'flag.' .. tostring(reason)
    if CP.Locale and CP.Locale.has and CP.Locale.has(key) then return CP.L(key) end
    return tostring(reason)
end
Admin.flagLabel = flagLabel

-- ── webhooks ────────────────────────────────────────────────────────────────
local queue = {}
local working = false
local lastSent, blockedUntil = {}, {}

local function webhookUrl(category)
    local convar = WEBHOOK_CONVARS[category]
    if not convar or not GetConvar then return nil end
    local url = GetConvar(convar, '')
    if type(url) ~= 'string' then return nil end
    url = U.trim(url)
    if url == '' then return nil end
    if url:sub(1, 8):lower() ~= 'https://' or url:find('[%s"\'<>]') then
        warnOnce('url.' .. category, 'convar %s must be an https:// webhook url; that webhook is off', convar)
        return nil
    end
    return url
end

local function clipText(s, n)
    s = tostring(s or '')
    if #s > n then s = s:sub(1, n - 1) .. '…' end
    return s
end

local function sendJob(job)
    PerformHttpRequest(job.url, function(status, body)
        status = tonumber(status) or 0
        if status >= 200 and status < 300 then return end
        if status == 429 then
            local wait = 2.0
            local ok, data = pcall(json.decode, body or '')
            if ok and type(data) == 'table' and tonumber(data.retry_after) then wait = tonumber(data.retry_after) end
            if wait > 1000 then wait = wait / 1000 end   -- very old API versions answered in ms
            blockedUntil[job.url] = GetGameTimer() + math.ceil(wait * 1000) + 100
        elseif status ~= 0 and status < 500 then
            warnOnce('status.' .. job.category .. status, 'webhook %s answered %d: check its convar', job.category, status)
            return
        else
            blockedUntil[job.url] = GetGameTimer() + 5000
        end
        job.tries = job.tries + 1
        if job.tries <= WEBHOOK_RETRIES then
            table.insert(queue, 1, job)
            Admin._pumpWebhooks()
        else
            CP.warn(TAG, 'webhook %s dropped after %d tries (last status %d)', job.category, job.tries, status)
        end
    end, 'POST', job.body, { ['Content-Type'] = 'application/json' })
end

function Admin._pumpWebhooks()
    if working then return end
    working = true
    CreateThread(function()
        while #queue > 0 do
            local now = GetGameTimer()
            local sent = false
            for i = 1, #queue do
                local job = queue[i]
                local freeAt = math.max(blockedUntil[job.url] or 0, (lastSent[job.url] or -WEBHOOK_GAP_MS) + WEBHOOK_GAP_MS)
                if now >= freeAt then
                    table.remove(queue, i)
                    lastSent[job.url] = now
                    local ok, err = pcall(sendJob, job)
                    if not ok then CP.err(TAG, 'webhook post failed: %s', tostring(err)) end
                    sent = true
                    break
                end
            end
            Wait(sent and 50 or 250)
        end
        working = false
    end)
end

function Admin._webhookQueue() return queue end

function Admin.webhook(category, title, description, fields)
    local url = webhookUrl(category)
    if not url then return false end
    local embed = {
        title = clipText(title, 256),
        description = clipText(description, 3500),
        color = WEBHOOK_COLOURS[category],
        timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ'),
        footer = { text = clipText(('%s · %s'):format(Config.Tablet and Config.Tablet.title or 'Crimson-Police', category), 256) },
    }
    local list = {}
    if type(fields) == 'table' then
        for _, f in ipairs(fields) do
            if #list >= 20 then break end
            local name = type(f) == 'table' and (f.name or f[1]) or nil
            local value = type(f) == 'table' and (f.value or f[2]) or nil
            if name ~= nil and value ~= nil and tostring(value) ~= '' then
                list[#list + 1] = { name = clipText(name, 256), value = clipText(value, 1000), inline = type(f) == 'table' and f.inline == true }
            end
        end
    end
    if #list > 0 then embed.fields = list end
    local ok, body = pcall(json.encode, { username = Config.Tablet and Config.Tablet.title or 'Crimson-Police', embeds = { embed } })
    if not ok then
        CP.err(TAG, 'webhook payload could not be encoded: %s', tostring(body))
        return false
    end
    if #queue >= WEBHOOK_QUEUE_MAX then
        table.remove(queue, 1)
        warnOnce('queue_full', 'the webhook queue is full; the oldest posts are dropped')
    end
    queue[#queue + 1] = { url = url, body = body, tries = 0, category = category }
    Admin._pumpWebhooks()
    return true
end

-- ── audit ───────────────────────────────────────────────────────────────────
-- actor -> id stored in cp_audit, display name, src (0 = console) or nil.
local function resolveActor(actor)
    if actor == nil or actor == 0 or actor == '0' or actor == 'console' then return 'console', CP.L('admin.actor.console'), 0 end
    if type(actor) == 'number' then
        local n = toSrc(actor)
        if not n then return 'console', CP.L('admin.actor.console'), 0 end
        local ok, info = call('Qbx', 'getInfo', n)
        if ok and type(info) == 'table' and type(info.citizenid) == 'string' then
            return U.clip(info.citizenid, 50), info.name, n
        end
        return U.clip(('player:%d'):format(n), 50), GetPlayerName and GetPlayerName(n) or nil, n
    end
    local s = U.trim(tostring(actor))
    if s == '' then return 'console', CP.L('admin.actor.console'), 0 end
    return U.clip(s, 50), nil, nil
end

local function resolveRole(role, actorId, src)
    if ROLES[role] then return role end
    if actorId == 'console' then return 'console' end
    if src and src > 0 and CP.Access then
        if CP.Access.isAdmin and CP.Access.isAdmin(src) then return 'admin' end
        if CP.Access.isSupervisor and CP.Access.isSupervisor(src) then return 'supervisor' end
    end
    return 'console'
end

local AUDIT_COLS = { 'actor', 'role', 'category', 'action', 'target', 'old_value', 'new_value', 'reason' }

local function writeAudit(entry, hookCategory, actorName)
    local values, params = {}, {}
    for i, col in ipairs(AUDIT_COLS) do
        local v = entry[col]
        if v == nil then
            values[i] = 'NULL'
        else
            values[i] = '?'
            params[#params + 1] = v
        end
    end
    db()
    local sql = ('INSERT INTO cp_audit (%s) VALUES (%s)'):format(table.concat(AUDIT_COLS, ', '), table.concat(values, ', '))
    local ok, id = pcall(MySQL.insert.await, sql, params)
    if not ok then
        CP.err(TAG, 'audit insert failed (%s): %s', entry.action, tostring(id))
        id = nil
    end
    local who = actorName and actorName ~= '' and ('%s (%s)'):format(actorName, entry.actor) or entry.actor
    local fields = {
        { name = CP.L('admin.webhook.field.actor'), value = who, inline = true },
        { name = CP.L('admin.webhook.field.role'), value = CP.L('admin.role.' .. entry.role), inline = true },
    }
    if entry.target then fields[#fields + 1] = { name = CP.L('admin.webhook.field.target'), value = entry.target, inline = true } end
    if entry.old_value or entry.new_value then
        fields[#fields + 1] = { name = CP.L('admin.webhook.field.change'),
            value = ('%s → %s'):format(entry.old_value or '—', entry.new_value or '—'), inline = false }
    end
    if entry.reason then fields[#fields + 1] = { name = CP.L('admin.webhook.field.reason'), value = entry.reason, inline = false } end
    Admin.webhook(hookCategory, actionLabel(entry.action), CP.L('admin.webhook.audit_desc', { category = hookCategory }), fields)
    return tonumber(id)
end

function Admin.audit(actor, role, category, action, target, old, new, reason)
    if type(action) ~= 'string' or action == '' then
        CP.warn(TAG, 'audit called without an action (ignored)')
        return nil
    end
    local actorId, actorName, src = resolveActor(actor)
    local entry = {
        actor = actorId,
        role = resolveRole(role, actorId, src),
        category = CATEGORIES[category] and category or 'audit',
        action = U.clip(action, 40),
        target = str(target, 64),
        old_value = str(old, 64),
        new_value = str(new, 64),
        reason = str(reason, MAX_REASON),
    }
    local hookCategory = WEBHOOK_CONVARS[category] and category or entry.category
    if not coroutine.isyieldable() then
        CreateThread(function() writeAudit(entry, hookCategory, actorName) end)
        return nil
    end
    return writeAudit(entry, hookCategory, actorName)
end

-- ── rows ────────────────────────────────────────────────────────────────────
local ROW_SQL = [[SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, end_reason,
  flagged, voided, flag_reason, cash_status, final_points, UNIX_TIMESTAMP(created_at) AS created_ts
  FROM cp_mission_runs WHERE id = ?]]

local function normaliseRow(row)
    row.id = math.tointeger(tonumber(row.id)) or row.id
    row.flagged = U.truthy(row.flagged)
    row.voided = U.truthy(row.voided)
    row.final_points = math.floor(num(row.final_points, 0))
    row.created_ts = math.floor(num(row.created_ts, 0))
    return row
end

function Admin.getRow(rowId)
    local id = int(rowId, 1, 2147483647)
    if not id then return nil, 'err.invalid_row' end
    local row, ok = single(ROW_SQL, { id })
    if not ok then return nil, 'err.internal' end
    if not row then return nil, 'err.row_not_found' end
    return normaliseRow(row)
end

function Admin.runDepartments(runUuid)
    local out, seen = {}, {}
    local function add(d)
        if type(d) == 'string' and d ~= '' and not seen[d] then
            seen[d] = true
            out[#out + 1] = d
        end
    end
    if validUuid(runUuid) then
        for _, r in ipairs(query('SELECT DISTINCT department FROM cp_mission_runs WHERE run_uuid = ?', { runUuid }) or {}) do
            add(r.department)
        end
        local run = has('Runs', 'get') and CP.Runs.get(runUuid) or nil
        if type(run) == 'table' and type(run.participants) == 'table' then
            for _, p in pairs(run.participants) do add(p.department) end
        end
    end
    table.sort(out)
    return out
end

local function rowTarget(row)
    return ('#%s %s'):format(tostring(row.id), tostring(row.citizenid))
end

-- Supervisor review of a row: the action switch, their department, never their own run.
local function reviewAllowed(src, action, row)
    local ctx = nil
    if not isAdmin(src) then ctx = { departments = Admin.runDepartments(row.run_uuid) } end
    local ok, errKey = can(src, action, ctx)
    if not ok then return false, errKey end
    return true
end

local function ownRunCheck(src, runUuid)
    if not has('Permissions', 'canReviewRun') then return false, 'err.no_permission' end
    local ok, allowed, errKey = call('Permissions', 'canReviewRun', src, runUuid)
    if not ok then return false, 'err.internal' end
    if not allowed then return false, errKey or 'err.own_run' end
    -- Still on that run (no row of theirs yet): also their own run.
    if inLiveRun(citizenOf(src), runUuid) then return false, 'err.own_run' end
    return true
end

local function releaseHeld(row)
    if row.cash_status == 'held' then call('Cash', 'release', row.id) end
end

local CLEAR_FLAG_SQL = [[UPDATE cp_mission_runs SET flagged = 0,
  breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.flagged', NULL), breakdown)
  WHERE id = ? AND flagged = 1 AND voided = 0]]

function Admin.approveFlagged(src, rowId, reason, opts)
    opts = type(opts) == 'table' and opts or {}
    reason = cleanText(reason)
    if not reason then return false, 'err.reason_required' end
    local row, errKey = Admin.getRow(rowId)
    if not row then return false, errKey end
    if row.voided then return false, 'err.already_voided' end
    if not row.flagged then return false, 'err.not_flagged' end
    if not opts.skipPermission then
        local ok, e = reviewAllowed(src, 'reviewFlagged', row)
        if not ok then return false, e end
    end
    local okOwn, eOwn = ownRunCheck(src, row.run_uuid)
    if not okOwn then return false, eOwn end

    local n = update(CLEAR_FLAG_SQL, { row.id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then return false, 'err.conflict' end
    releaseHeld(row)
    call('Scoring', 'onRowApproved', row.id)
    call('Leaderboard', 'invalidate')
    if not opts.noAudit then
        Admin.audit(src, roleOf(src), 'flags', 'approveFlagged', rowTarget(row), row.flag_reason, 'approved', reason)
    end
    if not opts.quiet then
        notify(onlineSrc(row.citizenid), 'success', 'admin.notice.run_approved', { mission = Admin.missionLabel(row.mission_id) })
    end
    CP.log(TAG, 'row %d approved by %s', row.id, tostring(src))
    return true, { rowId = row.id }
end

-- Void one row (checks done by the caller). Returns true or false, errKey.
local function voidRow(src, row, reason, action)
    local n = update('UPDATE cp_mission_runs SET voided = 1 WHERE id = ? AND voided = 0', { row.id })
    if n == nil then return false, 'err.internal' end
    if n == 0 then return false, 'err.already_voided' end
    call('Scoring', 'onRowVoided', row.id)
    Admin.audit(src, roleOf(src), 'flags', action, rowTarget(row), row.flagged and 'flagged' or row.state, 'voided', reason)
    notify(onlineSrc(row.citizenid), 'warning', 'admin.notice.run_voided', { mission = Admin.missionLabel(row.mission_id) })
    if not NON_MISSION_TYPES[row.mission_type] then
        call('AntiCheat', 'onVoided', row.citizenid)
    end
    return true
end

function Admin.voidFlagged(src, rowId, reason)
    reason = cleanText(reason)
    if not reason then return false, 'err.reason_required' end
    local row, errKey = Admin.getRow(rowId)
    if not row then return false, errKey end
    if row.voided then return false, 'err.already_voided' end
    if not row.flagged then return false, 'err.not_flagged' end
    local ok, e = reviewAllowed(src, 'reviewFlagged', row)
    if not ok then return false, e end
    local okOwn, eOwn = ownRunCheck(src, row.run_uuid)
    if not okOwn then return false, eOwn end
    local done, eVoid = voidRow(src, row, reason, 'voidFlagged')
    if not done then return false, eVoid end
    call('Leaderboard', 'invalidate')
    return true, { rowId = row.id, voided = 1 }
end

function Admin.voidRun(src, target, reason)
    reason = cleanText(reason)
    if not reason then return false, 'err.reason_required' end
    local okP, eP = can(src, 'voidAnyRun')
    if not okP then return false, eP end
    local rows = {}
    local runUuid
    if type(target) == 'string' and not tonumber(target) then
        if not validUuid(target) then return false, 'err.invalid_run' end
        runUuid = target
        for _, r in ipairs(query([[SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, end_reason,
            flagged, voided, flag_reason, cash_status, final_points, UNIX_TIMESTAMP(created_at) AS created_ts
            FROM cp_mission_runs WHERE run_uuid = ? AND voided = 0 ORDER BY id]], { runUuid }) or {}) do
            rows[#rows + 1] = normaliseRow(r)
        end
        if #rows == 0 then return false, 'err.nothing_to_void' end
    else
        local row, errKey = Admin.getRow(target)
        if not row then return false, errKey end
        if row.voided then return false, 'err.already_voided' end
        runUuid = row.run_uuid
        rows[1] = row
    end
    local okOwn, eOwn = ownRunCheck(src, runUuid)
    if not okOwn then return false, eOwn end
    local voided = 0
    local lastErr
    for _, row in ipairs(rows) do
        local ok, e = voidRow(src, row, reason, 'voidRun')
        if ok then voided = voided + 1 else lastErr = e end
    end
    if voided == 0 then return false, lastErr or 'err.conflict' end
    call('Leaderboard', 'invalidate')
    return true, { voided = voided, runUuid = runUuid }
end

-- ── force recall ────────────────────────────────────────────────────────────
local function runInvolves(run, dept)
    if type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    for _, p in pairs(run.participants) do
        if p.department == dept then return true end
    end
    return false
end

local function runDeptList(run)
    local out, seen = {}, {}
    for _, p in pairs(run.participants or {}) do
        if p.department and not seen[p.department] then
            seen[p.department] = true
            out[#out + 1] = p.department
        end
    end
    table.sort(out)
    return out
end

function Admin.forceRecall(src, runId, targetSrc, reason)
    if type(runId) ~= 'string' or #runId > 64 then return false, 'err.invalid_run' end
    local target = toSrc(targetSrc)
    if not target then return false, 'err.invalid_payload' end
    local run = has('Runs', 'get') and CP.Runs.get(runId) or nil
    if type(run) ~= 'table' or run.state == 'ended' then return false, 'err.invalid_run' end
    local p = run.participants and run.participants[target]
    if not p or p.status ~= 'active' then return false, 'err.not_participant' end
    local ctx = nil
    if not isAdmin(src) then ctx = { departments = runDeptList(run) } end
    local okP, eP = can(src, 'forceRecall', ctx)
    if not okP then return false, eP end
    if not has('Runs', 'removeParticipant') then return false, 'err.module_unavailable' end
    reason = cleanText(reason)
    local ok = call('Runs', 'removeParticipant', run, target, 'force_recall', { notify = 'admin.notice.force_recalled' })
    if not ok then return false, 'err.internal' end
    Admin.audit(src, roleOf(src), 'audit', 'forceRecall', U.clip(p.citizenid, 64), run.missionId, 'force_recall', reason)
    return true, { runId = runId, src = target }
end

-- ── citizen ids ─────────────────────────────────────────────────────────────
function Admin.resolveCitizenId(input)
    if type(input) ~= 'string' then return nil end
    local s = U.trim(input)
    if s == '' or #s > 50 or not s:match('^[%w_%-]+$') then return nil end
    -- cp_officers uses a case-insensitive collation: this returns the stored spelling.
    local row = single('SELECT citizenid FROM cp_officers WHERE citizenid = ? LIMIT 1', { s })
    if row and type(row.citizenid) == 'string' then return row.citizenid end
    if onlineSrc(s) then return s end
    local up = s:upper()
    if up ~= s and onlineSrc(up) then return up end
    return nil
end

-- ── command ─────────────────────────────────────────────────────────────────
local function reply(src, kind, key, vars)
    if tonumber(src) == 0 then
        local colour = ({ error = '^1', success = '^2', warning = '^3' })[kind] or '^5'
        print(('%s[Crimson-Police] %s^7'):format(colour, CP.L(key, vars)))
    else
        notify(src, kind, key, vars)
    end
end

local function cmdName()
    return (Config.Tablet and Config.Tablet.adminCommand) or 'CrimsonPoliceAdmin'
end

local function joinFrom(args, i)
    local parts = {}
    for k = i, #args do parts[#parts + 1] = tostring(args[k]) end
    return cleanText(table.concat(parts, ' '))
end

-- Result of a delegated call: ok (anything but false/nil-with-error), errKey.
local function outcome(okCall, a, b)
    if not okCall then return false, 'err.internal' end
    if a == false or (a == nil and type(b) == 'string') then return false, b or 'err.refused' end
    return true, a
end

local function parseAmount(v)
    if type(v) ~= 'string' then return nil, false end
    if v:lower() == 'clear' then return nil, true end
    local lo = math.floor(num(Config.Cash and Config.Cash.minPayout, 0))
    local hi = math.floor(num(Config.Cash and Config.Cash.maxPayout, 25000))
    local n = int(v, lo, hi)
    if not n then return nil, false end
    return n, true
end

local function usage(src)
    local c = cmdName()
    if tonumber(src) ~= 0 then
        return reply(src, 'info', 'admin.cmd.help_ingame', { cmd = c })
    end
    for _, key in ipairs({ 'admin.cmd.usage_title', 'admin.cmd.usage_open', 'admin.cmd.usage_payout_type',
        'admin.cmd.usage_payout_mission', 'admin.cmd.usage_award', 'admin.cmd.usage_season', 'admin.cmd.usage_suspend',
        'admin.cmd.usage_reload', 'admin.cmd.usage_test' }) do
        reply(src, 'info', key, { cmd = c })
    end
end

local function missingReason(src)
    reply(src, 'error', 'err.reason_required')
end

local SUB = {}

SUB.help = function(src) usage(src) end

SUB.payout = function(src, args)
    local what = args[1] and args[1]:lower() or ''
    if what == 'type' then
        local typeKey = args[2] and args[2]:lower() or ''
        if not (Config.MissionTypes and Config.MissionTypes[typeKey]) then return reply(src, 'error', 'err.invalid_type') end
        local amount, valid = parseAmount(args[3])
        if not valid then
            return reply(src, 'error', 'admin.cmd.amount_range', { min = num(Config.Cash.minPayout, 0), max = num(Config.Cash.maxPayout, 25000) })
        end
        local reason = joinFrom(args, 4)
        if not reason and (Config.Payouts == nil or Config.Payouts.requireReason ~= false) then return missingReason(src) end
        local okP, eP = can(src, amount == nil and 'clearPayout' or 'setTypePayout')
        if not okP then return reply(src, 'error', eP) end
        if not has('Payouts', 'setType') then return reply(src, 'error', 'err.module_unavailable') end
        local ok, e = outcome(call('Payouts', 'setType', src, typeKey, amount, reason, 'admin'))
        if not ok then return reply(src, 'error', e) end
        if amount == nil then
            return reply(src, 'success', 'admin.cmd.payout_type_cleared', { type = typeLabel(typeKey) })
        end
        return reply(src, 'success', 'admin.cmd.payout_type_set', { type = typeLabel(typeKey), amount = amount })
    elseif what == 'mission' then
        local def = findMission(args[2])
        if not def then return reply(src, 'error', 'err.unknown_mission') end
        local amount, valid = parseAmount(args[3])
        if not valid then
            return reply(src, 'error', 'admin.cmd.amount_range', { min = num(Config.Cash.minPayout, 0), max = num(Config.Cash.maxPayout, 25000) })
        end
        local reason = joinFrom(args, 4)
        if not reason and (Config.Payouts == nil or Config.Payouts.requireReason ~= false) then return missingReason(src) end
        local okP, eP = can(src, amount == nil and 'clearPayout' or 'setMissionPayout')
        if not okP then return reply(src, 'error', eP) end
        if not has('Payouts', 'setMission') then return reply(src, 'error', 'err.module_unavailable') end
        local ok, e = outcome(call('Payouts', 'setMission', src, def.id, amount, reason))
        if not ok then return reply(src, 'error', e) end
        if amount == nil then
            return reply(src, 'success', 'admin.cmd.payout_mission_cleared', { mission = def.label or def.id })
        end
        return reply(src, 'success', 'admin.cmd.payout_mission_set', { mission = def.label or def.id, amount = amount })
    end
    return usage(src)
end

SUB.award = function(src, args)
    local cid = Admin.resolveCitizenId(args[1])
    if not cid then return reply(src, 'error', 'err.unknown_officer') end
    local points = int(args[2], 1, MAX_AWARD)
    if not points then return reply(src, 'error', 'err.invalid_points', { max = MAX_AWARD }) end
    local reason = joinFrom(args, 3)
    if not reason then return missingReason(src) end
    local okP, eP = can(src, 'manualAward')
    if not okP then return reply(src, 'error', eP) end
    if not has('Scoring', 'manualAward') then return reply(src, 'error', 'err.module_unavailable') end
    local ok, e = outcome(call('Scoring', 'manualAward', src, cid, points, reason))
    if not ok then return reply(src, 'error', e) end
    return reply(src, 'success', 'admin.cmd.awarded', { points = points, citizenid = cid })
end

SUB.season = function(src, args)
    local what = args[1] and args[1]:lower() or ''
    local okP, eP = can(src, 'seasons')
    if not okP then return reply(src, 'error', eP) end
    if what == 'start' then
        local name = joinFrom(args, 2)
        if not name then return reply(src, 'error', 'err.season_name') end
        name = U.clip(name, 64)
        if not has('Challenge', 'startSeason') then return reply(src, 'error', 'err.module_unavailable') end
        local ok, e = outcome(call('Challenge', 'startSeason', src, name))
        if not ok then return reply(src, 'error', e) end
        return reply(src, 'success', 'admin.cmd.season_started', { name = name })
    elseif what == 'end' then
        if not has('Challenge', 'endSeason') then return reply(src, 'error', 'err.module_unavailable') end
        local ok, e = outcome(call('Challenge', 'endSeason', src))
        if not ok then return reply(src, 'error', e) end
        return reply(src, 'success', 'admin.cmd.season_ended')
    end
    return usage(src)
end

-- Suspend (days > 0) or lift (0) and write the audit entry. Returns ok, data|errKey.
local function suspendOfficer(src, citizenid, days, reason)
    local okP, eP = can(src, 'suspend')
    if not okP then return false, eP end
    local d = int(days, 0, 3650)
    if not d then return false, 'err.invalid_days' end
    local cid = Admin.resolveCitizenId(citizenid)
    if not cid then return false, 'err.unknown_officer' end
    if not has('Access', 'suspend') then return false, 'err.module_unavailable' end
    local prev = single('SELECT UNIX_TIMESTAMP(suspended_until) AS until_ts FROM cp_officers WHERE citizenid = ?', { cid })
    local prevTs = prev and tonumber(prev.until_ts) or nil
    local wasSuspended = prevTs ~= nil and prevTs > os.time()
    if d == 0 and not wasSuspended then return false, 'err.not_suspended' end
    local ok, e = outcome(call('Access', 'suspend', cid, d, src, reason))
    if not ok then return false, e end
    Admin.audit(src, roleOf(src), 'audit', d == 0 and 'unsuspend' or 'suspend', cid,
        wasSuspended and os.date('%Y-%m-%d %H:%M', prevTs) or nil,
        d == 0 and 'lifted' or ('%d'):format(d), reason)
    return true, { citizenid = cid, days = d, untilTs = d > 0 and (os.time() + d * 86400) or nil }
end

SUB.suspend = function(src, args)
    local reason = joinFrom(args, 3)
    local ok, res = suspendOfficer(src, args[1], args[2], reason)
    if not ok then
        if res == 'err.invalid_days' then return reply(src, 'error', 'err.invalid_days') end
        return reply(src, 'error', res)
    end
    if res.days == 0 then return reply(src, 'success', 'admin.cmd.unsuspended', { citizenid = res.citizenid }) end
    return reply(src, 'success', 'admin.cmd.suspended', { citizenid = res.citizenid, days = res.days })
end

SUB.reload = function(src)
    local okP, eP = can(src, 'reloadMissions')
    if not okP then return reply(src, 'error', eP) end
    if not has('Missions', 'reload') then return reply(src, 'error', 'err.module_unavailable') end
    local before = has('Missions', 'all') and U.count(CP.Missions.all() or {}) or 0
    local ok, summary = call('Missions', 'reload')
    if not ok or type(summary) ~= 'table' then return reply(src, 'error', 'err.internal') end
    local failed = type(summary.failed) == 'table' and #summary.failed or 0
    Admin.audit(src, roleOf(src), 'audit', 'reloadMissions', nil, tostring(before),
        ('%d loaded, %d rejected'):format(math.floor(num(summary.loaded, 0)), failed), nil)
    reply(src, failed > 0 and 'warning' or 'success', 'admin.cmd.reloaded', { loaded = math.floor(num(summary.loaded, 0)), failed = failed })
    if tonumber(src) == 0 and failed > 0 then
        for _, f in ipairs(summary.failed) do
            reply(0, 'warning', 'admin.cmd.reload_failed_line', { id = tostring(f.id or f.file or '?'), error = tostring(f.error or '') })
        end
    end
end

local function tierExists(name)
    if name == 'auto' then return true end   -- CP.Testing: the tier the number of testers reaches
    for _, row in ipairs(Config.Scaling or {}) do
        if row.tier == name then return true end
    end
    return false
end

SUB.test = function(src, args)
    if tonumber(src) == 0 then return reply(src, 'error', 'err.not_in_game') end
    local okP, eP = can(src, 'testRun')
    if not okP then return reply(src, 'error', eP) end
    local def = findMission(args[1])
    if not def then return reply(src, 'error', 'err.unknown_mission') end
    if #args > 3 then return reply(src, 'error', 'admin.cmd.test_bad_arg', { arg = tostring(args[4]) }) end
    local tier, location
    for i = 2, math.min(#args, 3) do
        local a = tostring(args[i]):lower()
        if tierExists(a) and not tier then
            tier = a
        elseif a == 'random' and not location then
            location = 'random'
        elseif int(a, 1, 1000) and not location then
            location = int(a, 1, 1000)
            if location > #(def.locations or {}) then return reply(src, 'error', 'err.invalid_location') end
        else
            return reply(src, 'error', 'admin.cmd.test_bad_arg', { arg = tostring(args[i]) })
        end
    end
    if CP.Alerts and CP.Alerts.inArena and CP.Alerts.inArena(src) then return reply(src, 'error', 'err.in_arena') end
    local ok, e
    if has('Testing', 'command') then
        -- CP.Testing's own parser also brings the testers who accepted this admin's invitations.
        local words = { def.id }
        if tier then words[#words + 1] = tier end
        if location then words[#words + 1] = tostring(location) end
        ok, e = outcome(call('Testing', 'command', src, words))
    elseif has('Testing', 'start') then
        ok, e = outcome(call('Testing', 'start', src, {
            missionId = def.id, location = location or 'random', tier = tier,
            useStartRoute = Config.Testing and Config.Testing.useStartRoute == true or false, testers = {},
        }))
    else
        return reply(src, 'error', 'err.module_unavailable')
    end
    if not ok then return reply(src, 'error', e) end
    return reply(src, 'success', 'admin.cmd.test_started', { mission = def.label or def.id })
end

function Admin.command(src, args)
    src = tonumber(src) or 0
    args = type(args) == 'table' and args or {}
    if src ~= 0 and not isAdmin(src) then return reply(src, 'error', 'err.not_admin') end
    local sub = args[1] and tostring(args[1]):lower() or nil
    if not sub then
        if src == 0 then return usage(src) end
        local okP, eP = can(src, 'openAdmin')
        if not okP then return reply(src, 'error', eP) end
        if not has('Tablet', 'openAdmin') then return reply(src, 'error', 'err.module_unavailable') end
        local ok, opened, e = call('Tablet', 'openAdmin', src)
        if ok and opened == false and e then reply(src, 'error', e) end
        return
    end
    local fn = SUB[sub]
    if not fn then
        reply(src, 'error', 'admin.cmd.unknown', { cmd = cmdName(), sub = sub })
        return usage(src)
    end
    local rest = {}
    for i = 2, #args do rest[#rest + 1] = tostring(args[i]) end
    local ok, err = pcall(fn, src, rest)
    if not ok then
        CP.err(TAG, '/%s %s failed: %s', cmdName(), sub, tostring(err))
        reply(src, 'error', 'err.internal')
    end
end

-- ── net: actions ────────────────────────────────────────────────────────────
local function reviewAction(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local decision = payload.decision
    if decision == 'approve' then return Admin.approveFlagged(src, payload.rowId, payload.reason) end
    if decision == 'void' then return Admin.voidFlagged(src, payload.rowId, payload.reason) end
    return false, 'err.invalid_decision'
end

CP.Net.action('server:sup:forceRecall', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return Admin.forceRecall(src, payload.runId, payload.src, payload.reason)
end, { rate = 3 })

CP.Net.action('server:sup:reviewFlagged', function(src, payload)
    return reviewAction(src, payload)
end, { rate = 3 })

CP.Net.action('server:admin:reviewFlagged', function(src, payload)
    if not isAdmin(src) then return false, 'err.no_permission' end
    return reviewAction(src, payload)
end, { rate = 3 })

CP.Net.action('server:admin:voidRun', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    if not isAdmin(src) then return false, 'err.no_permission' end
    local target = payload.rowId
    if target == nil then target = payload.runUuid end
    if target == nil then return false, 'err.invalid_payload' end
    if type(target) == 'number' or (type(target) == 'string' and tonumber(target)) then
        target = int(target, 1, 2147483647)
        if not target then return false, 'err.invalid_row' end
    end
    return Admin.voidRun(src, target, payload.reason)
end, { rate = 3 })

CP.Net.action('server:admin:awardPoints', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local okP, eP = can(src, 'manualAward')
    if not okP then return false, eP end
    local points = int(payload.points, 1, MAX_AWARD)
    if not points then return false, 'err.invalid_points' end
    local reason = cleanText(payload.reason)
    if not reason then return false, 'err.reason_required' end
    local cid = Admin.resolveCitizenId(payload.citizenid)
    if not cid then return false, 'err.unknown_officer' end
    if not has('Scoring', 'manualAward') then return false, 'err.module_unavailable' end
    local ok, e = outcome(call('Scoring', 'manualAward', src, cid, points, reason))
    if not ok then return false, e end
    return true, { citizenid = cid, points = points }
end, { rate = 2 })

CP.Net.action('server:admin:suspend', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local reason = cleanText(payload.reason)
    if not reason then return false, 'err.reason_required' end
    return suspendOfficer(src, payload.citizenid, payload.days, reason)
end, { rate = 2 })

-- ── net: callbacks ──────────────────────────────────────────────────────────
local function baseFor(def)
    if has('Payouts', 'baseFor') then
        local ok, b = call('Payouts', 'baseFor', def)
        if ok and tonumber(b) then return math.floor(tonumber(b) + 0.5) end
    end
    if def.isBoss then
        local boss = Config.Events and Config.Events.weeklyBoss
        return math.floor(num(boss and boss.payout, 0))
    end
    local mt = Config.MissionTypes and Config.MissionTypes[def.type]
    local stars = Config.Difficulty and Config.Difficulty.cashByStars or {}
    return math.floor(num(mt and mt.payout, 0) * num(stars[def.difficulty], 1) + 0.5)
end

local function sourceFor(def)
    if has('Payouts', 'sourceFor') then
        local ok, s = call('Payouts', 'sourceFor', def)
        if ok and (s == 'admin' or s == 'type' or s == 'event') then return s end
    end
    return def.isBoss and 'event' or 'type'
end

local function runningByMission()
    local out = {}
    if not has('Runs', 'all') then return out end
    local ok, list = call('Runs', 'all')
    if not ok or type(list) ~= 'table' then return out end
    for _, run in ipairs(list) do
        local id = run.missionId or (run.mission and run.mission.id)
        if id then
            local entry = out[id] or {}
            out[id] = entry
            for _, s in ipairs(run.order or {}) do
                local p = run.participants and run.participants[s]
                if p and p.status == 'active' then
                    entry[#entry + 1] = { runId = run.id, src = s, name = p.name or ('#' .. s), callsign = p.callsign,
                        departmentShort = p.departmentShort or deptShort(p.department), test = run.test ~= nil }
                end
            end
        end
    end
    return out
end

local function operationInfo()
    if not has('Operations', 'active') then return nil end
    local ok, op = call('Operations', 'active')
    if not ok or type(op) ~= 'table' then return nil end
    local missionId = op.missionId or op.mission_id
    return {
        id = tonumber(op.id), missionId = missionId, status = op.status,
        missionLabel = op.missionLabel or (missionId and Admin.missionLabel(missionId)) or '',
    }
end

CP.Net.callback('getMissionList', function(src)
    local okP, eP = can(src, 'viewMissionList')
    if not okP then return nil, eP end
    if not has('Missions', 'list') then return nil, 'err.module_unavailable' end
    local running = runningByMission()
    local list = {}
    for _, def in ipairs(CP.Missions.list() or {}) do
        local enabled = has('Missions', 'isEnabled') and CP.Missions.isEnabled(def.id) == true or false
        local depts = {}
        for _, d in ipairs(type(def.departments) == 'table' and def.departments or {}) do depts[#depts + 1] = d end
        local maxO = math.floor(num(def.maxOfficers, 1))
        local eligible = #depts == 0 and maxO >= 2 and not def.isBoss and enabled
        if has('Operations', 'eligible') then
            -- The same rule CP.Operations applies when the launch arrives.
            local okE, e = call('Operations', 'eligible', def)
            if okE then eligible = e == true end
        end
        list[#list + 1] = {
            id = def.id, label = def.label or def.id, type = def.type, typeLabel = typeLabel(def.type),
            source = def.source == 'custom' and 'custom' or 'builtin', builtin = def.source ~= 'custom',
            version = tonumber(def.version), difficulty = math.floor(num(def.difficulty, 1)),
            minOfficers = math.floor(num(def.minOfficers, 1)), maxOfficers = maxO,
            basePayout = baseFor(def), payoutSource = sourceFor(def),
            cooldown = math.floor(num(def.cooldown, 0)), timeLimit = math.floor(num(def.timeLimit, 0)),
            locations = #(def.locations or {}), enabled = enabled, isBoss = def.isBoss == true,
            departments = depts, runningNow = running[def.id] or {},
            crossDeptEligible = eligible,
        }
    end
    table.sort(list, function(a, b)
        if a.type ~= b.type then return tostring(a.type) < tostring(b.type) end
        return tostring(a.label) < tostring(b.label)
    end)
    local canLaunch = can(src, 'launchCrossDept')
    local op = operationInfo()
    return {
        missions = list,
        canLaunch = canLaunch and (Config.CrossDept == nil or Config.CrossDept.enabled ~= false),
        crossDeptEnabled = Config.CrossDept == nil or Config.CrossDept.enabled ~= false,
        operation = op,
    }
end, { rate = 3 })

local function viewerDepartment(src)
    if tonumber(src) == 0 then return nil, nil end
    local officer = CP.Access and CP.Access.getOfficer and CP.Access.getOfficer(src) or nil
    local citizenid = officer and officer.citizenid
    if not citizenid then
        local ok, info = call('Qbx', 'getInfo', src)
        citizenid = ok and type(info) == 'table' and info.citizenid or nil
    end
    return officer and officer.department or nil, citizenid
end

CP.Net.callback('sup:getLiveRuns', function(src)
    local okP, eP = can(src, 'viewMissionList')
    if not okP then return nil, eP end
    if not has('Runs', 'all') then return nil, 'err.module_unavailable' end
    local dept = viewerDepartment(src)
    local admin = isAdmin(src)
    if not dept and not admin then return nil, 'err.no_permission' end
    local canRecall = can(src, 'forceRecall')
    local out = {}
    for _, run in ipairs(CP.Runs.all() or {}) do
        if run.state ~= 'ended' and ((dept and runInvolves(run, dept)) or (not dept and admin)) then
            local ok, s = call('Runs', 'summary', run)
            if ok and type(s) == 'table' then
                for _, p in ipairs(s.participants or {}) do
                    local rp = run.participants and run.participants[p.src]
                    p.arrived = rp and rp.arrived == true or false
                    p.department = rp and rp.department or nil
                end
                s.missionId = run.missionId
                s.acceptedAt = run.acceptedAt
                s.startedAt = run.startedAt
                s.isBoss = run.isBoss == true
                local shorts = {}
                for _, d in ipairs(runDeptList(run)) do shorts[#shorts + 1] = deptShort(d) end
                s.departments = shorts
                out[#out + 1] = s
            end
        end
    end
    return { runs = out, serverTime = os.time(), canRecall = canRecall }
end, { rate = 3 })

-- Flag events recorded by CP.AntiCheat.flag (cp_audit 'runFlagged'): uuid -> { { citizenid|nil, reason, detail } }
local function flagEvents(uuids)
    local out = {}
    if #uuids == 0 then return out end
    local i = 1
    while i <= #uuids do
        local chunk, marks = {}, {}
        for k = i, math.min(i + 99, #uuids) do
            chunk[#chunk + 1] = uuids[k]
            marks[#marks + 1] = '?'
        end
        i = i + 100
        local rows = query(('SELECT target, old_value, new_value, reason FROM cp_audit WHERE category = \'flags\' AND action = \'runFlagged\' AND target IN (%s) ORDER BY id'):format(table.concat(marks, ', ')), chunk) or {}
        for _, r in ipairs(rows) do
            local list = out[r.target] or {}
            out[r.target] = list
            list[#list + 1] = { citizenid = r.old_value, reason = r.new_value, detail = r.reason }
        end
    end
    return out
end

local FLAGGED_SQL = [[SELECT r.id, r.run_uuid, r.citizenid, r.department, r.mission_type, r.mission_id, r.location_label,
  r.state, r.end_reason, r.tier, r.participants, r.departments_n, r.final_points, r.cash_status, r.flag_reason,
  r.duration_s, JSON_VALUE(r.breakdown, '$.cash.amount') AS cash_amount,
  UNIX_TIMESTAMP(r.created_at) AS created_ts, o.display_name, o.callsign
  FROM cp_mission_runs r
  LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
  WHERE r.flagged = 1 AND r.voided = 0]]

function Admin.flaggedRows(dept, excludeCitizenid)
    local sql, params = FLAGGED_SQL, {}
    if dept then
        sql = sql .. ' AND r.run_uuid IN (SELECT d.run_uuid FROM cp_mission_runs d WHERE d.department = ?)'
        params[#params + 1] = dept
    end
    if excludeCitizenid then
        sql = sql .. ' AND r.run_uuid NOT IN (SELECT m.run_uuid FROM cp_mission_runs m WHERE m.citizenid = ?)'
        params[#params + 1] = excludeCitizenid
    end
    sql = sql .. (' ORDER BY r.created_at DESC, r.id DESC LIMIT %d'):format(FLAGGED_LIMIT)
    local rows = {}
    for _, r in ipairs(query(sql, params) or {}) do
        -- A run the viewer is still on (their own row is not written yet) is their own run too.
        if not inLiveRun(excludeCitizenid, r.run_uuid) then rows[#rows + 1] = r end
    end
    local uuids, seen = {}, {}
    for _, r in ipairs(rows) do
        if not seen[r.run_uuid] then seen[r.run_uuid] = true; uuids[#uuids + 1] = r.run_uuid end
    end
    local events = flagEvents(uuids)
    local out = {}
    for _, r in ipairs(rows) do
        local details, reasons = {}, {}
        for _, e in ipairs(events[r.run_uuid] or {}) do
            if e.citizenid == nil or e.citizenid == r.citizenid then
                if e.detail and e.detail ~= '' then details[#details + 1] = e.detail end
                if e.reason and e.reason ~= r.flag_reason then reasons[#reasons + 1] = e.reason end
            end
        end
        out[#out + 1] = {
            rowId = math.tointeger(tonumber(r.id)), runUuid = r.run_uuid, citizenid = r.citizenid,
            name = r.display_name or r.citizenid, callsign = r.callsign,
            department = r.department, departmentShort = deptShort(r.department),
            missionId = r.mission_id, missionLabel = Admin.missionLabel(r.mission_id), missionType = r.mission_type,
            missionTypeLabel = typeLabel(r.mission_type), location = r.location_label,
            state = r.state, endReason = r.end_reason, tier = r.tier,
            participants = math.floor(num(r.participants, 1)), departments = math.floor(num(r.departments_n, 1)),
            points = math.floor(num(r.final_points, 0)), cash = math.floor(num(r.cash_amount, 0)),
            cashStatus = r.cash_status, flagReason = r.flag_reason or 'flagged',
            flagDetail = #details > 0 and table.concat(details, ' · ') or nil,
            otherReasons = reasons, durationS = math.floor(num(r.duration_s, 0)),
            createdAt = math.floor(num(r.created_ts, 0)),
        }
    end
    return out
end

CP.Net.callback('sup:getReviewQueue', function(src)
    local canReview = can(src, 'reviewFlagged')
    local canHandle = can(src, 'handleDisputes')
    if not canReview and not canHandle then return nil, 'err.no_permission' end
    local dept, citizenid = viewerDepartment(src)
    if not dept and not isAdmin(src) then return nil, 'err.no_permission' end
    local flagged = canReview and Admin.flaggedRows(dept, citizenid or '') or {}
    local disputes = {}
    if canHandle and has('Disputes', 'forSupervisor') then
        local ok, list = call('Disputes', 'forSupervisor', src)
        if ok and type(list) == 'table' then disputes = list end
    end
    return { flagged = flagged, disputes = disputes, canReview = canReview, canHandle = canHandle }
end, { rate = 3 })

local function adminOnly(src)
    return can(src, 'openAdmin')
end

CP.Net.callback('admin:getFlagged', function(src)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local _, citizenid = viewerDepartment(src)
    return { flagged = Admin.flaggedRows(nil, citizenid or '') }
end, { rate = 3 })

local function suspensionOf(ts)
    ts = tonumber(ts)
    if ts and ts > os.time() then return ts end
    return nil
end

CP.Net.callback('admin:searchOfficers', function(src, args)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local q = type(args) == 'table' and type(args.query) == 'string' and U.trim(args.query) or ''
    if #q > 64 then q = q:sub(1, 64) end
    local sql = 'SELECT citizenid, callsign, rank_label, display_name, department, xp, UNIX_TIMESTAMP(suspended_until) AS suspended_ts FROM cp_officers'
    local params = {}
    if q ~= '' then
        local like = likeArg(q)
        sql = sql .. ' WHERE citizenid LIKE ? OR callsign LIKE ? OR display_name LIKE ?'
        params = { like, like, like }
    end
    sql = sql .. (' ORDER BY display_name IS NULL, display_name, citizenid LIMIT %d'):format(SEARCH_LIMIT)
    local rows = query(sql, params)
    if not rows then return nil, 'err.internal' end
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            citizenid = r.citizenid, name = r.display_name or r.citizenid, callsign = r.callsign, rank = r.rank_label,
            department = r.department, departmentShort = deptShort(r.department), xp = math.floor(num(r.xp, 0)),
            suspendedUntil = suspensionOf(r.suspended_ts), online = onlineSrc(r.citizenid) ~= nil,
        }
    end
    return { officers = out, query = q }
end, { rate = 4 })

local function xpLevel(xp)
    if has('Scoring', 'xpLevel') then
        local ok, lvl = call('Scoring', 'xpLevel', xp)
        if ok and type(lvl) == 'table' then return lvl end
    end
    local levels = Config.XPLevels or {}
    local cur, nextXp = nil, nil
    for i, l in ipairs(levels) do
        if xp >= num(l.xp, 0) then
            cur = l
            nextXp = levels[i + 1] and levels[i + 1].xp or nil
        end
    end
    if not cur then return nil end
    return { label = cur.label, badge = cur.badge, xp = xp, next = nextXp }
end

local function badgesOf(citizenid)
    if has('Scoring', 'badges') then
        local ok, list = call('Scoring', 'badges', citizenid)
        if ok and type(list) == 'table' then return list end
    end
    local out = {}
    for _, r in ipairs(query('SELECT badge_id, UNIX_TIMESTAMP(earned_at) AS earned_ts FROM cp_badges WHERE citizenid = ? ORDER BY earned_at DESC', { citizenid }) or {}) do
        out[#out + 1] = { id = r.badge_id, label = r.badge_id, earnedAt = os.date('%Y-%m-%d', math.floor(num(r.earned_ts, 0))) }
    end
    return out
end

local function weekStartTs()
    if has('Schedule', 'weekStart') then
        local ok, ts = call('Schedule', 'weekStart')
        if ok and tonumber(ts) then return math.floor(tonumber(ts)) end
    end
    return os.time() - 7 * 86400
end

CP.Net.callback('admin:getOfficer', function(src, args)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local cid = type(args) == 'table' and Admin.resolveCitizenId(args.citizenid) or nil
    if not cid then return nil, 'err.unknown_officer' end
    local o = single('SELECT citizenid, callsign, rank_label, display_name, department, xp, streak_days, UNIX_TIMESTAMP(suspended_until) AS suspended_ts FROM cp_officers WHERE citizenid = ?', { cid })
    local xp = math.floor(num(o and o.xp, 0))
    local stats = single([[SELECT COUNT(*) AS runs, COALESCE(SUM(state = 'completed'), 0) AS completed,
        COALESCE(SUM(state = 'failed'), 0) AS failed, COALESCE(SUM(state = 'abandoned'), 0) AS abandoned,
        COALESCE(SUM(flagged = 1), 0) AS flagged, COALESCE(SUM(voided = 1), 0) AS voided,
        COALESCE(SUM(cash_paid), 0) AS cash_total,
        COALESCE(SUM(CASE WHEN created_at >= FROM_UNIXTIME(?) THEN cash_paid ELSE 0 END), 0) AS cash_week
        FROM (SELECT state, flagged, voided, cash_paid, created_at FROM cp_mission_runs WHERE citizenid = ? AND mission_type NOT IN ('manual_award', 'goal')
              UNION ALL
              SELECT state, flagged, voided, cash_paid, created_at FROM cp_mission_runs_archive WHERE citizenid = ? AND mission_type NOT IN ('manual_award', 'goal')) t]],
        { weekStartTs(), cid, cid }) or {}
    local cashWeek = math.floor(num(stats.cash_week, 0))
    if has('Cash', 'earnedThisWeek') then
        local ok, w = call('Cash', 'earnedThisWeek', cid)
        if ok and tonumber(w) then cashWeek = math.floor(tonumber(w)) end
    end
    local runs = {}
    for _, r in ipairs(query(([[SELECT id, run_uuid, mission_type, mission_id, state, end_reason, tier, participants,
        final_points, cash_paid, cash_status, flagged, voided, flag_reason, JSON_VALUE(breakdown, '$.cash.amount') AS cash_amount,
        UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_mission_runs WHERE citizenid = ? ORDER BY created_at DESC, id DESC LIMIT %d]]):format(RECENT_RUNS), { cid }) or {}) do
        runs[#runs + 1] = {
            id = math.tointeger(tonumber(r.id)), runUuid = r.run_uuid, missionId = r.mission_id,
            missionLabel = Admin.missionLabel(r.mission_id), missionType = r.mission_type, missionTypeLabel = typeLabel(r.mission_type),
            state = r.state, endReason = r.end_reason, tier = r.tier, participants = math.floor(num(r.participants, 1)),
            points = math.floor(num(r.final_points, 0)), cashPaid = math.floor(num(r.cash_paid, 0)),
            cash = math.floor(num(r.cash_amount, num(r.cash_paid, 0))), cashStatus = r.cash_status,
            flagged = U.truthy(r.flagged), voided = U.truthy(r.voided), flagReason = r.flag_reason,
            createdAt = math.floor(num(r.created_ts, 0)),
        }
    end
    local disputes = {}
    if has('Disputes', 'forOfficer') then
        local ok, list = call('Disputes', 'forOfficer', cid, 'admin', src)
        if ok and type(list) == 'table' then disputes = list end
    end
    local _, viewerCid = viewerDepartment(src)
    local dept = o and o.department or nil
    local deptInfo = dept and CP.Access and CP.Access.department and CP.Access.department(dept) or nil
    local online = onlineSrc(cid)
    return {
        citizenid = cid, name = o and o.display_name or cid, callsign = o and o.callsign or nil,
        rank = o and o.rank_label or nil, department = dept, departmentShort = deptShort(dept),
        departmentLabel = deptInfo and deptInfo.label or nil,
        xp = xp, level = xpLevel(xp), streakDays = math.floor(num(o and o.streak_days, 0)),
        badges = badgesOf(cid),
        cash = { total = math.floor(num(stats.cash_total, 0)), week = cashWeek },
        stats = {
            runs = math.floor(num(stats.runs, 0)), completed = math.floor(num(stats.completed, 0)),
            failed = math.floor(num(stats.failed, 0)), abandoned = math.floor(num(stats.abandoned, 0)),
            flagged = math.floor(num(stats.flagged, 0)), voided = math.floor(num(stats.voided, 0)),
        },
        suspension = { suspended = suspensionOf(o and o.suspended_ts) ~= nil, untilTs = suspensionOf(o and o.suspended_ts) },
        runs = runs, disputes = disputes, online = online ~= nil, own = viewerCid ~= nil and viewerCid == cid,
        known = o ~= nil, maxAward = MAX_AWARD,
    }
end, { rate = 4 })

local function onDutyCounts()
    local counts = {}
    if not (has('Qbx', 'getOnlinePlayers') and has('Qbx', 'getInfo')) then return counts end
    local ok, list = call('Qbx', 'getOnlinePlayers')
    if not ok or type(list) ~= 'table' then return counts end
    for _, s in ipairs(list) do
        local okI, info = call('Qbx', 'getInfo', s)
        if okI and type(info) == 'table' and type(info.job) == 'table' and info.job.onduty then
            local d = CP.Access.departmentForJob(info.job.name)
            if d then counts[d] = (counts[d] or 0) + 1 end
        end
    end
    return counts
end

CP.Net.callback('admin:getDepartments', function(src)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local members = {}
    for _, r in ipairs(query([[SELECT department, COUNT(*) AS n,
        COALESCE(SUM(suspended_until IS NOT NULL AND suspended_until > NOW()), 0) AS suspended
        FROM cp_officers WHERE department IS NOT NULL GROUP BY department]]) or {}) do
        members[r.department] = { n = math.floor(num(r.n, 0)), suspended = math.floor(num(r.suspended, 0)) }
    end
    local society = Config.Cash and Config.Cash.source == 'society'
    local duty = onDutyCounts()
    local out = {}
    for _, d in ipairs(CP.Access.departments() or {}) do
        local balance = nil
        if society and has('Banking', 'societyBalance') then
            local ok, b = call('Banking', 'societyBalance', d.societyAccount)
            if ok and tonumber(b) then balance = tonumber(b) end
        end
        local logo = nil
        if d.logo and d.logo.url then
            logo = { url = d.logo.url, watermark = d.logo.watermark ~= false, opacity = d.logo.opacity, size = d.logo.size, grayscale = d.logo.grayscale == true }
        end
        local m = members[d.key] or { n = 0, suspended = 0 }
        out[#out + 1] = {
            key = d.key, label = d.label, short = d.short, jobs = d.jobs, supervisorGrade = d.supervisorGrade,
            societyAccount = d.societyAccount, theme = d.theme, logo = logo,
            members = m.n, suspended = m.suspended, onDuty = duty[d.key] or 0, societyBalance = balance,
        }
    end
    return { departments = out, cashSource = society and 'society' or 'server', showSociety = society == true }
end, { rate = 3 })

CP.Net.callback('admin:getPermissions', function(src)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local sup = Config.Permissions and Config.Permissions.supervisor or {}
    local keys = {}
    for k in pairs(sup) do
        if type(k) == 'string' then keys[#keys + 1] = k end
    end
    local order = {}
    for i, k in ipairs(SUPERVISOR_ORDER) do order[k] = i end
    table.sort(keys, function(a, b)
        local ia, ib = order[a] or 1000, order[b] or 1000
        if ia ~= ib then return ia < ib end
        return a < b
    end)
    local list = {}
    local adminOnlySet = {}
    for _, a in ipairs(ADMIN_ONLY) do adminOnlySet[a] = true end
    for _, k in ipairs(keys) do
        list[#list + 1] = { action = k, enabled = sup[k] == true and not adminOnlySet[k] }
    end
    return { supervisor = list, adminOnly = ADMIN_ONLY, always = SUPERVISOR_ALWAYS }
end, { rate = 3 })

-- ── audit log reads ─────────────────────────────────────────────────────────
local function dateArg(v, endOfDay)
    if type(v) == 'number' and v > 0 then return math.floor(v) end
    if type(v) ~= 'string' then return nil end
    local y, m, d = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not y or m < 1 or m > 12 or d < 1 or d > 31 then return nil end
    local ts = os.time({ year = y, month = m, day = d, hour = 0, min = 0, sec = 0 })
    if endOfDay then ts = os.time({ year = y, month = m, day = d + 1, hour = 0, min = 0, sec = 0 }) end
    return ts
end

-- WHERE clause and params for the audit filters (shared by the page and the export).
function Admin._auditWhere(args)
    args = type(args) == 'table' and args or {}
    local conds, params = { '1 = 1' }, {}
    if type(args.category) == 'string' and CATEGORIES[args.category] then
        conds[#conds + 1] = 'a.category = ?'
        params[#params + 1] = args.category
    end
    local action = cleanText(args.action, 40)
    if action then
        conds[#conds + 1] = 'a.action = ?'
        params[#params + 1] = action
    end
    local actor = cleanText(args.actor, 64)
    if actor then
        local like = likeArg(actor)
        conds[#conds + 1] = '(a.actor LIKE ? OR o.display_name LIKE ?)'
        params[#params + 1] = like
        params[#params + 1] = like
    end
    local from = dateArg(args.from, false)
    if from then
        conds[#conds + 1] = 'a.created_at >= FROM_UNIXTIME(?)'
        params[#params + 1] = from
    end
    local to = dateArg(args.to, true)
    if to then
        conds[#conds + 1] = 'a.created_at < FROM_UNIXTIME(?)'
        params[#params + 1] = to
    end
    return table.concat(conds, ' AND '), params
end

local AUDIT_SELECT = [[SELECT a.id, a.actor, a.role, a.category, a.action, a.target, a.old_value, a.new_value, a.reason,
  UNIX_TIMESTAMP(a.created_at) AS created_ts, o.display_name
  FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor]]

local function auditRow(r)
    return {
        id = math.tointeger(tonumber(r.id)), actor = r.actor, actorName = r.display_name, role = r.role,
        category = r.category, action = r.action, target = r.target, oldValue = r.old_value, newValue = r.new_value,
        reason = r.reason, createdAt = math.floor(num(r.created_ts, 0)),
    }
end

CP.Net.callback('admin:getAudit', function(src, args)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    local where, params = Admin._auditWhere(args)
    local total = single(('SELECT COUNT(*) AS n FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor WHERE %s'):format(where), params)
    local n = math.floor(num(total and total.n, 0))
    local pages = math.max(1, math.ceil(n / AUDIT_PAGE))
    local page = int(type(args) == 'table' and args.page or 1, 1, 100000) or 1
    if page > pages then page = pages end
    local rows = query(('%s WHERE %s ORDER BY a.created_at DESC, a.id DESC LIMIT %d OFFSET %d'):format(AUDIT_SELECT, where, AUDIT_PAGE, (page - 1) * AUDIT_PAGE), params)
    if not rows then return nil, 'err.internal' end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = auditRow(r) end
    local actions = {}
    for _, r in ipairs(query('SELECT DISTINCT action FROM cp_audit ORDER BY action LIMIT 200') or {}) do actions[#actions + 1] = r.action end
    return { rows = out, page = page, pages = pages, total = n, pageSize = AUDIT_PAGE, actions = actions }
end, { rate = 4 })

local function csvCell(v)
    if v == nil then return '' end
    local s = tostring(v)
    if s:match('^[=+%-@\t\r]') then s = "'" .. s end
    if s:find('[,"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

function Admin._csv(rows)
    local lines = { 'id,time,actor,actor_name,role,category,action,target,old_value,new_value,reason' }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = table.concat({
            csvCell(r.id), csvCell(os.date('%Y-%m-%d %H:%M:%S', r.createdAt)), csvCell(r.actor), csvCell(r.actorName),
            csvCell(r.role), csvCell(r.category), csvCell(r.action), csvCell(r.target), csvCell(r.oldValue),
            csvCell(r.newValue), csvCell(r.reason),
        }, ',')
    end
    return table.concat(lines, '\n')
end

CP.Net.callback('admin:exportAudit', function(src, args)
    local okP, eP = adminOnly(src)
    if not okP then return nil, eP end
    if not CP.Net.rateOk(src, 'admin:exportAudit', 1, 3000) then return nil, 'err.rate_limited' end
    local where, params = Admin._auditWhere(args)
    local rows = query(('%s WHERE %s ORDER BY a.created_at DESC, a.id DESC LIMIT %d'):format(AUDIT_SELECT, where, EXPORT_MAX + 1), params)
    if not rows then return nil, 'err.internal' end
    local truncated = #rows > EXPORT_MAX
    local list = {}
    for i = 1, math.min(#rows, EXPORT_MAX) do list[i] = auditRow(rows[i]) end
    return { csv = Admin._csv(list), rows = #list, truncated = truncated }
end, { rate = 2 })

-- ── command registration (runtime) ──────────────────────────────────────────
CreateThread(function()
    local name = cmdName()
    RegisterCommand(name, function(source, args)
        local src = tonumber(source) or 0
        CreateThread(function()
            local ok, err = pcall(Admin.command, src, args)
            if not ok then CP.err(TAG, '/%s failed: %s', name, tostring(err)) end
        end)
    end, false)
    CP.log(TAG, '/%s registered', name)
end)
