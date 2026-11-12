-- sql/migrations/018_tours.sql · the guided tours each character finished (CP.Training, step TR1). One row per
-- character (officer, admin or criminal tablet user): JSON {"<tour>": <the version finished>}, e.g.
-- {"officer": 1, "admin": 1}. No row = no tour finished yet.
CREATE TABLE IF NOT EXISTS cp_tours (
  citizenid  VARCHAR(50) PRIMARY KEY,          -- Qbox citizenid
  seen       JSON NULL,                        -- {"<tour>": <version>}
  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
