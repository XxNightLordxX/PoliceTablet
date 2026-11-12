-- sql/migrations/006_item_rewards.sql · optional item rewards (Config.Rewards).
CREATE TABLE IF NOT EXISTS cp_item_rewards (
  id         INT AUTO_INCREMENT PRIMARY KEY,
  row_id     INT NULL,                        -- cp_mission_runs.id for run rewards
  source     ENUM('run','medal','goal','level','boss','season') NOT NULL,
  source_key VARCHAR(64) NOT NULL,            -- run_uuid, goal id and period, level number or season id
  citizenid  VARCHAR(50) NOT NULL,
  item       VARCHAR(64) NOT NULL,
  count      SMALLINT NOT NULL DEFAULT 1,
  value      INT NOT NULL DEFAULT 0,          -- count x the item's configured value
  status     ENUM('held','pending','giving','given','forfeited') NOT NULL DEFAULT 'pending',
  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  given_at   DATETIME NULL,
  UNIQUE KEY uq_reward (citizenid, source, source_key, item),
  INDEX idx_officer (citizenid, status),
  INDEX idx_row (row_id)
);
