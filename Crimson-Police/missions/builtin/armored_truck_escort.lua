--[[ Crimson-Police · built-in mission: Armored Truck Escort (armored_truck_escort)
  Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  An armored truck (stockade) with an NPC driver follows a road route from its depot at 60 km/h, keeping to
  its lanes. 2 ambush waves (scale) of 2 cars each (scale), 2 armed attackers per car, hit it at random
  ambush points. Escort it, neutralise each wave, and see it reach the destination with no attacker
  within 100 m.
  Locations (3 road routes, stored as road waypoints the way the Mission Builder records them: one at every
  junction or turn and at least one every 150 m; the last waypoint is the destination):
    · Boulevard Del Perro → Hawick Avenue, Morningwood to Alta via Burton (stop at the Burton branch)
    · Route 68 through Harmony to the Route 68 Fleeca
    · Great Ocean Highway, Banham Canyon to Chumash
  Blocks: escort.
]]

RegisterMission({
  id           = 'armored_truck_escort',
  label        = 'Armored Truck Escort',
  description  = 'An armored cash truck is leaving the depot. Escort it along its route, fight off the ambush crews and see it safely to its destination.',
  type         = 'tactical',      -- sets points and base payout; there is no payout field
  departments  = {},              -- empty = every department
  minOfficers  = 2,
  maxOfficers  = 4,
  difficulty   = 3,
  timeLimit    = 720,             -- seconds after the start
  startTimeout = 600,             -- seconds to reach the start
  cooldown     = 1200,            -- per officer, seconds
  vehiclePenalties = false,       -- ramming ambush cars is expected, so no heavy-damage penalty

  locations = {
    {
      label        = 'Boulevard Del Perro to Hawick Avenue (Morningwood to Alta)',
      start        = { coords = vec3(-1456.06, -391.58, 38.80), radius = 50.0 },   -- the depot: the truck leaves when the first participant arrives
      route        = {   -- 1.87 km, 16 road waypoints (last = destination)
        points = {
          vec3(-1456.06, -391.58, 38.80), vec3(-1337.07, -353.29, 37.89), vec3(-1218.08, -314.99, 36.98),
          vec3(-1093.44, -274.88, 38.59), vec3(-968.79, -234.76, 40.20), vec3(-844.15, -194.65, 41.81),
          vec3(-719.51, -154.53, 43.41), vec3(-594.87, -114.42, 45.02), vec3(-470.23, -74.30, 46.63),
          vec3(-345.59, -34.19, 48.24), vec3(-226.50, -75.25, 49.66), vec3(-107.40, -116.31, 51.07),
          vec3(11.69, -157.38, 52.48), vec3(130.78, -198.44, 53.90), vec3(225.64, -231.15, 53.63),
          vec3(320.49, -263.85, 53.36),
        },
        stops  = { { at = 10, wait = 20 } },   -- waypoint index, seconds the truck waits there
      },
      ambushPoints = {   -- 7 ambush points on the route, 150 m+ apart
        vec3(-1094.33, -275.17, 38.58), vec3(-922.98, -220.02, 40.79),
        vec3(-751.64, -164.87, 43.00), vec3(-580.30, -109.73, 45.21),
        vec3(-191.08, -87.46, 50.08), vec3(-11.46, -149.40, 52.21),
        vec3(158.71, -208.07, 53.82),
      },
    },
    {
      label        = 'Route 68, Harmony to the Route 68 Fleeca',
      start        = { coords = vec3(300.00, 2689.30, 41.40), radius = 50.0 },   -- the depot: the truck leaves when the first participant arrives
      route        = {   -- 0.87 km, 8 road waypoints (last = destination)
        points = {
          vec3(300.00, 2689.30, 41.40), vec3(423.10, 2688.95, 41.35), vec3(546.19, 2688.61, 41.30),
          vec3(671.82, 2688.93, 40.52), vec3(797.45, 2689.25, 39.74), vec3(923.08, 2689.57, 38.95),
          vec3(1048.71, 2689.89, 38.17), vec3(1174.34, 2690.21, 37.39),
        },
        stops  = {},
      },
      ambushPoints = {   -- 5 ambush points on the route, 150 m+ apart
        vec3(450.00, 2688.88, 41.34), vec3(610.00, 2688.77, 40.90),
        vec3(770.00, 2689.18, 39.91), vec3(930.00, 2689.58, 38.91),
        vec3(1090.00, 2689.99, 37.91),
      },
    },
    {
      label        = 'Great Ocean Highway, Banham Canyon to Chumash',
      start        = { coords = vec3(-2988.00, 345.00, 14.20), radius = 50.0 },   -- the depot: the truck leaves when the first participant arrives
      route        = {   -- 0.86 km, 10 road waypoints (last = destination)
        points = {
          vec3(-2988.00, 345.00, 14.20), vec3(-2985.00, 391.00, 14.40), vec3(-2979.04, 485.02, 14.80),
          vec3(-2988.00, 600.00, 15.20), vec3(-3010.00, 720.00, 15.90), vec3(-3043.00, 840.00, 16.80),
          vec3(-3082.00, 945.00, 17.90), vec3(-3118.00, 1035.00, 19.20), vec3(-3145.00, 1110.00, 20.00),
          vec3(-3166.00, 1180.00, 20.70),
        },
        stops  = {},
      },
      ambushPoints = {   -- 5 ambush points on the route, 150 m+ apart
        vec3(-2981.34, 514.62, 14.90), vec3(-3001.41, 673.15, 15.63),
        vec3(-3039.79, 828.34, 16.71), vec3(-3095.33, 978.33, 18.38),
        vec3(-3150.53, 1128.44, 20.18),
      },
    },
  },

  objectives = {
    {
      block        = 'escort',
      label        = 'Escort the armored truck',
      minSeconds   = 45,
      route        = 'route',
      vehicle      = 'stockade',
      speed        = 60,                                         -- km/h
      style        = 'normal',                                   -- always keeps to its lanes
      toughness    = 1.5,                                        -- x vehicle health
      stoppedFail  = 60,                                         -- fails when stopped this long (stops excluded)
      arrival      = 20.0,
      ambushPoints = 'ambushPoints',
      ambush       = {
        waves       = 2,                                         -- base counts, scaled by tier
        carsPerWave = 2,
        perCar      = 2,                                         -- armed attackers per car (does not scale)
        models      = { 'sultan', 'buffalo', 'kuruma' },
        weapons     = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG' },
        accuracy    = 25,                                        -- plus the tier's accuracy
        armour      = 0,                                         -- plus the tier's armour
      },
      clearRadius  = 100.0,                                      -- no attacker this close at the destination
    },
  },

  scaling   = {                                -- ambush waves and cars per wave
    { path = 'objectives.1.ambush.waves', max = 5 },
    { path = 'objectives.1.ambush.carsPerWave', max = 5 },
  },
  items     = {},                              -- no items for this mission
  bonuses   = {
    { id = 'truck_healthy', pctOfPoints = 0.10 },          -- the truck arrives above 50% health
    { id = 'no_participant_downed', pctOfPoints = 0.10 },
  },
  penalties = {},                              -- the common penalties always apply
})
