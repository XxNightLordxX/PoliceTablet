--[[ Crimson-Police · built-in mission: Gang Shootout (gang_shootout)
  Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
  Armed gang members are holed up at a remote hideout: 20 hostiles (scales) in three waves of 7 / 7 / 6,
  then "Secure the scene". NPC traffic is blocked within 120 m while the run is active.
  Locations (5 remote hideouts, away from civilian hotspots): Stab City trailer park on the Alamo Sea,
  the Grand Senora Desert scrapyard, the Paleto Forest sawmill, the Terminal container yard and the
  Elysian Island docks. Each has 14 hostile spawn points (facing the approach) and a scene marker.
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
      spawns = {   -- 14 hostile spawn points, facing the approach
        vec4(82.31, 3690.26, 40.40, 215.4), vec4(90.81, 3693.87, 40.40, 201.6),
        vec4(73.67, 3678.45, 40.40, 237.5), vec4(89.89, 3709.54, 40.40, 196.3),
        vec4(61.68, 3687.26, 40.40, 236.4), vec4(95.75, 3720.39, 40.40, 188.3),
        vec4(47.92, 3685.89, 40.40, 244.4), vec4(78.34, 3723.62, 40.40, 202.1),
        vec4(50.43, 3700.89, 40.40, 232.1), vec4(68.22, 3740.56, 40.40, 204.1),
        vec4(39.41, 3716.82, 40.40, 228.3), vec4(59.75, 3720.28, 40.40, 216.1),
        vec4(107.62, 3699.63, 40.40, 176.1), vec4(66.67, 3667.95, 40.40, 256.2),
      },
      scene  = vec3(70.00, 3705.00, 40.10),   -- "Secure the scene" point
    },
    {
      label  = 'Scrapyard, Grand Senora Desert',
      start  = { coords = vec3(2317.29, 3110.80, 48.30), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points, facing the approach
        vec4(2359.00, 3104.93, 48.60, 82.0), vec4(2349.46, 3094.54, 48.60, 63.2),
        vec4(2356.49, 3121.51, 48.60, 105.3), vec4(2363.22, 3085.95, 48.60, 61.6),
        vec4(2366.31, 3125.21, 48.60, 106.4), vec4(2374.60, 3073.80, 48.60, 57.2),
        vec4(2379.67, 3132.20, 48.60, 108.9), vec4(2385.09, 3084.55, 48.60, 68.8),
        vec4(2389.02, 3122.47, 48.60, 99.2), vec4(2402.27, 3085.37, 48.60, 73.3),
        vec4(2405.22, 3120.57, 48.60, 96.3), vec4(2389.93, 3102.17, 48.60, 83.2),
        vec4(2348.75, 3082.77, 48.60, 48.3), vec4(2350.85, 3128.93, 48.60, 118.4),
      },
      scene  = vec3(2375.00, 3105.00, 48.60),   -- "Secure the scene" point
    },
    {
      label  = 'Sawmill, Paleto Forest',
      start  = { coords = vec3(-616.01, 5331.01, 70.50), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points, facing the approach
        vec4(-588.89, 5302.07, 71.00, 43.1), vec4(-599.61, 5297.06, 71.00, 25.8),
        vec4(-583.89, 5314.43, 71.00, 62.7), vec4(-593.85, 5286.34, 71.00, 26.4),
        vec4(-570.86, 5307.93, 71.00, 62.9), vec4(-595.81, 5271.26, 71.00, 18.7),
        vec4(-552.66, 5312.34, 71.00, 73.6), vec4(-579.32, 5269.65, 71.00, 30.9),
        vec4(-550.97, 5294.24, 71.00, 60.5), vec4(-565.08, 5255.39, 71.00, 34.0),
        vec4(-540.23, 5284.49, 71.00, 58.5), vec4(-565.72, 5280.05, 71.00, 44.6),
        vec4(-611.60, 5293.85, 71.00, 6.8), vec4(-577.54, 5326.31, 71.00, 83.0),
      },
      scene  = vec3(-575.00, 5290.00, 70.80),   -- "Secure the scene" point
    },
    {
      label  = 'Container yard, Terminal',
      start  = { coords = vec3(1170.00, -3092.00, 5.90), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points, facing the approach
        vec4(1171.42, -3129.65, 6.10, 2.2), vec4(1155.16, -3126.25, 6.10, 336.6),
        vec4(1184.81, -3127.19, 6.10, 22.8), vec4(1154.76, -3141.20, 6.10, 342.8),
        vec4(1187.44, -3138.67, 6.10, 20.5), vec4(1139.72, -3147.35, 6.10, 331.3),
        vec4(1199.60, -3149.48, 6.10, 27.2), vec4(1152.20, -3162.93, 6.10, 345.9),
        vec4(1187.98, -3161.23, 6.10, 14.6), vec4(1150.96, -3176.21, 6.10, 347.3),
        vec4(1187.89, -3176.53, 6.10, 12.0), vec4(1169.69, -3167.60, 6.10, 359.8),
        vec4(1143.34, -3127.63, 6.10, 323.2), vec4(1198.98, -3124.81, 6.10, 41.5),
      },
      scene  = vec3(1170.00, -3150.00, 6.20),   -- "Secure the scene" point
    },
    {
      label  = 'Docks, Elysian Island',
      start  = { coords = vec3(150.00, -2922.00, 6.00), radius = 80.0 },
      spawns = {   -- 14 hostile spawn points, facing the approach
        vec4(150.00, -2962.80, 6.10, 0.0), vec4(136.71, -2959.54, 6.10, 340.5),
        vec4(163.77, -2960.34, 6.10, 19.8), vec4(131.11, -2969.53, 6.10, 338.3),
        vec4(165.21, -2968.95, 6.10, 17.9), vec4(117.62, -2978.87, 6.10, 330.3),
        vec4(181.82, -2983.34, 6.10, 27.4), vec4(130.77, -2992.97, 6.10, 344.8),
        vec4(166.80, -2990.09, 6.10, 13.9), vec4(135.29, -3011.54, 6.10, 350.7),
        vec4(165.08, -3010.92, 6.10, 9.6), vec4(150.54, -2995.59, 6.10, 0.4),
        vec4(125.91, -2953.25, 6.10, 322.4), vec4(174.89, -2955.11, 6.10, 36.9),
      },
      scene  = vec3(150.00, -2980.00, 6.30),   -- "Secure the scene" point
    },
  },

  objectives = {
    {
      block        = 'hostile_waves',
      label        = 'Neutralise all hostiles',
      minSeconds   = 60,                                       -- quicker than this is rejected
      spawns       = 'spawns',
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
