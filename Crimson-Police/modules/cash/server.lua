-- CP.Cash (server): the cash formula and every payment Crimson-Police makes.

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

local locks = {}       -- citizenid -> true while one of their rows is being paid
local inFlight = {}    -- rowId -> true while pay() works on it

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function ToId(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function FmtMoney(n)
    local s = tostring(math.floor(math.abs(Num(n, 0)) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (Num(n, 0) < 0 and '-$' or '$') .. out
end

local function TierRow(run)
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
    local waited = 0
    while locks[key] do
        if waited >= LOCK_WAIT_MS then
            CP.warn(TAG, 'payment lock for %s is still held after %d ms; skipping this attempt', key, waited)
            return nil
        end
        Wait(50)
        waited = waited + 50
    end
    locks[key] = true
    local ok, res = pcall(fn)
    locks[key] = nil
    if not ok then
        CP.err(TAG, 'payment for %s failed: %s', key, tostring(res))
        return nil
    end
    return res
end

local function Notify(src, kind, key, vars)
    if src and CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(src, kind, key, vars) end
end

-- A maintenance lock (a storage copy or switch, a backup restore) holds every payment back: the rows wait and are
-- paid after the restart. A store left behind by a storage switch never pays (its rows may be paid in the new one).
local function PaymentsHeld()
    if not (CP.Maintenance and CP.Maintenance.active) then return nil end
    local ok, kind = pcall(CP.Maintenance.active)
    return ok and kind or nil
end

-- A department for a payment, a turned-off one included (its unfinished pay still pays from its account).
local function DeptOf(key)
    local d = CP.Access and CP.Access.department and CP.Access.department(key) or nil
    if d then return d end
    local cfg = type(key) == 'string' and type(Config.Departments) == 'table' and Config.Departments[key] or nil
    if type(cfg) ~= 'table' then return nil end
    local account = type(cfg.societyAccount) == 'string' and cfg.societyAccount ~= '' and cfg.societyAccount
        or (type(cfg.jobs) == 'table' and cfg.jobs[1]) or key
    return { key = key, label = type(cfg.label) == 'string' and cfg.label or key, societyAccount = account }
end

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

function Cash.compute(run, p)
    if type(run) ~= 'table' or type(p) ~= 'table' then
        return 0, { B = 0, mTier = 1.0, mMod = 1.0, amount = 0, status = 'none' }
    end
    local B = math.max(0, math.floor(Num(run.cashBase, 0) + 0.5))
    local mTier = Num(TierRow(run).cash, 1.0)
    local mMod = 1.0
    if run.modifier then mMod = Num(Config.Events and Config.Events.modifierCash, 1.0) end
    local amount = 0
    if p.result == 'completed' and not PresenceFailed(run, p) then
        amount = math.max(0, RoundMoney(B * mTier * mMod))
    end
    local flagged = p.flagged ~= nil or run.flagged ~= nil
    local status = 'none'
    if p.result == 'completed' and flagged and not run.test then status = 'held' end
    return amount, { B = B, mTier = mTier, mMod = mMod, amount = amount, status = status }
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

local function RefundSociety(account, amount)
    if CP.Banking and CP.Banking.depositSociety then
        local ok, res = pcall(CP.Banking.depositSociety, account, amount)
        return ok and res == true
    end
    return false
end

local PayClaimed

-- Pays one claimed-or-claimable row. Runs under the citizenid lock.
local function PayRow(row)
    local rowId = math.floor(CP.U.num(row.id))
    local cid = row.citizenid
    local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(cid)

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
    local bd = CP.U.jsonField(row.breakdown)
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

    local society = Config.Cash and Config.Cash.source == 'society'
    local account = dept and dept.societyAccount
    local moneyAccount = (Config.Cash and Config.Cash.account) or 'bank'
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
    local withdrew = false
    if amount > 0 and society then
        local okW = false
        if type(account) == 'string' and account ~= '' and CP.Banking and CP.Banking.withdrawSociety then
            progress.moved = true
            okW = CP.Banking.withdrawSociety(account, amount) == true
            if not okW then progress.moved = false end
        end
        if not okW then
            SetFinal(rowId, 'unfunded', 0)
            CP.warn(TAG, 'row %d unfunded: society account %s could not cover %d', rowId, tostring(account), amount)
            Notify(src, 'error', 'cash.unfunded',
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
        progress.moved = true
        local okMoney, whyMoney = false, nil
        if CP.Qbx.addMoney then
            okMoney, whyMoney = CP.Qbx.addMoney(src, moneyAccount, amount, 'crimson-police-mission')
        end
        if not okMoney and whyMoney == 'error' then
            -- AddMoney raised: the balance may already have changed, so the row is never retried automatically
            -- (it stays paying and is listed in stuckPayments for a manual check; no society refund either).
            CP.err(TAG,
                'row %d: Qbox AddMoney(%s, %d) raised for %s; the row stays paying for a manual check (transaction %s)',
                rowId, moneyAccount, amount, cid, transId)
            return 'paying'
        end
        if not okMoney then
            if withdrew then
                if RefundSociety(account, amount) then
                    BackToPending(rowId, 'Qbox AddMoney failed; the society withdrawal was refunded')
                    return 'pending'
                end
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
        Notify(src, 'warning', 'cash.capped', { amount = FmtMoney(amount), mission = label })
    elseif amount > 0 then
        Notify(src, 'success', 'cash.paid', { amount = FmtMoney(amount), mission = label })
    end
    return status
end

-- Cash counted against the daily cap today (manual cash payments left out). nil when the lookup failed.
function Cash.paidToday(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    Db()
    return PaidOnDay(citizenid, Now())
end

function Cash.pay(rowId)
    rowId = ToId(rowId)
    if not rowId then return nil end
    if PaymentsHeld() then
        CP.log(TAG, 'row %d waits: payments are held by the maintenance lock', rowId)
        return nil
    end
    Db()
    local row = ReadRow(rowId)
    if not row then return nil end
    if FINAL[row.cash_status] or row.cash_status == 'paying' then return row.cash_status end
    if row.state ~= 'completed' or CP.U.truthy(row.flagged) or CP.U.truthy(row.voided) then
        CP.log(TAG, 'row %d is not payable (state %s, flagged %s, voided %s)', rowId, tostring(row.state),
            tostring(row.flagged), tostring(row.voided))
        return nil
    end
    if inFlight[rowId] then return nil end
    inFlight[rowId] = true
    local status = WithLock(row.citizenid, function() return PayRow(row) end)
    inFlight[rowId] = nil
    return status
end

function Cash.payPending(src)
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return 0 end
    if PaymentsHeld() then return 0 end
    Db()
    -- 'pending' rows, plus completed mission rows still 'none' although they carry cash (the engine's pay never
    -- ran or was skipped, e.g. a crash right after the row insert): no money moved on either, and pay() claims
    -- them like any other row. Manual award and goal rows never carry cash.
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT id FROM cp_mission_runs
        WHERE citizenid = ? AND state = 'completed' AND flagged = 0 AND voided = 0
          AND (cash_status = 'pending'
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
    Db()
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
    Db()
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

-- Voided rows whose dispute window closed with no open dispute: held/pending -> forfeited. Row by row, each
-- claimed by its own UPDATE, so row:forfeited (held item rewards) fires once per row that changed.
local function ForfeitRows()
    local hours = Num(Config.Disputes and Config.Disputes.windowHours, 48)
    local cutoff = Now() - math.floor(hours * 3600)
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT r.id FROM cp_mission_runs r
        WHERE r.voided = 1 AND r.cash_status IN ('held', 'pending') AND r.created_at < FROM_UNIXTIME(?)
          AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
        ORDER BY r.id
    ]], { cutoff })
    if not ok then
        CP.err(TAG, 'forfeiture job failed: %s', tostring(rows))
        return 0
    end
    local n = 0
    for _, row in ipairs(rows or {}) do
        local id = ToId(row.id)
        local okU, changed = pcall(MySQL.update.await, [[
            UPDATE cp_mission_runs r
            SET r.cash_status = 'forfeited',
                r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, '$.cash.status', 'forfeited'))
            WHERE r.id = ? AND r.voided = 1 AND r.cash_status IN ('held', 'pending')
              AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
        ]], { id })
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
    if PaymentsHeld() then return 0 end
    Db()
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
    if PaymentsHeld() then return nil, 'err.maintenance' end
    Db()
    local row = ReadRow(rowId)
    if not row then return nil, 'err.row_not_found' end
    return row, CP.U.jsonField(row.breakdown) or {}
end

local function CashOf(bd) return type(bd.cash) == 'table' and bd.cash or {} end

local function TxnOf(row) return ('CP-%s-%s'):format(tostring(row.run_uuid), tostring(row.citizenid)) end

local function Update(sql, params)
    local ok, n = pcall(MySQL.update.await, sql, params)
    if not ok then
        CP.err(TAG, 'payment update failed: %s', tostring(n))
        return 0
    end
    return tonumber(n) or 0
end

-- Undoes a JSON claim marker (breakdown.cash.<key>) that is still 'paying'.
local function Release(rowId, key)
    Update(
        ([[UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(breakdown, '$.cash.%s')
        WHERE id = ? AND JSON_VALUE(breakdown, '$.cash.%s') = 'paying']]):format(key, key),
        { rowId }
    )
end

-- Claims a JSON marker (breakdown.cash.<key> = 'paying') on a row in status: only one caller wins.
local function ClaimMarker(rowId, key, status, extraWhere)
    return Update(
        ([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.%s', 'paying')
        WHERE id = ? AND cash_status = ? AND voided = 0 AND JSON_EXTRACT(breakdown, '$.cash') IS NOT NULL
          AND JSON_EXTRACT(breakdown, '$.cash.%s') IS NULL%s]]):format(key, key, extraWhere or ''),
        { rowId, status }
    ) > 0
end

-- fn() under the officer's payment lock. The claim is undone (onTimeout) when the lock stays taken; an error after
-- the claim leaves it for a manual check, because money may have moved.
local function RunLocked(cid, fn, onTimeout)
    local waited = 0
    while locks[cid] do
        if waited >= LOCK_WAIT_MS then
            onTimeout()
            return false, 'err.payment_in_flight'
        end
        Wait(50)
        waited = waited + 50
    end
    locks[cid] = true
    local res = table.pack(pcall(fn))
    locks[cid] = nil
    if not res[1] then
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
    local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(cid)
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

function Cash.department(key) return DeptOf(key) end

-- true while pay() works on the row or the officer's payment lock is held (an admin waits for it).
function Cash.rowBusy(rowId, citizenid)
    rowId = ToId(rowId)
    return (rowId ~= nil and inFlight[rowId] == true) or (type(citizenid) == 'string' and locks[citizenid] == true)
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

local function PayAgainLocked(row, bd, rowId, amount, needWithdraw)
    local cid = row.citizenid
    local src, info = OnlineOf(cid)
    if not src then
        Release(rowId, 'again')
        return false, 'err.officer_offline'
    end
    local c = CashOf(bd)
    local dept = DeptOf(row.department)
    local account = c.societyAccount or (dept and dept.societyAccount)
    local deptLabel = dept and dept.label or tostring(row.department)
    local label = MissionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = TxnOf(row) .. '-r2'
    if needWithdraw then
        local okW = type(account) == 'string' and account ~= '' and CP.Banking and CP.Banking.withdrawSociety
            and CP.Banking.withdrawSociety(account, amount) == true
        if not okW then
            Release(rowId, 'again')
            return false, 'err.unfunded_now'
        end
        Mark(rowId, { againStep = 'withdrawn' }, 'paying')
    end
    local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
    local okMoney, why = false, nil
    if CP.Qbx.addMoney then okMoney, why = CP.Qbx.addMoney(src, moneyAccount, amount, 'crimson-police-mission') end
    if not okMoney and why == 'error' then
        CP.err(TAG, 'row %d: Pay again raised in AddMoney; it stays paying for a manual check (transaction %s)', rowId,
            transId)
        return false, 'err.payment_raised'
    end
    if not okMoney then
        if needWithdraw and not RefundSociety(account, amount) then
            CP.err(TAG, 'row %d: Pay again failed after %s was debited %d; it stays paying (transaction %s)', rowId,
                tostring(account), amount, transId)
            return false, 'err.payment_refused'
        end
        Release(rowId, 'again')
        return false, 'err.payment_refused'
    end
    if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordDeposit then
        CP.Banking.recordDeposit(cid, amount, message, deptLabel, info.name or cid, transId)
    end
    if needWithdraw and CP.Banking and CP.Banking.recordSocietyWithdraw then
        CP.Banking.recordSocietyWithdraw(account, amount, message, deptLabel, info.name or cid, transId)
    end
    local owed = AmountOf(row, bd)
    local status = amount < owed and 'capped' or 'paid'
    local n = Update([[
        UPDATE cp_mission_runs
        SET cash_status = ?, cash_paid = ?,
            breakdown = JSON_SET(breakdown, '$.cash.status', ?, '$.cash.paid', ?, '$.cash.again', 'paid',
                '$.cash.againTxn', ?)
        WHERE id = ? AND cash_status = 'paying'
    ]], { status, amount, status, amount, transId, rowId })
    if n < 1 then
        CP.err(TAG, 'row %d: Pay again paid %d but the status could not be written (transaction %s)', rowId, amount,
            transId)
    end
    Notify(src, 'success', 'cash.paid', { amount = FmtMoney(amount), mission = label })
    return true, { id = rowId, status = status, amount = amount, txn = transId }
end

-- Pay again: the admin checked the bank history and the money did not arrive. The step markers say what already
-- happened: at 'withdrawn' the department already paid, so only AddMoney runs; at 'claimed' both run; at 'added'
-- the money arrived (Mark paid instead). Its own transaction id CP-<uuid>-<cid>-r2. The officer must be online.
function Cash.payAgain(rowId, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'paying' then return false, 'err.state_changed' end
    if Cash.rowBusy(rowId, row.citizenid) then return false, 'err.payment_in_flight' end
    local c = CashOf(bd)
    if c.again ~= nil then return false, 'err.state_changed' end
    if c.step == 'added' then return false, 'err.payment_arrived' end
    local source = c.source
    if source == nil then
        -- a payment from before the step markers: only safe when nothing was taken from a department
        if Config.Cash and Config.Cash.source == 'society' then return false, 'err.payment_step_unknown' end
        source = 'server'
    end
    local needWithdraw = source == 'society' and c.step ~= 'withdrawn'
    local amount = PayAmountOf(bd) or AmountOf(row, bd)
    if amount <= 0 then return false, 'err.nothing_to_pay' end
    if not OnlineOf(row.citizenid) then return false, 'err.officer_offline' end
    if not ClaimMarker(rowId, 'again', 'paying') then return false, 'err.state_changed' end
    if not Audited(audit, { amount = amount, step = c.step or 'unknown', withdraw = needWithdraw }) then
        Release(rowId, 'again')
        return false, 'err.audit_failed'
    end
    return RunLocked(row.citizenid, function()
        return PayAgainLocked(row, bd, rowId, amount, needWithdraw)
    end, function() Release(rowId, 'again') end)
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
    local society = Config.Cash and Config.Cash.source == 'society'
    local deptLabel = dept and dept.label or tostring(row.department)
    local label = MissionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = TxnOf(row) .. '-r'
    if society then
        local okW = type(account) == 'string' and account ~= '' and CP.Banking and CP.Banking.withdrawSociety
            and CP.Banking.withdrawSociety(account, rest) == true
        if not okW then
            Release(rowId, 'restPaid')
            return false, 'err.unfunded_now'
        end
    end
    local moneyAccount = CashOf(bd).account or (Config.Cash and Config.Cash.account) or 'bank'
    local okMoney, why = false, nil
    if CP.Qbx.addMoney then okMoney, why = CP.Qbx.addMoney(src, moneyAccount, rest, 'crimson-police-mission') end
    if not okMoney and why == 'error' then
        CP.err(TAG, 'row %d: paying the capped rest raised in AddMoney; its marker stays paying (transaction %s)',
            rowId, transId)
        return false, 'err.payment_raised'
    end
    if not okMoney then
        if society and not RefundSociety(account, rest) then
            CP.err(TAG, 'row %d: the capped rest failed after %s was debited %d (transaction %s)', rowId,
                tostring(account), rest, transId)
            return false, 'err.payment_refused'
        end
        Release(rowId, 'restPaid')
        return false, 'err.payment_refused'
    end
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
    Notify(src, 'success', 'cash.paid', { amount = FmtMoney(rest), mission = label })
    return true, { id = rowId, amount = rest, paid = newPaid, txn = transId }
end

-- Pay the rest: the part of a capped payment the daily cap cut (owed - paid, computed here), once per row, with its
-- own transaction id CP-<uuid>-<cid>-r. The officer must be online. The status stays capped.
function Cash.payCapRest(rowId, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'capped' or CP.U.truthy(row.voided) then return false, 'err.state_changed' end
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

local function TakeBackIncrement(rowId, amount)
    Update('UPDATE cp_mission_runs SET cash_reclaimed = cash_reclaimed - ? WHERE id = ? AND cash_reclaimed >= ?',
        { amount, rowId, amount })
end

local function ClawbackLocked(row, rowId, amount)
    local cid = row.citizenid
    local src, info = OnlineOf(cid)
    if not src then
        TakeBackIncrement(rowId, amount)
        return false, 'err.officer_offline'
    end
    local fresh = ReadRow(rowId) or row
    local bd = CP.U.jsonField(fresh.breakdown) or {}
    local c = CashOf(bd)
    local moneyAccount = c.account or (Config.Cash and Config.Cash.account) or 'bank'
    local balance = CP.Qbx.getMoney and CP.Qbx.getMoney(src, moneyAccount)
    if type(balance) ~= 'number' or balance < amount then
        TakeBackIncrement(rowId, amount)
        return false, 'err.balance_low'
    end
    local okR, why = false, nil
    if CP.Qbx.removeMoney then okR, why = CP.Qbx.removeMoney(src, moneyAccount, amount, 'crimson-police-clawback') end
    if not okR and why == 'error' then
        CP.err(TAG, 'row %d: RemoveMoney raised during a clawback of %d; check the officer\'s balance', rowId, amount)
        return false, 'err.payment_raised'
    end
    if not okR then
        TakeBackIncrement(rowId, amount)
        return false, 'err.clawback_refused'
    end
    local n = math.floor(Num(c.backs, 0)) + 1
    local transId = ('%s-back%d'):format(TxnOf(row), n)
    Mark(rowId, { backs = n }, { 'paid', 'capped' })
    local dept = DeptOf(row.department)
    local deptLabel = dept and dept.label or tostring(row.department)
    local message = CP.L('cash.clawback_message', { mission = MissionLabel(row, bd) })
    if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordWithdraw then
        CP.Banking.recordWithdraw(cid, amount, message, deptLabel, info.name or cid, transId)
    end
    -- the department gets it back only when it paid it
    local refunded = false
    if c.source == 'society' then
        local account = c.societyAccount or (dept and dept.societyAccount)
        refunded = RefundSociety(account, amount)
        if refunded and CP.Banking and CP.Banking.recordSocietyDeposit then
            CP.Banking.recordSocietyDeposit(account, amount, message, info.name or cid, deptLabel, transId)
        end
        if not refunded then
            CP.warn(TAG, 'row %d: the clawback of %d could not be put back into %s', rowId, amount, tostring(account))
        end
    end
    Notify(src, 'warning', 'cash.clawed_back', { amount = FmtMoney(amount), mission = MissionLabel(row, bd) })
    return true, { id = rowId, amount = amount, txn = transId, refunded = refunded }
end

-- Clawback: takes up to what was paid (minus what was taken back before) from an online officer. The increment of
-- cash_reclaimed is the claim, so two clicks never take more than was paid; a refused or failed removal takes it back.
function Cash.clawback(rowId, amount, audit)
    local row, bd = Clean(rowId)
    if not row then return false, bd end
    rowId = math.floor(CP.U.num(row.id))
    if row.cash_status ~= 'paid' and row.cash_status ~= 'capped' then return false, 'err.state_changed' end
    local n = math.tointeger(tonumber(amount))
    local left = math.floor(CP.U.num(row.cash_paid)) - math.floor(CP.U.num(row.cash_reclaimed))
    if not n or n < 1 then return false, 'err.invalid_amount' end
    if n > left then return false, 'err.clawback_too_much' end
    if not OnlineOf(row.citizenid) then return false, 'err.officer_offline' end
    local claimed = Update([[
        UPDATE cp_mission_runs SET cash_reclaimed = cash_reclaimed + ?
        WHERE id = ? AND cash_status IN ('paid', 'capped') AND cash_reclaimed + ? <= cash_paid
    ]], { n, rowId, n })
    if claimed < 1 then return false, 'err.clawback_too_much' end
    if not Audited(audit, { amount = n, left = left - n }) then
        TakeBackIncrement(rowId, n)
        return false, 'err.audit_failed'
    end
    return RunLocked(row.citizenid, function() return ClawbackLocked(row, rowId, n) end, function()
        TakeBackIncrement(rowId, n)
    end)
end

-- ============================================================================
--                      STATUS CHANGES THAT MOVE NO MONEY
-- ============================================================================

-- unfunded -> pending (Retry unfunded) or forfeited -> pending (a restored run pays its forfeited cash after all):
-- the claim of the payment that follows. No money moved on either, so the transaction id stays unique.
function Cash.toPending(rowId, from)
    rowId = ToId(rowId)
    if not rowId then return false, 'err.invalid_row' end
    if PaymentsHeld() then return false, 'err.maintenance' end
    Db()
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
    Db()
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
    local modCash = 1.0
    if not isBossCard and Num(Config.Events and Config.Events.modifierChance, 0) > 0 then
        modCash = math.max(1.0, Num(Config.Events and Config.Events.modifierCash, 1.0))
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
    Db()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT r.id, r.run_uuid, r.citizenid, r.mission_id, r.department, r.cash_base, r.cash_multiplier, r.breakdown,
               UNIX_TIMESTAMP(r.created_at) AS created_ts, o.display_name
        FROM cp_mission_runs r LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
        WHERE r.cash_status = 'paying'
        ORDER BY r.created_at, r.id
    ]], {})
    if not ok then
        CP.err(TAG, 'stuck payments lookup failed: %s', tostring(rows))
        return {}
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local id = math.floor(CP.U.num(r.id))
        if not inFlight[id] then
            local bd = CP.U.jsonField(r.breakdown)
            out[#out + 1] = {
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
    Db()
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
        CP.err(TAG, 'modules/integrations/qbx is missing: pending payments are not paid on login')
    else
        CP.Qbx.onPlayerLoaded(OnLoaded)
    end
end)

local nextForfeitAt = nil   -- os.time() of the next forfeiture check (Admin UI -> Payments shows it)

CreateThread(function()
    Db()
    while true do
        ForfeitureJob()
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
    local ok, err = pcall(StartupSweep)
    if not ok then CP.err(TAG, 'pending payments sweep at start failed: %s', tostring(err)) end
end)

-- Test hooks (not part of the contract).
Cash._forfeitureJob = ForfeitureJob
Cash._startupSweep = StartupSweep
Cash._onLoaded = OnLoaded
Cash._fmtMoney = FmtMoney
