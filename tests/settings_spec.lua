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
    H.eq(titles.scaling_by_participants, 'Scaling by participants', 'short words such as BY go to lower case')
    H.eq(titles.route_to_the_start, 'Route to the start', 'TO goes to lower case')
    H.eq(titles.built_in_mission_tweaks, 'Built-in mission tweaks', 'IN goes to lower case')
    H.eq(titles.volunteer_suspects, 'Volunteer suspects (options B and C)', 'single option letters stay capitals')
    -- keys that read alike get their own names from settings.label.<path>
    H.eq(S.entry('Tablet.keybind').label, 'Default tablet key', 'the tablet key has its own label')
    H.eq(S.entry('Tablet.access.keybind').label, 'Players may open the tablet with a key', 'the key switch too')
    H.eq(S.entry('Builder.minLocations').label, 'Locations each new mission needs', 'the builder minimum')
    H.eq(S.entry('MissionCalls.minLocationsPerArea').label, 'Locations a call area needs', 'the call area minimum')
    H.eq(S.entry('Tablet.command').label, 'Command', 'a key without a locale label keeps its own name')

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
    H.eq(E('Draw.hardClearance').max, 500, 'hard clearance: 0 to 500 m')
    H.ok(E('Draw.hardClearance').desc:find('even when nothing else is free (0 = off', 1, true) ~= nil,
        'hard clearance: its comment is the description')
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
    H.eq(E('AdminUi.groupSidebar').default, true, 'the Admin UI sidebar ships grouped')
    H.ok(E('AdminUi.groupSidebar').desc:find('folds the rest under More', 1, true) ~= nil,
        'groupSidebar: its config.lua comment is its description')
    H.eq(E('AdminUi.landing').default, 'home', 'the Admin UI ships opening on Home')
    H.eq(E('AdminUi.landing').kind, 'enum', 'landing is a choice')
    H.ok(E('AdminUi.landing').desc:find('a landing screen with the common jobs', 1, true) ~= nil,
        'landing: its config.lua comment is its description')
    H.eq(E('AdminUi.homeForms').default, true, 'the Home tiles ship with their quick forms')
    H.eq(E('AdminUi.homeForms').kind, 'boolean', 'homeForms is a switch')
    H.ok(E('AdminUi.homeForms').desc:find('the Home tiles hold the quick forms', 1, true) ~= nil,
        'homeForms: its config.lua comment is its description')
    H.eq(cjson.encode(E('AdminUi.reasonChips').default), '["Balance change","Event","Correction"]',
        'the reason buttons ship with three ready-made reasons')
    H.eq(E('AdminUi.reasonChips').kind, 'list', 'reasonChips is a list of texts')
    H.ok((E('AdminUi.reasonChips').desc or ''):find('a click fills the box', 1, true) ~= nil,
        'reasonChips: its config.lua comment is its description')
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
    H.ok(
        E('Builder.supervisorItems') ~= nil and E('Builder.supervisorItems').kind == 'boolean'
            and E('Builder.supervisorItems').desc:find('only admins may put items in a custom mission', 1, true)
                ~= nil,
        'Builder.supervisorItems is a true/false setting with its comment'
    )
    H.eq(E('Builder.supervisorItems').restart, false, 'and changes live')
    H.ok(
        E('Builder.useMyPosition') ~= nil and E('Builder.useMyPosition').kind == 'boolean'
            and E('Builder.useMyPosition').default == true
            and E('Builder.useMyPosition').desc:find('the point goes where you stand', 1, true) ~= nil,
        'Builder.useMyPosition is a true/false setting, shipped on, with its comment'
    )
    H.ok(
        E('Builder.teleport') ~= nil and E('Builder.teleport').kind == 'boolean'
            and E('Builder.teleport').default == true
            and E('Builder.teleport').desc:find('the server reads the saved point', 1, true) ~= nil,
        'Builder.teleport is a true/false setting, shipped on, with its comment'
    )
    local grants = E('Permissions.builderTeleport')
    H.ok(
        grants ~= nil and grants.kind == 'json' and next(grants.default or { 1 }) == nil
            and grants.desc:find('Empty = admins only', 1, true) ~= nil,
        'Permissions.builderTeleport is one setting by department, shipped empty (admins only), with its comment'
    )

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

-- The Simple set: the everyday settings and the plain groups the sections fold into.
do
    local sc = S._schema()
    H.ok(#S._common >= 20 and #S._common <= 30, ('about 25 everyday settings (%d)'):format(#S._common))
    for _, path in ipairs(S._common) do
        local e = S.entry(path)
        H.ok(e ~= nil and e.common == true, path .. ': an everyday setting config.lua has, marked common')
        H.ok(CP.Locale.has('settings.label.' .. path), path .. ': a plain label in locales/parts/settings.json')
        H.ok(type(e and e.help) == 'string' and e.help ~= '' and e.desc ~= '',
            path .. ': a help text and a description')
    end
    H.eq(S.entry('Tablet.command').common, nil, 'a setting off the list is not common')
    H.eq(#S.commonPaths(), #S._common, 'every everyday setting is offered')
    H.eq(#S._groups, 8, 'eight plain groups')
    local seen = {}
    for _, g in ipairs(S._groups) do
        H.ok(CP.Locale.has('settings.group.' .. g.key) and CP.Locale.has('settings.group_help.' .. g.key),
            g.key .. ': a title and a help text')
        for _, key in ipairs(g.sections) do
            H.eq(seen[key], nil, key .. ': in one group only')
            seen[key] = g.key
        end
    end
    for _, sec in ipairs(sc.sections) do
        H.ok(seen[sec.key] ~= nil, sec.key .. ': a group names this section')
        H.eq(sec.group, seen[sec.key], sec.key .. ': the section carries its group')
    end
    H.eq(seen.suspect_behaviour, 'npcs', 'NPC combat and running away are under NPCs')
    local view = S.all()
    local n = 0
    for _, g in ipairs(view.groups) do n = n + #g.sections end
    H.eq(n, #view.sections, 'the view lists every section under one group')
    H.eq(view.groups[1].title, 'Tablet', 'group titles come from the locale')
    H.eq(S.view('Flee.sprintSeconds').common, true, 'a setting view says it is common')
    H.eq(S.view('Flee.sprintSeconds').label, 'Seconds a runner sprints', 'with its plain label')
    -- Config.AdminUi.settingsView: the view the screen opens in
    H.eq(S.entry('AdminUi.settingsView').default, 'simple', 'Settings ships opening in Simple')
    H.eq(S.entry('AdminUi.settingsView').kind, 'enum', 'settingsView is a choice')
    H.ok(S.entry('AdminUi.settingsView').desc:find('only the everyday settings in plain groups', 1, true) ~= nil,
        'settingsView: its config.lua comment is its description')
    H.eq(view.view, 'simple', 'the view asks the screen to open in Simple')
    Config.AdminUi.settingsView = 'all'
    H.eq(S.all().view, 'all', 'settingsView = all: the screen opens on every setting')
    Config.AdminUi.settingsView = 'bogus'
    H.eq(S.all().view, 'simple', 'an unknown view falls back to Simple')
    Config.AdminUi.settingsView = 'simple'
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
    -- the twists officers choose (PLAN M8b): a switch, a points share and a cash multiplier each, and the two caps
    H.ok((Check('Events.twists.time_crunch.enabled', false)), 'a twist can be switched off')
    H.ok((Check('Events.twists.radio_silence.points', 0.4)), 'a twist\'s points share')
    Err('Events.twists.radio_silence.cash', 0.8, 'err.setting_range', 'a twist\'s cash multiplier never takes cash')
    Err('Events.twists.armored_hostiles.points', 3, 'err.setting_range', 'a twist adds at most 2 x P')
    Err('Events.twistMaxCash', 0.5, 'err.setting_range', 'the stacked cash cap is at least x1.0')
    H.ok((S.entry('Events.twists.time_crunch.points') or {}).points == true,
        'a twist\'s points share is a points value')
    H.ok(((S.entry('Events.modifierChance') or {}).desc or ''):find('random twist', 1, true) ~= nil,
        'the random roll is described as an extra on top of the chosen twists')
    Err('Events.modifierPoints', 0.25, 'err.setting_unknown', 'the old single modifier reward is gone')
    -- Config.NpcCombat (how hard mission NPCs fight back): listed with its comments, ranges and options
    local function E(p) return S.entry(p) or {} end
    H.ok((E('NpcCombat.accuracyMax').desc or ''):find('never above this', 1, true) ~= nil,
        'the cap is listed with its comment')
    H.ok((E('NpcCombat.noCriticalHits').desc or ''):find('headshot', 1, true) ~= nil, 'the headshot switch too')
    H.eq(E('NpcCombat.firingPattern').kind, 'enum', 'the firing pattern is a pick from its options')
    H.ok((Check('NpcCombat.firingPattern', 'burst')), 'burst fire')
    Err('NpcCombat.firingPattern', 'full_auto', 'err.setting_option', 'there is no full-auto option')
    Err('NpcCombat.accuracyMax', 101, 'err.setting_range', 'accuracy is 0 to 100')
    Err('NpcCombat.shootRate', 1001, 'err.setting_range', 'the shoot rate is 0 to 1000')
    Err('NpcCombat.abilityMax', 3, 'err.setting_range', 'the combat ability is 0 to 2')
    Err('NpcCombat.officerDefense', 0.05, 'err.setting_range', 'the defense modifier is at least 0.1')
    ok, v = Check('NpcCombat.aiDamage', 1)
    H.ok(ok and v == 1.0 and math.type(v) == 'float', 'AI damage 1 is saved as 1.0 (the native reads a float)')
    Err('NpcCombat.weapons', { 'WEAPON_PISTOL', 'WEAPON_SMG' }, 'err.setting_automatic_weapon',
        'an automatic weapon cannot be added to the NPC weapons')
    H.ok((Check('NpcCombat.weapons', { 'WEAPON_PISTOL', 'WEAPON_REVOLVER' })), 'any other weapon may be listed')
    Err('NpcCombat.fallback', 'WEAPON_MINIGUN', 'err.setting_automatic_weapon', 'the fallback is never automatic')
    Err('NpcCombat.replace', { WEAPON_SMG = 'WEAPON_MICROSMG' }, 'err.setting_automatic_weapon',
        'nor a replacement weapon')
    H.ok((Check('NpcCombat.replace', { WEAPON_SMG = 'WEAPON_PISTOL' })), 'a replacement map')
    H.ok((E('NpcCombat.lethalCancelAbove').desc or ''):find('share of his health', 1, true) ~= nil,
        'the health share of the one-shot cancel is listed with its comment')
    H.ok((Check('NpcCombat.lethalCancelAbove', 0.5)), 'half health')
    Err('NpcCombat.lethalCancelAbove', 0.1, 'err.setting_range', 'never below a quarter (officers must go down)')
    Err('NpcCombat.lethalCancelAbove', 1.5, 'err.setting_range', 'never above full health')
    -- the Builder check takes an automatic weapon only while NpcCombat is on: switching it reloads the missions
    H.eq(E('NpcCombat.enabled').reload, true, 'NpcCombat.enabled reloads the missions')
    H.ok(not E('NpcCombat.aiDamage').reload, 'a damage value does not')
    -- Config.Flee (how long fleeing suspects keep running): in Suspect behaviour, with its comments and ranges
    H.eq(E('Flee.sprintSeconds').section, E('NpcCombat.enabled').section, 'Flee is listed under Suspect behaviour')
    -- each description exactly: a comment that continues on the next line must not run into the next key's
    H.eq(E('Flee.enabled').desc, 'false = suspects run as GTA makes them: they never tire', 'the switch')
    H.eq(E('Flee.sprintSeconds').desc, 'seconds a runner sprints before he slows to a jog', 'the sprint time')
    H.eq(E('Flee.jogSeconds').desc, 'seconds he then jogs before he slows to a walk', 'the jog time')
    H.eq(E('Flee.walkSeconds').desc, 'seconds he then walks before he is worn out', 'the walk time')
    local jitterDesc = 'Each suspect lasts up to this share longer or shorter, rolled once per suspect from the run\'s'
        .. ' seed (0.25 = 25 %, 0 = every suspect lasts the same)'
    H.eq(E('Flee.jitter').desc, jitterDesc, 'the jitter')
    local breatherDesc = 'Seconds with no officer within recoverRange before a runner gets his breath back and sprints'
        .. ' again'
    H.eq(E('Flee.recoverSeconds').desc, breatherDesc, 'the breather, without the end of the jitter comment')
    H.eq(E('Flee.recoverRange').desc, 'metres: an officer this close stops a runner from getting his breath back',
        'the breather range reads alone')
    H.eq(E('Flee.armedTire').desc, 'false = a suspect who carries a weapon you can see never tires', 'the armed switch')
    local fleeGroup = nil
    for _, sec in ipairs(S._schema().sections) do
        for _, g in ipairs(sec.groups) do if g.path == 'NpcDifficulty.custom' then fleeGroup = g end end
    end
    H.ok(((fleeGroup or {}).desc or ''):find('fleeMult: how long runners keep running', 1, true) ~= nil,
        'the NpcDifficulty custom group says what fleeMult does')
    H.ok((Check('Flee.sprintSeconds', 15)), 'a 15 s sprint')
    Err('Flee.sprintSeconds', 0, 'err.setting_range', 'a sprint of at least 1 s')
    Err('Flee.jogSeconds', 121, 'err.setting_range', 'at most 120 s')
    Err('Flee.walkSeconds', 0, 'err.setting_range', 'a walk of at least 1 s')
    Err('Flee.recoverSeconds', 500, 'err.setting_range', 'a breather of at most 120 s')
    ok, v = Check('Flee.jitter', 0)
    H.ok(ok and v == 0.0 and math.type(v) == 'float', 'jitter 0: every suspect lasts the same')
    Err('Flee.jitter', 0.6, 'err.setting_range', 'jitter at most 0.5')
    Err('Flee.recoverRange', 5, 'err.setting_range', 'the breather range is at least 10 m')
    H.ok(not E('Flee.enabled').reload and not E('Flee.enabled').restart, 'Flee is read live: no reload, no restart')
    -- how much a tired runner slows down (F2): each comment reads alone, rates 0.5-1.0, live
    H.eq(E('Flee.jogRate').desc, 'a jogging runner\'s speed: 1.0 = a normal jog, 0.9 = 10 % slower (0.5-1.0)',
        'the jog rate')
    H.eq(E('Flee.walkRate').desc, 'a walking or worn-out runner\'s speed: 1.0 = a normal walk (0.5-1.0)',
        'the walk rate')
    H.eq(E('Flee.windedClipset').desc, 'true = a tired runner looks it: he jogs, then walks winded', 'the look')
    ok, v = Check('Flee.jogRate', 1)
    H.ok(ok and v == 1.0 and math.type(v) == 'float', 'a jog rate of 1 is kept as 1.0 (a normal jog)')
    H.ok((Check('Flee.walkRate', 0.5)), 'a walk at half speed')
    Err('Flee.jogRate', 0.4, 'err.setting_range', 'a jog rate of at least 0.5')
    Err('Flee.walkRate', 1.2, 'err.setting_range', 'a walk rate of at most 1.0 (never faster than normal)')
    Err('Flee.windedClipset', 'yes', 'err.setting_type', 'the look is on or off')
    H.ok(not E('Flee.jogRate').reload and not E('Flee.jogRate').restart, 'the rates are read live')
    -- what a worn-out runner does (F3): a pick of three, the range 5-100 m, each comment alone, live
    local exhaustedDesc = 'What a worn-out runner does when an officer comes within giveUpRange: \'surrender\' (he gives'
        .. ' up and kneels), \'handsUp\' (he gives up and stands with his hands up) or \'walk\' (he walks on and never'
        .. ' gives up on his own)'
    H.eq(E('Flee.exhausted').desc, exhaustedDesc, 'the give-up choice, without the end of the windedClipset comment')
    H.eq(E('Flee.exhausted').kind, 'enum', 'the give-up is a pick from its options')
    H.eq(table.concat((E('Flee.exhausted').tpl or {}).options or {}, ','), 'surrender,handsUp,walk',
        'its three options')
    H.ok((Check('Flee.exhausted', 'handsUp')), 'hands up')
    H.ok((Check('Flee.exhausted', 'walk')), 'or he walks on')
    Err('Flee.exhausted', 'run', 'err.setting_option', 'there is no option to keep sprinting')
    Err('Flee.exhausted', 'HANDSUP', 'err.setting_option', 'the option is spelled as listed')
    H.eq(E('Flee.giveUpRange').desc, 'metres: a worn-out runner gives up when an officer is this close (5-100)',
        'the give-up range reads alone')
    ok, v = Check('Flee.giveUpRange', 50)
    H.ok(ok and v == 50.0 and math.type(v) == 'float', 'a 50 m give-up range is kept as 50.0')
    Err('Flee.giveUpRange', 4, 'err.setting_range', 'a give-up range of at least 5 m')
    Err('Flee.giveUpRange', 101, 'err.setting_range', 'and at most 100 m')
    H.ok(not E('Flee.exhausted').reload and not E('Flee.exhausted').restart, 'the give-up rule is read live')
    H.ok(not E('Flee.giveUpRange').reload and not E('Flee.giveUpRange').restart, 'and so is its range')
    -- which escape route a scattering suspect takes (S21): on or off, its comment alone, live
    local routeDesc = 'true = a runner, cook or inmate who scatters (Gang Hideout Raid, Drug Lab Raid, Prison Break)'
        .. ' flees along the escape route that starts nearest where he appears, so nobody runs back across the site'
        .. ' past your officers (routes that start about as near, within 5 m, take turns); false = the routes take'
        .. ' turns wherever he appears'
    H.eq(E('Flee.nearestRoute').desc, routeDesc, 'the route rule, without the end of the give-up range comment')
    H.eq(Config.Flee.nearestRoute, true, 'the route rule ships on')
    Err('Flee.nearestRoute', 'yes', 'err.setting_type', 'the route rule is on or off')
    H.ok(not E('Flee.nearestRoute').reload and not E('Flee.nearestRoute').restart, 'the route rule is read live')
    -- Config.Spawning (the spawn director, S1): its own section after the run limits, each comment alone, the ranges
    H.eq(E('Spawning.enabled').section, 'spawning', 'Spawning has its own section')
    local spawnTitle, spawnGroup = nil, nil
    for _, sec in ipairs(S._schema().sections) do
        if sec.key == 'spawning' then spawnTitle = sec.title end
        for _, g in ipairs(sec.groups) do if g.path == 'Spawning' then spawnGroup = g end end
    end
    H.eq(spawnTitle, 'Spawning (where mission people appear)', 'the section title from its banner')
    H.ok(
        ((spawnGroup or {}).desc or ''):find('never pop up next to, behind or all around your officers', 1, true) ~= nil,
        'the comment under the banner describes the group')
    H.ok(E('Limits.reserveLocations').section ~= 'spawning', 'the run limits stay in their own section')
    H.eq(
        E('Spawning.enabled').desc,
        'false = people appear at the mission\'s points as before (no rule below is used; only the spawn point check,'
            .. ' which you start yourself, still judges points by ground)',
        'the switch (the ground rules still judge points for the spawn point check)'
    )
    H.eq(
        E('Spawning.activateRange').desc,
        'Metres: an objective\'s people appear once an officer is this close to them (50-400, well inside the 424 m a'
            .. ' player\'s game can see)',
        'the activate range'
    )
    H.eq(E('Spawning.minDistance').desc, 'metres: a point closer than this to any officer is never used',
        'the distance, without the activate range comment above it')
    H.eq(E('Spawning.minDistanceIndoor').desc,
        'Metres: a point inside a building (walls hide it) closer than this to any officer is never used',
        'the indoor distance reads alone')
    H.eq(
        E('Spawning.behindAngle').desc,
        'Degrees: a point further than this off an officer\'s line to the scene (from where he stands towards the'
            .. ' mission\'s points, whichever side he came in from) is behind him and never used. Only officers within'
            .. ' activateRange of the point count (180 = off)',
        'behind'
    )
    H.eq(
        E('Spawning.maxSpread').desc,
        'Degrees: all points of one wave fit in a slice this wide seen from the officers, so a wave never comes from'
            .. ' every side at once (360 = off)',
        'the slice'
    )
    H.eq(E('Spawning.waveDelayMax').desc,
        'seconds a wave waits for points minDistance away before closer ones are allowed', 'the wait')
    H.eq(E('Spawning.hardMin').desc,
        'Metres: once a wave has waited waveDelayMax, a point this close to an officer may be used, never a closer one',
        'the closest after the wait, without the wait comment')
    H.eq(
        E('Spawning.leaveOutAfter').desc,
        'Seconds a wave of hostiles, a warrant\'s associates or a scatter\'s suspects (Prison Break\'s inmates, the'
            .. ' raids\' cooks and runners) may stay short of points (every point too close to or behind the officers,'
            .. ' or a cuffed suspect still stands on it), counted from when they first had to wait. Once that time has'
            .. ' passed, someone of the fight or objective has appeared and nobody of it is left to fight or catch, the'
            .. ' ones that could not be placed are left out, so it can end (0 = never: they wait until the officers move'
            .. ' away)',
        'the leave-out wait (S2), alone: its clock starts at the first wait, and it covers warrants and scatters (S11)'
    )
    local hidden = E('Spawning.preferHidden').desc
    H.ok(hidden:find('or in sight at hardMin or further once it has waited waveDelayMax', 1, true) ~= nil,
        'a Manhunt clue may appear in sight at hardMin after waveDelayMax (S16 check)')
    H.ok(
        hidden:find('such a clue waits until the officers are minDistance away, or hardMin after waveDelayMax', 1, true)
            ~= nil,
        'and with preferHidden off too'
    )
    H.eq(
        E('Spawning.stageAhead').desc,
        'true = a mission may place the next objective\'s people ahead of time, while your officers are still busy'
            .. ' with the one before it, so they are already there when it starts instead of popping up around the'
            .. ' officers (false = they appear only when their objective starts, as before)',
        'staging ahead (S3), alone'
    )
    H.eq(E('Spawning.stageAhead').section, 'spawning', 'staging ahead is in the Spawning section')
    H.ok((Check('Spawning.stageAhead', false)), 'staging ahead can be switched off')
    Err('Spawning.stageAhead', 'yes', 'err.setting_type', 'staging ahead is on or off')
    H.eq(
        E('Spawning.stageWakeRange').desc,
        'Metres: a raid\'s crew waiting in place before the breach stays calm until an officer comes this close to one'
            .. ' of them (officers nearer to the breach entries than to him do not count) or hurts one; then they all'
            .. ' wake and fight at once (0 = only a hurt one wakes them). They always wake when the fight starts',
        'the wake range of a staged crew (S4), alone'
    )
    H.eq(E('Spawning.stageWakeRange').section, 'spawning', 'the wake range is in the Spawning section')
    H.ok((Check('Spawning.stageWakeRange', 0)), 'stageWakeRange 0 (only a hurt one wakes them)')
    ok, v = Check('Spawning.stageWakeRange', 50)
    H.ok(ok and v == 50.0, 'stageWakeRange up to 50 m')
    Err('Spawning.stageWakeRange', 51, 'err.setting_range', 'stageWakeRange at most 50 m')
    Err('Spawning.stageWakeRange', -1, 'err.setting_range', 'and never below 0')
    H.eq(
        E('Spawning.log').desc,
        'true = a console line for each point skipped (shown while Config.Debug is on) and a warning when a wave had'
            .. ' to use closer points',
        'the console lines'
    )
    ok, v = Check('Spawning.activateRange', 400)
    H.ok(ok and v == 400.0, 'activateRange up to 400 m')
    Err('Spawning.activateRange', 425, 'err.setting_range', 'never past what a player\'s game can see (424 m)')
    Err('Spawning.activateRange', 40, 'err.setting_range', 'at least 50 m')
    H.ok((Check('Spawning.minDistance', 0)), 'a distance of 0 m (off)')
    Err('Spawning.minDistance', 201, 'err.setting_range', 'at most 200 m')
    Err('Spawning.minDistanceIndoor', -1, 'err.setting_range', 'never below 0')
    Err('Spawning.hardMin', 250, 'err.setting_range', 'hardMin at most 200 m')
    H.ok((Check('Spawning.behindAngle', 180)), 'behindAngle 180 (off)')
    Err('Spawning.behindAngle', 30, 'err.setting_range', 'behind is at least 45 degrees off the line to the scene')
    Err('Spawning.behindAngle', 190, 'err.setting_range', 'and at most 180')
    H.ok((Check('Spawning.maxSpread', 360)), 'maxSpread 360 (off)')
    Err('Spawning.maxSpread', 361, 'err.setting_range', 'a slice of at most 360 degrees')
    Err('Spawning.maxSpread', 20, 'err.setting_range', 'and at least 45')
    H.ok((Check('Spawning.waveDelayMax', 0)), 'a wave that never waits')
    Err('Spawning.waveDelayMax', 301, 'err.setting_range', 'a wait of at most 300 s')
    H.ok((Check('Spawning.leaveOutAfter', 0)), 'leaveOutAfter 0 (never leave anyone out)')
    ok, v = Check('Spawning.leaveOutAfter', 600)
    H.ok(ok and v == 600, 'leaveOutAfter up to 600 s')
    Err('Spawning.leaveOutAfter', 601, 'err.setting_range', 'leaveOutAfter at most 600 s')
    Err('Spawning.leaveOutAfter', -1, 'err.setting_range', 'and never below 0')
    Err('Spawning.log', 'yes', 'err.setting_type', 'the console lines are on or off')
    for _, k in ipairs({
        'enabled',
        'activateRange',
        'minDistance',
        'behindAngle',
        'maxSpread',
        'hardMin',
        'leaveOutAfter',
        'stageAhead',
        'stageWakeRange',
        'log',
    }) do
        H.ok(not E('Spawning.' .. k).reload and not E('Spawning.' .. k).restart, 'read live: Spawning.' .. k)
    end
    -- Config.Spawning.ground and the load waits (the ground probe, S6): ranges of two numbers, each comment alone
    H.eq(E('Spawning.ground.pedAbove').kind, 'range', 'a person\'s height range edits as a lowest and a highest')
    H.eq(E('Spawning.ground.pedAbove').size, 2, 'two numbers')
    H.eq(E('Spawning.ground.pedAbove').section, 'spawning', 'in the Spawning section')
    H.eq(
        E('Spawning.ground.pedAbove').desc,
        'Metres, lowest and highest: a person\'s point fits from 0.3 m under to 1.6 m over the ground (a standing'
            .. ' person\'s point is about 1 m over it)',
        'the person\'s range reads alone'
    )
    H.eq(E('Spawning.ground.vehicleAbove').desc, 'metres, lowest and highest: the same for a vehicle\'s point',
        'the vehicle\'s range')
    H.eq(E('Spawning.ground.propAbove').desc,
        'metres, lowest and highest: the same for an object\'s point (a clue, a stash)', 'the object\'s range')
    H.eq(
        E('Spawning.ground.snapWithin').desc,
        'Metres (0-10): a point outside its range is put on the ground when that moves it at most this far up or'
            .. ' down; one further off is reported as under the ground or floating',
        'snapWithin reads alone'
    )
    H.eq(E('Spawning.collisionTimeoutMs').desc,
        'Milliseconds (500-30000) a game waits for the ground around a point to load before it checks the point',
        'the collision wait')
    H.eq(
        E('Spawning.interiorTimeoutMs').desc,
        'Milliseconds (500-30000) a game waits for the inside of a building (a bank, a store) to load; still not'
            .. ' loaded after this = the point is reported as "inside not loaded"',
        'the interior wait'
    )
    ok, v = Check('Spawning.ground.pedAbove', { -0.5, 2 })
    H.ok(ok and v[1] == -0.5 and v[2] == 2.0 and math.type(v[2]) == 'float', 'a person\'s range of -0.5 to 2 m')
    Err('Spawning.ground.pedAbove', { 2, 1 }, 'err.setting_min_max', 'the lowest is not over the highest')
    Err('Spawning.ground.vehicleAbove', { 0.5 }, 'err.setting_list', 'a range keeps its two numbers')
    Err('Spawning.ground.propAbove', { 'a', 1 }, 'err.setting_number', 'numbers only')
    H.ok((Check('Spawning.ground.snapWithin', 0)), 'snapWithin 0 (never move a point)')
    ok, v = Check('Spawning.ground.snapWithin', 10)
    H.ok(ok and v == 10.0, 'snapWithin up to 10 m')
    Err('Spawning.ground.snapWithin', 11, 'err.setting_range', 'snapWithin at most 10 m')
    Err('Spawning.ground.snapWithin', -1, 'err.setting_range', 'and never below 0')
    H.ok((Check('Spawning.collisionTimeoutMs', 500)), 'a collision wait of 500 ms')
    Err('Spawning.collisionTimeoutMs', 499, 'err.setting_range', 'at least 500 ms')
    Err('Spawning.collisionTimeoutMs', 30001, 'err.setting_range', 'at most 30 s')
    Err('Spawning.interiorTimeoutMs', 1.5e3 + 0.5, 'err.setting_whole', 'whole milliseconds')
    Err('Spawning.interiorTimeoutMs', 30001, 'err.setting_range', 'an interior wait of at most 30 s')
    -- Config.Spawning.place (the placer, S9): on or off, its comment alone
    H.eq(
        E('Spawning.place').desc,
        'true = every new person, vehicle and object of a mission waits frozen where it appears until the game of an'
            .. ' officer near it has checked the ground there and put it on the ground (by the ranges above); a point'
            .. ' under the ground, floating, in water or in a wall is reported back instead and another of the'
            .. ' mission\'s points is tried. false = they appear on the file\'s points as before',
        'the placer reads alone'
    )
    H.eq(E('Spawning.place').section, 'spawning', 'the placer is in the Spawning section')
    H.ok((Check('Spawning.place', false)), 'the placer can be switched off')
    Err('Spawning.place', 'yes', 'err.setting_type', 'the placer is on or off')
    -- the server's side of it (S10): how long an entity waits, how many other points, what a timeout does
    H.eq(
        E('Spawning.placeTimeoutMs').desc,
        'Milliseconds (1000-60000) a new person, vehicle or object waits frozen for an officer\'s game to put it on'
            .. ' the ground, counted while an officer is within activateRange of it and no officer\'s game is checking'
            .. ' it (a big wave\'s later ones wait their turn there, at most 34 s plus collisionTimeoutMs and'
            .. ' interiorTimeoutMs); then onTimeout',
        'the wait reads alone'
    )
    H.eq(
        E('Spawning.retries').desc,
        'How many times (0-5) a point an officer\'s game reports bad (under the ground, floating, in water, in a'
            .. ' wall) is swapped for another point the mission may use there; after that, or with no other point, the'
            .. ' last one is used as it is (one warning in the console)',
        'the retries read alone'
    )
    H.eq(
        E('Spawning.onTimeout').desc,
        '\'unfreeze\' = a person, vehicle or object that no officer\'s game has put on the ground within'
            .. ' placeTimeoutMs is let go where it stands, as before; \'delete\' = it is removed and the mission treats'
            .. ' it as killed (a hostage or an escort\'s truck removed this way fails that objective). A person or'
            .. ' vehicle the mission only moved, such as a warrant\'s suspect who gives up at the door or the prisoner'
            .. ' transport put on its parking point, is always let go where it stands',
        'the timeout choice reads alone: delete counts as killed and can fail the objective (S10 check)'
    )
    for _, k in ipairs({ 'placeTimeoutMs', 'retries', 'onTimeout' }) do
        H.eq(E('Spawning.' .. k).section, 'spawning', 'in the Spawning section: ' .. k)
    end
    H.eq(Config.Spawning.placeTimeoutMs, 8000, 'an entity waits 8 s while an officer is near')
    H.eq(Config.Spawning.retries, 2, 'two other points after a bad one')
    H.eq(Config.Spawning.onTimeout, 'unfreeze', 'then let go where it stands (as before)')
    H.ok((Check('Spawning.placeTimeoutMs', 1000)), 'placeTimeoutMs 1000 ms')
    H.ok((Check('Spawning.placeTimeoutMs', 60000)), 'placeTimeoutMs 60000 ms')
    Err('Spawning.placeTimeoutMs', 999, 'err.setting_range', 'placeTimeoutMs at least 1000 ms')
    Err('Spawning.placeTimeoutMs', 60001, 'err.setting_range', 'placeTimeoutMs at most 60000 ms')
    H.ok((Check('Spawning.retries', 0)), 'retries 0 (the first point only)')
    Err('Spawning.retries', 6, 'err.setting_range', 'retries at most 5')
    Err('Spawning.retries', -1, 'err.setting_range', 'retries never below 0')
    H.ok((Check('Spawning.onTimeout', 'delete')), 'onTimeout delete')
    H.ok((Check('Spawning.onTimeout', 'unfreeze')), 'onTimeout unfreeze')
    H.eq(E('Spawning.onTimeout').kind, 'enum', 'the timeout choice is a pick from its options')
    Err('Spawning.onTimeout', 'keep', 'err.setting_option', 'onTimeout is unfreeze or delete')
    for _, k in ipairs({
        'place',
        'placeTimeoutMs',
        'retries',
        'onTimeout',
        'ground.pedAbove',
        'ground.vehicleAbove',
        'ground.propAbove',
        'ground.snapWithin',
        'collisionTimeoutMs',
        'interiorTimeoutMs',
    }) do
        H.ok(not E('Spawning.' .. k).reload and not E('Spawning.' .. k).restart, 'read live: Spawning.' .. k)
    end
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
    -- K22: the test panel key is a key setting like Tablet.keybind (read once at start)
    H.eq((S.entry('Testing.panelKey') or {}).restart, true, 'K22: Testing.panelKey is a restart setting')
    Err('Testing.panelKey', 'F7 ;', 'err.setting_text', 'K22: a test panel key with a space and a ;')
    ok, v = Check('Testing.panelKey', 'F6')
    H.ok(ok and v == 'F6', 'K22: a test panel key')

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
    -- FXServer cannot create folders on Linux: a folder the Builder cannot write yet is refused (the Builder's own
    -- check, tests/builder_server_spec.lua, is stood in for here)
    local savedBuilder = CP.Builder
    CP.Builder = {
        missingExportDirs = function(p) return p == 'missions/custom/server/' and { p } or {} end,
    }
    Err('Builder.exportPath', 'missions/custom/server/', 'err.setting_export_folder',
        'a folder that is not there yet is refused')
    H.ok((Check('Builder.exportPath', 'missions/custom/')), 'the shipped folder is fine')
    H.eq(
        S.entry('Builder.exportPath').desc,
        'folder (inside missions/custom/) for missions made in the Builder. Another folder must be created by hand'
            .. ' first, with archived, overrides, overrides/archived and deleted inside it (the server cannot create'
            .. ' folders on Linux)',
        'the export folder says a new one must be made by hand first (X3)'
    )
    CP.Builder = savedBuilder
    Err('Profile.bannedWordsFile', '../server.cfg', 'err.setting_text', 'the banned-words file is a .txt')
    H.ok((Check('Profile.bannedWordsFile', false)), 'no banned-words file')
end

-- Config.Markers (PLAN M1, BLIPS_FINAL section 4): its own section, each comment alone, the limits, read live.
do
    local function E(p) return S.entry(p) or {} end
    H.ok(E('Markers.enabled').section ~= E('Route.reportEvery').section, 'Map markers is a section of its own')
    H.eq(E('Markers.routeColour').desc, 'colour of the GPS line to an objective (5 = yellow, 1 = red, 3 = blue)',
        'the line colour')
    H.ok(
        E('Markers.radioSilence').desc:find('\'area\' = each objective\'s circle or its one blip stays', 1, true) ~= nil
            and E('Markers.radioSilence').desc:find('always show', 1, true) ~= nil,
        'Radio Silence says what each mode hides (and what always shows)'
    )
    H.eq(E('Markers.radioSilence').kind, 'enum', 'Radio Silence is a pick of three')
    H.ok((Check('Markers.radioSilence', 'none')), 'none: hide everything, as before')
    Err('Markers.radioSilence', 'loud', 'err.setting_option', 'only none, area or full')
    -- V2: the stun proof is a pick of four, shipped 'flag'; the AI damage re-apply is an on/off switch
    local stun = E('AntiCheat.stunNeedsProof')
    H.eq(stun.kind, 'enum', 'stunNeedsProof is a pick')
    H.eq(stun.default, 'flag', 'stunNeedsProof ships flag')
    H.ok(
        stun.desc and stun.desc:find('nobody\'s points are held', 1, true) ~= nil
            and stun.desc:find('\'strict\' = a fleeing person only gives up to a stun the', 1, true) ~= nil
            and stun.desc:find('\'off\' = no check (the old way)', 1, true) ~= nil,
        'stunNeedsProof says what each choice does: ' .. tostring(stun.desc)
    )
    for _, v in ipairs({ 'flag', 'hold', 'strict', 'off' }) do
        H.ok((Check('AntiCheat.stunNeedsProof', v)), 'stun ' .. v)
    end
    Err('AntiCheat.stunNeedsProof', 'loud', 'err.setting_option', 'only flag, hold, strict or off')
    local okT, cleanT = Check('AntiCheat.stunNeedsProof', true)
    H.ok(okT and cleanT == 'strict', 'a true from before it was a choice reads as strict')
    local okF, cleanF = Check('AntiCheat.stunNeedsProof', false)
    H.ok(okF and cleanF == 'off', 'a false reads as off')
    local re = E('NpcCombat.reassertAiDamage')
    H.eq(re.kind, 'boolean', 'reassertAiDamage is an on/off switch')
    H.eq(re.default, true, 'reassertAiDamage ships true')
    H.ok(re.desc and re.desc:find('false = set once at the start (the old way)', 1, true) ~= nil,
        'reassertAiDamage says what off does: ' .. tostring(re.desc))
    H.eq(S.entry('NpcCombat.holdAiDamage'), nil, 'its old name is no setting any more')
    H.ok((Check('Markers.routeColour', 85)), 'colour 85')
    Err('Markers.routeColour', 86, 'err.setting_range', 'blip colours stop at 85')
    Err('Markers.trackEvery', 0, 'err.setting_range', 'positions at least every second')
    Err('Markers.trackEvery', 11, 'err.setting_range', 'and at most every 10 s')
    Err('Markers.routeOffWithin', 201, 'err.setting_range', 'the line turns off within 200 m at most')
    Err('Markers.flashSeconds', 31, 'err.setting_range', 'a flash of 30 s at most')
    Err('Markers.category', 3, 'err.setting_range', 'legend category 1 or 2')
    Err('Markers.areaAlpha', 256, 'err.setting_range', 'alpha 0-255')
    Err('Markers.startCircleMin', 40, 'err.setting_range', 'a start circle from 50 m')
    Err('Markers.radioSilenceLastKnown', 61, 'err.setting_range', 'a last-known circle moved at most every 60 s')
    H.ok((Check('Markers.kinds.fightArea.sprite', 310)), 'any sprite of the blip list')
    Err('Markers.kinds.fightArea.sprite', 966, 'err.setting_range', 'sprites stop at 965')
    Err('Markers.kinds.fightArea.sprite', 84.5, 'err.setting_whole', 'a sprite is a whole number')
    Err('Markers.kinds.hostile.bossScale', 2.5, 'err.setting_range', 'a size of 2.0 at most')
    H.ok((Check('Markers.kinds.suspect.surrenderedScale', 0.5)), 'the size of a suspect who gave up (R6)')
    -- (R6) the time a late partner gets to reach the action
    H.ok((Check('Route.followActionSeconds', 0)), 'followActionSeconds 0: the start deadline he had, as before')
    Err('Route.followActionSeconds', 1801, 'err.setting_range', 'at most 30 minutes to reach the action')
    H.ok(E('Route.followActionSeconds').desc:find('0 = he keeps the start deadline, as before', 1, true) ~= nil,
        'followActionSeconds: its config.lua comment is its description')
    Err('Markers.kinds.suspect.surrenderedScale', 0.2, 'err.setting_range', 'a surrendered size of 0.3 at least')
    Err('Markers.kinds.point.followUpColour', 90, 'err.setting_range', 'the follow-up colour is a blip colour')
    local escort = nil
    for _, sec in ipairs(S._schema().sections) do
        for _, g in ipairs(sec.groups) do if g.path == 'Markers.kinds.escort' then escort = g end end
    end
    H.eq((escort or {}).desc, 'the vehicle you escort', 'each kind says what it is')
    local suspect = nil
    for _, sec in ipairs(S._schema().sections) do
        for _, g in ipairs(sec.groups) do if g.path == 'Markers.kinds.suspect' then suspect = g end end
    end
    H.eq((suspect or {}).desc, 'a suspect: stopped or armed (surrenderedScale: one who gave up)',
        'the suspect kind names its surrenderedScale')
    -- the kinds fields (sprite, colour, scale, ...) have no comment of their own: the Markers group says what they are
    local markers = nil
    for _, sec in ipairs(S._schema().sections) do
        for _, g in ipairs(sec.groups) do if g.path == 'Markers' then markers = g end end
    end
    local legend = (markers or {}).desc or ''
    H.ok(legend:find(
        'each kind of blip has a sprite (the blip\'s picture, by its id), a colour (a colour id: 5 ='
            .. ' yellow, go here; 1 = red, enemy; 17 = orange',
        1,
        true
    ) ~= nil, 'the Markers group explains sprite and colour')
    H.ok(legend:find('and a scale (its size, 1.0 = normal)', 1, true) ~= nil, 'and scale')
    H.ok(legend:find('nextScale, bossScale, surrenderedScale, followUpColour and setbackColour', 1, true) ~= nil,
        'and the extra fields')
    H.ok(legend:find('a suspect who gave up (the same size near you and far away)', 1, true) ~= nil,
        'surrenderedScale: one size near and far (R6)')
    H.ok(not E('Markers.enabled').reload and not E('Markers.enabled').restart, 'read live: no reload, no restart')
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
        ('Limits.maxUnitSize', '{"v": "lots"}', 'SET00001'), ('Old.removed', '{"v": 1}', 'SET00001'),
        ('AntiCheat.stunNeedsProof', '{"v": true}', 'SET00001')]])
    H.restart()
    lines = {}
    S = Boot()
    -- a stunNeedsProof saved as true (PF1, before it was a choice) is the strict proof now, not an ignored value
    H.eq(Config.AntiCheat.stunNeedsProof, 'strict', 'a saved true reads as strict after a restart')
    H.eq(S.view('AntiCheat.stunNeedsProof').invalid, nil, 'and is not shown as ignored')
    H.ok(not Printed('the saved setting AntiCheat.stunNeedsProof was ignored'), 'no ignored-setting line for it')
    H.sql('UPDATE cp_settings SET value_json = \'{"v": false}\' WHERE setting_key = \'AntiCheat.stunNeedsProof\'')
    H.restart()
    lines = {}
    S = Boot()
    H.eq(Config.AntiCheat.stunNeedsProof, 'off', 'a saved false reads as off')
    H.sql('DELETE FROM cp_settings WHERE setting_key = \'AntiCheat.stunNeedsProof\'')
    H.restart()
    lines = {}
    S = Boot()
    H.eq(Config.AntiCheat.stunNeedsProof, 'flag', 'nothing saved: config.lua\'s flag')
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

    -- a renamed location keeps its old label in aliases: a switch saved by it still matches (step L4)
    local renamed = U.deepcopy(def)
    renamed.locations[2].aliases = { 'An old label' }
    H.ok(S._locationOff({ 'An old label' }, renamed, 2), 'a switch saved by the old label turns it off')
    H.ok(not S._locationOff({ 'An old label' }, renamed, 1), 'and no other location')

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
