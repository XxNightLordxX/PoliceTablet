-- Full admin control, economy: the payments ledger, resolving stuck payments, pay now and retries, the money
-- tools that ship off, payout unlock and Adjust all, the archive and forfeiture jobs under the busy lock,
-- maintenance, the clean-up job (System -> Jobs) and the cash health lines.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/access/permissions, access, admin, adminkit, confighealth, settings, tablet, cash, payouts,
-- payments, schedule and the Renewed-Banking history lookup. Stand-ins: CP.Qbx (the players below, their money)
-- and CP.Banking's money calls (the society accounts below).

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if not line:find('crimson%-police') then realPrint(line) end
end

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local LIC1 = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1'
local people = {
    [1] = { cid = 'ADM00001', license = LIC1, job = 'sast', grade = 4, ace = true },
    [2] = { cid = 'SUP00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [3] = {
        cid = 'ADM00003',
        license = 'license:cccccccccccccccccccccccccccccccccccccc3',
        job = 'fib',
        grade = 1,
        ace = true,
    },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
    [8] = { cid = 'OFF00008', license = 'license:8888888888888888888888888888888888888888', job = 'fib', grade = 0 },
}
local qboxLicense = { ALT00001 = LIC1, NOBODY99 = 'license:9999999999999999999999999999999999999999' }
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
    p.money = { bank = 1000, cash = 0 }
end

-- money calls (Qbox) and what they did
local calls = { add = {}, remove = {} }
local addResult, addWhy, addYield = true, nil, false
local removeResult, removeWhy = true, nil

local function Online(cid)
    for src, p in pairs(people) do
        if p.cid == cid and not p.offline then return src end
    end
    return nil
end

CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p or p.offline then return nil end
        return {
            src = src,
            citizenid = p.cid,
            license = p.license,
            name = 'Player ' .. src,
            job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
        }
    end,
    getByCitizenId = Online,
    getOnlinePlayers = function()
        local out = {}
        for src, p in pairs(people) do if not p.offline then out[#out + 1] = src end end
        table.sort(out)
        return out
    end,
    licenseOf = function(cid)
        for _, p in pairs(people) do if p.cid == cid then return p.license end end
        return qboxLicense[cid]
    end,
    citizenidsOfLicense = function(lic)
        local out = {}
        for cid, l in pairs(qboxLicense) do if l == lic then out[#out + 1] = cid end end
        return out
    end,
    characterExists = function(cid) return qboxLicense[cid] ~= nil end,
    addMoney = function(src, account, amount)
        calls.add[#calls.add + 1] = { src = src, account = account, amount = amount }
        if addYield then Wait(500) end
        if addResult and people[src] then people[src].money[account] = (people[src].money[account] or 0) + amount end
        return addResult, addWhy
    end,
    getMoney = function(src, account) return people[src] and people[src].money[account] or nil end,
    removeMoney = function(src, account, amount)
        calls.remove[#calls.remove + 1] = { src = src, account = account, amount = amount }
        if removeResult and people[src] then people[src].money[account] = people[src].money[account] - amount end
        return removeResult, removeWhy
    end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
CP.Missions = {
    reload = function() end,
    get = function(id)
        if id == 'beat_patrol' then return { id = id, label = 'Beat Patrol', type = 'patrol', difficulty = 1 } end
        if id == 'bank_job' then return { id = id, label = 'Bank Job', type = 'tactical', difficulty = 2 } end
        return nil
    end,
    list = function()
        return {
            { id = 'beat_patrol', label = 'Beat Patrol', type = 'patrol', difficulty = 1 },
            { id = 'bank_job', label = 'Bank Job', type = 'tactical', difficulty = 2 },
        }
    end,
}

-- the real Renewed-Banking history lookup, read before the money calls are replaced by stand-ins
H.load('modules/system/integrations/renewed_banking.lua')
local realFindTxn = CP.Banking.findTxn
local setHistoryDb = CP.Banking._setHistoryDb

local bank = { balance = { sast = 5000, fib = 5000 }, log = {} }
local depositHook = nil
CP.Banking = {
    findTxn = realFindTxn,
    societyBalance = function(account) return bank.balance[account] end,
    withdrawSociety = function(account, amount)
        bank.log[#bank.log + 1] = { kind = 'withdraw', account = account, amount = amount }
        if not bank.balance[account] or bank.balance[account] < amount then return false end
        bank.balance[account] = bank.balance[account] - amount
        return true
    end,
    depositSociety = function(account, amount)
        if depositHook then depositHook(account, amount) end
        bank.log[#bank.log + 1] = { kind = 'deposit', account = account, amount = amount }
        if not bank.balance[account] then return false end
        bank.balance[account] = bank.balance[account] + amount
        return true
    end,
    recordDeposit = function(cid, amount, _, _, _, txn)
        bank.log[#bank.log + 1] = {
            kind = 'entry',
            side = 'personal',
            type = 'deposit',
            id = cid,
            amount = amount,
            txn = txn,
        }
        return true
    end,
    recordWithdraw = function(cid, amount, _, _, _, txn)
        bank.log[#bank.log + 1] = {
            kind = 'entry',
            side = 'personal',
            type = 'withdraw',
            id = cid,
            amount = amount,
            txn = txn,
        }
        return true
    end,
    recordSocietyWithdraw = function(account, amount, _, _, _, txn)
        bank.log[#bank.log + 1] = {
            kind = 'entry',
            side = 'society',
            type = 'withdraw',
            id = account,
            amount = amount,
            txn = txn,
        }
        return true
    end,
    recordSocietyDeposit = function(account, amount, _, _, _, txn)
        bank.log[#bank.log + 1] = {
            kind = 'entry',
            side = 'society',
            type = 'deposit',
            id = account,
            amount = amount,
            txn = txn,
        }
        return true
    end,
}

for _, t in ipairs({
    'cp_audit',
    'cp_settings',
    'cp_settings_history',
    'cp_admin_jobs',
    'cp_admin_requests',
    'cp_officers',
    'cp_mission_runs',
    'cp_mission_runs_archive',
    'cp_dept_funding',
    'cp_disputes',
    'cp_item_rewards',
    'cp_type_payouts',
    'cp_mission_payouts',
}) do
    H.sql('DELETE FROM ' .. t)
end

for _, m in ipairs({
    'modules/access/permissions.lua',
    'modules/access/access.lua',
    'modules/admin/admin.lua',
    'modules/admin/adminkit.lua',
    'modules/admin/confighealth.lua',
    'modules/admin/settings.lua',
    'modules/access/tablet.lua',
    'modules/system/schedule.lua',
    'modules/money/engine.lua',
    'modules/money/cash.lua',
    'modules/money/payouts.lua',
    'modules/money/payments.lua',
}) do
    H.load(m)
end
H.step(0)

local Kit, Maint, Cash, Pay, Payouts = CP.AdminKit, CP.Maintenance, CP.Cash, CP.Payments, CP.Payouts
local U = CP.U

for _, src in ipairs({ 1, 2, 3, 7, 8 }) do CP.Access.refreshOfficerRow(src) end
H.sql('UPDATE cp_officers SET display_name = \'=HYPERLINK("x")\' WHERE citizenid = \'OFF00008\'')

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local reqSeq = 0
local function Fire(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'e' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    return reqId
end

local function Result(reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function Act(name, src, payload) return Result(Fire(name, src, payload)) end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    local res = H.callback('crimson-police:' .. name, src, args or {})
    if type(res) ~= 'table' then return nil, 'no reply' end
    if res.ok then return res.data end
    return nil, res.error
end

local ridSeq = 100
local function Rid()
    ridSeq = ridSeq + 1
    return ('%08x-0000-4000-8000-%012x'):format(ridSeq, 99)
end

local uuidSeq = 0
local function Uuid()
    uuidSeq = uuidSeq + 1
    return ('%08x-1111-4000-8000-000000000000'):format(uuidSeq)
end

local function Count(sql, params)
    local r = H.sql(sql, params)[1]
    if not r then return 0 end
    for _, v in pairs(r) do return math.floor(tonumber(v) or 0) end
    return 0
end

-- A payment row. o: { cid, dept, status, base, paid, owed, cash = {extra breakdown.cash fields}, voided, flagged,
-- mission, ago (seconds before now), reclaimed }
local function Row(o)
    local owed = o.owed or o.base or 500
    local c = { B = o.base or owed, mTier = 1.0, mMod = 1.0, amount = owed, status = o.status or 'pending' }
    for k, v in pairs(o.cash or {}) do c[k] = v end
    local bd = { missionLabel = o.label or 'Beat Patrol', cash = c }
    local run = o.run or Uuid()
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_reclaimed, cash_status, breakdown, flagged,
        voided, created_at) VALUES (?, ?, ?, ?, ?, 'completed', 'completed', 60, 60, ?, 1.00, ?, ?, ?, ?, ?, ?,
        FROM_UNIXTIME(?))]], {
        run,
        o.type or 'patrol',
        o.mission or 'beat_patrol',
        o.cid or 'OFF00007',
        o.dept or 'sast',
        o.base or owed,
        o.paid or 0,
        o.reclaimed or 0,
        o.status or 'pending',
        cjson.encode(bd),
        o.flagged and 1 or 0,
        o.voided and 1 or 0,
        H.time - (o.ago or 0),
    })
    return Count('SELECT MAX(id) AS id FROM cp_mission_runs'), run
end

local function RowOf(id)
    local r = H.sql('SELECT * FROM cp_mission_runs WHERE id = ?', { id })[1]
    if r then r.bd = type(r.breakdown) == 'string' and cjson.decode(r.breakdown) or r.breakdown end
    return r
end

local function LastAudit(action)
    return H.sql('SELECT * FROM cp_audit WHERE action = ? ORDER BY id DESC LIMIT 1', { action })[1]
end

local function Logged(kind, filter)
    local out = {}
    for _, e in ipairs(bank.log) do
        local ok = e.kind == kind
        for k, v in pairs(filter or {}) do if e[k] ~= v then ok = false end end
        if ok then out[#out + 1] = e end
    end
    return out
end

local function Reset()
    calls.add, calls.remove, bank.log = {}, {}, {}
    addResult, addWhy, addYield = true, nil, false
    removeResult, removeWhy = true, nil
end

local function Async(fn)
    local res
    CreateThread(function() res = table.pack(fn()) end)
    return table.unpack(res or {}, 1, res and res.n or 0)
end

-- ============================================================================
--                  1. STEP MARKERS AND WHAT EACH PAYMENT USED
-- ============================================================================

do
    Reset()
    Config.Cash.source = 'society'
    local id = Row({ status = 'pending', owed = 400 })
    H.eq(Async(function() return Cash.pay(id) end), 'paid', 'a pending row of an online officer is paid')
    local r = RowOf(id)
    H.ok(
        r.bd.cash.step == 'added' and r.bd.cash.payAmount == 400 and r.bd.cash.account == 'bank'
            and r.bd.cash.source == 'society' and r.bd.cash.societyAccount == 'sast',
        'the breakdown keeps the step markers, ' .. 'the account and the source it used'
    )
    H.eq(r.bd.cash.txn, ('CP-%s-OFF00007'):format(r.run_uuid), 'and its transaction id')

    -- AddMoney raised after the society paid and the balance can not be read: the row stays paying (H3: at step
    -- 'review', never refunded blind)
    addResult, addWhy = false, 'error'
    local realGet = CP.Qbx.getMoney
    CP.Qbx.getMoney = function() return nil end
    local id2 = Row({ status = 'pending', owed = 300 })
    local sast0 = bank.balance.sast
    H.eq(Async(function() return Cash.pay(id2) end), 'paying', 'a raise in AddMoney leaves the row paying')
    H.eq(RowOf(id2).bd.cash.step, 'review', 'H3 step marker: no telling whether it arrived (review)')
    H.eq(bank.balance.sast, sast0 - 300, 'H3: and the department is not refunded blind')
    CP.Qbx.getMoney = realGet
    -- H3: AddMoney raised and the balance did not change: refused, the department gets it back, pending again
    local id2b = Row({ status = 'pending', owed = 300 })
    sast0 = bank.balance.sast
    H.eq(Async(function() return Cash.pay(id2b) end), 'pending',
        'H3: a raise that changed nothing goes back to pending')
    H.eq(bank.balance.sast, sast0, 'H3: the department got its withdrawal back')
    Reset()
    Config.Cash.source = 'server'
end

-- ============================================================================
--                        2. THE LEDGER, TOTALS AND CSV
-- ============================================================================

do
    H.sql('DELETE FROM cp_mission_runs')
    Row({ status = 'paid', owed = 500, paid = 500, cash = { source = 'society', account = 'bank' } })
    Row({ status = 'capped', owed = 800, paid = 300 })
    Row({ status = 'unfunded', owed = 250, cid = 'OFF00008', dept = 'fib', mission = 'bank_job', type = 'tactical' })
    Row({ status = 'held', owed = 100, ago = 3 * 86400 })
    Row({ status = 'none', owed = 0 })
    for _ = 1, 3 do Row({ status = 'pending', owed = 50, cid = 'OFF00008', dept = 'fib' }) end

    local d, e = Cb('admin:getPayments', 2, {})
    H.ok(d == nil and e == 'err.no_permission', 'a supervisor can\'t open the ledger')
    d = Cb('admin:getPayments', 1, {})
    H.ok(d and d.total == 7 and #d.rows == 7, 'every row with cash, \'none\' left out: ' .. tostring(d and d.total))
    H.eq(d.switches.clawback, false, 'the money tools ship off')
    d = Cb('admin:getPayments', 1, { status = 'capped' })
    H.ok(d.total == 1 and d.rows[1].cut == 500 and d.rows[1].owed == 800, 'capped: owed and the part the cap cut')
    d = Cb('admin:getPayments', 1, { department = 'fib' })
    H.eq(d.total, 4, 'by department')
    d = Cb('admin:getPayments', 1, { missionType = 'tactical' })
    H.eq(d.total, 1, 'by mission type')
    d = Cb('admin:getPayments', 1, { citizenid = 'OFF00008', status = 'pending' })
    H.eq(d.total, 3, 'by officer and status')
    d = Cb('admin:getPayments', 1, { from = H.time - 86400, to = H.time + 60 })
    H.eq(d.total, 6, 'by dates (>= and <)')
    d = Cb('admin:getPayments', 1, { size = 2, page = 2 })
    H.ok(d.page == 2 and d.pages == 4 and #d.rows == 2, 'paging')
    -- step H6: Config.AdminUi.pageSize wins over the asked size (at least 10); withTotals brings the totals
    H.eq(d.totals, nil, 'no withTotals: no totals with the list')
    Config.AdminUi.pageSize = 4
    d = Cb('admin:getPayments', 1, { size = 2, page = 1, withTotals = true })
    H.ok(d.size == 10 and d.pages == 1 and #d.rows == 7, 'pageSize: the server\'s size, never below 10')
    H.ok(d.totals ~= nil, 'withTotals: the totals come with the list')
    d = Cb('admin:getPayments', 1, { department = 'fib', withTotals = true })
    local tot = Cb('admin:getPaymentTotals', 1, { department = 'fib' })
    H.ok(
        d.totals and d.totals.paidTotal == tot.paidTotal
            and d.totals.byStatus.pending.count == tot.byStatus.pending.count,
        'the same totals with the list'
    )
    Config.AdminUi.pageSize = 0
    local _, eF = Cb('admin:getPayments', 1, { status = 'nope' })
    H.eq(eF, 'err.invalid_filter', 'an unknown status is refused')
    _, eF = Cb('admin:getPayments', 1, { from = H.time, to = H.time - 10 })
    H.eq(eF, 'err.invalid_filter', 'from after to is refused')

    local t = Cb('admin:getPaymentTotals', 1, {})
    H.ok(
        t and t.byStatus.paid.count == 1 and t.byStatus.paid.paid == 500 and t.byStatus.pending.count == 3
            and t.byStatus.pending.owed == 150 and t.byStatus.unfunded.owed == 250,
        'totals per status (count, paid, owed)'
    )
    H.ok(t.cut == 500 and t.cappedToday == 1, 'the cap cut and the capped rows of today')
    local sast, fib
    for _, x in ipairs(t.departments) do
        if x.department == 'sast' then sast = x elseif x.department == 'fib' then fib = x end
    end
    H.ok(sast and sast.paid == 800 and sast.share == 100 and fib and fib.unfunded == 1, 'totals per department')

    -- the tablet sends a reply id: the export comes as a latent actionResult (shared/net.lua)
    H.clockMs = H.clockMs + 1100
    local reply, sent = H.callbackLatent('crimson-police:admin:exportPayments', 1, { department = 'fib' }, 'r1')
    H.ok(reply and reply.ok and reply.latent == 'r1' and reply.data == nil and #sent == 1 and sent[1].args[1] == 'r1',
        'the export comes as a latent reply')
    local x = sent[1] and sent[1].args[3]
    H.ok(x and x.rows == 4 and not x.truncated, 'CSV export')
    H.ok(x.csv:find('\'=HYPERLINK(""x"")', 1, true) ~= nil, 'a cell starting with = is neutralised and quoted')
    H.ok(LastAudit('paymentsExport') ~= nil, 'the export is audited')
    H.eq(Pay.csv({ { id = 1, createdAt = 0, name = '+1', missionLabel = 'a,b' } }):match('\n(.*)\n$'):sub(1, 30),
        '1,1970-01-01 00:00:00,,\'+1,,"a', 'a leading + gets a quote; a comma is quoted')
end

-- ============================================================================
--           3. RESOLVE A STUCK PAYMENT: MARK PAID, PAY AGAIN, LOOKUP
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    -- the history lookup: only the entry with this transaction id leaves the banking module
    local history = {
        player_transactions = {
            OFF00007 = cjson.encode({
                { trans_id = 'CP-other', amount = 99999, trans_type = 'deposit', time = 1, message = 'rent' },
                { trans_id = 'CP-run-OFF00007', amount = 300, trans_type = 'deposit', time = 1234, message = 'x' },
            }),
        },
        bank_accounts_new = {},
    }
    setHistoryDb({
        single = {
            await = function(sql, params)
                local tbl = sql:match('FROM (%S+)')
                local v = history[tbl] and history[tbl][params[1]]
                return v and { transactions = v } or nil
            end,
        },
    })
    local f = CP.Banking.findTxn('CP-run-OFF00007', { citizenid = 'OFF00007', account = 'sast' })
    H.ok(f.personal.found and f.personal.amount == 300 and f.personal.time == 1234 and f.personal.message == nil,
        'found: amount, type and time of that entry only')
    H.ok(f.society and f.society.found == false, 'not in the society history')
    local n = 0
    for _ in pairs(f.personal) do n = n + 1 end
    H.eq(n, 4, 'no other field of the officer\'s history')

    -- a row stuck at 'withdrawn' (society source)
    local id = Row({
        status = 'paying',
        owed = 300,
        run = 'run',
        cash = {
            step = 'withdrawn',
            source = 'society',
            societyAccount = 'sast',
            account = 'bank',
            payAmount = 300,
        },
    })
    local chk = Cb('admin:checkBankingTxn', 1, { rowId = id })
    H.ok(chk and chk.personal and chk.personal.found and chk.step == 'withdrawn' and chk.amount == 300,
        'Check Renewed-Banking shows the lookup and the step marker')

    local ok, e = Act('server:admin:resolvePayment', 2,
        { rowId = id, outcome = 'paid', reason = 'x', requestId = Rid() })
    H.ok(not ok and e == 'err.no_permission', 'a supervisor can\'t resolve')
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id, outcome = 'payAgain', checked = true, reason = 'x', confirm = '300', requestId = Rid() })
    H.ok(not ok and e == 'err.money_tool_off', 'Pay again is refused while its switch is off')
    Config.Cash.allowPayAgain = true
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id, outcome = 'payAgain', reason = 'x', confirm = '300', requestId = Rid() })
    H.ok(not ok and e == 'err.check_first', 'Pay again needs "I checked"')
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id, outcome = 'payAgain', checked = true, reason = 'x', confirm = '30', requestId = Rid() })
    H.ok(not ok and e == 'err.confirm_mismatch', 'Pay again asks for the amount')
    -- Z10: a row flagged for review is never paid again
    H.sql('UPDATE cp_mission_runs SET flagged = 1 WHERE id = ' .. id)
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id, outcome = 'payAgain', checked = true, reason = 'x', confirm = '300', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_flagged' and #calls.add == 0, 'Z10: Pay again refuses a flagged row')
    H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ' .. id)
    local before = bank.balance.sast
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id, outcome = 'payAgain', checked = true, reason = 'x', confirm = '300', requestId = Rid() })
    H.ok(ok == true and e.status == 'paid' and e.txn == 'CP-run-OFF00007-r2', 'Pay again pays, with its own -r2 id')
    H.ok(#calls.add == 1 and #Logged('withdraw') == 0 and bank.balance.sast == before,
        'at step withdrawn only AddMoney runs: the department is never charged twice')
    H.ok(RowOf(id).cash_status == 'paid' and RowOf(id).cash_paid == 300, 'the row is paid')
    H.ok(LastAudit('paymentPayAgain') ~= nil, 'audited')

    -- at 'claimed': both money calls run
    Reset()
    local id2 = Row({
        status = 'paying',
        owed = 200,
        cash = { step = 'claimed', source = 'society', societyAccount = 'sast', payAmount = 200 },
    })
    ok = Act('server:admin:resolvePayment', 1,
        { rowId = id2, outcome = 'payAgain', checked = true, reason = 'x', confirm = '200', requestId = Rid() })
    H.ok(ok == true and #calls.add == 1 and #Logged('withdraw') == 1,
        'at step claimed both the withdrawal and AddMoney run')
    local e2 = Logged('entry', { side = 'society' })[1]
    H.ok(e2 and e2.txn:sub(-3) == '-r2', 'the society entry carries the -r2 id too')

    -- at 'added': the money arrived
    local id3 = Row({ status = 'paying', owed = 200, cash = { step = 'added', source = 'server', payAmount = 200 } })
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id3, outcome = 'payAgain', checked = true, reason = 'x', confirm = '200', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_arrived', 'at step added Pay again is refused (mark it paid)')

    -- mark paid moves no money; a second admin then finds the row changed
    Reset()
    ok, e = Act('server:admin:resolvePayment', 3,
        { rowId = id3, outcome = 'paid', reason = 'checked RB', requestId = Rid() })
    H.ok(ok == true and e.status == 'paid' and #calls.add == 0 and #bank.log == 0, 'Mark paid moves no money')
    ok, e = Act('server:admin:resolvePayment', 1, { rowId = id3, outcome = 'paid', reason = 'x', requestId = Rid() })
    H.ok(not ok and e == 'err.state_changed', 'the second admin finds it already resolved')

    -- refused while in flight: another payment of the same officer holds the lock
    local id4 = Row({ status = 'paying', owed = 100, cash = { step = 'claimed', source = 'server', payAmount = 100 } })
    local id5 = Row({ status = 'pending', owed = 50 })
    addYield = true
    CreateThread(function() Cash.pay(id5) end)
    ok, e = Act('server:admin:resolvePayment', 1, { rowId = id4, outcome = 'paid', reason = 'x', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_in_flight', 'refused while the officer\'s payment lock is held')
    H.advance(1000)
    addYield = false
    ok = Act('server:admin:resolvePayment', 1, { rowId = id4, outcome = 'paid', reason = 'x', requestId = Rid() })
    H.eq(ok, true, 'once the lock is free it goes ahead')

    -- step Z2: a feature reward paid as a money item: Pay again gives the item, never a Qbox account named 'item'
    Reset()
    -- the money engine's deposit gives the item through ox_inventory
    local itemGiven, savedCall = {}, CP.Ext.call
    CP.Ext.call = function(res, fn, src, item, amount)
        if res ~= 'ox_inventory' then return savedCall(res, fn, src, item, amount) end
        if fn == 'AddItem' then itemGiven[#itemGiven + 1] = { src = src, item = item, amount = amount } end
        return true, true
    end
    local idItem = Row({
        status = 'paying',
        owed = 150,
        cash = { step = 'claimed', source = 'server', account = 'item', moneyItem = 'black_money', payAmount = 150 },
    })
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = idItem, outcome = 'payAgain', checked = true, reason = 'x', confirm = '150', requestId = Rid() })
    H.ok(
        ok == true and #itemGiven == 1 and itemGiven[1].item == 'black_money' and itemGiven[1].amount == 150
            and #calls.add == 0,
        'Z2: Pay again of a money-item row gives the item again'
    )
    H.eq(RowOf(idItem).cash_status, 'paid', 'Z2: and the row is paid')
    CP.Ext.call = savedCall

    -- an old row without markers while the source is society: Pay again can't know what happened
    Config.Cash.source = 'society'
    local id6 = Row({ status = 'paying', owed = 100 })
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id6, outcome = 'payAgain', checked = true, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_step_unknown', 'no step marker with the society source: refused')
    Config.Cash.source = 'server'

    -- the officer offline: refused, the claim undone
    people[7].offline = true
    ok, e = Act('server:admin:resolvePayment', 1,
        { rowId = id6, outcome = 'payAgain', checked = true, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(not ok and e == 'err.officer_offline' and RowOf(id6).bd.cash.again == nil, 'offline: refused, nothing claimed')
    people[7].offline = nil
    Config.Cash.allowPayAgain = false
    setHistoryDb(nil)
end

-- ============================================================================
--                    4. PAY NOW, RETRY PENDING, REQUEST IDS
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local id = Row({ status = 'pending', owed = 120 })
    addYield = true
    local r1 = Fire('server:admin:payNow', 1, { rowId = id, requestId = Rid() })
    local r2 = Fire('server:admin:payNow', 3, { rowId = id, requestId = Rid() })
    H.advance(1000)
    addYield = false
    local ok1 = Result(r1)
    local ok2, e2 = Result(r2)
    H.ok(#calls.add == 1, 'two Pay now at once pay once (claim then pay)')
    H.ok(ok1 == true and (ok2 == false and e2 == 'err.state_changed' or ok2 == true), 'the second finds it taken')
    H.eq(RowOf(id).cash_status, 'paid', 'paid once')

    -- a repeated request id acts once and gets the first answer
    local rid = Rid()
    local id2 = Row({ status = 'pending', owed = 80 })
    local okA, dA = Act('server:admin:payNow', 1, { rowId = id2, requestId = rid })
    local okB, dB = Act('server:admin:payNow', 1, { rowId = id2, requestId = rid })
    H.ok(okA and okB and dA.status == dB.status and #calls.add == 2, 'a repeated request acts once')

    -- offline: stays pending
    people[8].offline = true
    local id3 = Row({ status = 'pending', owed = 60, cid = 'OFF00008', dept = 'fib' })
    local okC, dC = Act('server:admin:payNow', 1, { rowId = id3, requestId = Rid() })
    H.ok(okC and dC.status == 'pending' and dC.online == false, 'an offline officer\'s row stays pending')
    people[8].offline = nil
    local okD, dD = Act('server:admin:retryPending', 1, { requestId = Rid() })
    H.ok(okD and dD.paid == 1 and RowOf(id3).cash_status == 'paid', 'Retry all pending pays the online officers')

    -- Z8: an approved row whose release did not run (still 'held', flag cleared): the login sweep and Pay now pay it
    local id4 = Row({ status = 'held', owed = 70 })
    H.eq(Async(function() return Cash.payPending(7) end), 1, 'Z8: payPending pays a held row no longer flagged')
    H.eq(RowOf(id4).cash_status, 'paid', 'Z8: ...paid')
    local id5 = Row({ status = 'held', owed = 40, flagged = true })
    H.eq(Async(function() return Cash.payPending(7) end), 0, 'Z8: a held row still flagged waits for review')
    local okF, eF = Act('server:admin:payNow', 1, { rowId = id5, requestId = Rid() })
    H.ok(okF == false and eF == 'err.state_changed', 'Z8: Pay now refuses a held row still flagged')
    H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ?', { id5 })
    local okG, dG = Act('server:admin:payNow', 1, { rowId = id5, requestId = Rid() })
    H.ok(okG and dG.status == 'paid', 'Z8: Pay now pays a held row once its flag is cleared')
    -- Z14: a flagged 'pending' row is never paid: Pay now refuses it (no audit, no paid toast)
    local id6 = Row({ status = 'pending', owed = 30, flagged = true })
    local okH, eH = Act('server:admin:payNow', 1, { rowId = id6, requestId = Rid() })
    H.ok(okH == false and eH == 'err.state_changed', '(Z14) Pay now refuses a flagged pending row')
    H.eq(RowOf(id6).cash_status, 'pending', '(Z14) it stays pending')
end

-- ============================================================================
--                        5. RETRY UNFUNDED (SHIPS OFF)
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    Config.Cash.source = 'society'
    local a = Row({ status = 'unfunded', owed = 300 })
    local b = Row({ status = 'unfunded', owed = 200 })
    Row({ status = 'unfunded', owed = 999, voided = true })
    -- another character of admin 1's licence: never in admin 1's department retry (the S guard)
    local mine = Row({ status = 'unfunded', owed = 700, cid = 'ALT00001' })
    local pv = Cb('admin:previewRetryUnfunded', 1, { department = 'sast' })
    H.ok(pv and pv.effect.count == 2 and pv.effect.total == 500, 'the preview: rows and total (voided rows left out)')
    H.eq(pv and pv.effect.excluded, 1, 'the admin\'s own rows are left out of a department retry')
    local ok, e = Act('server:admin:retryUnfunded', 1, {
        department = 'sast',
        reason = 'topped up',
        confirm = '500',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(not ok and e == 'err.money_tool_off', 'refused while its switch is off')
    Config.Cash.allowUnfundedRetry = true
    bank.balance.sast = 400
    pv = Cb('admin:previewRetryUnfunded', 1, { department = 'sast' })
    ok, e = Act('server:admin:retryUnfunded', 1, {
        department = 'sast',
        reason = 'topped up',
        confirm = '500',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(not ok and e == 'err.balance_low' and RowOf(a).cash_status == 'unfunded', 'the balance must cover the total')
    bank.balance.sast = 5000
    ok, e = Act('server:admin:retryUnfunded', 1,
        { department = 'sast', reason = 'topped up', confirm = '500', previewToken = 'nope', requestId = Rid() })
    H.ok(not ok and (e == 'err.preview_expired' or e == 'err.preview_missing'), 'the preview token is needed')
    pv = Cb('admin:previewRetryUnfunded', 1, { department = 'sast' })
    ok, e = Act('server:admin:retryUnfunded', 1, {
        department = 'sast',
        reason = 'topped up',
        confirm = '500',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok and e.claimed == 2 and e.paid == 2, 'with the switch on and the money there: paid')
    H.ok(RowOf(a).cash_status == 'paid' and RowOf(b).cash_status == 'paid' and bank.balance.sast == 4500,
        'both rows paid from the account')
    H.eq(RowOf(mine).cash_status, 'unfunded', 'the admin\'s own unfunded row is not paid by their department retry')
    H.ok(Logged('entry', { side = 'personal' })[1].txn == ('CP-%s-OFF00007'):format(RowOf(a).run_uuid),
        'with the same transaction id (no money moved before)')
    Config.Cash.allowUnfundedRetry = false
    Config.Cash.source = 'server'
end

-- ============================================================================
--                      6. PAY THE CAPPED REST (SHIPS OFF)
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local id = Row({ status = 'capped', owed = 500, paid = 300 })
    local ok, e = Act('server:admin:payCapRest', 1, { rowId = id, reason = 'x', confirm = '200', requestId = Rid() })
    H.ok(not ok and e == 'err.money_tool_off', 'refused while its switch is off')
    Config.Cash.allowCapTopUp = true
    ok, e = Act('server:admin:payCapRest', 1, { rowId = id, reason = 'x', confirm = '500', requestId = Rid() })
    H.ok(not ok and e == 'err.confirm_mismatch', 'the typed amount is the server\'s rest (200)')
    -- Z10: a row flagged for review is never topped up
    H.sql('UPDATE cp_mission_runs SET flagged = 1 WHERE id = ' .. id)
    ok, e = Act('server:admin:payCapRest', 1, { rowId = id, reason = 'x', confirm = '200', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_flagged' and #calls.add == 0, 'Z10: Pay the rest refuses a flagged row')
    H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ' .. id)
    addYield = true
    local r1 = Fire('server:admin:payCapRest', 1, { rowId = id, reason = 'x', confirm = '200', requestId = Rid() })
    local r2 = Fire('server:admin:payCapRest', 3, { rowId = id, reason = 'x', confirm = '200', requestId = Rid() })
    H.advance(1000)
    addYield = false
    local ok1, d1 = Result(r1)
    local ok2, e2 = Result(r2)
    H.ok(ok1 == true and d1.txn:sub(-2) == '-r' and ok2 == false and e2 == 'err.state_changed',
        'once under two calls at the same moment (the restPaid claim); its own -r id')
    H.ok(#calls.add == 1 and calls.add[1].amount == 200, 'the rest only')
    local r = RowOf(id)
    H.ok(r.cash_paid == 500 and r.cash_status == 'capped' and r.bd.cash.restPaid == 'paid',
        'cash_paid grows by the rest')
    -- Qbox refused: the marker goes back so it can be tried again
    Reset()
    local id2 = Row({ status = 'capped', owed = 400, paid = 100 })
    addResult = false
    ok, e = Act('server:admin:payCapRest', 1, { rowId = id2, reason = 'x', confirm = '300', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_refused' and RowOf(id2).bd.cash.restPaid == nil, 'refused by Qbox: claim undone')
    -- Z9: the department was charged, Qbox refused and the refund failed: not 'Nothing was paid'
    Reset()
    Config.Cash.source = 'society'
    local id4 = Row({ status = 'capped', owed = 400, paid = 100 })
    addResult = false
    depositHook = function() error('banking down') end
    ok, e = Act('server:admin:payCapRest', 1, { rowId = id4, reason = 'x', confirm = '300', requestId = Rid() })
    depositHook = nil
    Config.Cash.source = 'server'
    H.ok(not ok and e == 'err.payment_refund_failed',
        'Z9: a failed refund says the department was charged: ' .. tostring(e))
    H.ok(not CP.L('err.payment_refund_failed'):find('Nothing was paid', 1, true),
        'Z9: its text never says nothing was paid')
    -- Z7: a feature reward row (source 'server', paid as a money item): new money as a money item, even in society
    -- mode, never a department withdraw nor a Qbox account named 'item'
    Reset()
    Config.Cash.source = 'society'
    -- the money engine's deposit gives the item through ox_inventory
    local itemGiven, savedCall = {}, CP.Ext.call
    CP.Ext.call = function(res, fn, src, item, amount)
        if res ~= 'ox_inventory' then return savedCall(res, fn, src, item, amount) end
        if fn == 'AddItem' then itemGiven[#itemGiven + 1] = { src = src, item = item, amount = amount } end
        return true, true
    end
    local id3 = Row({
        status = 'capped',
        owed = 400,
        paid = 100,
        type = 'feature_reward',
        cash = { source = 'server', account = 'item', moneyItem = 'black_money' },
    })
    ok, e = Act('server:admin:payCapRest', 1, { rowId = id3, reason = 'x', confirm = '300', requestId = Rid() })
    CP.Ext.call = savedCall
    Config.Cash.source = 'server'
    H.ok(ok == true, 'Z7: the rest of a money item row is paid: ' .. tostring(e))
    H.ok(#itemGiven == 1 and itemGiven[1].item == 'black_money' and itemGiven[1].amount == 300, 'Z7: as the money item')
    H.eq(#Logged('withdraw'), 0, 'Z7: and never from a department account')
    H.eq(#calls.add, 0, 'Z7: no Qbox AddMoney call')
    Config.Cash.allowCapTopUp = false
end

-- ============================================================================
--                   7. FORFEITED CASH AFTER ALL (SHIPS OFF)
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local id = Row({ status = 'forfeited', owed = 150 })
    local voided = Row({ status = 'forfeited', owed = 150, voided = true })
    local paidBefore = Row({ status = 'forfeited', owed = 150, paid = 20 })
    Config.Cash.restoreForfeited = true
    local ok, e = Act('server:admin:repayForfeited', 1,
        { rowId = voided, reason = 'x', confirm = '150', requestId = Rid() })
    H.ok(not ok and e == 'err.restore_first', 'a row still voided: restore the run first')
    ok, e = Act('server:admin:repayForfeited', 1,
        { rowId = paidBefore, reason = 'x', confirm = '150', requestId = Rid() })
    H.ok(not ok and e == 'err.state_changed', 'only from forfeited with nothing paid')
    ok, e = Act('server:admin:repayForfeited', 1, { rowId = id, reason = 'x', confirm = '150', requestId = Rid() })
    H.ok(ok and e.status == 'paid' and #calls.add == 1, 'forfeited -> pending -> paid')
    Config.Cash.restoreForfeited = false
    ok, e = Act('server:admin:repayForfeited', 1, { rowId = id, reason = 'x', confirm = '150', requestId = Rid() })
    H.eq(e, 'err.money_tool_off', 'off again: refused')
end

-- ============================================================================
--                        8. FORFEIT NOW, CANCEL PAYMENT
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local v = Row({ status = 'held', owed = 90, voided = true })
    local disputed = Row({ status = 'held', owed = 90, voided = true })
    H.sql([[INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to, status, created_at)
        VALUES (?, 'OFF00007', 'no', 'supervisor', 'open', NOW())]], { disputed })
    local ok, e = Act('server:admin:forfeitNow', 1, { rowId = disputed, reason = 'x' })
    H.ok(not ok and e == 'err.state_changed', 'Forfeit now: not while a dispute is open')
    ok = Act('server:admin:forfeitNow', 1, { rowId = v, reason = 'x' })
    H.ok(ok and RowOf(v).cash_status == 'forfeited', 'Forfeit now: held -> forfeited')
    local p = Row({ status = 'pending', owed = 75 })
    ok, e = Act('server:admin:cancelPayment', 1, { rowId = p, reason = 'mistake', confirm = '7' })
    H.eq(e, 'err.confirm_mismatch', 'Cancel payment asks for the amount')
    ok = Act('server:admin:cancelPayment', 1, { rowId = p, reason = 'mistake', confirm = '75' })
    local r = RowOf(p)
    H.ok(ok and r.cash_status == 'forfeited' and r.final_points == 60 and r.voided == 0 or r.voided == false,
        'Cancel payment: forfeited, the run keeps its points')
    H.ok(LastAudit('paymentCancel') ~= nil and LastAudit('paymentForfeit') ~= nil, 'both audited')
end

-- ============================================================================
--                           9. CLAWBACK (SHIPS OFF)
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    people[7].money.bank = 1000
    local id = Row({
        status = 'paid',
        owed = 300,
        paid = 300,
        cash = { source = 'society', societyAccount = 'sast', account = 'bank' },
    })
    local ok, e = Act('server:admin:clawback', 1,
        { rowId = id, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.eq(e, 'err.money_tool_off', 'refused while its switch is off')
    Config.Cash.allowClawback = true
    ok, e = Act('server:admin:clawback', 1,
        { rowId = id, amount = 400, reason = 'x', confirm = '400', requestId = Rid() })
    H.ok(not ok and e == 'err.clawback_too_much', 'never more than was paid')
    local sast = bank.balance.sast
    ok, e = Act('server:admin:clawback', 1,
        { rowId = id, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(ok and e.txn == ('CP-%s-OFF00007-back1'):format(RowOf(id).run_uuid) and e.refunded == true,
        'taken back with its own -back1 id')
    H.ok(people[7].money.bank == 900 and bank.balance.sast == sast + 100 and RowOf(id).cash_reclaimed == 100,
        'the officer pays it, the department gets it back (it paid it)')
    local w = Logged('entry', { side = 'personal', type = 'withdraw' })[1]
    H.ok(w and w.amount == 100, 'a withdraw entry in the officer\'s bank history')
    ok, e = Act('server:admin:clawback', 1,
        { rowId = id, amount = 150, reason = 'x', confirm = '150', requestId = Rid() })
    H.ok(ok and e.txn:sub(-6) == '-back2', 'the second one is -back2')
    -- two at once never pass cash_paid (50 left)
    local r1 = Fire('server:admin:clawback', 1,
        { rowId = id, amount = 50, reason = 'x', confirm = '50', requestId = Rid() })
    local r2 = Fire('server:admin:clawback', 3,
        { rowId = id, amount = 50, reason = 'x', confirm = '50', requestId = Rid() })
    local okA, okB = Result(r1), Result(r2)
    H.ok((okA == true) ~= (okB == true) and RowOf(id).cash_reclaimed == 300, 'two clicks never take more than was paid')
    -- the balance is lower: refused, the increment taken back
    local id2 = Row({ status = 'paid', owed = 500, paid = 500, cash = { source = 'server', account = 'bank' } })
    people[7].money.bank = 20
    ok, e = Act('server:admin:clawback', 1,
        { rowId = id2, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(not ok and e == 'err.balance_low' and RowOf(id2).cash_reclaimed == 0, 'refused when the bank balance is lower')
    people[7].money.bank = 1000
    removeResult = false
    ok, e = Act('server:admin:clawback', 1,
        { rowId = id2, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(not ok and e == 'err.clawback_refused' and RowOf(id2).cash_reclaimed == 0, 'RemoveMoney failed: taken back')
    removeResult = true
    -- step Z2: a feature reward paid as a money item cannot be taken back from a Qbox account
    local idItem = Row({
        status = 'paid',
        owed = 200,
        paid = 200,
        cash = { source = 'server', account = 'item', moneyItem = 'black_money' },
    })
    ok, e = Act('server:admin:clawback', 1,
        { rowId = idItem, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(not ok and e == 'err.clawback_item' and RowOf(idItem).cash_reclaimed == 0,
        'Z2: a money-item row is refused up front, nothing claimed')
    local sast2 = bank.balance.sast
    ok = Act('server:admin:clawback', 1,
        { rowId = id2, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(ok and bank.balance.sast == sast2, 'source server: no department refund')
    -- never your own characters
    local own = Row({ status = 'paid', owed = 100, paid = 100, cid = 'ALT00001' })
    ok, e = Act('server:admin:clawback', 1,
        { rowId = own, amount = 10, reason = 'x', confirm = '10', requestId = Rid() })
    H.eq(e, 'err.self_target', 'another character of the admin\'s licence is refused')
    Config.Cash.allowClawback = false
end

-- ============================================================================
--                     10. MANUAL CASH PAYMENT (SHIPS OFF)
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local ok, e = Act('server:admin:manualCash', 1,
        { citizenid = 'OFF00007', amount = 300, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.money_tool_off', 'refused while its switch is off')
    Config.Cash.allowManualCash = true
    Config.Cash.dailyCap = 100
    Config.Cash.manualDailyLimit = 1000
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'OFF00007', amount = 0, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.invalid_amount', '1 dollar at least')
    ok, e = Act('server:admin:manualCash', 1,
        { citizenid = 'OFF00007', amount = 13000, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.confirm_mismatch', 'above half the max payout the amount must be typed')
    local rid = Rid()
    ok, e = Act('server:admin:manualCash', 1,
        { citizenid = 'OFF00007', amount = 300, reason = 'wrong payout', requestId = rid })
    H.ok(ok and e.status == 'paid' and calls.add[1].amount == 300, 'pays the typed amount, not cut by the daily cap')
    Act('server:admin:manualCash', 1,
        { citizenid = 'OFF00007', amount = 300, reason = 'wrong payout', requestId = rid })
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE mission_id = \'manual_cash\''), 1,
        'a repeated request id makes no second payment')
    local r = RowOf(e.id)
    H.ok(r.mission_type == 'manual_award' and r.final_points == 0 and r.cash_base == 300,
        'a manual_award row (out of run counts, goals, streaks and the draw), 0 points')
    H.eq(Async(function() return Cash.paidToday('OFF00007') end), 0, 'not counted in the daily cap')
    -- Z9: the server stops while the pay waits: the audited row is already 'pending' for the sweeps
    local realPay, seenStatus = Cash.pay, nil
    Cash.pay = function(id)
        seenStatus = RowOf(id).cash_status
        error('resource stopped')
    end
    Act('server:admin:manualCash', 1, { citizenid = 'OFF00007', amount = 50, reason = 'x', requestId = Rid() })
    Cash.pay = realPay
    H.eq(seenStatus, 'pending', 'Z9: the audited manual cash row is pending before the pay waits')
    H.sql('DELETE FROM cp_mission_runs WHERE cash_base = 50 AND mission_id = \'manual_cash\'')
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'OFF00007', amount = 800, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.manual_limit', 'the per-admin daily limit, counted from today\'s rows')
    -- the same player on another character of their licence shares that limit
    people[1].cid = 'ALT00001'
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'OFF00007', amount = 800, reason = 'x', requestId = Rid() })
    people[1].cid = 'ADM00001'
    H.eq(e, 'err.manual_limit', 'the daily limit is per player (licence), not per character')
    -- the row is never paid before its audit row exists: a login payment in between finds nothing to pay
    local Kit = CP.AdminKit
    local realAudit = Kit.auditSync
    local before = #calls.add
    Kit.auditSync = function(...)
        local args = { ... }
        if args[3] == 'manualCash' then
            Cash.payPending(7)
            return nil
        end
        return realAudit(...)
    end
    ok, e = Act('server:admin:manualCash', 3, { citizenid = 'OFF00007', amount = 50, reason = 'x', requestId = Rid() })
    Kit.auditSync = realAudit
    H.ok(ok == false and e == 'err.audit_failed', 'the audit row failed: refused')
    H.eq(#calls.add, before, 'and no money moved, even with a login payment between the row and its audit row')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE mission_id = \'manual_cash\' AND cash_base = 50'), 0,
        'the half-written row is removed')
    ok = Act('server:admin:manualCash', 3, { citizenid = 'OFF00007', amount = 800, reason = 'x', requestId = Rid() })
    H.eq(ok, true, 'another admin has a limit of their own')
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'ADM00001', amount = 10, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.self_target', 'never to the admin\'s own character')
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'NOBODY99', amount = 10, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.unknown_officer', 'only an officer Crimson-Police knows')
    H.ok(LastAudit('manualCash') ~= nil, 'audited')
    -- Z7: a payment Cash.pay does not take now (it answers nil) is marked pending, so a sweep pays it later
    local realPay = Cash.pay
    Cash.pay = function() return nil end
    ok, e = Act('server:admin:manualCash', 3, { citizenid = 'OFF00007', amount = 20, reason = 'x', requestId = Rid() })
    Cash.pay = realPay
    H.ok(ok == true and e.status == 'pending', 'Z7: the admin is told pending')
    H.eq(ok and RowOf(e.id).cash_status, 'pending', 'Z7: and the row is pending, not left at none')
    Config.Cash.dailyCap = 0
    Config.Cash.allowManualCash = false
end

-- ============================================================================
--                      11. DEPARTMENT FUNDS AND ADD FUNDS
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    Config.Cash.source = 'society'
    bank.balance.sast = 1000
    Row({ status = 'paid', owed = 200, paid = 200, cash = { source = 'society' } })
    Row({ status = 'unfunded', owed = 50 })
    local f = Cb('admin:getDepartmentFunds', 1, { department = 'sast' })
    H.ok(f and f.balance == 1000 and f.spent.today == 200 and f.unfunded == 1 and f.allowAddFunds == false,
        'the Funds card: balance, spending, unfunded rows')
    local _, eS = Cb('admin:getDepartmentFunds', 2, { department = 'sast' })
    H.eq(eS, 'err.no_permission', 'admins only')
    local ok, e = Act('server:admin:addDepartmentFunds', 1,
        { department = 'sast', amount = 500, reason = 'x', confirm = '500', requestId = Rid() })
    H.eq(e, 'err.money_tool_off', 'refused while its switch is off')
    Config.Cash.allowAddFunds = true
    H.clockMs = H.clockMs + 11000   -- one Add funds per department per 10 s, whichever admin asks
    local seen = nil
    depositHook = function()
        seen = H.sql('SELECT state, txn FROM cp_dept_funding ORDER BY id DESC LIMIT 1')[1]
    end
    local rid = Rid()
    ok, e = Act('server:admin:addDepartmentFunds', 1,
        { department = 'sast', amount = 500, reason = 'top up', confirm = '500', requestId = rid })
    H.ok(ok and seen and seen.state == 'depositing' and seen.txn == e.txn,
        'the funding row is written before the deposit (H3: depositing): ' .. tostring(not ok and e))
    H.ok(e.txn == ('CP-FUND-%d'):format(e.id) and bank.balance.sast == 1500, 'deposited, CP-FUND-<id>')
    local entry = Logged('entry', { side = 'society', type = 'deposit' })[1]
    H.ok(entry and entry.txn == e.txn, 'a deposit entry in the department\'s bank history')
    H.eq(H.sql('SELECT state FROM cp_dept_funding WHERE id = ?', { e.id })[1].state, 'done', 'then done')
    H.clockMs = H.clockMs + 11000
    Act('server:admin:addDepartmentFunds', 1,
        { department = 'sast', amount = 500, reason = 'top up', confirm = '500', requestId = rid })
    H.ok(#Logged('deposit') == 1 and bank.balance.sast == 1500, 'a retried request makes no second deposit')
    H.clockMs = H.clockMs + 11000
    ok, e = Act('server:admin:addDepartmentFunds', 1,
        { department = 'sast', amount = 60000, reason = 'x', confirm = '60000', requestId = Rid() })
    H.eq(e, 'err.invalid_amount', 'at most Cash.addFundsMax')
    f = Cb('admin:getDepartmentFunds', 1, { department = 'sast' })
    H.ok(f.funded == 500 and #f.recent == 1, 'the running total of admin funding')
    depositHook = nil
    Config.Cash.allowAddFunds = false

    -- health lines: a missing account, a low balance
    Config.Cash.lowBalanceWarn = 2000
    bank.balance.fib = nil
    local lines = Pay.health()
    local text = {}
    for _, l in ipairs(lines) do text[#text + 1] = l.level .. ':' .. l.text end
    text = table.concat(text, '|')
    H.ok(text:find('error:', 1, true) ~= nil and text:find('fib', 1, true) ~= nil,
        'a missing society account: ' .. text)
    H.ok(text:find('warn:', 1, true) ~= nil, 'a balance below Cash.lowBalanceWarn')
    bank.balance.fib = 5000
    -- (Z12) source = 'society' with no banking script serving: pay goes out as new money, so no unfunded lines
    CP.Banking.societyOn = function() return false end
    local none = Pay.health()
    local errs = 0
    for _, l in ipairs(none) do if l.level == 'error' or l.level == 'warn' then errs = errs + 1 end end
    H.eq(errs, 0, '(Z12) no banking script: no society account or low balance line')
    H.eq(Pay.lowBalanceToasts(), 0, '(Z12) and no low balance toast')
    CP.Banking.societyOn = nil
    Config.Cash.lowBalanceWarn = 0
    Config.Cash.source = 'server'
end

-- ============================================================================
--           12. A TURNED-OFF DEPARTMENT STILL PAYS FROM ITS ACCOUNT
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    Config.Cash.source = 'society'
    local realDept = CP.Access.department
    CP.Access.department = function(key)
        if key == 'fib' then
            return nil
        end -- the department list leaves a turned-off department out
        return realDept(key)
    end
    Config.Departments.fib.enabled = false
    local id = Row({ status = 'pending', owed = 100, cid = 'OFF00008', dept = 'fib' })
    local before = bank.balance.fib
    H.eq(Async(function() return Cash.pay(id) end), 'paid', 'paid, never unfunded')
    H.eq(bank.balance.fib, before - 100, 'from the turned-off department\'s own account')
    Config.Departments.fib.enabled = true
    CP.Access.department = realDept
    Config.Cash.source = 'server'
end

-- ============================================================================
--                      13. PAYOUTS: UNLOCK AND ADJUST ALL
-- ============================================================================

do
    Payouts._reload()
    local ok = Act('server:admin:setTypePayout', 1, { type = 'patrol', amount = 400, unlock = true, reason = 'x' })
    H.eq(ok, true, 'an admin sets a type payout and leaves it open to supervisors')
    local a = LastAudit('setTypePayout')
    H.eq(a.new_value, 'unlocked:400', 'audited as unlocked:<amount>')
    local _, locked = Payouts.typePayout('patrol')
    H.eq(locked, false, 'not locked')
    H.sql('UPDATE cp_type_payouts SET updated_at = FROM_UNIXTIME(?) WHERE mission_type = \'patrol\'', { H.time - 7200 })
    Payouts._reload()
    local lo, hi = Payouts._supervisorRange('patrol')
    local okS, eS = Payouts.setType(2, 'patrol', hi + 1, 'too much', 'supervisor')
    H.ok(not okS and eS == 'err.payout_out_of_range', 'the supervisor range applies again')
    okS = Payouts.setType(2, 'patrol', lo, 'lower', 'supervisor')
    H.eq(okS, true, 'and a supervisor may move it within the range')

    local pv, e = Cb('admin:previewPayoutAdjust', 2, { mode = 'pct', value = 10, scope = 'types' })
    H.eq(e, 'err.no_permission', 'a supervisor can\'t adjust all')
    _, e = Cb('admin:previewPayoutAdjust', 1, { mode = 'pct', value = 600, scope = 'types' })
    H.eq(e, 'err.invalid_amount', 'at most +500 %')
    Config.Cash.maxPayout = 2000
    pv = Cb('admin:previewPayoutAdjust', 1, { mode = 'pct', value = 500, scope = 'types' })
    local clamped = true
    for _, row in ipairs(pv.effect.rows) do if row.new > 2000 then clamped = false end end
    H.ok(#pv.effect.rows > 0 and clamped, 'each new value is clamped to the payout range')
    local okA, dA = Act('server:admin:adjustAllPayouts', 1, {
        mode = 'pct',
        value = 500,
        scope = 'types',
        reason = 'x',
        confirm = 'ADJUST',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.ok(okA and dA.changed == #pv.effect.rows, 'Adjust all changes every previewed value')
    H.eq(Count(
        'SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'setTypePayout\' AND created_at >= FROM_UNIXTIME(?)',
        { H.time - 1 }
    ) >= dA.changed, true, 'one audit line per value')
    H.ok(LastAudit('payoutsAdjustAll') ~= nil, 'and one summary line')
    local again = Act('server:admin:adjustAllPayouts', 1, {
        mode = 'pct',
        value = 500,
        scope = 'types',
        reason = 'x',
        confirm = 'ADJUST',
        previewToken = pv.previewToken,
        requestId = Rid(),
    })
    H.eq(again, false, 'a used preview token is refused')
    Config.Cash.maxPayout = 25000
    local view = Payouts._adminView()
    H.ok(view.outOfRange == 0, 'stored payouts inside the range: none flagged')
    Config.Cash.maxPayout = 1000
    H.ok(Payouts._adminView().outOfRange > 0, 'a lower maxPayout flags the stored payouts above it')
    Config.Cash.maxPayout = 25000
end

-- ============================================================================
--            14. ARCHIVE AND FORFEITURE JOBS: SKIP RULES, BUSY LOCK
-- ============================================================================

do
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_mission_runs_archive')
    local old = 400 * 86400
    local final = Row({ status = 'paid', owed = 10, paid = 10, ago = old })
    local pend = Row({ status = 'pending', owed = 10, ago = old })
    local paying = Row({ status = 'paying', owed = 10, ago = old })
    local withReward = Row({ status = 'paid', owed = 10, paid = 10, ago = old })
    H.sql([[INSERT INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status)
        VALUES (?, 'run', 'k', 'OFF00007', 'water', 1, 5, 'pending')]], { withReward })
    -- the busy lock is held: the clean-up waits, then gives up
    Kit.lock('job', { kind = 'bulkVoid' })
    local res
    CreateThread(function() res = CP.Schedule._runRetention(H.time) end)
    H.advance(61000, 250)
    H.ok(res and res.skipped == 'busy' and Count('SELECT COUNT(*) AS n FROM cp_mission_runs_archive') == 0,
        'the archive job waits for an admin job and archives nothing while it runs')
    -- released while waiting: it goes on
    res = nil
    CreateThread(function() res = CP.Schedule._runRetention(H.time) end)
    H.advance(2000, 500)
    Kit.unlock('job')
    H.advance(1000, 250)
    H.ok(res and res.archived == 1 and res.kept == 3,
        'then archives only the finished row: ' .. tostring(res and res.archived))
    H.ok(RowOf(final) == nil and RowOf(pend) and RowOf(paying) and RowOf(withReward),
        'held, pending and paying rows and rows with unfinished rewards stay')

    -- the forfeiture job waits too
    H.sql('DELETE FROM cp_mission_runs')
    local v = Row({ status = 'held', owed = 10, voided = true, ago = 3 * 86400 })
    Kit.lock('job', { kind = 'bulkVoid' })
    local n
    CreateThread(function() n = Cash._forfeitureJob() end)
    H.advance(1000, 250)
    H.ok(n == nil and RowOf(v).cash_status == 'held', 'the forfeiture job waits while a bulk job runs')
    Kit.unlock('job')
    H.advance(1000, 250)
    H.ok(n == 1 and RowOf(v).cash_status == 'forfeited', 'and forfeits once it ends')
end

-- ============================================================================
--                               15. MAINTENANCE
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    local id = Row({ status = 'pending', owed = 70 })
    Maint.begin('storage', { by = 'test' })
    H.eq(Async(function() return Cash.payPending(7) end), 0, 'login payPending waits while locked')
    H.eq(Async(function() return Cash.pay(id) end), nil, 'and Cash.pay')
    H.ok(RowOf(id).cash_status == 'pending' and #calls.add == 0, 'nothing moved, the row waits')
    local r = CP.Schedule._runRetention(H.time)
    H.eq(r.skipped, 'maintenance', 'the clean-up waits')
    local ok, e = Act('server:admin:payNow', 1, { rowId = id, requestId = Rid() })
    H.eq(e, 'err.maintenance', 'payment actions are refused')
    Maint.finish('storage')
    H.advance(100)
    H.eq(RowOf(id).cash_status, 'paid', 'when the lock ends the rows that waited are paid')

    -- a store left behind never pays
    local id2 = Row({ status = 'pending', owed = 70 })
    Maint.begin('left_behind', {})
    H.eq(Async(function() return Cash.payPending(7) end), 0, 'a left-behind store never pays')
    H.eq(RowOf(id2).cash_status, 'pending', 'its rows stay as they are')
    Maint.finish('left_behind')

    -- F20: a payment or the forfeiture that waits for the store while the start takes the left-behind lock (the
    -- runner takes it before any waiting caller goes on) reads the lock after that wait, never before it
    local realReady = CP.Migrations.ready
    local function Locked(fn)
        CP.Migrations.ready = function()
            if not Maint.active() then Maint.begin('left_behind', { by = 'start' }) end
            return true
        end
        local res = table.pack(Async(fn))
        CP.Migrations.ready = realReady
        return table.unpack(res, 1, res.n)
    end
    local id3 = Row({ status = 'pending', owed = 70 })
    H.eq(Locked(function() return Cash.pay(id3) end), nil, 'Cash.pay reads the lock the start took while it waited')
    H.eq(RowOf(id3).cash_status, 'pending', 'so the row is not paid')
    H.eq(Locked(function() return Cash.payPending(7) end), 0, 'the login pay too')
    H.eq(RowOf(id3).cash_status, 'pending', '(still not paid)')
    local v2 = Row({ status = 'held', owed = 70, voided = true, ago = 3 * 86400 })
    H.eq(Locked(function() return Cash._forfeitureJob() end), 0, 'and the forfeiture job')
    H.eq(RowOf(v2).cash_status, 'held', 'which changes nothing in a store left behind')
    Maint.finish('left_behind')
end

-- ============================================================================
--                        16. CLEAN-UP (SYSTEM -> JOBS)
-- ============================================================================

do
    local function Job(view, id)
        for _, j in ipairs(view and view.jobs or {}) do if j.id == id then return j end end
        return nil
    end
    local d, e = Cb('admin:getJobs', 2, {})
    H.eq(e, 'err.no_permission', 'admins only')
    H.sql(
        'INSERT INTO cp_admin_requests (request_id, action, actor, created_at) VALUES (?, \'x\', \'y\', FROM_UNIXTIME(?))',
        { 'ffffffff-0000-4000-8000-000000000001', H.time - 8 * 86400 })
    Kit.lock('job', { kind = 'bulkVoid' })
    local ok
    ok, e = Act('server:admin:runJobNow', 1, { id = 'cleanup', reason = 'test' })
    H.ok(not ok and e == 'err.admin_busy', 'Run now is refused while a long job runs')
    Kit.unlock('job')
    ok, e = Act('server:admin:runJobNow', 2, { id = 'cleanup', reason = 'test' })
    H.eq(e, 'err.no_permission', 'a supervisor can\'t run it')
    ok, d = Act('server:admin:runJobNow', 1, { id = 'cleanup', reason = 'test' })
    local c = Job(d, 'cleanup')
    H.ok(ok and c and c.last and c.last.result.requestsDeleted >= 1 and c.last.by == 'ADM00001',
        'Run now: the result is kept')
    H.ok(LastAudit('jobRun') ~= nil, 'audited')
    d = Cb('admin:getJobs', 1, {})
    c = Job(d, 'cleanup')
    H.ok(c and c.last and c.nextRunAt > H.time and d.requestDays == 7, 'admin:getJobs: last run and next run')
    ok, e = Act('server:admin:runJobNow', 3, { id = 'cleanup', reason = 'again' })
    H.eq(e, 'err.rate_limited', 'once per 10 minutes, whichever admin asks')
end

-- ============================================================================
--                            17. THE SIDEBAR BADGE
-- ============================================================================

do
    H.sql('DELETE FROM cp_mission_runs')
    Row({ status = 'paying', owed = 10 })
    Pay._resetNav()
    H.eq(Pay.stuckCount(), 1, 'adminPayments: payments stuck in paying')
end

-- ============================================================================
--            18. H3: WHAT A MONEY CALL DID, FOLLOW-UPS, AUDIT FIRST
-- ============================================================================

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    Config.Cash.allowPayAgain, Config.Cash.allowClawback, Config.Cash.allowCapTopUp = true, true, true
    local realAdd, realRemove, realGet = CP.Qbx.addMoney, CP.Qbx.removeMoney, CP.Qbx.getMoney
    local realWithdraw, realDeposit = CP.Banking.withdrawSociety, CP.Banking.depositSociety
    local function Stuck(id)
        for _, s in ipairs(Cash.stuckPayments()) do if s.id == id then return s end end
        return nil
    end
    -- (the H3 entry points, read so the old code fails here instead of stopping the spec)
    local function Call(t, name, ...)
        local fn = t[name]
        if type(fn) ~= 'function' then return nil end
        return fn(...)
    end
    local function Resolve(id, outcome, confirm)
        return Act('server:admin:resolvePayment', 1,
            { rowId = id, outcome = outcome, checked = true, reason = 'H3', confirm = confirm, requestId = Rid() })
    end

    -- (a) AddMoney credits, then raises: the balance shows it arrived, so the row is paid once (with its history
    -- entry) and Pay again is refused
    CP.Qbx.addMoney = function(src, account, amount)
        people[src].money[account] = (people[src].money[account] or 0) + amount
        return false, 'error'
    end
    people[7].money.bank = 1000
    local id = Row({ status = 'pending', owed = 300, cash = { source = 'server', account = 'bank' } })
    H.eq(Async(function() return Cash.pay(id) end), 'paid', 'H3 (a): a raise after the money arrived: paid')
    CP.Qbx.addMoney = realAdd
    H.ok(people[7].money.bank == 1300 and RowOf(id).cash_paid == 300, 'H3 (a): once, $300')
    local e1 = Logged('entry', { side = 'personal', type = 'deposit' })[1]
    H.ok(e1 and e1.txn == ('CP-%s-OFF00007'):format(RowOf(id).run_uuid), 'H3 (a): with its bank history entry')
    local ok, e = Resolve(id, 'payAgain', '300')
    H.ok(not ok and e == 'err.state_changed' and people[7].money.bank == 1300,
        'H3 (a): Pay again refused, no second pay')

    -- (b) the department withdrawal raised after it took the money and the balance can not be read: no telling, the
    -- row stays at 'withdrawing' (H8: 'review' is only the officer's deposit) and Pay again is refused (never a second
    -- withdrawal)
    Reset()
    Config.Cash.source = 'society'
    local sast0 = bank.balance.sast
    CP.Banking.withdrawSociety = function(account, amount)
        bank.balance[account] = bank.balance[account] - amount
        bank.log[#bank.log + 1] = { kind = 'withdraw', account = account, amount = amount }
        error('cut')
    end
    local realBal = CP.Banking.societyBalance
    CP.Banking.societyBalance = function() return nil end
    local idB = Row({ status = 'pending', owed = 200 })
    H.eq(Async(function() return Cash.pay(idB) end), 'paying', 'H3 (b): a raised withdrawal stays paying')
    CP.Banking.withdrawSociety, CP.Banking.societyBalance = realWithdraw, realBal
    H.eq(RowOf(idB).bd.cash.step, 'withdrawing', 'H3 (b): at step withdrawing (H8)')
    ok, e = Resolve(idB, 'payAgain', '200')
    H.ok(not ok and e == 'err.payment_step_unknown' and #Logged('withdraw') == 1 and #calls.add == 0,
        'H3 (b): Pay again is refused, no second withdrawal: ' .. tostring(e))
    H.eq(bank.balance.sast, sast0 - 200, 'H3 (b): the department paid once')
    -- a cut inside a department call leaves its intent marker: Pay again refuses each of them (H8: 'adding' and
    -- 'review', the officer's deposit, are paid with the checked box: section 19)
    for _, step in ipairs({ 'withdrawing', 'refunding' }) do
        local idS = Row({
            status = 'paying',
            owed = 100,
            cash = { step = step, source = 'society', societyAccount = 'sast', payAmount = 100 },
        })
        Reset()
        ok, e = Resolve(idS, 'payAgain', '100')
        H.ok(not ok and e == 'err.payment_step_unknown' and #bank.log == 0 and #calls.add == 0,
            'H3: Pay again at step ' .. step .. ' is refused: ' .. tostring(e))
    end
    Config.Cash.source = 'server'

    -- (c) clawback of a society-source row, the give-back fails: owed on the row, listed, retried later
    Reset()
    people[7].money.bank = 1000
    local idC = Row({
        status = 'paid',
        owed = 300,
        paid = 300,
        cash = { source = 'society', societyAccount = 'sast', account = 'bank' },
    })
    CP.Banking.depositSociety = function() return false end
    Pay._resetNav()
    local n0 = Pay.stuckCount()
    ok, e = Act('server:admin:clawback', 1,
        { rowId = idC, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    H.ok(ok and e.refunded == false and people[7].money.bank == 900, 'H3 (c): taken back, the give-back failed')
    local c = RowOf(idC).bd.cash
    H.ok(c.giveBack == 'owed' and c.backOwed == 100 and c.backAccount == 'sast' and c.backs == 1,
        'H3 (c): the give-back is owed on the row')
    local s = Stuck(idC)
    H.ok(s and s.kind == 'giveBack' and s.followUpAmount == 100, 'H3 (c): listed in stuckPayments as a give-back')
    Pay._resetNav()
    H.eq(Pay.stuckCount(), n0 + 1, 'H3 (c): and counted in the Payments badge')
    H.eq(Async(function() return Call(Cash, 'retryGiveBacks') end), 0, 'H3 (c): the retry fails while banking refuses')
    H.eq(RowOf(idC).bd.cash.giveBack, 'owed', 'H3 (c): still owed')
    CP.Banking.depositSociety = realDeposit
    sast0 = bank.balance.sast
    H.eq(Async(function() return Call(Cash, 'retryGiveBacks') end), 1, 'H3 (c): the retry gives it back')
    c = RowOf(idC).bd.cash
    H.ok(bank.balance.sast == sast0 + 100 and c.giveBack == 'back' and c.backOwed == 0 and c.backGiven == 100,
        'H3 (c): cut taken equals cut returned')
    H.eq(Stuck(idC), nil, 'H3 (c): no longer listed')
    -- a give-back left for staff: Retry give-back in Payments asks for the amount
    CP.Banking.depositSociety = function() return false end
    ok = Act('server:admin:clawback', 1, { rowId = idC, amount = 50, reason = 'x', confirm = '50', requestId = Rid() })
    CP.Banking.depositSociety = realDeposit
    local chk = Cb('admin:checkBankingTxn', 1, { rowId = idC })
    H.ok(ok and chk and chk.followUp == 'giveBack' and chk.followUpAmount == 50 and (chk.outcomes or {}).giveBack,
        'H3 (c): Resolve shows the give-back and its outcomes')
    ok, e = Resolve(idC, 'giveBack', '5')
    H.ok(not ok and e == 'err.confirm_mismatch', 'H3 (c): Retry give-back asks for the amount')
    sast0 = bank.balance.sast
    ok, e = Resolve(idC, 'giveBack', '50')
    H.ok(ok and bank.balance.sast == sast0 + 50 and RowOf(idC).bd.cash.giveBack == 'back',
        'H3 (c): Retry give-back gives it back: ' .. tostring(e))
    H.ok((LastAudit('paymentResolve') or {}).new_value == 'giveBack:50', 'H3 (c): audited')

    -- (d) RemoveMoney takes the money, then raises: the balance shows it was taken, the clawback completes
    Reset()
    people[7].money.bank = 1000
    CP.Qbx.removeMoney = function(src, account, amount)
        calls.remove[#calls.remove + 1] = { src = src, account = account, amount = amount }
        people[src].money[account] = people[src].money[account] - amount
        return false, 'error'
    end
    local idD = Row({
        status = 'paid',
        owed = 300,
        paid = 300,
        cash = { source = 'society', societyAccount = 'sast', account = 'bank' },
    })
    sast0 = bank.balance.sast
    ok, e = Act('server:admin:clawback', 1,
        { rowId = idD, amount = 100, reason = 'x', confirm = '100', requestId = Rid() })
    c = RowOf(idD).bd.cash
    H.ok(
        ok and e.refunded == true and people[7].money.bank == 900 and bank.balance.sast == sast0 + 100 and c.backs == 1
            and c.backPending == nil,
        'H3 (d): a raise after the money was taken: taken back and given back'
    )
    H.ok(#Logged('entry', { side = 'personal', type = 'withdraw' }) == 1, 'H3 (d): with the withdraw history entry')
    -- no telling (no balance): the claim stays held for staff, listed; Resolve "taken" or "not taken"
    CP.Qbx.getMoney = function(src, account)
        if calls.remove[1] then return nil end
        return realGet(src, account)
    end
    calls.remove = {}
    ok, e = Act('server:admin:clawback', 1,
        { rowId = idD, amount = 50, reason = 'x', confirm = '50', requestId = Rid() })
    CP.Qbx.getMoney, CP.Qbx.removeMoney = realGet, realRemove
    c = RowOf(idD).bd.cash
    H.ok(
        not ok and e == 'err.payment_raised' and c.backPending == 50 and c.backStep == 'removing'
            and RowOf(idD).cash_reclaimed == 150,
        'H3 (d): no telling: held for staff'
    )
    s = Stuck(idD)
    H.ok(s and s.kind == 'back' and s.followUpAmount == 50, 'H3 (d): listed as a clawback')
    ok, e = Act('server:admin:clawback', 1,
        { rowId = idD, amount = 10, reason = 'x', confirm = '10', requestId = Rid() })
    H.ok(not ok and e == 'err.payment_in_flight', 'H3 (d): no new clawback while one is held')
    sast0 = bank.balance.sast
    ok, e = Resolve(idD, 'backTaken')
    c = RowOf(idD).bd.cash
    H.ok(
        ok and c.backs == 2 and c.backPending == nil and bank.balance.sast == sast0 + 50
            and RowOf(idD).cash_reclaimed == 150,
        'H3 (d): Resolve "taken": recorded and given back: ' .. tostring(e)
    )
    -- "not taken" takes the claim back
    CP.Qbx.removeMoney = function(src, account, amount)
        calls.remove[#calls.remove + 1] = { src = src, account = account, amount = amount }
        return false, 'error'
    end
    CP.Qbx.getMoney = function(src, account)
        if calls.remove[1] then return nil end
        return realGet(src, account)
    end
    calls.remove = {}
    Act('server:admin:clawback', 1, { rowId = idD, amount = 20, reason = 'x', confirm = '20', requestId = Rid() })
    CP.Qbx.getMoney, CP.Qbx.removeMoney = realGet, realRemove
    ok, e = Resolve(idD, 'backUndone')
    H.ok(ok and RowOf(idD).cash_reclaimed == 150 and RowOf(idD).bd.cash.backPending == nil,
        'H3 (d): Resolve "not taken": the claim is taken back: ' .. tostring(e))

    -- (e) Pay the rest: AddMoney raised with no telling: listed as a rest, Release refused, Mark the rest paid
    Reset()
    local idE = Row({ status = 'capped', owed = 500, paid = 300 })
    CP.Qbx.addMoney = function() return false, 'error' end
    CP.Qbx.getMoney = function() return nil end
    ok, e = Act('server:admin:payCapRest', 1, { rowId = idE, reason = 'x', confirm = '200', requestId = Rid() })
    CP.Qbx.addMoney, CP.Qbx.getMoney = realAdd, realGet
    c = RowOf(idE).bd.cash
    H.ok(not ok and e == 'err.payment_raised' and c.restPaid == 'paying' and c.restPaidStep == 'review',
        'H3 (e): the rest at step review')
    s = Stuck(idE)
    H.ok(s and s.kind == 'rest' and s.followUpAmount == 200, 'H3 (e): listed as a rest')
    local chkE = Cb('admin:checkBankingTxn', 1, { rowId = idE })
    H.ok(
        chkE and chkE.followUp == 'rest' and (chkE.outcomes or {}).restPaid == true
            and (chkE.outcomes or {}).restRelease == true,
        'H3 (e): at review the admin decides: Mark the rest paid or Release'
    )
    H.sql([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.restPaidStep', 'added') WHERE id = ?]],
        { idE })
    ok, e = Resolve(idE, 'restRelease')
    H.ok(not ok and e == 'err.payment_step_unknown', 'H3 (e): Release refused once the rest reached the officer')
    ok, e = Resolve(idE, 'restPaid')
    H.ok(ok and RowOf(idE).cash_paid == 500 and RowOf(idE).bd.cash.restPaid == 'paid' and #calls.add == 0,
        'H3 (e): Mark the rest paid moves no money: ' .. tostring(e))
    -- the department paid, the officer did not, the refund failed: at 'withdrawn'; Release gives it back first
    Reset()
    Config.Cash.source = 'society'
    local idE2 = Row({ status = 'capped', owed = 500, paid = 300 })
    addResult = false
    CP.Banking.depositSociety = function() return false end
    ok, e = Act('server:admin:payCapRest', 1, { rowId = idE2, reason = 'x', confirm = '200', requestId = Rid() })
    CP.Banking.depositSociety = realDeposit
    addResult = true
    c = RowOf(idE2).bd.cash
    H.ok(not ok and e == 'err.payment_refund_failed' and c.restPaidStep == 'withdrawn' and c.restPaidAccount == 'sast',
        'H3 (e): the rest at step withdrawn')
    sast0 = bank.balance.sast
    ok, e = Resolve(idE2, 'restRelease')
    H.ok(ok and bank.balance.sast == sast0 + 200 and RowOf(idE2).bd.cash.restPaid == nil,
        'H3 (e): Release gives the department its $200 back and frees the rest: ' .. tostring(e))
    ok = Act('server:admin:payCapRest', 1, { rowId = idE2, reason = 'x', confirm = '200', requestId = Rid() })
    H.ok(ok == true and RowOf(idE2).cash_paid == 500, 'H3 (e): Pay the rest can be used again')
    -- a claim cut before any money moved is released at the start
    local idE3 = Row({ status = 'capped', owed = 500, paid = 300 })
    H.sql([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.restPaid', 'paying',
        '$.cash.restPaidClaim', 1) WHERE id = ?]], { idE3 })
    H.eq(Async(function() return Call(Cash, '_releaseUnstarted') end), 1,
        'H3 (e): the start-up release frees a claim cut before money')
    H.eq(RowOf(idE3).bd.cash.restPaid, nil, 'H3 (e): ...so Pay the rest works again')

    -- (f) Pay again: the department paid, the deposit was refused and the refund failed: Pay again resumes with the
    -- deposit only (no second withdrawal)
    Reset()
    local idF = Row({
        status = 'paying',
        owed = 250,
        cash = { step = 'claimed', source = 'society', societyAccount = 'sast', payAmount = 250 },
    })
    addResult = false
    CP.Banking.depositSociety = function() return false end
    ok, e = Resolve(idF, 'payAgain', '250')
    CP.Banking.depositSociety = realDeposit
    addResult = true
    c = RowOf(idF).bd.cash
    H.ok(not ok and e == 'err.payment_refund_failed' and c.again == 'paying' and c.againStep == 'withdrawn',
        'H3 (f): Pay again left at withdrawn')
    Reset()
    people[7].money.bank = 1000
    ok, e = Resolve(idF, 'payAgain', '250')
    H.ok(ok and #Logged('withdraw') == 0 and people[7].money.bank == 1250 and RowOf(idF).cash_status == 'paid',
        'H3 (f): the resumed Pay again deposits only: ' .. tostring(e))
    H.ok((LastAudit('paymentPayAgain') or {}).new_value == '250:resume', 'H3 (f): audited as a resume')
    H.eq(#Logged('entry', { side = 'society', type = 'withdraw' }), 1,
        'H3 (f): the department\'s history entry is written')

    -- (g) Pay now, Forfeit now, Cancel payment: a failed audit row changes nothing (audit first)
    Reset()
    local Kit = CP.AdminKit
    local realAudit = Kit.auditSync
    Kit.auditSync = function() return nil end
    local idG = Row({ status = 'pending', owed = 90 })
    ok, e = Act('server:admin:payNow', 1, { rowId = idG, requestId = Rid() })
    H.ok(not ok and e == 'err.audit_failed' and #calls.add == 0 and RowOf(idG).cash_status == 'pending',
        'H3 (g): Pay now with no audit row pays nothing: ' .. tostring(e))
    ok, e = Act('server:admin:retryPending', 1, { requestId = Rid() })
    H.ok(not ok and e == 'err.audit_failed' and #calls.add == 0, 'H3 (g): Retry all pending neither')
    ok, e = Act('server:admin:cancelPayment', 1, { rowId = idG, reason = 'x', confirm = '90', requestId = Rid() })
    H.ok(not ok and e == 'err.audit_failed' and RowOf(idG).cash_status == 'pending', 'H3 (g): Cancel payment neither')
    local idG2 = Row({ status = 'pending', owed = 40, voided = true })
    ok, e = Act('server:admin:forfeitNow', 1, { rowId = idG2, reason = 'x', requestId = Rid() })
    H.ok(not ok and e == 'err.audit_failed' and RowOf(idG2).cash_status == 'pending', 'H3 (g): Forfeit now neither')
    Kit.auditSync = realAudit
    ok = Act('server:admin:payNow', 1, { rowId = idG, requestId = Rid() })
    local rows = H.sql(
        'SELECT old_value, new_value FROM cp_audit WHERE action = \'paymentRetry\' ORDER BY id DESC LIMIT 2')
    H.ok(ok and rows[2] and rows[2].new_value == 'paying' and rows[1].new_value == 'paid',
        'H3 (g): Pay now: the intent row, then the outcome row')

    -- (h) Add funds: a funding row cut before its deposit is failed at the start; the deposit marks 'depositing'
    H.sql('DELETE FROM cp_dept_funding')
    H.sql([[INSERT INTO cp_dept_funding (department, amount, txn, state, by_actor, reason, created_at)
        VALUES ('sast', 100, 'CP-FUND-1', 'pending', 'x', 'x', FROM_UNIXTIME(?))]], { H.time - 600 })
    H.eq(Async(function() return Call(Pay, '_failUnstartedFunding') end), 1,
        'H3 (h): a pending funding row cut before the deposit')
    H.eq(H.sql('SELECT state FROM cp_dept_funding')[1].state, 'failed', 'H3 (h): ...is failed')

    Config.Cash.allowPayAgain, Config.Cash.allowClawback, Config.Cash.allowCapTopUp = false, false, false
    Config.Cash.source = 'server'
    Reset()
end

-- ============================================================================
--                                    19. H8
-- ============================================================================
-- A REFUND WITH NO TELLING, PAY AGAIN AFTER A CUT DEPOSIT, OLD CLAIMS.

do
    Reset()
    H.sql('DELETE FROM cp_mission_runs')
    Config.Cash.allowPayAgain, Config.Cash.allowClawback, Config.Cash.allowCapTopUp = true, true, true
    Config.Cash.source = 'society'
    local realDeposit, realBal, realGet = CP.Banking.depositSociety, CP.Banking.societyBalance, CP.Qbx.getMoney
    local function Resolve(id, outcome, confirm, checked)
        return Act('server:admin:resolvePayment', 1, {
            rowId = id,
            outcome = outcome,
            checked = checked ~= false,
            reason = 'H8',
            confirm = confirm,
            requestId = Rid(),
        })
    end
    -- the department's refund arrives, then raises, and its balance can not be read: no telling
    local function UnknownRefund()
        CP.Banking.depositSociety = function(a, n)
            bank.balance[a] = bank.balance[a] + n
            return false, 'error'
        end
        CP.Banking.societyBalance = function() return nil end
    end
    local function Restore() CP.Banking.depositSociety, CP.Banking.societyBalance = realDeposit, realBal end

    -- (A) Pay the rest at 'withdrawn'; Release's refund has no telling: it stays at 'refunding', a second Release
    -- only releases (the department is never given the rest back twice)
    local idA = Row({ status = 'capped', owed = 500, paid = 300 })
    addResult = false
    CP.Banking.depositSociety = function() return false end
    Act('server:admin:payCapRest', 1, { rowId = idA, reason = 'x', confirm = '200', requestId = Rid() })
    Restore()
    addResult = true
    H.eq(RowOf(idA).bd.cash.restPaidStep, 'withdrawn', 'H8 (A): the rest at step withdrawn')
    local sast0 = bank.balance.sast
    UnknownRefund()
    local ok, e = Resolve(idA, 'restRelease')
    Restore()
    H.ok(not ok and e == 'err.payment_raised' and RowOf(idA).bd.cash.restPaidStep == 'refunding',
        'H8 (A): a refund with no telling stays at refunding: ' .. tostring(e))
    ok, e = Resolve(idA, 'restRelease')
    H.ok(ok and RowOf(idA).bd.cash.restPaid == nil, 'H8 (A): the second Release only releases: ' .. tostring(e))
    H.eq(bank.balance.sast - sast0, 200, 'H8 (A): the department got back $200 once, for the $200 it paid')

    -- (B) Pay again: the deposit refused, the refund with no telling: 'refunding', never resumed as a deposit only
    Reset()
    people[7].money.bank = 1000
    local idB = Row({
        status = 'paying',
        owed = 250,
        cash = { step = 'claimed', source = 'society', societyAccount = 'sast', payAmount = 250 },
    })
    local s0 = bank.balance.sast
    addResult = false
    UnknownRefund()
    ok, e = Resolve(idB, 'payAgain', '250')
    Restore()
    addResult = true
    H.ok(not ok and e == 'err.payment_raised' and RowOf(idB).bd.cash.againStep == 'refunding',
        'H8 (B): Pay again left at refunding: ' .. tostring(e))
    Reset()
    ok, e = Resolve(idB, 'payAgain', '250')
    H.ok(not ok and people[7].money.bank == 1000 and #calls.add == 0,
        'H8 (B): no deposit-only resume after a refund with no telling: ' .. tostring(e))
    H.eq(bank.balance.sast - s0, 0, 'H8 (B): the department paid and got it back: net $0')

    -- (C) a payment: the deposit refused, the refund with no telling: step 'refunding', Pay again refused
    Reset()
    people[7].money.bank = 1000
    local idC = Row({ status = 'pending', owed = 300 })
    local s1 = bank.balance.sast
    addResult = false
    UnknownRefund()
    local stC = Async(function() return Cash.pay(idC) end)
    Restore()
    addResult = true
    H.ok(stC == 'paying' and RowOf(idC).bd.cash.step == 'refunding',
        'H8 (C): the payment stays at refunding: ' .. tostring(stC) .. ' ' .. tostring(RowOf(idC).bd.cash.step))
    Reset()
    ok, e = Resolve(idC, 'payAgain', '300')
    H.ok(not ok and e == 'err.payment_step_unknown' and people[7].money.bank == 1000 and #calls.add == 0,
        'H8 (C): Pay again refused, no deposit-only pay: ' .. tostring(e))
    H.eq(bank.balance.sast - s1, 0, 'H8 (C): the department net $0')

    -- Pay again after the officer's deposit was cut ('adding') or raised with no telling ('review'): with the checked
    -- box it deposits once, never a second department withdrawal; without it, refused
    for _, step in ipairs({ 'adding', 'review' }) do
        Reset()
        people[7].money.bank = 1000
        local id = Row({
            status = 'paying',
            owed = 150,
            cash = { step = step, source = 'society', societyAccount = 'sast', payAmount = 150 },
        })
        local d0 = bank.balance.sast
        local okN, eN = Async(function() return Cash.payAgain(id) end)
        H.ok(not okN and eN == 'err.payment_step_unknown' and #calls.add == 0,
            'H8: Pay again at ' .. step .. ' without the checked box is refused: ' .. tostring(eN))
        ok, e = Resolve(id, 'payAgain', '150', false)
        H.ok(not ok and e == 'err.check_first', 'H8: and through the Payments screen too: ' .. tostring(e))
        ok, e = Resolve(id, 'payAgain', '150')
        H.ok(ok and people[7].money.bank == 1150 and RowOf(id).cash_status == 'paid',
            'H8: Pay again at ' .. step .. ' with the checked box pays once: ' .. tostring(e))
        H.ok(#Logged('withdraw') == 0 and bank.balance.sast == d0,
            'H8: ...and the department is not debited a second time')
        ok = Resolve(id, 'payAgain', '150')
        H.ok(not ok and people[7].money.bank == 1150, 'H8: ...and never twice')
    end
    -- a server-paid row cut at 'adding' is paid once too
    Reset()
    people[7].money.bank = 1000
    local idS = Row({ status = 'paying', owed = 120, cash = { step = 'adding', source = 'server', payAmount = 120 } })
    ok, e = Resolve(idS, 'payAgain', '120')
    H.ok(ok and people[7].money.bank == 1120 and #Logged('withdraw') == 0,
        'H8: a server-paid row at adding: ' .. tostring(e))

    -- the start-up release: a claim from before the step markers (no step, no tag) may have moved money and is left
    -- for Resolve; a claim of this build (tagged) cut before its first money call is still released
    Reset()
    local idL = Row({ status = 'capped', owed = 500, paid = 300 })
    H.sql([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.restPaid', 'paying') WHERE id = ?]],
        { idL })
    local idL2 = Row({ status = 'paying', owed = 100, cash = { step = 'claimed', source = 'server', payAmount = 100 } })
    H.sql([[UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.cash.again', 'paying') WHERE id = ?]],
        { idL2 })
    local idN = Row({ status = 'capped', owed = 500, paid = 300 })
    local cut = false
    CreateThread(function()
        Cash.payCapRest(idN, function()
            cut = true
            Wait(1e12)   -- the server stops here: claimed, no money call yet
        end)
    end)
    H.ok(cut and RowOf(idN).bd.cash.restPaid == 'paying' and RowOf(idN).bd.cash.restPaidClaim ~= nil,
        'H8: a new claim carries its tag')
    H.eq(Async(function() return Cash._releaseUnstarted() end), 1, 'H8: the start-up release frees only the new claim')
    H.eq(RowOf(idN).bd.cash.restPaid, nil, 'H8: the new claim cut before money is released')
    H.eq(RowOf(idL).bd.cash.restPaid, 'paying', 'H8: an old Pay the rest claim is left for Resolve')
    H.eq(RowOf(idL2).bd.cash.again, 'paying', 'H8: an old Pay again claim is left too')
    ok, e = Resolve(idL, 'restRelease')
    H.ok(ok and RowOf(idL).bd.cash.restPaid == nil, 'H8: Resolve releases the old claim: ' .. tostring(e))

    CP.Qbx.getMoney = realGet
    Config.Cash.allowPayAgain, Config.Cash.allowClawback, Config.Cash.allowCapTopUp = false, false, false
    Config.Cash.source = 'server'
    Reset()
end

-- ============================================================================
--                     17. THE DISPUTE WINDOW STANDS STILL
-- ============================================================================
-- SUSPENSION, MAINTENANCE LOCK.

do
    Reset()
    H.load('modules/review/disputes.lua')
    local D = CP.Disputes
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_disputes')
    local T0, HR = H.time, 3600
    local function Eligible(id, cid, at)
        local r = H.sql(
            [[SELECT citizenid, mission_type, state, flagged, voided, UNIX_TIMESTAMP(created_at) AS created_ts,
            (SELECT UNIX_TIMESTAMP(o.suspended_until) FROM cp_officers o WHERE o.citizenid = r.citizenid) AS suspended_ts,
            (SELECT UNIX_TIMESTAMP(o.suspended_from) FROM cp_officers o WHERE o.citizenid = r.citizenid)
                AS suspended_from_ts
            FROM cp_mission_runs r WHERE id = ?]], { id })[1]
        return (D.eligible(r, cid, at))
    end
    local function Forfeit() return Async(function() return Cash._forfeitureJob() end) end

    -- voided, then suspended for 7 days at once (the third void): 49 h on, still held, and the whole window after
    H.sql('INSERT INTO cp_officers (citizenid, department) VALUES (\'HOLD0001\', \'sast\')')
    local v = Row({ cid = 'HOLD0001', status = 'held', owed = 50, voided = true })
    H.ok(Async(function() return CP.Access.suspend('HOLD0001', 7, 0, 'auto') end), 'suspended for 7 days')
    H.time = T0 + 49 * HR
    Forfeit()
    H.eq(RowOf(v).cash_status, 'held', 'suspended: the voided row is not forfeited when the 48 h end')
    H.time = T0 + 72 * HR
    H.ok(Async(function() return CP.Access.suspend('HOLD0001', 0, 0, 'lifted') end), 'lifted on day 3')
    H.eq(Eligible(v, 'HOLD0001', T0 + 72 * HR + 47 * HR), true, 'a dispute may be filed until 48 h after the lift')
    H.eq(Eligible(v, 'HOLD0001', T0 + 72 * HR + 49 * HR), false, 'and not after')
    H.time = T0 + 72 * HR + 47 * HR
    Forfeit()
    H.eq(RowOf(v).cash_status, 'held', 'still held inside the window after the lift')
    H.time = T0 + 72 * HR + 49 * HR
    Forfeit()
    H.eq(RowOf(v).cash_status, 'forfeited', 'forfeited once that window ends')

    -- a maintenance lock 40 h after the void, ended by a restart at 50 h: the 8 h left come after it
    H.time = T0 + 200 * HR
    local T1 = H.time
    local w = Row({ status = 'held', owed = 50, voided = true })
    H.time = T1 + 40 * HR
    Maint.begin('restore', { by = 'test' })
    H.time = T1 + 50 * HR
    Kit._reset()          -- the restart: nothing in memory
    Maint.settleHold()    -- the start took no lock
    Forfeit()
    H.eq(RowOf(w).cash_status, 'held', 'the lock held the window: not forfeited at the restart')
    H.eq(Eligible(w, 'OFF00007', T1 + 57 * HR), true, 'a dispute may be filed until 58 h (the 10 h lock added)')
    Kit._reset()          -- a second restart adds nothing
    Maint.settleHold()
    H.eq(Eligible(w, 'OFF00007', T1 + 57 * HR), true, 'a second restart keeps the same end')
    H.eq(Eligible(w, 'OFF00007', T1 + 59 * HR), false, 'and extends nothing')
    H.time = T1 + 59 * HR
    Forfeit()
    H.eq(RowOf(w).cash_status, 'forfeited', 'forfeited after the moved end')

    -- H8: a suspension that starts after a run's window closed never reopens it (D.eligible and the forfeiture SQL
    -- read when the suspension started, cp_officers.suspended_from)
    local T2 = T0 + 400 * HR
    H.time = T2
    H.sql('INSERT INTO cp_officers (citizenid, department) VALUES (\'HOLD0009\', \'sast\')')
    local f = Row({ cid = 'HOLD0009', status = 'none', owed = 0 })
    H.sql('UPDATE cp_mission_runs SET state = \'failed\' WHERE id = ?', { f })
    local v2 = Row({ cid = 'HOLD0009', status = 'held', owed = 50, voided = true })
    local v3 = Row({ cid = 'HOLD0009', status = 'held', owed = 50, voided = true })
    H.eq(Eligible(f, 'HOLD0009', T2 + 49 * HR), false, 'H8: the failed run closes after 48 h')
    H.time = T2 + 49 * HR
    Forfeit()
    H.eq(RowOf(v2).cash_status, 'forfeited', 'H8: and the voided run is forfeited then')
    H.sql('UPDATE cp_mission_runs SET cash_status = \'held\' WHERE id = ?', { v3 })   -- held by hand (no job ran)
    H.time = T2 + 30 * 24 * HR
    H.ok(Async(function() return CP.Access.suspend('HOLD0009', 1, 0, 'x') end), 'H8: suspended a month later')
    H.time = T2 + 31 * 24 * HR + HR
    H.eq(Eligible(f, 'HOLD0009', H.time), false, 'H8: a month-old failed run stays closed after a later suspension')
    H.eq(Eligible(v2, 'HOLD0009', H.time), false, 'H8: a forfeited month-old voided run stays closed')
    Forfeit()
    H.eq(RowOf(v3).cash_status, 'forfeited', 'H8: the forfeiture job does not hold a month-old row either')
    -- a second suspension given inside the windows the first one held keeps its start (the hold goes on)
    H.time = T2 + 40 * 24 * HR
    local g = Row({ cid = 'HOLD0009', status = 'held', owed = 50, voided = true })
    H.time = H.time + HR
    H.ok(Async(function() return CP.Access.suspend('HOLD0009', 1, 0, 'x') end), 'H8: suspended in its window')
    local from1 = Count('SELECT UNIX_TIMESTAMP(suspended_from) FROM cp_officers WHERE citizenid = \'HOLD0009\'')
    H.eq(from1, H.time, 'H8: a suspension given 9 days after the last one ended starts now')
    H.time = H.time + 24 * HR + 10 * HR
    H.ok(Async(function() return CP.Access.suspend('HOLD0009', 1, 0, 'x') end), 'H8: suspended again 10 h after')
    H.eq(Count('SELECT UNIX_TIMESTAMP(suspended_from) FROM cp_officers WHERE citizenid = \'HOLD0009\''), from1,
        'H8: the second suspension keeps the first one\'s start')
    H.eq(Eligible(g, 'HOLD0009', H.time + 24 * HR + 47 * HR), true, 'H8: so the run stays open 48 h after it')

    -- H8: filing through server:dispute (ROW_SQL reads the suspension): open until 48 h after the lift, not after
    H.time = T0 + 2000 * HR
    local T3 = H.time
    H.sql('DELETE FROM cp_disputes')
    local a = Row({ cid = 'OFF00008', dept = 'fib', status = 'held', owed = 50, voided = true })
    local b = Row({ cid = 'OFF00008', dept = 'fib', status = 'held', owed = 50, voided = true })
    H.time = T3 + HR
    H.ok(Async(function() return CP.Access.suspend('OFF00008', 7, 0, 'auto') end), 'H8: OFF00008 suspended')
    H.time = T3 + 72 * HR
    H.ok(Async(function() return CP.Access.suspend('OFF00008', 0, 0, 'lifted') end), 'H8: and lifted on day 3')
    H.time = T3 + 72 * HR + 47 * HR
    local okD, eD = Act('server:dispute', 8, { rowId = a, reason = 'x', requestId = Rid() })
    H.ok(okD == true, 'H8: a dispute filed 47 h after the lift is taken: ' .. tostring(eD))
    H.time = T3 + 72 * HR + 49 * HR
    okD, eD = Act('server:dispute', 8, { rowId = b, reason = 'x', requestId = Rid() })
    H.ok(not okD and eD == 'err.dispute_window', 'H8: one filed 49 h after it is refused: ' .. tostring(eD))

    -- H8: migration 019 fills suspended_from for the suspensions given before it: the last 'suspend' audit row up to
    -- their end (so one lifted just before the update still holds its windows), else now for one still running
    do
        local f19 = io.open('Crimson-Police/sql/migrations/019_suspension_start.sql', 'r')
        local text = f19 and f19:read('a') or ''
        if f19 then f19:close() end
        text = text:gsub('%-%-[^\n]*', '')
        local fill = text:match('(UPDATE cp_officers.-);')
        H.ok(fill ~= nil, 'H8: 019 has its fill statement')
        H.time = T0 + 3000 * HR
        local now = H.time
        H.sql([[INSERT INTO cp_officers (citizenid, department, suspended_until) VALUES
            ('BACK0001', 'sast', FROM_UNIXTIME(?)), ('BACK0002', 'sast', FROM_UNIXTIME(?)),
            ('BACK0003', 'sast', FROM_UNIXTIME(?))]], { now - 10 * HR, now + 24 * HR, now - 900 * HR })
        H.sql([[INSERT INTO cp_audit (actor, role, action, target, created_at)
            VALUES ('console', 'console', 'suspend', 'BACK0001', FROM_UNIXTIME(?)),
                   ('console', 'console', 'suspend', 'BACK0001', FROM_UNIXTIME(?))]], { now - 900 * HR, now - 80 * HR })
        if fill then H.sql(fill) end
        local function From(cid)
            return Count(
                ('SELECT UNIX_TIMESTAMP(suspended_from) FROM cp_officers WHERE citizenid = \'%s\''):format(cid))
        end
        H.eq(From('BACK0001'), now - 80 * HR, 'H8: 019: a suspension lifted before the update starts at its audit row')
        H.eq(From('BACK0002'), now, 'H8: 019: a running one with no audit row starts at the update')
        H.eq(From('BACK0003'), 0, 'H8: 019: one that ended long ago with no audit row stays empty')
        H.sql('DELETE FROM cp_audit WHERE target LIKE \'BACK%\'')
    end
    H.time = T0
end

_G.print = realPrint
return H
