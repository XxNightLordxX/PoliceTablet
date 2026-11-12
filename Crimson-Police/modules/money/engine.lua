-- CP.Money (server): the one money engine. Every payment Crimson-Police makes goes through here: a mission's cash (the
-- run engine writes its ledger row), a feature reward (CP.FeatureRewards: the volunteer suspect, a surrender, field
-- training, supervisor awards) and an admin money tool (CP.Payments: manual cash, Pay again, the capped rest).

-- Owns
--   * the ledger row of a payment that is not a mission run (cp_mission_runs, mission type manual_award): one write
--     for every kind, with the same breakdown, so the payments ledger, the totals, holds, retries and forfeits treat
--     every payment the same
--   * the hand-over of a written row to CP.Cash (pending first, then the claim-then-pay flow of CP.Cash.pay: source
--     server or society, the daily cap, held while flagged, pending until login, the Renewed-Banking entries)
--   * where the money goes (accountOf: a row's own bank/cash/item account, else Config.Cash.account) and the deposit
--     itself (deposit: the Qbox account through CP.Qbx.addMoney, or the money item through ox_inventory)
-- Every money rule and ENABLE switch stays with its feature (Config.Cash, Config.FeatureRewards, the money tools'
-- allow* switches); this file only does the paying, the same way for all of them.
--
-- Public API (docs/dev/ARCHITECTURE.md §5.20)
--   CP.Money.accountOf(cashBd) -> account, moneyItem|nil   'bank' | 'cash' | 'item' (with its item)
--   CP.Money.deposit(src, account, moneyItem, amount) -> ok, why    why 'error' = it raised (the balance may have
--       changed: never retried automatically)
--   CP.Money.rowOf(runUuid, citizenid|nil) -> id | nil | false     false = the lookup failed
--   CP.Money.writeRow(spec) -> rowId | nil                         a manual award ledger row, cash_status 'none'
--       spec = { runUuid, missionId, citizenid, department, amount, label, kind, by, reason, seasonId,
--                cash = { extra RunResult.cash fields: account, moneyItem, source }, extra = { breakdown fields } }
--   CP.Money.settle(rowId) -> status                               'pending' first, then CP.Cash.pay
--   CP.Money.seasonId() -> id | nil                                the running Department Challenge season
--   CP.Money.department(key) -> { key, label, societyAccount } | nil   a turned-off department included
-- The money files share the library's clock and statement helpers (CP.now, CP.query, CP.scalar, CP.update).
-- writeRow, rowOf and settle query the database: call them from a thread.

CP.Money = CP.Money or {}
local Money = CP.Money
local U = CP.U
local TAG = 'money'

local Num = CP.Num

-- ============================================================================
--                                SHARED LOOKUPS
-- ============================================================================

-- Where the dispute window of a voided run row r starts (the cash and item reward forfeiture): its creation, or the
-- end of the officer's suspension when that came later (NOW() while he is still suspended: a suspended officer cannot
-- file a dispute, so the window stands still and he gets all of it once the suspension ends; a lift keeps its time
-- in suspended_until). The same rule as CP.Disputes.eligible.
Money.DISPUTE_START_SQL = [[GREATEST(r.created_at, LEAST(COALESCE((SELECT o.suspended_until FROM cp_officers o
    WHERE o.citizenid = r.citizenid), r.created_at), NOW()))]]

-- The end of a dispute window that starts at startTs: Config.Disputes.windowHours on, moved on by the time a
-- maintenance lock stood it still (CP.Maintenance.windowEnd).
function Money.disputeEnd(startTs)
    local w = math.floor(math.max(0, Num(Config.Disputes and Config.Disputes.windowHours, 48)) * 3600)
    if CP.Maintenance and CP.Maintenance.windowEnd then
        local ok, e = pcall(CP.Maintenance.windowEnd, startTs, w)
        if ok and tonumber(e) then return tonumber(e) end
    end
    return startTs + w
end

-- The id of the current Department Challenge season, or nil (none running, or no challenge module).
---@return integer|nil
function Money.seasonId()
    local ok, s = CP.Call(TAG, 'Challenge', 'currentSeason')
    if ok and type(s) == 'table' and tonumber(s.id) then return math.floor(tonumber(s.id)) end
    return nil
end

-- A department for a payment, a turned-off one included (its unfinished pay still pays from its account):
-- { key, label, societyAccount } | nil.
---@param key string
---@return table|nil
function Money.department(key)
    local d = CP.Access and CP.Access.department and CP.Access.department(key) or nil
    if d then return d end
    local cfg = type(key) == 'string' and type(Config.Departments) == 'table' and Config.Departments[key] or nil
    if type(cfg) ~= 'table' then return nil end
    local account = type(cfg.societyAccount) == 'string' and cfg.societyAccount ~= '' and cfg.societyAccount
        or (type(cfg.jobs) == 'table' and cfg.jobs[1]) or key
    return { key = key, label = type(cfg.label) == 'string' and cfg.label or key, societyAccount = account }
end

-- ============================================================================
--                                WHERE IT GOES
-- ============================================================================

-- The account of a ledger row's cash breakdown: its own 'bank' or 'cash', its own 'item' when it names the money
-- item, else Config.Cash.account (bank by default).
function Money.accountOf(cashBd)
    cashBd = type(cashBd) == 'table' and cashBd or {}
    if cashBd.account == 'bank' or cashBd.account == 'cash' then return cashBd.account, nil end
    if cashBd.account == 'item' and type(cashBd.moneyItem) == 'string' and cashBd.moneyItem ~= '' then
        return 'item', cashBd.moneyItem
    end
    return (Config.Cash and Config.Cash.account) or 'bank', nil
end

-- Gives amount of a money item. -> true | false (no room or no ox_inventory: nothing added) | false, 'error' (it
-- raised: the inventory may have changed).
local function GiveItem(src, item, amount)
    if type(item) ~= 'string' or item == '' then return false end
    local okC, can = CP.Ext.call('ox_inventory', 'CanCarryItem', src, item, amount)
    if not okC or can ~= true then return false end
    local ok, res = CP.Ext.call('ox_inventory', 'AddItem', src, item, amount)
    if not ok then
        CP.err(TAG, 'ox_inventory AddItem(%s, %d) raised for %s: %s', item, amount, tostring(src), tostring(res))
        return false, 'error'
    end
    return res == true or (res ~= false and res ~= nil)
end

-- The deposit of every payment: a money item when account is 'item' (never a Qbox account named 'item'), else
-- the Qbox account. -> ok, why (why 'error': it raised).
function Money.deposit(src, account, moneyItem, amount)
    amount = math.floor(Num(amount, 0))
    if amount <= 0 then return true end
    if account == 'item' then return GiveItem(src, moneyItem, amount) end
    if not (CP.Qbx and CP.Qbx.addMoney) then return false end
    return CP.Qbx.addMoney(src, account, amount, 'crimson-police-mission')
end

-- ============================================================================
--                                THE LEDGER ROW
-- ============================================================================

-- cid nil: any player's row of that id.
function Money.rowOf(runUuid, cid)
    local ok, id
    if cid then
        ok, id = pcall(MySQL.scalar.await,
            'SELECT id FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ? LIMIT 1', { runUuid, cid })
    else
        ok, id = pcall(MySQL.scalar.await, 'SELECT id FROM cp_mission_runs WHERE run_uuid = ? LIMIT 1', { runUuid })
    end
    if not ok then
        CP.err(TAG, 'looking up payment %s failed: %s', tostring(runUuid), tostring(id))
        return false
    end
    return tonumber(id)
end

-- One manual award ledger row (out of the run counts, goals, streaks and the draw by the existing filters), written
-- as 'none', which no login payment and no Pay now picks up: settle hands it to CP.Cash once it is audited.
-- spec.status = 'pending' (a feature reward, whose audit is no gate): written payable at once, so a restart
-- between the insert and the pay leaves a row the login and start-up sweeps pay.
function Money.writeRow(spec)
    local amount = math.max(0, math.floor(Num(spec.amount, 0)))
    local status = spec.status == 'pending' and amount > 0 and 'pending' or 'none'
    local cash = { B = amount, mTier = 1.0, mMod = 1.0, amount = amount, status = status }
    for k, v in pairs(type(spec.cash) == 'table' and spec.cash or {}) do cash[k] = v end
    local bd = {
        runId = spec.runUuid,
        missionLabel = spec.label,
        missionType = 'manual_award',
        result = 'completed',
        endReason = 'completed',
        test = false,
        tier = 'standard',
        payTier = 'standard',
        participants = 1,
        departments = 1,
        durationS = 0,
        points = { P = 0, bonuses = {}, penalties = {}, subtotal = 0, final = 0 },
        cash = cash,
        kind = spec.kind,
        by = spec.by,
        reason = spec.reason,
    }
    for k, v in pairs(type(spec.extra) == 'table' and spec.extra or {}) do bd[k] = v end
    local okJ, js = pcall(json.encode, U.serialize(bd))
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
        VALUES (?, 'manual_award', ?, ?, ?, NULLIF(?, 0), 1, 1, 'standard', 'completed', 'completed', 0, 0, 0, 0, ?,
            1.00, 0, ?, 0, ?, 0, 0, FROM_UNIXTIME(?))
    ]], {
        spec.runUuid,
        U.clip(spec.missionId, 40),
        spec.citizenid,
        U.clip(spec.department or 'unknown', 32),
        spec.seasonId or Money.seasonId() or 0,
        amount,
        status,
        okJ and js or '{}',
        CP.now(),
    })
    if not ok or not tonumber(id) then
        CP.err(TAG, 'inserting the %s row for %s failed: %s', tostring(spec.missionId), tostring(spec.citizenid),
            tostring(id))
        return nil
    end
    return math.floor(tonumber(id))
end

-- Hands a written, audited row to CP.Cash. 'pending' before the pay waits for the store and the officer's payment
-- lock: a stop or crash in that wait leaves an audited row the login, start and end-of-maintenance sweeps pay (they
-- skip manual award rows still 'none'). Not paid now (maintenance lock, lock wait, in flight): it stays 'pending'.
function Money.settle(rowId)
    local ok, err = pcall(MySQL.update.await, [[UPDATE cp_mission_runs SET cash_status = 'pending',
        breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.cash.status', 'pending'), breakdown)
        WHERE id = ? AND cash_status = 'none']], { rowId })
    if not ok then CP.err(TAG, 'marking row %d pending failed: %s', rowId, tostring(err)) end
    return CP.Cash and CP.Cash.pay and CP.Cash.pay(rowId) or 'pending'
end
