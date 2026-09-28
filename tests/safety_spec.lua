-- tests/safety_spec.lua · modules/route, calls, alerts, downed (slice safety: Hard rules 15-18).
--
-- CP.Runs, CP.Dispatch, CP.Ambulance, CP.Qbx, CP.Tablet and CP.Admin are stubbed; the four server
-- modules run together with their real 1 s / 2 s loops on the harness clock (H.step / H.advance).
-- The state bag is simulated: every write goes through bagSet, which fires the registered
-- AddStateBagChangeHandler handlers before the value changes (as FiveM does). At the end the two client
-- files are loaded in their own environment (a separate CP table) with stubbed natives.
-- No database is used.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ── locale: serve this slice's part as en.json so CP.L returns real text ─────
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
H.eq(CP.L('route.warning', { seconds = 20 }), 'You left the route to the start. Get back on it within 20 s or your mission is abandoned.', 'locale vars')

-- ── natives the harness does not have ───────────────────────────────────────
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

local function playerRec(src)
    local p = H.players[src]
    if not p then p = {}; H.players[src] = p end
    p.state = p.state or {}
    return p
end

-- Any resource writing the replicated bag: change handlers first, then the value.
local function bagSet(src, key, value)
    local p = playerRec(src)
    for _, h in ipairs(bagHandlers) do
        if h.key == nil or h.key == key then h.fn(('player:%d'):format(src), key, value, 0, true) end
    end
    p.state[key] = value
end

Player = function(src)
    src = tonumber(src)
    local p = playerRec(src)
    local st = p.state
    return { state = setmetatable({ set = function(_, k, v) bagSet(src, k, v) end }, { __index = st }) }
end

local dropped = {}
GetPlayerName = function(src)
    if dropped[tonumber(src)] then return nil end
    return 'Player' .. tostring(src)
end

local function bag(src) return playerRec(src).state.crimsonArena end
local OURS = function(v) return type(v) == 'table' and v.active == true and v.source == 'crimson-police' end

-- ── stubs ───────────────────────────────────────────────────────────────────
local runs = {}
local rlog = { arrived = {}, removed = {}, reclassify = {}, endRun = {} }
local runsCfg = { setFlagOnArrive = true, autoEnd = true, countDowns = true }

local function activeOf(r)
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
    activeSrcs = activeOf,
    markArrived = function(r, src)
        rlog.arrived[#rlog.arrived + 1] = { run = r.id, src = src }
        r.participants[src].arrived = true
        if r.state == 'accepted' then r.state = 'in_progress' end
        if runsCfg.setFlagOnArrive then CP.Alerts.set(src, r) end
    end,
    -- A deliberately careless engine: it clears the flag even when keepFlag is passed (the hold must win).
    removeParticipant = function(r, src, reason, opts)
        rlog.removed[#rlog.removed + 1] = { run = r.id, src = src, reason = reason, keepFlag = opts and opts.keepFlag or false, at = H.clockMs }
        local p = r.participants[src]
        if p.status ~= 'active' then return nil end
        p.status = 'left'
        p.endReason = reason
        if reason == 'downed' and runsCfg.countDowns then r.stats.downs = r.stats.downs + 1 end
        CP.Alerts.clear(src)
        CP.Route.stop(r, src)
        if opts and opts.notify then CP.Tablet.notify(src, 'warning', opts.notify) end
        if runsCfg.autoEnd and #activeOf(r) == 0 then r.state = 'ended' end
    end,
    reclassify = function(cid, runId, reason) rlog.reclassify[#rlog.reclassify + 1] = { cid = cid, run = runId, reason = reason } end,
    endRun = function(r, state, reason)
        rlog.endRun[#rlog.endRun + 1] = { run = r.id, state = state, reason = reason }
        r.state = 'ended'
    end,
    anchor = function(r) return r.anchor end,
}

local function newRun(id, o)
    local r = {
        id = id, missionId = o.missionId or 'test_mission', state = o.state or 'accepted', test = o.test,
        location = { start = { coords = o.start or vec3(1000.0, 0.0, 0.0), radius = o.radius or 50.0 } },
        participants = {}, stats = { downs = 0, weaponsFired = 0 }, anchor = o.anchor,
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

local function removedFor(src)
    local out = {}
    for _, e in ipairs(rlog.removed) do if e.src == src then out[#out + 1] = e end end
    return out
end

-- CP.Dispatch
local dl = { responding = {}, cleared = {}, restart = {}, shots = {}, down = {}, dead = {} }
local activeCalls = {}
local lookups = 0
local clears = {}
local function emit(kind, ...)
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
    onResponding = function(fn) table.insert(dl.responding, fn) end,
    onCallCleared = function(fn) table.insert(dl.cleared, fn) end,
    onDispatchRestart = function(fn) table.insert(dl.restart, fn) end,
    onShotsFired = function(fn) table.insert(dl.shots, fn) end,
    onPlayerDown = function(fn) table.insert(dl.down, fn) end,
    onPlayerDead = function(fn) table.insert(dl.dead, fn) end,
}

-- CP.Qbx, CP.Ambulance, CP.Tablet, CP.Admin
local downed = {}
local unloadListeners = {}
CP.Qbx = {
    isDowned = function(src) return downed[src] == true end,
    onPlayerUnload = function(fn) unloadListeners[#unloadListeners + 1] = fn end,
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
        audits[#audits + 1] = { actor = actor, role = role, category = category, action = action, target = target, new = new, reason = reason }
    end,
}

local function notesFor(src, key)
    local n = 0
    for _, e in ipairs(notes) do if e.src == src and e.key == key then n = n + 1 end end
    return n
end

local function clientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then out[#out + 1] = e end
    end
    return out
end

local function countRevives(src)
    local n = 0
    for _, s in ipairs(ems.revives) do if s == src then n = n + 1 end end
    return n
end

-- ── leftovers before the start: ours is removed, a foreign value is kept ─────
playerRec(21).state.crimsonArena = { active = true, source = 'crimson-police' }
playerRec(22).state.crimsonArena = { active = true, matchId = 'm0' }

-- ── load the slice ──────────────────────────────────────────────────────────
H.load('modules/alerts/server.lua')
H.load('modules/route/server.lua')
H.load('modules/calls/server.lua')
H.load('modules/downed/server.lua')
H.step(0)   -- runtime wiring (every module registers its listeners after Wait(0))

H.eq(bag(21), nil, 'start: leftover Crimson-Police flag removed')
H.eq(bag(22) and bag(22).matchId, 'm0', 'start: foreign value kept')
H.eq(#dl.responding, 1, 'calls listens to responding')
H.eq(#dl.shots, 1, 'alerts listens to shots fired')
H.eq(#dl.down + #dl.dead, 2, 'alerts listens to person down / dead')
H.eq(#unloadListeners, 1, 'downed listens to character unload')

-- advance ms in 100 ms steps, calling each(clock) after every step
local function runFor(ms, each)
    local target = H.clockMs + ms
    while H.clockMs < target do
        H.step(100)
        if each then each(H.clockMs) end
    end
end

-- run until the clock is a multiple of `m` (a tick boundary of the loops)
local function alignTo(m)
    while H.clockMs % m ~= 0 do H.step(100) end
end

local function report(src, runId, metres, coords)
    H.fire(CP.e('server:routeStatus'), src, runId, metres, coords or playerRec(src).coords)
end

-- reporter(src, runId, metresFn) reports every 2 s on the clock
local function reporter(src, runId, metres)
    return function(c)
        if c % 2000 == 0 then
            local m = type(metres) == 'function' and metres(c) or metres
            if m then report(src, runId, m) end
        end
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ROUTE
-- ═══════════════════════════════════════════════════════════════════════════
alignTo(2000)

-- 1) off route: warning at 10 s, abandon at 30 s
do
    playerRec(1).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-1', { srcs = { 1 } })
    H.ok(CP.Route.begin(r, 1), 'route begin')
    H.ok(CP.Route.begin(r, 1), 'route begin is idempotent')
    local st = CP.Route.status(r, 1)
    H.eq(st.status, 'on', 'status on')
    H.eq(st.recalcsLeft, 2, 'two recalcs')
    H.eq(st.distance, 1000, 'distance to the start')
    runFor(6000, reporter(1, 'r-route-1', 20.0))
    H.eq(#clientEvents('client:routeWarning', 1), 0, 'on route: no warning')
    local offAt = H.clockMs + 2000
    local warnedAt, removedAt
    runFor(40000, function(c)
        if c % 2000 == 0 and r.participants[1].status == 'active' then report(1, 'r-route-1', 200.0) end
        if not warnedAt and #clientEvents('client:routeWarning', 1) > 0 then warnedAt = c end
        if not removedAt and #removedFor(1) > 0 then removedAt = c end
    end)
    H.eq(warnedAt and warnedAt - offAt, 10000, 'warning 10 s after leaving the route')
    local w = clientEvents('client:routeWarning', 1)[1]
    H.eq(w and w.args[1], 'r-route-1', 'warning carries the run id')
    H.eq(w and w.args[2], 20, 'warning carries the seconds left')
    H.eq(removedAt and removedAt - offAt, 30000, 'abandoned 30 s after leaving the route')
    H.eq(removedFor(1)[1] and removedFor(1)[1].reason, 'off_route', 'end reason off_route')
    H.eq(#removedFor(1), 1, 'removed once')
end

-- 2) back within maxDeviation resets the stretch; a shown warning is withdrawn
do
    playerRec(2).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-2', { srcs = { 2 } })
    CP.Route.begin(r, 2)
    alignTo(2000)
    local A = H.clockMs + 2000
    local warnedAt
    runFor(24000, function(c)
        if c % 2000 == 0 then
            local d = c - A
            local m = 200.0
            if d == 8000 or d == 22000 then m = 50.0 end
            report(2, 'r-route-2', m)
        end
        if not warnedAt and #clientEvents('client:routeWarning', 2) > 0 then warnedAt = c end
    end)
    H.eq(warnedAt and warnedAt - A, 20000, 'the back-on-route report restarted the 10 s')
    local ws = clientEvents('client:routeWarning', 2)
    H.eq(ws[#ws].args[2], nil, 'back on route withdraws the warning')
    H.eq(CP.Route.status(r, 2).status, 'on', 'status on again')
    H.eq(#removedFor(2), 0, 'not abandoned')
    CP.Route.stop(r, 2)
end

-- 3) missing reports count as off route
do
    playerRec(3).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-3', { srcs = { 3 } })
    alignTo(1000)
    CP.Route.begin(r, 3)
    local C = H.clockMs
    report(3, 'r-route-3', 10.0)
    local warnedAt, removedAt
    runFor(42000, function(c)
        if not warnedAt and #clientEvents('client:routeWarning', 3) > 0 then warnedAt = c end
        if not removedAt and #removedFor(3) > 0 then removedAt = c end
    end)
    H.eq(warnedAt and warnedAt - C, 20000, 'no report for 10 s = off route, warned 10 s later')
    H.eq(removedAt and removedAt - C, 40000, 'abandoned 30 s after the reports stopped counting')
    H.eq(removedFor(3)[1] and removedFor(3)[1].reason, 'off_route', 'missing reports -> off_route')
end

-- 4) a report whose coords do not match the server position is ignored (counts as missing)
do
    playerRec(4).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-4', { srcs = { 4 } })
    alignTo(1000)
    CP.Route.begin(r, 4)
    local C = H.clockMs
    local warnedAt
    runFor(21000, function(c)
        if c % 2000 == 0 then report(4, 'r-route-4', 0.0, vec3(600.0, 0.0, 0.0)) end
        if not warnedAt and #clientEvents('client:routeWarning', 4) > 0 then warnedAt = c end
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
    playerRec(5).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-5', { srcs = { 5 } })
    alignTo(2000)
    CP.Route.begin(r, 5)
    report(5, 'r-route-5', 300.0)
    runFor(12000, reporter(5, 'r-route-5', 300.0))
    H.ok(#clientEvents('client:routeWarning', 5) > 0, 'warned before the recalc')
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    local rc = clientEvents('client:routeRecalc', 5)
    H.eq(rc[1] and rc[1].args[2], true, 'first recalc granted')
    H.eq(rc[1] and rc[1].args[3], 1, 'one recalc left')
    local ws = clientEvents('client:routeWarning', 5)
    H.eq(ws[#ws].args[2], nil, 'recalc withdraws the warning')
    H.eq(CP.Route.status(r, 5).status, 'on', 'recalc: on route again')
    runFor(2500, reporter(5, 'r-route-5', 10.0))
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    runFor(2500, reporter(5, 'r-route-5', 10.0))
    H.fire(CP.e('server:recalcRoute'), 5, 'r-route-5')
    rc = clientEvents('client:routeRecalc', 5)
    H.eq(#rc, 3, 'three replies')
    H.eq(rc[2].args[2], true, 'second recalc granted')
    H.eq(rc[3].args[2], false, 'third recalc refused')
    H.eq(CP.Route.status(r, 5).recalcsLeft, 0, 'no recalcs left')
    H.fire(CP.e('server:recalcRoute'), 6, 'r-route-5')
    H.eq(#clientEvents('client:routeRecalc', 6), 1, 'a non-participant gets a reply')
    H.eq(clientEvents('client:routeRecalc', 6)[1].args[2], false, '...which is a refusal')
    CP.Route.stop(r, 5)
end

-- 6) drift: further from the start than the closest point + maxDrift -> off_route whatever the reports say
do
    playerRec(6).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-6', { srcs = { 6 } })
    CP.Route.begin(r, 6)
    runFor(3000, reporter(6, 'r-route-6', 0.0))
    playerRec(6).coords = vec3(-500.0, 0.0, 0.0)          -- 1500 m: 500 past the closest (1000)
    runFor(3000, reporter(6, 'r-route-6', 0.0))
    H.eq(#removedFor(6), 0, 'drift within maxDrift is fine')
    playerRec(6).coords = vec3(-1050.0, 0.0, 0.0)         -- 2050 m: 1050 past the closest
    runFor(1500, reporter(6, 'r-route-6', 0.0))
    H.eq(removedFor(6)[1] and removedFor(6)[1].reason, 'off_route', 'drift check abandons the run')
end

-- 7) arrival: server-side position inside the start radius -> markArrived, flag, checks stop
do
    playerRec(7).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-7', { srcs = { 7 } })
    CP.Route.begin(r, 7)
    runFor(2000, reporter(7, 'r-route-7', 5.0))
    playerRec(7).coords = vec3(970.0, 10.0, 0.0)
    runFor(1000)
    H.eq(rlog.arrived[#rlog.arrived].src, 7, 'markArrived called')
    H.eq(r.state, 'in_progress', 'the first arrival starts the run (stub)')
    H.ok(CP.Alerts.has(7) and OURS(bag(7)), 'flag on at the start')
    local rs = clientEvents('client:routeStatus', 7)
    H.eq(rs[1] and rs[1].args[2].status, 'arrived', 'client told about the arrival')
    H.eq(CP.Route.status(r, 7).status, 'arrived', 'status arrived')
    playerRec(7).coords = vec3(-3000.0, 0.0, 0.0)          -- far away, silent: no checks any more
    runFor(45000)
    H.eq(#removedFor(7), 0, 'no route checks after arrival')
    local n = 0
    for _, a in ipairs(rlog.arrived) do if a.src == 7 then n = n + 1 end end
    H.eq(n, 1, 'arrival marked once')
end

-- 8) arrival sets the flag even when the engine does not
do
    runsCfg.setFlagOnArrive = false
    playerRec(8).coords = vec3(1010.0, 0.0, 0.0)
    local r = newRun('r-route-8', { srcs = { 8 } })
    CP.Route.begin(r, 8)
    runFor(1000)
    H.ok(r.participants[8].arrived, 'arrived at once (inside the radius)')
    H.ok(CP.Alerts.has(8) and OURS(bag(8)), 'route set the flag itself')
    runsCfg.setFlagOnArrive = true
end

-- 9) test run without the start route: arrival check only
do
    playerRec(9).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-9', { srcs = { 9 }, test = { adminSrc = 1, useStartRoute = false } })
    CP.Route.begin(r, 9)
    H.eq(CP.Route.status(r, 9).status, 'disabled', 'status disabled')
    playerRec(9).coords = vec3(-2500.0, 0.0, 0.0)
    runFor(45000)
    H.eq(#removedFor(9), 0, 'no off-route or drift check without the start route')
    H.eq(#clientEvents('client:routeWarning', 9), 0, 'no warning without the start route')
    playerRec(9).coords = vec3(1000.0, 20.0, 0.0)
    runFor(1000)
    H.ok(r.participants[9].arrived, 'arrival still checked')
end

-- 10) in-arena participants are not route-checked and cannot arrive (CP.Alerts removes them as quit)
do
    playerRec(10).coords = vec3(995.0, 0.0, 0.0)
    buckets[10] = 4210
    local r = newRun('r-route-10', { srcs = { 10 } })
    CP.Route.begin(r, 10)
    report(10, 'r-route-10', 500.0)
    runFor(2000)
    H.eq(r.participants[10].arrived, false, 'no arrival in an arena bucket')
    H.eq(removedFor(10)[1] and removedFor(10)[1].reason, 'quit', 'in-arena participant leaves as quit')
    H.eq(notesFor(10, 'run.left_for_arena'), 1, 'toast run.left_for_arena')
    buckets[10] = nil
end

-- 11) safety net: a participant the engine never began is route-checked anyway
do
    playerRec(20).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-route-20', { srcs = { 20 } })
    H.eq(CP.Route.status(r, 20).distance, nil, 'no state yet')
    runFor(1000)
    H.eq(CP.Route.status(r, 20).distance, 1000, 'state created by the tick')
    CP.Route.stop(r, 20)
    runFor(1000)
    H.eq(CP.Route.status(r, 20).distance, nil, 'an explicit stop is respected')
    r.state = 'ended'
end

-- 12) Manhunt: the start is the search circle (first objective search_area), not the small start radius
do
    playerRec(34).coords = vec3(5520.0, 0.0, 0.0)
    local r = newRun('r-route-34', { srcs = { 34 }, start = vec3(5000.0, 0.0, 0.0), radius = 80.0 })
    r.mission = { objectives = { { block = 'search_area', center = 'center', startRadius = 600 } } }
    r.location.center = vec3(5000.0, 0.0, 0.0)
    CP.Route.begin(r, 34)
    H.eq(CP.Route.status(r, 34).status, 'on', 'outside the search circle')
    runFor(1000)
    H.ok(r.participants[34].arrived, 'inside the 600 m search circle counts as arrived')
    playerRec(35).coords = vec3(5620.0, 0.0, 0.0)
    local r2 = newRun('r-route-35', { srcs = { 35 }, start = vec3(5000.0, 0.0, 0.0), radius = 80.0 })
    r2.mission = { objectives = { { block = 'search_area', center = 'center', startRadius = 600 } } }
    r2.location.center = vec3(5000.0, 0.0, 0.0)
    CP.Route.begin(r2, 35)
    runFor(1000)
    H.eq(r2.participants[35].arrived, false, 'outside the circle: still heading there')
    CP.Route.stop(r2, 35)
    r2.state = 'ended'
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CALLS
-- ═══════════════════════════════════════════════════════════════════════════
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

local function respond(src, callId, on) emit('responding', src, callId, on) end

do
    local r = newRun('r-calls', { srcs = { 11, 12 }, left = { 14 }, arrived = true, state = 'in_progress' })

    -- npccall ids: nothing at all (not even a lookup)
    local before = lookups
    respond(11, 'npccall-3-' .. T, true)
    H.eq(lookups, before, 'npccall id: no lookup')
    H.eq(#removedFor(11), 0, 'npccall never ends a run')
    H.eq(CP.Calls.isOnCall(11), false, 'npccall: not on a call')
    respond(11, 5, true)
    H.eq(#removedFor(11), 0, 'a row id that resolves to an npccall id does not count')

    -- a call about a partner of the same run
    respond(11, 'panic_12_' .. T, true)
    H.eq(#removedFor(11), 0, "a partner's panic call does not end the run")
    H.eq(CP.Calls.isOnCall(11), false, "a partner's panic call is not a real call for them")
    respond(11, 'playerdown_14_' .. T, true)
    H.eq(#removedFor(11), 0, "a call about a partner who already left does not count either")

    -- the same id for an unrelated officer is a real call
    respond(13, 'panic_12_' .. T, true)
    H.eq(CP.Calls.isOnCall(13), true, 'own-run prefix only protects partners')

    -- faked id: not in mdt_dispatch
    respond(11, '999', true)
    H.eq(#removedFor(11), 0, 'fake id does nothing')
    H.eq(CP.Calls.isOnCall(11), false, 'fake id: not on a call')

    -- a real call ends only that participant, as real_call (no cooldown: the engine applies the table)
    respond(11, 123, true)
    local rem = removedFor(11)
    H.eq(#rem, 1, 'real call removes the participant')
    H.eq(rem[1] and rem[1].reason, 'real_call', 'end reason real_call')
    H.eq(r.participants[12].status, 'active', 'the partner carries on')
    H.eq(CP.Calls.isOnCall(11), true, 'on a call now')
    H.eq(notesFor(11, 'calls.run_ended'), 1, 'toast calls.run_ended')
    H.eq(audits[#audits] and audits[#audits].category, 'flags', 'free abandon audited under flags')
    H.eq(audits[#audits] and audits[#audits].new, '123', 'audit carries the call id')
    H.eq(#rlog.reclassify, 0, 'no reclassify yet')

    -- un-mark within the dodge window -> real_call_cancelled
    H.time = T + 30
    respond(11, '123', false)
    H.eq(#rlog.reclassify, 1, 'un-mark within 60 s reclassifies')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].reason, 'real_call_cancelled', 'real_call_cancelled')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].cid, 'CID11', 'by citizenid')
    H.eq(rlog.reclassify[1] and rlog.reclassify[1].run, 'r-calls', 'for that run')
    H.eq(CP.Calls.isOnCall(11), false, 'un-marked: not on a call')
    respond(11, '123', false)
    H.eq(#rlog.reclassify, 1, 'reclassified once')

    -- own-run prefix match is exact: panic_121_ is not about participant 12
    respond(12, 'panic_121_' .. T, true)
    H.eq(removedFor(12)[1] and removedFor(12)[1].reason, 'real_call', 'panic_121_ is not playerdown of 12: real call')
end

do
    -- un-mark after the window: stays a free abandon
    H.time = T + 100
    newRun('r-calls-2', { srcs = { 15 }, arrived = true, state = 'in_progress' })
    respond(15, 456, true)
    H.eq(removedFor(15)[1] and removedFor(15)[1].reason, 'real_call', 'real call')
    H.time = T + 100 + 61
    respond(15, '456', false)
    H.eq(#rlog.reclassify, 1, 'un-mark after 60 s changes nothing')
end

do
    -- respondingExpiry: 13 has been on a call since T
    H.time = T + 1199
    H.eq(CP.Calls.isOnCall(13), true, 'entry alive before the expiry')
    H.time = T + 1200
    H.eq(CP.Calls.isOnCall(13), false, 'entry expires after Config.Calls.respondingExpiry')

    -- auto-cleared calls: re-checked in mdt_dispatch
    respond(16, '777', true)
    H.eq(CP.Calls.isOnCall(16), true, 'on call 777')
    activeCalls['777'] = nil
    H.time = H.time + 5
    H.eq(CP.Calls.isOnCall(16), true, 'still cached right after')
    H.time = H.time + 10
    H.eq(CP.Calls.isOnCall(16), false, 'an auto-cleared call is dropped on the next check')

    -- callClearedByOfficer, also in another id form
    respond(17, '888', true)
    respond(18, 889, true)
    H.eq(CP.Calls.isOnCall(17) and CP.Calls.isOnCall(18), true, 'on calls 888 / 889')
    emit('cleared', 888)
    emit('cleared', '889')
    H.eq(CP.Calls.isOnCall(17), false, 'callCleared removes the call')
    H.eq(CP.Calls.isOnCall(18), false, 'callCleared with the raw id removes the canonical entry')

    -- sc-dispatch restart wipes everything
    respond(19, '456', true)
    H.eq(CP.Calls.isOnCall(19), true, 'on call')
    emit('restart')
    H.eq(CP.Calls.isOnCall(19), false, 'sc-dispatch restart wipes the map')

    -- playerDropped
    respond(16, '456', true)
    H.eq(CP.Calls.isOnCall(16), true, 'on call')
    H.fire('playerDropped', 16, 'quit')
    H.eq(CP.Calls.isOnCall(16), false, 'playerDropped wipes the player')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- ALERTS
-- ═══════════════════════════════════════════════════════════════════════════
H.time = T + 5000

do
    local r = newRun('r-al-1', { srcs = { 23, 24, 25, 26, 27, 28, 29 }, arrived = true, state = 'in_progress', start = vec3(0.0, 0.0, 0.0) })
    for _, s in ipairs({ 23, 24, 25, 26, 27, 28, 29 }) do playerRec(s).coords = vec3(100.0, 0.0, 0.0) end

    -- set / clear ownership
    H.ok(CP.Alerts.set(23, r), 'set')
    H.ok(OURS(bag(23)), 'our value written')
    H.ok(CP.Alerts.has(23), 'has')
    H.eq(CP.Alerts.foreignFlag(23), false, 'ours is not foreign')
    H.eq(CP.Alerts.inArena(23), false, 'not in the arena')
    H.ok(CP.Alerts.clear(23), 'clear')
    H.eq(bag(23), nil, 'value removed')
    H.eq(CP.Alerts.has(23), false, 'intent removed')

    -- foreign values: never overwritten, never cleared
    playerRec(24).state.crimsonArena = { active = true, matchId = 'm24' }
    H.eq(CP.Alerts.foreignFlag(24), true, 'foreign flag')
    H.eq(CP.Alerts.inArena(24), true, 'foreign flag = in arena')
    H.eq(CP.Alerts.set(24, r), false, 'set refuses while foreign')
    H.eq((bag(24) or {}).matchId, 'm24', 'foreign value not overwritten')
    H.eq(CP.Alerts.has(24), false, 'nothing recorded')
    H.eq(CP.Alerts.clear(24), false, 'clear leaves a foreign value')
    H.eq((bag(24) or {}).matchId, 'm24', 'foreign value not cleared')
    runFor(1000)
    H.eq(removedFor(24)[1] and removedFor(24)[1].reason, 'quit', 'an active participant with a foreign value leaves as quit')
    H.eq((bag(24) or {}).matchId, 'm24', 'still not touched')

    -- re-assert after a wipe (debounced 250 ms)
    CP.Alerts.set(25, r)
    bagSet(25, 'crimsonArena', nil)            -- Crimson-Arena wipes the key unconditionally
    H.eq(bag(25), nil, 'wiped')
    H.step(0)
    H.ok(OURS(bag(25)), 're-asserted on the next tick')
    bagSet(25, 'crimsonArena', nil)
    H.step(0)
    H.eq(bag(25), nil, 'second wipe within 250 ms waits')
    H.step(100)
    H.eq(bag(25), nil, '...still waiting at 100 ms')
    H.step(200)
    H.ok(OURS(bag(25)), 're-asserted after 250 ms')
    H.ok(CP.Alerts.has(25), 'intent kept across wipes')

    -- a foreign value replaces ours: never re-written; the participant leaves; foreignClearedAt on nil
    CP.Alerts.set(26, r)
    bagSet(26, 'crimsonArena', { active = true, matchId = 'm26' })
    H.step(0)
    H.eq(removedFor(26)[1] and removedFor(26)[1].reason, 'quit', 'foreign flag mid-run -> quit')
    H.eq(notesFor(26, 'run.left_for_arena'), 1, 'toast run.left_for_arena')
    H.eq(CP.Alerts.has(26), false, 'intent dropped')
    H.eq((bag(26) or {}).matchId, 'm26', 'foreign value left alone')
    runFor(1500)
    H.eq((bag(26) or {}).matchId, 'm26', 'never re-asserted over a foreign value')
    H.eq(CP.Alerts.foreignClearedAt[26], nil, 'not cleared yet')
    bagSet(26, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[26], H.time, 'foreignClearedAt recorded')
    runFor(1500)
    H.eq(bag(26), nil, 'no re-assert once the intent is gone')

    -- routing bucket
    buckets[27] = 4210
    H.eq(CP.Alerts.inArena(27), true, 'bucket ~= 0 = in arena')
    H.eq(CP.Alerts.foreignFlag(27), false, 'no foreign flag though')
    H.eq(CP.Alerts.set(27, r), false, 'set refuses in another bucket')
    runFor(1000)
    H.eq(removedFor(27)[1] and removedFor(27)[1].reason, 'quit', 'bucket change mid-run -> quit')
    buckets[27] = nil

    -- backstop: shots fired near the mission, t-1, t, t+1, { 'police' }
    CP.Alerts.set(28, r)
    local t = H.time
    clears = {}
    emit('shots', 28, { coords = vec3(100.0, 0.0, 0.0) }, t)
    H.eq(#clears, 0, 'waits backstopDelay first')
    runFor(1000)
    H.eq(#clears, 3, 'three ids cleared')
    H.eq(clears[1] and clears[1].id, ('shots_28_%d'):format(t - 1), 'previous second')
    H.eq(clears[2] and clears[2].id, ('shots_28_%d'):format(t), 'current second')
    H.eq(clears[3] and clears[3].id, ('shots_28_%d'):format(t + 1), 'next second')
    H.eq(clears[1] and clears[1].jobs[1], 'police', "jobs { 'police' }")
    H.eq(clears[1] and #clears[1].jobs, 1, 'only police for shots')

    -- out of radius (server-side coords), then near the objective anchor
    clears = {}
    playerRec(29).coords = vec3(400.0, 0.0, 0.0)
    emit('shots', 29, { coords = vec3(0.0, 0.0, 0.0) }, t)
    runFor(1500)
    H.eq(#clears, 0, 'outside backstopRadius (client coords are ignored)')
    r.anchor = vec3(450.0, 0.0, 0.0)
    emit('shots', 29, {}, t + 5)
    runFor(1500)
    H.eq(#clears, 3, 'near the current objective anchor')
    r.anchor = nil

    -- foreign srcs are skipped
    clears = {}
    emit('shots', 24, {}, t)
    emit('down', 24, {}, t)
    runFor(1500)
    H.eq(#clears, 0, 'foreign srcs are left to Crimson-Arena')

    -- person down / dead from a flagged src: { 'police', 'ambulance' }; never emsdown_
    clears = {}
    emit('down', 28, {}, t)
    emit('dead', 28, {}, t)
    runFor(1500)
    H.eq(#clears, 6, 'down and dead: three ids each')
    H.eq(clears[1] and clears[1].id, ('playerdown_28_%d'):format(t - 1), 'playerdown t-1')
    H.eq(clears[6] and clears[6].id, ('playerdead_28_%d'):format(t + 1), 'playerdead t+1')
    H.eq(clears[1] and table.concat(clears[1].jobs, ','), 'police,ambulance', "jobs { 'police', 'ambulance' }")
    clears = {}
    emit('down', 23, {}, t)                    -- 23 has no intent any more
    runFor(1500)
    H.eq(#clears, 0, 'person down without our flag: nothing cleared')

    -- an intent that outlived its run is removed
    local r2 = newRun('r-al-2', { srcs = { 30 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(30, r2)
    r2.state = 'ended'                         -- the engine forgot to clear it
    runFor(5000)
    H.eq(bag(30), nil, 'orphaned flag removed')
    H.eq(CP.Alerts.has(30), false, 'orphaned intent removed')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- DOWNED
-- ═══════════════════════════════════════════════════════════════════════════
local function firstRemoval(src, reason)
    for _, e in ipairs(rlog.removed) do if e.src == src and e.reason == reason then return e end end
    return nil
end

local function untilRemoved(src, reason, maxMs)
    local limit = H.clockMs + (maxMs or 5000)
    while not firstRemoval(src, reason) and H.clockMs < limit do H.step(100) end
    return firstRemoval(src, reason)
end

-- 1) no EMS: pick-up after 15 s, then revive, then the flag goes when the client is done
do
    ems.doctors = 0
    playerRec(41).coords = vec3(-240.0, 6300.0, 32.0)
    local r = newRun('r-dn-1', { srcs = { 41 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(41, r)
    downed[41] = true
    local e = untilRemoved(41, 'downed')
    H.ok(e ~= nil, 'downed participant removed')
    H.eq(e and e.keepFlag, true, 'removed with keepFlag')
    H.eq(r.stats.downs, 1, 'run.stats.downs + 1 (counted once although the engine counts downs too)')
    H.ok(OURS(bag(41)) and CP.Alerts.has(41), 'flag kept while down (even though the engine tried to clear it)')
    H.eq(notesFor(41, 'downed.pickup_soon'), 1, 'toast: pick-up soon')
    local detected = e.at
    runFor(14900 - (H.clockMs - detected))
    H.eq(#clientEvents('client:pickup', 41), 0, 'no pick-up before 15 s')
    runFor(100)
    local pk = clientEvents('client:pickup', 41)
    H.eq(#pk, 1, 'pick-up at 15 s')
    H.eq(pk[1] and pk[1].args[1], 'r-dn-1', 'pick-up carries the run id')
    H.near(pk[1] and pk[1].args[2].x, -254.54, 1e-6, 'nearest drop-off (Paleto)')
    H.eq(countRevives(41), 0, 'revive follows the fade')
    runFor(1500)
    H.eq(countRevives(41), 1, 'revived')
    H.ok(OURS(bag(41)), 'flag still on until the client is done')
    H.fire(CP.e('server:pickupDone'), 41, 'r-dn-1', true)
    H.eq(bag(41), nil, 'flag cleared after the pick-up')
    H.eq(CP.Alerts.has(41), false, 'intent cleared')
    runFor(10000)                              -- metadata still says "down" for a while
    H.eq(#clientEvents('client:pickup', 41), 1, 'never picked up twice')
    H.eq(countRevives(41), 1, 'never revived twice')
    H.eq(r.state, 'ended', 'every participant downed: the run ended')
    downed[41] = nil
end

-- 2) EMS on duty: flag cleared first, then one EMS request
do
    ems.doctors = 2
    local r = newRun('r-dn-2', { srcs = { 42, 50 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(42, r)
    CP.Alerts.set(50, r)
    downed[42] = true
    H.ok(untilRemoved(42, 'downed') ~= nil, 'downed with EMS on duty')
    H.eq(bag(42), nil, 'flag removed before the EMS request')
    local req = clientEvents('client:requestEMS', 42)
    H.eq(#req, 1, 'EMS request sent')
    H.eq(req[1] and req[1].args[1], 'r-dn-2', 'EMS request carries the run id')
    runFor(8000)
    H.eq(#clientEvents('client:requestEMS', 42), 1, 'EMS request sent once')
    H.eq(#clientEvents('client:pickup', 42), 0, 'no pick-up with EMS on duty')
    H.eq(r.participants[50].status, 'active', 'the partner carries on')
    H.ok(OURS(bag(50)), "the partner's flag stays")
    downed[42] = nil
end

-- 2b) an engine that does not count downs itself: CP.Downed adds the one down
do
    ems.doctors = 1
    runsCfg.countDowns = false
    local r = newRun('r-dn-2b', { srcs = { 52, 53 }, arrived = true, state = 'in_progress' })
    downed[52] = true
    H.ok(untilRemoved(52, 'downed') ~= nil, 'downed')
    runFor(100)
    H.eq(r.stats.downs, 1, 'run.stats.downs + 1 by CP.Downed')
    runsCfg.countDowns = true
    downed[52] = nil
end

-- 3) EMS on duty after an arena exit: the request waits until 11 s after foreignClearedAt
do
    ems.doctors = 1
    bagSet(43, 'crimsonArena', { active = true, matchId = 'm43' })
    H.step(0)
    bagSet(43, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[43], H.time, 'arena exit recorded')
    local T43 = H.time
    H.time = T43 + 3
    local r = newRun('r-dn-3', { srcs = { 43 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(43, r)
    downed[43] = true
    local e = untilRemoved(43, 'downed')
    H.ok(e ~= nil, 'downed')
    H.eq(bag(43), nil, 'flag removed at once')
    runFor(7900 - (H.clockMs - e.at))
    H.eq(#clientEvents('client:requestEMS', 43), 0, 'EMS request held back after an arena exit')
    runFor(100)
    H.eq(#clientEvents('client:requestEMS', 43), 1, 'EMS request 11 s after the arena exit')
    downed[43] = nil
end

-- 4) in-arena srcs are not treated as downed
do
    ems.doctors = 0
    local r = newRun('r-dn-4', { srcs = { 44 }, arrived = true, state = 'in_progress' })
    buckets[44] = 4300
    downed[44] = true
    runFor(4000)
    H.eq(firstRemoval(44, 'downed'), nil, 'in-arena src skipped by the downed poll')
    H.eq(#clientEvents('client:pickup', 44), 0, 'no pick-up in the arena')
    buckets[44] = nil
    downed[44] = nil
    r.state = 'ended'
end

-- 5) a disconnect cancels the pick-up
do
    ems.doctors = 0
    newRun('r-dn-5', { srcs = { 45 }, arrived = true, state = 'in_progress' })
    downed[45] = true
    H.ok(untilRemoved(45, 'downed') ~= nil, 'downed')
    runFor(5000)
    dropped[45] = true
    H.fire('playerDropped', 45, 'quit')
    runFor(15000)
    H.eq(#clientEvents('client:pickup', 45), 0, 'dropped: no pick-up')
    H.eq(countRevives(45), 0, 'dropped: no revive')
    downed[45] = nil
end

-- 6) a character unload cancels the pick-up
do
    ems.doctors = 0
    local r = newRun('r-dn-6', { srcs = { 46 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(46, r)
    downed[46] = true
    H.ok(untilRemoved(46, 'downed') ~= nil, 'downed')
    for _, fn in ipairs(unloadListeners) do CreateThread(function() fn(46) end) end
    H.eq(bag(46), nil, 'unload: flag removed')
    runFor(16000)
    H.eq(#clientEvents('client:pickup', 46), 0, 'unload: no pick-up')
    downed[46] = nil
end

-- 7) revived by someone else before the pick-up: cancelled, flag removed
do
    ems.doctors = 0
    local r = newRun('r-dn-7', { srcs = { 47 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(47, r)
    downed[47] = true
    H.ok(untilRemoved(47, 'downed') ~= nil, 'downed')
    H.ok(OURS(bag(47)), 'flag kept while down')
    runFor(8000)
    downed[47] = nil
    runFor(8000)
    H.eq(#clientEvents('client:pickup', 47), 0, 'recovered: no pick-up')
    H.eq(bag(47), nil, 'recovered: flag removed')
end

-- 8) went down before the start (no flag) with EMS on duty: sc-ambulance already alerted EMS
do
    ems.doctors = 1
    newRun('r-dn-8', { srcs = { 48 }, arrived = false, state = 'accepted' })
    downed[48] = true
    H.ok(untilRemoved(48, 'downed') ~= nil, 'downed before the start')
    runFor(3000)
    H.eq(#clientEvents('client:requestEMS', 48), 0, 'no second EMS request without our flag')
    downed[48] = nil
end

-- 9) the last participant went down and the engine left the run open: it ends as failed
do
    ems.doctors = 1
    runsCfg.autoEnd = false
    local r = newRun('r-dn-9', { srcs = { 49 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(49, r)
    downed[49] = true
    H.ok(untilRemoved(49, 'downed') ~= nil, 'downed')
    runFor(6000)
    local ended
    for _, e in ipairs(rlog.endRun) do if e.run == 'r-dn-9' then ended = e end end
    H.eq(ended and ended.state, 'failed', 'run with every participant downed ends as failed')
    runsCfg.autoEnd = true
    downed[49] = nil
end

-- 10) the client gave up before the revive: no revive, flag removed
do
    ems.doctors = 0
    local r = newRun('r-dn-10', { srcs = { 51 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(51, r)
    downed[51] = true
    local e = untilRemoved(51, 'downed')
    runFor(15000 - (H.clockMs - e.at))
    H.eq(#clientEvents('client:pickup', 51), 1, 'pick-up sent')
    H.fire(CP.e('server:pickupDone'), 51, 'wrong-run', false)
    H.ok(OURS(bag(51)), 'pickupDone for another run is ignored')
    H.fire(CP.e('server:pickupDone'), 51, 'r-dn-10', false)
    runFor(2000)
    H.eq(countRevives(51), 0, 'no revive after the client gave up')
    H.eq(bag(51), nil, 'flag removed')
    H.eq(#clientEvents('client:pickupCancel', 51), 0, 'the client that gave up is not told to cancel')
    downed[51] = nil
end

-- ── review (integrations lens): regressions for the fixes ───────────────────
-- 1) backstop: shots events in consecutive seconds. The first event's clear of the t + 1 id ran before that
--    second's call could exist, so the next event must clear it again; ids cleared at s + 2 or later stay deduped.
do
    local r = newRun('r-rv-1', { srcs = { 81 }, arrived = true, state = 'in_progress', start = vec3(0.0, 0.0, 0.0) })
    playerRec(81).coords = vec3(10.0, 0.0, 0.0)
    CP.Alerts.set(81, r)
    local t = H.time
    local function idsOf(list)
        local out = {}
        for _, c in ipairs(list) do out[#out + 1] = c.id end
        return table.concat(out, ',')
    end
    clears = {}
    emit('shots', 81, {}, t)
    H.time = t + 1                               -- the clear runs after backstopDelay
    runFor(1100)
    H.eq(#clears, 3, 'first event: t-1, t, t+1')
    clears = {}
    emit('shots', 81, {}, t + 1)                 -- a second call, created during second t + 1
    H.time = t + 2
    runFor(1100)
    H.eq(idsOf(clears), ('shots_81_%d,shots_81_%d,shots_81_%d'):format(t, t + 1, t + 2),
        'next-second event clears shots_<src>_<t+1> again (the first clear came too early for it)')
    clears = {}
    emit('shots', 81, {}, t + 1)                 -- another event in second t + 1
    H.time = t + 3
    runFor(1100)
    H.eq(idsOf(clears), ('shots_81_%d,shots_81_%d'):format(t + 1, t + 2), 'an id cleared at s + 2 or later is not cleared again')
    H.time = t
    CP.Alerts.clear(81)
    r.state = 'ended'
end

-- 2) foreignClearedAt is recorded even when this module never saw the foreign value (e.g. after a restart)
do
    playerRec(82).state.crimsonArena = { active = true, matchId = 'm82' }   -- written before we were watching
    bagSet(82, 'crimsonArena', nil)
    H.step(0)
    H.eq(CP.Alerts.foreignClearedAt[82], H.time, 'arena exit recorded from the value before the change')
end

-- 3) a pick-up the server cancels after client:pickup went out tells the client to stop
do
    ems.doctors = 0
    local r = newRun('r-rv-3', { srcs = { 83 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(83, r)
    downed[83] = true
    local e = untilRemoved(83, 'downed')
    runFor(15000 - (H.clockMs - e.at))
    H.eq(#clientEvents('client:pickup', 83), 1, 'pick-up sent')
    downed[83] = nil                             -- revived by someone else during the fade-out
    runFor(2000)
    H.eq(countRevives(83), 0, 'no revive after the re-check failed')
    local pc = clientEvents('client:pickupCancel', 83)
    H.eq(#pc, 1, 'client told to cancel the pick-up')
    H.eq(pc[1] and pc[1].args[1], 'r-rv-3', 'cancel carries the run id')
    H.eq(bag(83), nil, 'flag removed')

    local r2 = newRun('r-rv-3b', { srcs = { 84 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(84, r2)
    downed[84] = true
    e = untilRemoved(84, 'downed')
    runFor(15000 - (H.clockMs - e.at) + 1600)   -- pick-up sent and revive done: waiting for pickupDone
    H.eq(countRevives(84), 1, 'revived')
    for _, fn in ipairs(unloadListeners) do CreateThread(function() fn(84) end) end
    H.step(0)
    H.eq(#clientEvents('client:pickupCancel', 84), 1, 'unload during the pick-up cancels it on the client')
    H.eq(bag(84), nil, 'unload: flag removed')
    downed[84] = nil
end

-- ── review (spec lens): regressions for the fixes ───────────────────────────
-- 1) dodge rule: an un-mark that arrives while the mark is still being looked up in mdt_dispatch
do
    activeCalls['5101'] = '5101'
    local realLookup = CP.Dispatch.lookupActiveCall
    CP.Dispatch.lookupActiveCall = function(id) Wait(100); return realLookup(id) end
    newRun('r-sl-1', { srcs = { 71, 72 }, arrived = true, state = 'in_progress' })
    local nRe = #rlog.reclassify
    respond(71, 5101, true)
    respond(71, '5101', false)                   -- the toggle-off arrives during the lookup
    H.eq(#removedFor(71), 0, 'the lookup is still running')
    runFor(300)
    H.eq(removedFor(71)[1] and removedFor(71)[1].reason, 'real_call', 'the real call still ends the run')
    H.eq(#rlog.reclassify, nRe + 1, 'an un-mark during the lookup still turns it into a normal abandon')
    H.eq(rlog.reclassify[#rlog.reclassify] and rlog.reclassify[#rlog.reclassify].run, 'r-sl-1', '...for that run')
    H.eq(rlog.reclassify[#rlog.reclassify] and rlog.reclassify[#rlog.reclassify].reason, 'real_call_cancelled', '...as real_call_cancelled')
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
    newRun('r-sl-2', { srcs = { 73, 74 }, arrived = true, state = 'in_progress' })
    local nRe = #rlog.reclassify
    respond(73, 5102, true)
    H.eq(removedFor(73)[1] and removedFor(73)[1].reason, 'real_call', 'removal started')
    respond(73, '5102', false)                   -- the toggle-off arrives before the row exists
    H.eq(#rlog.reclassify, nRe, 'reclassify waits for the row')
    runFor(400)
    H.eq(#rlog.reclassify, nRe + 1, 'reclassified once the row is written')
    H.eq(reclassifiedWhileWriting, false, 'reclassify never runs before the row exists')
    respond(73, '5102', false)
    runFor(100)
    H.eq(#rlog.reclassify, nRe + 1, 'reclassified once')
    CP.Runs.removeParticipant, CP.Runs.reclassify = realRemove, realReclassify
end

-- 3) the tablet gets the route view when the warning appears / goes and after a recalculation
do
    local pushes = {}
    CP.Tablet.push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end
    CP.Runs.view = function(r, src) return { runId = r.id, route = CP.Route.status(r, src) } end
    playerRec(75).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-sl-3', { srcs = { 75 } })
    alignTo(2000)
    CP.Route.begin(r, 75)
    runFor(4000, reporter(75, 'r-sl-3', 10.0))
    H.eq(#pushes, 0, 'nothing pushed while on route')
    runFor(12000, reporter(75, 'r-sl-3', 300.0))
    H.eq(#pushes, 1, 'view pushed when the warning appears')
    H.eq(pushes[1] and pushes[1].topic, 'run', "push topic 'run'")
    H.eq(pushes[1] and pushes[1].src, 75, 'to that participant')
    H.eq(pushes[1] and pushes[1].data.route.status, 'off', 'the tablet shows off route')
    H.eq(pushes[1] and pushes[1].data.route.secondsLeft, 20, '...with the seconds left')
    runFor(4000, reporter(75, 'r-sl-3', 300.0))
    H.eq(#pushes, 1, 'pushed once per warning, not every second')
    runFor(2000, reporter(75, 'r-sl-3', 10.0))
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
    playerRec(76).coords = vec3(0.0, 0.0, 0.0)
    local r = newRun('r-sl-4', { srcs = { 76 } })
    alignTo(1000)
    CP.Route.begin(r, 76)
    runFor(24000, function(c)
        if c % 2000 == 0 then report(76, 'r-sl-4', 5.0, vec3(100.0, 0.0, 0.0)) end   -- 100 m ahead of the server
    end)
    H.eq(#clientEvents('client:routeWarning', 76), 0, 'reports within 150 m of the server position count')
    H.eq(CP.Route.status(r, 76).status, 'on', 'still on route')
    Config.Route.maxDeviation = old
    CP.Route.stop(r, 76)
    r.state = 'ended'
end

-- ── resource stop: every value we set goes, foreign values stay ─────────────
do
    local r = newRun('r-stop', { srcs = { 32 }, arrived = true, state = 'in_progress' })
    CP.Alerts.set(32, r)
    H.ok(OURS(bag(32)), 'flag on')
    H.fire('onResourceStop', 0, 'Crimson-Police')
    H.eq(bag(32), nil, 'resource stop removes our flags')
    H.eq(bag(22) and bag(22).matchId, 'm0', 'resource stop leaves foreign values')
    r.state = 'ended'
end

-- ═══════════════════════════════════════════════════════════════════════════
-- CLIENT FILES (own environment, stubbed natives)
-- ═══════════════════════════════════════════════════════════════════════════
do
    for _, r in pairs(runs) do r.state = 'ended' end
    local serverEvents = {}
    local cstate = {
        pos = vec3(0.0, 0.0, 0.0), waypoint = nil, blips = {}, nextBlip = 1, routeFound = true,
        routeLen = 1000.0, dead = true, faded = 'in', md = { isdead = true }, coordsSet = nil,
        huds = {}, overlays = {}, toasts = {}, arena = nil, emsSent = 0,
    }
    local clientCP = {
        U = CP.U, L = CP.L, Locale = CP.Locale, e = CP.e, log = CP.log, warn = function() end, err = CP.err,
        resource = 'Crimson-Police', prefix = 'crimson-police', isServer = false,
        Tablet = {
            hud = function(p) cstate.huds[#cstate.huds + 1] = p end,
            overlay = function(o) cstate.overlays[#cstate.overlays + 1] = o or false end,
            notify = function(kind, text) cstate.toasts[#cstate.toasts + 1] = { kind = kind, text = text } end,
            registerClientAction = function(name, fn) cstate['action_' .. name] = fn end,
        },
        Qbx = { getPlayerData = function() return { metadata = cstate.md } end },
        Ambulance = { sendEMSRequest = function() cstate.emsSent = cstate.emsSent + 1; return true end },
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
        AddBlipForCoord = function() local b = cstate.nextBlip; cstate.nextBlip = b + 1; cstate.blips[b] = true; return b end,
        DoesBlipExist = function(b) return cstate.blips[b] == true or b == 900 end,
        RemoveBlip = function(b) cstate.blips[b] = nil end,
        SetBlipSprite = function() end, SetBlipColour = function() end, SetBlipScale = function() end,
        SetBlipRouteColour = function() end, SetBlipRoute = function() end,
        BeginTextCommandSetBlipName = function() end, AddTextComponentSubstringPlayerName = function() end,
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
        LocalPlayer = { state = setmetatable({}, { __index = function(_, k) if k == 'crimsonArena' then return cstate.arena end end }) },
    }, { __index = _G })
    local function loadClient(rel)
        local chunk = assert(loadfile(H.root .. rel, 't', env))
        chunk()
    end
    loadClient('modules/route/client.lua')
    loadClient('modules/downed/client.lua')
    H.step(0)
    local CR, CD = clientCP.Route, clientCP.Downed
    H.ok(type(CR.begin) == 'function' and type(CD.busy) == 'function', 'client modules loaded')
    H.ok(cstate.action_setGps and cstate.action_recalcRoute, 'client actions registered')
    local function sent(name)
        local out = {}
        for _, e in ipairs(serverEvents) do if e.name == CP.e(name) then out[#out + 1] = e end end
        return out
    end
    local function lastHudRoute()
        for i = #cstate.huds, 1, -1 do if cstate.huds[i].route then return cstate.huds[i].route end end
        return nil
    end

    -- begin: waypoint + sampled polyline + reports of the distance to that line
    H.ok(CR.begin('c-run-1', vec3(500.0, 500.0, 0.0)), 'client begin')
    H.eq(cstate.waypoint and cstate.waypoint.x, 500.0, 'waypoint set to the start')
    runFor(2100)
    local rep = sent('server:routeStatus')
    H.ok(#rep >= 1, 'reports sent')
    H.eq(rep[1] and rep[1].args[1], 'c-run-1', 'report carries the run id')
    H.near(rep[1] and rep[1].args[2], 0.0, 1e-6, 'on the polyline: 0 m')
    H.eq(lastHudRoute() and lastHudRoute().status, 'on', 'HUD route on')
    H.eq(lastHudRoute() and lastHudRoute().distance, 1000, 'HUD distance along the fixed line')
    local nBlips = 0
    for _ in pairs(cstate.blips) do nBlips = nBlips + 1 end
    H.eq(nBlips, 0, 'the temporary route blip is removed after sampling')

    -- off the line: the distance to the FIXED polyline is reported (the GPS may recalculate, the line does not)
    cstate.pos = vec3(-150.0, 250.0, 0.0)
    cstate.routeFound = false
    runFor(2000)
    rep = sent('server:routeStatus')
    H.near(rep[#rep].args[2], 150.0, 1e-6, 'distance to the fixed polyline')
    H.eq(lastHudRoute().status, 'off', 'HUD off beyond maxDeviation')

    -- server warning -> HUD seconds + one toast; withdrawn -> on
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', 20)
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', 19)
    H.eq(lastHudRoute().secondsLeft, 19, 'HUD shows the seconds left')
    local warnToasts = 0
    for _, t in ipairs(cstate.toasts) do if t.kind == 'warning' and t.text:find('within 20 s', 1, true) then warnToasts = warnToasts + 1 end end
    H.eq(warnToasts, 1, 'one toast when the warning first appears')
    TriggerEvent(CP.e('client:routeWarning'), 'c-run-1', nil)
    H.eq(lastHudRoute().secondsLeft, nil, 'warning withdrawn')

    -- recalculate: the server grants it, the line is resampled from here (straight line when no GPS route)
    local result
    CreateThread(function() result = { cstate.action_recalcRoute({}) } end)
    H.eq(#sent('server:recalcRoute'), 1, 'recalc asks the server')
    TriggerEvent(CP.e('client:routeRecalc'), 'c-run-1', true, 1)
    runFor(6000)
    H.eq(result and result[1], true, 'recalc ok')
    H.eq(result and result[2] and result[2].recalcsLeft, 1, 'recalcs left passed on')
    rep = sent('server:routeStatus')
    H.near(rep[#rep].args[2], 0.0, 1e-6, 'new straight line starts where the player is')
    CreateThread(function() result = { cstate.action_recalcRoute({}) } end)
    TriggerEvent(CP.e('client:routeRecalc'), 'c-run-1', false, 0)
    runFor(100)
    H.eq(result[1], false, 'refused recalc')
    H.eq(result[2], 'err.route_no_recalcs', 'refusal key')

    -- arrival from the server: reports stop, waypoint removed
    TriggerEvent(CP.e('client:routeStatus'), 'c-run-1', { status = 'arrived' })
    H.eq(lastHudRoute().status, 'arrived', 'HUD arrived')
    H.eq(cstate.waypoint, nil, 'our waypoint removed on arrival')
    local nRep = #sent('server:routeStatus')
    runFor(5000)
    H.eq(#sent('server:routeStatus'), nRep, 'no reports after arrival')
    TriggerEvent(CP.e('client:runEnded'), 'c-run-1')
    H.eq(CR.current(), nil, 'stopped at the run end')
    H.eq(CR.begin('c-run-1', vec3(1.0, 1.0, 0.0)), false, 'an ended run cannot begin again')

    -- pick-up: fade, overlay, wait for the revive, move, fade in, pickupDone
    cstate.dead, cstate.md = true, { isdead = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-2', vec3(308.19, -595.35, 43.29))
    runFor(1000)
    H.eq(cstate.faded, 'out', 'faded out')
    H.eq(cstate.overlays[#cstate.overlays] and cstate.overlays[#cstate.overlays].text, 'Picked up by an NPC unit', 'fade overlay text')
    H.eq(cstate.coordsSet, nil, 'not moved before the revive')
    cstate.dead, cstate.md = false, { isdead = false, inlaststand = false }
    runFor(1000)
    H.near(cstate.coordsSet and cstate.coordsSet.x, 308.19, 1e-6, 'moved to the drop-off')
    H.eq(cstate.faded, 'in', 'faded back in')
    H.eq(cstate.overlays[#cstate.overlays], false, 'overlay cleared')
    local done = sent('server:pickupDone')
    H.eq(done[1] and done[1].args[1], 'c-run-2', 'pickupDone sent')
    H.eq(done[1] and done[1].args[2], true, 'pickupDone ok')

    -- pick-up aborted by a foreign arena value: fades back in, no move
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-3', vec3(308.19, -595.35, 43.29))
    runFor(500)
    cstate.arena = { active = true, matchId = 'mx' }
    runFor(1000)
    H.eq(cstate.coordsSet, nil, 'no teleport into or out of the arena')
    H.eq(cstate.faded, 'in', 'abort fades back in')
    done = sent('server:pickupDone')
    H.eq(done[#done].args[2], false, 'abort reported')
    cstate.arena = nil

    -- pick-up cancelled by the server (client:pickupCancel): fades back in, never teleports, even if a
    -- revive arrives afterwards
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-5', vec3(308.19, -595.35, 43.29))
    runFor(1000)
    TriggerEvent(CP.e('client:pickupCancel'), 'other-run')
    runFor(300)
    H.ok(CD.busy(), 'a cancel for another run is ignored')
    TriggerEvent(CP.e('client:pickupCancel'), 'c-run-5')
    cstate.dead, cstate.md = false, { isdead = false, inlaststand = false }
    runFor(1000)
    H.eq(cstate.coordsSet, nil, 'cancelled pick-up: no teleport')
    H.eq(cstate.faded, 'in', 'cancelled pick-up fades back in')
    H.eq(cstate.overlays[#cstate.overlays], false, 'cancelled pick-up clears the overlay')
    H.eq(CD.busy(), false, 'pick-up no longer running')

    -- logout / character switch during the pick-up: no metadata is not "revived" (no teleport), it aborts
    cstate.coordsSet = nil
    cstate.dead, cstate.md = true, { inlaststand = true }
    TriggerEvent(CP.e('client:pickup'), 'c-run-6', vec3(308.19, -595.35, 43.29))
    runFor(1000)
    cstate.dead, cstate.md = false, nil          -- CP.Qbx.getPlayerData() has no character any more
    runFor(1000)
    H.eq(cstate.coordsSet, nil, 'no character loaded: no teleport')
    H.eq(cstate.faded, 'in', 'no character loaded: faded back in')
    done = sent('server:pickupDone')
    H.eq(done[#done].args[1], 'c-run-6', 'abort reported for that run')
    H.eq(done[#done].args[2], false, 'abort reported as not done')
    cstate.md = {}

    -- EMS request from the own client
    TriggerEvent(CP.e('client:requestEMS'), 'c-run-4')
    H.eq(cstate.emsSent, 1, 'EMS request sent from the client')
end

return H
