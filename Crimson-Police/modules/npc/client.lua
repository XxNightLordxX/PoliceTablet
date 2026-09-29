-- CP.Npc (client): host-side NPC AI helpers and "Cuff suspect".

CP.Npc = CP.Npc or {}
local Npc = CP.Npc
local U = CP.U
local TAG = 'npc'

local HOSTILE_NAME, NEUTRAL_NAME = 'CRIMSONPOLICE_HOSTILE', 'CRIMSONPOLICE_NEUTRAL'
local HOSTILE, NEUTRAL, PLAYER = joaat(HOSTILE_NAME), joaat(NEUTRAL_NAME), joaat('PLAYER')
-- Groups our two groups are explicitly neutral to (relations FROM our groups only).
local OTHER_GROUPS = {
    'CIVMALE',
    'CIVFEMALE',
    'COP',
    'SECURITY_GUARD',
    'PRIVATE_SECURITY',
    'FIREMAN',
    'MEDIC',
    'ARMY',
    'GANG_1',
    'GANG_2',
    'GANG_9',
    'GANG_10',
    'AMBIENT_GANG_LOST',
    'AMBIENT_GANG_MEXICAN',
    'AMBIENT_GANG_FAMILY',
    'AMBIENT_GANG_BALLAS',
    'AMBIENT_GANG_MARABUNTE',
    'AMBIENT_GANG_CULT',
    'AMBIENT_GANG_SALVA',
    'AMBIENT_GANG_WEICHENG',
    'AMBIENT_GANG_HILLBILLY',
    'DEALER',
    'HATES_PLAYER',
    'NO_RELATIONSHIP',
    'PRISONER',
    'SPECIAL',
    'NPCCALL_HOSTILE',
    'NPCCALL_RIVAL',
}

local CUFF_OPTION = 'crimson-police:cuff'
local CUFF_EVENT = 'crimson-police:server:npcCuff'
local CUFF_ICON = 'fas fa-handcuffs'
local CUFF_DICT, CUFF_CLIP = 'mp_arresting', 'a_uncuff'
local MAX_CUFF_RANGE = 10.0
local MAX_OPTIONS = 8
local FACE_MS = 600

local ARRESTS, BUSTED, CUFFED_DICT = 'random@arrests', 'random@arrests@busted', 'mp_arresting'
local HANDS_UP_MS, KNEEL_MS, ENTER_MS, GETUP_MS, EXIT_MS = 4000, 500, 1000, 2500, 1200

local UNARMED = joaat('WEAPON_UNARMED')
local LOOP_MS = 500
local RETARGET_MS = 3000
local SWITCH_SHARE = 0.6         -- switch combat target when another participant is this much closer
local STUCK_TICKS = 4            -- loop ticks below STUCK_SPEED before a task is re-issued
local STUCK_SPEED = 0.3
local REISSUE_MS = 3000
local REISSUE_VEH_MS = 8000
local POSE_CHECK_MS = 2500
local LOST_CONTROL_MS = 10000
local FOOT_ARRIVE = 2.5
local AHEAD_MARGIN = 50.0        -- route start: the first local minimum of the distance, with this hysteresis
local DEBOUNCE_MS = 1500         -- an identical movement task this soon after the last one is ignored
local CONTROL_MS = 1500
local ENTITY_WAIT_MS = 1500
local FLEE_DISTANCE = 500.0

local STYLES = {
    careful = 786603,    -- stops for cars, peds and red lights; keeps to its lane
    cautious = 786603,
    normal = 786475,     -- as careful, without stopping at red lights
    fast = 786492,       -- swerves around traffic instead of stopping; keeps to its lane
    reckless = 787004,   -- as fast, may use oncoming lanes to overtake
}

-- behaviour -> combat setup (attributes: 0 cover, 1 vehicles, 2 drive-bys, 3 leave vehicle, 5 always
-- fight, 13 aggressive, 17 always flee, 21 chase on foot, 42 flank, 46 fight armed when unarmed,
-- 50 charge, 58 disable flee from combat)
local BEHAVIOUR = {
    hold = {
        movement = 1,
        range = 2,
        ability = 1,
        area = 10.0,
        attrs = {
            [0] = true,
            [1] = false,
            [2] = true,
            [3] = true,
            [5] = true,
            [13] = false,
            [17] = false,
            [21] = false,
            [42] = false,
            [46] = true,
            [50] = false,
            [58] = true,
        },
    },
    balanced = {
        movement = 2,
        range = 1,
        ability = 1,
        attrs = {
            [0] = true,
            [1] = false,
            [2] = true,
            [3] = true,
            [5] = true,
            [13] = false,
            [17] = false,
            [21] = true,
            [42] = true,
            [46] = true,
            [50] = false,
            [58] = true,
        },
    },
    push = {
        movement = 2,
        range = 0,
        ability = 2,
        attrs = {
            [0] = true,
            [1] = false,
            [2] = true,
            [3] = true,
            [5] = true,
            [13] = true,
            [17] = false,
            [21] = true,
            [42] = true,
            [46] = true,
            [50] = true,
            [58] = true,
        },
    },
}

-- States in which a ped is calm: neutral group, no weapon in hand.
local CALM = { surrendered = true, cuffed = true, restrained = true, freed = true, safe = true, dead = true }
local POSES = { kneel = true, cuffed = true, handsUp = true, cower = true }

local ai = {}            -- [ped] = { action, args, token, at, prev, ... } peds this client tasked
local bags = {}          -- [netId] = last cp bag seen for the local player's run
local handled = {}       -- [netId] = { entity, state, taskKey } host bookkeeping of the bag handler
local partCache = {}     -- [runId] = { [src] = status }
local cuffOptions = {}   -- [label] = option name
local optionOrder = {}   -- { label, ... } in registration order
local targetReady = false
local groupsReady = false
local looping = false
local tokens = 0
local cuffing = nil      -- { netId, runId, cancelled } while the cuff progress bar runs

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Now() return GetGameTimer() end

local function CurrentRun()
    if not (CP.Runs and CP.Runs.current) then return nil end
    local ok, run = pcall(CP.Runs.current)
    if ok and type(run) == 'table' and run.id ~= nil then return run end
    return nil
end

local function MyServerId() return GetPlayerServerId(PlayerId()) end

local function ValidPed(e)
    return type(e) == 'number' and e ~= 0 and DoesEntityExist(e) and IsEntityAPed(e) and not IsPedAPlayer(e)
end

local function ToVec3(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function PointsOf(list)
    local out = {}
    if type(list) ~= 'table' then return out end
    if type(list.points) == 'table' then list = list.points end
    for i = 1, #list do
        local v = ToVec3(list[i])
        if v then out[#out + 1] = v end
    end
    return out
end

local function BagOf(e)
    local ok, v = pcall(function() return Entity(e).state.cp end)
    if ok and type(v) == 'table' then return v end
    return nil
end

local function Foreign(v)
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function InForeignArena()
    local ok, v = pcall(function() return LocalPlayer.state.crimsonArena end)
    return ok and Foreign(v)
end

-- args.speed is m/s (args.kmh is accepted too); defaultMs when neither is given.
local function SpeedOf(args, defaultMs)
    local ms = tonumber(args.speed)
    if not ms and tonumber(args.kmh) then ms = tonumber(args.kmh) / 3.6 end
    if not ms or ms ~= ms then ms = defaultMs end
    return U.clamp(ms, 1.0, 100.0)
end

-- A numeric args.drivingStyle wins over the args.style name.
local function StyleOf(args, default)
    local n = tonumber(args.drivingStyle)
    if n and n == n then return math.floor(n) end
    return STYLES[args.style] or STYLES[default] or STYLES.normal
end

local function Aggressive(args, default)
    local name = args.style or default
    return name == 'reckless' or name == 'fast'
end

local function LoadDict(dict)
    if HasAnimDictLoaded(dict) then return true end
    if lib and lib.requestAnimDict then
        pcall(lib.requestAnimDict, dict, 3000)
        return HasAnimDictLoaded(dict)
    end
    RequestAnimDict(dict)
    local deadline = Now() + 3000
    while not HasAnimDictLoaded(dict) and Now() < deadline do Wait(25) end
    return HasAnimDictLoaded(dict)
end

local function PlayAnim(ped, dict, clip, flag)
    if not LoadDict(dict) then return false end
    TaskPlayAnim(ped, dict, clip, 8.0, -8.0, -1, flag, 0.0, false, false, false)
    return true
end

local function Control(ent, ms)
    if NetworkHasControlOfEntity(ent) then return true end
    if CP.Runs and CP.Runs.control then
        local ok, res = pcall(CP.Runs.control, ent, ms)
        if ok then return res == true end
    end
    local deadline = Now() + ms
    NetworkRequestControlOfEntity(ent)
    while not NetworkHasControlOfEntity(ent) and Now() < deadline do
        Wait(50)
        NetworkRequestControlOfEntity(ent)
    end
    return NetworkHasControlOfEntity(ent)
end

local function EntityFromNet(netId, ms)
    local deadline = Now() + (ms or 0)
    repeat
        if NetworkDoesNetworkIdExist(netId) then
            local e = NetworkGetEntityFromNetworkId(netId)
            if e and e ~= 0 and DoesEntityExist(e) then return e end
        end
        if Now() >= deadline then break end
        Wait(100)
    until false
    return nil
end

local function VehicleOf(v)
    if type(v) ~= 'number' then return nil end
    if v ~= 0 and DoesEntityExist(v) and IsEntityAVehicle(v) then return v end
    if NetworkDoesNetworkIdExist(v) then
        local e = NetworkGetEntityFromNetworkId(v)
        if e and e ~= 0 and DoesEntityExist(e) and IsEntityAVehicle(e) then return e end
    end
    return nil
end

local function IsDriver(ped, veh)
    return veh and veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped
end

-- ============================================================================
--                             RELATIONSHIP GROUPS
-- ============================================================================

local function EnsureGroups()
    if groupsReady then return end
    if not DoesRelationshipGroupExist(HOSTILE) then AddRelationshipGroup(HOSTILE_NAME) end
    if not DoesRelationshipGroupExist(NEUTRAL) then AddRelationshipGroup(NEUTRAL_NAME) end
    -- Relations FROM our groups only (never from PLAYER, ARCHITECTURE §0.14 / §6.1).
    SetRelationshipBetweenGroups(5, HOSTILE, PLAYER)
    SetRelationshipBetweenGroups(0, HOSTILE, HOSTILE)
    SetRelationshipBetweenGroups(3, HOSTILE, NEUTRAL)
    SetRelationshipBetweenGroups(3, NEUTRAL, PLAYER)
    SetRelationshipBetweenGroups(3, NEUTRAL, HOSTILE)
    SetRelationshipBetweenGroups(3, NEUTRAL, NEUTRAL)
    for _, name in ipairs(OTHER_GROUPS) do
        local g = joaat(name)
        SetRelationshipBetweenGroups(3, HOSTILE, g)
        SetRelationshipBetweenGroups(3, NEUTRAL, g)
    end
    groupsReady = true
    CP.log(TAG, 'relationship groups ready')
end

-- ============================================================================
--                                 PARTICIPANTS
-- ============================================================================

local function CacheParticipants(runId, list)
    if runId == nil or type(list) ~= 'table' then return end
    local c = {}
    for k, v in pairs(list) do
        if type(v) == 'number' then
            c[v] = 'active'
        elseif type(v) == 'table' then
            local s = tonumber(v.src) or tonumber(k)
            if s then c[s] = type(v.status) == 'string' and v.status or 'active' end
        end
    end
    partCache[runId] = c
end

local function ParticipantSrcs(run)
    local out, seen = {}, {}
    local function add(src, status)
        src = tonumber(src)
        if not src or seen[src] then return end
        seen[src] = true
        if status == nil or status == 'active' then out[#out + 1] = src end
    end
    local cache = partCache[run.id]
    if cache then
        for src, status in pairs(cache) do add(src, status) end
    end
    if type(run.participants) == 'table' then
        for k, v in pairs(run.participants) do
            if type(v) == 'number' then
                add(v)
            elseif type(v) == 'table' then
                add(v.src or k, v.status)
            elseif v == true then
                add(k)
            end
        end
    end
    add(MyServerId())
    return out
end

local function ParticipantPeds(run)
    local out = {}
    for _, src in ipairs(ParticipantSrcs(run)) do
        local pl = GetPlayerFromServerId(src)
        if pl and pl ~= -1 and NetworkIsPlayerActive(pl) then
            local ped = GetPlayerPed(pl)
            if ped and ped ~= 0 and DoesEntityExist(ped) and not IsEntityDead(ped) then out[#out + 1] = ped end
        end
    end
    return out
end

function Npc.nearestParticipant(coords)
    local run = CurrentRun()
    local c = ToVec3(coords)
    if not run or not c then return nil, math.huge end
    local best, bestD = nil, math.huge
    for _, ped in ipairs(ParticipantPeds(run)) do
        local d = U.dist(GetEntityCoords(ped), c)
        if d < bestD then best, bestD = ped, d end
    end
    return best, bestD
end

local function IsParticipantPed(ped)
    local run = CurrentRun()
    if not run or not ped then return false end
    for _, p in ipairs(ParticipantPeds(run)) do
        if p == ped then return true end
    end
    return false
end

-- ============================================================================
--                                    APPLY
-- ============================================================================

local function WeaponHash(w)
    if type(w) == 'number' then return w end
    if type(w) == 'string' and w ~= '' then return joaat(w) end
    return nil
end

local function Disarm(ped)
    SetCurrentPedWeapon(ped, UNARMED, true)
    RemoveAllPedWeapons(ped, true)
end

local function Pristine(ped)
    return GetEntityHealth(ped) >= GetEntityMaxHealth(ped) and not HasEntityBeenDamagedByAnyPed(ped)
end

local function ApplyBehaviour(ped, name)
    local b = BEHAVIOUR[name] or BEHAVIOUR.balanced
    for attr, on in pairs(b.attrs) do SetPedCombatAttributes(ped, attr, on) end
    SetPedCombatMovement(ped, b.movement)
    SetPedCombatRange(ped, b.range)
    SetPedCombatAbility(ped, b.ability)
    if b.area then
        local c = GetEntityCoords(ped)
        SetPedSphereDefensiveArea(ped, c.x, c.y, c.z, b.area, false, false)
    else
        RemovePedDefensiveArea(ped, false)
    end
end

local function GroupFor(bag, cfg, state)
    if state == 'hostile' then return HOSTILE end
    if CALM[state] then return NEUTRAL end
    local g = cfg.group
    if g == nil and type(bag.cfg) == 'table' then g = bag.cfg.group end
    if g == 'hostile' then return HOSTILE end
    if g == 'neutral' then return NEUTRAL end
    return bag.armed == true and HOSTILE or NEUTRAL
end

local function ApplyWith(ped, cfg, bag)
    if not ValidPed(ped) or not NetworkHasControlOfEntity(ped) then return false end
    cfg = type(cfg) == 'table' and cfg or {}
    bag = type(bag) == 'table' and bag or {}
    EnsureGroups()
    local state = bag.state or 'idle'
    local armed = bag.armed
    if armed == nil then armed = cfg.weapon ~= nil end

    -- nothing a non-participant can take: no weapon or cash drops
    SetPedDropsWeaponsWhenDead(ped, false)
    SetPedMoney(ped, 0)
    SetPedDiesWhenInjured(ped, true)
    SetPedCanRagdollFromPlayerImpact(ped, false)

    local weapon = WeaponHash(cfg.weapon)
    if armed and weapon and not CALM[state] then
        if not HasPedGotWeapon(ped, weapon, false) then GiveWeaponToPed(ped, weapon, 250, false, true) end
        SetCurrentPedWeapon(ped, weapon, true)
    elseif not armed or CALM[state] then
        Disarm(ped)
    end

    local acc = tonumber(cfg.accuracy)
    if acc and acc == acc then SetPedAccuracy(ped, math.floor(U.clamp(acc, 0, 100) + 0.5)) end
    local hp = tonumber(cfg.health)
    if hp and hp == hp and hp > 0 then
        hp = math.floor(U.clamp(hp, 101, 5000))
        local max = GetEntityMaxHealth(ped)
        if max ~= hp then
            local untouched = GetEntityHealth(ped) >= max
            SetPedMaxHealth(ped, hp)
            SetEntityMaxHealth(ped, hp)
            if untouched then SetEntityHealth(ped, hp) end
        end
    end
    local arm = tonumber(cfg.armour)
    if arm and arm == arm and arm > 0 and GetPedArmour(ped) == 0 and Pristine(ped) then
        SetPedArmour(ped, math.floor(U.clamp(arm, 0, 200)))
    end

    SetPedRelationshipGroupHash(ped, GroupFor(bag, cfg, state))
    ApplyBehaviour(ped, cfg.behaviour)
    if armed and not CALM[state] then
        SetPedSeeingRange(ped, 100.0)
        SetPedHearingRange(ped, 100.0)
        SetPedAlertness(ped, 3)
    else
        SetPedCombatAttributes(ped, 5, false)
        SetPedCombatAttributes(ped, 46, false)
    end
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    CP.log(TAG, 'applied cfg to ped %s (state %s, armed %s)', tostring(ped), tostring(state), tostring(armed))
    return true
end

function Npc.apply(entity, cfg)
    if not ValidPed(entity) then return false end
    return ApplyWith(entity, cfg, BagOf(entity))
end

-- ============================================================================
--                                    TASKS
-- ============================================================================

local function IsCurrent(ped, token)
    local a = ai[ped]
    return a ~= nil and a.token == token and DoesEntityExist(ped)
end

-- Undo a pose (kneeling, cuffed, cowering) before a moving task. keepAnim: the caller plays its own
-- stand-up animation from the current pose.
local function Release(ped, a, keepAnim)
    FreezeEntityPosition(ped, false)
    SetEnableHandcuffs(ped, false)
    if POSES[a.prev] and not keepAnim then ClearPedTasks(ped) end
end

local function Calm(ped)
    Disarm(ped)
    SetPedRelationshipGroupHash(ped, NEUTRAL)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedKeepTask(ped, true)
end

local function RunTo(ped, p)
    TaskFollowNavMeshToCoord(ped, p.x, p.y, p.z, 3.0, -1, 1.0, false, 0.0)
end

local function DriveTo(ped, veh, p, a)
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, a.aggressive and 1.0 or 0.3)
    TaskVehicleDriveToCoordLongrange(ped, veh, p.x, p.y, p.z, a.speed, a.style, a.stopRange or 4.0)
end

local function ArriveRadius(a)
    return tonumber(a.args.arrive) or math.max(12.0, a.speed * 1.2, (a.stopRange or 4.0) + 4.0)
end

-- The nearest point AHEAD: walking the route from its first point, the first local minimum of the
-- distance (a later part of the route that bends back past the ped is not taken).
local function NearestAhead(pts, pos)
    local best, bestD = 1, math.huge
    for i = 1, #pts do
        local d = U.dist(pts[i], pos)
        if d < bestD then
            best, bestD = i, d
        elseif d > bestD + AHEAD_MARGIN then
            break
        end
    end
    return best, bestD
end

-- args.startIndex when given, else the nearest point ahead (or the one after it when already there).
local function StartIndex(a, pts, pos, radius, loop)
    local s = tonumber(a.args.startIndex)
    s = s and math.tointeger(s)
    if s and s >= 1 and s <= #pts then return s end
    local i, d = NearestAhead(pts, pos)
    if d <= radius then
        if i < #pts then i = i + 1 elseif loop then i = 1 end
    end
    return i
end

local function SmartFlee(ped, a)
    local veh = GetVehiclePedIsIn(ped, false)
    local from = a.args.from
    if not (from and DoesEntityExist(from)) then from = Npc.nearestParticipant(GetEntityCoords(ped)) end
    if IsDriver(ped, veh) then
        a.speed = SpeedOf(a.args, 120 / 3.6)
        a.style = StyleOf(a.args, 'reckless')
        SetDriverAbility(ped, 1.0)
        SetDriverAggressiveness(ped, 1.0)
        if from then
            TaskVehicleMissionPedTarget(ped, veh, from, 8, a.speed, a.style, FLEE_DISTANCE, 5.0, true)
        else
            TaskVehicleDriveWander(ped, veh, a.speed, a.style)
        end
    elseif from then
        TaskSmartFleePed(ped, from, tonumber(a.args.distance) or FLEE_DISTANCE, -1, false, false)
    else
        TaskWanderStandard(ped, 10.0, 10)
    end
    a.issuedAt = Now()
end

-- No participant to fight: stay put without looking for targets. TaskGuardCurrentPosition would
-- attack any ped of a hated group, and CRIMSONPOLICE_HOSTILE hates PLAYER, i.e. every player, so a
-- bystander walking past would be shot ("hostile only to participants", Hard rule "NPCs only").
local function Hold(ped)
    ClearPedTasks(ped)
    TaskStandStill(ped, -1)
end

local ACTIONS = {}

function ACTIONS.combat(ped, a)
    Release(ped, a)
    local bag = BagOf(ped) or {}
    local cfg = type(bag.cfg) == 'table' and bag.cfg or {}
    SetPedRelationshipGroupHash(ped, HOSTILE)
    ApplyBehaviour(ped, a.args.behaviour or cfg.behaviour)
    SetPedCombatAttributes(ped, 17, false)
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    local w = WeaponHash(cfg.weapon)
    if w and HasPedGotWeapon(ped, w, false) then SetCurrentPedWeapon(ped, w, true) end
    local target = a.args.target
    if not (target and DoesEntityExist(target) and not IsEntityDead(target)) then
        target = Npc.nearestParticipant(GetEntityCoords(ped))
    end
    a.target = target
    a.nextAt = Now() + RETARGET_MS
    if target then
        a.guarding = false
        TaskCombatPed(ped, target, 0, 16)
    else
        a.guarding = true
        Hold(ped)
    end
end

function ACTIONS.flee(ped, a)
    Release(ped, a)
    local bag = BagOf(ped) or {}
    local cfg = type(bag.cfg) == 'table' and bag.cfg or {}
    SetPedFleeAttributes(ped, 0, false)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCombatAttributes(ped, 17, true)
    local pts = PointsOf(a.args.points)
    a.points = #pts > 0 and pts or nil
    if not a.points then
        SmartFlee(ped, a)
        return
    end
    local veh = GetVehiclePedIsIn(ped, false)
    local pos = GetEntityCoords(ped)
    a.from = pos
    if IsDriver(ped, veh) then
        a.vehicle = veh
        a.speed = SpeedOf(a.args, 120 / 3.6)
        a.style = StyleOf(a.args, cfg.style or 'reckless')
        a.aggressive = Aggressive(a.args, cfg.style or 'reckless')
        a.stopRange = tonumber(a.args.stopRange)
        a.idx = StartIndex(a, pts, pos, ArriveRadius(a), false)
        DriveTo(ped, veh, pts[a.idx], a)
    else
        a.idx = StartIndex(a, pts, pos, FOOT_ARRIVE, false)
        RunTo(ped, pts[a.idx])
    end
    a.issuedAt = Now()
end

function ACTIONS.handsUp(ped, a)
    Calm(ped)
    local face = Npc.nearestParticipant(GetEntityCoords(ped))
    TaskHandsUp(ped, tonumber(a.args.duration) or -1, face or 0, -1, true)
end

function ACTIONS.kneel(ped, a)
    Calm(ped)
    FreezeEntityPosition(ped, false)
    local token = a.token
    local full = not a.args.instant and a.prev ~= 'kneel'
    CreateThread(function()
        if full then
            ClearPedTasks(ped)
            PlayAnim(ped, ARRESTS, 'idle_2_hands_up', 2)
            Wait(HANDS_UP_MS)
            if not IsCurrent(ped, token) then return end
            PlayAnim(ped, ARRESTS, 'kneeling_arrest_idle', 2)
            Wait(KNEEL_MS)
            if not IsCurrent(ped, token) then return end
            PlayAnim(ped, BUSTED, 'enter', 2)
            Wait(ENTER_MS)
            if not IsCurrent(ped, token) then return end
        end
        PlayAnim(ped, BUSTED, 'idle_a', 1)
        a.settled = true
        a.pose = { BUSTED, 'idle_a', 1 }
        a.poseAt = Now() + POSE_CHECK_MS
    end)
end

function ACTIONS.cuffed(ped, a)
    Calm(ped)
    SetEnableHandcuffs(ped, true)
    local token = a.token
    local getUp = not a.args.instant and a.prev == 'kneel'
    CreateThread(function()
        if getUp then
            PlayAnim(ped, ARRESTS, 'kneeling_arrest_get_up', 2)
            Wait(GETUP_MS)
            if not IsCurrent(ped, token) then return end
        end
        FreezeEntityPosition(ped, true)
        PlayAnim(ped, CUFFED_DICT, 'idle', 49)
        a.settled = true
        a.pose = { CUFFED_DICT, 'idle', 49 }
        a.poseAt = Now() + POSE_CHECK_MS
    end)
end

function ACTIONS.follow(ped, a)
    local c = ToVec3(a.args.coords)
    if not c then error('follow needs coords') end
    a.coords = c
    a.radius = tonumber(a.args.radius) or 1.5
    a.speedFoot = U.clamp(tonumber(a.args.speed) or 1.0, 0.5, 3.0)
    local wasKneeling = a.prev == 'kneel'
    Release(ped, a, wasKneeling)
    SetPedRelationshipGroupHash(ped, NEUTRAL)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedFleeAttributes(ped, 0, false)
    SetPedKeepTask(ped, true)
    local token = a.token
    CreateThread(function()
        if wasKneeling then
            PlayAnim(ped, BUSTED, 'exit', 2)
            Wait(EXIT_MS)
            if not IsCurrent(ped, token) then return end
        end
        if a.args.anyMeans then
            TaskGoToCoordAnyMeans(ped, c.x, c.y, c.z, a.speedFoot, 0, false, STYLES.careful, -1.0)
        else
            TaskFollowNavMeshToCoord(ped, c.x, c.y, c.z, a.speedFoot, -1, a.radius, false, 0.0)
        end
        a.issuedAt = Now()
    end)
end

function ACTIONS.cower(ped, a)
    Release(ped, a)
    Calm(ped)
    TaskCower(ped, -1)
end

function ACTIONS.wander(ped, a)
    Release(ped, a)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedKeepTask(ped, true)
    TaskWanderStandard(ped, 10.0, 10)
end

function ACTIONS.enterVehicle(ped, a)
    local veh = VehicleOf(a.args.vehicle)
    if not veh then error('enterVehicle needs a vehicle') end
    Release(ped, a)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    a.vehicle = veh
    TaskEnterVehicle(ped, veh, tonumber(a.args.timeout) or 20000, tonumber(a.args.seat) or -1,
        tonumber(a.args.speed) or 2.0, 1, 0)
end

function ACTIONS.driveTo(ped, a)
    local c = ToVec3(a.args.coords)
    local veh = VehicleOf(a.args.vehicle) or GetVehiclePedIsIn(ped, false)
    if not c or not veh or veh == 0 then error('driveTo needs coords and a vehicle') end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    a.coords, a.vehicle = c, veh
    a.speed = SpeedOf(a.args, 60 / 3.6)
    a.style = StyleOf(a.args, 'normal')
    a.aggressive = Aggressive(a.args, 'normal')
    a.stopRange = tonumber(a.args.stopRange) or 8.0
    DriveTo(ped, veh, c, a)
    a.issuedAt = Now()
end

function ACTIONS.driveRoute(ped, a)
    local pts = PointsOf(a.args.points)
    local veh = VehicleOf(a.args.vehicle) or GetVehiclePedIsIn(ped, false)
    if #pts == 0 or not veh or veh == 0 then error('driveRoute needs points and a vehicle') end
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    a.points, a.vehicle = pts, veh
    a.loop = a.args.loop == true
    a.speed = SpeedOf(a.args, 60 / 3.6)
    a.style = StyleOf(a.args, 'normal')
    a.aggressive = Aggressive(a.args, 'normal')
    a.stopRange = tonumber(a.args.stopRange)
    a.from = GetEntityCoords(veh)
    a.idx = StartIndex(a, pts, a.from, ArriveRadius(a), a.loop)
    DriveTo(ped, veh, pts[a.idx], a)
    a.issuedAt = Now()
end

local function SamePoint(a, b)
    if a == nil or b == nil then return a == b end
    return U.dist(a, b) <= 1.0
end

-- Poses and combat on the same target are never restarted (no animation replay); a flee without points
-- keeps a running route; identical movement tasks are only debounced (a block re-tasking a stuck ped
-- a few seconds later is obeyed). A task whose ped changed cp state since is never "the same".
local function SameTask(cur, action, args, t)
    if cur.action ~= action or cur.done then return false end
    if action == 'kneel' or action == 'cuffed' or action == 'handsUp' or action == 'cower' or action == 'wander' then
        return true
    elseif action == 'combat' then
        return args.target == nil or args.target == cur.args.target
    end
    local recent = t - cur.at < DEBOUNCE_MS
    if action == 'flee' then
        local new = PointsOf(args.points)
        if #new == 0 then return cur.points ~= nil or recent end
        local old = PointsOf(cur.args.points)
        return recent and #old == #new and SamePoint(old[1], new[1]) and SamePoint(old[#old], new[#new])
    elseif action == 'follow' or action == 'driveTo' then
        return recent and SamePoint(ToVec3(cur.args.coords), ToVec3(args.coords)) and cur.args.vehicle == args.vehicle
    elseif action == 'driveRoute' then
        local old, new = PointsOf(cur.args.points), PointsOf(args.points)
        return recent and #old == #new and SamePoint(old[1], new[1]) and cur.args.loop == args.loop
    elseif action == 'enterVehicle' then
        return recent and cur.args.vehicle == args.vehicle and cur.args.seat == args.seat
    end
    return false
end

local EnsureLoop

function Npc.task(entity, action, args)
    if not ValidPed(entity) then return false end
    local fn = ACTIONS[action]
    if not fn then
        CP.warn(TAG, 'unknown NPC action %s', tostring(action))
        return false
    end
    if not NetworkHasControlOfEntity(entity) then return false end
    args = type(args) == 'table' and args or {}
    local cur = ai[entity]
    local t = Now()
    if cur and not args.force and SameTask(cur, action, args, t) then return true end
    tokens = tokens + 1
    local bag = BagOf(entity)
    local a = {
        action = action,
        args = args,
        token = tokens,
        at = t,
        prev = cur and cur.action or nil,
        still = 0,
        bagState = bag and bag.state or nil,
    }
    ai[entity] = a
    local ok, err = pcall(fn, entity, a)
    if not ok then
        CP.warn(TAG, 'task %s on ped %s failed: %s', tostring(action), tostring(entity), tostring(err))
        ai[entity] = nil
        return false
    end
    EnsureLoop()
    return true
end

-- ============================================================================
--                                 HOST AI LOOP
-- ============================================================================

local function Stuck(ped, a, t, minMs)
    if GetEntitySpeed(ped) < STUCK_SPEED then a.still = (a.still or 0) + 1 else a.still = 0 end
    if a.still >= STUCK_TICKS and t - (a.issuedAt or 0) >= minMs then
        a.still = 0
        return true
    end
    return false
end

local function StepCombat(ped, a, t)
    if t < (a.nextAt or 0) then return end
    a.nextAt = t + RETARGET_MS
    local pos = GetEntityCoords(ped)
    local best, bestD = Npc.nearestParticipant(pos)
    if not best then
        if not a.guarding then
            a.guarding, a.target = true, nil
            Hold(ped)
        end
        return
    end
    local cur = a.target
    local valid = cur and DoesEntityExist(cur) and not IsEntityDead(cur) and IsParticipantPed(cur)
    local swap = not valid or (cur ~= best and bestD < SWITCH_SHARE * U.dist(pos, GetEntityCoords(cur)))
    if swap or a.guarding or not IsPedInCombat(ped, 0) then
        a.target, a.guarding = best, false
        TaskCombatPed(ped, best, 0, 16)
    end
end

local function StepPoints(ped, a, t)
    local veh = a.vehicle
    local driving = veh and DoesEntityExist(veh) and IsDriver(ped, veh)
    if a.vehicle and not driving then
        -- out of the vehicle (a block made them leave it): the block decides what happens next
        a.done = true
        return
    end
    local pos = GetEntityCoords(driving and veh or ped)
    local radius = driving and ArriveRadius(a) or FOOT_ARRIVE
    local cur = a.points[a.idx]
    local hasNext = a.idx < #a.points or a.loop
    local prev = a.idx > 1 and a.points[a.idx - 1] or a.from
    local d = U.dist(pos, cur)
    -- reached, or passed close by: near the waypoint and already beyond it along the leg being driven
    -- (from the previous waypoint, or where the task started). Not along the next leg: on a hairpin the
    -- next point lies on the approach side, and the turn would be cut short.
    local passed = false
    if hasNext and prev and d <= radius * 3 then
        passed = (pos.x - cur.x) * (cur.x - prev.x) + (pos.y - cur.y) * (cur.y - prev.y) > 0
    end
    if d <= radius or passed then
        a.idx = a.idx + 1
        if a.idx > #a.points then
            if a.loop then
                a.idx, a.from = 1, cur
            elseif a.action == 'flee' then
                a.points, a.vehicle = nil, nil
                SmartFlee(ped, a)
                return
            else
                a.done = true
                return
            end
        end
        if driving then DriveTo(ped, veh, a.points[a.idx], a) else RunTo(ped, a.points[a.idx]) end
        a.issuedAt = t
    elseif Stuck(driving and veh or ped, a, t, driving and REISSUE_VEH_MS or REISSUE_MS) then
        if driving then DriveTo(ped, veh, a.points[a.idx], a) else RunTo(ped, a.points[a.idx]) end
        a.issuedAt = t
    end
end

local function StepPose(ped, a, t)
    if not a.settled or not a.pose or t < (a.poseAt or 0) then return end
    a.poseAt = t + POSE_CHECK_MS
    local p = a.pose
    if not IsEntityPlayingAnim(ped, p[1], p[2], 3) then PlayAnim(ped, p[1], p[2], p[3]) end
end

local function Step(ped, a, t)
    if a.done then return end
    local action = a.action
    if action == 'combat' then
        StepCombat(ped, a, t)
    elseif action == 'flee' then
        if a.points then
            StepPoints(ped, a, t)
        elseif Stuck(ped, a, t, REISSUE_MS * 2) then
            SmartFlee(ped, a)
        end
    elseif action == 'driveRoute' then
        StepPoints(ped, a, t)
    elseif action == 'driveTo' then
        local veh = a.vehicle
        if not (veh and DoesEntityExist(veh) and IsDriver(ped, veh)) then a.done = true return end
        if U.dist(GetEntityCoords(veh), a.coords) <= a.stopRange + 2.0 then
            a.done = true
        elseif Stuck(veh, a, t, REISSUE_VEH_MS) then
            DriveTo(ped, veh, a.coords, a)
            a.issuedAt = t
        end
    elseif action == 'follow' then
        if not a.issuedAt then return end
        if U.dist(GetEntityCoords(ped), a.coords) <= a.radius + 0.5 then
            a.done = true
        elseif Stuck(ped, a, t, REISSUE_MS) then
            TaskFollowNavMeshToCoord(ped, a.coords.x, a.coords.y, a.coords.z, a.speedFoot, -1, a.radius, false, 0.0)
            a.issuedAt = t
        end
    elseif action == 'kneel' or action == 'cuffed' then
        StepPose(ped, a, t)
    end
end

EnsureLoop = function()
    if looping then return end
    looping = true
    CreateThread(function()
        while next(ai) ~= nil do
            local run = CurrentRun()
            local host = run ~= nil and run.isHost == true
            local t = Now()
            for ped, a in pairs(ai) do
                if not host or not DoesEntityExist(ped) or IsEntityDead(ped) then
                    ai[ped] = nil
                elseif not NetworkHasControlOfEntity(ped) then
                    a.lostAt = a.lostAt or t
                    if t - a.lostAt > LOST_CONTROL_MS then
                        ai[ped] = nil
                    else
                        NetworkRequestControlOfEntity(ped)
                    end
                else
                    a.lostAt = nil
                    if a.bagState ~= nil and not a.done then
                        -- the server moved the ped to another state: whoever reacts to it re-tasks
                        local b = BagOf(ped)
                        if b and b.state ~= a.bagState then a.done = true end
                    end
                    local ok, err = pcall(Step, ped, a, t)
                    if not ok then
                        CP.warn(TAG, 'AI step %s on ped %s failed: %s', tostring(a.action), tostring(ped),
                            tostring(err))
                        ai[ped] = nil
                    end
                end
            end
            Wait(LOOP_MS)
        end
        looping = false
    end)
end

-- ============================================================================
--                      THE CP STATE BAG (host re-tasking)
-- ============================================================================
-- The one-off server task's id: taskSeq (the bag seq it was written with) survives later writes of
-- the bag, so a cfg merge or enableCuff never replays it; seq is the fallback for older bags.
local function TaskKey(value)
    if type(value.task) ~= 'table' then return nil end
    return tostring(value.taskSeq or value.seq)
end

local function Retask(ent, value, settled)
    local task = value.task
    if type(task) == 'table' and ACTIONS[task.action] then
        Npc.task(ent, task.action, type(task.args) == 'table' and task.args or {})
        return
    end
    local cfg = type(value.cfg) == 'table' and value.cfg or {}
    local s = value.state
    if s == 'hostile' then
        Npc.task(ent, 'combat', { behaviour = cfg.behaviour })
    elseif s == 'fleeing' then
        Npc.task(ent, 'flee', { points = value.fleePoints or cfg.fleePoints })
    elseif s == 'surrendered' then
        Npc.task(ent, 'kneel', { instant = settled })
    elseif s == 'cuffed' then
        Npc.task(ent, 'cuffed', { instant = settled })
    elseif s == 'restrained' then
        Npc.task(ent, 'kneel', { instant = true })
    end
end

-- settled = the ped was already in this state before (host change, stream-in): no transitions.
local function OnHostBag(netId, value, settled)
    local ent = EntityFromNet(netId, ENTITY_WAIT_MS)
    if not ent or not ValidPed(ent) then return end
    local run = CurrentRun()
    if not run or not run.isHost or run.id ~= value.run then return end
    if bags[netId] ~= value then value = bags[netId] or value end
    if value.state == 'dead' then return end
    if not Control(ent, CONTROL_MS) then return end
    local h = handled[netId]
    local fresh = not h or h.entity ~= ent
    if fresh then
        ApplyWith(ent, value.cfg, value)
        h = { entity = ent }
        handled[netId] = h
    end
    local key = TaskKey(value)
    if not fresh and h.state == value.state and h.taskKey == key then return end
    h.state, h.taskKey = value.state, key
    Retask(ent, value, settled or fresh)
end

local function Schedule(netId, value, settled)
    CreateThread(function()
        Wait(0)   -- change handlers run before the new value is in the bag
        local ok, err = pcall(OnHostBag, netId, value, settled)
        if not ok then CP.warn(TAG, 'bag update of ped %s failed: %s', tostring(netId), tostring(err)) end
    end)
end

local function ForgetRun()
    bags, handled = {}, {}
    for ped in pairs(ai) do ai[ped] = nil end
end

-- Nothing a non-participant can take: weapons and cash of a dying ped are dropped by whichever
-- client owns it at that moment, and OneSync hands ownership to the nearest player (a partner, or
-- a bystander), not only to the run host that ran apply. So every client that sees a mission ped
-- (any run, participant or not) marks it once per entity handle; a local flag, no control needed.
local dropSafe, dropPending, dropCount = {}, {}, 0

local function MarkDropSafe(netId, ent)
    if dropSafe[netId] == ent then return end
    SetPedDropsWeaponsWhenDead(ent, false)
    SetPedMoney(ent, 0)
    if dropSafe[netId] == nil then dropCount = dropCount + 1 end
    dropSafe[netId] = ent
    if dropCount > 256 then
        for n, e in pairs(dropSafe) do
            if not DoesEntityExist(e) then
                dropSafe[n] = nil
                dropCount = dropCount - 1
            end
        end
    end
end

local function ProtectDrops(netId, value)
    if type(value.run) ~= 'string' or value.state == 'dead' then return end
    local ent = NetworkDoesNetworkIdExist(netId) and NetworkGetEntityFromNetworkId(netId) or 0
    if ent and ent ~= 0 and DoesEntityExist(ent) then
        if ValidPed(ent) then MarkDropSafe(netId, ent) end
        return
    end
    -- the bag of a ped streaming in can arrive before the ped itself
    if dropPending[netId] then return end
    dropPending[netId] = true
    CreateThread(function()
        local e = EntityFromNet(netId, ENTITY_WAIT_MS)
        dropPending[netId] = nil
        if e and ValidPed(e) then MarkDropSafe(netId, e) end
    end)
end

local EnsureCuffOption

AddStateBagChangeHandler('cp', nil, function(bagName, _, value)
    if type(value) ~= 'table' then return end
    local netId = tonumber(tostring(bagName):match('^entity:(%d+)$'))
    if not netId then return end
    ProtectDrops(netId, value)
    local run = CurrentRun()
    if not run or value.run ~= run.id then return end
    local prev = bags[netId]
    bags[netId] = value
    if type(value.cuff) == 'table' then EnsureCuffOption(value.cuff.label) end
    if value.state == 'dead' then
        handled[netId] = nil
        return
    end
    if not run.isHost then return end
    local changed = not prev or prev.state ~= value.state or TaskKey(prev) ~= TaskKey(value)
    if not changed and handled[netId] then return end
    -- settled: first sight of the ped (stream-in) or no state change: poses without transitions
    Schedule(netId, value, prev == nil or prev.state == value.state)
end)

RegisterNetEvent('crimson-police:client:start', function(runId, data)
    if type(runId) ~= 'string' or type(data) ~= 'table' then return end
    CacheParticipants(runId, data.participants)
end)

RegisterNetEvent('crimson-police:client:participants', function(runId, list)
    if type(runId) ~= 'string' or type(list) ~= 'table' then return end
    CacheParticipants(runId, list)
end)

RegisterNetEvent('crimson-police:client:hostChanged', function(runId, hostSrc)
    local run = CurrentRun()
    if type(runId) ~= 'string' or not run or run.id ~= runId then return end
    if tonumber(hostSrc) ~= MyServerId() then
        for ped in pairs(ai) do ai[ped] = nil end
        handled = {}
        return
    end
    handled = {}
    for netId, value in pairs(bags) do
        if value.state ~= 'dead' then Schedule(netId, value, true) end
    end
end)

RegisterNetEvent('crimson-police:client:runEnded', function(runId)
    if type(runId) ~= 'string' then return end
    partCache[runId] = nil
    -- modules/runs clears current() after this handler: a stale end of an earlier run keeps the AI
    -- of the run this player is on now
    local run = CurrentRun()
    if run and run.id ~= runId then return end
    ForgetRun()
end)

-- ============================================================================
--                 "Cuff suspect" (ox_target global ped option)
-- ============================================================================

local function DefaultLabel() return CP.L('npc.cuff') end

local function LabelOf(bag)
    local l = type(bag.cuff) == 'table' and bag.cuff.label or nil
    if type(l) ~= 'string' or l == '' then return DefaultLabel() end
    return l
end

-- The option that offers this bag: the one of its label, or the default one for a label that came after
-- the MAX_OPTIONS cap (labels pile up over a session).
local function OptionLabelOf(bag)
    local l = LabelOf(bag)
    if cuffOptions[l] then return l end
    return DefaultLabel()
end

local function RangeOf(bag)
    return U.clamp(tonumber(bag.cuff and bag.cuff.maxDistance) or 3.0, 1.0, MAX_CUFF_RANGE)
end

local function DurationOf(bag)
    return math.floor(U.clamp(tonumber(bag.cuff and bag.cuff.duration) or 5000, 500, 60000))
end

local function CuffableBag(entity, run)
    if not entity or entity == 0 or not DoesEntityExist(entity) or not NetworkGetEntityIsNetworked(entity) then
        return nil
    end
    local bag = BagOf(entity)
    if not bag or bag.run ~= run.id or bag.state ~= 'surrendered' or type(bag.cuff) ~= 'table' then return nil end
    return bag
end

local function CanCuff(entity, distance, label)
    if cuffing then return false end
    local run = CurrentRun()
    if not run then return false end
    local bag = CuffableBag(entity, run)
    if not bag or OptionLabelOf(bag) ~= label then return false end
    if (tonumber(distance) or math.huge) > RangeOf(bag) then return false end
    local me = PlayerPedId()
    if IsEntityDead(me) or IsPedInAnyVehicle(me, false) then return false end
    return not InForeignArena()
end

local function CancelProgress()
    if lib and lib.cancelProgress then pcall(lib.cancelProgress) end
end

local function CuffFlow(ent)
    if cuffing then return end
    local run = CurrentRun()
    if not run then return end
    local bag = CuffableBag(ent, run)
    if not bag then return end
    local netId = NetworkGetNetworkIdFromEntity(ent)
    local runId = run.id
    local range = RangeOf(bag)
    local state = { netId = netId, runId = runId, cancelled = false }
    cuffing = state
    local me = PlayerPedId()
    TaskTurnPedToFaceEntity(me, ent, FACE_MS)
    Wait(FACE_MS)
    CreateThread(function()
        while cuffing == state do
            Wait(250)
            if cuffing ~= state then break end
            local b = DoesEntityExist(ent) and BagOf(ent) or nil
            local far = U.dist(GetEntityCoords(PlayerPedId()), GetEntityCoords(ent)) > range + 1.0
            if not b or b.state ~= 'surrendered' or far or InForeignArena() then
                state.cancelled = true
                CancelProgress()
                break
            end
        end
    end)
    local ok = false
    if lib and lib.progressBar then
        ok = lib.progressBar({
            duration = DurationOf(bag),
            label = LabelOf(bag),
            useWhileDead = false,
            canCancel = true,
            disable = { move = true, car = true, combat = true },
            anim = { dict = CUFF_DICT, clip = CUFF_CLIP, flag = 49 },
        }) == true
    end
    cuffing = nil
    if not ok or state.cancelled or InForeignArena() then return end
    local cur = CurrentRun()
    if not cur or cur.id ~= runId then return end
    TriggerServerEvent(CUFF_EVENT, runId, netId)
    CP.log(TAG, 'cuff of ped %s sent for run %s', tostring(netId), tostring(runId))
end

local function OptionFor(label, name)
    return {
        name = name,
        icon = CUFF_ICON,
        label = label,
        distance = MAX_CUFF_RANGE,
        canInteract = function(entity, distance)
            local ok, res = pcall(CanCuff, entity, distance, label)
            return ok and res == true
        end,
        onSelect = function(data)
            local ent = type(data) == 'table' and data.entity or data
            if type(ent) ~= 'number' then return end
            CreateThread(function()
                local ok, err = pcall(CuffFlow, ent)
                if not ok then
                    cuffing = nil
                    CP.warn(TAG, 'cuff failed: %s', tostring(err))
                end
            end)
        end,
    }
end

local function RegisterOption(label)
    local name = cuffOptions[label]
    local ok, err = pcall(function() exports.ox_target:addGlobalPed({ OptionFor(label, name) }) end)
    if not ok then CP.warn(TAG, 'could not add the ox_target option %s: %s', name, tostring(err)) end
    return ok
end

EnsureCuffOption = function(label)
    if type(label) ~= 'string' or label == '' then label = DefaultLabel() end
    if cuffOptions[label] then return end
    if #optionOrder >= MAX_OPTIONS then
        CP.log(TAG, 'no option left for the cuff label %s: the default option offers it', label)
        return
    end
    optionOrder[#optionOrder + 1] = label
    cuffOptions[label] = #optionOrder == 1 and CUFF_OPTION or ('%s:%d'):format(CUFF_OPTION, #optionOrder)
    if targetReady then RegisterOption(label) end
end

local function RegisterAll()
    targetReady = true
    for _, label in ipairs(optionOrder) do RegisterOption(label) end
end

local function RemoveAll()
    if not targetReady then return end
    local names = {}
    for _, label in ipairs(optionOrder) do names[#names + 1] = cuffOptions[label] end
    if #names > 0 then
        local ok, err = pcall(function() exports.ox_target:removeGlobalPed(names) end)
        if not ok then CP.warn(TAG, 'could not remove the ox_target options: %s', tostring(err)) end
    end
    targetReady = false
end

-- The default option always exists (first, so it gets the plain name crimson-police:cuff).
EnsureCuffOption(DefaultLabel())

CreateThread(function()
    EnsureGroups()
    while GetResourceState('ox_target') ~= 'started' do Wait(1000) end
    if not targetReady then RegisterAll() end
end)

AddEventHandler('onClientResourceStart', function(res)
    if res == 'ox_target' then RegisterAll() end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res == 'ox_target' then targetReady = false end
end)

-- Crimson-Arena placed the local player: stop a cuff in progress (docs/CRIMSON_ARENA.md rule 8).
AddStateBagChangeHandler('crimsonArena', ('player:%d'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    if Foreign(value) and cuffing then
        cuffing.cancelled = true
        CancelProgress()
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    RemoveAll()
    if cuffing then
        cuffing.cancelled = true
        CancelProgress()
    end
    for ped in pairs(ai) do
        if DoesEntityExist(ped) and NetworkHasControlOfEntity(ped) then FreezeEntityPosition(ped, false) end
        ai[ped] = nil
    end
    if groupsReady then
        RemoveRelationshipGroup(HOSTILE)
        RemoveRelationshipGroup(NEUTRAL)
        groupsReady = false
    end
end)
