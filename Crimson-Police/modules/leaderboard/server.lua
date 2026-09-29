-- modules/leaderboard/server.lua · CP.Leaderboard (server): the four time-boxed boards, their cache,
-- the weekly/monthly recognition, public and own profiles, the hide-name privacy toggle and the admin
-- board view (cash paid per officer, payments stuck in paying).
--
-- Owns
--   * callbacks getBoard, getProfile, admin:getBoards and the action server:setHideName
--   * the in-memory board cache (Config.Leaderboard.cacheSeconds) per (period, filter, department, window)
--   * the weekly reset job: top 3 of the week that just ended -> board webhook (cp_webhook_board) and the
--     "Officer of the Week" badge officer_of_week_<weekKey> (idempotent; also run as a catch-up after start)
--   * Home announcements: top 3 of the previous week and of the previous month
--
-- Board rules (SPEC "Leaderboards")
--   points  = SUM(final_points) of counted rows (voided = 0 AND flagged = 0) in the window and filter
--   runs    = completed runs (mission_type not 'manual_award'/'goal'), failed = failed runs (counted rows)
--   windows = weekly: CP.Schedule.weekStart .. now; monthly: CP.Schedule.monthStart .. now;
--             season: rows with season_id of the active season (or the last ended one until a new starts);
--             alltime: cp_officers.xp (Overall filter only; runs/failed from cp_mission_runs + archive)
--   filters = overall | <Config.MissionTypes key> | unit (participants >= 2) | cross (departments_n >= 2)
--             | department (row department = args.department). manual_award and goal rows only count
--             toward overall and department.
--   ranking = points desc, fewer failed, then who reached the total first (latest counted row that
--             changed the total, ascending), then citizenid. Minimum Config.Leaderboard.minRunsToRank
--             completed runs in the board's own window and filter. Top Config.Leaderboard.topN rows.
--   privacy = hide_name officers show their callsign (or leaderboard.hidden_name) instead of their name;
--             cash is never on public boards.
--
-- Public API (docs/ARCHITECTURE.md §5.22)
--   callback getBoard({ period, filter, department? }) -> Board (§9.4) plus
--       { department?, minRuns, topN, ranked, window = { from, to|nil }, season = { id, name }|nil }
--       me = the viewer's row; rank 0 when they do not have minRuns completed runs yet (never nil for
--       an officer). errKeys: the CP.Access.getOfficer keys, err.invalid_period, err.invalid_filter,
--       err.unknown_department, err.invalid_payload
--   callback getProfile(citizenid | { citizenid } | nil) -> Profile (§9.4) plus
--       { departmentLabel, seasonPoints, disputeWindowHours, badges[i].kind }
--       own = nil or the viewer's citizenid: cash, cash status and the breakdown's cash block are only in
--       the own profile. runs = the last 20 rows (manual awards and goal rewards included, labelled).
--       canDispute = CP.Disputes.eligible(row, viewer, now) (own row, flagged or voided or failed, not an award
--       row, created within Config.Disputes.windowHours; the same rule server:dispute applies) and no cp_disputes
--       row at all for it (one dispute per row, ever). errKeys: err.unknown_officer, err.invalid_payload
--   action server:setHideName (boolean | { hideName = boolean }) -> { hideName }
--   callback admin:getBoards({ period, filter, department?, citizenid? })   (CP.Permissions 'openAdmin')
--       -> { period, filter, department?, rows = ranked rows + { cash, realName, hidden },
--            unranked = the same for officers below minRuns, stuck = payments still in 'paying'
--            (CP.Cash.stuckPayments(), normalised to { rowId, runUuid, citizenid, name, callsign,
--            missionLabel, amount, createdAt, transId }), minRuns, updatedAt, window, season,
--            runs = that officer's rows in the window/filter when citizenid is given }
--   CP.Leaderboard.invalidate()                      (hook: void/approve/new rows) drops every cache
--                                                    and calls CP.Challenge.invalidate()
--   CP.Leaderboard.seasonPoints(citizenid) -> number counted points in the active season
--   CP.Leaderboard.announcements() -> { { kind = 'weekly_top3'|'monthly_top3', text, entries }, ... }
--   CP.Leaderboard.ranking(opts) -> ranked, byCitizen   (slice helper, used by CP.Challenge at season end)
--       opts = { period = 'weekly'|'monthly'|'season'|'alltime'|'range', filter, department,
--                from, to (range), seasonId (season), fresh }
--   CP.Leaderboard.missionLabel(missionType, missionId, breakdown) -> text   (slice helper)
--   CP.Leaderboard.publicName(entry) -> text        (slice helper: privacy-aware display name)
--   CP.Leaderboard.badgeLabel(badgeId) -> label|nil, kind   label of this module's badge ids (officer_of_week_<week>,
--       season_<id>_champion, season_<id>_top10); nil (kind 'achievement') for any other id
-- Test hooks: CP.Leaderboard._weeklyJob(prevStartTs, curStartTs), CP.Leaderboard._boot()

CP.Leaderboard = CP.Leaderboard or {}
local LB = CP.Leaderboard
local U = CP.U
local TAG = 'leaderboard'

local PERIODS = { weekly = true, monthly = true, season = true, alltime = true }
local EXTRA_FILTERS = { overall = true, unit = true, cross = true, department = true }
local AWARD_TYPES = { manual_award = true, goal = true }
local PROFILE_RUNS = 20
local ADMIN_RUNS = 100
local BOOT_DELAY_MS = 1000
local CATCHUP_DELAY_MS = 60000
local HALF_DAY = 43200

local cache = {}          -- key -> { at, ranked, all, updatedAt, meta }
local inflight = {}       -- key -> { p = promise, gen = generation }
local generation = 0      -- bumped by invalidate(): a board computed before it is never cached
local seasonPointsCache = {}   -- citizenid -> { at, value }
local announceCache = nil      -- { at, key, list }
local booted = false

-- ── small helpers ───────────────────────────────────────────────────────────
local function num(v) return tonumber(v) or 0 end

local function int(v)
    return math.floor(num(v) + 0.0)
end

local function cfg(section, key, default)
    local s = Config[section]
    local v = type(s) == 'table' and s[key] or nil
    if v == nil then return default end
    return v
end

local function cacheSeconds() return math.max(0, num(cfg('Leaderboard', 'cacheSeconds', 60))) end
local function minRuns() return math.max(0, int(cfg('Leaderboard', 'minRunsToRank', 3))) end
local function topN() return math.max(1, int(cfg('Leaderboard', 'topN', 25))) end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function has(mod, fn)
    return type(CP[mod]) == 'table' and type(CP[mod][fn]) == 'function'
end

-- pcall a module function; returns ok, results...
local function call(mod, fn, ...)
    if not has(mod, fn) then return false end
    local res = table.pack(pcall(CP[mod][fn], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', mod, fn, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function validCitizenId(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function fmtInt(n)
    local s = tostring(math.floor(num(n)))
    local neg = s:sub(1, 1) == '-'
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (neg and '-' or '') .. out
end

local function sqlTs(ts) return os.date('%Y-%m-%d %H:%M:%S', math.floor(num(ts))) end

-- ── calendar (CP.Schedule, with a plain fallback) ───────────────────────────
local function resetHour()
    local h = int(cfg('Time', 'resetHour', 0))
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function weekStart(ts)
    if has('Schedule', 'weekStart') then return CP.Schedule.weekStart(ts) end
    ts = ts or os.time()
    local t = os.date('*t', ts)
    local y, m, d, wday = t.year, t.month, t.day, t.wday
    if t.hour < resetHour() then
        local p = os.date('*t', os.time({ year = y, month = m, day = d - 1, hour = 12 }))
        y, m, d, wday = p.year, p.month, p.day, p.wday
    end
    local back = (wday - 2) % 7
    return os.time({ year = y, month = m, day = d - back, hour = resetHour(), min = 0, sec = 0 })
end

local function monthStart(ts)
    if has('Schedule', 'monthStart') then return CP.Schedule.monthStart(ts) end
    ts = ts or os.time()
    local t = os.date('*t', ts)
    local y, m = t.year, t.month
    if t.day == 1 and t.hour < resetHour() then
        local p = os.date('*t', os.time({ year = y, month = m, day = 0, hour = 12 }))
        y, m = p.year, p.month
    end
    return os.time({ year = y, month = m, day = 1, hour = resetHour(), min = 0, sec = 0 })
end

local function dateKey(ts) return os.date('%Y-%m-%d', ts) end

-- ── departments and names ───────────────────────────────────────────────────
local function deptInfo(key)
    if type(key) ~= 'string' then return nil end
    if has('Access', 'department') then
        local ok, d = call('Access', 'department', key)
        if ok and type(d) == 'table' then
            return { key = d.key, label = d.label, short = d.short, colour = d.theme and d.theme.primary or '#a4161a' }
        end
        return nil
    end
    local d = type(Config.Departments) == 'table' and Config.Departments[key] or nil
    if type(d) ~= 'table' then return nil end
    local primary = type(d.theme) == 'table' and d.theme.primary or nil
    return { key = key, label = tostring(d.label or key), short = tostring(d.short or key:upper()),
        colour = U.isHexColour(primary) and primary:lower() or '#a4161a' }
end

local function deptShort(key)
    local d = deptInfo(key)
    return d and d.short or (type(key) == 'string' and key:upper() or '')
end

local function isDepartment(key)
    return type(key) == 'string' and type(Config.Departments) == 'table' and type(Config.Departments[key]) == 'table'
end

local function firstDepartment()
    local keys = {}
    for k, v in pairs(Config.Departments or {}) do
        if type(k) == 'string' and type(v) == 'table' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys[1]
end

local function nonEmpty(s)
    if type(s) ~= 'string' then return nil end
    s = U.trim(s)
    if s == '' then return nil end
    return s
end

-- Privacy-aware display name for public places (boards, Discord, other officers' profiles).
function LB.publicName(e)
    if e.hideName then return e.callsign or CP.L('leaderboard.hidden_name') end
    return e.name or e.callsign or CP.L('common.unknown')
end

local function validFilter(f)
    if type(f) ~= 'string' then return false end
    if EXTRA_FILTERS[f] then return true end
    return type(Config.MissionTypes) == 'table' and type(Config.MissionTypes[f]) == 'table'
end

-- ── mission labels ──────────────────────────────────────────────────────────
local function goalLabel(id)
    local goals = Config.Goals
    if type(goals) ~= 'table' then return nil end
    for _, list in ipairs({ goals.daily, goals.weekly }) do
        if type(list) == 'table' then
            for _, g in ipairs(list) do
                if type(g) == 'table' and g.id == id and g.label then return tostring(g.label) end
            end
        end
    end
    return nil
end

function LB.missionLabel(missionType, missionId, breakdown)
    if missionType == 'manual_award' then return CP.L('profile.manual_award') end
    if missionType == 'goal' then return goalLabel(missionId) or CP.L('profile.goal_reward') end
    if has('Missions', 'get') then
        local ok, def = call('Missions', 'get', missionId)
        if ok and type(def) == 'table' and def.label then return tostring(def.label) end
    end
    if type(breakdown) == 'table' and type(breakdown.missionLabel) == 'string' and breakdown.missionLabel ~= '' then
        return breakdown.missionLabel
    end
    return tostring(missionId or CP.L('common.unknown'))
end

-- ── seasons (CP.Challenge owns them) ────────────────────────────────────────
local function currentSeason()
    local ok, s = call('Challenge', 'currentSeason')
    if ok and type(s) == 'table' then return s end
    return nil
end

local function boardSeason()
    local ok, s = call('Challenge', 'latestSeason')
    if ok and type(s) == 'table' then return s end
    return currentSeason()
end

-- ── the board query ─────────────────────────────────────────────────────────
local COUNTED = 'r.voided = 0 AND r.flagged = 0'
local RUN_ROW = "r.mission_type NOT IN ('manual_award', 'goal')"

local AGG_SQL = [[
SELECT s.citizenid, s.points, s.runs, s.failed, s.reached_ts, s.cash, s.row_department,
  o.display_name, o.callsign, o.department AS officer_department, o.hide_name
FROM (
  SELECT r.citizenid,
    SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.final_points ELSE 0 END) AS points,
    SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS runs,
    SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'failed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS failed,
    UNIX_TIMESTAMP(COALESCE(
      MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.final_points <> 0 THEN r.created_at END),
      MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.created_at END),
      MAX(r.created_at))) AS reached_ts,
    SUM(r.cash_paid) AS cash,
    SUBSTRING_INDEX(GROUP_CONCAT(r.department ORDER BY r.created_at DESC, r.id DESC SEPARATOR ','), ',', 1) AS row_department
  FROM cp_mission_runs r
  WHERE %s
  GROUP BY r.citizenid
) s
LEFT JOIN cp_officers o ON o.citizenid = s.citizenid]]

local ALLTIME_SQL = [[
SELECT o.citizenid, o.xp AS points, o.display_name, o.callsign, o.department AS officer_department, o.hide_name,
  COALESCE(s.runs, 0) AS runs, COALESCE(s.failed, 0) AS failed, s.reached_ts, COALESCE(s.cash, 0) AS cash
FROM cp_officers o
LEFT JOIN (
  SELECT u.citizenid, SUM(u.runs) AS runs, SUM(u.failed) AS failed, MAX(u.reached_ts) AS reached_ts, SUM(u.cash) AS cash
  FROM (
    SELECT r.citizenid,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS runs,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'failed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS failed,
      UNIX_TIMESTAMP(MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.final_points <> 0 THEN r.created_at END)) AS reached_ts,
      SUM(r.cash_paid) AS cash
    FROM cp_mission_runs r GROUP BY r.citizenid
    UNION ALL
    SELECT r.citizenid,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS runs,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'failed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS failed,
      UNIX_TIMESTAMP(MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.final_points <> 0 THEN r.created_at END)) AS reached_ts,
      SUM(r.cash_paid) AS cash
    FROM cp_mission_runs_archive r GROUP BY r.citizenid
  ) u
  GROUP BY u.citizenid
) s ON s.citizenid = o.citizenid
WHERE o.xp <> 0 OR s.runs > 0]]

-- WHERE clause (and params) for a window + filter.
local function whereFor(q)
    local parts, params = {}, {}
    if q.period == 'season' then
        parts[#parts + 1] = 'r.season_id = ?'
        params[#params + 1] = q.seasonId
    else
        parts[#parts + 1] = 'r.created_at >= FROM_UNIXTIME(?)'
        params[#params + 1] = q.from
        if q.to then
            parts[#parts + 1] = 'r.created_at < FROM_UNIXTIME(?)'
            params[#params + 1] = q.to
        end
    end
    local f = q.filter
    if f == 'unit' then
        parts[#parts + 1] = 'r.participants >= 2 AND ' .. RUN_ROW
    elseif f == 'cross' then
        parts[#parts + 1] = 'r.departments_n >= 2 AND ' .. RUN_ROW
    elseif f == 'department' then
        parts[#parts + 1] = 'r.department = ?'
        params[#params + 1] = q.department
    elseif f ~= 'overall' then
        parts[#parts + 1] = 'r.mission_type = ?'
        params[#params + 1] = f
    end
    return table.concat(parts, ' AND '), params
end

local function entryFrom(row)
    local dept = nonEmpty(row.officer_department) or nonEmpty(row.row_department)
    return {
        citizenid = tostring(row.citizenid),
        points = int(row.points),
        runs = int(row.runs),
        failed = int(row.failed),
        reachedTs = row.reached_ts ~= nil and int(row.reached_ts) or math.maxinteger,
        cash = int(row.cash),
        name = nonEmpty(row.display_name),
        callsign = nonEmpty(row.callsign),
        department = dept,
        hideName = U.truthy(row.hide_name),
    }
end

local function compare(a, b)
    if a.points ~= b.points then return a.points > b.points end
    if a.failed ~= b.failed then return a.failed < b.failed end
    if a.reachedTs ~= b.reachedTs then return a.reachedTs < b.reachedTs end
    return a.citizenid < b.citizenid
end

-- Split entries into the ranked list (minRuns completed runs, sorted, rank set) and a map of everyone.
local function rankEntries(entries, need)
    local ranked, all = {}, {}
    for _, e in ipairs(entries) do
        all[e.citizenid] = e
        e.rank = 0
        if e.runs >= need then ranked[#ranked + 1] = e end
    end
    table.sort(ranked, compare)
    for i, e in ipairs(ranked) do e.rank = i end
    return ranked, all
end
LB._rankEntries = rankEntries

-- Resolve a query into its window: { period, filter, department, from, to, seasonId, season, key }.
local function resolve(opts)
    local now = os.time()
    local q = { period = opts.period or 'weekly', filter = opts.filter or 'overall', department = opts.department }
    if q.filter ~= 'department' then q.department = nil end
    if q.period == 'alltime' then
        q.filter, q.department = 'overall', nil
        q.key = 'alltime'
    elseif q.period == 'weekly' then
        q.from = weekStart(now)
        q.key = 'w' .. q.from
    elseif q.period == 'monthly' then
        q.from = monthStart(now)
        q.key = 'm' .. q.from
    elseif q.period == 'season' then
        local season
        if opts.seasonId then
            season = { id = int(opts.seasonId) }
            local ok, s = call('Challenge', 'seasonById', season.id)
            if ok and type(s) == 'table' then season = s end
        else
            season = boardSeason()
        end
        q.season = season
        q.seasonId = season and int(season.id) or nil
        q.key = 's' .. tostring(q.seasonId or 'none')
    elseif q.period == 'range' then
        q.from, q.to = int(opts.from), int(opts.to)
        q.key = ('r%d-%d'):format(q.from, q.to)
    end
    q.key = table.concat({ q.period, q.filter, q.department or '', q.key }, '|')
    return q
end

local function compute(q)
    db()
    local rows
    if q.period == 'alltime' then
        rows = MySQL.query.await(ALLTIME_SQL, {}) or {}
    elseif q.period == 'season' and not q.seasonId then
        rows = {}
    else
        local where, params = whereFor(q)
        rows = MySQL.query.await(AGG_SQL:format(where), params) or {}
    end
    local entries = {}
    for _, row in ipairs(rows) do entries[#entries + 1] = entryFrom(row) end
    local ranked, all = rankEntries(entries, minRuns())
    return { at = os.time(), updatedAt = os.time(), ranked = ranked, all = all, q = q }
end

-- The cached board for a query (computes at most once per key at a time).
local function getBoardData(opts)
    local q = resolve(opts)
    local c = cache[q.key]
    if not opts.fresh and c and os.time() - c.at < cacheSeconds() then return c end
    local wait = inflight[q.key]
    if wait and wait.gen == generation and not opts.fresh then
        local res = Citizen.Await(wait.p)
        if res then return res end
    end
    local p = promise.new()
    local gen = generation
    local slot = { p = p, gen = gen }
    inflight[q.key] = slot
    local ok, res = pcall(compute, q)
    if inflight[q.key] == slot then inflight[q.key] = nil end
    if not ok then
        p:resolve(nil)
        CP.err(TAG, 'board %s failed: %s', q.key, tostring(res))
        error(res, 0)
    end
    -- invalidate() ran while this query was in flight (a void, approval or new row): the result may
    -- predate that change, so it is returned once but not cached.
    if gen == generation then cache[q.key] = res end
    p:resolve(res)
    return res
end

function LB.ranking(opts)
    local data = getBoardData(opts or {})
    return data.ranked, data.all, data
end

-- ── public rows ─────────────────────────────────────────────────────────────
local function publicRow(e, viewer)
    local own = viewer and viewer.citizenid == e.citizenid
    return {
        rank = e.rank or 0,
        citizenid = e.citizenid,
        name = own and viewer.name or LB.publicName(e),
        callsign = e.callsign,
        departmentShort = e.department and deptShort(e.department) or '',
        points = e.points,
        runs = e.runs,
        failed = e.failed,
    }
end

local function windowView(q)
    if q.period == 'alltime' then return nil end
    if q.period == 'season' then
        local s = q.season
        if not s then return nil end
        return { from = s.startsAt, to = s.endsAt }
    end
    return { from = q.from, to = q.to }
end

local function seasonView(q)
    if q.period ~= 'season' or not q.season then return nil end
    return { id = int(q.season.id), name = q.season.name, active = q.season.active == true }
end

local function boardView(data, viewer)
    local q = data.q
    local rows = {}
    local n = topN()
    for i = 1, math.min(n, #data.ranked) do rows[i] = publicRow(data.ranked[i], viewer) end
    local me = nil
    if viewer then
        local e = data.all[viewer.citizenid]
        if e then
            me = publicRow(e, viewer)
        else
            me = { rank = 0, citizenid = viewer.citizenid, name = viewer.name, callsign = viewer.callsign,
                departmentShort = viewer.departmentShort or deptShort(viewer.department), points = 0, runs = 0, failed = 0 }
        end
    end
    return {
        period = q.period, filter = q.filter, department = q.department,
        rows = rows, me = me, updatedAt = data.updatedAt,
        minRuns = minRuns(), topN = n, ranked = #data.ranked,
        window = windowView(q), season = seasonView(q),
    }
end

-- Validate { period, filter, department } from the NUI. defaultDept fills department for that filter.
local function parseBoardArgs(args, defaultDept)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    args = args or {}
    local period = args.period
    if period == nil then period = 'weekly' end
    if type(period) ~= 'string' or not PERIODS[period] then return nil, 'err.invalid_period' end
    local filter = args.filter
    if filter == nil then filter = 'overall' end
    if not validFilter(filter) then return nil, 'err.invalid_filter' end
    local department = nil
    if filter == 'department' then
        department = args.department
        if department == nil or department == '' then department = defaultDept end
        if not isDepartment(department) then return nil, 'err.unknown_department' end
    end
    return { period = period, filter = filter, department = department }
end

-- ── caches ──────────────────────────────────────────────────────────────────
function LB.invalidate()
    generation = generation + 1
    cache = {}
    seasonPointsCache = {}
    announceCache = nil
    if has('Challenge', 'invalidate') then call('Challenge', 'invalidate') end
end

function LB.seasonPoints(citizenid)
    if not validCitizenId(citizenid) then return 0 end
    local season = currentSeason()
    if not season then return 0 end
    local c = seasonPointsCache[citizenid]
    if c and c.seasonId == season.id and os.time() - c.at < cacheSeconds() then return c.value end
    db()
    local gen = generation
    local v = MySQL.scalar.await(
        'SELECT COALESCE(SUM(final_points), 0) AS points FROM cp_mission_runs WHERE season_id = ? AND citizenid = ? AND voided = 0 AND flagged = 0',
        { int(season.id), citizenid })
    local value = int(v)
    if gen == generation then seasonPointsCache[citizenid] = { at = os.time(), seasonId = season.id, value = value } end
    return value
end

-- ── recognition ─────────────────────────────────────────────────────────────
local function topEntries(ranked, n)
    local out = {}
    for i = 1, math.min(n, #ranked) do
        local e = ranked[i]
        out[i] = { rank = i, citizenid = e.citizenid, name = LB.publicName(e), callsign = e.callsign,
            departmentShort = e.department and deptShort(e.department) or '', points = e.points }
    end
    return out
end

local function entryLine(e)
    local who = e.name
    if e.callsign and e.callsign ~= e.name then who = ('%s %s'):format(e.callsign, e.name) end
    return CP.L('leaderboard.announce_entry', { rank = e.rank, name = who, points = fmtInt(e.points), department = e.departmentShort })
end

local function joinEntries(entries)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = entryLine(e) end
    return table.concat(parts, ' · ')
end

function LB.announcements()
    local now = os.time()
    local curWeek = weekStart(now)
    local prevWeek = weekStart(curWeek - HALF_DAY)
    local curMonth = monthStart(now)
    local prevMonth = monthStart(curMonth - HALF_DAY)
    local key = ('%d|%d'):format(curWeek, curMonth)
    if announceCache and announceCache.key == key and now - announceCache.at < cacheSeconds() then
        return U.deepcopy(announceCache.list)
    end
    local list = {}
    local gen = generation
    local weekRanked = LB.ranking({ period = 'range', filter = 'overall', from = prevWeek, to = curWeek })
    local weekTop = topEntries(weekRanked, 3)
    if #weekTop > 0 then
        list[#list + 1] = {
            kind = 'weekly_top3',
            text = CP.L('leaderboard.announce_weekly', { week = dateKey(prevWeek), list = joinEntries(weekTop) }),
            entries = weekTop, period = dateKey(prevWeek),
        }
    end
    local monthRanked = LB.ranking({ period = 'range', filter = 'overall', from = prevMonth, to = curMonth })
    local monthTop = topEntries(monthRanked, 3)
    if #monthTop > 0 then
        list[#list + 1] = {
            kind = 'monthly_top3',
            text = CP.L('leaderboard.announce_monthly', { month = os.date('%Y-%m', prevMonth + HALF_DAY), list = joinEntries(monthTop) }),
            entries = monthTop, period = os.date('%Y-%m', prevMonth + HALF_DAY),
        }
    end
    if gen == generation then announceCache = { at = now, key = key, list = list } end
    return U.deepcopy(list)
end

local function webhook(title, description, fields)
    if not has('Admin', 'webhook') then
        CP.log(TAG, 'no CP.Admin.webhook: %s', title)
        return false
    end
    return call('Admin', 'webhook', 'board', title, description, fields)
end

-- The weekly reset job for the week [prevStart, curStart): top 3 to Discord and the Officer of the Week
-- badge. Idempotent: nothing happens when that week's badge already exists.
function LB._weeklyJob(prevStart, curStart)
    db()
    prevStart = int(prevStart)
    curStart = int(curStart)
    if prevStart <= 0 or curStart <= prevStart then return false end
    local weekKey = dateKey(prevStart)
    local badgeId = U.clip('officer_of_week_' .. weekKey, 40)
    local done = MySQL.scalar.await('SELECT 1 AS done FROM cp_badges WHERE badge_id = ? LIMIT 1', { badgeId })
    if done ~= nil then
        CP.log(TAG, 'weekly job for %s already done', weekKey)
        return false
    end
    local ranked = LB.ranking({ period = 'range', filter = 'overall', from = prevStart, to = curStart, fresh = true })
    local top = topEntries(ranked, 3)
    if #top == 0 then
        CP.log(TAG, 'week %s: nobody qualified for the board', weekKey)
        return false
    end
    local inserted = MySQL.update.await(
        'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { top[1].citizenid, badgeId, os.time() })
    if num(inserted) <= 0 then return false end

    local fields = {}
    for i, e in ipairs(top) do
        fields[i] = {
            name = CP.L('leaderboard.webhook_place', { rank = i }),
            value = CP.L('leaderboard.webhook_entry', { name = e.callsign and e.callsign ~= e.name and ('%s %s'):format(e.callsign, e.name) or e.name,
                department = e.departmentShort, points = fmtInt(e.points) }),
            inline = true,
        }
    end
    webhook(CP.L('leaderboard.webhook_weekly_title', { week = weekKey }),
        CP.L('leaderboard.webhook_weekly_desc', { name = top[1].name, points = fmtInt(top[1].points) }), fields)

    local ok, src = call('Qbx', 'getByCitizenId', top[1].citizenid)
    if ok and src and has('Tablet', 'notify') then
        call('Tablet', 'notify', src, 'success', 'leaderboard.officer_of_week_notice', { week = weekKey })
    end
    CP.log(TAG, 'officer of the week %s: %s', weekKey, top[1].citizenid)
    return true
end

-- ── profile ─────────────────────────────────────────────────────────────────
local function xpLevel(xp)
    local ok, lv = call('Scoring', 'xpLevel', xp)
    if ok and type(lv) == 'table' and lv.label then return lv end
    local levels = {}
    for _, l in ipairs(Config.XPLevels or {}) do
        if type(l) == 'table' and tonumber(l.xp) then levels[#levels + 1] = l end
    end
    table.sort(levels, function(a, b) return num(a.xp) < num(b.xp) end)
    local cur, nxt = levels[1], nil
    for i, l in ipairs(levels) do
        if xp >= num(l.xp) then cur = l; nxt = levels[i + 1] end
    end
    if not cur then return { label = CP.L('common.unknown'), badge = 'grey', xp = 0 } end
    return { label = tostring(cur.label), badge = tostring(cur.badge or 'grey'), xp = int(cur.xp), next = nxt and int(nxt.xp) or nil }
end

local seasonNames = { at = 0, byId = {} }
local function seasonName(id)
    id = int(id)
    if os.time() - seasonNames.at > 300 or seasonNames.byId[id] == nil then
        local ok, rows = pcall(MySQL.query.await, 'SELECT id, name FROM cp_seasons', {})
        if ok and type(rows) == 'table' then
            seasonNames = { at = os.time(), byId = {} }
            for _, r in ipairs(rows) do seasonNames.byId[int(r.id)] = tostring(r.name) end
        end
    end
    return seasonNames.byId[id] or ('#' .. id)
end

local function badgeLabel(id)
    local week = id:match('^officer_of_week_(%d%d%d%d%-%d%d%-%d%d)$')
    if week then return CP.L('profile.badge.officer_of_week', { week = week }), 'week' end
    local sid = id:match('^season_(%d+)_champion$')
    if sid then return CP.L('profile.badge.season_champion', { season = seasonName(sid) }), 'champion' end
    sid = id:match('^season_(%d+)_top10$')
    if sid then return CP.L('profile.badge.season_top10', { season = seasonName(sid) }), 'top10' end
    return nil, 'achievement'
end

function LB.badgeLabel(id)
    if type(id) ~= 'string' then return nil, 'achievement' end
    return badgeLabel(id)
end

local function badgesFor(citizenid)
    local list = {}
    local ok, fromScoring = call('Scoring', 'badges', citizenid)
    if ok and type(fromScoring) == 'table' then
        for _, b in ipairs(fromScoring) do
            if type(b) == 'table' then
                local id = b.id or b.badge_id
                if type(id) == 'string' then
                    list[#list + 1] = { id = id, label = b.label, earnedTs = tonumber(b.earnedTs or b.earned_ts), earnedAt = b.earnedAt or b.earned_at }
                end
            elseif type(b) == 'string' then
                list[#list + 1] = { id = b }
            end
        end
    else
        db()
        local rows = MySQL.query.await(
            'SELECT badge_id, UNIX_TIMESTAMP(earned_at) AS earned_ts FROM cp_badges WHERE citizenid = ? ORDER BY earned_at DESC, badge_id ASC',
            { citizenid }) or {}
        for _, r in ipairs(rows) do
            list[#list + 1] = { id = tostring(r.badge_id), earnedTs = tonumber(r.earned_ts) }
        end
    end
    -- newest first
    table.sort(list, function(a, c) return (a.earnedTs or 0) > (c.earnedTs or 0) end)
    local out = {}
    for _, b in ipairs(list) do
        local label, kind = badgeLabel(b.id)
        if not label then
            label = type(b.label) == 'string' and b.label ~= '' and b.label ~= ('badge.' .. b.id) and b.label or nil
            if not label then
                local key = 'badge.' .. b.id
                label = CP.Locale.has(key) and CP.L(key) or b.id
            end
        end
        local earnedAt = b.earnedTs and sqlTs(b.earnedTs) or (type(b.earnedAt) == 'string' and b.earnedAt or '')
        out[#out + 1] = { id = b.id, label = label, earnedAt = earnedAt, kind = kind }
    end
    return out
end

local PROFILE_RUNS_SQL = [[
SELECT r.id, r.mission_type, r.mission_id, r.state, r.end_reason, r.final_points, r.cash_paid, r.cash_status,
  r.flagged, r.voided, r.breakdown, UNIX_TIMESTAMP(r.created_at) AS created_ts,
  (SELECT COUNT(*) FROM cp_disputes d WHERE d.run_id = r.id) AS disputes
FROM cp_mission_runs r
WHERE r.citizenid = ?
ORDER BY r.created_at DESC, r.id DESC
LIMIT ?]]

local function disputable(row, own, nowTs, citizenid)
    if not own or AWARD_TYPES[row.mission_type] then return false end
    -- modules/disputes allows one dispute per row, ever: an open one blocks (err.dispute_open) and a
    -- decided one is final (err.dispute_final), so any cp_disputes row hides the button.
    if num(row.disputes) ~= 0 then return false end
    if has('Disputes', 'eligible') then
        -- The filing rule itself, so the button never offers what server:dispute would refuse.
        local ok, eligible = call('Disputes', 'eligible', {
            citizenid = citizenid, mission_type = row.mission_type, state = row.state,
            flagged = row.flagged, voided = row.voided, created_ts = row.created_ts,
        }, citizenid, nowTs)
        if ok then return eligible == true end
    end
    if not (U.truthy(row.flagged) or U.truthy(row.voided) or row.state == 'failed') then return false end
    local windowS = num(cfg('Disputes', 'windowHours', 48)) * 3600
    local created = num(row.created_ts)
    if created <= 0 or nowTs - created > windowS then return false end
    return true
end

-- RunResult fields (§9.6) a public profile may show: everything but the cash block, and none of the extra
-- keys some rows carry (a manual award's free-text admin reason, for example).
local PUBLIC_BREAKDOWN = {
    runId = true, missionLabel = true, missionType = true, result = true, endReason = true, test = true, tier = true,
    payTier = true, participants = true, departments = true, durationS = true, points = true, flagged = true,
}

local function profileRun(row, own, nowTs, citizenid)
    local bd = U.jsonField(row.breakdown)
    if type(bd) ~= 'table' then bd = nil end
    if bd then
        if own then
            if type(bd.cash) == 'table' then bd.cash.status = row.cash_status end
        else
            local pub = {}
            for k, v in pairs(bd) do
                if PUBLIC_BREAKDOWN[k] then pub[k] = v end
            end
            bd = pub
        end
    end
    local label = LB.missionLabel(row.mission_type, row.mission_id, bd)
    return {
        id = int(row.id),
        missionLabel = label,
        missionType = tostring(row.mission_type),
        state = tostring(row.state),
        endReason = tostring(row.end_reason),
        points = int(row.final_points),
        cash = own and int(row.cash_paid) or 0,
        cashStatus = own and tostring(row.cash_status or 'none') or '',
        flagged = U.truthy(row.flagged),
        voided = U.truthy(row.voided),
        createdAt = sqlTs(row.created_ts),
        createdTs = int(row.created_ts),
        breakdown = bd,
        canDispute = disputable(row, own, nowTs, citizenid),
    }
end

function LB.profile(viewer, target)
    db()
    local own = target == nil or target == viewer.citizenid
    local cid = own and viewer.citizenid or target
    local orow = MySQL.single.await(
        'SELECT citizenid, display_name, callsign, rank_label, department, xp, hide_name FROM cp_officers WHERE citizenid = ?',
        { cid })
    if not own and not orow then return nil, 'err.unknown_officer' end
    orow = orow or {}
    local hideName = U.truthy(orow.hide_name)
    local xp = int(orow.xp)
    local e = { name = nonEmpty(orow.display_name), callsign = nonEmpty(orow.callsign), hideName = hideName }
    local dept = own and viewer.department or nonEmpty(orow.department)
    local d = deptInfo(dept)
    local nowTs = os.time()
    local rows = MySQL.query.await(PROFILE_RUNS_SQL, { cid, PROFILE_RUNS }) or {}
    local runs = {}
    for i, row in ipairs(rows) do runs[i] = profileRun(row, own, nowTs, cid) end
    return {
        citizenid = cid,
        name = own and viewer.name or LB.publicName(e),
        callsign = own and viewer.callsign or e.callsign,
        rank = own and viewer.rank or (nonEmpty(orow.rank_label) or ''),
        departmentShort = own and viewer.departmentShort or (d and d.short or ''),
        departmentLabel = own and viewer.departmentLabel or (d and d.label or ''),
        xp = xp,
        level = xpLevel(xp),
        badges = badgesFor(cid),
        hideName = hideName,
        own = own,
        runs = runs,
        seasonPoints = LB.seasonPoints(cid),
        disputeWindowHours = num(cfg('Disputes', 'windowHours', 48)),
    }
end

-- ── admin board data ────────────────────────────────────────────────────────
local function normaliseStuck(list)
    local out = {}
    for _, p in ipairs(list or {}) do
        if type(p) == 'table' then
            local rowId = int(p.rowId or p.id)
            local runUuid = p.runUuid or p.run_uuid
            local cid = p.citizenid
            out[#out + 1] = {
                rowId = rowId,
                runUuid = runUuid and tostring(runUuid) or '',
                citizenid = cid and tostring(cid) or '',
                name = p.name or p.display_name,
                callsign = p.callsign,
                missionLabel = p.missionLabel or LB.missionLabel(p.missionType or p.mission_type, p.missionId or p.mission_id, nil),
                amount = int(p.amount or p.cashBase or p.cash_base),
                createdAt = (type(p.createdAt) == 'number' and sqlTs(p.createdAt))
                    or (type(p.createdAt) == 'string' and p.createdAt)
                    or (p.created_ts and sqlTs(p.created_ts)) or '',
                transId = p.transId or (runUuid and cid and ('CP-%s-%s'):format(runUuid, cid)) or '',
            }
        end
    end
    return out
end

local STUCK_SQL = [[
SELECT r.id, r.run_uuid, r.citizenid, r.mission_type, r.mission_id, ROUND(r.cash_base * r.cash_multiplier) AS amount,
  UNIX_TIMESTAMP(r.created_at) AS created_ts, o.display_name, o.callsign
FROM cp_mission_runs r
LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
WHERE r.cash_status = 'paying'
ORDER BY r.created_at ASC
LIMIT 200]]

local function stuckPayments()
    local ok, list = call('Cash', 'stuckPayments')
    if ok and type(list) == 'table' then return normaliseStuck(list) end
    db()
    return normaliseStuck(MySQL.query.await(STUCK_SQL, {}) or {})
end
LB._stuckPayments = stuckPayments

local function adminRow(e)
    local r = publicRow(e, nil)
    r.cash = e.cash
    r.realName = e.name or CP.L('common.unknown')
    r.hidden = e.hideName
    r.department = e.department
    return r
end

local ADMIN_RUNS_SQL = [[
SELECT r.id, r.run_uuid, r.mission_type, r.mission_id, r.state, r.end_reason, r.final_points, r.cash_paid, r.cash_status,
  r.flagged, r.flag_reason, r.voided, r.department, r.participants, r.departments_n, r.tier,
  UNIX_TIMESTAMP(r.created_at) AS created_ts
FROM cp_mission_runs r
WHERE r.citizenid = ? AND %s
ORDER BY r.created_at DESC, r.id DESC
LIMIT ?]]

local function adminRuns(q, citizenid)
    local list = {}
    if q.period == 'season' and not q.seasonId then return list end
    local rows
    if q.period == 'alltime' then
        rows = MySQL.query.await(ADMIN_RUNS_SQL:format('1 = 1'), { citizenid, ADMIN_RUNS }) or {}
    else
        local where, params = whereFor(q)
        local all = { citizenid }
        for _, p in ipairs(params) do all[#all + 1] = p end
        all[#all + 1] = ADMIN_RUNS
        rows = MySQL.query.await(ADMIN_RUNS_SQL:format(where), all) or {}
    end
    for _, r in ipairs(rows) do
        list[#list + 1] = {
            id = int(r.id), runUuid = tostring(r.run_uuid),
            missionLabel = LB.missionLabel(r.mission_type, r.mission_id, nil), missionType = tostring(r.mission_type),
            state = tostring(r.state), endReason = tostring(r.end_reason), points = int(r.final_points),
            cash = int(r.cash_paid), cashStatus = tostring(r.cash_status), flagged = U.truthy(r.flagged),
            flagReason = r.flag_reason, voided = U.truthy(r.voided), departmentShort = deptShort(r.department),
            participants = int(r.participants), departments = int(r.departments_n), tier = tostring(r.tier),
            createdAt = sqlTs(r.created_ts), createdTs = int(r.created_ts),
        }
    end
    return list
end

function LB.adminBoard(args)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    args = args or {}
    local q, err = parseBoardArgs(args, firstDepartment())
    if not q then return nil, err end
    local cid = args.citizenid
    if cid ~= nil and not validCitizenId(cid) then return nil, 'err.invalid_citizenid' end
    local data = getBoardData(q)
    local rows, unranked = {}, {}
    for i, e in ipairs(data.ranked) do rows[i] = adminRow(e) end
    local rest = {}
    for _, e in pairs(data.all) do
        if (e.rank or 0) == 0 then rest[#rest + 1] = e end
    end
    table.sort(rest, compare)
    for i, e in ipairs(rest) do unranked[i] = adminRow(e) end
    local out = {
        period = data.q.period, filter = data.q.filter, department = data.q.department,
        rows = rows, unranked = unranked, stuck = stuckPayments(),
        minRuns = minRuns(), updatedAt = data.updatedAt, window = windowView(data.q), season = seasonView(data.q),
    }
    if cid then out.citizenid = cid; out.runs = adminRuns(data.q, cid) end
    return out
end

-- ── net handlers ────────────────────────────────────────────────────────────
CP.Net.callback('getBoard', function(src, args)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    local q, err = parseBoardArgs(args, officer.department)
    if not q then return nil, err end
    return boardView(getBoardData(q), officer)
end)

local function parseCitizenArg(args)
    if args == nil then return nil end
    if type(args) == 'string' then
        if args == '' then return nil end
        return validCitizenId(args) and args or false
    end
    if type(args) ~= 'table' then return false end
    local cid = args.citizenid
    if cid == nil or cid == '' then return nil end
    return validCitizenId(cid) and cid or false
end

CP.Net.callback('getProfile', function(src, args)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    local target = parseCitizenArg(args)
    if target == false then return nil, 'err.invalid_payload' end
    return LB.profile(officer, target)
end)

CP.Net.action('server:setHideName', function(src, payload)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return false, errKey end
    local value = payload
    if type(payload) == 'table' then value = payload.hideName end
    if type(value) ~= 'boolean' then return false, 'err.invalid_payload' end
    db()
    MySQL.update.await(
        [[INSERT INTO cp_officers (citizenid, callsign, display_name, department, hide_name)
          VALUES (?, NULLIF(?, ''), ?, ?, ?)
          ON DUPLICATE KEY UPDATE hide_name = VALUES(hide_name)]],
        { officer.citizenid, U.clip(officer.callsign or '', 32), U.clip(officer.name or '', 64), officer.department, value and 1 or 0 })
    LB.invalidate()
    CP.log(TAG, '%s hide_name = %s', officer.citizenid, tostring(value))
    return true, { hideName = value }
end, { rate = 2 })

CP.Net.callback('admin:getBoards', function(src, args)
    local ok, errKey = CP.Permissions.can(src, 'openAdmin')
    if not ok then return nil, errKey end
    return LB.adminBoard(args)
end)

-- ── start ───────────────────────────────────────────────────────────────────
function LB._boot()
    if booted then return end
    booted = true
    if has('Schedule', 'onWeekly') then
        CP.Schedule.onWeekly(function(_, prevWeekStartTs)
            LB.invalidate()
            local curStart = weekStart(os.time())
            local prev = tonumber(prevWeekStartTs) or weekStart(curStart - HALF_DAY)
            LB._weeklyJob(prev, curStart)
        end)
        CP.Schedule.onMonthly(function(monthStartTs)
            LB.invalidate()
            CP.log(TAG, 'monthly reset %s: top 3 of the last month is now announced on Home', dateKey(tonumber(monthStartTs) or os.time()))
        end)
    else
        CP.warn(TAG, 'CP.Schedule is missing: no weekly recognition')
    end
end

CreateThread(function()
    Wait(BOOT_DELAY_MS)
    LB._boot()
    -- Catch-up: a server that was down across the weekly reset still awards last week's badge.
    Wait(CATCHUP_DELAY_MS)
    local ok, err = pcall(function()
        local curStart = weekStart(os.time())
        LB._weeklyJob(weekStart(curStart - HALF_DAY), curStart)
    end)
    if not ok then CP.err(TAG, 'weekly catch-up failed: %s', tostring(err)) end
end)
