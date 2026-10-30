-- sql/migrations/011_dept_controls.sql · Mission controls (CP.DeptControls): what a department's supervisors (or an
-- admin) changed inside the bounds an admin set. One row per department and control; '*' = a server-wide control.
-- No row = the config value. expires_at NULL = until it is changed or reset; a row past expires_at is ignored.
CREATE TABLE IF NOT EXISTS cp_dept_controls (
  department  VARCHAR(32) NOT NULL,
  control_key VARCHAR(40) NOT NULL,
  value_json  JSON NOT NULL,                      -- {"v": <value>}
  expires_at  DATETIME NULL,
  set_by      VARCHAR(50) NOT NULL,               -- citizenid, or 'console'
  set_role    VARCHAR(12) NOT NULL,               -- supervisor, admin or console
  updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (department, control_key)
);
