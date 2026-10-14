-- CP.Goals (server): personal daily and weekly goals.

CP.Goals = CP.Goals or {}
local Goals = CP.Goals
local TAG = 'goals'

local busy = {}   -- citizenid -> true while onRunCompleted runs for them

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Period(kind, ts)
    ts = ts or Now()
    if kind == 'daily' then
        local key = CP.Schedule and CP.Schedule.dayKey and CP.Schedule.dayKey(ts) or os.date('%Y-%m-%d', ts)
        local start = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(ts) or (ts - ts % 86400)
        return key, start
    end
    local start = CP.Schedule and CP.Schedule.weekStart and CP.Schedule.weekStart(ts) or (ts - 7 * 86400)
    local key = CP.Schedule and CP.Schedule.weekKey and CP.Schedule.weekKey(ts) or os.date('%Y-%m-%d', start)
    return key, start
end

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

-- The goal of 'kind' for citizenid in the period that contains ts.
local function Pick(kind, citizenid, ts)
    local list = ValidGoals(Config.Goals and Config.Goals[kind])
    if #list == 0 then return nil end
    local key, start = Period(kind, ts)
    local rng = CP.U.rng(CP.U.hash(('%s:%s:%s'):format(kind, key, citizenid)))
    local goal = rng:pick(list)
    return goal, key, start
end

local function PointsFor(kind)
    local g = Config.Goals or {}
    return math.max(0, math.floor(Num(kind == 'daily' and g.dailyPoints or g.weeklyPoints, 0)))
end

local function LabelOf(goal)
    if type(goal.label) == 'string' and goal.label ~= '' then return goal.label end
    return CP.L('goals.unnamed', { count = math.floor(Num(goal.count, 1)) })
end

-- Service-record columns a stat goal may count (Config.Goals: stat = ...); completed rows only.
local STAT_COLUMNS = {
    arrests = true,
    citations = true,
    impounds = true,
    rescues = true,
    vehicles_stopped = true,
    evidence = true,
    decisions_ok = true,
    decisions_best = true,
}

-- Counted runs since 'start' that match the goal (a stat goal: the sum of that column over them).
local function ProgressOf(goal, citizenid, start)
    local what = 'COUNT(*)'
    if type(goal.stat) == 'string' then
        if not STAT_COLUMNS[goal.stat] then return 0 end
        what = ('COALESCE(SUM(%s), 0)'):format(goal.stat)
    end
    local sql = {
        [[SELECT ]] .. what .. [[ AS n FROM cp_mission_runs
          WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0
            AND mission_type NOT IN ('manual_award', 'goal') AND created_at >= FROM_UNIXTIME(?)]],
    }
    local params = { citizenid, start }
    if type(goal.type) == 'string' and goal.type ~= '' then
        sql[#sql + 1] = 'AND mission_type = ?'
        params[#params + 1] = goal.type
    end
    if type(goal.mission) == 'string' and goal.mission ~= '' then
        sql[#sql + 1] = 'AND mission_id = ?'
        params[#params + 1] = goal.mission
    end
    if goal.unit == true then sql[#sql + 1] = 'AND participants >= 2' end
    if goal.crossDepartment == true then sql[#sql + 1] = 'AND departments_n >= 2' end
    if goal.missionCall == true then sql[#sql + 1] = 'AND mission_call_id IS NOT NULL' end
    local ok, n = pcall(MySQL.scalar.await, table.concat(sql, ' '), params)
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

local function GoalView(kind, citizenid)
    local goal, _, start = Pick(kind, citizenid)
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

function Goals.forOfficer(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { daily = nil, weekly = nil } end
    Db()
    return { daily = GoalView('daily', citizenid), weekly = GoalView('weekly', citizenid) }
end

-- force (an admin's Mark complete, a goal a bug blocked): rewarded without the progress check.
local function Award(kind, citizenid, force, extra)
    local goal, key, start = Pick(kind, citizenid)
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
        CP.warn(TAG, 'modules/scoring is unavailable: the %s goal of %s cannot be rewarded yet', kind, citizenid)
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
    if CP.Tablet and CP.Tablet.notify and CP.Qbx and CP.Qbx.getByCitizenId then
        local src = CP.Qbx.getByCitizenId(citizenid)
        if src then
            CP.Tablet.notify(src, 'success', kind == 'daily' and 'goals.completed_daily' or 'goals.completed_weekly',
                { goal = label, points = points })
        end
    end
    return true
end

function Goals.onRunCompleted(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    Db()
    local waited = 0
    while busy[citizenid] and waited < 10000 do
        Wait(50)
        waited = waited + 50
    end
    if busy[citizenid] then
        CP.warn(TAG, 'goal check for %s skipped: another one is still running', citizenid)
        return
    end
    busy[citizenid] = true
    local ok, err = pcall(function()
        Award('daily', citizenid)
        Award('weekly', citizenid)
    end)
    busy[citizenid] = nil
    if not ok then CP.err(TAG, 'goal check for %s failed: %s', citizenid, tostring(err)) end
end

-- An admin completes the officer's current goal of this kind (goalId must be that goal, not yet rewarded).
-- ok, rowId | false, errKey. extra goes into the reward row's breakdown (who and why).
function Goals.complete(kind, citizenid, goalId, extra)
    if kind ~= 'daily' and kind ~= 'weekly' then return false, 'err.goal_unknown' end
    if type(citizenid) ~= 'string' or citizenid == '' then return false, 'err.invalid_citizenid' end
    Db()
    local goal, _, start = Pick(kind, citizenid)
    if not goal or goal.id ~= goalId then return false, 'err.goal_unknown' end
    local already = Rewarded(kind, goal, citizenid, start)
    if already == nil then return false, 'err.internal' end
    if already then return false, 'err.goal_rewarded' end
    if busy[citizenid] then return false, 'err.busy' end
    busy[citizenid] = true
    local ok, res = pcall(Award, kind, citizenid, true, extra)
    busy[citizenid] = nil
    if not ok or not res then return false, ok and 'err.goal_rewarded' or 'err.internal' end
    return true
end

if CP.Hooks and CP.Hooks.on then
    -- a goal list changed in game: the officers' goals are re-picked at once; Rewarded (per kind and period) keeps a
    -- period from paying twice
    CP.Hooks.on('settings:changed', function(paths)
        for _, path in ipairs(type(paths) == 'table' and paths or {}) do
            if type(path) == 'string' and (path == 'Goals' or path:sub(1, 6) == 'Goals.') then
                CP.log(TAG, 'goals changed in game (%s): a period already rewarded stays rewarded', path)
                return
            end
        end
    end)
end

-- Test hooks (not part of the contract).
Goals._pick = Pick
Goals._progress = ProgressOf
