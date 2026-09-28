-- modules/scoring/server.lua · CP.Scoring (server): points, streaks, XP, XP levels, badges, manual awards
-- and the officer Home screen.
--
-- Owns
--   * P and the points formula of a run row (SPEC "Scoring, points & XP levels"):
--       Points = max(0, min(scoreCap x P, (P + Bonuses - Penalties) x M_team x M_cross x M_streak)), rounded
--       down, then x Config.Events.todMultiplier when the run's mission type is the Type of the Day (after the
--       cap). Failed = floor(failedCredit x P x objectives done / total) (no bonuses, multipliers or ToD);
--       Abandoned = 0; a participant under the presence share (runs with 2+ participants) gets 0.
--     Bonus/penalty lines: the mission card's entries (shared counts in run.score.shared plus personal ones in
--     p.score; value = the entry's points / pctOfPoints, else Config.Bonuses; each = x count), ids recorded
--     with a per-occurrence value (run.score.values), the end-evaluated no_participant_downed /
--     no_weapons_fired (when the card lists them) and the common ones of Config.Scoring.common: fast_finish
--     (not when run.flags.medals), modifier (Config.Events.modifierPoints), first_run, no_vehicle_damage,
--     heavy_damage (not when mission.vehiclePenalties == false), pedestrian_hit, lights_siren (Beat Patrol and
--     Business Check), shot_surrendered. Labels: CP.L('bonus.<id>') / CP.L('penalty.<id>').
--   * streaks (cp_officers.streak_days, last_complete, grace_week, grace_used): consecutive reset-adjusted
--     days with a completed run; up to Config.Scoring.streakGraceDays missed days per week (counted from the
--     weekly reset) are forgiven and add nothing; M_streak = 1 + min(streakMax, streakStep x days)
--   * XP (cp_officers.xp = lifetime points, never below 0) with an idempotency marker in the row's breakdown
--     ('$.xpCounted'), XP levels (Config.XPLevels, cosmetic), the five achievement badges (Config.Badges,
--     counted from cp_mission_runs + cp_mission_runs_archive, revoked when a void drops a count below its
--     threshold), manual_award rows, "first completed run since going on duty" (CP.Qbx duty/load events)
--   * callback getHome -> HomeData (ARCHITECTURE §9.4)
--
-- Public API (docs/ARCHITECTURE.md §5.18)
--   CP.Scoring.P(mission) -> number                     whole points (halves up)
--   CP.Scoring.compute(run, p, result, opts) -> RunResult.points (§9.6)
--       result 'completed'|'failed'|'abandoned'; opts (all optional) = { objectivesDone, objectivesTotal,
--       failedShare, durationS, participants, departments, endReason } as modules/runs passes them.
--   CP.Scoring.isFirstRunSinceDuty(src) -> boolean
--   CP.Scoring.streak(citizenid) -> { days, multiplier, graceLeft }
--   CP.Scoring.onRowCounted(citizenid, row)   (hook) row = the inserted cp_mission_runs columns + id
--   CP.Scoring.onRowApproved(rowId)            (hook) a flagged row was approved (flagged already 0)
--   CP.Scoring.onRowVoided(rowId)              (hook) a row was voided (XP taken back when it had counted)
--   CP.Scoring.manualAward(actorSrc, citizenid, points, reason) -> ok, errKey|rowId   (admin only, audited)
--   CP.Scoring.xpLevel(xp) -> { label, badge, xp, next }       xp = the level's threshold, next = the next one or nil
--   CP.Scoring.badges(citizenid) -> { { id, label, earnedAt, earnedTs } ... }   every badge in cp_badges
-- Net: callback 'getHome' -> HomeData (officers only; CP.Access.getOfficer error keys otherwise)
-- compute, streak, the hooks, manualAward and badges query the database: call them from a thread.

CP.Scoring = CP.Scoring or {}
local Scoring = CP.Scoring
local TAG = 'scoring'

local BOSS_ID = 'weekly_boss_kingpin'
local LIGHTS_MISSIONS = { beat_patrol = true, business_check = true }
local NOT_RUNS = { manual_award = true, goal = true }
local END_EVALUATED = { no_participant_downed = true, no_weapons_fired = true }
-- Personal ids recorded by the engine / CP.Npc whose values live in Config.Scoring.common.
local COMMON_RECORDED = {
    pedestrian_hit   = { key = 'pedestrianHit', each = true },
    lights_siren     = { key = 'lightsSiren', each = false },
    shot_surrendered = { key = 'shotSurrendered', each = true },
}
local BADGES = {
    { id = 'iron_wheels',      cfg = 'ironWheels' },
    { id = 'sharpshooter',     cfg = 'sharpshooter' },
    { id = 'road_warrior',     cfg = 'roadWarrior' },
    { id = 'partner_in_crime', cfg = 'partnerInCrime' },
    { id = 'joint_task_force', cfg = 'jointTaskForce' },
}
local MAX_WALK_DAYS = 400      -- missed days examined for grace before a streak counts as broken
local STREAK_STORE_MAX = 127   -- cp_officers.streak_days is a signed TINYINT
local MANUAL_MAX = 10000
local REASON_MAX = 255

local duty = {}        -- citizenid -> { onDuty = bool, firstDone = bool, since = ts }
local srcCid = {}      -- src -> citizenid (for unload/drop)
local warned = {}

-- ── helpers ─────────────────────────────────────────────────────────────────
local function num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function toSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n < 0 then return nil end
    return n
end

local function now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function resetHour()
    local h = math.floor(num(Config.Time and Config.Time.resetHour, 0))
    if h < 0 or h > 23 then h = 0 end
    return h
end

local function dayKey(ts)
    if CP.Schedule and CP.Schedule.dayKey then return CP.Schedule.dayKey(ts) end
    ts = ts or now()
    local t = os.date('*t', ts)
    if t.hour < resetHour() then ts = os.time({ year = t.year, month = t.month, day = t.day - 1, hour = 12 }) end
    return os.date('%Y-%m-%d', ts)
end

local function parseKey(key)
    if type(key) ~= 'string' then return nil end
    local y, m, d = key:match('^(%d%d%d%d)-(%d%d)-(%d%d)$')
    if not y then return nil end
    return tonumber(y), tonumber(m), tonumber(d)
end

-- A timestamp inside the reset-adjusted day 'key' (30 minutes after its reset).
local function keyTime(key)
    local y, m, d = parseKey(key)
    if not y then return nil end
    return os.time({ year = y, month = m, day = d, hour = resetHour(), min = 30, sec = 0 })
end

local function addDays(key, n)
    local y, m, d = parseKey(key)
    return os.date('%Y-%m-%d', os.time({ year = y, month = m, day = d + n, hour = 12, min = 0, sec = 0 }))
end

local function daysBetween(a, b)
    local ya, ma, da = parseKey(a)
    local yb, mb, db2 = parseKey(b)
    if not ya or not yb then return nil end
    local ta = os.time({ year = ya, month = ma, day = da, hour = 12 })
    local tb = os.time({ year = yb, month = mb, day = db2, hour = 12 })
    return math.floor((tb - ta) / 86400 + 0.5)
end

local function weekKeyOf(key)
    local ts = keyTime(key)
    if CP.Schedule and CP.Schedule.weekKey then return CP.Schedule.weekKey(ts) end
    local t = os.date('*t', ts)
    local back = (t.wday + 5) % 7   -- days since monday
    return os.date('%Y-%m-%d', os.time({ year = t.year, month = t.month, day = t.day - back, hour = 12 }))
end

local function scoringCfg() return Config.Scoring or {} end
local function commonCfg() return scoringCfg().common or {} end

local function tierRow(run)
    local t = run.payTier
    if type(t) == 'table' then return t end
    if CP.Scaling and CP.Scaling.tierByName then
        local row = CP.Scaling.tierByName(t or run.expectedTier)
        if row then return row end
    end
    return { tier = 'standard', points = 1.0, cash = 1.0 }
end

local function notify(citizenid, kind, key, vars)
    if not (CP.Tablet and CP.Tablet.notify and CP.Qbx and CP.Qbx.getByCitizenId) then return end
    local src = CP.Qbx.getByCitizenId(citizenid)
    if src then CP.Tablet.notify(src, kind, key, vars) end
end

-- ── P ───────────────────────────────────────────────────────────────────────
function Scoring.P(mission)
    if type(mission) ~= 'table' then return 0 end
    if mission.isBoss == true or mission.id == BOSS_ID then
        local b = Config.Events and Config.Events.weeklyBoss
        return math.max(0, CP.U.round(num(b and b.points, 0)))
    end
    local t = Config.MissionTypes and Config.MissionTypes[mission.type]
    local stars = Config.Difficulty and Config.Difficulty.pointsByStars
    local d = math.floor(num(mission.difficulty, 1))
    if d < 1 then d = 1 end
    if d > 3 then d = 3 end
    return math.max(0, CP.U.round(num(t and t.points, 0) * num(stars and stars[d], 1.0)))
end

-- ── streaks ─────────────────────────────────────────────────────────────────
local function graceDays()
    return math.max(0, math.floor(num(scoringCfg().streakGraceDays, 0)))
end

local function streakMultiplier(days)
    local cfg = scoringCfg()
    return 1 + math.min(num(cfg.streakMax, 0.25), num(cfg.streakStep, 0.05) * math.max(0, days))
end

local function readOfficer(citizenid)
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

local function streakState(row)
    if not row then return { days = 0, last = nil, graceWeek = nil, graceUsed = 0 } end
    return {
        days = math.max(0, math.floor(CP.U.num(row.streak_days))),
        last = parseKey(row.last_complete) and row.last_complete or nil,
        graceWeek = parseKey(row.grace_week) and row.grace_week or nil,
        graceUsed = math.max(0, math.floor(CP.U.num(row.grace_used))),
    }
end

-- Walk the missed days strictly between state.last and toKey. Returns alive, graceWeek, graceUsed.
local function walkGap(state, toKey)
    local gap = (daysBetween(state.last, toKey) or 0) - 1
    if gap <= 0 then return true, state.graceWeek, state.graceUsed end
    local allowed = graceDays()
    if allowed <= 0 or gap > MAX_WALK_DAYS then return false, state.graceWeek, state.graceUsed end
    local gw, gu = state.graceWeek, state.graceUsed
    for i = 1, gap do
        local wk = weekKeyOf(addDays(state.last, i))
        if wk ~= gw then gw, gu = wk, 0 end
        if gu >= allowed then return false, state.graceWeek, state.graceUsed end
        gu = gu + 1
    end
    return true, gw, gu
end

-- The streak after a completed run on key. Returns the new state and whether it changed.
local function advance(state, key)
    if state.last == key then return state, false end
    if state.last and (daysBetween(state.last, key) or 0) < 0 then return state, false end
    if not state.last or state.days <= 0 then
        return { days = 1, last = key, graceWeek = state.graceWeek, graceUsed = state.graceUsed }, true
    end
    local alive, gw, gu = walkGap(state, key)
    if alive then return { days = state.days + 1, last = key, graceWeek = gw, graceUsed = gu }, true end
    return { days = 1, last = key, graceWeek = state.graceWeek, graceUsed = state.graceUsed }, true
end

-- The live streak on todayKey (today may still get its run): days, graceWeek, graceUsed.
local function currentStreak(state, todayKey)
    if not state.last or state.days <= 0 then return 0, state.graceWeek, state.graceUsed end
    local diff = daysBetween(state.last, todayKey) or 0
    if diff <= 1 then return state.days, state.graceWeek, state.graceUsed end
    local alive, gw, gu = walkGap(state, todayKey)
    if alive then return state.days, gw, gu end
    return 0, state.graceWeek, state.graceUsed
end

local function graceLeftFor(gw, gu, todayKey)
    local allowed = graceDays()
    if allowed <= 0 then return false end
    local used = (gw == weekKeyOf(todayKey)) and gu or 0
    return used < allowed
end

function Scoring.streak(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return { days = 0, multiplier = 1.0, graceLeft = false } end
    db()
    local row = readOfficer(citizenid)
    local today = dayKey(now())
    local days, gw, gu = currentStreak(streakState(row), today)
    return { days = days, multiplier = streakMultiplier(days), graceLeft = graceLeftFor(gw, gu, today) }
end

local function storeStreak(citizenid, st)
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_officers (citizenid, streak_days, last_complete, grace_week, grace_used)
        VALUES (?, ?, ?, NULLIF(?, ''), ?)
        ON DUPLICATE KEY UPDATE streak_days = VALUES(streak_days), last_complete = VALUES(last_complete),
            grace_week = VALUES(grace_week), grace_used = VALUES(grace_used)
    ]], { citizenid, math.min(st.days, STREAK_STORE_MAX), st.last, st.graceWeek or '', math.min(st.graceUsed, 127) })
    if not ok then CP.err(TAG, 'saving the streak of %s failed: %s', citizenid, tostring(err)) end
    return ok
end

local function applyStreakDay(citizenid, key)
    local row, ok = readOfficer(citizenid)
    if not ok then return end
    local st, changed = advance(streakState(row), key)
    if changed then
        storeStreak(citizenid, st)
        CP.log(TAG, 'streak of %s: %d day(s) (last %s)', citizenid, st.days, st.last)
    end
end

-- ── first run since going on duty ───────────────────────────────────────────
local function markFirstDone(citizenid)
    local st = duty[citizenid]
    if st then
        st.firstDone = true
    else
        duty[citizenid] = { onDuty = true, firstDone = true, since = now() }
    end
end

local function dutyEvaluate(src, fresh)
    if not (CP.Qbx and CP.Qbx.getInfo) then return end
    local info = CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return end
    local cid = info.citizenid
    srcCid[src] = cid
    if fresh then duty[cid] = nil end
    local onDuty = info.job and info.job.onduty == true
        and CP.Access and CP.Access.departmentForJob and CP.Access.departmentForJob(info.job.name) ~= nil
    local st = duty[cid]
    if onDuty then
        if not st or not st.onDuty then
            duty[cid] = { onDuty = true, firstDone = false, since = now() }
            CP.log(TAG, '%s went on duty: the next completed run earns the first-run bonus', cid)
        end
    elseif st then
        st.onDuty = false
    end
end

local function dutyEnded(src)
    local cid = srcCid[src]
    srcCid[src] = nil
    if cid and duty[cid] then duty[cid].onDuty = false end
end

function Scoring.isFirstRunSinceDuty(src)
    src = toSrc(src)
    if not src or not (CP.Qbx and CP.Qbx.getInfo) then return false end
    local info = CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return false end
    local cid = info.citizenid
    srcCid[src] = cid
    local st = duty[cid]
    if not st then
        -- Unknown since this resource started: count a completed run earlier today as the first one.
        db()
        local ok, found = pcall(MySQL.scalar.await, [[
            SELECT 1 AS found FROM cp_mission_runs
            WHERE citizenid = ? AND state = 'completed' AND mission_type NOT IN ('manual_award', 'goal')
              AND created_at >= FROM_UNIXTIME(?)
            LIMIT 1
        ]], { cid, CP.Schedule and CP.Schedule.dayStart and CP.Schedule.dayStart(now()) or (now() - 86400) })
        st = { onDuty = info.job and info.job.onduty == true, firstDone = ok and found ~= nil, since = now() }
        duty[cid] = st
    end
    return st.firstDone ~= true
end

-- ── compute ─────────────────────────────────────────────────────────────────
local function listedEntries(mission)
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

-- Per-occurrence value and 'each' of a listed entry.
local function entryValue(id, e, P)
    local cfg = Config.Bonuses and Config.Bonuses[id]
    local per
    if type(e.points) == 'number' then
        per = e.points
    elseif type(e.pctOfPoints) == 'number' then
        per = e.pctOfPoints * P
    elseif type(cfg) == 'table' then
        per = cfg.kind == 'pct' and num(cfg.value, 0) * P or num(cfg.value, 0)
    end
    local each = e.each == true or (type(cfg) == 'table' and cfg.each == true)
    return per, each
end

local function countOf(run, p, id)
    local shared = run.score and run.score.shared and num(run.score.shared[id], 0) or 0
    local personal = p.score and num(p.score[id], 0) or 0
    return math.max(0, math.floor(shared + personal))
end

local function label(kind, id, count, each, vars)
    local text = CP.L((kind == 'bonus' and 'bonus.' or 'penalty.') .. id, vars)
    if each and count > 1 then text = text .. ' ' .. CP.L('scoring.times', { n = count }) end
    return text
end

local function addLine(bonuses, penalties, id, value, count, each, penaltyHint, vars)
    local pts = CP.U.round(value)
    if pts == 0 then return 0 end
    if penaltyHint and pts > 0 then pts = -pts end
    if pts > 0 then
        bonuses[#bonuses + 1] = { id = id, label = label('bonus', id, count, each, vars), points = pts }
    else
        penalties[#penalties + 1] = { id = id, label = label('penalty', id, count, each, vars), points = pts }
    end
    return pts
end

local function presenceFailed(run, p)
    if not (CP.AntiCheat and CP.AntiCheat.presenceOk) then return false end
    if type(run.order) ~= 'table' or #run.order < 2 then return false end
    local ok, present = pcall(CP.AntiCheat.presenceOk, run, p)
    return ok and present == false
end

local function departmentsOf(run, p)
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

local function durationOf(run, opts)
    if opts.durationS ~= nil then return num(opts.durationS, 0) end
    if run.startedAt then return math.max(0, (run.endedAt or now()) - run.startedAt) end
    return 0
end

local function objectiveShare(run, opts)
    if opts.failedShare ~= nil then return CP.U.clamp(num(opts.failedShare, 0), 0, 1) end
    local total = num(opts.objectivesTotal, nil)
    local done = num(opts.objectivesDone, nil)
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
local function scoreLines(run, p, P, opts)
    local bonuses, penalties = {}, {}
    local total = 0
    local mission = run.mission or {}
    local common = commonCfg()
    local listed, order = listedEntries(mission)
    local stats = run.stats or {}

    local hints = run.score and run.score.values or {}
    local kinds = run.score and run.score.kinds or {}

    -- 1. the mission card (in file order), end-evaluated ids included
    for _, id in ipairs(order) do
        local l = listed[id]
        local per, each = entryValue(id, l.entry, P)
        if per == nil and tonumber(hints[id]) then
            -- Listed without a value of its own and not in Config.Bonuses: the block's per-occurrence value.
            per, each = tonumber(hints[id]), true
        end
        if per then
            if END_EVALUATED[id] then
                local earned = (id == 'no_participant_downed' and num(stats.downs, 0) == 0)
                    or (id == 'no_weapons_fired' and num(stats.weaponsFired, 0) == 0)
                if earned then total = total + addLine(bonuses, penalties, id, per, 1, false, l.penalty) end
            else
                local count = countOf(run, p, id)
                if count > 0 then
                    local value = each and per * count or per
                    total = total + addLine(bonuses, penalties, id, value, count, each, l.penalty)
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
            local count = countOf(run, p, id)
            local c = COMMON_RECORDED[id]
            if count > 0 and c then
                if id ~= 'lights_siren' or LIGHTS_MISSIONS[run.missionId or mission.id] then
                    local per = num(common[c.key], 0)
                    local value = c.each and per * count or per
                    total = total + addLine(bonuses, penalties, id, value, count, c.each, per < 0)
                end
            elseif count > 0 and tonumber(hints[id]) then
                local per = tonumber(hints[id])
                total = total + addLine(bonuses, penalties, id, per * count, count, true, kinds[id] == 'penalty')
            elseif count > 0 then
                warnOnce('unvalued:' .. id, 'bonus/penalty %s was recorded but has no value (not on the mission card, not in Config.Scoring.common, no points hint); ignored', id)
            end
        end
    end

    -- 3. common end-evaluated bonuses and penalties
    local duration = durationOf(run, opts)
    local limit = num(run.timeLimit, num(mission.timeLimit, 0))
    local fastShare = num(common.fastShare, 0.75)
    if not (run.flags and run.flags.medals) and limit > 0 and duration <= fastShare * limit then
        total = total + addLine(bonuses, penalties, 'fast_finish', num(common.fastBonus, 0) * P, 1, false, false,
            { pct = math.floor(fastShare * 100 + 0.5) })
    end
    if run.modifier then
        local modLabel = CP.L('modifier.' .. tostring(run.modifier))
        total = total + addLine(bonuses, penalties, 'modifier', num(Config.Events and Config.Events.modifierPoints, 0) * P, 1,
            false, false, { modifier = modLabel })
    end
    if p.firstRunSinceDuty == true then
        total = total + addLine(bonuses, penalties, 'first_run', num(common.firstRun, 0), 1, false, false)
    end
    local v = p.vehicle
    if type(v) == 'table' and v.seen then
        local engine, body = num(v.engine, 1000), num(v.body, 1000)
        local above = num(common.noDamageAbove, 950)
        if engine > above and body > above then
            total = total + addLine(bonuses, penalties, 'no_vehicle_damage', num(common.noDamage, 0), 1, false, false)
        end
        if mission.vehiclePenalties ~= false and body < num(common.heavyDamageBelow, 500) then
            total = total + addLine(bonuses, penalties, 'heavy_damage', num(common.heavyDamage, 0), 1, false, true)
        end
    end
    return bonuses, penalties, total
end

local function emptyBreakdown(P)
    return {
        P = P, bonuses = {}, penalties = {}, subtotal = 0, mTeam = 1.0, mCross = 1.0, mStreak = 1.0,
        capped = false, tod = false, failedShare = nil, final = 0,
    }
end

function Scoring.compute(run, p, result, opts)
    opts = type(opts) == 'table' and opts or {}
    if type(run) ~= 'table' or type(p) ~= 'table' then return emptyBreakdown(0) end
    local P = num(run.pointsBase, nil)
    if not P or P <= 0 then P = Scoring.P(run.mission) end
    local out = emptyBreakdown(P)

    if result == 'failed' then
        local share = objectiveShare(run, opts)
        local credit = num(scoringCfg().failedCredit, 0.25) * P * share
        out.failedShare = share
        out.subtotal = math.floor(credit * 100 + 0.5) / 100
        out.final = presenceFailed(run, p) and 0 or math.max(0, math.floor(credit + 1e-9))
        return out
    end
    if result ~= 'completed' then return out end

    local bonuses, penalties, total = scoreLines(run, p, P, opts)
    local subtotal = P + total
    local mTeam = num(tierRow(run).points, 1.0)
    local nDepts = num(opts.departments, nil) or departmentsOf(run, p)
    local mCross = nDepts >= 2 and num(Config.CrossDepartmentPoints, 1.10) or 1.0

    local streakDays = 0
    if p.citizenid then
        db()
        local row = readOfficer(p.citizenid)
        local st = advance(streakState(row), dayKey(now()))
        streakDays = st.days
    end
    local mStreak = streakMultiplier(streakDays)

    local raw = subtotal * mTeam * mCross * mStreak
    local cap = num(scoringCfg().scoreCap, 2.0) * P
    local capped = raw > cap + 1e-9
    local value = math.max(0, math.min(cap, raw))
    local final = math.floor(value + 1e-9)
    local tod = false
    if CP.Events and CP.Events.typeOfTheDay then
        local okT, key = pcall(CP.Events.typeOfTheDay)
        tod = okT and key ~= nil and key == run.missionType
    end
    if tod then final = math.floor(final * num(Config.Events and Config.Events.todMultiplier, 2.0) + 1e-9) end

    if presenceFailed(run, p) then
        final, capped, tod = 0, false, false
    end
    if not run.test and p.citizenid then markFirstDone(p.citizenid) end

    out.bonuses, out.penalties = bonuses, penalties
    out.subtotal = subtotal
    out.mTeam, out.mCross, out.mStreak = mTeam, mCross, mStreak
    out.capped, out.tod = capped, tod
    out.final = math.max(0, final)
    return out
end

-- ── XP and levels ───────────────────────────────────────────────────────────
local function levels()
    local list = {}
    for _, l in ipairs(Config.XPLevels or {}) do
        if type(l) == 'table' then list[#list + 1] = l end
    end
    table.sort(list, function(a, b) return num(a.xp, 0) < num(b.xp, 0) end)
    return list
end

-- Level names are configuration (Config.XPLevels label, like mission type labels); the locale only
-- fills in a level that has no label.
local function levelLabel(l)
    if type(l.label) == 'string' and l.label ~= '' then return l.label end
    return CP.L('scoring.level_unnamed', { xp = math.floor(num(l.xp, 0)) })
end

function Scoring.xpLevel(xp)
    xp = math.max(0, math.floor(num(xp, 0)))
    local list = levels()
    local cur, nxt = nil, nil
    for i, l in ipairs(list) do
        if xp >= num(l.xp, 0) then
            cur = l
            nxt = list[i + 1]
        end
    end
    if not cur then
        cur, nxt = list[1], list[2]
        if not cur then return { label = '', badge = 'grey', xp = 0, next = nil } end
    end
    return {
        label = levelLabel(cur),
        badge = tostring(cur.badge or 'grey'),
        xp = math.floor(num(cur.xp, 0)),
        next = nxt and math.floor(num(nxt.xp, 0)) or nil,
    }
end

local function addXp(citizenid, delta)
    delta = math.floor(num(delta, 0))
    if delta == 0 then return end
    local before = readOfficer(citizenid)
    local oldXp = before and math.floor(CP.U.num(before.xp)) or 0
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_officers (citizenid, xp) VALUES (?, ?)
        ON DUPLICATE KEY UPDATE xp = GREATEST(0, xp + ?)
    ]], { citizenid, math.max(0, delta), delta })
    if not ok then
        CP.err(TAG, 'XP update for %s failed: %s', citizenid, tostring(err))
        return
    end
    local newXp = math.max(0, oldXp + delta)
    local a, b = Scoring.xpLevel(oldXp), Scoring.xpLevel(newXp)
    if delta > 0 and b.xp > a.xp then
        notify(citizenid, 'success', 'scoring.level_up', { level = b.label })
    end
    CP.log(TAG, 'XP %s %+d -> %d', citizenid, delta, newXp)
end

-- Marks a row's points as added to XP; true only for the call that set the marker.
local function claimXp(rowId)
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

local function releaseXp(rowId)
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

-- ── badges ──────────────────────────────────────────────────────────────────
local BADGE_SELECT = [[
    SELECT mission_type, mission_id, participants, departments_n,
           COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"no_vehicle_damage"'), 0) AS no_damage,
           COALESCE(JSON_CONTAINS(JSON_EXTRACT(breakdown, '$.points.bonuses[*].id'), '"no_participant_downed"'), 0) AS no_downs
    FROM %s
    WHERE citizenid = ? AND state = 'completed' AND voided = 0 AND flagged = 0
      AND mission_type NOT IN ('manual_award', 'goal')
]]

local function badgeCounts(citizenid)
    local sql = ([[
        SELECT COALESCE(SUM(t.no_damage > 0), 0) AS iron_wheels,
               COALESCE(SUM(t.mission_id = 'gang_shootout' AND t.no_downs > 0), 0) AS sharpshooter,
               COALESCE(SUM(t.mission_type = 'patrol'), 0) AS road_warrior,
               COALESCE(SUM(t.participants >= 2), 0) AS partner_in_crime,
               COALESCE(SUM(t.departments_n >= 2), 0) AS joint_task_force
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

local function ownedBadges(citizenid)
    local ok, rows = pcall(MySQL.query.await, 'SELECT badge_id FROM cp_badges WHERE citizenid = ?', { citizenid })
    local set = {}
    if not ok then
        CP.err(TAG, 'badge lookup for %s failed: %s', citizenid, tostring(rows))
        return nil
    end
    for _, r in ipairs(rows or {}) do set[r.badge_id] = true end
    return set
end

-- Award missing achievement badges and (revoke = true, after a void) remove ones whose count fell short.
local function checkBadges(citizenid, revoke)
    local counts = badgeCounts(citizenid)
    local owned = ownedBadges(citizenid)
    if not counts or not owned then return end
    for _, b in ipairs(BADGES) do
        local need = math.floor(num(Config.Badges and Config.Badges[b.cfg], 0))
        if need > 0 then
            if counts[b.id] >= need and not owned[b.id] then
                local ok, n = pcall(MySQL.update.await,
                    'INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
                    { citizenid, b.id, now() })
                if ok and (tonumber(n) or 0) > 0 then
                    CP.log(TAG, '%s earned the %s badge', citizenid, b.id)
                    notify(citizenid, 'success', 'scoring.badge_earned', { badge = CP.L('badge.' .. b.id) })
                elseif not ok then
                    CP.err(TAG, 'awarding %s to %s failed: %s', b.id, citizenid, tostring(n))
                end
            elseif revoke and owned[b.id] and counts[b.id] < need then
                local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_badges WHERE citizenid = ? AND badge_id = ?', { citizenid, b.id })
                if ok then
                    CP.log(TAG, '%s lost the %s badge after a void', citizenid, b.id)
                else
                    CP.err(TAG, 'revoking %s from %s failed: %s', b.id, citizenid, tostring(err))
                end
            end
        end
    end
end

function Scoring.badges(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return {} end
    db()
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
        out[#out + 1] = { id = r.badge_id, label = CP.L('badge.' .. tostring(r.badge_id)), earnedAt = r.earned_at, earnedTs = tonumber(r.earned_ts) }
    end
    return out
end

-- ── hooks ───────────────────────────────────────────────────────────────────
local function readRun(rowId)
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
    db()
    local state = row.state
    if state ~= 'completed' and state ~= 'failed' then return end
    local pts = math.max(0, math.floor(num(row.final_points, 0)))
    local rowId = tonumber(row.id)
    local counted = true
    if rowId then counted = claimXp(rowId) end
    if counted and pts > 0 then addXp(citizenid, pts) end
    if NOT_RUNS[row.mission_type] or state ~= 'completed' then return end
    markFirstDone(citizenid)
    applyStreakDay(citizenid, dayKey(now()))
    checkBadges(citizenid, false)
end

function Scoring.onRowApproved(rowId)
    rowId = tonumber(rowId)
    if not rowId then return end
    db()
    local row = readRun(rowId)
    if not row then return end
    if CP.U.truthy(row.flagged) or CP.U.truthy(row.voided) then
        CP.warn(TAG, 'onRowApproved(%d): the row is still flagged or voided; nothing counted', rowId)
        return
    end
    if row.state ~= 'completed' and row.state ~= 'failed' then return end
    local pts = math.max(0, math.floor(CP.U.num(row.final_points)))
    if claimXp(rowId) and pts > 0 then addXp(row.citizenid, pts) end
    if NOT_RUNS[row.mission_type] or row.state ~= 'completed' then return end
    applyStreakDay(row.citizenid, dayKey(tonumber(row.created_ts) or now()))
    checkBadges(row.citizenid, false)
    if CP.Goals and CP.Goals.onRunCompleted then CP.Goals.onRunCompleted(row.citizenid) end
end

function Scoring.onRowVoided(rowId)
    rowId = tonumber(rowId)
    if not rowId then return end
    db()
    local row = readRun(rowId)
    if not row then return end
    local pts = math.max(0, math.floor(CP.U.num(row.final_points)))
    if releaseXp(rowId) and pts > 0 then addXp(row.citizenid, -pts) end
    if not NOT_RUNS[row.mission_type] then checkBadges(row.citizenid, true) end
end

-- ── manual awards ───────────────────────────────────────────────────────────
local function currentSeasonId()
    if CP.Challenge and CP.Challenge.currentSeason then
        local ok, s = pcall(CP.Challenge.currentSeason)
        if ok and type(s) == 'table' and tonumber(s.id) then return math.floor(tonumber(s.id)) end
    end
    return 0
end

-- Inserts a manual_award or goal row (RunResult-shaped breakdown) and counts it. Returns rowId|nil.
function Scoring._insertBonusRow(citizenid, kind, missionId, points, labelText, extra)
    local officer = readOfficer(citizenid)
    local dept = officer and type(officer.department) == 'string' and officer.department ~= '' and officer.department or 'unknown'
    local runUuid = CP.U.uuid()
    local breakdown = {
        runId = runUuid, missionLabel = labelText, missionType = kind, result = 'completed', endReason = 'completed',
        test = false, tier = 'standard', payTier = 'standard', participants = 1, departments = 1, durationS = 0,
        points = { P = points, bonuses = {}, penalties = {}, subtotal = points, mTeam = 1.0, mCross = 1.0, mStreak = 1.0,
            capped = false, tod = false, final = points },
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
    ]], { runUuid, kind, CP.U.clip(missionId, 40), citizenid, CP.U.clip(dept, 32), currentSeasonId(), points, points,
        okJ and js or '{}', now() })
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
    local actor = toSrc(actorSrc)
    if not actor then return false, 'err.no_permission' end
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local okP, errKey = CP.Permissions.can(actor, 'manualAward')
    if not okP then return false, errKey or 'err.no_permission' end
    if type(citizenid) ~= 'string' then return false, 'err.invalid_citizenid' end
    citizenid = CP.U.trim(citizenid)
    if citizenid == '' or #citizenid > 50 or not citizenid:match('^[%w_%-]+$') then return false, 'err.invalid_citizenid' end
    local n = tonumber(points)
    if not n or n ~= n or n ~= math.floor(n) or n < 1 or n > MANUAL_MAX then return false, 'err.invalid_points' end
    n = math.floor(n)
    if type(reason) ~= 'string' then return false, 'err.reason_required' end
    local r = CP.U.trim(reason)
    if r == '' then return false, 'err.reason_required' end
    if #r > REASON_MAX then return false, 'err.reason_too_long' end
    db()
    local officer, okRead = readOfficer(citizenid)
    if not okRead then return false, 'err.internal' end
    if not officer then return false, 'err.unknown_officer' end

    local rowId = Scoring._insertBonusRow(citizenid, 'manual_award', 'manual_award', n, CP.L('scoring.manual_award_label'),
        { reason = CP.U.clip(r, REASON_MAX) })
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
            "INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason) VALUES (?, ?, 'audit', 'manualAward', ?, NULL, ?, ?)",
            { CP.U.clip(actorId, 50), role, citizenid, tostring(n), r })
    end
    notify(citizenid, 'success', 'scoring.manual_award', { points = n, reason = r })
    CP.log(TAG, 'manual award %d to %s by %s: %s', n, citizenid, tostring(actor), r)
    return true, rowId
end

-- ── Home screen ─────────────────────────────────────────────────────────────
local function seasonPoints(citizenid)
    if CP.Leaderboard and CP.Leaderboard.seasonPoints then
        local ok, v = pcall(CP.Leaderboard.seasonPoints, citizenid)
        if ok and tonumber(v) then return math.floor(tonumber(v)) end
    end
    local seasonId = currentSeasonId()
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

local function announcementsList()
    local out = {}
    if CP.Leaderboard and CP.Leaderboard.announcements then
        local ok, list = pcall(CP.Leaderboard.announcements)
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

local function championsBanner(dept)
    if CP.Challenge and CP.Challenge.championBanner then
        local ok, b = pcall(CP.Challenge.championBanner, dept)
        if ok and type(b) == 'table' and b.season and b.department then
            return { season = tostring(b.season), department = tostring(b.department) }
        end
    end
    return nil
end

local function typeOfTheDayCard()
    if not (CP.Events and CP.Events.typeOfTheDay) then return nil end
    local ok, key = pcall(CP.Events.typeOfTheDay)
    if not ok or type(key) ~= 'string' then return nil end
    local t = Config.MissionTypes and Config.MissionTypes[key]
    if not t then return nil end
    -- key/label are the contract (§9.4); multiplier and cap (Config values) are extras for the Home text.
    return {
        key = key, label = t.label or key,
        multiplier = num(Config.Events and Config.Events.todMultiplier, 2.0),
        cap = num(scoringCfg().scoreCap, 2.0),
    }
end

local function homeData(officer)
    local cid = officer.citizenid
    db()
    local row = readOfficer(cid)
    local xp = row and math.max(0, math.floor(CP.U.num(row.xp))) or 0
    local st = Scoring.streak(cid)
    local goals = { daily = nil, weekly = nil }
    if CP.Goals and CP.Goals.forOfficer then
        local ok, g = pcall(CP.Goals.forOfficer, cid)
        if ok and type(g) == 'table' then goals = { daily = g.daily, weekly = g.weekly } end
    end
    return {
        card = {
            callsign = officer.callsign,
            rank = officer.rank or '',
            departmentShort = officer.departmentShort or '',
            name = officer.name or cid,
            xp = xp,
            level = Scoring.xpLevel(xp),
            -- graceDays (Config.Scoring.streakGraceDays) is an extra: 0 = no grace, so the UI says nothing about it.
            streak = { days = st.days, graceLeft = st.graceLeft, graceDays = graceDays() },
            seasonPoints = seasonPoints(cid),
            cashThisWeek = CP.Cash and CP.Cash.earnedThisWeek and CP.Cash.earnedThisWeek(cid) or 0,
        },
        goals = goals,
        typeOfTheDay = typeOfTheDayCard(),
        announcements = announcementsList(),
        champions = championsBanner(officer.department),
    }
end

CP.Net.callback('getHome', function(src)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey or 'err.not_police' end
    return homeData(officer)
end)

-- ── wiring ──────────────────────────────────────────────────────────────────
CreateThread(function()
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: the first-run bonus cannot follow duty changes')
        return
    end
    CP.Qbx.onDutyChange(function(src) dutyEvaluate(src, false) end)
    CP.Qbx.onJobChange(function(src) dutyEvaluate(src, false) end)
    CP.Qbx.onPlayerLoaded(function(src) dutyEvaluate(src, true) end)
    CP.Qbx.onPlayerUnload(function(src) dutyEnded(src) end)
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then dutyEnded(src) end
end)

-- Test hooks (not part of the contract).
Scoring._advance = advance
Scoring._currentStreak = currentStreak
Scoring._graceLeft = graceLeftFor
Scoring._dutyEvaluate = dutyEvaluate
Scoring._dutyEnded = dutyEnded
Scoring._checkBadges = checkBadges
Scoring._homeData = homeData
Scoring._duty = duty
