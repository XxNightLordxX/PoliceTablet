-- Map markers' old names (shared/markers.lua, CP.MarkerAliases; MG1 folded Config.MissionBlips into Config.Markers):

-- Map markers' old names (shared/markers.lua, CP.MarkerAliases; MG1 folded Config.MissionBlips into Config.Markers):
-- an older config.lua's Config.MissionBlips, Config.Markers.serviceVehicles and Config.AdminUi.missionBlipsScreen are
-- read as the new names, a new name already set wins, and a setting saved in game under an old name still applies
-- after the restart (moved once to its new name), with one console line naming the new names.

local H = dofile('tests/harness.lua')

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if not line:find('crimson%-police') then realPrint(line) end
end
local function Count(needle)
    local n = 0
    for _, l in ipairs(lines) do if l:find(needle, 1, true) then n = n + 1 end end
    return n
end

-- ============================================================================
--                       AN OLDER CONFIG.LUA (PLAIN LUA)
-- ============================================================================

H.boot({ side = 'server' })
local A = CP.MarkerAliases
H.eq(#A.used, 0, 'the shipped config.lua uses no old name')
H.eq(Config.MissionBlips, nil, 'and has no Config.MissionBlips')

-- a config.lua from before MG1: no parts in Config.Markers, the old block and switches
local old = {
    Markers = { enabled = true, serviceVehicles = false, kinds = { towTruck = { sprite = 67, colour = 1 } } },
    MissionBlips = {
        enabled = true,
        refreshEvery = 5,
        parts = {
            prisonerVan = { on = true, sprite = 285 },
            partner = { on = true, sprite = 1, colour = 3 },
        },
        rules = { partner = { roles = 'leader' } },
    },
    AdminUi = { missionBlipsScreen = false },
}
H.ok(A.mapConfig(old) >= 5, 'every old name is counted')
H.eq(old.MissionBlips, nil, 'Config.MissionBlips is taken out')
H.eq(old.Markers.extraParts, true, 'MissionBlips.enabled -> Markers.extraParts')
H.eq(old.Markers.refreshEvery, 5, 'MissionBlips.refreshEvery -> Markers.refreshEvery')
H.eq(old.Markers.rules.partner.roles, 'leader', 'MissionBlips.rules -> Markers.rules')
H.eq(old.Markers.parts.partner.on, true, 'MissionBlips.parts -> Markers.parts')
H.eq(old.Markers.parts.prisonerVan.on, false,
    'serviceVehicles = false -> the prisoner van\'s on (its old on meant less)')
H.eq(old.Markers.parts.towTruck.on, false, 'and the tow truck\'s')
H.ok(old.Markers.parts.towTruck.sprite == 67 and old.Markers.parts.towTruck.colour == 1,
    'the tow truck keeps the look its old kinds entry had')
H.eq(old.Markers.serviceVehicles, nil, 'serviceVehicles is taken out')
H.ok(old.AdminUi.markersScreen == false and old.AdminUi.missionBlipsScreen == nil,
    'missionBlipsScreen -> markersScreen')

-- a config.lua with both: the new names win
local both = {
    Markers = { extraParts = false, parts = { partner = { on = false } } },
    MissionBlips = { enabled = true, parts = { partner = { on = true } } },
}
A.mapConfig(both)
H.ok(both.Markers.extraParts == false and both.Markers.parts.partner.on == false, 'a new name already set wins')
H.ok(both.Markers.parts.prisonerVan.on == true and both.Markers.parts.towTruck.on == true,
    'no serviceVehicles: the vans show, as before')

-- the saved paths
H.eq(table.concat(A.paths('MissionBlips.parts.partner.colour'), ','), 'Markers.parts.partner.colour', 'a part field')
H.eq(table.concat(A.paths('Markers.serviceVehicles'), ','), 'Markers.parts.prisonerVan.on,Markers.parts.towTruck.on',
    'serviceVehicles -> both vans')
H.eq(#A.paths('MissionBlips.parts.towTruck.on'), 0, 'the vans\' old on has no new name')
H.eq(A.paths('Markers.parts.partner.on'), nil, 'a new name is no alias')

-- ============================================================================
--                  SAVED IN GAME UNDER AN OLD NAME (RESTART)
-- ============================================================================

local function Boot()
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    CP.Access = {
        isAdmin = function(src) return src == 0 end,
        getOfficer = function() return nil end,
    }
    CP.Qbx = {
        getInfo = function(src) return { citizenid = ('SET%05d'):format(src) } end,
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
    return CP.Settings
end

H.restart()
H.boot({ side = 'server' })
H.sql('DELETE FROM cp_settings')
H.sql([[INSERT INTO cp_settings (setting_key, value_json, updated_by) VALUES
    ('MissionBlips.enabled', '{"v": true}', 'SET00001'),
    ('MissionBlips.parts.partner.on', '{"v": true}', 'SET00001'),
    ('Markers.serviceVehicles', '{"v": false}', 'SET00001')]])
H.restart()
lines = {}
local S = Boot()
H.ok(S.isLoaded(), 'the settings load')
H.eq(Config.Markers.extraParts, true, 'a saved MissionBlips.enabled still applies (Markers.extraParts)')
H.eq(Config.Markers.parts.partner.on, true, 'a saved part switch still applies')
H.ok(Config.Markers.parts.prisonerVan.on == false and Config.Markers.parts.towTruck.on == false,
    'a saved serviceVehicles = false still hides both vans')
H.eq(Count('Markers.extraParts'), 1, 'one console line names the new names')
local keys = {}
for _, r in ipairs(H.sql('SELECT setting_key FROM cp_settings ORDER BY setting_key')) do
    keys[#keys + 1] = r.setting_key
end
H.eq(table.concat(keys, ','),
    'Markers.extraParts,Markers.parts.partner.on,Markers.parts.prisonerVan.on,Markers.parts.towTruck.on',
    'the saved rows were moved to their new names')

-- the next restart reads them as they are: no console line any more
H.restart()
lines = {}
S = Boot()
H.eq(Config.Markers.extraParts, true, 'still on after the next restart')
H.eq(Count('old names'), 0, 'every name is new: no console line')
H.sql('DELETE FROM cp_settings')

return H
