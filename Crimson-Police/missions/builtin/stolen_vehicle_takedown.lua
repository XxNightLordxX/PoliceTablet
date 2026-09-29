--[[ Crimson-Police · built-in mission
  Stolen Vehicle Takedown · stolen_vehicle_takedown · Training · 1-2 officers · 3 stars · 8 min · cooldown 15 min
  A stolen car with 2 suspects (scales, max 4) waits in its last-seen area and flees along its
  flee route once a participant with emergency lights on is within 60 m. Stop it with a PIT or
  box-in (below 5 km/h for 5 s), aim at each suspect until they surrender, then "Cuff suspect"
  (5 s). After the stop each suspect has a 20% chance to run on foot. A suspect more than 400 m
  from every participant for 20 s has escaped (fail). Car stopped within 2 min +15; ramming at
  over 100 km/h -10 each; PIT stops mean contact, so no heavy-damage penalty.
  Last-seen areas and flee routes (road waypoints on the GTA vehicle-node network at every
  junction or turn and at least every 100 m; the car free-flees after the last one): a car park on
  Route 68 in east Harmony (west along Route 68), the Rob's Liquor car park at Banham Canyon
  (north on the Great Ocean Hwy to Chumash), the Paleto Bay Ron station (east along the Great
  Ocean Hwy), the Grove Street LTD (Davis Ave, Strawberry Ave, Adam's Apple Blvd) and the
  Little Seoul LTD (Lindsay Circus, Palomino Ave, South Rockford Dr, Dutch London St).
  Blocks: pursuit (mode = 'stop', spawn = location.spawn, route = location.route).
  Start: a 60 m circle centred on the approach road 35-50 m from the stolen car (never on top of it).
]]

RegisterMission({
  id           = 'stolen_vehicle_takedown',
  label        = 'Stolen Vehicle Takedown',
  description  = 'A stolen car was last seen in the area. Light it up, stop it with a PIT or box-in and take every suspect into custody.',
  type         = 'training',     -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 2,
  difficulty   = 3,
  timeLimit    = 480,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 900,            -- per officer, seconds
  vehiclePenalties = false,      -- PIT stops and box-ins mean contact, so no heavy-damage penalty

  locations = {
    {
      label  = "Route 68, east Harmony",
      start  = { coords = vec3(1167.25, 2683.25, 38.03), radius = 60.0 },  -- last seen here, 36 m from the car
      spawn  = vec4(1137.00, 2664.50, 37.50, 352.96),   -- the stolen car
      -- 16 road waypoints, 1271 m flee route: Route 68
      route  = {
        points = {
          vec3(1137.00, 2664.50, 37.00),
          vec3(1139.50, 2684.75, 37.28),
          vec3(1039.75, 2690.00, 38.34),
          vec3(948.50, 2695.00, 39.41),
          vec3(857.75, 2698.00, 39.78),
          vec3(761.75, 2700.00, 39.12),
          vec3(663.00, 2700.25, 39.75),
          vec3(576.25, 2693.00, 40.94),
          vec3(487.00, 2681.25, 42.06),
          vec3(398.75, 2667.50, 43.31),
          vec3(309.00, 2643.00, 43.50),
          vec3(221.75, 2626.25, 45.94),
          vec3(142.75, 2660.25, 48.84),
          vec3(74.75, 2727.50, 54.69),
          vec3(-0.75, 2786.00, 56.94),
          vec3(-43.25, 2808.00, 54.66),
        },
        loop   = false,
      },
    },
    {
      label  = "Rob's Liquor, Banham Canyon",
      start  = { coords = vec3(-3003.00, 334.25, 14.56), radius = 60.0 },  -- last seen here, 41 m from the car
      spawn  = vec4(-2970.50, 359.75, 14.41, 33.93),   -- the stolen car
      -- 15 road waypoints, 1043 m flee route: Great Ocean Hwy
      route  = {
        points = {
          vec3(-2970.50, 359.75, 13.91),
          vec3(-2979.75, 373.50, 13.88),
          vec3(-2995.25, 375.50, 13.66),
          vec3(-2992.50, 399.25, 13.88),
          vec3(-2986.25, 494.00, 14.28),
          vec3(-2993.75, 578.50, 17.50),
          vec3(-3014.50, 665.75, 21.22),
          vec3(-3062.50, 744.25, 20.56),
          vec3(-3121.25, 823.75, 16.06),
          vec3(-3154.50, 913.25, 13.38),
          vec3(-3145.00, 997.25, 16.06),
          vec3(-3114.75, 1087.50, 19.44),
          vec3(-3106.25, 1183.00, 19.31),
          vec3(-3097.00, 1278.50, 19.19),
          vec3(-3084.25, 1337.00, 19.22),
        },
        loop   = false,
      },
    },
    {
      label  = "Ron gas station, Paleto Bay",
      start  = { coords = vec3(184.75, 6559.50, 32.00), radius = 60.0 },  -- last seen here, 41 m from the car
      spawn  = vec4(197.50, 6598.75, 31.25, 178.34),   -- the stolen car
      -- 16 road waypoints, 1246 m flee route: Great Ocean Hwy
      route  = {
        points = {
          vec3(197.50, 6598.75, 30.75),
          vec3(196.50, 6564.25, 31.03),
          vec3(198.00, 6545.50, 30.91),
          vec3(282.75, 6570.25, 29.16),
          vec3(378.75, 6572.00, 26.81),
          vec3(468.25, 6563.50, 25.97),
          vec3(555.75, 6543.25, 26.78),
          vec3(649.50, 6522.50, 27.19),
          vec3(743.50, 6502.50, 25.41),
          vec3(839.00, 6491.50, 21.41),
          vec3(935.00, 6486.25, 20.09),
          vec3(1031.00, 6484.75, 19.97),
          vec3(1127.00, 6485.25, 20.03),
          vec3(1223.00, 6486.50, 19.81),
          vec3(1318.75, 6486.50, 18.97),
          vec3(1379.00, 6478.00, 19.03),
        },
        loop   = false,
      },
    },
    {
      label  = "LTD Gasoline, Grove Street",
      start  = { coords = vec3(-104.25, -1764.50, 29.88), radius = 60.0 },  -- last seen here, 40 m from the car
      spawn  = vec4(-64.75, -1756.75, 28.75, 22.70),   -- the stolen car
      -- 24 road waypoints, 1205 m flee route: Davis Ave > Strawberry Ave > Adam's Apple Blvd
      route  = {
        points = {
          vec3(-64.75, -1756.75, 28.25),
          vec3(-75.00, -1732.25, 28.31),
          vec3(-56.25, -1724.25, 28.31),
          vec3(-71.00, -1720.00, 28.34),
          vec3(-134.50, -1731.75, 29.12),
          vec3(-115.75, -1724.25, 28.97),
          vec3(-60.50, -1642.50, 28.34),
          vec3(9.50, -1578.25, 28.34),
          vec3(63.00, -1506.00, 28.31),
          vec3(92.00, -1483.75, 28.28),
          vec3(145.25, -1416.50, 28.25),
          vec3(154.25, -1394.25, 28.28),
          vec3(199.00, -1351.75, 28.31),
          vec3(228.25, -1278.00, 28.31),
          vec3(230.50, -1258.00, 28.31),
          vec3(222.50, -1245.25, 28.31),
          vec3(229.50, -1223.75, 28.31),
          vec3(210.50, -1130.50, 28.31),
          vec3(112.25, -1129.00, 28.31),
          vec3(13.75, -1134.25, 27.84),
          vec3(-76.00, -1137.25, 24.78),
          vec3(-97.75, -1138.00, 24.81),
          vec3(-116.25, -1131.50, 24.69),
          vec3(-122.50, -1131.75, 24.66),
        },
        loop   = false,
      },
    },
    {
      label  = "LTD Gasoline, Little Seoul",
      start  = { coords = vec3(-745.50, -892.00, 20.78), radius = 60.0 },  -- last seen here, 42 m from the car
      spawn  = vec4(-720.00, -925.50, 18.50, 225.81),   -- the stolen car
      -- 22 road waypoints, 878 m flee route: Lindsay Circus > Palomino Ave > South Rockford Dr > Dutch London St
      route  = {
        points = {
          vec3(-720.00, -925.50, 18.00),
          vec3(-711.00, -934.25, 18.00),
          vec3(-710.75, -950.25, 17.84),
          vec3(-701.75, -957.25, 18.25),
          vec3(-657.50, -957.00, 20.47),
          vec3(-638.25, -957.00, 20.50),
          vec3(-643.75, -979.50, 20.12),
          vec3(-662.50, -1037.00, 16.44),
          vec3(-737.25, -1089.75, 10.44),
          vec3(-756.75, -1101.25, 9.69),
          vec3(-768.50, -1117.50, 9.69),
          vec3(-769.00, -1135.25, 9.69),
          vec3(-709.00, -1213.50, 9.66),
          vec3(-692.25, -1222.50, 9.66),
          vec3(-683.75, -1251.00, 9.66),
          vec3(-653.75, -1343.00, 9.59),
          vec3(-654.25, -1361.75, 9.59),
          vec3(-647.25, -1380.00, 9.66),
          vec3(-651.50, -1461.00, 9.66),
          vec3(-680.25, -1549.25, 14.38),
          vec3(-719.00, -1600.75, 21.19),
          vec3(-735.25, -1608.25, 22.59),
        },
        loop   = false,
      },
    },
  },

  objectives = {
    {
      block              = 'pursuit',
      label              = 'Stop the stolen car and arrest the suspects',
      minSeconds         = 10,               -- quicker is rejected: 5 s stopped + a 5 s cuff (2 officers cuff at once)
      mode               = 'stop',
      vehicles           = 1,
      models             = { 'sultan', 'buffalo', 'kuruma' },   -- four-door cars for up to 4 suspects
      suspectsPerVehicle = 2,                -- base suspects in the car, scaled by tier (max 4)
      spawn              = 'spawn',
      route              = 'route',
      speed              = 115,              -- km/h
      style              = 'reckless',
      trigger            = { distance = 60.0, lights = true },
      stopped            = { speed = 5.0, seconds = 5 },
      footFlee           = 0.20,             -- chance per suspect to run after the stop
      surrenderOnAim     = true,
      arrest             = { label = 'Cuff suspect', duration = 5000 },
      escape             = { distance = 400, seconds = 20 },
      complete           = 'all_detained',
      ramSpeed           = 100,              -- km/h; faster contact is a hard ram
      ramPenaltyId       = 'hard_ram',
      neverShoots        = true,
    },
  },

  scaling   = { { path = 'objectives.1.suspectsPerVehicle', max = 4 } },
  items     = {},
  bonuses   = {
    { id = 'vehicle_stopped_fast', points = 15 },       -- car stopped within 2 minutes of the start
  },
  penalties = {
    { id = 'hard_ram', points = -10, each = true },     -- ramming at over 100 km/h
  },
})
