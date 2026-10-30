-- CP.ReviewRules (server): a department's stricter review rules for flagged runs (step P14, the Mission control

CP.ReviewRules = CP.ReviewRules or {}
local RR = CP.ReviewRules
local TAG = 'reviewrules'

local KEY = 'reviewRules'
local KINDS_MAX = 16

-- The flag kinds a supervisor may hand to admins (cp_mission_runs.flag_reason; the locale names them flag.<kind>).
local FLAG_KINDS = {
    'outside_help',
    'too_fast',
    'speed',
    'presence',
    'unexpected_event',
    'stun_unproven',
    'manual',
    'rs_excessive_force',
    'rs_unarmed_shot',
    'rs_vdm',
    'rs_bad_seize',
    'rs_linked_accounts',
    'rs_pair_repeat',
}

local pending = {}   -- row id -> { citizenid, name, department, at }: the first Void of a row waiting for a second

-- ============================================================================
--                                 THE CONTROL
-- ============================================================================

-- The control's value: { secondVoid = true | false, adminOnlyKinds = { kind, ... } }. strict: anything else is
-- refused (a supervisor's change); else a saved value keeps only the kinds still known.
local function Clean(v, strict)
    if type(v) ~= 'table' or type(v.secondVoid) ~= 'boolean' then return nil end
    for k in pairs(v) do
        if strict and k ~= 'secondVoid' and k ~= 'adminOnlyKinds' then return nil end
    end
    if v.adminOnlyKinds ~= nil and type(v.adminOnlyKinds) ~= 'table' then return nil end
    local known = {}
    for _, k in ipairs(FLAG_KINDS) do known[k] = true end
    local picked, n = {}, 0
    for _, k in pairs(v.adminOnlyKinds or {}) do
        n = n + 1
        if type(k) ~= 'string' or not known[k] or n > KINDS_MAX then
            if strict then return nil end
        else
            picked[k] = true
        end
    end
    local kinds = {}
    for _, k in ipairs(FLAG_KINDS) do
        if picked[k] then kinds[#kinds + 1] = k end
    end
    return { secondVoid = v.secondVoid, adminOnlyKinds = kinds }
end
RR._clean = Clean

function RR.registerControls()
    local dc = CP.DeptControls
    if not (dc and dc.register) then return false end
    dc.register(KEY, {
        kind = 'map',
        bounded = false,
        configValue = function() return { secondVoid = false, adminOnlyKinds = {} } end,
        check = function(v)
            local clean = Clean(v, true)
            if not clean then return nil, 'err.control_value' end
            return clean
        end,
        clamp = function(v) return Clean(v, false) end,
        -- stricter only: it applies to the supervisor who set it too
        relaxes = function() return false end,
        viewExtra = function() return { flagKinds = FLAG_KINDS } end,
    })
    return true
end
RR.registerControls()

-- The rules of a department: { secondVoid, adminOnlyKinds } (the config value, nothing stricter, while off).
function RR.rules(dept)
    local dc = CP.DeptControls
    if not (dc and dc.get) or type(dept) ~= 'string' then return nil end
    local ok, v = pcall(dc.get, dept, KEY)
    if not ok then
        CP.err(TAG, 'reading the %s control of %s failed: %s', KEY, dept, tostring(v))
        return nil
    end
    return type(v) == 'table' and v or nil
end

-- True when a flag of this kind on a row of dept goes to admins only.
function RR.adminOnly(dept, kind)
    local r = RR.rules(dept)
    if not r or type(r.adminOnlyKinds) ~= 'table' then return false end
    for _, k in ipairs(r.adminOnlyKinds) do
        if k == kind then return true end
    end
    return false
end

-- ============================================================================
--                                 SECOND VOID
-- ============================================================================

local function SameUser(a, b)
    if a == b then return true end
    local Access = CP.Access
    if not (Access and Access.licenseOf) then return false end
    local okA, la = pcall(Access.licenseOf, a)
    local okB, lb = pcall(Access.licenseOf, b)
    if not okA or not okB or not la or not lb then return false end
    if Access.sameUser then return Access.sameUser(la, lb) == true end
    return la == lb
end

-- A supervisor's Void of row (checks done by the caller): 'void' (go ahead; first = the pending Void it confirms, if
-- any), 'pending' (the first Void: the row waits for a second supervisor) or nil, errKey.
function RR.voidStep(officer, row)
    if type(officer) ~= 'table' or type(row) ~= 'table' then return nil, 'err.invalid_payload' end
    local r = RR.rules(row.department)
    if not r or r.secondVoid ~= true then return 'void' end
    local p = pending[row.id]
    if not p then
        pending[row.id] = {
            citizenid = officer.citizenid,
            name = officer.name,
            department = officer.department,
            at = os.time(),
        }
        return 'pending'
    end
    if SameUser(officer.citizenid, p.citizenid) then return nil, 'err.void_second_needed' end
    if officer.department ~= row.department then return nil, 'err.void_second_dept' end
    pending[row.id] = nil
    return 'void', p
end

-- The first Void a row waits on ({ name, at }) | nil.
function RR.pendingOf(rowId)
    local p = pending[rowId]
    if not p then return nil end
    return { name = p.name, at = p.at }
end

-- The row was voided or approved: a waiting Void is gone.
function RR.clear(rowId) pending[rowId] = nil end

-- Test hooks (not part of the contract).
RR._reset = function() pending = {} end
