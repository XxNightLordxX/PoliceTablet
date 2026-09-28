--[[ Crimson-Police · built-in mission: Weekly Boss: Kingpin (weekly_boss_kingpin)
  Tactical event card · 1–4 officers · ★★★ · time limit 15 min · once per officer per week, Friday–Sunday
  The Kingpin's crew holds a remote compound: 30 hostiles (scale) in 4 waves of 8 / 8 / 7 / 7 with pistols,
  SMGs and shotguns (accuracy 30, armour 25, plus the tier), then the Kingpin himself (health 400, armour
  100, assault rifle; does not scale), then "Secure the scene". Armed NPCs before scaling: 30 + the
  Kingpin = 31 (within Config.Builder.maxHostiles = 40).
  Points and payout come from Config.Events.weeklyBoss (500 points, $2,500 base); there is no payout
  field. The weekly limit is enforced by CP.Events.bossAvailable, not by the cooldown below.
  Locations (3 compounds, large remote properties outside every no-build zone): La Fuente Blanca ranch
  (the Madrazo ranch, Tataviam foothills east of Vinewood Hills), O'Neil Ranch (Grapeseed) and Marlowe
  Vineyards (Tongva Hills). Each has 18 hostile spawn points, the Kingpin's spawn and a scene marker, all
  in front of the main house's facade (towards the approach), so nothing spawns inside the buildings.
  Blocks: hostile_waves (with boss) → interact_points.
]]

RegisterMission({
  id           = 'weekly_boss_kingpin',
  label        = 'Weekly Boss: Kingpin',
  description  = 'The Kingpin and his crew are dug in at a remote compound. Fight through four waves of gunmen, take down the Kingpin and secure the scene.',
  type         = 'tactical',      -- counts as Tactical; points and payout from Config.Events.weeklyBoss
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 900,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer; the weekly limit is Config.Events
  vehiclePenalties = false,       -- vehicles take gunfire here, so no heavy-damage penalty

  locations = {
    {
      label  = 'La Fuente Blanca ranch, Tataviam foothills',
      start  = { coords = vec3(1304.00, 1125.72, 112.00), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points in front of the main house, facing the approach
        vec4(1387.42, 1131.19, 114.20, 93.8), vec4(1386.15, 1152.19, 114.20, 107.9),
        vec4(1381.00, 1136.46, 114.20, 97.9), vec4(1378.21, 1143.68, 114.20, 103.6),
        vec4(1377.93, 1124.54, 114.20, 89.1), vec4(1374.19, 1152.62, 114.20, 111.0),
        vec4(1368.13, 1135.20, 114.20, 98.4), vec4(1368.56, 1118.32, 114.20, 83.5),
        vec4(1360.26, 1155.04, 114.20, 117.5), vec4(1360.01, 1125.95, 114.20, 90.2),
        vec4(1354.95, 1144.25, 114.20, 110.0), vec4(1393.15, 1124.59, 114.20, 89.3),
        vec4(1388.76, 1158.14, 114.20, 110.9), vec4(1387.60, 1116.91, 114.20, 84.0),
        vec4(1380.35, 1163.76, 114.20, 116.5), vec4(1381.74, 1113.84, 114.20, 81.3),
        vec4(1375.29, 1111.28, 114.20, 78.6), vec4(1350.54, 1136.47, 114.20, 103.0),
      },
      boss   = vec4(1392.63, 1141.35, 114.30, 100.0),   -- the Kingpin, on the front step (outside the walls)
      scene  = vec3(1388.69, 1140.66, 114.30),   -- "Secure the scene" point
    },
    {
      label  = "O'Neil Ranch, Grapeseed",
      start  = { coords = vec3(2440.00, 4878.00, 45.60), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points in front of the main house, facing the approach
        vec4(2451.50, 4961.70, 46.80, 172.2), vec4(2430.60, 4960.20, 46.80, 186.5),
        vec4(2444.30, 4956.60, 46.80, 176.9), vec4(2433.40, 4957.80, 46.80, 184.7),
        vec4(2453.10, 4948.80, 46.80, 169.5), vec4(2424.20, 4950.30, 46.80, 192.3),
        vec4(2438.80, 4942.50, 46.80, 181.1), vec4(2461.20, 4941.20, 46.80, 161.5),
        vec4(2420.00, 4939.40, 46.80, 198.0), vec4(2447.70, 4932.90, 46.80, 172.0),
        vec4(2431.80, 4932.00, 46.80, 188.6), vec4(2457.60, 4966.60, 46.80, 168.8),
        vec4(2422.00, 4966.30, 46.80, 191.5), vec4(2463.10, 4959.30, 46.80, 164.1),
        vec4(2416.30, 4959.00, 46.80, 196.3), vec4(2464.70, 4953.20, 46.80, 161.8),
        vec4(2465.80, 4945.20, 46.80, 159.0), vec4(2438.20, 4925.60, 46.80, 182.2),
      },
      boss   = vec4(2440.00, 4968.00, 46.60, 180.0),   -- the Kingpin, on the front step (outside the walls)
      scene  = vec3(2440.00, 4964.00, 46.60),   -- "Secure the scene" point
    },
    {
      label  = 'Marlowe Vineyards, Tongva Hills',
      start  = { coords = vec3(-1796.00, 2050.00, 139.50), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points in front of the main house, facing the approach
        vec4(-1880.60, 2059.70, 141.20, 263.5), vec4(-1881.80, 2041.80, 141.20, 275.5),
        vec4(-1872.80, 2052.50, 141.20, 268.1), vec4(-1874.30, 2044.90, 141.20, 273.7),
        vec4(-1866.50, 2065.50, 141.20, 257.6), vec4(-1869.20, 2036.60, 141.20, 280.4),
        vec4(-1861.40, 2050.30, 141.20, 269.7), vec4(-1858.90, 2069.40, 141.20, 252.9),
        vec4(-1858.00, 2029.10, 141.20, 288.6), vec4(-1849.10, 2056.20, 141.20, 263.3),
        vec4(-1851.50, 2038.80, 141.20, 281.4), vec4(-1883.80, 2066.80, 141.20, 259.2),
        vec4(-1884.80, 2032.70, 141.20, 281.0), vec4(-1876.50, 2074.10, 141.20, 253.3),
        vec4(-1877.70, 2025.50, 141.20, 286.7), vec4(-1870.70, 2074.60, 141.20, 251.8),
        vec4(-1863.10, 2076.30, 141.20, 248.6), vec4(-1844.60, 2047.70, 141.20, 272.7),
      },
      boss   = vec4(-1886.00, 2050.00, 141.00, 270.0),   -- the Kingpin, on the front step (outside the walls)
      scene  = vec3(-1882.00, 2050.00, 141.00),   -- "Secure the scene" point
    },
  },

  objectives = {
    {
      block        = 'hostile_waves',
      label        = "Break the Kingpin's crew",
      minSeconds   = 90,
      waves        = { 8, 8, 7, 7 },                           -- 30 hostiles, scaled by tier
      nextWave     = { aliveAtMost = 2, afterSeconds = 90 },
      weapons      = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN' },
      accuracy     = 30,                                       -- plus the tier's accuracy
      armour       = 25,                                       -- plus the tier's armour
      surrender    = { belowHealth = 0.25, chance = 0.30 },
      boss         = {                                         -- after the last wave; does not scale
        model     = 'g_m_m_armboss_01',
        label     = 'The Kingpin',
        health    = 400,
        armour    = 100,
        weapon    = 'WEAPON_ASSAULTRIFLE',
        spawn     = 'boss',
        surrender = { belowHealth = 0.25, chance = 0.30 },     -- he can be taken alive
      },
      blockTraffic = 120.0,
    },
    {
      block      = 'interact_points',
      label      = 'Secure the scene',
      minSeconds = 8,
      points     = 'scene',
      progress   = { label = 'Securing scene', duration = 8000 },
    },
  },

  scaling   = { 'objectives.1.waves' },    -- hostiles (the Kingpin does not scale)
  items     = {},                          -- no items for this mission
  bonuses   = {
    { id = 'kingpin_alive', points = 50 },                 -- Kingpin arrested alive
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
  },
  penalties = {},                          -- the common penalties always apply
})
