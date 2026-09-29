-- tests/testing_spec.lua · the testing slice: CP.Testing server (invites, start gates, controls, debug
-- geometry, the run-end hook, recording results, the catalog view) and client (panel focus, HUD flag,
-- teleport arena re-check, debug data). Every SQL statement of modules/testing runs here on MariaDB cp_test.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true

local logs = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then logs[#logs + 1] = line return end
    realPrint(line)
end

-- ── natives ─────────────────────────────────────────────────────────────────
local buckets = {}
_G.GetPlayerRoutingBucket = function(src) return buckets[src] or 0 end
local offline = {}
local realName = GetPlayerName
_G.GetPlayerName = function(src) if offline[tonumber(src)] then return nil end return realName(src) end

local function events(name)
    return H.findEvents('crimson-police:' .. name)
end
local function lastEvent(name)
    local list = events(name)
    return list[#list]
end
local function eventsTo(name, target)
    local out = {}
    for _, e in ipairs(events(name)) do if e.target == target then out[#out + 1] = e end end
    return out
end

-- ── stubs of the modules CP.Testing calls ───────────────────────────────────
-- players: 1 = admin (not police), 2 = on-duty officer, 3 = admin who is an off-duty SAST officer,
-- 4 = civilian, 5 = on-duty FIB officer, 6 = supervisor (builderEdit), 7 = officer in the arena
local infos = {
    [1] = { citizenid = 'ADM00001', name = 'Alex Mercer', job = { name = 'unemployed', gradeName = 'Freelancer', gradeLevel = 0, onduty = false } },
    [2] = { citizenid = 'OFF00002', name = 'John Doe', callsign = '2L-14', job = { name = 'sast', gradeName = 'Trooper', gradeLevel = 1, onduty = true } },
    [3] = { citizenid = 'ADM00003', name = 'Sam Porter', job = { name = 'sast', gradeName = 'Sergeant', gradeLevel = 3, onduty = false } },
    [4] = { citizenid = 'CIV00004', name = 'Joe Civ', job = { name = 'unemployed', gradeName = 'Freelancer', gradeLevel = 0, onduty = false } },
    [5] = { citizenid = 'FIB00005', name = 'Dana Whitfield', job = { name = 'fib', gradeName = 'Agent', gradeLevel = 2, onduty = true } },
    [6] = { citizenid = 'SUP00006', name = 'Maria Lopez', callsign = '2L-21', job = { name = 'sast', gradeName = 'Lieutenant', gradeLevel = 4, onduty = true } },
    [7] = { citizenid = 'OFF00007', name = 'Tess Okafor', job = { name = 'sast', gradeName = 'Trooper', gradeLevel = 1, onduty = true } },
}
for src in pairs(infos) do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
local admins = { [1] = true, [3] = true }
local supervisors = { [6] = true }
local arena = {}
local onRun = {}

local DEPTS = {
    sast = { key = 'sast', label = 'San Andreas State Troopers', short = 'SAST' },
    fib = { key = 'fib', label = 'Federal Investigation Bureau', short = 'FIB' },
}
CP.Qbx = {
    getInfo = function(src) local i = infos[src]; if not i then return nil end; local c = CP.U.deepcopy(i); c.src = src; return c end,
    getOnlinePlayers = function() local out = {}; for s in pairs(infos) do if not offline[s] then out[#out + 1] = s end end; table.sort(out); return out end,
    getByCitizenId = function(cid) for s, i in pairs(infos) do if i.citizenid == cid then return s end end return nil end,
}
CP.Access = {
    departmentForJob = function(job) if job == 'sast' then return 'sast' elseif job == 'fib' then return 'fib' end return nil end,
    department = function(key) return DEPTS[key] and CP.U.copy(DEPTS[key]) or nil end,
    departments = function() return { CP.U.copy(DEPTS.fib), CP.U.copy(DEPTS.sast) } end,
    isAdmin = function(src) return admins[src] == true end,
    role = function(src) if admins[src] then return 'admin' elseif supervisors[src] then return 'supervisor' end return 'officer' end,
    getOfficer = function(src)
        local i = infos[src]
        if not i then return nil, 'err.not_police' end
        local dept = CP.Access.departmentForJob(i.job.name)
        if not dept then return nil, 'err.not_police' end
        if not i.job.onduty then return nil, 'err.not_on_duty' end
        return { src = src, citizenid = i.citizenid, name = i.name, department = dept, departmentLabel = DEPTS[dept].label,
            departmentShort = DEPTS[dept].short, job = i.job.name, rank = i.job.gradeName, gradeLevel = i.job.gradeLevel,
            callsign = i.callsign, onduty = true, isSupervisor = supervisors[src] == true, isAdmin = admins[src] == true }
    end,
}
local canCalls = {}
CP.Permissions = {
    can = function(src, action)
        canCalls[#canCalls + 1] = { src = src, action = action }
        if admins[src] then return true end
        if action == 'builderEdit' and supervisors[src] then return true end
        return false, 'err.no_permission'
    end,
}
CP.Alerts = { inArena = function(src) return arena[src] == true or (buckets[src] or 0) ~= 0 end }
local reserved = {}
CP.Draw = {
    isReserved = function(id, i) return reserved[id .. '#' .. i] == true end,
}
local audits, webhooks, notifies, pushes = {}, {}, {}, {}
CP.Admin = {
    audit = function(...) audits[#audits + 1] = table.pack(...) end,
    webhook = function(...) webhooks[#webhooks + 1] = table.pack(...) end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars) notifies[#notifies + 1] = { src = src, kind = kind, key = key, vars = vars } end,
    push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end,
}
local drafted = {}
CP.Builder = { onDraftTested = function(...) drafted[#drafted + 1] = table.pack(...) return true end }

local function lastNotify(src)
    for i = #notifies, 1, -1 do if notifies[i].src == src then return notifies[i] end end
    return nil
end

-- ── missions ────────────────────────────────────────────────────────────────
local function mission(id, extra)
    local def = {
        id = id, label = 'Gang Shootout', type = 'tactical', minOfficers = 1, maxOfficers = 4, difficulty = 3,
        timeLimit = 600, source = 'builtin', defHash = 'aaaa1111', status = 'published', isBoss = false,
        locations = {
            { label = 'Hideout A', start = { coords = vec3(100.0, 200.0, 30.0), radius = 80.0 },
              spawns = { vec4(110.0, 210.0, 30.0, 90.0), vec4(120.0, 220.0, 30.0, 180.0) },
              route = { points = { vec3(0.0, 0.0, 0.0), vec3(10.0, 0.0, 0.0), vec3(20.0, 0.0, 0.0) }, loop = true },
              checkpoints = { vec3(1.0, 1.0, 1.0), vec3(2.0, 2.0, 2.0) },
              safe = vec3(130.0, 230.0, 30.0),
              flee = { { vec3(5.0, 5.0, 5.0), vec3(6.0, 6.0, 6.0) }, { vec3(7.0, 7.0, 7.0) } },
              npcs = { { coords = vec4(140.0, 240.0, 30.0, 0.0), label = 'Hostage' } },
              medals = { gold = 10 } },
            { label = 'Hideout B', start = { coords = vec3(300.0, 400.0, 30.0), radius = 60.0 }, spawns = { vec4(310.0, 410.0, 30.0, 0.0) } },
            { label = 'Hideout C', start = { coords = vec3(500.0, 600.0, 30.0), radius = 60.0 }, spawns = { vec4(510.0, 610.0, 30.0, 0.0) } },
        },
        objectives = {
            { block = 'hostile_waves', label = 'Clear the hideout', spawns = 'spawns', presenceRange = 150.0, blockTraffic = 120.0 },
            { block = 'checkpoint_route', label = 'Drive the route', checkpoints = 'checkpoints', radius = 12.0, presenceRange = 100.0 },
            { block = 'protect_rescue', label = 'Rescue', npcs = 'npcs', safe = 'safe', safeRadius = 8.0, presenceRange = 60.0 },
        },
    }
    for k, v in pairs(extra or {}) do def[k] = v end
    return def
end
local defs = {
    gang_shootout = mission('gang_shootout'),
    prison_break = mission('prison_break', { label = 'Prison Break', defHash = 'bbbb2222' }),
    custom_dockside = mission('custom_dockside', { label = 'Dockside Raid', source = 'custom', version = 3, defHash = 'cccc3333', maxOfficers = 2 }),
    beat_patrol = mission('beat_patrol', { label = 'Beat Patrol', type = 'patrol', maxOfficers = 2, defHash = 'dddd4444' }),
}
Config.DisabledMissions = { 'prison_break' }
local normalized = {}
CP.Missions = {
    get = function(id) return defs[id] end,
    all = function() return CP.U.copy(defs) end,
    normalize = function(def, meta)
        normalized[#normalized + 1] = { def = def, meta = meta }
        if def.broken then return nil, 'objective 1 is broken' end
        local d = CP.U.deepcopy(def)
        d.source, d.version, d.status = meta.source, tonumber(meta.version), meta.status
        d.defHash = meta.defHash or 'draft0001'
        return d
    end,
}

-- ── the run engine (records calls, keeps runs) ──────────────────────────────
local runs, created, calls = {}, {}, {}
local runSeq = 0
local function call(name, ...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
local function lastCall(name)
    for i = #calls, 1, -1 do if calls[i].name == name then return calls[i] end end
    return nil
end
CP.Runs = {
    isOnMission = function(src) return onRun[src] == true end,
    get = function(id) return runs[id] end,
    create = function(opts)
        created[#created + 1] = opts
        runSeq = runSeq + 1
        local run = {
            id = ('run-%d'):format(runSeq), mission = opts.mission, missionId = opts.mission.id, test = CP.U.copy(opts.test),
            state = 'accepted', objectiveIndex = 1, location = opts.mission.locations[opts.locationIndex],
            locationIndex = opts.locationIndex, participants = {}, order = {}, expectedTier = opts.test.forcedTier or 'standard',
            timer = { remaining = 600, paused = false, running = false }, objectives = {}, host = opts.leaderSrc,
        }
        for i, o in ipairs(opts.mission.objectives) do run.objectives[i] = { status = 'pending', obj = o } end
        for _, m in ipairs(opts.members) do
            run.participants[m.src] = { src = m.src, name = m.name, status = 'active', departmentShort = m.departmentShort, arrived = false }
            run.order[#run.order + 1] = m.src
            onRun[m.src] = true
        end
        runs[run.id] = run
        return run
    end,
    testSkip = function(run) call('testSkip', run) run.objectiveIndex = run.objectiveIndex + 1 return true end,
    testRestart = function(run) call('testRestart', run) return true end,
    pauseTimer = function(run, paused) call('pauseTimer', run, paused) run.timer.paused = paused end,
    remaining = function(run) return run.timer.running and run.timer.remaining or nil end,
    anchor = function(run) return run.state == 'in_progress' and vec3(111.0, 222.0, 33.0) or run.location.start.coords end,
    entitiesFor = function(run)
        return {
            { netId = 1, kind = 'ped', armed = true, dead = false }, { netId = 2, kind = 'ped', armed = true, dead = true },
            { netId = 3, kind = 'ped', armed = false, dead = false }, { netId = 4, kind = 'vehicle', armed = false, dead = false },
            { netId = 5, kind = 'object', armed = false, dead = false },
        }
    end,
    endRun = function(run, state, reason)
        call('endRun', run, state, reason)
        run.state = 'ended'
        runs[run.id] = nil
        for _, s in ipairs(run.order) do onRun[s] = nil end
        CP.Testing.onRunEnded(run, state, reason)
    end,
    failRun = function(run, key)
        call('failRun', run, key)
        run.failReason = key
        CP.Runs.endRun(run, 'failed', 'mission_failed')
    end,
}
local function beginRun(run)
    run.state = 'in_progress'
    run.timer.running = true
    run.tier = { tier = run.test.forcedTier or 'standard' }
end

H.load('modules/scaling/server.lua')
H.load('modules/testing/server.lua')
local T = CP.Testing

H.sql('DELETE FROM cp_mission_tests')
H.sql("DELETE FROM cp_officers WHERE citizenid IN ('OFF00002', 'ADM00001')")
H.sql("INSERT INTO cp_officers (citizenid, display_name, department) VALUES ('OFF00002', 'John Doe', 'sast')")

-- ════════════════════════════════════════════════════════════════════════════
-- helpers
-- ════════════════════════════════════════════════════════════════════════════
do
    H.eq(T._validTier('Heavy'), 'heavy', 'tier names are case-insensitive')
    H.eq(T._validTier('legendary'), nil, 'unknown tier')
    local rec = T._adminRecord(1)
    H.eq(rec.department, 'fib', 'a non-police admin gets the first department key (sorted)')
    H.eq(rec.departmentShort, 'FIB', 'short name of that department')
    H.eq(rec.job, nil, 'no job: CP.Runs skips duty re-checks for the admin')
    H.eq(rec.rank, CP.L('test.admin_rank'), 'non-police admin rank label')
    H.eq(rec.citizenid, 'ADM00001', 'citizenid from qbx')
    local rec3 = T._adminRecord(3)
    H.eq(rec3.department, 'sast', 'an off-duty officer admin keeps their department')
    H.eq(rec3.rank, 'Sergeant', 'their grade name')
    H.eq(T._adminRecord(99), nil, 'no character')
end

-- ════════════════════════════════════════════════════════════════════════════
-- start gates
-- ════════════════════════════════════════════════════════════════════════════
do
    local ok, err = T.start(2, { missionId = 'gang_shootout' })
    H.eq(ok, false, 'an officer cannot start a test'); H.eq(err, 'err.no_permission', 'no permission')
    ok, err = T.start(0, { missionId = 'gang_shootout' })
    H.eq(err, 'err.not_in_game', 'console cannot join a test')
    ok, err = T.start(1, { missionId = 'nope' })
    H.eq(err, 'err.test_unknown_mission', 'unknown mission')
    ok, err = T.start(1, { missionId = 'gang_shootout', location = 'abc' })
    H.eq(err, 'err.invalid_payload', 'location must be an index or random')
    ok, err = T.start(1, { missionId = 'gang_shootout', location = 9 })
    H.eq(err, 'err.test_invalid_location', 'location out of range')
    ok, err = T.start(1, { missionId = 'gang_shootout', tier = 'legendary' })
    H.eq(err, 'err.test_invalid_tier', 'bad tier')
    ok, err = T.start(1, { missionId = 'gang_shootout', testers = { 2 } })
    H.eq(err, 'err.test_tester_not_ready', 'a tester needs an accepted invitation')
    Config.Testing.enabled = false
    ok, err = T.start(1, { missionId = 'gang_shootout' })
    H.eq(err, 'err.test_disabled', 'Config.Testing.enabled = false')
    Config.Testing.enabled = true
    arena[1] = true
    ok, err = T.start(1, { missionId = 'gang_shootout' })
    H.eq(err, 'err.in_arena', 'the admin in the arena (foreign flag)')
    arena[1] = nil
    buckets[1] = 4210
    ok, err = T.start(1, { missionId = 'gang_shootout' })
    H.eq(err, 'err.in_arena', 'the admin in another routing bucket')
    buckets[1] = nil
    onRun[1] = true
    ok, err = T.start(1, { missionId = 'gang_shootout' })
    H.eq(err, 'err.already_on_run', 'the admin is on a run')
    onRun[1] = nil
    reserved['gang_shootout#2'] = true
    ok, err = T.start(1, { missionId = 'gang_shootout', location = 2 })
    H.eq(err, 'err.test_location_busy', 'a location another run holds')
    H.eq(#created, 0, 'nothing was created by the refused starts')
end

-- ════════════════════════════════════════════════════════════════════════════
-- invitations
-- ════════════════════════════════════════════════════════════════════════════
local inviteFor5, inviteFor3
do
    arena[7] = true
    offline[8] = true
    local ok, res = T.invite(1, { 1, 2, 3, 4, 5, 7, 8, 2 }, { missionId = 'gang_shootout' })
    H.eq(ok, true, 'invite returns the lobby')
    local skipped = {}
    for _, s in ipairs(res.skipped) do skipped[s.src] = s.error end
    H.eq(skipped[1], 'err.test_invite_self', 'cannot invite yourself')
    H.eq(skipped[4], 'err.test_not_eligible', 'a civilian cannot test')
    H.eq(skipped[7], 'err.in_arena', 'Crimson-Arena rule 5: no invitation for an in-arena player')
    H.eq(skipped[8], 'err.test_player_offline', 'offline')
    H.eq(skipped[2], nil, 'the duplicate target 2 is not reported')
    H.eq(#res.lobby.invites, 3, 'three invitations: officer 2, admin 3, officer 5')
    H.eq(res.lobby.missionId, 'gang_shootout', 'lobby mission')
    H.eq(res.lobby.maxTesters, 8, 'Config.Testing.maxTesters')
    H.eq(#eventsTo('client:testInvite', 2), 1, 'client:testInvite to the officer')
    local ev = lastEvent('client:testInvite').args[1]
    H.eq(ev.missionLabel, 'Gang Shootout', 'invite carries the mission label')
    H.eq(ev.from, 'Alex Mercer', 'and who sent it')
    H.ok(type(ev.inviteId) == 'string', 'and an id')
    local list = T.pendingInvites(5)
    H.eq(#list, 1, 'the FIB officer has one invitation waiting')
    inviteFor5 = list[1].inviteId
    inviteFor3 = T.pendingInvites(3)[1].inviteId
    H.eq(#T.pendingInvites(4), 0, 'the civilian has none')

    -- a second invite call does not duplicate
    ok, res = T.invite(1, { 2 }, { missionId = 'gang_shootout' })
    H.eq(#res.lobby.invites, 3, 'inviting again does not duplicate')

    -- respond
    local okR, errR = T.respond(4, { inviteId = inviteFor5, accepted = true })
    H.eq(errR, 'err.test_invite_gone', 'only the invitee can answer')
    okR, errR = T.respond(5, { inviteId = inviteFor5 })
    H.eq(errR, 'err.invalid_payload', 'accepted must be a boolean')
    arena[5] = true
    okR, errR = T.respond(5, { inviteId = inviteFor5, accepted = true })
    H.eq(errR, 'err.in_arena', 'Crimson-Arena rule 5: accepting from the arena is refused')
    arena[5] = nil
    okR = T.respond(5, { inviteId = inviteFor5, accepted = true })
    H.eq(okR, true, 'accepted')
    H.eq(lastNotify(1).key, 'test.invite_accepted', 'the admin is told')
    okR = T.respond(3, { inviteId = inviteFor3, accepted = true })
    H.eq(okR, true, 'the admin tester accepted')
    local officerInvite = T.pendingInvites(2)[1].inviteId
    okR = T.respond(2, { inviteId = officerInvite, accepted = false })
    H.eq(okR, true, 'declined')
    H.eq(lastNotify(1).key, 'test.invite_declined', 'the admin is told about the decline')
    okR, errR = T.respond(2, { inviteId = officerInvite, accepted = true })
    H.eq(errR, 'err.test_invite_gone', 'a declined invitation is closed')
    local st = T.state(1)
    H.eq(st.lobby.accepted, 2, 'two accepted in the lobby view')
    H.ok(st.active == false, 'no active test yet')

    -- candidates
    local cands = T.candidates(1)
    local bySrc = {}
    for _, c in ipairs(cands) do bySrc[c.src] = c end
    H.eq(bySrc[1], nil, 'the viewer is not a candidate')
    H.eq(bySrc[4], nil, 'civilians are not candidates')
    H.eq(bySrc[5].invite, 'accepted', 'invite status in the candidate list')
    H.eq(bySrc[3].role, 'admin', 'an off-duty officer admin is listed as admin')
    H.eq(bySrc[7].inArena, true, 'in-arena candidates are flagged')
    arena[7] = nil
end

-- ════════════════════════════════════════════════════════════════════════════
-- starting, controls, debug stream, end hook
-- ════════════════════════════════════════════════════════════════════════════
local run
do
    H.reset()
    local ok, data = T.start(1, { missionId = 'gang_shootout', location = 1, tier = 'major', useStartRoute = false, testers = { 5, 3 } })
    H.eq(ok, true, 'test started')
    H.eq(data.tier, 'major', 'forced tier')
    H.eq(data.testers, 3, 'admin + two testers')
    local opts = created[#created]
    H.eq(opts.leaderSrc, 1, 'the admin leads')
    H.eq(opts.test.adminSrc, 1, 'test.adminSrc')
    H.eq(opts.test.forcedTier, 'major', 'test.forcedTier')
    H.eq(opts.test.useStartRoute, false, 'start route off')
    H.eq(opts.test.draft, false, 'not a draft')
    H.eq(opts.members[1].citizenid, 'ADM00001', 'the admin participant record first')
    H.eq(opts.members[1].department, 'fib', 'with a department')
    H.eq(opts.members[2].job, 'fib', 'the officer tester keeps their real officer record')
    H.eq(opts.members[3].job, nil, 'the admin tester has no job (no duty re-checks)')
    H.eq(opts.locationIndex, 1, 'chosen location')
    run = runs[data.runId]
    local ev = lastEvent('client:test')
    H.eq(ev.target, 1, 'client:test to the admin')
    H.eq(ev.args[1].controls, true, 'controls on')
    H.eq(ev.args[1].debug, false, 'debug off at start')
    H.eq(audits[#audits][4], 'testStart', 'every test start is audited')
    H.eq(audits[#audits][3], 'audit', 'category audit')
    H.eq(audits[#audits][5], 'gang_shootout#1', 'target mission#location')
    H.eq(#T.pendingInvites(5), 0, 'invitations are consumed')
    H.eq(T.state(1).lobby.missionId, false, 'the lobby is closed')

    local ok2, err2 = T.start(1, { missionId = 'beat_patrol' })
    H.eq(err2, 'err.test_already_running', 'one test at a time per admin')

    -- controls
    local okC, errC = T.control(5, { control = 'skip' })
    H.eq(errC, 'err.test_no_active', 'a tester has no controls')
    okC, errC = T.control(1, { control = 'jump' })
    H.eq(errC, 'err.invalid_payload', 'unknown control')
    okC, errC = T.control(1, { control = 'skip', runId = 'someone-else' })
    H.eq(errC, 'err.test_not_controller', 'another run id')
    okC, errC = T.control(1, { control = 'skip' })
    H.eq(errC, 'err.test_not_in_progress', 'skip before the run is in progress')
    okC, errC = T.control(1, { control = 'pause' })
    H.eq(errC, 'err.test_not_in_progress', 'pause before the timer runs')
    local okT, tp = T.control(1, { control = 'teleport' })
    H.eq(okT, true, 'teleport before in progress')
    H.eq(tp.target, 'start', 'defaults to the start')
    H.eq(tp.coords.x, 100.0, 'start coords')
    beginRun(run)
    okT, tp = T.control(1, { control = 'teleport' })
    H.eq(tp.target, 'objective', 'defaults to the objective in progress')
    H.eq(tp.coords.y, 222.0, 'CP.Runs.anchor coords')
    okT, tp = T.control(1, { control = 'teleport', target = 'start' })
    H.eq(tp.coords.z, 30.0, 'explicit start')
    okT, tp = T.control(1, { control = 'teleport', target = 'roof' })
    H.eq(tp, 'err.invalid_payload', 'bad teleport target')
    arena[1] = true
    okT, tp = T.control(1, { control = 'teleport' })
    H.eq(tp, 'err.in_arena', 'Crimson-Arena rule 13: no teleport for an in-arena admin')
    arena[1] = nil
    Config.Testing.allowTeleport = false
    okT, tp = T.control(1, { control = 'teleport' })
    H.eq(tp, 'err.test_teleport_disabled', 'allowTeleport = false')
    Config.Testing.allowTeleport = true

    okC = T.control(1, { control = 'skip' })
    H.eq(okC, true, 'skip')
    H.eq(lastCall('testSkip').args[1], run, 'CP.Runs.testSkip')
    okC = T.control(1, { control = 'restart' })
    H.eq(lastCall('testRestart').args[1], run, 'CP.Runs.testRestart')
    local okP, p = T.control(1, { control = 'pause' })
    H.eq(p.paused, true, 'paused')
    H.eq(lastCall('pauseTimer').args[2], true, 'CP.Runs.pauseTimer(run, true)')
    okP, p = T.control(1, { control = 'resume' })
    H.eq(lastCall('pauseTimer').args[2], false, 'resume')

    -- debug stream
    Config.Testing.debugOverlay = false
    local okD, d = T.control(1, { control = 'debug' })
    H.eq(d, 'err.test_debug_disabled', 'debugOverlay = false')
    Config.Testing.debugOverlay = true
    H.reset()
    okD, d = T.control(1, { control = 'debug' })
    H.eq(d.debug, true, 'debug toggled on')
    local dbg = lastEvent('client:test').args[1].debug
    H.ok(type(dbg) == 'table', 'debug payload sent to the admin')
    H.eq(dbg.counts.entities, 5, 'entity count')
    H.eq(dbg.counts.armedAlive, 1, 'armed alive excludes the dead')
    H.eq(dbg.counts.dead, 1, 'dead count')
    H.eq(dbg.counts.maxArmedAlive, 25, 'cap from Config.Limits.maxArmedAlive')
    H.eq(dbg.counts.maxEntities, 80, 'cap from Config.Limits.maxEntities')
    H.eq(dbg.objective.index, 2, 'current objective (after the skip)')
    H.eq(dbg.objective.block, 'checkpoint_route', 'its block')
    H.ok(type(dbg.geometry) == 'table', 'geometry on the first send')
    H.eq(dbg.startRadius, 80.0, 'start radius')
    H.reset()
    H.advance(2100)
    local list = events('client:test')
    H.ok(#list >= 1, 'the debug stream sends every 2 s')
    H.eq(list[#list].args[1].debug.geometry, nil, 'geometry only when it changed')
    Config.Limits.maxArmedAlive = 30
    H.advance(2100)
    list = events('client:test')
    H.eq(list[#list].args[1].debug.counts.maxArmedAlive, 30, 'caps are read from Config at call time')
    Config.Limits.maxArmedAlive = 25
    okD, d = T.control(1, { control = 'debug', enabled = false })
    H.eq(d.debug, false, 'debug off')
    H.eq(lastEvent('client:test').args[1].debug, false, 'the client is told')
    H.reset()
    H.advance(2100)
    H.eq(#events('client:test'), 0, 'no stream while off')

    -- the geometry itself
    local g = T._geometry(run)
    local byKey = {}
    for _, pt in ipairs(g.points) do byKey[pt.key] = (byKey[pt.key] or 0) + 1 end
    H.eq(byKey.spawns, 2, 'spawn points (vec4 list)')
    H.eq(byKey.checkpoints, 2, 'checkpoint points')
    H.eq(byKey.npcs, 1, 'points given as { coords }')
    H.eq(byKey.safe, 1, 'a single vec3')
    H.eq(byKey.medals, nil, 'medals are not points')
    local routes = {}
    for _, r in ipairs(g.routes) do routes[r.key] = r end
    H.ok(routes.route and #routes.route.points == 3 and routes.route.loop == true, 'road route { points, loop }')
    H.ok(routes.checkpoints ~= nil, 'a list referenced as checkpoints is also drawn as a route')
    H.ok(routes['flee#1'] and routes['flee#2'], 'list of lists = routes')
    local cp
    for _, pt in ipairs(g.points) do if pt.key == 'checkpoints' then cp = pt end end
    H.eq(cp.r, 12.0, 'checkpoint radius of the current objective')
    H.eq(g.start.r, 80.0, 'start radius')
    local zones = {}
    for _, z in ipairs(g.zones) do zones[z.label] = z end
    H.ok(zones.presence ~= nil, 'presence zone around the anchor in progress')
    local spawnH
    for _, pt in ipairs(g.points) do if pt.key == 'spawns' and pt.i == 2 then spawnH = pt.h end end
    H.eq(spawnH, 180.0, 'vec4 headings kept')

    -- force complete -> run end hook -> waiting for a result
    H.reset()
    local okE = T.control(1, { control = 'complete' })
    H.eq(okE, true, 'force complete')
    local e = lastCall('endRun')
    H.eq(e.args[2], 'completed', "endRun(run, 'completed', ...)")
    H.eq(e.args[3], 'completed', 'end reason completed')
    local endEv = lastEvent('client:test').args[1]
    H.eq(endEv.controls, false, 'controls off at the end')
    local st = T.state(1)
    H.ok(st.active == false, 'no active test after the end')
    H.eq(#st.pending, 1, 'one test waiting for a result')
    H.eq(st.pending[1].tier, 'major', 'the forced tier')
    H.eq(st.pending[1].testers, 3, 'testers')
    H.eq(st.pending[1].endState, 'completed', 'end state')
    H.eq(lastNotify(1).key, 'test.ended_record', 'the admin is reminded to record it')
end

-- ════════════════════════════════════════════════════════════════════════════
-- recording results (SQL) and the catalog (SQL)
-- ════════════════════════════════════════════════════════════════════════════
do
    local ok, err = T.record(1, { missionId = 'gang_shootout', location = 2, result = 'passed' })
    H.eq(err, 'err.test_not_run', 'no test of that location was run')
    ok, err = T.record(1, { missionId = 'gang_shootout', location = 1, result = 'maybe' })
    H.eq(err, 'err.invalid_payload', 'result passed|failed')
    ok, err = T.record(1, { missionId = 'gang_shootout', location = 1, result = 'passed', tier = 'heavy' })
    H.eq(err, 'err.test_not_run', 'a tier that was not tested')
    ok, err = T.record(2, { missionId = 'gang_shootout', location = 1, result = 'passed' })
    H.eq(err, 'err.test_not_run', 'another player has no pending test')
    ok, err = T.record(1, { missionId = 'gang_shootout', location = 1, result = 'passed', note = 42 })
    H.eq(err, 'err.invalid_payload', 'note must be text')

    local long = string.rep('é', 300)
    local okR, data = T.record(1, { missionId = 'gang_shootout', location = 1, tier = 'major', result = 'failed', note = '  ' .. long .. '  ' })
    H.eq(okR, true, 'recorded')
    if not okR then
        realPrint('record error: ' .. tostring(data))
        for _, l in ipairs(logs) do if l:find('testing', 1, true) and l:find('fail', 1, true) then realPrint(l) end end
    end
    H.eq(data.result, 'failed', 'result')
    local rows = H.sql('SELECT mission_id, mission_version, location_index, tier, testers, result, CHAR_LENGTH(note) AS n, tested_by, def_hash FROM cp_mission_tests')
    local stored = H.sql('SELECT note FROM cp_mission_tests')[1].note
    H.eq(#rows, 1, 'one cp_mission_tests row')
    H.eq(rows[1].mission_id, 'gang_shootout', 'mission_id')
    H.eq(rows[1].mission_version, nil, 'built-in: no version')
    H.eq(rows[1].location_index, 1, 'location_index')
    H.eq(rows[1].tier, 'major', 'tier')
    H.eq(rows[1].testers, 3, 'testers')
    H.eq(rows[1].result, 'failed', 'result')
    H.ok(rows[1].n <= 255, 'the note fits VARCHAR(255)')
    H.ok(utf8.len(stored) ~= nil and #stored <= 255 and #stored >= 250, 'clipped to 255 bytes on a character boundary (' .. #stored .. ')')
    H.eq(rows[1].tested_by, 'ADM00001', 'tested_by = the admin citizenid')
    H.eq(rows[1].def_hash, 'aaaa1111', 'def_hash = the mission defHash (migration 002)')
    local a = audits[#audits]
    H.eq(a[4], 'recordTest', 'recording is audited')
    local w = webhooks[#webhooks]
    H.eq(w[1], 'builder', 'posted to the builder webhook')
    ok, err = T.record(1, { missionId = 'gang_shootout', location = 1, result = 'passed' })
    H.eq(err, 'err.test_not_run', 'a result is recorded once')

    -- catalog
    local view = T.list()
    local byId = {}
    for _, m in ipairs(view.missions) do byId[m.id] = m end
    local g = byId.gang_shootout
    H.eq(g.locations[1].status, 'failed', 'last result of location 1')
    H.eq(g.locations[1].last.testedByName, 'Alex Mercer', 'tester name (online lookup when no cp_officers row)')
    H.eq(g.locations[1].last.tier, 'major', 'tier of the last test')
    H.ok(type(g.locations[1].last.testedAt) == 'number' and g.locations[1].last.testedAt > 0, 'when (unix seconds)')
    H.eq(g.locations[1].last.changed, false, 'same def hash: not changed')
    H.eq(g.locations[2].status, 'untested', 'location 2 not tested')
    H.eq(g.locations[2].reserved, true, 'reserved flag')
    H.eq(g.maxTier, 'heavy', 'maxTier = tierFor(maxOfficers = 4)')
    H.eq(byId.prison_break.disabled, true, 'Config.DisabledMissions still listed')
    H.eq(view.totals.failed, 1, 'totals')
    H.eq(view.totals.missions, 4, 'every mission')
    H.eq(view.totals.locations, 12, 'every location')
    H.eq(view.missions[1].type, 'patrol', 'sorted by type points')
    -- hand-inserted rows: a newer passed row by an officer, a custom mission with an older version
    H.sql([[INSERT INTO cp_mission_tests (mission_id, mission_version, location_index, tier, testers, result, note, tested_by, def_hash)
        VALUES ('gang_shootout', NULL, 1, 'heavy', 2, 'passed', NULL, 'OFF00002', 'aaaa1111'),
               ('custom_dockside', 2, 1, 'reinforced', 1, 'passed', 'ok', 'OFF00002', 'cccc3333'),
               ('beat_patrol', NULL, 3, 'reinforced', 2, 'passed', NULL, 'OFF00002', NULL)]])
    view = T.list()
    byId = {}
    for _, m in ipairs(view.missions) do byId[m.id] = m end
    H.eq(byId.gang_shootout.locations[1].status, 'passed', 'the newest row wins')
    H.eq(byId.gang_shootout.locations[1].last.tests, 2, 'tests counted per location')
    H.eq(byId.gang_shootout.locations[1].last.testedByName, 'John Doe', 'display_name from cp_officers')
    H.eq(byId.custom_dockside.locations[1].status, 'changed', 'custom: another version tested = Changed since test')
    H.eq(byId.beat_patrol.locations[3].status, 'changed', 'no def_hash recorded = Changed since test')
    defs.gang_shootout.defHash = 'eeee5555'
    view = T.list()
    byId = {}
    for _, m in ipairs(view.missions) do byId[m.id] = m end
    H.eq(byId.gang_shootout.locations[1].status, 'changed', 'edited/reloaded mission (new defHash) = Changed since test')
    defs.gang_shootout.defHash = 'aaaa1111'

    -- archived custom missions come from the builder
    CP.Builder.archivedDefs = function()
        return { mission('custom_harbor', { label = 'Harbor Sweep', source = 'custom', version = 1, defHash = 'ffff6666', status = 'archived' }) }
    end
    view = T.list()
    byId = {}
    for _, m in ipairs(view.missions) do byId[m.id] = m end
    H.eq(byId.custom_harbor.status, 'archived', 'archived missions are in the catalog')
    CP.Builder.getArchived = function(id)
        if id == 'custom_harbor' then return mission('custom_harbor', { label = 'Harbor Sweep', source = 'custom', version = 1, defHash = 'ffff6666' }) end
    end

    -- callbacks and actions through CP.Net
    local res = H.callback('crimson-police:admin:getTests', 2, {})
    H.eq(res.ok, false, 'admin:getTests needs testRun')
    H.eq(res.error, 'err.no_permission', 'no permission')
    res = H.callback('crimson-police:admin:getTests', 1, {})
    H.eq(res.ok, true, 'admin:getTests for an admin')
    res = H.callback('crimson-police:test:pendingInvites', 2, {})
    H.eq(res.ok, true, 'test:pendingInvites for anyone')
    res = H.callback('crimson-police:test:state', 1, {})
    H.eq(res.ok, true, 'test:state')
end

-- ════════════════════════════════════════════════════════════════════════════
-- archived mission start, random location, command, end/fail controls
-- ════════════════════════════════════════════════════════════════════════════
do
    H.clockMs = H.clockMs + 5000
    local ok, data = T.start(1, { missionId = 'custom_harbor', location = 'random' })
    H.eq(ok, true, 'an archived custom mission can be tested')
    H.ok(data.locationIndex >= 1 and data.locationIndex <= 3, 'random location')
    local r = runs[data.runId]
    H.eq(r.test.forcedTier, nil, 'no tier chosen: natural scaling')
    local okE = T.control(1, { control = 'end' })
    H.eq(okE, true, 'end test')
    H.eq(lastCall('failRun').args[2], 'test.ended_by_admin', 'ends with a failReason the HUD shows')
    local st = T.state(1)
    H.eq(st.pending[1].endedBy, 'end', 'ended by the admin')

    H.clockMs = H.clockMs + 5000
    reserved['beat_patrol#1'] = true
    reserved['beat_patrol#2'] = true
    ok, data = T.start(1, { missionId = 'beat_patrol', location = 'random' })
    H.eq(data.locationIndex, 3, 'random skips reserved locations')
    T.control(1, { control = 'fail' })
    H.eq(lastCall('failRun').args[2], 'test.fail_forced', 'force fail')
    reserved['beat_patrol#3'] = true
    H.clockMs = H.clockMs + 5000
    ok, data = T.start(1, { missionId = 'beat_patrol', location = 'random' })
    H.eq(data, 'err.no_location', 'every location reserved')
    reserved = {}

    -- the command
    H.clockMs = H.clockMs + 5000
    local okC, errC = T.command(1, { 'gang_shootout', 'bogus' })
    H.eq(errC, 'err.test_bad_command', 'bad command argument')
    okC, errC = T.command(1, { 'gang_shootout', 'heavy', 'critical' })
    H.eq(errC, 'err.test_bad_command', 'two tiers')
    okC, data = T.command(1, { 'gang_shootout', '3', 'Heavy' })
    H.eq(okC, true, 'test <missionId> <location> <tier>')
    H.eq(data.locationIndex, 3, 'location from the command')
    H.eq(data.tier, 'heavy', 'tier from the command')
    H.eq(created[#created].test.useStartRoute, Config.Testing.useStartRoute, 'start route default from Config.Testing')

    -- the admin leaves: the test ends for the testers
    H.fire('playerDropped', 1)
    H.step(10)
    H.eq(lastCall('failRun').args[2], 'test.ended_admin_left', 'the test ends when its admin leaves')
    H.ok(T.state(1).active == false, 'no active test left')
end

-- ════════════════════════════════════════════════════════════════════════════
-- draft tests (Mission Builder)
-- ════════════════════════════════════════════════════════════════════════════
do
    H.clockMs = H.clockMs + 5000
    local raw = mission('custom_draft', { label = 'Draft Raid', version = 4 })
    raw.source, raw.defHash, raw.status, raw.isBoss = nil, nil, nil, nil
    local ok, err = T.startDraft(2, raw, { tier = 'heavy' })
    H.eq(err, 'err.no_permission', 'an officer without builderEdit cannot test drafts')
    ok, err = T.startDraft(6, { id = 'custom_bad', broken = true, locations = {} }, {})
    H.eq(err, 'err.test_invalid_draft', 'a draft that does not normalise')
    ok, err = T.startDraft(6, raw, { tier = 'heavy', location = 2 })
    H.eq(ok, true, 'a supervisor with builderEdit tests a draft')
    local opts = created[#created]
    H.eq(opts.test.draft, true, 'test.draft = true')
    H.eq(opts.members[1].job, 'sast', 'the on-duty supervisor keeps their officer record')
    H.eq(normalized[#normalized].meta.status, 'draft', 'normalised as a draft')
    local r = runs[err.runId]
    beginRun(r)
    T.control(6, { control = 'complete' })
    local okR = T.record(6, { missionId = 'custom_draft', location = 2, result = 'passed', note = 'good' })
    H.eq(okR, true, 'the builder records the draft result')
    local d = drafted[#drafted]
    H.eq(d[1], 'custom_draft', 'CP.Builder.onDraftTested(missionId')
    H.eq(d[2], 4, 'version')
    H.eq(d[3], 'heavy', 'tierName')
    H.eq(d[4], true, 'passed')
    H.eq(d[5], 6, 'src)')
    local rows = H.sql("SELECT mission_version, tier, def_hash FROM cp_mission_tests WHERE mission_id = 'custom_draft'")
    H.eq(rows[1].mission_version, 4, 'draft version stored')
    H.eq(rows[1].def_hash, 'draft0001', 'draft hash stored')
end

-- ════════════════════════════════════════════════════════════════════════════
-- invitation expiry and actions through CP.Net
-- ════════════════════════════════════════════════════════════════════════════
do
    offline[1] = nil
    H.clockMs = H.clockMs + 5000
    local ok, res = T.invite(3, { 2 }, { missionId = 'gang_shootout' })
    H.eq(#res.lobby.invites, 1, 'invited')
    H.time = H.time + 121
    H.eq(#T.pendingInvites(2), 0, 'an unanswered invitation expires after 120 s')
    local st = T.state(3)
    H.eq(st.lobby.invites[1].status, 'expired', 'shown as expired in the lobby')

    -- integration: a draft invitation's label (from the Mission Builder) is clipped on a UTF-8 boundary
    local longLabel = string.rep('é', 40)   -- 40 characters, 80 bytes
    local okD, resD = T.invite(3, { 2 }, { missionId = 'my_draft', missionLabel = longLabel, draft = true })
    H.eq(okD, true, 'draft invitation')
    local lbl = resD and resD.lobby and resD.lobby.missionLabel or ''
    H.ok(utf8.len(lbl) ~= nil, 'the draft label stays valid UTF-8')
    H.eq(#lbl, 64, 'clipped to 64 bytes (32 whole characters)')
    local lastInviteEv = lastEvent('client:testInvite')
    H.ok(lastInviteEv and utf8.len(lastInviteEv.args[1].missionLabel) ~= nil, 'the invite event carries valid UTF-8')
    T.cancelInvites(3)

    -- integration: CP.Testing.resolveMission is public (/CrimsonPoliceAdmin test resolves archived missions with it)
    H.ok(type(T.resolveMission) == 'function', 'CP.Testing.resolveMission is exposed')
    H.eq(T.resolveMission('gang_shootout') and T.resolveMission('gang_shootout').id, 'gang_shootout', 'resolves a loaded mission')
    local noDef, noErr = T.resolveMission('no_such_mission')
    H.eq(noDef, nil, 'unknown mission')
    H.eq(noErr, 'err.test_unknown_mission', 'with its error key')

    -- the net action path (permission wrappers and reply events)
    H.reset()
    H.fire('crimson-police:server:test:invite', 2, { missionId = 'gang_shootout', targets = { 5 } }, 'r1')
    local reply = lastEvent('client:actionResult')
    H.eq(reply.args[2], false, 'server:test:invite needs testRun')
    H.eq(reply.args[3], 'err.no_permission', 'no permission')
    H.fire('crimson-police:server:testRespond', 5, { inviteId = 'x', accepted = true }, 'r2')
    reply = lastEvent('client:actionResult')
    H.eq(reply.args[3], 'err.test_invite_gone', 'server:testRespond with an unknown invitation')
    H.fire('crimson-police:server:admin:startTest', 2, { missionId = 'gang_shootout' }, 'r3')
    reply = lastEvent('client:actionResult')
    H.eq(reply.args[3], 'err.no_permission', 'server:admin:startTest needs testRun')
    H.fire('crimson-police:server:test:control', 5, { control = 'end' }, 'r4')
    reply = lastEvent('client:actionResult')
    H.eq(reply.args[3], 'err.test_no_active', 'server:test:control only for the starter')
    H.fire('crimson-police:server:admin:recordTest', 1, { missionId = 'gang_shootout', location = 1, result = 'passed' }, 'r5')
    reply = lastEvent('client:actionResult')
    H.eq(reply.args[3], 'err.test_not_run', 'server:admin:recordTest')
    H.fire('crimson-police:server:test:cancelInvites', 3, {}, 'r6')
    reply = lastEvent('client:actionResult')
    H.eq(reply.args[2], true, 'server:test:cancelInvites')
end

-- ════════════════════════════════════════════════════════════════════════════
-- locale: every key the slice uses exists in locales/parts/testing.json
-- ════════════════════════════════════════════════════════════════════════════
do
    local f = assert(io.open(H.root .. 'locales/parts/testing.json', 'r'))
    local part = json.decode(f:read('a'))
    f:close()
    local missing = {}
    for _, file in ipairs({ 'modules/testing/server.lua', 'modules/testing/client.lua' }) do
        local fh = assert(io.open(H.root .. file, 'r'))
        local src = fh:read('a')
        fh:close()
        for key in src:gmatch("'((%a+)%.[%w_%.]+)'") do
            local ns = key:match('^(%a+)%.')
            if (ns == 'err' or ns == 'test') and part[key] == nil then missing[#missing + 1] = key end
        end
    end
    H.eq(#missing, 0, 'locale keys used in Lua: ' .. table.concat(missing, ', '))
end

-- ════════════════════════════════════════════════════════════════════════════
-- integration with the REAL run engine (modules/runs/server.lua): the contract calls CP.Testing makes
-- (create with an admin record, testSkip/testRestart/pauseTimer/anchor/endRun/failRun, entitiesFor,
-- remaining) and the onRunEnded hook, with nothing written to cp_mission_runs
-- ════════════════════════════════════════════════════════════════════════════
do
    T._reset()
    for s in pairs(onRun) do onRun[s] = nil end
    for s in pairs(offline) do offline[s] = nil end
    for k in pairs(reserved) do reserved[k] = nil end
    local reservations = {}
    CP.Route = { begin = function() end, stop = function() end }
    CP.Draw.reserve = function(runId, missionId, index)
        reservations[runId] = missionId .. '#' .. index
        reserved[missionId .. '#' .. index] = true
        return true
    end
    CP.Draw.release = function(runId)
        if reservations[runId] then reserved[reservations[runId]] = nil end
        reservations[runId] = nil
        return true
    end
    CP.Alerts.set = function() return true end
    CP.Alerts.clear = function() return true end
    CP.Payouts = { baseFor = function() return 800 end }
    CP.Scoring = {
        P = function() return 200 end,
        compute = function(_, _, result, opts)
            return { P = 200, bonuses = {}, penalties = {}, subtotal = 200, mTeam = 1, mCross = 1, mStreak = 1,
                capped = false, tod = false, failedShare = opts.failedShare, final = result == 'completed' and 200 or 0 }
        end,
    }
    CP.Cash = { compute = function() return 800, { B = 800, mTier = 1.0, mMod = 1.0, amount = 800 } end }
    H.sql('DELETE FROM cp_mission_runs')
    CP.Runs = nil
    H.load('modules/runs/server.lua')
    local R = CP.Runs
    H.clockMs = H.clockMs + 5000
    H.reset()

    -- an invited on-duty officer (2) and the non-police admin (1)
    local okI, inv = T.invite(1, { 2 }, { missionId = 'gang_shootout' })
    H.eq(okI, true, 'real engine: invite')
    local okA = T.respond(2, { inviteId = inv.lobby.invites[1].inviteId, accepted = true })
    H.eq(okA, true, 'real engine: accepted')
    local ok, data = T.start(1, { missionId = 'gang_shootout', location = 1, tier = 'heavy', testers = { 2 } })
    H.eq(ok, true, 'real engine: CP.Runs.create accepts the test (admin record + officer)')
    local run = ok and R.get(data.runId) or nil
    H.ok(run ~= nil, 'real engine: the run exists')
    if run then
        H.eq(run.participants[1].isOfficer, false, 'real engine: the non-police admin is not an officer (no duty re-checks)')
        H.eq(run.participants[2].isOfficer, true, 'real engine: the tester is an officer')
        H.eq(run.expectedTier, 'heavy', 'real engine: the forced tier whatever the number of testers')
        H.eq(run.test.adminSrc, 1, 'real engine: test.adminSrc')
        H.eq(run.test.useStartRoute, false, 'real engine: the start route is off by default')
        H.eq(reserved['gang_shootout#1'], true, 'real engine: the test still reserves its location')
        H.eq(run.modifier, nil, 'real engine: no modifier on a test')
        local starts = eventsTo('client:start', 2)
        H.eq(#starts, 1, 'real engine: client:start to the tester')
        H.eq(starts[1] and starts[1].args[2].test.adminSrc, 1, 'real engine: the tester sees the test table')

        -- Accepted: the time controls wait for In progress; teleport goes to the start
        local okT, tp = T.control(1, { control = 'teleport', target = 'objective' })
        H.eq(okT, true, 'real engine: teleport before In progress')
        H.eq(tp.coords.x, 100.0, 'real engine: CP.Runs.anchor = the start before In progress')
        local okP, errP = T.control(1, { control = 'pause' })
        H.eq(errP, 'err.test_not_in_progress', 'real engine: no timer to pause yet')

        R.markArrived(run, 1)
        H.eq(run.state, 'in_progress', 'real engine: the first arrival starts the objectives')
        H.eq(run.tier and run.tier.tier, 'heavy', 'real engine: forced tier at In progress')
        okP = T.control(1, { control = 'pause' })
        H.eq(okP, true, 'real engine: pause')
        H.eq(run.timer.paused, true, 'real engine: CP.Runs.pauseTimer paused the timer')
        T.control(1, { control = 'resume' })
        H.eq(run.timer.paused, false, 'real engine: resume')
        local okS = T.control(1, { control = 'skip' })
        H.eq(okS, true, 'real engine: skip')
        H.eq(run.objectiveIndex, 2, 'real engine: CP.Runs.testSkip started objective 2')
        local okR = T.control(1, { control = 'restart' })
        H.eq(okR, true, 'real engine: restart')
        okT, tp = T.control(1, { control = 'teleport', target = 'objective' })
        H.eq(tp.coords.x, 1.0, 'real engine: CP.Runs.anchor = the current objective (checkpoint 1)')
        H.reset()
        local okD = T.control(1, { control = 'debug' })
        H.eq(okD, true, 'real engine: debug on')
        local dbg = lastEvent('client:test')
        dbg = dbg and dbg.args[1].debug
        H.ok(type(dbg) == 'table' and dbg.counts.entities == 0, 'real engine: counts from CP.Runs.entitiesFor')
        H.ok(type(dbg) == 'table' and type(dbg.remaining) == 'number', 'real engine: timer from CP.Runs.remaining')
        H.eq(type(dbg) == 'table' and dbg.objective.index, 2, 'real engine: current objective in the debug data')

        -- force complete: the result screen shows what the run would have earned, nothing is written
        H.reset()
        local okC = T.control(1, { control = 'complete' })
        H.eq(okC, true, 'real engine: force complete')
        H.eq(R.get(data.runId), nil, 'real engine: the run is gone')
        H.eq(reserved['gang_shootout#1'], nil, 'real engine: the location is released')
        local ended = eventsTo('client:runEnded', 2)
        local rr = ended[1] and ended[1].args[4]
        H.eq(ended[1] and ended[1].args[2], 'completed', 'real engine: completed for the tester')
        H.ok(type(rr) == 'table' and rr.test == true, 'real engine: the RunResult is marked test')
        H.eq(type(rr) == 'table' and rr.cash.amount, 800, 'real engine: the cash it would have earned is shown')
        H.eq(type(rr) == 'table' and rr.points.final, 200, 'real engine: the points it would have earned are shown')
        H.eq(tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n), 0, 'real engine: no cp_mission_runs row')
        local st = T.state(1)
        H.ok(st.active == false, 'real engine: no active test after the end (onRunEnded hook)')
        H.eq(st.pending[1] and st.pending[1].endState, 'completed', 'real engine: waiting for a result')
        H.eq(st.pending[1] and st.pending[1].tier, 'heavy', 'real engine: recorded tier')
        local okRec = T.record(1, { missionId = 'gang_shootout', location = 1, tier = 'heavy', result = 'passed' })
        H.eq(okRec, true, 'real engine: the result is recorded')
        local cd = R.cooldowns('OFF00002')
        H.eq(next(cd.missions or {}), nil, 'real engine: a test starts no mission cooldown')
        H.eq(next(cd.types or {}), nil, 'real engine: a test starts no type cooldown')
    end

    -- End test: failRun with its reason, for everyone
    H.clockMs = H.clockMs + 5000
    H.reset()
    ok, data = T.start(1, { missionId = 'beat_patrol', location = 2 })
    H.eq(ok, true, 'real engine: solo test')
    run = ok and R.get(data.runId) or nil
    if run then
        H.eq(run.expectedTier, 'standard', 'real engine: Auto tier = the tier for one tester')
        local okE = T.control(1, { control = 'end' })
        H.eq(okE, true, 'real engine: End test')
        local ended = eventsTo('client:runEnded', 1)
        local e = ended[#ended]
        H.eq(e and e.args[3], 'mission_failed', 'real engine: ended as mission_failed')
        H.eq(e and e.args[4] and e.args[4].failReason, 'test.ended_by_admin', 'real engine: with the End test reason')
        H.eq(R.get(data.runId), nil, 'real engine: cleaned up')
        H.eq(T.state(1).pending[1].endedBy, 'end', 'real engine: pending entry says who ended it')
    end

    -- the admin abandons alone: the engine ends the run, the hook still fires
    H.clockMs = H.clockMs + 5000
    ok, data = T.start(1, { missionId = 'gang_shootout', location = 3 })
    run = ok and R.get(data.runId) or nil
    if run then
        R.removeParticipant(run, 1, 'quit')
        H.eq(R.get(data.runId), nil, 'real engine: abandoned by the only tester')
        local st = T.state(1)
        H.ok(st.active == false, 'real engine: no stale active test after an abandon')
        H.eq(st.pending[1].endState, 'abandoned', 'real engine: abandoned test waits for a result')
    end

    -- archived custom missions without the builder hooks: cp_custom_missions rows + the archived file
    CP.Builder.archivedDefs, CP.Builder.getArchived = nil, nil
    H.sql("DELETE FROM cp_custom_missions WHERE id IN ('custom_arch', 'custom_live')")
    H.sql([[INSERT INTO cp_custom_missions (id, mission_type, status, published_version, file_path, created_by, updated_by)
        VALUES ('custom_arch', 'tactical', 'archived', 5, 'missions/custom/archived/custom_arch.lua', 'SUP00006', 'SUP00006'),
               ('custom_live', 'tactical', 'published', 2, 'missions/custom/custom_live.lua', 'SUP00006', 'SUP00006')]])
    local ARCH_FILE = "RegisterMission({ id = 'custom_arch', label = 'Archived Raid' })"
    local realLoad = LoadResourceFile
    local parsed = 0
    _G.LoadResourceFile = function(res, path)
        if path == 'missions/custom/archived/custom_arch.lua' then return ARCH_FILE end
        return realLoad(res, path)
    end
    CP.Missions.parse = function(content, chunk)
        parsed = parsed + 1
        if content ~= ARCH_FILE then return nil, 'unexpected file' end
        local d = mission('custom_arch', { label = 'Archived Raid' })
        d.source, d.defHash, d.status, d.isBoss = nil, nil, nil, nil
        return d
    end
    local view = T.list()
    local arch
    for _, m in ipairs(view.missions) do if m.id == 'custom_arch' then arch = m end end
    H.ok(arch ~= nil, 'archived mission listed from cp_custom_missions + its archived file')
    H.eq(arch and arch.status, 'archived', 'status archived')
    H.eq(arch and arch.version, 5, 'version from the published_version column')
    H.eq(arch and arch.source, 'custom', 'a custom mission')
    local n = parsed
    T.list()
    H.eq(parsed, n, 'an unchanged archived file is not parsed again')
    H.clockMs = H.clockMs + 5000
    ok, data = T.start(1, { missionId = 'custom_arch', location = 1 })
    H.eq(ok, true, 'an archived custom mission can be started without the builder hook')
    run = ok and R.get(data.runId) or nil
    H.eq(run and run.version, 5, 'the run carries the archived version')
    if run then T.control(1, { control = 'end' }) end
    local okRec = T.record(1, { missionId = 'custom_arch', location = 1, result = 'failed', note = 'spawn 3 is inside a wall' })
    H.eq(okRec, true, 'archived test recorded')
    local row = H.sql("SELECT mission_version, def_hash FROM cp_mission_tests WHERE mission_id = 'custom_arch'")[1]
    H.eq(row and row.mission_version, 5, 'mission_version of the archived mission')
    H.eq(row and row.def_hash, CP.U.hashHex(ARCH_FILE), 'def_hash = hash of the archived file')
    _G.LoadResourceFile = realLoad

    -- test:state is the caller's own data: admins and Mission Builder users (draft tests)
    local res = H.callback('crimson-police:test:state', 6, {})
    H.eq(res.ok, true, 'test:state for a supervisor with builderEdit (their draft tests)')
    res = H.callback('crimson-police:test:state', 2, {})
    H.eq(res.error, 'err.no_permission', 'test:state refused for an officer')
    CP.Runs = R
end

print = realPrint

-- ════════════════════════════════════════════════════════════════════════════
-- client side
-- ════════════════════════════════════════════════════════════════════════════
H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })
Config.Debug = true

local focus, keymaps, bagHandlers = {}, {}, {}
_G.SetNuiFocus = function(a, b) focus[#focus + 1] = { a, b } end
_G.RegisterKeyMapping = function(cmd, desc, dev, key) keymaps[#keymaps + 1] = { cmd = cmd, desc = desc, dev = dev, key = key } end
_G.GetPlayerServerId = function() return 1 end
_G.PlayerId = function() return 0 end
_G.AddStateBagChangeHandler = function(key, bag, fn) bagHandlers[#bagHandlers + 1] = { key = key, bag = bag, fn = fn } end
_G.LocalPlayer = { state = {} }
_G.PlayerPedId = function() return 100 end
_G.GetControlInstructionalButton = function() return 't_F7' end
local moved, frozen, fades = {}, {}, {}
_G.GetVehiclePedIsIn = function() return 0 end
_G.GetPedInVehicleSeat = function() return 0 end
_G.DoScreenFadeOut = function() fades[#fades + 1] = 'out' end
_G.DoScreenFadeIn = function() fades[#fades + 1] = 'in' end
_G.IsScreenFadedOut = function() return true end
_G.FreezeEntityPosition = function(e, on) frozen[#frozen + 1] = on end
_G.SetEntityCoords = function(e, x, y, z) moved[#moved + 1] = { e = e, x = x, y = y, z = z } end
_G.RequestCollisionAtCoord = function() end
_G.GetGroundZFor_3dCoord = function(x, y, z) return true, 29.5 end
local markers = 0
_G.DrawMarker = function() markers = markers + 1 end
_G.DrawLine = function() end
for _, n in ipairs({ 'SetTextScale', 'SetTextFont', 'SetTextProportional', 'SetTextColour', 'SetTextOutline', 'SetTextCentre',
    'SetDrawOrigin', 'BeginTextCommandDisplayText', 'AddTextComponentSubstringPlayerName', 'EndTextCommandDisplayText', 'ClearDrawOrigin' }) do
    _G[n] = function() end
end

-- Translate with this slice's locale part (locales/en.json is only merged at release).
do
    local fh = assert(io.open(H.root .. 'locales/parts/testing.json', 'r'))
    local strings = json.decode(fh:read('a'))
    fh:close()
    local realL = CP.L
    CP.L = function(key, vars)
        local text = strings[key]
        if text == nil then return realL(key, vars) end
        return (text:gsub('{([%w_]+)}', function(k)
            local v = vars and vars[k]
            if v == nil then return '{' .. k .. '}' end
            return tostring(v)
        end))
    end
end

local tabletOpen = false
local hudPatches, nuiPushes, toasts, clientActions = {}, {}, {}, {}
CP.Tablet = {
    isOpen = function() return tabletOpen end,
    hud = function(p) hudPatches[#hudPatches + 1] = p end,
    push = function(topic, data) nuiPushes[#nuiPushes + 1] = { topic = topic, data = data } end,
    notify = function(kind, text, opts) toasts[#toasts + 1] = { kind = kind, text = text, opts = opts } end,
    registerClientAction = function(name, fn) clientActions[name] = fn end,
}
local currentRun = nil
CP.Runs = { current = function() return currentRun end }

H.load('modules/testing/client.lua')
local serverReplies = {}
local sent = {}
CP.Net.action = function(name, payload)
    sent[#sent + 1] = { name = name, payload = payload }
    local r = serverReplies[payload and payload.control or name]
    if type(r) == 'function' then return r(payload) end
    return r or { ok = true, data = {} }
end
CP.Net.request = function(name) if name == 'test:pendingInvites' then return { ok = true, data = serverReplies.invites or {} } end return { ok = false } end

local CT = CP.Testing
local st = CT._state()
local function lastPush()
    return nuiPushes[#nuiPushes]
end

do
    H.eq(keymaps[1].cmd, '+crimsonpolice_testpanel', 'key mapping +crimsonpolice_testpanel')
    H.eq(keymaps[1].key, 'F9', 'default key F9')
    H.ok(H.commands['+crimsonpolice_testpanel'] ~= nil and H.commands['-crimsonpolice_testpanel'] ~= nil, 'both +/- commands registered')
    for _, n in ipairs({ 'testControl', 'teleport', 'toggleDebug', 'testPanel' }) do
        H.ok(clientActions[n] ~= nil, 'client action ' .. n)
    end

    -- no controls: F9 opens the invitation prompt only with invitations waiting
    H.commands['+crimsonpolice_testpanel'].fn()
    H.eq(#focus, 0, 'no invitations: no focus')
    H.eq(toasts[#toasts].text, CP.L('test.no_invites'), 'told there is nothing')
    serverReplies.invites = { { inviteId = 'ti1', missionLabel = 'Gang Shootout', from = 'Alex', expiresIn = 90 } }
    H.commands['+crimsonpolice_testpanel'].fn()
    H.eq(focus[#focus][1], true, 'prompt takes NUI focus')
    H.eq(lastPush().data.prompt.invites[1].inviteId, 'ti1', 'prompt pushed to the NUI')
    clientActions.testPanel({ open = false })
    H.eq(focus[#focus][1], false, 'released on close')
    H.eq(lastPush().data.prompt, false, 'prompt hidden')

    -- the invitation toast
    H.fire('crimson-police:client:testInvite', 1, { inviteId = 'ti2', missionLabel = 'Bomb Disposal', from = 'Sam' })
    H.ok(toasts[#toasts].text:find('Bomb Disposal', 1, true) ~= nil, 'invitation toast names the mission')
    H.ok(toasts[#toasts].text:find('F7', 1, true) ~= nil, 'and the bound key')

    -- controls for my test
    currentRun = { id = 'run-9' }
    H.fire('crimson-police:client:test', 1, { controls = true, runId = 'run-9', debug = false })
    H.eq(st.controls, true, 'controls on')
    H.step(0)
    H.eq(hudPatches[#hudPatches].testControls, true, 'HUD flag testControls on the run HUD')
    local before = #focus
    tabletOpen = true
    H.commands['+crimsonpolice_testpanel'].fn()
    H.eq(#focus, before, 'no focus change while the tablet is open')
    tabletOpen = false
    H.commands['+crimsonpolice_testpanel'].fn()
    H.eq(focus[#focus][1], true, 'F9 focuses the panel')
    H.eq(lastPush().data.focused, true, 'the panel knows it is focused')
    H.eq(lastPush().data.key, 'F7', 'with the bound key')
    clientActions.testPanel({ open = false })
    H.eq(focus[#focus][1], false, 'F9/Esc release')

    -- forwarded controls
    local ok = clientActions.testControl({ control = 'skip' })
    H.eq(ok, true, 'testControl forwards')
    H.eq(sent[#sent].name, 'server:test:control', 'to server:test:control')
    H.eq(sent[#sent].payload.runId, 'run-9', 'with the run id')
    local okBad, errBad = clientActions.testControl({ control = 'boom' })
    H.eq(errBad, 'err.invalid_payload', 'unknown control refused locally')

    -- teleport with the Crimson-Arena re-check
    serverReplies.teleport = { ok = true, data = { target = 'start', coords = { x = 1.0, y = 2.0, z = 30.0 } } }
    local okT = clientActions.teleport({ target = 'start' })
    H.eq(okT, true, 'teleport')
    H.eq(moved[#moved].z, 29.5, 'placed on the ground z')
    H.eq(fades[#fades], 'in', 'screen faded back in')
    H.eq(frozen[#frozen], false, 'unfrozen')
    LocalPlayer.state.crimsonArena = { active = true, matchId = 'm1' }
    local n = #sent
    local okA, errA = clientActions.teleport({ target = 'start' })
    H.eq(errA, 'err.in_arena', 'refused while the local crimsonArena value is foreign')
    H.eq(#sent, n, 'the server is not even asked')
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-police' }
    okA = clientActions.teleport({ target = 'objective' })
    H.eq(okA, true, 'our own flag does not block')
    LocalPlayer.state.crimsonArena = nil

    -- debug data: geometry stays in Lua, the NUI gets the counts
    H.fire('crimson-police:client:test', 1, { controls = true, runId = 'run-9', debug = {
        counts = { entities = 3, maxEntities = 80, armedAlive = 1, maxArmedAlive = 25 }, spawnPoints = 2,
        geometry = { start = { x = 0.0, y = 0.0, z = 0.0, r = 50.0 }, points = { { x = 5.0, y = 0.0, z = 0.0, key = 'spawns', i = 1 } }, routes = {}, zones = {} },
    } })
    H.eq(st.debugOn, true, 'debug on')
    H.ok(st.geometry ~= nil, 'geometry kept')
    H.eq(lastPush().data.debug.geometry, nil, 'no geometry sent to the NUI')
    H.eq(lastPush().data.debug.counts.entities, 3, 'counts sent to the NUI')
    H.near(CT._nearest(st.geometry, 0.0, 0.0, 0.0), -50.0, 1e-6, 'inside the start radius')
    H.advance(50, 10)
    H.ok(markers > 0, 'markers drawn near the test area')

    -- the arena flag closes the panel
    H.commands['+crimsonpolice_testpanel'].fn()
    H.eq(st.focused, true, 'focused again')
    bagHandlers[1].fn('player:1', 'crimsonArena', { active = true, matchId = 'm2' })
    H.step(0)
    H.eq(st.focused, false, 'Crimson-Arena rule 8: a foreign value releases our focus')
    H.eq(st.debugOn, false, 'and stops the overlay')

    -- Config.Testing switches travel with the push (the HUD panel disables those buttons)
    H.ok(lastPush().data.allowTeleport == true and lastPush().data.debugOverlay == true, 'allowTeleport / debugOverlay pushed')
    Config.Testing.allowTeleport = false
    clientActions.testPanel({ open = true })
    H.eq(lastPush().data.allowTeleport, false, 'Config.Testing.allowTeleport read at call time')
    clientActions.testPanel({ open = false })
    Config.Testing.allowTeleport = true

    -- Crimson-Arena rule 13: a foreign value that arrives during the fade-out still stops the move
    local realFade = DoScreenFadeOut
    _G.DoScreenFadeOut = function() fades[#fades + 1] = 'out'; LocalPlayer.state.crimsonArena = { active = true, matchId = 'm3' } end
    local movedBefore = #moved
    local okF, errF = clientActions.teleport({ target = 'start' })
    H.eq(errF, 'err.in_arena', 'teleport refused when the arena flag arrives during the fade')
    H.eq(#moved, movedBefore, 'SetEntityCoords never called')
    H.eq(fades[#fades], 'in', 'the screen fades back in')
    H.eq(frozen[#frozen], false, 'nothing stays frozen')
    _G.DoScreenFadeOut = realFade
    LocalPlayer.state.crimsonArena = nil

    -- a new test: the HUD flag is set, then the freshly mounted panel gets the key/config push
    currentRun = { id = 'run-10' }
    H.fire('crimson-police:client:test', 1, { controls = true, runId = 'run-10', debug = false })
    H.step(0)
    local pushesBefore = #nuiPushes
    H.advance(300, 50)
    H.ok(#nuiPushes > pushesBefore and lastPush().data.key == 'F7', 'the panel gets the bound key after the HUD flag')

    -- the test ends
    H.fire('crimson-police:client:test', 1, { controls = false, runId = 'run-10', debug = false })
    H.eq(st.controls, false, 'controls off')
    local okN, errN = clientActions.testControl({ control = 'skip' })
    H.eq(errN, 'err.test_no_active', 'no controls after the end')
end

return H
