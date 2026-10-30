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

-- the mission HUD's options (shared/options_hud.lua, step O4): kept on this PC, sized inside Config's bounds
CP.Access.setSession(Session({}, nil))
kvp['crimsonpolice:options'] = nil
local hud = O.localValues()
H.ok(hud.hudSide == 'right' and hud.hudScale == 1.0 and hud.hudCompact == false and hud.reduceMotion == false,
    'the HUD options ship as today: right, 1.0, every objective, animations on')
local okS, scale = O.setLocal('hudScale', 2.0)
H.ok(okS and scale == 1.3, 'a HUD size of 2.0 is clamped to Config.OfficerOptions.bounds.hudScale (1.3)')
H.eq(O.get('hudScale'), 1.3, '...and reads back clamped')
H.ok((O.setLocal('hudSide', 'left')), 'the HUD may sit on the left')
H.eq(select(2, O.setLocal('hudSide', 'top')), 'err.option_value', 'the HUD side is right or left only')
H.ok((O.setLocal('hudCompact', true)) and O.localValues().hudCompact == true, 'the compact HUD is kept on this PC')
H.eq(LastLocal() and LastLocal().hudSide, 'left', 'the NUI got the HUD options')
local keepAllow = Config.OfficerOptions.allow.hudSide
Config.OfficerOptions.allow.hudSide = false
H.eq(O.get('hudSide'), 'right', 'allow.hudSide = false: every officer gets the default side')
Config.OfficerOptions.allow.hudSide = keepAllow
kvp['crimsonpolice:options'] = nil

-- Pop-ups (shared/options_popups.lua, step O6): the toast time, the result card time and fewer pop-ups on a run
CP.Access.setSession(Session({}, nil))
kvp['crimsonpolice:options'] = nil
local pop = O.localValues()
H.ok(pop.toastTime == 'normal' and pop.resultTime == 25 and pop.quietRun == false,
    'the pop-up options ship as today: normal toasts, a 25 s result card, every pop-up shown')
local okR, secs = O.setLocal('resultTime', 200)
H.ok(okR and secs == 60, 'a result card time of 200 s is clamped to Config.OfficerOptions.bounds.resultTime (60)')
H.eq(select(2, O.setLocal('toastTime', 'forever')), 'err.option_value', 'the toast time is short, normal or long')
H.ok((O.setLocal('resultTime', 10)) and O.get('resultTime') == 10, 'a 10 s result card is kept on this PC')
H.eq(LastLocal() and LastLocal().resultTime, 10, 'the NUI got the result card time')

-- the real modules/tablet/client.lua (its CP.Tablet), kept for the tablet key below
local tabletModule = nil

-- the real CP.Tablet.notify (modules/tablet/client.lua) with the options above
do
    local nui = {}
    _G.SendNUIMessage = function(m) nui[#nui + 1] = m end
    for _, name in ipairs({
        'RegisterNUICallback',
        'RegisterKeyMapping',
        'SetNuiFocus',
        'PlayerId',
        'GetPlayerServerId',
        'AddStateBagChangeHandler',
    }) do
        _G[name] = _G[name] or function() return 1 end
    end
    local stub = CP.Tablet
    CP.Tablet = nil
    H.load('modules/tablet/client.lua')
    local T = CP.Tablet
    tabletModule = T
    local function Last()
        for i = #nui, 1, -1 do
            if nui[i].type == 'notify' then return nui[i].notification end
        end
        return nil
    end
    local onRun = nil
    CP.Runs = {
        current = function() return onRun end,
    }
    T.notify('info', 'plain')
    H.eq(Last().duration, 5000, 'toastTime normal: an info toast stays 5 s, as before')
    O.setLocal('toastTime', 'long')
    T.notify('warning', 'w')
    H.eq(Last().duration, 12000, 'toastTime long: a warning stays 12 s')
    T.notify('info', 'ready', { duration = 20000 })
    H.eq(Last().duration, 20000, 'an explicit duration (the ready check) is kept')
    O.setLocal('toastTime', 'short')
    T.notify('success', 's')
    H.eq(Last().duration, 3000, 'toastTime short: a success toast stays 3 s')

    O.setLocal('quietRun', true)
    onRun = { runId = 'r1' }
    T.notify('info', 'invite', { channel = 'social' })
    H.eq(Last().bellOnly, true, 'quietRun on a run: a social toast goes only to the bell')
    T.notify('warning', 'off route')
    H.eq(Last().bellOnly, nil, '...a route warning (default channel) still pops up')
    T.notify('warning', 'social warning', { channel = 'social' })
    H.eq(Last().bellOnly, nil, '...and so does a social warning')
    H.fire('crimson-police:client:notify', nil, { kind = 'success', key = 'some.key', channel = 'social' })
    H.eq(Last().bellOnly, true, 'a server toast on the social channel is kept in the bell too')
    onRun = nil
    T.notify('info', 'invite', { channel = 'social' })
    H.eq(Last().bellOnly, nil, 'quietRun off a run: the social toast pops up')
    onRun = { runId = 'r1' }
    O.setLocal('quietRun', false)
    T.notify('info', 'invite', { channel = 'social' })
    H.eq(Last().bellOnly, nil, 'quietRun off: every toast pops up during a run, as before')
    CP.Runs = nil
    CP.Tablet = stub
end
kvp['crimsonpolice:options'] = nil

-- Sounds (shared/options_sounds.lua, step O7): the call tone, the unit tone and the objective cues (this PC)
do
    CP.Access.setSession(Session({}, nil))
    kvp['crimsonpolice:options'] = nil
    local snd = O.localValues()
    H.ok(snd.soundCalls == true and snd.soundUnit == true and snd.soundCues == true,
        'the sound options ship as today: every tone plays')
    local played, toasts = {}, {}
    _G.PlaySoundFrontend = function(_, name, set) played[#played + 1] = name .. '/' .. set end
    CP.Tablet.notify = function(kind, text) toasts[#toasts + 1] = text end
    for _, name in ipairs({ 'RegisterKeyMapping', 'RegisterCommand', 'AddStateBagChangeHandler' }) do
        _G[name] = _G[name] or function() end
    end
    H.load('modules/missioncalls/client.lua')
    H.load('modules/units/client.lua')
    local function Call()
        H.clockMs = H.clockMs + 10000
        H.fire('crimson-police:client:missionCall', nil, { code = 'MC-1', typeLabel = 'Patrol', priority = 2 })
    end
    Call()
    H.ok(#played == 1 and #toasts == 1, 'soundCalls on: a new call pops up with its tone')
    H.ok((O.setLocal('soundCalls', false)) and O.get('soundCalls') == false, 'the call tone is turned off on this PC')
    Call()
    H.ok(#played == 1 and #toasts == 2, 'soundCalls off: the next call pops up silently')
    H.clockMs = H.clockMs + 10000
    H.fire('crimson-police:client:push', nil, 'unit', { invited = true })
    H.eq(#played, 2, 'the call tone off leaves the unit invite tone on')
    O.setLocal('soundUnit', false)
    H.clockMs = H.clockMs + 10000
    H.fire('crimson-police:client:push', nil, 'unit', { invited = true })
    H.fire('crimson-police:client:readyCheck', nil, { typeLabel = 'Patrol', expiresIn = 20, leaderName = 'A B' })
    H.ok(#played == 2 and #toasts == 3, 'soundUnit off: the invite and the ready check are silent, the toast shows')
    H.eq(O.sound('cues', 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET'), true, 'soundCues on: an objective cue plays')
    O.setLocal('soundCues', false)
    H.eq(O.sound('cues', 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET'), false, 'soundCues off: the cue is silent')
    H.eq(#played, 3, 'only the one cue played')
    local keepAllow = Config.OfficerOptions.allow.soundCalls
    Config.OfficerOptions.allow.soundCalls = false
    Call()
    H.eq(#played, 4, 'allow.soundCalls = false: the stored off is ignored and the call tone plays')
    Config.OfficerOptions.allow.soundCalls = keepAllow
    for _, b in ipairs({ 'checkpoint_route', 'skill_check', 'interact_points' }) do
        local fb = assert(io.open(H.root .. 'blocks/' .. b .. '/client.lua', 'r'))
        local code = fb:read('a')
        fb:close()
        local _, direct = code:gsub('PlaySoundFrontend%(', '')
        H.ok(direct == 1 and code:find('CP.Options.sound(\'cues\'', 1, true) ~= nil,
            b .. ': its cues go through CP.Options.sound (soundCues)')
    end
    CP.Tablet.notify = nil
    kvp['crimsonpolice:options'] = nil
end

-- Dispatch (shared/options_dispatch.lua, step O9): with dispatchKeyAfterCall the tablet key opens Dispatch for 20 s
-- after a mission call pop-up; nothing is claimed. The option is saved with the character (the session's values).
do
    local T = tabletModule
    local realOpen = T.open
    local opened = {}
    T.open = function(ui, opts)
        opened[#opened + 1] = { ui = ui, screen = opts and opts.screen, via = opts and opts.via }
        return true
    end
    local requests = 0
    local realRequest = CP.Net.request
    CP.Net.request = function(...)
        requests = requests + 1
        return realRequest(...)
    end
    local function Key()
        H.clockMs = H.clockMs + 1000
        H.commands.crimsonpolice_tablet.fn()
        return opened[#opened]
    end
    local function Call()
        H.clockMs = H.clockMs + 10000
        H.fire('crimson-police:client:missionCall', nil, { code = 'MC-9', typeLabel = 'Patrol', priority = 2 })
    end
    CP.Access.setSession(Session({}, nil))
    H.eq(O.get('dispatchKeyAfterCall'), false, 'dispatchKeyAfterCall ships off')
    Call()
    H.eq(Key().screen, nil, 'off: the tablet key opens the tablet as usual, just after a call (as before)')
    CP.Access.setSession(Session({ dispatchKeyAfterCall = true }, nil))
    H.clockMs = H.clockMs + 25000
    H.eq(Key().screen, nil, 'on, but the last call popped up more than 20 s ago: as usual')
    Call()
    H.clockMs = H.clockMs + 5000
    local k = Key()
    H.ok(k.screen == 'dispatch' and k.ui == 'officer' and k.via == 'keybind',
        'on: the tablet key within 20 s of a call opens the Officer UI on Dispatch')
    H.eq(requests, 0, '...and claims nothing')
    H.clockMs = H.clockMs + 14000
    H.eq(Key().screen, nil, 'on: 20 s after the call the key opens as usual again')
    local keepAllow = Config.OfficerOptions.allow.dispatchKeyAfterCall
    Config.OfficerOptions.allow.dispatchKeyAfterCall = false
    Call()
    H.eq(Key().screen, nil, 'allow.dispatchKeyAfterCall = false: the saved choice is ignored')
    Config.OfficerOptions.allow.dispatchKeyAfterCall = keepAllow
    CP.Net.request = realRequest
    T.open = realOpen
    CP.Access.setSession(Session({}, nil))
end

-- the client file uses no os or io
local f = assert(io.open(H.root .. 'modules/options/client.lua', 'r'))
local src = f:read('a')
f:close()
H.ok(src:find('%f[%w]os%.') == nil and src:find('%f[%w]io%.') == nil, 'modules/options/client.lua uses no os or io')

for _, key in ipairs({ 'test_sound', 'test_size', 'test_volume', 'test_board' }) do Defs.remove(key) end
return H
