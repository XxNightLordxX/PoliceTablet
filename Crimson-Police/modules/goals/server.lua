-- modules/goals/server.lua · CP.Goals (server): personal daily and weekly goals.
--
-- Owns
--   * picking each officer's goals: one of Config.Goals.daily per reset-adjusted day and one of
--     Config.Goals.weekly per week (from the weekly reset on Config.Leaderboard.weekStartsOn), with a seed
--     made from the date (or the week's start) and the citizenid, so a restart keeps the same goals and
--     nothing is stored
--   * progress: the officer's counted runs since the period started (completed, not flagged, not voided,
--     never manual_award or goal rows) that match the goal (type = a mission type key, unit = 2+
--     participants, crossDepartment = 2+ departments, mission = one mission id; count = how many)
--   * the reward: once per period a 'goal' row (mission_type 'goal', mission_id = the goal id, state and
--     end_reason 'completed', final_points = Config.Goals.dailyPoints / weeklyPoints) counted through
--     CP.Scoring (XP; Overall and Department boards only)
--
-- Public API (docs/ARCHITECTURE.md §5.19)
--   CP.Goals.forOfficer(citizenid) -> { daily = Goal|nil, weekly = Goal|nil }
--       Goal = { id, label, count, progress, done, points }   (progress is capped at count)
--   CP.Goals.onRunCompleted(citizenid)   (hook: a completed row was counted) -> inserts the goal rows earned
-- Both query the database: call them from a thread.

CP.Goals = CP.Goals or {}
local Goals = CP.Goals
local TAG = 'goals'

local busy = {}   -- citizenid -> true while onRunCompleted runs for them

-- ── helpers ─────────────────────────────────────────────────────────────────
local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function period(kind, ts)
    ts = ts or now()
    if kind == 'daily' then
        local key = CP.Schedule and CP.Schedule.dayKey and CP.Schedule.dayKey(ts) or os.date('%Y-%m-%d', ts)
        local start = CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(ts) or (ts - ts % 86400)
        return key, start
    end
    local start = CP.Schedule and CP.Schedule.weekStart and CP.Schedule.weekStart(ts) or (ts - 7 * 86400)
    local key = CP.Schedule and CP.Schedule.weekKey and CP.Schedule.weekKey(ts) or os.date('%Y-%m-%d', start)
    return key, start
end

local function validGoals(list)
    local out = {}
    for _, g in ipairs(type(list) == 'table' and list or {}) do
        if type(g) == 'table' and type(g.id) == 'string' and g.id ~= '' and #g.id <= 40 and num(g.count, 0) >= 1 then
            out[#out + 1] = g
        end
    end
    return out
end

-- The goal of `kind` for citizenid in the period that contains ts.
local function pick(kind, citizenid, ts)
    local list = validGoals(Config.Goals and Config.Goals[kind])
    if #list == 0 then return nil end
    local key, start = period(kind, ts)
    local rng = CP.U.rng(CP.U.hash(('%s:%s:%s'):format(kind, key, citizenid)))
    local goal = rng:pick(list)
    return goal, key, start
end

local function pointsFor(kind)
    local g = Config.Goals or {}
    return math.max(0, math.floor(num(kind == 'daily' and g.dailyPoints or g.weeklyPoints, 0)))
end

local function labelOf(goal)
    if type(goal.label) == 'string' and goal.label ~= '' then return goal.label end
    return CP.L('goals.unnamed', { count = math.floor(num(goal.count, 1)) })
end

-- Counted runs since `start` that match the goal.
local function progressOf(goal, citizenid, start)
    local sql = {
        [[SELECT COUNT(*) AS n FROM cp_mission_runs
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
    local ok, n = pcall(MySQL.scalar.await, table.concat(sql, ' '), params)
    if not ok then
        CP.err(TAG, 'goal progress of %s (%s) failed: %s', citizenid, goal.id, tostring(n))
        return nil
    end
    return math.floor(CP.U.num(n))
end

local function rewarded(kind, goal, citizenid, start)
    local ok, id = pcall(MySQL.scalar.await, [[
        SELECT id FROM cp_mission_runs
        WHERE citizenid = ? AND mission_type = 'goal' AND mission_id = ? AND created_at >= FROM_UNIXTIME(?)
          AND JSON_UNQUOTE(JSON_EXTRACT(breakdown, '$.period')) = ?
        LIMIT 1
    ]], { citizenid, goal.id, start, kind })
    if not ok then
        CP.err(TAG, 'goal reward lookup of %s (%s) failed: %s', citizenid, goal.id, tostring(id))
        return nil
    end
    return id ~= nil
end

local function goalView(kind, citizenid)
    local goal, _, start = pick(kind, citizenid)
    if not goal then return nil end
    local count = math.floor(num(goal.count, 1))
    local progress = progressOf(goal, citizenid, start) or 0
    local done = rewarded(kind, goal, citizenid, start) == true or progress >= count
    return {
        id = goal.id,
        label = labelOf(goal),
        count = count,
        progress = math.min(progress, count),
        done = done,
        points = pointsFor(kind),
    }
end

-- ── API ─────────────────────────────────────────────────────────────────────
function Goals.forOfficer(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { daily = nil, weekly = nil } end
    db()
    return { daily = goalView('daily', citizenid), weekly = goalView('weekly', citizenid) }
end

local function award(kind, citizenid)
    local goal, key, start = pick(kind, citizenid)
    if not goal then return false end
    local count = math.floor(num(goal.count, 1))
    local progress = progressOf(goal, citizenid, start)
    if not progress or progress < count then return false end
    local already = rewarded(kind, goal, citizenid, start)
    if already ~= false then return false end
    local points = pointsFor(kind)
    if not (CP.Scoring and CP.Scoring._insertBonusRow) then
        CP.warn(TAG, 'modules/scoring is unavailable: the %s goal of %s cannot be rewarded yet', kind, citizenid)
        return false
    end
    local label = labelOf(goal)
    local rowId = CP.Scoring._insertBonusRow(citizenid, 'goal', goal.id, points, label,
        { period = kind, periodKey = key, goalId = goal.id })
    if not rowId then return false end
    CP.log(TAG, '%s completed the %s goal %s (+%d)', citizenid, kind, goal.id, points)
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
    db()
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
        award('daily', citizenid)
        award('weekly', citizenid)
    end)
    busy[citizenid] = nil
    if not ok then CP.err(TAG, 'goal check for %s failed: %s', citizenid, tostring(err)) end
end

-- Test hooks (not part of the contract).
Goals._pick = pick
Goals._progress = progressOf
