-- CP.Training (client): /crimsonhelp (Config.Training.command, modules/access/training.lua) lands here with the tour
-- of the player's role. The tablet of that tour opens (or stays open) and the NUI gets { type = 'tour', tour }; the
-- NUI starts it once that tablet shows. Nothing runs between commands.

CP.Training = CP.Training or {}
local TAG = 'training'

-- The tablet each tour runs in: the Officer or Supervisor UI (opened as by the command), the criminal tablet, or the
-- Admin UI (the server opened it before it sent the tour).
local function OpenFor(tour)
    if tour == 'criminal' then
        return CP.CrimTab ~= nil and CP.CrimTab.open ~= nil and CP.CrimTab.open() == true
    end
    if tour == 'officer' or tour == 'supervisor' then
        if CP.Tablet.openUi() == tour then return true end
        return CP.Tablet.open(tour, { via = 'command' }) == true
    end
    return tour == 'admin'
end

RegisterNetEvent(CP.e('client:startTour'), function(tour)
    if type(tour) ~= 'string' or #tour > 16 then return end
    CreateThread(function()
        if not OpenFor(tour) then return end
        CP.Tablet.send({ type = 'tour', tour = tour })
        CP.log(TAG, 'the %s tour asked for', tour)
    end)
end)
