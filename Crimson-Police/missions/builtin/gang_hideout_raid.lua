--[[ Crimson-Police · built-in mission: Gang Hideout Raid (gang_hideout_raid)
  Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  Breach an urban gang hideout together, fight 16 hostiles in waves of 6 / 5 / 5 (scaled) from two of the
  three spawn sets rolled per run (the intel line names them; tactics hold 30 / balanced 50 / push 20), then
  the lieutenant, catch the runners, find and seize the weapons cache and process the scene.
  Locations (7 hideouts): Yard, Murrieta Heights, Duplex, Elysian Island, House, Vespucci Canals, House, Richman Glen, House, East Vinewood, Compound, Tataviam foothills, House, Pacific Bluffs.
  Every point sits on the GTA V vehicle-node network or 3 m beside it, at the hideout's ground level: the
  "house" set within 24 m of the building node, "front" on the approach side and "garage" behind it (6+
  points each), the lieutenant and the runners at the back, cache spots 4–48 m around, escape routes along
  the lanes away from the approach. The start is on the approach road 50–95 m from the house and at least
  33 m from every spawn; every point is at least 200 m from any other mission's locations (250 m from Drug
  Lab Raid's; tests/zone_lint_spec.lua).
  Blocks: interact_points (together) → hostile_waves (boss) → flee_arrest (scatter) → interact_points
  (seize) → process_scene.
]]

RegisterMission({
  id           = 'gang_hideout_raid',
  label        = 'Gang Hideout Raid',
  description  = 'A gang is holed up in a house with a lieutenant and a weapons cache. Breach together, neutralise the gang, take the lieutenant, catch the runners and seize the weapons.',
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
      label      = 'Yard, Murrieta Heights',
      start      = { coords = vec3(1546.75, -1768.50, 78.53), radius = 50.0 },   -- on the approach road, 65 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(1524.03, -1717.63, 79.41, 20.7), vec4(1520.15, -1726.28, 78.81, 357.4),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(1523.69, -1710.50, 79.78, 201.7), vec4(1522.30, -1705.57, 80.14, 201.2),
        vec4(1519.28, -1713.37, 79.53, 206.5), vec4(1528.00, -1707.43, 80.14, 197.1),
        vec4(1523.60, -1701.57, 80.60, 199.1), vec4(1517.55, -1717.29, 79.25, 209.7),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(1532.01, -1710.07, 79.94, 194.2), vec4(1519.25, -1720.67, 79.09, 209.9),
        vec4(1532.26, -1705.94, 80.34, 193.0), vec4(1532.94, -1715.10, 79.64, 194.5),
        vec4(1514.52, -1724.22, 78.81, 216.1), vec4(1533.81, -1719.35, 79.34, 194.7),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(1529.30, -1703.43, 80.60, 195.0), vec4(1524.89, -1697.60, 81.06, 197.1),
        vec4(1530.60, -1699.43, 81.06, 193.2), vec4(1526.39, -1692.85, 81.84, 195.1),
        vec4(1531.81, -1695.31, 81.84, 191.5), vec4(1535.92, -1699.58, 81.03, 188.9),
      },
      lieutenant = vec4(1529.25, -1693.75, 81.84, 342.5),   -- the lieutenant's spot
      runners    = { vec4(1529.25, -1693.75, 81.84, 342.5) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(1540.02, -1655.88, 88.12), vec3(1558.36, -1623.61, 88.27), vec3(1563.25, -1619.50, 88.38) },
        { vec3(1540.02, -1655.88, 88.12), vec3(1558.36, -1623.61, 88.27), vec3(1606.50, -1665.25, 88.00) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(1522.06, -1714.50, 79.53, 157.9), vec4(1526.47, -1711.63, 79.78, 157.9),
        vec4(1526.45, -1702.50, 80.60, 342.0), vec4(1521.95, -1721.96, 79.09, 154.4),
        vec4(1515.55, -1721.45, 78.94, 154.4), vec4(1532.51, -1701.82, 80.75, 176.5),
      },
      scene      = vec3(1525.15, -1706.50, 79.34),   -- scene marker: Process the scene
      coroner    = vec4(1547.25, -1751.00, 77.88, 32.3),   -- where the coroner van parks
    },
    {
      label      = 'Duplex, Elysian Island',
      start      = { coords = vec3(-160.25, -2500.25, 6.00), radius = 50.0 },   -- on the approach road, 62 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(-191.75, -2541.25, 6.00, 143.1), vec4(-193.13, -2532.29, 6.00, 164.8),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(-194.75, -2549.25, 6.00, 324.9), vec4(-198.83, -2546.25, 6.00, 320.0),
        vec4(-197.75, -2553.42, 6.00, 324.8), vec4(-194.75, -2545.25, 6.00, 322.5),
        vec4(-202.92, -2546.25, 6.00, 317.2), vec4(-191.75, -2553.42, 6.00, 329.4),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(-202.92, -2540.25, 6.00, 313.2), vec4(-194.75, -2539.25, 6.00, 318.5),
        vec4(-197.63, -2536.43, 6.00, 314.1), vec4(-207.00, -2540.25, 6.00, 310.6),
        vec4(-191.88, -2536.37, 6.00, 318.8), vec4(-196.47, -2532.34, 6.00, 311.5),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(-194.24, -2558.79, 6.00, 329.9), vec4(-209.08, -2546.25, 6.00, 313.3),
        vec4(-197.75, -2561.75, 6.00, 328.6), vec4(-189.87, -2559.54, 5.99, 333.5),
        vec4(-191.75, -2563.75, 6.00, 333.6), vec4(-213.25, -2546.25, 6.00, 311.0),
      },
      lieutenant = vec4(-197.75, -2557.58, 6.00, 180.0),   -- the lieutenant's spot
      runners    = { vec4(-197.75, -2557.58, 6.00, 180.0) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(-194.75, -2601.75, 6.00), vec3(-213.75, -2622.75, 6.09), vec3(-256.00, -2622.75, 6.03) },
        { vec3(-194.75, -2601.75, 6.00), vec3(-175.75, -2622.75, 6.04), vec3(-145.00, -2622.75, 6.00) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(-191.75, -2549.25, 6.00, 180.0), vec4(-197.75, -2543.25, 6.00, 0.0),
        vec4(-202.92, -2543.25, 6.00, 90.0), vec4(-191.75, -2557.58, 6.00, 180.0),
        vec4(-209.08, -2543.25, 6.00, 90.0), vec4(-194.75, -2561.75, 6.00, 180.0),
      },
      scene      = vec3(-194.75, -2553.42, 5.20),   -- scene marker: Process the scene
      coroner    = vec4(-190.75, -2506.25, 5.53, 170.8),   -- where the coroner van parks
    },
    {
      label      = 'House, Vespucci Canals',
      start      = { coords = vec3(-1345.25, -1546.75, 4.41), radius = 50.0 },   -- on the approach road, 63 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(-1379.25, -1516.79, 3.84, 48.8), vec4(-1386.12, -1510.25, 3.69, 51.5),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(-1390.00, -1503.58, 3.44, 226.0), vec4(-1390.13, -1509.20, 3.62, 230.1),
        vec4(-1395.37, -1501.09, 3.23, 227.7), vec4(-1388.88, -1499.66, 3.34, 222.8),
        vec4(-1384.93, -1506.21, 3.62, 224.4), vec4(-1394.75, -1497.00, 3.12, 224.9),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(-1387.41, -1514.14, 3.75, 232.3), vec4(-1382.12, -1511.30, 3.75, 226.1),
        vec4(-1383.38, -1515.38, 3.80, 230.5), vec4(-1384.75, -1519.21, 3.84, 235.1),
        vec4(-1382.91, -1523.37, 3.80, 238.2), vec4(-1371.87, -1505.58, 4.41, 212.9),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(-1398.58, -1496.66, 3.10, 226.8), vec4(-1393.59, -1493.34, 3.10, 222.1),
        vec4(-1401.25, -1492.66, 3.06, 226.0), vec4(-1396.00, -1489.80, 3.06, 221.7),
        vec4(-1400.42, -1487.17, 3.04, 222.8), vec4(-1402.25, -1483.25, 3.02, 221.9),
      },
      lieutenant = vec4(-1397.12, -1498.84, 3.12, 37.9),   -- the lieutenant's spot
      runners    = { vec4(-1397.12, -1498.84, 3.12, 37.9) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(-1413.98, -1462.27, 3.00), vec3(-1432.82, -1427.28, 3.00), vec3(-1472.75, -1401.25, 2.12) },
        { vec3(-1384.93, -1476.50, 4.26), vec3(-1376.32, -1456.37, 4.32), vec3(-1371.75, -1360.00, 3.75) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(-1393.00, -1499.25, 3.23, 37.9), vec4(-1387.43, -1502.04, 3.44, 211.0),
        vec4(-1388.75, -1511.70, 3.69, 208.8), vec4(-1383.50, -1508.80, 3.69, 208.8),
        vec4(-1397.42, -1493.00, 3.08, 33.7), vec4(-1386.03, -1516.77, 3.80, 207.6),
      },
      scene      = vec3(-1387.50, -1507.75, 2.83),   -- scene marker: Process the scene
      coroner    = vec4(-1360.00, -1526.75, 3.91, 56.4),   -- where the coroner van parks
    },
    {
      label      = 'House, Richman Glen',
      start      = { coords = vec3(-859.75, 706.50, 149.06), radius = 50.0 },   -- on the approach road, 65 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(-907.50, 704.00, 151.16, 94.6), vec4(-918.56, 703.17, 151.73, 95.2),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(-924.50, 699.62, 152.11, 276.1), vec4(-928.83, 702.50, 152.34, 273.3),
        vec4(-920.00, 699.75, 151.88, 276.4), vec4(-928.92, 696.50, 152.34, 278.2),
        vec4(-933.20, 702.75, 152.58, 272.9), vec4(-915.75, 700.75, 151.59, 275.9),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(-915.06, 697.83, 151.59, 278.9), vec4(-912.72, 705.17, 151.38, 271.4),
        vec4(-910.53, 699.58, 151.38, 277.8), vec4(-908.60, 706.79, 151.16, 269.7),
        vec4(-906.55, 701.15, 151.16, 276.5), vec4(-904.32, 708.22, 150.94, 267.8),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(-933.55, 696.75, 152.58, 277.5), vec4(-937.58, 703.00, 152.81, 272.6),
        vec4(-937.92, 697.00, 152.81, 276.9), vec4(-941.95, 703.25, 153.11, 272.3),
        vec4(-942.30, 697.25, 153.11, 276.4), vec4(-946.33, 703.50, 153.41, 272.0),
      },
      lieutenant = vec4(-953.12, 700.50, 153.95, 90.0),   -- the lieutenant's spot
      runners    = { vec4(-953.12, 700.50, 153.95, 90.0) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(-994.92, 697.20, 158.90), vec3(-1029.12, 716.21, 164.68), vec3(-1035.25, 726.00, 165.94) },
        { vec3(-994.92, 697.20, 158.90), vec3(-1029.12, 716.21, 164.68), vec3(-1002.25, 798.75, 171.72) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(-924.42, 696.63, 152.11, 91.6), vec4(-919.31, 696.83, 151.88, 283.2),
        vec4(-933.38, 699.75, 152.58, 86.7), vec4(-911.62, 702.38, 151.38, 291.5),
        vec4(-939.94, 700.12, 152.96, 86.7), vec4(-903.38, 705.38, 150.94, 288.4),
      },
      scene      = vec3(-929.00, 699.50, 151.54),   -- scene marker: Process the scene
      coroner    = vec4(-881.75, 708.00, 149.44, 97.2),   -- where the coroner van parks
    },
    {
      label      = 'House, East Vinewood',
      start      = { coords = vec3(1049.00, 253.75, 84.31), radius = 50.0 },   -- on the approach road, 63 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(1105.34, 245.34, 80.84, 237.5), vec4(1099.50, 252.75, 80.84, 226.3),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(1108.84, 243.00, 80.84, 79.8), vec4(1114.75, 243.00, 80.84, 80.7),
        vec4(1112.16, 248.00, 80.84, 84.8), vec4(1107.00, 247.83, 80.84, 84.2),
        vec4(1117.25, 246.25, 80.84, 83.7), vec4(1116.18, 250.29, 80.84, 87.1),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(1106.91, 251.50, 80.84, 87.8), vec4(1101.69, 247.74, 80.84, 83.5),
        vec4(1103.06, 254.01, 80.84, 90.3), vec4(1097.93, 250.20, 80.84, 85.8),
        vec4(1098.91, 256.64, 80.84, 93.3), vec4(1093.59, 252.86, 80.84, 88.9),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(1118.75, 248.75, 80.84, 85.9), vec4(1117.68, 252.79, 80.84, 89.2),
        vec4(1122.79, 249.65, 80.84, 86.8), vec4(1121.75, 253.62, 80.84, 89.9),
        vec4(1119.88, 257.63, 80.84, 93.1), vec4(1125.79, 254.40, 80.84, 90.5),
      },
      lieutenant = vec4(1140.10, 235.66, 81.81, 327.8),   -- the lieutenant's spot
      runners    = { vec4(1140.10, 235.66, 81.81, 327.8) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(1158.55, 259.36, 81.81), vec3(1188.75, 284.55, 81.81), vec3(1275.25, 208.75, 81.81) },
        { vec3(1158.55, 259.36, 81.81), vec3(1188.75, 284.55, 81.81), vec3(1219.50, 289.00, 81.81) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(1117.13, 241.17, 80.84, 322.4), vec4(1114.68, 247.79, 80.84, 329.0),
        vec4(1103.33, 250.25, 80.84, 56.9), vec4(1121.32, 247.21, 80.84, 329.0),
        vec4(1124.29, 252.02, 80.84, 327.7), vec4(1095.76, 251.53, 80.84, 58.4),
      },
      scene      = vec3(1112.37, 244.83, 80.04),   -- scene marker: Process the scene
      coroner    = vec4(1061.25, 243.75, 80.34, 267.6),   -- where the coroner van parks
    },
    {
      label      = 'Compound, Tataviam foothills',
      start      = { coords = vec3(1894.25, -1050.25, 79.31), radius = 50.0 },   -- on the approach road, 61 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(1876.56, -1002.27, 79.16, 317.2), vec4(1882.93, -995.31, 79.16, 316.7),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(1886.25, -987.42, 79.16, 187.3), vec4(1891.08, -986.66, 79.16, 182.9),
        vec4(1885.68, -992.39, 79.16, 188.4), vec4(1886.82, -982.44, 79.16, 186.3),
        vec4(1881.32, -988.28, 79.16, 191.8), vec4(1893.97, -983.88, 79.16, 180.2),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(1879.15, -995.00, 79.16, 195.3), vec4(1875.95, -998.50, 79.16, 199.5),
        vec4(1872.75, -1002.00, 79.16, 204.0), vec4(1872.60, -1007.03, 79.16, 206.6),
        vec4(1867.90, -1003.31, 79.16, 209.3), vec4(1870.10, -1010.19, 79.16, 211.1),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(1889.81, -979.56, 79.16, 183.6), vec4(1896.86, -981.11, 79.16, 177.8),
        vec4(1892.70, -976.78, 79.16, 181.2), vec4(1899.75, -978.33, 79.16, 175.6),
        vec4(1895.59, -974.00, 79.16, 179.0), vec4(1902.63, -975.55, 79.16, 173.6),
      },
      lieutenant = vec4(1889.00, -984.50, 79.16, 313.9),   -- the lieutenant's spot
      runners    = { vec4(1889.00, -984.50, 79.16, 313.9) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(1918.61, -957.63, 79.16), vec3(1950.16, -933.06, 79.16), vec3(1958.25, -927.25, 79.16) },
        { vec3(1918.61, -957.63, 79.16), vec3(1950.16, -933.06, 79.16), vec3(1993.50, -1002.75, 85.22) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(1884.07, -985.36, 79.16, 136.7), vec4(1891.89, -981.72, 79.16, 313.9),
        vec4(1878.57, -991.19, 79.16, 136.7), vec4(1879.76, -998.77, 79.16, 137.6),
        vec4(1896.22, -977.56, 79.16, 313.9), vec4(1873.74, -996.48, 79.16, 137.6),
      },
      scene      = vec3(1883.50, -990.33, 78.36),   -- scene marker: Process the scene
      coroner    = vec4(1899.00, -1037.25, 78.12, 12.5),   -- where the coroner van parks
    },
    {
      label      = 'House, Pacific Bluffs',
      start      = { coords = vec3(-1614.00, 151.00, 60.44), radius = 50.0 },   -- on the approach road, 61 m from the house
      entries    = {   -- the two entry points: "Stack up and breach"
        vec4(-1619.69, 94.20, 62.01, 232.8), vec4(-1628.75, 95.62, 62.30, 248.1),
      },
      house      = {   -- spawn set "house" (6 points)
        vec4(-1615.50, 87.25, 61.81, 358.7), vec4(-1617.29, 92.77, 61.94, 356.8),
        vec4(-1610.82, 84.59, 61.69, 2.7), vec4(-1616.49, 83.05, 61.69, 357.9),
        vec4(-1620.73, 87.89, 61.94, 353.9), vec4(-1613.25, 79.50, 61.56, 0.6),
      },
      front      = {   -- spawn set "front" (6 points)
        vec4(-1623.08, 92.67, 62.08, 351.1), vec4(-1625.53, 97.37, 62.23, 347.9),
        vec4(-1628.22, 92.00, 62.23, 346.5), vec4(-1629.28, 99.25, 62.37, 343.5),
        vec4(-1631.97, 93.88, 62.37, 342.5), vec4(-1632.80, 101.51, 62.50, 339.2),
      },
      garage     = {   -- spawn set "garage" (6 points)
        vec4(-1610.26, 79.70, 61.56, 3.0), vec4(-1616.24, 79.30, 61.56, 358.2),
        vec4(-1611.77, 75.51, 61.66, 1.7), vec4(-1619.27, 74.87, 61.31, 356.0),
        vec4(-1614.20, 71.67, 61.31, 359.9), vec4(-1623.37, 73.77, 61.78, 353.1),
      },
      lieutenant = vec4(-1613.36, 67.66, 61.28, 242.4),   -- the lieutenant's spot
      runners    = { vec4(-1613.36, 67.66, 61.28, 242.4) },   -- where the runners hide until they bolt
      escapes    = {   -- escape routes away from the start
        { vec3(-1644.85, 72.14, 63.19), vec3(-1662.61, 36.66, 62.95), vec3(-1683.75, 15.75, 64.62) },
        { vec3(-1577.58, 50.56, 59.32), vec3(-1538.16, 44.75, 56.84), vec3(-1534.50, 44.75, 56.59) },
      },
      caches     = {   -- cache spots (the hidden ones are rolled)
        vec4(-1618.18, 85.91, 61.81, 206.6), vec4(-1613.50, 83.25, 61.69, 206.6),
        vec4(-1624.56, 90.05, 62.08, 60.5), vec4(-1614.50, 76.75, 61.66, 155.6),
        vec4(-1617.83, 71.50, 61.38, 148.2), vec4(-1627.37, 76.37, 62.03, 57.0),
      },
      scene      = vec3(-1619.25, 90.50, 61.14),   -- scene marker: Process the scene
      coroner    = vec4(-1655.25, 90.75, 63.09, 268.3),   -- where the coroner van parks
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
      label        = 'Neutralise the gang',
      minSeconds   = 60,
      spawns       = 'house',
      spawnSets    = { keys = { 'front', 'house', 'garage' }, use = 2, intel = true },
      waves        = { 6, 5, 5 },                                       -- base counts, scaled by tier
      nextWave     = { aliveAtMost = 2, afterSeconds = 90 },
      weapons      = { 'WEAPON_PISTOL', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN' },
      accuracy     = 28,                                                -- plus the tier's accuracy
      armour       = 10,                                                -- plus the tier's armour
      behaviour    = { hold = 0.3, balanced = 0.5, push = 0.2 },        -- rolled once per run
      surrender    = { belowHealth = 0.25, chance = 0.30 },
      peds         = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01' },
      boss         = {
        spawn      = 'lieutenant',
        model      = 'g_m_m_chicold_01',
        label      = 'the lieutenant',
        health     = 300,
        armour     = 50,
        weapon     = 'WEAPON_ASSAULTRIFLE',
        surrender  = { belowHealth = 0.25, chance = 0.50 },
        aliveBonus = { id = 'lieutenant_alive', points = 25 },
      },
      blockTraffic = 120.0,
    },
    {
      block      = 'flee_arrest',
      label      = 'Catch the runners',
      minSeconds = 10,
      mode       = 'scatter',
      spawns     = 'runners',
      routes     = 'escapes',
      suspects   = 2,                                                   -- base 2, scaled (max 4)
      armedShare = 0,                                                   -- the runners are unarmed
      models     = { 'a_m_y_stbla_01', 'a_m_y_mexthug_01' },
      demeanour  = 'runner',
      escape     = { distance = 400, seconds = 20 },
      givesUp    = { 'aim', 'stun', 'close' },
      cuff       = { label = 'Cuff suspect', duration = 5000 },
      aliveBonus = { id = 'suspect_alive', points = 0 },               -- the card pays nothing per runner
    },
    {
      block      = 'interact_points',
      label      = 'Find and seize the weapons cache',
      minSeconds = 10,
      points     = 'caches',
      target     = { label = 'Search' },
      progress   = { label = 'Searching', duration = 4000, anim = 'search' },
      hidden     = {                                                    -- base 1, scaled (max 2)
        kind   = 'seize',
        count  = 1,
        label  = 'Weapons cache',
        action = { label = 'Seize the weapons', duration = 6000 },     -- at each cache once it is found
      },
      fastBonus  = { id = 'stash_found_fast', seconds = 120, after = 1 },   -- timed from the breach
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
    { path = 'objectives.3.suspects', max = 4 },
    { path = 'objectives.4.hidden.count', max = 2 },
  },
  items     = {},                                   -- nothing is looted
  bonuses   = {
    { id = 'lieutenant_alive', points = 25 },
    { id = 'hostile_arrested', points = 5, each = true },
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
    { id = 'stash_found_fast', points = 10 },       -- every cache found within 2 minutes of the breach
  },
  penalties = {},                                   -- the common penalties apply
})
