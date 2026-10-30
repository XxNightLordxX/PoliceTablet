-- The officer options on this PC (modules/options/client.lua): 'local' options live in the resource KVP
-- crimsonpolice:options and apply at once; 'server' options come from the session and the push 'options'.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })
local cjson = require('cjson')

-- the resource KVP of this PC
local kvp = {}
_G.GetResourceKvpString = function(key) return kvp[key] end
_G.SetResourceKvp = function(key, value) kvp[key] = value end

local sent, actions = {}, {}
CP.Tablet = {
    send = function(msg) sent[#sent + 1] = msg end,
    registerClientAction = function(name, fn) actions[name] = fn end,
}

local Defs = CP.OptionDefs
Defs.add('test_sound', { kind = 'bool', default = true, store = 'local' })
Defs.add('test_size', { kind = 'enum', values = { 'small', 'large' }, default = 'small', store = 'local' })
Defs.add('test_volume', { kind = 'number', default = 50, min = 0, max = 100, integer = true, store = 'local' })
Defs.add('test_board', { kind = 'enum', values = { 'list', 'cards' }, default = 'list' })

local changed = {}
CP.Hooks.on('options:changed', function(key) changed[#changed + 1] = key end)

H.load('modules/access/client.lua')
H.load('modules/options/client.lua')
local O = CP.Options

local function Session(options, officerOptions)
    return {
        ui = 'officer',
        roles = { officer = true },
        officer = { citizenid = 'CID1', name = 'A B', department = 'lspd', departmentShort = 'LSPD', rank = 'R' },
        prefs = { appearance = 'dark' },
        options = options,
        config = { officerOptions = officerOptions },
    }
end

local function LastLocal()
    for i = #sent, 1, -1 do
        if sent[i].type == 'localOptions' then return sent[i].options end
    end
    return nil
end

-- missing or broken KVP: the defaults
H.eq(O.get('test_sound'), true, 'no KVP: a local bool is its default')
H.eq(O.get('test_volume'), 50, 'no KVP: a local number is its default')
kvp['crimsonpolice:options'] = '{not json'
H.eq(O.get('test_size'), 'small', 'a broken KVP: the default')
_G.GetResourceKvpString = function() error('native failed') end
H.eq(O.get('test_size'), 'small', 'a failing native: the default')
_G.GetResourceKvpString = function(key) return kvp[key] end
kvp['crimsonpolice:options'] = cjson.encode({ test_size = 'huge' })
H.eq(O.get('test_size'), 'small', 'a KVP value no longer offered: the default')

-- get falls back to the default when the session has no options
H.eq(O.get('test_board'), 'list', 'no session: a server option is its default')
CP.Access.setSession(Session(nil, nil))
H.eq(O.get('test_board'), 'list', 'a session without options: the default')
H.eq(O.get('nope'), nil, 'an unknown key: nil')

-- the session keeps prefs and options
local rules = {
    enabled = true,
    allow = { test_sound = true, test_size = true, test_volume = true, test_board = true },
    defaults = { test_sound = true, test_size = 'small', test_volume = 50, test_board = 'list' },
    bounds = { test_volume = { min = 10, max = 80 } },
}
changed = {}
CP.Access.setSession(Session({ test_board = 'cards' }, rules))
H.eq(CP.Access.current().prefs.appearance, 'dark', 'the session keeps the prefs (the officer\'s look)')
H.eq(O.get('test_board'), 'cards', 'the session keeps the server options')
H.eq(changed[#changed], 'test_board', 'options:changed fires for the server option the session changed')
H.eq(LastLocal() and LastLocal().test_volume, 50, 'the NUI got localOptions')

-- the push 'options' refreshes the server values
changed = {}
H.fire('crimson-police:client:push', nil, 'options', { values = { test_board = 'list' } })
H.eq(O.get('test_board'), 'list', 'the push options refreshes the server values')
H.eq(changed[1], 'test_board', '...and fires options:changed')

-- setLocal writes one JSON key; an out-of-bounds number is clamped to the session bounds
kvp['crimsonpolice:options'] = nil
sent, changed = {}, {}
local ok, v = O.setLocal('test_volume', 95)
H.ok(ok and v == 80, 'an out-of-bounds number is clamped to the session bounds (95 -> 80)')
local stored = cjson.decode(kvp['crimsonpolice:options'])
local n = 0
for _ in pairs(stored) do n = n + 1 end
H.eq(n, 1, 'setLocal writes one JSON key')
H.eq(stored.test_volume, 80, '...the clean value')
H.eq(O.get('test_volume'), 80, 'get reads it back')
H.eq(changed[1], 'test_volume', 'options:changed (test_volume)')
H.eq(LastLocal() and LastLocal().test_volume, 80, 'the NUI got the new localOptions')
kvp['crimsonpolice:options'] = cjson.encode({ test_volume = 5 })
H.eq(O.get('test_volume'), 10, 'a KVP number under the bounds reads clamped')

-- refused
H.eq(select(2, O.setLocal('test_board', 'cards')), 'err.invalid_payload', 'a server option is not set on this PC')
H.eq(select(2, O.setLocal('nope', true)), 'err.invalid_payload', 'an unknown key is refused')
H.eq(select(2, O.setLocal('test_size', 'huge')), 'err.option_value', 'a value not offered is refused')
H.eq(select(2, O.setLocal('test_sound', 'yes')), 'err.option_value', 'a wrong type is refused')

-- allow = false ignores a KVP value
kvp['crimsonpolice:options'] = cjson.encode({ test_sound = false })
H.eq(O.get('test_sound'), false, 'allowed: the KVP value')
local locked = CP.U.deepcopy(rules)
locked.allow.test_sound = false
CP.Access.setSession(Session({}, locked))
H.eq(O.get('test_sound'), true, 'allow = false ignores the KVP value')
H.eq(select(2, O.setLocal('test_sound', false)), 'err.option_locked', 'allow = false refuses setLocal')
H.eq(cjson.decode(kvp['crimsonpolice:options']).test_sound, false, '...and keeps the KVP value for later')
CP.Access.setSession(Session({}, rules))

-- the client actions
H.step(0)
H.ok(actions.getLocalOptions ~= nil and actions.setLocalOption ~= nil, 'getLocalOptions and setLocalOption registered')
local okA, data = actions.setLocalOption({ key = 'test_size', value = 'large' })
H.ok(okA and data.value == 'large' and data.options.test_size == 'large', 'setLocalOption answers the new values')
local okB, list = actions.getLocalOptions()
H.ok(okB and list.options.test_size == 'large' and list.options.test_board == nil, 'getLocalOptions: local keys only')
H.eq(select(2, actions.setLocalOption('x')), 'err.invalid_payload', 'setLocalOption needs { key, value }')

-- the client file uses no os or io
local f = assert(io.open(H.root .. 'modules/options/client.lua', 'r'))
local src = f:read('a')
f:close()
H.ok(src:find('%f[%w]os%.') == nil and src:find('%f[%w]io%.') == nil, 'modules/options/client.lua uses no os or io')

for _, key in ipairs({ 'test_sound', 'test_size', 'test_volume', 'test_board' }) do Defs.remove(key) end
return H
