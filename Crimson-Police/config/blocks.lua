-- Mission Builder ranges and defaults.

Config.Blocks = {
    details = {                   -- the Details step, for every mission
        difficulty = { 1, 3, 2 },               -- stars
        officers = { 1, 4 },                    -- min and max officers the builder may set
        timeLimit = { 120, 1200, 600 },
        startTimeout = { 300, 900, 600 },
        cooldown = { 300, 3600, 1200 },
        vehiclePenalties = { default = true },  -- false turns off the heavy vehicle-damage penalty
    },

    escort = {
        vehicle = 'stockade',              -- default pick from Config.Builder.allowed.escortVehicles
        speed = { 20, 120, 60 },
        style = { options = { 'careful', 'normal', 'fast' }, default = 'normal' },  -- always lane-following
        toughness = { 0.5, 3.0, 1.5 },                                              -- × vehicle health
        stoppedFail = { 15, 120, 60 },
        arrival = { 10, 50, 20 },
        stops = { 0, 5, 0 },               -- stop points added with E while recording
        stopWait = { 10, 60, 20 },         -- seconds at each stop; never counts toward stoppedFail
        ambushPoints = { 1, 10, 5 },
        ambushGap = 150.0,                 -- minimum metres between ambush points
        ambushWaves = { 1, 5, 2 },
        carsPerWave = { 1, 5, 2 },
        perCar = { 1, 4, 2 },              -- attackers per car; weapons, accuracy and armour as hostile_waves
        presenceRange = { 50, 800, 300 },  -- from the escorted vehicle
    },

    checkpoint_route = {
        checkpoints = { 2, 20 },
        use = { options = { 'all', 'random' }, default = 'all' },
        radius = { 3, 20, 10 },
        stopFor = { 0, 30, 10 },
        vehicleRequired = { default = true },  -- a checkpoint only counts while driving a vehicle (any vehicle)
        medals = { default = false },          -- when on: Gold, Silver and Bronze times in seconds
        contactPenalty = { 0, 10, 2 },         -- seconds added per hit
        presenceRange = { 50, 800, 300 },      -- from the next checkpoint or the nearest partner, whichever is closer
    },

    protect_rescue = {
        npcs = { 1, 6, 3 },
        peds = { 'a_m_m_business_01', 'a_f_y_business_01' },
        restrained = { default = true },
        freeTime = { 1, 15, 6 },
        hitPenalty = { 0, 100, 50 },
        failIfDies = { default = true },
        presenceRange = { 50, 800, 150 }, -- from the nearest NPC being protected
    },

    search_area = {
        startRadius = { 200, 1000, 600 },
        clues = { 1, 5, 3 },
        shrinkTo = { 300, 150, 50 },       -- circle radius after each clue
        fugitives = { 1, 5, 1 },
        runDistance = { 10, 60, 30 },
        presenceRange = { 50, 800, 100 },  -- margin outside the current search circle (inside always counts)
    },
}

-- The blocks below are assigned after the table: field_contact and process_scene are new, the others
-- carry the settings the police actions, raids and tactical variants added.

Config.Blocks.field_contact = {
    mode = { options = { 'parked', 'scene', 'stop' }, default = 'scene' },
    people = { 1, 4, 1 },               -- scene mode; stop mode takes them from the stop; parked has none
    cars = { 0, 6, 1 },                 -- parked: cars to check; scene: 0 or 1
    -- truths from Config.Custody.profileSets
    profileSet = { options = { 'scene', 'traffic', 'parking', 'stolenCar' }, default = 'scene' },
    approach = { 10, 40, 25 },          -- metres: people react when the first participant is this close
    probableCause = { default = true }, -- a vehicle search needs probable cause or consent
    custody = { options = { 'cuff', 'handover' }, default = 'handover' },
    returning = { 0, 100, 25 },         -- parked: chance a driver comes back (at most once per run)
    escapeFails = { default = true },   -- off: an escape costs missed_arrest instead of failing
    bestPoints = { 0, 20, 10 },         -- correct_disposition points per Best decision
    minSpots = 5,                       -- parked: kerb spots per location (scene: 3 person spots)
    presenceRange = { 50, 800, 150 },   -- from the nearest contact not yet decided
}

Config.Blocks.process_scene = {
    bodies = { 0, 8, 4 },               -- bodies kept (the latest ones)
    tagTime = { 2, 15, 5 },             -- seconds: Photograph & tag
    bagTime = { 2, 15, 6 },             -- seconds: Bag body
    releaseTime = { 2, 15, 8 },         -- seconds: Release to coroner
    coroner = { default = true },       -- a coroner van collects the bags; off = release at the scene marker
    presenceRange = { 50, 800, 150 },   -- from the nearest body or the scene marker
}

Config.Blocks.pursuit = {
    mode = { options = { 'follow', 'stop' }, default = 'stop' },
    vehicles = { 1, 5, 1 },
    route = { options = { 'free', 'recorded' }, default = 'free' },
    speed = { 40, 160, 120 },
    style = { options = { 'cautious', 'reckless' }, default = 'reckless' },
    suspects = { 1, 4, 1 },             -- per vehicle
    footFlee = { 0, 100, 20 },          -- chance to flee on foot after the stop
    holdDistance = { 50, 300, 150 },    -- Follow mode
    lostDistance = { 150, 600, 250 },
    lostSeconds = { 5, 30, 10 },
    duration = { 60, 600, 180 },
    presenceRange = { 50, 800, 400 },   -- from the nearest suspect vehicle, or suspect on foot
    -- rolled when the lights trigger fires; must add up to 100
    responses = { yield = 0, flee = 100, fight = 0 },
    -- contact: the next field_contact objective works the stopped car and its people
    handoff = { options = { 'arrest', 'contact' }, default = 'arrest' },
    observe = { options = { 'off', 'pace', 'follow' }, default = 'off' },
    zoneSpeed = { 50, 130, 80 },        -- km/h: posted speed for observe = pace
    overMin = { 10, 60, 20 },           -- km/h over the posted speed: rolled between overMin...
    overMax = { 10, 60, 45 },           -- ...and overMax
    driveBy = { 0, 100, 0 },            -- chance armed passengers shoot from the car (participants only)
    ram = { 0, 100, 0 },                -- chance a boxed-in driver rams once
    -- metres along the route from the nearest participant or the observation point: negative = upstream,
    -- so the car drives past the officer; 0 = off. Kept within 250 m so a player is always in range
    spawnOffset = { -250, 250, 0 },
    paceTolerance = { 0, 10, 5 },       -- km/h: the median of the pace samples may be this far under the limit
}

Config.Blocks.interact_points = {
    points = { 1, 10 },
    use = { options = { 'all', 'random' }, default = 'all' },
    progress = { 1, 30, 5 },
    label = 'Checking…',
    animation = 'clipboard',            -- default pick from Config.Builder.allowed.animations
    logResult = { default = false },
    logChoices = { 2, 4, 2 },
    presenceRange = { 50, 800, 150 },   -- from the nearest point not yet done
    together = { 1, 4, 1 },             -- different officers who must finish points within the window (1 = off)
    togetherWindow = { 3, 15, 6 },      -- seconds
    soloProgress = { 3, 20, 8 },        -- seconds per point when together can't be met (one participant left)
    hiddenKind = { options = { 'device', 'seize' }, default = 'device' },
    finds = { 0, 100, 0 },              -- chance a plain point yields evidence
}

Config.Blocks.skill_check = {
    checks = { 1, 8, 4 },
    difficulty = { options = { 'easy', 'medium', 'hard' }, default = { 'easy', 'medium', 'medium', 'hard' } },
    missPenalty = { 0, 120, 30 },       -- seconds off the timer
    failAfter = { 1, 3, 2 },            -- misses in a row
    presenceRange = { 50, 800, 150 },   -- from the device or point being worked on
    -- what failAfter misses do: 'fail' the case (as today) or a 'setback' (a recovery step, then a retry)
    onFail = { options = { 'fail', 'setback' }, default = 'fail' },
    setbackTime = { 5, 30, 10 },        -- seconds: the recovery step (e.g. Ventilate)
    retryAfter = { 10, 120, 30 },       -- seconds before the checks can be tried again
}

Config.Blocks.flee_arrest = {
    suspects = { 1, 10, 1 },
    responses = { surrender = 50, flee = 30, fight = 20 },  -- must add up to 100
    armedChance = { 0, 100, 20 },
    weapons = { 'WEAPON_PISTOL' },
    escapeDistance = { 200, 800, 400 },
    escapeSeconds = { 10, 60, 20 },
    givesUp = { options = { 'aim', 'stun', 'close' }, default = { 'aim', 'stun', 'close' } },
    aimDistance = { 5, 15, 10 },                            -- gives up when aimed at within this distance,
    closeDistance = 3.0,                                    -- ...or when a participant stays this close...
    closeSeconds = 3,                                       -- ...for this long (or when stunned)
    presenceRange = { 50, 800, 250 },                       -- from the nearest suspect not yet cuffed
    demeanour = {
        options = { 'rolled', 'compliant', 'nervous', 'evasive', 'runner', 'hostile' },
        default = 'rolled',                                 -- rolled: Config.Custody.demeanour
    },
    feint = { 0, 50, 0 },                                   -- chance a surrendered unarmed suspect bolts
    custody = { options = { 'cuff', 'handover' }, default = 'cuff' },
}

Config.Blocks.hostile_waves = {
    waves = { 1, 6, 3 },
    perWave = { 1, 15, 7 },                            -- every armed NPC in the mission together: at most Config.Builder.maxHostiles
    nextWaveAlive = { 0, 5, 2 },                       -- next wave when this many or fewer are alive...
    nextWaveAfter = { 30, 300, 90 },                   -- ...or after this long
    weapons = { 'WEAPON_PISTOL', 'WEAPON_MICROSMG' },  -- default pick from Config.Builder.allowed.weapons
    accuracy = { 5, 60, 25 },
    armour = { 0, 100, 0 },
    health = { 100, 400, 200 },                        -- also the range for the boss
    behaviour = { options = { 'hold', 'balanced', 'push' }, default = 'balanced' },
    surrender = { 0, 100, 30 },                        -- chance to surrender under 25% health
    peds = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01' },
    boss = { default = false },                        -- when on: model, health, armour and weapon from the ranges above
    blockTraffic = { 0, 200, 120 },
    spawnPointsPerHostile = 1.5,                       -- spawn points needed per hostile in the largest wave
    presenceRange = { 50, 800, 150 },                  -- from the nearest living hostile
    behaviourRoll = { default = false },               -- on: behaviour weights rolled per run instead of one behaviour
    spawnSets = { 0, 4, 0 },                           -- named spawn sets per location (0 = off)
    spawnSetsUsed = { 1, 3, 2 },                       -- sets used per run, shown as the intel line
}
