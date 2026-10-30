-- CP.Options (client): the officer options as this PC sees them. A 'local' option (CP.OptionDefs store = 'local':

CP.Options = CP.Options or {}
local O = CP.Options
local Defs = CP.OptionDefs
local TAG = 'options'
local KVP = 'crimsonpolice:options'

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for i, x in ipairs(v) do out[i] = x end
    return out
end

-- The KVP object: {} when there is none, the native is missing or it does not read.
local function ReadStore()
    if type(GetResourceKvpString) ~= 'function' then return {} end
    local ok, raw = pcall(GetResourceKvpString, KVP)
    if not ok or type(raw) ~= 'string' or raw == '' then return {} end
    local okDecode, t = pcall(json.decode, raw)
    return okDecode and type(t) == 'table' and t or {}
end

local function WriteStore(t)
    local ok, err = pcall(SetResourceKvp, KVP, next(t) ~= nil and json.encode(t) or '{}')
    if not ok then CP.err(TAG, 'saving the options of this PC failed: %s', tostring(err)) end
    return ok
end

-- The rules for this officer: enabled, allow, defaults, bounds (the session's, else Config for his department).
local function Rules()
    local values, rules, dept = nil, nil, nil
    if CP.Access and CP.Access.optionsView then values, rules, dept = CP.Access.optionsView() end
    if type(rules) ~= 'table' then
        local allow, defaults, bounds = Defs.resolve(dept)
        rules = { enabled = Defs.enabled(), allow = allow, defaults = defaults, bounds = bounds }
    end
    return type(values) == 'table' and values or {}, rules
end

local function Part(rules, name)
    return type(rules[name]) == 'table' and rules[name] or {}
end

-- The option's value now: the default while the option is locked (allow false) or officer options are off, else
-- this PC's value ('local') or the session's ('server'), each only while it is still good. nil for an unknown key.
function O.get(key)
    local d = Defs.get(key)
    if not d then return nil end
    local values, rules = Rules()
    local default = Part(rules, 'defaults')[key]
    if default == nil then default = Defs.check(key, d.default, Part(rules, 'bounds')[key], { drop = true }) end
    if rules.enabled == false or Part(rules, 'allow')[key] == false then return Copy(default) end
    local v
    if d.store == 'local' then v = ReadStore()[key] else v = values[key] end
    if v ~= nil then
        local clean = Defs.check(key, v, Part(rules, 'bounds')[key], { drop = true })
        if clean ~= nil then return clean end
    end
    return Copy(default)
end

-- Every 'local' option and its value now (the NUI message localOptions, the client action getLocalOptions).
function O.localValues()
    local out = {}
    for _, key in ipairs(Defs.keys()) do
        if Defs.get(key).store == 'local' then out[key] = O.get(key) end
    end
    return out
end

function O.sendLocal()
    if CP.Tablet and CP.Tablet.send then CP.Tablet.send({ type = 'localOptions', options = O.localValues() }) end
end

-- What every option was at the last refresh (the 'options:changed' hook fires for the keys that differ).
local last = {}

local function Snapshot()
    local out = {}
    for _, key in ipairs(Defs.keys()) do out[key] = O.get(key) end
    return out
end

-- The session, the push 'options' or this PC changed: fire 'options:changed' (key) for each option whose value
-- changed, then send the NUI the local values when any did (always when force).
function O.refresh(force)
    local now = Snapshot()
    local changed = {}
    for key, v in pairs(now) do
        if last[key] == nil or not Defs.same(last[key], v) then changed[#changed + 1] = key end
    end
    for key in pairs(last) do
        if now[key] == nil then changed[#changed + 1] = key end
    end
    last = now
    table.sort(changed)
    for _, key in ipairs(changed) do CP.Hooks.fire('options:changed', key) end
    if force or #changed > 0 then O.sendLocal() end
    return changed
end

-- Sets a 'local' option on this PC. Returns true and the clean value, or false and the error key.
function O.setLocal(key, value)
    local d = Defs.get(key)
    if type(key) ~= 'string' or not d or d.store ~= 'local' then return false, 'err.invalid_payload' end
    local _, rules = Rules()
    if rules.enabled == false or Part(rules, 'allow')[key] == false then return false, 'err.option_locked' end
    local clean, err = Defs.check(key, value, Part(rules, 'bounds')[key])
    if clean == nil then return false, err or 'err.option_value' end
    local store = ReadStore()
    local default = Part(rules, 'defaults')[key]
    if default ~= nil and Defs.same(default, clean) then store[key] = nil else store[key] = clean end
    if not WriteStore(store) then return false, 'err.internal' end
    O.refresh(true)
    return true, clean
end

-- The sound groups and the option that turns each on or off on this PC (shared/options_sounds.lua).
local SOUND_OPTION = { calls = 'soundCalls', unit = 'soundUnit', cues = 'soundCues' }

-- Plays a frontend sound of a group ('calls', 'unit' or 'cues') unless the officer turned that group off on this PC.
-- Returns true when it played.
function O.sound(group, name, set, p3)
    local key = SOUND_OPTION[group]
    if key and O.get(key) == false then return false end
    if type(PlaySoundFrontend) ~= 'function' then return false end
    PlaySoundFrontend(-1, name, set, p3 == true)
    return true
end

-- The push 'options' ({ values }): the officer's server options changed.
RegisterNetEvent(CP.e('client:push'), function(topic, data)
    if topic ~= 'options' or type(data) ~= 'table' or type(data.values) ~= 'table' then return end
    if CP.Access and CP.Access.setOptions then CP.Access.setOptions(data.values) end
end)

-- The options of this PC apply from the start, before any session.
last = Snapshot()

-- ============================================================================
--           CLIENT ACTIONS (registered once every module has loaded)
-- ============================================================================

CreateThread(function()
    Wait(0)
    if not (CP.Tablet and CP.Tablet.registerClientAction) then
        CP.err(TAG, 'modules/tablet is missing: the options of this PC cannot be changed from the tablet')
        return
    end
    CP.Tablet.registerClientAction('getLocalOptions', function()
        return true, { options = O.localValues() }
    end)
    CP.Tablet.registerClientAction('setLocalOption', function(payload)
        if type(payload) ~= 'table' or type(payload.key) ~= 'string' then return false, 'err.invalid_payload' end
        local ok, res = O.setLocal(payload.key, payload.value)
        if not ok then return false, res end
        return true, { key = payload.key, value = res, options = O.localValues() }
    end)
end)
