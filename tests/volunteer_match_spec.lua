-- Volunteer matching (step V22): the yes/no pop-up one volunteer at a time with its answer checks, the case that opens

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local infos = {}             -- [src] = CP.Qbx.getInfo answer
local eligibleWhy = {}       -- [src] = the CP.Opponents.eligible refusal (intake or not)
local selfBlocked = {}       -- ['<officer src>:<cid>'] = true: that officer is the volunteer's player
CP.Qbx = {
    getInfo = function(src) return infos[src] end,
    onPlayerUnload = function() end,
    onDutyChange = function() end,
    onJobChange = function() end,
}
CP.Access = {
    departmentForJob = function(name) return name == 'police' and { key = 'sast' } or nil end,
    offDepartmentForJob = function() return nil end,
    isAdmin = function() return false end,
}

local recs, opened, states, lines = {}, {}, {}, {}
local srcOfCid = {}
-- the V22b gates: caps, conduct flags, staff notes and pair rows
local caps = { day = {}, suspended = {}, lastSuspect = {}, pair = {} }
local linked = {}            -- [officer src] = true: shares only a connection or PC with the volunteer
local notes, pairRows, closeOut = {}, {}, nil
CP.Opponents = {
    eligible = function(src)
        if eligibleWhy[src] then return false, eligibleWhy[src] end
        return true
    end,
    excluded = function() return false end,
    sampleCrew = function() return true end,
    unsampleCrew = function() return true end,
    open = function(run, spec)
        opened[#opened + 1] = { run = run, spec = spec }
        for _, cid in ipairs(spec.members) do
            recs[cid] = { cid = cid, src = srcOfCid[cid], label = 'A', state = 'free' }
        end
        return { runId = run.id }
    end,
    byCid = function(cid)
        local r = recs[cid]
        if r then return {}, r end
        return nil
    end,
    setState = function(_, cid, state, opts)
        recs[cid].state = state
        states[#states + 1] = { cid = cid, state = state, why = opts and opts.why }
        return true
    end,
    timeline = function(_, e)
        lines[#lines + 1] = e.what
        return true
    end,
    selfBlock = function(officer, list)
        if linked[officer] then return false, nil, { 'rs_linked_accounts' }, { cid = list[1], kinds = { 'ip' } } end
        return selfBlocked[officer .. ':' .. list[1]] == true, nil, {}
    end,
    suspectDayCount = function(cid) return caps.day[cid] or 0 end,
    suspended = function(cid) return caps.suspended[cid] == true end,
    lastSuspectAt = function(cid) return caps.lastSuspect[cid] end,
    pairOk = function(o, sCid)
        local why = caps.pair[o .. '|' .. sCid]
        if why then return false, why end
        return true
    end,
    note = function(_, reason, detail, cid)
        notes[#notes + 1] = { reason = reason, detail = detail, cid = cid }
        return true
    end,
    close = function() if closeOut then return closeOut[1], closeOut[2] end return {} end,
    recordPairs = function(_, rows)
        for _, r in ipairs(rows) do pairRows[#pairRows + 1] = r end
        return #rows
    end,
    checkPairFlags = function() return {} end,
}
local acFlags = {}
CP.AntiCheat = {
    flag = function(run, src, reason, detail)
        acFlags[#acFlags + 1] = { runId = run.id, src = src, reason = reason, detail = detail }
        return true
    end,
}

local dropped, released, ended, toasts = {}, {}, {}, {}
CP.NpcCombat = {
    dropFor = function(run, src, why) dropped[#dropped + 1] = { runId = run.id, src = src, why = why } end,
}
CP.Alerts = {
    releaseRun = function(run) released[#released + 1] = run.id end,
}
CP.Tablet = {
    notifyMany = function(srcs, kind, key)
        for _, s in ipairs(srcs) do toasts[#toasts + 1] = { src = s, kind = kind, key = key } end
    end,
}
local OFFICERS = { 1, 2 }
H.players[1] = { coords = vec3(0.0, 0.0, 30.0) }
H.players[2] = { coords = vec3(5.0, 0.0, 30.0) }

local function Finish(run, state, reason)
    if run.state == 'ended' then return end
    run.state = 'ended'
    ended[#ended + 1] = { runId = run.id, state = state, reason = reason }
    CP.Hooks.fire('run:ended', run, state, reason)
end
CP.Runs = {
    activeSrcs = function(run) return run.officers or OFFICERS end,
    endRun = function(run, state, reason) Finish(run, state, reason) end,
    cancelRun = function(run, reason)
        Finish(run, 'abandoned', reason)
        return true
    end,
}

-- one mission whose second objective offers the runner at the door
local DOOR = vec3(1000.0, 5.0, 30.0)
CP.Blocks.register('vmatch_runner', {
    volunteerSlot = function(_, _, location) return { role = 'runner', meet = location.door } end,
})
CP.Blocks.register('vmatch_plain', {})
local WARRANT = {
    id = 'warrant_m',
    type = 'investigation',
    locations = { { label = 'L1', start = { coords = vec3(900.0, 0.0, 30.0), radius = 40.0 }, door = DOOR } },
    objectives = { { block = 'vmatch_plain' }, { block = 'vmatch_runner' } },
}

H.load('modules/volunteers/server.lua')
H.load('modules/volunteers/match/server.lua')
H.step(0)
local V = CP.Volunteers

local function Civilian(src, cid, coords)
    infos[src] = { citizenid = cid, license = 'license:' .. cid, name = 'Civ ' .. src, job = { name = 'unemployed' } }
    H.players[src] = { coords = coords or vec3(2000.0, 0.0, 30.0) }
    srcOfCid[cid] = src
end

local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end
local function LastAsk(src)
    local list = ClientEvents('client:volunteerAsk', src)
    local e = list[#list]
    return e and e.args[1], e and e.args[2]
end
local function LastNote(src)
    local list = ClientEvents('client:volunteerNote', src)
    local e = list[#list]
    return e and e.args[2]
end
local function LastCase(src)
    local list = ClientEvents('client:volunteerCase', src)
    return list[#list] and list[#list].args[1]
end
local function Answer(src, token, yes)
    H.clockMs = H.clockMs + 600    -- the 4-in-2-s rate limit; no thread wakes
    H.fire(CP.e('server:volunteer'), src, 'answer', { token = token, yes = yes })
end
local function Toast(key)
    for _, t in ipairs(toasts) do if t.key == key then return true end end
    return false
end
local function Has(list, what)
    for _, v in ipairs(list) do if v == what then return true end end
    return false
end

local runN = 0
local function NewRun(mode, opts)
    runN = runN + 1
    local run = {
        id = 'vm-run-' .. runN,
        state = 'accepted',
        mission = WARRANT,
        locationIndex = 1,
        location = WARRANT.locations[1],
        volunteer = { mode = mode or 'players_when_available', role = 'runner', obj = 2 },
        officers = opts and opts.officers or nil,
    }
    CP.Hooks.fire('run:created', run)
    H.step(0)
    return run
end
local function Reset()
    H.events, toasts, dropped, released, ended, states, lines, opened = {}, {}, {}, {}, {}, {}, {}, {}
    recs = {}
end
local RUNNER = { runner = true }

-- ============================================================================
--                          SHIPPED: NOTHING IS ASKED
-- ============================================================================

do
    local c = Config.Volunteers
    H.eq(c.askSeconds, 30, 'the pop-up waits 30 s')
    H.eq(c.askTries, 3, 'three volunteers asked at most')
    H.eq(c.travelSeconds, 300, 'five minutes to reach the starting point')
    H.eq(c.meetRadius, 25.0, '25 m counts as in position')
    H.eq(c.cancelGraceSeconds, 60, 'a cancel in the first minute is free')
    H.eq(c.onVoid, 'npc', 'a volunteer who drops out gives the NPC back')
    H.eq(c.voidRun, 'cancelled', 'a mission that ends that way is cancelled')
    Civilian(10, 'VMA00001')
    local run = NewRun()
    H.eq(#ClientEvents('client:volunteerAsk'), 0, 'enabled off: nobody is asked')
    H.eq(V.matchView(run, 2), nil, 'and ctx.volunteer() has nothing')
    H.eq(run.realSuspect, nil, 'the run stays an NPC run')
end

Config.Volunteers.enabled = true

-- ============================================================================
--                     ASKING: ONE AT A TIME, NO, NO ANSWER
-- ============================================================================

do
    Reset()
    Civilian(10, 'VMA00001')
    Civilian(11, 'VMA00002')
    H.ok(V.join(10, RUNNER), 'the first volunteer joins')
    H.clockMs = H.clockMs + 1000
    H.ok(V.join(11, { runner = true, driver = true }), 'the second joins later')
    local run = NewRun()
    local token, info = LastAsk(10)
    H.ok(token ~= nil, 'the oldest volunteer is asked first')
    H.eq(LastAsk(11), nil, 'one at a time')
    H.eq(info and info.role, 'runner', 'the pop-up names the suspect')
    H.eq(info and info.seconds, 30, 'and how long it waits')
    H.eq(info and info.travelMinutes, 5, 'and the time to get there')
    H.eq(info and info.km, 1.0, 'and how far the starting point is (server coords)')
    H.eq(V.matchView(run, 2).phase, 'asking', 'ctx.volunteer(): asking')
    H.eq(V.matchView(run, 1), nil, 'another objective sees no volunteer')
    H.eq(V.reservedFor(run.id), 'VMA00001', 'the volunteer asked is held for the run')
    H.eq(#V.available(RUNNER), 1, 'nobody else counts on him meanwhile')

    Answer(10, 'wrong', true)
    H.eq(#opened, 0, 'a wrong token is ignored')
    Answer(11, token, true)
    H.eq(#opened, 0, 'another player answering his question is ignored')

    Answer(10, token, false)
    H.eq(LastNote(10), 'volunteer.ask.declined', 'a no is acknowledged')
    H.eq(V.strikes('VMA00001'), 0, 'a no is never a strike')
    local token2 = LastAsk(11)
    H.ok(token2 ~= nil and token2 ~= token, 'the next volunteer is asked with a new question')
    H.advance(34000, 1000)
    H.eq(#ClientEvents('client:volunteerAskClose', 11), 1, 'no answer: his pop-up is closed')
    H.eq(V.strikes('VMA00002'), 0, 'no answer is no strike')
    H.eq(V.matchView(run, 2).phase, 'npc', 'nobody said yes: the NPC plays the suspect')
    H.ok(Toast('volunteer.officer.npc'), 'the officers are told an NPC plays him')
    H.eq(run.realSuspect, nil, 'still an NPC run')
    H.eq(#ended, 0, 'players_when_available goes on with the NPC')
    H.eq(V.reservedFor(run.id), nil, 'nobody is held any more')
    Answer(11, token2, true)
    H.eq(#opened, 0, 'an answer after that is ignored')
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
end

-- ============================================================================
--                                    A YES
-- ============================================================================
-- THE CASE, TRAVEL, IN POSITION, ENGAGED AND THE RELEASE.

do
    Reset()
    local run = NewRun()
    local token = LastAsk(10)
    Answer(10, token, true)
    H.step(0)
    H.eq(#opened, 1, 'a yes opens his case')
    local spec = opened[1] and opened[1].spec or {}
    H.eq(spec.kind, 'volunteer', 'of kind volunteer')
    H.eq(spec.index, 2, 'on the slot objective')
    H.eq(spec.members and spec.members[1], 'VMA00001', 'with him as the suspect')
    H.eq(spec.meet, DOOR, 'and the slot\'s meet point')
    H.eq(run.realSuspect, 'volunteer', 'run.realSuspect = volunteer')
    H.eq(released[1], run.id, 'the officers\' arena flags are released (CP.Alerts.releaseRun)')
    H.ok(Toast('volunteer.officer.yes'), 'the officers are told a real player plays the suspect')
    H.ok(Has(lines, 'volunteer_yes'), 'staff timeline: the yes')
    local case = LastCase(10)
    H.eq(case and case.phase, 'travel', 'he travels')
    H.eq(case and case.meet and case.meet.x, 1000.0, 'to the meet point (his own waypoint)')
    H.eq(case and case.seconds, 300, 'within travelSeconds')
    local view = V.matchView(run, 2)
    H.eq(view.phase, 'travel', 'ctx.volunteer(): travel')
    H.eq(view.real, true, 'a real player plays him')
    H.eq(view.label, 'A', 'by his case label')
    H.eq(view.cid, nil, 'never his citizenid')
    H.eq(view.src, nil, 'never his server id')

    -- the volunteer menu shows the case
    H.clockMs = H.clockMs + 2000
    H.fire(CP.e('server:volunteer'), 10, 'open')
    local menus = ClientEvents('client:volunteerMenu', 10)
    local menu = menus[#menus] and menus[#menus].args[1]
    H.eq(menu and menu.case and menu.case.role, 'runner', 'his menu offers Cancel this case')

    H.players[10].coords = vec3(1010.0, 5.0, 30.0)
    H.advance(1000, 1000)
    H.eq(V.matchView(run, 2).phase, 'in_position', 'within meetRadius: in position')
    H.eq(LastNote(10), 'volunteer.case.in_position', 'he is told')
    H.ok(Has(lines, 'in_position'), 'staff timeline: in position')
    H.eq(#dropped, 0, 'no protection drop before an officer reached him')

    H.advance(400000, 1000)
    H.eq(V.strikes('VMA00001'), 0, 'in position: no no-show however long the officers take')

    recs.VMA00001.contactAt = H.clockMs
    H.advance(1000, 1000)
    H.eq(V.matchView(run, 2).phase, 'engaged', 'first contact: engaged')
    H.eq(#dropped, 2, 'both officers lose the NPC-combat protection')
    H.eq(dropped[1] and dropped[1].why, 'volunteer', 'through CP.NpcCombat.dropFor')
    H.ok(Has(lines, 'engaged'), 'staff timeline: engaged')
    CP.Hooks.fire('participant:joined', run, 3)
    H.eq(dropped[3] and dropped[3].src, 3, 'an officer who joins later loses it too')

    -- the window never runs out mid-case
    H.clockMs = H.clockMs + 1
    V._sweep()
    H.ok(V.isListed('VMA00001'), 'his listing is not ended by the window while he plays')

    Finish(run, 'completed', 'completed')
    H.eq(LastNote(10), 'volunteer.case.released', 'the run ends: he is released')
    H.eq(LastCase(10).phase, 'over', 'his waypoint goes')
    H.eq(V.matchView(run, 2), nil, 'nothing left of the match')
    H.eq(V.reservedFor(run.id), nil, 'nor of the hold')
end

-- ============================================================================
--                 WITH RealSuspects.npcCombat = TRUE: NO DROP
-- ============================================================================

do
    Reset()
    Config.RealSuspects.npcCombat = true
    V._sweep()
    local run = NewRun()
    Answer(10, LastAsk(10), true)
    H.step(0)
    recs.VMA00001.contactAt = H.clockMs
    H.advance(1000, 1000)
    H.eq(V.matchView(run, 2).phase, 'engaged', 'engaged')
    H.eq(#dropped, 0, 'npcCombat = true: the officers keep the protection')
    Config.RealSuspects.npcCombat = false
    Finish(run, 'completed', 'completed')
end

-- ============================================================================
--               ANSWER CHECKS: LATE, NO LONGER FIT, OWN OFFICER
-- ============================================================================

do
    Reset()
    local run = NewRun()
    local token = LastAsk(10)
    H.clockMs = H.clockMs + 33000   -- past the 30 s and the 2 s lag, before the tick runs
    H.fire(CP.e('server:volunteer'), 10, 'answer', { token = token, yes = true })
    H.eq(LastNote(10), 'volunteer.ask.too_late', 'a late yes is refused')
    H.eq(#opened, 0, 'and opens nothing')
    Finish(run, 'abandoned', 'cancelled')

    Reset()
    run = NewRun()
    token = LastAsk(10)
    eligibleWhy[10] = 'down'
    Answer(10, token, true)
    H.step(0)
    H.eq(LastNote(10), 'volunteer.ask.not_now', 'a yes from a volunteer who no longer fits (down) is refused')
    H.eq(#opened, 0, 'no case')
    H.ok(LastAsk(11) ~= nil, 'the next volunteer is asked')
    eligibleWhy[10] = nil
    Finish(run, 'abandoned', 'cancelled')

    Reset()
    selfBlocked['2:VMA00001'] = true
    run = NewRun()
    H.eq(LastAsk(10), nil, 'a volunteer who is one of the officers\' own players is never asked')
    H.ok(LastAsk(11) ~= nil, 'the next one is')
    selfBlocked['2:VMA00001'] = nil
    Finish(run, 'abandoned', 'cancelled')
end

-- ============================================================================
--                   NO-SHOW, CANCEL AND LEAVING: THE ENDINGS
-- ============================================================================

do
    -- a no-show: a strike, his suspect is void, the NPC plays (players_when_available, onVoid 'npc')
    Reset()
    H.players[10].coords = vec3(2000.0, 0.0, 30.0)
    local run = NewRun()
    Answer(10, LastAsk(10), true)
    H.step(0)
    H.advance(301000, 1000)
    H.eq(V.strikes('VMA00001'), 1, 'a no-show is a strike')
    H.eq(states[1] and states[1].state, 'void', 'his suspect counts for nobody')
    H.eq(states[1] and states[1].why, 'volunteer_no_show', 'why: no-show')
    H.ok(Has(lines, 'no_show'), 'staff timeline: the no-show')
    H.eq(LastNote(10), 'volunteer.case.no_show', 'he is told')
    H.eq(V.matchView(run, 2).phase, 'npc', 'onVoid npc: the NPC plays the suspect')
    H.eq(#ended, 0, 'and the run goes on')
    Finish(run, 'completed', 'completed')

    -- Cancel this case within the grace: free
    Reset()
    run = NewRun()
    Answer(10, LastAsk(10), true)
    H.step(0)
    H.advance(10000, 1000)
    H.fire(CP.e('server:volunteer'), 10, 'cancel')
    H.eq(V.strikes('VMA00001'), 1, 'a cancel right after the yes is no strike')
    H.eq(LastNote(10), 'volunteer.case.cancelled', 'he is told it is cancelled')
    H.ok(Has(lines, 'volunteer_cancel'), 'staff timeline: the cancel')
    H.eq(V.matchView(run, 2).phase, 'npc', 'the NPC plays the suspect')
    Finish(run, 'completed', 'completed')

    -- onVoid 'end' + a cancel after the grace: a strike and the run is cancelled
    Reset()
    Config.Volunteers.onVoid = 'end'
    run = NewRun()
    Answer(10, LastAsk(10), true)
    H.step(0)
    H.advance(61000, 1000)
    H.clockMs = H.clockMs + 600
    H.fire(CP.e('server:volunteer'), 10, 'cancel')
    H.step(0)
    H.eq(V.strikes('VMA00001'), 2, 'a cancel after the grace is a strike')
    H.eq(ended[1] and ended[1].reason, 'cancelled', 'onVoid end: the run is cancelled (no cooldown, penalty or pay)')
    H.ok(Toast('volunteer.officer.void_end'), 'the officers are told why')
    Config.Volunteers.onVoid = 'npc'

    -- after the engagement a leave always ends it: voidRun 'keep_earned' = completed
    Reset()
    Config.Volunteers.voidRun = 'keep_earned'
    run = NewRun()
    Answer(10, LastAsk(10), true)
    H.step(0)
    recs.VMA00001.contactAt = H.clockMs
    H.advance(1000, 1000)
    recs.VMA00001.state = 'left'
    H.advance(1000, 1000)
    H.step(0)
    H.eq(V.strikes('VMA00001'), 0, 'three strikes blocked him: the count started again')
    H.eq(ended[1] and ended[1].state, 'completed', 'after contact a leave ends the run; keep_earned = completed')
    Config.Volunteers.voidRun = 'cancelled'
end

-- ============================================================================
--                                 PLAYERS_ONLY
-- ============================================================================

do
    Reset()
    Civilian(12, 'VMA00003')
    H.ok(V.join(12, RUNNER), 'a third volunteer')
    H.ok(V.join(11, RUNNER) == false, 'the second is still listed')
    -- the accept held VMA00003 (V21): he is asked first
    V.reserve('pending-1', WARRANT, 1)
    local held = V.reservedFor('pending-1')
    runN = runN + 1
    local id = 'vm-run-' .. runN
    V.rekey('pending-1', id)
    local run = {
        id = id,
        state = 'accepted',
        mission = WARRANT,
        locationIndex = 1,
        location = WARRANT.locations[1],
        volunteer = { mode = 'players_only', role = 'runner', obj = 2 },
    }
    CP.Hooks.fire('run:created', run)
    H.step(0)
    H.ok(held ~= nil and LastAsk(srcOfCid[held]) ~= nil, 'the volunteer the accept held is asked first')
    Answer(srcOfCid[held], LastAsk(srcOfCid[held]), false)
    H.step(0)
    -- the remaining ones say nothing
    H.advance(70000, 1000)
    H.step(0)
    H.eq(ended[1] and ended[1].reason, 'cancelled', 'players_only and nobody said yes: the run is cancelled')
    H.eq(V.matchView(run, 2), nil, 'and the match is gone')
end

-- ============================================================================
--                                  THE GATES
-- ============================================================================
-- (V22b): CAPS, CONDUCT FLAGS, STAFF NOTES, PAIR ROWS.

do
    Reset()
    for _, v in ipairs(V.list()) do V.stop(v.src) end
    Civilian(20, 'VMG00001')
    H.ok(V.join(20, RUNNER), 'a volunteer for the gates')
    local P = { [1] = { citizenid = 'OFG00001' }, [2] = { citizenid = 'OFG00002' } }
    local probe = { id = 'probe', participants = P, officers = OFFICERS }
    H.eq(V.capsOk(probe, 'VMG00001'), true, 'no cap reached: he may play it')
    caps.day.VMG00001 = 2
    H.eq(select(2, V.capsOk(probe, 'VMG00001')), 'suspect_used', 'maxCatchesPerSuspectDay reached')
    caps.day.VMG00001 = nil
    caps.suspended.OFG00002 = true
    H.eq(select(2, V.capsOk(probe, 'VMG00001')), 'officer_suspended', 'an officer suspended from these cases')
    caps.suspended.OFG00002 = nil
    caps.lastSuspect.OFG00001 = os.time() - 60
    H.eq(select(2, V.capsOk(probe, 'VMG00001')), 'officer_recent_suspect', 'an officer was a suspect within jobHop')
    caps.lastSuspect.OFG00001 = nil
    caps.pair['OFG00001|VMG00001'] = 'blocked'
    H.eq(select(2, V.capsOk(probe, 'VMG00001')), 'pair_blocked', 'an admin pair block')
    caps.pair['OFG00001|VMG00001'] = 'suspect_cooldown'
    H.eq(select(2, V.capsOk(probe, 'VMG00001')), 'pair_cooldown', 'a recent case of the pair')
    caps.pair['OFG00001|VMG00001'] = nil

    -- a cap reached: he is never asked, the NPC plays the suspect
    caps.day.VMG00001 = 2
    runN = runN + 1
    local run = {
        id = 'vm-run-' .. runN,
        state = 'accepted',
        mission = WARRANT,
        locationIndex = 1,
        location = WARRANT.locations[1],
        volunteer = { mode = 'players_when_available', role = 'runner', obj = 2 },
        participants = P,
    }
    CP.Hooks.fire('run:created', run)
    H.step(0)
    H.eq(LastAsk(20), nil, 'a suspect who scored his catches today is not asked')
    H.eq(V.matchView(run, 2).phase, 'npc', 'the NPC plays him')
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    H.eq(#pairRows, 0, 'no yes: no pair rows')
    caps.day.VMG00001 = nil

    -- a yes: the linked-accounts flag on the officer who shares a connection
    Reset()
    notes, acFlags = {}, {}
    linked[2] = true
    runN = runN + 1
    run = {
        id = 'vm-run-' .. runN,
        state = 'accepted',
        mission = WARRANT,
        locationIndex = 1,
        location = WARRANT.locations[1],
        volunteer = { mode = 'players_when_available', role = 'runner', obj = 2 },
        participants = P,
    }
    CP.Hooks.fire('run:created', run)
    H.step(0)
    Answer(20, LastAsk(20), true)
    H.step(0)
    H.eq(run.realSuspect, 'volunteer', 'he plays it')
    H.eq(#acFlags, 1, 'one officer-conduct flag')
    H.eq(acFlags[1] and acFlags[1].src, 2, 'on the officer who shares a connection or PC')
    H.eq(acFlags[1] and acFlags[1].reason, 'rs_linked_accounts', 'rs_linked_accounts (his points wait for review)')
    linked[2] = nil

    -- no-show: a staff note besides the strike
    H.advance(301000, 1000)
    H.step(0)
    H.eq(notes[1] and notes[1].reason, 'rs_volunteer_dropout', 'a no-show is a staff note')
    H.eq(notes[1] and notes[1].cid, 'VMG00001', 'about him')

    -- the pair rows at the end: nobody reached him = 'gone' (never a cap)
    closeOut = {
        { VMG00001 = 'void' },
        { kind = 'volunteer', order = { 'VMG00001' }, suspects = { VMG00001 = { license = 'license:VMG00001' } } },
    }
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    H.eq(#pairRows, 2, 'one pair row per officer')
    H.eq(pairRows[1] and pairRows[1].kind, 'volunteer', 'of kind volunteer')
    H.eq(pairRows[1] and pairRows[1].outcome, 'gone', 'nobody reached him: gone')
    H.eq(pairRows[1] and pairRows[1].scored, false, 'and nothing scored')

    -- detained after contact in a completed run: scored
    pairRows = {}
    closeOut = {
        { VMG00001 = 'detained' },
        { kind = 'volunteer', order = { 'VMG00001' }, suspects = { VMG00001 = { contactAt = 1, share = 1 } } },
    }
    H.eq(V._recordPairs({ engagedAt = 5 }, { id = 'r', participants = P }, 'completed'), 2, 'two rows')
    H.eq(pairRows[1].outcome, 'detained', 'the outcome')
    H.eq(pairRows[1].scored, true, 'scored')
    pairRows = {}
    V._recordPairs({ engagedAt = 5 }, { id = 'r', participants = P }, 'abandoned')
    H.eq(pairRows[1].scored, false, 'a run that did not complete scores nothing')
    closeOut = nil
end

-- ============================================================================
--                 AN AFK CATCH IS A VOID (V23, afkCatchVoids)
-- ============================================================================

do
    H.eq(Config.Volunteers.afkCatchVoids, true, 'an AFK catch voids his part (ships true)')
    H.eq(Config.Volunteers.doorAssociates, false, 'no armed associate while a volunteer plays the door (ships false)')
    for _, v in ipairs(V.list()) do V.stop(v.src) end
    Civilian(20, 'VMA00020')
    H.clockMs = H.clockMs + 2000
    H.ok(V.join(20, RUNNER), 'a fresh volunteer joins')
    local function Caught(share)
        Reset()
        local run = NewRun()
        Answer(20, LastAsk(20), true)
        H.step(0)
        recs.VMA00020.contactAt = H.clockMs
        H.advance(1000, 1000)
        recs.VMA00020.state, recs.VMA00020.share = 'detained', share
        H.advance(1000, 1000)
        H.step(0)
        return run
    end
    local run = Caught(0)
    H.eq(V.strikes('VMA00020'), 1, 'caught while AFK: a strike')
    H.eq(states[1] and states[1].state, 'void', 'his suspect counts for nobody')
    H.eq(states[1] and states[1].why, 'volunteer_afk', 'why: afk')
    H.ok(Has(lines, 'volunteer_afk'), 'staff timeline: the AFK catch')
    H.eq(LastNote(20), 'volunteer.case.afk', 'he is told')
    H.eq(ended[1] and ended[1].reason, 'cancelled', 'officers had reached him: the run ends as voidRun says')
    H.eq(run.state, 'ended', 'the run is over')

    Config.Volunteers.afkCatchVoids = false
    run = Caught(0)
    H.eq(#states, 0, 'afkCatchVoids false: the AFK catch stands')
    H.eq(V.matchView(run, 2).phase, 'engaged', 'and the case goes on')
    Finish(run, 'completed', 'completed')
    Config.Volunteers.afkCatchVoids = true

    run = Caught(1)
    H.eq(#states, 0, 'a catch with a share is never a void')
    Finish(run, 'completed', 'completed')
end

-- ============================================================================
--                     ctx.volunteer() IN THE ENGINE'S CTX
-- ============================================================================

do
    local f = io.open('Crimson-Police/modules/runs/server.lua', 'r')
    local src = f and f:read('a') or ''
    if f then f:close() end
    H.ok(src:find('ctx.volunteer = function()', 1, true) ~= nil, 'every block ctx has ctx.volunteer()')
    H.ok(src:find('V.matchView, run, i', 1, true) ~= nil, 'it answers CP.Volunteers.matchView for its objective')
end

return H
