-- The release build (tools/build_release.py): it ships the runtime files, the files read with LoadResourceFile, the
-- write folders and the owner docs, nothing of the developer tree, and it fails on a missing file, a version
-- mismatch, a scratch file or a secret. docs/dev/TESTING.md "Release build".

local H = dofile('tests/harness.lua')

local function Shell(cmd)
    local p = io.popen(cmd .. ' 2>&1')
    local out = p:read('a')
    local ok, _, code = p:close()
    return ok, out, code
end
local function Lines(cmd)
    local _, out = Shell(cmd)
    local t = {}
    for l in out:gmatch('[^\n]+') do t[#t + 1] = l end
    return t
end
local function Q(s) return '\'' .. s:gsub('\'', '\'\\\'\'') .. '\'' end

local _, tmpOut = Shell('mktemp -d "${TMPDIR:-/tmp}/cp_release.XXXXXX"')
local TMP = tmpOut:gsub('%s+$', '')
H.ok(TMP:find('cp_release', 1, true) ~= nil, 'a scratch folder: ' .. TMP)

local function Build(root, out, draft)
    return Shell(('timeout 120 python3 %s/tools/build_release.py %s--root %s --out %s'):format(Q(root),
        draft and '--draft ' or '', Q(root), Q(out)))
end

-- ============================================================================
--                 1. THE BUILD OF THIS TREE, AND WHAT IS IN IT
-- ============================================================================

local out = TMP .. '/dist'
local ok, log = Build('.', out, true)
H.ok(ok, 'the draft build of this tree passes: ' .. log:sub(-600))
H.ok(log:find('release: PASS, version 1.0.0', 1, true) ~= nil, 'and says PASS with its version: ' .. log:sub(-200))

local files = {}
for _, f in ipairs(Lines(('cd %s && find . -type f | sed "s|^\\./||" | LC_ALL=C sort'):format(Q(out)))) do
    files[f] = true
end
local function Count(prefix, suffix)
    local n = 0
    for f in pairs(files) do
        if f:sub(1, #prefix) == prefix and (suffix == '' or f:sub(-#suffix) == suffix) then n = n + 1 end
    end
    return n
end

local tracked = Lines('git ls-files Crimson-Police/sql/migrations/ Crimson-Police/missions/builtin/')
local migrations, builtins = 0, 0
for _, f in ipairs(tracked) do
    H.ok(files[f] ~= nil, 'ships ' .. f)
    if f:find('/sql/migrations/', 1, true) then migrations = migrations + 1 else builtins = builtins + 1 end
end
H.eq(Count('Crimson-Police/sql/migrations/', '.sql'), migrations, 'every migration ships')
H.ok(migrations >= 18, ('every tracked migration (%d)'):format(migrations))
H.ok(builtins >= 20, ('the built-in missions (%d)'):format(builtins))
for _, f in ipairs({
    'Crimson-Police/fxmanifest.lua',
    'Crimson-Police/README.md',
    'Crimson-Police/CHANGELOG.md',
    'Crimson-Police/LICENSE',
    'Crimson-Police/config/config.lua',
    'Crimson-Police/config/banned_words.txt',
    'Crimson-Police/config/examples/generic.lua',
    'Crimson-Police/locales/en.json',
    'Crimson-Police/web/dist/index.html',
    'Crimson-Police/web/dist/build-stamp.json',
    'Crimson-Police/missions/builtin/index.lua',
    'Crimson-Police/items/ox_inventory_items.lua',
    'Crimson-Police/saves/README.md',
    'README.md',
    'docs/OWNER_GUIDE.md',
    'docs/IN_GAME_CHECKLIST.md',
    'docs/IN_GAME_TEST_PLAN.md',
    'Crimson-Police-1.0.0-draft.zip',
}) do
    H.ok(files[f] ~= nil, 'ships ' .. f)
end
-- every folder the resource writes into (tests/harness.lua H.SHIPPED_DIRS) ships with something in it
for _, dir in ipairs(H.SHIPPED_DIRS) do
    H.ok(Count('Crimson-Police/' .. dir .. '/', '') > 0, 'ships the write folder ' .. dir)
end
H.eq(Count('Crimson-Police/', '/.gitkeep'), 7, 'the 7 .gitkeep files')
-- every shared, server and client Lua file of the resource is in it
local missing = {}
for _, f in ipairs(Lines('git ls-files "Crimson-Police/*.lua"')) do
    if not f:find('^Crimson%-Police/missions/custom/') and not files[f] then missing[#missing + 1] = f end
end
H.eq(table.concat(missing, ' '), '', 'every tracked Lua file of the resource ships')

local bad = {}
for f in pairs(files) do
    local inner = f:gsub('^Crimson%-Police/', '')
    for _, part in ipairs({ 'web/src/', 'node_modules/', 'locales/parts/', 'tests/', 'tools/', 'docs/dev/' }) do
        if inner:sub(1, #part) == part or inner:find('/' .. part, 1, true) then bad[#bad + 1] = f end
    end
    if f:find('%.map$') or f:find('%.DS_Store$') or f:find('%.log$') or f:find('^Crimson%-Police/saves/.+%.json$')
        or f:find('^Crimson%-Police/missions/custom/test_')
        or (f:find('^Crimson%-Police/missions/custom/') and not f:find('/%.gitkeep$'))
        or f:find('^Crimson%-Police/web/[^/]+$') then
        bad[#bad + 1] = f
    end
end
table.sort(bad)
H.eq(table.concat(bad, ' '), '', 'nothing of the developer tree, no saves data and no scratch files')

-- the zip holds the same files
local zipped = Lines(('python3 -c %s %s'):format(
    Q('import sys, zipfile; print("\\n".join(sorted(zipfile.ZipFile(sys.argv[1]).namelist())))'),
    Q(out .. '/Crimson-Police-1.0.0-draft.zip')))
local inDir = 0
for f in pairs(files) do if not f:find('%.zip$') then inDir = inDir + 1 end end
H.eq(#zipped, inDir, 'the zip holds every built file')
local zipMiss = 0
for _, f in ipairs(zipped) do if not files[f] then zipMiss = zipMiss + 1 end end
H.eq(zipMiss, 0, 'and only those')

-- a second build into the same folder replaces the first; a folder of other files is refused
ok, log = Build('.', out, true)
H.ok(ok, 'a second build into the same folder passes: ' .. log:sub(-200))
Shell(('mkdir -p %s/mine && touch %s/mine/notes.txt'):format(Q(TMP .. '/other'), Q(TMP .. '/other')))
ok, log = Build('.', TMP .. '/other', true)
H.eq(ok, nil, 'a build into a folder of other files fails')
H.ok(log:find('holds files this tool did not make (mine)', 1, true) ~= nil, 'and names them: ' .. log:sub(-200))
H.ok(io.open(TMP .. '/other/mine/notes.txt', 'r') ~= nil, 'and deletes nothing')
-- the repository itself, or a folder inside the resource, is never an output folder
for _, dir in ipairs({ '.', 'Crimson-Police/web' }) do
    local okO, logO, code = Build('.', dir, true)
    H.eq(okO, nil, '--out ' .. dir .. ' is refused')
    H.eq(code, 2, '--out ' .. dir .. ': a usage error')
    H.ok(logO:find('--out must be a folder of its own', 1, true) ~= nil, '--out ' .. dir .. ': says why: ' .. logO)
end
H.ok(io.open('Crimson-Police/web/dist/index.html', 'r') ~= nil, 'and the tree is untouched')

-- without --draft the build refuses while the CHANGELOG says "(not released yet)"
local changelog = io.open('Crimson-Police/CHANGELOG.md', 'r'):read('a')
if changelog:match('\n## %S+([^\n]*)'):find('(not released yet)', 1, true) then
    ok, log = Build('.', TMP .. '/sale', false)
    H.eq(ok, nil, 'the sale build of an unreleased version fails')
    H.ok(log:find('"(not released yet)"', 1, true) ~= nil, 'and says why: ' .. log:sub(-200))
end

-- ============================================================================
--               2. dist/ IS IGNORED, A NEW web/dist FILE IS NOT
-- ============================================================================

local ign, ignOut = Shell('git check-ignore -q dist/x')
H.ok(ign, 'git ignores the release output dist/: ' .. ignOut)
ign = Shell('git check-ignore -q Crimson-Police/web/dist/assets/new.js')
H.eq(ign, nil, 'git does not ignore a new file under Crimson-Police/web/dist')

-- ============================================================================
--      3. A BROKEN SCRATCH COPY OF THE REPOSITORY FAILS, WITH THE REASON
-- ============================================================================

local function Copy()
    local root = TMP .. '/repo'
    Shell(('rm -rf %s && mkdir -p %s/tools %s/docs'):format(Q(root), Q(root), Q(root)))
    local okC, outC = Shell((
        'tar --exclude=node_modules -cf - Crimson-Police README.md docs/OWNER_GUIDE.md '
        .. 'docs/IN_GAME_CHECKLIST.md docs/IN_GAME_TEST_PLAN.md tools/build_release.py | tar -C %s -xf -'
    ):format(Q(root)))
    H.ok(okC, 'a scratch copy of the repository: ' .. outC)
    return root
end
local function Fails(what, change, expect)
    local root = Copy()
    local okS, outS = Shell(('cd %s && %s'):format(Q(root), change))
    H.ok(okS, what .. ': the change applies: ' .. outS)
    local okB, logB = Build(root, TMP .. '/broken', true)
    H.eq(okB, nil, what .. ': the build fails')
    H.ok(logB:find(expect, 1, true) ~= nil, what .. ': and says ' .. expect .. ': ' .. logB:sub(-300))
    H.eq(io.open(TMP .. '/broken/Crimson-Police-1.0.0-draft.zip', 'r'), nil, what .. ': no zip is written')
end

do
    local root = Copy()
    local okB, logB = Build(root, TMP .. '/broken', true)
    H.ok(okB, 'the unbroken scratch copy builds: ' .. logB:sub(-300))
end
Fails('a manifest file deleted', 'rm Crimson-Police/modules/money/engine.lua',
    'server_scripts: \'modules/money/engine.lua\' matches no file')
Fails('a manifest glob with nothing left', 'rm -r Crimson-Police/modules/review',
    '\'modules/review/*.lua\' matches no file')
Fails('a migration folder gone', 'rm Crimson-Police/sql/migrations/*.sql', 'sql/migrations/*.sql: missing')
Fails('banned_words.txt gone', 'rm Crimson-Police/config/banned_words.txt', 'config/banned_words.txt: missing')
Fails('a write folder without its .gitkeep',
    'rm Crimson-Police/saves/_backups/.gitkeep Crimson-Police/saves/exports/.gitkeep', 'saves/**/.gitkeep: missing')
Fails('an owner doc gone', 'rm docs/OWNER_GUIDE.md', 'docs/OWNER_GUIDE.md: missing')
Fails(
    'the CHANGELOG version changed',
    'sed -i "0,/^## 1.0.0/s//## 1.0.1/" Crimson-Police/CHANGELOG.md',
    'the versions differ: Crimson-Police/CHANGELOG.md 1.0.1, Crimson-Police/fxmanifest.lua 1.0.0, '
        .. 'Crimson-Police/web/package.json 1.0.0'
)
Fails('the package.json version changed',
    'sed -i "s/\\"version\\": \\"1.0.0\\"/\\"version\\": \\"1.1.0\\"/" ' .. 'Crimson-Police/web/package.json',
    'Crimson-Police/web/package.json 1.1.0')
Fails('a .orig file in a shipped folder', 'cp Crimson-Police/locales/en.json Crimson-Police/locales/en.json.orig',
    'Crimson-Police/locales/en.json.orig: scratch file')
Fails('a .bak file in web/dist', 'touch Crimson-Police/web/dist/index.html.bak',
    'Crimson-Police/web/dist/index.html.bak: scratch file')
Fails('a source map in web/dist', 'touch Crimson-Police/web/dist/assets/index.js.map', '.map: scratch file')
Fails('a symlink in a shipped folder', 'ln -s /etc/hostname Crimson-Police/logos/extra.png', 'is a symlink')
-- the fake secrets are put together here, so no file of the repository holds one whole
local hook = 'https://discord' .. '.com/api/webhooks/1234567890/abcdefABCDEF'
Fails('a webhook pasted into config.lua',
    ('printf "%%s\\n" %s >> Crimson-Police/config/config.lua'):format(Q('-- ' .. hook)),
    'Crimson-Police/config/config.lua:')
Fails('a webhook pasted into config.lua (the reason)',
    ('printf "%%s\\n" %s >> Crimson-Police/config/config.lua'):format(Q('-- ' .. hook)),
    'looks like a secret (Discord webhook)')
Fails('a licence key in a mission', ('printf "%%s\\n" %s >> Crimson-Police/missions/builtin/beat_patrol.lua'):format(
    Q('-- sv_licenseKey cfxk_' .. 'AbCdEf0123456789xyz')
), 'looks like a secret (FiveM licence key)')
Fails('a database URL with its password', ('printf "%%s\\n" %s >> Crimson-Police/config/blocks.lua'):format(
    Q('-- mysql://' .. 'root:hunter22@localhost/qbox')
), 'looks like a secret (database URL with a password)')
Fails('a password value',
    ('printf "%%s\\n" %s >> Crimson-Police/config/config.lua'):format(Q('-- password' .. '=hunter22')),
    'looks like a secret (password value)')

-- the secret rules leave the shipped redaction patterns alone (shared/init.lua) and never print the whole secret
do
    local root = Copy()
    Shell(('cd %s && printf "%%s\\n" %s >> Crimson-Police/config/config.lua'):format(Q(root), Q('-- ' .. hook)))
    local _, logB = Build(root, TMP .. '/broken', true)
    H.eq(logB:find('abcdefABCDEF', 1, true), nil, 'the build log does not print the whole secret')
end
H.eq(log:find('shared/init.lua', 1, true), nil, 'the redaction patterns of shared/init.lua are no hit')

-- a developer file that a manifest glob would pick up
Fails('a test file under a shipped glob',
    'mkdir -p Crimson-Police/web/dist/tests && touch Crimson-Police/web/dist/tests/x.js', 'developer file (tests)')

-- ============================================================================
--    4. WITHOUT THE BUILD TOOL, OR WITH dist/ NOT IGNORED, THIS SPEC FAILS
-- ============================================================================
-- (the first part asserts the build passes and git ignores dist/, so a tree without them fails above)

Shell(('rm -rf %s'):format(Q(TMP)))
H.eq(io.open(TMP, 'r'), nil, 'the scratch folders are removed')

return H
