-- tests/int_services_spec.lua · integration of the services group: the REAL modules scoring, goals, cash, payouts,
-- leaderboard, challenge, admin, disputes and anticheat running together (plus the real permissions, scaling and
-- schedule), on stubs of CP.Qbx, CP.Access, CP.Tablet, CP.Banking, CP.Missions and CP.Runs.
-- It checks the cross-module paths the slice notes asked for (docs/notes/economy.md, boards.md, oversight.md,
-- testing.md): approve/void ordering against the real XP / cash / board hooks, disputes forfeiting and restoring,
-- goal and manual_award rows (season, department, board refresh), admin:getStuckPayments, reasons counted in
-- characters across admin -> scoring and in payouts, the Profile's canDispute = CP.Disputes.eligible, badge labels
-- of leaderboard badges in CP.Scoring.badges, and /CrimsonPoliceAdmin test for archived custom missions.
-- Own database (<run database>_intsvc, rebuilt from sql/migrations and dropped at the end); the fake clock is
-- aligned with the database clock (rows are written with FROM_UNIXTIME(os.time())).

local REAL_NOW = os.time()
local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_intsvc'

-- oxmysql talks utf8mb4; the harness' mysql CLI would default to latin1 and mangle non-ASCII text.
do
    local realPopen = io.popen
    io.popen = function(cmd, mode)
        if type(cmd) == 'string' and cmd:match('^mysql %-uroot ') and not cmd:find('default%-character%-set', 1) then
            cmd = cmd:gsub('^mysql %-uroot ', 'mysql --default-character-set=utf8mb4 -uroot ', 1)
        end
        return realPopen(cmd, mode)
    end
end

H.resetDatabase()
H.boot({ side = 'server' })
H.time = REAL_NOW

local cjson = require('cjson')

-- ── console: keep the module log lines out of the test output ───────────────
local realPrint = print
local printed = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    printed[#printed + 1] = line
    if line:find('crimson%-police') or line:find('Crimson%-Police') then return end
    realPrint(line)
end

-- ── locale: every part merged, like locales/en.json in game ─────────────────
do
    local merged = {}
    local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
    for file in p:lines() do
        local f = io.open(file, 'r')
        local ok, data = pcall(cjson.decode, f:read('a'))
        f:close()
        if ok and type(data) == 'table' then
            for k, v in pairs(data) do merged[k] = v end
        end
    end
    p:close()
    local text = cjson.encode(merged)
    local realLoad = LoadResourceFile
    LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return text end
        return realLoad(res, path)
    end
    H.load('shared/locale.lua')
end

-- ── players ─────────────────────────────────────────────────────────────────
local players = {}   -- src -> { citizenid, name, dept, role = officer|supervisor|admin, offline }
local function addPlayer(src, cid, name, dept, role)
    players[src] = { src = src, citizenid = cid, name = name, dept = dept, role = role, callsign = 'C-' .. src }
    H.players[src] = { coords = vec3(0.0, 0.0, 0.0), ace = role == 'admin' and { ['crimsonpolice.admin'] = true } or {} }
end
addPlayer(1, 'IADM0001', 'Ada Admin', nil, 'admin')
addPlayer(2, 'ISUP0002', 'Sam Super', 'sast', 'supervisor')
addPlayer(3, 'IOFF0003', 'Olly Officer', 'sast', 'officer')
addPlayer(4, 'IFIB0004', 'Fay Fed', 'fib', 'officer')

local qbx = { addMoney = {} }
CP.Qbx = {
    getInfo = function(src)
        local p = players[tonumber(src)]
        if not p or p.offline then return nil end
        return { src = p.src, citizenid = p.citizenid, name = p.name, callsign = p.callsign,
            job = { name = p.dept or 'unemployed', onduty = p.dept ~= nil, gradeLevel = p.role == 'supervisor' and 3 or 1, gradeName = 'Trooper' } }
    end,
    getByCitizenId = function(cid)
        for s, p in pairs(players) do if p.citizenid == cid and not p.offline then return s end end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for s, p in pairs(players) do if not p.offline then out[#out + 1] = s end end
        table.sort(out)
        return out
    end,
    addMoney = function(src, account, amount, reason)
        qbx.addMoney[#qbx.addMoney + 1] = { src = src, account = account, amount = amount, reason = reason }
        return true
    end,
    onDutyChange = function() end, onJobChange = function() end, onPlayerLoaded = function() end,
    onPlayerUnload = function() end, onGroupUpdate = function() end,
}

local suspensions = {}
CP.Access = {
    isAdmin = function(src)
        src = tonumber(src)
        if src == 0 then return true end
        local p = players[src]
        return p ~= nil and p.role == 'admin'
    end,
    isSupervisor = function(src)
        local p = players[tonumber(src)]
        return p ~= nil and p.dept ~= nil and p.role == 'supervisor'
    end,
    getOfficer = function(src)
        local p = players[tonumber(src)]
        if not p or p.offline or not p.dept then return nil, 'err.not_police' end
        local d = Config.Departments[p.dept]
        return { src = p.src, citizenid = p.citizenid, name = p.name, department = p.dept, departmentLabel = d.label,
            departmentShort = d.short, job = p.dept, rank = 'Trooper', gradeLevel = p.role == 'supervisor' and 3 or 1,
            callsign = p.callsign, onduty = true, isSupervisor = p.role == 'supervisor', isAdmin = false }
    end,
    department = function(key)
        local d = Config.Departments[key]
        if not d then return nil end
        return { key = key, label = d.label, short = d.short, societyAccount = key, supervisorGrade = 3, theme = { primary = d.theme.primary } }
    end,
    departments = function()
        local keys = {}
        for k in pairs(Config.Departments) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for i, k in ipairs(keys) do out[i] = CP.Access.department(k) end
        return out
    end,
    departmentForJob = function(job) return Config.Departments[job] and job or nil end,
    isSuspended = function(cid) return suspensions[cid] ~= nil end,
    suspend = function(cid, days, actorSrc, reason)
        suspensions[cid] = { days = days, actor = actorSrc, reason = reason }
        return true
    end,
}

local banking = { deposits = {} }
CP.Banking = {
    recordDeposit = function(cid, amount, message, issuer, receiver, transId)
        banking.deposits[#banking.deposits + 1] = { cid = cid, amount = amount, transId = transId }
        return true
    end,
    withdrawSociety = function() return true end,
    recordSocietyWithdraw = function() return true end,
    societyBalance = function() return 0 end,
}

local notes = {}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } return true end,
    notifyMany = function(srcs, kind, key, vars) for _, s in ipairs(srcs) do CP.Tablet.notify(s, kind, key, vars) end return #srcs end,
    push = function() return true end,
    openAdmin = function() return true end,
}

local DEFS = {
    gang_shootout = { id = 'gang_shootout', label = 'Gang Shootout', type = 'tactical', difficulty = 3, minOfficers = 1, maxOfficers = 4,
        source = 'builtin', departments = {}, locations = { {}, {}, {} }, bonuses = {}, penalties = {}, objectives = { {} } },
    beat_patrol = { id = 'beat_patrol', label = 'Beat Patrol', type = 'patrol', difficulty = 1, minOfficers = 1, maxOfficers = 2,
        source = 'builtin', departments = {}, locations = { {} }, bonuses = {}, penalties = {}, objectives = { {} } },
}
CP.Missions = {
    get = function(id) return DEFS[id] end,
    list = function() return { DEFS.beat_patrol, DEFS.gang_shootout } end,
    all = function() return DEFS end,
    isEnabled = function(id) return DEFS[id] ~= nil end,
    byType = function(t)
        local out = {}
        for _, d in pairs(DEFS) do if d.type == t then out[#out + 1] = d end end
        return out
    end,
}
local liveRuns = {}
CP.Runs = { get = function(id) return liveRuns[id] end, all = function() return {} end }
CP.Draw = { pool = function(t) return CP.Missions.byType(t) end }
CP.Events = { typeOfTheDay = function() return nil end }

H.load('modules/scaling/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/payouts/server.lua')
H.load('modules/cash/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/goals/server.lua')
H.load('modules/leaderboard/server.lua')
H.load('modules/challenge/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/disputes/server.lua')
H.load('modules/anticheat/server.lua')

-- ── helpers ─────────────────────────────────────────────────────────────────
local reqSeq = 0
local function act(name, src, payload)
    H.clockMs = H.clockMs + 1100   -- stay under every per-second rate limit
    reqSeq = reqSeq + 1
    local reqId = 'i' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end

local function command(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    local c = coroutine.create(function() CP.Admin.command(src, args) end)
    local ok, err = coroutine.resume(c)
    if not ok then error(err, 2) end
end

local function lastNote(src, key)
    for i = #notes, 1, -1 do
        if notes[i].src == src and (key == nil or notes[i].key == key) then return notes[i] end
    end
    return nil
end

local function officerRow(cid, name, dept)
    H.sql('INSERT INTO cp_officers (citizenid, display_name, department, xp) VALUES (?, ?, ?, 0) ON DUPLICATE KEY UPDATE display_name = VALUES(display_name), department = VALUES(department)',
        { cid, name, dept })
end
officerRow('ISUP0002', 'Sam Super', 'sast')
officerRow('IOFF0003', 'Olly Officer', 'sast')
officerRow('IFIB0004', 'Fay Fed', 'fib')

local function xpOf(cid) return tonumber(H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1].xp) end
local function rowOf(id) return H.sql('SELECT * FROM cp_mission_runs WHERE id = ?', { id })[1] end
local function bd(id) return cjson.decode(rowOf(id).breakdown) end

-- A cp_mission_runs row as the engine writes it.
local uuidN = 0
local function insertRun(o)
    uuidN = uuidN + 1
    local uuid = o.uuid or ('intsvc-%04d'):format(uuidN)
    local breakdown = {
        runId = uuid, missionLabel = 'Gang Shootout', missionType = o.type or 'tactical', result = o.state or 'completed',
        endReason = o.state == 'failed' and 'time_limit' or 'completed', test = false, tier = 'heavy', payTier = 'heavy',
        participants = 2, departments = 1, durationS = 300,
        points = { P = 200, bonuses = {}, penalties = {}, subtotal = o.final or 240, mTeam = 1.15, mCross = 1, mStreak = 1,
            capped = false, tod = false, final = o.final or 240 },
        cash = { B = 800, mTier = 1.15, mMod = 1.25, amount = o.amount or 1150, status = o.status or 'none' },
        flagged = o.flagged and { reason = o.flagReason or 'outside_help' } or nil,
    }
    return MySQL.insert.await([[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid,
            cash_status, breakdown, flagged, flag_reason, voided, created_at)
        VALUES (?, ?, ?, ?, ?, NULL, 2, 1, 'heavy', ?, ?, 200, ?, 800, 1.44, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
    ]], { uuid, o.type or 'tactical', o.mission or 'gang_shootout', o.cid or 'IOFF0003', o.dept or 'sast',
        o.state or 'completed', o.state == 'failed' and 'time_limit' or 'completed', o.final or 240, o.paid or 0,
        o.status or 'none', cjson.encode(breakdown), o.flagged and 1 or 0, o.flagged and (o.flagReason or 'outside_help') or nil,
        o.voided and 1 or 0, o.created or H.time })
end

-- The weekly Overall points of an officer as the board shows them to that officer (cache included).
local function boardPoints(src)
    local res = cb('getBoard', src, { period = 'weekly', filter = 'overall' })
    H.ok(res and res.ok, 'getBoard answered')
    return res and res.data and res.data.me and res.data.me.points
end

-- ════════════════════════════════════════════════════════════════════════════
-- 1. Review queue approve: flagged = 0 BEFORE the XP and cash hooks (real CP.Scoring / CP.Cash / board cache)
-- ════════════════════════════════════════════════════════════════════════════
local f1 = insertRun({ flagged = true, status = 'held', amount = 1150, final = 240 })
H.eq(boardPoints(3), 0, 'a flagged row is not on the board')
H.eq(xpOf('IOFF0003'), 0, 'no XP for a flagged row')
local ok, data = act('server:sup:reviewFlagged', 2, { rowId = f1, decision = 'approve', reason = 'Checked the footage' })
H.eq(ok, true, 'supervisor approves the flagged run of their department')
local r1 = rowOf(f1)
H.eq(r1.flagged, 0, 'flag cleared')
H.eq(r1.cash_status, 'paid', 'held cash released and paid (CP.Cash.release saw flagged = 0)')
H.eq(r1.cash_paid, 1150, 'paid the breakdown amount, not cash_base x the rounded cash_multiplier (800 x 1.44 = 1152)')
H.eq(qbx.addMoney[#qbx.addMoney].amount, 1150, 'Qbox AddMoney with the exact amount')
H.eq(banking.deposits[#banking.deposits].transId, 'CP-' .. r1.run_uuid .. '-IOFF0003', 'Renewed-Banking transaction id')
H.eq(xpOf('IOFF0003'), 240, 'XP added by CP.Scoring.onRowApproved (it saw flagged = 0)')
H.eq(bd(f1).xpCounted, 1, 'XP marker set')
H.eq(boardPoints(3), 240, 'the board cache was invalidated: the approved points show at once')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'approveFlagged'")[1].n, 1, 'approval audited once')

-- A second approval changes nothing (no double XP, no second payment).
local paidBefore = #qbx.addMoney
ok, data = act('server:sup:reviewFlagged', 2, { rowId = f1, decision = 'approve', reason = 'again' })
H.eq(ok, false, 'second approval refused')
H.eq(data, 'err.not_flagged', 'not flagged any more')
H.eq(xpOf('IOFF0003'), 240, 'XP unchanged')
H.eq(#qbx.addMoney, paidBefore, 'no second payment')

-- ════════════════════════════════════════════════════════════════════════════
-- 2. Void: voided = 1 BEFORE CP.Scoring.onRowVoided; board refreshed; paid cash stays paid; 3 voids suspend
-- ════════════════════════════════════════════════════════════════════════════
ok, data = act('server:admin:voidRun', 1, { rowId = f1, reason = 'Exploit confirmed' })
H.eq(ok, true, 'admin voids the run')
H.eq(rowOf(f1).voided, 1, 'row voided')
H.eq(xpOf('IOFF0003'), 0, 'XP taken back (the row had counted)')
H.eq(bd(f1).xpCounted, nil, 'XP marker removed')
H.eq(rowOf(f1).cash_status, 'paid', 'voiding a paid run does not take the money back')
H.eq(boardPoints(3), 0, 'voided run left the board at once')
H.eq(suspensions.IOFF0003, nil, 'one void does not suspend')

-- Voiding a flagged row that never counted takes nothing back.
local f2 = insertRun({ flagged = true, status = 'held', final = 100 })
officerRow('IOFF0003', 'Olly Officer', 'sast')
H.sql("UPDATE cp_officers SET xp = 500 WHERE citizenid = 'IOFF0003'")
ok = act('server:sup:reviewFlagged', 2, { rowId = f2, decision = 'void', reason = 'Outside help' })
H.eq(ok, true, 'supervisor voids a flagged run')
H.eq(xpOf('IOFF0003'), 500, 'a never-counted row takes no XP back')
H.eq(rowOf(f2).cash_status, 'held', 'held cash stays held until the dispute window closes')

local f3 = insertRun({ flagged = true, status = 'held', final = 100 })
ok = act('server:sup:reviewFlagged', 2, { rowId = f3, decision = 'void', reason = 'Outside help again' })
H.eq(ok, true, 'third void')
H.ok(suspensions.IOFF0003 ~= nil, 'three voids in 30 days -> CP.Access.suspend (anticheat)')
H.eq(suspensions.IOFF0003 and suspensions.IOFF0003.days, Config.AntiCheat.suspendDays, 'for suspendDays')
H.eq(suspensions.IOFF0003 and suspensions.IOFF0003.actor, 0, 'by the server (actor 0)')
local autoAudit = H.sql("SELECT actor, role, target, new_value FROM cp_audit WHERE action = 'autoSuspend'")
H.eq(#autoAudit, 1, 'the automatic suspension is audited by anticheat itself')
H.eq(autoAudit[1] and autoAudit[1].role, 'console', 'automatic entry = console role')
H.eq(autoAudit[1] and autoAudit[1].target, 'IOFF0003', 'target = the officer')

-- ════════════════════════════════════════════════════════════════════════════
-- 3. Disputes about voided rows: reject -> forfeited; approve -> restored, XP back, cash released
-- ════════════════════════════════════════════════════════════════════════════
suspensions.IOFF0003 = nil
ok, data = act('server:dispute', 3, { rowId = f2, reason = 'It was my partner who fired' })
H.eq(ok, true, 'the officer disputes their voided run')
local d2 = data and data.disputeId
ok, data = act('server:sup:handleDispute', 2, { disputeId = d2, decision = 'reject', reason = 'Footage is clear' })
H.eq(ok, true, 'supervisor rejects the dispute')
H.eq(rowOf(f2).cash_status, 'forfeited', 'rejected dispute about a voided run -> CP.Cash.forfeit')
H.eq(bd(f2).cash.status, 'forfeited', 'breakdown status too')

ok, data = act('server:dispute', 3, { rowId = f3, reason = 'Wrong officer' })
H.eq(ok, true, 'second dispute filed')
local d3 = data and data.disputeId
local xpBefore = xpOf('IOFF0003')
ok, data = act('server:sup:handleDispute', 2, { disputeId = d3, decision = 'approve', reason = 'Confirmed: another unit' })
H.eq(ok, true, 'supervisor approves the dispute')
local r3 = rowOf(f3)
H.eq(r3.voided, 0, 'void lifted')
H.eq(r3.flagged, 0, 'flag lifted')
H.eq(xpOf('IOFF0003'), xpBefore + 100, 'XP added by onRowApproved after the void and flag were cleared')
H.eq(r3.cash_status, 'paid', 'held cash released')
H.eq(r3.cash_paid, 1150, 'paid the breakdown amount')
H.eq(boardPoints(3), 100, 'restored run is back on the board at once')

-- ════════════════════════════════════════════════════════════════════════════
-- 4. Goal and manual_award rows: season_id, department, the board refreshed
-- ════════════════════════════════════════════════════════════════════════════
ok, data = CP.Challenge.startSeason(0, 'Season One')
H.eq(ok, true, 'season started from the console')
local seasonId = CP.Challenge.currentSeason().id
H.ok(seasonId ~= nil, 'current season')

local savedGoals = Config.Goals
Config.Goals = { dailyPoints = 50, weeklyPoints = 200, daily = { { id = 'int_any_1', label = 'Complete 1 mission', count = 1 } }, weekly = {} }
H.eq(boardPoints(4), 0, 'FIB officer starts at 0')
insertRun({ cid = 'IFIB0004', dept = 'fib', final = 0, status = 'paid', paid = 0 })
CP.Goals.onRunCompleted('IFIB0004')
local goal = H.sql("SELECT * FROM cp_mission_runs WHERE mission_type = 'goal' AND citizenid = 'IFIB0004'")[1]
H.ok(goal ~= nil, 'goal row inserted')
H.eq(goal and goal.mission_id, 'int_any_1', 'goal id as mission_id')
H.eq(goal and goal.season_id, seasonId, 'goal row carries the season id')
H.eq(goal and goal.department, 'fib', 'goal row carries the officer department')
H.eq(goal and goal.final_points, 50, 'daily goal reward')
H.eq(boardPoints(4), 50, 'goal points on the board at once (invalidated)')
H.eq(cjson.decode(goal.breakdown).period, 'daily', 'breakdown period')
Config.Goals = savedGoals

-- Manual award from the console with a 250-character accented reason: admin clips by characters, scoring
-- validates by characters (a byte check refused it as "at most 255 characters").
local accented = string.rep('é', 250)
H.eq(#accented, 500, '250 characters are 500 bytes')
command(0, 'award IFIB0004 25 ' .. accented)
local award = H.sql("SELECT * FROM cp_mission_runs WHERE mission_type = 'manual_award' AND citizenid = 'IFIB0004'")[1]
H.ok(award ~= nil, 'console award accepted with a long accented reason')
H.eq(award and award.season_id, seasonId, 'manual award carries the season id')
H.eq(award and award.department, 'fib', 'manual award carries the officer department')
H.eq(award and cjson.decode(award.breakdown).reason, accented, 'the full reason is kept in the breakdown')
local awardAudit = H.sql("SELECT actor, role, new_value, reason FROM cp_audit WHERE action = 'manualAward' ORDER BY id DESC LIMIT 1")[1]
H.eq(awardAudit and awardAudit.role, 'console', 'console award audited with role console')
H.eq(awardAudit and awardAudit.new_value, 25, 'audit new value = points')
H.eq(awardAudit and awardAudit.reason, accented, 'audit reason stored in full (VARCHAR(255) counts characters)')
H.eq(boardPoints(4), 75, 'manual award on the board at once')
local tooLong = string.rep('é', 256)
local okA, errA = CP.Scoring.manualAward(0, 'IFIB0004', 5, tooLong)
H.eq(okA, false, '256 characters refused')
H.eq(errA, 'err.reason_too_long', 'err.reason_too_long')

-- ════════════════════════════════════════════════════════════════════════════
-- 5. admin:getStuckPayments -> CP.Cash.stuckPayments()
-- ════════════════════════════════════════════════════════════════════════════
local stuckRow = insertRun({ cid = 'IFIB0004', dept = 'fib', amount = 1337, status = 'paying', uuid = 'stuck-0001' })
local res = cb('admin:getStuckPayments', 2)
H.eq(res.ok, false, 'supervisors cannot read stuck payments')
H.eq(res.error, 'err.no_permission', 'admin only')
res = cb('admin:getStuckPayments', 1)
H.eq(res.ok, true, 'admin reads stuck payments')
local payments = res.data and res.data.payments or {}
H.eq(#payments, 1, 'one row left in paying')
H.eq(payments[1] and payments[1].id, stuckRow, 'row id')
H.eq(payments[1] and payments[1].amount, 1337, 'amount from the breakdown')
H.eq(payments[1] and payments[1].transId, 'CP-stuck-0001-IFIB0004', 'transaction id for the Renewed-Banking check')
H.eq(payments[1] and payments[1].name, 'Fay Fed', 'officer name')
H.ok(type(res.data.serverTime) == 'number', 'serverTime')
H.sql("UPDATE cp_mission_runs SET cash_status = 'paid' WHERE id = ?", { stuckRow })

-- ════════════════════════════════════════════════════════════════════════════
-- 6. Payout reasons are counted in characters (the Payouts screens' maxLength)
-- ════════════════════════════════════════════════════════════════════════════
local reason200 = string.rep('ü', 200)
ok, data = act('server:sup:setTypePayout', 2, { type = 'patrol', amount = 300, reason = reason200 })
H.eq(ok, true, 'a 200-character accented reason is accepted')
local pAudit = H.sql("SELECT reason FROM cp_audit WHERE action = 'setTypePayout' ORDER BY id DESC LIMIT 1")[1]
H.eq(pAudit and pAudit.reason, reason200, 'audited with the full reason')
ok, data = act('server:admin:setTypePayout', 1, { type = 'patrol', amount = 350, reason = string.rep('ü', 256) })
H.eq(ok, false, '256 characters refused')
H.eq(data, 'err.reason_too_long', 'err.reason_too_long')

-- ════════════════════════════════════════════════════════════════════════════
-- 7. Profile canDispute = CP.Disputes.eligible (+ no dispute row yet)
-- ════════════════════════════════════════════════════════════════════════════
H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_disputes')
local pFlag = insertRun({ flagged = true, status = 'held' })
local pOld = insertRun({ flagged = true, status = 'held', created = H.time - 49 * 3600 })
local pDone = insertRun({})
local pFail = insertRun({ state = 'failed', final = 50 })
local pAward = insertRun({ type = 'manual_award', mission = 'manual_award' })
local pDisputed = insertRun({ voided = true, status = 'held' })
H.sql("INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to, status) VALUES (?, 'IOFF0003', 'x', 'supervisor', 'rejected')", { pDisputed })
local function disputeFlags()
    local out = {}
    local r = cb('getProfile', 3, nil)
    for _, run in ipairs(r.data.runs) do out[run.id] = run.canDispute end
    return out
end
local flags = disputeFlags()
H.eq(flags[pFlag], true, 'flagged row in the window: disputable')
H.eq(flags[pOld], false, 'outside the dispute window')
H.eq(flags[pDone], false, 'a clean completed row is not disputable')
H.eq(flags[pFail], true, 'failed row: disputable (goes to an admin)')
H.eq(flags[pAward], false, 'manual awards are never disputable')
H.eq(flags[pDisputed], false, 'a decided dispute is final')
for id, can in pairs(flags) do
    local row = rowOf(id)
    local okE = CP.Disputes.eligible({ citizenid = row.citizenid, mission_type = row.mission_type, state = row.state,
        flagged = row.flagged, voided = row.voided, created_ts = H.time - (id == pOld and 49 * 3600 or 0) }, 'IOFF0003', H.time)
    if id ~= pDisputed then H.eq(can, okE == true, 'the Profile follows CP.Disputes.eligible for row ' .. id) end
end
local realEligible = CP.Disputes.eligible
CP.Disputes.eligible = function() return false, 'err.dispute_window' end
H.eq(disputeFlags()[pFlag], false, 'canDispute is decided by CP.Disputes.eligible')
CP.Disputes.eligible = realEligible
H.eq(disputeFlags()[pFlag], true, 'and back')

-- ════════════════════════════════════════════════════════════════════════════
-- 8. Badge labels: the leaderboard's own badges are labelled in CP.Scoring.badges (Admin Officers screen)
-- ════════════════════════════════════════════════════════════════════════════
H.sql("INSERT INTO cp_badges (citizenid, badge_id, earned_at) VALUES ('IOFF0003', 'officer_of_week_2026-09-21', NOW()), ('IOFF0003', 'iron_wheels', NOW())")
local labels = {}
for _, b in ipairs(CP.Scoring.badges('IOFF0003')) do labels[b.id] = b.label end
H.eq(labels['officer_of_week_2026-09-21'], CP.L('profile.badge.officer_of_week', { week = '2026-09-21' }), 'Officer of the Week label from CP.Leaderboard')
H.eq(labels.iron_wheels, CP.L('badge.iron_wheels'), 'achievement badges keep their badge.<id> label')
H.ok(not tostring(labels['officer_of_week_2026-09-21']):find('^badge%.'), 'no raw locale key')
res = cb('admin:getOfficer', 1, { citizenid = 'IOFF0003' })
local officerBadges = {}
for _, b in ipairs(res.data.badges) do officerBadges[b.id] = b.label end
H.eq(officerBadges['officer_of_week_2026-09-21'], labels['officer_of_week_2026-09-21'], 'admin:getOfficer shows the same label')

-- ════════════════════════════════════════════════════════════════════════════
-- 9. /CrimsonPoliceAdmin test: archived custom missions through CP.Testing.resolveMission
-- ════════════════════════════════════════════════════════════════════════════
local testCalls = {}
CP.Alerts = { inArena = function() return false end }
CP.Testing = {
    resolveMission = function(id)
        if id == 'old_heist' then return { id = 'old_heist', label = 'Old Heist', status = 'archived', locations = { {}, {} } } end
        return nil, 'err.test_unknown_mission'
    end,
    command = function(src, words) testCalls[#testCalls + 1] = { src = src, words = words } return true, {} end,
}
command(1, 'test old_heist 2')
H.eq(#testCalls, 1, 'an archived custom mission can be tested from the command')
H.eq(testCalls[1] and testCalls[1].words[1], 'old_heist', 'mission id passed to CP.Testing.command')
H.eq(testCalls[1] and testCalls[1].words[2], '2', 'location passed')
H.eq(lastNote(1).key, 'admin.cmd.test_started', 'started toast')
command(1, 'test Old_Heist')
H.eq(#testCalls, 2, 'the id is matched case-insensitively')
command(1, 'test old_heist 3')
H.eq(#testCalls, 2, 'a location the archived mission does not have is refused')
H.eq(lastNote(1).key, 'err.invalid_location', 'err.invalid_location')
command(1, 'test nothing_here')
H.eq(lastNote(1).key, 'err.unknown_mission', 'unknown mission')
command(1, 'test gang_shootout heavy')
H.eq(testCalls[#testCalls].words[1], 'gang_shootout', 'a loaded mission still resolves through CP.Missions')
H.eq(testCalls[#testCalls].words[2], 'heavy', 'with its tier')

-- ════════════════════════════════════════════════════════════════════════════
-- 10. admin:getMissions (ARCHITECTURE §8.3): getMissionList + the Admin UI file/status extras, admin only
-- ════════════════════════════════════════════════════════════════════════════
DEFS.gang_shootout.filePath = 'missions/builtin/gang_shootout.lua'
DEFS.gang_shootout.defHash = 'abcd1234'
DEFS.gang_shootout.status = 'published'
Config.DisabledMissions = { 'beat_patrol' }
res = cb('admin:getMissions', 2)
H.eq(res.ok, false, 'supervisors cannot read admin:getMissions')
res = cb('admin:getMissions', 1)
H.eq(res.ok, true, 'admin reads admin:getMissions')
local byMission = {}
for _, m in ipairs(res.data.missions) do byMission[m.id] = m end
H.eq(byMission.gang_shootout and byMission.gang_shootout.filePath, 'missions/builtin/gang_shootout.lua', 'Lua file path')
H.eq(byMission.gang_shootout and byMission.gang_shootout.editedInCode, false, 'edited-in-code flag')
H.eq(byMission.gang_shootout and byMission.gang_shootout.defHash, 'abcd1234', 'definition hash')
H.eq(byMission.gang_shootout and byMission.gang_shootout.basePayout, CP.Payouts.baseFor(DEFS.gang_shootout), 'base payout from CP.Payouts')
H.eq(byMission.beat_patrol and byMission.beat_patrol.disabledInConfig, true, 'turned off in Config.DisabledMissions')
res = cb('getMissionList', 2)
H.eq(res.ok, true, 'supervisors keep getMissionList')
H.eq(res.data.missions[1].filePath, nil, 'without the admin extras')
Config.DisabledMissions = {}

-- ════════════════════════════════════════════════════════════════════════════
-- 11. Presence sampling uses the engine's own objective ctx (CP.Runs.ctx) when the engine provides it
-- ════════════════════════════════════════════════════════════════════════════
local seenCtx = {}
CP.Blocks.register('int_presence_probe', {
    presence = function(ctx, src, coords) seenCtx[#seenCtx + 1] = ctx; return ctx.distanceForTest or 10 end,
})
local pRun = {
    id = 'int-presence-run', missionId = 'gang_shootout', state = 'in_progress', order = { 3, 4 }, objectiveIndex = 1, seed = 7,
    mission = { id = 'gang_shootout', objectives = { { block = 'int_presence_probe', presenceRange = 150 } } },
    objectives = { { status = 'active', state = {}, obj = { block = 'int_presence_probe', presenceRange = 150 } } },
    location = { start = { coords = vec3(0.0, 0.0, 0.0), radius = 50.0 } },
    participants = {
        [3] = { src = 3, citizenid = 'IOFF0003', status = 'active' },
        [4] = { src = 4, citizenid = 'IFIB0004', status = 'active' },
    },
}
local engineCtx = { run = pRun, index = 1, obj = pRun.objectives[1].obj, state = pRun.objectives[1].state, distanceForTest = 400 }
CP.Runs.all = function() return { pRun } end
CP.Runs.activeSrcs = function(run) return { 3, 4 } end
CP.Runs.ctx = function(run, i) if run == pRun and i == 1 then return engineCtx end return nil end
CP.AntiCheat._sample(5)
H.eq(#seenCtx, 2, 'the block measured both participants')
H.ok(seenCtx[1] == engineCtx, 'with the engine ctx from CP.Runs.ctx')
H.eq(pRun.participants[3].presence and pRun.participants[3].presence.total, 5, 'sampled 5 s')
H.eq(pRun.participants[3].presence and pRun.participants[3].presence.inRange, 0, '400 m is outside the 150 m range')
CP.Runs.ctx = nil
seenCtx = {}
CP.AntiCheat._sample(5)
H.ok(seenCtx[1] ~= nil and seenCtx[1] ~= engineCtx and seenCtx[1].run == pRun, 'without CP.Runs.ctx: the read-only ctx')
H.eq(pRun.participants[3].presence.inRange, 5, 'the read-only ctx path measured 10 m (in range)')
CP.Runs.all = function() return {} end

-- ════════════════════════════════════════════════════════════════════════════
-- 12. Season names are 1-64 characters (admin clips by characters, challenge validates by characters)
-- ════════════════════════════════════════════════════════════════════════════
local seasonName = string.rep('Ü', 60)
command(0, 'season start ' .. seasonName)
local sRow = H.sql('SELECT name FROM cp_seasons WHERE active = 1 ORDER BY id DESC LIMIT 1')[1]
H.eq(sRow and sRow.name, seasonName, 'a 60-character accented season name (120 bytes) is accepted from the console')
H.eq(CP.Challenge.currentSeason().name, seasonName, 'current season')
local okS, errS = CP.Challenge.startSeason(0, string.rep('Ü', 65))
H.eq(okS, false, '65 characters refused')
H.eq(errS, 'err.invalid_season_name', 'err.invalid_season_name')

os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db))
_G.print = realPrint
return H
