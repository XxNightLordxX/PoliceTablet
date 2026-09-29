-- tests/run.lua · runs every tests/*_spec.lua in a fresh Lua state and prints a summary.
--   lua5.4 tests/run.lua                    (all specs)
--   lua5.4 tests/run.lua scoring            (only specs whose file name contains "scoring")
--   lua5.4 tests/run.lua --storage=files    (database off: every spec on the saves folder engine; = CP_TEST_STORAGE=files)
--   lua5.4 tests/run.lua --storage=shadow   (MariaDB answers; every statement is also compared on an oxmysql twin and
--                                            the engine, 0 differences expected; = CP_TEST_STORAGE=shadow)
--   lua5.4 tests/run.lua --fuzz[=N]         (shadow mode on tests/shadow/fuzz_*.lua, random SQL, seeds 1..N, default 3)
-- The filter and --storage combine (lua5.4 tests/run.lua --storage=files storage). New or changed SQL must pass in all
-- three modes (docs/ARCHITECTURE.md §5.29, §11).
-- Each spec file is a plain script: local H = dofile('tests/harness.lua'); H.boot{...}; ... H.eq(...)
-- and must end with `return H`. Every run gets its own MariaDB database, rebuilt from sql/migrations first.
-- Storage modes (tests/harness.lua has the details):
--   database  (default) MySQL and H.sql go to MariaDB.
--   files     Config.Database.enabled = false: everything goes to the saves folder engine (CP.Storage.MemSQL); the
--             run's saves folders live in one temporary folder that is removed at the end.
--   shadow    the specs run as in database mode, and every statement also runs in lockstep on a MariaDB twin
--             (read the way oxmysql reads it, tests/shadow/twin.cjs) and on the saves folder engine; every
--             difference is appended to CP_SHADOW_REPORT (default /tmp/cp_shadow_<run database>.jsonl),
--             summarised at the end. Needs node and tests/shadow/node_modules (cd tests/shadow && npm install).
-- A check skipped in a mode (H.skipIn) prints a SKIP line; every skip is listed at the end. A spec's REPORT lines
-- (timings and sizes of tests/storage_spec.lua and tests/storage_copy_spec.lua) are shown under its result.

local base = (debug.getinfo(1, 'S').source:match('^@(.*)/run%.lua$') or 'tests')

local filter, storage, child, fuzz = nil, os.getenv('CP_TEST_STORAGE'), nil, nil
do
    local i = 1
    while arg[i] do
        local a = arg[i]
        local st = a:match('^%-%-storage=(.*)$')
        if st then
            storage = st
        elseif a == '--fuzz' or a:match('^%-%-fuzz=%d+$') then
            fuzz = tonumber(a:match('=(%d+)$')) or 3
            storage = 'shadow'
        elseif a == '--child' then
            child = arg[i + 1]
            i = i + 1
        else
            filter = a
        end
        i = i + 1
    end
end
if not storage or storage == '' then storage = 'database' end
if storage ~= 'database' and storage ~= 'files' and storage ~= 'shadow' then
    print(("unknown storage mode '%s': use --storage=database (default), --storage=files or --storage=shadow"):format(storage))
    os.exit(2)
end

-- ── one spec (a child process of the run below) ──
if child then
    package.path = package.path .. ';tests/?.lua'
    local ok, H = pcall(dofile, child)
    if not ok then print('ERROR ' .. tostring(H)); os.exit(2) end
    if H.shadowFinish then
        local okF, errF = pcall(H.shadowFinish)
        if not okF then print('ERROR shadow table check: ' .. tostring(errF)); os.exit(2) end
    end
    print(('RESULT %d %d'):format(H.passes, H.failures))
    os.exit(H.failures > 0 and 1 or 0)
end

local p = io.popen('ls ' .. base .. (fuzz and '/shadow/fuzz_*.lua' or '/*_spec.lua') .. ' 2>/dev/null')
local files = {}
for line in p:lines() do
    if not filter or line:find(filter, 1, true) then files[#files + 1] = line end
end
p:close()
local seeds = {}   -- file index -> FUZZ_SEED
if fuzz then
    local list = {}
    for seed = 1, fuzz do
        for _, f in ipairs(files) do list[#list + 1] = f; seeds[#list] = seed end
    end
    files = list
end

-- Every run gets its own database (parallel runs never wipe each other's data),
-- built from sql/migrations and dropped at the end (with the per-spec and twin databases named after it).
local dbName = os.getenv('CP_TEST_DB')
local ownDb = false
if not dbName then
    local rnd = io.open('/dev/urandom', 'rb')
    local bytes = rnd and rnd:read(4) or tostring(os.time())
    if rnd then rnd:close() end
    local n = 0
    for i = 1, #bytes do n = n * 256 + bytes:byte(i) end
    dbName = ('cp_test_%d_%d'):format(os.time(), n % 1000000)
    ownDb = true
end
local savesRoot = nil
if storage ~= 'database' then
    savesRoot = os.getenv('CP_TEST_SAVES')
    if not savesRoot or savesRoot == '' then
        savesRoot = os.tmpname()
        os.remove(savesRoot)
        os.execute(("mkdir -p '%s'"):format(savesRoot))
    end
end
local report = nil
if storage == 'shadow' then
    report = os.getenv('CP_SHADOW_REPORT')
    if not report or report == '' then report = ('/tmp/cp_shadow_%s.jsonl'):format(dbName) end
    os.remove(report)
    os.remove(report .. '.stats')
end

local env = ("CP_TEST_DB='%s' CP_TEST_STORAGE='%s'"):format(dbName, storage)
if savesRoot then env = env .. (" CP_TEST_SAVES='%s'"):format(savesRoot) end
if report then env = env .. (" CP_SHADOW_REPORT='%s'"):format(report) end

print(('storage mode: %s%s'):format(storage,
    storage == 'files' and ' (Config.Database.enabled = false: the saves folder engine)'
    or storage == 'shadow' and (' (MariaDB answers; the twin and the engine are compared, report %s)'):format(report)
    or ' (MariaDB)'))

-- The run database (and, in files / shadow mode, its saves folder and twin), in a child like every spec.
do
    local cmd = ('cd %s/.. && %s lua5.4 -e "package.path=package.path..\';tests/?.lua\'" -e "local H = dofile(\'tests/harness.lua\'); H.resetDatabase(); H.shadowFinish()" 2>&1'):format(base, env)
    local h = io.popen(cmd)
    local out = h:read('a')
    if not h:close() then print('could not build the run database: ' .. out); os.exit(2) end
end

local totalPass, totalFail, broken, skips = 0, 0, {}, {}
for fi, file in ipairs(files) do
    -- Fresh globals per spec: run it in a child process for isolation.
    local seedEnv = seeds[fi] and (' FUZZ_SEED=%d'):format(seeds[fi]) or ''
    local cmd = ('cd %s/.. && %s%s lua5.4 tests/run.lua --child %s 2>&1'):format(base, env, seedEnv, file)
    local h = io.popen(cmd)
    local out = h:read('a')
    h:close()
    local reports = {}
    for line in out:gmatch('[^\n]+') do
        if line:match('^SKIP ') then skips[#skips + 1] = line:sub(6) end
        if line:match('^REPORT ') then reports[#reports + 1] = '    ' .. line:sub(8) end
    end
    local pass, fail = out:match('RESULT (%d+) (%d+)')
    pass, fail = tonumber(pass), tonumber(fail)
    if not pass then
        broken[#broken + 1] = file
        print(('✗ %s crashed:\n%s'):format(file, out))
    else
        totalPass, totalFail = totalPass + pass, totalFail + fail
        local mark = fail == 0 and '✓' or '✗'
        print(('%s %s%s  %d passed, %d failed'):format(mark, file, seeds[fi] and (' (seed %d)'):format(seeds[fi]) or '', pass, fail))
        if fail > 0 then print(out) elseif #reports > 0 then print(table.concat(reports, '\n')) end
    end
end

-- Drop the run database and every database named after it (per-spec databases, shadow twins).
if ownDb then
    local like = dbName:gsub('_', '\\\\_') .. '\\\\_%'
    local h = io.popen(('mysql -uroot -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name = \'%s\' OR schema_name LIKE \'%s\'" 2>/dev/null'):format(dbName, like))
    local names = {}
    for line in h:lines() do names[#names + 1] = line end
    h:close()
    for _, name in ipairs(names) do os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS \\`%s\\`;"'):format(name)) end
end
if savesRoot and not os.getenv('CP_TEST_SAVES') then os.execute(("rm -rf '%s'"):format(savesRoot)) end

if #skips > 0 then
    print(('\n%d skipped check%s:'):format(#skips, #skips == 1 and '' or 's'))
    for _, s in ipairs(skips) do print('  ' .. s) end
end

local shadowDiffs = 0
if report then
    local cjson = require('cjson')
    local byCat, bySpec, compared, skipped, skipReasons = {}, {}, 0, 0, {}
    local f = io.open(report .. '.stats', 'r')
    if f then
        for line in f:lines() do
            local ok, st = pcall(cjson.decode, line)
            if ok then
                compared = compared + (st.compared or 0)
                skipped = skipped + (st.skipped or 0)
                for _, sk in ipairs(type(st.skips) == 'table' and st.skips or {}) do
                    skipReasons[#skipReasons + 1] = ('%s: %s: %s'):format(st.spec, sk.reason, sk.sql)
                end
            end
        end
        f:close()
    end
    f = io.open(report, 'r')
    if f then
        for line in f:lines() do
            local ok, d = pcall(cjson.decode, line)
            if ok then
                shadowDiffs = shadowDiffs + 1
                byCat[d.category] = (byCat[d.category] or 0) + 1
                bySpec[d.spec] = (bySpec[d.spec] or 0) + 1
            end
        end
        f:close()
    end
    print(('\nshadow: %d statements compared, %d differences, %d skipped; report %s'):format(compared, shadowDiffs, skipped, report))
    local cats = {}
    for k, v in pairs(byCat) do cats[#cats + 1] = ('%s %d'):format(k, v) end
    table.sort(cats)
    if #cats > 0 then print('  by category: ' .. table.concat(cats, ', ')) end
    local specs = {}
    for k, v in pairs(bySpec) do specs[#specs + 1] = ('%s %d'):format(k, v) end
    table.sort(specs)
    if #specs > 0 then print('  by spec: ' .. table.concat(specs, ', ')) end
    for _, s in ipairs(skipReasons) do print('  skipped ' .. s) end
end

print(('\n%d specs, %d assertions passed, %d failed, %d crashed (storage: %s)'):format(#files, totalPass, totalFail, #broken, storage))
os.exit((totalFail == 0 and #broken == 0 and shadowDiffs == 0) and 0 or 1)
