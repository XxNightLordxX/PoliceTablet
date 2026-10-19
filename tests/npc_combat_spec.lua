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
