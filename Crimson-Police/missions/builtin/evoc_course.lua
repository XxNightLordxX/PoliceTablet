--[[ Crimson-Police · built-in mission
  EVOC Course · evoc_course · Training · 1 officer · 2 stars · 4 min · cooldown 10 min
  Emergency vehicle operations course: drive through every checkpoint in order at the wheel of a
  vehicle (any vehicle; a missed one must be driven through before the next counts). Each wall or
  vehicle contact adds 2 s. Gold / Silver / Bronze by course time replace the common time bonus;
  no contact +10.
  Layouts (checkpoint markers only, no cones or props) on open airfield ground: LSIA (runways
  and taxiways west of the terminal), Sandy Shores Airfield runway, McKenzie Field (Grapeseed:
  a slalom down the airstrip and back, kept on the flat strip and clear of Seaview Rd).
  Checkpoint heights are ground + 1 m (the marker is drawn 1 m below the point).
  Blocks: checkpoint_route (use = 'all', drive-through, medals from location.medals).
  Start: the course start marker; the course clock starts at checkpoint 1 (timerStart = 'first').
]]

RegisterMission({
  id           = 'evoc_course',
  label        = 'EVOC Course',
  description  = 'Emergency vehicle operations course: drive through every checkpoint in order at the wheel of a vehicle. Every contact costs 2 seconds.',
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
      start       = { coords = vec3(2101.72, 4774.79, 41.21), radius = 20.0 },  -- course start marker, hangar apron
      medals      = { gold = 36, silver = 44, bronze = 55 },  -- seconds, first to last checkpoint (481 m)
      checkpoints = {                   -- all on the flat airstrip (ground 40.1-40.8), 27 m+ from Seaview Rd
        vec3(2082.69, 4763.20, 41.21),
        vec3(2054.52, 4740.16, 41.41),
        vec3(2016.05, 4740.98, 41.27),
        vec3(1990.26, 4712.44, 41.34),
        vec3(1952.58, 4711.43, 41.09),
        vec3(1924.41, 4688.39, 40.67),
        vec3(1918.17, 4720.54, 41.06),
        vec3(1949.09, 4744.76, 41.62),
        vec3(1987.14, 4752.47, 41.26),
        vec3(2018.07, 4776.70, 41.23),
        vec3(2055.72, 4785.32, 41.22),
        vec3(2094.17, 4792.10, 41.22),
        vec3(2108.81, 4765.75, 41.24),
        vec3(2078.26, 4748.22, 41.38),
      },
    },
  },

  objectives = {
    {
      block             = 'checkpoint_route',
      label             = 'Drive the course',
      minSeconds        = 25,                -- quicker than this is rejected; below every layout's gold time
      checkpoints       = 'checkpoints',
      use               = 'all',
      radius            = 8.0,
      stopFor           = 0,                 -- drive-through gates
      vehicleRequired   = true,              -- at the wheel of a vehicle (any vehicle)
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
