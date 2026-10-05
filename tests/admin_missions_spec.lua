-- Full admin control, Missions and Mission Builder (P2): the Builder for admins while it is off, Change owner,

local H = dofile('tests/harness.lua')
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'admin_missions')
local U = CP.U
local cjson = require('cjson')
local function Plain(v) return cjson.decode(cjson.encode(U.serialize(v))) end

Config.Permissions.supervisor = U.copy(Config.Permissions.supervisor)
for _, k in ipairs({ 'builderEdit', 'builderEditAny', 'builderPublish', 'builderArchive', 'builderRollback', 'testRun' }) do
    Config.Permissions.supervisor[k] = true
end
for _, cid in ipairs({ 'AMOFF001', 'AMSUP003', 'AMADM006' }) do
    H.sql('INSERT INTO cp_officers (citizenid, department, display_name) VALUES (?, \'sast\', ?)',
        { cid, 'Officer ' .. cid })
end

-- ============================================================================
--                1. THE BUILDER WHILE IT IS SWITCHED OFF (#37)
-- ============================================================================

do
    Config.Builder.enabled = false
    local _, eS = X.cb('builder:list', 3)
    H.eq(eS, 'err.builder_disabled', 'Builder off: supervisors are refused')
    local list = X.cb('builder:list', 5)
    H.ok(list ~= nil and type(list.builtins) == 'table', 'admins still manage and edit missions')
    Config.Builder.enabled = true
end

-- ============================================================================
--                             2. A CUSTOM MISSION
-- ============================================================================
-- CHANGE OWNER, DELETE, BRING BACK (#35, #36).

local customId
do
    local ok, d = X.act('server:builder:duplicate', 3, { id = 'beat_patrol', label = 'Night Beat' })
    H.eq(ok, true, 'a supervisor duplicates a built-in: ' .. tostring(d))
    customId = type(d) == 'table' and d.id or nil
    local okP, p = X.act('server:builder:publish', 3, { id = customId })
    H.eq(okP, true, 'and publishes it (testing is optional): ' .. tostring(p))
    H.ok(CP.Missions.get(customId) ~= nil and CP.Missions.get(customId).source == 'custom', 'it plays')

    local okO0, eO0 = X.act('server:builder:changeOwner', 5, { id = customId, citizenid = 'AMOFF001' })
    H.ok(not okO0 and eO0 == 'err.reason_required', 'Change owner needs a reason: ' .. tostring(eO0))
    local okO1, eO1 = X.act('server:builder:changeOwner', 5, { id = customId, citizenid = 'NOBODY99', reason = 'x' })
    H.ok(not okO1 and eO1 == 'err.builder_unknown_owner', 'an unknown citizenid is refused')
    local okO, o = X.act('server:builder:changeOwner', 5,
        { id = customId, citizenid = 'AMADM006', reason = 'handover' })
    H.ok(okO and o.owner == 'AMADM006', 'Change owner: ' .. tostring(o))
    H.eq(H.sql('SELECT created_by FROM cp_custom_missions WHERE id = ?', { customId })[1].created_by, 'AMADM006',
        'the row has the new owner')
    H.eq(#X.audits('missionOwner'), 1, 'audited: missionOwner')

    local okD0, eD0 = X.act('server:builder:deleteMission', 5, { id = customId, reason = 'gone', confirm = customId })
    H.ok(not okD0 and eD0 == 'err.builder_not_archived', 'only an archived mission is deleted: ' .. tostring(eD0))
    local okA, eA = X.act('server:builder:archive', 5, { id = customId })
    H.eq(okA, true, 'archived: ' .. tostring(eA))
    local okD1, eD1 = X.act('server:builder:deleteMission', 5, { id = customId, reason = 'gone', confirm = 'wrong' })
    H.ok(not okD1, 'Delete permanently asks for the mission id: ' .. tostring(eD1))
    local okD2, eD2 = X.act('server:builder:deleteMission', 3, { id = customId, reason = 'gone', confirm = customId })
    H.ok(not okD2 and eD2 == 'err.no_permission', 'a supervisor never deletes (missionAdmin)')
    local okD, d2 = X.act('server:builder:deleteMission', 5, { id = customId, reason = 'gone', confirm = customId })
    H.eq(okD, true, 'Delete permanently: ' .. tostring(d2))
    H.eq(X.count('SELECT COUNT(*) AS n FROM cp_custom_missions WHERE id = ?', { customId }), 0, 'the row is gone')
    local folder = type(d2) == 'table' and d2.folder or ''
    H.ok(folder:find(X.exportDir .. 'deleted/', 1, true) == 1 and X.exists(folder .. 'row.json'),
        'its files and row are kept in deleted/<id>-<time>/')
    local deleted = X.cb('builder:deleted', 5)
    H.ok(deleted and #deleted.missions == 1 and deleted.missions[1].id == customId, 'the Deleted list shows it')
    local okU, u = X.act('server:builder:undeleteMission', 5, { folder = folder, reason = 'needed after all' })
    H.eq(okU, true, 'Bring back: ' .. tostring(u))
    local back = H.sql('SELECT status, created_by FROM cp_custom_missions WHERE id = ?', { customId })[1]
    H.ok(back and back.status == 'archived' and back.created_by == 'AMADM006', 'back as archived, owner kept')
    H.eq(#X.cb('builder:deleted', 5).missions, 0, 'and off the Deleted list')
    local okR, eR = X.act('server:builder:restore', 5, { id = customId })
    H.eq(okR, true, 'and restored to play again: ' .. tostring(eR))
end

-- ============================================================================
--             3. LOAD SAVED DRAFT, COPY AS LUA, IMPORT (#34, C13)
-- ============================================================================

do
    local rec = X.cb('builder:get', 5, { id = customId })
    local def = Plain(rec.definition)
    def.label = 'Night Beat (recovered)'
    local lua = CP.Builder.exportLua(def, { version = 9 })
    X.write(X.exportDir .. customId .. '.draft.lua.bak', lua)
    local rec2 = X.cb('builder:get', 5, { id = customId })
    H.eq(rec2 and rec2.draftBackup, true, 'the Builder sees a saved draft')
    local okL, l = X.act('server:builder:loadBackupDraft', 5, { id = customId })
    H.eq(okL, true, 'Load saved draft: ' .. tostring(l))
    H.eq(X.cb('builder:get', 5, { id = customId }).definition.label, 'Night Beat (recovered)', 'the draft is back')
    H.eq(#X.audits('draftRecovered'), 1, 'audited: draftRecovered')
    X.act('server:builder:discardDraft', 5, { id = customId })

    local exp, eE = X.cb('admin:exportMissionLua', 5, { id = customId })
    H.ok(exp and type(exp.lua) == 'string' and exp.lua:find(customId, 1, true) ~= nil, 'Copy as Lua: ' .. tostring(eE))
    local _, eB = X.cb('admin:exportMissionLua', 5, { id = 'beat_patrol' })
    H.eq(eB, 'err.export_builtin', 'a built-in is copied only through its override')
    local _, eS = X.cb('admin:exportMissionLua', 3, { id = customId })
    H.eq(eS, 'err.no_permission', 'supervisors can\'t copy (missionAdmin)')

    local text = exp.lua:gsub('RegisterMission%(%{', 'RegisterMission({\n  payout = 50000,', 1)
    local pv, eP = X.cb('admin:previewImport', 5, { lua = text })
    H.ok(pv and pv.previewToken and pv.effect, 'Import preview: ' .. tostring(eP))
    local dropped = table.concat(pv and pv.effect.dropped or {}, ',')
    H.ok(dropped:find('payout', 1, true) ~= nil, 'the payout field is dropped and listed: ' .. dropped)
    local _, eBig = X.cb('admin:previewImport', 5, { lua = string.rep('-', 262145) })
    H.eq(eBig, 'err.import_too_large', 'more than 256 KB is refused')
    -- pasted text that would freeze or fill the server stops with an error instead
    local hostile = {
        { 'while true do end', 'a loop that never ends' },
        { 'local s = string.rep("x", 2^31)', 'string.rep of 2 GB' },
        { 'local s = ("x"):rep(2^31)', 'the same as a string method' },
        { 'local s = "x" for i = 1, 40 do s = s .. s end', 'a string doubled until memory runs out' },
        { 'local t = {} for i = 1, 1e9 do t[i] = i end', 'a table filled until memory runs out' },
        { 'local n = ("a"):rep(30000):find(".-.-.-.-.-.-.-.-.-.-b")', 'pattern matching (runs inside C)' },
    }
    for _, h in ipairs(hostile) do
        H.advance(11000)
        local t0 = os.clock()
        local pvH, eH = X.cb('admin:previewImport', 5, { lua = h[1] .. '\nRegisterMission({ id = "x" })' })
        H.ok(pvH == nil and eH == 'err.import_parse' and os.clock() - t0 < 10,
            ('refused, not run forever: %s (%s, %.1f s)'):format(h[2], tostring(eH), os.clock() - t0))
    end
    H.eq(('abc'):find('b', 1, true), 2, 'string functions work again after the import')
    H.eq(string.rep('ab', 3), 'ababab', 'and string.rep too')
    H.eq(debug.gethook(), nil, 'no budget hook is left behind')
    local okI, i = X.act('server:builder:importDraft', 5,
        { previewToken = pv.previewToken, reason = 'from the test server' })
    H.eq(okI, true, 'Import as a draft: ' .. tostring(i))
    local newId = type(i) == 'table' and i.id or nil
    H.ok(newId and newId ~= customId, 'a used id gets a new one: ' .. tostring(newId))
    local row = H.sql('SELECT status, published_version FROM cp_custom_missions WHERE id = ?', { newId })[1]
    H.ok(row and row.status == 'draft' and row.published_version == nil, 'only a draft: the import never publishes')
    H.ok(CP.Missions.get(newId) == nil, 'and nothing new plays')
    local okI2, eI2 = X.act('server:builder:importDraft', 5, { previewToken = pv.previewToken, reason = 'again' })
    H.ok(not okI2, 'a preview token is used once: ' .. tostring(eI2))
end

-- ============================================================================
--                               4. MARK CHECKED
-- ============================================================================
-- (NOT PLAYED), REMOVE A TEST RESULT (#45, C20).

local function LocStatus(missionId, index)
    local list = CP.Testing.list()
    for _, m in ipairs(list and list.missions or {}) do
        if m.id == missionId then
            for _, l in ipairs(m.locations or {}) do if l.index == index then return l end end
        end
    end
    return nil
end

do
    local ok0, e0 = X.act('server:admin:markLocationChecked', 5, { missionId = 'beat_patrol', locationIndex = 1 })
    H.ok(not ok0 and e0 == 'err.reason_required', 'Mark checked needs a reason: ' .. tostring(e0))
    local okS, eS = X.act('server:admin:markLocationChecked', 3,
        { missionId = 'beat_patrol', locationIndex = 1, reason = 'looked at it' })
    H.ok(not okS, 'a supervisor can\'t mark checked: ' .. tostring(eS))
    local okM, m = X.act('server:admin:markLocationChecked', 5,
        { missionId = 'beat_patrol', locationIndex = 1, reason = 'walked it, fine' })
    H.eq(okM, true, 'Mark checked (not played): ' .. tostring(m))
    local loc = LocStatus('beat_patrol', 1)
    H.ok(loc and loc.status == 'checked' and type(loc.last) == 'table' and loc.last.unplayed == true,
        'its own badge: checked')
    H.eq(#X.audits('testMarkChecked'), 1, 'audited: testMarkChecked')

    local resultId = type(m) == 'table' and m.id
    local okH, h = X.act('server:admin:hideTestResult', 5, { id = resultId, hidden = true, reason = 'wrong result' })
    H.ok(okH and h.hidden == true, 'Remove result: ' .. tostring(h))
    loc = LocStatus('beat_patrol', 1)
    H.ok(loc and loc.status ~= 'checked' and (type(loc.last) ~= 'table' or loc.last.unplayed ~= true),
        'a removed result counts for nothing')
    local hist = X.cb('admin:getTestHistory', 5, { missionId = 'beat_patrol', locationIndex = 1 })
    H.ok(hist and #hist.results == 1 and hist.results[1].hidden == true, 'the history still lists it (hidden)')
    local okSh = X.act('server:admin:hideTestResult', 5, { id = resultId, hidden = false, reason = 'it was right' })
    H.ok(okSh and LocStatus('beat_patrol', 1).status == 'checked', 'Show again')
    H.eq(#X.audits('testResultHide'), 2, 'audited twice: testResultHide')
    local list = CP.Testing.list()
    local m0 = list and list.missions and list.missions[1]
    H.ok(m0 and m0.switch ~= nil, 'Testing rows carry the mission and location switches')
end

-- ============================================================================
--           5. THE LOAD RESULT AND THE 'missions' CONFIG HEALTH LINE
-- ============================================================================
-- C4.

do
    local sum = X.cb('admin:getMissionLoad', 5)
    H.ok(sum and sum.loaded > 0 and sum.builtin > 0 and type(sum.failed) == 'table' and sum.at,
        'admin:getMissionLoad returns the last load')
    local _, eS = X.cb('admin:getMissionLoad', 3)
    H.eq(eS, 'err.no_permission', 'admins only')
    -- a hand edit that breaks a custom mission file: the old version keeps playing, the load result names it
    local path = X.exportDir .. customId .. '.lua'
    X.write(path, 'RegisterMission({ id = "' .. customId .. '", label = ')
    CP.Missions.reload()
    sum = X.cb('admin:getMissionLoad', 5)
    local named = false
    for _, f in ipairs(sum and sum.failed or {}) do if f.id == customId then named = true end end
    for _, r in ipairs(sum and sum.builder and sum.builder.rejected or {}) do
        if r.id == customId then named = true end
    end
    H.ok(named, 'the broken file is in the load result')
    local lines = CP.Missions._health()
    local bad = false
    for _, l in ipairs(lines) do
        if (l.level == 'warn' or l.level == 'error') and l.text:find(customId, 1, true) then bad = true end
    end
    H.ok(bad, 'and in the missions health line')
    local okA = X.act('server:builder:archive', 5, { id = customId })
    H.ok(okA, 'archived again')
end

-- ============================================================================
--           6. QUICK EDIT, checkTweak, THE SETTINGS TRIAL, THE REMAP
-- ============================================================================
-- #30, #31, A14, O3.

do
    local view = X.cb('admin:getMissionTweak', 5, { missionId = 'gang_shootout' })
    H.ok(view and view.file.cooldown == 1200 and view.live.cooldown == 1200,
        'Quick edit shows the file and live values')
    H.ok(view and U.contains(view.allowed.weapons, 'WEAPON_MICROSMG'), 'the pickers offer the mission\'s own weapons')
    local okW, eW = X.act('server:admin:setMissionTweak', 5,
        { missionId = 'gang_shootout', tweak = { weapons = { 'WEAPON_RAILGUN' } } })
    H.ok(not okW and eW == 'err.tweak_name_not_allowed', 'a weapon nobody allowed is refused: ' .. tostring(eW))
    local okC, eC = X.act('server:admin:setMissionTweak', 5, { missionId = customId, tweak = { cooldown = 600 } })
    H.ok(not okC, 'Quick edit is for built-ins: ' .. tostring(eC))
    local okT, t = X.act('server:admin:setMissionTweak', 5,
        { missionId = 'gang_shootout', tweak = { cooldown = 600, timeLimit = 900 }, reason = 'shorter wait' })
    H.eq(okT, true, 'Quick edit saves through Settings: ' .. tostring(t))
    X.adv(2000)
    H.ok(CP.Missions.get('gang_shootout').cooldown == 600 and CP.Missions.get('gang_shootout').timeLimit == 900,
        'the live mission has the new values')
    H.ok(#X.audits('settingChanged') >= 1 or #H.sql('SELECT id FROM cp_settings_history') >= 1,
        'audited as a settings change')
    local okR, r = X.act('server:admin:setMissionTweak', 5, { missionId = 'gang_shootout' })
    H.eq(okR, true, 'Reset (back to the file): ' .. tostring(r))
    X.adv(2000)
    H.eq(CP.Missions.get('gang_shootout').cooldown, 1200, 'the file value again')

    local okK, eK = CP.Missions.checkTweak('gang_shootout', { timeLimit = 900 })
    H.ok(okK == true, 'checkTweak accepts a sound tweak: ' .. tostring(eK))
    local okK2 = CP.Missions.checkTweak('gang_shootout', { objectives = { [9] = { label = 'x' } } })
    H.ok(okK2 == false or okK2 == true, 'checkTweak answers without changing anything')
    H.eq(CP.Missions.get('gang_shootout').cooldown, 1200, 'and the live mission is untouched')

    local trial, eT = X.cb('admin:trialMissions', 5, { patch = { { path = 'Builder.maxHostiles', value = 40 } } })
    H.ok(trial and trial.checked > 0 and type(trial.failed) == 'table',
        'the settings trial loads every mission: ' .. tostring(eT))
    local _, eT2 = X.cb('admin:trialMissions', 5, { patch = { { path = 'Builder.maxHostiles', value = 'lots' } } })
    H.ok(eT2 ~= nil, 'a value Settings refuses is refused by the trial too: ' .. tostring(eT2))
    H.eq(Config.Builder.maxHostiles, 40, 'the trial puts Config back')

    Config.DisabledLocations = U.deepcopy(Config.DisabledLocations or {})
    Config.DisabledLocations.gang_shootout = { 'A location that was renamed' }
    local remap = X.cb('admin:getSwitchRemap', 5)
    local entry
    for _, m in ipairs(remap and remap.missions or {}) do if m.id == 'gang_shootout' then entry = m end end
    H.ok(entry and entry.stale[1] == 'A location that was renamed', 'n switches no longer match: listed')
    local okM, mm = X.act('server:admin:remapLocationSwitches', 5,
        { missionId = 'gang_shootout', map = { { from = 'A location that was renamed', to = 2 } } })
    H.eq(okM, true, 'Remap: ' .. tostring(mm))
    local list = Config.DisabledLocations.gang_shootout or {}
    H.ok(#list == 1 and list[1] ~= 'A location that was renamed', 'the switch now names location 2')
end

-- ============================================================================
--            7. OPERATION AND DISPATCH HISTORY, STATS (C6, C7, C8)
-- ============================================================================

do
    H.sql([[INSERT INTO cp_operations (id, mission_id, launched_by, status, created_at, ended_at)
        VALUES (41, 'prison_break', 'AMSUP003', 'completed', FROM_UNIXTIME(?), FROM_UNIXTIME(?))]],
        { os.time() - 2 * 86400, os.time() - 2 * 86400 })
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, operation_id, mission_type, mission_id, citizenid, department, state,
        end_reason, points_base, final_points, created_at) VALUES ('op41-a', 41, 'tactical', 'prison_break', 'AMOFF001', 'sast',
        'completed', 'completed', 100, 120, FROM_UNIXTIME(?))]], { os.time() - 2 * 86400 })
    H.sql(
        [[INSERT INTO cp_mission_runs_archive (run_uuid, operation_id, mission_type, mission_id, citizenid, department,
        state, end_reason, points_base, final_points, created_at) VALUES ('op41-b', 41, 'tactical', 'prison_break', 'AMSUP003', 'sast',
        'completed', 'completed', 100, 80, FROM_UNIXTIME(?))]], { os.time() - 2 * 86400 })
    local ops, eO = X.cb('admin:getOperations', 5, {})
    local op = ops and ops.rows and ops.rows[1]
    H.ok(op and op.id == 41 and #op.participants == 2 and op.points == 200,
        'operation history: participants and points from live and archived rows: ' .. tostring(eO))
    local none = X.cb('admin:getOperations', 5, { status = 'cancelled' })
    H.ok(none and #none.rows == 0, 'filtered by status')
    local _, eS = X.cb('admin:getOperations', 3, {})
    H.eq(eS, 'err.no_permission', 'admins only')

    -- no calls of the server's own while the spec counts them
    Config.MissionCalls.enabled = false
    H.sql('DELETE FROM cp_mission_calls')
    for i = 1, 30 do
        H.sql(
            [[INSERT INTO cp_mission_calls (code, mission_type, area, status, outcome, created_by, claimed_by, created_at,
            claimed_at) VALUES (?, ?, NULL, ?, ?, ?, ?, FROM_UNIXTIME(?), FROM_UNIXTIME(?))]], {
                ('MC-%04d'):format(i),
                i % 2 == 0 and 'patrol' or 'traffic',
                'closed',
                i % 3 == 0 and 'failed' or 'completed',
                i % 5 == 0 and 'AMSUP003' or nil,
                'AMOFF001',
                os.time() - i * 600,
                os.time() - i * 600 + 120,
            })
    end
    -- the window ends before now: calls the server posts by itself while the spec runs stay out
    local to = os.time() - 60
    local calls = X.cb('admin:getMissionCalls', 5, { to = to })
    H.ok(calls and calls.total == 30 and #calls.rows == 25 and calls.pages == 2, 'dispatch history pages by 25')
    H.eq(calls and calls.rows[1].claimSeconds, 120, 'response time in seconds')
    local p2 = X.cb('admin:getMissionCalls', 5, { page = 2, to = to })
    H.eq(p2 and #p2.rows, 5, 'page 2')
    local pat = X.cb('admin:getMissionCalls', 5, { type = 'patrol', to = to })
    H.eq(pat and pat.total, 15, 'filtered by type')
    local staff = X.cb('admin:getMissionCalls', 5, { issuer = 'AMSUP003', to = to })
    H.eq(staff and staff.total, 6, 'filtered by issuer')
    local srv = X.cb('admin:getMissionCalls', 5, { issuer = 'server', to = to })
    H.eq(srv and srv.total, 24, 'posted by the server')
    local failed = X.cb('admin:getMissionCalls', 5, { outcome = 'failed', to = to })
    H.eq(failed and failed.total, 10, 'filtered by outcome')

    -- stats over live + archive: 3 completed, 1 failed, 1 abandoned of one mission (1 voided, 1 flagged)
    local rows = {
        { 'completed', 300, 100, 500, 0, 0, 'cp_mission_runs' },
        { 'completed', 400, 120, 600, 1, 0, 'cp_mission_runs' },
        { 'completed', 500, 140, 700, 0, 1, 'cp_mission_runs_archive' },
        { 'failed', 200, 0, 0, 0, 0, 'cp_mission_runs' },
        { 'abandoned', 100, 0, 0, 0, 0, 'cp_mission_runs_archive' },
    }
    for i, r in ipairs(rows) do
        H.sql(
            ([[INSERT INTO %s (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
            duration_s, points_base, final_points, cash_paid, flagged, voided, created_at) VALUES (?, 'tactical',
            'drug_lab_raid', 'AMOFF001', 'sast', ?, ?, ?, 100, ?, ?, ?, ?, FROM_UNIXTIME(?))]]):format(r[7]),
            { 'st-' .. i, r[1], r[1], r[2], r[3], r[4], r[5], r[6], os.time() - 86400 }
        )
    end
    local stats = X.cb('admin:getMissionStats', 5, { missionId = 'drug_lab_raid' })
    local s = stats and stats.missions and stats.missions[1]
    H.ok(s and s.runs == 5 and s.completed == 3 and s.failed == 1 and s.abandoned == 1, 'stats count every row')
    H.ok(s and s.completionRate == 60 and s.failRate == 20 and s.abandonRate == 20, 'rates computed in Lua')
    H.ok(s and s.avgDuration == 300 and s.avgPoints == 72 and s.avgCash == 360, 'averages computed in Lua')
    H.ok(s and s.flags == 1 and s.voids == 1, 'flags and voids')
    local _, eR = X.cb('admin:getMissionStats', 5, { from = 100, to = 50 })
    H.ok(eR == 'err.invalid_range' or eR == 'err.rate_limited', 'a backwards range is refused')
end

-- ============================================================================
--            8. POST ANYWAY, LAUNCH DURING THE COOLDOWN (C20, A13)
-- ============================================================================

do
    Config.MissionCalls.enabled = true
    local ok1, c1 = X.act('server:admin:mcCreate', 5, { type = 'patrol', to = to })
    H.eq(ok1, true, 'an admin posts a mission call: ' .. tostring(c1))
    local ok2, e2 = X.act('server:admin:mcCreate', 5, { type = 'patrol', to = to })
    H.ok(not ok2 and e2 == 'err.mc_staff_cooldown', 'the wait between staff calls applies: ' .. tostring(e2))
    local ok3, e3 = X.act('server:admin:mcCreate', 5, { type = 'patrol', skipWait = true })
    H.ok(not ok3, 'Post anyway needs a reason: ' .. tostring(e3))
    local ok4, c4 = X.act('server:admin:mcCreate', 5, { type = 'patrol', skipWait = true, reason = 'shift change' })
    H.eq(ok4, true, 'Post anyway: ' .. tostring(c4))
    H.eq(#X.audits('mcCreateSkipWait'), 1, 'audited: mcCreateSkipWait')
    if Config.Permissions.supervisor then Config.Permissions.supervisor.missionCalls = true end
    X.act('server:sup:mcCreate', 3, { type = 'patrol', to = to })
    local ok5, e5 = X.act('server:sup:mcCreate', 3, { type = 'patrol', skipWait = true, reason = 'me too' })
    H.ok(not ok5, 'a supervisor still waits: ' .. tostring(e5))

    CP.Operations._setLastLaunch(os.time())
    H.ok(CP.Operations.cooldownLeft() > 0, 'the Cross-Department cooldown is running')
    local okL, eL = X.act('server:admin:opLaunch', 5, { missionId = 'prison_break' })
    H.ok(not okL and eL == 'err.op_cooldown', 'a normal launch waits for it: ' .. tostring(eL))
    local okL2, eL2 = X.act('server:admin:opLaunch', 5, { missionId = 'prison_break', skipCooldown = true })
    H.ok(not okL2, 'Launch anyway needs a reason: ' .. tostring(eL2))
    local okL3, eL3 = X.act('server:sup:opLaunch', 3, { missionId = 'prison_break', skipCooldown = true, reason = 'x' })
    H.ok(not okL3, 'a supervisor can\'t skip the cooldown: ' .. tostring(eL3))
end

-- ============================================================================
--                         9. THE MAINTENANCE LOCK (S2)
-- ============================================================================

do
    CP.Maintenance.begin('storage', { by = 'console' })
    local _, eA = CP.Draw.check(1, 'patrol')
    H.eq(eA, 'err.maintenance', 'no new runs: the accept refuses at its own check')
    local okC, eC = CP.MissionCalls.claim(1, 1)
    H.ok(not okC and eC == 'err.maintenance', 'no mission call claims: ' .. tostring(eC))
    local okT, eT = CP.Testing.start(5, { missionId = 'beat_patrol' })
    H.ok(not okT and eT == 'err.maintenance', 'no test runs: ' .. tostring(eT))
    local okO, eO = CP.Operations.launch(5, 'prison_break')
    H.ok(not okO and eO == 'err.maintenance', 'no operation launches: ' .. tostring(eO))
    CP.Maintenance.finish('storage')
    local _, eA2 = CP.Draw.check(1, 'patrol')
    H.ok(eA2 ~= 'err.maintenance', 'lock ended: accepts check normally again')
end

X.cleanup()
return H
