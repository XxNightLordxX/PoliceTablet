-- CP.Scoring (server): points, streaks, XP, XP levels, badges, manual awards and the officer Home screen.

CP.Scoring = CP.Scoring or {}
local Scoring = CP.Scoring
local TAG = 'scoring'

local BOSS_ID = 'weekly_boss_kingpin'
local NOT_RUNS = { manual_award = true, goal = true }
local END_EVALUATED = { no_participant_downed = true, no_weapons_fired = true }
-- Personal ids recorded by the engine / CP.Npc whose values live in Config.Scoring.common.
local COMMON_RECORDED = {
    pedestrian_hit = { key = 'pedestrianHit', each = true },
    lights_siren = { key = 'lightsSiren', each = false },
    shot_surrendered = { key = 'shotSurrendered', each = true },
}
local BADGES = {
    { id = 'iron_wheels', cfg = 'ironWheels' },
    { id = 'sharpshooter', cfg = 'sharpshooter' },
    { id = 'road_warrior', cfg = 'roadWarrior' },
    { id = 'partner_in_crime', cfg = 'partnerInCrime' },
    { id = 'joint_task_force', cfg = 'jointTaskForce' },
    { id = 'by_the_book', cfg = 'byTheBook' },
    { id = 'first_responder', cfg = 'firstResponder' },
}
local MAX_WALK_DAYS = 400      -- missed days examined for grace before a streak counts as broken
local STREAK_STORE_MAX = 127   -- cp_officers.streak_days is a signed TINYINT
local MANUAL_MAX = 10000
local REASON_MAX = 255         -- characters (cp_audit.reason is VARCHAR(255) utf8mb4; the UI's maxLength counts characters)

local duty = {}        -- citizenid -> { onDuty = bool, firstDone = bool, since = ts }
local srcCid = {}      -- src -> citizenid (for unload/drop)
local warned = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n < 0 then return nil end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function WarnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function ResetHour()
    local h = math.floor(Num(Config.Time and Config.Time.resetHour, 0))
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function DayKey(ts)
    if CP.Schedule and CP.Schedule.dayKey then return CP.Schedule.dayKey(ts) end
    ts = ts or Now()
    local t = os.date('*t', ts)
    if t.hour < ResetHour() then ts = os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12 }) end
    return os.date('%Y-%m-%d', ts)
end

local function ParseKey(key)
    if type(key) ~= 'string' then return nil end
    local y, m, d = key:match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

-- A timestamp inside the reset-adjusted day 'key' (30 minutes after its reset).
local function KeyTime(key)
    local y, m, d = ParseKey(key)
    if not y then return nil end
    return os.time({ year = y, month = m, day = d, hour = ResetHour(), min = 30, sec = 0 })
end

local function AddDays(key, n)
    local y, m, d = ParseKey(key)
    return os.date('%Y-%m-%d', os.time({ year = y, month = m, day = d + n, hour = 12, min = 0, sec = 0 }))
end

local function DaysBetween(a, b)
    local ya, ma, da = ParseKey(a)
    local yb, mb, db2 = ParseKey(b)
    if not ya or not yb then return nil end
    local ta = os.time({ year = ya, month = ma, day = da, hour = 12 })
    local tb = os.time({ year = yb, month = mb, day = db2, hour = 12 })
    return math.floor((tb - ta) / 86400 + 0.5)
end

local function WeekKeyOf(key)
    local ts = KeyTime(key)
    if CP.Schedule and CP.Schedule.weekKey then return CP.Schedule.weekKey(ts) end
    local t = os.date('*t', ts)
    local back = (t.wday + 5) % 7   -- days since monday
    return os.date('%Y-%m-%d', os.time({ year = t.year, month = t.month, day = t.day - back, hour = 12 }))
end

local function ScoringCfg() return Config.Scoring or {} end
local function CommonCfg() return ScoringCfg().common or {} end

local function TierRow(run)
    local t = run.payTier
    if type(t) == 'table' then return t end
    if CP.Scaling and CP.Scaling.tierByName then
        local row = CP.Scaling.tierByName(t or run.expectedTier)
        if row then return row end
    end
    return { tier = 'standard', points = 1.0, cash = 1.0 }
end

local function Notify(citizenid, kind, key, vars)
    if not (CP.Tablet and CP.Tablet.notify and CP.Qbx and CP.Qbx.getByCitizenId) then return end
    local src = CP.Qbx.getByCitizenId(citizenid)
    if src then CP.Tablet.notify(src, kind, key, vars) end
end

-- ============================================================================
--                                      P
-- ============================================================================

function Scoring.P(mission)
    if type(mission) ~= 'table' then return 0 end
    if mission.isBoss == true or mission.id == BOSS_ID then
        local b = Config.Events and Config.Events.weeklyBoss
        return math.max(0, CP.U.round(Num(b and b.points, 0)))
    end
    local t = Config.MissionTypes and Config.MissionTypes[mission.type]
    local stars = Config.Difficulty and Config.Difficulty.pointsByStars
    local d = math.floor(Num(mission.difficulty, 1))
    if d < 1 then d = 1 end
    if d > 3 then d = 3 end
    return math.max(0, CP.U.round(Num(t and t.points, 0) * Num(stars and stars[d], 1.0)))
end

-- ============================================================================
--                                   STREAKS
-- ============================================================================

local function GraceDays()
    return math.max(0, math.floor(Num(ScoringCfg().streakGraceDays, 0)))
end

local function StreakMultiplier(days)
    local cfg = ScoringCfg()
    return 1 + math.min(Num(cfg.streakMax, 0.25), Num(cfg.streakStep, 0.05) * math.max(0, days))
end

local function ReadOfficer(citizenid)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT citizenid, xp, streak_days, DATE_FORMAT(last_complete, '%Y-%m-%d') AS last_complete,
               DATE_FORMAT(grace_week, '%Y-%m-%d') AS grace_week, grace_used, display_name, department
        FROM cp_officers WHERE citizenid = ?
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'reading cp_officers for %s failed: %s', tostring(citizenid), tostring(row))
        return nil, false
    end
    if type(row) ~= 'table' or row.citizenid == nil then return nil, true end
    return row, true
end

local function StreakState(row)
    if not row then return { days = 0, last = nil, graceWeek = nil, graceUsed = 0 } end
    return {
        days = math.max(0, math.floor(CP.U.num(row.streak_days))),
        last = ParseKey(row.last_complete) and row.last_complete or nil,
        graceWeek = ParseKey(row.grace_week) and row.grace_week or nil,
        graceUsed = math.max(0, math.floor(CP.U.num(row.grace_used))),
    }
end

-- Walk the missed days strictly between state.last and toKey. Returns alive, graceWeek, graceUsed.
local function WalkGap(state, toKey)
    local gap = (DaysBetween(state.last, toKey) or 0) - 1
    if gap <= 0 then return true, state.graceWeek, state.graceUsed end
    local allowed = GraceDays()
    if allowed <= 0 or gap > MAX_WALK_DAYS then return false, state.graceWeek, state.graceUsed end
    local gw, gu = state.graceWeek, state.graceUsed
    for i = 1, gap do
        local wk = WeekKeyOf(AddDays(state.last, i))
        if wk ~= gw then gw, gu = wk, 0 end
        if gu >= allowed then return false, state.graceWeek, state.graceUsed end
        gu = gu + 1
    end
    return true, gw, gu
end

-- The streak after a completed run on key. Returns the new state and whether it changed.
local function Advance(state, key)
    if state.last == key then return state, false end
    if state.last and (DaysBetween(state.last, key) or 0) < 0 then return state, false end
    if not state.last or state.days <= 0 then
        return { days = 1, last = key, graceWeek = state.graceWeek, graceUsed = state.graceUsed }, true
    end
    local alive, gw, gu = WalkGap(state, key)
    if alive then return { days = state.days + 1, last = key, graceWeek = gw, graceUsed = gu }, true end
    return { days = 1, last = key, graceWeek = state.graceWeek, graceUsed = state.graceUsed }, true
end

-- The live streak on todayKey (today may still get its run): days, graceWeek, graceUsed.
local function CurrentStreak(state, todayKey)
    if not state.last or state.days <= 0 then return 0, state.graceWeek, state.graceUsed end
    local diff = DaysBetween(state.last, todayKey) or 0
    if diff <= 1 then return state.days, state.graceWeek, state.graceUsed end
    local alive, gw, gu = WalkGap(state, todayKey)
    if alive then return state.days, gw, gu end
    return 0, state.graceWeek, state.graceUsed
end

local function GraceLeftFor(gw, gu, todayKey)
    local allowed = GraceDays()
    if allowed <= 0 then return false end
    local used = (gw == WeekKeyOf(todayKey)) and gu or 0
    return used < allowed
end

function Scoring.streak(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { days = 0, multiplier = 1.0, graceLeft = false } end
    Db()
    local row = ReadOfficer(citizenid)
    local today = DayKey(Now())
    local days, gw, gu = CurrentStreak(StreakState(row), today)
    return { days = days, multiplier = StreakMultiplier(days), graceLeft = GraceLeftFor(gw, gu, today) }
end

local function StoreStreak(citizenid, st)
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_officers (citizenid, streak_days, last_complete, grace_week, grace_used)
        VALUES (?, ?, ?, NULLIF(?, ''), ?)
        ON DUPLICATE KEY UPDATE streak_days = VALUES(streak_days), last_complete = VALUES(last_complete),
            grace_week = VALUES(grace_week), grace_used = VALUES(grace_used)
    ]], { citizenid, math.min(st.days, STREAK_STORE_MAX), st.last, st.graceWeek or '', math.min(st.graceUsed, 127) })
    if not ok then CP.err(TAG, 'saving the streak of %s failed: %s', citizenid, tostring(err)) end
    return ok
end

local function ApplyStreakDay(citizenid, key)
    local row, ok = ReadOfficer(citizenid)
    if not ok then return end
    local st, changed = Advance(StreakState(row), key)
    if changed then
        StoreStreak(citizenid, st)
        CP.log(TAG, 'streak of %s: %d day(s) (last %s)', citizenid, st.days, st.last)
    end
end

local STREAK_DAYS_SQL = [[SELECT UNIX_TIMESTAMP(created_at) AS ts FROM %s
    WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0
      AND mission_type NOT IN ('manual_award', 'goal')]]

-- The streak re-derived from the officer's counted completed runs (live and archived), with the same Advance and
-- grace rules as a run: { old = { days, multiplier }, new = { days, multiplier } } | nil, errKey.
function Scoring.recalcStreak(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'err.invalid_citizenid' end
    Db()
    local row, ok = ReadOfficer(citizenid)
    if not ok then return nil, 'err.internal' end
    if not row then return nil, 'err.unknown_officer' end
    local before = Scoring.streak(citizenid)
    local keys, seen = {}, {}
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local okQ, rows = pcall(MySQL.query.await, STREAK_DAYS_SQL:format(tbl), { citizenid })
        if not okQ then return nil, 'err.internal' end
        for _, r in ipairs(rows or {}) do
            local key = DayKey(math.floor(CP.U.num(r.ts)))
            if not seen[key] then
                seen[key] = true
                keys[#keys + 1] = key
            end
        end
    end
    table.sort(keys)
    local st = { days = 0, last = nil, graceWeek = nil, graceUsed = 0 }
    for _, key in ipairs(keys) do st = Advance(st, key) end
    if st.last then
        if not StoreStreak(citizenid, st) then return nil, 'err.internal' end
    else
        pcall(MySQL.update.await, 'UPDATE cp_officers SET streak_days = 0 WHERE citizenid = ?', { citizenid })
    end
    return { old = before, new = Scoring.streak(citizenid) }
end

-- Missed days forgiven (server downtime): the last completed day moves forward by up to days, never past yesterday,
-- so a breaking streak lives on. No day is added to the streak itself. { old, new } | nil, errKey.
function Scoring.forgiveStreakDays(citizenid, days)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'err.invalid_citizenid' end
    days = math.tointeger(tonumber(days))
    if not days or days < 1 then return nil, 'err.invalid_days' end
    Db()
    local row, ok = ReadOfficer(citizenid)
    if not ok then return nil, 'err.internal' end
    if not row then return nil, 'err.unknown_officer' end
    local st = StreakState(row)
    local today = DayKey(Now())
    local yesterday = AddDays(today, -1)
    if not st.last or st.days <= 0 or (DaysBetween(st.last, today) or 0) <= 1 then return nil, 'err.streak_nothing' end
    local before = Scoring.streak(citizenid)
    local moved = AddDays(st.last, days)
    if (DaysBetween(moved, yesterday) or 0) < 0 then moved = yesterday end
    local stored = StoreStreak(citizenid,
        { days = st.days, last = moved, graceWeek = st.graceWeek, graceUsed = st.graceUsed })
    if not stored then return nil, 'err.internal' end
    return { old = before, new = Scoring.streak(citizenid) }
end

-- ============================================================================
--                        FIRST RUN SINCE GOING ON DUTY
-- ============================================================================

local function MarkFirstDone(citizenid)
    local st = duty[citizenid]
    if st then
        st.firstDone = true
    else
        duty[citizenid] = { onDuty = true, firstDone = true, since = Now() }
    end
end

local function DutyEvaluate(src, fresh)
    if not (CP.Qbx and CP.Qbx.getInfo) then return end
    local info = CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return end
    local cid = info.citizenid
    srcCid[src] = cid
    if fresh then duty[cid] = nil end
    local onDuty = info.job and info.job.onduty == true and CP.Access and CP.Access.departmentForJob
        and CP.Access.departmentForJob(info.job.name) ~= nil
    local st = duty[cid]
    if onDuty then
        if not st or not st.onDuty then
            duty[cid] = { onDuty = true, firstDone = false, since = Now() }
            CP.log(TAG, '%s went on duty: the next completed run earns the first-run bonus', cid)
        end
    elseif st then
        st.onDuty = false
    end
end

local function DutyEnded(src)
    local cid = srcCid[src]
    srcCid[src] = nil
    if cid and duty[cid] then duty[cid].onDuty = false end
end

function Scoring.isFirstRunSinceDuty(src)
    src = ToSrc(src)
    if not src or not (CP.Qbx and CP.Qbx.getInfo) then return false end
    local info = CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return false end
    local cid = info.citizenid
    srcCid[src] = cid
    local st = duty[cid]
    if not st then
        -- Unknown since this resource started: count a completed run earlier today as the first one.
        Db()
        local ok, found = pcall(MySQL.scalar.await, [[
            SELECT 1 AS found FROM cp_mission_runs
            WHERE citizenid = ? AND state = 'completed' AND mission_type NOT IN ('manual_award', 'goal')
              AND created_at >= FROM_UNIXTIME(?)
            LIMIT 1
        ]], { cid, CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(Now()) or (Now() - 86400) })
        st = { onDuty = info.job and info.job.onduty == true, firstDone = ok and found ~= nil, since = Now() }
        duty[cid] = st
    end
    return st.firstDone ~= true
end

-- Whether an online officer's next completed run still earns the first-run bonus (nil when not online).
function Scoring.firstRunAvailable(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(citizenid) or nil
    if not ToSrc(src) then return nil end
    return Scoring.isFirstRunSinceDuty(src)
end

-- Makes the first-run bonus available again for this duty period (an admin action, once a day per officer).
function Scoring.resetFirstRun(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local st = duty[citizenid]
    duty[citizenid] = { onDuty = st == nil or st.onDuty ~= false, firstDone = false, since = Now() }
    return true
end

-- ============================================================================
--                                   COMPUTE
-- ============================================================================

local function ListedEntries(mission)
    local map, order = {}, {}
    for _, field in ipairs({ 'bonuses', 'penalties' }) do
        local list = type(mission[field]) == 'table' and mission[field] or {}
        for _, e in ipairs(list) do
            if type(e) == 'table' and type(e.id) == 'string' and not map[e.id] then
                map[e.id] = { entry = e, penalty = field == 'penalties' }
                order[#order + 1] = e.id
            end
        end
    end
    return map, order
end

-- Custom (Mission Builder) missions: the value of a bonus or penalty never comes from the mission file
-- beyond what the builder allows (Config.Bonuses ids, capped by Config.Builder.bonusCap).
local function IsCustom(mission)
    return type(mission) == 'table' and mission.source == 'custom'
end

local function BuilderCap(P)
    local c = Config.Builder and Config.Builder.bonusCap or {}
    return math.abs(Num(c.points, 50)), math.abs(Num(c.share, 0.25)) * P
end

local function ClampAbs(v, max)
    if v > max then return max end
    if v < -max then return -max end
    return v
end

-- A per-occurrence value hint recorded by trusted block code (ctx.award / ctx.penalize opts.points).
-- On custom missions a bonus hint is capped at Config.Builder.bonusCap.points (a penalty hint comes from
-- a block setting that keeps its own range, e.g. protect_rescue hitPenalty 0-100).
local function HintValue(hints, id, custom, P)
    local v = tonumber(hints[id])
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    if custom and v > 0 then
        local capPts = BuilderCap(P)
        if v > capPts then v = capPts end
    end
    return v
end

-- Per-occurrence value and 'each' of a listed entry. On custom missions only Config.Bonuses ids carry a
-- value of their own (the builder's capped override, else the config value; its each flag); a file value
-- (points / pctOfPoints / each) on any other id is ignored, so only a trusted block hint can value it.
local function EntryValue(id, e, P, custom)
    local cfg = Config.Bonuses and Config.Bonuses[id]
    if custom then
        if type(cfg) ~= 'table' then return nil, false end
        local capPts, capShare = BuilderCap(P)
        local per
        if cfg.kind == 'pct' then
            local share = type(e.pctOfPoints) == 'number' and e.pctOfPoints or Num(cfg.value, 0)
            per = ClampAbs(Num(share, 0) * P, capShare)
        else
            local pts = type(e.points) == 'number' and e.points or Num(cfg.value, 0)
            per = ClampAbs(Num(pts, 0), capPts)
        end
        return per, cfg.each == true
    end
    local per
    if type(e.points) == 'number' then
        per = e.points
    elseif type(e.pctOfPoints) == 'number' then
        per = e.pctOfPoints * P
    elseif type(cfg) == 'table' then
        per = cfg.kind == 'pct' and Num(cfg.value, 0) * P or Num(cfg.value, 0)
    end
    local each = e.each == true or (type(cfg) == 'table' and cfg.each == true)
    return per, each
end

local function CountOf(run, p, id)
    local shared = run.score and run.score.shared and Num(run.score.shared[id], 0) or 0
    local personal = p.score and Num(p.score[id], 0) or 0
    return math.max(0, math.floor(shared + personal))
end

local function Label(kind, id, count, each, vars)
    local text = CP.L((kind == 'bonus' and 'bonus.' or 'penalty.') .. id, vars)
    if each and count > 1 then text = text .. ' ' .. CP.L('scoring.times', { n = count }) end
    return text
end

local function AddLine(bonuses, penalties, id, value, count, each, penaltyHint, vars)
    local pts = CP.U.round(value)
    if pts == 0 then return 0 end
    if penaltyHint and pts > 0 then pts = -pts end
    if pts > 0 then
        bonuses[#bonuses + 1] = { id = id, label = Label('bonus', id, count, each, vars), points = pts }
    else
        penalties[#penalties + 1] = { id = id, label = Label('penalty', id, count, each, vars), points = pts }
    end
    return pts
end

local function PresenceFailed(run, p)
    if not (CP.AntiCheat and CP.AntiCheat.presenceOk) then return false end
    if type(run.order) ~= 'table' or #run.order < 2 then return false end
    local ok, present = pcall(CP.AntiCheat.presenceOk, run, p)
    return ok and present == false
end

local function DepartmentsOf(run, p)
    local seen, n = {}, 0
    for _, q in pairs(run.participants or {}) do
        if type(q) == 'table' and (q.status == 'active' or q == p) and q.department and not seen[q.department] then
            seen[q.department] = true
            n = n + 1
        end
    end
    if p.department and not seen[p.department] then n = n + 1 end
    return math.max(1, n)
end

local function DurationOf(run, opts)
    if opts.durationS ~= nil then return Num(opts.durationS, 0) end
    if run.startedAt then return math.max(0, (run.endedAt or Now()) - run.startedAt) end
    return 0
end

local function ObjectiveShare(run, opts)
    if opts.failedShare ~= nil then return CP.U.clamp(Num(opts.failedShare, 0), 0, 1) end
    local total = Num(opts.objectivesTotal, nil)
    local done = Num(opts.objectivesDone, nil)
    if not total then
        total, done = 0, 0
        local objs = run.mission and run.mission.objectives or {}
        for i = 1, #objs do
            total = total + 1
            local o = run.objectives and run.objectives[i]
            if o and o.status == 'done' then done = done + 1 end
        end
    end
    if total <= 0 then return 0 end
    return CP.U.clamp((done or 0) / total, 0, 1)
end

-- Every bonus and penalty line of a completed row.
local function ScoreLines(run, p, P, opts)
    local bonuses, penalties = {}, {}
    local total = 0
    local mission = run.mission or {}
    local common = CommonCfg()
    local listed, order = ListedEntries(mission)
    local stats = run.stats or {}

    local hints = run.score and run.score.values or {}
    local kinds = run.score and run.score.kinds or {}
    local custom = IsCustom(mission)

    -- 1. the mission card (in file order), end-evaluated ids included
    for _, id in ipairs(order) do
        local l = listed[id]
        local per, each = EntryValue(id, l.entry, P, custom)
        local hint = per == nil and HintValue(hints, id, custom, P) or nil
        if hint then
            -- Listed without a value of its own and not in Config.Bonuses: the block's per-occurrence value.
            per, each = hint, true
        end
        if per then
            if END_EVALUATED[id] then
                local earned = (id == 'no_participant_downed' and Num(stats.downs, 0) == 0)
                    or (id == 'no_weapons_fired' and Num(stats.weaponsFired, 0) == 0)
                if earned then total = total + AddLine(bonuses, penalties, id, per, 1, false, l.penalty) end
            else
                local count = CountOf(run, p, id)
                if count > 0 then
                    local value = each and per * count or per
                    total = total + AddLine(bonuses, penalties, id, value, count, each, l.penalty)
                end
            end
        end
    end

    -- 2. recorded ids the card does not list: a per-occurrence value hint, or a common personal id
    local recorded = {}
    for id in pairs(run.score and run.score.shared or {}) do recorded[id] = true end
    for id in pairs(p.score or {}) do recorded[id] = true end
    local extras = CP.U.keys(recorded)
    for _, id in ipairs(extras) do
        if not listed[id] and not END_EVALUATED[id] then
            local count = CountOf(run, p, id)
            local c = COMMON_RECORDED[id]
            local cfgB = Config.Bonuses and Config.Bonuses[id]
            if count > 0 and type(cfgB) == 'table' and cfgB.engineOnly == true then
                -- engine-awarded ids (decision grades, rapid response): never listed by a mission file, valued
                -- by the recorded hint or Config.Bonuses, on built-in and custom missions alike
                local per = HintValue(hints, id, false, P)
                if per == nil then
                    local share = Num(cfgB.value, 0)
                    if id == 'rapid_response' then
                        local rr = Config.MissionCalls and Config.MissionCalls.rapidResponse
                        share = Num(rr and rr.pctOfP, share)
                    end
                    per = cfgB.kind == 'pct' and share * P or Num(cfgB.value, 0)
                end
                local each = cfgB.each == true
                local value = each and per * count or per
                total = total + AddLine(bonuses, penalties, id, value, count, each, kinds[id] == 'penalty')
            elseif count > 0 and c then
                if id ~= 'lights_siren' or mission.quietPatrol == true or run.quietPatrol == true then
                    local per = Num(common[c.key], 0)
                    local value = c.each and per * count or per
                    total = total + AddLine(bonuses, penalties, id, value, count, c.each, per < 0)
                end
            elseif count > 0 and custom and Config.Bonuses and Config.Bonuses[id] ~= nil then
                -- a standard id the custom mission did not pick: its bonuses come only from its own list
                WarnOnce('unlisted:' .. id,
                    'bonus/penalty %s was recorded on a custom mission that does not list it; ignored', id)
            elseif count > 0 and HintValue(hints, id, custom, P) then
                local per = HintValue(hints, id, custom, P)
                total = total + AddLine(bonuses, penalties, id, per * count, count, true, kinds[id] == 'penalty')
            elseif count > 0 then
                WarnOnce('unvalued:' .. id,
                    'bonus/penalty %s was recorded but has no value (not on the mission card, not in Config.Scoring.common, no points hint); ignored',
                    id)
            end
        end
    end

    -- 3. common end-evaluated bonuses and penalties
    local duration = DurationOf(run, opts)
    -- Process the scene stops the fast-completion clock (CP.Runs.pauseFastClock)
    if opts.fastDurationS ~= nil then duration = math.min(duration, Num(opts.fastDurationS, duration)) end
    local limit = Num(run.timeLimit, Num(mission.timeLimit, 0))
    local fastShare = Num(common.fastShare, 0.75)
    if not (run.flags and run.flags.medals) and limit > 0 and duration <= fastShare * limit then
        total = total
            + AddLine(bonuses, penalties, 'fast_finish', Num(common.fastBonus, 0) * P, 1, false, false,
                { pct = math.floor(fastShare * 100 + 0.5) })
    end
    if run.modifier then
        local modLabel = CP.L('modifier.' .. tostring(run.modifier))
        total = total
            + AddLine(bonuses, penalties, 'modifier', Num(Config.Events and Config.Events.modifierPoints, 0) * P, 1,
                false, false, { modifier = modLabel })
    end
    if p.firstRunSinceDuty == true then
        total = total + AddLine(bonuses, penalties, 'first_run', Num(common.firstRun, 0), 1, false, false)
    end
    local v = p.vehicle
    if type(v) == 'table' and v.seen then
        local engine, body = Num(v.engine, 1000), Num(v.body, 1000)
        local above = Num(common.noDamageAbove, 950)
        if engine > above and body > above then
            total = total + AddLine(bonuses, penalties, 'no_vehicle_damage', Num(common.noDamage, 0), 1, false, false)
        end
        if mission.vehiclePenalties ~= false and body < Num(common.heavyDamageBelow, 500) then
            total = total + AddLine(bonuses, penalties, 'heavy_damage', Num(common.heavyDamage, 0), 1, false, true)
        end
    end
    return bonuses, penalties, total
end

local function EmptyBreakdown(P)
    return {
        P = P,
        bonuses = {},
        penalties = {},
        subtotal = 0,
        mTeam = 1.0,
        mCross = 1.0,
        mStreak = 1.0,
        capped = false,
        tod = false,
        failedShare = nil,
        final = 0,
    }
end

function Scoring.compute(run, p, result, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(run) ~= 'table' or type(p) ~= 'table' then return EmptyBreakdown(0) end
    local P = Num(run.pointsBase, nil)
    if not P or P <= 0 then P = Scoring.P(run.mission) end
    local out = EmptyBreakdown(P)

    if result == 'failed' then
        local share = ObjectiveShare(run, opts)
        local credit = Num(ScoringCfg().failedCredit, 0.25) * P * share
        out.failedShare = share
        out.subtotal = math.floor(credit * 100 + 0.5) / 100
        out.final = PresenceFailed(run, p) and 0 or math.max(0, math.floor(credit + 1e-9))
        return out
    end
    if result ~= 'completed' then return out end

    local bonuses, penalties, total = ScoreLines(run, p, P, opts)
    local subtotal = P + total
    local mTeam = Num(TierRow(run).points, 1.0)
    local nDepts = Num(opts.departments, nil) or DepartmentsOf(run, p)
    local mCross = nDepts >= 2 and Num(Config.CrossDepartmentPoints, 1.10) or 1.0

    local streakDays = 0
    if p.citizenid then
        Db()
        local row = ReadOfficer(p.citizenid)
        local st = Advance(StreakState(row), DayKey(Now()))
        streakDays = st.days
    end
    local mStreak = StreakMultiplier(streakDays)

    local raw = subtotal * mTeam * mCross * mStreak
    local scoreCap = Num(ScoringCfg().scoreCap, 2.0)
    local cap = scoreCap * P
    local capped = raw > cap + 1e-9
    local value = math.max(0, math.min(cap, raw))
    local final = math.floor(value + 1e-9)
    local tod = false
    if CP.Events and CP.Events.typeOfTheDay then
        local okT, key = pcall(CP.Events.typeOfTheDay)
        tod = okT and key ~= nil and key == run.missionType
    end
    local todMultiplier = Num(Config.Events and Config.Events.todMultiplier, 2.0)
    if tod then final = math.floor(final * todMultiplier + 1e-9) end

    if PresenceFailed(run, p) then
        final, capped, tod = 0, false, false
    end
    if not run.test and p.citizenid then MarkFirstDone(p.citizenid) end

    out.bonuses, out.penalties = bonuses, penalties
    out.subtotal = subtotal
    out.mTeam, out.mCross, out.mStreak = mTeam, mCross, mStreak
    out.capped, out.tod = capped, tod
    -- extras for the result card and the Profile breakdown: the cap (whole points) and the multipliers used
    out.cap, out.scoreCap, out.todMultiplier = math.floor(cap + 1e-9), scoreCap, todMultiplier
    out.final = math.max(0, final)
    return out
end

-- ============================================================================
--                                XP AND LEVELS
-- ============================================================================

local function Levels()
    local list = {}
    for _, l in ipairs(Config.XPLevels or {}) do
        if type(l) == 'table' then list[#list + 1] = l end
    end
    table.sort(list, function(a, b)
        local la, lb = Num(a.level, nil), Num(b.level, nil)
        if la and lb and la ~= lb then return la < lb end
        return Num(a.xp, 0) < Num(b.xp, 0)
    end)
    return list
end

-- Level names are configuration (Config.XPLevels label, like mission type labels); the locale only
-- fills in a level that has no label.
local function LevelLabel(l)
    if type(l.label) == 'string' and l.label ~= '' then return l.label end
    return CP.L('scoring.level_unnamed', { xp = math.floor(Num(l.xp, 0)) })
end

local function Curve()
    local c = Config.XPCurve or {}
    local maxLevel = math.max(1, math.floor(Num(c.maxLevel, 50)))
    local first = math.max(1, Num(c.first, 100))
    local growth = Num(c.growth, 1.07)
    if growth <= 0 then growth = 1.0 end
    return maxLevel, first, growth, math.max(1, math.floor(Num(c.prestigeEvery, 10000)))
end

-- XP needed to reach level n (Config.XPCurve): round(first × (growth^(n − 1) − 1) ÷ (growth − 1)).
function Scoring.levelXp(n)
    local maxLevel, first, growth = Curve()
    n = math.max(1, math.min(maxLevel, math.floor(Num(n, 1))))
    if n <= 1 then return 0 end
    if math.abs(growth - 1.0) < 1e-9 then return math.floor(first * (n - 1) + 0.5) end
    return math.floor(first * (growth ^ (n - 1) - 1) / (growth - 1) + 0.5)
end

function Scoring.levelOf(xp)
    xp = math.max(0, math.floor(Num(xp, 0)))
    local maxLevel = Curve()
    local n = 1
    while n < maxLevel and Scoring.levelXp(n + 1) <= xp do n = n + 1 end
    return n
end

-- The Config.XPLevels band a level falls in: the last entry whose level is at or below n (entries without a
-- level keep their old xp threshold, compared with the level's XP).
local function BandOf(n, levelXp)
    local list = Levels()
    local cur = list[1]
    for _, l in ipairs(list) do
        local at = Num(l.level, nil)
        if (at and at <= n) or (not at and Num(l.xp, 0) <= levelXp) then cur = l end
    end
    return cur
end

-- LevelInfo (web/src/shared/types.ts): n from Config.XPCurve, label and badge from the band of n, xp and
-- levelXp = the XP at which level n starts, nextLevelXp = the next level (or prestige star), next = the same
-- (kept for old callers), prestige = stars after the last level.
function Scoring.xpLevel(xp)
    xp = math.max(0, math.floor(Num(xp, 0)))
    local maxLevel, _, _, prestigeEvery = Curve()
    local n = Scoring.levelOf(xp)
    local levelXp = Scoring.levelXp(n)
    local prestige = 0
    local nextXp
    if n >= maxLevel then
        prestige = math.floor((xp - levelXp) / prestigeEvery)
        nextXp = levelXp + (prestige + 1) * prestigeEvery
    else
        nextXp = Scoring.levelXp(n + 1)
    end
    local band = BandOf(n, levelXp)
    return {
        n = n,
        label = band and LevelLabel(band) or '',
        badge = band and tostring(band.badge or 'grey') or 'grey',
        xp = levelXp,
        levelXp = levelXp,
        nextLevelXp = nextXp,
        prestige = prestige,
        next = nextXp,
        bandStart = band ~= nil and Num(band.level, -1) == n,
    }
end

-- The level-up toast text: "Lv 24", or "Lv 25 · Senior Patrol" when a band starts at that level.
local function LevelText(info)
    if info.bandStart and info.label ~= '' then
        return CP.L('scoring.level_band', { n = info.n, label = info.label })
    end
    return CP.L('scoring.level_n', { n = info.n })
end

local function XpOf(citizenid)
    local row = ReadOfficer(citizenid)
    return row and math.max(0, math.floor(CP.U.num(row.xp))) or 0
end

-- XP is max(0, the signed sum of the counted rows): completed or failed, not voided, not flagged, live and archived.
local DERIVED_XP_SQL = [[SELECT COALESCE(SUM(final_points), 0) AS pts, COUNT(*) AS n FROM %s
    WHERE citizenid = ? AND voided = 0 AND flagged = 0 AND state IN ('completed', 'failed')]]

-- derived XP, the number of counted rows, the signed sum | nil when the rows can't be read.
function Scoring.derivedXp(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    Db()
    local sum, n = 0, 0
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local ok, row = pcall(MySQL.single.await, DERIVED_XP_SQL:format(tbl), { citizenid })
        if not ok then
            CP.err(TAG, 'derived XP of %s failed: %s', citizenid, tostring(row))
            return nil
        end
        sum = sum + math.floor(CP.U.num(row and row.pts))
        n = n + math.floor(CP.U.num(row and row.n))
    end
    return math.max(0, sum), n, sum
end

-- Writes the derived XP: old, new | nil when it could not be read or written. No level-up toast.
function Scoring.syncXp(citizenid)
    local derived = Scoring.derivedXp(citizenid)
    if not derived then return nil end
    local old = XpOf(citizenid)
    if old == derived then return old, derived end
    local ok, err = pcall(MySQL.update.await, [[
        INSERT INTO cp_officers (citizenid, xp) VALUES (?, ?) ON DUPLICATE KEY UPDATE xp = VALUES(xp)
    ]], { citizenid, derived })
    if not ok then
        CP.err(TAG, 'XP sync for %s failed: %s', citizenid, tostring(err))
        return nil
    end
    CP.log(TAG, 'XP %s synced %d -> %d', citizenid, old, derived)
    return old, derived
end

-- A counted negative row (a points adjustment) of the officer, live or archived.
local SIGNED_SQL = [[SELECT 1 AS found FROM %s WHERE citizenid = ? AND final_points < 0 AND voided = 0
    AND flagged = 0 AND state IN ('completed', 'failed') LIMIT 1]]

local function HasSignedRows(citizenid)
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local ok, v = pcall(MySQL.scalar.await, SIGNED_SQL:format(tbl), { citizenid })
        if not ok or v ~= nil then return true end
    end
    return false
end

-- signed: the row behind the change carries negative points. XP = max(0, signed sum): a step up from 0 is exact
-- only when no deduction is counted, so then XP is read from the rows instead.
local function AddXp(citizenid, delta, signed)
    delta = math.floor(Num(delta, 0))
    if delta == 0 then return end
    local oldXp = XpOf(citizenid)
    if delta > 0 and oldXp == 0 and (signed or HasSignedRows(citizenid)) then
        local _, newXp = Scoring.syncXp(citizenid)
        local oldLevel, newLevel = Scoring.levelOf(0), Scoring.levelOf(newXp or 0)
        if newLevel > oldLevel then
            local info = Scoring.xpLevel(newXp)
            Notify(citizenid, 'success', 'scoring.level_up', { level = LevelText(info), n = info.n })
            local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(citizenid) or nil
            if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('xp:levelUp', citizenid, src, oldLevel, newLevel) end
        end
        return
    end
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_officers (citizenid, xp) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE xp = GREATEST(0, xp + ?)
    ]], { citizenid, math.max(0, delta), delta })
    if not ok then
        CP.err(TAG, 'XP update for %s failed: %s', citizenid, tostring(err))
        return
    end
    local newXp = math.max(0, oldXp + delta)
    local oldLevel, newLevel = Scoring.levelOf(oldXp), Scoring.levelOf(newXp)
    if delta > 0 and newLevel > oldLevel then
        -- the one level-up toast (and hook): once per level-up, naming the level reached
        local info = Scoring.xpLevel(newXp)
        Notify(citizenid, 'success', 'scoring.level_up', { level = LevelText(info), n = info.n })
        local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(citizenid) or nil
        if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('xp:levelUp', citizenid, src, oldLevel, newLevel) end
    end
    CP.log(TAG, 'XP %s %+d -> %d', citizenid, delta, newXp)
end

-- Marks a row's points as added to XP; true only for the call that set the marker.
local function ClaimXp(rowId)
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs SET breakdown = JSON_SET(COALESCE(breakdown, '{}'), '$.xpCounted', 1)
        WHERE id = ? AND (breakdown IS NULL OR JSON_EXTRACT(breakdown, '$.xpCounted') IS NULL)
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'XP marker for row %s failed: %s', tostring(rowId), tostring(n))
        return false
    end
    return (tonumber(n) or 0) > 0
end

local function ReleaseXp(rowId)
    local ok, n = pcall(MySQL.update.await, [[
        UPDATE cp_mission_runs SET breakdown = JSON_REMOVE(breakdown, '$.xpCounted')
        WHERE id = ? AND JSON_EXTRACT(breakdown, '$.xpCounted') IS NOT NULL
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'XP marker removal for row %s failed: %s', tostring(rowId), tostring(n))
        return false
    end
    return (tonumber(n) or 0) > 0
end

-- ============================================================================
--                                    BADGES
-- ============================================================================

local BADGE_SELECT = [[
    SELECT mission_type, mission_id, participants, departments_n, decisions_best,
           COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"no_vehicle_damage"'), 0) AS no_damage,
           COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"no_participant_downed"'), 0) AS no_downs,
           COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"rapid_response"'), 0) AS rapid
    FROM %s
    WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0
      AND mission_type NOT IN ('manual_award', 'goal')
]]

local function BadgeCounts(citizenid)
    local sql = ([[
        SELECT COALESCE(SUM(t.no_damage > 0), 0) AS iron_wheels,
               COALESCE(SUM(t.mission_id = 'gang_shootout' AND t.no_downs > 0), 0) AS sharpshooter,
               COALESCE(SUM(t.mission_type = 'patrol'), 0) AS road_warrior,
               COALESCE(SUM(t.participants >= 2), 0) AS partner_in_crime,
               COALESCE(SUM(t.departments_n >= 2), 0) AS joint_task_force,
               COALESCE(SUM(t.decisions_best), 0) AS by_the_book,
               COALESCE(SUM(t.rapid > 0), 0) AS first_responder
        FROM (%s UNION ALL %s) t
    ]]):format(BADGE_SELECT:format('cp_mission_runs'), BADGE_SELECT:format('cp_mission_runs_archive'))
    local ok, row = pcall(MySQL.single.await, sql, { citizenid, citizenid })
    if not ok or type(row) ~= 'table' then
        CP.err(TAG, 'badge counts for %s failed: %s', citizenid, tostring(row))
        return nil
    end
    local out = {}
    for _, b in ipairs(BADGES) do out[b.id] = math.floor(CP.U.num(row[b.id])) end
    return out
end

local function OwnedBadges(citizenid)
    local ok, rows = pcall(MySQL.query.await, 'SELECT badge_id FROM cp_badges WHERE citizenid = ?', { citizenid })
    local set = {}
    if not ok then
        CP.err(TAG, 'badge lookup for %s failed: %s', citizenid, tostring(rows))
        return nil
    end
    for _, r in ipairs(rows or {}) do set[r.badge_id] = true end
    return set
end

-- An admin's grants and blocks (cp_badge_overrides): badge_id -> 'grant' | 'block'.
local function Overrides(citizenid)
    local ok, rows = pcall(MySQL.query.await, 'SELECT badge_id, mode FROM cp_badge_overrides WHERE citizenid = ?',
        { citizenid })
    local out = {}
    if not ok then return out end
    for _, r in ipairs(rows or {}) do out[r.badge_id] = r.mode end
    return out
end

-- Award missing achievement badges and (revoke = true, after a void) remove ones whose count fell short. A badge
-- an admin granted is never removed and one an admin blocked is never given. Returns the ids added and removed.
local function CheckBadges(citizenid, revoke)
    local added, removed = {}, {}
    local counts = BadgeCounts(citizenid)
    local owned = OwnedBadges(citizenid)
    if not counts or not owned then return added, removed end
    local overrides = Overrides(citizenid)
    for _, b in ipairs(BADGES) do
        local need = math.floor(Num(Config.Badges and Config.Badges[b.cfg], 0))
        if need > 0 then
            if counts[b.id] >= need and not owned[b.id] and overrides[b.id] ~= 'block' then
                local ok, n = pcall(MySQL.update.await,
                    'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
                    { citizenid, b.id, Now() })
                if ok and (tonumber(n) or 0) > 0 then
                    added[#added + 1] = b.id
                    CP.log(TAG, '%s earned the %s badge', citizenid, b.id)
                    Notify(citizenid, 'success', 'scoring.badge_earned', { badge = CP.L('badge.' .. b.id) })
                elseif not ok then
                    CP.err(TAG, 'awarding %s to %s failed: %s', b.id, citizenid, tostring(n))
                end
            elseif revoke and owned[b.id] and counts[b.id] < need and overrides[b.id] ~= 'grant' then
                local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_badges WHERE citizenid = ? AND badge_id = ?',
                    { citizenid, b.id })
                if ok then
                    removed[#removed + 1] = b.id
                    CP.log(TAG, '%s lost the %s badge after a void', citizenid, b.id)
                else
                    CP.err(TAG, 'revoking %s from %s failed: %s', b.id, citizenid, tostring(err))
                end
            end
        end
    end
    return added, removed
end

-- Every achievement badge is checked against the rows again: added, removed.
function Scoring.recheckBadges(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return {}, {} end
    Db()
    return CheckBadges(citizenid, true)
end

-- The badges an admin may grant or revoke: the achievements (ids and labels) and the recognition id shapes.
function Scoring.badgeCatalog()
    local out = {
        achievements = {},
        recognition = { 'officer_of_week', 'top_metric', 'season_champion', 'season_top10' },
    }
    for _, b in ipairs(BADGES) do
        out.achievements[#out.achievements + 1] = {
            id = b.id,
            label = CP.L('badge.' .. b.id),
            need = math.floor(Num(Config.Badges and Config.Badges[b.cfg], 0)),
        }
    end
    return out
end

-- Whether id is a badge an admin may grant or revoke: an achievement, or a recognition badge of a closed week or of
-- a season that exists. Returns true, kind | false, errKey.
function Scoring.validBadgeId(id)
    if type(id) ~= 'string' or id == '' or #id > 40 then return false, 'err.badge_unknown' end
    for _, b in ipairs(BADGES) do
        if b.id == id then return true, 'achievement' end
    end
    local week = id:match('^officer_of_week_(%d%d%d%d%-%d%d%-%d%d)$')
    local metric, mweek = id:match('^top_(%a+)_(%d%d%d%d%-%d%d%-%d%d)$')
    week = week or mweek
    if week then
        if metric and not (CP.Leaderboard and CP.Leaderboard.isMetric and CP.Leaderboard.isMetric(metric)) then
            return false, 'err.badge_unknown'
        end
        local closed = CP.Leaderboard and CP.Leaderboard.isClosedWeek and CP.Leaderboard.isClosedWeek(week)
        if not closed then return false, 'err.badge_week_open' end
        return true, 'week'
    end
    local sid = id:match('^season_(%d+)_champion$') or id:match('^season_(%d+)_top10$')
    if sid then
        local season = CP.Challenge and CP.Challenge.seasonById and CP.Challenge.seasonById(tonumber(sid)) or nil
        if not season then return false, 'err.badge_season' end
        return true, 'season'
    end
    return false, 'err.badge_unknown'
end

-- The five achievement badges are labelled here (badge.<id>); the leaderboard's own badge ids (Officer of the
-- Week, season champion / top 10, e.g. officer_of_week_2026-09-21) carry dates and season names, so their
-- labels come from CP.Leaderboard.badgeLabel.
local function BadgeLabel(id)
    local key = 'badge.' .. id
    if CP.Locale and CP.Locale.has and CP.Locale.has(key) then return CP.L(key) end
    if CP.Leaderboard and CP.Leaderboard.badgeLabel then
        local ok, label = pcall(CP.Leaderboard.badgeLabel, id)
        if ok and type(label) == 'string' and label ~= '' then return label end
    end
    return CP.L(key)
end

function Scoring.badges(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end
    Db()
    local ok, rows = pcall(MySQL.query.await, [[
        SELECT badge_id, DATE_FORMAT(earned_at, '%Y-%m-%d %H:%i:%s') AS earned_at, UNIX_TIMESTAMP(earned_at) AS earned_ts
        FROM cp_badges WHERE citizenid = ? ORDER BY earned_at, badge_id
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'badge list for %s failed: %s', citizenid, tostring(rows))
        return {}
    end
    local out = {}
    for _, r in ipairs(rows or {}) do
        out[#out + 1] = {
            id = r.badge_id,
            label = BadgeLabel(tostring(r.badge_id)),
            earnedAt = r.earned_at,
            earnedTs = tonumber(r.earned_ts),
        }
    end
    return out
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

local function ReadRun(rowId)
    local ok, row = pcall(MySQL.single.await, [[
        SELECT id, citizenid, mission_type, mission_id, state, final_points, flagged, voided,
               UNIX_TIMESTAMP(created_at) AS created_ts
        FROM cp_mission_runs WHERE id = ?
    ]], { rowId })
    if not ok then
        CP.err(TAG, 'reading row %s failed: %s', tostring(rowId), tostring(row))
        return nil
    end
    if type(row) ~= 'table' or row.id == nil then return nil end
    return row
end

function Scoring.onRowCounted(citizenid, row)
    if type(citizenid) ~= 'string' or citizenid == '' or type(row) ~= 'table' then return end
    Db()
    local state = row.state
    if state ~= 'completed' and state ~= 'failed' then return end
    -- signed: a points adjustment takes XP down (never below 0)
    local pts = math.floor(Num(row.final_points, 0))
    local rowId = tonumber(row.id)
    local counted = true
    if rowId then counted = ClaimXp(rowId) end
    if counted and pts ~= 0 then AddXp(citizenid, pts, pts < 0) end
    if NOT_RUNS[row.mission_type] or state ~= 'completed' then return end
    MarkFirstDone(citizenid)
    ApplyStreakDay(citizenid, DayKey(Now()))
    CheckBadges(citizenid, false)
end

function Scoring.onRowApproved(rowId)
    rowId = tonumber(rowId)
    if not rowId then return end
    Db()
    local row = ReadRun(rowId)
    if not row then return end
    if CP.U.truthy(row.flagged) or CP.U.truthy(row.voided) then
        CP.warn(TAG, 'onRowApproved(%d): the row is still flagged or voided; nothing counted', rowId)
        return
    end
    if row.state ~= 'completed' and row.state ~= 'failed' then return end
    local pts = math.floor(CP.U.num(row.final_points))
    if ClaimXp(rowId) and pts ~= 0 then AddXp(row.citizenid, pts, pts < 0) end
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('row:approved', rowId) end
    if NOT_RUNS[row.mission_type] or row.state ~= 'completed' then return end
    ApplyStreakDay(row.citizenid, DayKey(tonumber(row.created_ts) or Now()))
    CheckBadges(row.citizenid, false)
    if CP.Goals and CP.Goals.onRunCompleted then CP.Goals.onRunCompleted(row.citizenid) end
end

function Scoring.onRowVoided(rowId)
    rowId = tonumber(rowId)
    if not rowId then return end
    Db()
    local row = ReadRun(rowId)
    if not row then return end
    local pts = math.floor(CP.U.num(row.final_points))
    if ReleaseXp(rowId) and pts ~= 0 then AddXp(row.citizenid, -pts, pts < 0) end
    if not NOT_RUNS[row.mission_type] then CheckBadges(row.citizenid, true) end
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('row:voided', rowId) end
end

-- A row an admin flagged for review: its XP is held until it is approved (or voided).
function Scoring.onRowFlagged(rowId)
    rowId = tonumber(rowId)
    if not rowId then return end
    Db()
    local row = ReadRun(rowId)
    if not row then return end
    local pts = math.floor(CP.U.num(row.final_points))
    if ReleaseXp(rowId) and pts ~= 0 then AddXp(row.citizenid, -pts, pts < 0) end
end

-- ============================================================================
--                            RESULT SCREEN PROGRESS
-- ============================================================================
-- RunResult.progress (web/src/types/run_ui.ts): the XP before and after this row, the level, a level-up and
-- the goals. A flagged row's XP is added only when a supervisor approves it (pending).

function Scoring.progressFor(citizenid, gained, pending)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    Db()
    gained = math.max(0, math.floor(Num(gained, 0)))
    local now = XpOf(citizenid)
    local before, after = now, now
    if pending then after = now + gained else before = math.max(0, now - gained) end
    local goals = { daily = nil, weekly = nil }
    if CP.Goals and CP.Goals.forOfficer then
        local ok, g = pcall(CP.Goals.forOfficer, citizenid)
        if ok and type(g) == 'table' then goals = { daily = g.daily, weekly = g.weekly } end
    end
    local lv = Scoring.xpLevel(after)
    local level = {
        n = lv.n,
        label = lv.label,
        badge = lv.badge,
        xp = after,
        levelXp = lv.levelXp,
        nextLevelXp = lv.nextLevelXp,
        prestige = lv.prestige,
    }
    return {
        xpBefore = before,
        xpAfter = after,
        pending = pending == true,
        level = level,
        -- pending XP reaches no level until it is approved (the toast comes then)
        levelUp = pending ~= true and Scoring.levelOf(after) > Scoring.levelOf(before),
        goals = goals,
    }
end

local function OnRowSettled(run, p, rowId, row, result)
    if type(result) ~= 'table' or type(p) ~= 'table' or type(row) ~= 'table' then return end
    if row.state ~= 'completed' and row.state ~= 'failed' then return end
    local pending = CP.U.truthy(row.flagged)
    result.progress = Scoring.progressFor(p.citizenid, row.final_points, pending)
end

-- ============================================================================
--                                MANUAL AWARDS
-- ============================================================================

local function CurrentSeasonId()
    if CP.Challenge and CP.Challenge.currentSeason then
        local ok, s = pcall(CP.Challenge.currentSeason)
        if ok and type(s) == 'table' and tonumber(s.id) then return math.floor(tonumber(s.id)) end
    end
    return 0
end

-- Who acted, as cp_audit and breakdown.by name them: the citizenid, 'console' or 'player:<src>'.
local function ActorId(actor)
    if not actor or actor == 0 then return 'console' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(actor)
    return info and info.citizenid or ('player:%d'):format(actor)
end

-- Inserts a manual_award or goal row (RunResult-shaped breakdown) and counts it. Returns rowId|nil.
function Scoring._insertBonusRow(citizenid, kind, missionId, points, labelText, extra)
    local officer = ReadOfficer(citizenid)
    local dept = officer and type(officer.department) == 'string' and officer.department ~= '' and officer.department
        or 'unknown'
    local runUuid = CP.U.uuid()
    local breakdown = {
        runId = runUuid,
        missionLabel = labelText,
        missionType = kind,
        result = 'completed',
        endReason = 'completed',
        test = false,
        tier = 'standard',
        payTier = 'standard',
        participants = 1,
        departments = 1,
        durationS = 0,
        points = {
            P = points,
            bonuses = {},
            penalties = {},
            subtotal = points,
            mTeam = 1.0,
            mCross = 1.0,
            mStreak = 1.0,
            capped = false,
            tod = false,
            final = points,
        },
        cash = { B = 0, mTier = 1.0, mMod = 1.0, amount = 0, status = 'none' },
        kind = kind,
    }
    for k, v in pairs(extra or {}) do breakdown[k] = v end
    local okJ, js = pcall(json.encode, CP.U.serialize(breakdown))
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
        VALUES (?, ?, ?, ?, ?, NULLIF(?, 0), 1, 1, 'standard', 'completed', 'completed', ?, 0, 0, ?, 0, 1.00, 0, 'none', 0, ?, 0, 0,
            FROM_UNIXTIME(?))
    ]], {
        runUuid,
        kind,
        CP.U.clip(missionId, 40),
        citizenid,
        CP.U.clip(dept, 32),
        CurrentSeasonId(),
        points,
        points,
        okJ and js or '{}',
        Now(),
    })
    if not ok or not tonumber(id) then
        CP.err(TAG, 'inserting the %s row for %s failed: %s', kind, citizenid, tostring(id))
        return nil
    end
    id = math.floor(tonumber(id))
    Scoring.onRowCounted(citizenid, { id = id, state = 'completed', mission_type = kind, final_points = points })
    if CP.Leaderboard and CP.Leaderboard.invalidate then pcall(CP.Leaderboard.invalidate) end
    return id
end

function Scoring.manualAward(actorSrc, citizenid, points, reason)
    local actor = ToSrc(actorSrc)
    if not actor then return false, 'err.no_permission' end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local okP, errKey = CP.Permissions.can(actor, 'manualAward')
    if not okP then return false, errKey or 'err.no_permission' end
    if type(citizenid) ~= 'string' then return false, 'err.invalid_citizenid' end
    citizenid = CP.U.trim(citizenid)
    if citizenid == '' or #citizenid > 50 or not citizenid:match('^[%w_%-]+$') then
        return false, 'err.invalid_citizenid'
    end
    local n = tonumber(points)
    if not n or n ~= n or n ~= math.floor(n) or n < 1 or n > MANUAL_MAX then return false, 'err.invalid_points' end
    n = math.floor(n)
    if type(reason) ~= 'string' then return false, 'err.reason_required' end
    local r = CP.U.trim(reason)
    if r == '' then return false, 'err.reason_required' end
    -- Characters, not bytes: modules/admin clips reasons to 255 characters, and an accented reason is longer in bytes.
    local rLen = utf8.len(r)
    if not rLen then return false, 'err.invalid_payload' end
    if rLen > REASON_MAX then return false, 'err.reason_too_long' end
    Db()
    local officer, okRead = ReadOfficer(citizenid)
    if not okRead then return false, 'err.internal' end
    if not officer then return false, 'err.unknown_officer' end
    -- never to one of the admin's own characters (by license; the console may)
    if actor ~= 0 and CP.AdminKit and CP.AdminKit.isSelf and CP.AdminKit.isSelf(actor, citizenid) then
        return false, 'err.self_target'
    end

    local rowId = Scoring._insertBonusRow(citizenid, 'manual_award', 'manual_award', n,
        CP.L('scoring.manual_award_label'), { reason = r, by = ActorId(actor) })
    if not rowId then return false, 'err.internal' end
    local role = actor == 0 and 'console' or 'admin'
    if CP.Admin and CP.Admin.audit then
        local ok, err = pcall(CP.Admin.audit, actor, role, 'audit', 'manualAward', citizenid, nil, tostring(n), r)
        if not ok then CP.err(TAG, 'CP.Admin.audit failed: %s', tostring(err)) end
    else
        local actorId = 'console'
        if actor ~= 0 then
            local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(actor)
            actorId = info and info.citizenid or ('player:%d'):format(actor)
        end
        pcall(MySQL.insert.await,
            'INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason) VALUES (?, ?, \'audit\', \'manualAward\', ?, NULL, ?, ?)',
            { CP.U.clip(actorId, 50), role, citizenid, tostring(n), r })
    end
    Notify(citizenid, 'success', 'scoring.manual_award', { points = n, reason = r })
    CP.log(TAG, 'manual award %d to %s by %s: %s', n, citizenid, tostring(actor), r)
    return true, rowId
end

-- A signed manual adjustment, checked by the caller (CP.Corrections): positive points are a manual award row,
-- negative ones a 'manual_adjust' row. Both store who (breakdown.by) and why. Returns the row id | nil.
function Scoring.adjust(actorSrc, citizenid, points, reason)
    local n = math.tointeger(tonumber(points))
    if not n or n == 0 or n < -MANUAL_MAX or n > MANUAL_MAX then return nil, 'err.invalid_points' end
    if type(citizenid) ~= 'string' or citizenid == '' then return nil, 'err.invalid_citizenid' end
    Db()
    local actor = ToSrc(actorSrc) or 0
    local missionId = n > 0 and 'manual_award' or 'manual_adjust'
    local label = n > 0 and CP.L('scoring.manual_award_label') or CP.L('scoring.adjust_label')
    local rowId = Scoring._insertBonusRow(citizenid, 'manual_award', missionId, n, label,
        { reason = reason, by = ActorId(actor) })
    if not rowId then return nil, 'err.internal' end
    if n > 0 then
        Notify(citizenid, 'success', 'scoring.manual_award', { points = n, reason = reason })
    else
        Notify(citizenid, 'warning', 'scoring.points_adjusted', { points = n, reason = reason })
    end
    return rowId
end

-- ============================================================================
--                                 HOME SCREEN
-- ============================================================================

local function SeasonPoints(citizenid)
    if CP.Leaderboard and CP.Leaderboard.seasonPoints then
        local ok, v = pcall(CP.Leaderboard.seasonPoints, citizenid)
        if ok and tonumber(v) then return math.floor(tonumber(v)) end
    end
    local seasonId = CurrentSeasonId()
    if seasonId <= 0 then return 0 end
    local ok, v = pcall(MySQL.scalar.await, [[
        SELECT COALESCE(SUM(final_points), 0) AS pts FROM cp_mission_runs
        WHERE citizenid = ? AND season_id = ? AND voided = 0 AND flagged = 0
    ]], { citizenid, seasonId })
    if not ok then
        CP.err(TAG, 'season points for %s failed: %s', citizenid, tostring(v))
        return 0
    end
    return math.floor(CP.U.num(v))
end

local function AnnouncementsList(dept)
    local out = {}
    if CP.Leaderboard and CP.Leaderboard.announcements then
        local ok, list = pcall(CP.Leaderboard.announcements, dept)
        if ok and type(list) == 'table' then
            for _, a in ipairs(list) do
                if type(a) == 'table' and type(a.text) == 'string' then
                    out[#out + 1] = { kind = tostring(a.kind or 'info'), text = a.text }
                end
            end
        end
    end
    return out
end

local function ChampionsBanner(dept)
    if CP.Challenge and CP.Challenge.championBanner then
        local ok, b = pcall(CP.Challenge.championBanner, dept)
        if ok and type(b) == 'table' and b.season and b.department then
            return { season = tostring(b.season), department = tostring(b.department) }
        end
    end
    return nil
end

local function TypeOfTheDayCard()
    if not (CP.Events and CP.Events.typeOfTheDay) then return nil end
    local ok, key = pcall(CP.Events.typeOfTheDay)
    if not ok or type(key) ~= 'string' then return nil end
    local t = Config.MissionTypes and Config.MissionTypes[key]
    if not t then return nil end
    -- key/label are the contract (§9.4); multiplier and cap (Config values) are extras for the Home text.
    return {
        key = key,
        label = t.label or key,
        multiplier = Num(Config.Events and Config.Events.todMultiplier, 2.0),
        cap = Num(ScoringCfg().scoreCap, 2.0),
    }
end

local function HomeData(officer)
    local cid = officer.citizenid
    Db()
    local row = ReadOfficer(cid)
    local xp = row and math.max(0, math.floor(CP.U.num(row.xp))) or 0
    local st = Scoring.streak(cid)
    local goals = { daily = nil, weekly = nil }
    if CP.Goals and CP.Goals.forOfficer then
        local ok, g = pcall(CP.Goals.forOfficer, cid)
        if ok and type(g) == 'table' then goals = { daily = g.daily, weekly = g.weekly } end
    end
    local maxDay = math.floor(Num(Config.Limits and Config.Limits.maxCompletionsDay, 0))
    local missionsToday = nil
    if maxDay > 0 and CP.Runs and CP.Runs.completionsToday then
        local ok, n = pcall(CP.Runs.completionsToday, cid)
        missionsToday = { n = ok and tonumber(n) or 0, max = maxDay }
    end
    local extras = {}
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('home:extras', cid, officer.src, extras) end
    return {
        missionsToday = missionsToday,
        extras = extras,
        card = {
            callsign = officer.callsign,
            rank = officer.rank or '',
            departmentShort = officer.departmentShort or '',
            name = officer.name or cid,
            xp = xp,
            level = Scoring.xpLevel(xp),
            -- graceDays (Config.Scoring.streakGraceDays) is an extra: 0 = no grace, so the UI says nothing about it.
            streak = { days = st.days, graceLeft = st.graceLeft, graceDays = GraceDays() },
            seasonPoints = SeasonPoints(cid),
            cashThisWeek = CP.Cash and CP.Cash.earnedThisWeek and CP.Cash.earnedThisWeek(cid) or 0,
        },
        goals = goals,
        typeOfTheDay = TypeOfTheDayCard(),
        announcements = AnnouncementsList(officer.department),
        champions = ChampionsBanner(officer.department),
    }
end

CP.Net.callback('getHome', function(src)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey or 'err.not_police' end
    return HomeData(officer)
end)

-- ============================================================================
--                                    WIRING
-- ============================================================================

if CP.Hooks and CP.Hooks.on then CP.Hooks.on('row:settled', OnRowSettled) end

CreateThread(function()
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: the first-run bonus cannot follow duty changes')
        return
    end
    CP.Qbx.onDutyChange(function(src) DutyEvaluate(src, false) end)
    CP.Qbx.onJobChange(function(src) DutyEvaluate(src, false) end)
    CP.Qbx.onPlayerLoaded(function(src) DutyEvaluate(src, true) end)
    CP.Qbx.onPlayerUnload(function(src) DutyEnded(src) end)
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then DutyEnded(src) end
end)

-- Test hooks (not part of the contract).
Scoring._advance = Advance
Scoring._currentStreak = CurrentStreak
Scoring._graceLeft = GraceLeftFor
Scoring._dutyEvaluate = DutyEvaluate
Scoring._dutyEnded = DutyEnded
Scoring._checkBadges = CheckBadges
Scoring._homeData = HomeData
Scoring._duty = duty
