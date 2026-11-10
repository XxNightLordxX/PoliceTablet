--[[ Crimson-Police · built-in mission: Bomb Disposal (bomb_disposal)
  Tactical · 1–4 officers · ★★ · time limit 6 min (the device timer) · cooldown 20 min
  A device (scales) is hidden at a random hiding spot of a store. Search the spots ("Search", 3 s) until
  every device is found, then defuse each one with 4 ox_lib skill checks (easy, medium, medium, hard).
  All devices share the one timer: a miss takes 30 s off it, 2 misses in a row on one device set it off
  (an explosion effect only, damage 0) and the mission fails.
  Locations (6 base-game 24/7 stores): Innocence Boulevard, Clinton Avenue, Palomino Freeway, Senora
  Freeway, Senora Freeway (Mount Chiliad) and Barbareno Road (Chumash). The seven hiding spots of a
  store are placed in the store's own frame (clerk position and heading, back-room safe): behind and in
  front of the counter, two in the back room, one on the shop floor and two outside by the entrance, each
  at least 2 m from the qbx_storerobbery registers and safes and the ox_inventory shop counter, so their
  ox_target options never overlap (tests/foreign_sites_spec.lua).
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
        vec3(24.51, -1349.67, 28.60), vec3(26.79, -1345.27, 28.60),
        vec3(28.46, -1336.95, 28.60), vec3(26.21, -1337.99, 28.60),
        vec3(34.53, -1348.53, 28.60), vec3(27.64, -1352.53, 28.60),
        vec3(34.15, -1352.84, 28.60),
      },
    },
    {
      label  = '24/7 Supermarket, Clinton Avenue',
      start  = { coords = vec3(365.90, 288.60, 102.97), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(371.56, 324.35, 102.67), vec3(375.27, 327.14, 102.67),
        vec3(379.92, 334.79, 102.67), vec3(376.89, 335.33, 102.67),
        vec3(381.20, 321.35, 102.67), vec3(373.39, 319.77, 102.67),
        vec3(379.46, 317.38, 102.67),
      },
    },
    {
      label  = '24/7 Supermarket, Palomino Freeway',
      start  = { coords = vec3(2593.89, 383.62, 108.02), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(2559.26, 380.11, 107.72), vec3(2554.87, 383.54, 107.72),
        vec3(2547.04, 384.64, 107.72), vec3(2548.00, 382.99, 107.72),
        vec3(2558.44, 390.70, 107.72), vec3(2561.82, 383.49, 107.72),
        vec3(2562.70, 389.95, 107.72),
      },
    },
    {
      label  = '24/7 Supermarket, Senora Freeway',
      start  = { coords = vec3(2713.48, 3267.54, 54.64), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(2679.77, 3277.83, 54.34), vec3(2677.62, 3282.20, 54.34),
        vec3(2670.39, 3286.63, 54.34), vec3(2670.99, 3288.23, 54.34),
        vec3(2683.44, 3287.64, 54.34), vec3(2683.81, 3279.68, 54.34),
        vec3(2687.09, 3285.32, 54.34),
      },
    },
    {
      label  = '24/7 Supermarket, Senora Freeway (Mount Chiliad)',
      aliases = { '24/7 Supermarket, Great Ocean Highway (Mount Chiliad)' },   -- the old label: a switch saved by it still matches
      start  = { coords = vec3(1718.21, 6379.24, 34.44), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(1726.53, 6413.21, 34.14), vec3(1730.83, 6416.05, 34.14),
        vec3(1736.93, 6421.54, 34.14), vec3(1733.25, 6422.62, 34.14),
        vec3(1736.70, 6410.31, 34.14), vec3(1728.77, 6409.52, 34.14),
        vec3(1734.57, 6406.54, 34.14),
      },
    },
    {
      label  = '24/7 Supermarket, Barbareno Road (Chumash)',
      start  = { coords = vec3(-3204.96, 1001.14, 12.23), radius = 50.0 },   -- outside; the device timer starts on arrival
      hiding = {   -- 7 hiding spots (floor level): counter, back room, shop floor, outside
        vec3(-3240.08, 999.15, 11.93), vec3(-3243.92, 1002.36, 11.93),
        vec3(-3251.97, 1003.13, 11.93), vec3(-3252.37, 1004.79, 11.93),
        vec3(-3240.08, 1009.71, 11.93), vec3(-3237.00, 1002.36, 11.93),
        vec3(-3237.15, 1005.48, 11.93),
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
