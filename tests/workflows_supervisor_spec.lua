-- WF5B: every supervisor workflow, extensively (the owner: "do extensive workflow testing on everything").

-- WF5B: every supervisor workflow, extensively (the owner: "do extensive workflow testing on everything").
-- Every workflow and every action a supervisor can take, driven start to finish on the REAL server side of
-- Crimson-Police: the world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the
-- owner's scripts running, database off: the saves folder, as shipped), booted on the shipped config with no
-- section of that spec run (CP_WF_WORLD). Each part runs on the shipped config first, then with the switches on that
-- the admin turns on through the Admin UI's own Settings action, with a `restart Crimson-Police` and a player drop and
-- reconnect in the middle, and every refusal a supervisor can meet (no permission, wrong department, caps reached,
-- feature off, maintenance lock). docs/dev/WORKFLOWS.md lists each workflow with its section here.
--   1. The Supervisor UI and the Department screen's Today and Officers tabs; who may open them.
--   2. The officer side panel on the shipped config: commend and revoke, the actions that are off.
--   3. The side panel with the switches on: give points, mission ban, clear cooldown, with their caps and limits.
--   4. Mission controls: every control set inside the admin's limits and refused outside them, the change wait, the
--      happy hour (minutes, scale, once a day, the self rule), the master switch and a department's grade rule.
--   5. The Review Queue: approve, void, a second supervisor's Void, undo and batches (admins only), a restart.
--   6. Calls and notices: create and withdraw a mission call, the wait between two, a department notice.
--   7. Field training: pair, the trainer's sign-off, unpair, their refusals, a restart.
--   8. Extra grants for officers who are not supervisors (Mission controls, field training, mission calls).
--   9. Two supervisors of one department at once.
--  10. The maintenance lock: every supervisor action refused while it holds, the screens still read.

_G.CP_WF_WORLD = 'supervisor'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Cb, Secs, Place, Setting = W.Cb, W.Secs, W.Place, W.Setting
-- The per-officer rate of the actions about one officer (opts.targetRate): a supervisor's dialog never sends two
-- about the same officer faster than that, so the spec waits it out before each.
local TARGET_WAIT = { ['server:sup:awardPoints'] = 10, ['server:sup:clearCooldowns'] = 3, ['server:restriction'] = 3 }
local function Act(name, src, payload, tries)
    if TARGET_WAIT[name] then Secs(TARGET_WAIT[name]) end
    return W.Act(name, src, payload, tries)
end

-- A second SAST supervisor (two at once, section 9) and a SAST cadet.
W.AddPlayer(8, 'WFSUPSU8', 'Max', 'Sarge', 'sast', 3)
W.AddPlayer(9, 'WFSUPCA9', 'Eve', 'Cadet', 'sast', 0)
for _, src in ipairs({ 8, 9 }) do
    CID[src] = PD[src].citizenid
    H.players[src].coords = vec3(0.0, 0.0, 0.0)
    W.Reconnect(src)
end

local AT = vec3(-300.0, -1400.0, 30.0)
for src = 1, 9 do Place(src, vec3(AT.x + src * 2.0, AT.y, AT.z)) end

-- Every cooldown and the hourly cap of the runs before are over.
local function Later() H.time = H.time + 3700 end
-- 09:00 of the next day: every daily count (awards, bans, clears, happy hours) starts again.
local function NextDay()
    local d = os.date('*t', H.time + 86400)
    H.time = os.time({ year = d.year, month = d.month, day = d.day, hour = 9, min = 0, sec = 0 })
    Secs(2)
end
local function Open(src, args)
    args = args or {}
    args.ui = args.ui or 'officer'
    args.via = args.via or 'command'
    return Cb('getSession', src, args)
end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
    if CP.Units.unitOf(src) then Act('server:teamLeave', src) end
end
local cjson = require('cjson')
local function Count(sql, params) return W.Count(sql, params) end
local function Audits(action) return Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { action }) end
-- The officer's side panel (Department screen -> Officers -> an officer) as src sees it.
local function Panel(src, cid) return Cb('sup:getOfficerActivity', src, { citizenid = cid }) end
-- A type cooldown on that officer: he accepts Beat Patrol and abandons it (the type's abandon cooldown).
local function AbandonPatrol(src)
    Later()
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    local ok, err = Act('server:acceptType', src, 'patrol')
    Config.DisabledMissions = {}
    H.eq(ok, true, ('cooldown: %s takes Beat Patrol: %s'):format(CID[src], tostring(err)))
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
    Secs(2)
    return CP.Runs.cooldowns(CID[src]).types.patrol ~= nil
end
local function Control(view, dept, key)
    for _, d in ipairs(view and view.departments or {}) do
        if d.key == dept then
            for _, c in ipairs(d.controls or {}) do if c.key == key then return c end end
        end
    end
    return nil
end
local function SetControl(src, key, value, reason)
    return Act('server:sup:setMissionControl', src,
        { key = key, value = value, reason = reason or 'WF5B', requestId = W.RequestId() })
end
-- The change wait of every control is over.
local function AfterWait() H.time = H.time + (tonumber(Config.MissionControls.changeWait) or 0) + 5 end
-- Z14: a reset is a change too (it waits for the change wait like a set)
local function ResetControl(src, key)
    AfterWait()
    return Act('server:sup:resetMissionControl', src, { key = key, reason = 'WF5B done', requestId = W.RequestId() })
end

-- ============================================================================
--                             1. THE SUPERVISOR UI
-- ============================================================================
-- TODAY AND OFFICERS (SHIPPED CONFIG FIRST).

do
    H.eq(Config.Database.enabled, W.ON_DB,
        W.ON_DB and 'database on (MariaDB)' or 'shipped: database off (the saves folder)')
    H.eq(Config.Debug, true, 'shipped: Debug on')
    H.eq(Config.Permissions.supervisor.missionControls, false, 'shipped: the Mission controls master switch off')
    H.eq(Config.MissionControls.selfExempt, true, 'shipped: the self rule on')

    -- every police player opens his Officer UI once (his officer row, as in game)
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7, 8, 9 }) do
        H.ok(Open(src) ~= nil, ('tablet: %s opens the Officer UI'):format(CID[src]))
    end
    -- the Supervisor UI: the supervisors of each department open it; an officer, a cadet, a civilian never
    H.ok(Open(3, { ui = 'supervisor' }) ~= nil, 'supervisor UI: the SAST supervisor opens it')
    H.ok(Open(4, { ui = 'supervisor' }) ~= nil, 'supervisor UI: the FIB supervisor opens it')
    H.ok(Open(8, { ui = 'supervisor' }) ~= nil, 'supervisor UI: the second SAST supervisor opens it')
    local s, why = Open(1, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'supervisor UI: an officer is refused')
    s, why = Open(9, { ui = 'supervisor' })
    H.eq(why, 'err.not_supervisor', 'supervisor UI: a cadet is refused')
    s, why = Open(5, { ui = 'supervisor' })
    H.ok(s == nil, 'supervisor UI: a civilian is refused (' .. tostring(why) .. ')')

    -- Today: his department's officers on duty and its runs going, his controls of today
    local today, err = Cb('sup:getToday', 3)
    H.ok(type(today) == 'table', 'today: the SAST supervisor opens Today: ' .. tostring(err))
    H.eq(today and today.onDuty, 6, 'today: six SAST players on duty (1, 3, 6, 7, 8, 9)')
    H.eq(today and today.running, 0, 'today: no run going')
    H.eq(type(today and today.controls), 'table', 'today: his controls of today')
    local fib = Cb('sup:getToday', 4)
    H.eq(fib and fib.onDuty, 2, 'today: FIB counts its own two (2, 4)')
    today, err = Cb('sup:getToday', 1)
    H.eq(today, nil, 'today: an officer cannot open it (' .. tostring(err) .. ')')

    -- an officer of his department on a run shows as running in his Today, not in FIB's
    Later()
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    local ok = Act('server:acceptType', 1, 'patrol')
    Config.DisabledMissions = {}
    H.eq(ok, true, 'today: Ada takes Beat Patrol')
    H.eq((Cb('sup:getToday', 3) or {}).running, 1, 'today: SAST shows one run going')
    H.eq((Cb('sup:getToday', 4) or {}).running, 0, 'today: FIB shows none')
    Leave(1)

    -- Officers: the department's list; another department only for an admin
    local report = Cb('sup:getDeptReport', 3)
    H.ok(type(report) == 'table' and type(report.officers) == 'table', 'officers: the SAST list opens')
    local listed = {}
    for _, o in ipairs(report and report.officers or {}) do listed[o.citizenid] = true end
    H.ok(listed[CID[1]] == true, 'officers: Ada is on the SAST list')
    H.ok(listed[CID[2]] == nil, 'officers: the FIB agent is not')
    report, err = Cb('sup:getDeptReport', 3, { department = 'fib' })
    H.eq(err, 'err.other_department', 'officers: the SAST supervisor cannot open FIB\'s list')
    report, err = Cb('sup:getDeptReport', 3, { department = 'nope' })
    H.eq(err, 'err.unknown_department', 'officers: an unknown department')
    H.ok(Cb('sup:getDeptReport', 5, { department = 'fib' }) ~= nil, 'officers: an admin opens any department')
    report, err = Cb('sup:getDeptReport', 1)
    H.eq(report, nil, 'officers: an officer cannot open the list (' .. tostring(err) .. ')')

    -- the side panel of one officer: his department only
    local panel
    panel, err = Panel(3, CID[1])
    H.ok(type(panel) == 'table', 'panel: the supervisor opens Ada\'s panel: ' .. tostring(err))
    panel, err = Cb('sup:getOfficerActivity', 3, { citizenid = CID[2], department = 'fib' })
    H.eq(err, 'err.other_department', 'panel: not a FIB agent\'s')
    panel, err = Panel(1, CID[6])
    H.eq(panel, nil, 'panel: an officer cannot open one (' .. tostring(err) .. ')')
    panel, err = Cb('sup:getOfficerActivity', 3, { citizenid = 'not a cid!' })
    H.eq(err, 'err.invalid_citizenid', 'panel: a bad citizenid')
end

-- ============================================================================
--           2. THE OFFICER SIDE PANEL ON THE SHIPPED CONFIG: COMMEND
-- ============================================================================

local GOOD = 'Stayed with the victim until EMS arrived.'

do
    -- shipped: Give points and Mission ban are off (master switch and their controls); Clear cooldown is offered
    local panel = Panel(3, CID[1]) or {}
    H.eq(panel.awardPoints, nil, 'shipped: no Give points in the panel')
    H.eq(panel.missionBan, nil, 'shipped: no Mission ban in the panel')
    H.ok(type(panel.cooldownClear) == 'table', 'shipped: Clear cooldown is offered (outside the master switch)')
    local ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[1], points = 5, reason = 'Good stop' })
    H.eq(ok, false, 'shipped: Give points refused (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[1], hours = 1, reason = 'Late' })
    H.eq(ok, false, 'shipped: Mission ban refused (' .. tostring(err) .. ')')

    -- commend: from the panel, the reply carries his fresh activity
    ok, err = Act('server:sup:commend', 3,
        { citizenid = CID[1], kind = 'lifesaving', citation = GOOD, activityOf = CID[1] })
    H.eq(ok, true, 'commend: the supervisor commends Ada: ' .. tostring(err))
    local mine
    for _, c in ipairs(type(err) == 'table' and err.activity and err.activity.commendations or {}) do
        if c.kind == 'lifesaving' then mine = c end
    end
    H.ok(mine ~= nil, 'commend: the reply carries her panel with it')
    H.eq(Audits('commend'), 1, 'commend: audited once')
    -- refusals: too short, an unknown kind, himself, another department, the same kind again, an officer
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[6], kind = 'valor', citation = 'short' })
    H.eq(err, 'err.citation_short', 'commend: a citation too short')
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[6], kind = 'bravery', citation = GOOD })
    H.eq(err, 'err.commend_kind', 'commend: an unknown kind')
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[3], kind = 'valor', citation = GOOD })
    H.eq(err, 'err.commend_self', 'commend: never himself')
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[2], kind = 'valor', citation = GOOD })
    H.eq(err, 'err.commend_other_dept', 'commend: never another department (crossDepartment off)')
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[1], kind = 'lifesaving', citation = GOOD })
    H.ok(ok == false and tostring(err):find('7 days') ~= nil, 'commend: the same kind again within 7 days')
    ok, err = Act('server:sup:commend', 1, { citizenid = CID[6], kind = 'valor', citation = GOOD })
    H.eq(err, 'err.no_permission', 'commend: an officer cannot')
    -- three a day for one supervisor
    for i, cid in ipairs({ CID[6], CID[7] }) do
        ok, err = Act('server:sup:commend', 3, { citizenid = cid, kind = 'teamwork', citation = GOOD })
        H.eq(ok, true, ('commend: commendation %d of today: %s'):format(i + 1, tostring(err)))
    end
    ok, err = Act('server:sup:commend', 3, { citizenid = CID[9], kind = 'teamwork', citation = GOOD })
    H.eq(err, 'err.commend_limit', 'commend: a fourth today is refused (perSupervisorPerDay 3)')
    ok, err = Act('server:sup:commend', 8, { citizenid = CID[9], kind = 'teamwork', citation = GOOD })
    H.eq(ok, true, 'commend: the second supervisor has his own three: ' .. tostring(err))

    -- a restart and a drop: the commendation stays; only its issuer revokes it, with a reason
    W.Restart()
    W.Drop(1)
    W.Reconnect(1)
    mine = nil
    for _, c in ipairs((Panel(3, CID[1]) or {}).commendations or {}) do
        if c.kind == 'lifesaving' then mine = c end
    end
    H.ok(mine ~= nil and mine.id ~= nil, 'restart: Ada\'s commendation is still there')
    ok, err = Act('server:sup:revokeCommendation', 8, { id = mine and mine.id, reason = 'Not mine' })
    H.eq(err, 'err.not_issuer', 'revoke: another supervisor cannot')
    ok, err = Act('server:sup:revokeCommendation', 3, { id = mine and mine.id })
    H.eq(err, 'err.reason_required', 'revoke: a reason is needed')
    ok, err = Act('server:sup:revokeCommendation', 3, { id = mine and mine.id, reason = 'Wrong officer' })
    H.eq(ok, true, 'revoke: the issuer revokes it: ' .. tostring(err))
    H.eq(Audits('revokeCommendation'), 1, 'revoke: audited')
    local left = nil
    for _, c in ipairs((Panel(3, CID[1]) or {}).commendations or {}) do
        if c.kind == 'lifesaving' then left = c end
    end
    H.eq(left, nil, 'revoke: gone from her panel')

    -- the feature off: commendations refused
    ok, err = Setting('Recognition.commendations.enabled', false)
    H.eq(ok, true, 'settings: commendations off: ' .. tostring(err))
    ok, err = Act('server:sup:commend', 8, { citizenid = CID[6], kind = 'valor', citation = GOOD })
    H.eq(err, 'err.commendations_off', 'commend: refused while the feature is off')
    Setting('Recognition.commendations.enabled', true)
    ok, err = Setting('Permissions.supervisor.issueCommendation', false)
    H.eq(ok, true, 'settings: the supervisors\' commend power off: ' .. tostring(err))
    ok, err = Act('server:sup:commend', 8, { citizenid = CID[6], kind = 'valor', citation = GOOD })
    H.eq(ok, false, 'commend: refused while the power is off (' .. tostring(err) .. ')')
    Setting('Permissions.supervisor.issueCommendation', true)
end

-- ============================================================================
--                    3. THE SIDE PANEL WITH THE SWITCHES ON
-- ============================================================================
-- POINTS, MISSION BAN, COOLDOWN.

do
    NextDay()
    local ok, err = Setting('Permissions.supervisor.missionControls', true)
    H.eq(ok, true, 'settings: the Mission controls master switch on: ' .. tostring(err))
    local controls = CP.U.copy(Config.MissionControls.controls)
    for _, c in pairs(controls) do c.on = true end
    ok, err = Setting('MissionControls.controls', controls)
    H.eq(ok, true, 'settings: every Mission control on: ' .. tostring(err))

    local panel = Panel(3, CID[1]) or {}
    H.eq(panel.awardPoints and panel.awardPoints.max, 50, 'panel: Give points offered, 1 to 50')
    H.eq(panel.awardPoints and panel.awardPoints.perDay, 100, 'panel: ...100 a day')
    H.eq(panel.missionBan and panel.missionBan.max, 24, 'panel: Mission ban offered, 1 to 24 hours')
    H.eq((Panel(3, CID[8]) or {}).awardPoints ~= nil, true, 'panel: Give points for another supervisor too')
    H.eq((Panel(3, CID[3]) or {}).awardPoints, nil, 'panel: never for himself')

    -- Give points: inside 1..50, with a reason, 100 a day; never himself or another department
    local xp0 = W.Xp(CID[1])
    ok, err = Act('server:sup:awardPoints', 3,
        { citizenid = CID[1], points = 50, reason = 'Great arrest', activityOf = CID[1] })
    H.eq(ok, true, 'points: 50 to Ada: ' .. tostring(err))
    H.eq(W.Xp(CID[1]), xp0 + 50, 'points: her XP has them')
    H.ok(type(err) == 'table' and type(err.activity) == 'table', 'points: the reply carries her panel')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[1], points = 51, reason = 'Too many' })
    H.eq(err, 'err.award_points_range', 'points: 51 is above the admin\'s max')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[1], points = 0, reason = 'None' })
    H.eq(err, 'err.award_points_range', 'points: 0 is below the min')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[1], points = 5 })
    H.eq(err, 'err.reason_required', 'points: a reason is needed')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[3], points = 5, reason = 'Me' })
    H.eq(ok, false, 'points: never himself (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[2], points = 5, reason = 'FIB' })
    H.eq(err, 'err.other_department', 'points: never another department')
    ok, err = Act('server:sup:awardPoints', 1, { citizenid = CID[6], points = 5, reason = 'Officer' })
    H.eq(ok, false, 'points: an officer cannot (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[6], points = 40, reason = 'Backup' })
    H.eq(ok, true, 'points: 40 to Cleo (90 today): ' .. tostring(err))
    -- a restart and his drop never reset today's count
    W.Restart()
    W.Drop(3)
    W.Reconnect(3)
    H.eq((Panel(3, CID[1]) or {}).awardPoints and Panel(3, CID[1]).awardPoints.usedToday, 90,
        'restart: 90 of 100 given today')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[7], points = 11, reason = 'Over the day' })
    H.eq(err, 'err.award_daily_limit', 'points: 11 more would pass 100 a day')
    ok, err = Act('server:sup:awardPoints', 3, { citizenid = CID[7], points = 10, reason = 'Up to 100' })
    H.eq(ok, true, 'points: 10 more reaches 100: ' .. tostring(err))
    ok, err = Act('server:sup:awardPoints', 8, { citizenid = CID[7], points = 10, reason = 'Second sup' })
    H.eq(ok, true, 'points: the second supervisor has his own 100: ' .. tostring(err))
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'manualAward' AND role = 'supervisor']]), 4,
        'points: four awards audited as supervisor')
    -- AdminControl.pointAdjust off stops every award
    ok, err = Setting('AdminControl.pointAdjust', false)
    H.eq(ok, true, 'settings: point adjusts off: ' .. tostring(err))
    ok, err = Act('server:sup:awardPoints', 8, { citizenid = CID[7], points = 5, reason = 'Off' })
    H.eq(err, 'err.award_off', 'points: refused while point adjusts are off')
    Setting('AdminControl.pointAdjust', true)
    -- the control off: refused, not offered
    controls.awardPoints.on = false
    Setting('MissionControls.controls', controls)
    ok, err = Act('server:sup:awardPoints', 8, { citizenid = CID[7], points = 5, reason = 'Off' })
    H.eq(err, 'err.control_off', 'points: refused while the control is off')
    H.eq((Panel(8, CID[7]) or {}).awardPoints, nil, 'points: ...and not offered')
    controls.awardPoints.on = true
    Setting('MissionControls.controls', controls)

    -- Mission ban: a lower grade of his department, 1..24 hours, 3 a day; the setter (or an admin) lifts it
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[1], hours = 25, reason = 'Too long' })
    H.eq(err, 'err.mission_ban_hours', 'ban: 25 hours is above the max')
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[8], hours = 1, reason = 'Same grade' })
    H.eq(err, 'err.mission_ban_grade', 'ban: never the same grade (the other supervisor)')
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[2], hours = 1, reason = 'FIB' })
    H.eq(err, 'err.other_department', 'ban: never another department')
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[3], hours = 1, reason = 'Me' })
    H.eq(ok, false, 'ban: never himself (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:missionBan', 1, { citizenid = CID[6], hours = 1, reason = 'Officer' })
    H.eq(ok, false, 'ban: an officer cannot (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:missionBan', 3,
        { citizenid = CID[1], hours = 2, reason = 'Ignored an order', activityOf = CID[1] })
    H.eq(ok, true, 'ban: Ada barred for 2 hours: ' .. tostring(err))
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.mission_banned', 'ban: she cannot take a mission')
    ok, err = Act('server:sup:missionBan', 8, { citizenid = CID[1], hours = 5, reason = 'Mine now' })
    H.eq(err, 'err.mission_ban_exists', 'ban: another supervisor cannot replace it')
    H.eq((Panel(8, CID[1]) or {}).missionBan and Panel(8, CID[1]).missionBan.canLift, false,
        'ban: ...and is not offered Lift')
    -- the officer quits and comes back, then a restart: still barred
    W.Drop(1)
    W.Reconnect(1)
    W.Restart()
    ok, err = Act('server:acceptType', 1, 'patrol')
    H.eq(err, 'err.mission_banned', 'restart: still barred')
    ok, err = Act('server:restriction', 8,
        { op = 'lift', kind = 'missionBan', citizenid = CID[1], reason = 'Not mine' })
    H.eq(err, 'err.mission_ban_not_yours', 'lift: another supervisor cannot')
    ok, err = Act('server:restriction', 3, { op = 'lift', kind = 'missionBan', citizenid = CID[1] })
    H.eq(err, 'err.reason_required', 'lift: a reason is needed')
    ok, err = Act('server:restriction', 3,
        { op = 'lift', kind = 'missionBan', citizenid = CID[1], reason = 'Talked it through' })
    H.eq(ok, true, 'lift: the setter lifts it: ' .. tostring(err))
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    ok, err = Act('server:acceptType', 1, 'patrol')
    Config.DisabledMissions = {}
    H.eq(ok, true, 'lift: she takes a mission again: ' .. tostring(err))
    Leave(1)
    -- three a day: the fourth refused; the ban of an offline officer refused
    for i, src in ipairs({ 6, 7 }) do
        ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[src], hours = 1, reason = 'Ban ' .. i })
        H.eq(ok, true, ('ban: ban %d of today: %s'):format(i + 1, tostring(err)))
    end
    ok, err = Act('server:sup:missionBan', 3, { citizenid = CID[9], hours = 1, reason = 'Fourth' })
    H.eq(err, 'err.mission_ban_used', 'ban: a fourth today is refused (missionBanPerDay 3)')
    W.Drop(9)
    ok, err = Act('server:sup:missionBan', 8, { citizenid = CID[9], hours = 1, reason = 'Offline' })
    H.eq(err, 'err.mission_ban_offline', 'ban: an offline officer cannot be barred')
    W.Reconnect(9)
    for _, src in ipairs({ 6, 7 }) do
        Act('server:restriction', 3, { op = 'lift', kind = 'missionBan', citizenid = CID[src], reason = 'Done' })
    end
    -- the Restrictions tab lists his department's bans
    ok, err = Act('server:sup:missionBan', 8, { citizenid = CID[9], hours = 1, reason = 'Listed' })
    H.eq(ok, true, 'ban: the second supervisor bars the cadet: ' .. tostring(err))
    local list = Cb('sup:getRestrictions', 3)
    H.ok(type(list) == 'table', 'restrictions: the tab opens')
    H.ok(Count('SELECT COUNT(*) AS n FROM cp_audit WHERE action = ?', { 'missionBan' }) >= 4, 'ban: audited')
    Act('server:restriction', 8, { op = 'lift', kind = 'missionBan', citizenid = CID[9], reason = 'Done' })

    -- Clear cooldown: one type or mission, a reason, never while he is on a run, 5 a day per supervisor
    H.ok(AbandonPatrol(6), 'cooldown: Cleo has the Patrol type cooldown')
    ok, err = Act('server:sup:clearCooldowns', 3, { citizenid = CID[6], scope = 'type', key = 'patrol' })
    H.eq(err, 'err.reason_required', 'clear: a reason is needed')
    ok, err = Act('server:sup:clearCooldowns', 3, { citizenid = CID[6], scope = 'all', key = 'patrol', reason = 'All' })
    H.eq(err, 'err.invalid_payload', 'clear: never all at once for a supervisor')
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[6], scope = 'type', key = 'nope', reason = 'Unknown' })
    H.eq(err, 'err.unknown_type', 'clear: an unknown type')
    ok, err = Act('server:sup:clearCooldowns', 3, { citizenid = CID[3], scope = 'type', key = 'patrol', reason = 'Me' })
    H.eq(err, 'err.self_target', 'clear: never his own')
    ok, err = Act('server:sup:clearCooldowns', 1,
        { citizenid = CID[6], scope = 'type', key = 'patrol', reason = 'Officer' })
    H.eq(ok, false, 'clear: an officer cannot (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[6], scope = 'type', key = 'patrol', reason = 'Needed on Patrol' })
    H.eq(ok, true, 'clear: the supervisor clears Cleo\'s Patrol cooldown: ' .. tostring(err))
    H.eq(CP.Runs.cooldowns(CID[6]).types.patrol, nil, 'clear: gone')
    H.ok(type(err) == 'table' and type(err.view) == 'table', 'clear: the reply carries her cooldown list')
    -- another department's officer: allowed (the control is server-wide)
    H.ok(AbandonPatrol(2), 'cooldown: the FIB agent has the Patrol type cooldown')
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[2], scope = 'type', key = 'patrol', reason = 'Joint op' })
    H.eq(ok, true, 'clear: a FIB agent\'s too (any department): ' .. tostring(err))
    -- on a run: refused
    Later()
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    Act('server:acceptType', 7, 'patrol')
    Config.DisabledMissions = {}
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[7], scope = 'type', key = 'patrol', reason = 'On a run' })
    H.eq(ok, false, 'clear: refused while the officer is on a run (' .. tostring(err) .. ')')
    Leave(7)
    -- one officer: 3 clears a day by all staff; one supervisor: 5 a day
    for i = 2, 3 do
        AbandonPatrol(6)
        ok, err = Act('server:sup:clearCooldowns', i == 2 and 8 or 3,
            { citizenid = CID[6], scope = 'type', key = 'patrol', reason = 'Again ' .. i })
        H.eq(ok, true, ('clear: Cleo\'s clear %d of today: %s'):format(i, tostring(err)))
    end
    AbandonPatrol(6)
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[6], scope = 'type', key = 'patrol', reason = 'Fourth' })
    H.eq(err, 'err.live_clear_limit', 'clear: a fourth clear of one officer today is refused')
    W.Restart()
    ok, err = Act('server:sup:clearCooldowns', 8,
        { citizenid = CID[6], scope = 'type', key = 'patrol', reason = 'After restart' })
    H.eq(err, 'err.live_clear_limit', 'restart: the officer\'s count is kept')
    for _, src in ipairs({ 7, 9 }) do
        AbandonPatrol(src)
        ok, err = Act('server:sup:clearCooldowns', 3,
            { citizenid = CID[src], scope = 'type', key = 'patrol', reason = 'Count' })
        H.eq(ok, true, ('clear: %s cleared: %s'):format(CID[src], tostring(err)))
    end
    AbandonPatrol(1)
    ok, err = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[1], scope = 'type', key = 'patrol', reason = 'Sixth' })
    H.eq(err, 'err.sup_clear_used', 'clear: his sixth clear today is refused (clearCooldownPerDay 5)')
    H.eq((Panel(3, CID[1]) or {}).cooldownClear and Panel(3, CID[1]).cooldownClear.usedToday, 5,
        'clear: the panel shows 5 of 5 used')
end

-- ============================================================================
--                             4. MISSION CONTROLS
-- ============================================================================
-- EVERY CONTROL, ITS LIMITS, HAPPY HOUR.

-- A value outside the admin's limits for a number control (nil when none is), and one inside them.
local function Outside(c)
    if c.kind ~= 'number' or not c.bounded then return nil end
    return (c.max or 0) + (c.integer and 1 or 0.5)
end
local function Inside(c)
    if c.kind == 'number' then
        if c.key == 'readyCheck' then return c.max end
        return c.min ~= c.configValue and c.min or c.max
    elseif c.kind == 'choice' then
        for _, v in ipairs(c.offered or c.choices or {}) do if v ~= c.configValue then return v end end
    elseif c.kind == 'map' then
        return c.configValue      -- the config value is always a valid shape
    elseif c.kind == 'boolean' or type(c.configValue) == 'boolean' then
        return not c.configValue
    end
    return nil
end
-- A value as text with its keys sorted (a saved map comes back in any key order).
local function Canon(v)
    if type(v) ~= 'table' then return cjson.encode(v) end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        local x = v[k]
        if x == nil then x = v[tonumber(k)] end
        parts[#parts + 1] = k .. '=' .. Canon(x)
    end
    return '{' .. table.concat(parts, ',') .. '}'
end
local function SavedOf(src)
    local view = Cb('sup:getMissionControls', src) or {}
    local out = {}
    for _, d in ipairs(view.departments or {}) do
        for _, c in ipairs(d.controls or {}) do out[c.key] = c.saved end
    end
    for _, c in ipairs(view.serverWide or {}) do out[c.key] = c.saved end
    return out, view
end

do
    NextDay()
    local view = Cb('sup:getMissionControls', 3)
    H.ok(view ~= nil and view.master == true, 'controls: the supervisor opens Mission controls (master switch on)')
    local list = {}
    for _, d in ipairs(view and view.departments or {}) do
        H.eq(d.key, 'sast', 'controls: only his own department is listed')
        for _, c in ipairs(d.controls or {}) do list[#list + 1] = c end
    end
    for _, c in ipairs(view and view.serverWide or {}) do list[#list + 1] = c end
    H.ok(#list >= 30, 'controls: every control is listed (' .. #list .. ')')

    -- every control: a value outside the limits refused, one inside saved, the second supervisor then waits
    local set, swept = {}, 0
    for _, c in ipairs(list) do
        if c.kind ~= 'action' and c.key ~= 'happyHour' and c.key ~= 'typeOfTheDay' then
            swept = swept + 1
            local out = Outside(c)
            if out ~= nil then
                local ok, err = SetControl(3, c.key, out)
                H.eq(err, 'err.control_value', ('controls: %s = %s is outside the limits'):format(c.key, tostring(out)))
            end
            if c.kind ~= 'number' then
                local ok, err = SetControl(3, c.key, 'not a value')
                H.eq(ok, false, ('controls: %s refuses a bad value (%s)'):format(c.key, tostring(err)))
            end
            local value = Inside(c)
            if value ~= nil then
                local ok, err = SetControl(3, c.key, value)
                H.eq(ok, true, ('controls: %s set to %s: %s'):format(c.key, cjson.encode(value), tostring(err)))
                if ok then set[c.key] = value end
                ok, err = SetControl(8, c.key, value)
                H.eq(ok, false, ('controls: %s: the second supervisor waits for the change wait'):format(c.key))
                H.ok(tostring(err):find('err.control_wait', 1, true) ~= nil or tostring(err):find('wait') ~= nil,
                    ('controls: ...and is told so (%s)'):format(tostring(err)))
            end
        end
    end
    H.ok(swept >= 20, 'controls: the sweep covered every value control (' .. swept .. ')')
    -- his drop and a restart keep every saved value
    W.Drop(3)
    W.Reconnect(3)
    W.Restart()
    local saved = SavedOf(3)
    for key, value in pairs(set) do
        local got = saved[key]
        if key == 'goals' and type(got) == 'table' then got = { daily = got.daily, weekly = got.weekly } end
        H.eq(Canon(got), Canon(value), ('restart: %s keeps %s'):format(key, Canon(value)))
    end
    -- Reset brings back config.lua's value (no change wait for a reset)
    for key in pairs(set) do
        local ok, err = ResetControl(3, key)
        H.eq(ok, true, ('controls: %s reset: %s'):format(key, tostring(err)))
    end
    saved = SavedOf(3)
    local left = 0
    for key in pairs(set) do if saved[key] ~= nil then left = left + 1 end end
    H.eq(left, 0, 'controls: every reset control is back on config.lua')
    local ok, err = ResetControl(3, 'unitSize')
    H.eq(err, 'err.control_not_set', 'controls: a reset of a control not set is refused')
    ok, err = SetControl(3, 'nope', 1)
    H.eq(ok, false, 'controls: an unknown control is refused (' .. tostring(err) .. ')')
    ok, err = SetControl(3, 'awardPoints', 5)
    H.eq(ok, false, 'controls: an action control has no value (' .. tostring(err) .. ')')
    ok, err = Act('server:sup:setMissionControl', 3, { key = 'unitSize', value = 3, requestId = W.RequestId() })
    H.eq(err, 'err.reason_required', 'controls: a reason is needed')

    -- an officer: no Mission controls screen, no change
    local v
    v, err = Cb('sup:getMissionControls', 1)
    H.eq(v, nil, 'controls: an officer cannot open them (' .. tostring(err) .. ')')
    AfterWait()
    ok, err = SetControl(1, 'unitSize', 3)
    H.eq(err, 'err.no_permission', 'controls: an officer cannot change one')

    -- one control off: refused; the master switch off: the controls under it refused, the server-wide ones not
    local controls = CP.U.copy(Config.MissionControls.controls)
    controls.unitSize.on = false
    Setting('MissionControls.controls', controls)
    ok, err = SetControl(3, 'unitSize', 3)
    H.eq(err, 'err.control_off', 'controls: a control the admin switched off is refused')
    controls.unitSize.on = true
    Setting('MissionControls.controls', controls)
    Setting('Permissions.supervisor.missionControls', false)
    ok, err = SetControl(3, 'unitSize', 3)
    H.eq(ok, false, 'master off: unit size refused (' .. tostring(err) .. ')')
    ok, err = SetControl(3, 'hourlyCap', 8)
    H.eq(ok, true, 'master off: the hourly cap (outside the master switch) still set: ' .. tostring(err))
    H.ok(Cb('sup:getMissionControls', 3) ~= nil, 'master off: the screen still opens for those')
    ResetControl(3, 'hourlyCap')
    Setting('Permissions.supervisor.missionControls', true)

    -- a department's grade rule: SAST from grade 4 only; FIB keeps every supervisor
    ok, err = Setting('MissionControls.grants', { sast = { minGrade = 4 } })
    H.eq(ok, true, 'grants: SAST controls from grade 4: ' .. tostring(err))
    AfterWait()
    ok, err = SetControl(3, 'unitSize', 3)
    H.eq(err, 'err.no_permission', 'grants: the grade 3 SAST supervisor is refused')
    ok, err = SetControl(4, 'unitSize', 3)
    H.eq(ok, true, 'grants: the FIB supervisor is not: ' .. tostring(err))
    ResetControl(4, 'unitSize')
    PD[3].job.grade.level = 4
    TriggerEvent('QBCore:Server:OnJobUpdate', 3, PD[3].job)
    Secs(2)
    ok, err = SetControl(3, 'unitSize', 3)
    H.eq(ok, true, 'grants: promoted to grade 4 he may: ' .. tostring(err))
    ResetControl(3, 'unitSize')
    PD[3].job.grade.level = 3
    TriggerEvent('QBCore:Server:OnJobUpdate', 3, PD[3].job)
    Secs(2)
    Setting('MissionControls.grants', {})

    -- the Type of the Day: once a day for his department
    AfterWait()
    ok, err = SetControl(3, 'typeOfTheDay', 'training')
    H.eq(ok, true, 'tod: the supervisor picks Training for tomorrow: ' .. tostring(err))
    AfterWait()
    ok, err = SetControl(8, 'typeOfTheDay', 'tactical')
    H.eq(ok, false, 'tod: a second pick the same day is refused (' .. tostring(err) .. ')')
end

-- Happy hour: 5 to 30 minutes, scale 0 only (shipped), once a day for supervisors, never for the one who started it.
do
    NextDay()
    local function Scale(src)
        local o = CP.Access.getOfficer(src)
        local v = CP.DeptControls.get(o.department, 'cooldownScale', o)
        if type(v) ~= 'table' then return v end
        return v.patrol or 1    -- a type left out of the map keeps x1
    end
    H.eq(Scale(1), 1, 'happy hour: before it, Patrol\'s cooldown x1')
    local ok, err = SetControl(3, 'happyHour', { minutes = 31 })
    H.eq(err, 'err.control_value', 'happy hour: 31 minutes is above the max')
    ok, err = SetControl(3, 'happyHour', { minutes = 4 })
    H.eq(err, 'err.control_value', 'happy hour: 4 minutes is below the min')
    ok, err = SetControl(3, 'happyHour', { minutes = 10, scale = 0.5 })
    H.eq(err, 'err.control_value', 'happy hour: a scale the admin does not allow')
    ok, err = SetControl(1, 'happyHour', { minutes = 10 })
    H.eq(err, 'err.no_permission', 'happy hour: an officer cannot start one')
    ok, err = SetControl(3, 'happyHour', { minutes = 10 })
    H.eq(ok, true, 'happy hour: the supervisor starts 10 minutes: ' .. tostring(err))
    H.eq(Scale(1), 0, 'happy hour: Ada\'s cooldowns are lifted')
    H.eq(Scale(4), 0, 'happy hour: ...and FIB\'s (server-wide)')
    H.eq(Scale(3), 1, 'happy hour: never for the one who started it (selfExempt)')
    ok, err = SetControl(8, 'happyHour', { minutes = 10 })
    H.eq(ok, false, 'happy hour: a second one while it runs is refused (' .. tostring(err) .. ')')
    -- his drop and a restart: it runs on
    W.Drop(3)
    H.eq(Scale(1), 0, 'drop: it runs on')
    W.Reconnect(3)
    W.Restart()
    H.eq(Scale(1), 0, 'restart: it runs on')
    H.eq(Scale(3), 1, 'restart: ...still not for him')
    -- the self rule off: it applies to him too
    Setting('MissionControls.selfExempt', false)
    H.eq(Scale(3), 0, 'selfExempt off: it applies to its starter too')
    Setting('MissionControls.selfExempt', true)
    -- it ends after 10 minutes; another one today is refused (perDay 1), an admin may
    Secs(10 * 60 + 40)
    H.eq(Scale(1), 1, 'happy hour: over after 10 minutes')
    AfterWait()
    ok, err = SetControl(8, 'happyHour', { minutes = 5 })
    H.eq(ok, false, 'happy hour: a second one today is refused (perDay 1) (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setMissionControl', 5,
        { key = 'happyHour', value = { minutes = 5 }, reason = 'Admin', requestId = W.RequestId() })
    H.eq(ok, true, 'happy hour: an admin may start another: ' .. tostring(err))
    Secs(5 * 60 + 40)
    NextDay()
    ok, err = SetControl(8, 'happyHour', { minutes = 5 })
    H.eq(ok, true, 'happy hour: the next day a supervisor may again: ' .. tostring(err))
    Secs(5 * 60 + 40)
end

-- ============================================================================
--                             5. THE REVIEW QUEUE
-- ============================================================================
-- APPROVE, VOID, A SECOND VOID, UNDO, A RESTART.

local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
-- A flagged Beat Patrol: one checkpoint, a 3 km jump in a second (the speed check), then the rest. Its row.
local function FlaggedPatrol(src, far)
    Later()
    local run = W.Accept(src, 'patrol', PATROL_OTHERS)
    Config.DisabledMissions = {}
    if not run then return {} end
    local veh = W.TakeWheel(src, run)
    W.DriveCheckpoints(src, run, veh, 1, 1)
    Place(src, far)
    Secs(1)
    W.Objective(src, run, 1, W.CheckpointEv(2, veh))
    H.eq(run.flagged and run.flagged.reason, 'speed', ('%s: the jump flags the run'):format(CID[src]))
    W.DriveCheckpoints(src, run, veh, 2, #run.objectives[1].state.points, 20)
    H.eq(run.state, 'ended', ('%s: the flagged run still completes'):format(CID[src]))
    Secs(3)
    return W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[src] })[1] or {}
end
local function InQueue(src, rowId)
    for _, f in ipairs(H.reviewItems(Cb('review:getQueue', src), 'flag')) do
        if f.id == rowId or f.rowId == rowId then return true end
    end
    return false
end
local function Decide(src, payload) return Act('server:review:decide', src, payload) end
local function Bit(v) return v == true or tonumber(v) == 1 end
local function Row(id) return W.Rows('id = ?', { id })[1] or {} end

do
    NextDay()
    -- a flagged run of a SAST officer: held, in the SAST supervisors' queue only
    local r = FlaggedPatrol(1, vec3(3000.0, 3000.0, 30.0))
    H.eq(Bit(r.flagged), true, 'review: Ada\'s row is flagged')
    H.eq(r.cash_status, 'held', 'review: its cash held')
    H.ok(InQueue(3, r.id), 'review: in the SAST supervisor\'s queue')
    H.ok(InQueue(8, r.id), 'review: ...and the second SAST supervisor\'s')
    H.eq(InQueue(4, r.id), false, 'review: not in FIB\'s')
    local q, err = Cb('review:getQueue', 1)
    H.ok(q == nil or #H.reviewItems(q, 'flag') == 0, 'review: an officer has no queue (' .. tostring(err) .. ')')
    local ok, data = Decide(4, { type = 'flag', id = r.id, decision = 'approve', reason = 'FIB' })
    H.eq(ok, false, 'review: the FIB supervisor cannot decide it (' .. tostring(data) .. ')')
    ok, data = Decide(1, { type = 'flag', id = r.id, decision = 'approve', reason = 'Mine' })
    H.eq(ok, false, 'review: the officer cannot approve his own (' .. tostring(data) .. ')')
    ok, data = Decide(3, { type = 'flag', id = r.id, decision = 'approve' })
    H.eq(data, 'err.reason_required', 'review: a reason is needed')
    -- a restart and the reviewer's drop with the queue open: still there
    W.Restart()
    W.Drop(3)
    W.Reconnect(3)
    H.ok(InQueue(3, r.id), 'restart: still in his queue')
    -- the two supervisors both have it open: one approves, the other's queue is pushed at once
    InQueue(8, r.id)
    local mark = #H.events
    local paid0 = W.Paid(CID[1])
    ok, data = Decide(3, { type = 'flag', id = r.id, decision = 'approve', reason = 'GPS glitch' })
    H.eq(ok, true, 'review: the SAST supervisor approves: ' .. tostring(data))
    H.ok(type(data) == 'table' and type(data.queue) == 'table', 'review: the reply carries his fresh queue')
    Secs(5)
    local pushed = false
    for _, e in ipairs(W.ClientEvents('crimson-police:client:push', 8, mark)) do
        if e.args[1] == 'reviewQueue' then pushed = true end
    end
    H.ok(pushed, 'review: the second supervisor\'s open queue is updated at once')
    H.eq(Row(r.id).cash_status, 'paid', 'review: the held cash is paid')
    H.eq(W.Paid(CID[1]), paid0 + 1, 'review: ...once')
    ok, data = Decide(8, { type = 'flag', id = r.id, decision = 'approve', reason = 'Me too' })
    H.eq(ok, false, 'review: the second supervisor\'s approve of the same row is refused (' .. tostring(data) .. ')')
    H.eq(W.Paid(CID[1]), paid0 + 1, 'review: ...and pays nothing more')

    -- void: a supervisor voids; undo and batches are the admin's (Config.AdminUi.reviewUndo)
    local v = FlaggedPatrol(6, vec3(-3000.0, 3000.0, 30.0))
    ok, data = Decide(3, { type = 'flag', id = v.id, decision = 'void', reason = 'Teleport' })
    H.eq(ok, true, 'void: the supervisor voids Cleo\'s flagged run: ' .. tostring(data))
    H.eq(Bit(Row(v.id).voided), true, 'void: voided')
    ok, data = Decide(3, { type = 'flag', id = v.id, decision = 'undo', reason = 'Oops' })
    H.eq(ok, false, 'undo: a supervisor cannot undo a void (' .. tostring(data) .. ')')
    ok, data = Decide(3, { type = 'batch', id = 'batch-1', decision = 'undo', reason = 'Oops' })
    H.eq(ok, false, 'undo: ...or a correction batch (' .. tostring(data) .. ')')
    ok, data = Decide(5, { type = 'flag', id = v.id, decision = 'undo', reason = 'Wrong call', all = true })
    H.eq(ok, true, 'undo: the admin undoes it from his queue: ' .. tostring(data))
    H.eq(Bit(Row(v.id).voided), false, 'undo: restored')
    Setting('AdminUi.reviewUndo', false)
    ok, data = Decide(3, { type = 'flag', id = v.id, decision = 'void', reason = 'Again' })
    ok, data = Decide(5, { type = 'flag', id = v.id, decision = 'undo', reason = 'Off', all = true })
    H.eq(data, 'err.review_undo_off', 'undo: refused while the admin switched Undo off')
    Setting('AdminUi.reviewUndo', true)

    -- the department's review rule: a supervisor's Void waits for a second supervisor
    local ok2, err2 = SetControl(3, 'reviewRules', { secondVoid = true, adminOnlyKinds = {} })
    H.eq(ok2, true, 'rules: SAST asks for a second supervisor\'s Void: ' .. tostring(err2))
    local s = FlaggedPatrol(7, vec3(3000.0, -3000.0, 30.0))
    ok, data = Decide(3, { type = 'flag', id = s.id, decision = 'void', reason = 'Jumped' })
    H.eq(ok, true, 'rules: the first Void is taken: ' .. tostring(data))
    H.eq(type(data) == 'table' and data.pending, true, 'rules: ...and waits for a second supervisor')
    H.eq(Bit(Row(s.id).voided), false, 'rules: not voided yet')
    ok, data = Decide(3, { type = 'flag', id = s.id, decision = 'void', reason = 'Jumped again' })
    H.eq(ok, false, 'rules: the same supervisor cannot be the second (' .. tostring(data) .. ')')
    W.Restart()
    ok, data = Decide(8, { type = 'flag', id = s.id, decision = 'void', reason = 'Agreed' })
    H.eq(ok, true, 'rules: after a restart the second supervisor\'s Void voids it: ' .. tostring(data))
    H.eq(type(data) == 'table' and data.pending, nil,
        'rules: ...not a first Void again (' .. cjson.encode(type(data) == 'table' and data or {}):sub(1, 200) .. ')')
    H.eq(Bit(Row(s.id).voided), true, 'rules: voided')
    AfterWait()
    ResetControl(3, 'reviewRules')

    -- the review power off: no queue, no decision
    local f = FlaggedPatrol(9, vec3(-3000.0, -3000.0, 30.0))
    Setting('Permissions.supervisor.reviewFlagged', false)
    ok, data = Decide(3, { type = 'flag', id = f.id, decision = 'approve', reason = 'Off' })
    H.eq(ok, false, 'power off: a supervisor cannot approve (' .. tostring(data) .. ')')
    Setting('Permissions.supervisor.reviewFlagged', true)
    ok, data = Decide(8, { type = 'flag', id = f.id, decision = 'approve', reason = 'Back on' })
    H.eq(ok, true, 'power on: approved: ' .. tostring(data))
    -- his own flagged run is never in his queue: the other supervisor reviews it
    local own = FlaggedPatrol(8, vec3(2500.0, 2500.0, 30.0))
    H.eq(InQueue(8, own.id), false, 'own run: not in his own queue')
    ok, data = Decide(8, { type = 'flag', id = own.id, decision = 'approve', reason = 'Mine' })
    H.eq(ok, false, 'own run: he cannot approve it (' .. tostring(data) .. ')')
    H.ok(InQueue(3, own.id), 'own run: the other SAST supervisor has it')
    ok, data = Decide(3, { type = 'flag', id = own.id, decision = 'approve', reason = 'Checked' })
    H.eq(ok, true, 'own run: the other one approves: ' .. tostring(data))
end

-- ============================================================================
--                             6. CALLS AND NOTICES
-- ============================================================================
-- A MISSION CALL, A DEPARTMENT NOTICE.

local function CallOf(src, id)
    for _, c in ipairs((CP.MissionCalls.list(src) or {}).calls or {}) do if c.id == id then return c end end
    return nil
end
local function HomeHas(src, text) return cjson.encode(Cb('getHome', src) or {}):find(text, 1, true) ~= nil end

do
    NextDay()
    -- Dispatch: the supervisor opens the panel, creates a call, the officers see it; the wait between two
    local view, err = Cb('sup:getMissionCalls', 3)
    H.ok(type(view) == 'table', 'calls: the supervisor opens the Dispatch panel: ' .. tostring(err))
    view, err = Cb('sup:getMissionCalls', 1)
    H.eq(view, nil, 'calls: an officer has no panel (' .. tostring(err) .. ')')
    local ok, data = Act('server:sup:mcPost', 3, { type = 'patrol' })
    H.eq(ok, true, 'calls: the supervisor creates a Patrol call: ' .. tostring(data))
    local id = type(data) == 'table' and data.id or nil
    H.ok(type(data) == 'table' and type(data.view) == 'table', 'calls: the reply carries his panel')
    H.ok(CallOf(1, id) ~= nil, 'calls: Ada sees it on Dispatch')
    ok, data = Act('server:sup:mcPost', 3, { type = 'patrol' })
    H.eq(data, 'err.mc_staff_cooldown', 'calls: a second one at once waits for the staff wait')
    ok, data = Act('server:sup:mcPost', 3, { type = 'nope' })
    H.eq(ok, false, 'calls: an unknown type is refused (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcPost', 1, { type = 'patrol' })
    H.eq(ok, false, 'calls: an officer cannot create one (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcPost', 8, { type = 'investigation' })
    H.eq(ok, true, 'calls: the second supervisor has his own wait: ' .. tostring(data))
    local id2 = type(data) == 'table' and data.id or nil
    -- his drop: the call stays open
    W.Drop(3)
    H.ok(CallOf(1, id) ~= nil, 'drop: his call stays open')
    W.Reconnect(3)
    -- withdraw: a reason; another department's supervisor cannot
    ok, data = Act('server:sup:mcWithdraw', 3, { callId = id })
    H.eq(data, 'err.reason_required', 'withdraw: a reason is needed')
    ok, data = Act('server:sup:mcWithdraw', 1, { callId = id, reason = 'Officer' })
    H.eq(ok, false, 'withdraw: an officer cannot (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcWithdraw', 3, { callId = id, reason = 'Handled by radio' })
    H.eq(ok, true, 'withdraw: the supervisor withdraws it: ' .. tostring(data))
    H.eq(CallOf(1, id), nil, 'withdraw: gone from Dispatch')
    ok, data = Act('server:sup:mcWithdraw', 3, { callId = id, reason = 'Twice' })
    H.eq(ok, false, 'withdraw: twice is refused (' .. tostring(data) .. ')')
    -- a restart: the open call lapses
    W.Restart()
    H.eq(CallOf(1, id2), nil, 'restart: the open call is gone')
    -- the power off: no panel, no call
    Setting('Permissions.supervisor.missionCalls', false)
    ok, data = Act('server:sup:mcPost', 8, { type = 'patrol' })
    H.eq(ok, false, 'power off: no call (' .. tostring(data) .. ')')
    H.eq(Cb('sup:getMissionCalls', 8), nil, 'power off: no panel')
    Setting('Permissions.supervisor.missionCalls', true)

    -- a department notice: SAST officers see it on Home, FIB never; it ends early or after its days
    local TEXT = 'Briefing at 20:00 at Mission Row.'
    ok, data = Act('server:notice:post', 3, { kind = 'department', text = TEXT, days = 31 })
    H.eq(data, 'err.notice_expiry', 'notice: more days than the admin allows')
    ok, data = Act('server:notice:post', 3, { kind = 'department', text = '', days = 1 })
    H.eq(ok, false, 'notice: no text (' .. tostring(data) .. ')')
    ok, data = Act('server:notice:post', 1, { kind = 'department', text = TEXT, days = 1 })
    H.eq(ok, false, 'notice: an officer cannot post (' .. tostring(data) .. ')')
    ok, data = Act('server:notice:post', 3, { kind = 'staff', text = TEXT, days = 1 })
    H.eq(ok, false, 'notice: a supervisor never posts a staff notice (' .. tostring(data) .. ')')
    ok, data = Act('server:notice:post', 3, { kind = 'department', text = TEXT, days = 1 })
    H.eq(ok, true, 'notice: the supervisor posts a SAST notice: ' .. tostring(data))
    local nid = type(data) == 'table' and data.id or nil
    H.ok(HomeHas(1, TEXT), 'notice: Ada sees it on Home')
    H.eq(HomeHas(2, TEXT), false, 'notice: the FIB agent never does')
    local nv = Cb('notices:get', 3, { kind = 'department' }) or {}
    H.eq(#(nv.running or {}), 1, 'notice: his panel lists it running')
    H.eq(nv.usedToday, 1, 'notice: ...one of his five today')
    W.Restart()
    H.ok(HomeHas(1, TEXT), 'restart: still on Ada\'s Home')
    ok, data = Act('server:notice:end', 4, { id = nid, reason = 'FIB' })
    H.eq(data, 'err.dept_notice_unknown', 'notice: the FIB supervisor cannot end it')
    ok, data = Act('server:notice:end', 8, { id = nid })
    H.eq(ok, true, 'notice: the second SAST supervisor ends it: ' .. tostring(data))
    H.eq(HomeHas(1, TEXT), false, 'notice: gone from Home')
    -- five running at most, five a day each
    for i = 1, 5 do
        Secs(70)
        ok, data = Act('server:notice:post', 3, { kind = 'department', text = TEXT .. ' ' .. i, days = 1 })
        H.eq(ok, i <= 4, ('notice: notice %d of today: %s'):format(i + 1, tostring(data)))
    end
    ok, data = Act('server:notice:post', 8, { kind = 'department', text = TEXT .. ' five', days = 1 })
    H.eq(ok, true, 'notice: the second supervisor posts the fifth running one: ' .. tostring(data))
    Secs(70)
    ok, data = Act('server:notice:post', 8, { kind = 'department', text = TEXT .. ' six', days = 1 })
    H.eq(data, 'err.dept_notice_too_many', 'notice: a sixth running in SAST is refused (maxRunning 5)')
    -- the control off: no notice
    local controls = CP.U.copy(Config.MissionControls.controls)
    controls.notices.on = false
    Setting('MissionControls.controls', controls)
    ok, data = Act('server:notice:post', 4, { kind = 'department', text = TEXT, days = 1 })
    H.eq(ok, false, 'notice: refused while the control is off (' .. tostring(data) .. ')')
    controls.notices.on = true
    Setting('MissionControls.controls', controls)
    for _, r in ipairs((Cb('notices:get', 3, { kind = 'department' }) or {}).running or {}) do
        Act('server:notice:end', 3, { id = r.id })
    end
end

-- ============================================================================
--                              7. FIELD TRAINING
-- ============================================================================
-- PAIR, SIGN OFF, UNPAIR, THEIR REFUSALS.

do
    NextDay()
    local ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, false, 'fto: off as shipped: pairing refused (' .. tostring(data) .. ')')
    for _, c in ipairs({
        { 'Recognition.fieldTraining.enabled', true },
        { 'Recognition.fieldTraining.tasks', { patrol = 1, investigation = 2 } },
    }) do
        ok, data = Setting(c[1], c[2])
        H.eq(ok, true, ('settings: %s saved: %s'):format(c[1], tostring(data)))
    end
    ok, data = Act('server:sup:ftoPair', 1, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, false, 'fto: an officer cannot pair (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[2], trainer = CID[8] })
    H.eq(ok, false, 'fto: never a FIB rookie (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[9] })
    H.eq(data, 'err.fto_same_officer', 'fto: never his own trainer')
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[6] })
    H.eq(data, 'err.fto_trainer_grade', 'fto: a trooper is below the trainer grade')
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[4] })
    H.eq(ok, false, 'fto: never a FIB trainer (' .. tostring(data) .. ')')
    W.Drop(8)
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[8] })
    H.eq(data, 'err.fto_trainer_offline', 'fto: an offline trainer')
    W.Reconnect(8)
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, true, 'fto: the supervisor pairs Eve with Max: ' .. tostring(data))
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[3] })
    H.eq(data, 'err.fto_already_paired', 'fto: twice is refused')
    local ft = Cb('sup:getFieldTraining', 3)
    H.ok(cjson.encode(ft or {}):find(CID[9], 1, true) ~= nil, 'fto: the Training tab lists the pair')
    H.eq(Cb('sup:getFieldTraining', 1), nil, 'fto: an officer has no Training tab')
    -- a sign-off before the count: refused; a run together: the trainer signs Patrol off
    ok, data = Act('server:fto:signOff', 8, { rookie = CID[9], task = 'patrol' })
    H.eq(data, 'err.fto_task_not_ready', 'fto: Patrol not ready before a run together')
    W.Restart()
    H.ok(type(Cb('fto:getMine', 9)) == 'table', 'restart: Eve still in training')
    Later()
    Place(9, AT)
    Place(8, vec3(AT.x + 2.0, AT.y, AT.z))
    W.FormUnit(9, 8)
    -- Beat Patrol (the only Patrol mission left on) is for one officer: both answer Ready, then the draw finds
    -- nothing for a unit of two; the leader is told why (his Accept reply said "ready check sent" long before)
    local SOLO_ONLY = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
    Config.DisabledMissions = SOLO_ONLY
    local mark = #H.events
    ok, data = Act('server:acceptType', 9, 'patrol')
    H.eq(type(data) == 'table' and data.pending, true, 'accept: the ready check is sent')
    Secs(5)
    Config.DisabledMissions = {}
    H.eq(CP.Runs.getBySrc(9), nil, 'accept: no run (no Patrol mission for two)')
    H.ok(W.Toasts(9, mark)['err.pool_empty'], 'accept: the leader is told no mission was left to draw')
    -- Street Race Bust for two: the run together, each objective done after its minimum time
    Later()
    Config.DisabledMissions = { 'beat_patrol', 'business_check', 'parking_patrol', 'traffic_enforcement' }
    ok, data = Act('server:acceptType', 9, 'patrol')
    H.eq(ok, true, 'accept: Street Race Bust for the two: ' .. tostring(data))
    Secs(5)                           -- the unit's ready check, then the run
    Config.DisabledMissions = {}
    local run = CP.Runs.getBySrc(9)
    H.ok(run ~= nil and CP.Runs.getBySrc(8) == run, 'fto: the rookie and his trainer are on one run')
    if run then
        W.Arrive(run, 9)
        W.Arrive(run, 8)
        for i = 1, #run.objectives do
            local o = run.objectives[i]
            if run.state ~= 'in_progress' then break end
            if o.status ~= 'done' and run.objectiveIndex == i then
                Secs(((o.obj and o.obj.minSeconds) or 0) + 2)
                CP.Runs.objectiveComplete(run, i, {})
                Secs(2)
            end
        end
        Secs(3)
        H.eq(run.state, 'ended', 'fto: the run together is over')
        for _, src in ipairs({ 9, 8 }) do
            local r = W.Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[src] })[1] or {}
            H.eq(r.state, 'completed', ('fto: %s\'s row Completed (flagged %s)'):format(CID[src], tostring(r.flagged)))
        end
    end
    Leave(9)
    Leave(8)
    ok, data = Act('server:fto:signOff', 3, { rookie = CID[9], task = 'patrol' })
    H.eq(data, 'err.fto_not_trainer', 'fto: only his trainer signs off')
    ok, data = Act('server:fto:signOff', 8, { rookie = CID[9], task = 'tactical' })
    H.eq(data, 'err.fto_task_unknown', 'fto: a type that is no task')
    ok, data = Act('server:fto:signOff', 8, { rookie = CID[9], task = 'patrol', note = 'Calm and safe' })
    H.eq(ok, true, 'fto: the trainer signs Patrol off: ' .. tostring(data))
    ok, data = Act('server:fto:signOff', 8, { rookie = CID[9], task = 'patrol' })
    H.eq(data, 'err.fto_task_signed', 'fto: twice is refused')
    -- unpair: only a supervisor; the record is gone
    ok, data = Act('server:sup:ftoUnpair', 1, { rookie = CID[9] })
    H.eq(ok, false, 'fto: an officer cannot unpair (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:ftoUnpair', 3, { rookie = CID[9], reason = 'Moved shift' })
    H.eq(ok, true, 'fto: the supervisor ends the training: ' .. tostring(data))
    ok, data = Act('server:sup:ftoUnpair', 3, { rookie = CID[9] })
    H.eq(data, 'err.fto_not_paired', 'fto: twice is refused')
    -- the feature off: refused
    Setting('Recognition.fieldTraining.enabled', false)
    ok, data = Act('server:sup:ftoPair', 3, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, false, 'fto: the feature off: refused (' .. tostring(data) .. ')')
    Setting('Recognition.fieldTraining.enabled', true)
end

-- ============================================================================
--             8. EXTRA GRANTS FOR OFFICERS WHO ARE NOT SUPERVISORS
-- ============================================================================

do
    NextDay()
    local ok, data = Setting('Permissions.grants', {
        missionControls = { citizenids = { CID[7] } },
        fieldTraining = { citizenids = { CID[7] } },
        missionCalls = { departments = { sast = { minGrade = 1 } } },
    })
    H.eq(ok, true, 'grants: the admin grants Dan the Mission controls and field training: ' .. tostring(data))
    -- Mission controls: he opens them and changes one of his department; never another officer
    H.ok(Cb('sup:getMissionControls', 7) ~= nil, 'grants: Dan opens Mission controls')
    AfterWait()
    ok, data = SetControl(7, 'unitSize', 3)
    H.eq(ok, true, 'grants: Dan sets SAST\'s unit size: ' .. tostring(data))
    ResetControl(7, 'unitSize')
    ok, data = SetControl(6, 'unitSize', 3)
    H.eq(data, 'err.no_permission', 'grants: Cleo (not granted) cannot')
    -- the Supervisor UI itself stays for supervisors
    local s, why = Open(7, { ui = 'supervisor' })
    H.ok(s ~= nil or why == 'err.not_supervisor',
        'grants: the Supervisor UI as the grant allows (' .. tostring(why) .. ')')
    -- field training
    ok, data = Act('server:sup:ftoPair', 7, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, true, 'grants: Dan pairs Eve with Max: ' .. tostring(data))
    Act('server:sup:ftoUnpair', 7, { rookie = CID[9] })
    ok, data = Act('server:sup:ftoPair', 6, { rookie = CID[9], trainer = CID[8] })
    H.eq(ok, false, 'grants: Cleo cannot (' .. tostring(data) .. ')')
    -- mission calls by department grade: troopers may, a cadet may not
    ok, data = Act('server:sup:mcPost', 6, { type = 'patrol' })
    H.eq(ok, true, 'grants: a SAST trooper creates a call (grade 1 and up): ' .. tostring(data))
    if type(data) == 'table' and data.id then
        Act('server:sup:mcWithdraw', 6, { callId = data.id, reason = 'Test' })
    end
    ok, data = Act('server:sup:mcPost', 9, { type = 'patrol' })
    H.eq(ok, false, 'grants: the cadet cannot (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcPost', 2, { type = 'patrol' })
    H.eq(ok, false, 'grants: a FIB agent cannot (not his department) (' .. tostring(data) .. ')')
    -- a restart keeps them; a power switched off stays off for the granted too
    W.Restart()
    H.ok(Cb('sup:getMissionControls', 7) ~= nil, 'restart: the grant is kept')
    Setting('Permissions.supervisor.missionCalls', false)
    Secs(130)
    ok, data = Act('server:sup:mcPost', 6, { type = 'patrol' })
    H.eq(ok, false, 'grants: the power off: the granted trooper is refused too (' .. tostring(data) .. ')')
    Setting('Permissions.supervisor.missionCalls', true)
    -- the Mission controls master switch off: the granted officer too
    Setting('Permissions.supervisor.missionControls', false)
    AfterWait()
    ok, data = SetControl(7, 'unitSize', 3)
    H.eq(ok, false, 'grants: the master switch off: refused (' .. tostring(data) .. ')')
    Setting('Permissions.supervisor.missionControls', true)
    Setting('Permissions.grants', {})
    ok, data = SetControl(7, 'unitSize', 3)
    H.eq(data, 'err.no_permission', 'grants: taken back: refused')
end

-- ============================================================================
--                 9. TWO SUPERVISORS OF ONE DEPARTMENT AT ONCE
-- ============================================================================

do
    NextDay()
    -- the same request twice (a double click): one change
    local rid = W.RequestId()
    local ok1 = Act('server:sup:setMissionControl', 3,
        { key = 'startTimeout', value = 900, reason = 'Long drives', requestId = rid })
    local ok2, d2 = Act('server:sup:setMissionControl', 3,
        { key = 'startTimeout', value = 900, reason = 'Long drives', requestId = rid })
    H.eq(ok1, true, 'twice: the change is saved')
    H.eq(ok2, true, 'twice: the second send answers the first reply (' .. tostring(d2) .. ')')
    H.eq(
        Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'missionControlSet'
        AND target = 'sast:startTimeout' AND created_at >= FROM_UNIXTIME(?)]], { H.time - 600 }),
        1,
        'twice: audited once'
    )
    -- the second supervisor sees the first one's change and waits for the change wait; FIB never does
    local c = Control(Cb('sup:getMissionControls', 8), 'sast', 'startTimeout')
    H.eq(c and c.saved, 900, 'two: the second supervisor sees it')
    H.ok(c and (c.waitLeft or 0) > 0, 'two: ...with the wait left')
    ok1 = SetControl(8, 'startTimeout', 300)
    H.eq(ok1, false, 'two: he cannot change it during the wait')
    ok1 = SetControl(4, 'startTimeout', 300)
    H.eq(ok1, true, 'two: FIB has its own value')
    AfterWait()
    ok1 = ResetControl(8, 'startTimeout')
    H.eq(ok1, true, 'two: after the wait the second one resets it')
    ResetControl(4, 'startTimeout')
    -- two happy hours at once: one runs (happy hours are server-wide, one a day)
    local a = SetControl(3, 'happyHour', { minutes = 5 })
    local b = SetControl(8, 'happyHour', { minutes = 5 })
    H.eq(a, true, 'two: the first happy hour starts')
    H.eq(b, false, 'two: the second is refused while it runs')
    Secs(5 * 60 + 40)
    -- both give the same officer points: each counts his own day
    local x0 = W.Xp(CID[6])
    a = Act('server:sup:awardPoints', 3, { citizenid = CID[6], points = 20, reason = 'Pursuit' })
    b = Act('server:sup:awardPoints', 8, { citizenid = CID[6], points = 20, reason = 'Pursuit too' })
    H.eq(a and b, true, 'two: both give Cleo 20 points')
    H.eq(W.Xp(CID[6]) - x0, 40, 'two: she has 40')
    -- both commend her the same kind: the second waits the kind's days
    a = Act('server:sup:commend', 3, { citizenid = CID[6], kind = 'valor', citation = GOOD })
    local bb, berr = Act('server:sup:commend', 8, { citizenid = CID[6], kind = 'valor', citation = GOOD })
    H.eq(a, true, 'two: the first commendation is given')
    H.eq(bb, false, 'two: the same kind from the second is refused (' .. tostring(berr) .. ')')
end

-- ============================================================================
--                           10. THE MAINTENANCE LOCK
-- ============================================================================
-- SUPERVISOR ACTIONS WAIT, SCREENS READ.

do
    NextDay()
    CP.Maintenance.begin('restore', { by = 'WF5B' })
    local tries = {
        { 'server:sup:awardPoints', { citizenid = CID[1], points = 5, reason = 'Lock' } },
        { 'server:sup:missionBan', { citizenid = CID[1], hours = 1, reason = 'Lock' } },
        { 'server:sup:clearCooldowns', { citizenid = CID[1], scope = 'type', key = 'patrol', reason = 'Lock' } },
        { 'server:sup:setMissionControl', { key = 'unitSize', value = 3, reason = 'Lock', requestId = W.RequestId() } },
        { 'server:notice:post', { kind = 'department', text = 'During the lock', days = 1 } },
        { 'server:sup:ftoPair', { rookie = CID[9], trainer = CID[8] } },
        { 'server:sup:commend', { citizenid = CID[1], kind = 'leadership', citation = GOOD } },
        { 'server:sup:mcPost', { type = 'patrol' } },
        { 'server:review:decide', { type = 'flag', id = 1, decision = 'approve', reason = 'Lock' } },
    }
    for _, t in ipairs(tries) do
        local ok, err = Act(t[1], 3, t[2])
        H.eq(err, 'err.maintenance', ('maintenance: %s is refused while it holds'):format(t[1]))
    end
    H.ok(Cb('sup:getToday', 3) ~= nil, 'maintenance: Today still opens')
    H.ok(Cb('sup:getDeptReport', 3) ~= nil, 'maintenance: Officers still opens')
    H.ok(Cb('review:getQueue', 3) ~= nil, 'maintenance: the Review Queue still opens')
    CP.Maintenance.finish('restore')
    local ok, err = Act('server:sup:commend', 3, { citizenid = CID[1], kind = 'leadership', citation = GOOD })
    H.eq(ok, true, 'maintenance: over: a commendation again: ' .. tostring(err))
end

_G.print = W.realPrint

return H
