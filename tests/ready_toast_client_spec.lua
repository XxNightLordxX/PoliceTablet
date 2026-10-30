-- The unit ready check on a member's game (modules/units/client.lua): the toast names the twists the leader chose
-- (PLAN M8b), and stays the plain one without twists.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client', realLocale = true })

_G.RegisterKeyMapping = function() end
_G.PlaySoundFrontend = function() end
local toasts = {}
CP.Tablet = {
    notify = function(kind, text, opts) toasts[#toasts + 1] = { kind = kind, text = text, opts = opts } end,
}
H.load('modules/units/client.lua')

H.fire('crimson-police:client:readyCheck', nil, {
    typeKey = 'tactical',
    typeLabel = 'Tactical',
    expiresIn = 20,
    leaderName = 'John Doe',
    twists = { { key = 'time_crunch', label = 'Time Crunch' }, { key = 'radio_silence', label = 'Radio Silence' } },
})
H.eq(#toasts, 1, 'one toast for the check')
H.eq(toasts[1].text, CP.L(
    'unit.ready.toast_twists',
    { type = 'Tactical', leader = 'John Doe', seconds = 20, twists = 'Time Crunch, Radio Silence' }
), 'the toast names the twists the leader chose')
H.ok(toasts[1].text:find('Time Crunch, Radio Silence', 1, true) ~= nil, '...in plain words')
H.ok(CP.Units.pendingReadyCheck() ~= nil, 'the check is pending (the Ready key answers it)')

H.fire('crimson-police:client:readyCheck', nil, {
    typeKey = 'patrol',
    typeLabel = 'Patrol',
    expiresIn = 20,
    leaderName = 'John Doe',
})
H.eq(toasts[2].text, CP.L('unit.ready.toast', { type = 'Patrol', leader = 'John Doe', seconds = 20 }),
    'without twists: the plain toast')
H.fire('crimson-police:client:readyCheck', nil, nil)
H.eq(CP.Units.pendingReadyCheck(), nil, 'nil clears the check')

return H
