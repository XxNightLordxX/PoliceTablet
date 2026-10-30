-- sql/migrations/013_call_department.sql · the department lane a mission call was posted in (CP.MissionCalls, step
-- P12: the callLane Mission control); NULL = a server-wide call (the server's own, or one staff created or paged).
ALTER TABLE cp_mission_calls ADD COLUMN department VARCHAR(32) NULL;
