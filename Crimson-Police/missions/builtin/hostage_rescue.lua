--[[ Crimson-Police · built-in mission: Hostage Rescue (hostage_rescue)
  Tactical · 1–4 officers · ★★★ · time limit 10 min · cooldown 20 min
  Armed robbers hold three hostages inside a bank: neutralise the 4 hostiles (scales), cut every hostage
  free ("Cut restraints", 6 s) and walk them to the safe marker outside. A hostage hit by participant fire
  costs 50 points each (protect_rescue hitPenalty); a hostage death fails the mission.
  Locations (6 enterable base-game Fleeca banks): Legion Square, Hawick Avenue (Alta), Hawick Avenue
  (Burton), Boulevard Del Perro (Rockford Hills), Great Ocean Highway (Banham Canyon) and Route 68. Every
  point is placed in the bank's own frame (teller position and heading): hostiles behind the counter, in
  the back office by the vault and in the lobby; hostages kneel in the lobby; the safe marker is outside.
  Blocks: hostile_waves → protect_rescue (the hostages spawn when the run moves to In progress).
]]

RegisterMission({
  id           = 'hostage_rescue',
  label        = 'Hostage Rescue',
  description  = 'Armed robbers are holding hostages inside a bank. Neutralise the hostiles, cut the hostages free and walk them out to the safe point. Watch your fire.',
  type         = 'tactical',      -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 600,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = false,       -- vehicles take gunfire here, so no heavy-damage penalty

  locations = {
    {
      label    = 'Fleeca Bank, Legion Square',
      start    = { coords = vec3(186.05, -1039.03, 28.57), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(149.46, -1042.09, 29.37, 335.4), vec4(151.23, -1042.79, 29.37, 335.4),
        vec4(147.23, -1044.81, 29.37, 335.4), vec4(149.74, -1044.85, 29.37, 335.4),
        vec4(152.28, -1038.32, 29.37, 335.4), vec4(148.33, -1037.83, 29.37, 355.4),
        vec4(153.78, -1040.33, 29.37, 315.4),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(151.09, -1039.97, 29.37, 155.4),
        vec4(149.53, -1038.82, 29.37, 155.4),
        vec4(152.42, -1040.91, 29.37, 155.4),
      },
      safe     = vec3(154.66, -1030.72, 29.07),   -- safe marker outside the entrance
    },
    {
      label    = 'Fleeca Bank, Hawick Avenue (Alta)',
      start    = { coords = vec3(350.23, -275.68, 53.36), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(313.84, -280.58, 54.16, 338.3), vec4(315.64, -281.19, 54.16, 338.3),
        vec4(311.75, -283.41, 54.16, 338.3), vec4(314.25, -283.33, 54.16, 338.3),
        vec4(316.47, -276.68, 54.16, 338.3), vec4(312.49, -276.39, 54.16, 358.3),
        vec4(318.07, -278.60, 54.16, 318.3),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(315.36, -278.39, 54.16, 158.3),
        vec4(313.74, -277.31, 54.16, 158.3),
        vec4(316.73, -279.26, 54.16, 158.3),
      },
      safe     = vec3(318.46, -268.97, 53.86),   -- safe marker outside the entrance
    },
    {
      label    = 'Fleeca Bank, Hawick Avenue (Burton)',
      start    = { coords = vec3(-315.20, -44.22, 48.24), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(-351.23, -51.28, 49.04, 341.7), vec4(-349.39, -51.78, 49.04, 341.7),
        vec4(-353.15, -54.23, 49.04, 341.7), vec4(-350.65, -54.00, 49.04, 341.7),
        vec4(-348.84, -47.23, 49.04, 341.7), vec4(-352.82, -47.17, 49.04, 1.7),
        vec4(-347.13, -49.05, 49.04, 321.7),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(-349.85, -49.00, 49.04, 161.7),
        vec4(-351.52, -48.02, 49.04, 161.7),
        vec4(-348.42, -49.79, 49.04, 161.7),
      },
      safe     = vec3(-347.31, -39.41, 48.74),   -- safe marker outside the entrance
    },
    {
      label    = 'Fleeca Bank, Boulevard Del Perro',
      start    = { coords = vec3(-1188.02, -304.01, 36.98), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(-1211.90, -331.90, 37.78, 20.1), vec4(-1210.15, -331.15, 37.78, 20.1),
        vec4(-1211.58, -335.40, 37.78, 20.1), vec4(-1209.76, -333.67, 37.78, 20.1),
        vec4(-1212.54, -327.24, 37.78, 20.1), vec4(-1215.70, -329.67, 37.78, 40.1),
        vec4(-1210.06, -327.61, 37.78, 0.1),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(-1212.23, -329.25, 37.78, 200.1),
        vec4(-1214.15, -329.53, 37.78, 200.1),
        vec4(-1210.62, -328.98, 37.78, 200.1),
      },
      safe     = vec3(-1216.19, -320.16, 37.48),   -- safe marker outside the entrance
    },
    {
      label    = 'Fleeca Bank, Great Ocean Highway',
      start    = { coords = vec3(-2975.60, 516.84, 14.90), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(-2961.14, 483.09, 15.70, 83.8), vec4(-2961.04, 484.99, 15.70, 83.8),
        vec4(-2957.86, 481.83, 15.70, 83.8), vec4(-2958.60, 484.22, 15.70, 83.8),
        vec4(-2965.61, 484.58, 15.70, 83.8), vec4(-2964.82, 480.67, 15.70, 103.8),
        vec4(-2964.18, 486.64, 15.70, 63.8),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(-2963.66, 483.97, 15.70, 263.8),
        vec4(-2964.26, 482.12, 15.70, 263.8),
        vec4(-2963.19, 485.52, 15.70, 263.8),
      },
      safe     = vec3(-2973.57, 484.43, 15.40),   -- safe marker outside the entrance
    },
    {
      label    = 'Fleeca Bank, Route 68',
      start    = { coords = vec3(1142.35, 2691.03, 37.29), radius = 60.0 },   -- on the street outside
      spawns   = {   -- 7 hostile spots inside (counter, back office, lobby)
        vec4(1174.80, 2708.20, 38.09, 178.5), vec4(1172.90, 2708.15, 38.09, 178.5),
        vec4(1175.79, 2711.58, 38.09, 178.5), vec4(1173.46, 2710.64, 38.09, 178.5),
        vec4(1173.68, 2703.63, 38.09, 178.5), vec4(1177.51, 2704.73, 38.09, 198.5),
        vec4(1171.51, 2704.88, 38.09, 158.5),
      },
      hostages = {   -- 3 hostages kneeling in the lobby
        vec4(1174.13, 2705.62, 38.09, 358.5),
        vec4(1176.02, 2705.17, 38.09, 358.5),
        vec4(1172.54, 2705.96, 38.09, 358.5),
      },
      safe     = vec3(1174.48, 2695.70, 37.79),   -- safe marker outside the entrance
    },
  },

  objectives = {
    {
      block      = 'hostile_waves',
      label      = 'Neutralise the hostage takers',
      minSeconds = 30,
      waves      = { 4 },                                        -- one wave of 4 inside, scaled by tier
      weapons    = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },
      accuracy   = 25,                                           -- plus the tier's accuracy
      armour     = 0,                                            -- plus the tier's armour
      behaviour  = 'hold',                                       -- they hold their positions inside
      surrender  = { belowHealth = 0.25, chance = 0.30 },
    },
    {
      block      = 'protect_rescue',
      label      = 'Free the hostages',
      minSeconds = 15,
      npcs       = 'hostages',
      count      = 3,                                            -- hostages stay at 3
      restrained = true,
      freeTime   = 6000,                                         -- "Cut restraints" progress, ms
      target     = { label = 'Cut restraints' },
      safe       = 'safe',
      safeRadius = 6.0,
      hitPenalty = 50,                                           -- per hostage hit by participant fire
      failIfDies = true,
    },
  },

  scaling   = { 'objectives.1.waves' },    -- hostiles (the hostages do not scale)
  items     = {},                          -- no items for this mission
  bonuses   = {
    { id = 'no_hostage_hurt', points = 15 },
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
  },
  penalties = {
    { id = 'hostage_hit', points = -50, each = true },   -- recorded by protect_rescue for each hit
  },
})
