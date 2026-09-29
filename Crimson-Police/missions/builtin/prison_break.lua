--[[ Crimson-Police · built-in mission: Prison Break (prison_break)
  Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
  5 inmates (scale) in prison clothes are already outside the fence and scattering on foot along the escape
  routes; 2 in every 5 carry pistols and fire when a participant is within 15 m. Catch and cuff them all.
  An unarmed inmate gives up when aimed at within 10 m, stunned, or when a participant stays within 3 m
  for 3 s; an armed one only when stunned or below 50% health. Escape: 600 m from everyone for 30 s.
  Locations (6 breakout points on the outer perimeter of Bolingbroke Penitentiary: north, north-east, east
  beyond the visitor lot, west, north-west and south-west). Nothing is placed inside the walls: every
  point is outside the 180 m Bolingbroke no-build circle around 1768.73, 2570.43 and at least 240 m from
  the prison's middle (1693.33, 2569.51). Breakout points, inmate spawns and escape routes are on the GTA V
  vehicle-node network (dirt tracks and roads round the prison, never a freeway or its ramps), so every
  height is the real ground height (+1 m for peds and waypoints) instead of one estimated z per location,
  and every escape route follows a connected track / road away from the prison (waypoints at every turn).
  Blocks: flee_arrest (scatter mode).
]]

RegisterMission({
  id           = 'prison_break',
  label        = 'Prison Break',
  description  = 'Inmates have broken out of Bolingbroke Penitentiary and are scattering into the desert. Catch and cuff every inmate before they get away. Some of them are armed.',
  type         = 'tactical',      -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 600,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = false,       -- vehicles take gunfire here, so no heavy-damage penalty

  locations = {
    {
      label  = 'North fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1718.50, 2842.25, 44.47), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(1718.50, 2842.25, 45.47, 354.7), vec4(1722.20, 2844.75, 45.44, 354.0),
        vec4(1715.67, 2838.25, 45.43, 355.2), vec4(1725.90, 2847.25, 45.42, 353.3),
        vec4(1714.00, 2833.83, 45.44, 355.5), vec4(1729.50, 2849.85, 45.42, 352.6),
        vec4(1713.50, 2829.00, 45.50, 355.6), vec4(1716.25, 2825.25, 45.48, 354.9),
      },
      routes = {   -- 3 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(1718.50, 2842.25, 45.47), vec3(1794.00, 2873.75, 45.53), vec3(1807.25, 2885.75, 45.44),
          vec3(1797.50, 2899.50, 45.69), vec3(1776.25, 2905.50, 45.75), vec3(1778.75, 2922.75, 45.75),
          vec3(1872.75, 2955.25, 45.75), vec3(1935.50, 2971.50, 45.78), vec3(1928.25, 2993.25, 45.62),
          vec3(1959.75, 3088.00, 46.88), vec3(1971.00, 3105.50, 46.91), vec3(2008.50, 3133.00, 46.34) },
        { vec3(1718.50, 2842.25, 45.47), vec3(1794.00, 2873.75, 45.53), vec3(1807.25, 2885.75, 45.44),
          vec3(1797.50, 2899.50, 45.69), vec3(1776.25, 2905.50, 45.75), vec3(1778.75, 2922.75, 45.75),
          vec3(1872.75, 2955.25, 45.75), vec3(1977.75, 2980.75, 45.78), vec3(2083.50, 2999.25, 45.09),
          vec3(2107.00, 3002.75, 45.12), vec3(2127.25, 2987.00, 45.53) },
        { vec3(1718.50, 2842.25, 45.47), vec3(1814.75, 2869.25, 45.53), vec3(1888.25, 2795.00, 45.50),
          vec3(1945.25, 2750.75, 45.28), vec3(2007.25, 2674.50, 46.72), vec3(2021.50, 2674.00, 47.03),
          vec3(2105.50, 2741.75, 48.97), vec3(2133.75, 2764.25, 49.78) },
      },
    },
    {
      label  = 'North-east fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1910.50, 2791.25, 44.28), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(1910.50, 2791.25, 45.28, 315.6), vec4(1908.50, 2795.08, 45.30, 316.4),
        vec4(1913.75, 2786.50, 45.34, 314.6), vec4(1906.50, 2799.12, 45.36, 317.1),
        vec4(1917.00, 2782.00, 45.47, 313.5), vec4(1903.75, 2804.75, 45.47, 318.2),
        vec4(1920.25, 2778.00, 45.44, 312.6), vec4(1902.00, 2808.50, 45.50, 318.9),
      },
      routes = {   -- 2 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(1910.50, 2791.25, 45.28), vec3(1976.50, 2707.50, 46.00), vec3(2007.25, 2674.50, 46.72),
          vec3(2021.50, 2674.00, 47.03), vec3(2105.50, 2741.75, 48.97), vec3(2182.50, 2810.50, 48.31),
          vec3(2184.00, 2912.75, 46.59), vec3(2164.00, 2961.50, 46.53), vec3(2172.00, 2969.75, 46.53) },
        { vec3(1910.50, 2791.25, 45.28), vec3(1938.00, 2760.50, 45.47), vec3(1939.00, 2751.75, 45.53),
          vec3(1868.75, 2822.00, 45.56), vec3(1814.75, 2869.25, 45.53), vec3(1807.75, 2889.75, 45.62),
          vec3(1780.50, 2904.25, 45.72), vec3(1769.25, 2918.50, 45.75), vec3(1872.75, 2955.25, 45.75),
          vec3(1935.50, 2971.50, 45.78), vec3(1928.25, 2993.25, 45.62), vec3(1924.50, 3025.75, 45.72) },
      },
    },
    {
      label  = 'East side, beyond the visitor lot',
      start  = { coords = vec3(2001.25, 2679.00, 45.34), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(2001.25, 2679.00, 46.34, 289.6), vec4(2005.50, 2675.88, 46.64, 288.8),
        vec4(1995.75, 2683.00, 46.06, 290.6), vec4(2008.44, 2672.50, 46.78, 288.1),
        vec4(1990.88, 2687.25, 45.81, 291.6), vec4(2010.81, 2668.50, 46.91, 287.3),
        vec4(2008.30, 2663.50, 46.94, 286.6), vec4(2015.17, 2669.00, 46.99, 287.2),
      },
      routes = {   -- 2 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(2001.25, 2679.00, 46.34), vec3(2021.50, 2674.00, 47.03), vec3(2105.50, 2741.75, 48.97),
          vec3(2182.50, 2810.50, 48.31), vec3(2184.00, 2912.75, 46.59), vec3(2164.00, 2961.50, 46.53),
          vec3(2211.00, 3011.25, 45.28), vec3(2301.50, 2994.75, 46.81) },
        { vec3(2001.25, 2679.00, 46.34), vec3(2021.50, 2674.00, 47.03), vec3(2105.50, 2741.75, 48.97),
          vec3(2182.50, 2810.50, 48.31), vec3(2187.50, 2849.75, 47.12), vec3(2177.25, 2865.00, 46.91),
          vec3(2090.00, 2922.25, 47.62), vec3(2058.75, 2938.25, 47.31) },
      },
    },
    {
      label  = 'West fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1383.50, 2557.50, 37.34), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(1383.50, 2557.50, 38.34, 92.2), vec4(1380.00, 2559.62, 38.12, 91.8),
        vec4(1386.88, 2555.12, 38.81, 92.7), vec4(1376.50, 2561.75, 37.91, 91.4),
        vec4(1390.25, 2552.75, 39.28, 93.2), vec4(1393.12, 2549.75, 39.81, 93.8),
        vec4(1372.88, 2563.88, 37.83, 91.0), vec4(1396.00, 2546.75, 40.34, 94.4),
      },
      routes = {   -- 2 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(1383.50, 2557.50, 38.34), vec3(1293.50, 2605.00, 37.69), vec3(1258.50, 2670.50, 37.50),
          vec3(1243.50, 2682.00, 37.59), vec3(1139.50, 2684.75, 38.28), vec3(1032.25, 2690.25, 39.44),
          vec3(927.75, 2695.75, 40.66), vec3(905.75, 2696.50, 40.84) },
        { vec3(1383.50, 2557.50, 38.34), vec3(1293.50, 2605.00, 37.69), vec3(1258.50, 2670.50, 37.50),
          vec3(1243.50, 2682.00, 37.59), vec3(1139.50, 2684.75, 38.28), vec3(1121.75, 2782.25, 37.59),
          vec3(1110.25, 2841.50, 38.59), vec3(1090.00, 2844.50, 38.53), vec3(1056.25, 2847.25, 40.06) },
      },
    },
    {
      label  = 'North-west fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1477.75, 2732.75, 36.72), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(1477.75, 2732.75, 37.72, 52.9), vec4(1474.21, 2730.83, 37.70, 53.6),
        vec4(1481.25, 2734.95, 37.74, 52.0), vec4(1470.67, 2728.92, 37.68, 54.4),
        vec4(1484.75, 2737.15, 37.77, 51.2), vec4(1467.12, 2727.00, 37.66, 55.2),
        vec4(1488.25, 2739.35, 37.79, 50.4), vec4(1463.58, 2725.08, 37.64, 55.9),
      },
      routes = {   -- 3 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(1477.75, 2732.75, 37.72), vec3(1380.75, 2690.50, 37.66), vec3(1311.75, 2683.00, 37.69),
          vec3(1207.50, 2682.25, 37.75), vec3(1107.50, 2686.00, 38.62), vec3(1017.00, 2691.00, 39.56),
          vec3(948.50, 2695.00, 40.41) },
        { vec3(1477.75, 2732.75, 37.72), vec3(1380.75, 2690.50, 37.66), vec3(1311.75, 2683.00, 37.69),
          vec3(1207.50, 2682.25, 37.75), vec3(1139.50, 2684.75, 38.28), vec3(1121.75, 2782.25, 37.59),
          vec3(1128.75, 2872.75, 39.34) },
        { vec3(1477.75, 2732.75, 37.72), vec3(1562.50, 2789.75, 38.28), vec3(1631.75, 2837.00, 39.84),
          vec3(1723.50, 2894.00, 44.91), vec3(1815.75, 2937.25, 45.78), vec3(1904.25, 2964.00, 45.75),
          vec3(1935.50, 2971.50, 45.78), vec3(1928.25, 2993.25, 45.62), vec3(1925.50, 3006.75, 45.69) },
      },
    },
    {
      label  = 'South-west fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1417.00, 2409.75, 58.50), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns on the track / road at the breakout point outside the fence (z = road + 1 m, facing away from the prison)
        vec4(1417.00, 2409.75, 59.50, 120.0), vec4(1419.25, 2414.75, 58.44, 119.5),
        vec4(1414.25, 2405.00, 60.69, 120.5), vec4(1421.75, 2419.50, 57.47, 118.9),
        vec4(1411.50, 2400.25, 61.91, 121.0), vec4(1409.00, 2395.50, 63.19, 121.5),
        vec4(1424.25, 2424.50, 56.69, 118.3), vec4(1406.50, 2390.75, 64.50, 121.9),
      },
      routes = {   -- 2 escape routes along tracks and roads away from the prison (road-node waypoints at every turn, <= 110 m apart)
        { vec3(1417.00, 2409.75, 59.50), vec3(1397.50, 2359.75, 72.50), vec3(1383.00, 2352.50, 72.53),
          vec3(1277.75, 2374.25, 73.09), vec3(1182.50, 2372.50, 57.69), vec3(1165.25, 2376.50, 57.59),
          vec3(1162.50, 2459.50, 54.16), vec3(1150.00, 2477.00, 54.00), vec3(1121.75, 2480.25, 51.69),
          vec3(1061.25, 2436.25, 49.56), vec3(1023.50, 2443.00, 44.78) },
        { vec3(1417.00, 2409.75, 59.50), vec3(1397.50, 2359.75, 72.50), vec3(1383.00, 2352.50, 72.53),
          vec3(1277.75, 2374.25, 73.09), vec3(1176.50, 2372.50, 57.59), vec3(1169.00, 2279.00, 51.91),
          vec3(1166.50, 2256.25, 48.81), vec3(1144.75, 2247.25, 49.78), vec3(1122.50, 2267.50, 49.16) },
      },
    },
  },

  objectives = {
    {
      block        = 'flee_arrest',
      label        = 'Catch the escaped inmates',
      minSeconds   = 30,
      mode         = 'scatter',
      spawns       = 'spawns',
      routes       = 'routes',
      suspects     = 5,                                          -- inmates (base 5, scales)
      armedShare   = 0.4,                                        -- 2 in every 5 carry pistols
      models       = { 's_m_y_prisoner_01', 's_m_y_prismuscl_01' },   -- prison clothes
      weapons      = { 'WEAPON_PISTOL' },
      fireWithin   = 15.0,
      escape       = { distance = 600, seconds = 30 },
      givesUp      = { aim = 10.0, stun = true, close = { distance = 3.0, seconds = 3 } },
      armedGivesUp = { stun = true, belowHealth = 0.5 },
      cuff         = { label = 'Cuff suspect', duration = 5000 },
      aliveBonus   = { id = 'inmate_alive', points = 10, each = true },
    },
  },

  scaling   = { 'objectives.1.suspects' },   -- inmates
  items     = {},                            -- no items for this mission
  bonuses   = {
    { id = 'inmate_alive', points = 10, each = true },   -- +10 per inmate arrested alive
  },
  penalties = {},                            -- the common penalties always apply
})
