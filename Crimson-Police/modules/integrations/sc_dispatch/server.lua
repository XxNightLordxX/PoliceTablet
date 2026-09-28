-- modules/integrations/sc_dispatch/server.lua · CP.Dispatch: the only code that talks to sc-dispatch.
--
-- Owns: the read-only listeners on sc-dispatch's events, the read-only mdt_dispatch lookup,
-- exports['sc-dispatch']:IsPlayerSuspended and exports['sc-dispatch']:ClearNotification.
-- Never uses sc-dispatch's call-creating export (missions never create dispatch calls) and never
-- triggers any sc-dispatch event. sc-dispatch's own handlers always run as well; nothing here blocks them.
--
-- Event registration (docs/INTEGRATIONS.md, sc-dispatch):
--   RegisterNetEvent  sc-dispatch:server:ToggleResponding (callId, isResponding)   client-originated
--   RegisterNetEvent  sc-dispatch:server:ShotsFired / PlayerDown / PlayerDead (data) client-originated
--   AddEventHandler   sc-dispatch:server:callClearedByOfficer (callId)   server-local ONLY, so no client
--                     can fire it to lift their own "On a call" block
--   AddEventHandler   onResourceStart / onResourceStop of 'sc-dispatch' (a restart deactivates every call)
-- Every net handler captures 'source' on its first line (and os.time() right after, before anything can
-- yield) and validates the payload; per-player rate limits go through CP.Net.rateOk.
--
-- Public API (docs/ARCHITECTURE.md §5.1)
--   CP.Dispatch.available() -> boolean                 sc-dispatch is started
--   CP.Dispatch.isSuspended(citizenid, jobName) -> boolean
--       exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobName); false when sc-dispatch is not
--       started or the export fails (sc-dispatch itself fails open). May yield (sc-dispatch awaits MySQL).
--   CP.Dispatch.lookupActiveCall(callId) -> uniqueId|nil
--       SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1
--       with (the integer form or 0, the normalised string), in pcall. Returns the canonical call id:
--       the row's unique_id, or its row id as a string when unique_id is empty. nil when the call is
--       unknown or inactive, when sc-dispatch is not started, or on a query error (logged). The result
--       can be an 'npccall-' id: the caller must still classify it. Yields (database).
--   CP.Dispatch.clearNotification(uniqueId, jobs) -> boolean
--       exports['sc-dispatch']:ClearNotification(uniqueId, jobs) in pcall. Only non-numeric string ids
--       are accepted (a number, or a digit-only string, would also match unrelated ems/fire rows by row
--       id). jobs defaults to { 'police' }. Call it from a handler or thread (sc-dispatch awaits MySQL).
--   CP.Dispatch.normalizeCallId(id) -> string          123, '123', 123.0 -> '123'; other strings unchanged;
--                                                      nil -> ''
--   Listeners (any number; each runs in its own thread):
--   CP.Dispatch.onResponding(fn(src, callId, isResponding))  callId as sent (number or string, validated),
--                                                             isResponding a boolean
--   CP.Dispatch.onCallCleared(fn(callId))                     number or string, as sc-dispatch sent it
--   CP.Dispatch.onDispatchRestart(fn())                       sc-dispatch started or stopped
--   CP.Dispatch.onShotsFired(fn(src, data, receivedAt))       data = { coords = vector3|nil, street, zone, sex }
--   CP.Dispatch.onPlayerDown(fn(src, data, receivedAt))       (client-supplied: use server-side ped coords
--   CP.Dispatch.onPlayerDead(fn(src, data, receivedAt))        for any distance check), receivedAt = os.time()

CP.Dispatch = CP.Dispatch or {}
local D = CP.Dispatch
local TAG = 'sc_dispatch'
local RESOURCE = 'sc-dispatch'
local MAX_ID_LEN = 64            -- mdt_dispatch.unique_id is VARCHAR(64)

local listeners = { responding = {}, cleared = {}, restart = {}, shots = {}, down = {}, dead = {} }
local errorLoggedAt = {}

local function logError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

function D.available()
    return GetResourceState(RESOURCE) == 'started'
end

function D.isSuspended(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if not D.available() then return false end
    if type(jobName) ~= 'string' or jobName == '' then jobName = nil end
    local ok, res = pcall(function() return exports[RESOURCE]:IsPlayerSuspended(citizenid, jobName) end)
    if not ok then
        logError('IsPlayerSuspended', "exports['sc-dispatch']:IsPlayerSuspended failed: %s", tostring(res))
        return false
    end
    return res == true
end

function D.normalizeCallId(id)
    local t = type(id)
    if t == 'number' then
        if id ~= id or id == math.huge or id == -math.huge then return tostring(id) end
        local i = math.tointeger(id)
        if i then return ('%d'):format(i) end
        return tostring(id)
    elseif t == 'string' then
        local s = CP.U.trim(id)
        if s:match('^%d+$') or s:match('^%d+%.0*$') then
            local i = math.tointeger(tonumber(s))
            if i then return ('%d'):format(i) end
        end
        return id
    elseif id == nil then
        return ''
    end
    return tostring(id)
end

function D.lookupActiveCall(callId)
    local key = D.normalizeCallId(callId)
    if key == '' or #key > MAX_ID_LEN then return nil end
    if not D.available() then return nil end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    -- Parameter order matches the placeholders: the integer form for 'id = ?' (0 for a non-numeric id,
    -- never the raw string, which MySQL would cast to 0), the string form for 'unique_id = ?'.
    local num = key:match('^%d+$') and math.tointeger(tonumber(key)) or 0
    local ok, rows = pcall(MySQL.query.await,
        'SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1',
        { num, key })
    if not ok then
        logError('lookup', 'mdt_dispatch lookup failed (sc-dispatch must have started once to add unique_id): %s', tostring(rows))
        return nil
    end
    local row = type(rows) == 'table' and rows[1] or nil
    if type(row) ~= 'table' then return nil end
    local uid = row.unique_id
    if uid ~= nil and tostring(uid) ~= '' then return tostring(uid) end
    if row.id ~= nil then return D.normalizeCallId(row.id) end
    return nil
end

function D.clearNotification(uniqueId, jobs)
    if type(uniqueId) ~= 'string' or uniqueId == '' or #uniqueId > MAX_ID_LEN or uniqueId:match('^%s*%d+%s*$') then
        CP.warn(TAG, 'clearNotification only takes a non-numeric string id (got %s %s)', type(uniqueId), tostring(uniqueId))
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
        logError('ClearNotification', "exports['sc-dispatch']:ClearNotification failed: %s", tostring(res))
        return false
    end
    CP.log(TAG, 'cleared %s for %s', uniqueId, table.concat(list, ','))
    return res ~= false
end

-- ── listeners ───────────────────────────────────────────────────────────────
local function addListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

local function emit(kind, ...)
    local list = listeners[kind]
    if #list == 0 then return end
    local args = table.pack(...)
    for i = 1, #list do
        local fn = list[i]
        CreateThread(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then CP.err(TAG, '%s listener failed: %s', kind, tostring(err)) end
        end)
    end
end

function D.onResponding(fn) addListener('responding', fn) end
function D.onCallCleared(fn) addListener('cleared', fn) end
function D.onDispatchRestart(fn) addListener('restart', fn) end
function D.onShotsFired(fn) addListener('shots', fn) end
function D.onPlayerDown(fn) addListener('down', fn) end
function D.onPlayerDead(fn) addListener('dead', fn) end

local function validCallId(callId)
    local t = type(callId)
    if t == 'number' then return callId == callId and callId ~= math.huge and callId ~= -math.huge end
    if t == 'string' then return callId ~= '' and #callId <= MAX_ID_LEN end
    return false
end

local function clipString(v, n)
    if type(v) ~= 'string' then return nil end
    return CP.U.clip(v, n)
end

-- A copy of the client payload with known fields only (it is client-supplied and untrusted).
local function sanitizeAlert(data)
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
        street = clipString(data.street, 128),
        zone = clipString(data.zone, 32),
        sex = clipString(data.sex, 16),
    }
end

-- ── sc-dispatch net events (a second, read-only handler next to sc-dispatch's own) ──
RegisterNetEvent('sc-dispatch:server:ToggleResponding', function(callId, isResponding)
    local src = source
    local n = tonumber(src)
    if not n or n <= 0 then return end
    if not validCallId(callId) then return end
    if not CP.Net.rateOk(n, 'sc_dispatch:toggle', 6, 1000) then
        CP.log(TAG, 'ToggleResponding from %d dropped (rate limit)', n)
        return
    end
    CP.log(TAG, 'ToggleResponding %d %s %s', n, tostring(callId), tostring(isResponding))
    emit('responding', n, callId, isResponding and true or false)
end)

local function alertHandler(kind, rateKey)
    return function(data)
        local src = source
        local receivedAt = os.time()
        local n = tonumber(src)
        if not n or n <= 0 then return end
        -- sc-dispatch creates no call without data.coords either.
        if type(data) ~= 'table' or data.coords == nil then return end
        if not CP.Net.rateOk(n, rateKey, 5, 1000) then return end
        emit(kind, n, sanitizeAlert(data), receivedAt)
    end
end

RegisterNetEvent('sc-dispatch:server:ShotsFired', alertHandler('shots', 'sc_dispatch:shots'))
RegisterNetEvent('sc-dispatch:server:PlayerDown', alertHandler('down', 'sc_dispatch:down'))
RegisterNetEvent('sc-dispatch:server:PlayerDead', alertHandler('dead', 'sc_dispatch:dead'))

-- ── server-local events ─────────────────────────────────────────────────────
AddEventHandler('sc-dispatch:server:callClearedByOfficer', function(callId)
    if not validCallId(callId) then return end
    CP.log(TAG, 'callClearedByOfficer %s', tostring(callId))
    emit('cleared', callId)
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= RESOURCE then return end
    CP.log(TAG, 'sc-dispatch started: every dispatch call is inactive now')
    emit('restart')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE then return end
    CP.log(TAG, 'sc-dispatch stopped: every dispatch call is gone')
    emit('restart')
end)
