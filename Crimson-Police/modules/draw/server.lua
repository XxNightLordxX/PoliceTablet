-- CP.Draw: mission pools, the random draw, locations and the Mission Board.

CP.Draw = CP.Draw or {}
local Draw = CP.Draw

local TAG = 'draw'
local BOSS_ID = 'weekly_boss_kingpin'
local BOSS_KEY = 'weekly_boss'
local RECENT_KEEP_S = 900            -- in-memory history is only a bridge until the row is in the DB
local MEM_SEQ_BASE = 2 ^ 40          -- in-memory records sort after DB rows of the same second
local PENDING_PREFIX = 'pending:'
local SAME_SPOT_M = 50.0             -- a location this close to a held spot is that spot (locations are 100 m apart)
local ROUTE_SAMPLE_M = 50.0          -- a route is part of a footprint every 50 m (Config.Draw.zoneClearance)
local FRESH_WEIGHT = 0.5             -- a location used server-wide within locationFreshness gets half the weight
local LAST_LOCS_KEEP = 5             -- in-memory last locations per officer and mission (a bridge until the row)
local DAY_SPAN_S = 108000            -- 30 h: from a day start this always lands inside the next day

local holders = {} -- holders[missionId][index] = { [holderId] = true }
local byHolder = {} -- byHolder[holderId] = { missionId, index, at, coords } (coords: the start of the held spot)
local recent = {} -- recent[citizenid][missionType] = { { missionId, at, seq }, ... } newest first
local inFlight = {} -- inFlight[src] = true while an accept for that player is being processed
local usedAt = {} -- usedAt[missionId][index] = when a run last took that spot (server-wide freshness)
local lastLocs = {} -- lastLocs[citizenid][missionId] = { { index, at }, ... } newest first
local footprints = setmetatable({}, { __mode = 'k' }) -- footprints[def][index] = { pts, box }
local memSeq = 0
local drawRng = nil

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Rng()
    if not drawRng then
        local seed = os.time() ~ (GetGameTimer and GetGameTimer() or 0) ~ CP.U.hash(tostring({}))
        drawRng = CP.U.rng(seed & 0x7FFFFFFF)
    end
    return drawRng
end

local function Safe(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        CP.err(TAG, 'call failed: %s', tostring(a))
        return false, nil
    end
    return true, a, b, c
end

local function GetOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    return CP.Access.getOfficer(src)
end

local function UnitOf(src)
    if not (CP.Units and CP.Units.unitOf) then return nil end
    local _, unit = Safe(CP.Units.unitOf, src)
    return type(unit) == 'table' and unit or nil
end

local function UnitMembers(src)
    if CP.Units and CP.Units.members then
        local _, list = Safe(CP.Units.members, src)
        if type(list) == 'table' and #list > 0 then return list end
    end
    return { src }
end

local function IsLeader(src)
    if not UnitOf(src) then
        return true
    end -- a solo officer leads themselves
    if not (CP.Units and CP.Units.isLeader) then return false end
    local _, leader = Safe(CP.Units.isLeader, src)
    return leader == true
end

local function OperationLocked()
    if not (CP.Operations and CP.Operations.isLocked) then return false end
    local _, locked = Safe(CP.Operations.isLocked)
    return locked == true
end

local function IsOnCall(src)
    if not (CP.Calls and CP.Calls.isOnCall) then return false end
    local _, onCall = Safe(CP.Calls.isOnCall, src)
    return onCall == true
end

-- docs/CRIMSON_ARENA.md rules 5 and 7: a foreign crimsonArena flag or a routing bucket other than 0.
-- CP.Alerts.inArena is the gate; the fallbacks only apply while modules/alerts is not loaded.
local function InArena(src)
    if CP.Alerts and CP.Alerts.inArena then
        local _, res = Safe(CP.Alerts.inArena, src)
        return res == true
    end
    if CP.Alerts and CP.Alerts.foreignFlag then
        local _, foreign = Safe(CP.Alerts.foreignFlag, src)
        if foreign == true then return true end
    end
    if GetPlayerRoutingBucket then
        local ok, bucket = pcall(GetPlayerRoutingBucket, src)
        if ok and tonumber(bucket) and tonumber(bucket) ~= 0 then return true end
    end
    return false
end

local function OnMission(src)
    if not CP.Runs then return false end
    if CP.Runs.isOnMission then
        local _, on = Safe(CP.Runs.isOnMission, src)
        if on then return true end
    end
    if CP.Runs.getBySrc then
        local _, run = Safe(CP.Runs.getBySrc, src)
        if run then return true end
    end
    return false
end

local function CapsOk(missionType)
    if not (CP.Runs and CP.Runs.capsOk) then return true end
    local ok, capOk = Safe(CP.Runs.capsOk, missionType)
    if not ok then return true end
    return capOk ~= false
end

local function CooldownsOf(citizenid)
    if CP.Runs and CP.Runs.cooldowns then
        local _, cd = Safe(CP.Runs.cooldowns, citizenid)
        if type(cd) == 'table' then
            cd.types = type(cd.types) == 'table' and cd.types or {}
            cd.missions = type(cd.missions) == 'table' and cd.missions or {}
            return cd
        end
    end
    return { types = {}, missions = {} }
end

local function CompletionsLastHour(citizenid)
    if not (CP.Runs and CP.Runs.completionsLastHour) then return 0 end
    local _, n = Safe(CP.Runs.completionsLastHour, citizenid)
    return tonumber(n) or 0
end

local function HourlyCap()
    return tonumber(Config.Limits and Config.Limits.maxCompletionsHour) or 8
end

local function ToOfficers(members)
    local out = {}
    for _, m in ipairs(members or {}) do
        if type(m) == 'table' and m.citizenid then
            out[#out + 1] = m
        elseif tonumber(m) then
            local o = GetOfficer(tonumber(m))
            if o then out[#out + 1] = o end
        end
    end
    return out
end

local function SrcsOf(officers)
    local out = {}
    for _, o in ipairs(officers) do out[#out + 1] = o.src end
    return out
end

local function TypeKeysByPoints()
    local keys = CP.U.keys(Config.MissionTypes or {})
    table.sort(keys, function(a, b)
        local pa = tonumber(Config.MissionTypes[a].points) or 0
        local pb = tonumber(Config.MissionTypes[b].points) or 0
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return keys
end

local function TypeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return (t and t.label) or tostring(key)
end

local function CompletionsToday(citizenid, missionType)
    if not (CP.Runs and CP.Runs.completionsToday) then return 0 end
    local _, n = Safe(CP.Runs.completionsToday, citizenid, missionType)
    return tonumber(n) or 0
end

-- Config.Limits.maxCompletionsDay (0 = no cap) and the type's dailyLimit (nil = no limit).
local function DailyCap()
    return math.max(0, math.floor(tonumber(Config.Limits and Config.Limits.maxCompletionsDay) or 0))
end

local function TypeDailyLimit(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    local n = t and tonumber(t.dailyLimit)
    return n and n > 0 and math.floor(n) or nil
end

-- The first officer at a daily limit and which one ('day' or 'type'), or nil.
local function DailyBlocked(officers, key)
    local max, perType = DailyCap(), TypeDailyLimit(key)
    for _, o in ipairs(officers) do
        if max > 0 and CompletionsToday(o.citizenid) >= max then return o, 'day' end
        if perType and CompletionsToday(o.citizenid, key) >= perType then return o, 'type' end
    end
    return nil
end

local function NextDayStart(now)
    if not (CP.Schedule and CP.Schedule.dayStart) then return nil end
    local _, today = Safe(CP.Schedule.dayStart, now)
    if not tonumber(today) then return nil end
    local _, nextDay = Safe(CP.Schedule.dayStart, tonumber(today) + DAY_SPAN_S)
    return tonumber(nextDay)
end

-- The area a point belongs to: the Config.MissionCalls.areas entry whose centre is nearest (nil: no areas).
local function AreaKeyOf(coords)
    local areas = Config.MissionCalls and Config.MissionCalls.areas
    if type(areas) ~= 'table' or coords == nil then return nil end
    local best, bestD
    for _, a in ipairs(areas) do
        if type(a) == 'table' and type(a.key) == 'string' and a.center then
            local d = CP.U.dist2d(coords, a.center)
            if d < math.huge and (not bestD or d < bestD) then best, bestD = a.key, d end
        end
    end
    return best
end
Draw._areaKeyOf = AreaKeyOf

-- ============================================================================
--                             ELIGIBILITY AND POOL
-- ============================================================================
-- ok, why ('disabled'|'size'|'department'|'cooldown'), untilTs (cooldown), officer (who blocks it)
local function Eligibility(def, officers, size, now)
    now = now or os.time()
    size = size or #officers
    if not (CP.Missions and CP.Missions.isEnabled and CP.Missions.isEnabled(def.id)) then return false, 'disabled' end
    if size < (def.minOfficers or 1) or size > (def.maxOfficers or 1) then return false, 'size' end
    if type(def.departments) == 'table' and #def.departments > 0 then
        for _, o in ipairs(officers) do
            if not CP.U.contains(def.departments, o.department) then return false, 'department', nil, o end
        end
    end
    local untilTs, who
    for _, o in ipairs(officers) do
        local u = tonumber(CooldownsOf(o.citizenid).missions[def.id])
        if u and u > now and (not untilTs or u > untilTs) then untilTs, who = u, o end
    end
    if untilTs then return false, 'cooldown', untilTs, who end
    return true
end
Draw._eligibility = Eligibility

-- The area of location #i of a definition (its start), cached on the definition's own table.
local function LocationArea(def, i)
    local loc = type(def) == 'table' and type(def.locations) == 'table' and def.locations[i]
    local start = type(loc) == 'table' and type(loc.start) == 'table' and loc.start.coords or nil
    if not start then return nil end
    return AreaKeyOf(start)
end
Draw._locationArea = LocationArea

-- Location #i is on (an admin can turn single locations off: Config.DisabledLocations).
local function LocationOn(def, i)
    if not (CP.Missions and CP.Missions.isLocationEnabled) then return true end
    return CP.Missions.isLocationEnabled(def.id, i) ~= false
end
Draw._locationOn = LocationOn

local function HasLocationIn(def, area)
    for i = 1, #(def.locations or {}) do
        if LocationOn(def, i) and LocationArea(def, i) == area then return true end
    end
    return false
end

-- opts.area: only missions with a location in that area (a mission call that named its area).
function Draw.pool(missionType, members, opts)
    local area = type(opts) == 'table' and opts.area or nil
    local officers = ToOfficers(members)
    local size = math.max(#(members or {}), #officers)
    if size < 1 then size = 1 end
    local list, cooldownUntil = {}, nil
    local byType = (CP.Missions and CP.Missions.byType and CP.Missions.byType(missionType)) or {}
    local now = os.time()
    for _, def in ipairs(byType) do
        local ok, why, untilTs = Eligibility(def, officers, size, now)
        if ok and area and not HasLocationIn(def, area) then
            ok, why = false, 'area'
        end
        if ok then
            list[#list + 1] = def
        elseif why == 'cooldown' and untilTs and (not cooldownUntil or untilTs < cooldownUntil) then
            cooldownUntil = untilTs
        end
    end
    if #list == 0 then
        local reason
        if cooldownUntil then
            reason = 'board.locked_mission_cooldown'
        else
            reason = size > 1 and 'board.locked_empty' or 'board.locked_empty_solo'
        end
        return list, reason, { cooldownUntil = cooldownUntil }
    end
    return list, nil, {}
end

-- ============================================================================
--                             HISTORY (no-repeat)
-- ============================================================================

local function PruneRecent(now)
    now = now or os.time()
    for cid, byType in pairs(recent) do
        for t, list in pairs(byType) do
            for i = #list, 1, -1 do
                if now - list[i].at > RECENT_KEEP_S then table.remove(list, i) end
            end
            if #list == 0 then byType[t] = nil end
        end
        if next(byType) == nil then recent[cid] = nil end
    end
end

-- Distinct missions of that type the officer last completed or abandoned, newest first.
local function HistoryFor(citizenid, missionType)
    CP.Migrations.ready()
    local rows = MySQL.query.await(
        'SELECT mission_id, UNIX_TIMESTAMP(MAX(created_at)) AS last_ts, MAX(id) AS last_id FROM cp_mission_runs WHERE citizenid = ? AND mission_type = ? AND state IN (\'completed\', \'abandoned\') AND mission_id <> ? GROUP BY mission_id',
        { citizenid, missionType, BOSS_ID }) or {}
    local byId = {}
    for _, r in ipairs(rows) do
        if r.mission_id then
            byId[tostring(r.mission_id)] = { at = CP.U.num(r.last_ts), seq = CP.U.num(r.last_id) }
        end
    end
    local mem = recent[citizenid] and recent[citizenid][missionType]
    if mem then
        local now = os.time()
        for _, e in ipairs(mem) do
            if now - e.at <= RECENT_KEEP_S then
                local cur = byId[e.missionId]
                if not cur or cur.at < e.at or (cur.at == e.at and cur.seq < e.seq) then
                    byId[e.missionId] = { at = e.at, seq = e.seq }
                end
            end
        end
    end
    local list = {}
    for id, h in pairs(byId) do list[#list + 1] = { id = id, at = h.at, seq = h.seq } end
    table.sort(list, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        if a.seq ~= b.seq then return a.seq > b.seq end
        return a.id < b.id
    end)
    return list
end

Draw.history = HistoryFor

-- The no-repeat rule (Config.Draw.avoidLast / avoidLastLarge / largePool) on an eligible list, given each
-- officer's history (HistoryFor lists, newest first). Relaxed step by step, never empty while list is not.
function Draw.noRepeat(list, hist)
    local cfg = Config.Draw or {}
    local avoidLast = math.max(0, math.floor(tonumber(cfg.avoidLast) or 1))
    local k = avoidLast
    if #list >= (tonumber(cfg.largePool) or 4) then
        k = math.max(avoidLast, math.floor(tonumber(cfg.avoidLastLarge) or 2))
    end
    if #list <= 1 or k <= 0 then return list end
    local function lastN(n)
        local set = {}
        for _, h in ipairs(hist) do
            for i = 1, math.min(n, #h) do set[h[i].id] = true end
        end
        return set
    end
    local function without(set)
        local out = {}
        for _, d in ipairs(list) do if not set[d.id] then out[#out + 1] = d end end
        return out
    end
    local candidates = without(lastN(k))
    -- A unit whose members' histories cover the whole pool: relax step by step, never below
    -- "not the unit's most recent mission" while another one is eligible.
    if #candidates == 0 and k > 1 and avoidLast > 0 then candidates = without(lastN(avoidLast)) end
    if #candidates == 0 then
        local latest
        for _, h in ipairs(hist) do
            local e = h[1]
            if e and (not latest or e.at > latest.at or (e.at == latest.at and e.seq > latest.seq)) then latest = e end
        end
        if latest then candidates = without({ [latest.id] = true }) end
    end
    if #candidates == 0 then candidates = list end
    return candidates
end

function Draw.recordLast(citizenid, missionType, missionId)
    if type(citizenid) ~= 'string' or type(missionType) ~= 'string' or type(missionId) ~= 'string' then return end
    if missionId == BOSS_ID then return end
    memSeq = memSeq + 1
    local byType = recent[citizenid] or {}
    recent[citizenid] = byType
    local list = byType[missionType] or {}
    byType[missionType] = list
    table.insert(list, 1, { missionId = missionId, at = os.time(), seq = MEM_SEQ_BASE + memSeq })
    while #list > 5 do table.remove(list) end
end

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

local function StartOf(location)
    local start = type(location) == 'table' and location.start
    return type(start) == 'table' and start.coords or nil
end

local function LocationStart(def, index)
    return type(def) == 'table' and type(def.locations) == 'table' and StartOf(def.locations[index]) or nil
end

-- The spot a holder takes: its run's own location (a run keeps the definition it was drawn from, also after a
-- Builder republish or a reload moved the locations), else location #index of the registered definition.
local function HeldCoords(holderId, missionId, index)
    if CP.Runs and CP.Runs.get then
        local _, run = Safe(CP.Runs.get, holderId)
        if type(run) == 'table' and tonumber(run.locationIndex) == index then
            local coords = StartOf(run.location) or LocationStart(run.mission, index)
            if coords then return coords end
        end
    end
    return LocationStart(CP.Missions and CP.Missions.get and CP.Missions.get(missionId), index)
end

-- A holder with coordinates takes the spot there, so a reservation survives a republish that moved or reordered
-- the locations; a holder or a query without coordinates matches by index.
local function InUse(missionId, index, coords)
    local byIdx = holders[missionId]
    if not byIdx then return false end
    for i, set in pairs(byIdx) do
        for holderId in pairs(set) do
            local held = byHolder[holderId] and byHolder[holderId].coords
            if held and coords then
                if CP.U.dist(held, coords) < SAME_SPOT_M then return true end
            elseif i == index then
                return true
            end
        end
    end
    return false
end

local function Reserve(holderId, missionId, index, coords)
    index = tonumber(index)
    if holderId == nil or type(missionId) ~= 'string' or not index then return false end
    index = math.floor(index)
    Draw.release(holderId)
    coords = coords or HeldCoords(holderId, missionId, index)
    local wasFree = not InUse(missionId, index, coords)
    local byIdx = holders[missionId] or {}
    holders[missionId] = byIdx
    local set = byIdx[index] or {}
    byIdx[index] = set
    set[holderId] = true
    byHolder[holderId] = { missionId = missionId, index = index, at = os.time(), coords = coords }
    if not (type(holderId) == 'string' and holderId:sub(1, #PENDING_PREFIX) == PENDING_PREFIX) then
        local byIndex = usedAt[missionId] or {}
        usedAt[missionId] = byIndex
        byIndex[index] = os.time()
    end
    CP.log(TAG, 'reserved %s #%d for %s', missionId, index, tostring(holderId))
    return wasFree
end

function Draw.reserve(runId, missionId, index)
    return Reserve(runId, missionId, index, nil)
end

function Draw.release(runId)
    local h = runId ~= nil and byHolder[runId]
    if not h then return false end
    byHolder[runId] = nil
    local byIdx = holders[h.missionId]
    local set = byIdx and byIdx[h.index]
    if set then
        set[runId] = nil
        if next(set) == nil then byIdx[h.index] = nil end
        if next(byIdx) == nil then holders[h.missionId] = nil end
    end
    CP.log(TAG, 'released %s #%d from %s', h.missionId, h.index, tostring(runId))
    return true
end

function Draw.isReserved(missionId, index)
    index = tonumber(index)
    if not index then return false end
    return InUse(missionId, index, LocationStart(CP.Missions and CP.Missions.get and CP.Missions.get(missionId), index))
end

-- Coordinates of every player who is not a participant (server-side ped coords). Players in
-- Crimson-Arena (foreign flag or another routing bucket) are ignored (docs/CRIMSON_ARENA.md rule 7).
local function OtherPlayerCoords(participants)
    local out = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local s = tonumber(id)
        if s and not participants[s] and not InArena(s) then
            local ped = GetPlayerPed(s)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                if c then out[#out + 1] = c end
            end
        end
    end
    return out
end

-- ============================================================================
--                        FOOTPRINTS AND ZONE CLEARANCE
-- ============================================================================

local function PointXyz(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return v.x, v.y, v.z end
    if t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number' then
        return v.x, v.y, v.z
    end
    return nil
end

-- Every point of a location table: its start and every coordinate in it; a route (a list of points under a
-- key named route) also every ROUTE_SAMPLE_M along its segments.
local function CollectPoints(v, out, depth, inRoute)
    if depth > 6 or type(v) ~= 'table' then return end
    local x, y, z = PointXyz(v)
    if x then
        out[#out + 1] = { x, y, z }
        return
    end
    local line = {}
    for k, child in pairs(v) do
        local cx, cy, cz = PointXyz(child)
        if cx then
            if inRoute and math.type(k) == 'integer' then line[k] = { cx, cy, cz } end
            out[#out + 1] = { cx, cy, cz }
        elseif type(child) == 'table' then
            CollectPoints(child, out, depth + 1, inRoute or k == 'route')
        end
    end
    for i = 2, #line do
        local a, b = line[i - 1], line[i]
        if a and b then
            local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
            local len = math.sqrt(dx * dx + dy * dy + dz * dz)
            local steps = math.floor(len / ROUTE_SAMPLE_M)
            for s = 1, steps do
                local f = s * ROUTE_SAMPLE_M / len
                out[#out + 1] = { a[1] + dx * f, a[2] + dy * f, a[3] + dz * f }
            end
        end
    end
end

local function BuildFootprint(def, index)
    local loc = type(def) == 'table' and type(def.locations) == 'table' and def.locations[index]
    if type(loc) ~= 'table' then return nil end
    local pts = {}
    CollectPoints(loc, pts, 0, false)
    if #pts == 0 then return nil end
    local box = { pts[1][1], pts[1][2], pts[1][1], pts[1][2] }
    for _, p in ipairs(pts) do
        if p[1] < box[1] then box[1] = p[1] end
        if p[2] < box[2] then box[2] = p[2] end
        if p[1] > box[3] then box[3] = p[1] end
        if p[2] > box[4] then box[4] = p[2] end
    end
    return { pts = pts, box = box }
end

local function Footprint(def, index)
    if type(def) ~= 'table' then return nil end
    local byIndex = footprints[def]
    if not byIndex then
        byIndex = {}
        footprints[def] = byIndex
    end
    local fp = byIndex[index]
    if fp == nil then
        fp = BuildFootprint(def, index) or false
        byIndex[index] = fp
    end
    return fp or nil
end

-- The points of location #index of a mission: its start and every point, routes sampled every 50 m.
function Draw.footprint(def, index)
    local fp = Footprint(def, index)
    local out = {}
    if not fp then return out end
    for _, p in ipairs(fp.pts) do out[#out + 1] = vector3(p[1], p[2], p[3]) end
    return out
end

-- The footprints held right now (every reservation: runs, Cross-Department Missions and accepts in flight).
local function HeldFootprints()
    local out = {}
    for holderId, h in pairs(byHolder) do
        local def
        if CP.Runs and CP.Runs.get
            and not (type(holderId) == 'string' and holderId:sub(1, #PENDING_PREFIX) == PENDING_PREFIX) then
            local _, run = Safe(CP.Runs.get, holderId)
            if type(run) == 'table' and run.state ~= 'ended' and tonumber(run.locationIndex) == h.index then
                def = run.mission
            end
        end
        def = def or (CP.Missions and CP.Missions.get and CP.Missions.get(h.missionId))
        local fp = def and Footprint(def, h.index)
        if fp then out[#out + 1] = { missionId = h.missionId, index = h.index, fp = fp } end
    end
    return out
end

local function Near(a, b, m)
    if a.box[1] - m > b.box[3] or b.box[1] - m > a.box[3] or a.box[2] - m > b.box[4] or b.box[2] - m > a.box[4] then
        return false
    end
    local m2 = m * m
    for _, p in ipairs(a.pts) do
        for _, q in ipairs(b.pts) do
            local dx, dy, dz = p[1] - q[1], p[2] - q[2], p[3] - q[3]
            if dx * dx + dy * dy + dz * dz < m2 then return true end
        end
    end
    return false
end

-- A location with any point within Config.Draw.zoneClearance of any point of another held location.
local function ZoneBlocked(def, index, held, clearance)
    local fp = Footprint(def, index)
    if not fp then return false end
    for _, h in ipairs(held) do
        if not (h.missionId == def.id and h.index == index) and Near(fp, h.fp, clearance) then return true end
    end
    return false
end
-- Whether location #index is blocked by zone clearance right now (for specs and the admin views).
Draw._zoneBlocked = function(def, index)
    return ZoneBlocked(def, index, HeldFootprints(), tonumber(Config.Draw and Config.Draw.zoneClearance) or 0)
end

-- ============================================================================
--               LAST LOCATIONS (Config.Draw.avoidLastLocations)
-- ============================================================================

function Draw.recordLocation(citizenid, missionId, index)
    index = math.tointeger(tonumber(index) or -1)
    if type(citizenid) ~= 'string' or type(missionId) ~= 'string' or not index or index < 1 then return end
    local byMission = lastLocs[citizenid] or {}
    lastLocs[citizenid] = byMission
    local list = byMission[missionId] or {}
    byMission[missionId] = list
    table.insert(list, 1, { index = index, at = os.time() })
    while #list > LAST_LOCS_KEEP do table.remove(list) end
end

-- The last n locations each officer played in that mission (cp_mission_runs.location_index and the
-- in-memory bridge), as a set of indices.
local function LastLocations(citizenids, missionId, n)
    local set = {}
    if n <= 0 then return set end
    for _, cid in ipairs(citizenids) do
        local seen = {}
        local list = {}
        local mem = lastLocs[cid] and lastLocs[cid][missionId]
        for _, e in ipairs(mem or {}) do list[#list + 1] = { index = e.index, at = e.at } end
        CP.Migrations.ready()
        local ok, rows = pcall(MySQL.query.await, [[
            SELECT location_index, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_mission_runs
            WHERE citizenid = ? AND mission_id = ? AND location_index IS NOT NULL
            ORDER BY created_at DESC, id DESC LIMIT ?
        ]], { cid, missionId, n })
        if ok and type(rows) == 'table' then
            for _, r in ipairs(rows) do
                list[#list + 1] = { index = math.tointeger(CP.U.num(r.location_index)), at = CP.U.num(r.created_ts) }
            end
        end
        table.sort(list, function(a, b) return a.at > b.at end)
        local taken = 0
        for _, e in ipairs(list) do
            if taken >= n then break end
            if e.index and not seen[e.index] then
                seen[e.index] = true
                set[e.index] = true
                taken = taken + 1
            end
        end
    end
    return set
end

-- ============================================================================
--                                   THE PICK
-- ============================================================================

local function Filter(list, keep)
    local out = {}
    for _, i in ipairs(list) do if keep(i) then out[#out + 1] = i end end
    return out
end

-- Locations turned off are never picked. opts: exclude (hard), area (hard: only locations in that area), avoid
-- (soft: indices to skip), nearCoords (county-wide weighting towards a unit: 1 / (1 + km / countyWeightKm) from the
-- nearest point). Soft rules apply only while another location is left; zone clearance falls back to the
-- reservation rule alone.
function Draw.pickLocation(def, participantSrcs, rngObj, opts)
    opts = opts or {}
    if type(def) ~= 'table' or type(def.locations) ~= 'table' or #def.locations == 0 then return nil end
    local r = rngObj or Rng()
    local cfg = Config.Draw or {}
    local reserveOn = not (Config.Limits and Config.Limits.reserveLocations == false)
    local participants = {}
    for _, s in ipairs(participantSrcs or {}) do
        local n = tonumber(type(s) == 'table' and s.src or s)
        if n then participants[n] = true end
    end
    local free = {}
    for i = 1, #def.locations do
        local skip = not LocationOn(def, i) or (reserveOn and InUse(def.id, i, LocationStart(def, i)))
            or (opts.exclude and opts.exclude[i]) or (opts.area and LocationArea(def, i) ~= opts.area)
        if not skip then free[#free + 1] = i end
    end
    if #free == 0 then return nil end

    local zone = tonumber(cfg.zoneClearance) or 0
    if zone > 0 and #free > 0 then
        local held = HeldFootprints()
        if #held > 0 then
            local clear = Filter(free, function(i) return not ZoneBlocked(def, i, held, zone) end)
            if #clear > 0 then free = clear end
        end
    end
    if type(opts.avoid) == 'table' and #free > 1 then
        local kept = Filter(free, function(i) return not opts.avoid[i] end)
        if #kept > 0 then free = kept end
    end
    local clearance = tonumber(cfg.playerClearance) or 0
    if clearance > 0 and #free > 1 then
        local others = OtherPlayerCoords(participants)
        if #others > 0 then
            local clear = Filter(free, function(i)
                local c = LocationStart(def, i)
                for _, pc in ipairs(others) do
                    if CP.U.dist(c, pc) <= clearance then return false end
                end
                return true
            end)
            if #clear > 0 then free = clear end
        end
    end
    if #free == 1 then return free[1] end

    -- ---- WEIGHTS: freshness and the county-wide distance weighting ---------
    local fresh = tonumber(cfg.locationFreshness) or 0
    local km = tonumber(Config.MissionCalls and Config.MissionCalls.countyWeightKm) or 2.0
    local near = type(opts.nearCoords) == 'table' and #opts.nearCoords > 0 and opts.nearCoords or nil
    local now = os.time()
    local weights, total, uniform = {}, 0, true
    for n, i in ipairs(free) do
        local w = 1.0
        local at = usedAt[def.id] and usedAt[def.id][i]
        if fresh > 0 and at and now - at < fresh then w = w * FRESH_WEIGHT end
        if near and km > 0 then
            local best = math.huge
            for _, c in ipairs(near) do
                local d = CP.U.dist2d(LocationStart(def, i), c)
                if d < best then best = d end
            end
            if best < math.huge then w = w / (1 + best / 1000 / km) end
        end
        weights[n] = w
        total = total + w
        if w ~= weights[1] then uniform = false end
    end
    if uniform or total <= 0 then return (r:pick(free)) end
    local roll = r:next() * total
    for n, i in ipairs(free) do
        roll = roll - weights[n]
        if roll < 0 then return i end
    end
    return free[#free]
end

-- ============================================================================
--                                     DRAW
-- ============================================================================

-- opts: rng, participants, area (a mission call that named its area: only missions and locations there),
-- nearCoords (a county-wide call: locations weighted towards these points), avoid (extra indices to skip).
function Draw.draw(missionType, members, opts)
    opts = opts or {}
    local officers = ToOfficers(members)
    local list, reason = Draw.pool(missionType, members, { area = opts.area })
    if #list == 0 then
        return nil, reason == 'board.locked_mission_cooldown' and 'err.pool_cooldown' or 'err.pool_empty'
    end

    local candidates = list
    if #list > 1 then
        local hist = {}
        for i, o in ipairs(officers) do hist[i] = HistoryFor(o.citizenid, missionType) end
        candidates = Draw.noRepeat(list, hist)
    end

    local r = opts.rng or Rng()
    local participants = opts.participants or SrcsOf(officers)
    local cids = {}
    for _, o in ipairs(officers) do cids[#cids + 1] = o.citizenid end
    local lastN = math.max(0, math.floor(tonumber(Config.Draw and Config.Draw.avoidLastLocations) or 0))
    for _, def in ipairs(r:shuffle(candidates)) do
        local avoid = LastLocations(cids, def.id, lastN)
        for i in pairs(type(opts.avoid) == 'table' and opts.avoid or {}) do avoid[i] = true end
        local index = Draw.pickLocation(def, participants, r, {
            exclude = opts.exclude,
            area = opts.area,
            avoid = avoid,
            nearCoords = opts.nearCoords,
        })
        if index then
            CP.log(TAG, 'drew %s #%d for %s (%d candidates of %d)', def.id, index, missionType, #candidates, #list)
            return def, index
        end
    end
    return nil, 'err.no_location'
end

-- ============================================================================
--                                MISSION BOARD
-- ============================================================================

local function CardCash(key, officers, list, size)
    if CP.Cash and CP.Cash.range then
        local ok, lo, hi = Safe(CP.Cash.range, key, officers)
        if ok and type(lo) == 'number' and type(hi) == 'number' then
            return { math.floor(lo + 0.5), math.floor(hi + 0.5) }
        end
    end
    -- Fallback while modules/cash is unavailable: base payout x tier (x modifier at the top).
    local tier = CP.Scaling.tierFor(size)
    local tierCash = tonumber(tier and tier.cash) or 1.0
    local modCash = tonumber(Config.Events and Config.Events.modifierCash) or 1.0
    local typePay = tonumber(Config.MissionTypes[key] and Config.MissionTypes[key].payout) or 0
    local lo, hi
    for _, def in ipairs(list) do
        local base
        if CP.Payouts and CP.Payouts.baseFor then
            local ok, b = Safe(CP.Payouts.baseFor, def)
            if ok and type(b) == 'number' then base = b end
        end
        if not base then
            local stars = Config.Difficulty and Config.Difficulty.cashByStars
            base = typePay * (tonumber(stars and stars[def.difficulty]) or 1.0)
        end
        if not lo or base < lo then lo = base end
        if not hi or base > hi then hi = base end
    end
    lo, hi = lo or typePay, hi or typePay
    return { CP.U.round(lo * tierCash), CP.U.round(hi * tierCash * modCash) }
end

local function CardPoints(key, list)
    local best
    for _, def in ipairs(list) do
        local p
        if CP.Scoring and CP.Scoring.P then
            local ok, v = Safe(CP.Scoring.P, def)
            if ok and type(v) == 'number' then p = v end
        end
        if not p then
            local stars = Config.Difficulty and Config.Difficulty.pointsByStars
            p = (tonumber(Config.MissionTypes[key].points) or 0) * (tonumber(stars and stars[def.difficulty]) or 1.0)
        end
        if not best or p > best then best = p end
    end
    return math.floor(best or tonumber(Config.MissionTypes[key].points) or 0)
end

-- The cash range and the points of a type's card for these officers (the Mission Board's own numbers), for
-- the mission call cards.
function Draw.typeValues(key, officers, list)
    officers = ToOfficers(officers)
    list = list or Draw.pool(key, officers)
    return CardCash(key, officers, list, math.max(1, #officers)), CardPoints(key, list)
end

local function TypeCooldown(officers, key, now)
    local untilTs, who
    for _, o in ipairs(officers) do
        local u = tonumber(CooldownsOf(o.citizenid).types[key])
        if u and u > now and (not untilTs or u > untilTs) then untilTs, who = u, o end
    end
    return untilTs, who
end

local function HourlyBlocked(officers)
    local max = HourlyCap()
    for _, o in ipairs(officers) do
        if CompletionsLastHour(o.citizenid) >= max then return o end
    end
    return nil
end

function Draw.boardCards(src)
    local viewer, errKey = GetOfficer(src)
    if not viewer then return nil, errKey or 'err.not_police' end

    local srcs = UnitMembers(src)
    local size = #srcs
    local officers, missing = {}, false
    for _, m in ipairs(srcs) do
        local o = (m == src) and viewer or GetOfficer(m)
        if o then officers[#officers + 1] = o else missing = true end
    end

    local activeRunId = nil
    if CP.Runs and CP.Runs.getBySrc then
        local _, run = Safe(CP.Runs.getBySrc, src)
        if type(run) == 'table' then activeRunId = run.id end
    end

    local data = {
        cards = {},
        boss = nil,
        operation = nil,
        unit = { size = size, isLeader = IsLeader(src) },
        activeRunId = activeRunId,
        -- Extras (web/src/types/run_ui.ts): the server clock for the locked.until countdowns and the Type
        -- of the Day multiplier the card texts show.
        serverTime = os.time(),
        todMultiplier = tonumber(Config.Events and Config.Events.todMultiplier) or 2,
    }

    -- While a Cross-Department Mission is active the board shows only its card.
    if OperationLocked() then
        if CP.Operations.boardCard then
            local _, card = Safe(CP.Operations.boardCard, src)
            data.operation = type(card) == 'table' and card or nil
        end
        return data
    end

    local now = os.time()
    local tod = CP.Events and CP.Events.typeOfTheDay and CP.Events.typeOfTheDay() or nil
    local onCall = false
    for _, m in ipairs(srcs) do
        if IsOnCall(m) then onCall = true; break end
    end
    local hourlyWho = HourlyBlocked(officers)

    for _, key in ipairs(TypeKeysByPoints()) do
        local label = TypeLabel(key)
        local list, reasonKey, info = Draw.pool(key, missing and srcs or officers)
        local card = {
            key = key,
            label = label,
            points = CardPoints(key, list),
            cash = CardCash(key, officers, list, size),
            pool = #list,
            mode = size > 1 and 'unit' or 'solo',
            locked = nil,
            busy = not CapsOk(key),
            onCall = onCall,
            typeOfTheDay = tod == key,
        }
        local cdUntil, cdWho = TypeCooldown(officers, key, now)
        if missing then
            card.locked = { reason = CP.L('board.member_unavailable') }
        elseif cdUntil then
            if cdWho.src == src then
                card.locked = { reason = CP.L('board.locked_cooldown', { type = label }), ['until'] = cdUntil }
            else
                card.locked = {
                    reason = CP.L('board.locked_cooldown_member', { type = label, name = cdWho.name or '?' }),
                    ['until'] = cdUntil,
                }
            end
        elseif hourlyWho then
            if hourlyWho.src == src then
                card.locked = { reason = CP.L('board.locked_hourly', { max = HourlyCap() }) }
            else
                card.locked = {
                    reason = CP.L('board.locked_hourly_member', { name = hourlyWho.name or '?', max = HourlyCap() }),
                }
            end
        elseif #list == 0 then
            card.locked = {
                reason = CP.L(reasonKey, { type = label, size = size }),
                ['until'] = info and info.cooldownUntil or nil,
            }
        else
            local dailyWho, which = DailyBlocked(officers, key)
            if dailyWho then
                local vars = {
                    type = label,
                    name = dailyWho.name or '?',
                    max = which == 'day' and DailyCap() or TypeDailyLimit(key),
                }
                local lockKey = which == 'day' and 'board.locked_daily' or 'board.locked_type_daily'
                if dailyWho.src ~= src then lockKey = lockKey .. '_member' end
                card.locked = { reason = CP.L(lockKey, vars), ['until'] = NextDayStart(now), daily = true }
            end
        end
        data.cards[#data.cards + 1] = card
    end
    -- "n mission calls open" (the calls this viewer's unit could claim), from CP.MissionCalls' cache
    if CP.MissionCalls and CP.MissionCalls.claimableCount then
        local _, n = Safe(CP.MissionCalls.claimableCount, src)
        data.callsOpen = tonumber(n) or 0
    end

    if CP.Events and CP.Events.bossCard then
        local _, boss = Safe(CP.Events.bossCard, src)
        data.boss = type(boss) == 'table' and boss or nil
    end
    return data
end

CP.Net.callback('getMissionTypes', function(src)
    return Draw.boardCards(src)
end, { rate = 4 })

-- ============================================================================
--                                    ACCEPT
-- ============================================================================

local function ParseType(payload)
    if type(payload) == 'table' then payload = payload.missionType or payload.type end
    if type(payload) ~= 'string' or #payload == 0 or #payload > 32 then return nil end
    if payload == BOSS_KEY then return payload end
    if Config.MissionTypes and Config.MissionTypes[payload] then return payload end
    return nil
end

local function UnlockUnit(unit)
    if unit and CP.Units and CP.Units.unlock then Safe(CP.Units.unlock, unit) end
end

local function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- Every check of accepting a type, without changing anything: the context for the accept, or false and the
-- error key the officer sees. A mission call claim runs exactly these (CP.MissionCalls). counts (optional):
-- { lastHour = fn(citizenid), today = fn(citizenid, type) } in place of CP.Runs' counts (the calls' cache).
local function CheckAccept(src, typeKey, counts)
    local leader, errKey = GetOfficer(src)
    if not leader then return false, errKey or 'err.not_police' end

    local unit = UnitOf(src)
    if unit then
        if not IsLeader(src) then return false, 'err.not_leader' end
        if unit.locked then return false, 'err.unit_locked' end
    end
    local srcs = UnitMembers(src)
    if #srcs > (tonumber(Config.Limits and Config.Limits.maxUnitSize) or 4) then return false, 'err.unit_too_large' end
    if OperationLocked() then return false, 'err.operation_locked' end

    local isBoss = typeKey == BOSS_KEY
    local missionType = isBoss and 'tactical' or typeKey
    local now = os.time()

    local officers = {}
    for _, m in ipairs(srcs) do
        local o = leader
        if m ~= src then o = GetOfficer(m) end
        if not o then return false, 'err.member_unavailable' end
        officers[#officers + 1] = o
    end

    local max, dayMax, typeDay = HourlyCap(), DailyCap(), TypeDailyLimit(missionType)
    local lastHour = type(counts) == 'table' and counts.lastHour or CompletionsLastHour
    local today = type(counts) == 'table' and counts.today or CompletionsToday
    for _, o in ipairs(officers) do
        local own = o.src == src
        if InArena(o.src) then return false, 'err.in_arena' end
        if OnMission(o.src) then return false, own and 'err.already_on_run' or 'err.member_on_run' end
        if IsOnCall(o.src) then return false, own and 'err.on_call' or 'err.member_on_call' end
        if lastHour(o.citizenid) >= max then
            return false, own and 'err.hourly_cap' or 'err.member_hourly_cap'
        end
        if dayMax > 0 and today(o.citizenid) >= dayMax then
            return false, own and 'err.daily_cap' or 'err.member_daily_cap'
        end
        if typeDay and today(o.citizenid, missionType) >= typeDay then
            return false, own and 'err.type_daily_cap' or 'err.member_type_daily_cap'
        end
        if not isBoss then
            local u = tonumber(CooldownsOf(o.citizenid).types[missionType])
            if u and u > now then return false, own and 'err.type_cooldown' or 'err.member_type_cooldown' end
        end
    end

    if not CapsOk(missionType) then return false, 'err.server_busy' end

    if isBoss then
        if not (CP.Events and CP.Events.bossAvailable) then return false, 'err.boss_unavailable' end
        for _, o in ipairs(officers) do
            local ok, reason = CP.Events.bossAvailable(o.src, o)
            if not ok then
                if reason == 'err.boss_used' and o.src ~= src then return false, 'err.member_boss_used' end
                return false, reason or 'err.boss_unavailable'
            end
        end
    end
    return {
        leader = leader,
        unit = unit,
        srcs = srcs,
        officers = officers,
        isBoss = isBoss,
        missionType = missionType,
        now = now,
    }
end

-- true, or false and the error key: whether src could accept typeKey right now (nothing is changed).
function Draw.check(src, typeKey, counts)
    local ctx, errKey = CheckAccept(src, typeKey, counts)
    if not ctx then return false, errKey end
    return true
end

-- The response target of a claimed mission call: the unit's nearest member to the drawn start (server-side
-- straight line) ÷ speed + grace (Config.MissionCalls.rapidResponse).
local function ResponseTarget(srcs, start)
    local rr = Config.MissionCalls and Config.MissionCalls.rapidResponse or {}
    local best = nil
    for _, m in ipairs(srcs) do
        local c = PedCoords(m)
        local d = c and CP.U.dist(c, start)
        if d and d < math.huge and (not best or d < best) then best = d end
    end
    if not best then return nil, nil end
    local speed = tonumber(rr.speed) or 20.0
    if speed <= 0 then speed = 20.0 end
    return math.floor(best / speed + (tonumber(rr.grace) or 45) + 0.5), math.floor(best + 0.5)
end

-- The draw and the run, after the checks (and the ready check of a unit).
local function FinishAccept(src, typeKey, ctx, opts)
    local unit, srcs, officers = ctx.unit, ctx.srcs, ctx.officers
    local function fail(key)
        UnlockUnit(unit)
        return false, key
    end
    local def, index
    if ctx.isBoss then
        def = CP.Missions and CP.Missions.get(BOSS_ID)
        if not def then return fail('err.boss_unavailable') end
        local ok, why = Eligibility(def, officers, #officers, ctx.now)
        if not ok then return fail(why == 'cooldown' and 'err.boss_cooldown' or 'err.boss_not_eligible') end
        index = Draw.pickLocation(def, srcs, Rng())
        if not index then return fail('err.no_location') end
    else
        local near = opts.nearCoords
        if near == nil and opts.missionCall and not opts.area then
            near = {}
            for _, m in ipairs(srcs) do near[#near + 1] = PedCoords(m) end
        end
        local second
        def, second = Draw.draw(ctx.missionType, officers, { participants = srcs, area = opts.area, nearCoords = near })
        if not def then return fail(second or 'err.pool_empty') end
        index = second
    end

    if not (CP.Runs and CP.Runs.create) then return fail('err.run_create_failed') end
    -- The draw may yield (history lookups): a member who disconnected meanwhile had no run for playerDropped
    -- to leave, so they are refused here (CP.Runs.create checks again after its own lookups).
    for _, m in ipairs(srcs) do
        if GetPlayerName(m) == nil then return fail('err.member_unavailable') end
    end
    local missionCall = nil
    if type(opts.missionCall) == 'table' then
        missionCall = CP.U.copy(opts.missionCall)
        if missionCall.targetS == nil then
            missionCall.targetS, missionCall.distance = ResponseTarget(srcs, LocationStart(def, index))
        end
    end
    -- Provisional reservation so a concurrent accept can't take the spot before CP.Runs reserves it.
    local token = ('%s%d:%d'):format(PENDING_PREFIX, src, GetGameTimer())
    Reserve(token, def.id, index, LocationStart(def, index))
    local okCall, run, createErr = pcall(CP.Runs.create, {
        mission = def,
        locationIndex = index,
        missionType = ctx.missionType,
        members = officers,
        leaderSrc = src,
        operationId = nil,
        test = nil,
        isBoss = def.isBoss == true,
        missionCall = missionCall,
    })
    Draw.release(token)
    if not okCall then
        CP.err(TAG, 'CP.Runs.create failed: %s', tostring(run))
        return fail('err.run_create_failed')
    end
    if type(run) ~= 'table' then return fail(createErr or 'err.run_create_failed') end
    if run.id and not byHolder[run.id] then Draw.reserve(run.id, def.id, index) end
    for _, o in ipairs(officers) do Draw.recordLocation(o.citizenid, def.id, index) end
    CP.log(TAG, '%s accepted %s: %s #%d (run %s, %d officer(s))', tostring(src), typeKey, def.id, index,
        tostring(run.id), #officers)
    return true,
        {
            runId = run.id,
            missionId = def.id,
            locationIndex = index,
            targetS = missionCall and missionCall.targetS or nil,
            distance = missionCall and missionCall.distance or nil,
        }
end

-- Accepting a type (the Mission Board, or a mission call that won its claim). opts: area, nearCoords,
-- missionCall ({ id, code, area, staff }; the response target is set here from the drawn start), onDone
-- (called with ok, data|errKey, srcs only when a unit's ready check made the accept wait).
-- Returns true, { runId } or true, { pending = true } while a unit of 2+ answers the ready check.
local function Accept(src, typeKey, opts)
    opts = type(opts) == 'table' and opts or {}
    local ctx, errKey = CheckAccept(src, typeKey)
    if not ctx then return false, errKey end
    local unit, srcs = ctx.unit, ctx.srcs

    -- Invites close now: the draw depends on the unit's size and every member's cooldowns.
    if unit and CP.Units and CP.Units.lock then Safe(CP.Units.lock, unit) end
    -- The checks above may yield (database lookups): an invite accepted meanwhile would put an officer in
    -- the locked unit who is not on the run and was never checked (docs/notes/teams.md). The unit must still
    -- be exactly the members that were checked; otherwise the leader tries again.
    if unit then
        local now2 = UnitMembers(src)
        local same = #now2 == #srcs
        if same then
            local set = {}
            for _, m in ipairs(srcs) do set[m] = true end
            for _, m in ipairs(now2) do if not set[m] then same = false break end end
        end
        -- (a forming unit, leader + pending invites, dissolves at lock: then unitOf is nil and members { src })
        local after = UnitOf(src)
        if after ~= nil and after ~= unit then same = false end
        if not same then
            CP.log(TAG, 'unit of %s changed during the accept; refused', tostring(src))
            UnlockUnit(unit)
            return false, 'err.busy'
        end
    end

    -- ---- THE READY CHECK (CP.Units, units of 2+; without it the draw follows at once) ----
    local readyCheck = CP.Units and CP.Units.readyCheck
    local wantCheck = not (Config.Units and Config.Units.readyCheck == false)
    if unit and #srcs >= 2 and wantCheck and type(readyCheck) == 'function' and not opts.noReadyCheck then
        local answered = false
        local function done(ok, data, who)
            if answered then return end
            answered = true
            if type(opts.onDone) == 'function' then
                local okCb, err = pcall(opts.onDone, ok, data, who)
                if not okCb then CP.err(TAG, 'accept callback failed: %s', tostring(err)) end
            end
        end
        local function onReady()
            CreateThread(function()
                -- the members answered: check them again, the unit stayed locked meanwhile
                for _, o in ipairs(ctx.officers) do
                    local own = o.src == src
                    if IsOnCall(o.src) then
                        UnlockUnit(unit)
                        return done(false, own and 'err.on_call' or 'err.member_on_call')
                    end
                end
                if OperationLocked() then
                    UnlockUnit(unit)
                    return done(false, 'err.operation_locked')
                end
                local okCall, ok, data = pcall(FinishAccept, src, typeKey, ctx, opts)
                if not okCall then
                    CP.err(TAG, 'accept after the ready check failed: %s', tostring(ok))
                    UnlockUnit(unit)
                    return done(false, 'err.internal')
                end
                done(ok, data)
            end)
        end
        local function onCancel(reasonKey, who)
            UnlockUnit(unit)
            done(false, type(reasonKey) == 'string' and reasonKey or 'err.ready_declined', who)
        end
        local okRc, res = pcall(readyCheck, unit, typeKey, onReady, onCancel)
        if okRc and res ~= false then return true, { pending = true } end
        CP.warn(TAG, 'the ready check could not start (%s); the draw follows at once', tostring(res))
    end
    return FinishAccept(src, typeKey, ctx, opts)
end
Draw.accept = Accept

CP.Net.action('server:acceptType', function(src, payload)
    local typeKey = ParseType(payload)
    if not typeKey then return false, 'err.invalid_type' end
    if not CP.Net.rateOk(src, 'draw:acceptType', 1, 1500) then return false, 'err.rate_limited' end

    local srcs = UnitMembers(src)
    for _, m in ipairs(srcs) do
        if inFlight[m] then return false, 'err.busy' end
    end
    for _, m in ipairs(srcs) do inFlight[m] = true end
    local okCall, ok, data = pcall(Accept, src, typeKey)
    for _, m in ipairs(srcs) do inFlight[m] = nil end
    if not okCall then
        CP.err(TAG, 'server:acceptType failed: %s', tostring(ok))
        local unit = UnitOf(src)
        if unit and unit.locked and not OnMission(src) then UnlockUnit(unit) end
        return false, 'err.internal'
    end
    return ok, data
end, { rate = 3 })

-- ============================================================================
--                                LOCATION STATS
-- ============================================================================
-- Admin UI → Missions and Testing: how often each location of a mission was played, and when last. Rows
-- are per participant, so they are grouped by run first (no COUNT(DISTINCT ...) in the saves folder engine).

function Draw.locationStats(missionId)
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(missionId)
    if not def then return nil, 'err.draw_unknown_mission' end
    CP.Migrations.ready()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT run_uuid, location_index, UNIX_TIMESTAMP(MAX(created_at)) AS last_ts FROM cp_mission_runs
        WHERE mission_id = ? AND location_index IS NOT NULL GROUP BY run_uuid, location_index
    ]], { missionId })
    if not ok then
        CP.err(TAG, 'location stats of %s failed: %s', tostring(missionId), tostring(rows))
        return nil, 'err.internal'
    end
    local byIndex = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local i = math.tointeger(CP.U.num(r.location_index))
        if i then
            local e = byIndex[i] or { plays = 0, lastPlayed = nil }
            byIndex[i] = e
            e.plays = e.plays + 1
            local ts = CP.U.num(r.last_ts)
            if ts > 0 and (not e.lastPlayed or ts > e.lastPlayed) then e.lastPlayed = math.floor(ts) end
        end
    end
    local out = {}
    for i, loc in ipairs(def.locations or {}) do
        local e = byIndex[i] or {}
        out[#out + 1] = {
            index = i,
            label = type(loc) == 'table' and loc.label or ('#' .. i),
            plays = e.plays or 0,
            lastPlayed = e.lastPlayed,
            area = LocationArea(def, i),
        }
    end
    return out
end

CP.Net.callback('admin:getLocationStats', function(src, args)
    if not (CP.Permissions and CP.Permissions.can) then return nil, 'err.no_permission' end
    local okP, eP = CP.Permissions.can(src, 'openAdmin')
    if not okP then return nil, eP or 'err.no_permission' end
    local missionId = type(args) == 'table' and args.missionId or nil
    if type(missionId) ~= 'string' or missionId == '' or #missionId > 64 then return nil, 'err.invalid_payload' end
    return Draw.locationStats(missionId)
end, { rate = 3 })

AddEventHandler('playerDropped', function()
    local src = source
    inFlight[src] = nil
end)

-- Safety net: drop provisional reservations that outlived their accept, and reservations of runs
-- the engine no longer knows (CP.Runs releases its own on cleanup; this only catches leaks).
CreateThread(function()
    while true do
        Wait(60000)
        local now = os.time()
        for holder, h in pairs(byHolder) do
            if type(holder) == 'string' and holder:sub(1, #PENDING_PREFIX) == PENDING_PREFIX then
                if now - h.at > 60 then Draw.release(holder) end
            elseif now - h.at > 120 and CP.Runs and CP.Runs.get then
                local ok, run = pcall(CP.Runs.get, holder)
                if ok and run == nil then
                    CP.log(TAG, 'released a stale reservation of run %s', tostring(holder))
                    Draw.release(holder)
                end
            end
        end
        PruneRecent(now)
        local fresh = tonumber(Config.Draw and Config.Draw.locationFreshness) or 0
        for missionId, byIndex in pairs(usedAt) do
            for i, at in pairs(byIndex) do
                if now - at >= fresh then byIndex[i] = nil end
            end
            if next(byIndex) == nil then usedAt[missionId] = nil end
        end
    end
end)
