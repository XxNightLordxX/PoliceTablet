-- run_ui slice (Officer Mission Board + Active Mission screens, UI only).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local cjson = require('cjson')

local ROOT = H.root                                   -- .../Crimson-Police/
local WEB = ROOT .. 'web/src/'

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Decode(path)
    local s = Read(path)
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
    src[k] = Read(path)
    H.ok(src[k] ~= nil and #src[k] > 0, 'slice file exists: ' .. path)
end

-- ============================================================================
--                                 LOCALE PART
-- ============================================================================

local part, perr = Decode(FILES.part)
H.ok(type(part) == 'table', 'run_ui.json parses (' .. tostring(perr) .. ')')
part = part or {}

local ui = Decode(ROOT .. 'locales/parts/ui.json') or {}
local others = {}                                     -- key -> { text, file } from every other part
do
    local p = io.popen('ls ' .. ROOT .. 'locales/parts/*.json')
    for file in p:lines() do
        if not file:find('run_ui.json', 1, true) then
            local data = Decode(file)
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
    H.ok(type(k) == 'string' and (k:match('^board%.[%w_.]+$') or k:match('^run%.[%w_.]+$')) ~= nil,
        'key in the board./run. namespace: ' .. tostring(k))
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
    H.eq(CP.L('board.card.tod_points', { multiplier = 2 }), '2× today',
        'Type of the Day multiplier comes from data (Config.Events.todMultiplier)')
    H.ok(CP.Locale.has('run.empty.title'), 'CP.Locale.has run.empty.title')
    H.ok(CP.L('board.confirm.abandon', { type = 'Patrol' }):find('drawn at random', 1, true) ~= nil,
        'accept confirm says the mission is drawn at random')
    H.ok(CP.L('board.confirm.abandon', { type = 'Patrol' }):find('whole Patrol type on cooldown', 1, true) ~= nil,
        'accept confirm names the type cooldown')
end

-- ============================================================================
--                           KEYS USED BY THE SCREENS
-- ============================================================================

local function LiteralKeys(text)
    local keys = {}
    for key in text:gmatch('[^%w_]t%(\'([%w_.]+)\'') do keys[key] = true end
    for key in text:gmatch('tOr%(\'([%w_.]+)\'') do keys[key] = true end
    for key in text:gmatch('tOr%([^,]+, \'([%w_.]+)\'') do keys[key] = true end
    for key in text:gmatch('success: \'([%w_.]+)\'') do keys[key] = true end
    return keys
end

local used = {}
for _, name in ipairs({ 'board', 'active' }) do
    for key in pairs(LiteralKeys(src[name] or '')) do
        used[key] = true
        H.ok(part[key] ~= nil or ui[key] ~= nil,
            ('screen key exists in run_ui.json or ui.json: %s (%s)'):format(key, name))
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

-- ============================================================================
--               KEYS THE BROWSER MOCKS ANSWER WITH OR TRANSLATE
-- ============================================================================

do
    local all = {}
    for k, v in pairs(others) do all[k] = v.text end
    for k, v in pairs(part) do all[k] = v end
    local mock = src.mock or ''
    local n = 0
    for key in mock:gmatch('new Error%(\'([%w_.]+)\'%)') do
        n = n + 1
        H.ok(key:match('^err%.') ~= nil and all[key] ~= nil, 'mock error key exists in a locale part: ' .. key)
    end
    H.ok(n >= 15, 'mocks answer the documented error keys (' .. n .. ')')
    for key in mock:gmatch('[^%w_]L%(\'([%w_.]+)\'') do
        H.ok(all[key] ~= nil, 'mock text key exists in a locale part: ' .. key)
    end
    for _, reason in ipairs({ 'quit', 'completed' }) do
        H.ok(all['run.ended_' .. reason] ~= nil, 'run.ended_' .. reason .. ' exists (mock result toast)')
    end
    for _, mod in ipairs({ 'armored_hostiles', 'time_crunch', 'radio_silence' }) do
        H.ok(all['modifier.' .. mod] ~= nil, 'modifier label exists: ' .. mod)
    end
end

-- ============================================================================
--                                CONTRACT NAMES
-- ============================================================================

local board, active = src.board or '', src.active or ''
-- Layout-free: whitespace and a trailing comma before a closing bracket do not count (see squash).
local function Squash(s) return (s:gsub('%s+', ''):gsub(',([%)%]}>])', '%1')) end
local function Has(text, needle, msg) return H.ok(Squash(text):find(Squash(needle), 1, true) ~= nil, msg or needle) end
local function Hasnt(text, needle, msg)
    return H.ok(Squash(text):find(Squash(needle), 1, true) == nil, msg or ('not ' .. needle))
end

Has(board, 'useRequest<MissionBoardData>(\'getMissionTypes\'', 'board requests getMissionTypes')
Has(board, 'usePush(\'board\', () => schedule())', 'board refetches (coalesced) on push board')
Has(board, 'usePush(\'operation\', () => schedule())', 'board refetches (coalesced) on push operation')
Has(board, 'if (runId !== (data?.activeRunId ?? null)) schedule();',
    'board refetches on push run only when the active run changes')
Has(board, 'res.error === \'err.rate_limited\'', 'a rate-limited board refetch is retried')
Has(board, 't(\'board.card.tod_points\', { multiplier: todX })', 'the Type of the Day multiplier is not hard-coded')
H.eq(tonumber(((Read(ROOT .. 'config/config.lua') or ''):match('todMultiplier%s*=%s*([%d.]+)'))), 2.0,
    'Config.Events.todMultiplier is the default the board falls back to (2)')
Has(board, '\'server:acceptType\'', 'board accepts with server:acceptType')
Has(board, 'const BOSS_KEY = \'weekly_boss\'', 'boss card accepts with weekly_boss')
Has(board, '\'server:joinOperation\', op.id', 'join sends the operation id')
Has(board, 'navigate(\'active\')', 'accept navigates to the Active Mission screen')
Has(board, 'ConfirmDialog', 'accept asks for confirmation')
Has(board, 'export default function MissionBoard() {', 'MissionBoard default export without props')
Hasnt(board, 'getMissionDefs', 'board never loads mission definitions')
Hasnt(board, 'getMissionList', 'board never lists missions')

Has(active, 'useRequest<ActiveMissionData | null>(\'getRun\'', 'active requests getRun')
Hasnt(active, 'pushTopic: \'run\'', 'active applies pushed views (no extra getRun per push)')
Has(active, 'usePush<ActiveMissionData | null | undefined>(\'run\'', 'active listens to push run')
Has(active,
    'if (view && typeof view === \'object\' && typeof view.runId === \'string\') setData(view);\n    else void refetch();',
    'a pushed view applies at once; a nil push (arrives as undefined) refetches')
Has(active, '\'server:abandon\', view.runId', 'abandon sends the run id')
Has(active, 'clientAction<SetGpsResult>(\'setGps\'', 'Set GPS client action')
Has(active, 'clientAction<RecalcRouteResult>(\'recalcRoute\'', 'Recalculate route client action')
Has(active, 'clientAction(\'logResult\', payload)', 'Business Check log client action')
Has(active, 'LogResultPayload = { point: view.log.point, choice }', 'logResult payload is { point, choice }')
Has(active, 'tone="danger"', 'abandon confirm dialog is a danger dialog')
Has(active, 'disabled={!routeOn || left <= 0}', 'recalculate is disabled with no recalculations left')
Has(active, 'export default function ActiveMission() {', 'ActiveMission default export without props')

local mock = src.mock or ''
for _, name in ipairs({
    '\'request\', \'getMissionTypes\'',
    '\'request\', \'getRun\'',
    '\'action\', \'server:acceptType\'',
    '\'action\', \'server:joinOperation\'',
    '\'action\', \'server:abandon\'',
    '\'client\', \'setGps\'',
    '\'client\', \'recalcRoute\'',
    '\'client\', \'logResult\'',
}) do
    Has(mock, 'registerMock(' .. name, 'mock registered: ' .. name)
end
Hasnt(mock, 'fallback: true', 'the getRun mock overrides core.mock.ts (not a fallback)')

-- ============================================================================
--                                 THE LUA SIDE
-- ============================================================================
-- Every field the screens read is produced by the real modules.
-- Static checks of the producers (modules/runs, draw, events, operations, route, blocks/interact_points)
-- against the contract shapes in web/src/shared/types.ts (ARCHITECTURE §9.4), so a renamed field on
-- either side fails here instead of rendering blank in game.
local function StripComments(text)
    text = text:gsub('%-%-%[%[.-%]%]', '')
    return (text:gsub('%-%-[^\n]*', ''))
end

-- Text of a top-level function from its header to the next top-level definition.
local function FnBody(text, header)
    local a = text:find(header, 1, true)
    if not a then return nil end
    local rest = text:sub(a + #header)
    local b = rest:find('\n[%w_.]*%s*function ') or rest:find('\nlocal function ') or rest:find('\nCP%.Net%.')
    for _, pat in ipairs({ '\nfunction ', '\nlocal function ', '\nCP%.Net%.', '\nRegisterNetEvent' }) do
        local i = rest:find(pat)
        if i and (not b or i < b) then b = i end
    end
    return b and rest:sub(1, b) or rest
end

-- The balanced {...} that starts at the first match of `opener` (e.g. 'return {', 'local card = {').
local function TableAt(text, opener)
    if not text then return nil end
    local a, e = text:find(opener, 1, true)
    if not a then return nil end
    local depth, i = 0, e
    while i <= #text do
        local c = text:sub(i, i)
        if c == '{' then
            depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then return text:sub(e, i) end
        end
        i = i + 1
    end
    return nil
end

-- Top-level keys of a Lua table constructor text ('{ a = 1, b = { c = 2 } }' -> { a, b }).
local function LuaKeys(tbl)
    local keys, depth, i = {}, 0, 1
    tbl = tbl or ''
    while i <= #tbl do
        local c = tbl:sub(i, i)
        if c == '{' or c == '(' then
            depth = depth + 1
            i = i + 1
        elseif c == '}' or c == ')' then
            depth = depth - 1
            i = i + 1
        elseif c == '\'' or c == '"' then
            local j = tbl:find(c, i + 1, true)
            i = (j or #tbl) + 1
        elseif depth == 1 and c:match('[%a_]') then
            local name, after = tbl:match('^([%a_][%w_]*)%s*()', i)
            if tbl:sub(after, after) == '=' and tbl:sub(after + 1, after + 1) ~= '=' then keys[name] = true end
            i = i + #name
        elseif depth == 1 and tbl:sub(i, i + 1) == '[\'' then
            local name = tbl:match('^%[\'([%w_]+)\'%]%s*=', i)
            if name then keys[name] = true end
            i = i + 2
        else
            i = i + 1
        end
    end
    return keys
end

-- Top-level field names of a TypeScript interface in web/src/shared/types.ts.
local typesTs = Read(WEB .. 'shared/types.ts') or ''
local function TsFields(name)
    local body = TableAt(typesTs, 'export interface ' .. name .. ' {')
    local out, depth, i = {}, 0, 1
    body = body or ''
    while i <= #body do
        local c = body:sub(i, i)
        if c == '{' or c == '(' or c == '[' then
            depth = depth + 1
            i = i + 1
        elseif c == '}' or c == ')' or c == ']' then
            depth = depth - 1
            i = i + 1
        elseif c == '\'' then
            local j = body:find('\'', i + 1, true)
            i = (j or #body) + 1
        elseif depth == 1 and c:match('[%a_]') then
            local field, after = body:match('^([%a_][%w_]*)%??%s*()', i)
            if body:sub(after, after) == ':' then out[#out + 1] = field end
            i = i + #field
        else
            i = i + 1
        end
    end
    return out
end

local function Mod(rel) return StripComments(Read(ROOT .. rel) or '') end
local runsSrv, drawSrv, eventsSrv =
    Mod('modules/runs/server.lua'), Mod('modules/draw/server.lua'), Mod('modules/events/server.lua')
local opsSrv, routeSrv, routeCl =
    Mod('modules/operations/server.lua'), Mod('modules/route/server.lua'), Mod('modules/route/client.lua')
local runsCl, ipSrv = Mod('modules/runs/client.lua'), Mod('blocks/interact_points/server.lua')

local function Covers(keys, fields, what)
    H.ok(#fields > 0, what .. ': contract fields parsed')
    for _, f in ipairs(fields) do H.ok(keys[f] == true, ('%s produces %s'):format(what, f)) end
end

-- getRun / push 'run': CP.Runs.view returns every ActiveMissionView field plus the extras the screen reads.
local viewKeys = LuaKeys(TableAt(FnBody(runsSrv, 'function Runs.view(run, src)'), 'return {'))
Covers(viewKeys, TsFields('ActiveMissionView'), 'CP.Runs.view')
for _, extra in ipairs({ 'me', 'isBoss', 'operationId', 'startIn' }) do
    H.ok(viewKeys[extra] == true, 'CP.Runs.view sends the optional extra ' .. extra)
end
local extrasTs = Read(FILES.types) or ''
for _, extra in ipairs({ 'me', 'isBoss', 'operationId', 'startIn', 'area' }) do
    H.ok(extrasTs:find('\n%s+' .. extra .. '%?:') ~= nil, 'ActiveMissionData extra is optional: ' .. extra)
end
local partnerKeys = LuaKeys(TableAt(FnBody(runsSrv, 'local function ParticipantsList(run)'), 'out[#out + 1] = {'))
for _, f in ipairs({ 'src', 'name', 'callsign', 'departmentShort', 'status', 'arrived' }) do
    H.ok(partnerKeys[f] == true, 'view.partners[] carries ' .. f)
end
local hudKeys = LuaKeys(
    TableAt(FnBody(runsSrv, 'local function HudObjectives(run, includePending)'), 'local entry = {'))
for _, f in ipairs({ 'label', 'done', 'current' }) do H.ok(hudKeys[f] == true, 'view.objectives[] carries ' .. f) end
local hudBody = FnBody(runsSrv, 'local function HudObjectives(run, includePending)') or ''
for _, f in ipairs({ 'value', 'max', 'detail' }) do
    H.ok(hudBody:find('entry.' .. f .. ' =', 1, true) ~= nil, 'view.objectives[] may carry ' .. f)
end
local expectedBody = FnBody(runsSrv, 'local function ExpectedFor(run)') or ''
H.ok(expectedBody:find('return { cash = cash, points = ', 1, true) ~= nil, 'view.expected = { cash, points }')
local modBody = FnBody(runsSrv, 'local function ModifierView(run)') or ''
H.ok(modBody:find('return { key = run.modifier, label = ', 1, true) ~= nil, 'view.modifier = { key, label }')
H.ok(runsSrv:find('Call(\'Tablet\', \'push\', src, \'run\', nil)', 1, true) ~= nil,
    'push \'run\' carries nil when the run ended (handled as undefined)')
H.ok(runsSrv:find('CP.Net.callback(\'getRun\'', 1, true) ~= nil, 'callback getRun is registered by modules/runs')
H.ok(runsSrv:find('CP.Net.action(\'server:abandon\'', 1, true) ~= nil,
    'action server:abandon is registered by modules/runs')
local abandonBody = FnBody(runsSrv, 'CP.Net.action(\'server:abandon\', function(src, payload)') or ''
H.ok(abandonBody:find('local runId = payload', 1, true) ~= nil, 'server:abandon takes the runId as its payload')

-- view.route = CP.Route.status: only the four statuses the screen knows, with secondsLeft/distance.
local statusBody = FnBody(routeSrv, 'function R.status(run, src)') or ''
local statuses = {}
for st in statusBody:gmatch('status = \'([%w_]+)\'') do statuses[st] = true end
for st in statusBody:gmatch('and \'([%w_]+)\' or \'([%w_]+)\'') do statuses[st] = true end
for a, b in statusBody:gmatch('\'([%w_]+)\' or \'([%w_]+)\'') do statuses[a] = true; statuses[b] = true end
local known = { on = true, off = true, arrived = true, disabled = true }
local nStatus = 0
for st in pairs(statuses) do
    nStatus = nStatus + 1
    H.ok(known[st] == true, 'CP.Route.status returns a status the screen handles: ' .. st)
end
H.ok(nStatus >= 4, 'every route status found (' .. nStatus .. ')')
for _, f in ipairs({ 'secondsLeft', 'recalcsLeft', 'distance' }) do
    H.ok(statusBody:find(f .. ' =', 1, true) ~= nil, 'CP.Route.status sends ' .. f)
end
local routeForBody = FnBody(runsSrv, 'local function RouteFor(run, src, p)') or ''
for _, f in ipairs({ 'route.secondsLeft', 'route.distance', 'st.recalcsLeft' }) do
    H.ok(routeForBody:find(f, 1, true) ~= nil, 'CP.Runs.view copies ' .. f)
end

-- Client actions the screen calls.
H.ok(routeCl:find('registerClientAction(\'setGps\'', 1, true) ~= nil,
    'client action setGps registered by modules/route')
H.ok(routeCl:find('registerClientAction(\'recalcRoute\'', 1, true) ~= nil,
    'client action recalcRoute registered by modules/route')
H.ok((FnBody(routeCl, 'function R.recalculate()') or ''):find('return true, { recalcsLeft = left }', 1, true) ~= nil,
    'recalcRoute replies { recalcsLeft }')
H.ok(runsCl:find('registerClientAction(\'logResult\', function(payload)', 1, true) ~= nil,
    'client action logResult registered by modules/runs')
H.ok(runsCl:find('payload.point', 1, true) ~= nil and runsCl:find('payload.choice', 1, true) ~= nil,
    'logResult reads { point, choice }')
-- view.log comes from the interact_points block state: { point, choices = { { id, label } } }.
H.ok(ipSrv:find('st.log = { point = n, choices = choices }', 1, true) ~= nil,
    'interact_points state.log = { point, choices }')
H.ok(ipSrv:find('choices[i] = { id = c.id, label = ChoiceLabel(c) }', 1, true) ~= nil,
    'log choices are { id, label } (label translated)')
H.ok(runsSrv:find('logView = { point = lg.point, choices = lg.choices }', 1, true) ~= nil,
    'CP.Runs.view forwards state.log as view.log')

-- getMissionTypes: CP.Draw.boardCards (cards + board), CP.Events.bossCard, CP.Operations.boardCard.
local boardBody = FnBody(drawSrv, 'function Draw.boardCards(src)')
local cardFields = TsFields('BoardCard')
Covers(LuaKeys(TableAt(boardBody, 'local card = {')), cardFields, 'CP.Draw.boardCards card')
Covers(LuaKeys(TableAt(boardBody, 'local data = {')), TsFields('BoardData'), 'CP.Draw.boardCards BoardData')
H.ok((boardBody or ''):find('unit = { size = size, isLeader = IsLeader(src) }', 1, true) ~= nil,
    'BoardData.unit = { size, isLeader }')
H.ok((boardBody or ''):find('[\'until\'] = cdUntil', 1, true) ~= nil,
    'locked.until is the cooldown end (os.time stamp)')
H.ok((boardBody or ''):find('reason = CP.L(', 1, true) ~= nil, 'locked.reason arrives translated (CP.L)')
local bossKeys = LuaKeys(TableAt(FnBody(eventsSrv, 'function Events.bossCard(src)'), 'local card = {'))
Covers(bossKeys, cardFields, 'CP.Events.bossCard')
H.ok(bossKeys.available == true, 'CP.Events.bossCard sends available')
H.ok(
    eventsSrv:find('key = BOSS_KEY', 1, true) ~= nil
        and eventsSrv:find('local BOSS_KEY = \'weekly_boss\'', 1, true) ~= nil,
    'the boss card\'s key is \'weekly_boss\' (the payload the screen accepts it with)'
)
local opKeys = LuaKeys(TableAt(FnBody(opsSrv, 'function Ops.boardCard(src)'), 'return {'))
for _, f in ipairs({
    'id',
    'missionLabel',
    'launcher',
    'status',
    'joined',
    'max',
    'joinedByMe',
    'canJoin',
    'joinEndsIn',
}) do
    H.ok(opKeys[f] == true, 'CP.Operations.boardCard produces ' .. f)
    H.ok(typesTs:find(f .. ':', 1, true) ~= nil, 'BoardData.operation declares ' .. f)
end
for _, f in ipairs({ 'missionType', 'missionTypeLabel', 'description', 'min', 'runState' }) do
    H.ok(opKeys[f] == true, 'CP.Operations.boardCard sends the extra ' .. f)
    H.ok(extrasTs:find('%s' .. f .. '%?:') ~= nil, 'BoardOperation extra is optional: ' .. f)
end
local opStatuses = {}
for st in opsSrv:match('local ACTIVE = (%b{})'):gmatch('([%a_]+) = true') do opStatuses[st] = true end
for st in pairs(opStatuses) do
    H.ok(board:find('op.status === \'' .. st .. '\'', 1, true) ~= nil, 'the operation card handles status ' .. st)
end
H.ok(drawSrv:find('CP.Net.callback(\'getMissionTypes\'', 1, true) ~= nil,
    'callback getMissionTypes is registered by modules/draw')
H.ok(drawSrv:find('CP.Net.action(\'server:acceptType\'', 1, true) ~= nil,
    'action server:acceptType is registered by modules/draw')
H.ok(opsSrv:find('\'server:joinOperation\'', 1, true) ~= nil,
    'action server:joinOperation is registered by modules/operations')

-- Pushes the board listens to are the ones the modules send.
local unitsSrv = Mod('modules/units/server.lua')
H.ok(unitsSrv:find('Push(m, \'board\'', 1, true) ~= nil, 'modules/units pushes \'board\' when the unit changes')
H.ok(opsSrv:find('Push(p, \'board\', data)', 1, true) ~= nil, 'modules/operations pushes \'board\'')

-- ============================================================================
--                                  CSS RULES
-- ============================================================================

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

-- ============================================================================
--                             NO SQL IN THE SLICE
-- ============================================================================

for name, text in pairs(src) do
    H.ok(not text:find('MySQL', 1, true), name .. ': no MySQL usage (UI-only slice, nothing to run on MariaDB)')
end

return H
