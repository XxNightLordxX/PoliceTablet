-- .luacheckrc · the Lua lint of tools/lint_lua.py (luacheck 1.1.2, `apt-get install lua-check`).
-- Run it through `python3 tools/lint_lua.py` from the repository root (the check_all step lint-lua); what each
-- warning means and how to clear one: docs/dev/TESTING.md "Lua lint".
--
-- The globals a script of the resource may read: Lua 5.4, the FiveM natives of tools/fivem_natives.txt (client
-- only and server only), the shared natives and Cfx runtime functions listed below, and the libraries the manifest
-- loads (ox_lib, oxmysql). Only CP, Config, RegisterMission and MySQL are written as globals (MySQL: the saves
-- folder engine replaces oxmysql's table with Config.Database.enabled = false).
-- luacheck does not look inside global tables: a misspelt field (CP.Moeny) is out of its reach.

-- the Cfx runtime adds a few functions to Lua's own os and io
stds.cfx = { read_globals = { os = { fields = { 'microtime', 'createdir' } }, io = { fields = { 'readdir' } } } }
std = 'lua54+cfx'
codes = true
max_line_length = false -- StyLua lays the lines out (docs/dev/STYLE.md)
-- block hooks, callbacks and methods share one signature, so an argument one of them does not read is normal
unused_args = false

local natives = {}
local f = io.open('tools/fivem_natives.txt')
if f then
    for line in f:lines() do
        local name = line:match('^[csb] ([%w_]+)$')
        if name then
            natives[#natives + 1] = name
        end
    end
    f:close()
end

-- Natives of apiset 'shared' (tools/fivem_natives.txt lists one-side natives only) and the Cfx runtime functions.
-- A shared native used for the first time goes here.
local shared = {
    'AddBlipForCoord', 'AddBlipForEntity', 'AddBlipForRadius', 'AddEventHandler', 'AddStateBagChangeHandler',
    'CancelEvent', 'Citizen', 'ClearPedTasks', 'ClearPedTasksImmediately', 'CreateObject', 'CreateObjectNoOffset',
    'CreatePed', 'CreatePedInsideVehicle', 'CreateThread', 'CreateVehicle', 'DeleteEntity', 'DeleteResourceKvp',
    'Entity', 'FreezeEntityPosition', 'GetAllVehicles', 'GetConvar', 'GetConvarInt', 'GetCurrentResourceName',
    'GetEntityCoords', 'GetEntityHeading', 'GetEntityHealth', 'GetEntityMaxHealth', 'GetEntityModel',
    'GetEntitySpeed', 'GetEntityType', 'GetGamePool', 'GetGameTimer', 'GetInvokingResource', 'GetPedArmour',
    'GetPedCauseOfDeath', 'GetPedInVehicleSeat', 'GetPedMaxHealth', 'GetPedSourceOfDeath', 'GetPlayerFromStateBagName',
    'GetPlayerName', 'GetPlayerPed', 'GetPlayerWeaponDefenseModifier', 'GetPlayers', 'GetResourceKvpString',
    'GetResourceMetadata', 'GetResourceState', 'GetSelectedPedWeapon', 'GetStateBagValue', 'GetVehicleBodyHealth',
    'GetVehicleEngineHealth', 'GetVehiclePedIsIn', 'GetVehiclePetrolTankHealth', 'GiveWeaponToPed', 'LoadResourceFile',
    'LocalPlayer', 'NetworkGetEntityFromNetworkId', 'NetworkGetEntityOwner', 'NetworkGetNetworkIdFromEntity',
    'PerformHttpRequest', 'Player', 'RegisterCommand', 'RegisterNUICallback', 'RegisterNetEvent', 'RemoveAllPedWeapons',
    'RemoveBlip', 'SendNUIMessage', 'SetBlipSprite', 'SetCurrentPedWeapon', 'SetEntityCoords', 'SetEntityHeading',
    'SetPedArmour', 'SetPedCanRagdoll', 'SetPedConfigFlag', 'SetPedIntoVehicle', 'SetResourceKvp', 'SetTimeout',
    'SetVehicleBodyHealth', 'SetVehicleDoorsLocked', 'SetVehicleNumberPlateText', 'TaskCombatPed', 'TaskDriveBy',
    'TaskEnterVehicle', 'TaskGoToCoordAnyMeans', 'TaskGoToEntity', 'TaskHandsUp', 'TaskLeaveVehicle', 'TaskPlayAnim',
    'TriggerClientEvent', 'TriggerEvent', 'TriggerLatentClientEvent', 'TriggerServerEvent', 'Wait',
    -- the Cfx Lua runtime and the libraries the manifest loads
    'cache', 'exports', 'joaat', 'json', 'lib', 'msgpack', 'promise', 'source', 'vec', 'vec2', 'vec3', 'vec4',
    'vector2', 'vector3', 'vector4', 'quat',
}

read_globals = {}
for _, n in ipairs(natives) do
    read_globals[#read_globals + 1] = n
end
for _, n in ipairs(shared) do
    read_globals[#read_globals + 1] = n
end
globals = { 'CP', 'Config', 'RegisterMission', 'MySQL' }

-- fxmanifest.lua is a list of manifest keys, each a global function call
files['Crimson-Police/fxmanifest.lua'] = {
    read_globals = {
        'fx_version', 'game', 'lua54', 'use_experimental_fxv2_oal', 'name', 'description', 'author', 'version',
        'dependencies', 'shared_scripts', 'server_scripts', 'client_scripts', 'ui_page', 'files', 'escrow_ignore',
    },
}

-- tests/: the harness and the specs replace natives and runtime functions on purpose (stubs), so those are
-- writable there, and `_` is a throwaway global in some specs. A spec's unused or shadowed locals, dead stores and
-- run-once loops are left alone (a spec reads more easily with them); undefined globals, unreachable code and
-- the rest still count.
local testGlobals = { '_', 'print', 'os', 'io' }
for _, n in ipairs(read_globals) do
    testGlobals[#testGlobals + 1] = n
end
for _, n in ipairs(globals) do
    testGlobals[#testGlobals + 1] = n
end
files['tests'] = {
    globals = testGlobals,
    ignore = { '211', '212', '213', '231', '241', '311', '411', '412', '421', '423', '431', '432', '512' },
}
-- the lint fixtures are wrong on purpose (tests/fixtures/lint: one file per tools/lint_fivem.py rule)
exclude_files = { '**/node_modules/**', 'tests/fixtures/lint/**' }
