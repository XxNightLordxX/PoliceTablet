-- CP.Cash (server): the cash formula and every payment Crimson-Police makes.

-- Owns
--   * cash per participant = round(B x M_tier x M_mod) (SPEC "Cash payouts"): B = run.cashBase, locked at
--     accept by CP.Payouts.baseFor; M_tier = the run's points and cash tier (Config.Scaling cash); M_mod =
--     Config.Events.modifierCash when the run rolled a modifier. Only Completed results pay; a participant
--     who failed the presence share (runs with 2+ participants) gets $0. x M_bonus, the happy hour
--     cash bonus fixed at the accept (Cash.bonusOf; never test, Cross-Department or boss runs), and M_mod uses
--     the department's twistCash scale (CP.Twists.scaleOf); breakdown.cash.mBonus when it is not 1.
--   * the claim-then-pay flow of one cp_mission_runs row (cash_status none/held/pending -> paying -> paid |
--     capped | unfunded; offline -> pending), the daily cap per reset-day (Config.Cash.dailyCap), the society
--     source (Config.Cash.source = 'society': the department's Renewed-Banking account through CP.Banking),
--     the Qbox deposit (CP.Qbx.addMoney, Config.Cash.account), the Renewed-Banking history entries with the
--     transaction id CP-<run_uuid>-<citizenid>, pending payments on login, releases after an approval,
--     forfeits of voided runs and the forfeiture job (every 10 min).
--   A row is only ever paid when it is completed, not flagged and not voided, and the claim
--   UPDATE ... SET cash_status = 'paying' WHERE ... IN ('none','held','pending') changed it: paid, capped,
--   unfunded and forfeited are final. A row left in 'paying' (crash, or a failed deposit after a society
--   withdrawal that could not be refunded) is never retried automatically: see stuckPayments().
--
-- Public API (docs/dev/ARCHITECTURE.md §5.20)
--   CP.Cash.compute(run, p) -> amount, breakdown       breakdown = RunResult.cash { B, mTier, mMod, amount, status }
--       status: 'held' for a completed, flagged, non-test row, else 'none'. Reads p.result (set by the engine).
--   CP.Cash.pay(rowId) -> status|nil                   'paid'|'capped'|'unfunded'|'pending'|'paying'|nil (nothing done)
--   CP.Cash.payPending(src) -> n                       pays the player's pending rows, and completed mission rows left
--                                                      'none' with cash (never claimed); run 5 s after login and once
--                                                      for every online player 15 s after the resource starts
--   CP.Cash.release(rowId) -> status|nil               after an approved flag (flagged already 0): pay now or pending
--   CP.Cash.forfeit(rowId) -> boolean                  a voided row's held/pending cash -> forfeited
--   CP.Cash.range(missionType, members) -> min, max    board card range per officer: missionType is a type key or
--       'weekly_boss'; members = officer tables or srcs (the unit). Covers every mission of the pool (admin
--       payouts, stars) at the unit's tier; the top also covers a modifier (never for the boss).
--   CP.Cash.stuckPayments() -> { StuckPayment... }     rows still 'paying' (not being paid right now), and paid or
--       capped rows an admin money tool left part way (kind 'rest', 'back', 'giveBack': Cash.followUpOf)
--       StuckPayment = { id, kind, followUpAmount, runUuid, citizenid, name, missionId, missionLabel, department,
--       amount, step, createdAt, transId }
--   CP.Cash.resolveFollowUp(rowId, outcome, audit) -> ok, data | false, errKey   (Admin UI -> Payments -> Resolve)
--   CP.Cash.retryGiveBacks() -> n                      owed clawback give-backs tried again (start, every 10 min)
--   CP.Cash.earnedThisWeek(citizenid) -> number        cash_paid of paid/capped rows since the week start
-- All functions except compute and range query the database: call them from a thread.

CP.Cash = CP.Cash or {}
local Cash = CP.Cash
local TAG = 'cash'

local BOSS_ID = 'weekly_boss_kingpin'
local BOSS_KEY = 'weekly_boss'
local PENDING_DELAY_MS = 5000          -- Renewed-Banking loads the player's history cache asynchronously
local FORFEIT_EVERY_MS = 10 * 60 * 1000
local STARTUP_SWEEP_MS = 15000         -- pending rows of players already online when the resource starts
local LOCK_WAIT_MS = 15000
local IDLE_WAIT_MS = 60000             -- the forfeiture job waits this long at most for an admin's bulk job to end
local MANUAL_CASH = 'manual_cash'      -- an admin's manual cash payment (mission_type manual_award): outside the cap
local FINAL = { paid = true, capped = true, unfunded = true, forfeited = true }

-- Config.Cash.source = 'society' and a banking script serves the department accounts (CP.Banking.societyOn); with
-- the banking stand-in of a test (no societyOn), the setting alone.
local function SocietyOn()
    local B = CP.Banking
    if B and B.societyOn then return B.societyOn() end
    return Config.Cash ~= nil and Config.Cash.source == 'society'
end

local payLock = CP.Lock.new() -- an officer's citizenid while one of their rows is being paid
local rowLock = CP.Lock.new() -- a row id while pay() works on it

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local Num = CP.Num

local function ToId(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local Now = CP.now

local function FmtMoney(n)
    local s = tostring(math.floor(math.abs(Num(n, 0)) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (Num(n, 0) < 0 and '-$' or '$') .. out
end

local function TierRow(run)
    -- a live case's tier comes from its crew (Config.RealPlayers.liveCrime.tier = 'crew')
    if CP.LiveCrime and CP.LiveCrime.tierRow then
        local ok, row = pcall(CP.LiveCrime.tierRow, run)
        if ok and type(row) == 'table' then return row end
    end
    local t = run.payTier
    if type(t) == 'table' then return t end
    if CP.Scaling and CP.Scaling.tierByName then
        local row = CP.Scaling.tierByName(t or run.expectedTier)
        if row then return row end
    end
    return { tier = 'standard', cash = 1.0, points = 1.0 }
end

local function PresenceFailed(run, p)
    if not (CP.AntiCheat and CP.AntiCheat.presenceOk) then return false end
    if type(run.order) ~= 'table' or #run.order < 2 then return false end
    local ok, present = pcall(CP.AntiCheat.presenceOk, run, p)
    return ok and present == false
end

local function WithLock(key, fn)
    local st, res = payLock:run(key, LOCK_WAIT_MS, fn)
    if st == 'busy' then
        CP.warn(TAG, 'payment lock for %s is still held after %d ms; skipping this attempt', key, LOCK_WAIT_MS)
        return nil
    end
    if st == 'error' then
        CP.err(TAG, 'payment for %s failed: %s', key, tostring(res))
        return nil
    end
    return res
end

-- A maintenance lock (a storage copy or switch, a backup restore) holds every payment back: the rows wait and are
-- paid after the restart. A store left behind by a storage switch never pays (its rows may be paid in the new one).
local function PaymentsHeld()
    if not (CP.Maintenance and CP.Maintenance.active) then return nil end
    local ok, kind = pcall(CP.Maintenance.active)
    return ok and kind or nil
end

-- A department for a payment, a turned-off one included (CP.Money.department).
local DeptOf = CP.Money.department

-- Long admin jobs (bulk voids, restores, copies) and the forfeiture job never meet half done: the job waits for the
-- shared busy lock and holds it while it works. nil, 'busy' when the lock stayed taken.
local function UnderBusyLock(kind, fn)
    local Kit = CP.AdminKit
    if not (Kit and Kit.waitIdle and Kit.lock and Kit.unlock) then return fn() end
    if not Kit.waitIdle(IDLE_WAIT_MS) then return nil, 'busy' end
    if not Kit.lock(kind) then return nil, 'busy' end
    local res = table.pack(pcall(fn))
    Kit.unlock(kind)
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

-- ============================================================================
--                                   COMPUTE
-- ============================================================================
-- Round to the nearest dollar, halves up. The epsilon absorbs float error in the product (350 * 1.15 is
-- 402.49999999999994 in doubles, a true $402.50 that must pay $403).
local function RoundMoney(x)
    return math.floor(x + 0.5 + 1e-7)
end

-- The happy hour cash bonus a run carries (run.controls.cashBonus, fixed at the accept): x the cash, 1.0 =
-- none. Never on test runs, Cross-Department runs or the Weekly Boss.
function Cash.bonusOf(run)
    if type(run) ~= 'table' or run.test or run.operationId or run.isBoss then return 1.0 end
    local b = type(run.controls) == 'table' and tonumber(run.controls.cashBonus) or nil
    if b == nil or b ~= b or b == math.huge then return 1.0 end
    return math.max(1.0, b)
end

function Cash.compute(run, p)
    if type(run) ~= 'table' or type(p) ~= 'table' then
        return 0, { B = 0, mTier = 1.0, mMod = 1.0, amount = 0, status = 'none' }
    end
    local B = math.max(0, math.floor(Num(run.cashBase, 0) + 0.5))
    -- a live or volunteer case pays nothing unless the owner turned on its mode's cash switch
    -- (Config.RealPlayers.liveCrime.cash, Config.RealPlayers.volunteer.cash: money switches)
    if not CP.RealPlayersTakePart(run, 'cash') then B = 0 end
    -- a volunteer case ended early by Config.RealPlayers.volunteer.voidRun = 'keep_earned': only the points earned so
    -- far, no mission cash
    if run.keepEarned == true then B = 0 end
    -- Z14: a live-case officer who went down ('downed_case') leaves with the points he earned so far, no mission cash
    if p.endReason == 'downed_case' then B = 0 end
    local mTier = Num(TierRow(run).cash, 1.0)
    -- the run's twists (CP.Twists): their cash multipliers multiply (each x the department's twist cash), up
    -- to Config.Events.twistMaxCash
    local mMod = CP.Twists.bonus(CP.Twists.of(run), CP.Twists.scaleOf(run)).cash
    local mBonus = Cash.bonusOf(run)
    local amount = 0
    if p.result == 'completed' and not PresenceFailed(run, p) then
        amount = math.max(0, RoundMoney(B * mTier * mMod * mBonus))
    end
    local flagged = p.flagged ~= nil or run.flagged ~= nil
    local status = 'none'
    if p.result == 'completed' and flagged and not run.test then status = 'held' end
    local cb = { B = B, mTier = mTier, mMod = mMod, amount = amount, status = status }
    -- the happy hour cash bonus: on the breakdown only when there is one (the result card shows it)
    if mBonus ~= 1.0 then cb.mBonus = mBonus end
    return amount, cb
end

-- ============================================================================
--                                     ROWS
-- ============================================================================

local function ReadRow(rowId)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT id, run_uuid, citizenid, mission_id, mission_type, department, state, cash_status, cash_base,
               cash_multiplier, cash_paid, cash_reclaimed, flagged, voided, breakdown,
               UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_mission_runs WHERE id = ?
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'reading row %d failed: %s', rowId, tostring(row))
        return nil
    end
    if type(row) ~= 'table' or row.id == nil then return nil end
    return row
end

local function AmountOf(row, bd)
    local a = bd and type(bd.cash) == 'table' and tonumber(bd.cash.amount) or nil
    if a == nil then a = Num(row.cash_base, 0) * Num(row.cash_multiplier, 1.0) end
    return math.max(0, math.floor(a + 0.5))
end

-- The amount the last payment attempt was for (after the daily cap), from its step marker.
local function PayAmountOf(bd)
    local c = bd and type(bd.cash) == 'table' and bd.cash or nil
    local n = c and tonumber(c.payAmount) or nil
    if not n then return nil end
    return math.max(0, math.floor(n + 0.5))
end

local function MissionLabel(row, bd)
    if bd and type(bd.missionLabel) == 'string' and bd.missionLabel ~= '' then return bd.missionLabel end
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(row.mission_id)
    if def and def.label then return def.label end
    return tostring(row.mission_id)
end

local function SetFinal(rowId, status, paid)
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs
        SET cash_status = ?, cash_paid = ?,
            breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', ?, '$.cash.paid', ?))
        WHERE id = ? AND cash_status = 'paying'
    ]], { status, paid, status, paid, rowId })
    if not ok then
        CP.err(TAG, 'writing the final status %s of row %d failed (it stays paying): %s', status, rowId, tostring(n))
        return false
    end
    return (tonumber(n) or 0) > 0
end

-- Writes fields under breakdown.cash of a row in one of the expected statuses: the step markers of a payment and
-- the account and source it used. One JSON_SET over those paths, so every other field of the breakdown is kept.
-- statuses: a status or a list of them. true when the row changed.
local function Mark(rowId, fields, statuses)
    if type(statuses) == 'string' then statuses = { statuses } end
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    if #keys == 0 then return false end
    table.sort(keys)
    local sets, params = {}, {}
    for _, k in ipairs(keys) do
        sets[#sets + 1] = ('\'$.cash.%s\', ?'):format(k)
        params[#params + 1] = fields[k]
    end
    params[#params + 1] = rowId
    local marks = {}
    for i, st in ipairs(statuses) do
        marks[i] = '?'
        params[#params + 1] = st
    end
    local ok, n = pcall(
        MySQL.update.await,
        ([[
        UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, %s)
        WHERE id = ? AND cash_status IN (%s) AND JSON_EXTRACT(breakdown, '$.cash') IS NOT NULL
    ]]):format(table.concat(sets, ', '), table.concat(marks, ', ')),
        params
    )
    if not ok then
        CP.err(TAG, 'writing the payment markers of row %d failed: %s', rowId, tostring(n))
        return false
    end
    return (tonumber(n) or 0) > 0
end

local function BackToPending(rowId, why)
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs
        SET cash_status = 'pending',
            breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', 'pending'))
        WHERE id = ? AND cash_status = 'paying'
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'row %d could not go back to pending (%s): %s', rowId, why, tostring(n))
        return false
    end
    CP.warn(TAG, 'row %d went back to pending: %s', rowId, why)
    return true
end

-- Paid (or capped) cash on the reset-day of ts, excluding the row being paid. A manual cash payment (an admin's,
-- mission_id manual_cash) is outside the daily cap: it is neither cut by it nor counted in it.
local function PaidOnDay(citizenid, ts)
    local startTs = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(ts) or (ts - ts % 86400)
    local nextTs = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(startTs + 25 * 3600)
        or (startTs + 86400)
    local ok, total = pcall(MySQL.scalar.await, [[
        SELECT COALESCE(SUM(cash_paid), 0) AS total FROM cp_mission_runs
        WHERE citizenid = ? AND cash_status IN ('paid', 'capped') AND mission_id <> 'manual_cash'
          AND created_at >= FROM_UNIXTIME(?) AND created_at < FROM_UNIXTIME(?)
    ]], { citizenid, startTs, nextTs })
    if not ok then
        CP.err(TAG, 'daily cap lookup for %s failed: %s', citizenid, tostring(total))
        return nil
    end
    return math.floor(CP.U.num(total))
end

-- Online supervisors of a department (for the unfunded warning).
local function SupervisorsOf(dept)
    local out = {}
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Access and CP.Access.getOfficer) then return out end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
        local o = CP.Access.getOfficer(s)
        if o and o.department == dept and o.isSupervisor then out[#out + 1] = s end
    end
    return out
end

-- ============================================================================
--                        WHAT A MONEY CALL ACTUALLY DID
-- ============================================================================
-- A money call that raised (Qbox AddMoney/RemoveMoney, a Renewed-Banking export) may or may not have moved the money.
-- The balance read right before the call (no await between) and right after it decides: changed by exactly the
-- amount = it arrived, unchanged = refused, anything else or no balance to read = no telling (the row is left for an
-- admin, never refunded or retried blind).

-- The department account's balance, or nil.
local function SocietyBalance(account)
    if type(account) ~= 'string' or account == '' then return nil end
    if not (CP.Banking and CP.Banking.societyBalance) then return nil end
    local ok, b = pcall(CP.Banking.societyBalance, account)
    return ok and type(b) == 'number' and b or nil
end

-- The officer's Qbox balance of a money account, or nil (a money item has none to read).
local function BalanceOf(src, account, item)
    if item ~= nil or account == 'item' then return nil end
    if not (CP.Qbx and CP.Qbx.getMoney) then return nil end
    local ok, b = pcall(CP.Qbx.getMoney, src, account)
    return ok and type(b) == 'number' and b or nil
end

-- 'done' | 'refused' | 'unknown' from the balance before and after a call that raised, for a change of delta.
local function Outcome(before, after, delta)
    if type(before) ~= 'number' or type(after) ~= 'number' then return 'unknown' end
    if after - before == delta then return 'done' end
    if after == before then return 'refused' end
    return 'unknown'
end

-- A society call (withdrawSociety or depositSociety) decided: 'done' | 'refused' | 'unknown'. A plain false is a
-- refusal (nothing moved); a raise (the adapter's false, 'error', or the call itself raising) reads the balance.
local function SocietyCall(fn, account, amount, sign)
    if not (CP.Banking and type(CP.Banking[fn]) == 'function') then return 'refused' end
    if type(account) ~= 'string' or account == '' then return 'refused' end
    local before = SocietyBalance(account)
    local ok, res, why = pcall(CP.Banking[fn], account, amount)
    if ok and res == true then return 'done' end
    if ok and why ~= 'error' then return 'refused' end
    CP.err(TAG, '%s(%s, %d) raised; deciding from the balance', fn, account, amount)
    return Outcome(before, SocietyBalance(account), sign * amount)
end

local function WithdrawSociety(account, amount) return SocietyCall('withdrawSociety', account, amount, -1) end
Cash.societyCall = SocietyCall

-- The officer's deposit decided: 'done' | 'refused' | 'unknown', and the balances read (for the review marker).
local function DepositChecked(src, account, item, amount)
    local before = BalanceOf(src, account, item)
    local ok, why = CP.Money.deposit(src, account, item, amount)
    if ok then return 'done' end
    if why ~= 'error' then return 'refused' end
    local after = BalanceOf(src, account, item)
    return Outcome(before, after, amount), before, after
end

-- Gives a department back what it paid: true only when it arrived (a raised call is decided from the balance; no
-- telling counts as not given back, so it stays a staff item and is never given twice).
local function RefundSociety(account, amount)
    return SocietyCall('depositSociety', account, amount, 1) == 'done'
end

local PayClaimed

-- Pays one claimed-or-claimable row. Runs under the citizenid lock.
local function PayRow(row)
    local rowId = math.floor(CP.U.num(row.id))
    local cid = row.citizenid
    local src = CP.srcOf(cid)

    if not src then
        local ok, n = pcall(MySQL.update.await, [[
            UPDATE cp_mission_runs
            SET cash_status = 'pending',
                breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', 'pending'))
            WHERE id = ? AND cash_status IN ('none', 'held') AND state = 'completed' AND flagged = 0 AND voided = 0
        ]], { rowId })
        if not ok then
            CP.err(TAG, 'marking row %d pending failed: %s', rowId, tostring(n))
            return nil
        end
        if (tonumber(n) or 0) > 0 then
            CP.log(TAG, 'row %d: %s is offline, payment pending', rowId, cid)
            return 'pending'
        end
        return row.cash_status == 'pending' and 'pending' or nil
    end

    -- Claim the row before any money moves.
    local okC, claimed = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs SET cash_status = 'paying'
        WHERE id = ? AND cash_status IN ('none', 'held', 'pending') AND state = 'completed' AND flagged = 0 AND voided = 0
    ]], { rowId })
    if not okC then
        CP.err(TAG, 'claiming row %d failed: %s', rowId, tostring(claimed))
        return nil
    end
    if (tonumber(claimed) or 0) < 1 then
        CP.log(TAG, 'row %d was not claimable (already paid or being paid)', rowId)
        return nil
    end

    -- From here the row is 'paying'. A Lua error before any money moved puts it back to pending (it would
    -- otherwise be stuck for a manual check); after money may have moved it stays paying.
    local progress = { moved = false }
    local okP, res = pcall(PayClaimed, row, rowId, cid, src, progress)
    if okP then return res end
    if not progress.moved then
        BackToPending(rowId, 'error before any money moved: ' .. tostring(res))
        return 'pending'
    end
    CP.err(TAG, 'row %d: error after money may have moved; it stays paying for a manual check: %s', rowId,
        tostring(res))
    return 'paying'
end

-- The claimed part of payRow (row is 'paying'). progress.moved = true right before the first call that can move money.
PayClaimed = function(row, rowId, cid, src, progress)
    local bd = CP.U.jsonField(row.breakdown) or {}
    local amount = AmountOf(row, bd)
    local capped = false
    local cap = math.floor(Num(Config.Cash and Config.Cash.dailyCap, 0))
    -- a manual cash payment has its own per-admin limit: the daily cap neither cuts it nor counts it
    if row.mission_id == MANUAL_CASH then cap = 0 end
    if cap > 0 and amount > 0 then
        local already = PaidOnDay(cid, tonumber(row.created_ts) or Now())
        if already == nil then
            BackToPending(rowId, 'daily cap lookup failed')
            return 'pending'
        end
        if already + amount > cap then
            amount = math.max(0, cap - already)
            capped = true
        end
    end

    local deptKey = row.department
    local dept = DeptOf(deptKey)
    local deptLabel = dept and dept.label or tostring(deptKey)
    local label = MissionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = ('CP-%s-%s'):format(tostring(row.run_uuid), tostring(cid))

    -- Re-fetch the player right before money moves.
    local info = CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or info.citizenid ~= cid then
        BackToPending(rowId, 'the officer went offline before the payment')
        return 'pending'
    end
    local charName = info.name or cid

    -- a feature reward row (CP.FeatureRewards) names its own account ('bank', 'cash' or 'item' with a money
    -- item) and may always be new money (a suspect has no department account)
    local cashBd = type(bd.cash) == 'table' and bd.cash or {}
    -- (with no banking script a society payout is new money: CP.Banking.societyOn)
    local society = SocietyOn() and cashBd.source ~= 'server'
    local account = dept and dept.societyAccount
    local moneyAccount, moneyItem = CP.Money.accountOf(cashBd)
    -- Step markers (claimed -> withdrawn -> added) and what this payment used, saved before and between the money
    -- calls: an admin resolving a payment left in 'paying' reads them (Admin UI -> Payments).
    Mark(rowId, {
        step = 'claimed',
        payAmount = amount,
        account = moneyAccount,
        source = society and 'society' or 'server',
        societyAccount = society and account or nil,
        txn = transId,
    }, 'paying')
    -- An intent marker (withdrawing, adding) is saved before each money call and checked: a restart or a raise in
    -- the call leaves that marker, which Pay again refuses (it can not know whether the money moved). A row with no
    -- breakdown.cash (an old or NULL breakdown) has nowhere to keep markers: paid as before, unmarked.
    local canMark = type(bd.cash) == 'table'
    local withdrew = false
    if amount > 0 and society then
        local got = 'refused'
        if type(account) == 'string' and account ~= '' and CP.Banking and CP.Banking.withdrawSociety then
            if not Mark(rowId, { step = 'withdrawing' }, 'paying') and canMark then
                BackToPending(rowId, 'the withdrawing marker could not be written; nothing moved')
                return 'pending'
            end
            progress.moved = true
            got = WithdrawSociety(account, amount)
            if got == 'refused' then progress.moved = false end
        end
        if got == 'unknown' then
            Mark(rowId, { step = 'review' }, 'paying')
            CP.err(
                TAG,
                'row %d: the withdrawal from %s raised and its balance does not tell; it stays paying for a '
                    .. 'manual check (transaction %s)',
                rowId,
                tostring(account),
                transId
            )
            return 'paying'
        end
        if got ~= 'done' then
            SetFinal(rowId, 'unfunded', 0)
            CP.warn(TAG, 'row %d unfunded: society account %s could not cover %d', rowId, tostring(account), amount)
            CP.notify(src, 'error', 'cash.unfunded',
                { amount = FmtMoney(amount), department = deptLabel, mission = label })
            local sups = SupervisorsOf(deptKey)
            if #sups > 0 and CP.Tablet and CP.Tablet.notifyMany then
                CP.Tablet.notifyMany(sups, 'warning', 'cash.unfunded_supervisor',
                    { name = charName, amount = FmtMoney(amount), department = deptLabel, account = tostring(account) })
            end
            return 'unfunded'
        end
        withdrew = true
        Mark(rowId, { step = 'withdrawn' }, 'paying')
    end

    if amount > 0 then
        if not Mark(rowId, { step = 'adding' }, 'paying') and canMark then
            -- nothing reached the officer: the department gets its money back, or the row stays at 'withdrawn'
            if withdrew and not RefundSociety(account, amount) then
                CP.err(
                    TAG,
                    'row %d: the adding marker could not be written after %s was debited %d; it stays paying '
                        .. '(transaction %s)',
                    rowId,
                    tostring(account),
                    amount,
                    transId
                )
                return 'paying'
            end
            progress.moved = false
            BackToPending(rowId, 'the adding marker could not be written; nothing reached the officer')
            return 'pending'
        end
        progress.moved = true
        local got, balBefore, balAfter = DepositChecked(src, moneyAccount, moneyItem, amount)
        if got == 'unknown' then
            -- AddMoney raised and the balance does not tell: never retried automatically, never refunded (it stays
            -- paying at step 'review' and is listed in stuckPayments for a manual check)
            Mark(rowId, { step = 'review', balBefore = balBefore, balAfter = balAfter }, 'paying')
            CP.err(TAG,
                'row %d: Qbox AddMoney(%s, %d) raised for %s; the row stays paying for a manual check (transaction %s)',
                rowId, moneyAccount, amount, cid, transId)
            return 'paying'
        end
        if got == 'refused' then
            if withdrew then
                if RefundSociety(account, amount) then
                    BackToPending(rowId, 'Qbox AddMoney failed; the society withdrawal was refunded')
                    return 'pending'
                end
                -- the department paid, the officer did not: Pay again deposits only
                Mark(rowId, { step = 'withdrawn' }, 'paying')
                CP.err(TAG,
                    'row %d: Qbox AddMoney failed after %s was debited %d; the row stays paying for a manual check (transaction %s)',
                    rowId, tostring(account), amount, transId)
                return 'paying'
            end
            CP.err(TAG, 'row %d: Qbox AddMoney(%s, %d) failed for %s', rowId, moneyAccount, amount, cid)
            progress.moved = false
            BackToPending(rowId, 'Qbox AddMoney failed')
            return 'pending'
        end
        Mark(rowId, { step = 'added' }, 'paying')
        if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordDeposit then
            CP.Banking.recordDeposit(cid, amount, message, deptLabel, charName, transId)
        end
        if withdrew and CP.Banking and CP.Banking.recordSocietyWithdraw then
            CP.Banking.recordSocietyWithdraw(account, amount, message, deptLabel, charName, transId)
        end
    end

    local status = capped and 'capped' or 'paid'
    if not SetFinal(rowId, status, amount) then
        CP.err(TAG, 'row %d: %d was paid but the status could not be written; it stays paying (transaction %s)', rowId,
            amount, transId)
        return 'paying'
    end
    CP.log(TAG, 'row %d: %s %d to %s (%s)', rowId, status, amount, cid, transId)
    if capped then
        CP.notify(src, 'warning', 'cash.capped', { amount = FmtMoney(amount), mission = label })
    elseif amount > 0 then
        CP.notify(src, 'success', 'cash.paid', { amount = FmtMoney(amount), mission = label })
    end
    return status
end

-- Cash counted against the daily cap today (manual cash payments left out). nil when the lookup failed.
function Cash.paidToday(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    CP.Db()
    return PaidOnDay(citizenid, Now())
end

function Cash.pay(rowId)
    rowId = ToId(rowId)
    if not rowId then return nil end
    -- the lock is read after the wait for the store: a lock the start takes (left behind) holds before this goes on
    CP.Db()
    local held = PaymentsHeld()
    if held == 'left_behind' then
        -- permanent: this store was left behind by a storage switch, its rows may be paid in the store that took over
        CP.warn(TAG, 'row %d is not paid: this store was left behind by a storage switch', rowId)
        return nil
    elseif held then
        CP.log(TAG, 'row %d waits: payments are held by the maintenance lock', rowId)
        return nil
    end
    local row = ReadRow(rowId)
    if not row then return nil end
    if FINAL[row.cash_status] or row.cash_status == 'paying' then return row.cash_status end
    if row.state ~= 'completed' or CP.U.truthy(row.flagged) or CP.U.truthy(row.voided) then
        CP.log(TAG, 'row %d is not payable (state %s, flagged %s, voided %s)', rowId, tostring(row.state),
            tostring(row.flagged), tostring(row.voided))
        return nil
    end
    local _, status = rowLock:run(rowId, 0, WithLock, row.citizenid, function() return PayRow(row) end)
    return status
end

function Cash.payPending(src)
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return 0 end
    CP.Db()
    if PaymentsHeld() then return 0 end
    -- 'pending' rows, plus completed mission rows still 'none' although they carry cash (the engine's pay never
    -- ran or was skipped, e.g. a crash right after the row insert): no money moved on either, and pay() claims
    -- them like any other row. Manual award and goal rows never carry cash. 'held' rows no longer flagged too: an
    -- approval whose release did not run (lock wait, maintenance, a stop between the flag clear and the claim).
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT id FROM cp_mission_runs
        WHERE citizenid = ? AND state = 'completed' AND flagged = 0 AND voided = 0
          AND (cash_status IN ('pending', 'held')
               OR (cash_status = 'none' AND mission_type NOT IN ('manual_award', 'goal') AND cash_base > 0))
        ORDER BY id
    ]], { info.citizenid })
    if not ok then
        CP.err(TAG, 'pending payments lookup for %s failed: %s', info.citizenid, tostring(rows))
        return 0
    end
    local n = 0
    for _, r in ipairs(rows or {}) do
        local st = Cash.pay(r.id)
        if st == 'paid' or st == 'capped' then n = n + 1 end
    end
    if n > 0 then CP.log(TAG, 'paid %d pending payment(s) to %s', n, info.citizenid) end
    return n
end

function Cash.release(rowId)
    rowId = ToId(rowId)
    if not rowId then return nil end
    CP.Db()
    local row = ReadRow(rowId)
    if not row then return nil end
    if CP.U.truthy(row.voided) then return nil end
    if CP.U.truthy(row.flagged) then
        CP.warn(TAG, 'release(%d) was called while the row is still flagged; clear the flag first', rowId)
        return nil
    end
    return Cash.pay(rowId)
end

local function FireForfeited(rowId)
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('row:forfeited', rowId) end
end

function Cash.forfeit(rowId)
    rowId = ToId(rowId)
    if not rowId then return false end
    CP.Db()
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs
        SET cash_status = 'forfeited',
            breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', 'forfeited'))
        WHERE id = ? AND voided = 1 AND cash_status IN ('held', 'pending')
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'forfeiting row %d failed: %s', rowId, tostring(n))
        return false
    end
    local done = (tonumber(n) or 0) > 0
    if done then FireForfeited(rowId) end
    return done
end

local WINDOW_START_SQL = CP.Money.DISPUTE_START_SQL

-- Voided rows whose dispute window closed with no open dispute: held/pending -> forfeited. Row by row, each
-- claimed by its own UPDATE, so row:forfeited (held item rewards) fires once per row that changed. The UPDATE
-- checks again that the window did not start later meanwhile (a suspension).
local function ForfeitRows()
    local hours = Num(Config.Disputes and Config.Disputes.windowHours, 48)
    local now = Now()
    local cutoff = now - math.floor(hours * 3600)
    local ok, rows = pcall(
        MySQL.query.await,
        ([[
        SELECT r.id, UNIX_TIMESTAMP(%s) AS start_ts FROM cp_mission_runs r
        WHERE r.voided = 1 AND r.cash_status IN ('held', 'pending') AND %s < FROM_UNIXTIME(?)
          AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
        ORDER BY r.id
    ]]):format(WINDOW_START_SQL, WINDOW_START_SQL),
        { cutoff }
    )
    if not ok then
        CP.err(TAG, 'forfeiture job failed: %s', tostring(rows))
        return 0
    end
    local n = 0
    for _, row in ipairs(rows or {}) do
        local id = ToId(row.id)
        local startTs = math.floor(Num(row.start_ts, 0))
        local okU, changed = true, 0
        if CP.Money.disputeEnd(startTs) < now then
            okU, changed = pcall(
                MySQL.update.await,
                ([[
                UPDATE cp_mission_runs r
                SET r.cash_status = 'forfeited',
                    r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, '$.cash.status', 'forfeited'))
                WHERE r.id = ? AND r.voided = 1 AND r.cash_status IN ('held', 'pending') AND %s <= FROM_UNIXTIME(?)
                  AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
            ]]):format(WINDOW_START_SQL),
                { id, startTs }
            )
        end
        if not okU then
            CP.err(TAG, 'forfeiture of row %s failed: %s', tostring(id), tostring(changed))
        elseif (tonumber(changed) or 0) > 0 then
            n = n + 1
            FireForfeited(id)
        end
    end
    if n > 0 then CP.log(TAG, 'forfeited the held cash of %d voided row(s)', n) end
    return n
end

-- Waits while a maintenance lock holds payments, and for an admin's bulk job (a void in flight is never forfeited
-- half done); holds the busy lock while it works.
local function ForfeitureJob()
    CP.Db()
    if PaymentsHeld() then return 0 end
    local n = UnderBusyLock('forfeiture', ForfeitRows)
    return n or 0
end

-- ============================================================================
--                      ADMIN TOOLS (ADMIN UI → PAYMENTS)
-- ============================================================================
-- Called by modules/payments inside CP.AdminKit actions (every guard has run). A tool that moves money claims the
-- row first (an UPDATE only one caller can win), then calls audit(info) (the synchronous audit row: false = the
-- claim is undone and nothing moves), then moves money under the officer's payment lock, then writes the final
-- state. Each returns ok, data | false, errKey.

local function Clean(rowId)
    rowId = ToId(rowId)
    if not rowId then return nil, 'err.invalid_row' end
    CP.Db()
    if PaymentsHeld() then return nil, 'err.maintenance' end
    local row = ReadRow(rowId)
    if not row then return nil, 'err.row_not_found' end
    return row, CP.U.jsonField(row.breakdown) or {}
end

local function CashOf(bd) return type(bd.cash) == 'table' and bd.cash or {} end

local function TxnOf(row) return ('CP-%s-%s'):format(tostring(row.run_uuid), tostring(row.citizenid)) end

-- The rows a statement changed; 0 when it raised (CP.update logged it).
local function Update(sql, params) return CP.update(TAG, sql, params) or 0 end

-- Undoes a JSON claim marker (breakdown.cash.<key>) that is still 'paying', with its step marker (<key>Step).
-- extraWhere: more conditions (the start-up release of claims no money call ever started).
local function Release(rowId, key, extraWhere)
    return Update(
        ([[UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(breakdown, '$.cash.%s', '$.cash.%sStep')
        WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.%s') = 'paying'%s]]):format(
            key,
            key,
            key,
            extraWhere or ''
        ),
        { rowId }
    ) > 0
end

-- Sets fields under breakdown.cash only while breakdown.cash.<key> is still val (compare and set): the step
-- markers of an admin money tool, so a claim released or resolved meanwhile is never moved on. true when it changed.
local function MarkIf(rowId, fields, key, val)
    local keys = {}
    for k in pairs(fields) do keys[#keys + 1] = k end
    table.sort(keys)
    local sets, params = {}, {}
    for _, k in ipairs(keys) do
        sets[#sets + 1] = ('\'$.cash.%s\', ?'):format(k)
        params[#params + 1] = fields[k]
    end
    params[#params + 1] = rowId
    params[#params + 1] = val
    return Update(
        ([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, %s)
        WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.%s') = ?]]):format(table.concat(sets, ', '), key),
        params
    ) > 0
end

-- Claims a JSON marker (breakdown.cash.<key> = 'paying') on a row in status: only one caller wins.
local function ClaimMarker(rowId, key, status, extraWhere)
    return Update(
        ([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.%s', 'paying')
        WHERE id = ? AND cash_status = ? AND voided = 0 AND flagged = 0 AND JSON_EXTRACT(breakdown, '$.cash') IS NOT NULL
          AND JSON_EXTRACT(breakdown, '$.cash.%s') IS NULL%s]]):format(key, key, extraWhere or ''),
        { rowId, status }
    ) > 0
end

-- fn() under the officer's payment lock. The claim is undone (onTimeout) when the lock stays taken; an error after
-- the claim leaves it for a manual check, because money may have moved.
local function RunLocked(cid, fn, onTimeout)
    local res = table.pack(payLock:run(cid, LOCK_WAIT_MS, fn))
    if res[1] == 'busy' then
        onTimeout()
        return false, 'err.payment_in_flight'
    end
    if res[1] == 'error' then
        CP.err(TAG, 'an admin payment for %s failed: %s', cid, tostring(res[2]))
        return false, 'err.payment_raised'
    end
    return table.unpack(res, 2, res.n)
end

local function Audited(audit, info)
    if type(audit) ~= 'function' then return true end
    local ok, id = pcall(audit, info)
    return ok and id ~= nil and id ~= false
end

-- The online officer of a row, re-read: src, info | nil.
local function OnlineOf(cid)
    local src = CP.srcOf(cid)
    if not src then return nil end
    local info = CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or info.citizenid ~= cid then return nil end
    return src, info
end

-- What an admin sees about a payment: owed, paid, taken back, the step markers.
function Cash.amountOf(row)
    if type(row) ~= 'table' then return 0 end
    return AmountOf(row, CP.U.jsonField(row.breakdown))
end

function Cash.txnOf(row) return TxnOf(row) end

-- true while pay() works on the row or the officer's payment lock is held (an admin waits for it).
function Cash.rowBusy(rowId, citizenid)
    rowId = ToId(rowId)
    return rowLock:held(rowId) or (type(citizenid) == 'string' and payLock:held(citizenid))
end

function Cash.paymentsHeld() return PaymentsHeld() end

-- ============================================================================
--                      RESOLVE A PAYMENT LEFT IN 'PAYING'
-- ============================================================================

-- Mark paid: the admin checked the bank history and the money arrived. No money moves.
function Cash.markPaid(rowId, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'paying' then return false, 'err.state_changed' end
    if Cash.rowBusy(rowId, row.citizenid) then return false, 'err.payment_in_flight' end
    local owed = AmountOf(row, bd)
    local paid = PayAmountOf(bd) or owed
    local status = paid < owed and 'capped' or 'paid'
    local n = Update([[
        UPDATE cp_mission_runs
        SET cash_status = ?, cash_paid = ?,
            breakdown = IF(JSON_EXTRACT(breakdown, '$.cash') IS NULL, breakdown,
                JSON_SET(breakdown, '$.cash.status', ?, '$.cash.paid', ?, '$.cash.resolved', 'marked'))
        WHERE id = ? AND cash_status = 'paying'
    ]], { status, paid, status, paid, rowId })
    if n < 1 then return false, 'err.state_changed' end
    if type(audit) == 'function' then pcall(audit, { amount = paid, status = status }) end
    return true, { id = rowId, status = status, amount = paid }
end

-- The money calls of Pay again and Pay the rest, each behind its own step marker breakdown.cash.<key>Step
-- (withdrawing -> withdrawn -> adding -> added; review when a raised call left no telling), written compare-and-set on
-- the claim marker <key> = 'paying'. A refused deposit gives the department its money back; when that fails too the
-- marker stays at 'withdrawn' (the department paid, the officer did not). -> true | false, errKey
local function MoveLocked(rowId, key, src, account, needWithdraw, moneyAccount, moneyItem, amount)
    local stepKey = key .. 'Step'
    local function Step(v, extra)
        local f = { [stepKey] = v }
        for k, x in pairs(extra or {}) do f[key .. k] = x end
        return MarkIf(rowId, f, key, 'paying')
    end
    if needWithdraw then
        -- the claim was released or resolved meanwhile (the marker is no longer ours): nothing moves
        if not Step('withdrawing') then return false, 'err.state_changed' end
        local got = type(account) == 'string' and account ~= '' and WithdrawSociety(account, amount) or 'refused'
        if got == 'unknown' then
            -- the marker stays at 'withdrawing': the department may have paid, the officer did not get it
            CP.err(TAG, 'row %d: the %s withdrawal from %s raised and its balance does not tell', rowId, key,
                tostring(account))
            return false, 'err.payment_raised'
        end
        if got ~= 'done' then
            Release(rowId, key)
            return false, 'err.unfunded_now'
        end
        Step('withdrawn')
    end
    if not Step('adding') then
        if not needWithdraw then return false, 'err.state_changed' end
        if RefundSociety(account, amount) then
            Release(rowId, key)
            return false, 'err.state_changed'
        end
        return false, 'err.payment_refund_failed'
    end
    local got, b0, b1 = DepositChecked(src, moneyAccount, moneyItem, amount)
    if got == 'unknown' then
        Step('review', { BalBefore = b0, BalAfter = b1 })
        CP.err(TAG, 'row %d: %s raised in AddMoney and the balance does not tell; it stays for a manual check', rowId,
            key)
        return false, 'err.payment_raised'
    end
    if got == 'refused' then
        if needWithdraw then
            if RefundSociety(account, amount) then
                Release(rowId, key)
                return false, 'err.payment_refused'
            end
            Step('withdrawn')
            CP.err(TAG, 'row %d: %s failed after %s was debited %d; it stays for a manual check', rowId, key,
                tostring(account), amount)
            return false, 'err.payment_refund_failed'
        end
        Release(rowId, key)
        return false, 'err.payment_refused'
    end
    Step('added')
    return true
end

-- Pay again under the officer's payment lock. key 'again' (a fresh Pay again) or 'again2' (the deposit of a Pay
-- again whose department withdrawal went through, resumed: no second withdrawal). Its transaction id is -r2 either way
-- (the resumed deposit never reached the officer before).
local function PayAgainLocked(row, bd, rowId, amount, needWithdraw, key)
    local cid = row.citizenid
    local src, info = OnlineOf(cid)
    if not src then
        Release(rowId, key)
        return false, 'err.officer_offline'
    end
    local c = CashOf(bd)
    local dept = DeptOf(row.department)
    local account = c.societyAccount or (dept and dept.societyAccount)
    local deptLabel = dept and dept.label or tostring(row.department)
    local label = MissionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = TxnOf(row) .. '-r2'
    local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
    -- a money item again when the payment used one (never a Qbox account named 'item')
    local okMove, err = MoveLocked(rowId, key, src, account, needWithdraw, moneyAccount, c.moneyItem, amount)
    if not okMove then return false, err end
    if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordDeposit then
        CP.Banking.recordDeposit(cid, amount, message, deptLabel, info.name or cid, transId)
    end
    if (needWithdraw or key == 'again2') and CP.Banking and CP.Banking.recordSocietyWithdraw then
        CP.Banking.recordSocietyWithdraw(account, amount, message, deptLabel, info.name or cid, transId)
    end
    local owed = AmountOf(row, bd)
    local status = amount < owed and 'capped' or 'paid'
    local n = Update(
        ([[
        UPDATE cp_mission_runs
        SET cash_status = ?, cash_paid = ?,
            breakdown = JSON_SET(breakdown, '$.cash.status', ?, '$.cash.paid', ?, '$.cash.again', 'paid',
                '$.cash.againTxn', ?%s)
        WHERE id = ? AND cash_status = 'paying'
    ]]):format(key ~= 'again' and (', \'$.cash.%s\', \'paid\''):format(key) or ''),
        { status, amount, status, amount, transId, rowId }
    )
    if n < 1 then
        CP.err(TAG, 'row %d: Pay again paid %d but the status could not be written (transaction %s)', rowId, amount,
            transId)
    end
    CP.notify(src, 'success', 'cash.paid', { amount = FmtMoney(amount), mission = label })
    return true, { id = rowId, status = status, amount = amount, txn = transId }
end

-- Pay again: the admin checked the bank history and the money did not arrive. The step markers say what already
-- happened: at 'claimed' nothing moved, so both money calls run; at 'withdrawn' the department already paid, so only
-- AddMoney runs; at 'added' the money arrived (Mark paid instead). At 'withdrawing', 'adding' or 'review' a money
-- call was cut or raised with no telling whether it moved: refused (Mark paid after checking both bank histories).
-- A Pay again left at againStep 'withdrawn' (the department paid, the deposit failed) resumes with the deposit only.
-- Its own transaction id CP-<uuid>-<cid>-r2. The officer must be online.
local UNKNOWN_STEP = { withdrawing = true, adding = true, review = true }

function Cash.payAgain(rowId, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'paying' then return false, 'err.state_changed' end
    if CP.U.truthy(row.flagged) then return false, 'err.payment_flagged' end
    if Cash.rowBusy(rowId, row.citizenid) then return false, 'err.payment_in_flight' end
    local c = CashOf(bd)
    local key = 'again'
    if c.again ~= nil then
        if c.again ~= 'paying' or c.againStep ~= 'withdrawn' or c.again2 ~= nil then
            return false, 'err.state_changed'
        end
        key = 'again2'
    end
    if c.step == 'added' then return false, 'err.payment_arrived' end
    if UNKNOWN_STEP[c.step] then return false, 'err.payment_step_unknown' end
    local paySource = c.source
    if paySource == nil then
        -- a payment from before the step markers: only safe when nothing was taken from a department
        if Config.Cash and Config.Cash.source == 'society' then return false, 'err.payment_step_unknown' end
        paySource = 'server'
    end
    local needWithdraw = key == 'again' and paySource == 'society' and c.step ~= 'withdrawn'
    local amount = PayAmountOf(bd) or AmountOf(row, bd)
    if amount <= 0 then return false, 'err.nothing_to_pay' end
    if not OnlineOf(row.citizenid) then return false, 'err.officer_offline' end
    if not ClaimMarker(rowId, key, 'paying') then return false, 'err.state_changed' end
    if
        not Audited(audit,
            { amount = amount, step = c.step or 'unknown', withdraw = needWithdraw, resume = key == 'again2' })
    then
        Release(rowId, key)
        return false, 'err.audit_failed'
    end
    return RunLocked(row.citizenid, function()
        return PayAgainLocked(row, bd, rowId, amount, needWithdraw, key)
    end, function() Release(rowId, key) end)
end

-- ============================================================================
--                        PAY THE PART THE DAILY CAP CUT
-- ============================================================================

local function CapRestLocked(row, bd, rowId, rest)
    local cid = row.citizenid
    local src, info = OnlineOf(cid)
    if not src then
        Release(rowId, 'restPaid')
        return false, 'err.officer_offline'
    end
    local dept = DeptOf(row.department)
    local account = dept and dept.societyAccount
    local c = CashOf(bd)
    -- a feature reward row names its own source ('server': new money, never a department account) and account
    local society = SocietyOn() and c.source ~= 'server'
    local deptLabel = dept and dept.label or tostring(row.department)
    local label = MissionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = TxnOf(row) .. '-r'
    local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
    -- a money item again when the payment used one (never a Qbox account named 'item'); the society it used is
    -- kept on the row for a Resolve that has to give it back (restPaidAccount)
    if society then MarkIf(rowId, { restPaidAccount = account }, 'restPaid', 'paying') end
    local okMove, err = MoveLocked(rowId, 'restPaid', src, account, society, moneyAccount, c.moneyItem, rest)
    if not okMove then return false, err end
    if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordDeposit then
        CP.Banking.recordDeposit(cid, rest, message, deptLabel, info.name or cid, transId)
    end
    if society and CP.Banking and CP.Banking.recordSocietyWithdraw then
        CP.Banking.recordSocietyWithdraw(account, rest, message, deptLabel, info.name or cid, transId)
    end
    local newPaid = math.floor(CP.U.num(row.cash_paid)) + rest
    local n = Update([[
        UPDATE cp_mission_runs
        SET cash_paid = ?,
            breakdown = JSON_SET(breakdown, '$.cash.restPaid', 'paid', '$.cash.restAmount', ?, '$.cash.paid', ?)
        WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.restPaid') = 'paying'
    ]], { newPaid, rest, newPaid, rowId })
    if n < 1 then CP.err(TAG, 'row %d: the capped rest was paid but could not be written (%s)', rowId, transId) end
    CP.notify(src, 'success', 'cash.paid', { amount = FmtMoney(rest), mission = label })
    return true, { id = rowId, amount = rest, paid = newPaid, txn = transId }
end

-- Pay the rest: the part of a capped payment the daily cap cut (owed - paid, computed here), once per row, with its
-- own transaction id CP-<uuid>-<cid>-r. The officer must be online. The status stays capped.
function Cash.payCapRest(rowId, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'capped' or CP.U.truthy(row.voided) then return false, 'err.state_changed' end
    if CP.U.truthy(row.flagged) then return false, 'err.payment_flagged' end
    if CashOf(bd).restPaid ~= nil then return false, 'err.state_changed' end
    local rest = AmountOf(row, bd) - math.floor(CP.U.num(row.cash_paid))
    if rest <= 0 then return false, 'err.nothing_to_pay' end
    if not OnlineOf(row.citizenid) then return false, 'err.officer_offline' end
    if not ClaimMarker(rowId, 'restPaid', 'capped') then return false, 'err.state_changed' end
    if not Audited(audit, { amount = rest }) then
        Release(rowId, 'restPaid')
        return false, 'err.audit_failed'
    end
    return RunLocked(row.citizenid, function() return CapRestLocked(row, bd, rowId, rest) end, function()
        Release(rowId, 'restPaid')
    end)
end

-- ============================================================================
--                        TAKE PAID CASH BACK (CLAWBACK)
-- ============================================================================

-- The clawback's markers on breakdown.cash. The claim (cash_reclaimed + n) also writes backPending = n and
-- backStep = 'claimed'; backStep becomes 'removing' (compare and set) right before RemoveMoney. Done: backs + 1, the
-- pending markers cleared and, on a society-source row, the give-back owed to the department (giveBack 'owed',
-- backOwed, backAccount) saved before the refund is tried. An undone claim takes the increment back and clears the
-- markers, compare and set on backStep. A row with backPending or an unsettled give-back is a staff item (stuckPayments).

-- The claim undone: cash_reclaimed - amount and the markers cleared, only while backStep is still fromStep.
local function UndoBack(rowId, amount, fromStep)
    return Update([[
        UPDATE cp_mission_runs SET cash_reclaimed = cash_reclaimed - ?,
            breakdown = JSON_REMOVE(breakdown, '$.cash.backPending', '$.cash.backStep')
        WHERE id = ? AND cash_reclaimed >= ? AND JSON_VALUE(breakdown, '$.cash.backStep') = ?
    ]], { amount, rowId, amount, fromStep }) > 0
end

-- The money was taken: backs = n, the pending markers cleared (while backStep is still fromStep) and, with an account,
-- the give-back owed (owedTotal: what the department is owed on this row, earlier unpaid give-backs included).
local function BackDone(rowId, n, fromStep, account, owedTotal)
    if account then
        return Update([[
            UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(JSON_SET(breakdown, '$.cash.backs', ?,
                '$.cash.giveBack', 'owed', '$.cash.backOwed', ?, '$.cash.backAccount', ?),
                '$.cash.backPending', '$.cash.backStep')
            WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.backStep') = ?
        ]], { n, owedTotal, account, rowId, fromStep }) > 0
    end
    return Update([[
        UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(JSON_SET(breakdown, '$.cash.backs', ?),
            '$.cash.backPending', '$.cash.backStep')
        WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.backStep') = ?
    ]], { n, rowId, fromStep }) > 0
end

-- Gives the department what it is owed on a row (giveBack 'owed' -> 'paying' -> 'back'). A refusal puts it back to
-- 'owed' (the start-up sweep and the 10-minute job try again; Payments lists it); a raise with no telling leaves it
-- 'paying' for an admin. Runs under the officer's payment lock. -> true | false, errKey
local function GiveBackRow(rowId)
    local row = ReadRow(rowId)
    if not row then return false, 'err.row_not_found' end
    local bd = CP.U.jsonField(row.breakdown) or {}
    local c = CashOf(bd)
    if c.giveBack ~= 'owed' then return false, 'err.state_changed' end
    local amount = math.floor(Num(c.backOwed, 0))
    local account = c.backAccount
    if amount <= 0 or type(account) ~= 'string' or account == '' then return false, 'err.payment_step_unknown' end
    if not MarkIf(rowId, { giveBack = 'paying' }, 'giveBack', 'owed') then return false, 'err.state_changed' end
    local got = SocietyCall('depositSociety', account, amount, 1)
    if got == 'done' then
        Update([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.giveBack', 'back',
            '$.cash.backOwed', 0, '$.cash.backGiven', ?) WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.giveBack') = 'paying']],
            { math.floor(Num(c.backGiven, 0)) + amount, rowId })
        if CP.Banking and CP.Banking.recordSocietyDeposit then
            local dept = DeptOf(row.department)
            local message = CP.L('cash.clawback_message', { mission = MissionLabel(row, bd) })
            CP.Banking.recordSocietyDeposit(account, amount, message, row.citizenid,
                dept and dept.label or tostring(row.department), ('%s-back%d'):format(TxnOf(row), Num(c.backs, 0)))
        end
        return true
    end
    if got == 'refused' then
        MarkIf(rowId, { giveBack = 'owed' }, 'giveBack', 'paying')
        CP.warn(TAG, 'row %d: giving %d back to %s failed; it is owed and tried again later', rowId, amount, account)
        return false, 'err.payment_refund_failed'
    end
    CP.err(TAG, 'row %d: giving %d back to %s raised and its balance does not tell; it waits for an admin', rowId,
        amount, account)
    return false, 'err.payment_raised'
end

local function ClawbackLocked(row, rowId, amount)
    local cid = row.citizenid
    local src, info = OnlineOf(cid)
    if not src then
        UndoBack(rowId, amount, 'claimed')
        return false, 'err.officer_offline'
    end
    local fresh = ReadRow(rowId) or row
    local bd = CP.U.jsonField(fresh.breakdown) or {}
    local c = CashOf(bd)
    -- a give-back cut part way (no telling whether it arrived) is settled first: never added to
    if c.giveBack == 'paying' then
        UndoBack(rowId, amount, 'claimed')
        return false, 'err.payment_in_flight'
    end
    local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
    local balance = CP.Qbx.getMoney and CP.Qbx.getMoney(src, moneyAccount)
    if type(balance) ~= 'number' or balance < amount then
        UndoBack(rowId, amount, 'claimed')
        return false, 'err.balance_low'
    end
    -- the claim released meanwhile (the start-up sweep, an admin's Resolve): nothing is taken
    if not MarkIf(rowId, { backStep = 'removing' }, 'backStep', 'claimed') then return false, 'err.state_changed' end
    local before = BalanceOf(src, moneyAccount)
    local okR, why = false, nil
    if CP.Qbx.removeMoney then okR, why = CP.Qbx.removeMoney(src, moneyAccount, amount, 'crimson-police-clawback') end
    if not okR and why == 'error' then
        -- RemoveMoney raised: the balance decides (taken, refused, or no telling: the row waits for an admin)
        local o = Outcome(before, BalanceOf(src, moneyAccount), -amount)
        if o == 'unknown' then
            CP.err(
                TAG,
                'row %d: RemoveMoney raised during a clawback of %d and the balance does not tell; it waits '
                    .. 'for an admin in Payments',
                rowId,
                amount
            )
            return false, 'err.payment_raised'
        end
        okR = o == 'done'
    end
    if not okR then
        UndoBack(rowId, amount, 'removing')
        return false, 'err.clawback_refused'
    end
    local n = math.floor(Num(c.backs, 0)) + 1
    local transId = ('%s-back%d'):format(TxnOf(row), n)
    local dept = DeptOf(row.department)
    local deptLabel = dept and dept.label or tostring(row.department)
    local message = CP.L('cash.clawback_message', { mission = MissionLabel(row, bd) })
    -- the department gets it back only when it paid it
    local account = c.source == 'society' and (c.societyAccount or (dept and dept.societyAccount)) or nil
    local owed = (c.giveBack == 'owed' and math.floor(Num(c.backOwed, 0)) or 0) + amount
    local marked = BackDone(rowId, n, 'removing', account, owed)
    if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordWithdraw then
        CP.Banking.recordWithdraw(cid, amount, message, deptLabel, info.name or cid, transId)
    end
    local refunded = false
    if account then
        if marked then
            refunded = GiveBackRow(rowId) == true
        else
            -- the markers could not be written: the refund straight away, as before
            refunded = RefundSociety(account, amount)
            if refunded and CP.Banking and CP.Banking.recordSocietyDeposit then
                CP.Banking.recordSocietyDeposit(account, amount, message, info.name or cid, deptLabel, transId)
            end
        end
        if not refunded then
            CP.warn(TAG, 'row %d: the clawback of %d could not be put back into %s yet', rowId, amount,
                tostring(account))
        end
    end
    CP.notify(src, 'warning', 'cash.clawed_back', { amount = FmtMoney(amount), mission = MissionLabel(row, bd) })
    return true, { id = rowId, amount = amount, txn = transId, refunded = refunded }
end

-- Clawback: takes up to what was paid (minus what was taken back before) from an online officer. The increment of
-- cash_reclaimed is the claim, so two clicks never take more than was paid; a refused or failed removal takes it back.
-- One clawback per row at a time (backPending).
function Cash.clawback(rowId, amount, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'paid' and row.cash_status ~= 'capped' then return false, 'err.state_changed' end
    local n = math.tointeger(tonumber(amount))
    local left = math.floor(CP.U.num(row.cash_paid)) - math.floor(CP.U.num(row.cash_reclaimed))
    if not n or n < 1 then return false, 'err.invalid_amount' end
    if n > left then return false, 'err.clawback_too_much' end
    local c = CashOf(bd)
    -- a feature reward paid as a money item (account 'item'): Qbox has no such account to take it from
    if c.account == 'item' then return false, 'err.clawback_item' end
    if c.backPending ~= nil or c.giveBack == 'paying' then return false, 'err.payment_in_flight' end
    if not OnlineOf(row.citizenid) then return false, 'err.officer_offline' end
    local claimed = Update([[
        UPDATE cp_mission_runs SET cash_reclaimed = cash_reclaimed + ?,
            breakdown = JSON_SET(breakdown, '$.cash.backPending', ?, '$.cash.backStep', 'claimed')
        WHERE id = ? AND cash_status IN ('paid', 'capped') AND cash_reclaimed + ? <= cash_paid
          AND JSON_EXTRACT(breakdown, '$.cash') IS NOT NULL AND JSON_EXTRACT(breakdown, '$.cash.backPending') IS NULL
    ]], { n, n, rowId, n })
    if claimed < 1 then return false, 'err.clawback_too_much' end
    if not Audited(audit, { amount = n, left = left - n }) then
        UndoBack(rowId, n, 'claimed')
        return false, 'err.audit_failed'
    end
    return RunLocked(row.citizenid, function() return ClawbackLocked(row, rowId, n) end, function()
        UndoBack(rowId, n, 'claimed')
    end)
end

-- ============================================================================
--                                  FOLLOW-UPS
-- ============================================================================
-- PAY THE REST, CLAWBACK, GIVE-BACK LEFT PART WAY.
-- A row whose cash_status is final can still carry an admin tool left part way: the rest of a capped payment
-- (restPaid 'paying'), a clawback (backPending), or a give-back to the department (giveBack 'owed' or 'paying').
-- Cash.followUpOf names it; stuckPayments lists it (kind) and Payments resolves it (resolveFollowUp).

-- The same rows in SQL (on alias r): the Payments count and list read it.
Cash.FOLLOW_UP_SQL = [[(JSON_VALUE(r.breakdown, '$.cash.restPaid') = 'paying'
    OR JSON_EXTRACT(r.breakdown, '$.cash.backPending') IS NOT NULL
    OR JSON_VALUE(r.breakdown, '$.cash.giveBack') IN ('owed', 'paying'))]]

-- 'rest' | 'back' | 'giveBack' | nil
function Cash.followUpOf(bd)
    local c = type(bd) == 'table' and type(bd.cash) == 'table' and bd.cash or nil
    if not c then return nil end
    if c.restPaid == 'paying' then return 'rest' end
    if c.backPending ~= nil then return 'back' end
    if c.giveBack == 'owed' or c.giveBack == 'paying' then return 'giveBack' end
    return nil
end

-- The amount a follow-up is about: the rest owed, the clawback held, the give-back owed.
local function FollowUpAmount(row, bd, kind)
    local c = CashOf(bd)
    if kind == 'rest' then return math.max(0, AmountOf(row, bd) - math.floor(CP.U.num(row.cash_paid))) end
    if kind == 'back' then return math.floor(Num(c.backPending, 0)) end
    if kind == 'giveBack' then return math.floor(Num(c.backOwed, 0)) end
    return 0
end
Cash.followUpAmount = FollowUpAmount

-- What a follow-up's Resolve may do now: { outcome = true }. rest: 'restPaid' once a deposit was tried (adding,
-- review, added); 'restRelease' unless the money reached the officer ('added'): with no step it only releases, at
-- 'withdrawing' or 'refunding' (a department call cut part way) it only releases after the admin checked the
-- department's history, and after a department withdrawal ('withdrawn', 'adding', 'review') it gives the department
-- its money back first. back: 'backTaken' once RemoveMoney ran (removing), 'backUndone' always. giveBack: 'giveBack'
-- (try the deposit now) and 'giveBackDone' (it arrived, no money moves).
function Cash.followUpOutcomes(bd)
    local kind = Cash.followUpOf(bd)
    local c = CashOf(type(bd) == 'table' and bd or {})
    if kind == 'rest' then
        local st = c.restPaidStep
        return {
            restPaid = st == 'adding' or st == 'review' or st == 'added',
            restRelease = st ~= 'added',
        }
    elseif kind == 'back' then
        return { backTaken = c.backStep == 'removing', backUndone = true }
    elseif kind == 'giveBack' then
        return { giveBack = true, giveBackDone = true }
    end
    return {}
end

local function ResolveLocked(row, bd, rowId, outcome, amount)
    local c = CashOf(bd)
    if outcome == 'restPaid' then
        local newPaid = math.floor(CP.U.num(row.cash_paid)) + amount
        local n = Update([[
            UPDATE cp_mission_runs SET cash_paid = ?,
                breakdown = JSON_SET(breakdown, '$.cash.restPaid', 'paid', '$.cash.restAmount', ?, '$.cash.paid', ?,
                    '$.cash.restResolved', 'marked')
            WHERE id = ? AND cash_paid = ? AND JSON_VALUE(breakdown, '$.cash.restPaid') = 'paying'
        ]], { newPaid, amount, newPaid, rowId, math.floor(CP.U.num(row.cash_paid)) })
        if n < 1 then return false, 'err.state_changed' end
        return true, { id = rowId, outcome = outcome, amount = amount, paid = newPaid }
    elseif outcome == 'restRelease' then
        local st = c.restPaidStep
        -- the department paid (its account is kept on the row): it gets the rest back first
        local refund = (st == 'withdrawn' or st == 'adding' or st == 'review') and c.restPaidAccount ~= nil
        if st == nil or st == 'claimed' then
            if not Release(rowId, 'restPaid', ' AND JSON_EXTRACT(breakdown, \'$.cash.restPaidStep\') IS NULL') then
                return false, 'err.state_changed'
            end
        elseif refund then
            if not MarkIf(rowId, { restPaidStep = 'refunding' }, 'restPaidStep', st) then
                return false, 'err.state_changed'
            end
            if not RefundSociety(c.restPaidAccount, amount) then
                MarkIf(rowId, { restPaidStep = st }, 'restPaidStep', 'refunding')
                return false, 'err.payment_refund_failed'
            end
            if not Release(rowId, 'restPaid') then return false, 'err.state_changed' end
        elseif st == 'added' or not Release(rowId, 'restPaid') then
            -- 'withdrawing', 'refunding' (a department call cut part way: the admin checked its history) and a
            -- server-paid rest: it only releases
            return false, 'err.state_changed'
        end
        return true, { id = rowId, outcome = outcome, amount = amount }
    elseif outcome == 'backUndone' then
        if not UndoBack(rowId, amount, c.backStep) then return false, 'err.state_changed' end
        return true, { id = rowId, outcome = outcome, amount = amount }
    elseif outcome == 'backTaken' then
        local n = math.floor(Num(c.backs, 0)) + 1
        local dept = DeptOf(row.department)
        local account = c.source == 'society' and (c.societyAccount or (dept and dept.societyAccount)) or nil
        local owed = (c.giveBack == 'owed' and math.floor(Num(c.backOwed, 0)) or 0) + amount
        if not BackDone(rowId, n, 'removing', account, owed) then return false, 'err.state_changed' end
        local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
        if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordWithdraw then
            CP.Banking.recordWithdraw(row.citizenid, amount,
                CP.L('cash.clawback_message', { mission = MissionLabel(row, bd) }),
                dept and dept.label or tostring(row.department), row.citizenid, ('%s-back%d'):format(TxnOf(row), n))
        end
        local refunded = account ~= nil and GiveBackRow(rowId) == true
        return true, { id = rowId, outcome = outcome, amount = amount, refunded = refunded }
    elseif outcome == 'giveBack' then
        if c.giveBack == 'paying' and not MarkIf(rowId, { giveBack = 'owed' }, 'giveBack', 'paying') then
            return false, 'err.state_changed'
        end
        local ok, err = GiveBackRow(rowId)
        if not ok then return false, err end
        return true, { id = rowId, outcome = outcome, amount = amount }
    elseif outcome == 'giveBackDone' then
        local n = Update([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.giveBack', 'back',
            '$.cash.backOwed', 0, '$.cash.backGiven', ?, '$.cash.giveBackResolved', 'marked')
            WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.giveBack') = ?]],
            { math.floor(Num(c.backGiven, 0)) + amount, rowId, c.giveBack })
        if n < 1 then return false, 'err.state_changed' end
        return true, { id = rowId, outcome = outcome, amount = amount }
    end
    return false, 'err.invalid_payload'
end

-- Resolves a follow-up (Admin UI -> Payments -> Resolve): audit(info) first (false = nothing changes), then the
-- change under the officer's payment lock. -> ok, data | false, errKey
function Cash.resolveFollowUp(rowId, outcome, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    local kind = Cash.followUpOf(bd)
    if not kind then return false, 'err.state_changed' end
    if Cash.rowBusy(rowId, row.citizenid) then return false, 'err.payment_in_flight' end
    if not Cash.followUpOutcomes(bd)[outcome] then return false, 'err.payment_step_unknown' end
    local amount = FollowUpAmount(row, bd, kind)
    if amount <= 0 and outcome ~= 'backUndone' then return false, 'err.nothing_to_pay' end
    if
        not Audited(audit, {
            kind = kind,
            outcome = outcome,
            amount = amount,
            step = CashOf(bd)[({
                rest = 'restPaidStep',
                back = 'backStep',
                giveBack = 'giveBack',
            })[kind]],
        })
    then
        return false, 'err.audit_failed'
    end
    local st, a, b = payLock:run(row.citizenid, LOCK_WAIT_MS, ResolveLocked, row, bd, rowId, outcome, amount)
    if st == 'busy' then return false, 'err.payment_in_flight' end
    if st == 'error' then
        CP.err(TAG, 'resolving row %d (%s) failed: %s', rowId, outcome, tostring(a))
        return false, 'err.payment_raised'
    end
    return a, b
end

-- The give-backs a department is still owed, tried again (the start-up sweep and the 10-minute job). -> n given back
function Cash.retryGiveBacks()
    CP.Db()
    if PaymentsHeld() then return 0 end
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT id, citizenid FROM cp_mission_runs
        WHERE cash_status IN ('paid', 'capped') AND JSON_VALUE(breakdown, '$.cash.giveBack') = 'owed' ORDER BY id
    ]], {})
    if not ok then
        CP.err(TAG, 'the owed give-backs lookup failed: %s', tostring(rows))
        return 0
    end
    local n = 0
    for _, r in ipairs(rows or {}) do
        local id = math.floor(CP.U.num(r.id))
        local st, done = payLock:run(r.citizenid, LOCK_WAIT_MS, GiveBackRow, id)
        if st == 'ok' and done == true then n = n + 1 end
    end
    if n > 0 then CP.log(TAG, 'gave %d owed clawback(s) back to their departments', n) end
    return n
end

-- At the start: the claims of an admin tool cut before its first money call (no step marker yet) are released, so the
-- tool can be used again: Pay again (again, again2), Pay the rest (restPaid) and a clawback still at 'claimed' (its
-- increment taken back). Safe at any time: every later step of those tools is compare-and-set on the claim.
local function ReleaseUnstarted()
    CP.Db()
    if PaymentsHeld() then return 0 end
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT id, breakdown FROM cp_mission_runs
        WHERE cash_status IN ('paying', 'paid', 'capped')
          AND (JSON_VALUE(breakdown, '$.cash.again') = 'paying' OR JSON_VALUE(breakdown, '$.cash.again2') = 'paying'
               OR JSON_VALUE(breakdown, '$.cash.restPaid') = 'paying'
               OR JSON_VALUE(breakdown, '$.cash.backStep') = 'claimed')
        ORDER BY id
    ]], {})
    if not ok then
        CP.err(TAG, 'the start-up release of cut admin claims failed: %s', tostring(rows))
        return 0
    end
    local n = 0
    local NO_STEP = ' AND JSON_EXTRACT(breakdown, \'$.cash.%sStep\') IS NULL'
    for _, r in ipairs(rows or {}) do
        local id = math.floor(CP.U.num(r.id))
        local c = CashOf(CP.U.jsonField(r.breakdown) or {})
        for _, key in ipairs({ 'again2', 'again', 'restPaid' }) do
            if c[key] == 'paying' and c[key .. 'Step'] == nil and Release(id, key, NO_STEP:format(key)) then
                n = n + 1
            end
        end
        if c.backStep == 'claimed' and UndoBack(id, math.floor(Num(c.backPending, 0)), 'claimed') then n = n + 1 end
    end
    if n > 0 then CP.warn(TAG, 'released %d admin payment claim(s) cut before any money moved', n) end
    return n
end
Cash._releaseUnstarted = ReleaseUnstarted

-- ============================================================================
--                      STATUS CHANGES THAT MOVE NO MONEY
-- ============================================================================

-- unfunded -> pending (Retry unfunded) or forfeited -> pending (a restored run pays its forfeited cash after all):
-- the claim of the payment that follows. No money moved on either, so the transaction id stays unique.
function Cash.toPending(rowId, from)
    rowId = ToId(rowId)
    if not rowId then return false, 'err.invalid_row' end
    CP.Db()
    if PaymentsHeld() then return false, 'err.maintenance' end
    local extra = ''
    if from == 'forfeited' then
        extra = ' AND cash_paid = 0'
    elseif from ~= 'unfunded' then
        return false, 'err.invalid_payload'
    end
    local n = Update(
        ([[
        UPDATE cp_mission_runs
        SET cash_status = 'pending',
            breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', 'pending'))
        WHERE id = ? AND cash_status = ? AND state = 'completed' AND flagged = 0 AND voided = 0%s
    ]]):format(extra),
        { rowId, from }
    )
    if n < 1 then return false, 'err.state_changed' end
    return true
end

-- The claim of toPending undone (its audit row could not be written): pending -> from.
function Cash.backFromPending(rowId, from)
    rowId = ToId(rowId)
    if not rowId or (from ~= 'unfunded' and from ~= 'forfeited') then return false end
    return Update([[
        UPDATE cp_mission_runs
        SET cash_status = ?, breakdown = IF(breakdown IS NULL, NULL, JSON_SET(breakdown, '$.cash.status', ?))
        WHERE id = ? AND cash_status = 'pending'
    ]], { from, from, rowId }) > 0
end

-- held/pending -> forfeited by an admin. mode 'voided' (Forfeit now): a voided row with no open dispute, its held
-- item rewards go too (row:forfeited). mode 'cancel' (Cancel payment): any held or pending row, the run keeps its
-- points and its item rewards.
function Cash.adminForfeit(rowId, mode)
    rowId = ToId(rowId)
    if not rowId then return false, 'err.invalid_row' end
    CP.Db()
    local n
    if mode == 'voided' then
        n = Update([[
            UPDATE cp_mission_runs r
            SET r.cash_status = 'forfeited',
                r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, '$.cash.status', 'forfeited'))
            WHERE r.id = ? AND r.voided = 1 AND r.cash_status IN ('held', 'pending')
              AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
        ]], { rowId })
    elseif mode == 'cancel' then
        n = Update([[
            UPDATE cp_mission_runs
            SET cash_status = 'forfeited',
                breakdown = IF(breakdown IS NULL, NULL,
                    JSON_SET(breakdown, '$.cash.status', 'forfeited', '$.cash.cancelled', 'admin'))
            WHERE id = ? AND cash_status IN ('held', 'pending')
        ]], { rowId })
    else
        return false, 'err.invalid_payload'
    end
    if n < 1 then return false, 'err.state_changed' end
    if mode == 'voided' then FireForfeited(rowId) end
    return true
end

-- ============================================================================
--                                 BOARD RANGE
-- ============================================================================

local function PoolFor(missionType, members)
    if missionType == BOSS_KEY then
        local def = CP.Missions and CP.Missions.get and CP.Missions.get(BOSS_ID)
        return def and { def } or {}
    end
    if CP.Draw and CP.Draw.pool then
        local ok, list = pcall(CP.Draw.pool, missionType, members)
        if ok and type(list) == 'table' and #list > 0 then return list end
    end
    local out = {}
    if CP.Missions and CP.Missions.byType then
        local n = #members
        for _, def in ipairs(CP.Missions.byType(missionType) or {}) do
            local enabled = not CP.Missions.isEnabled or CP.Missions.isEnabled(def.id)
            if enabled and n >= Num(def.minOfficers, 1) and n <= Num(def.maxOfficers, 4) then out[#out + 1] = def end
        end
    end
    return out
end

function Cash.range(missionType, members)
    if type(members) ~= 'table' then members = {} end
    local size = math.max(1, #members)
    local tier = CP.Scaling and CP.Scaling.tierFor and CP.Scaling.tierFor(size) or { cash = 1.0 }
    local mTier = Num(tier and tier.cash, 1.0)
    local isBossCard = missionType == BOSS_KEY
    -- a random twist on top (Config.Events.modifierChance above 0): the top of the range covers the best one. The
    -- twists the officers choose themselves are shown with their own bonus at the accept step.
    local modCash = 1.0
    if not isBossCard and Num(Config.Events and Config.Events.modifierChance, 0) > 0 then
        for _, key in ipairs(CP.Twists.ORDER) do
            local c = CP.Twists.cfg(key)
            if c.enabled and c.cash > modCash then modCash = math.min(c.cash, CP.Twists.caps().cash) end
        end
    end
    local lo, hi
    for _, def in ipairs(PoolFor(missionType, members)) do
        local B = CP.Payouts and CP.Payouts.baseFor and CP.Payouts.baseFor(def) or 0
        if not lo or B < lo then lo = B end
        if not hi or B > hi then hi = B end
    end
    if not lo then
        if isBossCard then
            lo = math.floor(Num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.payout, 0))
        else
            lo = CP.Payouts and CP.Payouts.typePayout and CP.Payouts.typePayout(missionType)
                or math.floor(Num(Config.MissionTypes[missionType] and Config.MissionTypes[missionType].payout, 0))
        end
        hi = lo
    end
    return RoundMoney(lo * mTier), RoundMoney(hi * mTier * modCash)
end

-- ============================================================================
--                                   REPORTS
-- ============================================================================

function Cash.stuckPayments()
    CP.Db()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT r.id, r.run_uuid, r.citizenid, r.mission_id, r.department, r.cash_status, r.cash_base, r.cash_multiplier,
               r.cash_paid, r.breakdown, UNIX_TIMESTAMP(r.created_at) AS created_ts, o.display_name
        FROM cp_mission_runs r LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
        WHERE r.cash_status = 'paying' OR (r.cash_status IN ('paid', 'capped') AND ]] .. Cash.FOLLOW_UP_SQL .. [[)
        ORDER BY r.created_at, r.id
    ]], {})
    if not ok then
        CP.err(TAG, 'stuck payments lookup failed: %s', tostring(rows))
        return {}
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local id = math.floor(CP.U.num(r.id))
        if not rowLock:held(id) then
            local bd = CP.U.jsonField(r.breakdown)
            local kind = r.cash_status == 'paying' and 'pay' or Cash.followUpOf(bd)
            out[#out + 1] = {
                kind = kind,
                followUpAmount = kind ~= 'pay' and FollowUpAmount(r, bd or {}, kind) or nil,
                id = id,
                runUuid = r.run_uuid,
                citizenid = r.citizenid,
                name = type(r.display_name) == 'string' and r.display_name or r.citizenid,
                missionId = r.mission_id,
                missionLabel = MissionLabel(r, bd),
                department = r.department,
                amount = AmountOf(r, bd),
                step = type(bd) == 'table' and type(bd.cash) == 'table' and bd.cash.step or nil,
                createdAt = tonumber(r.created_ts),
                transId = ('CP-%s-%s'):format(tostring(r.run_uuid), tostring(r.citizenid)),
            }
        end
    end
    return out
end

function Cash.earnedThisWeek(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    CP.Db()
    local start = CP.Schedule and CP.Schedule.weekStart and CP.Schedule.weekStart() or (Now() - 7 * 86400)
    local ok, total = pcall(MySQL.scalar.await, [[
        SELECT COALESCE(SUM(cash_paid), 0) AS total FROM cp_mission_runs
        WHERE citizenid = ? AND cash_status IN ('paid', 'capped') AND created_at >= FROM_UNIXTIME(?)
    ]], { citizenid, start })
    if not ok then
        CP.err(TAG, 'weekly cash lookup for %s failed: %s', citizenid, tostring(total))
        return 0
    end
    return math.floor(CP.U.num(total))
end

-- ============================================================================
--                                    WIRING
-- ============================================================================

local function OnLoaded(src)
    local info = CP.Qbx.getInfo(src)
    local cid = info and info.citizenid
    if not cid then return end
    Wait(PENDING_DELAY_MS)
    local again = CP.Qbx.getInfo(src)
    if not again or again.citizenid ~= cid then return end
    Cash.payPending(src)
    -- officer:loaded (CP.Hooks): the same moment, e.g. for the Rewards locker retry
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('officer:loaded', src) end
end

CreateThread(function()
    if not CP.Qbx or not CP.Qbx.onPlayerLoaded then
        CP.err(TAG, 'modules/system/integrations/qbx is missing: pending payments are not paid on login')
    else
        CP.Qbx.onPlayerLoaded(OnLoaded)
    end
end)

local nextForfeitAt = nil   -- os.time() of the next forfeiture check (Admin UI -> Payments shows it)

-- Admin UI -> System -> Jobs lists it (its last result, Run now); the loop below runs it through the jobs engine.
local RunForfeiture = CP.Schedule.job('cash_forfeiture', {
    when = 'every',
    every = FORFEIT_EVERY_MS // 1000,
    manual = true,
    settings = { 'Disputes.windowHours' },
    run = ForfeitureJob,
})

CreateThread(function()
    -- a start that failed: the loop never starts (quietly; the console has the lines that say what failed)
    if CP.Migrations and CP.Migrations.started and not CP.Migrations.started() then return end
    while true do
        RunForfeiture()
        -- The clawbacks a department is still owed, tried again
        local okG, errG = pcall(Cash.retryGiveBacks)
        if not okG then CP.err(TAG, 'the owed give-backs retry failed: %s', tostring(errG)) end
        nextForfeitAt = os.time() + FORFEIT_EVERY_MS // 1000
        Wait(FORFEIT_EVERY_MS)
    end
end)

function Cash.nextForfeitureAt() return nextForfeitAt end

-- After a resource (re)start, officers who are already online never fire PlayerLoaded again: pay their
-- pending rows once, after Renewed-Banking has had time to (re)build its caches.
local function StartupSweep()
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers) then return 0 end
    local n = 0
    for _, src in ipairs(CP.Qbx.getOnlinePlayers()) do
        n = n + (Cash.payPending(src) or 0)
    end
    return n
end

-- A maintenance lock that ends without a restart (a store used again): the rows that waited are paid now.
if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('maintenance:changed', function(view)
        if view then return end
        CreateThread(function()
            local ok, err = pcall(StartupSweep)
            if not ok then CP.err(TAG, 'pending payments sweep after maintenance failed: %s', tostring(err)) end
        end)
    end)
end

CreateThread(function()
    Wait(STARTUP_SWEEP_MS)
    -- Admin claims a restart cut before any money moved are released first
    local okR, errR = pcall(ReleaseUnstarted)
    if not okR then CP.err(TAG, 'the start-up release of cut admin claims failed: %s', tostring(errR)) end
    local ok, err = pcall(StartupSweep)
    if not ok then CP.err(TAG, 'pending payments sweep at start failed: %s', tostring(err)) end
end)

-- Test hooks (not part of the contract).
Cash._forfeitureJob = ForfeitureJob
Cash._startupSweep = StartupSweep
Cash._onLoaded = OnLoaded
Cash._fmtMoney = FmtMoney
