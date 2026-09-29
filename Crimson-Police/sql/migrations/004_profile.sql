-- sql/migrations/004_profile.sql · profile pictures, bio, look, language, call mute, commendations and reports.
ALTER TABLE cp_officers ADD COLUMN bio VARCHAR(280) NULL;
ALTER TABLE cp_officers ADD COLUMN avatar_kind VARCHAR(12) NOT NULL DEFAULT 'initials';
ALTER TABLE cp_officers ADD COLUMN avatar_value VARCHAR(255) NULL;
ALTER TABLE cp_officers ADD COLUMN avatar_pending VARCHAR(255) NULL;
ALTER TABLE cp_officers ADD COLUMN avatar_status VARCHAR(10) NOT NULL DEFAULT 'none';
ALTER TABLE cp_officers ADD COLUMN avatar_reviewed_by VARCHAR(50) NULL;
ALTER TABLE cp_officers ADD COLUMN appearance VARCHAR(24) NULL;
ALTER TABLE cp_officers ADD COLUMN accent VARCHAR(7) NULL;
ALTER TABLE cp_officers ADD COLUMN ui_scale DECIMAL(3,2) NULL;
ALTER TABLE cp_officers ADD COLUMN language VARCHAR(8) NULL;
ALTER TABLE cp_officers ADD COLUMN profile_updated_at DATETIME NULL;
ALTER TABLE cp_officers ADD COLUMN calls_muted TINYINT(1) NOT NULL DEFAULT 0;
ALTER TABLE cp_officers ADD COLUMN bio_pending VARCHAR(280) NULL;

CREATE TABLE IF NOT EXISTS cp_profile_reports (
  id          INT AUTO_INCREMENT PRIMARY KEY,
  citizenid   VARCHAR(50) NOT NULL,           -- the officer reported
  reporter    VARCHAR(50) NOT NULL,           -- citizenid of the reporter (never shown to the reported officer)
  reason      ENUM('picture','bio','other') NOT NULL,
  note        VARCHAR(140) NULL,
  department  VARCHAR(32) NOT NULL,           -- the reported officer's department when reported
  status      ENUM('open','cleared','dismissed') NOT NULL DEFAULT 'open',
  handled_by  VARCHAR(50) NULL,
  created_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  handled_at  DATETIME NULL,
  INDEX idx_queue (department, status, created_at),
  INDEX idx_reporter (reporter, created_at)
);

CREATE TABLE IF NOT EXISTS cp_commendations (
  id            INT AUTO_INCREMENT PRIMARY KEY,
  citizenid     VARCHAR(50) NOT NULL,          -- the officer commended
  kind          VARCHAR(24) NOT NULL,          -- a Config.Commendations.kinds id
  citation      VARCHAR(255) NOT NULL,
  run_uuid      VARCHAR(36) NULL,              -- the run it is for, if any
  department    VARCHAR(32) NOT NULL,          -- the recipient's department when it was given
  issued_by     VARCHAR(50) NOT NULL,          -- citizenid, or 'console'
  issuer_role   ENUM('supervisor','admin') NOT NULL,
  revoked       TINYINT(1) NOT NULL DEFAULT 0,
  revoked_by    VARCHAR(50) NULL,
  revoke_reason VARCHAR(255) NULL,
  created_at    DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  revoked_at    DATETIME NULL,
  INDEX idx_officer (citizenid, revoked, created_at),
  INDEX idx_issuer (issued_by, created_at)
);
