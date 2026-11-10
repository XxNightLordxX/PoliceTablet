-- The sc-ambulance adapter of CP.Ambulance (modules/system/integrations/integrations): the only server code that talks

-- The sc-ambulance adapter of CP.Ambulance (modules/system/integrations/integrations): the only server code that talks
-- to sc-ambulance. Its one second, read-only handler (hospital:server:RespawnAtHospital) passes the respawn to
-- CP.Ambulance listeners while a case with a real suspect is open; it never triggers, cancels or answers a hospital:*
-- event, and does nothing while another script (or none) serves the ambulance job (Config.Integrations.ambulance).
--
-- Owns exports['sc-ambulance']:GetDoctorCount() and the revive event. The ONLY revive used is
-- TriggerClientEvent('hospital:client:Revive', src): it resurrects in place, never bills, never touches
-- the inventory. Crimson-Police never triggers sc-ambulance's player-revive server event, its
-- revive-player / help-person / target-revive client events (each makes the officer's client send the
-- server revive, which bans non-EMS senders), and none of its billing or respawn events.
--
-- Adapter functions (CP.Ambulance checks the id, the connection and Crimson-Arena first)
--   doctorCount() -> integer
--       On-duty EMS. exports['sc-ambulance']:GetDoctorCount() in pcall; 0 when sc-ambulance is not
--       started (one error log until it starts again). The export is a counter clients update
--       themselves (it can be inflated or stale), so it is cross-checked against a live count of
--       on-duty 'ambulance' players from CP.Qbx.getOnlinePlayers(): the result is the lower of the
--       two (0 means "no EMS", so a downed participant is picked up).
--   revive(src) -> boolean
--       TriggerClientEvent('hospital:client:Revive', src); false when sc-ambulance is not started (no handler).
--   emsRequest = 'sc-ambulance'   the downed player's client sends hospital:server:EMSDownAlert

local A = {}
local TAG = 'sc_ambulance'
local RESOURCE = 'sc-ambulance'
local EMS_JOB = 'ambulance'          -- the only job name sc-ambulance counts as a doctor

A.emsRequest = RESOURCE

local notStartedLogged = false
local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Started()
    if GetResourceState(RESOURCE) == 'started' then
        notStartedLogged = false
        return true
    end
    if not notStartedLogged then
        notStartedLogged = true
        CP.err(TAG, 'sc-ambulance is not started: the EMS count is 0 and a pick-up cannot revive anyone')
    end
    return false
end

-- On-duty 'ambulance' players right now, or nil when the player list is not available.
local function LiveEmsCount()
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Qbx.getInfo) then return nil end
    local list = CP.Qbx.getOnlinePlayers()
    if type(list) ~= 'table' or #list == 0 then return nil end
    local n = 0
    for i = 1, #list do
        local info = CP.Qbx.getInfo(list[i])
        if info and info.job.name == EMS_JOB and info.job.onduty then n = n + 1 end
    end
    return n
end

function A.doctorCount()
    if not Started() then return 0 end
    local ok, count = pcall(function() return exports[RESOURCE]:GetDoctorCount() end)
    if not ok then
        LogError('GetDoctorCount', 'exports[\'sc-ambulance\']:GetDoctorCount failed: %s', tostring(count))
        return 0
    end
    local n = math.floor(tonumber(count) or 0)
    if n < 0 then n = 0 end
    if n > 0 then
        local live = LiveEmsCount()
        if live ~= nil and live < n then
            CP.log(TAG, 'GetDoctorCount says %d but %d ambulance players are on duty; using %d', n, live, live)
            n = live
        end
    end
    return n
end

function A.revive(n)
    if not Started() then return false end
    TriggerClientEvent('hospital:client:Revive', n)
    CP.log(TAG, 'revive sent to %d', n)
    return true
end

-- ============================================================================
--                     LISTEN-ONLY FACT (hospital respawns)
-- ============================================================================
-- For CP.Opponents (real suspects). The handler returns at once while no listener exists or no case is open, so it
-- reads no native and costs nothing; sc-ambulance's own handler (the bill, the bed) runs as before either way.

local RESPAWN_EVENT = 'hospital:server:RespawnAtHospital'

-- hospitalIndex: an index into sc-ambulance's Config.Locations.hospital (CP.Ambulance checks it).
RegisterNetEvent(RESPAWN_EVENT, function(hospitalIndex)
    local src = source
    CP.Ambulance._respawned(RESOURCE, src, hospitalIndex)
end)

CP.Integrations.register('ambulance', RESOURCE, A)
