-- CP.ConfigHealth (server): the Config health list of Admin UI → Permissions. Every check reports lines of
-- { level = 'ok' | 'warn' | 'error', text }; modules add their own with register (item rewards do).

CP.ConfigHealth = CP.ConfigHealth or {}
local Health = CP.ConfigHealth
local TAG = 'confighealth'

local START_DELAY_MS = 5000       -- the first run: after every module and ox_inventory have loaded
local LEVELS = { ok = true, warn = true, error = true }
local HOST_PATTERN = '^[%w][%w%-%.]*%.[%a][%a]+$'
local EXPIRING_HOSTS = { ['cdn.discordapp.com'] = true, ['media.discordapp.net'] = true }
local THEME_KEYS = { 'primary', 'accent', 'background', 'surface' }

local checks = {}          -- { { name, fn } } in the order registered
local results = nil        -- the last run: { ConfigHealthItem }

local function Line(level, key, vars)
    return { level = level, text = CP.L(key, vars) }
end

local function IsVec(v)
    return (type(v) == 'vector3' or type(v) == 'table') and tonumber(v.x) ~= nil and tonumber(v.y) ~= nil
        and tonumber(v.z) ~= nil
end

-- ============================================================================
--                                   REGISTRY
-- ============================================================================

-- fn() -> { { level, text } }. A second register of a name replaces the first.
function Health.register(name, fn)
    if type(name) ~= 'string' or name == '' or type(fn) ~= 'function' then return false end
    for _, c in ipairs(checks) do
        if c.name == name then
            c.fn = fn
            return true
        end
    end
    checks[#checks + 1] = { name = name, fn = fn }
    return true
end

-- Every check once: the ConfigHealthItem list (web/src/shared/types.ts), errors first.
function Health.run()
    local out = {}
    for _, c in ipairs(checks) do
        local ok, lines = pcall(c.fn)
        if not ok then
            CP.err(TAG, 'check %s failed: %s', c.name, tostring(lines))
            out[#out + 1] = { check = c.name, level = 'error', text = CP.L('health.check_failed') }
        else
            for _, l in ipairs(type(lines) == 'table' and lines or {}) do
                if type(l) == 'table' and LEVELS[l.level] and type(l.text) == 'string' then
                    out[#out + 1] = { check = c.name, level = l.level, text = l.text }
                end
            end
        end
    end
    local rank = { error = 1, warn = 2, ok = 3 }
    for i, item in ipairs(out) do item.order = i end
    table.sort(out, function(a, b)
        if rank[a.level] ~= rank[b.level] then return rank[a.level] < rank[b.level] end
        return a.order < b.order
    end)
    for _, item in ipairs(out) do item.order = nil end
    -- the console gets the problems of the first run only (the admin screen runs the checks again)
    if not results then
        for _, item in ipairs(out) do
            if item.level ~= 'ok' then CP.warn(TAG, '%s: %s', item.check, item.text) end
        end
    end
    results = out
    return out
end

-- ============================================================================
--                               THE TABLET ITEM
-- ============================================================================

local function CheckItems()
    local t = Config.Tablet or {}
    local access = type(t.access) == 'table' and t.access or {}
    local item = type(t.item) == 'string' and t.item ~= '' and t.item or nil
    if not item then
        if access.requireItem == true then return { Line('error', 'health.item.require_no_item') } end
        return { Line('ok', 'health.item.off') }
    end
    if GetResourceState('ox_inventory') ~= 'started' then
        return { Line('error', 'health.item.no_inventory', { item = item }) }
    end
    local ok, def = pcall(function() return exports.ox_inventory:Items(item) end)
    if not ok or def == nil then return { Line('warn', 'health.item.missing', { item = item }) } end
    local out = { Line('ok', 'health.item.ok', { item = item }) }
    if access.item == false and access.requireItem ~= true then
        out[#out + 1] = Line('warn', 'health.item.way_off', { item = item })
    end
    return out
end

-- ============================================================================
--                                MISSION DESKS
-- ============================================================================

local function CheckDesks()
    local t = Config.Tablet or {}
    if type(t.access) == 'table' and t.access.desk == false then return { Line('ok', 'health.desk.off') } end
    local desks = type(t.desks) == 'table' and t.desks or {}
    if #desks == 0 then return { Line('ok', 'health.desk.none') } end
    local out, good = {}, 0
    for i, d in ipairs(desks) do
        local label = type(d) == 'table' and tostring(d.label or i) or tostring(i)
        if type(d) ~= 'table' or not IsVec(d.coords) then
            out[#out + 1] = Line('error', 'health.desk.coords', { n = i, label = label })
        elseif d.size ~= nil and not IsVec(d.size) then
            out[#out + 1] = Line('warn', 'health.desk.size', { n = i, label = label })
        else
            local unknown = {}
            for _, k in ipairs(type(d.departments) == 'table' and d.departments or {}) do
                if not (Config.Departments and Config.Departments[k]) then unknown[#unknown + 1] = tostring(k) end
            end
            if #unknown > 0 then
                out[#out + 1] = Line('warn', 'health.desk.department',
                    { n = i, label = label, departments = table.concat(unknown, ', ') })
            else
                good = good + 1
            end
        end
    end
    if GetResourceState('ox_target') ~= 'started' then out[#out + 1] = Line('error', 'health.desk.no_target') end
    table.insert(out, 1, Line('ok', 'health.desk.ok', { n = good, total = #desks }))
    return out
end

-- ============================================================================
--                   DEPARTMENT COLOURS AND PERSONAL ACCENTS
-- ============================================================================

local function CheckColours()
    local out = {}
    local keys = {}
    for k in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local d = Config.Departments[key]
        local theme = type(d) == 'table' and type(d.theme) == 'table' and d.theme or {}
        for _, k in ipairs(THEME_KEYS) do
            if not CP.U.isHexColour(theme[k]) then
                out[#out + 1] = Line('warn', 'health.colour.theme', { dept = tostring(key), key = k })
            end
        end
        local accents = theme.personalAccents
        if accents ~= nil and type(accents) ~= 'table' then
            out[#out + 1] = Line('warn', 'health.colour.accents_list', { dept = tostring(key) })
        else
            local seen, n = {}, 0
            for i, a in ipairs(accents or {}) do
                local colour = type(a) == 'table' and a.colour or a
                local level = type(a) == 'table' and a.level or nil
                if not CP.U.isHexColour(colour) then
                    out[#out + 1] = Line('warn', 'health.colour.accent', { dept = tostring(key), n = i })
                elseif level ~= nil and (not math.tointeger(tonumber(level)) or tonumber(level) < 1) then
                    out[#out + 1] = Line('warn', 'health.colour.accent_level', { dept = tostring(key), n = i })
                elseif seen[colour:lower()] then
                    out[#out + 1] = Line('warn', 'health.colour.accent_twice',
                        { dept = tostring(key), colour = colour })
                else
                    seen[colour:lower()] = true
                    n = n + 1
                end
            end
            if n > 0 then out[#out + 1] = Line('ok', 'health.colour.accents', { dept = tostring(key), n = n }) end
        end
    end
    local warned = false
    for _, l in ipairs(out) do if l.level ~= 'ok' then warned = true end end
    if not warned then table.insert(out, 1, Line('ok', 'health.colour.ok')) end
    return out
end

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================

local function CheckTweaks()
    local tweaks = Config.MissionTweaks
    if type(tweaks) ~= 'table' or next(tweaks) == nil then return { Line('ok', 'health.tweak.none') } end
    local out, applied = {}, 0
    local ids = {}
    for id in pairs(tweaks) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local def = CP.Missions and CP.Missions.get and CP.Missions.get(id) or nil
        if not def then
            out[#out + 1] = Line('warn', 'health.tweak.unknown', { id = id })
        elseif def.tweaked == true then
            applied = applied + 1
        else
            out[#out + 1] = Line('warn', 'health.tweak.ignored', { id = id })
        end
    end
    table.insert(out, 1, Line('ok', 'health.tweak.ok', { n = applied, total = #ids }))
    return out
end

-- ============================================================================
--                                 LOCALE FILES
-- ============================================================================

local function CheckLocale()
    local out = {}
    local raw = LoadResourceFile(CP.resource, 'locales/en.json')
    if not raw or raw == '' then return { Line('error', 'health.locale.missing') } end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return { Line('error', 'health.locale.invalid') } end
    local n = 0
    for _ in pairs(data) do n = n + 1 end
    out[#out + 1] = Line('ok', 'health.locale.ok', { n = n })
    -- English is the only language this build ships
    local code = Config.Locale
    if code ~= nil and code ~= 'en' then
        out[#out + 1] = Line('warn', 'health.locale.not_en', { code = tostring(code) })
    end
    return out
end

-- ============================================================================
--                              AVATAR LINK HOSTS
-- ============================================================================

local function CheckAvatarHosts()
    local urls = Config.Profile and Config.Profile.avatarUrls
    if type(urls) ~= 'table' or urls.enabled ~= true then return { Line('ok', 'health.avatar.off') } end
    local hosts = type(urls.hosts) == 'table' and urls.hosts or {}
    local out, good = {}, 0
    for _, h in ipairs(hosts) do
        if type(h) ~= 'string' or not h:lower():match(HOST_PATTERN) then
            out[#out + 1] = Line('warn', 'health.avatar.bad_host', { host = tostring(h) })
        elseif EXPIRING_HOSTS[h:lower()] then
            out[#out + 1] = Line('warn', 'health.avatar.expiring', { host = h })
        else
            good = good + 1
        end
    end
    if good == 0 then
        table.insert(out, 1, Line('warn', 'health.avatar.no_hosts'))
    else
        table.insert(out, 1, Line('ok', 'health.avatar.ok', { n = good }))
    end
    if urls.requireApproval == false then out[#out + 1] = Line('warn', 'health.avatar.no_approval') end
    return out
end

Health.register('items', CheckItems)
Health.register('desks', CheckDesks)
Health.register('colours', CheckColours)
Health.register('tweaks', CheckTweaks)
Health.register('locale', CheckLocale)
Health.register('avatars', CheckAvatarHosts)

-- ============================================================================
--                                   CALLBACK
-- ============================================================================

CP.Net.callback('admin:getConfigHealth', function(src)
    if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return nil, 'err.not_admin' end
    -- every call runs the checks again: the screen's "Check again" shows a fix at once
    return Health.run()
end, { rate = 2 })

CreateThread(function()
    Wait(START_DELAY_MS)
    -- a module that loads later than this file may not have registered yet: item rewards' lines come here too
    local rewards = CP.Rewards
    if type(rewards) == 'table' and type(rewards.health) == 'function' then
        Health.register('rewards', rewards.health)
    end
    Health.run()
end)

-- Test hooks (not part of the contract).
Health._checks = function() return checks end
Health._reset = function() results = nil end
