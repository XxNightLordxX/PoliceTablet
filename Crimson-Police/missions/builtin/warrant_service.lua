--[[ Crimson-Police · built-in mission: Warrant Service (warrant_service)
  Investigation · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  Officers serve an arrest warrant at a house: knock and announce at the front door, deal with the
  suspect's rolled response (surrenders 50% / flees out the back 30% / fights with a pistol 20%) and the
  armed associates, cuff the suspect, then search the property at the yard marker.
  Locations (6 houses): Grove Street (Davis), Forum Drive (Strawberry), Mirror Park, Wild Oats Drive
  (Vinewood Hills), Sandy Shores and Paleto Bay. Each has a front door, the suspect's spot just inside,
  fleeTo points out the back, four associate spawns (the count scales) and a yard marker.
  Blocks: flee_arrest (door mode) → interact_points.
]]

RegisterMission({
  id           = 'warrant_service',
  label        = 'Warrant Service',
  description  = "A judge has signed an arrest warrant. Knock and announce at the suspect's house, take the suspect into custody, deal with any armed associates and search the property.",
  type         = 'investigation', -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 2,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 720,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = false,       -- vehicles take gunfire here, so no heavy-damage penalty

  locations = {
    {
      label      = 'Grove Street, Davis',
      start      = { coords = vec3(95.47, -1933.18, 20.80), radius = 50.0 },   -- the street in front of the house
      door       = vec4(114.33, -1961.14, 21.33, 34.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(115.00, -1962.13, 21.33, 34.0),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(128.29, -1978.26, 21.00), vec3(133.38, -1996.54, 20.90),
        vec3(140.71, -2018.13, 20.80), vec3(156.89, -2034.96, 20.80),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(123.90, -1961.92, 21.23, 34.0), vec4(111.47, -1970.31, 21.23, 34.0),
        vec4(118.57, -1976.37, 21.23, 34.0), vec4(128.50, -1966.06, 21.23, 34.0),
      },
      yard       = vec3(124.65, -1971.07, 21.10),   -- "Search the property"
    },
    {
      label      = 'Forum Drive, Strawberry',
      start      = { coords = vec3(-40.29, -1459.24, 30.30), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-14.29, -1441.24, 31.10, 180.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-14.29, -1440.04, 31.10, 180.0),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(-16.29, -1419.24, 30.80), vec3(-10.29, -1401.24, 30.60),
        vec3(-4.29, -1379.24, 30.40), vec3(-8.29, -1356.24, 30.20),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(-21.79, -1435.24, 31.00, 180.0), vec4(-6.79, -1435.24, 31.00, 180.0),
        vec4(-9.29, -1426.24, 31.00, 180.0), vec4(-23.29, -1429.24, 31.00, 180.0),
      },
      yard       = vec3(-17.29, -1427.24, 30.90),   -- "Search the property"
    },
    {
      label      = 'Mirror Park',
      start      = { coords = vec3(1223.42, -540.34, 69.20), radius = 50.0 },   -- the street in front of the house
      door       = vec4(1241.42, -566.34, 69.65, 90.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(1242.62, -566.34, 69.65, 90.0),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(1263.42, -564.34, 70.00), vec3(1281.42, -570.34, 70.50),
        vec3(1303.42, -576.34, 71.20), vec3(1326.42, -572.34, 72.00),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(1247.42, -558.84, 69.55, 90.0), vec4(1247.42, -573.84, 69.55, 90.0),
        vec4(1256.42, -571.34, 69.55, 90.0), vec4(1253.42, -557.34, 69.55, 90.0),
      },
      yard       = vec3(1255.42, -563.34, 69.80),   -- "Search the property"
    },
    {
      label      = 'Wild Oats Drive, Vinewood Hills',
      start      = { coords = vec3(-140.35, 524.73, 137.20), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-174.35, 502.73, 137.42, 0.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-174.35, 501.53, 137.42, 0.0),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(-190.35, 496.73, 137.30), vec3(-204.35, 506.73, 137.60),
        vec3(-226.35, 510.73, 138.00), vec3(-252.35, 512.73, 138.50),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(-166.35, 504.23, 137.32, 0.0), vec4(-182.35, 504.23, 137.32, 0.0),
        vec4(-164.35, 498.73, 137.32, 0.0), vec4(-184.35, 498.73, 137.32, 0.0),
      },
      yard       = vec3(-183.35, 504.73, 137.40),   -- "Search the property"
    },
    {
      label      = 'Sandy Shores',
      start      = { coords = vec3(1960.84, 3786.37, 32.90), radius = 50.0 },   -- the street in front of the house
      door       = vec4(1973.60, 3815.30, 33.43, 211.5),   -- "Knock and announce"; heading faces out
      suspect    = vec4(1972.97, 3816.32, 33.43, 211.5),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(1960.59, 3830.79, 33.20), vec3(1960.95, 3847.42, 33.00),
        vec3(1964.91, 3863.93, 32.80), vec3(1968.87, 3880.43, 32.60),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(1964.07, 3816.50, 33.33, 211.5), vec4(1976.86, 3824.33, 33.33, 211.5),
        vec4(1970.03, 3830.70, 33.33, 211.5), vec4(1959.66, 3820.83, 33.33, 211.5),
      },
      yard       = vec3(1963.73, 3825.67, 33.30),   -- "Search the property"
    },
    {
      label      = 'Paleto Bay',
      start      = { coords = vec3(-373.45, 6222.69, 31.30), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-374.34, 6191.08, 31.73, 53.7),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-373.37, 6190.37, 31.73, 53.7),   -- inside, behind the front door
      fleeTo     = {   -- out the back, in order
        vec3(-355.43, 6179.67, 31.60), vec3(-344.47, 6164.18, 31.50),
        vec3(-330.29, 6146.32, 31.50), vec3(-309.39, 6135.92, 31.40),
      },
      associates = {   -- armed associates (base 1, scales)
        vec4(-365.06, 6193.57, 31.63, 53.7), vec4(-373.94, 6181.48, 31.63, 53.7),
        vec4(-365.21, 6178.17, 31.63, 53.7), vec4(-359.34, 6191.23, 31.63, 53.7),
      },
      yard       = vec3(-361.28, 6185.21, 31.60),   -- "Search the property"
    },
  },

  objectives = {
    {
      block      = 'flee_arrest',
      label      = 'Serve the arrest warrant',
      minSeconds = 30,
      mode       = 'door',
      door       = 'door',
      knock      = { label = 'Knock and announce', duration = 3000 },
      suspect    = 'suspect',
      fleeTo     = 'fleeTo',
      responses  = { surrender = 0.5, flee = 0.3, fight = 0.2 },   -- rolled once per run
      associates = { count = 1, spawns = 'associates', weapons = { 'WEAPON_PISTOL' }, accuracy = 25, armour = 0 },
      weapons    = { 'WEAPON_PISTOL' },                             -- the suspect's pistol when fighting
      escape     = { distance = 400, seconds = 20 },                -- escapes: 400 m from everyone for 20 s
      cuff       = { label = 'Cuff suspect', duration = 5000 },
      aliveBonus = { id = 'suspect_alive', points = 15 },
    },
    {
      block      = 'interact_points',
      label      = 'Search the property',
      minSeconds = 8,
      points     = 'yard',
      target     = { label = 'Search the property' },
      progress   = { label = 'Searching the property', duration = 8000, anim = 'search' },
    },
  },

  scaling   = { 'objectives.1.associates.count' },   -- armed associates (base 1)
  items     = {},                                   -- no items for this mission
  bonuses   = {
    { id = 'suspect_alive', points = 15 },          -- suspect taken alive
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
  },
  penalties = {},                                   -- the common penalties always apply
})
