-- config/config.lua · every Crimson-Police setting. If this file and the spec disagree, this file wins.

Config = {}

Config.Debug  = false            -- true = each module prints tagged debug lines
Config.Locale = 'en'

-- ── Tablet and commands ─────────────────────────────────────────────────────
Config.Tablet = {
  title        = 'Crimson-Police',       -- app title on every screen
  command      = 'CrimsonPolice',        -- opens the Officer UI
  adminCommand = 'CrimsonPoliceAdmin',   -- opens the Admin UI; also takes subcommands
  keybind      = '',                     -- default key ('' = none; players can bind it in GTA settings)
  item         = false,                  -- ox_inventory item name that also opens the tablet, or false
  prop         = 'prop_cs_tablet',       -- prop held while the Officer UI is open
}

Config.AdminAce   = 'crimsonpolice.admin'   -- the admin permission; supervisors come from job grade
Config.AdminTheme = { primary = '#a4161a', accent = '#e5383b', background = '#0b090a', surface = '#161a1d', text = '#f5f3f4' }

-- ── Permissions ─────────────────────────────────────────────────────────────
-- What supervisors may do. Admins can always do every admin action.
-- false hides the action in the Supervisor UI, and the server refuses it.
Config.Permissions = {
  supervisor = {
    setTypePayout   = true,    -- within Config.Payouts limits; never a type an admin has set
    launchCrossDept = true,    -- launch, start now, relaunch and cancel
    forceRecall     = true,
    reviewFlagged   = true,    -- approve or void flagged runs involving their department
    handleDisputes  = true,    -- disputes about flagged or voided runs in their department
    builderEdit     = true,    -- create, edit, record routes and test their own missions
    builderPublish  = true,    -- publish their own tested drafts
    builderArchive  = true,    -- archive or restore their own missions
    builderEditAny  = false,   -- also edit, publish and archive other people's custom missions
    builderRollback = false,   -- roll a custom mission back to its previous version
    breakEditLock   = false,   -- unlock a mission someone else is editing
  },
  -- Always admin-only, whatever is set above: single-mission payouts, clearing
  -- admin payouts, manual awards, disputes about failed runs, voiding any run,
  -- seasons, the bounty override, suspensions, reloading mission files and test runs.
  -- Nobody may approve, void or answer a dispute about a run they took part in.
}

-- ── Departments ─────────────────────────────────────────────────────────────
-- Every entry is used automatically for access, the tablet name, colours and
-- logo watermark, leaderboards, the department challenge, unit invites and the
-- Mission Builder. Add a block, put its logo in logos/, restart. No code or SQL changes.
Config.Departments = {
  sast = {
    label           = 'San Andreas State Troopers',  -- shown in the tablet header
    short           = 'SAST',                        -- tag on boards, units and badges
    jobs            = { 'sast' },                    -- Qbox job names (as in sc-police / sc-dispatch)
    supervisorGrade = 3,                             -- Qbox grade level; set to your real grade
    societyAccount  = 'sast',                        -- only used when Config.Cash.source = 'society'
    theme = {
      primary    = '#1f4e8c',   -- header, buttons, active tab, progress bars
      accent     = '#f2c230',   -- highlights, badges, focus outlines
      background = '#0d1522',   -- tablet body
      surface    = '#152235',   -- cards, tables, dialogs
      -- text    = '#ffffff',   -- optional; picked automatically for contrast when left out
    },
    logo = {
      file      = 'sast.png',   -- file in logos/ (or use url = 'https://...')
      watermark = true,         -- draw the logo behind every screen
      opacity   = 0.08,         -- 0.0 to 0.25
      size      = 0.6,          -- share of the tablet height
      grayscale = false,
    },
  },
  fib = {
    label           = 'Federal Investigation Bureau',
    short           = 'FIB',
    jobs            = { 'fib' },
    supervisorGrade = 3,
    societyAccount  = 'fib',
    theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' },
    logo  = { file = 'fib.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
  },
  -- Example: to add BCSO, uncomment and edit this block, then put bcso.png in logos/ and restart.
  -- bcso = {
  --   label = "Blaine County Sheriff's Office", short = 'BCSO', jobs = { 'bcso' },
  --   supervisorGrade = 3, societyAccount = 'bcso',
  --   theme = { primary = '#5c4033', accent = '#d4a017', background = '#14100c', surface = '#231c16' },
  --   logo  = { file = 'bcso.png', watermark = true, opacity = 0.08, size = 0.6, grayscale = false },
  -- },
}

-- ── Mission types ───────────────────────────────────────────────────────────
-- points: leaderboard points, config only (never editable in-game).
-- payout: default base cash payout. Supervisors and admins change it in-game;
-- admin-set values are stored permanently in cp_type_payouts.
Config.MissionTypes = {
  patrol        = { label = 'Patrol',        points = 60,  payout = 250 },
  training      = { label = 'Training',      points = 100, payout = 350 },
  investigation = { label = 'Investigation', points = 160, payout = 600 },
  tactical      = { label = 'Tactical',      points = 200, payout = 800 },
}

Config.DisabledMissions = {}   -- built-in mission ids to turn off, e.g. { 'prison_break' }

-- ── Difficulty (stars) ──────────────────────────────────────────────────────
-- Multipliers by a mission's difficulty: index 1, 2 or 3 stars.
-- 1.0 = stars change nothing, so a builder can't raise pay or points by picking 3 stars.
Config.Difficulty = {
  pointsByStars = { 1.0, 1.0, 1.0 },
  cashByStars   = { 1.0, 1.0, 1.0 },
}

-- ── Cash ────────────────────────────────────────────────────────────────────
Config.Cash = {
  account   = 'bank',     -- 'bank' or 'cash'
  source    = 'server',   -- 'server' (new money) or 'society' (the department's Renewed-Banking account)
  minPayout = 0,          -- limits for any base payout set in-game
  maxPayout = 25000,
  dailyCap  = 0,          -- max cash per officer per day; 0 = no cap
}

-- ── Payout editing ──────────────────────────────────────────────────────────
Config.Payouts = {
  supervisorRange    = { 0.5, 2.0 },  -- supervisors: 50%–200% of the type's payout in Config.MissionTypes
  supervisorCooldown = 1800,          -- seconds between changes to the same type (any supervisor)
  requireReason      = true,          -- a reason is required for every payout change
}

-- ── Scaling by participants ─────────────────────────────────────────────────
-- The first row whose maxParticipants >= the participant count is used.
Config.Scaling = {
  { maxParticipants = 1, tier = 'standard',   count = 1.0,  accuracy = 0,  armour = 0,  points = 1.00, cash = 1.00 },
  { maxParticipants = 2, tier = 'reinforced', count = 1.25, accuracy = 5,  armour = 10, points = 1.10, cash = 1.15 },
  { maxParticipants = 4, tier = 'heavy',      count = 1.5,  accuracy = 10, armour = 25, points = 1.15, cash = 1.30 },
  { maxParticipants = 6, tier = 'major',      count = 2.0,  accuracy = 15, armour = 50, points = 1.20, cash = 1.50 },
  { maxParticipants = 8, tier = 'critical',   count = 2.5,  accuracy = 20, armour = 75, points = 1.25, cash = 1.75 },
}
Config.CrossDepartmentPoints = 1.10    -- points multiplier when 2+ departments are on a run

-- When the team shrinks mid-run (see When someone leaves mid-run)
Config.Rescale = {
  enabled        = true,   -- NPCs not yet spawned use the tier for the team that's left
  keepPayTierFor = { 'real_call', 'force_recall', 'downed' },  -- leave reasons that keep the points and cash tier
}

Config.Limits = {
  maxUnitSize           = 4,
  maxArmedAlive         = 25,    -- armed NPCs alive at any one moment per run
  maxEntities           = 80,    -- spawned entities at any one moment per run
  corpseCleanup         = 30,    -- seconds before dead NPCs and wrecked vehicles are deleted
  maxCompletionsHour    = 8,
  abandonCooldown       = 300,   -- seconds; covers the whole mission type
  startTimeout          = 600,   -- default seconds to reach the start (a mission can override it)
  maxConcurrentRuns     = 12,    -- runs active server-wide at once; Cross-Department Missions don't count
  maxConcurrentTactical = 4,     -- of those, Tactical runs
  reserveLocations      = true,  -- a location in use by one run can't be drawn for another
}

-- ── Police vehicles ─────────────────────────────────────────────────────────
-- Used wherever a mission needs "a police vehicle" (Beat Patrol, EVOC Course,
-- and checkpoint_route with "Police vehicle required" on).
Config.PoliceVehicles = {
  classes = { 18 },   -- GTA vehicle classes; 18 = Emergency
  models  = {},       -- extra model names for police cars outside class 18 (e.g. add-on unmarked cars)
}

-- ── Route to the start ──────────────────────────────────────────────────────
Config.Route = {
  sampleEvery   = 50.0,    -- metres between points taken from the GPS route
  reportEvery   = 2,       -- seconds between client reports
  reportTimeout = 10,      -- no report for this long counts as off route
  maxDeviation  = 120.0,   -- metres from the line before a participant is off route
  warnAfter     = 10,      -- seconds off route before the warning
  abandonAfter  = 30,      -- seconds off route in one stretch before Abandoned (back on route resets it)
  maxRecalcs    = 2,       -- Recalculate route taps per participant per run
  maxDrift      = 1000.0,  -- server check: metres further from the start than the closest they have been
}

-- ── Real calls ──────────────────────────────────────────────────────────────
Config.Calls = {
  npcCallPrefix      = 'npccall-',   -- SC-NPCPolice call ids start with this; those calls never end a run
  ownRunCallPrefixes = { 'playerdown_', 'playerdead_', 'emsdown_', 'emshelp_', 'panic_' }, -- about a participant: not real calls for their partners
  dodgeWindow        = 60,           -- un-marking responding within this many seconds makes it a normal abandon
  respondingExpiry   = 1200,         -- seconds; a responding entry with no update expires (auto-cleared calls fire no event)
}

-- ── Alert suppression ───────────────────────────────────────────────────────
-- The flag is the crimsonArena state bag, which SC-Dispatch and SC-Ambulance
-- already check; its name is fixed in those resources, so it is not configurable.
Config.Alerts = {
  backstopRadius = 300.0,   -- clear a shots-fired call from a participant within this many metres of their mission (person-down and dead calls are cleared while the flag is on)
  backstopDelay  = 1,       -- seconds to wait for SC-Dispatch to create the call before clearing it
}

-- ── Downed participants ─────────────────────────────────────────────────────
Config.Downed = {
  checkEvery  = 2,      -- seconds between downed checks
  pickupDelay = 15,     -- seconds down, with no EMS on duty, before the pick-up
  dropOffs    = {       -- the nearest one is used; defaults are SC-Ambulance's check-in points
    vec3(308.19, -595.35, 43.29),     -- Pillbox Hill
    vec3(-254.54, 6331.78, 32.43),    -- Paleto Bay
  },
}

-- ── Anti-exploit ────────────────────────────────────────────────────────────
Config.AntiCheat = {
  maxSpeed       = 80.0,    -- m/s between objective events before a run is flagged
  presenceRadius = 150.0,   -- runs with 2+ participants: fallback presence range for a block with none of its own...
  presenceShare  = 0.70,    -- ...for this share of the run to earn points and cash
  idleCheck      = 180,     -- seconds after the run moves to In progress to remove participants who haven't reached the start
  jobRecheck     = 10,      -- seconds between active-job and duty re-checks during a run
  outsideKillsToFlag = 1,   -- kills of mission NPCs by players who aren't on the run that flag it for review
  voidsToSuspend = 3,       -- this many voided runs...
  voidWindowDays = 30,      -- ...within this many days...
  suspendDays    = 7,       -- ...suspends the officer for this many days
}

-- ── Cross-Department Missions ───────────────────────────────────────────────
Config.CrossDept = {
  enabled         = true,
  minParticipants = 2,
  maxParticipants = 8,
  joinWindow      = 300,     -- seconds until joining closes (or the launcher taps Start now)
  idleCancel      = 1800,    -- auto-cancel after this long with no run in progress
  cooldown        = 1800,    -- seconds between launches, server-wide
}

-- ── Random draw ─────────────────────────────────────────────────────────────
Config.Draw = {
  avoidLast       = 1,       -- never repeat the last mission in that type
  avoidLastLarge  = 2,       -- skip the last two when the pool has largePool+ missions
  largePool       = 4,
  playerClearance = 75.0,    -- skip locations with a non-participant within this many metres
}

-- ── Time ────────────────────────────────────────────────────────────────────
-- Hour (0–23, server time) of the daily reset: Type of the Day, daily goals,
-- streak days, the daily cash cap and the retention job. Weekly things reset
-- at this hour on Config.Leaderboard.weekStartsOn.
Config.Time = { resetHour = 0 }

-- ── Scoring, XP levels and goals ────────────────────────────────────────────────
Config.Scoring = {
  scoreCap     = 2.0,        -- × P
  streakStep   = 0.05,
  streakMax    = 0.25,
  streakGraceDays = 1,       -- missed days per week that don't reset the streak (0 = off)
  failedCredit = 0.25,
  common = {
    fastShare       = 0.75,  -- finished within this share of the time limit...
    fastBonus       = 0.20,  -- ...earns this share of P
    noDamage        = 10,
    firstRun        = 15,
    heavyDamage     = -25,
    pedestrianHit   = -30,
    lightsSiren     = -10,   -- Beat Patrol and Business Check only
    shotSurrendered = -20,
    noDamageAbove   = 950,   -- engine and body health above this earns noDamage
    heavyDamageBelow = 500,  -- body health below this costs heavyDamage
  },
}

-- ── Bonuses and penalties ───────────────────────────────────────────────────
-- The standard list, and the only one the Mission Builder offers. kind 'points'
-- = flat points (each = per occurrence); kind 'pct' = a share of P. block = the
-- block the mission must contain (none = any mission). Ids with positive values go in a mission file's bonuses,
-- negative ones in its penalties; either may override the value with points or pctOfPoints.
-- Labels live in locales/en.json. Built-in missions may also use the extra
-- bonuses written on their mission cards.
Config.Bonuses = {
  no_participant_downed = { kind = 'pct',    value = 0.10 },
  no_weapons_fired      = { kind = 'points', value = 10 },
  hostile_arrested      = { kind = 'points', value = 5,    each = true, block = 'hostile_waves' },
  suspect_alive         = { kind = 'points', value = 15,   block = 'flee_arrest' },
  no_hostage_hurt       = { kind = 'points', value = 15,   block = 'protect_rescue' },
  vehicle_stopped_fast  = { kind = 'points', value = 15,   block = 'pursuit' },          -- stopped within 2 minutes of the start
  truck_healthy         = { kind = 'pct',    value = 0.10, block = 'escort' },           -- arrives above 50% health
  clues_first           = { kind = 'points', value = 10,   block = 'search_area' },      -- every clue checked before the first arrest
  no_missed_checks      = { kind = 'points', value = 15,   block = 'skill_check' },
  correct_log           = { kind = 'points', value = 5,    each = true, block = 'interact_points' },
  wrong_log             = { kind = 'points', value = -5,   each = true, block = 'interact_points' },  -- penalty
  hard_ram              = { kind = 'points', value = -10,  each = true, block = 'pursuit' },          -- penalty: ramming at over 100 km/h
}

Config.XPLevels = {   -- cosmetic badges only; never the Qbox rank
  { label = 'Probationary',   xp = 0,     badge = 'grey' },
  { label = 'Patrol Officer', xp = 1000,  badge = 'bronze' },
  { label = 'Senior Patrol',  xp = 5000,  badge = 'silver' },
  { label = 'Veteran',        xp = 15000, badge = 'gold' },
  { label = 'Elite',          xp = 40000, badge = 'platinum' },
}

Config.Badges = {            -- achievement badge counts
  ironWheels     = 20,   -- completed runs with no vehicle damage
  sharpshooter   = 10,   -- Gang Shootouts with no participant downed
  roadWarrior    = 100,  -- Patrol missions
  partnerInCrime = 50,   -- unit runs
  jointTaskForce = 10,   -- runs with 2 or more departments
}

Config.Goals = {
  dailyPoints  = 50,
  weeklyPoints = 200,
  daily = {
    { id = 'patrol_2', label = 'Complete 2 Patrol missions',      type = 'patrol', count = 2 },
    { id = 'any_3',    label = 'Complete 3 missions of any type', count = 3 },
    { id = 'unit_1',   label = 'Complete 1 unit run',             unit = true, count = 1 },
  },
  weekly = {
    { id = 'tactical_5', label = 'Complete 5 Tactical missions',     type = 'tactical', count = 5 },
    { id = 'cross_2',    label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 },
    { id = 'any_15',     label = 'Complete 15 missions',             count = 15 },
  },
}

-- ── Leaderboard ─────────────────────────────────────────────────────────────
Config.Leaderboard = {
  cacheSeconds  = 60,
  minRunsToRank = 3,
  topN          = 25,
  weekStartsOn  = 'monday',
  seasonWeeks   = 8,         -- suggested season length for "weeks left"; an admin ends the season
}

-- ── Special events ──────────────────────────────────────────────────────────
Config.Events = {
  typeOfTheDay   = true,
  todMultiplier  = 2.0,      -- points only
  modifierChance = 0.25,
  modifierPoints = 0.25,     -- +25% of P
  modifierCash   = 1.25,     -- × cash
  armoredArmour  = 50,       -- Armored Hostiles: extra armour on armed NPCs (Tactical only)
  timeCrunchCut  = 0.25,     -- Time Crunch: share of the time limit removed
  weeklyBoss     = { enabled = true, days = { 'friday', 'saturday', 'sunday' }, points = 500, payout = 2500 },
}

-- ── Department challenge ────────────────────────────────────────────────────
Config.Challenge = {
  enabled       = true,
  scoring       = 'average',   -- 'average' (per active officer) | 'total' | 'top10'
  minRunsActive = 3,
  weeklyBounty  = true,
  bountyBonus   = 0.10,
  bounties = {                 -- one is picked at random each week; counted per active officer
    { id = 'most_tactical',  label = 'Most Tactical missions' },
    { id = 'most_cross',     label = 'Most cross-department runs' },
    { id = 'most_unit',      label = 'Most unit runs' },
    { id = 'most_completed', label = 'Most completed runs' },
  },
}

-- ── Disputes ────────────────────────────────────────────────────────────────
Config.Disputes = { windowHours = 48 }

-- ── Mission Builder ─────────────────────────────────────────────────────────
-- Block setting ranges and defaults are in config/blocks.lua.
Config.Builder = {
  enabled           = true,
  maxHostiles       = 40,       -- armed NPCs per mission across all blocks, before scaling
  maxBlocks         = 6,
  minLocations      = 3,
  minLocationGap    = 100.0,    -- metres between locations of one mission
  minSpawnFromStart = 30.0,     -- metres between any spawn point and the start point
  bonusCap          = { points = 50, share = 0.25 },  -- flat bonuses and penalties: at most 50 points; percentage ones: at most 25% of P
  testAtMaxTier     = true,     -- publishing needs a passed test at the tier maxOfficers reaches
  editLockMinutes   = 30,       -- one editor at a time; renewed while they keep editing
  autosaveSeconds   = 30,
  exportPath        = 'missions/custom/',
  keepBackups       = true,     -- keep <mission_id>.v<version>.lua.bak on every publish
  route = {                     -- route recording (see Mission Builder, Route recording)
    snapEvery        = 25.0,    -- metres between samples while recording
    maxOffRoad       = 8.0,     -- samples further than this from a road node are rejected
    turnAngle        = 30.0,    -- heading change (degrees) that keeps a waypoint
    maxGap           = 150.0,   -- at least one waypoint this often, in metres
    minLength        = 800.0,
    maxLength        = 8000.0,
    minStartEndGap   = 300.0,   -- open routes: start and end at least this far apart
    loopClose        = 50.0,    -- a race loop must end this close to its start
    undoMetres       = 100.0,   -- Backspace removes this much of the recording
    testDriveTimeout = 30,      -- seconds to reach each waypoint in a test drive
  },
  allowed = {                   -- the only models, weapons and animations builders can pick
    weapons        = { 'WEAPON_PISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_MICROSMG', 'WEAPON_SMG', 'WEAPON_PUMPSHOTGUN', 'WEAPON_ASSAULTRIFLE' },
    peds           = { 'g_m_y_ballaeast_01', 'g_m_y_famca_01', 'g_m_y_mexgoon_01', 'g_m_y_lost_01', 'a_m_m_business_01', 'a_f_y_business_01' },
    vehicles       = { 'sultan', 'buffalo', 'elegy2', 'kuruma', 'dominator' },
    escortVehicles = { 'stockade', 'stockade3' },
    animations     = { 'clipboard', 'search', 'kneel', 'mechanic' },
  },
  noBuildZones = {              -- no spawn point, marker or route waypoint inside these
    { label = 'Mission Row PD and FIB HQ', coords = vec3(470.63, -974.11, 30.18),  radius = 120.0 },
    { label = 'Sandy Shores BCSO',         coords = vec3(1833.06, 3679.32, 33.19), radius = 80.0 },
    { label = 'SASP HQ',                   coords = vec3(1560.38, 815.76, 76.21),  radius = 80.0 },
    { label = 'Pillbox Hill Medical',      coords = vec3(308.19, -595.35, 43.29),  radius = 100.0 },
    { label = 'Paleto Bay Medical',        coords = vec3(-254.54, 6331.78, 32.43), radius = 80.0 },
    { label = 'Bolingbroke interior',      coords = vec3(1768.73, 2570.43, 44.73), radius = 180.0 },  -- widen or move to fit your prison
  },
}

-- ── Admin test mode ─────────────────────────────────────────────────────────
Config.Testing = {
  enabled       = true,
  maxTesters    = 8,       -- players in one test run, including the admin
  useStartRoute = false,   -- default for the start-route toggle
  allowTeleport = true,    -- teleport controls in test runs
  debugOverlay  = true,    -- the debug overlay control
}

-- ── Retention ───────────────────────────────────────────────────────────────
Config.Retention = {
  runArchiveMonths = 12,    -- move older runs to cp_mission_runs_archive; 0 = never
  auditDays        = 180,   -- delete older audit rows; 0 = keep forever
}

-- Discord webhooks are read from convars in server.cfg, never stored here.
-- A convar that is missing or empty turns that webhook off.
--   set cp_webhook_board      "https://discord.com/api/webhooks/..."   (weekly top 3, season results)
--   set cp_webhook_audit      "https://discord.com/api/webhooks/..."   (payout changes and admin actions)
--   set cp_webhook_flags      "https://discord.com/api/webhooks/..."   (flagged runs, voids, disputes)
--   set cp_webhook_builder    "https://discord.com/api/webhooks/..."   (publish, archive, rollback, lock breaks, code edits)
--   set cp_webhook_operations "https://discord.com/api/webhooks/..."   (Cross-Department launches and results)
