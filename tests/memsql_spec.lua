-- CP.Storage.MemSQL (modules/storage/memsql.lua): the saves folder engine behind database-off mode
-- (Config.Database.enabled = false) and CP.Storage (modules/storage/server.lua).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
if not (CP.Storage and CP.Storage.MemSQL and CP.Storage.MemSQL.new) then H.load('modules/storage/memsql.lua') end
local M = CP.Storage.MemSQL
local cjson = require('cjson')

local TMP = os.tmpname()
os.remove(TMP)
os.execute(('mkdir -p \'%s\''):format(TMP))
local function Mkdir(d) os.execute(('rm -rf \'%s\' && mkdir -p \'%s\''):format(d, d)) end
local function ReadFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end
local function WriteFile(p, s) local f = assert(io.open(p, 'wb')); f:write(s); f:close() end
local function Exists(p) local f = io.open(p, 'rb') if f then f:close() return true end return false end
local function ListDir(d)
    local out = {}
    local p = io.popen(('ls -A \'%s\' 2>/dev/null'):format(d))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    table.sort(out)
    return out
end
local function Leftovers(d)
    local out = {}
    for _, name in ipairs(ListDir(d)) do
        if name:match('%.tmp$') or name:match('%.bak$') then out[#out + 1] = name end
    end
    return out
end

local MIGRATIONS = { '001_initial.sql', '002_test_def_hash.sql' }
local function Migrate(db)
    for i, f in ipairs(MIGRATIONS) do
        local text = ReadFile(H.root .. 'sql/migrations/' .. f)
        for _, stmt in ipairs(H.splitStatements(text)) do
            local ok, err = pcall(db.exec, db, stmt)
            if not ok and not tostring(err):find('Duplicate column name', 1, true) then error(err, 0) end
        end
        db:exec('INSERT IGNORE INTO cp_schema_migrations (version, name) VALUES (?, ?)', { i, f })
    end
end

local function DeepEq(a, b)
    if type(a) == 'number' and type(b) == 'number' then return a == b end
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not DeepEq(v, b[k]) then return false end end
    for k, v in pairs(b) do if not DeepEq(a[k], v) then return false end end
    return true
end
local function Show(v)
    local ok, s = pcall(cjson.encode, v)
    return ok and s or tostring(v)
end
local function LastLine(e) return (tostring(e):match('([^\n]*)$')) end

-- every row and counter of two engines' tables
local function SameTables(db1, db2, label)
    local problems = {}
    for _, t1 in ipairs(db1.order) do
        local t2 = db2.tables[t1.name]
        if not t2 then
            problems[#problems + 1] = t1.name .. ' missing'
        else
            if #t1.rows ~= #t2.rows then
                problems[#problems + 1] = ('%s: %d vs %d rows'):format(t1.name, #t1.rows, #t2.rows)
            end
            for i = 1, math.min(#t1.rows, #t2.rows) do
                for c = 1, t1.ncols do
                    if t1.rows[i][c] ~= t2.rows[i][c] then
                        problems[#problems + 1] = ('%s row %d %s: %s vs %s'):format(t1.name, i, t1.cols[c].name,
                            tostring(t1.rows[i][c]), tostring(t2.rows[i][c]))
                    end
                end
            end
            if t1.autoCol and t1.nextId ~= t2.nextId then
                problems[#problems + 1] = ('%s next id %d vs %d'):format(t1.name, t1.nextId, t2.nextId)
            end
        end
    end
    H.eq(#problems, 0,
        label .. ((#problems > 0) and (': ' .. table.concat(problems, '; ', 1, math.min(#problems, 5))) or ''))
end

local IS_UTC = os.time({ year = 2026, month = 1, day = 1, hour = 0 }) == 1767225600
    and os.time({ year = 2026, month = 7, day = 1, hour = 0 }) == 1782864000

-- ============================================================================
--               1. CONSTRUCTS, CHECKED AGAINST MariaDB + OXMYSQL
-- ============================================================================

local N = setmetatable({}, {
    __tostring = function() return 'NULL' end,
}) -- a nil parameter
-- { kind, sql, params, expect = what oxmysql returned | err = MariaDB's message | unsupported = true,
--   write = true (compare fieldCount, affectedRows, insertId, changedRows, info), tz = true }
local CASES = {
    {
        'query',
        'CREATE TABLE IF NOT EXISTS cp_t_types (\n  id INT AUTO_INCREMENT PRIMARY KEY,\n  ti TINYINT NOT NULL DEFAULT 0,\n  b TINYINT(1) NOT NULL DEFAULT 0,\n  si SMALLINT NULL,\n  vc VARCHAR(8) NULL,\n  d DECIMAL(4,2) NOT NULL DEFAULT 1.00,\n  dt DATETIME NULL,\n  da DATE NULL,\n  e ENUM(\'a\',\'b\',\'c\') NOT NULL DEFAULT \'a\',\n  e2 ENUM(\'x\',\'y\') NOT NULL,\n  j JSON NULL,\n  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,\n  updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,\n  INDEX idx_vc (vc)\n)',
        {},
        write = true,
        expect = { fieldCount = 0, affectedRows = 0, insertId = 0, changedRows = 0, info = '' },
    },
    {
        'query',
        'CREATE TABLE IF NOT EXISTS cp_t_types (id INT PRIMARY KEY)',
        {},
        write = true,
        expect = { fieldCount = 0, affectedRows = 0, insertId = 0, changedRows = 0, info = '' },
    },
    { 'query', 'CREATE TABLE cp_t_types (id INT PRIMARY KEY)', {}, err = 'Table \'cp_t_types\' already exists' },
    {
        'query',
        'CREATE TABLE IF NOT EXISTS cp_t_copy LIKE cp_t_types',
        {},
        write = true,
        expect = { fieldCount = 0, affectedRows = 0, insertId = 0, changedRows = 0, info = '' },
    },
    {
        'query',
        'ALTER TABLE cp_t_types ADD COLUMN extra VARCHAR(10) NULL',
        {},
        write = true,
        expect = {
            fieldCount = 0,
            affectedRows = 0,
            insertId = 0,
            changedRows = 0,
            info = 'Records: 0  Duplicates: 0  Warnings: 0',
        },
    },
    {
        'query',
        'ALTER TABLE cp_t_types ADD COLUMN extra VARCHAR(10) NULL',
        {},
        err = 'Duplicate column name \'extra\'',
    },
    {
        'query',
        'CREATE TABLE IF NOT EXISTS cp_t_uniq (\n  id INT AUTO_INCREMENT PRIMARY KEY,\n  a VARCHAR(10) NOT NULL,\n  b INT NOT NULL,\n  n INT NOT NULL DEFAULT 0,\n  UNIQUE KEY uq_ab (a, b)\n)',
        {},
        write = true,
        expect = { fieldCount = 0, affectedRows = 0, insertId = 0, changedRows = 0, info = '' },
    },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)', { 'first', 'x' }, expect = 1 },
    {
        'single',
        'SELECT id, ti, b, si, vc, d, e, e2, j, extra, created_at IS NOT NULL AS has_created, UNIX_TIMESTAMP(created_at) - UNIX_TIMESTAMP(updated_at) AS same_ts FROM cp_t_types WHERE id = 1',
        {},
        expect = {
            id = 1,
            ti = 0,
            b = false,
            vc = 'first',
            d = '1.00',
            e = 'a',
            e2 = 'x',
            has_created = 1,
            same_ts = 0,
        },
    },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)', { 'second', 'y' }, expect = 2 },
    { 'insert', 'INSERT INTO cp_t_types (id, vc, e2) VALUES (?, ?, ?)', { 10, 'ten', 'x' }, expect = 10 },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)', { 'eleven', 'x' }, expect = 11 },
    { 'update', 'DELETE FROM cp_t_types WHERE id = ?', { 11 }, expect = 1 },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)', { 'twelve', 'x' }, expect = 12 },
    {
        'query',
        'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?), (?, ?)',
        { 'm1', 'x', 'm2', 'y' },
        write = true,
        expect = {
            fieldCount = 0,
            affectedRows = 2,
            insertId = 13,
            changedRows = 0,
            info = 'Records: 2  Duplicates: 0  Warnings: 0',
        },
    },
    {
        'query',
        'SELECT id, vc FROM cp_t_types ORDER BY id',
        {},
        expect = {
            { id = 1, vc = 'first' },
            { id = 2, vc = 'second' },
            { id = 10, vc = 'ten' },
            { id = 12, vc = 'twelve' },
            { id = 13, vc = 'm1' },
            { id = 14, vc = 'm2' },
        },
    },
    { 'insert', 'INSERT INTO cp_t_types (ti, e2) VALUES (?, ?)', { N, 'x' }, err = 'Column \'ti\' cannot be null' },
    {
        'insert',
        'INSERT INTO cp_seasons (name) VALUES (?)',
        { 'no start' },
        err = 'Field \'starts_at\' doesn\'t have a default value',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)',
        { 'ninechars', 'x' },
        err = 'Data too long for column \'vc\' at row 1',
    },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)', { 'éééééééé', 'x' }, expect = 15 },
    {
        'insert',
        'INSERT INTO cp_t_types (vc, e2) VALUES (?, ?)',
        { 'ééééééééé', 'x' },
        err = 'Data too long for column \'vc\' at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (ti, e2) VALUES (?, ?)',
        { 128, 'x' },
        err = 'Out of range value for column \'ti\' at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (ti, e2) VALUES (?, ?)',
        { -129, 'x' },
        err = 'Out of range value for column \'ti\' at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (si, e2) VALUES (?, ?)',
        { 32768, 'x' },
        err = 'Out of range value for column \'si\' at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (e, e2) VALUES (?, ?)',
        { 'z', 'x' },
        err = 'Data truncated for column \'e\' at row 1',
    },
    { 'insert', 'INSERT INTO cp_t_types (e, e2, vc) VALUES (?, ?, ?)', { 'B', 'Y', 'enumcase' }, expect = 16 },
    { 'single', 'SELECT e, e2 FROM cp_t_types WHERE vc = \'enumcase\'', {}, expect = { e = 'b', e2 = 'y' } },
    {
        'insert',
        'INSERT INTO cp_t_types (j, e2) VALUES (?, ?)',
        { '{bad', 'x' },
        err = 'CONSTRAINT `cp_t_types.j` failed for `saves`.`cp_t_types`',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (da, e2) VALUES (?, ?)',
        { 'notadate', 'x' },
        err = 'Incorrect date value: \'notadate\' for column `saves`.`cp_t_types`.`da` at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (dt, e2) VALUES (?, ?)',
        { '2026-02-30 10:00:00', 'x' },
        err = 'Incorrect datetime value: \'2026-02-30 10:00:00\' for column `saves`.`cp_t_types`.`dt` at row 1',
    },
    {
        'insert',
        'INSERT INTO cp_t_types (ti, e2) VALUES (?, ?)',
        { 'abc', 'x' },
        err = 'Incorrect integer value: \'abc\' for column `saves`.`cp_t_types`.`ti` at row 1',
    },
    { 'insert', 'INSERT INTO cp_t_types (d, e2, vc) VALUES (?, ?, ?)', { 1.125, 'x', 'dec1' }, expect = 17 },
    { 'insert', 'INSERT INTO cp_t_types (d, e2, vc) VALUES (?, ?, ?)', { -1.125, 'x', 'dec2' }, expect = 18 },
    { 'insert', 'INSERT INTO cp_t_types (d, e2, vc) VALUES (?, ?, ?)', { '2.345', 'x', 'dec3' }, expect = 19 },
    {
        'insert',
        'INSERT INTO cp_t_types (d, e2, vc) VALUES (?, ?, ?)',
        { 99.999, 'x', 'dec4' },
        err = 'Out of range value for column \'d\' at row 1',
    },
    { 'insert', 'INSERT INTO cp_t_types (ti, si, e2, vc) VALUES (2.5, ?, ?, ?)', { '3.5', 'x', 'ints1' }, expect = 20 },
    { 'insert', 'INSERT INTO cp_t_types (ti, si, e2, vc) VALUES (-2.5, 2.5e0, ?, ?)', { 'x', 'ints2' }, expect = 21 },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (101, ?)', { 'x' }, expect = 22 },
    { 'insert', 'INSERT INTO cp_t_types (vc, e2) VALUES (1.50, ?)', { 'x' }, expect = 23 },
    {
        'query',
        'SELECT vc, d, ti, si FROM cp_t_types WHERE vc LIKE \'dec%\' OR vc LIKE \'ints%\' OR vc IN (\'101\', \'1.50\') ORDER BY id',
        {},
        expect = {
            { vc = 'dec1', d = '1.13', ti = 0 },
            { vc = 'dec2', d = '-1.13', ti = 0 },
            { vc = 'dec3', d = '2.35', ti = 0 },
            { vc = 'ints1', d = '1.00', ti = 3, si = 4 },
            { vc = 'ints2', d = '1.00', ti = -3, si = 2 },
            { vc = '101', d = '1.00', ti = 0 },
            { vc = '1.50', d = '1.00', ti = 0 },
        },
    },
    {
        'insert',
        'INSERT INTO cp_t_types (dt, da, e2, vc) VALUES (FROM_UNIXTIME(?), ?, ?, ?)',
        { 1789900000, '2026-09-28', 'x', 'dates' },
        expect = 24,
    },
    {
        'insert',
        'INSERT INTO cp_t_types (dt, da, e2, vc) VALUES (?, FROM_UNIXTIME(?), ?, ?)',
        { '2026-09-21 14:13:20', 1789900000, 'x', 'dates2' },
        expect = 25,
    },
    {
        'query',
        'SELECT vc, dt, da, UNIX_TIMESTAMP(dt) AS dts, UNIX_TIMESTAMP(da) AS das, DATE_FORMAT(da, \'%Y-%m-%d\') AS daf FROM cp_t_types WHERE vc LIKE \'dates%\' ORDER BY id',
        {},
        expect = {
            {
                vc = 'dates',
                dt = 1789900000000,
                da = 1790553600000,
                dts = 1789900000,
                das = 1790553600,
                daf = '2026-09-28',
            },
            {
                vc = 'dates2',
                dt = 1790000000000,
                da = 1789862400000,
                dts = 1790000000,
                das = 1789862400,
                daf = '2026-09-20',
            },
        },
        tz = true,
    },
    {
        'insert',
        'INSERT INTO cp_t_types (j, e2, vc) VALUES (?, ?, \'json\')',
        { '{"a": 1, "b":[1, {"c":null}], "s":"x\\u00e9"}', 'x' },
        expect = 26,
    },
    {
        'single',
        'SELECT j, JSON_VALID(j) AS v FROM cp_t_types WHERE vc = \'json\'',
        {},
        expect = { j = '{"a": 1, "b":[1, {"c":null}], "s":"x\\u00e9"}', v = 1 },
    },
    { 'update', 'INSERT INTO cp_t_uniq (a, b) VALUES (?, ?)', { 'x', 1 }, expect = 1 },
    {
        'insert',
        'INSERT INTO cp_t_uniq (a, b) VALUES (?, ?)',
        { 'x', 1 },
        err = 'Duplicate entry \'x-1\' for key \'uq_ab\'',
    },
    {
        'insert',
        'INSERT INTO cp_t_uniq (a, b) VALUES (?, ?)',
        { 'X ', 1 },
        err = 'Duplicate entry \'X -1\' for key \'uq_ab\'',
    },
    { 'insert', 'INSERT IGNORE INTO cp_t_uniq (a, b) VALUES (?, ?)', { 'x', 1 }, expect = 0 },
    {
        'query',
        'INSERT IGNORE INTO cp_t_uniq (a, b) VALUES (?, ?)',
        { 'x', 1 },
        write = true,
        expect = { fieldCount = 0, affectedRows = 0, insertId = 0, changedRows = 0, info = '' },
    },
    { 'insert', 'INSERT INTO cp_t_uniq (a, b) VALUES (?, ?)', { 'x', 2 }, expect = 6 },
    {
        'update',
        'INSERT INTO cp_t_uniq (a, b, n) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE n = n + VALUES(n)',
        { 'X', 1, 5 },
        expect = 2,
    },
    {
        'update',
        'INSERT INTO cp_t_uniq (a, b, n) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE n = VALUES(n)',
        { 'x', 1, 5 },
        expect = 1,
    },
    {
        'insert',
        'INSERT INTO cp_t_uniq (a, b, n) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE n = VALUES(n)',
        { 'x', 1, 7 },
        expect = 1,
    },
    {
        'update',
        'INSERT INTO cp_t_uniq (a, b, n) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE n = VALUES(n)',
        { 'y', 1, 7 },
        expect = 1,
    },
    {
        'update',
        'UPDATE cp_t_uniq SET b = ? WHERE a = ? AND b = ?',
        { 1, 'x', 2 },
        err = 'Duplicate entry \'x-1\' for key \'uq_ab\'',
    },
    { 'update', 'UPDATE IGNORE cp_t_uniq SET b = ? WHERE a = ? AND b = ?', { 1, 'x', 2 }, expect = 1 },
    {
        'query',
        'SELECT id, a, b, n FROM cp_t_uniq ORDER BY id',
        {},
        expect = {
            { id = 1, a = 'x', b = 1, n = 7 },
            { id = 6, a = 'x', b = 2, n = 0 },
            { id = 10, a = 'y', b = 1, n = 7 },
        },
    },
    {
        'update',
        'INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department, xp) VALUES (\'ABC1\', \'101\', \'Sergeant\', \'Zoë Été\', \'sast\', 50), (\'abd2\', \'007\', NULL, \'bob\', \'fib\', 10), (\'XYZ3\', NULL, \'Trooper\', NULL, \'sast\', 0), (\'NUL4\', \'NULL\', \'x\', \'Émile\', NULL, 5), (\'LOW5\', \'12\', \'Cadet\', \'adam\', \'Fib\', 3)',
        {},
        expect = 5,
    },
    {
        'update',
        'INSERT INTO cp_officers (citizenid) VALUES (\'abc1\')',
        {},
        err = 'Duplicate entry \'abc1\' for key \'PRIMARY\'',
    },
    {
        'update',
        'INSERT INTO cp_officers (citizenid) VALUES (\'ABC1   \')',
        {},
        err = 'Duplicate entry \'ABC1   \' for key \'PRIMARY\'',
    },
    { 'update', 'INSERT IGNORE INTO cp_officers (citizenid, xp) VALUES (\'Abc1\', 99)', {}, expect = 0 },
    {
        'update',
        'INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department) VALUES (?, NULLIF(?, \'\'), NULLIF(?, \'\'), ?, ?) ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), rank_label = VALUES(rank_label), display_name = VALUES(display_name), department = VALUES(department)',
        { 'abc1', '101', 'Sergeant', 'Zoë Été', 'sast' },
        expect = 1,
    },
    {
        'update',
        'INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department) VALUES (?, NULLIF(?, \'\'), NULLIF(?, \'\'), ?, ?) ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), rank_label = VALUES(rank_label), display_name = VALUES(display_name), department = VALUES(department)',
        { 'ABC1', '', 'Sergeant', 'Zoë Été', 'sast' },
        expect = 2,
    },
    {
        'update',
        'INSERT INTO cp_officers (citizenid, xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE xp = GREATEST(0, xp + ?)',
        { 'abd2', 0, -25 },
        expect = 2,
    },
    {
        'query',
        'INSERT INTO cp_officers (citizenid, xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE xp = GREATEST(0, xp + ?)',
        { 'NEW6', 40, 40 },
        write = true,
        expect = { fieldCount = 0, affectedRows = 1, insertId = 0, changedRows = 0, info = '' },
    },
    {
        'query',
        'SELECT citizenid, callsign, rank_label, display_name, department, xp, hide_name, streak_days FROM cp_officers ORDER BY citizenid',
        {},
        expect = {
            {
                citizenid = 'ABC1',
                rank_label = 'Sergeant',
                display_name = 'Zoë Été',
                department = 'sast',
                xp = 50,
                hide_name = false,
                streak_days = 0,
            },
            {
                citizenid = 'abd2',
                callsign = '007',
                display_name = 'bob',
                department = 'fib',
                xp = 0,
                hide_name = false,
                streak_days = 0,
            },
            {
                citizenid = 'LOW5',
                callsign = '12',
                rank_label = 'Cadet',
                display_name = 'adam',
                department = 'Fib',
                xp = 3,
                hide_name = false,
                streak_days = 0,
            },
            { citizenid = 'NEW6', xp = 40, hide_name = false, streak_days = 0 },
            {
                citizenid = 'NUL4',
                callsign = 'NULL',
                rank_label = 'x',
                display_name = 'Émile',
                xp = 5,
                hide_name = false,
                streak_days = 0,
            },
            {
                citizenid = 'XYZ3',
                rank_label = 'Trooper',
                department = 'sast',
                xp = 0,
                hide_name = false,
                streak_days = 0,
            },
        },
    },
    { 'scalar', 'SELECT callsign FROM cp_officers WHERE citizenid = \'NUL4\'', {}, expect = 'NULL' },
    { 'scalar', 'SELECT callsign FROM cp_officers WHERE citizenid = \'abd2\'', {}, expect = '007' },
    { 'scalar', 'SELECT callsign FROM cp_officers WHERE citizenid = \'ABC1\'', {}, expect = nil },
    { 'single', 'SELECT citizenid FROM cp_officers WHERE citizenid = \'nobody\'', {}, expect = nil },
    { 'scalar', 'SELECT hide_name FROM cp_officers WHERE citizenid = \'XYZ3\'', {}, expect = false },
    {
        'insert',
        'INSERT INTO cp_seasons (name, starts_at, ends_at, active) VALUES (?, FROM_UNIXTIME(?), FROM_UNIXTIME(?), 0)',
        { 'Season 1', 1782700000, 1788100000 },
        expect = 1,
    },
    {
        'insert',
        'INSERT INTO cp_seasons (name, starts_at, active) VALUES (?, FROM_UNIXTIME(?), 1)',
        { 'Season 2', 1788103600 },
        expect = 2,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-a',
            'patrol',
            'beat_patrol',
            'ABC1',
            'sast',
            2,
            1,
            1,
            'standard',
            'completed',
            'completed',
            100,
            100,
            800,
            1,
            800,
            'paid',
            300,
            '{"cash":{"status":"none","amount":800,"paid":0},"points":{"bonuses":[{"id":"no_vehicle_damage","points":10},{"id":"fast_finish","points":5}],"final":100},"period":"2026-W39","endReason":"completed"}',
            0,
            N,
            0,
            1789903600,
        },
        expect = 1,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-b',
            'tactical',
            'gang_shootout',
            'ABC1',
            'sast',
            2,
            2,
            2,
            'reinforced',
            'completed',
            'completed',
            200,
            180,
            1000,
            1.15,
            0,
            'held',
            420,
            '{"cash":{"status":"held","amount":1150},"points":{"bonuses":[{"id":"no_participant_downed"}]},"flagged":{"reason":"speed"}}',
            1,
            'speed',
            0,
            1789907200,
        },
        expect = 2,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-b',
            'tactical',
            'gang_shootout',
            'abd2',
            'fib',
            2,
            2,
            2,
            'reinforced',
            'completed',
            'completed',
            200,
            180,
            1000,
            1.15,
            1150,
            'paid',
            420,
            '{"cash":{"status":"held","amount":1150},"points":{"bonuses":[{"id":"no_participant_downed"}]},"flagged":{"reason":"speed"}}',
            0,
            N,
            0,
            1789907200,
        },
        expect = 3,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-c',
            'patrol',
            'business_check',
            'abd2',
            'fib',
            2,
            1,
            1,
            'standard',
            'failed',
            'time_limit',
            60,
            15,
            250,
            1.44,
            0,
            'none',
            600,
            '{"cash":{"amount":0},"points":{"bonuses":{}},"xpCounted":1}',
            0,
            N,
            0,
            1790008000,
        },
        expect = 4,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-d',
            'patrol',
            'beat_patrol',
            'XYZ3',
            'sast',
            1,
            1,
            1,
            'standard',
            'abandoned',
            'quit',
            60,
            0,
            250,
            1,
            0,
            'none',
            90,
            N,
            0,
            N,
            1,
            1786300000,
        },
        expect = 5,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-e',
            'investigation',
            'warrant_service',
            'LOW5',
            'Fib',
            N,
            1,
            1,
            'heavy',
            'completed',
            'completed',
            150,
            150,
            900,
            1.3,
            0,
            'paying',
            200,
            '[]',
            0,
            N,
            0,
            1790080000,
        },
        expect = 6,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants, departments_n,\n  tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged,\n  flag_reason, voided, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))',
        {
            'run-f',
            'manual_award',
            'manual_award',
            'ABC1',
            'sast',
            2,
            1,
            1,
            'standard',
            'completed',
            'completed',
            0,
            25,
            0,
            1,
            0,
            'none',
            0,
            N,
            0,
            N,
            0,
            1790116000,
        },
        expect = 7,
    },
    {
        'query',
        'INSERT IGNORE INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE id <= ? AND created_at < FROM_UNIXTIME(?)',
        { 10, 1789900000 },
        write = true,
        expect = {
            fieldCount = 0,
            affectedRows = 1,
            insertId = 5,
            changedRows = 0,
            info = 'Records: 1  Duplicates: 0  Warnings: 0',
        },
    },
    {
        'update',
        'INSERT IGNORE INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE id <= ? AND created_at < FROM_UNIXTIME(?)',
        { 10, 1789900000 },
        expect = 0,
    },
    {
        'update',
        'DELETE r FROM cp_mission_runs r INNER JOIN cp_mission_runs_archive a ON a.id = r.id AND a.run_uuid = r.run_uuid AND a.citizenid = r.citizenid AND a.created_at = r.created_at WHERE r.id <= ? AND r.created_at < FROM_UNIXTIME(?)',
        { 10, 1789900000 },
        expect = 1,
    },
    {
        'insert',
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (\'run-g\', \'patrol\', \'beat_patrol\', \'XYZ3\', \'sast\', \'completed\', \'completed\', 60)',
        {},
        expect = 8,
    },
    {
        'query',
        'SELECT id, run_uuid, citizenid, UNIX_TIMESTAMP(created_at) AS ts FROM cp_mission_runs_archive',
        {},
        expect = { { id = 5, run_uuid = 'run-d', citizenid = 'XYZ3', ts = 1786300000 } },
    },
    {
        'insert',
        'INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to) SELECT ?, ?, ?, ? FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM cp_disputes WHERE run_id = ?)',
        { 2, 'ABC1', 'not me', 'supervisor', 2 },
        expect = 1,
    },
    {
        'insert',
        'INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to) SELECT ?, ?, ?, ? FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM cp_disputes WHERE run_id = ?)',
        { 2, 'ABC1', 'again', 'supervisor', 2 },
        expect = 0,
    },
    {
        'insert',
        'INSERT INTO cp_disputes (run_id, citizenid, reason, status, handled_by, handled_at) VALUES (4, \'abd2\', \'late\', \'rejected\', \'SUP1\', FROM_UNIXTIME(?))',
        { 1790044000 },
        expect = 2,
    },
    {
        'insert',
        'INSERT INTO cp_disputes (run_id, citizenid, reason) VALUES (3, \'abd2\', \'implicit enum\')',
        {},
        expect = 3,
    },
    {
        'single',
        'SELECT goes_to, status FROM cp_disputes WHERE reason = ?',
        { 'implicit enum' },
        expect = { goes_to = 'supervisor', status = 'open' },
    },
    {
        'update',
        'INSERT INTO cp_badges (citizenid, badge_id, earned_at) VALUES (\'ABC1\', \'iron_wheels\', FROM_UNIXTIME(?)), (\'ABC1\', \'officer_of_week_2026-09-14\', FROM_UNIXTIME(?)), (\'abd2\', \'iron_wheels\', FROM_UNIXTIME(?))',
        { 1789918000, 1789910800, 1789925200 },
        expect = 3,
    },
    {
        'update',
        'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (\'abc1\', \'IRON_WHEELS\', FROM_UNIXTIME(?))',
        { 1789932400 },
        expect = 0,
    },
    {
        'update',
        'INSERT INTO cp_dept_bounties (season_id, week, objective, winner) VALUES (2, 1, \'most_runs\', \'sast\'), (2, 2, \'most_tactical\', NULL), (1, 1, \'most_runs\', \'fib\')',
        {},
        expect = 3,
    },
    {
        'update',
        'INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason, created_at) VALUES (\'ABC1\', \'supervisor\', \'audit\', \'setTypePayout\', \'patrol\', \'250\', \'300\', \'why? 100%\', FROM_UNIXTIME(?)), (\'console\', \'console\', \'flags\', \'runFlagged\', \'run-b\', NULL, \'speed\', NULL, FROM_UNIXTIME(?)), (\'ADM1\', \'admin\', \'audit\', \'suspend\', \'abd2\', NULL, \'7\', \'spam\', FROM_UNIXTIME(?))',
        { 1789914400, 1789921600, 1789928800 },
        expect = 3,
    },
    {
        'update',
        'INSERT INTO cp_custom_missions (id, mission_type, status, published_version, published_definition, draft_version, draft_definition, file_path, created_by, updated_by, updated_at) VALUES (\'custom_one\', \'patrol\', \'published\', 1, \'{"id":"custom_one","steps":[1,2]}\', 2, \'{"id":"custom_one","steps":[1,2,3]}\', \'missions/custom/custom_one.lua\', \'ABC1\', \'ABC1\', FROM_UNIXTIME(1700000000))',
        {},
        expect = 1,
    },
    {
        'update',
        'INSERT INTO cp_type_payouts (mission_type, amount, admin_locked, updated_by, updated_at) VALUES (\'patrol\', 300, 1, \'ADM1\', FROM_UNIXTIME(?))',
        { 1789936000 },
        expect = 1,
    },
    {
        'update',
        'INSERT INTO cp_mission_tests (mission_id, mission_version, location_index, tier, testers, result, note, tested_by, def_hash) VALUES (\'m1\', NULL, 1, \'heavy\', 2, \'passed\', NULL, \'ADM1\', \'aa\'), (\'m1\', NULL, 1, \'heavy\', 1, \'failed\', \'x\', \'ABC1\', \'bb\'), (\'m2\', 3, 2, \'standard\', 1, \'passed\', \'ok\', \'ADM1\', NULL)',
        {},
        expect = 3,
    },
    { 'update', 'UPDATE cp_officers SET xp = xp WHERE citizenid = \'ABC1\'', {}, expect = 1 },
    {
        'query',
        'UPDATE cp_officers SET xp = xp WHERE citizenid = \'ABC1\'',
        {},
        write = true,
        expect = {
            fieldCount = 0,
            affectedRows = 1,
            insertId = 0,
            changedRows = 0,
            info = 'Rows matched: 1  Changed: 0  Warnings: 0',
        },
    },
    {
        'query',
        'UPDATE cp_officers SET xp = xp + 1 WHERE department = \'sast\'',
        {},
        write = true,
        expect = {
            fieldCount = 0,
            affectedRows = 2,
            insertId = 0,
            changedRows = 2,
            info = 'Rows matched: 2  Changed: 2  Warnings: 0',
        },
    },
    { 'update', 'UPDATE cp_officers SET xp = 0 WHERE citizenid = \'nobody\'', {}, expect = 0 },
    {
        'update',
        'UPDATE cp_officers SET streak_days = xp, xp = streak_days WHERE citizenid = \'LOW5\'',
        {},
        expect = 1,
    },
    {
        'single',
        'SELECT xp, streak_days FROM cp_officers WHERE citizenid = \'LOW5\'',
        {},
        expect = { xp = 3, streak_days = 3 },
    },
    {
        'update',
        'UPDATE cp_officers SET streak_days = NULL WHERE citizenid = \'LOW5\'',
        {},
        err = 'Column \'streak_days\' cannot be null',
    },
    {
        'update',
        'UPDATE cp_custom_missions SET locked_by = ?, locked_until = NOW() + INTERVAL ? MINUTE, updated_at = updated_at WHERE id = ? AND (locked_by IS NULL OR locked_by = ? OR locked_until IS NULL OR locked_until <= NOW())',
        { 'ABC1', 30, 'custom_one', 'ABC1' },
        expect = 1,
    },
    {
        'single',
        'SELECT locked_by, TIMESTAMPDIFF(SECOND, NOW(), locked_until) AS lock_left, UNIX_TIMESTAMP(updated_at) AS upd FROM cp_custom_missions WHERE id = \'custom_one\'',
        {},
        expect = { locked_by = 'ABC1', lock_left = 1799, upd = 1700000000 },
    },
    { 'update', 'UPDATE cp_custom_missions SET draft_tested = 1 WHERE id = \'custom_one\'', {}, expect = 1 },
    {
        'single',
        'SELECT draft_tested, UNIX_TIMESTAMP(updated_at) > 1700000000 AS touched, UNIX_TIMESTAMP(updated_at) - UNIX_TIMESTAMP(NOW()) AS age FROM cp_custom_missions WHERE id = \'custom_one\'',
        {},
        expect = { draft_tested = true, touched = 1, age = -1 },
    },
    { 'update', 'UPDATE cp_custom_missions SET draft_tested = 1 WHERE id = \'custom_one\'', {}, expect = 1 },
    {
        'insert',
        'INSERT INTO cp_custom_missions (id, mission_type, created_by, updated_by) VALUES (\'custom_two\', \'patrol\', \'x\', \'x\')',
        {},
        expect = 0,
    },
    {
        'update',
        'UPDATE IGNORE cp_custom_missions SET id = ? WHERE id = ? AND published_version IS NULL',
        { 'custom_one', 'custom_two' },
        expect = 1,
    },
    {
        'update',
        'UPDATE cp_custom_missions SET id = ? WHERE id = ? AND published_version IS NULL',
        { 'CUSTOM_ONE', 'custom_two' },
        err = 'Duplicate entry \'CUSTOM_ONE\' for key \'PRIMARY\'',
    },
    {
        'update',
        'UPDATE IGNORE cp_custom_missions SET id = ? WHERE id = ? AND published_version IS NULL',
        { 'custom_2b', 'custom_two' },
        expect = 1,
    },
    {
        'query',
        'SELECT id, status, draft_tested FROM cp_custom_missions ORDER BY id',
        {},
        expect = {
            { id = 'custom_2b', status = 'draft', draft_tested = false },
            { id = 'custom_one', status = 'published', draft_tested = true },
        },
    },
    {
        'update',
        'UPDATE cp_mission_runs r SET r.cash_status = \'forfeited\', r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, \'$.cash.status\', \'forfeited\')) WHERE r.cash_status IN (\'held\', \'pending\') AND r.created_at < FROM_UNIXTIME(?) AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = \'open\')',
        { 1790260000 },
        expect = 0,
    },
    {
        'query',
        'SELECT id, cash_status, breakdown FROM cp_mission_runs ORDER BY id',
        {},
        expect = {
            {
                id = 1,
                cash_status = 'paid',
                breakdown = '{"cash":{"status":"none","amount":800,"paid":0},"points":{"bonuses":[{"id":"no_vehicle_damage","points":10},{"id":"fast_finish","points":5}],"final":100},"period":"2026-W39","endReason":"completed"}',
            },
            {
                id = 2,
                cash_status = 'held',
                breakdown = '{"cash":{"status":"held","amount":1150},"points":{"bonuses":[{"id":"no_participant_downed"}]},"flagged":{"reason":"speed"}}',
            },
            {
                id = 3,
                cash_status = 'paid',
                breakdown = '{"cash":{"status":"held","amount":1150},"points":{"bonuses":[{"id":"no_participant_downed"}]},"flagged":{"reason":"speed"}}',
            },
            { id = 4, cash_status = 'none', breakdown = '{"cash":{"amount":0},"points":{"bonuses":{}},"xpCounted":1}' },
            { id = 6, cash_status = 'paying', breakdown = '[]' },
            { id = 7, cash_status = 'none' },
            { id = 8, cash_status = 'none' },
        },
    },
    { 'update', 'UPDATE cp_disputes SET status = \'approved\' WHERE run_id = 2', {}, expect = 1 },
    {
        'update',
        'UPDATE cp_mission_runs r SET r.cash_status = \'forfeited\', r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, \'$.cash.status\', \'forfeited\')) WHERE r.cash_status IN (\'held\', \'pending\') AND r.created_at < FROM_UNIXTIME(?) AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = \'open\')',
        { 1790260000 },
        expect = 1,
    },
    {
        'single',
        'SELECT cash_status, JSON_VALUE(breakdown, \'$.cash.status\') AS s FROM cp_mission_runs WHERE id = 2',
        {},
        expect = { cash_status = 'forfeited', s = 'forfeited' },
    },
    {
        'update',
        'UPDATE cp_mission_runs SET flagged = 0, breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, \'$.flagged\', NULL), breakdown) WHERE id = ? AND flagged = 1 AND voided = 0',
        { 2 },
        expect = 1,
    },
    {
        'single',
        'SELECT flagged, breakdown, JSON_EXTRACT(breakdown, \'$.flagged\') IS NULL AS gone, JSON_EXTRACT(breakdown, \'$.flagged\') AS jf FROM cp_mission_runs WHERE id = 2',
        {},
        expect = {
            flagged = false,
            breakdown = '{"cash": {"status": "forfeited", "amount": 1150}, "points": {"bonuses": [{"id": "no_participant_downed"}]}, "flagged": null}',
            gone = 0,
            jf = 'null',
        },
    },
    {
        'update',
        'UPDATE cp_mission_runs SET breakdown = JSON_SET(COALESCE(breakdown, \'{}\'), \'$.xpCounted\', 1) WHERE id = ? AND (breakdown IS NULL OR JSON_EXTRACT(breakdown, \'$.xpCounted\') IS NULL)',
        { 1 },
        expect = 1,
    },
    {
        'update',
        'UPDATE cp_mission_runs SET breakdown = JSON_SET(COALESCE(breakdown, \'{}\'), \'$.xpCounted\', 1) WHERE id = ? AND (breakdown IS NULL OR JSON_EXTRACT(breakdown, \'$.xpCounted\') IS NULL)',
        { 1 },
        expect = 0,
    },
    {
        'update',
        'UPDATE cp_mission_runs SET breakdown = JSON_SET(COALESCE(breakdown, \'{}\'), \'$.xpCounted\', 1) WHERE id = ? AND (breakdown IS NULL OR JSON_EXTRACT(breakdown, \'$.xpCounted\') IS NULL)',
        { 7 },
        expect = 1,
    },
    {
        'update',
        'UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(breakdown, \'$.xpCounted\') WHERE id = ? AND JSON_EXTRACT(breakdown, \'$.xpCounted\') IS NOT NULL',
        { 4 },
        expect = 1,
    },
    {
        'query',
        'SELECT id, breakdown FROM cp_mission_runs WHERE id IN (1, 4, 7) ORDER BY id',
        {},
        expect = {
            {
                id = 1,
                breakdown = '{"cash": {"status": "none", "amount": 800, "paid": 0}, "points": {"bonuses": [{"id": "no_vehicle_damage", "points": 10}, {"id": "fast_finish", "points": 5}], "final": 100}, "period": "2026-W39", "endReason": "completed", "xpCounted": 1}',
            },
            { id = 4, breakdown = '{"cash": {"amount": 0}, "points": {"bonuses": {}}}' },
            { id = 7, breakdown = '{"xpCounted": 1}' },
        },
    },
    {
        'update',
        'UPDATE cp_mission_runs SET cash_status = \'paid\', cash_paid = ROUND(cash_base * cash_multiplier) WHERE id = ?',
        { 6 },
        expect = 1,
    },
    {
        'single',
        'SELECT cash_paid, cash_status FROM cp_mission_runs WHERE id = 6',
        {},
        expect = { cash_paid = 1170, cash_status = 'paid' },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers WHERE display_name = \'ZOE ETE  \'',
        {},
        expect = { { citizenid = 'ABC1' } },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers WHERE display_name LIKE ? OR citizenid LIKE ? ORDER BY citizenid',
        { '%émi%', 'ab_%' },
        expect = { { citizenid = 'ABC1' }, { citizenid = 'abd2' }, { citizenid = 'NUL4' } },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers WHERE callsign LIKE ? ORDER BY citizenid',
        { '1%' },
        expect = { { citizenid = 'LOW5' } },
    },
    {
        'query',
        'SELECT citizenid, display_name FROM cp_officers ORDER BY display_name IS NULL, display_name, citizenid LIMIT 25',
        {},
        expect = {
            { citizenid = 'LOW5', display_name = 'adam' },
            { citizenid = 'abd2', display_name = 'bob' },
            { citizenid = 'NUL4', display_name = 'Émile' },
            { citizenid = 'ABC1', display_name = 'Zoë Été' },
            { citizenid = 'NEW6' },
            { citizenid = 'XYZ3' },
        },
    },
    {
        'query',
        'SELECT citizenid, display_name FROM cp_officers ORDER BY display_name',
        {},
        expect = {
            { citizenid = 'NEW6' },
            { citizenid = 'XYZ3' },
            { citizenid = 'LOW5', display_name = 'adam' },
            { citizenid = 'abd2', display_name = 'bob' },
            { citizenid = 'NUL4', display_name = 'Émile' },
            { citizenid = 'ABC1', display_name = 'Zoë Été' },
        },
    },
    {
        'query',
        'SELECT citizenid, display_name FROM cp_officers ORDER BY display_name DESC',
        {},
        expect = {
            { citizenid = 'ABC1', display_name = 'Zoë Été' },
            { citizenid = 'NUL4', display_name = 'Émile' },
            { citizenid = 'abd2', display_name = 'bob' },
            { citizenid = 'LOW5', display_name = 'adam' },
            { citizenid = 'NEW6' },
            { citizenid = 'XYZ3' },
        },
    },
    {
        'query',
        'SELECT citizenid, xp FROM cp_officers ORDER BY xp DESC, citizenid ASC LIMIT 2 OFFSET 1',
        {},
        expect = { { citizenid = 'NEW6', xp = 40 }, { citizenid = 'NUL4', xp = 5 } },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers ORDER BY citizenid LIMIT ?',
        { 2 },
        expect = { { citizenid = 'ABC1' }, { citizenid = 'abd2' } },
    },
    { 'query', 'SELECT citizenid FROM cp_officers ORDER BY citizenid LIMIT 0', {}, expect = {} },
    {
        'query',
        'SELECT DISTINCT department FROM cp_officers',
        {},
        expect = { { department = 'sast' }, { department = 'fib' }, {} },
    },
    {
        'query',
        'SELECT DISTINCT department FROM cp_officers ORDER BY department',
        {},
        expect = { {}, { department = 'fib' }, { department = 'sast' } },
    },
    {
        'query',
        'SELECT department, COUNT(*) AS n, SUM(xp) AS xp, MAX(citizenid) AS top FROM cp_officers GROUP BY department',
        {},
        expect = {
            { n = 2, xp = '45', top = 'NUL4' },
            { department = 'fib', n = 2, xp = '3', top = 'LOW5' },
            { department = 'sast', n = 2, xp = '52', top = 'XYZ3' },
        },
    },
    {
        'query',
        'SELECT department, COUNT(*) AS n FROM cp_officers GROUP BY department ORDER BY n DESC, department',
        {},
        expect = { { n = 2 }, { department = 'fib', n = 2 }, { department = 'sast', n = 2 } },
    },
    {
        'query',
        'SELECT r.department, UNIX_TIMESTAMP(DATE(r.created_at - INTERVAL ? HOUR)) AS day_ts, SUM(r.final_points) AS points FROM cp_mission_runs r WHERE r.season_id = ? GROUP BY r.department, day_ts',
        { 6, 2 },
        expect = {
            { department = 'fib', day_ts = 1789862400, points = '180' },
            { department = 'fib', day_ts = 1789948800, points = '15' },
            { department = 'sast', day_ts = 1789862400, points = '280' },
            { department = 'sast', day_ts = 1790035200, points = '25' },
        },
        tz = true,
    },
    {
        'single',
        'SELECT COUNT(*) AS n, SUM(xp) AS s, COALESCE(SUM(xp), 0) AS c, MAX(xp) AS m, MIN(xp) AS mi FROM cp_officers WHERE 1 = 0',
        {},
        expect = { n = 0, c = '0' },
    },
    {
        'single',
        'SELECT COUNT(callsign) AS c, COUNT(*) AS n, SUM(xp > 0) AS pos, MAX(hide_name) AS mh, MIN(display_name) AS first FROM cp_officers',
        {},
        expect = { c = 3, n = 6, pos = '5', mh = 0, first = 'adam' },
    },
    {
        'single',
        'SELECT SUM(cash_multiplier) AS sm, MAX(cash_multiplier) AS mm, SUM(cash_base * cash_multiplier) AS total, ROUND(SUM(cash_base * cash_multiplier)) AS r FROM cp_mission_runs',
        {},
        expect = { sm = '8.04', mm = '1.44', total = '4630.00', r = '4630' },
    },
    {
        'query',
        'SELECT citizenid, GROUP_CONCAT(badge_id ORDER BY earned_at DESC SEPARATOR \',\') AS b, SUBSTRING_INDEX(GROUP_CONCAT(badge_id ORDER BY earned_at DESC SEPARATOR \',\'), \',\', 1) AS latest FROM cp_badges GROUP BY citizenid',
        {},
        expect = {
            { citizenid = 'ABC1', b = 'iron_wheels,officer_of_week_2026-09-14', latest = 'iron_wheels' },
            { citizenid = 'abd2', b = 'iron_wheels', latest = 'iron_wheels' },
        },
    },
    {
        'single',
        'SELECT GROUP_CONCAT(callsign ORDER BY citizenid SEPARATOR \'|\') AS g, GROUP_CONCAT(callsign) AS g2 FROM cp_officers',
        {},
        expect = { g = '007|12|NULL', g2 = '007,12,NULL' },
    },
    {
        'single',
        'SELECT SUBSTRING_INDEX(\'a,b,c\', \',\', 2) AS a, SUBSTRING_INDEX(\'a,b,c\', \',\', -2) AS b, SUBSTRING_INDEX(\'abc\', \',\', 1) AS c, SUBSTRING_INDEX(NULL, \',\', 1) AS d',
        {},
        expect = { a = 'a,b', b = 'b,c', c = 'abc' },
    },
    {
        'single',
        'SELECT \'abc\' = 0 AS a, 5 = \'5\' AS b, \'a\' < \'B\' AS c, \'abc\' = \'ABC  \' AS d, \'é\' = \'E\' AS e, NULL = NULL AS f, \'10\' < \'9\' AS g, \'10\' < 9 AS h, 1 = 1.0 AS i, 1.5 > 1 AS k',
        {},
        expect = { a = 1, b = 1, c = 1, d = 1, e = 1, g = 1, h = 0, i = 1, k = 1 },
    },
    {
        'single',
        'SELECT 1 IN (NULL, 1) AS a, 2 IN (NULL, 1) AS b, 2 NOT IN (NULL, 1) AS c, \'A\' IN (\'a\', \'b\') AS d, 1 IN (\'1\', 2) AS e, NULL IN (1) AS f, \'z\' NOT IN (\'a\') AS g',
        {},
        expect = { a = 1, d = 1, e = 1, g = 1 },
    },
    {
        'single',
        'SELECT COALESCE(NULL, 1.5, 2) AS a, COALESCE(NULL, NULL) AS b, COALESCE(NULL, \'x\', 1) AS c, NULLIF(\'\', \'\') AS d, NULLIF(\'A\', \'a\') AS e, NULLIF(5, 0) AS f, IF(1, 2, 3) AS g, IF(NULL, \'y\', \'n\') AS h, IF(0, 1, \'x\') AS i',
        {},
        expect = { a = '1.5', c = 'x', f = 5, g = 2, h = 'n', i = 'x' },
    },
    {
        'single',
        'SELECT GREATEST(0, -5 + 2) AS a, GREATEST(1, 2.5) AS b, GREATEST(\'a\', \'B\') AS c, GREATEST(1, NULL) AS d, ROUND(2.5) AS e, ROUND(-2.5) AS f, ROUND(2.5e0) AS g, ROUND(3.5e0) AS h, ROUND(7) AS i, ROUND(1500 * 1.25) AS j',
        {},
        expect = { a = 0, b = '2.5', c = 'B', e = '3', f = '-3', g = 2, h = 4, i = 7, j = '1875' },
    },
    {
        'single',
        'SELECT CASE WHEN 1 = 1 THEN 1 ELSE 0.5 END AS a, CASE WHEN 1 = 0 THEN \'x\' END AS b, CASE 2 WHEN 1 THEN \'one\' WHEN 2 THEN \'two\' END AS c, CASE WHEN NULL THEN 1 ELSE 2 END AS d',
        {},
        expect = { a = '1.0', c = 'two', d = 2 },
    },
    {
        'single',
        'SELECT 1 + 2 AS a, 3 - 5 AS b, 4 * 2 AS c, 800 * 1.15 AS d, 1.5 + 1 AS e, \'5\' + 1 AS f, -(2) AS g, 1.25 * 1.2 AS h, 2 - 0.5 AS i',
        {},
        expect = { a = 3, b = -2, c = 8, d = '920.00', e = '2.5', f = 6, g = -2, h = '1.500', i = '1.5' },
    },
    {
        'single',
        'SELECT NOT 1 AS a, NOT 0 AS b, NOT NULL AS c, 1 AND NULL AS d, 0 AND NULL AS e, 1 OR NULL AS f, 0 OR NULL AS g, (1 = 1) AS h, NULL IS NULL AS i, 1 IS NOT NULL AS k',
        {},
        expect = { a = 0, b = 1, e = 0, f = 1, h = 1, i = 1, k = 1 },
    },
    {
        'single',
        'SELECT CHAR_LENGTH(\'é€😀\') AS c, CHAR_LENGTH(NULL) AS n, LOWER(\'ÉA b\') AS l, CHAR_LENGTH(UUID()) AS u, UUID() = UUID() AS same',
        {},
        expect = { c = 3, l = 'éa b', u = 36, same = 0 },
    },
    {
        'single',
        'SELECT ? AS s, ? AS i, ? AS d, ? AS n, ? + 0 AS b, ? AS t',
        { 'text', 42, 1.5, N, true, false },
        expect = { s = 'text', i = 42, d = '1.5', b = 1, t = 0 },
    },
    {
        'single',
        'SELECT JSON_SET(\'{}\', \'$.a\', ?) AS t, JSON_SET(\'{}\', \'$.a\', ?) AS f, JSON_SET(\'{}\', \'$.a\', ?) AS n, JSON_SET(\'{}\', \'$.a\', ?) AS d',
        { true, false, N, 2.25 },
        expect = { t = '{"a": true}', f = '{"a": false}', n = '{"a": null}', d = '{"a": 2.25}' },
    },
    { 'scalar', 'SELECT 1 AS x FROM cp_officers WHERE citizenid = ? LIMIT 1', { 'ABC1' }, expect = 1 },
    { 'scalar', 'SELECT 1 AS x FROM cp_officers WHERE citizenid = ? LIMIT 1', { 'none' }, expect = nil },
    { 'scalar', 'SELECT COUNT(*) AS n FROM cp_officers', {}, expect = 6 },
    { 'scalar', 'SELECT hide_name AS h FROM cp_officers WHERE citizenid = \'abd2\'', {}, expect = false },
    { 'insert', 'SELECT citizenid FROM cp_officers', {}, expect = nil },
    { 'update', 'SELECT citizenid FROM cp_officers', {}, expect = nil },
    { 'single', 'UPDATE cp_officers SET xp = xp WHERE citizenid = \'ABC1\'', {}, expect = nil },
    { 'scalar', 'UPDATE cp_officers SET xp = xp WHERE citizenid = \'ABC1\'', {}, expect = nil },
    {
        'single',
        'SELECT UNIX_TIMESTAMP(FROM_UNIXTIME(?)) AS a, FROM_UNIXTIME(-5) AS b, UNIX_TIMESTAMP(NULL) AS c, FROM_UNIXTIME(NULL) AS d, UNIX_TIMESTAMP(FROM_UNIXTIME(?) + INTERVAL 90 SECOND) AS e, UNIX_TIMESTAMP(FROM_UNIXTIME(?) - INTERVAL ? MINUTE) AS f, UNIX_TIMESTAMP(FROM_UNIXTIME(?) + INTERVAL 2 HOUR) AS g',
        { 1789900000, 1789900000, 1789900000, 5, 1789900000 },
        expect = { a = 1789900000, e = 1789900090, f = 1789899700, g = 1789907200 },
    },
    {
        'single',
        'SELECT TIMESTAMPDIFF(SECOND, FROM_UNIXTIME(?), FROM_UNIXTIME(?)) AS a, TIMESTAMPDIFF(SECOND, NULL, NOW()) AS b, TIMESTAMPDIFF(SECOND, FROM_UNIXTIME(?), FROM_UNIXTIME(?)) AS c',
        { 1789900000, 1789900090, 1789900090, 1789900000 },
        expect = { a = 90, c = -90 },
    },
    {
        'single',
        'SELECT UNIX_TIMESTAMP(NOW()) - UNIX_TIMESTAMP() AS a, NOW() > FROM_UNIXTIME(?) AS b, NOW() - INTERVAL 1 SECOND < NOW() AS c',
        { 1789900000 },
        expect = { a = 0, b = 1, c = 1 },
    },
    {
        'single',
        'SELECT UNIX_TIMESTAMP(DATE(FROM_UNIXTIME(?))) AS a, UNIX_TIMESTAMP(DATE(FROM_UNIXTIME(?) - INTERVAL 6 HOUR)) AS b, DATE_FORMAT(FROM_UNIXTIME(?), \'%Y-%m-%d %H:%i:%s\') AS c, DATE_FORMAT(FROM_UNIXTIME(?), \'%Y-%m-%d\') AS d, DATE_FORMAT(NULL, \'%Y\') AS e, UNIX_TIMESTAMP(\'2026-09-21 14:13:20\') AS f, FROM_UNIXTIME(?) = \'2026-09-20 09:46:40\' AS g',
        { 1789900000, 1789903600, 1789900000, 1789900000, 1789900000 },
        expect = { a = 1789862400, b = 1789862400, c = '2026-09-20 10:26:40', d = '2026-09-20', f = 1790000000, g = 0 },
        tz = true,
    },
    {
        'query',
        'SELECT badge_id, DATE_FORMAT(earned_at, \'%Y-%m-%d %H:%i:%s\') AS earned_at, UNIX_TIMESTAMP(earned_at) AS earned_ts FROM cp_badges WHERE citizenid = ? ORDER BY earned_at, badge_id',
        { 'ABC1' },
        expect = {
            { badge_id = 'officer_of_week_2026-09-14', earned_at = '2026-09-20 13:26:40', earned_ts = 1789910800 },
            { badge_id = 'iron_wheels', earned_at = '2026-09-20 15:26:40', earned_ts = 1789918000 },
        },
        tz = true,
    },
    {
        'single',
        'SELECT citizenid, xp, streak_days, DATE_FORMAT(last_complete, \'%Y-%m-%d\') AS last_complete, DATE_FORMAT(grace_week, \'%Y-%m-%d\') AS grace_week, grace_used FROM cp_officers WHERE citizenid = ?',
        { 'ABC1' },
        expect = { citizenid = 'ABC1', xp = 51, streak_days = 0, grace_used = 0 },
        tz = true,
    },
    {
        'query',
        'INSERT INTO cp_officers (citizenid, streak_days, last_complete, grace_week, grace_used) VALUES (?, ?, ?, NULLIF(?, \'\'), ?) ON DUPLICATE KEY UPDATE streak_days = VALUES(streak_days), last_complete = VALUES(last_complete), grace_week = VALUES(grace_week), grace_used = VALUES(grace_used)',
        { 'ABC1', 3, '2026-09-28', '', 1 },
        write = true,
        expect = { fieldCount = 0, affectedRows = 2, insertId = 0, changedRows = 0, info = '' },
        tz = true,
    },
    {
        'single',
        'SELECT streak_days, DATE_FORMAT(last_complete, \'%Y-%m-%d\') AS lc, grace_week, last_complete, UNIX_TIMESTAMP(last_complete) AS lts FROM cp_officers WHERE citizenid = ?',
        { 'ABC1' },
        expect = { streak_days = 3, lc = '2026-09-28', last_complete = 1790553600000, lts = 1790553600 },
        tz = true,
    },
    {
        'query',
        'SELECT id, handled_at, UNIX_TIMESTAMP(handled_at) AS h FROM cp_disputes ORDER BY id',
        {},
        expect = { { id = 1 }, { id = 2, handled_at = 1790044000000, h = 1790044000 }, { id = 3 } },
        tz = true,
    },
    {
        'single',
        'SELECT JSON_SET(\'{"a":1,"b":{"c":2}}\', \'$.d\', 3) AS r1, JSON_SET(\'{"a":1,"b":{"c":2}}\', \'$.a\', 5) AS r2, JSON_SET(\'{"a":1,"b":{"c":2}}\', \'$.b.c\', \'x\') AS r3, JSON_SET(\'{"a":1,"b":{"c":2}}\', \'$.b.e\', NULL) AS r4, JSON_SET(\'{}\', \'$.a.b\', 1) AS r5, JSON_SET(\'{ "a" : 1 , "b" : 2 }\', \'$.b\', 7, \'$.c\', \'q"\\\\x/é\') AS r6',
        {},
        expect = {
            r1 = '{"a": 1, "b": {"c": 2}, "d": 3}',
            r2 = '{"a": 5, "b": {"c": 2}}',
            r3 = '{"a": 1, "b": {"c": "x"}}',
            r4 = '{"a": 1, "b": {"c": 2, "e": null}}',
            r5 = '{}',
            r6 = '{"a": 1, "b": 7, "c": "q\\"\\\\x/é"}',
        },
    },
    {
        'single',
        'SELECT JSON_SET(\'{"cash":{"status":"none","paid":0}}\', \'$.cash.status\', \'paid\', \'$.cash.paid\', 800) AS r1, JSON_SET(\'{"a":[1,2]}\', \'$.a[5]\', 9) AS r2, JSON_SET(\'{"a":[1,2]}\', \'$.a[0]\', 9) AS r3, JSON_SET(\'{"a":1}\', \'$.b\', 1.50) AS r4, JSON_SET(\'{"a":1}\', \'$.b\', 2.5e0) AS r5, JSON_SET(\'[]\', \'$[0]\', 1) AS r6, JSON_SET(NULL, \'$.a\', 1) AS r7, JSON_SET(\'{"a":1}\', \'$.a\', JSON_EXTRACT(\'{"x":[1]}\', \'$.x\')) AS r8',
        {},
        expect = {
            r1 = '{"cash": {"status": "paid", "paid": 800}}',
            r2 = '{"a": [1, 2, 9]}',
            r3 = '{"a": [9, 2]}',
            r4 = '{"a": 1, "b": 1.50}',
            r5 = '{"a": 1, "b": 2.5}',
            r6 = '[1]',
            r8 = '{"a": [1]}',
        },
    },
    {
        'single',
        'SELECT JSON_SET(\'{"a":"\\u00e9\\/x","k\\u0041":1e5,"n":-0.0,"arr":[ 1 ,[ ],{ }, "s" ]}\', \'$.z\', 1) AS r1, JSON_SET(\'{"a":1,"a":2}\', \'$.a\', 3) AS r2, JSON_SET(\'{"a":1}\', \'$.b\', \'line1\\nline2\\ttab\') AS r3, JSON_SET(\'{"a":1}\', \'$\', 2) AS r4, JSON_SET(\'[1,2]\', \'$[1]\', \'x\') AS r5',
        {},
        expect = {
            r1 = '{"a": "u00e9/x", "ku0041": 1e5, "n": -0.0, "arr": [1, [], {}, "s"], "z": 1}',
            r2 = '{"a": 3, "a": 2}',
            r3 = '{"a": 1, "b": "line1\\nline2\\ttab"}',
            r4 = '2',
            r5 = '[1, "x"]',
        },
    },
    {
        'single',
        'SELECT JSON_REMOVE(\'{"a":1,"b":2,"c":3}\', \'$.b\') AS r1, JSON_REMOVE(\'{"a":1,"b":2}\', \'$.a\') AS r2, JSON_REMOVE(\'{"a":1}\', \'$.a\') AS r3, JSON_REMOVE(\'{"a":1}\', \'$.z\') AS r4, JSON_REMOVE(\'{ "a" : 1 , "b" : 2 , "c":3}\', \'$.b\') AS r5, JSON_REMOVE(\'[1,2,3]\', \'$[1]\') AS r6',
        {},
        expect = {
            r1 = '{"a": 1, "c": 3}',
            r2 = '{"b": 2}',
            r3 = '{}',
            r4 = '{"a": 1}',
            r5 = '{"a": 1, "c": 3}',
            r6 = '[1, 3]',
        },
    },
    {
        'single',
        'SELECT JSON_EXTRACT(\'{"a": {"b" :  1}}\', \'$.a\') AS r1, JSON_EXTRACT(\'{"a":"x"}\', \'$.a\') AS r2, JSON_EXTRACT(\'{"a":null}\', \'$.a\') AS r3, JSON_EXTRACT(\'{"a":1}\', \'$.z\') AS r4, JSON_EXTRACT(\'{"a":null}\', \'$.a\') IS NULL AS r5, JSON_EXTRACT(\'{"a":[1, {"b":  [2,3]}]}\', \'$.a\') AS r6, JSON_EXTRACT(\'[1,2]\', \'$[1]\') AS r7, JSON_EXTRACT(\'{"a":"\\u00e9"}\', \'$.a\') AS r8',
        {},
        expect = {
            r1 = '{"b": 1}',
            r2 = '"x"',
            r3 = 'null',
            r5 = 0,
            r6 = '[1, {"b": [2, 3]}]',
            r7 = '2',
            r8 = '"u00e9"',
        },
    },
    {
        'single',
        'SELECT JSON_EXTRACT(\'{"p":{"b":[{"id":"x"},{"id":"y"},{"q":1}]}}\', \'$.p.b[*].id\') AS r1, JSON_EXTRACT(\'{"p":{"b":[]}}\', \'$.p.b[*].id\') AS r2, JSON_EXTRACT(\'{"p":{"b":{}}}\', \'$.p.b[*].id\') AS r3, JSON_EXTRACT(\'{"p":{"b":[{"id":"x"}]}}\', \'$.p.b[*].id\') AS r4',
        {},
        expect = { r1 = '["x", "y"]', r4 = '["x"]' },
    },
    {
        'single',
        'SELECT JSON_UNQUOTE(JSON_EXTRACT(\'{"a":"x\\\\ny"}\', \'$.a\')) AS r1, JSON_UNQUOTE(\'abc\') AS r2, JSON_UNQUOTE(JSON_EXTRACT(\'{"a":5}\', \'$.a\')) AS r3, JSON_UNQUOTE(JSON_EXTRACT(\'{"a":"\\u00e9"}\', \'$.a\')) AS r4, JSON_UNQUOTE(NULL) AS r5',
        {},
        expect = { r1 = 'x\ny', r2 = 'abc', r3 = '5', r4 = 'u00e9' },
    },
    {
        'single',
        'SELECT JSON_UNQUOTE(JSON_EXTRACT(\'{"p":"2026-W39"}\', \'$.p\')) = ? AS a, JSON_UNQUOTE(JSON_EXTRACT(\'{"p":"2026-W39"}\', \'$.p\')) = ? AS b, JSON_VALUE(\'{"p":"ABC"}\', \'$.p\') = \'abc\' AS c',
        { '2026-W39', '2026-w39' },
        expect = { a = 1, b = 0, c = 1 },
    },
    {
        'single',
        'SELECT JSON_VALUE(\'{"cash":{"amount":800}}\', \'$.cash.amount\') AS r1, JSON_VALUE(\'{"a":null}\', \'$.a\') AS r2, JSON_VALUE(\'{"a":{"b":1}}\', \'$.a\') AS r3, JSON_VALUE(\'{"a":true}\', \'$.a\') AS r4, JSON_VALUE(\'{"a":"q\\\\"x"}\', \'$.a\') AS r5, JSON_VALUE(\'{"a":1.50}\', \'$.a\') AS r6, JSON_VALUE(\'{"a":false}\', \'$.a\') AS r7, JSON_VALUE(\'{"a":"\\u00e9"}\', \'$.a\') AS r8, JSON_VALUE(\'{"a":[1]}\', \'$.a\') AS r9',
        {},
        expect = { r1 = '800', r4 = '1', r5 = 'q"x', r6 = '1.50', r7 = '0', r8 = 'u00e9' },
    },
    {
        'single',
        'SELECT JSON_CONTAINS(\'["a","b"]\', \'"a"\') AS r1, JSON_CONTAINS(\'["a","b"]\', \'"c"\') AS r2, JSON_CONTAINS(NULL, \'"a"\') AS r3, JSON_CONTAINS(\'"a"\', \'"a"\') AS r4, JSON_CONTAINS(\'[1,2,3]\', \'[1,3]\') AS r5, JSON_CONTAINS(\'{"a":1,"b":2}\', \'{"a":1}\') AS r6, JSON_CONTAINS(\'[1.0]\', \'1\') AS r7',
        {},
        expect = { r1 = 1, r2 = 0, r4 = 1, r5 = 1, r6 = 1, r7 = 1 },
    },
    {
        'single',
        'SELECT JSON_VALID(\'{"a":1}\') AS r1, JSON_VALID(\'{a:1}\') AS r2, JSON_VALID(NULL) AS r3, JSON_VALID(\'\') AS r4, JSON_VALID(\'5\') AS r5, JSON_VALID(\'"a\tb"\') AS r6, JSON_VALID(\'[1,]\') AS r7, JSON_VALID(\' [1] \') AS r8, JSON_VALID(\'01\') AS r9',
        {},
        expect = { r1 = 1, r2 = 0, r4 = 0, r5 = 1, r6 = 0, r7 = 0, r8 = 1, r9 = 0 },
    },
    {
        'single',
        'SELECT LOWER(JSON_TYPE(JSON_EXTRACT(\'{"a":null}\', \'$.a\'))) AS r1, JSON_TYPE(\'1\') AS r2, JSON_TYPE(\'1.5\') AS r3, JSON_TYPE(\'true\') AS r4, JSON_TYPE(\'"s"\') AS r5, JSON_TYPE(\'[]\') AS r6, JSON_TYPE(\'{}\') AS r7',
        {},
        expect = {
            r1 = 'null',
            r2 = 'INTEGER',
            r3 = 'DOUBLE',
            r4 = 'BOOLEAN',
            r5 = 'STRING',
            r6 = 'ARRAY',
            r7 = 'OBJECT',
        },
    },
    {
        'single',
        'SELECT COALESCE(SUM(t.no_damage > 0), 0) AS iron_wheels, COALESCE(SUM(t.mission_id = \'gang_shootout\' AND t.no_downs > 0), 0) AS sharpshooter, COALESCE(SUM(t.mission_type = \'patrol\'), 0) AS road_warrior, COALESCE(SUM(t.participants >= 2), 0) AS partner_in_crime, COALESCE(SUM(t.departments_n >= 2), 0) AS joint_task_force FROM ( SELECT mission_type, mission_id, participants, departments_n, COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, \'$.points.bonuses[*].id\'), \'"no_vehicle_damage"\'), 0) AS no_damage, COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, \'$.points.bonuses[*].id\'), \'"no_participant_downed"\'), 0) AS no_downs FROM cp_mission_runs WHERE citizenid = ? AND state = \'completed\' AND voided = 0 AND flagged = 0 AND mission_type NOT IN (\'manual_award\', \'goal\') UNION ALL SELECT mission_type, mission_id, participants, departments_n, COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, \'$.points.bonuses[*].id\'), \'"no_vehicle_damage"\'), 0) AS no_damage, COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, \'$.points.bonuses[*].id\'), \'"no_participant_downed"\'), 0) AS no_downs FROM cp_mission_runs_archive WHERE citizenid = ? AND state = \'completed\' AND voided = 0 AND flagged = 0 AND mission_type NOT IN (\'manual_award\', \'goal\') ) t',
        { 'abd2', 'abd2' },
        expect = {
            iron_wheels = '0',
            sharpshooter = '1',
            road_warrior = '0',
            partner_in_crime = '1',
            joint_task_force = '1',
        },
    },
    {
        'scalar',
        'SELECT id FROM cp_mission_runs WHERE citizenid = ? AND JSON_UNQUOTE(JSON_EXTRACT(breakdown, \'$.period\')) = ? LIMIT 1',
        { 'ABC1', '2026-W39' },
        expect = 1,
    },
    {
        'scalar',
        'SELECT id FROM cp_mission_runs WHERE citizenid = ? AND JSON_UNQUOTE(JSON_EXTRACT(breakdown, \'$.period\')) = ? LIMIT 1',
        { 'ABC1', '2026-w39' },
        expect = nil,
    },
    {
        'query',
        'SELECT r.id, r.citizenid, o.display_name, o.callsign, o.hide_name FROM cp_mission_runs r LEFT JOIN cp_officers o ON o.citizenid = r.citizenid ORDER BY r.id',
        {},
        expect = {
            { id = 1, citizenid = 'ABC1', display_name = 'Zoë Été', hide_name = false },
            { id = 2, citizenid = 'ABC1', display_name = 'Zoë Été', hide_name = false },
            { id = 3, citizenid = 'abd2', display_name = 'bob', callsign = '007', hide_name = false },
            { id = 4, citizenid = 'abd2', display_name = 'bob', callsign = '007', hide_name = false },
            { id = 6, citizenid = 'LOW5', display_name = 'adam', callsign = '12', hide_name = false },
            { id = 7, citizenid = 'ABC1', display_name = 'Zoë Été', hide_name = false },
            { id = 8, citizenid = 'XYZ3', hide_name = false },
        },
    },
    {
        'query',
        'SELECT d.id, d.reason, r.run_uuid, r.flagged, o.display_name FROM cp_disputes d JOIN cp_mission_runs r ON r.id = d.run_id LEFT JOIN cp_officers o ON o.citizenid = d.citizenid ORDER BY d.created_at, d.id',
        {},
        expect = {
            { id = 1, reason = 'not me', run_uuid = 'run-b', flagged = false, display_name = 'Zoë Été' },
            { id = 2, reason = 'late', run_uuid = 'run-c', flagged = false, display_name = 'bob' },
            { id = 3, reason = 'implicit enum', run_uuid = 'run-b', flagged = false, display_name = 'bob' },
        },
    },
    {
        'query',
        'SELECT r.id, r.mission_id, (SELECT COUNT(*) FROM cp_disputes d WHERE d.run_id = r.id) AS disputes FROM cp_mission_runs r WHERE r.citizenid = ? ORDER BY r.created_at DESC, r.id DESC LIMIT ?',
        { 'ABC1', 20 },
        expect = {
            { id = 7, mission_id = 'manual_award', disputes = 0 },
            { id = 2, mission_id = 'gang_shootout', disputes = 1 },
            { id = 1, mission_id = 'beat_patrol', disputes = 0 },
        },
    },
    {
        'query',
        'SELECT r.id FROM cp_mission_runs r WHERE r.run_uuid IN (SELECT d.run_uuid FROM cp_mission_runs d WHERE d.department = ?) AND r.run_uuid NOT IN (SELECT m.run_uuid FROM cp_mission_runs m WHERE m.citizenid = ?) ORDER BY r.id',
        { 'fib', 'LOW5' },
        expect = { { id = 2 }, { id = 3 }, { id = 4 } },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers o WHERE EXISTS (SELECT 1 FROM cp_badges b WHERE b.citizenid = o.citizenid) ORDER BY citizenid',
        {},
        expect = { { citizenid = 'ABC1' }, { citizenid = 'abd2' } },
    },
    {
        'query',
        'SELECT citizenid FROM cp_officers o WHERE NOT EXISTS (SELECT 1 FROM cp_badges b WHERE b.citizenid = o.citizenid) ORDER BY citizenid',
        {},
        expect = { { citizenid = 'LOW5' }, { citizenid = 'NEW6' }, { citizenid = 'NUL4' }, { citizenid = 'XYZ3' } },
    },
    { 'single', 'SELECT 1 AS x WHERE 2 NOT IN (SELECT callsign FROM cp_officers)', {}, expect = nil },
    {
        'single',
        'SELECT 5 IN (SELECT xp FROM cp_officers) AS a, 99 IN (SELECT xp FROM cp_officers) AS b, 99 NOT IN (SELECT callsign FROM cp_officers) AS c, NULL IN (SELECT xp FROM cp_officers WHERE 1 = 0) AS d',
        {},
        expect = { a = 1, b = 0, d = 0 },
    },
    {
        'query',
        'SELECT (SELECT citizenid FROM cp_officers WHERE xp > 0) AS x',
        {},
        err = 'Subquery returns more than 1 row',
    },
    {
        'query',
        'SELECT id FROM cp_mission_runs WHERE citizenid = \'ABC1\' AND citizenid = \'abc1\' AND id = 1',
        {},
        expect = { { id = 1 } },
    },
    { 'query', 'SELECT citizenid FROM cp_officers, cp_badges', {}, unsupported = true },
    {
        'query',
        'SELECT citizenid FROM cp_officers o JOIN cp_badges b ON b.citizenid = o.citizenid',
        {},
        err = 'Column \'citizenid\' in SELECT is ambiguous',
    },
    { 'query', 'SELECT nope FROM cp_officers', {}, err = 'Unknown column \'nope\' in \'SELECT\'' },
    { 'query', 'SELECT * FROM cp_nowhere', {}, err = 'Table \'saves.cp_nowhere\' doesn\'t exist' },
    {
        'query',
        'SELECT s.citizenid, s.runs, s.points, o.display_name, o.hide_name FROM ( SELECT r.citizenid, SUM(CASE WHEN r.mission_type NOT IN (\'manual_award\', \'goal\') THEN 1 ELSE 0 END) AS runs, SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.final_points ELSE 0 END) AS points, UNIX_TIMESTAMP(MAX(r.created_at)) AS last_ts FROM cp_mission_runs r WHERE r.created_at >= FROM_UNIXTIME(?) GROUP BY r.citizenid ) s LEFT JOIN cp_officers o ON o.citizenid = s.citizenid ORDER BY s.points DESC, s.runs DESC, s.citizenid ASC',
        { 1789864000 },
        expect = {
            { citizenid = 'ABC1', runs = '2', points = '305', display_name = 'Zoë Été', hide_name = false },
            { citizenid = 'abd2', runs = '2', points = '195', display_name = 'bob', hide_name = false },
            { citizenid = 'LOW5', runs = '1', points = '150', display_name = 'adam', hide_name = false },
            { citizenid = 'XYZ3', runs = '1', points = '0', hide_name = false },
        },
    },
    {
        'query',
        'SELECT o.citizenid, o.xp AS points, COALESCE(s.runs, 0) AS runs, s.reached_ts, COALESCE(s.cash, 0) AS cash FROM cp_officers o LEFT JOIN ( SELECT u.citizenid, SUM(u.runs) AS runs, MAX(u.reached_ts) AS reached_ts, SUM(u.cash) AS cash FROM ( SELECT r.citizenid, SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = \'completed\' THEN 1 ELSE 0 END) AS runs, UNIX_TIMESTAMP(MAX(CASE WHEN r.voided = 0 AND r.final_points <> 0 THEN r.created_at END)) AS reached_ts, SUM(r.cash_paid) AS cash FROM cp_mission_runs r GROUP BY r.citizenid UNION ALL SELECT r.citizenid, SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = \'completed\' THEN 1 ELSE 0 END) AS runs, UNIX_TIMESTAMP(MAX(CASE WHEN r.voided = 0 AND r.final_points <> 0 THEN r.created_at END)) AS reached_ts, SUM(r.cash_paid) AS cash FROM cp_mission_runs_archive r GROUP BY r.citizenid ) u GROUP BY u.citizenid ) s ON s.citizenid = o.citizenid WHERE o.xp <> 0 OR s.runs > 0 ORDER BY o.citizenid',
        {},
        expect = {
            { citizenid = 'ABC1', points = 51, runs = '3', reached_ts = 1790116000, cash = '800' },
            { citizenid = 'abd2', points = 0, runs = '1', reached_ts = 1790008000, cash = '1150' },
            { citizenid = 'LOW5', points = 3, runs = '1', reached_ts = 1790080000, cash = '1170' },
            { citizenid = 'NEW6', points = 40, runs = '0', cash = '0' },
            { citizenid = 'NUL4', points = 5, runs = '0', cash = '0' },
            { citizenid = 'XYZ3', points = 1, runs = '1', cash = '0' },
        },
    },
    {
        'query',
        'SELECT s.citizenid, s.points, s.reached_ts, s.row_department FROM ( SELECT r.citizenid, SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.final_points ELSE 0 END) AS points, UNIX_TIMESTAMP(COALESCE( MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.final_points <> 0 THEN r.created_at END), MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.created_at END), MAX(r.created_at))) AS reached_ts, SUBSTRING_INDEX(GROUP_CONCAT(r.department ORDER BY r.created_at DESC, r.id DESC SEPARATOR \',\'), \',\', 1) AS row_department FROM cp_mission_runs r WHERE r.season_id = ? GROUP BY r.citizenid ) s LEFT JOIN cp_officers o ON o.citizenid = s.citizenid',
        { 2 },
        expect = {
            { citizenid = 'ABC1', points = '305', reached_ts = 1790116000, row_department = 'sast' },
            { citizenid = 'abd2', points = '195', reached_ts = 1790008000, row_department = 'fib' },
        },
    },
    {
        'single',
        'SELECT COUNT(*) AS runs, COALESCE(SUM(state = \'completed\'), 0) AS completed, COALESCE(SUM(flagged = 1), 0) AS flagged, COALESCE(SUM(cash_paid), 0) AS cash_total, COALESCE(SUM(CASE WHEN created_at >= FROM_UNIXTIME(?) THEN cash_paid ELSE 0 END), 0) AS cash_week FROM (SELECT state, flagged, voided, cash_paid, created_at FROM cp_mission_runs WHERE citizenid = ? AND mission_type NOT IN (\'manual_award\', \'goal\') UNION ALL SELECT state, flagged, voided, cash_paid, created_at FROM cp_mission_runs_archive WHERE citizenid = ? AND mission_type NOT IN (\'manual_award\', \'goal\')) t',
        { 1789900000, 'XYZ3', 'XYZ3' },
        expect = { runs = 2, completed = '1', flagged = '0', cash_total = '0', cash_week = '0' },
    },
    {
        'query',
        'SELECT t.id, t.mission_id, t.tier, t.testers, t.note, t.def_hash, last.n AS tests_n, o.display_name FROM cp_mission_tests t JOIN (SELECT MAX(id) AS id, COUNT(*) AS n FROM cp_mission_tests GROUP BY mission_id, location_index) last ON last.id = t.id LEFT JOIN cp_officers o ON o.citizenid = t.tested_by ORDER BY t.id',
        {},
        expect = {
            {
                id = 2,
                mission_id = 'm1',
                tier = 'heavy',
                testers = 1,
                note = 'x',
                def_hash = 'bb',
                tests_n = 2,
                display_name = 'Zoë Été',
            },
            { id = 3, mission_id = 'm2', tier = 'standard', testers = 1, note = 'ok', tests_n = 1 },
        },
    },
    {
        'query',
        'SELECT s.id, s.name, b.winner FROM cp_seasons s LEFT JOIN cp_dept_bounties b ON b.season_id = s.id AND b.week = ? WHERE s.ends_at IS NOT NULL ORDER BY s.id DESC LIMIT 1',
        { 1 },
        expect = { { id = 1, name = 'Season 1', winner = 'fib' } },
    },
    {
        'query',
        'SELECT b.season_id, b.week, b.objective, b.winner, s.name FROM cp_dept_bounties b JOIN cp_seasons s ON s.id = b.season_id WHERE b.week >= 1 ORDER BY b.season_id DESC, b.week DESC LIMIT ?',
        { 60 },
        expect = {
            { season_id = 2, week = 2, objective = 'most_tactical', name = 'Season 2' },
            { season_id = 2, week = 1, objective = 'most_runs', winner = 'sast', name = 'Season 2' },
            { season_id = 1, week = 1, objective = 'most_runs', winner = 'fib', name = 'Season 1' },
        },
    },
    {
        'query',
        'SELECT r.id, ROUND(r.cash_base * r.cash_multiplier) AS amount, r.cash_multiplier, o.display_name FROM cp_mission_runs r LEFT JOIN cp_officers o ON o.citizenid = r.citizenid WHERE r.cash_status IN (\'paying\', \'held\', \'paid\') ORDER BY r.created_at ASC LIMIT 200',
        {},
        expect = {
            { id = 1, amount = '800', cash_multiplier = '1.00', display_name = 'Zoë Été' },
            { id = 3, amount = '1150', cash_multiplier = '1.15', display_name = 'bob' },
            { id = 6, amount = '1170', cash_multiplier = '1.30', display_name = 'adam' },
        },
    },
    {
        'query',
        'SELECT a.id, a.actor, a.old_value, a.new_value, a.reason, UNIX_TIMESTAMP(a.created_at) AS created_ts, o.display_name FROM cp_audit a LEFT JOIN cp_officers o ON o.citizenid = a.actor WHERE 1 = 1 AND (a.actor LIKE ? OR o.display_name LIKE ?) ORDER BY a.created_at DESC, a.id DESC LIMIT 50 OFFSET 0',
        { '%c%', '%c%' },
        expect = {
            { id = 2, actor = 'console', new_value = 'speed', created_ts = 1789921600 },
            {
                id = 1,
                actor = 'ABC1',
                old_value = '250',
                new_value = '300',
                reason = 'why? 100%',
                created_ts = 1789914400,
                display_name = 'Zoë Été',
            },
        },
    },
    {
        'query',
        'SELECT mission_id, UNIX_TIMESTAMP(MAX(created_at)) AS last_ts, MAX(id) AS last_id FROM cp_mission_runs WHERE citizenid = ? AND mission_type = ? AND state IN (\'completed\', \'abandoned\') AND mission_id <> ? GROUP BY mission_id',
        { 'ABC1', 'patrol', 'x' },
        expect = { { mission_id = 'beat_patrol', last_ts = 1789903600, last_id = 1 } },
    },
    {
        'query',
        'SELECT hide_name FROM cp_officers WHERE citizenid = \'ABC1\' UNION ALL SELECT hide_name FROM cp_officers WHERE citizenid = \'ABC1\'',
        {},
        expect = { { hide_name = 0 }, { hide_name = 0 } },
    },
    {
        'query',
        'SELECT s.hide_name, COALESCE(s.hide_name, 0) AS c, IF(1, s.hide_name, 0) AS i FROM (SELECT hide_name FROM cp_officers WHERE citizenid = \'ABC1\') s',
        {},
        expect = { { hide_name = false, c = 0, i = 0 } },
    },
    {
        'query',
        'SELECT x FROM (SELECT NULL AS x UNION ALL SELECT \'b\' UNION ALL SELECT \'A\') t ORDER BY x',
        {},
        expect = { {}, { x = 'A' }, { x = 'b' } },
    },
    {
        'query',
        'SELECT x FROM (SELECT NULL AS x UNION ALL SELECT \'b\' UNION ALL SELECT \'A\') t ORDER BY x DESC',
        {},
        expect = { { x = 'b' }, { x = 'A' }, {} },
    },
    {
        'query',
        'SELECT x, y FROM (SELECT 1 AS x, 1.5 AS y UNION ALL SELECT 2.25, \'z\') t',
        {},
        expect = { { x = '1.00', y = '1.5' }, { x = '2.25', y = 'z' } },
    },
    {
        'query',
        'SELECT id, run_uuid, citizenid, department, flagged, voided, cash_multiplier, breakdown FROM cp_mission_runs WHERE run_uuid = ? ORDER BY id',
        { 'run-b' },
        expect = {
            {
                id = 2,
                run_uuid = 'run-b',
                citizenid = 'ABC1',
                department = 'sast',
                flagged = false,
                voided = false,
                cash_multiplier = '1.15',
                breakdown = '{"cash": {"status": "forfeited", "amount": 1150}, "points": {"bonuses": [{"id": "no_participant_downed"}]}, "flagged": null}',
            },
            {
                id = 3,
                run_uuid = 'run-b',
                citizenid = 'abd2',
                department = 'fib',
                flagged = false,
                voided = false,
                cash_multiplier = '1.15',
                breakdown = '{"cash":{"status":"held","amount":1150},"points":{"bonuses":[{"id":"no_participant_downed"}]},"flagged":{"reason":"speed"}}',
            },
        },
    },
    { 'update', 'DELETE FROM cp_badges WHERE citizenid = ? AND badge_id = ?', { 'ABC1', 'IRON_WHEELS' }, expect = 1 },
    { 'update', 'DELETE FROM cp_audit WHERE created_at < FROM_UNIXTIME(?)', { 1789925200 }, expect = 2 },
    {
        'query',
        'DELETE FROM cp_mission_tests',
        {},
        write = true,
        expect = { fieldCount = 0, affectedRows = 3, insertId = 0, changedRows = 0, info = '' },
    },
    { 'query', 'SELECT COUNT(*) AS n FROM cp_audit', {}, expect = { { n = 1 } } },
    {
        'query',
        'SELECT citizenid, badge_id FROM cp_badges ORDER BY citizenid, badge_id',
        {},
        expect = {
            { citizenid = 'ABC1', badge_id = 'officer_of_week_2026-09-14' },
            { citizenid = 'abd2', badge_id = 'iron_wheels' },
        },
    },
}
local BASE = 1790000000   -- case i runs at os.time() = BASE + i (MariaDB: SET timestamp = BASE + i)

local casesDir = TMP .. '/cases'
Mkdir(casesDir)
local db = M.new({ store = M.folderStore(casesDir) }):load()
Migrate(db)
local sh = M.shim(db, { resource = 'Crimson-Police' })
do
    local skipped = 0
    for i, c in ipairs(CASES) do
        H.time = BASE + i
        local label = ('case %d %s: %s'):format(i, c[1], (c[2]:gsub('%s+', ' ')):sub(1, 90))
        if c.tz and not IS_UTC then
            skipped = skipped + 1
        else
            local params = {}
            for j = 1, #c[3] do
                local p = c[3][j]
                if p ~= N then params[j] = p end
            end
            local ok, res = pcall(sh[c[1]].await, c[2], params)
            if c.unsupported then
                H.ok(not ok and tostring(res):find(M.unsupportedPrefix, 1, true) ~= nil,
                    label .. ' raises a clear "does not support" error: ' .. tostring(res))
            elseif c.err then
                H.ok(not ok, label .. ' fails')
                H.eq(LastLine(res), c.err, label .. ' error text')
            else
                if not ok then
                    H.ok(false, label .. ': ' .. tostring(res))
                else
                    local got = res
                    if c.write and type(res) == 'table' then
                        got = {
                            fieldCount = res.fieldCount,
                            affectedRows = res.affectedRows,
                            insertId = res.insertId,
                            changedRows = res.changedRows,
                            info = res.info,
                        }
                    end
                    if not H.ok(DeepEq(got, c.expect), label) then
                        print('    expected ' .. Show(c.expect))
                        print('    got      ' .. Show(got))
                    end
                end
            end
        end
    end
    if skipped > 0 then print(('  (%d time zone cases skipped: the server zone is not UTC)'):format(skipped)) end
end

-- ============================================================================
-- 1b. STORING VALUES AND TYPING, AS MariaDB 10.11 + OXMYSQL ANSWERED (tests/shadow/fuzz_store.lua and
-- ============================================================================
--        fuzz_funcs.lua compare the whole grid in shadow mode) ──
do
    local sdb = M.new()
    local ssh = M.shim(sdb, { resource = 'Crimson-Police' })
    sdb:exec([[CREATE TABLE cp_s (id INT AUTO_INCREMENT PRIMARY KEY, i INT NULL, ti TINYINT NULL, d DECIMAL(6,2) NULL,
        t5 VARCHAR(5) NULL, e ENUM('none','held','paid') NOT NULL DEFAULT 'none', dt DATETIME NULL, dd DATE NULL, j JSON NULL)]])
    local function W(sql) local r = ssh.query.await(sql); return r.warningStatus, r end
    local function One(sql) return ssh.scalar.await(sql) end
    local function Err(sql) local ok, e = pcall(ssh.query.await, sql); return not ok and LastLine(e) or 'no error' end
    H.eq(W('INSERT INTO cp_s (i) VALUES (\' 7 \')'), 1, 'store: trailing spaces after a number are a note')
    H.eq(Err('INSERT INTO cp_s (i) VALUES (\'7x\')'), 'Data truncated for column \'i\' at row 1',
        'store: text after a number is an error')
    H.eq(Err('INSERT INTO cp_s (i) VALUES (\'x\')'),
        'Incorrect integer value: \'x\' for column `saves`.`cp_s`.`i` at row 1', 'store: no number')
    H.eq(Err('INSERT INTO cp_s (ti) VALUES (\'2026-09-01\')'), 'Out of range value for column \'ti\' at row 1',
        'store: out of range comes first')
    H.eq(W('INSERT IGNORE INTO cp_s (i, ti) VALUES (\'x\', 300)'), 2, 'store: IGNORE turns both into warnings')
    H.eq(W('INSERT INTO cp_s (d) VALUES (\'1.234\')'), 1, 'store: decimals rounded away are a note')
    H.eq(One('SELECT d FROM cp_s WHERE d IS NOT NULL'), '1.23', 'store: and are rounded')
    H.eq(Err('INSERT INTO cp_s (t5) VALUES (\'toolong\')'), 'Data too long for column \'t5\' at row 1',
        'store: too long text')
    H.eq(W('INSERT INTO cp_s (t5) VALUES (\'ab      \')'), 1, 'store: only spaces cut off is a note')
    sdb:exec('DELETE FROM cp_s')
    sdb:exec('INSERT INTO cp_s (e) VALUES (2.5), (\'-0\'), (\' 3\')')
    H.ok(DeepEq(ssh.query.await('SELECT e FROM cp_s ORDER BY id'), { { e = 'held' }, { e = '' }, { e = 'paid' } }),
        'store: ENUM member numbers')
    H.ok(DeepEq(
        ssh.query.await('SELECT e + 0 AS n, e < 2 AS lt FROM cp_s ORDER BY id'),
        { { n = 2, lt = 0 }, { n = 0, lt = 1 }, { n = 3, lt = 0 } }
    ), 'an ENUM is its member number in number contexts')
    H.ok(DeepEq(ssh.query.await('SELECT e FROM cp_s ORDER BY e DESC'), { { e = 'paid' }, { e = 'held' }, { e = '' } }),
        'and ORDER BY sorts by it')
    sdb:exec('DELETE FROM cp_s')
    H.eq(W('INSERT INTO cp_s (dd, dt) VALUES (\'2026-09-01 10:00\', \'26-09-01 10\')'), 1,
        'store: the time of a DATE is dropped with a note')
    H.eq(One('SELECT UNIX_TIMESTAMP(dt) - UNIX_TIMESTAMP(dd) AS s FROM cp_s'), 36000, 'store: \'26-09-01 10\' is 10:00')
    H.ok(Err('INSERT INTO cp_s (dt) VALUES (\'0000-00-00\')'):find(M.unsupportedPrefix, 1, true) == 1,
        'store: a zero date is refused')
    H.eq(Err('INSERT INTO cp_s (dt) VALUES (\'2026-02-30\')'),
        'Incorrect datetime value: \'2026-02-30\' for column `saves`.`cp_s`.`dt` at row 1', 'store: a bad date')
    H.eq(Err('INSERT IGNORE INTO cp_s (j) VALUES (\'bad\')'), 'CONSTRAINT `cp_s.j` failed for `saves`.`cp_s`',
        'CHECK: a one-row INSERT fails even with IGNORE')
    local _, r = W('INSERT IGNORE INTO cp_s (j) VALUES (\'bad\'), (\'[5.]\')')
    H.ok(DeepEq({ r.affectedRows, r.info }, { 1, 'Records: 1  Duplicates: 0  Warnings: 1' }),
        'CHECK: IGNORE leaves the bad row out (and 5. is JSON to MariaDB)')
    local _, u = W('UPDATE IGNORE cp_s SET j = \'bad\' WHERE j IS NOT NULL')
    H.eq(u.info, 'Rows matched: 0  Changed: 0  Warnings: 1',
        'CHECK: an UPDATE IGNORE row that fails is not even matched')
    H.eq(One('SELECT GREATEST(1, \'7\')'), 7, 'GREATEST of a number and a text is a DOUBLE')
    H.eq(One('SELECT JSON_SET(\'{"a":1}\', \'$.b\', 1 = 1, \'$.a[1]\', TRUE)'), '{"a": [1, true], "b": true}',
        'JSON_SET: booleans, and [1] wraps a value in an array')
    H.eq(One('SELECT LOWER(1e-5)'), '0.00001', 'a DOUBLE as text is MariaDB\'s')
    H.eq(One('SELECT 1e2 + 1'), 101, 'a whole DOUBLE reaches Lua as an integer')
    H.eq(math.type(One('SELECT 1e2 + 1')), 'integer', 'of type integer')
    H.eq(One('SELECT 2147483647 * 2147483647 * 2'), '9223372028264841218', 'a BIGINT beyond 2^53 is text')
end

-- ============================================================================
--                       2. PERSISTENCE ACROSS A RESTART
-- ============================================================================

do
    local db2 = M.new({ store = M.folderStore(casesDir) }):load()
    SameTables(db, db2, 'restart: a new engine on the same saves folder has identical tables and counters')
    local nextRun = db.tables.cp_mission_runs.nextId
    local sh2 = M.shim(db2)
    H.eq(sh2.insert.await(
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (\'after-restart\', \'patrol\', \'beat_patrol\', \'ABC1\', \'sast\', \'completed\', \'completed\', 60)'
    ), nextRun, 'AUTO_INCREMENT continues after a restart')
    local nextTypes = db.tables.cp_t_types.nextId
    H.eq(sh2.insert.await('INSERT INTO cp_t_types (e2) VALUES (\'x\')'), nextTypes,
        'ids used by deleted rows are not handed out again')
    -- ids a failing statement took stay taken (InnoDB), also for a new engine on the same saves folder
    local taken = db2.tables.cp_t_types.nextId
    H.ok(not pcall(sh2.query.await, 'INSERT INTO cp_t_types (vc, e2) VALUES (\'ok1\', \'x\'), (\'ok2\', \'zz\')'),
        'a two-row INSERT that fails')
    H.eq(db2.tables.cp_t_types.nextId, taken + 2, 'keeps the two ids it took')
    local db3 = M.new({ store = M.folderStore(casesDir) }):load()
    H.eq(db3.tables.cp_t_types.nextId, taken + 2, 'and so does a new engine on the same saves folder')
    H.eq(#Leftovers(casesDir), 0, 'no .tmp or .bak file is left behind')
end

-- ============================================================================
--                          3. THE SAVES FOLDER LAYOUT
-- ============================================================================

do
    local files = ListDir(casesDir)
    local want = {
        '_tables.json',
        'audit.json',
        'badges.json',
        'custom_missions.json',
        'dept_bounties.json',
        'disputes.json',
        'mission_payouts.json',
        'mission_runs.json',
        'mission_runs_archive.json',
        'mission_tests.json',
        'officers.json',
        'operations.json',
        'seasons.json',
        't_copy.json',
        't_types.json',
        't_uniq.json',
        'type_payouts.json',
    }
    H.eq(table.concat(files, ' '), table.concat(want, ' '),
        'one document per table, named without cp_, plus _tables.json')
    H.eq(ReadFile(casesDir .. '/t_uniq.json'),
        '{"table":"cp_t_uniq","columns":["id","a","b","n"],"rows":[\n[1,"x",1,7],\n[6,"x",2,0],\n[10,"y",1,7]\n]}\n',
        'a document: column names once, then one row per line')
    local runs = ReadFile(casesDir .. '/mission_runs.json')
    local line1 = runs:match('\n(%[1,[^\n]*)')
    H.ok(
        line1 ~= nil and line1:find(',{"cash": {"status": "none", "amount": 800, "paid": 0}', 1, true) ~= nil
            and not line1:find('"{\\"cash', 1, true),
        'a JSON column is embedded as JSON (here as MariaDB formats JSON_SET output): ' .. tostring(line1)
    )
    H.ok(line1:find(',' .. tostring(1789900000 + 3600) .. '%]') ~= nil, 'DATETIME is stored as unix seconds')
    H.ok(line1:find(',1.00,', 1, true) ~= nil, 'DECIMAL keeps its decimals')
    local line6 = runs:match('\n(%[6,[^\n]*)')
    H.ok(line6 ~= nil and line6:find(',[],', 1, true) ~= nil, 'an empty JSON array is embedded too')
    local officers = ReadFile(casesDir .. '/officers.json')
    H.ok(officers:find('["XYZ3",null,"Trooper",null,"sast",1,0,null,null,0,0,null]', 1, true) ~= nil,
        'NULL is null and TINYINT(1) is 0/1: ' .. (officers:match('\n(%["XYZ3"[^\n]*)') or '?'))
    H.ok(officers:find('"007"', 1, true) ~= nil and officers:find('"12"', 1, true) ~= nil,
        'numeric-looking text stays text')
    local tables = M.jparse(ReadFile(casesDir .. '/_tables.json'))
    H.ok(tables ~= nil, '_tables.json is valid JSON')
    local meta = cjson.decode(ReadFile(casesDir .. '/_tables.json'))
    local names = {}
    for _, e in ipairs(meta.tables) do names[#names + 1] = e.name end
    H.eq(#names, 17, '_tables.json lists every table')
    H.eq(meta.migrations and #meta.migrations.rows, 2,
        '_tables.json holds the applied migrations (cp_schema_migrations)')
    H.ok(not Exists(casesDir .. '/schema_migrations.json'), 'the migrations have no document of their own')
    local runsEntry
    for _, e in ipairs(meta.tables) do if e.name == 'cp_mission_runs' then runsEntry = e end end
    H.ok(runsEntry and runsEntry.sql:find('^CREATE TABLE cp_mission_runs %(id INT NOT NULL AUTO_INCREMENT') ~= nil,
        'each layout is a CREATE TABLE statement')
    H.ok(runsEntry and runsEntry.sql:find('KEY idx_board (created_at, citizenid, voided)', 1, true) ~= nil,
        'with its keys')
    -- the stored text reads back exactly, also for JSON the parser could not embed
    local odd = M.new({ store = M.folderStore(TMP .. '/odd') })
    Mkdir(TMP .. '/odd')
    odd:load()
    odd:exec('CREATE TABLE cp_odd (id INT PRIMARY KEY, a JSON NULL, b JSON NULL, s VARCHAR(40) NULL)')
    local texts = {
        { 1, '{ "spaced" : [1, 2] ,"k":"v"}', '[{"x":"a\\u00e9\\n"}]', 'tab\there "quoted" \\ back' },
        { 2, '"just a string"', '{"multi":\n"line"}', 'é€😀' },
        { 3, '  {"lead":1}', '{"b":[1,{"c":{}}],"a":null}', '' },
        { 4, '5', '{"x":1}', nil },
    }
    for _, r in ipairs(texts) do odd:exec('INSERT INTO cp_odd (id, a, b, s) VALUES (?, ?, ?, ?)', r) end
    local back = M.new({ store = M.folderStore(TMP .. '/odd') }):load()
    SameTables(odd, back, 'every JSON and text value reads back byte for byte (embedded or as a string)')
    local oddText = ReadFile(TMP .. '/odd/odd.json')
    H.ok(oddText:find('[3,"  {\\"lead\\":1}",{"b":[1,{"c":{}}],"a":null},""]', 1, true) ~= nil,
        'JSON that is not a one-line object or array is kept as a string')
end

-- ============================================================================
--                     4. SPLIT DOCUMENTS AND WRITE-THROUGH
-- ============================================================================

local realFs = {}
for k, v in pairs(M.fs) do realFs[k] = v end
local function RestoreFs() for k, v in pairs(realFs) do M.fs[k] = v end end
local function RecordWrites()
    local list = {}
    M.fs.write = function(path, data)
        list[#list + 1] = path:match('([^/]+)$')
        return realFs.write(path, data)
    end
    return list
end
local function Written(list)
    local out = {}
    for _, p in ipairs(list) do if not p:match('%.cp%-write%-test$') then out[#out + 1] = (p:gsub('%.tmp$', '')) end end
    table.sort(out)
    return table.concat(out, ' ')
end

do
    local dir = TMP .. '/split'
    Mkdir(dir)
    local st = M.folderStore(dir, { docRows = 5 })
    local d = M.new({ store = st }):load()
    d:exec(
        'CREATE TABLE cp_runs_t (id INT AUTO_INCREMENT PRIMARY KEY, who VARCHAR(20) NOT NULL, n INT NOT NULL DEFAULT 0)')
    for i = 1, 5 do d:exec('INSERT INTO cp_runs_t (who) VALUES (?)', { 'w' .. i }) end
    H.eq(table.concat(ListDir(dir), ' '), '_tables.json runs_t.json', 'up to 5 rows: one document')
    local w = RecordWrites()
    d:exec('INSERT INTO cp_runs_t (who) VALUES (?)', { 'w6' })
    RestoreFs()
    H.eq(table.concat(ListDir(dir), ' '), '_tables.json runs_t_1.json runs_t_2.json',
        'past 5 rows the table splits by id range')
    H.eq(Written(w), '_tables.json runs_t_1.json runs_t_2.json',
        'the split writes the new documents, then _tables.json')
    for i = 7, 12 do d:exec('INSERT INTO cp_runs_t (who) VALUES (?)', { 'w' .. i }) end
    H.eq(table.concat(ListDir(dir), ' '), '_tables.json runs_t_1.json runs_t_2.json runs_t_3.json',
        'ids 11-12 open a third document')
    w = RecordWrites()
    d:exec('UPDATE cp_runs_t SET n = n + 1 WHERE id = ?', { 7 })
    RestoreFs()
    H.eq(Written(w), 'runs_t_2.json', 'an update rewrites only the document holding the row')
    w = RecordWrites()
    d:exec('INSERT INTO cp_runs_t (who) VALUES (?)', { 'w13' })
    RestoreFs()
    H.eq(Written(w), 'runs_t_3.json',
        'an insert rewrites only the newest document (the next id is known from the rows)')
    w = RecordWrites()
    d:exec('SELECT * FROM cp_runs_t WHERE id > 3')
    d:exec('UPDATE cp_runs_t SET n = n WHERE id = 2')
    RestoreFs()
    H.eq(Written(w), '', 'reads and updates that change nothing write nothing')
    H.eq(#ReadFile(dir .. '/runs_t_1.json'):gsub('[^\n]', ''), 7, 'a document holds its 5 rows, one per line')
    w = RecordWrites()
    d:exec('DELETE FROM cp_runs_t WHERE id <= 5')
    RestoreFs()
    H.eq(table.concat(ListDir(dir), ' '), '_tables.json runs_t_2.json runs_t_3.json',
        'a document that becomes empty is removed')
    H.eq(Written(w), '', 'removing an emptied document writes nothing else')
    w = RecordWrites()
    d:exec('DELETE FROM cp_runs_t WHERE id = 13')
    RestoreFs()
    H.eq(Written(w), '_tables.json runs_t_3.json',
        'deleting the newest row saves the next id in _tables.json (first) and the document')
    d:exec('DELETE FROM cp_runs_t')
    H.eq(table.concat(ListDir(dir), ' '), '_tables.json runs_t_3.json', 'the last document of a table stays, empty')
    H.eq(ReadFile(dir .. '/runs_t_3.json'), '{"table":"cp_runs_t","columns":["id","who","n"],"rows":[\n]}\n',
        'an empty document')
    H.eq(d:exec('INSERT INTO cp_runs_t (who) VALUES (\'again\')').insertId, 14,
        'ids keep counting after every row is gone')
    local again = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    SameTables(d, again, 'split range documents load back')
    H.eq(again:exec('INSERT INTO cp_runs_t (who) VALUES (\'after\')').insertId, 15,
        'and the counter survives the restart')
    d = again   -- one engine per folder from here on

    -- text keys: a stable hash bucket per key (linear hashing, one bucket splits per statement)
    d:exec('CREATE TABLE cp_names_t (name VARCHAR(20) PRIMARY KEY, n INT NOT NULL)')
    local maxWrites = 0
    for i = 1, 40 do
        w = RecordWrites()
        d:exec('INSERT INTO cp_names_t (name, n) VALUES (?, ?)', { ('Name%02d'):format(i), i })
        RestoreFs()
        local docs = 0
        for _, p in ipairs(w) do if p:find('^names_t') then docs = docs + 1 end end
        if docs > maxWrites then maxWrites = docs end
    end
    H.eq(maxWrites, 3,
        'an insert that splits a bucket rewrites the row\'s own bucket, the split bucket and its new sibling')
    local docs, biggest, total = 0, 0, 0
    for _, name in ipairs(ListDir(dir)) do
        if name:match('^names_t_%d+%.json$') then
            docs = docs + 1
            local rows = select(2, ReadFile(dir .. '/' .. name):gsub('\n%[', ''))
            total = total + rows
            if rows > biggest then biggest = rows end
        end
    end
    H.ok(docs >= 8, 'forty text keys spread over numbered documents (' .. docs .. ')')
    H.eq(total, 40, 'every key is in exactly one document')
    H.ok(biggest <= 10, 'no document grows far past the limit (' .. biggest .. ' rows)')
    H.eq(d:exec('SELECT COUNT(*) AS n FROM cp_names_t WHERE name = \'NAME07\'').rows[1][1], 1,
        'keys still compare case-insensitively')
    d:exec('UPDATE cp_names_t SET n = 0 WHERE name = \'name07\'')
    local hashed = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    SameTables(d, hashed, 'hash buckets load back')
    w = RecordWrites()
    hashed:exec('UPDATE cp_names_t SET n = n + 1 WHERE name = \'Name33\'')
    RestoreFs()
    local one = Written(w)
    H.ok(one:match('^names_t_%d+%.json$') ~= nil,
        'after a restart a change still rewrites just its bucket (' .. one .. ')')
    H.eq(#Leftovers(dir), 0, 'no .tmp or .bak left')
end

-- ============================================================================
--                               5. CRASH SAFETY
-- ============================================================================
-- Stop the process at every file operation of a save.

local CRASH = setmetatable({}, {
    __tostring = function() return 'simulated crash' end,
})
local function Snapshot(d)
    local out = {}
    for _, t in ipairs(d.order) do
        local rows = {}
        for _, r in ipairs(t.rows) do
            local vals = {}
            for c = 1, t.ncols do vals[c] = r[c] == nil and '\1' or tostring(r[c]) end
            rows[tostring(r[t.pk and t.pk[1] or 1])] = table.concat(vals, '\0')
        end
        out[t.name] = { rows = rows, nextId = t.autoCol and t.nextId or nil, ncols = t.ncols }
    end
    return out
end
-- windows = true: a rename cannot replace an existing file (the .bak sequence runs). After the crash the process is
-- gone: no file operation happens any more.
local function WithFs(windows, crashAt)
    local n = 0
    local dead = false
    local function hit()
        if dead then error(CRASH, 0) end
        n = n + 1
        if crashAt ~= nil and n == crashAt then dead = true; return true end
        return false
    end
    M.fs.write = function(p, data)
        if hit() then
            -- the crash hits in the middle of this write: half a file
            local f = io.open(p, 'wb')
            f:write(data:sub(1, #data // 2))
            f:close()
            error(CRASH, 0)
        end
        return realFs.write(p, data)
    end
    M.fs.rename = function(a, b)
        if hit() then error(CRASH, 0) end
        if windows and realFs.exists(b) then return nil, 'file exists' end
        return realFs.rename(a, b)
    end
    M.fs.remove = function(p)
        if hit() then error(CRASH, 0) end
        return realFs.remove(p)
    end
    M.fs.exists = function(p)
        if dead then error(CRASH, 0) end
        return realFs.exists(p)
    end
    return function() return n end
end

local SCENARIOS = {
    {
        'an update of one row',
        function(d) d:exec('UPDATE cp_crash_t SET n = n + 1 WHERE id = 2') end,
    },
    {
        'the insert that splits a table into id ranges',
        function(d) d:exec('INSERT INTO cp_crash_t (who) VALUES (\'sixth\')') end,
        rows = 5,
    },
    {
        'an insert opening a new range document',
        function(d) d:exec('INSERT INTO cp_crash_t (who) VALUES (\'eleventh\')') end,
        rows = 10,
    },
    {
        'deleting the newest row (the counter must survive)',
        function(d) d:exec('DELETE FROM cp_crash_t WHERE id = 4') end,
        rows = 4,
    },
    {
        'a hash bucket split',
        function(d) d:exec('INSERT INTO cp_crash_k (k) VALUES (\'k06\')') end,
        keys = 5,
    },
    {
        'a migration row (kept in _tables.json)',
        function(d) d:exec('INSERT INTO cp_schema_migrations (version, name) VALUES (3, \'003_x.sql\')') end,
    },
    {
        'ALTER TABLE ADD COLUMN',
        function(d) d:exec('ALTER TABLE cp_crash_t ADD COLUMN extra INT NOT NULL DEFAULT 7') end,
        rows = 7,
    },
    {
        'a statement touching two tables of one save',
        function(d)
            d:exec('INSERT INTO cp_crash_t (who) SELECT k FROM cp_crash_k WHERE k = \'k01\'')
        end,
        keys = 2,
    },
}

-- Key changes that move rows between hash buckets (the builder's rename of a draft in a split
-- cp_custom_missions): the moved rows are marked by v, and at least one copy of each must survive.
local function DocOfKey(d, key) return d.store:_docOf(d.store.ts.cp_crash_k, { key }) end
local function MoveKeys(d, want)
    -- existing keys and new keys: the first of want = 'up' moves to a higher document, 'swap' two rows
    -- between two documents (each into the other's)
    local keys = {}
    for i = 1, 12 do keys[i] = ('k%02d'):format(i) end
    for _, a in ipairs(keys) do
        local da = DocOfKey(d, a)
        for _, b in ipairs(keys) do
            local db = DocOfKey(d, b)
            if a ~= b and db > da then
                local toB, toA
                for i = 100, 999 do
                    local key = 'x' .. i
                    local dk = DocOfKey(d, key)
                    if not toB and dk == db then toB = key elseif not toA and dk == da then toA = key end
                    if toB and toA then break end
                end
                if want == 'up' then return a, toB end
                return a, b, toB, toA
            end
        end
    end
end
SCENARIOS[#SCENARIOS + 1] = {
    'a key change moving a row to a later hash bucket',
    function(d)
        local a, newKey = MoveKeys(d, 'up')
        d:exec('UPDATE cp_crash_k SET k = ? WHERE k = ?', { newKey, a })
    end,
    keys = 12,
    setup = function(d)
        local a = MoveKeys(d, 'up')
        d:exec('UPDATE cp_crash_k SET v = 777 WHERE k = ?', { a })
    end,
    keep = { 777 },
}
SCENARIOS[#SCENARIOS + 1] = {
    'two rows swapping hash buckets in one statement',
    function(d)
        local a, b, toB, toA = MoveKeys(d, 'swap')
        d:exec('UPDATE cp_crash_k SET k = CASE WHEN k = ? THEN ? ELSE ? END WHERE k IN (?, ?)', { a, toB, toA, a, b })
    end,
    keys = 12,
    setup = function(d)
        local a, b = MoveKeys(d, 'swap')
        d:exec('UPDATE cp_crash_k SET v = 701 WHERE k = ?', { a })
        d:exec('UPDATE cp_crash_k SET v = 702 WHERE k = ?', { b })
    end,
    keep = { 701, 702 },
}

local function Prepare(dir, sc)
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    d:exec(
        'CREATE TABLE cp_schema_migrations (version INT PRIMARY KEY, name VARCHAR(100) NOT NULL, applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)')
    d:exec('INSERT INTO cp_schema_migrations (version, name) VALUES (1, \'001_initial.sql\')')
    d:exec(
        'CREATE TABLE cp_crash_t (id INT AUTO_INCREMENT PRIMARY KEY, who VARCHAR(20) NOT NULL, n INT NOT NULL DEFAULT 0)')
    d:exec('CREATE TABLE cp_crash_k (k VARCHAR(10) PRIMARY KEY, v INT NOT NULL DEFAULT 0)')
    for i = 1, (sc.rows or 3) do d:exec('INSERT INTO cp_crash_t (who) VALUES (?)', { 'w' .. i }) end
    for i = 1, (sc.keys or 1) do d:exec('INSERT INTO cp_crash_k (k) VALUES (?)', { ('k%02d'):format(i) }) end
    if sc.setup then sc.setup(d) end
    return d
end

-- the marked rows (v) of a scenario that moves keys: at least one copy of each is in the folder
local function Kept(sc, snap)
    local missing = {}
    for _, mark in ipairs(sc.keep or {}) do
        local found = false
        for _, val in pairs(snap.cp_crash_k.rows) do
            if val:sub(-(#tostring(mark) + 1)) == '\0' .. mark then found = true end
        end
        if not found then missing[#missing + 1] = mark end
    end
    return missing
end

local function CrashSuite(windowsModes)
    local runs, problems = 0, {}
    local realPrint = print
    _G.print = function(...)   -- the loader's warnings about half-applied ALTERs are expected here
        local line = table.concat({ ... }, ' ')
        if not line:find('that the table no longer has', 1, true) then realPrint(line) end
    end
    for _, windows in ipairs(windowsModes) do
        for _, sc in ipairs(SCENARIOS) do
            local dir = TMP .. '/crash'
            -- how many file operations the save of this statement takes
            local base = Prepare(dir, sc)
            local count = WithFs(windows, nil)
            local before = Snapshot(base)
            sc[2](base)
            local ops = count()
            RestoreFs()
            local after = Snapshot(base)
            for crashAt = 1, ops do
                runs = runs + 1
                local d = Prepare(dir, sc)
                WithFs(windows, crashAt)
                local ok, err = pcall(sc[2], d)
                RestoreFs()
                local where = ('%s%s, crash at file operation %d of %d'):format(sc[1],
                    windows and ' (Windows rename rules)' or '', crashAt, ops)
                if ok then problems[#problems + 1] = where .. ': the statement did not stop' end
                local _ = err
                -- the process is gone: start again from the folder
                local okLoad, back = pcall(function()
                    return M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
                end)
                if not okLoad then
                    problems[#problems + 1] = where .. ': the folder does not load: ' .. tostring(back)
                else
                    local now = Snapshot(back)
                    for tname, bt in pairs(before) do
                        local at, nt = after[tname], now[tname]
                        if not nt then
                            problems[#problems + 1] = where .. ': table ' .. tname .. ' lost'
                        else
                            for key, val in pairs(bt.rows) do
                                local cur = nt.rows[key]
                                if cur ~= val and cur ~= (at and at.rows[key]) then
                                    -- ALTER: an old row may come back with the new column filled in
                                    if not (at and at.ncols > bt.ncols and cur and cur:sub(1, #val) == val) then
                                        problems[#problems + 1] = ('%s: %s row %s lost or changed'):format(where, tname,
                                            key)
                                    end
                                end
                            end
                            for key, val in pairs(nt.rows) do
                                if not bt.rows[key] and not (at and at.rows[key] == val) then
                                    problems[#problems + 1] = ('%s: %s has a row %s nobody wrote'):format(where, tname,
                                        key)
                                end
                            end
                            if bt.nextId and nt.nextId < bt.nextId then
                                problems[#problems + 1] = ('%s: %s next id went back from %d to %d'):format(where,
                                    tname, bt.nextId, nt.nextId)
                            end
                            local maxKey = 0
                            for key in pairs(nt.rows) do
                                local k = tonumber(key)
                                if k and k > maxKey then maxKey = k end
                            end
                            if bt.nextId and nt.nextId <= maxKey then
                                problems[#problems + 1] = ('%s: %s would hand out id %d again'):format(where, tname,
                                    nt.nextId)
                            end
                        end
                    end
                    local lost = Kept(sc, now)
                    if #lost > 0 then
                        problems[#problems + 1] = where .. ': the moved row ' .. table.concat(lost, ' ') .. ' is gone'
                    end
                    local left = Leftovers(dir)
                    if #left > 0 then problems[#problems + 1] = where .. ': left behind ' .. table.concat(left, ' ') end
                    -- and the folder keeps working
                    local okW, errW = pcall(back.exec, back, 'INSERT INTO cp_crash_t (who) VALUES (\'later\')')
                    if not okW then
                        problems[#problems + 1] = where .. ': cannot write afterwards: ' .. tostring(errW)
                    end
                end
            end
        end
    end
    _G.print = realPrint
    return runs, problems
end

do
    local runs, problems = CrashSuite({ false, true })
    H.ok(runs > 60, 'crash points tried: ' .. runs)
    if os.getenv('MEMSQL_VERBOSE') then print('  crash points tried: ' .. runs) end
    H.eq(
        #problems,
        0,
        'every crash point: nothing already saved is lost (a row whose key moves is never in neither document), no id is reused, nothing is left behind'
            .. (#problems > 0 and (': ' .. table.concat(problems, ' | ', 1, math.min(#problems, 6))) or '')
    )
end

do
    -- the states a crash leaves behind, one by one
    local dir = TMP .. '/states'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    d:exec('CREATE TABLE cp_s_t (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(10) NOT NULL)')
    d:exec('INSERT INTO cp_s_t (v) VALUES (\'one\'), (\'two\')')
    local doc = dir .. '/s_t.json'
    local good = ReadFile(doc)
    WriteFile(doc .. '.tmp', good:sub(1, 20))
    local l1 = M.new({ store = M.folderStore(dir) }):load()
    H.eq(#l1.tables.cp_s_t.rows, 2, 'a leftover .tmp is ignored')
    H.ok(not Exists(doc .. '.tmp'), 'and removed')
    os.rename(doc, doc .. '.bak')
    WriteFile(doc .. '.tmp', good)
    local l2 = M.new({ store = M.folderStore(dir) }):load()
    H.eq(#l2.tables.cp_s_t.rows, 2, 'a .bak without its document is restored')
    H.ok(Exists(doc) and not Exists(doc .. '.bak') and not Exists(doc .. '.tmp'),
        'the document is back, nothing left over')
    WriteFile(doc .. '.bak', 'stale')
    local l3 = M.new({ store = M.folderStore(dir) }):load()
    H.eq(#l3.tables.cp_s_t.rows, 2, 'a .bak next to its document is the old copy and is dropped')
    H.ok(not Exists(doc .. '.bak'), 'removed')
    -- a document written, _tables.json not: the rows are found and their ids are never handed out again
    local meta = ReadFile(dir .. '/_tables.json')
    l3:exec('INSERT INTO cp_s_t (id, v) VALUES (40, \'forty\')')
    WriteFile(dir .. '/_tables.json', meta)
    local l4 = M.new({ store = M.folderStore(dir) }):load()
    H.eq(#l4.tables.cp_s_t.rows, 3, 'a row saved in its document before _tables.json is kept')
    H.eq(l4:exec('INSERT INTO cp_s_t (v) VALUES (\'next\')').insertId, 41, 'and the next id comes after it')
    -- a damaged document stops the start instead of losing data
    WriteFile(doc, '{"table":"cp_s_t","columns":["id","v"],"rows":[\n[1,"one"],\n[2,"tw\n]}\n')
    local okBad, errBad = pcall(function() return M.new({ store = M.folderStore(dir) }):load() end)
    H.ok(not okBad and tostring(errBad):find('saves/s_t.json', 1, true) ~= nil,
        'a damaged document is reported by name: ' .. tostring(errBad))
    H.eq(ReadFile(doc):sub(1, 10), '{"table":"', 'and left untouched')
    -- documents without _tables.json are never overwritten by a fresh start
    os.remove(dir .. '/_tables.json')
    WriteFile(doc, good)
    local fresh = M.new({ store = M.folderStore(dir) }):load()
    local okNew, errNew = pcall(fresh.exec, fresh,
        'CREATE TABLE cp_s_t (id INT AUTO_INCREMENT PRIMARY KEY, v VARCHAR(10) NOT NULL)')
    H.ok(not okNew and tostring(errNew):find('_tables.json', 1, true) ~= nil,
        'a document without _tables.json is not overwritten: ' .. tostring(errNew))
    H.eq(ReadFile(doc), good, 'the document is untouched')
end

-- ============================================================================
--                                 6. ATOMICITY
-- ============================================================================

do
    local dir = TMP .. '/atomic'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    d:exec(
        'CREATE TABLE cp_a_t (id INT AUTO_INCREMENT PRIMARY KEY, code VARCHAR(4) NOT NULL, n INT NOT NULL DEFAULT 0, UNIQUE KEY uq_code (code))')
    d:exec('INSERT INTO cp_a_t (code) VALUES (\'a\'), (\'b\')')
    local before = ReadFile(dir .. '/a_t.json')
    local w = RecordWrites()
    local ok, err = pcall(d.exec, d, 'INSERT INTO cp_a_t (code) VALUES (\'c\'), (\'toolong\')')
    RestoreFs()
    H.ok(not ok and tostring(err):find('Data too long', 1, true) ~= nil, 'a failing second row fails the statement')
    H.eq(#d.tables.cp_a_t.rows, 2, 'and the first row of it is not kept')
    H.eq(Written(w), '_tables.json',
        'no document is written (only _tables.json: the AUTO_INCREMENT ids the statement took stay taken)')
    ok = pcall(d.exec, d, 'UPDATE cp_a_t SET code = \'b\', n = 5 WHERE id >= 1')
    H.ok(not ok, 'an update that collides on a UNIQUE key fails')
    H.eq(d:exec('SELECT code, n FROM cp_a_t WHERE id = 1').rows[1][1], 'a', 'the row it changed first is changed back')
    H.eq(d:exec('SELECT COUNT(*) FROM cp_a_t WHERE n = 5').rows[1][1], 0, 'no partial update')
    H.eq(ReadFile(dir .. '/a_t.json'), before, 'the document is as it was')
    -- a disk that refuses the write: the change is undone, reported, and saved later
    M.fs.write = function(p, data)
        if p:find('a_t.json.tmp', 1, true) then return nil, 'disk full' end
        return realFs.write(p, data)
    end
    local okW, errW = pcall(d.exec, d, 'UPDATE cp_a_t SET n = 9 WHERE code = \'a\'')
    RestoreFs()
    H.ok(not okW and tostring(errW):find('could not write to the saves folder', 1, true) ~= nil,
        'a failed save fails the statement: ' .. tostring(errW))
    H.eq(d:exec('SELECT n FROM cp_a_t WHERE code = \'a\'').rows[1][1], 0, 'and the change is undone in memory')
    d:exec('UPDATE cp_a_t SET n = 3 WHERE code = \'b\'')
    local reread = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, reread, 'the next save writes everything again')
    -- unique keys, case-insensitive like the column collation
    H.ok(not pcall(d.exec, d, 'INSERT INTO cp_a_t (code) VALUES (\'A \')'),
        'UNIQUE KEY: a duplicate insert fails (case and trailing spaces ignored)')
    H.eq(d:exec('INSERT IGNORE INTO cp_a_t (code) VALUES (\'A\')').affected, 0, 'INSERT IGNORE skips it')
    H.eq(d:exec('INSERT INTO cp_a_t (code, n) VALUES (\'B\', 1) ON DUPLICATE KEY UPDATE n = n + VALUES(n)').affected, 2,
        'ON DUPLICATE KEY UPDATE takes the UNIQUE KEY row')
    H.eq(d:exec('SELECT n FROM cp_a_t WHERE code = \'b\'').rows[1][1], 4, 'and updates it')
end

-- ============================================================================
--                   7. THE MySQL DROP-IN (oxmysql's shapes)
-- ============================================================================

do
    local d = M.new():load()
    d:exec(
        'CREATE TABLE cp_o_t (id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(20) NULL, flag TINYINT(1) NOT NULL DEFAULT 0, amount DECIMAL(6,2) NULL, at DATETIME NULL)')
    local warnings = {}
    local realPrint = print
    local real = { calls = {} }
    for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
        real[k] = {
            await = function(sql, params)
                real.calls[#real.calls + 1] = { k, sql, params }
                return { { id = 5, unique_id = 'call_5' } }
            end,
        }
    end
    local sh2 = M.shim(d, { resource = 'Crimson-Police', realMySQL = real })
    H.eq(sh2.insert.await(
        'INSERT INTO cp_o_t (name, amount, at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { 'a', 12.5, 1790000000 }
    ), 1, 'insert -> the new id')
    H.eq(sh2.insert.await('INSERT INTO cp_o_t (name) VALUES (?)', { '101' }), 2, 'insert -> the next id')
    local rows = sh2.query.await('SELECT id, name, flag, amount, at FROM cp_o_t ORDER BY id')
    H.eq(#rows, 2, 'query -> a list of rows')
    H.eq(rows[1].flag, false, 'TINYINT(1) -> boolean')
    H.eq(rows[1].amount, '12.50', 'DECIMAL -> string')
    H.eq(rows[1].at, 1790000000 * 1000, 'DATETIME -> milliseconds')
    H.eq(rows[2].name, '101', 'numeric-looking text -> string')
    H.eq(rows[2].amount, nil, 'NULL -> missing key')
    H.eq(#sh2.query.await('SELECT id FROM cp_o_t WHERE id = 99'), 0, 'query with no rows -> {}')
    local wr = sh2.query.await('UPDATE cp_o_t SET flag = 1 WHERE id = ?', { 1 })
    H.eq(wr.affectedRows, 1, 'query on a write -> the write result (affectedRows)')
    H.eq(wr.changedRows, 1, '(changedRows)')
    H.eq(wr.info, 'Rows matched: 1  Changed: 1  Warnings: 0', '(info)')
    H.eq(wr.insertId, 0, '(insertId)')
    H.eq(sh2.update.await('UPDATE cp_o_t SET flag = 1 WHERE id = ?', { 1 }), 1,
        'update counts matched rows, not changed ones')
    H.eq(sh2.single.await('SELECT id, flag FROM cp_o_t WHERE id = 1').flag, true, 'single -> the first row')
    H.eq(sh2.single.await('SELECT id FROM cp_o_t WHERE id = 99'), nil, 'single with no row -> nil')
    H.eq(sh2.scalar.await('SELECT flag FROM cp_o_t WHERE id = 2'), false, 'scalar keeps false')
    H.eq(sh2.scalar.await('SELECT amount FROM cp_o_t WHERE id = 2'), nil, 'scalar of NULL -> nil')
    H.eq(sh2.scalar.await('SELECT COUNT(*) FROM cp_o_t'), 2, 'scalar -> the first column')
    H.eq(sh2.update.await('SELECT id FROM cp_o_t'), nil, 'update on a SELECT -> nil')
    H.eq(sh2.insert.await('SELECT id FROM cp_o_t'), nil, 'insert on a SELECT -> nil')
    H.eq(sh2.single.await('UPDATE cp_o_t SET name = \'z\' WHERE id = 99'), nil, 'single on a write -> nil')
    H.eq(sh2.insert.await('INSERT INTO cp_o_t (name) VALUES (?)'), 3, 'a missing parameter is NULL (oxmysql pads)')
    H.eq(sh2.scalar.await('SELECT name FROM cp_o_t WHERE id = 3'), nil, '(stored as NULL)')
    local okP, errP = pcall(sh2.query.await, 'SELECT id FROM cp_o_t WHERE id = ?', { 1, 2 })
    H.ok(not okP and tostring(errP):find('Expected 1 parameters, but received 2.', 1, true) ~= nil,
        'extra parameters are an error, like oxmysql')
    local okE, errE = pcall(sh2.query.await, 'SELECT nope FROM cp_o_t WHERE id = ?', { 7 })
    H.ok(not okE, 'a failing query raises a Lua error')
    H.eq(tostring(errE),
        'Crimson-Police was unable to execute a query!\nQuery: SELECT nope FROM cp_o_t WHERE id = ?\n[7]\nUnknown column \'nope\' in \'SELECT\'',
        'with oxmysql\'s text')
    local okT, errT = pcall(sh2.query.await, 'SELECT id FROM cp_o_t WHERE id = ?', { { 1 } })
    H.ok(not okT and tostring(errT):find('a query parameter must be', 1, true) ~= nil,
        'a Lua table parameter is refused')
    local got
    sh2.query('SELECT name FROM cp_o_t WHERE id = ?', { 2 }, function(r) got = r end)
    H.eq(got and got[1] and got[1].name, '101', 'callback form: query(sql, params, cb)')
    got = nil
    sh2.scalar('SELECT COUNT(*) FROM cp_o_t', function(r) got = r end)
    H.eq(got, 3, 'callback form without parameters: scalar(sql, cb)')
    _G.print = function(...) warnings[#warnings + 1] = table.concat({ ... }, ' ') end
    got = 'untouched'
    sh2.query('SELECT broken FROM cp_o_t', {}, function(r) got = r end)
    _G.print = realPrint
    H.eq(got, 'untouched', 'a failing callback query does not call back (it is printed)')
    H.ok(#warnings == 1 and warnings[1]:find('unable to execute a query', 1, true) ~= nil, 'the error is printed once')
    local ready = false
    sh2.ready(function() ready = true end)
    H.ok(ready, 'ready(cb) runs cb (the saves folder is loaded)')
    H.eq(sh2.ready.await(), true, 'ready.await()')
    H.ok(not pcall(function() return sh2.prepare end), 'MySQL.prepare is not available (and never used)')
    H.ok(not pcall(function() return sh2.transaction end), 'MySQL.transaction is not available')
    -- another resource's table: read-only, through the real oxmysql
    local stateOf = 'started'
    local realState = _G.GetResourceState
    _G.GetResourceState = function(name) if name == 'oxmysql' then return stateOf end return 'started' end
    local disp = sh2.query.await(
        'SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { 5, '5' })
    H.eq(disp and disp[1] and disp[1].unique_id, 'call_5', 'a read of another resource\'s table goes to oxmysql')
    H.eq(real.calls[1] and real.calls[1][1], 'query', '(as the same kind of call)')
    stateOf = 'stopped'
    warnings = {}
    _G.print = function(...) warnings[#warnings + 1] = table.concat({ ... }, ' ') end
    local none = sh2.query.await(
        'SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { 5, '5' })
    local none2 = sh2.query.await(
        'SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1', { 6, '6' })
    _G.print = realPrint
    _G.GetResourceState = realState
    H.eq(none, nil, 'without oxmysql that lookup returns nil')
    H.eq(none2, nil, '(every time)')
    H.eq(#warnings, 1, 'and warns once')
    H.ok(warnings[1] and warnings[1]:find('oxmysql is not running', 1, true) ~= nil,
        'with a clear warning: ' .. tostring(warnings[1]))
    H.ok(not pcall(sh2.update.await, 'UPDATE mdt_dispatch SET active = 0 WHERE id = ?', { 5 }),
        'another resource\'s table is never written')
    H.ok(not pcall(sh2.query.await, 'SELECT o.id FROM cp_o_t o JOIN mdt_dispatch m ON m.id = o.id'),
        'and never joined with a Crimson-Police table')
    H.eq(#real.calls, 1, 'nothing else reached oxmysql')
end

-- ============================================================================
--            8. CP.Storage AND THE MIGRATIONS RUNNER IN FILES MODE
-- ============================================================================

do
    H.ok(Exists(H.root .. 'saves/README.md'), 'the resource ships its saves folder (saves/README.md)')
    local savedStorage, savedMySQL, savedCfg = CP.Storage, _G.MySQL, Config.Database
    local function LoadStorage(cfg)
        CP.Storage = { MemSQL = M }   -- as memsql.lua leaves it (fxmanifest loads it first)
        _G.MySQL = savedMySQL
        Config.Database = cfg
        H.load('modules/storage/server.lua')
        return CP.Storage
    end
    local st = LoadStorage({ enabled = true, folder = 'saves' })
    H.eq(st.mode(), 'database', 'enabled = true: database mode')
    H.eq(_G.MySQL, savedMySQL, 'MySQL is left alone')
    H.eq(st.folder(), nil, 'no saves folder')
    H.eq(LoadStorage(nil).mode(), 'database', 'no Config.Database: database mode')
    local abs = TMP .. '/absolute/saves'
    st = LoadStorage({ enabled = false, folder = abs })
    H.eq(st.mode(), 'files', 'enabled = false: files mode')
    H.eq(st.folder(), abs, 'an absolute folder is used as is')
    H.ok(Exists(abs .. '/_tables.json') == false and st.loadError() == nil, 'a missing folder is created')
    H.ok(_G.MySQL ~= savedMySQL and _G.MySQL.query and _G.MySQL.query.await, 'MySQL is the saves folder engine')
    H.eq(st.realMySQL, savedMySQL, 'the original MySQL is kept for other resources\' tables')
    H.ok(st.describe():find(abs, 1, true) ~= nil, 'describe() names the folder')
    st = LoadStorage({ enabled = false, folder = 'saves' })
    H.eq(st.folder(), H.resourcePath() .. '/saves', 'a relative folder is inside the resource')
    -- the real migrations runner applies sql/migrations to the engine and records them
    local lines = {}
    local realPrint = print
    local savedMigrations = CP.Migrations
    _G.print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = false, folder = TMP .. '/runner' })
    H.load('modules/migrations/server.lua')
    _G.print = realPrint
    H.ok(CP.Migrations.isReady(), 'the migrations runner finished')
    H.eq(CP.Migrations.version(), 2, 'at version 2')
    local joined = table.concat(lines, '\n')
    H.ok(joined:find(
        '[crimson-police] storage: database off, data saved as files in the saves folder ' .. TMP .. '/runner',
        1,
        true
    ) ~= nil, 'one start-up line names the storage: ' .. tostring(lines[1]))
    H.ok(joined:find(
        'the saves folder ' .. TMP
            .. '/runner is new, so Crimson-Police starts with no data. Nothing is copied from your database by itself',
        1,
        true
    ) ~= nil, 'a new saves folder is announced: nothing came over from the database')
    H.ok(
        joined:find('[crimson-police] Crimson-Police saves folder at version 2', 1, true) ~= nil
            and not joined:find('database at version', 1, true),
        'the version line names the saves folder, not the database'
    )
    H.eq(st.name(), 'saves folder', 'CP.Storage.name() for console text')
    local applied = st.db:exec('SELECT version, name FROM cp_schema_migrations ORDER BY version')
    H.eq(applied.n, 2, 'the applied migrations are recorded in cp_schema_migrations')
    H.ok(st.db.tables.cp_mission_tests.colIndex.def_hash ~= nil, 'and 002 added def_hash')
    local meta = cjson.decode(ReadFile(TMP .. '/runner/_tables.json'))
    H.eq(meta.migrations and #meta.migrations.rows, 2, 'kept in _tables.json')
    lines = {}
    _G.print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = false, folder = TMP .. '/runner' })
    H.load('modules/migrations/server.lua')
    _G.print = realPrint
    H.ok(not table.concat(lines, '\n'):find('applied migration', 1, true), 'a restart applies nothing twice')
    H.ok(not table.concat(lines, '\n'):find(' is new, so ', 1, true),
        'and a saves folder with data is not announced as new')
    -- switched back on: a new database next to a saves folder with data is announced (here the "database" is an
    -- empty engine behind MySQL)
    lines = {}
    _G.print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = true, folder = TMP .. '/runner' })
    H.eq(st.hasSavedData(), true, 'hasSavedData() sees the saves folder in database mode')
    _G.MySQL = M.shim(M.new():load(), { resource = 'Crimson-Police' })
    H.load('modules/migrations/server.lua')
    _G.print = realPrint
    local joinedDb = table.concat(lines, '\n')
    H.ok(joinedDb:find('Crimson-Police database at version 2', 1, true) ~= nil, 'database mode keeps its version line')
    H.ok(
        joinedDb:find('the database is new, but the saves folder holds data from running with the database off', 1,
            true)
                ~= nil
            and joinedDb:find('storage copy files-to-database', 1, true) ~= nil,
        'a new database next to saved data is announced, with the copy command'
    )
    _G.MySQL = savedMySQL
    -- a folder that cannot be written: the reason, and for a folder outside the resource what FXServer allows
    WriteFile(TMP .. '/afile', 'x')
    local errsW = {}
    _G.print = function(...) errsW[#errsW + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = false, folder = TMP .. '/afile/saves' })
    _G.print = realPrint
    local le = tostring(st.loadError())
    H.ok(
        le:find('cannot be written (', 1, true) ~= nil
            and le:find('FXServer only lets a resource write inside resource folders', 1, true) ~= nil
            and le:find('add_filesystem_permission', 1, true) ~= nil,
        'a folder outside the resource that cannot be written: ' .. le
    )
    st = LoadStorage({ enabled = false, folder = 'afile' })
    H.eq(st.loadError(), nil, '(a folder inside the resource is created)')
    local rp = H.resourcePath()
    WriteFile(rp .. '/notdir', 'x')
    _G.print = function(...) errsW[#errsW + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = false, folder = 'notdir/saves' })
    _G.print = realPrint
    le = tostring(st.loadError())
    H.ok(
        le:find('cannot be written (', 1, true) ~= nil
            and le:find('create it inside the Crimson-Police folder', 1, true) ~= nil,
        'a folder inside the resource that cannot be written names the reason: ' .. le
    )
    os.remove(rp .. '/notdir')
    os.execute(('rm -rf \'%s/afile\''):format(rp))
    -- a saves folder that cannot be read stops Crimson-Police without touching it
    WriteFile(TMP .. '/runner/officers.json', 'garbage')
    local errs = {}
    _G.print = function(...) errs[#errs + 1] = table.concat({ ... }, ' ') end
    st = LoadStorage({ enabled = false, folder = TMP .. '/runner' })
    local okQ, errQ = pcall(_G.MySQL.query.await, 'SELECT 1 AS x FROM cp_officers')
    _G.print = realPrint
    H.ok(st.loadError() ~= nil and st.loadError():find('officers.json', 1, true) ~= nil,
        'a damaged document is reported: ' .. tostring(st.loadError()))
    H.ok(not okQ and tostring(errQ):find('could not be read', 1, true) ~= nil,
        'and every query fails until it is fixed')
    H.eq(ReadFile(TMP .. '/runner/officers.json'), 'garbage', 'the document is left as it is')
    CP.Storage, _G.MySQL, Config.Database, CP.Migrations = savedStorage, savedMySQL, savedCfg, savedMigrations
end

-- ============================================================================
--                          9. DETAILS A REVIEW FOUND
-- ============================================================================
-- Each block reproduced the problem before the fix.

local function Fresh(opts)
    local d = M.new():load()
    return d, M.shim(d, opts or { resource = 'Crimson-Police' })
end
local function ErrOf(fn, ...)
    local ok, err = pcall(fn, ...)
    if ok then return nil end
    return LastLine(err)
end

-- 9.1 utf8mb4_general_ci is MariaDB's own table: every BMP code point weighs what MariaDB's WEIGHT_STRING says
-- and LOWER() maps it as MariaDB does (read from the local MariaDB when it runs)
do
    local p = io.popen(
        [[mysql -uroot -N -e "SELECT seq, HEX(WEIGHT_STRING(CONVERT(CHAR(seq USING utf32) USING utf8mb4) COLLATE utf8mb4_general_ci)), HEX(CONVERT(LOWER(CONVERT(CHAR(seq USING utf32) USING utf8mb4) COLLATE utf8mb4_general_ci) USING utf32)) FROM mysql.seq_0_to_65535 WHERE seq < 55296 OR seq > 57343" 2>/dev/null]])
    local out = p and p:read('a') or ''
    if p then p:close() end
    local n, badW, badL, examples = 0, 0, 0, {}
    for cp, w, lo in out:gmatch('(%d+)\t(%x*)\t(%x+)\n') do
        cp, w, lo = tonumber(cp), tonumber(w, 16), tonumber(lo, 16)
        n = n + 1
        local ch = utf8.char(cp)
        local want = cp == 32 and '' or utf8.char(w)   -- (a space is a trailing space: PAD SPACE)
        if M.ciKey(ch) ~= want then
            badW = badW + 1
            if #examples < 5 then examples[#examples + 1] = ('U+%04X weight'):format(cp) end
        end
        if M.lowerText(ch) ~= utf8.char(lo) then
            badL = badL + 1
            if #examples < 5 then examples[#examples + 1] = ('U+%04X LOWER'):format(cp) end
        end
    end
    if n == 0 then
        print('  SKIP memsql 9.1: MariaDB is not reachable, the collation table was not compared')
    else
        H.eq(n, 63488, 'every BMP code point compared with MariaDB 10.11')
        H.eq(badW, 0, 'every character weighs what MariaDB says (utf8mb4_general_ci): ' .. table.concat(examples, ', '))
        H.eq(badL, 0, 'LOWER() maps every character as MariaDB does')
    end
    H.eq(M.ciKey('😀'), M.ciKey('𝄞'), 'characters beyond U+FFFF all weigh the same (U+FFFD)')
    local _, sh9 = Fresh()
    sh9.query.await('CREATE TABLE cp_officers (citizenid VARCHAR(50) PRIMARY KEY, display_name VARCHAR(64) NULL)')
    sh9.query.await(
        'INSERT INTO cp_officers VALUES (\'A1\',\'Пётр Иванов\'),(\'A2\',\'Ștefan Pop\'),(\'A3\',\'Nguyễn Văn An\'),(\'A4\',\'Їжак\'),(\'A5\',\'Абрамов\'),(\'A6\',\'Ёлкин\'),(\'A7\',\'Bob\')')
    local found = {}
    for _, q in ipairs({ '%Петр%', '%ştefan%', '%nguyen%', '%іжак%' }) do
        found[#found + 1] = #sh9.query.await('SELECT citizenid FROM cp_officers WHERE display_name LIKE ?', { q })
    end
    H.eq(table.concat(found, ' '), '1 1 1 1', 'the admin search finds Пётр, Ștefan, Nguyễn and Їжак as MariaDB does')
    local order = {}
    for _, r in ipairs(sh9.query.await('SELECT citizenid FROM cp_officers ORDER BY display_name')) do
        order[#order + 1] = r.citizenid
    end
    H.eq(table.concat(order, ' '), 'A7 A3 A2 A4 A5 A6 A1',
        'ORDER BY sorts like MariaDB (Ș with S, Ї and Ё with І and Е)')
    H.eq(sh9.scalar.await('SELECT LOWER(\'İ\')'), 'i', 'LOWER(\'İ\') is \'i\'')
end

-- 9.2 PAD SPACE ordering: a text that goes on with a character below a space sorts before the shorter text
do
    local _, sh9 = Fresh()
    sh9.query.await('CREATE TABLE cp_pad (id INT PRIMARY KEY, v VARCHAR(20) NOT NULL)')
    sh9.query.await(
        'INSERT INTO cp_pad VALUES (1, \'Bob\'), (2, \'Bob\tSmith\'), (3, \'Bob\nX\'), (4, \'Bob Z\'), (5, \'Bob \tQ\'), (6, \'Bob  \')')
    local order = {}
    for _, r in ipairs(sh9.query.await('SELECT id FROM cp_pad ORDER BY v, id')) do order[#order + 1] = r.id end
    H.eq(table.concat(order, ' '), '2 3 5 1 6 4',
        'ORDER BY as MariaDB: Bob<tab>Smith, Bob<newline>X, Bob <tab>Q, then Bob, Bob (spaces), Bob Z')
    H.eq(sh9.scalar.await('SELECT COUNT(*) FROM cp_pad WHERE v < \'Bob\''), 3, 'v < \'Bob\' matches the three')
    H.eq(sh9.scalar.await('SELECT MIN(v) = \'Bob\' FROM cp_pad'), 0, 'MIN(v) is not \'Bob\'')
    H.eq(sh9.scalar.await('SELECT MAX(v) FROM cp_pad'), 'Bob Z', 'MAX(v)')
    H.eq(sh9.scalar.await('SELECT GREATEST(\'Bob\', \'Bob\tSmith\')'), 'Bob', 'GREATEST')
    H.eq(sh9.scalar.await('SELECT COUNT(*) FROM cp_pad WHERE v = \'Bob\''), 2,
        'equality still ignores trailing spaces (\'Bob\' and \'Bob  \')')
    local groups = sh9.query.await('SELECT COUNT(*) AS n FROM cp_pad GROUP BY v ORDER BY n DESC')
    H.eq(#groups, 5, 'GROUP BY still groups by equality')
end

-- 9.3 integer arithmetic raises MariaDB's out-of-range error instead of wrapping around
do
    local _, sh9 = Fresh()
    sh9.query.await('CREATE TABLE cp_n (id INT PRIMARY KEY, b BIGINT NULL, i INT NULL, xp INT NOT NULL DEFAULT 5)')
    sh9.query.await(
        'INSERT INTO cp_n (id, b, i) VALUES (1, 9223372036854775807, 2147483647), (2, 9223372036854775807, 1)')
    H.eq(ErrOf(sh9.update.await, 'UPDATE cp_n SET b = b + 1 WHERE id = 1'),
        'BIGINT value is out of range in \'`saves`.`cp_n`.`b` + 1\'',
        'b + 1 past the largest BIGINT: the MariaDB error (1690)')
    H.eq(sh9.scalar.await('SELECT b FROM cp_n WHERE id = 1'), '9223372036854775807', 'and the row is kept')
    H.eq(ErrOf(sh9.update.await, 'UPDATE cp_n SET xp = GREATEST(0, xp + ?) WHERE id = 1', { 9223372036854775807 }),
        'BIGINT value is out of range in \'`saves`.`cp_n`.`xp` + 9223372036854775807\'',
        'GREATEST(0, xp + ?): the error, not xp = 0')
    H.eq(sh9.scalar.await('SELECT xp FROM cp_n WHERE id = 1'), 5, 'xp is kept')
    H.eq(ErrOf(sh9.query.await, 'SELECT i*i*i FROM cp_n WHERE id = 1'),
        'BIGINT value is out of range in \'`saves`.`cp_n`.`i` * `saves`.`cp_n`.`i` * `saves`.`cp_n`.`i`\'', 'i*i*i')
    H.eq(ErrOf(sh9.query.await, 'SELECT -b - 2 FROM cp_n n WHERE id = 1'),
        'BIGINT value is out of range in \'-`saves`.`n`.`b` - 2\'', '-b - 2 (an alias)')
    H.eq(sh9.scalar.await('SELECT b - 1 + 1 FROM cp_n WHERE id = 1'), '9223372036854775807',
        'a result that fits is fine')
    local e = ErrOf(sh9.query.await, 'SELECT SUM(b) FROM cp_n')
    H.ok(e and e:find(M.unsupportedPrefix .. 'DECIMAL values of more than 18 digits', 1, true),
        'SUM past the engine\'s 18 digits is refused, not wrapped: ' .. tostring(e))
    e = ErrOf(sh9.query.await, 'SELECT SUM(b) AS s FROM cp_n GROUP BY xp')
    H.ok(e and e:find('more than 18 digits', 1, true), '(also per group)')
    sh9.query.await('INSERT INTO cp_n (id, b) VALUES (3, -9223372036854775807)')
    H.eq(sh9.scalar.await('SELECT SUM(b) FROM cp_n WHERE id <> 2'), '0', 'a SUM that fits')
end

-- 9.4 a DATE is a calendar day in the documents: a saves folder moved to a server in another time zone keeps
-- its days (the streak dates of scoring/server.lua)
do
    local dir = TMP .. '/tzdate'
    Mkdir(dir)
    local script = TMP .. '/tzdate.lua'
    WriteFile(
        script,
        ([[
local cjson = require('cjson')
json = { encode = cjson.encode, decode = cjson.decode }
CP = {}
dofile(%q)
local M = CP.Storage.MemSQL
local d = M.new({ store = M.folderStore(%q) }):load()
if arg[1] == 'write' then
    d:exec('CREATE TABLE cp_officers (citizenid VARCHAR(50) PRIMARY KEY, last_complete DATE NULL, grace_week DATE NULL, at DATETIME NULL)')
    d:exec("INSERT INTO cp_officers VALUES ('A', '2026-09-29', '2026-09-28', FROM_UNIXTIME(1790000000))")
end
local r = d:exec("SELECT DATE_FORMAT(last_complete, '%%Y-%%m-%%d'), DATE_FORMAT(grace_week, '%%Y-%%m-%%d'), UNIX_TIMESTAMP(at) FROM cp_officers").rows[1]
print(r[1] .. ' ' .. r[2] .. ' ' .. r[3])
]]):format(H.root .. 'modules/storage/memsql.lua', dir)
    )
    local function Run(tz, mode)
        local p = io.popen(('TZ=%s lua5.4 \'%s\' %s 2>&1'):format(tz, script, mode or ''))
        local s = p:read('a')
        p:close()
        return (s:gsub('%s+$', ''))
    end
    H.eq(Run('Europe/Berlin', 'write'), '2026-09-29 2026-09-28 1790000000', 'written under Europe/Berlin')
    H.eq(Run('UTC'), '2026-09-29 2026-09-28 1790000000', 'read under UTC: the same days')
    H.eq(Run('America/Chicago'), '2026-09-29 2026-09-28 1790000000',
        'read under America/Chicago: the same days (a DATETIME is the same moment)')
    H.ok(ReadFile(dir .. '/officers.json'):find('["A","2026-09-29","2026-09-28",1790000000]', 1, true) ~= nil,
        'the document shows the dates as dates: ' .. tostring(ReadFile(dir .. '/officers.json'):match('\n(%[[^\n]*)')))
end

-- 9.5 BIGINT and wide DECIMAL values read back exactly (the fast reader leaves doubles that may have lost digits
-- to the exact one)
do
    local dir = TMP .. '/exact'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    d:exec('CREATE TABLE cp_x (id INT PRIMARY KEY, b BIGINT NULL, m DECIMAL(18,2) NULL, j JSON NULL)')
    d:exec(
        'INSERT INTO cp_x VALUES (1, 9007199254740993, 1234567890123456.78, \'{"a":1}\'), (2, 9223372036854775807, -9999999999999999.99, NULL), (3, 123456789012345678, 0.01, \'[1]\'), (4, -9223372036854775807, 12.5, NULL)')
    local back = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, back,
        'BIGINT 9007199254740993 / 2^63-1 and DECIMAL(18,2) 1234567890123456.78 survive a restart exactly')
end

-- 9.6 ALTER TABLE: MariaDB's additive forms (the SPEC's database upgrades), and no zero dates
do
    local dir = TMP .. '/ddl'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    local sh9 = M.shim(d, { resource = 'Crimson-Police' })
    sh9.query.await('CREATE TABLE cp_t (id INT AUTO_INCREMENT PRIMARY KEY, a INT NULL, s VARCHAR(10) NULL)')
    sh9.query.await('INSERT INTO cp_t (a, s) VALUES (1, \'x\'), (1, \'y\')')
    local r = sh9.query.await('ALTER TABLE cp_t ADD COLUMN IF NOT EXISTS b INT NULL')
    H.eq(r.info, 'Records: 0  Duplicates: 0  Warnings: 0', 'ADD COLUMN IF NOT EXISTS')
    r = sh9.query.await('ALTER TABLE cp_t ADD COLUMN IF NOT EXISTS b INT NULL')
    H.eq(r.warningStatus, 1, 'again: a note (MariaDB 1060), not an error')
    sh9.query.await('ALTER TABLE cp_t ADD INDEX (a), ADD KEY (a), ADD INDEX idx_s (s)')
    H.eq(sh9.query.await('CREATE INDEX IF NOT EXISTS idx_s ON cp_t (a)').warningStatus, 1,
        'CREATE INDEX IF NOT EXISTS on an existing name: a note')
    sh9.query.await('CREATE INDEX idx_b ON cp_t (b)')
    sh9.query.await('ALTER TABLE cp_t ADD COLUMN c INT NOT NULL DEFAULT 3 AFTER a, ADD COLUMN d VARCHAR(5) NULL FIRST')
    H.eq(M.renderCreate(d.tables.cp_t),
        'CREATE TABLE cp_t (d VARCHAR(5) NULL, id INT NOT NULL AUTO_INCREMENT, a INT NULL, c INT NOT NULL DEFAULT 3, s VARCHAR(10) NULL, b INT NULL, PRIMARY KEY (id), KEY a (a), KEY a_2 (a), KEY idx_s (s), KEY idx_b (b))',
        'columns FIRST / AFTER and MariaDB\'s index names (a, a_2), as SHOW CREATE TABLE shows them')
    local row = sh9.single.await('SELECT * FROM cp_t WHERE id = 2')
    H.ok(row.d == nil and row.a == 1 and row.c == 3 and row.s == 'y', 'the rows follow: ' .. Show(row))
    H.eq(ErrOf(sh9.query.await, 'ALTER TABLE cp_t ADD UNIQUE (a)'), 'Duplicate entry \'1\' for key \'a_3\'',
        'ADD UNIQUE on duplicates: MariaDB\'s error')
    H.eq(ErrOf(sh9.query.await, 'ALTER TABLE cp_t ADD INDEX idx_s (a)'), 'Duplicate key name \'idx_s\'',
        'a taken index name')
    H.eq(ErrOf(sh9.query.await, 'ALTER TABLE cp_t ADD COLUMN e INT NULL, ADD COLUMN e INT NULL'),
        'Duplicate column name \'e\'', 'a column twice')
    H.eq(d.tables.cp_t.colIndex.e, nil, 'and the whole ALTER is undone')
    H.eq(ErrOf(sh9.query.await, 'ALTER TABLE cp_t ADD COLUMN f INT NULL AFTER nope'),
        'Unknown column \'nope\' in \'cp_t\'', 'AFTER an unknown column')
    sh9.query.await('CREATE UNIQUE INDEX uq_s ON cp_t (s)')
    H.eq(ErrOf(sh9.query.await, 'INSERT INTO cp_t (a, s) VALUES (5, \'X\')'), 'Duplicate entry \'X\' for key \'uq_s\'',
        'a new UNIQUE index is checked (case-insensitive)')
    local e = ErrOf(sh9.query.await, 'ALTER TABLE cp_t ADD COLUMN g DATETIME NOT NULL')
    H.ok(
        e and e:find(M.unsupportedPrefix .. 'storing \'0000-00-00 00:00:00\'', 1, true),
        'a NOT NULL DATETIME without a default on a table with rows is refused (MariaDB stores zero dates): '
            .. tostring(e)
    )
    sh9.query.await('CREATE TABLE cp_e (id INT PRIMARY KEY)')
    sh9.query.await('ALTER TABLE cp_e ADD COLUMN g DATETIME NOT NULL, ADD COLUMN h DATE NOT NULL')
    H.ok(d.tables.cp_e.colIndex.g ~= nil, 'on an empty table it is fine')
    local back = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, back, 'the changed tables load back')
    H.eq(M.renderCreate(back.tables.cp_t), M.renderCreate(d.tables.cp_t), 'with their columns and indexes')
    H.eq(ErrOf(M.shim(back).query.await, 'INSERT INTO cp_t (a, s) VALUES (5, \'Y\')'),
        'Duplicate entry \'Y\' for key \'uq_s\'', 'and the UNIQUE index still works')
end

-- 9.7 an UPDATE (or ON DUPLICATE KEY UPDATE) that sets an AUTO_INCREMENT column at or past the counter moves it on
-- (MariaDB 10.11 / InnoDB; the values are MariaDB's)
do
    local dir = TMP .. '/ai'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    local sh9 = M.shim(d, { resource = 'Crimson-Police' })
    sh9.query.await(
        'CREATE TABLE cp_a (id INT AUTO_INCREMENT PRIMARY KEY, k VARCHAR(4) NOT NULL, n INT NOT NULL DEFAULT 0, UNIQUE KEY uq_k (k))')
    sh9.query.await('INSERT INTO cp_a (k) VALUES (\'a\'), (\'b\')')
    sh9.update.await('UPDATE cp_a SET id = 500 WHERE k = \'b\'')
    H.eq(sh9.insert.await('INSERT INTO cp_a (k) VALUES (\'c\')'), 501, 'UPDATE id = 500: the next id is 501')
    sh9.query.await('INSERT INTO cp_a (k) VALUES (\'a\') ON DUPLICATE KEY UPDATE id = 800')
    H.eq(sh9.insert.await('INSERT INTO cp_a (k) VALUES (\'d\')'), 801, 'ON DUPLICATE KEY UPDATE id = 800: 801')
    sh9.update.await('UPDATE cp_a SET id = id + 1000 WHERE k IN (\'c\', \'d\')')
    H.eq(sh9.insert.await('INSERT INTO cp_a (k) VALUES (\'e\')'), 1802, 'several rows: the largest + 1')
    sh9.update.await('UPDATE cp_a SET id = 100 WHERE k = \'e\'')
    H.eq(sh9.insert.await('INSERT INTO cp_a (k) VALUES (\'f\')'), 1803, 'a value below the counter changes nothing')
    H.ok(not pcall(
        sh9.update.await,
        'UPDATE cp_a SET id = id + 5000, k = IF(k = \'f\', \'a\', k) WHERE k IN (\'b\', \'f\')'
    ), 'an UPDATE whose second row fails')
    H.eq(sh9.insert.await('INSERT INTO cp_a (k) VALUES (\'g\')'), 5501,
        'keeps the counter its first row moved (MariaDB: 5501)')
    local back = M.new({ store = M.folderStore(dir) }):load()
    H.eq(back:exec('INSERT INTO cp_a (k) VALUES (\'h\')').insertId, 5502, 'and so does the saves folder')
end

-- 9.8 FXServer's Linux build answers os.rename the wrong way round (a rename that worked reads as failed, one
-- that failed as done): every save still works, and every crash point is still safe
do
    local realRename = os.rename
    os.rename = function(a, b)
        local ok = realRename(a, b)
        if ok then return nil, a .. ' -> ' .. b .. ': Permission denied', 13 end
        return true
    end
    local dir = TMP .. '/inverted'
    Mkdir(dir)
    local okAll, errAll = pcall(function()
        local d = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
        H.eq(d.store.renames, 'inverted', 'the saves folder finds out how this runtime answers a rename')
        Migrate(d)
        for i = 1, 12 do
            d:exec('INSERT INTO cp_audit (actor, role, action, target) VALUES (\'A\', \'admin\', \'x\', ?)',
                { 't' .. i })
        end
        d:exec('UPDATE cp_audit SET target = \'changed\' WHERE id = 3')
        d:exec('DELETE FROM cp_audit WHERE id = 12')
        local back = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
        SameTables(d, back, 'saves (a split table, an update, a delete) load back identical on that runtime')
        H.eq(#Leftovers(dir), 0, 'no .tmp or .bak left')
        local runs, problems = CrashSuite({ false })
        H.ok(runs > 30, 'crash points tried with the inverted rename: ' .. runs)
        H.eq(
            #problems,
            0,
            'every crash point is safe there too'
                .. (#problems > 0 and (': ' .. table.concat(problems, ' | ', 1, math.min(#problems, 4))) or '')
        )
    end)
    os.rename = realRename
    H.ok(okAll, 'the inverted-rename runtime: ' .. tostring(errAll))
    local d2 = M.new({ store = M.folderStore(TMP .. '/inverted2') })
    Mkdir(TMP .. '/inverted2')
    d2:load()
    H.eq(d2.store.renames, 'normal', 'and plain Lua is recognised as it is')
end

-- 9.8b where a rename cannot replace a file (Windows), the saves folder learns it at the first save and skips the
-- rename that cannot work: one document is then saved with a write, two renames and a removal
do
    local dir = TMP .. '/winops'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir) }):load()
    d:exec('CREATE TABLE cp_w (id INT PRIMARY KEY, n INT NOT NULL)')
    d:exec('INSERT INTO cp_w VALUES (1, 0)')
    local ops = {}
    M.fs.write = function(p, data) ops[#ops + 1] = 'write'; return realFs.write(p, data) end
    M.fs.rename = function(a, b)
        ops[#ops + 1] = 'rename'
        if realFs.exists(b) then return nil, 'file exists' end
        return realFs.rename(a, b)
    end
    M.fs.remove = function(p) ops[#ops + 1] = 'remove'; return realFs.remove(p) end
    d:exec('UPDATE cp_w SET n = 1 WHERE id = 1')
    local first = #ops
    ops = {}
    d:exec('UPDATE cp_w SET n = 2 WHERE id = 1')
    RestoreFs()
    H.ok(first >= 5, 'the first save finds out (' .. first .. ' file operations)')
    H.eq(table.concat(ops, ' '), 'write rename rename remove',
        'the next ones: write, rename to .bak, rename into place, remove .bak')
    H.eq(M.new({ store = M.folderStore(dir) }):load():exec('SELECT n FROM cp_w').rows[1][1], 2,
        'and the document is saved')
end

-- 9.9 a save that fails part way (not a crash: the disk refuses one file operation) leaves the saves folder as
-- it was before the statement, without waiting for another save
local function FailSuite()
    local runs, problems = 0, {}
    local realPrint = print
    _G.print = function(...)
        local line = table.concat({ ... }, ' ')
        if not line:find('that the table no longer has', 1, true) then realPrint(line) end
    end
    for _, sc in ipairs(SCENARIOS) do
        local dir = TMP .. '/fail'
        local base = Prepare(dir, sc)
        local count = WithFs(false, nil)
        local before = Snapshot(base)
        sc[2](base)
        local ops = count()
        RestoreFs()
        local after = Snapshot(base)
        for failAt = 1, ops do
            runs = runs + 1
            local d = Prepare(dir, sc)
            local n = 0
            local function hit() n = n + 1; return n == failAt end
            M.fs.write = function(p, data)
                if hit() then return nil, 'No space left on device' end
                return realFs.write(p, data)
            end
            M.fs.rename = function(a, b)
                if hit() then return nil, 'the file is open in another program' end
                return realFs.rename(a, b)
            end
            M.fs.remove = function(p) if hit() then return nil, 'refused' end return realFs.remove(p) end
            local ok = pcall(sc[2], d)
            RestoreFs()
            local where = ('%s, file operation %d of %d refused'):format(sc[1], failAt, ops)
            local want = ok and after or before
            local inMemory = Snapshot(d)
            local back = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
            local now = Snapshot(back)
            for tname, wt in pairs(want) do
                local mt, nt = inMemory[tname], now[tname]
                for key, val in pairs(wt.rows) do
                    if not ok and mt.rows[key] ~= val then
                        problems[#problems + 1] = where .. ': in memory ' .. tname .. ' row ' .. key .. ' changed'
                    end
                    if nt.rows[key] ~= val then
                        problems[#problems + 1] = ('%s: the saves folder has %s row %s %s'):format(where, tname, key,
                            nt.rows[key] and 'changed' or 'missing')
                    end
                end
                for key in pairs(nt.rows) do
                    if not wt.rows[key] then
                        problems[#problems + 1] = ('%s: the saves folder has a row %s.%s that %s'):format(where, tname,
                            key, ok and 'nobody wrote' or 'was undone')
                    end
                end
                if wt.nextId and nt.nextId < wt.nextId then
                    problems[#problems + 1] = where .. ': ' .. tname .. ' next id went back'
                end
            end
            -- the next save writes only its own document
            local w = RecordWrites()
            local okW = pcall(back.exec, back, 'UPDATE cp_crash_k SET v = v + 1 WHERE k = \'k01\'')
            RestoreFs()
            local docs = 0
            for _, p in ipairs(w) do if not p:match('%.cp%-') then docs = docs + 1 end end
            if not okW or docs > 1 then
                problems[#problems + 1] = where .. ': the next save wrote ' .. docs .. ' files'
            end
            -- and the engine that failed keeps working
            local okD = pcall(d.exec, d, 'UPDATE cp_crash_k SET v = v + 1 WHERE k = \'k01\'')
            if not okD then problems[#problems + 1] = where .. ': the engine cannot write afterwards' end
        end
    end
    _G.print = realPrint
    return runs, problems
end
do
    local runs, problems = FailSuite()
    H.ok(runs > 30, 'refused file operations tried: ' .. runs)
    H.eq(
        #problems,
        0,
        'a refused file operation: the statement is undone in memory and in the saves folder (or it went through), and the next save writes only its own document'
            .. (#problems > 0 and (': ' .. table.concat(problems, ' | ', 1, math.min(#problems, 5))) or '')
    )
    -- a disk that stays full: the restore fails too, and the next save that works puts it right
    local dir = TMP .. '/full'
    Mkdir(dir)
    local st = M.folderStore(dir, { docRows = 2 })
    local d = M.new({ store = st }):load()
    d:exec('CREATE TABLE cp_r (id INT AUTO_INCREMENT PRIMARY KEY, st VARCHAR(10) NOT NULL)')
    d:exec('INSERT INTO cp_r (st) VALUES (\'pending\'), (\'pending\'), (\'pending\'), (\'pending\')')
    local renames = 0
    M.fs.rename = function(a, b)
        renames = renames + 1
        if renames >= 2 then return nil, 'locked' end
        return realFs.rename(a, b)
    end
    M.fs.write = function(p, data)
        if renames >= 2 then return nil, 'No space left on device' end
        return realFs.write(p, data)
    end
    local okU, errU = pcall(d.exec, d, 'UPDATE cp_r SET st = \'paid\' WHERE st = \'pending\'')
    RestoreFs()
    H.ok(not okU and tostring(errU):find('may hold part of it', 1, true) ~= nil,
        'the change is undone and the message says the saves folder may hold part of it: ' .. tostring(errU))
    H.eq(d:exec('SELECT COUNT(*) FROM cp_r WHERE st = \'paid\'').rows[1][1], 0, 'memory has none of it')
    d:exec('INSERT INTO cp_r (st) VALUES (\'new\')')
    local back = M.new({ store = M.folderStore(dir, { docRows = 2 }) }):load()
    SameTables(d, back, 'the next save that works writes back what the failed one left')
    -- the review's case: a new range document written, _tables.json refused: no phantom row after a restart
    Mkdir(dir)
    d = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    d:exec('CREATE TABLE cp_r (id INT AUTO_INCREMENT PRIMARY KEY, st VARCHAR(10) NOT NULL)')
    for i = 1, 10 do d:exec('INSERT INTO cp_r (st) VALUES (?)', { 'r' .. i }) end
    M.fs.rename = function(a, b)
        if a:find('_tables.json.tmp', 1, true) then return nil, 'locked' end
        return realFs.rename(a, b)
    end
    H.ok(not pcall(d.exec, d, 'INSERT INTO cp_r (st) VALUES (\'r11\')'),
        'an insert whose _tables.json cannot be saved fails')
    RestoreFs()
    back = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    H.eq(#back.tables.cp_r.rows, 10, 'and after a restart there is no phantom row 11')
    H.eq(#Leftovers(dir), 0, 'nothing is left behind')
end

-- 9.10 a document edited by hand: a value too few or too many, a key twice, a NOT NULL value missing stop the start
-- with the document and line; a byte order mark or a reformatted document is read
do
    local dir = TMP .. '/hand'
    local function Setup()
        Mkdir(dir)
        local d = M.new({ store = M.folderStore(dir) }):load()
        d:exec(
            'CREATE TABLE cp_officers (citizenid VARCHAR(50) PRIMARY KEY, callsign VARCHAR(10) NULL, rank_label VARCHAR(20) NULL, xp INT NOT NULL DEFAULT 0, hide_name TINYINT(1) NOT NULL DEFAULT 0, data JSON NULL)')
        d:exec(
            [[INSERT INTO cp_officers VALUES ('AAA', '101', 'Sergeant', 50, 0, '{"a": [1, 2]}'), ('BBB', '102', 'Trooper', 70, 1, NULL)]])
        return d
    end
    local d = Setup()
    local doc = dir .. '/officers.json'
    local good = ReadFile(doc)
    local function LoadErr()
        local ok, err = pcall(function() return M.new({ store = M.folderStore(dir) }):load() end)
        if ok then return nil end
        return tostring(err)
    end
    WriteFile(doc, (good:gsub('%["AAA","101","Sergeant",50,0,', '["AAA","Sergeant",50,0,')))
    local e = LoadErr()
    H.ok(e and e:find('saves/officers.json line 2', 1, true) and e:find('5 values for 6 columns', 1, true),
        'a value missing: ' .. tostring(e))
    WriteFile(doc, (good:gsub('%["AAA","101","Sergeant",50,0,', '["AAA","101","Sergeant",50,0,1,')))
    e = LoadErr()
    H.ok(e and e:find('7 values for 6 columns', 1, true), 'a value too many: ' .. tostring(e))
    WriteFile(doc, (good:gsub('\n%]}', ',\n["BBB","102","Trooper",999,1,null]\n]}')))
    e = LoadErr()
    H.ok(e and e:find('the key \'BBB\' twice', 1, true), 'a key twice: ' .. tostring(e))
    WriteFile(doc, (good:gsub('%["BBB","102","Trooper",70,1,', '["BBB","102","Trooper",null,1,')))
    e = LoadErr()
    H.ok(e and e:find('line 3: xp is null', 1, true), 'NULL in a NOT NULL column: ' .. tostring(e))
    H.ok(ReadFile(doc):find('null,1,', 1, true) ~= nil, 'and the document is left as it is')
    WriteFile(doc, '\239\187\191' .. good)
    local b = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, b, 'a document with a byte order mark (Windows Notepad) is read')
    local node = M.jparse(good)
    local pretty = '{\n  "table": "cp_officers",\n  "columns": [\n    "citizenid", "callsign", "rank_label", "xp", "hide_name", "data"\n  ],\n  "rows": [\n'
        .. '    [\n      "AAA", "101", "Sergeant", 50, 0,\n      {"a": [1, 2]}\n    ],\n    [ "BBB", "102", "Trooper", 70, 1, null ]\n  ]\n}\n'
    H.ok(node ~= nil, '(the document is JSON)')
    WriteFile(doc, pretty)
    b = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, b, 'a pretty-printed document is read')
    WriteFile(doc, (good:gsub('\n', '')))
    b = M.new({ store = M.folderStore(dir) }):load()
    SameTables(d, b, 'a document on one line is read')
    WriteFile(dir .. '/_tables.json', '\239\187\191' .. ReadFile(dir .. '/_tables.json'))
    b = M.new({ store = M.folderStore(dir) }):load()
    H.ok(b.tables.cp_officers ~= nil, '_tables.json with a byte order mark is read')
    b:exec('UPDATE cp_officers SET xp = 51 WHERE citizenid = \'AAA\'')
    H.eq(ReadFile(doc):sub(1, 1), '{', 'the next save writes the engine\'s own layout again')
    H.ok(ReadFile(doc):find('\n["AAA","101","Sergeant",51,0,{"a": [1, 2]}]', 1, true) ~= nil,
        '(one row per line, the JSON text as it was stored)')
end

-- 9.11 a document that is missing at start is reported, and its ids are never handed out again
do
    local dir = TMP .. '/missing'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    d:exec('CREATE TABLE cp_officers (citizenid VARCHAR(50) PRIMARY KEY, xp INT NOT NULL DEFAULT 0)')
    d:exec('INSERT INTO cp_officers (citizenid) VALUES (\'A\'), (\'B\')')
    d:exec('CREATE TABLE cp_runs (id INT AUTO_INCREMENT PRIMARY KEY, who VARCHAR(10) NOT NULL)')
    for i = 1, 13 do d:exec('INSERT INTO cp_runs (who) VALUES (?)', { 'r' .. i }) end
    d:exec('CREATE TABLE cp_small (id INT AUTO_INCREMENT PRIMARY KEY, who VARCHAR(10) NOT NULL)')
    d:exec('INSERT INTO cp_small (who) VALUES (\'s1\'), (\'s2\')')
    d:exec('DELETE FROM cp_runs WHERE id >= 11')
    H.ok(Exists(dir .. '/runs_3.json'), 'the newest range document stays when it is emptied')
    os.remove(dir .. '/officers.json')
    os.remove(dir .. '/runs_3.json')
    os.remove(dir .. '/small.json')
    local warnings = {}
    local realPrint = print
    _G.print = function(...) warnings[#warnings + 1] = table.concat({ ... }, ' ') end
    local b = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    _G.print = realPrint
    local all = table.concat(warnings, '\n')
    H.ok(all:find('saves/officers.json is missing: cp_officers starts empty', 1, true) ~= nil,
        'a missing document is reported: ' .. all)
    H.ok(all:find('saves/runs_3.json is missing: the rows of cp_runs with ids 11 to 15', 1, true) ~= nil,
        'with the ids it held')
    H.eq(#b.tables.cp_officers.rows, 0, '(the table starts empty)')
    H.eq(b:exec('INSERT INTO cp_runs (who) VALUES (\'new\')').insertId, 16,
        'ids of a missing range document are not handed out again')
    H.eq(b:exec('INSERT INTO cp_small (who) VALUES (\'new\')').insertId, 6,
        'nor those a missing single document could hold')
end

-- 9.12 row lines stay cached only for the documents saved last (memory does not grow with every save)
do
    local dir = TMP .. '/lncache'
    Mkdir(dir)
    local d = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    d:exec('CREATE TABLE cp_big (id INT AUTO_INCREMENT PRIMARY KEY, who VARCHAR(10) NOT NULL)')
    d:bulk(function(db) for i = 1, 200 do db:exec('INSERT INTO cp_big (who) VALUES (?)', { 'w' .. i }) end end)
    for i = 1, 200, 5 do d:exec('UPDATE cp_big SET who = \'x\' WHERE id = ?', { i }) end
    local cached = 0
    for _, r in ipairs(d.tables.cp_big.rows) do if r.ln then cached = cached + 1 end end
    H.ok(cached <= 16 * 5, 'after saving 40 documents, at most 16 keep their row lines (' .. cached .. ' rows)')
    local back = M.new({ store = M.folderStore(dir, { docRows = 5 }) }):load()
    SameTables(d, back, 'and every document is still saved correctly')
end

-- 9.14 on a server a long SELECT run from a thread gives the server its turn every few milliseconds instead of
-- holding the server thread (as oxmysql's await yields); every other statement waits for it, so it answers from
-- the tables as they were when it started
do
    local d = M.new():load()
    d:exec('CREATE TABLE cp_s (id INT AUTO_INCREMENT PRIMARY KEY, g INT NOT NULL, v INT NOT NULL)')
    d:bulk(function(db) for i = 1, 30000 do db:exec('INSERT INTO cp_s (g, v) VALUES (?, ?)', { i % 50, i }) end end)
    local SQL = 'SELECT g, COUNT(*) AS n, SUM(v) AS s FROM cp_s WHERE v > 0 GROUP BY g ORDER BY g'
    local plain = d:exec(SQL)
    local turns = 0
    d.slice = {
        ms = 1,
        wait = function() turns = turns + 1; coroutine.yield('turn') end,
    }
    local co = coroutine.create(function() return d:exec(SQL) end)
    local ok, res = coroutine.resume(co)
    H.ok(ok and res == 'turn', 'a long SELECT in a thread gives the server its turn')
    -- meanwhile another thread writes: it waits for the SELECT
    local co2 = coroutine.create(function() return d:exec('INSERT INTO cp_s (g, v) VALUES (1, 1)') end)
    local ok2, res2 = coroutine.resume(co2)
    H.ok(ok2 and res2 == 'turn' and coroutine.status(co2) == 'suspended', 'a write from another thread waits for it')
    local okM, errM = pcall(d.exec, d, 'SELECT COUNT(*) FROM cp_s')
    H.ok(not okM and tostring(errM):find('run this one from a thread', 1, true) ~= nil,
        'a call that cannot wait is refused, not mixed in: ' .. tostring(errM))
    while coroutine.status(co) == 'suspended' do ok, res = coroutine.resume(co) end
    H.ok(ok and type(res) == 'table' and res.n == 50, 'the SELECT finishes')
    H.ok(turns > 3, 'after several turns (' .. turns .. ')')
    H.eq(Show(res.rows), Show(plain.rows), 'with the same answer as without turns (the waiting insert is not in it)')
    while coroutine.status(co2) == 'suspended' do ok2, res2 = coroutine.resume(co2) end
    H.ok(ok2 and res2.insertId == 30001, 'then the write runs')
    H.eq(d:exec('SELECT COUNT(*) FROM cp_s').rows[1][1], 30001, 'and is there')
    local co3 = coroutine.create(function() return d:exec('SELECT SUM(v * 1000000000000000) FROM cp_s') end)
    local ok3, res3 = coroutine.resume(co3)
    while ok3 and coroutine.status(co3) == 'suspended' do ok3, res3 = coroutine.resume(co3) end
    H.ok(not ok3, 'a sliced SELECT that fails: ' .. tostring(res3))
    H.eq(d.busy, false, 'leaves the engine free')
    H.eq(d:exec('SELECT COUNT(*) FROM cp_s WHERE g = 1').rows[1][1], 601, 'and it keeps answering')
    d.slice = nil
end

-- 9.13 one global table: the engine is CP.Storage.MemSQL
H.eq(CP.MemSQL, nil, 'modules/storage defines no CP.MemSQL (CP.Storage is its one global table)')
H.eq(CP.Storage.MemSQL, M, 'the engine is CP.Storage.MemSQL')

os.execute(('rm -rf \'%s\''):format(TMP))
return H
