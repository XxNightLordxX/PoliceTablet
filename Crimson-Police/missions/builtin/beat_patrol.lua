--[[ Crimson-Police · built-in mission
  Beat Patrol · beat_patrol · Patrol · 1 officer · 1 star · 8 min · cooldown 10 min
  Drive a district beat: 5 of the district's checkpoints in order, holding 10 s inside each
  10 m marker while driving a vehicle (any vehicle; the server checks the driver seat).
  Markers and blips only; nothing spawns.
  Districts: Strawberry & Davis, La Mesa & Mirror Park, Harmony & Route 68, Sandy Shores,
  Paleto Bay, and Banham Canyon & Chumash on the Great Ocean Highway. Every checkpoint is a
  public road (on a road node), fuel forecourt or car park, never at a police station or
  hospital; heights are ground + 1 m.
  Blocks: checkpoint_route (use = 'random', count = 5).
  Start: location.start is the district's FIRST checkpoint (radius 30 m, no other checkpoint
  inside it). checkpoint_route always uses the pool point inside location.start first and
  takes the other 4 at random, in the list's circular order from it, so each list below is
  written in driving order around its district.
]]

RegisterMission({
  id           = 'beat_patrol',
  label        = 'Beat Patrol',
  description  = 'Patrol your district: drive to each checkpoint in order and hold inside its marker for 10 seconds while driving a vehicle.',
  type         = 'patrol',       -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 1,
  difficulty   = 1,
  timeLimit    = 480,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 600,            -- per officer, seconds
  vehiclePenalties = true,       -- heavy vehicle damage is penalised here
  quietPatrol  = true,           -- lights and siren after the first arrival cost -10, personal

  locations = {
    {
      label       = 'Strawberry & Davis',
      start       = { coords = vec3(26.59, -1392.03, 29.36), radius = 30.0 },  -- Strawberry car wash, Innocence Blvd (the first checkpoint)
      checkpoints = {
        vec3(26.59, -1392.03, 29.36),         -- Strawberry car wash, Innocence Blvd
        vec3(133.95, -1308.89, 29.30),        -- Vanilla Unicorn car park
        vec3(265.65, -1261.31, 29.29),        -- Xero Gas, Strawberry Ave
        vec3(176.63, -1562.03, 29.26),        -- Ron gas station, Davis Ave
        vec3(167.10, -1719.47, 29.29),        -- Davis car wash, Strawberry Ave
        vec3(70.05, -1913.12, 20.56),         -- Grove Street
        vec3(-70.21, -1761.79, 29.53),        -- LTD Gasoline, Grove Street
        vec3(-156.46, -1567.59, 34.02),       -- Forum Drive, Chamberlain Hills
        vec3(-5.80, -1451.60, 30.50),         -- Forum Drive, Strawberry
      },
    },
    {
      label       = 'La Mesa & Mirror Park',
      start       = { coords = vec3(731.81, -1088.82, 22.17), radius = 30.0 },  -- Los Santos Customs, La Mesa (the first checkpoint)
      checkpoints = {
        vec3(731.81, -1088.82, 22.17),        -- Los Santos Customs, La Mesa
        vec3(819.65, -1028.85, 26.40),        -- Ron gas station, La Mesa
        vec3(1208.95, -1402.57, 35.22),       -- Ron gas station, El Burro Heights
        vec3(1211.00, -1264.00, 35.20),       -- El Burro Heights underpass
        vec3(1149.15, -981.26, 46.32),        -- Rob's Liquor, El Rancho Blvd
        vec3(1126.50, -759.50, 57.81),        -- West Mirror Drive, south of the lake
        vec3(1172.50, -600.00, 64.03),        -- Mirror Park Blvd, by the lake
        vec3(1181.38, -330.85, 69.32),        -- LTD Gasoline, Mirror Park
      },
    },
    {
      label       = 'Harmony & Route 68',
      start       = { coords = vec3(263.89, 2606.46, 44.98), radius = 30.0 },  -- Globe Oil, Harmony (the first checkpoint)
      checkpoints = {
        vec3(263.89, 2606.46, 44.98),         -- Globe Oil, Harmony
        vec3(543.73, 2683.96, 42.05),         -- 24/7 car park, Route 68
        vec3(616.00, 2745.00, 42.10),         -- Suburban car park, Route 68
        vec3(809.75, 2699.25, 40.34),         -- Route 68, east of Harmony
        vec3(1039.96, 2671.13, 39.55),        -- Gas station, Route 68
        vec3(1137.77, 2663.54, 37.90),        -- Motor motel, Route 68
        vec3(1175.04, 2640.22, 37.75),        -- Los Santos Customs, Harmony
        vec3(1172.54, 2693.86, 38.00),        -- Fleeca strip mall, Route 68
      },
    },
    {
      label       = 'Sandy Shores',
      start       = { coords = vec3(2005.06, 3773.89, 32.40), radius = 30.0 },  -- Gas station, Alhambra Dr (the first checkpoint)
      checkpoints = {
        vec3(2005.06, 3773.89, 32.40),        -- Gas station, Alhambra Dr
        vec3(1951.25, 3782.25, 32.31),        -- Zancudo Ave, Sandy Shores
        vec3(1968.92, 3731.40, 32.30),        -- 24/7 car park, Alhambra Dr
        vec3(1707.17, 3746.41, 34.40),        -- Ammu-Nation car park, Sandy Shores
        vec3(1398.00, 3597.00, 34.80),        -- Liquor Ace, Sandy Shores
        vec3(1784.32, 3330.55, 41.25),        -- Sandy Shores Airfield gas station
        vec3(1995.50, 3058.50, 46.90),        -- Yellow Jack Inn, Panorama Dr
        vec3(2679.86, 3263.95, 55.24),        -- 24/7 gas station, Senora Fwy
      },
    },
    {
      label       = 'Paleto Bay',
      start       = { coords = vec3(-94.46, 6419.59, 31.49), radius = 30.0 },  -- Xero Gas, Paleto Bay (the first checkpoint)
      checkpoints = {
        vec3(-94.46, 6419.59, 31.49),         -- Xero Gas, Paleto Bay
        vec3(15.76, 6500.74, 31.50),          -- Discount Store, Paleto Bay
        vec3(110.99, 6626.39, 31.79),         -- Beeker's Garage, Paleto Bay
        vec3(179.86, 6602.84, 31.87),         -- Ron gas station, Paleto Bay
        vec3(456.25, 6565.50, 26.97),         -- Great Ocean Hwy, east of Paleto
        vec3(-347.50, 6321.25, 30.00),        -- Procopio Dr, west Paleto Bay
        vec3(-268.00, 6218.50, 31.50),        -- Herr Kutz, Paleto Bay
        vec3(-316.64, 6070.49, 31.35),        -- Ammu-Nation car park, Paleto Bay
      },
    },
    {
      label       = 'Banham Canyon & Chumash',
      start       = { coords = vec3(-2981.38, 392.08, 14.94), radius = 30.0 },  -- Rob's Liquor car park, Great Ocean Hwy (the first checkpoint)
      checkpoints = {
        vec3(-2981.38, 392.08, 14.94),        -- Rob's Liquor car park, Great Ocean Hwy
        vec3(-2977.38, 486.16, 15.60),        -- Fleeca car park, Great Ocean Hwy
        vec3(-3028.70, 590.13, 7.80),         -- 24/7 car park, Ineseno Rd
        vec3(-3229.90, 1003.06, 12.73),       -- 24/7 car park, Barbareno Rd
        vec3(-3155.00, 1062.00, 20.60),       -- Chumash Plaza, Great Ocean Hwy
        vec3(-3101.50, 1242.75, 20.25),       -- Great Ocean Hwy, north Chumash
        vec3(-2971.00, 106.75, 14.00),        -- Great Ocean Hwy, south Banham Canyon
        vec3(-2096.24, -320.29, 13.17),       -- Xero Gas, Pacific Bluffs
      },
    },
  },

  objectives = {
    {
      block             = 'checkpoint_route',
      label             = 'Patrol the district checkpoints',
      minSeconds        = 70,                -- 5 stops of 10 s plus 1 km+ of driving; a fast legal run takes ~90 s
      checkpoints       = 'checkpoints',
      use               = 'random',
      count             = 5,
      radius            = 10.0,
      stopFor           = 10,                -- seconds stopped inside each marker
      vehicleRequired   = true,              -- at the wheel of a vehicle (any vehicle)
      medals            = false,
      contactPenalty    = 0,                 -- no course clock on a patrol
      timerStart        = 'start',
      failIfUndriveable = false,             -- only the time limit fails a patrol
    },
  },

  scaling   = {},
  items     = {},
  bonuses   = {},
  penalties = {},                          -- the common penalties always apply
})
