-- The crash matrix of the server's own money journeys: each journey cut by a `restart Crimson-Police`

-- The crash matrix of the server's own money journeys: each journey cut by a `restart Crimson-Police`
-- after every database await of it, then the server starts again, its start-up catch-ups run, the officer logs in
-- again, and the journey must have recovered: paid at most once (or left 'paying' for an admin's Resolve in
-- Payments), the run ended at most once, nothing pending that her login does not pay, no payment lock held, and the
-- officer can take a mission again. tests/race_spec.lua cuts the client actions the same way; this spec cuts what
-- the server does by itself. docs/dev/TESTING.md "Crash matrix".
--   1. A Beat Patrol ends and pays: the last checkpoint, the run's end, its row, the payout (CP.Money, banking).
--   2. Her login pays a pending payment (CP.Cash.payPending after Qbox's player loaded).
--   3-6. (H3) A feature reward, Pay again, a clawback and Pay the rest, with the society source on: the money must add
--      up after every cut (the department's debits minus refunds = what reached her; taken back = given back).
-- A journey with more than CP_CRASH_SAMPLE cut points (default 40) is cut at that many spread over it;
-- CP_CRASH_ALL=1 cuts it after every await. Runs on the world of tests/workflows_full_spec.lua (the saves folder, as
-- shipped; in the database suite the same as there).

_G.CP_WF_WORLD = 'crash'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID = W.H, W.CID
local Secs, Act = W.Secs, W.Act

local SAMPLE = os.getenv('CP_CRASH_ALL') == '1' and math.huge
    or math.max(2, tonumber(os.getenv('CP_CRASH_SAMPLE') or '') or 40)
local OFFICER = 1
local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }

local function Later() H.time = H.time + 3700 end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
end
local function Draw(src)
    Later()
    Leave(src)
    local saved = Config.DisabledMissions
    local list = {}
    for _, id in ipairs(saved or {}) do list[#list + 1] = id end
    for _, id in ipairs(PATROL_OTHERS) do list[#list + 1] = id end
    Config.DisabledMissions = list
    local ok, data = Act('server:acceptType', src, 'patrol')
    Config.DisabledMissions = saved
    return ok, data, CP.Runs.getBySrc(src)
end

-- every Wait(0): with H.interleave(true) each database await of the resource is one
local yields = 0
local function CountingWait()
    local inner = _G.Wait
    _G.Wait = function(ms)
        if ms == 0 then yields = yields + 1 end
        return inner(ms)
    end
    return function() _G.Wait = inner end
end

-- Steps with no game time passing, one await a step, until nothing yields any more: the step after which the last
-- await of the journey ran.
local STEP_MAX = 600
local function StepOut()
    local last, n = 0, 0
    for i = 1, STEP_MAX do
        local before = yields
        H.step(0)
        if yields > before then last = i end
        n = i
        if i - last > 20 then break end
    end
    return last, n
end

-- `restart Crimson-Police` right now: the copy waiting for its query never resumes, what it wrote stays
local function CutRestart()
    H.interleave(false)
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    W.Boot()
    Secs(5)
end

-- The cut points: every step up to SAMPLE of them, else SAMPLE spread from the first to the last.
local function Points(steps)
    local out, seen = {}, {}
    local n = math.min(steps, SAMPLE)
    for i = 1, n do
        local at = steps <= SAMPLE and i or math.max(1, math.floor((i - 1) * (steps - 1) / (n - 1) + 1.5))
        if not seen[at] then
            seen[at] = true
            out[#out + 1] = at
        end
    end
    return out
end

local function Rows(sql, params) return W.Rows(sql, params) end
local function PaidN(cid) return (W.Paid(cid)) end

-- What every cut must leave: rows of the run (at most one), payments to her (at most one), and a state that is either
-- settled or visible to an admin.
local function Recovered(label, cid, rowOf, paid0)
    -- the start-up catch-ups, then her login (payPending) and its delay
    Secs(130)
    W.Drop(OFFICER)
    W.Reconnect(OFFICER)
    Secs(15)
    local rows = rowOf()
    local paid = PaidN(cid) - paid0
    H.ok(#rows <= 1, ('%s: the run ended at most once (%d rows)'):format(label, #rows))
    H.ok(paid <= 1, ('%s: paid at most once (%d payments)'):format(label, paid))
    local row = rows[1]
    if row then
        local st = row.cash_status
        local okState = (st == 'paid' and paid == 1) or (st == 'paying' and paid <= 1) or (st == 'capped' and paid <= 1)
            or (st == 'none' and paid == 0)
        H.ok(okState,
            ('%s: the payment is settled or waits for an admin (status %s, %d paid)'):format(label, tostring(st), paid))
        if CP.Cash and CP.Cash.rowBusy then
            H.eq(CP.Cash.rowBusy(math.floor(tonumber(row.id) or 0), cid), false, label .. ': no payment lock held')
        end
    else
        H.eq(paid, 0, label .. ': no row, nothing paid')
    end
    -- she can take a mission again
    local ok, why = Draw(OFFICER)
    H.eq(ok, true, label .. ': she can take a mission again: ' .. tostring(why))
    Leave(OFFICER)
    Secs(5)
end

local results = {}

-- ============================================================================
--                        1. A BEAT PATROL ENDS AND PAYS
-- ============================================================================
-- Driven to its last checkpoint; the cut comes after the n-th await that the last checkpoint sets off (the run's
-- end, the row, the payout).

local function ToLastCheckpoint()
    local ok, why, run = Draw(OFFICER)
    H.eq(ok, true, 'patrol: she accepts Beat Patrol: ' .. tostring(why))
    if not ok or not run then return nil end
    local veh = W.TakeWheel(OFFICER, run)
    local n = #run.objectives[1].state.points
    W.DriveCheckpoints(OFFICER, run, veh, 1, n - 1)
    Secs(15)
    W.Place(OFFICER, run.objectives[1].state.points[n])
    W.ents[veh].coords = H.players[OFFICER].coords
    Secs(10)
    return run, veh, n
end

do
    local cid = CID[OFFICER]
    -- alone: the journey's awaits
    local run, veh, n = ToLastCheckpoint()
    local steps = 0
    if run then
        local paid0 = PaidN(cid)
        H.interleave(true)
        yields = 0
        local undo = CountingWait()
        W.Objective(OFFICER, run, 1, W.CheckpointEv(n, veh))
        steps = StepOut()
        undo()
        H.interleave(false)
        Secs(10)
        local rows = Rows('run_uuid = ?', { run.id })
        H.eq(#rows, 1, 'patrol alone: the run ended with its row')
        H.eq(rows[1] and rows[1].cash_status, 'paid', 'patrol alone: paid')
        H.eq(PaidN(cid) - paid0, 1, 'patrol alone: once')
        H.ok(steps > 3, ('patrol alone: the end runs through the database (%d awaits)'):format(steps))
        Leave(OFFICER)
    end
    local cuts = 0
    for _, at in ipairs(Points(steps)) do
        local r, v, k = ToLastCheckpoint()
        if not r then break end
        local paid0 = PaidN(cid)
        local uuid = r.id
        H.interleave(true)
        W.Objective(OFFICER, r, 1, W.CheckpointEv(k, v))
        for _ = 2, at do H.step(0) end
        CutRestart()
        Recovered(('patrol cut after await %d of %d'):format(at, steps), cid, function()
            return Rows('run_uuid = ?', { uuid })
        end, paid0)
        cuts = cuts + 1
    end
    results[#results + 1] = ('a Beat Patrol ends and pays: %d awaits, %d cuts'):format(steps, cuts)
end

-- ============================================================================
--                     2. HER LOGIN PAYS A PENDING PAYMENT
-- ============================================================================
-- A pending payment row (Qbox refused it earlier); she logs in; the cut comes after the n-th await of the pay.

local function PendingRow(cid)
    local owed = 240
    local uuid = ('%08x-0000-4000-8000-%012x'):format(math.random(0, 0x7fffffff), 77)
    local bd = {
        missionLabel = 'Beat Patrol',
        cash = { B = owed, mTier = 1.0, mMod = 1.0, amount = owed, status = 'pending' },
    }
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_reclaimed, cash_status, breakdown,
        flagged, voided, created_at) VALUES (?, 'patrol', 'beat_patrol', ?, 'sast', 'completed', 'completed', 60, 60, ?,
        1.00, 0, 0, 'pending', ?, 0, 0, FROM_UNIXTIME(?))]],
        { uuid, cid, owed, require('cjson').encode(bd), H.time - 60 })
    return uuid
end

-- Her login (Qbox's player loaded); the pay waits PENDING_DELAY_MS (5 s) first: game time goes on in 100 ms steps
-- until its first await, so the awaits after it are stepped one at a time.
local function Login()
    W.Reconnect(OFFICER)
    local before = yields
    for _ = 1, 100 do
        H.step(100)
        if yields > before then return true end
    end
    return false
end

do
    local cid = CID[OFFICER]
    W.Drop(OFFICER)
    local uuid = PendingRow(cid)
    local paid0 = PaidN(cid)
    H.interleave(true)
    yields = 0
    local undo = CountingWait()
    local started = Login()
    local steps = started and (StepOut() + 1) or 0
    undo()
    H.interleave(false)
    Secs(5)
    local row = Rows('run_uuid = ?', { uuid })[1]
    H.eq(row and row.cash_status, 'paid', 'login alone: her pending payment is paid')
    H.eq(PaidN(cid) - paid0, 1, 'login alone: once')
    H.ok(steps > 3, ('login alone: the pay runs through the database (%d awaits)'):format(steps))
    local cuts = 0
    for _, at in ipairs(Points(steps)) do
        Later()
        W.Drop(OFFICER)
        local u = PendingRow(cid)
        local p0 = PaidN(cid)
        H.interleave(true)
        local undoC = CountingWait()
        Login()
        undoC()
        for _ = 2, at do H.step(0) end
        CutRestart()
        Recovered(('login pay cut after await %d of %d'):format(at, steps), cid, function()
            return Rows('run_uuid = ?', { u })
        end, p0)
        cuts = cuts + 1
    end
    results[#results + 1] = ('her login pays a pending payment: %d awaits, %d cuts'):format(steps, cuts)
end

-- ============================================================================
--             3-6. H3: A FEATURE REWARD AND THE ADMIN MONEY TOOLS
-- ============================================================================
-- With the society source on (the department pays, Renewed-Banking's account below keeps its balance) and the money
-- tools switched on: a feature reward (FR.pay), Pay again of a stuck payment, a clawback of a society-paid row and Pay
-- the rest of a capped row, each cut after every await. After the restart and her login the money must add up:
--   * the department's debits minus what it got back equal what reached the officer (cut taken = cut returned)
--   * a clawback: what was taken from her equals what the row holds as taken back, and the department got back (or is
--     owed on the row) exactly that
--   * never paid twice; every row settled or listed for an admin (CP.Cash.stuckPayments)

local cjson = require('cjson')
local soc = { bal = 1000000, out = 0, back = 0 }
local taken = 0
local function Wire()
    local RB = H.exportsMock['Renewed-Banking']
    RB.getAccountMoney = function() return soc.bal end
    RB.removeAccountMoney = function(_, amount)
        if soc.bal < amount then return false end
        soc.bal, soc.out = soc.bal - amount, soc.out + amount
        return true
    end
    RB.addAccountMoney = function(_, amount)
        soc.bal, soc.back = soc.bal + amount, soc.back + amount
        return true
    end
    local Q = H.exportsMock.qbx_core
    if not Q._h3 then
        local realGet = Q.GetPlayer
        Q.GetPlayer = function(src)
            local p = realGet(src)
            if p then
                local pd = p.PlayerData
                pd.money = pd.money or { bank = 100000, cash = 0 }
                local add = p.Functions.AddMoney
                p.Functions.AddMoney = function(account, amount, reason)
                    pd.money[account] = (pd.money[account] or 0) + amount
                    return add(account, amount, reason)
                end
                p.Functions.RemoveMoney = function(account, amount)
                    if (pd.money[account] or 0) < amount then return false end
                    pd.money[account] = pd.money[account] - amount
                    taken = taken + amount
                    return true
                end
            end
            return p
        end
        Q._h3 = true
    end
end
Wire()
local function CutRestartH3()
    CutRestart()
    Wire()
end

local ADMIN = 5
for _, path in ipairs({ 'Cash.allowPayAgain', 'Cash.allowClawback', 'Cash.allowCapTopUp' }) do
    local ok, err = Act('server:admin:setSetting', ADMIN,
        { path = path, json = 'true', reason = 'H3', confirm = 'ENABLE' })
    H.eq(ok, true, 'H3 switches: ' .. path .. ': ' .. tostring(err))
end
local okS, errS = Act('server:admin:setSetting', ADMIN, { path = 'Cash.source', json = '"society"', reason = 'H3' })
H.eq(okS, true, 'H3: the society source: ' .. tostring(errS))
for _, f in ipairs({ 'FeatureRewards.surrender.enabled' }) do
    local ok, err = Act('server:admin:setSetting', ADMIN, { path = f, json = 'true', reason = 'H3' })
    H.eq(ok, true, 'H3: ' .. f .. ': ' .. tostring(err))
end

local seq = 0
local function Uuid()
    seq = seq + 1
    return ('%08x-3333-4000-8000-%012x'):format(math.random(0, 0x7fffffff), seq)
end
local function MoneyRow(o)
    local uuid = Uuid()
    local c = { B = o.owed, mTier = 1.0, mMod = 1.0, amount = o.owed, status = o.status, account = 'bank' }
    for k, v in pairs(o.cash or {}) do c[k] = v end
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_reclaimed, cash_status, breakdown,
        flagged, voided, created_at) VALUES (?, 'patrol', 'beat_patrol', ?, 'sast', 'completed', 'completed', 60, 60, ?,
        1.00, ?, 0, ?, ?, 0, 0, FROM_UNIXTIME(?))]], {
        uuid,
        CID[OFFICER],
        o.owed,
        o.paid or 0,
        o.status,
        cjson.encode({ missionLabel = 'Beat Patrol', cash = c }),
        H.time - 60,
    })
    return uuid
end
local function RowByUuid(uuid)
    local r = H.sql([[SELECT id, cash_status, cash_paid, cash_reclaimed, breakdown FROM cp_mission_runs
        WHERE run_uuid = ?]], { uuid })[1]
    if r then
        r.id = math.floor(tonumber(r.id) or 0)
        r.cash = (type(r.breakdown) == 'string' and cjson.decode(r.breakdown) or r.breakdown or {}).cash or {}
    end
    return r
end
local function Listed(id)
    for _, s in ipairs(CP.Cash.stuckPayments() or {}) do if s.id == id then return s end end
    return nil
end
local function Snap()
    return {
        credited = select(2, W.Paid(CID[OFFICER])),
        n = (W.Paid(CID[OFFICER])),
        out = soc.out,
        back = soc.back,
        taken = taken,
    }
end
local function Delta(a, b)
    local d = {}
    for k, v in pairs(b) do d[k] = v - (a[k] or 0) end
    return d
end
local rid = 0
local function Send(name, payload)
    rid = rid + 1
    H.fire('crimson-police:' .. name, ADMIN, payload, 'h3cm' .. rid)
end

-- The money check after a cut (and her login): what the department paid out minus what it got back is what reached
-- her (payments), or, for a clawback, what was taken from her is what the row holds and the department got back or is
-- owed. A row left part way is listed for an admin.
local function Invariants(label, uuid, d, kind)
    local r = RowByUuid(uuid)
    H.ok(d.n <= 1, ('%s: paid at most once (%d deposits)'):format(label, d.n))
    if kind == 'pay' then
        -- or the department paid and she did not get it yet: then the row says so (its step marker) and is listed
        local gap = d.out - d.back - d.credited
        local c = r and r.cash or {}
        local step = c.restPaid == 'paying' and c.restPaidStep or c.again == 'paying' and c.againStep or c.step
        local said = r
            and (step == 'withdrawing' or step == 'withdrawn' or step == 'adding' or step == 'review' or step == 'refunding')
            and Listed(r.id) ~= nil
        H.ok(gap == 0 or (gap > 0 and said), (
            '%s: the department paid what reached her, or the row says it paid and waits for an admin (paid %d, got '
            .. 'back %d, she got %d, step %s)'
        ):format(label, d.out, d.back, d.credited, tostring(step)))
    elseif kind == 'back' then
        local reclaimed = r and math.floor(tonumber(r.cash_reclaimed) or 0) or 0
        local held = r and math.floor(tonumber(r.cash.backPending) or 0) or 0
        local owed = r and r.cash.giveBack ~= 'back' and math.floor(tonumber(r.cash.backOwed) or 0) or 0
        H.ok(d.taken == reclaimed - held or (held > 0 and (d.taken == reclaimed or d.taken == reclaimed - held)),
            ('%s: taken from her (%d) matches the row (%d taken back, %d held)'):format(label, d.taken, reclaimed, held))
        H.ok(d.back + owed == d.taken or (r and r.cash.giveBack == 'paying') or held > 0,
            ('%s: the department got back (%d) or is owed (%d) what was taken (%d)'):format(label, d.back, owed,
                d.taken))
        H.eq(d.out, 0, label .. ': no department withdrawal')
    end
    if r then
        -- (the follow-up markers read here, not through CP.Cash.followUpOf, so the old code fails instead of stopping)
        local c = r.cash
        local left = r.cash_status == 'paying' or c.restPaid == 'paying' or c.backPending ~= nil or c.giveBack == 'owed'
            or c.giveBack == 'paying'
        if left then
            local s = Listed(r.id)
            H.ok(s ~= nil, ('%s: the row left part way is listed for an admin (%s %s)'):format(label, r.cash_status,
                tostring(s and s.kind)))
        end
        H.ok(not (r.cash.again == 'paying' and r.cash.againStep == nil), label .. ': no Pay again claim left unstarted')
        H.ok(not (r.cash.restPaid == 'paying' and r.cash.restPaidStep == nil),
            label .. ': no Pay the rest claim left unstarted')
        H.ok(r.cash.backStep ~= 'claimed', label .. ': no clawback claim left unstarted')
    end
end

-- One journey: set up, then alone (its awaits), then cut after each.
local function Journey(j)
    local function Once(cutAt)
        Later()
        local ctx = j.setup()
        Secs(2)
        local s0 = Snap()
        H.interleave(true)
        if not cutAt then
            yields = 0
            local undo = CountingWait()
            j.fire(ctx)
            local steps = StepOut()
            undo()
            H.interleave(false)
            Secs(10)
            j.alone(ctx, Delta(s0, Snap()))
            return steps
        end
        j.fire(ctx)
        for _ = 2, cutAt do H.step(0) end
        CutRestartH3()
        local label = ('%s cut after await %d'):format(j.label, cutAt)
        -- the start-up catch-ups (the 15 s sweep, the give-back retry), then her login and its pay
        Secs(130)
        W.Drop(OFFICER)
        W.Reconnect(OFFICER)
        Secs(15)
        Invariants(label, ctx.uuid, Delta(s0, Snap()), j.kind)
        if j.after then j.after(ctx, label, Delta(s0, Snap())) end
    end
    local steps = Once(nil)
    local cuts = 0
    for _, at in ipairs(Points(steps)) do
        Once(at)
        cuts = cuts + 1
    end
    results[#results + 1] = ('%s: %d awaits, %d cuts'):format(j.label, steps, cuts)
end

-- 3. a feature reward (Talk them down), society source: the suspect's reward is new money, an officer's is the
-- department's
Journey({
    label = 'a feature reward',
    kind = 'pay',
    setup = function()
        local key = Uuid()
        return { key = key, uuid = CP.FeatureRewards.uuidOf('surrender', key, CID[OFFICER]) }
    end,
    fire = function(ctx)
        CreateThread(function() CP.FeatureRewards.pay('surrender', CID[OFFICER], { key = ctx.key }) end)
    end,
    alone = function(ctx, d)
        local r = RowByUuid(ctx.uuid)
        H.eq(r and r.cash_status, 'paid', 'feature reward alone: paid')
        H.eq(d.n, 1, 'feature reward alone: once')
    end,
    after = function(ctx, label, d)
        local r = RowByUuid(ctx.uuid)
        if r then
            H.ok((r.cash_status == 'paid' and d.n == 1) or r.cash_status == 'paying',
                ('%s: a written reward is paid once after her login, or waits for an admin (%s, %d paid)'):format(label,
                    r.cash_status, d.n))
        else
            H.eq(d.n, 0, label .. ': no row, nothing paid')
        end
    end,
})

-- 4. Pay again of a payment stuck at 'claimed' (nothing moved): the department pays, the officer gets it, once
Journey({
    label = 'Pay again',
    kind = 'pay',
    setup = function()
        local uuid = MoneyRow({
            status = 'paying',
            owed = 200,
            cash = { step = 'claimed', source = 'society', societyAccount = 'sast', payAmount = 200 },
        })
        return { uuid = uuid, id = RowByUuid(uuid).id }
    end,
    fire = function(ctx)
        Send('server:admin:resolvePayment',
            { rowId = ctx.id, outcome = 'payAgain', checked = true, reason = 'H3', confirm = '200', requestId = Uuid() })
    end,
    alone = function(ctx, d)
        H.eq(RowByUuid(ctx.uuid).cash_status, 'paid', 'Pay again alone: paid')
        H.ok(d.n == 1 and d.out == 200 and d.back == 0, 'Pay again alone: once, from the department')
    end,
})

-- 5. a clawback of a society-paid row: taken from her, given back to the department
Journey({
    label = 'a clawback',
    kind = 'back',
    setup = function()
        local uuid = MoneyRow({
            status = 'paid',
            owed = 300,
            paid = 300,
            cash = { source = 'society', societyAccount = 'sast', step = 'added' },
        })
        return { uuid = uuid, id = RowByUuid(uuid).id }
    end,
    fire = function(ctx)
        Send('server:admin:clawback',
            { rowId = ctx.id, amount = 100, reason = 'H3', confirm = '100', requestId = Uuid() })
    end,
    alone = function(ctx, d)
        local r = RowByUuid(ctx.uuid)
        H.ok(r.cash_reclaimed == 100 and d.taken == 100 and d.back == 100 and r.cash.giveBack == 'back',
            'clawback alone: taken back and given back: ' .. cjson.encode(r.cash))
    end,
})

-- 6. Pay the rest of a capped row: the department pays the rest, the officer gets it, once
Journey({
    label = 'Pay the rest',
    kind = 'pay',
    setup = function()
        local uuid = MoneyRow({
            status = 'capped',
            owed = 500,
            paid = 300,
            cash = { source = 'society', societyAccount = 'sast', step = 'added' },
        })
        return { uuid = uuid, id = RowByUuid(uuid).id }
    end,
    fire = function(ctx)
        Send('server:admin:payCapRest', { rowId = ctx.id, reason = 'H3', confirm = '200', requestId = Uuid() })
    end,
    alone = function(ctx, d)
        local r = RowByUuid(ctx.uuid)
        H.ok(r.cash_paid == 500 and d.n == 1 and d.out == 200, 'Pay the rest alone: once, from the department')
    end,
})

for _, line in ipairs(results) do print('REPORT crash ' .. line) end

return H
