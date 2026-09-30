-- Every Crimson-Police setting. If this file and the spec disagree, this file wins.

Config = {}

Config.Debug = false             -- true = each module prints tagged debug lines
Config.Locale = 'en'

-- ============================================================================
--                                   STORAGE
-- ============================================================================
-- enabled = true:  keep everything in your MySQL/MariaDB database through oxmysql. The tables are
--                  created automatically on start; there is no SQL file to import.
-- enabled = false: database off. Everything is saved as files in the resource's saves folder
--                  (Crimson-Police/saves). Keep that folder when you update the resource, and back it up.
-- Changing this moves no data: Crimson-Police starts with what the other storage holds (nothing, the
-- first time). To take your data along, use /CrimsonPoliceAdmin storage copy (see the README).
-- folder only matters when enabled = false: a folder inside the Crimson-Police folder (FXServer only lets
-- a resource write inside resource folders). A full path works when it points inside the resource.
Config.Database = {
    enabled = true,
    folder = 'saves',
}

-- ============================================================================
--                                   FORMATS
-- ============================================================================

Config.Format = {
    currency = '$',              -- money symbol
    currencyAfter = false,       -- true = "250 $"
}

-- ============================================================================
--                             TABLET AND COMMANDS
-- ============================================================================

Config.Tablet = {
    title = 'Crimson-Police',            -- app title on every screen
    command = 'CrimsonPolice',           -- opens the Officer UI
    adminCommand = 'CrimsonPoliceAdmin', -- opens the Admin UI; also takes subcommands
    keybind = '',                        -- default key ('' = none; players can bind it in GTA settings)
    dispatchKey = '',                    -- default key that opens the tablet on Dispatch ('' = none)
    readyKey = '',                       -- default key that answers a unit ready check with Ready ('' = none)
    -- default key for contact HUD actions: run plate from a vehicle, place in vehicle, hand over, escort
    contactKey = '',
    item = false,                        -- ox_inventory item name that also opens the tablet, or false
    prop = 'prop_cs_tablet',             -- prop held while the Officer UI is open
    access = {                           -- which ways open the Officer UI; the server refuses a way that is off
        command = true,                  -- /CrimsonPolice
        keybind = true,                  -- the crimsonpolice_tablet key mapping
        item = true,                     -- using Config.Tablet.item (only when item is set)
        desk = true,                     -- the mission desks below
        requireItem = false,             -- true = every way except a desk needs the item in the inventory
    },
    deskDistance = 3.0,                  -- metres: walking further than this from the desk closes the tablet
    deskScenario = 'PROP_HUMAN_ATM',     -- standing-and-typing animation at a desk (no handheld tablet)
    -- Mission desks: ox_target boxes that open the Officer UI. The coordinates are placeholders near the
    -- base-game stations, 2 m or more from sc-police's duty points: check them on your MLO.
    -- departments = nil lets every department use a desk; prop = a laptop only that player sees, or false.
    desks = {
        {
            label = 'Mission Row PD front desk',
            coords = vec3(441.20, -978.90, 30.69),
            size = vec3(1.2, 0.8, 1.0),
            rotation = 0.0,
            departments = nil,
            prop = false,
        },
        {
            label = 'Sandy Shores office',
            coords = vec3(1853.20, 3689.60, 34.27),
            size = vec3(1.2, 0.8, 1.0),
            rotation = 30.0,
            departments = nil,
            prop = 'prop_laptop_01a',
        },
    },
}

Config.AdminAce = 'crimsonpolice.admin'     -- the admin permission; supervisors come from job grade
Config.AdminTheme = {
    primary = '#a4161a',
    accent = '#e5383b',
    background = '#0b090a',
    surface = '#161a1d',
    text = '#f5f3f4',
}

-- ============================================================================
--                                 PERMISSIONS
-- ============================================================================
-- What supervisors may do. Admins can always do every admin action.
-- false hides the action in the Supervisor UI, and the server refuses it.
Config.Permissions = {
    supervisor = {
        setTypePayout = true,     -- within Config.Payouts limits; never a type an admin has set
        launchCrossDept = true,   -- launch, start now, relaunch and cancel; also remove a joiner before the start
        forceRecall = true,
        reviewFlagged = true,     -- approve or void flagged runs involving their department
        handleDisputes = true,    -- disputes about flagged or voided runs in their department
        builderEdit = true,       -- create, edit, record routes and test their own missions
        builderPublish = true,    -- publish their own tested drafts
        builderArchive = true,    -- archive or restore their own missions
        builderEditAny = false,   -- also edit, publish and archive other people's custom missions
        builderRollback = false,  -- roll a custom mission back to its previous version
        breakEditLock = false,    -- unlock a mission someone else is editing
        missionCalls = true,      -- view, withdraw, page and create mission calls
        issueCommendation = true, -- commend officers of their own department
        reviewProfiles = true,    -- approve or reject pictures and clear bios of their department
    },
    -- Always admin-only, whatever is set above: single-mission payouts, clearing
    -- admin payouts, manual awards, disputes about failed runs, voiding any run,
    -- seasons, the bounty override, suspensions, reloading mission files and test runs.
    -- Nobody may approve, void or answer a dispute about a run they took part in.
}

-- ============================================================================
--                                 DEPARTMENTS
-- ============================================================================
-- Every entry is used automatically for access, the tablet name, colours and
-- logo watermark, leaderboards, the department challenge, unit invites and the
-- Mission Builder. Add a block, put its logo in logos/, restart. No code or SQL changes.
Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',        -- shown in the tablet header
        short = 'SAST',                              -- tag on boards, units and badges
        jobs = { 'sast' },                           -- Qbox job names (as in sc-police / sc-dispatch)
        supervisorGrade = 3,                         -- Qbox grade level; set to your real grade
        societyAccount = 'sast',                     -- only used when Config.Cash.source = 'society'
        theme = {
            primary = '#1f4e8c',     -- header, buttons, active tab, progress bars
            accent = '#f2c230',      -- highlights, badges, focus outlines
            background = '#0d1522',  -- tablet body
            surface = '#152235',     -- cards, tables, dialogs
            -- text    = '#ffffff',   -- optional; picked automatically for contrast when left out
            -- accents an officer may pick for their own tablet: a 6-digit hex colour, or { colour, level }
            -- to unlock it at that level. Leave it out to offer none. Primary, logo and watermark never change.
            personalAccents = {
                '#f2c230',
                '#4cc9f0',
                { colour = '#80ed99', level = 10 },
                { colour = '#ff8fab', level = 25 },
                { colour = '#c77dff', level = 40 },
            },
        },
        logo = {
            file = 'sast.png',  -- file in logos/ (or use url = 'https://...')
            watermark = true,   -- draw the logo behind every screen
            opacity = 0.08,     -- 0.0 to 0.25
            size = 0.6,         -- share of the tablet height
            grayscale = false,
        },
    },
    fib = {
        label = 'Federal Investigation Bureau',
        short = 'FIB',
        jobs = { 'fib' },
        supervisorGrade = 3,
        societyAccount = 'fib',
        theme = {
            primary = '#1c2541',
            accent = '#c9a227',
            background = '#0b0c10',
            surface = '#1a1b24',
            personalAccents = {
                '#c9a227',
                '#e9ecef',
                { colour = '#48cae4', level = 10 },
                { colour = '#f28482', level = 25 },
                { colour = '#b5e48c', level = 40 },
            },
        },
        logo = { file = 'fib.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    },
    -- Example: to add BCSO, uncomment and edit this block, then put bcso.png in logos/ and restart.
    -- bcso = {
    --   label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = { 'bcso' },
    --   supervisorGrade = 3, societyAccount = 'bcso',
    --   theme = { primary = '#5c4033', accent = '#d4a017', background = '#14100c', surface = '#231c16' },
    --   logo  = { file = 'bcso.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
    -- },
}

-- ============================================================================
--                                MISSION TYPES
-- ============================================================================
-- points: leaderboard points, config only (never editable in-game).
-- payout: default base cash payout. Supervisors and admins change it in-game;
-- admin-set values are stored permanently in cp_type_payouts.
-- dailyLimit: completed runs of this type per officer per day; nil = no limit.
Config.MissionTypes = {
    patrol = { label = 'Patrol', points = 60, payout = 250, dailyLimit = nil },
    training = { label = 'Training', points = 100, payout = 350, dailyLimit = nil },
    investigation = { label = 'Investigation', points = 160, payout = 600, dailyLimit = nil },
    tactical = { label = 'Tactical', points = 200, payout = 800, dailyLimit = nil },
}

Config.DisabledMissions = {}   -- built-in mission ids to turn off, e.g. { 'prison_break' }

-- ============================================================================
--                              DIFFICULTY (stars)
-- ============================================================================
-- Multipliers by a mission's difficulty: index 1, 2 or 3 stars.
-- 1.0 = stars change nothing, so a builder can't raise pay or points by picking 3 stars.
Config.Difficulty = {
    pointsByStars = { 1.0, 1.0, 1.0 },
    cashByStars = { 1.0, 1.0, 1.0 },
}

-- ============================================================================
--                                     CASH
-- ============================================================================

Config.Cash = {
    account = 'bank',     -- 'bank' or 'cash'
    source = 'server',    -- 'server' (new money) or 'society' (the department's Renewed-Banking account)
    minPayout = 0,        -- limits for any base payout set in-game
    maxPayout = 25000,
    dailyCap = 0,         -- max cash per officer per day; 0 = no cap
}

-- ============================================================================
--                                PAYOUT EDITING
-- ============================================================================

Config.Payouts = {
    supervisorRange = { 0.5, 2.0 },   -- supervisors: 50%–200% of the type's payout in Config.MissionTypes
    supervisorCooldown = 1800,        -- seconds between changes to the same type (any supervisor)
    requireReason = true,             -- a reason is required for every payout change
}

-- ============================================================================
--                           SCALING BY PARTICIPANTS
-- ============================================================================
-- The first row whose maxParticipants >= the participant count is used.
Config.Scaling = {
    { maxParticipants = 1, tier = 'standard', count = 1.0, accuracy = 0, armour = 0, points = 1.00, cash = 1.00 },
    { maxParticipants = 2, tier = 'reinforced', count = 1.25, accuracy = 5, armour = 10, points = 1.10, cash = 1.15 },
    { maxParticipants = 4, tier = 'heavy', count = 1.5, accuracy = 10, armour = 25, points = 1.15, cash = 1.30 },
    { maxParticipants = 6, tier = 'major', count = 2.0, accuracy = 15, armour = 50, points = 1.20, cash = 1.50 },
    { maxParticipants = 8, tier = 'critical', count = 2.5, accuracy = 20, armour = 75, points = 1.25, cash = 1.75 },
}
Config.CrossDepartmentPoints = 1.10    -- points multiplier when 2+ departments are on a run

-- When the team shrinks mid-run (see When someone leaves mid-run)
Config.Rescale = {
    enabled = true,                                              -- NPCs not yet spawned use the tier for the team that's left
    keepPayTierFor = { 'real_call', 'force_recall', 'downed' },  -- leave reasons that keep the points and cash tier
}

Config.Limits = {
    maxUnitSize = 4,
    maxArmedAlive = 25,          -- armed NPCs alive at any one moment per run
    maxEntities = 80,            -- spawned entities at any one moment per run
    corpseCleanup = 30,          -- seconds before dead NPCs and wrecked vehicles are deleted (bodies a
                                 -- Process the scene objective keeps are deleted when it ends)
    maxCompletionsHour = 8,
    maxCompletionsDay = 0,       -- completed runs per officer per day (from the daily reset); 0 = no cap
    abandonCooldown = 300,       -- seconds; covers the whole mission type
    startTimeout = 600,          -- default seconds to reach the start (a mission can override it)
    maxConcurrentRuns = 12,      -- runs active server-wide at once; Cross-Department Missions don't count
    maxConcurrentTactical = 4,   -- of those, Tactical runs
    reserveLocations = true,     -- a location in use by one run can't be drawn for another
}

-- ============================================================================
--                              ROUTE TO THE START
-- ============================================================================

Config.Route = {
    sampleEvery = 50.0,    -- metres between points taken from the GPS route
    reportEvery = 2,       -- seconds between client reports
    reportTimeout = 10,    -- no report for this long counts as off route
    maxDeviation = 120.0,  -- metres from the line before a participant is off route
    warnAfter = 10,        -- seconds off route before the warning
    abandonAfter = 30,     -- seconds off route in one stretch before Abandoned (back on route resets it)
    maxRecalcs = 2,        -- Recalculate route taps per participant per run
    maxDrift = 1000.0,     -- server check: metres further from the start than the closest they have been
}

-- ============================================================================
--                                  REAL CALLS
-- ============================================================================

Config.Calls = {
    npcCallPrefix = 'npccall-', -- SC-NPCPolice call ids start with this; those calls never end a run
    ownRunCallPrefixes = { 'playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_' }, -- about a participant: not real calls for their partners
    dodgeWindow = 60, -- un-marking responding within this many seconds makes it a normal abandon
    respondingExpiry = 1200, -- seconds; a responding entry with no update expires (auto-cleared calls fire no event)
}

-- ============================================================================
--                              ALERT SUPPRESSION
-- ============================================================================
-- The flag is the crimsonArena state bag, which SC-Dispatch and SC-Ambulance
-- already check; its name is fixed in those resources, so it is not configurable.
Config.Alerts = {
    backstopRadius = 300.0, -- clear a shots-fired call from a participant within this many metres of their mission (person-down and dead calls are cleared while the flag is on)
    backstopDelay = 1,      -- seconds to wait for SC-Dispatch to create the call before clearing it
}

-- ============================================================================
--                             DOWNED PARTICIPANTS
-- ============================================================================

Config.Downed = {
    checkEvery = 2,     -- seconds between downed checks
    pickupDelay = 15,   -- seconds down, with no EMS on duty, before the pick-up
    dropOffs = {        -- the nearest one is used; defaults are SC-Ambulance's check-in points
        vec3(308.19, -595.35, 43.29),   -- Pillbox Hill
        vec3(-254.54, 6331.78, 32.43),  -- Paleto Bay
    },
}

-- ============================================================================
--                                 ANTI-EXPLOIT
-- ============================================================================

Config.AntiCheat = {
    maxSpeed = 80.0,        -- m/s between objective events before a run is flagged
    presenceRadius = 150.0, -- runs with 2+ participants: fallback presence range for a block with none of its own...
    presenceShare = 0.70,   -- ...for this share of the run to earn points and cash
    idleCheck = 180,        -- seconds after the run moves to In progress to remove participants who haven't reached the start
    jobRecheck = 10,        -- seconds between active-job and duty re-checks during a run
    outsideKillsToFlag = 1, -- kills of mission NPCs by players who aren't on the run that flag it for review
    voidsToSuspend = 3,     -- this many voided runs...
    voidWindowDays = 30,    -- ...within this many days...
    suspendDays = 7,        -- ...suspends the officer for this many days
}

-- ============================================================================
--                          CROSS-DEPARTMENT MISSIONS
-- ============================================================================

Config.CrossDept = {
    enabled = true,
    minParticipants = 2,
    maxParticipants = 8,
    joinWindow = 300,        -- seconds until joining closes (or the launcher taps Start now)
    idleCancel = 1800,       -- auto-cancel after this long with no run in progress
    cooldown = 1800,         -- seconds between launches, server-wide
    waitlist = true,         -- officers can queue when every place is taken; a freed place goes to the first
}

-- ============================================================================
--                                 RANDOM DRAW
-- ============================================================================

Config.Draw = {
    avoidLast = 1,              -- never repeat the last mission in that type
    avoidLastLarge = 2,         -- skip the last two when the pool has largePool+ missions
    largePool = 4,
    playerClearance = 75.0,     -- skip locations with a non-participant within this many metres
    zoneClearance = 200.0,      -- skip a location within this many metres of another active run's location
                                -- (any mission), while another is free
    avoidLastLocations = 2,     -- skip the last N locations any participant played in this mission, while
                                -- another is free
    locationFreshness = 3600,   -- seconds: a location used server-wide this recently gets half the weight
}

-- ============================================================================
--                                    UNITS
-- ============================================================================

Config.Units = {
    invitePolicy = 'anyone',            -- 'anyone' (every member may invite) | 'leader'
    readyCheck = true,                  -- units of 2+ confirm before the draw
    readyTimeout = 20,                  -- seconds to answer
    kickReinvite = 60,                  -- seconds before a kicked officer can be invited again
    nearbyBands = { 250, 1000, 3000 },  -- metres: distance bands in the invite list
}

-- ============================================================================
--                           DISPATCH (MISSION CALLS)
-- ============================================================================
-- Tablet-only NPC calls. The first unit to claim one gets a random mission of that type that starts in
-- the call's area. Mission calls are never sent to SC-Dispatch, and real calls always come first.
Config.MissionCalls = {
    enabled = true,
    checkEvery = 10,                 -- seconds between server checks
    types = {                        -- types that can be called: how often (weight) and priority (1 = highest)
        patrol = { weight = 5, priority = 3 },
        investigation = { weight = 3, priority = 2 },
        tactical = { weight = 2, priority = 1 },
        -- training = { weight = 1, priority = 3 },   -- training and the Weekly Boss are never called
    },
    unitsPerCall = 2,                         -- at most one open call per this many idle units...
    maxOpen = 4,                              -- ...and never more than this many open at once
    spawnEvery = { 60, 150 },                 -- seconds between new calls, random in this range
    offerTime = 180,                          -- seconds a call stays open
    lapsedShown = 10,                         -- seconds a lapsed call stays on screen
    claimWindowMs = 1500,                     -- claims this soon after the first are ranked (0 = pure first click)
    priorityWindow = 15,                      -- seconds during which only nearby units may claim...
    priorityRadius = 1500.0,                  -- ...within this many metres of the area's centre
    -- A call names its area to a viewer only when the viewer's eligible pool there (after unit size,
    -- no-repeat, cooldowns and daily limits) has this many missions and locations; else "County-wide".
    minMissionsPerArea = 2,
    minLocationsPerArea = 3,
    countyWeightKm = 2.0,                                      -- county-wide draws weight locations by 1 / (1 + km / this)
    titles = { patrol = 8, investigation = 6, tactical = 6 },  -- flavour titles per type (mc.title.<type>.<n>)
    eligibilityCache = 10,                                     -- seconds an officer's cached eligibility may be reused
    recentShown = 5,                                           -- calls in the Recent calls list
    reopen = { enabled = true, time = 120 },                   -- a claim dropped before anyone reached the start reopens once
    -- +10% of P (points only) for reaching the start within distance ÷ speed (m/s) + grace (seconds)
    -- Server-posted calls only: paged and staff-created calls never earn it.
    rapidResponse = { pctOfP = 0.10, speed = 20.0, grace = 45 },
    pageTime = 30,                   -- seconds a paged call is offered only to the paged unit
    staffCooldown = 120,             -- seconds between calls created by the same supervisor
    -- the issuer's own unit can never be paged, and can't claim a call the issuer paged or created
    claimRate = 1500,                -- milliseconds between claim attempts per player
    realCallStrip = true,            -- show the read-only SC-Dispatch real-call count
    realCallCache = 15,              -- seconds
    -- A location belongs to the area whose centre is nearest. Labels show on the calls.
    areas = {
        { key = 'south_ls', label = 'South Los Santos', center = vec3(150.0, -1750.0, 29.0) },
        { key = 'downtown', label = 'Downtown', center = vec3(-150.0, -850.0, 30.0) },
        { key = 'west_ls', label = 'West Los Santos', center = vec3(-1250.0, -650.0, 25.0) },
        { key = 'vinewood', label = 'Vinewood', center = vec3(250.0, 250.0, 105.0) },
        { key = 'east_ls', label = 'East Los Santos', center = vec3(1100.0, -1250.0, 40.0) },
        { key = 'port', label = 'Port & Airport', center = vec3(100.0, -2700.0, 6.0) },
        { key = 'senora', label = 'Grand Senora', center = vec3(1400.0, 3200.0, 40.0) },
        { key = 'north', label = 'Grapeseed & Paleto', center = vec3(700.0, 5600.0, 35.0) },
        { key = 'west_county', label = 'West Blaine County', center = vec3(-2500.0, 2000.0, 20.0) },
    },
}

-- ============================================================================
--                          POLICE ACTIONS AND CUSTODY
-- ============================================================================

Config.Custody = {
    times = {                        -- seconds each action's progress bar takes
        talk = 4,
        frisk = 4,
        detain = 3,
        searchPerson = 4,
        lookInside = 2,
        runPlate = 3,
        inspect = 3,
        orderOut = 2,
        searchVehicle = 8,
        warn = 2,
        cite = 6,
        release = 2,
        impound = 10,
        noAction = 1,
        explain = 4,
        escort = 1,
        seat = 2,
        handover = 4,
    },
    reach = {                        -- metres, checked with server-side coordinates
        person = 2.0,
        frisk = 1.5,
        vehicle = 3.0,
        plateFromVehicle = 20.0,     -- Run plate from the driver seat of any vehicle
        seatVehicle = 5.0,
        van = 20.0,                  -- Hand over moves escorted and seated people this close to the van
    },
    -- chance a person agrees to a vehicle search
    consent = { clean = 0.60, guilty = 0.15 },
    admission = 0.20,                -- chance a guilty person admits it when talked to (probable cause)
    handcuffsItem = false,           -- e.g. 'handcuffs': Detain and Cuff suspect need it (checked, not used)
    evidenceItem = false,            -- e.g. 'evidence_bag': one per participant, removed at the run's end
    releaseDespawn = 30,             -- seconds before a released person or car is removed
    actionSlack = 0.5,               -- seconds an action's finish may come early (begin → finish check)
    -- Cues rolled with a guilty truth, so contraband in a car can usually be found lawfully.
    cues = { plainView = 0.40, odour = 0.30 },
    -- Mission vehicle plates: prefix + random letters and digits (8 characters in all), rerolled up to
    -- 5 times when player_vehicles already has the plate.
    plates = { prefix = 'CP', length = 8 },
    -- Service vehicles (transport, tow, coroner): driven by the nearest participant's client.
    serviceTimeout = 60,             -- seconds to park or load before the fallback (placed / faded out)
    serviceHandoff = 250.0,          -- metres: AI moves to another participant beyond this
    transport = {                    -- the prisoner van
        model = 'policet',
        driver = 's_m_y_cop_01',
        spawnDistance = { 150.0, 250.0 },
        parkWithin = 60.0,           -- metres: with no transport point it parks anywhere this close to the scene
        leaveAfter = 60,             -- seconds after the objective that called it ends; called again if needed
    },
    tow = {                          -- the tow truck; enabled = false fades the car out instead
        enabled = true,
        model = 'flatbed',
        driver = 's_m_m_trucker_01',
        spawnDistance = { 150.0, 250.0 },
        leaveAfter = 45,
    },
    coroner = {
        model = 'burrito3',
        driver = 's_m_y_autopsy_01',
        bagProp = 'xm_prop_body_bag',
        spawnDistance = { 150.0, 250.0 },
    },
    offences = {                     -- what a citation can name (labels: locale custody.offence.<id>)
        person = {
            'speeding',
            'reckless',
            'no_licence',
            'suspended_licence',
            'expired_registration',
            'open_container',
            'loitering',
            'possession_small',
            'equipment',
        },
        vehicle = { 'expired_meter', 'no_permit', 'no_parking', 'hydrant', 'loading_zone' },
    },
    -- Hidden truths, as weights. A mission objective names the set (profileSet).
    profileSets = {
        scene = {
            person = { clean = 35, minor = 15, warrant = 15, narcotics = 15, tools = 12, armed = 8 },
            vehicle = { legal = 85, stolen = 15 },
        },
        traffic = {
            driver = { clean = 50, minor = 20, suspended = 10, warrant = 8, intoxicated = 7, narcotics = 3, armed = 2 },
            passenger = { clean = 70, warrant = 12, narcotics = 10, armed = 8 },
            vehicle = { legal = 90, stolen = 10 },
        },
        parking = {
            vehicle = { legal = 45, violation = 50, stolen = 5 },
        },
        stolenCar = {
            driver = { evading = 60, warrant = 25, armed = 15 },
            passenger = { evading = 60, warrant = 20, armed = 20 },
            vehicle = { stolen = 100 },
        },
    },
    -- Demeanour weights by truth. Only armed people can be hostile.
    demeanour = {
        clean = { compliant = 80, nervous = 15, evasive = 5 },
        minor = { compliant = 60, nervous = 30, evasive = 10 },
        suspended = { compliant = 55, nervous = 35, evasive = 10 },
        warrant = { compliant = 35, nervous = 25, evasive = 15, runner = 25 },
        narcotics = { compliant = 40, nervous = 35, evasive = 10, runner = 15 },
        tools = { compliant = 40, nervous = 30, evasive = 15, runner = 15 },
        intoxicated = { compliant = 60, nervous = 25, evasive = 15 },
        armed = { compliant = 30, nervous = 20, runner = 20, hostile = 30 },
        evading = { compliant = 30, nervous = 20, runner = 50 },
    },
    -- Parking: which spot rules make a violation ticket-level ('cite') or tow-level ('impound').
    parkingRules = {
        metered = 'cite',
        permit = 'cite',
        no_parking = 'impound',
        hydrant = 'impound',
        loading = 'impound',
        free = false,                -- a free spot is legal, or the car is stolen
    },
}

-- ============================================================================
--                                  DECISIONS
-- ============================================================================
-- The point value of each grade is in Config.Bonuses (correct_disposition, wrongful_arrest, ...).
Config.Decisions = {
    -- releasing a person after their warrant or weapon reached the decider fails the case
    failOnKnownDanger = true,
    -- No action or a citation for a car whose stolen plate reached the decider fails the case
    failOnKnownStolen = true,
    confirmKnownErrors = true,          -- a case-failing choice asks "this will fail the case" first
    undiscoverableIsOk = true,          -- Release or No action is Acceptable when no lawful path existed
    undecidedAtEnd = 'missed_offence',  -- what a contact still undecided at the end counts as
    debrief = true,                     -- list every decision on the result screen and in history
}

-- ============================================================================
--                              SUSPECT BEHAVIOUR
-- ============================================================================

Config.Npc = {
    tellSeconds = { 1.5, 3.0 },      -- how long a tell plays before a person runs or draws
    tellHints = true,                -- HUD hint ("Watch his hands") for participants within tellRange
    tellRange = 25.0,                -- metres
    feintRange = 6.0,                -- a feint needs no participant this close...
    feintAfter = 5,                  -- ...and nobody aiming for this many seconds
}

-- How NPCs feel. It never changes points or cash.
Config.NpcDifficulty = {
    preset = 'normal',               -- 'easy' | 'normal' | 'hard' | 'custom'
    custom = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
    presets = {
        easy = { accuracyAdd = -8, armourAdd = 0, healthMult = 0.85, surrenderMult = 1.3, fleeMult = 0.8 },
        normal = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
        hard = { accuracyAdd = 8, armourAdd = 15, healthMult = 1.15, surrenderMult = 0.7, fleeMult = 1.2 },
    },
}

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================
-- Change built-in missions without editing their files, so the change survives updates. Every tweak is
-- checked by the same rules as the file; a tweak that breaks one is ignored with a console warning.
-- Allowed keys: cooldown, timeLimit, startTimeout, disabledLocations (labels), peds, vehicles, weapons.
Config.MissionTweaks = {
    -- prison_break = { cooldown = 1800, timeLimit = 720, disabledLocations = { 'North gate' } },
    -- gang_shootout = { peds = { 'g_m_y_lost_01' }, weapons = { 'WEAPON_PISTOL', 'WEAPON_SMG' } },
}

-- ============================================================================
--                                     TIME
-- ============================================================================
-- Hour (0–23, server time) of the daily reset: Type of the Day, daily goals,
-- streak days, the daily cash cap and the retention job. Weekly things reset
-- at this hour on Config.Leaderboard.weekStartsOn.
Config.Time = { resetHour = 0 }

-- ============================================================================
--                         SCORING, XP LEVELS AND GOALS
-- ============================================================================

Config.Scoring = {
    scoreCap = 2.0,          -- × P
    streakStep = 0.05,
    streakMax = 0.25,
    streakGraceDays = 1,     -- missed days per week that don't reset the streak (0 = off)
    failedCredit = 0.25,
    common = {
        fastShare = 0.75,        -- finished within this share of the time limit...
        fastBonus = 0.20,        -- ...earns this share of P
        noDamage = 10,
        firstRun = 15,
        heavyDamage = -25,
        pedestrianHit = -30,
        lightsSiren = -10,       -- missions with quietPatrol = true only (Beat Patrol, Business Check,
                                 -- Illegal Parking Patrol), and only after arrival at the start
        shotSurrendered = -20,
        noDamageAbove = 950,     -- engine and body health above this earns noDamage
        heavyDamageBelow = 500,  -- body health below this costs heavyDamage
    },
}

-- ============================================================================
--                            BONUSES AND PENALTIES
-- ============================================================================
-- The standard list, and the only one the Mission Builder offers. kind 'points'
-- = flat points (each = per occurrence); kind 'pct' = a share of P. block = the
-- block the mission must contain (none = any mission). Ids with positive values go in a mission file's bonuses,
-- negative ones in its penalties; either may override the value with points or pctOfPoints.
-- Labels live in locales/en.json. Built-in missions may also use the extra
-- bonuses written on their mission cards. Decision grades are personal to the officer who decided.
-- engineOnly = true: awarded by the engine or a block's own setting (e.g. bestPoints); never listed by
-- builder:config, and the loader refuses it in a mission file's bonuses or penalties.
Config.Bonuses = {
    no_participant_downed = { kind = 'pct', value = 0.10 },
    no_weapons_fired = { kind = 'points', value = 10 },
    hostile_arrested = { kind = 'points', value = 5, each = true, block = 'hostile_waves' },
    suspect_alive = { kind = 'points', value = 15, block = 'flee_arrest' },
    no_hostage_hurt = { kind = 'points', value = 15, block = 'protect_rescue' },
    vehicle_stopped_fast = { kind = 'points', value = 15, block = 'pursuit' },            -- stopped within 2 minutes of the start
    truck_healthy = { kind = 'pct', value = 0.10, block = 'escort' },                     -- arrives above 50% health
    clues_first = { kind = 'points', value = 10, block = 'search_area' },                 -- every clue checked before the first arrest
    no_missed_checks = { kind = 'points', value = 15, block = 'skill_check' },
    correct_log = { kind = 'points', value = 5, each = true, block = 'interact_points' },
    wrong_log = { kind = 'points', value = -5, each = true, block = 'interact_points' },  -- penalty
    hard_ram = { kind = 'points', value = -10, each = true, block = 'pursuit' },          -- penalty: ramming at over 100 km/h
    correct_disposition = { kind = 'points', value = 10, each = true, block = 'field_contact', engineOnly = true },
    procedure_complete = { kind = 'points', value = 10, block = 'field_contact' },        -- once per officer
    all_correct = { kind = 'points', value = 10, block = 'field_contact' },
    subject_alive = { kind = 'points', value = 15, each = true, block = 'field_contact' },
    vehicle_impounded = { kind = 'points', value = 10, each = true, block = 'field_contact' },
    -- decision grades (negative values are penalties)
    wrong_citation = { kind = 'points', value = -5, each = true, block = 'field_contact', engineOnly = true },
    missed_offence = { kind = 'points', value = -5, each = true, block = 'field_contact', engineOnly = true },
    wrongful_arrest = { kind = 'points', value = -25, each = true, block = 'field_contact', engineOnly = true },
    missed_arrest = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    wrongful_impound = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    missed_impound = { kind = 'points', value = -10, each = true, block = 'field_contact', engineOnly = true },
    unlawful_search = { kind = 'points', value = -15, each = true, block = 'field_contact', engineOnly = true },
    unsearched_transport = { kind = 'points', value = -10, each = true, engineOnly = true },
    excessive_force = { kind = 'points', value = -10, each = true, engineOnly = true },
    all_taken_alive = { kind = 'points', value = 15, block = 'process_scene', engineOnly = true },
    stop_without_cause = { kind = 'points', value = -15, block = 'pursuit', engineOnly = true },
    lab_fire = { kind = 'points', value = -15, block = 'skill_check' },  -- penalty: setback
    cook_arrested = { kind = 'points', value = 10, each = true, block = 'flee_arrest' },
    stash_found_fast = { kind = 'points', value = 10, block = 'interact_points' },
    lieutenant_alive = { kind = 'points', value = 25, block = 'hostile_waves' },
    rapid_response = { kind = 'pct', value = 0.10, engineOnly = true },  -- claimed server-posted mission calls
}

-- Cosmetic badges only; never the Qbox rank. Each name is a band of numbered levels starting at level;
-- xp stays for old callers.
Config.XPLevels = {
    { label = 'Probationary', xp = 0, badge = 'grey', level = 1 },
    { label = 'Patrol Officer', xp = 1000, badge = 'bronze', level = 10 },
    { label = 'Senior Patrol', xp = 5000, badge = 'silver', level = 25 },
    { label = 'Veteran', xp = 15000, badge = 'gold', level = 38 },
    { label = 'Elite', xp = 40000, badge = 'platinum', level = 50 },
}

-- Level n needs round(first × (growth^(n − 1) − 1) ÷ (growth − 1)) XP. Cosmetic only: never the rank,
-- never pay, never missions. Lv 10 ≈ 1,200 XP, Lv 25 ≈ 5,800, Lv 50 ≈ 37,900.
Config.XPCurve = {
    maxLevel = 50,
    first = 100,             -- XP from level 1 to level 2
    growth = 1.07,           -- each level needs this much more than the one before
    prestigeEvery = 10000,   -- after maxLevel, one prestige star per this much XP
}

Config.Badges = {            -- achievement badge counts
    ironWheels = 20,     -- completed runs with no vehicle damage
    sharpshooter = 10,   -- Gang Shootouts with no participant downed
    roadWarrior = 100,   -- Patrol missions
    partnerInCrime = 50, -- unit runs
    jointTaskForce = 10, -- runs with 2 or more departments
    byTheBook = 100,     -- Best dispositions
    firstResponder = 25, -- mission calls answered with rapid response
}

-- A goal's stat is one of: arrests, citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok
-- (Best or Acceptable), decisions_best. Stat goals count completed rows only.
Config.Goals = {
    dailyPoints = 50,
    weeklyPoints = 200,
    daily = {
        { id = 'patrol_2', label = 'Complete 2 Patrol missions', type = 'patrol', count = 2 },
        { id = 'any_3', label = 'Complete 3 missions of any type', count = 3 },
        { id = 'unit_1', label = 'Complete 1 unit run', unit = true, count = 1 },
        { id = 'calls_2', label = 'Answer 2 mission calls', missionCall = true, count = 2 },
        { id = 'arrests_2', label = 'Make 2 arrests', stat = 'arrests', count = 2 },
    },
    weekly = {
        { id = 'tactical_5', label = 'Complete 5 Tactical missions', type = 'tactical', count = 5 },
        { id = 'cross_2', label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 },
        { id = 'any_15', label = 'Complete 15 missions', count = 15 },
        { id = 'judgement_15', label = 'Make 15 correct decisions', stat = 'decisions_ok', count = 15 },
        { id = 'impound_3', label = 'Impound 3 vehicles', stat = 'impounds', count = 3 },
    },
}

-- ============================================================================
--                                 LEADERBOARD
-- ============================================================================

Config.Leaderboard = {
    cacheSeconds = 60,
    minRunsToRank = 3,
    topN = 25,
    weekStartsOn = 'monday',
    seasonWeeks = 8,         -- suggested season length for "weeks left"; an admin ends the season
    metrics = { 'points', 'missions', 'arrests', 'impounds', 'citations', 'rescues', 'calls', 'judgement' },
    minDecisions = 10,       -- Judgement: decisions needed in the window
    weeklyBadges = {},       -- extra weekly badges by metric, e.g. { 'arrests' }; Officer of the Week stays by points
}

-- ============================================================================
--                                SPECIAL EVENTS
-- ============================================================================

Config.Events = {
    typeOfTheDay = true,
    todMultiplier = 2.0,     -- points only
    modifierChance = 0.25,
    modifierPoints = 0.25,   -- +25% of P
    modifierCash = 1.25,     -- × cash
    armoredArmour = 50,      -- Armored Hostiles: extra armour on armed NPCs (Tactical only)
    timeCrunchCut = 0.25,    -- Time Crunch: share of the time limit removed
    weeklyBoss = { enabled = true, days = { 'friday', 'saturday', 'sunday' }, points = 500, payout = 2500 },
}

-- ============================================================================
--                             DEPARTMENT CHALLENGE
-- ============================================================================

Config.Challenge = {
    enabled = true,
    scoring = 'average',       -- 'average' (per active officer) | 'total' | 'top10'
    minRunsActive = 3,
    weeklyBounty = true,
    bountyBonus = 0.10,
    bounties = {               -- one is picked at random each week; counted per active officer
        { id = 'most_tactical', label = 'Most Tactical missions' },
        { id = 'most_cross', label = 'Most cross-department runs' },
        { id = 'most_unit', label = 'Most unit runs' },
        { id = 'most_completed', label = 'Most completed runs' },
        { id = 'most_arrests', label = 'Most arrests' },
        { id = 'most_calls', label = 'Most mission calls answered' },
    },
}

-- ============================================================================
--                               OFFICER PROFILE
-- ============================================================================

Config.Profile = {
    bioMax = 280,                                 -- characters
    bioLines = 3,
    editCooldown = 300,                           -- seconds between profile changes
    bannedWords = {},                             -- extra words refused in bios (any case, whole words)
    bannedWordsFile = 'config/banned_words.txt',  -- the shipped default list; false = none
    bioRequiresApproval = false,                  -- true = a new bio is Pending until a supervisor or admin approves it
    reports = { perDay = 3, reasonMax = 140 },    -- Report profile: per reporter per day; text length
    avatarPresets = {                             -- image files ship in the UI; level = unlocked at that level
        { id = 'shield' },
        { id = 'star' },
        { id = 'badge' },
        { id = 'dept' },             -- the department logo
        { id = 'k9', level = 5 },
        { id = 'motor', level = 10 },
        { id = 'heli', level = 20 },
        { id = 'swat', level = 30 },
        { id = 'detective', level = 40 },
    },
    avatarUrls = {
        enabled = false,             -- allow image links as profile pictures
        requireApproval = true,      -- a supervisor of the department or an admin approves each new link
        perDay = 3,                  -- link submissions per officer per day
        -- exact host names allowed. Not cdn.discordapp.com: its links carry signed query strings and
        -- expire. i.imgur.com is blocked in some regions (including the UK).
        hosts = { 'r2.fivemanage.com', 'i.imgur.com' },
    },
    -- accessibility looks worked out from the department theme
    appearances = { 'department', 'midnight', 'high_contrast', 'colourblind' },
    uiScale = { 0.85, 1.25, 1.0 },   -- min, max and default tablet size
    showMdtCommendations = false,    -- also show SC-Dispatch MDT commendations, read-only
}

Config.Commendations = {
    enabled = true,
    kinds = { 'valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation' },
    citation = { 10, 255 },          -- characters
    perSupervisorPerDay = 3,
    sameKindCooldownDays = 7,        -- same officer, same kind
    crossDepartment = false,         -- true = supervisors may commend officers of other departments
    announceDays = 7,                -- days the Home announcement shows for the recipient
    announce = false,                -- also post it to the board webhook
}

-- ============================================================================
--                           ITEM REWARDS (OPTIONAL)
-- ============================================================================
-- Off by default. Admin config only: mission files and the Mission Builder never hold rewards.
-- Items must exist in ox_inventory. Never weapons, ammo, armour, bandages or money items.
Config.Rewards = {
    enabled = false,
    dailyItemCap = 10,               -- items per officer per day, every source together
    dailyValueCap = 2000,            -- total value of those items per officer per day
    findBonus = 0.10,                -- each lawful evidence find adds this to the run's chance...
    findBonusMax = 0.30,             -- ...up to this much
    -- added to the chance at each scaling tier
    tierChance = { reinforced = 0.05, heavy = 0.10, major = 0.15, critical = 0.20 },
    byType = {                       -- chance per roll, rolls per run, and a weighted pool
        -- tactical = {
        --     chance = 0.25,
        --     rolls = 1,
        --     pool = { { item = 'water', count = { 1, 2 }, weight = 3, value = 20 } },
        -- },
    },
    byMission = {},                  -- same shape as byType, keyed by mission id; replaces the type's entry
    medals = {},                     -- e.g. gold = { item = 'water', count = 1, value = 20 }
    goals = {},                      -- daily = { ... }, weekly = { ... }
    levels = {},                     -- e.g. [10] = { item = 'radio', count = 1, value = 150 }
    weeklyBoss = nil,                -- a guaranteed item for a completed Weekly Boss
    season = {},                     -- champion = { ... }, top10 = { ... }
    -- matched case-insensitively (WEAPON_PISTOL is refused too)
    forbidden = { 'weapon_*', 'ammo-*', 'armour', 'bandage', 'money', 'black_money', 'cash' },
    useExamplePools = false,         -- true = use examplePools for any type byType leaves empty
    examplePools = {                 -- example: safe values (default ox_inventory consumables)
        patrol = { chance = 0.15, rolls = 1, pool = { { item = 'water', count = { 1, 2 }, weight = 3, value = 20 } } },
        investigation = {
            chance = 0.20,
            rolls = 1,
            pool = {
                { item = 'water', count = { 1, 2 }, weight = 2, value = 20 },
                { item = 'burger', count = 1, weight = 1, value = 40 },
            },
        },
        tactical = {
            chance = 0.25,
            rolls = 1,
            pool = {
                { item = 'burger', count = { 1, 2 }, weight = 2, value = 40 },
                { item = 'sprunk', count = { 1, 2 }, weight = 2, value = 25 },
            },
        },
    },
}

-- ============================================================================
--                                   DISPUTES
-- ============================================================================

Config.Disputes = { windowHours = 48 }

-- ============================================================================
--                               MISSION BUILDER
-- ============================================================================
-- Block setting ranges and defaults are in config/blocks.lua.
Config.Builder = {
    enabled = true,
    maxHostiles = 40,                          -- armed NPCs per mission across all blocks, before scaling
    maxBlocks = 6,
    minLocations = 3,
    minLocationGap = 100.0,                    -- metres between locations of one mission
    minSpawnFromStart = 30.0,                  -- metres between any spawn point and the start point
    bonusCap = { points = 50, share = 0.25 },  -- flat bonuses and penalties: at most 50 points; percentage ones: at most 25% of P
    testAtMaxTier = true,                      -- publishing needs a passed test at the tier maxOfficers reaches
    editLockMinutes = 30,                      -- one editor at a time; renewed while they keep editing
    autosaveSeconds = 30,
    exportPath = 'missions/custom/',
    keepBackups = true,                        -- keep <mission_id>.v<version>.lua.bak on every publish
    route = {                                  -- route recording (see Mission Builder, Route recording)
        snapEvery = 25.0,       -- metres between samples while recording
        maxOffRoad = 8.0,       -- samples further than this from a road node are rejected
        turnAngle = 30.0,       -- heading change (degrees) that keeps a waypoint
        maxGap = 150.0,         -- at least one waypoint this often, in metres
        minLength = 800.0,
        maxLength = 8000.0,
        minStartEndGap = 300.0, -- open routes: start and end at least this far apart
        loopClose = 50.0,       -- a race loop must end this close to its start
        undoMetres = 100.0,     -- Backspace removes this much of the recording
        testDriveTimeout = 30,  -- seconds to reach each waypoint in a test drive
    },
    allowed = {                 -- the only models, weapons and animations builders can pick
        weapons = {
            'WEAPON_PISTOL',
            'WEAPON_COMBATPISTOL',
            'WEAPON_MICROSMG',
            'WEAPON_SMG',
            'WEAPON_PUMPSHOTGUN',
            'WEAPON_ASSAULTRIFLE',
        },
        -- base-game ped models only. The list holds every ped a built-in mission or a block default uses
        -- (inmates, the Kingpin, the escort driver), so a copy of any built-in mission can be published.
        peds = {
            'g_m_y_ballaeast_01',
            'g_m_y_famca_01',
            'g_m_y_mexgoon_01',
            'g_m_y_lost_01',
            'a_m_m_business_01',
            'a_f_y_business_01',
            's_m_y_prisoner_01',
            's_m_y_prismuscl_01',
            'g_m_m_armboss_01',
            's_m_m_armoured_01',
            'a_m_y_stbla_01',
            'a_m_m_eastsa_02',
            'a_m_y_mexthug_01',
            'a_f_y_eastsa_03',
            'a_m_m_salton_02',
            'g_m_y_salvagoon_01',
            'g_m_m_chicold_01',
        },
        vehicles = {
            'sultan',
            'buffalo',
            'elegy2',
            'kuruma',
            'dominator',
            'asea',
            'primo',
            'emperor',
            'tornado',
            'stanier',
            'rancherxl',
            'bison',
        },
        escortVehicles = { 'stockade', 'stockade3' },
        animations = { 'clipboard', 'search', 'kneel', 'mechanic', 'notepad', 'photo' },
    },
    noBuildZones = {            -- no spawn point, marker or route waypoint inside these
        { label = 'Mission Row PD and FIB HQ', coords = vec3(470.63, -974.11, 30.18), radius = 120.0 },
        { label = 'Sandy Shores BCSO', coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
        { label = 'SASP HQ', coords = vec3(1560.38, 815.76, 76.21), radius = 80.0 },
        { label = 'Pillbox Hill Medical', coords = vec3(308.19, -595.35, 43.29), radius = 100.0 },
        { label = 'Paleto Bay Medical', coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
        { label = 'Bolingbroke interior', coords = vec3(1768.73, 2570.43, 44.73), radius = 180.0 }, -- widen or move to fit your prison
        { label = 'Crimson-Arena Trailer Park', coords = vec3(2344.43, 2565.06, 46.67), radius = 160.0 }, -- live match boundary (up to 135 m) + push-back
        { label = 'Crimson-Arena lobby', coords = vec3(-282.01, -2030.46, 30.15), radius = 60.0 }, -- where arena players return after a match
    },
}

-- ============================================================================
--                               ADMIN TEST MODE
-- ============================================================================

Config.Testing = {
    enabled = true,
    maxTesters = 8,        -- players in one test run, including the admin
    useStartRoute = false, -- default for the start-route toggle
    allowTeleport = true,  -- teleport controls in test runs
    debugOverlay = true,   -- the debug overlay control
}

-- ============================================================================
--                                  RETENTION
-- ============================================================================

Config.Retention = {
    runArchiveMonths = 12,  -- move older runs to cp_mission_runs_archive; 0 = never
    auditDays = 180,        -- delete older audit rows; 0 = keep forever
    missionCallDays = 90,   -- delete older mission call history; 0 = keep forever
}

-- Discord webhooks are read from convars in server.cfg, never stored here.
-- A convar that is missing or empty turns that webhook off.
--   set cp_webhook_board      "https://discord.com/api/webhooks/..."   (weekly top 3, season results)
--   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   (payout changes and admin actions)
--   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   (flagged runs, voids, disputes)
--   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   (publish, archive, rollback, lock breaks, code edits)
--   set cp_webhook_operations "https://discord.com/api/webhooks/..."   (Cross-Department launches and results)
