-- CP.ScPolice: second, read-only handlers for sc-police's net events; they never trigger, cancel or answer one.
-- The Impound one tells the engine who removed a run vehicle (/imp); the cuff, escort, jail, bobby-pin and seizure
-- ones pass facts to ScPolice.on listeners while a real-suspect case is open (CP.Opponents.active), else nothing.

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

-- ============================================================================
--                              LISTEN-ONLY FACTS
-- ============================================================================
-- Cuffs, escorts, jails, bobby pins and cash seizures, for CP.Opponents (real suspects). Each handler returns at once
-- while no listener of its kind exists or no case is open, so it reads no native and costs nothing; sc-police's own
-- handler runs as before either way.

local MAX_SRC = 65535
local RATE_MAX, RATE_MS = 6, 1000   -- per sender and kind (CP.Net.rateOk); more is dropped without a word

local listeners = {}   -- listeners[kind] = { fn, ... } in the order registered
local errorAt = {}     -- errorAt[kind] = os.time() of the last listener error logged (one a minute)

-- A server id 1..65535, or nil.
local function PlayerId(v)
    local n = tonumber(v)
    n = n and math.tointeger(n)
    if n and n >= 1 and n <= MAX_SRC then return n end
    return nil
end

-- True only while CP.Opponents (V4) says a case is open; false while that module is missing.
local function CaseOpen()
    local opp = CP.Opponents
    if not (opp and opp.active) then return false end
    local ok, on = pcall(opp.active)
    return ok and on == true
end

-- Every listener of the kind with read()'s arguments, each inside pcall: one that fails does not stop the next one.
-- Nothing runs when read() dropped the event (no sender).
local function Fire(kind, ...)
    if (...) == nil then return end
    local list = listeners[kind]
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            local now = os.time()
            if not errorAt[kind] or now - errorAt[kind] >= 60 then
                errorAt[kind] = now
                CP.err(TAG, 'a \'%s\' listener failed: %s', kind, tostring(err))
            end
        end
    end
end

-- event -> kind; read(src, ...) returns the listener's arguments (the sender first) or nil to drop the event.
local FACTS = {
    {
        event = 'police:server:CuffPlayer',
        kind = 'cuff',
        read = function(src, playerId, isSoftcuff)
            local target = PlayerId(playerId)
            if not target then return nil end
            return src, target, isSoftcuff == true
        end,
    },
    {
        event = 'police:server:UncuffPlayer',
        kind = 'uncuff',
        read = function(src, playerId)
            local target = PlayerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
    {
        -- the sender is the suspect who broke free; the argument is the officer who cuffed him
        event = 'police:server:CuffBreakAlert',
        kind = 'cuffBreak',
        read = function(src, officerId)
            local officer = PlayerId(officerId)
            if not officer then return nil end
            return src, officer
        end,
    },
    {
        event = 'police:server:EscortPlayer',
        kind = 'escort',
        read = function(src, playerId)
            local target = PlayerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
    {
        -- jailTime goes on as sent: the listener clamps it
        event = 'police:server:JailPlayer',
        kind = 'jail',
        read = function(src, targetId, jailTime)
            local target = PlayerId(targetId)
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
            local target = PlayerId(playerId)
            if not target then return nil end
            return src, target
        end,
    },
}

local KINDS = {}
for _, f in ipairs(FACTS) do KINDS[f.kind] = true end

-- Listen to one kind of fact: 'cuff' (officerSrc, targetSrc, isSoftcuff), 'uncuff' (officerSrc, targetSrc),
-- 'cuffBreak' (suspectSrc, officerSrc), 'escort' (officerSrc, targetSrc), 'jail' (officerSrc, targetSrc,
-- jailTimeRaw), 'bobbyPin' (pickerSrc, success) or 'seizeCash' (officerSrc, targetSrc). fn runs inside the event
-- and must not yield. Returns false for an unknown kind or a missing function.
function ScPolice.on(kind, fn)
    if not KINDS[kind] or type(fn) ~= 'function' then
        CP.err(TAG, 'ScPolice.on: unknown kind \'%s\' or no function', tostring(kind))
        return false
    end
    local list = listeners[kind] or {}
    for i = 1, #list do
        if list[i] == fn then return true end
    end
    list[#list + 1] = fn
    listeners[kind] = list
    return true
end

for _, f in ipairs(FACTS) do
    local kind, read, rateKey = f.kind, f.read, 'scp:' .. f.kind
    RegisterNetEvent(f.event, function(...)
        local src = source
        if not listeners[kind] or not CaseOpen() then return end
        src = PlayerId(src)
        if not src or not CP.Net.rateOk(src, rateKey, RATE_MAX, RATE_MS) then return end
        Fire(kind, read(src, ...))
    end)
end
