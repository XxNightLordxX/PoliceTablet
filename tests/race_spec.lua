-- WF6C: every action that writes, sent twice at the same moment (the owner: "do extensive workflow testing on
-- everything").

-- WF6C: every action that writes, sent twice at the same moment (the owner: "do extensive workflow testing on
-- everything").
-- The world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the owner's scripts
-- running, the saves folder; CP_WF_STORAGE=database runs it on MariaDB) with a second SAST supervisor (8) and a second
-- admin (9). Every action that writes (money, points, caps, bans, grants, settings, review decisions, restores, runs,
-- calls, units, tours) is sent by two players (or twice by one, a double click) at the same moment with the harness's
-- yield control on (H.interleave: every query yields, as oxmysql's await does in game, so the two run turn by turn).
-- Each case runs three ways on the same starting state (its set-up builds it again each time):
--   alone     one copy: what one action does (the effect: money paid, rows, XP, ...) and how many queries it yields
--   at once   two copies: the effect is one action's per copy that succeeded, never more (exactly one wins where only
--             one may, both are correct where both may), and the replies say which
--   cut       the first copy is cut by `restart Crimson-Police` after each of its queries (1 to n), then the second is
--             sent: never a double effect, and every part of the effect moves together (no half-done action)
-- The shipped config first where the action is on there, then every switch on through Settings.

_G.CP_WF_WORLD = 'race'
_G.CP_WF_STORAGE = os.getenv('CP_WF_STORAGE')
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Act, Cb, Secs, Setting = W.Act, W.Cb, W.Secs, W.Setting
local cjson = require('cjson')

-- the error lines (CP.err prints '^1[crimson-police:<tag>]')
local errorLines = {}
do
    local inner = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if line:find('^%^1%[crimson%-police') then errorLines[#errorLines + 1] = line end
        return inner(...)
    end
end

-- the gaps of the test world the soak fills too (tests/soak_spec.lua): ox_inventory's item hook, Qbox's GetMetadata and
-- the city's own players, users, player_vehicles and mdt_dispatch tables (the database is dropped at the end)
H.exportsMock.ox_inventory.registerHook = function() return 1 end
H.exportsMock.ox_inventory.removeHooks = function() end
H.exportsMock.qbx_core.GetMetadata = function(src, key)
    local pd = type(src) == 'number' and PD[src]
    if not pd then return false end
    return pd.metadata[key]
end
local function Mysql(sql) os.execute(('mysql -uroot %s -e "%s"'):format(H.db, sql)) end
os.execute(('mysql -uroot -e "CREATE DATABASE IF NOT EXISTS %s"'):format(H.db))
Mysql(
    'DROP TABLE IF EXISTS mdt_dispatch, player_vehicles, players, users; '
        .. 'CREATE TABLE users (license VARCHAR(64), license2 VARCHAR(64)); '
        .. 'CREATE TABLE mdt_dispatch (id INT PRIMARY KEY, unique_id VARCHAR(64), priority INT, active TINYINT); '
        .. 'CREATE TABLE player_vehicles (plate VARCHAR(16)); '
        .. 'CREATE TABLE players (citizenid VARCHAR(50) PRIMARY KEY, license VARCHAR(64), charinfo TEXT)'
)
local function AddCharacter(src)
    local pd = PD[src]
    Mysql(('INSERT INTO players VALUES (\'%s\', \'%s\', \'%s\')'):format(
        pd.citizenid,
        pd.license,
        cjson.encode(pd.charinfo):gsub('"', '\\"')
    ) .. ('; INSERT INTO users VALUES (\'%s\', NULL)'):format(pd.license))
end

-- bank balances and Qbox's RemoveMoney (an admin's clawback); taken[citizenid] adds up what was taken
local taken = {}
do
    local realGet = H.exportsMock.qbx_core.GetPlayer
    H.exportsMock.qbx_core.GetPlayer = function(src)
        local p = realGet(src)
        if p then
            local pd = p.PlayerData
            pd.money = pd.money or { bank = 100000, cash = 0 }
            p.Functions.RemoveMoney = function(account, amount)
                if (pd.money[account] or 0) < amount then return false end
                pd.money[account] = pd.money[account] - amount
                taken[pd.citizenid] = (taken[pd.citizenid] or 0) + amount
                return true
            end
        end
        return p
    end
end

-- a second SAST supervisor (8) and a second admin (9, a Qbox admin)
W.AddPlayer(8, 'WFRACSU8', 'Max', 'Sarge', 'sast', 3)
W.AddPlayer(9, 'WFRACAD9', 'Quinn', 'Boxer', 'unemployed', 0)
for _, src in ipairs({ 8, 9 }) do
    CID[src] = PD[src].citizenid
    H.players[src].coords = vec3(0.0, 0.0, 0.0)
    W.Reconnect(src)
end
H.players[9].ace.admin = true
for src = 1, 9 do AddCharacter(src) end
for src = 1, 9 do W.Place(src, vec3(-300.0 + src * 2.0, -1400.0, 30.0)) end
-- every officer has opened his tablet once (his officer row)
for _, src in ipairs({ 1, 2, 6, 7 }) do Cb('getSession', src, { ui = 'officer', via = 'command' }) end

-- ============================================================================
--                                   SENDING
-- ============================================================================

local n = 0
local function Uuid()
    n = n + 1
    return ('%08x-0000-4000-8000-%012x'):format(n, 6003)
end

-- One copy of an action sent now: its reply id.
local function Send(c)
    n = n + 1
    local id = 'race' .. n
    local payload = c.payload
    if type(payload) == 'function' then payload = payload() end
    H.fire('crimson-police:' .. c.name, c.src, payload, id)
    return id
end
local function Reply(id)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then
            return { ok = e.args[2], data = e.args[3] }
        end
    end
end
local function WaitReplies(ids, ms)
    local waited = 0
    while waited < (ms or 30000) do
        local all = true
        for _, id in ipairs(ids) do if not Reply(id) then all = false end end
        if all then return end
        W.Adv(50, 50)
        waited = waited + 50
    end
end

-- Yields of one copy alone (H.interleave counts them through a Wait spy).
local yields = 0
local function CountingWait()
    local inner = _G.Wait
    _G.Wait = function(ms)
        if ms == 0 then yields = yields + 1 end
        return inner(ms)
    end
    return function() _G.Wait = inner end
end

-- `restart Crimson-Police` right now: the copy that is waiting for its query never resumes (FXServer ends the
-- resource's threads), what it wrote stays.
local function CutRestart()
    H.interleave(false)
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    W.Boot()
    Secs(5)
end

-- ============================================================================
--                                  THE CASES
-- ============================================================================
-- A case: { name, a = { name, src, payload }, b = { ... }, setup(), effect() -> { key = number }, one = true (only
-- one copy may act: a claim, a repeat of one request id), cut = false (no cut runs), check(ra, rb) -> ok, why }

local function Delta(before, after)
    local d = {}
    for k, v in pairs(after) do d[k] = v - (before[k] or 0) end
    return d
end
local function Show(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. '=' .. tostring(t[k]) end
    return '{' .. table.concat(parts, ' ') .. '}'
end
local function ShowReply(r) return r and (tostring(r.ok) .. ' ' .. tostring(r.data)) or 'no reply' end
-- k: how many copies acted, the same for every part of the effect (nil: the parts disagree, a half-done action)
-- lag: parts that a cut may leave behind (0 to k times; a pay claimed but cut before the money moved, which an admin
-- resolves in Payments)
local function Times(single, delta, lag)
    local k
    for key, one in pairs(single) do
        if lag and lag[key] then goto continue end
        local d = delta[key] or 0
        local kk
        if one == 0 then
            if d ~= 0 then return nil end
        else
            kk = d / one
            if kk ~= math.floor(kk) then return nil end
            if k ~= nil and kk ~= k then return nil end
            k = kk
        end
        ::continue::
    end
    for key, d in pairs(delta) do
        if single[key] == nil and d ~= 0 then return nil end
    end
    k = k or 0
    for key in pairs(lag or {}) do
        local d, one = delta[key] or 0, single[key] or 0
        if d < math.min(0, one * k) or d > math.max(0, one * k) then return nil end
    end
    return k
end

local results = {}
-- cut points per case (CP_RACE_CUTS=n: more; every query of the first copy when it has no more than that)
local CUTS = math.max(2, tonumber(os.getenv('CP_RACE_CUTS') or '') or 5)

-- A restore (and its maintenance lock) goes on after its reply, and a finished one asks for `restart Crimson-Police`
-- and keeps the lock until then: wait until the lock is gone, else restart as the admin is asked to.
local function Locked() return CP.Maintenance and CP.Maintenance.active and CP.Maintenance.active() ~= nil end
local function Settle()
    for _ = 1, 30 do
        if not Locked() then return end
        Secs(1)
    end
    W.Restart()
    H.ok(not Locked(), 'the restart the restore asked for ends its lock')
end

local function RunCase(c)
    local label = c.label
    Secs(11)
    -- alone
    c.setup()
    Secs(2)
    local before = c.effect()
    H.interleave(true)
    yields = 0
    local undo = CountingWait()
    local ida = Send(c.a)
    WaitReplies({ ida })
    undo()
    H.interleave(false)
    local ra = Reply(ida)
    local single = Delta(before, c.effect())
    local steps = yields
    H.ok(ra and ra.ok == true, label .. ': alone, it succeeds: ' .. ShowReply(ra))
    local acted = false
    for _, v in pairs(single) do if v ~= 0 then acted = true end end
    H.ok(acted, label .. ': alone, it has an effect ' .. Show(single))
    -- at once
    Secs(11)
    Settle()
    c.setup()
    Secs(2)
    before = c.effect()
    H.interleave(true)
    local i1 = Send(c.a)
    local i2 = Send(c.b)
    WaitReplies({ i1, i2 })
    H.interleave(false)
    local r1, r2 = Reply(i1), Reply(i2)
    local delta = Delta(before, c.effect())
    local k = Times(single, delta)
    local oks = ((r1 and r1.ok) and 1 or 0) + ((r2 and r2.ok) and 1 or 0)
    local why = ('%s | %s | alone %s, both %s'):format(ShowReply(r1), ShowReply(r2), Show(single), Show(delta))
    if os.getenv('CP_RACE_DEBUG') then W.realPrint('AT ONCE ' .. label .. ': ' .. why) end
    if c.one then
        H.ok(k == 1, label .. ': at once, exactly one acts: ' .. why)
    else
        H.ok(k ~= nil and k >= 1 and k <= 2, label .. ': at once, each copy whole or not at all: ' .. why)
        H.ok(k == nil or k <= oks, label .. ': at once, no copy acts without saying so: ' .. why)
    end
    if c.check then
        local okC, whyC = c.check(r1, r2)
        H.ok(okC, label .. ': at once: ' .. tostring(whyC) .. ' | ' .. why)
    end
    H.ok(r1 ~= nil and r2 ~= nil, label .. ': at once, both copies answer: ' .. why)
    -- the sender of the first copy drops in the middle of it and comes back; then the second copy
    Secs(11)
    Settle()
    c.setup()
    Secs(2)
    before = c.effect()
    H.interleave(true)
    i1 = Send(c.a)
    H.step(0)
    H.interleave(false)
    W.Drop(c.a.src)
    W.Reconnect(c.a.src)
    i2 = Send(c.b)
    WaitReplies({ i2 })
    delta = Delta(before, c.effect())
    k = Times(single, delta, c.lag)
    why = ('%s | %s | alone %s, now %s'):format(ShowReply(Reply(i1)), ShowReply(Reply(i2)), Show(single), Show(delta))
    H.ok(k ~= nil and k <= (c.one and 1 or 2),
        label .. ': a drop and reconnect in the middle, no double or half ' .. 'effect: ' .. why)
    -- both under the maintenance lock (a restore): both refused, nothing changes
    if c.maintenance ~= false then
        Secs(11)
        Settle()
        c.setup()
        Secs(2)
        before = c.effect()
        local okM = CP.Maintenance.begin('restore', { by = 'WF6C' })
        H.interleave(true)
        i1 = Send(c.a)
        i2 = Send(c.b)
        WaitReplies({ i1, i2 })
        H.interleave(false)
        -- measured before the lock ends (then the payments it held back are paid)
        delta = Delta(before, c.effect())
        CP.Maintenance.finish('restore')
        r1, r2 = Reply(i1), Reply(i2)
        why = ('%s | %s | now %s'):format(ShowReply(r1), ShowReply(r2), Show(delta))
        -- (a second copy from the same player may meet his rate limit first)
        local function Refused(r)
            return r and r.ok == false and (r.data == 'err.maintenance' or r.data == 'err.rate_limited')
        end
        H.ok(okM and Times(single, delta) == 0 and r1 and r1.data == 'err.maintenance' and Refused(r2),
            label .. ': under the maintenance lock both are refused: ' .. why)
    end
    -- cut by a restart after each query of the first copy, then the second sent
    local cuts = 0
    if c.cut ~= false then
        -- every query up to CUTS of them, else CUTS spread from the first to the last
        local max = c.maxCuts or CUTS
        local points, seen = {}, {}
        for i = 1, math.min(steps, max) do
            local at = steps <= max and i or math.max(1, math.floor((i - 1) * (steps - 1) / (max - 1) + 1.5))
            if not seen[at] then
                seen[at] = true
                points[#points + 1] = at
            end
        end
        for _, at in ipairs(points) do
            Secs(11)
            Settle()
            c.setup()
            Secs(2)
            before = c.effect()
            H.interleave(true)
            Send(c.a)
            for _ = 2, at do H.step(0) end
            CutRestart()
            if c.afterRestart then c.afterRestart() end
            local ib = Send(c.b)
            WaitReplies({ ib })
            local rb = Reply(ib)
            delta = Delta(before, c.effect())
            k = Times(single, delta, c.lag)
            local whyCut = ('cut after query %d: %s | alone %s, now %s'):format(at, ShowReply(rb), Show(single),
                Show(delta))
            H.ok(k ~= nil and k <= (c.one and 1 or 2), label .. ': no double or half effect, ' .. whyCut)
            cuts = cuts + 1
        end
    end
    Settle()
    if c.teardown then c.teardown() end
    results[#results + 1] = ('%s: %d queries, %d cuts'):format(label, steps, cuts)
end

-- ============================================================================
--                                 THE HELPERS
-- ============================================================================

local function Count(sql, params) return W.Count(sql, params) end
local function Sum(sql, params) return tonumber((H.sql(sql, params)[1] or {}).n) or 0 end
local function Paid(cid) local _, amount = W.Paid(cid); return amount end
local function Xp(cid) return W.Xp(cid) end
local function NewDay()
    local d = os.date('*t', H.time + 86400)
    H.time = os.time({ year = d.year, month = d.month, day = d.day, hour = 14, min = 0, sec = 0 })
    Secs(5)
end
local function Row(o)
    local owed = o.owed or 500
    local bd = {
        missionLabel = 'Beat Patrol',
        cash = { B = owed, mTier = 1.0, mMod = 1.0, amount = owed, status = o.status or 'pending' },
    }
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_reclaimed, cash_status, breakdown,
        flagged, voided, created_at) VALUES (?, 'patrol', 'beat_patrol', ?, ?, 'completed', 'completed', 60, 60, ?, 1.00, ?, 0,
        ?, ?, ?, 0, FROM_UNIXTIME(?))]], {
        Uuid(),
        o.cid,
        o.dept or 'sast',
        owed,
        o.paid or 0,
        o.status or 'pending',
        cjson.encode(bd),
        o.flagged and 1 or 0,
        H.time - 60,
    })
    return Count('SELECT MAX(id) AS n FROM cp_mission_runs')
end
-- 1 when the row's pay was claimed: paid, capped, or 'paying' (a pay cut off part way waits for an admin's Resolve
-- in Payments: it is never paid again on its own)
local function Claimed(id)
    return Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ?
        AND cash_status IN ('paid', 'capped', 'paying')]], { id })
end

-- the voids of these cases add up for one officer: his automatic suspension (Config.AdminControl) is lifted first
local function Unsuspend(cid)
    if CP.AdminKit and CP.AdminKit.dailyCount then
        Act('server:restriction', 5, { op = 'lift', kind = 'suspension', citizenid = cid, reason = 'WF6C' })
    end
end

local CASES = {}
local function Case(c) CASES[#CASES + 1] = c end

-- ---------------------------------------------------------------------------- money
local cur = {}
Case({
    label = 'manual cash, one request sent twice (a double click)',
    switches = true,
    one = true,
    setup = function() cur.rid = Uuid() end,
    effect = function() return { cash = Paid(CID[6]) } end,
    a = {
        name = 'server:admin:manualCash',
        src = 5,
        payload = function()
            return { citizenid = CID[6], amount = 250, reason = 'WF6C', requestId = cur.rid }
        end,
    },
    b = {
        name = 'server:admin:manualCash',
        src = 5,
        payload = function()
            return { citizenid = CID[6], amount = 250, reason = 'WF6C', requestId = cur.rid }
        end,
    },
})
Case({
    label = 'manual cash, two admins to one officer',
    switches = true,
    setup = function() end,
    effect = function() return { cash = Paid(CID[7]) } end,
    a = {
        name = 'server:admin:manualCash',
        src = 5,
        payload = function()
            return { citizenid = CID[7], amount = 300, reason = 'WF6C', requestId = Uuid() }
        end,
    },
    b = {
        name = 'server:admin:manualCash',
        src = 9,
        payload = function()
            return { citizenid = CID[7], amount = 300, reason = 'WF6C', requestId = Uuid() }
        end,
    },
})
Case({
    label = 'Add funds, one request sent twice',
    switches = true,
    one = true,
    setup = function() cur.rid = Uuid() end,
    effect = function()
        return { funds = Sum('SELECT COALESCE(SUM(amount), 0) AS n FROM cp_dept_funding WHERE department = \'sast\'') }
    end,
    a = {
        name = 'server:admin:addDepartmentFunds',
        src = 5,
        payload = function()
            return { department = 'sast', amount = 1000, reason = 'WF6C', confirm = '1000', requestId = cur.rid }
        end,
    },
    b = {
        name = 'server:admin:addDepartmentFunds',
        src = 5,
        payload = function()
            return { department = 'sast', amount = 1000, reason = 'WF6C', confirm = '1000', requestId = cur.rid }
        end,
    },
})
Case({
    label = 'Pay now, two admins on one pending payment',
    one = true,
    setup = function() cur.row = Row({ cid = CID[6], owed = 420 }) end,
    effect = function() return { cash = Paid(CID[6]), claimed = Claimed(cur.row) } end,
    lag = { cash = true },
    a = {
        name = 'server:admin:payNow',
        src = 5,
        payload = function()
            return { rowId = cur.row, requestId = Uuid() }
        end,
    },
    b = {
        name = 'server:admin:payNow',
        src = 9,
        payload = function()
            return { rowId = cur.row, requestId = Uuid() }
        end,
    },
})

-- ---------------------------------------------------------------------------- points
Case({
    label = 'Give points, two SAST supervisors to one officer',
    switches = true,
    setup = function() NewDay() end,
    effect = function() return { xp = Xp(CID[1]) } end,
    a = {
        name = 'server:sup:awardPoints',
        src = 3,
        payload = function()
            return { citizenid = CID[1], points = 20, reason = 'Great scene work' }
        end,
    },
    b = {
        name = 'server:sup:awardPoints',
        src = 8,
        payload = function()
            return { citizenid = CID[1], points = 20, reason = 'Great scene work' }
        end,
    },
})

-- one copy from a, one from b: the same action and payload builder, two players
local function Two(name, srcA, srcB, build)
    return {
        name = name,
        src = srcA,
        payload = function() return build(srcA) end,
    }, {
        name = name,
        src = srcB,
        payload = function() return build(srcB) end,
    }
end
local function Audits(action) return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action }) end
local function Bit(sql, params) return Count(sql, params) end

do
    local a, b = Two('server:admin:addDepartmentFunds', 5, 9, function()
        return { department = 'fib', amount = 700, reason = 'WF6C', confirm = '700', requestId = Uuid() }
    end)
    Case({
        label = 'Add funds, two admins to one department',
        switches = true,
        setup = function() end,
        effect = function()
            return {
                funds = Sum('SELECT COALESCE(SUM(amount), 0) AS n FROM cp_dept_funding WHERE department = \'fib\''),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:payCapRest', 5, 9, function()
        return { rowId = cur.row, reason = 'WF6C', confirm = '200', requestId = Uuid() }
    end)
    Case({
        label = 'Pay the rest of a capped payment, two admins',
        switches = true,
        one = true,
        setup = function() cur.row = Row({ cid = CID[1], owed = 500, paid = 300, status = 'capped' }) end,
        effect = function()
            return {
                cash = Paid(CID[1]),
                rowPaid = Sum('SELECT cash_paid AS n FROM cp_mission_runs WHERE id = ?', { cur.row }),
            }
        end,
        lag = { cash = true },
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:retryPending', 5, 9, function() return { requestId = Uuid() } end)
    Case({
        label = 'Retry pending payments, two admins',
        one = true,
        setup = function()
            cur.rows = { Row({ cid = CID[6], owed = 120 }), Row({ cid = CID[7], owed = 130 }) }
        end,
        effect = function()
            return {
                cash = Paid(CID[6]) + Paid(CID[7]),
                claimed = Claimed(cur.rows[1]) + Claimed(cur.rows[2]),
            }
        end,
        lag = { cash = true },
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:cancelPayment', 5, 9, function()
        return { rowId = cur.row, reason = 'Duplicate', confirm = '90' }
    end)
    Case({
        label = 'Cancel a pending payment, two admins',
        one = true,
        setup = function() cur.row = Row({ cid = CID[2], dept = 'fib', owed = 90 }) end,
        effect = function()
            return {
                cancelled = Count([[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ?
                AND cash_status NOT IN ('pending')]], { cur.row }),
                audit = Audits('paymentCancel'),
            }
        end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- caps
do
    local a = {
        name = 'server:sup:awardPoints',
        src = 3,
        payload = function()
            return { citizenid = CID[1], points = 30, reason = 'Great scene work' }
        end,
    }
    local b = {
        name = 'server:sup:awardPoints',
        src = 3,
        payload = function()
            return { citizenid = CID[6], points = 30, reason = 'Great scene work' }
        end,
    }
    Case({
        label = 'Give points, one supervisor to two officers at his daily limit',
        switches = true,
        one = true,
        setup = function()
            NewDay()
            -- 50 of the 100 a day given already: 30 more fits once (a fresh day each time)
            local ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[7], points = 50, reason = 'Earlier' })
            H.eq(ok, true, 'points set-up: ' .. tostring(err))
        end,
        effect = function() return { xp = Xp(CID[1]) + Xp(CID[6]) } end,
        a = a,
        b = b,
    })
end
do
    local a = {
        name = 'server:sup:commend',
        src = 3,
        payload = function()
            return { citizenid = CID[1], kind = cur.kind, citation = 'Stayed with the victim until EMS arrived.' }
        end,
    }
    local b = {
        name = 'server:sup:commend',
        src = 3,
        payload = function()
            return { citizenid = CID[6], kind = cur.kind, citation = 'Stayed with the victim until EMS arrived.' }
        end,
    }
    Case({
        label = 'Commend, one supervisor to two officers at his daily limit',
        one = true,
        setup = function()
            NewDay()
            cur.kind = 'valor'
            H.sql('DELETE FROM cp_commendations WHERE citizenid IN (?, ?, ?)', { CID[1], CID[6], CID[7] })
            -- two of his three a day given already
            for _, kind in ipairs({ 'teamwork', 'leadership' }) do
                local ok, err = Act('server:sup:commend', 3,
                    { citizenid = CID[7], kind = kind, citation = 'Kept the scene calm and safe.' })
                H.eq(ok, true, 'commend set-up: ' .. tostring(err))
            end
        end,
        effect = function()
            return {
                rows = Count('SELECT COUNT(*) AS n FROM cp_commendations WHERE citizenid IN (?, ?)',
                    { CID[1], CID[6] }),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:sup:commend', 3, 8, function()
        return { citizenid = CID[1], kind = cur.kind, citation = 'Talked the driver down calmly.' }
    end)
    local kinds = { 'valor', 'lifesaving', 'teamwork', 'professionalism', 'leadership', 'investigation' }
    local k = 0
    Case({
        label = 'Commend, two supervisors, the same kind to one officer',
        one = true,
        setup = function()
            -- the same kind again only after sameKindCooldownDays: a new kind each time
            k = k % #kinds + 1
            cur.kind = kinds[k]
            H.sql('DELETE FROM cp_commendations WHERE citizenid = ?', { CID[1] })
            NewDay()
        end,
        effect = function()
            return { rows = Count('SELECT COUNT(*) AS n FROM cp_commendations WHERE citizenid = ?', { CID[1] }) }
        end,
        a = a,
        b = b,
    })
end
do
    local a = {
        name = 'server:sup:missionBan',
        src = 3,
        payload = function()
            return { citizenid = CID[1], hours = 1, reason = 'Ignored an order' }
        end,
    }
    local b = {
        name = 'server:sup:missionBan',
        src = 3,
        payload = function()
            return { citizenid = CID[6], hours = 1, reason = 'Ignored an order' }
        end,
    }
    Case({
        label = 'Mission ban, one supervisor to two officers at his daily limit',
        switches = true,
        one = true,
        setup = function()
            NewDay()
            for _, cid in ipairs({ CID[1], CID[6], CID[7] }) do
                Act('server:restriction', 3, { op = 'lift', kind = 'missionBan', citizenid = cid, reason = 'x' })
            end
            Act('server:sup:missionBan', 3, { citizenid = CID[7], hours = 1, reason = 'Earlier today' })
            Secs(4)
            Act('server:sup:missionBan', 3, { citizenid = CID[7], hours = 2, reason = 'Earlier today' })
        end,
        effect = function()
            return {
                bans = Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'missionBan'
                AND target IN (?, ?)]], { CID[1], CID[6] }),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:sup:clearCooldowns', 3, 8, function()
        return { citizenid = CID[1], scope = 'type', key = 'patrol', reason = 'Crashed' }
    end)
    Case({
        label = 'Clear cooldown, two supervisors on one officer',
        switches = true,
        setup = function() NewDay() end,
        effect = function()
            return {
                clears = Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action LIKE '%ooldown%'
                AND target = ?]], { CID[1] }),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:sup:setMissionControl', 3, 8, function()
        return { key = 'happyHour', value = { minutes = 10 }, reason = 'Quiet night', requestId = Uuid() }
    end)
    Case({
        label = 'Happy hour, two SAST supervisors (one a day)',
        switches = true,
        one = true,
        setup = function()
            NewDay()
            H.sql('DELETE FROM cp_dept_controls WHERE control_key = \'happyHour\'')
            if CP.DeptControls and CP.DeptControls.clearCache then CP.DeptControls.clearCache() end
        end,
        effect = function()
            return {
                set = Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'missionControlSet'
                AND target LIKE '%:happyHour']]),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:resetFirstRun', 5, 9, function()
        return { citizenid = CID[6], reason = 'Crash' }
    end)
    Case({
        label = 'First-run bonus again, two admins (once a day)',
        one = true,
        setup = function() NewDay() end,
        effect = function() return { resets = Audits('firstRunReset') } end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- points, bans, grants
do
    local a, b = Two('server:admin:awardPoints', 5, 9, function()
        return { citizenid = CID[2], points = 15, reason = 'Helped at the scene' }
    end)
    Case({
        label = 'Give points (admin), two admins to one officer',
        setup = function() NewDay() end,
        effect = function() return { xp = Xp(CID[2]) } end,
        a = a,
        b = b,
    })
end
do
    local rid
    local function Build() return { citizenid = CID[2], points = 12, reason = 'Correction', requestId = rid } end
    Case({
        label = 'Adjust points, one request sent twice',
        one = true,
        setup = function()
            NewDay()
            rid = Uuid()
        end,
        effect = function() return { xp = Xp(CID[2]) } end,
        a = { name = 'server:admin:adjustPoints', src = 5, payload = Build },
        b = { name = 'server:admin:adjustPoints', src = 5, payload = Build },
    })
end
do
    local a, b = Two('server:admin:suspend', 5, 9, function()
        return { citizenid = CID[7], days = 1, reason = 'Rough arrest' }
    end)
    Case({
        label = 'Suspend, two admins on one officer',
        setup = function()
            Act('server:restriction', 5, { op = 'lift', kind = 'suspension', citizenid = CID[7], reason = 'x' })
        end,
        effect = function() return { suspended = Audits('suspend') } end,
        teardown = function()
            local ok, err = Act('server:restriction', 5,
                { op = 'lift', kind = 'suspension', citizenid = CID[7], reason = 'Back on the street' })
            H.eq(ok, true, 'suspend: lifted at the end: ' .. tostring(err))
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:allowExtraRuns', 5, 9, function()
        return { citizenid = CID[1], count = 1, reason = 'Event night' }
    end)
    Case({
        label = 'Extra runs, two admins to one officer',
        setup = function() NewDay() end,
        effect = function() return { granted = Audits('extraRunsAllow') } end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:grantBadge', 5, 9, function()
        return { citizenid = CID[6], badgeId = cur.badge, reason = 'Earned it' }
    end)
    Case({
        label = 'Grant a badge, two admins',
        one = true,
        setup = function()
            cur.badge = 'iron_wheels'
            H.sql('DELETE FROM cp_badges WHERE citizenid = ?', { CID[6] })
            H.sql('DELETE FROM cp_badge_overrides WHERE citizenid = ?', { CID[6] })
        end,
        effect = function()
            return { badges = Count('SELECT COUNT(*) AS n FROM cp_badges WHERE citizenid = ?', { CID[6] }) }
        end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- settings
do
    local v = 0
    local a = {
        name = 'server:admin:setSetting',
        src = 5,
        payload = function()
            return { path = 'MissionControls.addRunTimePerDay', json = tostring(cur.base + 1), reason = 'WF6C' }
        end,
    }
    local b = {
        name = 'server:admin:setSetting',
        src = 9,
        payload = function()
            return { path = 'MissionControls.addRunTimePerDay', json = tostring(cur.base + 2), reason = 'WF6C' }
        end,
    }
    Case({
        label = 'Settings, two admins change one setting',
        teardown = function() Setting('MissionControls.addRunTimePerDay', 10) end,
        setup = function()
            v = v + 3
            cur.base = 10 + v
            Setting('MissionControls.addRunTimePerDay', cur.base)
        end,
        effect = function()
            return {
                history = Count('SELECT COUNT(*) AS n FROM cp_settings_history WHERE setting_key = ?',
                    { 'MissionControls.addRunTimePerDay' }),
            }
        end,
        check = function()
            -- the value in force is the one stored
            local stored = H.sql('SELECT value_json AS v FROM cp_settings WHERE setting_key = ?',
                { 'MissionControls.addRunTimePerDay' })[1]
            local now = Config.MissionControls.addRunTimePerDay
            local ok = stored and tonumber(tostring(stored.v):match('%-?%d+')) == now
                and (now == cur.base + 1 or now == cur.base + 2)
            return ok, ('in force %s, stored %s'):format(tostring(now), tostring(stored and stored.v))
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:revertSetting', 5, 9, function()
        return { historyId = cur.hist, reason = 'Back as it was' }
    end)
    Case({
        label = 'Revert a setting, two admins on one change',
        teardown = function() Setting('MissionControls.addRunTimePerDay', 10) end,
        one = true,
        setup = function()
            cur.v = (cur.v or 10) + 1
            local ok, err = Setting('MissionControls.addRunTimePerDay', cur.v)
            H.eq(ok, true, 'revert set-up: ' .. tostring(err))
            cur.hist = Sum('SELECT MAX(id) AS n FROM cp_settings_history WHERE setting_key = ?',
                { 'MissionControls.addRunTimePerDay' })
        end,
        effect = function()
            return {
                history = Count('SELECT COUNT(*) AS n FROM cp_settings_history WHERE setting_key = ?',
                    { 'MissionControls.addRunTimePerDay' }),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:applyPreset', 5, 9, function() return { preset = 'golive' } end)
    Case({
        label = 'A preset, two admins at once',
        setup = function()
            -- the preset changes these again each time
            Setting('Debug', true)
            Setting('Payouts.requireReason', false)
        end,
        effect = function() return { applied = Audits('settingsPreset') } end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- review
do
    local a, b = Two('server:review:decide', 3, 8, function()
        return { type = 'flag', id = cur.row, decision = 'approve', reason = 'Route log is fine' }
    end)
    Case({
        label = 'Review Queue, two supervisors approve one flagged run',
        one = true,
        setup = function() cur.row = Row({ cid = CID[6], owed = 210, status = 'held', flagged = true }) end,
        effect = function()
            return {
                cash = Paid(CID[6]),
                approved = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ? AND flagged = 0', { cur.row }),
            }
        end,
        lag = { cash = true },
        a = a,
        b = b,
    })
end
do
    local a = {
        name = 'server:review:decide',
        src = 3,
        payload = function()
            return { type = 'flag', id = cur.row, decision = 'approve', reason = 'Route log is fine' }
        end,
    }
    local b = {
        name = 'server:review:decide',
        src = 8,
        payload = function()
            return { type = 'flag', id = cur.row, decision = 'void', reason = 'Route skipped' }
        end,
    }
    Case({
        label = 'Review Queue, approve and void of one flagged run at once',
        one = true,
        setup = function()
            cur.row = Row({ cid = CID[7], owed = 220, status = 'held', flagged = true })
            cur.paid0 = Paid(CID[7])
        end,
        effect = function()
            return {
                decided = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ? AND flagged = 0', { cur.row }),
            }
        end,
        check = function()
            local r = H.sql('SELECT voided, cash_status FROM cp_mission_runs WHERE id = ?', { cur.row })[1] or {}
            local voided = tonumber(r.voided) == 1 or r.voided == true
            local paid = Paid(CID[7]) - (cur.paid0 or 0)
            return not (voided and paid > 0), ('voided %s and paid %d'):format(tostring(voided), paid)
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:voidRun', 5, 9, function()
        return { rowId = cur.row, reason = 'Bugged course', kind = 'correction' }
    end)
    Case({
        label = 'Void a run, two admins',
        one = true,
        setup = function() cur.row = Row({ cid = CID[1], owed = 0, status = 'none' }) end,
        effect = function()
            return {
                voided = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ? AND voided = 1', { cur.row }),
                audit = Audits('voidRun'),
            }
        end,
        -- the audit row is written after the void: a stop between the two loses the row, never the void
        lag = { audit = true },
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:restoreRun', 5, 9, function()
        return { rowId = cur.row, reason = 'Course was fine' }
    end)
    Case({
        label = 'Restore a voided run, two admins',
        one = true,
        setup = function()
            cur.row = Row({ cid = CID[1], owed = 0, status = 'none' })
            Act('server:admin:voidRun', 5, { rowId = cur.row, reason = 'Bugged course', kind = 'correction' })
        end,
        effect = function()
            return {
                restored = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ? AND voided = 0', { cur.row }),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local function Build() return { rowId = cur.row, reason = 'My game crashed, please check the route log' } end
    Case({
        label = 'Dispute, one officer sends it twice',
        one = true,
        setup = function()
            cur.row = Row({ cid = CID[6], owed = 0, status = 'none' })
            Act('server:admin:voidRun', 5, { rowId = cur.row, reason = 'Bugged course', kind = 'correction' })
            Unsuspend(CID[6])
        end,
        effect = function()
            return { disputes = Count('SELECT COUNT(*) AS n FROM cp_disputes WHERE run_id = ?', { cur.row }) }
        end,
        a = { name = 'server:dispute', src = 6, payload = Build },
        b = { name = 'server:dispute', src = 6, payload = Build },
    })
end
do
    local a, b = Two('server:review:decide', 5, 9, function()
        return { type = 'dispute', id = cur.dispute, decision = 'approve', reason = 'Checked the log' }
    end)
    Case({
        label = 'Review Queue, two admins answer one dispute',
        one = true,
        setup = function()
            cur.row = Row({ cid = CID[7], owed = 0, status = 'none' })
            Act('server:admin:voidRun', 5, { rowId = cur.row, reason = 'Bugged course', kind = 'correction' })
            Unsuspend(CID[7])
            Secs(61)
            local ok, err = Act('server:dispute', 7,
                { rowId = cur.row, reason = 'My game crashed, please check the route log' })
            H.eq(ok, true, 'dispute set-up: ' .. tostring(err))
            cur.dispute = Sum('SELECT MAX(id) AS n FROM cp_disputes')
        end,
        effect = function()
            return {
                handled = Count('SELECT COUNT(*) AS n FROM cp_disputes WHERE id = ? AND status <> \'open\'',
                    { cur.dispute }),
                restored = Count('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE id = ? AND voided = 0', { cur.row }),
            }
        end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- backups and restores
do
    local a, b = Two('server:admin:backupNow', 5, 9, function() return {} end)
    Case({
        label = 'Back up now, two admins',
        maxCuts = 3,
        setup = function() end,
        effect = function()
            local list = Cb('admin:getBackups', 5) or {}
            return { backups = #(list.backups or {}) }
        end,
        a = a,
        b = b,
    })
end

-- ---------------------------------------------------------------------------- officers: tours, calls, runs
local function Tours(cid)
    local row = H.sql('SELECT seen FROM cp_tours WHERE citizenid = ?', { cid })[1]
    local seen = row and row.seen
    if type(seen) == 'string' then seen = cjson.decode(seen) end
    local n0 = 0
    for _ in pairs(type(seen) == 'table' and seen or {}) do n0 = n0 + 1 end
    return n0
end
do
    local function Build() return { tour = 'officer', version = 1 } end
    Case({
        label = 'A guided tour done, sent twice',
        one = true,
        setup = function() H.sql('DELETE FROM cp_tours WHERE citizenid = ?', { CID[1] }) end,
        effect = function() return { tours = Tours(CID[1]) } end,
        a = { name = 'server:training:done', src = 1, payload = Build },
        b = { name = 'server:training:done', src = 1, payload = Build },
    })
    Case({
        label = 'Two guided tours done at once (the officer tour and the first-run tips)',
        setup = function() H.sql('DELETE FROM cp_tours WHERE citizenid = ?', { CID[6] }) end,
        effect = function() return { tours = Tours(CID[6]) } end,
        check = function(r1, r2)
            local want = ((r1 and r1.ok) and 1 or 0) + ((r2 and r2.ok) and 1 or 0)
            return Tours(CID[6]) == want, ('%d tours saved, %d done'):format(Tours(CID[6]), want)
        end,
        a = { name = 'server:training:done', src = 6, payload = { tour = 'officer', version = 1 } },
        b = { name = 'server:training:done', src = 6, payload = { tour = 'run', version = 1 } },
    })
end
do
    local a, b = Two('server:admin:resetTours', 5, 9, function()
        return { citizenid = CID[1], reason = 'Replay the tours' }
    end)
    Case({
        label = 'Reset the tours of an officer, two admins',
        one = true,
        setup = function()
            Act('server:training:done', 1, { tour = 'officer', version = 1 })
        end,
        effect = function()
            return {
                cleared = Count(
                    'SELECT COUNT(*) AS n FROM cp_audit WHERE action = ? AND new_value'
                        .. ' = \'0\' AND old_value <> \'0\'',
                    { 'toursReset' }
                ),
            }
        end,
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:answerMissionCall', 1, 6, function() return { callId = cur.call } end)
    Case({
        label = 'A mission call, two officers claim it',
        one = true,
        setup = function()
            for _, s in ipairs({ 1, 6 }) do
                local run = CP.Runs.getBySrc(s)
                if run then Act('server:abandon', s, run.id) end
            end
            NewDay()
            H.sql('UPDATE cp_mission_calls SET status = \'withdrawn\' WHERE status IN (\'open\', \'claimed\')')
            local ok, err = Act('server:sup:mcPost', 3, { type = 'patrol', area = 'south_ls' })
            H.eq(ok, true, 'mission call set-up: ' .. tostring(err))
            cur.call = Sum('SELECT MAX(id) AS n FROM cp_mission_calls')
        end,
        effect = function()
            return {
                claimed = Count('SELECT COUNT(*) AS n FROM cp_mission_calls WHERE id = ? AND status = \'claimed\'',
                    { cur.call }),
                runs = (CP.Runs.getBySrc(1) and 1 or 0) + (CP.Runs.getBySrc(6) and 1 or 0),
            }
        end,
        a = a,
        b = b,
    })
end
do
    Case({
        label = 'Accept a mission, sent twice',
        one = true,
        cut = false,
        setup = function()
            local run = CP.Runs.getBySrc(7)
            if run then Act('server:abandon', 7, run.id) end
            Unsuspend(CID[7])
            NewDay()
        end,
        effect = function()
            local n0 = 0
            for _, run in ipairs(CP.Runs.all()) do
                for _, m in ipairs(CP.Runs.activeSrcs(run)) do if m == 7 then n0 = n0 + 1 end end
            end
            return { runs = n0 }
        end,
        a = { name = 'server:acceptType', src = 7, payload = 'patrol' },
        b = { name = 'server:acceptType', src = 7, payload = 'patrol' },
    })
end

-- ---------------------------------------------------------------------------- items, clawback, notices, units
local function Reward(cid)
    H.sql([[INSERT INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status, created_at)
        VALUES (NULL, 'run', ?, ?, 'water', 1, 0, 'pending', FROM_UNIXTIME(?))]], { Uuid(), cid, H.time })
    return Sum('SELECT MAX(id) AS n FROM cp_item_rewards')
end
do
    local function Build() return { id = cur.reward } end
    Case({
        label = 'Claim an item reward, sent twice',
        switches = true,
        one = true,
        setup = function()
            H.sql('UPDATE cp_item_rewards SET status = \'forfeited\' WHERE status = \'pending\'')
            cur.reward = Reward(CID[1])
        end,
        effect = function()
            return {
                items = W.ItemsGiven(1, 'water'),
                given = Count('SELECT COUNT(*) AS n FROM cp_item_rewards WHERE id = ? AND status <> \'pending\'',
                    { cur.reward }),
            }
        end,
        lag = { items = true },
        a = { name = 'server:rewards:claim', src = 1, payload = Build },
        b = { name = 'server:rewards:claim', src = 1, payload = Build },
    })
end
do
    local a, b = Two('server:admin:deliverRewards', 5, 9, function() return { citizenid = CID[6] } end)
    Case({
        label = 'Deliver waiting items, two admins',
        switches = true,
        one = true,
        setup = function()
            -- a row left waiting by the maintenance lock of a run before is not this run's
            H.sql('UPDATE cp_item_rewards SET status = \'forfeited\' WHERE status = \'pending\'')
            cur.reward = Reward(CID[6])
        end,
        effect = function()
            return {
                items = W.ItemsGiven(6, 'water'),
                given = Count('SELECT COUNT(*) AS n FROM cp_item_rewards WHERE id = ? AND status <> \'pending\'',
                    { cur.reward }),
            }
        end,
        lag = { items = true },
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:admin:clawback', 5, 9, function()
        return { rowId = cur.row, amount = 100, reason = 'Paid twice by mistake', confirm = '100', requestId = Uuid() }
    end)
    Case({
        label = 'Claw back paid cash, two admins on one row',
        switches = true,
        setup = function() cur.row = Row({ cid = CID[1], owed = 500, paid = 500, status = 'paid' }) end,
        effect = function()
            return {
                reclaimed = Sum('SELECT cash_reclaimed AS n FROM cp_mission_runs WHERE id = ?', { cur.row }),
                taken = taken[CID[1]] or 0,
            }
        end,
        -- the amount is held on the row before the money is taken: a stop between the two leaves it held (never
        -- taken twice)
        lag = { taken = true },
        a = a,
        b = b,
    })
end
do
    local a, b = Two('server:notice:post', 3, 8, function()
        return { kind = 'department', text = 'Briefing at the station at 20:00, every unit.', days = 2 }
    end)
    Case({
        label = 'Department notice, two SAST supervisors at once',
        switches = true,
        setup = function()
            NewDay()
            H.sql('UPDATE cp_staff_notices SET removed_at = NOW() WHERE removed_at IS NULL')
        end,
        effect = function()
            return { notices = Count('SELECT COUNT(*) AS n FROM cp_staff_notices WHERE removed_at IS NULL') }
        end,
        a = a,
        b = b,
    })
end
do
    local function Build() return { accepted = true, unitId = cur.unit } end
    Case({
        label = 'Answer a unit invite, sent twice',
        one = true,
        setup = function()
            for _, s0 in ipairs({ 1, 6 }) do
                if CP.Units.unitOf(s0) then Act('server:teamLeave', s0) end
            end
            local ok, data = Act('server:unitInvite', 1, 6)
            H.eq(ok, true, 'unit set-up: ' .. tostring(data))
            cur.unit = type(data) == 'table' and data.unitId or nil
        end,
        effect = function()
            local u = CP.Units.unitOf(6)
            return { members = u and #u.members or 0 }
        end,
        a = { name = 'server:unitRespond', src = 6, payload = Build },
        b = { name = 'server:unitRespond', src = 6, payload = Build },
        teardown = function()
            for _, s0 in ipairs({ 1, 6 }) do
                if CP.Units.unitOf(s0) then Act('server:teamLeave', s0) end
            end
        end,
    })
end
do
    local a = {
        name = 'server:sup:revokeCommendation',
        src = 3,
        payload = function()
            return { id = cur.commend, reason = 'Given by mistake' }
        end,
    }
    local b = {
        name = 'server:admin:revokeCommendation',
        src = 5,
        payload = function()
            return { id = cur.commend, reason = 'Given by mistake' }
        end,
    }
    local kinds = { 'professionalism', 'investigation', 'lifesaving' }
    local k = 0
    Case({
        label = 'Revoke a commendation, its supervisor and an admin at once',
        one = true,
        setup = function()
            NewDay()
            k = k % #kinds + 1
            H.sql('DELETE FROM cp_commendations WHERE citizenid = ?', { CID[7] })
            local ok, err = Act('server:sup:commend', 3,
                { citizenid = CID[7], kind = kinds[k], citation = 'Kept the scene calm and safe.' })
            H.eq(ok, true, 'revoke set-up: ' .. tostring(err))
            cur.commend = Sum('SELECT MAX(id) AS n FROM cp_commendations')
        end,
        effect = function()
            return {
                revoked = Count('SELECT COUNT(*) AS n FROM cp_commendations WHERE id = ? AND revoked = 1',
                    { cur.commend }),
                audit = Audits('revokeCommendation'),
            }
        end,
        -- the audit row is written after the revoke: a stop between the two loses the row, never the revoke
        lag = { audit = true },
        a = a,
        b = b,
    })
end
do
    local a = {
        name = 'server:admin:restoreBackup',
        src = 5,
        payload = function()
            return {
                name = cur.backup,
                previewToken = cur.pv5,
                reason = 'WF6C',
                confirm = 'RESTORE',
                requestId = Uuid(),
            }
        end,
    }
    local b = {
        name = 'server:admin:restoreBackup',
        src = 9,
        payload = function()
            return {
                name = cur.backup,
                previewToken = cur.pv9,
                reason = 'WF6C',
                confirm = 'RESTORE',
                requestId = Uuid(),
            }
        end,
    }
    Case({
        label = 'Restore a backup, two admins at once',
        -- a restore cut by a stop keeps payments held until the fix restore it names: workflows_system (3) drives
        -- that; the maintenance lock is the restore's own
        cut = false,
        maintenance = false,
        setup = function()
            if not cur.backup then
                local ok, res = Act('server:admin:backupNow', 5, {})
                H.ok(ok == true, 'restore set-up: a backup: ' .. tostring(res))
                cur.backup = type(res) == 'table' and res.name or nil
            end
            Secs(2)
            cur.pv5 = (Cb('admin:previewRestore', 5, { name = cur.backup }) or {}).previewToken
            cur.pv9 = (Cb('admin:previewRestore', 9, { name = cur.backup }) or {}).previewToken
        end,
        effect = function() return { restores = Audits('backupRestored') } end,
        a = a,
        b = b,
    })
end

-- ============================================================================
--                                     RUN
-- ============================================================================

local function SwitchesOn()
    Setting('Permissions.supervisor.missionControls', true)
    local controls = CP.U.copy(Config.MissionControls.controls)
    for _, c in pairs(controls) do c.on = true end
    Setting('MissionControls.controls', controls)
    for _, path in ipairs({
        'Cash.allowManualCash',
        'Cash.allowAddFunds',
        'Cash.allowCapTopUp',
        'Cash.allowClawback',
        'Rewards.enabled',
    }) do
        local ok, err = Act('server:admin:setSetting', 5,
            { path = path, json = 'true', reason = 'WF6C', confirm = 'ENABLE' })
        H.eq(ok, true, 'switches: ' .. path .. ': ' .. tostring(err))
    end
end

-- CP_RACE_ONLY=<text>: only the cases whose label holds it (while working on one)
local ONLY = os.getenv('CP_RACE_ONLY')
local function Picked(c) return not ONLY or ONLY == '' or c.label:find(ONLY, 1, true) ~= nil end
local t0 = os.clock()
for _, c in ipairs(CASES) do if not c.switches and Picked(c) then RunCase(c) end end
SwitchesOn()
for _, c in ipairs(CASES) do if c.switches and Picked(c) then RunCase(c) end end
for _, line in ipairs(results) do print('REPORT race ' .. line) end
print(('REPORT race %d cases in %.1f s'):format(#CASES, os.clock() - t0))
for _, l in ipairs(errorLines) do W.realPrint('ERRLINE ' .. l) end
H.eq(#errorLines, 0, 'no error line')
if not W.ON_DB then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s"'):format(H.db)) end

return H
