-- sql/migrations/005_mission_calls.sql · the history of mission calls (Dispatch).
CREATE TABLE IF NOT EXISTS cp_mission_calls (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  code         VARCHAR(12) NOT NULL,           -- e.g. MC-0427 (numbered per day)
  mission_type VARCHAR(32) NOT NULL,
  area         VARCHAR(32) NULL,               -- a Config.MissionCalls.areas key, NULL = county-wide
  priority     TINYINT NOT NULL DEFAULT 3,
  status       ENUM('open','claimed','lapsed','withdrawn','closed') NOT NULL DEFAULT 'open',
  outcome      VARCHAR(16) NULL,               -- completed, failed, abandoned or reopened
  created_by   VARCHAR(50) NULL,               -- NULL = posted by the server, else a citizenid or 'console'
  paged_to     VARCHAR(50) NULL,               -- leader citizenid of a paged unit
  claimed_by   VARCHAR(50) NULL,               -- leader citizenid of the winning claim
  claimants    TINYINT NOT NULL DEFAULT 0,     -- valid claims inside the claim window
  run_uuid     VARCHAR(36) NULL,
  reopened     TINYINT(1) NOT NULL DEFAULT 0,
  reason       VARCHAR(255) NULL,              -- withdraw reason
  created_at   DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  claimed_at   DATETIME NULL,
  closed_at    DATETIME NULL,
  INDEX idx_status (status, created_at),
  INDEX idx_run (run_uuid)
);
