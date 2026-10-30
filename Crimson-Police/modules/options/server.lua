-- CP.Options (server): each character's officer options (My options), saved sparse in cp_officers.options (JSON: only
-- the keys that differ from the default). The rules (which options exist, their values, defaults and bounds) are
-- CP.OptionDefs (shared/options.lua) with Config.OfficerOptions and the department's officerOptions.

CP.Options = CP.Options or {}
local Options = CP.Options
local Defs = CP.OptionDefs
local TAG = 'options'

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

-- The saved options of a row: a JSON text (or a table) -> table, {} when there is none or it does not read.
function Options.decode(raw)
    if type(raw) == 'table' then return raw end
    if type(raw) ~= 'string' or raw == '' then return {} end
    local ok, t = pcall(json.decode, raw)
    return ok and type(t) == 'table' and t or {}
end

local function ReadRaw(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    Db()
    local ok, row = pcall(MySQL.single.await, 'SELECT options FROM cp_officers WHERE citizenid = ?', { citizenid })
    if not ok then
        CP.err(TAG, 'reading the options of %s failed: %s', citizenid, tostring(row))
        return nil
    end
    return type(row) == 'table' and row.options or nil
end

-- What the officer's server options are now: the defaults, then each saved value while its option is allowed and
-- the value is still good (a list entry no longer offered is dropped). A saved value of an option that is not allowed
-- now is ignored, not deleted, so allowing it again brings it back. raw = the row's options (nil: read it).
-- Config.OfficerOptions.enabled = false: the defaults only.
function Options.effective(citizenid, deptKey, raw)
    local allow, defaults, bounds = Defs.resolve(deptKey)
    if raw == nil then raw = ReadRaw(citizenid) end
    local saved = Defs.enabled() and Options.decode(raw) or {}
    local out = {}
    for _, key in ipairs(Defs.keys()) do
        local d = Defs.get(key)
        if d.store == 'server' then
            local v = defaults[key]
            if allow[key] and saved[key] ~= nil then
                local clean = Defs.check(key, saved[key], bounds[key], { drop = true })
                if clean ~= nil then v = clean end
            end
            out[key] = v
        end
    end
    return out
end

-- The officer's options for the tablet: { enabled, schema, values } (schema: the allowed options only).
function Options.view(officer)
    local allow, defaults, bounds = Defs.resolve(officer.department)
    local schema = {}
    for _, key in ipairs(Defs.keys()) do
        local d = Defs.get(key)
        if allow[key] then
            schema[#schema + 1] = {
                key = key,
                kind = d.kind,
                values = (d.kind == 'enum' or d.kind == 'list') and Defs.values(key) or nil,
                default = defaults[key],
                bounds = bounds[key],
                store = d.store,
                group = d.group,
                order = d.order,
            }
        end
    end
    return {
        enabled = Defs.enabled(),
        schema = schema,
        values = Options.effective(officer.citizenid, officer.department),
    }
end

-- The session's config.officerOptions: { enabled, allow, defaults, bounds } for the officer's department.
function Options.config(deptKey)
    local allow, defaults, bounds = Defs.resolve(deptKey)
    return { enabled = Defs.enabled(), allow = allow, defaults = defaults, bounds = bounds }
end

local function Write(officer, saved)
    local text = next(saved) ~= nil and json.encode(saved) or nil
    local ok, err = pcall(function()
        MySQL.update.await([[INSERT IGNORE INTO cp_officers (citizenid, callsign, display_name, department)
            VALUES (?, NULLIF(?, ''), ?, ?)]], {
            officer.citizenid,
            CP.U.clip(officer.callsign or '', 32),
            CP.U.clip(officer.name or '', 64),
            officer.department,
        })
        MySQL.update.await('UPDATE cp_officers SET options = ? WHERE citizenid = ?', { text, officer.citizenid })
    end)
    if not ok then CP.err(TAG, 'saving the options of %s failed: %s', officer.citizenid, tostring(err)) end
    return ok
end

-- server:options:set { key = value, ... }: the on-duty officer's own options. true, { values } | false, errKey.
function Options.set(src, patch)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return false, errKey or 'err.not_police' end
    if type(patch) ~= 'table' or next(patch) == nil then return false, 'err.invalid_payload' end
    if not Defs.enabled() then return false, 'err.option_locked' end
    local allow, defaults, bounds = Defs.resolve(officer.department)
    local clean = {}
    for key, value in pairs(patch) do
        local d = type(key) == 'string' and Defs.get(key) or nil
        if not d or d.store ~= 'server' then return false, 'err.invalid_payload' end
        if not allow[key] then return false, 'err.option_locked' end
        local v = Defs.check(key, value, bounds[key])
        if v == nil then return false, 'err.option_value' end
        local refused = Defs.refused(key, v)
        if refused then return false, refused end
        clean[key] = v
    end
    local saved = Options.decode(ReadRaw(officer.citizenid))
    for key, v in pairs(clean) do
        if Defs.same(v, defaults[key]) then
            saved[key] = nil
        else
            saved[key] = v
        end
    end
    if not Write(officer, saved) then return false, 'err.internal' end
    local values = Options.effective(officer.citizenid, officer.department, saved)
    CP.log(TAG, '%s changed their options', officer.citizenid)
    if CP.Tablet and CP.Tablet.push then CP.Tablet.push(src, 'options', { values = values }) end
    return true, { values = values }
end

CP.Net.callback('getOptions', function(src)
    local officer, errKey = CP.Access.getOfficer(src)
    if not officer then return nil, errKey or 'err.not_police' end
    return Options.view(officer)
end, { rate = 4 })

CP.Net.action('server:options:set', function(src, patch) return Options.set(src, patch) end, { rate = 4 })
