--[[ Crimson-Police · built-in mission
  Stolen Vehicle Takedown · stolen_vehicle_takedown · Training · 1-2 officers · 3 stars · 8 min · cooldown 15 min
  A stolen car with 2 suspects (scales, max 4) waits in its last-seen area and flees along its
  flee route once a participant with emergency lights on is within 60 m. Stop it with a PIT or
  box-in (below 5 km/h for 5 s), aim at each suspect until they surrender, then "Cuff suspect"
  (5 s). After the stop each suspect has a 20% chance to run on foot. A suspect more than 400 m
  from every participant for 20 s has escaped (fail). Car stopped within 2 min +15; ramming at
  over 100 km/h -10 each; PIT stops mean contact, so no heavy-damage penalty.
  Last-seen areas and flee routes: the motor motel on Route 68 (west through Harmony), Rob's
  Liquor at Banham Canyon (north on the Great Ocean Hwy), the Paleto Bay Ron station (east along
  the coast), the Grove Street LTD (Davis Ave, Strawberry Ave, Adam's Apple Blvd) and the
  Little Seoul LTD (south towards La Puerta).
  Blocks: pursuit (mode = 'stop', spawn = location.spawn, route = location.route).
  Start: a circle of 60 m centred 35-50 m from the stolen car (never on top of it).
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
      label  = 'Motor motel, Route 68',
      start  = { coords = vec3(1178.00, 2686.50, 38.09), radius = 60.0 },  -- last seen here, 44 m from the car
      spawn  = vec4(1137.80, 2668.00, 37.90, 27.91),   -- the stolen car
      -- 15 waypoints, 1250 m flee route
      route  = {
        points = {
          vec3(1137.80, 2668.00, 37.90),
          vec3(1128.00, 2686.50, 37.98),
          vec3(1014.40, 2687.10, 39.49),
          vec3(900.80, 2687.70, 39.20),
          vec3(787.20, 2688.30, 40.79),
          vec3(673.60, 2688.90, 42.03),
          vec3(560.00, 2689.50, 42.15),
          vec3(495.00, 2680.75, 42.19),
          vec3(430.00, 2672.00, 42.87),
          vec3(370.00, 2652.50, 44.52),
          vec3(310.00, 2633.00, 45.00),
          vec3(225.00, 2640.00, 45.12),
          vec3(140.00, 2705.00, 53.98),
          vec3(60.00, 2766.00, 58.04),
          vec3(-30.00, 2830.00, 57.72),
        },
        loop   = false,
      },
    },
    {
      label  = "Rob's Liquor, Banham Canyon",
      start  = { coords = vec3(-2991.00, 352.00, 14.40), radius = 60.0 },  -- last seen here, 41 m from the car
      spawn  = vec4(-2981.38, 392.08, 14.94, 7.87),   -- the stolen car
      -- 12 waypoints, 1067 m flee route
      route  = {
        points = {
          vec3(-2981.38, 392.08, 14.94),
          vec3(-2988.00, 440.00, 15.20),
          vec3(-2989.00, 520.00, 15.60),
          vec3(-3005.00, 630.00, 16.30),
          vec3(-3040.00, 750.00, 17.30),
          vec3(-3064.00, 815.00, 17.95),
          vec3(-3088.00, 880.00, 18.60),
          vec3(-3128.00, 990.00, 19.80),
          vec3(-3147.00, 1080.00, 20.70),
          vec3(-3152.00, 1190.00, 21.40),
          vec3(-3140.00, 1310.00, 22.20),
          vec3(-3110.00, 1430.00, 23.00),
        },
        loop   = false,
      },
    },
    {
      label  = 'Ron gas station, Paleto Bay',
      start  = { coords = vec3(145.00, 6615.00, 31.82), radius = 60.0 },  -- last seen here, 39 m from the car
      spawn  = vec4(182.00, 6603.00, 31.87, 294.44),   -- the stolen car
      -- 12 waypoints, 1113 m flee route
      route  = {
        points = {
          vec3(182.00, 6603.00, 31.87),
          vec3(215.00, 6618.00, 31.83),
          vec3(300.00, 6624.00, 29.80),
          vec3(400.00, 6622.00, 23.13),
          vec3(465.00, 6619.00, 22.72),
          vec3(560.00, 6606.00, 23.06),
          vec3(680.00, 6588.00, 24.43),
          vec3(800.00, 6565.00, 25.38),
          vec3(920.00, 6545.00, 26.32),
          vec3(1040.00, 6522.00, 27.52),
          vec3(1160.00, 6500.00, 29.56),
          vec3(1280.00, 6482.00, 31.55),
        },
        loop   = false,
      },
    },
    {
      label  = 'LTD Gasoline, Grove Street',
      start  = { coords = vec3(-82.83, -1790.92, 29.50), radius = 60.0 },  -- last seen here, 37 m from the car
      spawn  = vec4(-66.00, -1758.00, 29.53, 289.86),   -- the stolen car
      -- 15 waypoints, 1148 m flee route
      route  = {
        points = {
          vec3(-66.00, -1758.00, 29.53),
          vec3(-30.00, -1745.00, 29.47),
          vec3(41.67, -1682.67, 29.25),
          vec3(113.33, -1620.33, 29.30),
          vec3(185.00, -1558.00, 29.26),
          vec3(213.00, -1462.00, 29.36),
          vec3(241.00, -1366.00, 29.35),
          vec3(262.00, -1268.00, 29.29),
          vec3(293.00, -1164.00, 29.28),
          vec3(221.50, -1155.00, 29.31),
          vec3(150.00, -1146.00, 29.33),
          vec3(82.50, -1137.00, 29.47),
          vec3(15.00, -1128.00, 29.69),
          vec3(-43.00, -1121.00, 26.50),
          vec3(-120.00, -1111.00, 26.93),
        },
        loop   = false,
      },
    },
    {
      label  = 'LTD Gasoline, Little Seoul',
      start  = { coords = vec3(-770.00, -955.00, 19.08), radius = 60.0 },  -- last seen here, 48 m from the car
      spawn  = vec4(-724.60, -938.00, 19.21, 168.69),   -- the stolen car
      -- 11 waypoints, 845 m flee route
      route  = {
        points = {
          vec3(-724.60, -938.00, 19.21),
          vec3(-728.00, -955.00, 19.22),
          vec3(-640.00, -955.00, 21.46),
          vec3(-575.00, -955.00, 21.38),
          vec3(-510.00, -955.00, 23.53),
          vec3(-510.00, -1080.00, 20.40),
          vec3(-510.00, -1145.00, 18.59),
          vec3(-510.00, -1210.00, 18.19),
          vec3(-508.00, -1330.00, 19.98),
          vec3(-505.00, -1450.00, 24.07),
          vec3(-390.00, -1455.00, 28.10),
        },
        loop   = false,
      },
    },
  },

  objectives = {
    {
      block              = 'pursuit',
      label              = 'Stop the stolen car and arrest the suspects',
      minSeconds         = 40,               -- quicker than this is rejected
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
