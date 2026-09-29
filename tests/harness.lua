-- A tiny FiveM/Qbox stand-in for unit tests (not shipped with the resource).

local H = {}
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
            out[#out + 1] = SqlLiteral(params[i])
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

-- One statement on the twin and on the engine (in that order, same pinned second); the twin's answer.
local function PairRun(kind, sql, params, fromSpec)
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
-- GetVehicleEngineHealth, DoesEntityExist and the net id natives (installed by H.boot; a spec that defines
-- its own natives after H.boot replaces them). H.advance moves each entity by its velocity (m/s) and applies
-- its timeline: e:at(ms, patch) sets fields when the fake clock reaches ms.
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
end

-- ============================================================================
--                        OTHER RESOURCES (opt-in mocks)
-- ============================================================================
-- ox_inventory: H.mockInventory() installs Search, CanCarryItem, AddItem, RemoveItem and Items and returns
-- the model ({ items = { [name] = { label } }, slots = { [src] = { slot } }, full = { [src] = true }, added,
-- removed }). ox_target: H.mockTarget() installs addBoxZone, removeZone, addLocalEntity, addEntity (options
-- with bones kept) and returns the recorded zones and options.
function H.mockInventory(items)
    local inv = { items = items or {}, slots = {}, full = {}, added = {}, removed = {} }
    H.exportsMock.ox_inventory = {
        Items = function(name)
            if name then return inv.items[name] end
            return inv.items
        end,
        Search = function(src, kind, name, meta)
            local out, count = {}, 0
            for _, sl in ipairs(inv.slots[src] or {}) do
                local ok = sl.name == name and sl.count > 0
                for k, v in pairs(meta or {}) do if not sl.metadata or sl.metadata[k] ~= v then ok = false end end
                if ok then
                    out[#out + 1] = sl
                    count = count + sl.count
                end
            end
            if kind == 'count' then return count end
            return out
        end,
        CanCarryItem = function(src, name, count)
            if inv.full[src] then return false end
            return inv.items[name] ~= nil or next(inv.items) == nil
        end,
        AddItem = function(src, name, count, meta)
            if inv.full[src] then return false, 'inventory_full' end
            inv.added[#inv.added + 1] = { src = src, name = name, count = count, meta = meta }
            inv.slots[src] = inv.slots[src] or {}
            local list = inv.slots[src]
            list[#list + 1] = { slot = #list + 1, name = name, count = count, metadata = meta }
            return true, 'ok'
        end,
        RemoveItem = function(src, name, count, _, slot)
            inv.removed[#inv.removed + 1] = { src = src, name = name, count = count, slot = slot }
            for _, sl in ipairs(inv.slots[src] or {}) do
                if sl.name == name and (slot == nil or sl.slot == slot) then sl.count = sl.count - count end
            end
            return true
        end,
        registerHook = function() return 1 end,
    }
    return inv
end

function H.mockTarget()
    local t = { zones = {}, entities = {}, localEntities = {}, removed = {} }
    local nextZone = 0
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

-- Simulate an incoming net event from `src` (handlers see `source`).
function H.fire(name, src, ...)
    local list = H.handlers[name] or {}
    for _, fn in ipairs(list) do
        local co = coroutine.create(function(...)
            _ENV.source = src
            source = src
            fn(...)
        end)
        Resume(co, ...)
    end
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

H.players = {}   -- H.players[src] = { ped coords = vec(...), state = {}, ace = { ['crimsonpolice.admin'] = true } }

function H.boot(opts)
    opts = opts or {}
    local server = (opts.side or 'server') == 'server'
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
        local f = assert(io.open(ROOT .. path, 'w'))
        f:write(data)
        f:close()
        return true
    end
    _G.GetResourceState = function(name) return (opts.stopped and opts.stopped[name]) and 'stopped' or 'started' end
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
    _G.TriggerServerEvent = function(name, ...)
        H.events[#H.events + 1] = { kind = 'server', name = name, args = { ... } }
    end
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
    _G.joaat = function(s) return require('cjson') and (#tostring(s) * 2654435761) % 4294967296 end
    _G.GetHashKey = _G.joaat

    H.load('config/config.lua')
    if H.storage == 'files' then
        Config.Database = Config.Database or {}
        Config.Database.enabled = false
        Config.Database.folder = 'saves'
    end
    H.load('config/blocks.lua')
    if CP and CP.Hooks then H.resetHooks() end
    H.load('shared/init.lua')
    H.load('shared/locale.lua')
    H.load('shared/net.lua')
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
    os.execute(('mkdir -p \'%s\''):format(H.savesDir()))
    preBootDb = nil
    RunMigrations(Memsql().shim(FilesEngine(), { resource = 'Crimson-Police' }))
end

-- A fresh twin database and saves folder for H.db, both built by the real migrations runner, every
-- statement compared (shadow mode).
function H.resetShadow()
    local r = TwinCall(('{"op":"reset","db":%s}'):format(Jstr(TwinName(H.db))))
    if not r.ok then error('shadow mode: the twin database could not be created: ' .. tostring(r.e), 2) end
    os.execute(('rm -rf \'%s\''):format(H.resourcePath()))
    os.execute(('mkdir -p \'%s\''):format(H.savesDir()))
    shadowEngines[H.db] = nil
    RunMigrations(MakePairMySQL())
end

return H
