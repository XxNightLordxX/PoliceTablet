-- Every Crimson-Police setting. If this file and the spec disagree, this file wins.
-- You never have to edit this file: an admin can change every setting in game (Admin UI → Settings). A change made
-- there is saved over the value here and survives restarts; Reset puts this file's value back.

-- CONTENTS: six parts, laid out like the Admin UI. Each block below has a banner with its name, which is also its
-- section in Admin UI -> Settings -> All settings. Every key has a comment with its unit and the values it takes;
-- in a list of entries that all have the same fields (Bonuses, map markers, departments), a line "field: text"
-- above the list explains that field for every entry.
--   PART 1 GENERAL              Debug, Storage (database or saves folder), Formats, Tablet and commands, Permissions,
--                               Admin control, Departments, Names
--   PART 2 NPC MISSIONS         Mission types, Difficulty, Scaling by participants, Spawning, Suspect behaviour,
--                               Route to the start, Map markers, Random draw, Dispatch (mission calls), Real calls,
--                               Alert suppression, Downed participants, Police actions and custody, Decisions,
--                               Special events, Built-in mission tweaks, Mission Builder
--   PART 3 PLAYER VS POLICE     Real suspects, Live crimes, Volunteer suspects, Criminal tablet
--   PART 4 POLICE TEAMWORK      Units, Cross-department missions, Mission controls, Field training, Leaderboard,
--                               Department challenge, Officer profile (and My options, commendations)
--   PART 5 ECONOMY AND REWARDS  Cash, Payout editing, Disputes, Scoring, XP levels and goals, Bonuses and penalties,
--                               Item rewards, Feature rewards
--   PART 6 SYSTEM               Run limits, Anti-exploit, Time, Admin test mode, Retention, Backups (webhooks are
--                               server.cfg convars, listed at the end)
-- Mission Builder ranges (what a builder may pick for each block) are in config/blocks.lua.

Config = {}

-- ############################################################################
--                               PART 1 · GENERAL
-- Debug lines, the language, where data is saved, the tablet and its commands, the admins and the
-- Admin UI, what supervisors and admins may do, the departments and the names admins give.
-- Usually changed here: Database (before the first start), the tablet keys and desks, and your departments' jobs
-- and supervisor grades.
-- ############################################################################

Config.Debug = true              -- true = each module prints tagged debug lines
Config.Locale = 'en'             -- the language of every text: 'en' (English) only

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
    enabled = false,  -- true = MySQL/MariaDB through oxmysql; false = files in the saves folder
    folder = 'saves', -- files mode: the folder inside Crimson-Police the files are saved in
    -- Files mode: after this many milliseconds of saving, Crimson-Police lets the server run its other work for a
    -- moment before the next save (what oxmysql does in database mode); 0 = never pause (the old timing)
    saveTurnMs = 4,
    -- Files mode: how many answers of JSON lookups (badge counts read every run of an officer) are kept; about 50 bytes
    -- each, 100000 = about 5 MB; 20000 = the old size; 0 = keep none
    jsonCacheEntries = 100000,
}

-- ============================================================================
--                                   FORMATS
-- ============================================================================

Config.Format = {
    currency = '$',              -- money symbol
    currencyAfter = false,       -- true = the symbol goes after the amount (250 $)
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
        -- true = every way except a desk needs the item in the inventory; accepting a mission and claiming a mission
        -- call check it again (away from the desk the tablet was opened at, the item is needed then too)
        requireItem = false,
    },
    deskDistance = 3.0,                  -- metres: walking further than this from the desk closes the tablet
    deskScenario = 'PROP_HUMAN_ATM',     -- standing-and-typing animation at a desk (no handheld tablet)
    -- Milliseconds (0-1000) the GTA pause key is blocked after Escape or the close button closes the tablet, so the
    -- same Escape press does not also open the pause menu (0 = off)
    pauseGuardMs = 300,
    -- The Officer UI sidebar order: 'classic' = Home, Mission Board, Dispatch, Unit, Active Mission, Leaderboard,
    -- Challenge, Profile, My options (as before); 'mostUsed' = Home, Mission Board, Active Mission, Dispatch, Unit,
    -- Profile, Leaderboard, Challenge, My options. Only the order changes
    sidebarOrder = 'classic',
    -- true = while the officer is on a run, Active Mission moves to the top of the sidebar, right under Home; false =
    -- it keeps its place (as before)
    activeFirst = false,
    -- true = the Officer UI sidebar shows only the icons (the name shows on hover), leaving the screens more room;
    -- false = icons and names (as before)
    compactSidebar = false,
    -- true = the Supervisor UI sidebar is grouped by task under four headings: People (Department Report: officers,
    -- give points, mission bans, field training), Missions (list, live, cross-department, controls, builder),
    -- Rewards (payouts) and Review (the review queue); false = one list (as before). Only the layout changes
    supervisorByTask = false,
    -- true = the Supervisor UI sidebar shows only the icons (the name shows on hover); false = icons and names
    -- (as before)
    supervisorCompact = false,
    -- The screen the Supervisor UI opens on: 'first' = the first one it shows (as before), 'report' = Department
    -- Report, 'review' = Review Queue, 'live' = Live Missions (a screen the supervisor may not see = the first one)
    supervisorLanding = 'first',
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
Config.QboxAdmins = true                    -- true = your Qbox admins (group.admin, which holds the 'admin'
                                            -- permission) are Crimson-Police admins too; false = only AdminAce
Config.AdminTheme = {          -- Admin UI colours (hex)
    primary = '#a4161a',       -- buttons and highlights
    accent = '#e5383b',        -- links and secondary highlights
    background = '#0b090a',    -- the page behind the panels
    surface = '#161a1d',       -- panels and cards
    text = '#f5f3f4',          -- body text
}
Config.AdminUi = {
    -- true = the Admin UI sidebar shows the everyday screens (Home, Payouts, Missions, Live, Officers, Settings) and
    -- folds the rest under More, whose badge adds up theirs; false = every screen in one flat list
    groupSidebar = true,
    -- true = the Admin UI sidebar and Settings put screens and settings under three plain sections, NPC missions,
    -- Player vs police (real players as suspects) and Police teamwork (cop and cop), with money and the server
    -- after them; false = the sidebar order and the Settings groups as before. Only the layout changes
    groupByPlay = true,
    -- The screen the Admin UI opens on: 'home' = a landing screen with the common jobs (new mission, missions on or
    -- off, pay, points, quick settings, what is wrong) and the live runs; 'payouts' or 'missions' = open straight
    -- on that screen, with no Home screen
    landing = 'home',
    -- The view Admin UI -> Settings opens in: 'simple' = only the everyday settings in plain groups, with plain
    -- labels and help texts ('All settings' is one click away); 'all' = every setting by config.lua section
    settingsView = 'simple',
    -- true = the Home tiles hold the quick forms (switch missions and locations on or off, change pay, give or take
    -- points, the everyday settings), each done right there; false = the tiles only open the full screen
    homeForms = true,
    -- Ready-made reasons shown as buttons under the reason box when setting pay, giving or taking points and in a
    -- mission's Quick edit: a click fills the box, which can still be typed in; {} = no buttons, only typing
    reasonChips = { 'Balance change', 'Event', 'Correction' },
    -- true = the Admin UI uses plain names and puts every screen under seven groups, each with a one-line
    -- description: NPC missions, Player vs police, Police teamwork, Rewards, Permissions, Economy and System; the
    -- rarely used tools fold under More, a search box finds any screen or setting, and a breadcrumb shows where you
    -- are; false = the sidebar as before. Only the layout changes
    plainLayout = false,
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
        forceRecall = true,       -- end one officer's run with no penalty (their department's runs only)
        reviewFlagged = true,     -- approve or void flagged runs involving their department
        handleDisputes = true,    -- disputes about flagged or voided runs in their department
        builderEdit = true,       -- create, edit, record routes and test their own missions
        builderPublish = true,    -- publish their own drafts (testing is optional, see Config.Builder)
        builderArchive = true,    -- archive or restore their own missions
        builderEditAny = false,   -- also edit, publish and archive other people's custom missions
        builderRollback = false,  -- roll a custom mission back to its previous version
        breakEditLock = false,    -- unlock a mission someone else is editing
        missionCalls = true,      -- view, withdraw, page and create mission calls
        issueCommendation = true, -- commend officers of their own department
        reviewProfiles = true,    -- approve or reject pictures and clear bios of their department
        -- change the Mission controls an admin switched on, for their own department only (Config.MissionControls)
        missionControls = false,
    },
    -- Who besides admins may use the Mission Builder Teleport button (admins always may), by department key: minGrade
    -- (that grade or higher) or grades (only those grades). For example sast = { minGrade = 4 } or
    -- the list form bcso = { grades = { 3, 5 } }. Empty = admins only.
    builderTeleport = {},
    -- Extra grants (Admin UI -> Permissions -> Extra grants): a power for people who are not supervisors, by power key
    -- (a key of supervisor above, builderTeleport, fieldTraining = pair and unpair field training, or criminalTablet,
    -- the criminal tablet while Config.CriminalTablet.access is 'granted'). Each power may name departments from a
    -- grade, e.g. departments = { sast = { minGrade = 3 } } (or { grades = { 3, 5 } }), Qbox gangs the same way,
    -- e.g. gangs = { ballas = { minGrade = 2 } }, and single characters by their citizenid, e.g. the list
    -- of citizenids = { 'ABC12345' }. A power switched off above stays off for everyone, an admin-only action can
    -- never be granted and admins still come only from AdminAce and QboxAdmins. Empty = only supervisors (and the
    -- builderTeleport grades), as before
    grants = {},
    -- Always admin-only, whatever is set above: single-mission payouts, clearing
    -- admin payouts, manual awards (apart from the awardPoints Mission control), disputes
    -- about failed runs, voiding any run, seasons, the bounty override, suspensions, reloading
    -- mission files and test runs.
    -- Nobody may approve, void or answer a dispute about a run they took part in.
}

-- ============================================================================
--                                ADMIN CONTROL
-- ============================================================================
-- What admins may do beyond the normal rules, from the Admin UI. Supervisors never get these. Every action is in
-- the audit log; limits are counted from saved rows, so a restart never resets them.
Config.AdminControl = {
    pointAdjust = true,          -- Officers → Give or take points: logged manual awards and deductions
    adjustConfirmAbove = 500,    -- points: a typed confirmation at or above this
    adjustDailyLimit = 0,        -- points one admin may adjust per day (0 = no limit)
    editBuiltins = true,         -- Mission Builder: admins edit built-in missions (saved as an override, same id)
    recordMove = true,           -- Officers → Move record: a re-created character's history to the new citizenid
    bulkMaxRows = 5000,          -- rows one bulk void or restore may change
    cooldownClearsPerDay = 3,    -- cooldown clears per officer per day
    extraRunsMax = 10,           -- extra completions per officer per day
    streakForgiveMax = 7,        -- streak days one forgive may cover
    runTimeAddMax = 600,         -- seconds an admin may add to one live run
    -- Departments → Upload a logo: milliseconds between two 16 KB pieces of the picture. 250 keeps the upload at half
    -- of what FXServer lets one player send per second (it drops a player who sends more); 1 MB then takes about 22 s.
    logoChunkGapMs = 250,
    -- Milliseconds between progress updates of a running bulk job on admins' screens (the start and the end of a job
    -- are always shown at once); 0 = after every batch (the old behaviour).
    jobProgressEveryMs = 500,
    -- Refused mission starts the server remembers for admins (who tried, which mission, why), newest kept. Memory
    -- only: a restart empties the list.
    refusalsKept = 200,
}

-- ============================================================================
--                                 DEPARTMENTS
-- ============================================================================
-- Every entry is used automatically for access, the tablet name, colours and
-- logo watermark, leaderboards, the department challenge, unit invites and the
-- Mission Builder. Add a block, put its logo in logos/, restart. No code or SQL changes.
-- Usually changed here: jobs and supervisorGrade (they decide who uses the tablet and who supervises). Each has:
-- label: the full name, shown in the tablet header
-- enabled: false = turned off: nobody new joins, history and pay stay
-- short: the tag on boards, units and badges
-- jobs: the Qbox job names of this department (as in sc-police / sc-dispatch)
-- supervisorGrade: Qbox grade number: this grade and up are supervisors
-- societyAccount: its Renewed-Banking account, only used when Config.Cash.source = 'society'
-- primary: tablet colour (hex) of the header, buttons, active tab and progress bars
-- accent: tablet colour (hex) of highlights, badges and focus outlines
-- background: tablet colour (hex) of the body
-- surface: tablet colour (hex) of cards, tables and dialogs
-- text: tablet text colour (hex); optional, picked automatically for contrast when left out
-- file: the logo's file in logos/ (or use url)
-- url: an https:// link to the logo instead of a file (optional)
-- watermark: true = draw the logo behind every screen
-- opacity: how solid the watermark is, 0.0 to 0.25
-- size: the watermark's size, as a share of the tablet height (0.05-1)
-- grayscale: true = the logo is drawn in grey
-- personalAccents: the accents an officer may pick for their own tablet (see sast below)
-- missionControls: this department's own Mission controls (optional; see Config.MissionControls)
-- officerOptions: this department's own My options choices (optional; see Config.OfficerOptions)
Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',
        enabled = true,
        short = 'SAST',
        jobs = { 'sast' },
        supervisorGrade = 3,
        societyAccount = 'sast',
        theme = {
            primary = '#1f4e8c',
            accent = '#f2c230',
            background = '#0d1522',
            surface = '#152235',
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
            file = 'sast.png',
            watermark = true,
            opacity = 0.08,
            size = 0.6,
            grayscale = false,
        },
    },
    fib = {
        label = 'Federal Investigation Bureau',
        enabled = true,
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
--                                    NAMES
-- ============================================================================
-- English names an admin gives to ids (Admin UI → Settings → Names). Only these kinds: custody.offence.<id>,
-- profile.commend.kind.<id>, badge.<id>, bonus.<id> and penalty.<id>. A name changes text only, never an id.
Config.Labels = {
    -- ['custody.offence.loitering'] = 'Loitering',
}

-- ############################################################################
--                            PART 2 · NPC MISSIONS
-- Missions against NPCs: mission types, stars, the team size, where people appear and how they act,
-- the route and the map, the draw, mission calls, real calls and alerts, custody, events, the
-- built-in mission tweaks and the Mission Builder.
-- Usually changed here: the mission types' payouts, MissionCalls (how often calls come) and NpcDifficulty.
-- ############################################################################

-- ============================================================================
--                                MISSION TYPES
-- ============================================================================
-- The four mission types every mission belongs to. Usually changed here: payout (or in game, Admin UI -> Payouts).
-- label: the type's name on the tablet
-- points: leaderboard points for a finished run, config only (never editable in-game).
-- payout: default base cash payout in dollars. Supervisors and admins change it in-game;
-- admin-set values are stored permanently in cp_type_payouts.
-- dailyLimit: completed runs of this type per officer per day; nil = no limit.
Config.MissionTypes = {
    patrol = { label = 'Patrol', points = 60, payout = 250, dailyLimit = nil },
    training = { label = 'Training', points = 100, payout = 350, dailyLimit = nil },
    investigation = { label = 'Investigation', points = 160, payout = 600, dailyLimit = nil },
    tactical = { label = 'Tactical', points = 200, payout = 800, dailyLimit = nil },
}

Config.DisabledMissions = {}   -- mission ids to turn off (built-in or custom), e.g. { 'prison_break' }
-- Locations to turn off without removing them, by mission id: their labels (or numbers, 1 = the first), e.g.
-- { prison_break = { 'North gate' } }. Admin UI → Missions has an on/off switch for every mission and location.
Config.DisabledLocations = {} -- locations turned off, by mission id (see above)

-- ============================================================================
--                              DIFFICULTY (stars)
-- ============================================================================
-- Multipliers by a mission's difficulty: index 1, 2 or 3 stars.
-- 1.0 = stars change nothing, so a builder can't raise pay or points by picking 3 stars.
Config.Difficulty = {
    pointsByStars = { 1.0, 1.0, 1.0 }, -- points multiplier for 1, 2 and 3 stars
    cashByStars = { 1.0, 1.0, 1.0 },   -- cash multiplier for 1, 2 and 3 stars
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
-- See also Part 4 (Police teamwork): Cross-department missions.

Config.CrossDepartmentPoints = 1.10    -- points multiplier when 2+ departments are on a run

-- When the team shrinks mid-run (see When someone leaves mid-run)
Config.Rescale = {
    -- NPCs not yet spawned use the tier for the team that's left
    enabled = true,
    keepPayTierFor = { 'real_call', 'force_recall', 'downed' },  -- leave reasons that keep the points and cash tier
}

-- ============================================================================
--                    SPAWNING (where mission people appear)
-- ============================================================================
-- Where a mission's people may appear, so they never pop up next to, behind or all around your officers. A mission
-- asks for its spawn points here: a point that breaks a rule below is skipped, and a mission that gets too few points
-- waits for more. Distances are measured on the map (height does not count).
Config.Spawning = {
    -- false = people appear at the mission's points as before (no rule below is used; only the spawn point check,
    -- which you start yourself, still judges points by ground)
    enabled = true,
    -- Metres: an objective's people appear once an officer is this close to them (50-400, well inside the 424 m a
    -- player's game can see)
    activateRange = 150.0,
    minDistance = 40.0,              -- metres: a point closer than this to any officer is never used
    -- Metres: a point inside a building (walls hide it) closer than this to any officer is never used
    minDistanceIndoor = 15.0,
    -- Degrees: a point further than this off an officer's line to the scene (from where he stands towards the
    -- mission's points, whichever side he came in from) is behind him and never used. Only officers within
    -- activateRange of the point count (180 = off)
    behindAngle = 110.0,
    -- Degrees: all points of one wave fit in a slice this wide seen from the officers, so a wave never comes from every
    -- side at once (360 = off)
    maxSpread = 150.0,
    waveDelayMax = 20,               -- seconds a wave waits for points minDistance away before closer ones are allowed
    -- Metres: once a wave has waited waveDelayMax, a point this close to an officer may be used, never a closer one
    hardMin = 20.0,
    -- Seconds a wave of hostiles, a warrant's associates or a scatter's suspects (Prison Break's inmates, the raids'
    -- cooks and runners) may stay short of points (every point too close to or behind the officers, or a cuffed
    -- suspect still stands on it), counted from when they first had to wait. Once that time has passed, someone of the
    -- fight or objective has appeared and nobody of it is left to fight or catch, the ones that could not be placed
    -- are left out, so it can end (0 = never: they wait until the officers move away)
    leaveOutAfter = 45,
    -- true = a mission may place the next objective's people ahead of time, while your officers are still busy with
    -- the one before it, so they are already there when it starts instead of popping up around the officers (false =
    -- they appear only when their objective starts, as before)
    stageAhead = true,
    -- Metres: a raid's crew waiting in place before the breach stays calm until an officer comes this close to one of
    -- them (officers nearer to the breach entries than to him do not count) or hurts one; then they all wake and
    -- fight at once (0 = only a hurt one wakes them). They always wake when the fight starts
    stageWakeRange = 12.0,
    -- true = a warrant's armed associates appear only when an officer knocks, on their points 15 m or more from every
    -- officer, out of the officers' sight first and never behind the one at the door, instead of waiting beside the
    -- door from the start (false = they wait at their points from the start, as before)
    associatesAtKnock = true,
    -- Metres, nearest and furthest: a parked car's returning driver and a stolen car's thief appear this far from the
    -- car, on a footpath the game of the officer at the car finds in front of him, out of his sight first, and walk up
    -- to the car once that game has put them on the ground (no answer from his game: round the car at this distance,
    -- never closer than the nearest to any officer). With enabled = false: 14 m and 30 m round the car, as before
    contactRing = { 25.0, 40.0 },
    -- Metres: a scene (Suspicious Activity's people and car, each parked car of Parking Patrol) appears once an
    -- officer is within activateRange of it while every officer is further than the mission's approach distance
    -- (where the people react, 25 m) plus this from it, so it is already there before you are on top of it (after
    -- waveDelayMax: hardMin, never closer)
    sceneOutside = 10.0,
    -- Seconds a scene waits for officers standing closer than that before it appears anyway, with one warning in the
    -- console naming the mission and the place (move its start further out); 0 = it waits until they step back
    sceneWaitMax = 45,
    -- When Hostage Rescue's hostages appear: 'objective' = when their own objective starts (after the fight), on
    -- their points once an officer is near and every officer is minDistanceIndoor (15 m) or more from them;
    -- 'runStart' = when the run starts, before the fight, as before
    hostagesAt = 'objective',
    -- Seconds the hostages wait for officers standing closer than minDistanceIndoor before they appear on their points
    -- anyway (they are tied up and unarmed, and the rescue cannot go on without them), with one warning in the
    -- console; 0 = they wait until the officers step back
    hostagesWaitMax = 10,
    -- Metres (0-1.5) a car made on a point of the mission's road itself (Traffic Enforcement's violator, a race loop's
    -- waypoint, Armored Truck Escort's truck and ambush cars) is lifted over the road there, so it never starts inside
    -- the road surface (0 = on the road's own height). A mission's own pursuit car points are used as written
    vehicleLift = 0.5,
    -- Metres (0-400): a violator that comes after another one on the same road (Traffic Enforcement's second violator)
    -- appears this far up the road from the officer furthest up it, so it drives towards your officers wherever they
    -- worked the first stop (0 = at the first violator's point, as before)
    secondViolatorUpstream = 200.0,
    -- true = an Armored Truck Escort ambush car never appears on, next to (within minDistance) or behind the truck, nor
    -- on another vehicle: its slot slides further along the route instead, ahead of the truck and away from your
    -- officers (a lead car included). false = the cars use their ambush point's own slots only (they still wait for
    -- officers standing on them), and appear there even once the truck is past it, as before
    ambushAheadOnly = true,
    -- true = of the points a wave may use, the ones your officers cannot see (behind a building, a container or a
    -- vehicle, as the nearest officers' own games check it) are used first, so people appear out of sight instead of
    -- in the open in front of you; seen points are still used when there are not enough hidden ones. A Manhunt clue
    -- closer than minDistance to an officer appears only where those games say no officer can see it, or in sight at
    -- hardMin or further once it has waited waveDelayMax (false = the mission's own order and nobody is asked: such a
    -- clue waits until the officers are minDistance away, or hardMin after waveDelayMax)
    preferHidden = true,
    -- Milliseconds the server waits for the officers' games to say what they can see (100-5000); no answer in time =
    -- every point counts as seen (the distance rules above still apply). Also how long it waits for the footpath point
    -- of a returning driver or a thief (contactRing)
    losTimeoutMs = 1500,
    -- How a point is checked against the ground under it: each range is the lowest and highest height in metres of
    -- the point in the mission file over the ground there (used by the spawn point check in Admin UI -> Testing and by
    -- place below)
    ground = {
        -- Metres, lowest and highest: a person's point fits from 0.3 m under to 1.6 m over the ground (a standing
        -- person's point is about 1 m over it)
        pedAbove = { -0.3, 1.6 },
        vehicleAbove = { -0.2, 1.5 },    -- metres, lowest and highest: the same for a vehicle's point
        propAbove = { -0.1, 0.5 },       -- metres, lowest and highest: the same for an object's point (a clue, a stash)
        -- Metres (0-10): a point outside its range is put on the ground when that moves it at most this far up or
        -- down; one further off is reported as under the ground or floating
        snapWithin = 3.0,
    },
    -- Milliseconds (500-30000) a game waits for the ground around a point to load before it checks the point
    collisionTimeoutMs = 6000,
    -- Milliseconds (500-30000) a game waits for the inside of a building (a bank, a store) to load; still not loaded
    -- after this = the point is reported as "inside not loaded"
    interiorTimeoutMs = 5000,
    -- true = every new person, vehicle and object of a mission waits frozen where it appears until the game of an
    -- officer near it has checked the ground there and put it on the ground (by the ranges above); a point under the
    -- ground, floating, in water or in a wall is reported back instead and another of the mission's points is tried.
    -- false = they appear on the file's points as before
    place = true,
    -- Milliseconds (1000-60000) a new person, vehicle or object waits frozen for an officer's game to put it on the
    -- ground, counted while an officer is within activateRange of it and no officer's game is checking it (a big
    -- wave's later ones wait their turn there, at most 34 s plus collisionTimeoutMs and interiorTimeoutMs); then
    -- onTimeout
    placeTimeoutMs = 8000,
    -- How many times (0-5) a point an officer's game reports bad (under the ground, floating, in water, in a wall) is
    -- swapped for another point the mission may use there; after that, or with no other point, the last one is used
    -- as it is (one warning in the console)
    retries = 2,
    -- 'unfreeze' = a person, vehicle or object that no officer's game has put on the ground within placeTimeoutMs is
    -- let go where it stands, as before; 'delete' = it is removed and the mission treats it as killed (a hostage or an
    -- escort's truck removed this way fails that objective). A person or vehicle the mission only moved, such as a
    -- warrant's suspect who gives up at the door or the prisoner transport put on its parking point, is always let go
    -- where it stands
    onTimeout = 'unfreeze',
    -- true = a console line for each point skipped (shown while Config.Debug is on) and a warning when a wave had to
    -- use closer points
    log = true,
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

-- How NPCs feel. It never changes points or cash. Each preset (and custom) has:
-- accuracyAdd: added to armed NPCs' accuracy (0-100 scale; -8 = a little worse aim)
-- armourAdd: armour points added to armed NPCs (0 = none)
-- healthMult: × NPC health (1.15 = 15 % more)
-- surrenderMult: × how readily an NPC gives up (1.3 = gives up more easily, 0.7 = holds out longer)
-- fleeMult: how long runners keep running (Config.Flee): 1.2 = 20 % longer
Config.NpcDifficulty = {
    preset = 'normal',               -- 'easy' | 'normal' | 'hard' | 'custom'
    -- the values used when preset = 'custom'
    custom = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
    presets = {
        easy = { accuracyAdd = -8, armourAdd = 0, healthMult = 0.85, surrenderMult = 1.3, fleeMult = 0.8 },
        normal = { accuracyAdd = 0, armourAdd = 0, healthMult = 1.0, surrenderMult = 1.0, fleeMult = 1.0 },
        hard = { accuracyAdd = 8, armourAdd = 15, healthMult = 1.15, surrenderMult = 0.7, fleeMult = 1.2 },
    },
}

-- How hard armed mission NPCs fight back. Only mission NPCs and the officers on their run are changed, and only
-- while the run is live. For every number here: lower = easier for your officers.
Config.NpcCombat = {
    enabled = true,                  -- false = NPCs fight as GTA makes them (every value below is ignored)
    -- The only weapons a mission NPC is ever given. Automatic weapons (SMGs, rifles, machine guns) are never given,
    -- even when one is added here.
    weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_HEAVYPISTOL', 'WEAPON_PUMPSHOTGUN' },
    -- A mission that names a weapon outside the list above gets the weapon this list gives for it...
    replace = {
        WEAPON_MICROSMG = 'WEAPON_PISTOL',
        WEAPON_SMG = 'WEAPON_COMBATPISTOL',
        WEAPON_ASSAULTRIFLE = 'WEAPON_HEAVYPISTOL',
    },
    fallback = 'WEAPON_PISTOL',      -- ...or this one when the list has none for it
    ammo = 60,                       -- rounds each armed NPC gets
    accuracyScale = 0.7,             -- NPC accuracy (after the team size and Config.NpcDifficulty) times this...
    accuracyMax = 18,                -- ...and never above this (0-100; bosses and shots from cars too)
    shootRate = 60,                  -- how fast NPCs pull the trigger (0-1000)
    firingPattern = 'single',        -- 'single' (one shot at a time), 'burst' (short bursts), 'delayed' (a pause
                                     -- before each shot) or 'default' (GTA picks)
    abilityMax = 1,                  -- combat skill at most: 0 poor, 1 average, 2 professional
    noCharge = true,                 -- NPCs never charge at officers
    aiDamage = 0.5,                  -- damage of NPC bullets (1.0 = normal GTA damage, 0.5 = half)
    aiMeleeDamage = 0.5,             -- damage of NPC punches and melee weapons (1.0 = normal)
    reassertAiDamage = true,         -- true = the run's NPC damage value is set again every second (other scripts
                                     -- such as Crimson-Contracts share it); false = set once at the start (the old way)
    officerDefense = 1.0,            -- damage officers on a run take from every weapon, players' too (1.0 = off)
    noCriticalHits = true,           -- officers on a run take no extra headshot damage (it hurts like a body shot)
    cancelLethalHeadshots = true,    -- the server drops a one-shot kill by a mission NPC on an officer of its run...
    lethalCancelAbove = 0.75,        -- ...who still has at least this share of his health (0.25-1, 0.75 = three
                                     -- quarters). The shot that finishes off a hurt officer always counts
    playerHitDropsProtection = false, -- true = an officer on an NPC mission loses noCriticalHits and officerDefense for
                                      -- the rest of that run once a real player who is not on the run shoots him
}

-- How long a suspect who runs from your officers can keep running. GTA's NPCs never tire, so the server times every
-- mission NPC that runs on foot (time in a car does not count): first a sprint, then a jog, then a walk, then worn
-- out, and he slows down to match. A worn-out runner gives up when an officer gets close. Config.NpcDifficulty's
-- fleeMult stretches every time here ('hard' runners last 20 % longer, 'easy' ones 20 % shorter).
Config.Flee = {
    enabled = true,                  -- false = suspects run as GTA makes them: they never tire
    sprintSeconds = 10,              -- seconds a runner sprints before he slows to a jog
    jogSeconds = 12,                 -- seconds he then jogs before he slows to a walk
    walkSeconds = 8,                 -- seconds he then walks before he is worn out
    -- Each suspect lasts up to this share longer or shorter, rolled once per suspect from the run's seed (0.25 = 25 %,
    -- 0 = every suspect lasts the same)
    jitter = 0.25,
    -- Seconds with no officer within recoverRange before a runner gets his breath back and sprints again
    recoverSeconds = 20,
    recoverRange = 60.0,             -- metres: an officer this close stops a runner from getting his breath back
    armedTire = true,                -- false = a suspect who carries a weapon you can see never tires
    jogRate = 0.95,                  -- a jogging runner's speed: 1.0 = a normal jog, 0.9 = 10 % slower (0.5-1.0)
    walkRate = 0.85,                 -- a walking or worn-out runner's speed: 1.0 = a normal walk (0.5-1.0)
    windedClipset = true,            -- true = a tired runner looks it: he jogs, then walks winded
    -- What a worn-out runner does when an officer comes within giveUpRange: 'surrender' (he gives up and kneels),
    -- 'handsUp' (he gives up and stands with his hands up) or 'walk' (he walks on and never gives up on his own)
    exhausted = 'surrender',
    giveUpRange = 30.0,              -- metres: a worn-out runner gives up when an officer is this close (5-100)
    -- true = a runner, cook or inmate who scatters (Gang Hideout Raid, Drug Lab Raid, Prison Break) flees along the
    -- escape route that starts nearest where he appears, so nobody runs back across the site past your officers
    -- (routes that start about as near, within 5 m, take turns); false = the routes take turns wherever he appears
    nearestRoute = true,
}

-- ============================================================================
--                              ROUTE TO THE START
-- ============================================================================

Config.Route = {
    -- true = officers must follow the GPS route to the mission start; leaving it for abandonAfter seconds ends their
    -- run as Abandoned. false = the route is still shown, but leaving it never ends a run. A run keeps the value it was
    -- accepted with; a test run follows its own Start route switch
    required = true,
    sampleEvery = 50.0,    -- metres between points taken from the GPS route
    reportEvery = 2,       -- seconds between client reports
    reportTimeout = 10,    -- no report for this long counts as off route
    maxDeviation = 120.0,  -- metres from the line before a participant is off route
    warnAfter = 10,        -- seconds off route before the warning
    abandonAfter = 30,     -- seconds off route in one stretch before Abandoned (back on route resets it)
    maxRecalcs = 2,        -- Recalculate route taps per participant per run
    maxDrift = 1000.0,     -- server check: metres further from the start than the closest they have been
    -- metres: once the run is In progress, an officer still on his way follows the action instead of the start: his
    -- GPS leads to the objective, his route is no longer checked, and he arrives this close to the objective (or at
    -- the start). 0 = only the start counts, as before
    lateArriveRange = 150.0,
    -- seconds: an officer who follows the action gets this long from then on to reach it, so a partner who left late
    -- is not dropped by the start timeout (Config.Limits.startTimeout) while he chases. Never less time than he had.
    -- The HUD and the tablet show the time left in the last 2 minutes. 0 = he keeps the start deadline, as before
    followActionSeconds = 300,
}

-- ============================================================================
--                                 MAP MARKERS
-- ============================================================================
-- How the objective your officers are on shows on their map: one blip (for a fight or a search area, a circle and its
-- centre) with one GPS line to it. While an officer still drives to the start, the line to the start is the only one he
-- gets from us; one who has set a waypoint of his own gets no objective line. Under kinds, each kind of blip has a
-- sprite (the blip's picture, by its id), a colour (a colour id: 5 = yellow, go here; 1 = red, enemy; 17 = orange,
-- fleeing or needs a follow-up; 3 = blue, friendly; 2 = green, safe point) and a scale (its size, 1.0 = normal).
-- nextScale, bossScale, surrenderedScale, followUpColour and setbackColour are the same for the next checkpoint, a
-- boss, a suspect who gave up (the same size near you and far away), a point to follow up and a device set back.
-- Sprite and colour ids: docs.fivem.net/docs/game-references/blips/
Config.Markers = {
    enabled = true,              -- false = no objective blip or line from Crimson-Police (the missions' own blips stay)
    route = true,                -- false = the objective blip shows, but no GPS line to it
    routeColour = 5,             -- colour of the GPS line to an objective (5 = yellow, 1 = red, 3 = blue)
    routeOffWithin = 40.0,       -- metres: the line turns off this close to the objective (inside a circle: off)
    trackEvery = 2,              -- seconds between the positions the server sends of moving objectives (cars, people)
    farTargets = true,           -- true = a car or suspect too far away for your game shows where the server says
    shortRange = false,          -- false = objective blips show at the edge of the radar however far away they are
    flashSeconds = 5,            -- seconds a new objective blip flashes (0 = no flash)
    setbackFlash = true,         -- true = a device that was set back (Drug Lab Raid: Ventilate) flashes until fixed
    category = 2,                -- the map legend: 2 = shows the distance to the blip, 1 = no distance
    areaAlpha = 80,              -- how solid the map circles are: 0 = invisible, 255 = solid
    -- true = the yellow Mission start pin stays on the map for the whole drive, with a GPS line of its own while your
    -- waypoint to the start is gone (you cleared it or set your own); false = only the waypoint shows the start
    startBlip = true,
    startCircleMin = 200.0,      -- metres: a mission start at least this wide shows as a circle on the map (Manhunt)
    -- What Radio Silence hides once the officers are at the start: 'area' = each objective's circle or its one blip
    -- stays (of several doors or devices only your nearest), without a GPS line and without blips on people and cars;
    -- 'none' = every objective blip; 'full' = nothing. The drive to the start, the prisoner van and the tow truck
    -- always show
    radioSilence = 'area',
    -- seconds: with 'area', a 200 m circle shows where a moving suspect or car was, moved this often (0 = off)
    radioSilenceLastKnown = 0,
    hudLine = true,              -- true = the HUD shows the objective's name and how far it is
    objectiveGps = true,         -- true = an Objective GPS button on the tablet puts a waypoint on the objective
    serviceVehicles = true,      -- true = a prisoner van or tow truck coming to you shows on the map
    -- How each kind of blip looks: sprite (blip id), colour id and size. Yellow = go here, red = enemy, orange =
    -- fleeing or needs a follow-up, blue = friendly, green = safe point
    -- sprite: the blip's picture, by its blip id (docs.fivem.net/docs/game-references/blips/)
    -- colour: the blip's colour id (5 = yellow, 1 = red, 17 = orange, 3 = blue, 2 = green)
    -- scale: the blip's size (1.0 = normal, 0.5 = half)
    -- nextScale: the size of the next checkpoint's blip
    -- bossScale: the size of a boss's blip
    -- surrenderedScale: the size of a suspect who gave up (the same near you and far away)
    -- followUpColour: the colour id of a point to follow up
    -- setbackColour: the colour id of a device that was set back
    kinds = {
        start = { sprite = 162, colour = 5, scale = 1.0 },                      -- the mission start
        checkpoint = { sprite = 1, colour = 5, scale = 1.0, nextScale = 0.7 },  -- a checkpoint (nextScale: the next)
        searchArea = { sprite = 162, colour = 5, scale = 0.9 },                 -- the centre of a search area
        clue = { sprite = 1, colour = 5, scale = 0.7 },                         -- a clue in a search area
        fightArea = { sprite = 84, colour = 1, scale = 0.9 },                   -- the centre of a fight
        hostile = { sprite = 1, colour = 1, scale = 0.6, bossScale = 0.9 },     -- an armed hostile (bossScale: a boss)
        -- a suspect: stopped or armed (surrenderedScale: one who gave up)
        suspect = { sprite = 1, colour = 1, scale = 0.7, surrenderedScale = 0.6 },
        fleeing = { sprite = 1, colour = 17, scale = 0.8 },                     -- a suspect on the run
        vehicle = { sprite = 225, colour = 1, scale = 0.9 },                    -- a suspect's car
        contact = { sprite = 280, colour = 5, scale = 0.7 },                    -- a person to talk to
        contactVehicle = { sprite = 225, colour = 5, scale = 0.7 },             -- a car to check
        escort = { sprite = 67, colour = 3, scale = 1.0 },                      -- the vehicle you escort
        destination = { sprite = 38, colour = 5, scale = 0.9 },                 -- where the escort goes
        hostage = { sprite = 280, colour = 3, scale = 0.8 },                    -- a hostage
        safePoint = { sprite = 38, colour = 2, scale = 0.9 },                   -- where the hostages go
        scene = { sprite = 162, colour = 5, scale = 0.9 },                      -- a scene to work
        point = { sprite = 1, colour = 5, scale = 0.8, followUpColour = 17 },   -- a point to check (or follow up)
        device = { sprite = 1, colour = 5, scale = 0.8, setbackColour = 17 },   -- a device to work (or one set back)
        prisonerVan = { sprite = 285, colour = 3, scale = 0.8 },                -- a prisoner van coming to you
        towTruck = { sprite = 68, colour = 3, scale = 0.8 },                    -- a tow truck coming to you
        objective = { sprite = 162, colour = 5, scale = 0.9 },                  -- any other objective
    },
}

-- ============================================================================
--                                 RANDOM DRAW
-- ============================================================================

Config.Draw = {
    avoidLast = 1,              -- never repeat the last mission in that type
    avoidLastLarge = 2,         -- skip the last two when the pool has largePool+ missions
    largePool = 4,              -- missions in a type's pool that make it large (see avoidLastLarge)
    playerClearance = 75.0,     -- skip locations with a non-participant within this many metres
    zoneClearance = 200.0,      -- skip a location within this many metres of another active run's location
                                -- (any mission), while another is free
    hardClearance = 100.0,      -- never draw a location within this many metres of another active run's
                                -- location, even when nothing else is free (0 = off: zone clearance only)
    avoidLastLocations = 2,     -- skip the last N locations any participant played in this mission, while
                                -- another is free
    locationFreshness = 3600,   -- seconds: a location used server-wide this recently gets half the weight
}

-- ============================================================================
--                           DISPATCH (MISSION CALLS)
-- ============================================================================
-- Tablet-only NPC calls. The first unit to claim one gets a random mission of that type that starts in
-- the call's area. Mission calls are never sent to SC-Dispatch, and real calls always come first.
Config.MissionCalls = {
    enabled = true,                  -- true = the server posts NPC mission calls to the tablet
    checkEvery = 10,                 -- seconds between server checks
    -- Types that can be called: how often (weight) and priority (1 = highest)
    -- weight: how often this type is called against the others (5 vs 2 = two and a half times as often; 0 = never)
    -- priority: 1 = highest; a higher-priority call shows first on the board
    types = {
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
    minLocationsPerArea = 3,                                   -- locations the area needs before a call names it
    countyWeightKm = 2.0,                                      -- county-wide draws weight locations by 1 / (1 + km / this)
    titles = { patrol = 8, investigation = 6, tactical = 6 },  -- flavour titles per type (mc.title.<type>.<n>)
    eligibilityCache = 10,                                     -- seconds an officer's cached eligibility may be reused
    recentShown = 5,                                           -- calls in the Recent calls list
    -- A claim dropped before anyone reached the start reopens once
    -- enabled: false = it never reopens
    -- time: seconds the reopened call stays open
    reopen = { enabled = true, time = 120 },
    -- +10% of P (points only) for reaching the start within distance ÷ speed (m/s) + grace (seconds)
    -- Server-posted calls only: paged and staff-created calls never earn it.
    -- pctOfP: the bonus as a share of P (0.10 = +10 %)
    -- speed: metres per second the target time allows for the distance
    -- grace: seconds added to the target time
    rapidResponse = { pctOfP = 0.10, speed = 20.0, grace = 45 },
    pageTime = 30,                   -- seconds a paged call is offered only to the paged unit
    -- seconds between calls created by the same supervisor (the issuer's own unit can never be paged, and can't claim
    -- a call the issuer paged or created)
    staffCooldown = 120,
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
--                                  REAL CALLS
-- ============================================================================

Config.Calls = {
    npcCallPrefix = 'npccall-', -- SC-NPCPolice call ids start with this; those calls never end a run
    -- about a participant: not real calls for their partners
    ownRunCallPrefixes = { 'playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_' },
    dodgeWindow = 60,           -- un-marking responding within this many seconds makes it a normal abandon
    respondingExpiry = 1200,    -- seconds; a responding entry with no update expires (auto-cleared calls fire no event)
}

-- ============================================================================
--                              ALERT SUPPRESSION
-- ============================================================================
-- The flag is the crimsonArena state bag, which SC-Dispatch and SC-Ambulance
-- already check; its name is fixed in those resources, so it is not configurable.
Config.Alerts = {
    -- clear a shots-fired call from a participant within this many metres of their mission (person-down and dead
    -- calls are cleared while the flag is on)
    backstopRadius = 300.0,
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
--                          POLICE ACTIONS AND CUSTODY
-- ============================================================================
-- See also Part 3 (Player vs police): a real suspect's cuffs and detain are timed in Config.RealSuspects.

-- What officers do with the people and cars of a mission (talk, frisk, search, cite, arrest, impound) and the vans
-- that come for them. Usually changed here: times (how long each action takes) and the chances.
-- The prisoner van (transport), tow truck (tow) and coroner van (coroner) have:
-- model: the vehicle model it comes in
-- driver: the ped model that drives it
-- spawnDistance: metres { nearest, furthest } from the scene where it appears
-- leaveAfter: seconds after the objective that called it ends before it drives off
-- bagProp: the body bag prop the coroner uses
-- enabled: false = no tow truck comes; the car fades out instead
Config.Custody = {
    times = {                        -- seconds each action's progress bar takes
        talk = 4,                    -- talk to a person and check their ID
        frisk = 4,                   -- frisk a person
        detain = 3,                  -- detain (cuff) a person
        searchPerson = 4,            -- search a person
        lookInside = 2,              -- look inside a car
        runPlate = 3,                -- run a plate
        inspect = 3,                 -- inspect a car
        orderOut = 2,                -- order a person out of a car
        searchVehicle = 8,           -- search a car
        warn = 2,                    -- give a verbal warning
        cite = 6,                    -- write a citation
        release = 2,                 -- release a person
        impound = 10,                -- impound a car
        noAction = 1,                -- no action
        explain = 4,                 -- explain the citation
        escort = 1,                  -- start or stop escorting a person
        seat = 2,                    -- place a person in a vehicle
        handover = 4,                -- hand a person over to the prisoner van
    },
    reach = {                        -- metres, checked with server-side coordinates
        person = 2.0,                -- to act on a person on foot (every other action)
        frisk = 1.5,                 -- to frisk a person
        vehicle = 3.0,               -- to act on a car or a person seated in one
        plateFromVehicle = 20.0,     -- Run plate from the driver seat of any vehicle
        seatVehicle = 5.0,           -- to seat a person in a vehicle
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
    -- Metres (10-100): a prisoner van, tow truck or coroner van never appears or is put down closer than this to any
    -- player. After serviceTimeout with its parking point taken by an officer it comes to a road point beside the scene
    -- instead (or waits until the officer steps away); a tow truck that never got a road point fades the car out
    serviceClearance = 30.0,
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
        -- on a person or driver
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
        vehicle = { 'expired_meter', 'no_permit', 'no_parking', 'hydrant', 'loading_zone' },  -- on a parked car
    },
    -- Hidden truths, as weights (how likely each is against the others; 0 = never). A mission objective names the
    -- set (profileSet), then the person or car's role (person, driver, passenger, vehicle).
    -- clean: nothing to find
    -- minor: a small offence worth a citation
    -- warrant: wanted on a warrant (arrest)
    -- narcotics: carries drugs (arrest)
    -- tools: carries burglary tools (arrest)
    -- armed: carries an illegal weapon (arrest); the only truth that can turn hostile
    -- suspended: drives on a suspended licence
    -- intoxicated: drives drunk or high
    -- evading: fleeing the police (arrest)
    -- legal: a car with nothing wrong
    -- stolen: a stolen car (impound)
    -- violation: a parking violation (see parkingRules)
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
    -- Demeanour weights by truth (how likely each is against the others). Only armed people can be hostile.
    -- compliant: does what officers say
    -- nervous: complies, but shows it
    -- evasive: avoids questions and stalls
    -- runner: runs when officers come close
    -- hostile: draws a weapon
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
        metered = 'cite',            -- an expired meter
        permit = 'cite',             -- a permit-only spot
        no_parking = 'impound',      -- a no-parking spot
        hydrant = 'impound',         -- in front of a hydrant
        loading = 'impound',         -- a loading zone
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
--                                SPECIAL EVENTS
-- ============================================================================

-- Extra fun on top of the missions: the Type of the Day, twists officers choose and the Weekly Boss. Usually
-- changed here: todMultiplier and the twists' points and cash.
Config.Events = {
    typeOfTheDay = true,     -- true = one mission type a day earns the points multiplier below
    todMultiplier = 2.0,     -- points only
    -- share of runs that also get one random twist on top of the ones the officers chose (0 = never: officers
    -- choose their own twists when they take a mission; 0.25 = one run in four)
    modifierChance = 0,
    armoredArmour = 50,      -- Armored Hostiles: extra armour on armed NPCs
    timeCrunchCut = 0.25,    -- Time Crunch: share of the time limit removed
    -- The Weekly Boss: one big mission on the days below
    -- enabled: true = the Weekly Boss shows on the Mission Board on its days; false = never
    -- days: the weekdays it is on, in lower case ('monday' to 'sunday'), the rest of the week it is off
    -- points: leaderboard points for finishing it
    -- payout: dollars for finishing it (until an admin sets a mission payout for it)
    weeklyBoss = { enabled = true, days = { 'friday', 'saturday', 'sunday' }, points = 500, payout = 2500 },
    -- Twists the officers may choose when they take a mission from the Mission Board or a mission call (the unit
    -- leader decides for the unit). Each chosen twist adds its own reward and they stack, up to twistMaxPoints and
    -- twistMaxCash. Rewards are paid only for a completed run. Never on the Weekly Boss, test runs or
    -- Cross-Department Missions.
    twists = {
        armored_hostiles = {     -- armed NPCs get armoredArmour extra armour (offered only where armed NPCs spawn)
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.25,       -- share of P it adds (0.25 = +25 % points; 0 = no extra points)
            cash = 1.25,         -- cash multiplier (1.25 = x1.25 cash; 1.0 = no extra cash)
        },
        time_crunch = {          -- the time limit is timeCrunchCut shorter
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.20,       -- share of P it adds (0.20 = +20 % points; 0 = no extra points)
            cash = 1.20,         -- cash multiplier (1.20 = x1.20 cash; 1.0 = no extra cash)
        },
        radio_silence = {        -- the map hides what Config.Markers.radioSilence says
            enabled = true,      -- false = officers cannot choose it and it is never rolled
            points = 0.25,       -- share of P it adds (0.25 = +25 % points; 0 = no extra points)
            cash = 1.25,         -- cash multiplier (1.25 = x1.25 cash; 1.0 = no extra cash)
        },
    },
    twistMaxPoints = 0.70,   -- the most all chosen twists add together, as a share of P (0.70 = +70 % points)
    twistMaxCash = 1.95,     -- the highest cash multiplier all chosen twists give together (the multipliers multiply)
}

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================
-- Change built-in missions without editing their files, so the change survives updates. Every tweak is
-- checked by the same rules as the file; a tweak that breaks one is ignored with a console warning.
-- Allowed keys: cooldown, timeLimit, startTimeout, disabledLocations (labels), peds, vehicles, weapons.
-- weapons replaces every weapon list of the mission (waves, ambushes, associates); a boss carries its last one.
Config.MissionTweaks = {
    -- prison_break = { cooldown = 1800, timeLimit = 720, disabledLocations = { 'North gate' } },
    -- gang_shootout = { peds = { 'g_m_y_lost_01' }, weapons = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL' } },
}

-- ============================================================================
--                               MISSION BUILDER
-- ============================================================================
-- Block setting ranges and defaults are in config/blocks.lua.
Config.Builder = {
    enabled = true,                            -- true = supervisors may use the Mission Builder (admins always can)
    maxHostiles = 40,                          -- armed NPCs per mission across all blocks, before scaling
    maxBlocks = 6,                             -- objective blocks in one custom mission at most
    minLocations = 1,                          -- locations a new custom mission needs before it can be published
                                               -- (more locations = it repeats less; 3 or more is a good habit)
    minLocationsOverride = 3,                  -- locations an edited built-in mission must keep before it can be
                                               -- published
    minLocationGap = 100.0,                    -- metres between locations of one mission
    minSpawnFromStart = 30.0,                  -- metres between any spawn point and the start point
    spawnMargin = 40.0,                        -- metres outside the start circle that armed NPCs of a new custom mission
                                               -- keep (shootout, boss, ambush and pursuit cars, door associates);
                                               -- files published before still load, with a warning
    maxPointFromStart = 300.0,                 -- metres a location's points may be outside its start circle: a
                                               -- point further away (left behind by a moved start) blocks
                                               -- publishing; routes, patrol checkpoints, escort ambush points and
                                               -- flee paths are exempt (50-2000)
    -- A builder's own bonuses and penalties: flat ones at most 50 points (points), percentage ones at most 25% of P
    -- (share, 0-1)
    bonusCap = { points = 50, share = 0.25 },
    requireTestToPublish = false,              -- true = supervisors may publish only a draft that passed a test
                                               -- (admins never need one); false = testing is optional for everyone
    supervisorItems = false,                   -- false = only admins may put items in a custom mission (items a run
                                               -- hands out can be used or sold before they are taken back); true =
                                               -- supervisors too
    useMyPosition = true,                      -- true = the Locations step has "Set start here" and "Add here":
                                               -- the point goes where you stand (or your vehicle is) and the tablet
                                               -- stays open; false = points are only placed with the aim tool
    autoFill = true,                           -- true = a spawn point row has "Fill N for me": the game proposes
                                               -- the points around the start, outside its keep-out, on safe ground
                                               -- (you keep them, try again or place them by hand); false = no button
    autoFillRing = { 15.0, 80.0 },             -- metres beyond the keep-out that "Fill N for me" puts points at
                                               -- (nearest, furthest)

    quickWizard = true,                        -- true = the New mission button opens a 4-step wizard (What,
                                               -- Where, Check, Publish): pick a template, stand at the spot, fill
                                               -- the points, publish; Open the full editor is on every step;
                                               -- false = the New mission dialog and the full editor only
    foldAdvanced = true,                       -- true = each block's settings show the few that matter
                                               -- (e.g. a shootout: waves, enemies per wave, weapons, difficulty)
                                               -- and fold the rest under "More settings"; false = every setting
                                               -- is shown open, as before

    -- On: a Teleport button next to each point on the Locations step puts you on the ground there (the server reads
    -- the saved point and logs it). Admins always; others only with Permissions.builderTeleport. Off: no button.
    teleport = true,

    -- built-in missions a new mission can start from: it copies their type, difficulty, team, times, bonuses,
    -- penalties and objectives, but none of their locations (you place your own). Empty = no templates
    templates = {
        'beat_patrol',
        'business_check',
        'parking_patrol',
        'pursuit_sim',
        'manhunt',
        'warrant_service',
        'gang_shootout',
        'hostage_rescue',
        'armored_truck_escort',
        'bomb_disposal',
    },
    testAtMaxTier = true, -- a test counts as passed only at the tier maxOfficers reaches
    editLockMinutes = 30, -- one editor at a time; renewed while they keep editing
    defaultTeam = { patrol = 2, training = 2, investigation = 2, tactical = 4 }, -- most officers a new mission
    -- starts with, by its type (the builder can change it on Details)
    autosaveSeconds = 30,
    exportPath = 'missions/custom/',           -- folder (inside missions/custom/) for missions made in the Builder.
                                               -- Another folder must be created by hand first, with archived,
                                               -- overrides, overrides/archived and deleted inside it (the server
                                               -- cannot create folders on Linux)
    keepBackups = true,                        -- keep <mission_id>.v<version>.lua.bak on every publish
    route = {                                  -- route recording (see Mission Builder, Route recording)
        snapEvery = 25.0,       -- metres between samples while recording
        maxOffRoad = 8.0,       -- samples further than this from a road node are rejected
        turnAngle = 30.0,       -- heading change (degrees) that keeps a waypoint
        maxGap = 150.0,         -- at least one waypoint this often, in metres
        minLength = 800.0,      -- metres a recorded route must be at least
        maxLength = 8000.0,     -- metres a recorded route may be at most
        minStartEndGap = 300.0, -- open routes: start and end at least this far apart
        loopClose = 50.0,       -- a race loop must end this close to its start
        undoMetres = 100.0,     -- Backspace removes this much of the recording
        testDriveTimeout = 30,  -- seconds to reach each waypoint in a test drive
        patrolSpacing = 300.0,  -- a patrol (checkpoint route) recorded by driving is saved as checkpoints about
                                -- this many metres apart along the drive, not as a road route
    },
    allowed = {                 -- the only models, weapons and animations builders can pick
        -- no automatic weapons: an NPC never gets one (Config.NpcCombat), so the Builder never offers one
        weapons = {
            'WEAPON_PISTOL',
            'WEAPON_COMBATPISTOL',
            'WEAPON_HEAVYPISTOL',
            'WEAPON_PUMPSHOTGUN',
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
        -- base-game vehicle models a builder may give suspects and hostiles
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
        escortVehicles = { 'stockade', 'stockade3' },  -- vehicle models an Escort mission may protect
        -- what a builder may have a person do at a point: clipboard, search, kneel, mechanic, notepad or photo
        animations = { 'clipboard', 'search', 'kneel', 'mechanic', 'notepad', 'photo' },
    },
    noBuildZones = {            -- no spawn point, marker or route waypoint inside these
        { label = 'Mission Row PD and FIB HQ', coords = vec3(470.63, -974.11, 30.18), radius = 120.0 },
        { label = 'Sandy Shores BCSO', coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
        { label = 'SASP HQ', coords = vec3(1560.38, 815.76, 76.21), radius = 80.0 },
        { label = 'Pillbox Hill Medical', coords = vec3(308.19, -595.35, 43.29), radius = 100.0 },
        { label = 'Paleto Bay Medical', coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
        -- the whole prison, every tower
        { label = 'Bolingbroke Penitentiary', coords = vec3(1691.5, 2578.5, 44.7), radius = 215.0 },
        { label = 'Fort Zancudo', coords = vec3(-2075.0, 3225.0, 33.0), radius = 320.0 },             -- the base: 4 circles
        { label = 'Fort Zancudo south-east', coords = vec3(-1875.0, 3050.0, 33.0), radius = 320.0 },
        { label = 'Fort Zancudo south-west', coords = vec3(-2300.0, 2950.0, 33.0), radius = 280.0 },
        { label = 'Fort Zancudo north-west', coords = vec3(-2250.0, 3300.0, 33.0), radius = 280.0 },
        -- live match boundary (up to 135 m) + push-back
        { label = 'Crimson-Arena Trailer Park', coords = vec3(2344.43, 2565.06, 46.67), radius = 160.0 },
        -- where arena players return after a match
        { label = 'Crimson-Arena lobby', coords = vec3(-282.01, -2030.46, 30.15), radius = 60.0 },
    },
}

-- ############################################################################
--                          PART 3 · PLAYER VS POLICE
-- Real players as suspects: the rules for every such case, live crimes and volunteer suspects.
-- Usually changed here: LiveCrime.enabled, Volunteers.enabled and CriminalTablet.enabled (all ship off), once your
-- server is ready for criminal players to take part.
-- ############################################################################

-- ============================================================================
--                    REAL SUSPECTS (rules for real players)
-- ============================================================================
-- Rules for every case where the suspect is a real player instead of an NPC: a LIVE crime (Config.LiveCrime) or a
-- mission played against a volunteer (Config.Volunteers). Nothing here does anything while both are off.
-- Crimson-Police never tells officers who a suspect is, and gives him nothing unless Config.FeatureRewards.suspect
-- is on (a volunteer paid for a fair case).
Config.RealSuspects = {
    -- The NPC-mission rules that do not fit a fight with a real player (each can be set back). 'normal' = an
    -- officer's own shots-fired, person-down and EMS calls go out like any officer's, so backup can come; 'silenced'
    -- = the NPC-mission rule (no alerts)
    officerAlerts = 'normal',
    -- 'first_contact' = an officer who gets near a suspect (contactRange) counts as arrived and his route check stops;
    -- 'start' = the NPC-mission rule (only the mission start counts)
    routeEnds = 'first_contact',
    -- 'keep_earned' = a downed officer leaves with what he earned so far and no type cooldown; 'failed' = the
    -- NPC-mission rule (his run is Failed)
    downed = 'keep_earned',
    -- Seconds down, with no EMS on duty, before the pick-up (keep equal to sc-ambulance's Config.DeathTime; NPC
    -- missions use Config.Downed.pickupDelay)
    downedPickupDelay = 400,
    -- false = no NPC-combat headshot protection or damage cut for officers once a real suspect is in the case; true =
    -- they keep Config.NpcCombat's officer settings
    npcCombat = false,
    -- Who can be a suspect:
    excludeAce = 'crimsonpolice.realsuspect.exclude',  -- players with this ace (server.cfg) are never suspects
    -- true = Crimson-Police admins (Config.AdminAce / Config.QboxAdmins) are never suspects either
    excludeAdmins = true,
    -- A character can't be a suspect within this many minutes of police duty, and can't take a case within this many
    -- minutes of being a suspect
    jobHopMinutes = 30,
    -- Seconds with no movement and no camera turn = AFK: never a suspect, and a suspect cuffed while AFK scores
    -- nothing
    afkSeconds = 300,
    afkSampleEvery = 15,             -- seconds between AFK samples (only suspects, volunteers and reported crews)
    noStartZones = {                 -- a player standing here can't become a suspect
        { label = 'Pillbox Hill Medical', coords = vec3(308.19, -595.35, 43.29), radius = 100.0 },
        { label = 'Paleto Bay Medical', coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
        { label = 'Crimson-Arena lobby', coords = vec3(-282.01, -2030.46, 30.15), radius = 60.0 },
        { label = 'Crimson-Arena Trailer Park', coords = vec3(2344.43, 2565.06, 46.67), radius = 160.0 },
    },
    contactRange = 100.0,            -- metres: an officer this close to a suspect has made contact
    -- When a suspect leaves (logs off, switches character, enters Crimson-Arena or another instance): 'void' = he
    -- counts for nobody; 'caught' = it counts as a detain for the officers; 'escaped' = it counts as getting away.
    -- Staff always get a note, and it never holds the officers' points
    onLeave = 'void',
    disconnectGrace = 120,           -- seconds a suspect who lost connection may come back and stay in the case
    reconnectNoticeMinutes = 30,     -- minutes: officers are told when a suspect who left cuffed is back this soon
    -- The staff note says "left soon after contact" when he left within this many seconds of it
    evadeWindow = 120,
    trail = {                        -- position trail kept for review
        every = 5,                   -- seconds between points
        max = 360,                   -- points kept per suspect
    },
    timelineMax = 300,               -- timeline entries kept per case
    -- Closed cases staff can still open in the Admin UI (their timeline, damage ledger and flags), the newest
    -- ones; open cases are always there
    casesKept = 16,
    -- true = the kept closed cases are saved (the database or the saves folder), so a restart keeps them (none older
    -- than pairLedgerDays); false = memory only, a restart starts the list again
    saveCases = true,
    -- true = admins (the antiFarmOverride key) get a Real suspects screen in the Admin UI while live crimes or
    -- volunteers are on: the cases, each case's timeline and damage ledger, pair statistics and the block, exclude
    -- and suspend tools; false = no screen (the cases are still kept)
    adminScreen = true,
    -- true = admins can lift a pair block, an exclusion or a suspension early from that screen (with a reason, in
    -- the audit log); false = each one runs to its end date
    staffLift = true,
    -- true = pair statistics, the running blocks and the case lists on that screen show character names next to
    -- citizen IDs (one name lookup per screen load); false = citizen IDs only
    staffNames = true,
    -- true = the damage ledger on that screen names the weapon (Combat Pistol); false = the raw weapon hash
    weaponNames = true,
    -- Proof the server checks before anything scores:
    cuffPairWindow = 10,             -- seconds between the officer's sc-police cuff and the suspect's cuffed state
    cuffRange = 3.5,                 -- metres between them at the cuff (sc-police allows 2.5; the rest is lag)
    custodyHoldSeconds = 30,         -- seconds the cuffs must hold before a detain counts
    -- An on-duty officer outside the case who cuffs a suspect: 'assist' = it counts as the case's cuff while an
    -- officer of the case is within contactRange of the suspect (else the suspect counts for nobody); 'stopped' = the
    -- suspect always counts for nobody, like a jail by someone outside the case
    outsideCuff = 'assist',
    -- Seconds: free this soon after the cuff = he won sc-police's cuff-break game (fair, once per case and not in
    -- the first 2 s); later, with no officer uncuff and no bobby pin, it is a self-uncuff: it counts as detained and
    -- staff get a note
    breakFreeSeconds = 20,
    -- Metres: a friend's successful bobby pin frees him with no note when that friend stood this close for 2 s or
    -- more (once per case)
    rescueRange = 4.0,
    neutralisedShare = 0.5,          -- a suspect cuffed while down (whoever downed him) counts this share of a detain
    jailRange = 6.0,                 -- metres between officer and suspect at the jail (sc-police allows 5)
    minJailTime = 5,                 -- a booking needs at least this sentence (sc-police counts months)
    jailTimeMax = 120,               -- longer sentences are recorded as this
    -- A booking counts only inside one of these ({} = anywhere): sc-police's station duty points and the prison;
    -- check them on your MLOs
    bookingZones = {
        { label = 'Mission Row PD', coords = vec3(470.63, -974.11, 30.18), radius = 120.0 },
        { label = 'Sandy Shores (BCSO)', coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
        { label = 'SASP', coords = vec3(1560.38, 815.76, 76.21), radius = 80.0 },
        { label = 'Bolingbroke Penitentiary', coords = vec3(1768.73, 2570.43, 44.73), radius = 180.0 },
    },
    -- Seconds after a hospital respawn he can't be detained for points (unless officers were with him when he
    -- went down)
    spawnProtectSeconds = 600,
    -- Seconds; keep equal to sc-ambulance's Config.DeathTime: a respawn sooner voids him and staff get a note
    earlyRespawnSeconds = 400,
    -- Officer conduct: these weapons are never a "shot" (a hit with one on a suspect who was never armed costs
    -- nothing)
    lessLethal = { 'WEAPON_STUNGUN', 'WEAPON_STUNGUN_MP', 'WEAPON_NIGHTSTICK', 'WEAPON_FLASHLIGHT' },
    armedMemory = 15,                -- seconds a suspect counts as armed after the server saw a gun in his hands
    downGrace = 3,                   -- seconds after he goes down before a hit counts as hitting a downed person
    damageLogMax = 200,              -- weapon hits between officers and suspects kept per case
    -- Anti-farm (admins only): nobody can take a case against one of his own characters or licenses, and the
    -- identifiers of both players are compared live, never stored or shown
    identityMatch = {
        block = { 'license', 'license2', 'discord', 'fivem', 'steam', 'xbl', 'live' }, -- same account = refused
        flag = { 'ip', 'token' }, -- same connection or PC = allowed but flagged (families share them)
    },
    -- One scored case of the same suspect per officer in this many hours (live crimes and volunteers together)
    pairCooldownHours = 24,
    maxCatchesPerSuspectDay = 2,     -- a suspect is worth points this many times a day, server-wide
    -- After a case, the same officers score nothing on that suspect for this many minutes
    suspectCooldownMinutes = 30,
    -- The same officer and suspect this often, with a second warning sign (a detain within fastCatchSeconds, a
    -- suspect never armed who moved under 30 m after contact, or a case under 3 minutes), flags that officer
    pairFlag = {
        count = 2,                   -- cases of the same pair (matched by license)
        days = 7,                    -- within this many days
    },
    fastCatchSeconds = 60,           -- seconds: a detain this soon after the case started is a warning sign
    pairLedgerDays = 30,             -- days the pair ledger keeps case rows (admin blocks stay until they expire)
    -- Surrender and Talk them down in a live case (Config.LiveCrime; nothing while live crimes are off). A suspect
    -- gives himself up with the command below, or says yes when an officer of the case close to him uses Talk them
    -- down (radial menu); the suspect always chooses. A surrendered suspect then detained with no officer hit on him
    -- scores the peaceful_arrest line (Config.Bonuses), and the case timeline shows who talked him down
    surrender = {
        enabled = true,              -- true = the surrender command and Talk them down work in live cases
        command = 'surrender',       -- the suspect's chat command (without the /)
        talkRange = 15.0,            -- metres: an officer this close to a free suspect can talk him down
        surrenderRange = 50.0,       -- metres: a surrender counts only with an officer of the case this close
        askSeconds = 20,             -- seconds the suspect's yes/no pop-up waits for an answer
        talkCooldown = 30,           -- seconds before the same officer can talk the same suspect down again
        holdSeconds = 120,           -- seconds a surrender lasts with no cuff before it lapses
        breakRange = 10.0,           -- metres: a surrendered suspect who moves this far from where he gave up ends it
    },
}

-- ============================================================================
--                            LIVE CRIMES (option A)
-- ============================================================================
-- A live crime is a real crime that Crimson-Contracts reports once its police alert goes out; the crew that started
-- the contract are the suspects. It shows as a red LIVE call on the Dispatch screen; officers who claim it respond
-- to the real crew and earn points for securing the scene, detaining and booking the suspects (the shares are the
-- live_* entries in Config.Bonuses). Crimson-Contracts needs ContractsConfig.LifecycleEvents = true.
Config.LiveCrime = {
    enabled = false,                 -- true = reported crimes become LIVE calls on the Dispatch screen
    -- false = officers on a live case may leave the GPS route to chase; true = the normal route rule
    -- (Config.Route.required)
    requireRoute = false,
    sources = { 'crimson-contracts' },  -- the only scripts allowed to report a crime
    types = {                           -- which crimes become LIVE calls, and the mission type whose points they use
        warehouse_burglary = 'investigation',
        container_heist = 'investigation',
        hostile_drug_pickup = 'tactical',
        drug_lab_raid = 'tactical',
        weapon_shipment = 'tactical',
        prisoner_ambush = 'tactical',
        atm_robbery = false,         -- false = never a LIVE call (a solo ATM hack has no crew to track)
    },
    suspectRadius = 300.0,           -- crew members further than this from the crime at the alert are not suspects
    offerTime = 300,                 -- seconds a LIVE call stays open before it lapses (the crime's end lapses it too)
    maxLiveRuns = 2,                 -- LIVE calls and live cases at once; a crime past this gets no LIVE call
    caseTime = 1800,                 -- seconds a live case lasts at most; it then ends with the points earned
    -- true = a unit of 2+ answers the ready check before its live case opens, like a mission; false = the case
    -- opens at once (a real crime does not wait)
    readyCheck = false,
    -- true = an officer with a type cooldown (he abandoned a mission of that type) can't claim a LIVE call of that
    -- type, and leaving a live case early starts that cooldown; false = live cases ignore type cooldowns
    typeCooldown = false,
    -- true = LIVE calls can still be claimed while a Cross-Department Mission runs (its lock stops missions only);
    -- false = the Cross-Department lock stops live cases too
    duringOperation = true,
    -- Backup: true = an on-duty officer on no mission who marks himself responding to the crime's own SC-Dispatch
    -- call, reaches the scene or cuffs a suspect gets a pop-up to join the live case; false = only the unit that
    -- claimed the LIVE call works the case
    backup = true,
    maxOfficers = 6,                 -- officers on one live case at most (the unit that claimed it counts)
    joinOfferSeconds = 30,           -- seconds the join pop-up waits for an answer
    -- The officers' tablet: true = a LIVE line on the unit's ready check and a case card on Active Mission (the
    -- three steps, the suspect count and when the "last reported" points were taken; never a suspect's state or a
    -- live position); false = the case shows like any mission
    caseCard = true,
    -- true = the result card lists each suspect's outcome by label (Suspect A: booked, Suspect B: got away) once the
    -- case is over; false = no outcomes on the result card
    resultOutcomes = true,
    -- Results for other scripts: true = when a live case ends, Crimson-Police sends the server-only event
    -- crimson-police:server:liveCrimeEnded (the crime, how the case ended and each suspect's outcome); false = no event
    endEvent = true,
    -- Who the export GetAvailablePolice counts: 'idle' = on-duty officers on no mission (they could answer a crime
    -- now); 'duty' = every on-duty officer. The export answers nil while enabled is false
    availablePolice = 'idle',
    -- The live case (officers who claimed a LIVE call): Respond, Secure the scene, then Detain and book the
    -- suspects. Metres around the reported place that count as being at the scene
    sceneRadius = 75.0,
    secureSeconds = 60,              -- seconds officers must hold the scene to secure it (0 = reaching it is enough)
    -- Seconds between the "last reported" map points of suspects still free (never a live position; 0 = no points)
    lastReportedEvery = 60,
    -- Seconds a case stays open once no suspect is left to work (all booked, lost, left or void) before it ends
    deadCaseSeconds = 30,
    -- Points of a live case: true = only its live lines (scene secured, each detain and booking x the suspect's
    -- share) and its conduct penalties; false = the mission type's points plus those lines, like a mission
    linesOnly = true,
    -- Which team sets a live case's tier (the points and cash multiplier of Config.Scaling): 'crew' = the number of
    -- suspects at the alert; 'officers' = the officers on the case, like a mission
    tier = 'crew',
    typeOfTheDay = false,            -- true = a live case of today's Type of the Day gets its points multiplier too
    goals = false,                   -- true = live cases count for the officers' daily and weekly goals
    challenge = false,               -- true = live cases count for the department challenge and the weekly bounty
    -- Money: true = a live case pays the officers cash like a mission of its type (its Config.MissionTypes payout,
    -- so the money is set already); false = points only. Ships off
    cash = false,
    items = false,                   -- true = a live case rolls the item rewards of its type too (Config.Rewards)
}

-- ============================================================================
--                     VOLUNTEER SUSPECTS (options B and C)
-- ============================================================================
-- A player who is not on police duty can volunteer, with the command below, to be the suspect of a police tablet
-- mission for an hour. When officers take a mission whose suspect a real player can play (Warrant Service's wanted
-- person, Street Race Bust's driver, Manhunt's fugitive) and a volunteer fits, he gets a yes/no pop-up; if he says
-- yes he plays that suspect instead of the NPC. Volunteers see pop-ups, notifications and a menu (or the criminal
-- tablet below, once it is on); they are paid only with Config.FeatureRewards.suspect on. Set a mode per mission
-- type below: while every mode is 'npc', nothing changes even with enabled = true.
Config.Volunteers = {
    enabled = false,                 -- true = players can volunteer with the command below
    -- The chat command (without the /) a player volunteers with: it asks him to agree to the rules and pick the
    -- suspects he will play, and while he volunteers it opens a menu to renew, change them or stop (restart to change)
    command = 'crimsonheat',
    windowMinutes = 60,              -- minutes a volunteer stays on the list; he can renew it from the menu
    -- A volunteer who says yes and then does not show up or walks away from the case gets a strike. This many
    -- strikes within strikeHours stop that player, on every character, from volunteering for blockHours
    strikes = 3,
    strikeHours = 24,                -- hours a strike counts towards the block
    blockHours = 24,                 -- hours a player who reached the strikes can't volunteer
    -- true = strikes and strike blocks are saved (the database or the saves folder), so a restart keeps them; false =
    -- memory only, a restart clears them. The volunteer list is never saved: after a restart a player volunteers again
    saveStrikes = true,
    -- true = admins can clear a player's strikes and strike block from the Real suspects Volunteers tab (with a
    -- reason, in the audit log); false = they run out on their own
    staffClearStrikes = true,
    -- Who plays the suspect of a mission a volunteer can play, per mission type: 'npc' = always the NPC (as today);
    -- 'players_when_available' = when the unit ticks "Real suspect OK" on the Mission Board and a volunteer who
    -- fits is online, he is asked to play the suspect, else the NPC plays him; 'players_only' = the type's missions
    -- are offered only while a volunteer who fits is free, to a unit that ticks "Real suspect OK", and its draw
    -- takes only missions a volunteer can play. A mission named in missionModes below follows its own mode instead
    modes = {
        patrol = 'npc',
        training = 'npc',
        investigation = 'npc',
        tactical = 'npc',
    },
    -- The same choice for single missions, by mission id (beats its type's mode), e.g. { warrant_service =
    -- 'players_only' }. Empty = every mission follows its type
    missionModes = {},
    -- Asking: the volunteers who fit get a yes/no pop-up one at a time (the one a 'players_only' accept held first).
    -- A no or no answer is never a strike
    askSeconds = 30,                 -- seconds the pop-up waits for an answer before the next volunteer is asked
    askTries = 3,                    -- volunteers asked per mission before the NPC plays the suspect
    -- After a yes he has this many seconds to reach the suspect's starting point (it is set as his map waypoint); not
    -- there in time = a no-show (a strike) unless officers already reached him
    travelSeconds = 300,
    meetRadius = 25.0,               -- metres from the starting point that count as being in position
    -- Seconds after his yes in which his own Cancel this case is no strike (once officers reached him it always is)
    cancelGraceSeconds = 60,
    -- When the volunteer who said yes drops out before officers reach him (no-show, Cancel this case, logs off):
    -- 'npc' = the NPC plays the suspect as if nobody had said yes; 'end' = the mission ends (see voidRun). A
    -- 'players_only' mission, and any mission once officers reached him, always ends
    onVoid = 'npc',
    -- How such a mission ends: 'cancelled' = Abandoned with no cooldown, penalty or pay; 'keep_earned' = Completed
    -- with what the officers earned so far
    voidRun = 'cancelled',
    -- A volunteer who is caught while AFK (he did not move for a while, Config.RealSuspects): true = his part is
    -- void (a strike, and the mission ends as in voidRun); false = the catch counts like any other catch
    afkCatchVoids = true,
    -- Warrant Service's armed associates while a volunteer plays the wanted person at the door: false = they stay
    -- away (the NPCs would shoot him too); true = they come out at the knock as usual
    doorAssociates = false,
    -- Street Race Bust's other NPC racers (and the other suspect cars of a stop pursuit) while a volunteer drives one
    -- in his own car: false = his car is the only suspect car; true = the others still come (he takes one car's place)
    driverNpcCars = false,
    -- Seconds between the map's "last reported" points of a volunteer driver once he is in position (where the server
    -- last saw him, never a live position); 0 = no points, the map keeps the starting point
    driverReportEvery = 30,
    -- Manhunt's other NPC fugitives (more officers bring more) while a volunteer hides as one of them: false = he is
    -- the only fugitive; true = the others still hide (he takes one fugitive's place)
    fugitiveNpcs = false,
    -- Seconds a volunteer fugitive may stay outside the search circle (the red circle on his own map; it shrinks
    -- towards where the server last saw him at each clue) before his part is void (a strike); 0 = no circle rule
    fugitiveOutSeconds = 30,
    -- Results for other scripts: true = when a mission a volunteer said yes to ends, Crimson-Police sends the
    -- server-only event crimson-police:server:volunteerEnded (the mission, the suspect he played, how it ended and
    -- his outcome, by his citizenid; another script can reward him); false = no event
    endEvent = true,
    -- What a mission played against a volunteer (once he said yes) takes part in; true = like any other mission
    typeOfTheDay = false,            -- true = today's Type of the Day points multiplier applies to it too
    goals = false,                   -- true = it counts for the officers' daily and weekly goals
    challenge = false,               -- true = it counts for the department challenge and the weekly bounty
    -- Money: true = it pays the officers cash like any mission of its type (its Config.MissionTypes payout, so the
    -- money is set already); false = points only (its cash is 0). Ships off. The volunteer's own pay is
    -- Config.FeatureRewards.suspect
    payCash = false,
    payRewards = false,              -- true = it rolls the item rewards of its type too (Config.Rewards)
}

-- ============================================================================
--                               CRIMINAL TABLET
-- ============================================================================
-- A tablet of its own for players who play real suspects, with a dark street look (nothing like the police
-- tablet): Home (volunteer on or off, the hour window), Jobs (the suspect police want played right now: the mission
-- type, the suspect, the area; Accept is the same yes as the pop-up), Active (the meet point, the rules and the
-- time left, give up), History (cases since the last restart, outcomes and strikes with when they run out) and
-- Rules. It runs on Volunteer suspects above (Config.Volunteers.enabled must be on too) and never shows where an
-- officer is. Police on duty can never open it.
Config.CriminalTablet = {
    enabled = false,                 -- true = players can open the criminal tablet with the command or item below
    command = 'crimtab',             -- the chat command (without the /) that opens it (restart to change)
    -- An ox_inventory item name that also opens it (items/ox_inventory_items.lua has an entry to paste), or false
    item = false,
    -- Who may use it: 'everyone' = every player whose job is not a police job (Config.Departments); 'granted' =
    -- only the players named by the criminalTablet extra grant (Admin UI -> Permissions -> Extra grants)
    access = 'everyone',
    -- true = the volunteer command (Config.Volunteers.command) opens this tablet for a player who may use it,
    -- instead of the pop-up menu; false = the command keeps its menu
    replaceCommand = false,
    historySize = 20,                -- past cases each player's History keeps (memory only: a restart clears it)
}

-- ############################################################################
--                           PART 4 · POLICE TEAMWORK
-- Officers working together: units, Cross-Department Missions, supervisor mission controls, field
-- training, leaderboards, the department challenge and officer profiles.
-- Usually changed here: the unit size, which Mission controls supervisors get, and field training.
-- ############################################################################

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
--                          CROSS-DEPARTMENT MISSIONS
-- ============================================================================

Config.CrossDept = {
    enabled = true,          -- true = officers may launch cross-department missions
    minParticipants = 2,     -- officers a cross-department run needs to start
    maxParticipants = 8,     -- officers one cross-department run takes at most
    joinWindow = 300,        -- seconds until joining closes (or the launcher taps Start now)
    idleCancel = 1800,       -- auto-cancel after this long with no run in progress
    cooldown = 1800,         -- seconds between launches, server-wide
    waitlist = true,         -- officers can queue when every place is taken; a freed place goes to the first
}

-- ============================================================================
--                               MISSION CONTROLS
-- ============================================================================
-- See also Part 2 (NPC missions): these controls change the NPC missions of one department.

-- Rules a department's supervisors may change for their own department from the Supervisor UI, only inside the
-- bounds set here and only while an admin switched them on: Config.Permissions.supervisor.missionControls and the
-- control's own on. A department may have its own bounds (Config.Departments.<key>.missionControls = { <control> =
-- { on, min, max } }); they win over the ones below for it. Every change needs a reason and is in the audit log.
-- The cooldown controls are server-wide (one value for every department), outside the master switch and ship
-- on: a supervisor may change them out of the box; until one does, every cooldown stays as config.lua sets it.
-- Clearing one officer's cooldown is a cooldown control too (server-wide, ships on). Every other control ships off.
Config.MissionControls = {
    changeWait = 300,   -- seconds between two changes of one control in one department
    selfExempt = true,  -- a control that relaxes a rule never applies to the supervisor who set it or a unit he is in
    grants = {},        -- per department who may use them, e.g. { sast = { minGrade = 4 } }; {} = every supervisor
    controls = {        -- per control: on = the admin switch, min/max = the only values a supervisor may pick
        -- x every mission's cooldown, per mission type, for every department; min 0 = a type with no mission cooldown
        cooldownScale = { on = true, min = 0, max = 2 },
        -- the abandon cooldown in seconds (Limits.abandonCooldown) for every department; 0 = none
        abandonCooldown = { on = true, min = 0, max = 900 },
        -- false switches the no-repeat rule (Draw.avoidLast) off for every department: a mission may come up twice
        noRepeat = { on = true },
        -- completed missions per officer per hour (Limits.maxCompletionsHour) for every department
        hourlyCap = { on = true, min = 1, max = 16 },
        -- completed missions per officer per day (Limits.maxCompletionsDay) for every department; 0 = no cap
        dailyCap = { on = true, min = 0, max = 40 },
        -- happy hour minutes: no mission cooldowns for anyone on the server (abandon cooldown and caps stay)
        happyHour = { on = true, min = 5, max = 30 },
        -- Department Report: a supervisor clears one officer's mission or type cooldown (any department, never his
        -- own character, never while the officer is on a run); each officer still at most
        -- AdminControl.cooldownClearsPerDay clears a day by all staff together
        clearCooldown = { on = true },
        -- Live Missions: a supervisor adds min to max minutes per click to a running mission of his department
        -- (never his own); the time limit the fast-finish bonus is judged on stays the same
        addRunTime = { on = false, min = 1, max = 5 },
        -- seconds a unit of his department has to reach the start after accepting (Limits.startTimeout and the
        -- mission's own); read when the run is accepted, so a change never moves a run already going
        startTimeout = { on = false, min = 300, max = 900 },
        -- seconds a unit of his department has to answer the ready check (Units.readyTimeout); 0 switches the ready
        -- check off for his department, allowed only while canTurnOff = true
        readyCheck = { on = false, min = 10, max = 40, canTurnOff = false },
        -- x the mission's time limit for runs of his department; the fast-finish bonus still uses the unscaled limit
        timeLimit = { on = false, min = 1.0, max = 1.25 },
        -- seconds after a run of his department starts before officers who never reached the start are removed
        -- (AntiCheat.idleCheck); stricter only: never more than that config value
        idleCheck = { on = false, min = 60, max = 180 },
        -- how hard mission NPCs are on runs his department leads: one of the presets listed here
        -- (NpcDifficulty.presets: easy, normal, hard, custom); read when the run is accepted; NpcCombat's limits
        -- still apply on top, and points and cash never change
        difficulty = { on = false, presets = { 'easy', 'normal' } },
        -- the largest unit an officer of his department may lead (invites, joins and accepting a mission); never
        -- above Limits.maxUnitSize
        unitSize = { on = false, min = 2, max = 4 },
        -- Mission Board: mission types (or single missions) a supervisor switches off for his department; its
        -- officers see the type locked, other departments still take it; it stays until switched back on
        types = { on = false },
        -- Mission Board: one mission type shown to his department's officers as "Recommended by command", right
        -- after their favourites; points and pay never change
        featuredType = { on = false },
        -- Department Report: a supervisor bars one officer of his department (a lower grade, never himself) from
        -- taking missions for min to max hours, with a reason: no Mission Board accept, mission call claim or
        -- Cross-Department join; the tablet stays usable and a mission already running goes on. The one who set it
        -- and admins (Officers -> Today & cooldowns) may lift it early
        missionBan = { on = false, min = 1, max = 24 },
        -- Dispatch: his department's own lane of mission calls next to the server's: min to max seconds between two
        -- lane calls (he picks a range inside it), how many may be open at once (up to callLaneMaxOpen), the areas
        -- and the mission types (MissionCalls.types) with a weight each; only his department sees and claims them
        callLane = { on = false, min = 120, max = 600 },
        -- seconds a supervisor of his department waits between two mission calls he creates
        -- (MissionCalls.staffCooldown); the one who shortens it keeps the config wait for himself
        staffCallWait = { on = false, min = 60, max = 120 },
        -- Supervisor UI: a supervisor posts a short notice (up to noticeMaxLength characters, 1 to 30 days) for his
        -- own department only; its officers see it on Home -> Announcements, other departments never do. At most 5
        -- run at once per department, the banned-word list applies, and every post and end is audited
        notices = { on = false },
        -- Cross-Department Missions: a supervisor keeps his department's officers out of them (they cannot join)
        -- or caps how many of them may take part in one; every board still shows only the running operation and
        -- the wait between launches stays server-wide
        crossDept = { on = false },
        -- Leaderboard: whether other departments see his department's officers by name or by callsign only, and
        -- which Rank by tabs his department's officers see (Leaderboard.metrics; points always). Presentation only:
        -- counts, the Department Challenge and the admin boards never change
        boards = { on = false },
        -- Review: stricter rules for his department's flagged runs: a supervisor's Void waits for a second
        -- supervisor of the department, and flags of the kinds he picks go to admins only. Admins are never bound
        -- and the anti-cheat flag triggers stay as they are
        reviewRules = { on = false },
        -- Mission Board and mission call claims: which of the twists enabled in Events.twists his department's
        -- leaders are offered at the accept step, and which of them start ticked; a twist his department does not
        -- offer is refused. The twists' bonuses never change
        twists = { on = false },
        -- Happy hour cash: x the cash of a completed run his department leads that was accepted while a happy hour
        -- ran (kept for the run, so the end of the hour never cuts it); never on test runs, Cross-Department runs or
        -- the Weekly Boss, and Cash.dailyCap still applies. min = max = 1.0 moves nothing: raise max (e.g. 1.25)
        happyHourCash = { on = false, min = 1.0, max = 1.0 },
        -- Twist cash: x each twist's cash (Events.twists) on runs his department leads, read at the accept; the chosen
        -- twists together still stop at Events.twistMaxCash and points never change. min = max = 1.0 moves nothing
        twistCash = { on = false, min = 1.0, max = 1.0 },
        -- Happy hour points: x the final points of a completed run his department leads that was accepted while a
        -- happy hour ran (kept for the run); never for the one who started the hour, on test runs, Cross-Department
        -- runs or the Weekly Boss. min = max = 1.0 moves nothing: raise max (e.g. 1.25)
        happyHourPoints = { on = false, min = 1.0, max = 1.0 },
        -- Twist points: x each twist's points share (Events.twists) on runs his department leads, read at the accept;
        -- the chosen twists together still stop at Events.twistMaxPoints. min = max = 1.0 moves nothing
        twistPoints = { on = false, min = 1.0, max = 1.0 },
        -- Type of the Day: a supervisor picks one mission type for TOMORROW, at most once a day for his department;
        -- tomorrow his department's officers earn the Type of the Day points (Events.todMultiplier) on that type
        -- instead of the server's type, other departments keep the server's. Never on his own runs or a unit he is in
        typeOfTheDay = { on = false },
        -- Dispatch: a supervisor pages a unit of his department (never his own) with one mission he chooses instead
        -- of a random one; only that unit sees the mission's name and may accept or decline it, every accept rule
        -- stays (cooldowns, caps, unit size), the call never earns rapid response and the audit names the mission
        pushMission = { on = false },
        -- Goals: a supervisor picks min to max of your daily goals and of your weekly goals (Goals.daily, Goals.weekly)
        -- his department's officers draw theirs from, starting at the next weekly reset (none picked = every goal);
        -- the goals' points never change and the supervisor himself keeps your whole lists
        goals = { on = false, min = 1, max = 5 },
        -- Department Report: a supervisor gives min to max points at a time to an officer of his own department
        -- (never to himself or another character of his license), with a reason, through the same logged manual award
        -- as Admin UI -> Give or take points (AdminControl.pointAdjust off stops it too); shown in the officer's history
        -- like an admin's award, at most awardPointsPerDay points a supervisor a day
        awardPoints = { on = false, min = 1, max = 50 },
    },
    happyHourPerDay = 1, -- happy hours a supervisor may start a day (admins any); never for the one who started it

    -- officers' cooldowns one supervisor may clear a day (admins any)
    clearCooldownPerDay = 5,
    -- times one supervisor may add minutes to a running mission a day (admins any)
    addRunTimePerDay = 10,
    -- seconds supervisors may add to one running mission in all, counted together with an admin's additions and
    -- never above AdminControl.runTimeAddMax
    addRunTimeMax = 300,
    -- mission bans one supervisor may set a day (admins any)
    missionBanPerDay = 3,
    -- calls one department's lane may have open at once (every open call still counts against MissionCalls.maxOpen)
    callLaneMaxOpen = 2,
    -- characters a department notice may hold (at most 280, the length of an admin's staff notice)
    noticeMaxLength = 280,
    -- department notices one supervisor may post a day (admins any)
    noticesPerDay = 5,
    -- missions one supervisor may push to a unit a day (the pushMission control; admins any)
    pushMissionPerDay = 5,
    -- points one supervisor may give a day in all (the awardPoints control; admins any); 0 = no limit
    awardPointsPerDay = 100,
}

-- ============================================================================
--                                FIELD TRAINING
-- ============================================================================
-- Field training (FTO): a supervisor (or an admin) pairs a trainer with a rookie of his own department in Supervisor
-- UI -> Department Report. Completed missions the rookie runs together with his trainer (both finish the same run)
-- count towards the sign-off tasks below. Once a task's count is reached the trainer signs it off on his tablet
-- (Profile -> Field training), with an optional note. When every task is signed off the rookie gets the badge below
-- and the training is done. Every pairing and sign-off is in the audit log. Off when you install.
Config.FieldTraining = {
    enabled = false,                 -- true = supervisors can pair trainers and rookies, and runs count for them
    -- Who may train, per department key: the lowest Qbox grade number of a trainer (that grade and up). A department
    -- not listed here uses its supervisorGrade (so only supervisors train there)
    trainerGrades = { sast = 2, fib = 2 },
    -- Sign-off tasks, per mission type key: the completed missions of that type the rookie must run with his trainer
    -- before the trainer may sign the task off. A type left out (or 0) is no task
    tasks = { patrol = 3, investigation = 2, tactical = 1 },
    rookiesPerTrainer = 2,           -- rookies one trainer may train at the same time
    badge = 'field_training',        -- the badge a rookie gets when every task is signed off (Profile -> Badges)
    -- Ride-along rule: mission type keys (e.g. { 'tactical' }) a rookie in training may only accept (or claim) with his
    -- trainer in the same unit. Empty = a rookie runs every type with anyone
    requireTrainerFor = {},
    trainerBonus = 0,                -- points the trainer gets for each task he signs off (0 = none)
}

-- ============================================================================
--                                 LEADERBOARD
-- ============================================================================

Config.Leaderboard = {
    cacheSeconds = 60,       -- seconds a board is reused before it is counted again
    minRunsToRank = 3,       -- runs in the window an officer needs to be ranked
    topN = 25,               -- rows a board shows
    weekStartsOn = 'monday',
    seasonWeeks = 8,         -- suggested season length for "weeks left"; an admin ends the season
    -- Rank by tabs; 'live_catches' (suspects detained in live cases, Config.LiveCrime) can be added
    metrics = { 'points', 'missions', 'arrests', 'impounds', 'citations', 'rescues', 'calls', 'judgement' },
    minDecisions = 10,       -- Judgement: decisions needed in the window
    weeklyBadges = {},       -- extra weekly badges by metric, e.g. { 'arrests' }; Officer of the Week stays by points
    announceWeekly = true,   -- the weekly top 3 on Home and the board webhook
    announceMonthly = true,  -- the monthly top 3 on Home and the board webhook
}

-- ============================================================================
--                             DEPARTMENT CHALLENGE
-- ============================================================================

Config.Challenge = {
    enabled = true,            -- true = departments compete in seasons (the department challenge)
    scoring = 'average',       -- 'average' (per active officer) | 'total' | 'top10'
    minRunsActive = 3,         -- runs in the week that make an officer active (the average counts only these)
    weeklyBounty = true,       -- true = a weekly bounty is picked every week
    bountyBonus = 0.10,        -- share of its week's challenge points the bounty winner gets on top (0.10 = +10%)
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
    bioLines = 3,                                 -- lines a bio may have at most
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

-- Officer options: the choices each officer makes for their own tablet on the My options screen, saved per
-- character. A department may set its own allow, defaults and bounds (Config.Departments.<key>.officerOptions =
-- { allow = {}, defaults = {}, bounds = {} }); they win over the ones below for its officers.
Config.OfficerOptions = {
    enabled = true,                  -- false = no My options screen; every option keeps its default for everyone
    allow = {                        -- per option: false = officers cannot change it, everyone gets the default
        hudSide = true,              -- the mission HUD on the right or the left of the screen (kept on this PC)
        hudScale = true,             -- the mission HUD bigger or smaller (kept on this PC)
        hudCompact = true,           -- the mission HUD shows only the current objective (kept on this PC)
        reduceMotion = true,         -- no slide-in or flashing on the HUD and the toasts (kept on this PC)
        hudLook = true,              -- the officer's tablet look on the HUD, result card and toasts (this character)
        textSize = true,             -- larger text on the tablet and the mission HUD (this character)
        toastTime = true,            -- how long notifications stay on screen (kept on this PC)
        resultTime = true,           -- how long the mission result card stays on screen (kept on this PC)
        quietRun = true,             -- fewer pop-ups during a mission: social news goes to the bell (kept on this PC)
        keyHints = true,             -- the ready check, a new call and the contact HUD line name their key (this PC)
        soundCalls = true,           -- the tone of a new mission call (kept on this PC)
        soundUnit = true,            -- the tone of a unit invite and a ready check (kept on this PC)
        soundCues = true,            -- the objective cues on a run: checkpoints, a defused target (kept on this PC)
        favouriteTypes = true,       -- the mission types shown first on the Mission Board (this character)
        hiddenTypes = true,          -- the mission types folded away on the Mission Board (this character)
        skipAcceptConfirm = true,    -- accept a mission type in one click, without the confirm (this character)
        usualTwists = true,          -- the twists already ticked when the officer takes a mission (this character)
        skipClaimConfirm = true,     -- claim a mission call in one click, without the confirm (this character)
        callAlerts = true,           -- which new mission calls pop up: every call or favourite types (this character)
        dispatchKeyAfterCall = true, -- the tablet key opens Dispatch just after a mission call (this character)
        openOn = true,               -- the screen the tablet opens on (this character)
        rememberFilters = true,      -- Dispatch and the Leaderboard keep their filters (kept on this PC)
        abandonConfirm = true,       -- Abandon asks in a dialog; off = press it twice (this character)
        skipRecalcConfirm = true,    -- recalculate the route in one click, without the confirm (this character)
        distanceUnits = true,        -- distances in metres or in miles (kept on this PC)
        autoReady = false,           -- answers the unit ready check for the officer: off unless you want it
        objectiveGps = true,         -- how the map leads to each objective: line, waypoint or none (this character)
        hudTargetLine = true,        -- the HUD line naming the objective and how far it is (kept on this PC)
        colourblindMap = true,       -- colour-blind colours for objective blips, no red or green (kept on this PC)
    },
    defaults = {                     -- per option: what every officer starts with
        hudSide = 'right',           -- 'right' (as before) or 'left': the side of the screen the mission HUD sits on
        hudScale = 1.0,              -- size of the mission HUD on top of the screen size (1.0 = as before)
        hudCompact = false,          -- true = the HUD shows the current objective, the done count and the timer
                                     -- only; false = every objective (as before)
        reduceMotion = false,        -- true = the HUD and the toasts appear without sliding in or flashing
        hudLook = false,             -- true = the HUD, result card and toasts use the officer's tablet look
                                     -- (appearance and accent); false = the department theme (as before)
        textSize = 'normal',         -- 'normal' (as before) or 'large': text size on the tablet and the mission HUD
        toastTime = 'normal',        -- how long notifications stay: 'short' (3 s, warnings 5 s), 'normal' (5 s,
                                     -- warnings 7 s, as before) or 'long' (8 s, warnings 12 s)
        resultTime = 25,             -- seconds the mission result card stays on screen (25 = as before)
        quietRun = false,            -- true = during a mission, unit invites, commendations, rewards and profile news
                                     -- go only to the bell; false = they pop up as before
        keyHints = true,             -- true = the ready check banner says "or press K", a new mission call names the
                                     -- Dispatch key and the contact HUD line its key (an unbound key is never named);
                                     -- false = no key hints (as before)
        soundCalls = true,           -- true = a new mission call plays its tone (as before); false = no tone
        soundUnit = true,            -- true = a unit invite and a ready check play a tone (as before); false = none
        soundCues = true,            -- true = a checkpoint, defused target or found item plays a cue (as before)
        favouriteTypes = {},         -- mission type keys shown first on the Mission Board, e.g. { 'tactical' }; {} = the
                                     -- board's own order (as before)
        hiddenTypes = {},            -- mission type keys folded under "Hidden types" on the Mission Board; never every
                                     -- type; {} = none (as before)
        skipAcceptConfirm = false,   -- true = Accept starts a type at once, the warnings sit under the cards; false =
                                     -- Accept asks first (as before)
        usualTwists = {},            -- twist keys ticked at the start of the accept step (Mission Board, mission call
                                     -- claim) where that card offers them, e.g. { 'time_crunch' }; the officer can
                                     -- untick them. Any = they replace the department's pre-ticked twists; {} = the
                                     -- department's pre-ticked twists, else none (as before)
        skipClaimConfirm = false,    -- true = Claim on a mission call takes it at once (the nearest unit still wins a
                                     -- claim together); false = Claim asks first (as before)
        callAlerts = 'all',          -- 'all' = every new mission call pops up (as before); 'favourites' = only calls
                                     -- of the officer's favourite types, the rest still show on Dispatch
        dispatchKeyAfterCall = false, -- true = for 20 s after a mission call pops up, the tablet key opens Dispatch
        -- (nothing is claimed); false = it opens as usual (as before)
        openOn = 'last',             -- the screen the tablet opens on: 'last' (the screen it was closed on, as before),
                                     -- 'home' or 'active_on_run' (Active Mission on a run, Unit in a ready check)
        rememberFilters = false,     -- true = Dispatch and the Leaderboard open with the filters used last on this
                                     -- PC; false = their own defaults (as before)
        abandonConfirm = true,       -- true = Abandon asks in a dialog (as before); false = no dialog: the button turns
                                     -- into "Click again to abandon" for 3 s, so it still takes two presses
        skipRecalcConfirm = false,   -- true = Recalculate route works at once (Config.Route.maxRecalcs still counts);
                                     -- false = it asks first (as before)
        distanceUnits = 'metric',    -- 'metric' (m and km, as before) or 'imperial' (ft and miles) on the HUD, Active
                                     -- Mission and Dispatch
        autoReady = false,           -- true = the officer is Ready at once when the unit leader accepts a mission type,
                                     -- if they are at the keys and near the leader; false = they answer (as before)
        objectiveGps = 'route',      -- 'route' = a GPS line to each objective (as before); 'waypoint' = a map waypoint
                                     -- set on each new objective instead; 'off' = none (the Objective GPS button
                                     -- still sets one). Radio Silence still hides it; the drive to the start keeps
                                     -- its own line
        hudTargetLine = true,        -- true = the HUD names the objective and how far it is (as before); false = no
                                     -- such line
        colourblindMap = false,      -- true = objective blips and lines use blue, yellow, orange, white and purple,
                                     -- never red or green; false = Config.Markers.kinds colours (as before)
    },
    bounds = {                       -- per number option: { min, max } officers may pick
        hudScale = { 0.8, 1.3 },     -- smallest and biggest mission HUD size an officer may pick
        resultTime = { 8, 60 },      -- shortest and longest time (seconds) an officer may keep the result card
    },
    autoReadyRange = 150.0,          -- metres: Auto-Ready answers only while the officer is this close to the leader
}

Config.Commendations = {
    enabled = true,                  -- true = supervisors may commend officers
    -- the kinds a supervisor may pick (ids: rename them in Admin UI -> Settings -> Names, profile.commend.kind.<id>)
    kinds = { 'valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation' },
    citation = { 10, 255 },          -- characters
    perSupervisorPerDay = 3,         -- commendations one supervisor may give per day
    sameKindCooldownDays = 7,        -- same officer, same kind
    crossDepartment = false,         -- true = supervisors may commend officers of other departments
    announceDays = 7,                -- days the Home announcement shows for the recipient
    announce = false,                -- also post it to the board webhook
}

-- ############################################################################
--                         PART 5 · ECONOMY AND REWARDS
-- Cash, payout changes, disputes, points, XP, badges, goals, bonuses and item rewards.
-- Usually changed here: Cash (bank or cash, server or society money, the daily cap), bonus values and goals.
-- Item rewards, feature rewards and the money tools all ship off.
-- ############################################################################

-- ============================================================================
--                                     CASH
-- ============================================================================

Config.Cash = {
    account = 'bank',     -- 'bank' or 'cash'
    source = 'server',    -- 'server' (new money) or 'society' (the department's Renewed-Banking account)
    minPayout = 0,        -- limits for any base payout set in-game
    maxPayout = 25000,    -- dollars
    dailyCap = 0,         -- max cash per officer per day; 0 = no cap
    -- Money tools outside the normal flow (Admin UI → Payments, Departments). All ship off: turning one on in
    -- Settings needs the typed word ENABLE and is audited.
    allowUnfundedRetry = false,  -- retry payments the department account could not cover
    allowCapTopUp = false,       -- pay the part of a payment the daily cap cut
    allowPayAgain = false,       -- pay a payment stuck in 'paying' again (after checking the bank history)
    restoreForfeited = false,    -- a restored run pays its forfeited cash after all
    allowAddFunds = false,       -- add money to a department's account
    addFundsMax = 50000,         -- dollars per Add funds
    allowClawback = false,       -- take back cash already paid
    allowManualCash = false,     -- pay an officer by hand
    manualDailyLimit = 10000,    -- dollars one admin may pay by hand per day
    lowBalanceWarn = 0,          -- warn below this department balance (0 = off)
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
--                                   DISPUTES
-- ============================================================================

Config.Disputes = {
    windowHours = 48,   -- hours after a run that its officers may dispute it
}

-- ============================================================================
--                         SCORING, XP LEVELS AND GOALS
-- ============================================================================

-- How a run's points (P = the mission type's points) are worked out. Usually changed here: the streak and the common
-- bonuses and penalties below.
Config.Scoring = {
    scoreCap = 2.0,          -- × P
    streakStep = 0.05,       -- × points added per day of streak (0.05 = +5% a day)
    streakMax = 0.25,        -- the streak adds at most this (0.25 = +25%)
    streakGraceDays = 1,     -- missed days per week that don't reset the streak (0 = off)
    failedCredit = 0.25,     -- a failed run earns this share of P times the share of objectives done
    common = {
        fastShare = 0.75,        -- finished within this share of the time limit...
        fastBonus = 0.20,        -- ...earns this share of P
        noDamage = 10,           -- points when the vehicle stays above noDamageAbove
        firstRun = 15,           -- points for an officer's first finished run since going on duty
        heavyDamage = -25,       -- points (negative): the vehicle ended below heavyDamageBelow
        pedestrianHit = -30,     -- points (negative) for each pedestrian hit with a vehicle
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
-- See also Part 3 (Player vs police): the rs_ penalties below are for real-suspect cases.

-- The standard list, and the only one the Mission Builder offers. Ids with positive values go in a mission file's
-- bonuses, negative ones in its penalties; either may override the value with points or pctOfPoints. Labels live in
-- locales/en.json (rename them in Admin UI -> Settings -> Names). Built-in missions may also use the extra bonuses
-- written on their mission cards. Decision grades are personal to the officer who decided. Usually changed here:
-- value. Every entry has:
-- kind: 'points' = value is flat points; 'pct' = value is a share of P (0.10 = 10 %)
-- value: the points (kind 'points') or the share of P (kind 'pct'); a negative value is a penalty
-- each: true = counted per occurrence (each arrest, each wrong log); left out = once per run
-- block: the block a mission must contain to use it (left out = any mission)
-- engineOnly: true = awarded by the engine or a block's own setting (e.g. bestPoints); never listed by
-- builder:config, and the loader refuses it in a mission file's bonuses or penalties.
Config.Bonuses = {
    no_participant_downed = { kind = 'pct', value = 0.10 },
    no_weapons_fired = { kind = 'points', value = 10 },
    hostile_arrested = { kind = 'points', value = 5, each = true, block = 'hostile_waves' },
    suspect_alive = { kind = 'points', value = 15, block = 'flee_arrest' },
    no_hostage_hurt = { kind = 'points', value = 15, block = 'protect_rescue' },
    vehicle_stopped_fast = { kind = 'points', value = 15, block = 'pursuit' },  -- stopped within 2 min of the start
    truck_healthy = { kind = 'pct', value = 0.10, block = 'escort' },           -- arrives above 50% health
    -- every clue checked before the first arrest
    clues_first = { kind = 'points', value = 10, block = 'search_area' },
    no_missed_checks = { kind = 'points', value = 15, block = 'skill_check' },
    correct_log = { kind = 'points', value = 5, each = true, block = 'interact_points' },
    wrong_log = { kind = 'points', value = -5, each = true, block = 'interact_points' },  -- penalty
    -- penalty: ramming at over 100 km/h
    hard_ram = { kind = 'points', value = -10, each = true, block = 'pursuit' },
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
    lab_fire = { kind = 'points', value = -15, block = 'skill_check' },                 -- penalty: setback
    cook_arrested = { kind = 'points', value = 10, each = true, block = 'flee_arrest' },
    stash_found_fast = { kind = 'points', value = 10, block = 'interact_points' },
    lieutenant_alive = { kind = 'points', value = 25, block = 'hostile_waves' },
    -- claimed server-posted mission calls
    rapid_response = { kind = 'pct', value = 0.10, engineOnly = true },
    -- penalty: shot a real suspect who was never armed
    rs_unarmed_shot = { kind = 'pct', value = -0.25, each = true, engineOnly = true },
    -- penalty: ran a real suspect over on foot
    rs_ran_over = { kind = 'pct', value = -0.25, each = true, engineOnly = true },
    live_scene = { kind = 'pct', value = 0.25, engineOnly = true },                     -- live case: secured the scene
    -- live case: per suspect detained (x his share)
    live_detain = { kind = 'pct', value = 0.50, each = true, engineOnly = true },
    -- live case: per suspect booked (x his share)
    live_book = { kind = 'pct', value = 0.25, each = true, engineOnly = true },
    -- live case: per suspect detained after a surrender, no officer hit (x his share)
    peaceful_arrest = { kind = 'pct', value = 0.15, each = true, engineOnly = true },
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
    maxLevel = 50,           -- the last numbered level
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

-- Each officer gets one goal a day and one a week, drawn from the lists below; finishing it earns its points.
-- A goal's stat is one of: arrests, citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok
-- (Best or Acceptable), decisions_best. Stat goals count completed rows only.
Config.Goals = {
    dailyPoints = 50,        -- points for finishing the daily goal
    weeklyPoints = 200,      -- points for finishing the weekly goal
    -- The goals a daily goal is drawn from: id (unique), label (shown to the officer), count (how many) and at most
    -- one of type (a mission type), unit = true (unit runs), missionCall = true (answered calls), crossDepartment =
    -- true (runs with 2+ departments) or stat (above); none of them = any completed mission
    daily = {
        { id = 'patrol_2', label = 'Complete 2 Patrol missions', type = 'patrol', count = 2 },
        { id = 'any_3', label = 'Complete 3 missions of any type', count = 3 },
        { id = 'unit_1', label = 'Complete 1 unit run', unit = true, count = 1 },
        { id = 'calls_2', label = 'Answer 2 mission calls', missionCall = true, count = 2 },
        { id = 'arrests_2', label = 'Make 2 arrests', stat = 'arrests', count = 2 },
    },
    weekly = {                   -- the goals a weekly goal is drawn from (the same fields as daily)
        { id = 'tactical_5', label = 'Complete 5 Tactical missions', type = 'tactical', count = 5 },
        { id = 'cross_2', label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 },
        { id = 'any_15', label = 'Complete 15 missions', count = 15 },
        { id = 'judgement_15', label = 'Make 15 correct decisions', stat = 'decisions_ok', count = 15 },
        { id = 'impound_3', label = 'Impound 3 vehicles', stat = 'impounds', count = 3 },
    },
}

-- ============================================================================
--                           ITEM REWARDS (OPTIONAL)
-- ============================================================================
-- Off by default. Admin config only: mission files and the Mission Builder never hold rewards.
-- Items must exist in ox_inventory. Never weapons, ammo, armour, bandages or money items.
Config.Rewards = {
    enabled = false,                 -- true = officers can earn items (see the rules above)
    allowTakeBack = false,           -- Admin UI: take a given item back from an online officer (needs ENABLE)
    dailyItemCap = 10,               -- items per officer per day, every source together
    dailyValueCap = 2000,            -- total value of those items per officer per day
    findBonus = 0.10,                -- each lawful evidence find adds this to the run's chance...
    findBonusMax = 0.30,             -- ...up to this much
    -- added to the chance at each scaling tier (0-1; tiers as in Config.Scaling)
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
    goals = {},                      -- items for finished goals, by daily and weekly
    levels = {},                     -- e.g. [10] = { item = 'radio', count = 1, value = 150 }
    weeklyBoss = nil,                -- a guaranteed item for a completed Weekly Boss
    season = {},                     -- items at a season's end, by champion and top10
    -- matched case-insensitively (WEAPON_PISTOL is refused too)
    forbidden = { 'weapon_*', 'ammo-*', 'armour', 'bandage', 'money', 'black_money', 'cash' },
    useExamplePools = false,         -- true = use examplePools for any type byType leaves empty
    -- Example: safe values (default ox_inventory consumables), by mission type
    -- chance: 0-1, the chance of each roll to give an item
    -- rolls: how many times a finished run rolls
    -- pool: the items one roll picks from: item (ox_inventory name), count (a number or { min, max }), weight (how
    -- likely against the others) and value (dollars, for dailyValueCap)
    examplePools = {
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
--                               FEATURE REWARDS
-- ============================================================================
-- Money and items for the features outside a mission's own pay: the volunteer who plays a suspect, the officer who
-- talks a suspect down, field training and supervisor point awards. Each feature has its own switch (all ship off,
-- so nothing pays until you turn one on in Admin UI -> Settings -> Features) and a money amount ready to use. Every
-- payment is a row of the payments ledger (Admin UI -> Payments: audited, paid once per case, pending until the
-- player logs in, Config.Cash.dailyCap applies). Items are given only while Config.Rewards.enabled is on, under its
-- daily caps, and must exist in ox_inventory (never weapons, ammo or the forbidden names of Config.Rewards).
-- An items list holds { item = 'water', count = 1, chance = 1.0, value = 20 } entries: count a number or { min, max
-- }, chance 0-1 for each payment, value in dollars for Config.Rewards.dailyValueCap.
Config.FeatureRewards = {
    -- The volunteer suspect (the criminal player of Config.Volunteers), paid once per case, and only for a case the
    -- server saw end fairly: officers reached him, he did not drop out or go AFK and his part was not void
    suspect = {
        enabled = false,             -- true = a volunteer suspect is paid for a fair case
        account = 'cash',            -- 'bank' | 'cash' | 'item' (the money is the item named in moneyItem)
        moneyItem = 'black_money',   -- the dirty-money item paid when account = 'item' (must exist in ox_inventory)
        money = {
            got_away = 1500,         -- dollars when he escaped
            caught = 500,            -- dollars when he was detained or booked (he played the part to the end)
        },
        items = {},                  -- items for a fair case (see the list shape above)
    },
    -- The officer who talked a live-case suspect down (Talk them down), paid once per suspect when the peaceful
    -- arrest counts (the suspect was not AFK)
    surrender = {
        enabled = false,             -- true = the officer who talked a suspect down is paid
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 300,                 -- dollars per peaceful arrest
        items = {},                  -- items per peaceful arrest
    },
    -- Field training (Config.FieldTraining): the trainer for each task he signs off
    ftoSignOff = {
        enabled = false,             -- true = the trainer is paid for each sign-off
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 250,                 -- dollars per task signed off
        items = {},                  -- items per task signed off
    },
    -- Field training: the rookie once every task is signed off and his training is done
    ftoComplete = {
        enabled = false,             -- true = the rookie is paid when his training is done
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 1000,                -- dollars for the finished training
        items = {},                  -- items for the finished training
    },
    -- Supervisor point awards (the Give points Mission control): the officer who got the points
    supAward = {
        enabled = false,             -- true = an officer given points by a supervisor is paid too
        account = 'bank',            -- 'bank' | 'cash' | 'item'
        moneyItem = 'black_money',   -- the money item when account = 'item'
        money = 5,                   -- dollars per point awarded
        maxMoney = 2500,             -- dollars one award pays at most (0 = no limit)
        items = {},                  -- items per award
    },
}

-- ############################################################################
--                               PART 6 · SYSTEM
-- Run limits, anti-exploit checks, the daily reset, admin test mode, retention, backups and webhooks.
-- Usually changed here: Time.resetHour (when the day starts) and how long old data is kept (Retention).
-- ############################################################################

-- ============================================================================
--                                  RUN LIMITS
-- ============================================================================
-- Caps for each run and for the whole server, with the request limits of the tablet.
Config.Limits = {
    maxUnitSize = 4,             -- officers in one unit at most
    maxArmedAlive = 25,          -- armed NPCs alive at any one moment per run
    maxEntities = 80,            -- spawned entities at any one moment per run
    corpseCleanup = 30,          -- seconds before dead NPCs and wrecked vehicles are deleted (bodies a
                                 -- Process the scene objective keeps are deleted when it ends)
    maxCompletionsHour = 8,      -- completed runs per officer per hour
    maxCompletionsDay = 0,       -- completed runs per officer per day (from the daily reset); 0 = no cap
    abandonCooldown = 300,       -- seconds; covers the whole mission type
    startTimeout = 600,          -- default seconds to reach the start (a mission can override it)
    maxConcurrentRuns = 12,      -- runs active server-wide at once; Cross-Department Missions don't count
    maxConcurrentTactical = 4,   -- of those, Tactical runs
    reserveLocations = true,     -- a location in use by one run can't be drawn for another
    -- Milliseconds a player's Qbox data (job, duty, name, callsign) is reused before Qbox is asked again; every Qbox
    -- job, duty or data change clears it at once; 0 = ask Qbox every time (the old behaviour)
    playerInfoCacheMs = 1000,
    -- What happens when a player keeps sending one tablet request past its limit (most allow 6 to 8 a second):
    -- 'block' = the extra requests are refused quietly, as before; 'log' = also one console warning a minute per
    -- player once one request is refused 3 times its limit (at least 20 times) in a minute; 'kick' = that warning,
    -- and the player is dropped from the server. Admins are never warned about or dropped for this
    netRateResponse = 'block',
    -- Bytes a second for the big Admin UI downloads (Audit and Payments → Export, up to 5000 rows): they come in the
    -- background, so the rest of the tablet keeps answering while one loads (below 100000 counts as 100000; 0 = send
    -- each one in one go, as before)
    exportBps = 200000,
}

-- ============================================================================
--                                 ANTI-EXPLOIT
-- ============================================================================

Config.AntiCheat = {
    maxSpeed = 80.0,        -- m/s between objective events before a run is flagged
    presenceRadius = 150.0, -- runs with 2+ participants: fallback presence range for a block with none of its own...
    presenceShare = 0.70,   -- ...for this share of the run to earn points and cash
    -- seconds after the run moves to In progress to remove participants who haven't reached the start
    idleCheck = 180,
    jobRecheck = 10,        -- seconds between active-job and duty re-checks during a run
    outsideKillsToFlag = 1, -- kills of mission NPCs by players who aren't on the run that flag it for review
    voidsToSuspend = 3,     -- this many voided runs...
    voidWindowDays = 30,    -- ...within this many days...
    suspendDays = 7,        -- ...suspends the officer for this many days

    stunNeedsProof = 'flag',  -- 'flag' = a stun counts as before, and one the server did not see (no fall) adds a
                              -- note for staff (nobody's points are held); 'hold' = the same, but that officer's
                              -- points wait for review; 'strict' = a fleeing person only gives up to a stun the
                              -- server saw; 'off' = no check (the old way)
    stunRecheck = 2,          -- seconds 'flag' and 'hold' wait before the note or flag: a report that reaches the
                              -- server before its copy of the suspect shows the fall gets no note when the fall
                              -- shows by then. 0 = decide at once

    -- A player who is not an admin sends a request only admins may send (the money, void and other Admin UI tools;
    -- no officer or supervisor screen sends one, so it is almost always a cheat menu). It is refused as always, and
    -- a console line, kept in Admin UI → System → Problems, names the player and the request: once a minute per
    -- player and request, at most this many lines a minute per player. 0 = refused without a line.
    adminProbeLines = 5,
}

-- ============================================================================
--                                     TIME
-- ============================================================================
-- Hour (0–23, server time) of the daily reset: Type of the Day, daily goals,
-- streak days, the daily cash cap and the retention job. Weekly things reset
-- at this hour on Config.Leaderboard.weekStartsOn.
Config.Time = { resetHour = 0 }

-- ============================================================================
--                               ADMIN TEST MODE
-- ============================================================================

Config.Testing = {
    enabled = true,        -- true = admins may run test runs of missions (Admin test mode)
    maxTesters = 8,        -- players in one test run, including the admin
    useStartRoute = false, -- default for the start-route toggle
    allowTeleport = true,  -- teleport controls in test runs
    debugOverlay = true,   -- the debug overlay control
    -- Default key of the admin test panel and the test invitation (each admin or tester can rebind it in GTA Settings ->
    -- Key Bindings -> FiveM; this default only reaches players who never bound it; '' = no default key). Not F9:
    -- sc-multijob uses F9
    panelKey = 'F7',
    -- Milliseconds (0-1000) the test controls key is ignored after the panel or the invitation prompt gives your mouse
    -- and keyboard back, so the press that let go does not take the panel straight back (0 = off)
    panelKeyGuardMs = 300,
    -- Check spawn points (Admin UI -> Testing): your own game visits every point of a mission's locations and tells
    -- you which ones are under the ground, floating, in water, in a wall or inside a building that never loads. It
    -- spawns nothing and moves only you (unseen and unhurt, back where you were afterwards)
    spawnCheck = {
        enabled = true,         -- false = no spawn point check
        -- Milliseconds (1000-30000) your game waits for the map around a location to load before checking its points
        sceneTimeoutMs = 8000,
        -- Metres (0-400): points further than this from where you are are checked from right over them (you are moved
        -- there); closer ones from where you stand (0 = move to every point)
        moveWithin = 150.0,
        -- true = also check every point of the routes (where cars drive and suspects run), which takes much longer;
        -- false = only where people, vehicles and objects appear and the objective markers
        routes = false,
        teleport = true,        -- the "Teleport here" button next to a checked point (puts you on the ground there)
    },
}

-- ============================================================================
--                                  RETENTION
-- ============================================================================

Config.Retention = {
    runArchiveMonths = 12,  -- move older runs to cp_mission_runs_archive; 0 = never
    auditDays = 180,        -- delete older audit rows; 0 = keep forever
    missionCallDays = 90,   -- delete older mission call history; 0 = keep forever
}

-- ============================================================================
--                                   BACKUPS
-- ============================================================================
-- Admin UI → System → Backups: copies of every Crimson-Police table and the mission files, in saves/_backups.
Config.Backups = {
    keep = 7,               -- backups kept; the newest and the latest automatic one are never removed
    daily = false,          -- true = one backup at every daily reset
    -- true = after a restore that stopped part way, payments and new runs stay held (also after a restart) until a
    -- restore works; false = a restart ends that lock and the server goes on with the store as it is
    holdAfterFailedRestore = true,
}

-- Discord webhooks are read from convars in server.cfg, never stored here.
-- A convar that is missing or empty turns that webhook off.
--   set cp_webhook_board      "https://discord.com/api/webhooks/..."   (weekly top 3, season results)
--   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   (payout changes and admin actions)
--   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   (flagged runs, voids, disputes)
--   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   (publish, archive, rollback, lock breaks, code edits)
--   set cp_webhook_operations "https://discord.com/api/webhooks/..."   (Cross-Department launches and results)
