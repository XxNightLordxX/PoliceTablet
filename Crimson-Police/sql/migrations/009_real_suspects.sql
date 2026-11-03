-- sql/migrations/009_real_suspects.sql · police vs real criminal players: the pair ledger (anti-farm, step V7).
-- One row per officer and suspect of a closed case (live crimes and volunteer suspects share it), an admin's pair
-- block, exclusion or suspension, and every time a character left police duty (job hops survive a restart). An
-- exclude row keeps '' in officer_citizenid; suspend and duty_off rows keep '' in suspect_citizenid.
CREATE TABLE IF NOT EXISTS cp_pvp_pairs (
  id                INT AUTO_INCREMENT PRIMARY KEY,
  kind              VARCHAR(12) NOT NULL,           -- live, volunteer, block, exclude, suspend or duty_off
  run_uuid          VARCHAR(36) NULL,
  officer_citizenid VARCHAR(50) NOT NULL,
  officer_license   VARCHAR(64) NULL,
  suspect_citizenid VARCHAR(50) NOT NULL,
  suspect_license   VARCHAR(64) NULL,
  outcome           VARCHAR(16) NULL,               -- detained, booked, got_away, left, void, gone ...
  scored            TINYINT(1) NOT NULL DEFAULT 0,  -- 1 = that suspect's detain or booking scored for that officer
  until_at          DATETIME NULL,                  -- block, exclude and suspend rows: when they run out
  created_at        DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  INDEX idx_officer (officer_citizenid, created_at),
  INDEX idx_suspect (suspect_citizenid, created_at)
);
