-- modules/migrations/server.lua · applies sql/migrations/NNN_*.sql in order on start.
--
-- Every other module calls CP.Migrations.ready() before its first query: it blocks the
-- calling thread until the database is at the latest version. If a migration fails the
-- resource prints the file and the error and stops itself, so it never runs on a
-- half-upgraded database.

CP.Migrations = {}

local TAG = 'migrations'
local DIR = 'sql/migrations/'
-- Migration files are listed here in order. A released entry is never edited or removed.
local FILES = {
    '001_initial.sql',
    '002_test_def_hash.sql',
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
local function splitStatements(sql)
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
CP.Migrations._split = splitStatements

-- Errors that mean "this change is already there": re-running is safe.
local IDEMPOTENT = { 'Duplicate column name', 'Duplicate key name', 'ER_DUP_FIELDNAME', 'ER_DUP_KEYNAME', 'already exists' }

local function isIdempotentError(msg)
    msg = tostring(msg)
    for _, needle in ipairs(IDEMPOTENT) do
        if msg:find(needle, 1, true) then return true end
    end
    return false
end

local function fail(file, stmt, err)
    CP.err(TAG, 'Migration %s failed. Crimson-Police will not start until it is fixed.', file)
    CP.err(TAG, 'Statement: %s', (stmt or ''):sub(1, 400))
    CP.err(TAG, 'Error: %s', tostring(err))
    -- Stop the resource so nothing runs on a half-upgraded database.
    SetTimeout(0, function()
        StopResource(GetCurrentResourceName())
    end)
end

local function run()
    local ok, err = pcall(MySQL.query.await, [[
        CREATE TABLE IF NOT EXISTS cp_schema_migrations (
          version    INT PRIMARY KEY,
          name       VARCHAR(100) NOT NULL,
          applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    if not ok then return fail('cp_schema_migrations', 'CREATE TABLE cp_schema_migrations', err) end

    local applied = {}
    local rows = MySQL.query.await('SELECT version FROM cp_schema_migrations') or {}
    for _, row in ipairs(rows) do applied[tonumber(row.version)] = true end

    for _, file in ipairs(FILES) do
        local num = tonumber(file:match('^(%d+)_'))
        if not num then return fail(file, nil, 'file name must start with a number, e.g. 003_name.sql') end
        if not applied[num] then
            local sql = LoadResourceFile(GetCurrentResourceName(), DIR .. file)
            if not sql then return fail(file, nil, 'file not found in ' .. DIR) end
            for _, stmt in ipairs(splitStatements(sql)) do
                local okStmt, errStmt = pcall(MySQL.query.await, stmt)
                if not okStmt then
                    if isIdempotentError(errStmt) then
                        CP.log(TAG, '%s: already applied (%s)', file, tostring(errStmt):sub(1, 120))
                    else
                        return fail(file, stmt, errStmt)
                    end
                end
            end
            local okRec, errRec = pcall(MySQL.insert.await,
                'INSERT IGNORE INTO cp_schema_migrations (version, name) VALUES (?, ?)', { num, file })
            if not okRec then return fail(file, 'INSERT INTO cp_schema_migrations', errRec) end
            print(('[crimson-police] applied migration %s'):format(file))
            applied[num] = true
        end
        if num > version then version = num end
    end

    print(('[crimson-police] Crimson-Police database at version %d'):format(version))
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
    run()
end)
