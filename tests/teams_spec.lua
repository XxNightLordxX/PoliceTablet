-- Modules/units and modules/operations (slice teams).

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_teams'
H.resetDatabase()
H.boot({ side = 'server' })

-- ============================================================================
--                                    LOCALE
-- ============================================================================
-- Serve this slice's part as en.json so CP.L returns real text.

local partFile = assert(io.open(H.root .. 'locales/parts/teams.json', 'r'))
local partText = partFile:read('a')
partFile:close()
local part = require('cjson').decode(partText)
local realLoad = LoadResourceFile
LoadResourceFile = function(res, path)
    if path == 'locales/en.json' then return partText end
    return realLoad(res, path)
end
H.load('shared/locale.lua')

-- Every locale key the slice's Lua uses exists in the part.
do
    local files = {
        'modules/units/server.lua',
        'modules/units/client.lua',
        'modules/operations/server.lua',
        'modules/operations/client.lua',
    }
    local missing = {}
    for _, f in ipairs(files) do
        local fh = assert(io.open(H.root .. f, 'r'))
        local src = fh:read('a')
        fh:close()
        for key in src:gmatch('\'((err|unit|officer|sup)%.[%w_%.]+)\'') do
            if not part[key] then missing[#missing + 1] = f .. ': ' .. key end
        end
        -- keys built from a prefix + reason
        for prefix in src:gmatch('\'(sup%.crossdept%.notify_waiting_)\'') do
            for _, r in ipairs({ 'failed', 'abandoned', 'not_enough', 'no_location', 'start_failed' }) do
                if not part[prefix .. r] then missing[#missing + 1] = f .. ': ' .. prefix .. r end
            end
        end
    end
    for _, kind in ipairs({ 'completed', 'started', 'failed', 'abandoned' }) do
        for _, s in ipairs({ '_title', '_text' }) do
            local k = 'sup.crossdept.webhook_' .. kind .. s
            if not part[k] then missing[#missing + 1] = k end
        end
    end
    H.eq(#missing, 0, 'every Lua locale key is in teams.json: ' .. table.concat(missing, ', '))
    -- Shared keys keep the owner's text (ARCHITECTURE §10).
    local function OwnerText(file, key)
        local fh = io.open(H.root .. 'locales/parts/' .. file, 'r')
        if not fh then return nil end
        local d = require('cjson').decode(fh:read('a'))
        fh:close()
        return d[key]
    end
    for _, k in ipairs({
        'err.in_arena',
        'err.already_on_run',
        'err.on_call',
        'err.busy',
        'err.no_location',
        'err.run_create_failed',
        'err.unit_locked',
    }) do
        if part[k] then H.eq(part[k], OwnerText('engine_a.json', k), 'same text as engine_a for ' .. k) end
    end
    for _, k in ipairs({
        'err.internal',
        'err.invalid_payload',
        'err.no_permission',
        'err.not_police',
        'err.not_in_game',
        'err.rate_limited',
    }) do
        if part[k] then H.eq(part[k], OwnerText('core.json', k), 'same text as core for ' .. k) end
    end
end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local players = {}      -- src -> { citizenid, name, job, onduty, callsign, rank, admin, sup }
local arena, onCall, perms = {}, {}, {}
local notes, pushes, audits, hooks = {}, {}, {}, {}
local unloadFns, lostFns = {}, {}
local runsById, runBySrc, removed, created = {}, {}, {}, {}
local pickResult = 2
local runSeq = 0

local function AddPlayer(src, t)
    t.citizenid = t.citizenid or ('CID' .. src)
    t.name = t.name or ('Officer ' .. src)
    if t.onduty == nil then t.onduty = true end
    players[src] = t
    H.players[src] = H.players[src] or { coords = vec3(0.0, 0.0, 0.0) }
    if t.admin then H.players[src].ace = { ['crimsonpolice.admin'] = true } end
end

local DEPTS = {
    sast = { key = 'sast', short = 'SAST', label = 'San Andreas State Troopers' },
    fib = { key = 'fib', short = 'FIB', label = 'Federal Investigation Bureau' },
}

CP.Qbx = {
    getInfo = function(src)
        local p = players[src]
        if not p then return nil end
        return {
            src = src,
            citizenid = p.citizenid,
            name = p.name,
            job = {
                name = p.job or 'unemployed',
                onduty = p.onduty,
                gradeLevel = p.sup and 3 or 1,
                gradeName = p.rank or 'Trooper',
            },
            callsign = p.callsign,
        }
    end,
    getOnlinePlayers = function()
        local out = {}
        for s in pairs(players) do out[#out + 1] = s end
        table.sort(out)
        return out
    end,
    getByCitizenId = function(cid)
        for s, p in pairs(players) do if p.citizenid == cid then return s end end
        return nil
    end,
    onPlayerUnload = function(fn) unloadFns[#unloadFns + 1] = fn end,
}
CP.Access = {
    getOfficer = function(src)
        local p = players[src]
        if not p or not p.job or not DEPTS[p.job] then return nil, 'err.not_police' end
        if not p.onduty then return nil, 'err.not_on_duty' end
        local d = DEPTS[p.job]
        return {
            src = src,
            citizenid = p.citizenid,
            name = p.name,
            department = d.key,
            departmentLabel = d.label,
            departmentShort = d.short,
            job = p.job,
            rank = p.rank or 'Trooper',
            gradeLevel = p.sup and 3 or 1,
            callsign = p.callsign,
            onduty = true,
            isSupervisor = p.sup == true,
            isAdmin = p.admin == true,
        }
    end,
    isAdmin = function(src) return players[src] ~= nil and players[src].admin == true end,
    departmentForJob = function(job) return DEPTS[job] and job or nil end,
    onLost = function(fn) lostFns[#lostFns + 1] = fn end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars, opts)
        notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars, opts = opts }
        return true
    end,
    push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } return true end,
}
CP.Alerts = {
    inArena = function(src) return arena[src] == true end,
}
CP.Calls = {
    isOnCall = function(src) return onCall[src] == true end,
}
CP.Permissions = {
    can = function(src, action)
        if action ~= 'launchCrossDept' then return false, 'err.no_permission' end
        if src == 0 or (players[src] and players[src].admin) or perms[src] then return true end
        return false, 'err.no_permission'
    end,
}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            role = role,
            category = category,
            action = action,
            target = target,
            old = old,
            new = new,
            reason = reason,
        }
    end,
    webhook = function(category, title, text, fields)
        hooks[#hooks + 1] = { category = category, title = title, text = text, fields = fields }
    end,
}

local function Def(id, o)
    o = o or {}
    return {
        id = id,
        label = o.label or ('Label ' .. id),
        description = 'Desc ' .. id,
        type = o.type or 'tactical',
        departments = o.departments or {},
        minOfficers = o.min or 1,
        maxOfficers = o.max or 4,
        difficulty = 3,
        status = o.status or 'published',
        isBoss = o.isBoss or false,
        objectives = { { block = 'x' } },
        locations = {
            { start = { coords = vec3(1, 2, 3), radius = 50 } },
            { start = { coords = vec3(4, 5, 6), radius = 50 } },
        },
    }
end
local MISSIONS = {
    gang_shootout = Def('gang_shootout', { label = 'Gang Shootout' }),
    hostage_rescue = Def('hostage_rescue', { label = 'Hostage Rescue', min = 3 }),
    warrant_service = Def('warrant_service', { type = 'investigation', departments = { 'fib' } }),
    evoc_course = Def('evoc_course', { type = 'training', max = 1 }),
    weekly_boss_kingpin = Def('weekly_boss_kingpin', { isBoss = true }),
    off_mission = Def('off_mission', { status = 'archived' }),
}
local disabled = { off_mission = true }
CP.Missions = {
    get = function(id) return MISSIONS[id] end,
    list = function()
        local out = {}
        for _, d in pairs(MISSIONS) do out[#out + 1] = d end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    isEnabled = function(id) return MISSIONS[id] ~= nil and not disabled[id] end,
}
CP.Draw = {
    pickLocation = function() return pickResult end,
}

local function NewRun(opts)
    runSeq = runSeq + 1
    local run = {
        id = 'run-' .. runSeq,
        operationId = opts.operationId,
        state = 'accepted',
        order = {},
        participants = {},
        expectedTier = 'heavy',
        tier = nil,
        test = opts.test,
    }
    for _, o in ipairs(opts.members) do
        local s = type(o) == 'table' and o.src or o
        local p = players[s]
        run.order[#run.order + 1] = s
        run.participants[s] = {
            src = s,
            status = 'active',
            name = p.name,
            callsign = p.callsign,
            departmentShort = DEPTS[p.job] and DEPTS[p.job].short or '',
            department = p.job,
            arrived = false,
        }
        runBySrc[s] = run
    end
    runsById[run.id] = run
    return run
end

CP.Runs = {
    getBySrc = function(src) return runBySrc[src] end,
    isOnMission = function(src) return runBySrc[src] ~= nil end,
    get = function(id) return runsById[id] end,
    activeSrcs = function(run)
        local out = {}
        for _, s in ipairs(run.order) do if run.participants[s].status == 'active' then out[#out + 1] = s end end
        return out
    end,
    remaining = function() return 480 end,
    create = function(opts)
        created[#created + 1] = opts
        return NewRun(opts)
    end,
    removeParticipant = function(run, src, reason)
        removed[#removed + 1] = { runId = run.id, src = src, reason = reason }
        run.participants[src].status = 'left'
        runBySrc[src] = nil
        local left = 0
        for _, s in ipairs(run.order) do if run.participants[s].status == 'active' then left = left + 1 end end
        if left == 0 then
            runsById[run.id] = nil
            run.state = 'ended'
            if run.operationId and CP.Operations then CP.Operations.onRunEnded(run, 'abandoned') end
        end
        return 1
    end,
}
local function EndRunStub(run, state)
    for _, s in ipairs(run.order) do run.participants[s].status = 'left'; runBySrc[s] = nil end
    runsById[run.id] = nil
    run.state = 'ended'
    if run.operationId then CP.Operations.onRunEnded(run, state) end
end

H.load('modules/scaling/server.lua')
H.load('modules/units/server.lua')
H.load('modules/operations/server.lua')
H.step(0)   -- the start-up threads register listeners and read cp_operations

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local reqN = 0
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 't' .. reqN
    H.clockMs = H.clockMs + 2500
    H.fire('crimson-police:' .. name, src, payload, id)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end
local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1000
    return H.callback('crimson-police:' .. name, src, args)
end
local function LastNote(src, key)
    for i = #notes, 1, -1 do
        local n = notes[i]
        if n.src == src and (key == nil or n.key == key) then return n end
    end
    return nil
end
local function CountNotes(key)
    local n = 0
    for _, x in ipairs(notes) do if x.key == key then n = n + 1 end end
    return n
end
local function PushedTo(src, topic)
    for _, p in ipairs(pushes) do if p.src == src and p.topic == topic then return true end end
    return false
end
local function Clear() notes, pushes, audits, hooks = {}, {}, {}, {}; H.reset() end
local function Contains(list, v) for _, x in ipairs(list) do if x == v then return true end end return false end

-- Players: 1-4 SAST, 5-6 FIB, 7 civilian, 8 SAST off duty, 9 FIB supervisor, 10 admin (not police)
AddPlayer(1, { job = 'sast', name = 'John Doe', callsign = '2L-14', rank = 'Sergeant', sup = true })
AddPlayer(2, { job = 'sast', name = 'Maria Lopez', callsign = '2L-21' })
AddPlayer(3, { job = 'sast', name = 'Tom Reed' })
AddPlayer(4, { job = 'sast', name = 'Ana Silva', callsign = '2L-30' })
AddPlayer(5, { job = 'fib', name = 'Dana Whitfield', callsign = 'F-11' })
AddPlayer(6, { job = 'fib', name = 'Leo Park', callsign = 'F-12' })
AddPlayer(7, { job = 'mechanic', name = 'Civ Seven' })
AddPlayer(8, { job = 'sast', name = 'Off Duty', onduty = false })
AddPlayer(9, { job = 'fib', name = 'Grace Kim', callsign = 'F-01', sup = true })
AddPlayer(10, { name = 'Server Admin', admin = true })
perms[1] = true
perms[9] = true

H.eq(#unloadFns, 2, 'units + operations registered onPlayerUnload')
H.eq(#lostFns, 2, 'units + operations registered onLost')
H.eq(CP.Units._INVITE_TTL, 120, 'invite TTL constant is 120 s')

-- ============================================================================
--                                    UNITS
-- ============================================================================

local U = CP.Units

-- Solo officers lead themselves.
H.eq(U.unitOf(1), nil, 'solo: no unit')
H.eq(#U.members(1), 1, 'solo members = { src }')
H.eq(U.members(1)[1], 1, 'solo member is self')
H.ok(U.isLeader(1), 'solo officer leads themselves')

-- Invite validation.
local ok, data = Act('server:unitInvite', 1, 1)
H.eq(ok, false, 'invite self refused')
H.eq(data, 'err.unit_invite_self', 'invite self key')
ok, data = Act('server:unitInvite', 1, 7)
H.eq(data, 'err.unit_target_unavailable', 'civilian cannot be invited')
ok, data = Act('server:unitInvite', 1, 8)
H.eq(data, 'err.unit_target_unavailable', 'off-duty officer cannot be invited')
ok, data = Act('server:unitInvite', 7, 1)
H.eq(data, 'err.not_police', 'a civilian cannot invite')
ok, data = Act('server:unitInvite', 1, { targetSrc = 'abc' })
H.eq(data, 'err.invalid_payload', 'bad target payload')
ok, data = Act('server:unitInvite', 1, { targetSrc = -3 })
H.eq(data, 'err.invalid_payload', 'negative target payload')
arena[6] = true
ok, data = Act('server:unitInvite', 1, 6)
H.eq(data, 'err.unit_target_unavailable', 'in-arena officer cannot be invited')
arena[6] = nil
arena[1] = true
ok, data = Act('server:unitInvite', 1, 2)
H.eq(data, 'err.in_arena', 'an in-arena officer cannot send invites')
arena[1] = nil
H.eq(U.unitOf(1), nil, 'refused invites create no unit')

-- First invite: the inviter leads a forming unit.
Clear()
ok, data = Act('server:unitInvite', 1, 2)
H.eq(ok, true, 'invite 2 ok')
H.eq(data.expiresIn, 120, 'invite expires in 120 s')
local unit = U.unitOf(1)
H.ok(unit ~= nil, 'forming unit exists')
H.eq(unit.leader, 1, 'first inviter is the leader')
H.eq(#unit.members, 1, 'forming unit has only the leader')
H.eq(unit.invites[2], H.time + 120, 'invite expiry stored')
local n = LastNote(2, 'unit.invite_received')
H.ok(n ~= nil, 'invitee got a toast')
H.eq(n and n.opts and n.opts.title, 'unit.invite_title', 'toast title key')
H.eq(n and n.vars.department, 'SAST', 'toast names the department')
local invitedPush, unitPushes = false, 0
for _, p in ipairs(pushes) do
    if p.src == 2 and p.topic == 'unit' then
        unitPushes = unitPushes + 1
        if p.data.invited == true then invitedPush = true end
    end
end
H.ok(invitedPush, 'invitee got a unit push with invited = true')
H.eq(unitPushes, 1, 'exactly one unit push to the invitee (no duplicate refetch)')
H.eq(PushedTo(2, 'board'), false, 'no board push to an invitee (not a member yet)')
H.eq(U.members(1)[1], 1, 'forming unit members')

ok, data = Act('server:unitInvite', 1, 2)
H.eq(data, 'err.unit_already_invited', 'no duplicate invite')

-- getUnit views.
local res = Cb('getUnit', 2)
H.ok(res.ok, 'getUnit ok for invitee')
H.eq(#res.data.invites, 1, 'invitee sees one invite')
H.eq(res.data.invites[1].unitId, unit.id, 'invite unit id')
H.eq(res.data.invites[1].from, 'John Doe', 'invite from')
H.eq(res.data.invites[1].fromCallsign, '2L-14', 'invite callsign')
H.eq(res.data.invites[1].departmentShort, 'SAST', 'invite department')
H.eq(res.data.invites[1].expiresIn, 120, 'invite expiresIn')
H.eq(res.data.unit, nil, 'invitee has no unit yet')
H.eq(res.data.me, 2, 'view carries me')

runBySrc[5] = { id = 'solo-run', order = { 5 }, participants = { [5] = { status = 'active' } } }
arena[4] = true
res = Cb('getUnit', 1)
local v = res.data
H.eq(v.unit.id, unit.id, 'leader view unit')
H.eq(v.unit.members[1].isLeader, true, 'leader flagged')
H.eq(v.unit.members[1].callsign, '2L-14', 'member callsign')
H.eq(v.unit.members[1].rank, 'Sergeant', 'member rank')
H.eq(#v.unit.pending, 1, 'pending invite listed')
H.eq(v.unit.pending[1].src, 2, 'pending invite src')
H.ok(v.canInvite, 'leader can invite')
H.eq(v.maxSize, 4, 'max size from config')
H.eq(v.inviteTtl, 120, 'view carries the invite TTL')
local invitable = {}
for _, o in ipairs(v.invitable) do invitable[o.src] = o end
H.ok(invitable[1] == nil, 'invitable excludes yourself')
H.ok(invitable[2] == nil, 'invitable excludes pending invitees')
H.ok(invitable[3] ~= nil, 'on-duty SAST officer invitable')
H.ok(invitable[6] ~= nil and invitable[6].departmentShort == 'FIB', 'FIB officer invitable (any department)')
H.ok(invitable[9] ~= nil, 'supervisor invitable')
H.ok(invitable[4] == nil, 'in-arena officer not invitable')
H.ok(invitable[5] == nil, 'officer on a run not invitable')
H.ok(invitable[7] == nil and invitable[8] == nil and invitable[10] == nil, 'non-officers not invitable')
H.eq(v.invitable[1].departmentShort, 'FIB', 'invitable sorted by department first')
arena[4] = nil
runBySrc[5] = nil
res = Cb('getUnit', 7)
H.eq(res.ok, false, 'civilian getUnit refused')
H.eq(res.error, 'err.not_police', 'civilian getUnit error key')

-- Accept with a bare boolean (newest invite).
Clear()
ok, data = Act('server:unitRespond', 2, true)
H.eq(ok, true, 'accept ok')
H.eq(data.unitId, unit.id, 'accept returns unit id')
H.eq(#unit.members, 2, 'two members')
H.eq(unit.members[2], 2, 'joined member appended')
H.eq(unit.invites[2], nil, 'invite consumed')
H.ok(LastNote(1, 'unit.member_joined') ~= nil, 'leader told')
H.ok(LastNote(2, 'unit.joined') ~= nil, 'joiner told')
H.ok(PushedTo(1, 'unit') and PushedTo(2, 'unit') and PushedTo(1, 'board'), 'unit + board pushes to members')
H.ok(not U.isLeader(2) and U.isLeader(1), 'leader unchanged')
H.eq(#U.members(2), 2, 'members from any member')
ok, data = Act('server:unitRespond', 2, true)
H.eq(data, 'err.unit_no_invite', 'no invite left')
ok, data = Act('server:unitInvite', 1, 2)
H.eq(data, 'err.unit_already_member', 'cannot invite a member')
ok, data = Act('server:unitRespond', 2, { accepted = 'yes' })
H.eq(data, 'err.invalid_payload', 'respond payload validated')
ok, data = Act('server:unitRespond', 2, { accepted = true, unitId = -1 })
H.eq(data, 'err.invalid_payload', 'respond unit id validated')

-- Any member may invite; the cap counts pending invites.
ok = Act('server:unitInvite', 2, 5)
H.eq(ok, true, 'member invites FIB officer')
ok = Act('server:unitInvite', 1, 3)
H.eq(ok, true, 'leader invites 3')
ok, data = Act('server:unitInvite', 1, 4)
H.eq(data, 'err.unit_full', 'members + pending invites reach the cap of 4')

-- Accept refused in the arena; accept with an explicit unit id.
arena[5] = true
ok, data = Act('server:unitRespond', 5, { accepted = true, unitId = unit.id })
H.eq(data, 'err.in_arena', 'accept refused while in the arena')
arena[5] = nil
ok = Act('server:unitRespond', 5, { accepted = true, unitId = unit.id })
H.eq(ok, true, 'FIB officer joins the SAST unit')
H.eq(#unit.members, 3, 'three members')

-- Decline.
Clear()
ok, data = Act('server:unitRespond', 3, { accepted = false, unitId = unit.id })
H.eq(ok, true, 'decline ok')
H.eq(data.accepted, false, 'decline result')
H.eq(unit.invites[3], nil, 'invite removed on decline')
H.ok(LastNote(1, 'unit.invite_declined') ~= nil, 'inviter told about the decline')

-- Invite expiry after 120 s.
ok = Act('server:unitInvite', 1, 3)
H.eq(ok, true, 're-invite after decline')
Clear()
H.time = H.time + 60
U._sweep()
H.ok(unit.invites[3] ~= nil, 'invite still open after 60 s')
H.time = H.time + 61
U._sweep()
H.eq(unit.invites[3], nil, 'invite expired after 120 s')
H.ok(LastNote(3, 'unit.invite_expired_you') ~= nil, 'invitee told the invite expired')
H.ok(LastNote(1, 'unit.invite_expired') ~= nil, 'inviter told the invite expired')
H.eq(LastNote(1, 'unit.invite_expired').vars.name, 'Tom Reed', 'the expiry toast names the invitee')
H.ok(PushedTo(3, 'unit'), 'invitee view refreshed')
ok, data = Act('server:unitRespond', 3, true)
H.eq(data, 'err.unit_no_invite', 'expired invite cannot be accepted')

-- Expired-but-not-swept invite answered with an explicit id.
ok = Act('server:unitInvite', 1, 3)
H.time = H.time + 125
ok, data = Act('server:unitRespond', 3, { accepted = true, unitId = unit.id })
H.eq(data, 'err.unit_invite_expired', 'late accept reports expiry')
H.eq(unit.invites[3], nil, 'late accept cleans the invite')

-- Leader leaves before accepting: the longest-standing member takes over.
Clear()
ok, data = Act('server:unitLeave', 1)
H.eq(ok, true, 'leader leaves')
H.eq(data.abandoned, false, 'no run abandoned')
H.eq(U.unitOf(1), nil, 'former leader has no unit')
H.eq(unit.leader, 2, 'longest-standing member (2) leads')
H.eq(#unit.members, 2, 'two members left')
H.ok(LastNote(2, 'unit.you_lead') ~= nil, 'new leader told')
H.ok(LastNote(5, 'unit.new_leader') ~= nil, 'others told about the new leader')
H.ok(LastNote(1, 'unit.you_left') ~= nil, 'leaver told')
ok, data = Act('server:unitLeave', 1)
H.eq(data, 'err.unit_none', 'leave without a unit')

-- A unit left with one member dissolves.
Clear()
ok = Act('server:unitLeave', 5)
H.eq(ok, true, 'member leaves')
H.eq(U.unitOf(2), nil, 'unit dissolved')
H.eq(U.unitOf(5), nil, 'leaver unitless')
H.ok(LastNote(2, 'unit.dissolved_after') ~= nil, 'last member told the unit dissolved')
H.ok(U.isLeader(2), 'last member is solo again')

-- Decline of the only invite dissolves a forming unit silently.
ok = Act('server:unitInvite', 3, 4)
local forming = U.unitOf(3)
H.ok(forming ~= nil, 'forming unit')
ok = Act('server:unitRespond', 4, false)
H.eq(ok, true, 'declined')
H.eq(U.unitOf(3), nil, 'forming unit dissolved after the only invite was declined')

-- Joining a unit moves the officer out of the old one and declines other invites.
Act('server:unitInvite', 3, 4)
Act('server:unitRespond', 4, true)  -- unit A = { 3, 4 }
local unitA = U.unitOf(3)
Act('server:unitInvite', 1, 3)      -- unit B forming (leader 1) invites 3
Act('server:unitInvite', 6, 3)      -- unit C forming (leader 6) invites 3
local unitB, unitC = U.unitOf(1), U.unitOf(6)
Clear()
ok = Act('server:unitRespond', 3, { accepted = true, unitId = unitB.id })
H.eq(ok, true, 'accept into unit B')
H.eq(U.unitOf(3), unitB, '3 is in unit B')
H.eq(U.unitOf(4), nil, 'unit A dissolved (one member left)')
H.eq(U.unitOf(6), nil, 'unit C (forming, only invite gone) dissolved')
H.eq(unitA.members[1], nil, 'old unit emptied')
H.eq(unitB.leader, 1, 'unit B leader')
H.eq(unitC.invites[3], nil, 'other invite dropped')

-- Lock (acceptType): invites close; unlock refused while a member is still on the unit's run.
Act('server:unitInvite', 1, 2)
Act('server:unitRespond', 2, true)  -- unit B = { 1, 3, 2 }
Act('server:unitInvite', 1, 5)      -- pending invite
Clear()
H.ok(U.lock(unitB), 'lock ok')
H.ok(unitB.locked, 'unit locked')
H.eq(unitB.invites[5], nil, 'pending invites withdrawn at lock')
H.ok(LastNote(5, 'unit.invite_withdrawn') ~= nil, 'invitee told the invite closed')
ok, data = Act('server:unitInvite', 1, 6)
H.eq(data, 'err.unit_locked', 'no invites while locked')
res = Cb('getUnit', 1)
H.eq(res.data.unit.locked, true, 'view shows locked')
H.eq(res.data.canInvite, false, 'cannot invite while locked')
H.eq(res.data.inviteBlocked, 'unit.blocked_locked', 'locked reason')
H.eq(#res.data.invitable, 0, 'no invitable list while locked')

local unitRun = NewRun({ members = { 1, 3, 2 } })
H.eq(U.unlock(unitB), false, 'unlock refused while members are on the unit run')
H.ok(unitB.locked, 'still locked')
res = Cb('getUnit', 3)
H.eq(res.data.inviteBlocked, 'unit.blocked_on_run', 'on-run reason wins')

-- Leaving the unit mid-run abandons that run (quit).
Clear()
removed = {}
ok, data = Act('server:unitLeave', 3)
H.eq(ok, true, 'leave mid-run')
H.eq(data.abandoned, true, 'run abandoned')
H.eq(#removed, 1, 'removeParticipant called once')
H.eq(removed[1].src, 3, 'for the leaver')
H.eq(removed[1].reason, 'quit', 'with end reason quit')
H.eq(removed[1].runId, unitRun.id, 'on the unit run')
H.eq(U.unitOf(3), nil, 'leaver out of the unit')

-- The run ends: runs unlocks the unit.
for _, s in ipairs(unitRun.order) do runBySrc[s] = nil end
runsById[unitRun.id] = nil
H.ok(U.unlock(unitB), 'unlock after the run ended')
H.eq(unitB.locked, false, 'unit unlocked')
H.eq(U.unlock(unitB.id), false, 'unlock of an unlocked unit is a no-op')

-- Leaving the unit while on a Cross-Department run does not touch that run.
local opRun = NewRun({ members = { 2 }, operationId = 99 })
U.lock(unitB)
removed = {}
ok, data = Act('server:unitLeave', 2)
H.eq(ok, true, 'leave while on an operation run')
H.eq(data.abandoned, false, 'operation run not abandoned')
H.eq(#removed, 0, 'no removeParticipant for the operation run')
runBySrc[2] = nil
runsById[opRun.id] = nil
H.eq(U.unitOf(1), nil, 'unit B dissolved (one member left)')

-- Lock of a forming unit: the leader goes solo.
Act('server:unitInvite', 1, 2)
local f2 = U.unitOf(1)
H.ok(U.lock(f2), 'lock forming unit')
H.eq(U.unitOf(1), nil, 'forming unit dissolved at lock')
H.eq(f2.invites[2], nil, 'its invite withdrawn')
H.eq(U.lock(f2), false, 'lock of a dissolved unit refused')

-- Invites: an inviter on a run, a target on a run, a target in a full unit.
Act('server:unitInvite', 1, 2)
Act('server:unitRespond', 2, true)
Act('server:unitInvite', 1, 3)
Act('server:unitRespond', 3, true)
Act('server:unitInvite', 1, 4)
Act('server:unitRespond', 4, true)
local full = U.unitOf(1)
H.eq(#full.members, 4, 'full unit of 4')
ok, data = Act('server:unitInvite', 5, 1)
H.eq(data, 'err.unit_target_in_full_unit', 'target in a full unit')
res = Cb('getUnit', 5)
local seen = {}
for _, o in ipairs(res.data.invitable) do seen[o.src] = true end
H.ok(not seen[1] and not seen[2], 'members of a full unit are not invitable')
runBySrc[6] = { id = 'r6', order = { 6 }, participants = { [6] = { status = 'active' } } }
ok, data = Act('server:unitInvite', 5, 6)
H.eq(data, 'err.unit_target_on_run', 'target on a run')
ok, data = Act('server:unitInvite', 6, 5)
H.eq(data, 'err.unit_on_run', 'inviter on a run')
runBySrc[6] = nil
res = Cb('getUnit', 1)
H.eq(res.data.inviteBlocked, 'unit.blocked_full', 'full unit reason')

-- Disconnect, character unload and lost access.
Clear()
H.fire('playerDropped', 4)
H.eq(#full.members, 3, 'dropped member removed')
H.ok(LastNote(1, 'unit.member_disconnected') ~= nil, 'members told about the disconnect')
for _, fn in ipairs(unloadFns) do fn(3) end
H.eq(#full.members, 2, 'unloaded member removed')
for _, fn in ipairs(lostFns) do fn(2, 'off_duty') end
H.eq(U.unitOf(1), nil, 'unit dissolved after the member went off duty')
H.ok(LastNote(2, 'unit.removed_lost') ~= nil, 'lost member told')

-- Invites to a dropped player are cancelled.
Act('server:unitInvite', 1, 5)
Act('server:unitRespond', 5, true)
Act('server:unitInvite', 1, 6)
local u6 = U.unitOf(1)
H.ok(u6.invites[6] ~= nil, 'invite pending')
Clear()
H.fire('playerDropped', 6)
H.eq(u6.invites[6], nil, 'invite to a dropped player cancelled')
H.ok(LastNote(1, 'unit.invite_cancelled') ~= nil, 'inviter told')

-- Safety net: a locked unit with nobody on a run unlocks after LOCK_GRACE.
U.lock(u6)
U._sweep()
H.ok(u6.locked, 'still locked right after the lock')
H.time = H.time + U._LOCK_GRACE
U._sweep()
H.eq(u6.locked, false, 'lock lifted by the safety net')

-- remove() never touches runs.
runBySrc[5] = { id = 'r5', order = { 5 }, participants = { [5] = { status = 'active' } } }
removed = {}
H.ok(U.remove(5), 'remove ok')
H.eq(#removed, 0, 'remove does not end runs')
runBySrc[5] = nil
H.eq(U.unitOf(1), nil, 'unit gone after remove')
AddPlayer(4, { job = 'sast', name = 'Ana Silva', callsign = '2L-30' })
AddPlayer(6, { job = 'fib', name = 'Leo Park', callsign = 'F-12' })
players[2].onduty = true
U._reset()

-- ============================================================================
--                                  OPERATIONS
-- ============================================================================

local O = CP.Operations

-- Restart safety: rows left active are cancelled on start; the last launch drives the cooldown.
H.sql('DELETE FROM cp_operations')
local T = H.time
H.sql(
    'INSERT INTO cp_operations (mission_id, launched_by, status, created_at) VALUES (\'gang_shootout\', \'CID1\', \'joining\', FROM_UNIXTIME(?))',
    { T - 7200 })
H.sql(
    'INSERT INTO cp_operations (mission_id, launched_by, status, created_at) VALUES (\'gang_shootout\', \'CID1\', \'running\', FROM_UNIXTIME(?))',
    { T - 5400 })
H.sql(
    'INSERT INTO cp_operations (mission_id, launched_by, status, created_at) VALUES (\'gang_shootout\', \'CID1\', \'waiting\', FROM_UNIXTIME(?))',
    { T - 3600 })
H.sql(
    'INSERT INTO cp_operations (mission_id, launched_by, status, created_at, ended_at) VALUES (\'gang_shootout\', \'CID1\', \'completed\', FROM_UNIXTIME(?), FROM_UNIXTIME(?))',
    { T - 9000, T - 8000 })
O._reset()
O._init()
local rows = H.sql('SELECT status, ended_at IS NOT NULL AS ended FROM cp_operations ORDER BY id')
H.eq(rows[1].status, 'cancelled', 'stale joining row cancelled')
H.eq(rows[2].status, 'cancelled', 'stale running row cancelled')
H.eq(rows[3].status, 'cancelled', 'stale waiting row cancelled')
H.eq(rows[3].ended, 1, 'ended_at set on cancelled rows')
H.eq(rows[4].status, 'completed', 'final row untouched')
H.eq(O.cooldownLeft(), 0, 'last launch 1 h ago: no cooldown')
H.ok(not O.isLocked(), 'no operation after start')
H.eq(O.boardCard(1), nil, 'no board card')

-- A launch 10 minutes ago (persisted) blocks a new launch for 20 more minutes.
H.sql(
    'INSERT INTO cp_operations (mission_id, launched_by, status, created_at, ended_at) VALUES (\'gang_shootout\', \'CID9\', \'cancelled\', FROM_UNIXTIME(?), FROM_UNIXTIME(?))',
    { T - 600, T - 500 })
O._init()
H.eq(O.cooldownLeft(), 1200, 'cooldown from the last created_at')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(data, 'err.op_cooldown', 'launch refused during the cooldown')
res = Cb('sup:getOperation', 1)
H.eq(res.data.cooldownLeft, 1200, 'view cooldownLeft')
H.eq(res.data.canLaunch, false, 'cannot launch')
H.eq(res.data.launchBlocked, 'err.op_cooldown', 'launch blocked reason')
H.time = H.time + 1200
H.eq(O.cooldownLeft(), 0, 'cooldown over')

-- Permissions.
ok, data = Act('server:sup:opLaunch', 2, { missionId = 'gang_shootout' })
H.eq(data, 'err.no_permission', 'officer without the permission refused')
ok, data = Act('server:admin:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(data, 'err.no_permission', 'admin path refused for a supervisor')
res = Cb('sup:getOperation', 2)
H.eq(res.error, 'err.no_permission', 'view refused without the permission')

-- Payload and eligibility.
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'bad id!' })
H.eq(data, 'err.invalid_payload', 'mission id validated')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'nope' })
H.eq(data, 'err.op_mission_unknown', 'unknown mission')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'weekly_boss_kingpin' })
H.eq(data, 'err.op_mission_boss', 'never the Weekly Boss')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'warrant_service' })
H.eq(data, 'err.op_mission_departments', 'must be open to every department')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'evoc_course' })
H.eq(data, 'err.op_mission_solo', 'must support 2+ officers')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'off_mission' })
H.eq(data, 'err.op_mission_disabled', 'must be published and enabled')
Config.CrossDept.enabled = false
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(data, 'err.op_disabled', 'Config.CrossDept.enabled = false')
Config.CrossDept.enabled = true
res = Cb('sup:getOperation', 1)
local ids = {}
for _, m in ipairs(res.data.eligibleMissions) do ids[#ids + 1] = m.id end
H.eq(table.concat(ids, ','), 'gang_shootout,hostage_rescue', 'eligible missions list')
H.eq(res.data.eligibleMissions[2].minOfficers, 3, 'hostage rescue needs 3 (mission minOfficers)')
H.eq(res.data.eligibleMissions[1].maxOfficers, 8, 'operations take up to 8')
H.eq(res.data.canLaunch, true, 'can launch now')
H.eq(res.data.joinWindow, 300, 'view joinWindow from config')
H.eq(res.data.idleCancel, 1800, 'view idleCancel from config')
H.eq(res.data.maxParticipants, 8, 'view maxParticipants from config')
H.eq(res.data.crossBonus, 1.10, 'view crossBonus from config')

-- Launch.
Clear()
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(ok, true, 'launch ok')
local opId = data.id
H.ok(type(opId) == 'number' and opId > 0, 'operation id from the insert')
local row = H.sql(
    'SELECT mission_id, launched_by, status, UNIX_TIMESTAMP(created_at) AS created_ts, ended_at FROM cp_operations WHERE id = ?',
    { opId })[1]
H.eq(row.mission_id, 'gang_shootout', 'row mission')
H.eq(row.launched_by, 'CID1', 'row launcher citizenid')
H.eq(row.status, 'joining', 'row status joining')
H.eq(row.created_ts, H.time, 'created_at = launch time')
H.eq(row.ended_at, nil, 'no ended_at yet')
H.ok(O.isLocked(), 'board locked')
H.eq(O.cooldownLeft(), 1800, 'launch cooldown restarted')
local toasts = {}
for _, e in ipairs(H.findEvents('crimson-police:client:operation')) do
    toasts[e.target] = e.args
end
H.ok(toasts[1] and toasts[2] and toasts[5] and toasts[9], 'client:operation to on-duty officers of every department')
H.eq(toasts[7], nil, 'no toast for civilians')
H.eq(toasts[8], nil, 'no toast for off-duty officers')
H.eq(toasts[1] and toasts[1][1], 'launched', 'state launched')
H.eq(toasts[1] and toasts[1][2], 'Gang Shootout', 'mission label')
H.ok(PushedTo(8, 'board') and PushedTo(5, 'operation'), 'board + operation pushes to department members')
H.ok(PushedTo(10, 'operation'), 'operation push to the online admin')
H.ok(not PushedTo(7, 'board'), 'no pushes to civilians')
H.eq(audits[1] and audits[1].category, 'operations', 'audit category operations')
H.eq(audits[1] and audits[1].action, 'opLaunch', 'audit action')
H.eq(audits[1] and audits[1].role, 'supervisor', 'audit role')
H.eq(audits[1] and audits[1].new, 'gang_shootout', 'audit new value')
ok, data = Act('server:sup:opLaunch', 9, { missionId = 'hostage_rescue' })
H.eq(data, 'err.op_active', 'only one operation at a time')

-- Board card and join.
local card = O.boardCard(2)
H.eq(card.id, opId, 'card id')
H.eq(card.missionLabel, 'Gang Shootout', 'card label')
H.eq(card.launcher, 'John Doe', 'card launcher')
H.eq(card.status, 'joining', 'card status')
H.eq(card.joined, 0, 'nobody joined')
H.eq(card.max, 8, 'max 8')
H.eq(card.canJoin, true, 'can join')
H.eq(card.joinBlocked, nil, 'joinBlocked: nothing blocks the join')
H.eq(card.joinedByMe, false, 'not joined')
H.eq(card.joinEndsIn, 300, 'join window 5 min')

ok, data = Act('server:joinOperation', 7, opId)
H.eq(data, 'err.not_police', 'civilian cannot join')
ok, data = Act('server:joinOperation', 2, opId + 1)
H.eq(data, 'err.op_not_found', 'wrong operation id')
ok, data = Act('server:joinOperation', 2, { operationId = 'x' })
H.eq(data, 'err.invalid_payload', 'operation id validated')
arena[3] = true
ok, data = Act('server:joinOperation', 3, opId)
H.eq(data, 'err.in_arena', 'in-arena officer cannot join')
H.eq(O.boardCard(3).canJoin, false, 'card: in-arena officer cannot join')
H.eq(O.boardCard(3).joinBlocked, 'err.in_arena', 'joinBlocked = the join error (arena)')
arena[3] = nil
onCall[4] = true
ok, data = Act('server:joinOperation', 4, opId)
H.eq(data, 'err.on_call', 'officer on a real call cannot join')
H.eq(O.boardCard(4).joinBlocked, 'err.on_call', 'joinBlocked = the join error (real call)')
onCall[4] = nil
runBySrc[6] = { id = 'r6', order = { 6 }, participants = { [6] = { status = 'active' } } }
ok, data = Act('server:joinOperation', 6, opId)
H.eq(data, 'err.already_on_run', 'officer on a run cannot join')
H.eq(O.boardCard(6).canJoin, false, 'card: cannot join while on a run')
H.eq(O.boardCard(6).joinBlocked, 'err.already_on_run', 'joinBlocked = the join error (on a run)')
runBySrc[6] = nil

Clear()
ok, data = Act('server:joinOperation', 2, opId)
H.eq(ok, true, 'SAST officer joins')
H.eq(data.joined, 1, 'one joined')
ok, data = Act('server:joinOperation', 2, opId)
H.eq(data, 'err.op_already_joined', 'no double join')
H.ok(PushedTo(9, 'board'), 'join pushes the board')
card = O.boardCard(2)
H.eq(card.joinedByMe, true, 'joinedByMe')
H.eq(card.canJoin, false, 'cannot join twice')
H.eq(card.joinBlocked, 'err.op_already_joined', 'joinBlocked = the join error (already joined)')

-- Start now needs 2 participants and the launcher.
res = Cb('sup:getOperation', 1)
v = res.data.operation
H.eq(v.id, opId, 'view id')
H.eq(v.status, 'joining', 'view status')
H.eq(v.launcher, 'John Doe', 'view launcher')
H.eq(v.launcherCallsign, '2L-14', 'view launcher callsign')
H.eq(#v.participants, 1, 'view participants')
H.eq(v.participants[1].departmentShort, 'SAST', 'participant department')
H.eq(v.min, 2, 'min 2')
H.eq(v.canStart, false, 'cannot start with 1')
H.eq(v.startBlocked, 'sup.crossdept.start_blocked_min', 'start blocked: too few')
H.eq(v.tier, 'reinforced', 'expected tier for the minimum')
H.eq(v.tierExpected, true, 'tier is expected')
H.eq(res.data.eligibleMissions, nil, 'no mission list while an operation is active')
ok, data = Act('server:sup:opStart', 1)
H.eq(data, 'err.op_not_enough', 'start refused with 1 participant')
H.eq(O.active().status, 'joining', 'still joining after a refused start')

Act('server:joinOperation', 5, opId)
Act('server:joinOperation', 3, { operationId = opId })
res = Cb('sup:getOperation', 9)
v = res.data.operation
H.eq(v.canStart, false, 'another supervisor cannot start while the launcher is online')
H.eq(v.startBlocked, 'sup.crossdept.start_blocked_launcher', 'blocked: not the launcher')
ok, data = Act('server:sup:opStart', 9)
H.eq(data, 'err.op_not_launcher', 'start refused for another supervisor')
H.eq(#v.departments, 2, 'two departments')
H.eq(v.departments[1].short, 'FIB', 'departments sorted')
H.eq(v.departments[2].count, 2, 'SAST count')
H.eq(v.tier, 'heavy', 'expected tier for 3')
res = Cb('sup:getOperation', 1)
H.eq(res.data.operation.canStart, true, 'launcher can start')

Clear()
created = {}
pickResult = 2
ok, data = Act('server:sup:opStart', 1)
H.eq(ok, true, 'start now ok')
H.eq(data.participants, 3, 'three participants')
local c = created[1]
H.eq(c.operationId, opId, 'run created with operationId')
H.eq(c.locationIndex, 2, 'location from CP.Draw.pickLocation')
H.eq(c.missionType, 'tactical', 'mission type')
H.eq(c.mission.id, 'gang_shootout', 'mission def')
H.eq(c.leaderSrc, 2, 'the first joiner leads')
H.eq(#c.members, 3, 'every joiner is a member')
H.eq(c.members[2].src, 5, 'members in join order')
H.eq(c.isBoss, false, 'not the boss')
H.eq(O.active().status, 'running', 'status running')
H.eq(H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1].status, 'running', 'row running')
H.ok(O.isLocked(), 'board still locked while running')
local started = 0
for _, e in ipairs(H.findEvents('crimson-police:client:operation')) do
    if e.args[1] == 'started' then started = started + 1 end
end
H.ok(started >= 5, 'started sent to on-duty officers')
H.eq(CountNotes('officer.op.started_participant'), 3, 'participants told')
H.eq(audits[1] and audits[1].action, 'opStart', 'start audited')
ok, data = Act('server:joinOperation', 4, opId)
H.eq(data, 'err.op_join_closed', 'joining closed after start')
ok, data = Act('server:sup:opRelaunch', 1)
H.eq(data, 'err.op_not_waiting', 'relaunch only after a fail')

card = O.boardCard(5)
H.eq(card.status, 'running', 'card running')
H.eq(card.joined, 3, 'card counts active participants')
H.eq(card.joinedByMe, true, 'participant sees joinedByMe')
H.eq(card.runState, 'accepted', 'card run state')

local run = runsById['run-' .. runSeq]
run.state = 'in_progress'
run.tier = CP.Scaling.tierFor(3)
res = Cb('sup:getOperation', 1)
v = res.data.operation
H.eq(v.runState, 'in_progress', 'view run state')
H.eq(v.tier, 'heavy', 'tier set at In progress')
H.eq(v.tierExpected, false, 'tier no longer expected')
H.eq(v.remaining, 480, 'time remaining from the run')
H.eq(#v.participants, 3, 'participants from the run')
H.eq(v.participants[1].status, 'active', 'participant status')

-- The run fails: the operation stays active (waiting) and can be relaunched.
Clear()
EndRunStub(run, 'failed')
H.eq(O.active().status, 'waiting', 'failed run -> waiting')
H.eq(O.active().waitingReason, 'failed', 'waiting reason failed')
H.ok(O.isLocked(), 'board stays locked after a fail')
H.eq(H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1].status, 'waiting', 'row waiting')
H.ok(LastNote(1, 'sup.crossdept.notify_waiting_failed') ~= nil, 'supervisors told')
H.ok(LastNote(9, 'sup.crossdept.notify_waiting_failed') ~= nil, 'every supervisor told')
H.eq(LastNote(2, 'sup.crossdept.notify_waiting_failed'), nil, 'officers without the permission not told')
H.eq(hooks[1] and hooks[1].category, 'operations', 'fail posted to the operations webhook')
res = Cb('sup:getOperation', 9)
H.eq(res.data.operation.canRelaunch, true, 'any supervisor may relaunch')
H.eq(res.data.operation.idleCancelIn, 1800, 'auto-cancel countdown')
H.eq(O.boardCard(2).canJoin, false, 'no join while waiting')
H.eq(O.boardCard(2).joinBlocked, 'err.op_join_closed', 'joinBlocked = the join error (closed)')

Clear()
ok, data = Act('server:sup:opRelaunch', 9)
H.eq(ok, true, 'relaunch by another supervisor')
H.eq(O.active().status, 'joining', 'joining again')
H.eq(#O.active().participants, 0, 'a new join window starts empty')
H.eq(O.active().attempt, 2, 'second attempt')
H.eq(H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1].status, 'joining', 'row joining')
H.eq(O.cooldownLeft() <= 1800 and O.cooldownLeft() > 0, true, 'relaunch is not a new launch')
local rel = false
for _, e in ipairs(H.findEvents('crimson-police:client:operation')) do
    if e.args[1] == 'launched' and type(e.args[3]) == 'table' and e.args[3].relaunched == true then rel = true end
end
H.ok(rel, 'relaunch announced as launched with relaunched = true')
H.eq(audits[1] and audits[1].action, 'opRelaunch', 'relaunch audited')
res = Cb('sup:getOperation', 9)
H.eq(res.data.operation.startBlocked, 'sup.crossdept.start_blocked_min', 'relauncher owns the new window')

-- A joiner who drops leaves the join list.
Act('server:joinOperation', 2, opId)
Act('server:joinOperation', 4, opId)
H.eq(#O.active().participants, 2, 'two joined')
H.fire('playerDropped', 4)
H.eq(#O.active().participants, 1, 'dropped joiner removed')
for _, fn in ipairs(lostFns) do fn(2, 'off_duty') end
H.eq(#O.active().participants, 0, 'joiner who lost access removed')
AddPlayer(4, { job = 'sast', name = 'Ana Silva', callsign = '2L-30' })

-- Join window ends with too few participants: waiting (not enough).
Act('server:joinOperation', 2, opId)
Clear()
H.time = H.time + 301
O._tick()
H.eq(O.active().status, 'waiting', 'window closed with 1 participant -> waiting')
H.eq(O.active().waitingReason, 'not_enough', 'reason not_enough')
H.ok(LastNote(9, 'sup.crossdept.notify_waiting_not_enough') ~= nil, 'supervisors told')

-- Relaunch, enough joiners: the window end starts the run by itself.
Act('server:sup:opRelaunch', 1)
Act('server:joinOperation', 2, opId)
Act('server:joinOperation', 6, opId)
created = {}
Clear()
H.time = H.time + 300
O._tick()
H.eq(O.active().status, 'running', 'window end starts the run')
H.eq(#created, 1, 'run created by the window end')
H.eq(created[1].leaderSrc, 2, 'first joiner leads')
H.eq(hooks[1] and hooks[1].category, 'operations', 'automatic start posted to the webhook')

-- Every participant leaves: waiting (abandoned).
run = runsById['run-' .. runSeq]
CP.Runs.removeParticipant(run, 2, 'quit')
CP.Runs.removeParticipant(run, 6, 'quit')
H.eq(O.active().status, 'waiting', 'everyone left -> waiting')
H.eq(O.active().waitingReason, 'abandoned', 'reason abandoned')

-- Idle auto-cancel after Config.CrossDept.idleCancel without a run.
Clear()
H.time = H.time + 1799
O._tick()
H.eq(O.active() and O.active().status, 'waiting', 'still waiting before 30 min')
H.time = H.time + 1
O._tick()
H.eq(O.active(), nil, 'auto-cancelled after 30 idle minutes')
H.ok(not O.isLocked(), 'lock lifted')
row = H.sql('SELECT status, UNIX_TIMESTAMP(ended_at) AS ended_ts FROM cp_operations WHERE id = ?', { opId })[1]
H.eq(row.status, 'cancelled', 'row cancelled')
H.eq(row.ended_ts, H.time, 'ended_at set')
H.eq(audits[1] and audits[1].action, 'opAutoCancel', 'auto-cancel audited')
H.eq(audits[1] and audits[1].actor, 'console', 'by the server')
H.eq(audits[1] and audits[1].role, 'console', 'console role')
local cancelled = false
for _, e in ipairs(H.findEvents('crimson-police:client:operation')) do
    if e.args[1] == 'cancelled' then cancelled = true end
end
H.ok(cancelled, 'cancelled announced')

-- Cancel a running operation: everyone still on the run leaves with end reason cancelled.
H.time = H.time + 1800
ok, data = Act('server:admin:opLaunch', 10, { missionId = 'gang_shootout' })
H.eq(ok, true, 'admin launches (not police)')
local op2 = data.id
H.eq(H.sql('SELECT launched_by FROM cp_operations WHERE id = ?', { op2 })[1].launched_by, 'CID10',
    'admin citizenid stored')
Act('server:joinOperation', 2, op2)
Act('server:joinOperation', 5, op2)
Act('server:joinOperation', 9, op2)
ok = Act('server:admin:opStart', 10)
H.eq(ok, true, 'admin starts')
run = runsById['run-' .. runSeq]
CP.Runs.removeParticipant(run, 9, 'quit')      -- one left earlier
ok, data = Act('server:sup:opCancel', 1, {})
H.eq(data, 'err.op_reason_required', 'reason required')
ok, data = Act('server:sup:opCancel', 1, { reason = '   ' })
H.eq(data, 'err.op_reason_required', 'blank reason refused')
ok, data = Act('server:sup:opCancel', 1, { reason = string.rep('x', 201) })
H.eq(data, 'err.op_reason_too_long', 'reason max 200')
ok, data = Act('server:sup:opCancel', 2, { reason = 'no' })
H.eq(data, 'err.no_permission', 'cancel needs the permission')
Clear()
removed = {}
ok, data = Act('server:sup:opCancel', 1, { reason = 'Real call surge' })
H.eq(ok, true, 'cancel ok')
H.eq(#removed, 2, 'the two still on the run removed')
H.eq(removed[1].reason, 'cancelled', 'end reason cancelled')
H.eq(removed[2].reason, 'cancelled', 'end reason cancelled (2)')
H.ok(not O.isLocked(), 'lock lifted on cancel')
H.eq(O.active(), nil, 'no active operation')
H.eq(H.sql('SELECT status FROM cp_operations WHERE id = ?', { op2 })[1].status, 'cancelled', 'row cancelled')
H.eq(CountNotes('officer.op.cancelled_participant'), 2, 'participants told with the reason')
H.eq(LastNote(2, 'officer.op.cancelled_participant').vars.reason, 'Real call surge', 'reason passed on')
H.eq(audits[#audits].action, 'opCancel', 'cancel audited')
H.eq(audits[#audits].reason, 'Real call surge', 'audit reason')
ok, data = Act('server:sup:opCancel', 1, { reason = 'again' })
H.eq(data, 'err.op_none', 'nothing to cancel')
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(data, 'err.op_cooldown', 'one launch per 30 minutes')

-- Completion lifts the lock.
H.time = H.time + 1800
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'hostage_rescue' })
H.eq(ok, true, 'launch hostage rescue')
local op3 = data.id
Act('server:joinOperation', 2, op3)
Act('server:joinOperation', 5, op3)
ok, data = Act('server:sup:opStart', 1)
H.eq(data, 'err.op_not_enough', 'hostage rescue needs 3 (mission minimum)')
Act('server:joinOperation', 6, op3)
pickResult = nil
ok, data = Act('server:sup:opStart', 1)
H.eq(data, 'err.no_location', 'no free location')
H.eq(O.active().status, 'joining', 'still joining after a manual start without a location')
pickResult = 1
ok = Act('server:sup:opStart', 1)
H.eq(ok, true, 'started')
run = runsById['run-' .. runSeq]
Clear()
O.onRunEnded({ id = 'other-run', operationId = op3 }, 'completed')
H.eq(O.active().status, 'running', 'another run id is ignored')
EndRunStub(run, 'completed')
H.eq(O.active(), nil, 'completed -> no active operation')
H.ok(not O.isLocked(), 'lock lifted on completion')
row = H.sql('SELECT status, ended_at IS NOT NULL AS ended FROM cp_operations WHERE id = ?', { op3 })[1]
H.eq(row.status, 'completed', 'row completed')
H.eq(row.ended, 1, 'ended_at set')
local ended = false
for _, e in ipairs(H.findEvents('crimson-police:client:operation')) do if e.args[1] == 'ended' then ended = true end end
H.ok(ended, 'ended announced')
H.eq(hooks[1] and hooks[1].category, 'operations', 'result posted to the webhook')

-- A run that vanished without a report counts as failed after the grace period.
H.time = H.time + 1800
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
local op4 = data.id
Act('server:joinOperation', 2, op4)
Act('server:joinOperation', 5, op4)
Act('server:sup:opStart', 1)
run = runsById['run-' .. runSeq]
runsById[run.id] = nil
for _, s in ipairs(run.order) do runBySrc[s] = nil end
O._tick()
H.eq(O.active().status, 'running', 'missing run: grace period')
H.time = H.time + 61
O._tick()
H.eq(O.active().status, 'waiting', 'missing run treated as failed')
H.ok(O.isLocked(), 'still locked')
ok = Act('server:sup:opCancel', 9, { reason = 'cleanup' })
H.eq(ok, true, 'cancel while waiting')

-- Public API checks permission too; src 0 is the server.
H.eq(select(2, O.launch(2, 'gang_shootout')), 'err.no_permission', 'Ops.launch checks permission')
H.eq(select(2, O.cancel(0, '')), 'err.op_reason_required', 'Ops.cancel validates the reason')
H.eq(select(2, O.cancel(0, 'x')), 'err.op_none', 'Ops.cancel with nothing active')
local okE, whyE = O.eligible(MISSIONS.gang_shootout)
H.ok(okE and whyE == nil, 'eligible(gang_shootout)')

-- Reason length is counted in characters (UTF-8), control characters become spaces.
H.eq(select(2, O.cancel(0, string.rep('é', 150))), 'err.op_none', '150 accented characters (300 bytes) pass')
H.eq(select(2, O.cancel(0, string.rep('é', 201))), 'err.op_reason_too_long', '201 characters refused')
H.eq(select(2, O.cancel(0, '\n\t\n')), 'err.op_reason_required', 'only control characters = no reason')
H.eq(select(2, O.cancel(0, 'bad \255 bytes')), 'err.invalid_payload', 'invalid UTF-8 refused')

-- Idle clock ("auto-cancels after 30 minutes with no run in progress"): a relaunch does not reset it,
-- an open join window is never cut short, and a run clears it.
H.time = H.time + 1800
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(ok, true, 'launch for the idle clock')
local op5 = data.id
H.eq(O.active().idleSince, H.time, 'idle clock starts at the launch')
Act('server:joinOperation', 2, op5)
Act('server:joinOperation', 5, op5)
-- A join whose on-call lookup waits (CP.Calls may query the database) checks the operation again
-- afterwards: here Start now happens meanwhile, so the late joiner is refused and never listed.
local realOnCall = CP.Calls.isOnCall
CP.Calls.isOnCall = function(s)
    if s == 4 then
        CP.Calls.isOnCall = realOnCall
        ok = Act('server:sup:opStart', 1)
    end
    return realOnCall(s)
end
local okJ, whyJ = Act('server:joinOperation', 4, op5)
CP.Calls.isOnCall = realOnCall
H.eq(ok, true, 'started while the join waited')
H.eq(okJ, false, 'the late join is refused')
H.eq(whyJ, 'err.op_join_closed', 'with join closed')
H.eq(#O.active().participants, 2, 'the late joiner is not in the list')
H.eq(#created[#created].members, 2, 'nor on the run')
H.eq(O.active().idleSince, nil, 'an operation with a run is not idle')
run = runsById['run-' .. runSeq]
EndRunStub(run, 'failed')
local failedAt = H.time
H.eq(O.active().idleSince, failedAt, 'idle clock restarts when the run ends')
H.time = H.time + 1700
ok = Act('server:sup:opRelaunch', 9)
H.eq(ok, true, 'relaunch 28 minutes after the fail')
H.eq(O.active().idleSince, failedAt, 'relaunch keeps the idle clock')
H.time = H.time + 200
O._tick()
H.eq(O.active() and O.active().status, 'joining', 'an open join window is not auto-cancelled')
H.time = H.time + 101
O._tick()
H.eq(O.active() and O.active().status, 'waiting', 'window closed without participants -> waiting')
res = Cb('sup:getOperation', 1)
H.eq(res.data.operation.idleCancelIn, 0, 'auto-cancel is due')
O._tick()
H.eq(O.active(), nil, 'auto-cancelled: more than 30 minutes without a run')
H.eq(H.sql('SELECT status FROM cp_operations WHERE id = ?', { op5 })[1].status, 'cancelled', 'row cancelled')

-- The tick loop runs by itself: joining window end through the thread.
H.time = H.time + 1800
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
Act('server:joinOperation', 2, data.id)
Act('server:joinOperation', 5, data.id)
H.time = H.time + 300
H.advance(2000, 500)
H.eq(O.active() and O.active().status, 'running', 'tick thread starts the run at window end')

-- Integration (docs/notes/core.md: "use notifyMany with a list of sources"): participant toasts go through
-- CP.Tablet.notifyMany when the tablet module provides it, one call per toast, never a -1 broadcast.
local manyCalls = {}
CP.Tablet.notifyMany = function(srcs, kind, key, vars)
    manyCalls[#manyCalls + 1] = { srcs = CP.U.copy(srcs), kind = kind, key = key, vars = vars }
    for _, s in ipairs(srcs) do CP.Tablet.notify(s, kind, key, vars) end
    return #srcs
end
Clear()
removed = {}
ok = Act('server:sup:opCancel', 1, { reason = 'Wrap up' })
H.eq(ok, true, 'cancel the running operation')
local cancelCall
for _, m in ipairs(manyCalls) do if m.key == 'officer.op.cancelled_participant' then cancelCall = m end end
H.ok(cancelCall ~= nil, 'cancel toast sent through CP.Tablet.notifyMany')
H.eq(cancelCall and #cancelCall.srcs, 2, 'to the two participants still on the run')
H.eq(cancelCall and cancelCall.vars.reason, 'Wrap up', 'with the reason')
for _, m in ipairs(manyCalls) do
    for _, s in ipairs(m.srcs) do H.ok(s ~= -1, 'never a -1 broadcast') end
end
H.eq(#removed, 2, 'both removed from the run')
H.eq(removed[1] and removed[1].reason, 'cancelled', 'with end reason cancelled')
H.time = H.time + 1800
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
Act('server:joinOperation', 2, data.id)
manyCalls = {}
H.time = H.time + 300
O._tick()
H.eq(O.active() and O.active().status, 'waiting', 'window closed with too few -> waiting')
H.advance(100, 50)
local waitCall
for _, m in ipairs(manyCalls) do if m.key == 'sup.crossdept.notify_waiting_not_enough' then waitCall = m end end
H.ok(waitCall ~= nil, 'waiting toast to the supervisors through CP.Tablet.notifyMany')
H.ok(waitCall ~= nil and Contains(waitCall.srcs, 1) and Contains(waitCall.srcs, 9) and not Contains(waitCall.srcs, 2),
    'only the players with launchCrossDept')
CP.Tablet.notifyMany = nil

-- ============================================================================
--                     LEADER CONTROLS AND THE READY CHECK
-- ============================================================================

if O.active() then O.cancel(0, 'Clean up before the leader-control checks') end
U._reset()
Clear()
removed = {}
local function Unit3()
    Act('server:unitInvite', 1, 2)
    Act('server:unitRespond', 2, true)
    Act('server:unitInvite', 1, 3)
    Act('server:unitRespond', 3, true)
    return U.unitOf(1)
end
local function HasNote(src, key)
    return LastNote(src, key) ~= nil
end
local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == 'crimson-police:' .. name and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end

-- ============================================================================
--                                     KICK
-- ============================================================================

local u = Unit3()
H.eq(#u.members, 3, 'unit of 3 for the leader controls')
ok, data = Act('server:unitKick', 2, { targetSrc = 3 })
H.eq(data, 'err.unit_not_leader', 'a member cannot kick')
ok, data = Act('server:unitKick', 1, { targetSrc = 1 })
H.eq(data, 'err.unit_kick_self', 'the leader cannot kick themselves')
ok, data = Act('server:unitKick', 1, { targetSrc = 6 })
H.eq(data, 'err.unit_not_member', 'kick of a non-member refused')
ok, data = Act('server:unitKick', 1, { targetSrc = 'x' })
H.eq(data, 'err.invalid_payload', 'kick payload validated')

-- Locked (a type accepted): kick, make leader, disband and withdraw are all refused.
U.lock(u)
ok, data = Act('server:unitKick', 1, { targetSrc = 3 })
H.eq(data, 'err.unit_locked', 'kick refused once locked')
ok, data = Act('server:unitPromote', 1, { targetSrc = 2 })
H.eq(data, 'err.unit_locked', 'make leader refused once locked')
ok, data = Act('server:unitDisband', 1)
H.eq(data, 'err.unit_locked', 'disband refused once locked')
ok, data = Act('server:unitCancelInvite', 1, { targetSrc = 5 })
H.eq(data, 'err.unit_locked', 'withdraw refused once locked')
H.eq(#u.members, 3, 'nobody left the locked unit')
res = Cb('getUnit', 1)
H.eq(res.data.unit.canManage, false, 'no leader controls while locked')
U.unlock(u)
res = Cb('getUnit', 1)
H.eq(res.data.unit.canManage, true, 'the leader manages the open unit')
res = Cb('getUnit', 2)
H.eq(res.data.unit.canManage, false, 'a member does not')

Clear()
ok, data = Act('server:unitKick', 1, { targetSrc = 3 })
H.eq(ok, true, 'the leader kicks a member')
H.eq(U.unitOf(3), nil, 'the kicked member is out')
H.eq(#u.members, 2, 'two members left')
H.ok(HasNote(3, 'unit.you_were_kicked'), 'the kicked member is told')
H.ok(HasNote(1, 'unit.member_kicked') and HasNote(2, 'unit.member_kicked'), 'the others are told')
H.eq(#removed, 0, 'a kick never touches a run (no abandon, no cooldown)')
ok, data = Act('server:unitInvite', 1, 3)
H.eq(data, 'err.unit_kicked_recently', 'the kicked officer cannot be re-invited by the leader')
ok, data = Act('server:unitInvite', 2, 3)
H.eq(data, 'err.unit_kicked_recently', 'nor by another member of that unit')
res = Cb('getUnit', 1)
local listed = false
for _, o in ipairs(res.data.invitable) do if o.src == 3 then listed = true end end
H.eq(listed, false, 'the kicked officer is not in the invite list for 60 s')
ok, data = Act('server:unitInvite', 4, 3)
H.eq(ok, true, 'another officer may invite them at once')
Act('server:unitRespond', 3, false)
-- The block belongs to the unit: an officer who joined after the kick can't bring them back either.
Act('server:unitInvite', 1, 6)
Act('server:unitRespond', 6, true)
H.eq(U.unitOf(6), u, 'a new member joined after the kick')
ok, data = Act('server:unitInvite', 6, 3)
H.eq(data, 'err.unit_kicked_recently', 'a member who joined after the kick cannot re-invite them')
res = Cb('getUnit', 6)
listed = false
for _, o in ipairs(res.data.invitable) do if o.src == 3 then listed = true end end
H.eq(listed, false, 'nor sees them in the invite list')
Act('server:unitLeave', 6)
H.time = H.time + 59
ok, data = Act('server:unitInvite', 1, 3)
H.eq(data, 'err.unit_kicked_recently', 'still blocked after 59 s')
H.time = H.time + 1
ok, data = Act('server:unitInvite', 1, 3)
H.eq(ok, true, 're-invite allowed after Config.Units.kickReinvite')

-- ============================================================================
--                              WITHDRAW AN INVITE
-- ============================================================================

Clear()
ok = Act('server:unitInvite', 2, 5)
H.eq(ok, true, 'a member invites (policy anyone)')
res = Cb('getUnit', 2)
H.eq(#res.data.pendingSent, 1, 'the inviter sees the invite they sent')
H.eq(res.data.pendingSent[1].src, 5, 'pendingSent names the invitee')
H.eq(#u.members + 2, 4, 'unit of 2 + 2 open invites is full')
ok, data = Act('server:unitInvite', 1, 6)
H.eq(data, 'err.unit_full', 'the open invites hold the slots')
ok, data = Act('server:unitCancelInvite', 2, { targetSrc = 3 })
H.eq(data, 'err.unit_not_inviter', 'a member cannot withdraw another member\'s invite')
ok, data = Act('server:unitCancelInvite', 2, { targetSrc = 6 })
H.eq(data, 'err.unit_no_invite_sent', 'no invite to withdraw')
ok = Act('server:unitCancelInvite', 2, { targetSrc = 5 })
H.eq(ok, true, 'the inviter withdraws their own invite')
H.eq(u.invites[5], nil, 'invite gone')
H.ok(HasNote(5, 'unit.invite_withdrawn'), 'the invitee is told')
ok = Act('server:unitCancelInvite', 1, { targetSrc = 3 })
H.eq(ok, true, 'the leader withdraws any invite')
ok, data = Act('server:unitInvite', 1, 6)
H.eq(ok, true, 'the freed slot is usable at once')
Act('server:unitCancelInvite', 1, { targetSrc = 6 })

-- ============================================================================
--                                INVITE POLICY
-- ============================================================================

Config.Units.invitePolicy = 'leader'
ok, data = Act('server:unitInvite', 2, 5)
H.eq(data, 'err.unit_invite_leader_only', 'invitePolicy leader refuses a member\'s invite')
res = Cb('getUnit', 2)
H.eq(res.data.canInvite, false, 'the member cannot invite under the leader policy')
H.eq(res.data.inviteBlocked, 'unit.blocked_policy', 'with its reason')
ok = Act('server:unitInvite', 1, 5)
H.eq(ok, true, 'the leader still invites')
Act('server:unitCancelInvite', 1, { targetSrc = 5 })
Config.Units.invitePolicy = 'anyone'

-- ============================================================================
--                                 MAKE LEADER
-- ============================================================================

Clear()
ok, data = Act('server:unitPromote', 2, { targetSrc = 2 })
H.eq(data, 'err.unit_not_leader', 'a member cannot make themselves leader')
ok, data = Act('server:unitPromote', 1, { targetSrc = 1 })
H.eq(data, 'err.unit_already_leader', 'the leader already leads')
ok = Act('server:unitPromote', 1, { targetSrc = 2 })
H.eq(ok, true, 'make leader')
H.eq(u.leader, 2, 'the new leader leads')
H.ok(U.isLeader(2) and not U.isLeader(1), 'isLeader follows')
H.ok(HasNote(2, 'unit.you_lead') and HasNote(1, 'unit.new_leader'), 'both told')
ok, data = Act('server:unitKick', 1, { targetSrc = 2 })
H.eq(data, 'err.unit_not_leader', 'the old leader lost the controls')

-- ============================================================================
--                                   DISBAND
-- ============================================================================

Act('server:unitInvite', 2, 4)
Clear()
ok, data = Act('server:unitDisband', 1)
H.eq(data, 'err.unit_not_leader', 'a member cannot disband')
ok = Act('server:unitDisband', 2)
H.eq(ok, true, 'the leader disbands')
H.eq(U.unitOf(1), nil, 'member 1 is solo')
H.eq(U.unitOf(2), nil, 'the leader is solo')
H.ok(HasNote(1, 'unit.disbanded'), 'members told who disbanded')
H.eq(LastNote(1, 'unit.disbanded').vars.name, 'Maria Lopez', 'toast names the leader')
H.ok(HasNote(2, 'unit.you_disbanded'), 'the leader told')
H.ok(HasNote(4, 'unit.invite_withdrawn'), 'open invites withdrawn with a toast')
ok, data = Act('server:unitDisband', 2)
H.eq(data, 'err.unit_none', 'nothing to disband')
H.eq(#removed, 0, 'no run touched by any leader control')

-- ============================================================================
--                                 READY CHECK
-- ============================================================================

local readyCalls, cancelCalls = 0, {}
local function StartCheck(unitRef, typeKey)
    U.lock(unitRef)
    return U.readyCheck(unitRef, typeKey or 'tactical', function() readyCalls = readyCalls + 1 end, function(key, who)
        cancelCalls[#cancelCalls + 1] = { key = key, who = who }
        U.unlock(unitRef)                       -- what CP.Draw's onCancel does
    end)
end
local function LastCancel() return cancelCalls[#cancelCalls] end

u = Unit3()
Clear()
H.eq(U.readyCheck(u, 'tactical', function() end, function() end), true, 'a unit of 3 gets a check')
U._reset()
u = Unit3()
Clear()
H.ok(StartCheck(u), 'ready check started')
H.ok(u.locked, 'the unit stays locked during the check (no second accept: CP.Draw refuses a locked unit)')
local prompts = ClientEvents('client:readyCheck')
H.eq(#prompts, 2, 'the two members are asked, not the leader')
local prompt = prompts[1].args[1]
local keys = {}
for k in pairs(prompt) do keys[#keys + 1] = k end
table.sort(keys)
H.eq(table.concat(keys, ','), 'expiresIn,leaderName,typeKey,typeLabel', 'the prompt carries the type only')
H.eq(prompt.typeLabel, Config.MissionTypes.tactical.label, 'the prompt names the type')
H.eq(prompt.expiresIn, 20, 'Config.Units.readyTimeout seconds to answer')
H.eq(prompt.leaderName, 'John Doe', 'and the leader')
local pushedCheck
for _, p in ipairs(pushes) do
    if p.src == 2 and p.topic == 'unit' and p.data.readyCheck then pushedCheck = p.data.readyCheck end
end
H.ok(pushedCheck ~= nil, 'the unit push carries the check')
H.eq(pushedCheck and pushedCheck.waitingForMe, true, 'member 2 still has to answer')
H.eq(pushedCheck and #pushedCheck.waiting, 2, 'two waiting')
res = Cb('getUnit', 3)
H.eq(res.data.unit.readyCheck.typeLabel, Config.MissionTypes.tactical.label, 'getUnit shows the check')
H.eq(res.data.unit.readyCheck.waitingForMe, true, 'to a member who has to answer')
res = Cb('getUnit', 1)
H.eq(res.data.unit.readyCheck.waitingForMe, false, 'the leader already answered by accepting')

-- A second accept while the check is pending never starts a second one.
local secondCancel
H.eq(U.readyCheck(u, 'patrol', function() readyCalls = readyCalls + 100 end, function(key)
    secondCancel = key
    U.unlock(u)                             -- what CP.Draw's onCancel does
end), true, 'a second check for the same unit is answered')
H.eq(secondCancel, 'err.busy', 'with err.busy, the first check keeps going')
H.ok(u.locked, 'the second caller\'s unlock leaves the unit locked while the first check is pending')

ok, data = Act('server:unitReady', 5, { accepted = true })
H.eq(data, 'err.unit_ready_none', 'an officer outside the unit cannot answer')
ok, data = Act('server:unitReady', 2, { accepted = 'yes' })
H.eq(data, 'err.invalid_payload', 'the answer is a boolean')
ok = Act('server:unitReady', 2, { accepted = true })
H.eq(ok, true, 'member 2 ready')
ok, data = Act('server:unitReady', 2, { accepted = true })
H.eq(data, 'err.unit_ready_answered', 'one answer per member')
H.eq(readyCalls, 0, 'not everyone answered yet')
H.reset()
ok = Act('server:unitReady', 3, true)
H.eq(ok, true, 'member 3 ready (a bare boolean, as the key mapping may send)')
H.eq(readyCalls, 1, 'everyone accepted: onReady once')
H.eq(U.readyCheckOf(u), nil, 'the check is over')
local clears = ClientEvents('client:readyCheck')
H.eq(#clears, 2, 'the prompts close')
H.eq(clears[1].args[1], nil, 'with nil')
ok, data = Act('server:unitReady', 3, true)
H.eq(data, 'err.unit_ready_none', 'nothing left to answer')
H.eq(readyCalls, 1, 'onReady never runs twice')
H.ok(u.locked, 'still locked: the draw follows')
U.unlock(u)

-- Decline: onCancel with who did not answer, the unit unlocked, nobody gets a cooldown.
Clear()
removed = {}
StartCheck(u)
ok = Act('server:unitReady', 2, { accepted = false })
H.eq(ok, true, 'member 2 declines')
H.eq(LastCancel().key, 'err.unit_ready_declined', 'onCancel with the decline key')
H.eq(#LastCancel().who, 1, 'naming one officer')
H.eq(LastCancel().who[1], 2, 'the one who declined')
H.eq(u.locked, false, 'the unit unlocked')
H.eq(readyCalls, 1, 'no draw after a decline')
H.eq(#removed, 0, 'nobody gets a cooldown or leaves a run')
for _, s in ipairs({ 1, 2, 3 }) do
    local n = LastNote(s, 'unit.ready.cancel_declined')
    H.ok(n ~= nil and n.vars.names == 'Maria Lopez', 'officer ' .. s .. ' told who was not ready')
end

-- Timeout: everyone who did not answer is named.
Clear()
StartCheck(u)
Act('server:unitReady', 3, true)
H.time = H.time + 19
U._sweep()
H.ok(U.readyCheckOf(u) ~= nil, 'still pending after 19 s')
H.time = H.time + 1
U._sweep()
H.eq(LastCancel().key, 'err.unit_ready_timeout', 'timeout after Config.Units.readyTimeout')
H.eq(#LastCancel().who, 1, 'only the member who did not answer')
H.eq(LastCancel().who[1], 2, 'member 2')
H.eq(LastNote(1, 'unit.ready.cancel_timeout').vars.names, 'Maria Lopez', 'the leader told who did not answer')
H.eq(u.locked, false, 'unlocked after a timeout')

-- A pending check keeps the lock-grace safety net away.
Config.Units.readyTimeout = 40
StartCheck(u)
H.time = H.time + U._LOCK_GRACE + 1
U._sweep()
H.ok(u.locked and U.readyCheckOf(u) ~= nil, 'the lock safety net waits for a pending check')
H.time = H.time + 10
U._sweep()
H.eq(LastCancel().key, 'err.unit_ready_timeout', 'the longer check times out')
Config.Units.readyTimeout = 20

-- A member entering the arena, taking a real call, going off duty or leaving cancels the check.
Clear()
StartCheck(u)
arena[3] = true
U._sweep()
arena[3] = nil
H.eq(LastCancel().key, 'err.unit_ready_cancelled', 'arena cancels')
H.eq(LastCancel().who[1], 3, 'naming the officer in the arena')
H.ok(HasNote(1, 'unit.ready.cancel_arena'), 'arena toast')
StartCheck(u)
ok, data = Act('server:unitReady', 2, true)
arena[2] = true
ok, data = Act('server:unitReady', 3, true)
H.eq(readyCalls, 1, 'a member who entered the arena after answering Ready stops the draw')
H.eq(LastCancel().who[1], 2, 'naming that member')
U.unlock(u)
arena[2] = nil
StartCheck(u)
arena[2] = true
ok, data = Act('server:unitReady', 2, true)
arena[2] = nil
H.eq(data, 'err.in_arena', 'an in-arena member cannot answer Ready')
H.ok(HasNote(1, 'unit.ready.cancel_arena'), 'and the check is cancelled')
-- The leader entering the arena between two sweeps: the last Ready does not start the draw.
local drawsBefore = readyCalls
StartCheck(u)
Act('server:unitReady', 2, true)
arena[1] = true
ok = Act('server:unitReady', 3, true)
arena[1] = nil
H.eq(readyCalls, drawsBefore, 'no draw while a member is in the arena')
H.eq(LastCancel().who[1], 1, 'the check names the officer in the arena')
H.eq(u.locked, false, 'and the unit unlocks')
Clear()
StartCheck(u)
onCall[2] = true
U._sweep()
onCall[2] = nil
H.eq(LastCancel().who[1], 2, 'a real call cancels')
H.ok(HasNote(3, 'unit.ready.cancel_call'), 'real call toast')
Clear()
StartCheck(u)
for _, fn in ipairs(lostFns) do fn(3, 'off_duty') end
H.eq(LastCancel().who[1], 3, 'going off duty cancels')
H.ok(HasNote(1, 'unit.ready.cancel_off_duty'), 'off-duty toast')
H.eq(U.unitOf(3), nil, 'and the officer left the unit')
Act('server:unitInvite', 1, 3)
Act('server:unitRespond', 3, true)
Clear()
StartCheck(u)
ok = Act('server:unitLeave', 3)
H.eq(ok, true, 'a member leaves during the check')
H.eq(LastCancel().who[1], 3, 'leaving cancels')
H.ok(HasNote(2, 'unit.ready.cancel_left'), 'leave toast')
H.eq(#removed, 0, 'no cooldown for anyone')
H.eq(U.readyCheck(U.unitOf(1), 'tactical', function() end, function() end), true, 'a unit of 2 still checks')
U._reset()
H.eq(U.readyCheck({ id = 999 }, 'tactical', function() end, function() end), false,
    'no unit: no check (the draw goes on)')

-- ============================================================================
--                           LAST PARTNERS AND NEARBY
-- ============================================================================

U._reset()
Clear()
local function RunOfPeople(srcs, extra)
    local run = { id = 'ended-' .. H.time, order = {}, participants = {}, test = extra and extra.test }
    for _, s in ipairs(srcs) do
        run.order[#run.order + 1] = s
        run.participants[s] = { src = s, citizenid = players[s].citizenid, status = 'left' }
    end
    return run
end
CP.Hooks.fire('run:ended', RunOfPeople({ 1, 4, 5 }), 'completed', 'completed')
local lp = U.lastPartners(1)
table.sort(lp)
H.eq(table.concat(lp, ','), '4,5', 'last partners from the last ended run')
CP.Hooks.fire('run:ended', RunOfPeople({ 1, 6 }, { test = true }), 'completed', 'completed')
lp = U.lastPartners(1)
H.eq(#lp, 2, 'a test run does not replace them')
H.players[1].coords = vec3(0.0, 0.0, 0.0)
H.players[4].coords = vec3(100.0, 0.0, 0.0)
H.players[5].coords = vec3(600.0, 0.0, 0.0)
H.players[6].coords = vec3(2000.0, 0.0, 0.0)
H.players[9].coords = vec3(5000.0, 0.0, 0.0)
H.players[2].coords = vec3(0.0, 4000.0, 0.0)
H.players[3].coords = vec3(0.0, 200.0, 0.0)
res = Cb('getUnit', 1, { coords = { x = 5000.0, y = 0.0, z = 0.0 } })
local band, partner, order = {}, {}, {}
for i, o in ipairs(res.data.invitable) do
    band[o.src] = o.distanceBand
    partner[o.src] = o.lastPartner
    order[i] = o.src
end
H.eq(band[4], 0, 'within 250 m: band 0')
H.eq(band[3], 0, 'band from the server position of each ped')
H.eq(band[5], 1, 'within 1000 m: band 1')
H.eq(band[6], 2, 'within 3000 m: band 2')
H.eq(band[9], 3, 'further: band 3')
H.eq(band[2], 3, 'distance, not one axis')
H.eq(order[1] == 3 or order[1] == 4, true, 'nearest officers first')
H.eq(band[order[#order]], 3, 'the furthest last')
H.eq(order[#order - 1], 9, 'within a band: department (FIB before SAST), then name')
H.eq(partner[4] and partner[5], true, 'last partners flagged')
H.eq(partner[6], false, 'others not')
H.time = H.time + 901
H.eq(#U.lastPartners(1), 0, 'last partners forgotten after 900 s')
for _, s in ipairs({ 1, 2, 3, 4, 5, 6, 9 }) do H.players[s].coords = vec3(0.0, 0.0, 0.0) end

-- ============================================================================
--                         SIZE FIT, LEVELS AND AVATARS
-- ============================================================================

local poolCalls = {}
CP.Draw.pool = function(typeKey, members)
    poolCalls[#poolCalls + 1] = { typeKey = typeKey, n = #members }
    local list = {}
    local n = typeKey == 'tactical' and (#members >= 2 and 3 or 0) or (#members == 1 and 2 or 1)
    for i = 1, n do list[i] = MISSIONS.gang_shootout end
    return list, nil, {}
end
res = Cb('getUnit', 1)
local fit = res.data.sizeFit
H.eq(fit.tactical.now, 0, 'solo: no tactical mission')
H.eq(fit.tactical.plusOne, 3, 'three with a partner')
H.eq(fit.patrol.now, 2, 'patrol counts')
H.eq(fit.patrol.plusOne, 1, 'patrol with one more')
local leaks = {}
local function Walk(v, path)
    if type(v) == 'table' then
        for k, x in pairs(v) do Walk(x, path .. '.' .. tostring(k)) end
    elseif v == 'gang_shootout' or v == 'Gang Shootout' or v == 'Desc gang_shootout' then
        leaks[#leaks + 1] = path
    end
end
Walk(fit, 'sizeFit')
H.eq(#leaks, 0, 'sizeFit carries counts only, never mission ids or labels: ' .. table.concat(leaks, ', '))
for _, entry in pairs(fit) do
    local k = {}
    for key in pairs(entry) do k[#k + 1] = key end
    table.sort(k)
    H.eq(table.concat(k, ','), 'now,plusOne', 'each entry is two numbers')
end
u = Unit3()
res = Cb('getUnit', 1)
H.eq(res.data.sizeFit.tactical.now, 3, 'unit of 3 counts at its size')
local sawFour = false
for _, c in ipairs(poolCalls) do if c.n == 4 then sawFour = true end end
H.ok(sawFour, 'and asks CP.Draw.pool one bigger')
H.eq(res.data.unit.members[1].level.n, 1, 'members carry their level')
H.eq(res.data.unit.members[1].avatar.kind, 'initials', 'and an avatar (initials without CP.Profile)')
H.eq(res.data.unit.members[1].avatar.initials, 'JD', 'initials of the name')
CP.Draw.pool = nil
U._reset()

-- ============================================================================
--                 OPERATIONS: LEAVE, REMOVE A JOINER, WAITLIST
-- ============================================================================

H.time = H.time + 1800
Clear()
Config.CrossDept.maxParticipants = 3
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
H.eq(ok, true, 'launch for the waitlist checks')
local opId = data.id
Act('server:joinOperation', 2, opId)
Act('server:joinOperation', 3, opId)
ok, data = Act('server:joinOperation', 4, opId)
H.eq(data.joined, 3, 'three places taken')
ok, data = Act('server:joinOperation', 5, opId)
H.eq(ok, true, 'a join when full goes to the waitlist')
H.eq(data.waitlisted, true, 'waitlisted')
H.eq(data.position, 1, 'first in line')
ok, data = Act('server:joinOperation', 6, opId)
H.eq(data.position, 2, 'second in line')
ok, data = Act('server:joinOperation', 5, opId)
H.eq(data, 'err.op_waitlisted', 'no double waitlist entry')
H.eq(O.boardCard(5).joinBlocked, 'err.op_waitlisted', 'board card knows the viewer waits')
H.eq(O.boardCard(5).waitlistPosition, 1, 'and where')
H.eq(O.boardCard(9).canJoin, true, 'another officer may still queue')
H.eq(O.officerCard(5).waitlistPosition, 1, 'the Unit screen card shows the waitlist place')
H.eq(O.officerCard(2).canLeave, true, 'a joiner may leave before the start')
H.eq(O.officerCard(9), nil, 'no card for someone not in the operation')
res = Cb('sup:getOperation', 1)
H.eq(#res.data.operation.waitlist, 2, 'the panel lists the waitlist')
H.eq(res.data.operation.participants[1].canRemove, true, 'joiners removable before the start')

-- Leave before the start: no penalty, the first on the waitlist takes the place.
Clear()
ok = Act('server:leaveOperation', 3)
H.eq(ok, true, 'leave before the start')
H.ok(HasNote(3, 'officer.op.left'), 'told it costs nothing')
H.eq(#removed, 0, 'no run touched')
local ids = {}
for _, p in ipairs(O.active().participants) do ids[#ids + 1] = p.src end
H.eq(table.concat(ids, ','), '2,4,5', 'the waitlisted officer took the freed place')
H.ok(HasNote(5, 'officer.op.waitlist_promoted'), 'and was told')
H.eq(#O.active().waitlist, 1, 'one still waiting')
ok, data = Act('server:leaveOperation', 3)
H.eq(data, 'err.op_not_joined', 'cannot leave twice')

-- A waitlisted officer who can no longer take a mission is skipped.
Act('server:joinOperation', 9, opId)
H.eq(#O.active().waitlist, 2, 'two waiting (6, 9)')
arena[6] = true
Clear()
Act('server:leaveOperation', 4)
arena[6] = nil
ids = {}
for _, p in ipairs(O.active().participants) do ids[#ids + 1] = p.src end
H.eq(table.concat(ids, ','), '2,5,9', 'the in-arena officer is skipped, the next takes the place')
H.ok(HasNote(6, 'officer.op.waitlist_skipped'), 'the skipped officer is told')
Act('server:joinOperation', 6, opId)

-- Remove a joiner: launchCrossDept, a reason, audited.
Clear()
ok, data = Act('server:sup:opRemoveJoiner', 2, { src = 5, reason = 'x' })
H.eq(data, 'err.no_permission', 'remove needs launchCrossDept')
ok, data = Act('server:admin:opRemoveJoiner', 1, { src = 5, reason = 'x' })
H.eq(data, 'err.no_permission', 'the admin scope needs an admin')
ok, data = Act('server:sup:opRemoveJoiner', 1, { src = 5 })
H.eq(data, 'err.op_reason_required', 'a reason is required')
ok, data = Act('server:sup:opRemoveJoiner', 1, { src = 5, reason = '   ' })
H.eq(data, 'err.op_reason_required', 'a blank reason is refused')
ok, data = Act('server:sup:opRemoveJoiner', 1, { src = 4, reason = 'Not in it' })
H.eq(data, 'err.op_not_joined', 'only joiners can be removed')
ok = Act('server:sup:opRemoveJoiner', 1, { src = 5, reason = 'Needed at the station' })
H.eq(ok, true, 'removed')
local n2 = LastNote(5, 'officer.op.removed_by_supervisor')
H.ok(n2 ~= nil and n2.vars.reason == 'Needed at the station', 'the removed officer gets the reason')
local audit = audits[#audits]
H.eq(audit and audit.action, 'opRemoveJoiner', 'audited')
H.eq(audit and audit.category, 'operations', 'in the operations category')
H.eq(audit and audit.reason, 'Needed at the station', 'with the reason')
H.eq(audit and audit.old, 'Dana Whitfield (CID5)', 'naming the officer')
ids = {}
for _, p in ipairs(O.active().participants) do ids[#ids + 1] = p.src end
H.eq(table.concat(ids, ','), '2,9,6', 'the freed place went to the waitlist')
ok = Act('server:sup:opRemoveJoiner', 9, { src = 6, reason = 'Other duties' })
H.eq(ok, true, 'any supervisor with launchCrossDept may remove')

-- After the start: leaving the operation and removing a joiner are refused; the waitlist closes.
Act('server:joinOperation', 4, opId)
Act('server:joinOperation', 3, opId)
H.eq(#O.active().waitlist, 1, 'one waiting at the start')
Clear()
ok = Act('server:sup:opStart', 1)
H.eq(ok, true, 'operation started')
H.eq(#O.active().waitlist, 0, 'the waitlist closed at the start')
H.ok(HasNote(3, 'officer.op.waitlist_closed'), 'and the waiting officer was told')
ok, data = Act('server:leaveOperation', 2)
H.eq(data, 'err.op_leave_started', 'no leaving the operation after the start')
ok, data = Act('server:sup:opRemoveJoiner', 1, { src = 2, reason = 'Late' })
H.eq(data, 'err.op_remove_started', 'no removing after the start')
H.eq(O.officerCard(2).canLeave, false, 'the Unit screen card has no Leave once started')
O.cancel(0, 'End of the waitlist checks')
Config.CrossDept.maxParticipants = 8

-- Waitlist off: a full operation refuses with err.op_full.
H.time = H.time + 1800
Config.CrossDept.waitlist = false
Config.CrossDept.maxParticipants = 2
ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
Act('server:joinOperation', 2, data.id)
Act('server:joinOperation', 3, data.id)
ok, data = Act('server:joinOperation', 4, data.id)
H.eq(data, 'err.op_full', 'waitlist off: full is full')
H.eq(O.boardCard(4).joinBlocked, 'err.op_full', 'the board card says so')
O.cancel(0, 'End of the waitlist-off check')
Config.CrossDept.waitlist = true
Config.CrossDept.maxParticipants = 8

os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db))
return H
