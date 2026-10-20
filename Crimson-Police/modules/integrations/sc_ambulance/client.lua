-- CP.Ambulance (client): sc-ambulance's standard EMS request for a downed participant.

CP.Ambulance = CP.Ambulance or {}
local A = CP.Ambulance
local TAG = 'sc_ambulance'
local DEBOUNCE_MS = 5000

local lastSentAt = -1

-- A crimsonArena value that is not Crimson-Police's own (docs/CRIMSON_ARENA.md).
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

function A.sendEMSRequest()
    if GetResourceState('sc-ambulance') ~= 'started' then
        CP.warn(TAG, 'sc-ambulance is not started: no EMS request was sent')
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
    local street = StreetName()
    TriggerServerEvent('hospital:server:EMSDownAlert', street)
    CP.log(TAG, 'EMS request sent (%s)', street)
    return true
end
