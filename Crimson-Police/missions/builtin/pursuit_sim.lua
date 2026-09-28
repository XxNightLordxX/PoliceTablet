--[[ Crimson-Police · built-in mission
  Pursuit Sim · pursuit_sim · Training · 1 officer · 3 stars · 5 min · cooldown 15 min
  Follow exercise: the getaway car (1 driver, never shoots) waits 50 m ahead of the start and
  flees along its flee loop when the officer arrives. Stay within 150 m of it for a total of
  3 minutes; more than 250 m away for 10 s straight fails. Medal by average distance: Gold
  under 40 m +50, Silver under 80 m +25, Bronze under 150 m +10 (replaces the common time
  bonus). Any ram of the getaway car -10 (ramSpeed 0: every contact counts).
  Flee loops (road waypoints, loop = true so the car keeps driving for the whole exercise):
  Cypress Flats & El Burro Heights, Rockford Hills & Burton, Hawick & Downtown Vinewood,
  Banham Canyon & Chumash (Great Ocean Hwy and the coast road), Strawberry & Chamberlain Hills.
  Blocks: pursuit (mode = 'follow', spawn = location.spawn, route = location.route).
  Start: the loop's last waypoint (radius 25 m); location.spawn is the loop's first waypoint.
]]

RegisterMission({
  id           = 'pursuit_sim',
  label        = 'Pursuit Sim',
  description  = 'Pursuit training: a getaway driver flees along a set route. Stay within 150 m for a total of 3 minutes and never touch the car.',
  type         = 'training',     -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 1,
  difficulty   = 3,
  timeLimit    = 300,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 900,            -- per officer, seconds
  vehiclePenalties = true,       -- a follow exercise: heavy vehicle damage is penalised

  locations = {
    {
      label  = 'Cypress Flats & El Burro Heights',
      start  = { coords = vec3(760.00, -1748.00, 31.31), radius = 25.0 },
      spawn  = vec4(760.00, -1700.00, 31.12, 270.00),   -- getaway car, 48 m ahead of the start
      -- 19 waypoints, 2180 m flee loop
      route  = {
        points = {
          vec3(760.00, -1700.00, 31.12),
          vec3(882.50, -1700.00, 30.27),
          vec3(1005.00, -1700.00, 30.99),
          vec3(1127.50, -1700.00, 42.89),
          vec3(1250.00, -1700.00, 54.42),
          vec3(1250.00, -1820.00, 52.10),
          vec3(1250.00, -1940.00, 46.26),
          vec3(1250.00, -2060.00, 39.33),
          vec3(1250.00, -2180.00, 34.14),
          vec3(1250.00, -2300.00, 32.42),
          vec3(1127.50, -2300.00, 31.09),
          vec3(1005.00, -2300.00, 31.00),
          vec3(882.50, -2300.00, 30.50),
          vec3(760.00, -2300.00, 30.01),
          vec3(760.00, -2189.60, 29.65),
          vec3(760.00, -2079.20, 29.78),
          vec3(760.00, -1968.80, 30.78),
          vec3(760.00, -1858.40, 31.48),
          vec3(760.00, -1748.00, 31.31),
        },
        loop   = true,
      },
    },
    {
      label  = 'Rockford Hills & Burton',
      start  = { coords = vec3(-1180.00, -282.00, 37.85), radius = 25.0 },
      spawn  = vec4(-1180.00, -330.00, 37.78, 270.00),   -- getaway car, 48 m ahead of the start
      -- 21 waypoints, 2340 m flee loop
      route  = {
        points = {
          vec3(-1180.00, -330.00, 37.78),
          vec3(-1062.86, -330.00, 36.95),
          vec3(-945.71, -330.00, 36.33),
          vec3(-828.57, -330.00, 37.08),
          vec3(-711.43, -330.00, 37.54),
          vec3(-594.29, -330.00, 38.25),
          vec3(-477.14, -330.00, 39.21),
          vec3(-360.00, -330.00, 41.45),
          vec3(-360.00, -213.33, 40.47),
          vec3(-360.00, -96.67, 43.78),
          vec3(-360.00, 20.00, 48.63),
          vec3(-477.14, 20.00, 48.37),
          vec3(-594.29, 20.00, 46.92),
          vec3(-711.43, 20.00, 42.79),
          vec3(-828.57, 20.00, 41.18),
          vec3(-945.71, 20.00, 40.78),
          vec3(-1062.86, 20.00, 41.03),
          vec3(-1180.00, 20.00, 41.64),
          vec3(-1180.00, -80.67, 40.60),
          vec3(-1180.00, -181.33, 39.16),
          vec3(-1180.00, -282.00, 37.85),
        },
        loop   = true,
      },
    },
    {
      label  = 'Hawick & Downtown Vinewood',
      start  = { coords = vec3(60.00, -142.00, 58.08), radius = 25.0 },
      spawn  = vec4(60.00, -190.00, 55.89, 270.00),   -- getaway car, 48 m ahead of the start
      -- 19 waypoints, 2140 m flee loop
      route  = {
        points = {
          vec3(60.00, -190.00, 55.89),
          vec3(176.00, -190.00, 56.01),
          vec3(292.00, -190.00, 54.55),
          vec3(408.00, -190.00, 56.32),
          vec3(524.00, -190.00, 66.94),
          vec3(640.00, -190.00, 75.91),
          vec3(640.00, -67.50, 82.62),
          vec3(640.00, 55.00, 83.14),
          vec3(640.00, 177.50, 99.72),
          vec3(640.00, 300.00, 103.01),
          vec3(524.00, 300.00, 102.10),
          vec3(408.00, 300.00, 103.43),
          vec3(292.00, 300.00, 103.51),
          vec3(176.00, 300.00, 102.44),
          vec3(60.00, 300.00, 91.72),
          vec3(60.00, 189.50, 84.01),
          vec3(60.00, 79.00, 69.88),
          vec3(60.00, -31.50, 68.59),
          vec3(60.00, -142.00, 58.08),
        },
        loop   = true,
      },
    },
    {
      label  = 'Banham Canyon & Chumash',
      start  = { coords = vec3(-3010.05, 374.87, 12.94), radius = 25.0 },
      spawn  = vec4(-2993.00, 330.00, 14.20, 357.40),   -- getaway car, 48 m ahead of the start
      -- 22 waypoints, 1805 m flee loop
      route  = {
        points = {
          vec3(-2993.00, 330.00, 14.20),
          vec3(-2988.00, 440.00, 15.20),
          vec3(-2990.00, 540.00, 15.70),
          vec3(-3008.00, 650.00, 16.50),
          vec3(-3045.00, 760.00, 17.40),
          vec3(-3067.50, 820.00, 18.00),
          vec3(-3090.00, 880.00, 18.60),
          vec3(-3128.00, 990.00, 19.80),
          vec3(-3146.00, 1070.00, 20.60),
          vec3(-3150.00, 1160.00, 21.20),
          vec3(-3190.00, 1175.00, 16.00),
          vec3(-3222.00, 1090.00, 13.20),
          vec3(-3224.00, 1003.00, 12.60),
          vec3(-3205.00, 900.00, 11.60),
          vec3(-3160.00, 800.00, 10.40),
          vec3(-3105.00, 700.00, 9.00),
          vec3(-3064.50, 648.00, 8.40),
          vec3(-3024.00, 596.00, 7.80),
          vec3(-3016.00, 520.00, 10.20),
          vec3(-3014.00, 450.00, 11.50),
          vec3(-3012.00, 380.00, 12.80),
          vec3(-3010.05, 374.87, 12.94),
        },
        loop   = true,
      },
    },
    {
      label  = 'Strawberry & Chamberlain Hills',
      start  = { coords = vec3(-430.27, -1741.82, 28.55), radius = 25.0 },
      spawn  = vec4(-398.78, -1778.05, 28.97, 311.00),   -- getaway car, 48 m ahead of the start
      -- 19 waypoints, 2082 m flee loop
      route  = {
        points = {
          vec3(-398.78, -1778.05, 28.97),
          vec3(-307.00, -1698.27, 30.41),
          vec3(-215.23, -1618.49, 33.23),
          vec3(-123.46, -1538.72, 33.72),
          vec3(-31.69, -1458.94, 31.04),
          vec3(60.09, -1379.16, 29.40),
          vec3(-10.93, -1297.46, 29.51),
          vec3(-81.95, -1215.77, 28.56),
          vec3(-152.97, -1134.07, 27.65),
          vec3(-223.99, -1052.37, 28.10),
          vec3(-315.76, -1132.15, 26.67),
          vec3(-407.53, -1211.93, 21.21),
          vec3(-499.31, -1291.70, 18.98),
          vec3(-591.08, -1371.48, 20.32),
          vec3(-682.85, -1451.26, 19.84),
          vec3(-619.71, -1523.90, 22.32),
          vec3(-556.56, -1596.54, 25.19),
          vec3(-493.41, -1669.18, 27.36),
          vec3(-430.27, -1741.82, 28.55),
        },
        loop   = true,
      },
    },
  },

  objectives = {
    {
      block              = 'pursuit',
      label              = 'Stay with the getaway car',
      minSeconds         = 180,              -- the hold time cannot be done faster
      mode               = 'follow',
      vehicles           = 1,
      models             = { 'sultan', 'buffalo', 'kuruma', 'elegy2', 'dominator' },
      suspectsPerVehicle = 1,
      spawn              = 'spawn',
      route              = 'route',
      speed              = 110,              -- km/h
      style              = 'reckless',
      trigger            = { ahead = 50.0 }, -- waits 50 m ahead, flees when the officer arrives
      hold               = 150,              -- metres
      lost               = { distance = 250, seconds = 10 },
      duration           = 180,              -- seconds within hold distance
      medals             = { gold = 40, silver = 80, bronze = 150 },   -- average distance, metres
      ramSpeed           = 0,                -- any contact counts as a ram
      ramPenaltyId       = 'ram',
      neverShoots        = true,
    },
  },

  scaling   = {},
  items     = {},
  bonuses   = {
    { id = 'medal_gold',   points = 50 },   -- average distance under 40 m
    { id = 'medal_silver', points = 25 },   -- under 80 m
    { id = 'medal_bronze', points = 10 },   -- under 150 m
  },
  penalties = {
    { id = 'ram', points = -10, each = true },          -- ramming the getaway car
  },
})
