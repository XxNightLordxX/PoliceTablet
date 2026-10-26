-- Police vs real criminal players, step V9: the NPC-mission Hard rules 15-18 bent for cases with a real suspect
-- (run.realSuspect), each a Config.RealSuspects choice, and Config.LiveCrime.requireRoute for live crimes. Nothing
-- sets run.realSuspect or run.live yet (V14, V22), so every run here is a fake run.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ============================================================================
--                      NATIVES THE HARNESS DOES NOT HAVE
-- ============================================================================

GetPlayerRoutingBucket = function() return 0 end
local bagHandlers = {}
AddStateBagChangeHandler = function(key, bagName, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, bagName = bagName, fn = fn }
    return #bagHandlers
end
GetPlayerFromStateBagName = function(name) return tonumber(tostring(name):match('^player:(%d+)$')) or 0 end

local function PlayerRec(src)
    local p = H.players[src]
    if not p then p = {}; H.players[src] = p end
    p.state = p.state or {}
    return p
end

local function BagSet(src, key, value)
    local p = PlayerRec(src)
    for _, h in ipairs(bagHandlers) do
        if h.key == nil or h.key == key then h.fn(('player:%d'):format(src), key, value, 0, true) end
    end
    p.state[key] = value
end

Player = function(src)
    src = tonumber(src)
    local st = PlayerRec(src).state
    return {
        state = setmetatable({
            set = function(_, k, v) BagSet(src, k, v) end,
        }, { __index = st }),
    }
end
GetPlayerName = function(src) return 'Player' .. tostring(src) end

local function Bag(src) return PlayerRec(src).state.crimsonArena end
local function Ours(src)
    local v = Bag(src)
    return type(v) == 'table' and v.active == true and v.source == 'crimson-police'
end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local runs = {}
local rlog = { arrived = {}, removed = {} }

local function ActiveOf(r)
    local out = {}
    for s, p in pairs(r.participants) do if p.status == 'active' then out[#out + 1] = s end end
    table.sort(out)
    return out
end

CP.Runs = {
    get = function(id) return runs[id] end,
    all = function()
        local out = {}
        for _, r in pairs(runs) do if r.state ~= 'ended' then out[#out + 1] = r end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    getBySrc = function(src)
        for _, r in pairs(runs) do
            local p = r.state ~= 'ended' and r.participants[src] or nil
            if p and p.status == 'active' then return r, p end
        end
        return nil
    end,
    activeSrcs = ActiveOf,
    markArrived = function(r, src)               -- the engine's markArrived: arrived, then CP.Alerts.set
        rlog.arrived[#rlog.arrived + 1] = { run = r.id, src = src }
        r.participants[src].arrived = true
        CP.Alerts.set(src, r)
    end,
    removeParticipant = function(r, src, reason, opts)
        rlog.removed[#rlog.removed + 1] = {
            run = r.id,
            src = src,
            reason = reason,
            keepFlag = opts and opts.keepFlag or false,
            at = H.clockMs,
        }
        local p = r.participants[src]
        if p.status ~= 'active' then return nil end
        p.status, p.endReason = 'left', reason
        if not (opts and opts.keepFlag) then CP.Alerts.clear(src) end
        CP.Route.stop(r, src)
        if #ActiveOf(r) == 0 then r.state = 'ended' end
    end,
    endRun = function(r) r.state = 'ended' end,
    anchor = function(r) return r.anchor end,
    extendStart = function() return nil end,
    actionPoints = function() return {} end,
}

local function NewRun(id, o)
    local r = {
        id = id,
        missionId = 'test_mission',
        state = o.state or 'accepted',
        test = o.test,
        realSuspect = o.realSuspect,
        live = o.live,
        location = { start = { coords = o.start or vec3(1000.0, 0.0, 0.0), radius = 50.0 } },
        participants = {},
        stats = { downs = 0 },
    }
    for _, s in ipairs(o.srcs) do
        r.participants[s] = { src = s, citizenid = 'CID' .. s, status = 'active', arrived = o.arrived or false }
    end
    runs[id] = r
    return r
end

local function RemovedFor(src)
    local out = {}
    for _, e in ipairs(rlog.removed) do if e.src == src then out[#out + 1] = e end end
    return out
end
local function Arrived(src)
    for _, e in ipairs(rlog.arrived) do if e.src == src then return true end end
    return false
end

-- CP.Opponents: the case of a run (its suspects' server ids) and nearAny over the watch's last positions
local cases = {}
CP.Opponents = {
    caseOf = function(run) return cases[type(run) == 'table' and run.id or run] end,
    nearAny = function(run, coords, range)
        local case = cases[run.id]
        for cid, rec in pairs(case and case.suspects or {}) do
            if rec.src and rec.coords and CP.U.dist(coords, rec.coords) <= range then return true, cid end
        end
        return false
    end,
}

-- CP.Dispatch
local dl = { responding = {}, cleared = {}, restart = {}, shots = {}, down = {}, dead = {} }
local activeCalls = {}
local clears = {}
local function Emit(kind, ...)
    local args = table.pack(...)
    for _, fn in ipairs(dl[kind]) do CreateThread(function() fn(table.unpack(args, 1, args.n)) end) end
end
CP.Dispatch = {
    normalizeCallId = function(id)
        if type(id) == 'number' then return ('%d'):format(math.tointeger(id) or 0) end
        if id == nil then return '' end
        return tostring(id)
    end,
    lookupActiveCall = function(id) return activeCalls[tostring(id)] end,
    clearNotification = function(id, jobs) clears[#clears + 1] = { id = id, jobs = jobs } end,
    onResponding = function(fn) dl.responding[#dl.responding + 1] = fn end,
    onCallCleared = function(fn) dl.cleared[#dl.cleared + 1] = fn end,
    onDispatchRestart = function(fn) dl.restart[#dl.restart + 1] = fn end,
    onShotsFired = function(fn) dl.shots[#dl.shots + 1] = fn end,
    onPlayerDown = function(fn) dl.down[#dl.down + 1] = fn end,
    onPlayerDead = function(fn) dl.dead[#dl.dead + 1] = fn end,
}

local downed = {}
CP.Qbx = {
    isDowned = function(src) return downed[src] == true end,
    getInfo = function(src) return { src = src, inLastStand = downed[src] == true } end,
    onPlayerUnload = function() end,
    onMetaDataChange = function() end,
}
local ems = { doctors = 0 }
CP.Ambulance = {
    doctorCount = function() return ems.doctors end,
    revive = function() return true end,
}
local notes = {}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, key = key, vars = vars } end,
}
CP.Admin = { audit = function() end }

local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end

H.load('modules/alerts/server.lua')
H.load('modules/route/server.lua')
H.load('modules/calls/server.lua')
H.load('modules/downed/server.lua')
H.step(0)

local function RunFor(ms, each, stepMs)
    local target = H.clockMs + ms
    while H.clockMs < target do
        H.step(stepMs or 100)
        if each then each(H.clockMs) end
    end
end
local function AlignTo(m) while H.clockMs % m ~= 0 do H.step(100) end end
local function Reporter(src, runId, metres)
    return function(c)
        if c % 2000 == 0 then H.fire(CP.e('server:routeStatus'), src, runId, metres, PlayerRec(src).coords) end
    end
end

local RS = Config.RealSuspects
H.eq(RS.officerAlerts, 'normal', 'officerAlerts ships normal (the officers\' own calls go out)')
H.eq(RS.routeEnds, 'first_contact', 'routeEnds ships first_contact')
H.eq(RS.downed, 'keep_earned', 'downed ships keep_earned')
H.eq(RS.downedPickupDelay, 400, 'downedPickupDelay ships 400 s (sc-ambulance\'s DeathTime)')
H.eq(RS.npcCombat, false, 'npcCombat ships false')
H.eq(Config.LiveCrime.requireRoute, false, 'requireRoute ships false (officers on a live case may chase)')

-- ============================================================================
--           ALERTS (Hard rule 16, Config.RealSuspects.officerAlerts)
-- ============================================================================

do
    local live = NewRun('rs-al-live', { srcs = { 1, 2 }, realSuspect = 'live', state = 'in_progress' })
    CP.Runs.markArrived(live, 1)
    H.eq(Bag(1), nil, 'normal: markArrived on a case with a real suspect writes no flag')
    H.eq(CP.Alerts.has(1), false, 'normal: and keeps no intent')
    H.eq(CP.Alerts.set(1, live.id), false, 'normal: set by run id refuses too')

    RS.officerAlerts = 'silenced'
    CP.Runs.markArrived(live, 2)
    H.ok(Ours(2) and CP.Alerts.has(2), 'silenced: markArrived writes the flag (the NPC-mission rule)')
    H.eq(CP.Alerts.set(9, live), false, 'silenced: a non-participant (the suspect) never gets the flag')
    H.eq(Bag(9), nil, '...nothing written for him')
    H.eq(CP.Alerts.releaseRun(live), 0, 'silenced: releaseRun leaves the flags alone')
    RS.officerAlerts = 'normal'

    local npc = NewRun('rs-al-npc', { srcs = { 3 }, state = 'in_progress' })
    CP.Runs.markArrived(npc, 3)
    H.ok(Ours(3) and CP.Alerts.has(3), 'a run without a real suspect: the flag as today')
    H.eq(CP.Alerts.releaseRun(npc), 0, 'releaseRun does nothing on a run without a real suspect')
    H.ok(Ours(3), '...the flag stays')

    -- a volunteer says yes after an officer arrived: his flag goes and is not put back
    local vol = NewRun('rs-al-vol', { srcs = { 4 }, state = 'in_progress' })
    CP.Runs.markArrived(vol, 4)
    H.ok(Ours(4), 'arrived before the volunteer said yes: flagged')
    vol.realSuspect = 'volunteer'
    H.eq(CP.Alerts.releaseRun(vol), 1, 'releaseRun clears one flag')
    H.eq(Bag(4), nil, 'the flag is gone')
    H.eq(CP.Alerts.has(4), false, 'and the intent')
    RunFor(3000)
    H.eq(Bag(4), nil, 'the reconcile does not put it back')
    H.eq(CP.Alerts.set(4, vol), false, 'a later set refuses')

    -- the backstop leaves the calls of a case with a real suspect alone
    PlayerRec(1).coords = vec3(1000.0, 0.0, 0.0)
    PlayerRec(2).coords = vec3(1000.0, 0.0, 0.0)
    live.participants[1].arrived = true
    local before = #clears
    Emit('shots', 1, nil, H.time)
    RunFor(3000)
    H.eq(#clears, before, 'normal: an officer\'s shots-fired call on the case is not cleared')
    RS.officerAlerts = 'silenced'
    Emit('shots', 2, nil, H.time)
    RunFor(3000)
    H.ok(#clears > before and clears[#clears].id:find('shots_2_', 1, true) == 1,
        'silenced: the backstop clears it (the NPC-mission rule)')
    RS.officerAlerts = 'normal'
    for _, r in ipairs({ live, npc, vol }) do r.state = 'ended' end
end

-- ============================================================================
--                  REAL CALLS (Hard rule 15, critic C1, C15)
-- ============================================================================

do
    local T = H.time
    local dispatchId = 'crimson_contract_7_' .. T
    for _, id in ipairs({ dispatchId, 'shots_5_123', 'shots_12_123', 'shots_15_123', 'playerdown_5_123', '456' }) do
        activeCalls[id] = id
    end
    cases['rs-calls'] = { suspects = { CIDS5 = { src = 5 }, CIDS6 = { src = nil } } }
    local r = NewRun('rs-calls', {
        srcs = { 11, 12 },
        arrived = true,
        state = 'in_progress',
        realSuspect = 'live',
        live = { dispatchId = dispatchId },
    })

    local set = CP.Calls.exemptFor(r)
    H.eq(set.exact[dispatchId], true, 'exemptFor: the case\'s own call, exact')
    local pre = {}
    for _, p in ipairs(set.prefixes) do pre[p] = true end
    H.ok(pre.shots_5_ and pre.playerdown_5_ and pre.panic_5_, 'exemptFor: the suspect\'s shots and down calls')
    H.ok(pre.shots_11_ and pre.shots_12_ and pre.emsdown_12_, 'exemptFor: every participant\'s shots and down calls')

    local function Respond(src, id) Emit('responding', src, id, true); H.step(0) end
    Respond(11, dispatchId)
    H.eq(#RemovedFor(11), 0, 'responding to the case\'s own call does not end the run')
    Respond(11, 'shots_5_123')
    H.eq(#RemovedFor(11), 0, 'responding to the suspect\'s shots-fired call does not end it')
    Respond(11, 'shots_12_123')
    H.eq(#RemovedFor(11), 0, 'responding to his partner\'s shots-fired call does not end it')
    H.eq(CP.Calls.isOnCall(11), false, 'none of them is a real call for him')
    Respond(11, 'shots_15_123')
    H.eq(RemovedFor(11)[1] and RemovedFor(11)[1].reason, 'real_call',
        'shots_1<suspect>_: another player\'s call is a real call')

    -- a run without a real suspect: a partner's shots call is a real call, as today
    local npc = NewRun('rs-calls-npc', { srcs = { 13, 12 + 100 }, arrived = true, state = 'in_progress' })
    activeCalls['shots_112_123'] = 'shots_112_123'
    Respond(13, 'shots_112_123')
    H.eq(RemovedFor(13)[1] and RemovedFor(13)[1].reason, 'real_call', 'an NPC run: unchanged (only ownRunCallPrefixes)')
    npc.state = 'ended'

    -- the claim's on-call check (V14): except ignores the case's calls, nothing else
    Respond(14, dispatchId)
    Respond(14, 'shots_5_123')
    H.eq(CP.Calls.isOnCall(14), true, 'an officer outside the case responding to them is on a call')
    H.eq(CP.Calls.isOnCall(14, { except = set }), false, 'isOnCall with except ignores those calls')
    Respond(14, '456')
    H.eq(CP.Calls.isOnCall(14, { except = set }), true, 'a real call still counts with except')
    r.state = 'ended'
end

-- ============================================================================
--                               THE START ROUTE
-- ============================================================================
-- Hard rule 17, routeEnds, LiveCrime.requireRoute.

AlignTo(2000)

local function RouteRun(id, src, o)
    local r = NewRun(id, { srcs = { src }, realSuspect = o.realSuspect, live = o.live, test = o.test })
    r.routeRequired = CP.Route.requiredFor(r)            -- what CP.Runs.create locks at accept
    PlayerRec(src).coords = vec3(0.0, 1000.0, 0.0)       -- 1 km off the GPS line (and from the start)
    if o.suspectAt then cases[id] = { suspects = { ['S' .. src] = { src = 900 + src, coords = o.suspectAt } } } end
    CP.Route.begin(r, src)
    return r
end

-- an officer 1 km off the GPS line but 80 m from a suspect has arrived and is never abandoned
do
    local r = RouteRun('rs-rt-contact', 21, { realSuspect = 'volunteer', suspectAt = vec3(80.0, 1000.0, 0.0) })
    H.eq(r.routeRequired, true, 'a volunteer run follows Config.Route.required (shipped on)')
    RunFor(40000, Reporter(21, r.id, 1000.0))
    H.ok(Arrived(21), 'first contact counts as arrived (markArrived)')
    H.eq(#RemovedFor(21), 0, 'never abandoned for the route')
    H.eq(#ClientEvents('client:routeWarning', 21), 0, 'no off-route warning')
    H.eq(CP.Route.status(r, 21).status, 'arrived', 'the route watch stopped: arrived')
    r.state = 'ended'

    RS.routeEnds = 'start'
    local r2 = RouteRun('rs-rt-start', 22, { realSuspect = 'volunteer', suspectAt = vec3(80.0, 1000.0, 0.0) })
    RunFor(40000, function(c)
        if c % 2000 == 0 and r2.participants[22].status == 'active' then
            H.fire(CP.e('server:routeStatus'), 22, r2.id, 1000.0, PlayerRec(22).coords)
        end
    end)
    H.eq(Arrived(22), false, 'routeEnds = start: contact is not arrival (the NPC-mission rule)')
    H.eq(RemovedFor(22)[1] and RemovedFor(22)[1].reason, 'off_route', '...and he is abandoned off route')
    RS.routeEnds = 'first_contact'
end

-- a live officer 1 km off the line for 60 s, 300 m behind a suspect (outside contactRange)
local function Chase(id, src, o, seconds)
    local r = RouteRun(id, src, o)
    RunFor(seconds * 1000, function(c)
        if c % 2000 == 0 and r.participants[src].status == 'active' then
            H.fire(CP.e('server:routeStatus'), src, r.id, 1000.0, PlayerRec(src).coords)
        end
    end)
    return r
end

do
    local behind = vec3(300.0, 1000.0, 0.0)
    local live = { dispatchId = 'crimson_contract_9_1' }
    local r = Chase('rs-rt-live-free', 23, { realSuspect = 'live', live = live, suspectAt = behind }, 60)
    H.eq(r.routeRequired, false, 'requireRoute false: a live run is locked without the route rule')
    H.eq(r.participants[23].status, 'active', 'requireRoute false: he stays in the run')
    H.eq(#RemovedFor(23), 0, '...never off_route')
    H.eq(#ClientEvents('client:routeWarning', 23), 0, '...with no warning')
    local st = CP.Route.status(r, 23)
    H.eq(st.required, false, '...the status says the route is not required')
    H.eq(st.secondsLeft, nil, '...and shows no countdown')
    H.eq(Arrived(23), false, '300 m behind is not contact (contactRange 100 m)')
    Config.LiveCrime.requireRoute = true
    H.eq(CP.Route.requiredFor(r), false, 'the run keeps the value it was locked with')
    r.state = 'ended'

    local r2 = Chase('rs-rt-live-strict', 24, { realSuspect = 'live', live = live, suspectAt = behind }, 60)
    H.eq(r2.routeRequired, true, 'requireRoute true: locked with the route rule')
    H.eq(RemovedFor(24)[1] and RemovedFor(24)[1].reason, 'off_route', 'requireRoute true: removed off_route as RT1')
    Config.LiveCrime.requireRoute = false

    -- volunteer runs follow Config.Route.required, whatever requireRoute says
    local old = Config.Route.required
    local v1 = Chase('rs-rt-vol-on', 25, { realSuspect = 'volunteer', suspectAt = behind }, 60)
    H.eq(RemovedFor(25)[1] and RemovedFor(25)[1].reason, 'off_route', 'a volunteer run, Route.required on: removed')
    Config.Route.required = false
    local v2 = Chase('rs-rt-vol-off', 26, { realSuspect = 'volunteer', suspectAt = behind }, 60)
    H.eq(v2.participants[26].status, 'active', 'a volunteer run, Route.required off: stays')
    H.eq(#ClientEvents('client:routeWarning', 26), 0, '...with no warning')
    Config.Route.required = old
    v1.state, v2.state = 'ended', 'ended'

    -- a test run's own route choice still wins
    local t1 = Chase('rs-rt-test', 27,
        { realSuspect = 'live', live = live, test = { adminSrc = 1, useStartRoute = true }, suspectAt = behind }, 60)
    H.eq(t1.routeRequired, true, 'a live test run with its Start route on: the route rule')
    H.eq(RemovedFor(27)[1] and RemovedFor(27)[1].reason, 'off_route', '...removed off_route')
    local t2 = Chase('rs-rt-test-off', 28,
        { realSuspect = 'live', live = live, test = { adminSrc = 1, useStartRoute = false }, suspectAt = behind }, 60)
    H.eq(CP.Route.status(t2, 28).status, 'disabled', 'a test run with its Start route off: no route at all')
    H.eq(t2.participants[28].status, 'active', '...and he stays')
    r2.state, t1.state, t2.state = 'ended', 'ended', 'ended'
end

-- ============================================================================
--              DOWNED (Hard rule 18, Config.RealSuspects.downed)
-- ============================================================================

local function UntilRemoved(src, maxMs)
    local limit = H.clockMs + (maxMs or 5000)
    while #RemovedFor(src) == 0 and H.clockMs < limit do H.step(100) end
    return RemovedFor(src)[1]
end

do
    ems.doctors = 0
    local r = NewRun('rs-dn-live', { srcs = { 31, 32 }, arrived = true, state = 'in_progress', realSuspect = 'live' })
    PlayerRec(31).coords = vec3(300.0, -590.0, 43.0)
    downed[31] = true
    local e = UntilRemoved(31)
    H.eq(e and e.reason, 'downed_case', 'a live case: the downed officer leaves with downed_case')
    H.eq(e and e.keepFlag, true, '...with keepFlag, as downed')
    H.eq(r.stats.downs, 1, '...and counts as a down')
    local soon
    for _, n in ipairs(notes) do if n.src == 31 and n.key == 'downed.pickup_soon' then soon = n end end
    H.eq(soon and soon.vars.seconds, 400, 'the pick-up toast says 400 s')
    RunFor(399000 - (H.clockMs - e.at), nil, 500)
    H.eq(#ClientEvents('client:pickup', 31), 0, 'no pick-up before 400 s (Config.Downed.pickupDelay is 15)')
    RunFor(1500, nil, 500)
    H.eq(#ClientEvents('client:pickup', 31), 1, 'the pick-up after downedPickupDelay')
    downed[31] = nil
    H.fire(CP.e('server:pickupDone'), 31, r.id, true)

    local v = NewRun('rs-dn-vol',
        { srcs = { 33, 34 }, arrived = true, state = 'in_progress', realSuspect = 'volunteer' })
    downed[33] = true
    H.eq(UntilRemoved(33) and UntilRemoved(33).reason, 'downed_kept', 'a volunteer case: downed_kept')
    downed[33] = nil

    RS.downed = 'failed'
    local f = NewRun('rs-dn-failed', { srcs = { 35, 36 }, arrived = true, state = 'in_progress', realSuspect = 'live' })
    downed[35] = true
    H.eq(UntilRemoved(35) and UntilRemoved(35).reason, 'downed', 'downed = failed: today\'s downed (Failed)')
    downed[35] = nil
    RS.downed = 'keep_earned'

    local n = NewRun('rs-dn-npc', { srcs = { 37, 38 }, arrived = true, state = 'in_progress' })
    PlayerRec(37).coords = vec3(300.0, -590.0, 43.0)
    downed[37] = true
    local en = UntilRemoved(37)
    H.eq(en and en.reason, 'downed', 'an NPC run: downed as today')
    RunFor(15000 - (H.clockMs - en.at))
    H.eq(#ClientEvents('client:pickup', 37), 1, 'an NPC run: the pick-up after Config.Downed.pickupDelay (15 s)')
    downed[37] = nil
    for _, x in ipairs({ r, v, f, n }) do x.state = 'ended' end
end

return H
