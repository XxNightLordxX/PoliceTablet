-- CP.Spawn (server): every new mission entity waits frozen where the server made it until the game of an officer of
-- its run has put it on the ground (the placer, modules/spawn/client.lua); a point that game reports bad is swapped for
-- another point the mission may use there (Config.Spawning.place, placeTimeoutMs, retries, onTimeout).

CP.Spawn = CP.Spawn or {}
local Spawn = CP.Spawn
local U = CP.U
local TAG = 'spawn'

local PLACED_EVENT = 'server:spawnPlaced'
local CHECKING_EVENT = 'server:spawnChecking'
local TICK_MS = 500         -- the open asks are checked this often (who simulates it, officers near, the time)
local Z_SLACK = 2.0         -- metres an ok point may sit off where it is put (a vehicle up to 1.7 m), over snapWithin
local OCCUPIED_M = 1.0      -- metres (on the map): another point is never one an entity of the run stands on
local ALT_MAX = 8           -- other points kept per entity
local REASON_MAX = 32       -- characters of a game's reason kept
local KINDS = { ped = 'ped', vehicle = 'vehicle', object = 'object' }
local ON_TIMEOUT = { unfreeze = true, delete = true }
-- How long an officer's game that said it checks an entity (server:spawnChecking) may take before its placeTimeoutMs
-- runs again: the placer's wait for its turn in a big wave (PLACE_QUEUE_MS 30 s) and its two asks for control
-- (PLACE_CONTROL_MS 2 s each, modules/spawn/client.lua), plus the probe's loads (collisionTimeoutMs and
-- interiorTimeoutMs, kept to LOAD_MS as the probe keeps them).
local CHECK_BASE_MS = 34000
local LOAD_MS = { 500, 30000 }

local asks = {}             -- [netId] = ask: see Spawn.ask
local seq = 0
local looping = false

local function Cfg() return type(Config.Spawning) == 'table' and Config.Spawning or {} end

local function On()
    local c = Cfg()
    return c.enabled ~= false and c.place ~= false
end

local function Num(v, default)
    v = tonumber(v)
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function Has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function RunOf(id)
    if id == nil or not (CP.Runs and CP.Runs.get) then return nil end
    local ok, run = pcall(CP.Runs.get, id)
    return ok and type(run) == 'table' and run or nil
end

local function ActiveSrcs(run)
    if not (CP.Runs and CP.Runs.activeSrcs) then return {} end
    local ok, list = pcall(CP.Runs.activeSrcs, run)
    return ok and type(list) == 'table' and list or {}
end

-- { x, y, z, h, label, indoor } of a point: a vector, { x, y, z, w | h }, { [1], [2], [3], [4] } or { coords = one of
-- those, label, indoor }; nil when it is none.
local function PointOf(v)
    local label, indoor = nil, nil
    if type(v) == 'table' and v.coords ~= nil then label, indoor, v = v.label, v.indoor, v.coords end
    local t = type(v)
    local x, y, z, h = nil, nil, nil, nil
    if t == 'vector3' or t == 'vector4' then
        x, y, z, h = v.x, v.y, v.z, t == 'vector4' and v.w or nil
    elseif t == 'table' then
        x, y, z, h = v.x or v[1], v.y or v[2], v.z or v[3], v.w or v.h or v.heading or v[4]
    end
    x, y, z = Num(x), Num(y), Num(z)
    if not (x and y and z) then return nil end
    return {
        x = x + 0.0,
        y = y + 0.0,
        z = z + 0.0,
        h = Num(h, 0.0) + 0.0,
        label = type(label) == 'string' and label or nil,
        indoor = indoor == true or nil,
    }
end

-- Unique per ask: a move to another point gets a new one, so a late answer for the old point is never taken.
local function NewToken(netId)
    seq = seq + 1
    return ('%x-%d-%d'):format(os.time(), netId, seq)
end

-- What goes in the cp bag (ARCHITECTURE 6.2): from = the point it waits at after a move to another one.
local function AskOf(a)
    local p = { x = a.x, y = a.y, z = a.z, h = a.h, kind = a.kind, token = a.token }
    if a.from then p.from = { x = a.from.x, y = a.from.y } end
    return p
end

-- true while the entity is still the run's own, alive.
local function Live(run, a)
    if run.state == 'ended' or type(run.entities) ~= 'table' then return false end
    local e = run.entities[a.netId]
    return type(e) == 'table' and e.entity == a.entity and not e.dead and DoesEntityExist(a.entity) and true or false
end

local function Freeze(a, on)
    if FreezeEntityPosition and DoesEntityExist(a.entity) then FreezeEntityPosition(a.entity, on) end
end

-- The ask into (place) or out of (nil) the entity's bag: through CP.Npc's record when it keeps one, else the
-- engine's copy.
local function WritePlace(run, a, place)
    if CP.Npc and CP.Npc.setPlace then
        local ok, done = pcall(CP.Npc.setPlace, run, a.netId, place)
        if ok and done then return true end
    end
    local e = run.entities[a.netId]
    if type(e) ~= 'table' or e.entity ~= a.entity or not DoesEntityExist(a.entity) then return false end
    local nb = U.deepcopy(type(e.bag) == 'table' and e.bag or {})
    nb.place = place and U.deepcopy(place) or nil
    local ok = pcall(function() Entity(a.entity).state:set('cp', nb, true) end)
    if ok then e.bag = nb end
    return ok
end

-- Let it go where it stands: an object stays frozen (as the engine made it), and so does a person CP.Npc holds in the
-- cuffed pose.
local function LetGo(a)
    if a.hold then return end
    if CP.Npc and CP.Npc.getState then
        local ok, st = pcall(CP.Npc.getState, a.netId)
        if ok and st == 'cuffed' then return end
    end
    Freeze(a, false)
end

-- The ask is over: out of the bag (CP.Npc's games let a person go once it is gone), let go when letGo.
local function Done(run, a, letGo)
    if asks[a.netId] == a then asks[a.netId] = nil end
    WritePlace(run, a, nil)
    if letGo then LetGo(a) end
end

local function Where(a) return ('%s %s at %.2f %.2f %.2f'):format(a.kind, a.model, a.x, a.y, a.z) end

local function CheckMs()
    local c = Cfg()
    local function Load(key, default) return U.clamp(Num(c[key], default), LOAD_MS[1], LOAD_MS[2]) end
    return CHECK_BASE_MS + Load('collisionTimeoutMs', 6000) + Load('interiorTimeoutMs', 5000)
end

local function PedXY(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local x, y = U.xyz(GetEntityCoords(ped))
    return Num(x), Num(y)
end

-- The active participants within Config.Spawning.activateRange of the point (on the map): { [src] = true }.
local function NearSrcs(srcs, a)
    local range = math.max(0, Num(Cfg().activateRange, 150.0))
    local near = {}
    for _, src in ipairs(srcs) do
        local x, y = PedXY(src)
        if x and y and (x - a.x) ^ 2 + (y - a.y) ^ 2 <= range * range then near[src] = true end
    end
    return near
end

-- The game that simulates it changed: frozen again there unless that is the game of an officer near it (that game
-- places it). FREEZE_ENTITY_POSITION is a server RPC to the game that simulates the entity now: the one written at
-- the creation reached the first game only.
local function WatchOwner(a, near)
    if not NetworkGetEntityOwner then return end
    local owner = math.tointeger(tonumber(NetworkGetEntityOwner(a.entity))) or -1
    if owner == a.owner then return end
    a.owner = owner
    if owner <= 0 or near[owner] then return end
    Freeze(a, true)
    a.refrozen = true
end

-- A point an entity of the run (another than this one) stands on, or another waiting entity's point.
local function Occupied(run, a, p)
    local r2 = OCCUPIED_M * OCCUPIED_M
    for netId, e in pairs(run.entities) do
        if netId ~= a.netId and type(e) == 'table' and not e.dead and e.entity and DoesEntityExist(e.entity) then
            local x, y = U.xyz(GetEntityCoords(e.entity))
            x, y = Num(x), Num(y)
            if x and y and (x - p.x) ^ 2 + (y - p.y) ^ 2 <= r2 then return true end
        end
    end
    for netId, o in pairs(asks) do
        if netId ~= a.netId and o.runId == a.runId and (o.x - p.x) ^ 2 + (o.y - p.y) ^ 2 <= r2 then return true end
    end
    return false
end

-- The next of the entity's other points that is free and that the spawn director allows now (Runs.choosePoints: away
-- from the officers where they stand by now, never behind them), or nil.
local function NextPoint(run, a)
    local free = {}
    for i, p in ipairs(a.alt) do
        if not a.tried[i] and not Occupied(run, a, p) then
            free[#free + 1] = { coords = { x = p.x, y = p.y, z = p.z }, label = p.label, indoor = p.indoor, i = i }
        end
    end
    if #free == 0 then return nil end
    local pick = free[1]
    if CP.Runs and CP.Runs.choosePoints then
        local ok, chosen = pcall(CP.Runs.choosePoints, run, free, 1, {
            obj = a.obj,
            name = ('another point for %s %s'):format(a.kind, a.model),
        })
        pick = ok and type(chosen) == 'table' and chosen[1] or nil
    end
    if not pick then return nil end
    a.tried[pick.i] = true
    return a.alt[pick.i]
end

-- A bad point: the entity waits at another of its points (the officer's game moves it there with the next ask), up
-- to Config.Spawning.retries times; then, or with no other point, it is let go where it is.
local function Retry(run, a, reason, groundZ)
    local retries = math.max(0, math.floor(Num(Cfg().retries, 2)))
    local ground = groundZ and ('%.2f'):format(groundZ) or 'not found'
    local alt = a.tries < retries and NextPoint(run, a) or nil
    if asks[a.netId] ~= a or not Live(run, a) then return end
    if not alt then
        local why = a.tries >= retries and ('it there (Config.Spawning.retries = %d spent)'):format(retries)
            or 'it there (no other point allowed)'
        CP.warn(TAG, 'run %s: %s is %s (ground %s); used %s', run.id, Where(a), reason, ground, why)
        Done(run, a, true)
        return
    end
    CP.warn(TAG, 'run %s: %s is %s (ground %s); used %s', run.id, Where(a), reason, ground,
        ('%s (%.2f %.2f %.2f) instead'):format(alt.label or 'another point', alt.x, alt.y, alt.z))
    a.from = { x = a.x, y = a.y }
    a.x, a.y, a.z, a.h = alt.x, alt.y, alt.z, alt.h
    a.tries = a.tries + 1
    a.token = NewToken(a.netId)
    a.waitedMs = 0
    a.checkedBy, a.checkUntil = nil, nil
    if not WritePlace(run, a, AskOf(a)) then Done(run, a, true) end
end

local function TimedOut(run, a, ms)
    local mode = ON_TIMEOUT[Cfg().onTimeout] and Cfg().onTimeout or 'unfreeze'
    -- one the server only moved (Spawn.again: a warrant's suspect who gives up at the door, the prisoner transport put
    -- on its parking point) stood on the ground in the world before: let go where it stands, never removed
    if a.again then mode = 'unfreeze' end
    CP.warn(TAG, 'run %s: %s was not placed by an officer\'s game within %d ms; %s (Config.Spawning.onTimeout)', run.id,
        Where(a), ms, mode == 'delete' and 'removed' or 'let go where it stands')
    if mode ~= 'delete' then return Done(run, a, true) end
    asks[a.netId] = nil
    -- counted as gone first (the objective that made it learns it), then removed
    if CP.Runs.entityDied then CP.Runs.entityDied(run, a.netId, nil) end
    if CP.Runs.deleteEntity then CP.Runs.deleteEntity(run, a.netId) end
end

-- One open ask, every TICK_MS (dt ms since the last check).
local function Check(a, on, timeoutMs, dt)
    local run = RunOf(a.runId)
    if not run or not Live(run, a) then
        asks[a.netId] = nil
        return
    end
    -- switched off in Settings: nobody waits any more
    if not on then return Done(run, a, true) end
    if a.busy then return end
    local srcs = ActiveSrcs(run)
    local near = NearSrcs(srcs, a)
    WatchOwner(a, near)
    -- the time only runs while an officer is near enough for his game to place it
    if next(near) == nil then return end
    -- and not while an officer's game checks it (a wave's later ones wait their turn there), up to CheckMs
    if a.checkUntil then
        if GetGameTimer() < a.checkUntil and Has(srcs, a.checkedBy) then return end
        a.checkUntil = nil
    end
    a.waitedMs = a.waitedMs + dt
    if a.waitedMs >= timeoutMs then TimedOut(run, a, timeoutMs) end
end

local function Tick(dt)
    local on = On()
    local timeoutMs = math.floor(Num(Cfg().placeTimeoutMs, 8000))
    -- a copy: letting one go or removing it may make new ones (an objective that learns one is gone)
    local list = {}
    for _, a in pairs(asks) do list[#list + 1] = a end
    for _, a in ipairs(list) do
        if asks[a.netId] == a then Check(a, on, timeoutMs, dt) end
    end
end

local function EnsureLoop()
    if looping then return end
    looping = true
    CreateThread(function()
        local last = GetGameTimer()
        while next(asks) ~= nil do
            Wait(TICK_MS)
            local now = GetGameTimer()
            local ok, err = pcall(Tick, now - last)
            last = now
            if not ok then CP.err(TAG, 'the placement check failed: %s', tostring(err)) end
        end
        looping = false
    end)
end

-- Called by the engine for every new mission entity (CP.Runs Track, kind 'ped' | 'vehicle' | 'object', opts the spawn
-- opts: coords, model, obj, frozen, alt = the other points the block may use there): with Config.Spawning.place on it
-- freezes the entity, keeps the ask and returns it for the cp bag (place); nil = no ask (off, or no point).
function Spawn.ask(run, netId, entity, kind, opts)
    kind = KINDS[kind]
    netId = math.tointeger(tonumber(netId))
    if not On() or type(run) ~= 'table' or not kind or not netId or type(opts) ~= 'table' then return nil end
    local p = PointOf(opts.coords)
    if not p then return nil end
    local a = {
        runId = run.id,
        netId = netId,
        entity = entity,
        kind = kind,
        model = tostring(opts.model),
        obj = opts.obj,
        x = p.x,
        y = p.y,
        z = p.z,
        h = p.h,
        alt = {},
        tried = {},
        tries = 0,
        waitedMs = 0,
        -- an object stays frozen once placed, as the engine always made it (opts.frozen = false: let go)
        hold = kind == 'object' and opts.frozen ~= false,
    }
    for _, v in ipairs(type(opts.alt) == 'table' and opts.alt or {}) do
        local q = PointOf(v)
        if q and #a.alt < ALT_MAX then a.alt[#a.alt + 1] = q end
    end
    a.token = NewToken(netId)
    Freeze(a, true)
    asks[netId] = a
    EnsureLoop()
    return AskOf(a)
end

-- The server has moved a person (or a vehicle) of the run itself (SetEntityCoords: flee_arrest stands a surrendering
-- suspect in front of the door, custody puts a late prisoner transport on its parking point): he waits frozen at
-- coords until an officer's game has put him on the ground there, as when he was made. There is no other point for
-- him: a bad one lets him go where he stands, with one warning.
-- from = { x, y } where he stood before the move (the placer moves him to coords first when the move has not reached
-- its game yet). An ask still open for him is replaced (a late answer for it is never taken). Returns the ask (in his
-- bag), or nil (place off, not a live entity of the run, coords not a point).
function Spawn.again(run, netId, coords, from)
    netId = math.tointeger(tonumber(netId))
    if not On() or type(run) ~= 'table' or not netId or type(run.entities) ~= 'table' then return nil end
    local e = run.entities[netId]
    local kind = type(e) == 'table' and KINDS[e.kind] or nil
    if not kind or e.dead or not e.entity or not DoesEntityExist(e.entity) or run.state == 'ended' then return nil end
    local p = PointOf(coords)
    if not p then return nil end
    local a = {
        runId = run.id,
        netId = netId,
        entity = e.entity,
        kind = kind,
        model = tostring(e.model),
        obj = e.obj,
        x = p.x,
        y = p.y,
        z = p.z,
        h = p.h,
        alt = {},
        tried = {},
        tries = 0,
        waitedMs = 0,
        hold = kind == 'object',
        again = true,
    }
    local fx, fy = nil, nil
    if type(from) == 'table' or type(from) == 'vector3' or type(from) == 'vector4' then
        fx, fy = Num(from.x or from[1]), Num(from.y or from[2])
    end
    if fx and fy then a.from = { x = fx + 0.0, y = fy + 0.0 } end
    a.token = NewToken(netId)
    asks[netId] = a
    Freeze(a, true)
    if not WritePlace(run, a, AskOf(a)) then
        asks[netId] = nil
        LetGo(a)
        return nil
    end
    EnsureLoop()
    return AskOf(a)
end

-- true while the entity netId still waits frozen for its placement (an ask for it is open).
function Spawn.holding(netId)
    netId = math.tointeger(tonumber(netId))
    return netId ~= nil and asks[netId] ~= nil
end

-- How many entities of the run still wait for their placement.
function Spawn.waiting(runId)
    local n = 0
    for _, a in pairs(asks) do if a.runId == runId then n = n + 1 end end
    return n
end

-- The answer of the placer of an officer of the run (once per ask): placed (it is on the ground, or seated, attached,
-- or was placed and let go before: moved) or bad (the probe's status).
local function OnPlaced(src, runId, data)
    if type(data) ~= 'table' then return end
    local netId = math.tointeger(tonumber(data.netId))
    local a = netId and asks[netId] or nil
    if not a or a.busy or a.runId ~= runId or data.token ~= a.token then return end
    local run = RunOf(runId)
    if not run or not Live(run, a) then
        asks[netId] = nil
        return
    end
    if not Has(ActiveSrcs(run), src) then return end
    local reason = type(data.reason) == 'string' and data.reason:sub(1, REASON_MAX) or 'unknown'
    if data.result == 'placed' then
        local z = Num(data.z)
        local snap = math.max(0, Num(type(Cfg().ground) == 'table' and Cfg().ground.snapWithin, 3.0))
        if reason ~= 'moved' and z and math.abs(z - a.z) > snap + Z_SLACK then
            CP.warn(TAG, 'run %s: %s: the game of %s put it at %.2f, too far from its point; not taken', run.id,
                Where(a), tostring(src), z)
            return
        end
        -- the officer's game let it go on the ground; again here when this server froze it after that game's freeze,
        -- and for one that game left as it was (seated, attached, moved)
        local placedHere = reason == 'ok' or reason == 'snap'
        Done(run, a, a.refrozen == true or not placedHere or (a.kind == 'object' and not a.hold))
        CP.log(TAG, 'run %s: %s placed by %s (%s)%s', run.id, Where(a), tostring(src), reason,
            z and (' at %.2f'):format(z) or '')
        return
    end
    if data.result ~= 'bad' then return end
    -- the server seated him in his car right after it made him (a pursuit's, an escort's, a transport's people):
    -- the game checked the ground before the seat reached it
    if a.kind == 'ped' and GetVehiclePedIsIn and (tonumber(GetVehiclePedIsIn(a.entity, false)) or 0) ~= 0 then
        Done(run, a, true)
        CP.log(TAG, 'run %s: %s is seated in a vehicle; placed', run.id, Where(a))
        return
    end
    a.busy = true
    -- the director may ask the officers' games what they can see: in a thread of its own
    CreateThread(function()
        local ok, err = pcall(Retry, run, a, reason, Num(data.groundZ))
        a.busy = nil
        if not ok then
            CP.err(TAG, 'run %s: another point for %s failed: %s', run.id, Where(a), tostring(err))
            if asks[a.netId] == a then Done(run, a, true) end
        end
    end)
end

-- An officer's game of the run checks the entity of the ask now (once per ask): its time waits for the answer, at
-- most CheckMs, while that officer stays on the run. done = true from that game: it gave up with no answer (no
-- control, the entity left it, its turn never came), so the time runs on now; a later word for the ask is not taken.
local function OnChecking(src, runId, data)
    if type(data) ~= 'table' then return end
    local netId = math.tointeger(tonumber(data.netId))
    local a = netId and asks[netId] or nil
    if not a or a.runId ~= runId or data.token ~= a.token then return end
    if data.done == true then
        if a.checkedBy == src then a.checkUntil = nil end
        return
    end
    if a.checkedBy ~= nil then return end
    local run = RunOf(runId)
    if not run or not Has(ActiveSrcs(run), src) then return end
    a.checkedBy, a.checkUntil = src, GetGameTimer() + CheckMs()
end

RegisterNetEvent(CP.e(CHECKING_EVENT), function(runId, data)
    local src = source
    if not CP.Net.rateOk(src, CHECKING_EVENT, 30, 1000) then return end
    local ok, err = pcall(OnChecking, src, runId, data)
    if not ok then CP.err(TAG, 'spawnChecking from %s failed: %s', tostring(src), tostring(err)) end
end)

RegisterNetEvent(CP.e(PLACED_EVENT), function(runId, data)
    local src = source
    if not CP.Net.rateOk(src, PLACED_EVENT, 30, 1000) then return end
    local ok, err = pcall(OnPlaced, src, runId, data)
    if not ok then CP.err(TAG, 'spawnPlaced from %s failed: %s', tostring(src), tostring(err)) end
end)
