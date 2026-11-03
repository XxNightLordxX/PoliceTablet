-- My options -> My keys (modules/tablet/client.lua): the client action getKeyLabels names the key bound to each
-- Crimson-Police key mapping, or says it is not set.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local bound = {}   -- { [command hash | 0x80000000] = 't_F5' | 'b_1001' }
local asked = {}
_G.GetControlInstructionalButton = function(group, hash, flag)
    asked[#asked + 1] = { group = group, hash = hash, flag = flag }
    return bound[hash]
end
local function Hash(cmd) return (joaat(cmd) & 0xFFFFFFFF) | 0x80000000 end

local nuiCb = {}
_G.RegisterKeyMapping = _G.RegisterKeyMapping or function() end
_G.RegisterCommand = _G.RegisterCommand or function() end
_G.PlayerId = _G.PlayerId or function() return 0 end
_G.GetPlayerServerId = _G.GetPlayerServerId or function() return 1 end
_G.AddStateBagChangeHandler = _G.AddStateBagChangeHandler or function() end
_G.RegisterNUICallback = function(name, fn) nuiCb[name] = fn end

H.load('modules/tablet/client.lua')
local T = CP.Tablet

-- The NUI's fetch to the 'client' callback, as shared/nui.ts clientAction sends it.
local function Client(name, payload)
    local reply
    H.ok(nuiCb.client ~= nil, 'the NUI callback client exists')
    if nuiCb.client then nuiCb.client({ name = name, payload = payload }, function(r) reply = r end) end
    H.advance(100)
    return reply
end

bound[Hash('crimsonpolice_tablet')] = 't_F5'
bound[Hash('crimsonpolice_ready')] = 'b_1001'
local res = Client('getKeyLabels')
H.ok(res and res.ok, 'getKeyLabels answers')
local keys = res and res.data and res.data.keys or {}
H.eq(#keys, 4, 'four key mappings are listed')
H.eq(keys[1] and keys[1].command, 'crimsonpolice_tablet', 'the tablet key first')
H.eq(keys[1] and keys[1].state, 'set', 'a bound key is set')
H.eq(keys[1] and keys[1].label, 'F5', 'with the key\'s name, without the t_')
H.eq(keys[2] and keys[2].command, 'crimsonpolice_dispatch', 'then the dispatch key')
H.eq(keys[2] and keys[2].state, 'unset', 'a key never bound is not set')
H.eq(keys[3] and keys[3].command, 'crimsonpolice_ready', 'then the ready key')
H.eq(keys[3] and keys[3].state, 'other', 'a mouse or pad button has no text label')
H.eq(keys[4] and keys[4].command, 'crimsonpolice_contact', 'then the contact key')
H.eq(asked[1] and asked[1].group, 0, 'the native is asked for control group 0')
H.eq(asked[1] and asked[1].flag, true, 'and with the third argument true')

_G.GetControlInstructionalButton = function() error('native failed') end
H.eq(T.keyLabel('crimsonpolice_tablet').state, 'unset', 'a failing native: not set')
_G.GetControlInstructionalButton = function() return 't_' end
H.eq(T.keyLabel('crimsonpolice_tablet').state, 'unset', 'an empty label: not set')

Config.OfficerOptions.enabled = false
res = Client('getKeyLabels')
H.eq(res and res.error, 'err.option_locked', 'officer options off: getKeyLabels is refused')
Config.OfficerOptions.enabled = true

return H
