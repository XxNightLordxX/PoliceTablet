-- The CP namespace, logging, the block registry and RegisterMission(). Loaded on both sides before every module. Only
-- definitions live here: nothing in this file calls another module.

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
--                               RegisterMission
-- ============================================================================
-- Every mission file contains exactly one RegisterMission({ ... }) call. The mission
-- loader (modules/missions) runs each file in a sandbox whose RegisterMission collects
-- the definition; this global only exists so a stray call is reported, not lost.
function RegisterMission(def)
    CP.warn('missions', 'RegisterMission(%s) was called outside the mission loader and was ignored',
        type(def) == 'table' and tostring(def.id) or '?')
end
