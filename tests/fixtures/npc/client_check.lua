-- The client half of modules/npc in its own Lua state (H.boot side = 'client'). Run by tests/npc_spec.lua as a child
-- process; prints "RESULT <passed> <failed>".

package.path = package.path .. ';tests/?.lua'
local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })
local U = CP.U

-- A real joaat (Jenkins one-at-a-time, lower case): the harness one collides for equal lengths.
local function JoaatReal(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end
_G.joaat, _G.GetHashKey = JoaatReal, JoaatReal

-- ============================================================================
--                      CALL RECORDER AND FALLBACK NATIVES
-- ============================================================================

local calls = {}
local function Record(name, ...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
local function Rec(name) return function(...) Record(name, ...) end end
local fallback = {}
setmetatable(_G, {
    __index = function(t, k)
        if type(k) == 'string' and k:match('^%u%l') then
            fallback[k] = true
            local f = Rec(k)
            rawset(t, k, f)
            return f
        end
        return nil
    end,
})

local function CallsOf(name, pred)
    local out = {}
    for _, c in ipairs(calls) do
        if c.name == name and (not pred or pred(c.args)) then out[#out + 1] = c.args end
    end
    return out
end
local function Called(name, pred) return #CallsOf(name, pred) > 0 end
local function LastOf(name) local l = CallsOf(name); return l[#l] end
local function Clear() calls = {} end

-- ============================================================================
--                                  FAKE WORLD
-- ============================================================================

local W = { ents = {}, byNet = {}, bags = {}, groups = {}, options = {}, removed = nil, progressResult = true }
local ME = 1
local PLAYERS = { [1] = { idx = 0, ped = 100 }, [2] = { idx = 5, ped = 200 } }
W.ents[100] = { type = 1, player = true, coords = vec3(0.0, 50.0, 0.0) }
W.ents[200] = { type = 1, player = true, coords = vec3(0.0, 10.0, 0.0) }

local function AddPed(e, netId, x, y, z)
    W.ents[e] = {
        type = 1,
        netId = netId,
        coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0),
        health = 200,
        maxHealth = 200,
        armour = 0,
    }
    if netId then W.byNet[netId] = e end
    return e
end
local function Move(e, x, y, z) W.ents[e].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0) end

_G.PlayerId = function() return PLAYERS[ME].idx end
_G.PlayerPedId = function() return PLAYERS[ME].ped end
_G.GetPlayerServerId = function(idx)
    for s, p in pairs(PLAYERS) do if p.idx == idx then return s end end
    return 0
end
_G.GetPlayerFromServerId = function(s) local p = PLAYERS[s]; return p and p.idx or -1 end
_G.GetPlayerPed = function(idx)
    for _, p in pairs(PLAYERS) do if p.idx == idx then return p.ped end end
    return 0
end
_G.NetworkIsPlayerActive = function() return true end
_G.DoesEntityExist = function(e) local x = W.ents[e]; return x ~= nil and x.gone ~= true end
_G.IsEntityAPed = function(e) local x = W.ents[e]; return x ~= nil and x.type == 1 end
_G.IsEntityAVehicle = function(e) local x = W.ents[e]; return x ~= nil and x.type == 2 end
_G.IsPedAPlayer = function(e) local x = W.ents[e]; return x ~= nil and x.player == true end
_G.IsEntityDead = function(e) local x = W.ents[e]; return x ~= nil and x.dead == true end
_G.NetworkHasControlOfEntity = function(e) local x = W.ents[e]; return x ~= nil and x.control ~= false end
_G.NetworkGetEntityIsNetworked = function(e) return W.ents[e] ~= nil and W.ents[e].netId ~= nil end
_G.NetworkGetNetworkIdFromEntity = function(e) return W.ents[e] and W.ents[e].netId or 0 end
_G.NetworkDoesNetworkIdExist = function(n) return W.byNet[n] ~= nil end
_G.NetworkGetEntityFromNetworkId = function(n) return W.byNet[n] or 0 end
_G.GetEntityCoords = function(e) local x = W.ents[e]; return x and x.coords or vec3(0.0, 0.0, 0.0) end
_G.GetEntityHealth = function(e) local x = W.ents[e]; return x and x.health or 0 end
_G.GetEntityMaxHealth = function(e) local x = W.ents[e]; return x and x.maxHealth or 0 end
_G.GetPedArmour = function(e) local x = W.ents[e]; return x and x.armour or 0 end
_G.SetPedMaxHealth = function(e, h) Record('SetPedMaxHealth', e, h); W.ents[e].maxHealth = h end
_G.SetEntityHealth = function(e, h) Record('SetEntityHealth', e, h); W.ents[e].health = h end
_G.SetPedArmour = function(e, a) Record('SetPedArmour', e, a); W.ents[e].armour = a end
_G.HasEntityBeenDamagedByAnyPed = function() return false end
_G.HasPedGotWeapon = function(e, w)
    local x = W.ents[e]
    return x ~= nil and x.weapons ~= nil and x.weapons[w] == true
end
_G.GiveWeaponToPed = function(e, w, ...)
    Record('GiveWeaponToPed', e, w, ...)
    W.ents[e].weapons = W.ents[e].weapons or {}
    W.ents[e].weapons[w] = true
end
_G.RemoveAllPedWeapons = function(e, ...) Record('RemoveAllPedWeapons', e, ...); W.ents[e].weapons = {} end
_G.GetVehiclePedIsIn = function(e) local x = W.ents[e]; return x and x.vehicle or 0 end
_G.GetPedInVehicleSeat = function(v, seat) local x = W.ents[v]; return (x and seat == -1 and x.driver) or 0 end
_G.GetEntitySpeed = function(e) local x = W.ents[e]; return x and x.speed or 0.0 end
_G.IsPedInAnyVehicle = function(e) local x = W.ents[e]; return x ~= nil and (x.vehicle or 0) ~= 0 end
_G.IsPedInCombat = function(e) local x = W.ents[e]; return x ~= nil and x.inCombat == true end
_G.IsEntityPlayingAnim = function() return true end
_G.HasAnimDictLoaded = function() return true end
_G.DoesRelationshipGroupExist = function(h) return W.groups[h] == true end
_G.AddRelationshipGroup = function(name)
    Record('AddRelationshipGroup', name)
    W.groups[joaat(name)] = true
    return true, joaat(name)
end
_G.RemoveRelationshipGroup = function(h) Record('RemoveRelationshipGroup', h); W.groups[h] = nil end
_G.LocalPlayer = { state = {} }
_G.Entity = function(e)
    W.bags[e] = W.bags[e] or {}
    return { state = W.bags[e] }
end
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, filter, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, filter = filter, fn = fn }
end
local function HandlerFor(key)
    for _, h in ipairs(bagHandlers) do if h.key == key then return h end end
end

lib.progressBar = function(opts)
    Record('progressBar', opts)
    W.progress = opts
    if W.duringProgress then W.duringProgress() end
    return W.progressResult
end
lib.cancelProgress = function() Record('cancelProgress') end

H.exportsMock['ox_target'] = {
    addGlobalPed = function(opts) W.options[#W.options + 1] = opts end,
    removeGlobalPed = function(names) W.removed = names end,
}

W.run = { id = 'run-1', isHost = true, participants = { 1, 2 } }
CP.Runs = {
    current = function() return W.run end,
    control = function(e) return NetworkHasControlOfEntity(e) end,
}

H.load('modules/npc/client.lua')
local Npc = CP.Npc
local HOSTILE, NEUTRAL, PLAYER = joaat('CRIMSONPOLICE_HOSTILE'), joaat('CRIMSONPOLICE_NEUTRAL'), joaat('PLAYER')
H.ok(type(Npc.apply) == 'function' and type(Npc.task) == 'function' and type(Npc.nearestParticipant) == 'function',
    'client API present')

-- ============================================================================
--                RELATIONSHIP GROUPS (ARCHITECTURE §0.14, §6.1)
-- ============================================================================

H.ok(Called('AddRelationshipGroup', function(a) return a[1] == 'CRIMSONPOLICE_HOSTILE' end), 'hostile group created')
H.ok(Called('AddRelationshipGroup', function(a) return a[1] == 'CRIMSONPOLICE_NEUTRAL' end), 'neutral group created')
local rel = CallsOf('SetRelationshipBetweenGroups')
H.ok(#rel > 6, 'relations set')
local onlyOurs, playerTouched = true, false
for _, a in ipairs(rel) do
    if a[2] ~= HOSTILE and a[2] ~= NEUTRAL then onlyOurs = false end
    if a[2] == PLAYER then playerTouched = true end
end
H.ok(onlyOurs, 'relations are only set FROM our two groups')
H.ok(not playerTouched, 'the PLAYER group relations are never changed')
H.ok(Called('SetRelationshipBetweenGroups', function(a) return a[1] == 5 and a[2] == HOSTILE and a[3] == PLAYER end),
    'hostile hates PLAYER')
H.ok(Called('SetRelationshipBetweenGroups', function(a) return a[1] == 3 and a[2] == HOSTILE and a[3] == NEUTRAL end),
    'hostile neutral to neutral')
H.ok(Called('SetRelationshipBetweenGroups', function(a) return a[1] == 3 and a[2] == NEUTRAL and a[3] == PLAYER end),
    'neutral neutral to PLAYER')
H.ok(not Called('SetRelationshipBetweenGroups', function(a)
    return a[1] == 5 and a[2] == NEUTRAL
end), 'neutral hates nobody')
H.ok(Called('SetRelationshipBetweenGroups', function(a) return a[1] == 0 and a[2] == HOSTILE and a[3] == HOSTILE end),
    'hostiles are companions')
H.ok(not Called('NetworkSetFriendlyFireOption') and not Called('SetCanAttackFriendly') and not Called('SetPlayerTeam'),
    'no global toggles')

-- ============================================================================
--                         THE GLOBAL ox_target OPTION
-- ============================================================================

H.eq(#W.options, 1, 'one option set registered at start')
local opt = W.options[1] and W.options[1][1]
H.eq(opt and opt.name, 'crimson-police:cuff', 'option name')
H.eq(opt and opt.label, CP.L('npc.cuff'), 'option label from locale')
H.eq(opt and opt.icon, 'fas fa-handcuffs', 'option icon')
H.ok(opt and type(opt.canInteract) == 'function' and type(opt.onSelect) == 'function', 'option callbacks')

-- ============================================================================
--                                    APPLY
-- ============================================================================

local PISTOL = joaat('WEAPON_PISTOL')
local P1 = AddPed(5001, 801, 0, 0, 0)
W.bags[P1] = {
    cp = {
        run = 'run-1',
        obj = 1,
        role = 'hostile',
        state = 'hostile',
        armed = true,
        cfg = { weapon = 'WEAPON_PISTOL', accuracy = 140, health = 300, armour = 50, behaviour = 'push' },
    },
}
Clear()
H.eq(Npc.apply(P1, W.bags[P1].cp.cfg), true, 'apply hostile')
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P1 and a[2] == false end), 'no weapon drops')
H.ok(Called('SetPedMoney', function(a) return a[1] == P1 and a[2] == 0 end), 'no cash drops')
H.ok(Called('GiveWeaponToPed', function(a)
    return a[1] == P1 and a[2] == PISTOL and a[3] == 250 and a[4] == false and a[5] == true
end), 'weapon given when missing')
H.ok(Called('SetPedAccuracy', function(a) return a[1] == P1 and a[2] == 100 end), 'accuracy clamped to 100')
H.ok(Called('SetPedMaxHealth', function(a) return a[1] == P1 and a[2] == 300 end), 'max health')
H.ok(Called('SetEntityHealth', function(a) return a[1] == P1 and a[2] == 300 end), 'health on an untouched ped')
H.ok(Called('SetPedArmour', function(a) return a[1] == P1 and a[2] == 50 end), 'armour')
H.ok(Called('SetPedRelationshipGroupHash', function(a) return a[1] == P1 and a[2] == HOSTILE end), 'hostile group')
H.ok(Called('SetPedCombatMovement', function(a) return a[1] == P1 and a[2] == 2 end), 'push: advances')
H.ok(Called('SetPedCombatRange', function(a) return a[1] == P1 and a[2] == 0 end), 'push: near range')
H.ok(Called('SetPedCombatAbility', function(a) return a[1] == P1 and a[2] == 2 end), 'push: professional')
H.ok(Called('SetPedCombatAttributes', function(a) return a[1] == P1 and a[2] == 58 and a[3] == true end),
    'no flee from combat')
H.ok(Called('SetPedCombatAttributes', function(a) return a[1] == P1 and a[2] == 17 and a[3] == false end),
    'never always-flee')
H.ok(Called('SetPedFleeAttributes', function(a) return a[1] == P1 and a[2] == 0 and a[3] == false end),
    'flee attributes off')
H.ok(Called('SetBlockingOfNonTemporaryEvents', function(a) return a[1] == P1 and a[2] == true end),
    'blocking non-temporary events')
H.ok(Called('SetPedKeepTask', function(a) return a[1] == P1 and a[2] == true end), 'keep task')
H.ok(Called('SetPedCanRagdollFromPlayerImpact', function(a) return a[1] == P1 and a[2] == false end),
    'no ragdoll from player impact')
Clear()
W.ents[P1].health = 250
W.bags[P1].cp.cfg.health = 400
Npc.apply(P1, W.bags[P1].cp.cfg)
H.ok(not Called('GiveWeaponToPed'), 're-apply: weapon not given twice')
H.ok(Called('SetPedMaxHealth', function(a) return a[2] == 400 end), 're-apply: max health raised')
H.ok(not Called('SetEntityHealth'), 're-apply: a damaged ped keeps its health')
H.ok(not Called('SetPedArmour'), 're-apply: armour not restored')
-- hold behaviour keeps a defensive area
local P1b = AddPed(5011, 811, 5, 5, 0)
Clear()
Npc.apply(P1b, { behaviour = 'hold', weapon = 'WEAPON_SMG' })
H.ok(Called('SetPedSphereDefensiveArea', function(a) return a[1] == P1b end), 'hold: defensive area')
H.ok(Called('SetPedCombatMovement', function(a) return a[1] == P1b and a[2] == 1 end), 'hold: defensive movement')
-- hostage: neutral, unarmed
local P2 = AddPed(5002, 802, 3, 0, 0)
W.bags[P2] = {
    cp = {
        run = 'run-1',
        obj = 2,
        role = 'hostage',
        state = 'restrained',
        armed = false,
        cfg = { group = 'neutral', restrained = true },
    },
}
Clear()
H.eq(Npc.apply(P2, W.bags[P2].cp.cfg), true, 'apply hostage')
H.ok(Called('SetPedRelationshipGroupHash', function(a) return a[1] == P2 and a[2] == NEUTRAL end),
    'hostage in the neutral group')
H.ok(Called('RemoveAllPedWeapons', function(a) return a[1] == P2 end), 'hostage unarmed')
H.ok(not Called('GiveWeaponToPed'), 'hostage gets no weapon')
-- an idle armed ped with group 'neutral' (an unarmed suspect's cfg) stays neutral
local P2b = AddPed(5012, 812, 3, 3, 0)
W.bags[P2b] = { cp = { run = 'run-1', state = 'fleeing', armed = false, cfg = { group = 'neutral' } } }
Clear()
Npc.apply(P2b, W.bags[P2b].cp.cfg)
H.ok(Called('SetPedRelationshipGroupHash', function(a) return a[1] == P2b and a[2] == NEUTRAL end),
    'fleeing unarmed suspect neutral')
-- refusals
W.ents[P2].control = false
H.eq(Npc.apply(P2, {}), false, 'no control: apply refused')
W.ents[P2].control = nil
H.eq(Npc.apply(100, {}), false, 'players are never touched')
H.eq(Npc.apply(0, {}), false, 'no entity')

-- ============================================================================
--                              nearestParticipant
-- ============================================================================

local np, nd = Npc.nearestParticipant(vec3(0.0, 0.0, 0.0))
H.eq(np, 200, 'nearest participant ped')
H.near(nd, 10.0, 1e-6, 'nearest participant distance')

-- ============================================================================
--                                 TASK: combat
-- ============================================================================

Clear()
H.eq(Npc.task(P1, 'combat', { behaviour = 'balanced' }), true, 'combat task')
H.ok(Called('TaskCombatPed', function(a) return a[1] == P1 and a[2] == 200 end), 'combat on the nearest participant')
H.ok(Called('SetPedRelationshipGroupHash', function(a) return a[1] == P1 and a[2] == HOSTILE end),
    'combat: hostile group')
Clear()
Npc.task(P1, 'combat', {})
H.ok(not Called('TaskCombatPed'), 'same combat task ignored')
W.ents[P1].inCombat = true
Move(100, 0, 2, 0)
H.advance(3600)
H.ok(Called('TaskCombatPed', function(a) return a[1] == P1 and a[2] == 100 end),
    'retarget to a much closer participant')
H.fire('crimson-police:client:participants', 1, 'run-1',
    { { src = 1, status = 'active' }, { src = 2, status = 'left' } })
np = Npc.nearestParticipant(vec3(0.0, 10.0, 0.0))
H.eq(np, 100, 'a participant who left is not a target')
W.ents[100].dead = true
Clear()
H.advance(3600)
H.ok(Called('TaskStandStill', function(a) return a[1] == P1 end), 'no live participant: stands still')
H.ok(not Called('TaskGuardCurrentPosition'), 'never guards (a guarding hostile attacks any player, bystanders too)')
H.ok(not Called('TaskCombatPed', function(a) return a[1] == P1 end), 'no target: no combat')
W.ents[100].dead = nil
H.fire('crimson-police:client:participants', 1, 'run-1',
    { { src = 1, status = 'active' }, { src = 2, status = 'active' } })
Clear()
H.advance(3600)
H.ok(Called('TaskCombatPed', function(a) return a[1] == P1 end), 'back to combat when a participant is there')

-- ============================================================================
--                           TASK: flee along points
-- ============================================================================

local P3 = AddPed(5003, 803, 0.5, 0, 0)
local route = { vec3(0.0, 0.0, 0.0), vec3(10.0, 0.0, 0.0), vec3(20.0, 0.0, 0.0) }
Clear()
H.eq(Npc.task(P3, 'flee', { points = route }), true, 'flee task')
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3 and a[2] == 10.0 and a[5] == 3.0 end),
    'runs to the next point (already at the first)')
Clear()
Npc.task(P3, 'flee', {})
H.ok(not Called('TaskSmartFleePed'), 'a flee without points keeps the route')
Move(P3, 10, 0, 0)
W.ents[P3].speed = 5.0
H.advance(600)
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3 and a[2] == 20.0 end), 'next point when reached')
Move(P3, 20, 0, 0)
Clear()
H.advance(600)
H.ok(Called('TaskSmartFleePed', function(a) return a[1] == P3 and a[3] == 500.0 end),
    'end of the route: flee from participants')
-- serialized points ({ x, y, z } tables from the server bag) work too
local P3b = AddPed(5013, 813, 100, 100, 0)
Clear()
Npc.task(P3b, 'flee', { points = { { x = 110.0, y = 100.0, z = 0.0 } } })
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3b and a[2] == 110.0 end), 'table points accepted')
-- stuck on foot: re-issued
Clear()
W.ents[P3b].speed = 0.0
H.advance(3600)
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3b end), 'stuck: task re-issued')
-- an on-foot hairpin: 6 m before the turn point (inside 3x 2.5 m) it keeps running to it
local P3h = AddPed(5017, 817, 0, 800, 0)
Clear()
Npc.task(P3h, 'flee', { points = { vec3(0.0, 800.0, 0.0), vec3(10.0, 800.0, 0.0), vec3(0.0, 801.0, 0.0) } })
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3h and a[2] == 10.0 end), 'foot hairpin: started')
Move(P3h, 4, 800, 0)
W.ents[P3h].speed = 3.0
Clear()
H.advance(600)
H.ok(not Called('TaskFollowNavMeshToCoord', function(a)
    return a[1] == P3h and a[3] == 801.0
end), 'foot hairpin: no skip on the approach side')

-- ============================================================================
--                          TASK: driveRoute / driveTo
-- ============================================================================

local P4 = AddPed(5004, 804, 0, 0, 0)
W.ents[6001] = { type = 2, netId = 901, coords = vec3(0.0, 0.0, 0.0), driver = P4, speed = 15.0 }
W.byNet[901] = 6001
W.ents[P4].vehicle = 6001
local road = { vec3(0.0, 0.0, 0.0), vec3(100.0, 0.0, 0.0), vec3(200.0, 0.0, 0.0), vec3(300.0, 0.0, 0.0) }
Clear()
H.eq(Npc.task(P4, 'driveRoute', { points = road, speed = 60 / 3.6, style = 'normal', loop = true }), true,
    'driveRoute task')
local drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[1] == P4 and drive[2] == 6001 and drive[3] == 100.0, 'drives to the next waypoint')
H.near(drive and drive[6] or 0, 60 / 3.6, 1e-6, 'speed is m/s')
H.eq(drive and drive[7], 786475, 'normal lane-following style')
Move(6001, 95, 0, 0)
Clear()
H.advance(600)
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[3] == 200.0, 'waypoint by waypoint')
Move(6001, 230, 5, 0)
H.advance(600)
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[3] == 300.0, 'a waypoint passed close by (30 m) still counts')
Move(6001, 299, 0, 0)
H.advance(600)
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[3] == 0.0, 'a loop route wraps to the first waypoint')
-- a hairpin: the next point lies behind the vehicle, the current one far ahead: no skip
local P4h = AddPed(5014, 814, 0, 500, 0)
W.ents[6003] = { type = 2, netId = 903, coords = vec3(0.0, 500.0, 0.0), driver = P4h, speed = 15.0 }
W.byNet[903] = 6003
W.ents[P4h].vehicle = 6003
Clear()
Npc.task(P4h, 'driveRoute', { points = { vec3(0.0, 500.0, 0.0), vec3(100.0, 500.0, 0.0), vec3(0.0, 505.0, 0.0) } })
Move(6003, 5, 500, 0)
H.advance(600)
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[3] == 100.0, 'hairpin: keeps driving to the far waypoint')
-- still on the approach, inside 3x the arrive radius (20 m, 60 m): the turn point is not cut short
Move(6003, 50, 500, 0)
Clear()
H.advance(600)
H.ok(not Called('TaskVehicleDriveToCoordLongrange', function(a)
    return a[1] == P4h and a[4] == 505.0
end), 'hairpin: no skip on the approach side within 3x the arrive radius')
-- beyond the turn point along the leg it drives (overshot by 30 m): passed
Move(6003, 130, 500, 0)
Clear()
H.advance(600)
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[3] == 0.0 and drive[4] == 505.0, 'hairpin: overshooting the turn point counts as passed')
Clear()
Npc.task(P4h, 'driveRoute',
    { points = { vec3(0.0, 500.0, 0.0), vec3(100.0, 500.0, 0.0), vec3(0.0, 505.0, 0.0) }, startIndex = 3, force = true })
H.ok(LastOf('TaskVehicleDriveToCoordLongrange')[3] == 0.0 and LastOf('TaskVehicleDriveToCoordLongrange')[4] == 505.0,
    'startIndex overrides the nearest point')
local P5 = AddPed(5005, 805, 50, 50, 0)
W.ents[6002] = { type = 2, netId = 902, coords = vec3(50.0, 50.0, 0.0), driver = P5, speed = 10.0 }
W.byNet[902] = 6002
W.ents[P5].vehicle = 6002
Clear()
Npc.task(P5, 'driveTo', { coords = vec3(500.0, 50.0, 0.0), kmh = 90, style = 'careful' })
drive = LastOf('TaskVehicleDriveToCoordLongrange')
H.ok(drive and drive[1] == P5 and drive[3] == 500.0, 'driveTo')
H.near(drive and drive[6] or 0, 25.0, 1e-6, 'kmh accepted')
H.eq(drive and drive[7], 786603, 'careful style obeys lights')
H.eq(drive and drive[8], 8.0, 'default stop range')
Clear()
Npc.task(P5, 'driveTo', { coords = vec3(500.0, 50.0, 0.0), kmh = 90, style = 'careful' })
H.ok(not Called('TaskVehicleDriveToCoordLongrange'), 'the same driveTo right away is debounced')
H.advance(1600)
Npc.task(P5, 'driveTo', { coords = vec3(500.0, 50.0, 0.0), kmh = 90, style = 'careful' })
H.ok(Called('TaskVehicleDriveToCoordLongrange'), 'the same driveTo later is obeyed (unstick)')
Npc.task(P5, 'driveTo', { coords = vec3(500.0, 50.0, 0.0), style = 'reckless', force = true })
H.eq(LastOf('TaskVehicleDriveToCoordLongrange')[7], 787004, 'reckless style')
Npc.task(P5, 'driveTo',
    { coords = vec3(500.0, 50.0, 0.0), drivingStyle = 1074528293, style = 'reckless', force = true })
H.eq(LastOf('TaskVehicleDriveToCoordLongrange')[7], 1074528293, 'a numeric drivingStyle wins')
-- a driver fleeing with no points
Clear()
Npc.task(P5, 'flee', { vehicle = 6002, speed = 30.0, drivingStyle = 1074528293 })
H.ok(Called('TaskVehicleMissionPedTarget', function(a)
    return a[1] == P5 and a[2] == 6002 and a[4] == 8 and a[5] == 30.0 and a[6] == 1074528293
end), 'vehicle flee mission')
-- the route starts at the nearest point AHEAD (an out-and-back route passing the car is not skipped)
local P4o = AddPed(5015, 815, 0, 4, 0)
W.ents[6004] = { type = 2, netId = 904, coords = vec3(0.0, 4.0, 0.0), driver = P4o, speed = 15.0 }
W.byNet[904] = 6004
W.ents[P4o].vehicle = 6004
local outBack = {
    vec3(0.0, 0.0, 0.0),
    vec3(100.0, 0.0, 0.0),
    vec3(200.0, 0.0, 0.0),
    vec3(100.0, 5.0, 0.0),
    vec3(0.0, 5.0, 0.0),
}
Clear()
Npc.task(P4o, 'driveRoute', { points = outBack })
H.ok(LastOf('TaskVehicleDriveToCoordLongrange')[3] == 100.0 and LastOf('TaskVehicleDriveToCoordLongrange')[4] == 0.0,
    'out-and-back: starts outbound')
Move(6004, 190, 0, 0)
Clear()
Npc.task(P4o, 'driveRoute', { points = outBack, force = true })
H.ok(LastOf('TaskVehicleDriveToCoordLongrange')[4] == 5.0,
    'mid-route (new host): continues from the nearest point ahead')
-- leaving the car ends the managed drive (the block decides what the ped does next)
W.ents[P4o].vehicle = nil
W.ents[6004].driver = 0
Move(6004, 100, 5, 0)
Clear()
H.advance(1200)
H.ok(not Called('TaskVehicleDriveToCoordLongrange', function(a)
    return a[1] == P4o
end), 'out of the car: no more driving tasks')
H.ok(not Called('TaskSmartFleePed', function(a) return a[1] == P4o end), 'out of the car: no foot flee forced')

-- a cp state change ends the managed task
local P3c = AddPed(5016, 816, 0, 700, 0)
W.bags[P3c] = { cp = { run = 'run-1', state = 'fleeing', armed = false, cfg = {} } }
Clear()
Npc.task(P3c, 'flee', { points = { vec3(0.0, 710.0, 0.0), vec3(0.0, 720.0, 0.0) } })
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P3c and a[3] == 710.0 end), 'flee route started')
W.bags[P3c].cp.state = 'stopped'
Move(P3c, 0, 710, 0)
Clear()
H.advance(1200)
H.ok(not Called('TaskFollowNavMeshToCoord', function(a)
    return a[1] == P3c
end), 'state changed: route no longer stepped')
Clear()
Npc.task(P3c, 'flee', {})
H.ok(Called('TaskSmartFleePed', function(a) return a[1] == P3c end), 'a new flee after the state change is obeyed')

-- ============================================================================
--                    TASK: kneel / cuffed / follow / others
-- ============================================================================

local P6 = AddPed(5006, 806, 8, 8, 0)
Clear()
H.eq(Npc.task(P6, 'kneel', {}), true, 'kneel task')
H.ok(Called('RemoveAllPedWeapons', function(a) return a[1] == P6 end), 'kneel: disarmed')
H.ok(Called('SetPedRelationshipGroupHash', function(a) return a[1] == P6 and a[2] == NEUTRAL end),
    'kneel: neutral group')
H.ok(Called('TaskPlayAnim', function(a)
    return a[1] == P6 and a[2] == 'random@arrests' and a[3] == 'idle_2_hands_up'
end), 'hands up first')
H.ok(not Called('TaskPlayAnim', function(a) return a[1] == P6 and a[3] == 'idle_a' end), 'not kneeling yet')
H.advance(6000)
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P6 and a[2] == 'random@arrests@busted' and a[3] == 'enter' end),
    'then kneel down')
H.ok(Called('TaskPlayAnim', function(a)
    return a[1] == P6 and a[2] == 'random@arrests@busted' and a[3] == 'idle_a' and a[7] == 1
end), 'kneeling idle loop')
Clear()
Npc.task(P6, 'kneel', {})
H.ok(not Called('TaskPlayAnim'), 'kneeling again is ignored')
Clear()
H.eq(Npc.task(P6, 'cuffed', {}), true, 'cuffed task')
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P6 and a[3] == 'kneeling_arrest_get_up' end),
    'gets up from kneeling')
H.advance(3000)
H.ok(Called('FreezeEntityPosition', function(a) return a[1] == P6 and a[2] == true end), 'cuffed: frozen')
H.ok(Called('TaskPlayAnim', function(a)
    return a[1] == P6 and a[2] == 'mp_arresting' and a[3] == 'idle' and a[7] == 49
end), 'cuffed idle loop')
H.ok(Called('SetEnableHandcuffs', function(a) return a[1] == P6 and a[2] == true end), 'handcuffs on')
local P7 = AddPed(5007, 807, 12, 12, 0)
Clear()
Npc.task(P7, 'kneel', { instant = true })
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P7 and a[3] == 'idle_a' end), 'instant kneel')
H.ok(not Called('TaskPlayAnim', function(a)
    return a[1] == P7 and a[3] == 'idle_2_hands_up'
end), 'instant kneel skips the transition')
Clear()
Npc.task(P7, 'follow', { coords = vec3(30.0, 12.0, 0.0) })
H.ok(Called('FreezeEntityPosition', function(a) return a[1] == P7 and a[2] == false end), 'follow: unfrozen')
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P7 and a[3] == 'exit' end), 'stands up from kneeling')
H.ok(not Called('ClearPedTasks', function(a) return a[1] == P7 end), 'no snap before the stand-up animation')
H.advance(1300)
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P7 and a[2] == 30.0 and a[5] == 1.0 end),
    'walks to the coords')
Clear()
Npc.task(P7, 'follow', { coords = vec3(30.2, 12.0, 0.0) })
H.ok(not Called('TaskFollowNavMeshToCoord') and not Called('TaskPlayAnim'), 'same follow target ignored')
Clear()
Npc.task(P7, 'follow', { coords = vec3(40.0, 12.0, 0.0), anyMeans = true })
H.advance(100)
H.ok(Called('TaskGoToCoordAnyMeans', function(a) return a[1] == P7 and a[2] == 40.0 end), 'follow any means')
Clear()
Npc.task(P7, 'cower', {})
H.ok(Called('TaskCower', function(a) return a[1] == P7 end), 'cower')
Clear()
Npc.task(P7, 'wander', {})
H.ok(Called('TaskWanderStandard', function(a) return a[1] == P7 end), 'wander')
Clear()
Npc.task(P7, 'handsUp', {})
H.ok(Called('TaskHandsUp', function(a) return a[1] == P7 end), 'hands up')
Clear()
Npc.task(P7, 'enterVehicle', { vehicle = 902, seat = 0 })
H.ok(Called('TaskEnterVehicle', function(a) return a[1] == P7 and a[2] == 6002 and a[4] == 0 end),
    'enter vehicle by net id')
H.eq(Npc.task(P7, 'teleport', {}), false, 'unknown action refused')
W.ents[P7].control = false
H.eq(Npc.task(P7, 'cower', { force = true }), false, 'no control: task refused')
W.ents[P7].control = nil
H.eq(Npc.task(P7, 'driveTo', { coords = vec3(1.0, 1.0, 1.0) }), false, 'driveTo without a vehicle refused')

-- ============================================================================
--                       THE CP STATE BAG HANDLER (host)
-- ============================================================================

local cpH = HandlerFor('cp')
H.ok(cpH ~= nil and cpH.filter == nil, 'cp bag handler registered for every entity')
local function BagChange(e, netId, value)
    W.bags[e] = W.bags[e] or {}
    cpH.fn(('entity:%d'):format(netId), 'cp', value)
    W.bags[e].cp = value   -- the handler runs before the value is in the bag
    H.advance(50)
end
local P8 = AddPed(5008, 808, 1, 0, 0)
local v = {
    run = 'run-1',
    obj = 1,
    role = 'hostile',
    state = 'idle',
    armed = true,
    cfg = { weapon = 'WEAPON_SMG', behaviour = 'hold' },
    seq = 1,
}
Clear()
BagChange(P8, 808, v)
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P8 end), 'host applies cfg once it has control')
H.ok(not Called('TaskCombatPed', function(a) return a[1] == P8 end), 'idle: no task')
Clear()
v = U.deepcopy(v)
v.state = 'hostile'
v.seq = 2
BagChange(P8, 808, v)
H.ok(Called('TaskCombatPed', function(a) return a[1] == P8 end), 'hostile -> combat')
H.ok(not Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P8 end), 'cfg applied only once')
Clear()
v = U.deepcopy(v)
v.state = 'surrendered'
v.seq = 3
BagChange(P8, 808, v)
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P8 and a[3] == 'idle_2_hands_up' end),
    'surrendered -> hands up then kneel')
Clear()
v = U.deepcopy(v)
v.cuff = { label = 'Detain driver', duration = 3000, maxDistance = 3.0 }
v.seq = 4
BagChange(P8, 808, v)
H.ok(not Called('TaskPlayAnim', function(a) return a[1] == P8 end), 'a cuff flag does not re-task')
H.eq(#W.options, 2, 'a second label gets its own option')
H.eq(W.options[2] and W.options[2][1].name, 'crimson-police:cuff:2', 'second option name')
H.eq(W.options[2] and W.options[2][1].label, 'Detain driver', 'second option label')
H.advance(6000)
Clear()
v = U.deepcopy(v)
v.state = 'cuffed'
v.seq = 5
BagChange(P8, 808, v)
H.advance(3000)
H.ok(Called('FreezeEntityPosition', function(a) return a[1] == P8 and a[2] == true end), 'cuffed -> frozen')
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P8 and a[2] == 'mp_arresting' and a[3] == 'idle' end),
    'cuffed -> cuffed idle')
Clear()
v = U.deepcopy(v)
v.task = { action = 'cower', args = {} }
v.seq = 6
v.taskSeq = 6
BagChange(P8, 808, v)
H.ok(Called('TaskCower', function(a) return a[1] == P8 end), 'a server task is run')
-- a later write of the bag (cfg merge, enableCuff) keeps taskSeq: the task is not run again
Npc.task(P8, 'wander', {})
Clear()
v = U.deepcopy(v)
v.seq = 7
v.cfg.note = 'x'
BagChange(P8, 808, v)
H.ok(not Called('TaskCower', function(a) return a[1] == P8 end), 'same taskSeq: the task is not replayed')
Clear()
v = U.deepcopy(v)
v.task = { action = 'cower', args = {} }
v.seq = 8
v.taskSeq = 8
BagChange(P8, 808, v)
H.ok(Called('TaskCower', function(a) return a[1] == P8 end), 'a new task (new taskSeq) is run')
-- fleeing with route points from cfg
local P9 = AddPed(5009, 809, 0, 100, 0)
Clear()
BagChange(P9, 809, {
    run = 'run-1',
    obj = 1,
    state = 'fleeing',
    armed = false,
    cfg = { group = 'neutral', fleePoints = { { x = 0.0, y = 130.0, z = 0.0 } } },
    seq = 1,
})
H.ok(Called('TaskFollowNavMeshToCoord', function(a) return a[1] == P9 and a[3] == 130.0 end),
    'fleeing -> flee along cfg.fleePoints')
-- restrained hostage kneels at once
local P10 = AddPed(5010, 810, 0, 200, 0)
Clear()
BagChange(P10, 810, {
    run = 'run-1',
    obj = 2,
    role = 'hostage',
    state = 'restrained',
    armed = false,
    cfg = { group = 'neutral' },
    seq = 1,
})
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P10 and a[3] == 'idle_a' end), 'restrained -> kneeling at once')
-- another run's bag: no AI, but the ped is still made drop-safe (whoever owns it when it dies drops)
local P11 = AddPed(5021, 821, 0, 300, 0)
Clear()
BagChange(P11, 821,
    { run = 'run-2', state = 'hostile', armed = true, cfg = { weapon = 'WEAPON_PISTOL', accuracy = 40 }, seq = 1 })
H.ok(not Called('SetPedAccuracy', function(a) return a[1] == P11 end), 'another run: cfg not applied')
H.ok(not Called('SetPedRelationshipGroupHash', function(a) return a[1] == P11 end), 'another run: group untouched')
H.ok(not Called('TaskCombatPed', function(a) return a[1] == P11 end), 'another run: no AI')
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P11 and a[2] == false end),
    'another run: no weapon drops')
H.ok(Called('SetPedMoney', function(a) return a[1] == P11 and a[2] == 0 end), 'another run: no cash drops')
Clear()
BagChange(P11, 821, { run = 'run-2', state = 'fleeing', armed = true, cfg = {}, seq = 2 })
H.ok(not Called('SetPedDropsWeaponsWhenDead', function(a)
    return a[1] == P11
end), 'drop protection once per entity handle')
-- a bag that arrives before its ped streams in: marked as soon as the ped exists
Clear()
cpH.fn('entity:830', 'cp', { run = 'run-9', state = 'idle', armed = true, cfg = {}, seq = 1 })
H.advance(200)
local P11b = AddPed(5030, 830, 0, 320, 0)
H.advance(400)
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P11b and a[2] == false end),
    'late stream-in: drop-safe once it exists')
-- bags that are not Crimson-Police mission peds are left alone
local P11c = AddPed(5031, 831, 0, 330, 0)
Clear()
cpH.fn('entity:831', 'cp', { something = 'else' })
cpH.fn('entity:100', 'cp', { run = 'run-9', state = 'idle' })
H.advance(1600)
H.ok(not Called('SetPedDropsWeaponsWhenDead'), 'foreign cp values and player peds untouched')
-- not the host: nothing is tasked (the ped is still drop-safe: ownership can move to this client)
W.run.isHost = false
local P12 = AddPed(5022, 822, 0, 400, 0)
Clear()
BagChange(P12, 822, { run = 'run-1', state = 'hostile', armed = true, cfg = {}, seq = 1 })
H.ok(not Called('TaskCombatPed', function(a) return a[1] == P12 end), 'not the host: no AI')
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P12 and a[2] == false end),
    'not the host: drop-safe')
-- a non-participant (no run at all) still makes mission peds drop-safe
local savedRun = W.run
W.run = nil
local P12b = AddPed(5024, 824, 0, 420, 0)
Clear()
BagChange(P12b, 824, { run = 'run-1', state = 'hostile', armed = true, cfg = {}, seq = 1 })
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P12b and a[2] == false end),
    'non-participant client: drop-safe')
H.ok(not Called('SetPedAccuracy'), 'non-participant client: nothing else')
W.run = savedRun
H.advance(600)
-- becoming the host re-applies and re-tasks every known ped of the run
Clear()
W.run.isHost = true
H.fire('crimson-police:client:hostChanged', 1, 'run-1', 1)
H.advance(50)
H.ok(Called('TaskCombatPed', function(a) return a[1] == P12 end), 'new host: hostile re-tasked')
H.ok(Called('SetPedDropsWeaponsWhenDead', function(a) return a[1] == P12 end), 'new host: cfg re-applied')
H.ok(Called('TaskPlayAnim', function(a) return a[1] == P10 and a[3] == 'idle_a' end),
    'new host: pose without transitions')
H.ok(not Called('TaskPlayAnim', function(a)
    return a[1] == P10 and a[3] == 'idle_2_hands_up'
end), 'new host: no hands-up replay')

-- ============================================================================
--                            canInteract / onSelect
-- ============================================================================

local P13 = AddPed(5023, 823, 1, 0, 0)
W.bags[P13] = {
    cp = {
        run = 'run-1',
        obj = 1,
        state = 'surrendered',
        armed = false,
        cfg = {},
        cuff = { label = CP.L('npc.cuff'), duration = 5000, maxDistance = 3.0 },
    },
}
local def = W.options[1][1]
local second = W.options[2][1]
H.eq(def.canInteract(P13, 2.0), true, 'surrendered suspect of my run in reach: cuffable')
H.eq(def.canInteract(P13, 3.5), false, 'out of reach')
H.eq(second.canInteract(P13, 2.0), false, 'the other label\'s option stays hidden')
W.bags[P13].cp.state = 'hostile'
H.eq(def.canInteract(P13, 2.0), false, 'not surrendered')
W.bags[P13].cp.state = 'surrendered'
W.bags[P13].cp.run = 'run-2'
H.eq(def.canInteract(P13, 2.0), false, 'another run')
W.bags[P13].cp.run = 'run-1'
local saved = W.run
W.run = nil
H.eq(def.canInteract(P13, 2.0), false, 'non-participants never see it')
W.run = saved
W.bags[P13].cp.cuff = nil
H.eq(def.canInteract(P13, 2.0), false, 'not cuffable')
W.bags[P13].cp.cuff = { label = CP.L('npc.cuff'), duration = 5000, maxDistance = 3.0 }
W.ents[100].vehicle = 6001
H.eq(def.canInteract(P13, 2.0), false, 'not from a vehicle')
W.ents[100].vehicle = nil
LocalPlayer.state.crimsonArena = { active = true, matchId = 'm1' }
H.eq(def.canInteract(P13, 2.0), false, 'not while in Crimson-Arena')
LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-police' }
H.eq(def.canInteract(P13, 2.0), true, 'our own alert flag is fine')
LocalPlayer.state.crimsonArena = nil
H.eq(def.canInteract(P13, 'x'), false, 'bad distance')
-- the cuff flow
H.reset()
Clear()
def.onSelect({ entity = P13 })
H.ok(Called('TaskTurnPedToFaceEntity', function(a) return a[1] == 100 and a[2] == P13 end), 'turns to the suspect')
H.advance(700)
local pb = W.progress
H.ok(pb ~= nil, 'progress bar shown')
H.eq(pb and pb.duration, 5000, 'progress duration from the bag')
H.eq(pb and pb.label, CP.L('npc.cuff'), 'progress label')
H.eq(pb and pb.anim and pb.anim.dict, 'mp_arresting', 'mp_arresting animation')
H.eq(pb and pb.disable and pb.disable.move, true, 'movement disabled')
H.eq(pb and pb.canCancel, true, 'cancellable')
local sent = H.findEvents('crimson-police:server:npcCuff')
H.eq(#sent, 1, 'cuff reported to the server')
H.eq(sent[1] and sent[1].args[1], 'run-1', 'with the run id')
H.eq(sent[1] and sent[1].args[2], 823, 'with the net id')
-- cancelled bar: nothing sent
H.reset()
W.progress = nil
W.progressResult = false
def.onSelect({ entity = P13 })
H.advance(700)
H.eq(#H.findEvents('crimson-police:server:npcCuff'), 0, 'cancelled: nothing sent')
W.progressResult = true
-- placed in Crimson-Arena during the bar: cancelled, nothing sent
local arenaH = HandlerFor('crimsonArena')
H.ok(arenaH ~= nil and arenaH.filter == 'player:1', 'local crimsonArena handler')
H.reset()
local busyDuring
W.duringProgress = function()
    busyDuring = def.canInteract(P13, 2.0)
    arenaH.fn('player:1', 'crimsonArena', { active = true, matchId = 'm2' })
end
Clear()
def.onSelect({ entity = P13 })
H.advance(700)
W.duringProgress = nil
H.eq(busyDuring, false, 'no second cuff while one runs')
H.ok(Called('cancelProgress'), 'arena placement cancels the bar')
H.eq(#H.findEvents('crimson-police:server:npcCuff'), 0, 'arena placement: nothing sent')
-- a ped that is not surrendered does nothing
H.reset()
W.progress = nil
W.bags[P13].cp.state = 'cuffed'
def.onSelect({ entity = P13 })
H.advance(700)
H.eq(W.progress, nil, 'not surrendered: no progress bar')
H.eq(#H.findEvents('crimson-police:server:npcCuff'), 0, 'not surrendered: nothing sent')

-- ============================================================================
--                  ox_target RESTART, RUN END, RESOURCE STOP
-- ============================================================================

local before = #W.options
TriggerEvent('onClientResourceStart', 'ox_target')
H.eq(#W.options, before + 2, 'ox_target restart re-adds every option')
-- labels pile up over a session: past the 8 options a new label falls back to the default option
local P14 = AddPed(5024, 824, 1, 0, 0)
local function CuffBag(label, seq)
    return {
        run = 'run-1',
        obj = 1,
        state = 'surrendered',
        armed = false,
        cfg = {},
        seq = seq,
        cuff = { label = label, duration = 3000, maxDistance = 3.0 },
    }
end
local extra = { 'Arrest robber', 'Detain dealer', 'Cuff fugitive', 'Arrest thief', 'Detain courier', 'Cuff runner' }
for i, label in ipairs(extra) do BagChange(P14, 824, CuffBag(label, i)) end
local byName = {}
for _, set in ipairs(W.options) do byName[set[1].name] = set[1] end
H.ok(byName['crimson-police:cuff:8'] ~= nil and byName['crimson-police:cuff:9'] == nil, 'at most 8 options')
H.eq(def.canInteract(P14, 2.0), false, 'a label with its own option: the default one stays hidden')
H.eq(byName['crimson-police:cuff:8'].canInteract(P14, 2.0), true, 'a label with its own option: that one shows')
BagChange(P14, 824, CuffBag('Arrest smuggler', 7))
local shown = 0
for _, o in pairs(byName) do
    if o.canInteract(P14, 2.0) then shown = shown + 1 end
end
H.eq(shown, 1, 'a ninth label is still cuffable (one option shows)')
H.eq(def.canInteract(P14, 2.0), true, 'a ninth label uses the default option')
H.reset()
W.progress = nil
def.onSelect({ entity = P14 })
H.advance(700)
H.eq(W.progress and W.progress.label, 'Arrest smuggler', 'the progress bar keeps the ninth label')
H.eq(#H.findEvents('crimson-police:server:npcCuff'), 1, 'a ninth label: cuff sent')
-- a stale end of an earlier run keeps the AI of the current one
Npc.task(P6, 'cuffed', { instant = true, force = true })
Clear()
Npc.task(P6, 'cuffed', { instant = true })
H.ok(not Called('SetEnableHandcuffs', function(a) return a[1] == P6 end), 'AI state primed (the same pose is ignored)')
H.fire('crimson-police:client:runEnded', 1, 'run-old')
Clear()
Npc.task(P6, 'cuffed', { instant = true })
H.ok(not Called('SetEnableHandcuffs', function(a) return a[1] == P6 end), 'stale run end: AI state kept')
H.fire('crimson-police:client:runEnded', 1, 'run-1')
Clear()
Npc.task(P6, 'cuffed', { instant = true })
H.ok(Called('SetEnableHandcuffs', function(a) return a[1] == P6 end), 'run end forgets the AI state')
TriggerEvent('onResourceStop', 'some-other-resource')
H.eq(W.removed, nil, 'another resource stopping changes nothing')
Clear()
TriggerEvent('onResourceStop', 'Crimson-Police')
local removed = {}
for _, n in ipairs(W.removed or {}) do removed[n] = true end
H.ok(removed['crimson-police:cuff'] and removed['crimson-police:cuff:2'], 'every option removed on stop')
H.ok(Called('RemoveRelationshipGroup', function(a) return a[1] == HOSTILE end), 'hostile group removed')
H.ok(Called('RemoveRelationshipGroup', function(a) return a[1] == NEUTRAL end), 'neutral group removed')
H.ok(Called('FreezeEntityPosition', function(a) return a[1] == P6 and a[2] == false end),
    'managed peds unfrozen on stop')

local names = {}
for k in pairs(fallback) do names[#names + 1] = k end
table.sort(names)
print('NATIVES (recorded by the fallback): ' .. table.concat(names, ', '))
print(('RESULT %d %d'):format(H.passes, H.failures))
