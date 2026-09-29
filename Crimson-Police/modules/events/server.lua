-- CP.Events: Type of the Day, run modifiers and the Weekly Boss.

CP.Events = CP.Events or {}
local Events = CP.Events

local TAG = 'events'
local BOSS_ID = 'weekly_boss_kingpin'
local BOSS_KEY = 'weekly_boss'

-- End reasons that do not use up the week's attempt (Mission cards: Weekly Boss).
local BOSS_EXEMPT_REASONS = { 'real_call', 'force_recall', 'cancelled' }

local MODIFIER_ORDER = { 'armored_hostiles', 'time_crunch', 'radio_silence' }
local MODIFIERS = {
    armored_hostiles = { label = 'modifier.armored_hostiles', tacticalOnly = true },
    time_crunch = { label = 'modifier.time_crunch' },
    radio_silence = { label = 'modifier.radio_silence' },
}

local usedCache = {}   -- usedCache[citizenid] = weekKey the attempt was seen used in (positive results only)

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function BossCfg()
    return (Config.Events and Config.Events.weeklyBoss) or {}
end

local function DayKeyNow()
    if CP.Schedule and CP.Schedule.dayKey then return CP.Schedule.dayKey() end
    return os.date('%Y-%m-%d')
end

local function WeekdayNow()
    if CP.Schedule and CP.Schedule.weekday then return CP.Schedule.weekday() end
    return os.date('%A'):lower()
end

local function WeekStartNow()
    if CP.Schedule and CP.Schedule.weekStart then return CP.Schedule.weekStart() end
    return os.time() - 7 * 86400
end

local function WeekKeyNow()
    if CP.Schedule and CP.Schedule.weekKey then return CP.Schedule.weekKey() end
    return os.date('%Y-%m-%d', WeekStartNow())
end

local function IsBossWeekday(name)
    for _, d in ipairs(BossCfg().days or {}) do
        if tostring(d):lower() == name then return true end
    end
    return false
end

local function IsBossDay()
    return IsBossWeekday(WeekdayNow())
end

local function HourlyCap()
    return tonumber(Config.Limits and Config.Limits.maxCompletionsHour) or 8
end

local function CompletionsLastHour(citizenid)
    if not (CP.Runs and CP.Runs.completionsLastHour) then return 0 end
    local ok, n = pcall(CP.Runs.completionsLastHour, citizenid)
    return ok and tonumber(n) or 0
end

local function OperationLocked()
    if CP.Operations and CP.Operations.isLocked then
        local ok, locked = pcall(CP.Operations.isLocked)
        return ok and locked == true
    end
    return false
end

local function BossDef()
    if not (CP.Missions and CP.Missions.get) then return nil end
    local def = CP.Missions.get(BOSS_ID)
    if not def then return nil end
    if CP.Missions.isEnabled and not CP.Missions.isEnabled(BOSS_ID) then return nil end
    return def
end

-- Start of this week's attempt window: the reset of the week's first boss day. A run row is written
-- when the run ends, so a boss run accepted late on the last boss day of last week (Sunday) and ended
-- after the weekly reset has a row dated this week; it belongs to last week's attempt and must not use
-- up this week's. With a boss day on the week's first day the window starts at the week start itself.
local function AttemptWindowStart()
    local weekStart = WeekStartNow()
    if not (CP.Schedule and CP.Schedule.dayStart and CP.Schedule.weekday) then return weekStart end
    for i = 0, 6 do
        local probe = weekStart + i * 86400 + 7200   -- 2 h into the day: safe across DST changes
        if IsBossWeekday(CP.Schedule.weekday(probe)) then
            return i == 0 and weekStart or CP.Schedule.dayStart(probe)
        end
    end
    return weekStart
end

-- True when this officer already used this week's attempt.
local function UsedThisWeek(citizenid)
    local weekKey = WeekKeyNow()
    if usedCache[citizenid] == weekKey then return true end
    CP.Migrations.ready()
    local n = MySQL.scalar.await(
        'SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND mission_type = \'tactical\' AND mission_id = ? AND created_at >= FROM_UNIXTIME(?) AND end_reason NOT IN (?, ?, ?)',
        {
            citizenid,
            BOSS_ID,
            AttemptWindowStart(),
            BOSS_EXEMPT_REASONS[1],
            BOSS_EXEMPT_REASONS[2],
            BOSS_EXEMPT_REASONS[3],
        })
    if CP.U.num(n) > 0 then
        usedCache[citizenid] = weekKey
        return true
    end
    return false
end

local function Members(src)
    if CP.Units and CP.Units.members then
        local ok, list = pcall(CP.Units.members, src)
        if ok and type(list) == 'table' and #list > 0 then return list end
    end
    return { src }
end

local function OfficerOf(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    return CP.Access.getOfficer(src)
end

-- ============================================================================
--                               TYPE OF THE DAY
-- ============================================================================

function Events.typeOfTheDay(dayKey)
    if not (Config.Events and Config.Events.typeOfTheDay) then return nil end
    local keys = CP.U.keys(Config.MissionTypes or {})
    if #keys == 0 then return nil end
    local rng = CP.U.rng(CP.U.hash(tostring(dayKey or DayKeyNow())))
    local key = rng:pick(keys)
    return key
end

-- ============================================================================
--                                  MODIFIERS
-- ============================================================================

function Events.modifiers()
    local out = {}
    for key, m in pairs(MODIFIERS) do
        out[key] = { label = m.label, tacticalOnly = m.tacticalOnly == true }
    end
    return out
end

function Events.rollModifier(run)
    if type(run) ~= 'table' then return nil end
    if run.test or run.operationId or run.isBoss or (run.mission and run.mission.isBoss) then return nil end
    local chance = tonumber(Config.Events and Config.Events.modifierChance) or 0
    if chance <= 0 then return nil end
    -- Derived from the run seed (and salted so it is independent of the objectives' own rng streams).
    local seed = CP.U.hash(tostring(run.seed or run.id or os.time()) .. ':modifier')
    local rng = CP.U.rng(seed)
    if not rng:chance(chance) then return nil end
    local missionType = run.missionType or (run.mission and run.mission.type)
    local eligible = {}
    for _, key in ipairs(MODIFIER_ORDER) do
        if not MODIFIERS[key].tacticalOnly or missionType == 'tactical' then eligible[#eligible + 1] = key end
    end
    local key = rng:pick(eligible)
    CP.log(TAG, 'run %s rolled modifier %s', tostring(run.id), tostring(key))
    return key
end

-- ============================================================================
--                                 WEEKLY BOSS
-- ============================================================================

function Events.bossAvailable(src, officer)
    if not BossCfg().enabled then return false, 'err.boss_disabled' end
    if not BossDef() then return false, 'err.boss_unavailable' end
    if not IsBossDay() then return false, 'err.boss_not_today' end
    if OperationLocked() then return false, 'err.operation_locked' end
    if type(officer) ~= 'table' then
        local o, errKey = OfficerOf(src)
        if not o then return false, errKey or 'err.not_police' end
        officer = o
    end
    if not officer.citizenid then return false, 'err.not_police' end
    if UsedThisWeek(officer.citizenid) then return false, 'err.boss_used' end
    return true
end

-- Cash range for the boss card: CP.Cash.range when it knows the boss key, otherwise the boss's
-- base payout (CP.Payouts.baseFor) times the tier's cash multiplier. The boss never rolls a modifier.
local function BossCash(def, officers, size)
    if CP.Cash and CP.Cash.range then
        local ok, lo, hi = pcall(CP.Cash.range, BOSS_KEY, officers)
        if ok and type(lo) == 'number' and type(hi) == 'number' and hi > 0 then
            return { math.floor(lo + 0.5), math.floor(hi + 0.5) }
        end
    end
    local base = tonumber(BossCfg().payout) or 0
    if CP.Payouts and CP.Payouts.baseFor then
        local ok, b = pcall(CP.Payouts.baseFor, def)
        if ok and type(b) == 'number' then base = b end
    end
    local tier = CP.Scaling.tierFor(size)
    local amount = CP.U.round(base * (tonumber(tier and tier.cash) or 1.0))
    return { amount, amount }
end

local function BossPoints(def)
    if CP.Scoring and CP.Scoring.P then
        local ok, p = pcall(CP.Scoring.P, def)
        if ok and type(p) == 'number' then return p end
    end
    return tonumber(BossCfg().points) or 0
end

function Events.bossCard(src)
    if not BossCfg().enabled or not IsBossDay() or OperationLocked() then return nil end
    local def = BossDef()
    if not def then return nil end
    local viewer = OfficerOf(src)
    if not viewer then return nil end

    local srcs = Members(src)
    local size = #srcs
    local officers, locked = {}, nil
    for _, m in ipairs(srcs) do
        local o = (m == src) and viewer or OfficerOf(m)
        if o then
            officers[#officers + 1] = o
        elseif not locked then
            locked = { reason = CP.L('board.member_unavailable') }
        end
    end

    local card = {
        key = BOSS_KEY,
        label = def.label,
        points = BossPoints(def),
        cash = BossCash(def, officers, size),
        pool = 1,
        mode = size > 1 and 'unit' or 'solo',
        locked = nil,
        busy = false,
        onCall = false,
        typeOfTheDay = Events.typeOfTheDay() == 'tactical',
        available = false,
    }

    if CP.Runs and CP.Runs.capsOk then
        local ok, capOk = pcall(CP.Runs.capsOk, 'tactical')
        card.busy = ok and capOk == false
    end
    if CP.Calls and CP.Calls.isOnCall then
        for _, m in ipairs(srcs) do
            local ok, onCall = pcall(CP.Calls.isOnCall, m)
            if ok and onCall then card.onCall = true end
        end
    end

    -- Eligibility of the mission itself for this unit (department, size, mission cooldown).
    if not locked and CP.Draw and CP.Draw._eligibility then
        local ok, why, untilTs, who = CP.Draw._eligibility(def, officers)
        if not ok then
            if why == 'cooldown' then
                if who and who.src ~= src then
                    locked = {
                        reason = CP.L('board.boss_cooldown_member', { name = who.name or '?' }),
                        ['until'] = untilTs,
                    }
                else
                    locked = { reason = CP.L('board.boss_cooldown'), ['until'] = untilTs }
                end
            else
                locked = { reason = CP.L('board.boss_not_eligible') }
            end
        end
    end

    -- The boss counts toward the hourly cap (Mission cards: Weekly Boss): the accept refuses it then.
    if not locked then
        local max = HourlyCap()
        for _, o in ipairs(officers) do
            if CompletionsLastHour(o.citizenid) >= max then
                if o.src == src then
                    locked = { reason = CP.L('board.locked_hourly', { max = max }) }
                else
                    locked = { reason = CP.L('board.locked_hourly_member', { name = o.name or '?', max = max }) }
                end
                break
            end
        end
    end

    -- Once per officer per week, for every member.
    if not locked then
        for _, o in ipairs(officers) do
            local ok, reason = Events.bossAvailable(o.src, o)
            if not ok then
                if reason == 'err.boss_used' then
                    if o.src == src then
                        locked = { reason = CP.L('board.boss_used') }
                    else
                        locked = { reason = CP.L('board.boss_used_member', { name = o.name or '?' }) }
                    end
                else
                    locked = { reason = CP.L(reason) }
                end
                break
            end
        end
    end

    card.locked = locked
    -- available = this officer/unit may take this week's attempt; busy and onCall are separate flags.
    card.available = locked == nil
    return card
end
