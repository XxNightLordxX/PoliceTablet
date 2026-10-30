-- Mission ban (step P11): a supervisor bars one officer of his department (a lower grade, never himself) from taking

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
H.load('modules/missionban/server.lua')
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

local before = os.time()
local res
ok, res = Ban(2, 'OFF00007', 2)
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
ok = W.act('server:admin:liftMissionBan', 1, { citizenid = 'OFF00009', reason = 'Appeal' })
H.eq(ok, true, 'an admin lifts any ban')
H.eq(MB.get('OFF00009'), nil, 'lifted')
H.eq(#W.audits('missionBanLift'), 2, 'audited')
ok, err = W.act('server:admin:liftMissionBan', 7, { citizenid = 'OFF00009', reason = 'x' })
H.eq(err, 'err.no_permission', 'an officer has no admin lift')

-- ============================================================================
--                               PER DAY, OFFLINE
-- ============================================================================

ok = Ban(2, 'OFF00009', 1)
H.eq(ok, true, 'the third ban today')
ok, err = Ban(2, 'OFF00007', 1)
H.eq(err, 'err.mission_ban_used', 'the fourth is refused (missionBanPerDay)')
W.people[12].grade = 5
W.people[9].offline = true
W.act('server:sup:liftMissionBan', 2, { citizenid = 'OFF00009', reason = 'x' })
ok, err = Ban(12, 'OFF00009', 1)
H.eq(err, 'err.mission_ban_offline', 'an officer who is offline cannot be banned (his grade is unknown)')
W.people[9].offline = nil

MC.controls.missionBan.on = false
Config.Permissions.supervisor.missionControls = false
return H
