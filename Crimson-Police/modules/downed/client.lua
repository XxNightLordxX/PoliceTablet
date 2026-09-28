-- modules/downed/client.lua · CP.Downed (client): the NPC pick-up of a downed participant and the EMS
-- request from their own client (docs/ARCHITECTURE.md §5.15, CRIMSON_ARENA rules 3 and 13).
--
-- Owns the handlers of client:pickup (runId, dropOff), client:pickupCancel (runId) and client:requestEMS
-- (runId) and sends the plain net event server:pickupDone (runId, ok).
--
-- Public API
--   CP.Downed.busy() -> boolean      a pick-up is running on this client
--
-- client:pickup: screen fade-out, overlay { kind = 'fade', text = CP.L('downed.picked_up') } ("Picked up by
-- an NPC unit"), wait for the server's revive (ped not dead AND metadata isdead / inlaststand false; 20 s
-- timeout), detach from any entity or vehicle, SetEntityCoords to the drop-off, wait for collision, fade in,
-- clear the overlay, server:pickupDone (runId, true). The Crimson-Arena value (LocalPlayer.state.crimsonArena
-- with a source other than 'crimson-police') is re-checked before the fade, while waiting for the revive and
-- right before SetEntityCoords, and so is a server cancel (client:pickupCancel); every abort path fades back
-- in, clears the overlay and sends server:pickupDone (runId, false). Nothing here revives anyone: the server sends sc-ambulance's own
-- hospital:client:Revive (through CP.Ambulance).
-- client:requestEMS: CP.Ambulance.sendEMSRequest() (sc-ambulance's standard EMS request, sent only after
-- the server removed our flag) and a toast.

CP.Downed = CP.Downed or {}
local D = CP.Downed
local TAG = 'downed'
local FADE_MS = 800
local FADE_WAIT_MS = 2500
local REVIVE_TIMEOUT_MS = 20000
local COLLISION_TIMEOUT_MS = 3000

local active = nil          -- { runId } while a pick-up runs

local function toVec3(v)
    local t = type(v)
    if t ~= 'vector3' and t ~= 'vector4' and t ~= 'table' then return nil end
    local x, y, z = CP.U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
    if x ~= x or y ~= y or z ~= z then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function foreignFlag()
    local st = LocalPlayer and LocalPlayer.state
    local v = st and st.crimsonArena
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

-- true / false from metadata isdead / inlaststand; nil when no character is loaded (CP.Qbx.getPlayerData
-- returns {} after a logout or during a character switch), which must never read as "revived".
local function metadataDown()
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    local md = type(pd) == 'table' and pd.metadata or nil
    if type(md) ~= 'table' then return nil end
    return md.isdead == true or md.inlaststand == true
end

local function revived()
    return metadataDown() == false and not IsEntityDead(PlayerPedId())
end

local function overlay(o)
    if CP.Tablet and CP.Tablet.overlay then CP.Tablet.overlay(o) end
end

local function toast(kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars)) end
end

local function fadeIn()
    if not IsScreenFadedIn() then DoScreenFadeIn(FADE_MS) end
end

local function waitFor(check, timeoutMs, step)
    local deadline = GetGameTimer() + timeoutMs
    while GetGameTimer() < deadline do
        if check() then return true end
        Wait(step or 100)
    end
    return check()
end

local function abort(runId, why)
    CP.log(TAG, 'pick-up aborted (%s)', tostring(why))
    fadeIn()
    overlay(nil)
    TriggerServerEvent(CP.e('server:pickupDone'), runId, false)
end

local function detach(ped)
    if IsEntityAttached(ped) then DetachEntity(ped, true, false) end
    if IsPedInAnyVehicle(ped, false) then ClearPedTasksImmediately(ped) end
end

-- The server cancelled this pick-up (client:pickupCancel): in the arena, recovered, unload.
local function cancelled()
    return active ~= nil and active.cancelled == true
end

local function runPickup(runId, dest)
    if foreignFlag() then return abort(runId, 'arena') end
    DoScreenFadeOut(FADE_MS)
    waitFor(IsScreenFadedOut, FADE_WAIT_MS, 50)
    overlay({ kind = 'fade', text = CP.L('downed.picked_up') })
    local deadline = GetGameTimer() + REVIVE_TIMEOUT_MS
    local ok = false
    while GetGameTimer() < deadline do
        if foreignFlag() then return abort(runId, 'arena') end
        if cancelled() then return abort(runId, 'cancelled by the server') end
        if metadataDown() == nil then return abort(runId, 'no character loaded') end
        if revived() then
            ok = true
            break
        end
        Wait(250)
    end
    if not ok then return abort(runId, 'not revived') end
    if foreignFlag() then return abort(runId, 'arena') end
    if cancelled() then return abort(runId, 'cancelled by the server') end
    local ped = PlayerPedId()
    detach(ped)
    RequestCollisionAtCoord(dest.x, dest.y, dest.z)
    SetEntityCoords(ped, dest.x, dest.y, dest.z, false, false, false, false)
    waitFor(function() return HasCollisionLoadedAroundEntity(PlayerPedId()) end, COLLISION_TIMEOUT_MS, 100)
    fadeIn()
    overlay(nil)
    toast('info', 'downed.dropped_off')
    TriggerServerEvent(CP.e('server:pickupDone'), runId, true)
end

function D.busy()
    return active ~= nil
end

RegisterNetEvent(CP.e('client:pickup'), function(runId, dropOff)
    if type(runId) ~= 'string' or runId == '' then return end
    local dest = toVec3(dropOff)
    if not dest then return end
    if active then return end
    active = { runId = runId }
    CreateThread(function()
        local ok, err = pcall(runPickup, runId, dest)
        if not ok then
            CP.err(TAG, 'pick-up failed: %s', tostring(err))
            abort(runId, 'error')
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
    if CP.Ambulance.sendEMSRequest() then toast('info', 'downed.ems_requested') end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    if active then DoScreenFadeIn(0) end
end)
