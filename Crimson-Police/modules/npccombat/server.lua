-- CP.NpcCombat (server, step V8): the crimsonPoliceRun player bag of every officer whose game runs the run's NPC
-- damage settings, and the message that drops an officer's headshot and defense protection for the rest of his run.

CP.NpcCombat = CP.NpcCombat or {}
local NpcCombat = CP.NpcCombat
local TAG = 'npccombat'

local BAG_KEY = 'crimsonPoliceRun'
local MAX_HITS = 32               -- victims read from one weaponDamageEvent (as CP.Npc)
local MAX_NETID = 0xFFFFFF

local bagRun = {}    -- [src] = the run id this script set his crimsonPoliceRun bag for
local dropped = {}   -- [runId] = { [src] = true }: officers of that run whose protection is already off
local errorAt = 0

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n <= 0 then return nil end
    return n
end

local function ToInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    local n = math.tointeger(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

-- FXServer's BOOL natives answer 1 for yes (false for no), never true: truthiness only.
local function Exists(e)
    if type(e) ~= 'number' or e == 0 then return false end
    local found = DoesEntityExist(e)
    return found == true or found == 1
end

local function IsPlayerPed(e) return Exists(e) and IsPedAPlayer(e) and true or false end

local function OwnerOf(e)
    local ok, o = pcall(NetworkGetEntityOwner, e)
    return ok and ToSrc(o) or nil
end

local function IsParticipant(run, src)
    return CP.Runs ~= nil and CP.Runs.isParticipant ~= nil and CP.Runs.isParticipant(run, src) == true
end

local function RunOf(src)
    if not (CP.Runs and CP.Runs.getBySrc) then return nil end
    local run = CP.Runs.getBySrc(src)
    return type(run) == 'table' and run or nil
end

-- One console line a minute at most for a failing handler.
local function LogError(fmt, ...)
    local now = os.time()
    if now - errorAt < 60 then return end
    errorAt = now
    CP.err(TAG, fmt, ...)
end

-- ============================================================================
--             THE crimsonPoliceRun BAG (read by Crimson-Contracts)
-- ============================================================================
-- Replicated, exactly true while this officer's game runs the run's NPC damage settings (from client:start to the
-- end of his run). Crimson-Contracts' guard damage scaling leaves the shared AI damage value alone while it is true, so
-- the two scripts never set it against each other once a second. Written only when it changes.

local function WriteBag(src, value)
    local ok, err = pcall(function() Player(src).state:set(BAG_KEY, value, true) end)
    if not ok then CP.err(TAG, 'could not write the %s flag of %d: %s', BAG_KEY, src, tostring(err)) end
    return ok
end

local function ClearBag(src)
    if bagRun[src] == nil then return end
    bagRun[src] = nil
    WriteBag(src, nil)
end

-- CP.Runs sent client:start to src: on = his game starts CP.NpcCombat (the start data has no npcCombat = false).
function NpcCombat.runStarted(run, src, on)
    src = ToSrc(src)
    if type(run) ~= 'table' or run.id == nil or not src then return false end
    if dropped[run.id] then
        dropped[run.id][src] = nil
    end -- his game starts the settings afresh
    if not on then
        ClearBag(src)
        return false
    end
    if bagRun[src] == nil then WriteBag(src, true) end
    bagRun[src] = run.id
    return true
end

-- Whether this script set src's bag (and for which run), for the specs and the staff tools.
function NpcCombat.flagRun(src) return bagRun[ToSrc(src) or 0] end

-- ============================================================================
--                             THE PROTECTION DROP
-- ============================================================================

-- Turn off noCriticalHits and officerDefense on src's game for the rest of run (the AI damage values stay: they
-- soften the NPCs only). Once per run and officer; why is a word for the console. True when the message went out.
function NpcCombat.dropFor(run, src, why)
    src = ToSrc(src)
    if type(run) ~= 'table' or run.id == nil or not src or run.state == 'ended' then return false end
    if run.npcCombat == false or not IsParticipant(run, src) then return false end
    local done = dropped[run.id]
    if not done then
        done = {}
        dropped[run.id] = done
    end
    if done[src] then return false end
    done[src] = true
    TriggerClientEvent(CP.e('client:npcCombatDrop'), src, run.id)
    CP.log(TAG, 'run %s: %d loses headshot and defense protection for the rest of the run (%s)', tostring(run.id), src,
        tostring(why or 'drop'))
    return true
end

-- An NPC run whose officers keep the protection until a real player shoots one (playerHitDropsProtection): not a
-- test, no real suspect (V14's live runs, V22's volunteer runs drop it their own way), the settings started.
local function NpcRun(run)
    return run.state ~= 'ended' and run.test == nil and run.realSuspect == nil and run.npcCombat ~= false
end

-- The player a weapon damage packet is blamed on: its sender, or nobody when the damage came from an NPC the sender's
-- game moves (a ped, or a car an NPC drives), as CP.Npc's ShooterOf reads it.
local function Shooter(src, data)
    local parent = ToInt(tonumber(data.parentGlobalId), 1, MAX_NETID)
    if not parent then return src end
    local pe = NetworkGetEntityFromNetworkId(parent)
    if not Exists(pe) then return src end
    local t = GetEntityType(pe)
    local ped = t == 2 and GetPedInVehicleSeat(pe, -1) or (t == 1 and pe or 0)
    if Exists(ped) and not IsPedAPlayer(ped) and OwnerOf(pe) == src then return nil end
    return src
end

local function OnHit(src, data)
    local hits = data.hitGlobalIds
    if type(hits) ~= 'table' then hits = { data.hitGlobalId } end
    if #hits == 0 or Shooter(src, data) ~= src then return end
    local seen = {}
    for i = 1, math.min(#hits, MAX_HITS) do
        local netId = ToInt(tonumber(hits[i]), 1, MAX_NETID)
        if netId and not seen[netId] then
            seen[netId] = true
            local ped = NetworkGetEntityFromNetworkId(netId)
            -- a player's ped is always simulated by his own game
            local victim = IsPlayerPed(ped) and OwnerOf(ped) or nil
            local run = victim and victim ~= src and RunOf(victim) or nil
            if run and NpcRun(run) and not IsParticipant(run, src) then NpcCombat.dropFor(run, victim, 'player hit') end
        end
    end
end

-- Always registered, read-only (never cancels): with Config.NpcCombat.playerHitDropsProtection off (shipped, read on
-- every event so a Settings change needs no restart) it returns at once.
AddEventHandler('weaponDamageEvent', function(sender, data)
    if not (Config.NpcCombat and Config.NpcCombat.playerHitDropsProtection == true) then return end
    local src = ToSrc(sender) or ToSrc(source)
    if not src or type(data) ~= 'table' or WasEventCanceled() then return end
    local ok, err = pcall(OnHit, src, data)
    if not ok then LogError('weaponDamageEvent from %s failed: %s', tostring(src), tostring(err)) end
end)

-- ============================================================================
--                                     ENDS
-- ============================================================================

-- He left the run (any reason, a disconnect included): his bag goes, and a later start of the same run may drop again.
CP.Hooks.on('participant:left', function(run, src)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src then return end
    if bagRun[src] == run.id then ClearBag(src) end
    if dropped[run.id] then dropped[run.id][src] = nil end
end)

CP.Hooks.on('run:ended', function(run)
    if type(run) ~= 'table' or run.id == nil then return end
    for src, id in pairs(bagRun) do
        if id == run.id then ClearBag(src) end
    end
    dropped[run.id] = nil
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for src in pairs(bagRun) do ClearBag(src) end
    dropped = {}
end)
