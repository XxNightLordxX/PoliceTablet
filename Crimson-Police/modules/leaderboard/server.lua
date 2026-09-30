-- CP.Leaderboard (server): the four time-boxed boards ranked by a metric, their cache, the weekly/monthly recognition,
-- public and own profiles with the service record, the hide-name toggle and the admin board view.

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

local cache = {}                -- key -> { at, ranked, all, updatedAt, meta }
local inflight = {}             -- key -> { p = promise, gen = generation }
local generation = 0            -- bumped by invalidate(): a board computed before it is never cached
local seasonPointsCache = {}    -- citizenid -> { at, value }
local announceCache = nil       -- { at, key, list }
local booted = false

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Num(v) return tonumber(v) or 0 end

local function Int(v)
    return math.floor(Num(v) + 0.0)
end

local function Cfg(section, key, default)
    local s = Config[section]
    local v = type(s) == 'table' and s[key] or nil
    if v == nil then return default end
    return v
end

local function CacheSeconds() return math.max(0, Num(Cfg('Leaderboard', 'cacheSeconds', 60))) end
local function MinRuns() return math.max(0, Int(Cfg('Leaderboard', 'minRunsToRank', 3))) end
local function TopN() return math.max(1, Int(Cfg('Leaderboard', 'topN', 25))) end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Has(mod, fn)
    return type(CP[mod]) == 'table' and type(CP[mod][fn]) == 'function'
end

-- pcall a module function; returns ok, results...
local function Call(mod, fn, ...)
    if not Has(mod, fn) then return false end
    local res = table.pack(pcall(CP[mod][fn], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', mod, fn, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function ValidCitizenId(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function FmtInt(n)
    local s = tostring(math.floor(Num(n)))
    local neg = s:sub(1, 1) == '-'
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (neg and '-' or '') .. out
end

local function SqlTs(ts) return os.date('%Y-%m-%d %H:%M:%S', math.floor(Num(ts))) end

-- ============================================================================
--                CALENDAR (CP.Schedule, with a plain fallback)
-- ============================================================================

local function ResetHour()
    local h = Int(Cfg('Time', 'resetHour', 0))
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function WeekStart(ts)
    if Has('Schedule', 'weekStart') then return CP.Schedule.weekStart(ts) end
    ts = ts or os.time()
    local t = os.date('*t', ts)
    local y, m, d, wday = t.year, t.month, t.day, t.wday
    if t.hour < ResetHour() then
        local p = os.date('*t', os.time({ year = y, month = m, day = d - 1, hour = 12 }))
        y, m, d, wday = p.year, p.month, p.day, p.wday
    end
    local back = (wday - 2) % 7
    return os.time({ year = y, month = m, day = d - back, hour = ResetHour(), min = 0, sec = 0 })
end

local function MonthStart(ts)
    if Has('Schedule', 'monthStart') then return CP.Schedule.monthStart(ts) end
    ts = ts or os.time()
    local t = os.date('*t', ts)
    local y, m = t.year, t.month
    if t.day == 1 and t.hour < ResetHour() then
        local p = os.date('*t', os.time({ year = y, month = m, day = 0, hour = 12 }))
        y, m = p.year, p.month
    end
    return os.time({ year = y, month = m, day = 1, hour = ResetHour(), min = 0, sec = 0 })
end

local function DateKey(ts) return os.date('%Y-%m-%d', ts) end

-- ============================================================================
--                            DEPARTMENTS AND NAMES
-- ============================================================================

local function DeptInfo(key)
    if type(key) ~= 'string' then return nil end
    if Has('Access', 'department') then
        local ok, d = Call('Access', 'department', key)
        if ok and type(d) == 'table' then
            return { key = d.key, label = d.label, short = d.short, colour = d.theme and d.theme.primary or '#a4161a' }
        end
        return nil
    end
    local d = type(Config.Departments) == 'table' and Config.Departments[key] or nil
    if type(d) ~= 'table' then return nil end
    local primary = type(d.theme) == 'table' and d.theme.primary or nil
    return {
        key = key,
        label = tostring(d.label or key),
        short = tostring(d.short or key:upper()),
        colour = U.isHexColour(primary) and primary:lower() or '#a4161a',
    }
end

local function DeptShort(key)
    local d = DeptInfo(key)
    return d and d.short or (type(key) == 'string' and key:upper() or '')
end

local function IsDepartment(key)
    return type(key) == 'string' and type(Config.Departments) == 'table' and type(Config.Departments[key]) == 'table'
end

local function FirstDepartment()
    local keys = {}
    for k, v in pairs(Config.Departments or {}) do
        if type(k) == 'string' and type(v) == 'table' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    return keys[1]
end

local function NonEmpty(s)
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

local function ValidFilter(f)
    if type(f) ~= 'string' then return false end
    if EXTRA_FILTERS[f] then return true end
    return type(Config.MissionTypes) == 'table' and type(Config.MissionTypes[f]) == 'table'
end

-- ============================================================================
--                                MISSION LABELS
-- ============================================================================

local function GoalLabel(id)
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
    if missionType == 'goal' then return GoalLabel(missionId) or CP.L('profile.goal_reward') end
    if Has('Missions', 'get') then
        local ok, def = Call('Missions', 'get', missionId)
        if ok and type(def) == 'table' and def.label then return tostring(def.label) end
    end
    if type(breakdown) == 'table' and type(breakdown.missionLabel) == 'string' and breakdown.missionLabel ~= '' then
        return breakdown.missionLabel
    end
    return tostring(missionId or CP.L('common.unknown'))
end

-- ============================================================================
--                       SEASONS (CP.Challenge owns them)
-- ============================================================================

local function CurrentSeason()
    local ok, s = Call('Challenge', 'currentSeason')
    if ok and type(s) == 'table' then return s end
    return nil
end

local function BoardSeason()
    local ok, s = Call('Challenge', 'latestSeason')
    if ok and type(s) == 'table' then return s end
    return CurrentSeason()
end

-- ============================================================================
--                               THE BOARD QUERY
-- ============================================================================

local COUNTED = 'r.voided = 0 AND r.flagged = 0'
local RUN_ROW = 'r.mission_type NOT IN (\'manual_award\', \'goal\')'

-- Counted completed run rows (not awards or goal rewards): the only rows a stat metric ever sums.
local DONE = 'r.voided = 0 AND r.flagged = 0 AND r.state = \'completed\' AND ' .. RUN_ROW

-- The per-officer sums every metric needs (SPEC Leaderboards → Rank by). Kills (lethal) are never read here.
local METRIC_SUMS = ([[
    SUM(CASE WHEN %s THEN r.arrests ELSE 0 END) AS arrests,
    SUM(CASE WHEN %s THEN r.impounds ELSE 0 END) AS impounds,
    SUM(CASE WHEN %s THEN r.citations ELSE 0 END) AS citations,
    SUM(CASE WHEN %s THEN r.rescues ELSE 0 END) AS rescues,
    SUM(CASE WHEN %s AND r.mission_call_id IS NOT NULL THEN 1 ELSE 0 END) AS calls,
    SUM(CASE WHEN %s THEN r.decisions_ok ELSE 0 END) AS decisions_ok,
    SUM(CASE WHEN %s THEN r.decisions_best ELSE 0 END) AS decisions_best,
    SUM(CASE WHEN %s THEN r.decisions_bad ELSE 0 END) AS decisions_bad]]):gsub('%%s', DONE)

local METRIC_COLS = 's.arrests, s.impounds, s.citations, s.rescues, s.calls, s.decisions_ok, s.decisions_best, s.decisions_bad'

local AGG_SQL = [[
SELECT s.citizenid, s.points, s.runs, s.failed, s.reached_ts, s.cash, s.row_department, ]] .. METRIC_COLS .. [[,
  o.display_name, o.callsign, o.department AS officer_department, o.hide_name, o.xp, o.avatar_kind, o.avatar_value,
  o.avatar_status
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
    SUBSTRING_INDEX(GROUP_CONCAT(r.department ORDER BY r.created_at DESC, r.id DESC SEPARATOR ','), ',', 1) AS row_department,
]] .. METRIC_SUMS .. [[

  FROM cp_mission_runs r
  WHERE %s
  GROUP BY r.citizenid
) s
LEFT JOIN cp_officers o ON o.citizenid = s.citizenid]]

-- One part of the all-time union (cp_mission_runs, then cp_mission_runs_archive).
local ALLTIME_PART = [[
    SELECT r.citizenid,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS runs,
      SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.state = 'failed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS failed,
      UNIX_TIMESTAMP(MAX(CASE WHEN r.voided = 0 AND r.flagged = 0 AND r.final_points <> 0 THEN r.created_at END)) AS reached_ts,
      SUM(r.cash_paid) AS cash,
]] .. METRIC_SUMS .. [[

    FROM %s r GROUP BY r.citizenid]]

local ALLTIME_SQL = [[
SELECT o.citizenid, o.xp AS points, o.display_name, o.callsign, o.department AS officer_department, o.hide_name,
  o.xp, o.avatar_kind, o.avatar_value, o.avatar_status,
  COALESCE(s.runs, 0) AS runs, COALESCE(s.failed, 0) AS failed, s.reached_ts, COALESCE(s.cash, 0) AS cash,
  ]] .. METRIC_COLS .. [[

FROM cp_officers o
LEFT JOIN (
  SELECT u.citizenid, SUM(u.runs) AS runs, SUM(u.failed) AS failed, MAX(u.reached_ts) AS reached_ts, SUM(u.cash) AS cash,
    SUM(u.arrests) AS arrests, SUM(u.impounds) AS impounds, SUM(u.citations) AS citations, SUM(u.rescues) AS rescues,
    SUM(u.calls) AS calls, SUM(u.decisions_ok) AS decisions_ok, SUM(u.decisions_best) AS decisions_best,
    SUM(u.decisions_bad) AS decisions_bad
  FROM (
]] .. ALLTIME_PART:format('cp_mission_runs') .. [[

    UNION ALL
]] .. ALLTIME_PART:format('cp_mission_runs_archive') .. [[

  ) u
  GROUP BY u.citizenid
) s ON s.citizenid = o.citizenid
WHERE o.xp <> 0 OR s.runs > 0]]

-- WHERE clause (and params) for a window + filter.
local function WhereFor(q)
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

local function EntryFrom(row)
    local dept = NonEmpty(row.officer_department) or NonEmpty(row.row_department)
    return {
        citizenid = tostring(row.citizenid),
        points = Int(row.points),
        runs = Int(row.runs),
        failed = Int(row.failed),
        reachedTs = row.reached_ts ~= nil and Int(row.reached_ts) or math.maxinteger,
        cash = Int(row.cash),
        name = NonEmpty(row.display_name),
        callsign = NonEmpty(row.callsign),
        department = dept,
        hideName = U.truthy(row.hide_name),
        xp = Int(row.xp),
        avatarRow = {
            display_name = row.display_name,
            callsign = row.callsign,
            hide_name = row.hide_name,
            xp = row.xp,
            avatar_kind = row.avatar_kind,
            avatar_value = row.avatar_value,
            avatar_status = row.avatar_status,
        },
        stats = {
            arrests = Int(row.arrests),
            impounds = Int(row.impounds),
            citations = Int(row.citations),
            rescues = Int(row.rescues),
            calls = Int(row.calls),
            decisionsOk = Int(row.decisions_ok),
            decisionsBest = Int(row.decisions_best),
            decisionsBad = Int(row.decisions_bad),
        },
    }
end

-- ============================================================================
--                                   METRICS
-- ============================================================================
-- Rank by (Config.Leaderboard.metrics): points (the default; XP on the All-time tab), missions (completed runs),
-- arrests, impounds, citations, rescues, calls (completed runs claimed from a mission call) and judgement
-- (Best dispositions as a share of all dispositions). Ratios are worked out here, never in SQL.

local METRICS = {
    points = true,
    missions = true,
    arrests = true,
    impounds = true,
    citations = true,
    rescues = true,
    calls = true,
    judgement = true,
}

local function MinDecisions() return math.max(0, Int(Cfg('Leaderboard', 'minDecisions', 10))) end

local function MetricList()
    local out = {}
    for _, m in ipairs(Cfg('Leaderboard', 'metrics', { 'points' }) or {}) do
        if METRICS[m] then out[#out + 1] = m end
    end
    if #out == 0 then out[1] = 'points' end
    return out
end

local function ValidMetric(m)
    if m == 'points' then return true end
    for _, k in ipairs(MetricList()) do
        if k == m then return true end
    end
    return false
end

-- The value an entry is ranked by, and (judgement) the decisions behind it.
local function MetricValue(e, metric)
    local st = e.stats or {}
    if metric == 'missions' then return e.runs end
    if metric == 'arrests' or metric == 'impounds' or metric == 'citations' or metric == 'rescues'
        or metric == 'calls' then
        return st[metric] or 0
    end
    if metric == 'judgement' then
        local total = (st.decisionsOk or 0) + (st.decisionsBad or 0)
        if total <= 0 then return 0, 0 end
        return math.floor((st.decisionsBest or 0) * 1000 / total + 0.5) / 10, total
    end
    return e.points
end
LB._metricValue = MetricValue

local function Compare(a, b)
    if a.value ~= nil and b.value ~= nil and a.value ~= b.value then return a.value > b.value end
    if (a.decisions or 0) ~= (b.decisions or 0) then return (a.decisions or 0) > (b.decisions or 0) end
    if a.points ~= b.points then return a.points > b.points end
    if a.failed ~= b.failed then return a.failed < b.failed end
    if a.reachedTs ~= b.reachedTs then return a.reachedTs < b.reachedTs end
    return a.citizenid < b.citizenid
end

-- Split entries into the ranked list (minRuns completed runs, and minDecisions for Judgement; sorted, rank set)
-- and a map of everyone. metric nil = points.
local function RankEntries(entries, need, metric)
    local ranked, all = {}, {}
    for _, e in ipairs(entries) do
        all[e.citizenid] = e
        e.rank = 0
        if metric then e.value, e.decisions = MetricValue(e, metric) end
        local ok = e.runs >= need
        if ok and metric == 'judgement' and (e.decisions or 0) < MinDecisions() then ok = false end
        if ok then ranked[#ranked + 1] = e end
    end
    table.sort(ranked, Compare)
    for i, e in ipairs(ranked) do e.rank = i end
    return ranked, all
end
LB._rankEntries = RankEntries

-- Resolve a query into its window: { period, filter, department, metric, from, to, seasonId, season, key }.
local function Resolve(opts)
    local now = os.time()
    local q = {
        period = opts.period or 'weekly',
        filter = opts.filter or 'overall',
        department = opts.department,
        metric = METRICS[opts.metric] and opts.metric or 'points',
    }
    if q.filter ~= 'department' then q.department = nil end
    if q.period == 'alltime' then
        q.filter, q.department = 'overall', nil
        q.key = 'alltime'
    elseif q.period == 'weekly' then
        q.from = WeekStart(now)
        q.key = 'w' .. q.from
    elseif q.period == 'monthly' then
        q.from = MonthStart(now)
        q.key = 'm' .. q.from
    elseif q.period == 'season' then
        local season
        if opts.seasonId then
            season = { id = Int(opts.seasonId) }
            local ok, s = Call('Challenge', 'seasonById', season.id)
            if ok and type(s) == 'table' then season = s end
        else
            season = BoardSeason()
        end
        q.season = season
        q.seasonId = season and Int(season.id) or nil
        q.key = 's' .. tostring(q.seasonId or 'none')
    elseif q.period == 'range' then
        q.from, q.to = Int(opts.from), Int(opts.to)
        q.key = ('r%d-%d'):format(q.from, q.to)
    end
    q.key = table.concat({ q.period, q.filter, q.department or '', q.metric, q.key }, '|')
    return q
end

local function Compute(q)
    Db()
    local rows
    if q.period == 'alltime' then
        rows = MySQL.query.await(ALLTIME_SQL, {}) or {}
    elseif q.period == 'season' and not q.seasonId then
        rows = {}
    else
        local where, params = WhereFor(q)
        rows = MySQL.query.await(AGG_SQL:format(where), params) or {}
    end
    local entries = {}
    for _, row in ipairs(rows) do entries[#entries + 1] = EntryFrom(row) end
    local ranked, all = RankEntries(entries, MinRuns(), q.metric)
    return { at = os.time(), updatedAt = os.time(), ranked = ranked, all = all, q = q }
end

-- The cached board for a query (computes at most once per key at a time).
local function GetBoardData(opts)
    local q = Resolve(opts)
    local c = cache[q.key]
    if not opts.fresh and c and os.time() - c.at < CacheSeconds() then return c end
    local wait = inflight[q.key]
    if wait and wait.gen == generation and not opts.fresh then
        local res = Citizen.Await(wait.p)
        if res then return res end
    end
    local p = promise.new()
    local gen = generation
    local slot = { p = p, gen = gen }
    inflight[q.key] = slot
    local ok, res = pcall(Compute, q)
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
    local data = GetBoardData(opts or {})
    return data.ranked, data.all, data
end

-- ============================================================================
--                                 PUBLIC ROWS
-- ============================================================================

-- The number and badge of an XP level (rows and headers carry nothing else).
local function RowLevel(xp)
    local ok, lv = Call('Scoring', 'xpLevel', Int(xp))
    if ok and type(lv) == 'table' then return { n = Int(lv.n or 1), badge = tostring(lv.badge or 'grey') } end
    return { n = 1, badge = 'grey' }
end

local function Initials(name)
    local out = {}
    for word in tostring(name or ''):gmatch('[^%s]+') do
        if #out < 2 then out[#out + 1] = word:sub(1, 1):upper() end
    end
    return #out > 0 and table.concat(out) or '?'
end

-- The picture shown on a row (CP.Profile.avatarOf: approved only, never for a hidden name but the officer's own).
local function RowAvatar(e, own)
    local row = e.avatarRow or {}
    local ok, av = Call('Profile', 'avatarOf', row, { own = own })
    if ok and type(av) == 'table' then return av end
    local hidden = e.hideName and not own
    local initials = hidden and tostring(e.callsign or '?'):gsub('[^%w]', ''):sub(1, 2):upper() or Initials(e.name)
    return {
        kind = 'initials',
        value = nil,
        initials = initials ~= '' and initials or '?',
        frame = RowLevel(e.xp).badge,
    }
end
LB._rowAvatar = RowAvatar

local function PublicRow(e, viewer, metric)
    local own = viewer and viewer.citizenid == e.citizenid
    metric = metric or 'points'
    local value = e.value
    if value == nil then value = MetricValue(e, metric) end
    return {
        rank = e.rank or 0,
        citizenid = e.citizenid,
        name = own and viewer.name or LB.publicName(e),
        callsign = e.callsign,
        departmentShort = e.department and DeptShort(e.department) or '',
        points = e.points,
        runs = e.runs,
        failed = e.failed,
        value = value,
        metric = metric,
        level = RowLevel(e.xp),
        avatar = RowAvatar(e, own == true),
    }
end

-- fromDate/toDate are the window's dates in server time. The tablet shows those, because its own
-- reading of from/to follows the player's time zone and can land on the day before.
local function WindowView(q)
    if q.period == 'alltime' then return nil end
    local from, to = q.from, q.to
    if q.period == 'season' then
        if not q.season then return nil end
        from, to = q.season.startsAt, q.season.endsAt
    end
    return { from = from, to = to, fromDate = from and DateKey(from) or nil, toDate = to and DateKey(to) or nil }
end

local function SeasonView(q)
    if q.period ~= 'season' or not q.season then return nil end
    return { id = Int(q.season.id), name = q.season.name, active = q.season.active == true }
end

local function BoardView(data, viewer)
    local q = data.q
    local rows = {}
    local n = TopN()
    local metric = q.metric or 'points'
    for i = 1, math.min(n, #data.ranked) do rows[i] = PublicRow(data.ranked[i], viewer, metric) end
    local me = nil
    if viewer then
        local e = data.all[viewer.citizenid]
        if e then
            me = PublicRow(e, viewer, metric)
        else
            me = {
                rank = 0,
                citizenid = viewer.citizenid,
                name = viewer.name,
                callsign = viewer.callsign,
                departmentShort = viewer.departmentShort or DeptShort(viewer.department),
                points = 0,
                runs = 0,
                failed = 0,
                value = 0,
                metric = metric,
            }
            -- no row in this window: the level and picture still come from the officer's cp_officers row
            local okRow, orow = pcall(MySQL.single.await, [[SELECT display_name, callsign, hide_name, xp, avatar_kind,
                avatar_value, avatar_status FROM cp_officers WHERE citizenid = ?]], { viewer.citizenid })
            orow = okRow and type(orow) == 'table' and orow or { display_name = viewer.name }
            me.level = RowLevel(orow.xp)
            me.avatar = RowAvatar({ name = viewer.name, xp = orow.xp, avatarRow = orow }, true)
        end
    end
    return {
        period = q.period,
        filter = q.filter,
        department = q.department,
        metric = metric,
        minDecisions = metric == 'judgement' and MinDecisions() or nil,
        rows = rows,
        me = me,
        updatedAt = data.updatedAt,
        minRuns = MinRuns(),
        topN = n,
        ranked = #data.ranked,
        window = WindowView(q),
        season = SeasonView(q),
    }
end

-- Validate { period, filter, department } from the NUI. defaultDept fills department for that filter.
local function ParseBoardArgs(args, defaultDept)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    args = args or {}
    local period = args.period
    if period == nil then period = 'weekly' end
    if type(period) ~= 'string' or not PERIODS[period] then return nil, 'err.invalid_period' end
    local filter = args.filter
    if filter == nil then filter = 'overall' end
    if not ValidFilter(filter) then return nil, 'err.invalid_filter' end
    local metric = args.metric
    if metric == nil or metric == '' then metric = 'points' end
    if type(metric) ~= 'string' or not ValidMetric(metric) then return nil, 'err.invalid_metric' end
    local department = nil
    if filter == 'department' then
        department = args.department
        if department == nil or department == '' then department = defaultDept end
        if not IsDepartment(department) then return nil, 'err.unknown_department' end
    end
    return { period = period, filter = filter, department = department, metric = metric }
end

-- ============================================================================
--                                    CACHES
-- ============================================================================

function LB.invalidate()
    generation = generation + 1
    cache = {}
    seasonPointsCache = {}
    announceCache = nil
    if Has('Challenge', 'invalidate') then Call('Challenge', 'invalidate') end
end

function LB.seasonPoints(citizenid)
    if not ValidCitizenId(citizenid) then return 0 end
    local season = CurrentSeason()
    if not season then return 0 end
    local c = seasonPointsCache[citizenid]
    if c and c.seasonId == season.id and os.time() - c.at < CacheSeconds() then return c.value end
    Db()
    local gen = generation
    local v = MySQL.scalar.await(
        'SELECT COALESCE(SUM(final_points), 0) AS points FROM cp_mission_runs WHERE season_id = ? AND citizenid = ? AND voided = 0 AND flagged = 0',
        { Int(season.id), citizenid })
    local value = Int(v)
    if gen == generation then seasonPointsCache[citizenid] = { at = os.time(), seasonId = season.id, value = value } end
    return value
end

-- ============================================================================
--                                 RECOGNITION
-- ============================================================================

local function TopEntries(ranked, n)
    local out = {}
    for i = 1, math.min(n, #ranked) do
        local e = ranked[i]
        out[i] = {
            rank = i,
            citizenid = e.citizenid,
            name = LB.publicName(e),
            callsign = e.callsign,
            departmentShort = e.department and DeptShort(e.department) or '',
            points = e.points,
        }
    end
    return out
end

local function EntryLine(e)
    local who = e.name
    if e.callsign and e.callsign ~= e.name then who = ('%s %s'):format(e.callsign, e.name) end
    return CP.L('leaderboard.announce_entry',
        { rank = e.rank, name = who, points = FmtInt(e.points), department = e.departmentShort })
end

local function JoinEntries(entries)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = EntryLine(e) end
    return table.concat(parts, ' · ')
end

function LB.announcements()
    local now = os.time()
    local curWeek = WeekStart(now)
    local prevWeek = WeekStart(curWeek - HALF_DAY)
    local curMonth = MonthStart(now)
    local prevMonth = MonthStart(curMonth - HALF_DAY)
    local key = ('%d|%d'):format(curWeek, curMonth)
    if announceCache and announceCache.key == key and now - announceCache.at < CacheSeconds() then
        return U.deepcopy(announceCache.list)
    end
    local list = {}
    local gen = generation
    local weekRanked = LB.ranking({ period = 'range', filter = 'overall', from = prevWeek, to = curWeek })
    local weekTop = TopEntries(weekRanked, 3)
    if #weekTop > 0 then
        list[#list + 1] = {
            kind = 'weekly_top3',
            text = CP.L('leaderboard.announce_weekly', { week = DateKey(prevWeek), list = JoinEntries(weekTop) }),
            entries = weekTop,
            period = DateKey(prevWeek),
        }
    end
    local monthRanked = LB.ranking({ period = 'range', filter = 'overall', from = prevMonth, to = curMonth })
    local monthTop = TopEntries(monthRanked, 3)
    if #monthTop > 0 then
        list[#list + 1] = {
            kind = 'monthly_top3',
            text = CP.L('leaderboard.announce_monthly',
                { month = os.date('%Y-%m', prevMonth + HALF_DAY), list = JoinEntries(monthTop) }),
            entries = monthTop,
            period = os.date('%Y-%m', prevMonth + HALF_DAY),
        }
    end
    if gen == generation then announceCache = { at = now, key = key, list = list } end
    return U.deepcopy(list)
end

local function Webhook(title, description, fields)
    if not Has('Admin', 'webhook') then
        CP.log(TAG, 'no CP.Admin.webhook: %s', title)
        return false
    end
    return Call('Admin', 'webhook', 'board', title, description, fields)
end

-- The weekly reset job for the week [prevStart, curStart): top 3 to Discord and the Officer of the Week
-- badge. Idempotent: nothing happens when that week's badge already exists.
-- Optional weekly badges per metric (Config.Leaderboard.weeklyBadges, e.g. { 'arrests' }): "Top Arrests of the
-- Week" for #1 of that metric. Each badge is given once (its id names the week); points stay Officer of the Week.
local function WeeklyMetricBadges(prevStart, curStart, weekKey)
    local given = 0
    for _, metric in ipairs(Cfg('Leaderboard', 'weeklyBadges', {}) or {}) do
        if type(metric) == 'string' and METRICS[metric] and metric ~= 'points' then
            local badgeId = U.clip(('top_%s_%s'):format(metric, weekKey), 40)
            local done = MySQL.scalar.await('SELECT 1 AS done FROM cp_badges WHERE badge_id = ? LIMIT 1', { badgeId })
            if done == nil then
                local ranked = LB.ranking({
                    period = 'range',
                    filter = 'overall',
                    metric = metric,
                    from = prevStart,
                    to = curStart,
                    fresh = true,
                })
                local top = ranked[1]
                if top and (top.value or 0) > 0 then
                    local n = MySQL.update.await(
                        'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
                        { top.citizenid, badgeId, os.time() })
                    if Num(n) > 0 then
                        given = given + 1
                        CP.log(TAG, 'top %s of the week %s: %s', metric, weekKey, top.citizenid)
                    end
                end
            end
        end
    end
    return given
end
LB._weeklyMetricBadges = WeeklyMetricBadges

function LB._weeklyJob(prevStart, curStart)
    Db()
    prevStart = Int(prevStart)
    curStart = Int(curStart)
    if prevStart <= 0 or curStart <= prevStart then return false end
    local weekKey = DateKey(prevStart)
    WeeklyMetricBadges(prevStart, curStart, weekKey)
    local badgeId = U.clip('officer_of_week_' .. weekKey, 40)
    local done = MySQL.scalar.await('SELECT 1 AS done FROM cp_badges WHERE badge_id = ? LIMIT 1', { badgeId })
    if done ~= nil then
        CP.log(TAG, 'weekly job for %s already done', weekKey)
        return false
    end
    local ranked = LB.ranking({ period = 'range', filter = 'overall', from = prevStart, to = curStart, fresh = true })
    local top = TopEntries(ranked, 3)
    if #top == 0 then
        CP.log(TAG, 'week %s: nobody qualified for the board', weekKey)
        return false
    end
    local inserted = MySQL.update.await(
        'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { top[1].citizenid, badgeId, os.time() })
    if Num(inserted) <= 0 then return false end

    local fields = {}
    for i, e in ipairs(top) do
        fields[i] = {
            name = CP.L('leaderboard.webhook_place', { rank = i }),
            value = CP.L('leaderboard.webhook_entry', {
                name = e.callsign and e.callsign ~= e.name and ('%s %s'):format(e.callsign, e.name) or e.name,
                department = e.departmentShort,
                points = FmtInt(e.points),
            }),
            inline = true,
        }
    end
    Webhook(CP.L('leaderboard.webhook_weekly_title', { week = weekKey }),
        CP.L('leaderboard.webhook_weekly_desc', { name = top[1].name, points = FmtInt(top[1].points) }), fields)

    local ok, src = Call('Qbx', 'getByCitizenId', top[1].citizenid)
    if ok and src and Has('Tablet', 'notify') then
        Call('Tablet', 'notify', src, 'success', 'leaderboard.officer_of_week_notice', { week = weekKey })
    end
    CP.log(TAG, 'officer of the week %s: %s', weekKey, top[1].citizenid)
    return true
end

-- ============================================================================
--                                   PROFILE
-- ============================================================================

local function XpLevel(xp)
    local ok, lv = Call('Scoring', 'xpLevel', xp)
    if ok and type(lv) == 'table' and lv.label then return lv end
    local levels = {}
    for _, l in ipairs(Config.XPLevels or {}) do
        if type(l) == 'table' and tonumber(l.xp) then levels[#levels + 1] = l end
    end
    table.sort(levels, function(a, b) return Num(a.xp) < Num(b.xp) end)
    local cur, nxt = levels[1], nil
    for i, l in ipairs(levels) do
        if xp >= Num(l.xp) then cur = l; nxt = levels[i + 1] end
    end
    if not cur then return { label = CP.L('common.unknown'), badge = 'grey', xp = 0 } end
    return {
        label = tostring(cur.label),
        badge = tostring(cur.badge or 'grey'),
        xp = Int(cur.xp),
        next = nxt and Int(nxt.xp) or nil,
    }
end

local seasonNames = { at = 0, byId = {} }
local function SeasonName(id)
    id = Int(id)
    if os.time() - seasonNames.at > 300 or seasonNames.byId[id] == nil then
        local ok, rows = pcall(MySQL.query.await, 'SELECT id, name FROM cp_seasons', {})
        if ok and type(rows) == 'table' then
            seasonNames = { at = os.time(), byId = {} }
            for _, r in ipairs(rows) do seasonNames.byId[Int(r.id)] = tostring(r.name) end
        end
    end
    return seasonNames.byId[id] or ('#' .. id)
end

local function BadgeLabel(id)
    local week = id:match('^officer_of_week_(%d%d%d%d%-%d%d%-%d%d)$')
    if week then return CP.L('profile.badge.officer_of_week', { week = week }), 'week' end
    local sid = id:match('^season_(%d+)_champion$')
    if sid then return CP.L('profile.badge.season_champion', { season = SeasonName(sid) }), 'champion' end
    sid = id:match('^season_(%d+)_top10$')
    if sid then return CP.L('profile.badge.season_top10', { season = SeasonName(sid) }), 'top10' end
    local metric, mweek = id:match('^top_(%a+)_(%d%d%d%d%-%d%d%-%d%d)$')
    if metric and METRICS[metric] then
        return CP.L('profile.badge.top_metric', { metric = CP.L('leaderboard.metric.' .. metric), week = mweek }),
            'week'
    end
    return nil, 'achievement'
end

function LB.badgeLabel(id)
    if type(id) ~= 'string' then return nil, 'achievement' end
    return BadgeLabel(id)
end

local function BadgesFor(citizenid)
    local list = {}
    local ok, fromScoring = Call('Scoring', 'badges', citizenid)
    if ok and type(fromScoring) == 'table' then
        for _, b in ipairs(fromScoring) do
            if type(b) == 'table' then
                local id = b.id or b.badge_id
                if type(id) == 'string' then
                    list[#list + 1] = {
                        id = id,
                        label = b.label,
                        earnedTs = tonumber(b.earnedTs or b.earned_ts),
                        earnedAt = b.earnedAt or b.earned_at,
                    }
                end
            elseif type(b) == 'string' then
                list[#list + 1] = { id = b }
            end
        end
    else
        Db()
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
        local label, kind = BadgeLabel(b.id)
        if not label then
            label = type(b.label) == 'string' and b.label ~= '' and b.label ~= ('badge.' .. b.id) and b.label or nil
            if not label then
                local key = 'badge.' .. b.id
                label = CP.Locale.has(key) and CP.L(key) or b.id
            end
        end
        local earnedAt = b.earnedTs and SqlTs(b.earnedTs) or (type(b.earnedAt) == 'string' and b.earnedAt or '')
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

local function Disputable(row, own, nowTs, citizenid)
    if not own or AWARD_TYPES[row.mission_type] then return false end
    -- modules/disputes allows one dispute per row, ever: an open one blocks (err.dispute_open) and a
    -- decided one is final (err.dispute_final), so any cp_disputes row hides the button.
    if Num(row.disputes) ~= 0 then return false end
    if Has('Disputes', 'eligible') then
        -- The filing rule itself, so the button never offers what server:dispute would refuse.
        local ok, eligible = Call('Disputes', 'eligible', {
            citizenid = citizenid,
            mission_type = row.mission_type,
            state = row.state,
            flagged = row.flagged,
            voided = row.voided,
            created_ts = row.created_ts,
        }, citizenid, nowTs)
        if ok then return eligible == true end
    end
    if not (U.truthy(row.flagged) or U.truthy(row.voided) or row.state == 'failed') then return false end
    local windowS = Num(Cfg('Disputes', 'windowHours', 48)) * 3600
    local created = Num(row.created_ts)
    if created <= 0 or nowTs - created > windowS then return false end
    return true
end

-- RunResult fields (§9.6) a public profile may show: everything but the cash block, and none of the extra
-- keys some rows carry (a manual award's free-text admin reason, for example).
local PUBLIC_BREAKDOWN = {
    runId = true,
    missionLabel = true,
    missionType = true,
    result = true,
    endReason = true,
    test = true,
    tier = true,
    payTier = true,
    participants = true,
    departments = true,
    durationS = true,
    points = true,
    flagged = true,
}

-- staff: an admin's view (admin:getOfficerProfile), which always keeps the debrief.
local function ProfileRun(row, own, nowTs, citizenid, staff)
    local bd = U.jsonField(row.breakdown)
    if type(bd) ~= 'table' then bd = nil end
    if bd then
        if own then
            if type(bd.cash) == 'table' then bd.cash.status = row.cash_status end
            -- Config.Decisions.debrief = false: the officer's history leaves the ledger and the people out
            if not staff and Config.Decisions and Config.Decisions.debrief == false then
                bd.decisions, bd.people = nil, nil
            end
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
        id = Int(row.id),
        missionLabel = label,
        missionType = tostring(row.mission_type),
        state = tostring(row.state),
        endReason = tostring(row.end_reason),
        points = Int(row.final_points),
        cash = own and Int(row.cash_paid) or 0,
        cashStatus = own and tostring(row.cash_status or 'none') or '',
        flagged = U.truthy(row.flagged),
        voided = U.truthy(row.voided),
        createdAt = SqlTs(row.created_ts),
        createdTs = Int(row.created_ts),
        breakdown = bd,
        canDispute = Disputable(row, own, nowTs, citizenid),
    }
end

-- ============================================================================
--                                SERVICE RECORD
-- ============================================================================
-- Every stat but runs and success rate comes only from counted (not voided, not flagged) completed rows, the
-- archive included, so it follows voids and can't be farmed by abandoning. Averages are worked out in Lua.

local SERVICE_COLS = 'state, arrests, citations, impounds, vehicles_stopped, rescues, evidence, decisions_ok, '
    .. 'decisions_best, decisions_bad, lethal, medal, mission_call_id, response_s, '
    .. 'COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, \'$.points.bonuses[*].id\'), \'"rapid_response"\'), 0) AS rapid'

local SERVICE_SQL = [[
SELECT
  SUM(CASE WHEN u.state = 'completed' THEN 1 ELSE 0 END) AS completed,
  SUM(CASE WHEN u.state = 'failed' THEN 1 ELSE 0 END) AS failed,
  SUM(CASE WHEN u.state = 'completed' THEN u.arrests ELSE 0 END) AS arrests,
  SUM(CASE WHEN u.state = 'completed' THEN u.citations ELSE 0 END) AS citations,
  SUM(CASE WHEN u.state = 'completed' THEN u.impounds ELSE 0 END) AS impounds,
  SUM(CASE WHEN u.state = 'completed' THEN u.vehicles_stopped ELSE 0 END) AS vehicles_stopped,
  SUM(CASE WHEN u.state = 'completed' THEN u.rescues ELSE 0 END) AS rescues,
  SUM(CASE WHEN u.state = 'completed' THEN u.evidence ELSE 0 END) AS evidence,
  SUM(CASE WHEN u.state = 'completed' THEN u.decisions_ok ELSE 0 END) AS decisions_ok,
  SUM(CASE WHEN u.state = 'completed' THEN u.decisions_best ELSE 0 END) AS decisions_best,
  SUM(CASE WHEN u.state = 'completed' THEN u.decisions_bad ELSE 0 END) AS decisions_bad,
  SUM(CASE WHEN u.state = 'completed' THEN u.lethal ELSE 0 END) AS lethal,
  SUM(CASE WHEN u.state = 'completed' AND u.mission_call_id IS NOT NULL THEN 1 ELSE 0 END) AS calls,
  SUM(CASE WHEN u.state = 'completed' AND u.mission_call_id IS NOT NULL AND u.response_s IS NOT NULL THEN u.response_s ELSE 0 END) AS response_sum,
  SUM(CASE WHEN u.state = 'completed' AND u.mission_call_id IS NOT NULL AND u.response_s IS NOT NULL THEN 1 ELSE 0 END) AS response_n,
  SUM(CASE WHEN u.state = 'completed' AND u.rapid > 0 THEN 1 ELSE 0 END) AS rapid,
  SUM(CASE WHEN u.state = 'completed' AND u.medal = 1 THEN 1 ELSE 0 END) AS gold,
  SUM(CASE WHEN u.state = 'completed' AND u.medal = 2 THEN 1 ELSE 0 END) AS silver,
  SUM(CASE WHEN u.state = 'completed' AND u.medal = 3 THEN 1 ELSE 0 END) AS bronze
FROM (
  SELECT ]] .. SERVICE_COLS .. [[ FROM cp_mission_runs
  WHERE citizenid = ? AND voided = 0 AND flagged = 0 AND mission_type NOT IN ('manual_award', 'goal') %s
  UNION ALL
  SELECT ]] .. SERVICE_COLS .. [[ FROM cp_mission_runs_archive
  WHERE citizenid = ? AND voided = 0 AND flagged = 0 AND mission_type NOT IN ('manual_award', 'goal') %s
) u]]

-- ServiceStats (web/src/types/boards.ts) of an officer: lifetime, or one season (seasonId). lethal is kept apart
-- (the officer's own clean-arrest rate only) and never leaves this module in a public payload.
function LB.serviceRecord(citizenid, seasonId)
    if not ValidCitizenId(citizenid) then return nil end
    Db()
    local extra, params = '', { citizenid }
    if seasonId then extra = 'AND season_id = ?'; params[#params + 1] = Int(seasonId) end
    params[#params + 1] = citizenid
    if seasonId then params[#params + 1] = Int(seasonId) end
    local r = MySQL.single.await(SERVICE_SQL:format(extra, extra), params) or {}
    local completed, failed = Int(r.completed), Int(r.failed)
    local done = completed + failed
    local responseN = Int(r.response_n)
    return {
        completed = completed,
        failed = failed,
        successRate = done > 0 and math.floor(completed * 1000 / done + 0.5) / 10 or 0,
        arrests = Int(r.arrests),
        citations = Int(r.citations),
        impounds = Int(r.impounds),
        vehiclesStopped = Int(r.vehicles_stopped),
        rescues = Int(r.rescues),
        evidence = Int(r.evidence),
        decisionsOk = Int(r.decisions_ok),
        decisionsBest = Int(r.decisions_best),
        decisionsBad = Int(r.decisions_bad),
        calls = Int(r.calls),
        avgResponseS = responseN > 0 and math.floor(Int(r.response_sum) / responseN + 0.5) or nil,
        rapidResponses = Int(r.rapid),
        medals = { gold = Int(r.gold), silver = Int(r.silver), bronze = Int(r.bronze) },
    },
        Int(r.lethal)
end

local BESTS_SQL = [[
SELECT u.mission_id, u.mission_type, MIN(u.duration_s) AS best
FROM (
  SELECT mission_id, mission_type, duration_s FROM cp_mission_runs
  WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0 AND duration_s > 0
    AND mission_type NOT IN ('manual_award', 'goal')
  UNION ALL
  SELECT mission_id, mission_type, duration_s FROM cp_mission_runs_archive
  WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0 AND duration_s > 0
    AND mission_type NOT IN ('manual_award', 'goal')
) u
GROUP BY u.mission_id, u.mission_type]]

-- Fastest completion of each mission the officer has completed (never a mission they haven't played).
function LB.personalBests(citizenid)
    if not ValidCitizenId(citizenid) then return {} end
    Db()
    local out = {}
    for _, r in ipairs(MySQL.query.await(BESTS_SQL, { citizenid, citizenid }) or {}) do
        if Int(r.best) > 0 then
            out[#out + 1] = {
                missionId = tostring(r.mission_id),
                missionLabel = LB.missionLabel(r.mission_type, r.mission_id, nil),
                durationS = Int(r.best),
            }
        end
    end
    table.sort(out, function(a, b)
        if a.missionLabel ~= b.missionLabel then return a.missionLabel < b.missionLabel end
        return a.missionId < b.missionId
    end)
    return out
end

local PARTNER_SQL = [[
SELECT b.citizenid, COUNT(*) AS n
FROM %s a
INNER JOIN %s b ON b.run_uuid = a.run_uuid AND b.citizenid <> a.citizenid
WHERE a.citizenid = ? AND a.state = 'completed' AND a.voided = 0 AND a.flagged = 0
  AND a.mission_type NOT IN ('manual_award', 'goal')
GROUP BY b.citizenid]]

-- The officer they shared the most completed runs with (ties: the lower citizenid), or nil.
function LB.favouritePartner(citizenid)
    if not ValidCitizenId(citizenid) then return nil end
    Db()
    local counts = {}
    for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        for _, r in ipairs(MySQL.query.await(PARTNER_SQL:format(t, t), { citizenid }) or {}) do
            local cid = tostring(r.citizenid)
            counts[cid] = (counts[cid] or 0) + Int(r.n)
        end
    end
    local best, bestN = nil, 0
    for cid, n in pairs(counts) do
        if n > bestN or (n == bestN and best and cid < best) then best, bestN = cid, n end
    end
    if not best then return nil end
    local o = MySQL.single.await('SELECT display_name, callsign, hide_name FROM cp_officers WHERE citizenid = ?',
        { best }) or {}
    local e = { name = NonEmpty(o.display_name), callsign = NonEmpty(o.callsign), hideName = U.truthy(o.hide_name) }
    return { name = LB.publicName(e), callsign = e.callsign, runs = bestN }
end

-- LevelInfo (web/src/shared/types.ts): xp is the officer's XP, levelXp and nextLevelXp where the level starts
-- and the next one does; next is kept for old callers.
local function LevelInfo(xp)
    local lv = XpLevel(xp)
    return {
        n = Int(lv.n or 1),
        label = tostring(lv.label or ''),
        badge = tostring(lv.badge or 'grey'),
        xp = Int(xp),
        levelXp = Int(lv.levelXp or lv.xp),
        nextLevelXp = tonumber(lv.nextLevelXp or lv.next),
        prestige = Int(lv.prestige),
        next = tonumber(lv.nextLevelXp or lv.next),
    }
end
LB._levelInfo = LevelInfo

local function Commendations(cid)
    local ok, list = Call('Profile', 'commendations', cid)
    if ok and type(list) == 'table' then return list end
    return {}
end

local function MdtCommendations(cid)
    if Cfg('Profile', 'showMdtCommendations', false) ~= true then return nil end
    local ok, list = Call('Dispatch', 'mdtCommendations', cid)
    if ok and type(list) == 'table' then return list end
    return nil
end

-- opts.staff (admin:getOfficerProfile): the real name and every run field, as the officer sees them.
function LB.profile(viewer, target, opts)
    Db()
    opts = type(opts) == 'table' and opts or {}
    local staff = opts.staff == true
    local own = target == nil or target == viewer.citizenid
    local cid = own and viewer.citizenid or target
    local orow = MySQL.single.await([[SELECT citizenid, display_name, callsign, rank_label, department, xp, hide_name,
        bio, avatar_kind, avatar_value, avatar_status FROM cp_officers WHERE citizenid = ?]], { cid })
    if not own and not orow then return nil, 'err.unknown_officer' end
    orow = orow or {}
    local hideName = U.truthy(orow.hide_name)
    local xp = Int(orow.xp)
    local e = { name = NonEmpty(orow.display_name), callsign = NonEmpty(orow.callsign), hideName = hideName }
    local dept = own and viewer.department or NonEmpty(orow.department)
    local d = DeptInfo(dept)
    local nowTs = os.time()
    local full = own or staff
    local rows = MySQL.query.await(PROFILE_RUNS_SQL, { cid, PROFILE_RUNS }) or {}
    local runs = {}
    for i, row in ipairs(rows) do runs[i] = ProfileRun(row, full, nowTs, cid, staff) end
    if staff then
        for _, r in ipairs(runs) do r.canDispute = false end
    end
    local season = CurrentSeason()
    local lifetime, lethal = LB.serviceRecord(cid)
    local cleanRate = nil
    if own and lifetime and lifetime.arrests + lethal > 0 then
        cleanRate = math.floor(lifetime.arrests * 1000 / (lifetime.arrests + lethal) + 0.5) / 10
    end
    if not orow.display_name and own then orow.display_name = viewer.name end
    local avatar = RowAvatar({ name = e.name, callsign = e.callsign, hideName = hideName, xp = xp, avatarRow = orow },
        own or staff)
    return {
        citizenid = cid,
        name = own and viewer.name or (staff and (e.name or CP.L('common.unknown'))) or LB.publicName(e),
        callsign = own and viewer.callsign or e.callsign,
        rank = own and viewer.rank or (NonEmpty(orow.rank_label) or ''),
        departmentShort = own and viewer.departmentShort or (d and d.short or ''),
        departmentLabel = own and viewer.departmentLabel or (d and d.label or ''),
        xp = xp,
        level = LevelInfo(xp),
        avatar = avatar,
        bio = NonEmpty(orow.bio),
        badges = BadgesFor(cid),
        commendations = Commendations(cid),
        mdtCommendations = MdtCommendations(cid),
        service = { lifetime = lifetime, season = season and LB.serviceRecord(cid, season.id) or nil },
        bests = LB.personalBests(cid),
        favouritePartner = LB.favouritePartner(cid),
        cleanArrestRate = cleanRate,
        hideName = hideName,
        own = own,
        runs = runs,
        seasonPoints = LB.seasonPoints(cid),
        disputeWindowHours = Num(Cfg('Disputes', 'windowHours', 48)),
    }
end

-- ============================================================================
--                               ADMIN BOARD DATA
-- ============================================================================

local function NormaliseStuck(list)
    local out = {}
    for _, p in ipairs(list or {}) do
        if type(p) == 'table' then
            local rowId = Int(p.rowId or p.id)
            local runUuid = p.runUuid or p.run_uuid
            local cid = p.citizenid
            out[#out + 1] = {
                rowId = rowId,
                runUuid = runUuid and tostring(runUuid) or '',
                citizenid = cid and tostring(cid) or '',
                name = p.name or p.display_name,
                callsign = p.callsign,
                missionLabel = p.missionLabel
                    or LB.missionLabel(p.missionType or p.mission_type, p.missionId or p.mission_id, nil),
                amount = Int(p.amount or p.cashBase or p.cash_base),
                createdAt = (type(p.createdAt) == 'number' and SqlTs(p.createdAt))
                    or (type(p.createdAt) == 'string' and p.createdAt) or (p.created_ts and SqlTs(p.created_ts)) or '',
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

local function StuckPayments()
    local ok, list = Call('Cash', 'stuckPayments')
    if ok and type(list) == 'table' then return NormaliseStuck(list) end
    Db()
    return NormaliseStuck(MySQL.query.await(STUCK_SQL, {}) or {})
end
LB._stuckPayments = StuckPayments

local function AdminRow(e, metric)
    local r = PublicRow(e, nil, metric)
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

local function AdminRuns(q, citizenid)
    local list = {}
    if q.period == 'season' and not q.seasonId then return list end
    local rows
    if q.period == 'alltime' then
        rows = MySQL.query.await(ADMIN_RUNS_SQL:format('1 = 1'), { citizenid, ADMIN_RUNS }) or {}
    else
        local where, params = WhereFor(q)
        local all = { citizenid }
        for _, p in ipairs(params) do all[#all + 1] = p end
        all[#all + 1] = ADMIN_RUNS
        rows = MySQL.query.await(ADMIN_RUNS_SQL:format(where), all) or {}
    end
    for _, r in ipairs(rows) do
        list[#list + 1] = {
            id = Int(r.id),
            runUuid = tostring(r.run_uuid),
            missionLabel = LB.missionLabel(r.mission_type, r.mission_id, nil),
            missionType = tostring(r.mission_type),
            state = tostring(r.state),
            endReason = tostring(r.end_reason),
            points = Int(r.final_points),
            cash = Int(r.cash_paid),
            cashStatus = tostring(r.cash_status),
            flagged = U.truthy(r.flagged),
            flagReason = r.flag_reason,
            voided = U.truthy(r.voided),
            departmentShort = DeptShort(r.department),
            participants = Int(r.participants),
            departments = Int(r.departments_n),
            tier = tostring(r.tier),
            createdAt = SqlTs(r.created_ts),
            createdTs = Int(r.created_ts),
        }
    end
    return list
end

function LB.adminBoard(args)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    args = args or {}
    local q, err = ParseBoardArgs(args, FirstDepartment())
    if not q then return nil, err end
    local cid = args.citizenid
    if cid ~= nil and not ValidCitizenId(cid) then return nil, 'err.invalid_citizenid' end
    local data = GetBoardData(q)
    local rows, unranked = {}, {}
    for i, e in ipairs(data.ranked) do rows[i] = AdminRow(e, data.q.metric) end
    local rest = {}
    for _, e in pairs(data.all) do
        if (e.rank or 0) == 0 then rest[#rest + 1] = e end
    end
    table.sort(rest, Compare)
    for i, e in ipairs(rest) do unranked[i] = AdminRow(e, data.q.metric) end
    local out = {
        period = data.q.period,
        filter = data.q.filter,
        department = data.q.department,
        metric = data.q.metric,
        rows = rows,
        unranked = unranked,
        stuck = StuckPayments(),
        minRuns = MinRuns(),
        updatedAt = data.updatedAt,
        window = WindowView(data.q),
        season = SeasonView(data.q),
    }
    if cid then out.citizenid = cid; out.runs = AdminRuns(data.q, cid) end
    return out
end

-- ============================================================================
--                                 NET HANDLERS
-- ============================================================================

CP.Net.callback('getBoard', function(src, args)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    local q, err = ParseBoardArgs(args, officer.department)
    if not q then return nil, err end
    return BoardView(GetBoardData(q), officer)
end)

local function ParseCitizenArg(args)
    if args == nil then return nil end
    if type(args) == 'string' then
        if args == '' then return nil end
        return ValidCitizenId(args) and args or false
    end
    if type(args) ~= 'table' then return false end
    local cid = args.citizenid
    if cid == nil or cid == '' then return nil end
    return ValidCitizenId(cid) and cid or false
end

CP.Net.callback('getProfile', function(src, args)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    local target = ParseCitizenArg(args)
    if target == false then return nil, 'err.invalid_payload' end
    return LB.profile(officer, target)
end)

CP.Net.action('server:setHideName', function(src, payload)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return false, errKey end
    local value = payload
    if type(payload) == 'table' then value = payload.hideName end
    if type(value) ~= 'boolean' then return false, 'err.invalid_payload' end
    Db()
    MySQL.update.await([[INSERT INTO cp_officers (citizenid, callsign, display_name, department, hide_name)
          VALUES (?, NULLIF(?, ''), ?, ?, ?)
          ON DUPLICATE KEY UPDATE hide_name = VALUES(hide_name)]], {
        officer.citizenid,
        U.clip(officer.callsign or '', 32),
        U.clip(officer.name or '', 64),
        officer.department,
        value and 1 or 0,
    })
    LB.invalidate()
    CP.log(TAG, '%s hide_name = %s', officer.citizenid, tostring(value))
    return true, { hideName = value }
end, { rate = 2 })

CP.Net.callback('admin:getBoards', function(src, args)
    local ok, errKey = CP.Permissions.can(src, 'openAdmin')
    if not ok then return nil, errKey end
    return LB.adminBoard(args)
end)

-- ============================================================================
--                                    START
-- ============================================================================

function LB._boot()
    if booted then return end
    booted = true
    if Has('Schedule', 'onWeekly') then
        CP.Schedule.onWeekly(function(_, prevWeekStartTs)
            LB.invalidate()
            local curStart = WeekStart(os.time())
            local prev = tonumber(prevWeekStartTs) or WeekStart(curStart - HALF_DAY)
            LB._weeklyJob(prev, curStart)
        end)
        CP.Schedule.onMonthly(function(monthStartTs)
            LB.invalidate()
            CP.log(TAG, 'monthly reset %s: top 3 of the last month is now announced on Home',
                DateKey(tonumber(monthStartTs) or os.time()))
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
        local curStart = WeekStart(os.time())
        LB._weeklyJob(WeekStart(curStart - HALF_DAY), curStart)
    end)
    if not ok then CP.err(TAG, 'weekly catch-up failed: %s', tostring(err)) end
end)
