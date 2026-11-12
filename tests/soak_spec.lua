-- WF6A: a seeded random action soak across every workflow (the owner: "do extensive workflow testing on everything").

-- WF6A: a seeded random action soak across every workflow (the owner: "do extensive workflow testing on everything").
-- A random driver on the world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the
-- owner's scripts running, database off: the saves folder, as shipped) with 12 officers in 3 departments (SAST, FIB and
-- a BCSO the admin adds in Departments), 2 supervisors, 1 admin and 2 civilians. For many simulated hours it picks
-- random valid AND invalid actions from every role: accept, work the objective, abandon, units, mission calls,
-- supervisor controls, the Review Queue, disputes, money tools, Settings changes, presets, restarts, drops and
-- reconnects, duty toggles, daily and weekly resets, the maintenance lock, the guided tours (done, replay,
-- /crimsonhelp, the Setup checklist) and the tablet itself. After every action it checks the invariants:
--   two_runs        no player on two runs
--   ended_twice     every run ends once per player (one runEnded each, one ledger row each), and at the end of the
--                   soak no run is left and every run ended
--   paid_twice      money paid at most once per row: the cash each character got equals the cash_paid of his paid
--                   and capped rows
--   negative        no negative XP, cash or department funding
--   caps            the per-day caps of supervisors (points, commendations, bans, cooldown clears), the unit size and
--                   the completions an hour are never passed
--   lock_held       every CP.Lock key and the maintenance lock are released (a few seconds after the action)
--   orphan          no entity left without its run (the client blips go with the runEnded of every participant)
--   error_line      no error line (CP.err) and no Lua error
--   refusal         an action of the wrong role, department, a feature off or under the maintenance lock never
--                   succeeds
-- On a failure it prints the seed and the shortest action list it finds that still fails (it replays shorter lists
-- in child runs: CP_SOAK_REPLAY).
--   lua5.4 tests/run.lua tests/soak_spec.lua                       the short run of the normal suite (~2 hours)
--   CP_SOAK=1 CP_SOAK_SEED=7 CP_SOAK_HOURS=8 lua5.4 tests/run.lua tests/soak_spec.lua      one long seed
--   CP_SOAK=1 CP_SOAK_STORAGE=database CP_SOAK_SEED=7 lua5.4 tests/run.lua tests/soak_spec.lua    on MariaDB
--   CP_SOAK=1 CP_SOAK_SEEDS=1-20 lua5.4 tests/run.lua tests/soak_spec.lua                 many seeds (child runs)

local SOAK = os.getenv('CP_SOAK') == '1'
local REPLAY = os.getenv('CP_SOAK_REPLAY')
local SEEDS = os.getenv('CP_SOAK_SEEDS')
local SEED = tonumber(os.getenv('CP_SOAK_SEED') or '') or 20261112
local HOURS = tonumber(os.getenv('CP_SOAK_HOURS') or '') or (SOAK and 8 or 2)
local SELF = 'tests/soak_spec.lua'

-- Lua source of a plain value (numbers, strings, booleans and tables of them): the action lists of a replay.
local function Ser(v)
    local t = type(v)
    if t == 'string' then return ('%q'):format(v) end
    if t ~= 'table' then return tostring(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local key = type(k) == 'number' and ('[%d]'):format(k) or ('[%q]'):format(k)
        parts[#parts + 1] = key .. '=' .. Ser(v[k])
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

-- A child run of this spec on one seed or one action list: its output and whether it failed.
local function Child(envs)
    local e = {}
    for k, v in pairs(envs) do e[#e + 1] = ('%s=\'%s\''):format(k, v) end
    table.sort(e)
    local h = io.popen(
        ('env -u CP_SOAK_SEEDS CP_SOAK=1 %s lua5.4 tests/run.lua --child %s 2>&1'):format(table.concat(e, ' '), SELF))
    local out = h:read('a')
    h:close()
    local _, fail = out:match('RESULT (%d+) (%d+)')
    return out, (tonumber(fail) or 1) > 0
end

-- ============================================================================
--                MANY SEEDS: ONE CHILD RUN EACH (CP_SOAK_SEEDS)
-- ============================================================================

if SOAK and SEEDS and not os.getenv('CP_SOAK_SEED') and not REPLAY then
    local H = dofile('tests/harness.lua')
    local from, to = SEEDS:match('^(%d+)%-(%d+)$')
    local list = {}
    if from then
        for s = tonumber(from), tonumber(to) do list[#list + 1] = s end
    else
        for s in SEEDS:gmatch('%d+') do list[#list + 1] = tonumber(s) end
    end
    for _, s in ipairs(list) do
        local out, failed = Child({ CP_SOAK_SEED = s, CP_SOAK_HOURS = HOURS })
        for line in out:gmatch('[^\n]+') do
            if line:match('^REPORT ') or line:match('^FAIL') then print(line) end
        end
        H.ok(not failed, ('soak: seed %d passed %d simulated hours'):format(s, HOURS))
    end
    return H
end

-- ============================================================================
--                                  THE WORLD
-- ============================================================================

_G.CP_WF_WORLD = 'soak'
-- CP_SOAK_STORAGE=database (with lua5.4 tests/run.lua's default MariaDB mode): the same soak on MariaDB, database on
_G.CP_WF_STORAGE = os.getenv('CP_SOAK_STORAGE')
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Act, Cb, Secs, Place, Setting = W.Act, W.Cb, W.Secs, W.Place, W.Setting
local cjson = require('cjson')

-- the error lines (CP.err prints '^1[crimson-police:<tag>]') of every boot
local errorLines = {}
do
    local inner = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if line:find('^%^1%[crimson%-police') then errorLines[#errorLines + 1] = line end
        if line:find('^REPORT ') or line:find('^%s*FAIL ') then return W.realPrint(line) end
        return inner(...)
    end
end

-- ox_inventory's hook (the tablet item's): the full walk never reaches it, the soak's restarts and settings do
H.exportsMock.ox_inventory.registerHook = function() return 1 end
H.exportsMock.ox_inventory.removeHooks = function() end
-- Qbox's GetMetadata (src only; a citizenid string returns false, as qbx_core does)
H.exportsMock.qbx_core.GetMetadata = function(src, key)
    local pd = type(src) == 'number' and PD[src]
    if not pd then return false end
    return pd.metadata[key]
end
-- the city's own tables the adapters read (sc-dispatch's calls, Qbox's players, users and owned plates) in the world's
-- database; every player's character is added to players below
local function Mysql(sql) os.execute(('mysql -uroot %s -e "%s"'):format(H.db, sql)) end
os.execute(('mysql -uroot -e "CREATE DATABASE IF NOT EXISTS %s"'):format(H.db))
Mysql(
    'DROP TABLE IF EXISTS mdt_dispatch, player_vehicles, players, users; '
        .. 'CREATE TABLE users (license VARCHAR(64), license2 VARCHAR(64)); '
        .. 'CREATE TABLE mdt_dispatch (id INT PRIMARY KEY, unique_id VARCHAR(64), priority INT, active TINYINT); '
        .. 'CREATE TABLE player_vehicles (plate VARCHAR(16)); '
        .. 'CREATE TABLE players (citizenid VARCHAR(50) PRIMARY KEY, license VARCHAR(64), charinfo TEXT)'
)
-- the database is dropped at the end (in files mode only the city's tables are in it)
local function DropCity()
    if os.getenv('CP_SOAK_STORAGE') ~= 'database' then
        os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s"'):format(H.db))
    end
end
local function AddCharacter(src)
    local pd = PD[src]
    Mysql(('INSERT INTO players VALUES (\'%s\', \'%s\', \'%s\')'):format(
        pd.citizenid,
        pd.license,
        cjson.encode(pd.charinfo):gsub('"', '\\"')
    ) .. ('; INSERT INTO users VALUES (\'%s\', NULL)'):format(pd.license))
end

-- Qbox knows a sheriff's job; the admin adds its department (BCSO) in Departments below.
do
    local realJobs = H.exportsMock.qbx_core.GetJobs
    H.exportsMock.qbx_core.GetJobs = function()
        local jobs = realJobs()
        jobs.bcso = { label = 'BCSO', type = 'leo', grades = jobs.sast.grades }
        return jobs
    end
end
-- 12 officers (SAST 1 6 7 8, FIB 2 9 10 11, BCSO 12-15), the supervisors 3 (SAST) and 4 (FIB), the admin 5 and the
-- civilians 16 and 17.
local ADDED = {
    { 8, 'SOAKOF08', 'Gus', 'Trooper', 'sast', 1 },
    { 9, 'SOAKOF09', 'Hal', 'Agent', 'fib', 1 },
    { 10, 'SOAKOF10', 'Ivy', 'Agent', 'fib', 0 },
    { 11, 'SOAKOF11', 'Jo', 'Agent', 'fib', 1 },
    { 12, 'SOAKDP12', 'Kai', 'Deputy', 'bcso', 1 },
    { 13, 'SOAKDP13', 'Lee', 'Deputy', 'bcso', 1 },
    { 14, 'SOAKDP14', 'Mo', 'Deputy', 'bcso', 0 },
    { 15, 'SOAKDP15', 'Ned', 'Deputy', 'bcso', 1 },
    { 16, 'SOAKCV16', 'Oli', 'Citizen', 'unemployed', 0 },
    { 17, 'SOAKCV17', 'Pam', 'Citizen', 'unemployed', 0 },
}
local OFFICERS = { 1, 6, 7, 8, 2, 9, 10, 11, 12, 13, 14, 15 }
local SUPERVISORS = { 3, 4 }
local ADMIN = 5
local CIVILIANS = { 16, 17 }
local ALL = {}
for s = 1, 17 do ALL[s] = s end
local DEPT_OF = {}
for _, s in ipairs({ 1, 6, 7, 8, 3 }) do DEPT_OF[s] = 'sast' end
for _, s in ipairs({ 2, 9, 10, 11, 4 }) do DEPT_OF[s] = 'fib' end
for _, s in ipairs({ 12, 13, 14, 15 }) do DEPT_OF[s] = 'bcso' end
local IS = {}
for _, s in ipairs(OFFICERS) do IS[s] = 'officer' end
for _, s in ipairs(SUPERVISORS) do IS[s] = 'supervisor' end
IS[ADMIN] = 'admin'
for _, s in ipairs(CIVILIANS) do IS[s] = 'civilian' end

-- ============================================================================
--                          THE RANDOM SOURCE (SEEDED)
-- ============================================================================
-- Its own xorshift, so the resource's math.random never moves the action list.

local rs = (SEED * 2654435761 + 1) & 0xffffffff
if rs == 0 then rs = 1 end
local function Rand()
    rs = rs ~ ((rs << 13) & 0xffffffff)
    rs = rs ~ (rs >> 17)
    rs = rs ~ ((rs << 5) & 0xffffffff)
    return rs
end
local function Int(a, b) return a + Rand() % (b - a + 1) end
local function Pick(list) return list[Int(1, #list)] end
local function Chance(p) return Rand() % 1000 < p * 1000 end
math.randomseed(SEED)

-- ============================================================================
--                                    STATE
-- ============================================================================

local offline = {}          -- src -> true while dropped
local maintOn = false       -- the soak holds the maintenance lock
local dutyOff = {}          -- src -> true while off duty
local lockRegistry = setmetatable({}, { __mode = 'k' })
local evMark = 0            -- H.events read so far by the runEnded check
local endedCount = {}       -- runId|src -> runEnded events
local runsSeen = {}         -- runId -> { participants = { [src] = true } }
local tally = {}            -- day|kind|who -> count (successful supervisor actions)
local orphanSince = {}      -- entity handle -> clockMs first seen without its run
local playerVehicles = {}   -- entity handle -> true (the officers' own cars)
local failure = nil         -- { invariant, detail }

local function Fail(name, detail)
    if not failure then failure = { name = name, detail = tostring(detail) } end
    return false
end

-- Every CP.Lock the resource takes is listed (lock_held), after each boot (the module tables are new).
local function WatchLocks()
    local mt = getmetatable(CP.Lock.new())
    if not mt or mt._soakWatched then return end
    local take = mt.take
    mt.take = function(self, key)
        lockRegistry[self] = true
        return take(self, key)
    end
    mt._soakWatched = true
end

-- A restart ends every run (onResourceStop deletes its entities and writes nothing, as documented in runs.lua; the
-- client's resource restarts too): those runs count as ended once, by the restart.
local function Restart()
    for _, run in ipairs(CP.Runs.all()) do
        local seen = runsSeen[run.id] or { participants = {} }
        seen.ended = 'restart'
        runsSeen[run.id] = seen
    end
    W.Restart()
    WatchLocks()
    -- the lock of a restore is memory only: a restart lets it go
    maintOn = CP.Maintenance.active() ~= nil
    for src in pairs(offline) do PD[src].job.onduty = false end
end

-- ============================================================================
--                                    SET-UP
-- ============================================================================

WatchLocks()
for i, p in ipairs(ADDED) do
    W.AddPlayer(table.unpack(p))
    CID[p[1]] = p[2]
    H.players[p[1]].coords = vec3(-300.0 + i * 3.0, -1400.0, 30.0)
    W.Reconnect(p[1])
end
for s = 1, 17 do AddCharacter(s) end
for s = 1, 7 do H.players[s].coords = vec3(-300.0 - s * 3.0, -1400.0, 30.0) end
do
    local ok, err = Act('server:admin:addDepartment', ADMIN, {
        key = 'bcso',
        label = 'Blaine County Sheriff',
        short = 'BCSO',
        jobs = { 'bcso' },
        supervisorGrade = 3,
        themeFrom = 'sast',
    })
    H.eq(ok, true, 'set-up: the admin adds BCSO: ' .. tostring(err))
end
-- even seeds: every switch on through Settings (odd seeds keep the shipped config)
local SWITCHES = SEED % 2 == 0
if SWITCHES then
    Setting('Permissions.supervisor.missionControls', true)
    local controls = CP.U.copy(Config.MissionControls.controls)
    for _, c in pairs(controls) do c.on = true end
    Setting('MissionControls.controls', controls)
    for _, path in ipairs({ 'Cash.allowManualCash', 'Cash.allowAddFunds' }) do
        Act('server:admin:setSetting', ADMIN, { path = path, json = 'true', reason = 'WF6A', confirm = 'ENABLE' })
    end
end
H.eq(#errorLines, 0, 'set-up: no error line: ' .. table.concat(errorLines, ' | '))

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function DayKey() return CP.Schedule.dayKey(os.time()) end
local function Count(day, kind, who) return tally[day .. '|' .. kind .. '|' .. tostring(who)] or 0 end
local function Add(kind, who, n)
    local k = DayKey() .. '|' .. kind .. '|' .. tostring(who)
    tally[k] = (tally[k] or 0) + (n or 1)
end

-- The objective in progress of src's run done: arrive at the start, then its block's own completion after the
-- objective's minimum time (the block specs drive every step's evidence).
local function Work(src)
    local run = CP.Runs.getBySrc(src)
    if not run then return false, 'not on a run' end
    if run.state ~= 'in_progress' and run.location and run.location.start then
        for _, m in ipairs(CP.Runs.activeSrcs(run)) do Place(m, run.location.start.coords) end
        Secs(3)
        if run.state ~= 'in_progress' then return false, 'not started (' .. tostring(run.state) .. ')' end
    end
    local i = run.objectiveIndex
    local o = i and run.objectives[i]
    if not o then return false, 'no objective' end
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    local minS = (o.obj and o.obj.minSeconds or 0) + 1
    if waited < minS then Secs(math.min(240, math.ceil(minS - waited))) end
    if run.state ~= 'in_progress' or run.objectiveIndex ~= i then return true end
    return CP.Runs.objectiveComplete(run, i, {}) or o.status == 'done'
end

local function OpenCall(src)
    local calls = (Cb('getMissionCalls', src) or {}).calls or {}
    for _, c in ipairs(calls) do
        if c.status == nil or c.status == 'open' then return c.id end
    end
    return calls[1] and calls[1].id
end

local function LatestRow(cid)
    local r = H.sql('SELECT id FROM cp_mission_runs WHERE citizenid = ? ORDER BY id DESC LIMIT 1', { cid })[1]
    return r and tonumber(r.id)
end

local function QueueItem(src)
    local q = Cb('review:getQueue', src)
    local items = type(q) == 'table' and q.items or {}
    return items[1]
end

local GOOD = 'Stayed with the victim until EMS arrived.'
local TYPES = { 'patrol', 'training', 'investigation', 'tactical' }
local KINDS = { 'valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation', 'bravery' }
local TOURS = { 'officer', 'supervisor', 'admin', 'criminal', 'run', 'nope' }
local AREAS = { 'south_ls', 'downtown', 'west_ls', 'vinewood', 'nowhere' }
local TOGGLES = {
    'Permissions.supervisor.missionControls',
    'AdminControl.pointAdjust',
    'Recognition.commendations.enabled',
    'Permissions.supervisor.missionCalls',
    'Permissions.supervisor.reviewFlagged',
    'Training.enabled',
    'Training.setupChecklist',
    'Cash.allowManualCash',
    'Cash.allowAddFunds',
    'controls',
}
local MONEY = { ['Cash.allowManualCash'] = true, ['Cash.allowAddFunds'] = true }

-- The actions that must be refused under the maintenance lock (every one writes).
local LOCKED = {
    accept = true,
    award = true,
    ban = true,
    clear = true,
    commend = true,
    mcPost = true,
    answer = true,
}

-- ============================================================================
--                       THE ACTIONS (ONE GENERATOR EACH)
-- ============================================================================
-- gen() -> a plain action table (kept for a replay); EXEC[a.k](a) -> ok, err.

local function AnyPlayer()
    if Chance(0.7) then return Pick(OFFICERS) end
    return Int(1, 17)
end
-- Most picks are valid (a player on a run, an invited one, an officer of the supervisor's department): the random
-- rest are the invalid ones.
local invited = {}          -- src -> true after an invite to him succeeded
local function OnRun()
    local on = {}
    for _, s in ipairs(OFFICERS) do if CP.Runs.getBySrc(s) then on[#on + 1] = s end end
    if #on > 0 and Chance(0.85) then return Pick(on) end
    return Pick(OFFICERS)
end
local function Invited()
    local list = {}
    for s in pairs(invited) do list[#list + 1] = s end
    table.sort(list)
    if #list > 0 and Chance(0.85) then return Pick(list) end
    return AnyPlayer()
end
local function InUnit()
    local list = {}
    for _, s in ipairs(OFFICERS) do if CP.Units.unitOf(s) then list[#list + 1] = s end end
    if #list > 0 and Chance(0.85) then return Pick(list) end
    return AnyPlayer()
end
local function TargetOf(staff)
    if Chance(0.75) and DEPT_OF[staff] then
        local same = {}
        for _, s in ipairs(OFFICERS) do if DEPT_OF[s] == DEPT_OF[staff] then same[#same + 1] = s end end
        return Pick(same)
    end
    return Int(1, 17)
end
local function Staff()
    local r = Int(1, 10)
    if r <= 6 then return Pick(SUPERVISORS) elseif r <= 8 then return ADMIN end
    return Pick(OFFICERS)
end

local GEN = {
    {
        14,
        function() return { k = 'accept', src = AnyPlayer(), type = Chance(0.05) and 'nope' or Pick(TYPES) } end,
    },
    {
        22,
        function() return { k = 'work', src = OnRun() } end,
    },
    {
        4,
        function() return { k = 'abandon', src = Chance(0.8) and OnRun() or AnyPlayer() } end,
    },
    {
        5,
        function() return { k = 'invite', src = Pick(OFFICERS), target = AnyPlayer() } end,
    },
    {
        4,
        function() return { k = 'pair', src = Pick(OFFICERS), target = Pick(OFFICERS) } end,
    },
    {
        5,
        function() return { k = 'respond', src = Invited(), yes = Chance(0.8) } end,
    },
    {
        2,
        function() return { k = 'leave', src = InUnit() } end,
    },
    {
        1,
        function() return { k = 'kick', src = InUnit(), target = InUnit() } end,
    },
    {
        1,
        function() return { k = 'promote', src = InUnit(), target = InUnit() } end,
    },
    {
        1,
        function() return { k = 'disband', src = InUnit() } end,
    },
    {
        1,
        function() return { k = 'cancelInvite', src = InUnit(), target = Invited() } end,
    },
    {
        3,
        function() return { k = 'mcPost', src = Staff(), type = Pick(TYPES), area = Pick(AREAS) } end,
    },
    {
        3,
        function() return { k = 'answer', src = AnyPlayer(), decline = Chance(0.2) } end,
    },
    {
        3,
        function()
            local src = Staff()
            return { k = 'award', src = src, target = TargetOf(src), points = Int(-5, 60) }
        end,
    },
    {
        2,
        function()
            local src = Staff()
            return { k = 'commend', src = src, target = TargetOf(src), kind = Pick(KINDS) }
        end,
    },
    {
        2,
        function()
            local src = Staff()
            return { k = 'ban', src = src, target = TargetOf(src), hours = Int(0, 26) }
        end,
    },
    {
        2,
        function()
            local src = Staff()
            return { k = 'clear', src = src, target = TargetOf(src), type = Pick(TYPES) }
        end,
    },
    {
        1,
        function() return { k = 'happyHour', src = Staff(), minutes = Int(1, 20) } end,
    },
    {
        3,
        function() return { k = 'review', src = Staff(), decision = Pick({ 'approve', 'void', 'undo' }) } end,
    },
    {
        1,
        function() return { k = 'dispute', src = Pick(OFFICERS) } end,
    },
    {
        2,
        function() return { k = 'manualCash', src = Staff(), target = Int(1, 17), amount = Int(-10, 400) } end,
    },
    {
        1,
        function()
            return {
                k = 'addFunds',
                src = Staff(),
                dept = Pick({ 'sast', 'fib', 'bcso', 'nope' }),
                amount = Int(0, 900),
            }
        end,
    },
    {
        2,
        function()
            return {
                k = 'setting',
                src = Chance(0.85) and ADMIN or Staff(),
                path = Pick(TOGGLES),
                value = Chance(0.5),
            }
        end,
    },
    {
        1,
        function()
            return {
                k = 'preset',
                src = Chance(0.85) and ADMIN or Staff(),
                preset = Pick({ 'casual', 'serious', 'golive', 'nope' }),
            }
        end,
    },
    {
        1,
        function() return { k = 'restart' } end,
    },
    {
        2,
        function() return { k = 'drop', src = Int(1, 17) } end,
    },
    {
        3,
        function() return { k = 'reconnect', src = Int(1, 17) } end,
    },
    {
        2,
        function() return { k = 'duty', src = Pick(OFFICERS), on = Chance(0.75) } end,
    },
    {
        6,
        function() return { k = 'wait', secs = Int(5, 150) } end,
    },
    {
        1,
        function() return { k = 'hour' } end,
    },
    {
        1,
        function() return { k = Chance(0.85) and 'day' or 'week' } end,
    },
    {
        1,
        function() return { k = 'maint', on = Chance(0.3) } end,
    },
    {
        2,
        function() return { k = 'tourDone', src = Int(1, 17), tour = Pick(TOURS), version = Int(0, 3) } end,
    },
    {
        2,
        function() return { k = 'help', src = Int(1, 17), arg = Chance(0.5) and Pick(TOURS) or nil } end,
    },
    {
        1,
        function() return { k = 'resetTours', src = Staff(), target = Int(1, 17) } end,
    },
    {
        1,
        function() return { k = 'home', src = Staff() } end,
    },
    {
        3,
        function() return { k = 'open', src = Int(1, 17), ui = Pick({ 'officer', 'supervisor', 'admin' }) } end,
    },
}
local GEN_TOTAL = 0
for _, g in ipairs(GEN) do GEN_TOTAL = GEN_TOTAL + g[1] end
local function Generate()
    local r = Int(1, GEN_TOTAL)
    for _, g in ipairs(GEN) do
        r = r - g[1]
        if r <= 0 then return g[2]() end
    end
end

local function Rid() return W.RequestId() end
-- W.Act with at() called right before the event is sent (after the wait between two actions).
local actN = 0
local function ActAt(name, src, payload, at)
    actN = actN + 1
    local id = 'soak' .. actN
    W.Adv(1600)
    at()
    local mark = #H.events
    H.fire('crimson-police:' .. name, src, payload, id)
    for _ = 1, 40 do
        for i = #H.events, mark + 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return e.args[2], e.args[3] end
        end
        W.Adv(250)
    end
    return nil, 'no reply'
end
local function Unit(src) return CP.Units.unitOf(src) end

local acceptOnRun = false  -- the accepting player was on a run when his accept was sent
local EXEC = {
    accept = function(a)
        -- whether he is on a run is read right when the accept is sent (a run may end during the wait before it)
        local ok, err = ActAt('server:acceptType', a.src, a.type, function()
            acceptOnRun = CP.Runs.getBySrc(a.src) ~= nil
        end)
        return ok, err
    end,
    work = function(a) return Work(a.src) end,
    abandon = function(a)
        local run = CP.Runs.getBySrc(a.src)
        return Act('server:abandon', a.src, run and run.id or 'no-run')
    end,
    invite = function(a)
        local ok, data = Act('server:unitInvite', a.src, a.target)
        if ok then invited[a.target] = type(data) == 'table' and data.unitId or true end
        return ok, data
    end,
    respond = function(a)
        local unitId = invited[a.src]
        invited[a.src] = nil
        return Act('server:unitRespond', a.src,
            { accepted = a.yes, unitId = type(unitId) ~= 'boolean' and unitId or nil })
    end,
    -- an invite answered at once (a unit formed or grown)
    pair = function(a)
        local ok, data = Act('server:unitInvite', a.src, a.target)
        if not ok then return ok, data end
        return Act('server:unitRespond', a.target, { accepted = true, unitId = type(data) == 'table' and data.unitId })
    end,
    leave = function(a) return Act('server:teamLeave', a.src) end,
    kick = function(a) return Act('server:unitKick', a.src, { targetSrc = a.target }) end,
    promote = function(a) return Act('server:unitPromote', a.src, { targetSrc = a.target }) end,
    disband = function(a) return Act('server:unitDisband', a.src) end,
    cancelInvite = function(a) return Act('server:unitCancelInvite', a.src, { targetSrc = a.target }) end,
    mcPost = function(a)
        local scope = a.src == ADMIN and 'admin' or 'sup'
        return Act(('server:%s:mcPost'):format(scope), a.src, { type = a.type, area = a.area })
    end,
    answer = function(a)
        local id = OpenCall(a.src) or 999999
        return Act('server:answerMissionCall', a.src, { callId = id, answer = a.decline and 'decline' or nil })
    end,
    award = function(a)
        return Act('server:sup:awardPoints', a.src, { citizenid = CID[a.target], points = a.points, reason = 'Soak' })
    end,
    commend = function(a)
        return Act('server:sup:commend', a.src, { citizenid = CID[a.target], kind = a.kind, citation = GOOD })
    end,
    ban = function(a)
        return Act('server:sup:missionBan', a.src, { citizenid = CID[a.target], hours = a.hours, reason = 'Soak' })
    end,
    clear = function(a)
        return Act('server:sup:clearCooldowns', a.src,
            { citizenid = CID[a.target], scope = 'type', key = a.type, reason = 'Soak' })
    end,
    happyHour = function(a)
        return Act('server:sup:setMissionControl', a.src,
            { key = 'happyHour', value = { minutes = a.minutes }, reason = 'Soak', requestId = Rid() })
    end,
    review = function(a)
        local item = QueueItem(a.src)
        if not item then return false, 'empty queue' end
        return Act('server:review:decide', a.src,
            { type = item.type, id = item.id, decision = a.decision, reason = 'Soak review' })
    end,
    dispute = function(a)
        local id = LatestRow(CID[a.src])
        if not id then return false, 'no row' end
        return Act('server:dispute', a.src, { rowId = id, reason = 'My game crashed, please check the route log' })
    end,
    manualCash = function(a)
        return Act('server:admin:manualCash', a.src,
            { citizenid = CID[a.target], amount = a.amount, reason = 'Soak', requestId = Rid() })
    end,
    addFunds = function(a)
        return Act('server:admin:addDepartmentFunds', a.src,
            { department = a.dept, amount = a.amount, reason = 'Soak', confirm = tostring(a.amount), requestId = Rid() })
    end,
    setting = function(a)
        if a.path == 'controls' then
            local controls = CP.U.copy(Config.MissionControls.controls)
            for key, c in pairs(controls) do
                if key ~= 'noRepeat' and key ~= 'hourlyCap' and key ~= 'dailyCap' then c.on = a.value end
            end
            return Act('server:admin:setSetting', a.src,
                { path = 'MissionControls.controls', json = cjson.encode(controls), reason = 'Soak' })
        end
        return Act('server:admin:setSetting', a.src, {
            path = a.path,
            json = cjson.encode(a.value),
            reason = 'Soak',
            confirm = (MONEY[a.path] and a.value) and 'ENABLE' or nil,
        })
    end,
    preset = function(a) return Act('server:admin:applyPreset', a.src, { preset = a.preset }) end,
    restart = function()
        Restart()
        return true
    end,
    drop = function(a)
        if offline[a.src] then return false, 'offline' end
        offline[a.src] = true
        W.Drop(a.src)
        return true
    end,
    reconnect = function(a)
        if not offline[a.src] then return false, 'online' end
        offline[a.src] = nil
        W.Reconnect(a.src)
        return true
    end,
    duty = function(a)
        if offline[a.src] then return false, 'offline' end
        PD[a.src].job.onduty = a.on
        dutyOff[a.src] = not a.on or nil
        TriggerEvent('QBCore:Server:SetDuty', a.src, a.on)
        Secs(2)
        return true
    end,
    wait = function(a)
        Secs(a.secs)
        return true
    end,
    hour = function()
        H.time = H.time + 3600
        Secs(5)
        return true
    end,
    day = function()
        local d = os.date('*t', H.time + 86400)
        H.time = os.time({ year = d.year, month = d.month, day = d.day, hour = 9, min = 0, sec = 0 })
        Secs(5)
        return true
    end,
    week = function()
        H.time = H.time + 7 * 86400
        Secs(5)
        return true
    end,
    maint = function(a)
        if a.on then
            local ok, err = CP.Maintenance.begin('restore', { by = 'WF6A' })
            maintOn = maintOn or ok == true
            return ok, err
        end
        local ok, err = CP.Maintenance.finish('restore')
        if ok then maintOn = false end
        return ok, err
    end,
    tourDone = function(a)
        return Act('server:training:done', a.src, { tour = a.tour, version = a.version })
    end,
    help = function(a)
        if offline[a.src] then return false, 'offline' end
        Secs(3)
        H.commands.crimsonhelp.fn(a.src, a.arg and { a.arg } or {})
        Secs(1)
        return true
    end,
    resetTours = function(a)
        return Act('server:admin:resetTours', a.src, { citizenid = CID[a.target], reason = 'Soak replay' })
    end,
    home = function(a)
        local home, err = Cb('admin:getHome', a.src, {})
        return home ~= nil, err
    end,
    open = function(a)
        local s, err = Cb('getSession', a.src, { ui = a.ui, via = 'command' })
        return s ~= nil, err
    end,
}

-- ============================================================================
--                    WHAT A SUCCESS MAY NEVER BE (REFUSALS)
-- ============================================================================

local function SupDept(src) return DEPT_OF[src] end
-- before: the state an action ran in; ok: its answer. false + why when a refusal was not kept.
local function Refusal(a, ok, before)
    if ok ~= true then return true end
    local k, src = a.k, a.src
    if before.maint and LOCKED[k] then return false, k .. ' succeeded under the maintenance lock' end
    if k == 'accept' then
        if IS[src] == 'civilian' or src == ADMIN then return false, 'a non-officer accepted a mission' end
        if before.offDuty then return false, 'an officer off duty accepted a mission' end
        if a.type == 'nope' then return false, 'an unknown type was accepted' end
        if acceptOnRun then return false, 'an officer on a run accepted another' end
    elseif k == 'award' or k == 'ban' or k == 'commend' then
        if IS[src] == 'officer' then return false, 'an officer used ' .. k end
        if src == a.target then return false, k .. ' on himself' end
        if IS[src] == 'supervisor' and SupDept(a.target) ~= SupDept(src) then
            return false, k .. ' on another department'
        end
        if IS[a.target] == 'civilian' then return false, k .. ' on a civilian' end
        if k == 'award' and (a.points < 1 or a.points > 50) then return false, 'points outside 1-50' end
        if k == 'award' and not before.pointAdjust then return false, 'points with point adjusts off' end
        if k == 'ban' and (a.hours < 1 or a.hours > 24) then return false, 'a ban outside 1-24 hours' end
        if k == 'commend' and a.kind == 'bravery' then return false, 'an unknown commendation kind' end
        if k == 'commend' and not before.commendations then return false, 'a commendation while they are off' end
    elseif k == 'clear' then
        if IS[src] == 'officer' then return false, 'an officer cleared a cooldown' end
        if src == a.target then return false, 'a cooldown cleared for himself' end
    elseif k == 'manualCash' or k == 'addFunds' or k == 'preset' or k == 'setting' or k == 'resetTours' then
        if src ~= ADMIN then return false, 'a non-admin used ' .. k end
        if k == 'manualCash' and not before.manualCash then return false, 'manual cash while the tool is off' end
        if k == 'addFunds' and not before.addFunds then return false, 'add funds while the tool is off' end
        if k == 'manualCash' and (a.amount <= 0 or IS[a.target] == 'civilian') then
            return false, 'manual cash of ' .. a.amount .. ' to ' .. tostring(IS[a.target])
        end
        if k == 'addFunds' and a.dept == 'nope' then return false, 'funds for an unknown department' end
        if k == 'preset' and a.preset == 'nope' then return false, 'an unknown preset' end
    elseif k == 'mcPost' then
        if IS[src] == 'officer' then return false, 'an officer posted a call' end
        if a.area == 'nowhere' then return false, 'a call in an unknown area' end
    elseif k == 'home' then
        if src ~= ADMIN then return false, 'a non-admin opened Admin Home' end
    elseif k == 'open' then
        if IS[src] == 'civilian' and a.ui ~= 'officer' then return false, 'a civilian opened the ' .. a.ui .. ' UI' end
        if a.ui == 'admin' and src ~= ADMIN then return false, 'a non-admin opened the Admin UI' end
    end
    return true
end

local function Before(a)
    local cash = Config.Cash or {}
    return {
        maint = CP.Maintenance.active() ~= nil,
        offDuty = PD[a.src or 0] and PD[a.src].job.onduty == false,
        pointAdjust = Config.AdminControl and Config.AdminControl.pointAdjust == true,
        commendations = Config.Recognition.commendations.enabled == true,
        manualCash = cash.allowManualCash == true,
        addFunds = cash.allowAddFunds == true,
    }
end

-- The tallies of the supervisor caps, after a success.
local function Tally(a, ok, data)
    if ok ~= true or IS[a.src] ~= 'supervisor' then return end
    if a.k == 'award' then
        Add('award', a.src, a.points)
    elseif a.k == 'commend' then
        Add('commend', a.src)
    elseif a.k == 'ban' then
        Add('ban', a.src)
    elseif a.k == 'clear' then
        Add('clear', a.src)
        Add('clearOf', a.target)
    end
end

-- ============================================================================
--                                THE INVARIANTS
-- ============================================================================

local function Num(v) return tonumber(v) or 0 end

local function CheckRuns()
    local on = {}
    for _, run in ipairs(CP.Runs.all()) do
        local seen = runsSeen[run.id] or { participants = {} }
        runsSeen[run.id] = seen
        for _, src in ipairs(CP.Runs.activeSrcs(run)) do
            seen.participants[src] = true
            if on[src] then return Fail('two_runs', ('player %d is on %s and %s'):format(src, on[src], run.id)) end
            on[src] = run.id
        end
    end
    if #H.events < evMark then evMark = 0 end
    for i = evMark + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.name == 'crimson-police:client:runEnded' then
            local key = tostring(e.args[1]) .. '|' .. tostring(e.target)
            endedCount[key] = (endedCount[key] or 0) + 1
            if runsSeen[e.args[1]] then runsSeen[e.args[1]].ended = true end
            if endedCount[key] > 1 then
                return Fail('ended_twice',
                    ('run %s ended %d times for player %s'):format(e.args[1], endedCount[key], tostring(e.target)))
            end
        end
    end
    evMark = #H.events
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local rows = H.sql((
            'SELECT run_uuid, citizenid, COUNT(*) AS n FROM %s WHERE mission_type IN '
            .. '(\'patrol\', \'training\', \'investigation\', \'tactical\') GROUP BY run_uuid, citizenid'
        ):format(tbl))
        for _, r in ipairs(rows) do
            if Num(r.n) > 1 then
                return Fail('ended_twice',
                    ('%s: run %s has %d rows for %s'):format(tbl, r.run_uuid, Num(r.n), r.citizenid))
            end
        end
    end
    return true
end

local function CheckMoney()
    local paying = H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE cash_status = \'paying\'')[1]
    if Num(paying and paying.n) > 0 then
        return true
    end -- a payout in flight: checked on the next action
    local got = {}
    for _, m in ipairs(W.addMoney) do got[m.citizenid] = (got[m.citizenid] or 0) + Num(m.amount) end
    for _, src in ipairs(ALL) do
        local cid = CID[src]
        local sum = 0
        for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
            local r = H.sql((
                'SELECT SUM(cash_paid) AS s FROM %s WHERE citizenid = ? AND cash_status IN '
                .. '(\'paid\', \'capped\')'
            ):format(tbl), { cid })[1]
            sum = sum + Num(r and r.s)
        end
        if (got[cid] or 0) ~= sum then
            return Fail('paid_twice', ('%s got $%d, his paid rows say $%d'):format(cid, got[cid] or 0, sum))
        end
    end
    local neg = H.sql('SELECT citizenid, xp FROM cp_officers WHERE xp < 0')[1]
    if neg then return Fail('negative', ('%s has %d XP'):format(neg.citizenid, Num(neg.xp))) end
    neg = H.sql('SELECT id, cash_paid FROM cp_mission_runs WHERE cash_paid < 0')[1]
    if neg then return Fail('negative', ('row %s paid %d'):format(tostring(neg.id), Num(neg.cash_paid))) end
    neg = H.sql('SELECT id, amount FROM cp_dept_funding WHERE amount < 0')[1]
    if neg then return Fail('negative', ('funding %s of %d'):format(tostring(neg.id), Num(neg.amount))) end
    return true
end

local function CheckCaps()
    local day = DayKey()
    local MC, R = Config.MissionControls or {}, Config.Recognition.commendations or {}
    for _, s in ipairs(SUPERVISORS) do
        if Count(day, 'award', s) > Num(MC.awardPointsPerDay) then
            return Fail('caps', ('supervisor %d gave %d points today'):format(s, Count(day, 'award', s)))
        end
        if Count(day, 'commend', s) > Num(R.perSupervisorPerDay) then
            return Fail('caps', ('supervisor %d gave %d commendations today'):format(s, Count(day, 'commend', s)))
        end
        if Count(day, 'ban', s) > Num(MC.missionBanPerDay) then
            return Fail('caps', ('supervisor %d set %d bans today'):format(s, Count(day, 'ban', s)))
        end
        if Count(day, 'clear', s) > Num(MC.clearCooldownPerDay) then
            return Fail('caps', ('supervisor %d cleared %d cooldowns today'):format(s, Count(day, 'clear', s)))
        end
    end
    for _, s in ipairs(ALL) do
        if Count(day, 'clearOf', s) > Num(Config.AdminControl.cooldownClearsPerDay) then
            return Fail('caps', ('player %d had %d cooldowns cleared today'):format(s, Count(day, 'clearOf', s)))
        end
    end
    local maxUnit = Num(Config.Limits.maxUnitSize)
    for _, u in ipairs(CP.Units.adminList()) do
        if #u.members > maxUnit then return Fail('caps', ('unit %s has %d members'):format(u.id, #u.members)) end
    end
    -- completed runs in any hour, per officer: never above the highest hourly cap a department may set
    local cap = math.max(Num(Config.Limits.maxCompletionsHour), Num(MC.controls.hourlyCap.max))
    local rows = H.sql(
        'SELECT citizenid, UNIX_TIMESTAMP(created_at) AS t FROM cp_mission_runs WHERE state = '
            .. '\'completed\' AND mission_type IN (\'patrol\', \'training\', \'investigation\', \'tactical\') '
            .. 'AND created_at >= FROM_UNIXTIME(?) ORDER BY id',
        { os.time() - 3600 }
    )
    local per = {}
    for _, r in ipairs(rows) do per[r.citizenid] = (per[r.citizenid] or 0) + 1 end
    for cid, n in pairs(per) do
        if n > cap then return Fail('caps', ('%s completed %d runs in an hour (cap %d)'):format(cid, n, cap)) end
    end
    return true
end

local function HeldLocks()
    for lock in pairs(lockRegistry) do
        for key in pairs(lock._held or {}) do return tostring(key) end
    end
    if CP.Maintenance.active() ~= nil and not maintOn then return 'maintenance (' .. CP.Maintenance.active() .. ')' end
    return nil
end

local function CheckEntities()
    local owned = {}
    for _, run in ipairs(CP.Runs.all()) do
        for _, e in ipairs(CP.Runs.entitiesFor(run, {})) do owned[e.entity] = true end
    end
    for _, src in ipairs(ALL) do
        local v = H.players[src] and H.players[src].vehicle
        if v then playerVehicles[v] = true end
    end
    for h, e in pairs(W.ents) do
        if e.exists and not owned[h] and not playerVehicles[h] then
            orphanSince[h] = orphanSince[h] or H.clockMs
            if H.clockMs - orphanSince[h] > 120000 then
                return Fail('orphan', ('%s %s (handle %d) exists %d s after its run'):format(e.kind, tostring(e.model),
                    h, (H.clockMs - orphanSince[h]) // 1000))
            end
        else
            orphanSince[h] = nil
        end
    end
    return true
end

local function Invariants()
    if #errorLines > 0 then return Fail('error_line', errorLines[1]) end
    if not CheckRuns() or not CheckMoney() or not CheckCaps() or not CheckEntities() then return false end
    local held = HeldLocks()
    if held then
        Secs(3)
        held = HeldLocks()
        if held then
            Secs(10)
            held = HeldLocks()
        end
        if held then return Fail('lock_held', 'still held: ' .. held) end
    end
    return true
end

local okCount = {}          -- action kind -> successes
-- One action: run it, keep its refusal rule, check every invariant. true while all hold.
local function Step(a)
    local before = Before(a)
    local res = table.pack(pcall(EXEC[a.k], a))
    if not res[1] then return Fail('error_line', 'Lua error in ' .. a.k .. ': ' .. tostring(res[2])) end
    local ok, data = res[2], res[3]
    local kept, why = Refusal(a, ok, before)
    if not kept then return Fail('refusal', why .. ' (' .. Ser(a) .. ')') end
    Tally(a, ok, data)
    if ok == true then okCount[a.k] = (okCount[a.k] or 0) + 1 end
    if os.getenv('CP_SOAK_TRACE') then
        W.realPrint(('TRACE %s -> %s %s'):format(Ser(a), tostring(ok), tostring(data)))
    end
    return Invariants()
end

-- The end of a soak: the lock off, everyone back on duty, every run left, twenty minutes later nothing runs and every
-- run that was seen ended.
local function Drain()
    if maintOn then
        CP.Maintenance.finish('restore')
        maintOn = false
    end
    for _, src in ipairs(ALL) do
        if offline[src] then
            offline[src] = nil
            W.Reconnect(src)
        end
    end
    for _, src in ipairs(ALL) do
        local run = CP.Runs.getBySrc(src)
        if run then Act('server:abandon', src, run.id) end
    end
    Secs(20 * 60)
    if not Invariants() then return false end
    local left = CP.Runs.all()
    if #left > 0 then return Fail('ended_twice', ('%d runs never ended (%s)'):format(#left, left[1].id)) end
    for id, seen in pairs(runsSeen) do
        if not seen.ended then
            local row = H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE run_uuid = ?', { id })[1]
            if Num(row and row.n) == 0 then return Fail('ended_twice', 'run ' .. id .. ' never ended') end
        end
    end
    return true
end

-- ============================================================================
--                          THE DRIVER AND THE REPLAY
-- ============================================================================

local function RunList(list)
    for i, a in ipairs(list) do
        if not Step(a) then return i end
    end
    if not Drain() then return #list + 1 end
    return nil
end

if REPLAY then
    local list = dofile(REPLAY)
    local at = RunList(list)
    if at then print(('REPORT SOAK REPLAY FAIL %s at %d: %s'):format(failure.name, at, failure.detail)) end
    H.ok(at == nil, 'replay: the list passes')
    DropCity()
    _G.print = W.realPrint
    return H
end

local list, startMs, failedAt = {}, H.clockMs, nil
local counts = {}
while H.clockMs - startMs < HOURS * 3600 * 1000 do
    local a = Generate()
    list[#list + 1] = a
    counts[a.k] = (counts[a.k] or 0) + 1
    if not Step(a) then
        failedAt = #list
        break
    end
end
if not failedAt and not Drain() then failedAt = #list + 1 end

-- The shortest list that still fails the same way: drop halves, then quarters ... of the actions before it.
local function Shrink(full, name)
    local tmp = os.tmpname()
    local tries = 0
    local function Fails(l)
        tries = tries + 1
        local f = io.open(tmp, 'w')
        f:write('return ' .. Ser(l))
        f:close()
        local out = Child({ CP_SOAK_REPLAY = tmp, CP_SOAK_SEED = SEED })
        return out:find('REPORT SOAK REPLAY FAIL ' .. name, 1, true) ~= nil
    end
    local cur = full
    local n = 2
    while #cur >= 2 and tries < 60 do
        local size = math.ceil(#cur / n)
        local shrunk = false
        for s = 1, #cur, size do
            local cand = {}
            for i, a in ipairs(cur) do
                if i < s or i >= s + size or i == #cur then cand[#cand + 1] = a end
            end
            if #cand < #cur and Fails(cand) then
                cur, n, shrunk = cand, math.max(n - 1, 2), true
                break
            end
        end
        if not shrunk then
            if size <= 1 then break end
            n = math.min(#cur, n * 2)
        end
    end
    os.remove(tmp)
    return cur
end

if failedAt then
    print(('REPORT SOAK FAIL seed=%d step=%d invariant=%s: %s'):format(SEED, failedAt, failure.name, failure.detail))
    local prefix = {}
    for i = 1, math.min(failedAt, #list) do prefix[i] = list[i] end
    local short = os.getenv('CP_SOAK_NOSHRINK') and prefix or Shrink(prefix, failure.name)
    print(('REPORT SOAK seed=%d: %d actions reproduce it:'):format(SEED, #short))
    for i, a in ipairs(short) do print(('REPORT   %d. %s'):format(i, Ser(a))) end
end
local kinds = {}
for k, n in pairs(counts) do kinds[#kinds + 1] = ('%s=%d/%d'):format(k, okCount[k] or 0, n) end
table.sort(kinds)
print(('REPORT soak seed=%d (%s): %d actions over %.1f simulated hours, %d runs seen'):format(SEED,
    SWITCHES and 'switches on' or 'shipped config', #list, (H.clockMs - startMs) / 3600000, (function()
        local n = 0
        for _ in pairs(runsSeen) do n = n + 1 end
        return n
    end)()))
if os.getenv('CP_SOAK_VERBOSE') then
    print('REPORT succeeded/tried ' .. table.concat(kinds, ' '))
    local r = H.sql('SELECT COUNT(*) AS n, SUM(cash_paid) AS s FROM cp_mission_runs WHERE state = \'completed\'')[1]
    print(('REPORT %d completed rows, $%d paid'):format(Num(r and r.n), Num(r and r.s)))
end
H.ok(failedAt == nil, ('soak: seed %d, every invariant held over %d actions'):format(SEED, #list))

DropCity()
_G.print = W.realPrint

return H
