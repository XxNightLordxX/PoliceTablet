-- CP.OptionDefs: the registry of officer options (the My options choices an officer makes for their own tablet) and
-- their rules. Pure Lua, no natives. Config.OfficerOptions (and a department's officerOptions) is read at every call.
-- No option is registered here: each feature registers its own keys with add().

CP.OptionDefs = CP.OptionDefs or { _list = {}, _order = {} }
local Defs = CP.OptionDefs

local KINDS = { bool = true, enum = true, list = true, number = true }
local STORES = { server = true, ['local'] = true }

local function Finite(v)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

-- def: { kind = 'bool'|'enum'|'list'|'number', values = list | function() -> list (enum and list), default,
-- min, max (number: the widest bounds an owner may set), integer (number: whole numbers only), store = 'server'
-- (saved per character, the default) | 'local' (kept by the tablet only), group, order, guard = function(clean) ->
-- nil | errKey (refuses a whole value, e.g. a list that hides every type) }. Returns true, or false and why.
function Defs.add(key, def)
    if type(key) ~= 'string' or key == '' or type(def) ~= 'table' then return false, 'a key and a table' end
    if not KINDS[def.kind] then return false, 'unknown kind ' .. tostring(def.kind) end
    local store = def.store or 'server'
    if not STORES[store] then return false, 'unknown store ' .. tostring(store) end
    if (def.kind == 'enum' or def.kind == 'list') and type(def.values) ~= 'table'
        and type(def.values) ~= 'function' then
        return false, 'an enum or list option needs values'
    end
    local entry = {
        key = key,
        kind = def.kind,
        values = def.values,
        default = def.default,
        min = Finite(def.min),
        max = Finite(def.max),
        integer = def.integer == true,
        store = store,
        group = type(def.group) == 'string' and def.group or 'general',
        order = Finite(def.order) or 100,
        guard = type(def.guard) == 'function' and def.guard or nil,
    }
    if entry.kind == 'bool' and type(entry.default) ~= 'boolean' then entry.default = false end
    if entry.kind == 'list' and type(entry.default) ~= 'table' then entry.default = {} end
    if not Defs._list[key] then Defs._order[#Defs._order + 1] = key end
    Defs._list[key] = entry
    return true
end

-- Forgets a key (the specs register test keys).
function Defs.remove(key)
    if not Defs._list[key] then return end
    Defs._list[key] = nil
    for i, k in ipairs(Defs._order) do
        if k == key then
            table.remove(Defs._order, i)
            break
        end
    end
end

function Defs.get(key) return Defs._list[key] end

-- Every registered key, in group then order then key order.
function Defs.keys()
    local out = {}
    for _, k in ipairs(Defs._order) do out[#out + 1] = k end
    table.sort(out, function(a, b)
        local da, db = Defs._list[a], Defs._list[b]
        if da.group ~= db.group then return da.group < db.group end
        if da.order ~= db.order then return da.order < db.order end
        return a < b
    end)
    return out
end

-- The values an enum or list option offers now (a function is asked at every call: mission types come and go).
function Defs.values(key)
    local d = Defs._list[key]
    if not d then return {} end
    local v = d.values
    if type(v) == 'function' then
        local ok, list = pcall(v)
        v = ok and list or nil
    end
    local out = {}
    for _, x in ipairs(type(v) == 'table' and v or {}) do
        if type(x) == 'string' or type(x) == 'number' then out[#out + 1] = x end
    end
    return out
end

local function Member(list, v)
    for _, x in ipairs(list) do
        if x == v then return true end
    end
    return false
end

-- bounds: { min, max } (or { min = , max = }) inside the option's own min and max. Returns lo, hi (either nil).
local function Range(d, bounds)
    local lo, hi = d.min, d.max
    if type(bounds) == 'table' then
        local bl, bh = Finite(bounds.min or bounds[1]), Finite(bounds.max or bounds[2])
        if bl and (lo == nil or bl > lo) then lo = bl end
        if bh and (hi == nil or bh < hi) then hi = bh end
    end
    if lo and hi and lo > hi then hi = lo end
    return lo, hi
end

-- A clean value for the option, or nil and 'err.invalid_payload' (unknown key) | 'err.option_value'. Enum and list
-- values must be offered now (a list is de-duplicated); numbers are clamped to bounds. opts.drop = true: list
-- entries no longer offered are dropped instead of refusing the list (a saved value read back).
function Defs.check(key, value, bounds, opts)
    local d = Defs._list[key]
    if not d then return nil, 'err.invalid_payload' end
    if d.kind == 'bool' then
        if type(value) ~= 'boolean' then return nil, 'err.option_value' end
        return value
    elseif d.kind == 'enum' then
        if (type(value) ~= 'string' and type(value) ~= 'number') or not Member(Defs.values(key), value) then
            return nil, 'err.option_value'
        end
        return value
    elseif d.kind == 'list' then
        if type(value) ~= 'table' then return nil, 'err.option_value' end
        local offered = Defs.values(key)
        local out, seen = {}, {}
        for i, x in pairs(value) do
            if math.type(i) ~= 'integer' then return nil, 'err.option_value' end
        end
        for _, x in ipairs(value) do
            if not Member(offered, x) then
                if not (opts and opts.drop) then return nil, 'err.option_value' end
            elseif not seen[x] then
                seen[x] = true
                out[#out + 1] = x
            end
        end
        return out
    end
    local n = type(value) == 'number' and Finite(value) or nil
    if n == nil then return nil, 'err.option_value' end
    if d.integer then n = math.floor(n + 0.5) end
    local lo, hi = Range(d, bounds)
    if lo and n < lo then n = lo end
    if hi and n > hi then n = hi end
    if d.integer then n = math.tointeger(n) or n end
    return n
end

-- The option's guard on a clean value: nil when it passes (or there is none), else the error key.
function Defs.refused(key, clean)
    local d = Defs._list[key]
    if not (d and d.guard) then return nil end
    local ok, errKey = pcall(d.guard, clean)
    if not ok then return 'err.option_value' end
    return type(errKey) == 'string' and errKey or nil
end

-- Two clean values alike (lists in order).
function Defs.same(a, b)
    if type(a) ~= 'table' or type(b) ~= 'table' then return a == b end
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for i, x in ipairs(v) do out[i] = x end
    return out
end

-- Config.OfficerOptions.enabled (false = no My options screen; every option keeps its default for everyone).
function Defs.enabled()
    local c = type(Config) == 'table' and Config.OfficerOptions or nil
    return not (type(c) == 'table' and c.enabled == false)
end

-- allow, defaults, bounds for an officer of the department: the option's own default <- Config.OfficerOptions <-
-- the department's officerOptions (each part per key; a value that fails check() is skipped). Registered keys only.
function Defs.resolve(deptKey)
    local cfg = type(Config) == 'table' and Config or {}
    local global = type(cfg.OfficerOptions) == 'table' and cfg.OfficerOptions or {}
    local deps = type(cfg.Departments) == 'table' and cfg.Departments or {}
    local dept = type(deptKey) == 'string' and type(deps[deptKey]) == 'table' and deps[deptKey].officerOptions or nil
    dept = type(dept) == 'table' and dept or {}
    local layers = { global, dept }
    local allow, defaults, bounds = {}, {}, {}
    for _, key in ipairs(Defs.keys()) do
        local d = Defs._list[key]
        allow[key] = true
        for _, l in ipairs(layers) do
            if type(l.allow) == 'table' and type(l.allow[key]) == 'boolean' then allow[key] = l.allow[key] end
        end
        if d.kind == 'number' then
            local b = nil
            for _, l in ipairs(layers) do
                local lb = type(l.bounds) == 'table' and l.bounds[key] or nil
                if type(lb) == 'table' then b = lb end
            end
            local lo, hi = Range(d, b)
            bounds[key] = { min = lo, max = hi }
        end
        local value = Defs.check(key, d.default, bounds[key], { drop = true })
        for _, l in ipairs(layers) do
            if type(l.defaults) == 'table' and l.defaults[key] ~= nil then
                local clean = Defs.check(key, l.defaults[key], bounds[key], { drop = true })
                if clean ~= nil then value = clean end
            end
        end
        defaults[key] = Copy(value)
    end
    return allow, defaults, bounds
end

-- An officerOptions table (Config.OfficerOptions or a department's) holds known keys and good values only. nil when
-- it does, else the error key and the key at fault ('err.option_config').
function Defs.checkConfig(t)
    if t == nil then return nil end
    if type(t) ~= 'table' then return 'err.option_config', 'officerOptions' end
    for _, part in ipairs({ 'allow', 'defaults', 'bounds' }) do
        local p = t[part]
        if p ~= nil and type(p) ~= 'table' then return 'err.option_config', part end
        for key, v in pairs(type(p) == 'table' and p or {}) do
            local d = Defs._list[key]
            if not d then return 'err.option_config', tostring(key) end
            if part == 'allow' and type(v) ~= 'boolean' then return 'err.option_config', key end
            if part == 'defaults' then
                local clean = Defs.check(key, v)
                if clean == nil or Defs.refused(key, clean) then return 'err.option_config', key end
            end
            if part == 'bounds' then
                local lo = type(v) == 'table' and Finite(v.min or v[1]) or nil
                local hi = type(v) == 'table' and Finite(v.max or v[2]) or nil
                if d.kind ~= 'number' or not lo or not hi or lo > hi then return 'err.option_config', key end
            end
        end
    end
    return nil
end
