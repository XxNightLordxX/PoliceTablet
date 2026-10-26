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
--                        SUPERVISOR UI → Live Missions
-- ============================================================================
-- sup:getLiveRuns needs viewMissionList; forceRecall only hides the recall buttons.

do
    local reg = Read(WEB .. 'layouts/screens.ts') or ''
    local block = reg:match('key: \'sup_live\',(.-)}') or ''
    H.ok(block:find('titleKey', 1, true) ~= nil, 'the registry lists Live Missions')
    H.ok(block:find('visible', 1, true) == nil, 'Live Missions stays visible when forceRecall is off')
    local live = Read(WEB .. 'supervisor/screens/LiveMissions.tsx')
    Has(live, 'const canRecall = !!data?.canRecall && can(\'forceRecall\');', 'the recall buttons follow forceRecall')
end

-- ============================================================================
--                        RUN BAR AFTER A FAILED REFETCH
-- ============================================================================

do
    Has(runbar, 'if (!data || !data.runId) return null;', 'the run bar hides only without a run')
    H.ok(runbar:find('if (error', 1, true) == nil, 'a failed refetch does not hide a run bar that holds a view')
end

-- ============================================================================
--                   ADMIN UI → Seasons: one start per click
-- ============================================================================

do
    local seasons = Read(WEB .. 'admin/screens/Seasons.tsx')
    Has(seasons, 'if (busy || !name.trim()) return;', 'startSeason does nothing while a start is on its way')
    Has(seasons, 'onEnter={() => void startSeason()}', 'Enter goes through the same guard')
    local form = Read(WEB .. 'shared/components/Form.tsx')
    Has(form, 'if (e.key === \'Enter\' && !e.repeat && onEnter) onEnter();', 'a held Enter fires onEnter once')
end

-- ============================================================================
--                  HUD COUNTDOWNS AFTER THE OFFICER UI CLOSES
-- ============================================================================
-- The HUD is unmounted under the Officer UI: it counts from the time the value arrived, not from its mount.

do
    local app = Read(WEB .. 'App.tsx')
    Has(app, 'useNuiEvent(\'hud\', m => setHud(prev => (m.hud ? normalizeHud(m.hud, prev) : null)));',
        'a HUD patch keeps the arrival time of an unchanged countdown')
    local data = Read(WEB .. 'shared/data.ts')
    Has(data, 'export function secondsSince(seconds: number, receivedAt?: number): number', 'secondsSince helper')
    local hudSrc = Read(WEB .. 'hud/Hud.tsx')
    Has(hudSrc, 'secondsSince(timer.remaining, timer.receivedAt)', 'the timer counts from its arrival time')
    Has(hudSrc, 'secondsSince(route.secondsLeft, route.receivedAt)',
        'the off-route countdown counts from its arrival time')
    -- PLAN M10: the objective line under the objectives (CP.Markers' HUD patch 'target', false clears it)
    Has(hudSrc, '{hud.phase === \'objectives\' && hud.target ? <TargetLine target={hud.target} /> : null}',
        'the HUD shows where the objective is and how far while the objectives run')
    Has(hudSrc, 't(\'hud.target.distance\', { distance: formatDistance(target.distance) })', 'its distance')
    Has(data, 'target: h.target ?? null,', 'normalizeHud keeps a missing target as null')
    local tabletCl = Read(ROOT .. 'modules/tablet/client.lua')
    Has(tabletCl, 'detail = true, target = true }', 'the HUD patch target = false clears it (NULLABLE_HUD)')
end

-- ============================================================================
--                              CHECK SPAWN POINTS
-- ============================================================================
-- (PLAN S8): the dialog, its store and the Lua testing client.

do
    local tclient = Read(ROOT .. 'modules/testing/client.lua')
    local tserver = Read(ROOT .. 'modules/testing/server.lua')
    local store = Read(WEB .. 'admin/components/spawnCheckStore.ts')
    local dialog = Read(WEB .. 'admin/components/SpawnCheckDialog.tsx')
    local screen = Read(WEB .. 'admin/screens/Testing.tsx')
    local mock = Read(WEB .. 'mocks/testing.mock.ts')
    H.ok(tclient and tserver and store and dialog and screen and mock and true,
        'testing client and server, the spawn check store and dialog, the Testing screen and its mock exist')
    tclient, tserver, store, dialog, screen, mock =
        tclient or '', tserver or '', store or '', dialog or '', screen or '', mock or ''

    -- the push: one topic, heard at module level (the check runs on while the tablet is closed)
    Has(tclient, 'local SPAWN_TOPIC = \'spawnCheck\'', 'the Lua client pushes topic spawnCheck')
    Has(tclient, 'CP.Tablet.push(SPAWN_TOPIC, data)', 'through CP.Tablet.push')
    Has(store, 'window.addEventListener(\'message\',', 'the store listens at module level')
    Has(store, 'd.type !== \'push\' || d.topic !== \'spawnCheck\'', 'to push messages of topic spawnCheck')
    local states = {}
    for st in tclient:gmatch('PushCheck%(\'(%w+)\'') do states[st] = true end
    local ended = tclient:match('local state = errKey and \'(%w+)\' or %(stopped and \'(%w+)\' or \'(%w+)\'%)')
    H.ok(ended ~= nil, 'the Lua client ends with failed, stopped or done')
    for a in tclient:gmatch('local state = errKey and \'(%w+)\' or %(stopped and \'%w+\' or \'%w+\'%)') do
        states[a] = true
    end
    for b, c in tclient:gmatch('or %(stopped and \'(%w+)\' or \'(%w+)\'%)') do
        states[b], states[c] = true, true
    end
    local n = 0
    for st in pairs(states) do
        n = n + 1
        Has(store, 'case \'' .. st .. '\':', 'the store handles the ' .. st .. ' push')
    end
    H.eq(n, 6, 'every state the Lua client pushes (started, location, point, done, stopped, failed)')
    -- the fields the store reads are the ones the Lua client sends
    for _, f in ipairs({
        'missionId = data.missionId',
        'missionLabel = data.missionLabel',
        'locationLabel = data.locationLabel',
        'points = #points',
        'result = shown',
        'totals = totals',
        'error = errKey',
    }) do
        Has(tclient, f, 'the Lua client sends ' .. f:match('^(%w+)'))
    end
    for _, f in ipairs({
        'd.missionId',
        'd.missionLabel',
        'd.locationLabel',
        'd.result',
        'd.totals',
        'd.error',
        'd.progress',
        'd.missions',
        'd.locations',
    }) do
        Has(store, f, 'the store reads ' .. f)
    end

    -- the client actions the dialog calls are the Lua client's
    Has(store, 'clientAction<{ started: boolean; missions: number; locations: number }>(\'spawnCheck\', scope)',
        'Start calls the client action spawnCheck with the scope')
    Has(tclient, 'CP.Tablet.registerClientAction(\'spawnCheck\', StartSpawnCheck)', 'which the Lua client registers')
    Has(store, 'clientAction<{ stopping: boolean }>(\'spawnCheckStop\')', 'Stop calls spawnCheckStop')
    Has(tclient, 'CP.Tablet.registerClientAction(\'spawnCheckStop\',', 'which the Lua client registers')
    Has(dialog,
        'clientAction(\'teleport\', { target: \'point\', missionId: r.missionId, location: r.location, point: r.id })',
        'Teleport here sends the point by its id, no coordinates')
    Has(tclient,
        'if type(payload) == \'table\' and payload.target == \'point\' then return TeleportToPoint(payload) end',
        'the Lua teleport action takes a point without a test run')
    Has(mock, 'registerMock(\'client\', \'spawnCheck\',', 'browser mock: spawnCheck')
    Has(mock, 'registerMock(\'client\', \'spawnCheckStop\',', 'browser mock: spawnCheckStop')
    Has(mock, 'topic: \'spawnCheck\'', 'browser mock: the pushes')

    -- the button and Teleport here follow Config.Testing.spawnCheck (admin:getTests config.spawnCheck)
    Has(tserver, 'enabled = c.enabled ~= false and sc.enabled ~= false,', 'admin:getTests: spawnCheck.enabled')
    Has(tserver, 'teleport = sc.teleport ~= false,', 'admin:getTests: spawnCheck.teleport')
    Has(screen, 'const canCheck = !!view && !!view.config.spawnCheck && view.config.spawnCheck.enabled;',
        'the Testing screen hides the button while the check is off')
    Has(screen, 'onCheck: canCheck', 'and the per-location Check item')
    Has(dialog, '{cfg?.teleport ? (', 'the dialog hides Teleport here while it is off')

    -- the report reads like the server's console line: the same status words
    local block = tserver:match('local CHECK_STATUS = {(.-)}') or ''
    local words = 0
    for k, w in block:gmatch('([%w_]+) = \'([%u ]+)\'') do
        words = words + 1
        Has(store, k .. ': \'' .. w .. '\'', 'report status word for ' .. k .. ' = the server\'s ' .. w)
        H.ok(keys['test.ui.spawn.status_' .. k] == true, 'locale: test.ui.spawn.status_' .. k)
        H.ok(keys['test.ui.spawn.hint_' .. k] == true, 'locale: test.ui.spawn.hint_' .. k)
    end
    H.eq(words, 9, 'every status the probe gives (and skipped)')
    Has(store,
        '`spawn check: ${r.missionId} #${r.location} ${r.id} (${r.x.toFixed(2)}, ${r.y.toFixed(2)}, ${r.z.toFixed(2)}) `',
        'the report line starts like the console line')
    Has(tserver, '\'spawn check: %s #%d %s (%.2f, %.2f, %.2f) %s ground %s (%s) [%s]\'', 'the console line it copies')

    -- every text the dialog and the store show exists
    for _, text in ipairs({ dialog, store }) do
        for key in pairs(LiteralKeys(text)) do H.ok(keys[key] == true, 'locale key exists: ' .. key) end
    end
    for _, kind in ipairs({ 'ped', 'vehicle', 'prop', 'marker', 'path' }) do
        H.ok(keys['test.ui.spawn.kind_' .. kind] == true, 'locale: test.ui.spawn.kind_' .. kind)
    end
    for _, st in ipairs({ 'idle', 'running', 'done', 'stopped', 'failed' }) do
        H.ok(keys['test.ui.spawn.state_' .. st] == true, 'locale: test.ui.spawn.state_' .. st)
    end
    for _, st in ipairs({ 'done', 'stopped', 'failed' }) do
        H.ok(keys['test.ui.spawn.toast_' .. st] == true, 'locale: test.ui.spawn.toast_' .. st)
    end
    H.ok(keys['test.ui.spawn.blocked_test'] == true, 'locale: test.ui.spawn.blocked_test (the screen passes it)')
    for key in tclient:gmatch('\'(err%.spawn_check_[%w_]+)\'') do H.ok(keys[key] == true, 'locale: ' .. key) end
    for key in tserver:gmatch('\'(err%.spawn_check_[%w_]+)\'') do H.ok(keys[key] == true, 'locale: ' .. key) end
end

-- ============================================================================
--             ADMIN UI: DIALOG STATE, JOB PROGRESS AND TEXTS (X8)
-- ============================================================================

-- Void runs (Officers, Leaderboards, Missions -> History): the screen behind the dialog re-renders on every push and
-- poll and passes a new `initial` object each time; that must not clear the preview, the typed word, the reason or
-- the progress, nor change the filter between Preview and Void.
do
    local dialog = Read(WEB .. 'admin/components/BulkVoidDialog.tsx') or ''
    Has(dialog, 'initial: given, name, onDone }: BulkVoidDialogProps', 'the dialog keeps the filter it opened with')
    Has(dialog, 'const [initial, setInitial] = useState<BulkVoidFilter | undefined>(given);',
        'the fixed filter is a snapshot (state), not the prop')
    local reset = dialog:match('useEffect%(%(%) => {%s*if %(!open%) return;(.-)}, %[([^%]]*)%]%);')
    local _, deps = dialog:match('useEffect%(%(%) => {%s*if %(!open%) return;(.-)}, %[([^%]]*)%]%);')
    H.ok(reset ~= nil and reset:find('setInitial(given);', 1, true) ~= nil, 'the snapshot is taken when it opens')
    H.eq(deps, 'open', 'the form resets only when the dialog opens (not when the screen behind re-renders)')
    Has(dialog, 'toast(\'success\', t(\'ui.admin_officers.bulk.started\'', 'a started void says so')
    H.ok(keys['ui.admin_officers.bulk.started'] == true, 'locale: ui.admin_officers.bulk.started')
end

-- A small job's progress pushes can reach the NUI before the action's reply mounts JobProgress: the last push of
-- each job is kept outside React from the start and the progress starts from it.
do
    local job = Read(WEB .. 'admin/components/kit/JobProgress.tsx') or ''
    local hook = job:find('export function useAdminJob', 1, true) or 0
    local listener = job:find('window.addEventListener(\'message\'', 1, true)
    H.ok(listener ~= nil and listener < hook,
        'adminjob pushes are kept by a listener of the module, not of a component')
    Has(job, 'if (!m || typeof m !== \'object\' || m.type !== \'push\' || m.topic !== \'adminjob\') return;',
        'it keeps the adminjob pushes')
    Has(job, 'useSyncExternalStore(subscribe, () => (jobId ? (lastPush.get(jobId) ?? null) : null))',
        'useAdminJob(jobId) reads the kept push (also one from before it mounted)')
    local settings = Read(WEB .. 'admin/screens/Settings.tsx') or ''
    Has(settings, '\'server:admin:recheckAllBadges\', {}, { success: \'int.ui.recheck_started\' }',
        'Re-check everyone\'s badges says it started')
    H.ok(keys['int.ui.recheck_started'] == true, 'locale: int.ui.recheck_started')
end

-- System: every tab's text key is written out (a key built from p.key is not checked and showed raw).
do
    local sys = Read(WEB .. 'admin/screens/System.tsx') or ''
    local union = sys:match('type Panel = ([^;]+);') or ''
    local n = 0
    for key in union:gmatch('\'([%w_]+)\'') do
        n = n + 1
        Has(sys, ('label: () => t(\'sysadmin.ui.tab.%s\')'):format(key),
            'System tab ' .. key .. ': its key is written out')
        H.ok(keys['sysadmin.ui.tab.' .. key] == true, 'locale: sysadmin.ui.tab.' .. key)
    end
    H.eq(n, 6, 'System has six tabs')
    H.ok(sys:find('t(`sysadmin.ui.tab.', 1, true) == nil, 'no tab text is built from the key')
end

-- Audit: the Cash actions preset lists the payout clears too, and every action the server writes has a label.
do
    local audit = Read(WEB .. 'admin/screens/Audit.tsx') or ''
    local list = audit:match('const CASH_ACTIONS = %[(.-)%];') or ''
    local cash = {}
    for name in list:gmatch('\'([%w_]+)\'') do cash[#cash + 1] = name end
    local has = {}
    for _, name in ipairs(cash) do has[name] = true end
    H.ok(has.clearTypePayout and has.clearMissionPayout, 'Cash actions lists clearTypePayout and clearMissionPayout')
    H.ok(#cash <= 30, 'Cash actions stays within the 30 names the server takes: ' .. #cash)
    local en = cjson.decode(Read(ROOT .. 'locales/en.json') or '{}')
    local NOT_ACTIONS = {
        admin = true,
        supervisor = true,
        console = true,
        audit = true,
        flags = true,
        builder = true,
        operations = true,
    }
    local found, missing, n = {}, {}, 0
    local p = io.popen('ls ' .. ROOT .. 'modules/*/server.lua')
    for file in p:lines() do
        local src = Read(file) or ''
        for _, pat in ipairs({
            'ctx%.audit%(%s*\'([%w_]+)\'',
            'auditSync%([^,]+,%s*\'[%w_]+\',%s*\'([%w_]+)\'',
            'Admin%.audit%([^,]+,[^,]+,%s*\'[%w_]+\',%s*\'([%w_]+)\'',
            '\'Admin\',%s*\'audit\',[^,]+,[^,]+,%s*\'[%w_]+\',%s*\'([%w_]+)\'',
            '[^%w_.:]Audit%(%s*[%w_.]+%s*,%s*\'([%w_]+)\'',
        }) do
            for name in src:gmatch(pat) do
                if not NOT_ACTIONS[name] and not found[name] then
                    found[name] = true
                    n = n + 1
                    if type(en['admin.action.' .. name]) ~= 'string' then missing[#missing + 1] = name end
                end
            end
        end
    end
    p:close()
    table.sort(missing)
    H.ok(n >= 100, 'the audit actions the server writes are found: ' .. n)
    H.eq(#missing, 0, 'every audit action shows a label, not its raw name (' .. table.concat(missing, ', ') .. ')')

    -- the maintenance lock: Crimson-Police never restarts itself (owner decision 2), so the banner never says so
    for _, k in ipairs({ 'ui.maintenance.title.storage', 'ui.maintenance.title.restore', 'ui.maintenance.restart' }) do
        H.ok(type(en[k]) == 'string' and not en[k]:lower():find('restarting', 1, true), k .. ': not "restarting"')
    end
    for _, k in ipairs({ 'ui.maintenance.admin.storage_done', 'ui.maintenance.admin.restore_done' }) do
        H.ok(type(en[k]) == 'string' and en[k]:find('done', 1, true) ~= nil, k .. ': says the work is done')
    end
    local banner = Read(WEB .. 'shared/components/MaintenanceBanner.tsx') or ''
    Has(banner, 'return done ? t(\'ui.maintenance.admin.storage_done\') : t(\'ui.maintenance.admin.storage\');',
        'a finished storage copy or switch says it is done and waits for the restart')
    Has(banner, 'return done ? t(\'ui.maintenance.admin.restore_done\') : t(\'ui.maintenance.admin.restore\');',
        'a finished restore says it is done and waits for the restart')
    Has(banner, 'const done = !!m.restart && !m.failed;', 'done = the work ended and only the restart is left')
    -- a restore that stopped part way is ended by an admin's restore, not by a restart (the lock comes back)
    Has(banner,
        'return kind === \'restore_failed\' ? t(\'ui.maintenance.officer_restore_failed\') : t(\'ui.maintenance.officer\');',
        'officers read their own line for a restore that stopped part way')
    Has(banner, ': officerText(kind)}', 'and the banner uses it')
    H.ok(
        type(en['ui.maintenance.officer_restore_failed']) == 'string'
            and en['ui.maintenance.officer_restore_failed']:find('an admin finishes restoring a backup', 1, true) ~= nil
            and not en['ui.maintenance.officer_restore_failed']:lower():find('restart', 1, true),
        'that line says an admin\'s restore ends it, not a restart'
    )
    H.ok(type(en['err.maintenance']) == 'string' and not en['err.maintenance']:lower():find('restart', 1, true),
        'err.maintenance does not promise that a restart ends the lock')
end

-- npm run dev: the Settings confirms (a reload setting that breaks missions, Cash.source = society) have mocks.
do
    local sm = Read(WEB .. 'mocks/settings.mock.ts') or ''
    local em = Read(WEB .. 'mocks/admin_economy.mock.ts') or ''
    Has(sm, 'registerMock(\'request\', \'admin:trialMissions\'', 'dev mode answers admin:trialMissions')
    Has(em, 'registerMock(\'request\', \'admin:previewCashSource\'', 'dev mode answers admin:previewCashSource')
    Has(sm, 's(\'Limits.maxUnitSize\', \'number\'',
        'the dev Settings list has a reload setting that can break missions')
    Has(sm, '\'Cash.source\',', 'and Cash.source')
end

-- Mission Builder -> Publish: an edited built-in is written to overrides/<id>.lua (FilePathFor).
do
    local pub = Read(WEB .. 'builder/steps/StepPublish.tsx') or ''
    Has(pub, 'const filePath = `${exportDir}${rec?.overridesBuiltin ? \'overrides/\' : \'\'}${ed.id}.lua`;',
        'the Lua file line follows the record: overrides/ for an edited built-in')
    Has(pub, '<span className="builder_client-mono">{filePath}</span>', 'the Lua file line shows it')
    Has(pub, 'version: rec?.draftVersion ?? 1, file: filePath', 'and so does the publish confirm')
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
