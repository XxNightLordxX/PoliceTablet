--[[ Crimson-Police · built-in mission: Bomb Disposal (bomb_disposal)
  Tactical · 1–4 officers · ★★ · time limit 6 min (the device timer) · cooldown 20 min
  A device (scales) is hidden at a random hiding spot of a store. Search the spots ("Search", 3 s) until
  every device is found, then defuse each one with 4 ox_lib skill checks (easy, medium, medium, hard).
  All devices share the one timer: a miss takes 30 s off it, 2 misses in a row on one device set it off
  (an explosion effect only, damage 0) and the mission fails.
  Locations (6 base-game 24/7 stores): Innocence Boulevard, Clinton Avenue, Palomino Freeway, Senora
  Freeway, Great Ocean Highway (Mount Chiliad) and Barbareno Road (Chumash). The seven hiding spots of a
  store are placed in the store's own frame (clerk position and heading, back-room safe): behind and in
  front of the counter, two in the back room, one on the shop floor and two outside by the entrance.
  Device prop: prop_c4_final_green (a base-game C4 charge model).
  Blocks: interact_points (hidden devices) → skill_check.
]]

RegisterMission({
  id           = 'bomb_disposal',
  label        = 'Bomb Disposal',
  description  = 'An explosive device has been planted at a store. Search the building, find every device and defuse it before the timer runs out.',
  type         = 'tactical',      -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 2,
  timeLimit    = 360,             -- the device timer: starts at the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = true,        -- no gunfire expected: the heavy-damage penalty applies

  locations = {
    {
      label  = '24/7 Supermarket, Innocence Boulevard',
      start  = { coords = vec3(30.57, -1384.46, 28.90), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(24.51, -1347.92, 28.60), vec3(26.34, -1345.67, 28.60),
        vec3(28.21, -1338.95, 28.60), vec3(26.71, -1338.99, 28.60),
        vec3(34.53, -1348.53, 28.60), vec3(27.64, -1352.53, 28.60),
        vec3(34.15, -1352.84, 28.60),
      },
    },
    {
      label  = '24/7 Supermarket, Clinton Avenue',
      start  = { coords = vec3(365.90, 288.60, 102.97), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(371.91, 325.15, 102.67), vec3(374.37, 326.69, 102.67),
        vec3(378.17, 333.44, 102.67), vec3(376.74, 333.88, 102.67),
        vec3(381.20, 321.35, 102.67), vec3(373.39, 319.77, 102.67),
        vec3(379.46, 317.38, 102.67),
      },
    },
    {
      label  = '24/7 Supermarket, Palomino Freeway',
      start  = { coords = vec3(2593.89, 383.62, 108.02), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(2556.96, 380.76, 107.72), vec3(2554.87, 382.79, 107.72),
        vec3(2549.19, 384.89, 107.72), vec3(2549.10, 383.39, 107.72),
        vec3(2558.44, 390.70, 107.72), vec3(2561.82, 383.49, 107.72),
        vec3(2562.70, 389.95, 107.72),
      },
    },
    {
      label  = '24/7 Supermarket, Senora Freeway',
      start  = { coords = vec3(2713.48, 3267.54, 54.64), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(2678.27, 3279.03, 54.34), vec3(2677.12, 3281.70, 54.34),
        vec3(2672.69, 3286.63, 54.34), vec3(2672.04, 3285.28, 54.34),
        vec3(2683.44, 3287.64, 54.34), vec3(2683.81, 3279.68, 54.34),
        vec3(2687.09, 3285.32, 54.34),
      },
    },
    {
      label  = '24/7 Supermarket, Great Ocean Highway (Mount Chiliad)',
      start  = { coords = vec3(1718.21, 6379.24, 34.44), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(1727.83, 6415.01, 34.14), vec3(1730.43, 6416.30, 34.14),
        vec3(1734.78, 6420.84, 34.14), vec3(1733.40, 6421.42, 34.14),
        vec3(1736.70, 6410.31, 34.14), vec3(1728.77, 6409.52, 34.14),
        vec3(1734.57, 6406.54, 34.14),
      },
    },
    {
      label  = '24/7 Supermarket, Barbareno Road (Chumash)',
      start  = { coords = vec3(-3204.96, 1001.14, 12.23), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(-3241.98, 999.85, 11.93), vec3(-3243.97, 1001.96, 11.93),
        vec3(-3250.02, 1004.43, 11.93), vec3(-3250.17, 1002.94, 11.93),
        vec3(-3240.08, 1009.71, 11.93), vec3(-3237.00, 1002.36, 11.93),
        vec3(-3235.85, 1008.78, 11.93),
      },
    },
  },

  objectives = {
    {
      block      = 'interact_points',
      label      = 'Find the device',
      minSeconds = 3,
      points     = 'hiding',
      target     = { label = 'Search' },
      progress   = { label = 'Searching', duration = 3000, anim = 'search' },
      hidden     = { count = 1, prop = 'prop_c4_final_green', label = 'Explosive device' },   -- devices (base 1)
      fastBonus  = { seconds = 120, id = 'devices_found_fast' },   -- every device found within 2 minutes
    },
    {
      block       = 'skill_check',
      label       = 'Defuse the device',
      minSeconds  = 5,
      targets     = 'shared:devices',                            -- the devices found by objective 1
      checks      = { 'easy', 'medium', 'medium', 'hard' },
      missPenalty = 30,                                          -- seconds off the shared timer
      failAfter   = 2,                                           -- misses in a row that set a device off
      target      = { label = 'Defuse device' },
      explosion   = true,                                        -- effect only, damage 0
    },
  },

  scaling   = { 'objectives.1.hidden.count' },   -- devices (base 1)
  items     = {},                                -- no items for this mission
  bonuses   = {
    { id = 'no_missed_checks', points = 15 },
    { id = 'devices_found_fast', points = 10 },  -- every device found within 2 minutes of the start
  },
  penalties = {},                                -- the common penalties always apply
})
