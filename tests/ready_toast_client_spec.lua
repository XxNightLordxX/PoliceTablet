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

-- a live case's ready check (V16): a red toast that names the reported crime and the suspect count
H.fire('crimson-police:client:readyCheck', nil, {
    typeKey = 'tactical',
    typeLabel = 'Tactical',
    expiresIn = 20,
    leaderName = 'John Doe',
    live = { title = 'Shots at the lab', street = 'Seaview Rd', suspects = 2 },
})
local live = toasts[#toasts]
H.eq(live.kind, 'error', 'a live case: the red toast')
H.eq(live.opts.title, CP.L('unit.ready.toast_live_title'), '...titled LIVE case')
H.ok(live.text:find('Shots at the lab, Seaview Rd', 1, true) ~= nil, '...naming the reported crime')
H.ok(live.text:find('Suspects: 2', 1, true) ~= nil, '...and the suspect count')
H.ok(CP.Units.pendingReadyCheck() ~= nil, 'the Ready key answers it like any check')

return H
