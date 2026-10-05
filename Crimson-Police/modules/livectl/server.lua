-- CP.LiveCtl (server): the Admin UI's Live screen (every live run and unit), an officer's run state with the anti-farm
-- overrides (cooldown clears, extra runs, another boss attempt, a free abandon made normal) and today's events.

CP.LiveCtl = CP.LiveCtl or {}
local LiveCtl = CP.LiveCtl
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'livectl'

local FREE_ABANDON_WINDOW_S = 86400  -- free abandons are shown and made normal for this long
local FREE_ABANDON_ROWS = 50
local CLEAR_KEEP_S = 7 * 86400       -- cooldown clear stamps older than this are dropped from the marker
local ADD_MINUTES_MAX = 10           -- one "+ minutes" click
local CITIZENID_MAX = 50
local MISSION_ID_MAX = 64
local SCOPES = { all = true, type = true, mission = true }

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function ToSrc(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n < 0 then return nil end
    return n
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return default end
    return n
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false, nil end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Ctl() return Config.AdminControl or {} end

local function Limit(key, default) return math.max(0, math.floor(Num(Ctl()[key], default))) end

local function Cid(v)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v)
    if s == '' or #s > CITIZENID_MAX or not s:match('^[%w_%-]+$') then return nil end
    return s
end

local function RunIdOf(v)
    if type(v) ~= 'string' or v == '' or #v > 64 then return nil end
    return v
end

local function DayKey()
    local ok, key = Call('Schedule', 'dayKey')
    if ok and type(key) == 'string' then return key end
    return os.date('%Y-%m-%d')
end

local function WeekKey()
    local ok, key = Call('Schedule', 'weekKey')
    if ok and type(key) == 'string' then return key end
    return os.date('%Y-W%V')
end

local function TypeLabel(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    return (t and t.label) or tostring(key)
end

local function MissionLabel(id)
    local ok, def = Call('Missions', 'get', id)
    if ok and type(def) == 'table' and type(def.label) == 'string' then return def.label end
    return tostring(id)
end

-- The online src of a citizenid (nil when offline).
local function OnlineSrc(citizenid)
    local ok, src = Call('Qbx', 'getByCitizenId', citizenid)
    src = ok and ToSrc(src) or nil
    if not src or src == 0 then return nil end
    return src
end

local function RunOfCitizen(citizenid)
    local src = OnlineSrc(citizenid)
    if not src then return nil, nil end
    local ok, run = Call('Runs', 'getBySrc', src)
    if ok and type(run) == 'table' then return run, src end
    return nil, src
end

local function Decode(v)
    if type(v) == 'table' then return v end
    if type(v) ~= 'string' or v == '' then return nil end
    local ok, t = pcall(json.decode, v)
    return ok and type(t) == 'table' and t or nil
end

-- ============================================================================
--                  THE OFFICER'S JSON MARKERS (K, FILES MODE)
-- ============================================================================
-- cooldown_clears, cap_extra and boss_extra on cp_officers: read, changed in Lua and written back with a compare on
-- the old JSON text (mission ids hold '-', which a JSON path would need quoted).

local MARKERS = { cooldown_clears = true, cap_extra = true, boss_extra = true }

-- exists, oldText (nil = NULL), decoded table
local function ReadMarker(citizenid, column)
    if not MARKERS[column] then return false end
    Db()
    local ok, row = pcall(MySQL.single.await,
        ('SELECT citizenid, %s AS v FROM cp_officers WHERE citizenid = ?'):format(column), { citizenid })
    if not ok then
        CP.err(TAG, 'reading %s of %s failed: %s', column, citizenid, tostring(row))
        return false
    end
    if type(row) ~= 'table' then return false end
    local text = row.v
    if type(text) == 'table' then text = json.encode(text) end
    if text == '' then text = nil end
    return true, text, Decode(text) or {}
end

-- ok | false, 'err.state_changed' (someone changed it since oldText was read)
local function WriteMarker(citizenid, column, oldText, value)
    if not MARKERS[column] then return false, 'err.invalid_payload' end
    local newText = json.encode(value)
    if oldText == nil then
        return Kit.cas(('UPDATE cp_officers SET %s = ? WHERE citizenid = ? AND %s IS NULL'):format(column, column),
            { newText, citizenid })
    end
    return Kit.cas(('UPDATE cp_officers SET %s = ? WHERE citizenid = ? AND %s = ?'):format(column, column),
        { newText, citizenid, oldText })
end
LiveCtl._readMarker = ReadMarker
LiveCtl._writeMarker = WriteMarker

-- ============================================================================
--                                  LIVE RUNS
-- ============================================================================

local function DeptShort(key)
    local d = Config.Departments and Config.Departments[key]
    return d and (d.short or d.label) or tostring(key)
end

local function RunView(run, adminSrc)
    local list = {}
    local depts, seen = {}, {}
    local own = false
    for _, src in ipairs(run.order or {}) do
        local p = run.participants[src]
        if p then
            list[#list + 1] = {
                src = src,
                citizenid = p.citizenid,
                name = p.name or ('#' .. src),
                callsign = p.callsign,
                departmentShort = p.departmentShort or '',
                status = p.status,
                arrived = p.arrived == true,
                endReason = p.status ~= 'active' and p.endReason or nil,
            }
            if p.department and not seen[p.department] then
                seen[p.department] = true
                depts[#depts + 1] = p.departmentShort or DeptShort(p.department)
            end
        end
    end
    if adminSrc and adminSrc > 0 and not run.test then own = Kit.selfRun(adminSrc, run.id) == true end
    local remaining = nil
    local okR, r = Call('Runs', 'remaining', run)
    if okR and r then remaining = math.max(0, math.ceil(r)) end
    local tier = run.tier and run.tier.name or run.expectedTier
    return {
        runId = run.id,
        missionId = run.missionId,
        missionLabel = run.mission and run.mission.label or run.missionId,
        missionType = run.missionType,
        state = run.state,
        tier = tier,
        remaining = remaining,
        timerRunning = run.timer and run.timer.running == true or false,
        paused = run.timer and run.timer.paused == true or false,
        timeLimit = run.timeLimit,
        timeAdded = math.floor(Num(run.timeAdded, 0)),
        test = run.test ~= nil,
        testBy = run.test and ToSrc(run.test.adminSrc) or nil,
        operationId = run.operationId,
        isBoss = run.isBoss == true,
        modifier = run.modifier,
        acceptedAt = run.acceptedAt,
        startedAt = run.startedAt,
        unitId = run.unit and run.unit.id or nil,
        departments = depts,
        own = own,
        participants = list,
    }
end

function LiveCtl.liveRuns(adminSrc)
    local ok, all = Call('Runs', 'all')
    local out = {}
    for _, run in ipairs(ok and type(all) == 'table' and all or {}) do
        if run.state ~= 'ended' then out[#out + 1] = RunView(run, ToSrc(adminSrc)) end
    end
    table.sort(out, function(a, b) return (a.acceptedAt or 0) < (b.acceptedAt or 0) end)
    return out
end

local function LiveRun(runId)
    local ok, run = Call('Runs', 'get', runId)
    if not ok or type(run) ~= 'table' or run.state == 'ended' then return nil end
    return run
end

local function NotifyRun(run, key, vars)
    local ok, srcs = Call('Runs', 'activeSrcs', run)
    if ok and type(srcs) == 'table' then Call('Tablet', 'notifyMany', srcs, 'warning', key, vars) end
end

local function RunTargets(payload) return { runUuid = RunIdOf(payload.runId) } end

-- ============================================================================
--                    OFFICER RUN STATE (TODAY & COOLDOWNS)
-- ============================================================================

local function FreeAbandons(citizenid)
    Db()
    local ok, rows = pcall(
        MySQL.query.await,
        ([[SELECT run_uuid, mission_type, mission_id,
        UNIX_TIMESTAMP(created_at) AS ts FROM cp_mission_runs WHERE citizenid = ? AND end_reason = 'real_call'
        AND created_at >= FROM_UNIXTIME(?) ORDER BY created_at DESC LIMIT %d]]):format(FREE_ABANDON_ROWS),
        { citizenid, os.time() - FREE_ABANDON_WINDOW_S }
    )
    local out = {}
    if not ok then
        CP.err(TAG, 'free abandons of %s failed: %s', citizenid, tostring(rows))
        return out
    end
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        out[#out + 1] = {
            runUuid = r.run_uuid,
            missionType = r.mission_type,
            typeLabel = TypeLabel(r.mission_type),
            missionLabel = MissionLabel(r.mission_id),
            at = math.floor(U.num(r.ts)),
        }
    end
    return out
end

local function CooldownList(citizenid)
    local ok, cd = Call('Runs', 'cooldowns', citizenid)
    local types, missions = {}, {}
    if ok and type(cd) == 'table' then
        for key, untilTs in pairs(cd.types or {}) do
            types[#types + 1] = { key = key, label = TypeLabel(key), ['until'] = untilTs }
        end
        for id, untilTs in pairs(cd.missions or {}) do
            missions[#missions + 1] = { id = id, label = MissionLabel(id), ['until'] = untilTs }
        end
    end
    table.sort(types, function(a, b) return a.key < b.key end)
    table.sort(missions, function(a, b) return a.id < b.id end)
    return { types = types, missions = missions }
end

local function Counts(citizenid)
    local limits = Config.Limits or {}
    local _, today = Call('Runs', 'completionsToday', citizenid, nil, true)
    local _, hour = Call('Runs', 'completionsLastHour', citizenid)
    local perType = {}
    for key, t in pairs(Config.MissionTypes or {}) do
        local _, n = Call('Runs', 'completionsToday', citizenid, key)
        local limit = tonumber(t.dailyLimit)
        perType[#perType + 1] = {
            key = key,
            label = TypeLabel(key),
            n = math.floor(Num(n, 0)),
            limit = limit and limit > 0 and math.floor(limit) or nil,
        }
    end
    table.sort(perType, function(a, b) return a.key < b.key end)
    local maxDay = math.floor(Num(limits.maxCompletionsDay, 0))
    return {
        today = math.floor(Num(today, 0)),
        maxDay = maxDay > 0 and maxDay or nil,
        hour = math.floor(Num(hour, 0)),
        maxHour = math.floor(Num(limits.maxCompletionsHour, 8)),
        perType = perType,
    }
end

-- The Mission Board as the officer sees it (C10): type cards and why each is locked. Never a mission id or name
-- (Hard rule Mission choice): only the fields below leave this function.
local function BoardView(src)
    local ok, data = Call('Draw', 'boardCards', src)
    if not ok or type(data) ~= 'table' then return nil end
    local cards = {}
    for _, c in ipairs(type(data.cards) == 'table' and data.cards or {}) do
        cards[#cards + 1] = {
            key = c.key,
            label = TypeLabel(c.key),
            pool = math.floor(Num(c.pool, 0)),
            busy = c.busy == true,
            onCall = c.onCall == true,
            typeOfTheDay = c.typeOfTheDay == true,
            locked = type(c.locked) == 'table'
                    and { reason = tostring(c.locked.reason or ''), ['until'] = tonumber(c.locked['until']) }
                or nil,
        }
    end
    local boss = nil
    if type(data.boss) == 'table' then
        boss = {
            available = data.boss.available == true,
            locked = type(data.boss.locked) == 'table' and { reason = tostring(data.boss.locked.reason or '') } or nil,
        }
    end
    return {
        cards = cards,
        boss = boss,
        operation = data.operation ~= nil,
        serverTime = os.time(),
        unitSize = type(data.unit) == 'table' and data.unit.size or 1,
    }
end

function LiveCtl.officerRunState(citizenid)
    local okO, exists, _, clears = pcall(ReadMarker, citizenid, 'cooldown_clears')
    if not okO or not exists then return nil, 'err.unknown_officer' end
    local _, _, extra = ReadMarker(citizenid, 'cap_extra')
    local _, _, bossExtra = ReadMarker(citizenid, 'boss_extra')
    local run, src = RunOfCitizen(citizenid)
    local today, week = DayKey(), WeekKey()
    local okC, cash = Call('Cash', 'paidToday', citizenid)
    local okB, boss = Call('Events', 'bossUsage', citizenid)
    local bossCfg = Config.Events and Config.Events.weeklyBoss or {}
    return {
        citizenid = citizenid,
        online = src ~= nil,
        onRun = run ~= nil,
        runId = run and run.id or nil,
        cooldowns = CooldownList(citizenid),
        clears = {
            used = clears.day == today and math.floor(Num(clears.n, 0)) or 0,
            max = Limit('cooldownClearsPerDay', 3),
        },
        counts = Counts(citizenid),
        extra = {
            n = extra.day == today and math.floor(Num(extra.n, 0)) or 0,
            usedToday = extra.day == today,
            max = Limit('extraRunsMax', 10),
        },
        cashToday = okC and math.floor(Num(cash, 0)) or 0,
        boss = {
            enabled = bossCfg.enabled == true,
            used = okB and type(boss) == 'table' and boss.used or 0,
            extra = okB and type(boss) == 'table' and boss.extra or 0,
            left = okB and type(boss) == 'table' and boss.left or 1,
            grantedThisWeek = bossExtra.week == week,
        },
        freeAbandons = FreeAbandons(citizenid),
        board = src and BoardView(src) or nil,
        serverTime = os.time(),
    }
end

-- ============================================================================
--                             ANTI-FARM OVERRIDES
-- ============================================================================

-- Refused while the officer is on a run: the change would land in the middle of it.
local function NotOnRun(citizenid)
    if RunOfCitizen(citizenid) then return false, 'err.live_officer_on_run' end
    return true
end

local function PruneStamps(t, now)
    local out = {}
    for k, v in pairs(type(t) == 'table' and t or {}) do
        if Num(v, 0) > now - CLEAR_KEEP_S then out[k] = v end
    end
    return out
end

-- scope 'all' | 'type' (key = a mission type) | 'mission' (key = a mission id). ok, data | false, errKey.
function LiveCtl.clearCooldowns(citizenid, scope, key)
    local max = Limit('cooldownClearsPerDay', 3)
    if max <= 0 then return false, 'err.live_limit_off' end
    local okRun, errRun = NotOnRun(citizenid)
    if not okRun then return false, errRun end
    local exists, oldText, cur = ReadMarker(citizenid, 'cooldown_clears')
    if not exists then return false, 'err.unknown_officer' end
    local today, now = DayKey(), os.time()
    local used = cur.day == today and math.floor(Num(cur.n, 0)) or 0
    if used >= max then return false, 'err.live_clear_limit' end
    local value = {
        day = today,
        n = used + 1,
        all = Num(cur.all, 0) > now - CLEAR_KEEP_S and cur.all or nil,
        type = PruneStamps(cur.type, now),
        mission = PruneStamps(cur.mission, now),
    }
    if scope == 'all' then
        value.all = now
    elseif scope == 'type' then
        value.type[key] = now
    else
        value.mission[key] = now
    end
    local ok, err = WriteMarker(citizenid, 'cooldown_clears', oldText, value)
    if not ok then return false, err end
    Call('Runs', 'clearCooldowns', citizenid, scope, key)
    return true, { used = value.n, max = max }
end

-- count extra completions today (the daily cap only, never the hourly one). Once per officer per day.
function LiveCtl.allowExtraRuns(citizenid, count)
    local max = Limit('extraRunsMax', 10)
    if max <= 0 then return false, 'err.live_limit_off' end
    count = math.tointeger(tonumber(count) or 0)
    if not count or count < 1 or count > max then return false, 'err.live_count_range' end
    local exists, oldText, cur = ReadMarker(citizenid, 'cap_extra')
    if not exists then return false, 'err.unknown_officer' end
    local today = DayKey()
    if cur.day == today then return false, 'err.live_extra_used' end
    local ok, err = WriteMarker(citizenid, 'cap_extra', oldText, { day = today, n = count })
    if not ok then return false, err end
    return true, { n = count, day = today }
end

-- One more Weekly Boss attempt this week. Once per officer per week.
function LiveCtl.grantBossAttempt(citizenid)
    local exists, oldText, cur = ReadMarker(citizenid, 'boss_extra')
    if not exists then return false, 'err.unknown_officer' end
    local week = WeekKey()
    if cur.week == week then return false, 'err.live_boss_granted' end
    local ok, err = WriteMarker(citizenid, 'boss_extra', oldText, { week = week, n = 1 })
    if not ok then return false, err end
    Call('Events', 'forgetBossUsage', citizenid)
    return true, { week = week }
end

-- A free abandon (end_reason real_call) of the last 24 h becomes a normal one: the type and mission cooldowns start
-- now, exactly as an un-mark within the dodge window does. The run paid nothing either way.
function LiveCtl.reclassifyAbandon(citizenid, runUuid)
    Db()
    local ok, row = pcall(MySQL.single.await, [[SELECT id FROM cp_mission_runs WHERE citizenid = ? AND run_uuid = ?
        AND end_reason = 'real_call' AND created_at >= FROM_UNIXTIME(?) LIMIT 1]],
        { citizenid, runUuid, os.time() - FREE_ABANDON_WINDOW_S })
    if not ok then return false, 'err.internal' end
    if type(row) ~= 'table' then return false, 'err.live_not_free_abandon' end
    local okR, done = Call('Runs', 'reclassify', citizenid, runUuid, 'real_call_cancelled')
    if not okR or done ~= true then return false, 'err.state_changed' end
    return true, { runUuid = runUuid }
end

-- ============================================================================
--                   TODAY: TYPE OF THE DAY, BOSS, MODIFIERS
-- ============================================================================

function LiveCtl.today()
    local ev = Config.Events or {}
    local _, tod = Call('Events', 'typeOfTheDay')
    local _, rolled = Call('Events', 'rolledTypeOfTheDay')
    local _, override = Call('Events', 'todOverride')
    local _, mods = Call('Events', 'modifiers')
    local modifiers = {}
    for key, m in pairs(type(mods) == 'table' and mods or {}) do
        modifiers[#modifiers + 1] = {
            key = key,
            label = CP.L(m.label or ('modifier.' .. key)),
            tacticalOnly = m.tacticalOnly == true,
            enabled = m.enabled ~= false,
        }
    end
    table.sort(modifiers, function(a, b) return a.key < b.key end)
    local types = {}
    for key in pairs(Config.MissionTypes or {}) do types[#types + 1] = { key = key, label = TypeLabel(key) } end
    table.sort(types, function(a, b) return a.key < b.key end)
    local boss = ev.weeklyBoss or {}
    local weekday = nil
    local okW, w = Call('Schedule', 'weekday')
    if okW then weekday = w end
    local bossDay = false
    for _, d in ipairs(boss.days or {}) do
        if weekday and tostring(d):lower() == tostring(weekday):lower() then bossDay = true end
    end
    return {
        day = DayKey(),
        todEnabled = ev.typeOfTheDay == true,
        typeOfTheDay = tod,
        typeLabel = tod and TypeLabel(tod) or nil,
        rolled = rolled,
        override = type(override) == 'table'
                and { type = override.type, by = override.by, reason = override.reason, at = override.at }
            or nil,
        todMultiplier = Num(ev.todMultiplier, 2),
        boss = { enabled = boss.enabled == true, today = bossDay, days = boss.days or {} },
        modifierChance = Num(ev.modifierChance, 0),
        modifiers = modifiers,
        types = types,
    }
end

-- Every online officer hears about today's new Type of the Day; their boards refresh.
local function TellOfficers(key, vars)
    local ok, list = Call('Qbx', 'getOnlinePlayers')
    if not ok or type(list) ~= 'table' then return end
    for _, s in ipairs(list) do
        local src = ToSrc(s)
        local okI, info = Call('Qbx', 'getInfo', src)
        local job = okI and type(info) == 'table' and type(info.job) == 'table' and info.job.name or nil
        local okD, dept = Call('Access', 'departmentForJob', job)
        if src and okD and dept then
            Call('Tablet', 'notify', src, 'info', key, vars)
            Call('Tablet', 'push', src, 'board', { tod = true })
        end
    end
end

-- ============================================================================
--                         NET: CALLBACKS (ADMINS ONLY)
-- ============================================================================

Kit.callback('admin:getLiveRuns', 'liveRuns', function(ctx)
    return {
        runs = LiveCtl.liveRuns(ctx.src),
        serverTime = os.time(),
        addMinutesMax = ADD_MINUTES_MAX,
        runTimeAddMax = Limit('runTimeAddMax', 600),
    }
end)

Kit.callback('admin:getUnits', 'liveRuns', function(ctx)
    local ok, list = Call('Units', 'adminList')
    local units = ok and type(list) == 'table' and list or {}
    local mine = {}
    for _, u in ipairs(units) do
        u.own = false
        for _, m in ipairs(u.members) do
            if m.src == ctx.src then u.own = true end
        end
        mine[#mine + 1] = u
    end
    return { units = mine, serverTime = os.time() }
end)

Kit.callback('admin:getOfficerRunState', 'antiFarmOverride', function(ctx)
    local cid = Cid(ctx.args.citizenid)
    if not cid then return nil, 'err.invalid_payload' end
    return LiveCtl.officerRunState(cid)
end)

Kit.callback('admin:getToday', 'liveRuns', function() return LiveCtl.today() end)

-- ============================================================================
--                     NET: LIVE RUN ACTIONS (ADMINS ONLY)
-- ============================================================================

-- Recall one participant without penalty (the existing force recall: no cooldown, pay tier kept).
Kit.action('server:admin:recall', 'liveRuns', function(ctx)
    local runId = RunIdOf(ctx.payload.runId)
    local target = ToSrc(ctx.payload.src)
    if not runId or not target or target == 0 then return false, 'err.invalid_payload' end
    if not Has('Admin', 'forceRecall') then return false, 'err.module_unavailable' end
    return CP.Admin.forceRecall(ctx.src, runId, target, ctx.reason)
end, { reason = true, self = RunTargets, category = 'operations' })

-- End a whole live run: everyone still on it leaves Abandoned (cancelled), with the cleanup of every other end.
Kit.action('server:admin:endRun', 'liveRuns', function(ctx)
    local runId = RunIdOf(ctx.payload.runId)
    local run = runId and LiveRun(runId)
    if not run then return false, 'err.invalid_run' end
    if run.test then return false, 'err.live_use_end_test' end
    local label = run.mission and run.mission.label or run.missionId
    local srcs = select(2, Call('Runs', 'activeSrcs', run)) or {}
    if not Has('Runs', 'cancelRun') then return false, 'err.module_unavailable' end
    local okE, errE = CP.Runs.cancelRun(run, 'cancelled', { src = ctx.src, reason = ctx.reason })
    if not okE then return false, errE end
    Call('Tablet', 'notifyMany', srcs, 'warning', 'admin.live.notice.run_ended', { mission = label })
    ctx.audit('runEnd', run.id, run.missionId, tostring(#srcs), { category = 'operations' })
    return true, { runId = run.id, participants = #srcs }
end, { reason = true, confirm = 'END', self = RunTargets, rate = 2, category = 'operations' })

-- End another admin's test run (tests are never saved or paid): the same cleanup.
Kit.action('server:admin:endTest', 'liveRuns', function(ctx)
    local runId = RunIdOf(ctx.payload.runId)
    local run = runId and LiveRun(runId)
    if not run then return false, 'err.invalid_run' end
    if not run.test then return false, 'err.live_not_test' end
    local srcs = select(2, Call('Runs', 'activeSrcs', run)) or {}
    if not Has('Runs', 'cancelRun') then return false, 'err.module_unavailable' end
    local okE, errE = CP.Runs.cancelRun(run, 'cancelled', { src = ctx.src, reason = ctx.reason })
    if not okE then return false, errE end
    Call('Tablet', 'notifyMany', srcs, 'warning', 'admin.live.notice.test_ended',
        { mission = run.mission and run.mission.label or run.missionId })
    ctx.audit('testEnd', run.id, run.missionId, nil, { category = 'builder' })
    return true, { runId = run.id }
end, { reason = true, category = 'builder' })

-- Add 1-10 minutes to a running timer; every addition of one run together stays within runTimeAddMax.
Kit.action('server:admin:addRunTime', 'liveRuns', function(ctx)
    local runId = RunIdOf(ctx.payload.runId)
    local minutes = math.tointeger(tonumber(ctx.payload.minutes) or 0)
    if not minutes or minutes < 1 or minutes > ADD_MINUTES_MAX then return false, 'err.live_minutes_range' end
    local run = runId and LiveRun(runId)
    if not run then return false, 'err.invalid_run' end
    local okA, total = CP.Runs.addTime(run, minutes * 60, Limit('runTimeAddMax', 600))
    if not okA then return false, total end
    NotifyRun(run, 'admin.live.notice.time_added', { minutes = minutes })
    ctx.audit('runTimeAdd', run.id, tostring(total - minutes * 60), tostring(total), { category = 'operations' })
    return true, { runId = run.id, timeAdded = total }
end, { reason = true, self = RunTargets, category = 'operations' })

-- ============================================================================
--                       NET: UNIT ACTIONS (ADMINS ONLY)
-- ============================================================================

-- An admin never splits their own unit or one of their own characters' units.
local function OwnUnit(src, unit)
    if src == 0 or type(unit) ~= 'table' then return false end
    for _, m in ipairs(unit.members or {}) do
        if m == src then return true end
        local okI, info = Call('Qbx', 'getInfo', m)
        local cid = okI and type(info) == 'table' and info.citizenid or nil
        if cid and Kit.isSelf(src, cid) == true then return true end
    end
    return false
end

local function UnitOf(payload)
    local id = math.tointeger(tonumber(payload.unitId) or -1)
    if not id or id < 1 then return nil end
    local ok, unit = Call('Units', 'adminGet', id)
    return ok and type(unit) == 'table' and unit or nil, id
end

Kit.action('server:admin:removeFromUnit', 'liveRuns', function(ctx)
    local unit, id = UnitOf(ctx.payload)
    if not unit then return false, 'err.unit_gone' end
    if OwnUnit(ctx.src, unit) then return false, 'err.live_own_unit' end
    local target = ToSrc(ctx.payload.src)
    local info = target and unit.info and unit.info[target] or nil
    local okR, res = CP.Units.adminRemove(id, target)
    if not okR then return false, res end
    ctx.audit('unitRemove', tostring(id), info and info.name and U.clip(info.name, 64) or tostring(target), nil,
        { category = 'operations' })
    return true, res
end, { reason = true, category = 'operations' })

Kit.action('server:admin:disbandUnit', 'liveRuns', function(ctx)
    local unit, id = UnitOf(ctx.payload)
    if not unit then return false, 'err.unit_gone' end
    if OwnUnit(ctx.src, unit) then return false, 'err.live_own_unit' end
    local n = #(unit.members or {})
    local okD, res = CP.Units.adminDisband(id)
    if not okD then return false, res end
    ctx.audit('unitDisband', tostring(id), tostring(n), nil, { category = 'operations' })
    return true, { disbanded = true }
end, { reason = true, category = 'operations' })

-- ============================================================================
--                    NET: ANTI-FARM OVERRIDES (ADMINS ONLY)
-- ============================================================================

local function OfficerTarget(payload) return { citizenid = Cid(payload.citizenid) } end

Kit.action('server:admin:clearCooldowns', 'antiFarmOverride', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    local scope = ctx.payload.scope
    if not SCOPES[scope] then return false, 'err.invalid_payload' end
    local key = nil
    if scope == 'type' then
        key = ctx.payload.key
        if type(key) ~= 'string' or not (Config.MissionTypes and Config.MissionTypes[key]) then
            return false, 'err.unknown_type'
        end
    elseif scope == 'mission' then
        key = ctx.payload.key
        if type(key) ~= 'string' or key == '' or #key > MISSION_ID_MAX then return false, 'err.unknown_mission' end
    end
    local ok, res = LiveCtl.clearCooldowns(cid, scope, key)
    if not ok then return false, res end
    ctx.audit('cooldownClear', cid, scope, key and U.clip(key, 64) or nil, { category = 'flags' })
    ctx.changed('cooldowns', cid)
    ctx.notify(cid, 'info', 'admin.live.notice.cooldowns_cleared', {})
    return true, res
end, { reason = true, self = OfficerTarget, targetRate = { 1, 3000 }, category = 'flags' })

Kit.action('server:admin:allowExtraRuns', 'antiFarmOverride', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    local ok, res = LiveCtl.allowExtraRuns(cid, ctx.payload.count)
    if not ok then return false, res end
    ctx.audit('extraRunsAllow', cid, nil, tostring(res.n), { category = 'flags' })
    ctx.changed('extraRuns', cid)
    ctx.notify(cid, 'info', 'admin.live.notice.extra_runs', { n = res.n })
    return true, res
end, { reason = true, self = OfficerTarget, targetRate = { 1, 3000 }, category = 'flags' })

Kit.action('server:admin:grantBossAttempt', 'antiFarmOverride', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    if not cid then return false, 'err.invalid_payload' end
    local ok, res = LiveCtl.grantBossAttempt(cid)
    if not ok then return false, res end
    ctx.audit('bossAttemptGrant', cid, nil, res.week, { category = 'flags' })
    ctx.changed('bossAttempt', cid)
    ctx.notify(cid, 'info', 'admin.live.notice.boss_attempt', {})
    return true, res
end, { reason = true, self = OfficerTarget, targetRate = { 1, 3000 }, category = 'flags' })

Kit.action('server:admin:reclassifyAbandon', 'antiFarmOverride', function(ctx)
    local cid = Cid(ctx.payload.citizenid)
    local runUuid = RunIdOf(ctx.payload.runUuid)
    if not cid or not runUuid then return false, 'err.invalid_payload' end
    local ok, res = LiveCtl.reclassifyAbandon(cid, runUuid)
    if not ok then return false, res end
    ctx.audit('abandonReclassify', cid, 'real_call', 'real_call_cancelled', { category = 'flags' })
    -- CP.Runs.reclassify already put the cooldowns (from now) in the in-memory table: no admin:changed here, which
    -- would rebuild it from the row's own time.
    ctx.notify(cid, 'warning', 'admin.live.notice.abandon_reclassified', {})
    return true, res
end, {
    reason = true,
    self = function(p) return { citizenid = Cid(p.citizenid), runUuid = RunIdOf(p.runUuid) } end,
    category = 'flags',
})

-- Today's Type of the Day: a mission type, 'none' (no Type of the Day today) or 'auto' (back to the day's roll).
Kit.action('server:admin:setTypeOfDay', 'liveRuns', function(ctx)
    if not (Config.Events and Config.Events.typeOfTheDay) then return false, 'err.live_tod_off' end
    local t = ctx.payload.type
    if t ~= 'none' and t ~= 'auto' and not (type(t) == 'string' and Config.MissionTypes and Config.MissionTypes[t]) then
        return false, 'err.unknown_type'
    end
    if not Has('Events', 'setTodOverride') then return false, 'err.module_unavailable' end
    local _, before = Call('Events', 'typeOfTheDay')
    local okS, errS = CP.Events.setTodOverride(t, { by = ctx.actor, reason = ctx.reason })
    if not okS then return false, errS end
    local _, after = Call('Events', 'typeOfTheDay')
    -- this row is also what CP.Events reads back after a restart (target = the day, new_value = the choice)
    local _, day = Call('Events', 'todDay')
    ctx.audit('todOverride', day or DayKey(), before and tostring(before) or 'none', t)
    if after ~= before then
        if after then
            TellOfficers('admin.live.notice.tod_changed', { type = TypeLabel(after) })
        else
            TellOfficers('admin.live.notice.tod_none', {})
        end
    end
    return true, { typeOfTheDay = after }
end, { reason = true, category = 'audit' })

-- ============================================================================
--                           SIDEBAR COUNT, START-UP
-- ============================================================================

CreateThread(function()
    Wait(0)
    if Has('Tablet', 'registerNavCount') then
        CP.Tablet.registerNavCount('adminLive', function()
            local ok, all = Call('Runs', 'all')
            local n = 0
            for _, run in ipairs(ok and type(all) == 'table' and all or {}) do
                if run.state ~= 'ended' then n = n + 1 end
            end
            return n
        end, { adminOnly = true })
    end
end)
