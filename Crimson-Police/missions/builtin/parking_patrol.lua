--[[ Crimson-Police · built-in mission: Illegal Parking Patrol (parking_patrol)
  Patrol · 1 officer · ★ · time limit 10 min · cooldown 10 min · quiet patrol
  A judgement sweep of five parked cars along one street: Inspect shows the posted rule, permit, meter and
  how long the car has been there, Run plate shows valid, expired or STOLEN, then No action, a citation or an
  Impound (the tow truck collects it). The server rolls each car: legal 45%, a violation 50% (ticket-level
  on metered and permit spots, tow-level on no-parking, hydrant and loading spots; free spots are legal or
  stolen), stolen 5%. A returning driver (25% per citation or impound, once) and a thief (50% on the first
  inspect of a stolen car, runs once an officer is within 15 m) may turn up.
  Locations (7 districts): Alta Street, Downtown, Ginger Street, Little Seoul, Mirror Park Boulevard, Mirror Park, Prosperity Street, Del Perro, Magellan Avenue, Vespucci, Eclipse Boulevard, West Vinewood, Marina Drive, Sandy Shores.
  Each district is one street with 10 kerb spots taken from the GTA V vehicle nodes: every spot sits 4.8 m
  right of the road centre line in the driving direction, 26 m apart, facing the traffic; the posted rules
  are spread so each street mixes meters, permits, no-parking, hydrants, a loading zone and free spots. The
  entry point is on the centre line 45 m before the first spot, and every point is at least 200 m from any
  other mission's locations (tests/zone_lint_spec.lua).
  Blocks: field_contact (mode = 'parked').
]]

RegisterMission({
  id           = 'parking_patrol',
  label        = 'Illegal Parking Patrol',
  description  = 'Parking complaints on one street. Inspect every car, run the plates and decide: no action, a citation or a tow. Most cars do not need towing.',
  type         = 'patrol',       -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 1,
  difficulty   = 1,
  timeLimit    = 600,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 600,            -- per officer, seconds
  vehiclePenalties = true,       -- the heavy vehicle-damage penalty applies
  quietPatrol  = true,           -- lights and siren after the first arrival cost -10, personal

  locations = {
    {
      label = 'Alta Street, Downtown',
      start = { coords = vec3(-100.74, -658.19, 35.89), radius = 40.0 },   -- patrol entry point, 45 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(-121.17, -698.60, 34.31, 159.7), rule = 'metered'   , street = 'Alta Street' },
        { coords = vec4(-130.25, -722.94, 34.29, 159.4), rule = 'no_parking', street = 'Alta Street' },
        { coords = vec4(-139.17, -747.19, 33.65, 157.6), rule = 'permit'    , street = 'Alta Street' },
        { coords = vec4(-148.14, -771.81, 32.39, 160.1), rule = 'hydrant'   , street = 'Alta Street' },
        { coords = vec4(-156.97, -796.28, 31.44, 160.2), rule = 'free'      , street = 'Alta Street' },
        { coords = vec4(-165.92, -820.64, 30.71, 159.7), rule = 'metered'   , street = 'Alta Street' },
        { coords = vec4(-174.77, -845.14, 29.61, 160.3), rule = 'loading'   , street = 'Alta Street' },
        { coords = vec4(-183.42, -869.71, 28.84, 160.9), rule = 'permit'    , street = 'Alta Street' },
        { coords = vec4(-192.53, -893.88, 28.82, 158.8), rule = 'free'      , street = 'Alta Street' },
        { coords = vec4(-201.72, -918.19, 28.84, 158.7), rule = 'no_parking', street = 'Alta Street' },
      },
    },
    {
      label = 'Ginger Street, Little Seoul',
      start = { coords = vec3(-445.25, -636.00, 31.44), radius = 40.0 },   -- patrol entry point, 47 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(-448.78, -589.53, 26.43, 41.2), rule = 'metered'   , street = 'Ginger Street' },
        { coords = vec4(-474.45, -576.53, 25.01, 83.9), rule = 'no_parking', street = 'Ginger Street' },
        { coords = vec4(-500.94, -576.20, 24.78, 90.0), rule = 'permit'    , street = 'Ginger Street' },
        { coords = vec4(-526.94, -576.20, 24.78, 90.0), rule = 'hydrant'   , street = 'Ginger Street' },
        { coords = vec4(-552.94, -576.20, 24.78, 90.0), rule = 'free'      , street = 'Ginger Street' },
        { coords = vec4(-578.94, -576.20, 24.78, 90.0), rule = 'metered'   , street = 'Ginger Street' },
        { coords = vec4(-604.94, -576.20, 24.78, 90.0), rule = 'loading'   , street = 'Ginger Street' },
        { coords = vec4(-630.94, -576.20, 24.78, 90.0), rule = 'permit'    , street = 'Ginger Street' },
        { coords = vec4(-656.25, -573.98, 24.78, 83.4), rule = 'free'      , street = 'Ginger Street' },
        { coords = vec4(-682.66, -572.69, 24.78, 88.9), rule = 'no_parking', street = 'Ginger Street' },
      },
    },
    {
      label = 'Mirror Park Boulevard, Mirror Park',
      start = { coords = vec3(917.03, -133.82, 76.31), radius = 40.0 },   -- patrol entry point, 45 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(881.54, -105.86, 78.94, 57.0), rule = 'metered'   , street = 'Mirror Park Boulevard' },
        { coords = vec4(859.45, -92.00, 79.15, 58.0), rule = 'no_parking', street = 'Mirror Park Boulevard' },
        { coords = vec4(837.38, -78.19, 80.12, 58.4), rule = 'permit'    , street = 'Mirror Park Boulevard' },
        { coords = vec4(815.76, -64.07, 80.12, 56.3), rule = 'hydrant'   , street = 'Mirror Park Boulevard' },
        { coords = vec4(795.10, -48.40, 80.12, 55.7), rule = 'free'      , street = 'Mirror Park Boulevard' },
        { coords = vec4(773.16, -34.05, 80.59, 58.3), rule = 'metered'   , street = 'Mirror Park Boulevard' },
        { coords = vec4(751.15, -20.35, 81.67, 57.5), rule = 'loading'   , street = 'Mirror Park Boulevard' },
        { coords = vec4(728.99, -6.65, 82.76, 58.1), rule = 'permit'    , street = 'Mirror Park Boulevard' },
        { coords = vec4(706.82, 6.98, 83.66, 58.4), rule = 'free'      , street = 'Mirror Park Boulevard' },
        { coords = vec4(684.65, 20.58, 83.68, 58.5), rule = 'no_parking', street = 'Mirror Park Boulevard' },
      },
    },
    {
      label = 'Prosperity Street, Del Perro',
      start = { coords = vec3(-961.03, -1197.93, 4.80), radius = 40.0 },   -- patrol entry point, 45 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(-979.50, -1156.47, 2.91, 31.8), rule = 'metered'   , street = 'Prosperity Street' },
        { coords = vec4(-992.38, -1134.06, 1.70, 30.0), rule = 'no_parking', street = 'Prosperity Street' },
        { coords = vec4(-1005.50, -1111.62, 1.73, 29.9), rule = 'permit'    , street = 'Prosperity Street' },
        { coords = vec4(-1018.37, -1089.05, 1.52, 29.7), rule = 'hydrant'   , street = 'Prosperity Street' },
        { coords = vec4(-1031.46, -1066.68, 3.38, 28.7), rule = 'free'      , street = 'Prosperity Street' },
        { coords = vec4(-1044.35, -1043.96, 1.69, 30.3), rule = 'metered'   , street = 'Prosperity Street' },
        { coords = vec4(-1057.37, -1021.55, 1.69, 29.4), rule = 'loading'   , street = 'Prosperity Street' },
        { coords = vec4(-1070.37, -998.99, 1.69, 29.7), rule = 'permit'    , street = 'Prosperity Street' },
        { coords = vec4(-1083.35, -976.58, 3.81, 28.6), rule = 'free'      , street = 'Prosperity Street' },
        { coords = vec4(-1097.21, -954.29, 1.95, 31.8), rule = 'no_parking', street = 'Prosperity Street' },
      },
    },
    {
      label = 'Magellan Avenue, Vespucci',
      start = { coords = vec3(-1301.59, -1119.75, 6.63), radius = 40.0 },   -- patrol entry point, 46 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(-1309.68, -1074.69, 6.49, 29.7), rule = 'metered'   , street = 'Magellan Avenue' },
        { coords = vec4(-1322.42, -1052.08, 6.90, 29.2), rule = 'no_parking', street = 'Magellan Avenue' },
        { coords = vec4(-1335.19, -1029.44, 7.35, 29.2), rule = 'permit'    , street = 'Magellan Avenue' },
        { coords = vec4(-1347.98, -1006.69, 7.82, 30.3), rule = 'hydrant'   , street = 'Magellan Avenue' },
        { coords = vec4(-1361.22, -984.14, 7.88, 32.1), rule = 'free'      , street = 'Magellan Avenue' },
        { coords = vec4(-1375.51, -962.20, 8.73, 34.4), rule = 'metered'   , street = 'Magellan Avenue' },
        { coords = vec4(-1390.11, -940.79, 9.96, 33.3), rule = 'loading'   , street = 'Magellan Avenue' },
        { coords = vec4(-1405.20, -919.13, 10.62, 38.3), rule = 'permit'    , street = 'Magellan Avenue' },
        { coords = vec4(-1426.64, -901.36, 10.55, 64.7), rule = 'free'      , street = 'Magellan Avenue' },
        { coords = vec4(-1450.30, -890.43, 10.33, 65.6), rule = 'no_parking', street = 'Magellan Avenue' },
      },
    },
    {
      label = 'Eclipse Boulevard, West Vinewood',
      start = { coords = vec3(-126.25, 247.25, 96.32), radius = 40.0 },   -- patrol entry point, 45 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(-170.71, 253.87, 92.73, 84.3), rule = 'metered'   , street = 'Eclipse Boulevard' },
        { coords = vec4(-196.35, 257.14, 91.77, 82.5), rule = 'no_parking', street = 'Eclipse Boulevard' },
        { coords = vec4(-219.22, 265.23, 91.56, 64.9), rule = 'permit'    , street = 'Eclipse Boulevard' },
        { coords = vec4(-246.85, 267.74, 91.53, 86.3), rule = 'hydrant'   , street = 'Eclipse Boulevard' },
        { coords = vec4(-273.54, 267.21, 89.60, 94.8), rule = 'free'      , street = 'Eclipse Boulevard' },
        { coords = vec4(-299.92, 263.88, 87.89, 102.0), rule = 'metered'   , street = 'Eclipse Boulevard' },
        { coords = vec4(-325.38, 256.27, 86.29, 109.4), rule = 'loading'   , street = 'Eclipse Boulevard' },
        { coords = vec4(-349.35, 248.68, 84.83, 99.5), rule = 'permit'    , street = 'Eclipse Boulevard' },
        { coords = vec4(-374.61, 245.16, 83.70, 93.6), rule = 'free'      , street = 'Eclipse Boulevard' },
        { coords = vec4(-399.98, 244.78, 82.99, 86.4), rule = 'no_parking', street = 'Eclipse Boulevard' },
      },
    },
    {
      label = 'Marina Drive, Sandy Shores',
      start = { coords = vec3(693.82, 3583.14, 33.04), radius = 40.0 },   -- patrol entry point, 45 m before the first spot
      spots = {   -- 10 kerb spots, 26 m apart on the right-hand kerb, each with its posted rule
        { coords = vec4(648.70, 3580.95, 32.42, 98.0), rule = 'metered'   , street = 'Marina Drive' },
        { coords = vec4(623.25, 3578.34, 32.34, 93.1), rule = 'no_parking', street = 'Marina Drive' },
        { coords = vec4(597.54, 3577.30, 32.59, 90.0), rule = 'permit'    , street = 'Marina Drive' },
        { coords = vec4(571.83, 3577.48, 32.61, 86.7), rule = 'hydrant'   , street = 'Marina Drive' },
        { coords = vec4(545.97, 3578.79, 32.56, 85.5), rule = 'free'      , street = 'Marina Drive' },
        { coords = vec4(520.05, 3580.84, 32.40, 85.5), rule = 'metered'   , street = 'Marina Drive' },
        { coords = vec4(494.47, 3583.64, 32.53, 82.3), rule = 'loading'   , street = 'Marina Drive' },
        { coords = vec4(469.17, 3588.33, 32.84, 79.2), rule = 'permit'    , street = 'Marina Drive' },
        { coords = vec4(444.28, 3594.33, 32.84, 74.5), rule = 'free'      , street = 'Marina Drive' },
        { coords = vec4(419.33, 3601.62, 32.84, 74.5), rule = 'no_parking', street = 'Marina Drive' },
      },
    },
  },

  objectives = {
    {
      block       = 'field_contact',
      label       = 'Check the parked cars',
      minSeconds  = 30,                                   -- five cars at 3 s inspect + 1 s decision at least
      mode        = 'parked',
      cars        = 5,                                    -- a run uses 5 random spots of the district
      spots       = 'spots',
      profileSet  = 'parking',                            -- legal 45 / violation 50 / stolen 5
      returning   = { chance = 0.25, max = 1 },           -- a driver walks up after a citation or impound
      thief       = { chance = 0.5, runAt = 15.0 },       -- on the first inspect of a stolen car
      custody     = 'handover',                           -- the thief goes to the transport van
      escapeFails = false,                                -- the thief escaping costs missed_arrest instead
      escape      = { distance = 400, seconds = 20 },
      bestPoints  = 5,                                    -- correct_disposition +5 per Best decision
      allCorrect  = { id = 'all_correct', points = 10 },  -- all five cars Best
      aliveBonus  = { id = 'subject_alive', points = 15 },-- the thief arrested alive
    },
  },

  scaling   = {},                                   -- solo: nothing scales
  items     = {},
  bonuses   = {
    { id = 'all_correct', points = 10 },            -- every car graded Best
    { id = 'subject_alive', points = 15 },          -- the thief arrested alive
  },
  penalties = {},                                   -- decision penalties and the common penalties apply
})
