-- Department notices (step P13, the notices Mission control): a supervisor posts a short notice for his own
-- department only (cp_staff_notices, shared with the admin's staff notices); it shows on that department's Home
-- Announcements card, never another's. Length, banned words, per day and the running limit per department.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
H.load('modules/deptcontrols/server.lua')
H.load('modules/deptnotices/server.lua')
H.step(0)
local Act = W.act
local DN, DC = CP.DeptNotices, CP.DeptControls
local DAY = 86400

H.sql('DELETE FROM cp_audit')
H.sql('DELETE FROM cp_staff_notices')

-- a post (one per supervisor per minute: the clock moves on first)
local function Post(src, text, days)
    H.clockMs = H.clockMs + 61000
    return Act('server:sup:postNotice', src, { text = text, days = days or 1 })
end

local function Shown(dept, needle)
    CP.Leaderboard.invalidate()
    local ann = W.async(function() return CP.Leaderboard.announcements(dept) end)
    for _, a in ipairs(ann or {}) do
        if type(a) == 'table' and tostring(a.text):find(needle, 1, true) then return true end
    end
    return false
end

-- ============================================================================
--                                SHIPPED CONFIG
-- ============================================================================

local MC = Config.MissionControls
H.ok(MC.controls.notices.on == false and MC.noticeMaxLength == 280 and MC.noticesPerDay == 5,
    'ships off, 280 characters, 5 a supervisor a day')
H.eq(DC.def('notices').kind, 'action', 'an action control')
H.eq(DC.checkConfig({ notices = MC.controls.notices }), nil, 'the shipped bounds pass the config check')
local ok, err = Post(2, 'Briefing at 8')
H.eq(ok, false, 'off as shipped: refused (' .. tostring(err) .. ')')
H.eq(#H.sql('SELECT id FROM cp_staff_notices'), 0, 'nothing saved')

-- ============================================================================
--                             ONE DEPARTMENT ONLY
-- ============================================================================

MC.controls.notices.on = true
Config.Permissions.supervisor.missionControls = true
ok, err = Act('server:sup:postNotice', 3, { text = 'Not a supervisor', days = 1 })
H.eq(ok, false, 'an officer cannot post: ' .. tostring(err))
local res
ok, res = Post(2, 'SAST briefing at 8 pm', 2)
H.ok(ok == true and res.department == 'sast', 'a SAST supervisor posts a SAST notice: ' .. tostring(res))
local row = H.sql('SELECT departments, by_actor FROM cp_staff_notices WHERE id = ?', { res.id })[1]
H.ok(
    row and tostring(row.departments):find('"sast"', 1, true) and not tostring(row.departments):find('fib', 1, true)
        and row.by_actor == 'sup:SUP00002',
    'saved for SAST only, by the supervisor'
)
H.ok(Shown('sast', 'SAST briefing'), 'SAST officers see it on Home')
H.ok(not Shown('fib', 'SAST briefing'), 'FIB officers do not')
local a = W.audits and W.audits('deptNoticePost')
    or H.sql('SELECT * FROM cp_audit WHERE action = ?', { 'deptNoticePost' })
H.ok(a[1] and a[1].role == 'supervisor', 'audited as supervisor')
local view = DN.view(2)
H.ok(view and view.usedToday == 1 and view.perDay == 5 and #view.notices == 1, 'the card lists it')

-- ============================================================================
--                               TEXT AND LIMITS
-- ============================================================================

local banned = CP.Profile.hasBannedWord
CP.Profile.hasBannedWord = function(text) return text:find('zorkle', 1, true) ~= nil end
ok, err = Post(2, 'you zorkle')
H.eq(err, 'err.notice_banned', 'a banned word is refused')
CP.Profile.hasBannedWord = banned
MC.noticeMaxLength = 20
ok, err = Post(2, 'This notice is far longer than twenty characters')
H.eq(err, 'err.notice_text', 'longer than noticeMaxLength is refused')
MC.noticeMaxLength = 280
ok, err = Post(2, 'Days', 31)
H.eq(err, 'err.notice_expiry', 'more than 30 days is refused')
for i = 2, 5 do
    ok = Post(2, 'Notice ' .. i)
    H.eq(ok, true, 'notice ' .. i)
end
ok, err = Post(2, 'Notice 6')
H.eq(err, 'err.notice_per_day', 'the sixth today is refused (noticesPerDay)')
MC.noticesPerDay = 10
ok, err = Post(2, 'Notice 6')
H.eq(err, 'err.dept_notice_too_many', 'at most 5 running in the department')
MC.noticesPerDay = 5

-- an admin's staff notice is not held back by the department's five
H.clockMs = H.clockMs + 61000
ok, err = Act('server:admin:postNotice', 1, { text = 'Server news', expiresAt = H.time + DAY, reason = 'news' })
H.ok(ok == true, 'an admin still posts a staff notice: ' .. tostring(err))

-- ============================================================================
--                                     END
-- ============================================================================

ok, err = Act('server:sup:endNotice', 2, { id = res.id })
H.eq(ok, true, 'the supervisor ends a notice of his department: ' .. tostring(err))
H.ok(not Shown('sast', 'SAST briefing'), 'gone from Home')
local staff = H.sql('SELECT id FROM cp_staff_notices WHERE text = ?', { 'Server news' })[1]
ok, err = Act('server:sup:endNotice', 2, { id = staff.id })
H.eq(err, 'err.dept_notice_unknown', 'never an admin staff notice')

MC.controls.notices.on = false
Config.Permissions.supervisor.missionControls = false
H.sql('DELETE FROM cp_staff_notices')
_G.print = W.realPrint or print
return H
