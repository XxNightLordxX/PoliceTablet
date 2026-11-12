-- The one notice system (CP.Notices, modules/supervisor/notices.lua): staff notices and department notices are kinds

-- The one notice system (CP.Notices, modules/supervisor/notices.lua): staff notices and department notices are kinds
-- of one engine with one post, one end and one view with a history. Each old feature is driven through the new
-- engine: the department notices (the notices Mission control), the staff notices (an admin, any departments), the
-- shared Home Announcements card, and the new per-kind alert (a toast, with the notice tone), which ships off.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
H.load('modules/supervisor/deptcontrols.lua')
CP.Notices.register()
H.step(0)
local Act = W.act
local N, DC = CP.Notices, CP.DeptControls
local DAY = 86400

H.sql('DELETE FROM cp_audit')
H.sql('DELETE FROM cp_staff_notices')

-- a post (one per player per Config.Notices.postWait: the clock moves on first)
local function Post(src, kind, text, days, extra)
    H.clockMs = H.clockMs + 61000
    local p = { kind = kind, text = text, days = days or 1 }
    for k, v in pairs(extra or {}) do p[k] = v end
    return Act('server:notice:post', src, p)
end

local function Shown(dept, needle)
    CP.Leaderboard.invalidate()
    local ann = W.async(function() return CP.Leaderboard.announcements(dept) end)
    for _, a in ipairs(ann or {}) do
        if type(a) == 'table' and tostring(a.text):find(needle, 1, true) then return true end
    end
    return false
end

local function View(src, kind) return W.async(function() return N.view(src, kind) end) end

-- ============================================================================
--                          SHIPPED CONFIG, OLD ROUTES
-- ============================================================================

local NC, MC = Config.Notices, Config.MissionControls
H.ok(
    MC.controls.notices.on == false and NC.department.maxLength == 280 and NC.department.perDay == 5
        and NC.department.maxRunning == 5 and NC.department.maxDays == 30,
    'department kind: ships off, as before'
)
H.ok(
    NC.staff.on == true and NC.staff.maxLength == 280 and NC.staff.maxDays == 30 and NC.staff.maxRunning == 5
        and NC.postWait == 60,
    'staff kind: ships on with the old limits'
)
H.ok(NC.staff.alert == 'off' and NC.department.alert == 'off', 'no alert as shipped: the notices only show on Home')
H.eq(MC.noticeMaxLength, nil, 'the old MissionControls.noticeMaxLength is gone')
H.eq(MC.noticesPerDay, nil, 'the old MissionControls.noticesPerDay is gone')
for _, old in ipairs({
    'server:admin:postNotice',
    'server:admin:removeNotice',
    'server:sup:postNotice',
    'server:sup:endNotice',
}) do
    H.eq(CP.AdminKit._actions()[old], nil, old .. ' is gone (one post and one end)')
end
H.eq(CP.DeptNotices, nil, 'no CP.DeptNotices any more')
H.eq(CP.Tablet.notifyAdmins, nil, 'no separate toast-every-admin helper (one toast path: notifyMany to onlineAdmins)')
H.eq(DC.def('notices').kind, 'action', 'department notices are still the notices Mission control')
local ok, err = Post(2, 'department', 'Briefing at 8')
H.eq(ok, false, 'department kind off as shipped: refused (' .. tostring(err) .. ')')
H.eq(#H.sql('SELECT id FROM cp_staff_notices'), 0, 'nothing saved')
ok, err = Post(1, 'memo', 'Hello')
H.eq(err, 'err.notice_kind', 'an unknown kind is refused')

-- ============================================================================
--                      OLD FEATURE 1: DEPARTMENT NOTICES
-- ============================================================================

MC.controls.notices.on = true
Config.Permissions.supervisor.missionControls = true
ok, err = Post(3, 'department', 'Not a supervisor')
H.eq(ok, false, 'an officer cannot post: ' .. tostring(err))
ok, err = Post(2, 'staff', 'A supervisor tries a staff notice', 1, { reason = 'x' })
H.eq(err, 'err.no_permission', 'a supervisor never posts a staff notice')
local res
ok, res = Post(2, 'department', 'SAST briefing at 8 pm', 2)
H.ok(ok == true and res.department == 'sast' and res.kind == 'department', 'a SAST supervisor posts: ' .. tostring(res))
local row = H.sql('SELECT departments, by_actor FROM cp_staff_notices WHERE id = ?', { res.id })[1]
H.ok(
    row and tostring(row.departments):find('"sast"', 1, true) and not tostring(row.departments):find('fib', 1, true)
        and row.by_actor == 'sup:SUP00002',
    'saved for SAST only, by the supervisor'
)
H.ok(Shown('sast', 'SAST briefing'), 'SAST officers see it on Home')
H.ok(not Shown('fib', 'SAST briefing'), 'FIB officers do not')
local a = H.sql('SELECT * FROM cp_audit WHERE action = ?', { 'deptNoticePost' })
H.ok(a[1] and a[1].role == 'supervisor', 'audited as deptNoticePost, role supervisor')
local view = View(2, 'department')
H.ok(view and view.usedToday == 1 and view.perDay == 5 and #view.running == 1 and view.reason == false,
    'his card lists it with his use today')
H.eq(DC.def('notices').usedToday and DC.def('notices').usedToday(2), 1, 'Your controls today counts it')

local banned = CP.Profile.hasBannedWord
CP.Profile.hasBannedWord = function(text) return text:find('zorkle', 1, true) ~= nil end
ok, err = Post(2, 'department', 'you zorkle')
H.eq(err, 'err.notice_banned', 'a banned word is refused')
CP.Profile.hasBannedWord = banned
NC.department.maxLength = 20
ok, err = Post(2, 'department', 'This notice is far longer than twenty characters')
H.eq(err, 'err.notice_text', 'longer than Notices.department.maxLength is refused')
NC.department.maxLength = 280
ok, err = Post(2, 'department', 'Days', 31)
H.eq(err, 'err.notice_expiry', 'more than maxDays is refused')
for i = 2, 5 do
    ok = Post(2, 'department', 'Notice ' .. i)
    H.eq(ok, true, 'notice ' .. i)
end
ok, err = Post(2, 'department', 'Notice 6')
H.eq(err, 'err.notice_per_day', 'the sixth today is refused (perDay)')
NC.department.perDay = 10
ok, err = Post(2, 'department', 'Notice 6')
H.eq(err, 'err.dept_notice_too_many', 'at most maxRunning in the department')
NC.department.perDay = 5

-- ============================================================================
--                         OLD FEATURE 2: STAFF NOTICES
-- ============================================================================

ok, err = Post(1, 'staff', 'Server news', 1)
H.eq(err, 'err.reason_required', 'a staff notice needs a reason')
local staff
ok, staff = Post(1, 'staff', 'FIB briefing at 9', 1, { departments = { 'fib' }, reason = 'brief' })
H.ok(ok == true and staff.kind == 'staff', 'an admin posts a staff notice for FIB (not held back by SAST five)')
H.ok(Shown('fib', 'FIB briefing') and not Shown('sast', 'FIB briefing'), 'shown to FIB only')
ok, err = Post(1, 'staff', 'Bad dept', 1, { departments = { 'nope' }, reason = 'x' })
H.eq(err, 'err.unknown_department', 'an unknown department is refused')
ok = Post(1, 'staff', 'Everyone: radio check', 1, { reason = 'x' })
H.ok(ok == true and Shown('sast', 'radio check') and Shown('fib', 'radio check'), 'no departments = every one')
H.clockMs = H.clockMs + 61000
Act('server:notice:post', 5, { kind = 'staff', text = 'Quick one', days = 1, reason = 'x' })
ok, err = Act('server:notice:post', 5, { kind = 'staff', text = 'Too quick', days = 1, reason = 'x' })
H.eq(err, 'err.rate_limited', 'one post per postWait')
H.eq(W.auditCount('noticePost'), 3, 'audited as noticePost')
NC.staff.maxRunning = 3
ok, err = Post(5, 'staff', 'A fourth', 1, { reason = 'x' })
H.eq(err, 'err.notice_too_many', 'at most staff.maxRunning staff notices (department ones never count)')
NC.staff.maxRunning = 5
NC.staff.on = false
ok, err = Post(5, 'staff', 'Off', 1, { reason = 'x' })
H.eq(err, 'err.notice_kind_off', 'the staff switch off refuses a post')
view = View(1, 'staff')
H.ok(view and view.canPost == false and #view.running == 8, 'switched off: the admin still lists every running one')
NC.staff.on = true
ok, err = Post(3, 'staff', 'Officer', 1, { reason = 'x' })
H.eq(err, 'err.no_permission', 'an officer never posts a staff notice')

-- ============================================================================
--                           END, AND THE ONE HISTORY
-- ============================================================================

ok, err = Act('server:notice:end', 2, { id = staff.id })
H.eq(err, 'err.dept_notice_unknown', 'a supervisor never ends a staff notice')
ok, err = Act('server:notice:end', 2, { id = res.id })
H.eq(ok, true, 'the supervisor ends a notice of his department: ' .. tostring(err))
H.ok(not Shown('sast', 'SAST briefing'), 'gone from Home')
H.eq(W.auditCount('deptNoticeEnd'), 1, 'audited as deptNoticeEnd')
local dnote = H.sql('SELECT id FROM cp_staff_notices WHERE text = ?', { 'Notice 2' })[1]
ok, err = Act('server:notice:end', 1, { id = dnote.id })
H.eq(err, 'err.reason_required', 'an admin ends with a reason')
ok = Act('server:notice:end', 1, { id = dnote.id, reason = 'wrong place' })
H.eq(ok, true, 'an admin ends any running notice, a department one too')
ok = Act('server:notice:end', 1, { id = staff.id, reason = 'done' })
H.eq(ok, true, 'and a staff notice')
H.eq(W.auditCount('noticeRemove'), 2, 'both audited as noticeRemove')
ok, err = Act('server:notice:end', 1, { id = staff.id, reason = 'again' })
H.eq(err, 'err.notice_unknown', 'an ended notice is not running any more')
view = View(1, 'staff')
local kinds = {}
for _, n in ipairs(view.history) do kinds[n.kind] = (kinds[n.kind] or 0) + 1 end
H.ok(#view.history == 3 and kinds.staff == 1 and kinds.department == 2 and view.history[1].ended == 'removed',
    'one history of both kinds, ended early')
-- who ended each one and why, from its end row in the audit log
local byId = {}
for _, n in ipairs(view.history) do byId[n.id] = n end
local hs, hd, hr = byId[staff.id], byId[dnote.id], byId[res.id]
H.ok(hs and type(hs.endedBy) == 'string' and hs.endedBy ~= '' and hs.endReason == 'done',
    'history: the admin who ended the staff notice, with his reason')
H.eq(hd and hd.endReason, 'wrong place', 'history: the reason the admin gave for ending a department notice')
H.ok(hr and type(hr.endedBy) == 'string' and hr.endedBy ~= '' and hr.endReason == nil,
    'history: the supervisor who ended his notice, no reason asked')
view = View(2, 'department')
H.ok(#view.history == 2 and view.history[1].kind == 'department', 'his history: his department only')
H.time = H.time + 3 * DAY
view = View(2, 'department')
H.ok(#view.running == 0 and view.history[1].ended == 'expired', 'a notice that ran out moves to history')
NC.historyShown = 1
view = View(1, 'staff')
H.eq(#view.history, 1, 'historyShown caps the history')
NC.historyShown = 20

-- ============================================================================
--                 NEW: EACH KIND'S ALERT (TOAST, NOTICE TONE)
-- ============================================================================

local function Toasts()
    local out = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:notify')) do
        local n = e.args[1]
        if type(n) == 'table' and n.key == 'notices.alert' then out[tonumber(e.target)] = n end
    end
    return out
end
H.reset()
ok = Post(2, 'department', 'No alert as shipped')
H.ok(ok == true and next(Toasts()) == nil, 'alert off: nobody gets a toast')
NC.department.alert = 'toast'
H.reset()
ok = Post(2, 'department', 'SAST: toast')
local t = Toasts()
H.ok(ok == true and t[3] and t[6] and not t[4] and not t[2] and t[3].sound == nil,
    'toast: on-duty SAST officers, not FIB, not the poster, no tone')
H.eq(t[3] and t[3].title, 'notices.alert_title.department', 'titled with its kind')
NC.staff.alert = 'sound'
H.reset()
ok = Post(1, 'staff', 'Everyone: tone', 1, { reason = 'x' })
t = Toasts()
H.ok(ok == true and t[3] and t[4] and t[3].sound == true and not t[1], 'sound: every department, with the tone')
NC.staff.alert, NC.department.alert = 'off', 'off'

MC.controls.notices.on = false
Config.Permissions.supervisor.missionControls = false
H.sql('DELETE FROM cp_staff_notices')
_G.print = W.realPrint or print
return H
