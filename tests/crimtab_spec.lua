-- The criminal tablet (step G2): CP.CrimTab on the server over CP.Volunteers. Shipped off; who may use it (never on

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local infos = {}             -- [src] = CP.Qbx.getInfo answer
local srcOfCid = {}
local duty, jobs = {}, {}    -- CP.Qbx listeners
CP.Qbx = {
    getInfo = function(src) return infos[src] end,
    onPlayerUnload = function() end,
    onDutyChange = function(fn) duty[#duty + 1] = fn end,
    onJobChange = function(fn) jobs[#jobs + 1] = fn end,
}
CP.Access = {
    departmentForJob = function(name) return name == 'police' and { key = 'sast' } or nil end,
    offDepartmentForJob = function(name) return name == 'offpolice' and 'sast' or nil end,
    isAdmin = function(src) return src == 0 end,
    isSupervisor = function() return false end,
    getOfficer = function(src)
        local i = infos[src]
        if i and i.job and i.job.name == 'police' then return { department = 'sast', gradeLevel = 2 } end
        return nil
    end,
}
local recs = {}
CP.Opponents = {
    eligible = function(src)
        local i = infos[src]
        if i and i.job and i.job.name == 'police' and i.job.onduty then return false, 'on_duty' end
        return true
    end,
    excluded = function() return false end,
    sampleCrew = function() return true end,
    unsampleCrew = function() return true end,
    open = function(run, spec)
        for _, cid in ipairs(spec.members) do
            recs[cid] = { cid = cid, src = srcOfCid[cid], label = 'A', state = 'free' }
        end
        return { runId = run.id, kind = spec.kind }
    end,
    byCid = function(cid)
        if recs[cid] then return {}, recs[cid] end
        return nil
    end,
    setState = function(_, cid, state)
        recs[cid].state = state
        return true
    end,
    timeline = function() return true end,
    selfBlock = function() return false, nil, {} end,
    suspectDayCount = function() return 0 end,
    suspended = function() return false end,
    lastSuspectAt = function() return nil end,
    pairOk = function() return true end,
    note = function() return true end,
    close = function() return {} end,
    recordPairs = function() return 0 end,
    checkPairFlags = function() return {} end,
}
CP.Runs = {
    activeSrcs = function() return { 1 } end,
    endRun = function() end,
    cancelRun = function() return true end,
}
H.players[1] = { coords = vec3(0.0, 0.0, 30.0) }

CP.Blocks.register('crimtab_runner', {
    volunteerSlot = function(_, _, location) return { role = 'runner', meet = location.door } end,
})
local MISSION = {
    id = 'crimtab_m',
    type = 'investigation',
    locations = {
        {
            label = 'Grove Street, Davis',
            start = { coords = vec3(900.0, 0.0, 30.0), radius = 40.0 },
            door = vec3(1000.0, 5.0, 30.0),
        },
    },
    objectives = { { block = 'crimtab_runner' } },
}

H.load('modules/permissions/server.lua')
H.load('modules/volunteers/server.lua')
H.load('modules/volunteers/match/server.lua')
H.load('modules/crimtab/server.lua')
H.step(0)
local V, C, P = CP.Volunteers, CP.CrimTab, CP.Permissions

local function Player(src, cid, job, onduty)
    infos[src] = {
        citizenid = cid,
        license = 'license:' .. cid,
        name = 'Name ' .. src,
        job = { name = job or 'unemployed', onduty = onduty == true },
    }
    H.players[src] = { coords = vec3(2000.0, 0.0, 30.0) }
    srcOfCid[cid] = src
end

local function Get(src)
    H.clockMs = H.clockMs + 1000
    return H.callback('crimson-police:crimtab:get', src, {})
end

-- server:crimtab:act through the net event, as the NUI sends it -> ok, data (the view or the error key)
local seq = 0
local function Act(src, payload)
    H.clockMs = H.clockMs + 1000
    seq = seq + 1
    local id = 'r' .. seq
    H.fire('crimson-police:server:crimtab:act', src, payload, id)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.kind == 'client' and e.name == 'crimson-police:client:actionResult' and e.args[1] == id then
            return e.args[2], e.args[3]
        end
    end
    return nil, 'no reply'
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

-- ============================================================================
--                            SHIPPED: OFF, AS TODAY
-- ============================================================================

do
    local c = Config.CriminalTablet
    H.eq(c.enabled, false, 'the criminal tablet ships off')
    H.eq(c.command, 'crimtab', 'its command is /crimtab')
    H.eq(c.item, false, 'no item opens it')
    H.eq(c.access, 'everyone', 'everyone who is not police may use it once on')
    H.eq(c.replaceCommand, false, 'the volunteer command keeps its menu')
    Player(10, 'CRT00010')
    local r = Get(10)
    H.eq(r.ok, false, 'off: crimtab:get refuses')
    H.eq(r.error, 'err.crimtab_off', 'off: the reason')
    local ok, err = Act(10, { what = 'join', roles = { 'runner' } })
    H.eq(ok, false, 'off: no action')
    H.eq(err, 'err.crimtab_off', 'off: the reason')
end

Config.CriminalTablet.enabled = true

-- ============================================================================
--                                WHO MAY USE IT
-- ============================================================================

do
    Player(11, 'CRT00011', 'police', true)
    H.eq(Get(11).error, 'err.crimtab_on_duty', 'police on duty: never')
    Player(12, 'CRT00012', 'police', false)
    H.eq(Get(12).error, 'err.crimtab_police', 'access \'everyone\': a police job off duty neither')
    Player(13, 'CRT00013', 'offpolice', false)
    H.eq(Get(13).error, 'err.crimtab_police', 'nor an off-duty police job')
    H.eq(Get(99).error, 'err.crimtab_not_loaded', 'no character: refused')
    local r = Get(10)
    H.ok(r.ok and r.data.volunteersOn == false, 'a civilian sees it, with volunteers still off')
    local ok, err = Act(10, { what = 'join', roles = { 'runner' } })
    H.eq(ok, false, 'volunteers off: nobody joins')
    H.eq(err, 'volunteer.refused.off', 'their own refusal text')

    -- 'granted': only the criminalTablet extra grant (Admin UI -> Permissions -> Extra grants)
    H.ok(P.isGrantable('criminalTablet'), 'criminalTablet is a grantable power')
    local keys = table.concat(P.grantableKeys(), ',')
    H.ok(keys:find('criminalTablet', 1, true) ~= nil, 'the Permissions screen lists it')
    Config.CriminalTablet.access = 'granted'
    H.eq(Get(10).error, 'err.crimtab_no_access', '\'granted\': a civilian without the grant is refused')
    Config.Permissions.grants = { criminalTablet = { citizenids = { 'CRT00010', 'CRT00012', 'CRT00011' } } }
    H.ok(Get(10).ok, 'granted by citizenid: he may')
    H.ok(Get(12).ok, 'an off-duty officer with the grant may')
    H.eq(Get(11).error, 'err.crimtab_on_duty', 'but never on duty, grant or not')
    H.eq(#P.actionsFor(10), 0, 'the grant is no supervisor action (no Supervisor UI button)')
    Config.Permissions.grants = {}
    Config.CriminalTablet.access = 'everyone'
end

Config.Volunteers.enabled = true

-- ============================================================================
--                          HOME: ON AND OFF THE LIST
-- ============================================================================

do
    local view = Get(10).data
    H.eq(view.status.listed, false, 'Home: not on the list')
    H.eq(view.status.canJoin, true, 'he may get on it')
    H.eq(view.rules.windowMinutes, 60, 'the rules carry the window')
    H.eq(view.rules.strikes, 3, '...and the strikes')
    local ok, data = Act(10, { what = 'join', roles = { 'runner', 'nobody' } })
    H.ok(ok and data.status.listed, 'join: on the list, the fresh view comes back')
    H.eq(table.concat(data.status.roles, ','), 'runner', 'only real suspects count')
    H.ok(V.isListed('CRT00010'), 'CP.Volunteers has him')
    ok, data = Act(10, { what = 'join', roles = { 'runner' } })
    H.eq(data, 'volunteer.refused.already', 'a second join: the volunteer refusal text')
    ok, data = Act(10, { what = 'roles', roles = {} })
    H.eq(data, 'volunteer.refused.no_role', 'no suspect picked: refused')
    ok, data = Act(10, { what = 'roles', roles = { runner = true, driver = true } })
    H.ok(ok and #data.status.roles == 2, 'roles as a set work too')
    ok = Act(10, { what = 'renew' })
    H.ok(ok, 'renew')
    ok, data = Act(10, { what = 'nope' })
    H.eq(data, 'err.invalid_payload', 'an unknown action is refused')
    ok, data = Act(10, 'join')
    H.eq(data, 'err.invalid_payload', 'a payload that is no table is refused')
end

-- ============================================================================
--                      JOBS: THE QUESTION, ACCEPT, ACTIVE
-- ============================================================================

local run
do
    run = {
        id = 'crt-run-1',
        state = 'accepted',
        mission = MISSION,
        missionType = 'investigation',
        locationIndex = 1,
        location = MISSION.locations[1],
        volunteer = { mode = 'players_when_available', role = 'runner', obj = 1 },
        participants = {},
    }
    CP.Hooks.fire('run:created', run)
    H.step(0)
    H.eq(#ClientEvents('client:volunteerAsk', 10), 1, 'he is asked')
    local view = Get(10).data
    local job = view.jobs[1]
    H.ok(job ~= nil, 'Jobs: the open question')
    H.eq(job and job.role, 'runner', '...its suspect')
    H.eq(job and job.missionType, 'Investigation', '...the mission type label')
    H.eq(job and job.area, 'Grove Street, Davis', '...the area')
    H.eq(job and job.km, 1.0, '...how far the meet point is')
    H.eq(job and job.seconds, 29, '...the time left to answer (a second went by)')
    local allowed = {
        token = true,
        role = true,
        missionType = true,
        area = true,
        km = true,
        seconds = true,
        travelMinutes = true,
    }
    for k in pairs(job or {}) do H.ok(allowed[k], 'a job carries no ' .. k .. ' (no run, officer or position)') end
    H.eq(view.status.canJoin, false, 'listed: no join button')

    local ok, data = Act(10, { what = 'answer', token = 'wrong', yes = true })
    H.eq(data, 'err.crimtab_job_gone', 'a wrong token: the job is gone')
    ok = Act(10, { what = 'answer', token = job.token, yes = true })
    H.ok(ok, 'Accept is the same yes as the pop-up')
    H.step(0)
    view = Get(10).data
    H.eq(#view.jobs, 0, 'no question any more')
    H.eq(view.active and view.active.phase, 'travel', 'Active: travelling')
    H.eq(view.active and view.active.role, 'runner', '...the suspect he plays')
    H.ok(view.active and view.active.meet and view.active.meet.x == 1000.0, '...his own meet point')
    H.eq(view.active and view.active.seconds, 299, '...the time left to get there')
    H.eq(view.active and view.active.freeCancel, true, '...giving up is free right after the yes')
    H.ok(view.active and view.active.graceLeft and view.active.graceLeft > 55 and view.active.graceLeft <= 60,
        'Z2: ...for the grace seconds still left (the tablet counts them down)')
end

-- ============================================================================
--                        GIVING UP, STRIKES AND HISTORY
-- ============================================================================

do
    H.clockMs = H.clockMs + 61000
    local view = Get(10).data
    H.eq(view.active.freeCancel, false, 'after the grace: a strike')
    H.eq(view.active.graceLeft, 0, 'Z2: no grace left')
    local ok = Act(10, { what = 'cancel' })
    H.ok(ok, 'give up')
    view = Get(10).data
    H.eq(view.active, nil, 'no case any more')
    H.eq(#view.strikes, 1, 'History: one strike')
    H.eq(view.strikes[1], os.time() + 24 * 3600, '...counting for strikeHours')
    local _, err = Act(10, { what = 'cancel' })
    H.eq(err, 'volunteer.refused.no_case', 'nothing to give up: refused')

    C.record({
        citizenid = 'CRT00010',
        missionType = 'investigation',
        role = 'runner',
        outcome = 'void',
        dropout = 'cancelled',
        result = 'completed',
        endedAt = os.time(),
    })
    view = Get(10).data
    H.eq(#view.history, 1, 'History: the case')
    H.eq(view.history[1].missionType, 'Investigation', '...its type label')
    H.eq(view.history[1].dropout, 'cancelled', '...and the dropout')
    Config.CriminalTablet.historySize = 2
    for i = 1, 3 do C.record({ citizenid = 'CRT00010', role = 'driver', outcome = 'got_away', endedAt = i }) end
    H.eq(#C.historyOf('CRT00010'), 2, 'History keeps historySize cases')
    H.eq(C.historyOf('CRT00010')[1].endedAt, 3, 'newest first')
    Config.CriminalTablet.historySize = 20
    H.eq(C.record({ role = 'runner' }), false, 'a payload without a citizenid is no line')

    local ok2, data = Act(10, { what = 'stop' })
    H.ok(ok2 and data.status.listed == false, 'stop: off the list')
end

-- ============================================================================
--               THE VOLUNTEER COMMAND, DUTY AND THE SHIPPED MENU
-- ============================================================================

do
    H.events = {}
    H.clockMs = H.clockMs + 3000
    H.fire(CP.e('server:volunteer'), 10, 'open')
    H.eq(#ClientEvents('client:volunteerMenu', 10), 1, 'replaceCommand false: the command keeps its menu')
    H.eq(#ClientEvents('client:crimtabOpen', 10), 0, '...and does not open the tablet')
    Config.CriminalTablet.replaceCommand = true
    H.clockMs = H.clockMs + 3000
    H.fire(CP.e('server:volunteer'), 10, 'open')
    H.eq(#ClientEvents('client:crimtabOpen', 10), 1, 'replaceCommand true: the command opens the tablet')
    H.clockMs = H.clockMs + 3000
    H.fire(CP.e('server:volunteer'), 12, 'open')
    H.eq(#ClientEvents('client:crimtabOpen', 12), 0, 'not for a player who may not use it')
    Config.CriminalTablet.replaceCommand = false

    -- going on police duty closes an open tablet
    Player(20, 'CRT00020', 'police', false)
    infos[20].job.onduty = true
    for _, fn in ipairs(duty) do fn(20, true) end
    H.eq(#ClientEvents('client:crimtabClose', 20), 1, 'on duty: the tablet closes')
    for _, fn in ipairs(duty) do fn(10, true) end
    H.eq(#ClientEvents('client:crimtabClose', 10), 0, 'a civilian is left alone')
end

return H
