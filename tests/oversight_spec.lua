-- tests/oversight_spec.lua · the oversight slice: modules/admin (audit, webhooks, /CrimsonPoliceAdmin,
-- review and void, force recall, supervisor/admin callbacks), modules/disputes and modules/anticheat.
-- The real CP.Access and CP.Permissions modules run on a CP.Qbx stub; every other module is a stub that
-- records its calls. Every SQL statement of the three modules runs here against MariaDB cp_test.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

-- ── console capture ─────────────────────────────────────────────────────────
local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if not line:find('crimson%-police') and not line:find('Crimson%-Police') then realPrint(line) end
end
local function printed(needle)
    for i = #lines, 1, -1 do
        if lines[i]:find(needle, 1, true) then return true end
    end
    return false
end

-- ── MariaDB client charset: oxmysql talks utf8mb4; the harness' mysql CLI would default to latin1 and
-- mangle every non-ASCII string (the UTF-8 clipping tests below need the real encoding) ────────────
do
    local realPopen = io.popen
    io.popen = function(cmd, mode)
        if type(cmd) == 'string' and cmd:match('^mysql %-uroot ') and not cmd:find('default%-character%-set', 1) then
            cmd = cmd:gsub('^mysql %-uroot ', 'mysql --default-character-set=utf8mb4 -uroot ', 1)
        end
        return realPopen(cmd, mode)
    end
end

-- ── natives the harness does not have ──────────────────────────────────────
local convars = {}
_G.GetConvar = function(name, default) local v = convars[name]; if v == nil then return default end return v end
local http = { calls = {}, statuses = {} }
_G.PerformHttpRequest = function(url, cb, method, body, headers)
    http.calls[#http.calls + 1] = { url = url, method = method, body = body, headers = headers }
    local st = table.remove(http.statuses, 1) or { 204, '' }
    cb(st[1], st[2], {})
end
local buckets = {}
_G.GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end

-- ── locale: load every part so CP.L resolves this slice's keys ─────────────
do
    local cjson = require('cjson')
    local f = assert(io.open(H.root .. 'locales/parts/oversight.json', 'r'))
    local part = cjson.decode(f:read('a'))
    f:close()
    local all = CP.Locale.all()
    for k, v in pairs(part) do all[k] = v end
end

-- ── helpers ─────────────────────────────────────────────────────────────────
local function co(fn, ...)
    local out
    local c = coroutine.create(function(...) out = table.pack(fn(...)) end)
    local ok, err = coroutine.resume(c, ...)
    if not ok then error(err, 2) end
    return table.unpack(out or {}, 1, out and out.n or 0)
end

local reqSeq = 0
local function act(name, src, payload)
    H.clockMs = H.clockMs + 1100   -- stay under every per-second rate limit
    reqSeq = reqSeq + 1
    local reqId = 'q' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    local res = H.callback('crimson-police:' .. name, src, args)
    return res
end

-- ── CP.Qbx stub (players) ───────────────────────────────────────────────────
local infos = {}
local function addPlayer(src, cid, name, job, grade, onduty, ace)
    infos[src] = { src = src, citizenid = cid, name = name, job = { name = job, label = job, onduty = onduty, gradeLevel = grade, gradeName = 'Grade ' .. grade }, callsign = ('C-%d'):format(src) }
    H.players[src] = { coords = vec3(0.0, 0.0, 0.0), ace = ace and { ['crimsonpolice.admin'] = true } or {} }
end
addPlayer(1, 'ADM00001', 'Ada Min', 'unemployed', 0, false, true)
addPlayer(2, 'SUP00002', 'Sam Super', 'sast', 3, true, false)
addPlayer(3, 'OFF00003', 'Olly Officer', 'sast', 1, true, false)
addPlayer(4, 'FIB00004', 'Fay Fed', 'fib', 3, true, false)
addPlayer(5, 'OUT00005', 'Otto Outsider', 'unemployed', 0, false, false)
addPlayer(6, 'OFF00006', 'Pat Partner', 'sast', 1, true, false)
addPlayer(7, 'SUP00007', 'Sue Second', 'sast', 4, true, false)

CP.Qbx = {
    getInfo = function(src) return infos[tonumber(src)] end,
    getByCitizenId = function(cid) for s, i in pairs(infos) do if i.citizenid == cid then return s end end return nil end,
    getOnlinePlayers = function() local out = {} for s in pairs(infos) do out[#out + 1] = s end table.sort(out) return out end,
    onDutyChange = function() end, onGroupUpdate = function() end, onJobChange = function() end,
    onPlayerLoaded = function() end, onPlayerUnload = function() end,
}

-- ── stubs of the modules this slice calls ───────────────────────────────────
local calls = {}
local function record(name, ...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
local function lastCall(name)
    for i = #calls, 1, -1 do if calls[i].name == name then return calls[i].args end end
    return nil
end
local function countCalls(name)
    local n = 0
    for _, c in ipairs(calls) do if c.name == name then n = n + 1 end end
    return n
end

local notifies = {}
CP.Tablet = {
    notify = function(src, kind, key, vars) notifies[#notifies + 1] = { src = src, kind = kind, key = key, vars = vars }; return true end,
    notifyMany = function(srcs, kind, key, vars) for _, s in ipairs(srcs) do CP.Tablet.notify(s, kind, key, vars) end return #srcs end,
    openAdmin = function(src) record('openAdmin', src); return true end,
}
local function lastNotify(src)
    for i = #notifies, 1, -1 do if notifies[i].src == src then return notifies[i] end end
    return nil
end

CP.Scoring = {
    onRowApproved = function(id) record('onRowApproved', id) end,
    onRowVoided = function(id) record('onRowVoided', id) end,
    manualAward = function(src, cid, points, reason) record('manualAward', src, cid, points, reason); return true end,
    xpLevel = function(xp) return { label = 'Patrol Officer', badge = 'bronze', xp = xp, next = 5000 } end,
    badges = function() return { { id = 'ironWheels', label = 'Iron Wheels', earnedAt = '2026-09-01' } } end,
}
CP.Cash = {
    release = function(id) record('cashRelease', id) end,
    forfeit = function(id) record('cashForfeit', id) end,
    earnedThisWeek = function() return 1234 end,
}
CP.Leaderboard = { invalidate = function() record('invalidate') end }
CP.Payouts = {
    setType = function(src, t, amount, reason, role) record('setType', src, t, amount, reason, role); return true end,
    setMission = function(src, id, amount, reason) record('setMission', src, id, amount, reason); return true end,
    baseFor = function(def) return def.id == 'gang_shootout' and 1200 or 800 end,
    sourceFor = function(def) return def.id == 'gang_shootout' and 'admin' or 'type' end,
}
CP.Challenge = {
    startSeason = function(src, name) record('startSeason', src, name); return true end,
    endSeason = function(src) record('endSeason', src); return true end,
}
CP.Testing = { start = function(src, opts) record('testStart', src, opts); return true end }
CP.Alerts = { inArena = function(src) return buckets[tonumber(src)] ~= nil and buckets[tonumber(src)] ~= 0 end }
CP.Operations = { active = function() return nil end }

local MISSIONS = {
    { id = 'beat_patrol', label = 'Beat Patrol', type = 'patrol', source = 'builtin', difficulty = 1, minOfficers = 1, maxOfficers = 2, cooldown = 600, timeLimit = 900, departments = {}, locations = { {}, {}, {}, {}, {} } },
    { id = 'gang_shootout', label = 'Gang Shootout', type = 'tactical', source = 'builtin', difficulty = 3, minOfficers = 1, maxOfficers = 4, cooldown = 1200, timeLimit = 600, departments = {}, locations = { {}, {}, {} } },
    { id = 'fib_raid', label = 'FIB Raid', type = 'investigation', source = 'custom', version = 3, difficulty = 2, minOfficers = 2, maxOfficers = 4, cooldown = 900, timeLimit = 900, departments = { 'fib' }, locations = { {} } },
    { id = 'weekly_boss_kingpin', label = 'Kingpin', type = 'tactical', source = 'builtin', isBoss = true, difficulty = 3, minOfficers = 1, maxOfficers = 4, cooldown = 0, timeLimit = 1200, departments = {}, locations = { {} } },
    { id = 'evoc_course', label = 'EVOC Course', type = 'training', source = 'builtin', difficulty = 1, minOfficers = 1, maxOfficers = 1, cooldown = 300, timeLimit = 400, departments = {}, locations = { {} } },
}
local byId = {}
for _, m in ipairs(MISSIONS) do byId[m.id] = m end
CP.Missions = {
    list = function() return MISSIONS end,
    get = function(id) return byId[id] end,
    all = function() return byId end,
    isEnabled = function(id) return id ~= 'evoc_course' end,
    reload = function() record('reload'); return { loaded = 5, builtin = 4, custom = 1, failed = { { id = 'broken', file = 'missions/custom/broken.lua', error = 'bad block' } }, warnings = {} } end,
}

-- A tiny run engine stand-in.
local runs = {}
local function participant(src, dept, status, arrived)
    local i = infos[src]
    return { src = src, citizenid = i.citizenid, name = i.name, callsign = i.callsign, department = dept,
        departmentShort = dept:upper(), status = status or 'active', arrived = arrived ~= false,
        presence = { inRange = 0, total = 0 } }
end
CP.Runs = {
    all = function() local out = {} for _, r in pairs(runs) do if r.state ~= 'ended' then out[#out + 1] = r end end table.sort(out, function(a, b) return a.id < b.id end) return out end,
    get = function(id) return runs[id] end,
    activeSrcs = function(run) local out = {} for _, s in ipairs(run.order) do if run.participants[s].status == 'active' then out[#out + 1] = s end end return out end,
    summary = function(run)
        local list = {}
        for _, s in ipairs(run.order) do
            local p = run.participants[s]
            list[#list + 1] = { src = s, name = p.name, callsign = p.callsign, departmentShort = p.departmentShort, status = p.status }
        end
        return { runId = run.id, missionType = run.missionType, missionLabel = run.mission.label, tier = 'reinforced', state = run.state,
            remaining = 300, test = run.test ~= nil, operationId = run.operationId, participants = list }
    end,
    removeParticipant = function(run, src, reason, opts)
        record('removeParticipant', run.id, src, reason, opts)
        run.participants[src].status = 'left'
        run.participants[src].endReason = reason
        return 1
    end,
    award = function() end, penalize = function() end,
}
local function newRun(id, missionId, parts, extra)
    local run = { id = id, missionId = missionId, mission = byId[missionId] or { id = missionId, label = missionId, objectives = {} },
        missionType = (byId[missionId] or {}).type or 'patrol', state = 'in_progress', order = {}, participants = {},
        objectiveIndex = 1, objectives = { { status = 'active', state = {} }, { status = 'pending', state = {} } },
        location = { label = 'Spot A', start = { coords = vec3(0.0, 0.0, 0.0), radius = 50.0 } },
        acceptedAt = H.time - 60, startedAt = H.time, seed = 42, host = parts[1].src }
    for _, p in ipairs(parts) do run.order[#run.order + 1] = p.src; run.participants[p.src] = p end
    for k, v in pairs(extra or {}) do run[k] = v end
    runs[id] = run
    return run
end

-- ── load the modules ────────────────────────────────────────────────────────
H.load('modules/access/server.lua')
H.load('modules/permissions/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/disputes/server.lua')
H.load('modules/anticheat/server.lua')

H.ok(H.commands['CrimsonPoliceAdmin'] ~= nil and H.commands['CrimsonPoliceAdmin'].restricted == false, 'admin command registered (unrestricted, checked in code)')
for _, name in ipairs({ 'server:sup:forceRecall', 'server:sup:reviewFlagged', 'server:admin:reviewFlagged', 'server:admin:voidRun',
    'server:admin:awardPoints', 'server:admin:suspend', 'server:dispute', 'server:sup:handleDispute', 'server:admin:handleDispute' }) do
    H.ok(H.handlers['crimson-police:' .. name] ~= nil, 'action registered: ' .. name)
end
for _, name in ipairs({ 'getMissionList', 'sup:getLiveRuns', 'sup:getReviewQueue', 'admin:getFlagged', 'admin:searchOfficers',
    'admin:getOfficer', 'admin:getDepartments', 'admin:getPermissions', 'admin:getAudit', 'admin:exportAudit', 'admin:getDisputes' }) do
    H.ok(H.callbacks['crimson-police:' .. name] ~= nil, 'callback registered: ' .. name)
end

-- ── database fixtures ───────────────────────────────────────────────────────
local function resetDb()
    H.sql('DELETE FROM cp_audit')
    H.sql('DELETE FROM cp_disputes')
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_mission_runs_archive')
    H.sql('DELETE FROM cp_officers')
    H.sql('DELETE FROM cp_badges')
    for s, i in pairs(infos) do
        local dept = CP.Access.departmentForJob(i.job.name)
        H.sql('INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department, xp) VALUES (?, ?, ?, ?, ?, ?)',
            { i.citizenid, i.callsign, i.job.gradeName, i.name, dept or 'none', s * 100 })
    end
end
resetDb()

-- Insert a cp_mission_runs row; returns its id.
local function addRow(o)
    local cols = { 'run_uuid', 'mission_type', 'mission_id', 'citizenid', 'department', 'participants', 'departments_n', 'tier', 'state',
        'end_reason', 'points_base', 'final_points', 'cash_base', 'cash_paid', 'cash_status', 'flagged', 'flag_reason', 'voided', 'breakdown' }
    local defaults = { mission_type = 'tactical', mission_id = 'gang_shootout', department = 'sast', participants = 2, departments_n = 1,
        tier = 'reinforced', state = 'completed', end_reason = 'completed', points_base = 200, final_points = 240, cash_base = 800,
        cash_paid = 0, cash_status = 'none', flagged = 0, flag_reason = '', voided = 0,
        breakdown = '{"cash":{"amount":920,"status":"held"},"flagged":{"reason":"outside_help"}}' }
    local marks, params = {}, {}
    for _, c in ipairs(cols) do
        local v = o[c]
        if v == nil then v = defaults[c] end
        marks[#marks + 1] = '?'
        params[#params + 1] = v
    end
    local sql = ('INSERT INTO cp_mission_runs (%s, created_at) VALUES (%s, %s)'):format(table.concat(cols, ', '), table.concat(marks, ', '),
        o.created_ts and ('FROM_UNIXTIME(%d)'):format(o.created_ts) or 'NOW()')
    local id = MySQL.insert.await(sql, params)
    if o.flag_reason == nil and (o.flagged or 0) == 0 then H.sql('UPDATE cp_mission_runs SET flag_reason = NULL WHERE id = ?', { id }) end
    return id
end

-- ════════════════════════════════════════════════════════════════════════════
-- 1. audit + webhooks
-- ════════════════════════════════════════════════════════════════════════════
convars.cp_webhook_audit = 'https://discord.com/api/webhooks/1/audit'
convars.cp_webhook_flags = 'https://discord.com/api/webhooks/2/flags'
convars.cp_webhook_builder = ''
convars.cp_webhook_operations = 'http://insecure.example.com/hook'

local id1 = co(CP.Admin.audit, 2, 'supervisor', 'audit', 'setTypePayout', 'patrol', 250, 400, 'Busy week')
H.ok(type(id1) == 'number' and id1 > 0, 'audit returns the new id')
local a1 = H.sql('SELECT actor, role, category, action, target, old_value, new_value, reason FROM cp_audit WHERE id = ?', { id1 })[1]
H.eq(a1.actor, 'SUP00002', 'actor src -> citizenid')
H.eq(a1.role, 'supervisor', 'role kept')
H.eq(a1.old_value, 250, 'old value')
H.eq(a1.reason, 'Busy week', 'reason')
H.eq(#http.calls, 1, 'audit webhook posted')
H.eq(http.calls[1].url, convars.cp_webhook_audit, 'posted to the audit webhook')
local body = require('cjson').decode(http.calls[1].body)
H.eq(body.embeds[1].title, CP.L('admin.action.setTypePayout'), 'embed title is the action label')
H.ok(#body.embeds[1].fields >= 3, 'embed fields')

local long = string.rep('x', 400)
local id2 = co(CP.Admin.audit, 'ABC12345', 'officer', 'flags', 'realCallCancelled', long, long, long, long)
local a2 = H.sql('SELECT role, category, CHAR_LENGTH(target) AS t, CHAR_LENGTH(old_value) AS o, CHAR_LENGTH(new_value) AS n, CHAR_LENGTH(reason) AS r FROM cp_audit WHERE id = ?', { id2 })[1]
H.eq(a2.role, 'console', "role 'officer' is stored as console (automatic entry)")
H.eq(a2.t, 64, 'target clipped to 64')
H.eq(a2.o, 64, 'old clipped')
H.eq(a2.n, 64, 'new clipped')
H.eq(a2.r, 255, 'reason clipped to 255')
H.eq(#http.calls, 1, 'the flags post is queued until the pump runs')
H.step(100)
H.ok(#http.calls >= 2, 'flags webhook posted')
H.eq(http.calls[#http.calls].url, convars.cp_webhook_flags, 'flags category -> flags webhook')

local id3 = co(CP.Admin.audit, 0, nil, 'board', 'weeklyTop3', nil, nil, nil, nil)
H.eq(H.sql('SELECT category, role, actor FROM cp_audit WHERE id = ?', { id3 })[1].category, 'audit', "'board' is stored as audit")
H.eq(H.sql('SELECT role FROM cp_audit WHERE id = ?', { id3 })[1].role, 'console', 'console actor -> console role')
local before = #http.calls
H.eq(CP.Admin.webhook('builder', 'Published', 'x', {}), false, 'empty convar = webhook off')
H.eq(CP.Admin.webhook('operations', 'Launched', 'x', {}), false, 'non-https convar = webhook off')
H.eq(CP.Admin.webhook('nope', 'x', 'x', {}), false, 'unknown category = off')
H.eq(#http.calls, before, 'nothing posted for disabled webhooks')

-- rate limit + 429
H.step(3000)
http.statuses = { { 429, '{"retry_after": 1.5}' }, { 204, '' } }
local n0 = #http.calls
CP.Admin.webhook('audit', 'A', 'first', {})
CP.Admin.webhook('audit', 'B', 'second', {})
H.eq(#http.calls, n0 + 1, 'first post sent, second waits for the gap')
H.advance(1000, 100)
H.eq(#http.calls, n0 + 1, 'the 429 blocks the url')
H.advance(6000, 100)
H.ok(#http.calls >= n0 + 3, 'retried after retry_after and the queued one sent')
H.eq(#CP.Admin._webhookQueue(), 0, 'queue drained')
local fieldsBody = nil
CP.Admin.webhook('audit', string.rep('T', 300), string.rep('D', 5000), { { name = 'n', value = string.rep('v', 2000) }, { 'pair', 'value' }, { name = 'empty', value = '' } })
H.advance(3000, 100)
fieldsBody = require('cjson').decode(http.calls[#http.calls].body)
H.eq(#fieldsBody.embeds[1].title, 256 + 2, 'title clipped (…)')
H.eq(#fieldsBody.embeds[1].fields, 2, 'empty field dropped, pair accepted')
H.ok(#fieldsBody.embeds[1].fields[1].value <= 1003, 'field value clipped')

-- ════════════════════════════════════════════════════════════════════════════
-- 2. /CrimsonPoliceAdmin
-- ════════════════════════════════════════════════════════════════════════════
local function command(src, ...)
    H.clockMs = H.clockMs + 1100
    H.commands['CrimsonPoliceAdmin'].fn(src, { ... }, 'CrimsonPoliceAdmin')
end

command(0)
H.ok(printed(CP.L('admin.cmd.usage_title')), 'console with no args prints the usage')
command(0, 'reload')
H.eq(countCalls('reload'), 1, 'reload -> CP.Missions.reload')
H.ok(printed('5 loaded'), 'reload summary printed')
H.ok(printed('broken'), 'failed mission listed on the console')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'reloadMissions' AND actor = 'console'")[1].n, 1, 'reload audited')

command(0, 'payout', 'type', 'patrol', '900', 'Summer', 'event')
local st = lastCall('setType')
H.eq(st[1], 0, 'setType src console')
H.eq(st[2], 'patrol', 'setType type')
H.eq(st[3], 900, 'setType amount')
H.eq(st[4], 'Summer event', 'reason joined')
H.eq(st[5], 'admin', 'console acts as admin')
command(0, 'payout', 'type', 'patrol', 'clear', 'Back', 'to', 'normal')
H.eq(lastCall('setType')[3], nil, 'clear -> nil amount')
local nType = countCalls('setType')
command(0, 'payout', 'type', 'nosuchtype', '900', 'x')
H.eq(countCalls('setType'), nType, 'unknown type refused')
command(0, 'payout', 'type', 'patrol', '999999', 'x')
H.eq(countCalls('setType'), nType, 'amount above Config.Cash.maxPayout refused')
command(0, 'payout', 'type', 'patrol', '900')
H.eq(countCalls('setType'), nType, 'reason required')
command(0, 'payout', 'mission', 'gang_shootout', '1500', 'Hard', 'mission')
H.eq(lastCall('setMission')[2], 'gang_shootout', 'setMission id')
H.eq(lastCall('setMission')[3], 1500, 'setMission amount')
command(0, 'payout', 'mission', 'nope', '1500', 'x')
H.ok(printed(CP.L('err.unknown_mission')), 'unknown mission refused')

command(0, 'award', 'off00003', '50', 'Great', 'RP')
local aw = lastCall('manualAward')
H.eq(aw[2], 'OFF00003', 'award resolves the stored citizenid (case-insensitive)')
H.eq(aw[3], 50, 'award points')
H.eq(aw[4], 'Great RP', 'award reason')
local nAward = countCalls('manualAward')
command(0, 'award', 'NOBODY99', '50', 'x')
command(0, 'award', 'OFF00003', '0', 'x')
command(0, 'award', 'OFF00003', '20000', 'x')
command(0, 'award', 'OFF00003', '50')
H.eq(countCalls('manualAward'), nAward, 'bad awards refused (unknown, 0, too many, no reason)')

command(0, 'season', 'start', 'Season', 'One')
H.eq(lastCall('startSeason')[2], 'Season One', 'season start name')
command(0, 'season', 'end')
H.eq(countCalls('endSeason'), 1, 'season end')

command(0, 'suspend', 'OFF00006', '7', 'Farming')
local sus = H.sql("SELECT UNIX_TIMESTAMP(suspended_until) AS ts FROM cp_officers WHERE citizenid = 'OFF00006'")[1]
H.eq(sus.ts, H.time + 7 * 86400, 'suspended for 7 days')
H.eq(H.sql("SELECT new_value, reason, role FROM cp_audit WHERE action = 'suspend' AND target = 'OFF00006'")[1].new_value, 7, 'suspension audited')
H.eq(lastNotify(6).key, 'access.suspended_notice', 'the online officer is told')
command(0, 'suspend', 'OFF00006', '0')
H.eq(H.sql("SELECT suspended_until FROM cp_officers WHERE citizenid = 'OFF00006'")[1].suspended_until, nil, '0 days lifts it')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'unsuspend' AND target = 'OFF00006'")[1].n, 1, 'lift audited')
command(0, 'suspend', 'OFF00006', 'x')
H.ok(printed(CP.L('err.invalid_days')), 'bad days refused')

command(0, 'test', 'gang_shootout')
H.ok(printed(CP.L('err.not_in_game')), 'test is in game only')
command(1, 'test', 'gang_shootout', 'heavy', '2')
local ts = lastCall('testStart')
H.eq(ts[1], 1, 'test by the admin')
H.eq(ts[2].missionId, 'gang_shootout', 'test mission')
H.eq(ts[2].tier, 'heavy', 'test tier')
H.eq(ts[2].location, 2, 'test location')
command(1, 'test', 'gang_shootout', '9')
H.eq(lastNotify(1).key, 'err.invalid_location', 'location outside the mission refused')
command(1, 'test', 'gang_shootout', 'random')
H.eq(lastCall('testStart')[2].location, 'random', 'random location')
command(1, 'test', 'gang_shootout', 'bogus')
H.eq(lastNotify(1).key, 'admin.cmd.test_bad_arg', 'bad test argument')
buckets[1] = 4210
command(1, 'test', 'gang_shootout')
H.eq(lastNotify(1).key, 'err.in_arena', 'no test runs from the arena')
buckets[1] = nil

command(1)
H.eq(lastCall('openAdmin')[1], 1, 'no args in game opens the Admin UI')
command(2)
H.eq(lastNotify(2).key, 'err.not_admin', 'non-admins cannot use the command')
H.eq(countCalls('openAdmin'), 1, 'no Admin UI for a supervisor')
command(1, 'nosuch')
H.eq(lastNotify(1).key, 'admin.cmd.help_ingame', 'unknown subcommand shows the in-game help')

-- ════════════════════════════════════════════════════════════════════════════
-- 3. review: approve / void flagged, void any run
-- ════════════════════════════════════════════════════════════════════════════
resetDb()
local R1 = 'aaaaaaaa-1111-4000-8000-000000000001'
local rowA = addRow({ run_uuid = R1, citizenid = 'OFF00003', flagged = 1, flag_reason = 'outside_help', cash_status = 'held' })
local rowB = addRow({ run_uuid = R1, citizenid = 'OFF00006', flagged = 1, flag_reason = 'outside_help', cash_status = 'held' })
local R2 = 'aaaaaaaa-1111-4000-8000-000000000002'
local rowFib = addRow({ run_uuid = R2, citizenid = 'FIB00004', department = 'fib', flagged = 1, flag_reason = 'speed', cash_status = 'held' })
local R3 = 'aaaaaaaa-1111-4000-8000-000000000003'
local rowOwn = addRow({ run_uuid = R3, citizenid = 'SUP00002', flagged = 1, flag_reason = 'presence', cash_status = 'held' })
co(CP.Admin.audit, 'console', 'console', 'flags', 'runFlagged', R1, nil, 'outside_help', 'Killed by: Otto Outsider [OUT00005]')

local ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowA, decision = 'approve', reason = '' })
H.eq(ok, false, 'reason required')
H.eq(res, 'err.reason_required', 'reason error key')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowFib, decision = 'approve', reason = 'ok' })
H.eq(res, 'err.other_department', 'supervisor refused for a run without their department')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowOwn, decision = 'approve', reason = 'mine' })
H.eq(res, 'err.own_run', 'supervisor refused for their own run')
ok, res = act('server:sup:reviewFlagged', 3, { rowId = rowA, decision = 'approve', reason = 'x' })
H.eq(res, 'err.no_permission', 'officers cannot review')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowA, decision = 'maybe', reason = 'x' })
H.eq(res, 'err.invalid_decision', 'decision validated')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = 'abc', decision = 'approve', reason = 'x' })
H.eq(res, 'err.invalid_row', 'row id validated')

Config.Permissions.supervisor.reviewFlagged = false
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowA, decision = 'approve', reason = 'Verified on camera' })
H.eq(res, 'err.no_permission', 'switched-off supervisor action refused')
Config.Permissions.supervisor.reviewFlagged = true

ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowA, decision = 'approve', reason = 'Verified on camera' })
H.eq(ok, true, 'supervisor approves a flagged run of their department')
local ra = H.sql('SELECT flagged, flag_reason, voided, LOWER(JSON_TYPE(JSON_EXTRACT(breakdown, "$.flagged"))) AS jf FROM cp_mission_runs WHERE id = ?', { rowA })[1]
H.eq(ra.flagged, 0, 'flag cleared')
H.eq(ra.flag_reason, 'outside_help', 'flag_reason kept')
H.eq(ra.jf, 'null', 'breakdown flag cleared (JSON null)')
H.eq(lastCall('cashRelease')[1], rowA, 'held cash released')
H.eq(lastCall('onRowApproved')[1], rowA, 'scoring hook')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'approveFlagged' AND category = 'flags' AND actor = 'SUP00002'")[1].n, 1, 'approval audited')
H.eq(lastNotify(3).key, 'admin.notice.run_approved', 'officer told')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowA, decision = 'approve', reason = 'again' })
H.eq(res, 'err.not_flagged', 'cannot approve twice')

ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowB, decision = 'void', reason = 'Joined only for the cash' })
H.eq(ok, true, 'supervisor voids a flagged run')
local rb = H.sql('SELECT flagged, voided, cash_status FROM cp_mission_runs WHERE id = ?', { rowB })[1]
H.eq(rb.voided, 1, 'voided')
H.eq(rb.flagged, 1, 'stays flagged')
H.eq(rb.cash_status, 'held', 'cash stays held until the window closes')
H.eq(lastCall('onRowVoided')[1], rowB, 'scoring void hook')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = rowB, decision = 'void', reason = 'again' })
H.eq(res, 'err.already_voided', 'cannot void twice')

ok, res = act('server:admin:reviewFlagged', 2, { rowId = rowFib, decision = 'approve', reason = 'x' })
H.eq(res, 'err.no_permission', 'admin endpoint refuses supervisors')
ok, res = act('server:admin:reviewFlagged', 1, { rowId = rowFib, decision = 'approve', reason = 'Checked' })
H.eq(ok, true, 'admin approves any department')

-- void any run
local R4 = 'aaaaaaaa-1111-4000-8000-000000000004'
local v1 = addRow({ run_uuid = R4, citizenid = 'OFF00003', cash_status = 'paid', cash_paid = 920 })
local v2 = addRow({ run_uuid = R4, citizenid = 'OFF00006', cash_status = 'paid', cash_paid = 920 })
ok, res = act('server:admin:voidRun', 2, { runUuid = R4, reason = 'x' })
H.eq(res, 'err.no_permission', 'voidRun is admin only')
ok, res = act('server:admin:voidRun', 1, { runUuid = R4 })
H.eq(res, 'err.reason_required', 'voidRun needs a reason')
ok, res = act('server:admin:voidRun', 1, { runUuid = R4, reason = 'Exploit' })
H.eq(ok, true, 'admin voids a whole run')
H.eq(res.voided, 2, 'both rows voided')
H.eq(H.sql('SELECT cash_status FROM cp_mission_runs WHERE id = ?', { v1 })[1].cash_status, 'paid', 'a paid run is not clawed back')
ok, res = act('server:admin:voidRun', 1, { rowId = v2, reason = 'again' })
H.eq(res, 'err.already_voided', 'row already voided')
ok, res = act('server:admin:voidRun', 1, { runUuid = 'bad uuid!', reason = 'x' })
H.eq(res, 'err.invalid_run', 'uuid validated')
local R5 = 'aaaaaaaa-1111-4000-8000-000000000005'
local adminRow = addRow({ run_uuid = R5, citizenid = 'ADM00001' })
ok, res = act('server:admin:voidRun', 1, { rowId = adminRow, reason = 'x' })
H.eq(res, 'err.own_run', 'nobody voids a run they took part in (admins too)')

-- ════════════════════════════════════════════════════════════════════════════
-- 4. anticheat: voids -> suspension
-- ════════════════════════════════════════════════════════════════════════════
H.sql('UPDATE cp_officers SET suspended_until = NULL')
local R6 = 'aaaaaaaa-1111-4000-8000-000000000006'
local s1 = addRow({ run_uuid = R6 .. '', citizenid = 'OFF00003', voided = 1 })
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), false, 'two voids (R4 + this) do not suspend yet')
local R7 = 'aaaaaaaa-1111-4000-8000-000000000007'
addRow({ run_uuid = R7, citizenid = 'OFF00003', mission_type = 'manual_award', mission_id = 'manual_award', voided = 1 })
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), false, 'voided manual awards do not count')
local old = addRow({ run_uuid = 'aaaaaaaa-1111-4000-8000-000000000008', citizenid = 'OFF00003', voided = 1, created_ts = H.time - 40 * 86400 })
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), false, 'voids older than the window do not count')
addRow({ run_uuid = 'aaaaaaaa-1111-4000-8000-000000000009', citizenid = 'OFF00003', voided = 1 })
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), true, 'third void in 30 days suspends')
H.eq(H.sql("SELECT UNIX_TIMESTAMP(suspended_until) AS ts FROM cp_officers WHERE citizenid = 'OFF00003'")[1].ts, H.time + 7 * 86400, 'for Config.AntiCheat.suspendDays')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'autoSuspend' AND target = 'OFF00003'")[1].n, 1, 'auto-suspension audited')
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), false, 'no second suspension while suspended')
H.sql("UPDATE cp_officers SET suspended_until = NULL WHERE citizenid = 'OFF00003'")
H.sql("UPDATE cp_audit SET created_at = NOW() + INTERVAL 5 SECOND WHERE action = 'autoSuspend'")
H.time = H.time + 20   -- past CP.Access' 15 s suspension cache
H.eq(co(CP.AntiCheat.onVoided, 'OFF00003'), false, 'voids before the last auto-suspension are not counted again')
H.eq(H.sql("SELECT suspended_until FROM cp_officers WHERE citizenid = 'OFF00003'")[1].suspended_until, nil, 'still not suspended')
local _ = s1 and old

-- ════════════════════════════════════════════════════════════════════════════
-- 5. force recall + live runs + mission list
-- ════════════════════════════════════════════════════════════════════════════
local run1 = newRun('run-1', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast', 'active', false) })
local run2 = newRun('run-2', 'fib_raid', { participant(4, 'fib') })
ok, res = act('server:sup:forceRecall', 2, { runId = 'run-2', src = 4 })
H.eq(res, 'err.other_department', 'force recall only for runs involving their department')
ok, res = act('server:sup:forceRecall', 3, { runId = 'run-1', src = 6 })
H.eq(res, 'err.no_permission', 'officers cannot force recall')
ok, res = act('server:sup:forceRecall', 2, { runId = 'run-1', src = 99 })
H.eq(res, 'err.not_participant', 'target must be an active participant')
ok, res = act('server:sup:forceRecall', 2, { runId = 'nope', src = 6 })
H.eq(res, 'err.invalid_run', 'unknown run')
ok, res = act('server:sup:forceRecall', 2, { runId = 'run-1', src = 6, reason = 'Needed on a real call' })
H.eq(ok, true, 'supervisor force recalls')
local rp = lastCall('removeParticipant')
H.eq(rp[3], 'force_recall', 'end reason force_recall')
H.eq(rp[4].notify, 'admin.notice.force_recalled', 'recalled officer told')
H.eq(H.sql("SELECT reason FROM cp_audit WHERE action = 'forceRecall'")[1].reason, 'Needed on a real call', 'recall audited with the reason')
ok, res = act('server:sup:forceRecall', 1, { runId = 'run-2', src = 4 })
H.eq(ok, true, 'admins recall any department')
run2.participants[4].status = 'active'

local lr = cb('sup:getLiveRuns', 2)
H.eq(lr.ok, true, 'live runs for a supervisor')
H.eq(#lr.data.runs, 1, 'only runs involving their department')
H.eq(lr.data.runs[1].runId, 'run-1', 'their run')
H.eq(lr.data.runs[1].departments[1], 'SAST', 'department tags')
H.eq(lr.data.canRecall, true, 'can recall')
H.eq(#cb('sup:getLiveRuns', 1).data.runs, 2, 'admin (no department) sees every run')
H.eq(cb('sup:getLiveRuns', 3).error, 'err.no_permission', 'officers cannot see live runs')

local ml = cb('getMissionList', 2)
H.eq(ml.ok, true, 'mission list')
H.eq(#ml.data.missions, #MISSIONS, 'every mission, built-in and custom')
local byMl = {}
for _, m in ipairs(ml.data.missions) do byMl[m.id] = m end
H.eq(byMl.gang_shootout.basePayout, 1200, 'base payout from CP.Payouts.baseFor')
H.eq(byMl.gang_shootout.payoutSource, 'admin', 'payout source')
H.eq(#byMl.gang_shootout.runningNow, 1, 'who is running it now (active only)')
H.eq(byMl.gang_shootout.runningNow[1].name, 'Olly Officer', 'running officer name')
H.eq(byMl.gang_shootout.crossDeptEligible, true, 'open to all, 2+ officers -> eligible')
H.eq(byMl.fib_raid.crossDeptEligible, false, 'department-limited mission not eligible')
H.eq(byMl.weekly_boss_kingpin.crossDeptEligible, false, 'never the boss')
H.eq(byMl.evoc_course.crossDeptEligible, false, 'solo mission / disabled not eligible')
H.eq(byMl.fib_raid.source, 'custom', 'custom source')
H.eq(ml.data.canLaunch, true, 'supervisor may launch')
H.eq(cb('getMissionList', 3).error, 'err.no_permission', 'officers never see the list')

-- ════════════════════════════════════════════════════════════════════════════
-- 6. disputes
-- ════════════════════════════════════════════════════════════════════════════
resetDb()
local D1 = 'bbbbbbbb-2222-4000-8000-000000000001'
local dFlag = addRow({ run_uuid = D1, citizenid = 'OFF00003', flagged = 1, flag_reason = 'presence', cash_status = 'held' })
local dPartner = addRow({ run_uuid = D1, citizenid = 'OFF00006' })
local D2 = 'bbbbbbbb-2222-4000-8000-000000000002'
local dFail = addRow({ run_uuid = D2, citizenid = 'OFF00003', state = 'failed', end_reason = 'mission_failed', final_points = 20 })
local D3 = 'bbbbbbbb-2222-4000-8000-000000000003'
local dVoid = addRow({ run_uuid = D3, citizenid = 'OFF00003', voided = 1, flagged = 1, flag_reason = 'speed', cash_status = 'held' })
local D4 = 'bbbbbbbb-2222-4000-8000-000000000004'
local dDone = addRow({ run_uuid = D4, citizenid = 'OFF00003' })
local D5 = 'bbbbbbbb-2222-4000-8000-000000000005'
local dOld = addRow({ run_uuid = D5, citizenid = 'OFF00003', state = 'failed', created_ts = H.time - 72 * 3600 })
local D6 = 'bbbbbbbb-2222-4000-8000-000000000006'
local dVoid2 = addRow({ run_uuid = D6, citizenid = 'OFF00003', voided = 1, cash_status = 'held' })
local dOwnSup = addRow({ run_uuid = D6, citizenid = 'SUP00007' })

-- pure rules
H.eq(CP.Disputes.kindOf({ voided = 1, flagged = 1, state = 'completed' }), 'voided', 'voided wins')
H.eq(CP.Disputes.kindOf({ voided = 0, flagged = true, state = 'failed' }), 'flagged', 'then flagged')
H.eq(CP.Disputes.kindOf({ state = 'failed' }), 'failed', 'then failed')
H.eq(CP.Disputes.kindOf({ state = 'completed' }), nil, 'a normal completed run is not disputable')
H.eq(CP.Disputes.goesTo('failed'), 'admin', 'failed -> admin')
H.eq(CP.Disputes.goesTo('voided'), 'supervisor', 'voided -> supervisor')
local okE, errE = CP.Disputes.eligible({ citizenid = 'X', state = 'failed', created_ts = H.time }, 'Y', H.time)
H.eq(errE, 'err.not_your_run', 'only your own rows')
okE, errE = CP.Disputes.eligible({ citizenid = 'X', mission_type = 'manual_award', flagged = 1, created_ts = H.time }, 'X', H.time)
H.eq(errE, 'err.not_disputable', 'manual awards are not disputable')
okE, errE = CP.Disputes.eligible({ citizenid = 'X', state = 'failed', created_ts = H.time - 49 * 3600 }, 'X', H.time)
H.eq(errE, 'err.dispute_window', '48 h window')
Config.Disputes.windowHours = 72
okE = CP.Disputes.eligible({ citizenid = 'X', state = 'failed', created_ts = H.time - 49 * 3600 }, 'X', H.time)
H.eq(okE, true, 'window read from config at call time')
Config.Disputes.windowHours = 48

local function dispute(src, payload)
    H.clockMs = H.clockMs + 21000   -- 3 disputes a minute per officer
    return act('server:dispute', src, payload)
end
ok, res = dispute(3, { rowId = dFlag, reason = '' })
H.eq(res, 'err.reason_required', 'dispute needs a reason')
ok, res = dispute(3, { rowId = dPartner, reason = 'not mine' })
H.eq(res, 'err.not_your_run', "cannot dispute someone else's row")
ok, res = dispute(3, { rowId = dDone, reason = 'why' })
H.eq(res, 'err.not_disputable', 'completed, unflagged rows are not disputable')
ok, res = dispute(3, { rowId = dOld, reason = 'late' })
H.eq(res, 'err.dispute_window', 'outside the window')
ok, res = dispute(5, { rowId = dFlag, reason = 'x' })
H.eq(res, 'err.not_police', 'non-officers cannot dispute')
ok, res = dispute(3, { rowId = dFlag, reason = 'I was covering the back door' })
H.eq(ok, true, 'officer disputes their flagged run')
H.eq(res.goesTo, 'supervisor', 'flagged -> supervisor')
local disFlag = res.disputeId
H.ok(#H.findEvents('crimson-police:client:notify') >= 0, 'staff notified (toast stub)')
local supToast = false
for _, n in ipairs(notifies) do if n.src == 2 and n.key == 'admin.notice.new_dispute' then supToast = true end end
H.ok(supToast, 'an online supervisor of the department is told')
ok, res = dispute(3, { rowId = dFlag, reason = 'again' })
H.eq(res, 'err.dispute_open', 'one open dispute per row')
ok, res = dispute(3, { rowId = dFail, reason = 'Bugged NPC stuck in a wall' })
H.eq(res.goesTo, 'admin', 'failed -> admin')
local disFail = res.disputeId
ok, res = dispute(3, { rowId = dVoid, reason = 'I did not teleport' })
H.eq(res.kind, 'voided', 'voided kind')
local disVoid = res.disputeId
ok, res = dispute(3, { rowId = dVoid2, reason = 'Please check' })
local disVoid2 = res.disputeId
H.ok(disVoid2 ~= nil, 'second voided dispute')

-- the atomic insert refuses a second row even without the pre-check
H.eq(MySQL.insert.await([[INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to)
  SELECT ?, ?, ?, ? FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM cp_disputes WHERE run_id = ?)]], { dFlag, 'OFF00003', 'x', 'supervisor', dFlag }), 0, 'atomic insert refuses a duplicate')

-- lists
local forSup = co(CP.Disputes.forSupervisor, 2)
H.eq(#forSup, 3, 'supervisor sees the flagged/voided disputes of their department')
local forSup7 = co(CP.Disputes.forSupervisor, 7)
H.eq(#forSup7, 2, 'never disputes about runs they took part in')
H.eq(#co(CP.Disputes.forSupervisor, 4), 0, 'other departments see nothing')
H.eq(#co(CP.Disputes.forSupervisor, 1), 3, 'an admin without a department sees every supervisor dispute')
local forAdmin = co(CP.Disputes.forAdmin)
H.eq(#forAdmin, 4, 'admin sees every open dispute')
local kinds = {}
for _, d in ipairs(forAdmin) do kinds[d.kind] = (kinds[d.kind] or 0) + 1 end
H.eq(kinds.failed, 1, 'failed kind')
H.eq(kinds.voided, 2, 'voided kind')
H.eq(forAdmin[1].name, 'Olly Officer', 'officer name joined')
H.eq(forAdmin[1].missionLabel, 'Gang Shootout', 'mission label')
local rq = cb('sup:getReviewQueue', 2)
H.eq(rq.ok, true, 'review queue')
H.eq(#rq.data.disputes, 3, 'queue carries the disputes')
H.eq(cb('admin:getDisputes', 1).data.disputes[1].id ~= nil, true, 'admin:getDisputes')

-- answering
ok, res = act('server:sup:handleDispute', 2, { disputeId = disFail, decision = 'approve', reason = 'x', awardPoints = 10 })
H.eq(res, 'err.no_permission', 'supervisors never answer failed-run disputes')
ok, res = act('server:sup:handleDispute', 7, { disputeId = disVoid2, decision = 'approve', reason = 'x' })
H.eq(res, 'err.own_run', 'nobody answers a dispute about a run they took part in')
ok, res = act('server:sup:handleDispute', 4, { disputeId = disFlag, decision = 'approve', reason = 'x' })
H.eq(res, 'err.other_department', 'only their department')
ok, res = act('server:sup:handleDispute', 2, { disputeId = disFlag, decision = 'approve', reason = '' })
H.eq(res, 'err.reason_required', 'reason required')
ok, res = act('server:sup:handleDispute', 2, { disputeId = disFlag, decision = 'approve', reason = 'Presence data was wrong' })
H.eq(ok, true, 'supervisor approves a flagged-run dispute')
H.eq(H.sql('SELECT flagged FROM cp_mission_runs WHERE id = ?', { dFlag })[1].flagged, 0, 'run restored (flag cleared)')
H.eq(lastCall('cashRelease')[1], dFlag, 'held cash released')
local dRow = H.sql('SELECT status, handled_by, handled_at FROM cp_disputes WHERE id = ?', { disFlag })[1]
H.eq(dRow.status, 'approved', 'dispute approved')
H.eq(dRow.handled_by, 'SUP00002', 'handled_by')
H.ok(dRow.handled_at ~= nil, 'handled_at')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'disputeApproved'")[1].n, 1, 'answer audited once')
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'approveFlagged'")[1].n, 0, 'no second audit entry for the approval itself')
H.eq(lastNotify(3).key, 'admin.notice.dispute_approved', 'officer told')
ok, res = act('server:sup:handleDispute', 2, { disputeId = disFlag, decision = 'reject', reason = 'changed my mind' })
H.eq(res, 'err.dispute_closed', 'decision is final')

ok, res = act('server:sup:handleDispute', 2, { disputeId = disVoid, decision = 'approve', reason = 'GPS glitch confirmed' })
H.eq(ok, true, 'supervisor approves a voided-run dispute')
local rv = H.sql('SELECT voided, flagged FROM cp_mission_runs WHERE id = ?', { dVoid })[1]
H.eq(rv.voided, 0, 'voided run restored')
H.eq(rv.flagged, 0, 'and unflagged')
H.eq(lastCall('onRowApproved')[1], dVoid, 'XP back')

ok, res = act('server:sup:handleDispute', 2, { disputeId = disVoid2, decision = 'reject', reason = 'Void stands' })
H.eq(ok, true, 'supervisor rejects a voided-run dispute')
H.eq(lastCall('cashForfeit')[1], dVoid2, 'rejected dispute forfeits the held cash')
H.eq(H.sql('SELECT voided FROM cp_mission_runs WHERE id = ?', { dVoid2 })[1].voided, 1, 'void kept')

ok, res = act('server:admin:handleDispute', 2, { disputeId = disFail, decision = 'approve', reason = 'x', awardPoints = 10 })
H.eq(res, 'err.no_permission', 'admin endpoint refuses supervisors')
ok, res = act('server:admin:handleDispute', 1, { disputeId = disFail, decision = 'approve', reason = 'Bug confirmed' })
H.eq(res, 'err.invalid_points', 'failed-run approval needs points')
CP.Scoring.manualAward = function() return false, 'err.award_failed' end
ok, res = act('server:admin:handleDispute', 1, { disputeId = disFail, decision = 'approve', reason = 'Bug confirmed', awardPoints = 60 })
H.eq(res, 'err.award_failed', 'a failed award is reported')
H.eq(H.sql('SELECT status FROM cp_disputes WHERE id = ?', { disFail })[1].status, 'open', 'and the dispute re-opened')
CP.Scoring.manualAward = function(src, cid, points, reason) record('manualAward', src, cid, points, reason); return true end
ok, res = act('server:admin:handleDispute', 1, { disputeId = disFail, decision = 'approve', reason = 'Bug confirmed', awardPoints = 60 })
H.eq(ok, true, 'admin answers a failed-run dispute with a manual award')
local ma = lastCall('manualAward')
H.eq(ma[2], 'OFF00003', 'award to the officer')
H.eq(ma[3], 60, 'award points')
H.eq(H.sql("SELECT new_value FROM cp_audit WHERE action = 'disputeApproved' ORDER BY id DESC LIMIT 1")[1].new_value, '+60', 'audit shows the award')

local officerView = co(CP.Disputes.forOfficer, 'OFF00003', 'admin', 1)
H.eq(#officerView, 1, 'disputes about failed runs for the Officers screen')
H.eq(officerView[1].status, 'approved', 'with their status')
H.eq(officerView[1].canHandle, false, 'a decided dispute cannot be handled')

-- new-dispute toasts: when every online supervisor of the department took part in the run, the admins are told
do
    local function toldSince(mark)
        local told = {}
        for i = mark + 1, #notifies do
            if notifies[i].key == 'admin.notice.new_dispute' then told[notifies[i].src] = true end
        end
        return told
    end
    local D7 = 'bbbbbbbb-2222-4000-8000-000000000007'
    local dAll = addRow({ run_uuid = D7, citizenid = 'OFF00003', flagged = 1, flag_reason = 'presence', cash_status = 'held' })
    addRow({ run_uuid = D7, citizenid = 'SUP00002' })
    addRow({ run_uuid = D7, citizenid = 'SUP00007' })
    local mark = #notifies
    local okA, resA = dispute(3, { rowId = dAll, reason = 'Both sergeants were on it with me' })
    H.eq(okA and resA.goesTo, 'supervisor', 'a flagged-run dispute still goes to the supervisors')
    local told = toldSince(mark)
    H.eq(told[1], true, 'every sast supervisor took part: the admin is told instead')
    H.eq(told[2] or told[7] or false, false, 'no supervisor who took part is told')
    H.eq(told[4] or false, false, 'another department is not told')
    local D8 = 'bbbbbbbb-2222-4000-8000-000000000008'
    local dOne = addRow({ run_uuid = D8, citizenid = 'OFF00003', flagged = 1, flag_reason = 'presence', cash_status = 'held' })
    addRow({ run_uuid = D8, citizenid = 'SUP00007' })
    mark = #notifies
    dispute(3, { rowId = dOne, reason = 'Only Sue was there' })
    told = toldSince(mark)
    H.eq(told[2], true, 'a supervisor who did not take part is told')
    H.eq(told[1] or told[7] or false, false, 'while one can answer, admins and participants are not told')
    -- with the switch off admins are told either way (unchanged)
    local sup = Config.Permissions.supervisor
    local was = sup.handleDisputes
    sup.handleDisputes = false
    local D9 = 'bbbbbbbb-2222-4000-8000-000000000009'
    local dOff = addRow({ run_uuid = D9, citizenid = 'OFF00003', flagged = 1, flag_reason = 'presence', cash_status = 'held' })
    mark = #notifies
    dispute(3, { rowId = dOff, reason = 'Switch off' })
    told = toldSince(mark)
    H.eq(told[1], true, 'switch off: the admin is told')
    H.eq(told[2] or told[7] or false, false, 'switch off: supervisors are not told')
    sup.handleDisputes = was
end

-- ════════════════════════════════════════════════════════════════════════════
-- 7. anticheat: checkEvent, flags, outside help, presence, idle
-- ════════════════════════════════════════════════════════════════════════════
runs = {}
local ar = newRun('run-ac', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast') })
H.players[3].coords = vec3(100.0, 0.0, 0.0)
local okC, why = CP.AntiCheat.checkEvent(ar, 3, 1, { type = 'low_health', netId = 5 })
H.eq(okC, true, 'valid event accepted')
okC, why = CP.AntiCheat.checkEvent(ar, 3, 1, { type = 'low_health', netId = 5, coords = vec3(1, 2, 3), time = 99 })
H.eq(why, 'err.duplicate_event', 'exact duplicate within 1 s dropped (coords/time ignored)')
okC = CP.AntiCheat.checkEvent(ar, 3, 1, { type = 'low_health', netId = 5, try = 2 })
H.eq(okC, true, 'a retry counter makes it a different event')
H.clockMs = H.clockMs + 1500
okC = CP.AntiCheat.checkEvent(ar, 3, 1, { type = 'low_health', netId = 5 })
H.eq(okC, true, 'the same evidence later is fine')
okC, why = CP.AntiCheat.checkEvent(ar, 5, 1, { type = 'x' })
H.eq(why, 'err.not_participant', 'non-participants refused')
okC, why = CP.AntiCheat.checkEvent(ar, 3, 'a', { type = 'x' })
H.eq(why, 'err.invalid_event', 'bad index')
H.eq(ar.flagged, nil, 'nothing flagged so far')
H.clockMs = H.clockMs + 1100
okC, why = CP.AntiCheat.checkEvent(ar, 3, 2, { type = 'x' })
H.eq(why, 'err.unexpected_event', 'an event for a later objective is refused')
H.eq(ar.flagged.reason, 'unexpected_event', 'and flags the run')
ar.objectiveIndex = 2
ar.objectives[1].status = 'done'
ar.objectives[2].status = 'active'
okC, why = CP.AntiCheat.checkEvent(ar, 3, 1, { type = 'late' })
H.eq(why, 'err.stale_event', 'a late event for a finished objective is dropped quietly')

-- speed
H.clockMs = H.clockMs + 2000
H.players[3].coords = vec3(100.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(ar, 3, 2, { type = 'a' })
H.clockMs = H.clockMs + 2000
H.players[3].coords = vec3(200.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(ar, 3, 2, { type = 'b' })
local flagsBefore = H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'runFlagged' AND new_value = 'speed'")[1].n
H.eq(flagsBefore, 0, '50 m/s is fine')
H.clockMs = H.clockMs + 2000
H.players[3].coords = vec3(2200.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(ar, 3, 2, { type = 'c' })
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'runFlagged' AND new_value = 'speed' AND target = 'run-ac'")[1].n, 1, '1000 m/s flags speed (recorded)')
H.eq(ar.flagged.reason, 'unexpected_event', 'the first reason stays on the run')
-- bucket change discards the pair (fresh run: its speed flag is not recorded yet)
local bk = newRun('run-bk', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast') })
H.clockMs = H.clockMs + 2000
buckets[6] = 4210
H.players[6].coords = vec3(0.0, 0.0, 0.0)
okC, why = CP.AntiCheat.checkEvent(bk, 6, 1, { type = 'd' })
H.eq(why, 'err.in_arena', 'in-arena src refused, never flagged')
buckets[6] = nil
H.clockMs = H.clockMs + 2000
H.players[6].coords = vec3(0.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(bk, 6, 1, { type = 'e' })
bk.participants[6].lastEvent.bucket = 4210   -- as if the last position was taken in another bucket
H.clockMs = H.clockMs + 2000
H.players[6].coords = vec3(5000.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(bk, 6, 1, { type = 'f' })
H.eq(H.sql("SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'runFlagged' AND target = 'run-bk'")[1].n, 0, 'no speed flag across a bucket change')
H.eq(bk.flagged, nil, 'run not flagged')
H.clockMs = H.clockMs + 2000
H.players[6].coords = vec3(9000.0, 0.0, 0.0)
CP.AntiCheat.checkEvent(bk, 6, 1, { type = 'g' })
H.eq(bk.flagged and bk.flagged.reason, 'speed', 'the same jump within one bucket flags speed')

-- rate limit
H.clockMs = H.clockMs + 2000
local refused = 0
for i = 1, 15 do
    local _, whyR = CP.AntiCheat.checkEvent(bk, 6, 1, { type = 'spam', n = i })
    if whyR == 'err.rate_limited' then refused = refused + 1 end
end
H.eq(refused, 5, 'per-src rate limit (10/s)')

-- test runs are never flagged
local tr = newRun('run-test', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast') }, { test = { adminSrc = 1 } })
H.eq(CP.AntiCheat.flag(tr, nil, 'speed', 'x'), false, 'test runs are never flagged')
H.eq(tr.flagged, nil, 'no flag on the test run')

-- outside help
runs['run-test'] = nil
local oh = newRun('run-oh', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast') })
CP.AntiCheat.onNpcKilled(oh, 3)
H.eq(oh.flagged, nil, 'participant kills are not outside help')
Config.AntiCheat.outsideKillsToFlag = 2
CP.AntiCheat.onNpcKilled(oh, 5)
H.eq(oh.flagged, nil, 'below outsideKillsToFlag')
CP.AntiCheat.onNpcKilled(oh, 5)
H.eq(oh.flagged.reason, 'outside_help', 'outside_help at the threshold')
H.ok(oh.flagged.detail:find('Otto Outsider', 1, true) ~= nil, 'names the killer')
Config.AntiCheat.outsideKillsToFlag = 1
local ohRow = addRow({ run_uuid = 'run-oh', citizenid = 'OFF00006', flagged = 1, flag_reason = 'outside_help', cash_status = 'held' })
local fr = cb('sup:getReviewQueue', 2)
local found = nil
for _, f in ipairs(fr.data.flagged) do if f.rowId == ohRow then found = f end end
H.ok(found ~= nil, 'flagged row in the queue')
H.ok(found and found.flagDetail and found.flagDetail:find('Otto Outsider', 1, true) ~= nil, 'queue shows who helped')
H.eq(found and found.cash, 920, 'held cash amount from the breakdown')
H.eq(found and found.flagReason, 'outside_help', 'flag reason')
H.eq(cb('sup:getReviewQueue', 6).error, 'err.no_permission', 'officers get no queue')
H.eq(#cb('admin:getFlagged', 1).data.flagged >= 1, true, 'admin:getFlagged')

-- participant flag
H.eq(CP.AntiCheat.flag(oh, 6, 'presence', 'share 40%'), true, 'participant-level flag')
H.eq(oh.participants[6].flagged.reason, 'presence', 'recorded on the participant')
H.eq(CP.AntiCheat.flag(oh, 6, 'presence', 'again'), false, 'recorded once')
H.eq(CP.AntiCheat.flag(oh, 99, 'presence'), false, 'unknown participant ignored')

-- presence
CP.Blocks.register('ac_test_block', {
    presence = function(ctx, src, coords) return CP.U.dist(coords, ctx.state.point) end,
})
local pr = newRun('run-pr', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast') })
pr.objectives[1] = { status = 'active', state = { point = vec3(0.0, 0.0, 0.0) }, obj = { block = 'ac_test_block', presenceRange = 150 } }
H.players[3].coords = vec3(100.0, 0.0, 0.0)
H.players[6].coords = vec3(400.0, 0.0, 0.0)
for _ = 1, 7 do CP.AntiCheat._sample(5) end
H.players[6].coords = vec3(50.0, 0.0, 0.0)
for _ = 1, 3 do CP.AntiCheat._sample(5) end
H.eq(pr.participants[3].presence.total, 50, 'sampled seconds')
H.eq(pr.participants[3].presence.inRange, 50, 'always in range')
H.eq(pr.participants[6].presence.inRange, 15, 'in range 3 of 10 samples')
H.eq(CP.AntiCheat.presenceOk(pr, pr.participants[3]), true, '100% present')
H.eq(CP.AntiCheat.presenceOk(pr, pr.participants[6]), false, '30% < presenceShare')
H.eq(pr.participants[6].flagged and pr.participants[6].flagged.reason, 'presence', 'a failing participant is flagged presence')
H.ok(pr.participants[6].flagged.detail:find('30%', 1, true) ~= nil, 'with the share as detail')
H.eq(H.sql("SELECT old_value FROM cp_audit WHERE action = 'runFlagged' AND target = 'run-pr' AND new_value = 'presence'")[1].old_value, 'OFF00006', 'participant flag recorded with the citizenid')
H.eq(pr.participants[3].flagged, nil, 'a present participant is not flagged')
H.near(CP.AntiCheat.presenceShare(pr.participants[6]), 0.3, 1e-9, 'share')
Config.AntiCheat.presenceShare = 0.25
H.eq(CP.AntiCheat.presenceOk(pr, pr.participants[6]), true, 'presenceShare read at call time')
Config.AntiCheat.presenceShare = 0.70
local solo = newRun('run-solo', 'gang_shootout', { participant(3, 'sast') })
H.eq(CP.AntiCheat.presenceOk(solo, solo.participants[3]), true, 'solo runs always pass')
H.eq(CP.AntiCheat.presenceOk(pr, { presence = { inRange = 0, total = 0 } }), true, 'nothing sampled passes')
-- fallback: no presence hook -> distance from the start, range from Config.AntiCheat.presenceRadius
pr.objectives[1].obj = { block = 'no_such_block' }
pr.participants[3].presence = { inRange = 0, total = 0 }
H.players[3].coords = vec3(140.0, 0.0, 0.0)
CP.AntiCheat._sample(5)
H.eq(pr.participants[3].presence.inRange, 5, 'fallback presenceRadius 150 m from the start')

-- idle check
runs = {}
local idle = newRun('run-idle', 'gang_shootout', { participant(3, 'sast'), participant(6, 'sast', 'active', false) })
CP.AntiCheat._idleCheck(H.time + 100)
H.eq(idle.participants[6].status, 'active', 'not before Config.AntiCheat.idleCheck')
CP.AntiCheat._idleCheck(H.time + 180)
H.eq(idle.participants[6].status, 'left', 'non-arrived participant removed')
H.eq(lastCall('removeParticipant')[3], 'idle', 'with end reason idle')
H.eq(idle.participants[3].status, 'active', 'arrived participant stays')
local nRemove = countCalls('removeParticipant')
CP.AntiCheat._idleCheck(H.time + 400)
H.eq(countCalls('removeParticipant'), nRemove, 'the idle check runs once per run')

-- bucket tracking
idle.participants[3].lastEvent = { coords = vec3(0, 0, 0), at = 0, bucket = 0 }
buckets[3] = 7
CP.AntiCheat._trackBuckets()
H.eq(idle.participants[3].lastEvent, nil, 'bucket change drops the speed position')
buckets[3] = nil

-- signature
H.eq(CP.AntiCheat.evidenceSignature({ type = 'a', netId = 3, coords = vec3(1, 2, 3) }), CP.AntiCheat.evidenceSignature({ netId = 3, type = 'a' }), 'coords ignored, key order irrelevant')
H.ok(CP.AntiCheat.evidenceSignature({ type = 'a', seq = 1 }) ~= CP.AntiCheat.evidenceSignature({ type = 'a', seq = 2 }), 'seq distinguishes')
H.ok(#CP.AntiCheat.evidenceSignature({ blob = string.rep('z', 2000) }) < 64, 'long evidence hashed')

-- ════════════════════════════════════════════════════════════════════════════
-- 8. admin callbacks: officers, departments, permissions, audit
-- ════════════════════════════════════════════════════════════════════════════
local so = cb('admin:searchOfficers', 1, { query = 'olly' })
H.eq(so.ok, true, 'search officers')
H.eq(#so.data.officers, 1, 'by name')
H.eq(so.data.officers[1].citizenid, 'OFF00003', 'found')
H.eq(so.data.officers[1].online, true, 'online flag')
H.eq(#cb('admin:searchOfficers', 1, { query = 'C-4' }).data.officers, 1, 'by callsign')
H.eq(#cb('admin:searchOfficers', 1, { query = 'SUP0' }).data.officers, 2, 'by citizenid')
H.eq(#cb('admin:searchOfficers', 1, { query = '%' }).data.officers, 0, 'LIKE wildcards escaped')
H.eq(#cb('admin:searchOfficers', 1, {}).data.officers, 7, 'empty query lists officers')
H.eq(cb('admin:searchOfficers', 2, { query = 'x' }).error, 'err.no_permission', 'admin only')

H.sql("INSERT INTO cp_badges (citizenid, badge_id) VALUES ('OFF00003', 'ironWheels')")
H.sql("INSERT INTO cp_mission_runs_archive (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base, cash_paid, cash_status) VALUES ('old-run', 'patrol', 'beat_patrol', 'OFF00003', 'sast', 'completed', 'completed', 60, 300, 'paid')")
local go = cb('admin:getOfficer', 1, { citizenid = 'off00003' })
H.eq(go.ok, true, 'officer detail')
H.eq(go.data.citizenid, 'OFF00003', 'stored citizenid')
H.eq(go.data.name, 'Olly Officer', 'name')
H.eq(go.data.level.label, 'Patrol Officer', 'XP level from scoring')
H.eq(#go.data.badges, 1, 'badges')
H.ok(go.data.stats.runs >= 5, 'runs counted (incl. the archive)')
H.eq(go.data.cash.week, 1234, 'cash this week from CP.Cash')
H.ok(go.data.cash.total >= 300, 'cash earned all-time includes the archive')
H.ok(#go.data.runs >= 1, 'recent runs')
do
    -- switch on: the failed-run dispute, plus the open flagged dispute about D7 (section 6: both sast supervisors
    -- took part, so no supervisor can answer it and the admins were told); D8 (Sam did not take part) and D9 stay
    -- with the supervisors
    local D7, D8 = 'bbbbbbbb-2222-4000-8000-000000000007', 'bbbbbbbb-2222-4000-8000-000000000008'
    local byRun, failed = {}, 0
    for _, d in ipairs(go.data.disputes) do
        byRun[d.runUuid] = d
        if d.kind == 'failed' then failed = failed + 1 end
    end
    H.eq(failed, 1, 'disputes about failed runs')
    H.eq(#go.data.disputes, 2, 'plus the one dispute no supervisor can answer')
    H.ok(byRun[D7] and byRun[D7].kind == 'flagged' and byRun[D7].status == 'open' and byRun[D7].canHandle == true,
        'every online supervisor took part: the admin sees the flagged-run dispute and can answer it')
    H.eq(byRun[D8], nil, 'a supervisor who did not take part is online: that dispute stays with the supervisors')
    H.eq(co(CP.Disputes.supervisorCanAnswer, D7), false, 'supervisorCanAnswer: every online supervisor took part')
    H.eq(co(CP.Disputes.supervisorCanAnswer, D8), true, 'supervisorCanAnswer: Sam can answer it')
    -- Sam logs off: nobody online can answer D8 either
    local sam = infos[2]
    infos[2] = nil
    local off = {}
    for _, d in ipairs(cb('admin:getOfficer', 1, { citizenid = 'OFF00003' }).data.disputes) do off[d.runUuid] = d end
    H.ok(off[D8] ~= nil, 'no supervisor who could answer it is online: listed for the admin')
    -- off duty still counts as able to answer it (tellStaff does not fall back to admins either)
    sam.job.onduty = false
    infos[2] = sam
    off = {}
    for _, d in ipairs(cb('admin:getOfficer', 1, { citizenid = 'OFF00003' }).data.disputes) do off[d.runUuid] = d end
    H.eq(off[D8], nil, 'an off-duty supervisor who did not take part keeps it with the supervisors')
    sam.job.onduty = true
end
do
    -- with the supervisors' dispute switch off, admins answer flagged/voided disputes too: the Officers screen lists them
    local sup = Config.Permissions.supervisor
    local was = sup.handleDisputes
    sup.handleDisputes = false
    local all = cb('admin:getOfficer', 1, { citizenid = 'OFF00003' }).data.disputes
    local kinds = {}
    for _, d in ipairs(all) do kinds[d.kind] = true end
    H.ok(#all > 2 and kinds.failed and (kinds.flagged or kinds.voided), 'supervisor-routed disputes shown to admins when supervisors do not handle them')
    H.eq(co(CP.Disputes.supervisorCanAnswer, 'bbbbbbbb-2222-4000-8000-000000000008'), false, 'supervisorCanAnswer is false with the switch off')
    sup.handleDisputes = was
    H.eq(#cb('admin:getOfficer', 1, { citizenid = 'OFF00003' }).data.disputes, 2, 'failed-run disputes and the unanswerable one again with the switch on')
end
H.eq(go.data.suspension.suspended, false, 'not suspended')
H.eq(cb('admin:getOfficer', 1, { citizenid = 'NOPE0000' }).error, 'err.unknown_officer', 'unknown officer')
CP.Scoring.xpLevel, CP.Scoring.badges = nil, nil
go = cb('admin:getOfficer', 1, { citizenid = 'OFF00003' })
H.eq(go.data.badges[1].id, 'ironWheels', 'badge fallback from cp_badges')
H.ok(go.data.level ~= nil, 'XP level fallback from Config.XPLevels')

ok, res = act('server:admin:suspend', 1, { citizenid = 'OFF00003', days = 3, reason = 'SOP breach' })
H.eq(ok, true, 'admin suspends from the Officers screen')
H.eq(res.days, 3, 'days')
H.eq(cb('admin:getOfficer', 1, { citizenid = 'OFF00003' }).data.suspension.suspended, true, 'shown as suspended')
ok, res = act('server:admin:suspend', 1, { citizenid = 'OFF00003', days = 0, reason = 'Appeal granted' })
H.eq(ok, true, 'unsuspend')
ok, res = act('server:admin:suspend', 1, { citizenid = 'OFF00003', days = 0, reason = 'again' })
H.eq(res, 'err.not_suspended', 'cannot lift twice')
ok, res = act('server:admin:suspend', 1, { citizenid = 'OFF00003', days = 3 })
H.eq(res, 'err.reason_required', 'the UI action needs a reason')
ok, res = act('server:admin:suspend', 2, { citizenid = 'OFF00003', days = 3, reason = 'x' })
H.eq(res, 'err.no_permission', 'supervisors cannot suspend')
ok, res = act('server:admin:suspend', 1, { citizenid = 'OFF00003', days = 9999, reason = 'x' })
H.eq(res, 'err.invalid_days', 'days validated')

ok, res = act('server:admin:awardPoints', 1, { citizenid = 'OFF00003', points = 25, reason = 'Bug compensation' })
H.eq(ok, true, 'award points action')
H.eq(lastCall('manualAward')[3], 25, 'award via CP.Scoring.manualAward')
ok, res = act('server:admin:awardPoints', 1, { citizenid = 'OFF00003', points = -5, reason = 'x' })
H.eq(res, 'err.invalid_points', 'points validated')
ok, res = act('server:admin:awardPoints', 2, { citizenid = 'OFF00003', points = 5, reason = 'x' })
H.eq(res, 'err.no_permission', 'admin only')

Config.Cash.source = 'society'
CP.Banking = { societyBalance = function(acc) return acc == 'sast' and 125000 or nil end }
local gd = cb('admin:getDepartments', 1)
H.eq(gd.ok, true, 'departments')
H.eq(#gd.data.departments, 2, 'every department')
H.eq(gd.data.showSociety, true, 'society balance shown')
local depts = {}
for _, d in ipairs(gd.data.departments) do depts[d.key] = d end
H.eq(depts.sast.societyBalance, 125000, 'society balance')
H.eq(depts.sast.members, 4, 'member count from cp_officers')
H.eq(depts.sast.onDuty, 4, 'on-duty count')
H.eq(depts.fib.theme.primary, '#1c2541', 'theme colours')
H.ok(depts.sast.logo.url:find('logos/sast.png', 1, true) ~= nil, 'logo url')
Config.Cash.source = 'server'
H.eq(cb('admin:getDepartments', 1).data.departments[1].societyBalance, nil, 'no balance when cash comes from the server')

local gp = cb('admin:getPermissions', 1)
H.eq(gp.ok, true, 'permissions')
local perm = {}
for _, p in ipairs(gp.data.supervisor) do perm[p.action] = p.enabled end
H.eq(perm.forceRecall, true, 'on')
H.eq(gp.data.supervisor[1].action, 'setTypePayout', 'listed in the spec order')
H.eq(gp.data.supervisor[11].action, 'breakEditLock', 'last in the spec order')
H.eq(perm.builderRollback, false, 'off')
H.eq(#gp.data.adminOnly, 11, 'admin-only list')

-- audit log
H.sql('DELETE FROM cp_audit')
for i = 1, 60 do
    MySQL.insert.await("INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason, created_at) VALUES (?, 'supervisor', ?, ?, 'patrol', '250', ?, ?, FROM_UNIXTIME(?))",
        { i % 2 == 0 and 'SUP00002' or 'FIB00004', i % 3 == 0 and 'flags' or 'audit', i % 3 == 0 and 'voidFlagged' or 'setTypePayout', tostring(i), i == 1 and '=HYPERLINK("x"), "quoted"' or 'r', H.time - i * 3600 })
end
local ga = cb('admin:getAudit', 1, { page = 1 })
H.eq(ga.ok, true, 'audit page')
H.eq(ga.data.total, 60, 'total')
H.eq(ga.data.pages, 2, 'pages of 50')
H.eq(#ga.data.rows, 50, 'first page')
H.eq(ga.data.rows[1].actorName ~= nil, true, 'actor name joined')
H.eq(#cb('admin:getAudit', 1, { page = 2 }).data.rows, 10, 'second page')
H.eq(cb('admin:getAudit', 1, { page = 99 }).data.page, 2, 'page clamped')
H.eq(cb('admin:getAudit', 1, { category = 'flags' }).data.total, 20, 'category filter')
H.eq(cb('admin:getAudit', 1, { action = 'voidFlagged' }).data.total, 20, 'action filter')
H.eq(cb('admin:getAudit', 1, { actor = 'Sam' }).data.total, 30, 'actor filter by name')
H.eq(cb('admin:getAudit', 1, { actor = 'FIB00004' }).data.total, 30, 'actor filter by citizenid')
H.eq(cb('admin:getAudit', 1, { from = H.time - 10 * 3600 + 1 }).data.total, 9, 'from filter (unix)')
H.eq(cb('admin:getAudit', 1, { to = H.time - 50 * 3600 }).data.total, 10, 'to filter (unix)')
H.ok(cb('admin:getAudit', 1, { from = os.date('%Y-%m-%d', H.time - 86400) }).data.total >= 1, 'from filter (date string)')
H.eq(#ga.data.actions, 2, 'distinct actions for the filter')
H.eq(cb('admin:getAudit', 2, {}).error, 'err.no_permission', 'audit is admin only')
local ex = cb('admin:exportAudit', 1, { category = 'audit' })
H.eq(ex.ok, true, 'export')
H.eq(ex.data.rows, 40, 'filtered rows exported')
H.ok(ex.data.csv:sub(1, 3) == 'id,', 'csv header')
local lineCount = select(2, ex.data.csv:gsub('\n', '\n')) + 1
H.eq(lineCount, 41, 'header + one line per row')
H.ok(ex.data.csv:find("'=HYPERLINK", 1, true) ~= nil, 'formula cells neutralised')
H.ok(ex.data.csv:find('""quoted""', 1, true) ~= nil, 'quotes escaped')
H.eq(cb('admin:exportAudit', 1, {}).error, 'err.rate_limited', 'export rate limited')
H.clockMs = H.clockMs + 5000

-- ════════════════════════════════════════════════════════════════════════════
-- 10. review fixes: live participants, UTF-8 clipping, test command, eligibility, history, toasts
-- ════════════════════════════════════════════════════════════════════════════
resetDb()
for k in pairs(notifies) do notifies[k] = nil end
H.clockMs = H.clockMs + 120000

-- A reviewer still ON the run has no row of their own yet: it is still their run.
local L1 = 'cccccccc-3333-4000-8000-000000000001'
newRun(L1, 'gang_shootout', { participant(2, 'sast'), participant(3, 'sast', 'left') })
local liveRow = addRow({ run_uuid = L1, citizenid = 'OFF00003', state = 'failed', end_reason = 'downed', flagged = 1, flag_reason = 'speed', cash_status = 'none' })
local q2 = cb('sup:getReviewQueue', 2)
local seen2 = false
for _, f in ipairs(q2.data.flagged) do if f.rowId == liveRow then seen2 = true end end
H.eq(seen2, false, 'a flagged row of a run the supervisor is still on is not in their queue')
local q7 = cb('sup:getReviewQueue', 7)
local seen7 = false
for _, f in ipairs(q7.data.flagged) do if f.rowId == liveRow then seen7 = true end end
H.eq(seen7, true, 'another supervisor of the department sees it')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = liveRow, decision = 'approve', reason = 'I was there' })
H.eq(res, 'err.own_run', 'a participant still on the run cannot approve it')
ok, res = act('server:sup:reviewFlagged', 2, { rowId = liveRow, decision = 'void', reason = 'I was there' })
H.eq(res, 'err.own_run', 'nor void it')
local adminFlaggedLive = cb('admin:getFlagged', 1).data.flagged
H.ok(#adminFlaggedLive >= 1, 'admins not on the run see it')

H.clockMs = H.clockMs + 21000
ok, res = act('server:dispute', 3, { rowId = liveRow, reason = 'Lag spike, not a teleport' })
H.eq(ok, true, 'the officer who left disputes the flagged row')
local liveDispute = res.disputeId
local supList = CP.Disputes.forSupervisor(2)
local listed = false
for _, d in ipairs(supList) do if d.id == liveDispute then listed = true end end
H.eq(listed, false, 'the dispute is hidden from a supervisor still on that run')
ok, res = act('server:sup:handleDispute', 2, { disputeId = liveDispute, decision = 'approve', reason = 'ok' })
H.eq(res, 'err.own_run', 'and they cannot answer it')
H.eq(H.sql('SELECT status FROM cp_disputes WHERE id = ?', { liveDispute })[1].status, 'open', 'the dispute stays open')

-- A supervisor who was not on the run answers it: one toast for the officer (no double "approved").
for k in pairs(notifies) do notifies[k] = nil end
ok, res = act('server:sup:handleDispute', 7, { disputeId = liveDispute, decision = 'approve', reason = 'Lag confirmed' })
H.eq(ok, true, 'another supervisor approves the dispute')
H.eq(H.sql('SELECT flagged FROM cp_mission_runs WHERE id = ?', { liveRow })[1].flagged, 0, 'the row is approved')
local toasts3 = {}
for _, n in ipairs(notifies) do if n.src == 3 then toasts3[#toasts3 + 1] = n.key end end
H.eq(#toasts3, 1, 'the officer gets exactly one toast')
H.eq(toasts3[1], 'admin.notice.dispute_approved', 'the dispute toast, not a second run_approved one')
runs[L1] = nil

-- UTF-8: clip on character boundaries (utf8mb4 columns count characters; a cut sequence is refused).
local accented = string.rep('a', 254) .. string.rep('é', 20)
local uid = co(CP.Admin.audit, 0, 'console', 'audit', 'utf8Test', string.rep('ü', 80), nil, nil, accented)
H.ok(type(uid) == 'number' and uid > 0, 'an audit entry with a long accented reason is written')
local ur = H.sql('SELECT CHAR_LENGTH(reason) AS c, CHAR_LENGTH(target) AS t, reason FROM cp_audit WHERE id = ?', { uid })[1]
H.eq(ur.c, 255, 'reason clipped to 255 characters')
H.eq(ur.t, 64, 'target clipped to 64 characters')
H.eq(ur.reason:sub(-2), 'é', 'the last character is whole')
local emojiId = co(CP.Admin.audit, 0, 'console', 'audit', 'utf8Test', nil, nil, nil, string.rep('😀', 300))
H.eq(H.sql('SELECT CHAR_LENGTH(reason) AS c FROM cp_audit WHERE id = ?', { emojiId })[1].c, 255, '4-byte characters: 255 of them')
local badId = co(CP.Admin.audit, 0, 'console', 'audit', 'utf8Test', nil, nil, nil, 'abc\195')
H.eq(H.sql('SELECT reason FROM cp_audit WHERE id = ?', { badId })[1].reason, 'abc', 'an invalid byte is dropped, not stored')
local failRow = addRow({ run_uuid = 'cccccccc-3333-4000-8000-000000000002', citizenid = 'OFF00003', state = 'failed', end_reason = 'mission_failed' })
H.clockMs = H.clockMs + 21000
ok, res = act('server:dispute', 3, { rowId = failRow, reason = string.rep('ł', 300) })
H.eq(ok, true, 'a dispute with a long non-ASCII reason is filed')
H.eq(H.sql('SELECT CHAR_LENGTH(reason) AS c FROM cp_disputes WHERE id = ?', { res.disputeId })[1].c, 255, 'dispute reason clipped to 255 characters')
H.eq(#require('cjson').decode('"' .. ('é'):rep(3) .. '"'), 6, 'cjson sanity')

-- /CrimsonPoliceAdmin test goes through CP.Testing.command when it exists (accepted testers, 'auto').
CP.Testing.command = function(src, args) record('testCommand', src, args); return true end
command(1, 'test', 'Gang_Shootout', 'auto', '2')
local tc = lastCall('testCommand')
H.eq(tc[1], 1, 'test command by the admin')
H.eq(tc[2][1], 'gang_shootout', 'mission id normalised to the stored id')
H.eq(tc[2][2], 'auto', "tier 'auto' passed on")
H.eq(tc[2][3], '2', 'location passed on')
H.eq(lastNotify(1).key, 'admin.cmd.test_started', 'test started reply')
command(1, 'test', 'gang_shootout', 'heavy', '2', 'extra')
H.eq(lastNotify(1).key, 'admin.cmd.test_bad_arg', 'too many test arguments refused')
CP.Testing.command = nil
command(0, 'payout', 'mission', 'GANG_SHOOTOUT', '1500', 'Upper', 'case')
H.eq(lastCall('setMission')[2], 'gang_shootout', 'payout mission finds a mission typed in upper case')

-- Cross-Department eligibility follows CP.Operations.eligible when it exists.
CP.Operations.eligible = function(def) return def.id == 'beat_patrol' end
local ml2 = cb('getMissionList', 2)
local el = {}
for _, m in ipairs(ml2.data.missions) do el[m.id] = m.crossDeptEligible end
H.eq(el.beat_patrol, true, 'eligible per CP.Operations')
H.eq(el.gang_shootout, false, 'not eligible per CP.Operations')
CP.Operations.eligible = nil

-- Suspension history on the officer record.
ok = act('server:admin:suspend', 1, { citizenid = 'OFF00006', days = 3, reason = 'Farming é' })
H.eq(ok, true, 'suspended')
ok = act('server:admin:suspend', 1, { citizenid = 'OFF00006', days = 0, reason = 'Appeal accepted' })
H.eq(ok, true, 'lifted')
local rec = cb('admin:getOfficer', 1, { citizenid = 'OFF00006' }).data
H.eq(#rec.suspensions, 2, 'two history entries')
H.eq(rec.suspensions[1].action, 'unsuspend', 'newest first')
H.eq(rec.suspensions[2].action, 'suspend', 'then the suspension')
H.eq(rec.suspensions[2].days, 3, 'with its length')
H.eq(rec.suspensions[2].reason, 'Farming é', 'and its reason')
H.eq(rec.suspensions[2].actorName, 'Ada Min', 'and who did it')
H.eq(rec.suspension.suspended, false, 'not suspended now')

-- ════════════════════════════════════════════════════════════════════════════
-- 9. every locale key used by the Lua files exists in the part
-- ════════════════════════════════════════════════════════════════════════════
local cjson = require('cjson')
local f = assert(io.open(H.root .. 'locales/parts/oversight.json', 'r'))
local part = cjson.decode(f:read('a'))
f:close()
local sharedParts = {}
for _, name in ipairs({ 'core.json', 'ui.json' }) do
    local pf = io.open(H.root .. 'locales/parts/' .. name, 'r')
    if pf then for k, v in pairs(cjson.decode(pf:read('a'))) do sharedParts[k] = v end pf:close() end
end
for _, file in ipairs({ 'modules/admin/server.lua', 'modules/disputes/server.lua', 'modules/anticheat/server.lua' }) do
    local src = assert(io.open(H.root .. file, 'r')):read('a')
    for key in src:gmatch("'([%a_]+%.[%w_%.]+)'") do
        local ns = key:match('^([%a_]+)%.')
        if (ns == 'err' or ns == 'admin' or ns == 'sup' or ns == 'flag') and not key:match('%.$') then
            H.ok(part[key] ~= nil, ('%s: locale key %s in oversight.json'):format(file, key))
            if sharedParts[key] ~= nil and part[key] ~= nil then
                H.eq(part[key], sharedParts[key], 'duplicate key has the same text: ' .. key)
            end
        end
    end
end
for _, k in ipairs({ 'admin.role.console', 'admin.role.admin', 'admin.role.supervisor', 'admin.dispute.kind.flagged', 'admin.dispute.kind.voided',
    'admin.dispute.kind.failed', 'admin.dispute.goes_to.supervisor', 'admin.dispute.goes_to.admin', 'flag.outside_help', 'flag.too_fast',
    'flag.speed', 'flag.presence', 'flag.unexpected_event', 'flag.flagged' }) do
    H.ok(part[k] ~= nil, 'dynamic key ' .. k)
end

return H
