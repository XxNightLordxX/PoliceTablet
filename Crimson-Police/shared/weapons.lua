-- CP.Weapons (shared): the names of the common GTA weapons by hash, so the Real suspects damage ledger
-- reads "Combat Pistol" and not 1593441988. Built once at load (joaat of each weapon name); a hash not in the table
-- reads as the hash itself.

CP.Weapons = CP.Weapons or {}
local Weapons = CP.Weapons

-- The weapon names (GTA's WEAPON_ codes) and the label shown for each.
local NAMES = {
    -- melee
    { 'WEAPON_UNARMED', 'Fists' },
    { 'WEAPON_KNIFE', 'Knife' },
    { 'WEAPON_NIGHTSTICK', 'Nightstick' },
    { 'WEAPON_HAMMER', 'Hammer' },
    { 'WEAPON_BAT', 'Baseball Bat' },
    { 'WEAPON_CROWBAR', 'Crowbar' },
    { 'WEAPON_GOLFCLUB', 'Golf Club' },
    { 'WEAPON_BOTTLE', 'Broken Bottle' },
    { 'WEAPON_DAGGER', 'Antique Dagger' },
    { 'WEAPON_HATCHET', 'Hatchet' },
    { 'WEAPON_KNUCKLE', 'Knuckle Duster' },
    { 'WEAPON_MACHETE', 'Machete' },
    { 'WEAPON_SWITCHBLADE', 'Switchblade' },
    { 'WEAPON_WRENCH', 'Pipe Wrench' },
    { 'WEAPON_BATTLEAXE', 'Battle Axe' },
    { 'WEAPON_POOLCUE', 'Pool Cue' },
    { 'WEAPON_STONE_HATCHET', 'Stone Hatchet' },
    { 'WEAPON_FLASHLIGHT', 'Flashlight' },
    -- handguns
    { 'WEAPON_PISTOL', 'Pistol' },
    { 'WEAPON_PISTOL_MK2', 'Pistol Mk II' },
    { 'WEAPON_COMBATPISTOL', 'Combat Pistol' },
    { 'WEAPON_APPISTOL', 'AP Pistol' },
    { 'WEAPON_STUNGUN', 'Stun Gun' },
    { 'WEAPON_STUNGUN_MP', 'Stun Gun' },
    { 'WEAPON_PISTOL50', 'Pistol .50' },
    { 'WEAPON_SNSPISTOL', 'SNS Pistol' },
    { 'WEAPON_SNSPISTOL_MK2', 'SNS Pistol Mk II' },
    { 'WEAPON_HEAVYPISTOL', 'Heavy Pistol' },
    { 'WEAPON_VINTAGEPISTOL', 'Vintage Pistol' },
    { 'WEAPON_FLAREGUN', 'Flare Gun' },
    { 'WEAPON_MARKSMANPISTOL', 'Marksman Pistol' },
    { 'WEAPON_REVOLVER', 'Heavy Revolver' },
    { 'WEAPON_REVOLVER_MK2', 'Heavy Revolver Mk II' },
    { 'WEAPON_DOUBLEACTION', 'Double-Action Revolver' },
    { 'WEAPON_CERAMICPISTOL', 'Ceramic Pistol' },
    { 'WEAPON_NAVYREVOLVER', 'Navy Revolver' },
    { 'WEAPON_GADGETPISTOL', 'Perico Pistol' },
    -- submachine guns
    { 'WEAPON_MICROSMG', 'Micro SMG' },
    { 'WEAPON_SMG', 'SMG' },
    { 'WEAPON_SMG_MK2', 'SMG Mk II' },
    { 'WEAPON_ASSAULTSMG', 'Assault SMG' },
    { 'WEAPON_COMBATPDW', 'Combat PDW' },
    { 'WEAPON_MACHINEPISTOL', 'Machine Pistol' },
    { 'WEAPON_MINISMG', 'Mini SMG' },
    { 'WEAPON_GUSENBERG', 'Gusenberg Sweeper' },
    -- shotguns
    { 'WEAPON_PUMPSHOTGUN', 'Pump Shotgun' },
    { 'WEAPON_PUMPSHOTGUN_MK2', 'Pump Shotgun Mk II' },
    { 'WEAPON_SAWNOFFSHOTGUN', 'Sawed-Off Shotgun' },
    { 'WEAPON_ASSAULTSHOTGUN', 'Assault Shotgun' },
    { 'WEAPON_BULLPUPSHOTGUN', 'Bullpup Shotgun' },
    { 'WEAPON_MUSKET', 'Musket' },
    { 'WEAPON_HEAVYSHOTGUN', 'Heavy Shotgun' },
    { 'WEAPON_DBSHOTGUN', 'Double Barrel Shotgun' },
    { 'WEAPON_AUTOSHOTGUN', 'Sweeper Shotgun' },
    { 'WEAPON_COMBATSHOTGUN', 'Combat Shotgun' },
    -- rifles
    { 'WEAPON_ASSAULTRIFLE', 'Assault Rifle' },
    { 'WEAPON_ASSAULTRIFLE_MK2', 'Assault Rifle Mk II' },
    { 'WEAPON_CARBINERIFLE', 'Carbine Rifle' },
    { 'WEAPON_CARBINERIFLE_MK2', 'Carbine Rifle Mk II' },
    { 'WEAPON_ADVANCEDRIFLE', 'Advanced Rifle' },
    { 'WEAPON_SPECIALCARBINE', 'Special Carbine' },
    { 'WEAPON_SPECIALCARBINE_MK2', 'Special Carbine Mk II' },
    { 'WEAPON_BULLPUPRIFLE', 'Bullpup Rifle' },
    { 'WEAPON_BULLPUPRIFLE_MK2', 'Bullpup Rifle Mk II' },
    { 'WEAPON_COMPACTRIFLE', 'Compact Rifle' },
    { 'WEAPON_MILITARYRIFLE', 'Military Rifle' },
    { 'WEAPON_HEAVYRIFLE', 'Heavy Rifle' },
    { 'WEAPON_TACTICALRIFLE', 'Service Carbine' },
    -- machine guns
    { 'WEAPON_MG', 'MG' },
    { 'WEAPON_COMBATMG', 'Combat MG' },
    { 'WEAPON_COMBATMG_MK2', 'Combat MG Mk II' },
    -- sniper rifles
    { 'WEAPON_SNIPERRIFLE', 'Sniper Rifle' },
    { 'WEAPON_HEAVYSNIPER', 'Heavy Sniper' },
    { 'WEAPON_HEAVYSNIPER_MK2', 'Heavy Sniper Mk II' },
    { 'WEAPON_MARKSMANRIFLE', 'Marksman Rifle' },
    { 'WEAPON_MARKSMANRIFLE_MK2', 'Marksman Rifle Mk II' },
    { 'WEAPON_PRECISIONRIFLE', 'Precision Rifle' },
    -- heavy weapons and throwables
    { 'WEAPON_RPG', 'RPG' },
    { 'WEAPON_GRENADELAUNCHER', 'Grenade Launcher' },
    { 'WEAPON_GRENADELAUNCHER_SMOKE', 'Smoke Grenade Launcher' },
    { 'WEAPON_MINIGUN', 'Minigun' },
    { 'WEAPON_COMPACTLAUNCHER', 'Compact Grenade Launcher' },
    { 'WEAPON_GRENADE', 'Grenade' },
    { 'WEAPON_STICKYBOMB', 'Sticky Bomb' },
    { 'WEAPON_PIPEBOMB', 'Pipe Bomb' },
    { 'WEAPON_MOLOTOV', 'Molotov Cocktail' },
    { 'WEAPON_BZGAS', 'BZ Gas' },
    { 'WEAPON_SMOKEGRENADE', 'Tear Gas' },
    { 'WEAPON_FLARE', 'Flare' },
    { 'WEAPON_PETROLCAN', 'Jerry Can' },
    { 'WEAPON_FIREEXTINGUISHER', 'Fire Extinguisher' },
    { 'WEAPON_BALL', 'Ball' },
    { 'WEAPON_SNOWBALL', 'Snowball' },
    -- not a weapon in the hand
    { 'WEAPON_RUN_OVER_BY_CAR', 'Run over by a vehicle' },
    { 'WEAPON_RAMMED_BY_CAR', 'Rammed by a vehicle' },
    { 'WEAPON_FALL', 'Fall' },
    { 'WEAPON_EXPLOSION', 'Explosion' },
    { 'WEAPON_FIRE', 'Fire' },
    { 'WEAPON_DROWNING', 'Drowning' },
    { 'WEAPON_BLEEDING', 'Bleeding' },
}

-- [hash as an unsigned 32-bit number] = label (a hash may come signed or unsigned: both read the same).
local byHash = {}

local function U32(h)
    local n = math.tointeger(tonumber(h))
    if not n then return nil end
    return n & 0xFFFFFFFF
end

for _, w in ipairs(NAMES) do
    local h = U32(joaat(w[1]))
    if h and byHash[h] == nil then byHash[h] = w[2] end
end

-- The label of a weapon hash (signed or unsigned), or nil when it is not one of the common weapons.
function Weapons.label(hash)
    local h = U32(hash)
    return h and byHash[h] or nil
end

-- The label, else the hash as text ('#<hash>'), else nil for no hash.
function Weapons.text(hash)
    local h = U32(hash)
    if not h or h == 0 then return nil end
    return byHash[h] or ('#' .. tostring(h))
end

Weapons.count = #NAMES
