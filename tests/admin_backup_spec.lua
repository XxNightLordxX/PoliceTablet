-- Full admin control, System → Backups (P5): a backup holds every table and the resource files, keep N never prunes the
-- newest or the latest automatic one, and a restore moves money forward only (paid stays paid, given stays given,
-- money rows made after the backup are kept), keeps the audit log and the money switches, and raises no id twice.

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================

H.boot({ side = 'server', realLocale = true })
if not (CP.Storage and CP.Storage.MemSQL) then H.load('modules/storage/memsql.lua') end

local hooks = {}
_G.GetConvar = function(name, default) return hooks[name] or default end
_G.PerformHttpRequest = function() end
_G.GetResourceMetadata = function(_, key) return key == 'version' and '1.0.0' or nil end

-- resource files stay in memory: the spec never writes into the resource folder
local files = {}
local realLoad = _G.LoadResourceFile
_G.LoadResourceFile = function(res, path)
    if files[path] ~= nil then return files[path] end
    if path:sub(1, 16) == 'missions/custom/' or path:sub(1, 6) == 'logos/' then return nil end
    return realLoad(res, path)
end
_G.SaveResourceFile = function(_, path, data)
    files[path] = data
    return true
end

local people = {
    [1] = {
        cid = 'ADM00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
}
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
end
CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p then return nil end
        return {
            src = src,
            citizenid = p.cid,
            license = p.license,
            name = 'Player ' .. src,
            job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
        }
    end,
    getByCitizenId = function(cid)
        for src, p in pairs(people) do
            if p.cid == cid then return src end
        end
        return nil
    end,
    getOnlinePlayers = function() return { 1, 7 } end,
    getJobs = function() return {} end,
    licenseOf = function() return nil end,
    citizenidsOfLicense = function() return {} end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
local runsNow = {}
CP.Runs = {
    all = function() return runsNow end,
    get = function() return nil end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}

for _, t in ipairs({
    'cp_audit',
    'cp_settings',
    'cp_settings_history',
    'cp_admin_requests',
    'cp_officers',
    'cp_mission_runs',
    'cp_mission_runs_archive',
    'cp_item_rewards',
    'cp_dept_funding',
    'cp_custom_missions',
    'cp_storage_meta',
}) do
    H.sql('DELETE FROM ' .. t)
end

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/sysadmin/server.lua',
}) do
    H.load(m)
end
H.step(0)

local Kit, Maint, S, Sys = CP.AdminKit, CP.Maintenance, CP.Settings, CP.Sysadmin

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'b' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for _ = 1, 2000 do
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then
                return e.args[2], e.args[3]
            end
        end
        H.step(1)
    end
    return nil, 'no reply'
end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 6000
    local r
    CreateThread(function() r = H.callback('crimson-police:' .. name, src, args) end)
    for _ = 1, 2000 do
        if r then break end
        H.step(1)
    end
    if type(r) ~= 'table' then return nil, 'no reply' end
    if r.ok then return r.data end
    return nil, r.error
end

local function Rid(n) return ('%08x-0000-4000-8000-%012x'):format(n, 66) end

local function One(sql, params) return H.sql(sql, params)[1] or {} end
local function Num(v) return math.floor(tonumber(v) or 0) end

local function Run(id, cid, status, paid)
    H.sql(
        [[INSERT INTO cp_mission_runs (id, run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, cash_base, cash_paid, cash_status, breakdown) VALUES (?, ?, 'patrol', 'beat_patrol', ?, 'sast',
        'completed', 'completed', 60, 500, ?, ?, ?)]],
        { id, ('r-%d'):format(id), cid, paid, status, ('{"cash":{"paid":%d}}'):format(paid) })
end

-- ============================================================================
--                               1. A BACKUP NOW
-- ============================================================================

Run(1, 'OFF00007', 'pending', 0)
Run(2, 'OFF00007', 'held', 0)
Run(3, 'OFF00007', 'paid', 500)
H.sql([[INSERT INTO cp_item_rewards (id, row_id, source, source_key, citizenid, item, count, value, status)
    VALUES (1, 1, 'run', 'r-1', 'OFF00007', 'donut', 1, 10, 'pending')]])
H.sql([[INSERT INTO cp_custom_missions (id, mission_type, status, file_path, created_by, updated_by)
    VALUES ('my_mission', 'patrol', 'published', 'missions/custom/my_mission.lua', 'ADM00001', 'ADM00001')]])
files['missions/custom/my_mission.lua'] = 'return { id = "my_mission", version = 1 }'
H.ok(S.set(1, 'Leaderboard.topN', 15), 'a setting changed before the backup')

local first
do
    local ok, res = Act('server:admin:backupNow', 1, {})
    H.ok(ok == true and res and res.name and res.rows >= 5, 'a backup is made: ' .. tostring(res and res.name or res))
    first = res.name
    local list = Cb('admin:getBackups', 1, {})
    H.ok(list and #list.backups == 1 and list.backups[1].name == first, 'it is listed')
    local fh = io.open(GetResourcePath() .. '/saves/_backups/' .. first .. '.manifest.json')
    local manifest = fh and require('cjson').decode(fh:read('a')) or {}
    if fh then fh:close() end
    local paths = {}
    for _, f in ipairs(manifest.files or {}) do paths[f.path] = true end
    H.ok(paths['missions/custom/my_mission.lua'], 'the custom mission file is in it')
    H.ok(manifest.tables and manifest.tables.cp_mission_runs == 3 and manifest.tables.cp_audit ~= nil,
        'every table with its row count')
    local m = Sys._index()[1]
    H.eq(m.kind, 'manual', 'a manual backup')
    local okP, eP = Act('server:admin:backupNow', 1, {})
    H.ok(okP == false and eP == 'err.rate_limited', 'one backup per minute per admin')
    local okO, eO = Act('server:admin:backupNow', 7, {})
    H.ok(okO == false and eO == 'err.no_permission', 'officers can\'t')
end

-- ============================================================================
--                      2. MONEY MOVES ON, THEN A RESTORE
-- ============================================================================

local maxId
do
    -- after the backup: row 1 paid, the reward given, a new paid row, a funding row, audit lines, a money switch on
    H.sql('UPDATE cp_mission_runs SET cash_status = \'paid\', cash_paid = 500, breakdown = ? WHERE id = 1',
        { '{"cash":{"paid":500}}' })
    H.sql('UPDATE cp_item_rewards SET status = \'given\', given_at = NOW() WHERE id = 1')
    Run(4, 'OFF00007', 'paid', 300)
    H.sql([[INSERT INTO cp_dept_funding (department, amount, txn, state, by_actor) VALUES ('sast', 1000, 'CP-FUND-1',
        'done', 'ADM00001')]])
    H.ok(S.set(1, 'Leaderboard.topN', 30), 'the setting changed again')
    H.ok(S.set(1, 'Cash.allowClawback', true, false, { confirm = 'ENABLE' }), 'a money switch turned on')
    files['missions/custom/my_mission.lua'] = 'return { id = "my_mission", version = 2 }'
    local audits = Num(One('SELECT COUNT(*) AS n FROM cp_audit').n)
    maxId = Num(One('SELECT MAX(id) AS m FROM cp_mission_runs').m)

    local pv = Cb('admin:previewRestore', 1, { name = first })
    H.ok(pv and pv.previewToken and pv.moneyRuns >= 3 and pv.moneyItems == 1, 'the preview counts the money rows')
    local kept = {}
    for _, k in ipairs(pv.kept) do kept[k] = true end
    H.ok(kept.cp_audit and kept.cp_settings_history and kept.cp_dept_funding, 'it lists what is kept')

    runsNow = { { participants = {} } }
    local ok, e = Act('server:admin:restoreBackup', 1,
        { name = first, previewToken = pv.previewToken, reason = 'test', confirm = 'RESTORE', requestId = Rid(1) })
    H.ok(ok == false and e == 'err.storage_runs_active', 'refused while a run goes')
    runsNow = {}
    pv = Cb('admin:previewRestore', 1, { name = first })
    ok, e = Act('server:admin:restoreBackup', 1,
        { name = first, previewToken = pv.previewToken, reason = 'test', confirm = 'restor', requestId = Rid(2) })
    H.ok(ok == false and e == 'err.confirm_mismatch', 'the typed word RESTORE')
    ok, e = Act('server:admin:restoreBackup', 1,
        { name = first, reason = 'test', confirm = 'RESTORE', requestId = Rid(3) })
    H.ok(ok == false and e == 'err.preview_missing', 'no preview: refused')
    ok, e = Act('server:admin:restoreBackup', 1,
        { name = first, previewToken = pv.previewToken, reason = 'test', confirm = 'RESTORE', requestId = Rid(4) })
    H.ok(ok == true and e.restart == true, 'restored: ' .. tostring(type(e) == 'table' and e.backup or e))
    H.eq((Maint.active()), 'restore', 'the restore lock holds until the owner restarts')
    H.eq(Maint.view().restart, true, 'and the Admin UI asks for the restart')

    local r1 = One('SELECT cash_status, cash_paid, breakdown FROM cp_mission_runs WHERE id = 1')
    H.ok(r1.cash_status == 'paid' and Num(r1.cash_paid) == 500, 'a row paid after the backup stays paid')
    H.ok(tostring(r1.breakdown):find('500', 1, true) ~= nil, 'with its paid breakdown')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 2').cash_status, 'held', 'a held row is as backed up')
    local r4 = One('SELECT cash_status, cash_paid FROM cp_mission_runs WHERE id = 4')
    H.ok(r4.cash_status == 'paid' and Num(r4.cash_paid) == 300, 'a paid row the backup lacks is kept')
    H.eq(One('SELECT status FROM cp_item_rewards WHERE id = 1').status, 'given', 'a given reward stays given')
    H.eq(Num(One('SELECT COUNT(*) AS n FROM cp_dept_funding').n), 1, 'the funding row made after the backup is kept')
    H.ok(Num(One('SELECT COUNT(*) AS n FROM cp_audit').n) > audits, 'cp_audit keeps every row and gains the restore')
    H.eq(Num(One('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'backupRestored\'').n), 1, 'one restore line')
    local topN = One('SELECT value_json FROM cp_settings WHERE setting_key = \'Leaderboard.topN\'')
    H.ok(tostring(topN.value_json):find('15', 1, true) ~= nil, 'the settings are as backed up')
    local claw = One('SELECT value_json FROM cp_settings WHERE setting_key = \'Cash.allowClawback\'')
    H.ok(tostring(claw.value_json):find('true', 1, true) ~= nil, 'the money switches stay as they are now')
    H.eq(files['missions/custom/my_mission.lua'], 'return { id = "my_mission", version = 1 }',
        'the custom mission file is put back')
    -- no id is handed out twice
    Maint.finish('restore')
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base) VALUES ('new-after', 'patrol', 'beat_patrol', 'OFF00007', 'sast', 'completed', 'completed', 10)]])
    local newId = Num(One('SELECT id FROM cp_mission_runs WHERE run_uuid = \'new-after\'').id)
    H.ok(newId > maxId, ('the next id (%d) is above both sides (%d)'):format(newId, maxId))
    local list = Sys.backups()
    local auto = nil
    for _, b in ipairs(list) do if b.kind == 'prerestore' then auto = b end end
    H.ok(auto ~= nil and auto.protected == true, 'an automatic backup was made first, and it is protected')
end

-- ============================================================================
--                              3. KEEP N, DELETE
-- ============================================================================

do
    Config.Backups = { keep = 3, daily = false }
    for i = 1, 4 do
        H.clockMs = H.clockMs + 61000
        H.time = H.time + 2
        local ok = Act('server:admin:backupNow', 1, {})
        H.ok(ok == true, 'backup ' .. i)
    end
    local list = Sys.backups()
    H.eq(#list, 3, 'keep 3')
    local kinds = {}
    for _, b in ipairs(list) do kinds[b.kind] = (kinds[b.kind] or 0) + 1 end
    H.eq(kinds.prerestore, 1, 'the latest automatic backup is never pruned')
    local newest = list[1].name
    local okD, eD = Act('server:admin:deleteBackup', 1, { name = newest, reason = 'x', confirm = newest })
    H.ok(okD == false and eD == 'err.backup_protected', 'the newest can\'t be deleted')
    local other = list[2].kind == 'prerestore' and list[3] or list[2]
    okD, eD = Act('server:admin:deleteBackup', 1, { name = other.name, confirm = other.name })
    H.ok(okD == false and eD == 'err.reason_required', 'a reason is required')
    okD, eD = Act('server:admin:deleteBackup', 1, { name = other.name, reason = 'old', confirm = 'nope' })
    H.ok(okD == false and eD == 'err.confirm_mismatch', 'the typed backup name')
    okD = Act('server:admin:deleteBackup', 1, { name = other.name, reason = 'old', confirm = other.name })
    H.ok(okD == true and #Sys.backups() == 2, 'deleted')
    H.eq(Num(One('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'backupDeleted\'').n), 1, 'audited')
end

-- ============================================================================
--                   4. THE MONEY STATE OF A FORCED OVERWRITE
-- ============================================================================
-- What a forced storage copy does to the store it replaces: the rows come from elsewhere, the money state stays.

do
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_item_rewards')
    Run(10, 'OFF00007', 'paying', 0)
    Run(11, 'OFF00007', 'paid', 200)
    local snap = Sys.moneySnapshot(MySQL)
    H.eq(#snap.runs, 2, 'paying and paid rows are read by id')
    H.sql('DELETE FROM cp_mission_runs')
    Run(10, 'OFF00007', 'pending', 0)
    local done = Sys.moneyReapply(MySQL, snap)
    H.ok(done.updated == 1 and done.inserted == 1, 'one put back, one brought back whole')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 10').cash_status, 'paying',
        'a paying row never goes back to pending (payPending can\'t pay it again)')
    H.eq(Num(One('SELECT cash_paid FROM cp_mission_runs WHERE id = 11').cash_paid), 200, 'the paid row is back')
end

return H
