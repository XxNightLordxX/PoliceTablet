-- Loads locales/<Config.Locale>.json (falls back to en.json).

-- All player-facing text lives in locales/en.json as a flat map of dotted keys, e.g.
--   "board.server_busy": "Server busy"
-- Placeholders use {name}: CP.L('run.ended_real_call') / CP.L('cash.paid', { amount = 250 })

CP = CP or {}
CP.Locale = CP.Locale or {}

local strings = nil                -- the locale's texts: read on first use (Strings), not while the scripts load

-- The plural form suffixes CP.Ln and the NUI's tn() read (key_<form>).
local PLURAL_FORMS = { 'zero', 'one', 'two', 'few', 'many', 'other' }
local FORM_OF = {}
for _, f in ipairs(PLURAL_FORMS) do FORM_OF[f] = true end

-- The base key of a plural form key ('admin.audit.total_one' -> 'admin.audit.total'), or nil.
local function BaseOf(k)
    local base, form = tostring(k):match('^(.+)_(%a+)$')
    if base and FORM_OF[form] then return base end
    return nil
end

-- The file reader as it is when this file loads (the same native in game; a test that hands its own locale file to
-- this load keeps it for the read on first use).
local readFile = LoadResourceFile

local function LoadLocale(code)
    local raw = readFile(GetCurrentResourceName(), ('locales/%s.json'):format(code))
    if not raw or raw == '' then return nil end
    local ok, data = pcall(json.decode, raw)
    if ok and type(data) == 'table' then return data end
    print(('^1[crimson-police:locale] locales/%s.json is not valid JSON^7'):format(code))
    return nil
end

-- The language is the one config.lua names when this file loads (as before); its file is read and decoded the
-- first time a text is needed, so the decode is not part of the resource's start-up hitch.
local localeCode = (Config and Config.Locale) or 'en'

local function Strings()
    if strings then return strings end
    local code = localeCode
    local t = LoadLocale(code) or {}
    if code ~= 'en' then
        -- Missing keys fall back to English. An English plural form (key_one, key_other) is left out when the
        -- translation has the base key itself (one written before the forms): its own text stays.
        local own = {}
        for k in pairs(t) do own[k] = true end
        local en = LoadLocale('en') or {}
        for k, v in pairs(en) do
            local base = BaseOf(k)
            if t[k] == nil and not (base and own[base]) then t[k] = v end
        end
    end
    strings = t
    return t
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

-- A name an admin gave in Settings → Names (Config.Labels, English text over the locale's), or nil.
local function Label(key)
    local labels = Config and Config.Labels
    if type(labels) ~= 'table' then return nil end
    local v = labels[key]
    if type(v) == 'string' and v ~= '' then return v end
    return nil
end

-- Translate a key; unknown keys are returned as-is so a missing string is visible, not blank.
function CP.L(key, vars)
    local s = Label(key) or Strings()[key]
    if s == nil then return Interpolate(tostring(key), vars) end
    return Interpolate(s, vars)
end

-- Plural forms: CP.Ln('key', n, vars) reads 'key_<form>' ('one' or 'other' by the rule of the locale's 'locale.lang',
-- English when it has no rule here), then 'key_other', then 'key' itself, so a key without forms keeps its text.
-- {n} is the count unless vars give one. The NUI does the same with tn() (web/src/shared/i18n.tsx).
local PLURAL = {
    en = function(n) return n == 1 and 'one' or 'other' end,
    fr = function(n) return (n == 0 or n == 1) and 'one' or 'other' end,
}

function CP.Ln(key, n, vars)
    n = tonumber(n) or 0
    local all = { n = n }
    for k, v in pairs(vars or {}) do all[k] = v end
    local lang = Label('locale.lang') or Strings()['locale.lang'] or 'en'
    local rule = PLURAL[lang] or PLURAL.en
    local form = key .. '_' .. rule(n)
    if Label(form) then return CP.L(form, all) end
    -- a Settings -> Names rename of the key itself (from before the forms) wins over the file's forms
    if Label(key) and not Label(key .. '_other') then return CP.L(key, all) end
    if Strings()[form] then return CP.L(form, all) end
    if Label(key .. '_other') or Strings()[key .. '_other'] then return CP.L(key .. '_other', all) end
    return CP.L(key, all)
end

function CP.Locale.has(key)
    return Label(key) ~= nil or Strings()[key] ~= nil
end

-- Whether locales/en.json itself has the key (Config.Labels left out).
function CP.Locale.inFile(key)
    return Strings()[key] ~= nil
end

-- Every string (with Config.Labels over it): the client sends it to the NUI with the reply to 'ready' and after a
-- Config.Labels change, so the UI shares one text source. Sessions do not carry it.
function CP.Locale.all()
    local labels = Config and Config.Labels
    if type(labels) ~= 'table' or next(labels) == nil then return Strings() end
    local out = {}
    for k, v in pairs(Strings()) do out[k] = v end
    for k, v in pairs(labels) do
        if type(k) == 'string' and type(v) == 'string' and v ~= '' then out[k] = v end
    end
    -- a renamed key that has plural forms in the file: the forms nobody renamed are left out, so the NUI's tn()
    -- shows the rename (as CP.Ln does) instead of the file's English forms
    for k in pairs(labels) do
        if type(k) == 'string' and Label(k) and not BaseOf(k) then
            for _, f in ipairs(PLURAL_FORMS) do
                local fk = k .. '_' .. f
                if out[fk] ~= nil and not Label(fk) then out[fk] = nil end
            end
        end
    end
    return out
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
    if type(key) == 'string' and (Strings()[key] ~= nil or Label(key)) then return CP.L(key, vars) end
    if fallback == nil then return CP.L(key, vars) end
    return Interpolate(tostring(fallback), vars)
end
