-- CP.Goals (server): personal daily and weekly goals.

-- Owns
--   * picking each officer's goals: one of Config.Objectives.dailyGoal.goals per reset-adjusted day and one of
--     Config.Objectives.weeklyGoal.goals per week (from the weekly reset on Config.Leaderboard.weekStartsOn), with a
--     seed
--     made from the date (or the week's start) and the citizenid, so a restart keeps the same goals and
--     nothing is stored
--   * progress: the officer's counted runs since the period started (completed, not flagged, not voided,
--     never manual_award or goal rows) that match the goal (type = a mission type key, unit = 2+
--     participants, crossDepartment = 2+ departments, mission = one mission id; count = how many)
--   * the reward: once per period a 'goal' row (mission_type 'goal', mission_id = the goal id, state and
--     end_reason 'completed', final_points = Config.Objectives.dailyGoal.points / weeklyGoal.points) counted through
--     CP.Scoring (XP; Overall and Department boards only)
--
-- Public API (docs/dev/ARCHITECTURE.md §5.19)
--   CP.Goals.forOfficer(citizenid) -> { daily = Goal|nil, weekly = Goal|nil }
--       Goal = { id, label, count, progress, done, points }   (progress is capped at count)
--   CP.Goals.onRunCompleted(citizenid)   (hook: a completed row was counted) -> inserts the goal rows earned
-- Both query the database: call them from a thread.
--
-- the goals Mission control (Goals.registerControl). A supervisor picks which of the admin's daily and
-- weekly goals his department's officers draw from, counting from the next weekly reset (the saved value carries
-- from and prev); forOfficer(citizenid, department) and Pick take the department; the setter keeps the whole lists.

CP.Goals = CP.Goals or {}
local Goals = CP.Goals
local TAG = 'goals'

local busy = CP.Lock.new() -- an officer's citizenid while his goals are checked or completed

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local Num = CP.Num

local Now = CP.now

-- The key and start of the period of 'kind' that contains ts. Each kind starts at its own hour
-- (Config.Objectives.dailyGoal / weeklyGoal .resetHour; -1 = Config.Time.resetHour), the weekly goal on
-- Config.Leaderboard.weekStartsOn.
local function Period(kind, ts)
    ts = ts or Now()
    local S = CP.Schedule or {}
    local hour = CP.ObjectiveResetHour(kind == 'daily' and 'dailyGoal' or 'weeklyGoal')
    if kind == 'daily' then
        local key = S.dayKey and S.dayKey(ts, hour) or os.date('%Y-%m-%d', ts)
        local start = S.dayStart and S.dayStart(ts, hour) or (ts - ts % 86400)
        return key, start
    end
    local start = S.weekStart and S.weekStart(ts, hour) or (ts - 7 * 86400)
    local key = S.weekKey and S.weekKey(ts, hour) or os.date('%Y-%m-%d', start)
    return key, start
end

-- The daily and weekly goal are two kinds of Config.Objectives (dailyGoal, weeklyGoal): cfg, on.
local function GoalKind(kind)
    return CP.Objective(kind == 'daily' and 'dailyGoal' or 'weeklyGoal')
end

-- The goals of one kind (the list a supervisor narrows, kept while the kind is switched off).
local function GoalList(kind) return (GoalKind(kind)).goals end

-- A goal switched off (enabled = false) is never picked.
local function ValidGoals(list)
    local out = {}
    for _, g in ipairs(type(list) == 'table' and list or {}) do
        if type(g) == 'table' and type(g.id) == 'string' and g.id ~= '' and #g.id <= 40 and Num(g.count, 0) >= 1
            and g.enabled ~= false then
            out[#out + 1] = g
        end
    end
    return out
end

-- ============================================================================
--                      DEPARTMENT GOALS (MISSION CONTROL)
-- ============================================================================
-- goals (Config.MissionControls.controls): per department, under the master switch, shipped off. A supervisor picks
-- min to max of the admin's daily goals and of the admin's weekly goals (Config.Objectives); his department's officers
-- draw
-- their goals from those FROM THE NEXT WEEKLY RESET, so no goal an officer is working on changes under him. An empty
-- list = every goal of that kind. The points stay the kind's points (Config.Objectives). The setter (and any
-- character of his) keeps the admin's whole list (Config.MissionControls.selfExempt).
-- Saved value: { daily = { id, ... }, weekly = { id, ... }, from = '<week key>', prev = { daily, weekly } | nil }: the
-- lists count from the week that starts on 'from'; before it, prev (what counted when the change was made).

local CONTROL_KEY = 'goals'
local KINDS = { 'daily', 'weekly' }
local LIST_MAX = 20           -- goal ids one list may hold
local WEEK_KEY = '^%d%d%d%d%-%d%d%-%d%d$'

local function WeekKeyOf(ts)
    local key = Period('weekly', ts)
    return key
end

-- The key of the week after the one that contains ts (the week a change made now counts from).
local function NextWeekKey(ts)
    local _, start = Period('weekly', ts or Now())
    return WeekKeyOf(start + 7 * 86400 + 12 * 3600)
end

-- A list of goal ids of one kind: the admin's goals (switched-off ones left out), each once, in the admin's order.
-- strict (a supervisor's or admin's change): an unknown id, a repeat or a count outside min to max is refused (nil);
-- otherwise (a saved value read today) what no longer exists is left out and a list longer than max is cut.
local function CleanIds(kind, raw, bounds, strict)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil end
    local goals = ValidGoals(GoalList(kind))
    local known = {}
    for _, g in ipairs(goals) do known[g.id] = true end
    local keep, n = {}, 0
    for k, id in pairs(raw) do
        n = n + 1
        local good = n <= LIST_MAX and math.type(k) == 'integer' and type(id) == 'string' and known[id] == true
        if good and not keep[id] then
            keep[id] = true
        elseif strict then
            return nil
        end
    end
    local out = {}
    for _, g in ipairs(goals) do
        if keep[g.id] then
            out[#out + 1] = g.id
            keep[g.id] = nil
        end
    end
    if #out == 0 then return out end
    local lo = math.max(1, math.floor(Num(bounds and bounds.min, 1)))
    local hi = math.max(1, math.floor(Num(bounds and bounds.max, LIST_MAX)))
    if strict and (#out < lo or #out > hi) then return nil end
    while #out > hi do out[#out] = nil end
    return out
end

-- The control's value cleaned. strict: only { daily, weekly } (the server adds from and prev when it saves).
local function CleanPick(v, bounds, strict)
    if type(v) ~= 'table' then return nil end
    if strict then
        for k in pairs(v) do
            if k ~= 'daily' and k ~= 'weekly' then return nil end
        end
    end
    local out = {}
    for _, kind in ipairs(KINDS) do
        out[kind] = CleanIds(kind, v[kind], bounds, strict)
        if not out[kind] then return nil end
    end
    if strict then return out end
    if type(v.from) == 'string' and v.from:match(WEEK_KEY) then out.from = v.from end
    if type(v.prev) == 'table' then
        out.prev = {
            daily = CleanIds('daily', v.prev.daily, bounds, false) or {},
            weekly = CleanIds('weekly', v.prev.weekly, bounds, false) or {},
        }
    end
    return out
end
Goals._cleanPick = CleanPick

-- The lists that count in the week weekKey: the newest pick from its week on, before it the one it replaced.
local function ListsAt(v, weekKey)
    if type(v) ~= 'table' then return nil end
    if type(v.from) == 'string' and weekKey < v.from then return v.prev end
    return v
end

-- True while some department has the control on (the master switch too): only then is an officer's department read.
local function AnyOn()
    local dc = CP.DeptControls
    if not (dc and dc.active and dc.def and dc.def(CONTROL_KEY)) then return false end
    for key in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do
        local ok, on = pcall(dc.active, key, CONTROL_KEY)
        if ok and on == true then return true end
    end
    return false
end

local DeptOf = CP.deptOfCitizen

-- The officer's department once for several reads: false while no department has the control on.
local function ResolveDept(citizenid)
    if not AnyOn() then return false end
    return DeptOf(citizenid) or false
end

-- The department's lists for citizenid in the week that contains ts ({ daily, weekly }), or nil (the whole lists).
-- dept: the officer's department when the caller knows it.
local function DeptLists(citizenid, ts, dept)
    local dc = CP.DeptControls
    if not (dc and dc.get and dc.def and dc.def(CONTROL_KEY)) then return nil end
    if dept == nil then
        if not AnyOn() then return nil end
        dept = DeptOf(citizenid)
    end
    if type(dept) ~= 'string' then
        return nil
    end -- false: ResolveDept found no department control on
    local ok, v = pcall(dc.get, dept, CONTROL_KEY, { citizenid = citizenid })
    if not ok then
        CP.err(TAG, 'reading the goals control of %s failed: %s', dept, tostring(v))
        return nil
    end
    return ListsAt(v, WeekKeyOf(ts))
end

-- The goal of 'kind' for citizenid in the period that contains ts: from his department's pick when it
-- names goals that still exist, else from the admin's whole list. dept (optional): the officer's department.
-- None while the kind is switched off (Config.Objectives.dailyGoal / weeklyGoal .enabled = false).
local function Pick(kind, citizenid, ts, dept)
    if not select(2, GoalKind(kind)) then return nil end
    local list = ValidGoals(GoalList(kind))
    if #list == 0 then return nil end
    local lists = DeptLists(citizenid, ts, dept)
    local ids = type(lists) == 'table' and lists[kind] or nil
    if type(ids) == 'table' and #ids > 0 then
        local want, narrowed = {}, {}
        for _, id in ipairs(ids) do want[id] = true end
        for _, g in ipairs(list) do
            if want[g.id] then narrowed[#narrowed + 1] = g end
        end
        if #narrowed > 0 then list = narrowed end
    end
    local key, start = Period(kind, ts)
    local rng = CP.U.rng(CP.U.hash(('%s:%s:%s'):format(kind, key, citizenid)))
    local goal = rng:pick(list)
    return goal, key, start
end

local function PointsFor(kind)
    return math.max(0, math.floor(Num(GoalKind(kind).points, 0)))
end

local function LabelOf(goal)
    if type(goal.label) == 'string' and goal.label ~= '' then return goal.label end
    return CP.L('goals.unnamed', { count = math.floor(Num(goal.count, 1)) })
end

-- Counted runs since 'start' that match the goal (a stat goal: the sum of that column over them), counted by the one
-- progress engine (CP.Progress) the weekly bounty counts by too.
local function ProgressOf(goal, citizenid, start)
    local value = CP.Progress.value(goal)
    if not value then return 0 end
    local what = value == '1' and 'COUNT(*)' or ('COALESCE(SUM(%s), 0)'):format(value)
    local where, params = CP.Progress.where(goal)
    local sql = (
        'SELECT %s AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 0'
        .. ' AND flagged = 0 AND created_at >= FROM_UNIXTIME(?) AND %s%s'
    ):format(
        what,
        where,
        -- live-case and volunteer-case rows count only with their mode's goals switch (Config.RealPlayers, shipped
        -- false)
        CP.RealPlayersRowFilter('goals', '')
    )
    local args = { citizenid, start }
    for _, v in ipairs(params) do args[#args + 1] = v end
    local ok, n = pcall(MySQL.scalar.await, sql, args)
    if not ok then
        CP.err(TAG, 'goal progress of %s (%s) failed: %s', citizenid, goal.id, tostring(n))
        return nil
    end
    return math.floor(CP.U.num(n))
end

-- Any goal reward of this kind in this period counts, whichever goal it was: a goal list changed in the middle of
-- a period re-picks the officer's goal, and the new one must not pay a second time.
local function Rewarded(kind, goal, citizenid, start)
    local ok, id = pcall(MySQL.scalar.await, [[
        SELECT id FROM cp_mission_runs
        WHERE citizenid = ? AND mission_type = 'goal' AND created_at >= FROM_UNIXTIME(?)
          AND JSON_UNQUOTE(JSON_EXTRACT(breakdown, '$.period')) = ?
        LIMIT 1
    ]], { citizenid, start, kind })
    if not ok then
        CP.err(TAG, 'goal reward lookup of %s (%s) failed: %s', citizenid, goal.id, tostring(id))
        return nil
    end
    return id ~= nil
end

local function GoalView(kind, citizenid, dept)
    local goal, _, start = Pick(kind, citizenid, nil, dept)
    if not goal then return nil end
    local count = math.floor(Num(goal.count, 1))
    local progress = ProgressOf(goal, citizenid, start) or 0
    local done = Rewarded(kind, goal, citizenid, start) == true or progress >= count
    return {
        id = goal.id,
        label = LabelOf(goal),
        count = count,
        progress = math.min(progress, count),
        done = done,
        points = PointsFor(kind),
    }
end

-- ============================================================================
--                                     API
-- ============================================================================

-- department (optional): the officer's department when the caller knows it (his department's goals).
function Goals.forOfficer(citizenid, department)
    if type(citizenid) ~= 'string' or citizenid == '' then return { daily = nil, weekly = nil } end
    CP.Db()
    local dept = department
    if type(dept) ~= 'string' then dept = ResolveDept(citizenid) end
    return { daily = GoalView('daily', citizenid, dept), weekly = GoalView('weekly', citizenid, dept) }
end

-- force (an admin's Mark complete, a goal a bug blocked): rewarded without the progress check.
local function Award(kind, citizenid, force, extra, dept)
    local goal, key, start = Pick(kind, citizenid, nil, dept)
    if not goal then return false end
    local count = math.floor(Num(goal.count, 1))
    if not force then
        local progress = ProgressOf(goal, citizenid, start)
        if not progress or progress < count then return false end
    end
    local already = Rewarded(kind, goal, citizenid, start)
    if already ~= false then return false end
    local points = PointsFor(kind)
    if not (CP.Scoring and CP.Scoring._insertBonusRow) then
        CP.warn(TAG, 'modules/progression/scoring is unavailable: the %s goal of %s cannot be rewarded yet', kind,
            citizenid)
        return false
    end
    local label = LabelOf(goal)
    local bd = { period = kind, periodKey = key, goalId = goal.id }
    for k, v in pairs(type(extra) == 'table' and extra or {}) do bd[k] = v end
    local rowId = CP.Scoring._insertBonusRow(citizenid, 'goal', goal.id, points, label, bd)
    if not rowId then return false end
    CP.log(TAG, '%s completed the %s goal %s (+%d)', citizenid, kind, goal.id, points)
    -- period = '<daily|weekly>:<period key>', so the same goal met in a later period is a new completion
    if CP.Hooks and CP.Hooks.fire then
        CP.Hooks.fire('goal:completed', citizenid, goal.id, ('%s:%s'):format(kind, tostring(key)))
    end
    CP.notifyCitizen(citizenid, 'success', kind == 'daily' and 'goals.completed_daily' or 'goals.completed_weekly',
        { goal = label, points = points })
    return true
end

function Goals.onRunCompleted(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    CP.Db()
    local st, err = busy:run(citizenid, 10000, function()
        local dept = ResolveDept(citizenid)
        Award('daily', citizenid, false, nil, dept)
        Award('weekly', citizenid, false, nil, dept)
    end)
    if st == 'busy' then CP.warn(TAG, 'goal check for %s skipped: another one is still running', citizenid) end
    if st == 'error' then CP.err(TAG, 'goal check for %s failed: %s', citizenid, tostring(err)) end
end

-- An admin completes the officer's current goal of this kind (goalId must be that goal, not yet rewarded).
-- ok, rowId | false, errKey. extra goes into the reward row's breakdown (who and why).
function Goals.complete(kind, citizenid, goalId, extra)
    if kind ~= 'daily' and kind ~= 'weekly' then return false, 'err.goal_unknown' end
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'err.invalid_citizenid' end
    CP.Db()
    local dept = ResolveDept(citizenid)
    local goal, _, start = Pick(kind, citizenid, nil, dept)
    if not goal or goal.id ~= goalId then return false, 'err.goal_unknown' end
    local already = Rewarded(kind, goal, citizenid, start)
    if already == nil then return false, 'err.internal' end
    if already then return false, 'err.goal_rewarded' end
    local st, res = busy:run(citizenid, 0, Award, kind, citizenid, true, extra, dept)
    if st == 'busy' then return false, 'err.busy' end
    if st ~= 'ok' or not res then return false, st == 'ok' and 'err.goal_rewarded' or 'err.internal' end
    return true
end

if CP.Hooks and CP.Hooks.on then
    -- a goal list changed in game: the officers' goals are re-picked at once; Rewarded (per kind and period) keeps a
    -- period from paying twice
    CP.Hooks.on('settings:changed', function(paths)
        for _, path in ipairs(type(paths) == 'table' and paths or {}) do
            if
                type(path) == 'string'
                and (
                    path == 'Objectives'
                    or path:find('^Objectives%.dailyGoal')
                    or path:find('^Objectives%.weeklyGoal')
                )
            then
                CP.log(TAG, 'goals changed in game (%s): a period already rewarded stays rewarded', path)
                return
            end
        end
    end)
end

-- ============================================================================
--                          THE GOALS MISSION CONTROL
-- ============================================================================

local function GoalChoices(kind)
    local out = {}
    for _, g in ipairs(ValidGoals(GoalList(kind))) do
        out[#out + 1] = { id = g.id, label = LabelOf(g) }
    end
    return out
end

function Goals.registerControl()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    return dc.register(CONTROL_KEY, {
        kind = 'map',
        integer = true,
        range = { 1, LIST_MAX },
        -- no pick: every goal of the admin's lists
        configValue = function() return { daily = {}, weekly = {} } end,
        check = function(v, bounds)
            local clean = CleanPick(v, bounds, true)
            if not clean then return nil, 'err.control_value' end
            return clean
        end,
        clamp = function(v, bounds) return CleanPick(v, bounds, false) end,
        -- a narrower goal list is a choice of goals that pay points: the setter keeps the admin's whole list
        relaxes = function() return true end,
        -- the pick counts from the next weekly reset; until then the one that counts now stays
        carry = function(ctx)
            local out = { daily = ctx.value.daily, weekly = ctx.value.weekly, from = NextWeekKey() }
            local row = type(ctx.row) == 'table' and ctx.row or nil
            local saved = row and CleanPick(row.value, dc.bounds and dc.bounds(ctx.dept, CONTROL_KEY) or {}, false)
            local now = ListsAt(saved, WeekKeyOf())
            if type(now) == 'table' then out.prev = { daily = now.daily or {}, weekly = now.weekly or {} } end
            return out
        end,
        -- what the supervisor's screen shows: the admin's goals, the week a pick counts from and what counts now
        viewExtra = function(dept)
            local ok, v = pcall(dc.get, dept, CONTROL_KEY)
            local now = ok and ListsAt(v, WeekKeyOf()) or nil
            return {
                goalsAll = { daily = GoalChoices('daily'), weekly = GoalChoices('weekly') },
                goalsFrom = NextWeekKey(),
                goalsNow = type(now) == 'table' and { daily = now.daily or {}, weekly = now.weekly or {} } or nil,
            }
        end,
    })
end
Goals.registerControl()

-- Test hooks (not part of the contract).
Goals._pick = Pick
Goals._progress = ProgressOf
