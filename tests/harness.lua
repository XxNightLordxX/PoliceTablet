-- A tiny FiveM/Qbox stand-in for unit tests (not shipped with the resource).

local H = {}
-- FXServer builds its Lua with LUA_SANDBOX (code/vendor/lua.lua), so the debug table a resource sees has only these
-- five functions: no sethook, no gethook, no getlocal (ldblib.c of citizenfx/lua luaglm-548; the real
-- libcitizen-scripting-lua.so of FXServer 35245 agrees). The resource code under test sees exactly that table, also
-- through require('debug'), so code that needs more fails the suite as it would fail on a real server. H.debug is the
-- full library, for the specs' own tools only (a spec copies what it needs into a local).
H.debug = debug
H.FX_DEBUG = { 'getinfo', 'getmetatable', 'getupvalue', 'setmetatable', 'traceback' }
do
    local fx = {}
    for _, name in ipairs(H.FX_DEBUG) do fx[name] = H.debug[name] end
    _G.debug = fx
    package.loaded.debug = fx
end
-- CP_TEST_CLOCK=<unix time> moves the "real" clock of the whole spec (os.time() before H.boot, MariaDB NOW()
-- through SET timestamp, the files engine) to that moment, ticking from there: a run at any wall-clock time.
local CLOCK_SHIFT = 0
do
    local at = tonumber(os.getenv('CP_TEST_CLOCK') or '')
    if at then
        local sysTime = os.time
        CLOCK_SHIFT = at - sysTime()
        os.time = function(t) if t then return sysTime(t) end return sysTime() + CLOCK_SHIFT end
    end
end
local REAL_TIME = os.time   -- H.boot fakes os.time(); the shadow engine runs on the real clock
local TESTS = (debug.getinfo(1, 'S').source:match('^@(.*)/harness%.lua$') or 'tests') .. '/'
local ROOT = (debug.getinfo(1, 'S').source:match('^@(.*)/tests/harness%.lua$') or '.') .. '/Crimson-Police/'
H.root = ROOT
-- The folder calls as FXServer on Linux answers them (FACTS W3, W7):
-- - os.getenv('os') is 'Linux' (H.fxOs; a spec sets 'Windows' to check that branch);
-- - os.createdir makes the folder and then kills the whole server with signal 11, which pcall cannot catch: here it
--   ends the spec at once with exit code 139 and a CRASH line, so any call from resource code fails the suite;
-- - os.execute is refused for the resource (nil, 'Permission denied', 13); the specs' own calls still run.
H.fxOs = 'Linux'
H.getenv = os.getenv
os.getenv = function(name)
    if name == 'os' then return H.fxOs end
    return H.getenv(name)
end
H.fatalCreatedir = function(path)
    print(
        ('CRASH os.createdir(%s): on a Linux FXServer this kills the whole server (signal 11)'):format(tostring(path)))
    print(H.debug.traceback('', 2))
    io.stdout:flush()
    os.exit(139)
end
os.createdir = H.fatalCreatedir
H.execute = os.execute
os.execute = function(...)
    local info = H.debug.getinfo(2, 'S')
    if info and info.source:sub(1, #ROOT + 1) == '@' .. ROOT then return nil, 'Permission denied', 13 end
    return H.execute(...)
end
-- Every folder Crimson-Police writes into, as the resource ships them (each holds a .gitkeep or a file in git).
H.SHIPPED_DIRS = {
    'saves',
    'saves/_backups',
    'saves/exports',
    'logos',
    'missions/custom',
    'missions/custom/archived',
    'missions/custom/overrides',
    'missions/custom/overrides/archived',
    'missions/custom/deleted',
}
-- The shipped folders inside a test resource folder (what a fresh install has).
function H.shipFolders(base)
    for _, rel in ipairs(H.SHIPPED_DIRS) do H.execute(('mkdir -p \'%s/%s\''):format(base, rel)) end
end
H.storage = os.getenv('CP_TEST_STORAGE') or 'database'
if H.storage == '' then H.storage = 'database' end
if H.storage ~= 'database' and H.storage ~= 'files' and H.storage ~= 'shadow' then
    error(('CP_TEST_STORAGE must be database, files or shadow (got \'%s\')'):format(H.storage))
end
H.events = {}                                                    -- recorded TriggerClientEvent / TriggerServerEvent / TriggerEvent calls
H.handlers = {}                                                  -- registered event handlers by name
H.callbacks = {}                                                 -- lib.callback.register handlers by name
H.commands = {}
H.exportsMock = {}                                               -- H.exportsMock['sc-dispatch'] = { ClearNotification = function(...) end }
H.clockMs = 0
H.time = tonumber(os.getenv('CP_TEST_NOW') or '') or 1790000000  -- fake os.time() (CP_TEST_NOW moves it)
H.db = os.getenv('CP_TEST_DB') or 'cp_test'                      -- tests/run.lua gives every run its own database
H.failures = 0
H.passes = 0

local cjson = require('cjson')
cjson.encode_sparse_array(true)

-- ============================================================================
--                                  ASSERTIONS
-- ============================================================================

local function Fmt(v)
    if type(v) == 'table' then
        local ok, s = pcall(cjson.encode, v)
        return ok and s or tostring(v)
    end
    return tostring(v)
end

function H.eq(actual, expected, msg)
    if actual == expected then H.passes = H.passes + 1; return true end
    H.failures = H.failures + 1
    print(('  FAIL %s: expected %s, got %s'):format(msg or '', Fmt(expected), Fmt(actual)))
    print(debug.traceback('', 2))
    return false
end

function H.ok(cond, msg)
    if cond then H.passes = H.passes + 1; return true end
    H.failures = H.failures + 1
    print(('  FAIL %s'):format(msg or 'expected truthy'))
    print(debug.traceback('', 2))
    return false
end

function H.near(a, b, eps, msg)
    return H.ok(type(a) == 'number' and math.abs(a - b) <= (eps or 1e-6),
        (msg or '') .. (' (%s vs %s)'):format(tostring(a), tostring(b)))
end

-- ============================================================================
--                                   VECTORS
-- ============================================================================

local vmt = {}
vmt.__index = function(v, k)
    if k == 'xy' then return setmetatable({ x = rawget(v, 'x'), y = rawget(v, 'y') }, vmt) end
    if k == 'xyz' then return setmetatable({ x = rawget(v, 'x'), y = rawget(v, 'y'), z = rawget(v, 'z') }, vmt) end
    return nil
end
vmt.__sub = function(a, b) return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = (a.z or 0) - (b.z or 0) }, vmt) end
vmt.__add = function(a, b) return setmetatable({ x = a.x + b.x, y = a.y + b.y, z = (a.z or 0) + (b.z or 0) }, vmt) end
vmt.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) ^ 2) end
vmt.__eq = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z and a.w == b.w end
local function Vec(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w }, vmt) end

-- ============================================================================
--                                   THREADS
-- ============================================================================

local sleeping = {}
local function Resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err, 0) end
end

function H.step(ms)
    H.clockMs = H.clockMs + (ms or 0)
    if H._entityTick then H._entityTick(ms or 0) end
    local list = sleeping
    sleeping = {}
    for _, s in ipairs(list) do
        if s.wake <= H.clockMs and coroutine.status(s.co) == 'suspended' then
            Resume(s.co)
        else
            sleeping[#sleeping + 1] = s
        end
    end
end

-- Run pending threads until nothing wakes within `ms` of fake time.
function H.advance(ms, stepMs)
    stepMs = stepMs or 100
    local target = H.clockMs + ms
    while H.clockMs < target do H.step(stepMs) end
end

-- ============================================================================
--                         MySQL THROUGH THE MYSQL CLI
-- ============================================================================

local function SqlLiteral(v)
    local t = type(v)
    if v == nil then return 'NULL' end
    if t == 'boolean' then return v and '1' or '0' end
    if t == 'number' then
        if v == math.floor(v) then return ('%d'):format(v) end
        return tostring(v)
    end
    if t == 'table' then
        local ok, s = pcall(cjson.encode, v)
        v = ok and s or tostring(v)
    end
    v = tostring(v):gsub('\\', '\\\\'):gsub('\'', '\\\'')
    return '\'' .. v .. '\''
end

-- MariaDB 11.8 and newer (Qbox recommends 12.3) answer FROM_UNIXTIME(0) with NULL: the TIMESTAMP range starts one
-- second after the epoch, so created_at >= FROM_UNIXTIME(0) matches no row. 10.11 (the local server and CI) still
-- answers 1970-01-01, so a value below 1 placed in FROM_UNIXTIME(?) is sent as NULL, as a current server reads it.
-- Below 0 and past 2038 10.11 already answers NULL. (mariadb.com/kb/en/from_unixtime; run on 11.8.2, 11.8.9, 12.3.3)
local function InFromUnixtime(out)
    local k = #out
    while k > 0 and out[k]:match('%s') do k = k - 1 end
    return k >= 14 and table.concat(out, '', k - 13, k):upper() == 'FROM_UNIXTIME('
end

local function Interpolate(sql, params)
    params = params or {}
    local i = 0
    local out = {}
    local inStr = nil
    for c in sql:gmatch('.') do
        if inStr then
            out[#out + 1] = c
            if c == inStr then inStr = nil end
        elseif c == '\'' or c == '"' then
            inStr = c
            out[#out + 1] = c
        elseif c == '?' then
            i = i + 1
            local v = params[i]
            out[#out + 1] = (type(v) == 'number' and v < 1 and InFromUnixtime(out)) and 'NULL' or SqlLiteral(v)
        else
            out[#out + 1] = c
        end
    end
    if i ~= #params and #params > 0 then
        error(('SQL placeholder count %d does not match %d params: %s'):format(i, #params, sql), 3)
    end
    return table.concat(out)
end

local function ParseValue(s)
    if s == 'NULL' then return nil end
    local n = tonumber(s)
    if n and s:match('^%-?%d+%.?%d*$') then return n end
    return s
end

-- NOW(), CURRENT_TIMESTAMP and UNIX_TIMESTAMP() read the spec's clock (os.time(), H.time once H.boot ran),
-- as the saves folder engine does in files mode: no check depends on the wall clock of the test box. It sits on
-- the statement's first line, so MariaDB's "at line N" still counts the statement's own lines.
local function ClockSql() return ('SET timestamp = %d; '):format(math.floor(os.time())) end

-- One mysql client per spec process, kept open: every call reconnects first (`connect <db>`), so each call
-- still gets a fresh session (charset, LAST_INSERT_ID, variables), as a new client would. The client stops at
-- the first error, like before; the next call starts a new one. It is started through io.popen with a command
-- that begins 'mysql -uroot ', so a spec's io.popen wrapper (the utf8mb4 charset) still applies; a new io.popen
-- starts a new client. Behind mysql, `cat` swallows whatever is still sent after it stopped (no SIGPIPE in the
-- spec) and the shell exits with mysql's status. CP_TEST_MYSQL=spawn: one client per call, as before.
local SPAWN_EACH = os.getenv('CP_TEST_MYSQL') == 'spawn'
local BIG_SQL = 32768   -- longer texts go through a client of their own (no pipe can fill up both ways)
local client = nil

-- Each returns the output, then true, or false and the exit code (as a closed io.popen does).
local function SpawnSql(q)
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, 'w'))
    f:write(ClockSql(), q, ';\n')
    f:close()
    local p = io.popen(('mysql -uroot %s --batch --raw < %s 2>&1'):format(H.db, tmp))
    local outText = p:read('a')
    local exited, _, code = p:close()
    os.remove(tmp)
    return outText, exited, code
end

local function CloseClient()
    if not client then return true end
    local c = client
    client = nil
    local ok, exited, _, code = pcall(c.w.close, c.w)
    pcall(c.r.close, c.r)
    return ok and exited, code
end

local function OpenClient()
    if client and client.popen == io.popen then return client end
    CloseClient()
    local fifo = os.tmpname()
    os.remove(fifo)
    if not os.execute(('mkfifo \'%s\''):format(fifo)) then error('mkfifo failed for the mysql client') end
    local popen = io.popen
    -- no database here: a missing one fails at `connect`, after this side has written the call
    local cmd = 'mysql -uroot --batch --raw --unbuffered > \'%s\' 2>&1; s=$?; cat > /dev/null; exit $s'
    local w = assert(popen(cmd:format(fifo), 'w'))
    local r = assert(io.open(fifo, 'r'))
    os.remove(fifo)
    client = { w = w, r = r, popen = popen, line = 0, n = 0, salt = fifo:gsub('%W', '') }
    return client
end

local function ClientSql(q)
    local c = OpenClient()
    c.n = c.n + 1
    local tok = ('cp_end_%s_%d'):format(c.salt, c.n)   -- a column name: the line that ends this call's output
    -- the lone ';' closes a text whose last ';' sat in a trailing comment (a new client ran it at end of input)
    local text = ('connect %s;\n%s%s;\n;\nSELECT 1 AS %s;\n'):format(H.db, ClockSql(), q, tok)
    local first = c.line + 2
    c.line = c.line + select(2, text:gsub('\n', ''))
    c.w:write(text)
    c.w:flush()
    local out = {}
    while true do
        local line = c.r:read('L')
        if not line then
            -- the client stopped (an error): the text up to here, line numbers as a client of its own gives them
            local exited, code = CloseClient()
            local outText = table.concat(out):gsub(' at line (%d+)', function(n)
                n = tonumber(n) - first + 1
                return n >= 1 and (' at line ' .. n) or ''   -- 0: the connect line (a missing database)
            end)
            return outText, false, exited and 0 or code
        end
        if line == tok .. '\n' then
            c.r:read('L')
            return table.concat(out), true
        end
        out[#out + 1] = line
    end
end

-- Returns rows (list of name->value tables) of the LAST result set, and its column names.
local lastHeader = nil   -- column names of the last result set (read by the optional SQL log below)
local function RawSql(sql, params)
    lastHeader = nil
    local q = Interpolate(sql, params)
    local outText, exited, code
    if SPAWN_EACH or #q > BIG_SQL then
        outText, exited, code = SpawnSql(q)
    else
        outText, exited, code = ClientSql(q)
    end
    if outText:match('^ERROR') or outText:match('\nERROR') then
        error('SQL error: ' .. outText .. '\nquery: ' .. q, 2)
    end
    -- mysql missing, unable to start or cut off: its message would otherwise be read as a result with no rows
    if not exited then
        error(('SQL error: mysql -uroot exited with %s: %s\nquery: %s'):format(tostring(code), outText, q), 2)
    end
    local lines = {}
    for line in outText:gmatch('[^\n]+') do lines[#lines + 1] = line end
    -- Find the last header line: results of multiple statements are concatenated.
    local rows, header = {}, nil
    for _, line in ipairs(lines) do
        local cols = {}
        for c in (line .. '\t'):gmatch('(.-)\t') do cols[#cols + 1] = c end
        if not header then
            header = cols
        else
            -- A new header appears when a later SELECT starts; detect by exact column-name repeat.
            local row = {}
            for i, name in ipairs(header) do row[name] = ParseValue(cols[i]) end
            rows[#rows + 1] = row
        end
    end
    lastHeader = header
    return rows, header
end
H.sql = RawSql

local function LastScalar(sql, params, extra)
    local rows = RawSql(Interpolate(sql, params) .. ';\n' .. extra, {})
    local r = rows[#rows]
    if not r then return nil end
    for _, v in pairs(r) do return v end
end

local function IsSelect(sql)
    local s = sql:gsub('^%s+', ''):upper()
    return s:sub(1, 6) == 'SELECT' or s:sub(1, 4) == 'SHOW' or s:sub(1, 4) == 'WITH'
end

local MySQL = { query = {}, single = {}, scalar = {}, insert = {}, update = {}, prepare = {}, transaction = {} }
function MySQL.query.await(sql, params)
    if IsSelect(sql) then return (RawSql(sql, params)) end
    local rows = RawSql(
        Interpolate(sql, params) .. ';\nSELECT ROW_COUNT() AS affectedRows, LAST_INSERT_ID() AS insertId', {})
    return rows[#rows] or { affectedRows = 0 }
end
function MySQL.single.await(sql, params) return (RawSql(sql, params))[1] end
function MySQL.scalar.await(sql, params)
    local rows, header = RawSql(sql, params)
    if not rows[1] or not header then return nil end
    return rows[1][header[1]]
end
function MySQL.insert.await(sql, params) return tonumber(LastScalar(sql, params, 'SELECT LAST_INSERT_ID() AS id')) end
function MySQL.update.await(sql, params) return tonumber(LastScalar(sql, params, 'SELECT ROW_COUNT() AS n')) or 0 end
function MySQL.prepare.await() error('MySQL.prepare is not used in Crimson-Police (see ARCHITECTURE 0.6)') end
function MySQL.transaction.await(queries)
    for _, q in ipairs(queries) do
        if type(q) == 'table' then
            MySQL.query.await(q.query or q[1], q.values or q.parameters or q[2])
        else
            MySQL.query.await(q)
        end
    end
    return true
end
for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
    setmetatable(MySQL[k], {
        __call = function(_, sql, params, cb)
            local r = MySQL[k].await(sql, params)
            if cb then cb(r) end
            return r
        end,
    })
end
MySQL.ready = function(cb) cb() end

-- ============================================================================
--               JSON LINES FOR THE SQL LOG AND THE SHADOW REPORT
-- ============================================================================
-- enc(v): JSON that keeps integers and floats apart (floats keep a '.0'), nil holes -> null, sorted keys.
-- sqlFrames(): resource frames on the (coroutine's) stack, innermost first, and the innermost tests/ frame.
local function Jstr(s) return cjson.encode(s) end
local function Enc(v, lvl)
    local t = type(v)
    if v == nil then return 'null' end
    if t == 'boolean' then return v and 'true' or 'false' end
    if t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then return Jstr(tostring(v)) end
        if math.type(v) == 'integer' then return ('%d'):format(v) end
        if v == math.floor(v) and math.abs(v) < 1e15 then return ('%.1f'):format(v) end
        return ('%.17g'):format(v)
    end
    if t == 'string' then return Jstr(v) end
    if t ~= 'table' then return Jstr('<' .. t .. '>') end
    lvl = (lvl or 0) + 1
    if lvl > 20 then return Jstr('<deep>') end
    local n, isList = 0, true
    for k in pairs(v) do
        if math.type(k) == 'integer' and k > 0 then
            if k > n then n = k end
        else
            isList = false
        end
    end
    local out = {}
    if isList then
        for i = 1, n do out[i] = Enc(v[i], lvl) end
        return '[' .. table.concat(out, ',') .. ']'
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = { s = tostring(k), k = k } end
    table.sort(keys, function(a, b) return a.s < b.s end)
    for i, e in ipairs(keys) do out[i] = Jstr(e.s) .. ':' .. Enc(v[e.k], lvl) end
    return '{' .. table.concat(out, ',') .. '}'
end
-- Resource frames anywhere on the (coroutine's) stack, so a spec's stub wrapped around MySQL.* still shows
-- the module line that called it; "from" is the innermost tests/ frame.
local function SqlFrames()
    local at, from = {}, nil
    for level = 3, 200 do
        local info = debug.getinfo(level, 'Sl')
        if not info then break end
        local src = info.source
        if src:sub(1, 1) == '@' then
            local rel = src:match('Crimson%-Police/(.*)$')
            if rel then
                if #at < 8 then at[#at + 1] = rel .. ':' .. tostring(info.currentline) end
            elseif not from then
                local t = src:match('(tests/.*)$')
                if t and not t:match('harness%.lua$') then from = t .. ':' .. tostring(info.currentline) end
            end
        end
    end
    return at, from
end

-- The spec this Lua state runs (tests/<name>.lua on the stack when the harness loads).
local SPEC_NAME = 'unknown'
for level = 2, 30 do
    local info = debug.getinfo(level, 'S')
    if not info then break end
    local name = info.source:match('^@.-tests/(.-)%.lua$')
    if name and name ~= 'harness' then SPEC_NAME = name:gsub('/', '_'); break end
end
H.specName = SPEC_NAME

-- ============================================================================
--                               OPTIONAL SQL LOG
-- ============================================================================
-- CP_SQL_LOG=<file> appends one JSON line per MySQL.*.await / MySQL.ready call and per direct H.sql call
-- (CP_SQL_LOG=<dir>/ writes <dir>/<spec>.jsonl instead). Off when the variable is unset: nothing is wrapped.
--   { "n": 12, "spec": "economy_spec", "db": "..", "kind": "update", "sql": "...", "params": [..],
--     "result": .., "cols": [..], "error": "..", "at": ["modules/cash/server.lua:177", ..], "from": "tests/x.lua:9" }
-- kind: query | single | scalar | insert | update | ready | H.sql (a spec's own statement).
-- params: the parameter list (nil holes -> null, Lua tables -> JSON). result: exactly what the harness returned
-- (row objects keep the column order given in cols; floats keep a '.0'; nil -> null; failed calls carry "error").
-- at: resource frames (path under Crimson-Police/, innermost first, up to 8); from: the innermost tests/ frame.
-- An empty "at" means the statement came from the spec itself (fixtures, resets, assertions).
do
    local target = os.getenv('CP_SQL_LOG')
    if target and target ~= '' then
        local specName = SPEC_NAME
        local path = target:sub(-1) == '/' and (target .. specName .. '.jsonl') or target
        local file, seq, depth = nil, 0, 0

        local function EncRow(row, cols)
            local out = {}
            for i, name in ipairs(cols) do out[i] = Jstr(name) .. ':' .. Enc(row[name]) end
            return '{' .. table.concat(out, ',') .. '}'
        end
        local function EncRows(rows, cols)
            if type(rows) ~= 'table' or not cols then return Enc(rows) end
            local out = {}
            for i, row in ipairs(rows) do out[i] = EncRow(row, cols) end
            return '[' .. table.concat(out, ',') .. ']'
        end
        local function Write(kind, sql, params, resultJson, cols, err)
            seq = seq + 1
            local at, from = SqlFrames()
            local np = 0
            if type(params) == 'table' then
                for k in pairs(params) do if math.type(k) == 'integer' and k > np then np = k end end
            end
            local plist = {}
            for i = 1, np do plist[i] = Enc(params[i]) end
            local parts = {
                '"n":' .. seq,
                '"spec":' .. Jstr(specName),
                '"db":' .. Jstr(H.db),
                '"kind":' .. Jstr(kind),
                '"sql":' .. (type(sql) == 'string' and Jstr(sql) or 'null'),
                '"params":[' .. table.concat(plist, ',') .. ']',
                '"result":' .. resultJson,
            }
            if cols then
                local c = {}
                for i, name in ipairs(cols) do c[i] = Jstr(name) end
                parts[#parts + 1] = '"cols":[' .. table.concat(c, ',') .. ']'
            end
            if err then parts[#parts + 1] = '"error":' .. Jstr(tostring(err)) end
            parts[#parts + 1] = '"at":' .. Enc(at)
            if from then parts[#parts + 1] = '"from":' .. Jstr(from) end
            if not file then file = assert(io.open(path, 'a')) end
            file:write('{', table.concat(parts, ','), '}\n')
            file:flush()
        end

        local function Wrap(kind, fn, rowsResult)
            return function(sql, params)
                depth = depth + 1
                local ok, res = pcall(fn, sql, params)
                depth = depth - 1
                local cols = lastHeader
                if not ok then
                    Write(kind, sql, params, 'null', nil, res)
                    error(res, 0)
                end
                local selectLike = kind == 'single' or kind == 'scalar' or kind == 'H.sql'
                    or (kind == 'query' and type(sql) == 'string' and IsSelect(sql))
                if rowsResult and selectLike then
                    Write(kind, sql, params, EncRows(res, cols), cols)
                elseif kind == 'single' and type(res) == 'table' and cols then
                    Write(kind, sql, params, EncRow(res, cols), cols)
                else
                    Write(kind, sql, params, Enc(res), selectLike and cols or nil)
                end
                return res
            end
        end
        for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
            MySQL[k].await = Wrap(k, MySQL[k].await, k == 'query')
        end
        local rawReady = MySQL.ready
        MySQL.ready = function(cb)
            Write('ready', nil, nil, 'null', nil)
            return rawReady(cb)
        end
        -- Direct H.sql calls from specs (the MySQL.* functions call rawSql, so nothing is logged twice).
        local sqlLogged = Wrap('H.sql', RawSql, true)
        H.sql = function(sql, params)
            if depth > 0 then return RawSql(sql, params) end
            return sqlLogged(sql, params)
        end
        H.sqlLog = path
    end
end
H.MySQL = MySQL

-- ============================================================================
--                    SAVES FOLDERS (files and shadow modes)
-- ============================================================================
-- Every database name (H.db) gets its own saves folder, <root>/<H.db>/saves, where <root> is CP_TEST_SAVES
-- (tests/run.lua makes one per run and removes it at the end) or a temporary folder removed when the spec's
-- Lua state closes. GetResourcePath returns <root>/<H.db>.
local function SavesRoot()
    if H.savesRoot then return H.savesRoot end
    local root = os.getenv('CP_TEST_SAVES')
    if not root or root == '' then
        root = os.tmpname()
        os.remove(root)
        os.execute(('mkdir -p \'%s\''):format(root))
        H._savesCleanup = setmetatable({}, {
            __gc = function() os.execute(('rm -rf \'%s\''):format(root)) end,
        })
    end
    H.savesRoot = root
    return root
end
function H.resourcePath() return SavesRoot() .. '/' .. H.db end
function H.savesDir() return H.resourcePath() .. '/saves' end

local function Memsql()
    _G.CP = _G.CP or {}
    if not _G.json then
        _G.json = {
            encode = function(v) return cjson.encode(v) end,
            decode = function(s) return cjson.decode(s) end,
        }
    end
    if not (CP.Storage and CP.Storage.MemSQL and CP.Storage.MemSQL.new) then
        dofile(ROOT .. 'modules/storage/memsql.lua')
    end
    return CP.Storage.MemSQL
end
H.memsql = Memsql

-- fn(...) with os.time() pinned to ts (os.time(table) still converts); returns pcall's results.
local function WithClock(ts, fn, ...)
    local saved = os.time
    os.time = function(t) if t then return REAL_TIME(t) end return ts end
    local res = table.pack(pcall(fn, ...))
    os.time = saved
    return table.unpack(res, 1, res.n)
end

-- The migrations runner's statement split (modules/migrations/server.lua).
local function SplitStatements(sql)
    local statements, current = {}, {}
    for line in (sql .. '\n'):gmatch('(.-)\r?\n') do
        local code = line:gsub('%-%-.*$', '')
        if code:match('%S') then
            current[#current + 1] = code
            if code:match(';%s*$') then
                statements[#statements + 1] = table.concat(current, '\n'):gsub(';%s*$', '')
                current = {}
            end
        end
    end
    local rest = table.concat(current, '\n')
    if rest:match('%S') then statements[#statements + 1] = rest end
    return statements
end
H.splitStatements = SplitStatements

-- The statements of one H.sql text: split at ';' outside quotes and comments, each with its share of the
-- '?' parameters. A SET NAMES statement is dropped: oxmysql and the engine talk utf8mb4 already.
local function SplitSql(sql, params)
    local out, start, i, n, q = {}, 1, 1, #sql, nil
    local marks = {}   -- '?' positions outside quotes and comments
    local cuts = {}
    while i <= n do
        local c = sql:sub(i, i)
        if q then
            if c == '\\' and q ~= '`' then
                i = i + 1
            elseif c == q then
                if sql:sub(i + 1, i + 1) == q then i = i + 1 else q = nil end
            end
        elseif c == '\'' or c == '"' or c == '`' then
            q = c
        elseif (c == '-' and sql:sub(i + 1, i + 1) == '-') or c == '#' then
            i = (sql:find('\n', i, true) or n)
        elseif c == '?' then
            marks[#marks + 1] = i
        elseif c == ';' then
            cuts[#cuts + 1] = i
        end
        i = i + 1
    end
    cuts[#cuts + 1] = n + 1
    local p, m = 1, 1
    for _, cut in ipairs(cuts) do
        local text = sql:sub(start, cut - 1)
        local count = 0
        while marks[m] and marks[m] < cut do count = count + 1; m = m + 1 end
        local code = text:gsub('%-%-[^\n]*', ''):gsub('#[^\n]*', '')
        if code:match('%S') and not code:match('^%s*[Ss][Ee][Tt]%s+[Nn][Aa][Mm][Ee][Ss]%s') then
            local ps = nil
            if type(params) == 'table' then
                ps = {}
                for k = 1, count do ps[k] = params[p + k - 1] end
            end
            out[#out + 1] = { sql = text:match('^%s*(.-)%s*$'), params = ps }
        end
        p = p + count
        start = cut + 1
    end
    return out
end
H.splitSql = SplitSql

-- A module statement with a "SET NAMES x; " prefix (a spec's charset wrapper for the mysql CLI) without it.
local function StripSetNames(sql)
    return (sql:gsub('^%s*[Ss][Ee][Tt]%s+[Nn][Aa][Mm][Ee][Ss]%s+[%w_]+%s*;%s*', ''))
end

-- Does a statement name a table of another resource (not cp_*)? Those stay on MariaDB.
local function NamesForeignTable(sql)
    local M = Memsql()
    local ok, ast = pcall(M.parse, sql)
    if ok then
        for _, name in ipairs(ast.tables) do
            if name:sub(1, 3) ~= 'cp_' then return true end
        end
        return false
    end
    return not sql:find('cp_', 1, true)
end

-- A spec's Lua table parameter is sent as JSON text, like the MariaDB path (sqlLiteral) does.
local function SpecParams(params)
    if type(params) ~= 'table' then return params end
    local copy, n = {}, 0
    for k in pairs(params) do if math.type(k) == 'integer' and k > n then n = k end end
    for i = 1, n do
        local v = params[i]
        if type(v) == 'table' then v = cjson.encode(v) end
        copy[i] = v
    end
    return copy
end

-- The real migrations runner (modules/migrations/server.lua) on a MySQL table, before H.boot: its own CP,
-- no console lines. Fails when the runner does not reach "ready".
local function RunMigrations(mysqlImpl)
    local errs = {}
    local env = setmetatable({}, { __index = _G })
    env.CP = {
        err = function(_, fmt, ...) errs[#errs + 1] = tostring(fmt):format(...) end,
        log = function() end,
        warn = function() end,
    }
    env.MySQL = mysqlImpl
    env.print = function() end
    env.promise = {
        new = function()
            local p = {}
            function p:resolve(v) self.resolved = true; self.value = v end
            function p:reject(e) self.resolved = true; self.err = e end
            return p
        end,
    }
    env.Citizen = {
        Await = function(p) return p.value end,
    }
    env.CreateThread = function(fn) fn() end
    env.SetTimeout = function() end
    env.StopResource = function() end
    env.GetCurrentResourceName = function() return 'Crimson-Police' end
    env.LoadResourceFile = function(_, path)
        local f = io.open(ROOT .. path, 'r')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end
    local chunk = assert(loadfile(ROOT .. 'modules/migrations/server.lua', 't', env))
    chunk()
    if not (env.CP.Migrations and env.CP.Migrations.isReady()) then
        error('the migrations runner failed: ' .. table.concat(errs, ' | '), 2)
    end
end

-- ============================================================================
--                      FILES MODE (CP_TEST_STORAGE=files)
-- ============================================================================
-- Runs Crimson-Police with Config.Database.enabled = false: H.boot loads modules/storage, which swaps MySQL
-- for the saves folder engine. The specs' own statements (H.sql) go to the same engine and come back typed
-- like oxmysql; statements on another resource's table (mdt_dispatch fixtures) still go to MariaDB, as the
-- real oxmysql would serve them.

-- The engine the specs' statements use: the booted resource's, or (before H.boot) one over the same folder.
local preBootDb, preBootFor = nil, nil
local function FilesEngine()
    if CP and CP.Storage and CP.Storage.db then return CP.Storage.db end
    local dir = H.savesDir()
    if preBootDb and preBootFor == dir then return preBootDb end
    local M = Memsql()
    preBootDb = M.new({ store = M.folderStore(dir) }):load()
    preBootFor = dir
    return preBootDb
end

local function FilesSql(sql, params)
    local rows, cols = {}, nil
    for _, st in ipairs(SplitSql(sql, params)) do
        if NamesForeignTable(st.sql) then
            rows, cols = RawSql(st.sql, st.params)
        else
            local res = FilesEngine():exec(st.sql, SpecParams(st.params))
            if res.kind == 'rows' then
                rows, cols = CP.Storage.MemSQL.luaRows(res), res.cols
            else
                rows, cols = {}, nil
            end
        end
    end
    lastHeader = cols
    return rows, cols
end
if H.storage == 'files' then H.sql = FilesSql end

-- A spec about database-off mode itself (tests/storage_spec.lua) runs in files mode whatever CP_TEST_STORAGE
-- says: call H.useFiles() before H.resetDatabase / H.boot.
function H.useFiles()
    H.storage = 'files'
    H.sql = FilesSql
end

-- A server restart inside one spec: every handler, callback, command, recorded event, sleeping thread and module
-- table is dropped; in files mode the next H.boot loads a new engine from the same saves folder.
function H.restart()
    H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
    sleeping = {}
    H.filesMySQL = nil
    preBootDb, preBootFor = nil, nil
    _G.CP, _G.Config, _G.MySQL = nil, nil, nil
end

-- ============================================================================
--                     SHADOW MODE (CP_TEST_STORAGE=shadow)
-- ============================================================================
-- The specs get exactly what database mode gives them (MySQL.* and H.sql answered by MariaDB through the
-- mysql CLI). Every call also runs, in lockstep, on
--   the twin: the MariaDB database <H.db>_ox, read by tests/shadow/twin.cjs (node + mysql2 with oxmysql's
--             options, typeCast, parseArguments, parseResponse and error text), and
--   the engine: CP.Storage.MemSQL over the saves folder <root>/<H.db>/saves, called through its MySQL drop-in
--             (CP.Storage.MemSQL.shim) exactly as the modules call it in files mode,
-- both built from the migrated empty schema by the real migrations runner. NOW() is pinned to the same second
-- on both (SET timestamp on the twin, os.time() for the engine), and the engine keeps its saves folder
-- between specs like a restarted server. A spec's statements on another resource's table (mdt_dispatch
-- fixtures) run on the twin only; module reads of it go through the drop-in's route to the real oxmysql,
-- which is the twin. Statements whose text is not valid UTF-8 cannot pass through oxmysql and are skipped.
-- Compared: errors (both texts, the twin database name read as `saves`), rows (as multisets; in order when
-- the statement has a top-level ORDER BY), each value and its Lua type (integer, float, string, boolean),
-- DATETIME values within 2 s, affected rows, insert ids, changed rows, warnings and info of writes. At the
-- end of each spec (H.shadowFinish, called by tests/run.lua) every cp_ table and AUTO_INCREMENT counter of
-- the twin is compared with the engine's.
-- Each difference is one JSON line appended to CP_SHADOW_REPORT:
--   { "spec", "db", "category", "kind", "sql", "params", "mariadb": {ok, r | e}, "engine": {ok, r | e},
--     "detail", "at": [module frames], "from": "tests/x_spec.lua:12" }
-- categories: error (one side failed), error-text, rowcount, value, type, order, result (shape),
-- affectedRows, insertId, changedRows, warnings, info, state (end-of-spec table contents), state-autoinc.
-- Per-spec counts (compared, differences, skipped) are appended to CP_SHADOW_REPORT .. '.stats'.
local KINDS = { 'query', 'single', 'scalar', 'insert', 'update' }
local Shadow = { compared = 0, diffs = 0, skipped = 0, byCat = {}, skips = {} }
H.shadowStats = Shadow
local SHADOW_REPORT = os.getenv('CP_SHADOW_REPORT')
if not SHADOW_REPORT or SHADOW_REPORT == '' then
    SHADOW_REPORT = (os.getenv('TMPDIR') or '/tmp') .. '/cp_shadow_report.jsonl'
end
H.shadowReport = SHADOW_REPORT

local function TwinName(db) return db .. '_ox' end
H.twinName = TwinName

local twin = nil
local function TwinStart()
    if twin then return twin end
    local dir = os.tmpname()
    os.remove(dir)
    os.execute(('mkdir -p \'%s\''):format(dir))
    local fifo = dir .. '/twin.out'
    if not os.execute(('mkfifo \'%s\''):format(fifo)) then error('shadow mode: mkfifo failed') end
    local nodePath = os.getenv('CP_SHADOW_NODE_PATH')
    local envs = (nodePath and nodePath ~= '') and ('NODE_PATH=\'' .. nodePath .. '\' ') or ''
    local check = io.popen(('cd \'%sshadow\' && %snode -e "require(\'mysql2/promise\')" 2>&1'):format(TESTS, envs))
    local msg = check:read('a')
    if not check:close() then
        os.execute(('rm -rf \'%s\''):format(dir))
        error('shadow mode needs node and the mysql2 package (cd tests/shadow && npm install): ' .. msg, 0)
    end
    local w = assert(io.popen(('%sexec node \'%sshadow/twin.cjs\' \'%s\''):format(envs, TESTS, fifo), 'w'))
    local r = assert(io.open(fifo, 'r'))
    local hello = r:read('l')
    os.remove(fifo)
    os.remove(dir)
    if not hello or not hello:find('"ready"', 1, true) then
        error('shadow mode: the twin did not start: ' .. tostring(hello), 0)
    end
    twin = { w = w, r = r }
    return twin
end

-- JSON numbers come back as floats from cjson: integral ones are integers, as FiveM hands JS numbers to Lua.
local function FromTwin(v)
    local t = type(v)
    if t == 'number' then
        if v == math.floor(v) and v > -2 ^ 53 and v < 2 ^ 53 then return math.tointeger(v) end
        return v
    elseif t == 'table' then
        local out = {}
        for k, x in pairs(v) do
            if x ~= cjson.null then out[k] = FromTwin(x) end
        end
        return out
    end
    return v
end

-- A table after the NUI round trip (server -> client -> SendNUIMessage -> the NUI's JSON.parse and JSON.stringify
-- -> RegisterNUICallback -> TriggerServerEvent): JavaScript has one number type, so JSON.stringify writes 80.0 as 80
-- and the client's json.decode (lua-rapidjson, FACTS L8) reads it back as an integer; a nil-valued field is dropped.
function H.viaNui(v) return FromTwin(cjson.decode(cjson.encode(v))) end

local function TwinCall(req)
    local t = TwinStart()
    t.w:write(req, '\n')
    t.w:flush()
    local line = t.r:read('l')
    if not line then error('shadow mode: the MariaDB twin (tests/shadow/twin.cjs) stopped', 0) end
    return FromTwin(cjson.decode(line))
end

local function ParamsJson(params)
    if type(params) ~= 'table' then return '[]' end
    local n = 0
    for k in pairs(params) do if math.type(k) == 'integer' and k > n then n = k end end
    local out = {}
    for i = 1, n do out[i] = Enc(params[i]) end
    return '[' .. table.concat(out, ',') .. ']'
end

local function TwinQuery(kind, sql, params, ts)
    return TwinCall(('{"op":"q","db":%s,"kind":%s,"sql":%s,"params":%s,"ts":%s}'):format(Jstr(TwinName(H.db)),
        Jstr(kind), Jstr(sql), ParamsJson(params), ts and ('%d'):format(ts) or 'null'))
end

-- The engine of H.db (loaded from its saves folder) and its MySQL drop-in. The drop-in's route to the real
-- oxmysql (another resource's table) answers with the twin's answer to the same statement.
local shadowEngines, lastTwin = {}, nil
local twinForeign = {}
for _, kind in ipairs(KINDS) do
    twinForeign[kind] = {
        await = function()
            local T = lastTwin
            if not T then error('shadow mode: no MariaDB answer for this statement', 0) end
            if not T.ok then error(T.e, 0) end
            return T.r
        end,
    }
end

local function ShadowEngine()
    local e = shadowEngines[H.db]
    if e then return e end
    local M = Memsql()
    local db = M.new({ store = M.folderStore(H.savesDir()) })
    local ok, err = WithClock(REAL_TIME(), db.load, db)
    if not ok then error('shadow mode: the saves folder could not be loaded: ' .. tostring(err), 0) end
    e = { db = db, name = H.db, shim = M.shim(db, { realMySQL = twinForeign, resource = 'Crimson-Police' }) }
    shadowEngines[H.db] = e
    return e
end

local reportFile = nil
local function ClipRows(v)
    if type(v) == 'table' and #v > 40 then
        local out = {}
        for i = 1, 40 do out[i] = v[i] end
        out[41] = ('... %d rows in all'):format(#v)
        return out
    end
    return v
end
local function Report(rec)
    Shadow.diffs = Shadow.diffs + 1
    Shadow.byCat[rec.category] = (Shadow.byCat[rec.category] or 0) + 1
    local at, from = SqlFrames()
    rec.at, rec.from, rec.spec, rec.db = at, from, SPEC_NAME, H.db
    if not reportFile then reportFile = assert(io.open(SHADOW_REPORT, 'a')) end
    reportFile:write((Enc(rec):gsub('\\/', '/')), '\n')
    reportFile:flush()
end

-- ============================================================================
--                              COMPARING ANSWERS
-- ============================================================================

local DT_TYPES = { DATETIME = true, DATETIME2 = true, TIMESTAMP = true, TIMESTAMP2 = true, NEWDATE = true }

-- Text made by SQL UUID() (a version-1 UUID, random by definition on both sides; the modules' own ids are
-- version 4 and passed as parameters) matches any other UUID() text.
local function SqlUuid(s)
    return s:match('^%x%x%x%x%x%x%x%x%-%x%x%x%x%-1%x%x%x%-[89abAB]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$') ~= nil
end

local function ValDiff(a, b, isDT)
    if a == nil or b == nil then
        if a == b then return nil end
        return 'value'
    end
    local ta, tb = type(a), type(b)
    if ta ~= tb then return 'type' end
    if ta == 'number' then
        if math.type(a) ~= math.type(b) then return 'type' end
        if a == b then return nil end
        if isDT and math.abs(a - b) <= 2000 then return nil end
        return 'value'
    end
    if ta == 'table' then
        for k, v in pairs(a) do local d = ValDiff(v, b[k]) if d then return d end end
        for k, v in pairs(b) do if a[k] == nil and v ~= nil then return 'value' end end
        return nil
    end
    if a == b then return nil end
    if ta == 'string' and SqlUuid(a) and SqlUuid(b) then return nil end
    return 'value'
end

local function RowDiff(ra, rb, dt)
    if type(ra) ~= 'table' or type(rb) ~= 'table' then
        if ra == nil and rb == nil then return nil end
        return 'result'
    end
    local worst = nil
    for k, v in pairs(ra) do
        local d = ValDiff(v, rb[k], dt[k])
        if d == 'value' then return 'value', k end
        if d then worst = worst or d end
    end
    for k, v in pairs(rb) do
        if ra[k] == nil then return 'value', k end
    end
    return worst
end

local function Canon(row)
    local keys = {}
    for k in pairs(row) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do
        local v = row[k]
        local t = type(v) == 'number' and math.type(v) or type(v)
        out[i] = k .. '\1' .. t .. '\1' .. (type(v) == 'table' and Enc(v) or tostring(v))
    end
    return table.concat(out, '\2')
end

-- Rows as multisets: nil when equal, else the category and the rows left over on each side (DATETIME columns
-- may differ by 2 s).
local function MultisetDiff(A, B, dt)
    local byKey = {}
    for i, r in ipairs(A) do
        local c = Canon(r)
        local l = byKey[c]
        if not l then l = {}; byKey[c] = l end
        l[#l + 1] = i
    end
    local matchedA, restB = {}, {}
    for _, r in ipairs(B) do
        local l = byKey[Canon(r)]
        if l and #l > 0 then matchedA[table.remove(l)] = true else restB[#restB + 1] = r end
    end
    local restA = {}
    for i, r in ipairs(A) do if not matchedA[i] then restA[#restA + 1] = r end end
    if #restA == 0 and #restB == 0 then return nil end
    local used, unA = {}, {}
    for _, ra in ipairs(restA) do
        local found = false
        for j, rb in ipairs(restB) do
            if not used[j] and RowDiff(ra, rb, dt) == nil then used[j] = true; found = true; break end
        end
        if not found then unA[#unA + 1] = ra end
    end
    local unB = {}
    for j, rb in ipairs(restB) do if not used[j] then unB[#unB + 1] = rb end end
    if #unA == 0 and #unB == 0 then return nil end
    local cat = 'value'
    if #unA > 0 and #unB > 0 then cat = RowDiff(unA[1], unB[1], dt) or 'value' end
    return cat, unA, unB
end

local function RowsDiff(A, B, dt, ordered)
    if type(A) ~= 'table' or type(B) ~= 'table' then return 'result' end
    if #A ~= #B then return 'rowcount' end
    local cat = MultisetDiff(A, B, dt)
    if cat then return cat end
    if ordered then
        for i = 1, #A do
            if RowDiff(A[i], B[i], dt) then return 'order', ('first at row %d'):format(i) end
        end
    end
    return nil
end

local function NormErr(s)
    s = tostring(s)
    local name = TwinName(H.db):gsub('%p', '%%%0')
    return (s:gsub(name, 'saves'))
end

local function HasOrderBy(sql)
    local ok, ast = pcall(Memsql().parse, sql)
    return ok and type(ast.order) == 'table' and #ast.order > 0
end

local WRITE_FIELDS = { 'affectedRows', 'insertId', 'changedRows', 'warningStatus', 'info' }
local WRITE_CAT = {
    affectedRows = 'affectedRows',
    insertId = 'insertId',
    changedRows = 'changedRows',
    warningStatus = 'warnings',
    info = 'info',
}

local SHADOW_TRACE = os.getenv('CP_SHADOW_TRACE')   -- set: every compared pair is written to stderr
local function CompareAnswers(kind, sql, params, T, okE, resE)
    if SHADOW_TRACE and SHADOW_TRACE ~= '' then
        io.stderr:write(Enc({ kind = kind, sql = sql, params = params, mariadb = T, engine = { ok = okE, r = resE } }),
            '\n')
    end
    local cat, detail
    if not T.ok or not okE then
        if T.ok ~= okE then
            cat = 'error'
            detail = T.ok and 'only the engine failed' or 'only MariaDB failed'
        elseif NormErr(T.e) ~= NormErr(resE) then
            cat = 'error-text'
        end
    else
        local r = T.r
        local dt = {}
        if T.f then for _, f in ipairs(T.f) do if DT_TYPES[f[2]] then dt[f[1]] = true end end end
        if kind == 'scalar' then
            cat = ValDiff(r, resE, T.f and T.f[1] and DT_TYPES[T.f[1][2]])
        elseif kind == 'insert' then
            if ValDiff(r, resE) then cat = 'insertId' end
        elseif kind == 'update' then
            if ValDiff(r, resE) then cat = 'affectedRows' end
        elseif kind == 'single' then
            cat, detail = RowDiff(r, resE, dt)
        elseif T.f then
            if type(resE) == 'table' and resE.affectedRows ~= nil then
                cat, detail = 'result', 'rows on MariaDB, a write result from the engine'
            else
                cat, detail = RowsDiff(r, resE, dt, HasOrderBy(sql))
            end
        elseif type(r) == 'table' and type(resE) == 'table' and r.affectedRows ~= nil then
            for _, k in ipairs(WRITE_FIELDS) do
                if ValDiff(r[k], resE[k]) then cat = WRITE_CAT[k]; detail = k; break end
            end
        else
            cat = ValDiff(r, resE) and 'result' or nil
        end
    end
    if cat then
        Report({
            category = cat,
            detail = detail,
            kind = kind,
            sql = sql,
            params = params,
            mariadb = T.ok and { ok = true, r = ClipRows(T.r) } or { ok = false, e = T.e },
            engine = okE and { ok = true, r = ClipRows(resE) } or { ok = false, e = tostring(resE) },
        })
    end
end

local function BadUtf8(sql, params)
    if not utf8.len(sql) then return true end
    if type(params) == 'table' then
        for _, v in pairs(params) do if type(v) == 'string' and not utf8.len(v) then return true end end
    end
    return false
end

-- The migrations runner's statements for the database server itself (its version check, the utf8mb4 tables): it only
-- sends them with the database on, and the saves folder engine has no server version or character sets. Shadow mode
-- runs them on MariaDB alone (a skip, listed).
local function ServerOnly(sql)
    local s = sql:upper()
    return s:find('^%s*SELECT%s+VERSION%(%)') ~= nil or s:find('CONVERT%s+TO%s+CHARACTER%s+SET') ~= nil
        or (s:find('INFORMATION_SCHEMA.', 1, true) ~= nil and s:find('COLLATION', 1, true) ~= nil)
        or s:find('^%s*ALTER%s+TABLE%s+`CP_[%w_]+`%s+MODIFY%s+`[%w_]+`%s+JSON') ~= nil
end

-- One statement on the twin and on the engine (in that order, same pinned second); the twin's answer.
local function PairRun(kind, sql, params, fromSpec)
    if not fromSpec and ServerOnly(sql) then
        Shadow.skipped = Shadow.skipped + 1
        Shadow.skips[#Shadow.skips + 1] = {
            reason = 'the database server only (the runner never sends it to the saves folder)',
            sql = sql:sub(1, 160),
        }
        return TwinQuery(kind, sql, params, REAL_TIME())
    end
    if BadUtf8(sql, params) then
        Shadow.skipped = Shadow.skipped + 1
        Shadow.skips[#Shadow.skips + 1] = {
            reason = 'text is not valid UTF-8 (oxmysql cannot send it)',
            sql = sql:sub(1, 160),
        }
        return nil
    end
    local foreign = NamesForeignTable(sql)
    local ts = REAL_TIME()
    local T = TwinQuery(kind, sql, params, ts)
    if T.twin then error('shadow mode: twin failure: ' .. tostring(T.e), 0) end
    if foreign and fromSpec then return T end
    Shadow.compared = Shadow.compared + 1
    lastTwin = T
    local okE, resE = WithClock(ts, ShadowEngine().shim[kind].await, sql, params)
    lastTwin = nil
    CompareAnswers(kind, sql, params, T, okE, resE)
    return T
end

local function ShadowCompare(kind, sql, params, fromSpec)
    if type(sql) ~= 'string' then return end
    if fromSpec then
        for _, st in ipairs(SplitSql(sql, params)) do PairRun('query', st.sql, SpecParams(st.params), true) end
    else
        local s = StripSetNames(sql)
        if s:match('%S') then PairRun(kind, s, params, false) end
    end
end

-- MySQL for the modules in shadow mode: MariaDB's answer (database mode) is returned, after the comparison.
local function MakeShadowMySQL()
    local S = {}
    for _, kind in ipairs(KINDS) do
        local m = {}
        m.await = function(sql, params)
            local okM, resM = pcall(MySQL[kind].await, sql, params)
            ShadowCompare(kind, sql, params, false)
            if not okM then error(resM, 0) end
            return resM
        end
        setmetatable(m, {
            __call = function(_, sql, params, cb)
                local r = m.await(sql, params)
                if cb then cb(r) end
                return r
            end,
        })
        S[kind] = m
    end
    S.prepare = MySQL.prepare
    S.transaction = {
        await = function(queries)
            for _, q in ipairs(queries) do
                if type(q) == 'table' then
                    S.query.await(q.query or q[1], q.values or q.parameters or q[2])
                else
                    S.query.await(q)
                end
            end
            return true
        end,
    }
    S.ready = function(cb) cb() end
    return S
end

-- MySQL for the migrations runner: the twin and the engine only (the harness database is built by the CLI).
local function MakePairMySQL()
    local S = {}
    for _, kind in ipairs(KINDS) do
        S[kind] = {
            await = function(sql, params)
                local T = PairRun(kind, sql, params, false)
                if not T then return nil end
                if not T.ok then error(T.e, 0) end
                return T.r
            end,
        }
    end
    S.ready = function(cb) cb() end
    return S
end

local function ShadowSql(sql, params)
    local okM, rows, header = pcall(RawSql, sql, params)
    ShadowCompare('query', sql, params, true)
    if not okM then error(rows, 0) end
    return rows, header
end
if H.storage == 'shadow' then
    H.sql = ShadowSql
    H.shadowMySQL = MakeShadowMySQL()
end

-- End of a spec: every cp_ table and AUTO_INCREMENT counter of each twin equals the engine's.
function H.shadowFinish()
    if H.storage ~= 'shadow' then return end
    local savedDb = H.db
    for name, e in pairs(shadowEngines) do
        H.db = name
        local T = TwinQuery('query',
            'SELECT table_name AS t, auto_increment AS a FROM information_schema.tables WHERE table_schema = DATABASE()',
            {}, nil)
        local twinTables = {}
        if T.ok then
            for _, row in ipairs(T.r) do if row.t:sub(1, 3) == 'cp_' then twinTables[row.t] = row.a or false end end
        end
        local engineTables = {}
        for _, t in ipairs(e.db.order) do engineTables[t.name] = t end
        for tname in pairs(twinTables) do
            if not engineTables[tname] then
                Report({ category = 'state', detail = 'table missing in the engine', sql = tname })
            end
        end
        for tname, t in pairs(engineTables) do
            if twinTables[tname] == nil then
                Report({ category = 'state', detail = 'table missing on MariaDB', sql = tname })
            else
                local sql = 'SELECT * FROM `' .. tname .. '`'
                local TR = TwinQuery('query', sql, {}, nil)
                local okE, resE = WithClock(REAL_TIME(), e.shim.query.await, sql)
                local dt = {}
                if TR.f then for _, f in ipairs(TR.f) do if DT_TYPES[f[2]] then dt[f[1]] = true end end end
                local cat, restA, restB
                if not TR.ok or not okE then
                    cat = 'error'
                else
                    cat, restA, restB = MultisetDiff(TR.r, resE, dt)
                    if cat and #TR.r ~= #resE then cat = 'rowcount' end
                end
                if cat then
                    Report({
                        category = 'state',
                        detail = tname .. ': ' .. cat,
                        sql = sql,
                        mariadb = TR.ok and { ok = true, r = ClipRows(restA or TR.r) } or { ok = false, e = TR.e },
                        engine = okE and { ok = true, r = ClipRows(restB or resE) }
                            or { ok = false, e = tostring(resE) },
                    })
                end
                local twinNext = twinTables[tname]
                if t.autoCol and twinNext and twinNext ~= t.nextId then
                    Report({
                        category = 'state-autoinc',
                        detail = ('%s: AUTO_INCREMENT %s on MariaDB, %s in the engine'):format(tname,
                            tostring(twinNext), tostring(t.nextId)),
                        sql = tname,
                    })
                end
            end
        end
    end
    H.db = savedDb
    local f = io.open(SHADOW_REPORT .. '.stats', 'a')
    if f then
        f:write(Enc({
            spec = SPEC_NAME,
            compared = Shadow.compared,
            diffs = Shadow.diffs,
            skipped = Shadow.skipped,
            byCat = Shadow.byCat,
            skips = Shadow.skips,
        }), '\n')
        f:close()
    end
end

-- A check that only means something on MariaDB (information_schema, the mysql CLI): skipped in `mode`.
-- Prints "SKIP <spec>: <reason>" (tests/run.lua lists every skip) and returns true when skipped.
function H.skipIn(mode, reason)
    if H.storage ~= mode then return false end
    print(('SKIP %s (%s mode): %s'):format(SPEC_NAME, mode, reason))
    return true
end

-- TINYINT(1) the way the spec's storage hands it over: 0/1 from the harness' MariaDB, false/true from
-- oxmysql and the saves folder engine. H.bit(v) gives 0/1 either way (anything else is returned as is).
function H.bit(v)
    if v == true then return 1 elseif v == false then return 0 end
    return v
end

-- ============================================================================
--                        SHARED ENTITY MODEL (H.entity)
-- ============================================================================
-- One model of server-side entities for the specs that need moving cars and people: H.entity(netId, fields)
-- makes (or returns) the entity of that net id. Its fields back GetEntityCoords, GetEntityHeading,
-- GetEntitySpeed, GetVehiclePedIsIn, GetPedInVehicleSeat, IsVehicleSirenOn, GetVehicleBodyHealth,
-- GetVehicleEngineHealth, DoesEntityExist, GetAllVehicles and the net id natives (installed by H.boot; a spec
-- that defines its own natives after H.boot replaces them). H.advance moves each entity by its velocity (m/s) and
-- applies its timeline: e:at(ms, patch) sets fields when the fake clock reaches ms.
--   fields: coords, heading, speed, velocity = vec3, health, body, engine, seats = { [-1] = pedHandle },
--           siren, exists, vehicle (the vehicle a ped sits in), model, kind ('ped' | 'vehicle' | 'object')
local ENTITY_BASE = 800000
local model = { byNet = {}, byHandle = {} }
H.entityModel = model

local entityMeta = {}
entityMeta.__index = entityMeta
function entityMeta:at(ms, patch)
    self.timeline = self.timeline or {}
    self.timeline[#self.timeline + 1] = { at = ms, patch = patch }
    table.sort(self.timeline, function(a, b) return a.at < b.at end)
    return self
end
function entityMeta:set(patch)
    for k, v in pairs(patch or {}) do self[k] = v end
    return self
end

function H.entity(netId, fields)
    netId = math.tointeger(netId)
    local e = model.byNet[netId]
    if not e then
        e = setmetatable({
            netId = netId,
            handle = ENTITY_BASE + netId,
            kind = 'vehicle',
            coords = Vec(0.0, 0.0, 0.0),
            heading = 0.0,
            speed = 0.0,
            health = 200,
            body = 1000.0,
            engine = 1000.0,
            seats = {},
            siren = false,
            exists = true,
        }, entityMeta)
        model.byNet[netId] = e
        model.byHandle[e.handle] = e
    end
    if fields then e:set(fields) end
    return e
end

-- Forget every modelled entity (a spec that reuses net ids between cases).
function H.resetEntities()
    model.byNet, model.byHandle = {}, {}
end

H._entityTick = function(ms)
    if next(model.byNet) == nil then return end
    local now = H.clockMs
    for _, e in pairs(model.byNet) do
        local v = e.velocity
        if v and e.exists and ms > 0 then
            local dt = ms / 1000
            e.coords = Vec(e.coords.x + (v.x or 0) * dt, e.coords.y + (v.y or 0) * dt,
                (e.coords.z or 0) + (v.z or 0) * dt)
            e.speed = math.sqrt((v.x or 0) ^ 2 + (v.y or 0) ^ 2 + (v.z or 0) ^ 2)
        end
        while e.timeline and e.timeline[1] and e.timeline[1].at <= now do
            local step = table.remove(e.timeline, 1)
            e:set(step.patch)
        end
    end
end

local function ModelEntity(handle) return model.byHandle[handle] end

-- Installed by H.boot: the modelled entities first, then the harness defaults (player peds are src * 100).
local function InstallEntityNatives()
    local playerCoords = _G.GetEntityCoords
    _G.GetEntityCoords = function(ent)
        local e = ModelEntity(ent)
        if e then return e.coords end
        return playerCoords(ent)
    end
    _G.DoesEntityExist = function(ent)
        local e = ModelEntity(ent)
        if e then return e.exists == true end
        return true
    end
    _G.GetEntityHeading = function(ent)
        local e = ModelEntity(ent)
        return e and e.heading + 0.0 or 0.0
    end
    _G.GetEntitySpeed = function(ent)
        local e = ModelEntity(ent)
        return e and e.speed + 0.0 or 0.0
    end
    _G.GetVehiclePedIsIn = function(ped)
        local e = ModelEntity(ped)
        if e then return e.vehicle or 0 end
        local p = H.players[math.floor((ped or 0) / 100)]
        return p and p.vehicle or 0
    end
    _G.GetPedInVehicleSeat = function(veh, seat)
        local e = ModelEntity(veh)
        return e and e.seats[seat or -1] or 0
    end
    _G.IsVehicleSirenOn = function(veh)
        local e = ModelEntity(veh)
        return e ~= nil and e.siren == true
    end
    _G.GetVehicleBodyHealth = function(veh)
        local e = ModelEntity(veh)
        return e and e.body + 0.0 or 1000.0
    end
    _G.GetVehicleEngineHealth = function(veh)
        local e = ModelEntity(veh)
        return e and e.engine + 0.0 or 1000.0
    end
    _G.NetworkGetEntityFromNetworkId = function(netId)
        local e = model.byNet[math.tointeger(tonumber(netId) or -1) or -1]
        return e and e.handle or 0
    end
    _G.NetworkGetNetworkIdFromEntity = function(ent)
        local e = ModelEntity(ent)
        return e and e.netId or 0
    end
    -- GET_ALL_VEHICLES (FXServer): a Lua list of the handle of every vehicle the server knows (a player's own car, a
    -- parked or passing one, every mission's), here every modelled vehicle that exists, by net id
    _G.GetAllVehicles = function()
        local list = {}
        for _, e in pairs(model.byNet) do
            if e.kind == 'vehicle' and e.exists == true then list[#list + 1] = e end
        end
        table.sort(list, function(a, b) return a.netId < b.netId end)
        local out = {}
        for i, e in ipairs(list) do out[i] = e.handle end
        return out
    end
end

-- ============================================================================
--                        OTHER RESOURCES (opt-in mocks)
-- ============================================================================
-- ox_inventory: H.mockInventory(items) installs Items, Search, CanCarryItem, AddItem, RemoveItem and registerHook with
-- the matching of the real ox_inventory 2.48.0 (modules/inventory/server.lua) and ox_lib 3.40.0
-- (imports/table/shared.lua):
-- - Search(src, 'slots'|'count', name, metadata) keeps a slot when every VALUE of metadata is one of the slot's
--   metadata values (table.contains): the keys are ignored, so { cpReward = 60 } also finds { degrade = 60 }.
-- - RemoveItem(src, name, count, metadata, slot, ignoreTotal, strict): strict (the default) needs exactly the same
--   table (table.matches); metadata nil takes any slot of the item; a slot with too few items is refused.
-- - AddItem(src, name, count, metadata) adds what modules/items/server.lua Items.Metadata adds: a degrade item gets
--   durability = os.time() + degrade * 60 and degrade, a durability item durability = 100, a container (container
--   = { size }) container and size; a stack item stacks onto a slot whose metadata matches exactly, a non-stack item
--   (stack = false) takes one slot each. An item not in `items` is 'invalid_item' (any item when `items` is empty).
-- Every result crosses the export boundary as a copy (msgpack). CanCarryItem: false while full[src], else true for a
-- known item. The model: { items = { [name] = { label, stack, degrade, durability, container } }, slots = { [src] =
-- { { slot, name, count, metadata } } } (count 0 is an empty slot), full = { [src] = true }, added = { { src, name,
-- count, meta } }, removed = { { src, name, count, slot } } }. ox_target: H.mockTarget() installs addBoxZone,
-- removeZone, addLocalEntity, addEntity (options with bones kept) and returns the recorded zones and options. Its
-- global ped and vehicle options work as ox_target 1.18.1 (client/api.lua addTarget/removeTarget): addGlobalPed /
-- addGlobalVehicle take one option or a list, replace an option of the same name and append the rest in order;
-- removeGlobalPed / removeGlobalVehicle take a name or a list. t.peds and t.vehicles hold the live options,
-- t.globalCalls every call in order ({ op = 'add'|'remove', kind = 'ped'|'vehicle', names }). isActive() answers
-- t.active (the eye menu is open) and counts t.isActiveCalls; t.restart() empties the lists as a restarted ox_target.
local function OxContains(tbl, value)
    if type(value) ~= 'table' then
        for _, v in pairs(tbl) do
            if v == value then return true end
        end
        return false
    end
    local set = {}
    for _, v in pairs(tbl) do set[v] = true end
    for _, v in pairs(value) do
        if not set[v] then return false end
    end
    return true
end

local function OxMatches(t1, t2)
    if type(t1) ~= type(t2) then return false end
    if type(t1) ~= 'table' then return t1 == t2 end
    for k, v1 in pairs(t1) do
        local v2 = t2[k]
        if v2 == nil or not OxMatches(v1, v2) then return false end
    end
    for k in pairs(t2) do
        if t1[k] == nil then return false end
    end
    return true
end

local function DeepCopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = DeepCopy(x) end
    return o
end

function H.mockInventory(items)
    local inv = { items = items or {}, slots = {}, full = {}, added = {}, removed = {} }
    local containerSeq = 0
    local function Def(name)
        if type(name) ~= 'string' then return nil end
        local key = inv.items[name] and name or name:lower()
        local d = inv.items[key]
        if d then return d, key end
        if next(inv.items) == nil then return {}, key end
        return nil
    end
    local function Slots(src)
        inv.slots[src] = inv.slots[src] or {}
        return inv.slots[src]
    end
    local function Used(sl) return type(sl) == 'table' and math.floor(tonumber(sl.count) or 0) > 0 end
    local function SlotAt(src, n)
        for _, sl in ipairs(Slots(src)) do
            if sl.slot == n and Used(sl) then return sl end
        end
        return nil
    end
    local function FreeSlot(src)
        local list = Slots(src)
        for _, sl in ipairs(list) do
            if not Used(sl) then return sl end
        end
        local sl = { slot = #list + 1, count = 0 }
        list[#list + 1] = sl
        return sl
    end
    -- Items.Metadata (a non-weapon item): container, then durability / degrade
    local function Metadata(def, metadata, count)
        if def.container then
            count = 1
            containerSeq = containerSeq + 1
            metadata.container = metadata.container or ('CPT' .. containerSeq)
            metadata.size = DeepCopy(def.container.size)
        end
        if not metadata.durability then
            if def.degrade then
                metadata.durability = os.time() + def.degrade * 60
                metadata.degrade = def.degrade
            elseif def.durability then
                metadata.durability = 100
            end
        end
        if count > 1 and def.stack == false then count = 1 end
        return metadata, count
    end
    -- Inventory.GetItemSlots: { [slot] = count }, total
    local function ItemSlots(src, name, metadata, strict)
        if strict == nil then strict = true end
        local match = strict and OxMatches or OxContains
        local slots, total = {}, 0
        for _, sl in ipairs(Slots(src)) do
            if Used(sl) and sl.name == name then
                if metadata and sl.metadata == nil then sl.metadata = {} end
                if not metadata or match(sl.metadata, metadata) then
                    slots[sl.slot] = sl.count
                    total = total + sl.count
                end
            end
        end
        return slots, total
    end
    H.exportsMock.ox_inventory = {
        Items = function(name)
            if name then return DeepCopy(inv.items[name]) end
            return DeepCopy(inv.items)
        end,
        Search = function(src, kind, name, meta)
            if type(meta) ~= 'nil' and type(meta) ~= 'table' then meta = { type = meta } end
            local out, count = {}, 0
            for _, sl in ipairs(Slots(src)) do
                if Used(sl) and sl.name == name then
                    if not sl.metadata then sl.metadata = {} end
                    if not meta or OxContains(sl.metadata, meta) then
                        out[#out + 1] = DeepCopy(sl)
                        count = count + sl.count
                    end
                end
            end
            if kind == 'count' then return count end
            return out
        end,
        CanCarryItem = function(src, name)
            if inv.full[src] then return false end
            return Def(name) ~= nil
        end,
        AddItem = function(src, name, count, meta)
            local def, key = Def(name)
            if not def then return false, 'invalid_item' end
            if type(count) ~= 'number' then return false, 'invalid_count' end
            count = math.floor(count + 0.5)
            if count <= 0 then return false, 'negative_count' end
            if inv.full[src] then return false, 'inventory_full' end
            if type(meta) ~= 'nil' and type(meta) ~= 'table' then meta = { type = meta } end
            local placed = {}
            local left = count
            while left > 0 do
                local md, n = Metadata(def, meta and DeepCopy(meta) or {}, left)
                local target = nil
                if def.stack ~= false then
                    for _, sl in ipairs(Slots(src)) do
                        if Used(sl) and sl.name == key and OxMatches(sl.metadata or {}, md) then
                            target = sl
                            break
                        end
                    end
                end
                if target then
                    target.count = target.count + n
                else
                    target = FreeSlot(src)
                    target.name, target.count, target.metadata = key, n, md
                end
                inv.added[#inv.added + 1] = { src = src, name = key, count = n, meta = target.metadata }
                placed[#placed + 1] = DeepCopy(target)
                left = left - n
            end
            return true, #placed == 1 and placed[1] or placed
        end,
        RemoveItem = function(src, name, count, metadata, slot, ignoreTotal, strict)
            local def, key = Def(name)
            if not def then return false, 'invalid_item' end
            if type(count) ~= 'number' then return false, 'invalid_count' end
            count = math.floor(count + 0.5)
            if count <= 0 then return false, 'negative_count' end
            if slot then
                local sl = SlotAt(src, slot)
                if not sl then return false, 'no_item_in_slot' end
                if count > sl.count then
                    if not ignoreTotal then return false, 'not_enough_items_in_slot' end
                    count = sl.count
                end
            end
            if type(metadata) ~= 'nil' and type(metadata) ~= 'table' then metadata = { type = metadata } end
            local slots, total = ItemSlots(src, key, metadata, strict)
            if count > total then
                if not ignoreTotal then return false, 'not_enough_items' end
                count = total
            end
            local removed = 0
            if slot and slots[slot] then
                SlotAt(src, slot).count = SlotAt(src, slot).count - count
                removed = count
            else
                for n in pairs(slots) do
                    if removed >= count then break end
                    local sl = SlotAt(src, n)
                    local take = math.min(sl.count, count - removed)
                    sl.count = sl.count - take
                    removed = removed + take
                end
            end
            if removed <= 0 then return false, 'not_enough_items' end
            inv.removed[#inv.removed + 1] = { src = src, name = key, count = removed, slot = slot }
            return true
        end,
        registerHook = function() return 1 end,
    }
    return inv
end

function H.mockTarget()
    local t = {
        zones = {},
        entities = {},
        localEntities = {},
        removed = {},
        peds = {},
        vehicles = {},
        globalCalls = {},
        active = false,
        isActiveCalls = 0,
    }
    local nextZone = 0
    local function AddGlobal(list, kind, options)
        if type(options) == 'table' and (options.name or options.label) then options = { options } end
        local names = {}
        for _, o in ipairs(options) do
            names[#names + 1] = o.name
            for i = #list, 1, -1 do
                if o.name and list[i].name == o.name then table.remove(list, i) end
            end
            list[#list + 1] = o
        end
        t.globalCalls[#t.globalCalls + 1] = { op = 'add', kind = kind, names = names }
    end
    local function RemoveGlobal(list, kind, names)
        if type(names) ~= 'table' then names = { names } end
        local copy = {}
        for i, n in ipairs(names) do copy[i] = n end
        for i = #list, 1, -1 do
            for _, n in ipairs(copy) do
                if list[i].name == n then
                    table.remove(list, i)
                    break
                end
            end
        end
        t.globalCalls[#t.globalCalls + 1] = { op = 'remove', kind = kind, names = copy }
    end
    function t.restart()
        t.peds, t.vehicles = {}, {}
    end
    H.exportsMock.ox_target = {
        addBoxZone = function(opts)
            nextZone = nextZone + 1
            t.zones[nextZone] = opts
            return nextZone
        end,
        removeZone = function(id)
            t.removed[#t.removed + 1] = id
            t.zones[id] = nil
        end,
        addLocalEntity = function(ent, options)
            t.localEntities[#t.localEntities + 1] = { entity = ent, options = options }
        end,
        addEntity = function(netIds, options) t.entities[#t.entities + 1] = { netIds = netIds, options = options } end,
        removeEntity = function(netIds, names) t.removed[#t.removed + 1] = { netIds = netIds, names = names } end,
        removeLocalEntity = function(ent, names) t.removed[#t.removed + 1] = { entity = ent, names = names } end,
        addGlobalPed = function(options) AddGlobal(t.peds, 'ped', options) end,
        addGlobalVehicle = function(options) AddGlobal(t.vehicles, 'vehicle', options) end,
        removeGlobalPed = function(names) RemoveGlobal(t.peds, 'ped', names) end,
        removeGlobalVehicle = function(names) RemoveGlobal(t.vehicles, 'vehicle', names) end,
        isActive = function()
            t.isActiveCalls = t.isActiveCalls + 1
            return t.active == true
        end,
    }
    return t
end

-- A CP.Qbx.plateOwned stand-in: owned = { [plate] = true }; fail = true answers nil (a lookup error).
function H.plateOwnedStub(owned, fail)
    local calls = {}
    local fn = function(plate)
        calls[#calls + 1] = plate
        if fail then return nil end
        return owned ~= nil and owned[plate] == true
    end
    return fn, calls
end

-- A clean CP.Hooks (every listener dropped).
function H.resetHooks()
    if CP and CP.Hooks then CP.Hooks._list, CP.Hooks._byId = {}, {} end
end

-- ============================================================================
--            COMBAT NATIVES WITH THEIR REAL ARGUMENT TYPES (opt-in)
-- ============================================================================
-- H.combatNatives(onCall) installs the game natives of NPC combat and of an officer's damage settings. Each one checks
-- its arguments against its parameter types in natives.json (runtime.fivem.net): a float where the game reads a float
-- (the native wrappers hand the raw Lua number to the game, natives_server.lua `_in(hash, ...)`, so an integer arrives
-- as another number: pass `x + 0.0`), an integer for an int, a Ped, a Player or a Vehicle, an integer or a name for a
-- Hash (the wrapper joaat's a name), a boolean for a BOOL, and exactly as many arguments as the native has. A call
-- with a wrong type or count fails the spec, naming the native and the argument. A global the spec set before is
-- still called afterwards (its own recording keeps working); onCall(name, ...) sees the calls of the others.
-- The world it returns keeps what each native set, as the game does:
--   aiDamage, aiMelee: the AI damage modifiers of this game (1.0 = the game's own, also after Reset*)
--   defense[player]: SetPlayerWeaponDefenseModifier (GetPlayerWeaponDefenseModifier answers 1.0 until it is set)
--   flags[ped][id]: ped config flags; SetPedSuffersCriticalHits(ped, false) sets flag 2 (NoCriticalHits)
--   peds[ped] = { accuracy, shootRate, pattern, ability, attrs = { [attr] = on }, weapon, ammo }
--   driveBys = { { ped, target, accuracy, pattern, distance } }, calls = { { name, args } }, typeErrors (a count)
--   world.forget(ped): the ped's own settings are gone (a test of a ped that came back from another game)
--   world.restore(): the globals as they were before H.combatNatives
H.NATIVE_TYPES = {
    SetAiWeaponDamageModifier = { 'float' },
    ResetAiWeaponDamageModifier = {},
    SetAiMeleeWeaponDamageModifier = { 'float' },
    ResetAiMeleeWeaponDamageModifier = {},
    SetPedSuffersCriticalHits = { 'Ped', 'BOOL' },
    GetPedConfigFlag = { 'Ped', 'int', 'BOOL' },
    SetPedConfigFlag = { 'Ped', 'int', 'BOOL' },
    SetPlayerWeaponDefenseModifier = { 'Player', 'float' },
    GetPlayerWeaponDefenseModifier = { 'Player' },
    SetPedAccuracy = { 'Ped', 'int' },
    SetPedShootRate = { 'Ped', 'int' },
    SetPedFiringPattern = { 'Ped', 'Hash' },
    SetPedCombatAbility = { 'Ped', 'int' },
    SetPedCombatAttributes = { 'Ped', 'int', 'BOOL' },
    TaskDriveBy = { 'Ped', 'Ped', 'Vehicle', 'float', 'float', 'float', 'float', 'int', 'BOOL', 'Hash' },
    GiveWeaponToPed = { 'Ped', 'Hash', 'int', 'BOOL', 'BOOL' },
}

local function TypeOk(kind, v)
    if kind == 'float' then return math.type(v) == 'float' end
    if kind == 'BOOL' then return type(v) == 'boolean' end
    if kind == 'Hash' then return math.type(v) == 'integer' or type(v) == 'string' end
    if kind == 'char*' then return type(v) == 'string' end
    if kind == 'Any' then return v ~= nil end
    return math.type(v) == 'integer'   -- int, Ped, Player, Vehicle
end

-- Installs each native of types as a global that checks its arguments, counts a wrong call in w.typeErrors, keeps it
-- in w.calls, runs its effect (every answer of the effect is the native's answer) and then the global the spec had
-- set before (before[name]) or onCall(name, ...).
local function InstallTyped(types, effects, w, onCall, before)
    for name, sig in pairs(types) do
        local prev = rawget(_G, name)
        before[name] = prev
        _G[name] = function(...)
            local n = select('#', ...)
            local args = table.pack(...)
            local ok = n == #sig
            for i, kind in ipairs(sig) do
                if not TypeOk(kind, args[i]) then
                    ok = false
                    H.ok(false, ('%s argument %d: the game reads a %s, got %s %s'):format(name, i, kind,
                        math.type(args[i]) or type(args[i]), tostring(args[i])))
                end
            end
            if n ~= #sig then H.ok(false, ('%s takes %d arguments, got %d'):format(name, #sig, n)) end
            if not ok then w.typeErrors = w.typeErrors + 1 end
            w.calls[#w.calls + 1] = { name = name, args = args }
            local res = table.pack(effects[name](...))
            if prev then
                prev(...)
            elseif onCall then
                onCall(name, ...)
            end
            return table.unpack(res, 1, res.n)
        end
    end
end

function H.combatNatives(onCall)
    local w = { aiDamage = 1.0, aiMelee = 1.0, defense = {}, flags = {}, peds = {}, driveBys = {}, calls = {} }
    w.typeErrors = 0
    local function Ped(ped)
        w.peds[ped] = w.peds[ped] or { attrs = {} }
        return w.peds[ped]
    end
    local function Flags(ped)
        w.flags[ped] = w.flags[ped] or {}
        return w.flags[ped]
    end
    function w.forget(ped) w.peds[ped] = nil end
    local before = {}
    function w.restore()
        for name in pairs(H.NATIVE_TYPES) do rawset(_G, name, before[name]) end
    end
    local effects = {
        SetAiWeaponDamageModifier = function(v) w.aiDamage = v end,
        ResetAiWeaponDamageModifier = function() w.aiDamage = 1.0 end,
        SetAiMeleeWeaponDamageModifier = function(v) w.aiMelee = v end,
        ResetAiMeleeWeaponDamageModifier = function() w.aiMelee = 1.0 end,
        SetPedSuffersCriticalHits = function(ped, on) Flags(ped)[2] = not on end,
        GetPedConfigFlag = function(ped, id) return Flags(ped)[id] == true end,
        SetPedConfigFlag = function(ped, id, on) Flags(ped)[id] = on end,
        SetPlayerWeaponDefenseModifier = function(p, v) w.defense[p] = v end,
        GetPlayerWeaponDefenseModifier = function(p) return w.defense[p] or 1.0 end,
        SetPedAccuracy = function(ped, v) Ped(ped).accuracy = v end,
        SetPedShootRate = function(ped, v) Ped(ped).shootRate = v end,
        SetPedFiringPattern = function(ped, v) Ped(ped).pattern = type(v) == 'string' and joaat(v) or v end,
        SetPedCombatAbility = function(ped, v) Ped(ped).ability = v end,
        SetPedCombatAttributes = function(ped, attr, on) Ped(ped).attrs[attr] = on end,
        TaskDriveBy = function(ped, target, _, _, _, _, dist, acc, _, pattern)
            w.driveBys[#w.driveBys + 1] = {
                ped = ped,
                target = target,
                accuracy = acc,
                pattern = pattern,
                distance = dist,
            }
        end,
        GiveWeaponToPed = function(ped, hash, ammo)
            local p = Ped(ped)
            p.weapon, p.ammo = type(hash) == 'string' and joaat(hash) or hash, ammo
        end,
    }
    InstallTyped(H.NATIVE_TYPES, effects, w, onCall, before)
    return w
end

-- ============================================================================
--           MOVEMENT NATIVES WITH THEIR REAL ARGUMENT TYPES (opt-in)
-- ============================================================================
-- H.gaitNatives(onCall) installs the natives a runner's game uses to move him and to hold him to a pace
-- (modules/npc/client.lua, Config.Flee), with natives.json's argument types checked as H.combatNatives does (Lua
-- leaves out the Vector3* of GetSafeCoordForPed and answers it after the BOOL). The world it returns keeps what the
-- game would:
--   peds[ped] = { cap, capAt, rate, rateAt, clipset, task = { name = 'nav'|'smartFlee', x, y, z, mbr, flags, from,
--     distance } }
--   capNow(ped), rateNow(ped): the move blend ratio cap and the move rate override in force this frame (one H.step),
--     nil when they were not set during it: SET_PED_MOVE_RATE_OVERRIDE "Needs to be looped!", and the cap is held to
--     the same rule (natives.json has no word on it; a4-combat section 4)
--   clipsets[name]: true once a RequestClipSet has loaded it, loadMs (200) later; a name the game does not have (not
--     in SET_PED_MOVEMENT_CLIPSET's list in natives.json) never loads. SetPedMovementClipset with a clip set that is
--     not loaded counts as w.unloaded (the game would ignore it)
--   safeCoord(x, y, z, onlyOnPavement, flags) -> found, vector3: set by the spec (default: nothing found)
--   calls, typeErrors, restore() as H.combatNatives
H.GAIT_NATIVE_TYPES = {
    TaskFollowNavMeshToCoord = { 'Ped', 'float', 'float', 'float', 'float', 'int', 'float', 'int', 'float' },
    TaskSmartFleePed = { 'Ped', 'Ped', 'float', 'Any', 'BOOL', 'BOOL' },
    SetPedMaxMoveBlendRatio = { 'Ped', 'float' },
    SetPedMoveRateOverride = { 'Ped', 'float' },
    SetPedMovementClipset = { 'Ped', 'char*', 'float' },
    ResetPedMovementClipset = { 'Ped', 'float' },
    RequestClipSet = { 'char*' },
    HasClipSetLoaded = { 'char*' },
    GetSafeCoordForPed = { 'float', 'float', 'float', 'BOOL', 'int' },
}

-- SET_PED_MOVEMENT_CLIPSET 0xAF8A94EDE7712BEF: the movement clip sets natives.json lists (clip set names are not
-- case-sensitive).
local KNOWN_CLIPSETS = {}
for _, name in ipairs({
    'ANIM_GROUP_MOVE_BALLISTIC',
    'ANIM_GROUP_MOVE_LEMAR_ALLEY',
    'clipset@move@trash_fast_turn',
    'FEMALE_FAST_RUNNER',
    'missfbi4prepp1_garbageman',
    'move_characters@franklin@fire',
    'move_characters@Jimmy@slow@',
    'move_characters@michael@fire',
    'move_f@flee@a',
    'move_f@scared',
    'move_f@sexy@a',
    'move_heist_lester',
    'move_injured_generic',
    'move_lester_CaneUp',
    'move_m@bag',
    'MOVE_M@BAIL_BOND_NOT_TAZERED',
    'MOVE_M@BAIL_BOND_TAZERED',
    'move_m@brave',
    'move_m@casual@d',
    'move_m@drunk@moderatedrunk',
    'MOVE_M@DRUNK@MODERATEDRUNK_HEAD_UP',
    'MOVE_M@DRUNK@SLIGHTLYDRUNK',
    'MOVE_M@DRUNK@VERYDRUNK',
    'move_m@fire',
    'move_m@gangster@var_e',
    'move_m@gangster@var_f',
    'move_m@gangster@var_i',
    'move_m@JOG@',
    'MOVE_M@PRISON_GAURD',
    'MOVE_P_M_ONE',
    'MOVE_P_M_ONE_BRIEFCASE',
    'move_p_m_zero_janitor',
    'move_p_m_zero_slow',
    'move_ped_bucket',
    'move_ped_crouched',
    'move_ped_mop',
    'MOVE_M@FEMME@',
    'MOVE_F@FEMME@',
    'MOVE_M@GANGSTER@NG',
    'MOVE_F@GANGSTER@NG',
    'MOVE_M@POSH@',
    'MOVE_F@POSH@',
    'MOVE_M@TOUGH_GUY@',
    'MOVE_F@TOUGH_GUY@',
}) do
    KNOWN_CLIPSETS[name:lower()] = true
end

function H.gaitNatives(onCall)
    local w = { peds = {}, clipsets = {}, requested = {}, calls = {}, typeErrors = 0, unloaded = 0, loadMs = 200 }
    local function Ped(ped)
        w.peds[ped] = w.peds[ped] or {}
        return w.peds[ped]
    end
    function w.capNow(ped)
        local p = w.peds[ped]
        if p and p.capAt == H.clockMs then return p.cap end
        return nil
    end
    function w.rateNow(ped)
        local p = w.peds[ped]
        if p and p.rateAt == H.clockMs then return p.rate end
        return nil
    end
    function w.safeCoord() return false, vector3(0.0, 0.0, 0.0) end
    local function Loaded(name)
        local key = name:lower()
        if w.clipsets[key] then return true end
        local at = w.requested[key]
        if at and KNOWN_CLIPSETS[key] and H.clockMs >= at + w.loadMs then w.clipsets[key] = true end
        return w.clipsets[key] == true
    end
    local before = {}
    function w.restore()
        for name in pairs(H.GAIT_NATIVE_TYPES) do rawset(_G, name, before[name]) end
    end
    local effects = {
        TaskFollowNavMeshToCoord = function(ped, x, y, z, mbr, _, _, flags)
            Ped(ped).task = { name = 'nav', x = x, y = y, z = z, mbr = mbr, flags = flags }
        end,
        TaskSmartFleePed = function(ped, from, distance)
            Ped(ped).task = { name = 'smartFlee', from = from, distance = distance }
        end,
        SetPedMaxMoveBlendRatio = function(ped, v)
            local p = Ped(ped)
            p.cap, p.capAt = v, H.clockMs
        end,
        SetPedMoveRateOverride = function(ped, v)
            local p = Ped(ped)
            p.rate, p.rateAt = v, H.clockMs
        end,
        SetPedMovementClipset = function(ped, name)
            if not Loaded(name) then
                w.unloaded = w.unloaded + 1
                return
            end
            Ped(ped).clipset = name:lower()
        end,
        ResetPedMovementClipset = function(ped) Ped(ped).clipset = nil end,
        RequestClipSet = function(name)
            local key = name:lower()
            if not w.requested[key] then w.requested[key] = H.clockMs end
        end,
        HasClipSetLoaded = function(name) return Loaded(name) end,
        GetSafeCoordForPed = function(...) return w.safeCoord(...) end,
    }
    InstallTyped(H.GAIT_NATIVE_TYPES, effects, w, onCall, before)
    return w
end

-- ============================================================================
--             GROUND PROBE NATIVES WITH THEIR REAL ARGUMENT TYPES
-- ============================================================================
-- H.groundNatives(onCall) (opt-in) installs the client natives a ground probe uses (CP.Spawn.probe,
-- modules/spawn/client.lua), each checking its arguments as H.combatNatives does (a float where the game reads a
-- float: an integer coordinate from a mission file must be passed as x + 0.0). The world it returns is a small game
-- map the spec sets up:
--   ped, car: this player's ped and the car he sits in (0 = on foot)
--   surfaces = { { z, at = fn(x, y) (default everywhere), nz (normal z, 1.0), interior = id } }: the ground. The
--     highest one at or under the probe's height is found, and only once the collision is loaded (as the game:
--     GET_GROUND_Z_* answers within the loaded area only); a surface of an interior only while it is ready
--   collisionMs: the collision loads this long after the first RequestCollisionAtCoord (nil = never)
--   interiors[id] = { at = fn(x, y, z), ready = bool, readyMs = ms after the pin (nil = never) }; pins[id], unpins[id]
--   water = fn(x, y) -> the water's height there or nil
--   wall = fn(capsule) -> bool (capsule = { x1, y1, z1, x2, y2, z2, r, flags, ignore, options }), capsules = { ... },
--     capsuleFrames (polls until done, 1), capsuleStuck (never done), capsuleFail (handle 0), hitAs (1 or true)
--   models[hash] = { mn, mx, loadMs, preloaded }: dimensions answered once the model is loaded (after RequestModel
--     and loadMs, or preloaded); released[hash] = true after SetModelAsNoLongerNeeded
--   calls = { { name, args } }, typeErrors; reset(): a new game (no collision, pins, probes, loads or calls yet);
--   restore(): the globals as they were before H.groundNatives
H.GROUND_NATIVE_TYPES = {
    PlayerPedId = {},
    GetVehiclePedIsIn = { 'Ped', 'BOOL' },
    RequestCollisionAtCoord = { 'float', 'float', 'float' },
    HasCollisionLoadedAroundEntity = { 'Entity' },
    GetInteriorAtCoords = { 'float', 'float', 'float' },
    IsInteriorReady = { 'int' },
    PinInteriorInMemory = { 'int' },
    UnpinInterior = { 'int' },
    GetGroundZAndNormalFor_3dCoord = { 'float', 'float', 'float' },
    TestProbeAgainstWater = { 'float', 'float', 'float', 'float', 'float', 'float' },
    GetWaterHeight = { 'float', 'float', 'float' },
    StartShapeTestCapsule = { 'float', 'float', 'float', 'float', 'float', 'float', 'float', 'int', 'Entity', 'int' },
    GetShapeTestResult = { 'int' },
    IsModelInCdimage = { 'Hash' },
    HasModelLoaded = { 'Hash' },
    RequestModel = { 'Hash' },
    GetModelDimensions = { 'Hash' },
    SetModelAsNoLongerNeeded = { 'Hash' },
}

function H.groundNatives(onCall)
    local w = {
        ped = 4242,
        car = 0,
        surfaces = {},
        collisionMs = 0,
        interiors = {},
        pins = {},
        unpins = {},
        wall = function() return false end,
        capsules = {},
        capsuleFrames = 1,
        hitAs = 1,
        models = {},
        released = {},
        requested = {},
        calls = {},
        typeErrors = 0,
    }
    local collisionAt, nextHandle, tests = nil, 300, {}
    local function Hash(m) return type(m) == 'string' and joaat(m) or m end
    local function Loaded()
        return collisionAt ~= nil and w.collisionMs ~= nil and H.clockMs >= collisionAt + w.collisionMs
    end
    local function Ready(id)
        local int = w.interiors[id]
        if not int then return false end
        if int.ready then return true end
        if (w.pins[id] or 0) > 0 and int.pinnedAt and int.readyMs and H.clockMs >= int.pinnedAt + int.readyMs then
            int.ready = true
        end
        return int.ready == true
    end
    local function ModelLoaded(hash)
        local m = w.models[hash]
        if not m then return false end
        if m.loaded or m.preloaded then return true end
        if w.requested[hash] and H.clockMs >= w.requested[hash] + (m.loadMs or 0) then m.loaded = true end
        return m.loaded == true
    end
    function w.reset()
        collisionAt = nil
        w.pins, w.unpins, w.capsules, w.released, w.requested, w.calls = {}, {}, {}, {}, {}, {}
        for _, int in pairs(w.interiors) do int.pinnedAt = nil end
        for _, m in pairs(w.models) do m.loaded = nil end
    end
    local before = {}
    function w.restore()
        for name in pairs(H.GROUND_NATIVE_TYPES) do rawset(_G, name, before[name]) end
    end
    local effects = {
        PlayerPedId = function() return w.ped end,
        GetVehiclePedIsIn = function() return w.car end,
        RequestCollisionAtCoord = function() if not collisionAt then collisionAt = H.clockMs end end,
        HasCollisionLoadedAroundEntity = function() return Loaded() end,
        GetInteriorAtCoords = function(x, y, z)
            for id, int in pairs(w.interiors) do
                if int.at(x, y, z) then return id end
            end
            return 0
        end,
        IsInteriorReady = function(id) return Ready(id) end,
        PinInteriorInMemory = function(id)
            w.pins[id] = (w.pins[id] or 0) + 1
            local int = w.interiors[id]
            if int and not int.pinnedAt then int.pinnedAt = H.clockMs end
        end,
        UnpinInterior = function(id)
            w.unpins[id] = (w.unpins[id] or 0) + 1
            w.pins[id] = math.max(0, (w.pins[id] or 0) - 1)
        end,
        GetGroundZAndNormalFor_3dCoord = function(x, y, z)
            if not Loaded() then return false, 0.0, Vec(0.0, 0.0, 0.0) end
            local best = nil
            for _, s in ipairs(w.surfaces) do
                if s.z <= z and (not s.at or s.at(x, y)) and (not s.interior or Ready(s.interior))
                    and (not best or s.z > best.z) then
                    best = s
                end
            end
            if not best then return false, 0.0, Vec(0.0, 0.0, 0.0) end
            return true, best.z + 0.0, Vec(0.0, 0.0, (best.nz or 1.0) + 0.0)
        end,
        TestProbeAgainstWater = function(x1, y1, z1, _, _, z2)
            local hz = w.water and w.water(x1, y1)
            if hz and hz <= math.max(z1, z2) and hz >= math.min(z1, z2) then return true, Vec(x1, y1, hz) end
            return false, Vec(0.0, 0.0, 0.0)
        end,
        GetWaterHeight = function(x, y)
            local hz = w.water and w.water(x, y)
            if hz then return true, hz + 0.0 end
            return false, 0.0
        end,
        StartShapeTestCapsule = function(x1, y1, z1, x2, y2, z2, r, flags, ignore, options)
            local c = {
                x1 = x1,
                y1 = y1,
                z1 = z1,
                x2 = x2,
                y2 = y2,
                z2 = z2,
                r = r,
                flags = flags,
                ignore = ignore,
                options = options,
            }
            w.capsules[#w.capsules + 1] = c
            if w.capsuleFail then return 0 end
            nextHandle = nextHandle + 1
            tests[nextHandle] = { c = c, polls = 0 }
            c.handle = nextHandle
            return nextHandle
        end,
        GetShapeTestResult = function(handle)
            local t = tests[handle]
            if not t or t.done then return 0, false, Vec(0.0, 0.0, 0.0), Vec(0.0, 0.0, 0.0), 0 end
            t.polls = t.polls + 1
            t.c.polls = t.polls
            if w.capsuleStuck or t.polls < w.capsuleFrames then
                return 1, false, Vec(0.0, 0.0, 0.0), Vec(0.0, 0.0, 0.0), 0
            end
            t.done = true
            local hit = w.wall(t.c)
            return 2, hit and w.hitAs or (w.hitAs == 1 and 0 or false), Vec(0.0, 0.0, 0.0), Vec(0.0, 0.0, 1.0), 0
        end,
        IsModelInCdimage = function(m) return w.models[Hash(m)] ~= nil end,
        HasModelLoaded = function(m) return ModelLoaded(Hash(m)) end,
        RequestModel = function(m)
            local hash = Hash(m)
            if not w.requested[hash] then w.requested[hash] = H.clockMs end
        end,
        GetModelDimensions = function(m)
            local hash = Hash(m)
            local d = w.models[hash]
            if not d or not ModelLoaded(hash) then return Vec(0.0, 0.0, 0.0), Vec(0.0, 0.0, 0.0) end
            return d.mn, d.mx
        end,
        SetModelAsNoLongerNeeded = function(m) w.released[Hash(m)] = true end,
    }
    InstallTyped(H.GROUND_NATIVE_TYPES, effects, w, onCall, before)
    return w
end

-- ============================================================================
--            PLACER NATIVES WITH THEIR REAL ARGUMENT TYPES (opt-in)
-- ============================================================================
-- H.placerNatives(onCall) installs the client natives the placer uses (modules/spawn/client.lua, PLAN S9: players,
-- network ids, control, freeze, coordinates, the ground natives of vehicles and objects) with natives.json's argument
-- types, as H.groundNatives does (a spec of the placer installs both). The world it returns is a small game:
--   me: this game's player index (PlayerId)
--   players[idx] = { src, ped, coords, active (default true) }: the players this game knows (GetEntityCoords of a
--     player's ped answers his coords; GetPlayerFromServerId answers -1 for a src not listed)
--   entities[handle] = { netId, type (1 ped, 2 vehicle, 3 object), coords, heading, model, frozen, owner (a player
--     index, -1 = nobody), grantMs (control comes this long after this game first asks; nil = never), loseAt (at this
--     clock time the game of player loseTo, default -1, takes it over), seated, attached, exists (default true) }.
--     As in the game, what this game sets on a networked entity it does not control is not kept: the call is
--     counted in ignored[name] and changes nothing. What it does set is kept: frozen, coords, keepTasks,
--     loadCollision, onGround (SetVehicleOnGroundProperly on a vehicle, PlaceObjectOnGroundProperly on an object)
--   entity(handle, fields): adds one; calls = { { name, args } }, typeErrors; restore()
H.PLACER_NATIVE_TYPES = {
    PlayerId = {},
    GetPlayerServerId = { 'Player' },
    GetPlayerFromServerId = { 'int' },
    NetworkIsPlayerActive = { 'Player' },
    GetPlayerPed = { 'Player' },
    NetworkDoesNetworkIdExist = { 'int' },
    NetworkGetEntityFromNetworkId = { 'int' },
    DoesEntityExist = { 'Entity' },
    GetEntityType = { 'Entity' },
    GetEntityModel = { 'Entity' },
    GetEntityHeading = { 'Entity' },
    NetworkHasControlOfEntity = { 'Entity' },
    NetworkRequestControlOfEntity = { 'Entity' },
    NetworkGetEntityOwner = { 'Entity' },
    IsPedInAnyVehicle = { 'Ped', 'BOOL' },
    IsEntityAttached = { 'Entity' },
    FreezeEntityPosition = { 'Entity', 'BOOL' },
    SetEntityLoadCollisionFlag = { 'Entity', 'BOOL' },
    SetEntityCoordsNoOffset = { 'Entity', 'float', 'float', 'float', 'BOOL', 'BOOL', 'BOOL' },
    SetVehicleOnGroundProperly = { 'Vehicle' },
    PlaceObjectOnGroundProperly = { 'Object' },
}

function H.placerNatives(onCall)
    local w = { me = 0, players = {}, entities = {}, ignored = {}, calls = {}, typeErrors = 0 }
    function w.entity(handle, fields)
        local e = { type = 1, coords = Vec(0.0, 0.0, 0.0), heading = 0.0, model = 0, frozen = false, owner = -1 }
        for k, v in pairs(fields or {}) do e[k] = v end
        w.entities[handle] = e
        return e
    end
    -- who controls it now (a request granted, a takeover due)
    local function Live(handle)
        local e = w.entities[handle]
        if not e or e.exists == false then return nil end
        if e.loseAt and H.clockMs >= e.loseAt then
            e.owner, e.loseAt, e.requestedAt = e.loseTo or -1, nil, nil
        end
        if e.requestedAt and e.grantMs and H.clockMs >= e.requestedAt + e.grantMs and e.owner ~= w.me then
            e.owner = w.me
        end
        return e
    end
    local function Mine(name, handle)
        local e = Live(handle)
        if e and e.owner == w.me then return e end
        w.ignored[name] = (w.ignored[name] or 0) + 1
        return nil
    end
    local function PlayerOfPed(ped)
        for idx, p in pairs(w.players) do if p.ped == ped then return idx, p end end
        return nil
    end
    local before = {}
    function w.restore()
        for name in pairs(H.PLACER_NATIVE_TYPES) do rawset(_G, name, before[name]) end
        rawset(_G, 'GetEntityCoords', before.GetEntityCoords)
    end
    local effects = {
        PlayerId = function() return w.me end,
        GetPlayerServerId = function(idx) return w.players[idx] and w.players[idx].src or 0 end,
        GetPlayerFromServerId = function(src)
            for idx, p in pairs(w.players) do if p.src == src then return idx end end
            return -1
        end,
        NetworkIsPlayerActive = function(idx) return w.players[idx] ~= nil and w.players[idx].active ~= false end,
        GetPlayerPed = function(idx) return w.players[idx] and w.players[idx].ped or 0 end,
        NetworkDoesNetworkIdExist = function(netId)
            for h in pairs(w.entities) do
                local e = Live(h)
                if e and e.netId == netId then return true end
            end
            return false
        end,
        NetworkGetEntityFromNetworkId = function(netId)
            for h in pairs(w.entities) do
                local e = Live(h)
                if e and e.netId == netId then return h end
            end
            return 0
        end,
        DoesEntityExist = function(h) return Live(h) ~= nil or PlayerOfPed(h) ~= nil end,
        GetEntityType = function(h)
            local e = Live(h)
            if e then return e.type end
            return PlayerOfPed(h) and 1 or 0
        end,
        GetEntityModel = function(h)
            local e = Live(h)
            return e and e.model or 0
        end,
        GetEntityHeading = function(h)
            local e = Live(h)
            return e and e.heading + 0.0 or 0.0
        end,
        NetworkHasControlOfEntity = function(h)
            local e = Live(h)
            return e ~= nil and e.owner == w.me
        end,
        NetworkRequestControlOfEntity = function(h)
            local e = Live(h)
            if not e then return false end
            if not e.requestedAt then e.requestedAt = H.clockMs end
            e.requests = (e.requests or 0) + 1
            return true
        end,
        NetworkGetEntityOwner = function(h)
            local e = Live(h)
            return e and e.owner or -1
        end,
        IsPedInAnyVehicle = function(h)
            local e = Live(h)
            return e ~= nil and e.seated == true
        end,
        IsEntityAttached = function(h)
            local e = Live(h)
            return e ~= nil and e.attached == true
        end,
        FreezeEntityPosition = function(h, on)
            local e = Mine('FreezeEntityPosition', h)
            if e then e.frozen = on end
        end,
        SetEntityLoadCollisionFlag = function(h, on)
            local e = Mine('SetEntityLoadCollisionFlag', h)
            if e then e.loadCollision = on end
        end,
        SetEntityCoordsNoOffset = function(h, x, y, z, keepTasks)
            local e = Mine('SetEntityCoordsNoOffset', h)
            if e then e.coords, e.keepTasks = Vec(x, y, z), keepTasks end
        end,
        SetVehicleOnGroundProperly = function(h)
            local e = Mine('SetVehicleOnGroundProperly', h)
            if not e or e.type ~= 2 then return false end
            e.onGround = true
            return true
        end,
        PlaceObjectOnGroundProperly = function(h)
            local e = Mine('PlaceObjectOnGroundProperly', h)
            if not e or e.type ~= 3 then return false end
            e.onGround = true
            return true
        end,
    }
    InstallTyped(H.PLACER_NATIVE_TYPES, effects, w, onCall, before)
    -- GetEntityCoords takes an optional second argument the code leaves out: answered, not type-checked
    before.GetEntityCoords = rawget(_G, 'GetEntityCoords')
    _G.GetEntityCoords = function(h)
        local _, p = PlayerOfPed(h)
        if p then return p.coords end
        local e = Live(h)
        return e and e.coords or Vec(0.0, 0.0, 0.0)
    end
    return w
end

-- ============================================================================
--           SERVER NATIVES THAT ANSWER YES OR NO (FXServer's shape)
-- ============================================================================
-- On FXServer a native that answers yes or no (a BOOL native) goes through `_r` in natives_server.lua
-- (Citizen.ReturnResultAnyway). ScriptInvoker.h hands Lua false for 0 and the integer otherwise, so "yes" is the
-- integer 1, never true: `DoesEntityExist(e) == true` is false for every entity on a real server. Read such an
-- answer as `if DoesEntityExist(e) then` or accept both (`v == true or v == 1`). The client natives answer true or
-- false (fxmanifest: use_experimental_fxv2_oal), so code shared by both sides must accept both too.
--
-- Every spec runs against that shape, whatever its own mocks return. While the spec is booted as the server
-- (H.boot, or H.boot({ side = 'server' })), each of the globals below that a spec or the harness sets to a function
-- answers 1 for true and false for false, nil or 0; other answers and further return values are kept. The function
-- the spec wrote is kept as it is and wrapped when it is read. Booted as the client, the same global answers what
-- the spec's function returns. The list is every `_r` native of natives_server.lua (FXServer build 35245).
--
-- The harness owns the metatable of _G for this, so a spec never calls setmetatable(_G, ...) (it raises an error):
-- H.strictGlobals(true) makes reading an undefined global an error, H.onUndefinedGlobal(fn) answers one.
local SERVER_BOOL = {}
for _, name in ipairs({
    'CanPlayerStartCommerceSession',
    'DoesBoatSinkWhenWrecked',
    'DoesEntityExist',
    'DoesPlayerExist',
    'DoesPlayerOwnSku',
    'DoesPlayerOwnSkuExt',
    'DoesTrainStopAtStations',
    'GetConvarBool',
    'GetEntityCollisionDisabled',
    'GetEntityRemoteSyncedScenesAllowed',
    'GetHeliDisableExplodeFromBodyDamage',
    'GetIsHeliEngineRunning',
    'GetIsVehicleEngineRunning',
    'GetIsVehiclePrimaryColourCustom',
    'GetIsVehicleSecondaryColourCustom',
    'GetPedStealthMovement',
    'GetPlayerInvincible',
    'GetTrainDirection',
    'GetVehicleHandbrake',
    'GetVehicleLightsState',
    'GetVehicleNeonEnabled',
    'HasEntityBeenMarkedAsNoLongerNeeded',
    'HasVehicleBeenDamagedByBullets',
    'HasVehicleBeenOwnedByPlayer',
    'IsAceAllowed',
    'IsBoatAnchoredAndFrozen',
    'IsBoatWrecked',
    'IsDuplicityVersion',
    'IsEntityPositionFrozen',
    'IsEntityVisible',
    'IsFlashLightOn',
    'IsHeliTailBoomBreakable',
    'IsHeliTailBoomBroken',
    'IsPedAPlayer',
    'IsPedHandcuffed',
    'IsPedInAnyVehicle',
    'IsPedInVehicle',
    'IsPedOnMount',
    'IsPedRagdoll',
    'IsPedStrafing',
    'IsPedUsingActionMode',
    'IsPlayerAceAllowed',
    'IsPlayerCommerceInfoLoaded',
    'IsPlayerCommerceInfoLoadedExt',
    'IsPlayerEvadingWantedLevel',
    'IsPlayerInFreeCamMode',
    'IsPlayerUsingSuperJump',
    'IsPrincipalAceAllowed',
    'IsTrainCaboose',
    'IsVehicleEngineStarting',
    'IsVehicleExtraTurnedOn',
    'IsVehicleSirenOn',
    'IsVehicleTyreBurst',
    'IsVehicleWindowIntact',
    'MumbleIsPlayerMuted',
    'ProfilerIsRecording',
    'SaveResourceFile',
    'StartResource',
    'StateBagHasKey',
    'StopResource',
    'VerifyPasswordHash',
    'WasEventCanceled',
}) do
    SERVER_BOOL[name] = true
end
H.SERVER_BOOL_NATIVES = SERVER_BOOL
H.side = 'server'   -- H.boot sets it

-- One BOOL answer the way FXServer hands it to Lua: 1 for yes, false for no (a nil or a 0 from a mock is a no).
function H.serverBool(v)
    if v == true then return 1 end
    if v == nil or v == false or v == 0 then return false end
    return v
end

local boolNatives = {}                                   -- [name] = the value a spec or the harness set
local wrapperOf = setmetatable({}, { __mode = 'k' })     -- [function] = its server-shaped wrapper
local wrapped = setmetatable({}, { __mode = 'k' })       -- [wrapper] = the function it wraps
local strictGlobals, undefinedGlobal = false, nil

local function ServerShaped(fn)
    local w = wrapperOf[fn]
    if w then return w end
    w = function(...)
        local r = table.pack(fn(...))
        r[1] = H.serverBool(r[1])
        return table.unpack(r, 1, math.max(r.n, 1))
    end
    wrapperOf[fn], wrapped[w] = w, fn
    return w
end

-- On: reading a global that is not defined raises 'undefined global <name>' (a misspelt native fails the spec).
function H.strictGlobals(on) strictGlobals = on == true end

-- fn(name) answers each read of an undefined global (nil: such a read gives nil again).
function H.onUndefinedGlobal(fn) undefinedGlobal = fn end

setmetatable(_G, {
    __metatable = 'tests/harness.lua owns the metatable of _G: use H.strictGlobals or H.onUndefinedGlobal',
    __index = function(_, k)
        local v = boolNatives[k]
        if v ~= nil then
            if H.side == 'server' and type(v) == 'function' then return ServerShaped(v) end
            return v
        end
        if undefinedGlobal then return undefinedGlobal(k) end
        if strictGlobals then error('undefined global ' .. tostring(k), 2) end
        return nil
    end,
    __newindex = function(t, k, v)
        if SERVER_BOOL[k] then
            -- a wrapper read earlier and set back is the spec's own function again
            boolNatives[k] = wrapped[v] or v
            return
        end
        rawset(t, k, v)
    end,
})
for name in pairs(SERVER_BOOL) do
    local v = rawget(_G, name)
    if v ~= nil then
        rawset(_G, name, nil)
        boolNatives[name] = v
    end
end

-- ============================================================================
--                                     BOOT
-- ============================================================================

function H.load(rel)
    local path = ROOT .. rel
    local chunk, err = loadfile(path)
    if not chunk then error(err, 2) end
    local r = chunk()
    -- the specs call the engine synchronously: a long SELECT does not give the (fake) server its turn here
    -- (tests/memsql_spec.lua 9.14 checks the slicing itself)
    if rel == 'modules/storage/server.lua' and CP and CP.Storage and CP.Storage.db then CP.Storage.db.slice = nil end
    return r
end

-- The real CP.AntiCheat (modules/anticheat/server.lua) as a table of its own, without its 1 s loop, for a spec that
-- stubs CP.AntiCheat: it takes the stun rule (stunMode, stunReport) and the staff notes from it. CP.AntiCheat stays
-- what it was. The real functions call each other through the returned table (wrap its note or flag to watch them).
function H.realAntiCheat()
    local saved, thread = CP.AntiCheat, _G.CreateThread
    CP.AntiCheat = nil
    _G.CreateThread = function() end
    local ok, err = pcall(H.load, 'modules/anticheat/server.lua')
    _G.CreateThread = thread
    local real = CP.AntiCheat
    CP.AntiCheat = saved
    if not ok then error(err, 2) end
    return real
end

-- The files FXServer runs for one script list of fxmanifest.lua ('server_scripts', 'client_scripts',
-- 'shared_scripts'), in its order: the entries as listed with no de-duplication across entries (a file named by
-- itself and matched again by a glob runs twice), each glob's matches byte-sorted and unique within the entry, '**/'
-- also matching no folder (ResourceMetaDataComponent.cpp GlobEntries / GlobValue, ResourceScriptingComponent.cpp
-- LoadFile per listed file). '@resource/...' entries are left out.
function H.manifestScripts(key)
    local fh = assert(io.open(ROOT .. 'fxmanifest.lua', 'r'))
    local manifest = fh:read('a'):gsub('%-%-[^\n]*', '')
    fh:close()
    local body = manifest:match(key .. '%s*(%b{})') or ''
    local files = nil
    local function All()
        if files then return files end
        files = {}
        local p = io.popen('cd ' .. ROOT .. ' && find . -path ./web/node_modules -prune -o -type f -print')
        for line in p:lines() do files[#files + 1] = line:gsub('^%./', '') end
        p:close()
        return files
    end
    local function Pattern(text) return (text:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '[^/]*')) end
    local out = {}
    for entry in body:gmatch('[\'"]([^\'"]+)[\'"]') do
        if entry:sub(1, 1) ~= '@' then
            if entry:find('*', 1, true) then
                local pre, post = entry:match('^(.-)%*%*/(.*)$')
                local matches, seen = {}, {}
                for _, f in ipairs(All()) do
                    local hit
                    if pre then
                        local rest = f:sub(1, #pre) == pre and f:sub(#pre + 1) or nil
                        hit = rest
                            and (rest:match('^' .. Pattern(post) .. '$') or rest:match('/' .. Pattern(post) .. '$'))
                    else
                        hit = f:match('^' .. Pattern(entry) .. '$')
                    end
                    if hit and not seen[f] then
                        seen[f] = true
                        matches[#matches + 1] = f
                    end
                end
                table.sort(matches)
                for _, f in ipairs(matches) do out[#out + 1] = f end
            else
                out[#out + 1] = entry
            end
        end
    end
    return out
end

function H.reset()
    H.events = {}
end

function H.findEvents(name)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.name == name then out[#out + 1] = e end
    end
    return out
end

-- Simulate an incoming net event from `src` (handlers see `source`). Like FXServer's TriggerEvent2, one dispatch has
-- one "cancelled" flag: CancelEvent() in a handler sets it, WasEventCanceled() in the handlers after it reads it, and
-- H.fire returns it (true: the game would not route the event, e.g. a weaponDamageEvent never reaches its victim).
H.eventCanceled = false
function H.fire(name, src, ...)
    local list = H.handlers[name] or {}
    local outer = H.eventCanceled
    H.eventCanceled = false
    for _, fn in ipairs(list) do
        local co = coroutine.create(function(...)
            _ENV.source = src
            source = src
            fn(...)
        end)
        Resume(co, ...)
    end
    local canceled = H.eventCanceled
    H.eventCanceled = outer
    return canceled
end

-- Call an ox_lib callback as `src`.
function H.callback(name, src, ...)
    local fn = H.callbacks[name]
    if not fn then error('no callback ' .. name, 2) end
    local result
    local co = coroutine.create(function(...) result = fn(src, ...) end)
    Resume(co, ...)
    return result
end

-- H.players[src] = { ped coords = vec(...), state = {}, ace = { ['crimsonpolice.admin'] = true },
--   identifiers = { 'license:...', 'license2:...', 'fivem:...' } (GetPlayerIdentifierByType) }
H.players = {}

-- ============================================================================
--               FXSERVER'S LIMITS ON ONE PLAYER'S SERVER EVENTS
-- ============================================================================
-- citizen-server-impl ServerEventPacketHandler.cpp (build 35245: the same constants in libcitizen-server-impl.so):
-- per player, token buckets 'netEvent' 50/s burst 200 (an event over it is dropped; over 'netEventFlood' 75/s burst 300
-- too, the player is dropped: "Reliable network event overflow.") and 'netEventSize' 128 KB/s burst 384 KB of event
-- name + msgpack'ed arguments (over it the player is dropped: "Reliable network event size overflow: <name>").
-- On the client side TriggerServerEvent goes through them: H.netDrop is the drop reason, and a dropped player's events
-- (that one and every later one) never reach the server.

-- The bytes msgpack gives a Lua value (FXServer packs an event's arguments as one msgpack array).
local function PackSize(v)
    local t = type(v)
    if v == nil or t == 'boolean' then return 1 end
    if t == 'number' then
        if math.type(v) == 'float' then return 9 end
        if v >= 0 then
            if v < 128 then return 1 elseif v < 256 then return 2 elseif v < 65536 then return 3 end
            return v < 4294967296 and 5 or 9
        end
        if v >= -32 then return 1 elseif v >= -128 then return 2 elseif v >= -32768 then return 3 end
        return v >= -2147483648 and 5 or 9
    end
    if t == 'string' then
        local n = #v
        if n < 32 then return 1 + n elseif n < 256 then return 2 + n elseif n < 65536 then return 3 + n end
        return 5 + n
    end
    if t == 'table' then
        local count = 0
        for _ in pairs(v) do count = count + 1 end
        local size = count < 16 and 1 or (count < 65536 and 3 or 5)
        if count == #v then
            for i = 1, count do size = size + PackSize(v[i]) end
        else
            for k, x in pairs(v) do size = size + PackSize(k) + PackSize(x) end
        end
        return size
    end
    return 18   -- a vector (msgpack ext) or anything else
end
H._packSize = PackSize

local function Bucket(rate, burst) return { rate = rate, burst = burst, tokens = burst, at = H.clockMs } end
local function Consume(b, n)
    b.tokens = math.min(b.burst, b.tokens + (H.clockMs - b.at) * b.rate / 1000)
    b.at = H.clockMs
    if b.tokens < n then return false end
    b.tokens = b.tokens - n
    return true
end

-- true when FXServer lets this client event through (and records why it dropped the player when it does not)
local function NetEventPasses(name, ...)
    if H.netDrop then return false end
    local net = H.netBuckets
    if not Consume(net.count, 1) then
        if not Consume(net.flood, 1) then H.netDrop = 'Reliable network event overflow.' end
        return false
    end
    local size = #name + (select('#', ...) < 16 and 1 or 3)
    for i = 1, select('#', ...) do size = size + PackSize((select(i, ...))) end
    if not Consume(net.size, size) then
        H.netDrop = ('Reliable network event size overflow: %s'):format(name)
        return false
    end
    return true
end

function H.resetNetLimits()
    H.netDrop = nil
    H.netBuckets = {
        count = Bucket(50, 200),
        flood = Bucket(75, 300),
        size = Bucket(128 * 1024, 384 * 1024),
    }
end
H.resetNetLimits()

function H.boot(opts)
    opts = opts or {}
    local server = (opts.side or 'server') == 'server'
    H.side = server and 'server' or 'client'   -- the BOOL natives answer 1 or false while it is 'server'
    _G.vec3, _G.vector3 = Vec, Vec
    _G.vec4, _G.vector4 = Vec, Vec
    _G.vec2, _G.vector2 =
        function(x, y) return Vec(x, y) end, function(x, y)
            return Vec(x, y)
        end
    _G.json = {
        encode = function(v) return cjson.encode(v) end,
        decode = function(s) return cjson.decode(s) end,
    }
    _G.IsDuplicityVersion = function() return server end
    _G.GetCurrentResourceName = function() return 'Crimson-Police' end
    _G.GetGameTimer = function() return H.clockMs end
    local realTime = os.time
    os.time = function(t) if t then return realTime(t) end return H.time end
    _G.LoadResourceFile = function(_, path)
        -- Specs see CP.L keys unless they load a locale themselves (they wrap LoadResourceFile for
        -- 'locales/en.json', as tests/e2e_spec.lua does with the merged parts) or boot with realLocale = true.
        -- The shipped locales/en.json is checked by tests/int_web_spec.lua and tools/check_contracts.py.
        if path == 'locales/en.json' and not opts.realLocale then return nil end
        local f = io.open(ROOT .. path, 'r')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end
    _G.SaveResourceFile = function(_, path, data)
        -- as FXServer: false when the folder is missing (it makes no folder)
        local f = io.open(ROOT .. path, 'w')
        if not f then return false end
        f:write(data)
        f:close()
        return true
    end
    _G.GetResourceState = function(name) return (opts.stopped and opts.stopped[name]) and 'stopped' or 'started' end
    -- FXServer refuses StopResource on the calling resource (citizen-server-impl ServerResources.cpp STOP_RESOURCE:
    -- name == the current resource -> false, Resource::Stop() never called; the same in build 35245's binary): the
    -- resource keeps running. H.stopRequests lists every call.
    H.stopRequests = {}
    _G.StopResource = function(name)
        H.stopRequests[#H.stopRequests + 1] = tostring(name)
        return name ~= GetCurrentResourceName()
    end
    _G.CreateThread = function(fn)
        local co = coroutine.create(fn)
        Resume(co)
    end
    _G.Citizen = { CreateThread = _G.CreateThread, Wait = nil, Await = nil }
    _G.Wait = function(ms)
        local co = coroutine.running()
        if not co or coroutine.isyieldable() == false then H.clockMs = H.clockMs + (ms or 0); return end
        sleeping[#sleeping + 1] = { co = co, wake = H.clockMs + (ms or 0) }
        coroutine.yield()
    end
    _G.Citizen.Wait = _G.Wait
    _G.SetTimeout = function(ms, fn)
        _G.CreateThread(function() Wait(ms); fn() end)
    end
    _G.promise = {
        new = function()
            local p = { resolved = false }
            function p:resolve(v) self.resolved = true; self.value = v end
            function p:reject(e) self.resolved = true; self.err = e end
            return p
        end,
    }
    _G.Citizen.Await = function(p)
        while not p.resolved do Wait(10) end
        if p.err then error(p.err, 2) end
        return p.value
    end
    _G.RegisterNetEvent = function(name, fn)
        if fn then H.handlers[name] = H.handlers[name] or {}; H.handlers[name][#H.handlers[name] + 1] = fn end
    end
    _G.AddEventHandler = function(name, fn)
        H.handlers[name] = H.handlers[name] or {}
        H.handlers[name][#H.handlers[name] + 1] = fn
    end
    _G.TriggerEvent = function(name, ...)
        H.events[#H.events + 1] = { kind = 'local', name = name, args = { ... } }
        for _, fn in ipairs(H.handlers[name] or {}) do fn(...) end
    end
    _G.TriggerClientEvent = function(name, target, ...)
        H.events[#H.events + 1] = { kind = 'client', name = name, target = target, args = { ... } }
    end
    H.resetNetLimits()
    _G.TriggerServerEvent = function(name, ...)
        if not server and not NetEventPasses(name, ...) then return end
        H.events[#H.events + 1] = { kind = 'server', name = name, args = { ... } }
    end
    -- the cancelled flag of the event H.fire is dispatching (FXServer: one per TriggerEvent2 dispatch)
    _G.CancelEvent = function() H.eventCanceled = true end
    _G.WasEventCanceled = function() return H.eventCanceled end
    _G.RegisterCommand = function(name, fn, restricted) H.commands[name] = { fn = fn, restricted = restricted } end
    _G.IsPlayerAceAllowed = function(src, ace)
        local p = H.players[tonumber(src)]
        return p and p.ace and p.ace[ace] == true or false
    end
    _G.GetPlayers = function()
        local out = {}
        for src in pairs(H.players) do out[#out + 1] = tostring(src) end
        return out
    end
    _G.GetPlayerPed = function(src) return H.players[tonumber(src)] and tonumber(src) * 100 or 0 end
    _G.GetEntityCoords = function(ent)
        local p = H.players[math.floor((ent or 0) / 100)]
        return p and p.coords or Vec(0.0, 0.0, 0.0)
    end
    _G.DoesEntityExist = function() return true end
    InstallEntityNatives()
    _G.GetPlayerName = function(src) return 'Player' .. tostring(src) end
    -- DROP_PLAYER (server only): H.dropped lists { src, reason } in call order. FXServer fires playerDropped later,
    -- once the client is gone, so this stand-in does not fire it.
    H.dropped = {}
    _G.DropPlayer = nil
    if server then
        _G.DropPlayer = function(src, reason) H.dropped[#H.dropped + 1] = { src = src, reason = reason } end
    end
    -- FXServer's GET_PLAYER_IDENTIFIER_BY_TYPE (citizen-server-impl PlayerScriptFunctions.cpp): the FIRST identifier
    -- of the player that starts with the given text (identifiers[i].rfind(type, 0)), nil when none, so 'license' also
    -- finds 'license2:...' when that one comes first. H.players[src].identifiers lists them in FXServer's order.
    _G.GetPlayerIdentifierByType = server
            and function(src, kind)
                local p = H.players[tonumber(src)]
                if not p then return nil end
                kind = tostring(kind)
                for _, id in ipairs(p.identifiers or {}) do
                    if id:sub(1, #kind) == kind then return id end
                end
                return nil
            end
        or nil
    -- GET_NUM_PLAYER_IDENTIFIERS / GET_PLAYER_IDENTIFIER(src, index 0..n-1) and GET_NUM_PLAYER_TOKENS /
    -- GET_PLAYER_TOKEN (server natives, PlayerScriptFunctions.cpp): H.players[src].identifiers and .tokens in order;
    -- an index out of range answers nil, an unknown player 0 and nil.
    _G.GetNumPlayerIdentifiers = server
            and function(src)
                local p = H.players[tonumber(src)]
                return p and #(p.identifiers or {}) or 0
            end
        or nil
    _G.GetPlayerIdentifier = server
            and function(src, i)
                local p = H.players[tonumber(src)]
                return p and (p.identifiers or {})[(tonumber(i) or -1) + 1] or nil
            end
        or nil
    _G.GetNumPlayerTokens = server
            and function(src)
                local p = H.players[tonumber(src)]
                return p and #(p.tokens or {}) or 0
            end
        or nil
    _G.GetPlayerToken = server
            and function(src, i)
                local p = H.players[tonumber(src)]
                return p and (p.tokens or {})[(tonumber(i) or -1) + 1] or nil
            end
        or nil
    _G.Player = function(src)
        local p = H.players[tonumber(src)] or {}
        H.players[tonumber(src)] = p
        p.state = p.state or {}
        local st = p.state
        return {
            state = setmetatable({
                set = function(self, k, v) st[k] = v end,
            }, { __index = st }),
        }
    end
    -- GET_STATE_BAG_VALUE, the native that Player(src).state[key] ends in (scheduler.lua NewStateBag __index): the
    -- value of a 'player:<id>' bag from H.players[id].state, nil for a bag or player it does not know
    _G.GetStateBagValue = function(bagName, key)
        local id = tonumber(tostring(bagName):match('^player:(%d+)$'))
        local p = id and H.players[id]
        local st = p and p.state
        if type(st) ~= 'table' then return nil end
        return st[key]
    end
    _G.exports = setmetatable({}, {
        __index = function(_, res)
            return setmetatable({}, {
                __index = function(_, fnName)
                    local m = H.exportsMock[res]
                    local fn = m and m[fnName]
                    if not fn then error(('export %s:%s is not mocked'):format(res, fnName), 2) end
                    return function(_, ...) return fn(...) end
                end,
            })
        end,
        __call = function() end,   -- exports('Name', fn) registrations are ignored
    })
    _G.lib = {
        callback = {
            register = function(name, fn) H.callbacks[name] = fn end,
            await = function() return nil end,
        },
    }
    _G.MySQL = (H.storage == 'files' and H.filesMySQL) or (H.storage == 'shadow' and H.shadowMySQL) or MySQL
    _G.GetResourcePath = function() return H.resourcePath() end
    H.shipFolders(H.resourcePath())
    _G.joaat = function(s) return require('cjson') and (#tostring(s) * 2654435761) % 4294967296 end
    _G.GetHashKey = _G.joaat

    H.load('config/config.lua')
    Config.Database = Config.Database or {}
    if H.storage == 'files' then
        Config.Database.enabled = false
        Config.Database.folder = 'saves'
    else
        -- database and shadow runs always talk to MariaDB, whatever the shipped config says
        Config.Database.enabled = true
    end
    H.load('config/blocks.lua')
    if CP and CP.Hooks then H.resetHooks() end
    -- shared/*.lua in fxmanifest's (alphabetical) order
    H.load('shared/init.lua')
    H.load('shared/locale.lua')
    H.load('shared/net.lua')
    H.load('shared/npccombat.lua')
    H.load('shared/twists.lua')
    H.load('shared/utils.lua')
    if H.storage == 'files' and server and not H.filesMySQL then
        -- a spec run on its own (no tests/run.lua) starts from an empty saves folder: build the tables
        local fh = io.open(H.savesDir() .. '/_tables.json', 'r')
        if fh then fh:close() else H.resetSaves() end
        -- what fxmanifest does: the storage files load right after @oxmysql/lib/MySQL.lua
        H.load('modules/storage/memsql.lua')
        H.load('modules/storage/server.lua')
        H.filesMySQL = _G.MySQL
        preBootDb = nil
    end
    if H.storage == 'shadow' and server then
        -- a spec run on its own (no tests/run.lua): the twin and the saves folder start from the migrations
        local fh = io.open(H.savesDir() .. '/_tables.json', 'r')
        if fh then fh:close() else H.resetShadow() end
    end
    if opts.migrations ~= false and server then
        -- Mark migrations as ready without running them (the schema is applied by tests/run.lua).
        CP.Migrations = CP.Migrations
            or {
                ready = function() return true end,
                isReady = function() return true end,
                started = function() return true end,
                failed = function() return nil end,
                version = function() return H.migrationVersion() end,
            }
    end
    return H
end

-- The migration files in order, read from the FILES list of modules/migrations/server.lua (the runner's own list).
function H.migrationFiles()
    local f = assert(io.open(ROOT .. 'modules/migrations/server.lua', 'r'))
    local src = f:read('a')
    f:close()
    local body = assert(src:match('local FILES = (%b{})'), 'modules/migrations/server.lua has no FILES list')
    local out = {}
    for name in body:gmatch('\'([^\']+%.sql)\'') do out[#out + 1] = name end
    return out
end

-- The schema version the migrations reach: the number of the last file in FILES.
function H.migrationVersion()
    local files = H.migrationFiles()
    return tonumber((files[#files] or '0'):match('^(%d+)')) or 0
end

-- Apply sql/migrations/*.sql to cp_test from scratch (used by tests/run.lua once per run). In files mode the
-- saves folder of H.db is rebuilt too, in shadow mode the twin database and the saves folder.
function H.resetDatabase()
    local function run(cmd)
        if not os.execute(cmd) then error('the test database could not be built (mysql message above): ' .. cmd, 3) end
    end
    run(('mysql -uroot -e "DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(H.db, H.db))
    for _, f in ipairs(H.migrationFiles()) do
        run(('mysql -uroot %s < %ssql/migrations/%s'):format(H.db, ROOT, f))
    end
    if H.storage == 'files' then
        if CP and CP.Storage and CP.Storage.db then error('H.resetDatabase must run before H.boot in files mode', 2) end
        H.resetSaves()
    elseif H.storage == 'shadow' then
        H.resetShadow()
    end
end

-- A fresh saves folder for H.db, built by the real migrations runner on the engine (files mode).
function H.resetSaves()
    os.execute(('rm -rf \'%s\''):format(H.resourcePath()))
    H.shipFolders(H.resourcePath())
    preBootDb = nil
    RunMigrations(Memsql().shim(FilesEngine(), { resource = 'Crimson-Police' }))
end

-- A fresh twin database and saves folder for H.db, both built by the real migrations runner, every
-- statement compared (shadow mode).
function H.resetShadow()
    local r = TwinCall(('{"op":"reset","db":%s}'):format(Jstr(TwinName(H.db))))
    if not r.ok then error('shadow mode: the twin database could not be created: ' .. tostring(r.e), 2) end
    os.execute(('rm -rf \'%s\''):format(H.resourcePath()))
    H.shipFolders(H.resourcePath())
    shadowEngines[H.db] = nil
    RunMigrations(MakePairMySQL())
end

return H
