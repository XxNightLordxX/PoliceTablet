-- The CP namespace, logging, the block registry, the config load check and RegisterMission(). Loaded on both sides
-- before every module. Only definitions live here: nothing in this file calls another module.

CP = CP or {}

CP.resource = GetCurrentResourceName()
CP.isServer = IsDuplicityVersion()
CP.prefix = 'crimson-police'

-- ============================================================================
--                                   LOGGING
-- ============================================================================
-- CP.log only prints with Config.Debug = true; warn and err always print.
local function Format(msg, ...)
    if select('#', ...) == 0 then return tostring(msg) end
    local ok, out = pcall(string.format, tostring(msg), ...)
    if ok then return out end
    local parts = { tostring(msg) }
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, ' ')
end

function CP.log(tag, msg, ...)
    if not Config.Debug then return end
    print(('[crimson-police:%s] %s'):format(tag, Format(msg, ...)))
end

function CP.warn(tag, msg, ...)
    print(('^3[crimson-police:%s]^7 %s'):format(tag, Format(msg, ...)))
end

function CP.err(tag, msg, ...)
    print(('^1[crimson-police:%s]^7 %s'):format(tag, Format(msg, ...)))
end

-- Full event / callback name: CP.e('server:acceptType') -> 'crimson-police:server:acceptType'
function CP.e(name)
    return CP.prefix .. ':' .. name
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================
-- In-resource events between modules (docs/notes/foundation.md lists them). fire() calls every listener in
-- the caller's thread, in the order they were added, each in pcall: a failing listener is logged and the
-- next one still runs. Listeners may only yield where the hook's contract allows it.
CP.Hooks = CP.Hooks or { _list = {}, _byId = {}, _next = 0 }

function CP.Hooks.on(name, fn)
    if type(name) ~= 'string' or name == '' or type(fn) ~= 'function' then return nil end
    local H = CP.Hooks
    H._next = H._next + 1
    local id = H._next
    local list = H._list[name]
    if not list then
        list = {}
        H._list[name] = list
    end
    list[#list + 1] = { id = id, fn = fn }
    H._byId[id] = name
    return id
end

function CP.Hooks.off(id)
    local H = CP.Hooks
    local name = H._byId[id]
    if not name then return false end
    H._byId[id] = nil
    local list = H._list[name] or {}
    for i, l in ipairs(list) do
        if l.id == id then
            table.remove(list, i)
            break
        end
    end
    return true
end

function CP.Hooks.fire(name, ...)
    local list = CP.Hooks._list[name]
    if not list or #list == 0 then return 0 end
    local copy = {}
    for i, l in ipairs(list) do copy[i] = l end
    local n = 0
    for _, l in ipairs(copy) do
        local ok, err = pcall(l.fn, ...)
        if ok then
            n = n + 1
        else
            CP.err('hooks', 'a %s listener failed: %s', name, tostring(err))
        end
    end
    return n
end

-- ============================================================================
--                           OBJECTIVE BLOCK REGISTRY
-- ============================================================================
-- blocks/<block_id>/server.lua and client.lua each call CP.Blocks.register(id, impl)
-- once. The run engine (modules/runs) looks blocks up by id. See docs/ARCHITECTURE.md.
CP.Blocks = CP.Blocks or { _list = {} }

function CP.Blocks.register(id, impl)
    if CP.Blocks._list[id] then
        CP.warn('blocks', 'block %s registered twice; the last one wins', id)
    end
    impl.id = id
    CP.Blocks._list[id] = impl
end

function CP.Blocks.get(id)
    return CP.Blocks._list[id]
end

function CP.Blocks.all()
    return CP.Blocks._list
end

-- ============================================================================
--                              CONFIG LOAD CHECK
-- ============================================================================
-- config/config.lua and config/blocks.lua load just before this file. When one stopped at an error (a missing
-- comma, quote or bracket) or config.lua is from an older version, every module fails in its own way: one line
-- first says why. The table sections of config.lua and blocks.lua, in file order.
local CONFIG_SECTIONS = {
    'Database',
    'Format',
    'Tablet',
    'AdminTheme',
    'Permissions',
    'Departments',
    'MissionTypes',
    'DisabledMissions',
    'Difficulty',
    'Cash',
    'Payouts',
    'Scaling',
    'Rescale',
    'Limits',
    'Route',
    'Calls',
    'Alerts',
    'Downed',
    'AntiCheat',
    'CrossDept',
    'Draw',
    'Units',
    'MissionCalls',
    'Custody',
    'Decisions',
    'Npc',
    'NpcDifficulty',
    'MissionTweaks',
    'Time',
    'Scoring',
    'Bonuses',
    'XPLevels',
    'XPCurve',
    'Badges',
    'Goals',
    'Leaderboard',
    'Events',
    'Challenge',
    'Profile',
    'Commendations',
    'Rewards',
    'Disputes',
    'Builder',
    'Testing',
    'Retention',
    'Blocks',
}
local MAX_NAMED_SECTIONS = 6

-- nil when cfg is whole, else 'error' or 'warn' and the line to print.
function CP.configProblem(cfg)
    if type(cfg) ~= 'table' then
        return 'error',
            'config/config.lua did not load, so Crimson-Police cannot work. The first red error above names the line to fix (usually a missing comma, quote or bracket); fix it and restart the resource.'
    end
    local missing = {}
    for _, name in ipairs(CONFIG_SECTIONS) do
        if type(cfg[name]) ~= 'table' then missing[#missing + 1] = 'Config.' .. name end
    end
    if #missing == 0 then return nil end
    local named = table.concat(missing, ', ', 1, math.min(#missing, MAX_NAMED_SECTIONS))
    if #missing > MAX_NAMED_SECTIONS then named = ('%s and %d more'):format(named, #missing - MAX_NAMED_SECTIONS) end
    return 'warn',
        ('%s %s missing: config/config.lua (or config/blocks.lua) stopped at an error, or it is from an older version. If a red error above names one of these files, fix that line; otherwise copy the missing blocks from the config.lua of this version. Then restart the resource.'):format(
            named, #missing == 1 and 'is' or 'are')
end

if CP.isServer then
    local level, text = CP.configProblem(Config)
    if level == 'error' then
        CP.err('config', '%s', text)
    elseif level == 'warn' then
        CP.warn('config', '%s', text)
    end
end

-- ============================================================================
--                               RegisterMission
-- ============================================================================
-- Every mission file contains exactly one RegisterMission({ ... }) call. The mission
-- loader (modules/missions) runs each file in a sandbox whose RegisterMission collects
-- the definition; this global only exists so a stray call is reported, not lost.
function RegisterMission(def)
    CP.warn('missions', 'RegisterMission(%s) was called outside the mission loader and was ignored',
        type(def) == 'table' and tostring(def.id) or '?')
end
