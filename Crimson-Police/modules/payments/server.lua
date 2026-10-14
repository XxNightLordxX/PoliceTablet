-- CP.Payments (server): Admin UI → Payments: the payments ledger, totals and CSV, the payment actions (resolve, pay
-- now, retries, the money tools that ship off), department funds and the cash health lines.

CP.Payments = CP.Payments or {}
local Payments = CP.Payments
local U = CP.U
local TAG = 'payments'

local PAGE_MAX = 50
local EXPORT_MAX = 5000
local AMOUNT_ROWS_MAX = 5000      -- rows read for the owed and cut totals (the rest is summed in SQL)
local UNFUNDED_MAX = 500          -- rows one Retry unfunded may claim
local NAV_CACHE_S = 30
local STATUSES = { 'held', 'pending', 'paying', 'paid', 'capped', 'unfunded', 'forfeited' }
local STATUS_SET = {}
for _, s in ipairs(STATUSES) do STATUS_SET[s] = true end
local MANUAL_CASH = 'manual_cash'

local navCache = { at = -1, n = 0 }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return d end
    return n
end

local function Int(v, lo, hi)
    local n = math.tointeger(tonumber(v))
    if not n or (lo and n < lo) or (hi and n > hi) then return nil end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function ValidCid(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function ValidKey(v) return type(v) == 'string' and #v >= 1 and #v <= 40 and v:match('^[%w_%-]+$') ~= nil end

local function Query(sql, params)
    local ok, rows = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(rows))
        return nil
    end
    return rows or {}
end

local function Scalar(sql, params)
    local ok, v = pcall(MySQL.scalar.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(v))
        return nil
    end
    return v
end

local function Update(sql, params)
    local ok, n = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(n))
        return nil
    end
    return tonumber(n) or 0
end

local function CashCfg() return type(Config.Cash) == 'table' and Config.Cash or {} end

local function Switch(name) return CashCfg()[name] == true end

local function Money(n) return CP.Cash and CP.Cash._fmtMoney and CP.Cash._fmtMoney(n) or ('$' .. tostring(n)) end

local function Target(rowId, cid) return U.clip(('#%d %s'):format(rowId, tostring(cid)), 64) end

local function DeptOf(key)
    if CP.Cash and CP.Cash.department then return CP.Cash.department(key) end
    return CP.Access and CP.Access.department and CP.Access.department(key) or nil
end

local function DepartmentKeys()
    local out = {}
    for k in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do
        if type(k) == 'string' then out[#out + 1] = k end
    end
    table.sort(out)
    return out
end

local function SeasonId()
    if CP.Challenge and CP.Challenge.currentSeason then
        local ok, s = pcall(CP.Challenge.currentSeason)
        if ok and type(s) == 'table' and tonumber(s.id) then return math.floor(tonumber(s.id)) end
    end
    return nil
end

local function DayStart()
    if CP.Schedule and CP.Schedule.dayStart then return CP.Schedule.dayStart(Now()) end
    local t = Now()
    return t - t % 86400
end

local function WeekStart()
    if CP.Schedule and CP.Schedule.weekStart then return CP.Schedule.weekStart(Now()) end
    return Now() - 7 * 86400
end

-- ============================================================================
--                                  ROW VIEWS
-- ============================================================================

local ROW_COLS = [[r.id, r.run_uuid, r.citizenid, r.mission_id, r.mission_type, r.department, r.state, r.cash_status,
    r.cash_base, r.cash_multiplier, r.cash_paid, r.cash_reclaimed, r.flagged, r.voided, r.breakdown,
    UNIX_TIMESTAMP(r.created_at) AS created_ts]]

local function RowById(rowId)
    local id = Int(rowId, 1, 2147483647)
    if not id then return nil end
    Db()
    local rows = Query('SELECT ' .. ROW_COLS .. ' FROM cp_mission_runs r WHERE r.id = ?', { id })
    return rows and rows[1] or nil
end

local function LabelOf(row, bd)
    if row.mission_id == MANUAL_CASH then return CP.L('payments.manual_label') end
    if type(bd.missionLabel) == 'string' and bd.missionLabel ~= '' then return bd.missionLabel end
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(row.mission_id)
    if def and def.label then return def.label end
    return tostring(row.mission_id)
end

local function Owed(row) return CP.Cash and CP.Cash.amountOf and CP.Cash.amountOf(row) or 0 end

-- One ledger row (PaymentRow in web/src/types/admin_economy.ts).
local function View(r)
    local bd = U.jsonField(r.breakdown) or {}
    local c = type(bd.cash) == 'table' and bd.cash or {}
    local id = math.floor(U.num(r.id))
    local owed = Owed(r)
    local paid = math.floor(U.num(r.cash_paid))
    local status = r.cash_status
    return {
        id = id,
        runUuid = r.run_uuid,
        citizenid = r.citizenid,
        name = type(r.display_name) == 'string' and r.display_name or nil,
        missionId = r.mission_id,
        missionLabel = LabelOf(r, bd),
        missionType = r.mission_type,
        manual = r.mission_id == MANUAL_CASH,
        department = r.department,
        status = status,
        owed = owed,
        paid = paid,
        reclaimed = math.floor(U.num(r.cash_reclaimed)),
        cut = status == 'capped' and c.restPaid ~= 'paid' and math.max(0, owed - paid) or 0,
        txn = ('CP-%s-%s'):format(tostring(r.run_uuid), tostring(r.citizenid)),
        account = type(c.account) == 'string' and c.account or nil,
        source = type(c.source) == 'string' and c.source or nil,
        step = type(c.step) == 'string' and c.step or nil,
        restPaid = type(c.restPaid) == 'string' and c.restPaid or nil,
        again = type(c.again) == 'string' and c.again or nil,
        voided = U.truthy(r.voided),
        flagged = U.truthy(r.flagged),
        busy = CP.Cash and CP.Cash.rowBusy and CP.Cash.rowBusy(id, r.citizenid) or false,
        createdAt = math.floor(U.num(r.created_ts)),
    }
end

-- WHERE for the ledger filters: sql, params | nil, errKey. args: { status, department, missionType, citizenid,
-- from, to } (from and to are unix seconds; >= and < because the saves folder engine has no BETWEEN).
local function Where(args)
    args = type(args) == 'table' and args or {}
    local parts, params = { 'r.cash_status <> \'none\'' }, {}
    if args.status ~= nil and args.status ~= '' and args.status ~= 'all' then
        local st = args.status == 'stuck' and 'paying' or args.status
        if not STATUS_SET[st] then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.cash_status = ?'
        params[#params + 1] = st
    end
    if args.department ~= nil and args.department ~= '' then
        if not ValidKey(args.department) then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.department = ?'
        params[#params + 1] = args.department
    end
    if args.missionType ~= nil and args.missionType ~= '' then
        if not ValidKey(args.missionType) then return nil, 'err.invalid_filter' end
        if args.missionType == MANUAL_CASH then
            parts[#parts + 1] = 'r.mission_id = ?'
        else
            parts[#parts + 1] = 'r.mission_type = ?'
        end
        params[#params + 1] = args.missionType
    end
    if args.citizenid ~= nil and args.citizenid ~= '' then
        if not ValidCid(args.citizenid) then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.citizenid = ?'
        params[#params + 1] = args.citizenid
    end
    local from = args.from ~= nil and Int(args.from, 0) or nil
    local to = args.to ~= nil and Int(args.to, 0) or nil
    if (args.from ~= nil and not from) or (args.to ~= nil and not to) then return nil, 'err.invalid_filter' end
    if from and to and from > to then return nil, 'err.invalid_filter' end
    if from then
        parts[#parts + 1] = 'r.created_at >= FROM_UNIXTIME(?)'
        params[#params + 1] = from
    end
    if to then
        parts[#parts + 1] = 'r.created_at < FROM_UNIXTIME(?)'
        params[#params + 1] = to
    end
    return table.concat(parts, ' AND '), params
end

local function Switches()
    local c = CashCfg()
    return {
        payAgain = c.allowPayAgain == true,
        unfundedRetry = c.allowUnfundedRetry == true,
        capTopUp = c.allowCapTopUp == true,
        restoreForfeited = c.restoreForfeited == true,
        clawback = c.allowClawback == true,
        manualCash = c.allowManualCash == true,
        addFunds = c.allowAddFunds == true,
    }
end

-- ============================================================================
--                             LEDGER, TOTALS, CSV
-- ============================================================================

function Payments.list(args)
    args = type(args) == 'table' and args or {}
    local where, params = Where(args)
    if not where then return nil, params end
    local size = Int(args.size, 1, PAGE_MAX) or 25
    local page = Int(args.page, 1) or 1
    Db()
    local total = math.floor(U.num(Scalar('SELECT COUNT(*) AS n FROM cp_mission_runs r WHERE ' .. where, params)))
    local pages = math.max(1, math.ceil(total / size))
    if page > pages then page = pages end
    local q = U.copy(params)
    q[#q + 1] = size
    q[#q + 1] = (page - 1) * size
    local rows = Query(
        'SELECT '
            .. ROW_COLS
            .. [[, o.display_name FROM cp_mission_runs r
        LEFT JOIN cp_officers o ON o.citizenid = r.citizenid WHERE ]]
            .. where
            .. ' ORDER BY r.created_at DESC, r.id DESC LIMIT ? OFFSET ?',
        q
    )
    if not rows then return nil, 'err.internal' end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = View(r) end
    local nextAt = CP.Cash and CP.Cash.nextForfeitureAt and CP.Cash.nextForfeitureAt() or nil
    return {
        rows = out,
        page = page,
        pages = pages,
        total = total,
        size = size,
        switches = Switches(),
        source = CashCfg().source == 'society' and 'society' or 'server',
        maxPayout = math.floor(Num(CashCfg().maxPayout, 25000)),
        manualDailyLimit = math.floor(Num(CashCfg().manualDailyLimit, 0)),
        nextForfeitIn = nextAt and math.max(0, nextAt - os.time()) or nil,
        held = CP.Cash and CP.Cash.paymentsHeld and CP.Cash.paymentsHeld() or nil,
        serverTime = Now(),
    }
end

-- Sums in SQL (counts, paid, taken back), owed and cut amounts and every percentage in Lua.
function Payments.totals(args)
    args = type(args) == 'table' and args or {}
    local where, params = Where({ department = args.department, from = args.from, to = args.to })
    if not where then return nil, params end
    Db()
    local grouped = Query([[SELECT r.cash_status AS status, r.department AS department, COUNT(*) AS n,
        COALESCE(SUM(r.cash_paid), 0) AS paid, COALESCE(SUM(r.cash_reclaimed), 0) AS reclaimed
        FROM cp_mission_runs r WHERE ]] .. where .. ' GROUP BY r.cash_status, r.department', params)
    if not grouped then return nil, 'err.internal' end
    local byStatus, byDept = {}, {}
    for _, s in ipairs(STATUSES) do byStatus[s] = { count = 0, paid = 0, reclaimed = 0, owed = 0 } end
    local allPaid = 0
    for _, g in ipairs(grouped) do
        local st = byStatus[g.status]
        local n, paid, back = math.floor(U.num(g.n)), math.floor(U.num(g.paid)), math.floor(U.num(g.reclaimed))
        if st then
            st.count, st.paid, st.reclaimed = st.count + n, st.paid + paid, st.reclaimed + back
        end
        local d = byDept[g.department]
        if not d then
            d = { department = g.department, count = 0, paid = 0, reclaimed = 0, unfunded = 0 }
            byDept[g.department] = d
        end
        d.count, d.paid, d.reclaimed = d.count + n, d.paid + paid, d.reclaimed + back
        if g.status == 'unfunded' then d.unfunded = d.unfunded + n end
        if g.status == 'paid' or g.status == 'capped' then allPaid = allPaid + paid - back end
    end
    -- owed amounts of the rows not paid in full, and the part the cap cut
    local q = U.copy(params)
    q[#q + 1] = AMOUNT_ROWS_MAX
    local open = Query(
        'SELECT ' .. ROW_COLS .. ' FROM cp_mission_runs r WHERE ' .. where
            .. ' AND r.cash_status IN (\'held\', \'pending\', \'paying\', \'unfunded\', \'capped\', \'forfeited\') LIMIT ?',
        q
    ) or {}
    local cut, cappedToday = 0, 0
    local today = DayStart()
    for _, r in ipairs(open) do
        local v = View(r)
        local st = byStatus[v.status]
        if st then st.owed = st.owed + v.owed end
        if v.status == 'capped' then
            cut = cut + v.cut
            if v.createdAt >= today then cappedToday = cappedToday + 1 end
        end
    end
    local depts = {}
    for _, d in pairs(byDept) do
        local spent = d.paid - d.reclaimed
        d.share = allPaid > 0 and math.floor(spent * 1000 / allPaid + 0.5) / 10 or 0
        depts[#depts + 1] = d
    end
    table.sort(depts, function(a, b) return tostring(a.department) < tostring(b.department) end)
    return {
        byStatus = byStatus,
        departments = depts,
        paidTotal = allPaid,
        cut = cut,
        cappedToday = cappedToday,
        partial = #open >= AMOUNT_ROWS_MAX,
    }
end

-- A CSV cell: a leading =, +, -, @, tab or carriage return is neutralised (spreadsheet formula injection), and a
-- cell with a comma, quote or line break is quoted.
local function CsvCell(v)
    if v == nil then return '' end
    local s = tostring(v)
    if s:match('^[=+%-@\t\r]') then s = '\'' .. s end
    if s:find('[,"\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
    return s
end

function Payments.csv(rows)
    local lines = {
        'id,time,citizenid,name,department,mission,status,owed,paid,taken_back,cut,transaction,account,source',
    }
    for _, r in ipairs(rows) do
        lines[#lines + 1] = table.concat({
            CsvCell(r.id),
            CsvCell(os.date('%Y-%m-%d %H:%M:%S', r.createdAt)),
            CsvCell(r.citizenid),
            CsvCell(r.name),
            CsvCell(r.department),
            CsvCell(r.missionLabel),
            CsvCell(r.status),
            CsvCell(r.owed),
            CsvCell(r.paid),
            CsvCell(r.reclaimed),
            CsvCell(r.cut),
            CsvCell(r.txn),
            CsvCell(r.account),
            CsvCell(r.source),
        }, ',')
    end
    return table.concat(lines, '\n') .. '\n'
end

function Payments.export(args)
    local where, params = Where(args)
    if not where then return nil, params end
    Db()
    local q = U.copy(params)
    q[#q + 1] = EXPORT_MAX + 1
    local rows = Query(
        'SELECT '
            .. ROW_COLS
            .. [[, o.display_name FROM cp_mission_runs r
        LEFT JOIN cp_officers o ON o.citizenid = r.citizenid WHERE ]]
            .. where
            .. ' ORDER BY r.created_at DESC, r.id DESC LIMIT ?',
        q
    )
    if not rows then return nil, 'err.internal' end
    local list = {}
    for i = 1, math.min(#rows, EXPORT_MAX) do list[i] = View(rows[i]) end
    return { csv = Payments.csv(list), rows = #list, truncated = #rows > EXPORT_MAX }
end

-- Stuck payments ('paying') for the sidebar badge, read at most every 30 s.
function Payments.stuckCount()
    local now = os.time()
    if navCache.at >= 0 and now - navCache.at < NAV_CACHE_S then return navCache.n end
    Db()
    local n = Scalar('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE cash_status = \'paying\'', {})
    navCache = { at = now, n = math.floor(U.num(n)) }
    return navCache.n
end

-- ============================================================================
--                               DEPARTMENT FUNDS
-- ============================================================================

function Payments.departmentFunds(key)
    if not ValidKey(key) then return nil, 'err.unknown_department' end
    local dept = DeptOf(key)
    if not dept then return nil, 'err.unknown_department' end
    Db()
    local account = dept.societyAccount
    local balance = nil
    if CP.Banking and CP.Banking.societyBalance then
        local ok, b = pcall(CP.Banking.societyBalance, account)
        balance = ok and type(b) == 'number' and math.floor(b) or nil
    end
    local function spentSince(extra, p)
        local params = { key }
        for _, v in ipairs(p) do params[#params + 1] = v end
        return math.floor(U.num(Scalar([[SELECT COALESCE(SUM(cash_paid - cash_reclaimed), 0) AS n FROM cp_mission_runs
            WHERE department = ? AND cash_status IN ('paid', 'capped')
              AND JSON_VALUE(breakdown, '$.cash.source') = 'society']] .. extra, params)))
    end
    local season = SeasonId()
    local spent = {
        today = spentSince(' AND created_at >= FROM_UNIXTIME(?)', { DayStart() }),
        week = spentSince(' AND created_at >= FROM_UNIXTIME(?)', { WeekStart() }),
        season = season and spentSince(' AND season_id = ?', { season }) or nil,
    }
    local unfunded = math.floor(U.num(Scalar([[SELECT COUNT(*) AS n FROM cp_mission_runs
        WHERE department = ? AND cash_status = 'unfunded']], { key })))
    local funded = math.floor(U.num(Scalar([[SELECT COALESCE(SUM(amount), 0) AS n FROM cp_dept_funding
        WHERE department = ? AND state = 'done']], { key })))
    local recent = {}
    for _, r in
        ipairs(Query(
            [[SELECT id, amount, txn, state, by_actor, reason, UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_dept_funding WHERE department = ? ORDER BY id DESC LIMIT 5]],
            { key }
        ) or {})
    do
        recent[#recent + 1] = {
            id = math.floor(U.num(r.id)),
            amount = math.floor(U.num(r.amount)),
            txn = r.txn,
            state = r.state,
            by = r.by_actor,
            reason = r.reason,
            at = math.floor(U.num(r.created_ts)),
        }
    end
    local cfg = type(Config.Departments) == 'table' and Config.Departments[key] or nil
    return {
        department = key,
        label = dept.label or key,
        account = account,
        enabled = not (type(cfg) == 'table' and cfg.enabled == false),
        source = CashCfg().source == 'society' and 'society' or 'server',
        balance = balance,
        lowBalanceWarn = math.floor(Num(CashCfg().lowBalanceWarn, 0)),
        spent = spent,
        unfunded = unfunded,
        funded = funded,
        recent = recent,
        allowAddFunds = Switch('allowAddFunds'),
        addFundsMax = math.floor(Num(CashCfg().addFundsMax, 0)),
    }
end

-- Before Cash.source changes: each department's balance and what it would then pay (held and pending rows).
function Payments.sourcePreview()
    Db()
    local out = {}
    for _, key in ipairs(DepartmentKeys()) do
        local dept = DeptOf(key)
        if dept then
            local rows = Query(
                [[SELECT ]]
                    .. ROW_COLS
                    .. [[ FROM cp_mission_runs r
                WHERE r.department = ? AND r.cash_status IN ('held', 'pending') LIMIT ?]],
                { key, AMOUNT_ROWS_MAX }
            ) or {}
            local owed = 0
            for _, r in ipairs(rows) do owed = owed + Owed(r) end
            local balance = CP.Banking and CP.Banking.societyBalance and CP.Banking.societyBalance(dept.societyAccount)
            out[#out + 1] = {
                department = key,
                label = dept.label or key,
                account = dept.societyAccount,
                balance = type(balance) == 'number' and math.floor(balance) or nil,
                rows = #rows,
                owed = owed,
                short = type(balance) == 'number' and owed > balance or nil,
            }
        end
    end
    return { departments = out, source = CashCfg().source == 'society' and 'society' or 'server' }
end

-- Config health (CP.ConfigHealth 'cash'): the money account, missing society accounts, low balances.
function Payments.health()
    local c, out = CashCfg(), {}
    if c.account ~= nil and c.account ~= 'bank' and c.account ~= 'cash' then
        out[#out + 1] = { level = 'error', text = CP.L('payments.health.account', { account = tostring(c.account) }) }
    end
    if c.source ~= 'society' then return out end
    local warn = math.floor(Num(c.lowBalanceWarn, 0))
    for _, key in ipairs(DepartmentKeys()) do
        local dept = DeptOf(key)
        if dept and CP.Banking and CP.Banking.societyBalance then
            local ok, b = pcall(CP.Banking.societyBalance, dept.societyAccount)
            if not ok or type(b) ~= 'number' then
                out[#out + 1] = {
                    level = 'error',
                    text = CP.L('payments.health.no_account',
                        { department = dept.label or key, account = tostring(dept.societyAccount) }),
                }
            elseif warn > 0 and b < warn then
                out[#out + 1] = {
                    level = 'warn',
                    text = CP.L('payments.health.low',
                        { department = dept.label or key, balance = Money(b), limit = Money(warn) }),
                }
            end
        end
    end
    return out
end

-- Once a day: a toast to each department's online supervisors when its account is below Cash.lowBalanceWarn.
function Payments.lowBalanceToasts()
    local c = CashCfg()
    local warn = math.floor(Num(c.lowBalanceWarn, 0))
    if c.source ~= 'society' or warn <= 0 then return 0 end
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Access and CP.Access.getOfficer) then return 0 end
    local n = 0
    for _, key in ipairs(DepartmentKeys()) do
        local dept = DeptOf(key)
        local b = dept and CP.Banking and CP.Banking.societyBalance and CP.Banking.societyBalance(dept.societyAccount)
        if type(b) == 'number' and b < warn then
            local sups = {}
            for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
                local o = CP.Access.getOfficer(s)
                if o and o.department == key and o.isSupervisor then sups[#sups + 1] = s end
            end
            if #sups > 0 and CP.Tablet and CP.Tablet.notifyMany then
                CP.Tablet.notifyMany(sups, 'warning', 'payments.low_balance_toast',
                    { department = dept.label or key, balance = Money(b) })
                n = n + 1
            end
        end
    end
    return n
end

-- ============================================================================
--                           RETRY UNFUNDED (PREVIEW)
-- ============================================================================

-- true when a row belongs to src (any character of their license, or a run they took part in) or the license is
-- unknown: the S guard for a whole department, where the row-level guard of the action never sees each row.
local function OwnRow(src, r, seen)
    local Kit = CP.AdminKit
    if (tonumber(src) or 0) == 0 or not Kit then return false end
    local cid, run = tostring(r.citizenid), tostring(r.run_uuid)
    if seen.cid[cid] == nil then seen.cid[cid] = Kit.isSelf(src, cid, true) ~= false end
    if seen.run[run] == nil then seen.run[run] = Kit.selfRun(src, run) == true end
    return seen.cid[cid] or seen.run[run]
end

-- The unfunded rows of one row id, or of a department since a time: ids, total, per-department totals. Never the
-- acting admin's own rows (src); excluded counts them.
local function UnfundedSet(args, src)
    args = type(args) == 'table' and args or {}
    local sql = 'SELECT '
        .. ROW_COLS
        .. [[ FROM cp_mission_runs r WHERE r.cash_status = 'unfunded' AND r.voided = 0
        AND r.flagged = 0 AND r.state = 'completed']]
    local params = {}
    if args.rowId ~= nil then
        local id = Int(args.rowId, 1, 2147483647)
        if not id then return nil, 'err.invalid_row' end
        sql = sql .. ' AND r.id = ?'
        params[#params + 1] = id
    else
        if not ValidKey(args.department) or not DeptOf(args.department) then return nil, 'err.unknown_department' end
        sql = sql .. ' AND r.department = ?'
        params[#params + 1] = args.department
        if args.since ~= nil then
            local since = Int(args.since, 0)
            if not since then return nil, 'err.invalid_filter' end
            sql = sql .. ' AND r.created_at >= FROM_UNIXTIME(?)'
            params[#params + 1] = since
        end
    end
    params[#params + 1] = UNFUNDED_MAX
    Db()
    local rows = Query(sql .. ' ORDER BY r.id LIMIT ?', params)
    if not rows then return nil, 'err.internal' end
    local ids, total, byDept, list, excluded = {}, 0, {}, {}, 0
    local seen = { cid = {}, run = {} }
    for _, r in ipairs(rows) do
        if OwnRow(src, r, seen) then
            excluded = excluded + 1
        else
            local v = View(r)
            ids[#ids + 1] = v.id
            total = total + v.owed
            byDept[v.department] = (byDept[v.department] or 0) + v.owed
            list[#list + 1] = v
        end
    end
    return { ids = ids, total = total, byDept = byDept, rows = list, excluded = excluded }
end

-- ============================================================================
--                                  NET: READS
-- ============================================================================

local Kit = CP.AdminKit

Kit.callback('admin:getPayments', 'payments', function(ctx) return Payments.list(ctx.args) end, { rate = 3 })

Kit.callback('admin:getPaymentTotals', 'payments', function(ctx) return Payments.totals(ctx.args) end, { rate = 2 })

Kit.callback('admin:exportPayments', 'payments', function(ctx)
    if not CP.Net.rateOk(ctx.src, 'admin:exportPayments', 1, 3000) then return nil, 'err.rate_limited' end
    local data, err = Payments.export(ctx.args)
    if not data then return nil, err end
    if CP.Admin and CP.Admin.audit then
        pcall(CP.Admin.audit, ctx.src, ctx.src == 0 and 'console' or 'admin', 'audit', 'paymentsExport', nil, nil,
            tostring(data.rows), nil)
    end
    return data
end, { rate = 2 })

-- What Renewed-Banking's history says about a stuck payment: only the entries with its transaction id.
Kit.callback('admin:checkBankingTxn', 'payments', function(ctx)
    local row = RowById(ctx.args.rowId)
    if not row then return nil, 'err.row_not_found' end
    local v = View(row)
    local bd = U.jsonField(row.breakdown) or {}
    local c = type(bd.cash) == 'table' and bd.cash or {}
    local dept = DeptOf(row.department)
    local account = c.societyAccount or (v.source == 'society' and dept and dept.societyAccount) or nil
    local found = nil
    if CP.Banking and CP.Banking.findTxn then
        found = CP.Banking.findTxn(v.txn, { citizenid = row.citizenid, account = account })
    end
    return {
        id = v.id,
        status = v.status,
        txn = v.txn,
        amount = c.payAmount and math.floor(Num(c.payAmount, 0)) or v.owed,
        step = v.step,
        source = v.source,
        account = v.account,
        societyAccount = account,
        personal = found and found.personal or nil,
        society = found and found.society or nil,
        busy = v.busy,
        online = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(row.citizenid) ~= nil or false,
        payAgain = Switch('allowPayAgain'),
    }
end, { rate = 2 })

Kit.callback('admin:previewRetryUnfunded', 'payments', function(ctx)
    local set, err = UnfundedSet(ctx.args, ctx.src)
    if not set then return nil, err end
    local balances = {}
    for key, owed in pairs(set.byDept) do
        local dept = DeptOf(key)
        local b = dept and CP.Banking and CP.Banking.societyBalance and CP.Banking.societyBalance(dept.societyAccount)
        balances[#balances + 1] = {
            department = key,
            label = dept and dept.label or key,
            owed = owed,
            balance = type(b) == 'number' and math.floor(b) or nil,
        }
    end
    table.sort(balances, function(a, b) return a.department < b.department end)
    local effect = {
        count = #set.ids,
        total = set.total,
        departments = balances,
        rows = set.rows,
        excluded = set.excluded,
    }
    local token, expiresAt = ctx.preview('retryUnfunded', set.ids, effect)
    return { previewToken = token, expiresAt = expiresAt, effect = effect }
end, { rate = 2 })

Kit.callback('admin:getDepartmentFunds', 'deptFunds', function(ctx)
    return Payments.departmentFunds(ctx.args.department)
end, { rate = 4 })

Kit.callback('admin:previewCashSource', 'payments', function() return Payments.sourcePreview() end, { rate = 1 })

-- ============================================================================
--                                 NET: ACTIONS
-- ============================================================================
-- Every money tool: request id (I), reason (R), the typed amount (T), never the admin's own characters or runs (S,
-- strict: refused when a licence is unknown), claim → synchronous audit row → money → final state (in CP.Cash).

local function SelfOfRow(p)
    local row = RowById(p.rowId)
    if not row then return nil end
    return { citizenid = row.citizenid, runUuid = row.run_uuid, strict = true }
end

local function OwedWord(p)
    local row = RowById(p.rowId)
    if not row then return nil end
    return tostring(Owed(row))
end

-- The audit callback CP.Cash calls after its claim: the row id of the synchronous audit row, or false.
local function AuditFn(ctx, action, rowId, cid, oldFn, newFn)
    return function(info)
        info = info or {}
        local old = oldFn and oldFn(info) or nil
        local new = newFn and newFn(info) or nil
        return ctx.audit(action, Target(rowId, cid), old, new)
    end
end

-- A payment changed: the caches that hold it, the sidebar count and every admin's open Payments screen.
local function Touched(ctx, cid)
    ctx.changed('payments', cid)
    navCache.at = -1
    if CP.Tablet and CP.Tablet.pushAdmins then pcall(CP.Tablet.pushAdmins, 'payments', { changed = true }) end
end

local function OffSwitch(name) if not Switch(name) then return 'err.money_tool_off' end end

-- ============================================================================
--                      RESOLVE A PAYMENT LEFT IN 'PAYING'
-- ============================================================================

Kit.action('server:admin:resolvePayment', 'payments', function(ctx)
    local p = ctx.payload
    local row = RowById(p.rowId)
    if not row then return false, 'err.row_not_found' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    if p.outcome == 'paid' then
        local ok, data = CP.Cash.markPaid(id,
            AuditFn(ctx, 'paymentResolve', id, cid, function() return 'paying' end, function(i)
                return ('%s:%d'):format(i.status or 'paid', i.amount or 0)
            end))
        if not ok then return false, data end
        Touched(ctx, cid)
        return true, data
    elseif p.outcome == 'payAgain' then
        local off = OffSwitch('allowPayAgain')
        if off then return false, off end
        if p.checked ~= true then return false, 'err.check_first' end
        local ok, data = CP.Cash.payAgain(id, AuditFn(ctx, 'paymentPayAgain', id, cid, function(i)
            return ('paying:%s'):format(i.step or 'unknown')
        end, function(i) return ('%d%s'):format(i.amount or 0, i.withdraw and ':withdraw' or '') end))
        if not ok then return false, data end
        Touched(ctx, cid)
        return true, data
    end
    return false, 'err.invalid_payload'
end, {
    requestId = true,
    reason = true,
    confirm = function(p)
        if p.outcome ~= 'payAgain' then return nil end
        local row = RowById(p.rowId)
        if not row then return nil end
        local bd = U.jsonField(row.breakdown) or {}
        local c = type(bd.cash) == 'table' and bd.cash or {}
        return tostring(c.payAmount and math.floor(Num(c.payAmount, 0)) or Owed(row))
    end,
    self = SelfOfRow,
})

-- ============================================================================
--                            PAY NOW, RETRY PENDING
-- ============================================================================

Kit.action('server:admin:payNow', 'payments', function(ctx)
    local row = RowById(ctx.payload.rowId)
    if not row then return false, 'err.row_not_found' end
    local st = row.cash_status
    -- a manual_award row still 'none' is a manual cash payment whose audit row was never written: never paid
    local unpaid = st == 'none' and row.state == 'completed' and math.floor(U.num(row.cash_base)) > 0
        and row.mission_type ~= 'manual_award'
    if st ~= 'pending' and not unpaid then return false, 'err.state_changed' end
    local id = math.floor(U.num(row.id))
    local status = CP.Cash.pay(id)
    ctx.audit('paymentRetry', Target(id, row.citizenid), st, tostring(status or st))
    local online = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(row.citizenid) ~= nil
    Touched(ctx, row.citizenid)
    return true, { id = id, status = status or st, online = online == true }
end, { requestId = true, rate = 2 })

Kit.action('server:admin:retryPending', 'payments', function(ctx)
    local paid, officers = 0, 0
    if CP.Qbx and CP.Qbx.getOnlinePlayers then
        for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
            officers = officers + 1
            paid = paid + (CP.Cash.payPending(s) or 0)
        end
    end
    ctx.audit('paymentRetry', 'online', nil, ('%d paid'):format(paid))
    Touched(ctx, nil)
    return true, { paid = paid, officers = officers }
end, { requestId = true, rate = 2 })

-- ============================================================================
--                      RETRY UNFUNDED (SWITCH, SHIPS OFF)
-- ============================================================================

Kit.action('server:admin:retryUnfunded', 'payments', function(ctx)
    local off = OffSwitch('allowUnfundedRetry')
    if off then return false, off end
    local p = ctx.payload
    local set, err = UnfundedSet(p, ctx.src)
    if not set then return false, err end
    if #set.ids == 0 then return false, 'err.nothing_to_pay' end
    local okT, errT = ctx.consume(p.previewToken, 'retryUnfunded', set.ids)
    if not okT then return false, errT end
    -- the balance, read just before: every department must cover its whole part
    if CashCfg().source == 'society' then
        for key, owed in pairs(set.byDept) do
            local dept = DeptOf(key)
            local b = dept and CP.Banking and CP.Banking.societyBalance
                and CP.Banking.societyBalance(dept.societyAccount)
            if type(b) ~= 'number' or b < owed then return false, 'err.balance_low' end
        end
    end
    local claimed = {}
    for _, id in ipairs(set.ids) do
        if CP.Cash.toPending(id, 'unfunded') then claimed[#claimed + 1] = id end
    end
    if #claimed == 0 then return false, 'err.state_changed' end
    local target = p.rowId ~= nil and ('#%s'):format(tostring(p.rowId)) or tostring(p.department)
    if not ctx.audit('paymentUnfundedRetry', target, ('%d unfunded'):format(#claimed), tostring(set.total)) then
        for _, id in ipairs(claimed) do CP.Cash.backFromPending(id, 'unfunded') end
        return false, 'err.audit_failed'
    end
    local paid, pending = 0, 0
    for _, id in ipairs(claimed) do
        local st = CP.Cash.pay(id)
        if st == 'paid' or st == 'capped' then paid = paid + 1 else pending = pending + 1 end
    end
    Touched(ctx, nil)
    return true, { claimed = #claimed, paid = paid, pending = pending }
end, {
    requestId = true,
    reason = true,
    confirm = function(p, ctx)
        local set = UnfundedSet(p, ctx and ctx.src)
        return set and tostring(set.total) or nil
    end,
    self = function(p)
        if p.rowId == nil then return nil end
        return SelfOfRow(p)
    end,
})

-- ============================================================================
--              PAY THE REST THE DAILY CAP CUT (SWITCH, SHIPS OFF)
-- ============================================================================

Kit.action('server:admin:payCapRest', 'payments', function(ctx)
    local off = OffSwitch('allowCapTopUp')
    if off then return false, off end
    local row = RowById(ctx.payload.rowId)
    if not row then return false, 'err.row_not_found' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    local ok, data = CP.Cash.payCapRest(id, AuditFn(ctx, 'paymentCapRest', id, cid, function()
        return ('capped:%d'):format(math.floor(U.num(row.cash_paid)))
    end, function(i) return tostring(i.amount or 0) end))
    if not ok then return false, data end
    Touched(ctx, cid)
    return true, data
end, {
    requestId = true,
    reason = true,
    confirm = function(p)
        local row = RowById(p.rowId)
        if not row then return nil end
        return tostring(math.max(0, Owed(row) - math.floor(U.num(row.cash_paid))))
    end,
    self = SelfOfRow,
})

-- ============================================================================
--               PAY FORFEITED CASH AFTER ALL (SWITCH, SHIPS OFF)
-- ============================================================================

Kit.action('server:admin:repayForfeited', 'payments', function(ctx)
    local off = OffSwitch('restoreForfeited')
    if off then return false, off end
    local row = RowById(ctx.payload.rowId)
    if not row then return false, 'err.row_not_found' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    if U.truthy(row.voided) then return false, 'err.restore_first' end
    local ok, err = CP.Cash.toPending(id, 'forfeited')
    if not ok then return false, err end
    if not ctx.audit('paymentForfeitRepay', Target(id, cid), 'forfeited', tostring(Owed(row))) then
        CP.Cash.backFromPending(id, 'forfeited')
        return false, 'err.audit_failed'
    end
    -- the item rewards forfeited with the row come back with it
    if CP.Rewards and CP.Rewards.undoForfeit then pcall(CP.Rewards.undoForfeit, id) end
    local status = CP.Cash.pay(id) or 'pending'
    Touched(ctx, cid)
    return true, { id = id, status = status }
end, { requestId = true, reason = true, confirm = OwedWord, self = SelfOfRow })

-- ============================================================================
--                         FORFEIT NOW, CANCEL PAYMENT
-- ============================================================================

Kit.action('server:admin:forfeitNow', 'payments', function(ctx)
    local row = RowById(ctx.payload.rowId)
    if not row then return false, 'err.row_not_found' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    local ok, err = CP.Cash.adminForfeit(id, 'voided')
    if not ok then return false, err end
    ctx.audit('paymentForfeit', Target(id, cid), row.cash_status, 'forfeited')
    ctx.notify(cid, 'warning', 'payments.toast.forfeited', { amount = Money(Owed(row)) })
    Touched(ctx, cid)
    return true, { id = id, status = 'forfeited' }
end, { reason = true, self = SelfOfRow })

Kit.action('server:admin:cancelPayment', 'payments', function(ctx)
    local row = RowById(ctx.payload.rowId)
    if not row then return false, 'err.row_not_found' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    local ok, err = CP.Cash.adminForfeit(id, 'cancel')
    if not ok then return false, err end
    ctx.audit('paymentCancel', Target(id, cid), row.cash_status, 'forfeited')
    ctx.notify(cid, 'warning', 'payments.toast.cancelled', { amount = Money(Owed(row)) })
    Touched(ctx, cid)
    return true, { id = id, status = 'forfeited' }
end, { reason = true, confirm = OwedWord, self = SelfOfRow })

-- ============================================================================
--                   TAKE PAID CASH BACK (SWITCH, SHIPS OFF)
-- ============================================================================

Kit.action('server:admin:clawback', 'payments', function(ctx)
    local off = OffSwitch('allowClawback')
    if off then return false, off end
    local p = ctx.payload
    local row = RowById(p.rowId)
    if not row then return false, 'err.row_not_found' end
    local amount = Int(p.amount, 1, 10000000)
    if not amount then return false, 'err.invalid_amount' end
    local id, cid = math.floor(U.num(row.id)), row.citizenid
    local ok, data = CP.Cash.clawback(id, amount, AuditFn(ctx, 'cashClawback', id, cid, function()
        return ('paid:%d'):format(math.floor(U.num(row.cash_paid)))
    end, function(i) return ('-%d'):format(i.amount or 0) end))
    if not ok then return false, data end
    Touched(ctx, cid)
    return true, data
end, {
    requestId = true,
    reason = true,
    confirm = function(p)
        local n = Int(p.amount, 1)
        return n and tostring(n) or '-'
    end,
    self = SelfOfRow,
})

-- ============================================================================
--                   MANUAL CASH PAYMENT (SWITCH, SHIPS OFF)
-- ============================================================================
-- A manual_cash row (mission_type manual_award: out of run counts, goals, streaks and the draw by the existing
-- filters), paid through the normal flow (source, account, pending until login) but outside the daily cap: it has
-- its own per-admin daily limit, counted from today's rows (every character of the admin's license). The row is
-- written as 'none', which no login payment and no Pay now picks up, and is paid only after its audit row exists.

local function InsertManualRow(cid, dept, amount, actor, reason, runUuid)
    local bd = {
        runId = runUuid,
        missionLabel = CP.L('payments.manual_label'),
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
        cash = { B = amount, mTier = 1.0, mMod = 1.0, amount = amount, status = 'none' },
        kind = MANUAL_CASH,
        by = actor,
        reason = reason,
    }
    local okJ, js = pcall(json.encode, U.serialize(bd))
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
        VALUES (?, 'manual_award', 'manual_cash', ?, ?, ?, 1, 1, 'standard', 'completed', 'completed', 0, 0, 0, 0, ?,
            1.00, 0, 'none', 0, ?, 0, 0, FROM_UNIXTIME(?))
    ]], { runUuid, cid, U.clip(dept, 32), SeasonId(), amount, okJ and js or '{}', Now() })
    if not ok or not tonumber(id) then
        CP.err(TAG, 'inserting the manual cash row for %s failed: %s', cid, tostring(id))
        return nil
    end
    return math.floor(tonumber(id))
end

local function ManualUsed(ctx)
    return Kit.dailySum({ missionIds = { MANUAL_CASH }, actor = ctx.actor, src = ctx.src, column = 'cash_base' })
end

Kit.action('server:admin:manualCash', 'payments', function(ctx)
    local off = OffSwitch('allowManualCash')
    if off then return false, off end
    if CP.Cash.paymentsHeld and CP.Cash.paymentsHeld() then return false, 'err.maintenance' end
    local p = ctx.payload
    if not ValidCid(p.citizenid) then return false, 'err.invalid_citizenid' end
    local maxPayout = math.floor(Num(CashCfg().maxPayout, 25000))
    local amount = Int(p.amount, 1, maxPayout)
    if not amount then return false, 'err.invalid_amount' end
    Db()
    local officer = Query('SELECT citizenid, department FROM cp_officers WHERE citizenid = ?', { p.citizenid })
    if not officer then return false, 'err.internal' end
    if not officer[1] then return false, 'err.unknown_officer' end
    local limit = math.floor(Num(CashCfg().manualDailyLimit, 0))
    local used = ManualUsed(ctx)
    if used == nil then return false, 'err.internal' end
    if limit > 0 and used + amount > limit then return false, 'err.manual_limit' end
    local runUuid = ctx.requestId or Kit.uuid()
    local id = InsertManualRow(p.citizenid, officer[1].department or 'unknown', amount, ctx.actor, ctx.reason, runUuid)
    if not id then return false, 'err.internal' end
    -- the limit again, now that the row is counted: two payments at the same moment never pass it together
    local after = ManualUsed(ctx)
    if after == nil or (limit > 0 and after > limit) then
        Update('DELETE FROM cp_mission_runs WHERE id = ? AND cash_status = \'none\'', { id })
        return false, 'err.manual_limit'
    end
    if not ctx.audit('manualCash', Target(id, p.citizenid), nil, tostring(amount)) then
        Update('DELETE FROM cp_mission_runs WHERE id = ? AND cash_status = \'none\'', { id })
        return false, 'err.audit_failed'
    end
    local status = CP.Cash.pay(id) or 'pending'
    Touched(ctx, p.citizenid)
    return true, { id = id, status = status, amount = amount }
end, {
    requestId = true,
    reason = true,
    rate = 1,
    confirm = function(p)
        local n = Int(p.amount, 1)
        local half = math.floor(Num(CashCfg().maxPayout, 25000) / 2)
        if n and n > half then return tostring(n) end
        return nil
    end,
    self = function(p)
        if not ValidCid(p.citizenid) then return nil end
        return { citizenid = p.citizenid, strict = true }
    end,
})

-- ============================================================================
--            ADD FUNDS TO A DEPARTMENT ACCOUNT (SWITCH, SHIPS OFF)
-- ============================================================================
-- The funding row (pending) is written first and gives the transaction id CP-FUND-<id>; the deposit follows; the
-- row ends done or failed. A repeated request is answered by the I guard and never deposits twice. Never a withdrawal.

Kit.action('server:admin:addDepartmentFunds', 'deptFunds', function(ctx)
    local off = OffSwitch('allowAddFunds')
    if off then return false, off end
    local p = ctx.payload
    if not ValidKey(p.department) then return false, 'err.unknown_department' end
    local dept = DeptOf(p.department)
    if not dept then return false, 'err.unknown_department' end
    local max = math.floor(Num(CashCfg().addFundsMax, 0))
    local amount = Int(p.amount, 1, max)
    if not amount then return false, 'err.invalid_amount' end
    Db()
    local okI, fundId = pcall(MySQL.insert.await,
        [[INSERT INTO cp_dept_funding (department, amount, txn, state, by_actor,
        reason, created_at) VALUES (?, ?, NULL, 'pending', ?, ?, FROM_UNIXTIME(?))]],
        { p.department, amount, U.clip(ctx.actor, 50), ctx.reason, Now() })
    if not okI or not tonumber(fundId) then
        CP.err(TAG, 'the funding row for %s could not be written: %s', p.department, tostring(fundId))
        return false, 'err.internal'
    end
    fundId = math.floor(tonumber(fundId))
    local txn = ('CP-FUND-%d'):format(fundId)
    Update('UPDATE cp_dept_funding SET txn = ? WHERE id = ? AND state = \'pending\'', { txn, fundId })
    if not ctx.audit('deptFund', p.department, nil, tostring(amount)) then
        Update('UPDATE cp_dept_funding SET state = \'failed\' WHERE id = ? AND state = \'pending\'', { fundId })
        return false, 'err.audit_failed'
    end
    local ok = CP.Banking and CP.Banking.depositSociety and CP.Banking.depositSociety(dept.societyAccount, amount)
    if ok ~= true then
        Update('UPDATE cp_dept_funding SET state = \'failed\' WHERE id = ? AND state = \'pending\'', { fundId })
        return false, 'err.fund_failed'
    end
    if CP.Banking.recordSocietyDeposit then
        CP.Banking.recordSocietyDeposit(dept.societyAccount, amount, CP.L('payments.fund_message'),
            CP.L('payments.fund_issuer'), dept.label or p.department, txn)
    end
    Update('UPDATE cp_dept_funding SET state = \'done\' WHERE id = ? AND state = \'pending\'', { fundId })
    return true, { id = fundId, txn = txn, amount = amount }
end, {
    requestId = true,
    reason = true,
    targetRate = { 1, 10000, field = 'department' },
    confirm = function(p)
        local n = Int(p.amount, 1)
        return n and tostring(n) or '-'
    end,
})

-- ============================================================================
--                                    START
-- ============================================================================

CreateThread(function()
    if CP.Tablet and CP.Tablet.registerNavCount then
        CP.Tablet.registerNavCount('adminPayments', function() return Payments.stuckCount() end, { adminOnly = true })
    end
    if CP.ConfigHealth and CP.ConfigHealth.register then CP.ConfigHealth.register('cash', Payments.health) end
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function() CreateThread(function() Payments.lowBalanceToasts() end) end)
    end
end)

-- Test hooks (not part of the contract).
Payments._where = Where
Payments._unfundedSet = UnfundedSet
Payments._resetNav = function() navCache = { at = -1, n = 0 } end
