-- Full admin control, economy (P4): the payments ledger, resolving stuck payments, pay now and retries, the money
-- tools that ship off, payout unlock and Adjust all, the archive and forfeiture jobs under the busy lock,
-- maintenance, the clean-up and the cash health lines.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: shared/*, modules/permissions, access, admin, adminkit, confighealth, settings, tablet, cash, payouts,
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
H.load('modules/integrations/renewed_banking/server.lua')
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
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/confighealth/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/cash/server.lua',
    'modules/payouts/server.lua',
    'modules/payments/server.lua',
    'modules/schedule/server.lua',
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

    -- AddMoney raised after the society paid: the row stays paying at step 'withdrawn'
    addResult, addWhy = false, 'error'
    local id2 = Row({ status = 'pending', owed = 300 })
    H.eq(Async(function() return Cash.pay(id2) end), 'paying', 'a raise in AddMoney leaves the row paying')
    H.eq(RowOf(id2).bd.cash.step, 'withdrawn', 'step marker: the department already paid')
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

    local x = Cb('admin:exportPayments', 1, { department = 'fib' })
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
    local pv = Cb('admin:previewRetryUnfunded', 1, { department = 'sast' })
    H.ok(pv and pv.effect.count == 2 and pv.effect.total == 500, 'the preview: rows and total (voided rows left out)')
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
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'OFF00007', amount = 800, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.manual_limit', 'the per-admin daily limit, counted from today\'s rows')
    ok = Act('server:admin:manualCash', 3, { citizenid = 'OFF00007', amount = 800, reason = 'x', requestId = Rid() })
    H.eq(ok, true, 'another admin has a limit of their own')
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'ADM00001', amount = 10, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.self_target', 'never to the admin\'s own character')
    ok, e = Act('server:admin:manualCash', 1, { citizenid = 'NOBODY99', amount = 10, reason = 'x', requestId = Rid() })
    H.eq(e, 'err.unknown_officer', 'only an officer Crimson-Police knows')
    H.ok(LastAudit('manualCash') ~= nil, 'audited')
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
    H.ok(ok and seen and seen.state == 'pending' and seen.txn == e.txn,
        'the funding row is written before the deposit: ' .. tostring(not ok and e))
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
end

-- ============================================================================
--                                 16. CLEAN-UP
-- ============================================================================

do
    local d, e = Cb('admin:getCleanup', 2, {})
    H.eq(e, 'err.no_permission', 'admins only')
    H.sql(
        'INSERT INTO cp_admin_requests (request_id, action, actor, created_at) VALUES (?, \'x\', \'y\', FROM_UNIXTIME(?))',
        { 'ffffffff-0000-4000-8000-000000000001', H.time - 8 * 86400 })
    Kit.lock('job', { kind = 'bulkVoid' })
    local ok
    ok, e = Act('server:admin:runCleanupNow', 1, { reason = 'test' })
    H.ok(not ok and e == 'err.admin_busy', 'Run now is refused while a long job runs')
    Kit.unlock('job')
    ok, e = Act('server:admin:runCleanupNow', 2, { reason = 'test' })
    H.eq(e, 'err.no_permission', 'a supervisor can\'t run it')
    ok, d = Act('server:admin:runCleanupNow', 1, { reason = 'test' })
    H.ok(ok and d.last and d.last.requestsDeleted >= 1 and d.last.by == 'ADM00001', 'Run now: the result is kept')
    H.ok(LastAudit('cleanupRun') ~= nil, 'audited')
    d = Cb('admin:getCleanup', 1, {})
    H.ok(d and d.last and d.nextRunAt > H.time and d.requestDays == 7, 'admin:getCleanup: last run and next run')
    ok, e = Act('server:admin:runCleanupNow', 3, { reason = 'again' })
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

_G.print = realPrint
return H
