-- CP.NpcCombat (client): softer NPC hits and no headshot multiplier on this officer while a run is live.

CP.NpcCombat = CP.NpcCombat or {}
local NpcCombat = CP.NpcCombat
local TAG = 'npccombat'

local WATCH_MS = 1000
local NO_CRITICAL_HITS = 2       -- CPED_CONFIG_FLAG_NoCriticalHits: the flag SetPedSuffersCriticalHits(ped, false) sets

local active = nil   -- { runId, ped, pedFlag, crit, ai, melee, defense, defenseSaved } while a run is live

local function IsYes(v) return v == true or v == 1 end

-- This player's own weapon defense modifier before the run (1.0 when the game cannot say).
local function ReadDefense()
    if type(GetPlayerWeaponDefenseModifier) ~= 'function' then return 1.0 end
    local ok, v = pcall(GetPlayerWeaponDefenseModifier, PlayerId())
    v = ok and tonumber(v) or nil
    if not v or v ~= v or v <= 0 then return 1.0 end
    return v + 0.0
end

-- The AI damage modifiers: set while a value is on, back to the game's own when it is turned off.
local function ApplyAi(a)
    local dmg, melee = NpcCombat.aiDamage(), NpcCombat.aiMeleeDamage()
    if dmg then
        SetAiWeaponDamageModifier(dmg)
        a.ai = true
    elseif a.ai then
        ResetAiWeaponDamageModifier()
        a.ai = false
    end
    if melee then
        SetAiMeleeWeaponDamageModifier(melee)
        a.melee = true
    elseif a.melee then
        ResetAiMeleeWeaponDamageModifier()
        a.melee = false
    end
end

-- The officer's own ped takes no extra headshot damage. A new ped (respawn, a model change) has its own flag read
-- first (another script may keep it on for the whole server), and that flag is what goes back at the end.
local function ApplyCritical(a)
    local ped = PlayerPedId()
    if a.ped ~= ped then
        a.ped = ped
        a.pedFlag = IsYes(GetPedConfigFlag(ped, NO_CRITICAL_HITS, true))
        a.crit = false
        a.defense = nil   -- applied again to the new ped's player
    end
    local want = NpcCombat.noCriticalHits()
    if want and not a.crit then
        SetPedSuffersCriticalHits(ped, false)
        a.crit = true
    elseif not want and a.crit then
        SetPedSuffersCriticalHits(ped, not a.pedFlag)
        a.crit = false
    end
end

local function ApplyDefense(a)
    local want = NpcCombat.officerDefense()
    if want then
        if a.defenseSaved == nil then a.defenseSaved = ReadDefense() end
        if a.defense ~= want then
            SetPlayerWeaponDefenseModifier(PlayerId(), want)
            a.defense = want
        end
    elseif a.defense ~= nil then
        SetPlayerWeaponDefenseModifier(PlayerId(), a.defenseSaved or 1.0)
        a.defense = nil
    end
end

local function Refresh(a)
    ApplyAi(a)
    ApplyCritical(a)
    ApplyDefense(a)
end

-- Start the run's damage settings (a run already started is stopped first). True when it started.
function NpcCombat.start(runId)
    if active then NpcCombat.stop() end
    local a = { runId = runId }
    active = a
    local ok, err = pcall(Refresh, a)
    if not ok then CP.warn(TAG, 'combat settings of run %s failed: %s', tostring(runId), tostring(err)) end
    CreateThread(function()
        while active == a do
            Wait(WATCH_MS)
            if active ~= a then break end
            -- a respawn or a new model gives the officer a new ped: its headshot flag goes on again
            if PlayerPedId() ~= a.ped then
                local okW, errW = pcall(Refresh, a)
                if not okW then CP.warn(TAG, 'combat settings failed: %s', tostring(errW)) end
            end
        end
    end)
    CP.log(TAG, 'run %s: NPC damage settings on', tostring(runId))
    return true
end

-- Put everything back as it was before the run. False when nothing was on.
function NpcCombat.stop()
    local a = active
    if not a then return false end
    active = nil
    if a.ai then ResetAiWeaponDamageModifier() end
    if a.melee then ResetAiMeleeWeaponDamageModifier() end
    if a.crit and a.ped and DoesEntityExist(a.ped) then SetPedSuffersCriticalHits(a.ped, not a.pedFlag) end
    if a.defense ~= nil then SetPlayerWeaponDefenseModifier(PlayerId(), a.defenseSaved or 1.0) end
    CP.log(TAG, 'run %s: NPC damage settings off', tostring(a.runId))
    return true
end

-- The run whose settings are on, or nil.
function NpcCombat.activeRun() return active and active.runId or nil end

-- A setting changed in game mid-run: the new values at once.
CP.Hooks.on('settings:changed', function()
    if not active then return end
    local ok, err = pcall(Refresh, active)
    if not ok then CP.warn(TAG, 'combat settings failed: %s', tostring(err)) end
end)

-- Crimson-Arena placed this player (docs/CRIMSON_ARENA.md rules 1 and 8): the server ends the run for them a moment
-- later; the arena's fights never get the headshot flag or the AI modifiers, not even for that moment.
AddStateBagChangeHandler('crimsonArena', ('player:%d'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    if type(value) == 'table' and value.active == true and value.source ~= 'crimson-police' then NpcCombat.stop() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    NpcCombat.stop()
end)
