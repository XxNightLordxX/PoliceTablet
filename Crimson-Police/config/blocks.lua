-- config/blocks.lua · Mission Builder ranges and defaults.
-- Numbers are { min, max, default }; the tablet only accepts values in range,
-- and the server checks them again on publish and on /CrimsonPoliceAdmin reload.
-- Times are seconds, distances metres, speeds km/h, chances percent. When the builder
-- writes a mission file it converts chances to fractions (30 → 0.30) and progress
-- times to milliseconds (5 → 5000), the units mission files use.
Config.Blocks = {
  details = {                     -- the Details step, for every mission
    difficulty   = { 1, 3, 2 },   -- stars
    officers     = { 1, 4 },      -- min and max officers the builder may set
    timeLimit    = { 120, 1200, 600 },
    startTimeout = { 300, 900, 600 },
    cooldown     = { 300, 3600, 1200 },
    vehiclePenalties = { default = true },  -- false turns off the heavy vehicle-damage penalty
  },

  hostile_waves = {
    waves         = { 1, 6, 3 },
    perWave       = { 1, 15, 7 },          -- every armed NPC in the mission together: at most Config.Builder.maxHostiles
    nextWaveAlive = { 0, 5, 2 },           -- next wave when this many or fewer are alive...
    nextWaveAfter = { 30, 300, 90 },       -- ...or after this long
    weapons       = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },   -- default pick from Config.Builder.allowed.weapons
    accuracy      = { 5, 60, 25 },
    armour        = { 0, 100, 0 },
    health        = { 100, 400, 200 },     -- also the range for the boss
    behaviour     = { options = { 'hold', 'balanced', 'push' }, default = 'balanced' },
    surrender     = { 0, 100, 30 },        -- chance to surrender under 25% health
    peds          = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01' },
    boss          = { default = false },   -- when on: model, health, armour and weapon from the ranges above
    blockTraffic  = { 0, 200, 120 },
    spawnPointsPerHostile = 1.5,           -- spawn points needed per hostile in the largest wave
    presenceRange = { 50, 800, 150 },      -- from the nearest living hostile
  },

  escort = {
    vehicle      = 'stockade',             -- default pick from Config.Builder.allowed.escortVehicles
    speed        = { 20, 120, 60 },
    style        = { options = { 'careful', 'normal', 'fast' }, default = 'normal' },  -- always lane-following
    toughness    = { 0.5, 3.0, 1.5 },      -- × vehicle health
    stoppedFail  = { 15, 120, 60 },
    arrival      = { 10, 50, 20 },
    stops        = { 0, 5, 0 },            -- stop points added with E while recording
    stopWait     = { 10, 60, 20 },         -- seconds at each stop; never counts toward stoppedFail
    ambushPoints = { 1, 10, 5 },
    ambushGap    = 150.0,                  -- minimum metres between ambush points
    ambushWaves  = { 1, 5, 2 },
    carsPerWave  = { 1, 5, 2 },
    perCar       = { 1, 4, 2 },            -- attackers per car; weapons, accuracy and armour as hostile_waves
    presenceRange = { 50, 800, 300 },      -- from the escorted vehicle
  },

  pursuit = {
    mode         = { options = { 'follow', 'stop' }, default = 'stop' },
    vehicles     = { 1, 5, 1 },
    route        = { options = { 'free', 'recorded' }, default = 'free' },
    speed        = { 40, 160, 120 },
    style        = { options = { 'cautious', 'reckless' }, default = 'reckless' },
    suspects     = { 1, 4, 1 },            -- per vehicle
    footFlee     = { 0, 100, 20 },         -- chance to flee on foot after the stop
    holdDistance = { 50, 300, 150 },       -- Follow mode
    lostDistance = { 150, 600, 250 },
    lostSeconds  = { 5, 30, 10 },
    duration     = { 60, 600, 180 },
    presenceRange = { 50, 800, 400 },      -- from the nearest suspect vehicle, or suspect on foot
  },

  checkpoint_route = {
    checkpoints    = { 2, 20 },
    use            = { options = { 'all', 'random' }, default = 'all' },
    radius         = { 3, 20, 10 },
    stopFor        = { 0, 30, 10 },
    policeVehicle  = { default = true },   -- uses Config.PoliceVehicles
    medals         = { default = false },  -- when on: Gold, Silver and Bronze times in seconds
    contactPenalty = { 0, 10, 2 },         -- seconds added per hit
    presenceRange  = { 50, 800, 300 },     -- from the next checkpoint or the nearest partner, whichever is closer
  },

  interact_points = {
    points     = { 1, 10 },
    use        = { options = { 'all', 'random' }, default = 'all' },
    progress   = { 1, 30, 5 },
    label      = 'Checking…',
    animation  = 'clipboard',              -- default pick from Config.Builder.allowed.animations
    logResult  = { default = false },
    logChoices = { 2, 4, 2 },
    presenceRange = { 50, 800, 150 },   -- from the nearest point not yet done
  },

  skill_check = {
    checks      = { 1, 8, 4 },
    difficulty  = { options = { 'easy', 'medium', 'hard' }, default = { 'easy', 'medium', 'medium', 'hard' } },
    missPenalty = { 0, 120, 30 },          -- seconds off the timer
    failAfter   = { 1, 3, 2 },             -- misses in a row
    presenceRange = { 50, 800, 150 },      -- from the device or point being worked on
  },

  protect_rescue = {
    npcs       = { 1, 6, 3 },
    peds       = { 'a_m_m_business_01', 'a_f_y_business_01' },
    restrained = { default = true },
    freeTime   = { 1, 15, 6 },
    hitPenalty = { 0, 100, 50 },
    failIfDies = { default = true },
    presenceRange = { 50, 800, 150 },   -- from the nearest NPC being protected
  },

  flee_arrest = {
    suspects       = { 1, 10, 1 },
    responses      = { surrender = 50, flee = 30, fight = 20 },   -- must add up to 100
    armedChance    = { 0, 100, 20 },
    weapons        = { 'WEAPON_PISTOL' },
    escapeDistance = { 200, 800, 400 },
    escapeSeconds  = { 10, 60, 20 },
    givesUp        = { options = { 'aim', 'stun', 'close' }, default = { 'aim', 'stun', 'close' } },
    aimDistance    = { 5, 15, 10 },        -- gives up when aimed at within this distance,
    closeDistance  = 3.0,                  -- ...or when a participant stays this close...
    closeSeconds   = 3,                    -- ...for this long (or when stunned)
    presenceRange  = { 50, 800, 250 },     -- from the nearest suspect not yet cuffed
  },

  search_area = {
    startRadius = { 200, 1000, 600 },
    clues       = { 1, 5, 3 },
    shrinkTo    = { 300, 150, 50 },        -- circle radius after each clue
    fugitives   = { 1, 5, 1 },
    runDistance = { 10, 60, 30 },
    presenceRange = { 50, 800, 100 },      -- margin outside the current search circle (inside always counts)
  },
}
