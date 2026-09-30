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

-- ============================================================================
--                         TOKENS FOR A PLAYER'S SCREEN
-- ============================================================================
-- CP.Lt(key, vars) is a text meant for a player's screen. The server never turns it into text: the engine
-- sends it as a token (\30 key \31 json(vars) \30) and the client resolves it just before the NUI. CP.L is
-- never replaced or wrapped, so a coroutine that yields can never leak a token into a webhook or the audit.
local TOKEN_OPEN, TOKEN_SEP = '\30', '\31'
local TOKEN_PATTERN = '\30([^\30\31]+)\31([^\30]*)\30'
local MAX_DEPTH = 6
local tokenMeta = {}

function CP.Lt(key, vars)
    return setmetatable({ key = tostring(key), vars = type(vars) == 'table' and vars or nil }, tokenMeta)
end

function CP.Locale.isToken(v)
    return type(v) == 'table' and getmetatable(v) == tokenMeta
end

local Encode

-- vars with nested tokens become plain values: a nested token is written as its own token string.
local function EncodeVars(vars, depth)
    if type(vars) ~= 'table' then return nil end
    local out = {}
    for k, v in pairs(vars) do
        if CP.Locale.isToken(v) then
            out[k] = Encode(v, depth + 1)
        elseif type(v) == 'table' then
            out[k] = EncodeVars(v, depth + 1)
        else
            out[k] = v
        end
    end
    return out
end

Encode = function(t, depth)
    depth = depth or 0
    if depth > MAX_DEPTH then return tostring(t.key) end
    local vars = EncodeVars(t.vars, depth)
    local js = ''
    if vars and next(vars) ~= nil then
        local ok, s = pcall(json.encode, vars)
        if ok and type(s) == 'string' then js = s end
    end
    return TOKEN_OPEN .. t.key .. TOKEN_SEP .. js .. TOKEN_OPEN
end

-- The token string of a CP.Lt text (a plain value comes back as it is).
function CP.Locale.encode(v)
    if CP.Locale.isToken(v) then return Encode(v, 0) end
    return v
end

-- A copy of a payload with every CP.Lt text in it turned into its token string (the engine's HUD path).
function CP.Locale.tokenize(v, depth)
    depth = depth or 0
    if CP.Locale.isToken(v) then return Encode(v, 0) end
    if type(v) ~= 'table' or getmetatable(v) ~= nil or depth > 8 then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = CP.Locale.tokenize(x, depth + 1) end
    return out
end

local Resolve

local function ResolveVars(vars, code, depth)
    for k, v in pairs(vars) do
        -- JSON gives whole numbers back as floats: 24, not 24.0
        if math.type(v) == 'float' and v == math.floor(v) and math.abs(v) < 2 ^ 53 then vars[k] = math.tointeger(v) end
        if type(v) == 'string' and v:find(TOKEN_OPEN, 1, true) then
            vars[k] = Resolve(v, code, depth + 1)
        elseif CP.Locale.isToken(v) then
            vars[k] = Resolve(v, code, depth + 1)
        end
    end
    return vars
end

Resolve = function(text, code, depth)
    depth = depth or 0
    if CP.Locale.isToken(text) then
        local vars = nil
        if type(text.vars) == 'table' then
            vars = {}
            for k, v in pairs(text.vars) do vars[k] = v end
            ResolveVars(vars, code, depth)
        end
        return CP.L(text.key, vars)
    end
    if type(text) ~= 'string' or not text:find(TOKEN_OPEN, 1, true) or depth > MAX_DEPTH then return text end
    return (
        text:gsub(TOKEN_PATTERN, function(key, js)
            local vars = nil
            if js ~= '' then
                local ok, t = pcall(json.decode, js)
                if ok and type(t) == 'table' then vars = ResolveVars(t, code, depth) end
            end
            return CP.L(key, vars)
        end)
    )
end

-- Expand the tokens in a text (nested ones too). code is the player's language; this build ships English
-- only, so every token resolves in the server language.
function CP.Locale.resolve(text, code)
    return Resolve(text, code, 0)
end

-- A copy of a payload with every token in it resolved (the client, right before SendNUIMessage).
function CP.Locale.resolveAll(v, code, depth)
    depth = depth or 0
    if type(v) == 'string' or CP.Locale.isToken(v) then return Resolve(v, code, 0) end
    if type(v) ~= 'table' or getmetatable(v) ~= nil or depth > 8 then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = CP.Locale.resolveAll(x, code, depth + 1) end
    return out
end

-- The locale text of key when the locale has it, else the fallback text (both with vars filled in).
function CP.Locale.label(key, fallback, vars)
    if type(key) == 'string' and strings[key] ~= nil then return CP.L(key, vars) end
    if fallback == nil then return CP.L(key, vars) end
    return Interpolate(tostring(fallback), vars)
end
