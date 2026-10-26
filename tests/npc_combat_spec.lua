-- Config.NpcCombat: no automatic weapons, the accuracy caps, and an officer's run-scoped damage settings.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local NC = CP.NpcCombat
local cfg = Config.NpcCombat

-- ============================================================================
--                         THE SHIPPED VALUES (README)
-- ============================================================================

H.eq(cfg.enabled, true, 'shipped on')
H.eq(cfg.accuracyMax, 18, 'accuracy at most 18')
H.eq(cfg.aiDamage, 0.5, 'NPC bullets do half damage')
H.eq(cfg.noCriticalHits, true, 'no headshot multiplier on officers')
H.eq(cfg.firingPattern, 'single', 'single shots')
H.eq(cfg.ammo, 60, '60 rounds')
H.eq(cfg.officerDefense, 1.0, 'the defense modifier ships off')
H.eq(table.concat(cfg.weapons, ','), 'WEAPON_PISTOL,WEAPON_COMBATPISTOL,WEAPON_HEAVYPISTOL,WEAPON_PUMPSHOTGUN',
    'the NPC weapons: pistols and a pump shotgun')
for _, w in ipairs(Config.Builder.allowed.weapons) do
    H.ok(not NC.isAutomatic(w), 'the Builder offers no automatic weapon: ' .. w)
end
for _, w in ipairs(Config.Blocks.hostile_waves.weapons) do
    H.ok(not NC.isAutomatic(w), 'the hostile_waves default is not automatic: ' .. w)
end

-- ============================================================================
--                   THE WEAPON HELPER (CP.NpcCombat.weapon)
-- ============================================================================

-- the weapons.json Automatic flag list, by name
for _, name in ipairs({
    'WEAPON_MICROSMG',
    'WEAPON_SMG',
    'WEAPON_ASSAULTRIFLE',
    'WEAPON_APPISTOL',
    'WEAPON_MINIGUN',
    'WEAPON_GUSENBERG',
    'WEAPON_AUTOSHOTGUN',
    'WEAPON_MARKSMANRIFLE',
    'WEAPON_CARBINERIFLE_MK2',
    'WEAPON_TECPISTOL',
}) do
    H.ok(NC.isAutomatic(name), 'automatic: ' .. name)
end
for _, name in ipairs({
    'WEAPON_PISTOL',
    'WEAPON_COMBATPISTOL',
    'WEAPON_HEAVYPISTOL',
    'WEAPON_PUMPSHOTGUN',
    'WEAPON_REVOLVER',
    'WEAPON_SNIPERRIFLE',
    'WEAPON_SAWNOFFSHOTGUN',
}) do
    H.ok(not NC.isAutomatic(name), 'not automatic: ' .. name)
end
H.ok(NC.isAutomatic('weapon_smg'), 'names in any case')

-- every automatic weapon is swapped, and the answer is never automatic
local list = NC.automatic()
H.ok(#list >= 30, 'the automatic list is complete (' .. #list .. ')')
for _, name in ipairs(list) do
    local w = NC.weapon(name)
    H.ok(type(w) == 'string' and not NC.isAutomatic(w), name .. ' is swapped for ' .. tostring(w))
end
H.eq(NC.weapon('WEAPON_MICROSMG'), 'WEAPON_PISTOL', 'replace: a micro SMG becomes a pistol')
H.eq(NC.weapon('WEAPON_SMG'), 'WEAPON_COMBATPISTOL', 'replace: an SMG becomes a combat pistol')
H.eq(NC.weapon('WEAPON_ASSAULTRIFLE'), 'WEAPON_HEAVYPISTOL', 'replace: an assault rifle becomes a heavy pistol')
H.eq(NC.weapon('WEAPON_MINIGUN'), 'WEAPON_PISTOL', 'no replace entry: the fallback')
H.eq(NC.weapon('weapon_smg'), 'WEAPON_COMBATPISTOL', 'any case')

-- the owner's list is respected
for _, w in ipairs(cfg.weapons) do H.eq(NC.weapon(w), w, 'a listed weapon stays: ' .. w) end
H.eq(NC.weapon('WEAPON_REVOLVER'), 'WEAPON_PISTOL', 'a weapon outside the list gets the fallback')
cfg.weapons[#cfg.weapons + 1] = 'WEAPON_REVOLVER'
H.eq(NC.weapon('WEAPON_REVOLVER'), 'WEAPON_REVOLVER', 'an owner who adds the revolver gets the revolver')
-- automatics are refused even when the owner adds one, as a weapon, a replacement or the fallback
cfg.weapons[#cfg.weapons + 1] = 'WEAPON_SMG'
H.eq(NC.weapon('WEAPON_SMG'), 'WEAPON_COMBATPISTOL', 'an SMG added to the list is still never given')
cfg.replace.WEAPON_SMG = 'WEAPON_MICROSMG'
H.eq(NC.weapon('WEAPON_SMG'), 'WEAPON_PISTOL', 'an automatic replacement is refused: the fallback')
cfg.fallback = 'WEAPON_ASSAULTRIFLE'
H.eq(NC.weapon('WEAPON_SMG'), 'WEAPON_PISTOL', 'an automatic fallback is refused: a plain pistol')
cfg.weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PUMPSHOTGUN' }
cfg.replace.WEAPON_SMG = 'WEAPON_COMBATPISTOL'
cfg.fallback = 'WEAPON_PISTOL'
H.eq(NC.weapon(nil), nil, 'no weapon: none given')
H.eq(NC.weapon(''), nil, 'an empty name: none')
H.eq(NC.weapon(12345), 'WEAPON_PISTOL', 'not a name: the fallback')

-- off: the weapon as named, 250 rounds (as before)
cfg.enabled = false
H.eq(NC.weapon('WEAPON_SMG'), 'WEAPON_SMG', 'off: nothing is swapped')
H.eq(NC.ammo(), 250, 'off: 250 rounds')
H.eq(NC.capAccuracy(60), 60, 'off: no cap')
H.eq(NC.firingPattern(), nil, 'off: the game picks the firing pattern')
H.eq(NC.aiDamage(), nil, 'off: no damage modifier')
H.eq(NC.cancelLethalHeadshots(), false, 'off: no cancel')
cfg.enabled = true
H.eq(NC.ammo(), 60, 'Config.NpcCombat.ammo')
cfg.ammo = 0
H.eq(NC.ammo(), 1, 'at least one round')
cfg.ammo = 60

-- the Builder check: the allowed list, or an automatic weapon an older custom file names (it loads, with a warning)
local allowed = Config.Builder.allowed.weapons
H.eq(NC.weaponsAllowed({ 'WEAPON_PISTOL' }, allowed), true, 'an allowed weapon')
H.eq(NC.weaponsAllowed({ 'WEAPON_PISTOL', 'WEAPON_SMG' }, allowed), true, 'an older file\'s SMG still loads')
H.eq(NC.weaponsAllowed({ 'WEAPON_RPG' }, allowed), false, 'any other weapon outside the list is refused')
H.eq(NC.weaponsAllowed({}, allowed), false, 'an empty list is refused')
H.eq(NC.weaponsAllowed({ 'WEAPON_RPG' }, nil), true, 'no list (a built-in file): any name')
H.eq(NC.weaponsAllowed({ 42 }, nil), false, 'never a number')
-- Config.NpcCombat.enabled = false: nothing swaps the weapon at the spawn, so the allowed list is the only check again
-- (a crafted Builder draft naming a minigun must not reach an NPC)
cfg.enabled = false
H.eq(NC.weaponsAllowed({ 'WEAPON_PISTOL', 'WEAPON_SMG' }, allowed), false, 'off: an SMG outside the list is refused')
H.eq(NC.weaponsAllowed({ 'WEAPON_MINIGUN' }, allowed), false, 'off: a minigun is refused')
H.eq(NC.weaponsAllowed({ 'WEAPON_PISTOL' }, allowed), true, 'off: an allowed weapon still passes')
H.eq(NC.weaponsAllowed({ 'WEAPON_MINIGUN' }, nil), true, 'off: a built-in file is not limited (as before)')
H.eq(NC.weapon('WEAPON_MINIGUN'), 'WEAPON_MINIGUN', 'off: the weapon as named, which is why the check must hold')
cfg.enabled = true
H.eq(NC.weaponsAllowed({ 'WEAPON_MINIGUN' }, allowed), true, 'on again: an automatic weapon passes (it is swapped)')
H.eq(table.concat(
    NC.automaticsIn({
        weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' },
        ambush = { weapons = { 'WEAPON_MICROSMG' } },
        boss = { weapon = 'WEAPON_ASSAULTRIFLE' },
        label = 'WEAPON_MINIGUN',
    }),
    ','
), 'WEAPON_ASSAULTRIFLE,WEAPON_MICROSMG,WEAPON_SMG', 'automaticsIn finds every weapon and weapons entry')

-- ============================================================================
--             ACCURACY AND FIRING CAPS (CP.NpcCombat, CP.Scaling)
-- ============================================================================

H.eq(NC.capAccuracy(140), 18, 'capped at accuracyMax')
H.eq(NC.capAccuracy(10), 10, 'below the cap: kept')
H.eq(NC.capAccuracy(-5), 0, 'never below 0')
H.eq(math.type(NC.capAccuracy(12.4)), 'integer', 'a whole number (SetPedAccuracy reads an int)')
H.eq(NC.capAccuracy(NC.capAccuracy(40)), 18, 'the cap twice changes nothing')
H.eq(NC.scaleAccuracy(20), 14, 'x accuracyScale 0.7 below the cap')
H.eq(NC.shootRate(), 60, 'shoot rate')
H.eq(NC.firingPattern(), 0x5D60E4E0, 'single: FIRING_PATTERN_SINGLE_SHOT')
cfg.firingPattern = 'burst'
H.eq(NC.firingPattern(), 0xA018DB8A, 'burst: FIRING_PATTERN_BURST_FIRE_PISTOL')
cfg.firingPattern = 'delayed'
H.eq(NC.firingPattern(), 0x7A845691, 'delayed: FIRING_PATTERN_DELAY_FIRE_BY_ONE_SEC')
cfg.firingPattern = 'default'
H.eq(NC.firingPattern(), nil, 'default: the game picks')
cfg.firingPattern = 'single'
H.eq(NC.ability(2), 1, 'professional capped at average')
H.eq(NC.ability(0), 0, 'poor stays poor')
H.eq(NC.driveByAccuracy(60), 18, 'a drive-by is capped too')
H.eq(NC.driveByAccuracy(nil), 18, 'a drive-by of a ped with no accuracy: the cap')
H.eq(NC.driveByPattern(), 0xD31265F2, 'drive-by in bursts (FIRING_PATTERN_BURST_FIRE_DRIVEBY)')
H.eq(math.type(NC.aiDamage()), 'float', 'the AI damage modifier is a float (the native reads one)')
H.eq(NC.officerDefense(), nil, 'officerDefense 1.0 = off')
cfg.officerDefense = 0.02
H.eq(NC.officerDefense(), 0.1, 'the defense modifier is at least 0.1')
cfg.officerDefense = 1.0
-- cancelLethalHeadshots drops a killing hit only on an officer with at least this share of his health
H.eq(NC.lethalCancelAbove(), 0.75, 'shipped: three quarters')
cfg.lethalCancelAbove = 0
H.eq(NC.lethalCancelAbove(), 0.25, 'never below a quarter (a hurt officer can always go down)')
cfg.lethalCancelAbove = 3
H.eq(NC.lethalCancelAbove(), 1.0, 'never above full health')
cfg.lethalCancelAbove = nil
H.eq(NC.lethalCancelAbove(), 0.75, 'missing: three quarters')
cfg.lethalCancelAbove = 0.75

H.load('modules/scaling/server.lua')
local S = CP.Scaling
-- the worst case of the audit: Kingpin waves 30 + 20 (critical) + 8 (hard) = 58 before the cap
Config.NpcDifficulty.preset = 'hard'
H.eq((S.combat(30, 25, 'critical')), 18, 'Kingpin waves at the critical tier on hard: 18, not 58')
Config.NpcDifficulty.preset = 'easy'
H.eq((S.combat(25, 0, 'standard')), 12, 'easy, standard: (25 - 8) x 0.7 = 11.9 -> 12')
Config.NpcDifficulty.preset = 'normal'
cfg.accuracyMax = 40
cfg.accuracyScale = 1.0
H.eq((S.combat(30, 0, 'critical')), 40, 'an owner who raises the cap gets up to it')
cfg.accuracyMax, cfg.accuracyScale = 18, 0.7

-- ============================================================================
--                   A REAL PLAYER'S HIT DROPS THE PROTECTION
-- ============================================================================
-- playerHitDropsProtection, V8.
-- modules/npccombat/server.lua: a weaponDamageEvent from a player who is not on the run, on an active participant of
-- an NPC run, sends that officer one crimson-police:client:npcCombatDrop for the rest of the run.

H.eq(cfg.playerHitDropsProtection, false, 'playerHitDropsProtection ships false (today\'s behaviour)')
H.load('modules/npccombat/server.lua')
H.ok(type(NC.dropFor) == 'function' and type(NC.runStarted) == 'function', 'the server API is there')

-- Player peds are src * 100 with the net id 7000 + src; NPC 50001 (net id 9001) is simulated by player 5's game.
local NPC, NPC_NET = 50001, 9001
local function NET(src) return 7000 + src end
_G.NetworkGetEntityFromNetworkId = function(n)
    n = math.tointeger(tonumber(n) or -1)
    if n == NPC_NET then return NPC end
    if n and n > 7000 and n < 7100 then return (n - 7000) * 100 end
    return 0
end
_G.DoesEntityExist = function(e) return e == NPC or (math.tointeger(e) or 1) % 100 == 0 end
_G.IsPedAPlayer = function(e)
    return e ~= NPC
end -- a server BOOL native: the harness hands it on as 1 / false
_G.NetworkGetEntityOwner = function(e) return e == NPC and 5 or e // 100 end
_G.GetEntityType = function() return 1 end
_G.GetPedInVehicleSeat = function() return 0 end

local R = {
    id = 'run-npc',
    state = 'in_progress',
    npcCombat = true,
    participants = { [1] = { status = 'active' }, [2] = { status = 'active' } },
}
local runOf = { [1] = R, [2] = R }
CP.Runs = {
    getBySrc = function(src) return runOf[src] end,
    isParticipant = function(run, src)
        local pp = run.participants[src]
        return pp ~= nil and pp.status == 'active'
    end,
}
local function Hit(sender, victimNet, fields)
    local data = { hitGlobalIds = { victimNet }, weaponType = 453432689, willKill = false }
    for k, v in pairs(fields or {}) do data[k] = v end
    H.fire('weaponDamageEvent', sender, sender, data)
end
local function Drops(target)
    local n = 0
    for _, e in ipairs(H.findEvents(CP.e('client:npcCombatDrop'))) do
        if e.target == target then n = n + 1 end
    end
    return n
end

H.reset()
Hit(3, NET(1))
H.eq(Drops(1), 0, 'switch off (shipped): a stranger\'s hit on an officer sends nothing')
cfg.playerHitDropsProtection = true   -- read on every event: no restart
Hit(2, NET(1))
H.eq(Drops(1), 0, 'a partner on the same run: nothing')
Hit(5, NET(1), { parentGlobalId = NPC_NET })
H.eq(Drops(1), 0, 'an NPC the sender\'s game moves: nothing')
Hit(3, NPC_NET)
H.eq(#H.findEvents(CP.e('client:npcCombatDrop')), 0, 'a hit on an NPC: nothing')
Hit(3, NET(1))
H.eq(Drops(1), 1, 'a player who is not on the run shoots an officer: one npcCombatDrop to him')
local ev = H.findEvents(CP.e('client:npcCombatDrop'))[1]
H.eq(ev and ev.args[1], 'run-npc', 'it names his run')
Hit(3, NET(1))
Hit(4, NET(1))
H.eq(Drops(1), 1, 'a second hit sends nothing (once per run and officer)')
H.eq(Drops(2), 0, 'his partner keeps the protection')
Hit(3, NET(2))
H.eq(Drops(2), 1, 'until he is shot too')
H.eq(NC.dropFor(R, 3), false, 'never to someone who is not on the run')

-- test runs and runs with a real suspect (V14, V22) never drop on a hit
H.reset()
local T = { id = 'run-test', state = 'in_progress', test = {}, participants = { [6] = { status = 'active' } } }
local V = {
    id = 'run-vol',
    state = 'in_progress',
    realSuspect = 'volunteer',
    participants = { [7] = { status = 'active' } },
}
runOf[6], runOf[7] = T, V
Hit(3, NET(6))
Hit(3, NET(7))
H.eq(#H.findEvents(CP.e('client:npcCombatDrop')), 0, 'a test run and a real-suspect run: nothing on a hit')
H.eq(NC.dropFor(V, 7, 'volunteer'), true, 'V22 still drops it for a volunteer run itself')

-- the run ended: the next run of the same officer can drop again
CP.Hooks.fire('run:ended', R, 'completed', 'completed')
H.reset()
Hit(3, NET(1))
H.eq(Drops(1), 1, 'a new run: a stranger\'s hit drops it again')
cfg.playerHitDropsProtection = false
H.reset()
Hit(3, NET(2))
H.eq(#H.findEvents(CP.e('client:npcCombatDrop')), 0, 'switched off in Settings: nothing at once')
CP.Runs = nil

-- ============================================================================
--           THE OFFICER'S GAME (separate Lua state, a child process)
-- ============================================================================

local p = io.popen('lua5.4 tests/fixtures/npccombat/client_check.lua 2>&1')
local out = p:read('a')
p:close()
local cp, cf = out:match('RESULT (%d+) (%d+)')
cp, cf = tonumber(cp), tonumber(cf)
if not cp then
    print(out)
    H.ok(false, 'the npccombat client checks crashed')
else
    H.passes = H.passes + cp
    H.failures = H.failures + cf
    if cf > 0 then print(out) end
    H.ok(cp > 25, 'the npccombat client checks ran')
end

return H
