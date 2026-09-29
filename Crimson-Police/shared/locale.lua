-- Loads locales/<Config.Locale>.json (falls back to en.json).

CP = CP or {}
CP.Locale = CP.Locale or {}

local strings = {}

local function LoadLocale(code)
    local raw = LoadResourceFile(GetCurrentResourceName(), ('locales/%s.json'):format(code))
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == 'table' then return data end
    print(('^1[crimson-police:locale] locales/%s.json is not valid JSON^7'):format(code))
    return nil
end

do
    local code = (Config and Config.Locale) or 'en'
    strings = LoadLocale(code) or {}
    if code ~= 'en' then
        -- Missing keys fall back to English.
        local en = LoadLocale('en') or {}
        for k, v in pairs(en) do
            if strings[k] == nil then strings[k] = v end
        end
    end
end

local function Interpolate(s, vars)
    if not vars then return s end
    return (
        s:gsub('{([%w_]+)}', function(k)
            local v = vars[k]
            if v == nil then return '{' .. k .. '}' end
            return tostring(v)
        end)
    )
end

-- Translate a key; unknown keys are returned as-is so a missing string is visible, not blank.
function CP.L(key, vars)
    local s = strings[key]
    if s == nil then return Interpolate(tostring(key), vars) end
    return Interpolate(s, vars)
end

function CP.Locale.has(key)
    return strings[key] ~= nil
end

-- Every string, sent to the NUI with the session so the UI shares one text source.
function CP.Locale.all()
    return strings
end
