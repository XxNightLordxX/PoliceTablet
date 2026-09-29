-- The shared layer, the migrations splitter and the harness itself.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local U = CP.U

-- round halves up
H.eq(U.round(2.5), 3, 'round 2.5')
H.eq(U.round(2.49), 2, 'round 2.49')
H.eq(U.round(1.25 * 7), 9, 'reinforced 7 hostiles -> 9')
H.eq(U.round(1.5 * 7), 11, 'heavy 7 -> 10.5 -> 11')
-- a true half that floating point stores just below .5 still rounds up (the same as CP.Cash pays)
H.ok(350 * 1.15 < 402.5, 'precondition: 350 x 1.15 is stored below 402.5')
H.eq(U.round(350 * 1.15), 403, '$350 x 1.15 = $402.50 -> $403')
H.eq(U.round(250 * 1.15), 288, '$250 x 1.15 = $287.50 -> $288')
H.eq(U.round(250 * 1.30), 325, 'exact amounts unchanged')
H.eq(U.round(402.4999), 402, 'a real x.4999 still rounds down')
H.eq(U.round(-2.5), -2, 'negative half rounds up (towards +inf)')
H.eq(U.round(0), 0, 'round 0')

-- deterministic rng
local a, b = U.rng(42), U.rng(42)
for _ = 1, 20 do H.eq(a:int(1, 100), b:int(1, 100), 'same seed same sequence') end
local r = U.rng(7)
local seen = {}
for _ = 1, 2000 do local v = r:int(1, 4); seen[v] = (seen[v] or 0) + 1; H.ok(v >= 1 and v <= 4, 'int in range') end
for i = 1, 4 do H.ok((seen[i] or 0) > 350, 'roughly uniform ' .. i) end
local sample = U.rng(3):sample({ 1, 2, 3, 4, 5, 6, 7, 8 }, 5)
H.eq(#sample, 5, 'sample size')

-- hashing is stable
H.eq(U.hash('2026-09-28'), U.hash('2026-09-28'), 'hash stable')
H.ok(U.hash('a') ~= U.hash('b'), 'hash differs')

-- paths
local t = { objectives = { { waves = { 7, 7, 6 } } } }
H.eq(U.getPath(t, 'objectives.1.waves')[3], 6, 'getPath')
U.setPath(t, 'objectives.1.count', 3)
H.eq(t.objectives[1].count, 3, 'setPath')

-- vectors
H.near(U.dist(vec3(0, 0, 0), vec3(3, 4, 0)), 5, 1e-9, 'dist')
H.near(U.distToPolyline(vec3(5, 5, 0), { vec3(0, 0, 0), vec3(10, 0, 0) }), 5, 1e-9, 'polyline dist')
H.eq(U.vecToTable(vec4(1, 2, 3, 4)).w, 4, 'vec4 to table')

-- colours
H.eq(U.contrastText('#0d1522'), '#ffffff', 'dark bg -> white text')
H.eq(U.contrastText('#f5f5f5'), '#111111', 'light bg -> dark text')
H.ok(not U.isHexColour('#12345'), 'bad hex')

-- db value helpers
H.ok(U.truthy(true) and U.truthy(1) and not U.truthy(0) and not U.truthy(nil), 'truthy')
H.eq(U.jsonField('{"a":1}').a, 1, 'jsonField string')
H.eq(U.clip('abcdef', 3), 'abc', 'clip')
-- clip never ends inside a UTF-8 character: MariaDB strict mode (utf8mb4) refuses the whole row (error 1366)
local longLabel = ('a'):rep(62) .. '— rear lot'
H.eq(U.clip(longLabel, 64), ('a'):rep(62), 'an em-dash cut at byte 64 is dropped whole')
H.ok(utf8.len(U.clip(longLabel, 64)) ~= nil, 'clip keeps valid UTF-8')
H.eq(U.clip('José', 4), 'Jos', 'a cut 2-byte letter is dropped')
H.eq(U.clip('José', 5), 'José', 'a whole 2-byte letter is kept')
H.eq(U.clip('ab😀', 5), 'ab', 'a cut 4-byte character is dropped')
H.eq(U.clip('ab😀', 6), 'ab😀', 'a whole 4-byte character is kept')

-- locale interpolation (unknown key returns the key)
H.eq(CP.L('no.such.key'), 'no.such.key', 'unknown key')

-- migrations splitter (statements end at line-ending semicolons, comments stripped)
H.load('modules/migrations/server.lua')
local sql = LoadResourceFile('Crimson-Police', 'sql/migrations/001_initial.sql')
local stmts = CP.Migrations._split(sql)
H.eq(#stmts, 14, '001 has 14 statements')
for _, s in ipairs(stmts) do H.ok(not s:find('%-%-'), 'no comments left in statement') end

-- the harness talks to MariaDB
H.sql('DELETE FROM cp_officers')
MySQL.insert.await('INSERT INTO cp_officers (citizenid, callsign, department) VALUES (?, ?, ?)',
    { 'T1', 'O\'Neil', 'sast' })
H.eq(MySQL.scalar.await('SELECT callsign FROM cp_officers WHERE citizenid = ?', { 'T1' }), 'O\'Neil', 'quote escaping')
H.eq(MySQL.update.await('UPDATE cp_officers SET xp = xp + ? WHERE citizenid = ?', { 5, 'T1' }), 1,
    'update affected rows')
local row = MySQL.single.await('SELECT xp, UNIX_TIMESTAMP(NOW()) AS now_ts FROM cp_officers WHERE citizenid = ?',
    { 'T1' })
H.eq(row.xp, 5, 'single row')
H.ok(row.now_ts > 1700000000, 'unix timestamp')
MySQL.insert.await('INSERT INTO cp_officers (citizenid, display_name) VALUES (?, ?)', { 'T2', U.clip(longLabel, 64) })
H.eq(MySQL.scalar.await('SELECT display_name FROM cp_officers WHERE citizenid = ?', { 'T2' }), ('a'):rep(62),
    'a clipped non-ASCII text is stored')

return H
