-- Mission ban: a supervisor bars one officer of his department (a lower grade, never himself) from taking

-- Mission ban: a supervisor bars one officer of his department (a lower grade, never himself) from taking
-- missions for some hours, with a reason; the one who set it lifts it, admins lift or extend it in the one
-- restrictions list (server:admin:restriction, kind 'missionBan'). Real missionban, restrictions, livectl,
-- deptcontrols, adminkit, admin, access and permissions (tests/fixtures/admin_live_world.lua). The accept, call
-- claim and Cross-Department join checks are in board_types_spec, missioncalls_spec and teams_spec.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
H.load('modules/supervisor/missionban.lua')
H.load('modules/supervisor/restrictions.lua')
H.step(0)
local MB, DC = CP.MissionBan, CP.DeptControls

-- a higher grade and an equal grade in SAST
W.people[11] = { cid = 'LT000011', license = 'license:h11', job = 'sast', grade = 5, name = 'Lee Lieutenant' }
W.people[12] = { cid = 'SUP00012', license = 'license:i12', job = 'sast', grade = 4, name = 'Pat Peer' }
for src, p in pairs({ [11] = W.people[11], [12] = W.people[12] }) do
    H.players[src] = { ace = {}, coords = vec3(100.0, 100.0, 30.0) }
    H.sql('INSERT INTO cp_officers (citizenid, department, license) VALUES (?, ?, ?)', { p.cid, p.job, p.license })
end

local function Ban(src, cid, hours, reason)
    return W.act('server:sup:missionBan', src,
        { citizenid = cid, hours = hours, reason = reason or 'Ignored an order' })
end

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

local MC = Config.MissionControls
H.ok(MC.controls.missionBan.on == false and MC.controls.missionBan.min == 1 and MC.controls.missionBan.max == 24,
    'ships off, 1-24 hours')
H.eq(MC.missionBanPerDay, 3, 'three bans a supervisor a day')
H.eq(DC.def('missionBan').kind, 'action', 'an action control')
H.eq(DC.def('missionBan').master, true, 'under the master switch')
H.eq(DC.checkConfig({ missionBan = MC.controls.missionBan }), nil, 'the shipped bounds pass the config check')
H.eq(DC.checkConfig({ missionBan = { on = true, min = 1, max = 200 } }), 'err.control_config', 'at most a week')
local ok, err = Ban(2, 'OFF00007', 1)
H.eq(ok, false, 'off as shipped: refused')
H.eq(MB.supView(2, 'OFF00007'), nil, 'and Department Report offers nothing')

-- ============================================================================
--                                  THE RULES
-- ============================================================================

MC.controls.missionBan.on = true
Config.Permissions.supervisor.missionControls = true
local view = MB.supView(2, 'OFF00007')
H.ok(view and view.min == 1 and view.max == 24 and view.perDay == 3 and view.usedToday == 0 and view.ban == nil,
    'switched on: Department Report offers it')
H.eq(MB.supView(2, 'SUP00002'), nil, 'never on his own character')
H.eq(MB.supView(7, 'OFF00009'), nil, 'never to an officer')

ok, err = Ban(2, 'SUP00002', 1)
H.eq(err, 'err.self_target', 'never himself')
ok, err = Ban(2, 'OFF00008', 1)
H.eq(err, 'err.other_department', 'never an FIB officer')
ok, err = Ban(2, 'LT000011', 1)
H.eq(err, 'err.mission_ban_grade', 'never a higher grade')
ok, err = Ban(2, 'SUP00012', 1)
H.eq(err, 'err.mission_ban_grade', 'nor an equal grade')
ok, err = Ban(2, 'OFF00007', 25)
H.eq(err, 'err.mission_ban_hours', 'never above max hours')
ok, err = Ban(2, 'OFF00007', 0)
H.eq(err, 'err.mission_ban_hours', 'never below min hours')
ok, err = W.act('server:sup:missionBan', 2, { citizenid = 'OFF00007', hours = 1 })
H.eq(err, 'err.reason_required', 'a reason is required')
H.eq(#W.audits('missionBan'), 0, 'nothing refused is audited')

-- ============================================================================
--                             BAN, EXPIRY, STORAGE
-- ============================================================================

-- step FX1: from the department report's activity dialog (activityOf) the reply carries his fresh activity
local asked = {}
CP.Challenge = {
    withActivity = function(src, payload, okA, data)
        asked[#asked + 1] = { src = src, of = payload.activityOf }
        if okA and payload.activityOf then data.activity = { officer = { citizenid = payload.activityOf } } end
        return okA, data
    end,
}
local before = os.time()
local res
ok, res = W.act('server:sup:missionBan', 2,
    { citizenid = 'OFF00007', hours = 2, reason = 'Ignored an order', activityOf = 'OFF00007' })
H.ok(ok and res.activity and res.activity.officer.citizenid == 'OFF00007', 'FX1: the ban reply carries his activity')
H.ok(asked[1] and asked[1].src == 2 and asked[1].of == 'OFF00007', 'FX1: ...asked for the supervisor')
CP.Challenge = nil
H.ok(ok and res['until'] >= before + 7200, 'a SAST officer banned for 2 hours')
local ban = MB.get('OFF00007')
H.ok(
    ban and ban.by == 'SUP00002' and ban.name == 'Rank Sam Super' and ban.dept == 'sast'
        and ban.reason == 'Ignored an order',
    'who, which department and why'
)
local row = W.audits('missionBan')[1]
H.ok(
    row and row.category == 'flags' and row.target == 'OFF00007' and row.reason == 'Ignored an order'
        and tonumber(row.new_value) == ban['until'],
    'audited under flags (the flags webhook)'
)
H.eq(H.sql('SELECT role FROM cp_audit WHERE action = ?', { 'missionBan' })[1].role, 'supervisor', 'as supervisor')
H.eq(W.toasts(7, 'sup.notice.mission_banned'), 1, 'the officer is told')
local saved = H.sql('SELECT mission_ban FROM cp_officers WHERE citizenid = ?', { 'OFF00007' })[1].mission_ban
H.ok(type(saved) == 'string' and saved:find('SUP00002', 1, true) ~= nil, 'saved in cp_officers.mission_ban')
MB.clearCache()
H.eq(MB.get('OFF00007') and MB.get('OFF00007')['until'], ban['until'], 'read back from the store (a restart)')
H.eq(MB.get('OFF00007', ban['until']), nil, 'it ends at until')
H.ok(MB.first({ { citizenid = 'OFF00009' }, { citizenid = 'OFF00007' } }).citizenid == 'OFF00007',
    'first finds the banned member of a unit')
H.ok(CP.LiveCtl.officerRunState('OFF00007').missionBan.by == 'Rank Sam Super', 'Admin UI Today & cooldowns shows it')
view = MB.supView(2, 'OFF00007')
H.ok(view.ban and view.canLift == true and view.usedToday == 1, 'the setter may lift it')
H.eq(CP.DeptControls.def('missionBan').usedToday(2), 1, 'the Your controls today card counts it too (H4)')

-- ============================================================================
--                                     LIFT
-- ============================================================================

local lift = { citizenid = 'OFF00007', reason = 'Talked it through' }
ok, err = W.act('server:sup:liftMissionBan', 12, lift)
H.eq(err, 'err.mission_ban_not_yours', 'another supervisor cannot lift it')
H.eq(MB.supView(12, 'OFF00007').canLift, false, 'and is not offered Lift')
ok = W.act('server:sup:liftMissionBan', 2, lift)
H.eq(ok, true, 'the setter lifts it')
H.eq(MB.get('OFF00007'), nil, 'gone at once')
H.eq(H.sql('SELECT mission_ban FROM cp_officers WHERE citizenid = ?', { 'OFF00007' })[1].mission_ban, nil,
    'and in the store')
H.eq(W.audits('missionBanLift')[1].category, 'flags', 'the lift is audited too')
ok, err = W.act('server:sup:liftMissionBan', 2, lift)
H.eq(err, 'err.mission_ban_none', 'nothing left to lift')

ok = Ban(2, 'OFF00009', 1)
H.eq(ok, true, 'a second ban')
-- the restrictions list: the ban is a row with who set it and why; an admin extends it, then lifts it
local list = W.cb('admin:getRestrictions', 1, {})
list = list and list.data
local row
for _, r in ipairs(list and list.rows or {}) do
    if r.kind == 'missionBan' and r.citizenid == 'OFF00009' then row = r end
end
H.ok(row and row.by == 'SUP00002' and row.reason == 'Ignored an order',
    'the restrictions list shows the ban, its setter and reason')
local untilBefore = MB.get('OFF00009')['until']
ok, err = W.act('server:admin:restriction', 1,
    { op = 'extend', kind = 'missionBan', citizenid = 'OFF00009', hours = 2, reason = 'Again' })
H.eq(ok, true, 'an admin extends it: ' .. tostring(err))
H.eq(MB.get('OFF00009')['until'], untilBefore + 7200, 'by two hours')
H.clockMs = H.clockMs + 4000
ok, err = W.act('server:admin:restriction', 1,
    { op = 'extend', kind = 'missionBan', citizenid = 'OFF00009', hours = 169, reason = 'x' })
H.eq(err, 'err.restriction_hours', 'never past a week')
H.clockMs = H.clockMs + 4000
ok = W.act('server:admin:restriction', 1,
    { op = 'lift', kind = 'missionBan', citizenid = 'OFF00009', reason = 'Appeal' })
H.eq(ok, true, 'an admin lifts any ban')
H.eq(MB.get('OFF00009'), nil, 'lifted')
H.eq(#W.audits('missionBanLift'), 2, 'audited')
ok, err = W.act('server:admin:restriction', 7,
    { op = 'lift', kind = 'missionBan', citizenid = 'OFF00009', reason = 'x' })
H.eq(err, 'err.no_permission', 'an officer has no admin lift')

-- ============================================================================
--                               PER DAY, OFFLINE
-- ============================================================================

-- step Z5: a second ban sent while the first still reads today's count waits (err.busy), so two at once never pass
-- the cap
local realCount, inner = CP.AdminKit.dailyCount, nil
CP.AdminKit.dailyCount = function(...)
    CP.AdminKit.dailyCount = realCount
    H.clockMs = H.clockMs + 1000
    inner = table.pack(Ban(2, 'OFF00007', 1))
    return realCount(...)
end
H.clockMs = H.clockMs + 1000
ok = Ban(2, 'OFF00009', 1)
CP.AdminKit.dailyCount = realCount
H.eq(ok, true, 'the third ban today')
H.eq(inner and inner[2], 'err.busy', 'Z5: a ban sent at the same time waits (err.busy)')
ok, err = Ban(2, 'OFF00007', 1)
H.eq(err, 'err.mission_ban_used', 'the fourth is refused (missionBanPerDay)')
W.people[12].grade = 5
W.people[9].offline = true
W.act('server:sup:liftMissionBan', 2, { citizenid = 'OFF00009', reason = 'x' })
ok, err = Ban(12, 'OFF00009', 1)
H.eq(err, 'err.mission_ban_offline', 'an officer who is offline cannot be banned (his grade is unknown)')
W.people[9].offline = nil

-- a ban in force belongs to its setter: another supervisor cannot replace it with a shorter one he could then lift
ok = Ban(12, 'OFF00009', 24)
H.eq(ok, true, 'a 24 h ban by Pat')
ok, err = Ban(11, 'OFF00009', 1)
H.eq(err, 'err.mission_ban_exists', 'another supervisor cannot replace it')
H.eq(MB.get('OFF00009').by, 'SUP00012', 'the 24 h ban stays his')
ok, err = W.act('server:sup:liftMissionBan', 11, { citizenid = 'OFF00009', reason = 'x' })
H.eq(err, 'err.mission_ban_not_yours', 'nor lift it')
ok = Ban(12, 'OFF00009', 2)
H.eq(ok, true, 'the setter may change his own ban')
H.clockMs = H.clockMs + 4000
ok = W.act('server:admin:restriction', 1, { op = 'lift', kind = 'missionBan', citizenid = 'OFF00009', reason = 'x' })
H.eq(ok, true, 'an admin lifts it')

MC.controls.missionBan.on = false
Config.Permissions.supervisor.missionControls = false

-- Z7: an admin on duty in another department works with the target's department switch and hours, not his own
do
    Config.Permissions.supervisor.missionControls = true
    local savedS, savedF = Config.Departments.sast.missionControls, Config.Departments.fib.missionControls
    Config.Departments.sast.missionControls = { missionBan = { on = true, min = 1, max = 24 } }
    Config.Departments.fib.missionControls = { missionBan = { on = false, min = 1, max = 4 } }
    local v = MB.supView(3, 'OFF00007')
    H.ok(v ~= nil and v.max == 24, 'Z7: the FIB admin is offered the SAST officer\'s ban with SAST hours')
    H.clockMs = H.clockMs + 4000
    local okA, errA = Ban(3, 'OFF00007', 10)
    H.ok(okA == true, 'Z7: and bans him for 10 hours (above FIB\'s max): ' .. tostring(errA))
    H.clockMs = H.clockMs + 4000
    W.act('server:admin:restriction', 1, { op = 'lift', kind = 'missionBan', citizenid = 'OFF00007', reason = 'x' })
    Config.Departments.sast.missionControls, Config.Departments.fib.missionControls = savedS, savedF
    Config.Permissions.supervisor.missionControls = false
end

-- step Z5: Clear cooldown and Add run time (Config.MissionControls per-day caps) take the same one-at-a-time lock
do
    local f = io.open('Crimson-Police/modules/supervisor/livectl.lua', 'r')
    local src = f and f:read('a') or ''
    if f then f:close() end
    local _, n = src:gsub('oneAtATime = true', '')
    H.eq(n, 2, 'Z5: clearCooldowns and addRunTime run one at a time per supervisor')
end
-- FM5: a tablet suspension is a row of the same restrictions list (who set it and why from the audit), extended and
-- lifted there with the suspend permission, audited like the suspend command
do
    H.clockMs = H.clockMs + 4000
    local okS, errS = W.act('server:admin:suspend', 1, { citizenid = 'OFF00008', days = 2, reason = 'No-shows' })
    H.ok(okS == true, 'an admin suspends an officer: ' .. tostring(errS))
    local res = W.cb('admin:getRestrictions', 1, {})
    local srow
    for _, r in ipairs(res and res.data and res.data.rows or {}) do
        if r.kind == 'suspension' and r.citizenid == 'OFF00008' then srow = r end
    end
    H.ok(srow and srow.reason == 'No-shows' and srow.by ~= nil, 'the suspension is listed with its reason and setter')
    local before = srow and srow.untilAt or 0
    H.clockMs = H.clockMs + 4000
    okS, errS = W.act('server:admin:restriction', 1,
        { op = 'extend', kind = 'suspension', citizenid = 'OFF00008', hours = 24, reason = 'Again' })
    H.ok(okS == true, 'extended by a day: ' .. tostring(errS))
    local untilTs = tonumber(
        H.sql('SELECT UNIX_TIMESTAMP(suspended_until) AS t FROM cp_officers WHERE citizenid = ?', { 'OFF00008' })[1].t)
    H.eq(untilTs, before + 86400, 'the suspension now ends a day later')
    H.clockMs = H.clockMs + 4000
    okS = W.act('server:admin:restriction', 1,
        { op = 'lift', kind = 'suspension', citizenid = 'OFF00008', reason = 'Appeal' })
    H.eq(okS, true, 'and lifted early')
    H.eq(W.audits('unsuspend')[1] ~= nil, true, 'audited as unsuspend')
    H.clockMs = H.clockMs + 4000
    local _, errO = W.act('server:admin:restriction', 1,
        { op = 'grow', kind = 'suspension', citizenid = 'OFF00008', reason = 'x' })
    H.eq(errO, 'err.restriction_op', 'only extend or lift')
    local _, errK = W.act('server:admin:restriction', 1,
        { op = 'lift', kind = 'nope', citizenid = 'OFF00008', reason = 'x' })
    H.eq(errK, 'err.restriction_kind', 'an unknown kind is refused')
    Config.AdminUi.restrictionsExtend = false
    H.clockMs = H.clockMs + 4000
    local _, errE = W.act('server:admin:restriction', 1,
        { op = 'extend', kind = 'missionBan', citizenid = 'OFF00008', hours = 1, reason = 'x' })
    H.eq(errE, 'err.restriction_extend_off', 'restrictionsExtend = false: no Extend')
    local off = W.cb('admin:getRestrictions', 1, {})
    H.eq(off and off.data and off.data.kinds[1].canExtend, false, 'and the list offers none')
    Config.AdminUi.restrictionsExtend = true
    H.eq(Config.AdminUi.restrictionsExtend, true, 'restrictionsExtend ships true')
end
return H
