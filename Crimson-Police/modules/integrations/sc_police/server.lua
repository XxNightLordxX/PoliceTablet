-- CP.ScPolice: a second, read-only handler for sc-police's police:server:Impound. It never triggers, cancels or
-- answers a police:* event; it only tells the engine who asked to remove a run vehicle (the /imp exploit).

CP.ScPolice = CP.ScPolice or {}
local ScPolice = CP.ScPolice
local TAG = 'sc_police'

local IMPOUND_EVENT = 'police:server:Impound'
local MAX_NETID = 0xFFFFFF

-- The live run that owns this net id as one of its vehicles, or nil.
local function RunVehicle(netId)
    if not (CP.Runs and CP.Runs.all) then return nil end
    local ok, list = pcall(CP.Runs.all)
    if not ok or type(list) ~= 'table' then return nil end
    for _, run in pairs(list) do
        local e = type(run) == 'table' and run.state ~= 'ended' and type(run.entities) == 'table'
            and run.entities[netId]
        if e and e.kind == 'vehicle' then return run, e end
    end
    return nil
end

-- The sender's server-side distance to the car when the event arrived (sc-police checks neither job nor distance).
local function DistanceTo(src, e)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not e or not e.entity or not DoesEntityExist(e.entity) then return nil end
    return CP.U.dist(GetEntityCoords(ped), GetEntityCoords(e.entity))
end

function ScPolice.onImpound(src, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    if not netId or netId <= 0 or netId > MAX_NETID then return false end
    local run, e = RunVehicle(netId)
    if not run then return false end
    local dist = DistanceTo(src, e)
    CP.log(TAG, 'police:server:Impound from %s on vehicle %d of run %s (%.1f m)', tostring(src), netId, run.id,
        dist or -1)
    if CP.Runs and CP.Runs.noteExternalRemoval then
        local ok, err = pcall(CP.Runs.noteExternalRemoval, netId, src, 'sc_impound', dist)
        if not ok then CP.err(TAG, 'noteExternalRemoval failed: %s', tostring(err)) end
    end
    return true
end

-- sc-police's own handler runs as well (net events call every handler): this one only reads.
RegisterNetEvent(IMPOUND_EVENT, function(_, _, _, _, _, _, netId)
    local src = source
    local ok, err = pcall(ScPolice.onImpound, src, netId)
    if not ok then CP.err(TAG, 'police:server:Impound from %s failed: %s', tostring(src), tostring(err)) end
end)
