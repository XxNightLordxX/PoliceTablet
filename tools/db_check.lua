-- tools/db_check.lua · the checks of tools/db_check.sh on its throwaway MariaDB server (run it through that script).
-- docs/dev/TESTING.md "Real database check" says what each line means.
--
--   lua5.4 tools/db_check.lua <socket> [<runtime.jsonl dir>]
--
-- Prints one PASS/FAIL line per check and a SUMMARY line. Exit status: 0 every check passed, 1 a check failed.

local SOCK, RUNTIME = arg[1], arg[2]
if not SOCK then
    io.stderr:write('usage: lua5.4 tools/db_check.lua <socket> [<runtime sql log dir>]\n')
    os.exit(2)
end
local ROOT = (arg[0]:match('^(.*)/tools/[^/]*$') or '.') .. '/'
local RES = ROOT .. 'Crimson-Police/'

local function ReadFile(path)
    local f = assert(io.open(path, 'r'))
    local s = f:read('a')
    f:close()
    return s
end
local function Quote(s) return '\'' .. tostring(s):gsub('\\', '\\\\'):gsub('\'', '\'\'') .. '\'' end

-- ---- the mysql client ----------------------------------------------------------------------------------------------

local CLIENT = 'mariadb --no-defaults -S ' .. Quote(SOCK) .. ' -uroot --default-character-set=utf8mb4 --batch'

local function Unescape(v)
    if v == 'NULL' then return nil end
    return (v:gsub('\\(.)', { n = '\n', t = '\t', ['\\'] = '\\', ['0'] = '\0' }))
end

-- Runs sql (one or more statements) on db; returns rows (named by the header line), or nil and the error text.
local function Q(db, sql, extra)
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, 'w'))
    f:write(sql, ';\n')
    f:close()
    local p = io.popen(('%s %s %s < %s 2>&1'):format(CLIENT, extra or '', db and Quote(db) or '', tmp))
    local out = p:read('a')
    local ok = p:close()
    os.remove(tmp)
    if not ok then return nil, out end
    local rows, header = {}, nil
    for line in out:gmatch('[^\n]+') do
        local cells = {}
        for cell in (line .. '\t'):gmatch('(.-)\t') do cells[#cells + 1] = cell end
        if not header then
            header = cells
        else
            local row = {}
            for i, name in ipairs(header) do row[name] = Unescape(cells[i] or 'NULL') end
            rows[#rows + 1] = row
        end
    end
    return rows
end
local function MustQ(db, sql)
    local rows, err = Q(db, sql)
    if not rows then error(('%s\n  %s'):format(err, sql:sub(1, 200)), 0) end
    return rows
end

-- Runs each statement of list on db in one client (--force goes on after an error); returns { [i] = error text }.
local function Each(db, list, preamble)
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, 'w'))
    local line, lastLine = 1, {}
    if preamble then
        f:write(preamble, ';\n')
        line = line + 1
    end
    for i, stmt in ipairs(list) do
        f:write(stmt, ';\n')
        for _ in stmt:gmatch('\n') do line = line + 1 end
        lastLine[i] = line
        line = line + 1
    end
    f:close()
    local p = io.popen(('%s --force %s < %s 2>&1 >/dev/null'):format(CLIENT, Quote(db), tmp))
    local out = p:read('a')
    p:close()
    os.remove(tmp)
    local errs, j = {}, 1
    for msg in out:gmatch('[^\n]+') do
        local at = tonumber(msg:match('^ERROR %d+ %([%w]+%) at line (%d+)'))
        if at then
            while lastLine[j] and lastLine[j] < at do j = j + 1 end
            if lastLine[j] then errs[j] = msg end
        end
    end
    return errs
end

-- ---- the report ----------------------------------------------------------------------------------------------------

local results, failed = {}, 0
local function Check(name, ok, detail)
    results[#results + 1] = { name = name, ok = ok, detail = detail or '' }
    if not ok then failed = failed + 1 end
    print(('%s  %-44s %s'):format(ok and 'PASS' or 'FAIL', name, detail or ''))
    io.stdout:flush()
end
local function Info(name, detail) print(('INFO  %-44s %s'):format(name, detail)) end
local function Some(list, n)
    n = n or 4
    local out = {}
    for i = 1, math.min(#list, n) do out[i] = list[i] end
    return table.concat(out, '; ') .. (#list > n and ('; and %d more'):format(#list - n) or '')
end

-- ---- the real migrations runner (modules/system/migrations.lua) on a database ---------------------------------------

local RUNNER_SRC = ReadFile(RES .. 'modules/system/migrations.lua')
local FILES = {}
for name in RUNNER_SRC:match('local FILES = (%b{})'):gmatch('\'([^\']+%.sql)\'') do FILES[#FILES + 1] = name end

-- oxmysql's MySQL.*.await on the mysql client: rows, or an error with MariaDB's message
local function Oxmysql(db)
    local function Run(sql, params)
        if type(params) == 'table' and #params > 0 then
            local i = 0
            sql = sql:gsub('%?', function()
                i = i + 1
                local v = params[i]
                return type(v) == 'number' and tostring(v) or Quote(v)
            end)
        end
        local rows, err = Q(db, sql)
        if not rows then error(err, 0) end
        return rows
    end
    return {
        query = { await = Run },
        insert = { await = function(sql, p) Run(sql, p) return 1 end },
        scalar = {
            await = function(sql, p)
                local r = Run(sql, p)[1]
                return r and r[next(r)]
            end,
        },
    }
end

-- One start of the runner, as Crimson-Police does it with the database on. Returns its lines, errors and warnings.
local function Start(db)
    local r = { lines = {}, errs = {}, warns = {}, applied = 0 }
    local env = setmetatable({}, { __index = _G })
    env.CP = {
        err = function(_, fmt, ...) r.errs[#r.errs + 1] = tostring(fmt):format(...) end,
        log = function() end,
        warn = function(_, fmt, ...) r.warns[#r.warns + 1] = tostring(fmt):format(...) end,
        resource = 'Crimson-Police',
        Storage = { mode = function() return 'database' end, name = function() return 'database' end },
    }
    env.Config = { Tablet = {} }
    env.MySQL = Oxmysql(db)
    env.print = function(...)
        local l = table.concat({ ... }, ' ')
        r.lines[#r.lines + 1] = l
        if l:find('applied migration', 1, true) then r.applied = r.applied + 1 end
    end
    env.promise = {
        new = function()
            local p = {}
            function p:resolve(v) self.resolved, self.value = true, v end
            return p
        end,
    }
    env.Citizen = { Await = function(p) return p.value end }
    env.CreateThread = function(fn) fn() end
    env.SetTimeout = function() end
    env.GetCurrentResourceName = function() return 'Crimson-Police' end
    env.LoadResourceFile = function(_, path)
        local f = io.open(RES .. path, 'r')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end
    assert(load(RUNNER_SRC, '=migrations', 't', env))()
    r.ready = env.CP.Migrations.isReady()
    r.M = env.CP.Migrations
    return r
end
local function Count(lines, needle)
    local n = 0
    for _, l in ipairs(lines) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ---- 1. the migrations on four kinds of database ---------------------------------------------------------------------

-- utf8mb4: what Crimson-Police's install asks for; latin1: MariaDB's own default; utf8mb3: txAdmin's recipe
-- deployer (CHARACTER SET utf8); myisam: a server whose default_storage_engine is MyISAM.
local KINDS = {
    { db = 'cpc_utf8mb4', charset = 'utf8mb4' },
    { db = 'cpc_latin1', charset = 'latin1' },
    { db = 'cpc_utf8mb3', charset = 'utf8mb3' },
    { db = 'cpc_myisam', charset = 'latin1', engine = 'MyISAM' },
}

local function Tables(db)
    local out = {}
    for _, r in ipairs(MustQ(nil, ([[SELECT table_name AS t, engine AS e, table_collation AS k
        FROM information_schema.tables WHERE table_schema = %s AND table_type = 'BASE TABLE']]):format(Quote(db))))
    do
        if r.t:sub(1, 3) == 'cp_' then out[r.t] = r end
    end
    return out
end
local function Columns(db, tbl)
    return MustQ(nil, ([[SELECT table_name AS t, column_name AS c, column_type AS ty, is_nullable AS n,
        column_default AS d, collation_name AS k, data_type AS dt, ordinal_position AS o
        FROM information_schema.columns WHERE table_schema = %s%s ORDER BY table_name, ordinal_position]]):format(
        Quote(db), tbl and (' AND table_name = ' .. Quote(tbl)) or ''))
end

local reference = nil
for _, kind in ipairs(KINDS) do
    local db = kind.db
    MustQ(nil, ('DROP DATABASE IF EXISTS `%s`; CREATE DATABASE `%s` CHARACTER SET %s'):format(db, db, kind.charset))
    if kind.engine then MustQ(nil, 'SET GLOBAL default_storage_engine = ' .. kind.engine) end
    local okRun, err = pcall(function()
        local tag = kind.charset .. (kind.engine and (' ' .. kind.engine .. '-default') or '') .. ': '
        -- first start, then every file again through the same runner (its idempotent errors only), then a quiet one
        local s1 = Start(db)
        Check(tag .. 'first start', s1.ready and #s1.errs == 0 and s1.applied == #FILES,
            ('%d of %d files applied, %d errors%s'):format(s1.applied, #FILES, #s1.errs,
                #s1.errs > 0 and (': ' .. Some(s1.errs, 2)) or ''))
        MustQ(db, 'DELETE FROM cp_schema_migrations')
        local s2 = Start(db)
        Check(tag .. 'every file applied a second time', s2.ready and #s2.errs == 0 and s2.applied == #FILES,
            ('%d of %d files re-run, %d errors%s'):format(s2.applied, #FILES, #s2.errs,
                #s2.errs > 0 and (': ' .. Some(s2.errs, 2)) or ''))
        local s3 = Start(db)
        Check(tag .. 'next start changes nothing',
            s3.ready and s3.applied == 0 and #s3.errs + #s3.warns == 0 and Count(s3.lines, 'switching it to') == 0,
            ('%d applied, %d switched, %d warnings'):format(s3.applied, Count(s3.lines, 'switching it to'), #s3.warns))
        Info(tag .. 'warnings at start', #s1.warns == 0 and 'none' or Some(s1.warns, 2))

        local tables = Tables(db)
        local n, notInno, notMb4 = 0, {}, {}
        for name, r in pairs(tables) do
            n = n + 1
            if tostring(r.e):lower() ~= 'innodb' then notInno[#notInno + 1] = name .. '=' .. tostring(r.e) end
            if tostring(r.k):sub(1, 7) ~= 'utf8mb4' then notMb4[#notMb4 + 1] = name .. '=' .. tostring(r.k) end
        end
        table.sort(notInno)
        table.sort(notMb4)
        Check(tag .. 'every cp_ table InnoDB', n > 0 and #notInno == 0,
            #notInno == 0 and ('%d of %d tables'):format(n, n) or Some(notInno))
        Check(tag .. 'every cp_ table utf8mb4', n > 0 and #notMb4 == 0,
            #notMb4 == 0 and ('%d of %d tables'):format(n, n) or Some(notMb4))
        local cols, badCol, json, badJson = Columns(db), {}, 0, {}
        for _, c in ipairs(cols) do
            if c.t:sub(1, 3) == 'cp_' and c.k and c.k:sub(1, 7) ~= 'utf8mb4' then badCol[#badCol + 1] = c.t .. '.' .. c.c .. '=' .. c.k end
            if c.t:sub(1, 3) == 'cp_' and c.dt == 'longtext' then
                json = json + 1
                if c.k ~= 'utf8mb4_bin' then badJson[#badJson + 1] = c.t .. '.' .. c.c .. '=' .. tostring(c.k) end
            end
        end
        Check(tag .. 'every text column utf8mb4', #badCol == 0, #badCol == 0 and ('%d columns'):format(#cols) or Some(badCol))
        local checks = MustQ(nil, ([[SELECT COUNT(*) AS n FROM information_schema.check_constraints
            WHERE constraint_schema = %s AND check_clause LIKE '%%json_valid%%']]):format(Quote(db)))[1].n
        Check(tag .. 'JSON columns utf8mb4_bin, json_valid kept', json > 0 and #badJson == 0 and tonumber(checks) == json,
            #badJson == 0 and ('%d JSON columns, %s json_valid checks'):format(json, checks) or Some(badJson))
        local emoji = '\u{1F46E}\u{200D}\u{2640}\u{FE0F} note \u{1F600}'
        local okE = Q(db, ('INSERT INTO cp_audit (actor, role, action, reason) VALUES (\'console\', \'console\', \'note\', %s)'):format(
            Quote(emoji)))
        local back = okE and MustQ(db, 'SELECT reason FROM cp_audit ORDER BY id DESC LIMIT 1')[1]
        Check(tag .. 'emoji saved and read back', back ~= nil and back.reason == emoji, back and 'cp_audit.reason' or 'insert refused')
        local a, b = Columns(db, 'cp_mission_runs'), Columns(db, 'cp_mission_runs_archive')
        local diff = {}
        for i = 1, math.max(#a, #b) do
            local x, y = a[i] or {}, b[i] or {}
            for _, f in ipairs({ 'c', 'ty', 'n', 'd', 'k' }) do
                if x[f] ~= y[f] then diff[#diff + 1] = ('%s: %s vs %s'):format(tostring(x.c or y.c), tostring(x[f]), tostring(y[f])) end
            end
        end
        Check(tag .. 'archive columns = cp_mission_runs columns', #a > 0 and #diff == 0,
            #diff == 0 and ('%d columns, same order and types'):format(#a) or Some(diff))
        if not reference then
            reference = { db = db, tables = tables }
        else
            local missing = {}
            for name, r in pairs(reference.tables) do
                if not tables[name] then missing[#missing + 1] = name .. ' missing'
                elseif tables[name].k ~= r.k then missing[#missing + 1] = name .. '=' .. tostring(tables[name].k) .. ' (' .. r.k .. ')' end
            end
            for name in pairs(tables) do if not reference.tables[name] then missing[#missing + 1] = name .. ' extra' end end
            table.sort(missing)
            Check(tag .. 'same tables and collations as utf8mb4', #missing == 0, #missing == 0 and ('%d tables'):format(n) or Some(missing))
        end
    end)
    if kind.engine then Q(nil, 'SET GLOBAL default_storage_engine = InnoDB') end
    if not okRun then Check(kind.db .. ': the check itself', false, tostring(err):gsub('\n', ' '):sub(1, 300)) end
end
local DB = KINDS[1].db

-- ---- 2. the SQL the code sends ----------------------------------------------------------------------------------------

-- Every string literal in Crimson-Police/**/*.lua that starts with an SQL verb (memsql.lua, the saves folder engine,
-- is not SQL Crimson-Police sends). complete: not glued to another string with .. and no %s or %d in it.
local VERBS = { SELECT = 1, INSERT = 1, UPDATE = 1, DELETE = 1, REPLACE = 1, ALTER = 1, CREATE = 1, WITH = 1, DROP = 1, TRUNCATE = 1 }
local function Literals(src, file, out)
    local i, n, line = 1, #src, 1
    local function Add(s, l, nextTok)
        local t = s:gsub('^%s+', '')
        local verb = t:match('^(%a+)')
        if verb and VERBS[verb:upper()] and t:find('%s') then
            local complete = nextTok ~= '..' and not s:find('%%[sdq]')
            out[#out + 1] = { at = file .. ':' .. l, sql = s, complete = complete }
        end
    end
    while i <= n do
        local c = src:sub(i, i)
        if c == '\n' then
            line = line + 1
            i = i + 1
        elseif src:sub(i, i + 1) == '--' then
            local lvl = src:match('^%-%-%[(=*)%[', i)
            if lvl then
                local e = src:find(']' .. lvl .. ']', i, true) or n
                for _ in src:sub(i, e):gmatch('\n') do line = line + 1 end
                i = e + #lvl + 2
            else
                i = src:find('\n', i, true) or n + 1
            end
        elseif c == '[' and src:match('^%[=*%[', i) then
            local lvl = src:match('^%[(=*)%[', i)
            local s0 = i + #lvl + 2
            local e = src:find(']' .. lvl .. ']', s0, true) or n + 1
            local s, l = src:sub(s0, e - 1), line
            for _ in s:gmatch('\n') do line = line + 1 end
            i = e + #lvl + 2
            Add(s, l, src:match('^%s*(%.%.)', i))
        elseif c == '"' or c == '\'' then
            local j, buf = i + 1, {}
            while j <= n do
                local d = src:sub(j, j)
                if d == '\\' then
                    local e = src:sub(j + 1, j + 1)
                    buf[#buf + 1] = ({ n = '\n', t = '\t', ['\\'] = '\\', ['\''] = '\'', ['"'] = '"' })[e] or ('\\' .. e)
                    j = j + 2
                elseif d == c or d == '\n' then
                    break
                else
                    buf[#buf + 1] = d
                    j = j + 1
                end
            end
            i = j + 1
            Add(table.concat(buf), line, src:match('^%s*(%.%.)', i))
        else
            i = i + 1
        end
    end
end

local literals = {}
do
    local p = io.popen(('cd %s && find . -name \'*.lua\' -not -path \'./web/*\' -not -name memsql.lua | LC_ALL=C sort'):format(Quote(RES)))
    for file in p:lines() do Literals(ReadFile(RES .. file), file:sub(3), literals) end
    p:close()
end

-- the statements the specs sent (CP_SQL_LOG of tools/db_check.sh), resource frames only, each text once
local runtime, runtimeFiles = {}, 0
if RUNTIME then
    local okJ, cjson = pcall(require, 'cjson')
    if not okJ then
        Check('runtime statements', false, 'lua-cjson is missing (apt-get install lua-cjson)')
    else
        local seen = {}
        local p = io.popen(('ls %s/*.jsonl 2>/dev/null'):format(Quote(RUNTIME)))
        for file in p:lines() do
            runtimeFiles = runtimeFiles + 1
            for l in io.lines(file) do
                local okL, e = pcall(cjson.decode, l)
                if okL and type(e) == 'table' and type(e.sql) == 'string' and type(e.at) == 'table' and #e.at > 0
                    and e.kind ~= 'ready' then
                    local s = e.sql:gsub('^%s*SET NAMES [%w_]+;%s*', '')
                    if not seen[s] then
                        seen[s] = true
                        runtime[#runtime + 1] = { at = tostring(e.at[1]), sql = s, complete = true }
                    end
                end
            end
        end
        p:close()
    end
end

-- a statement on another resource's table (player_vehicles, Renewed-Banking's ...): not in this schema
local function Foreign(err)
    local t = err and err:match('ERROR 1146 %S+ at line %d+: Table \'[^\'.]*%.([^\']+)\' doesn\'t exist')
    return t ~= nil and t:sub(1, 3) ~= 'cp_', t
end
-- text that only starts like SQL ('select failed', a label 'INSERT INTO cp_x'): no statement body after the verb
local BODY = {
    SELECT = { ' FROM ', '(' },
    INSERT = { ' VALUES', ' SELECT ', ' SET ' },
    REPLACE = { ' VALUES', ' SELECT ', ' SET ' },
    UPDATE = { ' SET ' },
    DELETE = { ' FROM ' },
    WITH = { ' SELECT ' },
    ALTER = { ' TABLE ' },
    CREATE = { ' TABLE ', ' INDEX ' },
    DROP = { ' TABLE ', ' INDEX ' },
    TRUNCATE = { ' TABLE ', ' CP_' },
}
local function LooksLikeSql(s)
    local u = ' ' .. s:upper():gsub('%s+', ' ') .. ' '
    for _, needle in ipairs(BODY[u:match('^%s*(%a+)')] or {}) do
        if u:find(needle, 1, true) then return true end
    end
    return false
end

local function PrepareAll(list, preamble)
    local stmts, idx = {}, {}
    for _, e in ipairs(list) do
        if e.complete and LooksLikeSql(e.sql) then
            stmts[#stmts + 1] = 'PREPARE st FROM ' .. Quote(e.sql)
            idx[#idx + 1] = e
        end
    end
    local errs = Each(DB, stmts, preamble)
    local ok, foreign, bad, names = 0, 0, {}, {}
    for i, e in ipairs(idx) do
        local err = errs[i]
        local isForeign, t = Foreign(err)
        if not err then
            ok = ok + 1
        elseif isForeign then
            foreign = foreign + 1
            names[t] = true
        else
            bad[#bad + 1] = ('%s: %s'):format(e.at, err:gsub('^ERROR %d+ %S+ at line %d+: ', ''):sub(1, 140))
        end
    end
    local fn = {}
    for t in pairs(names) do fn[#fn + 1] = t end
    table.sort(fn)
    return #idx, ok, foreign, bad, fn
end

local function Prepared(label, list)
    if #list == 0 then return end
    local ofgb = 'SET SESSION sql_mode = CONCAT(@@sql_mode, \',ONLY_FULL_GROUP_BY\')'
    for _, mode in ipairs({ { 'default sql_mode', nil }, { '+ONLY_FULL_GROUP_BY', ofgb } }) do
        local n, ok, foreign, bad, fn = PrepareAll(list, mode[2])
        Check(('%s PREPARE (%s)'):format(label, mode[1]), n > 0 and #bad == 0,
            ('%d statements: %d prepared, %d on other resources\' tables%s%s'):format(n, ok, foreign,
                #fn > 0 and (' (' .. table.concat(fn, ', ') .. ')') or '', #bad > 0 and ('; ' .. #bad .. ' failed: ' .. Some(bad, 3)) or ''))
    end
end
local partial = 0
for _, e in ipairs(literals) do if not e.complete then partial = partial + 1 end end
Info('code literals', ('%d SQL literals in Crimson-Police, %d built from parts (checked through the runtime capture)'):format(
    #literals, partial))
Prepared('code literals', literals)
if RUNTIME then
    Check('runtime capture', #runtime > 0, ('%d distinct statements the specs sent (%d log files)'):format(#runtime, runtimeFiles))
    Prepared('runtime statements', runtime)
end

-- ---- 3. every "insert once" or "on duplicate" target has a unique key that the insert fills -----------------------

do
    local keys = {}
    for _, r in ipairs(MustQ(nil, ([[SELECT table_name AS t, index_name AS i, GROUP_CONCAT(column_name ORDER BY seq_in_index) AS c
        FROM information_schema.statistics WHERE table_schema = %s AND non_unique = 0 GROUP BY table_name, index_name]]):format(
        Quote(DB))))
    do
        keys[r.t] = keys[r.t] or {}
        keys[r.t][#keys[r.t] + 1] = r.c
    end
    local sites, bad, seen = 0, {}, {}
    local function Look(e)
        local s = e.sql:gsub('%s+', ' ')
        local u = s:upper()
        local once = u:find('^%s*INSERT IGNORE') or u:find('ON DUPLICATE KEY UPDATE', 1, true) or u:find('^%s*REPLACE INTO')
        if not once then return end
        local tbl, colList = s:match('^%s*%a+%s+%a*%s*[Ii][Nn][Tt][Oo]%s+`?([%w_]+)`?%s*(%b())')
        tbl = tbl or s:match('^%s*%a+%s+%a*%s*[Ii][Nn][Tt][Oo]%s+`?([%w_]+)`?')
        if not tbl or tbl:sub(1, 3) ~= 'cp_' then return end
        local key = tbl .. '|' .. (colList or '')
        if seen[key] then return end
        seen[key] = true
        sites = sites + 1
        local cols = nil
        if colList and e.complete then
            cols = {}
            for c in colList:sub(2, -2):gmatch('[^,]+') do cols[c:gsub('[%s`]', ''):lower()] = true end
        end
        local found = false
        for _, k in ipairs(keys[tbl] or {}) do
            local all = true
            if cols then for c in k:gmatch('[^,]+') do if not cols[c:lower()] then all = false end end end
            if all then found = true end
        end
        if not found then
            bad[#bad + 1] = ('%s %s%s: no unique key%s'):format(e.at, tbl, colList or '', cols and ' the insert fills' or '')
        end
    end
    for _, e in ipairs(literals) do Look(e) end
    for _, e in ipairs(runtime) do Look(e) end
    Look({ at = 'migrations.lua', sql = 'INSERT IGNORE INTO cp_schema_migrations (version, name) VALUES (?, ?)', complete = true })
    Check('insert-once targets have a unique key', sites > 0 and #bad == 0,
        ('%d distinct targets%s'):format(sites, #bad > 0 and (': ' .. Some(bad)) or ''))
end

-- ---- 4. reserved words: every cp_ column name, unquoted ---------------------------------------------------------------

do
    local stmts, names = {}, {}
    for _, c in ipairs(Columns(DB)) do
        if c.t:sub(1, 3) == 'cp_' then
            stmts[#stmts + 1] = ('PREPARE st FROM \'SELECT %s FROM %s WHERE %s IS NULL ORDER BY %s\''):format(c.c, c.t, c.c, c.c)
            names[#names + 1] = c.t .. '.' .. c.c
        end
    end
    local errs, bad = Each(DB, stmts), {}
    for i in pairs(errs) do bad[#bad + 1] = names[i] end
    table.sort(bad)
    Check('column names need no quoting', #stmts > 0 and #bad == 0,
        #bad == 0 and ('%d columns used unquoted'):format(#stmts) or Some(bad))
end

-- ---- 5. writes that round-trip --------------------------------------------------------------------------------------

do
    local RUN = [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, cash_base, cash_multiplier, cash_paid, breakdown) VALUES ]]
    local bio = string.rep('\u{1F46E}', 280)
    local reason = string.rep('\u{1F600}', 255)
    local big = '{"name":"\u{1F46E}\u{200D}\u{2642}\u{FE0F} Kim","pad":"' .. string.rep('x', 5 * 1024 * 1024) .. '"}'
    local cases = {
        { 'INT 2147483647 kept, sums past INT',
            RUN .. [[('rt-1', 'patrol', 'm', 'RT1', 'lspd', 'completed', 'done', 1, 2147483647, 99.99, 2147483647, NULL)]],
            [[SELECT CONCAT(SUM(cash_base) + SUM(cash_paid), '|', MAX(cash_multiplier)) AS v FROM cp_mission_runs WHERE run_uuid = 'rt-1']],
            '4294967294|99.99' },
        { 'INT 2147483648 refused, not cut (strict)',
            RUN .. [[('rt-2', 'patrol', 'm', 'RT2', 'lspd', 'completed', 'done', 1, 2147483648, 1, 0, NULL)]],
            [[SELECT COUNT(*) AS v FROM cp_mission_runs WHERE run_uuid = 'rt-2']], '0', 1264 },
        { 'DECIMAL(4,2) 100 refused (strict)',
            RUN .. [[('rt-3', 'patrol', 'm', 'RT3', 'lspd', 'completed', 'done', 1, 1, 100, 0, NULL)]],
            [[SELECT COUNT(*) AS v FROM cp_mission_runs WHERE run_uuid = 'rt-3']], '0', 1264 },
        { 'NULLs and JSON null read as SQL NULL',
            RUN .. [[('rt-4', 'patrol', 'm', 'RT4', 'lspd', 'completed', 'done', 1, 0, 1, 0, '{"cash":{"status":null}}')]],
            [[SELECT CONCAT(JSON_VALUE(breakdown, '$.cash.status') IS NULL, '|', season_id IS NULL, '|', modifier IS NULL) AS v
              FROM cp_mission_runs WHERE run_uuid = 'rt-4']], '1|1|1' },
        { 'DATETIME at 2147483647 round-trips (UTC)',
            [[INSERT INTO cp_officers (citizenid, suspended_until) VALUES ('RT5', FROM_UNIXTIME(2147483647))]],
            [[SELECT UNIX_TIMESTAMP(suspended_until) AS v FROM cp_officers WHERE citizenid = 'RT5']], '2147483647' },
        { '280-emoji bio (1120 bytes) kept',
            ([[INSERT INTO cp_officers (citizenid, bio) VALUES ('RT6', %s)]]):format(Quote(bio)),
            [[SELECT CONCAT(CHAR_LENGTH(bio), '|', LENGTH(bio)) AS v FROM cp_officers WHERE citizenid = 'RT6']], '280|1120' },
        { '255-emoji audit reason kept',
            ([[INSERT INTO cp_audit (actor, role, action, reason) VALUES ('console', 'console', 'rt7', %s)]]):format(Quote(reason)),
            [[SELECT CHAR_LENGTH(reason) AS v FROM cp_audit WHERE action = 'rt7']], '255' },
        { '5 MB JSON with emoji kept',
            ([[INSERT INTO cp_pvp_cases (run_uuid, kind, closed_at, case_json) VALUES ('rt-8', 'live', NOW(), %s)]]):format(Quote(big)),
            [[SELECT CONCAT(JSON_VALUE(case_json, '$.name'), '|', LENGTH(case_json)) AS v FROM cp_pvp_cases WHERE run_uuid = 'rt-8']],
            '\u{1F46E}\u{200D}\u{2642}\u{FE0F} Kim|' .. #big },
        { 'text that is not JSON refused',
            [[INSERT INTO cp_pvp_cases (run_uuid, kind, closed_at, case_json) VALUES ('rt-9', 'live', NOW(), 'not json')]],
            [[SELECT COUNT(*) AS v FROM cp_pvp_cases WHERE run_uuid = 'rt-9']], '0', 4025 },
    }
    local UTC = 'SET time_zone = \'+00:00\'; '
    for _, c in ipairs(cases) do
        local name, write, read, want, wantErr = c[1], c[2], c[3], c[4], c[5]
        local okW, errW = Q(DB, UTC .. write)
        local code = errW and tonumber(errW:match('ERROR (%d+)'))
        local rows = Q(DB, UTC .. read)
        local got = rows and rows[1] and rows[1].v
        local fine = got == want and ((wantErr and code == wantErr) or (not wantErr and okW ~= nil))
        Check('write: ' .. name, fine,
            fine and (wantErr and ('error %d, nothing written'):format(code) or 'read back as written')
                or ('got %s, error %s'):format(tostring(got and got:sub(1, 60)), tostring(errW and errW:sub(1, 120))))
    end
end

-- ---- 6. the server's time zone (the start-up check's probe) ---------------------------------------------------------

do
    local rows = MustQ(nil, [[SELECT @@global.time_zone AS z, @@system_time_zone AS s,
        UNIX_TIMESTAMP('2026-07-01 12:00:00') - UNIX_TIMESTAMP('2026-01-01 12:00:00') AS d]])
    Info('server time zone', ('%s (system %s): the start-up probe reads %s, %s'):format(rows[1].z, rows[1].s, rows[1].d,
        rows[1].d == '15638400' and 'no daylight saving: no warning' or 'daylight saving: the start warns'))
end

print()
local passed = #results - failed
print(('SUMMARY %s: %d checks, %d passed, %d failed'):format(failed == 0 and 'PASS' or 'FAIL', #results, passed, failed))
os.exit(failed == 0 and 0 or 1)
