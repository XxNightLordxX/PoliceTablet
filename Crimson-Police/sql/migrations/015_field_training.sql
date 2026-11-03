-- sql/migrations/015_field_training.sql · a rookie's field training (CP.FieldTraining, step T1), on his officer row.
-- JSON {"trainer": <citizenid>, "trainerName": <text>, "dept": <department>, "by": <who paired them>, "byName": <text>,
-- "at": <unix time>, "tasks": {"<mission type>": {"runs": <n>, "signedBy": <citizenid>, "signedName": <text>,
-- "signedAt": <unix time>, "note": <text>}}, "doneAt": <unix time>}; NULL = not in field training.
ALTER TABLE cp_officers ADD COLUMN field_training JSON NULL;
