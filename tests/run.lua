-- Runs every tests/*_spec.lua in a fresh Lua state and prints a summary.

local base = (debug.getinfo(1, 'S').source:match('^@(.*)/run%.lua$') or 'tests')

local filter, storage, child, fuzz = nil, os.getenv('CP_TEST_STORAGE'), nil, nil
local jobs = tonumber(os.getenv('CP_TEST_JOBS') or '')
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
        elseif a:match('^%-%-jobs=%d+$') then
            jobs = tonumber(a:match('=(%d+)$'))
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
    print(('unknown storage mode \'%s\': use --storage=database (default), --storage=files or --storage=shadow'):format(
        storage))
    os.exit(2)
end
jobs = math.max(1, math.floor(jobs or 2))

-- ============================================================================
--                 ONE SPEC (a child process of the run below)
-- ============================================================================

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

-- ============================================================================
--                      WHAT EVERY RUN NEEDS, CHECKED ONCE
-- ============================================================================
-- A missing piece would otherwise crash every spec.

local function Shell(cmd)
    local h = io.popen(cmd .. ' 2>&1')
    local out = h:read('a')
    return h:close(), (out:gsub('%s+$', ''))
end
local mariadb = nil
do
    local missing = {}
    local function Need(what) missing[#missing + 1] = what end
    if _VERSION ~= 'Lua 5.4' then Need(('Lua 5.4 (this is %s): run lua5.4 tests/run.lua'):format(_VERSION)) end
    if not Shell('command -v lua5.4') then Need('lua5.4 on PATH (every spec runs in a lua5.4 child)') end
    if not pcall(require, 'cjson') then Need('lua-cjson for Lua 5.4 (require(\'cjson\') failed)') end
    if not Shell('command -v mkfifo') then
        Need('mkfifo (coreutils): the harness keeps one mysql client open per spec')
    end
    local ok, out = Shell('mysql -uroot -N -e "SELECT VERSION(), TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), NOW())"')
    local offset = ok and tonumber(out:match('\t(%-?%d+)$'))
    if offset then
        mariadb = out:match('^[^\t]*')
        if offset ~= 0 then
            -- the saves folder engine reads dates in the specs' zone (UTC), MariaDB in its own
            local zone = ('the MariaDB session time zone is UTC%+.1f h, not UTC'):format(offset / 3600)
            if storage == 'shadow' then
                Need(zone .. ' (shadow mode compares dates): set default-time-zone = \'+00:00\' in the server')
            else
                mariadb = mariadb .. ' (' .. zone .. ')'
            end
        end
    else
        Need('MariaDB through the mysql CLI as root (mysql -uroot): ' .. out)
    end
    if storage == 'shadow' then
        local nodePath = os.getenv('CP_SHADOW_NODE_PATH')
        local envs = (nodePath and nodePath ~= '') and ('NODE_PATH=\'' .. nodePath .. '\' ') or ''
        ok, out = Shell(('cd \'%s/shadow\' && %snode -e "require(\'mysql2/promise\')"'):format(base, envs))
        if not ok then
            Need('node and the mysql2 package (cd tests/shadow && npm ci): ' .. (out:match('Error: [^\n]*') or out))
        end
    end
    if jobs > 1 and not Shell('command -v xargs') then Need('xargs (findutils) for --jobs; or run with --jobs=1') end
    if #missing > 0 then
        print('tests/run.lua cannot start, missing or not working:')
        for _, m in ipairs(missing) do print('  - ' .. m) end
        print('tools/setup_test_env.sh checks the whole test environment and says how to fix it (docs/TESTING.md).')
        os.exit(2)
    end
end

-- LC_ALL=C and TZ=UTC for ls and every child, so every machine runs the specs the same way: the mysql CLI picks
-- its charset from the locale (latin1 under C, utf8mb3 under C.UTF-8), and dates are UTC dates unless
-- CP_TEST_TZ names another zone (the specs pass in any zone; shadow mode compares MariaDB's UTC dates with the
-- engine's, so it always runs UTC).
local tz = os.getenv('CP_TEST_TZ')
if not tz or tz == '' then tz = 'UTC' end
if not tz:match('^[%w_/+%-:]+$') then print(('CP_TEST_TZ \'%s\' is not a time zone name'):format(tz)); os.exit(2) end
if storage == 'shadow' and tz ~= 'UTC' then
    print(('shadow mode runs the specs with TZ=UTC (MariaDB compares in UTC), not CP_TEST_TZ=%s'):format(tz))
    tz = 'UTC'
end
local p = io.popen('LC_ALL=C ls ' .. base .. (fuzz and '/shadow/fuzz_*.lua' or '/*_spec.lua') .. ' 2>/dev/null')
local files = {}
for line in p:lines() do
    if not filter or line:find(filter, 1, true) then files[#files + 1] = line end
end
p:close()
if #files == 0 then
    print(filter and ('no spec file name contains \'%s\''):format(filter) or 'no spec files found in ' .. base)
    os.exit(2)
end
-- CP_TEST_ORDER=reverse or shuffle[:seed]: another spec order (the specs must not depend on it).
local order = os.getenv('CP_TEST_ORDER')
if order == 'reverse' then
    for i = 1, #files // 2 do files[i], files[#files + 1 - i] = files[#files + 1 - i], files[i] end
elseif order and order:match('^shuffle') then
    local seed = tonumber(order:match(':(%d+)$')) or os.time()
    math.randomseed(seed)
    for i = #files, 2, -1 do
        local j = math.random(1, i)
        files[i], files[j] = files[j], files[i]
    end
    print(('spec order: shuffle, seed %d'):format(seed))
end
local seeds = {}   -- file index -> FUZZ_SEED
if fuzz then
    local list = {}
    for seed = 1, fuzz do
        for _, f in ipairs(files) do list[#list + 1] = f; seeds[#list] = seed end
    end
    files = list
end
if jobs > #files then jobs = #files end

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
-- The run's saves folders live in one temporary folder removed at the end. In database mode every spec gets
-- its own subfolder (a spec that writes a saves folder starts from an empty one, as on its own).
local savesRoot = os.getenv('CP_TEST_SAVES')
local ownSaves = not savesRoot or savesRoot == ''
if ownSaves then
    savesRoot = os.tmpname()
    os.remove(savesRoot)
    os.execute(('mkdir -p \'%s\''):format(savesRoot))
end
local report = nil
if storage == 'shadow' then
    report = os.getenv('CP_SHADOW_REPORT')
    if not report or report == '' then report = ('/tmp/cp_shadow_%s.jsonl'):format(dbName) end
    os.remove(report)
    os.remove(report .. '.stats')
end

local env = ('LC_ALL=C TZ=\'%s\' CP_TEST_DB=\'%s\' CP_TEST_STORAGE=\'%s\''):format(tz, dbName, storage)
if storage ~= 'database' then env = env .. (' CP_TEST_SAVES=\'%s\''):format(savesRoot) end
if report then env = env .. (' CP_SHADOW_REPORT=\'%s\''):format(report) end

-- Mission folders of a spec that was killed before its cleanup (missions/custom/test_builder_<n>/,
-- test_dup_<n>/) are removed once they are an hour old (a parallel run's folder is younger).
os.execute(
    ('find \'%s/../Crimson-Police/missions/custom\' -maxdepth 1 -name \'test_*\' -mmin +60 -exec rm -rf {} + 2>/dev/null'):format(
        base))

print(('storage mode: %s%s'):format(
    storage,
    storage == 'files' and ' (Config.Database.enabled = false: the saves folder engine)'
        or storage == 'shadow' and (' (MariaDB answers; the twin and the engine are compared, report %s)'):format(
            report)
        or ' (MariaDB)'
))
print('MariaDB ' .. mariadb)
print(
    ('%d spec%s, %d at a time%s'):format(#files, #files == 1 and '' or 's', jobs, tz ~= 'UTC' and (', TZ=' .. tz) or ''))

-- Drop the run database and every database named after it (per-spec databases, shadow twins), and the saves
-- folders: at the end, and when the run database could not be built.
local function CleanUp()
    if ownDb then
        local like = dbName:gsub('_', '\\\\_') .. '\\\\_%'
        local h = io.popen(
            ('mysql -uroot -N -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name = \'%s\' OR schema_name LIKE \'%s\'" 2>/dev/null'):format(
                dbName, like))
        local drops = {}
        for line in h:lines() do drops[#drops + 1] = ('DROP DATABASE IF EXISTS \\`%s\\`;'):format(line) end
        h:close()
        if #drops > 0 then os.execute(('mysql -uroot -e "%s"'):format(table.concat(drops, ' '))) end
    end
    if ownSaves then os.execute(('rm -rf \'%s\''):format(savesRoot)) end
end

-- The run database (and, in files / shadow mode, its saves folder and twin), in a child like every spec.
do
    local cmd = ('cd %s/.. && %s lua5.4 -e "package.path=package.path..\';tests/?.lua\'" -e "local H = dofile(\'tests/harness.lua\'); H.resetDatabase(); H.shadowFinish()" 2>&1'):format(
        base, env)
    local h = io.popen(cmd)
    local out = h:read('a')
    if not h:close() then
        print('could not build the run database: ' .. out)
        CleanUp()
        os.exit(2)
    end
end

local totalPass, totalFail, broken, skips = 0, 0, {}, {}
local function Result(fi, out)
    local file = files[fi]
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
        print(('%s %s%s  %d passed, %d failed'):format(mark, file, seeds[fi] and (' (seed %d)'):format(seeds[fi]) or '',
            pass, fail))
        if fail > 0 then print(out) elseif #reports > 0 then print(table.concat(reports, '\n')) end
    end
    io.stdout:flush()
end

-- The command of spec fi: fresh globals per spec (a child process), on database db (default: the run's).
local function ChildCmd(fi, db)
    local e = env
    if db then e = e:gsub('CP_TEST_DB=\'[^\']*\'', ('CP_TEST_DB=\'%s\''):format(db), 1) end
    if seeds[fi] then e = e .. (' FUZZ_SEED=%d'):format(seeds[fi]) end
    if storage == 'database' then
        local dir = ('%s/%d'):format(savesRoot, fi)
        os.execute(('mkdir -p \'%s\''):format(dir))
        e = e .. (' CP_TEST_SAVES=\'%s\''):format(dir)
    end
    return ('cd %s/.. && %s lua5.4 tests/run.lua --child %s 2>&1'):format(base, e, files[fi])
end

if jobs <= 1 then
    for fi in ipairs(files) do
        local h = io.popen(ChildCmd(fi))
        local out = h:read('a')
        h:close()
        Result(fi, out)
    end
else
    -- N specs at a time (xargs -P), each on a database of its own, <run>_p<i> (dropped with the run's): a copy
    -- of the run database made in one mysql call (CREATE TABLE ... LIKE and the rows), with its twin in shadow
    -- mode and its saves folder in files and shadow mode, instead of running the migrations again. The slowest
    -- specs of the last run (per storage mode) start first.
    local tmp = os.tmpname()
    os.remove(tmp)
    os.execute(('mkdir -p \'%s\''):format(tmp))
    local timesFile = ('%s/cp_test_times_%s.txt'):format(os.getenv('TMPDIR') or '/tmp', storage)
    local last = {}
    local tf = io.open(timesFile, 'r')
    if tf then
        for line in tf:lines() do
            local ms, name = line:match('^(%d+) (.+)$')
            if ms then last[name] = tonumber(ms) end
        end
        tf:close()
    end
    local startOrder = {}
    for fi in ipairs(files) do startOrder[fi] = fi end
    table.sort(startOrder, function(a, b)
        local ta, tb = last[files[a]] or 0, last[files[b]] or 0
        if ta ~= tb then return ta > tb end
        return a < b
    end)
    local schemas = { dbName }
    if storage == 'shadow' then schemas[2] = dbName .. '_ox' end
    local tables = {}
    for i, schema in ipairs(schemas) do
        tables[i] = {}
        local h = io.popen(
            ('mysql -uroot -N -e "SELECT table_name FROM information_schema.tables WHERE table_schema = \'%s\'"'):format(
                schema))
        for line in h:lines() do tables[i][#tables[i] + 1] = line end
        h:close()
    end
    for fi in ipairs(files) do
        local db = ('%s_p%d'):format(dbName, fi)
        local sql = {}
        for i, schema in ipairs(schemas) do
            local to = db .. schema:sub(#dbName + 1)
            sql[#sql + 1] = ('CREATE DATABASE `%s` CHARACTER SET utf8mb4;'):format(to)
            for _, t in ipairs(tables[i]) do
                sql[#sql + 1] = ('CREATE TABLE `%s`.`%s` LIKE `%s`.`%s`; INSERT INTO `%s`.`%s` SELECT * FROM `%s`.`%s`;'):format(
                    to, t, schema, t, to, t, schema, t)
            end
        end
        local f = assert(io.open(('%s/%d.sql'):format(tmp, fi), 'w'))
        f:write(table.concat(sql, '\n'), '\n')
        f:close()
        local build = ('mysql -uroot < \'%s/%d.sql\' > \'%s/%d.out\' 2>&1'):format(tmp, fi, tmp, fi)
        if storage ~= 'database' then
            build = build .. (' && cp -a \'%s/%s\' \'%s/%s\''):format(savesRoot, dbName, savesRoot, db)
        end
        f = assert(io.open(('%s/%d.sh'):format(tmp, fi), 'w'))
        f:write('t0=$(date +%s%N)\n', build,
            (' || echo \'could not copy the run database\' >> \'%s/%d.out\'\n'):format(tmp, fi),
            ('%s >> %s/%d.out\n'):format(ChildCmd(fi, db), tmp, fi),
            ('echo "DONE %d $(( ($(date +%%s%%N) - t0) / 1000000 ))"\n'):format(fi))
        f:close()
    end
    local list = {}
    for _, fi in ipairs(startOrder) do list[#list + 1] = tostring(fi) end
    local h = io.popen(
        ('printf \'%%s\\n\' %s | xargs -P %d -I{} sh \'%s/{}.sh\''):format(table.concat(list, ' '), jobs, tmp))
    local done, nextFi, times = {}, 1, {}
    for line in h:lines() do
        local fi, ms = line:match('^DONE (%d+) (%d+)$')
        if fi then
            fi = tonumber(fi)
            done[fi] = true
            times[files[fi]] = ms
            while done[nextFi] do
                local of = io.open(('%s/%d.out'):format(tmp, nextFi), 'r')
                local out = of and of:read('a') or ''
                if of then of:close() end
                Result(nextFi, out)
                nextFi = nextFi + 1
            end
        end
    end
    h:close()
    for fi = nextFi, #files do Result(fi, '') end
    os.execute(('rm -rf \'%s\''):format(tmp))
    if not fuzz then
        for name, ms in pairs(last) do if not times[name] then times[name] = ms end end
        tf = io.open(timesFile, 'w')
        if tf then
            for name, ms in pairs(times) do tf:write(ms, ' ', name, '\n') end
            tf:close()
        end
    end
end

CleanUp()

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
    -- the per-spec counts are only for this summary; the report is kept when it has something to read
    os.remove(report .. '.stats')
    if shadowDiffs == 0 then os.remove(report) end
    print(('\nshadow: %d statements compared, %d differences, %d skipped%s'):format(compared, shadowDiffs, skipped,
        shadowDiffs > 0 and ('; report ' .. report) or ''))
    local cats = {}
    for k, v in pairs(byCat) do cats[#cats + 1] = ('%s %d'):format(k, v) end
    table.sort(cats)
    if #cats > 0 then print('  by category: ' .. table.concat(cats, ', ')) end
    local specs = {}
    for k, v in pairs(bySpec) do specs[#specs + 1] = ('%s %d'):format(k, v) end
    table.sort(specs)
    if #specs > 0 then print('  by spec: ' .. table.concat(specs, ', ')) end
    table.sort(skipReasons)
    for _, s in ipairs(skipReasons) do print('  skipped ' .. s) end
end

print(('\n%d specs, %d assertions passed, %d failed, %d crashed (storage: %s)'):format(#files, totalPass, totalFail,
    #broken, storage))
os.exit((totalFail == 0 and #broken == 0 and shadowDiffs == 0) and 0 or 1)
