--[[ Crimson-Police · built-in mission: Armored Truck Escort (armored_truck_escort)
  Tactical · 2–4 officers · ★★★ · time limit 12 min · cooldown 20 min
  An armored truck (stockade) with an NPC driver follows a road route from its depot at 60 km/h, keeping to
  its lanes. 2 ambush waves (scale) of 2 cars each (scale), 2 armed attackers per car, hit it at random
  ambush points. Escort it, neutralise each wave, and see it reach the destination with no attacker
  within 100 m.
  Locations (3 road routes, stored as the Mission Builder's route recorder stores them: road waypoints on
  the GTA V vehicle-node network, following connected roads in their legal direction, one at every turn and
  at least one every 100 m; z is the node's road height; the first waypoint is the depot = the start, the
  last one is the destination):
    · Boulevard Del Perro → Hawick Avenue, Morningwood to Alta (1.8 km): from the eastbound carriageway in
      Morningwood past the Boulevard Del Perro Fleeca, a 20 s stop in front of the Burton Fleeca, to the
      Alta Fleeca on Hawick Avenue
    · Route 68 from west of Harmony past the Joshua Rd junction to the Route 68 Fleeca (1.2 km)
    · Great Ocean Highway from Banham Canyon past Rob's Liquor and the Fleeca, then Barbareno Road into
      Chumash (1.2 km)
  Ambush points are road nodes of the route on straight stretches of two-lane road, 150 m+ apart, the
  first 250 m+ from the depot; each is a vec4 whose heading is the truck's direction of travel, so the
  block lines the ambush cars (up to 5, 7 m apart, 4.5 m either side of the centre line) up on the road.
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
      start        = { coords = vec3(-1352.25, -380.75, 35.75), radius = 50.0 },   -- the depot (Boulevard Del Perro, Morningwood): the truck leaves when the first participant arrives
      -- 25 road waypoints, 1821 m: Boulevard Del Perro > Hawick Ave; destination = the last one (Hawick Ave, in front of the Alta Fleeca)
      route        = {
        points = {
          vec3(-1352.25, -380.75, 35.75),
          vec3(-1267.50, -337.50, 35.84),
          vec3(-1189.00, -294.75, 36.84),
          vec3(-1113.50, -246.25, 36.78),
          vec3(-1034.75, -194.25, 36.84),
          vec3(-948.50, -157.75, 36.75),
          vec3(-882.50, -115.00, 36.94),
          vec3(-806.75, -78.00, 36.81),
          vec3(-724.50, -41.50, 36.81),
          vec3(-711.50, -28.50, 36.88),
          vec3(-672.25, -18.75, 37.53),
          vec3(-652.25, -11.50, 39.00),
          vec3(-555.25, 2.75, 43.34),
          vec3(-465.75, -5.00, 44.62),
          vec3(-375.00, -5.25, 46.06),
          vec3(-339.00, -18.25, 46.69),
          vec3(-255.25, -47.00, 48.53),
          vec3(-183.00, -80.75, 51.38),
          vec3(-96.25, -104.25, 56.84),
          vec3(-5.75, -133.00, 55.62),
          vec3(5.25, -144.00, 55.34),
          vec3(86.50, -177.50, 54.00),
          vec3(175.50, -209.75, 53.16),
          vec3(261.00, -232.25, 53.03),
          vec3(325.75, -257.75, 52.94),
        },
        stops  = { { at = 16, wait = 20 } },   -- waypoint 16: the Burton Fleeca on Hawick Ave
      },
      ambushPoints = {   -- 6 road nodes of the route, 150 m+ apart; heading = the truck's direction of travel
        vec4(-928.50, -144.75, 36.75, 300.7),
        vec4(-652.25, -11.50, 39.00, 285.0),
        vec4(-477.75, -4.25, 44.41, 266.2),
        vec4(-312.50, -27.50, 47.41, 250.5),
        vec4(-160.50, -88.75, 53.00, 250.4),
        vec4(100.75, -182.75, 53.84, 250.2),
      },
    },
    {
      label        = 'Route 68, Harmony to the Route 68 Fleeca',
      start        = { coords = vec3(57.50, 2744.25, 55.94), radius = 50.0 },   -- the depot (Route 68, west of Harmony): the truck leaves when the first participant arrives
      -- 14 road waypoints, 1158 m: Route 68; destination = the last one (Route 68, in front of the Route 68 Fleeca)
      route        = {
        points = {
          vec3(57.50, 2744.25, 55.94),
          vec3(125.00, 2676.50, 50.25),
          vec3(206.25, 2628.25, 46.66),
          vec3(297.50, 2639.50, 43.69),
          vec3(377.25, 2662.50, 43.66),
          vec3(469.25, 2678.75, 42.38),
          vec3(558.50, 2690.50, 41.19),
          vec3(654.00, 2699.75, 39.84),
          vec3(749.75, 2700.00, 39.16),
          vec3(833.75, 2698.75, 39.56),
          vec3(927.75, 2695.75, 39.66),
          vec3(1024.50, 2690.75, 38.50),
          vec3(1107.50, 2686.00, 37.62),
          vec3(1167.25, 2683.25, 37.03),
        },
        stops  = {},
      },
      ambushPoints = {   -- 5 road nodes of the route, 150 m+ apart; heading = the truck's direction of travel
        vec4(297.50, 2639.50, 43.69, 287.9),
        vec4(469.25, 2678.75, 42.38, 278.0),
        vec4(642.00, 2699.25, 39.94, 273.0),
        vec4(809.75, 2699.25, 39.34, 269.1),
        vec4(986.50, 2693.00, 38.88, 266.9),
      },
    },
    {
      label        = 'Great Ocean Highway, Banham Canyon to Chumash',
      start        = { coords = vec3(-3013.50, 152.25, 14.38), radius = 50.0 },   -- the depot (Great Ocean Hwy, Banham Canyon): the truck leaves when the first participant arrives
      -- 18 road waypoints, 1206 m: Great Ocean Hwy > Barbareno Rd; destination = the last one (Barbareno Rd, Chumash)
      route        = {
        points = {
          vec3(-3013.50, 152.25, 14.38),
          vec3(-3030.50, 226.25, 15.09),
          vec3(-3010.50, 311.50, 13.78),
          vec3(-2992.50, 399.25, 13.88),
          vec3(-2986.25, 494.00, 14.28),
          vec3(-2993.75, 578.50, 17.50),
          vec3(-3014.50, 665.75, 21.22),
          vec3(-3062.50, 744.25, 20.56),
          vec3(-3121.25, 823.75, 16.06),
          vec3(-3154.50, 913.25, 13.38),
          vec3(-3173.00, 911.00, 13.44),
          vec3(-3196.00, 912.75, 13.41),
          vec3(-3210.00, 920.50, 13.16),
          vec3(-3219.75, 933.50, 12.84),
          vec3(-3229.00, 1020.75, 10.94),
          vec3(-3206.00, 1116.25, 9.19),
          vec3(-3181.00, 1206.25, 8.66),
          vec3(-3175.50, 1249.50, 10.12),
        },
        stops  = {},
      },
      ambushPoints = {   -- 5 road nodes of the route, 150 m+ apart; heading = the truck's direction of travel
        vec4(-2992.50, 399.25, 13.88, 354.1),
        vec4(-2991.00, 560.50, 16.66, 8.0),
        vec4(-3038.25, 714.00, 21.78, 36.6),
        vec4(-3135.50, 850.25, 14.88, 25.1),
        vec4(-3229.50, 971.50, 11.97, 5.8),
      },
    },
  },

  objectives = {
    {
      block        = 'escort',
      label        = 'Escort the armored truck',
      minSeconds   = 45,                                         -- the shortest route (1.2 km) takes ~70 s at 60 km/h
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
