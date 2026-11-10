-- The qbx_ambulancejob adapter of CP.Ambulance (modules/system/integrations/integrations): Qbox's own ambulance job
-- (with qbx_medical). Nothing here runs while another script (or none) serves the ambulance job
-- (Config.Integrations.ambulance).

-- What it uses (checked in qbx_ambulancejob's server/main.lua and server/hospital.lua):
--   doctorCount()  exports.qbx_core:GetDutyCountType('ems'), the count qbx_ambulancejob's own getNumDoctors returns
--   revive(src)    exports.qbx_medical:Revive(src), the revive qbx_ambulancejob's check-in and first aid use
--   emsRequest     the downed player's client sends hospital:server:ambulanceAlert (its own "civilian down" text)
--   respawn        AddEventHandler('qbx_medical:server:playerRespawned', src): server-local, so no client can fake it
-- Downed is still the Qbox isdead / inlaststand metadata (CP.Qbx.isDowned), which qbx_medical writes.

local A = {}
local TAG = 'qbx_ambulancejob'
local RESOURCE = 'qbx_ambulancejob'
local MEDICAL = 'qbx_medical'
local HOSPITAL_INDEX = 1             -- qbx_medical names no hospital: every respawn counts as one at a hospital

A.emsRequest = RESOURCE

local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Started(res) return GetResourceState(res) == 'started' end

function A.doctorCount()
    if not Started(RESOURCE) then return 0 end
    local ok, n = pcall(function() return exports.qbx_core:GetDutyCountType('ems') end)
    if not ok then
        LogError('GetDutyCountType', 'exports.qbx_core:GetDutyCountType failed: %s', tostring(n))
        return 0
    end
    return math.floor(tonumber(n) or 0)
end

function A.revive(n)
    if not Started(MEDICAL) then
        LogError('medical', 'qbx_medical is not started: a pick-up cannot revive anyone')
        return false
    end
    local ok, err = pcall(function() exports[MEDICAL]:Revive(n) end)
    if not ok then
        LogError('Revive', 'exports.qbx_medical:Revive failed: %s', tostring(err))
        return false
    end
    CP.log(TAG, 'revive sent to %d', n)
    return true
end

AddEventHandler('qbx_medical:server:playerRespawned', function(src)
    CP.Ambulance._respawned(RESOURCE, src, HOSPITAL_INDEX)
end)

CP.Integrations.register('ambulance', RESOURCE, A)
