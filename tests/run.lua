-- tests/run.lua · runs every tests/*_spec.lua in a fresh Lua state and prints a summary.
--   lua5.4 tests/run.lua            (all specs)
--   lua5.4 tests/run.lua scoring    (only specs whose file name contains "scoring")
-- Each spec file is a plain script: local H = dofile('tests/harness.lua'); H.boot{...}; ... H.eq(...)
-- and must end with `return H`. The MariaDB database cp_test is rebuilt from sql/migrations first.

local filter = arg[1]
local base = (debug.getinfo(1, 'S').source:match('^@(.*)/run%.lua$') or 'tests')

local p = io.popen('ls ' .. base .. '/*_spec.lua 2>/dev/null')
local files = {}
for line in p:lines() do
    if not filter or line:find(filter, 1, true) then files[#files + 1] = line end
end
p:close()

-- Every run gets its own database (parallel runs never wipe each other's data),
-- built from sql/migrations and dropped at the end.
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
do
    local H = dofile(base .. '/harness.lua')
    H.db = dbName
    H.resetDatabase()
end

local totalPass, totalFail, broken = 0, 0, {}
for _, file in ipairs(files) do
    -- Fresh globals per spec: run it in a child process for isolation.
    local cmd = ('cd %s/.. && CP_TEST_DB=' .. dbName .. ' lua5.4 -e "package.path=package.path..\';tests/?.lua\'" -e "local ok, H = pcall(dofile, \'%s\'); if not ok then print(\'ERROR \' .. tostring(H)); os.exit(2) end; print((\'RESULT %%d %%d\'):format(H.passes, H.failures)); os.exit(H.failures > 0 and 1 or 0)" 2>&1'):format(base, file)
    local h = io.popen(cmd)
    local out = h:read('a')
    h:close()
    local pass, fail = out:match('RESULT (%d+) (%d+)')
    pass, fail = tonumber(pass), tonumber(fail)
    if not pass then
        broken[#broken + 1] = file
        print(('✗ %s crashed:\n%s'):format(file, out))
    else
        totalPass, totalFail = totalPass + pass, totalFail + fail
        local mark = fail == 0 and '✓' or '✗'
        print(('%s %s  %d passed, %d failed'):format(mark, file, pass, fail))
        if fail > 0 then print(out) end
    end
end

if ownDb then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(dbName)) end
print(('\n%d specs, %d assertions passed, %d failed, %d crashed'):format(#files, totalPass, totalFail, #broken))
os.exit((totalFail == 0 and #broken == 0) and 0 or 1)
