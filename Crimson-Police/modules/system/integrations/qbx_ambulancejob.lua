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

function A.doctorCount()
    if not CP.Ext.started(RESOURCE) then return 0 end
    local ok, n = CP.Ext.call('qbx_core', 'GetDutyCountType', 'ems')
    if not ok then return 0 end
    return math.floor(tonumber(n) or 0)
end

function A.revive(n)
    if not CP.Ext.started(MEDICAL) then
        CP.errEvery(TAG, 'medical', 'qbx_medical is not started: a pick-up cannot revive anyone')
        return false
    end
    if not CP.Ext.call(MEDICAL, 'Revive', n) then return false end
    CP.log(TAG, 'revive sent to %d', n)
    return true
end

AddEventHandler('qbx_medical:server:playerRespawned', function(src)
    CP.Ambulance._respawned(RESOURCE, src, HOSPITAL_INDEX)
end)

CP.Integrations.register('ambulance', RESOURCE, A)
