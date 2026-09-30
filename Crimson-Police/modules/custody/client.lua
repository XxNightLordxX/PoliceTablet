-- CP.Custody (client): the police action flow (begin, progress bar, finish), the case-fail confirm, the service
-- vehicles this client drives for the server, and the road point the server asks for.

CP.Custody = CP.Custody or {}
local Custody = CP.Custody
local U = CP.U
local TAG = 'custody'

local ACTION_EVENT = 'crimson-police:server:custody'
local ROAD_CALLBACK = 'crimson-police:client:roadPoint'
local CONTROL_MS = 1500
local ROAD_TRIES = 12
local DRIVE_SPEED = 14.0           -- m/s for service vehicles
local DRIVE_STYLE = 786603         -- normal, obeys lights
local TOW_BONE = 'bodyshell'

-- Progress bar animations per action (ox_lib anim or scenario).
local ANIMS = {
    talk = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
    frisk = { dict = 'mp_arresting', clip = 'a_uncuff', flag = 49 },
    detain = { dict = 'mp_arrest_paired', clip = 'cop_p2_back_right', flag = 49 },
    searchPerson = { dict = 'mp_arresting', clip = 'a_uncuff', flag = 49 },
    lookInside = { scenario = 'PROP_HUMAN_BUM_BIN' },
    runPlate = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
    inspect = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
    searchVehicle = { scenario = 'PROP_HUMAN_BUM_BIN' },
    cite = { scenario = 'CODE_HUMAN_MEDIC_TIME_OF_DEATH' },
    explain = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
    impound = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
}
-- Actions done from a vehicle seat (the bar does not stop the car).
local IN_CAR = { runPlateFromVehicle = true }

local busy = nil
local drives = {}          -- [serviceId] = { op, token }

local function Cfg() return Config.Custody or {} end

local function InForeignArena()
    local v = LocalPlayer and LocalPlayer.state and LocalPlayer.state.crimsonArena
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function CurrentRun()
    local run = CP.Runs and CP.Runs.current and CP.Runs.current()
    if run and run.state == 'in_progress' then return run end
    return nil
end

local function TimeOf(action)
    if action == 'arrest' then return 0 end
    local key = action == 'runPlateFromVehicle' and 'runPlate' or action
    return tonumber((Cfg().times or {})[key]) or 0
end

local function EntityFromNet(netId, ms)
    local deadline = GetGameTimer() + (ms or 1000)
    while GetGameTimer() < deadline do
        if NetworkDoesNetworkIdExist(netId) then
            local e = NetworkGetEntityFromNetworkId(netId)
            if e and e ~= 0 and DoesEntityExist(e) then return e end
        end
        Wait(50)
    end
    return nil
end

local function Control(ent, ms)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return false end
    if NetworkHasControlOfEntity(ent) then return true end
    local deadline = GetGameTimer() + (ms or CONTROL_MS)
    NetworkRequestControlOfEntity(ent)
    while not NetworkHasControlOfEntity(ent) and GetGameTimer() < deadline do
        Wait(50)
        NetworkRequestControlOfEntity(ent)
    end
    return NetworkHasControlOfEntity(ent)
end

-- ============================================================================
--                               THE ACTION FLOW
-- ============================================================================
-- begin when the bar starts, finish when it ends; a cancelled bar sends nothing more and counts for nothing.

function Custody.busy() return busy ~= nil end

function Custody.perform(netId, action, extra)
    if busy then return false, 'err.busy' end
    local run = CurrentRun()
    if not run then return false, 'err.not_on_run' end
    if InForeignArena() then return false, 'err.in_arena' end
    local ped = PlayerPedId()
    if IsEntityDead(ped) then return false, 'err.refused' end
    if IsPedInAnyVehicle(ped, false) and not IN_CAR[action] and action ~= 'handover' then
        return false, 'err.refused'
    end
    busy = { netId = netId, action = action, runId = run.id }
    TriggerServerEvent(ACTION_EVENT, run.id, netId, action, 'begin', extra)
    local seconds = TimeOf(action)
    local ok = true
    if seconds > 0 and lib and lib.progressBar then
        ok = lib.progressBar({
            duration = math.floor(seconds * 1000),
            label = CP.L('custody.action.' .. action),
            useWhileDead = false,
            canCancel = true,
            disable = { move = not IN_CAR[action], car = not IN_CAR[action], combat = true },
            anim = ANIMS[action],
        }) == true
    end
    busy = nil
    if not ok or InForeignArena() then return false, 'err.cancelled' end
    local cur = CurrentRun()
    if not cur or cur.id ~= run.id then return false, 'err.not_on_run' end
    TriggerServerEvent(ACTION_EVENT, run.id, netId, action, 'finish', extra)
    CP.log(TAG, '%s on %s sent for run %s', action, tostring(netId), run.id)
    return true
end

-- Crimson-Arena placed the player: a bar in progress is cancelled (docs/CRIMSON_ARENA.md rule 8).
function Custody.cancel()
    if busy and lib and lib.cancelProgress then pcall(lib.cancelProgress) end
end

-- ============================================================================
--               THE CASE-FAIL CONFIRM (from an ox_target choice)
-- ============================================================================
-- The choice was not decided: the tablet opens and the Contact panel asks "this will fail the case".

RegisterNetEvent('crimson-police:client:contactConfirm', function(data)
    if type(data) ~= 'table' or InForeignArena() then return end
    CreateThread(function()
        if CP.Tablet and CP.Tablet.isOpen and not CP.Tablet.isOpen() and CP.Tablet.open then
            CP.Tablet.open('officer')
        end
        if CP.Tablet and CP.Tablet.push then CP.Tablet.push('contactConfirm', data) end
    end)
end)

-- ============================================================================
--                    CONTACT PANEL BUTTONS (client action)
-- ============================================================================

local PANEL_ACTIONS = {
    runPlateFromVehicle = true,
    seat = true,
    handover = true,
    escort = true,
    talk = true,
    frisk = true,
    detain = true,
    searchPerson = true,
    lookInside = true,
    runPlate = true,
    inspect = true,
    orderOut = true,
    searchVehicle = true,
    explain = true,
}

CreateThread(function()
    for _ = 1, 60 do
        if CP.Tablet and CP.Tablet.registerClientAction then break end
        Wait(500)
    end
    if not (CP.Tablet and CP.Tablet.registerClientAction) then return end
    CP.Tablet.registerClientAction('contactAction', function(payload)
        if type(payload) ~= 'table' or not PANEL_ACTIONS[payload.action] then return false, 'err.invalid_payload' end
        local netId = math.tointeger(tonumber(payload.netId) or 0) or 0
        if CP.Tablet.close then CP.Tablet.close() end
        Wait(250)
        return Custody.perform(netId, payload.action, nil)
    end)
end)

-- ============================================================================
--                                THE ROAD POINT
-- ============================================================================
-- The server asks the driving client for a road point min-max metres from `near`; it checks the answer itself.

local function RoadPoint(args)
    if type(args) ~= 'table' or not args.near then return nil end
    local near = vector3(args.near.x + 0.0, args.near.y + 0.0, args.near.z + 0.0)
    local lo, hi = tonumber(args.min) or 150.0, tonumber(args.max) or 250.0
    local me = GetEntityCoords(PlayerPedId())
    for i = 1, ROAD_TRIES do
        local a = (i / ROAD_TRIES) * math.pi * 2.0
        local d = lo + (hi - lo) * ((i % 3) / 2)
        local p = vector3(near.x + math.cos(a) * d, near.y + math.sin(a) * d, near.z)
        local ok, node, heading = GetClosestVehicleNodeWithHeading(p.x, p.y, p.z, 1, 3.0, 0)
        if ok and node then
            local dist = #(node - near)
            if dist >= lo and dist <= hi and #(node - me) > 40.0 then
                local okSide, side = GetPointOnRoadSide(node.x, node.y, node.z, 0)
                local at = okSide and side or node
                return { coords = { x = at.x, y = at.y, z = at.z }, heading = heading }
            end
        end
    end
    return nil
end

lib.callback.register(ROAD_CALLBACK, function(args)
    local ok, res = pcall(RoadPoint, args)
    if not ok then
        CP.warn(TAG, 'road point failed: %s', tostring(res))
        return nil
    end
    return res
end)

-- ============================================================================
--                      SERVICE VEHICLES (driving client)
-- ============================================================================
-- drive: to the parking point and stop; load (tow): attach the car to the flatbed; leave: drive off.

local function DriveTo(driver, veh, p)
    TaskVehicleDriveToCoordLongrange(driver, veh, p.x + 0.0, p.y + 0.0, p.z + 0.0, DRIVE_SPEED, DRIVE_STYLE, 8.0)
end

local function LoadCar(veh, car)
    if not Control(car) or not Control(veh) then return false end
    local bone = GetEntityBoneIndexByName(veh, TOW_BONE)
    AttachEntityToEntity(car, veh, bone ~= -1 and bone or 0, 0.0, -2.6, 1.05, 0.0, 0.0, 0.0, false, false, false, false,
        2, true)
    return true
end

RegisterNetEvent('crimson-police:client:serviceVehicle', function(data)
    if type(data) ~= 'table' or type(data.id) ~= 'number' then return end
    local run = CurrentRun()
    if not run or run.id ~= data.runId then return end
    local token = (drives[data.id] and drives[data.id].token or 0) + 1
    drives[data.id] = { op = data.op, token = token }
    CreateThread(function()
        local veh = data.veh and EntityFromNet(data.veh, 3000)
        local driver = data.driver and EntityFromNet(data.driver, 3000)
        if not veh or not driver then return end
        if not Control(driver) or not Control(veh) then return end
        if drives[data.id].token ~= token then return end
        SetBlockingOfNonTemporaryEvents(driver, true)
        if data.op == 'drive' and data.dest then
            DriveTo(driver, veh, data.dest)
        elseif data.op == 'load' and data.target then
            local car = EntityFromNet(data.target, 3000)
            if car then LoadCar(veh, car) end
        elseif data.op == 'leave' and data.away then
            DriveTo(driver, veh, data.away)
        end
    end)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    Custody.cancel()
    drives = {}
end)
