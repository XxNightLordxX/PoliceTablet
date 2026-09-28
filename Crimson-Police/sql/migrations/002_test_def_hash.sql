-- sql/migrations/002_test_def_hash.sql · remember which version of a mission each test covered.
-- def_hash is a hash of the mission definition at test time. When the mission is edited,
-- re-published or reloaded its hash changes and Admin UI -> Testing shows "Changed since test".
-- The runner treats "duplicate column" as already applied, so this is safe to run again.
ALTER TABLE cp_mission_tests ADD COLUMN def_hash VARCHAR(40) NULL;
