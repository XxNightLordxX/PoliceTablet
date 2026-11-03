-- sql/migrations/016_saved_cases.sql · closed real-suspect cases kept over a restart (CP.Opponents, step F1).
-- One row per closed live or volunteer case: what the Admin UI Real suspects screen reads of it (the suspects and
-- officers by name, the timeline, the damage ledger, the volunteer's part), never a position. Only the newest
-- Config.RealSuspects.casesKept rows are kept, none older than Config.RealSuspects.pairLedgerDays. Volunteer strikes
-- and strike blocks are rows of cp_pvp_pairs (kind vol_strike or vol_block; the player key in suspect_license).
CREATE TABLE IF NOT EXISTS cp_pvp_cases (
  run_uuid   VARCHAR(36) NOT NULL PRIMARY KEY,
  kind       VARCHAR(12) NOT NULL,                 -- live or volunteer
  closed_at  DATETIME NOT NULL,
  case_json  JSON NOT NULL,
  INDEX idx_closed (closed_at)
);
