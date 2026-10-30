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
    '009_real_suspects.sql',
    '010_officer_options.sql',
    '011_dept_controls.sql',
    '012_mission_ban.sql',
}

local WAIT_HINT_MS = 30000   -- no database after this long: say what to check (oxmysql waits without a word)

local readyPromise = promise.new()
local isReady = false
local failed = false
local failure = nil        -- what failed, in a few words (CP.Migrations.failed())
local version = 0

-- The error ready() raises once the start failed: CP.Net answers it to the player as err.not_started.
local NOT_STARTED = 'err.not_started'
CP.Migrations.NOT_STARTED = NOT_STARTED

-- Blocks the current thread until migrations have finished. Returns true. It is a barrier: once the start failed it
-- raises err.not_started at once (and in every thread that was waiting), so nothing after it reads or writes a store
-- that did not start. FXServer refuses StopResource on the calling resource, so the resource stays started.
function CP.Migrations.ready()
    if isReady then return true end
    if failed then error(NOT_STARTED, 0) end
    Citizen.Await(readyPromise)
    if not isReady then error(NOT_STARTED, 0) end
    return true
end

-- For start-up threads and loops: waits like ready(), then true once started, or false when the start failed (no
-- error, so the thread ends quietly: the console already has the lines that say what failed).
function CP.Migrations.started()
    if isReady then return true end
    if failed then return false end
    Citizen.Await(readyPromise)
    return isReady
end

-- What failed (a few words) once the start failed, else nil (while it starts and after it started).
function CP.Migrations.failed()
    if not failed then return nil end
    return failure or 'the start failed'
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

local function CmdName() return (Config and Config.Tablet and Config.Tablet.adminCommand) or 'CrimsonPoliceAdmin' end

-- A failed start is a state, not a stop: FXServer refuses StopResource on the calling resource (ServerResources.cpp
-- STOP_RESOURCE), so Crimson-Police stays started and refuses every request with err.not_started (CP.Net), and
-- ready() raises it, so nothing runs on a half-upgraded store. The threads waiting in ready() wake up and stop there.
-- what: a few words for CP.Migrations.failed(); lines: what failed and how to fix it.
local function FailStart(what, lines)
    if failed or isReady then return end
    failed = true
    failure = what
    local resource = CP.resource or GetCurrentResourceName()
    for _, line in ipairs(lines) do CP.err(TAG, '%s', line) end
    -- a storage switched to in game that cannot start: the console command that goes back to config.lua's store
    if CP.Storage and CP.Storage.override and CP.Storage.override() then
        CP.err(TAG,
            'This is the storage switched to in Admin UI → System. To go back to config.lua\'s Config.Database, type "%s storagemode reset" in the server console, then "ensure %s".',
            CmdName(), resource)
    end
    CP.err(TAG,
        'Crimson-Police stays started but refuses every request until it starts. Fix the problem above, then type "ensure %s" in the server console (or restart it in txAdmin).',
        resource)
    readyPromise:resolve(false)
end

local function Fail(file, stmt, err)
    local lines = { ('Migration %s failed. Crimson-Police did not start.'):format(tostring(file)) }
    if stmt then lines[#lines + 1] = 'Statement: ' .. stmt:sub(1, 400) end
    lines[#lines + 1] = 'Error: ' .. tostring(err)
    local hint = DatabaseHint(err)
    if hint then lines[#lines + 1] = 'How to fix it: ' .. hint end
    FailStart(('migration %s failed'):format(tostring(file)), lines)
end

-- With the database on. In files mode MySQL is the saves folder engine: no server to ask, no character sets.
local function OnDatabase()
    return CP.Storage ~= nil and type(CP.Storage.mode) == 'function' and CP.Storage.mode() == 'database'
end

-- The database server and whether it has what Crimson-Police's SQL needs: JSON_VALUE (every payment step, the
-- Payments and Corrections screens) that reads a JSON null as NULL. MySQL has it from 8.0.21, MariaDB from 10.3
-- (10.2 answers the text 'null'); Qbox itself asks for MariaDB 10.9 or newer and does not support MySQL. An older
-- server would fail half way through a payment, so the start fails before any table is touched. MySQL starts with
-- a warning. A server that does not answer at all is left to the migrations, which name the usual errors.
local PROBE = [[SELECT VERSION() AS v, JSON_VALUE('{"a":"b"}', '$.a') AS a, JSON_VALUE('{"a":null}', '$.a') IS NULL AS n]]

local function ServerName(v) return v:lower():find('mariadb', 1, true) and v or ('MySQL ' .. v) end

-- true when the start may go on
local function CheckServer()
    local okP, rows = pcall(MySQL.query.await, PROBE)
    local row = okP and type(rows) == 'table' and rows[1] or nil
    local version = row and row.v
    if not row then
        -- no JSON_VALUE at all (MySQL before 8.0.21: "FUNCTION <db>.JSON_VALUE does not exist"), or no answer (the
        -- error text also holds the query, JSON_VALUE and all, as oxmysql words it)
        if not tostring(rows):find('JSON_VALUE does not exist', 1, true) then return true end
        local okV, vr = pcall(MySQL.query.await, 'SELECT VERSION() AS v')
        version = okV and type(vr) == 'table' and vr[1] and vr[1].v or 'unknown'
    end
    version = tostring(version)
    CP.log(TAG, 'database server: %s', version)
    if not (row and row.a == 'b' and (row.n == true or tonumber(row.n) == 1)) then
        FailStart('the database server is too old', {
            ('The database server is %s. Crimson-Police needs MariaDB 10.3 or newer (Qbox itself asks for MariaDB 10.9 or newer): every payment uses JSON_VALUE, which this server does not have or reads differently. Crimson-Police did not start.'):format(
                ServerName(version)),
            'How to fix it: update the database server to MariaDB 10.9 or newer (your host may offer it), or set Config.Database.enabled = false in config/config.lua to save to files instead.',
        })
        return false
    end
    if not version:lower():find('mariadb', 1, true) then
        CP.warn(TAG,
            'the database server is MySQL %s. Qbox does not support MySQL (it asks for MariaDB 10.9 or newer), and Crimson-Police is made and tested for MariaDB. It starts, but on MySQL, once an officer has a cooldown clear, cap raise or extra boss attempt, the next one is refused, and a storage copy to the saves folder can hand out a deleted run\'s id again. Move to MariaDB when you can.',
            version)
    end
    return true
end
CP.Migrations._checkServer = CheckServer

-- Crimson-Police's text is utf8mb4: officer names (Qbox's charinfo), reasons and labels may hold emoji. A cp_ table
-- takes the database's character set, and txAdmin's recipe deployer makes the database CHARACTER SET utf8 (utf8mb3,
-- at most 3 bytes a character), which refuses every emoji (error 1366: the whole write is lost). So every cp_ table
-- that is not utf8mb4 is switched, once (a table a later migration makes is switched on the start that makes it).
-- CONVERT gives the JSON columns the table's collation; they go back to utf8mb4_bin, as a utf8mb4 database makes
-- them (on MariaDB JSON is LONGTEXT, and no other cp_ column is). Only Crimson-Police's own tables are touched. A
-- table that cannot be switched (no ALTER right) is named in a warning, and the start goes on as before.
-- The storage copy to the database runs it too (admin/server.lua StorageCopy): an owner on the saves folder copies
-- into a txAdmin database whose cp_ tables the copy itself makes. query (optional): the database's query function,
-- MySQL.query.await by default; the copy passes oxmysql's, as in files mode MySQL is the saves folder engine.
local function Utf8mb4Tables(query)
    query = query or MySQL.query.await
    local ok, cols = pcall(query, [[SELECT c.table_name AS t, c.column_name AS c, c.data_type AS d,
        c.collation_name AS k, c.is_nullable AS n, b.table_collation AS tk
        FROM information_schema.columns c
        INNER JOIN information_schema.tables b ON b.table_schema = c.table_schema AND b.table_name = c.table_name
        WHERE c.table_schema = DATABASE() AND b.table_type = 'BASE TABLE'
        ORDER BY c.table_name, c.ordinal_position]])
    if not ok or type(cols) ~= 'table' then return end
    local order, todo = {}, {}
    for _, r in ipairs(cols) do
        local name = tostring(r.t)
        if name:sub(1, 3) == 'cp_' then
            local t = todo[name]
            if not t then
                local collation = tostring(r.tk or '')
                t = { collation = collation, convert = collation:sub(1, 7) ~= 'utf8mb4', json = {} }
                todo[name] = t
                order[#order + 1] = name
            end
            if tostring(r.d):lower() == 'longtext' and (t.convert or tostring(r.k) ~= 'utf8mb4_bin') then
                t.json[#t.json + 1] = ('MODIFY `%s` JSON %s'):format(tostring(r.c),
                    r.n == 'NO' and 'NOT NULL' or 'NULL')
            end
        end
    end
    local function Warn(name, err)
        local hint = DatabaseHint(err)
        CP.warn(TAG, '%s could not be switched to utf8mb4, so names and reasons with emoji cannot be saved in it: %s%s',
            name, tostring(err), hint and (' How to fix it: ' .. hint) or '')
    end
    for _, name in ipairs(order) do
        local t = todo[name]
        local okC, errC = true, nil
        if t.convert then
            print(
                ('[crimson-police] %s is %s: switching it to utf8mb4 (once), so names and reasons with emoji are kept'):format(
                    name, t.collation))
            okC, errC = pcall(query, ('ALTER TABLE `%s` CONVERT TO CHARACTER SET utf8mb4'):format(name))
            if not okC then Warn(name, errC) end
        end
        if okC and #t.json > 0 then
            local okJ, errJ = pcall(query, ('ALTER TABLE `%s` %s'):format(name, table.concat(t.json, ', ')))
            if not okJ then Warn(name, errJ) end
        end
    end
end
CP.Migrations._utf8mb4Tables = Utf8mb4Tables

local function Run()
    -- One start-up line naming the storage (Config.Database): the database, or the saves folder. In files
    -- mode MySQL is CP.Storage's engine, so the same migrations build the same tables there.
    print(('[crimson-police] storage: %s'):format(
        CP.Storage and CP.Storage.describe and CP.Storage.describe() or 'MySQL/MariaDB through oxmysql'))
    if OnDatabase() and not CheckServer() then return end
    local ok, err = pcall(MySQL.query.await, [[
        CREATE TABLE IF NOT EXISTS cp_schema_migrations (
          version    INT PRIMARY KEY,
          name       VARCHAR(100) NOT NULL,
          applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
    ]])
    if not ok then return Fail('cp_schema_migrations', 'CREATE TABLE cp_schema_migrations', err) end

    local applied = {}
    local okRows, rows = pcall(MySQL.query.await, 'SELECT version FROM cp_schema_migrations')
    if not okRows then return Fail('cp_schema_migrations', 'SELECT version FROM cp_schema_migrations', rows) end
    rows = type(rows) == 'table' and rows or {}
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

    if OnDatabase() then Utf8mb4Tables() end
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
    -- then the start-up locks (a store a storage switch left behind, a restore that did not finish), still before any
    -- module that waits here goes on: the cash forfeiture, the pending pay and the job resume already see them
    if CP.Sysadmin and type(CP.Sysadmin.startLocks) == 'function' then
        local okL, errL = pcall(CP.Sysadmin.startLocks)
        if not okL then CP.err(TAG, 'reading the storage marker failed: %s', tostring(errL)) end
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
    -- an error outside the guarded statements fails the start too, instead of leaving every caller of ready() waiting
    local ok, err = pcall(Run)
    if not ok then Fail('start', nil, err) end
end)
