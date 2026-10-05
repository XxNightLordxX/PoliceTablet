-- Full admin control, end to end (P6): the packages together on the real server side. Retire and unretire with the
-- money that waits; an untested built-in override played under the same id and reset; a department added in game,
-- used and turned off with its pay still paid; a backup, a payment and a restore that pays nothing twice.

local H = dofile('tests/harness.lua')
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'admin_control_e2e')
local U = CP.U
local cjson = require('cjson')
local Act, Cb, Adv, Rid, Count = X.act, X.cb, X.adv, X.rid, X.count

local ADMIN = 5
-- fxmanifest loads the saves-folder engine in every storage mode (backups write with it)
if not (CP.Storage and CP.Storage.MemSQL) then H.load('modules/storage/memsql.lua') end
local function Secs(n) Adv(n * 1000) end

-- ============================================================================
--                   MONEY AND JOBS OF THE OUTSIDE RESOURCES
-- ============================================================================
-- Every Qbox AddMoney and every Renewed-Banking history entry is recorded: "paid once" is counted, not assumed.

local money, history = {}, {}
local function Wrap(p)
    if not p then return nil end
    p.Functions.AddMoney = function(account, amount, reason)
        money[#money + 1] = { citizenid = p.PlayerData.citizenid, account = account, amount = amount, reason = reason }
        return true
    end
    return p
end
do
    local Q = H.exportsMock.qbx_core
    local getPlayer, byCid, jobs = Q.GetPlayer, Q.GetPlayerByCitizenId, Q.GetJobs
    Q.GetPlayer = function(src) return Wrap(getPlayer(src)) end
    Q.GetPlayerByCitizenId = function(cid) return Wrap(byCid(cid)) end
    Q.GetJobs = function()
        local list = jobs()
        list.bcso = { label = 'BCSO', type = 'leo', grades = list.sast.grades }
        return list
    end
    local B = H.exportsMock['Renewed-Banking']
    B.handleTransaction = function(account, title, amount, message, issuer, receiver, transType, transId)
        local t = { account = account, amount = amount, type = transType, id = transId }
        history[#history + 1] = t
        return t
    end
end
local function PaidTo(cid)
    local n, sum = 0, 0
    for _, m in ipairs(money) do
        if m.citizenid == cid then n, sum = n + 1, sum + (tonumber(m.amount) or 0) end
    end
    return n, sum
end
local function EntriesFor(txn)
    local n = 0
    for _, t in ipairs(history) do if t.id == txn then n = n + 1 end end
    return n
end

X.addPlayer(7, 'AMOFF007', 'Rita', 'Retired', 'sast', 1)
X.addPlayer(8, 'AMBCS008', 'Bo', 'Deputy', 'bcso', 1)
H.players[7].identifiers = { 'license:7777777777777777777777777777777777777777' }
H.players[8].identifiers = { 'license:8888888888888888888888888888888888888888' }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local seq = 0
local function Uuid()
    seq = seq + 1
    return ('%08x-2222-4000-8000-%012x'):format(seq, 77)
end

-- A finished run row (cp_mission_runs, or the archive): id
local function Row(o)
    local t = o.archive and 'cp_mission_runs_archive' or 'cp_mission_runs'
    local owed = o.owed or 250
    local bd = {
        missionLabel = 'Beat Patrol',
        xpCounted = 1,
        cash = { B = owed, mTier = 1.0, mMod = 1.0, amount = owed, status = o.status or 'pending', paid = o.paid or 0 },
    }
    H.sql(
        ([[INSERT INTO %s (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_status, breakdown, created_at)
        VALUES (?, 'patrol', 'beat_patrol', ?, ?, 'completed', 'completed', 60, ?, ?, 1.00, ?, ?, ?,
        FROM_UNIXTIME(?))]]):format(t),
        {
            o.run or Uuid(),
            o.cid,
            o.dept or 'sast',
            o.points or 60,
            owed,
            o.paid or 0,
            o.status or 'pending',
            cjson.encode(bd),
            H.time - (o.ago or 3600),
        }
    )
    return Count(('SELECT MAX(id) AS n FROM %s'):format(t))
end
local function RowOf(id, archive)
    return H.sql(('SELECT * FROM %s WHERE id = ?'):format(archive and 'cp_mission_runs_archive' or 'cp_mission_runs'),
        { id })[1]
end
local function Txn(row) return ('CP-%s-%s'):format(row.run_uuid, row.citizenid) end
local function XpOf(cid) return Count('SELECT xp AS n FROM cp_officers WHERE citizenid = ?', { cid }) end

-- Steps the server until no admin job holds the busy lock.
local function Drain()
    for _ = 1, 4000 do
        if not CP.AdminKit.busy() then return true end
        H.step(0)
    end
    return false
end

local function BoardHas(cid, src)
    local b = Cb('getBoard', src or 1, { period = 'weekly', filter = 'overall' })
    for _, r in ipairs(b and b.rows or {}) do if r.citizenid == cid then return r end end
    return nil
end

local function Audits(action)
    return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action })
end

-- the fixture's natives answer "nobody drives": the Beat Patrol needs a driver in a police car
do
    _G.GetVehiclePedIsIn = function(ped)
        local p = H.players[math.floor((tonumber(ped) or 0) / 100)]
        return p and p.vehicle or 0
    end
    _G.GetPedInVehicleSeat = function(veh, seat)
        local e = X.ents[veh]
        if seat == -1 and e and e.driver then return e.driver * 100 end
        return 0
    end
    _G.GetEntityType = function(e)
        if X.ents[e] then return X.ents[e].type end
        local n = tonumber(e) or 0
        if n > 0 and n % 100 == 0 and H.players[n // 100] then return 1 end
        return 0
    end
end

-- every officer opens the tablet once (the officer rows and licenses)
for _, src in ipairs({ 1, 7 }) do X.async(function() return CP.Access.refreshOfficerRow(src) end) end

-- ============================================================================
--                            1. RETIRE AND UNRETIRE
-- ============================================================================
-- ROWS, BOARDS, TABLET, MONEY THAT WAITS.

do
    local cid = 'AMOFF007'
    local paidRow = Row({ cid = cid, status = 'paid', paid = 250, points = 80, ago = 7200 })
    local pendingRow = Row({ cid = cid, status = 'pending', points = 70, ago = 3600 })
    Row({ cid = cid, status = 'pending', points = 50, ago = 3600 })
    local archived = Row({ cid = cid, status = 'paid', paid = 250, points = 40, ago = 40 * 86400, archive = true })
    H.sql([[UPDATE cp_officers SET bio = 'Twenty years on the road' WHERE citizenid = ?]], { cid })
    X.async(function() return CP.Scoring.syncXp(cid) end)
    local xp0 = XpOf(cid)
    H.eq(xp0, 80 + 70 + 50 + 40, 'the officer\'s XP is the sum of their live and archived rows')
    H.ok(BoardHas(cid) ~= nil, 'the officer is on the weekly board')
    local paidBefore = PaidTo(cid)

    local pv = Cb('admin:previewRetire', ADMIN, { citizenid = cid })
    H.ok(pv and pv.previewToken, 'Retire shows its preview first')
    local ok, e = Act('server:admin:retireOfficer', ADMIN, {
        citizenid = cid,
        reason = 'Left the server',
        confirm = cid,
        previewToken = pv and pv.previewToken,
        requestId = Rid(),
    })
    H.eq(ok, true, 'retired: ' .. tostring(e))
    Drain()
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 0', { cid }), 0,
        'every live row is voided as a correction')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs_archive WHERE citizenid = ? AND voided = 0', { cid }), 0,
        'and every archived row')
    H.eq(BoardHas(cid), nil, 'the rows left the boards')
    H.eq(XpOf(cid), 0, 'XP from the rows: 0')
    local okT, eT = CP.Access.getOfficer(7)
    H.ok(not okT and eT == 'err.retired', 'the tablet refuses a retired officer: ' .. tostring(eT))

    -- the officer logs off; the dispute window passes: the held cash of the voided rows is forfeited
    local pd7 = X.PD[7]
    X.PD[7] = nil
    H.time = H.time + math.floor((tonumber(Config.Disputes.windowHours) or 48) * 3600) + 60
    local n = X.async(function() return CP.Cash._forfeitureJob() end)
    H.eq(n, 2, 'the forfeiture job forfeits the two pending rows')
    local ledger = Cb('admin:getPayments', ADMIN, { citizenid = cid })
    local byId = {}
    for _, r in ipairs(ledger and ledger.rows or {}) do byId[r.id] = r end
    H.eq(byId[pendingRow] and byId[pendingRow].status, 'forfeited', 'Payments shows the pending cash forfeited')
    H.eq(byId[paidRow] and byId[paidRow].status, 'paid', 'and the paid row still paid')
    H.eq(PaidTo(cid), paidBefore, 'nothing was paid or taken back while retired')

    ok, e = Act('server:admin:unretireOfficer', ADMIN, { citizenid = cid, reason = 'Came back', requestId = Rid() })
    H.eq(ok, true, 'unretired: ' .. tostring(e))
    Drain()
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 1', { cid }), 0,
        'the live rows are restored')
    H.eq(RowOf(archived, true).voided ~= nil and H.bit(RowOf(archived, true).voided), 0, 'and the archived row')
    H.eq(XpOf(cid), xp0, 'XP is back to the sum of the rows')
    H.ok(BoardHas(cid) ~= nil, 'back on the weekly board')
    local prof = H.sql('SELECT bio, retired_at FROM cp_officers WHERE citizenid = ?', { cid })[1]
    H.ok(prof.bio == 'Twenty years on the road' and prof.retired_at == nil, 'the profile is as it was')
    H.eq(RowOf(pendingRow).cash_status, 'pending', 'the batch-caused forfeit is back to pending')
    H.eq(RowOf(paidRow).cash_status, 'paid', 'paid cash stayed paid throughout')

    -- the officer logs in: paid exactly once, however often the login sweep runs
    X.PD[7] = pd7
    H.ok(CP.Access.getOfficer(7) ~= nil, 'the tablet opens again')
    X.async(function() return CP.Cash.payPending(7) end)
    X.async(function() return CP.Cash.payPending(7) end)
    H.eq(RowOf(pendingRow).cash_status, 'paid', 'the pending row is paid at login')
    H.eq(EntriesFor(Txn(RowOf(pendingRow))), 1, 'one bank entry for it')
    local count, sum = PaidTo(cid)
    H.eq(count - paidBefore, 2, 'two payments in all (the two rows), each once')
    H.eq(sum, 500, 'and the right amount')
    H.ok(Audits('retireOfficer') == 1 and Audits('unretireOfficer') == 1, 'retire and unretire are audited')
end

-- ============================================================================
--    2. AN UNTESTED BUILT-IN OVERRIDE PLAYS UNDER THE SAME ID, THEN A RESET
-- ============================================================================

do
    local ID, src, cid = 'beat_patrol', 1, 'AMOFF001'
    H.eq(Config.Builder.requireTestToPublish, false, 'testing is not required (shipped default)')
    local okE, ed = Act('server:builder:editBuiltin', ADMIN, { id = ID })
    H.eq(okE, true, 'an admin opens Beat Patrol in the Mission Builder: ' .. tostring(ed))
    local def = cjson.decode(cjson.encode(U.serialize(ed.record.definition)))
    def.label = 'Beat Patrol (edited)'
    local okS, s = Act('server:builder:save', ADMIN, { id = ID, definition = def })
    H.eq(okS, true, 'the edit is saved: ' .. tostring(s))
    local okP, p = Act('server:builder:publish', ADMIN, { id = ID })
    H.eq(okP, true, 'and published without a test: ' .. tostring(p))
    local live = CP.Missions.get(ID)
    H.ok(live and live.overridden == true and live.id == ID, 'the override plays under the same id')

    -- two earlier runs this week, so this run ranks the officer on the board
    for _ = 1, 2 do Row({ cid = cid, status = 'paid', paid = 250, points = 50, ago = 20 * 3600 }) end
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    H.players[src].coords = vec3(200.0, -1000.0, 29.0)
    local okA, a = Act('server:acceptType', src, 'patrol')
    H.eq(okA, true, 'the officer accepts a Patrol from the board: ' .. tostring(a))
    local run = CP.Runs.getBySrc(src)
    H.eq(run and run.missionId, ID, 'the draw gives the override, under the same id')
    H.eq(run and run.mission and run.mission.label, 'Beat Patrol (edited)', 'with the admin\'s text')

    local c = H.players[src].coords
    local veh = CreateVehicle('police3', c.x, c.y, c.z, 0.0)
    X.ents[veh].driver = src
    H.players[src].vehicle = veh
    H.players[src].coords = run.location.start.coords
    X.ents[veh].coords = H.players[src].coords
    Secs(2)
    H.eq(run.state, 'in_progress', 'the officer reaches the start')
    H.fire('crimson-police:server:telemetry', src, run.id, 'vehicle', { netId = X.ents[veh].net })
    local st = run.objectives[1].state
    for k = 1, #(st.points or {}) do
        Secs(15)
        H.players[src].coords = st.points[k]
        X.ents[veh].coords = st.points[k]
        Secs(10)
        H.fire('crimson-police:server:objective', src, run.id, 1,
            { type = 'checkpoint', index = k, netId = X.ents[veh].net })
    end
    Secs(2)
    H.eq(run.state, 'ended', 'every checkpoint done: the run ended')
    local r = H.sql('SELECT * FROM cp_mission_runs WHERE run_uuid = ?', { run.id })[1] or {}
    H.eq(r.mission_id, ID, 'the row has the built-in\'s id')
    H.eq(r.state, 'completed', 'completed')
    H.eq(r.cash_status, 'paid', 'the payout follows the id: paid')
    H.eq(tonumber(r.cash_paid), 250, 'the Patrol type payout (no payout field in a mission file)')
    H.eq(EntriesFor(Txn(r)), 1, 'one bank entry')
    local cd = CP.Runs.cooldowns(cid)
    H.ok((cd.missions[ID] or 0) > os.time(), 'the cooldown follows the id')
    local b = BoardHas(cid)
    H.ok(b ~= nil and b.runs == 3, 'the board counts the run under the id')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
    H.players[src].vehicle = nil

    local okR, rr = Act('server:builder:resetBuiltin', ADMIN, { id = ID, reason = 'back to stock', confirm = ID })
    H.eq(okR, true, 'Reset to original: ' .. tostring(rr))
    live = CP.Missions.get(ID)
    H.ok(live and not live.overridden and live.label == 'Beat Patrol', 'the shipped Beat Patrol plays again')
    H.ok(Audits('publishUntested') == 1 and Audits('overrideReset') == 1, 'publish untested and the reset are audited')
end

-- ============================================================================
--                        3. A DEPARTMENT ADDED IN GAME
-- ============================================================================
-- USED, PAID, TURNED OFF, STILL PAID.

do
    local cid = 'AMBCS008'
    local _, eNP = CP.Access.getOfficer(8)
    H.eq(eNP, 'err.not_police', 'the bcso deputy can\'t open the tablet yet')
    local ok, e = Act('server:admin:addDepartment', ADMIN, {
        key = 'bcso',
        label = 'Blaine County Sheriff',
        short = 'BCSO',
        jobs = { 'bcso' },
        supervisorGrade = 3,
        themeFrom = 'sast',
    })
    H.eq(ok, true, 'a department is added in game: ' .. tostring(e))
    local o = CP.Access.getOfficer(8)
    H.ok(o and o.department == 'bcso', 'the deputy opens the tablet as BCSO')
    X.async(function() return CP.Access.refreshOfficerRow(8) end)

    H.eq(Config.Cash.source, 'server', 'pay comes from the default source (the server)')
    local first = Row({ cid = cid, dept = 'bcso', status = 'pending' })
    X.async(function() return CP.Cash.pay(first) end)
    H.eq(RowOf(first).cash_status, 'paid', 'a BCSO run is paid')
    H.eq(EntriesFor(Txn(RowOf(first))), 1, 'once')

    local second = Row({ cid = cid, dept = 'bcso', status = 'pending' })
    ok, e = Act('server:admin:setDepartmentEnabled', ADMIN,
        { key = 'bcso', enabled = false, reason = 'merged into SAST', confirm = 'BCSO' })
    H.eq(ok, true, 'the department is turned off: ' .. tostring(e))
    local _, eOff = CP.Access.getOfficer(8)
    H.ok(eOff ~= nil, 'its job no longer opens the tablet: ' .. tostring(eOff))
    X.async(function() return CP.Cash.payPending(8) end)
    H.eq(RowOf(second).cash_status, 'paid', 'its pending pay still pays')
    H.eq(EntriesFor(Txn(RowOf(second))), 1, 'once')
    local n, sum = PaidTo(cid)
    H.ok(n == 2 and sum == 500, 'two payments, $500')
end

-- ============================================================================
--                           4. BACK UP, PAY, RESTORE
-- ============================================================================
-- STAYS PAID, NOTHING PAYS TWICE, AUDIT KEPT.

do
    -- backups go to this run's scratch resource folder, never into the tree
    local realPath = _G.GetResourcePath
    _G.GetResourcePath = function() return H.resourcePath() end
    os.execute(('mkdir -p \'%s\''):format(H.resourcePath()))
    local cid = 'AMOFF007'
    local id = Row({ cid = cid, status = 'pending' })
    local ok, b = Act('server:admin:backupNow', ADMIN, {})
    H.ok(ok == true and b and b.name, 'a backup is made: ' .. tostring(type(b) == 'table' and b.name or b))
    local before = PaidTo(cid)

    local okP, pd = Act('server:admin:payNow', ADMIN, { rowId = id, requestId = Rid() })
    H.ok(okP == true and pd and pd.status == 'paid', 'Payments → Pay now pays the row: ' .. tostring(pd and pd.status))
    H.eq(PaidTo(cid), before + 1, 'one payment')
    local line = H.sql('SELECT id FROM cp_audit WHERE action = ? AND target LIKE ?',
        { 'paymentRetry', '#' .. id .. ' %' })
    H.eq(#line, 1, 'the payment is in the audit log')

    for _ = 1, 3 do H.step(1000) end
    local pv = Cb('admin:previewRestore', ADMIN, { name = b.name })
    H.ok(pv and pv.previewToken, 'the restore preview')
    local okR, rr = Act('server:admin:restoreBackup', ADMIN, {
        name = b.name,
        previewToken = pv and pv.previewToken,
        reason = 'drill',
        confirm = 'RESTORE',
        requestId = Rid(),
    })
    H.ok(okR == true and type(rr) == 'table' and rr.restart == true,
        'restored, and the owner is asked to restart: ' .. tostring(type(rr) == 'table' and rr.backup or rr))
    H.eq(RowOf(id).cash_status, 'paid', 'the row paid after the backup stays paid')
    H.eq(#H.sql('SELECT id FROM cp_audit WHERE action = ? AND target LIKE ?', { 'paymentRetry', '#' .. id .. ' %' }), 1,
        'the audit log still has the payment line')
    X.async(function() return CP.Cash.payPending(7) end)
    H.eq(PaidTo(cid), before + 1, 'nothing pays twice (the restore lock holds payments, and the row is paid)')
    H.eq(EntriesFor(Txn(RowOf(id))), 1, 'one bank entry for it')
    H.eq((CP.Maintenance.active()), 'restore', 'the restore lock holds until the owner restarts')
    _G.GetResourcePath = realPath
end

X.cleanup()
return H
