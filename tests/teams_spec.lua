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

os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db))
return H
