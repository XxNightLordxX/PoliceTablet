-- CP.MissionCalls: the tablet's own call board (Dispatch): posting, claims, lapses, re-dispatch, staff calls,
-- the Dispatch screen data and call toasts. Nothing here ever reaches SC-Dispatch.

CP.MissionCalls = CP.MissionCalls or {}
local MC = CP.MissionCalls

local TAG = 'missioncalls'
local BOSS_KEY = 'weekly_boss'
local WATCH_TTL_S = 45               -- a Dispatch screen that has not asked for the calls this long is closed
local MUTE_CACHE_S = 30              -- cp_officers.calls_muted is read at most this often per officer
local FINISHED_KEEP = 20             -- ended calls kept in memory for the Recent list
local CLAIM_POLL_MS = 50             -- how often a waiting claim looks whether its window was decided
local CLAIM_WAIT_MS = 12000          -- a claim never waits longer than this for its answer
local COVERAGE_CACHE_S = 60          -- areaIndex() is rebuilt at most this often
local COUNT_RECHECK_S = 60           -- an hourly or daily count at its cap is read again this often
local AREA_SPREAD = 0.25             -- base weight of an area when a call is posted (plus the idle units near it)
local HOUR_S = 3600
local DAY_S = 86400

-- End reasons of a claimed run that reopen the call when nobody had reached the start (SPEC Dispatch).
local REDISPATCH = {
    quit = true,
    off_route = true,
    start_timeout = true,
    idle = true,
    real_call = true,
    force_recall = true,
}
local OUTCOME = { completed = 'completed', failed = 'failed', abandoned = 'abandoned' }
local VISIBLE = { open = true, claiming = true, claimed = true, lapsed = true }

local calls = {}       -- calls[id] = call (open, claiming, claimed, or lapsed while it is still shown)
local runToCall = {}   -- runToCall[runId] = call id
local finished = {}    -- ended calls, newest first: { code, typeLabel, claimedBy, outcome, at }
local states = {}      -- states[leaderSrc] = { at, sig, types = { [type] = TypeState } } (the eligibility cache)
local history = {}     -- history[citizenid][type] = the no-repeat history (filled once, cleared on a new row)
local watchers = {}    -- watchers[src] = os.time() of the last getMissionCalls (the Dispatch screen is open)
local muted = {}       -- muted[citizenid] = { v = bool, at = ts }
local counts = {}      -- counts[citizenid][key] = { n, at }: the hourly and daily counts of the accept checks
local wins = {}        -- wins[citizenid] = { ts, ... } calls won in the last hour (claim window tie-break)
local staffLast = {}   -- staffLast[issuer] = os.time() of the last call that issuer created
local coverage = nil   -- { at, index } (areaIndex cache)
local codeDay, codeSeq = nil, 0
local nextPostAt = 0
local tempId = 0
local claimSeq = 0
local dirty = false
local rng = nil

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.MissionCalls or {} end

local function Num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n then return d end
    return n
end

local function Rng()
    if not rng then
        local seed = os.time() ~ (GetGameTimer and GetGameTimer() or 0) ~ CP.U.hash(tostring({}))
        rng = CP.U.rng(seed & 0x7FFFFFFF)
    end
    return rng
end
MC._setRng = function(r) rng = r end

local function Safe(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        CP.err(TAG, 'call failed: %s', tostring(a))
        return false, nil
    end
    return true, a, b, c
end

local function Call(modName, fnName, ...)
    local m = CP[modName]
    return Safe(m and m[fnName], ...)
end

local function ToSrc(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n <= 0 then return nil end
    return n
end

local function GetOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    return CP.Access.getOfficer(src)
end

local function UnitOf(src)
    local _, unit = Call('Units', 'unitOf', src)
    return type(unit) == 'table' and unit or nil
end

local function UnitMembers(src)
    local _, list = Call('Units', 'members', src)
    if type(list) == 'table' and #list > 0 then return list end
    return { src }
end

local function IsLeader(src)
    if not UnitOf(src) then return true end
    local _, leader = Call('Units', 'isLeader', src)
    return leader == true
end

local function LeaderOf(src)
    local unit = UnitOf(src)
    return unit and ToSrc(unit.leader) or src
end

local function OperationLocked()
    local _, locked = Call('Operations', 'isLocked')
    return locked == true
end

local function IsOnCall(src)
    local _, on = Call('Calls', 'isOnCall', src)
    return on == true
end

local function InArena(src)
    local _, res = Call('Alerts', 'inArena', src)
    if res == true then return true end
    if GetPlayerRoutingBucket then
        local ok, bucket = pcall(GetPlayerRoutingBucket, src)
        if ok and tonumber(bucket) and tonumber(bucket) ~= 0 then return true end
    end
    return false
end

local function OnMission(src)
    local _, on = Call('Runs', 'isOnMission', src)
    if on then return true end
    local _, run = Call('Runs', 'getBySrc', src)
    return run ~= nil
end

local function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function TypeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return (t and t.label) or tostring(key)
end

local function AreaDef(key)
    if type(key) ~= 'string' then return nil end
    for _, a in ipairs(Cfg().areas or {}) do
        if type(a) == 'table' and a.key == key then return a end
    end
    return nil
end

local function AreaLabel(key)
    local a = AreaDef(key)
    return a and (a.label or a.key) or nil
end

local function Notify(src, kind, key, vars)
    if ToSrc(src) then Call('Tablet', 'notify', src, kind, key, vars) end
end

local function Push(src, topic, data)
    if ToSrc(src) then Call('Tablet', 'push', src, topic, data) end
end

local function Audit(src, action, target, old, new, reason)
    local _, admin = Call('Access', 'isAdmin', src)
    local actor = ToSrc(src) or 'console'
    Call('Admin', 'audit', actor, (admin or actor == 'console') and 'admin' or 'supervisor', 'operations', action,
        target, old, new, reason)
end

-- A type the server may post or staff may call: in Config.MissionCalls.types and Config.MissionTypes; never
-- Training or the Weekly Boss.
local function Callable(key)
    if type(key) ~= 'string' or key == 'training' or key == BOSS_KEY then return false end
    local t = Cfg().types
    return type(t) == 'table' and type(t[key]) == 'table' and Config.MissionTypes ~= nil
        and Config.MissionTypes[key] ~= nil
end

local function Priority(key)
    local t = Cfg().types and Cfg().types[key]
    local p = math.floor(Num(t and t.priority, 3))
    if p < 1 then p = 1 elseif p > 3 then p = 3 end
    return p
end

local function Exec(sql, params)
    CP.Migrations.ready()
    local ok, res = pcall(MySQL.update.await, sql, params)
    if not ok then
        CP.err(TAG, 'mission call write failed: %s', tostring(res))
        return nil
    end
    return tonumber(res) or 0
end

-- ============================================================================
--                                    AREAS
-- ============================================================================

-- The area a point belongs to: the Config.MissionCalls.areas entry whose centre is nearest.
function MC.areaOf(coords)
    if CP.Draw and CP.Draw._areaKeyOf then return CP.Draw._areaKeyOf(coords) end
    return nil
end

local function LocationArea(def, i)
    if CP.Draw and CP.Draw._locationArea then return CP.Draw._locationArea(def, i) end
    return nil
end

-- Missions and locations of every enabled mission per type and area (Admin UI → Testing coverage matrix).
function MC.areaIndex()
    local now = os.time()
    if coverage and now - coverage.at < COVERAGE_CACHE_S then return coverage.index end
    local index = {}
    for key in pairs(Config.MissionTypes or {}) do
        local byArea = {}
        local _, list = Call('Missions', 'byType', key)
        for _, def in ipairs(type(list) == 'table' and list or {}) do
            local _, enabled = Call('Missions', 'isEnabled', def.id)
            if enabled then
                local seen = {}
                for i = 1, #(def.locations or {}) do
                    local a = LocationArea(def, i)
                    if a then
                        local c = byArea[a] or { missions = 0, locations = 0 }
                        byArea[a] = c
                        c.locations = c.locations + 1
                        if not seen[a] then
                            seen[a] = true
                            c.missions = c.missions + 1
                        end
                    end
                end
            end
        end
        index[key] = byArea
    end
    coverage = { at = now, index = index }
    return index
end

-- ============================================================================
--                           ELIGIBILITY (THE CACHE)
-- ============================================================================
-- Per unit (keyed by its leader) and type: every accept check, the eligible pool after the no-repeat rule, and
-- its missions and locations per area. Built from in-memory state (CP.Runs keeps cooldowns and counts cached;
-- the no-repeat history is read once per officer and type and kept until a new row), reused for
-- Config.MissionCalls.eligibilityCache seconds, and cleared on row:settled, a participant leaving (cooldowns)
-- and duty changes. It never reads the database per call or per viewer.

local function HistoryOf(citizenid, missionType)
    local byType = history[citizenid] or {}
    history[citizenid] = byType
    local h = byType[missionType]
    if h == nil then
        local _, list = Call('Draw', 'history', citizenid, missionType)
        h = type(list) == 'table' and list or {}
        byType[missionType] = h
    end
    return h
end

local function Invalidate(citizenid)
    if citizenid then
        history[citizenid] = nil
        counts[citizenid] = nil
    end
    states = {}
end
MC._invalidate = Invalidate

-- The cap a count is checked against (Draw's accept checks): nil = no cap.
local function CountCap(key, missionType)
    local limits = Config.Limits or {}
    if key == 'hour' then return Num(limits.maxCompletionsHour, 8) end
    local n
    if missionType == nil then
        n = Num(limits.maxCompletionsDay, 0)
    else
        local t = Config.MissionTypes and Config.MissionTypes[missionType]
        n = Num(t and t.dailyLimit, 0)
    end
    return n > 0 and n or nil
end

-- A count kept until the officer's next settled row or duty change: it only grows with a new row, so a value
-- under its cap stays true; a value at the cap is read again every COUNT_RECHECK_S (the hour or day passes).
local function CachedCount(citizenid, key, missionType, fnName)
    local byKey = counts[citizenid] or {}
    counts[citizenid] = byKey
    local slot = key .. '|' .. tostring(missionType or '*')
    local c = byKey[slot]
    local now = os.time()
    local cap = CountCap(key, missionType)
    if c and not (cap and c.n >= cap and now - c.at >= COUNT_RECHECK_S) then return c.n end
    local _, n = Call('Runs', fnName, citizenid, missionType)
    n = math.floor(Num(n, 0))
    byKey[slot] = { n = n, at = now }
    return n
end

local COUNTS = {
    lastHour = function(citizenid) return CachedCount(citizenid, 'hour', nil, 'completionsLastHour') end,
    today = function(citizenid, missionType) return CachedCount(citizenid, 'day', missionType, 'completionsToday') end,
}

local function UnitInfo(src)
    local leader = LeaderOf(src)
    local srcs = UnitMembers(leader)
    local officers, cids, sig = {}, {}, {}
    for _, m in ipairs(srcs) do
        local o = GetOfficer(m)
        if o then
            officers[#officers + 1] = o
            cids[#cids + 1] = o.citizenid
        end
        sig[#sig + 1] = tostring(m)
    end
    return { leader = leader, srcs = srcs, officers = officers, cids = cids, sig = table.concat(sig, ',') }
end

-- The smallest unit size any mission of the type asks for beyond this size (the "Needs a unit of 2+" line).
local function MinUnit(missionType, size)
    local best
    local _, list = Call('Missions', 'byType', missionType)
    for _, def in ipairs(type(list) == 'table' and list or {}) do
        local m = math.floor(Num(def.minOfficers, 1))
        if m > size and (not best or m < best) then best = m end
    end
    return best
end

local function BuildTypeState(unit, missionType)
    local st = { ok = false, errKey = nil, board = 0, byArea = {}, minUnit = nil, cash = { 0, 0 }, points = 0 }
    local ok, allowed, errKey = Call('Draw', 'check', unit.leader, missionType, COUNTS)
    st.ok = ok and allowed == true
    st.errKey = st.ok and nil or (errKey or 'err.refused')
    local _, pool = Call('Draw', 'pool', missionType, unit.officers)
    pool = type(pool) == 'table' and pool or {}
    st.board = #pool
    if #pool > 1 and CP.Draw and CP.Draw.noRepeat then
        local hist = {}
        for i, cid in ipairs(unit.cids) do hist[i] = HistoryOf(cid, missionType) end
        local _, list = Call('Draw', 'noRepeat', pool, hist)
        if type(list) == 'table' then pool = list end
    end
    st.eligible = #pool
    for _, def in ipairs(pool) do
        local seen = {}
        for i = 1, #(def.locations or {}) do
            local a = LocationArea(def, i)
            if a then
                local c = st.byArea[a] or { missions = 0, locations = 0 }
                st.byArea[a] = c
                c.locations = c.locations + 1
                if not seen[a] then
                    seen[a] = true
                    c.missions = c.missions + 1
                end
            end
        end
    end
    if st.board == 0 then st.minUnit = MinUnit(missionType, #unit.srcs) end
    local okV, cash, points = Call('Draw', 'typeValues', missionType, unit.officers)
    if okV then
        st.cash = type(cash) == 'table' and cash or { 0, 0 }
        st.points = math.floor(Num(points, 0))
    end
    return st
end

-- The cached state of src's unit: { at, unit, types = { [type] = state } }.
local function UnitState(src, fresh)
    local unit = UnitInfo(src)
    local now = os.time()
    local ttl = Num(Cfg().eligibilityCache, 10)
    local e = states[unit.leader]
    if fresh or not e or e.sig ~= unit.sig or now - e.at >= ttl then
        e = { at = now, sig = unit.sig, unit = unit, types = {} }
        states[unit.leader] = e
    end
    return e
end

local function TypeState(e, missionType)
    local st = e.types[missionType]
    if not st then
        st = BuildTypeState(e.unit, missionType)
        e.types[missionType] = st
    end
    return st
end

-- The cached per-type state of src's unit (Config.MissionCalls.eligibilityCache seconds).
function MC.eligibility(src)
    local e = UnitState(src)
    for key in pairs(Cfg().types or {}) do
        if Callable(key) then TypeState(e, key) end
    end
    return e
end

-- The area a call names to this unit: only when its eligible pool there holds minMissionsPerArea missions
-- and minLocationsPerArea locations; nil = county-wide (drawn from the same pool as the Mission Board).
local function AreaForState(st, call)
    if not call.area then return nil end
    local c = st.byArea[call.area]
    local cfg = Cfg()
    if c and c.missions >= Num(cfg.minMissionsPerArea, 2) and c.locations >= Num(cfg.minLocationsPerArea, 3) then
        return call.area
    end
    return nil
end

-- The number of missions a claim of this call would draw from: the named area's, else the board's pool.
local function EffectivePool(st, area)
    if area then return st.byArea[area].missions end
    return st.board
end

function MC.areaFor(src, call)
    if type(call) ~= 'table' then call = calls[tonumber(call)] end
    if not call then return nil end
    return AreaForState(TypeState(UnitState(src), call.type), call)
end

-- ============================================================================
--                                  CALL RULES
-- ============================================================================

local function Contains(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- Distance of a unit's nearest member to the call's area centre (0 when the call names no area).
local function UnitDistance(srcs, call)
    local a = AreaDef(call.area)
    if not a then return 0 end
    local best = math.huge
    for _, m in ipairs(srcs) do
        local c = PedCoords(m)
        local d = c and CP.U.dist2d(c, a.center) or math.huge
        if d < best then best = d end
    end
    return best
end

-- The call's own rules for a unit (after every accept check): nil, or the error key and whether it is only
-- the priority window ('priority').
local function CallRule(call, unit, dist, now)
    for _, cid in ipairs(unit.cids) do
        if call.excluded[cid] then return 'err.mc_excluded' end
    end
    if call.staff and call.issuerCid and Contains(unit.cids, call.issuerCid) then return 'err.mc_own_call' end
    if call.pagedCid and now < (call.pagedUntil or 0) and not Contains(unit.cids, call.pagedCid) then
        return 'err.mc_paged'
    end
    if call.priorityUntil and now < call.priorityUntil and call.area and dist > Num(Cfg().priorityRadius, 1500.0) then
        return 'err.mc_priority', 'priority'
    end
    return nil
end

-- ok, info | false, errKey: can src's unit claim the call right now (every accept check, then the call's rules).
local function ClaimCheck(src, call, now)
    local officer, e = GetOfficer(src)
    if not officer then return false, e or 'err.not_police' end
    local okD, allowed, errKey = Call('Draw', 'check', src, call.type)
    if not okD then return false, 'err.internal' end
    if allowed ~= true then return false, errKey or 'err.refused' end
    local unit = UnitInfo(src)
    local dist = UnitDistance(unit.srcs, call)
    local rule = CallRule(call, unit, dist, now)
    if rule then return false, rule end
    local st = TypeState(UnitState(src, true), call.type)
    local area = AreaForState(st, call)
    if EffectivePool(st, area) <= 0 then return false, 'err.mc_no_missions_here' end
    return true, { unit = unit, dist = dist, area = area, officer = officer }
end

local function RecentClaims(cids, now)
    local n = 0
    for _, cid in ipairs(cids) do
        local list = wins[cid]
        for _, ts in ipairs(list or {}) do
            if now - ts < HOUR_S then n = n + 1 end
        end
    end
    return n
end

local function NoteWin(cids, now)
    for _, cid in ipairs(cids) do
        local list = wins[cid] or {}
        wins[cid] = list
        list[#list + 1] = now
        while #list > 0 and now - list[1] >= HOUR_S do table.remove(list, 1) end
    end
end

-- ============================================================================
--                                  THE CALLS
-- ============================================================================

local function MarkDirty() dirty = true end

local function NextCode(now)
    local _, day = Call('Schedule', 'dayKey', now)
    day = day or os.date('%Y-%m-%d', now)
    if codeDay ~= day then
        codeDay, codeSeq = day, 0
        local _, start = Call('Schedule', 'dayStart', now)
        if tonumber(start) then
            CP.Migrations.ready()
            local ok, n = pcall(MySQL.scalar.await,
                'SELECT COUNT(*) AS n FROM cp_mission_calls WHERE created_at >= FROM_UNIXTIME(?)', { tonumber(start) })
            if ok then codeSeq = math.floor(CP.U.num(n)) end
        end
    end
    codeSeq = codeSeq + 1
    return ('MC-%04d'):format(codeSeq % 10000)
end

local function NoteFinished(call, outcome, now)
    table.insert(finished, 1, {
        code = call.code,
        typeLabel = TypeLabel(call.type),
        claimedBy = call.winner and (call.winner.callsign or call.winner.name) or nil,
        outcome = outcome,
        at = now,
    })
    while #finished > FINISHED_KEEP do table.remove(finished) end
end

-- A new call: the row, the record and the toasts. opts: staff, issuer (citizenid or 'console'), issuerCid,
-- pagedSrc, pagedCid, pageTime, priorityUntil, units (idle units for the toasts).
local function NewCall(missionType, area, opts)
    opts = opts or {}
    local cfg = Cfg()
    local now = os.time()
    local code = NextCode(now)
    local priority = Priority(missionType)
    -- NULL for the missing values (a nil would leave a hole in the parameter list)
    local cols = { code, missionType, area, priority, opts.issuer, opts.pagedCid }
    local values, params = {}, {}
    for i = 1, 6 do
        if cols[i] == nil then
            values[i] = 'NULL'
        else
            values[i] = '?'
            params[#params + 1] = cols[i]
        end
    end
    CP.Migrations.ready()
    local okI, id = pcall(
        MySQL.insert.await,
        ([[
        INSERT INTO cp_mission_calls (code, mission_type, area, priority, created_by, paged_to, status)
        VALUES (%s, 'open')
    ]]):format(table.concat(values, ', ')),
        params
    )
    local err = not okI and id or nil
    id = okI and math.tointeger(tonumber(id) or -1) or nil
    if not id or id <= 0 then
        CP.err(TAG, 'the mission call row could not be written: %s', tostring(err or id))
        tempId = tempId - 1
        id = tempId
    end
    local titles = math.max(1, math.floor(Num(cfg.titles and cfg.titles[missionType], 1)))
    local call = {
        id = id,
        code = code,
        type = missionType,
        area = area,
        priority = priority,
        titleIdx = Rng():int(1, titles),
        createdAt = now,
        offerEnds = now + math.floor(Num(cfg.offerTime, 180)),
        status = 'open',
        staff = opts.staff == true,
        issuer = opts.issuer,
        issuerCid = opts.issuerCid,
        pagedCid = opts.pagedCid,
        pagedUntil = opts.pagedCid and (now + math.floor(Num(cfg.pageTime, 30))) or nil,
        priorityUntil = opts.priorityUntil,
        redispatched = false,
        reopened = false,
        excluded = {},
        lostBy = {},
        claimants = 0,
    }
    calls[id] = call
    MarkDirty()
    CP.log(TAG, 'posted %s (%s, %s, %s)', code, missionType, tostring(area), call.staff and 'staff' or 'server')
    return call
end

local function ToastPayload(call)
    return {
        id = call.id,
        code = call.code,
        typeLabel = TypeLabel(call.type),
        priority = call.priority,
        areaLabel = AreaLabel(call.area),
        titleKey = ('mc.title.%s.%d'):format(call.type, call.titleIdx),
    }
end

-- cp_officers.calls_muted (saved by the profile screen), cached per officer.
local function IsMuted(citizenid)
    local now = os.time()
    local m = muted[citizenid]
    if m and now - m.at < MUTE_CACHE_S then return m.v end
    CP.Migrations.ready()
    local ok, v = pcall(MySQL.scalar.await, 'SELECT calls_muted FROM cp_officers WHERE citizenid = ?', { citizenid })
    local val = ok and CP.U.truthy(v) or false
    muted[citizenid] = { v = val, at = now }
    return val
end
MC._forgetMuted = function(citizenid) muted[citizenid] = nil end

-- The toast and tone for every member of the given idle units who could claim the call and has not muted calls
-- (skipCid: a unit with that member already had it, e.g. the paged unit).
local function Toast(call, units, skipCid)
    local payload = ToastPayload(call)
    local now = os.time()
    for _, u in ipairs(units) do
        local st = TypeState(UnitState(u.leader), call.type)
        local area = AreaForState(st, call)
        local rule, soft = CallRule(call, u, UnitDistance(u.srcs, call), now)
        local skip = skipCid ~= nil and Contains(u.cids, skipCid)
        if not skip and st.ok and EffectivePool(st, area) > 0 and (not rule or soft == 'priority') then
            for i, m in ipairs(u.srcs) do
                local cid = u.cids[i]
                if cid and not IsMuted(cid) and not IsOnCall(m) then
                    TriggerClientEvent(CP.e('client:missionCall'), m, payload)
                end
            end
        end
    end
end

-- A paged call whose pageTime is over is offered to everyone: the other idle units get the toast then.
local function ToastPageEnded(units, now)
    for _, call in pairs(calls) do
        if call.pagedCid and not call.pageToasted and now >= (call.pagedUntil or 0) then
            call.pageToasted = true
            if call.status == 'open' and not call.window then Toast(call, units, call.pagedCid) end
        end
    end
end

local function OpenCalls()
    local out = {}
    for _, call in pairs(calls) do
        if call.status == 'open' or call.status == 'claiming' then out[#out + 1] = call end
    end
    return out
end

-- Idle units: solo officers and units whose members are all on duty, not suspended, not on a run, not
-- responding to a real call and not in Crimson-Arena. Each has leader, srcs, officers, cids.
local function IdleUnits()
    local out, seen = {}, {}
    local players = GetPlayers() or {}
    table.sort(players, function(a, b) return (tonumber(a) or 0) < (tonumber(b) or 0) end)
    for _, id in ipairs(players) do
        local src = ToSrc(id)
        if src and GetOfficer(src) then
            local leader = LeaderOf(src)
            if not seen[leader] then
                seen[leader] = true
                local unit = UnitInfo(leader)
                local idle = #unit.officers == #unit.srcs and #unit.srcs > 0
                local u = UnitOf(leader)
                if u and u.locked then idle = false end
                for _, m in ipairs(unit.srcs) do
                    if not idle then break end
                    if OnMission(m) or IsOnCall(m) or InArena(m) then idle = false end
                end
                if idle then out[#out + 1] = unit end
            end
        end
    end
    return out
end
MC._idleUnits = IdleUnits

local function WeightedPick(items, weightOf)
    local total = 0
    for _, it in ipairs(items) do total = total + math.max(0, weightOf(it)) end
    if total <= 0 then return nil end
    local roll = Rng():next() * total
    for _, it in ipairs(items) do
        roll = roll - math.max(0, weightOf(it))
        if roll < 0 then return it end
    end
    return items[#items]
end

-- The server's own call: a weighted type that an idle unit could claim (not at its run cap), and an area
-- weighted towards the idle units that no open call of that type already names.
local function PostServerCall(units, now)
    local cfg = Cfg()
    local keys = {}
    for key in pairs(cfg.types or {}) do if Callable(key) then keys[#keys + 1] = key end end
    table.sort(keys)
    local open = OpenCalls()
    local viable = {}
    for _, key in ipairs(keys) do
        local _, capOk = Call('Runs', 'capsOk', key)
        if capOk ~= false then
            local claimers = {}
            for _, u in ipairs(units) do
                local st = TypeState(UnitState(u.leader), key)
                if st.ok and st.board > 0 then claimers[#claimers + 1] = u end
            end
            if #claimers > 0 then viable[#viable + 1] = { key = key, units = claimers } end
        end
    end
    local tries = #viable
    while tries > 0 do
        tries = tries - 1
        local pick = WeightedPick(viable, function(v) return Num(cfg.types[v.key].weight, 1) end)
        if not pick then return false end
        local areas = {}
        for _, a in ipairs(cfg.areas or {}) do
            local taken = false
            for _, c in ipairs(open) do
                if c.type == pick.key and c.area == a.key then taken = true end
            end
            if not taken and type(a.key) == 'string' then areas[#areas + 1] = a end
        end
        local area = nil
        if #(cfg.areas or {}) > 0 then
            local index = MC.areaIndex()[pick.key] or {}
            local km = Num(cfg.countyWeightKm, 2.0)
            area = WeightedPick(areas, function(a)
                local w = AREA_SPREAD
                for _, u in ipairs(pick.units) do
                    local d = UnitDistance(u.srcs, { area = a.key })
                    if d < math.huge then w = w + 1 / (1 + d / 1000 / km) end
                end
                if not (index[a.key] and index[a.key].missions > 0) then w = w * 0.1 end
                return w
            end)
        end
        if #(cfg.areas or {}) == 0 or area then
            local areaKey = area and area.key or nil
            local priorityUntil = nil
            if areaKey then
                for _, u in ipairs(units) do
                    if UnitDistance(u.srcs, { area = areaKey }) <= Num(cfg.priorityRadius, 1500.0) then
                        priorityUntil = now + math.floor(Num(cfg.priorityWindow, 15))
                        break
                    end
                end
            end
            local call = NewCall(pick.key, areaKey, { priorityUntil = priorityUntil })
            Toast(call, units)
            return true
        end
        for i, v in ipairs(viable) do
            if v == pick then table.remove(viable, i) break end
        end
    end
    return false
end

-- ============================================================================
--                                 CALL ENDINGS
-- ============================================================================

local function Lapse(call, now)
    call.status = 'lapsed'
    call.lapsedAt = now
    if call.id > 0 then
        Exec('UPDATE cp_mission_calls SET status = \'lapsed\', closed_at = NOW() WHERE id = ? AND status = \'open\'',
            { call.id })
    end
    NoteFinished(call, 'lapsed', now)
    MarkDirty()
end

local function Withdraw(call, reason, now)
    call.status = 'withdrawn'
    calls[call.id] = nil
    if call.id > 0 then
        Exec([[UPDATE cp_mission_calls SET status = 'withdrawn', reason = ?, closed_at = NOW()
            WHERE id = ? AND status = 'open']], { CP.U.clip(tostring(reason or ''), 255), call.id })
    end
    NoteFinished(call, 'withdrawn', now)
    MarkDirty()
end

local function WithdrawAll(reason)
    local now = os.time()
    for _, call in pairs(calls) do
        if call.status == 'open' and not call.window then Withdraw(call, reason, now) end
    end
end

-- Lapsed calls leave after lapsedShown seconds; open ones lapse at the end of their offer; claimed ones stay
-- on the board for lapsedShown seconds after the claim (their run ends them).
local function Expire(now)
    local shown = Num(Cfg().lapsedShown, 10)
    for id, call in pairs(calls) do
        if call.status == 'open' and not call.window and now >= call.offerEnds then
            Lapse(call, now)
        elseif call.status == 'lapsed' and now - (call.lapsedAt or now) >= shown then
            calls[id] = nil
            MarkDirty()
        end
    end
end

local function Close(call, outcome, now)
    call.status = 'closed'
    calls[call.id] = nil
    if call.id > 0 then
        Exec([[UPDATE cp_mission_calls SET status = 'closed', outcome = ?, closed_at = NOW()
            WHERE id = ? AND status = 'claimed']], { outcome, call.id })
    end
    NoteFinished(call, outcome, now)
    MarkDirty()
end

-- A claimed run abandoned before anyone reached the start: the call opens once more for reopen.time,
-- tagged Re-dispatched; members of the old claim can't claim it again.
local function Reopen(call, now)
    local cfg = Cfg()
    call.status = 'open'
    call.redispatched = true
    call.reopened = true
    call.offerEnds = now + math.floor(Num(cfg.reopen and cfg.reopen.time, 120))
    call.priorityUntil = nil
    call.pagedCid, call.pagedUntil = nil, nil
    for _, cid in ipairs(call.winner and call.winner.cids or {}) do call.excluded[cid] = true end
    call.runId = nil
    call.window = nil
    call.winner = nil
    call.claimedAt = nil
    if call.id > 0 then
        Exec([[UPDATE cp_mission_calls SET status = 'open', reopened = 1, outcome = 'reopened', claimed_by = NULL,
            run_uuid = NULL WHERE id = ? AND status = 'claimed']], { call.id })
    end
    MarkDirty()
    CP.log(TAG, '%s re-dispatched', call.code)
end

local function OnRunEnded(run, state, endReason)
    if type(run) ~= 'table' then return end
    local id = runToCall[run.id]
    if not id then return end
    runToCall[run.id] = nil
    local call = calls[id]
    if not call or call.status ~= 'claimed' then return end
    local now = os.time()
    local arrived = call.arrived == true
    for _, p in pairs(run.participants or {}) do
        if p.arrived then arrived = true end
    end
    local cfg = Cfg()
    local reopenOn = not (cfg.reopen and cfg.reopen.enabled == false)
    if not arrived and REDISPATCH[endReason] and reopenOn and not call.reopened then
        NoteFinished(call, 'reopened', now)
        return Reopen(call, now)
    end
    Close(call, OUTCOME[state] or 'abandoned', now)
end

local function OnRunArrived(run)
    local id = type(run) == 'table' and runToCall[run.id]
    local call = id and calls[id]
    if call then call.arrived = true end
end

-- ============================================================================
--                               THE CLAIM WINDOW
-- ============================================================================

local TryNext

-- Which rule decided between the winner and another claimant: 'distance', 'recent' or 'first'.
local function RuleBetween(w, l)
    if math.floor(w.dist) ~= math.floor(l.dist) then return 'distance' end
    if w.recent ~= l.recent then return 'recent' end
    return 'first'
end

local function TellLosers(call, winner)
    local by = call.winner or {}
    for _, c in ipairs(call.queue or {}) do
        if c ~= winner and not c.result then
            local rule = RuleBetween(winner, c)
            call.lostBy[c.src] = rule
            c.result = { false, 'err.mc_taken_by' }
            Notify(c.src, 'warning', 'mc.toast.lost_' .. rule, {
                code = call.code,
                callsign = by.callsign or by.name or '?',
                department = by.departmentShort or '',
            })
        end
    end
end

-- The winner's accept finished (at once, or after the unit's ready check).
local function Accepted(call, c, ok, data)
    local now = os.time()
    if ok and type(data) == 'table' and data.runId then
        call.status = 'claimed'
        call.runId = data.runId
        call.claimedAt = now
        runToCall[data.runId] = call.id
        NoteWin(c.unit.cids, now)
        if call.id > 0 then Exec('UPDATE cp_mission_calls SET run_uuid = ? WHERE id = ?', { data.runId, call.id }) end
        if not c.result then c.result = { true, { runId = data.runId, code = call.code } } end
        for _, m in ipairs(c.unit.srcs) do
            Notify(m, 'success', 'mc.toast.won', {
                code = call.code,
                distance = data.distance and ('%.1f'):format(data.distance / 1000) or '?',
                target = data.targetS or '?',
            })
        end
        TellLosers(call, c)
        call.queue = nil
        call.window = nil
        MarkDirty()
        CP.log(TAG, '%s claimed by %s (run %s)', call.code, tostring(c.src), tostring(data.runId))
        return
    end
    -- declined, timed out or refused: back to open for the time it had left, and the next claimant
    local errKey = type(data) == 'string' and data or 'err.run_create_failed'
    call.status = 'open'
    call.offerEnds = call.offerEnds + math.max(0, now - (call.claimingSince or now))
    call.claimingSince = nil
    call.winner = nil
    for _, cid in ipairs(c.unit.cids) do call.excluded[cid] = true end
    if call.id > 0 then
        Exec([[UPDATE cp_mission_calls SET status = 'open', claimed_by = NULL, claimed_at = NULL
            WHERE id = ? AND status = 'claimed']], { call.id })
    end
    if c.result then
        Notify(c.src, 'error', errKey)
    else
        c.result = { false, errKey }
    end
    MarkDirty()
    CP.log(TAG, '%s: the claim of %s did not start a run (%s)', call.code, tostring(c.src), errKey)
    TryNext(call)
end

TryNext = function(call)
    while call.queue and #call.queue > 0 do
        local c = table.remove(call.queue, 1)
        local skip = false
        for _, cid in ipairs(c.unit.cids) do if call.excluded[cid] then skip = true end end
        if skip then
            c.result = c.result or { false, 'err.mc_excluded' }
        else
            -- claim before act: the row moves from open to claimed exactly once
            local claimed = true
            if call.id > 0 then
                local n = Exec([[UPDATE cp_mission_calls SET status = 'claimed', claimed_by = ?, claimants = ?,
                    claimed_at = NOW() WHERE id = ? AND status = 'open']],
                    { c.officer.citizenid, call.claimants, call.id })
                claimed = n == nil or n > 0
            end
            if not claimed then
                c.result = c.result or { false, 'err.mc_taken_by' }
            else
                local o = c.officer
                call.lostBy[c.src] = nil
                call.status = 'claiming'
                call.claimingSince = os.time()
                call.winner = {
                    src = c.src,
                    cids = c.unit.cids,
                    name = o.name,
                    callsign = o.callsign,
                    departmentShort = o.departmentShort,
                }
                MarkDirty()
                -- a claimant that lost the window gets its turn after the winner's unit declined
                if c.result then Notify(c.src, 'info', 'mc.toast.next_in_line', { code = call.code }) end
                local okA, ok, data = Call('Draw', 'accept', c.src, call.type, {
                    area = c.area,
                    missionCall = {
                        id = call.id > 0 and call.id or nil,
                        code = call.code,
                        area = c.area,
                        staff = call.staff,
                    },
                    onDone = function(ok2, data2) Accepted(call, c, ok2, data2) end,
                })
                if not okA then ok, data = false, 'err.internal' end
                if ok and type(data) == 'table' and data.pending then
                    local readyS = math.floor(Num(Config.Units and Config.Units.readyTimeout, 20))
                    call.readyUntil = os.time() + readyS
                    if not c.result then c.result = { true, { pending = true, code = call.code } } end
                    TellLosers(call, c)
                    MarkDirty()
                    return
                end
                return Accepted(call, c, ok, data)
            end
        end
    end
    call.queue = nil
    call.window = nil
    MarkDirty()
end

-- Rank the claims of the window: nearest member to the area's centre, then fewer calls won in the last hour,
-- then the earliest claim.
local function Resolve(call)
    local w = call.window
    if not w or w.resolved then return end
    w.resolved = true
    table.sort(w.claims, function(a, b)
        local da, db = math.floor(a.dist), math.floor(b.dist)
        if da ~= db then return da < db end
        if a.recent ~= b.recent then return a.recent < b.recent end
        if a.atMs ~= b.atMs then return a.atMs < b.atMs end
        return a.seq < b.seq
    end)
    call.claimants = #w.claims
    call.queue = {}
    for i, c in ipairs(w.claims) do call.queue[i] = c end
    TryNext(call)
end
MC._resolve = Resolve

function MC.claim(src, callId)
    src = ToSrc(src)
    local cfg = Cfg()
    if not src then return false, 'err.not_in_game' end
    if cfg.enabled == false then return false, 'err.mc_disabled' end
    if not CP.Net.rateOk(src, 'missioncalls:claim', 1, math.floor(Num(cfg.claimRate, 1500))) then
        return false, 'err.rate_limited'
    end
    local call = calls[math.tointeger(tonumber(callId) or 0)]
    if not call or not VISIBLE[call.status] or call.status == 'lapsed' then return false, 'err.mc_gone' end
    if call.status == 'claiming' then return false, 'err.mc_claiming' end
    if call.status == 'claimed' then return false, 'err.mc_taken_by' end
    local now = os.time()
    if now >= call.offerEnds and not call.window then return false, 'err.mc_gone' end
    local ok, info = ClaimCheck(src, call, now)
    if not ok then return false, info end

    local w = call.window
    if w and w.resolved then return false, 'err.mc_claiming' end
    local entry
    for _, c in ipairs(w and w.claims or {}) do
        if c.unit.leader == info.unit.leader then entry = c end
    end
    if not entry then
        claimSeq = claimSeq + 1
        entry = {
            src = src,
            unit = info.unit,
            officer = info.officer,
            area = info.area,
            dist = info.dist,
            recent = RecentClaims(info.unit.cids, now),
            atMs = GetGameTimer(),
            seq = claimSeq,
        }
        if not w then
            w = { firstMs = entry.atMs, claims = {} }
            call.window = w
            local windowMs = math.floor(Num(cfg.claimWindowMs, 1500))
            w.claims[1] = entry
            MarkDirty()
            if windowMs <= 0 then
                Resolve(call)
            else
                SetTimeout(windowMs, function() Resolve(call) end)
            end
        else
            w.claims[#w.claims + 1] = entry
        end
    end
    local waited = 0
    while not entry.result and waited < CLAIM_WAIT_MS do
        Wait(CLAIM_POLL_MS)
        waited = waited + CLAIM_POLL_MS
    end
    if not entry.result then return false, 'err.timeout' end
    return entry.result[1], entry.result[2]
end

-- ============================================================================
--                                 STAFF CALLS
-- ============================================================================

local function StaffIssuer(src)
    if not ToSrc(src) then return 'console', nil end
    local o = GetOfficer(src)
    if o then return o.citizenid, o.citizenid end
    local _, info = Call('Qbx', 'getInfo', src)
    local cid = type(info) == 'table' and info.citizenid or nil
    return cid or ('src:' .. src), cid
end

local function ParseArea(area)
    if area == nil or area == '' or area == 'county' then return true, nil end
    if AreaDef(area) then return true, area end
    return false
end

function MC.create(src, typeKey, area)
    if Cfg().enabled == false then return false, 'err.mc_disabled' end
    if not Callable(typeKey) then return false, 'err.mc_type_not_callable' end
    local okA, areaKey = ParseArea(area)
    if not okA then return false, 'err.mc_unknown_area' end
    if OperationLocked() then return false, 'err.operation_locked' end
    local issuer, issuerCid = StaffIssuer(src)
    local now = os.time()
    local last = staffLast[issuer]
    if last and now - last < Num(Cfg().staffCooldown, 120) then return false, 'err.mc_staff_cooldown' end
    staffLast[issuer] = now
    local call = NewCall(typeKey, areaKey, { staff = true, issuer = issuer, issuerCid = issuerCid })
    Toast(call, IdleUnits())
    Audit(src, 'mcCreate', call.code, nil, ('%s %s'):format(typeKey, areaKey or 'county'), nil)
    return true, { id = call.id, code = call.code }
end

function MC.page(src, typeKey, area, leaderSrc)
    if Cfg().enabled == false then return false, 'err.mc_disabled' end
    if not Callable(typeKey) then return false, 'err.mc_type_not_callable' end
    local okA, areaKey = ParseArea(area)
    if not okA then return false, 'err.mc_unknown_area' end
    if OperationLocked() then return false, 'err.operation_locked' end
    local target = ToSrc(leaderSrc)
    local leaderO = target and GetOfficer(target)
    if not leaderO then return false, 'err.mc_page_target' end
    if not IsLeader(target) then return false, 'err.mc_page_not_leader' end
    local unit = UnitInfo(target)
    local issuer, issuerCid = StaffIssuer(src)
    if ToSrc(src) and (Contains(unit.srcs, ToSrc(src)) or (issuerCid and Contains(unit.cids, issuerCid))) then
        return false, 'err.mc_page_self'
    end
    local call = NewCall(typeKey, areaKey, {
        staff = true,
        issuer = issuer,
        issuerCid = issuerCid,
        pagedCid = leaderO.citizenid,
    })
    local payload = ToastPayload(call)
    payload.paged = true
    for _, m in ipairs(unit.srcs) do TriggerClientEvent(CP.e('client:missionCall'), m, payload) end
    Audit(src, 'mcPage', call.code, nil, ('%s %s -> %s'):format(typeKey, areaKey or 'county', leaderO.citizenid), nil)
    return true, { id = call.id, code = call.code }
end

function MC.withdraw(src, id, reason)
    local call = calls[math.tointeger(tonumber(id) or 0)]
    if not call or call.status ~= 'open' or call.window then return false, 'err.mc_not_open' end
    if type(reason) ~= 'string' or CP.U.trim(reason) == '' then return false, 'err.reason_required' end
    reason = CP.U.clip(CP.U.trim(reason), 255)
    Withdraw(call, reason, os.time())
    Audit(src, 'mcWithdraw', call.code, 'open', 'withdrawn', reason)
    return true
end

-- ============================================================================
--                              THE DISPATCH VIEW
-- ============================================================================

local function Viewer(src)
    local officer = GetOfficer(src)
    if not officer then return nil end
    local e = UnitState(src)
    return {
        src = src,
        officer = officer,
        isLeader = IsLeader(src),
        state = e,
        unit = e.unit,
        coords = PedCoords(src),
        now = os.time(),
    }
end

local function Distance(v, st, area)
    local from = v.coords
    if not from then return nil end
    if area then
        local a = AreaDef(area)
        return a and math.floor(CP.U.dist2d(from, a.center) + 0.5) or nil
    end
    local best
    for key, c in pairs(st.byArea) do
        local a = AreaDef(key)
        if a and c.missions > 0 then
            local d = CP.U.dist2d(from, a.center)
            if not best or d < best then best = d end
        end
    end
    return best and math.floor(best + 0.5) or nil
end

local function Card(call, v, tod)
    local cfg = Cfg()
    local now = v.now
    local st = TypeState(v.state, call.type)
    local area = AreaForState(st, call)
    local pool = EffectivePool(st, area)
    local size = #v.unit.srcs
    local rr = cfg.rapidResponse or {}
    local card = {
        id = call.id,
        code = call.code,
        type = call.type,
        typeLabel = TypeLabel(call.type),
        titleKey = ('mc.title.%s.%d'):format(call.type, call.titleIdx),
        priority = call.priority,
        area = area and { key = area, label = AreaLabel(area) } or nil,
        distance = Distance(v, st, area),
        ageS = math.max(0, now - call.createdAt),
        offerEndsIn = math.max(0, call.offerEnds - now),
        staff = call.staff,
        crew = pool > 0 and (size > 1 and 'unit' or 'solo') or 'none',
        minUnit = pool <= 0 and st.minUnit or nil,
        cash = st.cash,
        points = st.points,
        rapidPoints = call.staff and 0 or math.floor(st.points * Num(rr.pctOfP, 0.10) + 0.5),
        typeOfTheDay = tod == call.type,
        redispatched = call.redispatched,
        paged = call.pagedCid ~= nil,
        status = 'ready',
        priorityEndsIn = nil,
        locked = nil,
        claimedBy = nil,
        claiming = nil,
        lostBy = call.lostBy[v.src],
    }
    local w = call.winner
    if call.status == 'lapsed' then
        card.status = 'lapsed'
        card.offerEndsIn = 0
    elseif call.status == 'claimed' then
        card.status = 'claimed'
        card.claimedBy = w and { callsign = w.callsign or w.name, departmentShort = w.departmentShort or '' } or nil
    elseif call.status == 'claiming' then
        card.status = 'claiming'
        card.claiming = w
                and {
                    callsign = w.callsign or w.name,
                    expiresIn = math.max(0, (call.readyUntil or now) - now),
                }
            or nil
    elseif not v.isLeader then
        card.status = 'locked'
        card.locked = { reason = CP.L('mc.locked.not_leader') }
    elseif not st.ok then
        card.status = 'locked'
        card.locked = { reason = CP.L(st.errKey or 'err.refused') }
    elseif pool <= 0 then
        card.status = 'locked'
        card.locked = { reason = CP.L('mc.locked.no_missions', { type = card.typeLabel }) }
    else
        local rule, soft = CallRule(call, v.unit, UnitDistance(v.unit.srcs, call), now)
        if soft == 'priority' then
            card.status = 'priority'
            card.priorityEndsIn = math.max(0, call.priorityUntil - now)
        elseif rule then
            card.status = 'locked'
            card.locked = { reason = CP.L(rule) }
        end
    end
    return card
end

local function SortCards(list)
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.ageS ~= b.ageS then return a.ageS > b.ageS end
        return a.id < b.id
    end)
    return list
end

local function Visible(call, now)
    if not VISIBLE[call.status] then return false end
    if call.status == 'claimed' then return now - (call.claimedAt or now) < Num(Cfg().lapsedShown, 10) end
    return true
end

local function Recent(now)
    local out = {}
    local shown = math.floor(Num(Cfg().recentShown, 5))
    local list = {}
    for _, call in pairs(calls) do
        if call.status == 'claimed' then
            list[#list + 1] = {
                code = call.code,
                typeLabel = TypeLabel(call.type),
                claimedBy = call.winner and (call.winner.callsign or call.winner.name) or nil,
                outcome = 'in_progress',
                at = call.claimedAt or now,
            }
        end
    end
    for _, f in ipairs(finished) do list[#list + 1] = f end
    table.sort(list, function(a, b) return a.at > b.at end)
    for i = 1, math.min(shown, #list) do out[i] = list[i] end
    return out
end

-- DispatchView for src (built only for officers with the tablet open: the getMissionCalls callback and the
-- 'calls' push to watchers).
function MC.list(src)
    local v = Viewer(src)
    if not v then return nil end
    local _, tod = Call('Events', 'typeOfTheDay')
    local cards = {}
    for _, call in pairs(calls) do
        if Visible(call, v.now) then cards[#cards + 1] = Card(call, v, tod) end
    end
    local _, run = Call('Runs', 'getBySrc', src)
    local onCall = false
    for _, m in ipairs(v.unit.srcs) do if IsOnCall(m) then onCall = true end end
    local operation = nil
    if OperationLocked() then
        local _, op = Call('Operations', 'active')
        operation = { missionLabel = type(op) == 'table' and op.missionLabel or '' }
    end
    local realCalls = nil
    if Cfg().realCallStrip ~= false then
        local _, summary = Call('Dispatch', 'realCallSummary')
        realCalls = type(summary) == 'table' and summary or nil
    end
    return {
        calls = SortCards(cards),
        unit = { size = #v.unit.srcs, isLeader = v.isLeader },
        activeRunId = type(run) == 'table' and run.id or nil,
        operation = operation,
        onCall = onCall,
        realCalls = realCalls,
        serverTime = v.now,
        recent = Recent(v.now),
    }
end

-- The calls src's unit could claim right now (the nav badge, Home and the board's "n mission calls open").
function MC.claimableCount(src)
    if Cfg().enabled == false then return 0 end
    local v = Viewer(src)
    if not v or not v.isLeader then return 0 end
    local n = 0
    for _, call in pairs(calls) do
        if call.status == 'open' and not call.window then
            local card = Card(call, v, nil)
            if card.status == 'ready' then n = n + 1 end
        end
    end
    return n
end

local function PushAll()
    if not dirty then return end
    dirty = false
    local now = os.time()
    for src, at in pairs(watchers) do
        if now - at > WATCH_TTL_S or not GetPlayerName(src) then
            watchers[src] = nil
        else
            local okV, view = pcall(MC.list, src)
            if okV and view then Push(src, 'calls', view) end
        end
    end
end
MC._pushAll = PushAll

-- ============================================================================
--                               SUPERVISOR VIEWS
-- ============================================================================

local function SupToday(src)
    local _, start = Call('Schedule', 'dayStart', os.time())
    start = tonumber(start) or (os.time() - DAY_S)
    CP.Migrations.ready()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT c.id, c.code, c.mission_type, c.area, c.status, c.outcome, c.claimed_by, c.claimants,
               UNIX_TIMESTAMP(c.created_at) AS created_ts, UNIX_TIMESTAMP(c.claimed_at) AS claimed_ts,
               o.callsign, o.display_name, o.department
        FROM cp_mission_calls c LEFT JOIN cp_officers o ON o.citizenid = c.claimed_by
        WHERE c.created_at >= FROM_UNIXTIME(?) ORDER BY c.id DESC LIMIT 100
    ]], { start })
    if not ok then
        CP.err(TAG, 'the calls of today could not be read: %s', tostring(rows))
        return {}
    end
    local resp = {}
    local okR, rrows = pcall(MySQL.query.await, [[
        SELECT mission_call_id, SUM(response_s) AS rs, COUNT(response_s) AS rc FROM cp_mission_runs
        WHERE mission_call_id IS NOT NULL AND created_at >= FROM_UNIXTIME(?) GROUP BY mission_call_id
    ]], { start })
    if okR and type(rrows) == 'table' then
        for _, r in ipairs(rrows) do
            local rc = CP.U.num(r.rc)
            if rc > 0 then resp[math.tointeger(CP.U.num(r.mission_call_id))] = math.floor(CP.U.num(r.rs) / rc + 0.5) end
        end
    end
    local _, admin = Call('Access', 'isAdmin', src)
    local viewer = GetOfficer(src)
    local dept = not admin and viewer and viewer.department or nil
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if not dept or r.claimed_by == nil or r.department == dept then
            local created, claimed = CP.U.num(r.created_ts), CP.U.num(r.claimed_ts)
            out[#out + 1] = {
                code = r.code,
                type = r.mission_type,
                area = r.area,
                status = r.status,
                claimedBy = r.claimed_by and (r.callsign or r.display_name or r.claimed_by) or nil,
                claimants = math.floor(CP.U.num(r.claimants)),
                claimS = claimed > 0 and math.max(0, math.floor(claimed - created)) or nil,
                responseS = resp[math.tointeger(CP.U.num(r.id))],
                outcome = r.outcome,
            }
        end
    end
    return out
end

function MC.supView(src)
    local v = Viewer(src)
    local open = {}
    local now = os.time()
    local _, tod = Call('Events', 'typeOfTheDay')
    for _, call in pairs(calls) do
        if call.status == 'open' or call.status == 'claiming' then
            if v then
                -- staff see the call's own area, not the one it names to them as an officer
                local card = Card(call, v, tod)
                card.area = call.area and { key = call.area, label = AreaLabel(call.area) } or nil
                open[#open + 1] = card
            else
                open[#open + 1] = {
                    id = call.id,
                    code = call.code,
                    type = call.type,
                    typeLabel = TypeLabel(call.type),
                    titleKey = ('mc.title.%s.%d'):format(call.type, call.titleIdx),
                    priority = call.priority,
                    area = call.area and { key = call.area, label = AreaLabel(call.area) } or nil,
                    distance = nil,
                    ageS = math.max(0, now - call.createdAt),
                    offerEndsIn = math.max(0, call.offerEnds - now),
                    staff = call.staff,
                    crew = 'none',
                    minUnit = nil,
                    cash = { 0, 0 },
                    points = 0,
                    rapidPoints = 0,
                    typeOfTheDay = tod == call.type,
                    redispatched = call.redispatched,
                    paged = call.pagedCid ~= nil,
                    status = call.status == 'claiming' and 'claiming' or 'ready',
                    lostBy = nil,
                }
            end
        end
    end
    local units = {}
    local own = v and v.unit.srcs or { src }
    for _, u in ipairs(IdleUnits()) do
        if not Contains(own, u.leader) then
            local o = GetOfficer(u.leader) or {}
            units[#units + 1] = {
                src = u.leader,
                name = o.name or ('#' .. u.leader),
                callsign = o.callsign,
                departmentShort = o.departmentShort or '',
                size = #u.srcs,
            }
        end
    end
    return { open = SortCards(open), today = SupToday(src), units = units }
end

-- ============================================================================
--                                    STATS
-- ============================================================================

-- Profile & History: calls answered (completed runs from a claim), average response and rapid responses.
function MC.stats(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { answered = 0, avgResponse = nil, rapid = 0 } end
    CP.Migrations.ready()
    local ok, row = pcall(MySQL.single.await, [[
        SELECT COUNT(*) AS n, COALESCE(SUM(t.response_s), 0) AS rs, COUNT(t.response_s) AS rc,
               COALESCE(SUM(t.rapid > 0), 0) AS rapid
        FROM (SELECT response_s,
                     COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"rapid_response"'), 0) AS rapid
              FROM cp_mission_runs
              WHERE citizenid = ? AND state = 'completed' AND mission_call_id IS NOT NULL) t
    ]], { citizenid })
    if not ok or type(row) ~= 'table' then
        if not ok then CP.err(TAG, 'call stats of %s failed: %s', citizenid, tostring(row)) end
        return { answered = 0, avgResponse = nil, rapid = 0 }
    end
    local rc = CP.U.num(row.rc)
    return {
        answered = math.floor(CP.U.num(row.n)),
        avgResponse = rc > 0 and math.floor(CP.U.num(row.rs) / rc + 0.5) or nil,
        rapid = math.floor(CP.U.num(row.rapid)),
    }
end

-- ============================================================================
--                                   THE TICK
-- ============================================================================

function MC._tick()
    local cfg = Cfg()
    if cfg.enabled == false then return end
    local now = os.time()
    Expire(now)
    if OperationLocked() then
        WithdrawAll('operation')
        return PushAll()
    end
    local units = IdleUnits()
    ToastPageEnded(units, now)
    local target = 0
    if #units > 0 then
        local per = math.max(1, Num(cfg.unitsPerCall, 2))
        target = math.min(math.floor(Num(cfg.maxOpen, 4)), math.max(1, math.ceil(#units / per)))
    end
    if #OpenCalls() < target and now >= nextPostAt then
        if PostServerCall(units, now) then
            local every = cfg.spawnEvery or { 60, 150 }
            local lo, hi = math.floor(Num(every[1], 60)), math.floor(Num(every[2], every[1] or 150))
            nextPostAt = now + Rng():int(lo, math.max(lo, hi))
        end
    end
    PushAll()
end

function MC._reset()
    calls, runToCall, finished, states, history, watchers, muted, wins, staffLast = {}, {}, {}, {}, {}, {}, {}, {}, {}
    counts = {}
    coverage, codeDay, codeSeq, nextPostAt, tempId, claimSeq, dirty = nil, nil, 0, 0, 0, 0, false
end
MC._calls = function() return calls end
MC._setNextPost = function(ts) nextPostAt = ts end

CreateThread(function()
    while true do
        Wait(math.max(1000, math.floor(Num(Cfg().checkEvery, 10) * 1000)))
        local ok, err = pcall(MC._tick)
        if not ok then CP.err(TAG, 'check failed: %s', tostring(err)) end
    end
end)

-- The screen's own pushes are coalesced: a burst of changes (a claim window) is one push.
CreateThread(function()
    while true do
        Wait(1000)
        if dirty then
            local ok, err = pcall(PushAll)
            if not ok then CP.err(TAG, 'push failed: %s', tostring(err)) end
        end
    end
end)

-- ============================================================================
--                                NET AND HOOKS
-- ============================================================================

CP.Net.callback('getMissionCalls', function(src)
    local officer, e = GetOfficer(src)
    if not officer then return nil, e or 'err.not_police' end
    watchers[src] = os.time()
    return MC.list(src)
end, { rate = 4 })

CP.Net.action('server:claimMissionCall', function(src, payload)
    if type(payload) ~= 'table' or not tonumber(payload.callId) then return false, 'err.invalid_payload' end
    return MC.claim(src, payload.callId)
end, { rate = 3 })

RegisterNetEvent(CP.e('server:mcWatch'), function(open)
    local src = source
    if not CP.Net.rateOk(src, 'missioncalls:watch', 4, 1000) then return end
    if open == false then watchers[src] = nil end
end)

local function StaffAllowed(src, adminOnly)
    if adminOnly then
        local _, admin = Call('Access', 'isAdmin', src)
        if not admin then return false, 'err.no_permission' end
    end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local ok, e = CP.Permissions.can(src, 'missionCalls')
    if not ok then return false, e or 'err.no_permission' end
    return true
end

local function StaffArea(payload)
    local area = payload.area
    if area ~= nil and type(area) ~= 'string' then return false end
    return true, area
end

for _, scope in ipairs({ 'sup', 'admin' }) do
    local adminOnly = scope == 'admin'
    CP.Net.action(('server:%s:mcWithdraw'):format(scope), function(src, payload)
        local ok, e = StaffAllowed(src, adminOnly)
        if not ok then return false, e end
        if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
        return MC.withdraw(src, payload.callId, payload.reason)
    end, { rate = 2 })
    CP.Net.action(('server:%s:mcPage'):format(scope), function(src, payload)
        local ok, e = StaffAllowed(src, adminOnly)
        if not ok then return false, e end
        if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
        local okA, area = StaffArea(payload)
        if not okA then return false, 'err.mc_unknown_area' end
        return MC.page(src, payload.type, area, payload.leaderSrc)
    end, { rate = 2 })
    CP.Net.action(('server:%s:mcCreate'):format(scope), function(src, payload)
        local ok, e = StaffAllowed(src, adminOnly)
        if not ok then return false, e end
        if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
        local okA, area = StaffArea(payload)
        if not okA then return false, 'err.mc_unknown_area' end
        return MC.create(src, payload.type, area)
    end, { rate = 2 })
end

CP.Net.callback('sup:getMissionCalls', function(src)
    local ok, e = StaffAllowed(src, false)
    if not ok then return nil, e end
    return MC.supView(src)
end, { rate = 3 })

CP.Net.callback('admin:getAreaCoverage', function(src)
    if not (CP.Permissions and CP.Permissions.can) then return nil, 'err.no_permission' end
    local okP, eP = CP.Permissions.can(src, 'openAdmin')
    if not okP then return nil, eP or 'err.no_permission' end
    local index = MC.areaIndex()
    local types = {}
    for key in pairs(Config.MissionTypes or {}) do types[#types + 1] = key end
    table.sort(types)
    local areas = {}
    for _, a in ipairs(Cfg().areas or {}) do areas[#areas + 1] = { key = a.key, label = a.label or a.key } end
    local cells = {}
    for _, key in ipairs(types) do
        cells[key] = {}
        for _, a in ipairs(areas) do
            local c = index[key] and index[key][a.key]
            cells[key][a.key] = { missions = c and c.missions or 0, locations = c and c.locations or 0 }
        end
    end
    return { types = types, areas = areas, cells = cells }
end, { rate = 2 })

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('run:arrived', function(run) OnRunArrived(run) end)
    CP.Hooks.on('run:ended', function(run, state, endReason) OnRunEnded(run, state, endReason) end)
    CP.Hooks.on('row:settled', function(_, p)
        Invalidate(type(p) == 'table' and p.citizenid or nil)
    end)
    CP.Hooks.on('participant:left', function() Invalidate(nil) end)
    CP.Hooks.on('home:extras', function(_, src, extras)
        if type(extras) == 'table' and ToSrc(src) then extras.callsOpen = MC.claimableCount(src) end
    end)
end

-- /CrimsonPoliceAdmin missioncall <type> [area], the daily history clean-up and the duty listener (runtime:
-- other modules are only called once every file has loaded).
CreateThread(function()
    local tries = 0
    while not (CP.Admin and CP.Admin.registerSubcommand and CP.Schedule and CP.Schedule.onDaily) and tries < 50 do
        tries = tries + 1
        Wait(100)
    end
    if CP.Admin and CP.Admin.registerSubcommand then
        CP.Admin.registerSubcommand('missioncall', function(src, args)
            local typeKey = args and args[1] and tostring(args[1]):lower() or nil
            if not typeKey then return false, 'admin.cmd.usage_missioncall' end
            local area = args[2] and tostring(args[2]) or nil
            local ok, data = MC.create(src, typeKey, area)
            if not ok then return false, data end
            return true, 'admin.cmd.missioncall_done', { code = data.code, type = TypeLabel(typeKey) }
        end, 'admin.cmd.usage_missioncall')
    end
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function()
            local days = Num(Config.Retention and Config.Retention.missionCallDays, 90)
            if days <= 0 then return end
            local n = Exec('DELETE FROM cp_mission_calls WHERE created_at < NOW() - INTERVAL ? SECOND',
                { math.floor(days * DAY_S) })
            CP.log(TAG, 'history clean-up removed %s call(s)', tostring(n))
        end)
    end
    if CP.Qbx and CP.Qbx.onDutyChange then
        CP.Qbx.onDutyChange(function(src)
            local o = GetOfficer(src)
            Invalidate(o and o.citizenid or nil)
            if not o then watchers[src] = nil end
        end)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    watchers[src] = nil
    states[src] = nil
end)
