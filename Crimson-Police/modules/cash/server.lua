-- modules/cash/server.lua · CP.Cash (server): the cash formula and every payment Crimson-Police makes.
--
-- Owns
--   * cash per participant = round(B x M_tier x M_mod) (SPEC "Cash payouts"): B = run.cashBase, locked at
--     accept by CP.Payouts.baseFor; M_tier = the run's points and cash tier (Config.Scaling cash); M_mod =
--     Config.Events.modifierCash when the run rolled a modifier. Only Completed results pay; a participant
--     who failed the presence share (runs with 2+ participants) gets $0.
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
-- Public API (docs/ARCHITECTURE.md §5.20)
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
--   CP.Cash.stuckPayments() -> { StuckPayment... }     rows still 'paying' (not being paid right now)
--       StuckPayment = { id, runUuid, citizenid, name, missionId, missionLabel, department, amount, createdAt, transId }
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
local FINAL = { paid = true, capped = true, unfunded = true, forfeited = true }

local locks = {}       -- citizenid -> true while one of their rows is being paid
local inFlight = {}    -- rowId -> true while pay() works on it

-- ── helpers ─────────────────────────────────────────────────────────────────
local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function toId(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function fmtMoney(n)
    local s = tostring(math.floor(math.abs(num(n, 0)) + 0.5))
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (num(n, 0) < 0 and '-$' or '$') .. out
end

local function tierRow(run)
    local t = run.payTier
    if type(t) == 'table' then return t end
    if CP.Scaling and CP.Scaling.tierByName then
        local row = CP.Scaling.tierByName(t or run.expectedTier)
        if row then return row end
    end
    return { tier = 'standard', cash = 1.0, points = 1.0 }
end

local function presenceFailed(run, p)
    if not (CP.AntiCheat and CP.AntiCheat.presenceOk) then return false end
    if type(run.order) ~= 'table' or #run.order < 2 then return false end
    local ok, present = pcall(CP.AntiCheat.presenceOk, run, p)
    return ok and present == false
end

local function withLock(key, fn)
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

local function notify(src, kind, key, vars)
    if src and CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(src, kind, key, vars) end
end

-- ── compute ─────────────────────────────────────────────────────────────────
-- Round to the nearest dollar, halves up. The epsilon absorbs float error in the product (350 * 1.15 is
-- 402.49999999999994 in doubles, a true $402.50 that must pay $403).
local function roundMoney(x)
    return math.floor(x + 0.5 + 1e-7)
end

function Cash.compute(run, p)
    if type(run) ~= 'table' or type(p) ~= 'table' then
        return 0, { B = 0, mTier = 1.0, mMod = 1.0, amount = 0, status = 'none' }
    end
    local B = math.max(0, math.floor(num(run.cashBase, 0) + 0.5))
    local mTier = num(tierRow(run).cash, 1.0)
    local mMod = 1.0
    if run.modifier then mMod = num(Config.Events and Config.Events.modifierCash, 1.0) end
    local amount = 0
    if p.result == 'completed' and not presenceFailed(run, p) then
        amount = math.max(0, roundMoney(B * mTier * mMod))
    end
    local flagged = p.flagged ~= nil or run.flagged ~= nil
    local status = 'none'
    if p.result == 'completed' and flagged and not run.test then status = 'held' end
    return amount, { B = B, mTier = mTier, mMod = mMod, amount = amount, status = status }
end

-- ── rows ────────────────────────────────────────────────────────────────────
local function readRow(rowId)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT id, run_uuid, citizenid, mission_id, mission_type, department, state, cash_status, cash_base,
               cash_multiplier, cash_paid, flagged, voided, breakdown, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_mission_runs WHERE id = ?
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'reading row %d failed: %s', rowId, tostring(row))
        return nil
    end
    if type(row) ~= 'table' or row.id == nil then return nil end
    return row
end

local function amountOf(row, bd)
    local a = bd and type(bd.cash) == 'table' and tonumber(bd.cash.amount) or nil
    if a == nil then a = num(row.cash_base, 0) * num(row.cash_multiplier, 1.0) end
    return math.max(0, math.floor(a + 0.5))
end

local function missionLabel(row, bd)
    if bd and type(bd.missionLabel) == 'string' and bd.missionLabel ~= '' then return bd.missionLabel end
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(row.mission_id)
    if def and def.label then return def.label end
    return tostring(row.mission_id)
end

local function setFinal(rowId, status, paid)
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

local function backToPending(rowId, why)
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

-- Paid (or capped) cash on the reset-day of ts, excluding the row being paid.
local function paidOnDay(citizenid, ts)
    local startTs = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(ts) or (ts - ts % 86400)
    local nextTs = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(startTs + 25 * 3600) or (startTs + 86400)
    local ok, total = pcall(MySQL.scalar.await, [[
        SELECT COALESCE(SUM(cash_paid), 0) AS total FROM cp_mission_runs
        WHERE citizenid = ? AND cash_status IN ('paid', 'capped')
          AND created_at >= FROM_UNIXTIME(?) AND created_at < FROM_UNIXTIME(?)
    ]], { citizenid, startTs, nextTs })
    if not ok then
        CP.err(TAG, 'daily cap lookup for %s failed: %s', citizenid, tostring(total))
        return nil
    end
    return math.floor(CP.U.num(total))
end

-- Online supervisors of a department (for the unfunded warning).
local function supervisorsOf(dept)
    local out = {}
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Access and CP.Access.getOfficer) then return out end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
        local o = CP.Access.getOfficer(s)
        if o and o.department == dept and o.isSupervisor then out[#out + 1] = s end
    end
    return out
end

local function refundSociety(account, amount)
    if CP.Banking and CP.Banking.depositSociety then
        local ok, res = pcall(CP.Banking.depositSociety, account, amount)
        return ok and res == true
    end
    return false
end

local payClaimed

-- Pays one claimed-or-claimable row. Runs under the citizenid lock.
local function payRow(row)
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
    local okP, res = pcall(payClaimed, row, rowId, cid, src, progress)
    if okP then return res end
    if not progress.moved then
        backToPending(rowId, 'error before any money moved: ' .. tostring(res))
        return 'pending'
    end
    CP.err(TAG, 'row %d: error after money may have moved; it stays paying for a manual check: %s', rowId, tostring(res))
    return 'paying'
end

-- The claimed part of payRow (row is 'paying'). progress.moved = true right before the first call that can move money.
payClaimed = function(row, rowId, cid, src, progress)
    local bd = CP.U.jsonField(row.breakdown)
    local amount = amountOf(row, bd)
    local capped = false
    local cap = math.floor(num(Config.Cash and Config.Cash.dailyCap, 0))
    if cap > 0 and amount > 0 then
        local already = paidOnDay(cid, tonumber(row.created_ts) or now())
        if already == nil then
            backToPending(rowId, 'daily cap lookup failed')
            return 'pending'
        end
        if already + amount > cap then
            amount = math.max(0, cap - already)
            capped = true
        end
    end

    local deptKey = row.department
    local dept = CP.Access and CP.Access.department and CP.Access.department(deptKey) or nil
    local deptLabel = dept and dept.label or tostring(deptKey)
    local label = missionLabel(row, bd)
    local message = CP.L('cash.bank_message', { mission = label })
    local transId = ('CP-%s-%s'):format(tostring(row.run_uuid), tostring(cid))

    -- Re-fetch the player right before money moves.
    local info = CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or info.citizenid ~= cid then
        backToPending(rowId, 'the officer went offline before the payment')
        return 'pending'
    end
    local charName = info.name or cid

    local society = Config.Cash and Config.Cash.source == 'society'
    local account = dept and dept.societyAccount
    local withdrew = false
    if amount > 0 and society then
        local okW = false
        if type(account) == 'string' and account ~= '' and CP.Banking and CP.Banking.withdrawSociety then
            progress.moved = true
            okW = CP.Banking.withdrawSociety(account, amount) == true
            if not okW then progress.moved = false end
        end
        if not okW then
            setFinal(rowId, 'unfunded', 0)
            CP.warn(TAG, 'row %d unfunded: society account %s could not cover %d', rowId, tostring(account), amount)
            notify(src, 'error', 'cash.unfunded', { amount = fmtMoney(amount), department = deptLabel, mission = label })
            local sups = supervisorsOf(deptKey)
            if #sups > 0 and CP.Tablet and CP.Tablet.notifyMany then
                CP.Tablet.notifyMany(sups, 'warning', 'cash.unfunded_supervisor',
                    { name = charName, amount = fmtMoney(amount), department = deptLabel, account = tostring(account) })
            end
            return 'unfunded'
        end
        withdrew = true
    end

    if amount > 0 then
        local moneyAccount = (Config.Cash and Config.Cash.account) or 'bank'
        progress.moved = true
        local okMoney, whyMoney = false, nil
        if CP.Qbx.addMoney then okMoney, whyMoney = CP.Qbx.addMoney(src, moneyAccount, amount, 'crimson-police-mission') end
        if not okMoney and whyMoney == 'error' then
            -- AddMoney raised: the balance may already have changed, so the row is never retried automatically
            -- (it stays paying and is listed in stuckPayments for a manual check; no society refund either).
            CP.err(TAG, 'row %d: Qbox AddMoney(%s, %d) raised for %s; the row stays paying for a manual check (transaction %s)',
                rowId, moneyAccount, amount, cid, transId)
            return 'paying'
        end
        if not okMoney then
            if withdrew then
                if refundSociety(account, amount) then
                    backToPending(rowId, 'Qbox AddMoney failed; the society withdrawal was refunded')
                    return 'pending'
                end
                CP.err(TAG, 'row %d: Qbox AddMoney failed after %s was debited %d; the row stays paying for a manual check (transaction %s)',
                    rowId, tostring(account), amount, transId)
                return 'paying'
            end
            CP.err(TAG, 'row %d: Qbox AddMoney(%s, %d) failed for %s', rowId, moneyAccount, amount, cid)
            progress.moved = false
            backToPending(rowId, 'Qbox AddMoney failed')
            return 'pending'
        end
        if moneyAccount == 'bank' and CP.Banking and CP.Banking.recordDeposit then
            CP.Banking.recordDeposit(cid, amount, message, deptLabel, charName, transId)
        end
        if withdrew and CP.Banking and CP.Banking.recordSocietyWithdraw then
            CP.Banking.recordSocietyWithdraw(account, amount, message, deptLabel, charName, transId)
        end
    end

    local status = capped and 'capped' or 'paid'
    if not setFinal(rowId, status, amount) then
        CP.err(TAG, 'row %d: %d was paid but the status could not be written; it stays paying (transaction %s)', rowId, amount, transId)
        return 'paying'
    end
    CP.log(TAG, 'row %d: %s %d to %s (%s)', rowId, status, amount, cid, transId)
    if capped then
        notify(src, 'warning', 'cash.capped', { amount = fmtMoney(amount), mission = label })
    elseif amount > 0 then
        notify(src, 'success', 'cash.paid', { amount = fmtMoney(amount), mission = label })
    end
    return status
end

function Cash.pay(rowId)
    rowId = toId(rowId)
    if not rowId then return nil end
    db()
    local row = readRow(rowId)
    if not row then return nil end
    if FINAL[row.cash_status] or row.cash_status == 'paying' then return row.cash_status end
    if row.state ~= 'completed' or CP.U.truthy(row.flagged) or CP.U.truthy(row.voided) then
        CP.log(TAG, 'row %d is not payable (state %s, flagged %s, voided %s)', rowId, tostring(row.state),
            tostring(row.flagged), tostring(row.voided))
        return nil
    end
    if inFlight[rowId] then return nil end
    inFlight[rowId] = true
    local status = withLock(row.citizenid, function() return payRow(row) end)
    inFlight[rowId] = nil
    return status
end

function Cash.payPending(src)
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return 0 end
    db()
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
    rowId = toId(rowId)
    if not rowId then return nil end
    db()
    local row = readRow(rowId)
    if not row then return nil end
    if CP.U.truthy(row.voided) then return nil end
    if CP.U.truthy(row.flagged) then
        CP.warn(TAG, 'release(%d) was called while the row is still flagged; clear the flag first', rowId)
        return nil
    end
    return Cash.pay(rowId)
end

function Cash.forfeit(rowId)
    rowId = toId(rowId)
    if not rowId then return false end
    db()
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
    return (tonumber(n) or 0) > 0
end

-- Voided rows whose dispute window closed with no open dispute: held/pending -> forfeited.
local function forfeitureJob()
    db()
    local hours = num(Config.Disputes and Config.Disputes.windowHours, 48)
    local cutoff = now() - math.floor(hours * 3600)
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs r
        SET r.cash_status = 'forfeited',
            r.breakdown = IF(r.breakdown IS NULL, NULL, JSON_SET(r.breakdown, '$.cash.status', 'forfeited'))
        WHERE r.voided = 1 AND r.cash_status IN ('held', 'pending') AND r.created_at < FROM_UNIXTIME(?)
          AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
    ]], { cutoff })
    if not ok then
        CP.err(TAG, 'forfeiture job failed: %s', tostring(n))
        return 0
    end
    n = tonumber(n) or 0
    if n > 0 then CP.log(TAG, 'forfeited the held cash of %d voided row(s)', n) end
    return n
end

-- ── board range ─────────────────────────────────────────────────────────────
local function poolFor(missionType, members)
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
            if enabled and n >= num(def.minOfficers, 1) and n <= num(def.maxOfficers, 4) then out[#out + 1] = def end
        end
    end
    return out
end

function Cash.range(missionType, members)
    if type(members) ~= 'table' then members = {} end
    local size = math.max(1, #members)
    local tier = CP.Scaling and CP.Scaling.tierFor and CP.Scaling.tierFor(size) or { cash = 1.0 }
    local mTier = num(tier and tier.cash, 1.0)
    local isBossCard = missionType == BOSS_KEY
    local modCash = 1.0
    if not isBossCard and num(Config.Events and Config.Events.modifierChance, 0) > 0 then
        modCash = math.max(1.0, num(Config.Events and Config.Events.modifierCash, 1.0))
    end
    local lo, hi
    for _, def in ipairs(poolFor(missionType, members)) do
        local B = CP.Payouts and CP.Payouts.baseFor and CP.Payouts.baseFor(def) or 0
        if not lo or B < lo then lo = B end
        if not hi or B > hi then hi = B end
    end
    if not lo then
        if isBossCard then
            lo = math.floor(num(Config.Events and Config.Events.weeklyBoss and Config.Events.weeklyBoss.payout, 0))
        else
            lo = CP.Payouts and CP.Payouts.typePayout and CP.Payouts.typePayout(missionType)
                or math.floor(num(Config.MissionTypes[missionType] and Config.MissionTypes[missionType].payout, 0))
        end
        hi = lo
    end
    return roundMoney(lo * mTier), roundMoney(hi * mTier * modCash)
end

-- ── reports ─────────────────────────────────────────────────────────────────
function Cash.stuckPayments()
    db()
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
                missionLabel = missionLabel(r, bd),
                department = r.department,
                amount = amountOf(r, bd),
                createdAt = tonumber(r.created_ts),
                transId = ('CP-%s-%s'):format(tostring(r.run_uuid), tostring(r.citizenid)),
            }
        end
    end
    return out
end

function Cash.earnedThisWeek(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    db()
    local start = CP.Schedule and CP.Schedule.weekStart and CP.Schedule.weekStart() or (now() - 7 * 86400)
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

-- ── wiring ──────────────────────────────────────────────────────────────────
local function onLoaded(src)
    local info = CP.Qbx.getInfo(src)
    local cid = info and info.citizenid
    if not cid then return end
    Wait(PENDING_DELAY_MS)
    local again = CP.Qbx.getInfo(src)
    if not again or again.citizenid ~= cid then return end
    Cash.payPending(src)
end

CreateThread(function()
    if not CP.Qbx or not CP.Qbx.onPlayerLoaded then
        CP.err(TAG, 'modules/integrations/qbx is missing: pending payments are not paid on login')
    else
        CP.Qbx.onPlayerLoaded(onLoaded)
    end
end)

CreateThread(function()
    db()
    while true do
        forfeitureJob()
        Wait(FORFEIT_EVERY_MS)
    end
end)

-- After a resource (re)start, officers who are already online never fire PlayerLoaded again: pay their
-- pending rows once, after Renewed-Banking has had time to (re)build its caches.
local function startupSweep()
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers) then return 0 end
    local n = 0
    for _, src in ipairs(CP.Qbx.getOnlinePlayers()) do
        n = n + (Cash.payPending(src) or 0)
    end
    return n
end

CreateThread(function()
    Wait(STARTUP_SWEEP_MS)
    local ok, err = pcall(startupSweep)
    if not ok then CP.err(TAG, 'pending payments sweep at start failed: %s', tostring(err)) end
end)

-- Test hooks (not part of the contract).
Cash._forfeitureJob = forfeitureJob
Cash._startupSweep = startupSweep
Cash._onLoaded = onLoaded
Cash._fmtMoney = fmtMoney
