--[[ Crimson-Police · built-in mission
  Street Race Bust · street_race_bust · Patrol · 1-2 officers · 2 stars · 4 min race · cooldown 15 min
  Three NPC racers (scales) in sports cars lap a 2-3 km street loop. Stop them (below 5 km/h for
  5 s), then "Detain driver" (3 s). Completed when every racer is detained, or when the race ends
  with at least one detained. +30 per racer detained, +20 more for all of them; ramming a racer
  at over 100 km/h -10 each. Boxing racers in means contact, so no heavy-damage penalty.
  Loops (road waypoints at every junction/turn and at least every 150 m, recorded order = race
  direction, loop = true, last waypoint within 50 m of the first): Davis & Strawberry,
  La Mesa & Murrieta Heights, Little Seoul & La Puerta, Mirror Park, Vespucci Canals & Del Perro.
  Blocks: pursuit (mode = 'stop', route = location.route, spawns = location.spawns).
  Start: an intercept waypoint half way round the loop (radius 60 m); the race starts when the
  first participant arrives, with the racers leaving the grid at the loop's first waypoint.
]]

RegisterMission({
  id           = 'street_race_bust',
  label        = 'Street Race Bust',
  description  = 'Street racers are lapping a city loop. Intercept the race, stop the cars and detain every driver before the race ends.',
  type         = 'patrol',       -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 2,
  difficulty   = 2,
  timeLimit    = 240,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 900,            -- per officer, seconds
  vehiclePenalties = false,      -- boxing racers in means contact, so no heavy-damage penalty

  locations = {
    {
      label  = 'Davis & Strawberry loop',
      start  = { coords = vec3(440.83, -1600.72, 29.31), radius = 60.0 },  -- intercept point on the loop
      spawns = {                              -- racers line up at the loop's first waypoint
        vec4(-270.82, -1772.82, 29.83, 221.00),
        vec4(-277.38, -1765.27, 29.85, 221.00),
        vec4(-283.94, -1757.72, 29.87, 221.00),
        vec4(-290.50, -1750.18, 29.88, 221.00),
        vec4(-297.06, -1742.63, 29.90, 221.00),
        vec4(-303.62, -1735.08, 29.92, 221.00),
        vec4(-310.19, -1727.53, 29.93, 221.00),
        vec4(-316.75, -1719.99, 29.95, 221.00),
      },
      -- 20 waypoints, 2067 m loop
      route  = {
        points = {
          vec3(-323.31, -1712.44, 29.97),
          vec3(-254.91, -1791.12, 29.79),
          vec3(-186.52, -1869.80, 29.06),
          vec3(-118.12, -1948.48, 27.51),
          vec3(-49.73, -2027.15, 25.20),
          vec3(32.03, -1956.08, 21.04),
          vec3(113.79, -1885.01, 21.24),
          vec3(195.55, -1813.93, 28.33),
          vec3(277.31, -1742.86, 29.03),
          vec3(359.07, -1671.79, 29.24),
          vec3(440.83, -1600.72, 29.31),
          vec3(375.23, -1525.24, 29.29),
          vec3(309.62, -1449.77, 29.28),
          vec3(241.00, -1366.00, 29.35),
          vec3(150.50, -1370.50, 29.44),
          vec3(60.00, -1375.00, 29.41),
          vec3(-28.32, -1452.75, 31.07),
          vec3(-116.64, -1530.50, 33.43),
          vec3(-204.96, -1608.26, 33.54),
          vec3(-293.28, -1686.01, 30.73),
        },
        loop   = true,
      },
    },
    {
      label  = 'La Mesa & Murrieta Heights loop',
      start  = { coords = vec3(1270.00, -1580.00, 41.43), radius = 60.0 },  -- intercept point on the loop
      spawns = {                              -- racers line up at the loop's first waypoint
        vec4(769.99, -1016.96, 25.82, 270.75),
        vec4(759.99, -1017.09, 25.61, 270.75),
        vec4(749.99, -1017.22, 25.41, 270.75),
        vec4(740.00, -1017.35, 25.20, 270.75),
        vec4(730.00, -1017.48, 24.99, 270.75),
        vec4(720.00, -1017.61, 24.78, 270.75),
        vec4(710.00, -1017.74, 24.58, 270.75),
        vec4(700.00, -1017.87, 24.37, 270.75),
      },
      -- 22 waypoints, 2102 m loop
      route  = {
        points = {
          vec3(690.00, -1018.00, 24.16),
          vec3(805.00, -1016.50, 26.55),
          vec3(920.00, -1015.00, 28.53),
          vec3(1035.00, -1013.50, 42.56),
          vec3(1150.00, -1012.00, 46.39),
          vec3(1172.00, -1096.00, 44.36),
          vec3(1194.00, -1180.00, 39.32),
          vec3(1212.67, -1263.67, 36.04),
          vec3(1231.33, -1347.33, 35.10),
          vec3(1250.00, -1431.00, 34.09),
          vec3(1260.00, -1505.50, 35.77),
          vec3(1270.00, -1580.00, 41.43),
          vec3(1147.50, -1580.00, 35.75),
          vec3(1025.00, -1580.00, 33.10),
          vec3(902.50, -1580.00, 30.60),
          vec3(780.00, -1580.00, 31.03),
          vec3(773.33, -1486.67, 30.35),
          vec3(766.67, -1393.33, 28.82),
          vec3(760.00, -1300.00, 28.25),
          vec3(739.88, -1218.94, 26.77),
          vec3(719.76, -1137.88, 22.77),
          vec3(699.64, -1056.82, 22.69),
        },
        loop   = true,
      },
    },
    {
      label  = 'Little Seoul & La Puerta loop',
      start  = { coords = vec3(-510.00, -1260.00, 18.36), radius = 60.0 },  -- intercept point on the loop
      spawns = {                              -- racers line up at the loop's first waypoint
        vec4(-970.00, -790.00, 19.71, 270.00),
        vec4(-980.00, -790.00, 19.66, 270.00),
        vec4(-990.00, -790.00, 19.62, 270.00),
        vec4(-1000.00, -790.00, 19.57, 270.00),
        vec4(-1010.00, -790.00, 19.53, 270.00),
        vec4(-1020.00, -790.00, 19.48, 270.00),
        vec4(-1030.00, -790.00, 19.43, 270.00),
        vec4(-1040.00, -790.00, 19.39, 270.00),
      },
      -- 19 waypoints, 2020 m loop
      route  = {
        points = {
          vec3(-1050.00, -790.00, 19.34),
          vec3(-942.00, -790.00, 19.84),
          vec3(-834.00, -790.00, 20.36),
          vec3(-726.00, -790.00, 20.68),
          vec3(-618.00, -790.00, 23.32),
          vec3(-510.00, -790.00, 30.20),
          vec3(-510.00, -907.50, 25.52),
          vec3(-510.00, -1025.00, 21.92),
          vec3(-510.00, -1142.50, 18.64),
          vec3(-510.00, -1260.00, 18.36),
          vec3(-618.00, -1260.00, 18.64),
          vec3(-726.00, -1260.00, 17.13),
          vec3(-834.00, -1260.00, 14.57),
          vec3(-942.00, -1260.00, 12.33),
          vec3(-1050.00, -1260.00, 9.10),
          vec3(-1050.00, -1152.50, 12.55),
          vec3(-1050.00, -1045.00, 15.04),
          vec3(-1050.00, -937.50, 17.93),
          vec3(-1050.00, -830.00, 19.21),
        },
        loop   = true,
      },
    },
    {
      label  = 'Mirror Park loop',
      start  = { coords = vec3(1097.50, -880.00, 51.10), radius = 60.0 },  -- intercept point on the loop
      spawns = {                              -- racers line up at the loop's first waypoint
        vec4(1155.03, -256.41, 69.06, 10.78),
        vec4(1156.90, -266.24, 69.09, 10.78),
        vec4(1158.77, -276.06, 69.12, 10.78),
        vec4(1160.64, -285.88, 69.16, 10.78),
        vec4(1162.52, -295.71, 69.19, 10.78),
        vec4(1164.39, -305.53, 69.22, 10.78),
        vec4(1166.26, -315.35, 69.25, 10.78),
        vec4(1168.13, -325.18, 69.29, 10.78),
      },
      -- 21 waypoints, 2039 m loop
      route  = {
        points = {
          vec3(1170.00, -335.00, 69.32),
          vec3(1150.00, -230.00, 68.97),
          vec3(1075.00, -230.00, 69.08),
          vec3(1000.00, -230.00, 69.37),
          vec3(998.33, -338.33, 67.55),
          vec3(996.67, -446.67, 65.19),
          vec3(995.00, -555.00, 61.68),
          vec3(993.33, -663.33, 56.72),
          vec3(991.67, -771.67, 52.62),
          vec3(990.00, -880.00, 43.69),
          vec3(1097.50, -880.00, 51.10),
          vec3(1205.00, -880.00, 51.60),
          vec3(1312.50, -880.00, 52.29),
          vec3(1420.00, -880.00, 52.80),
          vec3(1397.00, -780.33, 58.79),
          vec3(1374.00, -680.67, 65.07),
          vec3(1351.00, -581.00, 67.84),
          vec3(1245.00, -610.00, 69.79),
          vec3(1230.00, -540.00, 68.17),
          vec3(1215.00, -470.00, 66.21),
          vec3(1182.65, -372.95, 69.10),
        },
        loop   = true,
      },
    },
    {
      label  = 'Vespucci Canals & Del Perro loop',
      start  = { coords = vec3(-997.10, -400.22, 34.84), radius = 60.0 },  -- intercept point on the loop
      spawns = {                              -- racers line up at the loop's first waypoint
        vec4(-1218.70, -1030.93, 10.89, 306.00),
        vec4(-1226.79, -1036.80, 10.42, 306.00),
        vec4(-1234.88, -1042.68, 9.95, 306.00),
        vec4(-1242.97, -1048.56, 9.48, 306.00),
        vec4(-1251.06, -1054.44, 9.01, 306.00),
        vec4(-1259.15, -1060.32, 8.54, 306.00),
        vec4(-1267.24, -1066.19, 8.07, 306.00),
        vec4(-1275.33, -1072.07, 7.60, 306.00),
      },
      -- 20 waypoints, 2020 m loop
      route  = {
        points = {
          vec3(-1283.42, -1077.95, 7.13),
          vec3(-1198.47, -1016.23, 12.07),
          vec3(-1113.52, -954.51, 16.30),
          vec3(-1028.58, -892.80, 18.72),
          vec3(-943.63, -831.08, 19.27),
          vec3(-858.68, -769.36, 20.70),
          vec3(-773.74, -707.65, 22.48),
          vec3(-829.58, -630.79, 24.79),
          vec3(-885.42, -553.93, 28.22),
          vec3(-941.26, -477.08, 31.63),
          vec3(-997.10, -400.22, 34.84),
          vec3(-1082.04, -461.94, 33.85),
          vec3(-1166.99, -523.65, 31.94),
          vec3(-1251.94, -585.37, 29.58),
          vec3(-1336.88, -647.09, 30.48),
          vec3(-1421.83, -708.81, 29.77),
          vec3(-1506.78, -770.52, 27.11),
          vec3(-1440.16, -862.21, 20.04),
          vec3(-1373.55, -953.90, 13.74),
          vec3(-1306.93, -1045.59, 8.12),
        },
        loop   = true,
      },
    },
  },

  objectives = {
    {
      block              = 'pursuit',
      label              = 'Stop and detain the racers',
      minSeconds         = 45,               -- quicker than this is rejected
      mode               = 'stop',
      vehicles           = 3,                -- base racers, scaled by tier
      models             = { 'elegy2', 'sultan', 'buffalo', 'dominator', 'kuruma' },
      suspectsPerVehicle = 1,
      spawns             = 'spawns',
      route              = 'route',
      speed              = 130,              -- km/h
      style              = 'reckless',
      trigger            = 'arrive',         -- the race starts when the first participant arrives
      stopped            = { speed = 5.0, seconds = 5 },
      footFlee           = 0.0,
      surrenderOnAim     = false,            -- a stopped racer is detained without aiming
      arrest             = { label = 'Detain driver', duration = 3000 },
      complete           = 'all_or_timeout_any',
      ramSpeed           = 100,              -- km/h; faster contact is a hard ram
      ramPenaltyId       = 'hard_ram',
      neverShoots        = true,
    },
  },

  scaling   = { 'objectives.1.vehicles' },
  items     = {},
  bonuses   = {
    { id = 'racer_detained',      points = 30, each = true },   -- per racer detained
    { id = 'all_racers_detained', points = 20 },                -- every racer detained
  },
  penalties = {
    { id = 'hard_ram', points = -10, each = true },     -- ramming a racer at over 100 km/h
  },
})
