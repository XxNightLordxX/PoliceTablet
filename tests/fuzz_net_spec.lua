-- Forged calls to every server net event and ox_lib callback: a regression guard for the net plumbing.

-- Forged calls to every server net event and ox_lib callback: a regression guard for the net plumbing.
-- The world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the owner's scripts
-- running). Two parts, both with a fixed seed (CP_FUZZ_SEED, default 1):
--   1. the run events (objective, telemetry, route, pickup, spawn, custody, cuff, stun) sent by the REAL participant
--      with the REAL run id and random payloads (NaN, inf, huge, negative, wrong types, junk tables)
--   2. every registered event (but the server-local lifecycle ones) and every callback, sent CP_FUZZ_PER rounds
--      (default 5) from random server ids (players, staff, an unknown id, 0, -1) with 0 to 5 random arguments,
--      sometimes with a reused request id (a replay)
-- After both: nothing raised out of a handler, no reply said err.internal, no error line ('^1[crimson-police' or
-- 'failed:') was printed, no money and no item was given, and no active run holds a NaN or an infinite number.

_G.CP_WF_WORLD = 'fuzz'
_G.CP_WF_STORAGE = os.getenv('CP_WF_STORAGE')
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local realPrint = W.realPrint

local SEED = tonumber(os.getenv('CP_FUZZ_SEED') or '') or 1
local PER = math.max(1, tonumber(os.getenv('CP_FUZZ_PER') or '') or 5)
math.randomseed(SEED)

-- the error lines (CP.err prints '^1[crimson-police:<tag>]'; an export wrapper's 'failed:')
local errorLines = {}
do
    local inner = _G.print
    _G.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
        local line = table.concat(parts, ' ')
        if line:find('^%^1%[') or line:find('failed:', 1, true) then errorLines[#errorLines + 1] = line end
        return inner(...)
    end
end

-- the gaps of the test world the soak and the race spec fill too: ox_inventory's item hook, Qbox's gangs and
-- metadata, and the city's own mdt_dispatch and player_vehicles tables (the database is dropped at the end)
H.exportsMock.ox_inventory.registerHook = function() return 1 end
H.exportsMock.ox_inventory.removeHooks = function() end
H.exportsMock.qbx_core.GetGangs = function() return {} end
H.exportsMock.qbx_core.GetMetadata = function(src, key)
    local pd = type(src) == 'number' and PD[src]
    if not pd then return false end
    return pd.metadata[key]
end
local function Mysql(sql) os.execute(('mysql -uroot %s -e "%s"'):format(H.db, sql)) end
os.execute(('mysql -uroot -e "CREATE DATABASE IF NOT EXISTS %s"'):format(H.db))
Mysql(
    'DROP TABLE IF EXISTS mdt_dispatch, player_vehicles; '
        .. 'CREATE TABLE mdt_dispatch (id INT PRIMARY KEY, unique_id VARCHAR(64), priority INT, active TINYINT); '
        .. 'CREATE TABLE player_vehicles (plate VARCHAR(16))'
)

for src = 1, 7 do W.Place(src, vec3(-300.0 + src * 2.0, -1400.0, 30.0)) end
for _, src in ipairs({ 1, 2, 6, 7 }) do W.Cb('getSession', src, { ui = 'officer', via = 'command' }) end

-- ============================================================================
--                                  THE VALUES
-- ============================================================================

local NAN = 0 / 0
local SCALARS = {
    false,
    true,
    0,
    -1,
    1,
    2,
    7,
    99,
    1e308,
    -1e308,
    NAN,
    math.huge,
    -math.huge,
    2 ^ 53,
    math.mininteger,
    math.maxinteger,
    0.5,
    -0.0,
    '',
    'x',
    '1',
    'NaN',
    'run-0001',
    'sast',
    'fib',
    '%s%s%n',
    '\255\254',
    '../../../server.cfg',
    '\'; DROP TABLE x; --',
}
-- (no NUL byte: the harness sends SQL through the mysql command line, which cannot carry one; oxmysql can)
local LONG = string.rep('A', 70000)
local KEYS = {
    'runId',
    'id',
    'netId',
    'amount',
    'citizenid',
    'department',
    'dept',
    'type',
    'typeKey',
    'index',
    'page',
    'limit',
    'offset',
    'points',
    'cash',
    'reason',
    'note',
    'name',
    'value',
    'key',
    'path',
    'token',
    'target',
    'src',
    'missionId',
    'grade',
    'period',
    'confirm',
    'ok',
    'yes',
    'state',
    'text',
    'items',
    'count',
    'callId',
    'unitId',
    'opId',
    'coords',
    'x',
    'y',
    'z',
    'data',
    'list',
    'ids',
    'settings',
    'section',
    'expect',
    'rookie',
    'trainer',
    'requestId',
}

local function Scalar()
    local r = math.random(#SCALARS + 3)
    if r == #SCALARS + 1 then return nil end
    if r == #SCALARS + 2 then return LONG end
    if r == #SCALARS + 3 then return CID[math.random(1, 7)] end
    return SCALARS[r]
end

local function Val(depth)
    depth = depth or 0
    local r = math.random(10)
    if r <= 6 or depth > 3 then return Scalar() end
    if r == 7 then
        local t = {}
        for i = 1, math.random(0, 5) do t[i] = Val(depth + 1) end
        return t
    end
    if r == 8 then return { x = Val(depth + 1), y = Val(depth + 1), z = Val(depth + 1) } end
    local t = {}
    for _ = 1, math.random(0, 6) do
        local v = Val(depth + 1)
        if v ~= nil then t[KEYS[math.random(#KEYS)]] = v end
    end
    return t
end

-- the paths of every NaN or infinite number in v
local function NonFinite(v, path, seen, out)
    seen, out = seen or {}, out or {}
    if type(v) == 'number' and (v ~= v or v == math.huge or v == -math.huge) then out[#out + 1] = path end
    if type(v) == 'table' and not seen[v] then
        seen[v] = true
        for k, x in pairs(v) do NonFinite(x, path .. '.' .. tostring(k), seen, out) end
    end
    return out
end

local raises = {}
local function Raised(kind, name, err)
    local k = ('%s %s: %s'):format(kind, name, tostring(err):gsub('%d+', 'N'):sub(1, 200))
    raises[k] = (raises[k] or 0) + 1
end

local m0, i0, e0 = #W.addMoney, #W.addItem, #H.events

-- ============================================================================
--                 1. THE RUN EVENTS, FROM THE REAL PARTICIPANT
-- ============================================================================

local RUN_EVENTS = {
    'server:objective',
    'server:telemetry',
    'server:routeStatus',
    'server:recalcRoute',
    'server:pickupDone',
    'server:spawnChecking',
    'server:spawnPlaced',
    'server:npcCuff',
    'server:custody',
    'server:stunHit',
}
local RUN_TYPES = { 'vehicle', 'ped_hit', 'area', 'checkpoint', 'arrive', 'lights_siren', 'weapon_fired' }
local RUN_KEYS = {
    'type',
    'netId',
    'index',
    'speed',
    'coords',
    'damage',
    'model',
    'plate',
    'inside',
    'point',
    'x',
    'y',
    'z',
    'metres',
    'kind',
    'entity',
    'ms',
    'seconds',
}
local function RunVal(depth)
    depth = depth or 0
    local r = math.random(8)
    if r <= 4 or depth > 2 then return Scalar() end
    if r == 5 then return { x = RunVal(depth + 1), y = RunVal(depth + 1), z = RunVal(depth + 1) } end
    local t = {}
    for _, k in ipairs(RUN_KEYS) do
        if math.random(3) == 1 then t[k] = RunVal(depth + 1) end
    end
    if math.random(2) == 1 then t.type = RUN_TYPES[math.random(#RUN_TYPES)] end
    return t
end

local runCalls = 0
for _, typeKey in ipairs({ 'patrol', 'investigation' }) do
    W.Secs(400)
    local run = W.Accept(1, typeKey)
    H.ok(run ~= nil, 'run fuzz: ' .. typeKey .. ' accepted')
    if run then
        W.TakeWheel(1, run)
        W.Secs(3)
        for _ = 1, PER * 60 do
            local name = RUN_EVENTS[math.random(#RUN_EVENTS)]
            local args = name == 'server:stunHit' and { RunVal() } or { run.id, RunVal(), RunVal(), RunVal(), RunVal() }
            local ok, err = pcall(H.fire, 'crimson-police:' .. name, 1, table.unpack(args, 1, 5))
            if not ok then Raised('run event', name, err) end
            local ok2, err2 = pcall(H.step, 60)
            if not ok2 then Raised('after run event', name, err2) end
            runCalls = runCalls + 1
        end
        local bad = NonFinite(run, 'run')
        H.eq(#bad, 0,
            ('run fuzz: %s holds no NaN or infinite number (%s)'):format(typeKey, table.concat(bad, ' '):sub(1, 300)))
        W.Secs(60)
        W.Act('server:abandon', 1, run.id)
        W.Secs(5)
    end
end

-- ============================================================================
--                     2. EVERY EVENT AND CALLBACK, FORGED
-- ============================================================================

-- server-local lifecycle events (a client cannot send them: AddEventHandler) and the client side
local SKIP = { playerDropped = true, onResourceStop = true, onResourceStart = true, weaponDamageEvent = true }
local events, callbacks = {}, {}
for name in pairs(H.handlers) do
    if not SKIP[name] and not name:find('^QBCore:') and not name:find('^qbx_') and not name:find('^crimson%-contracts')
        and not name:find('client:', 1, true) then
        events[#events + 1] = name
    end
end
for name in pairs(H.callbacks) do callbacks[#callbacks + 1] = name end
table.sort(events)
table.sort(callbacks)
H.ok(#events > 100 and #callbacks > 50, ('net fuzz: %d events and %d callbacks found'):format(#events, #callbacks))

local SRCS = { 1, 2, 3, 5, 6, 99, 0, -1 }
local internal, calls = 0, 0
for round = 1, PER do
    for _, name in ipairs(events) do
        local src = SRCS[math.random(#SRCS)]
        local n = math.random(0, 5)
        local args = {}
        for i = 1, n do args[i] = Val() end
        -- a CP.Net.action takes (payload, reqId): a fresh id, or one used before (a replay)
        if name:find('^crimson%-police:server:') and n >= 1 and math.random(2) == 1 then
            args[2] = 'fz' .. (math.random(3) == 1 and math.random(1, 20) or calls)
        end
        local ok, err = pcall(H.fire, name, src, table.unpack(args, 1, n))
        if not ok then Raised('event', name, err) end
        local ok2, err2 = pcall(H.step, 40)
        if not ok2 then Raised('after event', name, err2) end
        calls = calls + 1
    end
    for _, name in ipairs(callbacks) do
        local src = SRCS[math.random(#SRCS)]
        local ok, res = pcall(H.callback, name, src, Val(), math.random(3) == 1 and ('fz' .. calls) or nil)
        if not ok then
            Raised('callback', name, res)
        elseif type(res) == 'table' and res.error == 'err.internal' then
            internal = internal + 1
            realPrint('INTERNAL callback ' .. name)
        end
        local ok2, err2 = pcall(H.step, 40)
        if not ok2 then Raised('after callback', name, err2) end
        calls = calls + 1
    end
    local ok3, err3 = pcall(H.advance, 1200, 200)
    if not ok3 then Raised('advance', 'round ' .. round, err3) end
end
for i = e0 + 1, #H.events do
    local e = H.events[i]
    if e.name == 'crimson-police:client:actionResult' and e.args[2] == false and e.args[3] == 'err.internal' then
        internal = internal + 1
    end
end
print(('REPORT fuzz seed %d: %d run events, %d net calls over %d events and %d callbacks'):format(SEED, runCalls, calls,
    #events, #callbacks))

-- ============================================================================
--                                  THE CHECKS
-- ============================================================================

local raiseLines = {}
for k, n in pairs(raises) do raiseLines[#raiseLines + 1] = ('x%d %s'):format(n, k) end
table.sort(raiseLines)
for _, l in ipairs(raiseLines) do realPrint('RAISE ' .. l) end
H.eq(#raiseLines, 0, 'no handler raised')
H.eq(internal, 0, 'no reply said err.internal')
for _, l in ipairs(errorLines) do realPrint('ERRLINE ' .. l:sub(1, 300)) end
H.eq(#errorLines, 0, 'no error line')
H.eq(#W.addMoney - m0, 0, 'no money was given')
H.eq(#W.addItem - i0, 0, 'no item was given')
local bad = {}
for _, run in ipairs(CP.Runs.all()) do
    for _, p in ipairs(NonFinite(run, 'run ' .. tostring(run.id))) do bad[#bad + 1] = p end
end
H.eq(#bad, 0, 'no active run holds a NaN or infinite number: ' .. table.concat(bad, ' '):sub(1, 300))
if not W.ON_DB then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s"'):format(H.db)) end

return H
