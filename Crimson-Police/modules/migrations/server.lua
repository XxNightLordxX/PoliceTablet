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
    '007_settings.sql',
    '008_admin_control.sql',
}

local WAIT_HINT_MS = 30000   -- no database after this long: say what to check (oxmysql waits without a word)

local readyPromise = promise.new()
local isReady = false
local failed = false
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

-- Every migration file with whether it ran and when (Admin UI → System → Storage; a pending one is a problem):
-- { version, files = { { version, name, applied, appliedAt } }, pending }.
function CP.Migrations.status()
    local done = {}
    local ok, rows = pcall(MySQL.query.await,
        'SELECT version, name, UNIX_TIMESTAMP(applied_at) AS at FROM cp_schema_migrations ORDER BY version')
    if ok and type(rows) == 'table' then
        for _, r in ipairs(rows) do
            local v = math.tointeger(tonumber(r.version))
            if v then done[v] = math.floor(tonumber(r.at) or 0) end
        end
    end
    local out = { version = version, files = {}, pending = 0, readable = ok == true }
    for _, file in ipairs(FILES) do
        local num = math.tointeger(tonumber(file:match('^(%d+)_')))
        local at = num and done[num] or nil
        out.files[#out.files + 1] = { version = num, name = file, applied = at ~= nil, appliedAt = at }
        if at == nil then out.pending = out.pending + 1 end
    end
    return out
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

-- The usual database errors on a first start, each with the fix in plain words (matched in lower case, in order).
local UNREACHABLE = 'oxmysql cannot reach the database server: make sure MySQL/MariaDB is running and that set mysql_connection_string in server.cfg has the right host and port, then restart.'
local DATABASE_HINTS = {
    {
        'command denied',
        'Your database user may not create or change tables: give it CREATE, ALTER and INDEX rights on the database named in set mysql_connection_string (server.cfg), or set Config.Database.enabled = false in config/config.lua to save to files instead. Then restart.',
    },
    {
        'using password',
        'oxmysql could not log in to the database: check the user name and password in set mysql_connection_string in server.cfg, then restart.',
    },
    {
        'access denied',
        'Your database user has no rights on this database: give it CREATE, ALTER, INDEX, SELECT, INSERT, UPDATE and DELETE rights, or set Config.Database.enabled = false in config/config.lua. Then restart.',
    },
    {
        'unknown database',
        'The database named in set mysql_connection_string (server.cfg) does not exist: create it or fix the name, then restart.',
    },
    { 'econnrefused', UNREACHABLE },
    { 'etimedout', UNREACHABLE },
    {
        'enotfound',
        'oxmysql cannot find the database host: check the host in set mysql_connection_string in server.cfg, then restart.',
    },
}

-- The plain fix for a database error, or nil when it is not one of the usual ones.
local function DatabaseHint(err)
    local msg = tostring(err):lower()
    for _, h in ipairs(DATABASE_HINTS) do
        if msg:find(h[1], 1, true) then return h[2] end
    end
    return nil
end
CP.Migrations._hint = DatabaseHint

local function Fail(file, stmt, err)
    failed = true
    CP.err(TAG, 'Migration %s failed. Crimson-Police will not start until it is fixed.', file)
    CP.err(TAG, 'Statement: %s', (stmt or ''):sub(1, 400))
    CP.err(TAG, 'Error: %s', tostring(err))
    local hint = DatabaseHint(err)
    if hint then CP.err(TAG, 'How to fix it: %s', hint) end
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
    -- The settings an admin changed in game go over Config before any module that waits here reads it.
    if CP.Settings and type(CP.Settings.boot) == 'function' then
        local okS, errS = pcall(CP.Settings.boot)
        if not okS then CP.err(TAG, 'the settings changed in game could not be loaded: %s', tostring(errS)) end
    end
    isReady = true
    readyPromise:resolve(true)
end

-- oxmysql never answers when it cannot connect: after WAIT_HINT_MS one line says what to check. The saves folder
-- (database off) never waits for oxmysql, so the line is only about the database.
SetTimeout(WAIT_HINT_MS, function()
    if isReady or failed then return end
    if CP.Storage and CP.Storage.name and CP.Storage.name() ~= 'database' then return end
    CP.warn(TAG,
        'still waiting for the database after %d seconds: oxmysql has not connected. Check the oxmysql lines above and the line set mysql_connection_string in server.cfg (user name, password, host and database name), then restart. Or set Config.Database.enabled = false in config/config.lua to save to files instead.',
        WAIT_HINT_MS // 1000)
end)

CreateThread(function()
    -- oxmysql connects asynchronously; MySQL.ready waits for it.
    if MySQL.ready then
        local p = promise.new()
        MySQL.ready(function() p:resolve(true) end)
        Citizen.Await(p)
    end
    Run()
end)
