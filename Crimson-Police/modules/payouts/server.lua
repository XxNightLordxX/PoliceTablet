-- modules/payouts/server.lua · CP.Payouts (server): editable base cash payouts per mission type and per
-- mission, the supervisor limits and the Payouts screens of the Supervisor UI and the Admin UI.
--
-- Owns
--   * cp_type_payouts (one row per type an admin or a supervisor has changed; admin_locked = 1 when an
--     admin set it: permanent and read-only for supervisors) and cp_mission_payouts (admin only,
--     permanent until an admin clears it), both cached in memory and reloaded after every write
--   * the base payout B of a mission (SPEC "Cash payouts"): the admin mission payout if set; the Weekly
--     Boss's Config.Events.weeklyBoss.payout otherwise; else the type payout x Config.Difficulty.cashByStars
--   * who may change what: supervisors change a type (never one an admin set) only within
--     Config.Payouts.supervisorRange of its Config.MissionTypes payout, at most once per
--     Config.Payouts.supervisorCooldown seconds per type (any supervisor, timed by updated_at), with a
--     reason; admins set any type or mission payout within Config.Cash.minPayout..maxPayout and are the
--     only ones who clear. Every change is audited (CP.Admin.audit, category 'audit', which also posts the
--     audit webhook) and pushed to open screens (topics 'payouts' and 'board').
--
-- Public API (docs/ARCHITECTURE.md §5.21)
--   CP.Payouts.typePayout(type) -> amount, adminLocked      stored amount, or the Config.MissionTypes payout
--   CP.Payouts.missionPayout(missionId) -> amount|nil        the admin mission payout
--   CP.Payouts.baseFor(mission) -> B                         whole dollars (halves up)
--   CP.Payouts.sourceFor(mission) -> 'admin'|'type'|'event'  where B comes from
--   CP.Payouts.setType(src, type, amount|nil, reason, role) -> ok, errKey|entry
--       role 'supervisor' | 'admin' (default: admin when src is an admin, else supervisor). amount nil =
--       clear (admin only). src 0 = the server console (admin). On success the second value is the
--       updated type entry of list().types.
--   CP.Payouts.setMission(src, missionId, amount|nil, reason) -> ok, errKey|entry   (admin only; nil = clear)
--   CP.Payouts.list() -> { types = { TypeEntry... }, missions = { MissionEntry... } }
--       TypeEntry    = { key, label, points, amount, default, adminLocked, stored, updatedBy, updatedByName,
--                        updatedAt (unix s)|nil, supMin, supMax, cooldownLeft (s), missions (count) }
--       MissionEntry = { id, label, type, typeLabel, difficulty, source ('builtin'|'custom'), isBoss,
--                        enabled, base, payoutSource ('admin'|'type'|'event'), missionPayout|nil,
--                        fallback (B without the mission payout), setBy|nil, setByName|nil,
--                        updatedAt|nil, missing (a stored payout whose mission is not loaded) }
-- Net (docs/notes/economy.md has the response shapes)
--   callback 'sup:getPayouts'   (permission setTypePayout)  -> SupPayoutsView
--   callback 'admin:getPayouts' (admin)                     -> AdminPayoutsView
--   action 'server:sup:setTypePayout'     { type, amount, reason }                 -> SupPayoutType
--   action 'server:admin:setTypePayout'   { type, amount (nil/clear = clear), reason } -> TypeEntry
--   action 'server:admin:setMissionPayout' { missionId, amount (nil/clear = clear), reason } -> MissionEntry
-- Every function that reads the tables may yield on the first call (cache load): call from a thread.

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

local function typeCfg(key)
    local t = Config.MissionTypes and Config.MissionTypes[key]
    if type(t) == 'table' then return t end
    return nil
end

local function cashLimits()
    local c = Config.Cash or {}
    local lo = math.floor(num(c.minPayout, 0))
    local hi = math.floor(num(c.maxPayout, 25000))
    if hi < lo then hi = lo end
    return lo, hi
end

local function starMultiplier(difficulty)
    local stars = Config.Difficulty and Config.Difficulty.cashByStars
    local d = math.floor(num(difficulty, 1))
    if d < 1 then d = 1 end
    if d > 3 then d = 3 end
    return num(stars and stars[d], 1.0)
end

local function isBoss(mission)
    return type(mission) == 'table' and (mission.isBoss == true or mission.id == BOSS_ID)
end

local function bossPayout()
    local b = Config.Events and Config.Events.weeklyBoss
    return math.max(0, math.floor(num(b and b.payout, 0) + 0.5))
end

-- Config.Payouts.supervisorRange as (low share, high share).
local function rangeShares()
    local r = Config.Payouts and Config.Payouts.supervisorRange or {}
    local loShare, hiShare = num(r[1], 0.5), num(r[2], 2.0)
    if hiShare < loShare then loShare, hiShare = hiShare, loShare end
    return loShare, hiShare
end

-- Supervisor range for a type: share of its Config.MissionTypes payout, inside the overall range.
local function supervisorRange(key)
    local cfg = typeCfg(key)
    local default = math.floor(num(cfg and cfg.payout, 0))
    local loShare, hiShare = rangeShares()
    local lo = math.ceil(default * loShare - 1e-9)
    local hi = math.floor(default * hiShare + 1e-9)
    local cLo, cHi = cashLimits()
    if lo < cLo then lo = cLo end
    if hi > cHi then hi = cHi end
    if hi < lo then hi = lo end
    return lo, hi, loShare, hiShare
end

local function cooldownSeconds()
    return math.max(0, math.floor(num(Config.Payouts and Config.Payouts.supervisorCooldown, 1800)))
end

local function reasonRequired(role)
    if role == 'supervisor' then return true end   -- SPEC: a supervisor must always give a reason
    return not (Config.Payouts and Config.Payouts.requireReason == false)
end

local function actorId(src)
    if src == 0 then return 'console' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if info and info.citizenid then return CP.U.clip(info.citizenid, 50) end
    return CP.U.clip(('player:%d'):format(src), 50)
end

-- ── cache ───────────────────────────────────────────────────────────────────
local function load()
    db()
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
            if not typeCfg(r.mission_type) then
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

local function ensureLoaded()
    if loaded then return end
    if loading then
        local waited = 0
        while loading and waited < 10000 do Wait(50); waited = waited + 50 end
        if loaded then return end
    end
    loading = true
    local ok, err = pcall(load)
    loading = false
    if not ok then CP.err(TAG, 'payout cache load failed: %s', tostring(err)) end
end

-- ── lookups ─────────────────────────────────────────────────────────────────
function Payouts.typePayout(key)
    ensureLoaded()
    local cfg = typeCfg(key)
    if not cfg then return 0, false end
    local row = typeRows[key]
    if row then return row.amount, row.adminLocked == true end
    return math.max(0, math.floor(num(cfg.payout, 0) + 0.5)), false
end

function Payouts.missionPayout(missionId)
    if type(missionId) ~= 'string' then return nil end
    ensureLoaded()
    local row = missionRows[missionId]
    return row and row.amount or nil
end

-- B without an admin mission payout (the type or event payout).
local function fallbackBase(mission)
    if isBoss(mission) then return bossPayout() end
    local amount = Payouts.typePayout(mission.type)
    return math.max(0, math.floor(amount * starMultiplier(mission.difficulty) + 0.5))
end

function Payouts.baseFor(mission)
    if type(mission) ~= 'table' then return 0 end
    local m = Payouts.missionPayout(mission.id)
    if m then return m end
    return fallbackBase(mission)
end

function Payouts.sourceFor(mission)
    if type(mission) ~= 'table' then return 'type' end
    if Payouts.missionPayout(mission.id) then return 'admin' end
    if isBoss(mission) then return 'event' end
    return 'type'
end

local function missionDefs()
    if CP.Missions and CP.Missions.list then
        local ok, list = pcall(CP.Missions.list)
        if ok and type(list) == 'table' then return list end
    end
    return {}
end

local function typeEntry(key, counts)
    local cfg = typeCfg(key)
    local row = typeRows[key]
    local amount, locked = Payouts.typePayout(key)
    local lo, hi = supervisorRange(key)
    local left = 0
    if row and not row.adminLocked and row.updatedTs then
        left = math.max(0, cooldownSeconds() - (now() - row.updatedTs))
    end
    return {
        key = key,
        label = cfg and cfg.label or key,
        points = math.floor(num(cfg and cfg.points, 0)),
        amount = amount,
        default = math.floor(num(cfg and cfg.payout, 0)),
        adminLocked = locked,
        stored = row ~= nil,
        updatedBy = row and row.updatedBy or nil,
        updatedByName = row and row.updatedByName or nil,
        updatedAt = row and row.updatedTs or nil,
        supMin = lo,
        supMax = hi,
        cooldownLeft = left,
        missions = counts and counts[key] or 0,
    }
end

local function missionEntry(def)
    local row = missionRows[def.id]
    local typeLabel = typeCfg(def.type) and typeCfg(def.type).label or tostring(def.type)
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
        difficulty = math.floor(num(def.difficulty, 1)),
        source = def.source == 'custom' and 'custom' or 'builtin',
        isBoss = isBoss(def),
        enabled = enabled,
        base = Payouts.baseFor(def),
        payoutSource = Payouts.sourceFor(def),
        missionPayout = row and row.amount or nil,
        fallback = fallbackBase(def),
        setBy = row and row.setBy or nil,
        setByName = row and row.setByName or nil,
        updatedAt = row and row.updatedTs or nil,
        missing = false,
    }
end

local function sortedTypeKeys()
    local keys = CP.U.keys(Config.MissionTypes or {})
    table.sort(keys, function(a, b)
        local pa, pb = num(Config.MissionTypes[a].points, 0), num(Config.MissionTypes[b].points, 0)
        if pa ~= pb then return pa < pb end
        return a < b
    end)
    return keys
end

function Payouts.list()
    ensureLoaded()
    local defs = missionDefs()
    local counts, seen = {}, {}
    local missions = {}
    for _, def in ipairs(defs) do
        if type(def) == 'table' and type(def.id) == 'string' then
            seen[def.id] = true
            if not isBoss(def) then counts[def.type] = (counts[def.type] or 0) + 1 end
            missions[#missions + 1] = missionEntry(def)
        end
    end
    -- Stored payouts of missions that are not loaded (archived, deleted file): listed so an admin can clear them.
    for id, row in pairs(missionRows) do
        if not seen[id] then
            missions[#missions + 1] = {
                id = id, label = id, type = nil, typeLabel = nil, difficulty = 1, source = 'custom', isBoss = false,
                enabled = false, base = row.amount, payoutSource = 'admin', missionPayout = row.amount, fallback = 0,
                setBy = row.setBy, setByName = row.setByName, updatedAt = row.updatedTs, missing = true,
            }
        end
    end
    local typeOrder = {}
    for i, k in ipairs(sortedTypeKeys()) do typeOrder[k] = i end
    table.sort(missions, function(a, b)
        local ta, tb = typeOrder[a.type or ''] or 99, typeOrder[b.type or ''] or 99
        if a.isBoss ~= b.isBoss then return not a.isBoss end
        if ta ~= tb then return ta < tb end
        return tostring(a.label) < tostring(b.label)
    end)
    local types = {}
    for _, key in ipairs(sortedTypeKeys()) do types[#types + 1] = typeEntry(key, counts) end
    return { types = types, missions = missions }
end

-- ── audit, push ─────────────────────────────────────────────────────────────
local function audit(src, role, action, target, old, new, reason)
    local auditRole = src == 0 and 'console' or role
    local oldS, newS = CP.U.clip(tostring(old), 64), CP.U.clip(tostring(new), 64)
    if CP.Admin and CP.Admin.audit then
        local ok, err = pcall(CP.Admin.audit, src, auditRole, 'audit', action, CP.U.clip(target, 64), oldS, newS, reason)
        if ok then return end
        CP.err(TAG, 'CP.Admin.audit failed: %s', tostring(err))
    end
    -- modules/admin unavailable: keep the audit trail anyway (no webhook).
    local ok, err = pcall(MySQL.insert.await,
        "INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason) VALUES (?, ?, 'audit', ?, ?, ?, ?, ?)",
        { actorId(src), auditRole, CP.U.clip(action, 40), CP.U.clip(target, 64), oldS, newS, reason or '' })
    if not ok then CP.err(TAG, 'audit insert failed: %s', tostring(err)) end
end

local function pushChange(data)
    if not (CP.Tablet and CP.Tablet.push and CP.Qbx and CP.Qbx.getOnlinePlayers) then return end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers()) do
        CP.Tablet.push(s, 'payouts', data)
        CP.Tablet.push(s, 'board', { reason = 'payouts' })
    end
end

-- ── validation ──────────────────────────────────────────────────────────────
local function cleanReason(reason, role)
    if reason ~= nil and type(reason) ~= 'string' then return nil, 'err.invalid_payload' end
    local r = reason and CP.U.trim(reason) or ''
    -- Characters, not bytes: the Payouts screens' maxLength and cp_audit.reason (VARCHAR(255) utf8mb4) count
    -- characters, so an accented 200-character reason is valid.
    local len = utf8.len(r)
    if not len then return nil, 'err.invalid_payload' end
    if len > REASON_MAX then return nil, 'err.reason_too_long' end
    if r == '' and reasonRequired(role) then return nil, 'err.reason_required' end
    return r
end

local function cleanAmount(amount)
    local n = tonumber(amount)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil, 'err.invalid_amount' end
    if math.floor(n) ~= n then return nil, 'err.invalid_amount' end
    n = math.floor(n)
    local lo, hi = cashLimits()
    if n < lo or n > hi then return nil, 'err.payout_out_of_range' end
    return n
end

local function lock(key)
    if busy[key] then return false end
    busy[key] = true
    return true
end

local function unlock(key) busy[key] = nil end

-- ── writes ──────────────────────────────────────────────────────────────────
local function writeType(key, amount, adminLocked, actor)
    local ok, err = pcall(MySQL.query.await, [[
        INSERT INTO cp_type_payouts (mission_type, amount, admin_locked, updated_by, updated_at)
        VALUES (?, ?, ?, ?, FROM_UNIXTIME(?))
        ON DUPLICATE KEY UPDATE amount = VALUES(amount), admin_locked = VALUES(admin_locked),
            updated_by = VALUES(updated_by), updated_at = VALUES(updated_at)
    ]], { key, amount, adminLocked and 1 or 0, actor, now() })
    if not ok then CP.err(TAG, 'saving the %s payout failed: %s', key, tostring(err)) end
    return ok
end

local function setTypeLocked(src, key, amount, reason, role)
    ensureLoaded()
    local row = typeRows[key]
    local oldAmount = Payouts.typePayout(key)
    local actor = actorId(src)

    if role == 'supervisor' then
        if row and row.adminLocked then return false, 'err.payout_locked' end
        local lo, hi = supervisorRange(key)
        if amount < lo or amount > hi then return false, 'err.payout_out_of_range' end
        if row and row.updatedTs and now() - row.updatedTs < cooldownSeconds() then return false, 'err.payout_cooldown' end
        if amount == oldAmount then return false, 'err.payout_unchanged' end
        if not writeType(key, amount, false, actor) then return false, 'err.internal' end
        audit(src, 'supervisor', 'setTypePayout', key, oldAmount, amount, reason)
    else
        if amount == nil then
            if not row then return false, 'err.payout_unchanged' end
            local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_type_payouts WHERE mission_type = ?', { key })
            if not ok then
                CP.err(TAG, 'clearing the %s payout failed: %s', key, tostring(err))
                return false, 'err.internal'
            end
            local cfgAmount = math.floor(num(typeCfg(key).payout, 0))
            audit(src, 'admin', 'clearTypePayout', key, oldAmount, ('config:%d'):format(cfgAmount), reason)
        else
            if row and row.adminLocked and row.amount == amount then return false, 'err.payout_unchanged' end
            if not writeType(key, amount, true, actor) then return false, 'err.internal' end
            audit(src, 'admin', 'setTypePayout', key, oldAmount, amount, reason)
        end
    end
    load()
    CP.log(TAG, '%s payout %s -> %s by %s (%s)', key, tostring(oldAmount), tostring(amount), actor, role)
    pushChange({ kind = 'type', key = key })
    return true, typeEntry(key, nil)
end

function Payouts.setType(src, key, amount, reason, role)
    src = toSrc(src)
    if not src then return false, 'err.no_permission' end
    if type(key) ~= 'string' or #key > TYPE_KEY_MAX or not typeCfg(key) then return false, 'err.unknown_type' end
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
        local n, errKey = cleanAmount(amount)
        if not n then return false, errKey end
        value = n
    end
    local r, errKey = cleanReason(reason, role)
    if not r then return false, errKey end

    local lk = 'type:' .. key
    if not lock(lk) then return false, 'err.busy' end
    local okCall, ok, res = pcall(setTypeLocked, src, key, value, r, role)
    unlock(lk)
    if not okCall then
        CP.err(TAG, 'setType failed: %s', tostring(ok))
        return false, 'err.internal'
    end
    return ok, res
end

local function missionEntryById(id)
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(id)
    if def then return missionEntry(def) end
    for _, e in ipairs(Payouts.list().missions) do
        if e.id == id then return e end
    end
    return nil
end

local function setMissionLocked(src, missionId, amount, reason)
    ensureLoaded()
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(missionId)
    local row = missionRows[missionId]
    if not def and not row then return false, 'err.unknown_mission' end
    if not def and amount ~= nil then return false, 'err.unknown_mission' end
    local oldAmount = row and row.amount or nil
    local oldText = oldAmount and tostring(oldAmount) or ('%s:%d'):format(def and (isBoss(def) and 'event' or 'type') or 'none',
        def and fallbackBase(def) or 0)
    local actor = actorId(src)
    if amount == nil then
        if not row then return false, 'err.payout_unchanged' end
        local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_mission_payouts WHERE mission_id = ?', { missionId })
        if not ok then
            CP.err(TAG, 'clearing the payout of %s failed: %s', missionId, tostring(err))
            return false, 'err.internal'
        end
        audit(src, 'admin', 'clearMissionPayout', missionId, oldText, def and ('%s:%d'):format(isBoss(def) and 'event' or 'type', fallbackBase(def)) or 'none', reason)
    else
        if oldAmount == amount then return false, 'err.payout_unchanged' end
        local ok, err = pcall(MySQL.query.await, [[
            INSERT INTO cp_mission_payouts (mission_id, amount, set_by, updated_at) VALUES (?, ?, ?, FROM_UNIXTIME(?))
            ON DUPLICATE KEY UPDATE amount = VALUES(amount), set_by = VALUES(set_by), updated_at = VALUES(updated_at)
        ]], { missionId, amount, actor, now() })
        if not ok then
            CP.err(TAG, 'saving the payout of %s failed: %s', missionId, tostring(err))
            return false, 'err.internal'
        end
        audit(src, 'admin', 'setMissionPayout', missionId, oldText, amount, reason)
    end
    load()
    CP.log(TAG, 'mission %s payout %s -> %s by %s', missionId, tostring(oldAmount), tostring(amount), actor)
    pushChange({ kind = 'mission', missionId = missionId })
    return true, missionEntryById(missionId) or { id = missionId, missionPayout = amount }
end

function Payouts.setMission(src, missionId, amount, reason)
    src = toSrc(src)
    if not src then return false, 'err.no_permission' end
    if type(missionId) ~= 'string' or missionId == '' or #missionId > MISSION_ID_MAX or not missionId:match('^[%w_%-]+$') then
        return false, 'err.unknown_mission'
    end
    if not CP.Permissions or not CP.Permissions.can then return false, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, amount == nil and 'clearPayout' or 'setMissionPayout')
    if not ok then return false, errKey or 'err.no_permission' end
    local value = nil
    if amount ~= nil then
        local n, e = cleanAmount(amount)
        if not n then return false, e end
        value = n
    end
    local r, e = cleanReason(reason, 'admin')
    if not r then return false, e end

    local lk = 'mission:' .. missionId
    if not lock(lk) then return false, 'err.busy' end
    local okCall, res1, res2 = pcall(setMissionLocked, src, missionId, value, r)
    unlock(lk)
    if not okCall then
        CP.err(TAG, 'setMission failed: %s', tostring(res1))
        return false, 'err.internal'
    end
    return res1, res2
end

-- ── screens ─────────────────────────────────────────────────────────────────
local function supView()
    local data = Payouts.list()
    local loShare, hiShare = rangeShares()
    local types = {}
    for _, e in ipairs(data.types) do
        types[#types + 1] = {
            key = e.key, label = e.label, amount = e.amount, default = e.default,
            min = e.supMin, max = e.supMax, adminLocked = e.adminLocked,
            cooldownLeft = e.adminLocked and 0 or e.cooldownLeft,
            updatedByName = e.updatedByName, updatedAt = e.updatedAt,
            stored = e.stored,
            canEdit = not e.adminLocked and e.cooldownLeft <= 0,
        }
    end
    local lo, hi = cashLimits()
    return {
        types = types,
        rangeShare = { min = loShare, max = hiShare },
        cooldownSeconds = cooldownSeconds(),
        requireReason = true,
        limits = { min = lo, max = hi },
        serverTime = now(),
    }
end

local function adminView()
    local data = Payouts.list()
    local lo, hi = cashLimits()
    return {
        types = data.types,
        missions = data.missions,
        limits = { min = lo, max = hi },
        requireReason = reasonRequired('admin'),
        cooldownSeconds = cooldownSeconds(),
        serverTime = now(),
    }
end

CP.Net.callback('sup:getPayouts', function(src)
    local ok, errKey = CP.Permissions.can(src, 'setTypePayout')
    if not ok then return nil, errKey or 'err.no_permission' end
    return supView()
end)

CP.Net.callback('admin:getPayouts', function(src)
    if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return nil, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, 'setMissionPayout')
    if not ok then return nil, errKey or 'err.no_permission' end
    return adminView()
end)

-- Payload helpers: nil / JSON null / clear = true mean "clear" on the admin paths.
local function payloadAmount(payload)
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
    return true, {
        key = res.key, label = res.label, amount = res.amount, default = res.default, min = res.supMin, max = res.supMax,
        adminLocked = res.adminLocked, cooldownLeft = res.cooldownLeft, updatedByName = res.updatedByName,
        updatedAt = res.updatedAt, stored = res.stored, canEdit = not res.adminLocked and res.cooldownLeft <= 0,
    }
end, { rate = 2 })

CP.Net.action('server:admin:setTypePayout', function(src, payload)
    if type(payload) ~= 'table' or type(payload.type) ~= 'string' then return false, 'err.invalid_payload' end
    if payload.reason ~= nil and type(payload.reason) ~= 'string' then return false, 'err.invalid_payload' end
    local amount, valid = payloadAmount(payload)
    if not valid then return false, 'err.invalid_payload' end
    return Payouts.setType(src, payload.type, amount, payload.reason, 'admin')
end, { rate = 3 })

CP.Net.action('server:admin:setMissionPayout', function(src, payload)
    if type(payload) ~= 'table' or type(payload.missionId) ~= 'string' then return false, 'err.invalid_payload' end
    if payload.reason ~= nil and type(payload.reason) ~= 'string' then return false, 'err.invalid_payload' end
    local amount, valid = payloadAmount(payload)
    if not valid then return false, 'err.invalid_payload' end
    return Payouts.setMission(src, payload.missionId, amount, payload.reason)
end, { rate = 3 })

-- ── start ───────────────────────────────────────────────────────────────────
CreateThread(function()
    ensureLoaded()
end)

-- Test hooks (not part of the contract).
Payouts._reload = function() loaded = false; ensureLoaded() end
Payouts._supervisorRange = supervisorRange
Payouts._supView = supView
Payouts._adminView = adminView
