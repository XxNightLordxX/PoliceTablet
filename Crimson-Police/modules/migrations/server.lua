-- Applies sql/migrations/NNN_*.sql in order on start.

CP.Migrations = {}

local TAG = 'migrations'
local DIR = 'sql/migrations/'
-- Migration files are listed here in order. A released entry is never edited or removed.
local FILES = {
    '001_initial.sql',
    '002_test_def_hash.sql',
    '003_run_stats.sql',
    '004_profile.sql',
    '005_mission_calls.sql',
    '006_item_rewards.sql',
}

local readyPromise = promise.new()
local isReady = false
local version = 0

-- Blocks the current thread until migrations have finished. Returns true.
function CP.Migrations.ready()
    if isReady then return true end
    Citizen.Await(readyPromise)
    return true
end

function CP.Migrations.isReady()
    return isReady
end

function CP.Migrations.version()
    return version
end

-- Split a file into statements at every ';' that ends a line (after stripping '--' comments).
local function SplitStatements(sql)
    local statements, current = {}, {}
    for line in (sql .. '\n'):gmatch('(.-)\r?\n') do
        local code = line:gsub('%-%-.*$', '')
        if code:match('%S') then
            current[#current + 1] = code
            if code:match(';%s*$') then
                local stmt = table.concat(current, '\n'):gsub(';%s*$', '')
                statements[#statements + 1] = stmt
                current = {}
            end
        end
    end
    local rest = table.concat(current, '\n')
    if rest:match('%S') then statements[#statements + 1] = rest end
    return statements
end
CP.Migrations._split = SplitStatements

-- Errors that mean "this change is already there": re-running is safe.
local IDEMPOTENT = {
    'Duplicate column name',
    'Duplicate key name',
    'ER_DUP_FIELDNAME',
    'ER_DUP_KEYNAME',
    'already exists',
}

local function IsIdempotentError(msg)
    msg = tostring(msg)
    for _, needle in ipairs(IDEMPOTENT) do
        if msg:find(needle, 1, true) then return true end
    end
    return false
end

local function Fail(file, stmt, err)
    CP.err(TAG, 'Migration %s failed. Crimson-Police will not start until it is fixed.', file)
    CP.err(TAG, 'Statement: %s', (stmt or ''):sub(1, 400))
    CP.err(TAG, 'Error: %s', tostring(err))
    -- Stop the resource so nothing runs on a half-upgraded database.
    SetTimeout(0, function()
        StopResource(GetCurrentResourceName())
    end)
end

local function Run()
    -- One start-up line naming the storage (Config.Database): the database, or the saves folder. In files
    -- mode MySQL is CP.Storage's engine, so the same migrations build the same tables there.
    print(('[crimson-police] storage: %s'):format(
        CP.Storage and CP.Storage.describe and CP.Storage.describe() or 'MySQL/MariaDB through oxmysql'))
    local ok, err = pcall(MySQL.query.await, [[
        CREATE TABLE IF NOT EXISTS cp_schema_migrations (
          version    INT PRIMARY KEY,
          name       VARCHAR(100) NOT NULL,
          applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    if not ok then return Fail('cp_schema_migrations', 'CREATE TABLE cp_schema_migrations', err) end

    local applied = {}
    local rows = MySQL.query.await('SELECT version FROM cp_schema_migrations') or {}
    for _, row in ipairs(rows) do applied[tonumber(row.version)] = true end
    local fresh = next(applied) == nil

    for _, file in ipairs(FILES) do
        local num = tonumber(file:match('^(%d+)_'))
        if not num then return Fail(file, nil, 'file name must start with a number, e.g. 003_name.sql') end
        if not applied[num] then
            local sql = LoadResourceFile(GetCurrentResourceName(), DIR .. file)
            if not sql then return Fail(file, nil, 'file not found in ' .. DIR) end
            for _, stmt in ipairs(SplitStatements(sql)) do
                local okStmt, errStmt = pcall(MySQL.query.await, stmt)
                if not okStmt then
                    if IsIdempotentError(errStmt) then
                        CP.log(TAG, '%s: already applied (%s)', file, tostring(errStmt):sub(1, 120))
                    else
                        return Fail(file, stmt, errStmt)
                    end
                end
            end
            local okRec, errRec = pcall(MySQL.insert.await,
                'INSERT IGNORE INTO cp_schema_migrations (version, name) VALUES (?, ?)', { num, file })
            if not okRec then return Fail(file, 'INSERT INTO cp_schema_migrations', errRec) end
            print(('[crimson-police] applied migration %s'):format(file))
            applied[num] = true
        end
        if num > version then version = num end
    end

    local store = CP.Storage and CP.Storage.name and CP.Storage.name() or 'database'
    print(('[crimson-police] Crimson-Police %s at version %d'):format(store, version))
    if fresh and store == 'database' and CP.Storage and CP.Storage.hasSavedData and CP.Storage.hasSavedData() then
        -- a new database next to a saves folder with data (Config.Database.enabled switched back on)
        local cmd = (Config.Tablet and Config.Tablet.adminCommand) or 'CrimsonPoliceAdmin'
        CP.warn(TAG,
            'the database is new, but the saves folder holds data from running with the database off. Nothing is copied by itself: to bring it over, run "%s storage copy files-to-database" in the server console, then restart Crimson-Police.',
            cmd)
    end
    isReady = true
    readyPromise:resolve(true)
end

CreateThread(function()
    -- oxmysql connects asynchronously; MySQL.ready waits for it.
    if MySQL.ready then
        local p = promise.new()
        MySQL.ready(function() p:resolve(true) end)
        Citizen.Await(p)
    end
    Run()
end)
