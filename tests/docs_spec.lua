-- The documents stay true to the code: the SPEC links the config files instead of copying them and every Config key
-- it names exists, every document a file names exists, the short README and the owner guide keep their contents,
-- commands, config keys and "What ships off" table in step with the code, and FILE_NOTES is one line per file.

-- The documents stay true to the code: the SPEC links the config files instead of copying them and every Config key
-- it names exists, every document a file names exists, the short README and the owner guide keep their contents,
-- commands, config keys and "What ships off" table in step with the code, and FILE_NOTES is one line per file.
-- The map (step H1): ARCHITECTURE, FILE_NOTES and LOOPS name what the code has (docs/dev/TESTING.md "Keeping the docs true").

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local REPO = H.root .. '../'

local function ReadRepo(rel)
    local f = io.open(REPO .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

local function Lines(cmd)
    local out = {}
    local p = io.popen(cmd)
    if not p then return out end
    for ln in p:lines() do out[#out + 1] = ln end
    p:close()
    return out
end

local function Node(root, path)
    local node = root
    for key in path:gmatch('[^%.]+') do
        if type(node) == 'table' then node = node[key] else return nil end
    end
    return node
end

-- config.lua and blocks.lua as shipped (the harness changes some values for its storage mode)
local Shipped = { Config = {} }
local function V(x, y, z, w) return { x = x, y = y, z = z, w = w } end
Shipped.vector3, Shipped.vec3, Shipped.vector4, Shipped.vec4 = V, V, V, V
for _, rel in ipairs({ 'Crimson-Police/config/config.lua', 'Crimson-Police/config/blocks.lua' }) do
    local chunk = loadfile(REPO .. rel, 't', Shipped)
    H.ok(chunk ~= nil and pcall(chunk), rel .. ' loads as shipped')
end
local Cfg = Shipped.Config

local readme = ReadRepo('README.md') or ''
local guide = ReadRepo('docs/OWNER_GUIDE.md') or ''
local spec = ReadRepo('docs/dev/SPEC.md') or ''
H.ok(#readme > 10000 and #guide > 10000 and #spec > 10000, 'README, the owner guide and SPEC are readable')

-- ============================================================================
--           THE SPEC LINKS THE CONFIG FILES, AND THEY HOLD ITS KEYS
-- ============================================================================

-- the README is the short owner guide; the rest is in docs/OWNER_GUIDE.md
H.ok(#readme < 61440, ('README stays under 60 KB (%d bytes)'):format(#readme))
for _, part in ipairs({
    'What you need',
    'Install in 5 minutes',
    'Admins, supervisors and permissions',
    'What ships off and how to turn it on',
    'All commands and keys',
    'Admin UI tour',
    'Troubleshooting',
}) do
    H.ok(readme:find('\n##+ [%d%.]+ ' .. part .. '\n') ~= nil, 'README has its part: ' .. part)
end
H.ok(Has(readme, '](docs/OWNER_GUIDE.md)') and Has(readme, '](docs/dev/README.md)'),
    'README links the guide and docs/dev')

-- no copy of a config file in the SPEC: it links them, and every Config key it names is a real setting
for _, rel in ipairs({ 'Crimson-Police/config/config.lua', 'Crimson-Police/config/blocks.lua' }) do
    local file = ReadRepo(rel) or ''
    local head = file:sub(1, 400)
    H.ok(#file > 1000 and not Has(spec, head), 'docs/dev/SPEC.md copies no part of ' .. rel)
    H.ok(Has(spec, '(../../' .. rel .. ')'), 'docs/dev/SPEC.md links ' .. rel)
end
local SPEC_MAX = 250000
H.ok(#spec < SPEC_MAX, ('SPEC stays small (%d bytes)'):format(#spec))
do
    local SPEC_FOREIGN = {
        Roster = true,
        Police = true,
        DispatchIntegration = true,
        Integrations = true,
        ArenaIntegration = true,
        Prison = true,
        DispatchJobs = true,
        PoliceJobs = true,
        Dispatch = true,
    }
    local bad, n, seen = {}, 0, {}
    for path, after in spec:gmatch('%f[%w]Config%.([%w_%.]+)(.?)') do
        path = path:gsub('%.+$', '')
        local top = path:match('^[%w_]+')
        if not seen[path] and not SPEC_FOREIGN[top] and after ~= '*' and after ~= '<' then
            seen[path] = true
            n = n + 1
            if Node(Cfg, path) == nil then bad[#bad + 1] = path end
        end
    end
    H.ok(n > 150, ('the SPEC names the settings (%d)'):format(n))
    H.eq(table.concat(bad, ', '), '', 'every Config key the SPEC names exists in config.lua as shipped')
end

-- ============================================================================
--              THE DOCUMENT SET, AND EVERY DOCUMENT A FILE NAMES
-- ============================================================================

local DOCS = {
    'IN_GAME_CHECKLIST.md',
    'IN_GAME_TEST_PLAN.md',
    'OWNER_GUIDE.md',
    'dev/ARCHITECTURE.md',
    'dev/FILE_NOTES.md',
    'dev/INTEGRATIONS.md',
    'dev/LOOPS.md',
    'dev/README.md',
    'dev/SPEC.md',
    'dev/STYLE.md',
    'dev/TESTING.md',
    'dev/WORKFLOWS.md',
}
local present = Lines('cd "' .. REPO .. 'docs" && find . -type f | sed "s|^\\./||" | LC_ALL=C sort')
H.eq(table.concat(present, ' '), table.concat(DOCS, ' '),
    'docs/ holds the owner set and docs/dev the developer set, no notes folder')

local files = Lines(
    'cd "' .. REPO .. '" && find . \\( -name node_modules -o -name dist -o -name .git -o -name fixtures \\) -prune'
        .. ' -o -type f \\( -name "*.lua" -o -name "*.md" -o -name "*.py" -o -name "*.sh" -o -name "*.ts" -o -name'
        .. ' "*.tsx" -o -name "*.txt" -o -name "*.mjs" -o -name "*.yml" \\) -print | LC_ALL=C sort'
)
H.ok(#files > 300, ('the repository files are listed (%d)'):format(#files))
local named, missing = 0, {}
for _, rel in ipairs(files) do
    local s = ReadRepo(rel:gsub('^%./', '')) or ''
    for doc in s:gmatch('docs/[%w_/]+%.md') do
        named = named + 1
        if not ReadRepo(doc) then missing[#missing + 1] = rel .. ': ' .. doc end
    end
end
H.ok(named > 100, ('files name the docs (%d times)'):format(named))
H.eq(table.concat(missing, '; '), '', 'every docs/*.md a file names exists')

-- the short test plan: linked from the README, a smoke test first, then the risky changes, each line with a result
local plan = ReadRepo('docs/IN_GAME_TEST_PLAN.md') or ''
H.ok(Has(readme, '(docs/IN_GAME_TEST_PLAN.md)'), 'README links the in-game test plan')
H.ok(Has(plan, '## Session 1: smoke test (60 minutes)') and Has(plan, '## Session 2: the risky changes, in this order'),
    'the test plan has the 60-minute smoke test, then the risky changes')
local checks = {}
for ln in (plan .. '\n'):gmatch('(.-)\n') do
    if ln:match('^%- %[ %] ') then
        checks[#checks + 1] = ln
    elseif ln:match('^  %S') and #checks > 0 then
        checks[#checks] = checks[#checks] .. ' ' .. ln
    end
end
local steps, unseen = #checks, {}
for _, item in ipairs(checks) do
    if not item:find('->', 1, true) then unseen[#unseen + 1] = item:sub(7, 50) end
end
H.ok(steps >= 40, ('the test plan has its checks (%d)'):format(steps))
H.eq(table.concat(unseen, '; '), '', 'every test plan check says what you should see')
for _, part in ipairs({
    'restart Crimson-Police',
    'resmon',
    'tour',
    'Payments',
    'Supervisor',
    '/CrimsonPoliceAdmin',
    'moved mission points',
    'mission desks',
    'Teams',
    'money engine',
    'Real players',
    'Your other scripts',
}) do
    H.ok(Has(plan, part), 'the test plan covers ' .. part)
end

-- no scratch paths or lost design files in the documents
for _, rel in ipairs(files) do
    if rel:match('%.md$') then
        local s = ReadRepo(rel:gsub('^%./', '')) or ''
        H.ok(not Has(s, '/tmp/claude') and not Has(s, 'scratchpad/') and not Has(s, 'DESIGN_FINAL'),
            rel .. ': names no scratch path')
    end
end

-- no build history: no step or plan id anywhere in a document but the CHANGELOG. An id is a whole word made of a
-- step prefix and a number (WF5B, SALE3, H3, V22b). The prefixes are those of the build's step subjects (and of git
-- log, when it is there). Not ids: F<n> is a key (F7, F8, the F10 panel), FX<nn> a lint rule (FX01-FX12), C<n> a
-- Crimson-Arena rule (C1-C27) and P1-P3 a call priority.
local STEP = {}
for kind in
    ([[A AP B BK BL BOOT DOC FIN FM FX G H K L LOC LP M MG MOD N O OP P PLAN Q R RP S SALE T TR UI V VC WF WP
    X Z]]):gmatch('%S+')
do
    STEP[kind] = true
end
for _, subject in ipairs(Lines('git -C "' .. REPO .. '" log --format=%s 2>/dev/null')) do
    local kind = subject:match('^(%u+)%d+')
    if kind and kind ~= 'C' and kind ~= 'F' then STEP[kind] = true end
end
local NOT_STEP = { P1 = true, P2 = true, P3 = true }
local function StepIds(s)
    local hits = {}
    for kind, num, suffix in s:gmatch('%f[%w](%u+)(%d+)([%u%l]?)%f[^%w]') do
        local id = kind .. num .. suffix
        if STEP[kind] and not NOT_STEP[kind .. num] and not (kind == 'FX' and #num == 2) then hits[#hits + 1] = id end
    end
    -- the build's name is build history too
    for word in s:gmatch('[Pp]arity%-plus') do hits[#hits + 1] = word end
    return hits
end
H.eq(table.concat(StepIds('(WF5A) WF5F-1 (MG3) (FM5, FIN4) SALE3: (UI6) H3 added VC1 V14\'s V22b'), ' '),
    'WF5A WF5F MG3 FM5 FIN4 SALE3 UI6 H3 VC1 V14 V22b', 'the step id scan finds every form of a step id')
H.eq(table.concat(StepIds('F7 (F8) the F10 panel FX01-FX12 C9 Tactical P1 utf8mb4 MB4 fx10_loops.lua'), ' '), '',
    'the step id scan leaves keys, lint rules, Arena rules and priorities alone')
for _, rel in ipairs(files) do
    if rel:match('%.md$') and not rel:match('CHANGELOG%.md$') then
        local hits = StepIds(ReadRepo(rel:gsub('^%./', '')) or '')
        H.eq(table.concat(hits, ', '), '', rel:gsub('^%./', '') .. ': no step or plan ids in it')
    end
end

-- no build history in the resource's code comments either: no step or plan ids, review notes or design file names
-- (the migrations and the SPEC-copied config/blocks.lua are left as they are; (F7) is a key)
local CODE_STEP = {}
for kind in ('K L M N O P V RP T AP F G H Z LP OP R WF S VC DOC TR FX'):gmatch('%S+') do CODE_STEP[kind] = true end
local codeHits = {}
for _, rel in ipairs(files) do
    local path = rel:gsub('^%./', '')
    local lua, web = path:match('%.lua$'), path:match('%.tsx?$')
    if path:match('^Crimson%-Police/') and (lua or web) and not path:match('/migrations/')
        and path ~= 'Crimson-Police/config/blocks.lua' then
        local n = 0
        for ln in ((ReadRepo(path) or '') .. '\n'):gmatch('(.-)\n') do
            n = n + 1
            local at = lua and ln:find('--', 1, true) or (web and (ln:find('^%s*//') or ln:find('[^:]//')))
            local c = at and ln:sub(at) or ''
            local bad = c:find('BLIPS_FINAL', 1, true) or c:find('%f[%a]critic%f[%A]') or c:find('PLAN %u+%d')
            for word, id in c:gmatch('(%a+) (%u+%d+)') do
                if (word == 'step' or word == 'Step' or word == 'steps' or word == 'STEP')
                    and CODE_STEP[id:match('^%u+')] then
                    bad = true
                end
            end
            for id in c:gmatch('%((%u+%d+%l?)[%),;]') do
                local kind = id:match('^%u+')
                if CODE_STEP[kind] and kind ~= 'F' then bad = true end
            end
            if bad then codeHits[#codeHits + 1] = path .. ':' .. n end
        end
    end
end
H.eq(table.concat(codeHits, ', '), '', 'no step or plan ids in the code comments')

-- the README's console example names the newest migration's version
local newest = 0
for _, name in ipairs(Lines('ls "' .. REPO .. 'Crimson-Police/sql/migrations"')) do
    local num = name:match('^(%d+)_.*%.sql$')
    if num and tonumber(num) > newest then newest = tonumber(num) end
end
H.ok(
    newest > 0 and Has(readme, ('saves folder at version %d\n'):format(newest))
        and Has(readme, ('`Crimson-Police database at version %d`'):format(newest)),
    'README: the console example shows version ' .. newest
)

-- ============================================================================
--                   README: CONTENTS, COMMANDS, CONFIG KEYS
-- ============================================================================

-- in the README and the owner guide every numbered heading is in the contents, every link of the contents has its
-- heading, and every link from one to a heading of the other lands on one
local function Slug(t) return (t:lower():gsub('[^%w%s%-_]', ''):gsub('%s', '-')) end
local function Headings(doc)
    local slugs, numbered = {}, {}
    local fence = false
    for ln in (doc .. '\n'):gmatch('(.-)\n') do
        if ln:match('^```') then fence = not fence end
        local hashes, text = ln:match('^(#+) (.+)$')
        if hashes and not fence and #hashes >= 2 then
            slugs[Slug(text)] = true
            if text:match('^%d') then numbered[#numbered + 1] = Slug(text) end
        end
    end
    return slugs, numbered
end
local docHeads = {}
for name, doc in pairs({ README = readme, guide = guide }) do
    local slugs, numbered = Headings(doc)
    docHeads[name] = slugs
    local contents = doc:match('\n## Contents\n(.-)\n%-%-%-\n') or ''
    H.ok(#contents > 500, name .. ' has its contents')
    for anchor in contents:gmatch('%]%(#([^)]+)%)') do
        H.ok(slugs[anchor], name .. ' contents: #' .. anchor .. ' is a heading')
    end
    for _, slug in ipairs(numbered) do
        H.ok(Has(contents, '(#' .. slug .. ')'), name .. ' contents lists #' .. slug)
    end
end
for _, l in ipairs({
    { readme, 'README', '#', 'README' },
    { readme, 'README', 'docs/OWNER_GUIDE.md#', 'guide' },
    { guide, 'guide', '#', 'guide' },
    { guide, 'guide', '../README.md#', 'README' },
}) do
    local bad = {}
    for target in l[1]:gmatch('%]%(' .. l[3]:gsub('%p', '%%%0') .. '([^)]+)%)') do
        if not docHeads[l[4]][target] then bad[#bad + 1] = target end
    end
    H.eq(table.concat(bad, ' '), '', l[2] .. ': every link to ' .. l[4] .. ' lands on a heading')
end

-- ============================================================================
--                                EVERY DOCUMENT
-- ============================================================================
-- LINKS, ANCHORS, FILE:LINE REFERENCES, THE README ORDER.

-- the lines of a document outside its ``` fences, with their line numbers
local function Prose(doc)
    local out, fence, n = {}, false, 0
    for ln in (doc .. '\n'):gmatch('(.-)\n') do
        n = n + 1
        if ln:match('^%s*```') then
            fence = not fence
        elseif not fence then
            out[#out + 1] = { n = n, text = ln }
        end
    end
    return out
end

-- a path relative to the repository: '..' and '.' resolved; nil when it climbs out of the repository
local function Norm(path)
    local parts = {}
    for seg in path:gmatch('[^/]+') do
        if seg == '..' then
            if #parts == 0 then return nil end
            parts[#parts] = nil
        elseif seg ~= '.' then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, '/')
end

-- every tracked file, and every folder that holds one
local trackedFiles, trackedDirs = {}, { [''] = true }
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files')) do
    trackedFiles[path] = true
    local dir = path
    while true do
        dir = dir:match('^(.+)/[^/]+$')
        if not dir then break end
        trackedDirs[dir] = true
    end
end
local function Exists(path) return path ~= nil and (trackedFiles[path] or trackedDirs[path]) and true or false end

-- the anchors of a document, as GitHub makes them (a repeated heading gets -1, -2, ...)
local function Anchors(doc)
    local out, count = {}, {}
    for _, l in ipairs(Prose(doc)) do
        local text = l.text:match('^#+ (.+)$')
        if text then
            local slug = Slug((text:gsub('%[([^%]]*)%]%b()', '%1')))
            if count[slug] then
                count[slug] = count[slug] + 1
                out[slug .. '-' .. count[slug]] = true
            else
                count[slug] = 0
                out[slug] = true
            end
        end
    end
    return out
end

local mdFiles = Lines('git -C "' .. REPO .. '" ls-files "*.md"')
H.ok(#mdFiles >= 15, ('git lists the documents (%d)'):format(#mdFiles))
local anchorsOf = {}
local function AnchorsOf(path)
    if anchorsOf[path] == nil then anchorsOf[path] = Anchors(ReadRepo(path) or '') end
    return anchorsOf[path]
end
local linksChecked, brokenLinks = 0, {}
for _, rel in ipairs(mdFiles) do
    local dir = rel:match('^(.+)/[^/]+$')
    for _, l in ipairs(Prose(ReadRepo(rel) or '')) do
        for target in l.text:gmatch('%]%(([^)%s]+)%)') do
            if not target:match('^%a[%w+.-]*:') then
                linksChecked = linksChecked + 1
                local path, anchor = target:match('^([^#]*)#?(.*)$')
                local dest = path == '' and rel or Norm((dir and dir .. '/' or '') .. path:gsub('/$', ''))
                local where = rel .. ':' .. l.n .. ' ' .. target
                if not Exists(dest) then
                    brokenLinks[#brokenLinks + 1] = where .. ' (no such file)'
                elseif anchor ~= '' and dest:match('%.md$') and not AnchorsOf(dest)[anchor] then
                    brokenLinks[#brokenLinks + 1] = where .. ' (no such heading)'
                end
            end
        end
    end
end
H.ok(linksChecked > 300, ('the documents\' links are read (%d)'):format(linksChecked))
H.eq(table.concat(brokenLinks, '; '), '', 'every relative link of every document lands on a file and its heading')

-- a path:line or path:first-last reference names a line the file has. A reference into another resource (its line or
-- its section names that resource) or a made-up example is left alone; one into this repository must resolve.
local FOREIGN_REF = {
    'qbx_',
    'sc-',
    'ox_',
    'oxmysql',
    'Renewed',
    'ps-',
    'Crimson-Arena',
    'rimson-Contracts',
    'rimson-contracts',
    'identifier.',
    'ref/',
    'src/',
    'lb-',
    'npwd',
    'qs-',
}
local EXAMPLE_REF = { 'night_beat.lua', 'zz_demo_spec.lua', 'modules/foo' }
local function Mentions(s, list)
    for _, needle in ipairs(list) do
        if Has(s, needle) then return true end
    end
    return false
end
local lineCount = {}
local function LinesOf(path)
    if not lineCount[path] then
        local n = 0
        for _ in ((ReadRepo(path) or '') .. '\n'):gmatch('[^\n]*\n') do n = n + 1 end
        lineCount[path] = n - 1
    end
    return lineCount[path]
end
local OWN_PREFIX = { 'Crimson-Police/', 'tests/', 'tools/', 'docs/', '.github/' }
local function LineRefs(rel, doc)
    local bad, checked, heads = {}, 0, {}
    for _, l in ipairs(Prose(doc)) do
        local hashes = l.text:match('^(#+) ')
        if hashes then
            for k = #hashes, 9 do heads[k] = nil end
            heads[#hashes] = l.text
        end
        local context = l.text
        for k = 1, 9 do context = context .. ' ' .. (heads[k] or '') end
        for path, a, b in l.text:gmatch('([%w_%./%-]+%.%a+):(%d+)%-?(%d*)') do
            path = path:gsub('^%./', '')
            local found
            for _, base in ipairs({ '', 'Crimson-Police/', 'Crimson-Police/modules/' }) do
                local p = Norm(base .. path)
                if p and trackedFiles[p] then
                    found = p
                    break
                end
            end
            local own = false
            for _, prefix in ipairs(OWN_PREFIX) do
                if path:sub(1, #prefix) == prefix then own = true end
            end
            local foreign = not own and (Mentions(context, FOREIGN_REF) or Mentions(context, EXAMPLE_REF))
            local last = math.max(tonumber(a), tonumber(b) or 0)
            if found and (own or path:find('/', 1, true) or not foreign) then
                checked = checked + 1
                if last > LinesOf(found) then
                    bad[#bad + 1] = ('%s:%d %s:%s (%s has %d lines)'):format(rel, l.n, path, a, found, LinesOf(found))
                end
            elseif not found and not foreign then
                bad[#bad + 1] = ('%s:%d %s (no such file here, and no other resource named)'):format(rel, l.n, path)
            end
        end
    end
    return bad, checked
end
do
    local probe = 'x\n`tests/docs_spec.lua:999999` and `modules/runs/gone.lua:3`\n### sc-dispatch\n`client/main.lua:9`\n'
    local bad = LineRefs('probe', probe)
    H.eq(#bad, 2, 'the file:line scan fails a line past the end and a file that is not there, not another resource')
    local refBad, refChecked = {}, 0
    for _, rel in ipairs(mdFiles) do
        local b, n = LineRefs(rel, ReadRepo(rel) or '')
        refChecked = refChecked + n
        for _, x in ipairs(b) do refBad[#refBad + 1] = x end
    end
    H.ok(refChecked >= 1, ('the file:line references into this repository are read (%d)'):format(refChecked))
    H.eq(table.concat(refBad, '; '), '', 'every file:line reference of the documents names a line its file has')
end

-- the README's nine parts, in this order (the contents and the other documents link them by number)
do
    local want = {
        'What Crimson-Police is',
        'What you need',
        'Install in 5 minutes',
        'Admins, supervisors and permissions',
        'Debug, storage and what ships off',
        'All commands and keys',
        'Admin UI tour',
        'Troubleshooting',
        'More documents',
    }
    local got = {}
    for _, l in ipairs(Prose(readme)) do
        local num, title = l.text:match('^## (%d+)%. (.+)$')
        if num then got[#got + 1] = num .. '. ' .. title end
    end
    local expect = {}
    for i, title in ipairs(want) do expect[i] = i .. '. ' .. title end
    H.eq(table.concat(got, ' | '), table.concat(expect, ' | '), 'README parts 1-9 come in their order')
    local wrong, prev, part = {}, 0, 0
    for _, l in ipairs(Prose(readme)) do
        local num = l.text:match('^## (%d+)%. ')
        if num then part, prev = tonumber(num), 0 end
        local a, b = l.text:match('^### (%d+)%.(%d+) ')
        if a then
            a, b = tonumber(a), tonumber(b)
            if a ~= part or b ~= prev + 1 then wrong[#wrong + 1] = a .. '.' .. b end
            prev = b
        end
    end
    H.eq(table.concat(wrong, ' '), '', 'README: every n.m sits under part n, numbered 1, 2, 3, ...')
end

-- 6.1 lists every command Crimson-Police registers, and nothing else
local commands = readme:match('\n### 6%.1 Commands\n(.-)\n### 6%.2') or ''
local registered = {
    [Cfg.Tablet.command] = true,
    [Cfg.Tablet.adminCommand] = true,
    [Cfg.RealPlayers.volunteer.command] = true,
    [Cfg.RealPlayers.criminalTablet.command] = true,
    [Cfg.RealPlayers.surrender.command] = true,
    [Cfg.Training.command] = true,
}
local diag = ReadRepo('Crimson-Police/modules/admin/client/diag.lua') or ''
registered[diag:match('\nlocal COMMAND = \'([%w_]+)\'') or '?'] = true
local listed = {}
for name in commands:gmatch('\n| `/?([%w_]+)') do listed[name] = true end
for name in pairs(registered) do H.ok(listed[name], 'README 6.1 lists ' .. name) end
for name in pairs(listed) do H.ok(registered[name], 'README 6.1: ' .. name .. ' is a registered command') end

-- every admin subcommand of the table exists in the code, and every one in the code is in the table
local admin = ReadRepo('Crimson-Police/modules/admin/admin.lua') or ''
local subs = {}
for sub in admin:gmatch('\nSUB%.([%w_]+) = function') do subs[sub] = true end
for _, rel in ipairs(files) do
    if rel:match('^%.?/?Crimson%-Police/modules/.*%.lua$') then
        local s = ReadRepo(rel:gsub('^%./', '')) or ''
        for sub in s:gmatch('CP%.Admin%.registerSubcommand%(\'([%w_]+)\'') do subs[sub] = true end
    end
end
local adminCmd = Cfg.Tablet.adminCommand
local inTable = {}
for sub in commands:gmatch('`/?' .. adminCmd .. ' ([%w_]+)') do inTable[sub] = true end
for sub in pairs(subs) do H.ok(Has(commands, adminCmd .. ' ' .. sub), 'README 6.1 lists the subcommand ' .. sub) end
for sub in pairs(inTable) do H.ok(subs[sub], 'README 6.1: ' .. sub .. ' is a subcommand in the code') end

-- every Config key the owner documents names a real setting (keys of other resources and wildcards left out)
local FOREIGN = {
    Roster = true,
    Police = true,
    DispatchIntegration = true,
    Integrations = true,
    DispatcherMode = true,
    ArenaIntegration = true,
}
local owner = { 'README.md', 'docs/OWNER_GUIDE.md', 'Crimson-Police/README.md', 'docs/IN_GAME_TEST_PLAN.md' }
for _, rel in ipairs(files) do
    if rel:match('^%./Crimson%-Police/.+/README%.md$') then owner[#owner + 1] = rel:gsub('^%./', '') end
end
local keys = 0
for _, rel in ipairs(owner) do
    local s = ReadRepo(rel) or ''
    -- the owner guide's Baked in part names the keys an update removed (tests/baked_in_spec.lua checks that table)
    s = s:gsub('\n### [%d%.]+ Baked in[^\n]*\n.-\n## ', '\n## ')
    local seen = {}
    for path, after in s:gmatch('%f[%w]Config%.([%w_%.]+)(.?)') do
        path = path:gsub('%.+$', '')
        local top = path:match('^[%w_]+')
        if not seen[path] and not FOREIGN[top] and after ~= '*' and after ~= '<' and path ~= 'X' then
            seen[path] = true
            keys = keys + 1
            H.ok(Node(Cfg, path) ~= nil, rel .. ' names Config.' .. path .. ', which exists')
        end
    end
end
H.ok(keys > 200, ('the owner docs name the settings (%d)'):format(keys))

-- ============================================================================
--                      README 5.2: WHAT SHIPS OFF AND ON
-- ============================================================================

local ships = readme:match('\n### 5%.2 What ships off and how to turn it on\n(.-)\n## ') or ''
local offPart, moneyPart, onPart = ships:match('%*%*Ships off%*%*(.-)%*%*Admin money tools%*%*(.-)%*%*Ships on%*%*(.*)')
H.ok(offPart ~= nil, 'README 5.2 has its three parts')
offPart, moneyPart, onPart = offPart or '', moneyPart or '', onPart or ''
local settings = ReadRepo('Crimson-Police/modules/admin/settings.lua') or ''
local features = settings:match('\nPlay%.features = (%b{})') or ''
local n = 0
for path in features:gmatch('path = \'([^\']+)\'') do
    n = n + 1
    local value = Node(Cfg, path)
    local part = value == true and onPart or offPart
    H.ok(Has(part, '`Config.' .. path .. '`'),
        ('README 5.2 lists Config.%s under ships %s'):format(path, value == true and 'on' or 'off'))
end
H.ok(n >= 40, ('every Features tab switch is checked (%d)'):format(n))
local money = settings:match('\nlocal MONEY_SWITCHES = (%b{})') or ''
for path in money:gmatch('\'([%w_%.]+)\'') do
    H.eq(Node(Cfg, path), false, 'the money tool Config.' .. path .. ' ships off')
    H.ok(Has(moneyPart, '`Config.' .. path .. '`'), 'README 5.2 lists the money tool Config.' .. path)
end
H.eq(Cfg.Debug, true, 'Debug ships on, as 5.2 says')
H.eq(Cfg.Database.enabled, false, 'the database ships off, as 5.2 says')
H.eq(Cfg.Builder.requireTestToPublish, false, 'testing is never required, as 5.2 says')
H.ok(Has(ships, '`Config.Builder.requireTestToPublish = false`'), 'README 5.2 says testing is never required')

-- ============================================================================
--             FILE_NOTES: ONE LINE PER FILE, ONLY FILES THAT EXIST
-- ============================================================================

local notes = ReadRepo('docs/dev/FILE_NOTES.md') or ''
local entries, long = 0, 0
for path, purpose in notes:gmatch('\n%- `([^`]+)`: ([^\n]*)') do
    entries = entries + 1
    local f = io.open(REPO .. path, 'r')
    H.ok(f ~= nil, 'FILE_NOTES: ' .. path .. ' exists')
    if f then f:close() end
    if #purpose > 400 then long = long + 1 end
end
H.ok(entries > 400, ('FILE_NOTES has a line per source file (%d)'):format(entries))
H.eq(notes:find('\n## ', 1, true), nil, 'FILE_NOTES has no per-file sections (the details stay in the files)')
H.eq(notes:find('```', 1, true), nil, 'FILE_NOTES quotes no headers')
H.eq(long, 0, 'every FILE_NOTES line is one sentence')
H.ok(#notes < 150000, ('FILE_NOTES stays small (%d bytes)'):format(#notes))

-- ARCHITECTURE: one place per module (no second "module notes" part), no build-history narration, every section it
-- names exists, and it stays small (its module sections keep the names and rules; the code headers have the rest)
local arch = ReadRepo('docs/dev/ARCHITECTURE.md') or ''
H.ok(#arch > 100000 and #arch < 380000, ('ARCHITECTURE stays small (%d bytes)'):format(#arch))
H.eq(arch:find('\n## 13.', 1, true), nil, 'ARCHITECTURE has no separate module notes part')
for _, phrase in ipairs({ 'owner request of', 'as before', 'Contract interpretations', 'this slice' }) do
    H.eq(arch:find(phrase, 1, true), nil, 'ARCHITECTURE has no history phrase: ' .. phrase)
end
local heads = {}
for num in arch:gmatch('\n#+ (%d[%d%.]*)[ .]') do heads[(num:gsub('%.$', ''))] = true end
local unknown = {}
for num in (arch .. ' '):gmatch('§ ?(%d[%d%.]*)') do
    num = num:gsub('%.$', '')
    if not heads[num] then unknown[#unknown + 1] = num end
end
H.eq(table.concat(unknown, ' '), '', 'every ARCHITECTURE section it names exists')
for _, rel in ipairs(files) do
    local s = ReadRepo(rel:gsub('^%./', '')) or ''
    H.eq(s:find('ARCHITECTURE.md ' .. '§13', 1, true), nil, rel .. ': names no removed ARCHITECTURE section 13')
end
H.eq((ReadRepo('docs/dev/TESTING.md') or ''):find('before the ' .. 'speed-up', 1, true), nil,
    'TESTING has no old timing story')

-- SPEC: it stays cut down, carries no build history, and every ARCHITECTURE section it names exists
local prose = spec
H.ok(#prose > 100000, ('SPEC keeps its rules (%d bytes)'):format(#prose))
for _, phrase in ipairs({ 'owner request of', 'owner\'s request of', 'as before', 'owner decision of', 'as today' }) do
    H.eq(prose:find(phrase, 1, true), nil, 'SPEC has no history phrase: ' .. phrase)
end
local specUnknown = {}
for num in (prose .. ' '):gmatch('ARCHITECTURE%.md §(%d[%d%.]*)') do
    num = num:gsub('%.$', '')
    if not heads[num] then specUnknown[#specUnknown + 1] = num end
end
H.eq(table.concat(specUnknown, ' '), '', 'every ARCHITECTURE section SPEC names exists')
H.eq(prose:find('\nFolder layout\n', 1, true), nil, 'SPEC keeps no copy of the ARCHITECTURE folder layout')
H.eq(prose:find('CREATE TABLE cp_', 1, true), nil, 'SPEC restates no migration: the tables point at sql/migrations')

-- step FX1: a disconnect on the Weekly Boss costs its mission cooldown and that week's attempt, never the type cooldown
-- (modules/runs/draw skips the type cooldown for the boss); every SPEC line about the disconnect cooldown says so
for line in spec:gmatch('[^\n]+') do
    local lower = line:lower()
    if lower:find('disconnect', 1, true) and lower:find('type cooldown', 1, true) then
        H.ok(line:find('Weekly Boss', 1, true) ~= nil, 'SPEC names the Weekly Boss exception: ' .. line:sub(1, 70))
    end
end

-- Z8B: Sys.storageCopy ends the lock (Maint.finish) for a copy into the store not in use and for a refusal before
-- any write, so the SPEC's maintenance lock line names that exception to "until the owner restarts"
do
    local lockLine = spec:match('\n%- Maintenance lock:[^\n]+') or ''
    H.ok(lockLine:find('store not in use', 1, true) ~= nil, 'Z8B: SPEC: a copy into the other store ends the lock')
end

-- ============================================================================
--                        THE MAP KEEPS UP WITH THE CODE
-- ============================================================================
-- Step H1: every name the code has.

local integrations = ReadRepo('docs/dev/INTEGRATIONS.md') or ''
local loops = ReadRepo('docs/dev/LOOPS.md') or ''
local surface = arch .. '\n' .. integrations

-- The text from a heading that starts with `head` to the next heading of that level or above.
local function Section(doc, head)
    local at = doc:find('\n' .. head, 1, true)
    if not at then return '' end
    local level = #(head:match('^(#+)') or '#')
    local rest = doc:sub(at + 1)
    local stop = nil
    for pos, hashes in rest:gmatch('()\n(#+) ') do
        if pos > 1 and #hashes <= level then
            stop = pos
            break
        end
    end
    return stop and rest:sub(1, stop) or rest
end

-- name is in doc as a whole name (the next character is not part of a longer name)
local function Named(doc, name)
    local from = 1
    while true do
        local a, b = doc:find(name, from, true)
        if not a then return false end
        if not doc:sub(b + 1, b + 1):match('[%w_]') then return true end
        from = b + 1
    end
end

-- A grouped row names the rest of its actions without their prefix: `server:admin:a`, `b` on one line, or a section
-- whose heading names `<prefix><name>` and lists `b` (the builder actions of §5.28.4).
local function Shorthand(doc, name)
    local prefix, short = name:match('^(.+:)([%w_]+)$')
    if not prefix then return false end
    local tick = '`' .. short .. '`'
    for line in doc:gmatch('[^\n]+') do
        if Has(line, prefix) and Has(line, tick) then return true end
    end
    for head in doc:gmatch('\n(#+ [^\n]*`' .. prefix:gsub('%p', '%%%0') .. '<name>`[^\n]*)') do
        if Has(Section(doc, head), tick) then return true end
    end
    return false
end

-- the game's own events a resource handles, documented by FiveM
local ENGINE = {
    onResourceStart = true,
    onResourceStop = true,
    onClientResourceStart = true,
    onClientResourceStop = true,
}

_G.CP_INVENTORY_LIB = true
local okInv, Inv = pcall(dofile, 'tools/capability_inventory.lua')
_G.CP_INVENTORY_LIB = nil
local okList, inventory = false, nil
if okInv then okList, inventory = pcall(Inv.inventory) end
H.ok(okList and type(inventory) == 'table' and #inventory > 1000, 'H1: the capability inventory builds')
local nui91 = Section(arch, '### 9.1 ')
H.ok(#nui91 > 1000, 'H1: ARCHITECTURE has §9.1')
local missingNet, checked = {}, 0
for _, line in ipairs(okList and inventory or {}) do
    local kind, name = line:match('^(%S+) %S+ (%S+)')
    if kind == 'nui' then
        checked = checked + 1
        if not Has(nui91, '`' .. name .. '`') then missingNet[#missingNet + 1] = 'nui ' .. name end
    elseif kind == 'event' or kind == 'callback' or kind == 'action' then
        checked = checked + 1
        local short = name:gsub('^crimson%-police:', '')
        if not ENGINE[short] and not Named(surface, short) and not Shorthand(arch, short) then
            missingNet[#missingNet + 1] = kind .. ' ' .. short
        end
    end
end
H.ok(checked > 500, ('H1: every event, callback, action and NUI callback is checked (%d)'):format(checked))
H.eq(table.concat(missingNet, ', '), '',
    'H1: ARCHITECTURE §8 / §9.1 or INTEGRATIONS names every event, callback, action and NUI callback of the inventory')

-- every source file the repository tracks has its FILE_NOTES line (the data folders and the build are named in its
-- intro instead)
local SOURCE = { lua = true, ts = true, tsx = true, py = true, sh = true, mjs = true, cjs = true, sql = true }
local DATA = { 'Crimson-Police/web/dist/', 'Crimson-Police/missions/builtin/', 'Crimson-Police/sql/migrations/' }
local listed = {}
for path in notes:gmatch('\n%- `([^`]+)`: ') do listed[path] = true end
local tracked, unlisted = 0, {}
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files')) do
    local ext = path:match('%.(%w+)$')
    local data = false
    for _, d in ipairs(DATA) do
        if path:sub(1, #d) == d then data = true end
    end
    if ext and SOURCE[ext] and not data then
        tracked = tracked + 1
        if not listed[path] then unlisted[#unlisted + 1] = path end
    end
end
H.ok(tracked > 600, ('H1: git lists the source files (%d)'):format(tracked))
H.eq(table.concat(unlisted, ', '), '', 'H1: FILE_NOTES has a line for every tracked source file')
for _, d in ipairs(DATA) do
    H.ok(Has(notes:sub(1, 1200), d:gsub('/$', '')), 'H1: FILE_NOTES names what it leaves out: ' .. d)
end

-- every CP table a file makes (`CP.X = CP.X or ...`) is named in ARCHITECTURE
local tables, unnamed = 0, {}
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files "Crimson-Police/*.lua"')) do
    local src = ReadRepo(path) or ''
    for name in src:gmatch('\nCP%.(%u[%w_]*) = CP%.%1 or') do
        tables = tables + 1
        if not Named(arch, 'CP.' .. name) then unnamed[#unnamed + 1] = 'CP.' .. name .. ' (' .. path .. ')' end
    end
end
H.ok(tables > 50, ('H1: the CP tables are found (%d)'):format(tables))
H.eq(table.concat(unnamed, ', '), '', 'H1: ARCHITECTURE names every CP table')

-- §1 lists every shared file, config file and owner document
local layout = Section(arch, '## 1. ')
local layoutMissing = {}
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files Crimson-Police/shared Crimson-Police/config docs')) do
    local short = path:match('^Crimson%-Police/(.+%.lua)$') or path:match('^(docs/[^/]+%.md)$')
    if short and not Has(layout, short) then layoutMissing[#layoutMissing + 1] = short end
end
H.eq(table.concat(layoutMissing, ', '), '', 'H1: ARCHITECTURE §1 lists every shared and config file and owner document')
local sharedFiles = {}
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files "Crimson-Police/shared/*.lua"')) do
    sharedFiles[#sharedFiles + 1] = path:match('([^/]+)%.lua$')
end
table.sort(sharedFiles)
H.ok(#sharedFiles > 10 and Has(layout:gsub('%s+', ' '), '(alphabetical: ' .. table.concat(sharedFiles, ', ') .. ')'),
    'H1: ARCHITECTURE §1 gives the shared load order in full')

-- every file LOOPS names exists, and its anticheat interval is the code's
local ghost = {}
for t in loops:gmatch('[%w_%./%-]+%.lua') do
    local rel = t:gsub('^%./', '')
    local found = false
    for _, base in ipairs({ '', 'Crimson-Police/', 'Crimson-Police/modules/' }) do
        local f = io.open(REPO .. base .. rel, 'r')
        if f then
            f:close()
            found = true
            break
        end
    end
    if not found then ghost[#ghost + 1] = t end
end
H.eq(table.concat(ghost, ', '), '', 'H1: every file LOOPS names exists')
local tick = tonumber((ReadRepo('Crimson-Police/modules/review/anticheat.lua') or ''):match('\nlocal TICK_MS = (%d+)'))
H.ok(tick ~= nil, 'H1: anticheat has its TICK_MS')
local loopLines = {}
for line in (loops .. '\n'):gmatch('([^\n]*)\n') do loopLines[#loopLines + 1] = line end
for i, line in ipairs(loopLines) do
    local at = line:find('anticheat', 1, true)
    if at and tick then
        local after = line:sub(at) .. ' ' .. (loopLines[i + 1] or '')
        local n, unit = after:match('(%d+) (m?s)[%s,:;%)|]')
        if n then
            local ms = tonumber(n) * (unit == 's' and 1000 or 1)
            H.eq(ms, tick, ('H1: LOOPS line %d gives the anticheat interval of the code'):format(i))
        end
    end
end

-- §8.2 names every other resource's server event a client can send (RegisterNetEvent), and §8.3 every key mapping
local s82 = Section(arch, '### 8.2 ')
local keysLine = (Section(arch, '### 8.3 '):match('\nKey mappings:(.-)\n\n') or '')
local foreignNet, keyNames, unlistedNet, unlistedKeys = 0, 0, {}, {}
for _, path in ipairs(Lines('git -C "' .. REPO .. '" ls-files "Crimson-Police/*.lua"')) do
    local src = ReadRepo(path) or ''
    for ev in src:gmatch('RegisterNetEvent%(\'([^\']+:server:[^\']+)\'') do
        if not ev:find('^crimson%-police:') then
            foreignNet = foreignNet + 1
            if not Has(s82, ev) and not Shorthand(s82, ev) then unlistedNet[#unlistedNet + 1] = ev end
        end
    end
    for key in src:gmatch('\nlocal [%u_]+ = \'(%+?crimsonpolice_[%w_]+)\'') do
        keyNames = keyNames + 1
        if not Has(keysLine, '`' .. key .. '`') then unlistedKeys[#unlistedKeys + 1] = key end
    end
end
H.ok(foreignNet >= 7 and keyNames >= 5,
    ('H1: the foreign net events (%d) and key mappings (%d) are found'):format(foreignNet, keyNames))
H.eq(table.concat(unlistedNet, ', '), '', 'H1: ARCHITECTURE §8.2 names every client-sendable event of another resource')
H.eq(table.concat(unlistedKeys, ', '), '', 'H1: ARCHITECTURE §8.3 Key mappings names every key mapping')

-- H2: FiveM asset escrow encrypts every .lua file escrow_ignore does not list. A .lua file the manifest does not load
-- as a script is one a city reads or pastes (a mission, the ox_inventory item snippet), so escrow_ignore must cover it.
do
    local Block = H.manifestGlobs
    local function Any(pats, f)
        for _, lp in ipairs(pats) do if f:match(lp) then return true end end
        return false
    end
    local scripts = {}
    for _, b in ipairs({ 'shared_scripts', 'server_scripts', 'client_scripts' }) do
        for _, lp in ipairs(Block(b)) do scripts[#scripts + 1] = lp end
    end
    local ignored = Block('escrow_ignore')
    local files = Lines(
        'cd "' .. H.root .. '" && find . -name "*.lua" -not -path "./web/node_modules/*" | sed "s|^./||"')
    local loose = {}
    for _, f in ipairs(files) do
        if f ~= 'fxmanifest.lua' and not Any(scripts, f) and not Any(ignored, f) then loose[#loose + 1] = f end
    end
    table.sort(loose)
    H.ok(#scripts > 10 and #ignored >= 4 and #files > 100, 'H2: the manifest script and escrow_ignore lists are read')
    H.eq(table.concat(loose, ', '), '', 'H2: every .lua file the manifest does not load is in escrow_ignore')
end

-- ============================================================================
--             THE OWNER'S CONSOLE LINES, CHECKLIST AND TEST FACTS
-- ============================================================================

-- the console examples quote the mission load line as missions.lua prints it
do
    local missions = ReadRepo('Crimson-Police/modules/missions/missions.lua') or ''
    local fmt = missions:match('%[crimson%-police%] missions loaded: ([^\']+)\'') or ''
    H.ok(fmt:find('%d', 1, true) ~= nil, 'missions.lua prints the mission load line')
    local pat = '^missions loaded: ' .. fmt:gsub('%%d', '\1'):gsub('%p', '%%%0'):gsub('\1', '[%%dN]+')
    for _, rel in ipairs({ 'README.md', 'docs/IN_GAME_TEST_PLAN.md', 'docs/OWNER_GUIDE.md' }) do
        local n = 0
        for line in (ReadRepo(rel) or ''):gmatch('missions loaded:[^\n`]*') do
            n = n + 1
            H.ok(line:match(pat) ~= nil, rel .. ' quotes the mission load line as printed: ' .. line)
        end
        H.ok(n > 0, rel .. ' shows the mission load line')
    end
end

-- README 3.4's example warning is the start-up check's own text for a missing SAST job
do
    local parts = ReadRepo('Crimson-Police/locales/parts/access.json') or ''
    local text = parts:match('\n  "health%.dept%.no_job": "(.-)",?\n') or ''
    H.ok(#text > 50, 'the department job warning is in locales/parts/access.json')
    local line = text:gsub('{dept}', 'SAST'):gsub('{job}', 'sast'):gsub('{key}', 'sast')
    H.ok(Has(readme, '[crimson-police:confighealth] departments: ' .. line .. '\n'),
        'README 3.4 shows the department job warning as the console prints it')
end

local checklist = ReadRepo('docs/IN_GAME_CHECKLIST.md') or ''

-- the checklist names the supervisor grade the config ships
H.ok(Has(
    checklist:match('\n## Before you start\n(.-)\n## ') or '',
    ('(grade %d as shipped'):format(Cfg.Departments.sast.supervisorGrade)
), 'the checklist names the shipped SAST supervisor grade ' .. tostring(Cfg.Departments.sast.supervisorGrade))

-- the checklist opens with a first hour in game: 12 to 18 checks, each saying what you should see
do
    H.eq(checklist:match('\n## ([^\n]+)'), 'First hour in game', 'the checklist starts with its first hour in game')
    local first = checklist:match('\n## First hour in game\n(.-)\n## ') or ''
    local items = {}
    for ln in (first .. '\n'):gmatch('(.-)\n') do
        if ln:match('^%- %[ %] ') then
            items[#items + 1] = ln
        elseif ln:match('^  %S') and #items > 0 then
            items[#items] = items[#items] .. ' ' .. ln
        end
    end
    H.ok(#items >= 12 and #items <= 18, ('the first hour has about 15 checks (%d)'):format(#items))
    local blind = {}
    for _, item in ipairs(items) do
        if not item:find('->', 1, true) then blind[#blind + 1] = item:sub(7, 50) end
    end
    H.eq(table.concat(blind, '; '), '', 'every first-hour check says what you should see')
    H.ok(Has(first, '(IN_GAME_TEST_PLAN.md)'), 'the first hour links the full test plan')
end

-- TESTING states the gate as tools/check_all.sh runs it
do
    local testing = ReadRepo('docs/dev/TESTING.md') or ''
    local gate = ReadRepo('tools/check_all.sh') or ''
    local listed = Lines('cd "' .. REPO .. '" && bash tools/check_all.sh --list')
    local rows = {}
    for step in (testing:match('\n## The checks\n(.-)\n%*%*') or ''):gmatch('\n| `([%w%-]+)` |') do
        rows[#rows + 1] = step
    end
    H.ok(#listed >= 10 and Has(gate, '--list'), ('check_all.sh lists its steps (%d)'):format(#listed))
    H.eq(table.concat(rows, ' '), table.concat(listed, ' '), 'TESTING lists the gate steps in the order they run')
    local nightly = ReadRepo('.github/workflows/nightly.yml') or ''
    local named = {}
    for step in (nightly:match('bash tools/check_all%.sh ([%w%- ]+)\n') or ''):gmatch('%S+') do
        named[#named + 1] = '`' .. step .. '`'
    end
    H.ok(#named >= 1, 'nightly.yml names its opt-in steps')
    H.ok(Has(testing, '`.github/workflows/nightly.yml` runs ' .. table.concat(named, ' and ') .. ' every night'),
        'TESTING names the steps nightly.yml runs: ' .. table.concat(named, ' and '))
    H.ok(Has(testing, ('the SPEC stays under %d bytes'):format(SPEC_MAX)), 'TESTING gives the SPEC size the test uses')
end

-- STYLE gives the config's first key without a value the shipped config does not have
do
    local style = ReadRepo('docs/dev/STYLE.md') or ''
    local said = style:match('`Config%.Debug = (%a+)` is the first key')
    H.ok(said == nil or said == tostring(Cfg.Debug), 'STYLE: the first config key as shipped')
    H.ok(Has(style, '`Config.Debug` is the first key'), 'STYLE names Config.Debug as the first key')
end

-- ARCHITECTURE names only settings that exist (Config.X and the keys of other resources left out)
do
    local OTHER = {
        Roster = true,
        Police = true,
        DispatchIntegration = true,
        Integrations = true,
        ArenaIntegration = true,
        Prison = true,
        DispatchJobs = true,
        PoliceJobs = true,
        Dispatch = true,
        DispatcherMode = true,
    }
    local bad, seen, n = {}, {}, 0
    for path, after in arch:gmatch('%f[%w]Config%.([%w_%.]+)(.?)') do
        path = path:gsub('%.+$', '')
        local top = path:match('^[%w_]+')
        if not seen[path] and not OTHER[top] and after ~= '*' and after ~= '<' and after ~= '{' and top ~= 'X' then
            seen[path] = true
            n = n + 1
            if Node(Cfg, path) == nil then bad[#bad + 1] = path end
        end
    end
    H.ok(n > 150, ('ARCHITECTURE names the settings (%d)'):format(n))
    H.eq(table.concat(bad, ', '), '', 'every Config key ARCHITECTURE names exists in config.lua as shipped')
end

return H
