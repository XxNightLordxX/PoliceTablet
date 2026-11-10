-- One Department screen (MG3): the Supervisor UI's Department Report, Mission controls and Review Queue are tabs of

-- One Department screen (MG3): the Supervisor UI's Department Report, Mission controls and Review Queue are tabs of
-- one Department screen, and its Controls tab shows each control's admin limits and today's use inline, so
-- Config.Tablet.supervisorControlsCard is gone. An older config.lua that still has it lists no such setting, a
-- setting saved in game under that name is dropped quietly (Settings.RETIRED, the same code as MG2's, whose
-- storage case is in money_screen_spec.lua), an imported file's row is left out without being called unknown, and
-- the session no longer carries the switch. Plain Lua: no SQL, storage or migration changes.

local H = dofile('tests/harness.lua')

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
-- an older config.lua: the switch is still in it
Config.Tablet.supervisorControlsCard = true
CP.Access = {
    isAdmin = function(src) return src == 0 end,
    getOfficer = function() return nil end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = ('DEP%05d'):format(src) } end,
}
CP.Tablet = { push = function() end }
CP.Runs = {
    all = function() return {} end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}
H.load('modules/permissions/server.lua')
H.load('modules/admin/server.lua')
H.load('modules/confighealth/server.lua')
H.load('modules/settings/server.lua')
H.step(0)
local S = CP.Settings

H.ok(S.isLoaded(), 'the settings load')
H.eq(S.entry('Tablet.supervisorControlsCard'), nil, 'an older config.lua: no supervisorControlsCard setting')
H.ok(S.entry('Tablet.supervisorLanding') ~= nil and S.entry('Tablet.supervisorRemember') ~= nil,
    'the other Supervisor UI settings stay')

local rows = S._dropRetired({
    { setting_key = 'Tablet.supervisorControlsCard' },
    { setting_key = 'Tablet.supervisorLanding' },
})
H.eq(#rows, 1, 'a saved supervisorControlsCard row is dropped')
H.eq(rows[1].setting_key, 'Tablet.supervisorLanding', 'every other row is kept')

-- an imported file: the retired row is left out, not listed as unknown
local view = S.previewImport(json.encode({
    settings = { { path = 'Tablet.supervisorControlsCard', value = true } },
}))
H.ok(view ~= nil, 'the file is read')
H.eq(#view.unknown, 0, 'the retired row is not called unknown')
H.eq(#view.changes + #view.invalid, 0, 'and changes nothing')

return H
