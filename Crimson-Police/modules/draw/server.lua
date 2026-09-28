-- modules/draw/server.lua · CP.Draw: mission pools, the random draw, locations and the Mission Board.
--
-- Owns
--   * the pool of a mission type for an officer or unit: published, enabled, of that type, open to
--     every member's department, supporting the unit's size, off per-mission cooldown for every member
--   * the random draw with the no-repeat rules (cp_mission_runs history: the last completed or
--     abandoned missions of that type per citizenid, union over the unit; Config.Draw.avoidLast, and
--     avoidLastLarge with largePool+ missions in the pool; a pool of one may repeat)
--   * location picking (reserved spots skipped; spots with a non-participant player within
--     Config.Draw.playerClearance skipped while another spot is free; server-side ped coords) and the
--     location reservations (several holders per spot are allowed so a test run can still reserve)
--   * the Mission Board data (BoardData, ARCHITECTURE §9.4) and the accept of a mission type
--
-- Public API (server)
--   CP.Draw.pool(missionType, members) -> { def, ... }, reasonKey|nil, info   members = officers (§3.1) or srcs
--       reasonKey: 'board.locked_empty' | 'board.locked_empty_solo' | 'board.locked_mission_cooldown'
--       info = { cooldownUntil = ts|nil } (earliest per-mission cooldown end when that emptied the pool)
--   CP.Draw.draw(missionType, members, opts) -> def, locationIndex | nil, errKey
--       opts = { rng = CP.U.rng(...), participants = { src... } }; errKeys err.pool_empty,
--       err.pool_cooldown, err.no_location
--   CP.Draw.pickLocation(def, participantSrcs, rng, opts) -> index|nil     opts = { exclude = { [index] = true } }
--   CP.Draw.reserve(runId, missionId, index) -> wasFree
--   CP.Draw.release(runId) -> boolean
--   CP.Draw.isReserved(missionId, index) -> boolean
--   CP.Draw.recordLast(citizenid, missionType, missionId)   (CP.Runs: a completed or abandoned row was written)
--   CP.Draw.boardCards(src) -> BoardData | nil, errKey
-- Net
--   callback 'getMissionTypes' -> BoardData
--   action 'server:acceptType' (payload = a Config.MissionTypes key, or 'weekly_boss') -> { runId }
--       leader only; every member must be an officer (CP.Access.getOfficer), carry no foreign
--       crimsonArena flag (err.in_arena), have no active run, not be on a real call, be under the hourly
--       cap and off the type cooldown; server caps (CP.Runs.capsOk); refused while a Cross-Department
--       Mission is active; the Weekly Boss also needs CP.Events.bossAvailable for every member.
--       Then CP.Units.lock(unit), the draw, CP.Runs.create (the unit is unlocked again on failure).
-- Internal (same slice): CP.Draw._eligibility(def, officers, size?, now?) -> ok, why, untilTs, officer
--
-- Contract interpretations (details in docs/notes/engine_a.md)
--   * history = distinct missions of the type with state completed/abandoned (failed rows and the Weekly
--     Boss never count); a unit whose histories cover the whole pool relaxes to avoidLast, then to "not the
--     unit's most recent mission", then the whole pool; no fallback to avoided missions for locations
--   * board: points = best CP.Scoring.P in the pool, cash = CP.Cash.range(key, officers) (fallback from
--     payouts x tier); locked priority member unavailable > type cooldown > hourly cap > empty pool
--   * the Weekly Boss is not blocked by the Tactical type cooldown (it has no type), everything else applies
--   * capsOk failures are reported as err.server_busy; CP.Access / CP.Runs.create error keys pass through

CP.Draw = CP.Draw or {}
local Draw = CP.Draw

local TAG = 'draw'
local BOSS_ID = 'weekly_boss_kingpin'
local BOSS_KEY = 'weekly_boss'
local RECENT_KEEP_S = 900            -- in-memory history is only a bridge until the row is in the DB
local MEM_SEQ_BASE = 2 ^ 40          -- in-memory records sort after DB rows of the same second
local PENDING_PREFIX = 'pending:'

local holders = {}     -- holders[missionId][index] = { [holderId] = true }
local byHolder = {}    -- byHolder[holderId] = { missionId, index, at }
local recent = {}      -- recent[citizenid][missionType] = { { missionId, at, seq }, ... } newest first
local inFlight = {}    -- inFlight[src] = true while an accept for that player is being processed
local memSeq = 0
local drawRng = nil

-- ── helpers ─────────────────────────────────────────────────────────────────
local function rng()
    if not drawRng then
        local seed = os.time() ~ (GetGameTimer and GetGameTimer() or 0) ~ CP.U.hash(tostring({}))
        drawRng = CP.U.rng(seed & 0x7FFFFFFF)
    end
    return drawRng
end

local function safe(fn, ...)
    if type(fn) ~= 'function' then return false, nil end
    local ok, a, b, c = pcall(fn, ...)
    if not ok then
        CP.err(TAG, 'call failed: %s', tostring(a))
        return false, nil
    end
    return true, a, b, c
end

local function getOfficer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    return CP.Access.getOfficer(src)
end

local function unitOf(src)
    if not (CP.Units and CP.Units.unitOf) then return nil end
    local _, unit = safe(CP.Units.unitOf, src)
    return type(unit) == 'table' and unit or nil
end

local function unitMembers(src)
    if CP.Units and CP.Units.members then
        local _, list = safe(CP.Units.members, src)
        if type(list) == 'table' and #list > 0 then return list end
    end
    return { src }
end

local function isLeader(src)
    if not unitOf(src) then return true end   -- a solo officer leads themselves
    if not (CP.Units and CP.Units.isLeader) then return false end
    local _, leader = safe(CP.Units.isLeader, src)
    return leader == true
end

local function operationLocked()
    if not (CP.Operations and CP.Operations.isLocked) then return false end
    local _, locked = safe(CP.Operations.isLocked)
    return locked == true
end

local function isOnCall(src)
    if not (CP.Calls and CP.Calls.isOnCall) then return false end
    local _, onCall = safe(CP.Calls.isOnCall, src)
    return onCall == true
end

local function onMission(src)
    if not CP.Runs then return false end
    if CP.Runs.isOnMission then
        local _, on = safe(CP.Runs.isOnMission, src)
        if on then return true end
    end
    if CP.Runs.getBySrc then
        local _, run = safe(CP.Runs.getBySrc, src)
        if run then return true end
    end
    return false
end

local function capsOk(missionType)
    if not (CP.Runs and CP.Runs.capsOk) then return true end
    local ok, capOk = safe(CP.Runs.capsOk, missionType)
    if not ok then return true end
    return capOk ~= false
end

local function cooldownsOf(citizenid)
    if CP.Runs and CP.Runs.cooldowns then
        local _, cd = safe(CP.Runs.cooldowns, citizenid)
        if type(cd) == 'table' then
            cd.types = type(cd.types) == 'table' and cd.types or {}
            cd.missions = type(cd.missions) == 'table' and cd.missions or {}
            return cd
        end
    end
    return { types = {}, missions = {} }
end

local function completionsLastHour(citizenid)
    if not (CP.Runs and CP.Runs.completionsLastHour) then return 0 end
    local _, n = safe(CP.Runs.completionsLastHour, citizenid)
    return tonumber(n) or 0
end

local function hourlyCap()
    return tonumber(Config.Limits and Config.Limits.maxCompletionsHour) or 8
end

local function toOfficers(members)
    local out = {}
    for _, m in ipairs(members or {}) do
        if type(m) == 'table' and m.citizenid then
            out[#out + 1] = m
        elseif tonumber(m) then
            local o = getOfficer(tonumber(m))
            if o then out[#out + 1] = o end
        end
    end
    return out
end

local function srcsOf(officers)
    local out = {}
    for _, o in ipairs(officers) do out[#out + 1] = o.src end
    return out
end

local function typeKeysByPoints()
    local keys = CP.U.keys(Config.MissionTypes or {})
    table.sort(keys, function(a, b)
        local pa = tonumber(Config.MissionTypes[a].points) or 0
        local pb = tonumber(Config.MissionTypes[b].points) or 0
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return keys
end

local function typeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return (t and t.label) or tostring(key)
end

-- ── eligibility and pool ────────────────────────────────────────────────────
-- ok, why ('disabled'|'size'|'department'|'cooldown'), untilTs (cooldown), officer (who blocks it)
local function eligibility(def, officers, size, now)
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
        local u = tonumber(cooldownsOf(o.citizenid).missions[def.id])
        if u and u > now and (not untilTs or u > untilTs) then untilTs, who = u, o end
    end
    if untilTs then return false, 'cooldown', untilTs, who end
    return true
end
Draw._eligibility = eligibility

function Draw.pool(missionType, members)
    local officers = toOfficers(members)
    local size = math.max(#(members or {}), #officers)
    if size < 1 then size = 1 end
    local list, cooldownUntil = {}, nil
    local byType = (CP.Missions and CP.Missions.byType and CP.Missions.byType(missionType)) or {}
    local now = os.time()
    for _, def in ipairs(byType) do
        local ok, why, untilTs = eligibility(def, officers, size, now)
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

-- ── history (no-repeat) ─────────────────────────────────────────────────────
local function pruneRecent(now)
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
local function historyFor(citizenid, missionType)
    CP.Migrations.ready()
    local rows = MySQL.query.await(
        "SELECT mission_id, UNIX_TIMESTAMP(MAX(created_at)) AS last_ts, MAX(id) AS last_id FROM cp_mission_runs WHERE citizenid = ? AND mission_type = ? AND state IN ('completed', 'abandoned') AND mission_id <> ? GROUP BY mission_id",
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

-- ── locations ───────────────────────────────────────────────────────────────
function Draw.reserve(runId, missionId, index)
    index = tonumber(index)
    if runId == nil or type(missionId) ~= 'string' or not index then return false end
    index = math.floor(index)
    Draw.release(runId)
    local byIdx = holders[missionId] or {}
    holders[missionId] = byIdx
    local set = byIdx[index] or {}
    byIdx[index] = set
    local wasFree = next(set) == nil
    set[runId] = true
    byHolder[runId] = { missionId = missionId, index = index, at = os.time() }
    CP.log(TAG, 'reserved %s #%d for %s', missionId, index, tostring(runId))
    return wasFree
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
    local byIdx = holders[missionId]
    local set = byIdx and byIdx[tonumber(index)]
    return set ~= nil and next(set) ~= nil
end

-- Coordinates of every player who is not a participant (server-side ped coords).
local function otherPlayerCoords(participants)
    local out = {}
    for _, id in ipairs(GetPlayers() or {}) do
        local s = tonumber(id)
        if s and not participants[s] then
            local ped = GetPlayerPed(s)
            if ped and ped ~= 0 then
                local c = GetEntityCoords(ped)
                if c then out[#out + 1] = c end
            end
        end
    end
    return out
end

function Draw.pickLocation(def, participantSrcs, rngObj, opts)
    opts = opts or {}
    if type(def) ~= 'table' or type(def.locations) ~= 'table' or #def.locations == 0 then return nil end
    local r = rngObj or rng()
    local reserveOn = not (Config.Limits and Config.Limits.reserveLocations == false)
    local participants = {}
    for _, s in ipairs(participantSrcs or {}) do
        local n = tonumber(type(s) == 'table' and s.src or s)
        if n then participants[n] = true end
    end
    local free = {}
    for i = 1, #def.locations do
        local skip = (reserveOn and Draw.isReserved(def.id, i)) or (opts.exclude and opts.exclude[i])
        if not skip then free[#free + 1] = i end
    end
    if #free == 0 then return nil end
    local clearance = tonumber(Config.Draw and Config.Draw.playerClearance) or 0
    if clearance > 0 and #free > 1 then
        local others = otherPlayerCoords(participants)
        if #others > 0 then
            local clear = {}
            for _, i in ipairs(free) do
                local start = def.locations[i].start
                local c = start and start.coords
                local near = false
                for _, pc in ipairs(others) do
                    if CP.U.dist(c, pc) <= clearance then near = true; break end
                end
                if not near then clear[#clear + 1] = i end
            end
            if #clear > 0 then free = clear end
        end
    end
    local index = r:pick(free)
    return index
end

-- ── draw ────────────────────────────────────────────────────────────────────
function Draw.draw(missionType, members, opts)
    opts = opts or {}
    local officers = toOfficers(members)
    local list, reason = Draw.pool(missionType, members)
    if #list == 0 then
        return nil, reason == 'board.locked_mission_cooldown' and 'err.pool_cooldown' or 'err.pool_empty'
    end

    local candidates = list
    local cfg = Config.Draw or {}
    local avoidLast = math.max(0, math.floor(tonumber(cfg.avoidLast) or 1))
    local k = avoidLast
    if #list >= (tonumber(cfg.largePool) or 4) then
        k = math.max(avoidLast, math.floor(tonumber(cfg.avoidLastLarge) or 2))
    end
    if #list > 1 and k > 0 then
        local hist = {}
        for i, o in ipairs(officers) do hist[i] = historyFor(o.citizenid, missionType) end
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
        candidates = without(lastN(k))
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
    end

    local r = opts.rng or rng()
    local participants = opts.participants or srcsOf(officers)
    for _, def in ipairs(r:shuffle(candidates)) do
        local index = Draw.pickLocation(def, participants, r, opts)
        if index then
            CP.log(TAG, 'drew %s #%d for %s (%d candidates of %d)', def.id, index, missionType, #candidates, #list)
            return def, index
        end
    end
    return nil, 'err.no_location'
end

-- ── Mission Board ───────────────────────────────────────────────────────────
local function cardCash(key, officers, list, size)
    if CP.Cash and CP.Cash.range then
        local ok, lo, hi = safe(CP.Cash.range, key, officers)
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
            local ok, b = safe(CP.Payouts.baseFor, def)
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

local function cardPoints(key, list)
    local best
    for _, def in ipairs(list) do
        local p
        if CP.Scoring and CP.Scoring.P then
            local ok, v = safe(CP.Scoring.P, def)
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

local function typeCooldown(officers, key, now)
    local untilTs, who
    for _, o in ipairs(officers) do
        local u = tonumber(cooldownsOf(o.citizenid).types[key])
        if u and u > now and (not untilTs or u > untilTs) then untilTs, who = u, o end
    end
    return untilTs, who
end

local function hourlyBlocked(officers)
    local max = hourlyCap()
    for _, o in ipairs(officers) do
        if completionsLastHour(o.citizenid) >= max then return o end
    end
    return nil
end

function Draw.boardCards(src)
    local viewer, errKey = getOfficer(src)
    if not viewer then return nil, errKey or 'err.not_police' end

    local srcs = unitMembers(src)
    local size = #srcs
    local officers, missing = {}, false
    for _, m in ipairs(srcs) do
        local o = (m == src) and viewer or getOfficer(m)
        if o then officers[#officers + 1] = o else missing = true end
    end

    local activeRunId = nil
    if CP.Runs and CP.Runs.getBySrc then
        local _, run = safe(CP.Runs.getBySrc, src)
        if type(run) == 'table' then activeRunId = run.id end
    end

    local data = {
        cards = {},
        boss = nil,
        operation = nil,
        unit = { size = size, isLeader = isLeader(src) },
        activeRunId = activeRunId,
    }

    -- While a Cross-Department Mission is active the board shows only its card.
    if operationLocked() then
        if CP.Operations.boardCard then
            local _, card = safe(CP.Operations.boardCard, src)
            data.operation = type(card) == 'table' and card or nil
        end
        return data
    end

    local now = os.time()
    local tod = CP.Events and CP.Events.typeOfTheDay and CP.Events.typeOfTheDay() or nil
    local onCall = false
    for _, m in ipairs(srcs) do
        if isOnCall(m) then onCall = true; break end
    end
    local hourlyWho = hourlyBlocked(officers)

    for _, key in ipairs(typeKeysByPoints()) do
        local label = typeLabel(key)
        local list, reasonKey, info = Draw.pool(key, missing and srcs or officers)
        local card = {
            key = key,
            label = label,
            points = cardPoints(key, list),
            cash = cardCash(key, officers, list, size),
            pool = #list,
            mode = size > 1 and 'unit' or 'solo',
            locked = nil,
            busy = not capsOk(key),
            onCall = onCall,
            typeOfTheDay = tod == key,
        }
        local cdUntil, cdWho = typeCooldown(officers, key, now)
        if missing then
            card.locked = { reason = CP.L('board.member_unavailable') }
        elseif cdUntil then
            if cdWho.src == src then
                card.locked = { reason = CP.L('board.locked_cooldown', { type = label }), ['until'] = cdUntil }
            else
                card.locked = { reason = CP.L('board.locked_cooldown_member', { type = label, name = cdWho.name or '?' }), ['until'] = cdUntil }
            end
        elseif hourlyWho then
            if hourlyWho.src == src then
                card.locked = { reason = CP.L('board.locked_hourly', { max = hourlyCap() }) }
            else
                card.locked = { reason = CP.L('board.locked_hourly_member', { name = hourlyWho.name or '?', max = hourlyCap() }) }
            end
        elseif #list == 0 then
            card.locked = { reason = CP.L(reasonKey, { type = label, size = size }), ['until'] = info and info.cooldownUntil or nil }
        end
        data.cards[#data.cards + 1] = card
    end

    if CP.Events and CP.Events.bossCard then
        local _, boss = safe(CP.Events.bossCard, src)
        data.boss = type(boss) == 'table' and boss or nil
    end
    return data
end

CP.Net.callback('getMissionTypes', function(src)
    return Draw.boardCards(src)
end, { rate = 4 })

-- ── accept ──────────────────────────────────────────────────────────────────
local function parseType(payload)
    if type(payload) == 'table' then payload = payload.missionType or payload.type end
    if type(payload) ~= 'string' or #payload == 0 or #payload > 32 then return nil end
    if payload == BOSS_KEY then return payload end
    if Config.MissionTypes and Config.MissionTypes[payload] then return payload end
    return nil
end

local function unlockUnit(unit)
    if unit and CP.Units and CP.Units.unlock then safe(CP.Units.unlock, unit) end
end

local function accept(src, typeKey)
    local leader, errKey = getOfficer(src)
    if not leader then return false, errKey or 'err.not_police' end

    local unit = unitOf(src)
    if unit then
        if not isLeader(src) then return false, 'err.not_leader' end
        if unit.locked then return false, 'err.unit_locked' end
    end
    local srcs = unitMembers(src)
    if #srcs > (tonumber(Config.Limits and Config.Limits.maxUnitSize) or 4) then return false, 'err.unit_too_large' end
    if operationLocked() then return false, 'err.operation_locked' end

    local isBoss = typeKey == BOSS_KEY
    local missionType = isBoss and 'tactical' or typeKey
    local now = os.time()

    local officers = {}
    for _, m in ipairs(srcs) do
        local o = leader
        if m ~= src then o = getOfficer(m) end
        if not o then return false, 'err.member_unavailable' end
        officers[#officers + 1] = o
    end

    local max = hourlyCap()
    for _, o in ipairs(officers) do
        local own = o.src == src
        if CP.Alerts and CP.Alerts.foreignFlag then
            local _, foreign = safe(CP.Alerts.foreignFlag, o.src)
            if foreign then return false, 'err.in_arena' end
        end
        if onMission(o.src) then return false, own and 'err.already_on_run' or 'err.member_on_run' end
        if isOnCall(o.src) then return false, own and 'err.on_call' or 'err.member_on_call' end
        if completionsLastHour(o.citizenid) >= max then return false, own and 'err.hourly_cap' or 'err.member_hourly_cap' end
        if not isBoss then
            local u = tonumber(cooldownsOf(o.citizenid).types[missionType])
            if u and u > now then return false, own and 'err.type_cooldown' or 'err.member_type_cooldown' end
        end
    end

    if not capsOk(missionType) then return false, 'err.server_busy' end

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

    -- Invites close now: the draw depends on the unit's size and every member's cooldowns.
    if unit and CP.Units and CP.Units.lock then safe(CP.Units.lock, unit) end
    local function fail(key)
        unlockUnit(unit)
        return false, key
    end

    local def, index
    if isBoss then
        def = CP.Missions and CP.Missions.get(BOSS_ID)
        if not def then return fail('err.boss_unavailable') end
        local ok, why = eligibility(def, officers, #officers, now)
        if not ok then return fail(why == 'cooldown' and 'err.boss_cooldown' or 'err.boss_not_eligible') end
        index = Draw.pickLocation(def, srcs, rng())
        if not index then return fail('err.no_location') end
    else
        local second
        def, second = Draw.draw(missionType, officers, { participants = srcs })
        if not def then return fail(second or 'err.pool_empty') end
        index = second
    end

    if not (CP.Runs and CP.Runs.create) then return fail('err.run_create_failed') end
    -- Provisional reservation so a concurrent accept can't take the spot before CP.Runs reserves it.
    local token = ('%s%d:%d'):format(PENDING_PREFIX, src, GetGameTimer())
    Draw.reserve(token, def.id, index)
    local okCall, run, createErr = pcall(CP.Runs.create, {
        mission = def,
        locationIndex = index,
        missionType = missionType,
        members = officers,
        leaderSrc = src,
        operationId = nil,
        test = nil,
        isBoss = def.isBoss == true,
    })
    Draw.release(token)
    if not okCall then
        CP.err(TAG, 'CP.Runs.create failed: %s', tostring(run))
        return fail('err.run_create_failed')
    end
    if type(run) ~= 'table' then return fail(createErr or 'err.run_create_failed') end
    if run.id and not byHolder[run.id] then Draw.reserve(run.id, def.id, index) end
    CP.log(TAG, '%s accepted %s: %s #%d (run %s, %d officer(s))', tostring(src), typeKey, def.id, index, tostring(run.id), #officers)
    return true, { runId = run.id }
end

CP.Net.action('server:acceptType', function(src, payload)
    local typeKey = parseType(payload)
    if not typeKey then return false, 'err.invalid_type' end
    if not CP.Net.rateOk(src, 'draw:acceptType', 1, 1500) then return false, 'err.rate_limited' end

    local srcs = unitMembers(src)
    for _, m in ipairs(srcs) do
        if inFlight[m] then return false, 'err.busy' end
    end
    for _, m in ipairs(srcs) do inFlight[m] = true end
    local okCall, ok, data = pcall(accept, src, typeKey)
    for _, m in ipairs(srcs) do inFlight[m] = nil end
    if not okCall then
        CP.err(TAG, 'server:acceptType failed: %s', tostring(ok))
        local unit = unitOf(src)
        if unit and unit.locked and not onMission(src) then unlockUnit(unit) end
        return false, 'err.internal'
    end
    return ok, data
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
        pruneRecent(now)
    end
end)
