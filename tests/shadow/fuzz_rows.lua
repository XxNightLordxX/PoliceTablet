-- tests/shadow/fuzz_rows.lua · random row queries and writes, compared in shadow mode (lua5.4 tests/run.lua --fuzz):
-- SELECT with WHERE, ORDER BY (with the id as the last key: rows tied on every key come back in an order MariaDB
-- does not define), LIMIT / OFFSET, LEFT JOIN, IN / EXISTS subqueries and expressions; UPDATE, DELETE,
-- INSERT IGNORE ... SELECT (ordered), INSERT ... ON DUPLICATE KEY UPDATE, UNIQUE conflicts and AUTO_INCREMENT.
-- FUZZ_SEED picks the data and statements, FUZZ_N how many. An UPDATE that fails on a UNIQUE key reports the first
-- conflicting row in the order MariaDB's plan reads the rows (index or table order): that error text can differ.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local SEED = tonumber(os.getenv('FUZZ_SEED')) or 1
local NQ = tonumber(os.getenv('FUZZ_N')) or 400
local TIES = os.getenv('FUZZ_TIES') == '1'
math.randomseed(SEED)
local function pick(t) return t[math.random(#t)] end

H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_rows (
  id INT AUTO_INCREMENT PRIMARY KEY,
  a INT NULL, b INT NOT NULL DEFAULT 0, t VARCHAR(20) NULL, k VARCHAR(20) NOT NULL DEFAULT 'x',
  d DECIMAL(6,2) NULL, flag TINYINT(1) NOT NULL DEFAULT 0, dt DATETIME NULL,
  UNIQUE KEY uk (k, b), KEY idx_a (a)
)]])
H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_side (
  k VARCHAR(20) PRIMARY KEY, n INT NOT NULL DEFAULT 0, label VARCHAR(20) NULL
)]])
H.sql('DELETE FROM cp_zz_rows')
H.sql('DELETE FROM cp_zz_side')
local INTS = { -1, 0, 1, 2, 3, 'NULL' }
local TEXTS = { "'a'", "'A'", "'b'", "'B '", "'é'", "'e'", "''", "'x,y'", 'NULL' }
local KEYS = { "'a'", "'b'", "'e'", "'x'", "'zz'" }
for i = 1, 120 do
    H.sql(('INSERT IGNORE INTO cp_zz_rows (a, b, t, k, d, flag, dt) VALUES (%s, %d, %s, %s, %s, %d, %s)'):format(pick(INTS),
        math.random(0, 9), pick(TEXTS), pick(KEYS), pick({ '0.00', '1.50', '-2.25', 'NULL' }), math.random(0, 1),
        pick({ "'2026-09-01 10:00:00'", "'2026-09-02 00:00:00'", 'NULL' })))
end
H.sql("INSERT INTO cp_zz_side (k, n, label) VALUES ('a', 1, 'A-side'), ('b', 2, NULL), ('x', 3, 'X'), ('q', 4, 'Q')")

local params
local function lit(kind)
    if kind == 'int' then
        if math.random() < 0.3 then params[#params + 1] = pick({ -1, 0, 1, 2, 3 }); return '?' end
        return tostring(pick({ -1, 0, 1, 2, 3 }))
    end
    if math.random() < 0.3 then params[#params + 1] = pick({ 'a', 'A', 'b', 'é', 'e', '', 'x', 'q' }); return '?' end
    return pick({ "'a'", "'A'", "'b'", "'é'", "'e'", "''", "'x'" })
end
local function leaf()
    local r = math.random(1, 10)
    if r == 1 then return ('r.%s %s %s'):format(pick({ 'a', 'b', 'flag' }), pick({ '=', '<>', '<', '>=', '>' }), lit('int')) end
    if r == 2 then return ('r.%s %s %s'):format(pick({ 't', 'k' }), pick({ '=', '<>', '<', '>' }), lit('text')) end
    if r == 3 then return ('r.%s IS %sNULL'):format(pick({ 'a', 't', 'd', 'dt' }), pick({ '', 'NOT ' })) end
    if r == 4 then return ('r.t %sIN (%s, %s)'):format(pick({ '', 'NOT ' }), lit('text'), lit('text')) end
    if r == 5 then return ('r.a %sIN (%s, %s)'):format(pick({ '', 'NOT ' }), lit('int'), lit('int')) end
    if r == 6 then return ('r.t LIKE %s'):format(pick({ "'a%'", "'%b%'", "'_'", "'x,%'", "'%'" })) end
    if r == 7 then return ('r.k IN (SELECT s.k FROM cp_zz_side s WHERE s.n > %s)'):format(lit('int')) end
    if r == 8 then return ('EXISTS (SELECT 1 FROM cp_zz_side s WHERE s.k = r.k AND s.label IS %sNULL)'):format(pick({ '', 'NOT ' })) end
    if r == 9 then return ('r.dt > %s'):format(pick({ "'2026-09-01 12:00:00'", 'NOW() - INTERVAL 30 SECOND', "'2026-09-01'" })) end
    return ('r.d %s %s'):format(pick({ '=', '>', '<' }), pick({ '0', '1.5', '-2.25' }))
end
local function cond(depth)
    depth = depth or 0
    local r = math.random()
    if depth < 2 and r < 0.3 then
        local parts = {}
        for i = 1, math.random(2, 3) do parts[i] = cond(depth + 1) end
        return '(' .. table.concat(parts, pick({ ' AND ', ' OR ' })) .. ')'
    end
    return leaf()
end
local function expr()
    return pick({ 'r.a', 'r.b', 'r.t', 'r.k', 'r.d', 'r.flag', 'r.dt', 'r.a + r.b', 'r.b * 2', 'r.d * 2', 'COALESCE(r.a, -9)',
        'IF(r.flag = 1, r.t, r.k)', "CASE WHEN r.a > 1 THEN 'big' WHEN r.a IS NULL THEN NULL ELSE 'small' END", 'LOWER(r.t)',
        'CHAR_LENGTH(r.t)', 'UNIX_TIMESTAMP(r.dt)', "DATE_FORMAT(r.dt, '%Y-%m-%d %H')", 'GREATEST(r.b, 2)', 'NULLIF(r.b, 0)',
        'ROUND(r.d)', 's.n', 's.label', 'r.a - r.b', "SUBSTRING_INDEX(r.t, ',', 1)" })
end
local function orderKey()
    return pick({ 'r.a', 'r.b', 'r.t', 'r.k', 'r.d', 'r.dt', 'r.flag', 's.n' }) .. pick({ '', ' DESC' })
end
local nOk, nErr = 0, 0
for q = 1, NQ do
    params = {}
    local r = math.random(1, 10)
    local sql
    if r <= 6 then
        local items = {}
        for i = 1, math.random(1, 4) do items[i] = expr() .. ' AS e' .. i end
        items[#items + 1] = 'r.id'
        local join = math.random() < 0.4 and ' LEFT JOIN cp_zz_side s ON s.k = r.k' or ' LEFT JOIN cp_zz_side s ON 1 = 0'
        local order = ''
        if math.random() < 0.8 then
            local keys = {}
            for i = 1, math.random(1, 2) do keys[i] = orderKey() end
            if not TIES then keys[#keys + 1] = 'r.id' .. pick({ '', ' DESC' }) end
            order = ' ORDER BY ' .. table.concat(keys, ', ')
        end
        local limit = ''
        if order ~= '' and math.random() < 0.5 then
            limit = (' LIMIT %d'):format(math.random(1, 10))
            if math.random() < 0.3 then limit = limit .. (' OFFSET %d'):format(math.random(0, 5)) end
        end
        sql = ('SELECT %s FROM cp_zz_rows r%s%s%s%s'):format(table.concat(items, ', '), join,
            math.random() < 0.8 and (' WHERE ' .. cond()) or '', order, limit)
    elseif r == 7 then
        local set = pick({ 'a = r.a + 1', 'b = r.b + 1', 't = LOWER(r.t)', 'd = r.d * 2', 'flag = 1 - r.flag',
            "t = IF(r.a > 0, 'pos', r.t)", 'a = NULL', 'dt = NOW()', 'b = GREATEST(r.b - 1, 0)' })
        local where = cond()
        -- b is part of the UNIQUE key: a change of b on several rows may conflict, and which row MariaDB reports
        -- depends on the order its plan reads the rows, so such an UPDATE touches one row
        if set:find('^b ') then where = ('(%s) AND r.id = %d'):format(where, math.random(1, 200)) end
        sql = ('UPDATE cp_zz_rows r SET r.%s WHERE %s'):format(set, where)
    elseif r == 8 then
        sql = ('DELETE FROM cp_zz_rows WHERE %s AND id > %d'):format(cond():gsub('r%.', ''), math.random(60, 200))
    elseif r == 9 then
        sql = ("INSERT INTO cp_zz_rows (a, b, t, k) VALUES (%s, %d, %s, %s) ON DUPLICATE KEY UPDATE a = COALESCE(a, 0) + 1, t = VALUES(t)"):format(
            lit('int'), math.random(0, 9), lit('text'), pick(KEYS))
    else
        sql = ("INSERT IGNORE INTO cp_zz_rows (a, b, t, k) SELECT r.b, r.b + %d, r.t, r.k FROM cp_zz_rows r WHERE %s ORDER BY r.id LIMIT 3"):format(
            math.random(0, 3), cond())
    end
    local okQ = pcall(MySQL.query.await, sql, params)
    if okQ then nOk = nOk + 1 else nErr = nErr + 1 end
end
print(('REPORT fuzz_rows seed %d: %d statements ran on MariaDB, %d failed there'):format(SEED, nOk, nErr))
return H
