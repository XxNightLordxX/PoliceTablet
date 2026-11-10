-- CP.Ambulance (client): the downed participant's EMS request to the city's ambulance script, and Crimson-Police's
-- own revive when the city has none.

-- Public API (docs/dev/ARCHITECTURE.md §5.1)
--   CP.Ambulance.sendEMSRequest(script) -> boolean
--       The standard EMS request of the ambulance script the server named (CP.Ambulance.emsRequest), from the downed
--       player's OWN client (each script uses 'source' as the patient):
--         'sc-ambulance'      TriggerServerEvent('hospital:server:EMSDownAlert', streetName), the street name
--                             computed exactly as sc-ambulance does
--         'qbx_ambulancejob'  TriggerServerEvent('hospital:server:ambulanceAlert'), its own "civilian down" text
--       Send it only after the server has cleared the crimsonArena flag (modules/runs/downed does that before
--       client:requestEMS): sc-ambulance ignores flagged players and players who are not down. Guarded against
--       duplicates (at most one request per 5 s); false when the script is not started or unknown, the request was a
--       duplicate, or the player carries Crimson-Arena's crimsonArena value (Crimson-Arena handles its own players).
--       This is the one dispatch call Crimson-Police may cause.
--   client:revive (no ambulance script): resurrects the dead ped where it lies, at full health.

CP.Ambulance = CP.Ambulance or {}
local A = CP.Ambulance
local TAG = 'ambulance'
local DEBOUNCE_MS = 5000

local lastSentAt = -1

-- A crimsonArena value that is not Crimson-Police's own (docs/dev/INTEGRATIONS.md, Crimson-Arena).
local function InForeignArena()
    local st = LocalPlayer and LocalPlayer.state
    local v = st and st.crimsonArena
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function StreetName()
    local ped = PlayerPedId()
    local pos = GetEntityCoords(ped)
    local ok, name = pcall(function()
        local hash = GetStreetNameAtCoord(pos.x, pos.y, pos.z)
        return GetStreetNameFromHashKey(hash)
    end)
    if ok and type(name) == 'string' then return name end
    return ''
end

-- script -> the request it takes (each sends from this client).
local REQUESTS = {
    ['sc-ambulance'] = function()
        local street = StreetName()
        TriggerServerEvent('hospital:server:EMSDownAlert', street)
        return street
    end,
    ['qbx_ambulancejob'] = function()
        TriggerServerEvent('hospital:server:ambulanceAlert')
        return ''
    end,
}

function A.sendEMSRequest(script)
    local send = REQUESTS[script]
    if not send then
        CP.warn(TAG, 'no ambulance script takes EMS requests (%s): no EMS request was sent', tostring(script))
        return false
    end
    if GetResourceState(script) ~= 'started' then
        CP.warn(TAG, '%s is not started: no EMS request was sent', script)
        return false
    end
    if InForeignArena() then
        CP.log(TAG, 'EMS request skipped: the player is in Crimson-Arena')
        return false
    end
    local now = GetGameTimer()
    if lastSentAt >= 0 and now - lastSentAt < DEBOUNCE_MS then
        CP.log(TAG, 'EMS request skipped (already sent %d ms ago)', now - lastSentAt)
        return false
    end
    lastSentAt = now
    local street = send()
    CP.log(TAG, 'EMS request sent to %s (%s)', script, street)
    return true
end

-- The server's own revive at the end of a pick-up, only when no ambulance script serves (CP.Ambulance.revive).
RegisterNetEvent(CP.e('client:revive'), function()
    local ped = PlayerPedId()
    if not IsEntityDead(ped) and GetEntityHealth(ped) > 0 then return end
    local pos = GetEntityCoords(ped)
    NetworkResurrectLocalPlayer(pos.x, pos.y, pos.z, GetEntityHeading(ped), 0, false)
    ped = PlayerPedId()
    SetEntityHealth(ped, GetEntityMaxHealth(ped))
    ClearPedBloodDamage(ped)
    CP.log(TAG, 'revived by Crimson-Police (no ambulance script)')
end)
