-- modules/challenge/server.lua · CP.Challenge (server): seasons, the department challenge, the weekly
-- bounty and the supervisor Department Report.
--
-- Owns
--   * cp_seasons (start / end, the cached current season every run row is tagged with)
--   * cp_dept_bounties: one row per (season_id, week) with week = 1, 2 ... counted in weekly resets since
--     the season started (week 1 runs from the season start to the first weekly reset). The objective is
--     picked with CP.U.rng(CP.U.hash('<seasonId>:<week>')) from Config.Challenge.bounties, so a restart
--     picks the same one; an admin may override the current week's objective while it is open.
--     winner: NULL = week still open, '' = closed without a winner, else the winning department key.
--     week = 0 (objective 'season_champion') stores the season's champion department at season end.
--   * the season end: champion by Config.Challenge.scoring and the tie-break, "Season X Champions" banner
--     data, trophy badges season_<id>_champion (champion members with minRunsActive completed runs),
--     season_<id>_top10 badges (top 10 of the season board), the board webhook with the results
--   * callbacks getChallenge, getDeptContributors, admin:getSeasons, sup:getDeptReport,
--     sup:getOfficerActivity and the actions server:admin:startSeason, server:admin:endSeason,
--     server:admin:overrideBounty
--
-- Challenge rules (SPEC "Department challenge")
--   Season rows = cp_mission_runs with season_id = the season, voided = 0 AND flagged = 0, grouped by the
--   row's department (the department at the end of the run, so transfers keep old points; joint runs
--   count for each participant's own department). Active officer = minRunsActive completed runs
--   (manual_award / goal rows never count as runs) in that department this season.
--   Weekly bounty bonus = floor(bountyBonus x the winning department's season points that week), added
--   to that department's points pool once its week is closed:
--     average: (points of active officers + bonuses) / active officers
--     total:   all points + bonuses
--     top10:   the 10 best officers' points + bonuses
--   Ranking and tie-break: score, then completed runs, then unit runs (2+ participants).
--   Bounty winner: highest count per active officer (season-to-date active officers) for the objective
--   (most_tactical: completed Tactical runs, most_cross: completed runs with 2+ departments, most_unit:
--   completed runs with 2+ participants, most_completed: completed runs), tie-break completed runs then
--   unit runs that week; no winner when every count is 0 or the tie cannot be broken. Weeks close at the
--   weekly reset, as a catch-up after start (a server that was down across the reset) and at season end.
--   A department added to Config.Departments mid-season simply starts at 0.
--
-- Public API (docs/ARCHITECTURE.md §5.23)
--   CP.Challenge.currentSeason(reload?) -> { id, name, startsAt, endsAt|nil, active = true } | nil   (cached)
--   CP.Challenge.latestSeason() -> the active season, else the last ended one (the Season board)
--   CP.Challenge.seasonById(id) -> season | nil
--   CP.Challenge.startSeason(src, name) -> ok, seasonView | errKey   (ends the running season first)
--   CP.Challenge.endSeason(src, reason?) -> ok, { season, standings, champion, top10 } | errKey
--   CP.Challenge.standings(seasonId?) -> { seasonId, mode, departments = { { key, label, short, colour,
--       score, activeOfficers, officers, points, completed, unitRuns, bonus, rank } } }
--   CP.Challenge.bounty(weekKey?) -> { seasonId, week, id, label, winner|nil, closed, startsAt, endsAt,
--       overridden } | nil        (weekKey = 'YYYY-MM-DD' of a week start; default the current week)
--   CP.Challenge.overrideBounty(src, objective) -> ok, bountyView | errKey
--   CP.Challenge.championBanner(dept?) -> { season, department (label), departmentKey, short } | nil
--       the last ended season's champion; nil when dept is given and is not the champion
--   CP.Challenge.invalidate()  (hook, called by CP.Leaderboard.invalidate) drops the challenge caches
--   callback getChallenge -> ChallengeView (§9.4) plus { enabled, mode, minRunsActive, myDepartment,
--       season.week, season.startsAt, departments[i].rank/points/bonus, bounty.leaderKey/week/endsIn/
--       overridden/rates = { { key, short, colour, count, activeOfficers, rate } }, topContributors[i].citizenid }
--   callback getDeptContributors({ department }) -> { department = { key, label, short, colour }, season,
--       minRunsActive, contributors = { { rank, citizenid, name, callsign, points, runs, active } } }
--   callback admin:getSeasons ('seasons') -> { current, latest, standings, bounty, bountyHistory = { {
--       seasonId, seasonName, week, objective, label, winner, winnerShort, bonus, closed, current,
--       startsAt, endsAt } }, seasons = { { id, name, startsAt, endsAt, active, champion, championShort } },
--       bounties = { { id, label } }, enabled, weeklyBounty, mode, seasonWeeks, minRunsActive }
--   action server:admin:startSeason { name }    ('seasons', audited 'season_start')
--   action server:admin:endSeason               ('seasons', audited 'season_end')
--   action server:admin:overrideBounty { objective }   ('bountyOverride', audited 'bounty_override')
--   callback sup:getDeptReport({ department? })  (supervisors and admins: CP.Permissions 'viewMissionList';
--       department only for admins) -> { department, season, standing, standings, bounty, week = { key,
--       startsAt }, officers = { { citizenid, name, callsign, rank, runs, completed, failed, abandoned,
--       flagged, points, cash, lastRunAt, lastRunTs } } }
--   callback sup:getOfficerActivity({ citizenid, department? }) -> { officer = { citizenid, name, callsign,
--       rank, departmentShort }, week, runs = { { id, missionLabel, missionType, state, endReason, points,
--       cash, cashStatus, flagged, flagReason, voided, participants, departments, tier, durationS,
--       createdAt, createdTs } } }   only officers of the supervisor's department (err.other_department)
-- Test hooks: CP.Challenge._boot(), _weekIndex(season, ts), _weekWindow(season, n), _pickBounty(seasonId, week),
--   _closeDueWeeks(season, nowTs, includeCurrent), _collect(seasonId, fresh), _standingsFrom(data)

CP.Challenge = CP.Challenge or {}
local C = CP.Challenge
local U = CP.U
local TAG = 'challenge'

local WEEK_S = 604800
local HALF_DAY = 43200
local SEASON_RELOAD_S = 300
local CHAMPION_WEEK = 0
local CHAMPION_OBJECTIVE = 'season_champion'
local MAX_WEEK = 127
local BOOT_DELAY_MS = 1500
local HISTORY_LIMIT = 60
local CONTRIBUTORS_LIMIT = 200
local ACTIVITY_LIMIT = 100
local BOUNTY_KINDS = { most_tactical = 'tactical', most_cross = 'cross', most_unit = 'unit', most_completed = 'completed' }
local SCORING = { average = true, total = true, top10 = true }

local seasons = { at = 0, loaded = false, current = nil, latest = nil, byId = {}, list = {} }
local collectCache = {}    -- seasonId -> data
local collectGen = 0       -- bumped by invalidate(): aggregates read before it are not cached
local bannerCache = nil    -- { at, row }
local busy = false
local booted = false
local warned = {}

-- ── helpers ─────────────────────────────────────────────────────────────────
local function num(v) return tonumber(v) or 0 end
local function int(v) return math.floor(num(v) + 0.0) end

local function cfg(section, key, default)
    local s = Config[section]
    local v = type(s) == 'table' and s[key] or nil
    if v == nil then return default end
    return v
end

local function cacheSeconds() return math.max(0, num(cfg('Leaderboard', 'cacheSeconds', 60))) end
local function minActive() return math.max(0, int(cfg('Challenge', 'minRunsActive', 3))) end
local function challengeOn() return cfg('Challenge', 'enabled', true) ~= false end
local function bountiesOn() return challengeOn() and cfg('Challenge', 'weeklyBounty', true) ~= false end
local function bonusShare() return math.max(0, num(cfg('Challenge', 'bountyBonus', 0.10))) end
local function seasonWeeks() return math.max(0, int(cfg('Leaderboard', 'seasonWeeks', 8))) end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function scoringMode()
    local m = cfg('Challenge', 'scoring', 'average')
    if not SCORING[m] then
        warnOnce('scoring', 'Config.Challenge.scoring %s is not average, total or top10; using average', tostring(m))
        return 'average'
    end
    return m
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function has(mod, fn)
    return type(CP[mod]) == 'table' and type(CP[mod][fn]) == 'function'
end

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

local function nonEmpty(s)
    if type(s) ~= 'string' then return nil end
    s = U.trim(s)
    if s == '' then return nil end
    return s
end

local function sqlTs(ts) return os.date('%Y-%m-%d %H:%M:%S', math.floor(num(ts))) end

local function fmtInt(n)
    local s = tostring(math.floor(num(n)))
    local neg = s:sub(1, 1) == '-'
    if neg then s = s:sub(2) end
    local out = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
    if out:sub(1, 1) == ',' then out = out:sub(2) end
    return (neg and '-' or '') .. out
end

local function placeholders(n)
    local t = {}
    for i = 1, n do t[i] = '?' end
    return table.concat(t, ', ')
end

-- ── calendar ────────────────────────────────────────────────────────────────
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
    return os.time({ year = y, month = m, day = d - (wday - 2) % 7, hour = resetHour(), min = 0, sec = 0 })
end

local function noonOf(ts)
    local t = os.date('*t', ts)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = 12, min = 0, sec = 0 })
end

-- Week number (1-based) of ts in the season: weekly resets passed since the season started, plus one.
local function weekIndex(season, ts)
    local days = math.floor((noonOf(weekStart(ts)) - noonOf(weekStart(season.startsAt))) / 86400 + 0.5)
    if days < 0 then return 1 end
    return math.min(MAX_WEEK, math.floor(days / 7 + 0.5) + 1)
end

local function rawWeekStart(season, n)
    local t = os.date('*t', weekStart(season.startsAt))
    return os.time({ year = t.year, month = t.month, day = t.day + 7 * (n - 1), hour = resetHour(), min = 0, sec = 0 })
end

-- [from, to) of week n (clipped to the season's start and end).
local function weekWindow(season, n)
    local from = math.max(rawWeekStart(season, n), season.startsAt)
    local to = rawWeekStart(season, n + 1)
    if season.endsAt and season.endsAt < to then to = season.endsAt end
    return from, to
end

-- A timestamp inside the reset-adjusted day whose date is dayTs (midnight of that date).
local function insideDay(dayTs)
    local t = os.date('*t', dayTs + HALF_DAY)
    return os.time({ year = t.year, month = t.month, day = t.day, hour = resetHour(), min = 30, sec = 0 })
end

local function weeksLeft(season, nowTs)
    if not season.active then return 0 end
    local endTs = season.startsAt + seasonWeeks() * WEEK_S
    return math.max(0, math.ceil((endTs - nowTs) / WEEK_S))
end

C._weekIndex = weekIndex
C._weekWindow = weekWindow

-- ── departments ─────────────────────────────────────────────────────────────
local function departmentList()
    local out = {}
    if has('Access', 'departments') then
        local ok, list = call('Access', 'departments')
        if ok and type(list) == 'table' then
            for _, d in ipairs(list) do
                out[#out + 1] = { key = d.key, label = d.label, short = d.short, colour = d.theme and d.theme.primary or '#a4161a' }
            end
            return out
        end
    end
    local keys = {}
    for k, v in pairs(Config.Departments or {}) do
        if type(k) == 'string' and type(v) == 'table' then keys[#keys + 1] = k end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local d = Config.Departments[k]
        local primary = type(d.theme) == 'table' and d.theme.primary or nil
        out[#out + 1] = { key = k, label = tostring(d.label or k), short = tostring(d.short or k:upper()),
            colour = U.isHexColour(primary) and primary:lower() or '#a4161a' }
    end
    return out
end

local function deptInfo(key)
    for _, d in ipairs(departmentList()) do
        if d.key == key then return d end
    end
    return nil
end

local function deptShort(key)
    local d = deptInfo(key)
    return d and d.short or (type(key) == 'string' and key:upper() or '')
end

local function isDepartment(key)
    return type(key) == 'string' and type(Config.Departments) == 'table' and type(Config.Departments[key]) == 'table'
end

-- ── seasons ─────────────────────────────────────────────────────────────────
local function seasonFrom(row)
    return {
        id = int(row.id), name = tostring(row.name), startsAt = int(row.starts_ts),
        endsAt = row.ends_ts ~= nil and int(row.ends_ts) or nil, active = U.truthy(row.active),
    }
end

local function loadSeasons()
    db()
    local rows = MySQL.query.await(
        'SELECT id, name, UNIX_TIMESTAMP(starts_at) AS starts_ts, UNIX_TIMESTAMP(ends_at) AS ends_ts, active FROM cp_seasons ORDER BY id DESC',
        {}) or {}
    local s = { at = os.time(), loaded = true, byId = {}, list = {} }
    local actives = 0
    for _, row in ipairs(rows) do
        local season = seasonFrom(row)
        s.byId[season.id] = season
        s.list[#s.list + 1] = season
        if season.active then
            actives = actives + 1
            if not s.current then s.current = season end
        end
    end
    if actives > 1 then warnOnce('actives', '%d seasons are marked active in cp_seasons; season %d is used', actives, s.current.id) end
    s.latest = s.current or s.list[1]
    seasons = s
    return s
end

local function ensureSeasons(reload)
    if reload or not seasons.loaded or os.time() - seasons.at > SEASON_RELOAD_S then loadSeasons() end
    return seasons
end

function C.currentSeason(reload)
    local s = ensureSeasons(reload).current
    return s and U.copy(s) or nil
end

function C.latestSeason()
    local s = ensureSeasons(false).latest
    return s and U.copy(s) or nil
end

function C.seasonById(id)
    id = int(id)
    local s = ensureSeasons(false).byId[id]
    if not s then s = ensureSeasons(true).byId[id] end
    return s and U.copy(s) or nil
end

-- ── bounties ────────────────────────────────────────────────────────────────
local function bountyList()
    local out = {}
    for _, b in ipairs(cfg('Challenge', 'bounties', {}) or {}) do
        if type(b) == 'table' and type(b.id) == 'string' and b.id ~= '' and #b.id <= 40 then
            if not BOUNTY_KINDS[b.id] then
                warnOnce('bounty.' .. b.id, 'Config.Challenge.bounties id %s is not one of most_tactical, most_cross, most_unit, most_completed; it counts completed runs', b.id)
            end
            local key = 'challenge.bounty.' .. b.id
            out[#out + 1] = { id = b.id, label = CP.Locale.has(key) and CP.L(key) or tostring(b.label or b.id) }
        end
    end
    return out
end

local function bountyLabel(id)
    for _, b in ipairs(bountyList()) do
        if b.id == id then return b.label end
    end
    local key = 'challenge.bounty.' .. tostring(id)
    return CP.Locale.has(key) and CP.L(key) or tostring(id)
end

local function isBounty(id)
    for _, b in ipairs(bountyList()) do
        if b.id == id then return true end
    end
    return false
end

local function pickBounty(seasonId, week)
    local list = bountyList()
    if #list == 0 then return nil end
    local rng = U.rng(U.hash(('%d:%d'):format(int(seasonId), int(week))))
    local b = rng:pick(list)
    return b and b.id or nil
end
C._pickBounty = pickBounty

local BOUNTY_ROW_SQL = 'SELECT objective, winner FROM cp_dept_bounties WHERE season_id = ? AND week = ?'

-- The bounty row of week n (created with the seeded pick when missing).
local function ensureBounty(season, n)
    if not bountiesOn() or n < 1 or n > MAX_WEEK then return nil end
    db()
    local row = MySQL.single.await(BOUNTY_ROW_SQL, { season.id, n })
    if not row then
        local id = pickBounty(season.id, n)
        if not id then
            warnOnce('nobounties', 'Config.Challenge.bounties is empty: no weekly bounty')
            return nil
        end
        MySQL.update.await('INSERT IGNORE INTO cp_dept_bounties (season_id, week, objective) VALUES (?, ?, ?)', { season.id, n, id })
        row = MySQL.single.await(BOUNTY_ROW_SQL, { season.id, n })
        if not row then return nil end
        CP.log(TAG, 'season %d week %d bounty: %s', season.id, n, id)
    end
    return { week = n, objective = tostring(row.objective), winner = row.winner ~= nil and tostring(row.winner) or nil }
end

-- ── season aggregates ───────────────────────────────────────────────────────
local OFFICER_SQL = [[
SELECT r.department, r.citizenid,
  SUM(r.final_points) AS points,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS completed,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') AND r.participants >= 2 THEN 1 ELSE 0 END) AS unit_runs
FROM cp_mission_runs r
WHERE r.season_id = ? AND r.voided = 0 AND r.flagged = 0
GROUP BY r.department, r.citizenid]]

local DAY_SQL = [[
SELECT r.department, UNIX_TIMESTAMP(DATE(r.created_at - INTERVAL ? HOUR)) AS day_ts,
  SUM(r.final_points) AS points,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS completed,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') AND r.participants >= 2 THEN 1 ELSE 0 END) AS unit_runs,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type = 'tactical' THEN 1 ELSE 0 END) AS tactical,
  SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') AND r.departments_n >= 2 THEN 1 ELSE 0 END) AS cross_runs
FROM cp_mission_runs r
WHERE r.season_id = ? AND r.voided = 0 AND r.flagged = 0
GROUP BY r.department, day_ts]]

local function emptyWeek()
    return { points = 0, completed = 0, unit = 0, tactical = 0, cross = 0 }
end

-- Every aggregate the standings, bounties and contributor lists need, cached per season.
local function collect(seasonId, fresh)
    seasonId = int(seasonId)
    local c = collectCache[seasonId]
    if not fresh and c and os.time() - c.at < cacheSeconds() then return c end
    local season = C.seasonById(seasonId)
    if not season then return nil end
    db()
    local gen = collectGen
    local data = { at = os.time(), season = season, officers = {}, weeks = {}, bounties = {} }
    for _, r in ipairs(MySQL.query.await(OFFICER_SQL, { seasonId }) or {}) do
        local dept = tostring(r.department)
        data.officers[dept] = data.officers[dept] or {}
        data.officers[dept][tostring(r.citizenid)] = { points = int(r.points), completed = int(r.completed), unitRuns = int(r.unit_runs) }
    end
    for _, r in ipairs(MySQL.query.await(DAY_SQL, { resetHour(), seasonId }) or {}) do
        local n = weekIndex(season, insideDay(int(r.day_ts)))
        local dept = tostring(r.department)
        data.weeks[n] = data.weeks[n] or {}
        local w = data.weeks[n][dept] or emptyWeek()
        w.points = w.points + int(r.points)
        w.completed = w.completed + int(r.completed)
        w.unit = w.unit + int(r.unit_runs)
        w.tactical = w.tactical + int(r.tactical)
        w.cross = w.cross + int(r.cross_runs)
        data.weeks[n][dept] = w
    end
    for _, r in ipairs(MySQL.query.await('SELECT week, objective, winner FROM cp_dept_bounties WHERE season_id = ? AND week >= 1', { seasonId }) or {}) do
        data.bounties[int(r.week)] = { objective = tostring(r.objective), winner = r.winner ~= nil and tostring(r.winner) or nil }
    end
    if gen == collectGen then collectCache[seasonId] = data end
    return data
end
C._collect = collect

local function activeCount(data, dept)
    local n = 0
    for _, o in pairs((data and data.officers[dept]) or {}) do
        if o.completed >= minActive() then n = n + 1 end
    end
    return n
end

local function weekStats(data, n, dept)
    local w = data and data.weeks[n]
    return (w and w[dept]) or emptyWeek()
end

local function bonusFor(data, dept)
    local total = 0
    if not data then return 0 end
    for n, b in pairs(data.bounties) do
        if b.winner == dept then total = total + math.floor(bonusShare() * weekStats(data, n, dept).points) end
    end
    return total
end

local function standingsCompare(a, b)
    if a.scoreRaw ~= b.scoreRaw then return a.scoreRaw > b.scoreRaw end
    if a.completed ~= b.completed then return a.completed > b.completed end
    if a.unitRuns ~= b.unitRuns then return a.unitRuns > b.unitRuns end
    return a.key < b.key
end

-- Standings list for every department in Config.Departments (0 for departments without rows).
local function standingsFrom(data)
    local mode = scoringMode()
    local list = {}
    for _, d in ipairs(departmentList()) do
        local offs = (data and data.officers[d.key]) or {}
        local total, activePts, active, officers, completed, unitRuns = 0, 0, 0, 0, 0, 0
        local pts = {}
        for _, o in pairs(offs) do
            officers = officers + 1
            total = total + o.points
            completed = completed + o.completed
            unitRuns = unitRuns + o.unitRuns
            pts[#pts + 1] = o.points
            if o.completed >= minActive() then
                active = active + 1
                activePts = activePts + o.points
            end
        end
        local bonus = bonusFor(data, d.key)
        local raw
        if mode == 'total' then
            raw = total + bonus
        elseif mode == 'top10' then
            table.sort(pts, function(a, b) return a > b end)
            raw = bonus
            for i = 1, math.min(10, #pts) do raw = raw + pts[i] end
        else
            raw = active > 0 and (activePts + bonus) / active or 0
        end
        list[#list + 1] = {
            key = d.key, label = d.label, short = d.short, colour = d.colour,
            score = U.round(raw), scoreRaw = raw, activeOfficers = active, officers = officers,
            points = total, completed = completed, unitRuns = unitRuns, bonus = bonus,
        }
    end
    table.sort(list, standingsCompare)
    for i, e in ipairs(list) do e.rank = i end
    return list
end
C._standingsFrom = standingsFrom

local function publicStanding(e)
    return { key = e.key, label = e.label, short = e.short, colour = e.colour, score = e.score,
        activeOfficers = e.activeOfficers, officers = e.officers, points = e.points, completed = e.completed,
        unitRuns = e.unitRuns, bonus = e.bonus, rank = e.rank }
end

local function publicStandings(list)
    local out = {}
    for i, e in ipairs(list) do out[i] = publicStanding(e) end
    return out
end

function C.standings(seasonId)
    local season = seasonId and C.seasonById(seasonId) or C.currentSeason()
    local data = season and collect(season.id) or nil
    return { seasonId = season and season.id or nil, mode = scoringMode(), departments = publicStandings(standingsFrom(data)) }
end

-- Per-department bounty counts per active officer for week n, best first.
local function bountyRates(data, n, objective)
    local kind = BOUNTY_KINDS[objective] or 'completed'
    local list = {}
    for _, d in ipairs(departmentList()) do
        local w = weekStats(data, n, d.key)
        local active = activeCount(data, d.key)
        local count = w[kind] or 0
        list[#list + 1] = { key = d.key, short = d.short, colour = d.colour, count = count, activeOfficers = active,
            rate = active > 0 and count / active or 0, completed = w.completed, unit = w.unit }
    end
    table.sort(list, function(a, b)
        if a.rate ~= b.rate then return a.rate > b.rate end
        if a.completed ~= b.completed then return a.completed > b.completed end
        if a.unit ~= b.unit then return a.unit > b.unit end
        return a.key < b.key
    end)
    return list
end

local function pickWinner(rates)
    local top, second = rates[1], rates[2]
    if not top or top.rate <= 0 then return '' end
    if second and second.rate == top.rate and second.completed == top.completed and second.unit == top.unit then return '' end
    return top.key
end

local function publicRates(rates)
    local out = {}
    for i, r in ipairs(rates) do
        out[i] = { key = r.key, short = r.short, colour = r.colour, count = r.count, activeOfficers = r.activeOfficers,
            rate = math.floor(r.rate * 100 + 0.5) / 100 }
    end
    return out
end

-- Close week n (store its winner) once. Returns true when this call closed it.
local function closeWeek(season, n, data)
    local b = ensureBounty(season, n)
    if not b or b.winner ~= nil then return false end
    local winner = pickWinner(bountyRates(data, n, b.objective))
    local changed = MySQL.update.await('UPDATE cp_dept_bounties SET winner = ? WHERE season_id = ? AND week = ? AND winner IS NULL',
        { winner, season.id, n })
    if num(changed) <= 0 then return false end
    CP.log(TAG, 'season %d week %d bounty %s closed: %s', season.id, n, b.objective, winner ~= '' and winner or 'no winner')
    return true
end

local function closeDueWeeks(season, nowTs, includeCurrent)
    if not bountiesOn() then return 0 end
    local cur = weekIndex(season, nowTs)
    local last = includeCurrent and cur or cur - 1
    if last < 1 then return 0 end
    local data = collect(season.id, true)
    if not data then return 0 end
    local closed = 0
    for n = 1, math.min(last, MAX_WEEK) do
        if closeWeek(season, n, data) then closed = closed + 1 end
    end
    if closed > 0 then collectCache[season.id] = nil end
    return closed
end
C._closeDueWeeks = closeDueWeeks

local function bountyView(season, data, nowTs)
    local n = weekIndex(season, nowTs)
    local b = ensureBounty(season, n)
    if not b then return nil end
    local rates = bountyRates(data, n, b.objective)
    local leaderKey = pickWinner(rates)
    if leaderKey == '' then leaderKey = nil end
    local _, to = weekWindow(season, n)
    return {
        id = b.objective, label = bountyLabel(b.objective),
        leader = leaderKey and deptShort(leaderKey) or nil, leaderKey = leaderKey,
        week = n, endsIn = math.max(0, to - nowTs), closed = b.winner ~= nil,
        overridden = b.objective ~= pickBounty(season.id, n),
        rates = publicRates(rates),
    }
end

function C.bounty(weekKey)
    local season = C.currentSeason()
    if not season then return nil end
    local ts = os.time()
    if weekKey ~= nil then
        local y, m, d = tostring(weekKey):match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
        if not y then return nil end
        ts = os.time({ year = int(y), month = int(m), day = int(d), hour = resetHour(), min = 30, sec = 0 })
    end
    local n = weekIndex(season, ts)
    local b = ensureBounty(season, n)
    if not b then return nil end
    local from, to = weekWindow(season, n)
    return { seasonId = season.id, week = n, id = b.objective, label = bountyLabel(b.objective),
        winner = (b.winner ~= nil and b.winner ~= '') and b.winner or nil, closed = b.winner ~= nil,
        startsAt = from, endsAt = to, overridden = b.objective ~= pickBounty(season.id, n) }
end

-- ── caches and banner ───────────────────────────────────────────────────────
function C.invalidate()
    collectGen = collectGen + 1
    collectCache = {}
    bannerCache = nil
end

local function invalidateAll()
    C.invalidate()
    if has('Leaderboard', 'invalidate') then
        -- CP.Leaderboard.invalidate calls C.invalidate as well; both are cheap.
        call('Leaderboard', 'invalidate')
    end
end

local function latestChampion()
    if bannerCache and os.time() - bannerCache.at < SEASON_RELOAD_S then return bannerCache.row end
    db()
    local row = MySQL.single.await(
        [[SELECT s.id, s.name, b.winner FROM cp_seasons s
          LEFT JOIN cp_dept_bounties b ON b.season_id = s.id AND b.week = ?
          WHERE s.active = 0 AND s.ends_at IS NOT NULL
          ORDER BY s.id DESC LIMIT 1]], { CHAMPION_WEEK })
    bannerCache = { at = os.time(), row = row }
    return row
end

function C.championBanner(dept)
    local row = latestChampion()
    if not row then return nil end
    local winner = nonEmpty(row.winner)
    if not winner then return nil end
    if dept ~= nil and dept ~= winner then return nil end
    local d = deptInfo(winner)
    return { season = tostring(row.name), seasonId = int(row.id), department = d and d.label or winner, departmentKey = winner,
        short = d and d.short or winner:upper() }
end

-- ── permissions, audit, webhook ─────────────────────────────────────────────
local function allowed(src, action)
    local n = tonumber(src)
    if n == 0 then return true end
    if not n or not has('Permissions', 'can') then return false, 'err.no_permission' end
    return CP.Permissions.can(n, action)
end

local function audit(src, action, target, old, new, reason)
    local n = tonumber(src) or 0
    local actor = n == 0 and 'console' or n
    local role = n == 0 and 'console' or 'admin'
    if not has('Admin', 'audit') then
        CP.warn(TAG, 'CP.Admin.audit is not available: %s %s by %s not written to the audit log', action, tostring(target), tostring(actor))
        return
    end
    call('Admin', 'audit', actor, role, 'audit', action, target,
        old ~= nil and U.clip(tostring(old), 64) or nil, new ~= nil and U.clip(tostring(new), 64) or nil,
        reason ~= nil and U.clip(tostring(reason), 255) or nil)
end

local function webhook(title, description, fields)
    if not has('Admin', 'webhook') then
        CP.log(TAG, 'no CP.Admin.webhook: %s', title)
        return false
    end
    return call('Admin', 'webhook', 'board', title, description, fields)
end

-- ── views ───────────────────────────────────────────────────────────────────
local function seasonView(season, nowTs)
    if not season then return nil end
    nowTs = nowTs or os.time()
    local at = season.active and nowTs or (season.endsAt or nowTs)
    return { id = season.id, name = season.name, startsAt = season.startsAt, endsAt = season.endsAt, active = season.active,
        week = weekIndex(season, at), weeksLeft = weeksLeft(season, nowTs) }
end

-- Names for a list of citizenids: { [cid] = { name, callsign, hideName, rank } }.
local function officerNames(cids)
    local out = {}
    if #cids == 0 then return out end
    db()
    for i = 1, #cids, 100 do
        local chunk = {}
        for j = i, math.min(#cids, i + 99) do chunk[#chunk + 1] = cids[j] end
        local rows = MySQL.query.await(
            ('SELECT citizenid, display_name, callsign, rank_label, hide_name FROM cp_officers WHERE citizenid IN (%s)'):format(placeholders(#chunk)),
            chunk) or {}
        for _, r in ipairs(rows) do
            out[tostring(r.citizenid)] = { name = nonEmpty(r.display_name), callsign = nonEmpty(r.callsign),
                rank = nonEmpty(r.rank_label), hideName = U.truthy(r.hide_name) }
        end
    end
    return out
end

local function publicName(e)
    if has('Leaderboard', 'publicName') then return CP.Leaderboard.publicName(e) end
    if e.hideName then return e.callsign or CP.L('leaderboard.hidden_name') end
    return e.name or e.callsign or CP.L('common.unknown')
end

-- The department's officers this season, best first.
local function contributors(data, dept, limit)
    local list = {}
    for cid, o in pairs((data and data.officers[dept]) or {}) do
        list[#list + 1] = { citizenid = cid, points = o.points, runs = o.completed }
    end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points > b.points end
        if a.runs ~= b.runs then return a.runs > b.runs end
        return a.citizenid < b.citizenid
    end)
    local out, cids = {}, {}
    for i = 1, math.min(limit, #list) do
        out[i] = list[i]
        cids[i] = list[i].citizenid
    end
    local names = officerNames(cids)
    for i, e in ipairs(out) do
        local n = names[e.citizenid] or {}
        out[i] = { rank = i, citizenid = e.citizenid, name = publicName({ name = n.name, callsign = n.callsign, hideName = n.hideName }),
            callsign = n.callsign, points = e.points, runs = e.runs, active = e.runs >= minActive() }
    end
    return out
end

function C.view(officer)
    local nowTs = os.time()
    local season = C.currentSeason()
    local out = {
        enabled = challengeOn(), mode = scoringMode(), minRunsActive = minActive(), myDepartment = officer.department,
        season = nil, departments = {}, bounty = nil, topContributors = {},
    }
    if season then
        out.season = { id = season.id, name = season.name, weeksLeft = weeksLeft(season, nowTs), week = weekIndex(season, nowTs), startsAt = season.startsAt }
    end
    if not out.enabled then return out end
    local data = season and collect(season.id) or nil
    out.departments = publicStandings(standingsFrom(data))
    if season and data then
        out.bounty = bountyView(season, data, nowTs)
        local top = contributors(data, officer.department, 5)
        for i, c in ipairs(top) do
            out.topContributors[i] = { name = c.name, callsign = c.callsign, points = c.points, citizenid = c.citizenid, runs = c.runs }
        end
    end
    return out
end

-- ── season start / end ──────────────────────────────────────────────────────
local function validName(name)
    if type(name) ~= 'string' then return nil end
    name = U.trim(name)
    if name == '' or #name > 64 or name:find('%c') then return nil end
    return name
end

local function awardBadge(citizenid, badgeId, ts)
    return num(MySQL.update.await('INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { citizenid, U.clip(badgeId, 40), ts }))
end

local function decideChampion(list)
    if not challengeOn() then return '' end
    local top, second = list[1], list[2]
    if not top or (top.scoreRaw <= 0 and top.completed <= 0) then return '' end
    if second and second.scoreRaw == top.scoreRaw and second.completed == top.completed and second.unitRuns == top.unitRuns then return '' end
    return top.key
end

local function seasonResultsWebhook(season, list, champion, top10)
    local lines = {}
    for i, e in ipairs(list) do
        lines[i] = CP.L('challenge.webhook_standing_line', { rank = i, department = e.short, score = fmtInt(e.score), active = e.activeOfficers })
    end
    local topLines = {}
    for i, e in ipairs(top10) do
        topLines[i] = CP.L('challenge.webhook_top_line', { rank = i, name = e.name, department = e.departmentShort, points = fmtInt(e.points) })
    end
    local fields = {
        { name = CP.L('challenge.webhook_standings'), value = #lines > 0 and table.concat(lines, '\n') or CP.L('common.none'), inline = false },
        { name = CP.L('challenge.webhook_top10'), value = #topLines > 0 and table.concat(topLines, '\n') or CP.L('common.none'), inline = false },
    }
    local d = champion ~= '' and deptInfo(champion) or nil
    local desc = d and CP.L('challenge.webhook_champion', { department = d.label, season = season.name })
        or CP.L('challenge.webhook_no_champion', { season = season.name })
    webhook(CP.L('challenge.webhook_season_title', { season = season.name }), desc, fields)
end

local function endSeasonInternal(src, season, reason)
    db()
    local endTs = os.time()
    local changed = MySQL.update.await('UPDATE cp_seasons SET active = 0, ends_at = FROM_UNIXTIME(?) WHERE id = ? AND active = 1',
        { endTs, season.id })
    loadSeasons()
    if num(changed) <= 0 then return false, 'err.no_season' end
    season = C.seasonById(season.id) or season
    season.endsAt = season.endsAt or endTs
    season.active = false
    invalidateAll()

    closeDueWeeks(season, endTs, true)
    local data = collect(season.id, true) or { officers = {}, weeks = {}, bounties = {} }
    local list = standingsFrom(data)
    local champion = decideChampion(list)
    MySQL.update.await(
        'INSERT INTO cp_dept_bounties (season_id, week, objective, winner) VALUES (?, ?, ?, ?) ON DUPLICATE KEY UPDATE winner = VALUES(winner)',
        { season.id, CHAMPION_WEEK, CHAMPION_OBJECTIVE, champion })

    local trophies = 0
    if champion ~= '' then
        for cid, o in pairs(data.officers[champion] or {}) do
            if o.completed >= minActive() then trophies = trophies + awardBadge(cid, ('season_%d_champion'):format(season.id), endTs) end
        end
    end
    local top10 = {}
    if has('Leaderboard', 'ranking') then
        local ok, ranked = call('Leaderboard', 'ranking', { period = 'season', seasonId = season.id, filter = 'overall', fresh = true })
        if ok and type(ranked) == 'table' then
            for i = 1, math.min(10, #ranked) do
                local e = ranked[i]
                awardBadge(e.citizenid, ('season_%d_top10'):format(season.id), endTs)
                top10[i] = { rank = i, citizenid = e.citizenid, name = publicName(e), departmentShort = deptShort(e.department), points = e.points }
            end
        end
    end
    seasonResultsWebhook(season, list, champion, top10)
    audit(src, 'season_end', ('season:%d'):format(season.id), season.name, champion ~= '' and champion or '-', reason)
    invalidateAll()
    CP.log(TAG, 'season %d (%s) ended: champion %s, %d trophies, %d top 10 badges', season.id, season.name,
        champion ~= '' and champion or 'none', trophies, #top10)
    return true, { season = seasonView(season, endTs), standings = publicStandings(list),
        champion = champion ~= '' and champion or nil, top10 = top10 }
end

local function guarded(fn)
    if busy then return false, 'err.busy' end
    busy = true
    local res = table.pack(pcall(fn))
    busy = false
    if not res[1] then
        CP.err(TAG, 'season change failed: %s', tostring(res[2]))
        return false, 'err.internal'
    end
    return table.unpack(res, 2, res.n)
end

function C.endSeason(src, reason)
    local ok, errKey = allowed(src, 'seasons')
    if not ok then return false, errKey or 'err.no_permission' end
    if reason ~= nil and type(reason) ~= 'string' then return false, 'err.invalid_payload' end
    return guarded(function()
        local season = C.currentSeason(true)
        if not season then return false, 'err.no_season' end
        return endSeasonInternal(src, season, reason and U.trim(reason) or nil)
    end)
end

function C.startSeason(src, name)
    local ok, errKey = allowed(src, 'seasons')
    if not ok then return false, errKey or 'err.no_permission' end
    name = validName(name)
    if not name then return false, 'err.invalid_season_name' end
    return guarded(function()
        db()
        local prev = C.currentSeason(true)
        if prev then
            local okEnd, err = endSeasonInternal(src, prev, CP.L('challenge.audit_replaced', { name = name }))
            if not okEnd then return false, err end
        end
        local now = os.time()
        local id = MySQL.insert.await('INSERT INTO cp_seasons (name, starts_at, active) VALUES (?, FROM_UNIXTIME(?), 1)', { name, now })
        loadSeasons()
        local season = id and C.seasonById(id)
        if not season then return false, 'err.internal' end
        ensureBounty(season, 1)
        audit(src, 'season_start', ('season:%d'):format(season.id), prev and prev.name or nil, name, nil)
        invalidateAll()
        CP.log(TAG, 'season %d (%s) started', season.id, name)
        return true, seasonView(season, now)
    end)
end

function C.overrideBounty(src, objective)
    local ok, errKey = allowed(src, 'bountyOverride')
    if not ok then return false, errKey or 'err.no_permission' end
    if not bountiesOn() then return false, 'err.bounty_disabled' end
    if type(objective) ~= 'string' or not isBounty(objective) then return false, 'err.invalid_bounty' end
    return guarded(function()
        local season = C.currentSeason(true)
        if not season then return false, 'err.no_season' end
        local nowTs = os.time()
        local n = weekIndex(season, nowTs)
        local b = ensureBounty(season, n)
        if not b then return false, 'err.bounty_disabled' end
        if b.winner ~= nil then return false, 'err.bounty_closed' end
        if b.objective ~= objective then
            local changed = MySQL.update.await('UPDATE cp_dept_bounties SET objective = ? WHERE season_id = ? AND week = ? AND winner IS NULL',
                { objective, season.id, n })
            if num(changed) <= 0 then return false, 'err.bounty_closed' end
            audit(src, 'bounty_override', ('season:%d:week:%d'):format(season.id, n), b.objective, objective, nil)
            invalidateAll()
        end
        local data = collect(season.id, true)
        return true, bountyView(season, data, nowTs)
    end)
end

-- ── admin: seasons screen ───────────────────────────────────────────────────
local function bountyHistory()
    db()
    local rows = MySQL.query.await(
        [[SELECT b.season_id, b.week, b.objective, b.winner, s.name
          FROM cp_dept_bounties b JOIN cp_seasons s ON s.id = b.season_id
          WHERE b.week >= 1
          ORDER BY b.season_id DESC, b.week DESC
          LIMIT ?]], { HISTORY_LIMIT }) or {}
    local out = {}
    local nowTs = os.time()
    for _, r in ipairs(rows) do
        local sid, n = int(r.season_id), int(r.week)
        local season = C.seasonById(sid)
        local winner = r.winner ~= nil and tostring(r.winner) or nil
        local bonus = 0
        if season and winner and winner ~= '' then
            local data = collect(sid)
            bonus = math.floor(bonusShare() * weekStats(data, n, winner).points)
        end
        local from, to = 0, 0
        if season then from, to = weekWindow(season, n) end
        out[#out + 1] = {
            seasonId = sid, seasonName = tostring(r.name), week = n, objective = tostring(r.objective),
            label = bountyLabel(tostring(r.objective)), winner = winner ~= '' and winner or nil,
            winnerShort = (winner and winner ~= '') and deptShort(winner) or nil, bonus = bonus,
            closed = winner ~= nil, current = season ~= nil and season.active and weekIndex(season, nowTs) == n or false,
            startsAt = from, endsAt = to,
        }
    end
    return out
end

local function seasonsList()
    db()
    local champs = {}
    for _, r in ipairs(MySQL.query.await('SELECT season_id, winner FROM cp_dept_bounties WHERE week = ?', { CHAMPION_WEEK }) or {}) do
        champs[int(r.season_id)] = r.winner ~= nil and tostring(r.winner) or ''
    end
    local out = {}
    for _, s in ipairs(ensureSeasons(true).list) do
        local champ = nonEmpty(champs[s.id])
        out[#out + 1] = { id = s.id, name = s.name, startsAt = s.startsAt, endsAt = s.endsAt, active = s.active,
            champion = champ, championShort = champ and deptShort(champ) or nil }
    end
    return out
end

function C.adminView()
    local nowTs = os.time()
    local current = C.currentSeason(true)
    local latest = C.latestSeason()
    local focus = current or latest
    local data = focus and collect(focus.id) or nil
    return {
        current = current and seasonView(current, nowTs) or nil,
        latest = (not current and latest) and seasonView(latest, nowTs) or nil,
        standings = publicStandings(standingsFrom(data)),
        bounty = (current and data) and bountyView(current, data, nowTs) or nil,
        bountyHistory = bountyHistory(),
        seasons = seasonsList(),
        bounties = bountyList(),
        enabled = challengeOn(), weeklyBounty = bountiesOn(), mode = scoringMode(),
        seasonWeeks = seasonWeeks(), minRunsActive = minActive(),
    }
end

-- ── supervisor: department report ───────────────────────────────────────────
-- The department a supervisor/admin looks at: their own; admins may pass args.department.
local function reportDepartment(src, args)
    local ok, errKey = CP.Permissions.can(src, 'viewMissionList')
    if not ok then return nil, errKey or 'err.no_permission' end
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local officer = CP.Access.getOfficer(src)
    local dept = officer and officer.department or nil
    local wanted = args and args.department
    if wanted ~= nil and wanted ~= '' then
        if not isDepartment(wanted) then return nil, 'err.unknown_department' end
        if wanted ~= dept then
            if not CP.Access.isAdmin(src) then return nil, 'err.other_department' end
            dept = wanted
        end
    end
    if not dept then
        if not CP.Access.isAdmin(src) then return nil, 'err.not_police' end
        local list = departmentList()
        dept = list[1] and list[1].key or nil
    end
    if not dept then return nil, 'err.unknown_department' end
    return dept
end

local ACTIVITY_SQL = [[
SELECT s.citizenid, s.runs, s.completed, s.failed, s.abandoned, s.flagged, s.points, s.cash, s.last_ts,
  o.display_name, o.callsign, o.rank_label
FROM (
  SELECT r.citizenid,
    SUM(CASE WHEN r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS runs,
    SUM(CASE WHEN r.state = 'completed' AND r.mission_type NOT IN ('manual_award', 'goal') THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN r.state = 'failed' THEN 1 ELSE 0 END) AS failed,
    SUM(CASE WHEN r.state = 'abandoned' THEN 1 ELSE 0 END) AS abandoned,
    SUM(CASE WHEN r.flagged = 1 THEN 1 ELSE 0 END) AS flagged,
    SUM(CASE WHEN r.voided = 0 AND r.flagged = 0 THEN r.final_points ELSE 0 END) AS points,
    SUM(r.cash_paid) AS cash,
    UNIX_TIMESTAMP(MAX(r.created_at)) AS last_ts
  FROM cp_mission_runs r
  WHERE r.department = ? AND r.created_at >= FROM_UNIXTIME(?)
  GROUP BY r.citizenid
) s
LEFT JOIN cp_officers o ON o.citizenid = s.citizenid
ORDER BY s.points DESC, s.runs DESC, s.citizenid ASC]]

function C.deptReport(dept)
    db()
    local nowTs = os.time()
    local ws = weekStart(nowTs)
    local season = C.currentSeason()
    local data = season and collect(season.id) or nil
    local list = standingsFrom(data)
    local standing = nil
    for _, e in ipairs(list) do
        if e.key == dept then standing = publicStanding(e); standing.of = #list end
    end
    local officers = {}
    for _, r in ipairs(MySQL.query.await(ACTIVITY_SQL, { dept, ws }) or {}) do
        officers[#officers + 1] = {
            citizenid = tostring(r.citizenid), name = nonEmpty(r.display_name) or CP.L('common.unknown'),
            callsign = nonEmpty(r.callsign), rank = nonEmpty(r.rank_label) or '',
            runs = int(r.runs), completed = int(r.completed), failed = int(r.failed), abandoned = int(r.abandoned),
            flagged = int(r.flagged), points = int(r.points), cash = int(r.cash),
            lastRunAt = r.last_ts and sqlTs(r.last_ts) or '', lastRunTs = int(r.last_ts),
        }
    end
    return {
        department = deptInfo(dept),
        season = season and { id = season.id, name = season.name, weeksLeft = weeksLeft(season, nowTs), week = weekIndex(season, nowTs) } or nil,
        enabled = challengeOn(),
        standing = (season and challengeOn()) and standing or nil,
        standings = challengeOn() and publicStandings(list) or {},
        bounty = (season and data) and bountyView(season, data, nowTs) or nil,
        week = { key = os.date('%Y-%m-%d', ws), startsAt = ws },
        officers = officers,
    }
end

local OFFICER_RUNS_SQL = [[
SELECT r.id, r.mission_type, r.mission_id, r.state, r.end_reason, r.final_points, r.cash_paid, r.cash_status,
  r.flagged, r.flag_reason, r.voided, r.participants, r.departments_n, r.tier, r.duration_s, r.breakdown,
  UNIX_TIMESTAMP(r.created_at) AS created_ts
FROM cp_mission_runs r
WHERE r.citizenid = ? AND r.department = ? AND r.created_at >= FROM_UNIXTIME(?)
ORDER BY r.created_at DESC, r.id DESC
LIMIT ?]]

local function missionLabel(missionType, missionId, bd)
    if has('Leaderboard', 'missionLabel') then return CP.Leaderboard.missionLabel(missionType, missionId, bd) end
    return tostring(missionId)
end

function C.officerActivity(dept, citizenid)
    db()
    local ws = weekStart(os.time())
    local orow = MySQL.single.await('SELECT citizenid, display_name, callsign, rank_label, department FROM cp_officers WHERE citizenid = ?', { citizenid })
    local inDept = orow ~= nil and orow.department == dept
    if not inDept then
        inDept = MySQL.scalar.await(
            'SELECT 1 AS in_dept FROM cp_mission_runs WHERE citizenid = ? AND department = ? AND created_at >= FROM_UNIXTIME(?) LIMIT 1',
            { citizenid, dept, ws }) ~= nil
    end
    if not inDept then return nil, orow and 'err.other_department' or 'err.unknown_officer' end
    orow = orow or {}
    local runs = {}
    for _, r in ipairs(MySQL.query.await(OFFICER_RUNS_SQL, { citizenid, dept, ws, ACTIVITY_LIMIT }) or {}) do
        local bd = U.jsonField(r.breakdown)
        runs[#runs + 1] = {
            id = int(r.id), missionLabel = missionLabel(r.mission_type, r.mission_id, type(bd) == 'table' and bd or nil),
            missionType = tostring(r.mission_type), state = tostring(r.state), endReason = tostring(r.end_reason),
            points = int(r.final_points), cash = int(r.cash_paid), cashStatus = tostring(r.cash_status),
            flagged = U.truthy(r.flagged), flagReason = r.flag_reason, voided = U.truthy(r.voided),
            participants = int(r.participants), departments = int(r.departments_n), tier = tostring(r.tier),
            durationS = int(r.duration_s), createdAt = sqlTs(r.created_ts), createdTs = int(r.created_ts),
        }
    end
    local d = deptInfo(nonEmpty(orow.department) or dept)
    return {
        officer = { citizenid = citizenid, name = nonEmpty(orow.display_name) or CP.L('common.unknown'), callsign = nonEmpty(orow.callsign),
            rank = nonEmpty(orow.rank_label) or '', departmentShort = d and d.short or '' },
        week = { key = os.date('%Y-%m-%d', ws), startsAt = ws },
        runs = runs,
    }
end

-- ── net handlers ────────────────────────────────────────────────────────────
CP.Net.callback('getChallenge', function(src)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    return C.view(officer)
end)

CP.Net.callback('getDeptContributors', function(src, args)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey end
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local dept = args and args.department
    if dept == nil or dept == '' then dept = officer.department end
    if not isDepartment(dept) then return nil, 'err.unknown_department' end
    local season = C.currentSeason()
    local data = season and collect(season.id) or nil
    return {
        department = deptInfo(dept),
        season = season and { id = season.id, name = season.name } or nil,
        minRunsActive = minActive(),
        contributors = data and contributors(data, dept, CONTRIBUTORS_LIMIT) or {},
    }
end)

CP.Net.callback('admin:getSeasons', function(src)
    local ok, errKey = CP.Permissions.can(src, 'seasons')
    if not ok then return nil, errKey end
    return C.adminView()
end)

CP.Net.action('server:admin:startSeason', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return C.startSeason(src, payload.name)
end, { rate = 2 })

CP.Net.action('server:admin:endSeason', function(src, payload)
    if payload ~= nil and type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    local reason = payload and payload.reason or nil
    if reason ~= nil and (type(reason) ~= 'string' or #reason > 255) then return false, 'err.invalid_payload' end
    return C.endSeason(src, reason)
end, { rate = 2 })

CP.Net.action('server:admin:overrideBounty', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return C.overrideBounty(src, payload.objective)
end, { rate = 2 })

CP.Net.callback('sup:getDeptReport', function(src, args)
    local dept, errKey = reportDepartment(src, args)
    if not dept then return nil, errKey end
    return C.deptReport(dept)
end)

CP.Net.callback('sup:getOfficerActivity', function(src, args)
    if type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    if not validCitizenId(args.citizenid) then return nil, 'err.invalid_citizenid' end
    local dept, errKey = reportDepartment(src, { department = args.department })
    if not dept then return nil, errKey end
    return C.officerActivity(dept, args.citizenid)
end)

-- ── start and the weekly reset ──────────────────────────────────────────────
local function weeklyReset()
    local season = C.currentSeason(true)
    if season then
        local nowTs = os.time()
        closeDueWeeks(season, nowTs, false)
        ensureBounty(season, weekIndex(season, nowTs))
    end
    invalidateAll()
end

function C._boot()
    if booted then return end
    booted = true
    if has('Schedule', 'onWeekly') then
        CP.Schedule.onWeekly(function() weeklyReset() end)
    else
        CP.warn(TAG, 'CP.Schedule is missing: weekly bounties only close at season end')
    end
    local ok, err = pcall(function()
        loadSeasons()
        local season = seasons.current
        if season then
            -- Catch-up for weeks that ended while the server was down, then this week's bounty.
            closeDueWeeks(season, os.time(), false)
            ensureBounty(season, weekIndex(season, os.time()))
            CP.log(TAG, 'season %d (%s), week %d', season.id, season.name, weekIndex(season, os.time()))
        end
    end)
    if not ok then CP.err(TAG, 'start failed: %s', tostring(err)) end
end

CreateThread(function()
    Wait(BOOT_DELAY_MS)
    C._boot()
end)
