--[[ Crimson-Police · built-in mission: Drug Lab Raid (drug_lab_raid)
  Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  Breach a rural drug lab together, neutralise the crew (9 hostiles in waves of 5 / 4, scaled; tactics rolled
  hold 50 / balanced 40 / push 10), catch the cooks when they bolt, find the stashes and seize the product,
  shut the lab down with three skill checks (two misses in a row start a toxic fire: a setback, never a
  fail) and process the scene.
  Locations (7 labs): Cabin, Raton Canyon, Oil-field shed, El Burro Heights, Warehouse, Cypress Flats, Shack, Lago Zancudo, Farmstead, south of Harmony, Trailer, north of Stab City, Cabin, Zancudo River.
  Every point sits on the GTA V vehicle-node network or 3 m beside it (driveways, yard lanes and dirt
  tracks), at the site's ground level, so no ped spawns inside a wall: the lab point is the node nearest the
  building, the two entries 6–18 m from it facing it, the "inside" set within 32 m and the "yard" set
  18–68 m out, the stash spots 4–48 m around, escape routes follow the tracks away from the approach road.
  The start is on that road 50–78 m from the lab and at least 33 m from every spawn; every point is at least
  250 m from any other mission's locations (tests/zone_lint_spec.lua). Not O'Neil Ranch (the Weekly Boss).
  Blocks: interact_points (together) → hostile_waves → flee_arrest (scatter) → interact_points (seize)
  → skill_check (setback) → process_scene.
]]

RegisterMission({
  id           = 'drug_lab_raid',
  label        = 'Drug Lab Raid',
  description  = 'A drug lab is running out of a remote building. Breach it together, neutralise the crew, catch the cooks, seize the product, shut the lab down and process the scene.',
  type         = 'tactical',     -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 2,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 720,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 1200,           -- per officer, seconds
  vehiclePenalties = false,      -- vehicles take gunfire here, so no heavy-damage penalty

  locations = {
    {
      label   = 'Cabin, Raton Canyon',
      start   = { coords = vec3(-1576.00, 4668.50, 45.69), radius = 50.0 },   -- on the approach road, 62 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(-1535.87, 4692.37, 42.00, 299.5), vec4(-1527.54, 4695.90, 42.45, 308.4),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(-1522.75, 4697.12, 40.81, 118.3), vec4(-1526.47, 4701.11, 42.11, 123.4),
        vec4(-1530.05, 4703.01, 43.20, 126.9), vec4(-1530.42, 4696.75, 42.45, 121.8),
        vec4(-1528.87, 4691.40, 41.97, 115.9), vec4(-1534.00, 4702.25, 43.72, 128.8),
        vec4(-1533.87, 4694.37, 41.97, 121.6),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(-1533.63, 4686.13, 42.03, 112.6), vec4(-1537.06, 4710.49, 45.25, 137.2),
        vec4(-1537.87, 4690.37, 42.03, 119.8), vec4(-1540.69, 4705.26, 44.89, 136.2),
        vec4(-1539.75, 4684.50, 42.25, 113.8), vec4(-1544.87, 4709.88, 46.19, 143.0),
        vec4(-1542.44, 4715.67, 46.59, 144.6),
      },
      cook    = { vec4(-1539.00, 4712.50, 45.72, 45.0) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(-1570.11, 4737.04, 50.80), vec3(-1530.89, 4739.53, 51.63), vec3(-1461.50, 4805.00, 85.75) },
        { vec3(-1508.58, 4697.58, 37.72), vec3(-1468.79, 4701.21, 38.82), vec3(-1423.00, 4722.50, 42.66) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(-1531.88, 4700.62, 43.20, 52.6), vec4(-1531.75, 4692.25, 41.97, 163.5),
        vec4(-1533.38, 4705.87, 44.12, 45.0), vec4(-1537.62, 4701.63, 44.12, 45.0),
        vec4(-1538.25, 4707.00, 44.89, 35.5), vec4(-1535.75, 4688.25, 42.03, 135.0),
      },
      lab     = vec4(-1522.26, 4700.08, 40.81, 80.5),   -- "Shut down the lab"
      scene   = vec3(-1523.24, 4694.17, 40.01),   -- scene marker: Process the scene
      coroner = vec4(-1565.25, 4677.00, 45.38, 298.2),   -- where the coroner van parks
    },
    {
      label   = 'Oil-field shed, El Burro Heights',
      start   = { coords = vec3(1374.25, -2254.50, 61.47), radius = 50.0 },   -- on the approach road, 62 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(1385.28, -2307.67, 61.44, 243.8), vec4(1377.60, -2314.80, 61.53, 276.9),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(1394.50, -2315.50, 62.98, 18.4), vec4(1392.03, -2311.67, 62.34, 17.3),
        vec4(1399.10, -2313.81, 63.62, 22.7), vec4(1389.61, -2317.11, 62.34, 13.8),
        vec4(1397.61, -2319.61, 63.62, 19.7), vec4(1403.35, -2314.69, 64.23, 25.8),
        vec4(1387.53, -2309.00, 61.74, 13.7),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(1380.12, -2322.64, 61.42, 4.9), vec4(1377.45, -2309.05, 61.55, 3.4),
        vec4(1403.00, -2329.82, 63.72, 20.9), vec4(1413.80, -2317.60, 65.44, 32.1),
        vec4(1411.90, -2323.30, 65.44, 28.7), vec4(1375.62, -2318.38, 61.48, 1.2),
        vec4(1396.29, -2333.43, 62.79, 15.6),
      },
      cook    = { vec4(1403.54, -2336.07, 63.38, 121.0) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(1438.94, -2332.59, 66.83), vec3(1447.67, -2369.84, 66.71), vec3(1449.75, -2444.00, 64.16) },
        { vec3(1372.36, -2359.90, 61.03), vec3(1364.86, -2398.99, 56.38), vec3(1348.25, -2459.25, 48.66) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(1398.50, -2316.75, 63.62, 72.6), vec4(1393.61, -2318.36, 62.98, 72.6),
        vec4(1389.78, -2310.34, 62.04, 59.3), vec4(1386.72, -2315.50, 62.04, 59.3),
        vec4(1402.15, -2320.56, 64.23, 258.4), vec4(1383.75, -2310.25, 61.44, 59.3),
      },
      lab     = vec4(1395.39, -2312.64, 62.98, 72.6),   -- "Shut down the lab"
      scene   = vec3(1390.50, -2314.25, 61.54),   -- scene marker: Process the scene
      coroner = vec4(1393.25, -2267.00, 62.25, 182.7),   -- where the coroner van parks
    },
    {
      label   = 'Warehouse, Cypress Flats',
      start   = { coords = vec3(904.00, -2402.25, 29.69), radius = 50.0 },   -- on the approach road, 62 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(879.82, -2351.93, 30.33, 16.5), vec4(888.92, -2352.73, 30.39, 57.5),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(877.75, -2348.75, 30.31, 206.1), vec4(873.83, -2345.36, 30.31, 207.9),
        vec4(882.62, -2346.13, 30.34, 200.9), vec4(873.27, -2351.34, 30.31, 211.1),
        vec4(869.63, -2344.96, 30.31, 211.0), vec4(884.45, -2352.30, 30.36, 201.4),
        vec4(887.24, -2346.51, 30.38, 196.7),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(860.25, -2342.50, 30.31, 216.2), vec4(896.29, -2347.51, 30.44, 188.0),
        vec4(895.71, -2353.49, 30.44, 189.7), vec4(857.43, -2336.21, 30.31, 215.2),
        vec4(854.59, -2347.11, 30.31, 221.9), vec4(902.67, -2348.14, 30.50, 181.4),
        vec4(853.57, -2340.79, 30.31, 219.4),
      },
      cook    = { vec4(854.07, -2328.32, 30.32, 199.8) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(850.05, -2287.55, 30.31), vec3(853.63, -2247.72, 30.36), vec3(775.00, -2212.25, 29.31) },
        { vec3(850.05, -2287.55, 30.31), vec3(853.63, -2247.72, 30.36), vec3(879.50, -2245.50, 30.59) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(882.38, -2349.12, 30.34, 265.4), vec4(869.35, -2347.95, 30.31, 84.6),
        vec4(889.25, -2349.75, 30.39, 263.7), vec4(865.55, -2342.72, 30.31, 233.1),
        vec4(863.70, -2348.84, 30.31, 233.1), vec4(896.00, -2350.50, 30.44, 263.7),
      },
      lab     = vec4(877.99, -2345.76, 30.31, 265.4),   -- "Shut down the lab"
      scene   = vec3(873.55, -2348.35, 29.51),   -- scene marker: Process the scene
      coroner = vec4(906.25, -2378.50, 30.00, 40.8),   -- where the coroner van parks
    },
    {
      label   = 'Shack, Lago Zancudo',
      start   = { coords = vec3(-1541.50, 2703.00, 4.09), radius = 50.0 },   -- on the approach road, 61 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(-1586.62, 2706.22, 4.31, 85.8), vec4(-1595.18, 2710.45, 4.22, 111.9),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(-1600.43, 2708.45, 4.44, 264.7), vec4(-1605.27, 2706.26, 5.03, 267.1),
        vec4(-1605.23, 2712.86, 4.73, 261.2), vec4(-1598.88, 2712.25, 4.33, 260.8),
        vec4(-1609.02, 2703.55, 5.00, 269.5), vec4(-1610.36, 2709.95, 5.02, 264.2),
        vec4(-1597.32, 2716.05, 4.22, 256.8),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(-1620.25, 2711.81, 5.66, 263.6), vec4(-1617.36, 2718.00, 5.67, 258.8),
        vec4(-1616.41, 2695.48, 2.81, 275.7), vec4(-1604.62, 2725.50, 5.63, 250.4),
        vec4(-1611.33, 2723.54, 5.64, 253.6), vec4(-1588.37, 2695.86, 4.03, 278.7),
        vec4(-1611.34, 2691.02, 1.78, 279.7),
      },
      cook    = { vec4(-1632.31, 2709.45, 5.69, 105.7) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(-1665.68, 2727.64, 5.59), vec3(-1698.47, 2749.89, 5.63), vec3(-1753.00, 2719.25, 4.53) },
        { vec3(-1665.68, 2727.64, 5.59), vec3(-1698.47, 2749.89, 5.63), vec3(-1697.25, 2650.00, 0.94) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(-1606.50, 2709.00, 5.03, 125.2), vec4(-1597.81, 2709.45, 4.33, 290.9),
        vec4(-1602.73, 2713.99, 4.44, 294.2), vec4(-1610.47, 2705.86, 5.03, 32.5),
        vec4(-1609.52, 2700.62, 3.81, 7.1), vec4(-1613.46, 2710.59, 5.69, 32.0),
      },
      lab     = vec4(-1602.77, 2707.39, 4.73, 294.2),   -- "Shut down the lab"
      scene   = vec3(-1601.50, 2711.25, 3.64),   -- scene marker: Process the scene
      coroner = vec4(-1555.25, 2712.50, 4.16, 96.1),   -- where the coroner van parks
    },
    {
      label   = 'Farmstead, south of Harmony',
      start   = { coords = vec3(676.50, 2129.25, 65.03), radius = 50.0 },   -- on the approach road, 62 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(653.69, 2179.88, 63.78, 22.0), vec4(664.25, 2180.64, 62.94, 68.4),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(651.50, 2182.75, 63.95, 205.0), vec4(647.44, 2185.50, 64.28, 207.3),
        vec4(655.31, 2185.99, 63.61, 200.5), vec4(647.69, 2179.51, 64.28, 209.8),
        vec4(643.44, 2185.42, 64.66, 210.5), vec4(659.31, 2186.24, 63.28, 196.8),
        vec4(657.69, 2180.13, 63.45, 200.3),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(668.75, 2181.01, 62.59, 188.5), vec4(633.21, 2185.30, 65.64, 217.7),
        vec4(635.68, 2175.16, 65.70, 221.6), vec4(670.43, 2187.18, 62.43, 186.0),
        vec4(631.04, 2179.52, 65.60, 222.1), vec4(675.32, 2181.57, 62.10, 181.3),
        vec4(633.11, 2169.26, 66.00, 227.3),
      },
      cook    = { vec4(623.69, 2185.50, 66.59, 91.2) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(583.76, 2182.50, 71.07), vec3(543.81, 2180.80, 76.05), vec3(540.25, 2180.50, 76.50) },
        { vec3(663.71, 2183.60, 62.96), vec3(702.39, 2190.20, 59.88), vec3(656.00, 2305.25, 51.00) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(655.50, 2183.00, 63.61, 273.6), vec4(643.50, 2182.42, 64.66, 91.2),
        vec4(661.75, 2183.44, 63.11, 274.8), vec4(639.44, 2185.33, 65.03, 91.2),
        vec4(639.56, 2179.33, 65.03, 91.2), vec4(666.00, 2186.80, 62.77, 274.8),
      },
      lab     = vec4(651.31, 2185.74, 63.95, 273.6),   -- "Shut down the lab"
      scene   = vec3(647.50, 2182.50, 63.48),   -- scene marker: Process the scene
      coroner = vec4(677.25, 2184.75, 61.44, 87.8),   -- where the coroner van parks
    },
    {
      label   = 'Trailer, north of Stab City',
      start   = { coords = vec3(-359.00, 4002.00, 48.94), radius = 50.0 },   -- on the approach road, 61 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(-309.08, 3987.11, 43.59, 218.2), vec4(-299.17, 3984.39, 43.50, 151.9),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(-303.83, 3980.61, 43.50, 68.8), vec4(-300.68, 3976.24, 43.44, 66.2),
        vec4(-297.44, 3982.01, 43.47, 72.0), vec4(-306.46, 3983.86, 43.55, 71.0),
        vec4(-298.13, 3972.92, 43.34, 64.5), vec4(-294.62, 3978.20, 43.39, 69.7),
        vec4(-301.79, 3987.64, 43.55, 75.9),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(-286.98, 3968.51, 43.16, 65.1), vec4(-308.06, 3995.99, 43.64, 83.3),
        vec4(-313.92, 3993.92, 43.66, 79.8), vec4(-290.33, 3963.11, 43.12, 60.5),
        vec4(-283.04, 3963.64, 43.06, 63.2), vec4(-312.46, 4001.08, 43.86, 88.9),
        vec4(-318.23, 3998.42, 43.96, 85.0),
      },
      cook    = { vec4(-297.00, 3976.38, 43.39, 217.6) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(-273.19, 3946.84, 42.69), vec3(-248.28, 3915.60, 39.61), vec3(-224.75, 3939.75, 37.47) },
        { vec3(-273.19, 3946.84, 42.69), vec3(-248.28, 3915.60, 39.61), vec3(-221.50, 4005.50, 37.22) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(-304.12, 3985.75, 43.55, 38.9), vec4(-294.50, 3973.12, 43.30, 217.6),
        vec4(-304.42, 3990.89, 43.59, 38.9), vec4(-294.27, 3967.99, 43.22, 218.9),
        vec4(-289.60, 3971.76, 43.22, 218.9), vec4(-311.69, 3990.76, 43.62, 35.5),
      },
      lab     = vec4(-302.31, 3978.49, 43.47, 215.8),   -- "Shut down the lab"
      scene   = vec3(-301.50, 3982.50, 42.70),   -- scene marker: Process the scene
      coroner = vec4(-332.00, 4012.25, 45.69, 221.3),   -- where the coroner van parks
    },
    {
      label   = 'Cabin, Zancudo River',
      start   = { coords = vec3(-2357.50, 3428.25, 28.38), radius = 50.0 },   -- on the approach road, 62 m from the lab
      entries = {   -- the two entry points: "Stack up and breach"
        vec4(-2310.97, 3396.94, 30.88, 233.0), vec4(-2318.99, 3402.98, 30.70, 233.0),
      },
      inside  = {   -- spawn set "inside" (7 points)
        vec4(-2307.96, 3390.92, 30.99, 53.0), vec4(-2302.95, 3390.90, 31.06, 55.6),
        vec4(-2311.17, 3393.33, 30.92, 53.0), vec4(-2306.60, 3386.14, 31.06, 50.4),
        vec4(-2299.40, 3388.11, 31.09, 55.4), vec4(-2314.38, 3395.75, 30.84, 53.0),
        vec4(-2303.10, 3383.39, 31.09, 50.5),
      },
      yard    = {   -- spawn set "yard" (7 points)
        vec4(-2322.40, 3401.79, 30.66, 53.0), vec4(-2296.10, 3377.89, 31.13, 50.6),
        vec4(-2290.65, 3381.23, 31.14, 54.9), vec4(-2325.87, 3408.05, 30.44, 57.4),
        vec4(-2290.86, 3373.87, 31.27, 50.8), vec4(-2329.38, 3403.20, 30.44, 48.3),
        vec4(-2285.69, 3377.53, 31.38, 54.8),
      },
      cook    = { vec4(-2282.39, 3375.13, 31.61, 234.0) },   -- the cooks' hiding spot
      escapes = {   -- escape routes away from the start
        { vec3(-2244.30, 3366.57, 33.42), vec3(-2262.58, 3332.05, 32.86), vec3(-2179.50, 3285.00, 32.78) },
        { vec3(-2244.30, 3366.57, 33.42), vec3(-2262.58, 3332.05, 32.86), vec3(-2290.00, 3284.00, 32.84) },
      },
      stashes = {   -- stash spots (the hidden ones are rolled)
        vec4(-2309.76, 3388.52, 30.99, 53.0), vec4(-2314.58, 3392.15, 30.88, 53.0),
        vec4(-2301.25, 3385.75, 31.09, 231.8), vec4(-2314.17, 3399.35, 30.81, 53.0),
        vec4(-2295.90, 3385.36, 31.11, 231.8), vec4(-2319.39, 3395.77, 30.77, 53.0),
      },
      lab     = vec4(-2306.15, 3393.31, 30.99, 53.0),   -- "Shut down the lab"
      scene   = vec3(-2304.75, 3388.50, 30.26),   -- scene marker: Process the scene
      coroner = vec4(-2338.50, 3413.50, 29.38, 238.0),   -- where the coroner van parks
    },
  },

  objectives = {
    {
      block      = 'interact_points',
      label      = 'Stack up and breach',
      minSeconds = 3,
      points     = 'entries',
      target     = { label = 'Stack up and breach' },
      progress   = { label = 'Stacking up', duration = 3000, anim = 'kneel' },
      together   = { count = 2, window = 6, soloProgress = 8000 },   -- 2 officers within 6 s; solo 8 s each
    },
    {
      block        = 'hostile_waves',
      label        = 'Neutralise the lab crew',
      minSeconds   = 45,
      spawns       = 'inside',
      spawnSets    = { keys = { 'inside', 'yard' }, use = 2, intel = true },
      waves        = { 5, 4 },                                          -- base counts, scaled by tier
      nextWave     = { aliveAtMost = 2, afterSeconds = 90 },
      weapons      = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG', 'WEAPON_PUMPSHOTGUN' },
      accuracy     = 25,                                                -- plus the tier's accuracy
      armour       = 0,                                                 -- plus the tier's armour
      behaviour    = { hold = 0.5, balanced = 0.4, push = 0.1 },        -- rolled once per run
      surrender    = { belowHealth = 0.25, chance = 0.30 },
      peds         = { 'g_m_y_salvagoon_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01' },
      blockTraffic = 120.0,
    },
    {
      block      = 'flee_arrest',
      label      = 'Catch the cooks',
      minSeconds = 10,
      mode       = 'scatter',
      spawns     = 'cook',
      routes     = 'escapes',
      suspects   = 1,                                                   -- base 1, scaled (max 3)
      armedShare = 0,                                                   -- the cooks are unarmed
      models     = { 'a_m_m_salton_02', 'a_m_y_stbla_01' },
      demeanour  = 'runner',
      escape     = { distance = 400, seconds = 20 },
      givesUp    = { 'aim', 'stun', 'close' },
      cuff       = { label = 'Cuff suspect', duration = 5000 },
      aliveBonus = { id = 'cook_arrested', points = 10 },
    },
    {
      block      = 'interact_points',
      label      = 'Find and seize the stash',
      minSeconds = 10,
      points     = 'stashes',
      target     = { label = 'Search' },
      progress   = { label = 'Searching', duration = 4000, anim = 'search' },
      hidden     = {                                                    -- base 2, scaled (max 4)
        kind   = 'seize',
        count  = 2,
        label  = 'Stash',
        action = { label = 'Seize the product', duration = 6000 },     -- at each stash once it is found
      },
      fastBonus  = { id = 'stash_found_fast', seconds = 180, after = 1 },   -- timed from the breach
    },
    {
      block      = 'skill_check',
      label      = 'Shut down the lab',
      minSeconds = 5,
      targets    = 'lab',
      checks     = { 'medium', 'medium', 'hard' },
      missPenalty = 0,
      failAfter  = 2,
      explosion  = false,
      target     = { label = 'Shut down the lab' },
      onFail     = { setback = { label = 'Ventilate', duration = 10000, penalty = 'lab_fire' }, retryAfter = 30 },
    },
    {
      block      = 'process_scene',
      label      = 'Process the scene',
      minSeconds = 5,
      scene      = 'scene',
      coroner    = 'coroner',
      bodies     = 4,
    },
  },

  scaling   = {
    'objectives.2.waves',
    { path = 'objectives.3.suspects', max = 3 },
    { path = 'objectives.4.hidden.count', max = 4 },
  },
  items     = {},                                   -- the seized product is virtual evidence
  bonuses   = {
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
    { id = 'hostile_arrested', points = 5, each = true },
    { id = 'cook_arrested', points = 10, each = true },
    { id = 'stash_found_fast', points = 10 },       -- every stash found within 3 minutes of the breach
  },
  penalties = {
    { id = 'lab_fire', points = -15 },              -- personal: the officer whose checks missed
  },
})
