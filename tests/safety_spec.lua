-- Modules/route, calls, alerts, downed (slice safety: Hard rules 15-18).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ============================================================================
--                                    LOCALE
-- ============================================================================
-- Serve this slice's part as en.json so CP.L returns real text.

do
    local f = io.open(H.root .. 'locales/parts/safety.json', 'r')
    local text = f:read('a')
    f:close()
    local realLoad = LoadResourceFile
    LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return text end
        return realLoad(res, path)
    end
    H.load('shared/locale.lua')
end
H.eq(CP.L('downed.picked_up'), 'Picked up by an NPC unit', 'locale part loaded')
H.eq(CP.L('route.warning', { seconds = 20 }),
    'You left the route to the start. Get back on it within 20 s or your mission is abandoned.', 'locale vars')

-- ============================================================================
--                      NATIVES THE HARNESS DOES NOT HAVE
-- ============================================================================

local buckets = {}
GetPlayerRoutingBucket = function(src) return buckets[tonumber(src)] or 0 end

local bagHandlers = {}
AddStateBagChangeHandler = function(key, bagName, fn)
    bagHandlers[#bagHandlers + 1] = { key = key, bagName = bagName, fn = fn }
    return #bagHandlers
end
GetPlayerFromStateBagName = function(name)
    return tonumber(tostring(name):match('^player:(%d+)$')) or 0
end

local function PlayerRec(src)
    local p = H.players[src]
    if not p then p = {}; H.players[src] = p end
    p.state = p.state or {}
    return p
end

-- Any resource writing the replicated bag: change handlers first, then the value.
local function BagSet(src, key, value)
    local p = PlayerRec(src)
    for _, h in ipairs(bagHandlers) do
        if h.key == nil or h.key == key then h.fn(('player:%d'):format(src), key, value, 0, true) end
    end
    p.state[key] = value
end

Player = function(src)
    src = tonumber(src)
    local p = PlayerRec(src)
    local st = p.state
    return {
        state = setmetatable({
            set = function(_, k, v) BagSet(src, k, v) end,
        }, { __index = st }),
    }
end

local dropped = {}
GetPlayerName = function(src)
    if dropped[tonumber(src)] then return nil end
    return 'Player' .. tostring(src)
end

local function Bag(src) return PlayerRec(src).state.crimsonArena end
local OURS = function(v) return type(v) == 'table' and v.active == true and v.source == 'crimson-police' end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local runs = {}
local rlog = { arrived = {}, removed = {}, reclassify = {}, endRun = {} }
local runsCfg = { setFlagOnArrive = true, autoEnd = true, countDowns = true }

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
            if r.state ~= 'ended' then
                local p = r.participants[src]
                if p and p.status == 'active' then return r, p end
            end
        end
        return nil
    end,
    activeSrcs = ActiveOf,
    markArrived = function(r, src)
        rlog.arrived[#rlog.arrived + 1] = { run = r.id, src = src }
        r.participants[src].arrived = true
        if r.state == 'accepted' then r.state = 'in_progress' end
        if runsCfg.setFlagOnArrive then CP.Alerts.set(src, r) end
    end,
    -- A deliberately careless engine: it clears the flag even when keepFlag is passed (the hold must win).
    -- An in-arena src only loses the intent, as the real ReleaseFlag does (CRIMSON_ARENA rule 1).
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
        p.status = 'left'
        p.endReason = reason
        if reason == 'downed' and runsCfg.countDowns then r.stats.downs = r.stats.downs + 1 end
        if CP.Alerts.inArena(src) then CP.Alerts.forget(src) else CP.Alerts.clear(src) end
        CP.Route.stop(r, src)
        if opts and opts.notify then CP.Tablet.notify(src, 'warning', opts.notify) end
        if runsCfg.autoEnd and #ActiveOf(r) == 0 then r.state = 'ended' end
    end,
    reclassify = function(cid, runId, reason)
        rlog.reclassify[#rlog.reclassify + 1] = { cid = cid, run = runId, reason = reason }
    end,
    endRun = function(r, state, reason)
        rlog.endRun[#rlog.endRun + 1] = { run = r.id, state = state, reason = reason }
        r.state = 'ended'
    end,
    anchor = function(r) return r.anchor end,
}

local function NewRun(id, o)
    local r = {
        id = id,
        missionId = o.missionId or 'test_mission',
        state = o.state or 'accepted',
        test = o.test,
        location = { start = { coords = o.start or vec3(1000.0, 0.0, 0.0), radius = o.radius or 50.0 } },
        participants = {},
        stats = { downs = 0, weaponsFired = 0 },
        anchor = o.anchor,
    }
    for _, s in ipairs(o.srcs) do
        r.participants[s] = { src = s, citizenid = 'CID' .. s, status = 'active', arrived = o.arrived or false }
    end
    for _, s in ipairs(o.left or {}) do
        r.participants[s] = { src = s, citizenid = 'CID' .. s, status = 'left', arrived = true, endReason = 'downed' }
    end
    runs[id] = r
    return r
end

local function RemovedFor(src)
    local out = {}
    for _, e in ipairs(rlog.removed) do if e.src == src then out[#out + 1] = e end end
    return out
end

-- CP.Dispatch
local dl = { responding = {}, cleared = {}, restart = {}, shots = {}, down = {}, dead = {} }
local activeCalls = {}
local lookups = 0
local clears = {}
local function Emit(kind, ...)
    local args = table.pack(...)
    for _, fn in ipairs(dl[kind]) do
        CreateThread(function() fn(table.unpack(args, 1, args.n)) end)
    end
end
CP.Dispatch = {
    normalizeCallId = function(id)
        if type(id) == 'number' then
            local i = math.tointeger(id)
            if i then return ('%d'):format(i) end
            return tostring(id)
        elseif type(id) == 'string' then
            if id:match('^%d+$') or id:match('^%d+%.0*$') then return ('%d'):format(math.tointeger(tonumber(id))) end
            return id
        elseif id == nil then
            return ''
        end
        return tostring(id)
    end,
    lookupActiveCall = function(id)
        lookups = lookups + 1
        return activeCalls[CP.Dispatch.normalizeCallId(id)]
    end,
    clearNotification = function(id, jobs)
        clears[#clears + 1] = { id = id, jobs = jobs }
        return true
    end,
    onResponding = function(fn) dl.responding[#dl.responding + 1] = fn end,
    onCallCleared = function(fn) dl.cleared[#dl.cleared + 1] = fn end,
    onDispatchRestart = function(fn) dl.restart[#dl.restart + 1] = fn end,
    onShotsFired = function(fn) dl.shots[#dl.shots + 1] = fn end,
    onPlayerDown = function(fn) dl.down[#dl.down + 1] = fn end,
    onPlayerDead = function(fn) dl.dead[#dl.dead + 1] = fn end,
}

-- CP.Qbx, CP.Ambulance, CP.Tablet, CP.Admin
local downed = {}
local unloadListeners = {}
local metaListeners = {}   -- CP.Qbx.onMetaDataChange registrations { fn, keys }
CP.Qbx = {
    -- downed[src]: true / 'laststand' (metadata inlaststand) or 'dead' (metadata isdead only)
    isDowned = function(src) return downed[src] ~= nil and downed[src] ~= false end,
    getInfo = function(src)
        local d = downed[src]
        return { src = src, isDead = d == 'dead', inLastStand = d == true or d == 'laststand' }
    end,
    onPlayerUnload = function(fn) unloadListeners[#unloadListeners + 1] = fn end,
    onMetaDataChange = function(fn, keys) metaListeners[#metaListeners + 1] = { fn = fn, keys = keys } end,
}
local ems = { doctors = 0, revives = {} }
CP.Ambulance = {
    doctorCount = function() return ems.doctors end,
    revive = function(src) ems.revives[#ems.revives + 1] = src; return true end,
}
local notes = {}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end,
}
local audits = {}
CP.Admin = {
    audit = function(actor, role, category, action, target, old, new, reason)
        audits[#audits + 1] = {
            actor = actor,
            role = role,
            category = category,
            action = action,
            target = target,
            new = new,
            reason = reason,
        }
    end,
}

local function NotesFor(src, key)
    local n = 0
    for _, e in ipairs(notes) do if e.src == src and e.key == key then n = n + 1 end end
    return n
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

local function CountRevives(src)
    local n = 0
    for _, s in ipairs(ems.revives) do if s == src then n = n + 1 end end
    return n
end

-- ============================================================================
--                          LEFTOVERS BEFORE THE START
-- ============================================================================
-- Ours is removed, a foreign value is kept.

PlayerRec(21).state.crimsonArena = { active = true, source = 'crimson-police' }
PlayerRec(22).state.crimsonArena = { active = true, matchId = 'm0' }

-- ============================================================================
--                                LOAD THE SLICE
-- ============================================================================

H.load('modules/alerts/server.lua')
H.load('modules/route/server.lua')
H.load('modules/calls/server.lua')
H.load('modules/downed/server.lua')
H.step(0)   -- runtime wiring (every module registers its listeners after Wait(0))

H.eq(Bag(21), nil, 'start: leftover Crimson-Police flag removed')
H.eq(Bag(22) and Bag(22).matchId, 'm0', 'start: foreign value kept')
H.eq(#dl.responding, 1, 'calls listens to responding')
H.eq(#dl.shots, 1, 'alerts listens to shots fired')
H.eq(#dl.down + #dl.dead, 2, 'alerts listens to person down / dead')
H.eq(#unloadListeners, 1, 'downed listens to character unload')
H.eq(#metaListeners, 1, 'downed listens to qbx metadata changes')
do
    local keys = {}
    for _, k in ipairs(metaListeners[1] and metaListeners[1].keys or {}) do keys[k] = true end
    H.ok(keys.isdead and keys.inlaststand, 'metadata listener filtered to isdead / inlaststand')
end

-- advance ms in 100 ms steps, calling each(clock) after every step
local function RunFor(ms, each)
    local target = H.clockMs + ms
    while H.clockMs < target do
        H.step(100)
        if each then each(H.clockMs) end
    end
end

-- run until the clock is a multiple of `m` (a tick boundary of the loops)
local function AlignTo(m)
    while H.clockMs % m ~= 0 do H.step(100) end
end

local function Report(src, runId, metres, coords)
    H.fire(CP.e('server:routeStatus'), src, runId, metres, coords or PlayerRec(src).coords)
end

-- reporter(src, runId, metresFn) reports every 2 s on the clock
local function Reporter(src, runId, metres)
    return function(c)
        if c % 2000 == 0 then
            local m = type(metres) == 'function' and metres(c) or metres
            if m then Report(src, runId, m) end
        end
    end
end

-- ============================================================================
--                                    ROUTE
-- ============================================================================

AlignTo(2000)

-- 1) off route: warning at 10 s, abandon at 30 s
do
    PlayerRec(1).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-1', { srcs = { 1 } })
    H.ok(CP.Route.begin(r, 1), 'route begin')
    H.ok(CP.Route.begin(r, 1), 'route begin is idempotent')
    local st = CP.Route.status(r, 1)
    H.eq(st.status, 'on', 'status on')
    H.eq(st.recalcsLeft, 2, 'two recalcs')
    H.eq(st.distance, 1000, 'distance to the start')
    RunFor(6000, Reporter(1, 'r-route-1', 20.0))
    H.eq(#ClientEvents('client:routeWarning', 1), 0, 'on route: no warning')
    local offAt = H.clockMs + 2000
    local warnedAt, removedAt
    RunFor(40000, function(c)
        if c % 2000 == 0 and r.participants[1].status == 'active' then Report(1, 'r-route-1', 200.0) end
        if not warnedAt and #ClientEvents('client:routeWarning', 1) > 0 then warnedAt = c end
        if not removedAt and #RemovedFor(1) > 0 then removedAt = c end
    end)
    H.eq(warnedAt and warnedAt - offAt, 10000, 'warning 10 s after leaving the route')
    local w = ClientEvents('client:routeWarning', 1)[1]
    H.eq(w and w.args[1], 'r-route-1', 'warning carries the run id')
    H.eq(w and w.args[2], 20, 'warning carries the seconds left')
    H.eq(removedAt and removedAt - offAt, 30000, 'abandoned 30 s after leaving the route')
    H.eq(RemovedFor(1)[1] and RemovedFor(1)[1].reason, 'off_route', 'end reason off_route')
    H.eq(#RemovedFor(1), 1, 'removed once')
end

-- 2) back within maxDeviation resets the stretch; a shown warning is withdrawn
do
    PlayerRec(2).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-2', { srcs = { 2 } })
    CP.Route.begin(r, 2)
    AlignTo(2000)
    local A = H.clockMs + 2000
    local warnedAt
    RunFor(24000, function(c)
        if c % 2000 == 0 then
            local d = c - A
            local m = 200.0
            if d == 8000 or d == 22000 then m = 50.0 end
            Report(2, 'r-route-2', m)
        end
        if not warnedAt and #ClientEvents('client:routeWarning', 2) > 0 then warnedAt = c end
    end)
    H.eq(warnedAt and warnedAt - A, 20000, 'the back-on-route report restarted the 10 s')
    local ws = ClientEvents('client:routeWarning', 2)
    H.eq(ws[#ws].args[2], nil, 'back on route withdraws the warning')
    H.eq(CP.Route.status(r, 2).status, 'on', 'status on again')
    H.eq(#RemovedFor(2), 0, 'not abandoned')
    CP.Route.stop(r, 2)
end

-- 3) missing reports count as off route
do
    PlayerRec(3).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-3', { srcs = { 3 } })
    AlignTo(1000)
    CP.Route.begin(r, 3)
    local C = H.clockMs
    Report(3, 'r-route-3', 10.0)
    local warnedAt, removedAt
    RunFor(42000, function(c)
        if not warnedAt and #ClientEvents('client:routeWarning', 3) > 0 then warnedAt = c end
        if not removedAt and #RemovedFor(3) > 0 then removedAt = c end
    end)
    H.eq(warnedAt and warnedAt - C, 20000, 'no report for 10 s = off route, warned 10 s later')
    H.eq(removedAt and removedAt - C, 40000, 'abandoned 30 s after the reports stopped counting')
    H.eq(RemovedFor(3)[1] and RemovedFor(3)[1].reason, 'off_route', 'missing reports -> off_route')
end

-- 4) a report whose coords do not match the server position is ignored (counts as missing)
do
    PlayerRec(4).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-4', { srcs = { 4 } })
    AlignTo(1000)
    CP.Route.begin(r, 4)
    local C = H.clockMs
    local warnedAt
    RunFor(21000, function(c)
        if c % 2000 == 0 then Report(4, 'r-route-4', 0.0, vec3(600.0, 0.0, 0.0)) end
        if not warnedAt and #ClientEvents('client:routeWarning', 4) > 0 then warnedAt = c end
    end)
    H.eq(warnedAt and warnedAt - C, 20000, 'faked position reports are ignored')
    H.fire(CP.e('server:routeStatus'), 4, 'r-route-4', -5.0, vec3(0.0, 0.0, 0.0))
    H.fire(CP.e('server:routeStatus'), 4, 'r-route-4', 0 / 0, vec3(0.0, 0.0, 0.0))
    H.fire(CP.e('server:routeStatus'), 4, 12345, 1.0, vec3(0.0, 0.0, 0.0))
    H.eq(CP.Route.status(r, 4).status, 'off', 'invalid payloads change nothing')
    CP.Route.stop(r, 4)
end

-- 5) recalculate: at most twice per run; a granted one ends the off stretch
do
    PlayerRec(5).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-5', { srcs = { 5 } })
    AlignTo(2000)
    CP.Route.begin(r, 5)
    Report(5, 'r-route-5', 300.0)
    RunFor(12000, Reporter(5, 'r-route-5', 300.0))
    H.ok(#ClientEvents('client:routeWarning', 5) > 0, 'warned before the recalc')
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    local rc = ClientEvents('client:routeRecalc', 5)
    H.eq(rc[1] and rc[1].args[2], true, 'first recalc granted')
    H.eq(rc[1] and rc[1].args[3], 1, 'one recalc left')
    local ws = ClientEvents('client:routeWarning', 5)
    H.eq(ws[#ws].args[2], nil, 'recalc withdraws the warning')
    H.eq(CP.Route.status(r, 5).status, 'on', 'recalc: on route again')
    RunFor(2500, Reporter(5, 'r-route-5', 10.0))
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    RunFor(2500, Reporter(5, 'r-route-5', 10.0))
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    rc = ClientEvents('client:routeRecalc', 5)
    H.eq(#rc, 3, 'three replies')
    H.eq(rc[2].args[2], true, 'second recalc granted')
    H.eq(rc[3].args[2], false, 'third recalc refused')
    H.eq(CP.Route.status(r, 5).recalcsLeft, 0, 'no recalcs left')
    H.fire(CP.e('server:recalcRoute'), 6, 'r-route-5')
    H.eq(#ClientEvents('client:routeRecalc', 6), 1, 'a non-participant gets a reply')
    H.eq(ClientEvents('client:routeRecalc', 6)[1].args[2], false, '...which is a refusal')
    CP.Route.stop(r, 5)
end

-- 6) drift: further from the start than the closest point + maxDrift -> off_route whatever the reports say
do
    PlayerRec(6).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-6', { srcs = { 6 } })
    CP.Route.begin(r, 6)
    RunFor(3000, Reporter(6, 'r-route-6', 0.0))
    PlayerRec(6).coords = vec3(-500.0, 0.0, 0.0)   -- 1500 m: 500 past the closest (1000)
    RunFor(3000, Reporter(6, 'r-route-6', 0.0))
    H.eq(#RemovedFor(6), 0, 'drift within maxDrift is fine')
    PlayerRec(6).coords = vec3(-1050.0, 0.0, 0.0)  -- 2050 m: 1050 past the closest
    RunFor(1500, Reporter(6, 'r-route-6', 0.0))
    H.eq(RemovedFor(6)[1] and RemovedFor(6)[1].reason, 'off_route', 'drift check abandons the run')
end

-- 7) arrival: server-side position inside the start radius -> markArrived, flag, checks stop
do
    PlayerRec(7).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-7', { srcs = { 7 } })
    CP.Route.begin(r, 7)
    RunFor(2000, Reporter(7, 'r-route-7', 5.0))
    PlayerRec(7).coords = vec3(970.0, 10.0, 0.0)
    RunFor(1000)
    H.eq(rlog.arrived[#rlog.arrived].src, 7, 'markArrived called')
    H.eq(r.state, 'in_progress', 'the first arrival starts the run (stub)')
    H.ok(CP.Alerts.has(7) and OURS(Bag(7)), 'flag on at the start')
    local rs = ClientEvents('client:routeStatus', 7)
    H.eq(rs[1] and rs[1].args[2].status, 'arrived', 'client told about the arrival')
    H.eq(CP.Route.status(r, 7).status, 'arrived', 'status arrived')
    PlayerRec(7).coords = vec3(-3000.0, 0.0, 0.0) -- far away, silent: no checks any more
    RunFor(45000)
    H.eq(#RemovedFor(7), 0, 'no route checks after arrival')
    local n = 0
    for _, a in ipairs(rlog.arrived) do if a.src == 7 then n = n + 1 end end
    H.eq(n, 1, 'arrival marked once')
end

-- 8) arrival sets the flag even when the engine does not
do
    runsCfg.setFlagOnArrive = false
    PlayerRec(8).coords = vec3(1010.0, 0.0, 0.0)
    local r = NewRun('r-route-8', { srcs = { 8 } })
    CP.Route.begin(r, 8)
    RunFor(1000)
    H.ok(r.participants[8].arrived, 'arrived at once (inside the radius)')
    H.ok(CP.Alerts.has(8) and OURS(Bag(8)), 'route set the flag itself')
    runsCfg.setFlagOnArrive = true
end

-- 9) test run without the start route: arrival check only
do
    PlayerRec(9).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-9', { srcs = { 9 }, test = { adminSrc = 1, useStartRoute = false } })
    CP.Route.begin(r, 9)
    H.eq(CP.Route.status(r, 9).status, 'disabled', 'status disabled')
    PlayerRec(9).coords = vec3(-2500.0, 0.0, 0.0)
    RunFor(45000)
    H.eq(#RemovedFor(9), 0, 'no off-route or drift check without the start route')
    H.eq(#ClientEvents('client:routeWarning', 9), 0, 'no warning without the start route')
    PlayerRec(9).coords = vec3(1000.0, 20.0, 0.0)
    RunFor(1000)
    H.ok(r.participants[9].arrived, 'arrival still checked')
end

-- 10) in-arena participants are not route-checked and cannot arrive (CP.Alerts removes them as quit)
do
    PlayerRec(10).coords = vec3(995.0, 0.0, 0.0)
    buckets[10] = 4210
    local r = NewRun('r-route-10', { srcs = { 10 } })
    CP.Route.begin(r, 10)
    Report(10, 'r-route-10', 500.0)
    RunFor(2000)
    H.eq(r.participants[10].arrived, false, 'no arrival in an arena bucket')
    H.eq(RemovedFor(10)[1] and RemovedFor(10)[1].reason, 'quit', 'in-arena participant leaves as quit')
    H.eq(NotesFor(10, 'run.left_for_arena'), 1, 'toast run.left_for_arena')
    buckets[10] = nil
end

-- 11) safety net: a participant the engine never began is route-checked anyway
do
    PlayerRec(20).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-route-20', { srcs = { 20 } })
    H.eq(CP.Route.status(r, 20).distance, nil, 'no state yet')
    RunFor(1000)
    H.eq(CP.Route.status(r, 20).distance, 1000, 'state created by the tick')
    CP.Route.stop(r, 20)
    RunFor(1000)
    H.eq(CP.Route.status(r, 20).distance, nil, 'an explicit stop is respected')
    r.state = 'ended'
end

-- 12) Manhunt: the start is the search circle (first objective search_area), not the small start radius
do
    PlayerRec(34).coords = vec3(5520.0, 0.0, 0.0)
    local r = NewRun('r-route-34', { srcs = { 34 }, start = vec3(5000.0, 0.0, 0.0), radius = 80.0 })
    r.mission = { objectives = { { block = 'search_area', center = 'center', startRadius = 600 } } }
    r.location.center = vec3(5000.0, 0.0, 0.0)
    CP.Route.begin(r, 34)
    H.eq(CP.Route.status(r, 34).status, 'on', 'outside the search circle')
    RunFor(1000)
    H.ok(r.participants[34].arrived, 'inside the 600 m search circle counts as arrived')
    PlayerRec(35).coords = vec3(5620.0, 0.0, 0.0)
    local r2 = NewRun('r-route-35', { srcs = { 35 }, start = vec3(5000.0, 0.0, 0.0), radius = 80.0 })
    r2.mission = { objectives = { { block = 'search_area', center = 'center', startRadius = 600 } } }
    r2.location.center = vec3(5000.0, 0.0, 0.0)
    CP.Route.begin(r2, 35)
    RunFor(1000)
    H.eq(r2.participants[35].arrived, false, 'outside the circle: still heading there')
    CP.Route.stop(r2, 35)
    r2.state = 'ended'
end

-- ============================================================================
--                                    CALLS
-- ============================================================================

local T = H.time
activeCalls['123'] = '123'
activeCalls['456'] = '456'
activeCalls['777'] = '777'
activeCalls['888'] = '888'
activeCalls['889'] = 'CALL-889'
activeCalls['npccall-3-' .. T] = 'npccall-3-' .. T
activeCalls['panic_12_' .. T] = 'panic_12_' .. T
activeCalls['playerdown_14_' .. T] = 'playerdown_14_' .. T
activeCalls['panic_121_' .. T] = 'panic_121_' .. T
activeCalls['5'] = 'npccall-9-' .. T                    -- a numeric row id that belongs to an NPC call

local function Respond(src, callId, on) Emit('responding', src, callId, on) end

do
    local r = NewRun('r-calls', { srcs = { 11, 12 }, left = { 14 }, arrived = true, state = 'in_progress' })

    -- npccall ids: nothing at all (not even a lookup)
    local before = lookups
    Respond(11, 'npccall-3-' .. T, true)
    H.eq(lookups, before, 'npccall id: no lookup')
    H.eq(#RemovedFor(11), 0, 'npccall never ends a run')
    H.eq(CP.Calls.isOnCall(11), false, 'npccall: not on a call')
    Respond(11, 5, true)
    H.eq(#RemovedFor(11), 0, 'a row id that resolves to an npccall id does not count')

    -- a call about a partner of the same run
    Respond(11, 'panic_12_' .. T, true)
    H.eq(#RemovedFor(11), 0, 'a partner\'s panic call does not end the run')
    H.eq(CP.Calls.isOnCall(11), false, 'a partner\'s panic call is not a real call for them')
    Respond(11, 'playerdown_14_' .. T, true)
    H.eq(#RemovedFor(11), 0, 'a call about a partner who already left does not count either')

    -- the same id for an unrelated officer is a real call
    Respond(13, 'panic_12_' .. T, true)
    H.eq(CP.Calls.isOnCall(13), true, 'own-run prefix only protects partners')

    -- faked id: not in mdt_dispatch
    Respond(11, '999', true)
    H.eq(#RemovedFor(11), 0, 'fake id does nothing')
    H.eq(CP.Calls.isOnCall(11), false, 'fake id: not on a call')

    -- a real call ends only that participant, as real_call (no cooldown: the engine applies the table)
    Respond(11, 123, true)
    local rem = RemovedFor(11)
    H.eq(#rem, 1, 'real call removes the participant')
    H.eq(rem[1] and rem[1].reason, 'real_call', 'end reason real_call')
    H.eq(r.participants[12].status, 'active', 'the partner carries on')
    H.eq(CP.Calls.isOnCall(11), true, 'on a call now')
    H.eq(NotesFor(11, 'calls.run_ended'), 1, 'toast calls.run_ended')
    H.eq(audits[#audits] and audits[#audits].category, 'flags', 'free abandon audited under flags')
    H.eq(audits[#audits] and audits[#audits].new, '123', 'audit carries the call id')
    H.eq(#rlog.reclassify, 0, 'no reclassify yet')

    -- un-mark within the dodge window -> real_call_cancelled
    H.time = T + 30
    Respond(11, '123', false)
    H.eq(#rlog.reclassify, 1, 'un-mark within 60 s reclassifies')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].reason, 'real_call_cancelled', 'real_call_cancelled')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].cid, 'CID11', 'by citizenid')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].run, 'r-calls', 'for that run')
    H.eq(CP.Calls.isOnCall(11), false, 'un-marked: not on a call')
    Respond(11, '123', false)
    H.eq(#rlog.reclassify, 1, 'reclassified once')

    -- own-run prefix match is exact: panic_121_ is not about participant 12
    Respond(12, 'panic_121_' .. T, true)
    H.eq(RemovedFor(12)[1] and RemovedFor(12)[1].reason, 'real_call', 'panic_121_ is not playerdown of 12: real call')
end

do
    -- un-mark after the window: stays a free abandon
    H.time = T + 100
    NewRun('r-calls-2', { srcs = { 15 }, arrived = true, state = 'in_progress' })
    Respond(15, 456, true)
    H.eq(RemovedFor(15)[1] and RemovedFor(15)[1].reason, 'real_call', 'real call')
    H.time = T + 100 + 61
    Respond(15, '456', false)
    H.eq(#rlog.reclassify, 1, 'un-mark after 60 s changes nothing')
end

do
    -- respondingExpiry: 13 has been on a call since T
    H.time = T + 1199
    H.eq(CP.Calls.isOnCall(13), true, 'entry alive before the expiry')
    H.time = T + 1200
    H.eq(CP.Calls.isOnCall(13), false, 'entry expires after Config.Calls.respondingExpiry')

    -- auto-cleared calls: re-checked in mdt_dispatch
    Respond(16, '777', true)
    H.eq(CP.Calls.isOnCall(16), true, 'on call 777')
    activeCalls['777'] = nil
    H.time = H.time + 5
    H.eq(CP.Calls.isOnCall(16), true, 'still cached right after')
    H.time = H.time + 10
    H.eq(CP.Calls.isOnCall(16), false, 'an auto-cleared call is dropped on the next check')

    -- callClearedByOfficer, also in another id form
    Respond(17, '888', true)
    Respond(18, 889, true)
    H.eq(CP.Calls.isOnCall(17) and CP.Calls.isOnCall(18), true, 'on calls 888 / 889')
    Emit('cleared', 888)
    Emit('cleared', '889')
    H.eq(CP.Calls.isOnCall(17), false, 'callCleared removes the call')
    H.eq(CP.Calls.isOnCall(18), false, 'callCleared with the raw id removes the canonical entry')

    -- sc-dispatch restart wipes everything
    Respond(19, '456', true)
    H.eq(CP.Calls.isOnCall(19), true, 'on call')
    Emit('restart')
    H.eq(CP.Calls.isOnCall(19), false, 'sc-dispatch restart wipes the map')

    -- playerDropped
    Respond(16, '456', true)
    H.eq(CP.Calls.isOnCall(16), true, 'on call')
    H.fire('playerDropped', 16, 'quit')
    H.eq(CP.Calls.isOnCall(16), false, 'playerDropped wipes the player')
end

-- ============================================================================
--                                    ALERTS
-- ============================================================================

H.time = T + 5000

do
    local r = NewRun('r-al-1',
        { srcs = { 23, 24, 25, 26, 27, 28, 29 }, arrived = true, state = 'in_progress', start = vec3(0.0, 0.0, 0.0) })
    for _, s in ipairs({ 23, 24, 25, 26, 27, 28, 29 }) do PlayerRec(s).coords = vec3(100.0, 0.0, 0.0) end

    -- set / clear ownership
    H.ok(CP.Alerts.set(23, r), 'set')
    H.ok(OURS(Bag(23)), 'our value written')
    H.ok(CP.Alerts.has(23), 'has')
    H.eq(CP.Alerts.foreignFlag(23), false, 'ours is not foreign')
    H.eq(CP.Alerts.inArena(23), false, 'not in the arena')
    H.ok(CP.Alerts.clear(23), 'clear')
    H.eq(Bag(23), nil, 'value removed')
    H.eq(CP.Alerts.has(23), false, 'intent removed')

    -- foreign values: never overwritten, never cleared
    PlayerRec(24).state.crimsonArena = { active = true, matchId = 'm24' }
    H.eq(CP.Alerts.foreignFlag(24), true, 'foreign flag')
    H.eq(CP.Alerts.inArena(24), true, 'foreign flag = in arena')
    H.eq(CP.Alerts.set(24, r), false, 'set refuses while foreign')
    H.eq((Bag(24) or {}).matchId, 'm24', 'foreign value not overwritten')
    H.eq(CP.Alerts.has(24), false, 'nothing recorded')
    H.eq(CP.Alerts.clear(24), false, 'clear leaves a foreign value')
    H.eq((Bag(24) or {}).matchId, 'm24', 'foreign value not cleared')
    RunFor(1000)
    H.eq(RemovedFor(24)[1] and RemovedFor(24)[1].reason, 'quit',
        'an active participant with a foreign value leaves as quit')
    H.eq((Bag(24) or {}).matchId, 'm24', 'still not touched')

    -- re-assert after a wipe (debounced 250 ms)
    CP.Alerts.set(25, r)
    BagSet(25, 'crimsonArena', nil) -- Crimson-Arena wipes the key unconditionally
    H.eq(Bag(25), nil, 'wiped')
    H.step(0)
    H.ok(OURS(Bag(25)), 're-asserted on the next tick')
    BagSet(25, 'crimsonArena', nil)
    H.step(0)
    H.eq(Bag(25), nil, 'second wipe within 250 ms waits')
    H.step(100)
    H.eq(Bag(25), nil, '...still waiting at 100 ms')
    H.step(200)
    H.ok(OURS(Bag(25)), 're-asserted after 250 ms')
    H.ok(CP.Alerts.has(25), 'intent kept across wipes')

    -- a foreign value replaces ours: never re-written; the participant leaves; foreignClearedAt on nil
    CP.Alerts.set(26, r)
    BagSet(26, 'crimsonArena', { active = true, matchId = 'm26' })
    H.step(0)
    H.eq(RemovedFor(26)[1] and RemovedFor(26)[1].reason, 'quit', 'foreign flag mid-run -> quit')
    H.eq(NotesFor(26, 'run.left_for_arena'), 1, 'toast run.left_for_arena')
    H.eq(CP.Alerts.has(26), false, 'intent dropped')
    H.eq((Bag(26) or {}).matchId, 'm26', 'foreign value left alone')
    RunFor(1500)
    H.eq((Bag(26) or {}).matchId, 'm26', 'never re-asserted over a foreign value')
    H.eq(CP.Alerts.foreignClearedAt[26], nil, 'not cleared yet')
    BagSet(26, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[26], H.time, 'foreignClearedAt recorded')
    RunFor(1500)
    H.eq(Bag(26), nil, 'no re-assert once the intent is gone')

    -- routing bucket
    buckets[27] = 4210
    H.eq(CP.Alerts.inArena(27), true, 'bucket ~= 0 = in arena')
    H.eq(CP.Alerts.foreignFlag(27), false, 'no foreign flag though')
    H.eq(CP.Alerts.set(27, r), false, 'set refuses in another bucket')
    RunFor(1000)
    H.eq(RemovedFor(27)[1] and RemovedFor(27)[1].reason, 'quit', 'bucket change mid-run -> quit')
    buckets[27] = nil

    -- backstop: shots fired near the mission, t-1, t, t+1, { 'police' }
    CP.Alerts.set(28, r)
    local t = H.time
    clears = {}
    Emit('shots', 28, { coords = vec3(100.0, 0.0, 0.0) }, t)
    H.eq(#clears, 0, 'waits backstopDelay first')
    RunFor(1000)
    H.eq(#clears, 3, 'three ids cleared')
    H.eq(clears[1] and clears[1].id, ('shots_28_%d'):format(t - 1), 'previous second')
    H.eq(clears[2] and clears[2].id, ('shots_28_%d'):format(t), 'current second')
    H.eq(clears[3] and clears[3].id, ('shots_28_%d'):format(t + 1), 'next second')
    H.eq(clears[1] and clears[1].jobs[1], 'police', 'jobs { \'police\' }')
    H.eq(clears[1] and #clears[1].jobs, 1, 'only police for shots')

    -- out of radius (server-side coords), then near the objective anchor
    clears = {}
    PlayerRec(29).coords = vec3(400.0, 0.0, 0.0)
    Emit('shots', 29, { coords = vec3(0.0, 0.0, 0.0) }, t)
    RunFor(1500)
    H.eq(#clears, 0, 'outside backstopRadius (client coords are ignored)')
    r.anchor = vec3(450.0, 0.0, 0.0)
    Emit('shots', 29, {}, t + 5)
    RunFor(1500)
    H.eq(#clears, 3, 'near the current objective anchor')
    r.anchor = nil

    -- foreign srcs are skipped
    clears = {}
    Emit('shots', 24, {}, t)
    Emit('down', 24, {}, t)
    RunFor(1500)
    H.eq(#clears, 0, 'foreign srcs are left to Crimson-Arena')

    -- person down / dead from a flagged src: { 'police', 'ambulance' }; never emsdown_
    clears = {}
    Emit('down', 28, {}, t)
    Emit('dead', 28, {}, t)
    RunFor(1500)
    H.eq(#clears, 6, 'down and dead: three ids each')
    H.eq(clears[1] and clears[1].id, ('playerdown_28_%d'):format(t - 1), 'playerdown t-1')
    H.eq(clears[6] and clears[6].id, ('playerdead_28_%d'):format(t + 1), 'playerdead t+1')
    H.eq(clears[1] and table.concat(clears[1].jobs, ','), 'police,ambulance', 'jobs { \'police\', \'ambulance\' }')
    clears = {}
    Emit('down', 23, {}, t) -- 23 has no intent any more
    RunFor(1500)
    H.eq(#clears, 0, 'person down without our flag: nothing cleared')

    -- an intent that outlived its run is removed
    local r2 = NewRun('r-al-2', { srcs = { 30 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(30, r2)
    r2.state = 'ended'                         -- the engine forgot to clear it
    RunFor(5000)
    H.eq(Bag(30), nil, 'orphaned flag removed')
    H.eq(CP.Alerts.has(30), false, 'orphaned intent removed')
end

-- ============================================================================
--                                    DOWNED
-- ============================================================================

local function FirstRemoval(src, reason)
    for _, e in ipairs(rlog.removed) do if e.src == src and e.reason == reason then return e end end
    return nil
end

local function UntilRemoved(src, reason, maxMs)
    local limit = H.clockMs + (maxMs or 5000)
    while not FirstRemoval(src, reason) and H.clockMs < limit do H.step(100) end
    return FirstRemoval(src, reason)
end

-- 1) no EMS: pick-up after 15 s, then revive, then the flag goes when the client is done
do
    ems.doctors = 0
    PlayerRec(41).coords = vec3(-240.0, 6300.0, 32.0)
    local r = NewRun('r-dn-1', { srcs = { 41 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(41, r)
    downed[41] = true
    local e = UntilRemoved(41, 'downed')
    H.ok(e ~= nil, 'downed participant removed')
    H.eq(e and e.keepFlag, true, 'removed with keepFlag')
    H.eq(r.stats.downs, 1, 'run.stats.downs + 1 (counted once although the engine counts downs too)')
    H.ok(OURS(Bag(41)) and CP.Alerts.has(41), 'flag kept while down (even though the engine tried to clear it)')
    H.eq(NotesFor(41, 'downed.pickup_soon'), 1, 'toast: pick-up soon')
    local detected = e.at
    RunFor(14900 - (H.clockMs - detected))
    H.eq(#ClientEvents('client:pickup', 41), 0, 'no pick-up before 15 s')
    RunFor(100)
    local pk = ClientEvents('client:pickup', 41)
    H.eq(#pk, 1, 'pick-up at 15 s')
    H.eq(pk[1] and pk[1].args[1], 'r-dn-1', 'pick-up carries the run id')
    H.near(pk[1] and pk[1].args[2].x, -254.54, 1e-6, 'nearest drop-off (Paleto)')
    H.eq(CountRevives(41), 0, 'revive follows the fade')
    RunFor(1500)
    H.eq(CountRevives(41), 1, 'revived')
    H.ok(OURS(Bag(41)), 'flag still on until the client is done')
    H.fire(CP.e('server:pickupDone'), 41, 'r-dn-1', true)
    H.eq(Bag(41), nil, 'flag cleared after the pick-up')
    H.eq(CP.Alerts.has(41), false, 'intent cleared')
    RunFor(10000) -- metadata still says "down" for a while
    H.eq(#ClientEvents('client:pickup', 41), 1, 'never picked up twice')
    H.eq(CountRevives(41), 1, 'never revived twice')
    H.eq(r.state, 'ended', 'every participant downed: the run ended')
    downed[41] = nil
end

-- 2) EMS on duty: flag cleared first, then one EMS request
do
    ems.doctors = 2
    local r = NewRun('r-dn-2', { srcs = { 42, 50 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(42, r)
    CP.Alerts.set(50, r)
    downed[42] = true
    H.ok(UntilRemoved(42, 'downed') ~= nil, 'downed with EMS on duty')
    H.eq(Bag(42), nil, 'flag removed before the EMS request')
    local req = ClientEvents('client:requestEMS', 42)
    H.eq(#req, 1, 'EMS request sent')
    H.eq(req[1] and req[1].args[1], 'r-dn-2', 'EMS request carries the run id')
    RunFor(8000)
    H.eq(#ClientEvents('client:requestEMS', 42), 1, 'EMS request sent once')
    H.eq(#ClientEvents('client:pickup', 42), 0, 'no pick-up with EMS on duty')
    H.eq(r.participants[50].status, 'active', 'the partner carries on')
    H.ok(OURS(Bag(50)), 'the partner\'s flag stays')
    downed[42] = nil
end

-- 2b) an engine that does not count downs itself: CP.Downed adds the one down
do
    ems.doctors = 1
    runsCfg.countDowns = false
    local r = NewRun('r-dn-2b', { srcs = { 52, 53 }, arrived = true, state = 'in_progress' })
    downed[52] = true
    H.ok(UntilRemoved(52, 'downed') ~= nil, 'downed')
    RunFor(100)
    H.eq(r.stats.downs, 1, 'run.stats.downs + 1 by CP.Downed')
    runsCfg.countDowns = true
    downed[52] = nil
end

-- 3) EMS on duty after an arena exit: the request waits until 11 s after foreignClearedAt
do
    ems.doctors = 1
    BagSet(43, 'crimsonArena', { active = true, matchId = 'm43' })
    H.step(0)
    BagSet(43, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[43], H.time, 'arena exit recorded')
    local T43 = H.time
    H.time = T43 + 3
    local r = NewRun('r-dn-3', { srcs = { 43 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(43, r)
    downed[43] = true
    local e = UntilRemoved(43, 'downed')
    H.ok(e ~= nil, 'downed')
    H.eq(Bag(43), nil, 'flag removed at once')
    RunFor(7900 - (H.clockMs - e.at))
    H.eq(#ClientEvents('client:requestEMS', 43), 0, 'EMS request held back after an arena exit')
    RunFor(100)
    H.eq(#ClientEvents('client:requestEMS', 43), 1, 'EMS request 11 s after the arena exit')
    downed[43] = nil
end

-- 4) in-arena srcs are not treated as downed
do
    ems.doctors = 0
    local r = NewRun('r-dn-4', { srcs = { 44 }, arrived = true, state = 'in_progress' })
    buckets[44] = 4300
    downed[44] = true
    RunFor(4000)
    H.eq(FirstRemoval(44, 'downed'), nil, 'in-arena src skipped by the downed poll')
    H.eq(#ClientEvents('client:pickup', 44), 0, 'no pick-up in the arena')
    buckets[44] = nil
    downed[44] = nil
    r.state = 'ended'
end

-- 5) a disconnect cancels the pick-up
do
    ems.doctors = 0
    NewRun('r-dn-5', { srcs = { 45 }, arrived = true, state = 'in_progress' })
    downed[45] = true
    H.ok(UntilRemoved(45, 'downed') ~= nil, 'downed')
    RunFor(5000)
    dropped[45] = true
    H.fire('playerDropped', 45, 'quit')
    RunFor(15000)
    H.eq(#ClientEvents('client:pickup', 45), 0, 'dropped: no pick-up')
    H.eq(CountRevives(45), 0, 'dropped: no revive')
    downed[45] = nil
end

-- 6) a character unload cancels the pick-up
do
    ems.doctors = 0
    local r = NewRun('r-dn-6', { srcs = { 46 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(46, r)
    downed[46] = true
    H.ok(UntilRemoved(46, 'downed') ~= nil, 'downed')
    for _, fn in ipairs(unloadListeners) do CreateThread(function() fn(46) end) end
    H.eq(Bag(46), nil, 'unload: flag removed')
    RunFor(16000)
    H.eq(#ClientEvents('client:pickup', 46), 0, 'unload: no pick-up')
    downed[46] = nil
end

-- 7) revived by someone else before the pick-up: cancelled, flag removed
do
    ems.doctors = 0
    local r = NewRun('r-dn-7', { srcs = { 47 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(47, r)
    downed[47] = true
    H.ok(UntilRemoved(47, 'downed') ~= nil, 'downed')
    H.ok(OURS(Bag(47)), 'flag kept while down')
    RunFor(8000)
    downed[47] = nil
    RunFor(8000)
    H.eq(#ClientEvents('client:pickup', 47), 0, 'recovered: no pick-up')
    H.eq(Bag(47), nil, 'recovered: flag removed')
end

-- 8) went down before the start (no flag) into last stand with EMS on duty: sc-ambulance already alerted EMS
do
    ems.doctors = 1
    NewRun('r-dn-8', { srcs = { 48 }, arrived = false, state = 'accepted' })
    downed[48] = 'laststand'
    H.ok(UntilRemoved(48, 'downed') ~= nil, 'downed before the start')
    RunFor(3000)
    H.eq(#ClientEvents('client:requestEMS', 48), 0, 'no second EMS request without our flag (last stand)')
    H.eq(NotesFor(48, 'downed.ems_on_duty'), 1, 'toast: EMS on duty')
    downed[48] = nil
end

-- 8b) went down before the start (no flag) straight to dead with EMS on duty: sc-ambulance sent no alert,
-- so Crimson-Police sends exactly one EMS request
do
    ems.doctors = 1
    NewRun('r-dn-8b', { srcs = { 58 }, arrived = false, state = 'accepted' })
    downed[58] = 'dead'
    H.ok(UntilRemoved(58, 'downed') ~= nil, 'downed (dead) before the start')
    RunFor(3000)
    local req = ClientEvents('client:requestEMS', 58)
    H.eq(#req, 1, 'EMS request sent for an unflagged participant who went straight to dead')
    H.eq(req[1] and req[1].args[1], 'r-dn-8b', 'EMS request carries the run id')
    RunFor(10000)
    H.eq(#ClientEvents('client:requestEMS', 58), 1, 'EMS request sent once')
    downed[58] = nil
end

-- 9) the last participant went down and the engine left the run open: it ends as failed
do
    ems.doctors = 1
    runsCfg.autoEnd = false
    local r = NewRun('r-dn-9', { srcs = { 49 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(49, r)
    downed[49] = true
    H.ok(UntilRemoved(49, 'downed') ~= nil, 'downed')
    RunFor(6000)
    local ended
    for _, e in ipairs(rlog.endRun) do if e.run == 'r-dn-9' then ended = e end end
    H.eq(ended and ended.state, 'failed', 'run with every participant downed ends as failed')
    runsCfg.autoEnd = true
    downed[49] = nil
end

-- 10) the client gave up before the revive: no revive, flag removed
do
    ems.doctors = 0
    local r = NewRun('r-dn-10', { srcs = { 51 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(51, r)
    downed[51] = true
    local e = UntilRemoved(51, 'downed')
    RunFor(15000 - (H.clockMs - e.at))
    H.eq(#ClientEvents('client:pickup', 51), 1, 'pick-up sent')
    H.fire(CP.e('server:pickupDone'), 51, 'wrong-run', false)
    H.ok(OURS(Bag(51)), 'pickupDone for another run is ignored')
    H.fire(CP.e('server:pickupDone'), 51, 'r-dn-10', false)
    RunFor(2000)
    H.eq(CountRevives(51), 0, 'no revive after the client gave up')
    H.eq(Bag(51), nil, 'flag removed')
    H.eq(#ClientEvents('client:pickupCancel', 51), 0, 'the client that gave up is not told to cancel')
    downed[51] = nil
end

-- ============================================================================
--            REVIEW (integrations lens): regressions for the fixes
-- ============================================================================
-- 1) backstop: shots events in consecutive seconds. The first event's clear of the t + 1 id ran before that
--    second's call could exist, so the next event must clear it again; ids cleared at s + 2 or later stay deduped.
do
    local r = NewRun('r-rv-1', { srcs = { 81 }, arrived = true, state = 'in_progress', start = vec3(0.0, 0.0, 0.0) })
    PlayerRec(81).coords = vec3(10.0, 0.0, 0.0)
    CP.Alerts.set(81, r)
    local t = H.time
    local function IdsOf(list)
        local out = {}
        for _, c in ipairs(list) do out[#out + 1] = c.id end
        return table.concat(out, ',')
    end
    clears = {}
    Emit('shots', 81, {}, t)
    H.time = t + 1                               -- the clear runs after backstopDelay
    RunFor(1100)
    H.eq(#clears, 3, 'first event: t-1, t, t+1')
    clears = {}
    Emit('shots', 81, {}, t + 1)                 -- a second call, created during second t + 1
    H.time = t + 2
    RunFor(1100)
    H.eq(IdsOf(clears), ('shots_81_%d,shots_81_%d,shots_81_%d'):format(t, t + 1, t + 2),
        'next-second event clears shots_<src>_<t+1> again (the first clear came too early for it)')
    clears = {}
    Emit('shots', 81, {}, t + 1) -- another event in second t + 1
    H.time = t + 3
    RunFor(1100)
    H.eq(IdsOf(clears), ('shots_81_%d,shots_81_%d'):format(t + 1, t + 2),
        'an id cleared at s + 2 or later is not cleared again')
    H.time = t
    CP.Alerts.clear(81)
    r.state = 'ended'
end

-- 2) foreignClearedAt is recorded even when this module never saw the foreign value (e.g. after a restart)
do
    PlayerRec(82).state.crimsonArena = { active = true, matchId = 'm82' } -- written before we were watching
    BagSet(82, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[82], H.time, 'arena exit recorded from the value before the change')
end

-- 3) a pick-up the server cancels after client:pickup went out tells the client to stop
do
    ems.doctors = 0
    local r = NewRun('r-rv-3', { srcs = { 83 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(83, r)
    downed[83] = true
    local e = UntilRemoved(83, 'downed')
    RunFor(15000 - (H.clockMs - e.at))
    H.eq(#ClientEvents('client:pickup', 83), 1, 'pick-up sent')
    downed[83] = nil                             -- revived by someone else during the fade-out
    RunFor(2000)
    H.eq(CountRevives(83), 0, 'no revive after the re-check failed')
    local pc = ClientEvents('client:pickupCancel', 83)
    H.eq(#pc, 1, 'client told to cancel the pick-up')
    H.eq(pc[1] and pc[1].args[1], 'r-rv-3', 'cancel carries the run id')
    H.eq(Bag(83), nil, 'flag removed')

    local r2 = NewRun('r-rv-3b', { srcs = { 84 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(84, r2)
    downed[84] = true
    e = UntilRemoved(84, 'downed')
    RunFor(15000 - (H.clockMs - e.at) + 1600) -- pick-up sent and revive done: waiting for pickupDone
    H.eq(CountRevives(84), 1, 'revived')
    for _, fn in ipairs(unloadListeners) do CreateThread(function() fn(84) end) end
    H.step(0)
    H.eq(#ClientEvents('client:pickupCancel', 84), 1, 'unload during the pick-up cancels it on the client')
    H.eq(Bag(84), nil, 'unload: flag removed')
    downed[84] = nil
end

-- 4) integration: CP.Ambulance.revive refuses (false: sc-ambulance stopped, in the arena, not connected) or
--    raises -> the pick-up is cancelled at once (the client fades back in) and the flag goes; no 30 s wait
do
    ems.doctors = 0
    local realRevive = CP.Ambulance.revive
    for i, mode in ipairs({ 'false', 'error', 'missing' }) do
        local src = 85 + i
        if mode == 'false' then
            CP.Ambulance.revive = function(s) ems.revives[#ems.revives + 1] = s; return false end
        elseif mode == 'error' then
            CP.Ambulance.revive = function() error('sc-ambulance broken') end
        else
            CP.Ambulance.revive = nil
        end
        local r = NewRun('r-rv-4' .. mode, { srcs = { src }, arrived = true, state = 'in_progress' })
        CP.Alerts.set(src, r)
        downed[src] = true
        local e = UntilRemoved(src, 'downed')
        RunFor(15000 - (H.clockMs - e.at) + 1700) -- pick-up sent, fade over, revive attempted
        H.eq(#ClientEvents('client:pickup', src), 1, 'revive ' .. mode .. ': pick-up sent')
        local pc = ClientEvents('client:pickupCancel', src)
        H.eq(#pc, 1, 'revive ' .. mode .. ': the client is told to cancel right away')
        H.eq(pc[1] and pc[1].args[1], r.id, 'revive ' .. mode .. ': cancel carries the run id')
        H.eq(Bag(src), nil, 'revive ' .. mode .. ': flag removed')
        H.eq(CP.Downed.isPending(src), false, 'revive ' .. mode .. ': nothing pending any more')
        H.eq(r.participants[src].endReason, 'downed', 'revive ' .. mode .. ': the result stays downed')
        downed[src] = nil
    end
    CP.Ambulance.revive = realRevive
end

-- ============================================================================
--                REVIEW (spec lens): regressions for the fixes
-- ============================================================================
-- 1) dodge rule: an un-mark that arrives while the mark is still being looked up in mdt_dispatch
do
    activeCalls['5101'] = '5101'
    local realLookup = CP.Dispatch.lookupActiveCall
    CP.Dispatch.lookupActiveCall = function(id) Wait(100); return realLookup(id) end
    NewRun('r-sl-1', { srcs = { 71, 72 }, arrived = true, state = 'in_progress' })
    local nRe = #rlog.reclassify
    Respond(71, 5101, true)
    Respond(71, '5101', false) -- the toggle-off arrives during the lookup
    H.eq(#RemovedFor(71), 0, 'the lookup is still running')
    RunFor(300)
    H.eq(RemovedFor(71)[1] and RemovedFor(71)[1].reason, 'real_call', 'the real call still ends the run')
    H.eq(#rlog.reclassify, nRe + 1, 'an un-mark during the lookup still turns it into a normal abandon')
    H.eq(rlog.reclassify[#rlog.reclassify] and rlog.reclassify[#rlog.reclassify].run, 'r-sl-1', '...for that run')
    H.eq(rlog.reclassify[#rlog.reclassify] and rlog.reclassify[#rlog.reclassify].reason, 'real_call_cancelled',
        '...as real_call_cancelled')
    CP.Dispatch.lookupActiveCall = realLookup
    H.eq(CP.Calls.isOnCall(71), false, 'un-marked before the lookup finished: not on a call')
end

-- 2) dodge rule: an un-mark that arrives while CP.Runs.removeParticipant is still writing the row
do
    activeCalls['5102'] = '5102'
    local realRemove, realReclassify = CP.Runs.removeParticipant, CP.Runs.reclassify
    local writing, reclassifiedWhileWriting = false, nil
    CP.Runs.removeParticipant = function(...)
        local res = realRemove(...)
        writing = true
        Wait(200)                                -- the row insert yields
        writing = false
        return res
    end
    CP.Runs.reclassify = function(...)
        reclassifiedWhileWriting = writing
        return realReclassify(...)
    end
    NewRun('r-sl-2', { srcs = { 73, 74 }, arrived = true, state = 'in_progress' })
    local nRe = #rlog.reclassify
    Respond(73, 5102, true)
    H.eq(RemovedFor(73)[1] and RemovedFor(73)[1].reason, 'real_call', 'removal started')
    Respond(73, '5102', false) -- the toggle-off arrives before the row exists
    H.eq(#rlog.reclassify, nRe, 'reclassify waits for the row')
    RunFor(400)
    H.eq(#rlog.reclassify, nRe + 1, 'reclassified once the row is written')
    H.eq(reclassifiedWhileWriting, false, 'reclassify never runs before the row exists')
    Respond(73, '5102', false)
    RunFor(100)
    H.eq(#rlog.reclassify, nRe + 1, 'reclassified once')
    CP.Runs.removeParticipant, CP.Runs.reclassify = realRemove, realReclassify
end

-- 3) the tablet gets the route view when the warning appears / goes and after a recalculation
do
    local pushes = {}
    CP.Tablet.push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end
    CP.Runs.view = function(r, src) return { runId = r.id, route = CP.Route.status(r, src) } end
    PlayerRec(75).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-sl-3', { srcs = { 75 } })
    AlignTo(2000)
    CP.Route.begin(r, 75)
    RunFor(4000, Reporter(75, 'r-sl-3', 10.0))
    H.eq(#pushes, 0, 'nothing pushed while on route')
    RunFor(6000, Reporter(75, 'r-sl-3', 300.0))
    H.eq(CP.Route.status(r, 75).status, 'on', 'off the line for less than warnAfter: no warning, status on')
    H.eq(CP.Route.status(r, 75).secondsLeft, nil, '...and no countdown')
    H.eq(#pushes, 0, 'nothing pushed before the warning')
    RunFor(6000, Reporter(75, 'r-sl-3', 300.0))
    H.eq(CP.Route.status(r, 75).status, 'off', 'status off once the warning shows')
    H.eq(#pushes, 1, 'view pushed when the warning appears')
    H.eq(pushes[1] and pushes[1].topic, 'run', 'push topic \'run\'')
    H.eq(pushes[1] and pushes[1].src, 75, 'to that participant')
    H.eq(pushes[1] and pushes[1].data.route.status, 'off', 'the tablet shows off route')
    H.eq(pushes[1] and pushes[1].data.route.secondsLeft, 20, '...with the seconds left')
    RunFor(4000, Reporter(75, 'r-sl-3', 300.0))
    H.eq(#pushes, 1, 'pushed once per warning, not every second')
    RunFor(2000, Reporter(75, 'r-sl-3', 10.0))
    H.eq(#pushes, 2, 'view pushed when the warning goes')
    H.eq(pushes[2] and pushes[2].data.route.status, 'on', 'the tablet shows on route again')
    H.fire(CP.e('server:recalcRoute'), 75, 'r-sl-3')
    H.eq(#pushes, 3, 'view pushed after a recalculation')
    H.eq(pushes[3] and pushes[3].data.route.recalcsLeft, 1, '...with the recalculations left')
    CP.Route.stop(r, 75)
    r.state = 'ended'
    CP.Tablet.push, CP.Runs.view = nil, nil
end

-- 4) a small maxDeviation does not make honest reports at speed count as missing
do
    local old = Config.Route.maxDeviation
    Config.Route.maxDeviation = 40.0
    PlayerRec(76).coords = vec3(0.0, 0.0, 0.0)
    local r = NewRun('r-sl-4', { srcs = { 76 } })
    AlignTo(1000)
    CP.Route.begin(r, 76)
    RunFor(24000, function(c)
        if c % 2000 == 0 then
            Report(76, 'r-sl-4', 5.0, vec3(100.0, 0.0, 0.0))
        end -- 100 m ahead of the server
    end)
    H.eq(#ClientEvents('client:routeWarning', 76), 0, 'reports within 150 m of the server position count')
    H.eq(CP.Route.status(r, 76).status, 'on', 'still on route')
    Config.Route.maxDeviation = old
    CP.Route.stop(r, 76)
    r.state = 'ended'
end

-- ============================================================================
--                                   ROUND 3
-- ============================================================================
-- CP.Downed.handle (endRun), the metadata listener, CP.Alerts.forget.
-- 1) handle (no EMS): the participant leaves with keepFlag before handle returns, then the pick-up flow
do
    ems.doctors = 0
    PlayerRec(61).coords = vec3(-240.0, 6300.0, 32.0)
    local r = NewRun('r-dh-1', { srcs = { 61, 62 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(61, r)
    CP.Alerts.set(62, r)
    downed[61] = true
    local removedBefore, at = #rlog.removed, H.clockMs
    H.eq(CP.Downed.handle(r, 61), true, 'handle: true')
    H.eq(#rlog.removed, removedBefore + 1, 'handle: removed at once')
    local e = FirstRemoval(61, 'downed')
    H.eq(e and e.keepFlag, true, 'handle: end_reason \'downed\' with keepFlag')
    H.eq(e and e.at, at, 'handle: removed before its first yield (same instant)')
    H.eq(r.participants[61].status, 'left', 'handle: left before handle returned')
    H.ok(OURS(Bag(61)) and CP.Alerts.has(61), 'handle: flag kept (the hold beats the engine clear)')
    H.eq(CP.Downed.isPending(61), true, 'handle: pick-up pending')
    H.eq(r.stats.downs, 1, 'handle: one down')
    H.eq(NotesFor(61, 'downed.pickup_soon'), 1, 'handle: toast pick-up soon')
    H.eq(r.participants[62].status, 'active', 'handle: the partner is left for the engine to end')
    H.eq(CP.Downed.handle(r, 61), false, 'handle again: no longer active, nothing done')
    RunFor(15000)
    H.eq(#ClientEvents('client:pickup', 61), 1, 'handle: pick-up after 15 s')
    RunFor(2000)
    H.eq(CountRevives(61), 1, 'handle: revived')
    H.fire(CP.e('server:pickupDone'), 61, 'r-dh-1', true)
    H.eq(Bag(61), nil, 'handle: flag cleared after the pick-up')
    RunFor(4000)
    H.eq(#ClientEvents('client:pickup', 61), 1, 'handle: never picked up twice (the poll keeps off)')
    H.eq(#RemovedFor(61), 1, 'handle: removed once')
    downed[61] = nil
    r.state = 'ended'
    CP.Alerts.clear(62)
end

-- 2) handle with EMS on duty: flag cleared, then exactly one EMS request
do
    ems.doctors = 1
    local r = NewRun('r-dh-2', { srcs = { 63 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(63, r)
    downed[63] = true
    H.eq(CP.Downed.handle(r, 63), true, 'handle (EMS): true')
    H.eq(FirstRemoval(63, 'downed') and FirstRemoval(63, 'downed').keepFlag, true, 'handle (EMS): keepFlag')
    RunFor(200)
    H.eq(Bag(63), nil, 'handle (EMS): flag removed before the request')
    local req = ClientEvents('client:requestEMS', 63)
    H.eq(#req, 1, 'handle (EMS): one EMS request')
    H.eq(req[1] and req[1].args[1], 'r-dh-2', 'handle (EMS): request carries the run id')
    RunFor(6000)
    H.eq(#ClientEvents('client:requestEMS', 63), 1, 'handle (EMS): never twice')
    downed[63] = nil
end

-- 3) handle refuses what is not its to handle (the engine then removes them itself)
do
    ems.doctors = 0
    local r = NewRun('r-dh-3', { srcs = { 64 }, arrived = true, state = 'in_progress' })
    downed[64] = true
    buckets[64] = 4400
    H.eq(CP.Downed.handle(r, 64), false, 'handle: in the arena -> false')
    buckets[64] = nil
    H.eq(CP.Downed.handle(r, 999), false, 'handle: not a participant -> false')
    H.eq(CP.Downed.handle(r, 'x'), false, 'handle: bad src -> false')
    H.eq(CP.Downed.handle(nil, 64), false, 'handle: no run -> false')
    r.state = 'ended'
    H.eq(CP.Downed.handle(r, 64), false, 'handle: ended run -> false')
    H.eq(#RemovedFor(64), 0, 'handle refusals: nothing removed')
    downed[64] = nil
end

-- 4) the poll / metadata listener saw the down first but its thread has not run yet (CreateThread is
--    deferred in FiveM): handle makes them leave now and that thread only does the follow-up
do
    ems.doctors = 0
    local r = NewRun('r-dh-4', { srcs = { 65, 66 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(65, r)
    downed[65] = true
    local realCT = CreateThread
    local queued = {}
    CreateThread = function(fn) queued[#queued + 1] = fn end
    metaListeners[1].fn(65, 'isdead', false, true)
    CreateThread = realCT
    H.eq(#queued, 1, 'race: the flow thread is queued')
    H.eq(CP.Downed.isPending(65), true, 'race: the down is recorded')
    H.eq(r.participants[65].status, 'active', 'race: not removed yet')
    H.eq(CP.Downed.handle(r, 65), true, 'race: handle -> true')
    H.eq(r.participants[65].status, 'left', 'race: removed by handle at once')
    H.eq(FirstRemoval(65, 'downed') and FirstRemoval(65, 'downed').keepFlag, true, 'race: keepFlag')
    realCT(queued[1])
    H.eq(#RemovedFor(65), 1, 'race: the queued thread does not remove them again')
    H.eq(r.stats.downs, 1, 'race: one down')
    H.eq(NotesFor(65, 'downed.pickup_soon'), 1, 'race: one follow-up')
    RunFor(15100)
    H.eq(#ClientEvents('client:pickup', 65), 1, 'race: one pick-up')
    downed[65] = nil
    r.state = 'ended'
end

-- 5) the metadata listener reacts at once (no 2 s poll wait); other keys, recoveries and non-participants
--    are ignored
do
    ems.doctors = 1
    AlignTo(2000)
    H.step(100)
    local r = NewRun('r-dh-5', { srcs = { 67 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(67, r)
    downed[67] = true
    metaListeners[1].fn(67, 'inlaststand', false, true)
    H.ok(FirstRemoval(67, 'downed') ~= nil, 'metadata: removed at once, before the next poll')
    H.eq(#ClientEvents('client:requestEMS', 67), 1, 'metadata: the EMS flow ran')
    metaListeners[1].fn(67, 'isdead', false, true)
    H.eq(#RemovedFor(67), 1, 'metadata: a second event for the same down does nothing')
    downed[67] = nil
    local r2 = NewRun('r-dh-5b', { srcs = { 68 }, arrived = true, state = 'in_progress' })
    downed[68] = true
    metaListeners[1].fn(68, 'hunger', 50, 40)
    metaListeners[1].fn(68, 'isdead', true, false)
    metaListeners[1].fn(68, 'isdead', false, 1)
    H.eq(#RemovedFor(68), 0, 'metadata: other keys, a recovery or a non-true value do nothing')
    downed[68] = nil
    metaListeners[1].fn(68, 'isdead', false, true)
    H.eq(#RemovedFor(68), 0, 'metadata: re-checked with CP.Qbx.isDowned (already recovered)')
    r2.state = 'ended'
    downed[69] = true
    metaListeners[1].fn(69, 'isdead', false, true)
    H.eq(#RemovedFor(69), 0, 'metadata: not on a run -> nothing')
    downed[69] = nil
end

-- 6) CP.Alerts.forget drops our intent and never touches the bag
do
    local r = NewRun('r-af-1', { srcs = { 70 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(70, r)
    CP.Alerts.hold(70, true)
    H.ok(OURS(Bag(70)), 'forget: flag on before')
    buckets[70] = 7000                        -- only the routing bucket moved: our value is still on the bag
    H.eq(CP.Alerts.forget(70), true, 'forget: an intent was dropped')
    H.eq(CP.Alerts.has(70), false, 'forget: intent gone')
    H.ok(OURS(Bag(70)), 'forget: the bag is left alone')
    H.eq(CP.Alerts.forget(70), false, 'forget again: nothing to drop')
    H.eq(CP.Alerts.forget('abc'), false, 'forget: bad src')
    r.state = 'ended'
    RunFor(5000)
    H.ok(OURS(Bag(70)), 'forget: the reconcile and the orphan grace never touch the bag afterwards')
    buckets[70] = nil
    H.eq(CP.Alerts.clear(70), true, 'forget dropped the hold too: a later clear removes our value')
    H.eq(Bag(70), nil, 'value removed by that clear')
end

-- 7) a participant who left because only the routing bucket moved (an interior, another instancing script) keeps
--    our value while in that bucket; back in bucket 0 with no run, hold or downed follow-up it goes, so
--    sc-ambulance and sc-dispatch alert for them again. A foreign value or a new intent is never touched.
do
    local r = NewRun('r-af-2', { srcs = { 90, 91, 92, 93 }, arrived = true, state = 'in_progress' })
    for _, s in ipairs({ 90, 91, 92, 93 }) do CP.Alerts.set(s, r) end
    H.ok(OURS(Bag(90)) and OURS(Bag(93)), 'stale: flags on before')
    -- qbx_core SetPlayerBucket (a property)
    for _, s in ipairs({ 90, 91, 92, 93 }) do buckets[s] = 5 end
    RunFor(1000)
    H.eq(RemovedFor(90)[1] and RemovedFor(90)[1].reason, 'quit', 'stale: another bucket mid-run -> quit')
    H.eq(NotesFor(90, 'run.left_for_arena'), 1, 'stale: toast run.left_for_arena')
    H.eq(CP.Alerts.has(90), false, 'stale: intent dropped')
    RunFor(3000)
    H.ok(OURS(Bag(90)), 'stale: the bag is left alone while in another bucket')

    -- back in bucket 0: removed by the next reconcile
    buckets[90] = nil
    RunFor(1000)
    H.eq(Bag(90), nil, 'stale: our value removed once back in bucket 0')
    H.eq(CP.Alerts.has(90), false, 'stale: no intent either')

    -- a hold (CP.Downed keeps the flag) waits for its release
    CP.Alerts.hold(91, true)
    buckets[91] = nil
    RunFor(2000)
    H.ok(OURS(Bag(91)), 'stale: kept while held')
    CP.Alerts.hold(91, false)
    RunFor(1000)
    H.eq(Bag(91), nil, 'stale: removed once the hold is released')

    -- Crimson-Arena places them: its value is never removed, not even back in bucket 0
    BagSet(92, 'crimsonArena', { active = true, matchId = 'm92' })
    H.step(0)
    buckets[92] = nil
    RunFor(2000)
    H.eq((Bag(92) or {}).matchId, 'm92', 'stale: a foreign value is left alone')

    -- a new run's arrival in bucket 0 before the reconcile ran: the value is theirs again
    local r2 = NewRun('r-af-3', { srcs = { 93 }, arrived = true, state = 'in_progress' })
    buckets[93] = nil
    H.ok(CP.Alerts.set(93, r2), 'stale: a new run sets the flag')
    RunFor(2000)
    H.ok(OURS(Bag(93)), 'stale: a new intent keeps our value')
    H.ok(CP.Alerts.has(93), 'stale: intent recorded')
    CP.Alerts.clear(93)
    r2.state = 'ended'
    BagSet(92, 'crimsonArena', nil)
    H.step(0)
end

-- ============================================================================
--                                RESOURCE STOP
-- ============================================================================
-- Every value we set goes, foreign values stay.

do
    local r = NewRun('r-stop', { srcs = { 32 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(32, r)
    H.ok(OURS(Bag(32)), 'flag on')
    H.fire('onResourceStop', 0, 'Crimson-Police')
    H.eq(Bag(32), nil, 'resource stop removes our flags')
    H.eq(Bag(22) and Bag(22).matchId, 'm0', 'resource stop leaves foreign values')
    r.state = 'ended'
end

-- ============================================================================
--               CLIENT FILES (own environment, stubbed natives)
-- ============================================================================

do
    for _, r in pairs(runs) do r.state = 'ended' end
    local serverEvents = {}
    local cstate = {
        pos = vec3(0.0, 0.0, 0.0),
        waypoint = nil,
        blips = {},
        nextBlip = 1,
        routeFound = true,
        routeLen = 1000.0,
        dead = true,
        faded = 'in',
        md = { isdead = true },
        coordsSet = nil,
        huds = {},
        overlays = {},
        toasts = {},
        arena = nil,
        emsSent = 0,
    }
    local clientCP = {
        U = CP.U,
        L = CP.L,
        Locale = CP.Locale,
        e = CP.e,
        log = CP.log,
        warn = function() end,
        err = CP.err,
        resource = 'Crimson-Police',
        prefix = 'crimson-police',
        isServer = false,
        Tablet = {
            hud = function(p) cstate.huds[#cstate.huds + 1] = p end,
            overlay = function(o) cstate.overlays[#cstate.overlays + 1] = o or false end,
            notify = function(kind, text) cstate.toasts[#cstate.toasts + 1] = { kind = kind, text = text } end,
            registerClientAction = function(name, fn) cstate['action_' .. name] = fn end,
        },
        Qbx = {
            getPlayerData = function() return { metadata = cstate.md } end,
        },
        Ambulance = {
            sendEMSRequest = function() cstate.emsSent = cstate.emsSent + 1; return true end,
        },
    }
    local env = setmetatable({
        CP = clientCP,
        PlayerPedId = function() return 1 end,
        PlayerId = function() return 0 end,
        GetPlayerServerId = function() return 61 end,
        GetEntityCoords = function() return cstate.pos end,
        SetNewWaypoint = function(x, y) cstate.waypoint = vec3(x, y, 0.0) end,
        IsWaypointActive = function() return cstate.waypoint ~= nil end,
        GetFirstBlipInfoId = function() return cstate.waypoint and 900 or 0 end,
        GetBlipInfoIdCoord = function() return cstate.waypoint end,
        SetWaypointOff = function() cstate.waypoint = nil end,
        AddBlipForCoord = function()
            local b = cstate.nextBlip
            cstate.nextBlip = b + 1
            cstate.blips[b] = true
            return b
        end,
        DoesBlipExist = function(b) return cstate.blips[b] == true or b == 900 end,
        RemoveBlip = function(b) cstate.blips[b] = nil end,
        SetBlipSprite = function() end,
        SetBlipColour = function() end,
        SetBlipScale = function() end,
        SetBlipRouteColour = function() end,
        SetBlipRoute = function() end,
        BeginTextCommandSetBlipName = function() end,
        AddTextComponentSubstringPlayerName = function() end,
        EndTextCommandSetBlipName = function() end,
        GetGpsBlipRouteFound = function() return cstate.routeFound end,
        GetGpsBlipRouteLength = function() return cstate.routeFound and cstate.routeLen or 0 end,
        -- the GPS route goes north 500 m, then east to the start at (500, 500)
        GetPosAlongGpsTypeRoute = function(_, d, slot)
            if not cstate.routeFound or slot ~= 1 then return false, nil end
            if d <= 500 then return true, vec3(0.0, d, 0.0) end
            return true, vec3(d - 500.0, 500.0, 0.0)
        end,
        TriggerServerEvent = function(name, ...) serverEvents[#serverEvents + 1] = { name = name, args = { ... } } end,
        IsEntityDead = function() return cstate.dead end,
        DoScreenFadeOut = function() cstate.faded = 'out' end,
        DoScreenFadeIn = function() cstate.faded = 'in' end,
        IsScreenFadedOut = function() return cstate.faded == 'out' end,
        IsScreenFadedIn = function() return cstate.faded == 'in' end,
        IsEntityAttached = function() return false end,
        DetachEntity = function() end,
        IsPedInAnyVehicle = function() return false end,
        ClearPedTasksImmediately = function() end,
        RequestCollisionAtCoord = function() end,
        SetEntityCoords = function(_, x, y, z) cstate.coordsSet = vec3(x, y, z) end,
        HasCollisionLoadedAroundEntity = function() return true end,
        LocalPlayer = {
            state = setmetatable({}, {
                __index = function(_, k) if k == 'crimsonArena' then return cstate.arena end end,
            }),
        },
    }, { __index = _G })
    local function LoadClient(rel)
        local chunk = assert(loadfile(H.root .. rel, 't', env))
        chunk()
    end
    LoadClient('modules/route/client.lua')
    LoadClient('modules/downed/client.lua')
    H.step(0)
    local CR, CD = clientCP.Route, clientCP.Downed
    H.ok(type(CR.begin) == 'function' and type(CD.busy) == 'function', 'client modules loaded')
    H.ok(cstate.action_setGps and cstate.action_recalcRoute, 'client actions registered')
    local function Sent(name)
        local out = {}
        for _, e in ipairs(serverEvents) do if e.name == CP.e(name) then out[#out + 1] = e end end
        return out
    end
    local function LastHudRoute()
        for i = #cstate.huds, 1, -1 do if cstate.huds[i].route then return cstate.huds[i].route end end
        return nil
    end

    -- begin: waypoint + sampled polyline + reports of the distance to that line
    H.ok(CR.begin('c-run-1', vec3(500.0, 500.0, 0.0)), 'client begin')
    H.eq(cstate.waypoint and cstate.waypoint.x, 500.0, 'waypoint set to the start')
    RunFor(2100)
    local rep = Sent('server:routeStatus')
    H.ok(#rep >= 1, 'reports sent')
    H.eq(rep[1] and rep[1].args[1], 'c-run-1', 'report carries the run id')
    H.near(rep[1] and rep[1].args[2], 0.0, 1e-6, 'on the polyline: 0 m')
    H.eq(LastHudRoute() and LastHudRoute().status, 'on', 'HUD route on')
    H.eq(LastHudRoute() and LastHudRoute().distance, 1000, 'HUD distance along the fixed line')
    local nBlips = 0
    for _ in pairs(cstate.blips) do nBlips = nBlips + 1 end
    H.eq(nBlips, 0, 'the temporary route blip is removed after sampling')

    -- off the line: the distance to the FIXED polyline is reported (the GPS may recalculate, the line does not)
    cstate.pos = vec3(-150.0, 250.0, 0.0)
    cstate.routeFound = false
    RunFor(2000)
    rep = Sent('server:routeStatus')
    H.near(rep[#rep].args[2], 150.0, 1e-6, 'distance to the fixed polyline')
    H.eq(LastHudRoute().status, 'on', 'no off-route warning on the HUD before the server sends it (warnAfter)')

    -- server warning -> HUD seconds + one toast; withdrawn -> on
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', 20)
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', 19)
    H.eq(LastHudRoute().status, 'off', 'HUD off with the warning')
    H.eq(LastHudRoute().secondsLeft, 19, 'HUD shows the seconds left')
    local warnToasts = 0
    for _, t in ipairs(cstate.toasts) do
        if t.kind == 'warning' and t.text:find('within 20 s', 1, true) then warnToasts = warnToasts + 1 end
    end
    H.eq(warnToasts, 1, 'one toast when the warning first appears')
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', nil)
    H.eq(LastHudRoute().secondsLeft, nil, 'warning withdrawn')

    -- recalculate: the server grants it, the line is resampled from here (straight line when no GPS route)
    local result
    CreateThread(function() result = { cstate.action_recalcRoute({}) } end)
    H.eq(#Sent('server:recalcRoute'), 1, 'recalc asks the server')
    TriggerEvent(CP.e('client:routeRecalc'), 'c-run-1', true, 1)
    RunFor(6000)
    H.eq(result and result[1], true, 'recalc ok')
    H.eq(result and result[2] and result[2].recalcsLeft, 1, 'recalcs left passed on')
    rep = Sent('server:routeStatus')
    H.near(rep[#rep].args[2], 0.0, 1e-6, 'new straight line starts where the player is')
    CreateThread(function() result = { cstate.action_recalcRoute({}) } end)
    TriggerEvent(CP.e('client:routeRecalc'), 'c-run-1', false, 0)
    RunFor(100)
    H.eq(result[1], false, 'refused recalc')
    H.eq(result[2], 'err.route_no_recalcs', 'refusal key')

    -- arrival from the server: reports stop, waypoint removed
    TriggerEvent(CP.e('client:routeStatus'), 'c-run-1', { status = 'arrived' })
    H.eq(LastHudRoute().status, 'arrived', 'HUD arrived')
    H.eq(cstate.waypoint, nil, 'our waypoint removed on arrival')
    local nRep = #Sent('server:routeStatus')
    RunFor(5000)
    H.eq(#Sent('server:routeStatus'), nRep, 'no reports after arrival')
    TriggerEvent(CP.e('client:runEnded'), 'c-run-1')
    H.eq(CR.current(), nil, 'stopped at the run end')
    H.eq(CR.begin('c-run-1', vec3(1.0, 1.0, 0.0)), false, 'an ended run cannot begin again')

    -- pick-up: fade, overlay, wait for the revive, move, fade in, pickupDone
    cstate.dead, cstate.md = true, { isdead = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-2', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    H.eq(cstate.faded, 'out', 'faded out')
    H.eq(cstate.overlays[#cstate.overlays] and cstate.overlays[#cstate.overlays].text, 'Picked up by an NPC unit',
        'fade overlay text')
    H.eq(cstate.coordsSet, nil, 'not moved before the revive')
    cstate.dead, cstate.md = false, { isdead = false, inlaststand = false }
    RunFor(1000)
    H.near(cstate.coordsSet and cstate.coordsSet.x, 308.19, 1e-6, 'moved to the drop-off')
    H.eq(cstate.faded, 'in', 'faded back in')
    H.eq(cstate.overlays[#cstate.overlays], false, 'overlay cleared')
    local done = Sent('server:pickupDone')
    H.eq(done[1] and done[1].args[1], 'c-run-2', 'pickupDone sent')
    H.eq(done[1] and done[1].args[2], true, 'pickupDone ok')

    -- pick-up aborted by a foreign arena value: fades back in, no move
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-3', vec3(308.19, -595.35, 43.29))
    RunFor(500)
    cstate.arena = { active = true, matchId = 'mx' }
    RunFor(1000)
    H.eq(cstate.coordsSet, nil, 'no teleport into or out of the arena')
    H.eq(cstate.faded, 'in', 'abort fades back in')
    done = Sent('server:pickupDone')
    H.eq(done[#done].args[2], false, 'abort reported')
    cstate.arena = nil

    -- pick-up cancelled by the server (client:pickupCancel): fades back in, never teleports, even if a
    -- revive arrives afterwards
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-5', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    TriggerEvent(CP.e('client:pickupCancel'), 'other-run')
    RunFor(300)
    H.ok(CD.busy(), 'a cancel for another run is ignored')
    TriggerEvent(CP.e('client:pickupCancel'), 'c-run-5')
    cstate.dead, cstate.md = false, { isdead = false, inlaststand = false }
    RunFor(1000)
    H.eq(cstate.coordsSet, nil, 'cancelled pick-up: no teleport')
    H.eq(cstate.faded, 'in', 'cancelled pick-up fades back in')
    H.eq(cstate.overlays[#cstate.overlays], false, 'cancelled pick-up clears the overlay')
    H.eq(CD.busy(), false, 'pick-up no longer running')

    -- logout / character switch during the pick-up: no metadata is not "revived" (no teleport), it aborts
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-6', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    cstate.dead, cstate.md = false, nil          -- CP.Qbx.getPlayerData() has no character any more
    RunFor(1000)
    H.eq(cstate.coordsSet, nil, 'no character loaded: no teleport')
    H.eq(cstate.faded, 'in', 'no character loaded: faded back in')
    done = Sent('server:pickupDone')
    H.eq(done[#done].args[1], 'c-run-6', 'abort reported for that run')
    H.eq(done[#done].args[2], false, 'abort reported as not done')
    cstate.md = {}

    -- EMS request from the own client
    TriggerEvent(CP.e('client:requestEMS'), 'c-run-4')
    H.eq(cstate.emsSent, 1, 'EMS request sent from the client')
end

return H
