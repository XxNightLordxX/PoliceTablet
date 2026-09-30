-- Parity-plus foundation (WP1): migrations 003-006, CP.Hooks, CP.Lt tokens, the engine contracts other packages build
-- on (stats, decisions, adoption, hidden spawns, plates, held bodies, removals), levels, tweaks, the Session.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
local cjson = require('cjson')

local function Contains(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end
local function Count(list, pred)
    local n = 0
    for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
    return n
end
local function ReadFile(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- ============================================================================
--                     1. MIGRATIONS (both storage engines)
-- ============================================================================
-- The real runner (modules/migrations/server.lua) in its own environment, on any MySQL table. files (optional)
-- replaces its FILES list, to play a server from before this build. Returns the runner's CP and its lines.
local RUNNER_SRC = ReadFile(H.root .. 'modules/migrations/server.lua')

local function Runner(mysqlImpl, files)
    local lines, errs = {}, {}
    local env = setmetatable({}, { __index = _G })
    env.CP = {
        err = function(_, fmt, ...) errs[#errs + 1] = tostring(fmt):format(...) end,
        log = function() end,
        warn = function() end,
    }
    env.MySQL = mysqlImpl
    env.print = function(...) lines[#lines + 1] = table.concat({ ... }, ' ') end
    env.promise = {
        new = function()
            local p = {}
            function p:resolve(v) self.resolved = true; self.value = v end
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
    env.LoadResourceFile = function(_, path) return ReadFile(H.root .. path) end
    local src = RUNNER_SRC
    if files then
        local list = {}
        for _, f in ipairs(files) do list[#list + 1] = ('    \'%s\','):format(f) end
        src = src:gsub('local FILES = %b{}', function()
            return 'local FILES = {\n' .. table.concat(list, '\n') .. '\n}'
        end)
    end
    local chunk = assert(load(src, '=migrations', 't', env))
    chunk()
    local applied = {}
    for _, l in ipairs(lines) do
        local name = l:match('applied migration (%S+)')
        if name then applied[#applied + 1] = name end
    end
    return { cp = env.CP, lines = lines, errs = errs, applied = applied }
end

local FILES = H.migrationFiles()
H.eq(#FILES, 6, 'FILES lists 001-006')
H.eq(FILES[3], '003_run_stats.sql', '003 after 002')
H.eq(FILES[6], '006_item_rewards.sql', '006 last')
H.eq(H.migrationVersion(), 6, 'the harness reads the version from FILES')
H.eq(CP.Migrations.version(), 6, 'the harness\' CP.Migrations.version() is the real version')
local NEW_FILES = { '003_run_stats.sql', '004_profile.sql', '005_mission_calls.sql', '006_item_rewards.sql' }
local function SameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do if a[i] ~= b[i] then return false end end
    return true
end

-- ============================================================================
--                           THE SAVES FOLDER ENGINE
-- ============================================================================

local M = H.memsql()
local TMP = os.tmpname()
os.remove(TMP)
os.execute(('mkdir -p \'%s\''):format(TMP))
local function Folder(name)
    local dir = TMP .. '/' .. name
    os.execute(('mkdir -p \'%s\''):format(dir))
    local db = M.new({ store = M.folderStore(dir) }):load()
    return db, M.shim(db, { resource = 'Crimson-Police' }), dir
end

do
    local db, shim, dir = Folder('fresh')
    local r = Runner(shim)
    H.ok(r.cp.Migrations.isReady(), 'a fresh saves folder: the runner finishes')
    H.eq(#r.errs, 0, 'no migration error')
    H.eq(r.cp.Migrations.version(), 6, 'at version 6')
    H.ok(SameList(r.applied, FILES), 'a fresh saves folder gets 001-006 once, in order')
    for _, t in ipairs({ 'cp_commendations', 'cp_profile_reports', 'cp_mission_calls', 'cp_item_rewards' }) do
        H.ok(db.tables[t] ~= nil, t .. ' exists in the saves folder')
    end
    H.ok(db.tables.cp_mission_runs.colIndex.decisions_best ~= nil, 'cp_mission_runs.decisions_best')
    H.ok(db.tables.cp_mission_runs_archive.colIndex.response_s ~= nil, 'the archive gets the new columns too')
    H.ok(db.tables.cp_officers.colIndex.calls_muted ~= nil, 'cp_officers.calls_muted')
    -- a restart: the folder read back, nothing applied again
    local db2 = M.new({ store = M.folderStore(dir) }):load()
    local r2 = Runner(M.shim(db2, { resource = 'Crimson-Police' }))
    H.eq(#r2.applied, 0, 'a second start applies nothing')
    H.eq(r2.cp.Migrations.version(), 6, 'and reports version 6')
end

do
    local _, shim, dir = Folder('before')
    local r = Runner(shim, { '001_initial.sql', '002_test_def_hash.sql' })
    H.ok(SameList(r.applied, { '001_initial.sql', '002_test_def_hash.sql' }),
        'a folder made before this build: 001-002')
    local db2 = M.new({ store = M.folderStore(dir) }):load()
    local r2 = Runner(M.shim(db2, { resource = 'Crimson-Police' }))
    H.ok(SameList(r2.applied, NEW_FILES), 'its next start applies exactly 003-006')
    H.eq(#r2.errs, 0, 'without errors')
end

do
    -- a partial apply: half of 003 and the first column of 004 ran, nothing was recorded
    local db, shim = Folder('partial')
    Runner(shim, { '001_initial.sql', '002_test_def_hash.sql' })
    local stmts = H.splitStatements(ReadFile(H.root .. 'sql/migrations/003_run_stats.sql'))
    for i = 1, math.floor(#stmts / 2) do db:exec(stmts[i]) end
    db:exec(H.splitStatements(ReadFile(H.root .. 'sql/migrations/004_profile.sql'))[1])
    db:exec(H.splitStatements(ReadFile(H.root .. 'sql/migrations/005_mission_calls.sql'))[1])
    local r = Runner(shim)
    H.ok(r.cp.Migrations.isReady(), 'a re-run after a partial apply finishes')
    H.eq(#r.errs, 0, 'the columns and tables already there count as applied')
    H.ok(SameList(r.applied, NEW_FILES), 'and 003-006 are recorded')
    H.ok(db.tables.cp_mission_runs_archive.colIndex.mission_call_id ~= nil, 'the rest of 003 was applied')
end

-- ============================================================================
--                                   MariaDB
-- ============================================================================

local mariaOnly = 'the migrations on a MariaDB database of their own (the saves folder engine is checked above)'
if not H.skipIn('files', mariaOnly) and not H.skipIn('shadow', mariaOnly) then
    local base = H.db
    local fdb = base .. '_fnd'
    local function Mysql(sql)
        assert(os.execute(('mysql -uroot -e "%s"'):format(sql)))
    end
    local function Pipe(file)
        assert(os.execute(('mysql -uroot %s < %ssql/migrations/%s'):format(fdb, H.root, file)))
    end
    local impl = {}
    local function On(fn)
        return function(sql, params)
            local keep = H.db
            H.db = fdb
            local ok, res = pcall(fn, sql, params)
            H.db = keep
            if not ok then error(res, 0) end
            return res
        end
    end
    impl.query = { await = On(function(sql, p) return H.sql(sql, p) end) }
    impl.insert = { await = On(function(sql, p) H.sql(sql, p) return 1 end) }
    impl.scalar = {
        await = On(function(sql, p)
            local r = H.sql(sql, p)
            local row = r[1]
            return row and next(row) and row[next(row)]
        end),
    }
    local function Fresh()
        Mysql(('DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;'):format(fdb, fdb))
    end
    Fresh()
    local r = Runner(impl)
    H.eq(#r.errs, 0, 'MariaDB: a fresh database migrates')
    H.ok(SameList(r.applied, FILES), 'MariaDB: 001-006 applied once')
    local r2 = Runner(impl)
    H.eq(#r2.applied, 0, 'MariaDB: a second start applies nothing')
    Fresh()
    Pipe('001_initial.sql')
    Pipe('002_test_def_hash.sql')
    On(function()
        H.sql(
            'INSERT INTO cp_schema_migrations (version, name) VALUES (1, \'001_initial.sql\'), (2, \'002_test_def_hash.sql\')')
    end)()
    local stmts = H.splitStatements(ReadFile(H.root .. 'sql/migrations/003_run_stats.sql'))
    for i = 1, 5 do On(function() H.sql(stmts[i]) end)() end
    local r3 = Runner(impl)
    H.eq(#r3.errs, 0, 'MariaDB: a re-run after a partial apply of 003 succeeds')
    H.ok(SameList(r3.applied, NEW_FILES), 'MariaDB: a database from before this build gets exactly 003-006')
    -- the retention job's copy: INSERT ... SELECT * with the new columns on both tables
    On(function()
        H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, flagged, arrests, decisions_best, mission_call_id)
            VALUES ('fnd-1', 'patrol', 'beat_patrol', 'CITF', 'sast', 1, 1, 'standard', 'completed', 'completed', 60, 0,
            0, 60, 250, 1.00, 250, 'paid', 100, 0, 2, 3, 7)]])
        H.sql('INSERT INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE run_uuid = \'fnd-1\'')
    end)()
    local arch = On(function()
        return H.sql('SELECT arrests, decisions_best, mission_call_id FROM cp_mission_runs_archive')
    end)()
    H.eq(#arch, 1, 'MariaDB: INSERT INTO the archive SELECT * still works')
    H.eq(tonumber(arch[1].decisions_best), 3, 'MariaDB: the new columns are copied')
    Mysql(('DROP DATABASE IF EXISTS %s;'):format(fdb))
    H.db = base
end

-- the same copy on the spec's own storage (MariaDB, the saves folder or both)
H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, participants,
    departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
    cash_multiplier, cash_paid, cash_status, duration_s, flagged, arrests, decisions_best, location_index)
    VALUES ('fnd-archive', 'patrol', 'beat_patrol', 'CITARCH', 'sast', 1, 1, 'standard', 'completed', 'completed', 60,
    0, 0, 60, 250, 1.00, 250, 'paid', 100, 0, 1, 2, 3)]])
H.sql('INSERT INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE run_uuid = \'fnd-archive\'')
local archived = H.sql(
    'SELECT arrests, decisions_best, location_index FROM cp_mission_runs_archive WHERE run_uuid = \'fnd-archive\'')
H.eq(#archived, 1, 'the retention copy works on this storage')
H.eq(tonumber(archived[1].location_index), 3, 'with the new columns')
H.sql('DELETE FROM cp_mission_runs_archive WHERE run_uuid = \'fnd-archive\'')
H.sql('DELETE FROM cp_mission_runs WHERE run_uuid = \'fnd-archive\'')
os.execute(('rm -rf \'%s\''):format(TMP))

-- ============================================================================
--                                 2. CP.HOOKS
-- ============================================================================

do
    local seen = {}
    local a = CP.Hooks.on('fnd:test', function(x) seen[#seen + 1] = 'a' .. x end)
    CP.Hooks.on('fnd:test', function() error('boom') end)
    local c = CP.Hooks.on('fnd:test', function(x) seen[#seen + 1] = 'c' .. x end)
    local n = CP.Hooks.fire('fnd:test', 1)
    H.eq(table.concat(seen, ','), 'a1,c1', 'listeners run in order; a failing one does not stop the next')
    H.eq(n, 2, 'fire returns the listeners that ran')
    H.ok(CP.Hooks.off(a), 'off')
    CP.Hooks.fire('fnd:test', 2)
    H.eq(table.concat(seen, ','), 'a1,c1,c2', 'an off listener is gone')
    H.ok(not CP.Hooks.off(a), 'off twice is false')
    CP.Hooks.off(c)
    H.eq(CP.Hooks.fire('fnd:none'), 0, 'a hook nobody listens to')
    -- a listener may yield where the hook allows it: it runs in the caller's thread
    local order = {}
    CP.Hooks.on('fnd:yield', function() order[#order + 1] = 'before'; Wait(500); order[#order + 1] = 'after' end)
    CreateThread(function() CP.Hooks.fire('fnd:yield'); order[#order + 1] = 'caller' end)
    H.advance(600)
    H.eq(table.concat(order, ','), 'before,after,caller', 'a yielding listener runs in the caller\'s thread')
    H.resetHooks()
    H.eq(CP.Hooks.fire('fnd:yield'), 0, 'H.resetHooks drops every listener')
end

-- ============================================================================
--                               3. CP.Lt TOKENS
-- ============================================================================

do
    local t = CP.Lt('scoring.level_up', { level = CP.Lt('scoring.level_n', { n = 24 }) })
    H.ok(CP.Locale.isToken(t), 'CP.Lt makes a token')
    local s = CP.Locale.encode(t)
    H.ok(type(s) == 'string' and s:sub(1, 1) == '\30', 'encoded as a \\30 token string')
    H.eq(CP.Locale.resolve(s), 'Level up: Lv 24', 'nested vars resolve')
    H.eq(CP.Locale.resolve(t), 'Level up: Lv 24', 'a token table resolves too')
    H.eq(CP.Locale.resolve('Plain text'), 'Plain text', 'plain text is left alone')
    H.eq(CP.Locale.resolve('Before ' .. CP.Locale.encode(CP.Lt('scoring.level_n', { n = 3 })) .. ' after'),
        'Before Lv 3 after', 'a token inside other text')
    local payload = CP.Locale.tokenize({ message = { text = t, kind = 'info' }, coords = vec3(1.0, 2.0, 3.0) })
    H.eq(type(payload.message.text), 'string', 'tokenize turns tokens into strings')
    H.eq(payload.coords.x, 1.0, 'and keeps vectors')
    H.eq(CP.Locale.resolveAll(payload).message.text, 'Level up: Lv 24', 'resolveAll on the client side')
    H.eq(CP.Locale.label('scoring.level_n', 'fallback', { n = 5 }), 'Lv 5', 'label: the locale key wins')
    H.eq(CP.Locale.label('mission.nope.label', 'My mission'), 'My mission', 'label: the fallback otherwise')
    -- CP.L is never replaced: two coroutines, one yielding between a HUD token and a webhook body
    local hookA, hookB, hudToken
    local co1 = coroutine.create(function()
        hudToken = CP.Locale.encode(CP.Lt('scoring.level_n', { n = 7 }))
        coroutine.yield()
        hookA = CP.L('scoring.level_up', { level = 'Lv 7' })
    end)
    local co2 = coroutine.create(function() hookB = CP.L('scoring.level_up', { level = 'Lv 9' }) end)
    coroutine.resume(co1)
    coroutine.resume(co2)
    coroutine.resume(co1)
    H.ok(Contains(hudToken, '\30'), 'the HUD text is a token')
    H.ok(not Contains(hookA, '\30') and not Contains(hookB, '\30'), 'no webhook text carries a token')
    H.eq(hookB, 'Level up: Lv 9', 'webhook text is plain text')
end

-- ============================================================================
--                          4. THE ENGINE, WITH STUBS
-- ============================================================================

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_officers')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)

local nextNet = 9000
local deleted, weapons, armour, bags = {}, {}, {}, {}
local function NewEntity(kind, model, x, y, z, h)
    nextNet = nextNet + 1
    local e = H.entity(nextNet, { kind = kind, model = model, coords = vec3(x, y, z), heading = h or 0.0 })
    return e.handle
end
local function Ent(handle) return H.entityModel.byHandle[handle] end
_G.CreatePed = function(_, model, x, y, z, h) return NewEntity('ped', model, x, y, z, h) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return NewEntity('vehicle', model, x, y, z, h) end
_G.CreateObjectNoOffset = function(model, x, y, z) return NewEntity('object', model, x, y, z) end
_G.DeleteEntity = function(h)
    deleted[h] = true
    local e = Ent(h)
    if e then e.exists = false end
end
_G.GiveWeaponToPed = function(h, w) weapons[#weapons + 1] = { h = h, w = w } end
_G.SetPedArmour = function(h, a) armour[h] = a end
_G.SetVehicleNumberPlateText = function(h, p) local e = Ent(h) if e then e.plate = p end end
_G.SetEntityHeading = function(h, v) local e = Ent(h) if e then e.heading = v end end
_G.FreezeEntityPosition = function() end
_G.GetEntityHealth = function(h) local e = Ent(h); return e and e.health or 200 end
_G.GetEntityModel = function(h) local e = Ent(h); return e and joaat(e.model) or 0 end
_G.GetEntityType = function(h)
    local e = Ent(h)
    if not e then return 1 end
    return ({ ped = 1, vehicle = 2, object = 3 })[e.kind] or 0
end
_G.IsPedAPlayer = function(h) return Ent(h) == nil end
_G.GetPedArmour = function(h) return armour[h] or 0 end
_G.GetPedSourceOfDeath = function() return 0 end
_G.GetPedSourceOfDamage = function() return 0 end
_G.Entity = function(h)
    local b = bags[h]
    if not b then b = {}; bags[h] = b end
    return {
        state = setmetatable({
            set = function(_, k, v) b[k] = v end,
        }, { __index = b }),
    }
end
_G.GetPlayerRoutingBucket = function(src) local p = H.players[tonumber(src)]; return p and p.bucket or 0 end

local log = {}
local function Rec(k, v) log[k] = log[k] or {}; log[k][#log[k] + 1] = v end
local function Logged(k) return log[k] or {} end
local notes = {}

CP.Alerts = {
    set = function() end,
    clear = function() end,
    forget = function() end,
    inArena = function() return false end,
    foreignClearedAt = {},
}
CP.Route = {
    begin = function() end,
    stop = function() end,
    status = function() return { status = 'arrived', distance = 0 } end,
}
CP.Draw = {
    reserve = function() return true end,
    release = function() return true end,
    recordLast = function() end,
}
CP.Events = {
    rollModifier = function() return nil end,
    typeOfTheDay = function() return nil end,
}
CP.Payouts = {
    baseFor = function() return 250 end,
}
CP.Cash = {
    compute = function() return 0, { B = 0, mTier = 1.0, mMod = 1.0, amount = 0 } end,
    earnedThisWeek = function() return 0 end,
}
CP.Leaderboard = { invalidate = function() end }
CP.Challenge = {
    currentSeason = function() return nil end,
}
CP.AntiCheat = {
    checkEvent = function() return true end,
    flag = function(run, src, reason, detail)
        Rec('flag', { src = src, reason = reason, detail = detail })
        if src and run.participants[src] then
            run.participants[src].flagged = { reason = reason }
        else
            run.flagged = { reason = reason }
        end
    end,
    presenceOk = function() return true end,
    presenceShare = function() return 1.0 end,
}
CP.Units = {
    unitOf = function() return nil end,
    unlock = function() end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end,
    push = function() end,
}
local CIDS = { [1] = 'FND1', [2] = 'FND2', [3] = 'FND3' }
CP.Access = {
    recheck = function() return true end,
    onLost = function() end,
    departmentForJob = function(job) return job end,
}
CP.Qbx = {
    getInfo = function(src)
        local cid = CIDS[src]
        if not cid then return nil end
        return { src = src, citizenid = cid, name = 'Officer ' .. src, job = { name = 'sast', onduty = true } }
    end,
    getByCitizenId = function(cid)
        for src, c in pairs(CIDS) do if c == cid then return src end end
        return nil
    end,
    onPlayerUnload = function() end,
    onPlayerLoaded = function() end,
    onDutyChange = function() end,
    onJobChange = function() end,
    getOnlinePlayers = function() return { 1, 2, 3 } end,
}
CP.Schedule = {
    now = function() return os.time() end,
    dayStart = function(ts)
        local t = os.date('*t', ts or os.time())
        return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
    end,
}

-- a block that records every hook call
local calls = {}
local function CallsOf(name, index)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name and (index == nil or c.index == index) then out[#out + 1] = c end end
    return out
end
CP.Blocks.register('fnd_block', {
    prepare = function(ctx) calls[#calls + 1] = { name = 'prepare', index = ctx.index } end,
    start = function(ctx) calls[#calls + 1] = { name = 'start', index = ctx.index } end,
    onEvent = function(ctx, src, ev)
        calls[#calls + 1] = { name = 'onEvent', index = ctx.index, src = src, ev = ev }
        return true
    end,
    onEntityDead = function(ctx, netId)
        calls[#calls + 1] = { name = 'onEntityDead', index = ctx.index, netId = netId }
    end,
    stop = function(ctx) calls[#calls + 1] = { name = 'stop', index = ctx.index } end,
})

H.load('modules/scaling/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/npc/server.lua')
H.load('modules/runs/server.lua')
local Runs = CP.Runs
H.step(0)

local function Mission(extra)
    local m = {
        id = 'fnd_mission',
        label = 'Foundation Mission',
        description = '',
        type = 'patrol',
        departments = {},
        minOfficers = 1,
        maxOfficers = 4,
        difficulty = 1,
        timeLimit = 600,
        startTimeout = 600,
        cooldown = 600,
        locations = { { label = 'L1', start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 } } },
        objectives = {
            { block = 'fnd_block', label = 'One', minSeconds = 0 },
            { block = 'fnd_block', label = 'Two', minSeconds = 0 },
        },
        bonuses = {},
        penalties = {},
        scaling = {},
        items = {},
        source = 'builtin',
    }
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end
local function Officer(src)
    return {
        src = src,
        citizenid = CIDS[src],
        name = 'Officer ' .. src,
        department = 'sast',
        departmentShort = 'SAST',
        job = 'sast',
        rank = 'Trooper',
    }
end
for src = 1, 3 do H.players[src] = { coords = vec3(100.0, 100.0, 30.0) } end
CP.Missions = {
    get = function() return nil end,
    all = function() return {} end,
}

-- A run with the given members, arrived and in progress.
local function StartedRun(members, extra, opts)
    local list = {}
    for _, src in ipairs(members) do list[#list + 1] = Officer(src) end
    local o = {
        mission = Mission(extra),
        locationIndex = 1,
        missionType = 'patrol',
        members = list,
        leaderSrc = members[1],
    }
    for k, v in pairs(opts or {}) do o[k] = v end
    local run, err = Runs.create(o)
    assert(run, tostring(err))
    for _, src in ipairs(members) do Runs.markArrived(run, src) end
    return run
end
local function RowsOf(runId)
    return H.sql('SELECT * FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid', { runId })
end
local function RowOf(runId, cid)
    for _, r in ipairs(RowsOf(runId)) do if r.citizenid == cid then return r end end
    return nil
end
local function N(v) return math.floor(tonumber(v) or -1) end

-- ============================================================================
--                          HOOKS FIRED BY THE ENGINE
-- ============================================================================

local fired = {}
for _, name in ipairs({ 'run:created', 'run:arrived', 'run:inProgress', 'participant:left', 'row:settled', 'run:ended' }) do
    CP.Hooks.on(name, function(...) fired[#fired + 1] = { name = name, args = { ... } } end)
end
local function FiredNames()
    local out = {}
    for _, f in ipairs(fired) do out[#out + 1] = f.name end
    return table.concat(out, ',')
end

-- ============================================================================
--                       5. STATS, ARRESTS AND DECISIONS
-- ============================================================================

do
    fired = {}
    local run = StartedRun({ 1, 2 })
    H.eq(FiredNames(), 'run:created,run:inProgress,run:arrived,run:arrived', 'run:created, run:inProgress, run:arrived')
    H.eq(fired[3].args[3], true, 'the first arrival is marked')
    H.eq(fired[4].args[3], false, 'the second is not')
    local _, suspect = Runs.spawnPed(run,
        { obj = 1, model = 'a_m_y_stbla_01', coords = vec4(101, 101, 30, 0), role = 'suspect' })
    local _, driver = Runs.spawnPed(run,
        { obj = 1, model = 'a_m_y_stbla_01', coords = vec4(102, 101, 30, 0), role = 'driver' })
    H.ok(Runs.noteStat(run, 1, 'citations', 2), 'noteStat personal')
    H.ok(Runs.noteStat(run, nil, 'rescues', 1), 'noteStat shared')
    H.ok(not Runs.noteStat(run, 1, 'arrests', 1), 'arrests go through noteArrest')
    H.ok(not Runs.noteStat(run, 1, 'nonsense', 1), 'unknown stat refused')
    H.ok(Runs.noteArrest(run, 1, suspect), 'noteArrest')
    H.ok(not Runs.noteArrest(run, 1, suspect), 'a repeat is false')
    H.ok(not Runs.noteArrest(run, 2, suspect), 'one person gives one arrest, whoever cuffs again')
    -- decisions
    H.ok(Runs.decide(run, 2, {
        contact = 'A',
        kind = 'person',
        choice = 'arrest',
        verdict = 'best',
        bonusId = 'correct_disposition',
        truthKey = 'warrant',
        bestChoice = 'arrest',
        facts = { 'warrant' },
        netId = suspect,
    }), 'decide best')
    H.ok(Runs.decide(run, 2, {
        contact = 'B',
        kind = 'person',
        choice = 'arrest',
        verdict = 'wrong',
        bonusId = 'wrongful_arrest',
        truthKey = 'clean',
        bestChoice = 'release',
        netId = driver,
    }), 'decide wrong')
    H.ok(Runs.decide(run, 1, { contact = 'C', kind = 'vehicle', choice = 'no_action', verdict = 'ok' }), 'decide ok')
    local p1, p2 = run.participants[1], run.participants[2]
    H.eq(p2.score.correct_disposition, 1, 'the Best award is personal to the decider')
    H.eq(p1.score.correct_disposition, nil, 'and never the partner\'s')
    H.eq(p2.score.wrongful_arrest, 1, 'the penalty is personal too')
    H.eq(p2.stats.arrests, nil, 'a wrongful Arrest never calls noteArrest')
    H.eq(p2.stats.decisions_best, 1, 'decisions_best')
    H.eq(p2.stats.decisions_ok, 1, 'decisions_ok counts Best')
    H.eq(p2.stats.decisions_bad, 1, 'decisions_bad')
    H.eq(p1.stats.decisions_ok, 1, 'decisions_ok counts Acceptable')
    H.eq(#run.decisions, 3, 'the ledger has every decision')
    H.eq(run.decisions[1].by, 'Officer 2', 'with who decided')
    -- a revealed fact: graded, no points
    H.ok(Runs.decide(run, 1, {
        contact = 'D',
        kind = 'vehicle',
        choice = 'impound',
        verdict = 'best',
        bonusId = 'correct_disposition',
        points = 0,
    }), 'decide with points = 0')
    H.eq(p1.score.correct_disposition, nil, 'points = 0 records the grade without an award')
    fired = {}
    Runs.objectiveComplete(run, 1)
    Runs.objectiveComplete(run, 2)
    H.eq(run.state, 'ended', 'completed')
    local r1, r2 = RowOf(run.id, 'FND1'), RowOf(run.id, 'FND2')
    H.eq(N(r1.arrests), 1, 'the arrest reaches the row')
    H.eq(N(r1.citations), 2, 'personal counts reach the row')
    H.eq(N(r1.rescues), 1, 'shared counts reach every row')
    H.eq(N(r2.rescues), 1, 'shared counts reach the partner\'s row')
    H.eq(N(r2.decisions_best), 1, 'decisions_best on the row')
    H.eq(N(r2.decisions_bad), 1, 'decisions_bad on the row')
    H.eq(N(r1.decisions_ok), 2, 'decisions_ok on the row (ok + a points-less best)')
    H.eq(N(r1.location_index), 1, 'location_index')
    local names = FiredNames()
    H.ok(Contains(names, 'row:settled,row:settled,run:ended'), 'row:settled per row, then run:ended: ' .. names)
    local settled = fired[1]
    local rr = settled.args[5]
    H.ok(type(rr.decisions) == 'table' and #rr.decisions == 4, 'RunResult.decisions')
    H.eq(rr.decisions[1].verdict, 'best', 'DecisionEntry verdict')
    H.ok(type(rr.stats) == 'table' and rr.stats.citations ~= nil and rr.stats.lethal == nil,
        'RunResult.stats, lethal private')
    H.eq(rr.missionCall, nil, 'no mission call')
    H.ok(type(rr.progress) == 'table' and rr.progress.level and rr.progress.level.n,
        'RunResult.progress filled by CP.Scoring')
    H.ok(type(rr.items) == 'table', 'RunResult.items for row:settled listeners')
end

do
    -- 'critical' fails the run for everyone with its key
    local run = StartedRun({ 1, 2 })
    Runs.decide(run, 1,
        { contact = 'A', kind = 'person', choice = 'release', verdict = 'critical', failKey = 'reason.known_error' })
    H.eq(run.state, 'ended', 'a critical decision ends the run')
    H.eq(run.endReason, 'mission_failed', 'as mission_failed')
    H.eq(run.failReason, 'reason.known_error', 'with its key')
    H.eq(RowOf(run.id, 'FND2').state, 'failed', 'for everyone')
end

do
    -- the debrief: every fact the decider had (text and time), and the people's demeanour and what they did,
    -- only in the result of a run that ended; Config.Decisions.debrief = false keeps them off the officer's card
    local run = StartedRun({ 1, 2, 3 })
    local _, a = Runs.spawnPed(run,
        { obj = 1, model = 'a_m_y_stbla_01', coords = vec4(103, 101, 30, 0), role = 'suspect' })
    H.ok(Runs.notePerson(run, a, { label = 'A', demeanour = 'nervous' }), 'notePerson')
    Runs.notePerson(run, a, { did = 'ran' })
    Runs.notePerson(run, a, { did = 'ran' })
    Runs.notePerson(run, a, { did = 'nonsense' })
    Runs.notePerson(run, a, { did = 'surrendered' })
    Runs.notePerson(run, 9999, { label = 'B', demeanour = 'compliant' })
    H.ok(not Runs.notePerson(run, 0, { label = 'C' }), 'a bad net id is refused')
    Runs.decide(run, 1, {
        contact = 'A',
        kind = 'person',
        choice = 'arrest',
        verdict = 'best',
        truthKey = 'warrant',
        bestChoice = 'arrest',
        facts = { 'warrant' },
        factLog = { { key = 'warrant', text = 'Active warrant', at = run.startedAt + 42 } },
        netId = a,
    })
    H.eq(run.decisions[1].factLog[1].text, 'Active warrant', 'the fact log keeps each fact\'s text')
    H.eq(run.decisions[1].factLog[1].atS, 42, 'and when it reached the decider (seconds into the run)')
    fired = {}
    Runs.removeParticipant(run, 3, 'quit')
    local early = nil
    for _, f in ipairs(fired) do if f.name == 'row:settled' then early = f.args[5] end end
    H.ok(early ~= nil, 'the leaver\'s row is settled')
    H.eq(early and early.people, nil, 'a participant who leaves before the end never gets the people')
    fired = {}
    H.reset()
    Config.Decisions.debrief = false
    Runs.objectiveComplete(run, 1)
    Runs.objectiveComplete(run, 2)
    Config.Decisions.debrief = true
    H.eq(run.state, 'ended', 'completed')
    local rr = nil
    for _, f in ipairs(fired) do if f.name == 'row:settled' then rr = f.args[5] end end
    H.eq(rr and rr.people and #rr.people, 2, 'RunResult.people once the run has ended')
    H.eq(rr.people[1].contact, 'A', 'in the order they were noted')
    H.eq(rr.people[1].demeanour, 'nervous', 'with the demeanour')
    H.eq(table.concat(rr.people[1].did, ','), 'ran,surrendered', 'and what they did, each once, known ones only')
    H.eq(#rr.people[2].did, 0, 'nothing done: complied')
    local row = RowOf(run.id, 'FND1')
    local bd = cjson.decode(row.breakdown)
    H.eq(bd.people and #bd.people, 2, 'the stored breakdown keeps the people (disputes)')
    H.eq(bd.decisions and #bd.decisions, 1, 'and the ledger')
    local sent = nil
    for _, e in ipairs(H.findEvents('crimson-police:client:runEnded')) do
        if e.target == 1 then sent = e.args[4] end
    end
    H.ok(sent ~= nil, 'the result card is sent')
    H.eq(sent and #sent.decisions, 0, 'debrief = false: the officer\'s card has no ledger')
    H.eq(sent and sent.people, nil, 'and no people')
end

do
    -- medal: 1 gold, 2 silver, 3 bronze from the medal awards (the best one), NULL without one
    local run = StartedRun({ 1, 2, 3 })
    Runs.award(run, 'medal_bronze', { src = 1 })
    Runs.award(run, 'medal_silver', { src = 1 })
    Runs.award(run, 'medal_bronze', { src = 2 })
    Runs.objectiveComplete(run, 1)
    Runs.objectiveComplete(run, 2)
    H.eq(N(RowOf(run.id, 'FND1').medal), 2, 'the best medal of the row: silver')
    H.eq(N(RowOf(run.id, 'FND2').medal), 3, 'bronze')
    H.eq(RowOf(run.id, 'FND3').medal, nil, 'no medal: NULL')
    local shared = StartedRun({ 1 })
    Runs.award(shared, 'medal_gold')
    Runs.objectiveComplete(shared, 1)
    Runs.objectiveComplete(shared, 2)
    H.eq(N(RowOf(shared.id, 'FND1').medal), 1, 'a shared gold')
end

-- ============================================================================
--                                 6. ADOPTION
-- ============================================================================

do
    calls = {}
    local run = StartedRun({ 1 })
    local _, car = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(110, 110, 30, 0), role = 'car' })
    local _, pedA = Runs.spawnPed(run,
        { obj = 1, model = 'a_m_y_stbla_01', coords = vec4(100.5, 100.0, 30, 0), role = 'suspect' })
    local _, pedB = Runs.spawnPed(run,
        { obj = 1, model = 'a_m_y_stbla_01', coords = vec4(112, 110, 30, 0), role = 'suspect' })
    Runs.objectiveComplete(run, 1)   -- the pursuit is done; its entities stay
    H.eq(run.objectiveIndex, 2, 'objective 2 is current')
    H.reset()
    H.eq(Runs.adoptMany(run, { car, pedA, pedB }, 2), 3, 'adoptMany moves a car and its occupants together')
    H.eq(run.entities[car].obj, 2, 'the car belongs to objective 2')
    H.eq(Runs.ownerOf(run, pedA), 2, 'ownerOf')
    local ops = H.findEvents('crimson-police:client:objective')
    H.eq(Count(ops, function(e) return e.args[3].op == 'adopt' and e.target == run.host end), 3,
        'the host gets the adopt op')
    H.eq(ops[1].args[3].from, 1, 'with the objective it came from')
    local bag = bags[run.entities[pedA].entity].cp
    H.eq(bag and bag.obj, 2, 'the replicated bag names the adopter')
    -- a death goes to the adopter, never to the finished objective
    Runs.entityDied(run, pedB, nil)
    H.eq(#CallsOf('onEntityDead', 2), 1, 'onEntityDead reaches the adopter')
    H.eq(#CallsOf('onEntityDead', 1), 0, 'the old objective gets nothing')
    -- CP.Npc's cuff: the real state machine dispatches to the record's objective
    CP.Npc.setState(run, pedA, 'surrendered')
    CP.Npc.enableCuff(run, pedA, { duration = 500, maxDistance = 3.0 })
    H.players[1].coords = vec3(100.0, 100.0, 30.0)
    H.fire('crimson-police:server:npcCuff', 1, run.id, pedA)
    local cuffs = Count(CallsOf('onEvent', 2), function(c) return c.ev.type == 'cuffed' end)
    H.eq(cuffs, 1, 'a cuff reaches the adopting objective')
    H.eq(Count(CallsOf('onEvent', 1), function(c) return c.ev.type == 'cuffed' end), 0, 'and never the old one')
    -- custody events through entityEvent
    Runs.entityEvent(run, car, { type = 'impounded', netId = car })
    H.eq(Count(CallsOf('onEvent', 2), function(c) return c.ev.type == 'impounded' end), 1,
        'custody events go to the owner')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                      7. HIDDEN SPAWNS, ARM AND THE CAPS
-- ============================================================================

do
    local run = StartedRun({ 1 })
    weapons = {}
    local ped, net = Runs.spawnPed(run, {
        obj = 1,
        model = 'a_m_y_stbla_01',
        coords = vec4(105, 100, 30, 0),
        role = 'subject',
        hidden = true,
        armed = true,
        weapon = 'WEAPON_PISTOL',
        accuracy = 40,
        armour = 30,
    })
    local bag = bags[ped].cp
    H.eq(bag.armed, false, 'a hidden contact spawns with armed = false in its bag')
    H.eq(bag.cfg.weapon, nil, 'no weapon in the bag')
    H.eq(bag.cfg.accuracy, nil, 'no accuracy in the bag')
    H.eq(bag.cfg.armour, nil, 'no armour in the bag')
    H.eq(#weapons, 0, 'no GiveWeaponToPed at spawn')
    H.eq(armour[ped], nil, 'no armour at spawn')
    H.eq(run.entities[net].armedTruth, true, 'the truth stays on the server')
    Config.Limits.maxArmedAlive = 1
    H.ok(not Runs.canSpawn(run, 1, true), 'armedTruth counts toward maxArmedAlive')
    H.eq(Runs.spawnPed(run, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0), armed = true }), nil, 'the cap holds')
    Config.Limits.maxArmedAlive = 25
    H.ok(Runs.arm(run, net), 'arm()')
    H.eq(#weapons, 1, 'the weapon is given at the draw')
    H.eq(weapons[1].w, joaat('WEAPON_PISTOL'), 'the right weapon')
    H.eq(armour[ped], 30, 'armour at the draw')
    H.eq(bags[ped].cp.armed, true, 'the bag says armed now')
    H.eq(bags[ped].cp.cfg.weapon, 'WEAPON_PISTOL', 'with the combat cfg')
    H.ok(Runs.arm(run, net), 'arm() again')
    H.eq(#weapons, 1, 'the weapon is given once')
    local _, clean = Runs.spawnPed(run, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0), hidden = true })
    H.ok(not Runs.arm(run, clean), 'an unarmed truth has nothing to draw')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                                  8. PLATES
-- ============================================================================

do
    local stub, asked = H.plateOwnedStub({})
    CP.Qbx.plateOwned = stub
    local run = StartedRun({ 1 })
    local seen = {}
    for i = 1, 6 do
        local h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(100 + i * 5, 100, 30, 0) })
        local plate = Ent(h).plate
        seen[#seen + 1] = plate
        H.ok(Runs.isMissionPlate(plate), 'plate in the reserved pattern: ' .. tostring(plate))
        H.eq(#plate, Config.Custody.plates.length, 'plate length')
        H.eq(plate:sub(1, #Config.Custody.plates.prefix), Config.Custody.plates.prefix, 'plate prefix')
    end
    H.eq(#asked, 6, 'every plate is checked against player_vehicles')
    -- an owned plate is rerolled
    local owned = {}
    local rolled = {}
    CP.Qbx.plateOwned = function(plate)
        rolled[#rolled + 1] = plate
        if #rolled == 1 then owned[plate] = true return true end
        return false
    end
    local h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(150, 100, 30, 0) })
    H.eq(#rolled, 2, 'an owned plate is rerolled')
    H.ok(Ent(h).plate ~= rolled[1] and Ent(h).plate == rolled[2], 'the car carries the second roll')
    -- a lookup error: the pattern alone
    local failStub, failAsked = H.plateOwnedStub(nil, true)
    CP.Qbx.plateOwned = failStub
    h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(160, 100, 30, 0) })
    H.eq(#failAsked, 1, 'asked once')
    H.ok(Runs.isMissionPlate(Ent(h).plate), 'on a stub error the pattern alone is used')
    -- a plate the mission asks for (in the pattern) is checked too, and rerolled when a player owns it
    local wanted = Config.Custody.plates.prefix
        .. ('7'):rep(Config.Custody.plates.length - #Config.Custody.plates.prefix)
    local ownedStub, ownedAsked = H.plateOwnedStub({ [wanted] = true })
    CP.Qbx.plateOwned = ownedStub
    h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(170, 100, 30, 0), plate = wanted })
    H.eq(ownedAsked[1], wanted, 'the requested plate is looked up')
    H.ok(Ent(h).plate ~= wanted and Runs.isMissionPlate(Ent(h).plate), 'an owned requested plate is rerolled')
    CP.Qbx.plateOwned = H.plateOwnedStub({})
    h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(180, 100, 30, 0), plate = wanted })
    H.eq(Ent(h).plate, wanted, 'a free requested plate in the pattern is kept')
    CP.Qbx.plateOwned = nil
    Runs.endRun(run, 'completed', 'completed')
    -- plates never come from the run seed (a client sees every plate and could work the seed out, then replay
    -- the hidden server rolls): two runs with the same seed get different plates
    local a, b = StartedRun({ 1 }), StartedRun({ 2 })
    a.seed, b.seed = 424242, 424242
    local pa, pb = {}, {}
    for i = 1, 3 do
        pa[i] = Ent(Runs.spawnVehicle(a, { obj = 1, model = 'sultan', coords = vec4(200 + i * 5, 100, 30, 0) })).plate
        pb[i] = Ent(Runs.spawnVehicle(b, { obj = 1, model = 'sultan', coords = vec4(300 + i * 5, 100, 30, 0) })).plate
    end
    H.ok(table.concat(pa, ',') ~= table.concat(pb, ','), 'plates are independent of the run seed')
    Runs.endRun(a, 'completed', 'completed')
    Runs.endRun(b, 'completed', 'completed')
end

-- ============================================================================
--                                9. HELD BODIES
-- ============================================================================

do
    local run = StartedRun({ 1 })
    Runs.holdBodies(run, { roles = { 'hostile' }, max = 2 })
    local nets = {}
    for i = 1, 3 do
        local _, n = Runs.spawnPed(run, { obj = 1, model = 'x', coords = vec4(100 + i, 100, 30, 0), role = 'hostile' })
        nets[i] = n
    end
    local _, bystander = Runs.spawnPed(run, { obj = 1, model = 'x', coords = vec4(90, 100, 30, 0), role = 'hostage' })
    Runs.entityDied(run, nets[1], nil)
    Runs.entityDied(run, nets[2], nil)
    Runs.entityDied(run, bystander, nil)
    H.eq(#Runs.heldBodies(run), 2, 'two bodies held')
    Runs.entityDied(run, nets[3], nil)
    local held = Runs.heldBodies(run)
    H.eq(#held, 2, 'FIFO: never more than max')
    H.eq(held[1].netId, nets[2], 'the oldest was released')
    H.eq(run.entities[nets[1]], nil, 'and deleted')
    H.time = H.time + 60
    H.advance(1500)
    H.ok(run.entities[nets[2]] ~= nil, 'the corpse cleanup skips held bodies')
    H.eq(run.entities[bystander], nil, 'a body of another role is cleaned up as before')
    local handle = run.entities[nets[2]].entity
    H.ok(Runs.releaseBody(run, nets[2]), 'releaseBody')
    H.ok(deleted[handle], 'releaseBody deletes')
    local last = run.entities[nets[3]].entity
    local before = Runs.remaining(run)
    H.ok(Runs.pauseFastClock(run), 'pauseFastClock')
    H.ok(math.abs(Runs.remaining(run) - before - 80) < 1.5, 'the time limit grows by 60 s + 20 s per held body')
    H.ok(not Runs.pauseFastClock(run), 'once per run')
    Runs.endRun(run, 'completed', 'completed')
    H.ok(deleted[last], 'held bodies are deleted at the run end')
end

-- ============================================================================
--                        10. VANISHED VEHICLES AND /imp
-- ============================================================================

do
    -- a participant's recorded removal: removed, never wrecked, the objective fails, the run is flagged
    calls = {}
    log = {}
    local run = StartedRun({ 1, 2 })
    local h, car = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(110, 100, 30, 0), role = 'car' })
    H.advance(1100)   -- one server sample while it exists
    Runs.noteExternalRemoval(car, 1, 'sc_impound', 4.0)
    Ent(h).exists = false
    H.advance(2500)
    H.eq(#CallsOf('onEntityDead'), 0, 'a removed car is never counted as wrecked or stopped')
    local removed = CallsOf('onEvent', 1)
    H.eq(removed[1] and removed[1].ev.type, 'removed', 'the block gets { type = removed }')
    H.eq(removed[1] and removed[1].ev.src, 1, 'with the sender')
    H.eq(removed[1] and removed[1].ev.via, 'sc_impound', 'and how')
    H.eq(Logged('flag')[1] and Logged('flag')[1].reason, 'sc_impound', 'the run is flagged sc_impound')
    H.eq(run.state, 'ended', 'the run ends')
    H.eq(run.failReason, 'reason.vehicle_removed', 'the objective fails: vehicle removed')
    H.eq(run.stats.vehiclesWrecked, nil, 'never a wreck')
end

do
    -- a non-participant's removal: not counted, no cooldown for anyone
    calls = {}
    local run = StartedRun({ 1, 2 }, { id = 'fnd_removed', cooldown = 900 })
    local h, car = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(110, 100, 30, 0), role = 'car' })
    H.advance(1100)
    Runs.noteExternalRemoval(car, 3, 'sc_impound', 12.0)
    local audits = {}
    CP.Admin = {
        audit = function(actor, _, _, action, ...) audits[#audits + 1] = { actor = actor, action = action } end,
    }
    Ent(h).exists = false
    H.advance(2500)
    CP.Admin = nil
    H.eq(audits[1] and audits[1].actor, 3, 'the sender is audited')
    H.eq(Count(audits, function(a) return a.action == 'vehicleRemoved' end), 1, 'once')
    H.eq(run.state, 'ended', 'the run ends')
    local r1, r2 = RowOf(run.id, 'FND1'), RowOf(run.id, 'FND2')
    H.eq(r1.end_reason, 'vehicle_removed_external', 'end reason vehicle_removed_external')
    H.eq(r1.state, 'abandoned', 'not counted')
    H.eq(N(r1.final_points), 0, 'no points')
    H.eq(N(r2.cash_paid), 0, 'no cash')
    local cd = Runs.cooldowns('FND1')
    H.eq(cd.types.patrol, nil, 'no type cooldown')
    H.eq(cd.missions.fnd_removed, nil, 'no mission cooldown')
    H.eq(#CallsOf('onEntityDead'), 0, 'never wrecked')
end

do
    -- nothing recorded (another script's delete): as a non-participant's
    local run = StartedRun({ 1 })
    local h = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(110, 100, 30, 0), role = 'car' })
    H.advance(1100)
    Ent(h).exists = false
    H.advance(2500)
    H.eq(run.endReason, 'vehicle_removed_external', 'the run ends as not counted')
    H.eq(RowOf(run.id, 'FND1').end_reason, 'vehicle_removed_external', 'unrecorded: not counted')
end

do
    -- a last sample at 0 health: still a wreck
    calls = {}
    local run = StartedRun({ 1 })
    local h, car = Runs.spawnVehicle(run, { obj = 1, model = 'sultan', coords = vec4(110, 100, 30, 0), role = 'car' })
    Ent(h).body = 0.0
    H.advance(1100)
    Ent(h).exists = false
    H.advance(2500)
    H.eq(#CallsOf('onEntityDead'), 1, 'a car whose last sample was at 0 health counts as wrecked')
    H.eq(CallsOf('onEntityDead')[1].netId, car, 'that car')
    H.eq(run.state, 'in_progress', 'and the run goes on')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- the Stolen Vehicle Takedown / Street Race Bust exploit (F6e): the chased car deleted mid-chase by a
    -- participant's /imp never stops the chase, it fails the objective and flags the run
    calls = {}
    log = {}
    local run = StartedRun({ 1 })
    local h, car = Runs.spawnVehicle(run,
        { obj = 1, model = 'sultan', coords = vec4(110, 100, 30, 0), role = 'suspect' })
    Ent(h):set({ velocity = vec3(20.0, 0.0, 0.0) })
    H.advance(3000)
    H.ok(Ent(h).coords.x > 150, 'the car is fleeing (H.entity moves it)')
    Runs.noteExternalRemoval(car, 1, 'sc_impound', 30.0)
    Ent(h).exists = false
    H.advance(2500)
    H.eq(#CallsOf('onEntityDead'), 0, 'the chase never counts the car as stopped')
    H.eq(run.failReason, 'reason.vehicle_removed', 'the objective fails')
    H.eq(Logged('flag')[1] and Logged('flag')[1].reason, 'sc_impound', 'flagged for review')
end

-- ============================================================================
--                            11. COMPLETIONS TODAY
-- ============================================================================

do
    H.sql('DELETE FROM cp_mission_runs')
    -- three hours after the daily reset, so the counts never depend on when the spec runs
    local savedTime = H.time
    H.time = CP.Schedule.dayStart(savedTime) + 3 * 3600
    local function Insert(cid, typ, state, opId, ago)
        H.sql([[INSERT INTO cp_mission_runs (run_uuid, operation_id, mission_type, mission_id, citizenid, department,
            participants, departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points,
            final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, flagged, created_at)
            VALUES (?, ?, ?, 'm', ?, 'sast', 1, 1, 'standard', ?, 'completed', 60, 0, 0, 60, 0, 1.00, 0, 'none', 60, 0,
            FROM_UNIXTIME(?))]], { CP.U.uuid(), opId, typ, cid, state, os.time() - ago })
    end
    Insert('DAY1', 'patrol', 'completed', nil, 60)
    Insert('DAY1', 'tactical', 'completed', nil, 120)
    Insert('DAY1', 'patrol', 'failed', nil, 60)
    Insert('DAY1', 'manual_award', 'completed', nil, 60)
    Insert('DAY1', 'goal', 'completed', nil, 60)
    Insert('DAY1', 'tactical', 'completed', 5, 60)
    Insert('DAY1', 'patrol', 'completed', nil, 3 * 86400)
    Insert('DAY1', 'patrol', 'completed', nil, 4 * 3600)   -- yesterday, one hour before the reset
    H.eq(Runs.completionsToday('DAY1'), 2, 'completed runs since the daily reset (no awards, goals, operations)')
    H.eq(Runs.completionsToday('DAY1', 'patrol'), 1, 'per type')
    local cached = Runs.completionsToday('DAY1')
    Insert('DAY1', 'patrol', 'completed', nil, 10)
    H.eq(Runs.completionsToday('DAY1'), cached, 'cached for 10 s')
    -- a completion clears the officer's cache at once
    local before = Runs.completionsToday('FND1')
    local run = StartedRun({ 1 })
    Runs.objectiveComplete(run, 1)
    Runs.objectiveComplete(run, 2)
    H.eq(Runs.completionsToday('FND1'), before + 1, 'the cache is cleared on completion')
    H.sql('DELETE FROM cp_mission_runs')
    H.time = savedTime
end

-- ============================================================================
--                     12. QUIET PATROL AND RAPID RESPONSE
-- ============================================================================

do
    for _, f in ipairs({ 'modules/runs/server.lua', 'modules/runs/client.lua', 'modules/scoring/server.lua' }) do
        H.ok(not Contains(ReadFile(H.root .. f), 'LIGHTS_MISSIONS'), f .. ' has no LIGHTS_MISSIONS table')
    end
    local defs = {}
    for _, id in ipairs({ 'beat_patrol', 'business_check', 'gang_shootout' }) do
        defs[id] = ReadFile(H.root .. 'missions/builtin/' .. id .. '.lua')
    end
    H.ok(defs.beat_patrol:find('quietPatrol%s*=%s*true') ~= nil, 'Beat Patrol sets quietPatrol')
    H.ok(defs.business_check:find('quietPatrol%s*=%s*true') ~= nil, 'Business Check sets quietPatrol')
    H.ok(defs.gang_shootout:find('quietPatrol') == nil, 'other missions never do')
    -- the telemetry: free before the run is in progress, -10 after
    local run = Runs.create({
        mission = Mission({ quietPatrol = true }),
        locationIndex = 1,
        missionType = 'patrol',
        members = { Officer(1), Officer(2) },
        leaderSrc = 1,
    })
    H.players[1].vehicle = 7
    H.fire('crimson-police:server:telemetry', 1, run.id, 'lights_siren', {})
    H.eq(run.participants[1].score.lights_siren, nil, 'lights during the drive to the start cost nothing')
    Runs.markArrived(run, 2)
    H.fire('crimson-police:server:telemetry', 1, run.id, 'lights_siren', {})
    H.eq(run.participants[1].score.lights_siren, 1, 'after arrival they cost')
    H.players[1].vehicle = nil
    local other = StartedRun({ 3 })
    H.players[3].vehicle = 7
    H.fire('crimson-police:server:telemetry', 3, other.id, 'lights_siren', {})
    H.eq(other.participants[3].score.lights_siren, nil, 'a mission without quietPatrol never counts lights')
    H.players[3].vehicle = nil
    Runs.endRun(other, 'completed', 'completed')
    Runs.endRun(run, 'completed', 'completed')
    local P = 60
    local fake = {
        mission = Mission({ quietPatrol = true }),
        missionId = 'fnd_mission',
        pointsBase = P,
        timeLimit = 600,
        stats = {},
        score = { shared = {}, values = {}, kinds = {} },
        participants = {},
        flags = {},
    }
    local fp = { src = 1, citizenid = 'QP1', score = { lights_siren = 1 }, department = 'sast', status = 'active' }
    local b = CP.Scoring.compute(fake, fp, 'completed', { durationS = 590 })
    local line
    for _, l in ipairs(b.penalties) do if l.id == 'lights_siren' then line = l end end
    H.eq(line and line.points, -10, 'quietPatrol: -10 in the breakdown')
    fake.mission = Mission()
    b = CP.Scoring.compute(fake, fp, 'completed', { durationS = 590 })
    line = nil
    for _, l in ipairs(b.penalties) do if l.id == 'lights_siren' then line = l end end
    H.eq(line, nil, 'no penalty without quietPatrol')
end

do
    -- rapid response: a server-posted call reached within its target
    local call = { id = 42, code = 'MC-0042', area = 'south_ls', targetS = 120 }
    local run = Runs.create({
        mission = Mission(),
        locationIndex = 1,
        missionType = 'patrol',
        members = { Officer(1), Officer(2) },
        leaderSrc = 1,
        missionCall = call,
    })
    H.time = H.time + 60
    Runs.markArrived(run, 1)
    H.time = H.time + 100
    Runs.markArrived(run, 2)
    H.eq(run.participants[1].score.rapid_response, 1, 'within the target: rapid_response, personal')
    H.eq(run.participants[2].score.rapid_response, nil, 'late: none')
    local view = Runs.view(run, 1)
    H.eq(view.missionCall and view.missionCall.code, 'MC-0042', 'view.missionCall')
    H.eq(view.missionCall and view.missionCall.arrivedS, 60, 'arrivedS')
    local P = run.pointsBase
    local b1 = CP.Scoring.compute(run, run.participants[1], 'completed', { durationS = 590, departments = 1 })
    local b2 = CP.Scoring.compute(run, run.participants[2], 'completed', { durationS = 590, departments = 1 })
    local rapid
    for _, l in ipairs(b1.bonuses) do if l.id == 'rapid_response' then rapid = l end end
    H.eq(rapid and rapid.points, CP.U.round(0.10 * P), '+10% of P')
    H.ok(b1.final <= math.floor(Config.Scoring.scoreCap * P), 'inside the 2P cap')
    local c1 = { CP.Cash.compute(run, run.participants[1]) }
    local c2 = { CP.Cash.compute(run, run.participants[2]) }
    H.eq(c1[1], c2[1], 'cash identical with and without it')
    H.ok(b1.final >= b2.final, 'points only')
    Runs.objectiveComplete(run, 1)
    Runs.objectiveComplete(run, 2)
    local row = RowOf(run.id, 'FND1')
    H.eq(N(row.mission_call_id), 42, 'mission_call_id on the row')
    H.eq(N(row.response_s), 60, 'response_s on the row')
    -- staff calls never earn it, nor other runs
    local staff = Runs.create({
        mission = Mission(),
        locationIndex = 1,
        missionType = 'patrol',
        members = { Officer(1) },
        leaderSrc = 1,
        missionCall = { id = 43, code = 'MC-0043', targetS = 999, staff = true },
    })
    Runs.markArrived(staff, 1)
    H.eq(staff.participants[1].score.rapid_response, nil, 'never on a paged or staff call')
    Runs.endRun(staff, 'completed', 'completed')
    local plain = StartedRun({ 1 })
    H.eq(plain.participants[1].score.rapid_response, nil, 'never on other runs')
    Runs.endRun(plain, 'completed', 'completed')
end

-- ============================================================================
--                      13. STATS FROM COMPLETED ROWS ONLY
-- ============================================================================

do
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_badges')
    Config.Badges.byTheBook = 5
    local function Insert(state, best, arrests)
        H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, flagged, arrests, impounds, decisions_best, created_at)
            VALUES (?, 'patrol', 'm', 'STAT1', 'sast', 1, 1, 'standard', ?, 'completed', 60, 0, 0, 60, 0, 1.00, 0,
            'none', 60, 0, ?, ?, ?, NOW())]], { CP.U.uuid(), state, arrests, arrests, best })
    end
    Insert('abandoned', 9, 4)
    Insert('failed', 9, 4)
    CP.Scoring._checkBadges('STAT1', false)
    H.eq(#H.sql('SELECT badge_id FROM cp_badges WHERE citizenid = \'STAT1\''), 0,
        'abandoned and failed rows never count toward a badge')
    Insert('completed', 5, 1)
    CP.Scoring._checkBadges('STAT1', false)
    local b = H.sql('SELECT badge_id FROM cp_badges WHERE citizenid = \'STAT1\'')
    H.eq(b[1] and b[1].badge_id, 'by_the_book', 'By the Book from completed rows (decisions_best)')
    Config.Badges.byTheBook = 100
    H.load('modules/goals/server.lua')
    local n = CP.Goals._progress({ id = 'arrests_x', stat = 'arrests', count = 2 }, 'STAT1', os.time() - 3600)
    H.eq(n, 1, 'a stat goal sums completed rows only')
    local imp = CP.Goals._progress({ id = 'imp_x', stat = 'impounds', count = 2 }, 'STAT1', os.time() - 3600)
    H.eq(imp, 1, 'impounds too')
    local bad = CP.Goals._progress({ id = 'bad', stat = 'lethal', count = 1 }, 'STAT1', os.time() - 3600)
    H.eq(bad, 0, 'a column that is not a stat counts nothing')
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_badges')
end

do
    -- goal:completed names the period itself (kind and period key), so a goal met again next day or next week
    -- is a new completion for its listeners (item rewards key on the goal id and the period)
    local savedGoals, savedTime = Config.Goals, H.time
    Config.Goals = { dailyPoints = 50, weeklyPoints = 0, daily = { { id = 'fnd_any_1', count = 1 } }, weekly = {} }
    local seen = {}
    local id = CP.Hooks.on('goal:completed', function(cid, goalId, period)
        seen[#seen + 1] = { cid, goalId, period }
    end)
    local function Completed()
        H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, flagged, created_at)
            VALUES (?, 'patrol', 'm', 'GOAL1', 'sast', 1, 1, 'standard', 'completed', 'completed', 60, 0, 0, 60, 0,
            1.00, 0, 'none', 60, 0, FROM_UNIXTIME(?))]], { CP.U.uuid(), os.time() })
        CP.Goals.onRunCompleted('GOAL1')
    end
    H.time = CP.Schedule.dayStart(savedTime) + 7200
    Completed()
    Completed()
    H.eq(#seen, 1, 'goal:completed once per period')
    H.eq(seen[1] and seen[1][2], 'fnd_any_1', 'with the goal id')
    local day1 = seen[1] and seen[1][3]
    H.ok(type(day1) == 'string' and Contains(day1, 'daily') and Contains(day1, os.date('%Y-%m-%d', H.time)),
        'the period names the kind and the day: ' .. tostring(day1))
    H.time = H.time + 86400
    Completed()
    H.eq(#seen, 2, 'the next day completes it again')
    H.ok(seen[2] and seen[2][3] ~= day1, 'as a different period')
    CP.Hooks.off(id)
    Config.Goals, H.time = savedGoals, savedTime
    H.sql('DELETE FROM cp_mission_runs')
end

-- ============================================================================
--                          14. XP CURVE AND LEVEL-UPS
-- ============================================================================

do
    local S = CP.Scoring
    H.eq(S.levelXp(1), 0, 'level 1 at 0')
    H.eq(S.levelXp(2), 100, 'level 2 at 100')
    H.eq(S.levelXp(10), 1198, 'level 10 at 1,198')
    H.ok(math.abs(S.levelXp(50) - 37900) <= 1, 'level 50 at 37,900 (±1): ' .. S.levelXp(50))
    H.eq(S.levelOf(99), 1, 'Lv 1 below 100')
    H.eq(S.levelOf(100), 2, 'Lv 2 at 100')
    local top = S.levelXp(50)
    H.eq(S.xpLevel(top + 9999).prestige, 0, 'no star before 10,000 XP past 50')
    H.eq(S.xpLevel(top + 10000).prestige, 1, 'a prestige star every 10,000 XP after 50')
    H.eq(S.xpLevel(top + 25000).prestige, 2, 'two stars')
    H.eq(S.xpLevel(top + 25000).n, 50, 'still Lv 50')
    for _, band in ipairs(Config.XPLevels) do
        local at = S.levelXp(band.level)
        H.eq(S.xpLevel(at).label, band.label, 'Lv ' .. band.level .. ' starts the ' .. band.label .. ' band')
        if band.level > 1 then
            H.ok(S.xpLevel(at - 1).label ~= band.label, 'one XP less is the band before')
        end
    end
    -- xp:levelUp and the one toast, once per level-up
    local ups = {}
    CP.Hooks.on('xp:levelUp', function(cid, src, old, new) ups[#ups + 1] = { cid, src, old, new } end)
    H.sql('DELETE FROM cp_officers WHERE citizenid = \'FND1\'')
    H.sql('INSERT INTO cp_officers (citizenid, xp) VALUES (\'FND1\', 90)')
    notes = {}
    local function Count1(delta, id)
        H.sql(
            [[INSERT INTO cp_mission_runs (id, run_uuid, mission_type, mission_id, citizenid, department, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, flagged, created_at) VALUES (?, ?, 'patrol', 'm', 'FND1',
            'sast', 1, 1, 'standard', 'completed', 'completed', 60, 0, 0, ?, 0, 1.00, 0, 'none', 60, 0, NOW())]],
            { id, CP.U.uuid(), delta })
        S.onRowCounted('FND1', { id = id, state = 'completed', mission_type = 'patrol', final_points = delta })
    end
    Count1(5, 9101)
    H.eq(#ups, 0, 'no level-up inside a level')
    Count1(10, 9102)
    H.eq(#ups, 1, 'xp:levelUp once')
    H.eq(ups[1][3], 1, 'from Lv 1')
    H.eq(ups[1][4], 2, 'to Lv 2')
    H.eq(ups[1][2], 1, 'with the player\'s src')
    local toasts = Count(notes, function(n) return n.key == 'scoring.level_up' end)
    H.eq(toasts, 1, 'one level-up toast')
    Count1(3, 9103)
    H.eq(#ups, 1, 'no second toast or hook for the same level')
    local other = Count(notes, function(n) return n.key ~= 'scoring.level_up' and Contains(n.key, 'level') end)
    H.eq(other, 0, 'no other level-up toast exists')
    -- RunResult.progress: a counted row's XP is already in; a flagged row's is pending and levels nobody up yet
    local xpNow = 108
    local counted = S.progressFor('FND1', 18, false)
    H.eq(counted.xpBefore, xpNow - 18, 'xpBefore of a counted row')
    H.eq(counted.xpAfter, xpNow, 'xpAfter of a counted row')
    H.ok(counted.levelUp, 'the counted row crossed Lv 2: level-up banner')
    local pending = S.progressFor('FND1', 150, true)
    H.ok(pending.pending, 'a flagged row is pending review')
    H.eq(pending.xpBefore, xpNow, 'pending: nothing added yet')
    H.eq(pending.levelUp, false, 'pending XP shows no level-up banner (no level was reached yet)')
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_officers')
end

-- ============================================================================
--                              15. NPC DIFFICULTY
-- ============================================================================

do
    local cfg = Config.NpcDifficulty
    local S = CP.Scaling
    cfg.preset = 'normal'
    local accN, armN = S.combat(25, 0, 'standard')
    cfg.preset = 'hard'
    local accH, armH = S.combat(25, 0, 'standard')
    H.eq(accH, accN + 8, 'hard raises accuracy in combat()')
    H.eq(armH, armN + 15, 'hard raises armour')
    H.eq(S.feel().healthMult, 1.15, 'feel() health multiplier')
    cfg.preset = 'easy'
    H.eq(select(1, S.combat(25, 0, 'standard')), accN - 8, 'easy lowers accuracy')
    cfg.preset = 'custom'
    cfg.custom.accuracyAdd = 3
    H.eq(select(1, S.combat(25, 0, 'standard')), accN + 3, 'custom')
    cfg.custom.accuracyAdd = 0
    cfg.preset = 'nonsense'
    H.eq(select(1, S.combat(25, 0, 'standard')), accN, 'an unknown preset is normal')
    -- points and cash of a run are identical under every preset
    local results = {}
    for _, preset in ipairs({ 'easy', 'normal', 'hard' }) do
        cfg.preset = preset
        local run = StartedRun({ 1 })
        local pts = CP.Scoring.compute(run, run.participants[1], 'completed', { durationS = 590, departments = 1 })
        results[#results + 1] = { pts.final, run.cashBase, run.pointsBase }
        Runs.endRun(run, 'failed', 'mission_failed')
    end
    H.ok(results[1][1] == results[2][1] and results[2][1] == results[3][1], 'points identical under every preset')
    H.ok(results[1][2] == results[3][2] and results[1][3] == results[3][3], 'cash and P identical under every preset')
    cfg.preset = 'normal'
end

-- ============================================================================
--                    16. THE VIEW AND TOKENS TO THE CLIENTS
-- ============================================================================

do
    local run = StartedRun({ 1, 2 })
    H.reset()
    Runs.hud(run, { message = { text = CP.Lt('scoring.level_n', { n = 12 }), kind = 'info' } })
    local ev = H.findEvents('crimson-police:client:hud')
    H.eq(#ev, 2, 'a HUD patch reaches each participant')
    local text = ev[1].args[2].message.text
    H.ok(type(text) == 'string' and text:sub(1, 1) == '\30', 'as a token')
    H.eq(CP.Locale.resolve(text), 'Lv 12', 'which each client resolves')
    local ctx = Runs.ctx(run, 1)
    ctx.hud({ detail = CP.Lt('scoring.level_n', { n = 4 }) })
    run.shared.intel = CP.Lt('scoring.level_n', { n = 5 })
    local view = Runs.view(run, 1)
    H.eq(view.objectives[1].detail, 'Lv 4', 'ctx.hud detail tokens are resolved in the view')
    H.eq(view.intel, 'Lv 5', 'view.intel')
    H.eq(view.missionCall, nil, 'no mission call')
    H.eq(view.contact, nil, 'no contact without CP.Custody')
    H.reset()
    ctx.send({ label = CP.Lt('scoring.level_n', { n = 6 }) })
    local up = H.findEvents('crimson-police:client:objective')
    H.ok(up[1] and type(up[1].args[3].data.label) == 'string', 'ctx.send tokens are sent as strings')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                         17. BUILT-IN MISSION TWEAKS
-- ============================================================================

do
    local fakeFile = [[
RegisterMission({
  id = 'fnd_tweak',
  label = 'Tweakable',
  type = 'patrol',
  timeLimit = 600,
  cooldown = 600,
  locations = {
    { label = 'A', start = { coords = vec3(1000.0, 1000.0, 30.0), radius = 20.0 } },
    { label = 'B', start = { coords = vec3(1200.0, 1000.0, 30.0), radius = 20.0 } },
    { label = 'C', start = { coords = vec3(1400.0, 1000.0, 30.0), radius = 20.0 } },
    { label = 'D', start = { coords = vec3(1600.0, 1000.0, 30.0), radius = 20.0 } },
    { label = 'E', start = { coords = vec3(1800.0, 1000.0, 30.0), radius = 20.0 } },
    { label = 'F', start = { coords = vec3(2000.0, 1000.0, 30.0), radius = 20.0 } },
  },
  objectives = { { block = 'fnd_block', label = 'Go', weapons = { 'WEAPON_PISTOL' } } },
  bonuses = { { id = 'correct_disposition' }, { id = 'no_weapons_fired' } },
})
]]
    local realLoad = _G.LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == 'missions/builtin/index.lua' then return 'return { \'fnd_tweak\' }' end
        if path == 'missions/builtin/fnd_tweak.lua' then return fakeFile end
        return realLoad(res, path)
    end
    local warnings = {}
    local realWarn = CP.warn
    CP.warn = function(tag, fmt, ...) warnings[#warnings + 1] = tostring(fmt):format(...) end
    local realMissions = CP.Missions
    CP.Missions = nil
    H.load('modules/missions/server.lua')
    H.step(0)   -- its start-up load, while the fake index is served
    local Missions = CP.Missions
    Config.MissionTweaks = {
        fnd_tweak = {
            cooldown = 1800,
            timeLimit = 720,
            disabledLocations = { 'B' },
            weapons = { 'WEAPON_SMG' },
        },
    }
    Missions.loadAll()
    local d = Missions.get('fnd_tweak')
    H.ok(d ~= nil, 'the mission loads')
    H.eq(d and d.cooldown, 1800, 'a valid tweak changes the cooldown')
    H.eq(d and d.timeLimit, 720, 'and the time limit')
    H.eq(d and #d.locations, 5, 'a disabled location is left out')
    H.eq(d and d.objectives[1].weapons[1], 'WEAPON_SMG', 'weapons tweaked')
    H.eq(d and d.quietPatrol, false, 'quietPatrol defaults to false')
    local listed = {}
    for _, e in ipairs(d and d.bonuses or {}) do listed[e.id] = true end
    H.ok(not listed.correct_disposition, 'an engineOnly id is refused in a mission file')
    H.ok(listed.no_weapons_fired, 'a normal id stays')
    H.ok(Count(warnings, function(w)
        return Contains(w, 'correct_disposition') and Contains(w, 'engine only')
    end) >= 1, 'with a warning')
    warnings = {}
    Config.MissionTweaks = { fnd_tweak = { disabledLocations = { 'B', 'C' } } }
    Missions.loadAll()
    H.eq(#Missions.get('fnd_tweak').locations, 6, 'a tweak below the minimum locations is ignored')
    H.ok(Count(warnings, function(w)
        return Contains(w, 'MissionTweaks.fnd_tweak was ignored')
    end) >= 1, 'with a warning')
    warnings = {}
    Config.MissionTweaks = { fnd_tweak = { colour = 'red', cooldown = 60 } }
    Missions.loadAll()
    H.eq(Missions.get('fnd_tweak').cooldown, 600, 'a tweak with an unknown key is ignored')
    H.ok(Count(warnings, function(w) return Contains(w, 'unknown key') end) >= 1, 'with a warning')
    Config.MissionTweaks = {}
    -- label overrides
    H.eq(Missions.label(d, 'label'), 'Tweakable', 'label: the file text without a locale key')
    H.eq(Missions.label(d, 'location', 1), 'A', 'location label')
    -- reward-like and payout-like fields never stay
    local n = Missions.normalize({
        id = 'fnd_r',
        label = 'R',
        type = 'patrol',
        timeLimit = 600,
        itemRewards = { 1 },
        loot = 1,
        locations = { { start = { coords = vec3(3000.0, 3000.0, 30.0), radius = 10.0 } } },
        objectives = { { block = 'fnd_block' } },
    }, { source = 'builtin' })
    H.ok(n and n.itemRewards == nil and n.loot == nil, 'reward-like keys are refused like payout fields')
    CP.warn = realWarn
    _G.LoadResourceFile = realLoad
    CP.Missions = realMissions
end

-- ============================================================================
--                                  18. CONFIG
-- ============================================================================

do
    -- every block and key of the old config/blocks.lua is still present
    local env = { Config = {}, vec3 = vec3, vec4 = vec4 }
    local chunk = assert(loadfile(H.root .. '../tests/fixtures/foundation/blocks_before.lua', 't', env))
    chunk()
    local old = env.Config.Blocks
    local missing = {}
    for block, keys in pairs(old) do
        if not Config.Blocks[block] then
            missing[#missing + 1] = block
        else
            for k in pairs(keys) do
                if Config.Blocks[block][k] == nil then missing[#missing + 1] = block .. '.' .. k end
            end
        end
    end
    H.eq(table.concat(missing, ', '), '', 'every block and key of the old config/blocks.lua is still present')
    H.ok(Config.Blocks.field_contact and Config.Blocks.process_scene, 'field_contact and process_scene are new')
    H.eq(Config.Blocks.pursuit.responses.flee, 100, 'pursuit responses')
    H.eq(Config.Rewards.enabled, false, 'item rewards ship off')
    H.eq(Config.Locale, 'en', 'English only')
    -- engineOnly ids are missing from builder:config
    CP.Permissions = {
        can = function() return true end,
        actionsFor = function() return {} end,
    }
    CP.Access.isAdmin = function() return true end
    CP.Access.getOfficer = function() return nil end
    local realMissions = CP.Missions
    H.load('modules/builder/server.lua')
    CP.Missions = realMissions
    local res = H.callback('crimson-police:builder:config', 0)
    H.ok(res and res.ok, 'builder:config answers')
    local offered = {}
    for _, b in ipairs(res and res.data and res.data.bonuses or {}) do offered[b.id] = true end
    local leaked = {}
    for id, c in pairs(Config.Bonuses) do
        if c.engineOnly and offered[id] then leaked[#leaked + 1] = id end
    end
    H.eq(table.concat(leaked, ', '), '', 'builder:config leaves out every engineOnly id')
    H.ok(offered.procedure_complete and offered.no_weapons_fired, 'and offers the others')
end

-- ============================================================================
--                               19. THE SESSION
-- ============================================================================

do
    CP.Access.getOfficer = function(src)
        if src ~= 1 then return nil, 'err.not_police' end
        return {
            src = 1,
            citizenid = 'SESS1',
            name = 'Alice Able',
            department = 'sast',
            departmentLabel = 'SAST',
            departmentShort = 'SAST',
            rank = 'Sergeant',
            callsign = '2L-1',
            gradeLevel = 3,
            isSupervisor = true,
        }
    end
    CP.Access.isAdmin = function() return false end
    CP.Access.department = function() return { key = 'sast', theme = { primary = '#1f4e8c' } } end
    CP.Access.departments = function()
        return { { key = 'sast', label = 'SAST', short = 'SAST', theme = { primary = '#1f4e8c' } } }
    end
    CP.Access.refreshOfficerRow = function() end
    CP.Permissions.actionsFor = function() return {} end
    H.sql([[INSERT INTO cp_officers (citizenid, xp, avatar_kind, avatar_value, avatar_status, appearance, accent,
        ui_scale, calls_muted) VALUES ('SESS1', 1300, 'url', 'https://r2.fivemanage.com/a.png', 'approved', 'midnight',
        '#4CC9F0', 1.10, 1)]])
    H.load('modules/tablet/server.lua')
    local res = H.callback('crimson-police:getSession', 1, { ui = 'officer', via = 'desk', desk = 2, silent = true })
    H.ok(res and res.ok, 'getSession answers')
    local s = res and res.data or {}
    H.eq(s.officer.level.n, 10, 'officer.level (LevelInfo)')
    H.eq(s.officer.level.xp, 1300, 'with the officer\'s XP')
    H.eq(s.officer.level.label, 'Patrol Officer', 'and the band')
    H.eq(s.officer.avatar.kind, 'url', 'officer.avatar: an approved link')
    H.eq(s.officer.avatar.initials, 'AA', 'initials')
    H.eq(s.officer.avatar.frame, 'bronze', 'frame = the level badge')
    H.eq(s.prefs.appearance, 'midnight', 'prefs.appearance')
    H.eq(s.prefs.accent, '#4cc9f0', 'prefs.accent')
    H.eq(s.prefs.uiScale, 1.1, 'prefs.uiScale')
    H.eq(s.prefs.callsMuted, true, 'prefs.callsMuted')
    H.eq(s.prefs.language, nil, 'English only: no per-player language')
    H.eq(s.access.via, 'desk', 'access.via')
    H.eq(s.access.desk, 2, 'access.desk')
    local c = s.config
    H.eq(c.dispatch.enabled, Config.MissionCalls.enabled, 'config.dispatch.enabled')
    H.eq(#c.dispatch.areas, #Config.MissionCalls.areas, 'config.dispatch.areas')
    H.eq(c.dispatch.areas[1].key, 'south_ls', 'area keys')
    H.eq(#c.leaderboardMetrics, #Config.Leaderboard.metrics, 'config.leaderboardMetrics')
    H.eq(c.languages, nil, 'English only: no language list')
    H.eq(c.profile.bioMax, Config.Profile.bioMax, 'config.profile.bioMax')
    H.eq(#c.profile.presets, #Config.Profile.avatarPresets, 'profile presets')
    H.eq(c.profile.urls, false, 'avatar links off')
    H.eq(#c.profile.accents, #Config.Departments.sast.theme.personalAccents, 'the department\'s accents')
    H.eq(c.profile.accents[3].level, 10, 'with their levels')
    H.eq(c.profile.uiScale[2], 1.25, 'uiScale range')
    H.eq(#c.commendationKinds, #Config.Commendations.kinds, 'commendationKinds')
    H.eq(c.rewards.enabled, false, 'rewards off')
    H.eq(c.format.currency, '$', 'format.currency')
    H.eq(c.format.currencyAfter, false, 'format.currencyAfter')
    res = H.callback('crimson-police:getSession', 1, { ui = 'officer', via = 'bogus', silent = true })
    H.eq(res.data.access.via, 'command', 'an unknown way is command')
    H.eq(res.data.access.desk, nil, 'and no desk')
    H.sql('UPDATE cp_officers SET avatar_status = \'pending\' WHERE citizenid = \'SESS1\'')
    res = H.callback('crimson-police:getSession', 1, { ui = 'officer', silent = true })
    H.eq(res.data.officer.avatar.kind, 'initials', 'a pending link is never shown')
    H.sql('DELETE FROM cp_officers')
end

-- ============================================================================
--                   20. HOME EXTRAS AND THE ADMIN SUBCOMMAND
-- ============================================================================

do
    CP.Hooks.on('home:extras', function(cid, src, extras) extras.callsOpen = 2; extras.who = cid end)
    Config.Limits.maxCompletionsDay = 10
    local hd = CP.Scoring._homeData({ citizenid = 'HOME1', src = 1, name = 'H', departmentShort = 'SAST' })
    H.eq(hd.extras.callsOpen, 2, 'home:extras listeners add to Home')
    H.eq(hd.extras.who, 'HOME1', 'with the citizenid')
    H.eq(hd.missionsToday and hd.missionsToday.max, 10, 'missionsToday while a daily cap is on')
    Config.Limits.maxCompletionsDay = 0
    hd = CP.Scoring._homeData({ citizenid = 'HOME1', src = 1, name = 'H', departmentShort = 'SAST' })
    H.eq(hd.missionsToday, nil, 'no missionsToday without a cap')
    H.eq(hd.card.level.n, 1, 'the card level has a number')
end

-- ============================================================================
--                               21. arena:exited
-- ============================================================================

do
    CP.Alerts = nil
    CP.Dispatch = nil
    _G.AddStateBagChangeHandler = nil
    _G.GetPlayerFromStateBagName = function() return nil end
    H.load('modules/alerts/server.lua')
    local exits = {}
    CP.Hooks.on('arena:exited', function(src) exits[#exits + 1] = src end)
    H.players[1].state = H.players[1].state or {}
    H.players[1].bucket = 7
    CP.Alerts._arenaExits()
    H.eq(#exits, 0, 'nothing while in another bucket')
    H.players[1].bucket = 0
    CP.Alerts._arenaExits()
    H.eq(#exits, 1, 'bucket back to 0 with no flag change: once')
    CP.Alerts._arenaExits()
    H.eq(#exits, 1, 'only once')
    H.players[1].state.crimsonArena = { active = true, source = 'crimson_arena' }
    CP.Alerts._arenaExits()
    H.eq(#exits, 1, 'never while the foreign flag holds')
    H.players[1].bucket = 3
    H.players[1].state.crimsonArena = nil
    CP.Alerts._arenaExits()
    H.eq(#exits, 1, 'never while the bucket still holds')
    H.players[1].bucket = 0
    H.players[1].state.crimsonArena = { active = true, source = 'crimson_arena' }
    CP.Alerts._arenaExits()
    H.players[1].state.crimsonArena = nil
    CP.Alerts._arenaExits()
    H.eq(#exits, 2, 'once when the flag clears with bucket 0')
    H.eq(exits[2], 1, 'for that player')
end

-- ============================================================================
--                         22. THE HARNESS ENTITY MODEL
-- ============================================================================

do
    local e = H.entity(123456,
        { kind = 'vehicle', coords = vec3(0.0, 0.0, 0.0), velocity = vec3(10.0, 0.0, 0.0), siren = true })
    e.seats[-1] = 4242
    e:at(H.clockMs + 2000, { body = 300.0, siren = false })
    H.advance(1000)
    H.ok(math.abs(GetEntityCoords(e.handle).x - 10.0) < 0.01, 'H.entity moves with its velocity over H.advance')
    H.eq(GetEntitySpeed(e.handle), 10.0, 'GetEntitySpeed')
    H.eq(GetPedInVehicleSeat(e.handle, -1), 4242, 'seat occupants')
    H.eq(IsVehicleSirenOn(e.handle), true, 'siren')
    H.advance(1100)
    H.eq(GetVehicleBodyHealth(e.handle), 300.0, 'the timeline sets the health')
    H.eq(IsVehicleSirenOn(e.handle), false, 'and the siren')
    H.eq(NetworkGetEntityFromNetworkId(123456), e.handle, 'net id to handle')
    e.exists = false
    H.eq(DoesEntityExist(e.handle), false, 'DoesEntityExist')
    local inv = H.mockInventory({ water = { label = 'Water' } })
    H.ok(exports.ox_inventory:CanCarryItem(1, 'water', 1), 'ox_inventory CanCarryItem')
    exports.ox_inventory:AddItem(1, 'water', 2, { cpReward = 1 })
    H.eq(exports.ox_inventory:Search(1, 'count', 'water'), 2, 'ox_inventory Search count')
    H.eq(exports.ox_inventory:Items('water').label, 'Water', 'ox_inventory Items')
    inv.full[1] = true
    H.ok(not exports.ox_inventory:CanCarryItem(1, 'water', 1), 'a full inventory')
    local tgt = H.mockTarget()
    local zone = exports.ox_target:addBoxZone(
        { coords = vec3(1, 2, 3), options = { { name = 'crimson-police:desk' } } })
    exports.ox_target:addEntity({ 5 }, { { name = 'crimson-police:seat_talk', bones = { 'door_dside_f' } } })
    H.eq(tgt.zones[zone].options[1].name, 'crimson-police:desk', 'ox_target addBoxZone')
    H.eq(tgt.entities[1].options[1].bones[1], 'door_dside_f', 'ox_target addEntity with bones')
end

return H
