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
  ON the compound's own roads (the courtyard loop, yard lanes and driveways of the GTA V vehicle-node
  network, z = road height + 1 m), so nothing spawns inside a house, barn or shed; the start is on the
  compound's driveway (within 7.5 m of the compound's height), 30 m+ from every spawn.
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
      start  = { coords = vec3(1330.75, 1121.00, 107.06), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(1368.50, 1135.00, 113.75, 110.3), vec4(1368.75, 1145.38, 113.75, 122.7),
        vec4(1358.00, 1140.12, 113.75, 125.1), vec4(1370.50, 1129.25, 113.91, 101.7),
        vec4(1353.75, 1144.75, 113.75, 135.9), vec4(1368.00, 1152.25, 113.75, 130.0),
        vec4(1353.75, 1151.25, 113.75, 142.8), vec4(1361.50, 1155.75, 113.75, 138.5),
        vec4(1373.00, 1123.75, 114.16, 93.7), vec4(1361.25, 1163.25, 113.66, 144.2),
        vec4(1377.50, 1119.75, 114.44, 88.5), vec4(1361.25, 1170.19, 113.12, 148.2),
        vec4(1361.25, 1177.00, 112.75, 151.4), vec4(1361.25, 1183.67, 112.54, 154.0),
        vec4(1365.33, 1188.08, 112.69, 152.7), vec4(1371.46, 1188.21, 112.97, 148.8),
        vec4(1355.25, 1188.00, 112.19, 159.9), vec4(1377.50, 1188.25, 113.16, 145.2),
      },
      boss   = vec4(1365.50, 1140.25, 113.75, 119.0),   -- the Kingpin, on the yard road nearest the house (open ground)
      scene  = vec3(1365.00, 1154.50, 112.95),   -- "Secure the scene" point
    },
    {
      label  = "O'Neil Ranch, Grapeseed",
      start  = { coords = vec3(2429.00, 4900.00, 40.16), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(2452.25, 4947.88, 45.12, 154.1), vec4(2442.75, 4938.20, 45.11, 160.2),
        vec4(2457.25, 4952.75, 45.12, 151.8), vec4(2438.38, 4933.44, 45.00, 164.3),
        vec4(2461.75, 4957.70, 45.12, 150.4), vec4(2466.38, 4962.67, 45.18, 149.2),
        vec4(2469.16, 4956.22, 45.10, 144.5), vec4(2417.00, 4969.25, 46.16, 189.8),
        vec4(2473.56, 4951.44, 45.08, 139.1), vec4(2421.88, 4975.38, 45.92, 185.4),
        vec4(2411.25, 4963.00, 45.58, 195.7), vec4(2471.25, 4967.67, 45.33, 148.0),
        vec4(2426.25, 4980.42, 45.86, 182.0), vec4(2478.06, 4946.94, 44.93, 133.7),
        vec4(2432.00, 4985.50, 45.88, 178.0), vec4(2405.50, 4957.25, 44.38, 202.3),
        vec4(2475.56, 4973.06, 45.52, 147.5), vec4(2437.00, 4991.00, 46.00, 175.0),
      },
      boss   = vec4(2447.25, 4943.00, 45.12, 157.0),   -- the Kingpin, on the yard road nearest the house (open ground)
      scene  = vec3(2466.22, 4959.41, 44.32),   -- "Secure the scene" point
    },
    {
      label  = 'Marlowe Vineyards, Tongva Hills',
      start  = { coords = vec3(-1852.75, 2031.75, 135.53), radius = 100.0 },   -- the approach, within 100 m of the compound
      spawns = {   -- 18 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(-1905.75, 2031.17, 140.72, 270.6), vec4(-1910.08, 2044.62, 140.72, 257.3),
        vec4(-1899.83, 2027.42, 140.72, 275.3), vec4(-1910.50, 2053.00, 140.72, 249.8),
        vec4(-1895.58, 2022.42, 140.76, 282.3), vec4(-1911.00, 2059.50, 140.72, 244.5),
        vec4(-1893.33, 2016.67, 140.99, 290.4), vec4(-1916.50, 2064.00, 140.59, 243.2),
        vec4(-1890.42, 2011.42, 141.43, 298.4), vec4(-1895.50, 2006.75, 141.66, 300.3),
        vec4(-1884.50, 2007.75, 141.66, 307.1), vec4(-1922.00, 2068.50, 140.47, 242.0),
        vec4(-1877.00, 2008.50, 141.50, 313.8), vec4(-1897.88, 2000.00, 141.78, 305.1),
        vec4(-1878.00, 2002.50, 142.00, 319.2), vec4(-1923.75, 2076.62, 139.47, 237.7),
        vec4(-1897.00, 1994.00, 141.94, 310.5), vec4(-1878.81, 1994.50, 142.53, 325.0),
      },
      boss   = vec4(-1909.58, 2038.25, 140.72, 263.5),   -- the Kingpin, on the yard road nearest the house (open ground)
      scene  = vec3(-1909.25, 2034.00, 139.92),   -- "Secure the scene" point
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
