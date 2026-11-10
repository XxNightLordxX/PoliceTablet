-- CP.HappyHour (server): happy hour, the timed cooldown change of the cooldown Mission controls. A supervisor (or an

-- CP.HappyHour (server): happy hour, the timed cooldown change of the cooldown Mission controls. A supervisor (or an
-- admin) starts it for N minutes (the admin's min and max) with a cooldown scale (scaleMin to scaleMax, shipped 0 =
-- no mission cooldown): while it runs every mission type's cooldown is x that scale for anyone on the server
-- (cooldownScale reads it) and, when ticked, the no-repeat rule is off. The abandon type cooldown, the hourly and
-- daily caps and the cash cap stay. Server-wide (anything that changes cooldowns is), outside the master switch,
-- perDay a day for supervisors (Config.MissionControls.controls.happyHour.perDay, counted from the audit log), never
-- for the supervisor who started it or a unit he is in while it relaxes a rule (the self rule). It is one timed row
-- of cp_dept_controls (expires_at), so a restart keeps the window; when it ends every cooldown is read against its
-- real end time again (read-time cooldowns).
-- the happyHourCash control (per department, under the master switch, shipped off with min = max = 1.0):
-- HH.cashBonusFor gives a run accepted during a happy hour its department's cash multiplier (run.controls.cashBonus),
-- never for the one who started the hour or a unit he is in.
-- happyHourPoints, the same for points: HH.pointsBonusFor fixes run.controls.pointsBonus at the accept
-- (CP.Scoring.compute multiplies the final points by it).

CP.HappyHour = CP.HappyHour or {}
local HH = CP.HappyHour

local TAG = 'happyhour'
local KEY = 'happyHour'
local WHERE = '*'            -- a server-wide control's row
local TICK_MS = 30000        -- how often the end of a happy hour is looked for (the screens hear it then)
local MINUTES_RANGE = { 1, 240 }
local SCALE_RANGE = { 0, 2 } -- x every mission's cooldown while it runs (the cooldownScale control's range)
local PER_DAY_RANGE = { 0, 24 }

local last = nil             -- the end time of the happy hour the last tick saw (0 = none)

-- The admin's bounds of the control (Config.MissionControls.controls.happyHour), {} when there are none.
local function Bounds()
    local dc = CP.DeptControls
    return dc and dc.bounds and dc.bounds(nil, KEY) or {}
end

-- Happy hours a day a supervisor may start (Config.MissionControls.controls.happyHour.perDay).
function HH.perDay() return math.max(0, math.floor(tonumber(Bounds().perDay) or 1)) end

-- The cooldown scales a supervisor may pick: lo, hi (scaleMin and scaleMax; a scaleMax below scaleMin = scaleMin).
function HH.scaleBounds(bounds)
    local b = bounds or Bounds()
    local lo = CP.Num(b.scaleMin, 0, SCALE_RANGE[1], SCALE_RANGE[2])
    local hi = CP.Num(b.scaleMax, lo, SCALE_RANGE[1], SCALE_RANGE[2])
    return lo, math.max(lo, hi)
end

-- Happy hours started today (every set of the control is in the audit log).
function HH.usedToday()
    if not (CP.AdminKit and CP.AdminKit.dailyCount) then return 0 end
    return CP.AdminKit.dailyCount('missionControlSet', { target = WHERE .. ':' .. KEY }) or 0
end

-- A scale on the 0.05 step.
local function Step(x) return math.floor(x * 20 + 0.5) / 20 end

-- { minutes = n, scale = x, noRepeat = 0 | 1 } from a screen (noRepeat may come as true or false; no scale = the
-- lowest one the admin allows): clean | nil, errKey.
local function Check(value, bounds)
    if type(value) ~= 'table' then return nil, 'err.control_value' end
    local m = math.tointeger(tonumber(value.minutes))
    local lo = tonumber(bounds.min) or MINUTES_RANGE[1]
    local hi = tonumber(bounds.max) or 30
    if not m or m < lo or m > hi then return nil, 'err.control_value' end
    local nr = value.noRepeat
    if nr ~= nil and nr ~= true and nr ~= false and nr ~= 0 and nr ~= 1 then return nil, 'err.control_value' end
    local sLo, sHi = HH.scaleBounds(bounds)
    local sc = value.scale == nil and sLo or tonumber(value.scale)
    if sc == nil or sc ~= sc then return nil, 'err.control_value' end
    sc = Step(sc)
    if sc < sLo - 1e-9 or sc > sHi + 1e-9 then return nil, 'err.control_value' end
    for k in pairs(value) do
        if k ~= 'minutes' and k ~= 'noRepeat' and k ~= 'scale' then return nil, 'err.control_value' end
    end
    return { minutes = m, scale = sc, noRepeat = (nr == true or nr == 1) and 1 or 0 }
end

-- The scale a saved happy hour runs at (a row with none is the old fixed 0: no cooldowns).
local function ScaleOf(value)
    local sc = type(value) == 'table' and tonumber(value.scale) or nil
    if sc == nil or sc ~= sc then return 0 end
    return math.min(SCALE_RANGE[2], math.max(SCALE_RANGE[1], sc))
end

-- A started happy hour keeps its length and scale when an admin narrows the bounds later (its end time is saved).
local function Clamp(value)
    if type(value) ~= 'table' or not math.tointeger(tonumber(value.minutes)) then return nil end
    return {
        minutes = math.tointeger(tonumber(value.minutes)),
        scale = ScaleOf(value),
        noRepeat = tonumber(value.noRepeat) == 1 and 1 or 0,
    }
end

-- It relaxes a rule (the self rule applies) while it lowers the cooldowns or switches no-repeat off.
local function Relaxes(value)
    return ScaleOf(value) < 1 or (type(value) == 'table' and tonumber(value.noRepeat) == 1)
end

-- One running at a time; a supervisor only perDay a day.
local function Allow(ctx)
    if ctx.row then return 'err.happy_hour_running' end
    if ctx.role == 'supervisor' and HH.usedToday() >= HH.perDay() then
        return 'err.happy_hour_used', { perDay = HH.perDay() }
    end
    return nil
end

-- While it runs: every mission type's cooldown x its scale.
local function ScaledCooldowns(value)
    local out, sc = {}, ScaleOf(value)
    for k, t in pairs(type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}) do
        if type(k) == 'string' and type(t) == 'table' then out[k] = sc end
    end
    return out
end

function HH.register()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    return dc.register(KEY, {
        kind = 'map',
        serverWide = true,
        master = false,
        integer = true,
        range = MINUTES_RANGE,
        configValue = function() return {} end,
        check = Check,
        clamp = Clamp,
        relaxes = Relaxes,
        duration = function(v) return v.minutes * 60 end,
        allow = Allow,
        numbers = {
            { name = 'scaleMin', range = SCALE_RANGE },
            { name = 'scaleMax', range = SCALE_RANGE },
            { name = 'perDay', range = PER_DAY_RANGE, integer = true },
        },
        overlays = {
            cooldownScale = function(_, hh) return ScaledCooldowns(hh) end,
            noRepeat = function(v, hh)
                if tonumber(hh.noRepeat) == 1 then return false end
                return v
            end,
        },
        viewExtra = function()
            local lo, hi = HH.scaleBounds()
            return { perDay = HH.perDay(), usedToday = HH.usedToday(), scaleMin = lo, scaleMax = hi }
        end,
        -- the 'Your controls today' card (DC.mine): the count Allow checks (happy hours started today)
        usedToday = function() return HH.usedToday() end,
    })
end
HH.register()

-- ============================================================================
--                               HAPPY HOUR CASH
-- ============================================================================
-- happyHourCash (Config.MissionControls.controls): per department, under the master switch, shipped off with
-- min = max = 1.0. x the cash of a completed run the department leads that was accepted while a happy hour ran; read
-- at the accept (scope run) and fixed in run.controls.cashBonus, so the end of the hour never cuts a live run.
local CASH_KEY = 'happyHourCash'
local CASH_RANGE = { 1, 3 }

function HH.registerCash()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    return dc.register(CASH_KEY, {
        kind = 'number',
        scope = 'run',
        range = CASH_RANGE,
        configValue = function() return 1.0 end,
        relaxes = function(v) return tonumber(v) ~= nil and v > 1 end,
    })
end
HH.registerCash()

-- The bonus of a run accepted now: value (the department's happyHourCash or happyHourPoints, read for the leader's
-- unit) while a happy hour runs that applies to the unit (the one who started it and a unit he is in get none), else
-- nil.
local function BonusFor(value, members)
    local v = tonumber(value)
    if v == nil or v ~= v or v <= 1 or v > CASH_RANGE[2] then return nil end
    local dc = CP.DeptControls
    if not (dc and dc.get and dc.def and dc.def(KEY)) then return nil end
    local hv, row = dc.get(nil, KEY)
    if type(row) ~= 'table' or type(hv) ~= 'table' or not row.expiresAt or row.expiresAt <= os.time() then
        return nil
    end
    if dc.heldBy and dc.heldBy({ members = members }, row) == true then return nil end
    return v
end
HH.cashBonusFor = BonusFor

-- ============================================================================
--                              HAPPY HOUR POINTS
-- ============================================================================
-- happyHourPoints (Config.MissionControls.controls): per department, under the master switch, shipped off with
-- min = max = 1.0. x the final points of a completed run the department leads that was accepted while a happy hour
-- ran; read at the accept (scope run) and fixed in run.controls.pointsBonus (CP.Scoring.compute applies it).
local POINTS_KEY = 'happyHourPoints'

function HH.registerPoints()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    return dc.register(POINTS_KEY, {
        kind = 'number',
        scope = 'run',
        range = CASH_RANGE,
        configValue = function() return 1.0 end,
        relaxes = function(v) return tonumber(v) ~= nil and v > 1 end,
    })
end
HH.registerPoints()

-- The points bonus of a run accepted now (the same rule as the cash bonus), else nil.
HH.pointsBonusFor = BonusFor

-- "Sgt Doe": the rank and name of the officer who started it while he is online, else nil (the screens say who by
-- role then).
local function NameOf(cid)
    if type(cid) ~= 'string' or not (CP.Qbx and CP.Qbx.getByCitizenId and CP.Access) then return nil end
    local ok, src = pcall(CP.Qbx.getByCitizenId, cid)
    if not ok or not src then return nil end
    local okO, o = pcall(CP.Access.getOfficer, src)
    if not okO or type(o) ~= 'table' then return nil end
    return ('%s %s'):format(o.rank or '', o.name or ''):gsub('^%s+', '')
end

-- The happy hour running now, as the officer screens show it, or nil. officer (an officer table): self = true when
-- it does not apply to him (he started it, Config.MissionControls.selfExempt).
-- { endsAt, left (seconds), minutes, scale (x every cooldown, 0 = none), noRepeat, by, byRole, self }
function HH.state(officer)
    local dc = CP.DeptControls
    if not (dc and dc.get and dc.def and dc.def(KEY)) then return nil end
    local v, row = dc.get(nil, KEY)
    if type(row) ~= 'table' or not row.expiresAt or type(v) ~= 'table' then return nil end
    return {
        endsAt = row.expiresAt,
        left = math.max(0, row.expiresAt - os.time()),
        minutes = v.minutes,
        scale = ScaleOf(v),
        noRepeat = tonumber(v.noRepeat) == 1,
        by = NameOf(row.setBy),
        byRole = row.setRole,
        self = dc.heldBy(officer, row) == true and Relaxes(v),
    }
end

-- Every online officer (and admin) hears the new state (push 'happyHour': the state or false).
function HH.pushAll()
    local T = CP.Tablet
    if not (T and T.push and CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Access) then return end
    local admins = {}
    if T.pushAdmins then
        T.pushAdmins('happyHour', HH.state(nil) or false)
        for _, n in ipairs(T.onlineAdmins and T.onlineAdmins() or {}) do admins[n] = true end
    end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers() or {}) do
        local n = math.tointeger(tonumber(s))
        if n and not admins[n] then
            local o = CP.Access.getOfficer(n)
            if o then T.push(n, 'happyHour', HH.state(o) or false) end
        end
    end
end

-- Looks for a happy hour that ran out (no one changed the control): the caches and the screens hear it.
function HH._tick()
    local s = HH.state(nil)
    local now = s and s.endsAt or 0
    if last ~= nil and now ~= last and now == 0 and CP.DeptControls.expired then
        CP.DeptControls.expired(WHERE, KEY)   -- fires deptControls:changed, which pushes
    end
    last = now
end

-- The end check runs only while a happy hour may be on (it woke every 30 s all day): at start (a happy
-- hour from before a restart), when one starts and when Settings re-reads the controls. Each pass is TICK_MS apart
-- as before; once no happy hour runs, the loop ends until the next of those.
local ticking = false

local function Arm()
    if ticking then return end
    ticking = true
    CreateThread(function()
        -- a failed start (a migration, the saves folder): end quietly, as the other loops do
        if CP.Migrations and CP.Migrations.started and not CP.Migrations.started() then
            ticking = false
            return
        end
        while true do
            Wait(CP.Perf.ms(TICK_MS))
            local ok, err = pcall(HH._tick)
            if not ok then CP.err(TAG, 'check failed: %s', tostring(err)) end
            if ok and last == 0 then break end
        end
        ticking = false
    end)
end
HH._arm = Arm

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('deptControls:changed', function(e)
        if type(e) ~= 'table' or e.key ~= KEY then return end
        local s = HH.state(nil)
        last = s and s.endsAt or 0
        HH.pushAll()
        if last ~= 0 then Arm() end
    end)
    -- Settings may make the controls be read again (DC.clearCache): one pass sees a happy hour that is on
    CP.Hooks.on('settings:changed', function() Arm() end)
end

Arm()

-- Test hooks (not part of the contract).
HH._reset = function() last = nil end
HH._ticking = function() return ticking end
