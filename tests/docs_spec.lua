-- The documents stay true to the code: the SPEC's config copies are the config files byte for byte, every document
-- a file names exists, the README's contents, commands, config keys and "What ships off" table match the code, and
-- FILE_NOTES names only files that exist.

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
local spec = ReadRepo('docs/SPEC.md') or ''
H.ok(#readme > 10000 and #spec > 10000, 'README and SPEC are readable')

-- ============================================================================
--                   THE SPEC'S CONFIG COPIES, BYTE FOR BYTE
-- ============================================================================

for _, c in ipairs({
    { 'Crimson-Police/config/config.lua', '\nconfig/blocks.lua holds the range' },
    { 'Crimson-Police/config/blocks.lua', '\n## Example files' },
}) do
    local file = ReadRepo(c[1]) or ''
    local at = spec:find(file, 1, true)
    H.ok(#file > 1000 and at ~= nil, 'docs/SPEC.md has ' .. c[1] .. ' byte for byte')
    H.eq(at and spec:sub(at - 2, at - 1), '\n\n', c[1] .. ': the copy starts on its own paragraph')
    H.eq(at and spec:sub(at + #file, at + #file + #c[2] - 1), c[2], c[2]:sub(2) .. ' follows the copy at once')
end

-- ============================================================================
--              THE DOCUMENT SET, AND EVERY DOCUMENT A FILE NAMES
-- ============================================================================

local DOCS = {
    'ARCHITECTURE.md',
    'FILE_NOTES.md',
    'INTEGRATIONS.md',
    'IN_GAME_CHECKLIST.md',
    'LOOPS.md',
    'SPEC.md',
    'STYLE.md',
    'TESTING.md',
    'WORKFLOWS.md',
}
local present = Lines('cd "' .. REPO .. 'docs" && find . -type f | sed "s|^\\./||" | LC_ALL=C sort')
H.eq(table.concat(present, ' '), table.concat(DOCS, ' '), 'docs/ holds the consolidated set, no notes folder')

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

-- no scratch paths or lost design files in the documents
for _, rel in ipairs(files) do
    if rel:match('%.md$') then
        local s = ReadRepo(rel:gsub('^%./', '')) or ''
        H.ok(not Has(s, '/tmp/claude') and not Has(s, 'scratchpad/') and not Has(s, 'DESIGN_FINAL'),
            rel .. ': names no scratch path')
    end
end

-- ============================================================================
--                   README: CONTENTS, COMMANDS, CONFIG KEYS
-- ============================================================================

-- every heading of sections 1-12 is in the contents, and every link of the contents has its heading
local function Slug(t) return (t:lower():gsub('[^%w%s%-_]', ''):gsub('%s', '-')) end
local slugs, numbered = {}, {}
local fence = false
for ln in (readme .. '\n'):gmatch('(.-)\n') do
    if ln:match('^```') then fence = not fence end
    local hashes, text = ln:match('^(#+) (.+)$')
    if hashes and not fence and #hashes >= 2 then
        slugs[Slug(text)] = true
        if text:match('^%d') then numbered[#numbered + 1] = Slug(text) end
    end
end
local contents = readme:match('\n## Contents\n(.-)\n%-%-%-\n') or ''
H.ok(#contents > 1000, 'README has its contents')
for anchor in contents:gmatch('%]%(#([^)]+)%)') do
    H.ok(slugs[anchor], 'README contents: #' .. anchor .. ' is a heading')
end
for _, slug in ipairs(numbered) do
    H.ok(Has(contents, '(#' .. slug .. ')'), 'README contents lists #' .. slug)
end

-- 8.1 lists every command Crimson-Police registers, and nothing else
local commands = readme:match('\n### 8%.1 Commands\n(.-)\n### 8%.2') or ''
local registered = {
    [Cfg.Tablet.command] = true,
    [Cfg.Tablet.adminCommand] = true,
    [Cfg.Volunteers.command] = true,
    [Cfg.CriminalTablet.command] = true,
    [Cfg.RealSuspects.surrender.command] = true,
}
local diag = ReadRepo('Crimson-Police/modules/diag/client.lua') or ''
registered[diag:match('\nlocal COMMAND = \'([%w_]+)\'') or '?'] = true
local listed = {}
for name in commands:gmatch('\n| `/?([%w_]+)') do listed[name] = true end
for name in pairs(registered) do H.ok(listed[name], 'README 8.1 lists ' .. name) end
for name in pairs(listed) do H.ok(registered[name], 'README 8.1: ' .. name .. ' is a registered command') end

-- every admin subcommand of the table exists in the code, and every one in the code is in the table
local admin = ReadRepo('Crimson-Police/modules/admin/server.lua') or ''
local subs = {}
for sub in admin:gmatch('\nSUB%.([%w_]+) = function') do subs[sub] = true end
for _, rel in ipairs(files) do
    if rel:match('server%.lua$') then
        local s = ReadRepo(rel:gsub('^%./', '')) or ''
        for sub in s:gmatch('CP%.Admin%.registerSubcommand%(\'([%w_]+)\'') do subs[sub] = true end
    end
end
local adminCmd = Cfg.Tablet.adminCommand
local inTable = {}
for sub in commands:gmatch('`/?' .. adminCmd .. ' ([%w_]+)') do inTable[sub] = true end
for sub in pairs(subs) do H.ok(Has(commands, adminCmd .. ' ' .. sub), 'README 8.1 lists the subcommand ' .. sub) end
for sub in pairs(inTable) do H.ok(subs[sub], 'README 8.1: ' .. sub .. ' is a subcommand in the code') end

-- every Config key the owner documents names a real setting (keys of other resources and wildcards left out)
local FOREIGN = {
    Roster = true,
    Police = true,
    DispatchIntegration = true,
    Integrations = true,
    DispatcherMode = true,
    ArenaIntegration = true,
}
local owner = { 'README.md', 'Crimson-Police/README.md' }
for _, rel in ipairs(files) do
    if rel:match('^%./Crimson%-Police/.+/README%.md$') then owner[#owner + 1] = rel:gsub('^%./', '') end
end
local keys = 0
for _, rel in ipairs(owner) do
    local s = ReadRepo(rel) or ''
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
--                      README 5.10: WHAT SHIPS OFF AND ON
-- ============================================================================

local ships = readme:match('\n### 5%.10 What ships off and how to turn it on\n(.-)\n## ') or ''
local offPart, moneyPart, onPart = ships:match('%*%*Ships off%*%*(.-)%*%*Admin money tools%*%*(.-)%*%*Ships on%*%*(.*)')
H.ok(offPart ~= nil, 'README 5.10 has its three parts')
offPart, moneyPart, onPart = offPart or '', moneyPart or '', onPart or ''
local settings = ReadRepo('Crimson-Police/modules/settings/server.lua') or ''
local features = settings:match('\nPlay%.features = (%b{})') or ''
local n = 0
for path in features:gmatch('path = \'([^\']+)\'') do
    n = n + 1
    local value = Node(Cfg, path)
    local part = value == true and onPart or offPart
    H.ok(Has(part, '`Config.' .. path .. '`'),
        ('README 5.10 lists Config.%s under ships %s'):format(path, value == true and 'on' or 'off'))
end
H.ok(n >= 40, ('every Features tab switch is checked (%d)'):format(n))
local money = settings:match('\nlocal MONEY_SWITCHES = (%b{})') or ''
for path in money:gmatch('\'([%w_%.]+)\'') do
    H.eq(Node(Cfg, path), false, 'the money tool Config.' .. path .. ' ships off')
    H.ok(Has(moneyPart, '`Config.' .. path .. '`'), 'README 5.10 lists the money tool Config.' .. path)
end
H.eq(Cfg.Debug, true, 'Debug ships on, as 5.10 says')
H.eq(Cfg.Database.enabled, false, 'the database ships off, as 5.10 says')
H.eq(Cfg.Builder.requireTestToPublish, false, 'testing is never required, as 5.10 says')
H.ok(Has(ships, '`Config.Builder.requireTestToPublish = false`'), 'README 5.10 says testing is never required')

-- ============================================================================
--                    FILE_NOTES NAMES ONLY FILES THAT EXIST
-- ============================================================================

local notes = ReadRepo('docs/FILE_NOTES.md') or ''
local sections = 0
for path in notes:gmatch('\n## (%S+)\n') do
    sections = sections + 1
    local f = io.open(REPO .. path, 'r')
    H.ok(f ~= nil, 'FILE_NOTES: ' .. path .. ' exists')
    if f then f:close() end
end
H.ok(sections > 200, ('FILE_NOTES has a section per long-headed file (%d)'):format(sections))

return H
