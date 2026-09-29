-- tests/harness.lua · a tiny FiveM/Qbox stand-in for unit tests (not shipped with the resource).
--
--   local H = dofile('tests/harness.lua')
--   H.boot({ side = 'server' })            -- Config, CP shared layer, native stubs, MySQL -> MariaDB
--   H.load('modules/scaling/server.lua')   -- any resource file, path relative to Crimson-Police/
--   H.eq(CP.Scaling.tierFor(3).tier, 'heavy')
--
-- MySQL.* runs real queries against the local MariaDB database `cp_test` through the mysql CLI
-- (schema from sql/migrations). Use H.sql('DELETE FROM cp_mission_runs') to reset tables.
-- Threads: CreateThread runs the function as a coroutine immediately; Wait(ms) advances the fake
-- clock and yields; H.step() resumes sleeping threads. Citizen.Await works on resolved promises.

local H = {}
local ROOT = (debug.getinfo(1, 'S').source:match('^@(.*)/tests/harness%.lua$') or '.') .. '/Crimson-Police/'
H.root = ROOT
H.events = {}        -- recorded TriggerClientEvent / TriggerServerEvent / TriggerEvent calls
H.handlers = {}      -- registered event handlers by name
H.callbacks = {}     -- lib.callback.register handlers by name
H.commands = {}
H.exportsMock = {}   -- H.exportsMock['sc-dispatch'] = { ClearNotification = function(...) end }
H.clockMs = 0
H.time = 1790000000  -- fake os.time()
H.db = os.getenv('CP_TEST_DB') or 'cp_test'   -- tests/run.lua gives every run its own database
H.failures = 0
H.passes = 0

local cjson = require('cjson')
cjson.encode_sparse_array(true)

-- ── assertions ──────────────────────────────────────────────────────────────
local function fmt(v)
    if type(v) == 'table' then
        local ok, s = pcall(cjson.encode, v)
        return ok and s or tostring(v)
    end
    return tostring(v)
end

function H.eq(actual, expected, msg)
    if actual == expected then H.passes = H.passes + 1; return true end
    H.failures = H.failures + 1
    print(('  FAIL %s: expected %s, got %s'):format(msg or '', fmt(expected), fmt(actual)))
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
    return H.ok(type(a) == 'number' and math.abs(a - b) <= (eps or 1e-6), (msg or '') .. (' (%s vs %s)'):format(tostring(a), tostring(b)))
end

-- ── vectors ─────────────────────────────────────────────────────────────────
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
local function vec(x, y, z, w) return setmetatable({ x = x, y = y, z = z, w = w }, vmt) end

-- ── threads ─────────────────────────────────────────────────────────────────
local sleeping = {}
local function resume(co, ...)
    local ok, err = coroutine.resume(co, ...)
    if not ok then error(err, 0) end
end

function H.step(ms)
    H.clockMs = H.clockMs + (ms or 0)
    local list = sleeping
    sleeping = {}
    for _, s in ipairs(list) do
        if s.wake <= H.clockMs and coroutine.status(s.co) == 'suspended' then
            resume(s.co)
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

-- ── MySQL through the mysql CLI ─────────────────────────────────────────────
local function sqlLiteral(v)
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
    v = tostring(v):gsub('\\', '\\\\'):gsub("'", "\\'")
    return "'" .. v .. "'"
end

local function interpolate(sql, params)
    params = params or {}
    local i = 0
    local out = {}
    local inStr = nil
    for c in sql:gmatch('.') do
        if inStr then
            out[#out + 1] = c
            if c == inStr then inStr = nil end
        elseif c == "'" or c == '"' then
            inStr = c
            out[#out + 1] = c
        elseif c == '?' then
            i = i + 1
            out[#out + 1] = sqlLiteral(params[i])
        else
            out[#out + 1] = c
        end
    end
    if i ~= #params and #params > 0 then
        error(('SQL placeholder count %d does not match %d params: %s'):format(i, #params, sql), 3)
    end
    return table.concat(out)
end

local function parseValue(s)
    if s == 'NULL' then return nil end
    local n = tonumber(s)
    if n and s:match('^%-?%d+%.?%d*$') then return n end
    return s
end

-- Returns rows (list of name->value tables) of the LAST result set.
function H.sql(sql, params)
    local q = interpolate(sql, params)
    local tmp = os.tmpname()
    local f = assert(io.open(tmp, 'w'))
    f:write(q, ';\n')
    f:close()
    local p = io.popen(('mysql -uroot %s --batch --raw < %s 2>&1'):format(H.db, tmp))
    local outText = p:read('a')
    p:close()
    os.remove(tmp)
    if outText:match('^ERROR') or outText:match('\nERROR') then
        error('SQL error: ' .. outText .. '\nquery: ' .. q, 2)
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
            for i, name in ipairs(header) do row[name] = parseValue(cols[i]) end
            rows[#rows + 1] = row
        end
    end
    return rows, header
end

local function lastScalar(sql, params, extra)
    local rows = H.sql(interpolate(sql, params) .. ';\n' .. extra, {})
    local r = rows[#rows]
    if not r then return nil end
    for _, v in pairs(r) do return v end
end

local function isSelect(sql)
    local s = sql:gsub('^%s+', ''):upper()
    return s:sub(1, 6) == 'SELECT' or s:sub(1, 4) == 'SHOW' or s:sub(1, 4) == 'WITH'
end

local MySQL = { query = {}, single = {}, scalar = {}, insert = {}, update = {}, prepare = {}, transaction = {} }
function MySQL.query.await(sql, params)
    if isSelect(sql) then return (H.sql(sql, params)) end
    local rows = H.sql(interpolate(sql, params) .. ';\nSELECT ROW_COUNT() AS affectedRows, LAST_INSERT_ID() AS insertId', {})
    return rows[#rows] or { affectedRows = 0 }
end
function MySQL.single.await(sql, params) return (H.sql(sql, params))[1] end
function MySQL.scalar.await(sql, params)
    local rows, header = H.sql(sql, params)
    if not rows[1] or not header then return nil end
    return rows[1][header[1]]
end
function MySQL.insert.await(sql, params) return tonumber(lastScalar(sql, params, 'SELECT LAST_INSERT_ID() AS id')) end
function MySQL.update.await(sql, params) return tonumber(lastScalar(sql, params, 'SELECT ROW_COUNT() AS n')) or 0 end
function MySQL.prepare.await() error('MySQL.prepare is not used in Crimson-Police (see ARCHITECTURE 0.6)') end
function MySQL.transaction.await(queries)
    for _, q in ipairs(queries) do
        if type(q) == 'table' then MySQL.query.await(q.query or q[1], q.values or q.parameters or q[2]) else MySQL.query.await(q) end
    end
    return true
end
for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
    setmetatable(MySQL[k], { __call = function(_, sql, params, cb)
        local r = MySQL[k].await(sql, params)
        if cb then cb(r) end
        return r
    end })
end
MySQL.ready = function(cb) cb() end
H.MySQL = MySQL

-- ── boot ────────────────────────────────────────────────────────────────────
function H.load(rel)
    local path = ROOT .. rel
    local chunk, err = loadfile(path)
    if not chunk then error(err, 2) end
    return chunk()
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
        resume(co, ...)
    end
end

-- Call an ox_lib callback as `src`.
function H.callback(name, src, ...)
    local fn = H.callbacks[name]
    if not fn then error('no callback ' .. name, 2) end
    local result
    local co = coroutine.create(function(...) result = fn(src, ...) end)
    resume(co, ...)
    return result
end

H.players = {}   -- H.players[src] = { ped coords = vec(...), state = {}, ace = { ['crimsonpolice.admin'] = true } }

function H.boot(opts)
    opts = opts or {}
    local server = (opts.side or 'server') == 'server'
    _G.vec3, _G.vector3 = vec, vec
    _G.vec4, _G.vector4 = vec, vec
    _G.vec2, _G.vector2 = function(x, y) return vec(x, y) end, function(x, y) return vec(x, y) end
    _G.json = { encode = function(v) return cjson.encode(v) end, decode = function(s) return cjson.decode(s) end }
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
        local s = f:read('a'); f:close(); return s
    end
    _G.SaveResourceFile = function(_, path, data)
        local f = assert(io.open(ROOT .. path, 'w')); f:write(data); f:close(); return true
    end
    _G.GetResourceState = function(name) return (opts.stopped and opts.stopped[name]) and 'stopped' or 'started' end
    _G.CreateThread = function(fn)
        local co = coroutine.create(fn)
        resume(co)
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
        if fn then H.handlers[name] = H.handlers[name] or {}; table.insert(H.handlers[name], fn) end
    end
    _G.AddEventHandler = function(name, fn)
        H.handlers[name] = H.handlers[name] or {}; table.insert(H.handlers[name], fn)
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
        return p and p.coords or vec(0.0, 0.0, 0.0)
    end
    _G.DoesEntityExist = function() return true end
    _G.GetPlayerName = function(src) return 'Player' .. tostring(src) end
    _G.Player = function(src)
        local p = H.players[tonumber(src)] or {}
        H.players[tonumber(src)] = p
        p.state = p.state or {}
        local st = p.state
        return { state = setmetatable({ set = function(self, k, v) st[k] = v end }, { __index = st }) }
    end
    _G.exports = setmetatable({}, {
        __index = function(_, res)
            return setmetatable({}, { __index = function(_, fnName)
                local m = H.exportsMock[res]
                local fn = m and m[fnName]
                if not fn then error(('export %s:%s is not mocked'):format(res, fnName), 2) end
                return function(_, ...) return fn(...) end
            end })
        end,
        __call = function() end,   -- exports('Name', fn) registrations are ignored
    })
    _G.lib = {
        callback = {
            register = function(name, fn) H.callbacks[name] = fn end,
            await = function() return nil end,
        },
    }
    _G.MySQL = MySQL
    _G.joaat = function(s) return require('cjson') and (#tostring(s) * 2654435761) % 4294967296 end
    _G.GetHashKey = _G.joaat

    H.load('config/config.lua')
    H.load('config/blocks.lua')
    H.load('shared/init.lua')
    H.load('shared/locale.lua')
    H.load('shared/net.lua')
    H.load('shared/utils.lua')
    if opts.migrations ~= false and server then
        -- Mark migrations as ready without running them (the schema is applied by tests/run.lua).
        CP.Migrations = CP.Migrations or { ready = function() return true end, isReady = function() return true end, version = function() return 2 end }
    end
    return H
end

-- Apply sql/migrations/*.sql to cp_test from scratch (used by tests/run.lua once per run).
function H.resetDatabase()
    os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(H.db, H.db))
    for _, f in ipairs({ '001_initial.sql', '002_test_def_hash.sql' }) do
        os.execute(('mysql -uroot %s < %ssql/migrations/%s'):format(H.db, ROOT, f))
    end
end

return H
