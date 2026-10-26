-- Staff notes (step V2, critic 2 #12 and #13): CP.AntiCheat.note records a fact for staff (audited as runNoted, shown
-- in the Review run detail) and never holds anyone's points or items; a flag (runFlagged) still does. Real:
-- modules/admin (cp_audit, the Review Queue), modules/anticheat, modules/cash (Cash.compute) and modules/rewards.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = true   -- run every CP.log format string too

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if not line:find('crimson%-police') then realPrint(line) end
end
local function Printed(needle)
    for i = #lines, 1, -1 do
        if lines[i]:find(needle, 1, true) then return true end
    end
    return false
end

_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
_G.GetPlayerRoutingBucket = function() return 0 end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local infos = {}
local function AddPlayer(src, cid, name, job, grade, ace)
    infos[src] = {
        src = src,
        citizenid = cid,
        name = name,
        job = { name = job, label = job, onduty = true, gradeLevel = grade, gradeName = 'Grade ' .. grade },
        callsign = ('C-%d'):format(src),
    }
    H.players[src] = { coords = vec3(0.0, 0.0, 0.0), ace = ace and { ['crimsonpolice.admin'] = true } or {} }
end
AddPlayer(1, 'ADM00001', 'Ada Min', 'unemployed', 0, true)
AddPlayer(2, 'SUP00002', 'Sam Super', 'sast', 3, false)
AddPlayer(3, 'OFF00003', 'Olly Officer', 'sast', 1, false)
AddPlayer(6, 'OFF00006', 'Pat Partner', 'sast', 1, false)
local online = { [2] = true }   -- the officers are offline: an item reward stays as it was granted
CP.Qbx = {
    getInfo = function(src) return infos[tonumber(src)] end,
    getByCitizenId = function(cid)
        for s, i in pairs(infos) do if i.citizenid == cid and online[s] then return s end end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for s in pairs(infos) do out[#out + 1] = s end
        table.sort(out)
        return out
    end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
CP.Tablet = {
    notify = function() return true end,
    notifyMany = function(srcs) return #srcs end,
    push = function() end,
}
CP.Scoring = {
    onRowApproved = function() end,
    onRowVoided = function() end,
    xpLevel = function(xp) return { label = 'Patrol Officer', badge = 'bronze', xp = xp, next = 5000 } end,
    badges = function() return {} end,
}
CP.Leaderboard = { invalidate = function() end }
CP.Payouts = {
    baseFor = function() return 800 end,
    sourceFor = function() return 'type' end,
}
CP.Alerts = {
    inArena = function() return false end,
}
CP.Operations = {
    active = function() return nil end,
}
local MISSION = {
    id = 'warrant_service',
    label = 'Warrant Service',
    type = 'patrol',
    source = 'builtin',
    difficulty = 2,
    minOfficers = 1,
    maxOfficers = 4,
    cooldown = 600,
    timeLimit = 900,
    departments = {},
    locations = { {} },
}
CP.Missions = {
    list = function() return { MISSION } end,
    get = function(id) return id == MISSION.id and MISSION or nil end,
    all = function() return { [MISSION.id] = MISSION } end,
    isEnabled = function() return true end,
}

local runs = {}
local function Participant(src)
    local i = infos[src]
    return {
        src = src,
        citizenid = i.citizenid,
        name = i.name,
        department = 'sast',
        departmentShort = 'SAST',
        status = 'active',
        arrived = true,
        presence = { inRange = 0, total = 0 },
    }
end
CP.Runs = {
    all = function()
        local out = {}
        for _, r in pairs(runs) do if r.state ~= 'ended' then out[#out + 1] = r end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    get = function(id) return runs[id] end,
}
local function NewRun(id, srcs, extra)
    local run = {
        id = id,
        missionId = MISSION.id,
        mission = MISSION,
        missionType = 'patrol',
        state = 'in_progress',
        order = {},
        participants = {},
        objectiveIndex = 1,
        objectives = { { status = 'active', state = {} } },
        cashBase = 800,
        startedAt = H.time,
        host = srcs[1],
    }
    for _, s in ipairs(srcs) do
        run.order[#run.order + 1] = s
        run.participants[s] = Participant(s)
    end
    for k, v in pairs(extra or {}) do run[k] = v end
    runs[id] = run
    return run
end

H.mockInventory({ water = { label = 'Water' } })   -- ox_inventory for the item rewards

H.load('modules/adminkit/server.lua')
H.load('modules/access/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/anticheat/server.lua')
H.load('modules/cash/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/rewards/server.lua')
H.advance(5000)   -- the start checks
local AC = CP.AntiCheat

H.sql('DELETE FROM cp_audit')
H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_item_rewards')
H.sql('DELETE FROM cp_officers')
for _, i in pairs(infos) do
    H.sql(
        'INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department, xp) VALUES (?, ?, ?, ?, ?, ?)',
        { i.citizenid, i.callsign, i.job.gradeName, i.name, i.job.name == 'sast' and 'sast' or 'none', 100 })
end

local function Audits(action, target)
    return H.sql(
        'SELECT category, action, target, old_value, new_value, reason FROM cp_audit WHERE action = ? AND target = ? ORDER BY id',
        { action, target })
end

-- ============================================================================
--                    1. A NOTE IS AUDITED, NOTHING IS HELD
-- ============================================================================

local run = NewRun('run-note', { 3, 6 })
do
    H.eq(type(AC.note), 'function', 'CP.AntiCheat.note exists')
    H.eq(AC.note(run, 3, 'stun_unproven', 'Objective 1, person 5003'), true, 'a note about officer 3')
    local rows = Audits('runNoted', 'run-note')
    H.eq(#rows, 1, 'audited once as runNoted')
    local a = rows[1] or {}
    H.eq(a.category, 'flags', 'category flags (like runFlagged)')
    H.eq(a.old_value, 'OFF00003', 'old_value = the participant\'s citizenid')
    H.eq(a.new_value, 'stun_unproven', 'new_value = the reason')
    H.eq(a.reason, 'Objective 1, person 5003', 'reason = the detail')
    H.eq(#Audits('runFlagged', 'run-note'), 0, 'no runFlagged row')
    H.eq(run.flagged, nil, 'the run stays unflagged')
    H.eq(run.participants[3].flagged, nil, 'the participant stays unflagged')
    H.eq(run.participants[6].flagged, nil, 'his partner too')

    -- a second identical note is deduped; another officer or reason is its own note
    H.eq(AC.note(run, 3, 'stun_unproven', 'again'), false, 'the same note twice: deduped')
    H.eq(#Audits('runNoted', 'run-note'), 1, 'still one runNoted row')
    H.eq(AC.note(run, 6, 'stun_unproven', 'Objective 1, person 5004'), true, 'the same reason for his partner')
    H.eq(AC.note(run, nil, 'rs_combat_log', 'the suspect logged off'), true, 'a note about the case (src nil)')
    H.eq(AC.note(run, nil, 'rs_combat_log', 'again'), false, 'the case note once')
    local caseRow = Audits('runNoted', 'run-note')[3] or {}
    H.eq(caseRow.old_value, nil, 'a case note has no citizenid')
    H.eq(#Audits('runNoted', 'run-note'), 3, 'three notes in all')
    H.ok(run.flagged == nil and run.participants[3].flagged == nil and run.participants[6].flagged == nil,
        'still nobody flagged')

    -- the same input checks as a flag
    H.eq(AC.note(run, 99, 'stun_unproven'), false, 'not a participant: refused')
    H.eq(AC.note(run, 3, ''), false, 'no reason: refused')
    H.eq(AC.note(run, 3, 42), false, 'a reason that is no string: refused')
    H.eq(AC.note('run-note', 3, 'x'), false, 'no run table: refused')
    H.eq(AC.note(run, 3, string.rep('r', 100), string.rep('d', 300)), true, 'a long reason and detail')
    local long = H.sql(
        'SELECT CHAR_LENGTH(new_value) AS n, CHAR_LENGTH(reason) AS d FROM cp_audit WHERE action = \'runNoted\' AND target = \'run-note\' ORDER BY id DESC LIMIT 1')[1]
    H.ok(long and tonumber(long.n) == 64 and tonumber(long.d) == 255, 'clipped like a flag (64 and 255)')

    -- the note list is its own: a flag with the same reason still flags, and a note after it still notes
    local other = NewRun('run-both', { 3, 6 })
    H.eq(AC.note(other, 3, 'stun_unproven'), true, 'a note first')
    H.eq(AC.flag(other, 3, 'stun_unproven'), true, 'then a flag with the same reason is not deduped by the note')
    H.eq(other.participants[3].flagged and other.participants[3].flagged.reason, 'stun_unproven', 'the flag holds')
    H.eq(AC.note(other, 6, 'speed'), true, 'a note')
    H.eq(AC.flag(other, 6, 'speed'), true, 'and a flag of the same reason for the same officer')
end

-- a test run only logs a note
do
    local tr = NewRun('run-note-test', { 3 }, { test = { adminSrc = 1 } })
    H.eq(AC.note(tr, 3, 'stun_unproven', 'x'), false, 'a test run: no note')
    H.eq(#Audits('runNoted', 'run-note-test'), 0, 'nothing audited')
    H.eq(tr.flagged, nil, 'nothing flagged')
    H.ok(Printed('test run run-note-test would be noted stun_unproven'), 'one log line instead')
    runs['run-note-test'] = nil
end

-- ============================================================================
--               2. CASH AND ITEM REWARDS ARE NOT HELD FOR A NOTE
-- ============================================================================

do
    local p = run.participants[3]
    p.result = 'completed'
    local _, cb = CP.Cash.compute(run, p)
    H.eq(cb.status, 'none', 'Cash.compute: a completed row with only notes is not held')
    local flagged = NewRun('run-flagged', { 3, 6 })
    AC.flag(flagged, 3, 'too_fast', 'x')
    flagged.participants[3].result = 'completed'
    local _, cf = CP.Cash.compute(flagged, flagged.participants[3])
    H.eq(cf.status, 'held', 'Cash.compute: a flagged one is held (the same check)')

    Config.Rewards.enabled = true
    Config.Rewards.dailyItemCap, Config.Rewards.dailyValueCap = 10, 2000
    Config.Rewards.byType = {
        patrol = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
    }
    Config.Rewards.byMission, Config.Rewards.medals, Config.Rewards.weeklyBoss = {}, {}, nil
    Config.Rewards.useExamplePools = false
    CP.Rewards._reset()
    CP.Rewards.validate()
    local function Settle(r, src, rowId)
        local row = {
            citizenid = r.participants[src].citizenid,
            state = 'completed',
            mission_id = MISSION.id,
            mission_type = 'patrol',
            tier = 'standard',
            evidence = 0,
            flagged = (r.flagged or r.participants[src].flagged) and 1 or 0,
        }
        CP.Hooks.fire('row:settled', r, r.participants[src], rowId, row, { items = {} })
        return H.sql('SELECT status FROM cp_item_rewards WHERE row_id = ?', { rowId })
    end
    local noted = Settle(run, 3, 9001)
    H.ok(#noted >= 1, 'Rewards: the noted officer gets his roll')
    H.eq(noted[1] and noted[1].status, 'pending', 'Rewards: granted pending, not held')
    local held = Settle(flagged, 3, 9002)
    H.eq(held[1] and held[1].status, 'held', 'Rewards: a flagged officer\'s items are held (the same check)')
    Config.Rewards.enabled = false
end

-- ============================================================================
--                   3. THE REVIEW RUN DETAIL SHOWS THE NOTES
-- ============================================================================

local function AddRow(uuid, cid, reason)
    local id = MySQL.insert.await([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid,
        department, participants, departments_n, tier, state, end_reason, points_base, final_points, cash_base,
        cash_paid, cash_status, flagged, flag_reason, voided, breakdown, created_at)
        VALUES (?, 'patrol', ?, ?, 'sast', 2, 1, 'standard', 'completed', 'completed', 100, 120, 800, 0, ?, ?, ?, 0,
        '{}', NOW())]], { uuid, MISSION.id, cid, reason and 'held' or 'none', reason and 1 or 0, reason or '' })
    if not reason then H.sql('UPDATE cp_mission_runs SET flag_reason = NULL WHERE id = ?', { id }) end
    return id
end

do
    -- officer 3's row of run-note is held for an officer-conduct flag; the notes come along in its detail
    AC.flag(run, 3, 'speed', 'moved 900 m in 2 s')
    local held = AddRow('run-note', 'OFF00003', 'speed')
    local partner = AddRow('run-note', 'OFF00006', nil)
    local onlyNote = AddRow('run-only-note', 'OFF00006', nil)
    local lone = NewRun('run-only-note', { 6 })
    AC.note(lone, 6, 'stun_unproven', 'Objective 1, person 5009')
    local res = Cb('sup:getReviewQueue', 2)
    local list = res and res.data and res.data.flagged or {}
    local row, others = nil, {}
    for _, r in ipairs(list) do
        if r.rowId == held then row = r else others[#others + 1] = r.rowId end
    end
    H.ok(row ~= nil, 'the held row is in the Review Queue')
    local notes = row and row.notes or {}
    H.eq(#notes, 3, 'its detail lists officer 3\'s notes and the case note (not his partner\'s)')
    local byReason = {}
    for _, n in ipairs(notes) do byReason[n.reason] = n end
    H.eq(byReason.stun_unproven and byReason.stun_unproven.note, true, 'the stun note comes with note = true')
    H.eq(byReason.stun_unproven and byReason.stun_unproven.detail, 'Objective 1, person 5003', 'with its detail')
    H.eq(byReason.rs_combat_log and byReason.rs_combat_log.note, true, 'the case note too')
    H.eq(row and row.flagReason, 'speed', 'the flag reason is the flag\'s')
    H.ok(row and row.flagDetail == 'moved 900 m in 2 s', 'the flag detail holds no note text')
    local also = false
    for _, r in ipairs(row and row.otherReasons or {}) do
        if r == 'stun_unproven' or r == 'rs_combat_log' then also = true end
    end
    H.eq(also, false, 'a note is not listed as another flag reason')
    local listed = false
    for _, id in ipairs(others) do if id == partner or id == onlyNote then listed = true end end
    H.eq(listed, false, 'the queue still lists only held rows (a row with only notes is not there)')
    -- the screen's text: "Note: <the flag line>"
    H.eq(CP.L('sup.review.note', { line = CP.L('flag.stun_unproven') }),
        'Note: A stun was reported that the server did not see (the suspect did not fall). Check it before approving.',
        'the Review line of a stun note')
end

-- ============================================================================
--              4. THE STUN RULE WRITES THE NOTE (stunNeedsProof)
-- ============================================================================

do
    local saved = Config.AntiCheat.stunNeedsProof
    H.eq(saved, 'flag', 'stunNeedsProof ships \'flag\'')
    local sr = NewRun('run-stun', { 3, 6 })
    H.eq(AC.stunReport(sr, 3, false, 5003), true, 'flag: an unseen stun counts')
    local n = Audits('runNoted', 'run-stun')[1] or {}
    H.eq(n.new_value, 'stun_unproven', 'flag: a stun_unproven note')
    H.eq(n.reason, 'Objective 1, person 5003: the server saw no fall within 1 s of the report', 'flag: its detail')
    H.ok(sr.flagged == nil and sr.participants[3].flagged == nil, 'flag: nobody is held')
    H.eq(AC.stunReport(sr, 3, false, 5003), true, 'flag: the report again')
    H.eq(#Audits('runNoted', 'run-stun'), 1, 'flag: once per officer and run')
    H.eq(AC.stunReport(sr, 6, true, 5003), true, 'a stun the server saw counts')
    H.eq(#Audits('runNoted', 'run-stun'), 1, 'and writes nothing')
    Config.AntiCheat.stunNeedsProof = 'hold'
    H.eq(AC.stunReport(sr, 6, false, 5003), true, 'hold: an unseen stun counts')
    H.eq(sr.participants[6].flagged and sr.participants[6].flagged.reason, 'stun_unproven', 'hold: that officer held')
    H.eq(#Audits('runFlagged', 'run-stun'), 1, 'hold: audited as runFlagged')
    Config.AntiCheat.stunNeedsProof = 'strict'
    H.eq(AC.stunReport(sr, 3, false, 5003), false, 'strict: an unseen stun is refused')
    Config.AntiCheat.stunNeedsProof = 'off'
    H.eq(AC.stunReport(sr, 3, false, 5003), true, 'off: taken')
    H.ok(#Audits('runNoted', 'run-stun') == 1 and #Audits('runFlagged', 'run-stun') == 1,
        'strict and off write nothing')
    Config.AntiCheat.stunNeedsProof = saved
end

return H
