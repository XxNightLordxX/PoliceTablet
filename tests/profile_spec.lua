-- CP.Profile (modules/profile): bio, pictures, look, call mute, profile reports, moderation and commendations.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then return end
    realPrint(line)
end

-- Wednesday 2026-09-23 12:00.
local NOW = os.time({ year = 2026, month = 9, day = 23, hour = 12, min = 0, sec = 0 })
H.time = NOW
local DAY = 86400

-- ============================================================================
--                         DEPARTMENTS, OFFICERS, STUBS
-- ============================================================================

Config.Departments = {
    sast = {
        label = 'San Andreas State Troopers',
        short = 'SAST',
        jobs = { 'sast' },
        supervisorGrade = 3,
        theme = {
            primary = '#1f4e8c',
            accent = '#f2c230',
            background = '#0d1522',
            surface = '#152235',
            personalAccents = { '#f2c230', '#4cc9f0', { colour = '#80ed99', level = 10 } },
        },
    },
    fib = {
        label = 'Federal Investigation Bureau',
        short = 'FIB',
        jobs = { 'fib' },
        supervisorGrade = 3,
        theme = { primary = '#1c2541', accent = '#c9a227', background = '#0b0c10', surface = '#1a1b24' },
    },
}

local officers = {}
local function Officer(src, cid, name, dept, callsign, sup)
    officers[src] = {
        src = src,
        citizenid = cid,
        name = name,
        department = dept,
        departmentLabel = Config.Departments[dept].label,
        departmentShort = Config.Departments[dept].short,
        job = dept,
        rank = sup and 'Sergeant' or 'Trooper',
        gradeLevel = sup and 3 or 1,
        callsign = callsign,
        onduty = true,
        isSupervisor = sup == true,
        isAdmin = false,
    }
end
local bySrc = {}
CP.Access = {
    getOfficer = function(src)
        local o = officers[tonumber(src)]
        if not o then return nil, 'err.not_police' end
        return CP.U.copy(o)
    end,
    isAdmin = function(src) return tonumber(src) == 0 or IsPlayerAceAllowed(src, 'crimsonpolice.admin') == true end,
    isSupervisor = function(src)
        local o = officers[tonumber(src)]
        return o ~= nil and o.isSupervisor == true
    end,
    department = function(key)
        local d = Config.Departments[key]
        if not d then return nil end
        return { key = key, label = d.label, short = d.short, theme = { primary = d.theme.primary } }
    end,
    departments = function()
        return { CP.Access.department('fib'), CP.Access.department('sast') }
    end,
}
CP.Qbx = {
    getInfo = function(src)
        local o = officers[tonumber(src)]
        if o then return { citizenid = o.citizenid, name = o.name } end
        if tonumber(src) == 1 then return { citizenid = 'ADMIN1', name = 'Admin' } end
        return nil
    end,
    getByCitizenId = function(cid)
        for src, o in pairs(officers) do if o.citizenid == cid then return src end end
        return nil
    end,
    onDutyChange = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
local audits, notes, pushes, hooks = {}, {}, {}, {}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            category = category,
            action = action,
            target = target,
            old = old,
            new = new,
            reason = reason,
        }
    end,
    webhook = function(category, title) hooks[#hooks + 1] = { category = category, title = title }; return true end,
}
CP.Tablet = {
    notify = function(src, kind, key) notes[#notes + 1] = { src = src, kind = kind, key = key } end,
    push = function(src, topic) pushes[#pushes + 1] = { src = src, topic = topic } end,
}

H.load('modules/permissions/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/leaderboard/server.lua')
H.load('modules/profile/server.lua')
local P = CP.Profile

local function Tick() H.clockMs = H.clockMs + 1001 end
local function Cb(name, src, args)
    Tick()
    return H.callback('crimson-police:' .. name, src, args)
end
local function Act(name, src, payload)
    Tick()
    H.reset()
    H.fire('crimson-police:' .. name, src, payload, 'rq')
    local ev = H.findEvents('crimson-police:client:actionResult')[1]
    if not ev then return nil, 'no reply' end
    return ev.args[2], ev.args[3]
end
local function Row(cid)
    return H.sql(
        [[SELECT bio, bio_pending, avatar_kind, avatar_value, avatar_pending, avatar_status, appearance, accent,
        ui_scale, calls_muted FROM cp_officers WHERE citizenid = ?]], { cid })[1]
end
local function OfficerRow(cid, name, dept, xp, hide, callsign)
    H.sql(
        'INSERT INTO cp_officers (citizenid, display_name, callsign, department, xp, hide_name) VALUES (?, ?, ?, ?, ?, ?)',
        { cid, name, callsign or 'C-1', dept, xp or 0, hide and 1 or 0 })
end
local function LastAudit() return audits[#audits] end
local function Later(s) H.time = H.time + s end

for _, t in ipairs({ 'cp_officers', 'cp_profile_reports', 'cp_commendations', 'cp_mission_runs', 'cp_badges' }) do
    H.sql('DELETE FROM ' .. t)
end
P._resetCaches()
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
Officer(11, 'P1', 'Alice Young', 'sast', '2L-01')          -- the officer editing her profile (level 1)
Officer(12, 'P2', 'Ben Stone', 'sast', '2L-02')            -- a second SAST officer (level 12)
Officer(13, 'P3', 'Cara Holt', 'fib', 'F-03')              -- FIB officer
Officer(21, 'S1', 'Sam Reyes', 'sast', '2L-90', true)      -- SAST supervisor
Officer(22, 'S2', 'Fay Mori', 'fib', 'F-90', true)         -- FIB supervisor
OfficerRow('P2', 'Ben Stone', 'sast', 1700, false, '2L-02')
OfficerRow('P3', 'Cara Holt', 'fib', 0)
OfficerRow('S1', 'Sam Reyes', 'sast', 0)
OfficerRow('S2', 'Fay Mori', 'fib', 0)
H.advance(2000)

-- ============================================================================
--                                     BIO
-- ============================================================================

do
    Config.Profile.bannedWords = { 'turnip' }
    P._reloadBannedWords()
    H.eq(select(2, P.validateBio(('a'):rep(281))), 'err.bio_too_long', 'bio: at most 280 characters')
    H.eq(P.validateBio(('é'):rep(280)), ('é'):rep(280), 'bio: characters, not bytes')
    H.eq(select(2, P.validateBio('one\ntwo\nthree\nfour')), 'err.bio_lines', 'bio: at most 3 lines')
    H.eq(P.validateBio('  one\r\ntwo\1\2 \n three  '), 'one\ntwo\nthree', 'bio: trimmed, CRLF, control characters')
    H.eq(select(2, P.validateBio('I love TURNIP soup')), 'err.bio_banned', 'bio: config banned word, any case')
    H.eq(select(2, P.validateBio('what the Fuck')), 'err.bio_banned', 'bio: config/banned_words.txt, any case')
    H.eq(select(2, P.validateBio('KILL YOURSELF now')), 'err.bio_banned', 'bio: a banned phrase')
    H.eq(P.validateBio('a classic assessment'), 'a classic assessment', 'bio: whole words only')
    H.eq(P.validateBio('turnips'), 'turnips', 'bio: a longer word is not the banned word')
    H.eq(P.validateBio(''), nil, 'bio: empty clears it')

    -- single-line bios below: the harness's mysql client reads a newline inside a value as a new row
    local ok, res = Act('server:profile:set', 11, { bio = 'Night shift, Sandy Shores' })
    H.eq(ok, true, 'bio saved')
    H.eq(res.pending.bio, false, 'no approval needed by default')
    H.eq(Row('P1').bio, 'Night shift, Sandy Shores', 'bio stored (an officer without a row gets one)')
    local again, err = Act('server:profile:set', 11, { bio = 'Changed my mind' })
    H.eq(again, false, 'a second change within 5 minutes is refused')
    H.eq(err, 'err.profile_cooldown', 'profile cooldown')
    H.ok(Cb('getProfileEdit', 11).data.nextEditIn > 0, 'the dialog shows the cooldown')
    local look = Act('server:profile:set', 11, { appearance = 'midnight' })
    H.eq(look, true, 'the look is not under the edit cooldown')
    Later(301)
    local banned, bErr = Act('server:profile:set', 11, { bio = 'turnip time' })
    H.eq(banned, false, 'a banned bio is refused')
    H.eq(bErr, 'err.bio_banned', 'banned-word key')
    H.eq(Row('P1').bio, 'Night shift, Sandy Shores', 'a refused bio changes nothing')

    -- bioRequiresApproval: pending, others see the old bio until a supervisor approves
    Config.Profile.bioRequiresApproval = true
    local okP, resP = Act('server:profile:set', 11, { bio = 'Pending words' })
    H.eq(okP, true, 'a new bio is accepted')
    H.eq(resP.pending.bio, true, 'and waits for approval')
    local pub = Cb('getProfile', 12, { citizenid = 'P1' }).data
    H.eq(pub.bio, 'Night shift, Sandy Shores', 'others still see the old bio')
    H.eq(Cb('getProfileEdit', 11).data.bioPending, 'Pending words', 'the owner sees the pending bio')
    local q = Cb('sup:getProfileQueue', 21).data
    local item
    for _, i in ipairs(q) do if i.kind == 'bio' and i.citizenid == 'P1' then item = i end end
    H.ok(item ~= nil and item.text == 'Pending words', 'the pending bio is in the Review Queue')
    H.eq(#Cb('sup:getProfileQueue', 22).data, 0, 'another department\'s supervisor does not see it')
    local okA = Act('server:sup:reviewAvatar', 21,
        { citizenid = 'P1', decision = 'approve', what = 'bio', reason = 'ok' })
    H.eq(okA, true, 'the supervisor approves the bio')
    H.eq(Row('P1').bio, 'Pending words', 'the approved bio is shown')
    H.eq(LastAudit().action, 'reviewBio', 'bio review audited')
    Config.Profile.bioRequiresApproval = false
    Config.Profile.bannedWords = {}
    P._reloadBannedWords()
end

-- ============================================================================
--                                   PICTURES
-- ============================================================================

do
    Later(301)
    H.eq(select(2, Act('server:profile:set', 11, { avatar = { kind = 'preset', value = 'motor' } })),
        'err.avatar_locked', 'a preset above the officer\'s level is locked')
    H.eq(select(2, Act('server:profile:set', 11, { avatar = { kind = 'preset', value = 'nope' } })),
        'err.avatar_preset', 'an unknown preset is refused')
    H.eq(Act('server:profile:set', 11, { avatar = { kind = 'preset', value = 'shield' } }), true, 'an open preset')
    H.eq(Row('P1').avatar_value, 'shield', 'preset stored')
    Later(301)
    H.eq(select(2, Act('server:profile:set', 11, { avatar = { kind = 'url', value = 'https://i.imgur.com/a.png' } })),
        'err.avatar_urls_off', 'links are off by default')

    Config.Profile.avatarUrls.enabled = true
    local V = P.validateUrl
    H.eq(V('https://i.imgur.com/abc.png'), true, 'an allowed link')
    H.eq(V('https://r2.fivemanage.com/x/y.WEBP?width=64&t=1'), true, 'a query string is ignored for the extension')
    H.eq(select(2, V('http://i.imgur.com/abc.png')), 'err.avatar_url_https', 'https only')
    H.eq(select(2, V('https://evil.com/abc.png')), 'err.avatar_url_host', 'host not allowed')
    H.eq(select(2, V('https://i.imgur.com.evil.com/abc.png')), 'err.avatar_url_host', 'the host must match exactly')
    H.eq(select(2, V('https://cdn.discordapp.com/attachments/1/2/a.png')), 'err.avatar_url_host',
        'cdn.discordapp.com is not a default host')
    H.eq(select(2, V('https://i.imgur.com/abc.gif')), 'err.avatar_url_ext', 'extension checked')
    H.eq(select(2, V('https://i.imgur.com/abc?x=.png')), 'err.avatar_url_ext', 'the extension is read on the path')
    H.eq(select(2, V('https://i.imgur.com/a b.png')), 'err.avatar_url_invalid', 'no spaces')
    H.eq(select(2, V('https://i.imgur.com/a"<b>.png')), 'err.avatar_url_invalid', 'no quotes or angle brackets')
    H.eq(select(2, V('https://i.imgur.com/' .. ('a'):rep(240) .. '.png')), 'err.avatar_url_too_long', '255 characters')

    local ok, res = Act('server:profile:set', 11, { avatar = { kind = 'url', value = 'https://i.imgur.com/new.png' } })
    H.eq(ok, true, 'a link is accepted')
    H.eq(res.pending.avatar, true, 'and waits for approval')
    H.eq(Row('P1').avatar_value, 'shield', 'the old picture stays for everyone')
    H.eq(P.avatarFor('P1', 12).value, 'shield', 'another officer sees the old picture')
    H.eq(Cb('getProfileEdit', 11).data.pending.value, 'https://i.imgur.com/new.png', 'the owner sees the pending link')
    H.eq(Cb('getProfileEdit', 11).data.urlsLeftToday, 2, 'links left today')
    -- another department's supervisor may not review it; the officer's own department may
    H.eq(select(2, Act('server:sup:reviewAvatar', 22, { citizenid = 'P1', decision = 'approve', reason = 'x' })),
        'err.profile_other_dept', 'another department\'s supervisor is refused')
    H.eq(select(2, Act('server:sup:reviewAvatar', 21, { citizenid = 'P1', decision = 'approve' })),
        'err.reason_required', 'a reason is required')
    H.eq(select(2, Act('server:sup:reviewAvatar', 12, { citizenid = 'P1', decision = 'approve', reason = 'x' })),
        'err.no_permission', 'an officer cannot review')
    H.eq(Act('server:sup:reviewAvatar', 21, { citizenid = 'P1', decision = 'reject', reason = 'not you' }), true,
        'rejected by the supervisor')
    H.eq(Row('P1').avatar_value, 'shield', 'a rejected link keeps the old picture')
    H.eq(Row('P1').avatar_status, 'rejected', 'status rejected')
    H.eq(LastAudit().action, 'reviewAvatar', 'picture review audited')
    Later(301)
    Act('server:profile:set', 11, { avatar = { kind = 'url', value = 'https://i.imgur.com/two.png' } })
    H.eq(Act('server:admin:reviewAvatar', 1, { citizenid = 'P1', decision = 'approve', reason = 'fine' }), true,
        'an admin approves')
    H.eq(P.avatarFor('P1', 12).value, 'https://i.imgur.com/two.png', 'the approved link is what everyone sees')
    H.eq(P.avatarFor('P1', 12).kind, 'url', 'kind url')
    -- the daily limit on link submissions
    Later(301)
    Act('server:profile:set', 11, { avatar = { kind = 'url', value = 'https://i.imgur.com/three.png' } })
    Later(301)
    local lim, limErr = Act('server:profile:set', 11,
        { avatar = { kind = 'url', value = 'https://i.imgur.com/4.png' } })
    H.eq(lim, false, 'the fourth link of the day is refused')
    H.eq(limErr, 'err.avatar_url_limit', 'link limit key')
    -- requireApproval off: the link is shown at once
    Config.Profile.avatarUrls.requireApproval = false
    H.time = NOW + 2 * DAY
    local okNow = Act('server:profile:set', 12, { avatar = { kind = 'url', value = 'https://i.imgur.com/ben.png' } })
    H.eq(okNow, true, 'without approval the link is saved')
    H.eq(Row('P2').avatar_value, 'https://i.imgur.com/ben.png', 'and shown at once')
    Config.Profile.avatarUrls.requireApproval = true
    Config.Profile.avatarUrls.enabled = false
    -- a hidden name never shows the picture to others
    H.sql('UPDATE cp_officers SET hide_name = 1 WHERE citizenid = ?', { 'P2' })
    local hidden = P.avatarFor('P2', 11)
    H.eq(hidden.kind, 'initials', 'hidden name: no picture')
    H.eq(hidden.initials, '2L', 'hidden name: the callsign\'s initials')
    H.eq(P.avatarFor('P2', 12).kind, 'url', 'the officer still sees their own picture')
    H.sql('UPDATE cp_officers SET hide_name = 0 WHERE citizenid = ?', { 'P2' })
    -- the admin clears a picture
    H.eq(Act('server:admin:clearProfile', 1, { citizenid = 'P2', what = 'avatar', reason = 'offensive' }), true,
        'an admin clears a picture')
    H.eq(Row('P2').avatar_kind, 'initials', 'cleared to initials')
    H.eq(LastAudit().action, 'clearAvatar', 'clear audited')
end

-- ============================================================================
--                                LOOK AND MUTE
-- ============================================================================

do
    H.eq(select(2, Act('server:profile:set', 11, { accent = '#123456' })), 'err.accent_invalid',
        'an accent outside the department palette is refused')
    H.eq(select(2, Act('server:profile:set', 11, { accent = '#80ed99' })), 'err.accent_locked',
        'a level-locked accent is refused below its level')
    H.eq(Act('server:profile:set', 12, { accent = '#80ED99' }), true, 'level 12 unlocks it (any case)')
    H.eq(Row('P2').accent, '#80ed99', 'accent stored lower case')
    H.eq(select(2, Act('server:profile:set', 13, { accent = '#f2c230' })), 'err.accent_invalid',
        'FIB has no personal accents')
    H.eq(Act('server:profile:set', 11, { accent = false }), true, 'the accent can be cleared')
    H.eq(Row('P1').accent, nil, 'back to the department accent')
    H.eq(select(2, Act('server:profile:set', 11, { appearance = 'neon' })), 'err.appearance_invalid',
        'appearance only from Config.Profile.appearances')
    H.eq(Act('server:profile:set', 11, { uiScale = 3 }), true, 'tablet size is clamped, not refused')
    H.near(tonumber(Row('P1').ui_scale), 1.25, 1e-9, 'clamped to the maximum')
    Act('server:profile:set', 11, { uiScale = 0.1 })
    H.near(tonumber(Row('P1').ui_scale), 0.85, 1e-9, 'clamped to the minimum')
    -- English only: a profile has no language (no column, no pref, no picker); a language field is ignored
    H.eq(Act('server:profile:set', 11, { language = 'de' }), true, 'a language field saves nothing')
    H.eq(P.prefsFor('P1').language, nil, 'and no pref carries a language')
    H.eq(P.languageFor, nil, 'there is no per-player language')
    local mig = io.open(H.root .. 'sql/migrations/004_profile.sql', 'r')
    local sql = mig and mig:read('a') or ''
    if mig then mig:close() end
    H.ok(sql ~= '' and not sql:find('language', 1, true), 'cp_officers gets no language column')
    -- call mute survives a reconnect (it is stored on cp_officers)
    H.eq(Act('server:profile:set', 11, { callsMuted = true }), true, 'calls muted')
    P._resetCaches()
    H.eq(P.prefsFor('P1').callsMuted, true, 'the mute is read back from cp_officers after a reconnect')
    H.eq(CP.U.truthy(Row('P1').calls_muted), true, 'cp_officers.calls_muted = 1')
    H.eq(select(2, Act('server:profile:set', 11, { callsMuted = 'yes' })), 'err.invalid_payload', 'a boolean only')
    local prefs = Cb('getProfileEdit', 11).data.prefs
    H.eq(prefs.appearance, 'midnight', 'appearance read back')
end

-- ============================================================================
--                               PROFILE REPORTS
-- ============================================================================

do
    H.time = NOW + 3 * DAY
    audits = {}
    H.eq(select(2, Act('server:profile:report', 12, { citizenid = 'P2', reason = 'bio' })), 'err.report_self',
        'an officer cannot report themselves')
    H.eq(select(2, Act('server:profile:report', 12, { citizenid = 'P1', reason = 'rude' })), 'err.invalid_payload',
        'a reason from the list')
    H.eq(select(2, Act('server:profile:report', 12, { citizenid = 'P1', reason = 'bio', note = ('x'):rep(141) })),
        'err.report_too_long', 'the note is at most 140 characters')
    local ok = Act('server:profile:report', 12, { citizenid = 'P1', reason = 'bio', note = 'Rude bio' })
    H.eq(ok, true, 'a report is sent')
    H.eq(audits[#audits].action, 'profileReport', 'report audited')
    H.eq(select(2, Act('server:profile:report', 12, { citizenid = 'P1', reason = 'picture' })), 'err.report_duplicate',
        'one report per profile per day')
    Act('server:profile:report', 12, { citizenid = 'S1', reason = 'other' })
    Act('server:profile:report', 12, { citizenid = 'P3', reason = 'picture' })
    H.eq(select(2, Act('server:profile:report', 12, { citizenid = 'S2', reason = 'other' })), 'err.report_limit',
        'at most 3 reports a day')
    -- the queue of the reported officer's department, and every department for admins
    local sast = Cb('sup:getProfileQueue', 21).data
    local reports = {}
    for _, i in ipairs(sast) do if i.kind == 'report' then reports[#reports + 1] = i end end
    H.eq(#reports, 2, 'the SAST queue has the two SAST reports')
    local fibQ = Cb('sup:getProfileQueue', 22).data
    H.eq(#fibQ, 1, 'the FIB queue has the FIB report')
    local all = Cb('sup:getProfileQueue', 1).data
    local n = 0
    for _, i in ipairs(all) do if i.kind == 'report' then n = n + 1 end end
    H.eq(n, 3, 'admins see every department\'s reports')
    -- the reported officer is never told who reported them
    local text = json.encode(sast) .. json.encode(Cb('getProfile', 11, nil).data)
        .. json.encode(Cb('getProfileEdit', 11).data)
    H.ok(text:find('P2', 1, true) == nil and text:find('Ben Stone', 1, true) == nil,
        'no reporter in the queue or the reported officer\'s own payloads')
    local rep
    for _, i in ipairs(reports) do if i.citizenid == 'P1' then rep = i end end
    H.eq(rep.note, 'Rude bio', 'the note reaches the reviewer')
    H.eq(rep.text, 'Pending words', 'the reviewer sees the live bio')
    -- handle: another department refused, clear audited and clears the bio, dismiss audited
    H.eq(select(2, Act('server:sup:handleReport', 22, { id = rep.id, decision = 'clear', reason = 'x' })),
        'err.profile_other_dept', 'another department cannot handle it')
    H.eq(Act('server:sup:handleReport', 21, { id = rep.id, decision = 'clear', reason = 'inappropriate' }), true,
        'the supervisor clears it')
    H.eq(Row('P1').bio, nil, 'the reported bio is cleared')
    H.eq(audits[#audits].action, 'clearReport', 'clear audited')
    H.eq(select(2, Act('server:sup:handleReport', 21, { id = rep.id, decision = 'dismiss', reason = 'x' })),
        'err.report_handled', 'a handled report is final')
    local other = fibQ[1]
    H.eq(Act('server:admin:handleReport', 1, { id = other.id, decision = 'dismiss', reason = 'fine' }), true,
        'an admin dismisses a report')
    H.eq(audits[#audits].action, 'dismissReport', 'dismiss audited')
    H.eq(H.sql('SELECT status FROM cp_profile_reports WHERE id = ?', { other.id })[1].status, 'dismissed',
        'status dismissed')
end

-- ============================================================================
--                                COMMENDATIONS
-- ============================================================================

do
    local function Counts()
        local r = H.sql('SELECT COUNT(*) AS n, COALESCE(SUM(final_points), 0) AS pts FROM cp_mission_runs')[1]
        local xp = H.sql('SELECT COALESCE(SUM(xp), 0) AS xp FROM cp_officers')[1].xp
        local b = H.sql('SELECT COUNT(*) AS n FROM cp_badges')[1].n
        return ('%s/%s/%s/%s'):format(tostring(r.n), tostring(r.pts), tostring(xp), tostring(b))
    end
    -- a run P2 and S1 both took part in, and one only P2 took part in
    for _, r in ipairs({ { 'P2', 'run-both' }, { 'S1', 'run-both' }, { 'P2', 'run-p2' } }) do
        H.sql(
            [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
            points_base, final_points) VALUES (?, 'patrol', 'beat_patrol', ?, 'sast', 'completed', 'completed', 60, 60)]],
            { r[2], r[1] })
    end
    H.time = NOW + 5 * DAY
    audits = {}
    local before = Counts()
    local good = 'Pulled two people out of a burning car.'
    H.eq(select(2, Act('server:sup:commend', 12, { citizenid = 'P1', kind = 'valor', citation = good })),
        'err.no_permission', 'an officer cannot commend')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'S1', kind = 'valor', citation = good })),
        'err.commend_self', 'never themselves')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P3', kind = 'valor', citation = good })),
        'err.commend_other_dept', 'own department only')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'bravery', citation = good })),
        'err.commend_kind', 'a kind from the config')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'valor', citation = 'Nice' })),
        'err.citation_short', 'citation at least 10 characters')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'valor', citation = ('x'):rep(256) })),
        'err.citation_long', 'citation at most 255 characters')
    H.eq(select(
        2,
        Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'valor', citation = good, runUuid = 'run-both' })
    ), 'err.commend_own_run', 'never for a run the supervisor took part in')
    H.eq(select(
        2,
        Act('server:sup:commend', 21, { citizenid = 'P1', kind = 'valor', citation = good, runUuid = 'run-p2' })
    ), 'err.commend_run', 'the run must be the recipient\'s')
    local ok, res = Act('server:sup:commend', 21,
        { citizenid = 'P2', kind = 'valor', citation = good, runUuid = 'run-p2' })
    H.eq(ok, true, 'commended')
    H.eq(audits[#audits].action, 'commend', 'commendation audited')
    H.eq(audits[#audits].target, 'P2', 'audit target')
    H.eq(H.sql('SELECT issuer_role, department FROM cp_commendations WHERE id = ?', { res.id })[1].issuer_role,
        'supervisor', 'issuer role')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'valor', citation = good })),
        'err.commend_recent', 'same officer, same kind within 7 days')
    H.eq(Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'teamwork', citation = good }), true, 'another kind')
    H.eq(Act('server:sup:commend', 21, { citizenid = 'P1', kind = 'teamwork', citation = good }), true, 'a third one')
    H.eq(select(2, Act('server:sup:commend', 21, { citizenid = 'P1', kind = 'valor', citation = good })),
        'err.commend_limit', 'at most 3 a day')
    Config.Commendations.crossDepartment = true
    H.time = NOW + 6 * DAY
    H.eq(Act('server:sup:commend', 21, { citizenid = 'P3', kind = 'valor', citation = good }), true,
        'crossDepartment lets a supervisor commend another department')
    Config.Commendations.crossDepartment = false
    H.eq(Act('server:admin:commend', 1, { citizenid = 'P3', kind = 'leadership', citation = good }), true,
        'an admin commends anyone')
    H.eq(Counts(), before, 'zero points: no row, no points, no XP, no badge')
    -- the recipient: toast, profile card and Home news
    local found = false
    for _, n in ipairs(notes) do if n.src == 12 and n.key == 'profile.commend.received' then found = true end end
    H.ok(found, 'the recipient gets a toast')
    local list = Cb('getProfile', 11, { citizenid = 'P2' }).data.commendations
    H.eq(#list, 2, 'the public profile lists the commendations')
    H.eq(list[1].kind, 'teamwork', 'newest first')
    H.eq(list[1].by, 'Sam Reyes', 'with the issuer')
    local extras = {}
    CP.Hooks.fire('home:extras', 'P2', 12, extras)
    H.eq(extras.commendations, 2, 'Home: two commendations this week')
    H.eq(#extras.news, 2, 'Home: one announcement each')
    H.eq(P.newCommendations('P2'), 2, 'newCommendations')
    -- revoke: the issuer or an admin, with a reason
    local id = list[1].id
    H.eq(select(2, Act('server:sup:revokeCommendation', 22, { id = id, reason = 'x' })), 'err.not_issuer',
        'another supervisor cannot revoke')
    H.eq(select(2, Act('server:sup:revokeCommendation', 21, { id = id })), 'err.reason_required',
        'a reason is required')
    H.eq(Act('server:sup:revokeCommendation', 21, { id = id, reason = 'given in error' }), true, 'the issuer revokes')
    H.eq(audits[#audits].action, 'revokeCommendation', 'revoke audited')
    H.eq(select(2, Act('server:admin:revokeCommendation', 1, { id = id, reason = 'x' })), 'err.commend_revoked',
        'already revoked')
    H.eq(#Cb('getProfile', 11, { citizenid = 'P2' }).data.commendations, 1, 'a revoked one leaves the profile')
    local staff = Cb('admin:getOfficerProfile', 1, { citizenid = 'P2' }).data
    H.eq(#staff.commendations, 2, 'admins see revoked ones too')
    H.eq(staff.realName, 'Ben Stone', 'admins see the real name')
    H.eq(Cb('admin:getOfficerProfile', 12, { citizenid = 'P2' }).error, 'err.no_permission', 'admin only')
    -- the 7-day window reopens after a week
    H.time = NOW + 13 * DAY
    H.eq(Act('server:sup:commend', 21, { citizenid = 'P2', kind = 'valor', citation = good }), true,
        'after 7 days the same kind is allowed again')
    H.eq(Counts(), before, 'still zero points')
    CP.Hooks.fire('home:extras', 'P2', 12, {})   -- a stale cache refreshes in a thread
    H.advance(10)
    H.eq(P._news('P2').n, 1, 'the news cache follows the last 7 days (the 8-day-old one left, the revoked one too)')
    -- an issuer who hides their name is shown by callsign on the recipient's profile and Home news
    H.sql('UPDATE cp_officers SET hide_name = 1 WHERE citizenid = ?', { 'S1' })
    local hiddenBy = Cb('getProfile', 11, { citizenid = 'P2' }).data.commendations[1]
    H.eq(hiddenBy.by, 'C-1', 'a hidden issuer shows the callsign')
    H.eq(hiddenBy.byRank, nil, 'and no rank')
    H.eq(Cb('getProfile', 12, nil).data.commendations[1].by, 'C-1', 'on the recipient\'s own profile too')
    P._resetCaches()
    CP.Hooks.fire('home:extras', 'P2', 12, {})
    H.advance(10)
    H.eq(P._news('P2').list[1].by, 'C-1', 'the Home news names a hidden issuer by callsign')
    -- the viewer's own commendations are marked (Department Report offers Revoke on those)
    H.eq(P.commendations('P2', { viewer = 'S1' })[1].mine, true, 'the issuer sees their commendation as theirs')
    H.eq(P.commendations('P2', { viewer = 'S2' })[1].mine, false, 'another supervisor does not')
    H.eq(P.commendations('P2')[1].mine, nil, 'no viewer, no mark')
    local staffBy = Cb('admin:getOfficerProfile', 1, { citizenid = 'P2' }).data.commendations[1]
    H.eq(staffBy.by, 'Sam Reyes', 'admins still see the issuer\'s name')
    H.sql('UPDATE cp_officers SET hide_name = 0 WHERE citizenid = ?', { 'S1' })
end

return H
