-- tests/economy_spec.lua · modules/scoring, goals, cash, payouts (slice economy).
--
-- Other modules are stubbed (CP.Qbx, CP.Access, CP.Missions, CP.Draw, CP.Banking, CP.Tablet, CP.Admin,
-- CP.Events, CP.AntiCheat, CP.Challenge); modules/permissions, scaling and schedule are the real ones.
-- Every SQL statement of the slice runs against MariaDB. The spec uses its own database
-- (cp_test_economy, rebuilt from sql/migrations like cp_test) so other specs that reset cp_test in
-- parallel cannot interfere. The fake clock is aligned with the database clock (NOW()).

local REAL_NOW = os.time()
local H = dofile('tests/harness.lua')
H.db = 'cp_test_economy'
H.resetDatabase()
H.boot({ side = 'server' })
H.time = REAL_NOW

local cjson = require('cjson')

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
H.eq(CP.L('bonus.fast_finish'), 'Finished within 75% of the time limit', 'economy locale part loaded')

-- ── stubs ───────────────────────────────────────────────────────────────────
local DEPTS = {
    sast = { key = 'sast', label = 'San Andreas State Troopers', short = 'SAST', societyAccount = 'sast', jobs = { 'sast' } },
    fib = { key = 'fib', label = 'Federal Investigation Bureau', short = 'FIB', societyAccount = 'fib', jobs = { 'fib' } },
}
local JOB_DEPT = { sast = 'sast', fib = 'fib' }

-- src -> player; role: 'officer' | 'supervisor' | 'admin' | 'none'
local players = {}
local function addPlayer(src, cid, name, dept, role, onduty)
    players[src] = { src = src, citizenid = cid, name = name, dept = dept, role = role, onduty = onduty ~= false, rank = 'Sergeant', callsign = '2L-' .. src }
    H.players[src] = H.players[src] or {}
    H.players[src].ace = role == 'admin' and { ['crimsonpolice.admin'] = true } or {}
end

local qbxCalls = { addMoney = {} }
local addMoneyResult = true
local listeners = { duty = {}, job = {}, loaded = {}, unload = {} }
CP.Qbx = {
    getInfo = function(src)
        local p = players[tonumber(src)]
        if not p then return nil end
        return { src = p.src, citizenid = p.citizenid, name = p.name, job = { name = p.dept or 'unemployed', onduty = p.onduty, gradeLevel = 3, gradeName = p.rank }, callsign = p.callsign }
    end,
    getByCitizenId = function(cid)
        for src, p in pairs(players) do
            if p.citizenid == cid and not p.offline then return src end
        end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for src, p in pairs(players) do if not p.offline then out[#out + 1] = src end end
        table.sort(out)
        return out
    end,
    addMoney = function(src, account, amount, reason)
        qbxCalls.addMoney[#qbxCalls.addMoney + 1] = { src = src, account = account, amount = amount, reason = reason }
        return addMoneyResult
    end,
    onDutyChange = function(fn) table.insert(listeners.duty, fn) end,
    onJobChange = function(fn) table.insert(listeners.job, fn) end,
    onPlayerLoaded = function(fn) table.insert(listeners.loaded, fn) end,
    onPlayerUnload = function(fn) table.insert(listeners.unload, fn) end,
}

CP.Access = {
    isAdmin = function(src)
        src = tonumber(src)
        if src == 0 then return true end
        local p = players[src]
        return p ~= nil and p.role == 'admin'
    end,
    getOfficer = function(src)
        local p = players[tonumber(src)]
        if not p or not p.dept then return nil, 'err.not_police' end
        if not p.onduty then return nil, 'err.not_on_duty' end
        local d = DEPTS[p.dept]
        return {
            src = p.src, citizenid = p.citizenid, name = p.name, department = p.dept, departmentLabel = d.label,
            departmentShort = d.short, job = p.dept, rank = p.rank, gradeLevel = 3, callsign = p.callsign, onduty = true,
            isSupervisor = p.role == 'supervisor' or p.role == 'admin', isAdmin = p.role == 'admin',
        }
    end,
    department = function(key)
        local d = DEPTS[key]
        if not d then return nil end
        return { key = d.key, label = d.label, short = d.short, societyAccount = d.societyAccount }
    end,
    departmentForJob = function(job) return JOB_DEPT[job] end,
}
CP.Access.isSupervisor = function(src)
    local p = players[tonumber(src)]
    return p ~= nil and p.dept ~= nil and p.onduty and (p.role == 'supervisor' or p.role == 'admin')
end

local banking = { deposits = {}, withdraws = {}, societyRecords = {}, refunds = {} }
local societyOk = true
CP.Banking = {
    recordDeposit = function(cid, amount, message, issuer, receiver, transId)
        banking.deposits[#banking.deposits + 1] = { cid = cid, amount = amount, message = message, issuer = issuer, receiver = receiver, transId = transId }
        return true
    end,
    withdrawSociety = function(account, amount)
        banking.withdraws[#banking.withdraws + 1] = { account = account, amount = amount }
        return societyOk
    end,
    recordSocietyWithdraw = function(account, amount, message, issuer, receiver, transId)
        banking.societyRecords[#banking.societyRecords + 1] = { account = account, amount = amount, message = message, issuer = issuer, receiver = receiver, transId = transId }
        return true
    end,
    societyBalance = function() return 100000 end,
}

local notes, many, pushes = {}, {}, {}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } return true end,
    notifyMany = function(srcs, kind, key, vars) many[#many + 1] = { srcs = srcs, kind = kind, key = key, vars = vars } end,
    push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } return true end,
}
local audits = {}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = { actor = actor, role = role, category = category, action = action, target = target, old = old, new = new, reason = reason }
    end,
}

local function def(id, typ, diff, extra)
    local d = { id = id, label = extra and extra.label or id, type = typ, difficulty = diff, minOfficers = 1, maxOfficers = 4, timeLimit = 600,
        source = extra and extra.source or 'builtin', bonuses = extra and extra.bonuses or {}, penalties = extra and extra.penalties or {},
        vehiclePenalties = not (extra and extra.vehiclePenalties == false), objectives = { {}, {} } }
    if extra and extra.isBoss then d.isBoss = true end
    return d
end
local DEFS = {
    beat_patrol = def('beat_patrol', 'patrol', 1, { label = 'Beat Patrol' }),
    evoc_course = def('evoc_course', 'training', 2, { label = 'EVOC Course' }),
    manhunt = def('manhunt', 'investigation', 2, { label = 'Manhunt', bonuses = { { id = 'no_weapons_fired', points = 10 } } }),
    gang_shootout = def('gang_shootout', 'tactical', 3, { label = 'Gang Shootout', vehiclePenalties = false,
        bonuses = { { id = 'no_participant_downed', pctOfPoints = 0.10 }, { id = 'hostile_arrested', points = 5, each = true } } }),
    bomb_disposal = def('bomb_disposal', 'tactical', 2, { label = 'Bomb Disposal', bonuses = { { id = 'no_missed_checks', points = 15 } } }),
    business_check = def('business_check', 'patrol', 1, { label = 'Business Check',
        bonuses = { { id = 'correct_log' } }, penalties = { { id = 'wrong_log', points = -5, each = true } } }),
    weekly_boss_kingpin = def('weekly_boss_kingpin', 'tactical', 3, { label = 'Weekly Boss: Kingpin', isBoss = true, vehiclePenalties = false,
        bonuses = { { id = 'no_participant_downed', pctOfPoints = 0.10 } } }),
    custom_heist = def('custom_heist', 'tactical', 2, { label = 'Custom Heist', source = 'custom' }),
}
CP.Missions = {
    get = function(id) return DEFS[id] end,
    list = function()
        local out = {}
        for _, d in pairs(DEFS) do out[#out + 1] = d end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    isEnabled = function(id) return DEFS[id] ~= nil end,
    byType = function(t)
        local out = {}
        for _, d in pairs(DEFS) do if d.type == t and not d.isBoss then out[#out + 1] = d end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
}
CP.Draw = { pool = function(t, members) return CP.Missions.byType(t) end }

local tod = nil
CP.Events = { typeOfTheDay = function() return tod end }
local presence = true
CP.AntiCheat = { presenceOk = function() return presence end }
local season = { id = 3, name = 'Season 3' }
CP.Challenge = { currentSeason = function() return season end }

H.load('modules/scaling/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/payouts/server.lua')
H.load('modules/cash/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/goals/server.lua')

H.ok(#listeners.duty == 1 and #listeners.job == 1 and #listeners.unload == 1, 'scoring registered duty/job/unload listeners')
H.eq(#listeners.loaded, 2, 'cash and scoring registered player-loaded listeners')

-- players
addPlayer(1, 'CPOFF001', 'John Doe', 'sast', 'officer')
addPlayer(2, 'CPSUP001', 'Maria Lopez', 'sast', 'supervisor')
addPlayer(3, 'CPADM001', 'Server Admin', nil, 'admin')
addPlayer(4, 'CPFIB001', 'Dana Whitfield', 'fib', 'officer')
addPlayer(6, 'CPSUP002', 'Ray Chen', 'fib', 'supervisor')

local function officerRow(cid, name, dept)
    MySQL.query.await('INSERT INTO cp_officers (citizenid, display_name, department) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE display_name = VALUES(display_name), department = VALUES(department)', { cid, name, dept })
end
officerRow('CPOFF001', 'John Doe', 'sast')
officerRow('CPSUP001', 'Maria Lopez', 'sast')
officerRow('CPFIB001', 'Dana Whitfield', 'fib')

local function rowOf(id) return H.sql('SELECT * FROM cp_mission_runs WHERE id = ?', { id })[1] end
local function bd(id) return cjson.decode(rowOf(id).breakdown) end

-- A cp_mission_runs row. o = { cid, type, mission, state, status, amount, flagged, voided, created, participants, depts, final, dept, bonuses }
local function insertRun(o)
    local breakdown = o.breakdown or {
        runId = o.uuid or 'uuid-' .. tostring(math.random(1, 1e9)), missionLabel = o.label or 'Gang Shootout', missionType = o.type or 'tactical',
        result = o.state or 'completed',
        points = { P = 200, bonuses = o.bonuses or {}, penalties = {}, final = o.final or 0 },
        cash = { B = 800, mTier = 1.3, mMod = 1, amount = o.amount or 1040, status = o.status or 'none' },
    }
    return MySQL.insert.await([[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, final_points, cash_base, cash_multiplier, cash_paid,
            cash_status, breakdown, flagged, voided, created_at)
        VALUES (?, ?, ?, ?, ?, NULLIF(?, 0), ?, ?, 'standard', ?, ?, 200, ?, 800, 1.30, 0, ?, ?, ?, ?, FROM_UNIXTIME(?))
    ]], { o.uuid or ('uuid-%d'):format(math.random(1, 1e9)), o.type or 'tactical', o.mission or 'gang_shootout', o.cid or 'CPOFF001',
        o.dept or 'sast', o.season or 3, o.participants or 1, o.depts or 1, o.state or 'completed',
        o.state == 'failed' and 'time_limit' or 'completed', o.final or 0, o.status or 'none', cjson.encode(breakdown),
        o.flagged and 1 or 0, o.voided and 1 or 0, o.created or H.time })
end

local function actionReply(src)
    local ev = H.findEvents('crimson-police:client:actionResult')
    for i = #ev, 1, -1 do
        if ev[i].target == src then return ev[i].args[2], ev[i].args[3] end
    end
    return nil
end

local function tick() H.clockMs = H.clockMs + 1500 end

-- ═══════════════════════════════════════════════════════════════════════════
-- Payouts
-- ═══════════════════════════════════════════════════════════════════════════
H.sql('DELETE FROM cp_type_payouts')
H.sql('DELETE FROM cp_mission_payouts')
H.sql('DELETE FROM cp_audit')
CP.Payouts._reload()

local amt, locked = CP.Payouts.typePayout('patrol')
H.eq(amt, 250, 'patrol default payout')
H.eq(locked, false, 'patrol not locked')
H.eq(CP.Payouts.baseFor(DEFS.gang_shootout), 800, 'B = tactical payout x 1.0 stars')
H.eq(CP.Payouts.sourceFor(DEFS.gang_shootout), 'type', 'type source')
H.eq(CP.Payouts.baseFor(DEFS.weekly_boss_kingpin), 2500, 'boss B = event payout')
H.eq(CP.Payouts.sourceFor(DEFS.weekly_boss_kingpin), 'event', 'boss source = event')
Config.Difficulty.cashByStars = { 1.0, 1.0, 1.5 }
H.eq(CP.Payouts.baseFor(DEFS.gang_shootout), 1200, 'star multiplier from config at call time')
Config.Difficulty.cashByStars = { 1.0, 1.0, 1.0 }

local lo, hi = CP.Payouts._supervisorRange('patrol')
H.eq(lo, 125, 'supervisor min 50%')
H.eq(hi, 500, 'supervisor max 200%')

-- supervisor changes
local ok, res = CP.Payouts.setType(2, 'patrol', 300, 'More patrols needed', 'supervisor')
H.ok(ok, 'supervisor may set patrol within range')
H.eq(res.amount, 300, 'returned entry amount')
H.eq(res.adminLocked, false, 'supervisor value is not locked')
H.ok(res.cooldownLeft > 1700, 'cooldown started')
local tp = H.sql('SELECT amount, admin_locked, updated_by FROM cp_type_payouts WHERE mission_type = ?', { 'patrol' })[1]
H.eq(tp.amount, 300, 'stored amount')
H.eq(tp.admin_locked, 0, 'stored unlocked')
H.eq(tp.updated_by, 'CPSUP001', 'stored updated_by citizenid')
H.eq(audits[#audits].action, 'setTypePayout', 'audited')
H.eq(audits[#audits].role, 'supervisor', 'audit role')
H.eq(audits[#audits].old, '250', 'audit old value')
H.eq(audits[#audits].new, '300', 'audit new value')
H.eq(audits[#audits].reason, 'More patrols needed', 'audit reason')
H.eq(audits[#audits].category, 'audit', 'audit category')
H.ok(#pushes > 0 and pushes[#pushes].topic == 'board', 'pushes sent')
local sawPayouts = false
for _, p in ipairs(pushes) do if p.topic == 'payouts' then sawPayouts = true end end
H.ok(sawPayouts, 'payouts topic pushed')
H.eq(CP.Payouts.typePayout('patrol'), 300, 'cache updated')
H.eq(CP.Payouts.baseFor(DEFS.beat_patrol), 300, 'base follows the type payout')

ok, res = CP.Payouts.setType(2, 'patrol', 320, 'again', 'supervisor')
H.eq(res, 'err.payout_cooldown', 'supervisor cooldown per type')
ok, res = CP.Payouts.setType(6, 'patrol', 320, 'another supervisor', 'supervisor')
H.eq(res, 'err.payout_cooldown', 'cooldown applies to any supervisor')
ok, res = CP.Payouts.setType(2, 'tactical', 2000, 'too much', 'supervisor')
H.eq(res, 'err.payout_out_of_range', 'above 200%')
ok, res = CP.Payouts.setType(2, 'tactical', 300, 'too little', 'supervisor')
H.eq(res, 'err.payout_out_of_range', 'below 50%')
ok, res = CP.Payouts.setType(2, 'tactical', 900, '', 'supervisor')
H.eq(res, 'err.reason_required', 'supervisor reason required')
ok, res = CP.Payouts.setType(2, 'tactical', 900, string.rep('x', 256), 'supervisor')
H.eq(res, 'err.reason_too_long', 'reason max 255')
ok, res = CP.Payouts.setType(2, 'tactical', nil, 'clear', 'supervisor')
H.eq(res, 'err.invalid_amount', 'supervisors cannot clear')
ok, res = CP.Payouts.setType(2, 'tactical', 900.5, 'fraction', 'supervisor')
H.eq(res, 'err.invalid_amount', 'whole dollars only')
ok, res = CP.Payouts.setType(1, 'tactical', 900, 'officer', 'supervisor')
H.eq(res, 'err.no_permission', 'officers cannot change payouts')
ok, res = CP.Payouts.setType(2, 'nope', 900, 'x', 'supervisor')
H.eq(res, 'err.unknown_type', 'unknown type')
ok, res = CP.Payouts.setType(2, 'tactical', 900, 'x', 'admin')
H.eq(res, 'err.no_permission', 'the admin path needs an admin')
ok, res = CP.Payouts.setType(2, 'tactical', 800, 'same', 'supervisor')
H.eq(res, 'err.payout_unchanged', 'unchanged value refused')
Config.Permissions.supervisor.setTypePayout = false
ok, res = CP.Payouts.setType(2, 'tactical', 900, 'switched off', 'supervisor')
H.eq(res, 'err.no_permission', 'Config.Permissions switch read at call time')
Config.Permissions.supervisor.setTypePayout = true

-- cooldown over (updated_at 31 min ago)
H.sql('UPDATE cp_type_payouts SET updated_at = FROM_UNIXTIME(?) WHERE mission_type = ?', { H.time - 1860, 'patrol' })
CP.Payouts._reload()
ok, res = CP.Payouts.setType(6, 'patrol', 280, 'cooldown over', 'supervisor')
H.ok(ok, 'change allowed after the cooldown')

-- admin changes
ok, res = CP.Payouts.setType(3, 'investigation', 750, 'Investigations are long', 'admin')
H.ok(ok, 'admin sets a type payout')
H.eq(res.adminLocked, true, 'admin payout locks the type')
ok, res = CP.Payouts.setType(2, 'investigation', 700, 'try', 'supervisor')
H.eq(res, 'err.payout_locked', 'supervisor cannot change an admin-set type')
ok, res = CP.Payouts.setType(3, 'investigation', 30000, 'too much', 'admin')
H.eq(res, 'err.payout_out_of_range', 'admin bound by the overall range')
ok, res = CP.Payouts.setType(3, 'investigation', 25000, 'max', 'admin')
H.ok(ok, 'admin may set up to maxPayout')
ok, res = CP.Payouts.setType(3, 'investigation', 25000, 'max again', 'admin')
H.eq(res, 'err.payout_unchanged', 'admin unchanged refused')
ok, res = CP.Payouts.setType(0, 'investigation', 900, 'console', 'admin')
H.ok(ok, 'console (src 0) is an admin')
H.eq(audits[#audits].role, 'console', 'console audit role')
ok, res = CP.Payouts.setType(3, 'investigation', nil, 'back to config', 'admin')
H.ok(ok, 'admin clears a type payout')
H.eq(#H.sql('SELECT * FROM cp_type_payouts WHERE mission_type = ?', { 'investigation' }), 0, 'row deleted')
H.eq(select(2, CP.Payouts.typePayout('investigation')), false, 'unlocked after clear')
H.eq(CP.Payouts.typePayout('investigation'), 600, 'config payout after clear')
H.eq(audits[#audits].action, 'clearTypePayout', 'clear audited')
ok, res = CP.Payouts.setType(3, 'investigation', nil, 'again', 'admin')
H.eq(res, 'err.payout_unchanged', 'nothing to clear')

-- mission payouts
ok, res = CP.Payouts.setMission(3, 'gang_shootout', 1200, 'Hardest Tactical draw')
H.ok(ok, 'admin sets a mission payout')
H.eq(res.base, 1200, 'mission entry base')
H.eq(res.payoutSource, 'admin', 'mission entry source')
H.eq(CP.Payouts.missionPayout('gang_shootout'), 1200, 'missionPayout')
H.eq(CP.Payouts.baseFor(DEFS.gang_shootout), 1200, 'mission payout overrides the type')
H.eq(CP.Payouts.sourceFor(DEFS.gang_shootout), 'admin', 'admin source')
ok = CP.Payouts.setType(3, 'tactical', 1000, 'type change', 'admin')
H.ok(ok, 'tactical type set')
H.eq(CP.Payouts.baseFor(DEFS.gang_shootout), 1200, 'a mission with an admin payout ignores type changes')
H.eq(CP.Payouts.baseFor(DEFS.bomb_disposal), 1000, 'other tactical missions follow the type')
ok, res = CP.Payouts.setMission(2, 'gang_shootout', 1300, 'supervisor')
H.eq(res, 'err.no_permission', 'supervisors never set mission payouts')
ok, res = CP.Payouts.setMission(3, 'no_such_mission', 1300, 'x')
H.eq(res, 'err.unknown_mission', 'unknown mission')
ok, res = CP.Payouts.setMission(3, 'bad id!', 1300, 'x')
H.eq(res, 'err.unknown_mission', 'invalid mission id')
ok, res = CP.Payouts.setMission(3, 'weekly_boss_kingpin', 3000, 'Boss pays more')
H.ok(ok, 'boss mission payout')
H.eq(CP.Payouts.baseFor(DEFS.weekly_boss_kingpin), 3000, 'boss uses the admin mission payout')
ok, res = CP.Payouts.setMission(3, 'weekly_boss_kingpin', nil, 'back to event')
H.ok(ok, 'clear boss payout')
H.eq(CP.Payouts.baseFor(DEFS.weekly_boss_kingpin), 2500, 'boss back to the event payout')
-- a stored payout for a mission that is not loaded
MySQL.query.await("INSERT INTO cp_mission_payouts (mission_id, amount, set_by) VALUES ('old_bank_job', 1500, 'CPADM001')", {})
CP.Payouts._reload()
local list = CP.Payouts.list()
H.eq(#list.types, 4, 'four types')
H.eq(list.types[1].key, 'patrol', 'types sorted by points')
H.eq(list.types[4].key, 'tactical', 'tactical last')
H.eq(list.types[4].missions, 3, 'tactical mission count excludes the boss')
local missing, bossEntry, gangEntry
for _, m in ipairs(list.missions) do
    if m.id == 'old_bank_job' then missing = m end
    if m.id == 'weekly_boss_kingpin' then bossEntry = m end
    if m.id == 'gang_shootout' then gangEntry = m end
end
H.ok(missing and missing.missing == true, 'stale mission payout listed as missing')
H.eq(bossEntry.payoutSource, 'event', 'boss entry source')
H.eq(bossEntry.isBoss, true, 'boss flagged')
H.eq(list.missions[#list.missions].id, 'weekly_boss_kingpin', 'boss sorted after the type missions')
H.eq(gangEntry.fallback, 1000, 'fallback = type payout')
H.eq(gangEntry.setBy, 'CPADM001', 'setBy')
ok, res = CP.Payouts.setMission(3, 'old_bank_job', nil, 'cleanup')
H.ok(ok, 'a stale mission payout can be cleared')
ok, res = CP.Payouts.setMission(3, 'old_bank_job', 100, 'x')
H.eq(res, 'err.unknown_mission', 'no new payout for a mission that is not loaded')

-- callbacks and actions
local r = H.callback('crimson-police:sup:getPayouts', 2)
H.eq(r.ok, true, 'sup:getPayouts ok for a supervisor')
H.eq(#r.data.types, 4, 'sup view types')
H.eq(r.data.types[1].min, 125, 'sup view min')
H.eq(r.data.rangeShare.max, 2.0, 'sup view range share')
H.eq(r.data.cooldownSeconds, 1800, 'sup view cooldown')
r = H.callback('crimson-police:sup:getPayouts', 1)
H.eq(r.error, 'err.no_permission', 'officers cannot open supervisor payouts')
r = H.callback('crimson-police:admin:getPayouts', 2)
H.eq(r.error, 'err.no_permission', 'supervisors cannot open admin payouts')
r = H.callback('crimson-police:admin:getPayouts', 3)
H.eq(r.ok, true, 'admin view')
H.ok(#r.data.missions >= 8, 'admin view missions')
H.eq(r.data.limits.max, 25000, 'admin view limits')

tick()
H.fire('crimson-police:server:sup:setTypePayout', 2, { type = 'training', amount = 420, reason = 'EVOC demand' }, 'r1')
local okA, dataA = actionReply(2)
H.eq(okA, true, 'sup action ok')
H.eq(dataA.amount, 420, 'sup action returns the entry')
H.eq(dataA.canEdit, false, 'no edit during the cooldown')
tick()
H.fire('crimson-police:server:sup:setTypePayout', 2, { type = 'training', amount = 'lots', reason = 'x' }, 'r2')
okA, dataA = actionReply(2)
H.eq(okA, false, 'bad payload refused')
H.eq(dataA, 'err.invalid_payload', 'invalid payload key')
tick()
H.fire('crimson-police:server:admin:setTypePayout', 3, { type = 'training', amount = 500, reason = 'admin' }, 'r3')
okA, dataA = actionReply(3)
H.eq(okA, true, 'admin action set')
H.eq(dataA.adminLocked, true, 'admin action locks')
tick()
H.fire('crimson-police:server:admin:setTypePayout', 3, { type = 'training', amount = nil, clear = true, reason = 'clear' }, 'r4')
okA = actionReply(3)
H.eq(okA, true, 'admin action clear')
H.eq(CP.Payouts.typePayout('training'), 350, 'training back to config')
tick()
H.fire('crimson-police:server:admin:setMissionPayout', 3, { missionId = 'manhunt', amount = 900, reason = 'x' }, 'r5')
okA, dataA = actionReply(3)
H.eq(okA, true, 'mission action')
H.eq(dataA.missionPayout, 900, 'mission action entry')
tick()
H.fire('crimson-police:server:admin:setMissionPayout', 2, { missionId = 'manhunt', amount = 950, reason = 'x' }, 'r6')
okA, dataA = actionReply(2)
H.eq(dataA, 'err.no_permission', 'supervisor refused on the admin mission action')

-- fallback audit straight to cp_audit when modules/admin is missing
local savedAdmin = CP.Admin
CP.Admin = nil
H.sql('DELETE FROM cp_audit')
ok = CP.Payouts.setMission(3, 'manhunt', 950, 'fallback audit')
H.ok(ok, 'set without modules/admin')
local au = H.sql('SELECT actor, role, category, action, target, old_value, new_value, reason FROM cp_audit')[1]
H.eq(au.action, 'setMissionPayout', 'fallback audit row')
H.eq(au.actor, 'CPADM001', 'fallback audit actor')
H.eq(au.old_value, 900, 'fallback audit old')
H.eq(au.new_value, 950, 'fallback audit new')
CP.Admin = savedAdmin
CP.Payouts.setMission(3, 'manhunt', nil, 'cleanup')
CP.Payouts.setMission(3, 'gang_shootout', nil, 'cleanup')
CP.Payouts.setType(3, 'tactical', nil, 'cleanup', 'admin')
CP.Payouts.setType(3, 'patrol', nil, 'cleanup', 'admin')
H.eq(CP.Payouts.baseFor(DEFS.gang_shootout), 800, 'cleaned up')

-- ═══════════════════════════════════════════════════════════════════════════
-- Cash
-- ═══════════════════════════════════════════════════════════════════════════
local heavy = CP.Scaling.tierByName('heavy')
local function fakeRun(o)
    o = o or {}
    local run = {
        id = o.id or 'run-1', mission = o.mission or DEFS.gang_shootout, missionId = (o.mission or DEFS.gang_shootout).id,
        missionType = o.missionType or (o.mission or DEFS.gang_shootout).type, cashBase = o.cashBase or 800,
        pointsBase = o.pointsBase, payTier = o.payTier or CP.Scaling.tierByName('standard'), modifier = o.modifier,
        order = o.order or { 1 }, participants = {}, stats = { downs = o.downs or 0, weaponsFired = o.fired or 0 },
        score = { shared = o.shared or {}, values = o.values or {}, kinds = o.kinds or {} }, flags = { medals = o.medals or false },
        flagged = o.flagged, test = o.test, timeLimit = o.timeLimit or 600, startedAt = H.time - (o.duration or 300), endedAt = H.time,
        objectives = o.objectives,
    }
    return run
end
local function fakeP(o)
    o = o or {}
    return {
        src = o.src or 1, citizenid = o.cid or 'CPOFF001', department = o.dept or 'sast', status = 'active', result = o.result,
        score = o.score or {}, vehicle = o.vehicle or { engine = 1000, body = 1000, seen = false },
        firstRunSinceDuty = o.first == true, flagged = o.flagged,
    }
end

local amount, cb = CP.Cash.compute(fakeRun({ payTier = heavy, modifier = 'time_crunch' }), fakeP({ result = 'completed' }))
H.eq(amount, 1300, 'B 800 x heavy 1.30 x modifier 1.25')
H.eq(cb.B, 800, 'breakdown B')
H.near(cb.mTier, 1.30, 1e-9, 'breakdown mTier')
H.near(cb.mMod, 1.25, 1e-9, 'breakdown mMod')
H.eq(cb.status, 'none', 'status none')
amount, cb = CP.Cash.compute(fakeRun({ payTier = heavy }), fakeP({ result = 'completed' }))
H.eq(amount, 1040, 'spec example: heavy Gang Shootout pays $1,040')
amount, cb = CP.Cash.compute(fakeRun(), fakeP({ result = 'failed' }))
H.eq(amount, 0, 'failed pays 0')
amount, cb = CP.Cash.compute(fakeRun(), fakeP({ result = 'abandoned' }))
H.eq(amount, 0, 'abandoned pays 0')
amount, cb = CP.Cash.compute(fakeRun({ flagged = { reason = 'outside_help' } }), fakeP({ result = 'completed' }))
H.eq(cb.status, 'held', 'flagged run is held')
H.eq(amount, 800, 'flagged keeps its amount (held)')
amount, cb = CP.Cash.compute(fakeRun({ test = { adminSrc = 3 } }), fakeP({ result = 'completed', flagged = { reason = 'x' } }))
H.eq(cb.status, 'none', 'test runs are never held')
presence = false
amount = CP.Cash.compute(fakeRun({ order = { 1, 4 } }), fakeP({ result = 'completed' }))
H.eq(amount, 0, 'presence failed -> $0')
amount = CP.Cash.compute(fakeRun({ order = { 1 } }), fakeP({ result = 'completed' }))
H.eq(amount, 800, 'presence only counts in runs with 2+ participants')
presence = true

-- pay: online officer, bank account
H.sql('DELETE FROM cp_mission_runs')
qbxCalls.addMoney, banking.deposits = {}, {}
local id1 = insertRun({ uuid = 'aaaa-1111', amount = 1040 })
local st = CP.Cash.pay(id1)
H.eq(st, 'paid', 'paid')
local row = rowOf(id1)
H.eq(row.cash_status, 'paid', 'row paid')
H.eq(row.cash_paid, 1040, 'cash_paid')
H.eq(bd(id1).cash.status, 'paid', 'breakdown status updated')
H.eq(#qbxCalls.addMoney, 1, 'one AddMoney')
H.eq(qbxCalls.addMoney[1].account, 'bank', 'Config.Cash.account')
H.eq(qbxCalls.addMoney[1].amount, 1040, 'amount')
H.eq(qbxCalls.addMoney[1].reason, 'crimson-police-mission', 'reason')
H.eq(#banking.deposits, 1, 'bank deposit recorded')
H.eq(banking.deposits[1].cid, 'CPOFF001', 'deposit account = citizenid')
H.eq(banking.deposits[1].message, 'Mission payout: Gang Shootout', 'deposit message')
H.eq(banking.deposits[1].issuer, 'San Andreas State Troopers', 'deposit issuer = department label')
H.eq(banking.deposits[1].receiver, 'John Doe', 'deposit receiver = character name')
H.eq(banking.deposits[1].transId, 'CP-aaaa-1111-CPOFF001', 'transaction id')
H.eq(#banking.withdraws, 0, 'server source: no society withdrawal')
H.eq(notes[#notes].key, 'cash.paid', 'officer notified')
H.eq(CP.Cash.pay(id1), 'paid', 'a final row is never paid again')
H.eq(#qbxCalls.addMoney, 1, 'still one AddMoney')

-- cash account: no Renewed-Banking deposit entry
Config.Cash.account = 'cash'
local idc = insertRun({ amount = 500 })
H.eq(CP.Cash.pay(idc), 'paid', 'cash account paid')
H.eq(qbxCalls.addMoney[#qbxCalls.addMoney].account, 'cash', 'cash account used')
H.eq(#banking.deposits, 1, 'no bank history entry for cash payouts')
Config.Cash.account = 'bank'

-- offline -> pending -> paid on login
players[1].offline = true
local id2 = insertRun({ uuid = 'bbbb-2222', amount = 900 })
H.eq(CP.Cash.pay(id2), 'pending', 'offline officer -> pending')
H.eq(rowOf(id2).cash_status, 'pending', 'row pending')
H.eq(bd(id2).cash.status, 'pending', 'breakdown pending')
H.eq(CP.Cash.pay(id2), 'pending', 'still pending while offline')
players[1].offline = false
local before = #qbxCalls.addMoney
CreateThread(function() CP.Cash._onLoaded(1) end)
H.eq(#qbxCalls.addMoney, before, 'pending payment waits a few seconds after login')
H.advance(6000, 500)
H.eq(rowOf(id2).cash_status, 'paid', 'pending row paid after login')
H.eq(#qbxCalls.addMoney, before + 1, 'paid once')

-- AddMoney fails -> back to pending
addMoneyResult = false
local id3 = insertRun({ amount = 700 })
H.eq(CP.Cash.pay(id3), 'pending', 'AddMoney false -> pending')
H.eq(rowOf(id3).cash_status, 'pending', 'row back to pending')
addMoneyResult = true
H.eq(CP.Cash.payPending(1), 1, 'payPending pays it')
H.eq(rowOf(id3).cash_status, 'paid', 'paid now')

-- daily cap per reset-day
H.sql('DELETE FROM cp_mission_runs')
Config.Cash.dailyCap = 1500
local c1 = insertRun({ amount = 1040 })
H.eq(CP.Cash.pay(c1), 'paid', 'under the cap')
local c2 = insertRun({ amount = 1040 })
H.eq(CP.Cash.pay(c2), 'capped', 'over the cap -> capped')
H.eq(rowOf(c2).cash_paid, 460, 'paid up to the cap')
local c3 = insertRun({ amount = 300 })
H.eq(CP.Cash.pay(c3), 'capped', 'cap reached -> capped at 0')
H.eq(rowOf(c3).cash_paid, 0, 'nothing paid')
local cy = insertRun({ amount = 1040, created = CP.Schedule.dayStart(H.time) - 3600 })
H.eq(CP.Cash.pay(cy), 'paid', 'a row of the previous reset-day has its own cap')
Config.Cash.dailyCap = 0
H.eq(CP.Cash.earnedThisWeek('CPOFF001') >= 1500, true, 'earnedThisWeek sums paid and capped rows')

-- society source
Config.Cash.source = 'society'
banking.withdraws, banking.societyRecords, many = {}, {}, {}
societyOk = false
local s1 = insertRun({ uuid = 'cccc-3333', amount = 1040 })
H.eq(CP.Cash.pay(s1), 'unfunded', 'society account cannot cover -> unfunded')
H.eq(rowOf(s1).cash_paid, 0, 'unfunded pays $0')
H.eq(banking.withdraws[1].account, 'sast', 'withdrawn from the department society account')
H.eq(notes[#notes].key, 'cash.unfunded', 'officer told')
H.eq(many[#many].key, 'cash.unfunded_supervisor', 'supervisors told')
H.eq(#many[#many].srcs, 1, 'only online supervisors of that department')
H.eq(many[#many].srcs[1], 2, 'the SAST supervisor')
H.eq(CP.Cash.pay(s1), 'unfunded', 'unfunded is final')
societyOk = true
local s2 = insertRun({ uuid = 'dddd-4444', amount = 1040 })
H.eq(CP.Cash.pay(s2), 'paid', 'society funded payout')
H.eq(#banking.societyRecords, 1, 'society withdraw recorded')
H.eq(banking.societyRecords[1].transId, 'CP-dddd-4444-CPOFF001', 'same transaction id on the society side')
-- society withdrawn, then AddMoney fails and there is no refund call -> stays paying (manual check)
addMoneyResult = false
local s3 = insertRun({ uuid = 'eeee-5555', amount = 600 })
H.eq(CP.Cash.pay(s3), 'paying', 'no refund possible -> the row stays paying')
local stuck = CP.Cash.stuckPayments()
H.eq(#stuck, 1, 'listed as a stuck payment')
H.eq(stuck[1].transId, 'CP-eeee-5555-CPOFF001', 'stuck payment transaction id')
H.eq(stuck[1].name, 'John Doe', 'stuck payment officer name')
H.eq(stuck[1].amount, 600, 'stuck payment amount')
H.eq(CP.Cash.pay(s3), 'paying', 'a paying row is never retried automatically')
CP.Banking.depositSociety = function(account, amount) banking.refunds[#banking.refunds + 1] = { account, amount } return true end
local s4 = insertRun({ amount = 650 })
H.eq(CP.Cash.pay(s4), 'pending', 'with a refund call the row goes back to pending')
H.eq(#banking.refunds, 1, 'society refunded')
CP.Banking.depositSociety = nil
addMoneyResult = true
Config.Cash.source = 'server'

-- flagged / held / release / void / forfeit
H.sql('DELETE FROM cp_mission_runs')
local f1 = insertRun({ status = 'held', flagged = true, amount = 1040 })
H.eq(CP.Cash.pay(f1), nil, 'a flagged row is never paid')
H.eq(rowOf(f1).cash_status, 'held', 'still held')
H.eq(CP.Cash.release(f1), nil, 'release refused while still flagged')
H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ?', { f1 })
H.eq(CP.Cash.release(f1), 'paid', 'approved -> released and paid')
local f2 = insertRun({ status = 'held', flagged = true, amount = 1040 })
H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ?', { f2 })
players[1].offline = true
H.eq(CP.Cash.release(f2), 'pending', 'approved while offline -> pending')
players[1].offline = false
local v1 = insertRun({ status = 'held', flagged = true, voided = true, amount = 1040 })
H.eq(CP.Cash.release(v1), nil, 'voided rows are not released')
H.eq(CP.Cash.forfeit(v1), true, 'forfeit a voided held row')
H.eq(rowOf(v1).cash_status, 'forfeited', 'forfeited')
H.eq(CP.Cash.pay(v1), 'forfeited', 'forfeited is final')
local v2 = insertRun({ status = 'held', flagged = true, amount = 1040 })
H.eq(CP.Cash.forfeit(v2), false, 'forfeit only voided rows')
local old1 = insertRun({ status = 'held', flagged = true, voided = true, created = H.time - 49 * 3600 })
local old2 = insertRun({ status = 'held', flagged = true, voided = true, created = H.time - 49 * 3600 })
local fresh = insertRun({ status = 'held', flagged = true, voided = true, created = H.time - 3600 })
MySQL.insert.await("INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to, status) VALUES (?, 'CPOFF001', 'not me', 'supervisor', 'open')", { old2 })
H.eq(CP.Cash._forfeitureJob(), 1, 'forfeiture job: one row past the window without an open dispute')
H.eq(rowOf(old1).cash_status, 'forfeited', 'old voided row forfeited')
H.eq(rowOf(old2).cash_status, 'held', 'open dispute keeps it held')
H.eq(rowOf(fresh).cash_status, 'held', 'inside the dispute window stays held')
local fa = insertRun({ state = 'failed', amount = 0 })
H.eq(CP.Cash.pay(fa), nil, 'failed rows are never paid')

-- board range
local officers4 = { CP.Access.getOfficer(1), CP.Access.getOfficer(2), CP.Access.getOfficer(4), CP.Access.getOfficer(6) }
local rlo, rhi = CP.Cash.range('tactical', officers4)
H.eq(rlo, 1040, 'range min: $800 x 1.30')
H.eq(rhi, 1300, 'range max covers a modifier: $800 x 1.30 x 1.25')
CP.Payouts.setMission(3, 'custom_heist', 1200, 'custom pays more')
rlo, rhi = CP.Cash.range('tactical', officers4)
H.eq(rhi, 1950, 'range covers admin payouts in the pool')
CP.Payouts.setMission(3, 'custom_heist', nil, 'cleanup')
rlo, rhi = CP.Cash.range('weekly_boss', { 1, 2 })
H.eq(rlo, 2875, 'boss range: $2,500 x reinforced 1.15')
H.eq(rhi, 2875, 'boss never rolls a modifier')
rlo, rhi = CP.Cash.range('patrol', { 1 })
H.eq(rlo, 250, 'solo patrol min')
H.eq(rhi, 313, 'solo patrol max with modifier (312.5 rounds up)')

-- ═══════════════════════════════════════════════════════════════════════════
-- Scoring
-- ═══════════════════════════════════════════════════════════════════════════
H.eq(CP.Scoring.P(DEFS.beat_patrol), 60, 'P patrol')
H.eq(CP.Scoring.P(DEFS.gang_shootout), 200, 'P tactical')
H.eq(CP.Scoring.P(DEFS.weekly_boss_kingpin), 500, 'P boss')
Config.Difficulty.pointsByStars = { 1.0, 1.0, 1.5 }
H.eq(CP.Scoring.P(DEFS.gang_shootout), 300, 'P with star multiplier')
Config.Difficulty.pointsByStars = { 1.0, 1.0, 1.0 }

H.sql('DELETE FROM cp_mission_runs')
H.sql("UPDATE cp_officers SET xp = 0, streak_days = 0, last_complete = NULL, grace_week = NULL, grace_used = 0")

local function find(list, id)
    for _, e in ipairs(list) do if e.id == id then return e end end
    return nil
end

-- completed solo Gang Shootout
local run = fakeRun({ shared = { hostile_arrested = 3 }, duration = 300 })
local p = fakeP({ result = 'completed', first = true, score = { pedestrian_hit = 1 }, vehicle = { engine = 990, body = 980, seen = true } })
local b = CP.Scoring.compute(run, p, 'completed', { durationS = 300, departments = 1 })
H.eq(b.P, 200, 'P')
H.eq(find(b.bonuses, 'no_participant_downed').points, 20, 'end-evaluated no_participant_downed = 10% of P')
H.eq(find(b.bonuses, 'hostile_arrested').points, 15, 'each x count')
H.eq(find(b.bonuses, 'hostile_arrested').label, 'Hostile arrested × 3', 'label with the count')
H.eq(find(b.bonuses, 'fast_finish').points, 40, 'fast finish +20% of P')
H.eq(find(b.bonuses, 'first_run').points, 15, 'first run +15')
H.eq(find(b.bonuses, 'no_vehicle_damage').points, 10, 'no vehicle damage +10')
H.eq(find(b.penalties, 'pedestrian_hit').points, -30, 'pedestrian hit -30')
H.eq(find(b.penalties, 'heavy_damage'), nil, 'no heavy damage')
H.eq(b.subtotal, 270, 'subtotal')
H.near(b.mTeam, 1.0, 1e-9, 'solo team multiplier')
H.near(b.mCross, 1.0, 1e-9, 'one department')
H.near(b.mStreak, 1.05, 1e-9, 'first streak day +5%')
H.eq(b.final, 283, '270 x 1.05 = 283.5 -> 283 (rounded down)')
H.eq(b.capped, false, 'not capped')
H.eq(b.tod, false, 'no ToD')
H.eq(b.failedShare, nil, 'no failed share')
H.eq(CP.Scoring.isFirstRunSinceDuty(1), false, 'first-run bonus used by the completed run')

-- team, cross-department, cap and Type of the Day after the cap
run = fakeRun({ payTier = heavy, modifier = 'time_crunch', shared = { hostile_arrested = 20 }, order = { 1, 4, 2 } })
p = fakeP({ result = 'completed' })
b = CP.Scoring.compute(run, p, 'completed', { durationS = 300, departments = 2 })
H.eq(find(b.bonuses, 'modifier').points, 50, 'modifier +25% of P')
H.eq(find(b.bonuses, 'modifier').label, 'Modifier: Time Crunch', 'modifier label')
H.near(b.mTeam, 1.15, 1e-9, 'heavy team multiplier from the pay tier')
H.near(b.mCross, 1.10, 1e-9, 'cross-department x1.10')
H.eq(b.capped, true, 'capped at 2P')
H.eq(b.final, 400, 'cap = 2 x P')
tod = 'tactical'
b = CP.Scoring.compute(run, p, 'completed', { durationS = 300, departments = 2 })
H.eq(b.tod, true, 'Type of the Day applies by run.missionType')
H.eq(b.final, 800, 'ToD doubles after the cap')
tod = 'patrol'
b = CP.Scoring.compute(run, p, 'completed', { durationS = 300, departments = 2 })
H.eq(b.tod, false, 'another type is not doubled')
tod = nil

-- medals, vehicle penalties, lights and siren, hints, unlisted ids, penalties floor at 0
run = fakeRun({ mission = DEFS.beat_patrol, medals = true, pointsBase = 60 })
p = fakeP({ result = 'completed', score = { lights_siren = 1, pedestrian_hit = 3 }, vehicle = { engine = 400, body = 300, seen = true } })
b = CP.Scoring.compute(run, p, 'completed', { durationS = 60 })
H.eq(find(b.bonuses, 'fast_finish'), nil, 'no fast bonus on medal courses')
H.eq(find(b.penalties, 'heavy_damage').points, -25, 'heavy damage -25')
H.eq(find(b.penalties, 'lights_siren').points, -10, 'lights and siren on Beat Patrol')
H.eq(find(b.penalties, 'pedestrian_hit').points, -90, 'pedestrian hits x3')
H.eq(b.final, 0, 'never below 0')
run = fakeRun({ mission = DEFS.gang_shootout })
p = fakeP({ result = 'completed', score = { lights_siren = 1 }, vehicle = { engine = 400, body = 300, seen = true } })
b = CP.Scoring.compute(run, p, 'completed', { durationS = 500 })
H.eq(find(b.penalties, 'lights_siren'), nil, 'lights and siren only on Beat Patrol / Business Check')
H.eq(find(b.penalties, 'heavy_damage'), nil, 'vehiclePenalties = false turns off heavy damage')
H.eq(find(b.bonuses, 'fast_finish'), nil, 'slow run: no fast bonus')
run = fakeRun({ mission = DEFS.weekly_boss_kingpin, pointsBase = 500, missionType = 'tactical',
    shared = { kingpin_alive = 1, hostile_arrested = 4, hostage_hit = 2 }, values = { kingpin_alive = 50, hostage_hit = -50 },
    kinds = { kingpin_alive = 'bonus', hostage_hit = 'penalty' }, downs = 1 })
b = CP.Scoring.compute(run, fakeP({ result = 'completed' }), 'completed', { durationS = 800 })
H.eq(find(b.bonuses, 'kingpin_alive').points, 50, 'per-occurrence value hint honoured')
H.eq(find(b.penalties, 'hostage_hit').points, -100, 'penalty hint x count')
H.eq(find(b.bonuses, 'hostile_arrested'), nil, 'an id the card does not list is ignored')
H.eq(find(b.bonuses, 'no_participant_downed'), nil, 'someone went down: no bonus')
run = fakeRun({ mission = DEFS.business_check, pointsBase = 60, shared = { correct_log = 2, wrong_log = 1 } })
b = CP.Scoring.compute(run, fakeP({ result = 'completed' }), 'completed', { durationS = 590 })
H.eq(find(b.bonuses, 'correct_log').points, 10, 'Config.Bonuses value with its each flag')
H.eq(find(b.penalties, 'wrong_log').points, -5, 'card penalty')
run = fakeRun({ mission = DEFS.manhunt, pointsBase = 160, fired = 1 })
b = CP.Scoring.compute(run, fakeP({ result = 'completed' }), 'completed', { durationS = 590 })
H.eq(find(b.bonuses, 'no_weapons_fired'), nil, 'a weapon was fired: no bonus')
run = fakeRun({ mission = DEFS.manhunt, pointsBase = 160, fired = 0 })
b = CP.Scoring.compute(run, fakeP({ result = 'completed' }), 'completed', { durationS = 590 })
H.eq(find(b.bonuses, 'no_weapons_fired').points, 10, 'nobody fired: end-evaluated bonus')

-- failed, abandoned, presence
b = CP.Scoring.compute(fakeRun(), fakeP({ result = 'failed' }), 'failed', { failedShare = 0.5 })
H.eq(b.final, 25, 'failed = 25% of P x share done')
H.eq(b.failedShare, 0.5, 'failed share')
H.eq(#b.bonuses, 0, 'no bonuses on a failed run')
run = fakeRun({ objectives = { { status = 'done' }, { status = 'active' } } })
b = CP.Scoring.compute(run, fakeP({ result = 'failed' }), 'failed', {})
H.eq(b.failedShare, 0.5, 'share from the run objectives when opts has none')
b = CP.Scoring.compute(fakeRun(), fakeP({ result = 'abandoned' }), 'abandoned', {})
H.eq(b.final, 0, 'abandoned = 0')
presence = false
b = CP.Scoring.compute(fakeRun({ order = { 1, 4 } }), fakeP({ result = 'completed' }), 'completed', { durationS = 300 })
H.eq(b.final, 0, 'presence failed: 0 points')
presence = true

-- streak arithmetic (dates as reset-adjusted day keys)
local adv = CP.Scoring._advance
local s0 = { days = 0, last = nil, graceWeek = nil, graceUsed = 0 }
local s = adv(s0, '2026-09-21')
H.eq(s.days, 1, 'first day')
s = adv(s, '2026-09-22')
H.eq(s.days, 2, 'consecutive day')
local same = adv(s, '2026-09-22')
H.eq(same.days, 2, 'same day counts once')
s = adv(s, '2026-09-24')   -- missed 09-23 (forgiven, week of 09-21)
H.eq(s.days, 3, 'one missed day forgiven: the streak carries on, the forgiven day adds nothing')
H.eq(s.graceUsed, 1, 'grace used')
H.eq(s.graceWeek, '2026-09-21', 'grace week = week start')
local broken = adv(s, '2026-09-26')   -- missed 09-25: a second miss in the same week
H.eq(broken.days, 1, 'second missed day in a week resets the streak')
s = adv(s, '2026-09-29')   -- missed 09-25..09-28: two in week 21, more in week 28
H.eq(s.days, 1, 'long gap resets')
local s2w = adv({ days = 5, last = '2026-09-27', graceWeek = '2026-09-21', graceUsed = 1 }, '2026-09-29')
H.eq(s2w.days, 6, 'a new week has its own grace day')
H.eq(s2w.graceWeek, '2026-09-28', 'grace moved to the new week')
Config.Scoring.streakGraceDays = 0
H.eq(adv({ days = 5, last = '2026-09-21', graceWeek = nil, graceUsed = 0 }, '2026-09-23').days, 1, 'grace 0 = off')
Config.Scoring.streakGraceDays = 1
local cur, gw, gu = CP.Scoring._currentStreak({ days = 4, last = '2026-09-22', graceWeek = nil, graceUsed = 0 }, '2026-09-24')
H.eq(cur, 4, 'streak alive while today can still get its run')
H.eq(CP.Scoring._graceLeft(gw, gu, '2026-09-24'), false, 'the pending missed day uses this week\'s grace')
cur = CP.Scoring._currentStreak({ days = 4, last = '2026-09-22', graceWeek = nil, graceUsed = 0 }, '2026-09-23')
H.eq(cur, 4, 'yesterday still alive')
cur = CP.Scoring._currentStreak({ days = 4, last = '2026-09-20', graceWeek = nil, graceUsed = 0 }, '2026-09-24')
H.eq(cur, 0, 'broken streak shows 0')

-- streak(), onRowCounted, XP marker, badges
H.sql("UPDATE cp_officers SET xp = 0, streak_days = 3, last_complete = ?, grace_week = NULL, grace_used = 0 WHERE citizenid = 'CPOFF001'",
    { os.date('%Y-%m-%d', CP.Schedule.dayStart(H.time) - 12 * 3600) })
local sk = CP.Scoring.streak('CPOFF001')
H.eq(sk.days, 3, 'streak read from cp_officers')
H.near(sk.multiplier, 1.15, 1e-9, 'streak multiplier')
H.eq(sk.graceLeft, true, 'grace day left')
b = CP.Scoring.compute(fakeRun(), fakeP({ result = 'completed' }), 'completed', { durationS = 500 })
H.near(b.mStreak, 1.20, 1e-9, 'today completes day 4 -> +20%')
Config.Badges.ironWheels, Config.Badges.partnerInCrime, Config.Badges.sharpshooter = 2, 1, 1
notes = {}
local nd = { { id = 'no_vehicle_damage', label = 'x', points = 10 }, { id = 'no_participant_downed', label = 'y', points = 20 } }
local rA = insertRun({ final = 300, bonuses = nd, participants = 2 })
CP.Scoring.onRowCounted('CPOFF001', { id = rA, state = 'completed', mission_type = 'tactical', final_points = 300 })
local off = H.sql("SELECT xp, streak_days, DATE_FORMAT(last_complete, '%Y-%m-%d') AS lc FROM cp_officers WHERE citizenid = 'CPOFF001'")[1]
H.eq(off.xp, 300, 'XP added')
H.eq(off.streak_days, 4, 'streak advanced')
H.eq(off.lc, CP.Schedule.dayKey(H.time), 'last_complete = today')
H.eq(bd(rA).xpCounted, 1, 'XP marker on the row')
CP.Scoring.onRowCounted('CPOFF001', { id = rA, state = 'completed', mission_type = 'tactical', final_points = 300 })
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 300, 'counted once per row')
local owned = {}
for _, bg in ipairs(CP.Scoring.badges('CPOFF001')) do owned[bg.id] = bg end
H.ok(owned.partner_in_crime ~= nil, 'Partner in Crime badge (unit run)')
H.ok(owned.sharpshooter ~= nil, 'Sharpshooter badge (Gang Shootout, nobody downed)')
H.eq(owned.iron_wheels, nil, 'Iron Wheels needs 2')
H.eq(owned.partner_in_crime.label, 'Partner in Crime', 'badge label')
H.ok(type(owned.partner_in_crime.earnedAt) == 'string', 'earnedAt string')
local rB = insertRun({ final = 100, bonuses = { nd[1] } , mission = 'bomb_disposal' })
CP.Scoring.onRowCounted('CPOFF001', { id = rB, state = 'completed', mission_type = 'tactical', final_points = 100 })
owned = {}
for _, bg in ipairs(CP.Scoring.badges('CPOFF001')) do owned[bg.id] = true end
H.ok(owned.iron_wheels, 'Iron Wheels after 2 no-damage runs')
local gotBadgeNote = false
for _, n in ipairs(notes) do if n.key == 'scoring.badge_earned' then gotBadgeNote = true end end
H.ok(gotBadgeNote, 'badge notification')
-- the archive counts toward badges too
H.sql('INSERT INTO cp_mission_runs_archive SELECT * FROM cp_mission_runs WHERE id = ?', { rB })
-- void: XP removed, badges revoked below the threshold
H.sql('UPDATE cp_mission_runs SET voided = 1 WHERE id = ?', { rA })
CP.Scoring.onRowVoided(rA)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 100, 'voided row XP taken back')
H.eq(bd(rA).xpCounted, nil, 'marker removed')
CP.Scoring.onRowVoided(rA)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 100, 'void is idempotent')
owned = {}
for _, bg in ipairs(CP.Scoring.badges('CPOFF001')) do owned[bg.id] = true end
H.eq(owned.partner_in_crime, nil, 'Partner in Crime revoked after the void')
H.eq(owned.sharpshooter, nil, 'Sharpshooter revoked after the void')
H.ok(owned.iron_wheels, 'Iron Wheels kept: the archived copy still counts')
local uncounted = insertRun({ final = 500, flagged = true, status = 'held' })
H.sql('UPDATE cp_mission_runs SET voided = 1 WHERE id = ?', { uncounted })
CP.Scoring.onRowVoided(uncounted)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 100, 'voiding a row that never counted takes nothing')
H.sql('DELETE FROM cp_mission_runs_archive')
Config.Badges.ironWheels, Config.Badges.partnerInCrime, Config.Badges.sharpshooter = 20, 50, 10

-- approval of a flagged row
local rF = insertRun({ final = 250, flagged = true, status = 'held' })
H.sql('UPDATE cp_mission_runs SET flagged = 0 WHERE id = ?', { rF })
CP.Scoring.onRowApproved(rF)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 350, 'approved row adds XP')
CP.Scoring.onRowApproved(rF)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 350, 'approval counted once')
local rF2 = insertRun({ final = 250, flagged = true, status = 'held' })
CP.Scoring.onRowApproved(rF2)
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, 350, 'still flagged: nothing counted')

-- XP levels
local lv = CP.Scoring.xpLevel(0)
H.eq(lv.label, 'Probationary', 'level 0')
H.eq(lv.next, 1000, 'next level')
lv = CP.Scoring.xpLevel(1000)
H.eq(lv.label, 'Patrol Officer', 'level 1000')
H.eq(lv.badge, 'bronze', 'badge colour')
H.eq(lv.xp, 1000, 'level threshold')
lv = CP.Scoring.xpLevel(45000)
H.eq(lv.label, 'Elite', 'top level')
H.eq(lv.next, nil, 'no next level')
notes = {}
H.sql("UPDATE cp_officers SET xp = 990 WHERE citizenid = 'CPOFF001'")
local rL = insertRun({ final = 20 })
CP.Scoring.onRowCounted('CPOFF001', { id = rL, state = 'completed', mission_type = 'tactical', final_points = 20 })
H.eq(notes[#notes] and notes[#notes].key, 'scoring.level_up', 'level-up notification')

-- manual awards
audits = {}
ok, res = CP.Scoring.manualAward(2, 'CPOFF001', 100, 'Great RP')
H.eq(res, 'err.no_permission', 'supervisors cannot award points')
ok, res = CP.Scoring.manualAward(3, 'bad id!', 100, 'x')
H.eq(res, 'err.invalid_citizenid', 'bad citizenid')
ok, res = CP.Scoring.manualAward(3, 'CPOFF001', 0, 'x')
H.eq(res, 'err.invalid_points', 'points >= 1')
ok, res = CP.Scoring.manualAward(3, 'CPOFF001', 12.5, 'x')
H.eq(res, 'err.invalid_points', 'whole points')
ok, res = CP.Scoring.manualAward(3, 'CPOFF001', 100, '   ')
H.eq(res, 'err.reason_required', 'reason required')
ok, res = CP.Scoring.manualAward(3, 'NOBODY01', 100, 'x')
H.eq(res, 'err.unknown_officer', 'unknown officer')
local xpBefore = H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp
ok, res = CP.Scoring.manualAward(3, 'CPOFF001', 150, 'Outstanding scene command')
H.ok(ok, 'manual award')
local ma = rowOf(res)
H.eq(ma.mission_type, 'manual_award', 'manual_award row')
H.eq(ma.mission_id, 'manual_award', 'mission_id manual_award')
H.eq(ma.state, 'completed', 'state completed')
H.eq(ma.end_reason, 'completed', 'end_reason = the same word')
H.eq(ma.final_points, 150, 'final points')
H.eq(ma.season_id, 3, 'season id')
H.eq(ma.department, 'sast', 'department from cp_officers')
H.eq(bd(res).reason, 'Outstanding scene command', 'reason in the breakdown')
H.eq(bd(res).points.final, 150, 'RunResult-shaped breakdown')
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, xpBefore + 150, 'manual award adds XP')
H.eq(audits[#audits].action, 'manualAward', 'manual award audited')
H.eq(audits[#audits].new, '150', 'audit new value')
ok = CP.Scoring.manualAward(0, 'CPOFF001', 10, 'console award')
H.ok(ok, 'console award')
H.eq(audits[#audits].role, 'console', 'console role')
season = nil
ok, res = CP.Scoring.manualAward(3, 'CPOFF001', 10, 'no season')
H.eq(rowOf(res).season_id, nil, 'no season -> NULL season_id')
season = { id = 3, name = 'Season 3' }

-- first run since going on duty (duty events)
CP.Scoring._duty['CPOFF001'] = nil
H.sql('DELETE FROM cp_mission_runs')
H.eq(CP.Scoring.isFirstRunSinceDuty(1), true, 'unknown since start, no completed run today -> first')
CP.Scoring.compute(fakeRun(), fakeP({ result = 'completed', first = true }), 'completed', { durationS = 500 })
H.eq(CP.Scoring.isFirstRunSinceDuty(1), false, 'used by a completed run')
players[1].onduty = false
listeners.duty[1](1, false)
players[1].onduty = true
listeners.duty[1](1, true)
H.eq(CP.Scoring.isFirstRunSinceDuty(1), true, 'going on duty again resets it')
listeners.duty[1](1, true)
H.eq(CP.Scoring.isFirstRunSinceDuty(1), true, 'a duplicate on-duty event changes nothing')
CP.Scoring.compute(fakeRun({ test = { adminSrc = 3 } }), fakeP({ result = 'completed', first = true }), 'completed', { durationS = 500 })
H.eq(CP.Scoring.isFirstRunSinceDuty(1), true, 'test runs never use it')
CP.Scoring.compute(fakeRun(), fakeP({ result = 'completed', first = true }), 'completed', { durationS = 500 })
listeners.duty[1](1, true)
H.eq(CP.Scoring.isFirstRunSinceDuty(1), false, 'still on duty: used')
listeners.unload[1](1)
listeners.loaded[2](1)
H.eq(CP.Scoring.isFirstRunSinceDuty(1), true, 'a new character session on duty is a new duty start')
CP.Scoring._duty['CPOFF001'] = nil
insertRun({ final = 10 })
H.eq(CP.Scoring.isFirstRunSinceDuty(1), false, 'unknown since start with a completed run today -> used')

-- ═══════════════════════════════════════════════════════════════════════════
-- Goals
-- ═══════════════════════════════════════════════════════════════════════════
H.sql('DELETE FROM cp_mission_runs')
local g1 = CP.Goals._pick('daily', 'CPOFF001')
local g2 = CP.Goals._pick('daily', 'CPOFF001')
H.eq(g1.id, g2.id, 'same day + citizenid -> same goal (restart-safe)')
local seen = {}
for i = 1, 30 do seen[CP.Goals._pick('daily', ('CID%05d'):format(i)).id] = true end
H.ok(CP.U.count(seen) >= 2, 'goals differ between officers')
local w1 = CP.Goals._pick('weekly', 'CPOFF001', CP.Schedule.weekStart(H.time) + 3600)
local w2 = CP.Goals._pick('weekly', 'CPOFF001', CP.Schedule.weekStart(H.time) + 5 * 86400)
H.eq(w1.id, w2.id, 'the weekly goal stays the same all week')

local savedGoals = Config.Goals
Config.Goals = {
    dailyPoints = 50, weeklyPoints = 200,
    daily = { { id = 'patrol_2', label = 'Complete 2 Patrol missions', type = 'patrol', count = 2 } },
    weekly = { { id = 'cross_2', label = 'Complete 2 cross-department runs', crossDepartment = true, count = 2 } },
}
local fo = CP.Goals.forOfficer('CPOFF001')
H.eq(fo.daily.id, 'patrol_2', 'daily goal')
H.eq(fo.daily.progress, 0, 'no progress yet')
H.eq(fo.daily.done, false, 'not done')
H.eq(fo.daily.points, 50, 'daily points')
H.eq(fo.weekly.points, 200, 'weekly points')
insertRun({ type = 'patrol', mission = 'beat_patrol' })
insertRun({ type = 'patrol', mission = 'beat_patrol', flagged = true })
insertRun({ type = 'patrol', mission = 'beat_patrol', voided = true })
insertRun({ type = 'patrol', mission = 'beat_patrol', state = 'failed' })
insertRun({ type = 'patrol', mission = 'beat_patrol', created = CP.Schedule.dayStart(H.time) - 60 })
insertRun({ type = 'tactical', mission = 'gang_shootout', depts = 2, participants = 2 })
fo = CP.Goals.forOfficer('CPOFF001')
H.eq(fo.daily.progress, 1, 'only counted completed patrol runs since the daily reset')
H.eq(fo.weekly.progress, 1, 'cross-department runs this week')
local xp0 = H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp
CP.Goals.onRunCompleted('CPOFF001')
H.eq(#H.sql("SELECT id FROM cp_mission_runs WHERE mission_type = 'goal'"), 0, 'no reward before the goal is met')
insertRun({ type = 'patrol', mission = 'business_check' })
notes = {}
CP.Goals.onRunCompleted('CPOFF001')
local goalRows = H.sql("SELECT id, mission_id, final_points, state, end_reason FROM cp_mission_runs WHERE mission_type = 'goal'")
H.eq(#goalRows, 1, 'daily goal row inserted')
H.eq(goalRows[1].mission_id, 'patrol_2', 'goal id as mission_id')
H.eq(goalRows[1].final_points, 50, 'daily reward')
H.eq(goalRows[1].end_reason, 'completed', 'goal end_reason')
H.eq(H.sql("SELECT xp FROM cp_officers WHERE citizenid = 'CPOFF001'")[1].xp, xp0 + 50, 'goal reward XP')
H.eq(notes[#notes].key, 'goals.completed_daily', 'goal notification')
CP.Goals.onRunCompleted('CPOFF001')
H.eq(#H.sql("SELECT id FROM cp_mission_runs WHERE mission_type = 'goal'"), 1, 'once per period')
fo = CP.Goals.forOfficer('CPOFF001')
H.eq(fo.daily.done, true, 'daily done')
H.eq(fo.daily.progress, 2, 'progress capped at count')
insertRun({ type = 'investigation', mission = 'manhunt', depts = 2, participants = 2 })
CP.Goals.onRunCompleted('CPOFF001')
goalRows = H.sql("SELECT mission_id, final_points FROM cp_mission_runs WHERE mission_type = 'goal' ORDER BY id")
H.eq(#goalRows, 2, 'weekly goal rewarded')
H.eq(goalRows[2].final_points, 200, 'weekly reward')
H.eq(CP.Goals.forOfficer('CPOFF001').weekly.done, true, 'weekly done')
Config.Goals.daily = { { id = 'unit_1', label = 'Complete 1 unit run', unit = true, count = 1 } }
H.eq(CP.Goals.forOfficer('CPOFF001').daily.progress, 1, 'unit goal counts 2+ participant runs')
Config.Goals.daily = { { id = 'any_3', label = 'Complete 3 missions of any type', count = 3 } }
H.eq(CP.Goals.forOfficer('CPOFF001').daily.progress, 3, 'goal and manual rows never count as runs')
Config.Goals.daily = { { id = 'shoot_1', label = 'Gang Shootout', mission = 'gang_shootout', count = 1 } }
H.eq(CP.Goals.forOfficer('CPOFF001').daily.progress, 1, 'mission filter')
Config.Goals.daily = {}
H.eq(CP.Goals.forOfficer('CPOFF001').daily, nil, 'no daily goals configured')
Config.Goals = savedGoals

-- ═══════════════════════════════════════════════════════════════════════════
-- Home
-- ═══════════════════════════════════════════════════════════════════════════
tod = 'tactical'
H.sql("UPDATE cp_officers SET xp = 11250, streak_days = 4, last_complete = ? WHERE citizenid = 'CPOFF001'", { CP.Schedule.dayKey(H.time) })
H.sql("UPDATE cp_mission_runs SET cash_status = 'paid', cash_paid = 1040 WHERE mission_type = 'patrol' AND flagged = 0 AND voided = 0 AND state = 'completed'")
local home = H.callback('crimson-police:getHome', 1)
H.eq(home.ok, true, 'getHome ok')
local hd = home.data
H.eq(hd.card.name, 'John Doe', 'card name')
H.eq(hd.card.callsign, '2L-1', 'card callsign')
H.eq(hd.card.departmentShort, 'SAST', 'card department tag')
H.eq(hd.card.xp, 11250, 'card xp')
H.eq(hd.card.level.label, 'Senior Patrol', 'card level')
H.eq(hd.card.level.next, 15000, 'card next level')
H.eq(hd.card.streak.days, 4, 'card streak')
H.eq(type(hd.card.streak.graceLeft), 'boolean', 'grace flag')
H.ok(hd.card.seasonPoints > 0, 'season points from the SQL fallback')
H.ok(hd.card.cashThisWeek >= 2080, 'cash this week')
H.eq(hd.typeOfTheDay.key, 'tactical', 'Type of the Day key')
H.eq(hd.typeOfTheDay.label, 'Tactical', 'Type of the Day label')
H.ok(hd.goals.daily ~= nil and hd.goals.weekly ~= nil, 'goals present')
H.eq(#hd.announcements, 0, 'no announcements without modules/leaderboard')
H.eq(hd.champions, nil, 'no champions banner without modules/challenge')
CP.Leaderboard = { seasonPoints = function() return 4321 end, announcements = function() return { { kind = 'weekly_top', text = 'Top 3' }, { bad = true } } end }
CP.Challenge.championBanner = function(dept) return { season = 'Season 2', department = 'FIB' } end
hd = H.callback('crimson-police:getHome', 1).data
H.eq(hd.card.seasonPoints, 4321, 'season points from modules/leaderboard')
H.eq(#hd.announcements, 1, 'announcements from modules/leaderboard (invalid entries dropped)')
H.eq(hd.champions.department, 'FIB', 'champions banner')
tod = nil
hd = H.callback('crimson-police:getHome', 1).data
H.eq(hd.typeOfTheDay, nil, 'no Type of the Day')
local denied = H.callback('crimson-police:getHome', 3)
H.eq(denied.error, 'err.not_police', 'admins without a police job get the access error')
players[4].onduty = false
denied = H.callback('crimson-police:getHome', 4)
H.eq(denied.error, 'err.not_on_duty', 'off duty')

return H
