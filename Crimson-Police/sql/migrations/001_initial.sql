-- sql/migrations/001_initial.sql · the full schema for a fresh install.
-- Released migration files are never edited: every later change is a new numbered file.
-- No semicolon may appear inside a comment or a string (the runner splits on line-ending semicolons).

CREATE TABLE IF NOT EXISTS cp_schema_migrations (   -- created by the migration runner before 001 runs
  version    INT PRIMARY KEY,                  -- the file's number, e.g. 1 for 001_initial.sql
  name       VARCHAR(100) NOT NULL,            -- the file name
  applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cp_officers (
  citizenid       VARCHAR(50) PRIMARY KEY,     -- Qbox citizenid
  callsign        VARCHAR(32) NULL,            -- copy of metadata.callsign (set by SC-Police), display only
  rank_label      VARCHAR(40) NULL,            -- copy of the Qbox job grade name, display only
  display_name    VARCHAR(64) NULL,
  department      VARCHAR(32) NULL,            -- key from Config.Departments
  xp              INT NOT NULL DEFAULT 0,
  streak_days     TINYINT NOT NULL DEFAULT 0,
  last_complete   DATE NULL,
  grace_week      DATE NULL,                   -- start of the week the grace count below belongs to
  grace_used      TINYINT NOT NULL DEFAULT 0,  -- missed days forgiven in that week
  hide_name       TINYINT(1) NOT NULL DEFAULT 0,
  suspended_until DATETIME NULL                -- Crimson-Police suspension (separate from SC-Dispatch)
);

CREATE TABLE IF NOT EXISTS cp_operations (                   -- Cross-Department Missions
  id          INT AUTO_INCREMENT PRIMARY KEY,
  mission_id  VARCHAR(40) NOT NULL,
  launched_by VARCHAR(50) NOT NULL,            -- citizenid of the supervisor or admin
  status      ENUM('joining','running','waiting','completed','cancelled') NOT NULL DEFAULT 'joining',
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,  -- the last launch starts Config.CrossDept.cooldown
  ended_at    DATETIME NULL
);

CREATE TABLE IF NOT EXISTS cp_mission_runs (                 -- one row per participant per run
  id              INT AUTO_INCREMENT PRIMARY KEY,
  run_uuid        VARCHAR(36) NOT NULL,        -- shared by every participant of one run
  operation_id    INT NULL,                    -- set for Cross-Department Missions
  mission_type    VARCHAR(32) NOT NULL,        -- a type key, 'manual_award' or 'goal'
  mission_id      VARCHAR(40) NOT NULL,
  mission_version SMALLINT NULL,               -- custom missions only
  location_label  VARCHAR(64) NULL,            -- the drawn location
  citizenid       VARCHAR(50) NOT NULL,
  department      VARCHAR(32) NOT NULL,        -- participant's department when the run ended
  season_id       INT NULL,
  participants    TINYINT NOT NULL DEFAULT 1,
  departments_n   TINYINT NOT NULL DEFAULT 1,  -- distinct departments on the run
  tier            ENUM('standard','reinforced','heavy','major','critical') NOT NULL DEFAULT 'standard',  -- points and cash tier used for this row
  modifier        VARCHAR(20) NULL,
  state           ENUM('completed','failed','abandoned') NOT NULL,
  end_reason      VARCHAR(24) NOT NULL,        -- how this participant's run ended (see Mission lifecycle)
  points_base     SMALLINT NOT NULL,           -- P = the type's config points x star multiplier
  bonus_points    SMALLINT NOT NULL DEFAULT 0,
  penalty_points  SMALLINT NOT NULL DEFAULT 0,
  final_points    SMALLINT NOT NULL DEFAULT 0,
  cash_base       INT NOT NULL DEFAULT 0,      -- B, locked when the type was accepted
  cash_multiplier DECIMAL(4,2) NOT NULL DEFAULT 1.00,
  cash_paid       INT NOT NULL DEFAULT 0,
  cash_status     ENUM('none','held','pending','paying','paid','capped','unfunded','forfeited') NOT NULL DEFAULT 'none',
  duration_s      SMALLINT NOT NULL DEFAULT 0,
  breakdown       JSON NULL,                   -- points and cash breakdown shown on the tablet
  flagged         TINYINT(1) NOT NULL DEFAULT 0,
  flag_reason     VARCHAR(64) NULL,            -- why: 'outside_help', 'too_fast', 'speed', 'presence' or 'unexpected_event'
  voided          TINYINT(1) NOT NULL DEFAULT 0,
  created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_board  (created_at, citizenid, voided),
  INDEX idx_season (season_id, citizenid),
  INDEX idx_dept   (season_id, department),
  INDEX idx_draw   (citizenid, mission_type, created_at),
  INDEX idx_run    (run_uuid)
);

-- rows older than Config.Retention.runArchiveMonths
CREATE TABLE IF NOT EXISTS cp_mission_runs_archive LIKE cp_mission_runs;

CREATE TABLE IF NOT EXISTS cp_seasons (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  name      VARCHAR(64) NOT NULL,
  starts_at DATETIME NOT NULL,
  ends_at   DATETIME NULL,
  active    TINYINT(1) NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS cp_badges (
  citizenid VARCHAR(50) NOT NULL,
  badge_id  VARCHAR(40) NOT NULL,
  earned_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (citizenid, badge_id)
);

CREATE TABLE IF NOT EXISTS cp_custom_missions (
  id                   VARCHAR(40) PRIMARY KEY,
  mission_type         VARCHAR(32) NOT NULL,  -- required, sets points and base payout
  status               ENUM('draft','published','archived') NOT NULL DEFAULT 'draft',
  published_version    SMALLINT NULL,         -- the version players run now
  published_definition JSON NULL,             -- copy of the published file
  draft_version        SMALLINT NULL,         -- the next version, being edited in the builder
  draft_definition     JSON NULL,             -- autosaved every Config.Builder.autosaveSeconds
  draft_tested         TINYINT(1) NOT NULL DEFAULT 0,  -- 1 = passed a test run at the tier its maxOfficers reaches
  file_path            VARCHAR(128) NULL,     -- missions/custom/<id>.lua
  edited_in_code       TINYINT(1) NOT NULL DEFAULT 0,
  locked_by            VARCHAR(50) NULL,      -- citizenid editing it now
  locked_until         DATETIME NULL,         -- edit lock expiry (Config.Builder.editLockMinutes)
  created_by           VARCHAR(50) NOT NULL,
  updated_by           VARCHAR(50) NOT NULL,
  updated_at           DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cp_dept_bounties (
  season_id INT NOT NULL,
  week      TINYINT NOT NULL,
  objective VARCHAR(40) NOT NULL,             -- key from Config.Challenge.bounties
  winner    VARCHAR(32) NULL,                 -- department key
  PRIMARY KEY (season_id, week)
);

CREATE TABLE IF NOT EXISTS cp_type_payouts (                 -- base cash payout per mission type
  mission_type VARCHAR(32) PRIMARY KEY,        -- key from Config.MissionTypes
  amount       INT NOT NULL,
  admin_locked TINYINT(1) NOT NULL DEFAULT 0,  -- 1 = set by an admin: permanent, read-only for supervisors
  updated_by   VARCHAR(50) NOT NULL,
  updated_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP  -- also times the supervisor cooldown
);

CREATE TABLE IF NOT EXISTS cp_mission_payouts (              -- admin only, permanent until an admin clears it
  mission_id VARCHAR(40) PRIMARY KEY,
  amount     INT NOT NULL,
  set_by     VARCHAR(50) NOT NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS cp_disputes (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  run_id     INT NOT NULL,                     -- cp_mission_runs.id
  citizenid  VARCHAR(50) NOT NULL,
  reason     VARCHAR(255) NOT NULL,
  goes_to    ENUM('supervisor','admin') NOT NULL, -- flagged or voided run: supervisor, failed run: admin
  status     ENUM('open','approved','rejected') NOT NULL DEFAULT 'open',
  handled_by VARCHAR(50) NULL,                 -- never a participant of that run
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  handled_at DATETIME NULL
);

CREATE TABLE IF NOT EXISTS cp_mission_tests (                -- admin test log (see Admin test mode)
  id              INT AUTO_INCREMENT PRIMARY KEY,
  mission_id      VARCHAR(40) NOT NULL,
  mission_version SMALLINT NULL,               -- custom missions only
  location_index  TINYINT NOT NULL,
  tier            ENUM('standard','reinforced','heavy','major','critical') NOT NULL,
  testers         TINYINT NOT NULL DEFAULT 1,
  result          ENUM('passed','failed') NOT NULL,
  note            VARCHAR(255) NULL,
  tested_by       VARCHAR(50) NOT NULL,        -- citizenid of the admin
  created_at      DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_mission (mission_id, location_index, created_at)
);

CREATE TABLE IF NOT EXISTS cp_audit (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  actor      VARCHAR(50) NOT NULL,             -- citizenid, or 'console'
  role       ENUM('supervisor','admin','console') NOT NULL,
  category   ENUM('audit','flags','builder','operations') NOT NULL DEFAULT 'audit', -- picks the webhook
  action     VARCHAR(40) NOT NULL,
  target     VARCHAR(64) NULL,
  old_value  VARCHAR(64) NULL,
  new_value  VARCHAR(64) NULL,
  reason     VARCHAR(255) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
