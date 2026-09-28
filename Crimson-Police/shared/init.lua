-- shared/init.lua · the CP namespace, logging, the block registry and RegisterMission().
-- Loaded on both sides before every module. Only definitions live here: nothing in this
-- file calls another module.

CP = CP or {}

CP.resource = GetCurrentResourceName()
CP.isServer = IsDuplicityVersion()
CP.prefix   = 'crimson-police'

-- ── Logging ─────────────────────────────────────────────────────────────────
-- CP.log only prints with Config.Debug = true; warn and err always print.
local function format(msg, ...)
    if select('#', ...) == 0 then return tostring(msg) end
    local ok, out = pcall(string.format, tostring(msg), ...)
    if ok then return out end
    local parts = { tostring(msg) }
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    return table.concat(parts, ' ')
end

function CP.log(tag, msg, ...)
    if not Config.Debug then return end
    print(('[crimson-police:%s] %s'):format(tag, format(msg, ...)))
end

function CP.warn(tag, msg, ...)
    print(('^3[crimson-police:%s] %s^7'):format(tag, format(msg, ...)))
end

function CP.err(tag, msg, ...)
    print(('^1[crimson-police:%s] %s^7'):format(tag, format(msg, ...)))
end

-- Full event / callback name: CP.e('server:acceptType') -> 'crimson-police:server:acceptType'
function CP.e(name)
    return CP.prefix .. ':' .. name
end

-- ── Objective block registry ────────────────────────────────────────────────
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

-- ── RegisterMission ─────────────────────────────────────────────────────────
-- Every mission file contains exactly one RegisterMission({ ... }) call. The mission
-- loader (modules/missions) runs each file in a sandbox whose RegisterMission collects
-- the definition; this global only exists so a stray call is reported, not lost.
function RegisterMission(def)
    CP.warn('missions', 'RegisterMission(%s) was called outside the mission loader and was ignored',
        type(def) == 'table' and tostring(def.id) or '?')
end
