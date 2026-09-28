-- tests/run_ui_spec.lua · run_ui slice (Officer Mission Board + Active Mission screens, UI only).
--
-- The slice has no Lua and writes no SQL; this spec checks what the UI relies on from the Lua side and
-- the slice's own files:
--   * locales/parts/run_ui.json: flat object of non-empty strings, only board.* / run.* keys, no key
--     redefined from ui.json, identical text for keys other parts share, well-formed {var} placeholders,
--     loads through shared/locale.lua (CP.L interpolation) like locales/en.json in game;
--   * every literal t('…') / tOr('…') key in the two screens exists (own part or ui.json), and every key
--     of the part is used by a screen (no dead text);
--   * every err.* key the browser mocks answer with, and every key they translate, exists in some part;
--   * the screens use exactly the contract names (ARCHITECTURE §8/§9.4) for requests, actions, client
--     actions and push topics, keep a default export with no props, and never list individual missions;
--   * the slice CSS uses only --cp-* variables (no hex colours, no color-mix/:has), and every rule is
--     scoped by a run_ui- class;
--   * no SQL / MySQL anywhere in the slice files (nothing to run on MariaDB).
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local cjson = require('cjson')

local ROOT = H.root                                   -- .../Crimson-Police/
local WEB = ROOT .. 'web/src/'

local function read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function decode(path)
    local s = read(path)
    if not s then return nil, 'missing' end
    local ok, data = pcall(cjson.decode, s)
    if not ok then return nil, tostring(data) end
    return data
end

local FILES = {
    board = WEB .. 'officer/screens/MissionBoard.tsx',
    active = WEB .. 'officer/screens/ActiveMission.tsx',
    boardCss = WEB .. 'officer/screens/MissionBoard.css',
    activeCss = WEB .. 'officer/screens/ActiveMission.css',
    mock = WEB .. 'mocks/run_ui.mock.ts',
    types = WEB .. 'types/run_ui.ts',
    part = ROOT .. 'locales/parts/run_ui.json',
}

local src = {}
for k, path in pairs(FILES) do
    src[k] = read(path)
    H.ok(src[k] ~= nil and #src[k] > 0, 'slice file exists: ' .. path)
end

-- ── locale part ─────────────────────────────────────────────────────────────
local part, perr = decode(FILES.part)
H.ok(type(part) == 'table', 'run_ui.json parses (' .. tostring(perr) .. ')')
part = part or {}

local ui = decode(ROOT .. 'locales/parts/ui.json') or {}
local others = {}                                     -- key -> { text, file } from every other part
do
    local p = io.popen('ls ' .. ROOT .. 'locales/parts/*.json')
    for file in p:lines() do
        if not file:find('run_ui.json', 1, true) then
            local data = decode(file)
            if type(data) == 'table' then
                for k, v in pairs(data) do others[k] = others[k] or { text = v, file = file:match('([^/]+)$') } end
            end
        end
    end
    p:close()
end

local count = 0
for k, v in pairs(part) do
    count = count + 1
    H.ok(type(k) == 'string' and (k:match('^board%.[%w_.]+$') or k:match('^run%.[%w_.]+$')) ~= nil, 'key in the board./run. namespace: ' .. tostring(k))
    H.ok(type(v) == 'string' and #v > 0, 'non-empty string value: ' .. tostring(k))
    H.ok(ui[k] == nil, 'does not redefine a ui.json key: ' .. tostring(k))
    if others[k] ~= nil then
        H.eq(v, others[k].text, 'shared key ' .. k .. ' has the same text as ' .. others[k].file)
    end
    if type(v) == 'string' then
        -- placeholders: only {name} with [A-Za-z0-9_], braces balanced
        local stripped = v:gsub('{[%w_]+}', '')
        H.ok(not stripped:find('[{}]'), 'well-formed placeholders in ' .. k)
        H.ok(not v:find('`', 1, true), 'no backticks in ' .. k)
    end
end
H.ok(count >= 100, 'run_ui.json has the screens\' text (' .. count .. ' keys)')

-- The part loads through CP.L like locales/en.json (every part merged).
do
    local merged = {}
    for k, v in pairs(others) do merged[k] = v.text end
    for k, v in pairs(part) do merged[k] = v end
    local text = cjson.encode(merged)
    local realLoad = LoadResourceFile
    LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return text end
        return realLoad(res, path)
    end
    H.load('shared/locale.lua')
    H.eq(CP.L('board.card.mode_unit', { size = 3 }), 'Unit · 3', 'CP.L interpolates board.card.mode_unit')
    H.eq(CP.L('board.confirm.accept', { type = 'Tactical' }), 'Accept Tactical', 'CP.L board.confirm.accept')
    H.eq(CP.L('run.route.recalcs_left', { n = 2 }), 'Recalculations left: 2', 'CP.L run.route.recalcs_left')
    H.ok(CP.Locale.has('run.empty.title'), 'CP.Locale.has run.empty.title')
    H.ok(CP.L('board.confirm.abandon', { type = 'Patrol' }):find('drawn at random', 1, true) ~= nil, 'accept confirm says the mission is drawn at random')
    H.ok(CP.L('board.confirm.abandon', { type = 'Patrol' }):find('whole Patrol type on cooldown', 1, true) ~= nil, 'accept confirm names the type cooldown')
end

-- ── keys used by the screens ────────────────────────────────────────────────
local function literalKeys(text)
    local keys = {}
    for key in text:gmatch("[^%w_]t%('([%w_.]+)'") do keys[key] = true end
    for key in text:gmatch("tOr%('([%w_.]+)'") do keys[key] = true end
    for key in text:gmatch("tOr%([^,]+, '([%w_.]+)'") do keys[key] = true end
    for key in text:gmatch("success: '([%w_.]+)'") do keys[key] = true end
    return keys
end

local used = {}
for _, name in ipairs({ 'board', 'active' }) do
    for key in pairs(literalKeys(src[name] or '')) do
        used[key] = true
        H.ok(part[key] ~= nil or ui[key] ~= nil, ('screen key exists in run_ui.json or ui.json: %s (%s)'):format(key, name))
        if part[key] == nil and ui[key] == nil and others[key] ~= nil then
            print('  note: ' .. key .. ' only exists in ' .. others[key].file)
        end
    end
end
-- Dynamic keys: tier labels (tOr(`tier.${name}`, 'common.unknown')) come from ui.json.
for _, tier in ipairs({ 'standard', 'reinforced', 'heavy', 'major', 'critical' }) do
    H.ok(ui['tier.' .. tier] ~= nil, 'tier label in ui.json: ' .. tier)
end
for k in pairs(part) do
    H.ok(used[k] == true, 'part key is used by a screen: ' .. k)
end

-- ── keys the browser mocks answer with or translate ─────────────────────────
do
    local all = {}
    for k, v in pairs(others) do all[k] = v.text end
    for k, v in pairs(part) do all[k] = v end
    local mock = src.mock or ''
    local n = 0
    for key in mock:gmatch("new Error%('([%w_.]+)'%)") do
        n = n + 1
        H.ok(key:match('^err%.') ~= nil and all[key] ~= nil, 'mock error key exists in a locale part: ' .. key)
    end
    H.ok(n >= 15, 'mocks answer the documented error keys (' .. n .. ')')
    for key in mock:gmatch("[^%w_]L%('([%w_.]+)'") do
        H.ok(all[key] ~= nil, 'mock text key exists in a locale part: ' .. key)
    end
    for _, reason in ipairs({ 'quit', 'completed' }) do
        H.ok(all['run.ended_' .. reason] ~= nil, 'run.ended_' .. reason .. ' exists (mock result toast)')
    end
    for _, mod in ipairs({ 'armored_hostiles', 'time_crunch', 'radio_silence' }) do
        H.ok(all['modifier.' .. mod] ~= nil, 'modifier label exists: ' .. mod)
    end
end

-- ── contract names ──────────────────────────────────────────────────────────
local board, active = src.board or '', src.active or ''
local function has(text, needle, msg) return H.ok(text:find(needle, 1, true) ~= nil, msg or needle) end
local function hasnt(text, needle, msg) return H.ok(text:find(needle, 1, true) == nil, msg or ('not ' .. needle)) end

has(board, "useRequest<MissionBoardData>('getMissionTypes'", 'board requests getMissionTypes')
has(board, "pushTopic: 'board'", 'board refetches on push board')
has(board, "usePush('operation'", 'board refetches on push operation')
has(board, "'server:acceptType'", 'board accepts with server:acceptType')
has(board, "const BOSS_KEY = 'weekly_boss'", 'boss card accepts with weekly_boss')
has(board, "'server:joinOperation', op.id", 'join sends the operation id')
has(board, "navigate('active')", 'accept navigates to the Active Mission screen')
has(board, 'ConfirmDialog', 'accept asks for confirmation')
has(board, 'export default function MissionBoard() {', 'MissionBoard default export without props')
hasnt(board, 'getMissionDefs', 'board never loads mission definitions')
hasnt(board, 'getMissionList', 'board never lists missions')

has(active, "useRequest<ActiveMissionData | null>('getRun'", 'active requests getRun')
has(active, "pushTopic: 'run'", 'active refetches on push run')
has(active, "'server:abandon', view.runId", 'abandon sends the run id')
has(active, "clientAction<SetGpsResult>('setGps'", 'Set GPS client action')
has(active, "clientAction<RecalcRouteResult>('recalcRoute'", 'Recalculate route client action')
has(active, "clientAction('logResult', payload)", 'Business Check log client action')
has(active, 'LogResultPayload = { point: view.log.point, choice }', 'logResult payload is { point, choice }')
has(active, "tone=\"danger\"", 'abandon confirm dialog is a danger dialog')
has(active, 'disabled={!routeOn || left <= 0}', 'recalculate is disabled with no recalculations left')
has(active, 'export default function ActiveMission() {', 'ActiveMission default export without props')

local mock = src.mock or ''
for _, name in ipairs({ "'request', 'getMissionTypes'", "'request', 'getRun'", "'action', 'server:acceptType'",
    "'action', 'server:joinOperation'", "'action', 'server:abandon'", "'client', 'setGps'", "'client', 'recalcRoute'", "'client', 'logResult'" }) do
    has(mock, 'registerMock(' .. name, 'mock registered: ' .. name)
end
hasnt(mock, 'fallback: true', 'the getRun mock overrides core.mock.ts (not a fallback)')

-- ── CSS rules ───────────────────────────────────────────────────────────────
for _, name in ipairs({ 'boardCss', 'activeCss' }) do
    local css = (src[name] or ''):gsub('/%*.-%*/', '')
    H.ok(not css:find('#%x%x%x'), name .. ': no hex colours (only --cp-* variables)')
    H.ok(not css:find('color%-mix'), name .. ': no color-mix()')
    H.ok(not css:find(':has%('), name .. ': no :has()')
    for var in css:gmatch('var%((%-%-[%w-]+)') do
        H.ok(var:match('^%-%-cp%-') ~= nil, name .. ': only --cp-* variables (' .. var .. ')')
    end
    -- every rule's selector list names a run_ui- class (keyframes excluded)
    for selectors in css:gmatch('([^{}]+){') do
        local sel = selectors:gsub('^%s+', ''):gsub('%s+$', '')
        if not sel:match('^@') and not sel:match('^%d+%%') and not sel:match('^[%d%%,%s]+$') then
            for one in sel:gmatch('[^,]+') do
                H.ok(one:find('%.run_ui%-') ~= nil, name .. ': selector scoped by run_ui-: ' .. one:gsub('^%s+', ''))
            end
        end
    end
end

-- ── no SQL in the slice ─────────────────────────────────────────────────────
for name, text in pairs(src) do
    H.ok(not text:find('MySQL', 1, true), name .. ': no MySQL usage (UI-only slice, nothing to run on MariaDB)')
end

return H
