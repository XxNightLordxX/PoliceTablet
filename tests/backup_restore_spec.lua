-- Backup restore: money and voids only move forward, the oldest backup of a full list restores, a damaged backup
-- changes nothing, and a restore that stops part way keeps payments held, also after a restart, until a restore works
-- (details: docs/FILE_NOTES.md).

local H = dofile('tests/harness.lua')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================

local files = {}      -- resource files stay in memory: the spec never writes into the resource folder
local paidLog = {}    -- every bank payment CP.Cash makes
local lines = {}      -- console lines
local runsNow = {}
local people = {
    [1] = {
        cid = 'ADM00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
    [8] = { cid = 'NEW00007', license = 'license:8888888888888888888888888888888888888888', job = 'sast', grade = 0 },
}

-- One start of Crimson-Police (again after H.restart: the database or saves folder is kept).
-- before(): runs after config.lua loads and before the modules do.
local function Boot(before)
    H.boot({ side = 'server', realLocale = true })
    if not (CP.Storage and CP.Storage.MemSQL) then H.load('modules/storage/memsql.lua') end
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    _G.GetResourceMetadata = function(_, key) return key == 'version' and '1.0.0' or nil end
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
        getOnlinePlayers = function() return { 1, 7, 8 } end,
        getJobs = function() return {} end,
        licenseOf = function() return nil end,
        citizenidsOfLicense = function() return {} end,
        onDutyChange = function() end,
        onGroupUpdate = function() end,
        onJobChange = function() end,
        onPlayerLoaded = function() end,
        onPlayerUnload = function() end,
        addMoney = function(src, _, amount)
            paidLog[#paidLog + 1] = { src = src, amount = amount }
            return true
        end,
    }
    CP.Runs = {
        all = function() return runsNow end,
        get = function() return nil end,
    }
    CP.Missions = {
        reload = function() end,
        get = function() return nil end,
    }
    local realErr = CP.err
    CP.err = function(tag, fmt, ...)
        lines[#lines + 1] = tostring(fmt):format(...)
        return realErr(tag, fmt, ...)
    end
    if before then before() end
    for _, m in ipairs({
        'modules/permissions/server.lua',
        'modules/access/server.lua',
        'modules/admin/server.lua',
        'modules/adminkit/server.lua',
        'modules/settings/server.lua',
        'modules/tablet/server.lua',
        'modules/sysadmin/server.lua',
        'modules/cash/server.lua',
    }) do
        H.load(m)
    end
    H.step(0)
    H.advance(20000) -- the cash module's start-up sweep (pending rows of the officers online)
end

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
    'cp_seasons',
}) do
    H.sql('DELETE FROM ' .. t)
end
Boot()

local function Printed(text)
    for _, l in ipairs(lines) do
        if l:find(text, 1, true) then return true end
    end
    return false
end

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'x' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for _ = 1, 4000 do
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
    for _ = 1, 4000 do
        if r then break end
        H.step(1)
    end
    if type(r) ~= 'table' then return nil, 'no reply' end
    if r.ok then return r.data end
    return nil, r.error
end

local rid = 0
local function Rid()
    rid = rid + 1
    return ('%08x-0000-4000-8000-%012x'):format(rid, 77)
end

local function One(sql, params) return H.sql(sql, params)[1] or {} end
local function Num(v) return math.floor(tonumber(v) or 0) end

local function RunX(id, uuid, cid, status, paid, extra)
    extra = extra or {}
    H.sql(
        [[INSERT INTO cp_mission_runs (id, run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, cash_base, cash_paid, cash_status, breakdown, voided, void_kind, flagged) VALUES (?, ?, 'patrol',
        'beat_patrol', ?, 'sast', 'completed', 'completed', 60, 500, ?, ?, ?, ?, ?, 0)]], {
            id,
            uuid,
            cid,
            paid,
            status,
            ('{"cash":{"paid":%d}}'):format(paid),
            extra.voided or 0,
            extra.voidKind or 'admin',
        })
end

local function Item(id, cid, key, status)
    H.sql([[INSERT INTO cp_item_rewards (id, row_id, source, source_key, citizenid, item, count, value, status)
        VALUES (?, NULL, 'run', ?, ?, 'donut', 1, 10, ?)]], { id, key, cid, status })
end

local function Paid(id)
    H.sql('UPDATE cp_mission_runs SET cash_status = \'paid\', cash_paid = 500, breakdown = ? WHERE id = ?',
        { '{"cash":{"paid":500}}', id })
end

-- What happens to the officers' pay from now on: each one logs in (payPending), as after a restart.
local function PayAll()
    local before = #paidLog
    for _, src in ipairs({ 7, 8 }) do
        local done = false
        CreateThread(function()
            CP.Cash.payPending(src)
            done = true
        end)
        for _ = 1, 4000 do
            if done then break end
            H.step(1)
        end
    end
    H.step(6000)
    return #paidLog - before
end

local function Clear()
    for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive', 'cp_item_rewards', 'cp_seasons' }) do
        H.sql('DELETE FROM ' .. t)
    end
end

local function Tick()
    H.time = H.time + 5
    H.clockMs = H.clockMs + 61000
end

local function Backup()
    Tick()
    local ok, res = CP.Sysadmin.backup(1, 'manual')
    H.ok(ok == true, 'backup made: ' .. tostring(type(res) == 'table' and res.name or res))
    return type(res) == 'table' and res.name or nil
end

-- The admin's Restore (preview, then RESTORE): ok, result | false, errKey.
local function Restore(name)
    Tick()
    local pv, pe = Cb('admin:previewRestore', 1, { name = name })
    if not pv then return false, pe end
    return Act('server:admin:restoreBackup', 1,
        { name = name, previewToken = pv.previewToken, reason = 'x4 case', confirm = 'RESTORE', requestId = Rid() })
end

-- The owner restarts Crimson-Police after a restore that worked: the lock ends and payments go on.
local function OwnerRestart()
    CP.Maintenance.finish('restore')
    H.step(6000)
end

-- A real restart: the Lua lock is gone, the store is kept.
local function Restart(before)
    H.restart()
    Boot(before)
end

-- The bank payments made by fn() and then by the officers logging in (the sweep after a lock ends counts too).
local function PaymentsAfter(fn)
    local before = #paidLog
    fn()
    PayAll()
    return #paidLog - before
end

local function PartPath(name, tname)
    return GetResourcePath() .. '/saves/_backups/' .. name .. '.t.' .. tname .. '.json'
end

local function EditPart(name, tname, fn)
    local fh = io.open(PartPath(name, tname), 'rb')
    local rows = require('cjson').decode(fh:read('a'))
    fh:close()
    for _, r in ipairs(rows) do fn(r) end
    fh = io.open(PartPath(name, tname), 'wb')
    fh:write(require('cjson').encode(rows))
    fh:close()
end

-- The automatic backup of a restore that has not finished, as cp_storage_meta keeps it.
local function OpenMark()
    return One('SELECT meta_value FROM cp_storage_meta WHERE meta_key = \'restore_open\'').meta_value
end

local function Listed(name)
    for _, b in ipairs(CP.Sysadmin._index()) do
        if b.name == name then return true end
    end
    return false
end

local function LatestAuto()
    local auto = nil
    for _, b in ipairs(CP.Sysadmin._index()) do if b.kind == 'prerestore' then auto = b.name end end
    return auto
end

-- MySQL fails on the statements fail(sql) names (a database or disk error part way): restored by the returned fn.
local function Breaking(fail)
    local realUpdate, realQuery = MySQL.update.await, MySQL.query.await
    MySQL.update.await = function(sql, params)
        if fail(sql) then error('disk full (test): ' .. sql, 0) end
        return realUpdate(sql, params)
    end
    MySQL.query.await = function(sql, params)
        if fail(sql) then error('disk full (test): ' .. sql, 0) end
        return realQuery(sql, params)
    end
    return function() MySQL.update.await, MySQL.query.await = realUpdate, realQuery end
end

Config.Backups = { keep = 20, daily = false, holdAfterFailedRestore = true }

-- ============================================================================
--                     1. VOIDS MADE SINCE THE BACKUP (F15)
-- ============================================================================

do
    -- voided after the backup (still pending until the dispute window closes): stays voided, never paid
    Clear()
    RunX(100, 'v-100', 'OFF00007', 'pending', 0)
    local b = Backup()
    H.sql('UPDATE cp_mission_runs SET voided = 1, void_kind = \'bulk\', void_batch = \'batch-1\' WHERE id = 100')
    local ok, e = Restore(b)
    H.ok(ok == true, 'restored: ' .. tostring(type(e) == 'table' and e.backup or e))
    local r = One('SELECT cash_status, voided, void_kind, void_batch FROM cp_mission_runs WHERE id = 100')
    H.ok(Num(H.bit(r.voided)) == 1 and r.void_kind == 'bulk' and r.void_batch == 'batch-1',
        'a run voided after the backup stays voided, with its void kind and batch')
    H.eq(PaymentsAfter(OwnerRestart), 0, 'and it is not paid after the restart')

    -- un-voided after the backup (Restore run): stays owed, and the officer is paid
    Clear()
    RunX(110, 'v-110', 'OFF00007', 'pending', 0, { voided = 1 })
    b = Backup()
    H.sql('UPDATE cp_mission_runs SET voided = 0, void_kind = NULL WHERE id = 110')
    ok = Restore(b)
    H.ok(ok == true, 'restored')
    r = One('SELECT cash_status, voided, void_kind FROM cp_mission_runs WHERE id = 110')
    H.ok(Num(H.bit(r.voided)) == 0 and r.void_kind == nil,
        'a run brought back after the backup stays owed (not voided again)')
    H.eq(PaymentsAfter(OwnerRestart), 1, 'and the officer gets the pay the live store owed')

    -- flagged after the backup: stays held for review
    Clear()
    RunX(115, 'v-115', 'OFF00007', 'pending', 0)
    b = Backup()
    H.sql('UPDATE cp_mission_runs SET flagged = 1, flag_reason = \'too_fast\', cash_status = \'held\' WHERE id = 115')
    ok = Restore(b)
    r = One('SELECT cash_status, flagged, flag_reason FROM cp_mission_runs WHERE id = 115')
    H.ok(ok == true and r.cash_status == 'held' and Num(H.bit(r.flagged)) == 1 and r.flag_reason == 'too_fast',
        'a run flagged after the backup stays flagged and held')
    H.eq(PaymentsAfter(OwnerRestart), 0, 'and it is not paid')
end

-- ============================================================================
--                   2. A RECORD MOVED SINCE THE BACKUP (F14)
-- ============================================================================

do
    Clear()
    RunX(120, 'm-120', 'OFF00007', 'pending', 0)
    Item(120, 'OFF00007', 'm-120', 'pending')
    local b = Backup()
    -- Officers -> Move record OFF00007 -> NEW00007, then the new character is paid and given the reward
    H.sql('UPDATE cp_mission_runs SET citizenid = \'NEW00007\' WHERE id = 120')
    H.sql('UPDATE cp_item_rewards SET citizenid = \'NEW00007\' WHERE id = 120')
    Paid(120)
    H.sql('UPDATE cp_item_rewards SET status = \'given\', given_at = NOW() WHERE id = 120')
    local ok = Restore(b)
    H.ok(ok == true, 'restored')
    local rows = H.sql('SELECT id, citizenid, cash_status FROM cp_mission_runs WHERE run_uuid = \'m-120\'')
    H.ok(#rows == 1 and rows[1].citizenid == 'NEW00007' and rows[1].cash_status == 'paid',
        'one row for the run, the new character\'s, paid')
    local items = H.sql('SELECT citizenid, status FROM cp_item_rewards WHERE source_key = \'m-120\'')
    H.ok(#items == 1 and items[1].citizenid == 'NEW00007' and items[1].status == 'given',
        'one reward, the new character\'s, given')
    H.eq(PaymentsAfter(OwnerRestart), 0, 'the old character logging in is not paid the run again')

    -- a backup from a store that handed the same ids out again: another run under id 130 is not the same run
    Clear()
    RunX(130, 'x-130', 'OFF00007', 'paid', 500)
    b = Backup()
    Clear()
    RunX(130, 'y-130', 'NEW00007', 'pending', 0)
    ok = Restore(b)
    local x = One('SELECT cash_status FROM cp_mission_runs WHERE run_uuid = \'x-130\'')
    local y = H.sql('SELECT id, cash_status FROM cp_mission_runs WHERE run_uuid = \'y-130\'')
    H.ok(ok == true and x.cash_status == 'paid' and #y == 1 and y[1].cash_status == 'pending' and Num(y[1].id) ~= 130,
        'the backup\'s paid run stays paid, the live owed run is kept once under a new id')
    OwnerRestart()
end

-- ============================================================================
--                  3. THE OLDEST BACKUP OF A FULL LIST (F13)
-- ============================================================================

do
    Clear()
    -- a fresh list (the files of the earlier cases removed by hand)
    H.execute(('rm -f \'%s\'/*'):format(GetResourcePath() .. '/saves/_backups'))
    Config.Backups.keep = 3
    RunX(160, 'k-160', 'OFF00007', 'pending', 0)
    local oldest = Backup()
    Backup()
    Backup()
    H.eq(#CP.Sysadmin._index(), 3, 'three backups listed, keep = 3')
    Paid(160)
    local ok, e = Restore(oldest)
    H.ok(ok == true, 'restoring the oldest of a full list works: ' .. tostring(type(e) == 'table' and e.backup or e))
    H.ok(Listed(oldest), 'and the backup restored is still listed (keep N removed the next one)')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 160').cash_status, 'paid', 'paid since: stays paid')
    OwnerRestart()
    Config.Backups.keep = 20
end

-- ============================================================================
--                     4. A DAMAGED BACKUP, AN OLDER BACKUP
-- ============================================================================
-- F12: before anything changes.

do
    Clear()
    RunX(170, 'd-170', 'OFF00007', 'pending', 0)
    local b = Backup()
    Paid(170)
    local before = #CP.Sysadmin._index()
    local fh = io.open(PartPath(b, 'cp_staff_notices'), 'wb')
    fh:write('{ damaged')
    fh:close()
    local pv, pe = Cb('admin:previewRestore', 1, { name = b })
    H.ok(pv == nil and pe == 'err.backup_damaged', 'the preview refuses a damaged backup: ' .. tostring(pe))
    Tick()
    local ok, e = CP.Sysadmin.restore(1, b, 'x4 case')
    H.ok(ok == false and e == 'err.backup_damaged', 'and so does the restore: ' .. tostring(e))
    H.eq(CP.Maintenance.active(), nil, 'no lock was taken')
    H.eq(#CP.Sysadmin._index(), before, 'no automatic backup was made')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 170').cash_status, 'paid', 'nothing changed')
    H.eq(OpenMark(), nil, 'nothing is left to finish')

    -- a run row without a column this version needs and has no default for
    b = Backup()
    EditPart(b, 'cp_mission_runs', function(r) r.run_uuid = nil end)
    Tick()
    ok, e = CP.Sysadmin.restore(1, b, 'x4 case')
    H.ok(ok == false and e == 'err.backup_damaged' and CP.Maintenance.active() == nil,
        'a row missing a column with no default is refused before the lock')

    -- a backup made before a migration that added NOT NULL DEFAULT columns: they get their defaults
    Clear()
    H.sql([[INSERT INTO cp_seasons (id, name, starts_at, active) VALUES (1, 'S1', NOW(), 1)]])
    RunX(175, 'o-175', 'OFF00007', 'pending', 0)
    b = Backup()
    EditPart(b, 'cp_seasons', function(r) r.active = nil end)
    EditPart(b, 'cp_mission_runs', function(r) r.participants, r.created_at = nil, nil end)
    Paid(175)
    ok, e = Restore(b)
    H.ok(ok == true, 'an older backup restores: ' .. tostring(type(e) == 'table' and e.backup or e))
    local s = One('SELECT active FROM cp_seasons WHERE id = 1')
    H.eq(Num(H.bit(s.active)), 0, 'a column it lacks gets its default')
    local r = One('SELECT participants, created_at, cash_status FROM cp_mission_runs WHERE id = 175')
    H.ok(Num(r.participants) == 1 and r.created_at ~= nil, 'number and time defaults too')
    H.eq(r.cash_status, 'paid', 'paid since: stays paid')
    H.eq(PaymentsAfter(OwnerRestart), 0, 'nobody is paid twice')
end

-- ============================================================================
--               5. A RESTORE THAT STOPS PART WAY, THEN A RESTART
-- ============================================================================
-- F12: partial failure.

local auto
do
    Clear()
    RunX(180, 'f-180', 'OFF00007', 'pending', 0)
    local b = Backup()
    Paid(180)
    -- cp_mission_runs is put back, then the next table fails (a database or disk error)
    local undo = Breaking(function(sql) return sql == 'DELETE FROM `cp_seasons`' end)
    local ok, e = Restore(b)
    undo()
    H.ok(ok == false and e == 'err.restore_failed', 'the restore stopped part way: ' .. tostring(e))
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 180').cash_status, 'paid',
        'the row paid since the backup is paid again (the money state was put back)')
    auto = LatestAuto()
    local v = CP.Maintenance.view()
    H.ok(v and v.kind == 'restore' and v.failed == true and v.automatic == auto and not v.restart,
        'the lock stays, names the automatic backup and does not say "done, restart"')
    H.eq(OpenMark(), auto, 'and the store keeps it for the next start')
    H.ok(Printed(auto) and Printed('stopped part way'), 'the console names the automatic backup')
    H.ok(CP.L('err.restore_failed'):find('also after a restart', 1, true) ~= nil, 'the admin is told the order')
    H.eq(PayAll(), 0, 'payments are held')
    local okN, eN = Act('server:admin:backupNow', 1, {})
    H.ok(okN == false and eN == 'err.maintenance', 'other actions are refused')

    -- the owner restarts first: the Lua lock is gone, the mark in the store is not
    local n = PaymentsAfter(Restart)
    v = CP.Maintenance.view()
    H.ok(v and v.kind == 'restore' and v.failed == true and v.automatic == auto,
        'after the restart the restore lock is back')
    H.ok(Printed('did not finish'), 'with one console line')
    H.eq(n, 0, 'the start-up sweep and logins pay nothing')

    -- another lock never lets a restore through
    CP.Maintenance.finish('restore')
    CP.Maintenance.begin('storage', { by = 'test' })
    local pv = Cb('admin:previewRestore', 1, { name = auto })
    local okS, eS = Act('server:admin:restoreBackup', 1,
        { name = auto, previewToken = pv and pv.previewToken, reason = 'x', confirm = 'RESTORE', requestId = Rid() })
    H.ok(okS == false and eS == 'err.maintenance', 'a restore is refused during a storage lock')
    CP.Maintenance.finish('storage')
    CP.Maintenance.begin('restore', { by = 'start', failed = true, automatic = auto })

    -- the fix: restore the automatic backup while the lock holds
    ok, e = Restore(auto)
    H.ok(ok == true, 'the automatic backup restores while the failed lock holds: ' .. tostring(e))
    H.eq(OpenMark(), nil, 'the restore is finished')
    v = CP.Maintenance.view()
    H.ok(v and v.restart == true and not v.failed, 'now: done, restart')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 180').cash_status, 'paid', 'still paid')
    n = PaymentsAfter(Restart)
    H.eq(CP.Maintenance.active(), nil, 'the next start has no lock')
    H.eq(n, 0, 'and nobody is paid twice')
end

-- ============================================================================
--                6. STOPPED BEFORE THE MONEY STATE WAS PUT BACK
-- ============================================================================
-- A server stopped mid-way.
-- The store is half put back with the backup's money state: the next restore reads the money state from the
-- automatic backup, not from the store.

do
    Clear()
    RunX(185, 'c-185', 'OFF00007', 'pending', 0)
    Item(185, 'OFF00007', 'c-185', 'pending')
    local b = Backup()
    Paid(185)
    H.sql('UPDATE cp_item_rewards SET status = \'given\', given_at = NOW() WHERE id = 185')
    local undo = Breaking(function(sql)
        return sql == 'DELETE FROM `cp_seasons`' or sql:find('^UPDATE `cp_mission_runs` SET') ~= nil
    end)
    local ok, e = Restore(b)
    undo()
    H.ok(ok == false, 'the restore stopped part way and so did putting the money back')
    -- the admin and the console are never told that every payment kept its state
    H.eq(e, 'err.restore_failed_money', 'the admin is told the money state could not be put back')
    H.ok(
        not CP.L('err.restore_failed_money'):find('kept its state', 1, true)
            and CP.L('err.restore_failed_money'):find('also after a restart', 1, true) ~= nil,
        'and the order, without "kept its state"'
    )
    H.ok(Printed('Putting the money state back failed too'), 'the console says so too')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 185').cash_status, 'pending',
        'the store holds the backup\'s state now (as after a server that stopped mid-way)')
    local open = OpenMark()
    local n = PaymentsAfter(Restart)
    H.eq(CP.Maintenance.view().automatic, open, 'after the restart the lock names the automatic backup')
    H.eq(n, 0, 'nothing is paid while it holds')
    ok = Restore(open)
    H.ok(ok == true, 'restoring it works')
    H.eq(One('SELECT cash_status FROM cp_mission_runs WHERE id = 185').cash_status, 'paid',
        'the money state came from the automatic backup: paid stays paid')
    H.eq(One('SELECT status FROM cp_item_rewards WHERE id = 185').status, 'given', 'given stays given')
    H.eq(PaymentsAfter(Restart), 0, 'nobody is paid twice')
end

-- ============================================================================
--               7. Config.Backups.holdAfterFailedRestore = FALSE
-- ============================================================================

do
    H.sql('INSERT INTO cp_storage_meta (meta_key, meta_value) VALUES (\'restore_open\', ?)', { auto })
    Restart(function() Config.Backups.holdAfterFailedRestore = false end)
    H.eq(CP.Maintenance.active(), nil, 'false: a restart ends the lock of a restore that did not finish')
    H.eq(OpenMark(), nil, 'and forgets it')
end

-- ============================================================================
--               8. THE DAILY BACKUP RUNS ON THE DAILY JOB THREAD
-- ============================================================================
-- Config.Backups.daily = true: the reset listeners and the weekly reset do not wait for a slow backup, the clean-up
-- starts only once the backup has returned, and the backup is still written whole.

do
    Restart(function() H.load('modules/schedule/server.lua') end)
    Config.Backups.daily = true
    Config.Retention = { runArchiveMonths = 0, auditDays = 0 }
    local Sched, Kit, Sys = CP.Schedule, CP.AdminKit, CP.Sysadmin
    local order = {}
    local function Seen(what)
        for _, w in ipairs(order) do if w == what then return true end end
        return false
    end
    local realBackup, realLock = Sys.backup, Kit.lock
    Sys.backup = function(...)
        order[#order + 1] = 'backup'
        Wait(5000) -- a big store takes a while
        local r = table.pack(realBackup(...))
        order[#order + 1] = 'backup done'
        return table.unpack(r, 1, r.n)
    end
    Kit.lock = function(kind, ...)
        if kind == 'cleanup' then order[#order + 1] = 'clean-up' end
        return realLock(kind, ...)
    end
    Sched.onDaily(function() order[#order + 1] = 'daily' end)
    Sched.onWeekly(function() order[#order + 1] = 'weekly' end)
    H.time = H.time + 7 * 86400
    local fired = Sched._check(H.time)
    H.ok(fired.daily and fired.weekly, 'a day and a week went by')
    H.eq(table.concat(order, ','), 'daily,backup,weekly', 'the weekly reset ran while the backup is still going')
    H.ok(not Seen('backup done') and not Seen('clean-up'), 'the boundary check returned before the backup finished')
    H.advance(30000)
    Sys.backup, Kit.lock = realBackup, realLock
    H.eq(table.concat(order, ','), 'daily,backup,weekly,backup done,clean-up',
        'the clean-up started once the backup had returned')
    local list = Sys._index()
    local last = list[#list] or {}
    H.eq(last.kind, 'daily', 'the daily backup is listed')
    local fh = last.name and io.open(GetResourcePath() .. '/saves/_backups/' .. last.name .. '.manifest.json', 'rb')
    H.ok(fh ~= nil, 'with its manifest')
    if fh then fh:close() end
    local done = Sched.cleanupView().last
    H.ok(done ~= nil and done.skipped == nil and done.error == nil, 'and the clean-up ran')
end

return H
