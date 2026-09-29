-- /CrimsonPoliceAdmin storage and storage copy (modules/admin) with MariaDB and a temporary saves folder together.

local H = dofile('tests/harness.lua')
local WALL = os.time                                                     -- the real clock (H.boot fakes os.time)
local RUNS = math.max(701, tonumber(os.getenv('CP_COPY_RUNS')) or 1203)  -- CP_COPY_RUNS=50000 for a timing at scale
H.useFiles()
local BASE = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_copy'
H.db = BASE
local cjson = require('cjson')

-- oxmysql talks utf8mb4; the harness' mysql CLI would default to latin1 (as in tests/oversight_spec.lua)
do
    local realPopen = io.popen
    io.popen = function(cmd, mode)
        if type(cmd) == 'string' and cmd:match('^mysql %-uroot ') and not cmd:find('default%-character%-set', 1) then
            cmd = cmd:gsub('^mysql %-uroot ', 'mysql --default-character-set=utf8mb4 -uroot ', 1)
        end
        return realPopen(cmd, mode)
    end
end
H.resetDatabase()

-- ============================================================================
--                               CONSOLE CAPTURE
-- ============================================================================
-- Module lines hidden, REPORT and failures shown.

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if os.getenv('E2E_VERBOSE') or not (line:find('crimson%-police') or line:find('Crimson%-Police')) then
        realPrint(line)
    end
end
local function Say(fmt, ...) realPrint(('REPORT storage copy: ' .. fmt):format(...)) end
local function Mark() return #lines end
local function PrintedSince(from, needle)
    for i = from + 1, #lines do
        if lines[i]:find(needle, 1, true) then return lines[i] end
    end
    return nil
end
local function OutputSince(from)
    local out = {}
    for i = from + 1, #lines do out[#out + 1] = lines[i] end
    return table.concat(out, '\n')
end

-- ============================================================================
--                    MariaDB THROUGH THE harness' MYSQL CLI
-- ============================================================================
-- The database H.db names at call time.

local MDB = H.MySQL
local function Mq(sql, params) return MDB.query.await(sql, params) end
local function Lit(v)
    if v == nil then return 'NULL' end
    if type(v) == 'table' then
        return v[1]
    end -- raw SQL, e.g. { 'FROM_UNIXTIME(1789000000)' }
    if type(v) == 'number' then return math.type(v) == 'integer' and ('%d'):format(v) or ('%.2f'):format(v) end
    return '\'' .. tostring(v):gsub('\\', '\\\\'):gsub('\'', '\\\'') .. '\''
end
local function InsertRows(tbl, cols, rows)
    for i = 1, #rows, 200 do
        local tuples = {}
        for r = i, math.min(#rows, i + 199) do
            local vals = {}
            for c = 1, #cols do vals[c] = Lit(rows[r][c]) end
            tuples[#tuples + 1] = '(' .. table.concat(vals, ', ') .. ')'
        end
        Mq(('INSERT INTO %s (%s) VALUES %s'):format(tbl, table.concat(cols, ', '), table.concat(tuples, ', ')))
    end
end
local function At(ts) return { ('FROM_UNIXTIME(%d)'):format(ts) } end

-- ============================================================================
--                               THE SOURCE DATA
-- ============================================================================
-- Every cp_ table, every column type, NULLs, UTF-8, quotes, id gaps, raised counters.

local RUN_COLS = {
    'id',
    'run_uuid',
    'operation_id',
    'mission_type',
    'mission_id',
    'mission_version',
    'location_label',
    'citizenid',
    'department',
    'season_id',
    'participants',
    'departments_n',
    'tier',
    'modifier',
    'state',
    'end_reason',
    'points_base',
    'bonus_points',
    'penalty_points',
    'final_points',
    'cash_base',
    'cash_multiplier',
    'cash_paid',
    'cash_status',
    'duration_s',
    'breakdown',
    'flagged',
    'flag_reason',
    'voided',
    'created_at',
}
local TYPES = { 'patrol', 'training', 'investigation', 'tactical' }
local MISSIONS = { 'beat_patrol', 'evoc_course', 'warrant_service', 'gang_shootout' }
local TIERS = { 'standard', 'reinforced', 'heavy', 'major', 'critical' }
local STATES = { 'completed', 'failed', 'abandoned' }
local CASH = { 'none', 'held', 'paid', 'capped' }
local BREAKDOWN = [[{"runId":"%s","points":{"final":%d,"bonuses":[{"id":"fast_finish","points":12}]},"note":"Zoë \"quoted\" – ok","list":[1,2.5,true,null]}]]
local function RunRow(id, i)
    local uuid = ('%08x-0000-4000-8000-%012x'):format(id, i)
    return {
        id,
        uuid,
        (i % 50 == 0) and 1 or nil,
        TYPES[i % 4 + 1],
        MISSIONS[i % 4 + 1],
        (i % 7 == 0) and 3 or nil,
        (i % 3 == 0) and 'Sandy Shores' or 'Mirror Park – Zoë',
        ('CPY%05d'):format(i % 3 + 1),
        (i % 2 == 0) and 'sast' or 'fib',
        (i % 5 == 0) and nil or 2,
        1 + i % 3,
        1 + i % 2,
        TIERS[i % 5 + 1],
        (i % 11 == 0) and 'rain' or nil,
        STATES[i % 3 + 1],
        STATES[i % 3 + 1],
        60 + i % 40,
        i % 12,
        i % 3,
        60 + i % 50,
        260,
        (i % 4 == 0) and '1.25' or '1.00',
        (i % 3 == 0) and 0 or 260,
        CASH[i % 4 + 1],
        100 + i % 400,
        (i % 9 == 0) and nil or BREAKDOWN:format(uuid, 60 + i % 50),
        (i % 13 == 0) and 1 or 0,
        (i % 13 == 0) and 'too_fast' or nil,
        (i % 17 == 0) and 1 or 0,
        At(1789000000 + i * 97),
    }
end
local runs, archive = {}, {}
for i = 1, 700 do
    runs[#runs + 1] = RunRow(100 + i, i)
end -- ids 101-800
for i = 701, RUNS do
    runs[#runs + 1] = RunRow(1300 + i, i)
end -- ids 2001 and up (a gap of 1200 ids)
for i = 1, 25 do
    archive[#archive + 1] = RunRow(i, RUNS + i)
end                                                                       -- archived ids 1-25
InsertRows('cp_mission_runs', RUN_COLS, runs)
InsertRows('cp_mission_runs_archive', RUN_COLS, archive)
local RUNS_NEXT = math.max(3000, 1300 + RUNS + 497)                       -- above max(id) + 1
Mq(('ALTER TABLE cp_mission_runs AUTO_INCREMENT = %d'):format(RUNS_NEXT))
InsertRows('cp_officers', {
    'citizenid',
    'callsign',
    'rank_label',
    'display_name',
    'department',
    'xp',
    'streak_days',
    'last_complete',
    'grace_week',
    'grace_used',
    'hide_name',
    'suspended_until',
}, {
    { 'CPY00001', '101', 'Sergeant', 'Zoë O\'Brien', 'sast', 1500, 3, '2026-09-20', '2026-09-14', 1, 1, nil },
    { 'CPY00002', nil, nil, 'Dan "The Man"', 'fib', 0, 0, nil, nil, 0, 0, At(1790500000) },
    { 'CPY00003', 'K-9', 'Trooper', 'Back\\slash ü', 'sast', 42, 1, '2026-01-31', nil, 0, 0, nil },
})
InsertRows('cp_seasons', { 'id', 'name', 'starts_at', 'ends_at', 'active' }, {
    { 1, 'Season One', At(1780000000), At(1785000000), 0 },
    { 2, 'Saison Été', At(1785000001), nil, 1 },
})
InsertRows('cp_badges', { 'citizenid', 'badge_id', 'earned_at' }, {
    { 'CPY00001', 'ironWheels', At(1789000100) },
    { 'CPY00001', 'sharpshooter', At(1789000200) },
    { 'CPY00003', 'ironWheels', At(1789000300) },
})
InsertRows('cp_custom_missions', {
    'id',
    'mission_type',
    'status',
    'published_version',
    'published_definition',
    'draft_version',
    'draft_definition',
    'draft_tested',
    'file_path',
    'edited_in_code',
    'locked_by',
    'locked_until',
    'created_by',
    'updated_by',
    'updated_at',
}, {
    {
        'fib_raid',
        'investigation',
        'published',
        3,
        [[{"id":"fib_raid","label":"FIB Raid – Zoë","objectives":[{"type":"checkpoint","points":[1,2.5,-3]}]}]],
        4,
        [[{"id":"fib_raid","draft":true,"note":"say \"hi\""}]],
        1,
        'missions/custom/fib_raid.lua',
        0,
        nil,
        nil,
        'CPY00001',
        'CPY00003',
        At(1789500000),
    },
    {
        'draft_only',
        'patrol',
        'draft',
        nil,
        nil,
        1,
        [[{"id":"draft_only"}]],
        0,
        nil,
        1,
        'CPY00003',
        At(1789600000),
        'CPY00003',
        'CPY00003',
        At(1789500500),
    },
})
InsertRows('cp_dept_bounties', { 'season_id', 'week', 'objective', 'winner' },
    { { 2, 1, 'most_unit', 'sast' }, { 2, 2, 'most_tactical', nil } })
InsertRows('cp_type_payouts', { 'mission_type', 'amount', 'admin_locked', 'updated_by', 'updated_at' },
    { { 'patrol', 260, 1, 'CPY00001', At(1789600000) } })
InsertRows('cp_mission_payouts', { 'mission_id', 'amount', 'set_by', 'updated_at' },
    { { 'gang_shootout', 1200, 'CPY00001', At(1789600100) } })
InsertRows('cp_disputes',
    { 'id', 'run_id', 'citizenid', 'reason', 'goes_to', 'status', 'handled_by', 'created_at', 'handled_at' }, {
        { 1, 105, 'CPY00002', 'I was there, honest – ça va', 'supervisor', 'open', nil, At(1789700000), nil },
        { 2, 106, 'CPY00003', 'Failed run', 'admin', 'rejected', 'CPY00001', At(1789700100), At(1789800000) },
    })
InsertRows('cp_mission_tests', {
    'id',
    'mission_id',
    'mission_version',
    'location_index',
    'tier',
    'testers',
    'result',
    'note',
    'tested_by',
    'created_at',
    'def_hash',
}, { { 1, 'beat_patrol', nil, 2, 'reinforced', 2, 'passed', 'ok', 'CPY00001', At(1789000500), 'abc123' } })
InsertRows('cp_audit',
    { 'id', 'actor', 'role', 'category', 'action', 'target', 'old_value', 'new_value', 'reason', 'created_at' }, {
        { 1, 'CPY00001', 'admin', 'audit', 'setTypePayout', 'patrol', '200', '260', 'raise', At(1789600000) },
        { 2, 'console', 'console', 'builder', 'publish', 'fib_raid', nil, '3', nil, At(1789600050) },
        { 3, 'console', 'console', 'audit', 'reloadMissions', nil, '14', '14 loaded, 0 rejected', nil, At(1789600060) },
    })
Mq('DELETE FROM cp_audit WHERE id = 3') -- the counter stays at 4: a copy must not hand out id 3 again
InsertRows('cp_operations', { 'id', 'mission_id', 'launched_by', 'status', 'created_at', 'ended_at' }, {
    { 1, 'hostage_rescue', 'CPY00001', 'completed', At(1789100000), At(1789101000) },
})
Mq('ALTER TABLE cp_operations AUTO_INCREMENT = 10')
local SOURCE_ROWS = #runs + #archive + 3 + 2 + 3 + 2 + 2 + 1 + 1 + 2 + 1 + 2 + 1   -- every table but cp_schema_migrations
local COPIED_TABLES = 13

-- ============================================================================
--                 COMPARING TABLES (as the modules read them)
-- ============================================================================

local M   -- CP.Storage.MemSQL (set after H.boot)
local function Canon(v)
    if v == nil then return '~' end
    if v == true then return '1' elseif v == false then return '0' end
    if type(v) == 'string' and v:match('^%-?%d+%.?%d*$') then v = tonumber(v) end
    if type(v) == 'number' then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ('%d'):format(v) end
        return ('%.10g'):format(v)
    end
    return tostring(v)
end
local function SelectOf(engine, name)
    local t = engine.tables[name]
    local list, cols = {}, {}
    for i, col in ipairs(t.cols) do
        local q = '`' .. col.name .. '`'
        cols[i] = col.name
        if col.kind == 'dt' then
            list[i] = 'UNIX_TIMESTAMP(' .. q .. ') AS ' .. q
        elseif col.kind == 'date' then
            list[i] = 'DATE_FORMAT(' .. q .. ', \'%Y-%m-%d\') AS ' .. q
        else
            list[i] = q
        end
    end
    return 'SELECT ' .. table.concat(list, ', ') .. ' FROM `' .. name .. '`', cols
end
local function DumpRows(rows, cols, skip)
    local out = {}
    for _, r in ipairs(rows or {}) do
        if not (skip and skip(r)) then
            local parts = {}
            for i, c in ipairs(cols) do parts[i] = Canon(r[c]) end
            out[#out + 1] = table.concat(parts, '|')
        end
    end
    table.sort(out)
    return table.concat(out, '\n'), #out
end
local notCopyAudit = function(r) return r.action == 'storageCopy' end
-- { [table] = { text, n } } of an engine and of MariaDB (H.db), with the engine's column list for both
local function DumpEngine(engine, skipAudit)
    local out = {}
    for _, name in ipairs(engine:tableNames()) do
        if name ~= 'cp_schema_migrations' then
            local sql, cols = SelectOf(engine, name)
            local text, n = DumpRows(M.luaRows(engine:exec(sql)), cols,
                (skipAudit and name == 'cp_audit') and notCopyAudit or nil)
            out[name] = { text = text, n = n }
        end
    end
    return out
end
local function DumpMaria(engine, skipAudit)
    local out = {}
    for _, name in ipairs(engine:tableNames()) do
        if name ~= 'cp_schema_migrations' then
            local sql, cols = SelectOf(engine, name)
            local text, n = DumpRows(Mq(sql), cols, (skipAudit and name == 'cp_audit') and notCopyAudit or nil)
            out[name] = { text = text, n = n }
        end
    end
    return out
end
local function SameTables(a, b, what)
    local compared = 0
    for name, t in pairs(a) do
        compared = compared + 1
        local u = b[name]
        H.eq(u and u.n, t.n, ('%s: %s has the same number of rows'):format(what, name))
        if not H.ok(u ~= nil and u.text == t.text, ('%s: %s has the same rows'):format(what, name)) and u then
            local la, lb = {}, {}
            for l in (t.text .. '\n'):gmatch('(.-)\n') do la[#la + 1] = l end
            for l in (u.text .. '\n'):gmatch('(.-)\n') do lb[#lb + 1] = l end
            for i = 1, math.max(#la, #lb) do
                if la[i] ~= lb[i] then
                    realPrint(('    first difference in %s:\n      %s\n      %s'):format(name, tostring(la[i]),
                        tostring(lb[i])))
                    break
                end
            end
        end
    end
    for name in pairs(b) do if not a[name] then H.ok(false, what .. ': ' .. name .. ' only on one side') end end
    return compared
end
local function MariaNext()
    local out = {}
    for _, r in
        ipairs(Mq(
            'SELECT table_name AS t, auto_increment AS n FROM information_schema.tables WHERE table_schema = DATABASE()'))
    do
        if r.n then out[r.t] = math.tointeger(tonumber(r.n)) end
    end
    return out
end
local function EngineNext(engine)
    local out = {}
    for _, t in ipairs(engine.order) do if t.autoCol then out[t.name] = t.nextId end end
    return out
end
local function RowCount(sql) local r = Mq(sql); return r[1] and tonumber(r[1].n) or 0 end
local function EngineCount(engine, sql) local r = M.luaRows(engine:exec(sql)); return r[1] and tonumber(r[1].n) or 0 end
-- rows of the 13 copied tables (cp_schema_migrations left out), in MariaDB and in an engine
local function MariaTotal(engine)
    local n = 0
    for _, name in ipairs(engine:tableNames()) do
        if name ~= 'cp_schema_migrations' then n = n + RowCount('SELECT COUNT(*) AS n FROM `' .. name .. '`') end
    end
    return n
end
local function EngineTotal(engine)
    local n = 0
    for _, name in ipairs(engine:tableNames()) do
        if name ~= 'cp_schema_migrations' then
            n = n + EngineCount(engine, 'SELECT COUNT(*) AS n FROM `' .. name .. '`')
        end
    end
    return n
end
local function ReadFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end
local function ListDir(d)
    local out = {}
    local p = io.popen(('ls -A \'%s\' 2>/dev/null'):format(d))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    table.sort(out)
    return out
end

-- ============================================================================
--                                 THE RESOURCE
-- ============================================================================
-- Config, shared, storage (files mode), the real migrations runner, CP.Access and CP.Admin.

local notes = {}
local activeList, activeOp = {}, nil
local infos = {
    [1] = {
        src = 1,
        citizenid = 'ADM00001',
        name = 'Ada Min',
        job = { name = 'unemployed', onduty = false, gradeLevel = 0 },
    },
    [2] = {
        src = 2,
        citizenid = 'OFF00002',
        name = 'Olly Officer',
        job = { name = 'sast', onduty = true, gradeLevel = 1 },
    },
}
local function Stubs()
    CP.Qbx = {
        getInfo = function(src) return infos[tonumber(src)] end,
        getByCitizenId = function(cid)
            for s, i in pairs(infos) do if i.citizenid == cid then return s end end
            return nil
        end,
        getOnlinePlayers = function() return { 1, 2 } end,
        onDutyChange = function() end,
        onGroupUpdate = function() end,
        onJobChange = function() end,
        onPlayerLoaded = function() end,
        onPlayerUnload = function() end,
    }
    CP.Tablet = {
        notify = function(src, kind, key, vars)
            notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
            return true
        end,
    }
    CP.Runs = {
        all = function() return activeList end,
    }
    CP.Operations = {
        active = function() return activeOp end,
    }
end
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
H.players[2] = { ace = {} }
local function NotesFor(src, from)
    local out = {}
    for i = (from or 0) + 1, #notes do if notes[i].src == src then out[#out + 1] = notes[i] end end
    return out
end
local function HasNote(list, key)
    for _, n in ipairs(list) do if n.key == key then return n end end
    return nil
end

local function admin(...) return CP.Admin.command(0, { ... }) end
local function Command(src, ...) -- through the registered command (a thread, as FiveM runs it)
    H.commands['CrimsonPoliceAdmin'].fn(src, { ... })
end

-- ============================================================================
--                                1. FILES MODE
-- ============================================================================

H.boot({ side = 'server', realLocale = true })
M = CP.Storage.MemSQL
Stubs()
H.load('modules/migrations/server.lua')   -- the real runner (its CP.Migrations._split splits the copy's migrations)
H.load('modules/access/server.lua')
H.load('modules/admin/server.lua')
H.ok(H.commands['CrimsonPoliceAdmin'] ~= nil, 'the admin command is registered')
H.eq(CP.Storage.mode(), 'files', 'files mode')
H.ok(CP.Migrations.isReady(), 'the migrations found the saves folder built')
local live = CP.Storage.db
local dir = CP.Storage.folder()
H.eq(dir, H.savesDir(), 'the saves folder of this spec')

-- status (console and in game)
local m0 = Mark()
admin('storage')
H.ok(PrintedSince(m0, 'Storage: database off') ~= nil, 'status: the mode')
H.ok(PrintedSince(m0, 'Saves folder: ' .. dir) ~= nil, 'status: the saves folder path')
H.ok(PrintedSince(m0, 'cp_mission_runs: 0 rows') ~= nil, 'status: a line per table')
H.ok(PrintedSince(m0, '14 tables, 2 rows in all.') ~= nil, 'status: 14 tables, the 2 migration rows')
H.ok(PrintedSince(m0, 'Saves folder size: ') ~= nil, 'status: the size of the saves folder')
local n0 = #notes
CP.Admin.command(1, { 'storage' })
local st = NotesFor(1, n0)
H.ok(
    HasNote(st, 'admin.cmd.storage_mode_files') and HasNote(st, 'admin.cmd.storage_total')
        and HasNote(st, 'admin.cmd.storage_size'),
    'in game: the mode, the totals and the size'
)
H.eq(#st, 3, 'in game: three notifications, no per-table lines')
n0 = #notes
CP.Admin.command(2, { 'storage', 'copy', 'database-to-files' })
H.eq(NotesFor(2, n0)[1] and NotesFor(2, n0)[1].key, 'err.not_admin',
    'a player without the crimsonpolice.admin ace is refused')

-- usage and refusals: nothing reaches the saves folder
local function LiveRows()
    return EngineCount(live, 'SELECT COUNT(*) AS n FROM cp_mission_runs')
        + EngineCount(live, 'SELECT COUNT(*) AS n FROM cp_officers')
end
for _, args in ipairs({
    { 'storage', 'copy' },
    { 'storage', 'copy', 'sideways' },
    { 'storage', 'copy', 'database-to-files', 'now' },
    { 'storage', 'copy', 'database-to-files', 'force', 'x' },
    { 'storage', 'status' },
}) do
    m0 = Mark()
    admin(table.unpack(args))
    H.ok(PrintedSince(m0, 'Use /CrimsonPoliceAdmin storage') ~= nil, 'usage for: ' .. table.concat(args, ' '))
end
activeList = { { id = 'run-1', state = 'in_progress' } }
m0 = Mark()
admin('storage', 'copy', 'database-to-files')
H.ok(PrintedSince(m0, 'Active mission runs: 1.') ~= nil, 'refused while a run is active')
activeList, activeOp = {}, { id = 3, status = 'joining' }
m0 = Mark()
admin('storage', 'copy', 'database-to-files', 'force')
H.ok(PrintedSince(m0, 'Active mission runs: 1.') ~= nil, 'refused while a Cross-Department Mission is being set up')
activeOp = nil
local realState = _G.GetResourceState
_G.GetResourceState = function(name) if name == 'oxmysql' then return 'stopped' end return realState(name) end
m0 = Mark()
admin('storage', 'copy', 'database-to-files')
H.ok(PrintedSince(m0, 'oxmysql is not running') ~= nil, 'refused while oxmysql is stopped')
_G.GetResourceState = realState
H.eq(LiveRows(), 0, 'no refused copy wrote anything')

-- database-to-files into the live engine, through the registered command
local mariaBefore = DumpMaria(live)
local nextBefore = MariaNext()
H.eq(MariaTotal(live), SOURCE_ROWS, 'the source rows')
m0 = Mark()
local c0, w0 = os.clock(), WALL()
Command(0, 'storage', 'copy', 'database-to-files')
local tCopy1, wCopy1 = os.clock() - c0, WALL() - w0
local out = OutputSince(m0)
H.ok(out:find('Copied 13 tables and ' .. SOURCE_ROWS .. ' rows from the database to the saves folder', 1, true) ~= nil,
    'database-to-files: the summary (' .. (out:match('Copied[^\n]*') or out:sub(-300)) .. ')')
H.ok(out:find(('cp_mission_runs: %d rows copied'):format(#runs), 1, true) ~= nil, 'a line per table')
H.ok(out:find('Restart Crimson-Police now', 1, true) ~= nil, 'the target is the storage in use: restart')
H.ok(not out:find('now has', 1, true), 'every table has the rows copied')
Say('database -> saves folder (the live engine): %d rows, %.2f s CPU in Crimson-Police, about %d s in all', SOURCE_ROWS,
    tCopy1, wCopy1)
local engineAfter = DumpEngine(live, true)
H.eq(SameTables(mariaBefore, engineAfter, 'database-to-files'), COPIED_TABLES, 'every table compared')
local ids = EngineNext(live)
for _, name in ipairs({
    'cp_mission_runs',
    'cp_mission_runs_archive',
    'cp_seasons',
    'cp_disputes',
    'cp_mission_tests',
    'cp_operations',
}) do
    H.eq(ids[name], nextBefore[name], name .. ': the AUTO_INCREMENT counter is the database\'s')
end
H.eq(ids.cp_mission_runs, RUNS_NEXT, 'the raised runs counter (not max(id) + 1) is kept')
local copyRow = M.luaRows(live:exec(
    'SELECT id, actor, role, category, target, old_value, new_value FROM cp_audit WHERE action = \'storageCopy\''))
H.eq(#copyRow, 1, 'the copy is in the audit log of the storage in use')
H.eq(copyRow[1] and copyRow[1].id, 4, 'with the next id the database would give (id 3 is never handed out again)')
H.eq(copyRow[1] and copyRow[1].actor, 'console', 'actor console')
H.eq(copyRow[1] and copyRow[1].target, 'database-to-files', 'target = the direction')
H.eq(copyRow[1] and copyRow[1].old_value, nil, 'nothing replaced')
H.eq(copyRow[1] and copyRow[1].new_value, ('13 tables, %d rows'):format(SOURCE_ROWS), 'new value = the tables and rows')
H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\''), 0,
    'the source database was only read')
H.eq(SameTables(mariaBefore, DumpMaria(live), 'the source after the copy'), COPIED_TABLES, 'the source is unchanged')

-- the saves folder: split documents, valid JSON, nothing left over, a reload reads the same
local names = ListDir(dir)
local has = {}
for _, n in ipairs(names) do has[n] = true end
for _, n in ipairs({
    'mission_runs_1.json',
    'mission_runs_2.json',
    'mission_runs_5.json',
    'mission_runs_archive.json',
    'officers.json',
    'custom_missions.json',
    'audit.json',
    '_tables.json',
}) do
    H.ok(has[n], 'saves/' .. n .. ' written')
end
for _, n in ipairs(names) do
    H.ok(not n:match('%.tmp$') and not n:match('%.bak$'), 'no leftover ' .. n)
    if n:match('%.json$') then H.ok(pcall(cjson.decode, ReadFile(dir .. '/' .. n)), n .. ' is valid JSON') end
end
local tables = cjson.decode(ReadFile(dir .. '/_tables.json'))
local nextInFile = {}
for _, t in ipairs(tables.tables) do nextInFile[t.name] = t.next end
H.eq(nextInFile.cp_mission_runs, RUNS_NEXT, '_tables.json keeps the runs counter')
local reloaded = M.new({ store = M.folderStore(dir) }):load()
H.eq(SameTables(DumpEngine(live), DumpEngine(reloaded), 'a reload of the saves folder'), COPIED_TABLES,
    'the saves folder reads back the same')
H.eq(EngineNext(reloaded).cp_mission_runs, RUNS_NEXT, 'and the counter')

-- a second copy without force: refused, nothing changed
local liveDump = DumpEngine(live)
m0 = Mark()
admin('storage', 'copy', 'database-to-files')
out = OutputSince(m0)
H.eq(EngineTotal(live), SOURCE_ROWS + 1, 'the saves folder has the source rows and the audit entry')
H.ok(out:find('The saves folder already has ' .. (SOURCE_ROWS + 1) .. ' rows', 1, true) ~= nil,
    'a target with rows is refused: ' .. out:sub(1, 200))
H.ok(out:find('storage copy database-to-files force', 1, true) ~= nil, 'the refusal names the force command')
H.eq(SameTables(liveDump, DumpEngine(live), 'after the refusal'), COPIED_TABLES, 'nothing changed')

-- force, from an admin in game: the target becomes the (changed) source
Mq('DELETE FROM cp_officers WHERE citizenid = \'CPY00003\'')
Mq('UPDATE cp_mission_runs SET final_points = 99, flagged = 1 WHERE id = ?', { 1300 + RUNS })
Mq('UPDATE cp_custom_missions SET draft_definition = \'{"id":"fib_raid","v":5}\' WHERE id = \'fib_raid\'')
mariaBefore = DumpMaria(live)
local expected = MariaTotal(live)
n0 = #notes
Command(1, 'storage', 'copy', 'database-to-files', 'force')
local inGame = NotesFor(1, n0)
H.ok(HasNote(inGame, 'admin.cmd.storage_copy_started') ~= nil, 'in game: copy started')
local done = HasNote(inGame, 'admin.cmd.storage_copied')
H.ok(done ~= nil, 'in game: copied')
H.eq(done and done.vars.rows, expected, 'in game: the rows copied')
H.ok(HasNote(inGame, 'admin.cmd.storage_next_restart') ~= nil, 'in game: restart now')
H.eq(SameTables(mariaBefore, DumpEngine(live, true), 'force'), COPIED_TABLES,
    'force: the saves folder holds exactly the database')
copyRow = M.luaRows(live:exec('SELECT actor, role, old_value FROM cp_audit WHERE action = \'storageCopy\''))
H.eq(#copyRow, 1, 'force replaced the earlier audit rows too; one new entry')
H.eq(copyRow[1] and copyRow[1].actor, 'ADM00001', 'actor = the admin\'s citizenid')
H.eq(copyRow[1] and copyRow[1].role, 'admin', 'role admin')
H.eq(copyRow[1] and copyRow[1].old_value, ('replaced %d rows'):format(SOURCE_ROWS + 1), 'old value = the rows replaced')

-- a copy that fails half way (a zero date the saves folder cannot hold): the target is emptied, the source unchanged
Mq('UPDATE cp_officers SET last_complete = \'0000-00-00\' WHERE citizenid = \'CPY00002\'')
local mariaZero = DumpMaria(live)
m0 = Mark()
admin('storage', 'copy', 'database-to-files', 'force')
out = OutputSince(m0)
H.ok(out:find('The copy stopped at cp_officers', 1, true) ~= nil, 'the failure names the table: ' .. out:sub(1, 300))
H.ok(out:find('does not support', 1, true) ~= nil, 'and the reason')
H.ok(out:find('The saves folder was emptied again and the database is unchanged', 1, true) ~= nil, 'and what it did')
local emptied = 0
for _, name in ipairs(live:tableNames()) do
    if name ~= 'cp_schema_migrations' then
        emptied = emptied + EngineCount(live, 'SELECT COUNT(*) AS n FROM `' .. name .. '`')
    end
end
H.eq(emptied, 0, 'every table of the saves folder is empty')
H.eq(EngineCount(live, 'SELECT COUNT(*) AS n FROM cp_schema_migrations'), 2, 'the migration record stays')
reloaded = M.new({ store = M.folderStore(dir) }):load()
H.eq(EngineCount(reloaded, 'SELECT COUNT(*) AS n FROM cp_mission_runs'), 0, 'and it is saved empty')
H.eq(SameTables(mariaZero, DumpMaria(live), 'the source after the failure'), COPIED_TABLES, 'the database is unchanged')
Mq('UPDATE cp_officers SET last_complete = NULL WHERE citizenid = \'CPY00002\'')
mariaBefore = DumpMaria(live)
m0 = Mark()
admin('storage', 'copy', 'database-to-files')
H.ok(PrintedSince(m0, 'Copied 13 tables') ~= nil, 'after the fix the copy needs no force (the target is empty)')
H.eq(SameTables(mariaBefore, DumpEngine(live, true), 'after the fix'), COPIED_TABLES,
    'the saves folder holds the database')

-- files-to-database into an empty MariaDB database: the migrations create the tables first
local engineDump = DumpEngine(live, true)
local engineIds = EngineNext(live)
expected = EngineTotal(live)
H.db = BASE .. '_empty'
os.execute(
    ('mysql -uroot -e "DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(H.db, H.db))
m0 = Mark()
c0, w0 = os.clock(), WALL()
admin('storage', 'copy', 'files-to-database')
local tCopy2, wCopy2 = os.clock() - c0, WALL() - w0
out = OutputSince(m0)
H.ok(out:find('Copied 13 tables and ' .. expected .. ' rows from the saves folder to the database', 1, true) ~= nil,
    'files-to-database into an empty database: ' .. (out:match('Copied[^\n]*') or out:sub(1, 300)))
H.ok(out:find('set Config.Database.enabled = true', 1, true) ~= nil, 'the target is not in use: how to switch')
Say(
    'saves folder -> database (an empty database, tables created first): %d rows, %.2f s CPU in Crimson-Police, about %d s in all',
    expected, tCopy2, wCopy2)
H.eq(RowCount('SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE()'), 14,
    'the 14 tables were created')
local applied = Mq('SELECT version, name FROM cp_schema_migrations ORDER BY version')
H.eq(#applied, 2, 'with both migrations recorded')
H.eq(applied[2] and applied[2].name, '002_test_def_hash.sql', 'the 002 migration ran (def_hash exists)')
H.eq(SameTables(engineDump, DumpMaria(live, true), 'files-to-database'), COPIED_TABLES,
    'the new database holds the saves folder')
local newIds = MariaNext()
for name, n in pairs(engineIds) do
    if name ~= 'cp_audit' then H.eq(newIds[name], n, name .. ': the counter came along') end
end
H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\' AND target = \'files-to-database\''),
    1, 'the copy is also in the audit log of the database it filled')
H.eq(EngineCount(
    live,
    'SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\' AND target = \'files-to-database\''
), 1, 'and in the storage in use')

-- files-to-database back into the first database (it has rows): refused, then force
H.db = BASE
m0 = Mark()
admin('storage', 'copy', 'files-to-database')
H.ok(PrintedSince(m0, 'The database already has') ~= nil, 'a database with rows is refused')
Mq('UPDATE cp_seasons SET name = ? WHERE id = 1', { 'Changed in MariaDB' })
engineDump = DumpEngine(live, true)
m0 = Mark()
admin('storage', 'copy', 'files-to-database', 'force')
H.ok(PrintedSince(m0, 'Copied 13 tables') ~= nil, 'force: copied')
H.eq(SameTables(engineDump, DumpMaria(live, true), 'files-to-database force'), COPIED_TABLES,
    'force: the database holds the saves folder')
H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_seasons WHERE name = \'Changed in MariaDB\''), 0,
    'the database\'s own change was replaced')

-- ============================================================================
--                 2. DATABASE MODE (an absolute saves folder)
-- ============================================================================

H.restart()
H.storage = 'database'
H.boot({ side = 'server', realLocale = true })
H.load('modules/storage/memsql.lua')  -- what fxmanifest loads right after @oxmysql/lib/MySQL.lua
H.load('modules/storage/server.lua')
M = CP.Storage.MemSQL
Stubs()
H.load('modules/access/server.lua')
H.load('modules/admin/server.lua')    -- CP.Migrations is the harness stub here: the copy splits the files itself
H.eq(CP.Storage.mode(), 'database', 'database mode')
local folder2 = H.resourcePath() .. '/backup saves'
Config.Database.folder = folder2

m0 = Mark()
admin('storage')
out = OutputSince(m0)
H.ok(out:find('Storage: the database', 1, true) ~= nil, 'status: database mode')
H.ok(out:find('Saves folder: ' .. folder2 .. ' (not used while Config.Database.enabled = true)', 1, true) ~= nil,
    'status: the absolute folder, not in use')
H.ok(out:find(('cp_mission_runs: %d rows'):format(#runs), 1, true) ~= nil, 'status: the database\'s rows')
H.ok(out:find('The saves folder holds no Crimson-Police data yet.', 1, true) ~= nil, 'status: the folder is empty')

m0 = Mark()
admin('storage', 'copy', 'files-to-database')
H.ok(PrintedSince(m0, 'holds no Crimson-Police data') ~= nil, 'files-to-database from an empty folder is refused')

-- database-to-files into a new folder: built by the migrations, then filled
expected = nil
do
    local r = Mq(
        'SELECT SUM(n) AS n FROM (SELECT COUNT(*) AS n FROM cp_audit UNION ALL SELECT COUNT(*) FROM cp_badges UNION ALL SELECT COUNT(*) FROM cp_custom_missions'
            .. ' UNION ALL SELECT COUNT(*) FROM cp_dept_bounties UNION ALL SELECT COUNT(*) FROM cp_disputes UNION ALL SELECT COUNT(*) FROM cp_mission_payouts'
            .. ' UNION ALL SELECT COUNT(*) FROM cp_mission_runs UNION ALL SELECT COUNT(*) FROM cp_mission_runs_archive UNION ALL SELECT COUNT(*) FROM cp_mission_tests'
            .. ' UNION ALL SELECT COUNT(*) FROM cp_officers UNION ALL SELECT COUNT(*) FROM cp_operations UNION ALL SELECT COUNT(*) FROM cp_seasons'
            .. ' UNION ALL SELECT COUNT(*) FROM cp_type_payouts) x'
    )
    expected = tonumber(r[1].n)
end
local copies = RowCount('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\'')
m0 = Mark()
admin('storage', 'copy', 'database-to-files')
out = OutputSince(m0)
H.ok(out:find('Copied 13 tables and ' .. expected .. ' rows from the database to the saves folder', 1, true) ~= nil,
    'database mode, database-to-files: ' .. (out:match('Copied[^\n]*') or out:sub(1, 300)))
H.ok(out:find('set Config.Database.enabled = false', 1, true) ~= nil, 'how to switch to the saves folder')
local folderDb = M.new({ store = M.folderStore(folder2) }):load()
H.eq(#folderDb:tableNames(), 14, 'the new saves folder has every table')
H.eq(EngineCount(folderDb, 'SELECT COUNT(*) AS n FROM cp_schema_migrations'), 2, 'and both migrations')
H.eq(SameTables(DumpMaria(folderDb, true), DumpEngine(folderDb, true), 'database mode, database-to-files'),
    COPIED_TABLES, 'the folder holds the database')
H.eq(EngineNext(folderDb).cp_mission_runs, RUNS_NEXT, 'the runs counter came along')
H.eq(EngineCount(folderDb, 'SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\''), copies + 1,
    'the copy is in the new folder\'s audit log (the copied entries and its own)')
H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'storageCopy\''), copies + 1,
    'and in the database\'s')
m0 = Mark()
admin('storage')
H.ok(PrintedSince(m0, 'Saves folder size: ') ~= nil, 'status: the folder now has a size')

-- files-to-database: refused (the database has rows), then force replaces the database's changes
m0 = Mark()
admin('storage', 'copy', 'files-to-database')
H.ok(PrintedSince(m0, 'The database already has') ~= nil, 'refused without force')
Mq('DELETE FROM cp_badges')
Mq('UPDATE cp_officers SET xp = 1 WHERE citizenid = ?', { 'CPY00001' })
local folderDump = DumpEngine(folderDb, true)
m0 = Mark()
admin('storage', 'copy', 'files-to-database', 'force')
out = OutputSince(m0)
H.ok(out:find('Copied 13 tables', 1, true) ~= nil, 'force: copied')
H.ok(out:find('Restart Crimson-Police now', 1, true) ~= nil, 'the database is in use: restart')
H.eq(SameTables(folderDump, DumpMaria(folderDb, true), 'database mode, files-to-database force'), COPIED_TABLES,
    'the database holds the folder again')
H.eq(RowCount('SELECT xp AS n FROM cp_officers WHERE citizenid = \'CPY00001\''), 1500,
    'the database\'s change was replaced')

-- files-to-database force into the database in use while the server keeps writing: an officer logs in and gets
-- XP (their cp_officers row) after the copy emptied the tables, before it reaches cp_officers. The copy still
-- finishes, and the database is not left empty.
do
    local officers = EngineCount(folderDb, 'SELECT COUNT(*) AS n FROM cp_officers')
    local realAwait = MySQL.query.await
    local wrote = false
    MySQL.query.await = function(sql, params)
        if not wrote and type(sql) == 'string' and sql:find('INSERT INTO `cp_officers`', 1, true) == 1 then
            wrote = true
            realAwait('INSERT INTO cp_officers (citizenid, xp) VALUES (?, 7) ON DUPLICATE KEY UPDATE xp = xp + 7',
                { 'CPY00001' })
        end
        return realAwait(sql, params)
    end
    m0 = Mark()
    local okCopy, errCopy = pcall(admin, 'storage', 'copy', 'files-to-database', 'force')
    MySQL.query.await = realAwait
    out = OutputSince(m0)
    H.ok(okCopy, 'the copy ran (' .. tostring(errCopy) .. ')')
    H.ok(wrote, 'the other write happened during the copy')
    H.ok(out:find('Copied 13 tables', 1, true) ~= nil,
        'a row written during the copy does not stop it: ' .. (out:match('[^\n]*failed[^\n]*') or out:sub(1, 300)))
    H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_officers'), officers, 'the database keeps every officer')
    H.eq(RowCount('SELECT COUNT(*) AS n FROM cp_mission_runs'), #runs, 'and every run')
    H.eq(RowCount('SELECT xp AS n FROM cp_officers WHERE citizenid = \'CPY00001\''), 1500,
        'the copied row replaces the one written during the copy')
end

-- the default folder is the resource's saves folder
Config.Database.folder = 'saves'
m0 = Mark()
admin('storage')
H.ok(PrintedSince(m0, 'Saves folder: ' .. H.resourcePath() .. '/saves (not used') ~= nil,
    'saves = the folder inside the resource')

-- FXServer refuses os.execute (EACCES, it runs nothing) and has os.createdir (one folder per call): a missing
-- saves folder, its parent missing too, is still created for database-to-files
do
    local realExecute, realCreatedir = os.execute, os.createdir
    os.createdir = function(path)
        if realExecute(('mkdir \'%s\' 2>/dev/null'):format((path:gsub('\'', '\'\\\'\'')))) then return true end
        return nil, path .. ': Directory already exists.'
    end
    os.execute = function() return nil, 'Permission denied', 13 end
    local folder3 = H.resourcePath() .. '/fx saves/live'
    Config.Database.folder = folder3
    m0 = Mark()
    local okCopy, errCopy = pcall(admin, 'storage', 'copy', 'database-to-files')
    os.execute, os.createdir = realExecute, realCreatedir
    out = OutputSince(m0)
    H.ok(okCopy, 'the copy ran (' .. tostring(errCopy) .. ')')
    local copied = out:match('Copied[^\n]*') or out:sub(1, 300)
    H.ok(out:find('Copied 13 tables', 1, true) ~= nil,
        'FXServer: the missing folder is made with os.createdir (' .. copied .. ')')
    H.eq(#M.new({ store = M.folderStore(folder3) }):load():tableNames(), 14, 'and holds every table')
    Config.Database.folder = 'saves'
end

return H
