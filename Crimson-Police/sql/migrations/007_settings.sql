-- sql/migrations/007_settings.sql · settings an admin changed in game (Admin UI → Settings), over config.lua.
CREATE TABLE IF NOT EXISTS cp_settings (
  setting_key VARCHAR(191) NOT NULL PRIMARY KEY,  -- the Config key path, e.g. Tablet.deskDistance
  value_json  JSON NOT NULL,                      -- {"v": <value>}, or {"none": true} for "not set" (nil)
  updated_by  VARCHAR(50) NULL,                   -- citizenid, or 'console'
  updated_at  DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);
