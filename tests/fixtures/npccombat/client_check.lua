-- The run-scoped damage settings of an officer's game (modules/npccombat/client.lua, started and stopped by
-- modules/runs/client.lua) in their own Lua state (H.boot side = 'client'). Run by tests/npc_combat_spec.lua as a child
-- process; prints "RESULT <passed> <failed>".

package.path = package.path .. ';tests/?.lua'
local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- every other native: a no-op that answers nil
H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^%u%l') then
        local f = function() return nil end
        _G[k] = f
        return f
    end
    return nil
end)

local ME = { ped = 100, alive = { [100] = true, [101] = true, [102] = true } }
_G.PlayerId = function() return 0 end
_G.PlayerPedId = function() return ME.ped end
_G.GetPlayerServerId = function() return 1 end
_G.DoesEntityExist = function(e) return ME.alive[e] == true end
_G.GetEntityCoords = function() return vec3(0.0, 0.0, 0.0) end
_G.GetVehiclePedIsIn = function() return 0 end

local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, filter, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, filter = filter, fn = fn }
end
local function ArenaFlag(value)
    for _, h in ipairs(bagHandlers) do
        if h.key == 'crimsonArena' and h.filter == 'player:1' then h.fn('player:1', 'crimsonArena', value) end
    end
end

-- The natives with natives.json's argument types; W keeps what they set, as the game does.
local W = H.combatNatives()
local NC = Config.NpcCombat

H.load('modules/npccombat/client.lua')
H.load('modules/runs/client.lua')
H.ok(type(CP.NpcCombat.start) == 'function' and type(CP.NpcCombat.stop) == 'function', 'client API present')

local function Start(runId)
    H.fire(CP.e('client:start'), nil, runId, {
        missionId = 'gang_shootout',
        mission = { id = 'gang_shootout', label = 'Gang Shootout', objectives = {} },
        host = 1,
        participants = { { src = 1, status = 'active' } },
    })
end
local function End(runId) H.fire(CP.e('client:runEnded'), nil, runId, 'completed', 'completed', nil) end

-- before any run: the game's own values
H.eq(W.aiDamage, 1.0, 'no run: NPC bullets as GTA makes them')
H.eq(W.flags[100], nil, 'no run: the officer\'s headshot flag untouched')

-- ============================================================================
--                   A RUN: ON AT THE START, BACK AT THE END
-- ============================================================================

W.defense[0] = 0.9   -- another script's own defense modifier for this player (kept, and back after the run)
Start('run-1')
H.eq(CP.NpcCombat.activeRun(), 'run-1', 'client:start turns the settings on')
H.eq(W.aiDamage, 0.5, 'NPC bullets do half damage (SetAiWeaponDamageModifier 0.5)')
H.eq(W.aiMelee, 0.5, 'NPC melee too (SetAiMeleeWeaponDamageModifier 0.5)')
H.eq(W.flags[100][2], true, 'no headshot multiplier on the officer (SetPedSuffersCriticalHits false = flag 2)')
H.eq(W.defense[0], 0.9, 'officerDefense 1.0 = off: the player\'s defense modifier is left alone')
H.eq(W.typeErrors, 0, 'every native got the argument types the game reads')

-- a respawn (sc-ambulance) or a skin change gives the officer a new ped: the flag goes on it within a second
ME.ped = 101
H.advance(1100)
H.eq(W.flags[101] and W.flags[101][2], true, 'the new ped takes no headshot multiplier either')

-- a setting changed in game mid-run applies at once
NC.aiDamage = 1          -- an integer, as an owner may type it: the native still gets a float
NC.officerDefense = 0.6
CP.Hooks.fire('settings:changed')
H.eq(W.aiDamage, 1.0, 'aiDamage changed mid-run')
H.eq(math.type(W.aiDamage), 'float', 'and passed as a float')
H.eq(W.defense[0], 0.6, 'officerDefense on mid-run (SetPlayerWeaponDefenseModifier)')
NC.noCriticalHits = false
CP.Hooks.fire('settings:changed')
H.eq(W.flags[101][2], false, 'noCriticalHits turned off mid-run: the ped\'s own flag is back')
NC.noCriticalHits = true
CP.Hooks.fire('settings:changed')
H.eq(W.flags[101][2], true, 'and on again')
NC.aiDamage = 0.5
CP.Hooks.fire('settings:changed')
H.eq(W.aiDamage, 0.5, 'aiDamage back to 0.5')

-- another script that shares the one AI damage value of the game (Crimson-Contracts' guard scaling) resets it
-- mid-run: the run's value is on again within a second
ResetAiWeaponDamageModifier()
H.eq(W.aiDamage, 1.0, 'another script reset the shared AI damage value')
H.advance(1100)
H.eq(W.aiDamage, 0.5, 'the run\'s AI damage is on again within a second')
ResetAiMeleeWeaponDamageModifier()
H.advance(1100)
H.eq(W.aiMelee, 0.5, 'and the melee value too')

-- the cost: at most the two AI natives a second while the run lasts, nothing else
local function CountCalls(fromIndex)
    local byName, n = {}, 0
    for i = fromIndex + 1, #W.calls do
        local name = W.calls[i].name
        byName[name] = (byName[name] or 0) + 1
        n = n + 1
    end
    return n, byName
end
local before = #W.calls
H.advance(10000)
local n, byName = CountCalls(before)
H.ok(n <= 20 and (byName.SetAiWeaponDamageModifier or 0) <= 10 and (byName.SetAiMeleeWeaponDamageModifier or 0) <= 10,
    ('at most two natives a second while the run lasts (%d in 10 s)'):format(n))
H.ok((byName.SetAiWeaponDamageModifier or 0) >= 9, 'the bullet value goes on every second')

-- Config.NpcCombat.reassertAiDamage = false: the old behaviour (set at the start and after a respawn only), read on
-- every pass of the watcher
H.eq(NC.reassertAiDamage, true, 'reassertAiDamage ships true (config.lua)')
NC.reassertAiDamage = false
ResetAiWeaponDamageModifier()
before = #W.calls
H.advance(1100)
H.eq(W.aiDamage, 1.0, 'reassertAiDamage off: another script\'s reset is still there after 1.1 s')
H.advance(1900)
H.eq(W.aiDamage, 1.0, 'reassertAiDamage off: and after 3 s')
H.eq(CountCalls(before), 0, 'reassertAiDamage off: the watcher sets nothing while the ped stays the same')
NC.reassertAiDamage = true
H.advance(1100)
H.eq(W.aiDamage, 0.5, 'reassertAiDamage on again: the run\'s value is back within a second')
-- a config.lua from before the key had its name (PF2 called it holdAiDamage): its false still counts while
-- reassertAiDamage is missing
NC.reassertAiDamage = nil
NC.holdAiDamage = false
ResetAiWeaponDamageModifier()
H.advance(1100)
H.eq(W.aiDamage, 1.0, 'the old name holdAiDamage = false (new key missing): the reset stays')
NC.holdAiDamage = nil
H.advance(1100)
H.eq(W.aiDamage, 0.5, 'neither key: on (missing = true)')
NC.reassertAiDamage = true

End('run-1')
H.eq(CP.NpcCombat.activeRun(), nil, 'the run end turns them off')
H.eq(W.aiDamage, 1.0, 'NPC bullets back to normal (ResetAiWeaponDamageModifier)')
before = #W.calls
H.advance(5000)
H.eq(W.aiDamage, 1.0, 'after the run nothing sets it again')
H.eq(CountCalls(before), 0, 'after the run: no native at all (the watcher has ended)')
H.eq(W.aiMelee, 1.0, 'NPC melee back to normal')
H.eq(W.flags[101][2], false, 'the officer\'s own headshot flag is back')
H.eq(W.defense[0], 0.9, 'the defense modifier back to what it was before the run')
NC.officerDefense = 1.0

-- ============================================================================
--     A SERVER-WIDE NO-HEADSHOT SCRIPT IS NEVER UNDONE; STOPS AND RESTARTS
-- ============================================================================

W.flags[101][2] = true   -- another script keeps headshots off for everyone
Start('run-2')
H.eq(W.flags[101][2], true, 'on during the run')
End('run-2')
H.eq(W.flags[101][2], true, 'still on after the run: it was the other script\'s')
W.flags[101][2] = false

-- a new run while one is on (a test run, then a mission): the first is stopped first, nothing leaks
Start('run-3')
Start('run-4')
H.eq(CP.NpcCombat.activeRun(), 'run-4', 'the new run\'s settings')
H.eq(W.aiDamage, 0.5, 'still on')
End('run-3')
H.eq(CP.NpcCombat.activeRun(), 'run-4', 'a stale end of the earlier run changes nothing')
H.eq(W.aiDamage, 0.5, 'still on for run-4')

-- the resource stops mid-run: everything back
TriggerEvent('onResourceStop', 'Crimson-Police')
H.eq(CP.NpcCombat.activeRun(), nil, 'resource stop: off')
H.eq(W.aiDamage, 1.0, 'resource stop: NPC bullets back to normal')
H.eq(W.flags[101][2], false, 'resource stop: the headshot flag back')

-- Crimson-Arena places the player (a foreign crimsonArena value): off at once, before the server ends the run
Start('run-arena')
ArenaFlag({ active = true, source = 'crimson-police' })
H.eq(CP.NpcCombat.activeRun(), 'run-arena', 'our own crimsonArena flag (on a run) changes nothing')
ArenaFlag({ active = true, matchId = 'm1' })
H.eq(CP.NpcCombat.activeRun(), nil, 'placed in an arena match: the run\'s settings are off at once')
H.eq(W.aiDamage, 1.0, 'the arena: NPC bullets as GTA makes them')
H.eq(W.flags[101][2], false, 'the arena: headshots as the arena has them')
End('run-arena')

-- a ped that died with the respawn before the run ended: nothing is set on a ped that is gone
ME.ped = 102
Start('run-5')
ME.alive[102] = nil
End('run-5')
H.eq(W.aiDamage, 1.0, 'the AI modifiers are reset even when the ped is gone')
ME.alive[102] = true
ME.ped = 101

-- Config.NpcCombat.enabled = false: no native is called at all
NC.enabled = false
local calls = #W.calls
Start('run-6')
H.eq(#W.calls - calls, 1, 'off: only the headshot flag is read (GetPedConfigFlag), nothing is set')
H.eq(W.aiDamage, 1.0, 'off: NPC bullets as GTA makes them')
End('run-6')
NC.enabled = true
H.eq(W.typeErrors, 0, 'no native got a wrong argument type')

print(('RESULT %d %d'):format(H.passes, H.failures))
