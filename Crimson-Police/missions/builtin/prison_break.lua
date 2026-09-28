--[[ Crimson-Police · built-in mission: Prison Break (prison_break)
  Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
  5 inmates (scale) in prison clothes are already outside the fence and scattering on foot along the escape
  routes; 2 in every 5 carry pistols and fire when a participant is within 15 m. Catch and cuff them all.
  An unarmed inmate gives up when aimed at within 10 m, stunned, or when a participant stays within 3 m
  for 3 s; an armed one only when stunned or below 50% health. Escape: 600 m from everyone for 30 s.
  Locations (6 breakout points on the outer perimeter of Bolingbroke Penitentiary: north, north-east, east
  beyond the visitor lot, west, north-west and south-west). Nothing is placed inside the walls: every
  point is outside the 180 m Bolingbroke no-build circle around 1768.73, 2570.43 and at least 240 m from
  the prison's middle (1693.33, 2569.51).
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
      start  = { coords = vec3(1706.92, 2851.95, 45.80), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1718.98, 2811.33, 46.30, 357.2), vec4(1713.18, 2815.61, 46.30, 357.2),
        vec4(1708.04, 2812.85, 46.30, 357.2), vec4(1702.24, 2817.14, 46.30, 357.2),
        vec4(1697.06, 2813.38, 46.30, 357.2), vec4(1691.21, 2816.67, 46.30, 357.2),
        vec4(1723.36, 2819.13, 46.30, 357.2), vec4(1687.45, 2821.85, 46.30, 357.2),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(1758.39, 2857.97, 45.80), vec3(1798.02, 2930.29, 45.80),
          vec3(1873.80, 2982.79, 45.80), vec3(1927.00, 3069.79, 45.80) },
        { vec3(1700.37, 2882.30, 45.80), vec3(1724.20, 2961.25, 45.80),
          vec3(1708.55, 3052.11, 45.80), vec3(1733.33, 3151.03, 45.80) },
        { vec3(1771.71, 2834.66, 45.80), vec3(1854.13, 2832.09, 45.80),
          vec3(1937.84, 2870.72, 45.80), vec3(2039.81, 2872.38, 45.80) },
      },
    },
    {
      label  = 'North-east fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1918.01, 2798.55, 46.30), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1899.99, 2760.20, 46.80, 315.6), vec4(1898.51, 2767.25, 46.80, 315.6),
        vec4(1892.84, 2768.61, 46.80, 315.6), vec4(1891.36, 2775.67, 46.80, 315.6),
        vec4(1884.99, 2776.32, 46.80, 315.6), vec4(1882.81, 2782.66, 46.80, 315.6),
        vec4(1908.45, 2763.11, 46.80, 315.6), vec4(1883.45, 2789.03, 46.80, 315.6),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(1960.45, 2768.81, 46.30), vec3(2038.14, 2796.45, 46.30),
          vec3(2129.65, 2785.25, 46.30), vec3(2227.24, 2814.83, 46.30) },
        { vec3(1933.31, 2825.57, 46.30), vec3(2003.61, 2868.68, 46.30),
          vec3(2052.35, 2946.93, 46.30), vec3(2136.66, 3004.31, 46.30) },
        { vec3(1903.41, 2839.17, 46.30), vec3(1889.67, 2920.48, 46.30),
          vec3(1916.59, 3008.66, 46.30), vec3(1904.41, 3109.91, 46.30) },
      },
    },
    {
      label  = 'East side, beyond the visitor lot',
      start  = { coords = vec3(2029.86, 2541.71, 47.00), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1988.85, 2531.05, 47.50, 265.3), vec4(1993.33, 2536.70, 47.50, 265.3),
        vec4(1990.75, 2541.93, 47.50, 265.3), vec4(1995.23, 2547.58, 47.50, 265.3),
        vec4(1991.66, 2552.89, 47.50, 265.3), vec4(1995.14, 2558.62, 47.50, 265.3),
        vec4(1996.49, 2526.40, 47.50, 265.3), vec4(2000.45, 2562.20, 47.50, 265.3),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(2034.11, 2490.06, 47.00), vec3(2105.02, 2447.97, 47.00),
          vec3(2154.90, 2370.43, 47.00), vec3(2240.02, 2314.28, 47.00) },
        { vec3(2051.77, 2578.90, 47.00), vec3(2105.52, 2641.43, 47.00),
          vec3(2190.55, 2677.08, 47.00), vec3(2260.63, 2751.16, 47.00) },
        { vec3(2006.09, 2613.59, 47.00), vec3(2051.92, 2682.15, 47.00),
          vec3(2063.46, 2773.62, 47.00), vec3(2116.04, 2861.00, 47.00) },
      },
    },
    {
      label  = 'West fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1410.31, 2604.97, 44.80), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1451.74, 2613.89, 45.30, 82.9), vec4(1447.03, 2608.44, 45.30, 82.9),
        vec4(1449.38, 2603.10, 45.30, 82.9), vec4(1444.67, 2597.64, 45.30, 82.9),
        vec4(1448.01, 2592.19, 45.30, 82.9), vec4(1444.29, 2586.61, 45.30, 82.9),
        vec4(1444.30, 2618.85, 45.30, 82.9), vec4(1438.83, 2583.26, 45.30, 82.9),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(1408.25, 2656.75, 44.80), vec3(1339.18, 2701.79, 44.80),
          vec3(1292.62, 2781.37, 44.80), vec3(1209.94, 2841.07, 44.80) },
        { vec3(1379.55, 2600.77, 44.80), vec3(1302.66, 2630.56, 44.80),
          vec3(1210.87, 2621.90, 44.80), vec3(1114.13, 2654.18, 44.80) },
        { vec3(1386.86, 2568.74, 44.80), vec3(1330.51, 2508.54, 44.80),
          vec3(1244.06, 2476.51, 44.80), vec3(1170.90, 2405.45, 44.80) },
      },
    },
    {
      label  = 'North-west fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1487.66, 2789.20, 45.30), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1525.22, 2769.57, 45.80, 43.1), vec4(1518.11, 2768.39, 45.80, 43.1),
        vec4(1516.51, 2762.78, 45.80, 43.1), vec4(1509.39, 2761.60, 45.80, 43.1),
        vec4(1508.48, 2755.26, 45.80, 43.1), vec4(1502.05, 2753.35, 45.80, 43.1),
        vec4(1522.67, 2778.14, 45.80, 43.1), vec4(1495.71, 2754.27, 45.80, 43.1),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(1446.46, 2776.34, 45.30), vec3(1364.64, 2766.08, 45.30),
          vec3(1277.69, 2796.73, 45.30), vec3(1176.01, 2788.86, 45.30) },
        { vec3(1457.03, 2719.96, 45.30), vec3(1377.04, 2699.91, 45.30),
          vec3(1307.08, 2639.86, 45.30), vec3(1209.46, 2610.38, 45.30) },
      },
    },
    {
      label  = 'South-west fence, Bolingbroke Penitentiary',
      start  = { coords = vec3(1475.66, 2367.81, 46.80), radius = 150.0 },   -- within 150 m of the breakout point
      spawns = {   -- 8 inmate spawns just outside the fence (none inside the walls)
        vec4(1495.48, 2405.27, 47.30, 132.8), vec4(1496.63, 2398.15, 47.30, 132.8),
        vec4(1502.23, 2396.52, 47.30, 132.8), vec4(1503.37, 2389.40, 47.30, 132.8),
        vec4(1509.70, 2388.45, 47.30, 132.8), vec4(1511.58, 2382.01, 47.30, 132.8),
        vec4(1486.90, 2402.77, 47.30, 132.8), vec4(1510.63, 2375.68, 47.30, 132.8),
      },
      routes = {   -- escape routes heading away from the prison into the countryside
        { vec3(1434.69, 2399.55, 46.80), vec3(1355.77, 2375.64, 46.80),
          vec3(1264.90, 2391.19, 46.80), vec3(1166.00, 2366.29, 46.80) },
        { vec3(1459.09, 2341.55, 46.80), vec3(1386.82, 2301.85, 46.80),
          vec3(1334.40, 2226.01, 46.80), vec3(1247.45, 2172.71, 46.80) },
        { vec3(1488.31, 2326.55, 46.80), vec3(1498.15, 2244.68, 46.80),
          vec3(1467.06, 2157.88, 46.80), vec3(1474.40, 2056.17, 46.80) },
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
