-- Admin UI → Settings (modules/settings): the schema read from config.lua and blocks.lua, every check of a value,
-- saving, resetting and a restart in every storage mode, Config and the clients, the mission and location switches.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

-- ============================================================================
--                                  THE SERVER
-- ============================================================================
-- Real: modules/permissions, modules/admin (cp_audit), modules/confighealth, modules/settings. Stand-ins: CP.Access
-- (the real admin rule over H.players aces), CP.Qbx (citizenids), CP.Tablet (pushes) and CP.Missions.

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if not line:find('crimson%-police') then realPrint(line) end
end
local function Printed(needle)
    for _, l in ipairs(lines) do
        if l:find(needle, 1, true) then return true end
    end
    return false
end

local pushes, reloads = {}, 0
local runs = {}

local function Boot()
    H.boot({ side = 'server', realLocale = true })
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
    H.players[2] = { ace = {} }
    H.players[3] = { ace = { admin = true } }
    CP.Access = {
        isAdmin = function(src)
            if src == 0 then return true end
            local ace = type(Config.AdminAce) == 'string' and Config.AdminAce ~= '' and Config.AdminAce
                or 'crimsonpolice.admin'
            return IsPlayerAceAllowed(src, ace) or (Config.QboxAdmins == true and IsPlayerAceAllowed(src, 'admin'))
        end,
        isSupervisor = function(src) return src == 2 end,
        getOfficer = function() return nil, 'err.not_police' end,
    }
    CP.Qbx = {
        getInfo = function(src) return { citizenid = ('SET%05d'):format(src), name = 'Admin ' .. src } end,
    }
    CP.Tablet = {
        push = function(src, topic, data) pushes[#pushes + 1] = { src = src, topic = topic, data = data } end,
    }
    CP.Runs = {
        all = function() return runs end,
    }
    CP.Missions = {
        reload = function() reloads = reloads + 1 end,
        get = function() return nil end,
    }
    H.load('modules/permissions/server.lua')
    H.load('modules/admin/server.lua')
    H.load('modules/confighealth/server.lua')
    H.load('modules/settings/server.lua')
    H.step(0)
    return CP.Settings
end

H.sql('DELETE FROM cp_settings')
H.sql('DELETE FROM cp_audit')
local S = Boot()
local U = CP.U
local VMT = getmetatable(vec3(0, 0, 0))

H.ok(S.isLoaded(), 'the settings load once the database is ready')

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 's' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end

local function Row(path)
    return H.sql('SELECT setting_key, value_json, updated_by FROM cp_settings WHERE setting_key = \'' .. path .. '\'')[1]
end

local function LastAudit()
    return H.sql('SELECT action, target, old_value, new_value, reason, actor FROM cp_audit ORDER BY id DESC LIMIT 1')[1]
end

local function Check(path, value, none) return S.check(path, value, none) end

local function Err(path, value, expected, msg)
    local ok, e = Check(path, value)
    H.eq(ok, false, msg .. ' (refused)')
    H.eq(e, expected, msg)
end

-- ============================================================================
--                         THE SCHEMA (FROM THE FILES)
-- ============================================================================

do
    local sc = S._schema()
    H.ok(#sc.list > 600, ('every setting of config.lua and blocks.lua is listed (%d)'):format(#sc.list))
    local keys = {}
    for _, sec in ipairs(sc.sections) do keys[#keys + 1] = sec.key end
    H.eq(keys[1], 'general', 'the keys above the first banner are General')
    H.ok(U.contains(keys, 'storage') and U.contains(keys, 'tablet_and_commands') and U.contains(keys, 'blocks'),
        'sections follow the banners of config.lua, then blocks.lua: ' .. table.concat(keys, ', '))
    H.eq(keys[#keys], 'blocks', 'blocks.lua is the last section')
    local titles = {}
    for _, sec in ipairs(sc.sections) do titles[sec.key] = sec.title end
    H.eq(titles.scoring_xp_levels_and_goals, 'Scoring, XP levels and goals', 'banner titles in sentence case')

    local function E(p) return S.entry(p) or {} end
    H.eq(E('Debug').desc, 'true = each module prints tagged debug lines', 'a trailing comment is the description')
    H.eq(E('Tablet.deskDistance').kind, 'number', 'numbers edit as numbers')
    H.eq(E('Tablet.deskDistance').integer, false, '3.0 in config.lua: a decimal number')
    H.eq(E('Tablet.deskDistance').min, 0, 'a positive number cannot go below 0')
    H.ok(E('Limits.corpseCleanup').desc:find(
        '(bodies a Process the scene objective keeps are deleted when it ends)',
        1,
        true
    ) ~= nil, 'a comment continued on the next line is part of it')
    H.ok(E('Draw.zoneClearance').desc:find('(any mission), while another is free', 1, true) ~= nil,
        'a continuation that starts with a bracket too')
    H.ok(E('QboxAdmins').desc:find('are Crimson-Police admins too', 1, true) ~= nil, 'top-level scalars too')
    local accents = E('Departments.sast.theme.personalAccents').desc
    H.ok(accents:find('accents an officer may pick', 1, true) == 1 and accents:find('#ffffff', 1, true) == nil,
        'comment lines above a key describe it; a commented-out entry does not: ' .. accents)
    local groups = {}
    for _, sec in ipairs(sc.sections) do
        for _, g in ipairs(sec.groups) do groups[g.path] = g end
    end
    H.ok(groups.Difficulty and groups.Difficulty.desc:find('1.0 = stars change nothing', 1, true) ~= nil,
        'a table\'s comment describes its group (prose that starts with a number is not code)')
    H.ok(groups.Database and groups.Database.desc:find('enabled = false: database off', 1, true) ~= nil,
        'the comment under a banner describes the first table')
    H.eq(E('Database.enabled').locked, 'settings.locked.database', 'where the settings live: config.lua only')
    H.eq(E('MissionTypes.patrol.dailyLimit').nullable, true, 'dailyLimit = nil is a setting that may stay unset')
    H.eq(E('MissionTypes.patrol.dailyLimit').default, nil, 'with no value in config.lua')
    H.eq(E('Blocks.escort.speed').kind, 'range', 'blocks.lua { min, max, default } edit as ranges')
    H.eq(E('Blocks.escort.speed').section, 'blocks', 'in the blocks.lua section')
    H.eq(E('Blocks.search_area.shrinkTo').kind, 'numbers', 'shrinkTo { 300, 150, 50 } is not a range')
    H.eq(E('Difficulty.pointsByStars').integer, false, '{ 1.0, 1.0, 1.0 }: the screen allows decimals')
    H.eq(E('Units.nearbyBands').integer, true, '{ 250, 1000, 3000 }: whole numbers')
    H.eq(E('Blocks.escort.style.default').kind, 'enum', 'a default picks one of its options')
    H.eq(E('Blocks.pursuit.responses').kind, 'json', 'chances that must add up to 100 are one setting')
    H.eq(E('Tablet.desks').restart, false, 'desks change live (the zones are made again on every client)')
    H.eq(E('Tablet.command').restart, true, 'commands too')
    H.ok(not E('Tablet.title').restart, 'the title is read live')
    H.eq(E('Blocks.escort.speed').reload, true, 'a block range reloads the missions')
    H.eq(E('Tablet.item').kind, 'optionalText', 'false or an item name')
    H.eq(E('Custody.parkingRules.free').kind, 'enum', 'false or cite/impound')
    H.ok(S.entry('DisabledLocations') ~= nil and S.entry('MissionTweaks') ~= nil, 'open tables are one setting')
    H.eq(S.entry('Tablet'), nil, 'a table of settings is not a setting itself')
    H.ok(E('Builder.requireTestToPublish').desc:find('testing is optional for everyone', 1, true) ~= nil,
        'the new test switch is listed with its comment')

    -- every setting is a key of Config (or a nil key config.lua names)
    local bad = {}
    for _, e in ipairs(sc.list) do
        if U.getPath(Config, e.path) == nil and not e.nullable and e.path ~= 'DisabledLocations' then
            bad[#bad + 1] = e.path
        end
    end
    H.eq(table.concat(bad, ', '), '', 'every listed setting exists in Config')

    -- the descriptions follow the file: a changed comment shows up without code changes
    local realLoad = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        local s = realLoad(res, path)
        if path == 'config/config.lua' and s then
            s = s:gsub('%-%- metres: walking further than this from the desk closes the tablet',
                '-- metres before the tablet closes (edited)', 1)
        end
        return s
    end
    S._resetSchema()
    H.eq(S.entry('Tablet.deskDistance').desc, 'metres before the tablet closes (edited)',
        'the descriptions are read from the file itself')
    _G.LoadResourceFile = realLoad
    S._resetSchema()

    H.eq(S._isCode('text    = \'#ffffff\',   -- optional'), true, 'a commented-out value is code')
    H.eq(S._isCode('bcso = {'), true, 'a commented-out table is code')
    H.eq(S._isCode('},'), true, 'a closing bracket is code')
    H.eq(S._isCode('enabled = true:  keep everything in your database'), false, 'prose with "x = y:" is not')
    H.eq(S._isCode('(any mission), while another is free'), false, 'a bracketed continuation is not')
end

-- ============================================================================
--                               CHECKING A VALUE
-- ============================================================================

do
    local ok, v = Check('Tablet.deskDistance', 4)
    H.ok(ok and v == 4.0 and math.type(v) == 'float', 'a whole number for a decimal setting becomes 4.0 (natives)')
    Err('Tablet.deskDistance', 'far', 'err.setting_number', 'text for a number')
    Err('Tablet.deskDistance', -1, 'err.setting_negative', 'a positive setting stays at 0 or above')
    Err('Tablet.deskDistance', 0 / 0, 'err.setting_number', 'NaN')
    Err('Tablet.deskDistance', 1e12, 'err.setting_range', 'a typo-sized number')
    ok, v = Check('Limits.maxUnitSize', 6.0)
    H.ok(ok and v == 6 and math.type(v) == 'integer', '6.0 for a whole-number setting becomes 6')
    Err('Limits.maxUnitSize', 4.5, 'err.setting_whole', 'a fraction for a whole-number setting')
    Err('Limits.maxUnitSize', 17, 'err.setting_range', 'above the known range (1 to 16)')
    Err('Time.resetHour', 24, 'err.setting_range', 'an hour past 23')
    Err('Scoring.common.heavyDamage', 5, 'err.setting_positive', 'a penalty stays a penalty')
    H.ok((Check('NpcDifficulty.custom.accuracyAdd', -5)), 'NPC difficulty adds may go either way')
    Err('Debug', 'yes', 'err.setting_type', 'text for on/off')
    Err('AdminTheme.primary', '#zzzzzz', 'err.setting_colour', 'a colour must be #rrggbb')
    H.ok((Check('AdminTheme.primary', '#112233')), 'a valid colour')
    Err('Cash.account', 'wallet', 'err.setting_option', 'not one of bank/cash')
    H.ok((Check('Tablet.item', false)), 'the tablet item off')
    ok, v = Check('Tablet.item', 'police_tablet')
    H.eq(v, 'police_tablet', 'the tablet item on')
    Err('Tablet.item', true, 'err.setting_type', 'true is not an item name')
    Err('Tablet.item', 'bad name!', 'err.setting_text', 'an item name with spaces')
    Err('Tablet.command', 'CopTab', 'err.setting_locked', 'the command names are Hard rule names: config.lua only')
    Err('Tablet.keybind', 'F 6', 'err.setting_text', 'a default key with a space')
    H.ok((Check('Tablet.keybind', '')), 'an empty default key (none)')

    ok, v = Check('Downed.dropOffs', { { x = 1, y = 2, z = 3 }, { x = 4.5, y = 5, z = 6 } })
    H.ok(ok and getmetatable(v[1]) == VMT and v[2].x == 4.5 and math.type(v[1].x) == 'float',
        'drop-offs come back as vectors with decimal coordinates')
    Err('Downed.dropOffs', { { x = 1, y = 2 } }, 'err.setting_vector', 'a coordinate missing')
    Err('Downed.dropOffs', { { x = 1, y = 2, z = 3, q = 4 } }, 'err.setting_vector', 'an unknown coordinate')

    ok, v = Check('Blocks.escort.speed', { 20, 100, 50 })
    H.ok(ok and v[2] == 100, 'a block range')
    Err('Blocks.escort.speed', { 130, 120, 60 }, 'err.setting_min_max', 'min above max')
    Err('Blocks.escort.speed', { 20, 120, 150 }, 'err.setting_default_range', 'the default outside min and max')
    Err('Blocks.escort.speed', { 20, 120 }, 'err.setting_list', 'a range keeps its three numbers')
    Err('Blocks.escort.speed', { 20.5, 120, 60 }, 'err.setting_whole', 'whole numbers like blocks.lua')
    ok, v = Check('Difficulty.pointsByStars', { 1, 1.5, 2 })
    H.ok(ok and math.type(v[1]) == 'float', 'a fixed list of numbers keeps its kind')
    Err('Difficulty.pointsByStars', { 1, 2 }, 'err.setting_list', 'and its length')
    Err('Blocks.search_area.shrinkTo', { 300, 150 }, 'err.setting_list', 'shrinkTo keeps three radii')

    H.ok((Check('Builder.allowed.weapons', { 'WEAPON_PISTOL' })), 'a list of names')
    H.ok((Check('Builder.allowed.weapons', {})), 'an empty list')
    Err('Builder.allowed.weapons', { 5 }, 'err.setting_type', 'a number in a list of names')
    Err('Builder.allowed.weapons', { a = 'b' }, 'err.setting_list', 'a table for a list')
    Err('Leaderboard.metrics', { 'points', 'nope' }, 'err.setting_option', 'an unknown board metric')
    Err('Leaderboard.metrics', {}, 'err.setting_too_few', 'at least one board metric')
    Err('Leaderboard.metrics', { 'points', 'points' }, 'err.setting_duplicate', 'a metric twice')
    Err('Departments.sast.jobs', {}, 'err.setting_too_few', 'a department keeps one job at least')

    local rows = U.deepcopy(Config.Scaling)
    rows[1].count = 1.1
    H.ok((Check('Scaling', rows)), 'the scaling rows with a changed count')
    rows[1].tier = nil
    Err('Scaling', rows, 'err.setting_missing', 'a row without a field every row has')
    rows = U.deepcopy(Config.Scaling)
    rows[2].extra = 1
    Err('Scaling', rows, 'err.setting_key', 'a row with an unknown field')
    local goals = U.deepcopy(Config.Goals.daily)
    goals[#goals + 1] = { id = 'any_5', label = 'Complete 5 missions', count = 5 }
    H.ok((Check('Goals.daily', goals)), 'a new goal with the fields the others use')

    H.ok((Check('Tablet.desks', {
        { label = 'Desk', coords = { x = 1, y = 2, z = 3 }, size = { x = 1, y = 1, z = 1 }, departments = { 'fib' } },
    })), 'a desk for one department')
    Err('Tablet.desks', { { label = 'Desk' } }, 'err.setting_missing', 'a desk without coordinates')
    H.ok((Check('MissionTweaks', { prison_break = { cooldown = 1800, disabledLocations = { 'North gate' } } })),
        'a mission tweak')
    Err('MissionTweaks', { prison_break = { payout = 5 } }, 'err.setting_key', 'a tweak key that is not allowed')
    H.ok((Check('DisabledLocations', { beat_patrol = { 2, 'Vinewood Blvd' } })), 'locations off by number or label')
    Err('DisabledLocations', { beat_patrol = { 0 } }, 'err.setting_range', 'location numbers start at 1')
    H.ok((Check('Rewards.levels', { ['10'] = { item = 'water', count = 1, value = 20 } })), 'free reward tables')
    ok, v = Check('Rewards.levels', { ['10'] = { item = 'water', count = 1, value = 20 } })
    H.ok(ok and v[10] ~= nil, 'reward levels keyed by number come back keyed by number')

    ok, v = Check('MissionTypes.patrol.dailyLimit', nil, true)
    H.ok(ok and v == nil, 'dailyLimit may be unset again')
    H.ok((Check('MissionTypes.patrol.dailyLimit', 3)), 'or a number')
    local okN, eN = Check('Debug', nil, true)
    H.ok(not okN and eN == 'err.setting_required', 'a setting with a value in config.lua cannot be unset')
    Err('Database.enabled', false, 'err.setting_locked', 'where the data lives: config.lua only')
    Err('Nope.nothing', 1, 'err.setting_unknown', 'not a setting')

    H.ok((Check('Blocks.pursuit.responses', { yield = 10, flee = 80, fight = 10 })), 'chances that add up to 100')
    Err('Blocks.pursuit.responses', { yield = 10, flee = 10, fight = 10 }, 'err.setting_sum_100', 'or do not')
    Err('Blocks.escort.style.options', { 'careful', 'fast' }, 'err.setting_options_default',
        'the options keep the default (normal)')
    Err('Blocks.escort.style.default', 'sporty', 'err.setting_option', 'a default not among the options')
    Err('CrossDept.minParticipants', 9, 'err.setting_order', 'min participants above max')
    Err('Builder.exportPath', '../modules/', 'err.setting_text', 'the export folder stays in missions/custom')
    Err('Builder.exportPath', 'missions/custom/../../modules/', 'err.setting_text', 'no way out of it')
    Err('Builder.exportPath', 'missions/custom//x/', 'err.setting_path', 'nor an empty folder name')
    H.ok((Check('Builder.exportPath', 'missions/custom/server/')), 'a subfolder of missions/custom')
    Err('Profile.bannedWordsFile', '../server.cfg', 'err.setting_text', 'the banned-words file is a .txt')
    H.ok((Check('Profile.bannedWordsFile', false)), 'no banned-words file')
end

-- ============================================================================
--                    SAVING, CONFIG, CLIENTS AND THE AUDIT
-- ============================================================================

do
    H.reset()
    local before = Config.Tablet
    local ok, res = S.set(1, 'Tablet.deskDistance', 4.5)
    H.ok(ok and res.settings[1].changed == true, 'an admin saves a setting')
    H.eq(Config.Tablet.deskDistance, 4.5, 'Config has it at once')
    H.eq(Config.Tablet.title, 'Crimson-Police', 'the rest of the section keeps config.lua\'s values')
    H.ok(Config.Tablet ~= before, 'the section is a new table (modules\' caches of it rebuild)')
    local row = Row('Tablet.deskDistance')
    H.ok(row and cjson.decode(row.value_json).v == 4.5, 'saved in cp_settings')
    H.eq(row and row.updated_by, 'SET00001', 'with who changed it')
    local a = LastAudit()
    -- the mysql CLI hands numeric text over as numbers: compare as text
    H.ok(
        a and a.action == 'settingChanged' and a.target == 'Tablet.deskDistance' and tostring(a.old_value) == '3'
            and tostring(a.new_value) == '4.5' and a.actor == 'SET00001',
        'audited: who, what, old -> new'
    )
    local sync = H.findEvents('crimson-police:client:settings')
    H.ok(#sync == 1 and sync[1].target == -1, 'every client gets the settings')
    local found = false
    for _, item in ipairs(sync[1] and sync[1].args[1] or {}) do
        if item.path == 'Tablet.deskDistance' and item.value == 4.5 then found = true end
    end
    H.ok(found, 'with the new value')
    H.ok(type(res.health) == 'table' and #res.health > 0, 'the Config health check runs again after the change')
    local hasSettingsLine = false
    for _, l in ipairs(res.health) do
        if l.check == 'settings' and l.text:find('1 setting', 1, true) then hasSettingsLine = true end
    end
    H.ok(hasSettingsLine, 'and names the settings changed in game')
    local pushed = false
    for _, p in ipairs(pushes) do
        if p.src == 1 and p.topic == 'settings' then pushed = true end
    end
    H.ok(pushed, 'the admins\' Settings screens refresh')

    H.reset()
    ok = S.set(1, 'Tablet.deskDistance', 3.0)
    H.ok(ok and Row('Tablet.deskDistance') == nil, 'setting config.lua\'s value again removes the saved one')
    H.eq(LastAudit().action, 'settingReset', 'audited as a reset')
    H.eq(Config.Tablet.deskDistance, 3.0, 'Config is back to config.lua')

    S.set(1, 'Debug', not Config.Debug)
    local dbg = Config.Debug
    ok = S.reset(1, 'Debug')
    H.ok(ok and Config.Debug ~= dbg and Row('Debug') == nil, 'Reset puts config.lua\'s value back')

    -- nil settings
    ok = S.set(1, 'MissionTypes.patrol.dailyLimit', 3)
    H.ok(ok and Config.MissionTypes.patrol.dailyLimit == 3, 'a daily limit where config.lua has none')
    ok = S.set(1, 'MissionTypes.patrol.dailyLimit', nil, true)
    H.ok(ok and Config.MissionTypes.patrol.dailyLimit == nil and Row('MissionTypes.patrol.dailyLimit') == nil,
        'unset again = config.lua\'s nil')

    -- false values reach Config and the clients
    S.set(1, 'Tablet.access.keybind', false)
    H.eq(Config.Tablet.access.keybind, false, 'a switch turned off')
    local last = H.findEvents('crimson-police:client:settings')
    local sent = nil
    for _, item in ipairs(last[#last].args[1]) do if item.path == 'Tablet.access.keybind' then sent = item end end
    H.ok(sent and sent.value == false, 'false is sent to the clients as false')
    S.reset(1, 'Tablet.access.keybind')

    -- vectors
    ok = S.set(1, 'Downed.dropOffs', { { x = 10, y = 20, z = 30 } })
    H.ok(ok and getmetatable(Config.Downed.dropOffs[1]) == VMT and Config.Downed.dropOffs[1].z == 30.0,
        'a list of drop-offs is saved and used as vectors')
    H.eq(#Config.Downed.dropOffs, 1, 'the list replaces config.lua\'s')
    S.reset(1, 'Downed.dropOffs')
    H.eq(#Config.Downed.dropOffs, 2, 'and comes back on reset')

    -- who is an admin only changes in config.lua: never everyone an admin, never every admin locked out
    local okA, eA = S.set(1, 'AdminAce', 'crimsonpolice.boss')
    H.ok(not okA and eA == 'err.setting_locked', 'AdminAce cannot change in game')
    local okQ, eQ = S.set(1, 'QboxAdmins', false)
    H.ok(not okQ and eQ == 'err.setting_locked', 'nor QboxAdmins')
    H.eq(Config.AdminAce, 'crimsonpolice.admin', 'AdminAce stays config.lua\'s')
    H.eq(Config.QboxAdmins, true, 'QboxAdmins too')
    H.eq(S.entry('AdminAce').locked, 'settings.locked.admin', 'the screen shows why')
    H.eq(S.entry('QboxAdmins').locked, 'settings.locked.admin', 'for both')

    -- restart settings: saved now, used after a restart
    ok, res = S.set(1, 'Tablet.keybind', 'F6')
    H.ok(ok, 'a restart setting is saved')
    H.eq(Config.Tablet.keybind, '', 'but Config keeps the running value until a restart')
    H.ok(res.settings[1].pending == true and res.pending == 1, 'the screen shows it waits for a restart')
    H.eq(res.settings[1].saved, 'F6', 'with the saved value')

    -- the missions reload once after a burst of changes to what the loader reads
    reloads = 0
    S.set(1, 'Blocks.escort.speed', { 20, 110, 60 })
    S.set(1, 'Blocks.escort.arrival', { 10, 40, 20 })
    H.eq(reloads, 0, 'not at once')
    H.advance(1500)
    H.eq(reloads, 1, 'one missions reload after the changes')

    -- net: admins only, JSON from the editor, the screen's data, the history
    local okP, eP = Act('server:admin:setSetting', 2, { path = 'Debug', value = true })
    H.ok(okP == false and eP == 'err.no_permission', 'a supervisor cannot change settings')
    local okJ, dJ = Act('server:admin:setSetting', 1, { path = 'Units.nearbyBands', json = '[200, 900, 2500]' })
    H.ok(okJ == true and Config.Units.nearbyBands[2] == 900, 'the JSON editor\'s text is read on the server')
    H.ok(type(dJ) == 'table' and dJ.settings[1].changed, 'the reply carries the changed setting')
    local okB, eB = Act('server:admin:setSetting', 1, { path = 'Units.nearbyBands', json = '[200, ' })
    H.ok(okB == false and eB == 'err.setting_json', 'broken JSON is refused')
    okB, eB = Act('server:admin:setSetting', 1, { path = 'Units.nearbyBands', value = { 1, 2 } })
    H.ok(okB == false and eB == 'err.setting_list', 'a refused value names why')
    local view = Cb('admin:getSettings', 1)
    H.ok(view and view.ok and #view.data.sections > 30, 'the Settings screen gets every section')
    H.ok(view.data.total > 600 and view.data.changed >= 3,
        ('with counts (%d settings, %d changed)'):format(view.data.total or 0, view.data.changed or 0))
    local deny = Cb('admin:getSettings', 2)
    H.ok(deny and deny.ok == false, 'only admins see it')
    local hist = Cb('admin:getSettingsHistory', 1, { page = 1 })
    H.ok(hist and hist.ok and #hist.data.rows > 5 and hist.data.rows[1].action ~= nil, 'the change history')
    local hp = Cb('admin:getSettingsHistory', 1, { path = 'Units.nearbyBands' })
    H.ok(hp and hp.ok and #hp.data.rows == 1 and hp.data.rows[1].newValue == '[200,900,2500]',
        'the history of one setting: ' .. cjson.encode(hp and hp.data and hp.data.rows or {}))

    -- a client that starts asks for the settings
    H.reset()
    H.fire('crimson-police:server:settingsHello', 7)
    local hello = H.findEvents('crimson-police:client:settings')
    H.ok(#hello == 1 and hello[1].target == 7, 'a starting client gets the settings')
end

-- ============================================================================
--                        A RESTART AND BAD SAVED VALUES
-- ============================================================================

do
    H.sql([[INSERT INTO cp_settings (setting_key, value_json, updated_by) VALUES
        ('Limits.maxUnitSize', '{"v": "lots"}', 'SET00001'), ('Old.removed', '{"v": 1}', 'SET00001')]])
    H.restart()
    lines = {}
    S = Boot()
    H.eq(Config.Tablet.keybind, 'F6', 'after a restart the saved default key is used')
    H.eq(Config.Units.nearbyBands[3], 2500, 'every saved setting is over config.lua from the start')
    H.eq(Config.Blocks.escort.speed[2], 110, 'blocks.lua settings too')
    H.eq(Config.Limits.maxUnitSize, 4, 'a saved value that is not allowed is ignored')
    H.ok(Printed('the saved setting Limits.maxUnitSize was ignored'), 'with one clear console line')
    H.ok(Printed('the saved setting Old.removed was ignored'), 'a setting config.lua no longer has too')
    local v = S.view('Limits.maxUnitSize')
    H.ok(v.invalid == 'err.setting_number' and v.invalidValue == 'lots', 'the screen shows the ignored value')
    H.ok(S.view('Tablet.keybind').pending == nil, 'nothing waits for a restart any more')
    local warn = false
    for _, l in ipairs(CP.ConfigHealth.run()) do
        if l.check == 'settings' and l.level == 'warn' and l.text:find('Limits.maxUnitSize', 1, true) then
            warn = true
        end
    end
    H.ok(warn, 'Config health names the ignored setting')
    local ok = S.reset(1, 'Limits.maxUnitSize')
    H.ok(ok and Row('Limits.maxUnitSize') == nil, 'an ignored setting can be reset')

    -- reset all
    local okAll = S.resetAll(1)
    H.ok(okAll, 'reset all')
    H.eq(#H.sql('SELECT setting_key FROM cp_settings'), 0, 'no saved setting is left')
    H.eq(Config.Units.nearbyBands[3], 3000, 'Config is config.lua again')
    H.eq(LastAudit().action, 'settingsResetAll', 'audited once')
    H.eq(Config.Tablet.keybind, 'F6', 'a restart setting keeps running until the next restart')
    H.ok(S.view('Tablet.keybind').pending, 'and says so')
end

-- ============================================================================
--                        MISSION AND LOCATION SWITCHES
-- ============================================================================

do
    H.restart()
    S = Boot()
    local blocks = {}
    local p = io.popen('ls ' .. H.root .. 'blocks')
    for b in p:lines() do blocks[#blocks + 1] = b end
    p:close()
    for _, b in ipairs(blocks) do H.load('blocks/' .. b .. '/server.lua') end
    CP.Missions = nil
    local realWarn = CP.warn
    CP.warn = function() end
    H.load('modules/missions/server.lua')
    local M = CP.Missions
    local summary = M.loadAll()
    CP.warn = realWarn
    H.ok(summary.loaded > 15, 'the real missions load')
    H.load('modules/draw/server.lua')
    local Draw = CP.Draw

    local def = M.get('beat_patrol')
    local n = #def.locations
    H.ok(M.isEnabled('beat_patrol'), 'a mission starts on')
    local ok, view = S.setMissionEnabled(1, 'beat_patrol', false)
    H.ok(ok and view.on == false and view.changed, 'an admin turns a mission off')
    H.eq(M.isEnabled('beat_patrol'), false, 'it is out of every pool at once')
    H.ok(U.contains(Config.DisabledMissions, 'beat_patrol'), 'through Config.DisabledMissions')
    H.ok(M.get('beat_patrol') ~= nil, 'its definition stays loaded: a run already going finishes')
    local a = LastAudit()
    H.ok(a.action == 'missionSwitch' and a.target == 'beat_patrol' and a.old_value == 'on' and a.new_value == 'off',
        'audited')
    ok, view = S.setMissionEnabled(1, 'beat_patrol', true)
    H.ok(ok and view.on and not view.changed and M.isEnabled('beat_patrol'), 'and on again')
    H.eq(Row('DisabledMissions'), nil, 'back to config.lua: nothing is saved')

    local label = def.locations[2].label
    ok, view = S.setLocationEnabled(1, 'beat_patrol', 2, false)
    H.ok(ok and view.locations[2].on == false and view.locationsOff == 1, 'a location turned off')
    H.eq(M.isLocationEnabled('beat_patrol', 2), false, 'the loader\'s check says so')
    H.eq(Config.DisabledLocations.beat_patrol[1], label, 'saved by its label')
    H.eq(#M.enabledLocations(def), n - 1, 'one location fewer')
    local seen = {}
    for seed = 1, 60 do
        local i = Draw.pickLocation(def, {}, U.rng(seed))
        if i then seen[i] = true end
    end
    H.ok(not seen[2] and next(seen) ~= nil, 'the draw never picks it')
    H.eq(LastAudit().action, 'locationSwitch', 'audited')
    for i = 1, n do
        if i ~= 4 then S.setLocationEnabled(1, 'beat_patrol', i, false) end
    end
    local only = {}
    for seed = 1, 20 do only[Draw.pickLocation(def, {}, U.rng(seed)) or 0] = true end
    H.ok(only[4] and U.count(only) == 1, 'with one location left it is always that one')
    S.setLocationEnabled(1, 'beat_patrol', 4, false)
    H.eq(M.isEnabled('beat_patrol'), false, 'every location off: the mission is never drawn')
    H.eq(Draw.pickLocation(def, {}, U.rng(1)), nil, 'and no location is picked')
    ok, view = S.resetMission(1, 'beat_patrol')
    H.ok(ok and view.locationsOff == 0 and view.on and not view.changed, 'reset to default')
    H.ok(M.isEnabled('beat_patrol') and Row('DisabledLocations') == nil, 'nothing saved any more')
    H.eq(LastAudit().action, 'missionSwitchesReset', 'audited once')

    local okU, eU = S.setMissionEnabled(1, 'no_such_mission', false)
    H.ok(not okU and eU == 'err.unknown_mission', 'an unknown mission')
    local okL, eL = S.setLocationEnabled(1, 'beat_patrol', n + 1, false)
    H.ok(not okL and eL == 'err.invalid_location', 'an unknown location')
    local okD, eD = Act('server:admin:setMissionEnabled', 2, { missionId = 'beat_patrol', enabled = false })
    H.ok(okD == false and eD == 'err.no_permission', 'supervisors cannot switch missions')
    local okN = Act('server:admin:setLocationEnabled', 1, { missionId = 'beat_patrol', index = 1, enabled = false })
    H.ok(okN == true and not M.isLocationEnabled('beat_patrol', 1), 'admins can, through the net action')
    Act('server:admin:resetMissionSwitches', 1, { missionId = 'beat_patrol' })
    H.ok(M.isLocationEnabled('beat_patrol', 1), 'and reset them')

    -- a location label used twice is saved by its number
    local twin = U.deepcopy(def)
    twin.locations[3].label = twin.locations[1].label
    local realGet = M.get
    M.get = function(id) if id == 'beat_patrol' then return twin end return realGet(id) end
    S.setLocationEnabled(1, 'beat_patrol', 3, false)
    H.eq(Config.DisabledLocations.beat_patrol[1], 3, 'by number when its label is not unique')
    H.ok(M.isLocationEnabled('beat_patrol', 1), 'so the other location with that label stays on')
    S.resetMission(1, 'beat_patrol')
    M.get = realGet

    -- the Admin UI Missions list carries the switches
    H.ok(S.missionView(def).locations[1].label == def.locations[1].label, 'the Missions screen gets every location')
    S.setLocationEnabled(1, 'beat_patrol', 2, false)
    local listed = Cb('admin:getMissions', 1)
    local entry = nil
    for _, m in ipairs(listed and listed.ok and listed.data.missions or {}) do
        if m.id == 'beat_patrol' then entry = m end
    end
    H.ok(entry and entry.switch and entry.switch.locationsOff == 1 and #entry.switch.locations == n,
        'admin:getMissions lists each mission with its switches')
    S.resetMission(1, 'beat_patrol')
end

-- ============================================================================
--                               THE CLIENT HALF
-- ============================================================================

do
    H.restart()
    H.boot({ side = 'client' })
    H.load('modules/settings/client.lua')
    local C = CP.Settings
    H.eq(#H.findEvents('crimson-police:server:settingsHello'), 1, 'the client asks for the settings at start')
    H.eq(C.received(), false, 'nothing received yet')
    local handler = H.handlers['crimson-police:client:settings'][1]
    handler({
        { path = 'Tablet.deskDistance', value = 5.5 },
        { path = 'Tablet.access.keybind', value = false },
        { path = 'MissionTypes.patrol.dailyLimit', value = 2 },
        { path = 'Downed.dropOffs', value = { vec3(1.0, 2.0, 3.0) } },
    })
    H.eq(C.received(), true, 'received')
    H.eq(Config.Tablet.deskDistance, 5.5, 'client code reads the server\'s values')
    H.eq(Config.Tablet.access.keybind, false, 'false too')
    H.eq(Config.MissionTypes.patrol.dailyLimit, 2, 'and keys config.lua leaves nil')
    H.eq(Config.Tablet.title, 'Crimson-Police', 'the rest stays config.lua\'s')
    handler({ { path = 'Tablet.title', value = 'Station' } })
    H.eq(Config.Tablet.deskDistance, 3.0, 'a setting the server no longer sends is config.lua\'s again')
    H.eq(Config.Tablet.title, 'Station', 'the new list applies')
    H.eq(#Config.Downed.dropOffs, 2, 'every section the server touched before is rebuilt')
    H.ok(C.ready(0), 'ready() answers at once once received')
end

return H
