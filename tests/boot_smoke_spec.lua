-- The real server boot test (tools/boot_smoke.sh) reads a console log the way it should: real FXServer logs pass
-- or fail for the right reason, keys are masked and the server.cfg it writes holds no secret.

-- The logs in tests/fixtures/boot are real FXServer consoles (build 38435, Qbox v1.24.1): a clean start, a start
-- with "server thread hitch" lines, a start where settings.lua did not parse, and a database-off boot with
-- --admin-check --restart (real_restart.txt, its folder paths shortened). Variants (a restart, a missing line, a
-- moved hitch, a crash at quit) are written to a temporary file. Runs bash and awk only; no stubs, no database.

local H = dofile('tests/harness.lua')

local REPO = H.root .. '../'
local TOOL = REPO .. 'tools/boot_smoke.sh'

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Write(path, s)
    local f = assert(io.open(path, 'w'))
    f:write(s)
    f:close()
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

-- Runs the tool with these arguments (and env assignments in front); its output and exit status.
local function Run(args, env)
    local p = io.popen(('%s bash %s %s 2>&1; echo "rc=$?"'):format(env or '', TOOL, args))
    local out = p:read('a')
    p:close()
    local rc = tonumber(out:match('rc=(%d+)%s*$'))
    return out, rc
end

local function Check(text)
    local path = os.tmpname()
    Write(path, text)
    local out, rc = Run('--check ' .. path)
    os.remove(path)
    return out, rc
end

local FIX = REPO .. 'tests/fixtures/boot/'
local clean = Read(FIX .. 'clean_start.txt')
H.ok(clean ~= nil and Read(TOOL) ~= nil, 'the tool and its fixtures are readable')

-- A clean start in database mode: PASS.
local out, rc = Run('--check ' .. FIX .. 'clean_start.txt')
H.eq(rc, 0, 'a clean start passes')
H.ok(Has(out, '\nPASS'), 'and says PASS')
H.ok(Has(out, 'Crimson-Police started 1 time(s)'), 'one start counted')
H.ok(Has(out, 'info  Start-up check: 7 warnings and 0 errors'), 'the start-up check summary is shown')

-- The hitches of the start-up check before it gave the server a tick: FAIL, one line per hitch.
out, rc = Run('--check ' .. FIX .. 'hitch_start.txt')
H.eq(rc, 1, 'a start with hitch lines fails')
H.ok(Has(out, 'FAIL  server thread hitch while Crimson-Police starts: '), 'the hitch is named')
H.ok(Has(out, 'timer interval of 252 milliseconds'), 'the hitch while the migrations ran')
H.ok(Has(out, 'timer interval of 970 milliseconds'), 'the hitch right after the start-up check')
H.ok(Has(out, 'FAIL: 2 problem(s)'), 'two problems')

-- A file that did not parse (too many locals): FAIL with the FXServer line.
out, rc = Run('--check ' .. FIX .. 'parse_error.txt')
H.eq(rc, 1, 'a parse error fails')
H.ok(Has(out, 'FAIL  Crimson-Police error: [script:Crimson-Polic] Error parsing script @Crimson-Police/'),
    'the Error parsing line is shown')

-- Hitches outside Crimson-Police's start do not count: before it and long after its start-up check.
local hitch = '[ citizen-server-impl] server thread hitch warning: timer interval of 300 milliseconds\n'
local tail = {}
for i = 1, 3 do tail[#tail + 1] = ('[     script:qbx_core] another resource %d\n'):format(i) end
out, rc = Check(hitch .. clean .. '\n' .. table.concat(tail) .. hitch)
H.eq(rc, 0, 'hitches before the start and after another resource printed pass')

-- A hitch a few Crimson-Police lines after the summary (its integration lines) still counts.
H.ok(Has(clean, '[crimson-police:integrations]'), 'the clean start has its integration lines')
out, rc = Check(clean .. '\n' .. hitch)
H.eq(rc, 1, 'a hitch right after the last Crimson-Police start line fails')

-- Each start needs its migrations and missions lines.
local noMissions = clean:gsub('[^\n]*missions loaded: [^\n]*\n', '')
out, rc = Check(noMissions)
H.eq(rc, 1, 'a start without the missions line fails')
H.ok(Has(out, 'start 1 of Crimson-Police has no "missions loaded" line'), 'and says which line is missing')
local noMigrations = clean:gsub('[^\n]*Crimson%-Police database at version [^\n]*\n', '')
out, rc = Check(noMigrations)
H.eq(rc, 1, 'a start without the migrations line fails')
H.ok(Has(out, 'has no migrations line'), 'and says so')

-- Never started, or a refused key.
out, rc = Check('[ svadhesive] This server does not have a license key specified.\n')
H.eq(rc, 1, 'no start fails')
H.ok(Has(out, 'Crimson-Police never started'), 'never started is named')
H.ok(Has(out, 'did not accept its license key'), 'and the missing key')

-- Console commands: the tool writes a "[boot_smoke] sent:" line before each one it types.
local start = clean:sub((clean:find('[^\n]*Creating script environments for Crimson%-Police')))
local stop = '[           resources] Stopping resource Crimson-Police\n'
local answer = '[script:Crimson-Polic] [crimson-police] Check: 18 OK, 7 warnings, 0 errors.\n'
local check = '[boot_smoke] sent: CrimsonPoliceAdmin check\n'
local restart = '[boot_smoke] sent: restart Crimson-Police\n'
out, rc = Check(clean .. check .. answer .. restart .. stop .. start)
H.eq(rc, 0, 'the admin check answered and a clean restart pass')
H.ok(Has(out, 'Crimson-Police started 2 time(s)'), 'two starts counted')
out, rc = Check(clean .. check .. restart .. stop)
H.eq(rc, 1, 'no check answer and no second start fail')
H.ok(Has(out, 'Crimson-Police started 1 time(s), 2 asked'), 'the missing restart is named')
H.ok(Has(out, 'CrimsonPoliceAdmin check printed no "Check:" answer'), 'the missing answer is named')
local badRestart = start:gsub('[^\n]*missions loaded: [^\n]*\n', '')
out, rc = Check(clean .. restart .. stop .. badRestart)
H.eq(rc, 1, 'a restart without its missions line fails')
H.ok(Has(out, 'start 2 of Crimson-Police has no "missions loaded" line'), 'the second start is named')

-- A real boot (tests/fixtures/boot/real_restart.txt, build 38435, database off, --admin-check --restart):
-- a 258 ms hitch on the first start while oxmysql answered qbx_core's and ox_inventory's first queries (the line
-- before it is ox_inventory's query), and a 224 ms hitch of the restart while Crimson-Police loaded its missions.
local real = Read(FIX .. 'real_restart.txt')
H.ok(real ~= nil and Has(real, 'timer interval of 224 milliseconds'), 'the real restart log is readable')
real = real or ''
out, rc = Run('--check ' .. FIX .. 'real_restart.txt')
H.eq(rc, 1, 'the real restart log fails (the mission load hitch)')
H.ok(Has(out, 'FAIL  server thread hitch while Crimson-Police starts: ') and Has(out, 'interval of 224 milliseconds'),
    'the 224 ms hitch next to Crimson-Police\'s lines is a FAIL')
H.ok(Has(out, 'FAIL: 1 problem(s)'), 'one problem only: ' .. out)
H.ok(
    Has(out, 'info  hitch during another resource\'s work (ox_inventory): ')
        and Has(out, 'interval of 258 milliseconds'),
    'the 258 ms hitch after ox_inventory\'s query is info'
)
H.ok(Has(out, 'Crimson-Police started 2 time(s)'), 'both starts counted')

-- the same boot without the mission load hitch (the fix): PASS
local fixed = real:gsub('[^\n]*timer interval of 224 milliseconds[^\n]*\n', '')
out, rc = Check(fixed)
H.eq(rc, 0, 'the real boot without the restart hitch passes: ' .. out)
H.ok(Has(out, '\nPASS'), 'and says PASS')

-- the hitch right after another resource's own script line is info too; after oxmysql reporting Crimson-Police's
-- query, or after a Crimson-Police line, it stays a FAIL
local hitch258 = '[ citizen-server-impl] server thread hitch warning: timer interval of 258 milliseconds\n'
local function Move(text, after)
    local cut = text:gsub('[^\n]*timer interval of 258 milliseconds[^\n]*\n', '')
    local at = cut:find(after, 1, true)
    if not at then return cut end
    local eol = cut:find('\n', at, true)
    return cut:sub(1, eol) .. hitch258 .. cut:sub(eol + 1)
end
out, rc = Check(Move(fixed, 'Warning: Table \'properties\' does not exist'))
H.eq(rc, 0, 'a hitch after a qbx_core line passes')
H.ok(Has(out, 'info  hitch during another resource\'s work (qbx_core): '), 'and names qbx_core')
out, rc = Check(Move(fixed, 'SELECT COUNT(*) FROM cp_schema_migrations []'))
H.eq(rc, 1, 'a hitch after oxmysql reports Crimson-Police\'s query fails')
H.ok(Has(out, 'FAIL  server thread hitch while Crimson-Police starts: ') and Has(out, 'interval of 258'),
    'and is the Crimson-Police hitch')
out, rc = Check(Move(fixed, 'storage: database off, data saved as files'))
H.eq(rc, 1, 'a hitch right after a Crimson-Police line fails')
out, rc = Check(Move(fixed, 'Started resource Crimson-Police'))
H.eq(rc, 1, 'a hitch right after "Started resource Crimson-Police" fails')

-- the server crashed at quit (proot shutdown): info, not FAIL; a crash before "Quitting" fails
local exit139 = '[boot_smoke] the server exited with status 139\n'
local segv = 'Segmentation fault (core dumped)\n'
out, rc = Check(fixed .. segv .. exit139)
H.eq(rc, 0, 'a crash after "Quitting" passes: ' .. out)
H.ok(Has(out, 'info  the server crashed after "Quitting" (its shutdown, not counted): '), 'and is shown as info')
local early = fixed:gsub('(%[boot_smoke%] sent: quit\n)', segv .. '%1')
out, rc = Check(early .. exit139)
H.eq(rc, 1, 'a crash before "Quitting" fails')
H.ok(Has(out, 'FAIL  the server crashed: Segmentation fault'), 'and names the crash line')
out, rc = Check(clean .. exit139)
H.eq(rc, 1, 'exit status 139 without a "Quitting" line fails')
out, rc = Check(fixed .. '[boot_smoke] the server exited with status 0\n')
H.eq(rc, 0, 'a clean exit passes')
H.ok(Has(Read(TOOL), 'the server exited with status'), 'a boot writes the exit status of the server to its log')

-- Keys are masked: the key itself, any cfxk_ value and the mysql connection string.
local raw = os.tmpname()
Write(raw, '+set sv_licenseKey s3cretKEY +set x cfxk_AbC12_x9 +set mysql_connection_string mysql://u:pw@h/db\n')
local p = io.popen(
    ('CP_FX_LICENSE_KEY=s3cretKEY CP_FX_MYSQL=\'mysql://u:pw@h/db\' bash %s --mask < %s'):format(TOOL, raw))
local masked = p:read('a')
p:close()
os.remove(raw)
H.eq(masked, '+set sv_licenseKey [masked] +set x cfxk_[masked] +set mysql_connection_string [masked]\n',
    'the key, cfxk_ values and the connection string are masked')

-- The server.cfg of the test: TCP only, what Qbox needs, the deps in order, and no secret.
local cfgPath = os.tmpname()
out, rc = Run('--write-cfg ' .. cfgPath)
local cfg = Read(cfgPath) or ''
os.remove(cfgPath)
H.eq(rc, 0, 'the server.cfg is written')
H.ok(Has(cfg, 'set inventory:framework "qbx"'), 'qbx_core gets inventory:framework qbx')
H.ok(Has(cfg, 'endpoint_add_tcp "0.0.0.0:30125"'), 'a TCP endpoint')
H.eq(cfg:find('endpoint_add_udp', 1, true), nil, 'no UDP endpoint')
H.eq(cfg:find('sv_licenseKey', 1, true), nil, 'no license key in it')
H.eq(cfg:find('mysql_connection_string', 1, true), nil, 'no connection string in it')
local order = {}
for name in cfg:gmatch('\nensure ([%w_%-]+)') do order[#order + 1] = name end
H.eq(table.concat(order, ' '), 'oxmysql require ox_lib qbx_core ox_target qbx_vehicles ox_inventory Crimson-Police',
    'ox_lib after require, ox_inventory after qbx_vehicles, Crimson-Police last')

-- Without a key the tool stops before it starts anything.
out, rc = Run('--fx /nonexistent --data /nonexistent', 'CP_FX_LICENSE_KEY=')
H.eq(rc, 2, 'no key: usage error')
H.ok(Has(out, 'set CP_FX_LICENSE_KEY'), 'and it says how to set it')

-- The setup tool pins the releases the boot was made with and writes no secret.
local setup = Read(REPO .. 'tools/boot_smoke_setup.sh') or ''
H.ok(Has(setup, 'QBX_CORE=v1.24.1') and Has(setup, 'OX_LIB=v3.42.2'), 'the setup pins the booted releases')
H.eq(setup:find('sv_licenseKey', 1, true), nil, 'the setup never handles the key')

-- docs/dev/TESTING.md says how the owner runs it.
local testing = Read(REPO .. 'docs/dev/TESTING.md') or ''
H.ok(Has(testing, '## Real server boot test'), 'TESTING has the section')
H.ok(Has(testing, 'export CP_FX_LICENSE_KEY='), 'and how to give the key')

return H
