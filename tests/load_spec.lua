-- Every workflow under load: 48 officers, 16 runs at once, 4 operations, 200 queued payments, backup and copy.

-- Every workflow under load. On the world of
-- tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the owner's scripts running):
-- MariaDB with the database on in the database suite (lua5.4 tests/run.lua), the saves folder in the files and shadow
-- suites, so the same load runs on both stores and the suites compare them. 48 officers in three departments (SAST,
-- FIB and a BCSO the admin adds in Departments), 3 supervisors and the admin are online. The load:
--   1. shipped config: 12 runs at once (8 units of two, 4 solo); the 13th is refused (the server cap), and so are a
--      storage copy while runs go on, manual cash (the money tool ships off), a launch by an officer, a supervisor's
--      points for another department's officer, and a new run while an operation holds the boards. Operation 1 (four
--      officers of three departments) runs to the end during the 12 runs; a second launch waits for the cooldown.
--   2. the load limits changed (the admin's Settings: the server cap 16, no launch cooldown, the route not required,
--      manual cash on; every other switch: tests/settings_matrix_spec.lua): 16 runs at once (the 17th refused), operations 2 to 4
--      back to back (the last starts by itself when its join window closes), a backup while the 16 runs go on, a
--      player drop and reconnect mid-run, two runs nobody reaches (their start deadline), the rest done to the end
--      while Qbox refuses the pay of a few officers (their payments wait).
--   3. the queue: 200 payments wait (the refused ones and the admin's manual cash to officers who are offline), a
--      storage copy into the other store and a backup while they wait, then the logins pay them in waves with a
--      `restart Crimson-Police` in the middle.
-- Checked: no lost or double rows (every participant of every run has exactly one ledger row, the backup and the copy
-- hold every row the store has), every queued payment paid exactly once (the money each character got equals his
-- paid rows), no deadline missed (a start deadline and the operation join window end on time), no error line, and the
-- server's tick time within its budget (os.clock of each harness step: the resource's threads; on MariaDB the
-- queries' own time is in the mysql client, not counted). REPORT lines give the tick times.

_G.CP_WF_WORLD = 'load'
_G.CP_WF_STORAGE = 'database'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD, _G.CP_WF_STORAGE = nil, nil
local H, CID, PD = W.H, W.CID, W.PD
local Act, Cb, Secs, Place, Setting = W.Act, W.Cb, W.Secs, W.Place, W.Setting
local cjson = require('cjson')
local ON_DB = H.storage == 'database'

-- the error lines (CP.err prints '^1[crimson-police:<tag>]'); a refused Qbox AddMoney is one by design (expected)
local errorLines = {}
do
    local inner = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if line:find('^%^1%[crimson%-police') and not line:find('AddMoney%(bank, %d+%) failed') then
            errorLines[#errorLines + 1] = line
        end
        if line:find('^REPORT ') or line:find('^%s*FAIL ') then return W.realPrint(line) end
        return inner(...)
    end
end

-- the exports and city tables the soak (tests/soak_spec.lua) adds to this world
H.exportsMock.ox_inventory.registerHook = function() return 1 end
H.exportsMock.ox_inventory.removeHooks = function() end
H.exportsMock.qbx_core.GetMetadata = function(src, key)
    local pd = type(src) == 'number' and PD[src]
    if not pd then return false end
    return pd.metadata[key]
end
local function Mysql(sql) os.execute(('mysql -uroot %s -e "%s"'):format(H.db, sql)) end
os.execute(('mysql -uroot -e "CREATE DATABASE IF NOT EXISTS %s"'):format(H.db))
Mysql(
    'DROP TABLE IF EXISTS mdt_dispatch, player_vehicles, players, users; '
        .. 'CREATE TABLE users (license VARCHAR(64), license2 VARCHAR(64)); '
        .. 'CREATE TABLE mdt_dispatch (id INT PRIMARY KEY, unique_id VARCHAR(64), priority INT, active TINYINT); '
        .. 'CREATE TABLE player_vehicles (plate VARCHAR(16)); '
        .. 'CREATE TABLE players (citizenid VARCHAR(50) PRIMARY KEY, license VARCHAR(64), charinfo TEXT)'
)
do
    local realJobs = H.exportsMock.qbx_core.GetJobs
    H.exportsMock.qbx_core.GetJobs = function()
        local jobs = realJobs()
        jobs.bcso = { label = 'BCSO', type = 'leo', grades = jobs.sast.grades }
        return jobs
    end
end
-- Qbox refuses AddMoney for the characters in refuse (their payments wait as pending)
local refuse = {}
do
    local realGet = H.exportsMock.qbx_core.GetPlayer
    H.exportsMock.qbx_core.GetPlayer = function(src)
        local p = realGet(src)
        if p and refuse[p.PlayerData.citizenid] then
            p.Functions.AddMoney = function() return false end
        end
        return p
    end
end

-- ============================================================================
--                       THE TICK METER (HARNESS TIMING)
-- ============================================================================
-- CPU milliseconds of each harness step (every server thread that wakes in it), by phase.

local meter = { phase = nil, by = {} }
-- src -> { due = os.time() deadline, at = os.time() when he was first seen off his run } (the deadline checks)
local watch = {}
do
    local realStep = H.step
    H.step = function(ms)
        for src, w in pairs(watch) do
            if not w.at and CP.Runs and not CP.Runs.getBySrc(src) then w.at = os.time() end
        end
        if not meter.phase then return realStep(ms) end
        local t0 = os.clock()
        realStep(ms)
        local d = (os.clock() - t0) * 1000
        local b = meter.by[meter.phase]
        b.n, b.total = b.n + 1, b.total + d
        if d > b.max then b.max = d end
        if os.getenv('CP_LOAD_TRACE') and d > 30 then
            W.realPrint(('REPORT trace: a step of %.1f ms at %d ms (%s)'):format(d, H.clockMs, meter.phase))
        end
        b.list[#b.list + 1] = d
    end
end
local function Phase(name)
    meter.by[name] = meter.by[name] or { n = 0, total = 0, max = 0, list = {} }
    meter.phase = name
end
local function Pct(list, q)
    if #list == 0 then return 0 end
    local s = {}
    for i, v in ipairs(list) do s[i] = v end
    table.sort(s)
    return s[math.max(1, math.ceil(#s * q))]
end

-- ============================================================================
--                                 THE PLAYERS
-- ============================================================================
-- 48 officers: the world's 1 6 7 (SAST) and 2 (FIB), and 8-51 (SAST, FIB, BCSO in turn); supervisors 3 (SAST),
-- 4 (FIB) and 52 (BCSO); the admin 5.

local DEPTS = { 'sast', 'fib', 'bcso' }
local DEPT_OF = { [1] = 'sast', [6] = 'sast', [7] = 'sast', [2] = 'fib', [3] = 'sast', [4] = 'fib', [52] = 'bcso' }
local OFFICERS = { 1, 2, 6, 7 }
for s = 8, 51 do
    DEPT_OF[s] = DEPTS[(s % 3) + 1]
    OFFICERS[#OFFICERS + 1] = s
    W.AddPlayer(s, ('LOADOF%02d'):format(s), 'Load', 'Officer' .. s, DEPT_OF[s], 1)
end
W.AddPlayer(52, 'LOADSU52', 'Rae', 'Sheriff', 'bcso', 3)
local ALL = {}
for s = 1, 52 do ALL[#ALL + 1] = s end
for _, s in ipairs(ALL) do CID[s] = PD[s].citizenid end
for i, s in ipairs(ALL) do
    if s >= 8 then
        PD[s].job.type = 'leo'
        H.players[s].coords = vec3(-300.0 + i * 3.0, -1400.0, 30.0)
        W.Reconnect(s)
    end
    local pd = PD[s]
    Mysql(('INSERT INTO players VALUES (\'%s\', \'%s\', \'%s\'); INSERT INTO users VALUES (\'%s\', NULL)'):format(
        pd.citizenid, pd.license, cjson.encode(pd.charinfo):gsub('"', '\\"'), pd.license))
end
H.eq(#OFFICERS, 48, 'set-up: 48 officers')
do
    local ok, err = Act('server:admin:addDepartment', 5, {
        key = 'bcso',
        label = 'Blaine County Sheriff',
        short = 'BCSO',
        jobs = { 'bcso' },
        supervisorGrade = 3,
        themeFrom = 'sast',
    })
    H.eq(ok, true, 'set-up: the admin adds BCSO: ' .. tostring(err))
end
-- every officer opens the tablet once (his officer row)
for _, s in ipairs(OFFICERS) do Cb('getSession', s, { ui = 'officer' }) end
H.eq(#errorLines, 0, 'set-up: no error line: ' .. table.concat(errorLines, ' | '))

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v) return tonumber(v) or 0 end
local function Count(sql, params) return Num((H.sql(sql, params)[1] or {}).n) end
local function Rid() return W.RequestId() end
local runsSeen = {}       -- runId -> { participants = { [src] = true }, ended = reason }
local function Seen()
    for _, run in ipairs(CP.Runs.all()) do
        local s = runsSeen[run.id] or { participants = {}, operation = run.operationId }
        runsSeen[run.id] = s
        for _, src in ipairs(CP.Runs.activeSrcs(run)) do s.participants[src] = true end
    end
end
local function Running()
    Seen()
    return #CP.Runs.all()
end

-- The objective in progress of src's run done (tests/soak_spec.lua's Work): every member at the start, then the
-- objective's own completion after its minimum time.
local function Work(src)
    local run = CP.Runs.getBySrc(src)
    if not run then return false end
    if run.state ~= 'in_progress' and run.location and run.location.start then
        for _, m in ipairs(CP.Runs.activeSrcs(run)) do Place(m, run.location.start.coords) end
        Secs(3)
        if run.state ~= 'in_progress' then return false end
    end
    local i = run.objectiveIndex
    local o = i and run.objectives[i]
    if not o then return false end
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    local minS = (o.obj and o.obj.minSeconds or 0) + 1
    if waited < minS then Secs(math.min(240, math.ceil(minS - waited))) end
    if run.state ~= 'in_progress' or run.objectiveIndex ~= i then return true end
    CP.Runs.objectiveComplete(run, i, {})
    return true
end
-- Every run of srcs worked to its end (at most n passes).
local function WorkAll(srcs, n)
    for _ = 1, n or 20 do
        local left = 0
        for _, s in ipairs(srcs) do
            local run = CP.Runs.getBySrc(s)
            if run and (run.leader == nil or run.leader == s or not CP.Runs.getBySrc(run.leader)) then
                Seen()
                Work(s)
                left = left + 1
            end
        end
        if left == 0 then return true end
    end
    return false
end

local TYPES = { 'patrol', 'training', 'investigation' }
-- src (a solo officer or a unit leader) accepts a type; his run's members go to its start (arrive) unless away
local function AcceptAs(src, i, away)
    local ok, err = Act('server:acceptType', src, TYPES[(i % #TYPES) + 1])
    local run = ok and CP.Runs.getBySrc(src)
    if run and not away and run.location and run.location.start then
        for _, m in ipairs(CP.Runs.activeSrcs(run)) do Place(m, run.location.start.coords) end
        Secs(3)
    end
    return ok, err
end

-- every on-run state the store has: a ledger row per run and participant, never two
local function DoubleRows()
    local r = H.sql(
        'SELECT run_uuid, citizenid, COUNT(*) AS n FROM cp_mission_runs WHERE mission_type IN '
            .. '(\'patrol\', \'training\', \'investigation\', \'tactical\') GROUP BY run_uuid, citizenid'
    )
    for _, x in ipairs(r) do
        if Num(x.n) > 1 then return x.run_uuid .. ' ' .. x.citizenid end
    end
    return nil
end

local function Deptless(list, dept)
    local out = {}
    for _, s in ipairs(list) do if DEPT_OF[s] == dept then out[#out + 1] = s end end
    return out
end

-- One cross-department operation: the supervisor launches, the four join (three departments), Start now (or the
-- join window's end), every member done to the end. -> the run's id
local function Operation(sup, members, label, waitWindow)
    local view = Cb('sup:getOperation', sup) or {}
    local mission
    for _, m in ipairs(view.eligibleMissions or {}) do
        local def = CP.Missions.get(m.id)
        local free = false
        for k = 1, def and #(def.locations or {}) or 0 do
            if not CP.Draw.isReserved(m.id, k) then free = true end
        end
        if free and def and CP.Draw.pickLocation(def, members) == nil then free = false end
        if free and Num(m.maxOfficers) >= #members and Num(m.minOfficers) <= #members and m.type ~= 'tactical' then
            mission = m.id
            break
        end
    end
    H.ok(mission ~= nil, label .. ': a mission to launch')
    local ok, data = Act('server:sup:opLaunch', sup, { missionId = mission })
    H.eq(ok, true, label .. ': launched: ' .. tostring(data))
    local opId = data and data.id
    for _, s in ipairs(members) do
        local okJ, dj = Act('server:joinOperation', s, opId)
        H.eq(okJ, true, ('%s: %s joins: %s'):format(label, CID[s], tostring(dj)))
    end
    local startAt
    if waitWindow then
        -- nobody taps Start now: the window's end starts it
        local op = CP.Operations.active()
        local due = op and op.joinEndsAt
        H.ok(due ~= nil, label .. ': a join window deadline')
        for _ = 1, 800 do
            if CP.Runs.getBySrc(members[1]) then break end
            Secs(1)
        end
        startAt = os.time()
        local late = startAt - Num(due)
        H.ok(late >= 0 and late <= 3, ('%s: the window ends on time (%d s late)'):format(label, late))
    else
        local okS, ds = Act('server:sup:opStart', sup)
        H.eq(okS, true, label .. ': Start now: ' .. tostring(ds))
    end
    local run = CP.Runs.getBySrc(members[1])
    H.ok(run ~= nil and run.operationId == opId, label .. ': the operation run')
    Seen()
    WorkAll({ members[1] })
    Secs(3)
    local st = H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1]
    H.eq(st and st.status, 'completed', label .. ': completed')
    H.eq(CP.Operations.isLocked(), false, label .. ': the boards are free again')
    return run and run.id
end

-- ============================================================================
--                      1. SHIPPED CONFIG: 12 RUNS AT ONCE
-- ============================================================================

-- a fixed draw seed for the whole spec: with 16 runs at once a random seed can leave one type with no free
-- location (a right answer, but not the one the switches phase checks)
CP.Draw._setRng(CP.U.rng(4242))
Phase('shipped')
H.time = H.time + 7200
local UNITS = {}                     -- 8 units of two: leaders 8..15, members 16..23
for i = 0, 7 do
    W.FormUnit(8 + i, 16 + i)
    UNITS[#UNITS + 1] = 8 + i
end
local SOLO = { 24, 25, 26, 27 }
local onRun = {}
for i, s in ipairs(UNITS) do
    local ok, err = AcceptAs(s, i)
    H.eq(ok, true, ('shipped: unit %d accepts: %s'):format(s, tostring(err)))
end
for i, s in ipairs(SOLO) do
    local ok, err = AcceptAs(s, i)
    H.eq(ok, true, ('shipped: %s accepts: %s'):format(CID[s], tostring(err)))
end
H.eq(Running(), 12, 'shipped: 12 runs at once')
do
    local ok, err = AcceptAs(28, 1)
    H.eq(err, 'err.server_busy', 'shipped: the 13th run is refused (the server cap 12): ' .. tostring(ok))
    ok, err = Act('server:admin:storageCopy', 5,
        { direction = ON_DB and 'database-to-files' or 'files-to-database', reason = 'WF6B', requestId = Rid() }, 400)
    H.eq(ok, false, 'shipped: a storage copy while runs go on is refused (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:manualCash', 5,
        { citizenid = CID[28], amount = 25, reason = 'WF6B', requestId = Rid() })
    H.ok(not ok and err == 'err.money_tool_off', 'shipped: manual cash ships off')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[29], points = 5, reason = 'WF6B' })
    H.eq(ok, DEPT_OF[29] == 'sast', 'shipped: points only for the own department (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:opLaunch', 28, { missionId = 'beat_patrol' })
    H.eq(ok, false, 'shipped: an officer cannot launch an operation (' .. tostring(err) .. ')')
end
-- operation 1 during the 12 runs: SAST 30, FIB 31 and 34, BCSO 32
do
    Operation(3, { 30, 31, 32, 34 }, 'operation 1')
    local ok, err = Act('server:sup:opLaunch', 4, { missionId = 'beat_patrol' })
    H.eq(ok, false, 'shipped: the next launch waits for the cooldown (' .. tostring(err) .. ')')
end
H.eq(Running(), 12, 'shipped: the 12 runs go on through the operation')
-- a drop and a reconnect mid-run (unit member 16 of 8's unit): his row is Failed, the unit's run goes on
do
    W.Drop(16)
    H.eq(CP.Runs.getBySrc(16), nil, 'drop: off his run')
    H.ok(CP.Runs.getBySrc(8) ~= nil, 'drop: the unit run goes on')
    W.Reconnect(16)
    H.eq(CP.Runs.getBySrc(16), nil, 'reconnect: not put back on the run')
end
local shipped = {}
for _, s in ipairs(UNITS) do shipped[#shipped + 1] = s end
for _, s in ipairs(SOLO) do shipped[#shipped + 1] = s end
H.ok(WorkAll(shipped, 30), 'shipped: every run done to its end')
Secs(10)
H.eq(Running(), 0, 'shipped: no run left')
H.eq(DoubleRows(), nil, 'shipped: no double ledger row')

-- ============================================================================
--                 2. THE LOAD LIMITS CHANGED: 16 RUNS AT ONCE
-- ============================================================================

Phase('switches')
H.eq(Setting('Limits.maxConcurrentRuns', 16), true, 'switches: the server cap 16')
H.eq(Setting('CrossDept.cooldown', 0), true, 'switches: no launch cooldown')
-- (an officer who never moves sends no route report: with the route required he is off route after 40 s)
H.eq(Setting('Route.required', false), true, 'switches: the route is not required')
do
    local ok, err = Act('server:admin:setSetting', 5,
        { path = 'Cash.allowManualCash', json = 'true', reason = 'WF6B', confirm = 'ENABLE' })
    H.eq(ok, true, 'switches: manual cash on with ENABLE: ' .. tostring(err))
end
-- 16 solo runs; 33 and 35 never reach the start (their deadline)
local SIXTEEN = { 28, 29, 33, 35 }
for s = 36, 47 do SIXTEEN[#SIXTEEN + 1] = s end
local AWAY_START = { [33] = true, [35] = true }
-- Qbox refuses the pay of four of them: their payments wait
local REFUSED = { 28, 29, 36, 37 }
for _, s in ipairs(REFUSED) do refuse[CID[s]] = true end
for i, s in ipairs(SIXTEEN) do
    local ok, err = AcceptAs(s, i, AWAY_START[s])
    H.eq(ok, true, ('switches: %s accepts: %s'):format(CID[s], tostring(err)))
end
for s in pairs(AWAY_START) do
    local run = CP.Runs.getBySrc(s)
    local p = run and run.participants[s]
    H.ok(p ~= nil and p.deadline ~= nil, ('deadline: %s has a start deadline'):format(CID[s]))
    watch[s] = { due = p and p.deadline }
end
H.eq(Running(), 16, 'switches: 16 runs at once')
do
    local ok, err = AcceptAs(48, 1)
    H.eq(err, 'err.server_busy', 'switches: the 17th run is refused: ' .. tostring(ok))
end
-- a backup while the 16 runs go on: it holds every ledger row
do
    local before = Count('SELECT COUNT(*) AS n FROM cp_mission_runs')
    local ok, res = Act('server:admin:backupNow', 5, {}, 400)
    local after = Count('SELECT COUNT(*) AS n FROM cp_mission_runs')
    H.ok(ok == true and type(res) == 'table', 'switches: a backup during 16 runs: ' .. tostring(res))
    local m = res and res.name and io.open(H.resourcePath() .. '/saves/_backups/' .. res.name .. '.manifest.json')
    local manifest = m and cjson.decode(m:read('a'))
    if m then m:close() end
    local n = Num(manifest and manifest.tables and manifest.tables.cp_mission_runs)
    H.ok(n >= before and n <= after,
        ('switches: the backup has every ledger row (%d, store %d-%d)'):format(n, before, after))
end
-- operation 2 during the 16 runs (officers of the shipped runs: operations ignore their cooldowns)
Operation(4, { 8, 9, 10, 11 }, 'operation 2')
local working = {}
for _, s in ipairs(SIXTEEN) do if not AWAY_START[s] then working[#working + 1] = s end end
H.ok(WorkAll(working, 30), 'switches: every run done to its end')
-- the start deadline of 33 and 35: removed at it, not later
for _, s in ipairs({ 33, 35 }) do
    for _ = 1, 900 do
        if watch[s].at then break end
        Secs(1)
    end
    local late = Num(watch[s].at) - Num(watch[s].due)
    H.ok(watch[s].at ~= nil and late >= 0 and late <= 3,
        ('deadline: %s removed at his start deadline (%d s late)'):format(CID[s], late))
    watch[s] = nil
end
Secs(10)
H.eq(Running(), 0, 'switches: no run left')
H.eq(DoubleRows(), nil, 'switches: no double ledger row')
H.eq(#errorLines, 0, 'switches: no error line: ' .. table.concat(errorLines, ' | '))

-- ============================================================================
--                       3. THE QUEUE: 200 PAYMENTS WAIT
-- ============================================================================

Phase('queue')
local function Pending() return Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE cash_status = \'pending\'') end
local refusedRows = Pending()
H.ok(refusedRows >= #REFUSED, ('queue: the refused payments wait (%d)'):format(refusedRows))
-- twenty officers go offline; the admin pays them by hand ($25 each) until 200 payments wait
local AWAY = {}
for s = 30, 49 do AWAY[#AWAY + 1] = s end
for _, s in ipairs(AWAY) do W.Drop(s) end
local manual = 0
while Pending() < 200 do
    local s = AWAY[(manual % #AWAY) + 1]
    local ok, res = Act('server:admin:manualCash', 5,
        { citizenid = CID[s], amount = 25, reason = 'WF6B queue', requestId = Rid() })
    manual = manual + 1
    if not ok then
        H.ok(false, 'queue: manual cash to an offline officer: ' .. tostring(res))
        break
    end
end
H.eq(Pending(), 200, ('queue: 200 payments wait (%d refused, %d by hand)'):format(refusedRows, manual))
local queued = {}
for _, r in ipairs(H.sql('SELECT id, citizenid FROM cp_mission_runs WHERE cash_status = \'pending\'')) do
    queued[#queued + 1] = { id = Num(r.id), cid = r.citizenid }
end
local paidBefore = #W.addMoney
-- a storage copy into the other store while they wait (it has rows from the set-up: Replace with REPLACE): every row
-- copied, nothing paid by it
do
    local direction = ON_DB and 'database-to-files' or 'files-to-database'
    local rows = Count('SELECT COUNT(*) AS n FROM cp_mission_runs')
    local ok, res = Act('server:admin:storageCopy', 5,
        { direction = direction, force = true, confirm = 'REPLACE', reason = 'WF6B copy', requestId = Rid() }, 800)
    H.eq(ok, true, 'queue: a storage copy while 200 payments wait: ' .. tostring(res))
    local copied = type(res) == 'table' and type(res.vars) == 'table' and Num(res.vars.rows) or 0
    H.ok(copied >= rows, ('queue: the copy wrote every row (%d)'):format(copied))
    H.eq(CP.Maintenance.active(), nil, 'queue: no lock left by the copy')
    H.eq(#W.addMoney, paidBefore, 'queue: the copy paid nothing')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs'), rows, 'queue: the store in use keeps every row')
end
-- a backup while they wait
do
    local ok, res = Act('server:admin:backupNow', 5, {}, 400)
    H.ok(ok == true and type(res) == 'table', 'queue: a backup while they wait: ' .. tostring(res))
end
-- operations 3 and 4 while they wait (the 4th starts when its join window closes); no copy while one runs
do
    local okL = Act('server:sup:opLaunch', 52, { missionId = 'nope' })
    H.eq(okL, false, 'queue: an unknown mission is never launched')
end
Operation(52, { 12, 13, 14, 15 }, 'operation 3')
Operation(3, { 50, 51, 1, 2 }, 'operation 4', true)
-- the logins pay them: half the offline officers come back, Qbox takes the money again, a restart in the middle,
-- then the rest come back
for k = 1, 10 do W.Reconnect(AWAY[k]) end
for _, s in ipairs(REFUSED) do refuse[CID[s]] = nil end
W.Restart()
Secs(90)                                   -- the start's sweep pays whoever is online
for k = 11, #AWAY do W.Reconnect(AWAY[k]) end
Secs(30)
do
    local n, twice, missing = 0, 0, {}
    for _, q in ipairs(queued) do
        local r = H.sql('SELECT cash_status, cash_paid FROM cp_mission_runs WHERE id = ?', { q.id })[1] or {}
        if r.cash_status == 'paid' then
            n = n + 1
        else
            missing[#missing + 1] = q.id .. ':' .. tostring(r.cash_status)
        end
    end
    H.eq(n, 200, 'queue: every queued payment is paid (' .. table.concat(missing, ' ', 1, math.min(5, #missing)) .. ')')
    local got, rowsSum = {}, {}
    for _, m in ipairs(W.addMoney) do got[m.citizenid] = (got[m.citizenid] or 0) + Num(m.amount) end
    for _, s in ipairs(ALL) do
        local r = H.sql(
            'SELECT COALESCE(SUM(cash_paid), 0) AS s FROM cp_mission_runs WHERE citizenid = ? AND '
                .. 'cash_status IN (\'paid\', \'capped\')',
            { CID[s] }
        )[1]
        rowsSum[s] = Num(r and r.s)
        if (got[CID[s]] or 0) ~= rowsSum[s] then twice = twice + 1 end
    end
    H.eq(twice, 0, 'queue: the money each character got equals his paid rows (never twice)')
    H.eq(Pending(), 0, 'queue: nothing waits')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE cash_status = \'paying\''), 0, 'queue: nothing stuck')
end

-- ============================================================================
--                       NO LOST ROW, NO ERROR, TICK TIME
-- ============================================================================

meter.phase = nil
do
    local lost = {}
    for id, seen in pairs(runsSeen) do
        for src in pairs(seen.participants) do
            local n = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ?',
                { id, CID[src] })
            if n ~= 1 then lost[#lost + 1] = ('%s %s %d'):format(id, CID[src], n) end
        end
    end
    local n = 0
    for _ in pairs(runsSeen) do n = n + 1 end
    H.ok(n >= 20, ('rows: %d runs seen'):format(n))
    H.eq(#lost, 0, 'rows: one ledger row per run and participant: ' .. table.concat(lost, ', ', 1, math.min(5, #lost)))
    H.eq(DoubleRows(), nil, 'rows: no double ledger row')
end
H.eq(#errorLines, 0, 'no error line: ' .. table.concat(errorLines, ' | ', 1, math.min(3, #errorLines)))

-- budgets (CPU ms of one harness step): the 95th and 99th percentile and the worst step of each phase (os.clock counts
-- the process' garbage collection too, so the worst step has room for one collection on a busy machine)
local BUDGET = { p95 = 25, p99 = 100, max = 500 }
for _, name in ipairs({ 'shipped', 'switches', 'queue' }) do
    local b = meter.by[name]
    local p95, p99 = Pct(b.list, 0.95), Pct(b.list, 0.99)
    print(('REPORT load %s (%s): %d steps, mean %.2f ms, p95 %.2f ms, p99 %.1f ms, max %.1f ms'):format(name,
        ON_DB and 'MariaDB' or 'saves folder', b.n, b.total / math.max(1, b.n), p95, p99, b.max))
    H.ok(p95 <= BUDGET.p95, ('tick: %s p95 %.2f ms within %d ms'):format(name, p95, BUDGET.p95))
    H.ok(p99 <= BUDGET.p99, ('tick: %s p99 %.1f ms within %d ms'):format(name, p99, BUDGET.p99))
    H.ok(b.max <= BUDGET.max, ('tick: %s worst step %.1f ms within %d ms'):format(name, b.max, BUDGET.max))
end

if not ON_DB then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s"'):format(H.db)) end
_G.print = W.realPrint

return H
