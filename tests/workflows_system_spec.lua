-- WF5E: the system and its integrations, extensively (the owner: "do extensive workflow testing on everything").

-- WF5E: the system and its integrations, extensively (the owner: "do extensive workflow testing on everything").
-- What Crimson-Police does on its own, driven on the REAL server side: the world of tests/workflows_full_spec.lua
-- (every server file of fxmanifest loaded as in game, the owner's scripts running, database off: the saves folder, as
-- shipped), booted on the shipped config with no section of that spec run (CP_WF_WORLD). Each part runs on the
-- shipped config first, then with the switches on, with a `restart Crimson-Police` and a player drop and reconnect in
-- the middle, and every refusal it meets. docs/dev/WORKFLOWS.md lists each workflow with its section here.
--   1. A fresh install: an empty saves folder, the real migrations runner builds every table at start, a run is
--      played and paid, a restart applies nothing twice and keeps everything.
--   2. Every Config.Integrations kind with each adapter: dispatch (sc-dispatch, ps-dispatch, none), ambulance
--      (sc-ambulance, qbx_ambulancejob, none), banking (Renewed-Banking, none), police (sc-police, qbx_policejob,
--      none), each picked in Settings, a restart keeps the pick, a named script that is not running.
--   3. A restart and the maintenance lock in the middle of each money action: a payout paying, Pay now, Retry all,
--      the money tools, department funds; and of each storage action: a backup, a restore, a storage copy.
--   4. The timed jobs: the clean-up (Config.Retention) and the daily backup (Config.Backups) at the daily reset, a
--      restart before the reset, the lock holding them back.
--   5. Idle: with nobody on a run the server sends nothing, writes nothing and no thread wakes every frame.
-- tests/workflows_system_generic_spec.lua runs the generic example config (config/examples/generic.lua copied over
-- config.lua) and its first-start setup on this same world, and tests/workflows_system_db_spec.lua the start on
-- MariaDB (database on).

_G.CP_WF_WORLD = rawget(_G, 'CP_WF_WORLD') or 'system'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Cb, Act, Secs, Setting = W.Cb, W.Act, W.Secs, W.Setting
local ClientEvents = W.ClientEvents
local cjson = require('cjson')

-- tests/workflows_system_db_spec.lua: the same walk on MariaDB (database on)
local ON_DB = Config.Database.enabled == true
local function Later() H.time = H.time + 3700 end
local function Open(src) return Cb('getSession', src, { ui = 'officer', via = 'command' }) end
local function RequestId() return W.RequestId() end
local function Count(sql, params) return W.Count(sql, params) end
local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
local function Draw(src, typeKey, disabled)
    Later()
    local saved = Config.DisabledMissions
    local list = {}
    for _, id in ipairs(saved or {}) do list[#list + 1] = id end
    for _, id in ipairs(disabled or {}) do list[#list + 1] = id end
    Config.DisabledMissions = list
    local ok, data = Act('server:acceptType', src, typeKey)
    Config.DisabledMissions = saved
    return ok, data, CP.Runs.getBySrc(src)
end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
end
-- Beat Patrol played to its end -> its run row.
local function Patrol(src)
    local ok, why, run = Draw(src, 'patrol', PATROL_OTHERS)
    H.eq(ok, true, ('patrol: %s accepts Beat Patrol: %s'):format(CID[src], tostring(why)))
    if not ok or not run then return nil end
    local veh = W.TakeWheel(src, run)
    W.DriveCheckpoints(src, run, veh)
    Secs(5)
    return W.Rows('run_uuid = ?', { run.id })[1], run
end
local function Audits(action)
    return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action })
end

-- ============================================================================
--                    1. A FRESH INSTALL (THE SAVES FOLDER)
-- ============================================================================
-- AN EMPTY SAVES FOLDER, EVERY TABLE BUILT AT START, A RUN, A RESTART APPLIES NOTHING TWICE.

do
    H.eq(Config.Database.enabled, ON_DB,
        ON_DB and 'database on (MariaDB)' or 'shipped: database off (the saves folder)')
    H.eq(Config.Debug, true, 'shipped: Debug on')
    H.eq(Config.Rewards.enabled, false, 'shipped: item rewards off')
    H.eq(Config.Cash.allowManualCash, false, 'shipped: the money tools off')
    H.eq(Config.Backups.daily, false, 'shipped: no daily backup')

    -- the server stops, the owner empties the saves folder (or the database: a fresh install), the server starts
    Secs(2)
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    os.execute(('rm -rf \'%s/saves\''):format(H.resourcePath()))
    if ON_DB then
        os.execute(('mysql -uroot -e "DROP DATABASE %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(H.db, H.db))
    end
    H.emptySaves = true
    W.Boot()
    H.emptySaves = nil
    Secs(5)
    local st = CP.Migrations.status()
    H.eq(CP.Migrations.failed(), nil, 'fresh: the start did not fail')
    H.eq(CP.Migrations.isReady(), true, 'fresh: started')
    H.eq(st.version, H.migrationVersion(), 'fresh: every migration applied at start')
    H.eq(st.pending, 0, 'fresh: none pending')
    if ON_DB then
        H.eq(Count(
            'SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = DATABASE() AND '
                .. 'table_name LIKE ? AND table_collation NOT LIKE ?',
            { 'cp\\_%', 'utf8mb4%' }
        ), 0, 'fresh: every table utf8mb4')
    else
        local f = io.open(H.savesDir() .. '/_tables.json', 'r')
        H.ok(f ~= nil, 'fresh: the saves folder holds its tables')
        if f then f:close() end
    end
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_officers'), 0, 'fresh: no officer yet')
    H.eq(CP.Maintenance.active(), nil, 'fresh: no maintenance lock')

    -- the players were online all along: they open the tablet, an officer plays and is paid
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        H.ok(Open(src) ~= nil, ('fresh: %s opens the Officer UI'):format(CID[src]))
    end
    local row = Patrol(1)
    H.eq(row and row.state, 'completed', 'fresh: Beat Patrol completed')
    H.eq(row and row.cash_status, 'paid', 'fresh: and paid')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_officers'), 6, 'fresh: every officer who opened it is known')

    -- a restart: the migrations are not applied again, the run and the officers stay
    local applied = H.sql('SELECT version, applied_at FROM cp_schema_migrations ORDER BY version')
    W.Drop(6)
    W.Restart()
    W.Reconnect(6)
    st = CP.Migrations.status()
    H.eq(st.pending, 0, 'restart: none pending')
    local again = H.sql('SELECT version, applied_at FROM cp_schema_migrations ORDER BY version')
    H.eq(#again, #applied, 'restart: no migration recorded twice')
    H.eq(cjson.encode(again), cjson.encode(applied), 'restart: none applied again')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE state = ?', { 'completed' }), 1,
        'restart: the run is kept')
    H.ok(Open(6) ~= nil, 'reconnect: the officer who dropped opens the tablet')
end

-- ============================================================================
--             2. EVERY CONFIG.INTEGRATIONS KIND WITH EACH ADAPTER
-- ============================================================================
-- DISPATCH, AMBULANCE, BANKING, POLICE: THE OWNER'S SCRIPT, THE OTHER ONE, NONE.

-- The other scripts' stand-ins, shaped like their real server exports (tests/integrations_spec.lua has the copies):
-- ps-dispatch's GetDispatchCalls, qbx_core's GetDutyCountType and qbx_medical's Revive.
local psCalls = {}                -- ps-dispatch's active calls
local emsOnDuty = 0               -- qbx_core's on-duty count of job type 'ems'
local revived = {}                -- qbx_medical Revive(src) calls
local scRevived = {}              -- sc-ambulance's revive events
local running = {}                -- resource -> false: not running on this city (GetResourceState 'missing')
H.exportsMock['ps-dispatch'] = {
    GetDispatchCalls = function() return psCalls end,
}
H.exportsMock.qbx_core.GetDutyCountType = function(kind) return kind == 'ems' and emsOnDuty or 0 end
H.exportsMock.qbx_medical = {
    Revive = function(src) revived[#revived + 1] = src return true end,
}
local function Natives()
    local state = _G.GetResourceState
    _G.GetResourceState = function(name)
        if running[name] == false then return 'missing' end
        return state(name)
    end
end
local realRestart = W.Restart
W.Restart = function()
    realRestart()
    Natives()
end
Natives()
local function Pick(kind) return (CP.Integrations.pick(kind)) or 'none' end
local function Kind(kind, value)
    local ok, err = Setting('Integrations.' .. kind, value)
    H.eq(ok, true, ('integrations: %s set to %s: %s'):format(kind, value, tostring(err)))
end
-- src goes down on a run (qbx_core's isdead) -> the client events he got for it.
local function Downed(src)
    local ok, why, run = Draw(src, 'patrol', PATROL_OTHERS)
    H.eq(ok, true, 'downed: the officer is on a run: ' .. tostring(why))
    if not run then return {} end
    W.Arrive(run, src)
    local mark = #H.events
    PD[src].metadata.isdead = true
    TriggerEvent('qbx_core:server:onSetMetaData', 'isdead', false, true, src)
    Secs((tonumber(Config.Downed.pickupDelay) or 10) + 8)
    local got = {}
    for i = mark + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.target == src then got[e.name] = e.args end
    end
    PD[src].metadata.isdead = false
    TriggerEvent('qbx_core:server:onSetMetaData', 'isdead', true, false, src)
    H.fire('crimson-police:server:pickupDone', src, run.id, true)
    Secs(5)
    H.eq(CP.Runs.getBySrc(src), nil, 'downed: off the run')
    return got, run
end

do
    -- as shipped: every kind 'auto' finds the owner's script
    for _, kind in ipairs(CP.Integrations.KINDS) do
        H.eq(Config.Integrations[kind], 'auto', 'shipped: ' .. kind .. ' auto')
    end
    H.eq(Pick('dispatch') .. ',' .. Pick('ambulance') .. ',' .. Pick('banking') .. ',' .. Pick('police'),
        'sc-dispatch,sc-ambulance,Renewed-Banking,sc-police', 'shipped: auto picks the owner\'s scripts')
    local ok, err = Act('server:admin:setSetting', 3, { path = 'Integrations.dispatch', json = '"none"', reason = 'x' })
    H.eq(ok, false, 'integrations: a supervisor cannot change one (' .. tostring(err) .. ')')
    ok, err = Setting('Integrations.dispatch', 'my-dispatch')
    H.eq(ok, false, 'integrations: a script with no adapter is refused (' .. tostring(err) .. ')')
    H.eq(Pick('dispatch'), 'sc-dispatch', 'integrations: still sc-dispatch')
end

do
    -- dispatch: ps-dispatch serves; a real call it holds, an officer on a run responds to it: released from the run
    Kind('dispatch', 'ps-dispatch')
    H.eq(Pick('dispatch'), 'ps-dispatch', 'dispatch: ps-dispatch serves')
    psCalls = { { id = 77, priority = 1, code = '10-71' } }
    local ok, why, run = Draw(1, 'patrol', PATROL_OTHERS)
    H.eq(ok, true, 'dispatch: Ada is on a run: ' .. tostring(why))
    if run then W.Arrive(run, 1) end
    H.fire('ps-dispatch:server:attach', 1, 77)
    Secs(5)
    H.eq(CP.Runs.getBySrc(1), nil, 'ps-dispatch: responding to a real call releases her from the run')
    local row = run and W.Rows('run_uuid = ?', { run.id })[1]
    H.ok(row ~= nil and row.state ~= 'completed', 'ps-dispatch: the run ended (' .. tostring(row and row.state) .. ')')
    H.fire('ps-dispatch:server:detach', 1, 77)
    -- sc-dispatch's toggle is ignored while ps-dispatch serves
    ok, why, run = Draw(1, 'patrol', PATROL_OTHERS)
    if run then W.Arrive(run, 1) end
    H.fire('sc-dispatch:server:ToggleResponding', 1, 'call_77', true)
    Secs(5)
    H.ok(run ~= nil and CP.Runs.getBySrc(1) == run, 'ps-dispatch: sc-dispatch\'s toggle changes nothing')
    -- a restart keeps the pick
    W.Drop(1)
    W.Restart()
    W.Reconnect(1)
    H.eq(Config.Integrations.dispatch, 'ps-dispatch', 'restart: dispatch still ps-dispatch')
    H.eq(Pick('dispatch'), 'ps-dispatch', 'restart: ps-dispatch serves')
    -- ps-dispatch stops: named, it is not swapped for sc-dispatch; Features and System say so
    running['ps-dispatch'] = false
    H.eq(CP.Dispatch.available(), false, 'ps-dispatch stopped: no dispatch')
    H.eq(Pick('dispatch'), 'ps-dispatch', 'ps-dispatch stopped: still the named script')
    local health = cjson.encode(CP.ConfigHealth and CP.ConfigHealth.run and CP.ConfigHealth.run() or {})
    H.ok(health:find('ps-dispatch', 1, true) ~= nil, 'ps-dispatch stopped: Config health names it')
    running['ps-dispatch'] = nil
    -- none: no dispatch script; responding is the tablet's own only
    Kind('dispatch', 'none')
    H.eq(Pick('dispatch'), 'none', 'dispatch none: no script')
    ok, why, run = Draw(1, 'patrol', PATROL_OTHERS)
    if run then W.Arrive(run, 1) end
    H.fire('ps-dispatch:server:attach', 1, 77)
    H.fire('sc-dispatch:server:ToggleResponding', 1, 'call_77', true)
    Secs(5)
    H.ok(run ~= nil and CP.Runs.getBySrc(1) == run, 'dispatch none: no script releases her from the run')
    Leave(1)
    Kind('dispatch', 'auto')
    H.eq(Pick('dispatch'), 'sc-dispatch', 'dispatch auto: sc-dispatch again')
    psCalls = {}
end

do
    -- ambulance: sc-ambulance with no doctor (a pick-up and sc-ambulance's revive), qbx_ambulancejob with EMS on
    -- duty (the EMS request) and without (qbx_medical's revive), none (Crimson-Police revives on its own)
    local got = Downed(1)
    H.ok(got['crimson-police:client:pickup'] ~= nil, 'sc-ambulance, no doctor: the free pick-up')
    Kind('ambulance', 'qbx_ambulancejob')
    H.eq(Pick('ambulance'), 'qbx_ambulancejob', 'ambulance: qbx_ambulancejob serves')
    emsOnDuty = 2
    H.eq(CP.Ambulance.doctorCount(), 2, 'qbx_ambulancejob: EMS on duty from qbx_core')
    got = Downed(1)
    local req = got['crimson-police:client:requestEMS']
    H.ok(req ~= nil, 'qbx_ambulancejob, EMS on duty: the EMS request')
    H.eq(req and req[2], 'qbx_ambulancejob', 'qbx_ambulancejob: its own alert')
    H.eq(got['crimson-police:client:pickup'], nil, 'qbx_ambulancejob, EMS on duty: no pick-up')
    emsOnDuty = 0
    W.Restart()
    H.eq(Pick('ambulance'), 'qbx_ambulancejob', 'restart: ambulance still qbx_ambulancejob')
    revived = {}
    got = Downed(1)
    H.ok(got['crimson-police:client:pickup'] ~= nil, 'qbx_ambulancejob, no EMS: the free pick-up')
    H.eq(revived[1], 1, 'qbx_ambulancejob: qbx_medical revives her')
    -- qbx_medical not running: the pick-up cannot revive, it is cancelled
    running.qbx_medical = false
    revived = {}
    got = Downed(1)
    H.eq(#revived, 0, 'qbx_medical stopped: no revive')
    H.ok(got['crimson-police:client:pickupCancel'] ~= nil, 'qbx_medical stopped: the pick-up is cancelled')
    running.qbx_medical = nil
    Kind('ambulance', 'none')
    got = Downed(1)
    H.ok(got['crimson-police:client:pickup'] ~= nil, 'ambulance none: the free pick-up')
    H.eq(CP.Ambulance.doctorCount(), 0, 'ambulance none: no EMS')
    Kind('ambulance', 'auto')
    H.eq(Pick('ambulance'), 'sc-ambulance', 'ambulance auto: sc-ambulance again')
end

do
    -- banking: Renewed-Banking writes the payout's bank history; none pays the same with no history entry
    local before = W.BankEntries()
    local row = Patrol(1)
    H.eq(row and row.cash_status, 'paid', 'Renewed-Banking: the run is paid')
    H.ok(W.BankEntries() > before, 'Renewed-Banking: the payout is in the bank history')
    Kind('banking', 'none')
    W.Restart()
    H.eq(Pick('banking'), 'none', 'restart: banking still none')
    before = W.BankEntries()
    local n0, a0 = W.Paid(CID[1])
    row = Patrol(1)
    local n1, a1 = W.Paid(CID[1])
    H.eq(row and row.cash_status, 'paid', 'banking none: the run is paid all the same')
    H.eq(n1 - n0, 1, 'banking none: one payment')
    H.eq(a1 - a0, tonumber(row and row.cash_paid), 'banking none: the same amount')
    H.eq(W.BankEntries(), before, 'banking none: no bank history entry')
    H.eq(CP.Banking.societyOn(), false, 'banking none: no society account')
    Kind('banking', 'auto')
end

do
    -- police: sc-police has the cuff and jail facts (live crimes may go on); qbx_policejob jails but cannot cuff,
    -- none has neither: live crimes and volunteers stay off with a line on Features that says why
    H.eq(CP.Integrations.realSuspectsBlocked(), false, 'sc-police: cuff and jail, live crimes may run')
    Kind('police', 'qbx_policejob')
    H.eq(Pick('police'), 'qbx_policejob', 'police: qbx_policejob serves')
    H.eq(CP.Police.has('jail'), true, 'qbx_policejob: jailing is seen')
    H.eq(CP.Police.has('cuff'), false, 'qbx_policejob: no cuffing')
    H.eq(CP.Integrations.realSuspectsBlocked(), true, 'qbx_policejob: live crimes and volunteers stay off')
    Setting('RealPlayers.liveCrime.enabled', true)
    H.ok(type(CP.Integrations.featureOff('live_crimes')) == 'string', 'qbx_policejob: Features says why')
    local seen = {}
    CP.Police.on('jail', function(src, target, time) seen[#seen + 1] = ('%s:%s:%s'):format(src, target, time) end)
    H.fire('police:server:JailPlayer', 1, 6, 30)
    H.fire('police:server:CuffPlayer', 1, 6, false)
    Secs(1)
    H.eq(#seen, 0, 'qbx_policejob: with no live case open its events are not even read')
    W.Restart()
    H.eq(Pick('police'), 'qbx_policejob', 'restart: police still qbx_policejob')
    Kind('police', 'none')
    H.eq(CP.Police.has('jail'), false, 'police none: no facts')
    H.eq(CP.Integrations.realSuspectsBlocked(), true, 'police none: live crimes stay off')
    Kind('police', 'auto')
    H.eq(CP.Integrations.realSuspectsBlocked(), false, 'police auto: sc-police again')
    Act('server:admin:resetSetting', 5, { path = 'RealPlayers.liveCrime.enabled', reason = 'WF5E' })
    for _, kind in ipairs(CP.Integrations.KINDS) do
        Act('server:admin:resetSetting', 5, { path = 'Integrations.' .. kind, reason = 'WF5E' })
    end
end

-- ============================================================================
--    3. A RESTART AND THE MAINTENANCE LOCK IN EACH MONEY AND STORAGE ACTION
-- ============================================================================
-- A PAYOUT PAYING, PAY NOW, RETRY ALL, THE MONEY TOOLS, FUNDS; A BACKUP, A RESTORE, A STORAGE COPY.

-- How Qbox's AddMoney answers Ada's next payment: nil = as normal, false = it refuses, 'raise' = it errors.
local nextAddMoney = nil
do
    local realGet = H.exportsMock.qbx_core.GetPlayer
    H.exportsMock.qbx_core.GetPlayer = function(src)
        local p = realGet(src)
        if p and tonumber(src) == 1 and nextAddMoney ~= nil then
            local mode = nextAddMoney
            local add = p.Functions.AddMoney
            p.Functions.AddMoney = function(...)
                nextAddMoney = nil
                if mode == 'raise' then error('bank is down') end
                if mode == false then return false end
                return add(...)
            end
        end
        return p
    end
end
local function Status(rowId) return (W.Rows('id = ?', { rowId })[1] or {}).cash_status end
local function Restore(name, tries)
    local pv = Cb('admin:previewRestore', 5, { name = name })
    return Act('server:admin:restoreBackup', 5, {
        name = name,
        previewToken = pv and pv.previewToken,
        reason = 'WF5E',
        confirm = 'RESTORE',
        requestId = RequestId(),
    }, tries or 400)
end
local function OpenRestore()
    local r = H.sql('SELECT meta_value FROM cp_storage_meta WHERE meta_key = ?', { 'restore_open' })[1]
    return r and r.meta_value ~= '' and r.meta_value or nil
end
-- The admin's money and storage changes, each refused while a lock holds.
local function MoneyRefused(label)
    local list = {
        { 'server:admin:payNow', { rowId = 1, requestId = RequestId() } },
        { 'server:admin:retryPending', { requestId = RequestId() } },
        { 'server:admin:manualCash', { citizenid = CID[1], amount = 50, reason = 'x', requestId = RequestId() } },
        { 'server:admin:clawback', { citizenid = CID[1], amount = 50, reason = 'x', requestId = RequestId() } },
        {
            'server:admin:addDepartmentFunds',
            { department = 'sast', amount = 100, reason = 'x', requestId = RequestId() },
        },
        { 'server:admin:setTypePayout', { type = 'patrol', amount = 300, reason = 'x' } },
        { 'server:admin:backupNow', {} },
        { 'server:admin:storageCopy', { direction = 'files-to-database', reason = 'x', requestId = RequestId() } },
    }
    for _, r in ipairs(list) do
        Secs(1)
        local ok, res = Act(r[1], 5, r[2])
        H.eq(res, 'err.maintenance', ('%s: %s refused'):format(label, r[1]))
    end
end

do
    -- a payout cut off while it pays (Qbox raised): 'paying' across a restart, never paid again by itself
    nextAddMoney = 'raise'
    local n0 = W.Paid(CID[1])
    local row = Patrol(1)
    H.eq(row and row.cash_status, 'paying', 'paying: AddMoney raised, the row waits for a check')
    W.Restart()
    Secs(130)
    W.Drop(1)
    W.Reconnect(1)
    Secs(5)
    H.eq(Status(row and row.id), 'paying', 'paying: a restart and her login never pay it again')
    H.eq(W.Paid(CID[1]), n0, 'paying: no payment went out')
    local ok, err = Act('server:admin:resolvePayment', 5,
        { rowId = row and row.id, outcome = 'paid', reason = 'Checked the bank history', requestId = RequestId() })
    H.eq(ok, true, 'paying: Mark paid after the restart: ' .. tostring(err))
end

local pendingRow
do
    -- a pending payment (Qbox refused), a backup, the restore: the lock holds every money and storage action and
    -- her login pays nothing; the restart ends it and her payment goes out once
    nextAddMoney = false
    local row = Patrol(1)
    H.eq(row and row.cash_status, 'pending', 'restore: a payment Qbox refused waits (pending)')
    pendingRow = row and row.id
    local ok, res = Act('server:admin:backupNow', 5, {})
    H.ok(ok == true and type(res) == 'table', 'restore: a backup: ' .. tostring(res))
    local name = res and res.name
    W.Drop(1)
    ok, res = Restore(name)
    H.ok(ok == true and type(res) == 'table' and res.restart == true,
        'restore: done, a restart asked: ' .. tostring(res))
    H.eq(CP.Maintenance.active(), 'restore', 'restore: the lock holds')
    local n0 = W.Paid(CID[1])
    W.Reconnect(1)
    Secs(70)
    H.eq(Status(pendingRow), 'pending', 'restore lock: her login pays nothing')
    H.eq(W.Paid(CID[1]), n0, 'restore lock: no payment went out')
    MoneyRefused('restore lock')
    local okA = Draw(6, 'patrol', PATROL_OTHERS)
    H.eq(okA, false, 'restore lock: no run starts')
    W.Restart()
    H.eq(CP.Maintenance.active(), nil, 'restart: the lock is gone')
    Secs(70)
    W.Drop(1)
    W.Reconnect(1)
    Secs(5)
    H.eq(Status(pendingRow), 'paid', 'restart: her pending payment is paid')
    H.eq(W.Paid(CID[1]), n0 + 1, 'restart: once')
    W.Restart()
    W.Drop(1)
    W.Reconnect(1)
    Secs(5)
    H.eq(W.Paid(CID[1]), n0 + 1, 'restart again: never twice')
    Act('server:admin:deleteBackup', 5, { name = name, reason = 'Old', confirm = name })
end

do
    -- a restore the server stops in the middle of: on start the lock holds (Config.Backups.holdAfterFailedRestore),
    -- payments and runs wait; a fix restore puts it right, a restart ends the lock
    nextAddMoney = false
    local row = Patrol(1)
    H.eq(row and row.cash_status, 'pending', 'cut restore: a pending payment')
    local ok, res = Act('server:admin:backupNow', 5, {})
    local name = ok and res and res.name
    local pv = Cb('admin:previewRestore', 5, { name = name })
    W.Adv(1600)
    H.fire('crimson-police:server:admin:restoreBackup', 5, {
        name = name,
        previewToken = pv and pv.previewToken,
        reason = 'WF5E',
        confirm = 'RESTORE',
        requestId = ('%08x-0000-4000-8000-%012x'):format(999999, 91),   -- (an id no Act below uses)
    }, 'wf5e-cut')
    local open
    for _ = 1, 400 do
        open = OpenRestore()
        if open then break end
        H.step(0)
    end
    H.ok(open ~= nil, 'cut restore: the restore is under way (its automatic backup named)')
    -- the server stops before it finishes
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    W.Boot()
    Secs(5)
    local kind, info = CP.Maintenance.active()
    H.eq(kind, 'restore', 'cut restore: the lock is back at start')
    H.eq(info and info.failed, true, 'cut restore: ...as a restore that did not finish')
    H.eq(info and info.automatic, open, 'cut restore: ...naming its automatic backup')
    local n0 = W.Paid(CID[1])
    W.Drop(1)
    W.Reconnect(1)
    Secs(70)
    H.eq(Status(row and row.id), 'pending', 'cut restore: her login pays nothing')
    H.eq(W.Paid(CID[1]), n0, 'cut restore: nothing paid')
    MoneyRefused('cut restore')
    -- the fix: restore again (the backup she chose, or the automatic one)
    ok, res = Restore(name)
    H.ok(ok == true and type(res) == 'table' and res.restart == true,
        'cut restore: the fix restore works: ' .. tostring(res))
    H.eq(OpenRestore(), nil, 'cut restore: nothing left open')
    W.Restart()
    H.eq(CP.Maintenance.active(), nil, 'cut restore: the restart ends the lock')
    W.Drop(1)
    W.Reconnect(1)
    Secs(70)
    H.eq(Status(row and row.id), 'paid', 'cut restore: her payment goes out')
    H.eq(W.Paid(CID[1]), n0 + 1, 'cut restore: once')
    for _, b in ipairs((Cb('admin:getBackups', 5) or {}).backups or {}) do
        if not b.protected then
            Act('server:admin:deleteBackup', 5, { name = b.name, reason = 'Old', confirm = b.name })
        end
    end
end

do
    -- a backup cut off by a stop leaves part files with no manifest: the next start never lists them and removes them
    local dir = H.resourcePath() .. '/saves/_backups'
    local f = io.open(dir .. '/20260101-000000-manual.t.cp_officers.json', 'w')
    if f then f:write('[]') f:close() end
    W.Restart()
    local list = Cb('admin:getBackups', 5)
    local names = {}
    for _, b in ipairs(list and list.backups or {}) do names[#names + 1] = b.name end
    H.ok(not table.concat(names, ' '):find('20260101', 1, true), 'cut backup: never listed')
    local gone = io.open(dir .. '/20260101-000000-manual.t.cp_officers.json', 'r')
    H.eq(gone, nil, 'cut backup: its part file is removed')
    if gone then gone:close() end
end

do
    -- a storage copy into the other store (the copy runs to its end in one go, so no stop can come in the middle):
    -- the store in use untouched, no lock left; a restart, then a copy over it is refused without force (and its
    -- typed REPLACE), and put right with them; runs start again
    local direction = ON_DB and 'database-to-files' or 'files-to-database'
    if not ON_DB then
        os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(
            H.db, H.db))
    end
    local runsBefore = Count('SELECT COUNT(*) AS n FROM cp_mission_runs')
    local ok, res = Act('server:admin:storageCopy', 5,
        { direction = direction, reason = 'WF5E copy', requestId = RequestId() }, 400)
    H.eq(ok, true, 'copy: the other store gets a copy: ' .. tostring(res))
    H.eq(CP.Maintenance.active(), nil, 'copy: no lock left')
    W.Drop(5)
    W.Restart()
    W.Reconnect(5)
    H.eq(Config.Database.enabled, ON_DB, 'copy: the same store in use')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs'), runsBefore, 'copy: its rows untouched')
    ok, res = Act('server:admin:storageCopy', 5,
        { direction = direction, reason = 'WF5E again', requestId = RequestId() }, 400)
    H.eq(ok, false, 'copy: a copy over a store with rows is refused without force (' .. tostring(res) .. ')')
    ok, res = Act('server:admin:storageCopy', 5,
        { direction = direction, reason = 'WF5E force', force = true, requestId = RequestId() }, 400)
    H.eq(res, 'err.confirm_mismatch', 'copy: force needs the typed REPLACE')
    ok, res = Act('server:admin:storageCopy', 5,
        { direction = direction, reason = 'WF5E force', force = true, confirm = 'REPLACE', requestId = RequestId() },
        400)
    H.eq(ok, true, 'copy: with force and REPLACE it is replaced: ' .. tostring(res))
    local okA = Draw(6, 'patrol', PATROL_OTHERS)
    H.eq(okA, true, 'copy: runs start again')
    Leave(6)

    -- the switch to that store (typed SWITCH) marks the store in use left behind; the server comes back on it all the
    -- same (here the switch never takes): the left_behind lock holds payments, runs and changes until an admin uses
    -- it again (typed USE)
    nextAddMoney = false
    local row = Patrol(1)
    H.eq(row and row.cash_status, 'pending', 'switch: a pending payment')
    ok, res = Act('server:admin:setStorageMode', 5,
        { enabled = not ON_DB, folder = 'saves', reason = 'WF5E', requestId = RequestId() })
    H.eq(res, 'err.confirm_mismatch', 'switch: needs the typed SWITCH')
    ok, res = Act('server:admin:setStorageMode', 5,
        { enabled = not ON_DB, folder = 'saves', reason = 'WF5E', confirm = 'SWITCH', requestId = RequestId() })
    H.ok(ok == true and type(res) == 'table' and res.restart == true,
        'switch: saved, a restart asked: ' .. tostring(res))
    H.eq(CP.Maintenance.active(), 'storage', 'switch: the storage lock until the restart')
    W.Drop(1)
    W.Restart()
    H.eq(CP.Maintenance.active(), 'left_behind', 'switch: back on the old store, it is locked as left behind')
    local n0 = W.Paid(CID[1])
    W.Reconnect(1)
    Secs(70)
    H.eq(Status(row and row.id), 'pending', 'left behind: her login pays nothing')
    MoneyRefused('left behind')
    H.eq((Draw(6, 'patrol', PATROL_OTHERS)), false, 'left behind: no run starts')
    ok, res = Act('server:admin:useStoreAgain', 3, { reason = 'x', confirm = 'USE' })
    H.eq(ok, false, 'left behind: a supervisor cannot lift it (' .. tostring(res) .. ')')
    ok, res = Act('server:admin:useStoreAgain', 5, { reason = 'WF5E' })
    H.eq(res, 'err.confirm_mismatch', 'left behind: Use again needs the typed USE')
    ok, res = Act('server:admin:useStoreAgain', 5, { reason = 'WF5E', confirm = 'USE' })
    H.eq(ok, true, 'left behind: used again: ' .. tostring(res))
    H.eq(CP.Maintenance.active(), nil, 'left behind: the lock is off at once')
    W.Drop(1)
    W.Reconnect(1)
    Secs(5)
    H.eq(Status(row and row.id), 'paid', 'used again: her payment goes out')
    H.eq(W.Paid(CID[1]), n0 + 1, 'used again: once')
    W.Restart()
    H.eq(CP.Maintenance.active(), nil, 'restart: no lock')
    H.eq(Audits('storageUseAgain'), 1, 'used again: audited')
    if not ON_DB then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db)) end
end

-- ============================================================================
--                 4. THE TIMED JOBS: CLEAN-UP AND DAILY BACKUP
-- ============================================================================
-- CONFIG.RETENTION AND CONFIG.BACKUPS AT THE DAILY RESET, A RESTART BEFORE IT, THE LOCK HOLDING THEM BACK.

-- The clock to just before the next daily reset (Config.Time.resetHour), then past it.
local function PastReset()
    local d = os.date('*t', H.time)
    local hour = tonumber(Config.Time.resetHour) or 0
    local at = os.time({ year = d.year, month = d.month, day = d.day, hour = hour, min = 0, sec = 0 })
    if at <= H.time then at = at + 86400 end
    H.time = at - 30
    Secs(150)
end
-- Two rows made old: a run 13 months back and an audit row 200 days back -> run id, audit id.
local function MakeOld()
    local run = H.sql('SELECT id FROM cp_mission_runs ORDER BY id LIMIT 1')[1]
    local audit = H.sql('SELECT id FROM cp_audit ORDER BY id LIMIT 1')[1]
    H.sql('UPDATE cp_mission_runs SET created_at = FROM_UNIXTIME(?) WHERE id = ?', { H.time - 400 * 86400, run.id })
    H.sql('UPDATE cp_audit SET created_at = FROM_UNIXTIME(?) WHERE id = ?', { H.time - 200 * 86400, audit.id })
    return run.id, audit.id
end
local function Archived(id) return Count('SELECT COUNT(*) AS n FROM cp_mission_runs_archive WHERE id = ?', { id }) end
local function Live(id) return Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ?', { id }) end
local function AuditLeft(id) return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE id = ?', { id }) end
local function Daily()
    local n = 0
    for _, b in ipairs((Cb('admin:getBackups', 5) or {}).backups or {}) do if b.kind == 'daily' then n = n + 1 end end
    return n
end

do
    -- as shipped: the clean-up at the reset (runs older than 12 months archived, audit older than 180 days deleted),
    -- no daily backup
    local runId, auditId = MakeOld()
    W.Restart()                                   -- a restart before the reset changes nothing below
    PastReset()
    H.eq(Archived(runId), 1, 'clean-up: the old run is archived at the reset')
    H.eq(Live(runId), 0, 'clean-up: ...and gone from the live table')
    H.eq(AuditLeft(auditId), 0, 'clean-up: the old audit row is deleted')
    H.eq(Daily(), 0, 'shipped: no daily backup at the reset')
    local jobs = Cb('admin:getJobs', 5)
    local last
    for _, j in ipairs(jobs and jobs.jobs or {}) do if j.id == 'cleanup' then last = j.last end end
    H.ok(type(last) == 'table' and last.error == nil, 'jobs: the clean-up\'s last result is shown')

    -- Retention 0 keeps everything; the daily backup on, Backups.keep 2: one a reset, the oldest removed
    H.eq(Setting('Retention.runArchiveMonths', 0), true, 'clean-up: runs kept forever')
    H.eq(Setting('Retention.auditDays', 0), true, 'clean-up: audit kept forever')
    H.eq(Setting('Backups.daily', true), true, 'backup: the daily backup on')
    H.eq(Setting('Backups.keep', 2), true, 'backup: keep 2')
    runId, auditId = MakeOld()
    W.Drop(5)
    W.Restart()
    PastReset()
    H.eq(Live(runId), 1, 'retention 0: the old run stays')
    H.eq(AuditLeft(auditId), 1, 'retention 0: the old audit row stays')
    W.Reconnect(5)
    H.eq(Daily(), 1, 'backup: one daily backup at the reset')
    PastReset()
    PastReset()
    H.eq(#((Cb('admin:getBackups', 5) or {}).backups or {}), 2, 'backup: keep 2 removes the oldest')

    -- the maintenance lock holds both back (a restore that waits for its restart)
    local ok, res = Act('server:admin:backupNow', 5, {})
    ok, res = Restore(ok and res and res.name)
    H.eq(CP.Maintenance.active(), 'restore', 'lock: a restore waits for its restart')
    H.eq(Setting('Retention.auditDays', 180), false, 'lock: no setting changes meanwhile')
    Config.Retention.auditDays = 180          -- (as if config.lua said so: the job reads it at the reset)
    local before = #((Cb('admin:getBackups', 5) or {}).backups or {})
    auditId = select(2, MakeOld())
    PastReset()
    H.eq(AuditLeft(auditId), 1, 'lock: no clean-up at the reset')
    H.eq(#((Cb('admin:getBackups', 5) or {}).backups or {}), before, 'lock: no daily backup at the reset')
    W.Restart()
    H.eq(CP.Maintenance.active(), nil, 'restart: the lock is gone')
    for _, path in ipairs({ 'Retention.runArchiveMonths', 'Retention.auditDays', 'Backups.daily', 'Backups.keep' }) do
        Act('server:admin:resetSetting', 5, { path = path, reason = 'WF5E' })
    end
    auditId = select(2, MakeOld())
    PastReset()
    H.eq(AuditLeft(auditId), 0, 'restart: the clean-up runs at the next reset')
end

-- ============================================================================
--                    5. IDLE: NOBODY ON A RUN, NOTHING RUNS
-- ============================================================================
-- THE LOOPS IDLE CHECK: NO CLIENT EVENT, NO WRITE, NO THREAD THAT WAKES EVERY FRAME.

-- Ten idle minutes (the officers online and on duty, nobody on a run or a case) -> what the server did.
local function Idle()
    for src = 1, 7 do Leave(src) end
    Secs(30)
    local wakes, fast, writes, reads, sqls = 0, {}, 0, 0, {}
    local realWait, realMySQL = _G.Wait, _G.MySQL
    _G.Wait = function(ms)
        wakes = wakes + 1
        if (tonumber(ms) or 0) < 500 then
            local info = debug.getinfo(2, 'Sl')
            local at = info and (info.short_src .. ':' .. tostring(info.currentline)) or '?'
            fast[at] = (fast[at] or 0) + 1
        end
        return realWait(ms)
    end
    local spy = {}
    for kind, t in pairs(realMySQL) do
        if type(t) == 'table' and type(t.await) == 'function' then
            spy[kind] = setmetatable({
                await = function(sql, ...)
                    local s2 = tostring(sql):gsub('^%s+', ''):upper()
                    local key = s2:sub(1, 70)
                    sqls[key] = (sqls[key] or 0) + 1
                    if s2:find('^SELECT') or s2:find('^SHOW') then reads = reads + 1 else writes = writes + 1 end
                    return t.await(sql, ...)
                end,
            }, { __index = t })
        else
            spy[kind] = t
        end
    end
    _G.MySQL = setmetatable(spy, { __index = realMySQL })
    local mark = #H.events
    Secs(600)
    _G.Wait, _G.MySQL = realWait, realMySQL
    local sent = {}
    for i = mark + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' then sent[#sent + 1] = e.name end
    end
    return { wakes = wakes, fast = fast, writes = writes, reads = reads, sent = sent, sql = sqls }
end

do
    -- as shipped: the NPC mission calls (Config.MissionCalls, on as shipped) are all that happens: a call posted and
    -- lapsed now and then, its card to the officers on duty
    local r = Idle()
    H.eq(next(r.fast), nil, 'idle: no thread waits less than 500 ms')
    local other = {}
    for k in pairs(r.sql) do
        if not k:find('^SELECT') and not k:find('CP_MISSION_CALLS', 1, true) then other[#other + 1] = k end
    end
    H.eq(table.concat(other, ' | '), '', 'idle: the only writes are the mission calls')
    H.ok(r.writes > 0, 'idle: a mission call was posted')
    local names = {}
    for _, e in ipairs(r.sent) do if e ~= 'crimson-police:client:missionCall' then names[#names + 1] = e end end
    H.eq(table.concat(names, ' '), '', 'idle: the only client events are the mission call cards')
    H.ok(r.reads < 600, ('idle: %d reads in 10 minutes (the cached officer checks)'):format(r.reads))
    -- the mission calls off: nothing written, nothing sent; a restart in between
    H.eq(Setting('MissionCalls.enabled', false), true, 'idle: mission calls off')
    W.Restart()
    Secs(150)                                 -- (the clean-up's catch-up run 120 s after a start)
    r = Idle()
    H.eq(r.writes, 0, 'idle, no mission calls: nothing written')
    H.eq(#r.sent, 0, 'idle, no mission calls: nothing sent')
    H.eq(next(r.fast), nil, 'idle, no mission calls: no fast thread')
    Act('server:admin:resetSetting', 5, { path = 'MissionCalls.enabled', reason = 'WF5E' })
end

_G.print = W.realPrint
if ON_DB then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db)) end

return H
