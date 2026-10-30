-- CP.Payouts (server): editable base cash payouts per mission type and per mission, the supervisor limits and the
-- Payouts screens of the Supervisor UI and the Admin UI.

CP.Payouts = CP.Payouts or {}
local Payouts = CP.Payouts
local TAG = 'payouts'

local BOSS_ID = 'weekly_boss_kingpin'
local REASON_MAX = 255
local TYPE_KEY_MAX = 32
local MISSION_ID_MAX = 40

local typeRows = {}       -- mission_type -> { amount, adminLocked, updatedBy, updatedByName, updatedTs }
local missionRows = {}    -- mission_id -> { amount, setBy, setByName, updatedTs }
local loaded = false
local loading = false
local busy = {}           -- 'type:<key>' / 'mission:<id>' while a write is in flight

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

local function TypeCfg(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    if type(t) == 'table' then return t end
    return nil
end

local function CashLimits()
    local c = Config.Cash or {}
    local lo = math.floor(Num(c.minPayout, 0))
    local hi = math.floor(Num(c.maxPayout, 25000))
    if hi < lo then hi = lo end
    return lo, hi
end

local function StarMultiplier(difficulty)
    local stars = Config.Difficulty and Config.Difficulty.cashByStars
    local d = math.floor(Num(difficulty, 1))
    if d < 1 then d = 1 end
    if d > 3 then d = 3 end
    return Num(stars and stars[d], 1.0)
end

local function IsBoss(mission)
    return type(mission) == 'table' and (mission.isBoss == true or mission.id == BOSS_ID)
end

local function BossPayout()
    local b = Config.Events and Config.Events.weeklyBoss
    return math.max(0, math.floor(Num(b and b.payout, 0) + 0.5))
end

-- Config.Payouts.supervisorRange as (low share, high share).
local function RangeShares()
    local r = Config.Payouts and Config.Payouts.supervisorRange or {}
    local loShare, hiShare = Num(r[1], 0.5), Num(r[2], 2.0)
    if hiShare < loShare then loShare, hiShare = hiShare, loShare end
    return loShare, hiShare
end

-- Supervisor range for a type: share of its Config.MissionTypes payout, inside the overall range.
local function SupervisorRange(key)
    local cfg = TypeCfg(key)
    local default = math.floor(Num(cfg and cfg.payout, 0))
    local loShare, hiShare = RangeShares()
    local lo = math.ceil(default * loShare - 1e-9)
    local hi = math.floor(default * hiShare + 1e-9)
    local cLo, cHi = CashLimits()
    if lo < cLo then lo = cLo end
    if hi > cHi then hi = cHi end
    if hi < lo then hi = lo end
    return lo, hi, loShare, hiShare
end

local function CooldownSeconds()
    return math.max(0, math.floor(Num(Config.Payouts and Config.Payouts.supervisorCooldown, 1800)))
end

local function ReasonRequired(role)
    if role == 'supervisor' then
        return true
    end -- SPEC: a supervisor must always give a reason
    return not (Config.Payouts and Config.Payouts.requireReason == false)
end

local function ActorId(src)
    if src == 0 then return 'console' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if info and info.citizenid then return CP.U.clip(info.citizenid, 50) end
    return CP.U.clip(('player:%d'):format(src), 50)
end

-- ============================================================================
--                                    CACHE
-- ============================================================================

local function Load()
    Db()
    local okT, rows = pcall(MySQL.query.await, [[
        SELECT t.mission_type, t.amount, t.admin_locked, t.updated_by, UNIX_TIMESTAMP(t.updated_at) AS updated_ts,
               o.display_name
        FROM cp_type_payouts t LEFT JOIN cp_officers o ON o.citizenid = t.updated_by
    ]], {})
    local okM, mrows = pcall(MySQL.query.await, [[
        SELECT m.mission_id, m.amount, m.set_by, UNIX_TIMESTAMP(m.updated_at) AS updated_ts, o.display_name
        FROM cp_mission_payouts m LEFT JOIN cp_officers o ON o.citizenid = m.set_by
    ]], {})
    if not okT or not okM then
        CP.err(TAG, 'loading the stored payouts failed: %s', tostring(okT and mrows or rows))
        return false
    end
    local t, m = {}, {}
    for _, r in ipairs(rows or {}) do
        if type(r.mission_type) == 'string' then
            t[r.mission_type] = {
                amount = math.floor(CP.U.num(r.amount)),
                adminLocked = CP.U.truthy(r.admin_locked),
                updatedBy = r.updated_by,
                updatedByName = type(r.display_name) == 'string' and r.display_name or nil,
                updatedTs = tonumber(r.updated_ts),
            }
            if not TypeCfg(r.mission_type) then
                CP.warn(TAG, 'cp_type_payouts has a payout for unknown mission type %s; it is ignored', r.mission_type)
            end
        end
    end
    for _, r in ipairs(mrows or {}) do
        if type(r.mission_id) == 'string' then
            m[r.mission_id] = {
                amount = math.floor(CP.U.num(r.amount)),
                setBy = r.set_by,
                setByName = type(r.display_name) == 'string' and r.display_name or nil,
                updatedTs = tonumber(r.updated_ts),
            }
        end
    end
    typeRows, missionRows, loaded = t, m, true
    CP.log(TAG, 'loaded %d type payout(s) and %d mission payout(s)', CP.U.count(t), CP.U.count(m))
    return true
end

local function EnsureLoaded()
    if loaded then return end
    if loading then
        local waited = 0
        while loading and waited < 10000 do Wait(50); waited = waited + 50 end
        if loaded then return end
    end
    loading = true
    local ok, err = pcall(Load)
    loading = false
    if not ok then CP.err(TAG, 'payout cache load failed: %s', tostring(err)) end
end

-- ============================================================================
--                                   LOOKUPS
-- ============================================================================

function Payouts.typePayout(key)
    EnsureLoaded()
    local cfg = TypeCfg(key)
    if not cfg then return 0, false end
    local row = typeRows[key]
    if row then return row.amount, row.adminLocked == true end
    return math.max(0, math.floor(Num(cfg.payout, 0) + 0.5)), false
end

function Payouts.missionPayout(missionId)
    if type(missionId) ~= 'string' then return nil end
    EnsureLoaded()
    local row = missionRows[missionId]
    return row and row.amount or nil
end

-- B without an admin mission payout (the type or event payout).
local function FallbackBase(mission)
    if IsBoss(mission) then return BossPayout() end
    local amount = Payouts.typePayout(mission.type)
    return math.max(0, math.floor(amount * StarMultiplier(mission.difficulty) + 0.5))
end

function Payouts.baseFor(mission)
    if type(mission) ~= 'table' then return 0 end
    local m = Payouts.missionPayout(mission.id)
    if m then return m end
    return FallbackBase(mission)
end

function Payouts.sourceFor(mission)
    if type(mission) ~= 'table' then return 'type' end
    if Payouts.missionPayout(mission.id) then return 'admin' end
    if IsBoss(mission) then return 'event' end
    return 'type'
end

local function MissionDefs()
    if CP.Missions and CP.Missions.list then
        local ok, list = pcall(CP.Missions.list)
        if ok and type(list) == 'table' then return list end
    end
    return {}
end

local OutOfRange

local function TypeEntry(key, counts)
    local cfg = TypeCfg(key)
    local row = typeRows[key]
    local amount, locked = Payouts.typePayout(key)
    local lo, hi = SupervisorRange(key)
    local left = 0
    if row and not row.adminLocked and row.updatedTs then
        left = math.max(0, CooldownSeconds() - (Now() - row.updatedTs))
    end
    return {
        key = key,
        label = cfg and cfg.label or key,
        points = math.floor(Num(cfg and cfg.points, 0)),
        amount = amount,
        default = math.floor(Num(cfg and cfg.payout, 0)),
        adminLocked = locked,
        stored = row ~= nil,
        updatedBy = row and row.updatedBy or nil,
        updatedByName = row and row.updatedByName or nil,
        updatedAt = row and row.updatedTs or nil,
        supMin = lo,
        supMax = hi,
        cooldownLeft = left,
        missions = counts and counts[key] or 0,
        outOfRange = row ~= nil and OutOfRange(row.amount) or nil,
    }
end

-- A stored payout outside Cash.minPayout-maxPayout (the range changed after it was set): it still pays as set.
OutOfRange = function(amount)
    local lo, hi = CashLimits()
    local n = tonumber(amount)
    return n ~= nil and (n < lo or n > hi)
end

local function MissionEntry(def)
    local row = missionRows[def.id]
    local typeLabel = TypeCfg(def.type) and TypeCfg(def.type).label or tostring(def.type)
    local enabled = true
    if CP.Missions and CP.Missions.isEnabled then
        local ok, e = pcall(CP.Missions.isEnabled, def.id)
        enabled = ok and e == true
    end
    return {
        id = def.id,
        label = def.label or def.id,
        type = def.type,
        typeLabel = typeLabel,
        difficulty = math.floor(Num(def.difficulty, 1)),
        source = def.source == 'custom' and 'custom' or 'builtin',
        isBoss = IsBoss(def),
        enabled = enabled,
        base = Payouts.baseFor(def),
        payoutSource = Payouts.sourceFor(def),
        missionPayout = row and row.amount or nil,
        outOfRange = row ~= nil and OutOfRange(row.amount) or nil,
        fallback = FallbackBase(def),
        setBy = row and row.setBy or nil,
        setByName = row and row.setByName or nil,
        updatedAt = row and row.updatedTs or nil,
        missing = false,
    }
end

local function SortedTypeKeys()
    local keys = CP.U.keys(Config.MissionTypes or {})
    table.sort(keys, function(a, b)
        local pa, pb = Num(Config.MissionTypes[a].points, 0), Num(Config.MissionTypes[b].points, 0)
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return keys
end

function Payouts.list()
    EnsureLoaded()
    local defs = MissionDefs()
    local counts, seen = {}, {}
    local missions = {}
    for _, def in ipairs(defs) do
        if type(def) == 'table' and type(def.id) == 'string' then
            seen[def.id] = true
            if not IsBoss(def) then counts[def.type] = (counts[def.type] or 0) + 1 end
            missions[#missions + 1] = MissionEntry(def)
        end
    end
    -- Stored payouts of missions that are not loaded (archived, deleted file): listed so an admin can clear them.
    for id, row in pairs(missionRows) do
        if not seen[id] then
            missions[#missions + 1] = {
                id = id,
                label = id,
                type = nil,
                typeLabel = nil,
                difficulty = 1,
                source = 'custom',
                isBoss = false,
                enabled = false,
                base = row.amount,
                payoutSource = 'admin',
                missionPayout = row.amount,
                fallback = 0,
                setBy = row.setBy,
                setByName = row.setByName,
                updatedAt = row.updatedTs,
                missing = true,
            }
        end
    end
    local typeOrder = {}
    for i, k in ipairs(SortedTypeKeys()) do typeOrder[k] = i end
    table.sort(missions, function(a, b)
        local ta, tb = typeOrder[a.type or ''] or 99, typeOrder[b.type or ''] or 99
        if a.isBoss ~= b.isBoss then return not a.isBoss end
        if ta ~= tb then return ta < tb end
        return tostring(a.label) < tostring(b.label)
    end)
    local types = {}
    for _, key in ipairs(SortedTypeKeys()) do types[#types + 1] = TypeEntry(key, counts) end
    return { types = types, missions = missions }
end

-- ============================================================================
--                                 AUDIT, PUSH
-- ============================================================================

local function Audit(src, role, action, target, old, new, reason)
    local auditRole = src == 0 and 'console' or role
    local oldS, newS = CP.U.clip(tostring(old), 64), CP.U.clip(tostring(new), 64)
    if CP.Admin and CP.Admin.audit then
        local ok, err = pcall(CP.Admin.audit, src, auditRole, 'audit', action, CP.U.clip(target, 64), oldS, newS,
            reason)
        if ok then return end
        CP.err(TAG, 'CP.Admin.audit failed: %s', tostring(err))
    end
    -- modules/admin unavailable: keep the audit trail anyway (no webhook).
    local ok, err = pcall(MySQL.insert.await,
        'INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason) VALUES (?, ?, \'audit\', ?, ?, ?, ?, ?)',
        { ActorId(src), auditRole, CP.U.clip(action, 40), CP.U.clip(target, 64), oldS, newS, reason or '' })
    if not ok then CP.err(TAG, 'audit insert failed: %s', tostring(err)) end
end

local function PushChange(data)
    if not (CP.Tablet and CP.Tablet.push and CP.Qbx and CP.Qbx.getOnlinePlayers) then return end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
        CP.Tablet.push(s, 'payouts', data)
        CP.Tablet.push(s, 'board', { reason = 'payouts' })
    end
end

-- ============================================================================
--                                  VALIDATION
-- ============================================================================

local function CleanReason(reason, role)
    if reason ~= nil and type(reason) ~= 'string' then return nil, 'err.invalid_payload' end
    local r = reason and CP.U.trim(reason) or ''
    -- Characters, not bytes: the Payouts screens' maxLength and cp_audit.reason (VARCHAR(255) utf8mb4) count
    -- characters, so an accented 200-character reason is valid.
    local len = utf8.len(r)
    if not len then return nil, 'err.invalid_payload' end
    if len > REASON_MAX then return nil, 'err.reason_too_long' end
    if r == '' and ReasonRequired(role) then return nil, 'err.reason_required' end
    return r
end

local function CleanAmount(amount)
    local n = tonumber(amount)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil, 'err.invalid_amount' end
    if math.floor(n) ~= n then return nil, 'err.invalid_amount' end
    n = math.floor(n)
    local lo, hi = CashLimits()
    if n < lo or n > hi then return nil, 'err.payout_out_of_range' end
    return n
end

local function Lock(key)
    if busy[key] then return false end
    busy[key] = true
    return true
end

local function Unlock(key) busy[key] = nil end

-- ============================================================================
--                                    WRITES
-- ============================================================================

local function WriteType(key, amount, adminLocked, actor)
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_type_payouts (mission_type, amount, admin_locked, updated_by, updated_at)
        VALUES (?, ?, ?, ?, FROM_UNIXTIME(?))
        ON DUPLICATE KEY UPDATE amount = VALUES(amount), admin_locked = VALUES(admin_locked),
            updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)
    ]], { key, amount, adminLocked and 1 or 0, actor, Now() })
    if not ok then CP.err(TAG, 'saving the %s payout failed: %s', key, tostring(err)) end
    return ok
end

-- opts.unlock (admins): the amount is set and the type stays open to supervisors, within their range again.
local function SetTypeLocked(src, key, amount, reason, role, opts)
    opts = type(opts) == 'table' and opts or {}
    EnsureLoaded()
    local row = typeRows[key]
    local oldAmount = Payouts.typePayout(key)
    local actor = ActorId(src)

    if role == 'supervisor' then
        if row and row.adminLocked then return false, 'err.payout_locked' end
        local lo, hi = SupervisorRange(key)
        if amount < lo or amount > hi then return false, 'err.payout_out_of_range' end
        if row and row.updatedTs and Now() - row.updatedTs < CooldownSeconds() then
            return false, 'err.payout_cooldown'
        end
        if amount == oldAmount then return false, 'err.payout_unchanged' end
        if not WriteType(key, amount, false, actor) then return false, 'err.internal' end
        Audit(src, 'supervisor', 'setTypePayout', key, oldAmount, amount, reason)
    else
        if amount == nil then
            if not row then return false, 'err.payout_unchanged' end
            local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_type_payouts WHERE mission_type = ?', { key })
            if not ok then
                CP.err(TAG, 'clearing the %s payout failed: %s', key, tostring(err))
                return false, 'err.internal'
            end
            local cfgAmount = math.floor(Num(TypeCfg(key).payout, 0))
            Audit(src, 'admin', 'clearTypePayout', key, oldAmount, ('config:%d'):format(cfgAmount), reason)
        elseif opts.unlock then
            if row and not row.adminLocked and row.amount == amount then return false, 'err.payout_unchanged' end
            if not WriteType(key, amount, false, actor) then return false, 'err.internal' end
            Audit(src, 'admin', 'setTypePayout', key, oldAmount, ('unlocked:%d'):format(amount), reason)
        else
            if row and row.adminLocked and row.amount == amount then return false, 'err.payout_unchanged' end
            if not WriteType(key, amount, true, actor) then return false, 'err.internal' end
            Audit(src, 'admin', 'setTypePayout', key, oldAmount, amount, reason)
        end
    end
    Load()
    CP.log(TAG, '%s payout %s -> %s by %s (%s)', key, tostring(oldAmount), tostring(amount), actor, role)
    PushChange({ kind = 'type', key = key })
    return true, TypeEntry(key, nil)
end

function Payouts.setType(src, key, amount, reason, role, opts)
    src = ToSrc(src)
    if not src then return false, 'err.no_permission' end
    if type(key) ~= 'string' or #key > TYPE_KEY_MAX or not TypeCfg(key) then return false, 'err.unknown_type' end
    if role ~= 'admin' and role ~= 'supervisor' then
        role = (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) and 'admin' or 'supervisor'
    end
    if not CP.Permissions or not CP.Permissions.can then return false, 'err.no_permission' end
    if role == 'admin' then
        if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return false, 'err.no_permission' end
        local action = amount == nil and 'clearPayout' or 'setTypePayout'
        local ok, errKey = CP.Permissions.can(src, action)
        if not ok then return false, errKey or 'err.no_permission' end
    else
        local ok, errKey = CP.Permissions.can(src, 'setTypePayout')
        if not ok then return false, errKey or 'err.no_permission' end
        if amount == nil then return false, 'err.invalid_amount' end
    end
    local value = nil
    if amount ~= nil then
        local n, errKey = CleanAmount(amount)
        if not n then return false, errKey end
        value = n
    end
    local r, errKey = CleanReason(reason, role)
    if not r then return false, errKey end

    local lk = 'type:' .. key
    if not Lock(lk) then return false, 'err.busy' end
    if role ~= 'admin' then opts = nil end
    local okCall, ok, res = pcall(SetTypeLocked, src, key, value, r, role, opts)
    Unlock(lk)
    if not okCall then
        CP.err(TAG, 'setType failed: %s', tostring(ok))
        return false, 'err.internal'
    end
    return ok, res
end

local function MissionEntryById(id)
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(id)
    if def then return MissionEntry(def) end
    for _, e in ipairs(Payouts.list().missions) do
        if e.id == id then return e end
    end
    return nil
end

local function SetMissionLocked(src, missionId, amount, reason)
    EnsureLoaded()
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(missionId)
    local row = missionRows[missionId]
    if not def and not row then return false, 'err.unknown_mission' end
    if not def and amount ~= nil then return false, 'err.unknown_mission' end
    local oldAmount = row and row.amount or nil
    local oldText = oldAmount and tostring(oldAmount)
        or ('%s:%d'):format(def and (IsBoss(def) and 'event' or 'type') or 'none', def and FallbackBase(def) or 0)
    local actor = ActorId(src)
    if amount == nil then
        if not row then return false, 'err.payout_unchanged' end
        local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_mission_payouts WHERE mission_id = ?', { missionId })
        if not ok then
            CP.err(TAG, 'clearing the payout of %s failed: %s', missionId, tostring(err))
            return false, 'err.internal'
        end
        Audit(src, 'admin', 'clearMissionPayout', missionId, oldText,
            def and ('%s:%d'):format(IsBoss(def) and 'event' or 'type', FallbackBase(def)) or 'none', reason)
    else
        if oldAmount == amount then return false, 'err.payout_unchanged' end
        local ok, err = pcall(MySQL.query.await, [[
            INSERT INTO cp_mission_payouts (mission_id, amount, set_by, updated_at) VALUES (?, ?, ?, FROM_UNIXTIME(?))
            ON DUPLICATE KEY UPDATE amount = VALUES(amount), set_by = VALUES(set_by), updated_at = VALUES(updated_at)
        ]], { missionId, amount, actor, Now() })
        if not ok then
            CP.err(TAG, 'saving the payout of %s failed: %s', missionId, tostring(err))
            return false, 'err.internal'
        end
        Audit(src, 'admin', 'setMissionPayout', missionId, oldText, amount, reason)
    end
    Load()
    CP.log(TAG, 'mission %s payout %s -> %s by %s', missionId, tostring(oldAmount), tostring(amount), actor)
    PushChange({ kind = 'mission', missionId = missionId })
    return true, MissionEntryById(missionId) or { id = missionId, missionPayout = amount }
end

function Payouts.setMission(src, missionId, amount, reason)
    src = ToSrc(src)
    if not src then return false, 'err.no_permission' end
    if type(missionId) ~= 'string' or missionId == '' or #missionId > MISSION_ID_MAX
        or not missionId:match('^[%w_%-]+$') then
        return false, 'err.unknown_mission'
    end
    if not CP.Permissions or not CP.Permissions.can then return false, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, amount == nil and 'clearPayout' or 'setMissionPayout')
    if not ok then return false, errKey or 'err.no_permission' end
    local value = nil
    if amount ~= nil then
        local n, e = CleanAmount(amount)
        if not n then return false, e end
        value = n
    end
    local r, e = CleanReason(reason, 'admin')
    if not r then return false, e end

    local lk = 'mission:' .. missionId
    if not Lock(lk) then return false, 'err.busy' end
    local okCall, res1, res2 = pcall(SetMissionLocked, src, missionId, value, r)
    Unlock(lk)
    if not okCall then
        CP.err(TAG, 'setMission failed: %s', tostring(res1))
        return false, 'err.internal'
    end
    return res1, res2
end

-- ============================================================================
--                       ADJUST ALL (ADMIN UI → PAYOUTS)
-- ============================================================================
-- One change for many payouts: a percentage (-90..+500, the maths in Lua) or a fixed amount, applied to every type
-- payout and/or every admin mission payout, each new value clamped to Cash.minPayout-maxPayout. The preview shows
-- old -> new and gives the token the action needs; every value then goes through Payouts.setType / setMission, so
-- every check, audit line and push still runs.

local ADJUST_PCT_MIN, ADJUST_PCT_MAX = -90, 500

-- The entries of an adjustment: { key = 'type:<k>' | 'mission:<id>', kind, id, label, old, new } | nil, errKey.
local function AdjustPlan(args)
    if type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local mode, value = args.mode, tonumber(args.value)
    if mode ~= 'pct' and mode ~= 'amount' then return nil, 'err.invalid_payload' end
    if not value or value ~= value or value == math.huge or value == -math.huge then
        return nil, 'err.invalid_amount'
    end
    if mode == 'pct' and (value < ADJUST_PCT_MIN or value > ADJUST_PCT_MAX) then return nil, 'err.invalid_amount' end
    if mode == 'amount' and (math.floor(value) ~= value or math.abs(value) > 10000000) then
        return nil, 'err.invalid_amount'
    end
    local scope = args.scope or 'types'
    if scope ~= 'types' and scope ~= 'missions' and scope ~= 'both' then return nil, 'err.invalid_payload' end
    EnsureLoaded()
    local lo, hi = CashLimits()
    local function newOf(old)
        local n
        if mode == 'pct' then n = math.floor(old * (100 + value) / 100 + 0.5) else n = old + math.floor(value) end
        if n < lo then n = lo end
        if n > hi then n = hi end
        return n
    end
    local out = {}
    if scope ~= 'missions' then
        for _, key in ipairs(SortedTypeKeys()) do
            local old, locked = Payouts.typePayout(key)
            local cfg = TypeCfg(key)
            out[#out + 1] = {
                key = 'type:' .. key,
                kind = 'type',
                id = key,
                label = cfg and cfg.label or key,
                old = old,
                new = newOf(old),
                locked = locked == true,
            }
        end
    end
    if scope ~= 'types' then
        local ids = CP.U.keys(missionRows)
        table.sort(ids)
        for _, id in ipairs(ids) do
            local def = CP.Missions and CP.Missions.get and CP.Missions.get(id)
            if def then
                local old = missionRows[id].amount
                out[#out + 1] = {
                    key = 'mission:' .. id,
                    kind = 'mission',
                    id = id,
                    label = def.label or id,
                    old = old,
                    new = newOf(old),
                }
            end
        end
    end
    return out
end

-- The ids a preview token is bound to: every entry with its old value, so a payout changed since the preview
-- makes the token stale.
local function PlanIds(plan)
    local ids = {}
    for _, e in ipairs(plan) do ids[#ids + 1] = ('%s=%d'):format(e.key, e.old) end
    return ids
end

function Payouts.previewAdjust(src, args)
    local plan, err = AdjustPlan(args)
    if not plan then return nil, err end
    local changes = {}
    for _, e in ipairs(plan) do if e.new ~= e.old then changes[#changes + 1] = e end end
    local token, expiresAt = CP.AdminKit.preview(src, 'payoutsAdjust', PlanIds(plan), { count = #changes })
    return { previewToken = token, expiresAt = expiresAt, effect = { rows = changes, total = #plan } }
end

-- ok, { changed, failed } | false, errKey. ctx: the CP.AdminKit action context.
function Payouts.adjustAll(ctx)
    local p = ctx.payload
    local plan, err = AdjustPlan(p)
    if not plan then return false, err end
    local okT, errT = ctx.consume(p.previewToken, 'payoutsAdjust', PlanIds(plan))
    if not okT then return false, errT end
    local changed, failed = 0, 0
    for _, e in ipairs(plan) do
        if e.new ~= e.old then
            local ok
            if e.kind == 'type' then
                -- lockTypes: every type becomes admin-locked; otherwise each type keeps its lock state
                local unlock = p.lockTypes ~= true and not e.locked
                ok = Payouts.setType(ctx.src, e.id, e.new, ctx.reason, 'admin', { unlock = unlock })
            else
                ok = Payouts.setMission(ctx.src, e.id, e.new, ctx.reason)
            end
            if ok then changed = changed + 1 else failed = failed + 1 end
        end
    end
    local what = p.mode == 'pct' and ('%+g%%'):format(tonumber(p.value))
        or ('%+d'):format(math.floor(tonumber(p.value)))
    ctx.audit('payoutsAdjustAll', tostring(p.scope or 'types'), nil, ('%s (%d changed)'):format(what, changed))
    return true, { changed = changed, failed = failed }
end

-- ============================================================================
--                                   SCREENS
-- ============================================================================

local function SupView()
    local data = Payouts.list()
    local loShare, hiShare = RangeShares()
    local types = {}
    for _, e in ipairs(data.types) do
        types[#types + 1] = {
            key = e.key,
            label = e.label,
            amount = e.amount,
            default = e.default,
            min = e.supMin,
            max = e.supMax,
            adminLocked = e.adminLocked,
            cooldownLeft = e.adminLocked and 0 or e.cooldownLeft,
            updatedByName = e.updatedByName,
            updatedAt = e.updatedAt,
            stored = e.stored,
            canEdit = not e.adminLocked and e.cooldownLeft <= 0,
        }
    end
    local lo, hi = CashLimits()
    return {
        types = types,
        rangeShare = { min = loShare, max = hiShare },
        cooldownSeconds = CooldownSeconds(),
        requireReason = true,
        limits = { min = lo, max = hi },
        serverTime = Now(),
    }
end

local function AdminView()
    local data = Payouts.list()
    local lo, hi = CashLimits()
    local outside = 0
    for _, e in ipairs(data.types) do if e.outOfRange then outside = outside + 1 end end
    for _, e in ipairs(data.missions) do if e.outOfRange then outside = outside + 1 end end
    return {
        types = data.types,
        missions = data.missions,
        outOfRange = outside,
        supervisorRange = { RangeShares() },
        limits = { min = lo, max = hi },
        requireReason = ReasonRequired('admin'),
        cooldownSeconds = CooldownSeconds(),
        serverTime = Now(),
    }
end

CP.Net.callback('sup:getPayouts', function(src)
    local ok, errKey = CP.Permissions.can(src, 'setTypePayout')
    if not ok then return nil, errKey or 'err.no_permission' end
    return SupView()
end)

CP.Net.callback('admin:getPayouts', function(src)
    if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return nil, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, 'setMissionPayout')
    if not ok then return nil, errKey or 'err.no_permission' end
    return AdminView()
end)

-- Payload helpers: nil / JSON null / clear = true mean "clear" on the admin paths.
local function PayloadAmount(payload)
    if payload.clear == true then return nil, true end
    if payload.amount == nil then return nil, true end
    if type(payload.amount) ~= 'number' then return nil, false end
    return payload.amount, true
end

CP.Net.action('server:sup:setTypePayout', function(src, payload)
    if type(payload) ~= 'table' or type(payload.type) ~= 'string' or type(payload.amount) ~= 'number' then
        return false, 'err.invalid_payload'
    end
    if payload.reason ~= nil and type(payload.reason) ~= 'string' then return false, 'err.invalid_payload' end
    local ok, res = Payouts.setType(src, payload.type, payload.amount, payload.reason, 'supervisor')
    if not ok then return false, res end
    return true,
        {
            key = res.key,
            label = res.label,
            amount = res.amount,
            default = res.default,
            min = res.supMin,
            max = res.supMax,
            adminLocked = res.adminLocked,
            cooldownLeft = res.cooldownLeft,
            updatedByName = res.updatedByName,
            updatedAt = res.updatedAt,
            stored = res.stored,
            canEdit = not res.adminLocked and res.cooldownLeft <= 0,
        }
end, { rate = 2 })

CP.Net.action('server:admin:setTypePayout', function(src, payload)
    if type(payload) ~= 'table' or type(payload.type) ~= 'string' then return false, 'err.invalid_payload' end
    if payload.reason ~= nil and type(payload.reason) ~= 'string' then return false, 'err.invalid_payload' end
    if payload.unlock ~= nil and type(payload.unlock) ~= 'boolean' then return false, 'err.invalid_payload' end
    local amount, valid = PayloadAmount(payload)
    if not valid then return false, 'err.invalid_payload' end
    if payload.unlock == true and amount == nil then return false, 'err.invalid_amount' end
    return Payouts.setType(src, payload.type, amount, payload.reason, 'admin', { unlock = payload.unlock == true })
end, { rate = 3 })

CP.Net.action('server:admin:setMissionPayout', function(src, payload)
    if type(payload) ~= 'table' or type(payload.missionId) ~= 'string' then return false, 'err.invalid_payload' end
    if payload.reason ~= nil and type(payload.reason) ~= 'string' then return false, 'err.invalid_payload' end
    local amount, valid = PayloadAmount(payload)
    if not valid then return false, 'err.invalid_payload' end
    return Payouts.setMission(src, payload.missionId, amount, payload.reason)
end, { rate = 3 })

-- ============================================================================
--                                    START
-- ============================================================================

-- Payout adjustments with a preview: admins only (supervisors never pass), request id, reason, typed ADJUST.
if CP.AdminKit and CP.AdminKit.action then
    CP.AdminKit.callback('admin:previewPayoutAdjust', 'setTypePayout', function(ctx)
        return Payouts.previewAdjust(ctx.src, ctx.args)
    end, { rate = 2 })
    CP.AdminKit.action('server:admin:adjustAllPayouts', 'setTypePayout', function(ctx)
        return Payouts.adjustAll(ctx)
    end, { requestId = true, reason = true, confirm = 'ADJUST', rate = 1 })
end

-- A payout setting changed in Settings (a type's Config default, the cash limits, the supervisor range): open
-- Supervisor and Admin screens get the new values.
local function OnSettingsChanged(paths)
    for _, path in ipairs(type(paths) == 'table' and paths or {}) do
        local head = tostring(path):match('^([%a]+)')
        if head == 'MissionTypes' or head == 'Cash' or head == 'Payouts' or path == 'Events.weeklyBoss.payout'
            or path == 'Difficulty.cashByStars' then
            PushChange({ kind = 'settings' })
            return
        end
    end
end

if CP.Hooks and CP.Hooks.on then CP.Hooks.on('settings:changed', OnSettingsChanged) end

CreateThread(function()
    EnsureLoaded()
end)

-- Test hooks (not part of the contract).
Payouts._reload = function() loaded = false; EnsureLoaded() end
Payouts._supervisorRange = SupervisorRange
Payouts._supView = SupView
Payouts._adminView = AdminView
Payouts._onSettingsChanged = OnSettingsChanged
