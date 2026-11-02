-- Feature rewards (step G3, Config.FeatureRewards): money and items for the volunteer suspect, the officer who talks a

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local online = { [7] = 'FR_SUSPECT1', [8] = 'FR_OFFICER1' }
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
local audits = {}
CP.Admin.audit = function(_, _, _, action, target, _, new, reason)
    audits[#audits + 1] = { action = action, target = target, new = new, reason = reason }
end

local inv = H.mockInventory({ water = { label = 'Water' }, black_money = { label = 'Dirty money' } })

H.load('modules/schedule/server.lua')
H.load('modules/rewards/server.lua')
H.load('modules/cash/server.lua')
H.load('modules/featurerewards/server.lua')
H.advance(5000)
local FR = CP.FeatureRewards
local FC = Config.FeatureRewards

local function Row(runUuid)
    return H.sql(
        'SELECT id, mission_type, mission_id, citizenid, department, cash_base, cash_status, cash_paid, '
            .. 'breakdown FROM cp_mission_runs WHERE run_uuid = ?',
        { runUuid }
    )
end

-- ============================================================================
--                    SHIPPED: OFF, WITH MONEY READY TO USE
-- ============================================================================

for _, f in ipairs(FR.FEATURES) do
    H.eq(FC[f].enabled, false, f .. ' ships off')
    H.eq(FR.enabled(f), false, f .. ': nothing pays while it is off')
    H.ok(type(FC[f].items) == 'table' and #FC[f].items == 0, f .. ': no items until the owner adds some')
end
H.ok(FR.money('suspect', { outcome = 'got_away' }) > 0, 'suspect: escaping has a default amount')
H.ok(FR.money('suspect', { outcome = 'booked' }) > 0, 'suspect: a caught suspect has a default amount')
for _, f in ipairs({ 'surrender', 'ftoSignOff', 'ftoComplete' }) do
    H.ok(FR.money(f) > 0, f .. ': a default amount')
end
H.ok(FR.money('supAward', { points = 10 }) > 0, 'supAward: a default amount per point')
H.eq(Config.Rewards.enabled, false, 'the item switch keeps its shipped value')
H.eq((FR.pay('surrender', 'FR_OFFICER1', { key = 'x' })), nil, 'off: no payment')

-- ============================================================================
--                                 THE AMOUNTS
-- ============================================================================

H.eq(FR.money('suspect', { outcome = 'got_away' }), FC.suspect.money.got_away, 'escaped pays got_away')
H.eq(FR.money('suspect', { outcome = 'detained' }), FC.suspect.money.caught, 'detained pays caught')
H.eq(FR.money('suspect', { outcome = 'left' }), 0, 'left pays nothing')
H.eq(FR.money('suspect', { outcome = 'void' }), 0, 'void pays nothing')
-- step H1: per mission type money for the suspect, falling back to the per-outcome default
H.eq(type(FC.suspect.byType) == 'table' and next(FC.suspect.byType), nil, 'byType ships empty')
H.eq(FR.money('suspect', { outcome = 'got_away', missionType = 'investigation' }), FC.suspect.money.got_away,
    'byType empty: a type pays the default')
FC.suspect.byType = { investigation = { got_away = 2000 } }
H.eq(FR.money('suspect', { outcome = 'got_away', missionType = 'investigation' }), 2000, 'a set type pays its amount')
H.eq(FR.money('suspect', { outcome = 'booked', missionType = 'investigation' }), FC.suspect.money.caught,
    'an outcome the type leaves out pays the default')
H.eq(FR.money('suspect', { outcome = 'got_away', missionType = 'patrol' }), FC.suspect.money.got_away,
    'another type pays the default')
H.eq(FR.money('suspect', { outcome = 'got_away' }), FC.suspect.money.got_away, 'no type: the default')
FC.suspect.byType = {}
H.eq(FR.money('supAward', { points = 3 }), 3 * FC.supAward.money, 'supAward: per point')
H.eq(FR.money('supAward', { points = 100000 }), FC.supAward.maxMoney, 'supAward: up to maxMoney')

-- ============================================================================
--                          A FAIR CASE (THE SUSPECT)
-- ============================================================================

local fair = { citizenid = 'FR_SUSPECT1', outcome = 'got_away', engaged = true }
H.eq(FR.fairSuspect(fair, false), true, 'officers reached him and he escaped: fair')
H.eq(FR.fairSuspect({ citizenid = 'X1', outcome = 'got_away', engaged = false }), false, 'never reached: no pay')
H.eq(FR.fairSuspect({ citizenid = 'X1', outcome = 'booked', engaged = true, dropout = 'left' }), false,
    'a dropout: no pay')
H.eq(FR.fairSuspect({ citizenid = 'X1', outcome = 'detained', engaged = true }, true), false, 'AFK: no pay')
H.eq(FR.fairSuspect({ citizenid = 'X1', outcome = 'void', engaged = true }), false, 'a void part: no pay')
H.eq(FR.suspectEnded('run-a', fair, false), false, 'switch off: suspectEnded pays nothing')

-- ============================================================================
--                   A PAYMENT: ONE LEDGER ROW, ONCE PER CASE
-- ============================================================================

FC.suspect.enabled = true
FC.suspect.account = 'cash'
local res = FR.pay('suspect', 'FR_SUSPECT1', { key = 'run-fair-1', outcome = 'got_away' })
H.ok(res and res.rowId, 'a fair case is paid')
H.eq(res and res.status, 'paid', 'he is online: paid at once')
local uuid = FR.uuidOf('suspect', 'run-fair-1', 'FR_SUSPECT1')
H.ok(#uuid <= 36, 'the row id fits run_uuid')
local row = Row(uuid)[1]
H.eq(row and row.mission_type, 'manual_award', 'a manual award row: out of the run counts')
H.eq(row and row.mission_id, 'reward_suspect', 'its mission id names the feature')
H.eq(row and row.department, 'none', 'a suspect has no department')
H.eq(row and tonumber(row.cash_paid), FC.suspect.money.got_away, 'the ledger holds what was paid')
local bd = row and CP.U.jsonField(row.breakdown) or {}
H.eq(bd.cash and bd.cash.source, 'server', 'a suspect is always paid new money')
local last = moneyCalls[#moneyCalls]
H.eq(last and last.account, 'cash', 'paid into the feature\'s account')
H.eq(last and last.amount, FC.suspect.money.got_away, 'the outcome\'s amount')
H.eq(audits[#audits] and audits[#audits].action, 'featureReward', 'audited')
local n = #moneyCalls
local again, why = FR.pay('suspect', 'FR_SUSPECT1', { key = 'run-fair-1', outcome = 'got_away' })
H.eq(again, nil, 'the same case again: nothing')
H.eq(why, 'duplicate', '...it is a duplicate')
H.eq(#moneyCalls, n, 'no second payment')

-- dirty money as an item
FC.suspect.account = 'item'
FC.suspect.moneyItem = 'black_money'
res = FR.pay('suspect', 'FR_SUSPECT1', { key = 'run-fair-2', outcome = 'booked' })
H.eq(res and res.status, 'paid', 'paid as an item')
H.eq(#moneyCalls, n, 'no Qbox money moved')
local got = 0
for _, a in ipairs(inv.added) do if a.name == 'black_money' then got = got + a.count end end
H.eq(got, FC.suspect.money.caught, 'the dirty-money item, as many as the dollars')
FC.suspect.account = 'cash'

-- offline: pending until login
online[7] = nil
res = FR.pay('suspect', 'FR_SUSPECT1', { key = 'run-fair-3', outcome = 'got_away' })
H.eq(res and res.status, 'pending', 'offline: pending in the ledger')
online[7] = 'FR_SUSPECT1'
FC.suspect.enabled = false

-- ============================================================================
--               ITEMS: ADDED PER FEATURE, UNDER THE ITEM SWITCH
-- ============================================================================

FC.surrender.enabled = true
FC.surrender.items = { { item = 'water', count = 2, chance = 1.0, value = 10 } }
res = FR.pay('surrender', 'FR_OFFICER1', { key = 'run-x:FR_SUSPECT1' })
H.ok(res and #res.items == 1, 'the item is rolled')
H.eq(#H.sql('SELECT id FROM cp_item_rewards WHERE citizenid = ?', { 'FR_OFFICER1' }), 0,
    'Config.Rewards.enabled off: no item row')
Config.Rewards.enabled = true
res = FR.pay('surrender', 'FR_OFFICER1', { key = 'run-y:FR_SUSPECT1' })
local items = H.sql('SELECT source, source_key, item, count FROM cp_item_rewards WHERE citizenid = ?',
    { 'FR_OFFICER1' })
H.eq(#items, 1, 'item switch on: the item is stored')
H.eq(items[1] and items[1].source, 'run', 'a run reward of the ledger row')
H.eq(items[1] and items[1].source_key, FR.uuidOf('surrender', 'run-y:FR_SUSPECT1', 'FR_OFFICER1'), 'keyed by the row')
H.eq(items[1] and tonumber(items[1].count), 2, 'the configured count')
FC.surrender.items = { { item = 'water', count = 1, chance = 0.0 } }
H.eq(#FR.rollItems('surrender', 'k', 'FR_OFFICER1'), 0, 'chance 0: never')
Config.Rewards.enabled = false
FC.surrender.items = {}
FC.surrender.enabled = false

-- ============================================================================
--                             SETTINGS: THE CHECKS
-- ============================================================================

H.eq(FR.checkSetting('FeatureRewards.suspect.items', { { item = 'water', count = 1 } }), nil, 'a known item')
H.eq(FR.checkSetting('FeatureRewards.suspect.items', { { item = 'nope_item' } }), 'err.feature_reward_unknown_item',
    'an item ox_inventory does not know is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.items', { { item = 'WEAPON_PISTOL' } }), 'err.reward_item_forbidden',
    'a weapon is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.items', { { item = 'water', chance = 2 } }), 'err.reward_chance',
    'chance above 1 is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.moneyItem', 'nope_item'), 'err.feature_reward_unknown_item',
    'an unknown money item is refused')
-- step H1: suspect.byType names known mission types and dollars by outcome only
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', {}), nil, 'an empty byType')
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', { tactical = { got_away = 3000, caught = 900 } }), nil,
    'a known type with both outcomes')
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', { nope = { got_away = 1 } }), 'err.feature_reward_by_type',
    'an unknown mission type is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', { patrol = { left = 1 } }), 'err.feature_reward_by_type',
    'an unknown outcome is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', { patrol = { caught = -5 } }), 'err.feature_reward_by_type',
    'a negative amount is refused')
H.eq(FR.checkSetting('FeatureRewards.suspect.byType', 'x'), 'err.feature_reward_by_type', 'not a table: refused')

-- step H1: a fair case pays its mission type's amount (suspectEnded passes the type on)
FC.suspect.enabled = true
FC.suspect.byType = { tactical = { got_away = 3100 } }
local nTyped = #moneyCalls
H.eq(FR.suspectEnded(
    'run-typed-1',
    { citizenid = 'FR_SUSPECT1', outcome = 'got_away', engaged = true, missionType = 'tactical' },
    false
), true, 'a fair tactical case is paid')
H.advance(100)
H.eq(moneyCalls[nTyped + 1] and moneyCalls[nTyped + 1].amount, 3100, 'it pays the tactical amount')
FC.suspect.byType = {}
FC.suspect.enabled = false

return H
