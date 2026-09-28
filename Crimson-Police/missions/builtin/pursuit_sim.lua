--[[ Crimson-Police · built-in mission
  Pursuit Sim · pursuit_sim · Training · 1 officer · 3 stars · 5 min · cooldown 15 min
  Follow exercise: the getaway car (1 driver, never shoots) waits 50 m ahead of the start and
  flees along its flee loop when the officer arrives. Stay within 150 m of it for a total of
  3 minutes; more than 250 m away for 10 s straight fails. Medal by average distance: Gold
  under 40 m +50, Silver under 80 m +25, Bronze under 150 m +10 (replaces the common time
  bonus). Any ram of the getaway car -10 (ramSpeed 0: every contact counts).
  Flee loops (road waypoints on the GTA vehicle-node network at every junction or turn and at least
  every 100 m, loop = true so the car keeps driving for the whole exercise): Cypress Flats &
  El Burro Heights (Popular St, Hanger Way, South Shambles St, El Rancho Blvd, Labor Pl),
  Rockford Hills & Morningwood (Boulevard Del Perro, Rockford Dr, Dorset Dr, Marathon Ave),
  Hawick & Alta (Hawick Ave, Meteor St, Spanish Ave, San Vitus Blvd), Banham Canyon & Chumash
  (Great Ocean Hwy, Barbareno Rd, Ineseno Road; the highway between the two side roads is driven
  both ways) and Strawberry & Chamberlain Hills (Innocence Blvd, Alta St, Davis Ave, Strawberry Ave).
  Blocks: pursuit (mode = 'follow', spawn = location.spawn, route = location.route).
  Start: the loop's last waypoint (radius 25 m), 44-50 m behind the car; location.spawn is the
  loop's first waypoint, facing the second.
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
      start  = { coords = vec3(800.10, -1854.35, 29.36), radius = 25.0 },  -- the loop's last waypoint
      spawn  = vec4(790.00, -1900.25, 28.81, 168.56),   -- getaway car on waypoint 1, 47 m ahead of the start
      -- 40 road waypoints, 2672 m flee loop: Popular St > Hanger Way > South Shambles St > El Rancho Blvd > Labor Pl > Orchardville Ave > Innocence Blvd > Popular St
      route  = {
        points = {
          vec3(790.00, -1900.25, 28.31),
          vec3(772.25, -1988.00, 28.34),
          vec3(763.75, -2033.25, 28.31),
          vec3(775.25, -2064.75, 28.38),
          vec3(760.25, -2096.50, 28.31),
          vec3(752.00, -2192.25, 28.31),
          vec3(743.75, -2287.75, 27.47),
          vec3(735.25, -2383.25, 20.72),
          vec3(733.75, -2431.25, 18.94),
          vec3(753.00, -2459.25, 19.25),
          vec3(850.25, -2453.75, 26.81),
          vec3(946.00, -2463.75, 27.62),
          vec3(1018.25, -2470.00, 27.59),
          vec3(1031.50, -2459.50, 27.50),
          vec3(1040.00, -2363.00, 29.53),
          vec3(1047.75, -2273.25, 29.56),
          vec3(1056.50, -2177.00, 30.75),
          vec3(1072.25, -2103.50, 32.56),
          vec3(1082.25, -2089.00, 33.97),
          vec3(1177.50, -2073.25, 41.84),
          vec3(1263.50, -2044.00, 43.34),
          vec3(1353.50, -2003.00, 50.81),
          vec3(1419.25, -1939.25, 66.75),
          vec3(1435.50, -1843.00, 69.78),
          vec3(1414.25, -1771.50, 64.97),
          vec3(1394.75, -1766.00, 64.84),
          vec3(1303.75, -1792.25, 48.25),
          vec3(1214.00, -1825.25, 37.34),
          vec3(1122.25, -1858.75, 36.34),
          vec3(1031.75, -1884.50, 27.88),
          vec3(972.75, -1886.00, 30.31),
          vec3(956.25, -1884.50, 30.25),
          vec3(950.00, -1871.75, 30.22),
          vec3(956.25, -1785.00, 30.31),
          vec3(957.75, -1763.75, 30.28),
          vec3(938.25, -1762.25, 30.25),
          vec3(852.75, -1752.75, 28.56),
          vec3(827.75, -1750.00, 28.47),
          vec3(812.75, -1768.50, 28.09),
          vec3(800.10, -1854.35, 28.36),
        },
        loop   = true,
      },
    },
    {
      label  = 'Rockford Hills & Morningwood',
      start  = { coords = vec3(-921.68, -141.19, 37.75), radius = 25.0 },  -- the loop's last waypoint
      spawn  = vec4(-882.50, -115.00, 37.44, 296.03),   -- getaway car on waypoint 1, 47 m ahead of the start
      -- 31 road waypoints, 1961 m flee loop: Boulevard Del Perro > Rockford Dr > Dorset Dr > Marathon Ave > Morningwood Blvd > Boulevard Del Perro
      route  = {
        points = {
          vec3(-882.50, -115.00, 36.94),
          vec3(-806.75, -78.00, 36.81),
          vec3(-724.50, -41.50, 36.81),
          vec3(-711.50, -28.50, 36.88),
          vec3(-704.25, -42.25, 36.78),
          vec3(-658.00, -125.75, 36.75),
          vec3(-613.25, -203.50, 36.56),
          vec3(-568.00, -281.50, 34.16),
          vec3(-531.50, -349.50, 34.16),
          vec3(-530.75, -371.25, 34.16),
          vec3(-544.00, -362.75, 34.31),
          vec3(-631.50, -372.25, 33.78),
          vec3(-685.25, -362.00, 33.50),
          vec3(-758.75, -324.00, 35.53),
          vec3(-783.50, -322.00, 35.88),
          vec3(-862.50, -283.50, 39.38),
          vec3(-879.25, -273.75, 39.50),
          vec3(-961.50, -324.50, 36.97),
          vec3(-1048.00, -368.75, 36.94),
          vec3(-1128.50, -408.25, 35.47),
          vec3(-1216.25, -429.25, 32.66),
          vec3(-1240.00, -447.25, 32.56),
          vec3(-1246.50, -430.25, 32.69),
          vec3(-1288.25, -363.75, 35.72),
          vec3(-1303.25, -347.00, 35.69),
          vec3(-1279.00, -343.00, 35.72),
          vec3(-1199.50, -300.25, 36.88),
          vec3(-1122.50, -254.25, 36.75),
          vec3(-1056.50, -208.50, 36.88),
          vec3(-969.50, -169.00, 36.84),
          vec3(-921.68, -141.19, 36.75),
        },
        loop   = true,
      },
    },
    {
      label  = 'Hawick & Alta',
      start  = { coords = vec3(0.66, -142.07, 56.44), radius = 25.0 },  -- the loop's last waypoint
      spawn  = vec4(46.25, -154.00, 54.75, 245.04),   -- getaway car on waypoint 1, 47 m ahead of the start
      -- 26 road waypoints, 1654 m flee loop: Hawick Ave > Meteor St > Spanish Ave > San Vitus Blvd > Hawick Ave
      route  = {
        points = {
          vec3(46.25, -154.00, 54.25),
          vec3(133.25, -194.50, 53.53),
          vec3(208.25, -220.75, 53.06),
          vec3(294.50, -244.75, 53.03),
          vec3(339.00, -262.50, 52.94),
          vec3(355.00, -268.75, 52.94),
          vec3(370.75, -251.25, 52.94),
          vec3(396.25, -172.25, 62.00),
          vec3(392.00, -158.25, 63.16),
          vec3(400.00, -131.50, 63.88),
          vec3(381.00, -122.00, 64.06),
          vec3(293.25, -90.25, 69.12),
          vec3(200.75, -54.50, 67.84),
          vec3(109.50, -21.00, 66.88),
          vec3(21.00, 11.00, 69.41),
          vec3(-68.25, 45.75, 71.06),
          vec3(-153.25, 92.50, 69.69),
          vec3(-209.25, 122.50, 68.69),
          vec3(-227.75, 123.25, 68.66),
          vec3(-234.00, 104.00, 68.56),
          vec3(-248.75, 13.25, 52.28),
          vec3(-258.75, -24.50, 48.53),
          vec3(-255.25, -47.00, 48.53),
          vec3(-183.00, -80.75, 51.38),
          vec3(-96.25, -104.25, 56.84),
          vec3(0.66, -142.07, 55.44),
        },
        loop   = true,
      },
    },
    {
      label  = 'Banham Canyon & Chumash',
      start  = { coords = vec3(-3016.45, 295.47, 15.11), radius = 25.0 },  -- the loop's last waypoint
      spawn  = vec4(-3001.50, 340.00, 14.06, 352.64),   -- getaway car on waypoint 1, 47 m ahead of the start
      -- 40 road waypoints, 2463 m flee loop: Great Ocean Hwy > Barbareno Rd > Great Ocean Hwy > Ineseno Road > Great Ocean Hwy
      route  = {
        points = {
          vec3(-3001.50, 340.00, 13.56),
          vec3(-2990.00, 429.00, 14.00),
          vec3(-2986.25, 519.00, 14.72),
          vec3(-3000.50, 613.75, 19.16),
          vec3(-3031.50, 704.00, 21.94),
          vec3(-3090.75, 779.50, 18.53),
          vec3(-3135.50, 850.25, 14.88),
          vec3(-3156.75, 945.00, 13.53),
          vec3(-3129.25, 1029.50, 18.31),
          vec3(-3110.75, 1123.25, 19.41),
          vec3(-3103.50, 1219.00, 19.28),
          vec3(-3093.25, 1299.50, 19.19),
          vec3(-3090.00, 1316.00, 19.19),
          vec3(-3112.50, 1320.25, 19.09),
          vec3(-3130.75, 1320.00, 18.19),
          vec3(-3145.00, 1315.00, 16.78),
          vec3(-3164.50, 1291.50, 13.34),
          vec3(-3181.00, 1206.25, 8.66),
          vec3(-3206.00, 1116.25, 9.19),
          vec3(-3229.00, 1020.75, 10.94),
          vec3(-3219.75, 933.50, 12.84),
          vec3(-3210.00, 920.50, 13.16),
          vec3(-3196.00, 912.75, 13.41),
          vec3(-3154.50, 913.25, 13.38),
          vec3(-3121.25, 823.75, 16.06),
          vec3(-3083.25, 770.00, 19.09),
          vec3(-3072.00, 756.00, 19.91),
          vec3(-3091.25, 740.75, 20.12),
          vec3(-3095.25, 726.75, 20.38),
          vec3(-3047.25, 645.00, 7.03),
          vec3(-3019.00, 550.00, 6.62),
          vec3(-3034.50, 456.00, 5.38),
          vec3(-3069.00, 369.25, 6.09),
          vec3(-3093.25, 273.00, 9.06),
          vec3(-3092.25, 255.75, 10.50),
          vec3(-3086.00, 240.75, 12.12),
          vec3(-3072.50, 231.00, 14.03),
          vec3(-3049.00, 227.00, 15.19),
          vec3(-3030.50, 226.25, 15.09),
          vec3(-3016.45, 295.47, 14.11),
        },
        loop   = true,
      },
    },
    {
      label  = 'Strawberry & Chamberlain Hills',
      start  = { coords = vec3(-309.65, -1570.50, 23.89), radius = 25.0 },  -- the loop's last waypoint
      spawn  = vec4(-333.50, -1611.00, 19.84, 147.14),   -- getaway car on waypoint 1, 47 m ahead of the start
      -- 30 road waypoints, 1641 m flee loop: Alta St > Davis Ave > Strawberry Ave > Innocence Blvd > Alta St
      route  = {
        points = {
          vec3(-333.50, -1611.00, 19.34),
          vec3(-385.50, -1691.50, 17.81),
          vec3(-409.25, -1753.50, 19.28),
          vec3(-406.50, -1792.25, 20.56),
          vec3(-398.75, -1815.75, 20.41),
          vec3(-385.75, -1832.75, 20.62),
          vec3(-292.75, -1840.25, 25.12),
          vec3(-254.75, -1834.00, 27.66),
          vec3(-235.25, -1825.50, 28.94),
          vec3(-195.25, -1802.00, 28.91),
          vec3(-184.00, -1786.25, 28.84),
          vec3(-115.75, -1724.25, 28.97),
          vec3(-60.50, -1642.50, 28.34),
          vec3(9.50, -1578.25, 28.34),
          vec3(63.00, -1506.00, 28.31),
          vec3(92.00, -1483.75, 28.28),
          vec3(145.25, -1416.50, 28.25),
          vec3(154.25, -1394.25, 28.28),
          vec3(138.25, -1378.25, 28.31),
          vec3(93.75, -1358.00, 28.31),
          vec3(-2.25, -1361.50, 28.38),
          vec3(-99.50, -1367.25, 28.41),
          vec3(-161.25, -1387.50, 29.16),
          vec3(-210.50, -1421.25, 30.34),
          vec3(-228.75, -1429.50, 30.34),
          vec3(-245.25, -1422.50, 30.28),
          vec3(-275.75, -1431.00, 30.34),
          vec3(-283.50, -1450.50, 30.34),
          vec3(-287.25, -1525.75, 26.94),
          vec3(-309.65, -1570.50, 22.89),
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
