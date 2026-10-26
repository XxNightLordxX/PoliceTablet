-- CP.NpcCombat (shared): which weapon a mission NPC may carry, and its accuracy and firing caps (Config.NpcCombat).

CP.NpcCombat = CP.NpcCombat or {}
local NpcCombat = CP.NpcCombat

local SAFE_WEAPON = 'WEAPON_PISTOL'      -- when even the fallback is unusable
local DEFAULT_AMMO = 60
local LEGACY_AMMO = 250                  -- Config.NpcCombat.enabled = false: as before
local MAX_AMMO = 9999
local LEGACY_DRIVEBY_ACCURACY = 60
local MAX_DEPTH = 8
local DEFAULT_LETHAL_ABOVE = 0.75        -- cancelLethalHeadshots: only an officer with three quarters of his health...
local MIN_LETHAL_ABOVE = 0.25            -- ...and never one below a quarter (he can always go down)

-- FIRING_PATTERN_* hashes (natives.json SET_PED_FIRING_PATTERN 0x9AC577F5A12AD8A9)
local PATTERNS = {
    single = 0x5D60E4E0,    -- FIRING_PATTERN_SINGLE_SHOT
    burst = 0xA018DB8A,     -- FIRING_PATTERN_BURST_FIRE_PISTOL
    delayed = 0x7A845691,   -- FIRING_PATTERN_DELAY_FIRE_BY_ONE_SEC
}
local DRIVEBY_PATTERN = 0xD31265F2      -- FIRING_PATTERN_BURST_FIRE_DRIVEBY
local FULL_AUTO = 0xC6EE6B4C            -- FIRING_PATTERN_FULL_AUTO (only with Config.NpcCombat.enabled = false)

-- Every weapon whose game data carries the Automatic flag (gta-v-data-dumps weapons.json). None is ever given to a
-- mission NPC, whatever Config.NpcCombat.weapons says.
local AUTOMATIC = {}
for _, name in ipairs({
    'WEAPON_ADVANCEDRIFLE',
    'WEAPON_APPISTOL',
    'WEAPON_ASSAULTRIFLE',
    'WEAPON_ASSAULTRIFLE_MK2',
    'WEAPON_ASSAULTSMG',
    'WEAPON_AUTOSHOTGUN',
    'WEAPON_BATTLERIFLE',
    'WEAPON_BULLPUPRIFLE',
    'WEAPON_BULLPUPRIFLE_MK2',
    'WEAPON_CARBINERIFLE',
    'WEAPON_CARBINERIFLE_MK2',
    'WEAPON_COMBATMG',
    'WEAPON_COMBATMG_MK2',
    'WEAPON_COMBATPDW',
    'WEAPON_COMPACTRIFLE',
    'WEAPON_GUSENBERG',
    'WEAPON_HEAVYRIFLE',
    'WEAPON_MACHINEPISTOL',
    'WEAPON_MARKSMANRIFLE',
    'WEAPON_MARKSMANRIFLE_MK2',
    'WEAPON_MG',
    'WEAPON_MICROSMG',
    'WEAPON_MILITARYRIFLE',
    'WEAPON_MINIGUN',
    'WEAPON_MINISMG',
    'WEAPON_RAYCARBINE',
    'WEAPON_RAYMINIGUN',
    'WEAPON_SMG',
    'WEAPON_SMG_MK2',
    'WEAPON_SPECIALCARBINE',
    'WEAPON_SPECIALCARBINE_MK2',
    'WEAPON_STRICKLER',
    'WEAPON_TACTICALRIFLE',
    'WEAPON_TECPISTOL',
}) do
    AUTOMATIC[name] = true
end

local function Cfg()
    local c = Config and Config.NpcCombat
    return type(c) == 'table' and c or {}
end

local function On() return Cfg().enabled ~= false end

function NpcCombat.enabled() return On() end

local function Name(v)
    if type(v) ~= 'string' then return nil end
    local s = v:match('^%s*(.-)%s*$'):upper()
    if s == '' then return nil end
    return s
end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function Number(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

local function InList(list, name)
    if type(list) ~= 'table' then return false end
    for _, w in ipairs(list) do
        if Name(w) == name then return true end
    end
    return false
end

-- Config.NpcCombat.fallback when it is not automatic, else WEAPON_PISTOL.
local function Fallback(c)
    local f = Name(c.fallback)
    if f and not AUTOMATIC[f] then return f end
    return SAFE_WEAPON
end

-- ============================================================================
--                                   WEAPONS
-- ============================================================================

-- Every automatic weapon name (a copy).
function NpcCombat.automatic()
    local out = {}
    for name in pairs(AUTOMATIC) do out[#out + 1] = name end
    table.sort(out)
    return out
end

function NpcCombat.isAutomatic(name)
    local n = Name(name)
    return n ~= nil and AUTOMATIC[n] == true
end

-- The weapon a mission NPC is given for the weapon a mission names (nil: no weapon): the name itself when it is in
-- Config.NpcCombat.weapons, else what Config.NpcCombat.replace gives for it, else Config.NpcCombat.fallback. The
-- answer is never an automatic weapon, whatever the lists say. With Config.NpcCombat.enabled = false: the name.
function NpcCombat.weapon(name)
    if name == nil or name == false or name == '' then return nil end
    local c = Cfg()
    if c.enabled == false then return name end
    local n = Name(name)
    if not n then return Fallback(c) end
    if not AUTOMATIC[n] and InList(c.weapons, n) then return n end
    if type(c.replace) == 'table' then
        for k, v in pairs(c.replace) do
            if Name(k) == n then
                local r = Name(v)
                if r and not AUTOMATIC[r] then return r end
                break
            end
        end
    end
    return Fallback(c)
end

-- A weapon list a mission may name (the Mission Builder's check): every name a text, and in the allowed list when one
-- is given, or an automatic weapon while Config.NpcCombat is on. An older custom file that still names one keeps
-- loading: CP.Missions warns about it in the console, and each NPC carries the weapon CP.NpcCombat.weapon gives
-- instead. With Config.NpcCombat.enabled = false nothing is swapped, so the allowed list is the only check again (the
-- missions reload when the switch changes in Settings).
function NpcCombat.weaponsAllowed(list, allowed)
    if type(list) ~= 'table' or #list == 0 then return false end
    local swapped = On()
    for _, v in ipairs(list) do
        if type(v) ~= 'string' then return false end
        if type(allowed) == 'table' and not (swapped and AUTOMATIC[Name(v) or '']) then
            local found = false
            for _, a in ipairs(allowed) do
                if a == v then
                    found = true
                    break
                end
            end
            if not found then return false end
        end
    end
    return true
end

-- The rounds an armed mission NPC gets.
function NpcCombat.ammo()
    if not On() then return LEGACY_AMMO end
    local n = Number(Cfg().ammo)
    if not n then return DEFAULT_AMMO end
    return math.floor(Clamp(n, 1, MAX_AMMO))
end

-- The automatic weapon names an objective (or any part of a mission) names: every `weapon` text and every text of a
-- `weapons` list, at any depth. For the console warning of a mission that still names one.
function NpcCombat.automaticsIn(v)
    local out, seen = {}, {}
    local function add(x)
        local n = Name(x)
        if n and AUTOMATIC[n] and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    local function walk(t, depth)
        if type(t) ~= 'table' or depth > MAX_DEPTH then return end
        for k, x in pairs(t) do
            if k == 'weapon' then
                add(x)
            elseif k == 'weapons' and type(x) == 'table' then
                for _, w in ipairs(x) do add(w) end
            elseif type(x) == 'table' then
                walk(x, depth + 1)
            end
        end
    end
    walk(v, 1)
    table.sort(out)
    return out
end

-- ============================================================================
--                          ACCURACY AND FIRING (CAPS)
-- ============================================================================

-- The accuracy cap (0-100), or nil when Config.NpcCombat is off.
function NpcCombat.accuracyMax()
    if not On() then return nil end
    local m = Number(Cfg().accuracyMax)
    if not m then return nil end
    return Clamp(m, 0, 100)
end

-- At most the cap (old bags, custom cfg): never scaled, so applying it twice changes nothing. A whole number 0-100.
function NpcCombat.capAccuracy(acc)
    acc = Number(acc)
    if not acc then return nil end
    local max = NpcCombat.accuracyMax()
    if max and acc > max then acc = max end
    return math.floor(Clamp(acc, 0, 100) + 0.5)
end

-- The server's final accuracy (after the tier and Config.NpcDifficulty): times accuracyScale, then the cap.
function NpcCombat.scaleAccuracy(acc)
    acc = Number(acc)
    if not acc then return nil end
    if On() then
        local s = Number(Cfg().accuracyScale)
        if s and s >= 0 then acc = acc * s end
    end
    return NpcCombat.capAccuracy(acc)
end

-- SetPedShootRate's value (0-1000), or nil (leave the game's).
function NpcCombat.shootRate()
    if not On() then return nil end
    local r = Number(Cfg().shootRate)
    if not r then return nil end
    return math.floor(Clamp(r, 0, 1000) + 0.5)
end

-- The FIRING_PATTERN_* hash of Config.NpcCombat.firingPattern, or nil ('default': the game picks).
function NpcCombat.firingPattern()
    if not On() then return nil end
    return PATTERNS[Cfg().firingPattern]
end

-- The combat ability (0 poor, 1 average, 2 professional) at most abilityMax.
function NpcCombat.ability(a)
    a = math.floor(Clamp(Number(a) or 1, 0, 2))
    if not On() then return a end
    local m = Number(Cfg().abilityMax)
    if m and a > m then a = math.floor(Clamp(m, 0, 2)) end
    return a
end

function NpcCombat.noCharge() return On() and Cfg().noCharge ~= false end

-- The drive-by accuracy (TaskDriveBy pedAccuracy) for the NPC's own accuracy, and the drive-by firing pattern.
function NpcCombat.driveByAccuracy(acc)
    if not On() then return LEGACY_DRIVEBY_ACCURACY end
    local a = NpcCombat.capAccuracy(acc or NpcCombat.accuracyMax() or LEGACY_DRIVEBY_ACCURACY)
    return a or 0
end

function NpcCombat.driveByPattern()
    if not On() then return FULL_AUTO end
    return DRIVEBY_PATTERN
end

-- ============================================================================
--                   DAMAGE TO OFFICERS (WHILE A RUN IS LIVE)
-- ============================================================================

local function Modifier(key, lo, hi)
    if not On() then return nil end
    local v = Number(Cfg()[key])
    if not v then return nil end
    return Clamp(v, lo, hi) + 0.0
end

-- SetAiWeaponDamageModifier / SetAiMeleeWeaponDamageModifier values, or nil (leave the game's).
function NpcCombat.aiDamage() return Modifier('aiDamage', 0.0, 2.0) end

function NpcCombat.aiMeleeDamage() return Modifier('aiMeleeDamage', 0.0, 2.0) end

-- True when the run's AI damage values go on again every second of the run (holdAiDamage; missing = true).
function NpcCombat.holdAiDamage() return On() and Cfg().holdAiDamage ~= false end

-- SetPlayerWeaponDefenseModifier's value, or nil when it is 1.0 (off).
function NpcCombat.officerDefense()
    local v = Modifier('officerDefense', 0.1, 2.0)
    if not v or math.abs(v - 1.0) < 1e-6 then return nil end
    return v
end

function NpcCombat.noCriticalHits() return On() and Cfg().noCriticalHits == true end

function NpcCombat.cancelLethalHeadshots() return On() and Cfg().cancelLethalHeadshots == true end

-- The share of his health (0.25-1) an officer needs for cancelLethalHeadshots to drop a killing hit: below it the hit
-- that finishes him off counts, so a hurt officer can always go down.
function NpcCombat.lethalCancelAbove()
    local v = Number(Cfg().lethalCancelAbove)
    if not v then return DEFAULT_LETHAL_ABOVE end
    return Clamp(v, MIN_LETHAL_ABOVE, 1.0)
end

NpcCombat.PATTERNS = PATTERNS
NpcCombat.DRIVEBY_PATTERN = DRIVEBY_PATTERN
