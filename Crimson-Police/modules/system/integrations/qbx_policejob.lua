-- The qbx_policejob adapter of CP.Police (modules/system/integrations/integrations): second, read-only handlers for
-- Qbox's own police job; they never trigger, cancel or answer one, and do nothing while another script (or none)
-- serves the police job (Config.Integrations.police).

-- What qbx_policejob sends (checked in its server/main.lua; the same argument order as sc-police):
--   police:server:EscortPlayer (escortSrc), police:server:JailPlayer (targetSrc, time),
--   police:server:SeizeCash (targetSrc), police:server:Impound (plate, fullImpound, price, body, engine, fuel, netId)
-- What it does not send: cuffing is an ox_lib callback (police:server:CuffPlayer), not an event another resource can
-- listen to, and it has no cuff-break or bobby-pin events. So with qbx_policejob, live crimes and volunteer suspects
-- (which need the cuff) stay off (CP.Integrations.realSuspectsBlocked); impounds of run vehicles are still seen.

local P = CP.Police
local RESOURCE = 'qbx_policejob'

P.addFacts(RESOURCE, {
    {
        event = 'police:server:EscortPlayer',
        kind = 'escort',
        read = function(src, escortSrc)
            local target = P.playerId(escortSrc)
            if not target then return nil end
            return src, target
        end,
    },
    {
        event = 'police:server:JailPlayer',
        kind = 'jail',
        read = function(src, targetSrc, time)
            local target = P.playerId(targetSrc)
            if not target then return nil end
            return src, target, time
        end,
    },
    {
        event = 'police:server:SeizeCash',
        kind = 'seizeCash',
        read = function(src, targetSrc)
            local target = P.playerId(targetSrc)
            if not target then return nil end
            return src, target
        end,
    },
    {
        event = 'police:server:Impound',
        kind = 'impound',
        read = function(_, _, _, _, _, _, netId) return netId end,
    },
})
CP.Integrations.register('police', RESOURCE, {})
