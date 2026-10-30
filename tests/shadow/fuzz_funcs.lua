-- Random expressions, compared in shadow mode (lua5.4 tests/run.lua --fuzz): arithmetic on

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local SEED = tonumber(os.getenv('FUZZ_SEED')) or 1
local NQ = tonumber(os.getenv('FUZZ_N')) or 400
math.randomseed(SEED + 1000)
local function Pick(t) return t[math.random(#t)] end
-- one of the alternatives, evaluated only when chosen (so an unchosen one adds no parameter)
local function Lazy(t)
    local v = t[math.random(#t)]
    if type(v) == 'function' then return v() end
    return v
end

H.sql([[CREATE TABLE IF NOT EXISTS cp_zz_fn (
  id INT AUTO_INCREMENT PRIMARY KEY,
  i INT NULL, s SMALLINT NULL, ti TINYINT NULL, flag TINYINT(1) NULL,
  d DECIMAL(6,2) NULL, t VARCHAR(12) NULL, e ENUM('none','held','paid') NOT NULL DEFAULT 'none',
  dt DATETIME NULL, dd DATE NULL, j JSON NULL
)]])
H.sql('DELETE FROM cp_zz_fn')
local DOCS = {
    [['{"cash":{"B":260,"status":"paid","amount":260},"points":{"bonuses":[{"id":"fast_finish","points":12},{"id":"no_vehicle_damage","points":10}],"final":61},"flagged":null,"xpCounted":1,"label":"A \\"quoted\\" one"}']],
    [['{"cash":{"B":0,"status":"none"},"points":{"bonuses":[],"final":0},"flagged":true}']],
    [['{"a":[1,2,3],"b":{"c":"x"},"n":1.50,"z":false}']],
    [['[1,"two",{"three":3}]']],
    '\'{}\'',
    'NULL',
}
-- (i stays far from INT's limits: i * i next to a DECIMAL would need more than the engine's 18 decimal digits,
-- which it refuses; fuzz_store covers the limits)
for k = 1, 40 do
    H.sql(
        ('INSERT INTO cp_zz_fn (i, s, ti, flag, d, t, e, dt, dd, j) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)'):format(
            Pick({ '0', '1', '-7', '42', '99999', 'NULL' }), Pick({ '0', '5', '-300', '32767', 'NULL' }),
            Pick({ '0', '1', '-128', '127', 'NULL' }), Pick({ '0', '1', 'NULL' }),
            Pick({ '0.00', '1.25', '-99.99', '9999.99', '0.5', 'NULL' }),
            Pick({ '\'a\'', '\'Abc\'', '\'é\'', '\'12\'', '\'1.5x\'', '\'\'', '\'  pad \'', '\'x,y,z\'', 'NULL' }),
            Pick({ '\'none\'', '\'held\'', '\'paid\'' }),
            Pick({ '\'2026-09-01 10:00:00\'', '\'2026-02-28 23:59:59\'', '\'2025-12-31 00:00:00\'', 'NULL' }),
            Pick({ '\'2026-09-01\'', '\'2024-02-29\'', 'NULL' }), Pick(DOCS)))
end

local params
local function P(v) params[#params + 1] = v; return '?' end
local NUMS = { 'i', 's', 'ti', 'flag', 'd', '1', '0', '-3', '2.5', '0.1', '1e2', '\'7\'', '\'2.5\'', 't', 'NULL', 'id' }
-- In UPDATE / DELETE no text column is read as a number: MariaDB counts a warning for each such read of a text
-- that is no number ("Truncated incorrect DOUBLE value"), as often as its plan evaluates it; the engine counts
-- only the warnings of storing values (see memsql.lua, section 7).
local NUMS_W = { 'i', 's', 'ti', 'flag', 'd', '1', '0', '-3', '2.5', '0.1', '1e2', '\'7\'', '\'2.5\'', 'NULL', 'id' }
-- UNION ALL branches get numbers only: a text column would group rows that differ only in case (which one MariaDB
-- shows depends on its plan), and a text branch next to COALESCE / IF / GREATEST of decimals with different scales
-- shows MariaDB's text of the chosen argument ('1', not '1.00'), which the engine does not keep (memsql.lua header).
local NUMS_U = { 'i', 's', 'ti', 'flag', 'd', '1', '0', '-3', '2.5', '0.1', '1e2', 'NULL', 'id' }
local WRITE, UNION = false, false
local function Nums() return Pick((UNION and NUMS_U) or (WRITE and NUMS_W) or NUMS) end
local function Num()
    local r = math.random(1, 12)
    if r == 1 then return P(Pick({ 1, 0, -5, 3, 2.5, 0.25, 1000000 })) end
    if r == 2 then return ('(%s + %s)'):format(Nums(), Nums()) end
    if r == 3 then return ('(%s - %s)'):format(Nums(), Nums()) end
    if r == 4 then return ('(%s * %s)'):format(Nums(), Nums()) end
    if r == 5 then return ('COALESCE(%s, %s)'):format(Nums(), Nums()) end
    if r == 6 then return ('ROUND(%s)'):format(Nums()) end
    if r == 7 then return ('GREATEST(%s, %s)'):format(Nums(), Nums()) end
    if r == 8 then
        return ('IF(%s, %s, %s)'):format(Pick({ 'flag', 'i > 0', 't IS NULL', '1', '0' }), Nums(), Nums())
    end
    if r == 9 then return ('NULLIF(%s, %s)'):format(Nums(), Nums()) end
    if r == 10 then return ('CHAR_LENGTH(%s)'):format(Pick({ 't', 'j', '\'héllo\'', 'NULL' })) end
    if r == 11 then
        return ('TIMESTAMPDIFF(%s, %s, %s)'):format(Pick({ 'SECOND', 'MINUTE', 'HOUR', 'DAY' }),
            Pick({ 'dt', 'dd', '\'2026-09-01 00:00:00\'' }), Pick({ 'NOW()', 'dt', '\'2026-09-02 12:30:00\'' }))
    end
    return Nums()
end
local function Jpath()
    return Pick({
        '\'$.cash.status\'',
        '\'$.cash.B\'',
        '\'$.points.bonuses[0].id\'',
        '\'$.points.bonuses[*].id\'',
        '\'$.flagged\'',
        '\'$.xpCounted\'',
        '\'$.a[1]\'',
        '\'$.b.c\'',
        '\'$.n\'',
        '\'$[2].three\'',
        '\'$.missing\'',
        '\'$.label\'',
        '\'$\'',
    })
end
local function Text()
    local r = math.random(1, 12)
    if r == 1 then return ('JSON_UNQUOTE(JSON_EXTRACT(j, %s))'):format(Jpath()) end
    if r == 2 then return ('JSON_EXTRACT(j, %s)'):format(Jpath()) end
    if r == 3 then return ('JSON_VALUE(j, %s)'):format(Jpath()) end
    if r == 4 then return ('JSON_TYPE(JSON_EXTRACT(j, %s))'):format(Jpath()) end
    if r == 5 then
        return ('JSON_SET(COALESCE(j, %s), %s, %s)'):format('\'{}\'',
            Pick({ '\'$.cash.status\'', '\'$.new\'', '\'$.points.final\'', '\'$.a[5]\'' }), Lazy({
                '\'x\'',
                '1',
                '2.50',
                'TRUE',
                'NULL',
                function() return P('par') end,
                function() return P(7) end,
            }))
    end
    if r == 6 then
        return ('JSON_REMOVE(j, %s)'):format(
            Pick({ '\'$.cash\'', '\'$.a[0]\'', '\'$.points.bonuses[1]\'', '\'$.nope\'' }))
    end
    if r == 7 then
        return ('DATE_FORMAT(%s, \'%s\')'):format(Pick({ 'dt', 'dd', 'NOW()' }),
            Pick({ '%Y-%m-%d', '%H:%i:%s', '%d/%m/%y %W %M', '%j %a %b %e %c %k %l %p' }))
    end
    if r == 8 then
        return ('SUBSTRING_INDEX(%s, %s, %s)'):format(Pick({ 't', '\'a,b,c\'', 'j' }),
            Pick({ '\',\'', '\'b\'', '\'\'' }), Pick({ '1', '2', '-1', '0', '-2' }))
    end
    if r == 9 then return ('LOWER(%s)'):format(Pick({ 't', '\'ÀBC\'', 'j' })) end
    if r == 10 then
        return ('FROM_UNIXTIME(%s)'):format(Lazy({
            '0',
            '1790000000',
            'i',
            function() return P(1790000123) end,
        }))
    end
    if r == 11 then
        return ('DATE(%s)'):format(Pick({ 'dt', 'dd', '\'2026-09-01 23:00:00\'', 'NOW()', 'dt - INTERVAL 30 HOUR' }))
    end
    return Pick({
        't',
        'e',
        'CASE WHEN i > 0 THEN \'pos\' WHEN i < 0 THEN \'neg\' END',
        'IF(flag, \'y\', \'n\')',
        'JSON_VALID(j)',
        'JSON_VALID(t)',
        'JSON_CONTAINS(JSON_EXTRACT(j, \'$.points.bonuses[*].id\'), \'"fast_finish"\')',
        'UNIX_TIMESTAMP(dt)',
        'UNIX_TIMESTAMP(dd)',
        'dt + INTERVAL 90 MINUTE',
        'dt - INTERVAL 3600 SECOND',
        'dd + INTERVAL 2 HOUR',
    })
end
-- constants only (INSERT ... VALUES: MariaDB would read columns of the row being built, which the engine refuses)
local function Cnum()
    return Lazy({
        '1',
        '0',
        '-3',
        '2.5',
        '0.1',
        '1e2',
        '\'7\'',
        '\'2.5\'',
        'NULL',
        '(2 + 3)',
        '(7 * -2)',
        'ROUND(2.5)',
        'GREATEST(1, 9)',
        function() return P(Pick({ 1, 0, -5, 3, 2.5, 0.25, 1000000 })) end,
    })
end
local function Ctext()
    return Lazy({
        '\'short\'',
        '\'é\'',
        '\'\'',
        'LOWER(\'ÀBC\')',
        'DATE_FORMAT(\'2026-09-01 10:11:12\', \'%H:%i\')',
        'SUBSTRING_INDEX(\'a,b\', \',\', 1)',
        function() return P('par') end,
    })
end
local function Cond()
    return Lazy({
        function() return ('%s %s %s'):format(Num(), Pick({ '=', '<>', '<', '>=' }), Num()) end,
        function()
            return ('%s = %s'):format(Text(), Lazy({
                '\'paid\'',
                '\'x\'',
                '\'none\'',
                '\'1\'',
                function() return P('paid') end,
            }))
        end,
        function()
            return ('t %s %s'):format(Pick({ '=', '<', '>', 'LIKE' }), Lazy({
                '\'a\'',
                '\'ABC\'',
                '\'%b%\'',
                '\'1.5x\'',
                '\'12\'',
                function() return P('é') end,
            }))
        end,
        function()
            return ('dt %s %s'):format(Pick({ '<', '>=', '=' }),
                Pick({ '\'2026-09-01\'', '\'2026-09-01 10:00:00\'', 'NOW() - INTERVAL 24 HOUR', 'dd' }))
        end,
        function()
            return ('e %s %s'):format(Pick({ '=', '<>', '<' }), Pick({ '\'held\'', '\'paid\'', '2', '\'HELD\'' }))
        end,
        function()
            return ('%s IS NULL'):format(Lazy({
                'j',
                function() return 'JSON_EXTRACT(j, ' .. Jpath() .. ')' end,
                't',
                'dd',
            }))
        end,
        function() return ('i IN (SELECT x.i FROM cp_zz_fn x WHERE x.id < %d)'):format(math.random(1, 40)) end,
        'EXISTS (SELECT 1 FROM cp_zz_fn x WHERE x.i = cp_zz_fn.i AND x.id <> cp_zz_fn.id)',
        function()
            return ('(SELECT COUNT(*) FROM cp_zz_fn x WHERE x.t = cp_zz_fn.t) > %d'):format(math.random(0, 3))
        end,
    })
end
-- DELETE conditions: no text read as a number, no text read as a date that is none (both warn in MariaDB)
local function Wcond()
    return Lazy({
        function() return ('%s %s %s'):format(Num(), Pick({ '=', '<>', '<', '>=' }), Num()) end,
        function()
            return ('JSON_UNQUOTE(JSON_EXTRACT(j, %s)) = %s'):format(Jpath(), Lazy({
                '\'paid\'',
                '\'x\'',
                function() return P('paid') end,
            }))
        end,
        function()
            return ('t %s %s'):format(Pick({ '=', '<', '>', 'LIKE' }), Lazy({
                '\'a\'',
                '\'ABC\'',
                '\'%b%\'',
                '\'1.5x\'',
                '\'12\'',
                function() return P('é') end,
            }))
        end,
        function()
            return ('dt %s %s'):format(Pick({ '<', '>=', '=' }),
                Pick({ '\'2026-09-01\'', '\'2026-09-01 10:00:00\'', 'NOW() - INTERVAL 24 HOUR', 'dd' }))
        end,
        function()
            return ('e %s %s'):format(Pick({ '=', '<>', '<' }), Pick({ '\'held\'', '\'paid\'', '2', '\'HELD\'' }))
        end,
        function() return ('%s IS NULL'):format(Pick({ 'j', 't', 'dd' })) end,
        function() return ('i IN (SELECT x.i FROM cp_zz_fn x WHERE x.id < %d)'):format(math.random(1, 40)) end,
        'EXISTS (SELECT 1 FROM cp_zz_fn x WHERE x.i = cp_zz_fn.i AND x.id <> cp_zz_fn.id)',
    })
end
local nOk, nErr = 0, 0
for q = 1, NQ do
    params = {}
    local r = math.random(1, 10)
    WRITE, UNION = r >= 8, r == 7
    local sql
    if r <= 6 then
        local items = {}
        for k = 1, math.random(1, 4) do items[k] = (math.random() < 0.5 and Num() or Text()) .. ' AS c' .. k end
        sql = ('SELECT %s%s, id FROM cp_zz_fn%s ORDER BY id'):format(math.random() < 0.1 and 'DISTINCT ' or '',
            table.concat(items, ', '), math.random() < 0.6 and (' WHERE ' .. Cond()) or '')
    elseif r == 7 then
        sql = ('SELECT u.v AS v, COUNT(*) AS n FROM (SELECT %s AS v FROM cp_zz_fn WHERE %s UNION ALL SELECT %s AS v FROM cp_zz_fn) u GROUP BY u.v ORDER BY u.v'):format(
            Num(), Cond(), Num())
    elseif r == 8 then
        local col = Pick({ 'i', 's', 'ti', 'flag', 'd', 't', 'e', 'dt', 'dd', 'j' })
        local ignore = math.random() < 0.3
        local val
        if col == 'dt' or col == 'dd' then
            -- MariaDB stores a zero date for a bad date with IGNORE (and for 0 or '2026-00-01' always), which the
            -- engine refuses (unsupported): dates get values that are dates, and bad text only without IGNORE
            val = Lazy({
                '\'2026-09-01 10:00\'',
                '\'2026-09-01\'',
                '\'2026/9/1 7:05\'',
                '\'20260901\'',
                '\'26-09-01 10\'',
                'NOW()',
                'NULL',
                'dt + INTERVAL 90 MINUTE',
                'FROM_UNIXTIME(1790000000)',
                'DATE(dt)',
                '\'2026-09-01 10:00:00x\'',
                '\'2026-09-01 10:00:00.1234567\'',
                function()
                    return ignore and '\'2025-12-31\''
                        or Pick({ '\'garbage\'', '\'2026-13-01\'', '\'2026-02-30\'', '-1', '\'x\'' })
                end,
            })
        else
            val = Lazy({
                Num,
                Text,
                '\'2026-09-01 10:00\'',
                '\'abc\'',
                '\'1e3\'',
                '99999999',
                '-129',
                '\'toolongtextvalue\'',
                'NULL',
                '\'held\'',
                '\'{"k":1}\'',
                '\' 7 \'',
                '\'7x\'',
                '\'1.234\'',
                '\'  2\'',
                '\'-0\'',
                '\'00002\'',
            })
        end
        sql = ('UPDATE %scp_zz_fn SET %s = %s WHERE id = %d'):format(ignore and 'IGNORE ' or '', col, val,
            math.random(1, 45))
    elseif r == 9 then
        local ignore = math.random() < 0.3
        local rows = {}
        for k = 1, math.random() < 0.7 and 1 or math.random(2, 3) do
            rows[k] = ('(%s, %s, %s, %s, %s, %s)'):format(
                Cnum(),
                Lazy({ Cnum, '\'1.234\'', '\'x\'', '123456.7', '\' 5 \'' }),
                Lazy({ Ctext, '\'toolongtextvalue\'', 'NULL', '\'toolong      \'' }),
                Pick({ '\'paid\'', '\'nope\'', 'NULL', '1', '2.5', '\'3\'', '\'HELD \'' }),
                ignore and Pick({ '\'2026-09-01\'', 'NOW()', 'NULL', '\'2026-09-01 10:00:00x\'' })
                    or Pick({ '\'2026-09-01\'', '\'2026-13-01\'', 'NOW()', 'NULL', '\'garbage\'', '\'2026-09-01 10\'' }),
                Pick({ '\'{"a":1}\'', '\'not json\'', 'NULL', '\'[]\'', '\'{"x": [1, 2]}\'', '\'[5.]\'' })
            )
        end
        sql = ('INSERT %sINTO cp_zz_fn (i, d, t, e, dt, j) VALUES %s'):format(ignore and 'IGNORE ' or '',
            table.concat(rows, ', '))
    else
        sql = ('DELETE FROM cp_zz_fn WHERE id > %d AND %s'):format(math.random(30, 60), Wcond())
    end
    local okQ = pcall(MySQL.query.await, sql, params)
    if okQ then nOk = nOk + 1 else nErr = nErr + 1 end
end
print(('REPORT fuzz_funcs seed %d: %d statements ran on MariaDB, %d failed there'):format(SEED, nOk, nErr))
return H
