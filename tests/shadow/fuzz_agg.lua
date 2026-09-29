-- tests/shadow/fuzz_agg.lua · random aggregate queries, compared in shadow mode (lua5.4 tests/run.lua --fuzz): SUM /
-- COUNT / MAX / MIN over CASE, AND / OR / NOT, IN lists, IS NULL, column and parameter comparisons (integer, DECIMAL,
-- DATETIME and case / accent / trailing-space variants of text), GROUP BY one to three columns (NULLs included), and
-- SUBSTRING_INDEX(GROUP_CONCAT(... ORDER BY ...), ',', 1) with NULL and tied keys. FUZZ_SEED picks the data and queries,
-- FUZZ_N how many. GROUP BY uses a text column without case variants: grouping by a text whose rows differ in case
-- shows an arbitrary member on MariaDB (it depends on the plan), which nothing can match.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local SEED = tonumber(os.getenv('FUZZ_SEED')) or 1
local NQ = tonumber(os.getenv('FUZZ_N')) or 400
math.randomseed(SEED)
local function pick(t) return t[math.random(#t)] end

H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_fuzz (
  id INT AUTO_INCREMENT PRIMARY KEY,
  a INT NULL, b INT NULL, c SMALLINT NULL,
  t VARCHAR(20) NULL, u VARCHAR(20) NULL, k VARCHAR(20) NULL,
  d DECIMAL(6,2) NULL, flag TINYINT(1) NULL,
  dt DATETIME NULL,
  KEY idx_t (t), KEY idx_a (a)
)]])
H.sql('DELETE FROM cp_zz_fuzz')
local INTS = { -1, 0, 1, 2, 3, 'NULL' }
local TEXTS = { "'a'", "'A'", "'b'", "'B '", "'b'", "'é'", "'e'", "'E'", "''", "'x,y'", "'z'", 'NULL' }
local DECS = { '0.00', '1.50', '-2.25', '10.00', 'NULL' }
local vals = {}
for i = 1, 160 do
    vals[#vals + 1] = ('(%s, %s, %s, %s, %s, %s, %s, %s, %s)'):format(pick(INTS), pick(INTS), pick(INTS), pick(TEXTS), pick(TEXTS),
        pick({ "'a'", "'b'", "'e'", "'x,y'", "''", 'NULL' }),
        pick(DECS), pick({ '0', '1', 'NULL' }), pick({ "'2026-09-01 10:00:00'", "'2026-09-02 00:00:00'", "'2026-09-01 23:59:59'", 'NULL' }))
end
H.sql('INSERT INTO cp_zz_fuzz (a, b, c, t, u, k, d, flag, dt) VALUES ' .. table.concat(vals, ', '))

local ICOLS = { 'a', 'b', 'c', 'flag' }
local TCOLS = { 't', 'u' }
local params
local function lit(kind)
    if kind == 'int' then
        if math.random() < 0.25 then params[#params + 1] = pick({ -1, 0, 1, 2, 3 }); return '?' end
        return tostring(pick({ -1, 0, 1, 2, 3 }))
    end
    if math.random() < 0.25 then params[#params + 1] = pick({ 'a', 'A', 'b', 'B ', 'é', 'e', '', 'x,y', 'q' }); return '?' end
    return pick({ "'a'", "'A'", "'b'", "'B '", "'é'", "'e'", "''", "'q'" })
end
local leaf
leaf = function()
    local r = math.random(1, 9)
    if r == 1 then return ('r.%s %s %s'):format(pick(ICOLS), pick({ '=', '<>', '<', '>=', '<=', '>' }), lit('int')) end
    if r == 2 then return ('r.%s %s %s'):format(pick(TCOLS), pick({ '=', '<>' }), lit('text')) end
    if r == 3 then return ('r.%s IS %sNULL'):format(pick({ 'a', 't', 'd', 'dt', 'flag' }), pick({ '', 'NOT ' })) end
    if r == 4 then return ('r.%s %sIN (%s, %s)'):format(pick(TCOLS), pick({ '', 'NOT ' }), lit('text'), lit('text')) end
    if r == 5 then return ('r.%s %sIN (%s, %s%s)'):format(pick(ICOLS), pick({ '', 'NOT ' }), lit('int'), lit('int'), math.random() < 0.3 and ', NULL' or '') end
    if r == 6 then return ('r.d %s %s'):format(pick({ '=', '>', '<' }), pick({ '0', '1.5', '-2.25', '10' })) end
    if r == 7 then return ('r.%s = r.%s'):format(pick(ICOLS), pick(ICOLS)) end
    if r == 8 then return ('r.%s = r.%s'):format(pick(TCOLS), pick(TCOLS)) end
    return ('r.flag = %s'):format(pick({ '0', '1' }))
end
local function cond(depth)
    depth = depth or 0
    local r = math.random()
    if depth < 2 and r < 0.35 then
        local n = math.random(2, 4)
        local parts = {}
        for i = 1, n do parts[i] = cond(depth + 1) end
        return '(' .. table.concat(parts, pick({ ' AND ', ' OR ' })) .. ')'
    end
    if depth < 2 and r < 0.4 then return 'NOT ' .. cond(depth + 1) end
    return leaf()
end
local function value()
    return pick({ '1', '0', 'r.a', 'r.b', 'r.d', 'r.c', 'NULL', '2.5', 'r.flag' })
end
local function agg()
    local r = math.random(1, 8)
    if r == 1 then return ('SUM(CASE WHEN %s THEN %s ELSE %s END)'):format(cond(), value(), value()) end
    if r == 2 then return ('SUM(CASE WHEN %s THEN %s END)'):format(cond(), value()) end
    if r == 3 then return ('COUNT(CASE WHEN %s THEN 1 END)'):format(cond()) end
    if r == 4 then return ('MAX(CASE WHEN %s THEN r.%s END)'):format(cond(), pick({ 'dt', 'a', 'd', 'id', 'flag' })) end
    if r == 5 then return ('MIN(CASE WHEN %s THEN r.%s END)'):format(cond(), pick({ 'dt', 'b', 'd', 'id' })) end
    if r == 6 then
        local k1 = pick({ 'r.a', 'r.dt', 'r.t', 'r.d', 'r.flag', 'r.c' })
        return ("SUBSTRING_INDEX(GROUP_CONCAT(r.%s ORDER BY %s%s, r.id%s SEPARATOR ','), ',', 1)"):format(pick({ 't', 'u', 'a', 'd' }), k1,
            pick({ '', ' DESC' }), pick({ '', ' DESC' }))
    end
    if r == 7 then return ('COUNT(*)') end
    return ('SUM(r.%s)'):format(pick({ 'a', 'b', 'd', 'c', 'flag' }))
end
local GROUPS = { {}, { 'r.k' }, { 'r.a' }, { 'r.k', 'r.a' }, { 'r.flag', 'r.k' }, { 'r.a', 'r.b', 'r.k' }, { 'r.d' }, { 'r.dt' } }
local ok, bad = 0, 0
for q = 1, NQ do
    params = {}
    local g = pick(GROUPS)
    local items = {}
    for i, col in ipairs(g) do items[#items + 1] = col .. ' AS g' .. i end
    for i = 1, math.random(1, 5) do items[#items + 1] = agg() .. ' AS x' .. i end
    local where = math.random() < 0.7 and (' WHERE ' .. cond()) or ''
    local sql = 'SELECT ' .. table.concat(items, ', ') .. ' FROM cp_zz_fuzz r' .. where
        .. (#g > 0 and (' GROUP BY ' .. table.concat(g, ', ')) or '')
    local okQ = pcall(MySQL.query.await, sql, params)
    if okQ then ok = ok + 1 else bad = bad + 1 end
end
print(('REPORT fuzz_agg seed %d: %d queries ran on MariaDB, %d failed there'):format(SEED, ok, bad))

return H
