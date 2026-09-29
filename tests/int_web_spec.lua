-- tests/int_web_spec.lua · integration checks for the web group (web/src outside the Mission Builder).
--
-- Static cross-checks between the screens and the Lua that feeds them, for what the integration pass
-- changed or relies on:
--   * Mission Board: BoardData.operation.joinBlocked (CP.Operations.boardCard) is typed, read by the
--     screen, and every key the Lua can send has a text in some locale part;
--   * Unit screen: test invitations (SPEC Admin test mode, "accept on their own screen") use the names
--     modules/testing registers (callback test:pendingInvites, action server:testRespond { inviteId,
--     accepted }, push 'invites') and the TestInvite fields the Lua returns; every literal key exists;
--   * a nil push ('run' with no data) arrives as a missing field: the RunBar, Home, Mission Board and
--     Active Mission treat undefined like null;
--   * Home styles both announcement kinds modules/leaderboard sends (weekly_top3, monthly_top3);
--   * lists from Lua ({} for an empty table): the touched screens wrap them (asArray / asList);
--   * theme: primary/accent text colours reach WCAG AA (4.5:1) on the surface, checked with a Lua port of
--     web/src/shared/theme.ts on the configured department themes (FIB's navy primary was 3.2:1).
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local cjson = require('cjson')

local ROOT = H.root
local WEB = ROOT .. 'web/src/'

local function read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function has(text, needle, msg)
    H.ok(text ~= nil and text:find(needle, 1, true) ~= nil, msg or ('contains ' .. needle))
end

-- Every locale key of every part (the merged en.json is built from these).
local keys = {}
do
    local p = io.popen('ls ' .. ROOT .. 'locales/parts/*.json')
    for file in p:lines() do
        local ok, data = pcall(cjson.decode, read(file) or '')
        if ok and type(data) == 'table' then for k in pairs(data) do keys[k] = true end end
    end
    p:close()
end

local function literalKeys(text)
    local out = {}
    for key in text:gmatch("[^%w_]t%('([%w_.]+)'") do out[key] = true end
    for a, b in text:gmatch("success: accepted %? '([%w_.]+)' : '([%w_.]+)'") do out[a] = true; out[b] = true end
    for key in text:gmatch("success: '([%w_.]+)'") do out[key] = true end
    return out
end

-- ── Mission Board: joinBlocked ───────────────────────────────────────────────
local ops = read(ROOT .. 'modules/operations/server.lua')
local board = read(WEB .. 'officer/screens/MissionBoard.tsx')
local runTypes = read(WEB .. 'types/run_ui.ts')
H.ok(ops ~= nil and board ~= nil and runTypes ~= nil, 'operations server, Mission Board and run_ui types exist')
has(ops, 'joinBlocked = joinBlocked', 'CP.Operations.boardCard sends joinBlocked')
has(runTypes, 'joinBlocked?: string | null', 'BoardOperation types joinBlocked (optional)')
has(board, 'op.joinBlocked', 'the Mission Board reads op.joinBlocked')
has(board, 'hasKey(op.joinBlocked)', 'an unknown joinBlocked key falls back to the generic text')
do
    local body = ops:match('local joinBlocked = nil(.-)return {')
    H.ok(body ~= nil, 'boardCard computes joinBlocked')
    local n = 0
    for key in (body or ''):gmatch("joinBlocked = '([%w_.]+)'") do
        n = n + 1
        H.ok(keys[key] == true, 'joinBlocked key has a locale text: ' .. key)
    end
    H.ok(n >= 6, 'boardCard names every join refusal (' .. n .. ' keys)')
end
has(board, "'board.op.cannot_join'", 'generic hint kept when joinBlocked is missing')

-- ── Unit screen: test invitations ─────────────────────────────────────────────
local unit = read(WEB .. 'officer/screens/Unit.tsx')
local testing = read(ROOT .. 'modules/testing/server.lua')
local testTypes = read(WEB .. 'types/testing.ts')
H.ok(unit ~= nil and testing ~= nil and testTypes ~= nil, 'Unit screen, testing server and testing types exist')
has(unit, "useRequest<TestInvite[]>('test:pendingInvites', {}, { pushTopic: 'invites' })", 'Unit lists test:pendingInvites, live on push invites')
has(unit, "run('server:testRespond', { inviteId: inv.inviteId, accepted }", 'Unit answers with server:testRespond { inviteId, accepted }')
has(unit, 'asList(data)', 'the invitation list tolerates {} from Lua')
has(testing, "CP.Net.callback('test:pendingInvites'", 'modules/testing registers test:pendingInvites')
has(testing, "CP.Net.action('server:testRespond'", 'modules/testing registers server:testRespond')
has(testing, "push(target, 'invites', { test = true })", "modules/testing pushes 'invites' to the invitee")
do
    local shape = testing:match('function Testing%.pendingInvites.-out%[#out %+ 1%] = {(.-)}')
    H.ok(shape ~= nil, 'pendingInvites builds its entries')
    local tsShape = testTypes:match('export interface TestInvite {(.-)}')
    H.ok(tsShape ~= nil, 'TestInvite interface exists')
    for field in (tsShape or ''):gmatch('([%w_]+)%??:') do
        H.ok((shape or ''):find(field .. ' =', 1, true) ~= nil, 'pendingInvites sends TestInvite.' .. field)
    end
    for _, field in ipairs({ 'inviteId', 'missionLabel', 'from', 'fromCallsign', 'expiresIn' }) do
        has(unit, 'inv.' .. field, 'Unit shows/uses inv.' .. field)
    end
    local respond = testing:match('function Testing%.respond(.-)\nend')
    H.ok(respond ~= nil and respond:find('inviteId', 1, true) ~= nil and respond:find('accepted', 1, true) ~= nil,
        'Testing.respond reads payload.inviteId and payload.accepted')
end
for key in pairs(literalKeys(unit)) do
    H.ok(keys[key] == true, 'Unit screen key exists in a locale part: ' .. key)
end

-- ── nil pushes arrive as a missing field ──────────────────────────────────────
local runbar = read(WEB .. 'layouts/RunBar.tsx')
has(runbar, 'if (view === null || view === undefined) setData(null);', 'RunBar clears on a run push without data')
local home = read(WEB .. 'officer/screens/Home.tsx')
has(home, 'if (view === null || view === undefined) void refetch();', 'Home refetches on the run-ended push')
local active = read(WEB .. 'officer/screens/ActiveMission.tsx')
has(active, "usePush<ActiveMissionData | null | undefined>('run'", 'Active Mission accepts an undefined run push')
has(board, "usePush<{ runId?: unknown } | null | undefined>('run'", 'Mission Board accepts an undefined run push')

-- ── Home announcements ────────────────────────────────────────────────────────
local lb = read(ROOT .. 'modules/leaderboard/server.lua')
for _, kind in ipairs({ 'weekly_top3', 'monthly_top3' }) do
    has(lb, "kind = '" .. kind .. "'", 'modules/leaderboard sends ' .. kind)
    H.ok(home:find('\n  ' .. kind .. ': ', 1, true) ~= nil, 'Home has an icon for ' .. kind)
end
has(home, 'asArray(list)', 'Home announcements tolerate {} from Lua')

-- ── theme contrast (Lua port of web/src/shared/theme.ts) ─────────────────────
local themeTs = read(WEB .. 'shared/theme.ts')
has(themeTs, "'--cp-primary-text': legibleOn(th.primary, th.surface, 4.5)", 'primary text targets 4.5:1')
has(themeTs, "'--cp-accent-text': legibleOn(th.accent, th.surface, 4.5)", 'accent text targets 4.5:1')
do
    local function rgb(hex)
        local n = tonumber(hex:sub(2), 16)
        return { (n >> 16) & 255, (n >> 8) & 255, n & 255 }
    end
    local function tohex(c)
        local function b(x) return math.max(0, math.min(255, math.floor(x + 0.5))) end
        return ('#%02x%02x%02x'):format(b(c[1]), b(c[2]), b(c[3]))
    end
    local function mix(a, b, t)
        local x, y = rgb(a), rgb(b)
        return tohex({ x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t, x[3] + (y[3] - x[3]) * t })
    end
    local function lum(hex)
        local c = rgb(hex)
        for i = 1, 3 do
            local s = c[i] / 255
            c[i] = s <= 0.03928 and s / 12.92 or ((s + 0.055) / 1.055) ^ 2.4
        end
        return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
    end
    local function ratio(a, b)
        local la, lb2 = lum(a), lum(b)
        return (math.max(la, lb2) + 0.05) / (math.min(la, lb2) + 0.05)
    end
    local function legibleOn(fg, bg, min)
        if ratio(fg, bg) >= min then return fg end
        local target = lum(bg) < 0.4 and '#ffffff' or '#000000'
        for i = 1, 10 do
            local c = mix(fg, target, i * 0.1)
            if ratio(c, bg) >= min then return c end
        end
        return target
    end
    H.load('config/config.lua')
    local themes = { admin = Config.AdminTheme }
    for key, d in pairs(Config.Departments or {}) do themes[key] = d.theme end
    local n = 0
    for key, th in pairs(themes) do
        if type(th) == 'table' and th.primary and th.surface then
            n = n + 1
            H.ok(ratio(legibleOn(th.primary, th.surface, 4.5), th.surface) >= 4.5, key .. ': primary text is AA on the surface')
            H.ok(ratio(legibleOn(th.accent, th.surface, 4.5), th.surface) >= 4.5, key .. ': accent text is AA on the surface')
        end
    end
    H.ok(n >= 3, 'checked the admin theme and every configured department (' .. n .. ')')
    H.ok(ratio(Config.Departments.fib.theme.primary, Config.Departments.fib.theme.surface) < 3.2,
        'FIB primary on its surface needs the lightened text colour (the case this guards)')
end

-- ── Review Queue / Mission List layout guards (visual fixes of this pass) ─────
local rq = read(WEB .. 'supervisor/screens/ReviewQueue.tsx')
has(rq, "key: 'flag', header: t('sup.review.col.flag'), width: 176", 'Review Queue flag column fits "Impossible speed"')
local ml = read(WEB .. 'supervisor/screens/MissionList.tsx')
local mlCss = read(WEB .. 'supervisor/screens/MissionList.css')
has(ml, 'oversight-mission__label', 'Mission List clamps long mission labels')
has(mlCss, '-webkit-line-clamp: 2', 'Mission List label clamp is two lines')

return H
