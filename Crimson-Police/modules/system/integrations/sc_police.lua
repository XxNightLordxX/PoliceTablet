-- The sc-police adapter of CP.Police (modules/system/integrations/integrations): second, read-only handlers for

-- The sc-police adapter of CP.Police (modules/system/integrations/integrations): second, read-only handlers for
-- sc-police's net events; they never trigger, cancel or answer one, and do nothing while another script (or none)
-- serves the police job (Config.Integrations.police). The Impound one tells the engine who removed a run vehicle
-- (/imp); the cuff, escort, jail, bobby-pin and seizure ones pass facts to CP.Police.on listeners while a
-- real-suspect case is open (CP.Opponents.active), else nothing. sc-police's own handlers run as before either way.

local P = CP.Police
local RESOURCE = 'sc-police'

-- event -> kind; read(src, ...) returns the listener's arguments (the sender first) or nil to drop the event.
local FACTS = {
    {
        event = 'police:server:CuffPlayer',
        kind = 'cuff',
        read = function(src, playerId, isSoftcuff)
            local target = P.playerId(playerId)
            if not target then return nil end
            return src, target, isSoftcuff == true
        end,
    },
    {
        event = 'police:server:UncuffPlayer',
        kind = 'uncuff',
        read = function(src, playerId)
            local target = P.playerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
    {
        -- the sender is the suspect who broke free; the argument is the officer who cuffed him
        event = 'police:server:CuffBreakAlert',
        kind = 'cuffBreak',
        read = function(src, officerId)
            local officer = P.playerId(officerId)
            if not officer then return nil end
            return src, officer
        end,
    },
    {
        event = 'police:server:EscortPlayer',
        kind = 'escort',
        read = function(src, playerId)
            local target = P.playerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
    {
        -- jailTime goes on as sent: the listener clamps it
        event = 'police:server:JailPlayer',
        kind = 'jail',
        read = function(src, targetId, jailTime)
            local target = P.playerId(targetId)
            if not target then return nil end
            return src, target, jailTime
        end,
    },
    {
        -- the sender is the picker; sc-police drops a result with no pending attempt, this handler still sees it
        event = 'police:server:BobbyPinResult',
        kind = 'bobbyPin',
        read = function(src, success) return src, success == true end,
    },
    {
        event = 'police:server:SeizeCash',
        kind = 'seizeCash',
        read = function(src, playerId)
            local target = P.playerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
}

-- police:server:Impound (plate, fullImpound, price, body, engine, fuel, netId): only the net id is read.
FACTS[#FACTS + 1] = {
    event = 'police:server:Impound',
    kind = 'impound',
    read = function(_, _, _, _, _, _, netId) return netId end,
}

P.addFacts(RESOURCE, FACTS)
CP.Integrations.register('police', RESOURCE, {})
