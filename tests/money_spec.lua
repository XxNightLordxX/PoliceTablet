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
local cashSrc = Read('modules/money/cash.lua')
H.ok(not cashSrc:find('CP.Qbx.addMoney(', 1, true), 'cash: every deposit goes through CP.Money.deposit')
local _, deposits = cashSrc:gsub('CP%.Money%.deposit%(', '')
H.eq(deposits, 3, 'cash: the payment, Pay again and the capped rest deposit through the engine')

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
Config.FeatureRewards.surrender.enabled = false

return H
