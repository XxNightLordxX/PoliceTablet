-- Full admin control, the foundation (P0): CP.AdminKit's guards, request ids, previews, self checks, jobs and the busy
-- lock, CP.Maintenance and the net gate, the new permission keys, the Access, Admin, Tablet and Cash seams, the
-- Settings additions (locked paths, ranges, money switches, point values, row templates, names, history, validators).

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/permissions, access, admin, adminkit, confighealth, settings, tablet, cash. Stand-in:
-- CP.Qbx (the players below, their licenses and Qbox's players table).

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if not line:find('crimson%-police') then realPrint(line) end
end

H.boot({ side = 'server', realLocale = true })

-- a line printed before any module loaded is kept, its secrets cut out
CP.warn('early', 'a webhook https://discord.com/api/webhooks/123456/abcDEF_gh-1 and license:0123456789abcdef0123')

local hooks = {}
_G.GetConvar = function(name, default) return hooks[name] or default end
local posts = {}
_G.PerformHttpRequest = function(url, _, method, body) posts[#posts + 1] = { url = url, body = body } end

local LIC1 = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
local LIC3 = 'license:cccccccccccccccccccccccccccccccccccccc3'
local people = {
    [1] = { cid = 'ADM00001', license = LIC1, job = 'sast', grade = 4, ace = true },
    [2] = { cid = 'SUP00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [3] = { cid = 'ADM00003', license = LIC3, job = 'fib', grade = 1, ace = true },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
}
local qboxLicense = { ALT00001 = LIC1 }   -- Qbox's players table: characters that never opened the tablet
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
end

local function Info(src)
    local p = people[src]
    if not p then return nil end
    return {
        src = src,
        citizenid = p.cid,
        license = p.license,
        name = 'Player ' .. src,
        job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
    }
end
CP.Qbx = {
    getInfo = Info,
    getByCitizenId = function(cid)
        for src, p in pairs(people) do
            if p.cid == cid then return src end
        end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for src in pairs(people) do out[#out + 1] = src end
        table.sort(out)
        return out
    end,
    licenseOf = function(cid)
        for _, p in pairs(people) do
            if p.cid == cid then return p.license end
        end
        return qboxLicense[cid]
    end,
    citizenidsOfLicense = function(lic)
        local out = {}
        for cid, l in pairs(qboxLicense) do
            if l == lic then out[#out + 1] = cid end
        end
        return out
    end,
    characterExists = function(cid) return qboxLicense[cid] ~= nil end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}

H.sql('DELETE FROM cp_audit')
H.sql('DELETE FROM cp_settings')
H.sql('DELETE FROM cp_settings_history')
H.sql('DELETE FROM cp_admin_jobs')
H.sql('DELETE FROM cp_admin_requests')
H.sql('DELETE FROM cp_officers')
H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_mission_runs_archive')

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/confighealth/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/cash/server.lua',
}) do
    H.load(m)
end
H.step(0)

local Kit, Maint, S, A, P, T, Admin =
    CP.AdminKit, CP.Maintenance, CP.Settings, CP.Access, CP.Permissions, CP.Tablet, CP.Admin
local U = CP.U

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'k' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end

-- in a server thread (the audit and the money steps wait for the database)
local function Async(fn)
    local res
    CreateThread(function() res = table.pack(fn()) end)
    return table.unpack(res or {}, 1, res and res.n or 0)
end

local function Rid(n) return ('%08x-0000-4000-8000-%012x'):format(n, 77) end

local function Count(sql)
    local r = H.sql(sql)[1]
    if not r then return 0 end
    for _, v in pairs(r) do return math.floor(tonumber(v) or 0) end
    return 0
end

-- ============================================================================
--                 1. THE PROBLEMS BUFFER (FROM THE FIRST LINE)
-- ============================================================================

do
    local found = nil
    for _, l in ipairs(CP.Problems.list({ tag = 'early' })) do found = l end
    H.ok(found ~= nil, 'a warning printed before any module loaded is kept')
    H.ok(found and found.text:find('<webhook link>', 1, true) ~= nil and not found.text:find('discord.com', 1, true),
        'a webhook link in it is cut out: ' .. tostring(found and found.text))
    H.ok(found and found.text:find('license:…0123', 1, true) ~= nil, 'a license keeps only its last 4 characters')
    CP.err('later', 'connect mysql://root:secret@db/cp?x=1 user=a;password=hunter2;')
    local e = CP.Problems.list({ limit = 1 })[1]
    H.ok(
        e.level == 'error' and e.tag == 'later' and not e.text:find('hunter2', 1, true)
            and not e.text:find('secret@', 1, true),
        'connection strings and passwords are cut out: ' .. e.text
    )
    for i = 1, 210 do CP.warn('flood', 'line %d', i) end
    H.eq(#CP.Problems.list(), 200, 'the buffer keeps the last 200 lines')
    H.eq(CP.Problems.list({ limit = 1 })[1].text, 'line 210', 'newest first')
end

-- ============================================================================
--                          2. THE NEW PERMISSION KEYS
-- ============================================================================

do
    local keys = P.adminOnlyKeys()
    H.eq(#keys, 29, 'the 11 admin-only actions of the spec and the 18 keys of full admin control')
    Config.Permissions.supervisor = U.copy(Config.Permissions.supervisor)
    for _, k in ipairs(keys) do Config.Permissions.supervisor[k] = true end
    H.ok(A.isSupervisor(2) and not A.isAdmin(2), 'player 2 is a supervisor')
    local bad = {}
    for _, k in ipairs(keys) do
        if not P.can(1, k) then bad[#bad + 1] = 'admin:' .. k end
        if not P.can(0, k) then bad[#bad + 1] = 'console:' .. k end
        if P.can(2, k) then bad[#bad + 1] = 'supervisor:' .. k end
        if P.can(99, k) then bad[#bad + 1] = 'unknown:' .. k end
    end
    H.eq(table.concat(bad, ', '), '',
        'admins and the console pass every key; a supervisor never does, even switched on')
    H.ok(P.isAdminOnly('cleanup') and not P.isAdminOnly('forceRecall'), 'isAdminOnly')
    local acts = P.actionsFor(1)
    H.ok(U.contains(acts, 'bulkVoid') and not U.contains(P.actionsFor(2), 'bulkVoid'),
        'the session actions list the new keys for admins only')
    Config.Permissions.supervisor = U.deepcopy(S._defaults().Permissions.supervisor)

    -- tookPart reads the archive too
    local run = '11111111-0000-4000-8000-000000000001'
    H.sql([[INSERT INTO cp_mission_runs_archive (run_uuid, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base) VALUES (?, 'patrol', 'beat_patrol', 'ALT00001', 'sast', 'completed', 'completed', 60)]],
        { run })
    H.eq(P.tookPart('ALT00001', run), true, 'a row in the archive counts as taking part')
    H.eq(P.tookPart('ADM00001', run), false, 'another character did not')
end

-- ============================================================================
--                        3. ACCESS: LICENSES AND SEAMS
-- ============================================================================

do
    H.ok(A.refreshOfficerRow(1) and A.refreshOfficerRow(3) and A.refreshOfficerRow(7),
        'the tablet open writes the rows')
    local r = H.sql('SELECT license FROM cp_officers WHERE citizenid = \'ADM00001\'')[1]
    H.eq(r and r.license, LIC1, 'cp_officers.license is written at every tablet open')
    H.sql('INSERT INTO cp_officers (citizenid, department, license) VALUES (\'ALT00002\', \'sast\', ?)', { LIC1 })
    H.eq(A.licenseOf('ADM00001'), LIC1, 'licenseOf from the row')
    H.eq(A.licenseOf('ALT00001'), LIC1, 'licenseOf from Qbox when no row has it')
    H.eq(A.licenseOf('NOBODY01'), nil, 'unknown: nil')
    H.eq(A.licenseOfSrc(3), LIC3, 'licenseOfSrc')
    local mine = A.selfCitizenids(1)
    table.sort(mine)
    H.eq(table.concat(mine, ','), 'ADM00001,ALT00001,ALT00002', 'every character of the admin\'s license')
    H.eq(#A.selfCitizenids(0), 0, 'the console has none')
    local d = A.dispatchSuspension('OFF00007')
    H.ok(d.suspended == false and d.available == false, 'an SC-Dispatch suspension without sc-dispatch: none')

    -- suspend until an exact time
    local ok = A.suspend('OFF00007', 0, 0, 'test', { untilTs = H.time + 5400 })
    local row = H.sql('SELECT UNIX_TIMESTAMP(suspended_until) AS ts FROM cp_officers WHERE citizenid = \'OFF00007\'')[1]
    H.ok(ok and row and math.floor(tonumber(row.ts)) == H.time + 5400, 'suspended until the exact moment (90 min)')
    local okP, eP = A.suspend('OFF00007', 0, 0, 'test', { untilTs = H.time - 10 })
    H.ok(not okP and eP == 'err.invalid_days', 'a moment in the past is refused')
    A.suspend('OFF00007', 0, 0, 'lift')

    -- caches: an admin change is seen at once
    H.ok(A.getOfficer(7) ~= nil, 'the officer opens the tablet')
    H.sql('UPDATE cp_officers SET suspended_until = FROM_UNIXTIME(?) WHERE citizenid = \'OFF00007\'', { H.time + 3600 })
    H.ok(A.getOfficer(7) ~= nil, 'a change made behind Access\'s back waits for its cache')
    Kit.changed('suspend', 'OFF00007')
    local _, e1 = A.getOfficer(7)
    H.eq(e1, 'err.suspended', 'admin:changed clears the suspension cache: refused at once')
    H.sql('UPDATE cp_officers SET suspended_until = NULL WHERE citizenid = \'OFF00007\'')
    Kit.changed('suspend', 'OFF00007')
    H.ok(A.getOfficer(7) ~= nil, 'a lifted suspension stops refusing at once')
    H.sql('UPDATE cp_officers SET retired_at = NOW() WHERE citizenid = \'OFF00007\'')
    Kit.changed('retire', 'OFF00007')
    local _, e2 = A.getOfficer(7)
    H.eq(e2, 'err.retired', 'a retired officer can\'t open the tablet')
    H.sql('UPDATE cp_officers SET retired_at = NULL WHERE citizenid = \'OFF00007\'')
    Kit.changed('retire', 'OFF00007')
    H.ok(A.getOfficer(7) ~= nil, 'unretired: back at once')
end

-- ============================================================================
--                       4. THE GUARDS OF ADMINKIT.ACTION
-- ============================================================================

local acted = {}
Kit.action('server:admin:kitTest', 'pointsAdjust', function(ctx)
    acted[#acted + 1] = ctx.payload.citizenid or '-'
    ctx.target = ctx.payload.citizenid
    return true, { n = #acted, reason = ctx.reason }
end, {
    rate = 20,
    reason = true,
    requestId = true,
    confirm = function(p) return p.word end,
    self = function(p) return { citizenid = p.citizenid, runUuid = p.runUuid, strict = p.strict } end,
    audit = 'kitTest',
})
Kit.action('server:admin:kitRate', 'liveRuns', function(ctx) return true, ctx.payload.citizenid end, {
    rate = 20,
    targetRate = { 1, 10000 },
})

do
    local ok, data = Act('server:admin:kitTest', 2, { requestId = Rid(1), reason = 'x', citizenid = 'OFF00007' })
    H.ok(ok == false and data == 'err.no_permission', 'a supervisor never passes an AdminKit action')
    ok, data = Act('server:admin:kitTest', 7, { requestId = Rid(1), reason = 'x', citizenid = 'OFF00007' })
    H.ok(ok == false and data == 'err.no_permission', 'nor an officer')
    ok, data = Act('server:admin:kitTest', 1, { reason = 'x', citizenid = 'OFF00007' })
    H.ok(ok == false and data == 'err.request_id', 'a request id is required')

    -- R: trimmed, 1 to 255 characters (UTF-8)
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(2), reason = '   ', citizenid = 'OFF00007' })
    H.ok(ok == false and data == 'err.reason_required', 'a blank reason is refused')
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(2), reason = '  fine  ', citizenid = 'OFF00007' })
    H.ok(ok == true and data.reason == 'fine', 'a reason is trimmed (and the id refused before is free again)')
    ok = Act('server:admin:kitTest', 1, { requestId = Rid(3), reason = ('é'):rep(255), citizenid = 'OFF00007' })
    H.eq(ok, true, '255 accented characters (510 bytes) are fine')
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(4), reason = ('é'):rep(256), citizenid = 'OFF00007' })
    H.ok(ok == false and data == 'err.reason_too_long', '256 characters are refused')
    H.eq(Kit.reason('a\nb'), 'a b', 'control characters become spaces')

    -- T
    ok, data = Act('server:admin:kitTest', 1,
        { requestId = Rid(5), reason = 'r', citizenid = 'OFF00007', word = 'VOID 3', confirm = 'VOID 2' })
    H.ok(ok == false and data == 'err.confirm_mismatch', 'a typed word that does not match is refused')
    ok = Act('server:admin:kitTest', 1,
        { requestId = Rid(5), reason = 'r', citizenid = 'OFF00007', word = 'VOID 3', confirm = ' void 3 ' })
    H.eq(ok, true, 'the same id with the right word (any case, trimmed) acts')

    -- I: a repeat gets the first answer and acts once
    local before = #acted
    local ok1, d1 = Act('server:admin:kitTest', 1, { requestId = Rid(6), reason = 'once', citizenid = 'OFF00007' })
    local ok2, d2 = Act('server:admin:kitTest', 1, { requestId = Rid(6), reason = 'once', citizenid = 'OFF00007' })
    H.ok(ok1 and ok2 and d1.n == d2.n, 'a repeated request id returns the first result')
    H.eq(#acted, before + 1, 'and acts once')
    ok, data = Act('server:admin:kitTest', 3, { requestId = Rid(6), reason = 'once', citizenid = 'OFF00007' })
    H.ok(ok == true and data.n == d1.n, 'whoever sends it again')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_admin_requests WHERE request_id = \'' .. Rid(6) .. '\''), 1,
        'one cp_admin_requests row')

    -- S: every character of the admin's license
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(7), reason = 'r', citizenid = 'ADM00001' })
    H.ok(ok == false and data == 'err.self_target', 'the admin\'s own character is refused')
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(8), reason = 'r', citizenid = 'ALT00001' })
    H.ok(ok == false and data == 'err.self_target', 'and a second character of the same license (from Qbox)')
    ok, data = Act('server:admin:kitTest', 1, { requestId = Rid(9), reason = 'r', citizenid = 'ALT00002' })
    H.ok(ok == false and data == 'err.self_target', 'and one only Crimson-Police knows')
    ok, data = Act('server:admin:kitTest', 1, {
        requestId = Rid(10),
        reason = 'r',
        citizenid = 'OFF00007',
        runUuid = '11111111-0000-4000-8000-000000000001',
    })
    H.ok(ok == false and data == 'err.own_run', 'a run (archived) one of the admin\'s characters took part in')
    ok = Act('server:admin:kitTest', 3, { requestId = Rid(11), reason = 'r', citizenid = 'ADM00001' })
    H.eq(ok, true, 'another admin may act on that character')
    ok, data = Act('server:admin:kitTest', 1,
        { requestId = Rid(12), reason = 'r', citizenid = 'NOBODY01', strict = true })
    H.ok(ok == false and data == 'err.self_unknown', 'money and points: an unknown license is refused')
    ok = Act('server:admin:kitTest', 1, { requestId = Rid(13), reason = 'plain', citizenid = 'NOBODY01' })
    H.eq(ok, true, 'other actions go ahead')
    local a = H.sql('SELECT reason, actor_ident FROM cp_audit WHERE action = \'kitTest\' ORDER BY id DESC LIMIT 1')[1]
    H.ok(a and a.reason:find('licence unknown', 1, true) ~= nil,
        'and the audit row says so: ' .. tostring(a and a.reason))
    H.eq(a and a.actor_ident, LIC1, 'every audit row stores the acting player\'s license')
    local okC, dC = Async(function()
        return Kit.run('server:admin:kitTest', 0, { requestId = Rid(14), reason = 'console', citizenid = 'ADM00001' })
    end)
    H.ok(okC == true and dC.reason == 'console', 'the console is never "self"')

    -- L per target, across admins
    H.eq(Act('server:admin:kitRate', 1, { citizenid = 'OFF00007' }), true, 'first change of a target')
    local okR, eR = Act('server:admin:kitRate', 3, { citizenid = 'OFF00007' })
    H.ok(okR == false and eR == 'err.rate_limited', 'a second admin on the same target within the window is refused')
    H.eq(Act('server:admin:kitRate', 3, { citizenid = 'ADM00001' }), true, 'another target is fine')
end

-- ============================================================================
--                        5. V, K, A AND THE DAY COUNTS
-- ============================================================================

do
    local token = Kit.preview(1, 'bulkVoid', { 3, 1, 2 }, { rows = 3 })
    local ok, e = Kit.consume(3, token, 'bulkVoid', { 1, 2, 3 })
    H.ok(not ok and e == 'err.preview_missing', 'a token of another admin is refused')
    ok, e = Kit.consume(1, token, 'bulkVoid', { 1, 2 })
    H.ok(not ok and e == 'err.preview_stale', 'the ids changed since the preview')
    ok, e = Kit.consume(1, token, 'bulkVoid', { 1, 2, 3 })
    H.ok(not ok and e == 'err.preview_expired', 'a stale token is gone')
    token = Kit.preview(1, 'bulkVoid', { 3, 1, 2 }, { rows = 3 })
    local okT, eff = Kit.consume(1, token, 'bulkVoid', { 1, 2, 3 })
    H.ok(okT and eff.rows == 3, 'the same ids in any order: the effect comes back')
    H.eq((Kit.consume(1, token, 'bulkVoid', { 1, 2, 3 })), false, 'a token is used once')
    token = Kit.preview(1, 'bulkVoid', { 1 }, {})
    H.time = H.time + 121
    ok, e = Kit.consume(1, token, 'bulkVoid', { 1 })
    H.ok(not ok and e == 'err.preview_expired', 'after 120 s the preview expired')

    -- K
    H.sql('UPDATE cp_officers SET board_excluded = 0 WHERE citizenid = \'OFF00007\'')
    local okK = Async(function()
        return Kit.cas('UPDATE cp_officers SET board_excluded = 1 WHERE citizenid = ? AND board_excluded = 0',
            { 'OFF00007' })
    end)
    local okK2, eK2 = Async(function()
        return Kit.cas('UPDATE cp_officers SET board_excluded = 1 WHERE citizenid = ? AND board_excluded = 0',
            { 'OFF00007' })
    end)
    H.ok(okK and not okK2 and eK2 == 'err.state_changed', 'compare-and-set: the second of two never acts')

    -- A: a failing audit insert refuses a money action and moves nothing
    local moved = 0
    Kit.action('server:admin:kitMoney', 'payments', function(ctx)
        if not ctx.audit('kitMoney', 'OFF00007', nil, '100', { category = 'audit' }) then
            return false, 'err.internal'
        end
        moved = moved + 1
        return true
    end, { rate = 20, requestId = true, reason = true })
    local realInsert = MySQL.insert.await
    MySQL.insert.await = function(sql, ...)
        if tostring(sql):find('cp_audit', 1, true) then error('database away') end
        return realInsert(sql, ...)
    end
    local okM, eM = Act('server:admin:kitMoney', 1, { requestId = Rid(20), reason = 'pay' })
    MySQL.insert.await = realInsert
    H.ok(okM == false and eM == 'err.internal' and moved == 0, 'auditSync failed: refused, no money moved')
    H.eq(Act('server:admin:kitMoney', 1, { requestId = Rid(21), reason = 'pay' }), true, 'with the audit row it acts')
    H.eq(moved, 1, 'once')

    -- day counts come from the saved rows (a restart forgets nothing)
    local n = Async(function() return Kit.dailyCount('kitTest', { target = 'OFF00007' }) end)
    H.ok(n >= 3, ('kitTest on OFF00007 today: %d'):format(n))
    Kit._reset()
    H.eq(Async(function() return Kit.dailyCount('kitTest', { target = 'OFF00007' }) end), n,
        'the same count after a simulated restart')
    H.eq(Async(function() return Kit.dailyCount('kitTest', { target = 'OFF00007', since = H.time + 10 }) end), 0,
        'nothing since a later moment')
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, breakdown) VALUES
        ('22222222-0000-4000-8000-000000000001', 'manual_award', 'manual_adjust', 'OFF00007', 'sast', 'completed',
         'manual', 0, -40, '{"by":"ADM00001"}'),
        ('22222222-0000-4000-8000-000000000002', 'manual_award', 'manual_award', 'OFF00007', 'sast', 'completed',
         'manual', 0, 25, '{"by":"ADM00001"}'),
        ('22222222-0000-4000-8000-000000000003', 'manual_award', 'manual_adjust', 'OFF00007', 'sast', 'completed',
         'manual', 0, 10, '{"by":"ADM00003"}')]])
    H.eq(Async(function()
        return Kit.dailySum({ missionIds = { 'manual_adjust', 'manual_award' }, actor = 'ADM00001' })
    end), 65, 'the points one admin adjusted today, signs ignored')
end

-- ============================================================================
--                          6. JOBS AND THE BUSY LOCK
-- ============================================================================

do
    local seen, calls, crash, finished = {}, 0, true, 0
    Kit.registerJob('kitJob', {
        batch = function(_, ids)
            calls = calls + 1
            if crash and calls == 3 then
                crash = false
                coroutine.yield()   -- the server stops here (a crash): this thread never runs again
            end
            for _, id in ipairs(ids) do seen[id] = (seen[id] or 0) + 1 end
            return true
        end,
        finish = function() finished = finished + 1 end,
    })
    local ids = {}
    for i = 1, 150 do ids[i] = i end
    local ok, jobId = Async(function()
        return Kit.startJob({ kind = 'kitJob', src = 1, reason = 'test', ids = ids })
    end)
    H.ok(ok and type(jobId) == 'string', 'a job starts')
    H.eq((Kit.busy()), 'job', 'and holds the busy lock')
    local okB, eB = Async(function() return Kit.startJob({ kind = 'kitJob', src = 1, ids = { 1 } }) end)
    H.ok(not okB and eB == 'err.admin_busy', 'one job at a time')
    local okS, kS = Async(function() return Admin.storageCopy(0, 'database-to-files', false) end)
    H.ok(okS == false and kS == 'admin.cmd.storage_copy_busy', 'a storage copy waits for the job (the shared lock)')
    H.step(0)
    H.step(0)
    local job = Async(function() return Kit.job(jobId) end)
    H.ok(job and job.state == 'running' and job.done == 100,
        ('two batches saved before the crash (%d)'):format(job and job.done or -1))
    -- the restart: memory is gone, the saved job is not
    Kit._reset()
    H.eq(Kit.busy(), nil, 'after the restart nothing holds the lock')
    local resumed = Async(function() return Kit._resumeJobs() end)
    H.eq(resumed, 1, 'the interrupted job is finished at start-up')
    local twice = 0
    for i = 1, 150 do if seen[i] ~= 1 then twice = twice + 1 end end
    H.eq(twice, 0, 'every row once: no row twice, none left out')
    H.eq(finished, 1, 'its finish ran once')
    job = Async(function() return Kit.job(jobId) end)
    H.ok(job and job.state == 'done' and job.done == 150, 'saved as done')
    local adminPushes = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:push')) do
        if e.args[1] == 'adminjob' then adminPushes[e.target] = true end
    end
    H.ok(adminPushes[1] and adminPushes[3] and not adminPushes[2] and not adminPushes[7],
        'the adminjob progress reaches admin players only')

    -- a kind nobody registered: rolled back when it can be, else marked failed
    H.sql([[INSERT INTO cp_admin_jobs (id, kind, state, done, total, actor, created_at) VALUES
        ('33333333-0000-4000-8000-000000000001', 'gone', 'running', 0, 5, 'console', NOW())]])
    Async(function() return Kit._resumeJobs() end)
    H.eq((Async(function() return Kit.job('33333333-0000-4000-8000-000000000001') end) or {}).state, 'failed',
        'a job whose kind is gone is stopped, not left running')
    H.eq(Async(function() return Kit.withLock('backup', function() return Kit.busy() end) end), 'backup', 'withLock')
    H.eq(Kit.busy(), nil, 'and it is released')
end

-- ============================================================================
--                        7. AUDIT AND THE WEBHOOK QUEUE
-- ============================================================================

do
    hooks.cp_webhook_audit = 'https://discord.com/api/webhooks/1/token_a'
    hooks.cp_webhook_flags = 'https://discord.com/api/webhooks/2/token_b'
    local q = Admin._webhookQueue()
    for k in pairs(q) do q[k] = nil end
    local before = #q
    Async(function() return Admin.audit(1, 'admin', 'audit', 'bulkRow', '#1', nil, nil, 'r', { noWebhook = true }) end)
    H.eq(#q, before, 'a bulk row (noWebhook) posts nothing')
    H.ok(Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'bulkRow\'') == 1, 'but is in the audit log')
    for i = 1, 120 do Admin.webhook('audit', 'ordinary ' .. i, 'x') end
    H.eq(#q, 100, 'the queue holds 100 posts at most')
    local id = Async(function()
        return Admin.auditSync(1, 'admin', 'audit', 'moneyThing', 'OFF00007', nil, '500', 'r')
    end)
    H.ok(type(id) == 'number' and id > 0, 'auditSync returns the row id')
    local critical = 0
    for _, job in ipairs(q) do if job.critical then critical = critical + 1 end end
    H.ok(#q == 100 and critical == 1, 'a full queue keeps the post of a typed-confirmation or money action')
    H.ok(Admin._webhookDropped() > 0, 'and counts the ordinary posts it dropped')
    H.eq(Async(function() return Admin.auditSync(1, 'admin', 'audit', '', 'x') end), false, 'no action: false')

    -- the audit filters
    local res = Cb('admin:getAudit', 1, { actorIdent = LIC1, action = 'moneyThing' })
    H.ok(res and res.ok and res.data.total == 1 and res.data.rows[1].actorIdent == LIC1,
        'filter by the actor\'s player')
    res = Cb('admin:getAudit', 1, { target = 'OFF00007', action = 'moneyThing' })
    H.ok(res and res.ok and res.data.total == 1, 'filter by target')
    res = Cb('admin:getAudit', 1, { role = 'console' })
    H.ok(res and res.ok and res.data.total >= 1, 'filter by role')
    res = Cb('admin:getAudit', 1, { reason = '100%' })
    H.ok(res and res.ok and res.data.total == 0, 'a % in the reason search is a plain character')
    local whs = Admin.webhooks()
    H.ok(whs[1].category == 'audit' and whs[1].state == 'on' and whs[1].discord == true, 'a Discord link: on')
    hooks.cp_webhook_board = 'https://discord.com.evil.example/api/webhooks/1/x'
    for _, w in ipairs(Admin.webhooks()) do
        if w.category == 'board' then H.ok(w.discord == false, 'a look-alike host is not a Discord link') end
        H.eq(w.url, nil, 'the link itself never leaves the module')
    end
    hooks.cp_webhook_board = nil
    for k in pairs(q) do q[k] = nil end
end

-- ============================================================================
--                 8. MAINTENANCE, THE NET GATE AND THE TABLET
-- ============================================================================

local passed = 0
Kit.action('server:admin:kitStatus', 'storageAdmin', function()
    passed = passed + 1
    return true
end, { rate = 20, maintenance = true })

do
    H.reset()
    H.ok(Maint.begin('storage', { by = 'ADM00001' }), 'a storage copy takes the maintenance lock')
    H.eq((Maint.active()), 'storage', 'active')
    local ok, e = Act('server:admin:kitTest', 1, { requestId = Rid(30), reason = 'r', citizenid = 'OFF00007' })
    H.ok(ok == false and e == 'err.maintenance', 'an admin action is refused')
    ok, e = Act('server:admin:setSetting', 1, { path = 'Debug', value = false })
    H.ok(ok == false and e == 'err.maintenance', 'every other action too (the net gate)')
    H.eq(Act('server:admin:kitStatus', 1, {}), true, 'an action marked for maintenance still works')
    local view = Cb('admin:getSettings', 1)
    H.ok(view and view.ok, 'reads keep working')
    local session = Cb('getSession', 1, { ui = 'admin' })
    H.ok(session and session.ok and session.data.maintenance and session.data.maintenance.kind == 'storage',
        'the session carries the lock')
    local pushed = false
    for _, ev in ipairs(H.findEvents('crimson-police:client:push')) do
        if ev.args[1] == 'maintenance' and ev.target == -1 then pushed = true end
    end
    H.ok(pushed, 'every tablet gets the maintenance push')
    H.ok(Maint.askRestart('storage') and Maint.view().restart == true, 'done: only a restart by the owner ends it')
    H.ok(not (Maint.begin('restore')), 'another kind waits')
    H.ok(Maint.finish('storage') and Maint.active() == nil, 'finish reopens')
    H.eq(Act('server:admin:setSetting', 1, { path = 'Debug', value = Config.Debug }), true, 'actions work again')

    -- admin-only sidebar counts
    T.registerNavCount('adminTest', function() return 4 end, { adminOnly = true })
    T.registerNavCount('everyone', function() return 2 end)
    local c1 = T.navCounts(1)
    local c7 = T.navCounts(7)
    H.eq(c1.adminTest, 4, 'an admin-only count reaches an admin')
    H.eq(c7.adminTest, nil, 'never an officer')
    H.eq(c7.everyone, 2, 'a count for everyone reaches officers')
    H.reset()
    H.eq(T.pushAdmins('adminthing', { a = 1 }), 2, 'pushAdmins: the two online admins')
    for _, ev in ipairs(H.findEvents('crimson-police:client:push')) do
        H.ok(ev.target == 1 or ev.target == 3, 'to admin ' .. tostring(ev.target))
    end
end

-- ============================================================================
--                          9. CASH AND STORAGE SEAMS
-- ============================================================================

do
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, cash_paid, cash_status) VALUES
        ('44444444-0000-4000-8000-000000000001', 'patrol', 'beat_patrol', 'OFF00007', 'sast', 'completed', 'completed',
         60, 100, 'paid'),
        ('44444444-0000-4000-8000-000000000002', 'manual_award', 'manual_cash', 'OFF00007', 'sast', 'completed',
         'manual', 0, 500, 'paid')]])
    H.eq(Async(function() return CP.Cash.paidToday('OFF00007') end), 100,
        'paidToday counts run pay and leaves manual cash out (it has its own limit)')
    -- the database side reads information_schema, which only MariaDB has (the twin engine can't follow it)
    if not H.skipIn('shadow', 'storageStatus reads information_schema') then
        local st = Async(function() return Admin.storageStatus() end)
        local names = {}
        for _, t in ipairs(st.tables or {}) do names[t.name] = t.rows end
        H.ok(
            st.mode == (H.storage == 'files' and 'files' or 'database') and names.cp_admin_jobs ~= nil
                and names.cp_settings_history ~= nil,
            'storageStatus: the mode and every table with its rows'
        )
        H.ok(st.folder == 'saves' and not tostring(st.folder):find('/', 1, true),
            'the folder by its setting, never a full path')
    end
    H.eq(Admin.missionLabel('manual_adjust'), 'Points adjustment', 'labels of the new manual row kinds')
end

-- ============================================================================
--                                 10. SETTINGS
-- ============================================================================

local function Check(path, value) return S.check(path, value) end
local function Err(path, value, expected, msg)
    local ok, e = Check(path, value)
    H.eq(ok, false, msg .. ' (refused)')
    H.eq(e, expected, msg)
end

do
    -- locked: Hard rule names, call-id formats, code facts
    for _, p in ipairs({
        'Tablet.title',
        'Tablet.adminCommand',
        'Calls.npcCallPrefix',
        'Calls.ownRunCallPrefixes',
        'Bonuses.hostile_arrested.each',
        'Bonuses.hostile_arrested.block',
        'Bonuses.rapid_response.engineOnly',
    }) do
        local ok, e = S.set(1, p, U.deepcopy(U.getPath(Config, p)))
        H.ok(not ok and e == 'err.setting_locked', p .. ' is locked')
    end
    H.eq(S.view('Tablet.title').locked, 'settings.locked.names', 'with the reason shown')

    -- ranges of the real-call, alert, route and downed numbers
    Err('Calls.dodgeWindow', 5, 'err.setting_range', 'dodgeWindow below 10 s')
    H.ok((Check('Calls.dodgeWindow', 90)), 'dodgeWindow 90 s')
    Err('Route.maxDrift', 100, 'err.setting_range', 'maxDrift below 200 m')
    Err('Downed.checkEvery', 11, 'err.setting_range', 'checkEvery above 10 s')
    Err('Alerts.backstopRadius', 2000, 'err.setting_range', 'backstopRadius above 1000 m')
    Err('AdminControl.bulkMaxRows', 0, 'err.setting_range', 'a bulk job changes 1 row at least')
    H.ok(
        S.entry('AdminControl.pointAdjust') ~= nil and S.entry('Cash.allowClawback') ~= nil and S.entry('Labels') ~= nil
            and S.entry('Backups.keep') ~= nil and S.entry('Events.modifiers.time_crunch') ~= nil
            and S.entry('Departments.sast.enabled') ~= nil,
        'the new keys are settings'
    )

    -- a bonus's kind only together with its value
    local ok, e = S.set(1, 'Bonuses.no_weapons_fired.kind', 'pct')
    H.ok(not ok and e == 'err.setting_kind_alone', 'the kind alone is refused')
    ok, e = S.setMany(1, {
        { path = 'Bonuses.no_weapons_fired.kind', value = 'pct' },
        { path = 'Bonuses.no_weapons_fired.value', value = 2 },
    })
    H.ok(not ok and e == 'err.setting_range', 'a share above 1 for a pct bonus')
    ok = S.setMany(1, {
        { path = 'Bonuses.no_weapons_fired.kind', value = 'pct' },
        { path = 'Bonuses.no_weapons_fired.value', value = 0.1 },
    })
    H.ok(ok and Config.Bonuses.no_weapons_fired.kind == 'pct' and Config.Bonuses.no_weapons_fired.value == 0.1,
        'kind and value together')
    Err('Bonuses.correct_log.value', 7.5, 'err.setting_whole', 'a points bonus is a whole number')
    Err('Bonuses.correct_log.value', 600, 'err.setting_range', 'at most 500 points')
    Err('Bonuses.wrong_log.value', 5, 'err.setting_positive', 'a penalty stays a penalty')
    H.ok(S.view('Bonuses.no_weapons_fired.value').points == true, 'a point value carries the flag')
    local q = Admin._webhookQueue()
    for k in pairs(q) do q[k] = nil end
    ok = S.reset(1, 'Bonuses.no_weapons_fired.value')
    H.ok(ok and Config.Bonuses.no_weapons_fired.kind == 'points' and Config.Bonuses.no_weapons_fired.value == 10,
        'a reset puts the kind and the value back together')
    local flags = 0
    for _, j in ipairs(q) do if j.category == 'flags' then flags = flags + 1 end end
    H.ok(flags >= 1, 'a point value change posts a notice to the flags webhook')
    ok = S.set(1, 'MissionTypes.patrol.points', 70)
    H.ok(ok and Config.MissionTypes.patrol.points == 70, 'an admin changes a point value')
    S.reset(1, 'MissionTypes.patrol.points')

    -- money switches need the typed word
    ok, e = S.set(1, 'Cash.allowClawback', true)
    H.ok(not ok and e == 'err.confirm_enable' and Config.Cash.allowClawback == false,
        'turning a money tool on needs ENABLE')
    local okN, eN = Act('server:admin:setSetting', 1, { path = 'Cash.allowManualCash', value = true, confirm = 'yes' })
    H.ok(okN == false and eN == 'err.confirm_enable', 'checked on the server for the net action too')
    ok = Act('server:admin:setSetting', 1, { path = 'Cash.allowManualCash', value = true, confirm = ' enable ' })
    H.ok(ok == true and Config.Cash.allowManualCash == true, 'with ENABLE it is on')
    local last = H.sql('SELECT action, target, old_value, new_value FROM cp_audit ORDER BY id DESC LIMIT 1')[1]
    H.ok(last and last.action == 'moneySwitch' and last.target == 'Cash.allowManualCash' and last.new_value == 'on',
        'audited as a money switch')
    H.ok(S.set(1, 'Cash.allowManualCash', false) and Config.Cash.allowManualCash == false,
        'turning it off needs nothing')
    H.ok(S.view('Rewards.allowTakeBack').money == true, 'Rewards.allowTakeBack is a money switch')

    -- the six row templates
    local D = S._defaults()
    for _, p in ipairs({
        'Builder.noBuildZones',
        'Downed.dropOffs',
        'MissionCalls.areas',
        'Scaling',
        'XPLevels',
        'Profile.avatarPresets',
    }) do
        H.ok((Check(p, U.deepcopy(U.getPath(D, p)))), p .. ': the shipped rows pass')
        local e2 = S.entry(p)
        H.ok(e2.kind == 'rows' and type(e2.rows) == 'table' and (e2.rows.fields or e2.rows.bare), p .. ': a row editor')
    end
    local zones = U.deepcopy(D.Builder.noBuildZones)
    local arena = nil
    for i, z in ipairs(zones) do if z.label == 'Crimson-Arena lobby' then arena = i end end
    local cut = U.deepcopy(zones)
    table.remove(cut, arena)
    Err('Builder.noBuildZones', cut, 'err.setting_arena_zone', 'an arena zone removed')
    local small = U.deepcopy(zones)
    small[arena].radius = 30.0
    Err('Builder.noBuildZones', small, 'err.setting_arena_zone', 'an arena zone made smaller')
    local moved = U.deepcopy(zones)
    moved[arena].coords = vec3(0.0, 0.0, 30.0)
    Err('Builder.noBuildZones', moved, 'err.setting_arena_zone', 'an arena zone moved')
    local grown = U.deepcopy(zones)
    grown[arena].radius = 90.0
    H.ok((Check('Builder.noBuildZones', grown)), 'an arena zone may grow')
    local tiny = U.deepcopy(zones)
    tiny[1].radius = 5.0
    Err('Builder.noBuildZones', tiny, 'err.setting_range', 'a zone radius below 10 m')
    local areas = U.deepcopy(D.MissionCalls.areas)
    areas[2].key = areas[1].key
    Err('MissionCalls.areas', areas, 'err.setting_duplicate', 'an area key used twice')
    areas = U.deepcopy(D.MissionCalls.areas)
    areas[1].center = vec3(90000.0, 0.0, 0.0)
    Err('MissionCalls.areas', areas, 'err.setting_outside_map', 'an area centre outside the map')
    local rows = U.deepcopy(D.Scaling)
    rows[3].maxParticipants = 2
    Err('Scaling', rows, 'err.setting_order', 'maxParticipants must keep rising')
    rows = U.deepcopy(D.Scaling)
    rows[2].tier = 'mega'
    Err('Scaling', rows, 'err.setting_option', 'a tier that does not exist')
    rows = { U.deepcopy(D.Scaling[1]) }
    Err('Scaling', rows, 'err.setting_scaling_last', 'the last row must cover the largest unit')
    local levels = U.deepcopy(D.XPLevels)
    levels[1].xp = 5
    Err('XPLevels', levels, 'err.setting_xp_first', 'the first level starts at 0 XP')
    levels = U.deepcopy(D.XPLevels)
    levels[3].xp = levels[2].xp
    Err('XPLevels', levels, 'err.setting_order', 'XP keeps rising')
    local presets = U.deepcopy(D.Profile.avatarPresets)
    presets[1].id = 'unicorn'
    Err('Profile.avatarPresets', presets, 'err.setting_option', 'a picture the UI does not ship')
    Err('Downed.dropOffs', {}, 'err.setting_too_few', 'one drop-off at least')
    Err('Downed.dropOffs', { vec3(0.0, 99000.0, 0.0) }, 'err.setting_outside_map', 'a drop-off outside the map')

    -- a validator another module registers applies to the raw editor too
    H.ok(S.registerValidator('Limits.maxCompletionsHour', function(_, v)
        if v > 20 then return 'err.setting_range' end
    end), 'registerValidator')
    local okV, eV = Act('server:admin:setSetting', 1, { path = 'Limits.maxCompletionsHour', json = '30' })
    H.ok(okV == false and eV == 'err.setting_range', 'the raw editor gets the validator\'s answer')
    H.ok(S.set(1, 'Limits.maxCompletionsHour', 12) and Config.Limits.maxCompletionsHour == 12, 'a value it allows')

    -- the history: the full old and new values, who and the license
    S.set(1, 'Profile.bannedWords', { 'alpha', 'beta' })
    local h = H.sql([[SELECT setting_key, action, old_json, new_json, by_actor, by_ident FROM cp_settings_history
        WHERE setting_key = 'Profile.bannedWords' ORDER BY id DESC LIMIT 1]])[1]
    H.ok(h and h.action == 'settingChanged' and h.old_json == nil and h.by_actor == 'ADM00001' and h.by_ident == LIC1,
        'a history row with who changed it (citizenid and license)')
    H.eq(h and cjson.decode(h.new_json).v[2], 'beta', 'and the full new value')
    S.reset(1, 'Profile.bannedWords')
    h = H.sql([[SELECT action, old_json, new_json FROM cp_settings_history WHERE setting_key = 'Profile.bannedWords'
        ORDER BY id DESC LIMIT 1]])[1]
    H.ok(h and h.action == 'settingReset' and h.new_json == nil and cjson.decode(h.old_json).v[1] == 'alpha',
        'a reset keeps the old value (NULL = config.lua\'s)')
    local hist = Async(function() return S.history({ path = 'Profile.bannedWords' }) end)
    H.ok(hist and hist.total == 2 and hist.rows[1].action == 'settingReset' and hist.rows[2].new[1] == 'alpha',
        'Settings.history reads them back, newest first')
    local entry = Async(function() return S.historyEntry(hist.rows[2].id) end)
    H.ok(entry and entry.path == 'Profile.bannedWords' and entry.newSaved == true, 'historyEntry')

    -- names (Config.Labels)
    ok = S.set(1, 'Labels',
        { ['bonus.no_weapons_fired'] = 'Held fire', ['custody.offence.loitering'] = 'Hanging about' })
    H.ok(ok, 'names for a bonus and an offence')
    H.eq(CP.L('bonus.no_weapons_fired'), 'Held fire', 'CP.L reads the name first')
    H.ok(CP.Locale.has('custody.offence.loitering') and CP.Locale.all()['custody.offence.loitering'] == 'Hanging about',
        'CP.Locale.has and CP.Locale.all() too')
    H.ok(CP.Locale.inFile('custody.offence.loitering') and not CP.Locale.inFile('custody.offence.nope'), 'inFile')
    Err('Labels', { ['ui.screen.home'] = 'Start' }, 'err.setting_label_key', 'only the five kinds of names')
    Err('Labels', { ['bonus.no_weapons_fired'] = '<b>x</b>' }, 'err.setting_label_text', 'no markup')
    Err('Labels', { ['bonus.nope'] = 'Nope' }, 'err.setting_label_unknown', 'an id that does not exist')
    Err('Labels', { ['bonus.no_weapons_fired'] = ('x'):rep(65) }, 'err.setting_too_long', 'at most 64 characters')
    S.reset(1, 'Labels')
    H.ok(CP.L('bonus.no_weapons_fired') ~= 'Held fire', 'reset: the locale\'s name again')
end

_G.print = realPrint
return H
