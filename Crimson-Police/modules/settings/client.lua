-- CP.Settings (client): the settings an admin changed in game, sent by the server at start and after every change, put
-- over this client's copy of config.lua so client code reads the same values as the server.

CP.Settings = CP.Settings or {}
local Settings = CP.Settings
local U = CP.U
local TAG = 'settings'

local READY_POLL_MS = 100

local DEFAULTS = U.deepcopy(Config or {})
local touched = {}       -- top-level Config keys rebuilt at least once
local received = false

local function Top(path) return tostring(path):match('^[^%.]+') end

-- The server's list { { path, value } | { path, none = true } } over config.lua, the same way the server does it.
local function Apply(list)
    local tops = {}
    for _, item in ipairs(list) do
        if type(item) == 'table' and type(item.path) == 'string' then tops[Top(item.path)] = true end
    end
    for top in pairs(touched) do tops[top] = true end
    for top in pairs(tops) do
        Config[top] = U.deepcopy(DEFAULTS[top])
        touched[top] = true
    end
    local n = 0
    for _, item in ipairs(list) do
        if type(item) == 'table' and type(item.path) == 'string' then
            if item.none then
                U.setPath(Config, item.path, nil)
            else
                U.setPath(Config, item.path, U.deepcopy(item.value))
            end
            n = n + 1
        end
    end
    return n
end

RegisterNetEvent(CP.e('client:settings'), function(list)
    if type(list) ~= 'table' then return end
    local n = Apply(list)
    received = true
    CP.log(TAG, '%d setting(s) changed in game applied', n)
    CP.Hooks.fire('settings:changed')
end)

-- Waits (up to timeoutMs) for the server's first list: start-up code that reads a setting once calls this first.
function Settings.ready(timeoutMs)
    local waited = 0
    while not received and waited < (timeoutMs or 0) do
        Wait(READY_POLL_MS)
        waited = waited + READY_POLL_MS
    end
    return received
end

function Settings.received() return received end

CreateThread(function()
    TriggerServerEvent(CP.e('server:settingsHello'))
end)

-- Test hooks (not part of the contract).
Settings._apply = Apply
Settings._defaults = function() return DEFAULTS end
