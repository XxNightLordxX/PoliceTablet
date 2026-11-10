-- The shared helper library: the small helpers every module used to carry its own copy of. Loaded on both sides
-- after shared/init.lua and before every module (docs/dev/ARCHITECTURE.md, "The helper library").

-- The shared helper library: the small helpers every module used to carry its own copy of. Loaded on both sides
-- after shared/init.lua and before every module (docs/dev/ARCHITECTURE.md, "The helper library").
--   CP.U.toSrc   a player source number from anything (shared/utils.lua)
--   CP.Db        wait for the store before a query (server)
--   CP.notify    a tablet toast (server: to one player; client: to this player)
--   CP.push      a tablet push to one player, through CP.Tablet.push and its Config.Performance.pushGapMs rule
--   CP.Ext       a safe call into another resource's export, with the resource-started check
--   CP.Lock      one-at-a-time per key (an officer, a row, a player), freed on error and when a player drops
--   CP.Daily     per-day counters for caps: count and reserve in one step, so two requests cannot pass a cap

CP = CP or {}

-- ============================================================================
--                                    STORE
-- ============================================================================

-- Waits until the migrations finished (CP.Migrations.ready). Raises err.not_started once the start failed, so a
-- query never reaches a store that did not start. Returns true.
function CP.Db()
    local M = CP.Migrations -- server only
    if M and M.ready then M.ready() end
    return true
end

-- ============================================================================
--                              TOASTS AND PUSHES
-- ============================================================================

-- Calls CP.Tablet[fnName] in pcall; a failure is logged and answers false.
local function TabletCall(fnName, ...)
    local T = CP.Tablet
    if type(T) ~= 'table' or type(T[fnName]) ~= 'function' then return false end
    local ok, err = pcall(T[fnName], ...)
    if not ok then
        CP.err('tablet', 'CP.Tablet.%s failed: %s', fnName, tostring(err))
        return false
    end
    return true
end

if CP.isServer then
    -- A tablet toast to one player: kind ('success' | 'error' | 'info' | 'warning'), a locale key and its vars;
    -- opts as CP.Tablet.notify takes them ({ channel = 'social' } ...). Nothing for a bad source or the console.
    function CP.notify(src, kind, key, vars, opts)
        local n = CP.U.toSrc(src)
        if not n then return false end
        return TabletCall('notify', n, kind, key, vars, opts)
    end

    -- A tablet push of one topic to one player. CP.Tablet.push holds a second push of a topic within
    -- Config.Performance.pushGapMs and merges it with the next one.
    function CP.push(src, topic, data)
        local n = CP.U.toSrc(src)
        if not n then return false end
        return TabletCall('push', n, topic, data)
    end
else
    -- A tablet toast to this player: kind, a locale key and its vars, opts as CP.Tablet.notify takes them.
    function CP.notify(kind, key, vars, opts)
        return TabletCall('notify', kind, CP.L(key, vars), opts)
    end
end

-- ============================================================================
--                           OTHER RESOURCES' EXPORTS
-- ============================================================================

CP.Ext = CP.Ext or {}

-- true while that resource is started.
function CP.Ext.started(resource)
    return type(GetResourceState) == 'function' and GetResourceState(resource) == 'started'
end

-- exports[resource]:fnName(...) in pcall. Answers true, its results | false, 'not_started' (the resource is not
-- started) | false, the error (logged under the tag 'ext').
function CP.Ext.call(resource, fnName, ...)
    if not CP.Ext.started(resource) then return false, 'not_started' end
    local args = table.pack(...)
    local res = table.pack(pcall(function()
        local r = exports[resource]
        return r[fnName](r, table.unpack(args, 1, args.n))
    end))
    if not res[1] then
        CP.err('ext', 'exports[\'%s\']:%s failed: %s', resource, fnName, tostring(res[2]))
        return false, res[2]
    end
    return true, table.unpack(res, 2, res.n)
end

-- ============================================================================
--                                ONE AT A TIME
-- ============================================================================
-- local lock = CP.Lock.new()                     keys are anything (an officer's citizenid, a row id)
-- local lock = CP.Lock.new({ players = true })   keys are player sources: a player's key is freed when he drops
-- lock:run(key, waitMs, fn, ...) runs fn(...) while it holds the key. waitMs: how long to wait for the key
-- (0 = refuse at once; it looks every 50 ms). Answers 'ok', fn's results | 'busy' (still held) | 'error', the error.
-- The key is freed when fn ends, also when it raised. A key freed by a drop is not freed again by the run that held
-- it, so a new holder keeps it.
CP.Lock = CP.Lock or {}
local LOCK_STEP_MS = 50
local Lock = {}
Lock.__index = Lock
local playerLocks = setmetatable({}, { __mode = 'k' })

function CP.Lock.new(opts)
    local lock = setmetatable({ _held = {}, _next = 0 }, Lock)
    if type(opts) == 'table' and opts.players then playerLocks[lock] = true end
    return lock
end

function Lock:held(key) return key ~= nil and self._held[key] ~= nil end

-- Takes the key at once: a token, or nil while it is held.
function Lock:take(key)
    if key == nil or self._held[key] ~= nil then return nil end
    self._next = self._next + 1
    self._held[key] = self._next
    return self._next
end

-- Frees the key when the token still holds it.
function Lock:free(key, token)
    if key ~= nil and (token == nil or self._held[key] == token) then self._held[key] = nil end
end

local function Finish(self, keys, tokens, res)
    for i, k in ipairs(keys) do self:free(k, tokens[i]) end
    if not res[1] then return 'error', res[2] end
    return 'ok', table.unpack(res, 2, res.n)
end

function Lock:run(key, waitMs, fn, ...)
    local waited, limit = 0, tonumber(waitMs) or 0
    while self._held[key] ~= nil do
        if waited >= limit then return 'busy' end
        Wait(LOCK_STEP_MS)
        waited = waited + LOCK_STEP_MS
    end
    local token = self:take(key)
    if not token then return 'busy' end
    return Finish(self, { key }, { token }, table.pack(pcall(fn, ...)))
end

-- All keys at once or none (a unit's members): 'busy' at once when one is held, else as run.
function Lock:runAll(keys, fn, ...)
    for _, k in ipairs(keys) do
        if self._held[k] ~= nil then return 'busy' end
    end
    local tokens = {}
    for i, k in ipairs(keys) do tokens[i] = self:take(k) end
    return Finish(self, keys, tokens, table.pack(pcall(fn, ...)))
end

function Lock:clear() self._held = {} end

-- A dropped player's keys in every players lock.
function CP.Lock._dropped(src)
    local n = CP.U.toSrc(src)
    if not n then return end
    for lock in pairs(playerLocks) do lock._held[n] = nil end
end

if CP.isServer and type(AddEventHandler) == 'function' then
    AddEventHandler('playerDropped', function() CP.Lock._dropped(source) end)
end

-- ============================================================================
--                                 PER-DAY CAPS
-- ============================================================================
-- local links = CP.Daily.new()   counts per key (an officer) for the current server day (CP.Schedule.dayStart)
-- links:reserve(key, cap, n) takes n of today's cap at once: a token, or nil when used + reserved + n > cap. The
-- check and the reservation are one step (nothing yields between them), so two requests sent at once cannot both
-- pass. After the work: links:commit(token) counts it, links:cancel(token) gives it back. A reservation made
-- yesterday counts for nothing today. Memory only: a restart starts every count at 0.
CP.Daily = CP.Daily or {}
local Daily = {}
Daily.__index = Daily

-- The server day (CP.Schedule.dayStart, else local midnight). The client has no os library: there it is one day.
local function DayNow()
    local now = os and os.time() or 0
    local S = CP.Schedule -- server only
    if S and type(S.dayStart) == 'function' then return S.dayStart(now) end
    local t = os and os.date('*t', now)
    return t and os and os.time({ year = t.year, month = t.month, day = t.day, hour = 0, min = 0, sec = 0 }) or 0
end

-- dayFn: the current day (any value that changes once a day); default the server day.
function CP.Daily.new(dayFn)
    return setmetatable({ _day = dayFn or DayNow, _rows = {}, _held = {}, _next = 0 }, Daily)
end

local function Row(self, key)
    local day = self._day()
    local r = self._rows[key]
    if not r or r.day ~= day then
        r = { day = day, n = 0, held = 0 }
        self._rows[key] = r
    end
    return r
end

-- Counted and reserved today.
function Daily:used(key) local r = Row(self, key); return r.n + r.held end

-- What is left of cap today (never below 0).
function Daily:left(key, cap) return math.max(0, (tonumber(cap) or 0) - self:used(key)) end

function Daily:reserve(key, cap, n)
    n = tonumber(n) or 1
    local r = Row(self, key)
    if r.n + r.held + n > (tonumber(cap) or 0) then return nil end
    r.held = r.held + n
    self._next = self._next + 1
    self._held[self._next] = { key = key, day = r.day, n = n }
    return self._next
end

local function Release(self, token, counted)
    local h = token and self._held[token]
    if not h then return false end
    self._held[token] = nil
    local r = self._rows[h.key]
    if not r or r.day ~= h.day then return true end
    r.held = math.max(0, r.held - h.n)
    if counted then r.n = r.n + h.n end
    return true
end

function Daily:commit(token) return Release(self, token, true) end

function Daily:cancel(token) return Release(self, token, false) end

-- Counts n today without a reservation.
function Daily:add(key, n) local r = Row(self, key); r.n = r.n + (tonumber(n) or 1) end

-- Forgets one key's count (nil: every key).
function Daily:clear(key)
    if key == nil then
        self._rows, self._held = {}, {}
    else
        self._rows[key] = nil
    end
end
