-- One way to do each thing (BK1): the switches that only chose between an old and a new layout of the same screens

-- One way to do each thing (BK1): the switches that only chose between an old and a new layout of the same screens
-- are gone, the better layout is the only one, and every real choice stays a setting. Each removed key is in the
-- owner guide's "Baked in" table with the place its capability now lives; each kept key is still a setting. A row
-- saved in game under a removed key is skipped quietly at start (no console line, no Problems line), and an imported
-- file names it as unknown. The session carries none of the removed switches. Plain Lua, one storage case (the start
-- reads the saved rows).

local H = dofile('tests/harness.lua')

-- every switch that chose between an old and a new way of the same thing, and where its capability lives now
local BAKED = {
    'AdminUi.groupSidebar',
    'AdminUi.groupByPlay',
    'AdminUi.plainLayout',
    'AdminUi.landing',
    'AdminUi.settingsView',
    'AdminUi.homeForms',
    'AdminUi.markersScreen',
    'AdminUi.needsAttention',
    'AdminUi.oneRequest',
    'AdminUi.windowRows',
    'AdminUi.foldAdvanced',
    'Tablet.supervisorByTask',
    'Tablet.supervisorRemember',
    'Tablet.supervisorReviewLive',
    'Builder.quickWizard',
    'Builder.foldAdvanced',
}
-- the keys of the same blocks that are real choices or tuning numbers: they stay settings
local KEPT = {
    'AdminUi.reasonChips',
    'AdminUi.homeShortcuts',
    'AdminUi.homeShortcutsByUse',
    'AdminUi.presets',
    'AdminUi.pageSize',
    'Tablet.sidebarOrder',
    'Tablet.activeFirst',
    'Tablet.compactSidebar',
    'Tablet.supervisorCompact',
    'Tablet.supervisorLanding',
    'Performance.loopScale',
    'Performance.pushGapMs',
    'Performance.latentAboveBytes',
    'Performance.markerRange',
}

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

local function Boot()
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    CP.Access = {
        isAdmin = function(src) return src == 0 end,
        getOfficer = function() return nil end,
    }
    CP.Qbx = {
        getInfo = function(src) return { citizenid = ('BAK%05d'):format(src) } end,
    }
    CP.Tablet = { push = function() end }
    CP.Runs = {
        all = function() return {} end,
    }
    CP.Missions = {
        reload = function() end,
        get = function() return nil end,
    }
    H.load('modules/access/permissions.lua')
    H.load('modules/admin/admin.lua')
    H.load('modules/admin/confighealth.lua')
    H.load('modules/admin/settings.lua')
    H.step(0)
    return CP.Settings
end

local function At(path)
    local t = Config
    for seg in path:gmatch('[^%.]+') do
        if type(t) ~= 'table' then return nil end
        t = t[seg]
    end
    return t
end

-- ============================================================================
--                   CONFIG.LUA AND THE SETTINGS (PLAIN LUA)
-- ============================================================================

local S = Boot()
H.ok(S.isLoaded(), 'the settings load')
for _, path in ipairs(BAKED) do
    H.eq(At(path), nil, 'config.lua no longer has ' .. path)
    H.eq(S.entry(path), nil, path .. ' is no setting')
end
for _, path in ipairs(KEPT) do
    H.ok(At(path) ~= nil, 'config.lua keeps ' .. path)
    H.ok(S.entry(path) ~= nil, path .. ' stays editable in Settings')
end

-- the owner guide's table names every removed key with the place its capability lives now
local f = io.open('docs/OWNER_GUIDE.md', 'r')
local guide = f and f:read('a') or ''
if f then f:close() end
local table_ = guide:match('\n#+ [%d%.]* *Baked in[^\n]*\n(.-)\n##') or ''
H.ok(#table_ > 0, 'the owner guide has its Baked in part')
for _, path in ipairs(BAKED) do
    H.ok(table_:find('`Config.' .. path .. '`', 1, true) ~= nil, 'the Baked in table names Config.' .. path)
end

-- a saved row of a removed key is dropped; every other row is kept
local rows = S._dropUnknown({
    { setting_key = 'AdminUi.plainLayout' },
    { setting_key = 'Builder.quickWizard' },
    { setting_key = 'AdminUi.pageSize' },
})
H.eq(#rows, 1, 'the rows of removed keys are dropped')
H.eq(rows[1].setting_key, 'AdminUi.pageSize', 'every other row is kept')

-- an imported file: a removed key is unknown and changes nothing
local view = S.previewImport(json.encode({ settings = { { path = 'AdminUi.landing', value = 'home' } } }))
H.ok(view ~= nil, 'the file is read')
H.eq(#view.unknown, 1, 'a removed key is listed as unknown')
H.eq(#view.changes + #view.invalid, 0, 'and changes nothing')

-- the old screen keys and the name mappings are gone
local adminMoney = io.open('Crimson-Police/web/src/layouts/adminMoney.ts', 'r')
local src = adminMoney and adminMoney:read('a') or ''
if adminMoney then adminMoney:close() end
H.ok(#src > 0 and not src:find('resolveAdminKey', 1, true), 'no old Admin screen key redirects')
H.eq(io.open('Crimson-Police/shared/markers.lua', 'r'), nil, 'no Map markers old-name mapping')

-- ============================================================================
--                 SAVED IN GAME UNDER A REMOVED KEY (RESTART)
-- ============================================================================

H.restart()
H.boot({ side = 'server' })
H.sql('DELETE FROM cp_settings')
H.sql([[INSERT INTO cp_settings (setting_key, value_json, updated_by) VALUES
    ('AdminUi.plainLayout', '{"v": true}', 'BAK00001')]])
H.restart()
lines = {}
S = Boot()
H.ok(S.isLoaded(), 'the settings load with a removed key saved')
H.eq(Count('AdminUi.plainLayout'), 0, 'skipped quietly: no console line')
local bad = 0
for _, l in ipairs(CP.ConfigHealth.run()) do
    if (l.text or ''):find('AdminUi.plainLayout', 1, true) then bad = bad + 1 end
end
H.eq(bad, 0, 'skipped quietly: no Problems line')
H.sql('DELETE FROM cp_settings')

return H
