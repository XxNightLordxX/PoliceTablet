-- sql/migrations/014_live_catches.sql · suspects detained in a live case per run row (CP.LiveCrime, step V13: the
-- live_catches Rank by tab). Added to cp_mission_runs AND cp_mission_runs_archive in the same order, because the
-- retention job copies rows with INSERT ... SELECT *.
ALTER TABLE cp_mission_runs ADD COLUMN live_catches SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE cp_mission_runs_archive ADD COLUMN live_catches SMALLINT NOT NULL DEFAULT 0;
