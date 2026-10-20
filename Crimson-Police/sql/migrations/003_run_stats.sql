-- sql/migrations/003_run_stats.sql · service-record counts, the drawn location and mission calls per run row.
-- Every column is added to cp_mission_runs AND cp_mission_runs_archive in the same order, because the
-- retention job copies rows with INSERT ... SELECT *. Counts are per participant row.
ALTER TABLE cp_mission_runs ADD COLUMN location_index TINYINT NULL;
ALTER TABLE cp_mission_runs ADD COLUMN arrests SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN citations SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN impounds SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN rescues SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN vehicles_stopped SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN evidence SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN decisions_ok SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN decisions_bad SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN decisions_best SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN lethal SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs ADD COLUMN medal TINYINT NULL;
ALTER TABLE cp_mission_runs ADD COLUMN mission_call_id INT NULL;
ALTER TABLE cp_mission_runs ADD COLUMN response_s SMALLINT NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN location_index TINYINT NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN arrests SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN citations SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN impounds SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN rescues SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN vehicles_stopped SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN evidence SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN decisions_ok SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN decisions_bad SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN decisions_best SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN lethal SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN medal TINYINT NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN mission_call_id INT NULL;
ALTER TABLE cp_mission_runs_archive ADD COLUMN response_s SMALLINT NULL;
ALTER TABLE cp_mission_runs ADD INDEX idx_location (citizenid, mission_id, created_at);
ALTER TABLE cp_mission_runs ADD INDEX idx_call (mission_call_id);
