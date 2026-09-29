--[[ Crimson-Police · built-in mission: Warrant Service (warrant_service)
  Investigation · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  Officers serve an arrest warrant at a house: knock and announce at the front door, deal with the
  suspect's rolled response (surrenders 50% / flees out the back 30% / fights with a pistol 20%) and the
  armed associates, cuff the suspect, then search the property at the yard marker.
  Locations (6 houses): Grove Street (Davis), Forum Drive (Strawberry), Mirror Park, Wild Oats Drive
  (Vinewood Hills), Sandy Shores and Paleto Bay. Each has a front door, the suspect's spot, fleeTo points
  out the back, four associate spawns (the count scales) and a yard marker. The suspect waits on the door
  step, 1.2 m beside the door: none of these houses can be relied on to have an interior a ped can walk
  out of (most have none, and story-mode doors are locked in multiplayer), so a ped placed behind the
  facade would be stuck in the walls. From beside the door, the block's surrender move (1 m past the
  door, away from where he waited) keeps him on the step, and a fleeing suspect runs round the house to
  fleeTo. Associates and the yard marker are in the front and side yard for the same reason. fleeTo points
  on or beside a street have that street's height (+1 m) from the GTA V vehicle nodes (Wild Oats Drive drops
  18 m over the flee path; Grove Street's back street is 3 m below the house).
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
      suspect    = vec4(113.17, -1961.56, 21.33, 34.0),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(128.29, -1978.26, 21.00), vec3(133.38, -1996.54, 18.28),
        vec3(140.71, -2018.13, 18.27), vec3(156.89, -2034.96, 18.28),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(107.41, -1963.40, 21.23, 34.0), vec4(102.97, -1963.97, 21.23, 34.0),
        vec4(101.61, -1967.31, 21.23, 34.0), vec4(97.71, -1965.11, 21.23, 34.0),
      },
      yard       = vec3(105.19, -1963.69, 21.10),   -- "Search the property": front yard, beside the path to the door
    },
    {
      label      = 'Forum Drive, Strawberry',
      start      = { coords = vec3(-40.29, -1459.24, 30.30), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-14.29, -1441.24, 31.10, 180.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-13.09, -1441.54, 31.10, 180.0),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(-16.29, -1419.24, 30.80), vec3(-10.29, -1401.24, 30.60),
        vec3(-4.29, -1379.24, 30.40), vec3(-8.29, -1356.24, 30.20),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(-7.29, -1443.24, 31.00, 180.0), vec4(-3.29, -1445.24, 31.00, 180.0),
        vec4(-0.29, -1443.24, 31.00, 180.0), vec4(1.71, -1447.24, 31.00, 180.0),
      },
      yard       = vec3(-5.29, -1444.24, 30.90),   -- "Search the property": front yard, beside the path to the door
    },
    {
      label      = 'Mirror Park',
      start      = { coords = vec3(1223.42, -540.34, 69.20), radius = 50.0 },   -- the street in front of the house
      door       = vec4(1241.42, -566.34, 69.65, 90.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(1241.12, -567.54, 69.65, 90.0),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(1263.42, -564.34, 70.00), vec3(1281.42, -570.34, 70.50),
        vec3(1303.42, -576.34, 71.20), vec3(1326.42, -572.34, 72.00),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(1239.42, -573.34, 69.55, 90.0), vec4(1237.42, -577.34, 69.55, 90.0),
        vec4(1239.42, -580.34, 69.55, 90.0), vec4(1235.42, -582.34, 69.55, 90.0),
      },
      yard       = vec3(1238.42, -575.34, 69.80),   -- "Search the property": front yard, beside the path to the door
    },
    {
      label      = 'Wild Oats Drive, Vinewood Hills',
      start      = { coords = vec3(-140.35, 524.73, 141.03), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-174.35, 502.73, 137.42, 0.0),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-175.55, 503.03, 137.42, 0.0),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(-191.35, 505.73, 134.29), vec3(-204.35, 506.73, 132.35),
        vec3(-226.35, 510.73, 128.77), vec3(-252.35, 512.73, 123.52),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(-181.35, 504.73, 137.32, 0.0), vec4(-185.35, 506.73, 137.32, 0.0),
        vec4(-188.35, 504.73, 137.32, 0.0), vec4(-190.35, 508.73, 137.32, 0.0),
      },
      yard       = vec3(-183.35, 505.73, 137.40),   -- "Search the property": front yard, beside the path to the door
    },
    {
      label      = 'Sandy Shores',
      start      = { coords = vec3(1960.84, 3786.37, 32.90), radius = 50.0 },   -- the street in front of the house
      door       = vec4(1973.60, 3815.30, 33.43, 211.5),   -- "Knock and announce"; heading faces out
      suspect    = vec4(1974.78, 3815.67, 33.43, 211.5),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(1960.59, 3830.79, 33.20), vec3(1960.95, 3847.42, 33.00),
        vec3(1964.91, 3863.93, 32.80), vec3(1968.87, 3880.43, 32.60),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(1980.61, 3817.25, 33.33, 211.5), vec4(1985.07, 3817.64, 33.33, 211.5),
        vec4(1986.58, 3820.91, 33.33, 211.5), vec4(1990.38, 3818.54, 33.33, 211.5),
      },
      yard       = vec3(1982.84, 3817.44, 33.30),   -- "Search the property": front yard, beside the path to the door
    },
    {
      label      = 'Paleto Bay',
      start      = { coords = vec3(-373.45, 6222.69, 31.30), radius = 50.0 },   -- the street in front of the house
      door       = vec4(-374.34, 6191.08, 31.73, 53.7),   -- "Knock and announce"; heading faces out
      suspect    = vec4(-375.29, 6190.29, 31.73, 53.7),   -- on the door step, beside the door (see the header)
      fleeTo     = {   -- out the back, in order
        vec3(-355.43, 6179.67, 31.60), vec3(-344.47, 6164.18, 31.50),
        vec3(-330.29, 6146.32, 31.50), vec3(-309.39, 6135.92, 31.40),
      },
      associates = {   -- armed associates (base 1, scales): front and side yard, away from the start
        vec4(-380.10, 6186.62, 31.63, 53.7), vec4(-384.08, 6184.58, 31.63, 53.7),
        vec4(-384.24, 6180.98, 31.63, 53.7), vec4(-388.65, 6181.74, 31.63, 53.7),
      },
      yard       = vec3(-382.09, 6185.60, 31.60),   -- "Search the property": front yard, beside the path to the door
    },
  },

  objectives = {
    {
      block      = 'flee_arrest',
      label      = 'Serve the arrest warrant',
      minSeconds = 8,                                               -- the 3 s knock + the 5 s cuff; quicker is rejected
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
