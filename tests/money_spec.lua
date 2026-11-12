-- The money module (modules/money): one money engine (CP.Money) that every payment goes through. A mission's cash,
-- a feature reward and an admin money tool all write their ledger row, hand it to CP.Cash and deposit the money the
-- same way: where it goes (accountOf), the deposit (deposit), the row (writeRow) and the hand-over (settle).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

local function Read(path)
    local fh = assert(io.open(H.root .. path, 'r'))
    local s = fh:read('a')
    fh:close()
    return s
end

local function Exists(path)
    local fh = io.open(H.root .. path, 'r')
    if fh then fh:close() end
    return fh ~= nil
end

-- ============================================================================
--                   THE MODULE: ONE HOME, NO PRIVATE COPIES
-- ============================================================================

local PARTS = { 'engine', 'cash', 'featurerewards', 'payments', 'payouts', 'rewards' }
for _, f in ipairs(PARTS) do
    H.ok(Exists('modules/money/' .. f .. '.lua'), 'modules/money/' .. f .. '.lua exists')
    if f ~= 'engine' then
        H.ok(not Exists('modules/' .. f .. '/server.lua'), 'the old modules/' .. f .. ' folder is gone')
    end
end
local manifest = Read('fxmanifest.lua')
local at = manifest:find('\'modules/money/engine.lua\'', 1, true)
H.ok(at ~= nil, 'the manifest loads the engine')
for _, f in ipairs(PARTS) do
    local p = manifest:find('\'modules/money/' .. f .. '.lua\'', 1, true)
    H.ok(p ~= nil and p >= at, 'the manifest loads ' .. f .. ' after the engine')
end
for _, f in ipairs(PARTS) do
    local src = Read('modules/money/' .. f .. '.lua')
    H.ok(not src:find('local function Num(', 1, true), f .. ': no private Num (CP.Num)')
    H.ok(not src:find('local function ValidCid', 1, true), f .. ': no private citizenid check (CP.ValidCid)')
    H.ok(not src:find('giveMoneyItem', 1, true), f .. ': the money item is given by the engine only')
end
for _, f in ipairs({ 'featurerewards', 'payments' }) do
    local src = Read('modules/money/' .. f .. '.lua')
    H.ok(not src:find('INSERT INTO cp_mission_runs', 1, true), f .. ': its ledger row is written by the engine')
    H.ok(src:find('CP.Money.writeRow', 1, true) and src:find('CP.Money.settle', 1, true), f .. ': writes and settles')
end
-- FIN8: one clock, one set of statement helpers, one season and department lookup for the whole module, and the
-- forfeiture jobs always run through the jobs engine (no fallback for a missing schedule)
for _, f in ipairs(PARTS) do
    local src = Read('modules/money/' .. f .. '.lua')
    H.ok(not src:find('local function Now()', 1, true), f .. ': no private clock (CP.now)')
    H.ok(not src:find('pcall(MySQL.query.await, sql', 1, true), f .. ': its queries go through CP.query')
    H.ok(not src:find('pcall(MySQL.scalar.await, sql', 1, true), f .. ': its scalars go through CP.scalar')
    H.ok(not src:find('pcall(MySQL.update.await, sql', 1, true), f .. ': its updates go through CP.update')
    H.ok(not src:find('local function SeasonId', 1, true), f .. ': the season is CP.Money.seasonId')
    H.ok(not src:find('local function DeptOf', 1, true), f .. ': the department is CP.Money.department')
    H.ok(not src:find('or ForfeitureJob', 1, true), f .. ': the forfeiture job runs through CP.Schedule.job only')
end
local cashSrc = Read('modules/money/cash.lua')
H.ok(not cashSrc:find('CP.Qbx.addMoney(', 1, true), 'cash: every deposit goes through CP.Money.deposit')
local _, deposits = cashSrc:gsub('CP%.Money%.deposit%(', '')
H.eq(deposits, 1, 'cash: one deposit through the engine (H3: DepositChecked, which reads the balance around it)')
local _, checked = cashSrc:gsub('= DepositChecked%(', '')
H.eq(checked, 2, 'cash: the payment, and Pay again and the capped rest (MoveLocked), deposit through DepositChecked')

H.eq(CP.ValidCid('MN_OFFICER-1'), true, 'CP.ValidCid: a citizenid')
H.eq(CP.ValidCid('a b'), false, 'CP.ValidCid: not one')

-- ============================================================================
--                                    STUBS
-- ============================================================================

local online = { [7] = 'MN_OFFICER1' }
local moneyCalls = {}
CP.Qbx = {
    getInfo = function(src)
        local cid = online[tonumber(src)]
        return cid and { citizenid = cid, name = cid } or nil
    end,
    getByCitizenId = function(cid)
        for src, c in pairs(online) do if c == cid then return src end end
        return nil
    end,
    addMoney = function(src, account, amount)
        moneyCalls[#moneyCalls + 1] = { src = src, account = account, amount = amount }
        return true
    end,
    onPlayerLoaded = function() end,
    onDutyChange = function() end,
}
CP.Tablet = { notify = function() end, push = function() end, notifyMany = function() end }
CP.Admin = CP.Admin or {}
CP.Admin.audit = function() end
local inv = H.mockInventory({ black_money = { label = 'Dirty money' } })

H.load('modules/system/schedule.lua')
H.load('modules/money/engine.lua')
H.load('modules/money/rewards.lua')
H.load('modules/money/cash.lua')
H.load('modules/money/featurerewards.lua')
H.advance(5000)
local M = CP.Money

-- ============================================================================
--                                SHARED LOOKUPS
-- ============================================================================

do
    local savedC = CP.Challenge
    CP.Challenge = {
        currentSeason = function() return { id = 4.0 } end,
    }
    H.eq(M.seasonId(), 4, 'seasonId: the running season')
    CP.Challenge = {
        currentSeason = function() return nil end,
    }
    H.eq(M.seasonId(), nil, 'seasonId: none running')
    CP.Challenge = savedC
    local savedD, savedA = Config.Departments, CP.Access
    CP.Access = {
        department = function() return nil end,
    }
    Config.Departments = { gone = { label = 'Gone', jobs = { 'gonejob' } } }
    local d = M.department('gone')
    H.ok(d and d.label == 'Gone' and d.societyAccount == 'gonejob', 'department: a turned-off one, its first job')
    H.eq(M.department('nope'), nil, 'department: an unknown key is none')
    Config.Departments, CP.Access = savedD, savedA
    H.eq(CP.Cash.department, nil, 'one department lookup: CP.Cash keeps no copy')
end

-- ============================================================================
--                                WHERE IT GOES
-- ============================================================================

Config.Cash.account = 'bank'
H.eq((M.accountOf({})), 'bank', 'a mission row: Config.Cash.account')
Config.Cash.account = 'cash'
H.eq((M.accountOf(nil)), 'cash', 'no breakdown: Config.Cash.account')
Config.Cash.account = 'bank'
H.eq((M.accountOf({ account = 'cash' })), 'cash', 'a feature reward\'s own account')
local a, item = M.accountOf({ account = 'item', moneyItem = 'black_money' })
H.ok(a == 'item' and item == 'black_money', 'a money item account names its item')
H.eq((M.accountOf({ account = 'item' })), 'bank', 'an item account without its item: the server account')

-- ============================================================================
--                                 THE DEPOSIT
-- ============================================================================

H.eq(M.deposit(7, 'bank', nil, 0), true, 'nothing to pay: done')
H.eq(M.deposit(7, 'cash', nil, 120), true, 'a Qbox account')
H.ok(moneyCalls[#moneyCalls].account == 'cash' and moneyCalls[#moneyCalls].amount == 120, 'into that account')
local nQbx = #moneyCalls
H.eq(M.deposit(7, 'item', 'black_money', 40), true, 'a money item')
H.eq(#moneyCalls, nQbx, 'never a Qbox account named item')
H.eq(inv.added[#inv.added] and inv.added[#inv.added].count, 40, 'as many items as dollars')
H.eq(M.deposit(7, 'item', nil, 40), false, 'an item account without its item: refused')
local savedCall = CP.Ext.call
CP.Ext.call = function(res, fn, ...)
    if fn == 'AddItem' then return false, 'boom' end
    return savedCall(res, fn, ...)
end
local okR, whyR = M.deposit(7, 'item', 'black_money', 5)
CP.Ext.call = savedCall
H.ok(okR == false and whyR == 'error', 'a deposit that raised says so (never retried automatically)')

-- ============================================================================
--                 EACH OLD PAYMENT, DRIVEN THROUGH THE ENGINE
-- ============================================================================

local function Spy(name)
    local real, seen = M[name], {}
    M[name] = function(...)
        seen[#seen + 1] = { ... }
        return real(...)
    end
    return seen, function() M[name] = real end
end

-- a written row (the shape of every payment that is not a mission run): paid by CP.Cash, deposited by the engine
local deposited, undoDeposit = Spy('deposit')
local id = M.writeRow({
    runUuid = 'mn-row-1',
    missionId = 'manual_cash',
    citizenid = 'MN_OFFICER1',
    department = 'lspd',
    amount = 250,
    label = 'Manual payment',
    kind = 'manual_cash',
    by = 'tester',
})
H.ok(id ~= nil, 'writeRow: one ledger row')
local row = H.sql('SELECT mission_type, cash_status, cash_base FROM cp_mission_runs WHERE id = ?', { id })[1]
H.ok(row and row.mission_type == 'manual_award' and row.cash_status == 'none' and tonumber(row.cash_base) == 250,
    'a manual award row, waiting (none) until it is settled')
H.eq(M.rowOf('mn-row-1', 'MN_OFFICER1'), id, 'rowOf finds it')
H.eq(M.rowOf('mn-row-1'), id, 'rowOf finds it for anyone')
H.eq(M.settle(id), 'paid', 'settle: CP.Cash pays it')
H.eq(#deposited, 1, 'through the engine\'s deposit')
H.ok(deposited[1][2] == 'bank' and deposited[1][4] == 250, 'into Config.Cash.account, the row\'s amount')
undoDeposit()

-- feature rewards: FR.pay writes its row with its account and settles it through the engine
Config.FeatureRewards.surrender.enabled = true
Config.FeatureRewards.surrender.account = 'cash'
local wrote, undoWrite = Spy('writeRow')
local settled, undoSettle = Spy('settle')
local res = CP.FeatureRewards.pay('surrender', 'MN_OFFICER1', { key = 'mn-case-1' })
undoWrite()
undoSettle()
H.eq(res and res.status, 'paid', 'a feature reward is paid')
local spec = wrote[1] and wrote[1][1] or {}
H.ok(spec.missionId == 'reward_surrender' and spec.kind == 'feature_reward', 'its row is written by the engine')
H.eq(spec.cash and spec.cash.account, 'cash', 'with the feature\'s own account')
H.eq(#settled, 1, 'and settled by the engine')
H.eq(moneyCalls[#moneyCalls].account, 'cash', 'deposited into that account')
local again, why = CP.FeatureRewards.pay('surrender', 'MN_OFFICER1', { key = 'mn-case-1' })
H.ok(again == nil and why == 'duplicate', 'the same case pays once')
-- H3: a restart in the middle of a feature reward (here: the audit row's write never comes back, as when the server
-- restarts during that await) leaves a payable row: the login sweep pays it, once
local realAudit = CP.Admin.audit
CP.Admin.audit = function() Wait(1e9) end
local paid0 = #moneyCalls
CreateThread(function() CP.FeatureRewards.pay('surrender', 'MN_OFFICER1', { key = 'mn-case-cut' }) end)
H.step(0)
CP.Admin.audit = realAudit
local cutRow = H.sql([[SELECT id, cash_status FROM cp_mission_runs WHERE mission_id = 'reward_surrender'
    ORDER BY id DESC LIMIT 1]])[1]
H.eq(cutRow and cutRow.cash_status, 'pending', 'H3: a feature reward cut before its pay is payable (pending)')
H.eq(CP.Cash.payPending(7), 1, 'H3: her login pays it')
H.eq(#moneyCalls - paid0, 1, 'H3: once')
H.eq(CP.Cash.payPending(7), 0, 'H3: and never again')
Config.FeatureRewards.surrender.enabled = false

-- H2: a completed run row whose breakdown is NULL (or JSON that does not decode) is still paid: CP.Cash reads the
-- breakdown as {} instead of raising, which used to send the row back to pending on every try
local nullId = MySQL.insert.await([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid,
  department, participants, departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points,
  final_points, cash_base, cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
  VALUES ('mn-nullbd-1', 'patrol', 'some_mission', 'MN_OFFICER1', 'lspd', 1, 1, 'standard', 'completed', 'completed',
  0, 0, 0, 0, 300, 1.00, 0, 'none', 0, NULL, 0, 0, FROM_UNIXTIME(?))]], { CP.now() })
local depNull, undoNull = Spy('deposit')
H.eq(CP.Cash.pay(nullId), 'paid', 'a run row with a NULL breakdown is paid')
undoNull()
H.eq(#depNull, 1, 'with exactly one deposit')
H.eq(depNull[1] and depNull[1][4], 300, 'of the row\'s cash')
local nullRow = H.sql('SELECT cash_status FROM cp_mission_runs WHERE id = ?', { nullId })[1]
H.eq(nullRow and nullRow.cash_status, 'paid', 'and the row says paid')

return H
