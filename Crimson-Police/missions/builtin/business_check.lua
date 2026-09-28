--[[ Crimson-Police · built-in mission
  Business Check · business_check · Patrol · 1 officer · 1 star · 10 min · cooldown 10 min
  Check the front doors of 4 businesses on the beat (ox_target "Check door", 5 s). The server has
  rolled each door secure (75%) or open (25%); an open door adds "Secure door" (5 s). Log each
  result on the tablet: "Secure" or "Found open – secured" (+5 correct / -5 wrong, each).
  Areas: Strawberry & Legion, Morningwood & Rockford Hills, Harmony (Route 68), Paleto Bay, and
  Banham Canyon & Chumash. Door points sit on the pavement at each front door; the heading
  faces out of the building.
  Blocks: interact_points (use = 'random', count = 4, roll + logResult).
  Start: location.start is the FIRST listed door (radius 30 m); interact_points always uses the
  point inside location.start first, then 3 more in the list's circular order.
]]

RegisterMission({
  id           = 'business_check',
  label        = 'Business Check',
  description  = 'Check the front doors of the businesses on your beat. Secure any door you find open and log every result on the tablet.',
  type         = 'patrol',       -- sets points and base payout; there is no payout field
  departments  = {},             -- empty = every department
  minOfficers  = 1,
  maxOfficers  = 1,
  difficulty   = 1,
  timeLimit    = 600,            -- seconds after the start
  startTimeout = 600,            -- seconds to reach the start
  cooldown     = 600,            -- per officer, seconds
  vehiclePenalties = true,       -- heavy vehicle damage is penalised here

  locations = {
    {
      label = 'Strawberry & Legion',
      start = { coords = vec3(27.60, -1351.03, 29.39), radius = 30.0 },  -- 24/7 Supermarket, Innocence Blvd (the first business)
      doors = {                                 -- front doors, heading facing out
        { coords = vec4(27.60, -1351.03, 29.39, 181.66), heading = 181.66, label = '24/7 Supermarket, Innocence Blvd' },
        { coords = vec4(76.20, -1385.60, 29.30, 0.00), heading = 0.00, label = 'Discount Store, Innocence Blvd' },
        { coords = vec4(127.95, -1298.50, 29.30, 210.00), heading = 210.00, label = 'Vanilla Unicorn, Strawberry Ave' },
        { coords = vec4(154.64, -1035.07, 29.35, 339.85), heading = 339.85, label = 'Fleeca Bank, Vespucci Blvd' },
        { coords = vec4(18.88, -1116.63, 29.70, 162.91), heading = 162.91, label = "Ammu-Nation, Adam's Apple Blvd" },
        { coords = vec4(-38.57, -1109.49, 26.43, 160.00), heading = 160.00, label = "Premium Deluxe Motorsport, Adam's Apple Blvd" },
      },
    },
    {
      label = 'Morningwood & Rockford Hills',
      start = { coords = vec3(-1491.14, -383.00, 40.06), radius = 30.0 },  -- Rob's Liquor, Prosperity St (the first business)
      doors = {                                 -- front doors, heading facing out
        { coords = vec4(-1491.14, -383.00, 40.06, 139.51), heading = 139.51, label = "Rob's Liquor, Prosperity St" },
        { coords = vec4(-1448.20, -244.40, 49.60, 198.00), heading = 198.00, label = 'Ponsonbys, Morningwood' },
        { coords = vec4(-1213.55, -323.39, 37.70, 26.86), heading = 26.86, label = 'Fleeca Bank, Boulevard Del Perro' },
        { coords = vec4(-815.00, -191.00, 37.50, 170.00), heading = 170.00, label = 'Bob Mulet Barber, Rockford Hills' },
        { coords = vec4(-1315.25, -390.82, 36.60, 75.03), heading = 75.03, label = 'Ammu-Nation, Morningwood Blvd' },
      },
    },
    {
      label = 'Harmony, Route 68',
      start = { coords = vec3(545.46, 2674.11, 42.05), radius = 30.0 },  -- 24/7 Supermarket, Route 68 (the first business)
      doors = {                                 -- front doors, heading facing out
        { coords = vec4(545.46, 2674.11, 42.05, 10.00), heading = 10.00, label = '24/7 Supermarket, Route 68' },
        { coords = vec4(1165.10, 2703.88, 38.06, 179.43), heading = 179.43, label = "Rob's Liquor, Route 68" },
        { coords = vec4(1172.54, 2699.86, 38.00, 180.00), heading = 180.00, label = 'Fleeca Bank, Route 68' },
        { coords = vec4(1196.80, 2701.50, 38.10, 180.00), heading = 180.00, label = 'Discount Store, Route 68' },
        { coords = vec4(1175.00, 2645.50, 37.75, 0.00), heading = 0.00, label = 'Los Santos Customs, Harmony' },
      },
    },
    {
      label = 'Paleto Bay',
      start = { coords = vec3(-111.30, 6462.30, 31.55), radius = 30.0 },  -- Blaine County Savings Bank, Paleto Bay (the first business)
      doors = {                                 -- front doors, heading facing out
        { coords = vec4(-111.30, 6462.30, 31.55, 135.00), heading = 135.00, label = 'Blaine County Savings Bank, Paleto Bay' },
        { coords = vec4(10.10, 6506.40, 31.60, 225.00), heading = 225.00, label = 'Discount Store, Paleto Bay' },
        { coords = vec4(114.95, 6622.43, 31.70, 225.00), heading = 225.00, label = "Beeker's Garage, Paleto Bay" },
        { coords = vec4(-323.33, 6076.51, 31.35, 228.02), heading = 228.02, label = 'Ammu-Nation, Paleto Bay' },
        { coords = vec4(-272.10, 6222.20, 31.50, 225.00), heading = 225.00, label = 'Herr Kutz Barber, Paleto Bay' },
      },
    },
    {
      label = 'Banham Canyon & Chumash',
      start = { coords = vec3(-2973.38, 391.73, 14.94), radius = 30.0 },  -- Rob's Liquor, Great Ocean Hwy (the first business)
      doors = {                                 -- front doors, heading facing out
        { coords = vec4(-2973.38, 391.73, 14.94, 87.48), heading = 87.48, label = "Rob's Liquor, Great Ocean Hwy" },
        { coords = vec4(-2969.39, 485.78, 15.60, 87.30), heading = 87.30, label = 'Fleeca Bank, Great Ocean Hwy' },
        { coords = vec4(-3036.43, 588.06, 7.80, 285.00), heading = 285.00, label = '24/7 Supermarket, Ineseno Rd' },
        { coords = vec4(-3237.90, 1003.34, 12.73, 268.00), heading = 268.00, label = '24/7 Supermarket, Barbareno Rd' },
        { coords = vec4(-3163.20, 1043.20, 20.76, 270.00), heading = 270.00, label = 'Suburban, Chumash Plaza' },
        { coords = vec4(-3163.05, 1082.88, 20.74, 246.08), heading = 246.08, label = 'Ammu-Nation, Chumash Plaza' },
      },
    },
  },

  objectives = {
    {
      block      = 'interact_points',
      label      = 'Check the business doors',
      minSeconds = 60,                       -- 4 doors of 5 s each plus the drives between them
      points     = 'doors',
      use        = 'random',
      count      = 4,
      target     = { label = 'Check door', icon = 'fa-solid fa-door-closed', radius = 1.5 },
      progress   = { label = 'Checking the door', duration = 5000, anim = 'search' },
      roll       = { outcomes = {
        { id = 'secure', chance = 0.75 },
        { id = 'open',   chance = 0.25, followUp = { label = 'Secure door', duration = 5000 } },
      } },
      logResult  = { choices = { 'secure', 'found_open' }, correct = { secure = 'secure', open = 'found_open' } },
    },
  },

  scaling   = {},
  items     = {},
  bonuses   = {
    { id = 'correct_log', points = 5, each = true },     -- each correctly logged result
  },
  penalties = {
    { id = 'wrong_log', points = -5, each = true },      -- each wrongly logged result
  },
})
