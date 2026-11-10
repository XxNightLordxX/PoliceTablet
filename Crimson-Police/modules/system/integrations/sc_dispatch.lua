-- The sc-dispatch adapter of CP.Dispatch (modules/system/integrations/integrations): the only code that talks to
-- sc-dispatch.

-- Owns: the read-only listeners on sc-dispatch's events, the read-only mdt_dispatch lookup,
-- exports['sc-dispatch']:IsPlayerSuspended and exports['sc-dispatch']:ClearNotification.
-- Never uses sc-dispatch's call-creating export (missions never create dispatch calls) and never
-- triggers any sc-dispatch event. sc-dispatch's own handlers always run as well; nothing here blocks them.
-- Every handler does nothing while another script (or none) serves dispatch (Config.Integrations.dispatch).
--
-- Event registration (docs/dev/INTEGRATIONS.md, sc-dispatch):
--   RegisterNetEvent  sc-dispatch:server:ToggleResponding (callId, isResponding)   client-originated
--   RegisterNetEvent  sc-dispatch:server:ShotsFired / PlayerDown / PlayerDead (data) client-originated
--   AddEventHandler   sc-dispatch:server:callClearedByOfficer (callId)   server-local ONLY, so no client
--                     can fire it to lift their own "On a call" block
--   AddEventHandler   onResourceStart / onResourceStop of 'sc-dispatch' (a restart deactivates every call)
-- Every net handler captures 'source' on its first line (and os.time() right after, before anything can
-- yield) and validates the payload; per-player rate limits go through CP.Net.rateOk.
--
-- Adapter functions (CP.Dispatch, docs/dev/ARCHITECTURE.md §5.1)
--   available() -> boolean                 sc-dispatch is started
--   isSuspended(citizenid, jobName) -> boolean
--       exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobName); false when sc-dispatch is not
--       started or the export fails (sc-dispatch itself fails open). May yield (sc-dispatch awaits MySQL).
--   lookupActiveCall(callId) -> uniqueId|nil
--       SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1
--       with (the integer form or 0, the normalised string), in pcall. Returns the canonical call id:
--       the row's unique_id, or its row id as a string when unique_id is empty. nil when the call is
--       unknown or inactive, when sc-dispatch is not started, or on a query error (logged). The result
--       can be an 'npccall-' id: the caller must still classify it. Yields (database).
--   clearNotification(uniqueId, jobs) -> boolean
--       exports['sc-dispatch']:ClearNotification(uniqueId, jobs) in pcall. Only non-numeric string ids
--       are accepted (a number, or a digit-only string, would also match unrelated ems/fire rows by row
--       id). jobs defaults to { 'police' }. Call it from a handler or thread (sc-dispatch awaits MySQL).
--   realCallSummary() -> { total, p1 }|nil and mdtCommendations(citizenid) -> list|nil (read-only summaries)

local D = {}
local Dispatch = CP.Dispatch
local TAG = 'sc_dispatch'
local RESOURCE = 'sc-dispatch'
local MAX_ID_LEN = 64            -- mdt_dispatch.unique_id is VARCHAR(64)

local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

-- sc-dispatch serves dispatch now (its events mean nothing otherwise).
local function Serving() return CP.Integrations.is('dispatch', RESOURCE) end

function D.available()
    return GetResourceState(RESOURCE) == 'started'
end

function D.isSuspended(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if not D.available() then return false end
    if type(jobName) ~= 'string' or jobName == '' then jobName = nil end
    local ok, res = pcall(function() return exports[RESOURCE]:IsPlayerSuspended(citizenid, jobName) end)
    if not ok then
        LogError('IsPlayerSuspended', 'exports[\'sc-dispatch\']:IsPlayerSuspended failed: %s', tostring(res))
        return false
    end
    return res == true
end

function D.lookupActiveCall(callId)
    local key = Dispatch.normalizeCallId(callId)
    if key == '' or #key > MAX_ID_LEN then return nil end
    if not D.available() then return nil end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    -- Parameter order matches the placeholders: the integer form for 'id = ?' (0 for a non-numeric id,
    -- never the raw string, which MySQL would cast to 0), the string form for 'unique_id = ?'.
    local num = key:match('^%d+$') and math.tointeger(tonumber(key)) or 0
    local ok, rows = pcall(MySQL.query.await,
        'SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { num, key })
    if not ok then
        LogError('lookup', 'mdt_dispatch lookup failed (sc-dispatch must have started once to add unique_id): %s',
            tostring(rows))
        return nil
    end
    local row = type(rows) == 'table' and rows[1] or nil
    if type(row) ~= 'table' then return nil end
    local uid = row.unique_id
    if uid ~= nil and tostring(uid) ~= '' then return tostring(uid) end
    if row.id ~= nil then return Dispatch.normalizeCallId(row.id) end
    return nil
end

function D.clearNotification(uniqueId, jobs)
    if type(uniqueId) ~= 'string' or uniqueId == '' or #uniqueId > MAX_ID_LEN or uniqueId:match('^%s*%d+%s*$') then
        CP.warn(TAG, 'clearNotification only takes a non-numeric string id (got %s %s)', type(uniqueId),
            tostring(uniqueId))
        return false
    end
    local list = {}
    if type(jobs) == 'table' then
        for i = 1, #jobs do
            if type(jobs[i]) == 'string' and jobs[i] ~= '' then list[#list + 1] = jobs[i] end
        end
    end
    if #list == 0 then list = { 'police' } end
    if not D.available() then return false end
    local ok, res = pcall(function() return exports[RESOURCE]:ClearNotification(uniqueId, list) end)
    if not ok then
        LogError('ClearNotification', 'exports[\'sc-dispatch\']:ClearNotification failed: %s', tostring(res))
        return false
    end
    CP.log(TAG, 'cleared %s for %s', uniqueId, table.concat(list, ','))
    return res ~= false
end

-- ============================================================================
--                             READ-ONLY SUMMARIES
-- ============================================================================
-- The Dispatch screen strip (active real calls, NPC calls left out) and the MDT commendations of a profile.
-- Read-only, never mixed with a cp_ table; in files mode the storage shim sends them to the real oxmysql.

local summaryCache = nil     -- { at, value } (value false = the lookup failed: the strip is hidden)

local function LikePrefix(prefix)
    return (prefix:gsub('[\\%%_]', '\\%0')) .. '%'
end

function D.realCallSummary()
    local now = os.time()
    local ttl = tonumber(Config.MissionCalls and Config.MissionCalls.realCallCache) or 15
    if summaryCache and now - summaryCache.at < ttl then return summaryCache.value or nil end
    local prefix = tostring(Config.Calls and Config.Calls.npcCallPrefix or 'npccall-')
    local value = false
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT priority, COUNT(*) AS n FROM mdt_dispatch
        WHERE active = 1 AND (unique_id IS NULL OR unique_id NOT LIKE ?) GROUP BY priority
    ]], { LikePrefix(prefix) })
    if not ok or type(rows) ~= 'table' then
        LogError('summary', 'mdt_dispatch real-call count failed (the Dispatch strip is hidden): %s', tostring(rows))
    else
        local total, p1 = 0, 0
        for _, r in ipairs(rows) do
            local n = math.floor(CP.U.num(r.n))
            total = total + n
            if tonumber(r.priority) == 1 then p1 = p1 + n end
        end
        value = { total = total, p1 = p1 }
    end
    summaryCache = { at = now, value = value }
    return value or nil
end

function D.mdtCommendations(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 64 then return nil end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT title, issued_by, UNIX_TIMESTAMP(created_at) AS ts FROM employee_incidents
        WHERE citizenid = ? AND type = 'commendation' ORDER BY created_at DESC LIMIT 10
    ]], { citizenid })
    if not ok or type(rows) ~= 'table' then
        LogError('commendations', 'employee_incidents commendations failed (the MDT tag is hidden): %s', tostring(rows))
        return nil
    end
    local out = {}
    for _, r in ipairs(rows) do
        out[#out + 1] = {
            title = type(r.title) == 'string' and CP.U.clip(r.title, 128) or '',
            by = type(r.issued_by) == 'string' and CP.U.clip(r.issued_by, 64) or '',
            at = math.floor(CP.U.num(r.ts)),
        }
    end
    return out
end

Dispatch._resetSummary = function() summaryCache = nil end

-- ============================================================================
--                                  LISTENERS
-- ============================================================================

local function ValidCallId(callId)
    local t = type(callId)
    if t == 'number' then return callId == callId and callId ~= math.huge and callId ~= -math.huge end
    if t == 'string' then return callId ~= '' and #callId <= MAX_ID_LEN end
    return false
end

local function ClipString(v, n)
    if type(v) ~= 'string' then return nil end
    return CP.U.clip(v, n)
end

-- A copy of the client payload with known fields only (it is client-supplied and untrusted).
local function SanitizeAlert(data)
    local coords
    local c = data.coords
    local ct = type(c)
    if ct == 'vector3' or ct == 'vector4' or ct == 'table' then
        local x, y, z = c.x, c.y, c.z
        if ct == 'table' then
            x, y, z = x or c[1], y or c[2], z or c[3]
        end
        if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
            coords = vector3(x + 0.0, y + 0.0, z + 0.0)
        end
    end
    return {
        coords = coords,
        street = ClipString(data.street, 128),
        zone = ClipString(data.zone, 32),
        sex = ClipString(data.sex, 16),
    }
end

-- ============================================================================
--                            SC-DISPATCH NET EVENTS
-- ============================================================================
-- A second, read-only handler next to sc-dispatch's own.

RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding)
    local src = source
    local n = tonumber(src)
    if not n or n <= 0 then return end
    if not ValidCallId(callId) or not Serving() then return end
    if not CP.Net.rateOk(n, 'sc_dispatch:toggle', 6, 1000) then
        CP.log(TAG, 'ToggleResponding from %d dropped (rate limit)', n)
        return
    end
    CP.log(TAG, 'ToggleResponding %d %s %s', n, tostring(callId), tostring(isResponding))
    Dispatch._emit('responding', n, callId, isResponding and true or false)
end)

local function AlertHandler(kind, rateKey)
    return function(data)
        local src = source
        local receivedAt = os.time()
        local n = tonumber(src)
        if not n or n <= 0 then return end
        -- sc-dispatch creates no call without data.coords either.
        if type(data) ~= 'table' or data.coords == nil or not Serving() then return end
        if not CP.Net.rateOk(n, rateKey, 5, 1000) then return end
        Dispatch._emit(kind, n, SanitizeAlert(data), receivedAt)
    end
end

RegisterNetEvent('sc-dispatch:server:ShotsFired', AlertHandler('shots', 'sc_dispatch:shots'))
RegisterNetEvent('sc-dispatch:server:PlayerDown', AlertHandler('down', 'sc_dispatch:down'))
RegisterNetEvent('sc-dispatch:server:PlayerDead', AlertHandler('dead', 'sc_dispatch:dead'))

-- ============================================================================
--                             SERVER-LOCAL EVENTS
-- ============================================================================

AddEventHandler('sc-dispatch:server:callClearedByOfficer', function(callId)
    if not ValidCallId(callId) or not Serving() then return end
    CP.log(TAG, 'callClearedByOfficer %s', tostring(callId))
    Dispatch._emit('cleared', callId)
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= RESOURCE or not Serving() then return end
    CP.log(TAG, 'sc-dispatch started: every dispatch call is inactive now')
    Dispatch._emit('restart')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE or not Serving() then return end
    CP.log(TAG, 'sc-dispatch stopped: every dispatch call is gone')
    Dispatch._emit('restart')
end)

CP.Integrations.register('dispatch', RESOURCE, D)
