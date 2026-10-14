--[[ Crimson-Police · built-in mission: Suspicious Activity (suspicious_activity)
  Investigation · 1–2 officers · ★★ · time limit 10 min · cooldown 15 min
  A caller reports people hanging around a parked car. The server rolls the scene (someone sitting in the
  car 50%, people loitering beside it 30%, someone looking into parked cars 20%), each person's hidden truth
  (Config.Custody.profileSets.scene) and whether the car is stolen (15%). When the first officer is within
  25 m each person reacts by demeanour: stays, walks away, runs, or shows a tell and draws. Talk / Check ID,
  frisk, detain, look inside, run the plate and search the car (with probable cause), then decide.
  Locations (7 scenes): Container yard, Elysian Island, Lookout, Vinewood Hills, Car park, Rockford Hills, Truck stop, Grand Senora, Farm lot, Grapeseed, Lumber yard, Paleto Forest, Terminal car park, LSIA.
  Each scene is a car park or yard lane from the GTA V vehicle nodes (a back-road or non-GPS node): the car
  sits on the lane, three person spots are 3–5 m around it, two escape paths follow the lanes away from
  the start, and the transport point is on the nearest main road. The start marker is 44–58 m from the car
  on that road and at least 30 m from every person and car spot; every point is at least 200 m from any
  other mission's locations (tests/zone_lint_spec.lua).
  Blocks: field_contact (mode = 'scene').
]]

RegisterMission({
  id           = 'suspicious_activity',
  label        = 'Suspicious Activity',
  description  = 'A caller reports people hanging around a parked car. Make contact, find out what is going on and decide what to do with every person and the car.',
  type         = 'investigation', -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 2,
  difficulty   = 2,
  timeLimit    = 600,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 900,             -- per officer, seconds
  vehiclePenalties = true,       -- the heavy vehicle-damage penalty applies

  locations = {
    {
      label     = 'Container yard, Elysian Island',
      start     = { coords = vec3(666.00, -2763.50, 6.16), radius = 40.0 },   -- 57 m from the car
      car       = vec4(611.00, -2779.00, 5.53, 346.8),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(613.73, -2779.64, 6.03, 76.8), vec4(611.79, -2783.50, 6.03, 16.8),
        vec4(609.10, -2774.85, 6.03, 226.8),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(581.57, -2777.59, 6.03), vec3(551.27, -2760.06, 6.03), vec3(534.50, -2750.25, 6.03) },
        { vec3(614.44, -2744.63, 6.04), vec3(605.78, -2718.63, 6.03), vec3(600.25, -2690.00, 6.06) },
      },
      transport = vec4(669.75, -2778.25, 5.66, 180.0),   -- where the prisoner van parks, on the road 59 m away
    },
    {
      label     = 'Lookout, Vinewood Hills',
      start     = { coords = vec3(-14.50, 974.75, 214.34), radius = 40.0 },   -- 49 m from the car
      car       = vec4(21.75, 942.00, 197.88, 208.1),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(19.28, 940.68, 198.38, 298.1), vec4(18.19, 944.86, 198.38, 238.1),
        vec4(25.91, 940.14, 198.38, 88.1),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(39.23, 965.71, 199.24), vec3(68.21, 948.04, 198.55), vec3(124.00, 894.75, 198.34) },
        { vec3(34.11, 909.52, 197.69), vec3(23.25, 870.50, 197.56) },
      },
      transport = vec4(17.25, 902.50, 203.34, 173.7),   -- where the prisoner van parks, on the road 40 m away
    },
    {
      label     = 'Car park, Rockford Hills',
      start     = { coords = vec3(-1082.25, 245.75, 63.78), radius = 40.0 },   -- 49 m from the car
      car       = vec4(-1100.12, 200.12, 63.05, 23.2),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(-1097.55, 201.23, 63.55, 113.2), vec4(-1096.82, 196.97, 63.55, 53.2),
        vec4(-1104.12, 202.33, 63.55, 263.2),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(-1118.68, 173.14, 63.23), vec3(-1138.89, 145.30, 62.71), vec3(-1138.25, 105.00, 58.34) },
        { vec3(-1088.18, 170.49, 61.59), vec3(-1070.25, 136.25, 58.28) },
      },
      transport = vec4(-1070.00, 177.75, 59.28, 207.3),   -- where the prisoner van parks, on the road 38 m away
    },
    {
      label     = 'Truck stop, Grand Senora',
      start     = { coords = vec3(2068.50, 2113.50, 90.25), radius = 40.0 },   -- 52 m from the car
      car       = vec4(2044.25, 2159.42, 95.15, 169.0),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(2041.50, 2159.95, 95.65, 259.0), vec4(2043.28, 2163.88, 95.65, 199.0),
        vec4(2046.31, 2155.35, 95.65, 49.0),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(2044.59, 2196.60, 99.37), vec3(2021.95, 2221.50, 102.41), vec3(2007.00, 2218.75, 103.44) },
        { vec3(2040.66, 2130.54, 93.36), vec3(2012.79, 2111.05, 93.49), vec3(1983.50, 2116.00, 91.75) },
      },
      transport = vec4(2043.50, 2200.25, 99.22, 196.7),   -- where the prisoner van parks, on the road 41 m away
    },
    {
      label     = 'Farm lot, Grapeseed',
      start     = { coords = vec3(1401.50, 4494.00, 52.16), radius = 40.0 },   -- 49 m from the car
      car       = vec4(1437.25, 4461.00, 49.38, 338.2),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(1439.85, 4459.96, 49.88, 68.2), vec4(1437.36, 4456.43, 49.88, 8.2),
        vec4(1435.99, 4465.38, 49.88, 218.2),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(1425.57, 4428.06, 48.09), vec3(1412.75, 4392.00, 43.25) },
        { vec3(1453.12, 4492.10, 50.58), vec3(1478.84, 4510.99, 52.45), vec3(1508.00, 4531.25, 53.53) },
      },
      transport = vec4(1456.00, 4496.75, 50.06, 148.2),   -- where the prisoner van parks, on the road 40 m away
    },
    {
      label     = 'Lumber yard, Paleto Forest',
      start     = { coords = vec3(-263.75, 4739.75, 137.44), radius = 40.0 },   -- 51 m from the car
      car       = vec4(-298.00, 4702.50, 236.28, 212.7),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(-300.36, 4700.99, 236.78, 302.7), vec4(-301.79, 4705.06, 236.78, 242.7),
        vec4(-293.70, 4700.99, 236.78, 92.7),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(-291.66, 4671.81, 243.34), vec3(-319.72, 4689.70, 249.86), vec3(-366.50, 4682.75, 254.78) },
        { vec3(-316.23, 4732.30, 231.81), vec3(-336.11, 4761.05, 227.11), vec3(-352.25, 4784.50, 222.59) },
      },
      transport = vec4(-319.00, 4736.25, 230.72, 215.0),   -- where the prisoner van parks, on the road 40 m away
    },
    {
      label     = 'Terminal car park, LSIA',
      start     = { coords = vec3(-1011.00, -2591.25, 33.97), radius = 40.0 },   -- 50 m from the car
      car       = vec4(-961.25, -2596.50, 13.34, 103.0),   -- the parked car at the scene
      people    = {   -- person spots around the car
        vec4(-961.88, -2593.77, 13.84, 193.0), vec4(-957.56, -2593.80, 13.84, 133.0),
        vec4(-964.13, -2600.04, 13.84, 343.0),
      },
      fleeTo    = {   -- escape paths along the lanes, away from the start
        { vec3(-935.27, -2583.79, 13.84), vec3(-905.21, -2576.94, 13.81), vec3(-886.00, -2593.00, 13.84) },
        { vec3(-963.80, -2576.34, 13.81), vec3(-966.09, -2547.71, 13.81), vec3(-963.50, -2488.00, 13.81) },
      },
      transport = vec4(-941.50, -2631.25, 28.72, 149.0),   -- where the prisoner van parks, on the road 40 m away
    },
  },

  objectives = {
    {
      block         = 'field_contact',
      label         = 'Check out the suspicious activity',
      minSeconds    = 30,                                 -- a talk, a check and a decision at least
      mode          = 'scene',
      people        = 1,                                  -- base 1, scaled by tier (max 3)
      cars          = 1,
      car           = 'car',
      peopleSpots   = 'people',
      fleeTo        = 'fleeTo',
      transport     = 'transport',
      profileSet    = 'scene',                            -- clean 35, minor 15, warrant 15, narcotics 15, tools 12, armed 8
      scene         = { occupied_car = 0.5, loitering = 0.3, casing = 0.2 },
      approach      = 25.0,                               -- people react when the first officer is this close
      probableCause = true,
      custody       = 'handover',                         -- arrests go to the transport van
      escapeFails   = true,                               -- 400 m from everyone for 20 s fails the case
      escape        = { distance = 400, seconds = 20 },
      bestPoints    = 10,                                 -- correct_disposition per Best decision
      aliveBonus    = { id = 'subject_alive', points = 15 },
    },
  },

  scaling   = { { path = 'objectives.1.people', max = 3 } },
  items     = {},
  bonuses   = {
    { id = 'procedure_complete', points = 10 },     -- every arrested person ID-checked and searched, per officer
    { id = 'subject_alive', points = 15 },          -- each person who ran or drew, arrested alive
    { id = 'no_weapons_fired', points = 10 },
  },
  penalties = {},                                   -- decision penalties and the common penalties apply
})
