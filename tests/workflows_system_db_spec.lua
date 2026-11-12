-- Tests/workflows_system_spec.lua on MariaDB (database on), where the storage differs from the saves folder.

-- Tests/workflows_system_spec.lua on MariaDB (database on), where the storage differs from the saves folder:
-- an empty database built by the real migrations runner at start (every table utf8mb4), a restart that applies
-- nothing twice, every adapter, a restart and the maintenance lock in the middle of each money and storage action
-- (backups and restore read and write the database, the copy and the switch go to the saves folder), the clean-up's
-- archive and deletes at the daily reset, idle. Database mode only: the files and shadow suites run
-- tests/workflows_system_spec.lua itself.
local storage = os.getenv('CP_TEST_STORAGE') or ''
if storage ~= '' and storage ~= 'database' then
    local H = dofile('tests/harness.lua')
    H.skipIn(storage, 'the MariaDB walk of tests/workflows_system_spec.lua')
    return H
end
_G.CP_WF_WORLD = 'system_db'
_G.CP_WF_STORAGE = 'database'
local H = dofile('tests/workflows_system_spec.lua')
_G.CP_WF_STORAGE = nil
return H
