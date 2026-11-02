-- sql/migrations/017_lookup_indexes.sql · indexes for lookups that read every row of their table (step OP3).
-- cp_audit had only its id: the auto-suspension check (action and target), the flagged-run notes of the Admin UI
-- run lists (target IN ...), the Type of the Day and mission control overrides, the builder's publisher lookup, the
-- reward take-back check (target) and the per-day caps of supervisor actions (action and time) each read the whole
-- log. cp_disputes is looked up by its run (one dispute per run). Only indexes are added: no data changes.
ALTER TABLE cp_audit ADD INDEX idx_audit_target (target, action);
ALTER TABLE cp_audit ADD INDEX idx_audit_action (action, created_at);
ALTER TABLE cp_disputes ADD INDEX idx_dispute_run (run_id);
