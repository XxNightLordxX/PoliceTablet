-- CP.Downed (client): the NPC pick-up of a downed participant and the EMS request from their own client
-- (docs/ARCHITECTURE.md §5.15, CRIMSON_ARENA rules 3 and 13).

CP.Downed = CP.Downed or {}
local D = CP.Downed
local TAG = 'downed'
local FADE_MS = 800
local FADE_WAIT_MS = 2500
local REVIVE_TIMEOUT_MS = 20000
local COLLISION_TIMEOUT_MS = 3000

local active = nil          -- { runId, cancelled } while a pick-up runs
local faded = false         -- the screen is faded out (or fading) by our pick-up
local overlaid = false      -- our fade overlay is on the NUI

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

-- The flags say what may still be on screen: set before the call that shows it, cleared after the one that
-- removes it, so a call that fails leaves the flag for the safety net.
local function Overlay(o)
    if o ~= nil then overlaid = true end
    if CP.Tablet and CP.Tablet.overlay then CP.Tablet.overlay(o) end
    if o == nil then overlaid = false end
end

local function Toast(kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars)) end
end

local function FadeOut()
    faded = true
    DoScreenFadeOut(FADE_MS)
end

local function FadeIn()
    if not IsScreenFadedIn() then DoScreenFadeIn(FADE_MS) end
    faded = false
end

-- The safety net: undo what this module still shows, whatever ended the pick-up (every exit already does it).
-- Only our own fade and overlay: a fade another resource started later is left alone.
local function Restore(why)
    if not faded and not overlaid then return false end
    CP.warn(TAG, 'the pick-up fade or overlay was still on (%s): removed', tostring(why))
    if faded then FadeIn() end
    if overlaid then Overlay(nil) end
    return true
end

local function WaitFor(check, timeoutMs, step)
    local deadline = GetGameTimer() + timeoutMs
    while GetGameTimer() < deadline do
        if check() then return true end
        Wait(step or 100)
    end
    return check()
end

-- server:pickupDone, once per pick-up
local function Report(runId, ok)
    if active then
        if active.reported then return end
        active.reported = true
    end
    TriggerServerEvent(CP.e('server:pickupDone'), runId, ok)
end

local function Abort(runId, why)
    CP.log(TAG, 'pick-up aborted (%s)', tostring(why))
    -- the server first: it must stop the revive even if what follows fails
    Report(runId, false)
    FadeIn()
    Overlay(nil)
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
    FadeOut()
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
    Report(runId, true)
end

function D.busy()
    return active ~= nil
end

-- Run end and the end of the downed follow-up (docs/ARCHITECTURE.md §5.15): our fade and overlay are undone
-- unless a pick-up is still running (it restores them itself when it ends).
function D.restore(why)
    if active then return false end
    return Restore(why)
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
            local okAbort, errAbort = pcall(Abort, runId, 'error')
            if not okAbort then CP.err(TAG, 'pick-up abort failed: %s', tostring(errAbort)) end
        end
        active = nil
        local okRestore, errRestore = pcall(Restore, 'pick-up ended')
        if not okRestore then
            CP.err(TAG, 'screen restore failed: %s', tostring(errRestore))
            if faded then pcall(DoScreenFadeIn, 0) end
        end
    end)
end)

RegisterNetEvent(CP.e('client:pickupCancel'), function(runId)
    if active and active.runId == runId then active.cancelled = true end
end)

-- The server's follow-up is over (done, cancelled, EMS handed over): a pick-up still running for it stops (it
-- fades back in itself), and anything of an earlier one still on screen is undone.
RegisterNetEvent(CP.e('client:downedEnded'), function(runId, why)
    if type(runId) ~= 'string' then return end
    if active then
        if active.runId == runId then active.cancelled = true end
        return
    end
    local ok, err = pcall(Restore, why)
    if not ok then CP.err(TAG, 'screen restore failed: %s', tostring(err)) end
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
    if active or faded then DoScreenFadeIn(0) end
end)
