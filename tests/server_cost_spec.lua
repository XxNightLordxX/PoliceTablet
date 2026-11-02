-- Server cost (step OP2, docs/LOOPS.md "Server cost and NUI"): the REAL server side of Crimson-Police with its officers

local World
do
    local f = assert(io.open('tests/e2e_spec.lua', 'r'))
    local text = f:read('a')
    f:close()
    local cut = text:find('\n%-%- =+\n%-%-%s+HELPERS\n')
    assert(cut, 'tests/e2e_spec.lua has its HELPERS section')
    text = text:sub(1, cut) .. '\nreturn { H = H, Adv = Adv, print = realPrint }\n'
    text = text:gsub('%.%. \'_e2e\'', '.. \'_cost\'', 1)
    World = assert(load(text, '@tests/e2e_spec.lua (world)'))()
end
local H, Adv = World.H, World.Adv

-- ============================================================================
--                     SQL OF THE IDLE SERVER (two minutes)
-- ============================================================================
-- Every MySQL call, keyed by its text. The first two minutes fill the caches (no-repeat history, cooldowns, boards);
-- the next two are what an idle server keeps sending.

local sql = {}
for _, k in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
    -- the global MySQL: oxmysql (database mode) or the saves folder engine (files mode)
    local real = MySQL[k].await
    MySQL[k].await = function(q, params)
        local key = q:gsub('%s+', ' ')
        sql[key] = (sql[key] or 0) + 1
        return real(q, params)
    end
end
local function Count(needle)
    local n = 0
    for q, c in pairs(sql) do
        if q:find(needle, 1, true) then n = n + c end
    end
    return n
end
local function Total()
    local n = 0
    for _, c in pairs(sql) do n = n + c end
    return n
end

Adv(125000, 500)
sql = {}
-- every Wait of the resource's own files during the idle two minutes (step LP4)
local wakes = {}
local realWait = _G.Wait
_G.Wait = function(ms)
    local info = debug.getinfo(2, 'S')
    local file = info.source:match('Crimson%-Police/(.*)$')
    if file then wakes[file] = (wakes[file] or 0) + 1 end
    return realWait(ms)
end
_G.Citizen.Wait = _G.Wait
Adv(120000, 500)
_G.Wait = realWait
_G.Citizen.Wait = realWait

-- ============================================================================
--            TICKS THAT SLEEP WITH NO RUN (step LP4, docs/LOOPS.md)
-- ============================================================================
-- the run engine (with the job recheck), custody, the NPC watcher, the drive-to-start and downed checks, the Testing
-- upkeep and the unit sweep woke every 1-5 s all day; now each runs only while what it watches exists (a run, a test,
-- a unit), armed again by the next one. The mission calls push flag is a SetTimeout armed by a change, not a 1 s loop.
for _, m in ipairs({
    { 'Runs', 'modules/runs/server.lua', '_engineTicking', 2 },
    { 'Custody', 'modules/custody/server.lua' },
    { 'Npc', 'modules/npc/server.lua' },
    { 'Route', 'modules/route/server.lua' },
    { 'Downed', 'modules/downed/server.lua' },
    { 'Testing', 'modules/testing/server.lua' },
    { 'Units', 'modules/units/server.lua' },
}) do
    local mod, field = CP[m[1]], m[3] or '_ticking'
    local ticking = type(mod[field]) == 'function' and mod[field]()
    H.eq(ticking, false, ('idle server: the %s tick is not running (%s)'):format(m[1], tostring(ticking)))
    -- the run engine's file keeps its 60 s cache housekeeping (two passes in two minutes)
    local n, most = wakes[m[2]] or 0, m[4] or 0
    H.ok(n <= most, ('idle server, two minutes: %s wakes at most %d times (%d)'):format(m[2], most, n))
end
do
    local n = wakes['modules/missioncalls/server.lua'] or 0
    local every = math.max(1, tonumber(Config.MissionCalls.checkEvery) or 10)
    H.ok(n <= math.ceil(120 / every) + 1,
        ('idle server, two minutes: mission calls wake only for their %d s check (%d; +120 before LP4)'):format(every,
            n))
end
local officers = 0
for _, s in ipairs(GetPlayers()) do
    if CP.Access.getOfficer(tonumber(s)) then officers = officers + 1 end
end
H.ok(officers >= 10, 'officers online and on duty: ' .. officers)

H.eq(Count('SELECT 1 AS retired FROM cp_officers'), 0, 'no retirement query of its own (read with the suspension)')
local state = Count('retired_at IS NOT NULL AS retired FROM cp_officers')
-- the cache keeps an answer 15 s: about 8 reads per officer in 120 s (was 16: suspension and retirement apart)
H.ok(state > 0 and state <= officers * 9,
    ('one officer state read per officer per 15 s: %d for %d officers'):format(state, officers))
H.eq(Count('SELECT options FROM cp_officers'), 0, 'a call toast reads no options row of its own')
H.eq(Count('SELECT calls_muted FROM cp_officers WHERE'), 0, 'calls_muted is read with the options')
H.ok(Total() <= officers * 9 + 2 * officers + 10, ('the idle server sent %d SQL calls in 120 s'):format(Total()))

-- ============================================================================
--                 TABLET PUSHES (Config.Performance.pushGapMs)
-- ============================================================================

local T = CP.Tablet
local PUSH = CP.e('client:push')
local function Pushes(src, topic)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == PUSH and e.target == src and e.args[1] == topic then
            out[#out + 1] = e.args[2]
        end
    end
    return out
end

do
    H.eq(Config.Performance.pushGapMs, 0, 'shipped: every push at once')
    H.events = {}
    for i = 1, 3 do T.push(1, 'board', { n = i }) end
    H.eq(#Pushes(1, 'board'), 3, 'gap 0: three pushes, three events')

    Config.Performance.pushGapMs = 300
    Adv(1000, 100)
    H.events = {}
    T.push(1, 'unit', { invited = true })
    T.push(1, 'unit', { unitId = 4 })
    T.push(1, 'unit', { unitId = 5 })
    T.push(1, 'board', { tod = true })
    T.push(2, 'unit', { unitId = 9 })
    H.eq(#Pushes(1, 'unit'), 1, 'gap 300: the first push goes at once, the next two are held')
    H.eq(#Pushes(1, 'board'), 1, 'another topic is not held')
    H.eq(#Pushes(2, 'unit'), 1, 'another player is not held')
    Adv(400, 100)
    local unit = Pushes(1, 'unit')
    H.eq(#unit, 2, 'the held pushes go as one after the gap')
    H.ok(unit[2] and unit[2].unitId == 5 and unit[2].invited == nil, 'the newest data, merged over the held one')

    H.events = {}
    T.push(1, 'unit', { invited = true })
    T.push(1, 'unit', { unitId = 6 })
    Adv(400, 100)
    unit = Pushes(1, 'unit')
    H.ok(#unit == 1 and unit[1].invited == true and unit[1].unitId == 6, 'a hint of a merged push is kept')

    H.events = {}
    T.push(1, 'run', { id = 'a' })
    T.push(1, 'run', { id = 'a', offRoute = true })
    T.push(1, 'run', { id = 'a' })
    Adv(400, 100)
    local run = Pushes(1, 'run')
    H.ok(#run == 2 and run[2].offRoute == nil, 'a run view is never merged: the newest only')

    -- Z4: every view topic is replaced, not merged; event topics are never held
    H.events = {}
    T.push(1, 'unit', { unitId = 7, readyCheck = { typeLabel = 'x' } })
    T.push(1, 'unit', { unitId = 7, readyCheck = { typeLabel = 'x' } })
    T.push(1, 'unit', { unitId = 7 })
    Adv(400, 100)
    unit = Pushes(1, 'unit')
    H.ok(#unit == 2 and unit[2].readyCheck == nil, 'a finished ready check is not kept by the merge')
    H.events = {}
    T.push(1, 'calls', { list = {}, activeRunId = 'r1' })
    T.push(1, 'calls', { list = {}, activeRunId = 'r1' })
    T.push(1, 'calls', { list = {} })
    Adv(400, 100)
    local calls = Pushes(1, 'calls')
    H.ok(#calls == 2 and calls[2].activeRunId == nil, 'a calls view that dropped activeRunId stays dropped')
    H.events = {}
    T.push(1, 'builder', { event = 'changed', id = 'A' })
    T.push(1, 'builder', { event = 'lockBroken', id = 'A' })
    T.push(1, 'builder', { event = 'changed', id = 'B' })
    local builder = Pushes(1, 'builder')
    H.eq(#builder, 3, 'builder events are never held: each goes at once')
    H.ok(builder[2] and builder[2].event == 'lockBroken' and builder[2].id == 'A', 'the lock break reaches the editor')
    Adv(400, 100)
    H.eq(#Pushes(1, 'builder'), 3, 'and nothing is sent twice')

    H.events = {}
    T.push(1, 'board', { a = 1 })
    T.push(1, 'board', { a = 2 })
    H.fire('playerDropped', 1)
    H.eq(T._pushHeld()[1], nil, 'playerDropped forgets the held pushes')
    Adv(400, 100)
    H.eq(#Pushes(1, 'board'), 1, 'nothing held goes to a player who left')
    Config.Performance.pushGapMs = 0
end

-- ============================================================================
--             LATENT ANSWERS (Config.Performance.latentAboveBytes)
-- ============================================================================

do
    local rows = {}
    for i = 1, 200 do rows[i] = { id = i, label = ('Mission number %d'):format(i) } end
    CP.Net.callback('test:bigList', function() return { rows = rows } end)
    CP.Net.callback('test:smallList', function() return { rows = { 1, 2 } } end)
    local res, sent = H.callbackLatent('crimson-police:test:bigList', 3, {}, 'r1')
    H.ok(res.ok and res.data and #sent == 0, 'shipped 0: a big list answers in one message')
    Config.Performance.latentAboveBytes = 2000
    res, sent = H.callbackLatent('crimson-police:test:bigList', 3, {}, 'r2')
    H.ok(res.ok and res.latent == 'r2' and res.data == nil, 'above the size: the answer says latent')
    H.ok(#sent == 1 and sent[1].target == 3 and sent[1].bps == Config.Limits.exportBps,
        'the data goes as a latent event at Config.Limits.exportBps')
    res, sent = H.callbackLatent('crimson-police:test:smallList', 3, {}, 'r3')
    H.ok(res.ok and res.data and #sent == 0, 'a small answer stays one message')
    res, sent = H.callbackLatent('crimson-police:test:bigList', 3, {}, nil)
    H.ok(res.ok and res.data and #sent == 0, 'no reply id (not the tablet): one message')
    local bps = Config.Limits.exportBps
    Config.Limits.exportBps = 0
    res, sent = H.callbackLatent('crimson-police:test:bigList', 3, {}, 'r4')
    H.ok(res.ok and res.data and #sent == 0, 'exportBps 0: one message')
    Config.Limits.exportBps = bps
    Config.Performance.latentAboveBytes = 0
end

-- ============================================================================
--            ONE ADMIN OR SUPERVISOR REQUEST: ACE CHECKS (step OP3)
-- ============================================================================
-- CP.AdminKit's guards asked CP.Access.isAdmin and then CP.Permissions.can asked it again (each is one or two
-- IsPlayerAceAllowed calls: Config.AdminAce, then the Qbox admin ace while Config.QboxAdmins is on). The guard now
-- hands its answer on. Before -> after: an admin action 2 -> 1 ace check, an admin read 2 -> 1, a supervisor action
-- 6 -> 4 (the officer lookup asks once for its own isAdmin field).

do
    local admin, sup
    for _, s in ipairs(GetPlayers()) do
        local n = tonumber(s)
        if not admin and CP.Access.isAdmin(n) then admin = n end
        if not sup and not CP.Access.isAdmin(n) and CP.Access.isSupervisor(n) then sup = n end
    end
    H.ok(admin ~= nil and sup ~= nil,
        ('an admin (%s) and a supervisor (%s) online'):format(tostring(admin), tostring(sup)))
    local Kit = CP.AdminKit
    local ran = 0
    Kit.action('test:op3Admin', 'viewMissionList', function() ran = ran + 1; return true end)
    Kit.supAction('test:op3Sup', 'viewMissionList', function() ran = ran + 1; return true end)
    Kit.callback('test:op3Read', 'viewMissionList', function() return { ok = 1 } end)
    local real, aces = _G.IsPlayerAceAllowed, 0
    _G.IsPlayerAceAllowed = function(...)
        aces = aces + 1
        return real(...)
    end
    local function Aces(fn)
        aces = 0
        fn()
        return aces
    end
    local a1 = Aces(function() H.ok(Kit.run('test:op3Admin', admin, {}), 'the admin action runs') end)
    local a2 = Aces(function()
        Adv(1100, 1100)
        local res = H.callback('crimson-police:test:op3Read', admin, {})
        H.ok(res and res.ok, 'the admin read answers')
    end)
    local a3 = Aces(function() H.ok(Kit.run('test:op3Sup', sup, {}), 'the supervisor action runs') end)
    local a4 = Aces(function()
        H.ok(not Kit.run('test:op3Admin', sup, {}), 'a supervisor cannot run an admin action')
    end)
    _G.IsPlayerAceAllowed = real
    H.eq(ran, 2, 'each allowed action ran once')
    H.eq(a1, 1, ('an admin action: one ace check (%d; 2 before OP3)'):format(a1))
    H.eq(a2, 1, ('an admin read: one ace check (%d; 2 before OP3)'):format(a2))
    H.ok(a3 <= 4, ('a supervisor action: at most 4 ace checks (%d; 6 before OP3)'):format(a3))
    H.ok(a4 <= 2, ('a refused admin action: the ace checks once (%d)'):format(a4))
end

if not os.getenv('E2E_KEEP_DB') then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db)) end
_G.print = World.print
return H
