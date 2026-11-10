-- One Money screen (MG2): Pay rates, Rewards, Payments and Department funds are tabs of one Admin UI screen, so

-- One Money screen (MG2): Pay rates, Rewards, Payments and Department funds are tabs of one Admin UI screen, so
-- Config.AdminUi.rewardsScreen and Config.AdminUi.moneyScreen are gone. A setting saved in game under either name is
-- ignored quietly after the restart (no warning, no Problems line, nothing applied), an older config.lua that still
-- has them lists no such setting, and an imported file's row is left out without being called unknown.

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

local function Boot(old)
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    -- an older config.lua: the two switches are still in it
    if old then Config.AdminUi.rewardsScreen, Config.AdminUi.moneyScreen = true, true end
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

-- ============================================================================
--                       THE RETIRED SWITCHES (PLAIN LUA)
-- ============================================================================

local S = Boot(true)
H.ok(S.isLoaded(), 'the settings load')
H.eq(S.entry('AdminUi.rewardsScreen'), nil, 'an older config.lua: no rewardsScreen setting')
H.eq(S.entry('AdminUi.moneyScreen'), nil, 'an older config.lua: no moneyScreen setting')
H.ok(S.entry('AdminUi.oneRequest') ~= nil, 'the other Admin UI settings stay')
local rows = S._dropRetired({
    { setting_key = 'AdminUi.moneyScreen' },
    { setting_key = 'AdminUi.rewardsScreen' },
    { setting_key = 'AdminUi.oneRequest' },
})
H.eq(#rows, 1, 'the retired rows are dropped')
H.eq(rows[1].setting_key, 'AdminUi.oneRequest', 'every other row is kept')

-- an imported file: the retired rows are left out, not listed as unknown
local view = S.previewImport(json.encode({
    settings = {
        { path = 'AdminUi.moneyScreen', value = true },
        { path = 'AdminUi.rewardsScreen', value = true },
    },
}))
H.ok(view ~= nil, 'the file is read')
H.eq(#view.unknown, 0, 'the retired rows are not called unknown')
H.eq(#view.changes + #view.invalid, 0, 'and change nothing')

-- ============================================================================
--                 SAVED IN GAME UNDER A RETIRED NAME (RESTART)
-- ============================================================================

H.restart()
H.boot({ side = 'server' })
H.sql('DELETE FROM cp_settings')
H.sql([[INSERT INTO cp_settings (setting_key, value_json, updated_by) VALUES
    ('AdminUi.moneyScreen', '{"v": true}', 'SET00001')]])
H.restart()
lines = {}
S = Boot(false)
H.ok(S.isLoaded(), 'the settings load with a retired row saved')
H.eq(Count('AdminUi.moneyScreen'), 0, 'ignored quietly: no console line')
local bad = 0
for _, l in ipairs(CP.ConfigHealth.run()) do
    if (l.text or ''):find('AdminUi.moneyScreen', 1, true) then bad = bad + 1 end
end
H.eq(bad, 0, 'ignored quietly: no Problems line')
H.sql('DELETE FROM cp_settings')

return H
