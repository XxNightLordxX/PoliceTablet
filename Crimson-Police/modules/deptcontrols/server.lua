-- CP.DeptControls (server): Mission controls. Rules a department's supervisors may change for their own department,

CP.DeptControls = CP.DeptControls or {}
local DC = CP.DeptControls
local U = CP.U
local TAG = 'deptcontrols'

local SERVER_WIDE = '*'         -- the department key of a server-wide control's row
local KEY_PATTERN = '^%a[%w_]*$'
local KEY_MAX = 40              -- characters (cp_dept_controls.control_key)
local MAP_MAX = 64              -- entries of a map value (one number per mission type)
local AUDIT_TEXT = 64           -- characters cp_audit keeps of an old or new value
local KINDS = { number = true, bool = true, map = true, action = true, choice = true }
local CHOICE_MAX = 16           -- names in a choice control's list (difficulty's presets)
local SCOPES = { between = true, run = true }
local WATCHED = { 'MissionControls', 'Permissions.supervisor.missionControls', 'Departments' }

local defs = {}           -- key -> { kind, scope, master, serverWide, integer, configValue, check, clamp, relaxes, ... }
local order = {}          -- the registered keys in the order they were registered
local cache = {}          -- department -> { [key] = row } (rows of cp_dept_controls, decoded)
local lastChange = {}     -- 'department|key' -> os.time() of the last set or reset (a reset leaves no row behind)

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Cfg()
    return type(Config.MissionControls) == 'table' and Config.MissionControls or {}
end

-- The master switch: Config.Permissions.supervisor.missionControls.
local function MasterOn()
    local perms = Config.Permissions
    local sup = type(perms) == 'table' and perms.supervisor or nil
    return type(sup) == 'table' and sup.missionControls == true
end

local function ChangeWait() return math.max(0, math.floor(tonumber(Cfg().changeWait) or 0)) end

local function IsNum(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end

local function Encode(v)
    local ok, s = pcall(json.encode, { v = v })
    return ok and s or nil
end

local function Decode(raw)
    local t = raw
    if type(raw) == 'string' then
        local ok, d = pcall(json.decode, raw)
        t = ok and d or nil
    end
    if type(t) ~= 'table' then return nil end
    return t.v
end

local function Brief(v)
    if v == nil then return nil end
    local s = type(v) == 'table' and (Encode(v) or '?'):match('^{"v":(.*)}$') or tostring(v)
    return U.clip(s, AUDIT_TEXT)
end

local function Same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not Same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

local function StoreDept(def, dept) return def.serverWide and SERVER_WIDE or dept end

local function DeptKnown(dept)
    return type(dept) == 'string' and type(Config.Departments) == 'table' and type(Config.Departments[dept]) == 'table'
end

-- ============================================================================
--                                 THE CONTROLS
-- ============================================================================

local function Flags(list)
    local out = {}
    for _, f in ipairs(type(list) == 'table' and list or {}) do
        if type(f) == 'string' and f ~= 'on' and f ~= 'min' and f ~= 'max' then out[f] = true end
    end
    return out
end

-- DC.register(key, def): a control other modules read with DC.get.
--   kind        'number' (one number), 'bool' (true or false), 'map' (a number per key, e.g. per mission type),
--               'choice' (one name from the list the admin's bounds give in the field named by list) or 'action' (a staff action with no saved value, e.g. clearing an officer's cooldown: only its admin
--               switch and bounds; DC.canChange says who may use it, DC.get / DC.set / DC.reset never apply)
--   scope       'between' (read between runs: cooldowns, limits) or 'run' (copied into run.controls at the start,
--               DC.snapshot)
--   configValue fn(officer) -> the value while no change applies (the config.lua rule)
--   check       optional fn(value, bounds) -> clean value | nil, errKey (replaces the kind's own check)
--   clamp       optional fn(value, bounds) -> value moved into the bounds (replaces the kind's own clamp)
--   relaxes     optional fn(value, configValue) -> true when the value makes the rule easier (the self rule); default:
--               any value other than the config value
--   integer     true: a number must be whole
--   serverWide  true: one value for every department (saved under '*'); a supervisor of any department changes it
--   master      false: the master switch does not apply (the control's own on still does)
--   range       optional { lo, hi }: the admin's min and max (config and Settings) must lie inside it
--   duration    optional fn(value) -> seconds: a timed control; DC.set makes the change end that long after it starts
--   allow       optional fn({ role, src, dept, value, row }) -> errKey | nil, extra: one more rule before a change
--   carry       optional fn({ role, dept, value, row }) -> the value saved: built from the change and the live row
--               (step P21: a pick that counts from the next weekly reset keeps the one that counts until then)
--   overlays    optional { [other key] = fn(value, thisValue) -> value }: while this control has a live change, DC.get
--               of the other key returns fn's value (the self rule of this change still applies)
--   viewExtra   optional fn(dept) -> table: more fields for this control's row in DC.view
--   bounded     false: the control has no min and max (the admin's card shows only its switch)
--   flags       optional { name, ... }: more true / false fields its bounds may carry (readyCheck's canTurnOff)
--   list        a 'choice' control: the bounds field with the names a supervisor may pick (difficulty: 'presets');
--               left out, every name choices gives is offered (featuredType: every mission type)
--   choices     a 'choice' control: fn() -> every name that list may hold (the Config.NpcDifficulty presets)
function DC.register(key, def)
    if type(key) ~= 'string' or #key > KEY_MAX or not key:match(KEY_PATTERN) then
        CP.err(TAG, 'register: a control key is a name of at most %d characters (%s)', KEY_MAX, tostring(key))
        return false
    end
    if type(def) == 'table' and def.kind == 'action' and def.configValue == nil then
        def.configValue = function() return nil end
    end
    if type(def) ~= 'table' or not KINDS[def.kind] or type(def.configValue) ~= 'function' then
        CP.err(TAG, 'register(%s): kind number, bool, map or action and a configValue function are needed', key)
        return false
    end
    local scope = def.scope or 'between'
    local badList = def.list ~= nil and type(def.list) ~= 'string'
    if def.kind == 'choice' and (badList or type(def.choices) ~= 'function') then
        CP.err(TAG, 'register(%s): a choice control needs a choices function (and list: a bounds field)', key)
        return false
    end
    if not SCOPES[scope] then
        CP.err(TAG, 'register(%s): scope is between or run', key)
        return false
    end
    if not defs[key] then order[#order + 1] = key end
    defs[key] = {
        key = key,
        kind = def.kind,
        scope = scope,
        master = def.master ~= false,
        serverWide = def.serverWide == true,
        integer = def.integer == true,
        configValue = def.configValue,
        check = def.check,
        clamp = def.clamp,
        relaxes = def.relaxes,
        range = type(def.range) == 'table' and IsNum(def.range[1]) and IsNum(def.range[2]) and def.range or nil,
        duration = type(def.duration) == 'function' and def.duration or nil,
        allow = type(def.allow) == 'function' and def.allow or nil,
        carry = type(def.carry) == 'function' and def.carry or nil,
        overlays = type(def.overlays) == 'table' and def.overlays or nil,
        viewExtra = type(def.viewExtra) == 'function' and def.viewExtra or nil,
        bounded = def.bounded ~= false and def.kind ~= 'bool' and def.kind ~= 'choice',
        flags = Flags(def.flags),
        list = def.kind == 'choice' and def.list or nil,
        choices = def.kind == 'choice' and def.choices or nil,
    }
    return true
end

-- Removes a control (tests; a module that turns its control off for good).
function DC.unregister(key)
    if not defs[key] then return false end
    defs[key] = nil
    for i, k in ipairs(order) do
        if k == key then
            table.remove(order, i)
            break
        end
    end
    return true
end

function DC.def(key) return type(key) == 'string' and defs[key] or nil end

function DC.keys()
    local out = {}
    for i, k in ipairs(order) do out[i] = k end
    return out
end

-- The bounds of a control for a department: Config.MissionControls.controls[key], then
-- Config.Departments[dept].missionControls[key] over it, field by field. Always a table ({} = off).
function DC.bounds(dept, key)
    local out = {}
    local all = type(Cfg().controls) == 'table' and Cfg().controls[key] or nil
    if type(all) == 'table' then
        for k, v in pairs(all) do out[k] = v end
    end
    local d = DeptKnown(dept) and Config.Departments[dept] or nil
    local own = type(d) == 'table' and type(d.missionControls) == 'table' and d.missionControls[key] or nil
    if type(own) == 'table' then
        for k, v in pairs(own) do out[k] = v end
    end
    return out
end

-- The bounds a server-wide control is read with (no department may override it).
local function BoundsOf(def, dept)
    if def.serverWide then return DC.bounds(nil, def.key) end
    return DC.bounds(dept, def.key)
end

-- True while a change of the control counts: its on, and the master switch unless the control is outside it.
local function Active(def, bounds)
    return bounds.on == true and (not def.master or MasterOn())
end

local function InRange(v, bounds)
    if IsNum(tonumber(bounds.min)) and v < tonumber(bounds.min) then return false end
    if IsNum(tonumber(bounds.max)) and v > tonumber(bounds.max) then return false end
    return true
end

local function ClampNum(v, bounds)
    if IsNum(tonumber(bounds.min)) then v = math.max(v, tonumber(bounds.min)) end
    if IsNum(tonumber(bounds.max)) then v = math.min(v, tonumber(bounds.max)) end
    return v
end

local function GoodNum(def, v)
    if not IsNum(v) then return false end
    return not def.integer or math.tointeger(v) ~= nil
end

-- A choice control: the names the admin's bounds offer (only names its choices function knows); with no list
-- field, every name its choices function gives.
local function Offered(def, bounds)
    local out = {}
    local list = def.list and bounds[def.list]
    local ok, all = pcall(def.choices)
    if def.list == nil then
        for _, n in ipairs(ok and type(all) == 'table' and all or {}) do
            if type(n) == 'string' then out[#out + 1] = n end
        end
        return out
    end
    if type(list) ~= 'table' then return out end
    local known = {}
    for _, n in ipairs(ok and type(all) == 'table' and all or {}) do known[n] = true end
    for _, n in ipairs(list) do
        if type(n) == 'string' and known[n] then out[#out + 1] = n end
    end
    return out
end

-- True when value is one of the names a choice control's bounds offer.
local function Picked(def, value, bounds)
    if type(value) ~= 'string' then return false end
    for _, n in ipairs(Offered(def, bounds)) do
        if n == value then return true end
    end
    return false
end

-- The value a supervisor or admin sent: clean value | nil, errKey. Outside the bounds is refused, never clamped.
local function Check(def, value, bounds)
    if def.check then
        local ok, v, err = pcall(def.check, value, bounds)
        if not ok then
            CP.err(TAG, 'the check of %s failed: %s', def.key, tostring(v))
            return nil, 'err.internal'
        end
        if v == nil then return nil, err or 'err.control_value' end
        return v
    end
    if def.kind == 'bool' then
        if type(value) ~= 'boolean' then return nil, 'err.control_value' end
        return value
    elseif def.kind == 'choice' then
        if not Picked(def, value, bounds) then return nil, 'err.control_value' end
        return value
    elseif def.kind == 'number' then
        if not GoodNum(def, value) or not InRange(value, bounds) then return nil, 'err.control_value' end
        return value
    end
    if type(value) ~= 'table' then return nil, 'err.control_value' end
    local out, n = {}, 0
    for k, v in pairs(value) do
        n = n + 1
        if n > MAP_MAX or type(k) ~= 'string' or #k > KEY_MAX or not k:match('^[%w_%-]+$') then
            return nil, 'err.control_value'
        end
        if not GoodNum(def, v) or not InRange(v, bounds) then return nil, 'err.control_value' end
        out[k] = v
    end
    return out
end

-- A saved value moved into today's bounds (an admin narrowed them after the change): value | nil (no longer usable).
local function Clamp(def, value, bounds)
    if def.clamp then
        local ok, v = pcall(def.clamp, value, bounds)
        if ok then return v end
        CP.err(TAG, 'the clamp of %s failed: %s', def.key, tostring(v))
        return nil
    end
    if def.kind == 'bool' then return type(value) == 'boolean' and value or nil end
    if def.kind == 'choice' then return Picked(def, value, bounds) and value or nil end
    if def.kind == 'number' then return GoodNum(def, value) and ClampNum(value, bounds) or nil end
    if type(value) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(value) do
        if type(k) == 'string' and GoodNum(def, v) then out[k] = ClampNum(v, bounds) end
    end
    return out
end

local function ConfigValue(def, officer)
    local ok, v = pcall(def.configValue, officer)
    if not ok then
        CP.err(TAG, 'the config value of %s failed: %s', def.key, tostring(v))
        return nil
    end
    return v
end

local function Relaxes(def, value, configValue)
    if def.relaxes then
        local ok, r = pcall(def.relaxes, value, configValue)
        if ok then return r == true end
        CP.err(TAG, 'relaxes of %s failed: %s', def.key, tostring(r))
        return true
    end
    return not Same(value, configValue)
end

-- ============================================================================
--                                ROWS AND CACHE
-- ============================================================================

local ROW_SQL = [[SELECT control_key, value_json, UNIX_TIMESTAMP(expires_at) AS expires_ts, set_by, set_role,
  UNIX_TIMESTAMP(updated_at) AS updated_ts FROM cp_dept_controls WHERE department = ?]]

-- The rows of a department (or '*'), read once and kept until a write or a settings change.
local function Rows(dept)
    local c = cache[dept]
    if c then return c end
    Db()
    local ok, rows = pcall(MySQL.query.await, ROW_SQL, { dept })
    if not ok then
        CP.err(TAG, 'reading the mission controls of %s failed: %s', tostring(dept), tostring(rows))
        return {}
    end
    c = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if type(r.control_key) == 'string' then
            c[r.control_key] = {
                value = Decode(r.value_json),
                expiresAt = math.tointeger(tonumber(r.expires_ts)),
                setBy = r.set_by,
                setRole = r.set_role,
                at = math.tointeger(tonumber(r.updated_ts)) or 0,
            }
        end
    end
    cache[dept] = c
    return c
end

local function LiveRow(dept, key)
    local row = Rows(dept)[key]
    if not row then return nil end
    if row.expiresAt and row.expiresAt <= os.time() then return nil end
    return row
end

function DC.clearCache(dept)
    if dept == nil then
        cache = {}
    else
        cache[dept] = nil
    end
end

-- ============================================================================
--                                   READING
-- ============================================================================

-- The members a value is read for: an officer table ({ citizenid }), a list of them (a unit) or { members = ... }.
local function Members(officer)
    if type(officer) ~= 'table' then return {} end
    if type(officer.citizenid) == 'string' then return { officer } end
    local list = type(officer.members) == 'table' and officer.members or officer
    local out = {}
    for _, m in pairs(list) do
        if type(m) == 'table' and type(m.citizenid) == 'string' then out[#out + 1] = m end
    end
    return out
end

local function LicenseOf(cid)
    if not (CP.Access and CP.Access.licenseOf) then return nil end
    local ok, l = pcall(CP.Access.licenseOf, cid)
    return ok and l or nil
end

-- True when the citizenid is the setter or another character of his license.
local function IsSetter(cid, setBy)
    if cid == setBy then return true end
    local a, b = LicenseOf(cid), LicenseOf(setBy)
    if not a or not b then return false end
    if CP.Access and CP.Access.sameUser then return CP.Access.sameUser(a, b) == true end
    return a == b
end

local function SelfHeld(officer, row)
    if Cfg().selfExempt == false or type(row.setBy) ~= 'string' then return false end
    for _, m in ipairs(Members(officer)) do
        if IsSetter(m.citizenid, row.setBy) then return true end
    end
    return false
end

-- The value of a control for a department (dept: its key; officer: who it is read for, a unit's members, or nil).
-- The saved change while the control is on (and the master switch, unless the control is outside it) and the row
-- has not expired, moved into today's bounds; else the config value. The config value too for the supervisor who set
-- a change that relaxes the rule, any character of his and any unit he is in (Config.MissionControls.selfExempt).
-- Returns value, row (nil when the config value applies).
local function Own(def, dept, key, officer)
    local configValue = ConfigValue(def, officer)
    local bounds = BoundsOf(def, dept)
    if not Active(def, bounds) then return configValue end
    local where = StoreDept(def, dept)
    if type(where) ~= 'string' then return configValue end
    local row = LiveRow(where, key)
    if not row then return configValue end
    local v = Clamp(def, row.value, bounds)
    if v == nil then return configValue end
    if officer ~= nil and SelfHeld(officer, row) and Relaxes(def, v, configValue) then return configValue end
    return v, row
end

-- Another control's live change laid over the value (a happy hour over the cooldowns): value, its row | nil.
local function Overlay(dept, key, officer, value)
    for _, k in ipairs(order) do
        local od = defs[k]
        local fn = od.overlays and od.overlays[key]
        local where = fn and StoreDept(od, dept)
        local row = type(where) == 'string' and Active(od, BoundsOf(od, dept)) and LiveRow(where, k) or nil
        if row and not (officer ~= nil and SelfHeld(officer, row)) then
            local ok, v = pcall(fn, value, row.value)
            if ok and v ~= nil then return v, row end
            if not ok then CP.err(TAG, 'the overlay of %s on %s failed: %s', k, key, tostring(v)) end
        end
    end
    return nil
end

function DC.get(dept, key, officer)
    local def = defs[key]
    if not def or def.kind == 'action' then return nil end
    local v, row = Own(def, dept, key, officer)
    local ov, orow = Overlay(dept, key, officer, v)
    if orow then return ov, orow end
    return v, row
end

-- True while a change of the control counts for the department: its on (the department's bounds) and the master
-- switch unless the control is outside it. A module that keeps its own record of a change reads this (step P18).
function DC.active(dept, key)
    local def = defs[key]
    if not def then return false end
    return Active(def, BoundsOf(def, dept))
end

-- True when the change in row does not apply to officer (an officer, a unit's members): the self rule.
function DC.heldBy(officer, row)
    return type(row) == 'table' and officer ~= nil and SelfHeld(officer, row) or false
end

-- The scope 'run' values for run.controls, read for the leader (an officer table with its department, or
-- { department, members } for a unit) at the start. Returns values, changed (key -> true where a change applied
-- rather than the config value).
function DC.snapshot(leader)
    local out, changed = {}, {}
    local dept = type(leader) == 'table' and leader.department or nil
    for _, key in ipairs(order) do
        if defs[key].scope == 'run' then
            local v, row = DC.get(dept, key, leader)
            out[key] = v
            if row ~= nil then changed[key] = true end
        end
    end
    return out, changed
end

-- ============================================================================
--                                   WRITING
-- ============================================================================

-- Who may change a control of a department: admins any (bounds still apply); a supervisor only his own department
-- (any for a server-wide control), with the master switch (unless the control is outside it), his department's grant
-- in Config.MissionControls.grants and the control switched on. Returns ok, errKey, role, the department used.
function DC.canChange(src, key, dept)
    local def = defs[key]
    if not def then return false, 'err.control_unknown' end
    local n = math.tointeger(tonumber(src))
    if not n or n < 0 or not CP.Access then return false, 'err.no_permission' end
    local admin = n == 0 or CP.Access.isAdmin(n) == true
    if admin then
        if def.serverWide then
            dept = SERVER_WIDE
        elseif dept == nil and n > 0 then
            local own = CP.Access.getOfficer(n)
            dept = own and own.department or nil
        end
        if dept ~= SERVER_WIDE and not DeptKnown(dept) then return false, 'err.invalid_payload' end
        local bounds = BoundsOf(def, dept)
        if not Active(def, bounds) then return false, 'err.control_off' end
        return true, nil, n == 0 and 'console' or 'admin', dept
    end
    local officer = CP.Access.getOfficer(n)
    if not officer or officer.isSupervisor ~= true then return false, 'err.no_permission' end
    if def.master then
        local ok, err = CP.Permissions.can(n, 'missionControls', { department = officer.department })
        if not ok then return false, err or 'err.no_permission' end
    end
    if def.serverWide then
        dept = SERVER_WIDE
    elseif dept ~= nil and dept ~= officer.department then
        return false, 'err.other_department'
    else
        dept = officer.department
    end
    local grants = type(Cfg().grants) == 'table' and Cfg().grants or {}
    local grant = grants[officer.department]
    if grant ~= nil and not (CP.Permissions.gradeGrant and CP.Permissions.gradeGrant(officer, grant)) then
        return false, 'err.no_permission'
    end
    if not Active(def, BoundsOf(def, dept)) then return false, 'err.control_off' end
    return true, nil, 'supervisor', dept
end

-- DC.available(src): true when that player may change at least one control now (the Supervisor UI shows its
-- Mission controls screen then; with the shipped config the cooldown controls, outside the master switch).
function DC.available(src)
    for _, key in ipairs(order) do
        if defs[key].kind ~= 'action' and DC.canChange(src, key, nil) then return true end
    end
    return false
end

local function ActorOf(n)
    if n == 0 then return 'console' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    return type(info) == 'table' and info.citizenid or ('src:%d'):format(n)
end

-- Seconds until the control may change again in that department (0 = now).
local function WaitLeft(dept, key, row)
    local wait = ChangeWait()
    if wait <= 0 then return 0 end
    local last = lastChange[dept .. '|' .. key] or 0
    if row and row.at and row.at > last then last = row.at end
    return math.max(0, last + wait - os.time())
end

local function Audit(n, role, action, target, old, new, reason)
    if not (CP.AdminKit and CP.AdminKit.auditSync) then return false end
    return CP.AdminKit.auditSync(n, 'audit', action, target, Brief(old), Brief(new), reason, { role = role })
end

-- The open Supervisor UIs of that department (every department for '*') and the Admin UIs get the new state.
local function Push(dept, key)
    local data = { department = dept, key = key }
    local T = CP.Tablet
    if not (T and T.push) then return end
    if T.pushAdmins then T.pushAdmins('missionControls', data) end
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Access and CP.Access.getOfficer) then return end
    for _, s in ipairs(CP.Qbx.getOnlinePlayers() or {}) do
        local n = math.tointeger(tonumber(s))
        if n and not CP.Access.isAdmin(n) then
            local o = CP.Access.getOfficer(n)
            if o and o.isSupervisor and (dept == SERVER_WIDE or o.department == dept) then
                T.push(n, 'missionControls', data)
            end
        end
    end
end

local function Changed(dept, key)
    lastChange[dept .. '|' .. key] = os.time()
    cache[dept] = nil
    CP.Hooks.fire('deptControls:changed', { dept = dept, key = key })
    Push(dept, key)
end

-- A timed change ran out (nobody changed it): the readers that keep their own caches and the open screens hear it.
function DC.expired(dept, key)
    if type(dept) ~= 'string' or not defs[key] then return false end
    cache[dept] = nil
    CP.Hooks.fire('deptControls:changed', { dept = dept, key = key, expired = true })
    Push(dept, key)
    return true
end

-- DC.set(src, key, value, reason, opts): the only write. opts.department: the department (admins; a supervisor's
-- own when left out), opts.expiresAt: os.time() the change ends (server code only, never from a screen).
-- Returns true, { department, key, value } | false, errKey (opts.waitLeft on err.control_wait: seconds).
function DC.set(src, key, value, reason, opts)
    opts = type(opts) == 'table' and opts or {}
    if defs[key] and defs[key].kind == 'action' then return false, 'err.control_unknown' end
    local ok, err, role, dept = DC.canChange(src, key, opts.department)
    if not ok then return false, err end
    local def = defs[key]
    local cleanReason, errR = CP.AdminKit.reason(reason)
    if not cleanReason then return false, errR end
    local bounds = BoundsOf(def, dept)
    local clean, errV = Check(def, value, bounds)
    if clean == nil then return false, errV end
    local n = math.tointeger(tonumber(src))
    local row = LiveRow(dept, key)
    if role == 'supervisor' then
        local left = WaitLeft(dept, key, Rows(dept)[key])
        if left > 0 then return false, 'err.control_wait', { waitLeft = left } end
    end
    if def.allow then
        local okA, errA, extra = pcall(def.allow, { role = role, src = n, dept = dept, value = clean, row = row })
        if not okA then
            CP.err(TAG, 'the rule of %s failed: %s', key, tostring(errA))
            return false, 'err.internal'
        end
        if errA then return false, errA, extra end
    end
    if def.carry then
        local okC, carried = pcall(def.carry, { role = role, dept = dept, value = clean, row = row })
        if not okC or carried == nil then
            CP.err(TAG, 'the carry of %s failed: %s', key, tostring(carried))
            return false, 'err.internal'
        end
        clean = carried
    end
    local text = Encode(clean)
    if not text then return false, 'err.control_value' end
    local expires = math.tointeger(tonumber(opts.expiresAt))
    if def.duration then
        local okD, secs = pcall(def.duration, clean)
        secs = okD and math.tointeger(tonumber(secs)) or nil
        if not secs or secs <= 0 then return false, 'err.control_value' end
        expires = os.time() + secs
    end
    Db()
    local okW, errW = pcall(MySQL.query.await, [[
        INSERT INTO cp_dept_controls (department, control_key, value_json, expires_at, set_by, set_role, updated_at)
        VALUES (?, ?, ?, FROM_UNIXTIME(?), ?, ?, FROM_UNIXTIME(?))
        ON DUPLICATE KEY UPDATE value_json = VALUES(value_json), expires_at = VALUES(expires_at),
            set_by = VALUES(set_by), set_role = VALUES(set_role), updated_at = VALUES(updated_at)
    ]], { dept, key, text, expires, ActorOf(n), role, os.time() })
    if not okW then
        CP.err(TAG, 'saving the %s control of %s failed: %s', key, dept, tostring(errW))
        return false, 'err.internal'
    end
    local old = row and row.value
    if old == nil then old = ConfigValue(def, nil) end
    Audit(n, role, 'missionControlSet', ('%s:%s'):format(dept, key), old, clean, cleanReason)
    Changed(dept, key)
    CP.log(TAG, '%s set %s of %s', ActorOf(n), key, dept)
    return true, { department = dept, key = key, value = clean }
end

-- DC.reset(src, dept, key, reason): back to the config value (the row is deleted). A supervisor: his own department
-- (or a server-wide control); an admin: any. true, { department, key } | false, errKey.
function DC.reset(src, dept, key, reason)
    if defs[key] and defs[key].kind == 'action' then return false, 'err.control_unknown' end
    local ok, err, role, where = DC.canChange(src, key, dept)
    if not ok then return false, err end
    local cleanReason, errR = CP.AdminKit.reason(reason)
    if not cleanReason then return false, errR end
    local row = Rows(where)[key]
    if not row then return false, 'err.control_not_set' end
    Db()
    local okD, errD = pcall(MySQL.update.await, 'DELETE FROM cp_dept_controls WHERE department = ? AND control_key = ?',
        { where, key })
    if not okD then
        CP.err(TAG, 'resetting the %s control of %s failed: %s', key, where, tostring(errD))
        return false, 'err.internal'
    end
    local n = math.tointeger(tonumber(src))
    Audit(n, role, 'missionControlReset', ('%s:%s'):format(where, key), row.value, ConfigValue(defs[key], nil),
        cleanReason)
    Changed(where, key)
    return true, { department = where, key = key }
end

-- ============================================================================
--                                     VIEW
-- ============================================================================

-- The department's own bounds of a control (Config.Departments.<key>.missionControls), nil for a server-wide one.
local function OwnBounds(def, dept)
    if def.serverWide or not DeptKnown(dept) then return nil end
    local mc = Config.Departments[dept].missionControls
    local own = type(mc) == 'table' and mc[def.key] or nil
    return type(own) == 'table' and U.deepcopy(own) or nil
end

-- The flag names a control registered, sorted (nil when none).
local function FlagList(def)
    local out = {}
    for f in pairs(def.flags) do out[#out + 1] = f end
    table.sort(out)
    return #out > 0 and out or nil
end

-- Every name a choice control's list may hold (its choices function).
local function ChoiceList(def)
    local ok, all = pcall(def.choices)
    local out = {}
    for _, n in ipairs(ok and type(all) == 'table' and all or {}) do
        if type(n) == 'string' then out[#out + 1] = n end
    end
    return out
end

local function ControlFields(def, dept)
    local bounds = BoundsOf(def, dept)
    local where = StoreDept(def, dept)
    local row = Rows(where)[def.key]
    local now = os.time()
    local expired = row ~= nil and row.expiresAt ~= nil and row.expiresAt <= now
    local active = Active(def, bounds)
    local configValue = ConfigValue(def, nil)
    local value = configValue
    if active and row and not expired then
        local v = Clamp(def, row.value, bounds)
        if v ~= nil then value = v end
    end
    return {
        key = def.key,
        kind = def.kind,
        scope = def.scope,
        serverWide = def.serverWide,
        master = def.master,
        on = bounds.on == true,
        active = active,
        min = tonumber(bounds.min),
        max = tonumber(bounds.max),
        value = value,
        configValue = configValue,
        saved = row ~= nil and not expired and row.value or nil,
        setBy = row and row.setBy or nil,
        setRole = row and row.setRole or nil,
        at = row and row.at or nil,
        expiresAt = row and row.expiresAt or nil,
        timeLeft = row and row.expiresAt and math.max(0, row.expiresAt - now) or nil,
        waitLeft = WaitLeft(where, def.key, row),
        integer = def.integer,
        bounded = def.bounded,
        range = def.range and { def.range[1], def.range[2] } or nil,
        own = OwnBounds(def, dept),
        flags = FlagList(def),
        list = def.list,
        offered = def.kind == 'choice' and Offered(def, bounds) or nil,
        choices = def.choices and ChoiceList(def) or nil,
    }
end

local function ControlView(def, dept)
    local view = ControlFields(def, dept)
    if def.viewExtra then
        local ok, extra = pcall(def.viewExtra, dept)
        if ok and type(extra) == 'table' then
            for k, v in pairs(extra) do if view[k] == nil then view[k] = v end end
        elseif not ok then
            CP.err(TAG, 'the view of %s failed: %s', def.key, tostring(extra))
        end
    end
    return view
end

local function DeptView(dept, serverWide, admin)
    local d = Config.Departments[dept]
    local controls = {}
    for _, key in ipairs(order) do
        local def = defs[key]
        if def.serverWide == serverWide then controls[#controls + 1] = ControlView(def, dept) end
    end
    local out = { key = dept, label = d and d.label or dept, short = d and d.short or dept, controls = controls }
    -- the setting an admin saves this department's own bounds in (a department added in game has none)
    local path = ('Departments.%s.missionControls'):format(dept)
    if admin and not serverWide and CP.Settings and CP.Settings.entry and CP.Settings.entry(path) then
        out.boundsPath = path
    end
    return out
end

-- DC.view(src): what the Mission controls screens show. A supervisor: his department (with the master switch, or
-- while a control outside it is on); an admin (or the console): every department. { master, changeWait, selfExempt,
-- departments = { { key, label, controls, boundsPath? } }, serverWide = { controls }, bounds? (admins) }, or nil,
-- errKey.
function DC.view(src)
    local n = math.tointeger(tonumber(src))
    if not n or n < 0 or not CP.Access then return nil, 'err.no_permission' end
    local depts = {}
    local admin = n == 0 or CP.Access.isAdmin(n) == true
    if admin then
        for key, d in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do
            if type(key) == 'string' and type(d) == 'table' then depts[#depts + 1] = key end
        end
        table.sort(depts)
    else
        local officer = CP.Access.getOfficer(n)
        if not officer or officer.isSupervisor ~= true then return nil, 'err.no_permission' end
        local outside = false
        for _, key in ipairs(order) do
            local def = defs[key]
            if not def.master and Active(def, BoundsOf(def, officer.department)) then outside = true end
        end
        if not outside then
            local ok, err = CP.Permissions.can(n, 'missionControls', { department = officer.department })
            if not ok then return nil, err or 'err.no_permission' end
        end
        depts[1] = officer.department
    end
    local out = {
        master = MasterOn(),
        changeWait = ChangeWait(),
        selfExempt = Cfg().selfExempt ~= false,
        departments = {},
    }
    for _, dept in ipairs(depts) do out.departments[#out.departments + 1] = DeptView(dept, false, admin) end
    out.serverWide = DeptView(SERVER_WIDE, true, admin).controls
    -- an admin: Config.MissionControls.controls as saved (the admin switches and bounds the Permissions card edits)
    if admin then
        local all = type(Cfg().controls) == 'table' and Cfg().controls or {}
        out.bounds = {}
        for _, key in ipairs(order) do
            out.bounds[key] = type(all[key]) == 'table' and U.deepcopy(all[key]) or {}
        end
    end
    return out
end

-- ============================================================================
--                                CONFIG CHECKS
-- ============================================================================

-- A choice control's list in the config: names its choices function knows, each once, at most CHOICE_MAX.
local function ChoicesOk(def, v)
    if type(v) ~= 'table' or #v > CHOICE_MAX then return false end
    local n = 0
    for _ in pairs(v) do n = n + 1 end
    if n ~= #v then return false end
    local known, seen = {}, {}
    for _, c in ipairs(ChoiceList(def)) do known[c] = true end
    for _, c in ipairs(v) do
        if type(c) ~= 'string' or not known[c] or seen[c] then return false end
        seen[c] = true
    end
    return true
end

-- Config.MissionControls.controls or a department's missionControls: { <control> = { on, min, max } }. Registered
-- controls only (unless boot: the modules register theirs after the saved settings are read), min not above max.
-- Returns errKey, the control | nil.
function DC.checkConfig(map, boot)
    if map == nil then return nil end
    if type(map) ~= 'table' then return 'err.control_config' end
    for key, b in pairs(map) do
        if type(key) ~= 'string' or type(b) ~= 'table' then return 'err.control_config', tostring(key) end
        if not boot and not defs[key] then return 'err.control_config', key end
        for field, v in pairs(b) do
            if field == 'on' then
                if type(v) ~= 'boolean' then return 'err.control_config', key end
            elseif field == 'min' or field == 'max' then
                if not IsNum(v) then return 'err.control_config', key end
            elseif defs[key] and defs[key].list == field then
                if not ChoicesOk(defs[key], v) then return 'err.control_config', key end
            elseif boot and not defs[key] and type(v) == 'table' then
                if #v > CHOICE_MAX then return 'err.control_config', key end
            elseif defs[key] and defs[key].flags[field] or (boot and not defs[key]) then
                if type(v) ~= 'boolean' then return 'err.control_config', key end
            else
                return 'err.control_config', key
            end
        end
        if IsNum(b.min) and IsNum(b.max) and b.min > b.max then return 'err.control_config', key end
        local range = defs[key] and defs[key].range
        if range then
            for _, v in ipairs({ b.min, b.max }) do
                if IsNum(v) and (v < range[1] or v > range[2]) then return 'err.control_config', key end
            end
        end
    end
    return nil
end

-- ============================================================================
--                            CALLBACKS AND ACTIONS
-- ============================================================================

local function Payload(p) return type(p) == 'table' and p or {} end

CP.Net.callback('sup:getMissionControls', function(src) return DC.view(src) end, { rate = 3 })

-- A supervisor's own department (a server-wide control: any); the action itself runs DC.canChange.
local function SupPermission(src, p)
    local key = Payload(p).key
    local ok, err = DC.canChange(src, type(key) == 'string' and key or '', nil)
    return ok, err
end

if CP.AdminKit and CP.AdminKit.supAction then
    local Kit = CP.AdminKit
    Kit.supAction('server:sup:setMissionControl', 'missionControls', function(ctx)
        return DC.set(ctx.src, ctx.payload.key, ctx.payload.value, ctx.reason)
    end, { rate = 2, reason = true, requestId = true, permission = SupPermission })
    Kit.supAction('server:sup:resetMissionControl', 'missionControls', function(ctx)
        return DC.reset(ctx.src, nil, ctx.payload.key, ctx.reason)
    end, { rate = 2, reason = true, requestId = true, permission = SupPermission })
    Kit.callback('admin:getMissionControls', 'missionControls', function(ctx) return DC.view(ctx.src) end)
    Kit.action('server:admin:setMissionControl', 'missionControls', function(ctx)
        local p = ctx.payload
        return DC.set(ctx.src, p.key, p.value, ctx.reason, { department = p.department })
    end, { rate = 2, reason = true, requestId = true })
    Kit.action('server:admin:resetMissionControl', 'missionControls', function(ctx)
        local p = ctx.payload
        return DC.reset(ctx.src, p.department, p.key, ctx.reason)
    end, { rate = 2, reason = true, requestId = true })
end

-- A rule or a department changed in Settings: the rows are read again (bounds are always read live).
if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('settings:changed', function(paths)
        for _, path in ipairs(type(paths) == 'table' and paths or {}) do
            for _, w in ipairs(WATCHED) do
                if path == w or tostring(path):sub(1, #w + 1) == w .. '.' then
                    DC.clearCache()
                    return
                end
            end
        end
    end)
end

-- Test hooks (not part of the contract).
DC._reset = function()
    cache, lastChange = {}, {}
end
