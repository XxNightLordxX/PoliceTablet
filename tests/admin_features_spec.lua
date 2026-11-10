-- Admin UI split by play, (the owner: "ensure the admin panel separates npc stuff and player player stuff

-- Admin UI split by play (the owner: "ensure the admin panel separates npc stuff and player player stuff
-- and cop cop stuff and every feature is able to be turned on and off etc edited"): the Settings sections fold into
-- NPC missions, Player vs police and Police teamwork, and Settings -> Features lists every feature switch with its
-- section and the setting it writes.

local H = dofile('tests/harness.lua')

local function ReadRepo(rel)
    local f = io.open(H.root .. '../' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function Has(s, needle, msg) H.ok(type(s) == 'string' and s:find(needle, 1, true) ~= nil, msg) end

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
CP.Access = {
    isAdmin = function(src) return src == 0 or src == 1 end,
    isSupervisor = function() return false end,
    getOfficer = function() return nil, 'err.not_police' end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = ('APF%05d'):format(src), name = 'Admin ' .. src } end,
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

-- ============================================================================
--                   NO SWITCH (BK1: grouped by play, always)
-- ============================================================================

H.eq(S.entry('AdminUi.groupByPlay'), nil, 'Config.AdminUi.groupByPlay is no setting any more')

-- ============================================================================
--                THE THREE SECTIONS (Settings, Simple and All)
-- ============================================================================

do
    local sc = S._schema()
    local seen = {}
    for _, g in ipairs(S._playGroups) do
        H.ok(CP.Locale.has('settings.group.' .. g.key) and CP.Locale.has('settings.group_help.' .. g.key),
            g.key .. ': a title and a help text')
        for _, key in ipairs(g.sections) do
            H.eq(seen[key], nil, key .. ': in one play group only')
            seen[key] = g.key
        end
    end
    for _, sec in ipairs(sc.sections) do H.ok(seen[sec.key] ~= nil, sec.key .. ': a play group names it') end
    H.eq(seen.spawning, 'play_npc', 'spawning is NPC missions')
    H.eq(seen.dispatch, 'play_npc', 'mission calls are NPC missions')
    H.eq(seen.real_players, 'play_pvp', 'Real players (both modes and their shared rules) is Player vs police')
    H.eq(seen.recognition, 'play_team', 'recognition (with field training) is Police teamwork')
    H.eq(seen.mission_controls, 'play_team', 'supervisor mission controls are Police teamwork')
    H.eq(seen.cross_department_missions, 'play_team', 'cross-department operations are Police teamwork')
    H.eq(seen.storage, 'play_system', 'storage stays under the server')
    H.eq(seen.cash, 'play_economy', 'cash stays with the money')

    local view = S.all()
    H.eq(view.groups[1].key, 'play_npc', 'NPC missions first')
    H.eq(view.groups[2].key, 'play_pvp', 'then Player vs police')
    H.eq(view.groups[3].key, 'play_team', 'then Police teamwork')
    H.eq(view.groups[1].title, 'NPC missions', 'group titles come from the locale')
    local n = 0
    for _, g in ipairs(view.groups) do n = n + #g.sections end
    H.eq(n, #view.sections, 'every section under one group')
    for _, sec in ipairs(view.sections) do
        H.eq(sec.group, seen[sec.key], sec.key .. ': the section carries its play group')
    end
end

-- ============================================================================
--                 THE FEATURES OVERVIEW (Settings -> Features)
-- ============================================================================

do
    local plays = { npc = 0, pvp = 0, team = 0, economy = 0, system = 0 }
    local keys = {}
    for _, f in ipairs(S._features) do
        H.eq(keys[f.key], nil, f.key .. ': one feature per key')
        keys[f.key] = true
        H.ok(plays[f.play] ~= nil, f.key .. ': a known section')
        plays[f.play] = (plays[f.play] or 0) + 1
        local e = S.entry(f.path)
        H.ok(e ~= nil, f.key .. ': ' .. f.path .. ' is a Settings template')
        H.eq(e and e.kind, 'boolean', f.key .. ': its setting is a switch')
        H.eq(type(CP.U.getPath(Config, f.path)), 'boolean', f.key .. ': config.lua has ' .. f.path)
        H.ok(e and not e.restart, f.key .. ': read when used, so a change works at once')
        H.ok(e and not e.locked, f.key .. ': not locked to config.lua')
        H.ok(CP.Locale.has('settings.feature.' .. f.key), f.key .. ': a name in locales/parts/settings.json')
    end
    for play, n in pairs(plays) do
        H.ok(n > 0, play .. ': at least one feature')
        H.ok(CP.Locale.has('settings.features.play.' .. play), play .. ': a section title')
    end
    -- the main switches of each section are on the list
    for _, path in ipairs({
        'Spawning.enabled',
        'NpcCombat.enabled',
        'MissionCalls.enabled',
        'RealPlayers.liveCrime.enabled',
        'RealPlayers.volunteer.enabled',
        'RealPlayers.surrender.enabled',
        'CrossDept.enabled',
        'Recognition.fieldTraining.enabled',
        'Recognition.commendations.enabled',
        'Permissions.supervisor.missionControls',
        'Rewards.enabled',
    }) do
        local hit = false
        for _, f in ipairs(S._features) do if f.path == path then hit = true end end
        H.ok(hit, path .. ': listed in Features')
    end
    -- step G3 (owner decision 2026-11-02): live-case and volunteer cash are plain switches (no typed ENABLE); the
    -- admin money tools keep it
    H.eq(S.view('RealPlayers.liveCrime.cash').money, nil, 'cash for live cases needs no typed ENABLE')
    H.eq(S.view('RealPlayers.volunteer.cash').money, nil, 'cash for volunteer cases needs no typed ENABLE')
    H.eq(S.view('Cash.allowManualCash').money, true, 'a money tool keeps its typed ENABLE')
    -- step G3: every feature reward is a Money feature with its amounts and the shared item switch as limits
    for _, key in ipairs({
        'reward_suspect',
        'reward_surrender',
        'reward_fto_signoff',
        'reward_fto_complete',
        'reward_sup_award',
    }) do
        local f
        for _, x in ipairs(S._features) do if x.key == key then f = x end end
        H.ok(f and f.play == 'economy' and S.view(f.path) and S.view(f.path).value == false,
            key .. ': a Money feature, Off')
        local hasItems = false
        for _, l in ipairs(f and f.limits or {}) do if l == 'Rewards.enabled' then hasItems = true end end
        H.ok(hasItems, key .. ': shows the item switch next to it')
        H.eq(f and S.view(f.path).money, nil, key .. ': no typed ENABLE')
    end
    H.eq(S.view('FeatureRewards.suspect.money.got_away').value, 1500, 'the suspect\'s default money')
    H.eq((S.check('FeatureRewards.suspect.money.got_away', -5)), false, 'never a negative amount')
    H.eq((S.check('FeatureRewards.suspect.account', 'gold')), false, 'account: bank, cash or item only')
    H.eq((S.check('FeatureRewards.suspect.account', 'item')), true, 'item is an account')

    local view = S.all()
    H.eq(#view.features, #S._features, 'the view lists every feature')
    H.eq(view.features[1].key, 'spawning', 'in order')
    H.eq(view.features[1].risky, true, 'a risky switch asks first')
end

-- ============================================================================
--                       THE SESSION, THE UI AND THE DOCS
-- ============================================================================

do
    local nav = ReadRepo('Crimson-Police/web/src/layouts/adminNav.ts')
    for _, key in ipairs({ 'admin_missions', 'admin_rs', 'admin_officers', 'admin_settings', 'admin_money' }) do
        H.ok(nav and nav:find('    ' .. key .. ': \'', 1, true) ~= nil, key .. ': has a group of play')
    end
    local layout = ReadRepo('Crimson-Police/web/src/layouts/AdminLayout.tsx')
    Has(layout, 'play: adminGroupOf(s.key),', 'the sidebar lists each screen under its group')
    local st = ReadRepo('Crimson-Police/web/src/admin/screens/Settings.tsx')
    Has(st, '<FeaturesPanel', 'Settings has the Features panel')
    local guide = ReadRepo('docs/OWNER_GUIDE.md')
    Has(guide, '**Grouped by who you play against**', 'the owner guide describes the three sections')
    Has(ReadRepo('README.md'), '**Features**', 'and the README the Features overview')
end

return H
