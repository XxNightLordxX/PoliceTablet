-- tools/capability_inventory.lua · the capability inventory: every command, event, callback, NUI callback, export,
-- admin action, setting, feature and Config key Crimson-Police has, one sorted line each (dev tooling, not shipped).
--
--   lua5.4 tools/capability_inventory.lua            print the inventory
--   lua5.4 tools/capability_inventory.lua --write    rewrite tests/capability_baseline.txt with it
--
-- Run it from the repository root. tests/capability_inventory_spec.lua builds it again and fails on any line of the
-- baseline that is gone: a refactor that drops a command, an event or a setting together with its docs and its
-- sender still fails there. docs/dev/TESTING.md "Capability inventory" says when and how to refresh the baseline.
--
-- How each list is read (the names as the running resource registers them, so the names that come from Config
-- are the shipped ones):
--   server   tests/workflows_full_spec.lua's world (every server file of fxmanifest loaded as in game, the saves
--            folder, the owner's scripts running), booted with no section run: H.commands, H.handlers (every net and
--            local event a handler is registered for), H.callbacks (lib.callback.register), H.ownExports
--            (exports('Name', fn)), CP.AdminKit._actions() (each with its permission key), the Admin UI settings
--            (CP.Settings._schema().list) and the feature switches (CP.Settings._features)
--   client   every client script of fxmanifest loaded with the natives answering nil, the start-up threads run for
--            ten game minutes: commands, events, callbacks, exports and the NUI callbacks (RegisterNUICallback)
--   config   every key path of config/config.lua and config/blocks.lua as shipped (string keys; a list's items are
--            not walked, a vector is one value)
-- Each line is `<kind> <side> <name>[ <detail>]`. The child runs (--side=server, --side=client) print theirs with
-- `CAP ` in front; the console lines of the boot around them are dropped.

local function Root()
    local src = debug.getinfo(1, 'S').source:match('^@(.*)$') or ''
    local dir = src:match('^(.*)/tools/capability_inventory%.lua$')
    return dir or '.'
end
local ROOT = Root()
local BASELINE = ROOT .. '/tests/capability_baseline.txt'

local side, write = nil, false
local asLib = rawget(_G, 'CP_INVENTORY_LIB') == true
for _, a in ipairs(not asLib and arg or {}) do
    if a == '--write' then
        write = true
    elseif a:match('^%-%-side=') then
        side = a:match('^%-%-side=(.*)$')
    else
        io.stderr:write(('unknown argument %s (lua5.4 tools/capability_inventory.lua [--write])\n'):format(a))
        os.exit(2)
    end
end

local function Sorted(set)
    local out = {}
    for k in pairs(set) do
        out[#out + 1] = k
    end
    table.sort(out)
    return out
end

-- ============================================================================
--                              THE SERVER (a child run)
-- ============================================================================

if side == 'server' then
    _G.CP_WF_WORLD = 'inventory'
    local W = dofile('tests/workflows_full_spec.lua')
    _G.CP_WF_WORLD = nil
    local H = W.H
    W.Secs(20) -- the start-up threads: the saved settings, then the commands named from them
    local lines = {}
    local function Add(kind, name, detail)
        lines[#lines + 1] = ('%s server %s%s'):format(kind, name, detail and (' ' .. detail) or '')
    end
    for _, n in ipairs(Sorted(H.commands)) do
        Add('command', n)
    end
    for _, n in ipairs(Sorted(H.handlers)) do
        Add('event', n)
    end
    for _, n in ipairs(Sorted(H.callbacks)) do
        Add('callback', n)
    end
    for _, n in ipairs(Sorted(H.ownExports)) do
        Add('export', n)
    end
    for name, a in pairs(CP.AdminKit._actions()) do
        Add('action', name, (a.supervisor and 'supervisor ' or 'admin ') .. tostring(a.permKey))
    end
    for _, e in ipairs(CP.Settings._schema().list) do
        Add('setting', e.path)
    end
    for _, f in ipairs(CP.Settings._features or {}) do
        Add('feature', f.path)
    end
    table.sort(lines)
    for _, l in ipairs(lines) do
        io.write('CAP ', l, '\n')
    end
    os.exit(0, true)
end

-- ============================================================================
--                              THE CLIENT (a child run)
-- ============================================================================

if side == 'client' then
    package.path = package.path .. ';tests/?.lua'
    local H = dofile('tests/harness.lua')
    H.boot({ side = 'client', realLocale = true })
    -- the natives no start-up path needs answer nil, as tests/loops_spec.lua loads the client
    local function Nop()
        return nil
    end
    H.onUndefinedGlobal(function(k)
        if type(k) == 'string' and k:match('^[A-Z]') then
            return Nop
        end
        return nil
    end)
    _G.PlayerId = function()
        return 0
    end
    _G.GetPlayerServerId = function()
        return 1
    end
    _G.LocalPlayer = { state = {} }
    local nui = {}
    _G.RegisterNUICallback = function(name)
        nui[tostring(name)] = true
    end
    local failed = {}
    for _, rel in ipairs(H.manifestScripts('client_scripts')) do
        local ok, err = pcall(H.load, rel)
        if not ok then
            failed[#failed + 1] = rel .. ': ' .. tostring(err)
        end
    end
    if #failed > 0 then
        print('a client script did not load: ' .. table.concat(failed, '; '))
        os.exit(1)
    end
    H.advance(600000, 1000)
    local lines = {}
    local function Add(kind, name)
        lines[#lines + 1] = ('%s client %s'):format(kind, name)
    end
    for _, n in ipairs(Sorted(H.commands)) do
        Add('command', n)
    end
    for _, n in ipairs(Sorted(H.handlers)) do
        Add('event', n)
    end
    for _, n in ipairs(Sorted(H.callbacks)) do
        Add('callback', n)
    end
    for _, n in ipairs(Sorted(H.ownExports)) do
        Add('export', n)
    end
    for _, n in ipairs(Sorted(nui)) do
        Add('nui', n)
    end
    table.sort(lines)
    for _, l in ipairs(lines) do
        io.write('CAP ', l, '\n')
    end
    os.exit(0, true)
end

-- ============================================================================
--                         THE CONFIG KEYS, AND THE WHOLE LIST
-- ============================================================================

local function ConfigLines()
    local env = { Config = {} }
    local function V(x, y, z, w)
        return { x = x, y = y, z = z, w = w, [V] = true }
    end
    env.vector2, env.vector3, env.vector4, env.vec2, env.vec3, env.vec4 = V, V, V, V, V, V
    setmetatable(env, { __index = _G })
    for _, rel in ipairs({ 'Crimson-Police/config/config.lua', 'Crimson-Police/config/blocks.lua' }) do
        local chunk, err = loadfile(ROOT .. '/' .. rel, 't', env)
        if not chunk then
            error(rel .. ': ' .. tostring(err), 0)
        end
        chunk()
    end
    local out = {}
    local function Walk(t, path, seen)
        if seen[t] then
            return
        end
        seen[t] = true
        for k, v in pairs(t) do
            if type(k) == 'string' then
                local p = path .. '.' .. k
                out[#out + 1] = 'config shared ' .. p
                if type(v) == 'table' and not v[V] then
                    Walk(v, p, seen)
                end
            end
        end
    end
    Walk(env.Config, 'Config', {})
    return out
end

local function Child(which)
    local cmd = ('cd \'%s\' && lua5.4 tools/capability_inventory.lua --side=%s 2>&1'):format(ROOT, which)
    local p = assert(io.popen(cmd))
    local out, other = {}, {}
    for line in p:lines() do
        local l = line:match('^CAP (.*)$')
        if l then
            out[#out + 1] = l
        else
            other[#other + 1] = line
        end
    end
    local ok = p:close()
    if not ok or #out == 0 then
        error(('the %s inventory run failed:\n%s'):format(which, table.concat(other, '\n'):sub(-3000)), 0)
    end
    return out
end

local function Inventory()
    local all = {}
    for _, l in ipairs(Child('server')) do
        all[#all + 1] = l
    end
    for _, l in ipairs(Child('client')) do
        all[#all + 1] = l
    end
    for _, l in ipairs(ConfigLines()) do
        all[#all + 1] = l
    end
    table.sort(all)
    return all
end

-- loaded by tests/capability_inventory_spec.lua (dofile): the functions, no output
if asLib then
    return { inventory = Inventory, baseline = BASELINE }
end

local ok, all = pcall(Inventory)
if not ok then
    io.stderr:write(tostring(all), '\n')
    os.exit(1)
end
if write then
    local f = assert(io.open(BASELINE, 'w'))
    f:write(
        '# tests/capability_baseline.txt: what Crimson-Police can do, from lua5.4 tools/capability_inventory.lua --write.\n',
        '# tests/capability_inventory_spec.lua fails when a line here is gone. Remove a line only when the capability\n',
        '# is removed on purpose (say so in the commit); docs/dev/TESTING.md "Capability inventory".\n'
    )
    for _, l in ipairs(all) do
        f:write(l, '\n')
    end
    f:close()
    print(('%s: %d lines'):format(BASELINE:gsub('^%./', ''), #all))
else
    for _, l in ipairs(all) do
        print(l)
    end
end
