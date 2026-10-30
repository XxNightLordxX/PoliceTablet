-- CP.Events: Type of the Day, run twists (mission modifiers) and the Weekly Boss.

CP.Events = CP.Events or {}
local Events = CP.Events

local TAG = 'events'
local BOSS_ID = 'weekly_boss_kingpin'
local BOSS_KEY = 'weekly_boss'

-- End reasons that do not use up the week's attempt (Mission cards: Weekly Boss).
local BOSS_EXEMPT_REASONS = { 'real_call', 'force_recall', 'cancelled' }

-- armedOnly: offered and applied only where the mission spawns armed NPCs; timedOnly: only with a time limit.
local MODIFIERS = {
    armored_hostiles = { label = 'modifier.armored_hostiles', armedOnly = true },
    time_crunch = { label = 'modifier.time_crunch', timedOnly = true },
    radio_silence = { label = 'modifier.radio_silence' },
}
local armedMemo = setmetatable({}, { __mode = 'k' })   -- armedMemo[def] = whether the mission spawns armed NPCs

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

-- The hourly cap for officers (a unit's members): the hourlyCap Mission control via CP.Draw.limits, else config.
local function HourlyCap(officers)
    if CP.Draw and CP.Draw.limits then
        local ok, l = pcall(CP.Draw.limits, officers)
        if ok and type(l) == 'table' and tonumber(l.hour) then return l.hour end
    end
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

-- Extra attempts an admin gave this week (cp_officers.boss_extra = { week, n }).
local function BossExtra(citizenid, weekKey)
    local ok, row = pcall(MySQL.single.await, 'SELECT boss_extra FROM cp_officers WHERE citizenid = ?', { citizenid })
    if not ok or type(row) ~= 'table' then return 0 end
    local v = row.boss_extra
    if type(v) == 'string' and v ~= '' then
        local okJ, t = pcall(json.decode, v)
        v = okJ and t or nil
    end
    if type(v) ~= 'table' or v.week ~= weekKey then return 0 end
    return math.max(0, math.floor(tonumber(v.n) or 0))
end

-- This week's boss rows that used up an attempt (a voided row gives its attempt back), and the extra attempts.
local function BossUsage(citizenid)
    local weekKey = WeekKeyNow()
    CP.Migrations.ready()
    local n = MySQL.scalar.await(
        'SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND mission_type = \'tactical\' AND mission_id = ? AND created_at >= FROM_UNIXTIME(?) AND voided = 0 AND end_reason NOT IN (?, ?, ?)',
        {
            citizenid,
            BOSS_ID,
            AttemptWindowStart(),
            BOSS_EXEMPT_REASONS[1],
            BOSS_EXEMPT_REASONS[2],
            BOSS_EXEMPT_REASONS[3],
        })
    return math.floor(CP.U.num(n)), BossExtra(citizenid, weekKey), weekKey
end

-- True when this officer already used every attempt of this week.
local function UsedThisWeek(citizenid)
    local weekKey = WeekKeyNow()
    if usedCache[citizenid] == weekKey then return true end
    local used, extra = BossUsage(citizenid)
    if used > extra then
        usedCache[citizenid] = weekKey
        return true
    end
    return false
end

-- { used, extra, left, week } for the Admin UI (Officers → Today & cooldowns).
function Events.bossUsage(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    local used, extra, weekKey = BossUsage(citizenid)
    return { used = used, extra = extra, left = math.max(0, 1 + extra - used), week = weekKey }
end

-- The weekly attempt cache of one officer (or everyone) is read again: a grant, a void or a restore changed it.
function Events.forgetBossUsage(citizenid)
    if type(citizenid) == 'string' and citizenid ~= '' then
        usedCache[citizenid] = nil
    else
        usedCache = {}
    end
end

CP.Hooks.on('admin:changed', function(data)
    if type(data) == 'table' then Events.forgetBossUsage(data.citizenid) end
end)
-- A void or restore of any row may be a boss row: every cached "used" is read again.
CP.Hooks.on('row:voided', function() usedCache = {} end)
CP.Hooks.on('row:restored', function() usedCache = {} end)

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

-- The type the day's seed picks, before any admin override.
function Events.rolledTypeOfTheDay(dayKey)
    if not (Config.Events and Config.Events.typeOfTheDay) then return nil end
    local keys = CP.U.keys(Config.MissionTypes or {})
    if #keys == 0 then return nil end
    local rng = CP.U.rng(CP.U.hash(tostring(dayKey or DayKeyNow())))
    local key = rng:pick(keys)
    return key
end

-- Today's override: { day, choice ('auto' | 'none' | a type), by, reason, at }. An admin's choice lives in memory and
-- in its cp_audit row (action todOverride, target = the day), which a restart reads back; cp_audit is never replaced
-- by a backup restore, and an override of another day is ignored, so it always ends at the daily reset.
local tod = nil

local function TodState(day)
    if tod and tod.day == day then return tod end
    if not (CP.Migrations and CP.Migrations.ready) then return nil end
    local ok, row = pcall(function()
        CP.Migrations.ready()
        return MySQL.single.await([[SELECT new_value, actor, reason, UNIX_TIMESTAMP(created_at) AS ts FROM cp_audit
            WHERE action = 'todOverride' AND target = ? ORDER BY id DESC LIMIT 1]], { day })
    end)
    if not ok then return nil end
    tod = { day = day, choice = 'auto' }
    if type(row) == 'table' and type(row.new_value) == 'string' then
        tod.choice, tod.by, tod.reason, tod.at = row.new_value, row.actor, row.reason, CP.U.num(row.ts)
    end
    return tod
end

-- { day, type ('none' = no Type of the Day), by, reason, at } for today, or nil (the day's roll).
function Events.todOverride()
    local s = TodState(DayKeyNow())
    if not s or s.choice == 'auto' then return nil end
    if s.choice ~= 'none' and not (Config.MissionTypes and Config.MissionTypes[s.choice]) then return nil end
    return { day = s.day, type = s.choice, by = s.by, reason = s.reason, at = s.at }
end

-- typeKey, 'none' or 'auto' (nil = 'auto': back to the roll) for today. meta = { by, reason }. ok | false, errKey.
-- The caller writes the cp_audit row (action todOverride, target = Events.todDay(), new_value = the choice).
function Events.setTodOverride(choice, meta)
    choice = choice or 'auto'
    if choice ~= 'auto' and choice ~= 'none' and not (Config.MissionTypes and Config.MissionTypes[choice]) then
        return false, 'err.unknown_type'
    end
    meta = type(meta) == 'table' and meta or {}
    tod = { day = DayKeyNow(), choice = choice, by = meta.by, reason = meta.reason, at = os.time() }
    return true
end

function Events.todDay() return DayKeyNow() end

function Events.typeOfTheDay(dayKey)
    if not (Config.Events and Config.Events.typeOfTheDay) then return nil end
    if dayKey == nil or dayKey == DayKeyNow() then
        local o = Events.todOverride()
        if o then
            if o.type == 'none' then return nil end
            return o.type
        end
    end
    return Events.rolledTypeOfTheDay(dayKey)
end

-- ============================================================================
--                                  MODIFIERS
-- ============================================================================

-- Whether a mission spawns armed NPCs: an objective whose block counts armed NPCs (its armedCount, the Mission
-- Builder's armed budget) above 0.
local function Armed(def)
    if type(def) ~= 'table' then return false end
    local memo = armedMemo[def]
    if memo ~= nil then return memo end
    local armed, known = false, true
    for _, obj in ipairs(type(def.objectives) == 'table' and def.objectives or {}) do
        local impl = type(obj) == 'table' and CP.Blocks and CP.Blocks.get and CP.Blocks.get(obj.block) or nil
        if type(impl) == 'table' and type(impl.armedCount) == 'function' then
            local ok, n = pcall(impl.armedCount, obj)
            if ok and (tonumber(n) or 0) > 0 then
                armed = true
                break
            end
        elseif type(impl) ~= 'table' then
            known = false   -- a block not registered (yet): asked again next time
        end
    end
    if armed or known then armedMemo[def] = armed end
    return armed
end

-- What a twist does, in the officers' words (the accept step and the ready check).
local function TwistDesc(key)
    local ev = Config.Events or {}
    if key == 'armored_hostiles' then
        return CP.L('twist.desc.armored_hostiles', { armour = math.floor((tonumber(ev.armoredArmour) or 0) + 0.5) })
    elseif key == 'time_crunch' then
        return CP.L('twist.desc.time_crunch', { pct = math.floor((tonumber(ev.timeCrunchCut) or 0) * 100 + 0.5) })
    end
    local mode = type(Config.Markers) == 'table' and Config.Markers.radioSilence or nil
    if mode ~= 'none' and mode ~= 'full' then mode = 'area' end
    return CP.L('twist.desc.radio_silence_' .. mode)
end

function Events.modifiers()
    local out = {}
    for key, m in pairs(MODIFIERS) do
        local c = CP.Twists.cfg(key)
        out[key] = {
            label = m.label,
            armedOnly = m.armedOnly == true,
            enabled = c.enabled,
            points = c.points,
            cash = c.cash,
        }
    end
    return out
end

-- Whether twist key makes sense for mission def: Armored Hostiles only where armed NPCs spawn (never without a
-- mission to look at), Time Crunch only with a time limit, none on the Weekly Boss.
function Events.twistFits(key, def)
    local m = MODIFIERS[key]
    if not m then return false end
    if type(def) == 'table' and def.isBoss == true then return false end
    if m.armedOnly then return Armed(def) end
    if m.timedOnly and type(def) == 'table' and def.timeLimit ~= nil then return (tonumber(def.timeLimit) or 0) > 0 end
    return true
end

-- ============================================================================
--                  THE DEPARTMENT'S TWISTS (MISSION CONTROL)
-- ============================================================================
-- The twists Mission control (step P15, per department, under the master switch, off as shipped): which of the
-- twists the admin enabled in Config.Events.twists the department's leaders are offered at the accept step, and
-- which of them start ticked. Its value: { offered = { key, ... }, ticked = { key, ... } } (ticked within offered).

local TWISTS_KEY = 'twists'

-- The twists the admin enabled (Config.Events.twists), in CP.Twists.ORDER.
local function EnabledTwists()
    local out = {}
    for _, key in ipairs(CP.Twists.ORDER) do
        if CP.Twists.cfg(key).enabled then out[#out + 1] = key end
    end
    return out
end

-- A list of twist keys: the enabled ones, each once, in order. strict: anything else refused (nil).
local function CleanList(raw, strict, allowed)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil end
    local keep = {}
    for k, v in pairs(raw) do
        if math.type(k) ~= 'integer' or type(v) ~= 'string' then
            if strict then return nil end
        elseif allowed[v] then
            keep[v] = true
        elseif strict then
            return nil
        end
    end
    local out = {}
    for _, key in ipairs(CP.Twists.ORDER) do
        if keep[key] then out[#out + 1] = key end
    end
    return out
end

-- The control's value cleaned: { offered, ticked } with only enabled twists and ticked within offered. strict (a
-- supervisor's or admin's change): an unknown or switched-off twist, or a ticked one not offered, is refused (nil);
-- otherwise (a saved value read today) what the admin switched off since is left out.
local function CleanTwists(v, strict)
    if type(v) ~= 'table' then return nil end
    for k in pairs(v) do
        if strict and k ~= 'offered' and k ~= 'ticked' then return nil end
    end
    local enabled = {}
    for _, key in ipairs(EnabledTwists()) do enabled[key] = true end
    local offered = CleanList(v.offered, strict, enabled)
    if not offered then return nil end
    local inOffer = {}
    for _, key in ipairs(offered) do inOffer[key] = true end
    local ticked = CleanList(v.ticked, strict, inOffer)
    if not ticked then return nil end
    return { offered = offered, ticked = ticked }
end
Events._cleanTwists = CleanTwists

-- The department's twists: { offered = { [key] = true }, ticked = { [key] = true } }, or nil when nothing narrows
-- the offer (no department, no Mission controls). With the control off (as shipped): every enabled twist, none
-- ticked, so the accept step is as before.
function Events.deptTwists(dept)
    local dc = CP.DeptControls
    if type(dept) ~= 'string' or not (dc and dc.get and dc.def and dc.def(TWISTS_KEY)) then return nil end
    local ok, v = pcall(dc.get, dept, TWISTS_KEY)
    if not ok then
        CP.err(TAG, 'reading the %s control of %s failed: %s', TWISTS_KEY, dept, tostring(v))
        return nil
    end
    v = CleanTwists(v, false)
    if not v then return nil end
    local out = { offered = {}, ticked = {} }
    for _, key in ipairs(v.offered) do out.offered[key] = true end
    for _, key in ipairs(v.ticked) do out.ticked[key] = true end
    return out
end

function Events.registerTwistControl()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    dc.register(TWISTS_KEY, {
        kind = 'map',
        scope = 'run',
        bounded = false,
        configValue = function() return { offered = EnabledTwists(), ticked = {} } end,
        check = function(v)
            local clean = CleanTwists(v, true)
            if not clean then return nil, 'err.control_value' end
            return clean
        end,
        clamp = function(v) return CleanTwists(v, false) end,
        -- offering fewer twists or pre-ticking some never makes a rule easier: it applies to the setter too
        relaxes = function() return false end,
        -- the twists the admin enabled, for the supervisor's switches
        viewExtra = function()
            local list = {}
            for _, key in ipairs(EnabledTwists()) do
                list[#list + 1] = { key = key, label = CP.L(MODIFIERS[key].label) }
            end
            return { twistsAll = list }
        end,
    })
    return true
end
Events.registerTwistControl()

-- The twists the officers may choose for a mission type whose pool for them is list (mission defs): every enabled
-- twist that fits at least one mission of the pool. The mission is drawn after the accept (Hard rule: Mission
-- choice), so a twist that fits only some of them is marked some = true: it is dropped, without its reward, when
-- the drawn mission is not one of them. None for the Weekly Boss.
-- dept (optional): the leader's department; its twists Mission control (step P15) narrows the offer to the twists it
-- offers and marks the ones it pre-ticks (ticked = true).
-- { { key, label, desc, points, cash, some, ticked } } in CP.Twists.ORDER.
function Events.twistOffer(missionType, list, dept)
    local out = {}
    if missionType == BOSS_KEY or type(list) ~= 'table' or #list == 0 then return out end
    local own = Events.deptTwists(dept)
    for _, key in ipairs(CP.Twists.ORDER) do
        local c = CP.Twists.cfg(key)
        if c.enabled and (not own or own.offered[key]) then
            local fit = 0
            for _, def in ipairs(list) do
                if Events.twistFits(key, def) then fit = fit + 1 end
            end
            if fit > 0 then
                out[#out + 1] = {
                    key = key,
                    label = CP.L(MODIFIERS[key].label),
                    desc = TwistDesc(key),
                    points = c.points,
                    cash = c.cash,
                    some = fit < #list or nil,
                    ticked = own and own.ticked[key] or nil,
                }
            end
        end
    end
    return out
end

-- The twists the tablet sent with an accept, checked: a clean list in CP.Twists.ORDER, or nil and the error key.
-- raw: nil, or a list of twist keys; every one must be offered for this type now (Events.twistOffer) and, with dept
-- (the leader's department), by that department (its twists Mission control, step P15: err.twist_department).
function Events.checkTwists(raw, missionType, list, dept)
    if raw == nil then return {} end
    if type(raw) ~= 'table' then return nil, 'err.invalid_payload' end
    local n = 0
    for k, v in pairs(raw) do
        n = n + 1
        if math.type(k) ~= 'integer' or not CP.Twists.known(v) then return nil, 'err.invalid_payload' end
    end
    if n == 0 then return {} end
    if n > #CP.Twists.ORDER then return nil, 'err.invalid_payload' end
    local offered = {}
    for _, o in ipairs(Events.twistOffer(missionType, list)) do offered[o.key] = true end
    local out = CP.Twists.sorted(raw)
    for _, key in ipairs(out) do
        if not offered[key] then return nil, 'err.twist_unavailable' end
    end
    local own = Events.deptTwists(dept)
    for _, key in ipairs(out) do
        if own and not own.offered[key] then return nil, 'err.twist_department' end
    end
    return out
end

-- The chosen twists that fit the drawn mission of run: kept, dropped (a twist that changes nothing on that mission
-- gets no reward). Never any on test runs, Cross-Department Missions or the Weekly Boss.
function Events.fitTwists(run, chosen)
    local kept, dropped = {}, {}
    local list = CP.Twists.sorted(chosen)
    if type(run) ~= 'table' or run.test or run.operationId or run.isBoss then return kept, list end
    for _, key in ipairs(list) do
        if CP.Twists.cfg(key).enabled and Events.twistFits(key, run.mission) then
            kept[#kept + 1] = key
        else
            dropped[#dropped + 1] = key
        end
    end
    return kept, dropped
end

-- A random twist on top of the chosen ones (Config.Events.modifierChance; 0, as shipped, never rolls): one that
-- is enabled, fits the run's mission and is not on the run already.
function Events.rollModifier(run)
    if type(run) ~= 'table' then return nil end
    if run.test or run.operationId or run.isBoss or (run.mission and run.mission.isBoss) then return nil end
    local chance = tonumber(Config.Events and Config.Events.modifierChance) or 0
    if chance <= 0 then return nil end
    -- Derived from the run seed (and salted so it is independent of the objectives' own rng streams).
    local seed = CP.U.hash(tostring(run.seed or run.id or os.time()) .. ':modifier')
    local rng = CP.U.rng(seed)
    if not rng:chance(chance) then return nil end
    local taken = {}
    for _, key in ipairs(CP.Twists.of(run)) do taken[key] = true end
    local eligible = {}
    -- Config.Events.twists.<key>.enabled = false: that twist is never rolled.
    for _, key in ipairs(CP.Twists.ORDER) do
        if not taken[key] and CP.Twists.cfg(key).enabled and Events.twistFits(key, run.mission) then
            eligible[#eligible + 1] = key
        end
    end
    if #eligible == 0 then return nil end
    local key = rng:pick(eligible)
    CP.log(TAG, 'run %s rolled twist %s', tostring(run.id), tostring(key))
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
-- base payout (CP.Payouts.baseFor) times the tier's cash multiplier. The boss never has a twist.
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
        twists = {},   -- the Weekly Boss never has a twist
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
        local max = HourlyCap(officers)
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
