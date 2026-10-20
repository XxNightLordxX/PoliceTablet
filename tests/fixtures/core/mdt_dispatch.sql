-- tests/fixtures/core/mdt_dispatch.sql · sc-dispatch's mdt_dispatch table (sql/schema-qbox.sql plus the
-- unique_id column sc-dispatch adds at start) with sample calls, for CP.Dispatch.lookupActiveCall.
CREATE TABLE IF NOT EXISTS mdt_dispatch (
  id INT AUTO_INCREMENT PRIMARY KEY,
  type VARCHAR(50) NOT NULL,
  message TEXT,
  coords TEXT,
  street VARCHAR(255),
  caller VARCHAR(100),
  priority INT DEFAULT 2,
  responders LONGTEXT,
  active TINYINT(1) DEFAULT 1,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  unique_id VARCHAR(64) NULL,
  INDEX idx_active (active),
  INDEX idx_mdt_dispatch_uid (unique_id)
);
DELETE FROM mdt_dispatch;
INSERT INTO mdt_dispatch (id, type, message, active, unique_id) VALUES
  (1, '10-71 - Shots Fired', 'numeric call', 1, '1'),
  (2, '10-71 - Shots Fired', 'shots call', 1, 'shots_12_1790000000'),
  (3, '10-71 - Shots Fired', 'npc call', 1, 'npccall-3-1790000000'),
  (4, '10-16 - Stolen Vehicle', 'legacy call without unique_id', 1, NULL),
  (5, '10-11 - Traffic Violation', 'cleared call', 0, '5'),
  (6, '911', 'empty unique_id', 1, '');
