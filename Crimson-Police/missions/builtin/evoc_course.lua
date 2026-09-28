--[[ Crimson-Police · built-in mission
  EVOC Course · evoc_course · Training · 1 officer · 2 stars · 4 min · cooldown 10 min
  Emergency vehicle operations course: drive every checkpoint in order in a police vehicle (a
  missed one must be driven through before the next counts). Each wall or vehicle contact adds
  2 s. Gold / Silver / Bronze by course time replace the common time bonus; no contact +10.
  Layouts (checkpoint markers only, no cones or props) on open airfield ground: LSIA (runway
  and taxiway west of the terminal), Sandy Shores Airfield runway, McKenzie Field (Grapeseed).
  Blocks: checkpoint_route (use = 'all', drive-through, medals from location.medals).
  Start: the course start marker; the course clock starts at checkpoint 1 (timerStart = 'first').
]]

RegisterMission({
  id           = 'evoc_course',
  label        = 'EVOC Course',
  description  = 'Emergency vehicle operations course: drive through every checkpoint in order in a police vehicle. Every contact costs 2 seconds.',
  type         = 'training',     -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 1,
  difficulty   = 2,
  timeLimit    = 240,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 600,            -- per officer, seconds
  vehiclePenalties = true,       -- heavy vehicle damage is penalised here

  locations = {
    {
      label       = 'LSIA runway and taxiway',
      start       = { coords = vec3(-1484.64, -3212.00, 13.94), radius = 20.0 },  -- course start marker
      medals      = { gold = 60, silver = 75, bronze = 90 },  -- seconds, first to last checkpoint (1061 m)
      checkpoints = {
        vec3(-1450.00, -3192.00, 13.94),
        vec3(-1402.04, -3155.07, 13.94),
        vec3(-1342.08, -3138.93, 13.94),
        vec3(-1298.12, -3095.07, 13.94),
        vec3(-1238.15, -3078.93, 13.94),
        vec3(-1181.53, -3037.00, 13.94),
        vec3(-1135.91, -2976.02, 13.94),
        vec3(-1139.93, -2909.06, 13.94),
        vec3(-1195.91, -2872.10, 13.94),
        vec3(-1266.53, -2889.78, 13.94),
        vec3(-1320.81, -2955.76, 13.94),
        vec3(-1398.94, -2960.45, 13.94),
        vec3(-1442.06, -3025.76, 13.94),
        vec3(-1509.02, -3029.78, 13.94),
        vec3(-1549.64, -3099.42, 13.94),
        vec3(-1523.30, -3165.04, 13.94),
      },
    },
    {
      label       = 'Sandy Shores Airfield',
      start       = { coords = vec3(1735.66, 3262.59, 41.11), radius = 20.0 },  -- course start marker
      medals      = { gold = 55, silver = 65, bronze = 80 },  -- seconds, first to last checkpoint (939 m)
      checkpoints = {
        vec3(1697.02, 3252.24, 41.07),
        vec3(1641.14, 3228.98, 41.01),
        vec3(1579.04, 3228.90, 40.95),
        vec3(1525.23, 3197.92, 40.89),
        vec3(1463.13, 3197.85, 40.83),
        vec3(1397.59, 3172.00, 40.76),
        vec3(1322.90, 3141.64, 40.68),
        vec3(1262.36, 3135.77, 40.62),
        vec3(1277.02, 3158.33, 40.64),
        vec3(1345.67, 3172.58, 40.71),
        vec3(1415.35, 3182.97, 40.78),
        vec3(1480.38, 3210.75, 40.85),
        vec3(1550.58, 3219.21, 40.92),
        vec3(1615.61, 3246.98, 40.99),
        vec3(1675.63, 3254.79, 41.05),
        vec3(1713.23, 3269.00, 41.09),
      },
    },
    {
      label       = 'McKenzie Field, Grapeseed',
      start       = { coords = vec3(2126.72, 4789.79, 40.95), radius = 20.0 },  -- course start marker
      medals      = { gold = 40, silver = 50, bronze = 60 },  -- seconds, first to last checkpoint (691 m)
      checkpoints = {
        vec3(2095.00, 4775.00, 40.95),
        vec3(2052.22, 4748.43, 40.95),
        vec3(2001.83, 4738.18, 40.95),
        vec3(1961.59, 4706.17, 40.95),
        vec3(1911.20, 4695.91, 40.95),
        vec3(1859.36, 4665.12, 40.95),
        vec3(1827.03, 4627.98, 40.95),
        vec3(1844.24, 4602.90, 40.95),
        vec3(1893.78, 4614.97, 40.95),
        vec3(1941.82, 4653.92, 40.95),
        vec3(2002.54, 4665.68, 40.95),
        vec3(2050.58, 4704.63, 40.95),
        vec3(2104.65, 4718.81, 40.95),
        vec3(2132.75, 4765.02, 40.95),
      },
    },
  },

  objectives = {
    {
      block             = 'checkpoint_route',
      label             = 'Drive the course',
      minSeconds        = 45,                -- quicker than this is rejected
      checkpoints       = 'checkpoints',
      use               = 'all',
      radius            = 8.0,
      stopFor           = 0,                 -- drive-through gates
      policeVehicle     = true,
      medals            = { gold = 60, silver = 75, bronze = 90 },   -- fallback; every layout sets location.medals
      contactPenalty    = 2,                 -- seconds per wall or vehicle contact
      timerStart        = 'first',
      failIfUndriveable = true,
    },
  },

  scaling   = {},
  items     = {},
  bonuses   = {
    { id = 'medal_gold',   points = 50 },
    { id = 'medal_silver', points = 25 },
    { id = 'medal_bronze', points = 10 },
    { id = 'no_contact',   points = 10 },
  },
  penalties = {},                          -- the common penalties always apply
})
