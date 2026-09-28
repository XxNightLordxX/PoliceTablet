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
      start       = { coords = vec3(-1534.64, -3250.00, 13.94), radius = 20.0 },  -- course start marker
      medals      = { gold = 60, silver = 75, bronze = 90 },  -- seconds, first to last checkpoint (1061 m)
      checkpoints = {
        vec3(-1500.00, -3230.00, 13.94),
        vec3(-1452.04, -3193.07, 13.94),
        vec3(-1392.08, -3176.93, 13.94),
        vec3(-1348.12, -3133.07, 13.94),
        vec3(-1288.15, -3116.93, 13.94),
        vec3(-1231.53, -3075.00, 13.94),
        vec3(-1185.91, -3014.02, 13.94),
        vec3(-1189.93, -2947.06, 13.94),
        vec3(-1245.91, -2910.10, 13.94),
        vec3(-1316.53, -2927.78, 13.94),
        vec3(-1370.81, -2993.76, 13.94),
        vec3(-1448.94, -2998.45, 13.94),
        vec3(-1492.06, -3063.76, 13.94),
        vec3(-1559.02, -3067.78, 13.94),
        vec3(-1599.64, -3137.42, 13.94),
        vec3(-1573.30, -3203.04, 13.94),
      },
    },
    {
      label       = 'Sandy Shores Airfield',
      start       = { coords = vec3(1735.66, 3262.59, 41.11), radius = 20.0 },  -- course start marker
      medals      = { gold = 55, silver = 65, bronze = 80 },  -- seconds, first to last checkpoint (939 m)
      checkpoints = {
        vec3(1698.06, 3248.37, 41.07),
        vec3(1642.17, 3225.12, 41.01),
        vec3(1581.11, 3221.18, 40.95),
        vec3(1526.26, 3194.06, 40.89),
        vec3(1465.20, 3190.12, 40.83),
        vec3(1399.14, 3166.21, 40.76),
        vec3(1323.42, 3139.70, 40.68),
        vec3(1263.39, 3131.90, 40.62),
        vec3(1283.71, 3164.26, 40.65),
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
      start       = { coords = vec3(2101.72, 4774.79, 40.95), radius = 20.0 },  -- course start marker
      medals      = { gold = 40, silver = 50, bronze = 60 },  -- seconds, first to last checkpoint (691 m)
      checkpoints = {
        vec3(2070.00, 4760.00, 40.95),
        vec3(2027.22, 4733.43, 40.95),
        vec3(1976.83, 4723.18, 40.95),
        vec3(1936.59, 4691.17, 40.95),
        vec3(1886.20, 4680.91, 40.95),
        vec3(1834.36, 4650.12, 40.95),
        vec3(1802.03, 4612.98, 40.95),
        vec3(1819.24, 4587.90, 40.95),
        vec3(1868.78, 4599.97, 40.95),
        vec3(1916.82, 4638.92, 40.95),
        vec3(1977.54, 4650.68, 40.95),
        vec3(2025.58, 4689.63, 40.95),
        vec3(2079.65, 4703.81, 40.95),
        vec3(2107.75, 4750.02, 40.95),
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
