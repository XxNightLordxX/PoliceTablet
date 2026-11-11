-- The shared helper library: the small helpers every module used to carry its own copy of. Loaded on both sides
-- after shared/init.lua and before every module (docs/dev/ARCHITECTURE.md, "The helper library").

-- The shared helper library: the small helpers every module used to carry its own copy of. Loaded on both sides
-- after shared/init.lua and before every module (docs/dev/ARCHITECTURE.md, "The helper library").
--   CP.U.toSrc   a player source number from anything (shared/utils.lua)
--   CP.Db        wait for the store before a query (server)
--   CP.errEvery  an error line at most once a minute per tag and key (a failure that repeats every tick)
--   CP.notify    a tablet toast (server: to one player; client: to this player)
--   CP.push      a tablet push (server: to one player, through CP.Tablet.push and its Config.Performance.pushGapMs
--                rule; client: to this player's own screen)
--   CP.srcOf     the source of the player who has a character loaded (server); CP.notifyCitizen and
--                CP.pushCitizen: a toast or push to him; CP.deptOfCitizen: his department
--   CP.Ext       a safe call into another resource's export, with the resource-started check (failures through
--                CP.errEvery)
--   CP.Lock      one-at-a-time per key (an officer, a row, a player), freed on error and when a player drops
--   CP.Daily     per-day counters for caps: count and reserve in one step, so two requests cannot pass a cap
--   CP.Objective one kind of Config.Objectives (dailyGoal, weeklyGoal, challenge, bounty, typeOfTheDay) and its switch
--   CP.ObjectiveResetHour the hour one objective kind's day and week start at (nil = Config.Time.resetHour)
--   CP.Progress  the one progress engine: the counted-run rule and the conditions goals and bounties count by
--   CP.Recognition one part of Config.Recognition (levels, levelCurve, badges, weeklyBadges, commendations,
--                fieldTraining) and its switch
--   CP.Num       a finite number or the default, kept between lo and hi; CP.Num0 (default 0), CP.Int (whole)
--   CP.Cfg       Config[section][key] or a default; CP.NonEmpty a trimmed string or nil; CP.cidOf a payload's
--                citizenid; CP.now seconds now; CP.SqlTs a DATETIME text; CP.warnOnce a warning once per tag and key
--   CP.query     a SELECT in pcall (rows or nil); CP.scalar its first value; CP.update the rows changed (server)
--   CP.Has       whether CP.<Mod>.<fn> is there (a module that may be missing or not loaded yet)
--   CP.can       whether a player may use a power (CP.Permissions.can, safe, always an error key on false)
--   CP.Call      a safe call into another module of this resource (CP.<Mod>.<fn> in pcall, failures through
--                CP.errEvery); a module binds its log tag once: local function Call(modName, fnName, ...)
--   CP.RealPlayers one mode of Config.RealPlayers (liveCrime, volunteer, criminalTablet) or the shared rules, and its
--                switch; CP.RealPlayersTakePart and CP.RealPlayersRowFilter: what a real-player case takes part in
--   CP.Restriction one kind of restriction (a mission ban, a suspension, a pair block...) joins the one restrictions
--                list (modules/supervisor/restrictions.lua)

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
--                                 ERROR LINES
-- ============================================================================

local ERR_EVERY_S = 60
local errAt = {} -- errAt[tag .. '\0' .. key] = the second the last line of that key was printed

-- Seconds now: os.time on the server, the game timer on the client (it has no os library).
local function NowS()
    if os and os.time then return os.time() end
    if type(GetGameTimer) == 'function' then return GetGameTimer() // 1000 end
    return 0
end

-- CP.err(tag, fmt, ...) at most once a minute per tag and key: a failure that repeats every tick (a stopped
-- resource's export, a lookup in a loop) prints one line a minute. Answers true when the line was printed.
---@param tag string
---@param key any
---@return boolean
function CP.errEvery(tag, key, fmt, ...)
    local k = tostring(tag) .. '\0' .. tostring(key)
    local now = NowS()
    if errAt[k] and now - errAt[k] < ERR_EVERY_S then return false end
    errAt[k] = now
    CP.err(tag, fmt, ...)
    return true
end

-- ============================================================================
--                                   NUMBERS
-- ============================================================================

-- v as a finite number (a number or a numeric string; NaN and infinities do not count), else default; then kept
-- between lo and hi when they are given.
---@return number|nil
function CP.Num(v, default, lo, hi)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then v = default end
    if v and lo and v < lo then v = lo end
    if v and hi and v > hi then v = hi end
    return v
end

-- CP.Num with 0 as the default (the counts and sums of a query row).
---@return number
function CP.Num0(v) return CP.Num(v, 0) end

-- CP.Num0 rounded down to a whole number.
---@return integer
function CP.Int(v) return math.floor(CP.Num(v, 0) + 0.0) end

-- v as a whole number between lo and hi (each optional), else nil: a payload's id or count, never rounded.
---@return integer|nil
function CP.IntIn(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if not n or n < (lo or math.mininteger) or n > (hi or math.maxinteger) then return nil end
    return n
end

-- Config[section][key] as it is now, or default when it is left out (a switch set to false reads as false).
---@param section string
---@param key string
function CP.Cfg(section, key, default)
    local s = type(Config) == 'table' and Config[section] or nil
    local v = nil
    if type(s) == 'table' then v = s[key] end
    if v == nil then return default end
    return v
end

-- A trimmed string, or nil when it is not a string or holds only spaces.
---@return string|nil
function CP.NonEmpty(s)
    if type(s) ~= 'string' then return nil end
    s = CP.U.trim(s)
    if s == '' then return nil end
    return s
end

-- Seconds now: CP.Schedule.now on the server (tests move its clock), else os.time or the game timer.
---@return integer
function CP.now()
    local S = CP.Schedule
    if type(S) == 'table' and type(S.now) == 'function' then return S.now() end
    return NowS()
end

local warnedOnce = {} -- warnedOnce[tag .. '\0' .. key] = true once that warning was printed

-- CP.warn(tag, fmt, ...) once per tag and key (a config mistake read on every call warns one time).
---@param tag string
---@param key any
---@return boolean printed
function CP.warnOnce(tag, key, fmt, ...)
    local k = tostring(tag) .. '\0' .. tostring(key)
    if warnedOnce[k] then return false end
    warnedOnce[k] = true
    CP.warn(tag, fmt, ...)
    return true
end

-- A Qbox citizenid as the store keeps it: 1-50 letters, digits, _ or -.
---@return boolean
function CP.ValidCid(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

-- A citizenid from a payload: trimmed, then CP.ValidCid; nil otherwise.
---@return string|nil
function CP.cidOf(v)
    local s = CP.NonEmpty(v)
    return CP.ValidCid(s) and s or nil
end

-- true when CP[modName][fnName] is a function.
---@param modName string
---@param fnName string
---@return boolean
function CP.Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

-- Whether player src may use a power: CP.Permissions.can(src, action, ctx, known) in CP.Call. Answers true | false,
-- errKey (never nil: 'err.no_permission' while the permissions module is missing, raised or named no key).
---@param action string
---@return boolean ok, string|nil errKey
function CP.can(src, action, ctx, known)
    local ok, allowed, errKey = CP.Call('permissions', 'Permissions', 'can', src, action, ctx, known)
    if ok and allowed == true then return true end
    return false, ok and errKey or 'err.no_permission'
end

-- Calls CP[modName][fnName](...) in pcall. Answers false when the module or function is missing or raised (the error
-- is logged under tag, once a minute per function), else true followed by the function's own answers.
---@param tag string
---@param modName string
---@param fnName string
---@return boolean ok
function CP.Call(tag, modName, fnName, ...)
    if not CP.Has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.errEvery(tag, modName .. '.' .. fnName, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
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
    -- 'YYYY-MM-DD HH:MM:SS' in server local time, for DATETIME columns.
    ---@return string
    function CP.SqlTs(ts) return os and os.date('%Y-%m-%d %H:%M:%S', math.floor(CP.Num(ts, 0))) end

    -- The rows of a SELECT ({} when none), or nil when it raised (an error line under the module's tag).
    ---@param tag string
    ---@param sql string
    ---@param params? table
    ---@return table|nil
    function CP.query(tag, sql, params)
        local ok, rows = pcall(MySQL.query.await, sql, params or {})
        if not ok then
            CP.err(tag, 'query failed: %s', tostring(rows))
            return nil
        end
        return type(rows) == 'table' and rows or {}
    end

    -- The first column of the first row, or nil (no row, or it raised: an error line under the module's tag).
    ---@param tag string
    ---@param sql string
    ---@param params? table
    ---@return any
    function CP.scalar(tag, sql, params)
        local ok, v = pcall(MySQL.scalar.await, sql, params or {})
        if not ok then
            CP.err(tag, 'query failed: %s', tostring(v))
            return nil
        end
        return v
    end

    -- The rows an UPDATE or DELETE changed, or nil when it raised (an error line under the module's tag).
    ---@param tag string
    ---@param sql string
    ---@param params? table
    ---@return integer|nil
    function CP.update(tag, sql, params)
        local ok, n = pcall(MySQL.update.await, sql, params or {})
        if not ok then
            CP.err(tag, 'update failed: %s', tostring(n))
            return nil
        end
        return tonumber(n) or 0
    end

    -- A tablet toast to one player: kind ('success' | 'error' | 'info' | 'warning'), a locale key and its vars;
    -- opts as CP.Tablet.notify takes them ({ channel = 'social' } ...). Nothing for a bad source or the console.
    function CP.notify(src, kind, key, vars, opts)
        local n = CP.U.toSrc(src)
        if not n then return false end
        return TabletCall('notify', n, kind, key, vars, opts)
    end

    -- The source of the player who has that character loaded now (CP.Qbx.getByCitizenId), or nil (offline, the
    -- console, no player lookup).
    function CP.srcOf(citizenid)
        if type(citizenid) ~= 'string' or citizenid == '' or citizenid == 'console' then return nil end
        local ok, s = CP.Call('lib', 'Qbx', 'getByCitizenId', citizenid)
        return ok and CP.U.toSrc(s) or nil
    end

    -- An officer's department: his Qbox job's department while he is online (on duty or not), else his officer row
    -- (row: the cp_officers row when the caller already read it), else nil.
    ---@param citizenid string
    ---@param row? table
    ---@return string|nil
    function CP.deptOfCitizen(citizenid, row)
        local n = CP.srcOf(citizenid)
        if n then
            local _, info = CP.Call('lib', 'Qbx', 'getInfo', n)
            if type(info) == 'table' and type(info.job) == 'table' then
                local _, dept = CP.Call('lib', 'Access', 'departmentForJob', info.job.name)
                if type(dept) == 'string' then return dept end
            end
        end
        if type(row) == 'table' then
            return type(row.department) == 'string' and row.department ~= '' and row.department or nil
        end
        local M = CP.Migrations
        if M and M.ready then M.ready() end
        local ok, d = pcall(MySQL.scalar.await, 'SELECT department FROM cp_officers WHERE citizenid = ? LIMIT 1',
            { citizenid })
        if ok and type(d) == 'string' and d ~= '' then return d end
        return nil
    end

    -- CP.notify to the player who has that character loaded: the source it went to, or nil (offline).
    function CP.notifyCitizen(citizenid, kind, key, vars, opts)
        local n = CP.srcOf(citizenid)
        if not n then return nil end
        CP.notify(n, kind, key, vars, opts)
        return n
    end

    -- CP.push to the player who has that character loaded: the source it went to, or nil (offline).
    function CP.pushCitizen(citizenid, topic, data)
        local n = CP.srcOf(citizenid)
        if not n then return nil end
        CP.push(n, topic, data)
        return n
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

    -- A tablet push of one topic to this player's own screen (local live updates).
    function CP.push(topic, data)
        return TabletCall('push', topic, data)
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
-- started) | false, the error (logged under the tag 'ext', once a minute per resource and export).
function CP.Ext.call(resource, fnName, ...)
    if not CP.Ext.started(resource) then return false, 'not_started' end
    local args = table.pack(...)
    local res = table.pack(pcall(function()
        local r = exports[resource]
        return r[fnName](r, table.unpack(args, 1, args.n))
    end))
    if not res[1] then
        CP.errEvery('ext', resource .. ':' .. fnName, 'exports[\'%s\']:%s failed: %s', resource, fnName,
            tostring(res[2]))
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

-- ============================================================================
--                                  OBJECTIVES
-- ============================================================================

local OBJECTIVE_KINDS = { dailyGoal = true, weeklyGoal = true, challenge = true, bounty = true, typeOfTheDay = true }

-- One kind of Config.Objectives as it is now (a setting changed in game included), never nil, and whether it is on
-- (enabled ~= false; the weekly bounty also needs the department challenge).
---@param kind string 'dailyGoal' | 'weeklyGoal' | 'challenge' | 'bounty' | 'typeOfTheDay'
---@return table cfg, boolean on
function CP.Objective(kind)
    local all = type(Config) == 'table' and type(Config.Objectives) == 'table' and Config.Objectives or {}
    local cfg = OBJECTIVE_KINDS[kind] and type(all[kind]) == 'table' and all[kind] or {}
    local on = OBJECTIVE_KINDS[kind] == true and cfg.enabled ~= false
    if on and kind == 'bounty' then
        local ch = type(all.challenge) == 'table' and all.challenge or {}
        on = ch.enabled ~= false
    end
    return cfg, on
end

-- The hour a kind's day and week start at (Config.Objectives.<kind>.resetHour, 0-23), or nil: -1 or left out
-- = the server's reset hour (Config.Time.resetHour), as every kind started before.
---@param kind string 'dailyGoal' | 'weeklyGoal' | 'typeOfTheDay'
---@return integer|nil
function CP.ObjectiveResetHour(kind)
    local h = CP.Num((CP.Objective(kind)).resetHour, -1)
    h = math.floor(h)
    if h < 0 or h > 23 then return nil end
    return h
end

-- ============================================================================
--                                   PROGRESS
-- ============================================================================
-- The one progress engine of the objectives: what a counted run is (a completed mission row; a point award or a
-- goal reward row never counts) and the conditions a goal or a weekly bounty counts it by. The daily and weekly
-- goals (modules/progression/goals.lua) and the department challenge and its bounty
-- (modules/progression/challenge.lua) both build their cp_mission_runs counts here, so one rule counts for both.
-- A condition: { type = mission type, mission = mission id, unit = true (2+ officers), crossDepartment = true
-- (2+ departments), missionCall = true (answered a mission call), stat = service-record column (the sum of it) };
-- none = every counted run.

CP.Progress = CP.Progress or {}
local Progress = CP.Progress

-- The service-record columns a condition may sum (stat = ...).
Progress.STATS = {
    arrests = true,
    citations = true,
    impounds = true,
    rescues = true,
    vehicles_stopped = true,
    evidence = true,
    decisions_ok = true,
    decisions_best = true,
}

-- The counted-run rule as SQL (alias: the table alias with its dot, such as 'r.', or '').
---@param alias? string
---@return string
function Progress.counted(alias)
    local a = alias or ''
    return ('%sstate = \'completed\' AND %smission_type NOT IN (\'manual_award\', \'goal\')'):format(a, a)
end

-- The SQL of a condition on top of the counted-run rule (' AND ...' parts, '' for none) and its ? values.
---@param cond table|nil
---@param alias? string
---@return string sql, table params
function Progress.match(cond, alias)
    local a = alias or ''
    local parts, params = {}, {}
    cond = type(cond) == 'table' and cond or {}
    if type(cond.type) == 'string' and cond.type ~= '' then
        parts[#parts + 1] = (' AND %smission_type = ?'):format(a)
        params[#params + 1] = cond.type
    end
    if type(cond.mission) == 'string' and cond.mission ~= '' then
        parts[#parts + 1] = (' AND %smission_id = ?'):format(a)
        params[#params + 1] = cond.mission
    end
    if cond.unit == true then parts[#parts + 1] = (' AND %sparticipants >= 2'):format(a) end
    if cond.crossDepartment == true then parts[#parts + 1] = (' AND %sdepartments_n >= 2'):format(a) end
    if cond.missionCall == true then parts[#parts + 1] = (' AND %smission_call_id IS NOT NULL'):format(a) end
    return table.concat(parts), params
end

-- What one counted run adds: 1, or its stat column. nil for a stat that is not a service-record column.
---@param cond table|nil
---@param alias? string
---@return string|nil
function Progress.value(cond, alias)
    local stat = type(cond) == 'table' and cond.stat or nil
    if stat == nil then return '1' end
    if type(stat) ~= 'string' or not Progress.STATS[stat] then return nil end
    return (alias or '') .. stat
end

-- WHERE parts for "the counted runs that match cond": counted-run rule plus the condition, and its ? values.
---@param cond table|nil
---@param alias? string
---@return string sql, table params
function Progress.where(cond, alias)
    local sql, params = Progress.match(cond, alias)
    return Progress.counted(alias) .. sql, params
end

-- A SELECT column that counts the matching counted runs of a group: SUM(CASE WHEN ... THEN 1 | stat ELSE 0 END),
-- and its ? values (in the order they appear). nil for an unknown stat.
---@param cond table|nil
---@param alias? string
---@return string|nil sql, table params
function Progress.sum(cond, alias)
    local value = Progress.value(cond, alias)
    if not value then return nil, {} end
    local sql, params = Progress.where(cond, alias)
    return ('SUM(CASE WHEN %s THEN %s ELSE 0 END)'):format(sql, value), params
end

-- ============================================================================
--                                 RECOGNITION
-- ============================================================================

-- The parts of Config.Recognition and whether each is on when its enabled key is left out (field training ships
-- off, so it is only on with enabled = true; commendations are on unless enabled = false).
local RECOGNITION_PARTS = {
    levels = true,
    levelCurve = true,
    badges = true,
    weeklyBadges = true,
    commendations = true,
    fieldTraining = false,
}

-- One part of Config.Recognition as it is now (a setting changed in game included), never nil, and whether it is
-- on. Parts without a switch (levels, levelCurve, badges, weeklyBadges) are always on.
---@param part string 'levels' | 'levelCurve' | 'badges' | 'weeklyBadges' | 'commendations' | 'fieldTraining'
---@return table cfg, boolean on
function CP.Recognition(part)
    local all = type(Config) == 'table' and type(Config.Recognition) == 'table' and Config.Recognition or {}
    local known = RECOGNITION_PARTS[part]
    local cfg = known ~= nil and type(all[part]) == 'table' and all[part] or {}
    if known == nil then return cfg, false end
    if known then return cfg, cfg.enabled ~= false end
    return cfg, cfg.enabled == true
end

-- ============================================================================
--                                 REAL PLAYERS
-- ============================================================================

-- The parts of Config.RealPlayers: 'mode' = live crimes or volunteers (on = its enabled switch, and off while the
-- police script sends no cuff and jail facts), 'switch' = the criminal tablet (on = its enabled switch), 'rules' = a
-- block of the rules both modes share (on = live crimes or volunteers on).
local REAL_PLAYER_PARTS = {
    liveCrime = 'mode',
    volunteer = 'mode',
    criminalTablet = 'switch',
    surrender = 'rules',
    staff = 'rules',
    antiFarm = 'rules',
}
-- What a real-player case can take part in: the switch of that name in its mode (each shipped false).
local TAKE_PART = { typeOfTheDay = true, goals = true, challenge = true, cash = true, items = true }

-- On the server, live crimes and volunteers are also off while the city's police script sends no cuff and jail facts
-- (CP.Integrations.realSuspectsBlocked; Admin UI -> Settings -> Features says why).
local function SuspectsBlocked()
    local I = CP.Integrations
    return I ~= nil and I.realSuspectsBlocked ~= nil and I.realSuspectsBlocked()
end

-- The one reader of Config.RealPlayers: one part as it is now (a setting changed in game included), never nil, and
-- whether it is on (see REAL_PLAYER_PARTS; every mode ships off). With no part: the whole section (the rules both
-- modes share) and whether live crimes or volunteers are on. An unknown part: {} and false.
---@param part? string 'liveCrime' | 'volunteer' | 'criminalTablet' | 'surrender' | 'staff' | 'antiFarm'
---@return table cfg, boolean on
function CP.RealPlayers(part)
    local all = type(Config) == 'table' and type(Config.RealPlayers) == 'table' and Config.RealPlayers or {}
    local kind = part ~= nil and REAL_PLAYER_PARTS[part] or nil
    if part == nil or kind == 'rules' then
        local lc, vo = all.liveCrime, all.volunteer
        local on = (type(lc) == 'table' and lc.enabled == true) or (type(vo) == 'table' and vo.enabled == true)
        on = on == true and not SuspectsBlocked()
        if part == nil then return all, on end
        return type(all[part]) == 'table' and all[part] or {}, on
    end
    local cfg = kind ~= nil and type(all[part]) == 'table' and all[part] or {}
    local on = kind ~= nil and cfg.enabled == true
    if on and kind == 'mode' then on = not SuspectsBlocked() end
    return cfg, on
end

-- Only whether a part of Config.RealPlayers is on (the second value of CP.RealPlayers).
---@param part? string
---@return boolean
function CP.RealPlayersOn(part)
    local _, on = CP.RealPlayers(part)
    return on == true
end

-- The mode of a run's real-player case: 'liveCrime' (run.live or realSuspect 'live'), 'volunteer' or nil.
function CP.RealPlayersMode(run)
    if type(run) ~= 'table' then return nil end
    if type(run.live) == 'table' or run.realSuspect == 'live' then return 'liveCrime' end
    if run.realSuspect == 'volunteer' then return 'volunteer' end
    return nil
end

-- Whether a run takes part in 'typeOfTheDay', 'goals', 'challenge', 'cash' or 'items': a live or volunteer case
-- only with that switch of its mode on; any other run: true.
function CP.RealPlayersTakePart(run, what)
    local mode = CP.RealPlayersMode(run)
    if not mode then return true end
    return TAKE_PART[what] == true and (CP.RealPlayers(mode))[what] == true
end

-- SQL to add to a WHERE that sums run rows for 'goals' or 'challenge': leaves out live-case rows (their mission_id
-- 'live_crime') and volunteer-case rows (their breakdown's realSuspect) while that switch of the mode is off ('' when
-- both are on). alias: the table alias with its dot ('r.') or ''.
function CP.RealPlayersRowFilter(what, alias)
    alias = alias or ''
    local sql = ''
    if (CP.RealPlayers('liveCrime'))[what] ~= true then
        sql = (' AND COALESCE(%smission_id, \'\') <> \'live_crime\''):format(alias)
    end
    if (CP.RealPlayers('volunteer'))[what] ~= true then
        sql = sql
            .. (' AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(%sbreakdown, \'$.realSuspect\')), \'\') <> \'volunteer\''):format(
                alias)
    end
    return sql
end

-- ============================================================================
--                                 RESTRICTIONS
-- ============================================================================

-- The kinds of the one restrictions list, in the order they register (modules/supervisor/restrictions.lua reads
-- them). Here so a module loaded before or after the list can register its kind.
CP.RestrictionKinds = CP.RestrictionKinds or { order = {}, byKey = {} }

-- One kind of restriction joins the list. def: { perm = { lift = key, extend = key }, maxHours, self (true: never
-- on one of the admin's own characters), on() -> shown, liftOn() -> the list offers Lift, list() -> rows,
-- audit = { actions, match(row, auditRow) } (who set it and why, for a kind that keeps neither), lift(ctx, p),
-- extend(ctx, p, hours) }.
-- A row: { citizenid, other? (the second player of a pair), untilAt, by?, byName?, reason?, dept? }.
---@param key string
---@param def table
function CP.Restriction(key, def)
    if type(key) ~= 'string' or type(def) ~= 'table' then return false end
    local R = CP.RestrictionKinds
    if not R.byKey[key] then R.order[#R.order + 1] = key end
    def.key = key
    R.byKey[key] = def
    return true
end
