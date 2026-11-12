-- sql/migrations/019_suspension_start.sql · when each officer's current or last suspension started (step H8).
-- A run's dispute window stands still only for a suspension that started while that window was open
-- (CP.Disputes.eligible, CP.Money.disputeStartSql); written by CP.Access.suspend, kept by a lift.
ALTER TABLE cp_officers ADD COLUMN suspended_from DATETIME NULL;
-- Suspensions given before the update: the time of the last 'suspend' audit row up to their end (Admin → Officers
-- writes one per suspension), else now for one still running (the windows still open keep standing still).
UPDATE cp_officers o SET suspended_from = COALESCE(
    (SELECT MAX(a.created_at) FROM cp_audit a
      WHERE a.action = 'suspend' AND a.target = o.citizenid AND a.created_at <= o.suspended_until),
    CASE WHEN o.suspended_until > NOW() THEN NOW() END)
  WHERE o.suspended_until IS NOT NULL AND o.suspended_from IS NULL;
