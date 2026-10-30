-- sql/migrations/012_mission_ban.sql · a supervisor's temporary mission ban of one officer (CP.MissionBan, step P11).
-- JSON {"until": <unix time>, "by": <citizenid>, "name": <who set it>, "dept": <department>, "reason": <text>,
-- "at": <unix time>}; NULL = no ban. A ban past its "until" counts as none.
ALTER TABLE cp_officers ADD COLUMN mission_ban JSON NULL;
