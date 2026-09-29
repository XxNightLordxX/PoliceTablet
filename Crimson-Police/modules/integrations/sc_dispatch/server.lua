-- CP.Dispatch: the only code that talks to sc-dispatch.

CP.Dispatch = CP.Dispatch or {}
local D = CP.Dispatch
local TAG = 'sc_dispatch'
local RESOURCE = 'sc-dispatch'
local MAX_ID_LEN = 64            -- mdt_dispatch.unique_id is VARCHAR(64)

local listeners = { responding = {}, cleared = {}, restart = {}, shots = {}, down = {}, dead = {} }
local errorLoggedAt = {}

local function LogError(key, fmt, ...)
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
        LogError('IsPlayerSuspended', 'exports[\'sc-dispatch\']:IsPlayerSuspended failed: %s', tostring(res))
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
    if row.id ~= nil then return D.normalizeCallId(row.id) end
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
--                                  LISTENERS
-- ============================================================================

local function AddListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

local function Emit(kind, ...)
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

function D.onResponding(fn) AddListener('responding', fn) end
function D.onCallCleared(fn) AddListener('cleared', fn) end
function D.onDispatchRestart(fn) AddListener('restart', fn) end
function D.onShotsFired(fn) AddListener('shots', fn) end
function D.onPlayerDown(fn) AddListener('down', fn) end
function D.onPlayerDead(fn) AddListener('dead', fn) end

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
    if not ValidCallId(callId) then return end
    if not CP.Net.rateOk(n, 'sc_dispatch:toggle', 6, 1000) then
        CP.log(TAG, 'ToggleResponding from %d dropped (rate limit)', n)
        return
    end
    CP.log(TAG, 'ToggleResponding %d %s %s', n, tostring(callId), tostring(isResponding))
    Emit('responding', n, callId, isResponding and true or false)
end)

local function AlertHandler(kind, rateKey)
    return function(data)
        local src = source
        local receivedAt = os.time()
        local n = tonumber(src)
        if not n or n <= 0 then return end
        -- sc-dispatch creates no call without data.coords either.
        if type(data) ~= 'table' or data.coords == nil then return end
        if not CP.Net.rateOk(n, rateKey, 5, 1000) then return end
        Emit(kind, n, SanitizeAlert(data), receivedAt)
    end
end

RegisterNetEvent('sc-dispatch:server:ShotsFired', AlertHandler('shots', 'sc_dispatch:shots'))
RegisterNetEvent('sc-dispatch:server:PlayerDown', AlertHandler('down', 'sc_dispatch:down'))
RegisterNetEvent('sc-dispatch:server:PlayerDead', AlertHandler('dead', 'sc_dispatch:dead'))

-- ============================================================================
--                             SERVER-LOCAL EVENTS
-- ============================================================================

AddEventHandler('sc-dispatch:server:callClearedByOfficer', function(callId)
    if not ValidCallId(callId) then return end
    CP.log(TAG, 'callClearedByOfficer %s', tostring(callId))
    Emit('cleared', callId)
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= RESOURCE then return end
    CP.log(TAG, 'sc-dispatch started: every dispatch call is inactive now')
    Emit('restart')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE then return end
    CP.log(TAG, 'sc-dispatch stopped: every dispatch call is gone')
    Emit('restart')
end)
