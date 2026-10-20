-- sql/migrations/008_admin_control.sql · full admin control: corrections, overrides, jobs, settings history.
-- Every column is added to cp_mission_runs AND cp_mission_runs_archive in the same order, because the
-- retention job copies rows with INSERT ... SELECT *. One column per statement, never with a key (files mode).
ALTER TABLE cp_officers ADD COLUMN board_excluded TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE cp_officers ADD COLUMN retired_at DATETIME NULL;
ALTER TABLE cp_officers ADD COLUMN retire_batch VARCHAR(36) NULL;
ALTER TABLE cp_officers ADD COLUMN cooldown_clears JSON NULL;
ALTER TABLE cp_officers ADD COLUMN cap_extra JSON NULL;
ALTER TABLE cp_officers ADD COLUMN boss_extra JSON NULL;
ALTER TABLE cp_officers ADD COLUMN license VARCHAR(64) NULL;
ALTER TABLE cp_officers ADD INDEX idx_license (license);

ALTER TABLE cp_mission_runs ADD COLUMN void_kind VARCHAR(12) NULL;
ALTER TABLE cp_mission_runs ADD COLUMN void_batch VARCHAR(36) NULL;
ALTER TABLE cp_mission_runs ADD COLUMN cash_reclaimed INT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN void_kind VARCHAR(12) NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN void_batch VARCHAR(36) NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN cash_reclaimed INT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD INDEX idx_cash (cash_status, created_at);
ALTER TABLE cp_mission_runs ADD INDEX idx_batch (void_batch);
ALTER TABLE cp_mission_runs_archive ADD INDEX idx_batch (void_batch);

ALTER TABLE cp_audit ADD COLUMN actor_ident VARCHAR(64) NULL;
ALTER TABLE cp_seasons ADD COLUMN planned_end DATETIME NULL;
ALTER TABLE cp_seasons ADD COLUMN next_name VARCHAR(64) NULL;
ALTER TABLE cp_custom_missions ADD COLUMN overrides_builtin TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE cp_custom_missions ADD COLUMN base_hash VARCHAR(64) NULL;
ALTER TABLE cp_mission_tests ADD COLUMN unplayed TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_tests ADD COLUMN hidden TINYINT(1) NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS cp_badge_overrides (
  citizenid  VARCHAR(50) NOT NULL,
  badge_id   VARCHAR(64) NOT NULL,
  mode       ENUM('grant','block') NOT NULL,  -- grant: kept whatever the rows say; block: never given
  by_actor   VARCHAR(50) NOT NULL,
  reason     VARCHAR(255) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (citizenid, badge_id)
);

CREATE TABLE IF NOT EXISTS cp_dept_funding (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  department VARCHAR(32) NOT NULL,
  amount     INT NOT NULL,
  txn        VARCHAR(64) NULL,                -- CP-FUND-<id>, set before the deposit
  state      VARCHAR(12) NOT NULL,            -- pending (before the deposit), done or failed
  by_actor   VARCHAR(50) NOT NULL,
  reason     VARCHAR(255) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_dept (department, created_at)
);

CREATE TABLE IF NOT EXISTS cp_settings_history (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  setting_key VARCHAR(191) NOT NULL,
  action      VARCHAR(40) NOT NULL,           -- settingChanged, settingReset, missionSwitch ...
  old_json    JSON NULL,                      -- the full values; NULL = config.lua's value
  new_json    JSON NULL,
  by_actor    VARCHAR(50) NOT NULL,           -- citizenid, or 'console'
  by_ident    VARCHAR(64) NULL,               -- the acting player's license
  reason      VARCHAR(255) NULL,
  reverts_id  INT NULL,                       -- the history row a Revert undid
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_key (setting_key, created_at)
);

CREATE TABLE IF NOT EXISTS cp_admin_jobs (
  id         VARCHAR(36) PRIMARY KEY,         -- also the void_batch of the rows it changed
  kind       VARCHAR(24) NOT NULL,            -- bulkVoid, restoreBatch, retire, recordMove, seasonReopen ...
  state      VARCHAR(12) NOT NULL,            -- running, done, failed, rolledback
  filter     JSON NULL,
  detail     JSON NULL,                       -- ids done, per-kind data
  done       INT NOT NULL DEFAULT 0,
  total      INT NOT NULL DEFAULT 0,
  actor      VARCHAR(50) NOT NULL,
  reason     VARCHAR(255) NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at DATETIME NULL,
  INDEX idx_state (state, created_at)
);

CREATE TABLE IF NOT EXISTS cp_admin_requests (
  request_id VARCHAR(36) PRIMARY KEY,         -- the NUI's request id: one money or bulk action acts once
  action     VARCHAR(40) NOT NULL,
  actor      VARCHAR(50) NOT NULL,
  result     JSON NULL,
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_created (created_at)
);

CREATE TABLE IF NOT EXISTS cp_staff_notices (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  text        VARCHAR(280) NOT NULL,
  departments JSON NULL,                      -- NULL = every department
  expires_at  DATETIME NOT NULL,
  by_actor    VARCHAR(50) NOT NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  removed_at  DATETIME NULL
);

CREATE TABLE IF NOT EXISTS cp_storage_meta (
  meta_key   VARCHAR(32) PRIMARY KEY,         -- generation, state (active or left_behind)
  meta_value VARCHAR(255) NULL,
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
