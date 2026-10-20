-- A start that fails (FIXPLAN S5: F43-F47, F18, F20, F21). FXServer refuses StopResource on the calling resource

local H = require('harness')

local function Contains(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end
local function AnyContains(list, needle)
    for _, s in ipairs(list) do if Contains(s, needle) then return true end end
    return false
end
local function ReadFile(path)
    local f = assert(io.open(path, 'r'))
    local s = f:read('a')
    f:close()
    return s
end

local DENIED = 'CREATE command denied to user \'cp\'@\'localhost\' for table `qbox`.`cp_schema_migrations`'

-- ============================================================================
--             1. THE RUNNER (its own environment, the real Await)
-- ============================================================================

local RUNNER_SRC = ReadFile(H.root .. 'modules/migrations/server.lua')

-- mysqlImpl.query.await answers the runner; returns the runner's CP, its error lines, connect() (oxmysql connects:
-- MySQL.ready's callback) and the StopResource calls.
local function Runner(mysqlImpl, opts)
    opts = opts or {}
    local r = { errs = {}, stops = {}, warns = {} }
    local env = setmetatable({}, { __index = _G })
    env.CP = {
        err = function(_, fmt, ...) r.errs[#r.errs + 1] = tostring(fmt):format(...) end,
        log = function() end,
        warn = function(_, fmt, ...) r.warns[#r.warns + 1] = tostring(fmt):format(...) end,
        resource = 'Crimson-Police',
        Storage = opts.storage,
        Sysadmin = opts.sysadmin,
    }
    env.Config = { Tablet = { adminCommand = opts.cmd or 'CrimsonPoliceAdmin' } }
    env.print = function() end
    env.promise = {
        new = function()
            local p = { waiting = {} }
            function p:resolve(v)
                if self.done then return end
                self.done, self.value = true, v
                for _, co in ipairs(self.waiting) do
                    local ok, err = coroutine.resume(co)
                    if not ok then error(err, 0) end
                end
            end
            return p
        end,
    }
    env.Citizen = {
        Await = function(p)
            if not p.done then
                p.waiting[#p.waiting + 1] = coroutine.running()
                coroutine.yield()
            end
            return p.value
        end,
    }
    env.CreateThread = function(fn)
        local ok, err = coroutine.resume(coroutine.create(fn))
        if not ok then error(err, 0) end
    end
    env.SetTimeout = function() end
    env.StopResource = function(name)
        r.stops[#r.stops + 1] = name
        return name ~= 'Crimson-Police'
    end
    env.GetCurrentResourceName = function() return 'Crimson-Police' end
    env.LoadResourceFile = function(_, path) return ReadFile(H.root .. path) end
    local onReady
    mysqlImpl.ready = function(cb) onReady = cb end
    env.MySQL = mysqlImpl
    assert(load(RUNNER_SRC, '=migrations', 't', env))()
    r.cp = env.CP
    r.M = env.CP.Migrations
    r.connect = function() return pcall(onReady) end
    r.thread = env.CreateThread
    return r
end

-- A database that answers every statement (every migration recorded as applied), or raises `failOn`'s error.
local function Db(failOn)
    local applied = {}
    for i = 1, 8 do applied[i] = { version = i } end
    return {
        query = {
            await = function(sql)
                for needle, err in pairs(failOn or {}) do
                    if Contains(sql, needle) then error(err, 0) end
                end
                if Contains(sql, 'SELECT version FROM cp_schema_migrations') then return applied end
                return {}
            end,
        },
        insert = {
            await = function() return 1 end,
        },
    }
end

do
    -- 1.1 a database user without CREATE: threads that waited during the start wake up and stop at the barrier
    local r = Runner(Db({ ['CREATE TABLE IF NOT EXISTS cp_schema_migrations'] = DENIED }))
    local barrier, after, quiet = nil, false, nil
    r.thread(function()
        barrier = table.pack(pcall(function()
            r.M.ready()
            after = true
        end))
    end)
    r.thread(function() quiet = r.M.started() end)
    H.eq(barrier, nil, 'a request during the start waits for the migrations')
    local okC, errC = r.connect()
    H.ok(okC, 'the failure is handled in the runner: ' .. tostring(errC))
    H.ok(barrier and barrier[1] == false and barrier[2] == 'err.not_started' and not after,
        'the thread that waited wakes up and stops at ready() with err.not_started')
    H.eq(quiet, false, 'started() answers false to a start-up thread (no error: it ends quietly)')
    H.ok(Contains(r.M.failed and r.M.failed(), 'migration cp_schema_migrations failed'),
        'CP.Migrations.failed() names what failed')
    H.eq(r.M.isReady(), false, 'it never becomes ready')
    H.eq(#r.stops, 0, 'Crimson-Police never asks FXServer to stop itself (FXServer refuses it)')
    local okR, errR = pcall(r.M.ready)
    H.ok(not okR and errR == 'err.not_started', 'ready() after the failure raises err.not_started at once')
    H.eq(r.M.started(), false, 'started() at once too')
    H.ok(AnyContains(r.errs, 'How to fix it: Your database user may not create or change tables'), 'the fix')
    H.ok(AnyContains(r.errs, 'type "ensure Crimson-Police" in the server console (or restart it in txAdmin)'),
        'one line names "ensure Crimson-Police"')
    H.ok(AnyContains(r.errs, 'refuses every request'), 'and says it refuses every request until then')
    H.ok(not AnyContains(r.errs, 'will not start until it is fixed'), 'no promise of a stop FXServer never makes')
    H.ok(not AnyContains(r.errs, 'storagemode reset'), 'no storage mode line without a storage switched in game')
end

do
    -- 1.2 an error outside the guarded statements (the SELECT of cp_schema_migrations: a user with CREATE but not
    -- SELECT, or a connection lost between the two) fails the start too, instead of leaving every caller waiting
    local r = Runner(Db({ ['SELECT version FROM cp_schema_migrations'] = 'SELECT command denied to user \'cp\'' }))
    local waited = nil
    r.thread(function() waited = r.M.started() end)
    local okC, errC = r.connect()
    H.ok(okC, 'the runner does not die with the error: ' .. tostring(errC))
    H.ok(r.M.failed and r.M.failed() ~= nil, 'the start is failed')
    H.eq(waited, false, 'the thread that waited is told')
    H.ok(AnyContains(r.errs, 'SELECT command denied'), 'the error is printed')
    H.ok(AnyContains(r.errs, 'ensure Crimson-Police'), 'with the ensure line')

    -- any other unexpected error in the runner (here CP.Storage.describe) goes through the same failure
    local r2 = Runner(Db(), {
        storage = {
            describe = function() error('describe broke', 0) end,
        },
    })
    local okC2 = r2.connect()
    H.ok(okC2 and r2.M.failed and r2.M.failed() ~= nil and AnyContains(r2.errs, 'describe broke'),
        'an unexpected error anywhere in the runner fails the start with its text')
end

do
    -- 1.3 a storage switched to in game that cannot start: the failure names the console command that goes back to
    -- config.lua's store, with the command's configured name
    local r = Runner(
        Db({ ['CREATE TABLE IF NOT EXISTS cp_schema_migrations'] = 'saves/broken/_tables.json is not valid JSON' }), {
            cmd = 'PDAdmin',
            storage = {
                override = function() return { mode = 'files', folder = 'saves/broken' } end,
                describe = function() return 'saves folder saves/broken' end,
            },
        })
    r.connect()
    H.ok(AnyContains(r.errs, 'type "PDAdmin storagemode reset" in the server console, then "ensure Crimson-Police"'),
        'the way back from a broken storage switch, with Config.Tablet.adminCommand')
end

do
    -- 1.4 the start-up locks (F20): the runner takes them (CP.Sysadmin.startLocks) before any waiting caller goes on
    local order = {}
    local r = Runner(Db(), {
        sysadmin = {
            startLocks = function()
                order[#order + 1] = 'the start-up lock'
            end,
        },
    })
    r.thread(function()
        r.M.ready()
        order[#order + 1] = 'a waiting payment'
    end)
    r.connect()
    H.eq(r.M.isReady(), true, 'a working start becomes ready')
    H.eq(table.concat(order, ', '), 'the start-up lock, a waiting payment',
        'the start-up locks are taken before the thread that waited goes on')
    H.eq(r.M.failed(), nil, 'and failed() is nil')
end

do
    -- 1.5 the database server (FIXPLAN S10). A server is played as the real ones answered the runner's probe
    -- (VERSION(), JSON_VALUE of a string and of a JSON null; run on each server: MySQL 8.0.20 has no JSON_VALUE,
    -- MariaDB 10.2 reads a JSON null as the text 'null', oxmysql hands IS NULL over as the number 1 or 0).
    local DATABASE = {
        mode = function() return 'database' end,
        name = function() return 'database' end,
    }
    -- oxmysql's error text: "<resource> was unable to execute a query!\nQuery: ...\n[params]\n<message>"
    local function OxError(sql, message)
        return ('Crimson-Police was unable to execute a query!\nQuery: %s\n[]\n%s'):format(sql, message)
    end
    local function Server(version, probe)
        local db, sent = Db(), {}
        local answer = db.query.await
        db.query.await = function(sql, ...)
            sent[#sent + 1] = sql
            if Contains(sql, 'JSON_VALUE(') then
                if type(probe) == 'string' then error(OxError(sql, probe), 0) end
                return { { v = version, a = probe.a, n = probe.n } }
            end
            if Contains(sql, 'SELECT VERSION()') then return { { v = version } } end
            return answer(sql, ...)
        end
        local r = Runner(db, { storage = DATABASE })
        r.connect()
        r.sent = sent
        return r
    end
    local function Touched(r)
        for _, sql in ipairs(r.sent) do if Contains(sql, 'cp_schema_migrations') then return true end end
        return false
    end

    -- MySQL 8.0.20: "FUNCTION <database>.JSON_VALUE does not exist", so every payment would fail half way
    local old = Server('8.0.20', 'FUNCTION qbox.JSON_VALUE does not exist')
    H.eq(old.M.failed(), 'the database server is too old', 'MySQL 8.0.20: the start fails, named')
    H.ok(AnyContains(old.errs, 'The database server is MySQL 8.0.20. Crimson-Police needs MariaDB 10.3 or newer'),
        'the console names the server and what Crimson-Police needs')
    H.ok(
        AnyContains(old.errs, 'How to fix it: update the database server to MariaDB 10.9 or newer')
            and AnyContains(old.errs, 'Config.Database.enabled = false'),
        'and how to fix it: MariaDB, or the saves folder'
    )
    H.ok(AnyContains(old.errs, 'type "ensure Crimson-Police" in the server console'), 'and how to come back')
    H.eq(Touched(old), false, 'no table is touched on that server')
    H.eq(#old.stops, 0, 'and no self-stop is asked for (FXServer refuses it)')
    local okR, errR = pcall(old.M.ready)
    H.ok(not okR and errR == 'err.not_started', 'every request is refused with err.not_started')

    -- MariaDB 10.2: JSON_VALUE reads a JSON null as 'null' (the Payments screen and the payment steps read NULL)
    local m102 = Server('10.2.44-MariaDB-1:10.2.44+maria~bionic', { a = 'b', n = 0 })
    H.ok(m102.M.failed() ~= nil and AnyContains(m102.errs, 'The database server is 10.2.44-MariaDB'),
        'MariaDB 10.2: refused too, named as it is')

    -- MySQL 8.0.21 and newer has everything: it starts, with one warning (Qbox does not support MySQL)
    local mysql = Server('8.0.46-0ubuntu0.24.04.4', { a = 'b', n = 1 })
    H.eq(mysql.M.isReady(), true, 'MySQL 8.0.46: it starts')
    H.ok(
        #mysql.warns == 1 and Contains(mysql.warns[1], 'the database server is MySQL 8.0.46-0ubuntu0.24.04.4')
            and Contains(mysql.warns[1], 'Qbox does not support MySQL'),
        'with one warning that says Qbox wants MariaDB'
    )

    -- the MariaDB Qbox recommends: no line at all
    local m123 = Server('12.3.3-MariaDB-ubu2404', { a = 'b', n = 1 })
    H.ok(m123.M.isReady() and #m123.warns == 0 and #m123.errs == 0, 'MariaDB 12.3: it starts, nothing said')

    -- a server that does not answer (oxmysql's text holds the probe, JSON_VALUE and all) is left to the migrations,
    -- which name the usual errors
    local downDb = Db({ CREATE = 'connect ECONNREFUSED 127.0.0.1:3306' })
    local answerDown = downDb.query.await
    downDb.query.await = function(sql, ...)
        if Contains(sql, 'SELECT VERSION()') then error(OxError(sql, 'connect ECONNREFUSED 127.0.0.1:3306'), 0) end
        return answerDown(sql, ...)
    end
    local down = Runner(downDb, { storage = DATABASE })
    down.connect()
    H.ok(
        Contains(down.M.failed(), 'migration cp_schema_migrations failed')
            and AnyContains(down.errs, 'cannot reach the database server')
            and not AnyContains(down.errs, 'The database server is'),
        'no answer: the migration error and its fix'
    )
end

-- ============================================================================
--           2. THE WHOLE RESOURCE ON A DATABASE USER WITHOUT CREATE
-- ============================================================================

-- a storage switched to in game (to the store this run uses, so the spec keeps its storage mode)
local kvp = { cp_storage_mode = H.storage == 'files' and 'files' or 'database', cp_storage_folder = 'saves' }
_G.GetResourceKvpString = function(k) return kvp[k] end
_G.SetResourceKvp = function(k, v) kvp[k] = v end
_G.DeleteResourceKvp = function(k) kvp[k] = nil end

local actions, callbacks = {}, {}
local afterFail = {}        -- statements that reached the store once the start had failed
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'failstart', {
    beforeLoad = function()
        local a, c = CP.Net.action, CP.Net.callback
        CP.Net.action = function(name, ...)
            actions[#actions + 1] = 'crimson-police:' .. name
            return a(name, ...)
        end
        CP.Net.callback = function(name, ...)
            callbacks[#callbacks + 1] = 'crimson-police:' .. name
            return c(name, ...)
        end
        for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update', 'prepare' }) do
            local okM, m = pcall(function()
                return MySQL[k]
            end) -- files mode refuses MySQL.prepare
            if okM and type(m) == 'table' and type(m.await) == 'function' then
                local real = m.await
                m.await = function(sql, ...)
                    if Contains(sql, 'CREATE TABLE IF NOT EXISTS cp_schema_migrations') then error(DENIED, 0) end
                    local M = CP.Migrations
                    if M and M.failed and M.failed() then afterFail[#afterFail + 1] = tostring(sql):sub(1, 100) end
                    return real(sql, ...)
                end
            end
        end
    end,
})
local M = CP.Migrations

H.ok(M.failed and M.failed() ~= nil, 'the start failed (no CREATE right)')
H.eq(X.stopResource, 0, 'StopResource is never called: the resource stays started, in a failed state')
H.ok(AnyContains(X.lines, 'type "ensure Crimson-Police" in the server console'), 'the console says how to come back')
H.ok(AnyContains(X.lines, 'type "CrimsonPoliceAdmin storagemode reset" in the server console'),
    'and, for the storage switched to in game, how to go back to config.lua\'s')

-- the console command is there at once (it used to wait 15 s for settings that never load)
local cmd = H.commands.CrimsonPoliceAdmin
H.ok(cmd ~= nil and H.clockMs <= 5000, 'the console command registers right away: ' .. tostring(H.clockMs) .. ' ms')

-- every action and callback answers err.not_started before its handler runs: nothing parks, nothing touches the store
H.ok(#actions > 100 and #callbacks > 50,
    ('every CP.Net entry point found (%d actions, %d callbacks)'):format(#actions, #callbacks))
local wrongA, wrongC = {}, {}
for i, name in ipairs(actions) do
    for _, src in ipairs({ 1, 5 }) do
        local id = 'fs' .. i .. '_' .. src
        local mark = #H.events
        H.fire(name, src, { reason = 'a reason', confirm = 'CONFIRM', requestId = X.rid() }, id)
        local answer = nil
        for k = #H.events, mark + 1, -1 do
            local e = H.events[k]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then answer = e end
        end
        if not (answer and answer.args[2] == false and answer.args[3] == 'err.not_started') then
            wrongA[#wrongA + 1] = name
        end
    end
end
for _, name in ipairs(callbacks) do
    for _, src in ipairs({ 1, 5 }) do
        local res = H.callback(name, src, { ui = src == 5 and 'admin' or 'officer' })
        if not (type(res) == 'table' and res.ok == false and res.error == 'err.not_started') then
            wrongC[#wrongC + 1] = name
        end
    end
end
H.eq(table.concat(wrongA, ', '), '', 'every action answers err.not_started at once, as officer and as admin')
H.eq(table.concat(wrongC, ', '), '', 'every callback too (the tablet shows it at once, not after 15 s)')

-- the console: check and storage mode reset work and print; everything else (and the in-game open) is refused
local function Console(args)
    local from = #X.lines
    cmd.fn(0, args)
    X.adv(500)
    local out = {}
    for i = from + 1, #X.lines do out[#out + 1] = X.lines[i] end
    return out
end
local storage = Console({ 'storage' })
H.ok(
    #storage == 1 and Contains(storage[1], 'Crimson-Police did not start')
        and Contains(storage[1], 'ensure Crimson-Police'),
    'the console\'s storage is refused with one line'
)
H.ok(#Console({ 'check' }) > 3, 'the console\'s check prints its lines')
local reset = Console({ 'storagemode', 'reset' })
H.eq(kvp.cp_storage_mode, nil, 'storagemode reset clears the storage chosen in game')
H.ok(AnyContains(reset, 'The storage chosen in game is cleared') and AnyContains(reset, 'ensure Crimson-Police'),
    'and prints its confirmation at once (it used to wait for good on the audit row)')
kvp.cp_storage_mode = 'files'
local reset2 = Console({ 'storage', 'mode', 'reset' })
H.ok(kvp.cp_storage_mode == nil and AnyContains(reset2, 'The storage chosen in game is cleared'),
    'storage mode reset (the other spelling) too')
local mark = #H.events
cmd.fn(5, {})
X.adv(500)
local refused = false
for i = mark + 1, #H.events do
    local e = H.events[i]
    if e.target == 5 and Contains(require('cjson').encode(e.args), 'admin.cmd.not_started') then refused = true end
    if e.target == 5 and Contains(require('cjson').encode(e.args), 'did not start') then refused = true end
end
H.ok(refused, 'an admin\'s in-game command is refused with the not-started line')

-- the start-up threads and loops end quietly over a long run: no thread raises (the harness would crash the spec
-- on it, as FXServer would print a SCRIPT ERROR), no "failed: err.not_started" lines, no store access
local before = #X.lines
H.fire('QBCore:Server:PlayerLoaded', 0, X.PD and { PlayerData = X.PD[1] } or nil)
H.fire('QBCore:Server:OnPlayerUnload', 0, 3)
H.fire('playerDropped', 3)
X.adv(30 * 60 * 1000, 5000)
-- and across the daily and weekly resets (the scheduled jobs fire, and stop at the barrier quietly)
H.time = H.time + 8 * 86400
X.adv(5 * 60 * 1000, 5000)
local noisy = {}
for i = 1, #X.lines do if Contains(X.lines[i], 'err.not_started') then noisy[#noisy + 1] = X.lines[i] end end
H.eq(table.concat(noisy, ' | '), '', 'no console line carries err.not_started (the failure lines say it all)')
H.ok(#X.lines - before < 20, ('the console stays quiet afterwards (%d lines in 30 minutes)'):format(#X.lines - before))
H.eq(table.concat(afterFail, ' | '), '', 'nothing reached the store after the failure')
H.eq(M.isReady(), false, 'still not started')

X.cleanup()
return H
