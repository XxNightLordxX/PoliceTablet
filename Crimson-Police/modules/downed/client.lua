-- CP.Downed (client): the NPC pick-up of a downed participant and the EMS request from their own client
-- (docs/ARCHITECTURE.md §5.15, CRIMSON_ARENA rules 3 and 13).

CP.Downed = CP.Downed or {}
local D = CP.Downed
local TAG = 'downed'
local FADE_MS = 800
local FADE_WAIT_MS = 2500
local REVIVE_TIMEOUT_MS = 20000
local COLLISION_TIMEOUT_MS = 3000

local active = nil          -- { runId } while a pick-up runs

local function ToVec3(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = CP.U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function ForeignFlag()
    local st = LocalPlayer and LocalPlayer.state
    local v = st and st.crimsonArena
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

-- true / false from metadata isdead / inlaststand; nil when no character is loaded (CP.Qbx.getPlayerData
-- returns {} after a logout or during a character switch), which must never read as "revived".
local function MetadataDown()
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    local md = type(pd) == 'table' and pd.metadata or nil
    if type(md) ~= 'table' then return nil end
    return md.isdead == true or md.inlaststand == true
end

local function Revived()
    return MetadataDown() == false and not IsEntityDead(PlayerPedId())
end

local function Overlay(o)
    if CP.Tablet and CP.Tablet.overlay then CP.Tablet.overlay(o) end
end

local function Toast(kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars)) end
end

local function FadeIn()
    if not IsScreenFadedIn() then DoScreenFadeIn(FADE_MS) end
end

local function WaitFor(check, timeoutMs, step)
    local deadline = GetGameTimer() + timeoutMs
    while GetGameTimer() < deadline do
        if check() then return true end
        Wait(step or 100)
    end
    return check()
end

local function Abort(runId, why)
    CP.log(TAG, 'pick-up aborted (%s)', tostring(why))
    FadeIn()
    Overlay(nil)
    TriggerServerEvent(CP.e('server:pickupDone'), runId, false)
end

local function Detach(ped)
    if IsEntityAttached(ped) then DetachEntity(ped, true, false) end
    if IsPedInAnyVehicle(ped, false) then ClearPedTasksImmediately(ped) end
end

-- The server cancelled this pick-up (client:pickupCancel): in the arena, recovered, unload.
local function Cancelled()
    return active ~= nil and active.cancelled == true
end

local function RunPickup(runId, dest)
    if ForeignFlag() then return Abort(runId, 'arena') end
    DoScreenFadeOut(FADE_MS)
    WaitFor(IsScreenFadedOut, FADE_WAIT_MS, 50)
    Overlay({ kind = 'fade', text = CP.L('downed.picked_up') })
    local deadline = GetGameTimer() + REVIVE_TIMEOUT_MS
    local ok = false
    while GetGameTimer() < deadline do
        if ForeignFlag() then return Abort(runId, 'arena') end
        if Cancelled() then return Abort(runId, 'cancelled by the server') end
        if MetadataDown() == nil then return Abort(runId, 'no character loaded') end
        if Revived() then
            ok = true
            break
        end
        Wait(250)
    end
    if not ok then return Abort(runId, 'not revived') end
    if ForeignFlag() then return Abort(runId, 'arena') end
    if Cancelled() then return Abort(runId, 'cancelled by the server') end
    local ped = PlayerPedId()
    Detach(ped)
    RequestCollisionAtCoord(dest.x, dest.y, dest.z)
    SetEntityCoords(ped, dest.x, dest.y, dest.z, false, false, false, false)
    WaitFor(function() return HasCollisionLoadedAroundEntity(PlayerPedId()) end, COLLISION_TIMEOUT_MS, 100)
    FadeIn()
    Overlay(nil)
    Toast('info', 'downed.dropped_off')
    TriggerServerEvent(CP.e('server:pickupDone'), runId, true)
end

function D.busy()
    return active ~= nil
end

RegisterNetEvent(CP.e('client:pickup'), function(runId, dropOff)
    if type(runId) ~= 'string' or runId == '' then return end
    local dest = ToVec3(dropOff)
    if not dest then return end
    if active then return end
    active = { runId = runId }
    CreateThread(function()
        local ok, err = pcall(RunPickup, runId, dest)
        if not ok then
            CP.err(TAG, 'pick-up failed: %s', tostring(err))
            Abort(runId, 'error')
        end
        active = nil
    end)
end)

RegisterNetEvent(CP.e('client:pickupCancel'), function(runId)
    if active and active.runId == runId then active.cancelled = true end
end)

RegisterNetEvent(CP.e('client:requestEMS'), function(runId)
    if type(runId) ~= 'string' or runId == '' then return end
    if not (CP.Ambulance and CP.Ambulance.sendEMSRequest) then
        CP.err(TAG, 'modules/integrations/sc_ambulance is missing: no EMS request was sent')
        return
    end
    if CP.Ambulance.sendEMSRequest() then Toast('info', 'downed.ems_requested') end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    if active then DoScreenFadeIn(0) end
end)
