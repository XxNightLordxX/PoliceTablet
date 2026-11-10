-- The ps-dispatch adapter of CP.Dispatch (modules/system/integrations/integrations): real calls from ps-dispatch.

-- The ps-dispatch adapter of CP.Dispatch (modules/system/integrations/integrations): real calls from ps-dispatch.
-- Read only: it reads exports['ps-dispatch']:GetDispatchCalls() and listens next to ps-dispatch's own handlers of
-- ps-dispatch:server:attach / detach / clearCall. It never creates, changes or clears a ps-dispatch call. Every
-- handler does nothing while another script (or none) serves dispatch (Config.Integrations.dispatch).
--
-- What ps-dispatch has (checked in its server/main.lua):
--   exports('GetDispatchCalls')      the live call list: { { id = number, priority = 0 | 1 | 2, units, ... } }
--   ps-dispatch:server:attach (id, PlayerData)    a unit marks Responding (from the officer's own client); it also
--                                                 takes the unit off any other call (sent on as a 'moved' un-mark)
--   ps-dispatch:server:detach (id, PlayerData)    the unit leaves the call
--   ps-dispatch:server:clearCall (id)             an officer closes the call (ps-dispatch checks who may)
-- What it has not: no suspension list (isSuspended is false), no MDT commendations, no call another resource may clear
-- (the mission alert backstop cannot clear a ps-dispatch call), and no shots-fired or person-down server events with
-- the shape Crimson-Police reads (those listeners never fire).

local D = {}
local Dispatch = CP.Dispatch
local TAG = 'ps_dispatch'
local RESOURCE = 'ps-dispatch'
local MAX_ID = 2 ^ 31
local CLEAR_CHECK_MS = 250       -- ps-dispatch's own clearCall handler removes the call first: look after this long

local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Serving() return CP.Integrations.is('dispatch', RESOURCE) end

function D.available() return GetResourceState(RESOURCE) == 'started' end

-- ps-dispatch's call list, or nil when it is not started or the export failed.
local function Calls()
    if not D.available() then return nil end
    local ok, list = pcall(function() return exports[RESOURCE]:GetDispatchCalls() end)
    if not ok then
        LogError('GetDispatchCalls', 'exports[\'ps-dispatch\']:GetDispatchCalls failed: %s', tostring(list))
        return nil
    end
    return type(list) == 'table' and list or nil
end

local function FindCall(key)
    for _, c in ipairs(Calls() or {}) do
        if type(c) == 'table' and c.id ~= nil and Dispatch.normalizeCallId(c.id) == key then return c end
    end
    return nil
end

function D.isSuspended() return false end

-- The call id as a string while that call is in ps-dispatch's list, else nil.
function D.lookupActiveCall(callId)
    local key = Dispatch.normalizeCallId(callId)
    if key == '' or not key:match('^%d+$') then return nil end
    return FindCall(key) and key or nil
end

function D.realCallSummary()
    local list = Calls()
    if not list then return nil end
    local total, p1 = 0, 0
    for _, c in ipairs(list) do
        if type(c) == 'table' then
            total = total + 1
            if (tonumber(c.priority) or 2) <= 1 then p1 = p1 + 1 end
        end
    end
    return { total = total, p1 = p1 }
end

-- A ps-dispatch call id: a whole number.
local function ValidId(id)
    local n = tonumber(id)
    return n ~= nil and n == math.floor(n) and n > 0 and n < MAX_ID
end

-- attached[src] = the call id this unit last attached to. ps-dispatch keeps a unit on one call: attaching to another
-- takes it off the old one without a detach event, so that one goes out as a 'moved' un-mark.
local attached = {}

local function OnAttach(isResponding)
    return function(id)
        local src = source
        local n = tonumber(src)
        if not n or n <= 0 or not ValidId(id) or not Serving() then return end
        if not CP.Net.rateOk(n, 'ps_dispatch:toggle', 6, 1000) then return end
        CP.log(TAG, '%s %d %s', isResponding and 'attach' or 'detach', n, tostring(id))
        local key, before = Dispatch.normalizeCallId(id), attached[n]
        if isResponding then
            if before and before ~= key then Dispatch._emit('responding', n, before, false, true) end
            attached[n] = key
        elseif before == key then
            attached[n] = nil
        end
        Dispatch._emit('responding', n, id, isResponding)
    end
end

RegisterNetEvent('ps-dispatch:server:attach', OnAttach(true))
RegisterNetEvent('ps-dispatch:server:detach', OnAttach(false))

AddEventHandler('playerDropped', function()
    local n = tonumber(source)
    if n then attached[n] = nil end
end)

-- A clear counts only once ps-dispatch itself has removed the call (a refused clear leaves it in the list).
RegisterNetEvent('ps-dispatch:server:clearCall', function(id)
    local src = source
    local n = tonumber(src)
    if not n or n <= 0 or not ValidId(id) or not Serving() then return end
    if not CP.Net.rateOk(n, 'ps_dispatch:clear', 6, 1000) then return end
    local key = Dispatch.normalizeCallId(id)
    SetTimeout(CLEAR_CHECK_MS, function()
        if FindCall(key) then return end
        CP.log(TAG, 'call %s cleared by %d', key, n)
        Dispatch._emit('cleared', id)
    end)
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= RESOURCE or not Serving() then return end
    attached = {}
    Dispatch._emit('restart')
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE or not Serving() then return end
    attached = {}
    Dispatch._emit('restart')
end)

CP.Integrations.register('dispatch', RESOURCE, D)
