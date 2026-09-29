--[[ Crimson-Police · built-in mission: Gang Shootout (gang_shootout)
  Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
  Armed gang members are holed up at a remote hideout: 20 hostiles (scales) in three waves of 7 / 7 / 6,
  then "Secure the scene". NPC traffic is blocked within 120 m while the run is active.
  Locations (5 remote hideouts, away from civilian hotspots): Stab City trailer park on the Alamo Sea,
  the Grand Senora Desert scrapyard, the Paleto Forest sawmill, the Terminal container yard and the
  Elysian Island docks. Each has 14 hostile spawn points (facing the approach) and a scene marker, all ON
  the hideout's roads and yard lanes (GTA V vehicle-node network: the lanes between the container stacks,
  the trailer-park loop, the yard tracks; z = road height + 1 m), 7 m+ apart and 30 m+ from the start, so
  none is inside a container, trailer or shed.
  Blocks: hostile_waves → interact_points.
]]

RegisterMission({
  id           = 'gang_shootout',
  label        = 'Gang Shootout',
  description  = 'Armed gang members are holed up at a remote hideout. Clear it and secure the scene.',
  type         = 'tactical',      -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 600,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = false,       -- gunfire damages vehicles here, so no heavy-damage penalty

  locations = {
    {
      label  = 'Stab City trailer park, Alamo Sea',
      start  = { coords = vec3(104.80, 3658.60, 39.80), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(88.61, 3690.93, 39.73, 206.6), vec4(93.04, 3697.64, 39.76, 196.8),
        vec4(84.20, 3683.55, 39.76, 219.5), vec4(97.55, 3704.80, 39.76, 188.9),
        vec4(101.56, 3712.44, 39.71, 183.4), vec4(63.38, 3736.88, 39.70, 207.9),
        vec4(102.75, 3720.88, 39.70, 181.9), vec4(54.65, 3734.25, 39.68, 213.5),
        vec4(72.06, 3739.19, 39.72, 202.1), vec4(90.50, 3734.75, 39.72, 190.6),
        vec4(98.88, 3728.75, 39.72, 184.8), vec4(83.50, 3739.00, 39.72, 194.8),
        vec4(46.25, 3731.25, 39.62, 218.9), vec4(39.50, 3676.50, 39.70, 254.7),
      },
      scene  = vec3(90.82, 3694.29, 38.95),   -- "Secure the scene" point
    },
    {
      label  = 'Scrapyard, Grand Senora Desert',
      start  = { coords = vec3(2317.29, 3110.80, 48.30), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(2370.44, 3107.56, 48.02, 86.5), vec4(2376.85, 3112.65, 48.11, 91.8),
        vec4(2363.94, 3101.06, 47.86, 78.2), vec4(2385.25, 3111.25, 48.16, 90.4),
        vec4(2378.95, 3120.60, 48.07, 99.0), vec4(2356.38, 3098.25, 47.88, 72.2),
        vec4(2390.70, 3099.85, 48.16, 81.5), vec4(2392.30, 3108.75, 48.16, 88.4),
        vec4(2388.50, 3091.25, 48.16, 74.6), vec4(2386.19, 3120.44, 48.13, 98.0),
        vec4(2385.17, 3083.58, 48.16, 68.2), vec4(2348.25, 3097.15, 47.96, 66.2),
        vec4(2379.33, 3078.08, 48.22, 62.2), vec4(2399.38, 3111.38, 48.16, 90.4),
      },
      scene  = vec3(2367.31, 3104.19, 47.15),   -- "Secure the scene" point
    },
    {
      label  = 'Sawmill, Paleto Forest',
      start  = { coords = vec3(-616.01, 5331.01, 70.50), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(-589.50, 5298.88, 70.19, 39.5), vec4(-592.50, 5292.12, 70.19, 31.2),
        vec4(-585.50, 5307.12, 70.19, 51.9), vec4(-588.90, 5278.25, 70.39, 27.2),
        vec4(-582.19, 5273.00, 70.44, 30.2), vec4(-595.50, 5284.25, 70.22, 23.7),
        vec4(-582.50, 5313.58, 70.19, 62.5), vec4(-576.15, 5266.50, 70.44, 31.7),
        vec4(-599.50, 5278.50, 71.16, 17.5), vec4(-579.67, 5320.58, 70.19, 74.0),
        vec4(-574.36, 5259.11, 70.44, 30.1), vec4(-605.88, 5272.88, 71.75, 9.9),
        vec4(-577.25, 5327.62, 70.19, 85.0), vec4(-576.58, 5251.33, 70.46, 26.3),
      },
      scene  = vec3(-587.50, 5303.00, 69.39),   -- "Secure the scene" point
    },
    {
      label  = 'Container yard, Terminal',
      start  = { coords = vec3(1170.00, -3092.00, 5.90), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(1166.00, -3146.86, 5.82, 355.8), vec4(1166.00, -3155.50, 5.84, 356.4),
        vec4(1166.00, -3138.00, 5.78, 355.0), vec4(1166.00, -3130.50, 5.78, 354.1),
        vec4(1166.00, -3163.50, 5.83, 356.8), vec4(1161.17, -3169.50, 5.84, 353.5),
        vec4(1153.75, -3169.50, 5.88, 348.2), vec4(1166.15, -3175.95, 5.78, 357.4),
        vec4(1145.25, -3169.50, 5.84, 342.3), vec4(1166.25, -3184.25, 5.78, 357.7),
        vec4(1146.50, -3114.75, 5.78, 314.1), vec4(1137.17, -3169.50, 5.81, 337.0),
        vec4(1138.50, -3114.75, 5.78, 305.8), vec4(1166.25, -3192.25, 5.78, 357.9),
      },
      scene  = vec3(1166.00, -3151.29, 5.04),   -- "Secure the scene" point
    },
    {
      label  = 'Docks, Elysian Island',
      start  = { coords = vec3(150.00, -2922.00, 6.00), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points on the compound's roads and yard lanes (open ground), facing the approach
        vec4(150.50, -2981.00, 6.08, 0.5), vec4(141.88, -2981.06, 6.37, 352.2),
        vec4(159.05, -2981.05, 5.88, 8.7), vec4(148.88, -2993.38, 7.02, 359.1),
        vec4(134.92, -2983.25, 6.76, 346.2), vec4(167.25, -2981.25, 5.88, 16.2),
        vec4(140.35, -2993.35, 7.00, 352.3), vec4(173.58, -2976.17, 5.91, 23.5),
        vec4(131.00, -2993.38, 6.97, 345.1), vec4(173.25, -2968.50, 5.91, 26.6),
        vec4(173.75, -2961.35, 5.92, 31.1), vec4(123.58, -2993.42, 6.52, 339.7),
        vec4(180.25, -2979.00, 5.91, 28.0), vec4(175.75, -2952.75, 5.97, 39.9),
      },
      scene  = vec3(146.17, -2981.00, 5.41),   -- "Secure the scene" point
    },
  },

  objectives = {
    {
      block        = 'hostile_waves',
      label        = 'Neutralise all hostiles',
      minSeconds   = 60,                                       -- quicker than this is rejected
      waves        = { 7, 7, 6 },                              -- base counts, scaled by tier
      nextWave     = { aliveAtMost = 2, afterSeconds = 90 },
      weapons      = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },
      accuracy     = 25,                                       -- plus the tier's accuracy
      armour       = 0,                                        -- plus the tier's armour
      surrender    = { belowHealth = 0.25, chance = 0.30 },
      blockTraffic = 120.0,
    },
    {
      block      = 'interact_points',
      label      = 'Secure the scene',
      minSeconds = 8,
      points     = 'scene',
      target     = { label = 'Secure the scene' },   -- the ox_target option (not the locale default)
      progress   = { label = 'Securing scene', duration = 8000 },
    },
  },

  scaling   = { 'objectives.1.waves' },    -- counts multiplied by the tier
  items     = {},                          -- no items for this mission
  bonuses   = {
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
    { id = 'hostile_arrested', points = 5, each = true },
  },
  penalties = {},                          -- the common penalties always apply
})
