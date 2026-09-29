-- tests/shadow/fuzz_store.lua · storing values into typed columns, compared in shadow mode (lua5.4 tests/run.lua --fuzz):
-- every column type Crimson-Police uses (INT, TINYINT, TINYINT(1), SMALLINT, DECIMAL, VARCHAR, ENUM, DATETIME, DATE,
-- JSON, NOT NULL with and without a default) gets numbers, decimals, doubles, texts with and without a number in
-- them, dates in MariaDB's many spellings, JSON, booleans and NULL, through INSERT and UPDATE, in strict mode and
-- with IGNORE: the stored value, the error, and the warnings and notes (warningStatus, "Rows matched ... Warnings")
-- are compared. Then rows of several values at once: CHECK (JSON_VALID) failures with IGNORE, NULL into NOT NULL,
-- columns left out without a default, ON DUPLICATE KEY UPDATE conversions.
-- FUZZ_SEED 1 runs the whole grid; other seeds a random part of it and random multi-row statements.
-- Left out (the engine refuses them as unsupported): values MariaDB stores as a zero date or a date with a zero
-- month or day ('0000-00-00', 0, 300, '2026-00-01', and any bad date with IGNORE).
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local SEED = tonumber(os.getenv('FUZZ_SEED')) or 1
math.randomseed(SEED + 2000)
local function pick(t) return t[math.random(#t)] end

H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_store (
  id INT AUTO_INCREMENT PRIMARY KEY,
  i INT NULL, ti TINYINT NULL, b1 TINYINT(1) NULL, s SMALLINT NULL, d DECIMAL(6,2) NULL, t VARCHAR(12) NULL,
  t5 VARCHAR(5) NULL, e ENUM('none','held','paid') NOT NULL DEFAULT 'none', dt DATETIME NULL, dd DATE NULL, j JSON NULL,
  nn INT NOT NULL DEFAULT 5, ne ENUM('a','b') NOT NULL, nt VARCHAR(5) NOT NULL DEFAULT 'd',
  ndt DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, k VARCHAR(8) NULL, UNIQUE KEY uk (k)
)]])
H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_store_nd (
  id INT AUTO_INCREMENT PRIMARY KEY, k VARCHAR(5) NULL, nn INT NOT NULL, nt VARCHAR(5) NOT NULL, ne ENUM('a','b') NOT NULL
)]])

local VALUES = { 'NULL', '0.1', '0.5', '2.5', '-2.5', '-0.5', '1.234', '1.235', "'1.234'", "'1.235'", "'1.5'", "'2.5'", "'.5'",
    "'5.'", "'+3'", "'1,5'", "' 7 '", "'7 '", "'  2'", "'7x'", "'x'", "''", "' '", '1e2', '1.5e0', '1.234e0', "'1.234e0'",
    '(0.1e0 + 0.2e0)', '99999999', '-129', '300', "'toolongtextvalue'", "'abc          '", "'abcdefghijkl   '", "'garbage'", 'NOW()',
    "'held'", "'HELD'", "'held '", "' held'", "'nope'", "'2'", "'3'", "'4'", "'-1'", "'00002'", "'-0'", "'1e3'", "'0x10'", '2', '0',
    '4', '-1', "'{\"k\":1}'", "'not json'", "'[1, 2]'", "'\"s\"'", "'null'", "'[5.]'", "'\"\\\\q\"'", 'TRUE', 'FALSE', "DATE('2026-09-01')",
    '123456.7', "'9999.999'", "'9999.994'", "CHAR_LENGTH('abc')", "JSON_EXTRACT('{\"a\":1}', '$.a')", "JSON_EXTRACT('{\"a\":\"x\"}', '$.a')",
    '(1 = 1)', "('a' LIKE 'b')", '1e20', '(2 * 1e-7)', '1234567.5e0', '-0e0', "'2026-09-01 10:00:00'" }
-- dates: what MariaDB reads as a date in both modes, and what it refuses in strict mode (with IGNORE: a zero date)
local DATES = { 'NULL', "'2026-09-01'", "'2026-09-01 10:00'", "'2026-09-01 10'", "'2026-09-01 10:00:00'", "'2026-09-01 10:00:00.5'",
    "'2026-09-01T10:00:00'", "'2026/09/01'", "'2026-9-1'", "'26-09-01'", "'69-12-31'", "'70-01-01'", "'2026-09-01 10:00:00 '",
    "' 2026-09-01'", "'20260901'", "'20260901100000'", "'260901'", "'2609011000'", "'20260901T100000'", '20260901', '20260901100000',
    '260901', '20260901.5', 'NOW()', "DATE('2026-09-01')", 'NOW() + INTERVAL 3 HOUR', "'2026-09-01 10:00:00.9999999'", "'2026.09.01'",
    "'2026-09-01 1:2:3'", "'2026-09-01 10:00:'", "'2026-09-01 10.00.00'", "'2024-02-29'", "'9999-12-31 23:59:59'", "'1000-01-01'",
    "'2026-09-01x'", "'2026-09-01 10:00:00x'", "'2026-09-01 x'", "'2026-09-01 10::'", "'2026-09-01 10:00:00 PM'", "'2026-09-01T'" }
local BADDATES = { "'2026-13-01'", "'garbage'", "'2026-02-30'", "'2026-02-29'", "'2026-09-01 25:00:00'", "'2026-09-01 10:60:00'", "'x'",
    "''", "'2'", "'2026'", "'2026-09'", "'2026--09--01'", "'10000-01-01'", "'2026090110'", '2', '4', '-1', '1e2', '2.5', "'7x'", '99999999',
    "'{\"k\":1}'", 'TRUE' }
local DATECOLS = { dt = true, dd = true, ndt = true }
local COLS = { 'i', 'ti', 'b1', 's', 'd', 't', 't5', 'e', 'dt', 'dd', 'j', 'nn', 'ne', 'nt', 'ndt' }

local function try(sql, params)
    local ok = pcall(MySQL.query.await, sql, params or {})
    return ok
end

-- one value into one column: INSERT and UPDATE, strict and IGNORE; the stored value is read back
local nStmt = 0
local function cell(col, v, ignore)
    local ig = ignore and 'IGNORE ' or ''
    try('DELETE FROM cp_zz_store')
    try("INSERT INTO cp_zz_store (id, ne) VALUES (1, 'a')")
    try(('INSERT %sINTO cp_zz_store (%s) VALUES (%s)'):format(ig, col, v))
    try(('SELECT %s FROM cp_zz_store WHERE id > 1'):format(col))
    try(('UPDATE %scp_zz_store SET %s = %s WHERE id = 1'):format(ig, col, v))
    try(('SELECT %s FROM cp_zz_store WHERE id = 1'):format(col))
    nStmt = nStmt + 6
end

local grid = {}
for _, col in ipairs(COLS) do
    if DATECOLS[col] then
        for _, v in ipairs(DATES) do
            if not (col == 'ndt' and v == 'NULL') then
                grid[#grid + 1] = { col, v, false }
                grid[#grid + 1] = { col, v, true }
            end
        end
        for _, v in ipairs(BADDATES) do grid[#grid + 1] = { col, v, false } end
    else
        for _, v in ipairs(VALUES) do
            grid[#grid + 1] = { col, v, false }
            grid[#grid + 1] = { col, v, true }
        end
    end
end
if SEED == 1 then
    for _, g in ipairs(grid) do cell(g[1], g[2], g[3]) end
else
    for _ = 1, 150 do local g = pick(grid); cell(g[1], g[2], g[3]) end
end

-- several rows at once
local JS = { "'{\"a\":1}'", "'bad'", 'NULL', "'[]'", "'[5.]'", "'{\"x\": [1, 2]}'", "'\"s\"'" }
local NUMV = { '1', "' 8 '", "'x'", 'NULL', '2.5', "'7x'", '99999999999' }
local TXT = { "'a'", "'toolong'", "'b   '", 'NULL', '12.5', "'é'" }
local ENUMV = { "'a'", "'B'", "'c'", 'NULL', '2', "'2'", '0' }
local function row(k)
    return ('(%s, %s, %s, %s, %s)'):format(k and ("'" .. k .. "'") or 'NULL', pick(NUMV), pick(TXT), pick(ENUMV), pick(JS))
end
local nMulti = SEED == 1 and 120 or 80
for q = 1, nMulti do
    local r = math.random(1, 6)
    local ig = math.random() < 0.6 and 'IGNORE ' or ''
    if r == 1 then
        local rows = {}
        for n = 1, math.random(1, 4) do rows[n] = row(pick({ 'k1', 'k2', 'k3', 'k4', 'k5', 'k6' })) end
        try(('INSERT %sINTO cp_zz_store (k, nn, nt, ne, j) VALUES %s'):format(ig, table.concat(rows, ', ')))
    elseif r == 2 then
        try(('INSERT %sINTO cp_zz_store (k, nn, nt, ne, j) VALUES %s ON DUPLICATE KEY UPDATE nn = %s, nt = %s, j = %s, k = %s'):format(ig,
            row(pick({ 'k1', 'k2', 'k3' })), pick(NUMV), pick(TXT), pick(JS), pick({ 'k', "'k2'", "'k4'", "'k9'", 'NULL' })))
    elseif r == 3 then
        try(('UPDATE %scp_zz_store SET nn = %s, j = %s, ne = %s WHERE k IN (%s, %s)'):format(ig, pick(NUMV), pick(JS), pick(ENUMV),
            pick({ "'k1'", "'k2'", "'k3'" }), pick({ "'k4'", "'k5'", "'k6'" })))
    elseif r == 4 then
        try(('INSERT %sINTO cp_zz_store (k, nn, nt, ne, j) SELECT %s, nn, nt, ne, %s FROM cp_zz_store WHERE id > %d ORDER BY id LIMIT 3')
            :format(ig, pick({ 'NULL', 'LOWER(k)', "SUBSTRING_INDEX(k, 'k', -1)" }), pick({ 'j', "IF(id > 5, 'bad', '[]')", "'[]'" }),
                math.random(0, 20)))
    elseif r == 5 then
        -- columns left out that have no default
        local rows = {}
        for n = 1, math.random(1, 3) do rows[n] = ('(%s)'):format(pick({ "'a'", "'b'", 'NULL', "'toolong'" })) end
        try(('INSERT %sINTO cp_zz_store_nd (k) VALUES %s'):format(ig, table.concat(rows, ', ')))
        try(('INSERT %sINTO cp_zz_store_nd (k, nn) SELECT k, id FROM cp_zz_store WHERE id > %d LIMIT 2'):format(ig, math.random(0, 20)))
        try(('INSERT %sINTO cp_zz_store_nd (nn, nt, ne) VALUES (%s, %s, %s)'):format(ig, pick(NUMV), pick(TXT), pick(ENUMV)))
    else
        try(('UPDATE %scp_zz_store SET k = %s WHERE id = %d'):format(ig, pick({ "'k1'", "'k2'", "'k3'", 'NULL', "'toolongkey'" }), math.random(1, 30)))
    end
    try('SELECT * FROM cp_zz_store ORDER BY id')
end
print(('REPORT fuzz_store seed %d: %d grid statements, %d multi-row rounds'):format(SEED, nStmt, nMulti))
return H
