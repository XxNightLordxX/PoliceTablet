-- Integration checks for the web group (web/src outside the Mission Builder).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local cjson = require('cjson')

local ROOT = H.root
local WEB = ROOT .. 'web/src/'

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- Layout-free: whitespace and a trailing comma before a closing bracket do not count, so a formatter
-- that wraps a call or re-indents a file does not change what these source checks see.
local function Squash(s)
    return (s:gsub('%s+', ''):gsub(',([%)%]}>])', '%1'))
end

local function Has(text, needle, msg)
    H.ok(text ~= nil and Squash(text):find(Squash(needle), 1, true) ~= nil, msg or ('contains ' .. needle))
end

-- Every locale key of every part (the merged en.json is built from these).
local keys = {}
do
    local p = io.popen('ls ' .. ROOT .. 'locales/parts/*.json')
    for file in p:lines() do
        local ok, data = pcall(cjson.decode, Read(file) or '')
        if ok and type(data) == 'table' then for k in pairs(data) do keys[k] = true end end
    end
    p:close()
end

local function LiteralKeys(text)
    local out = {}
    for key in text:gmatch('[^%w_]t%(\'([%w_.]+)\'') do out[key] = true end
    for a, b in text:gmatch('success: accepted %? \'([%w_.]+)\' : \'([%w_.]+)\'') do out[a] = true; out[b] = true end
    for key in text:gmatch('success: \'([%w_.]+)\'') do out[key] = true end
    return out
end

-- ============================================================================
--                          MISSION BOARD: joinBlocked
-- ============================================================================

local ops = Read(ROOT .. 'modules/operations/server.lua')
local board = Read(WEB .. 'officer/screens/MissionBoard.tsx')
local runTypes = Read(WEB .. 'types/run_ui.ts')
H.ok(ops ~= nil and board ~= nil and runTypes ~= nil, 'operations server, Mission Board and run_ui types exist')
Has(ops, 'joinBlocked = joinBlocked', 'CP.Operations.boardCard sends joinBlocked')
Has(runTypes, 'joinBlocked?: string | null', 'BoardOperation types joinBlocked (optional)')
Has(board, 'op.joinBlocked', 'the Mission Board reads op.joinBlocked')
Has(board, 'hasKey(op.joinBlocked)', 'an unknown joinBlocked key falls back to the generic text')
do
    local body = ops:match('local joinBlocked = nil(.-)return {')
    H.ok(body ~= nil, 'boardCard computes joinBlocked')
    local n = 0
    for key in (body or ''):gmatch('joinBlocked = \'([%w_.]+)\'') do
        n = n + 1
        H.ok(keys[key] == true, 'joinBlocked key has a locale text: ' .. key)
    end
    H.ok(n >= 6, 'boardCard names every join refusal (' .. n .. ' keys)')
end
Has(board, '\'board.op.cannot_join\'', 'generic hint kept when joinBlocked is missing')

-- ============================================================================
--                        UNIT SCREEN: test invitations
-- ============================================================================

local unit = Read(WEB .. 'officer/screens/Unit.tsx')
local testing = Read(ROOT .. 'modules/testing/server.lua')
local testTypes = Read(WEB .. 'types/testing.ts')
H.ok(unit ~= nil and testing ~= nil and testTypes ~= nil, 'Unit screen, testing server and testing types exist')
Has(unit, 'useRequest<TestInvite[]>(\'test:pendingInvites\', {}, { pushTopic: \'invites\' })',
    'Unit lists test:pendingInvites, live on push invites')
Has(unit, 'run(\'server:testRespond\', { inviteId: inv.inviteId, accepted }',
    'Unit answers with server:testRespond { inviteId, accepted }')
Has(unit, 'asList(data)', 'the invitation list tolerates {} from Lua')
Has(testing, 'CP.Net.callback(\'test:pendingInvites\'', 'modules/testing registers test:pendingInvites')
Has(testing, 'CP.Net.action(\'server:testRespond\'', 'modules/testing registers server:testRespond')
Has(testing, 'Push(target, \'invites\', { test = true })', 'modules/testing pushes \'invites\' to the invitee')
do
    local shape = testing:match('function Testing%.pendingInvites.-out%[#out %+ 1%] = {(.-)}')
    H.ok(shape ~= nil, 'pendingInvites builds its entries')
    local tsShape = testTypes:match('export interface TestInvite {(.-)}')
    H.ok(tsShape ~= nil, 'TestInvite interface exists')
    for field in (tsShape or ''):gmatch('([%w_]+)%??:') do
        H.ok((shape or ''):find(field .. ' =', 1, true) ~= nil, 'pendingInvites sends TestInvite.' .. field)
    end
    for _, field in ipairs({ 'inviteId', 'missionLabel', 'from', 'fromCallsign', 'expiresIn' }) do
        Has(unit, 'inv.' .. field, 'Unit shows/uses inv.' .. field)
    end
    local respond = testing:match('function Testing%.respond(.-)\nend')
    H.ok(respond ~= nil and respond:find('inviteId', 1, true) ~= nil and respond:find('accepted', 1, true) ~= nil,
        'Testing.respond reads payload.inviteId and payload.accepted')
end
for key in pairs(LiteralKeys(unit)) do
    H.ok(keys[key] == true, 'Unit screen key exists in a locale part: ' .. key)
end

-- ============================================================================
--                     NIL PUSHES ARRIVE AS A MISSING FIELD
-- ============================================================================

local runbar = Read(WEB .. 'layouts/RunBar.tsx')
Has(runbar, 'if (view === null || view === undefined) setData(null);', 'RunBar clears on a run push without data')
local home = Read(WEB .. 'officer/screens/Home.tsx')
Has(home, 'if (view === null || view === undefined) void refetch();', 'Home refetches on the run-ended push')
local active = Read(WEB .. 'officer/screens/ActiveMission.tsx')
Has(active, 'usePush<ActiveMissionData | null | undefined>(\'run\'', 'Active Mission accepts an undefined run push')
Has(board, 'usePush<{ runId?: unknown } | null | undefined>(\'run\'', 'Mission Board accepts an undefined run push')

-- ============================================================================
--                              HOME ANNOUNCEMENTS
-- ============================================================================

local lb = Read(ROOT .. 'modules/leaderboard/server.lua')
for _, kind in ipairs({ 'weekly_top3', 'monthly_top3' }) do
    Has(lb, 'kind = \'' .. kind .. '\'', 'modules/leaderboard sends ' .. kind)
    H.ok(home:find('\n%s+' .. kind .. ': ') ~= nil, 'Home has an icon for ' .. kind)
end
Has(home, 'asArray(list)', 'Home announcements tolerate {} from Lua')

-- ============================================================================
--             THEME CONTRAST (Lua port of web/src/shared/theme.ts)
-- ============================================================================

local themeTs = Read(WEB .. 'shared/theme.ts')
Has(themeTs, '\'--cp-primary-text\': legibleOn(th.primary, th.surface, 4.5)', 'primary text targets 4.5:1')
Has(themeTs, '\'--cp-accent-text\': legibleOn(th.accent, th.surface, 4.5)', 'accent text targets 4.5:1')
do
    local function Rgb(hex)
        local n = tonumber(hex:sub(2), 16)
        return { (n >> 16) & 255, (n >> 8) & 255, n & 255 }
    end
    local function Tohex(c)
        local function b(x) return math.max(0, math.min(255, math.floor(x + 0.5))) end
        return ('#%02x%02x%02x'):format(b(c[1]), b(c[2]), b(c[3]))
    end
    local function Mix(a, b, t)
        local x, y = Rgb(a), Rgb(b)
        return Tohex({ x[1] + (y[1] - x[1]) * t, x[2] + (y[2] - x[2]) * t, x[3] + (y[3] - x[3]) * t })
    end
    local function Lum(hex)
        local c = Rgb(hex)
        for i = 1, 3 do
            local s = c[i] / 255
            c[i] = s <= 0.03928 and s / 12.92 or ((s + 0.055) / 1.055) ^ 2.4
        end
        return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3]
    end
    local function Ratio(a, b)
        local la, lb2 = Lum(a), Lum(b)
        return (math.max(la, lb2) + 0.05) / (math.min(la, lb2) + 0.05)
    end
    local function LegibleOn(fg, bg, min)
        if Ratio(fg, bg) >= min then return fg end
        local target = Lum(bg) < 0.4 and '#ffffff' or '#000000'
        for i = 1, 10 do
            local c = Mix(fg, target, i * 0.1)
            if Ratio(c, bg) >= min then return c end
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
            H.ok(Ratio(LegibleOn(th.primary, th.surface, 4.5), th.surface) >= 4.5,
                key .. ': primary text is AA on the surface')
            H.ok(Ratio(LegibleOn(th.accent, th.surface, 4.5), th.surface) >= 4.5,
                key .. ': accent text is AA on the surface')
        end
    end
    H.ok(n >= 3, 'checked the admin theme and every configured department (' .. n .. ')')
    H.ok(Ratio(Config.Departments.fib.theme.primary, Config.Departments.fib.theme.surface) < 3.2,
        'FIB primary on its surface needs the lightened text colour (the case this guards)')
end

-- ============================================================================
--                  REVIEW QUEUE / MISSION LIST LAYOUT GUARDS
-- ============================================================================
-- Visual fixes of this pass.

local rq = Read(WEB .. 'supervisor/screens/ReviewQueue.tsx')
Has(rq, 'key: \'flag\', header: t(\'sup.review.col.flag\'), width: 176',
    'Review Queue flag column fits "Impossible speed"')
local ml = Read(WEB .. 'supervisor/screens/MissionList.tsx')
local mlCss = Read(WEB .. 'supervisor/screens/MissionList.css')
Has(ml, 'oversight-mission__label', 'Mission List clamps long mission labels')
Has(mlCss, '-webkit-line-clamp: 2', 'Mission List label clamp is two lines')

-- ============================================================================
--                           ADMIN UI → Leaderboards
-- ============================================================================
-- Approve / void a flagged run (SPEC Supervisor & admin actions).

do
    local lb = Read(WEB .. 'admin/screens/Leaderboards.tsx')
    local adminSrv = Read(ROOT .. 'modules/admin/server.lua')
    H.ok(lb ~= nil and adminSrv ~= nil, 'Admin Leaderboards screen and modules/admin exist')
    Has(adminSrv, 'CP.Net.callback(\'admin:getFlagged\'', 'modules/admin registers admin:getFlagged')
    Has(adminSrv, 'CP.Net.action(\'server:admin:reviewFlagged\'', 'modules/admin registers server:admin:reviewFlagged')
    Has(lb, 'useRequest<{ flagged: FlaggedRow[] }>(\'admin:getFlagged\'', 'Admin Leaderboards loads the flagged runs')
    Has(lb, 'run(\'server:admin:reviewFlagged\', { rowId: review.row.rowId, decision: review.decision, reason }',
        'Approve / Void send server:admin:reviewFlagged { rowId, decision, reason }')
    Has(lb, 'onDecide(r, \'approve\')', 'each flagged row has Approve')
    Has(lb, 'onDecide(r, \'void\')', 'each flagged row has Void')
    local dialog = lb:match('<ConfirmDialog%s+open={!!review}(.-)/>')
    H.ok(dialog ~= nil and dialog:find('required: true', 1, true) ~= nil, 'the review dialog requires a reason')
    Has(lb, 'void flaggedReq.refetch();', 'the flagged list refreshes after a decision')
    local missing = {}
    for key in pairs(LiteralKeys(lb)) do if not keys[key] then missing[#missing + 1] = key end end
    for key in lb:gmatch('\'(sup%.review%.[%w_]+)\'') do if not keys[key] then missing[#missing + 1] = key end end
    table.sort(missing)
    H.eq(#missing, 0, 'every text key of Admin Leaderboards exists (' .. table.concat(missing, ', ') .. ')')
end

-- ============================================================================
--                 MISSION HUD OVER THE SUPERVISOR / ADMIN UIS
-- ============================================================================
-- Only the Officer UI pins the run bar.

do
    local app = Read(WEB .. 'App.tsx')
    Has(app, 'const showHud = !!hud && !(uiOpen && ui === \'officer\');', 'the HUD hides only under the Officer UI')
    local sup = Read(WEB .. 'layouts/SupervisorLayout.tsx') or ''
    local adm = Read(WEB .. 'layouts/AdminLayout.tsx') or ''
    local off = Read(WEB .. 'layouts/OfficerLayout.tsx') or ''
    H.ok(off:find('<RunBar', 1, true) ~= nil, 'the Officer UI pins the run bar')
    H.ok(sup:find('<RunBar', 1, true) == nil and adm:find('<RunBar', 1, true) == nil,
        'the Supervisor and Admin UIs have no run bar (so they rely on the HUD)')
end

-- ============================================================================
--                             ADMIN UI → Officers
-- ============================================================================
-- Disputes about flagged / voided runs are approved or rejected, never awarded.

do
    local off = Read(WEB .. 'admin/screens/Officers.tsx')
    local disputes = Read(ROOT .. 'modules/disputes/server.lua')
    H.ok(off ~= nil and disputes ~= nil, 'Admin Officers screen and modules/disputes exist')
    Has(disputes, 'CP.Net.action(\'server:admin:handleDispute\'',
        'modules/disputes registers server:admin:handleDispute')
    Has(off, 'd.status === \'open\' && d.kind === \'failed\'', 'Award / Dismiss only for failed-run disputes')
    Has(off, 'setReview({ dispute: d, decision: \'approve\' })', 'flagged/voided disputes have Approve')
    Has(off, 'setReview({ dispute: d, decision: \'reject\' })', 'flagged/voided disputes have Reject')
    Has(off, 'run(\'server:admin:handleDispute\', { disputeId: review.dispute.id, decision: review.decision, reason }',
        'Approve / Reject send server:admin:handleDispute { disputeId, decision, reason } without awardPoints')
    local review = off:match('const doReview = async(.-)};')
    H.ok(review ~= nil and review:find('awardPoints', 1, true) == nil,
        'the approve / reject call never carries award points')
    local dialog = off:match('<ConfirmDialog%s+open={!!review}(.-)/>')
    H.ok(dialog ~= nil and dialog:find('required: true', 1, true) ~= nil,
        'the approve / reject dialog requires a reason')
    local missing = {}
    for key in pairs(LiteralKeys(off)) do if not keys[key] then missing[#missing + 1] = key end end
    for key in off:gmatch('\'(sup%.review%.[%w_]+)\'') do if not keys[key] then missing[#missing + 1] = key end end
    for _, k in ipairs({
        'admin.officers.dispute_kind.flagged',
        'admin.officers.dispute_kind.voided',
        'admin.officers.review_status.open',
        'admin.officers.review_status.approved',
        'admin.officers.review_status.rejected',
    }) do
        if not keys[k] then missing[#missing + 1] = k end
    end
    table.sort(missing)
    H.eq(#missing, 0, 'every text key of Admin Officers exists (' .. table.concat(missing, ', ') .. ')')
end

-- ============================================================================
--                                SHIPPED FILES
-- ============================================================================
-- locales/en.json and web/dist are regenerated from their sources.

do
    local en = Read(ROOT .. 'locales/en.json')
    H.ok(en ~= nil, 'locales/en.json ships (shared/locale.lua loads only locales/<code>.json)')
    local ok, data = pcall(cjson.decode, en or '')
    H.ok(ok and type(data) == 'table', 'locales/en.json is valid JSON')
    if ok and type(data) == 'table' then
        local missingKeys, extra = 0, 0
        for k in pairs(keys) do if data[k] == nil then missingKeys = missingKeys + 1 end end
        for k in pairs(data) do if not keys[k] then extra = extra + 1 end end
        H.eq(missingKeys, 0, 'locales/en.json has every key of locales/parts')
        H.eq(extra, 0, 'locales/en.json has no key that is not in locales/parts')
    end
    local fx = Read(ROOT .. 'fxmanifest.lua') or ''
    Has(fx, '\'locales/*.json\'', 'fxmanifest ships locales/*.json (en.json)')
    Has(fx, '\'web/dist/**/*\'', 'fxmanifest ships web/dist')
    H.ok(Read(ROOT .. 'web/dist/build-stamp.json') ~= nil, 'web/dist carries the build stamp of npm run build')
    local p = io.popen('python3 ' .. ROOT .. '../tools/check_contracts.py 2>&1')
    local out = p and p:read('a') or ''
    if p then p:close() end
    H.ok(out:find('TOTAL problems', 1, true) ~= nil, 'tools/check_contracts.py ran')
    H.ok(out:find('## nui-build', 1, true) == nil, 'web/dist is built from the current web/src (no nui-build problem)')
    H.ok(out:find('## locale-en', 1, true) == nil, 'locales/en.json equals the merged parts (no locale-en problem)')
end

return H
