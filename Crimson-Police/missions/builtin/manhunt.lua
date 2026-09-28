--[[ Crimson-Police · built-in mission: Manhunt (manhunt)
  Investigation · 1–4 officers · ★★ · time limit 12 min · cooldown 20 min
  A fugitive (scales) hides somewhere in a 600 m search circle. Three clues (a dropped bag, a phone and
  a witness) shrink the circle 600 → 300 → 150 → 50 m; the fugitive runs when a participant gets within
  30 m and has to be caught and cuffed. Fugitives are unarmed: killing one fails the mission.
  Locations (5 search regions): Sandy Shores, Grapeseed, Paleto Bay, Harmony and the Grand Senora Desert
  around the Yellow Jack Inn. Each has 6+ clue spots and 7 hiding spots inside the 600 m circle.
  Blocks: search_area.
]]

RegisterMission({
  id           = 'manhunt',
  label        = 'Manhunt',
  description  = 'A fugitive is hiding somewhere in the search area. Check the clues to narrow the circle, then catch and cuff every fugitive. They are unarmed: bring them in alive.',
  type         = 'investigation', -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 2,
  timeLimit    = 720,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = true,        -- no gunfire expected: the heavy-damage penalty applies

  locations = {
    {
      label  = 'Sandy Shores',
      start  = { coords = vec3(1740.00, 3720.00, 33.80), radius = 600.0 },   -- entering the 600 m search circle
      center = vec3(1740.00, 3720.00, 33.80),   -- centre of the starting circle
      clues  = {   -- 7 clue spots (3 are used)
        vec3(1966.00, 3736.10, 31.40), vec3(1937.10, 3719.90, 31.60),
        vec3(1700.00, 3748.00, 33.60), vec3(1545.00, 3790.00, 33.30),
        vec3(1398.00, 3616.00, 34.00), vec3(1700.00, 3600.00, 34.50),
        vec3(1840.00, 3800.00, 31.70),
      },
      hiding = {   -- 7 hiding spots for the fugitives
        vec4(1957.00, 3752.80, 32.30, 278.6), vec4(1880.00, 3780.00, 32.80, 293.2),
        vec4(1620.00, 3775.00, 34.00, 65.4), vec4(1470.00, 3650.00, 34.60, 104.5),
        vec4(1760.00, 3560.00, 36.20, 187.1), vec4(1590.00, 3700.00, 34.40, 97.6),
        vec4(2025.00, 3745.00, 32.20, 275.0),
      },
    },
    {
      label  = 'Grapeseed',
      start  = { coords = vec3(1780.00, 4860.00, 42.00), radius = 600.0 },   -- entering the 600 m search circle
      center = vec3(1780.00, 4860.00, 42.00),   -- centre of the starting circle
      clues  = {   -- 7 clue spots (3 are used)
        vec3(1705.00, 4935.00, 41.20), vec3(1703.00, 4815.00, 41.20),
        vec3(1850.00, 4900.00, 41.60), vec3(1760.00, 4760.00, 40.40),
        vec3(1640.00, 4880.00, 41.10), vec3(1900.00, 4970.00, 42.60),
        vec3(1960.00, 4880.00, 41.40),
      },
      hiding = {   -- 7 hiding spots for the fugitives
        vec4(1815.00, 4960.00, 43.20, 340.7), vec4(1690.00, 4760.00, 41.50, 138.0),
        vec4(1930.00, 4805.00, 41.20, 249.9), vec4(1620.00, 4940.00, 42.80, 63.4),
        vec4(1880.00, 4720.00, 40.50, 215.5), vec4(1745.00, 4990.00, 43.50, 15.1),
        vec4(2000.00, 4950.00, 43.00, 292.2),
      },
    },
    {
      label  = 'Paleto Bay',
      start  = { coords = vec3(-104.00, 6380.00, 31.30), radius = 600.0 },   -- entering the 600 m search circle
      center = vec3(-104.00, 6380.00, 31.30),   -- centre of the starting circle
      clues  = {   -- 6 clue spots (3 are used)
        vec3(-106.80, 6456.30, 30.70), vec3(-46.00, 6535.70, 30.80),
        vec3(-287.90, 6204.60, 30.60), vec3(46.00, 6617.00, 30.70),
        vec3(-67.10, 6327.90, 30.30), vec3(-189.00, 6516.70, 29.90),
      },
      hiding = {   -- 7 hiding spots for the fugitives
        vec4(-56.50, 6469.00, 31.40, 331.9), vec4(-69.90, 6602.80, 31.20, 351.3),
        vec4(-208.40, 6456.40, 31.00, 53.8), vec4(-257.50, 6169.90, 31.50, 143.8),
        vec4(126.00, 6607.80, 31.60, 314.7), vec4(-78.50, 6261.70, 31.10, 192.2),
        vec4(14.80, 6540.70, 31.80, 323.5),
      },
    },
    {
      label  = 'Harmony',
      start  = { coords = vec3(560.00, 2720.00, 42.00), radius = 600.0 },   -- entering the 600 m search circle
      center = vec3(560.00, 2720.00, 42.00),   -- centre of the starting circle
      clues  = {   -- 7 clue spots (3 are used)
        vec3(545.00, 2677.30, 41.20), vec3(615.20, 2748.00, 41.20),
        vec3(547.10, 2658.40, 41.20), vec3(430.00, 2740.00, 40.90),
        vec3(700.00, 2640.00, 39.90), vec3(500.00, 2820.00, 42.10),
        vec3(760.00, 2760.00, 39.60),
      },
      hiding = {   -- 7 hiding spots for the fugitives
        vec4(620.00, 2790.00, 42.50, 319.4), vec4(470.00, 2650.00, 42.00, 127.9),
        vec4(380.00, 2715.00, 42.00, 91.6), vec4(660.00, 2712.00, 41.20, 265.4),
        vec4(560.00, 2870.00, 44.00, 0.0), vec4(820.00, 2660.00, 40.00, 257.0),
        vec4(300.00, 2760.00, 42.50, 81.3),
      },
    },
    {
      label  = 'Grand Senora Desert (Yellow Jack Inn)',
      start  = { coords = vec3(2000.00, 3075.00, 46.80), radius = 600.0 },   -- entering the 600 m search circle
      center = vec3(2000.00, 3075.00, 46.80),   -- centre of the starting circle
      clues  = {   -- 7 clue spots (3 are used)
        vec3(1995.00, 3035.00, 45.70), vec3(1920.00, 3120.00, 45.10),
        vec3(2080.00, 2990.00, 46.60), vec3(1880.00, 2980.00, 45.10),
        vec3(2140.00, 3120.00, 46.90), vec3(2000.00, 3200.00, 44.60),
        vec3(1860.00, 3070.00, 44.40),
      },
      hiding = {   -- 7 hiding spots for the fugitives
        vec4(2050.00, 3090.00, 47.00, 286.7), vec4(1950.00, 2950.00, 46.50, 158.2),
        vec4(2180.00, 3030.00, 48.00, 256.0), vec4(1870.00, 3170.00, 44.00, 53.8),
        vec4(2100.00, 3200.00, 46.50, 321.3), vec4(1800.00, 3000.00, 44.50, 110.6),
        vec4(2020.00, 2900.00, 47.00, 186.5),
      },
    },
  },

  objectives = {
    {
      block        = 'search_area',
      label        = 'Find and arrest the fugitive',
      minSeconds   = 60,
      center       = 'center',
      startRadius  = 600,
      shrinkTo     = { 300, 150, 50 },                            -- circle radius after each clue
      clues        = 'clues',
      clueCount    = 3,
      clueProps    = { 'prop_cs_heist_bag_02', 'prop_npc_phone_02', 'witness' },   -- bag, phone, witness NPC
      clueProgress = { label = 'Checking clue', duration = 4000 },
      hiding       = 'hiding',
      fugitives    = 1,                                           -- base count, scaled by tier
      runDistance  = 30.0,
      givesUp      = { stun = true, close = { distance = 3.0, seconds = 3 } },
      escape       = { distance = 300, seconds = 30 },
      cuff         = { label = 'Cuff suspect', duration = 5000 },
    },
  },

  scaling   = { 'objectives.1.fugitives' },   -- fugitives (base 1)
  items     = {},                             -- no items for this mission
  bonuses   = {
    { id = 'clues_first', points = 10 },      -- all 3 clues checked before the first arrest
    { id = 'no_weapons_fired', points = 10 },
  },
  penalties = {},                             -- the common penalties always apply
})
