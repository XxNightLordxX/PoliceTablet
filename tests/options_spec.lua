-- Officer options (shared/options.lua CP.OptionDefs, modules/options CP.Options): the rules, saving per character
-- (sparse JSON in cp_officers.options), getOptions and server:options:set, and what the tablet session carries.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
local cjson = require('cjson')

-- ============================================================================
--                         DEPARTMENTS, OFFICERS, STUBS
-- ============================================================================

local officers = {
    [1] = { dept = 'sast', cid = 'OPT00001' },
    [2] = { dept = 'fib', cid = 'OPT00002' },
    [3] = { dept = 'sast', cid = 'OPT00003' },
}
CP.Access = {
    getOfficer = function(src)
        local o = officers[src]
        if not o then return nil, 'err.not_police' end
        return {
            src = src,
            citizenid = o.cid,
            name = 'Officer ' .. src,
            department = o.dept,
            departmentLabel = o.dept:upper(),
            departmentShort = o.dept:upper(),
            rank = 'Trooper',
            callsign = 'C-' .. src,
            gradeLevel = 1,
            isSupervisor = false,
        }
    end,
    isAdmin = function() return false end,
    department = function(key) return { key = key, theme = { primary = '#1f4e8c' } } end,
    departments = function()
        return {
            { key = 'sast', label = 'SAST', short = 'SAST', theme = { primary = '#1f4e8c' } },
            { key = 'fib', label = 'FIB', short = 'FIB', theme = { primary = '#1c2541' } },
        }
    end,
    refreshOfficerRow = function() end,
}
CP.Permissions = {
    can = function() return false end,
    actionsFor = function() return {} end,
}
CP.Alerts = {
    inArena = function() return false end,
}
Config.Tablet.item = false
Config.Tablet.access = { command = true, keybind = true, item = true, desk = true, requireItem = false }
for src in pairs(officers) do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end

Config.Departments.sast = Config.Departments.sast or { label = 'SAST', jobs = { 'sast' } }
Config.Departments.fib = Config.Departments.fib or { label = 'FIB', jobs = { 'fib' } }

H.load('modules/tablet/server.lua')
H.load('modules/options/server.lua')
local Defs, Options = CP.OptionDefs, CP.Options

-- Four test options, one of each kind, saved on the server; one kept by the tablet only.
local types = { 'patrol', 'traffic', 'warrant' }
Defs.add('t_bool', { kind = 'bool', default = false, group = 'test', order = 1 })
Defs.add('t_enum', { kind = 'enum', values = { 'small', 'medium', 'large' }, default = 'medium', group = 'test' })
Defs.add('t_list', {
    kind = 'list',
    values = function() return types end,
    default = {},
    group = 'test',
})
Defs.add('t_num', { kind = 'number', min = 0, max = 100, integer = true, default = 50, group = 'test' })
Defs.add('t_local', { kind = 'bool', default = true, store = 'local', group = 'test' })

local function Tick() H.clockMs = H.clockMs + 1100 end
local function Cb(name, src, args)
    Tick()
    return H.callback('crimson-police:' .. name, src, args)
end
local function Act(src, payload)
    Tick()
    H.reset()
    H.fire('crimson-police:server:options:set', src, payload, 'rq')
    local ev = H.findEvents('crimson-police:client:actionResult')[1]
    if not ev then return nil, 'no reply' end
    return ev.args[2], ev.args[3]
end
local function Pushes()
    local out = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:push')) do
        if e.args[1] == 'options' then out[#out + 1] = e end
    end
    return out
end
local function Saved(cid)
    local r = H.sql('SELECT options FROM cp_officers WHERE citizenid = ?', { cid })[1]
    if not r or r.options == nil or r.options == cjson.null then return nil end
    return cjson.decode(r.options)
end

H.sql('DELETE FROM cp_officers WHERE citizenid LIKE \'OPT%\'')

-- ============================================================================
--                         1. THE RULES (CP.OptionDefs)
-- ============================================================================

do
    H.eq(Defs.check('t_num', 250), 100, 'a number above the option\'s max is clamped')
    H.eq(Defs.check('t_num', 10, { 20, 80 }), 20, 'and to the bounds an owner set')
    H.eq(Defs.check('t_num', 33.4), 33, 'an integer option rounds')
    H.eq(select(2, Defs.check('t_num', 'x')), 'err.option_value', 'a text is not a number')
    H.eq(select(2, Defs.check('t_enum', 'huge')), 'err.option_value', 'an enum takes its values only')
    H.eq(select(2, Defs.check('t_bool', 1)), 'err.option_value', 'a bool takes true or false only')
    H.eq(cjson.encode(Defs.check('t_list', { 'traffic', 'traffic', 'patrol' })), '["traffic","patrol"]',
        'a list is de-duplicated')
    H.eq(select(2, Defs.check('t_list', { 'nope' })), 'err.option_value', 'a list takes offered values only')
    H.eq(select(2, Defs.check('t_nope', true)), 'err.invalid_payload', 'an unknown key')
    H.eq(Defs.checkConfig({ allow = { t_nope = false } }), 'err.option_config', 'a config of an unknown key')
    H.eq(Defs.checkConfig({ defaults = { t_enum = 'huge' } }), 'err.option_config', 'a config with a bad default')
    H.eq(Defs.checkConfig({ bounds = { t_bool = { 0, 1 } } }), 'err.option_config', 'bounds on a non-number')
    H.eq(Defs.checkConfig({ allow = { t_bool = false }, bounds = { t_num = { 10, 20 } } }), nil, 'a good config')
end

-- ============================================================================
--                  2. A FRESH OFFICER, SAVING, THE SPARSE ROW
-- ============================================================================

do
    local res = Cb('getOptions', 1)
    H.ok(res and res.ok, 'getOptions answers an officer')
    local v = res.data.values
    H.ok(v.t_bool == false and v.t_enum == 'medium' and #v.t_list == 0 and v.t_num == 50,
        'a fresh officer gets the defaults')
    H.eq(v.t_local, nil, 'a local option is not a server value')
    H.eq(res.data.enabled, true, 'officer options ship on')
    local keys = {}
    for _, s in ipairs(res.data.schema) do keys[s.key] = s end
    H.ok(keys.t_bool and keys.t_enum and keys.t_list and keys.t_num and keys.t_local, 'the schema lists every option')
    H.eq(cjson.encode(keys.t_list.values), '["patrol","traffic","warrant"]', 'with the values offered now')
    H.eq(keys.t_num.bounds.max, 100, 'and a number\'s bounds')
    H.eq(Cb('getOptions', 9).error, 'err.not_police', 'not police: refused')

    local ok, data = Act(1, { t_bool = true, t_enum = 'large', t_list = { 'warrant' }, t_num = 70 })
    H.eq(ok, true, 'server:options:set saves')
    H.eq(data.values.t_enum, 'large', 'and answers the values')
    local pushes = Pushes()
    H.ok(#pushes == 1 and pushes[1].target == 1, 'the push \'options\' goes to the officer only')
    v = Cb('getOptions', 1).data.values
    H.ok(v.t_bool == true and v.t_enum == 'large' and v.t_list[1] == 'warrant' and v.t_num == 70,
        'set -> getOptions round trip')
    H.eq(Cb('getOptions', 3).data.values.t_enum, 'medium', 'another officer keeps the defaults')

    H.eq((Act(1, { t_enum = 'medium', t_num = 50 })), true, 'setting the default values')
    local saved = Saved('OPT00001')
    H.ok(saved and saved.t_enum == nil and saved.t_num == nil and saved.t_bool == true,
        'a value equal to the default removes its key (sparse row)')
    Act(1, { t_bool = false, t_list = {} })
    H.eq(Saved('OPT00001'), nil, 'all defaults again: the row keeps NULL')

    H.eq(select(2, Act(1, { t_nope = true })), 'err.invalid_payload', 'an unknown key is refused')
    H.eq(select(2, Act(1, { t_local = false })), 'err.invalid_payload', 'a local key is refused')
    H.eq(select(2, Act(1, { t_bool = 'yes' })), 'err.option_value', 'a wrong type is refused')
    H.eq(select(2, Act(1, 'x')), 'err.invalid_payload', 'a payload that is not a table')
    H.eq(select(2, Act(9, { t_bool = true })), 'err.not_police', 'not police: refused')
    Act(1, { t_num = 500 })
    H.eq(Saved('OPT00001').t_num, 100, 'numbers are clamped to bounds')
end

-- ============================================================================
--                 3. LOCKS, DEPARTMENTS, VALUES THAT WENT AWAY
-- ============================================================================

do
    Act(3, { t_enum = 'small', t_list = { 'traffic', 'warrant' } })
    Config.OfficerOptions.allow = { t_enum = false }
    H.eq(select(2, Act(3, { t_enum = 'large' })), 'err.option_locked', 'allow = false refuses a change')
    local v = Cb('getOptions', 3).data
    H.eq(v.values.t_enum, 'medium', 'and ignores the saved value')
    local listed = false
    for _, s in ipairs(v.schema) do listed = listed or s.key == 't_enum' end
    H.eq(listed, false, 'a locked option is left out of the schema')
    H.eq(Saved('OPT00003').t_enum, 'small', 'the saved value is kept')
    Config.OfficerOptions.allow = {}
    H.eq(Cb('getOptions', 3).data.values.t_enum, 'small', 'allowing it again brings it back')

    Config.OfficerOptions.defaults = { t_enum = 'small', t_num = 40 }
    Config.OfficerOptions.bounds = { t_num = { 30, 60 } }
    Config.Departments.fib.officerOptions = { defaults = { t_enum = 'large' }, bounds = { t_num = { 0, 20 } } }
    local fib = Cb('getOptions', 2).data.values
    H.eq(fib.t_enum, 'large', 'the department override wins over the global one')
    H.eq(fib.t_num, 20, 'a default is clamped to the department bounds')
    H.eq(Cb('getOptions', 1).data.values.t_num, 60, 'a saved number outside the bounds now is clamped')
    local _, got = Act(2, { t_num = 90 })
    H.eq(got and got.values.t_num, 20, 'the department bounds clamp a new value')
    H.eq(Saved('OPT00002'), nil, 'clamped to the default: nothing is saved')
    Config.Departments.fib.officerOptions = { allow = { t_bool = false } }
    H.eq(select(2, Act(2, { t_bool = true })), 'err.option_locked', 'a department can lock an option')
    H.eq((Act(1, { t_bool = true })), true, 'for its officers only')
    Config.Departments.fib.officerOptions = nil
    Config.OfficerOptions.defaults, Config.OfficerOptions.bounds = {}, {}

    types = { 'patrol', 'traffic' }
    H.eq(cjson.encode(Cb('getOptions', 3).data.values.t_list), '["traffic"]',
        'a list value that no longer exists is dropped')

    Config.OfficerOptions.enabled = false
    H.eq(select(2, Act(3, { t_bool = true })), 'err.option_locked', 'enabled = false refuses every change')
    H.eq(Cb('getOptions', 3).data.values.t_enum, 'medium', 'and everyone gets the defaults')
    Config.OfficerOptions.enabled = true
end

-- ============================================================================
--                                4. THE SESSION
-- ============================================================================

do
    local res = Cb('getSession', 3, { ui = 'officer', via = 'command' })
    H.ok(res and res.ok, 'the officer session opens')
    H.eq(res.data.options and res.data.options.t_enum, 'small', 'the session carries the effective options')
    H.eq(res.data.options.t_local, nil, 'server options only')
    local oo = res.data.config.officerOptions
    H.ok(
        oo and oo.enabled == true and oo.allow.t_num == true and oo.defaults.t_enum == 'medium'
            and oo.bounds.t_num.max == 100,
        'and config.officerOptions for the department'
    )
    Config.Departments.fib.officerOptions = { allow = { t_num = false } }
    H.eq(Cb('getSession', 2, { ui = 'officer', via = 'command' }).data.config.officerOptions.allow.t_num, false,
        'resolved for the officer\'s department')
    Config.Departments.fib.officerOptions = nil
    H.eq(Options.effective('OPT00003', 'sast', false).t_enum, 'medium', 'raw false: no row, the defaults')
end

-- Easier to read (shared/options_look.lua, step O5): saved with the character, normal or large text only.
do
    local v = Cb('getOptions', 1).data.values
    H.ok(v.hudLook == false and v.textSize == 'normal', 'the look options ship as today: department theme, normal text')
    local ok, data = Act(1, { hudLook = true, textSize = 'large' })
    H.ok(ok == true and data.values.hudLook == true and data.values.textSize == 'large', 'large text and the HUD look')
    H.ok(Saved('OPT00001').textSize == 'large' and Saved('OPT00001').hudLook == true, '...saved with the character')
    H.eq(select(2, Act(1, { textSize = 'huge' })), 'err.option_value', 'the text size is normal or large only')
    H.eq(select(2, Act(1, { textSize = 1.15 })), 'err.option_value', 'a number is not a text size')
    Act(1, { hudLook = false, textSize = 'normal' })
end

-- Mission Board (shared/options_board.lua, step O8): favourite and hidden types (the Config.MissionTypes keys, asked
-- at every call) and accept in one click, saved with the character; never every type hidden.
do
    local v = Cb('getOptions', 1).data.values
    H.ok(#v.favouriteTypes == 0 and #v.hiddenTypes == 0 and v.skipAcceptConfirm == false,
        'the board options ship as today: no favourites, nothing hidden, Accept asks first')
    local offered = table.concat(Defs.values('hiddenTypes'), ',')
    H.eq(offered, 'patrol,training,investigation,tactical', 'the values are the mission types, in the board order')
    local ok, data = Act(1, { favouriteTypes = { 'tactical', 'tactical' }, hiddenTypes = { 'training' } })
    H.ok(ok == true and #data.values.favouriteTypes == 1 and data.values.hiddenTypes[1] == 'training',
        'favourite tactical (de-duplicated), training hidden')
    H.eq(Saved('OPT00001').hiddenTypes[1], 'training', '...saved with the character')
    H.eq(select(2, Act(1, { favouriteTypes = { 'racing' } })), 'err.option_value', 'an unknown type is refused')
    H.eq(select(2, Act(1, { hiddenTypes = { 'patrol', 'training', 'investigation', 'tactical' } })),
        'err.option_hide_all', 'hiding every type is refused')
    H.eq(Saved('OPT00001').hiddenTypes[1], 'training', '...and the saved list is kept')
    H.ok(Act(1, { skipAcceptConfirm = true }) == true, 'accept in one click')
    H.eq(Defs.checkConfig({ defaults = { hiddenTypes = { 'patrol', 'training', 'investigation', 'tactical' } } }),
        'err.option_config', 'a config default hiding every type is refused')
    H.eq(Defs.checkConfig({ defaults = { hiddenTypes = { 'training' } } }), nil, 'a config default hiding one is fine')
    -- a new type is offered at once; a removed one is dropped from the saved list
    Config.MissionTypes.k9 = { label = 'K9', points = 120, payout = 400 }
    H.ok(Act(1, { favouriteTypes = { 'k9', 'tactical' } }) == true, 'a type added to Config.MissionTypes is offered')
    Config.MissionTypes.k9 = nil
    v = Cb('getOptions', 1).data.values
    H.eq(table.concat(v.favouriteTypes, ','), 'tactical', 'a removed type is dropped from the saved list')
    Act(1, { favouriteTypes = {}, hiddenTypes = {}, skipAcceptConfirm = false })
    H.eq(Saved('OPT00001') and Saved('OPT00001').hiddenTypes, nil, 'back to the defaults: nothing saved')
end

-- Dispatch and opening (shared/options_dispatch.lua, step O9): one-click claim, call pop-ups, the tablet key after a
-- call and the screen the tablet opens on are saved with the character; the remembered filters stay on the PC and are
-- not a row of My options.
do
    local view = Cb('getOptions', 1).data
    local v = view.values
    H.ok(
        v.skipClaimConfirm == false and v.callAlerts == 'all' and v.dispatchKeyAfterCall == false and v.openOn == 'last',
        'the dispatch options ship as today: Claim asks, every call pops up, last screen')
    H.eq(v.rememberFilters, nil, 'remember my filters is kept on the PC, not with the character')
    local rows = {}
    for _, d in ipairs(view.schema) do rows[d.key] = d end
    H.ok(rows.openOn and rows.callAlerts and rows.rememberFilters and rows.rememberFilters.store == 'local',
        'the new options are rows of My options')
    H.eq(rows.filters, nil, 'the remembered filters are not a row of their own')
    local ok, data = Act(1, { callAlerts = 'favourites', openOn = 'active_on_run', skipClaimConfirm = true })
    H.ok(ok == true and data.values.callAlerts == 'favourites' and data.values.openOn == 'active_on_run',
        'favourite types only, open on Active Mission on a run')
    H.eq(Saved('OPT00001').skipClaimConfirm, true, '...saved with the character')
    H.eq(select(2, Act(1, { callAlerts = 'none' })), 'err.option_value', '\'none\' stays Mute call alerts on Dispatch')
    H.eq(select(2, Act(1, { openOn = 'board' })), 'err.option_value', 'open on: last, home or active_on_run only')
    H.eq(select(2, Act(1, { filters = { 'dispatch.filter:near' } })), 'err.invalid_payload',
        'the filters are not saved with the character')
    H.ok(Defs.check('filters', { 'dispatch.filter:near', 'leaderboard.period:monthly' }) ~= nil,
        'a remembered filter list of offered values is good')
    H.eq(select(2, Defs.check('filters', { 'dispatch.filter:everything' })), 'err.option_value',
        'a filter value no screen offers is refused')
    local ses = Cb('getSession', 1, { ui = 'officer', via = 'command' }).data
    H.ok(
        ses.options.openOn == 'active_on_run' and type(ses.opening) == 'table' and ses.opening.onRun == false
            and ses.opening.readyCheck == false,
        'the session carries openOn and the officer\'s run and ready check'
    )
    local keepRuns = CP.Runs
    CP.Runs = setmetatable({
        getBySrc = function(src) return src == 1 and {} or nil end,
    }, { __index = keepRuns })
    H.eq(Cb('getSession', 1, { ui = 'officer', via = 'command' }).data.opening.onRun, true, 'on a run: onRun')
    CP.Runs = keepRuns
    Act(1, { callAlerts = 'all', openOn = 'last', skipClaimConfirm = false })
    H.eq(Saved('OPT00001') and Saved('OPT00001').openOn, nil, 'back to the defaults: nothing saved')
end

-- During a mission (shared/options_run.lua, step O10): abandon without the dialog (still two presses) and recalculate
-- in one click are saved with the character; distances in miles stay on the PC.
do
    local view = Cb('getOptions', 1).data
    local v = view.values
    H.ok(v.abandonConfirm == true and v.skipRecalcConfirm == false,
        'the run options ship as today: Abandon and Recalculate ask in a dialog')
    H.eq(v.distanceUnits, nil, 'the distance units are kept on the PC, not with the character')
    local rows = {}
    for _, d in ipairs(view.schema) do rows[d.key] = d end
    H.ok(
        rows.abandonConfirm and rows.skipRecalcConfirm and rows.distanceUnits and rows.distanceUnits.store == 'local'
            and rows.distanceUnits.group == 'run',
        'the three are rows of My options -> During a mission'
    )
    H.eq(rows.distanceUnits.default, 'metric', 'metres by default, as before')
    local ok, data = Act(1, { abandonConfirm = false, skipRecalcConfirm = true })
    H.ok(ok == true and data.values.abandonConfirm == false and data.values.skipRecalcConfirm == true,
        'Abandon without the dialog, Recalculate in one click')
    H.eq(Saved('OPT00001').abandonConfirm, false, '...saved with the character')
    H.eq(select(2, Act(1, { distanceUnits = 'imperial' })), 'err.invalid_payload', 'units are not saved on the server')
    H.eq(Defs.check('distanceUnits', 'imperial'), 'imperial', 'miles may be picked on the PC')
    H.eq(select(2, Defs.check('distanceUnits', 'nautical')), 'err.option_value', 'metric or imperial only')
    Act(1, { abandonConfirm = true, skipRecalcConfirm = false })
    H.eq(Saved('OPT00001') and Saved('OPT00001').abandonConfirm, nil, 'back to the defaults: nothing saved')
end

-- Unit (shared/options_unit.lua, step O13): Auto-Ready ships locked and off; allowed, it is a row of My options -> Unit
-- saved with the character.
do
    local function Rows()
        local rows = {}
        for _, d in ipairs(Cb('getOptions', 1).data.schema) do rows[d.key] = d end
        return rows
    end
    Config.OfficerOptions.allow.autoReady = false     -- as config.lua ships it (this spec cleared allow above)
    H.eq(Rows().autoReady, nil, 'Auto-Ready is locked as shipped: no row')
    H.eq(Cb('getOptions', 1).data.values.autoReady, false, '...and off: officers answer the ready check, as before')
    H.eq(select(2, Act(1, { autoReady = true })), 'err.option_locked', 'a locked Auto-Ready cannot be turned on')
    Config.OfficerOptions.allow.autoReady = true
    local row = Rows().autoReady
    H.ok(row and row.group == 'unit' and row.store == 'server' and row.default == false,
        'allowed: a row of My options -> Unit, saved with the character, off by default')
    local ok, data = Act(1, { autoReady = true })
    H.ok(ok == true and data.values.autoReady == true, 'the officer turns it on')
    Act(1, { autoReady = false })
    Config.OfficerOptions.allow.autoReady = nil
end

-- Map (shared/options_map.lua, step O14): Objective GPS saved with the character, the HUD line and colour-blind colours
-- kept on this PC; shipped as today.
do
    local rows = {}
    for _, d in ipairs(Cb('getOptions', 1).data.schema) do rows[d.key] = d end
    local g = rows.objectiveGps
    H.ok(
        g and g.group == 'map' and g.store == 'server' and g.default == 'route'
            and table.concat(g.values, ',') == 'route,waypoint,off',
        'Objective GPS: route (as before), waypoint or off'
    )
    H.ok(rows.hudTargetLine and rows.hudTargetLine.store == 'local' and rows.hudTargetLine.default == true,
        'the HUD objective line: on as before, kept on this PC')
    H.ok(rows.colourblindMap and rows.colourblindMap.store == 'local' and rows.colourblindMap.default == false,
        'colour-blind map colours: off as before, kept on this PC')
    H.eq(Cb('getOptions', 1).data.values.objectiveGps, 'route', 'officers get the GPS line as before')
    local ok, data = Act(1, { objectiveGps = 'waypoint' })
    H.ok(ok == true and data.values.objectiveGps == 'waypoint', 'an officer picks the waypoint')
    H.eq(select(2, Act(1, { objectiveGps = 'start' })), 'err.option_value', 'only route, waypoint or off')
    Act(1, { objectiveGps = 'route' })
end

-- My usual twists (shared/options_board.lua, step O15): the twists enabled in Config.Events.twists, saved with the
-- character; shipped as today (none); an unknown twist is refused, one switched off since is dropped.
do
    local rows = {}
    for _, d in ipairs(Cb('getOptions', 1).data.schema) do rows[d.key] = d end
    local u = rows.usualTwists
    H.ok(u and u.group == 'board' and u.store == 'server' and u.kind == 'list',
        'My usual twists: a Mission Board row, saved with the character')
    H.eq(table.concat(Defs.values('usualTwists'), ','), 'armored_hostiles,time_crunch,radio_silence',
        'the values are the enabled twists, in the tablet\'s order')
    H.eq(#Cb('getOptions', 1).data.values.usualTwists, 0, 'shipped: no usual twists, as before')
    local ok, data = Act(1, { usualTwists = { 'time_crunch', 'time_crunch' } })
    H.ok(ok == true and table.concat(data.values.usualTwists, ',') == 'time_crunch', 'Time Crunch as usual (once)')
    H.eq(Saved('OPT00001').usualTwists[1], 'time_crunch', '...saved with the character')
    H.eq(select(2, Act(1, { usualTwists = { 'double_trouble' } })), 'err.option_value', 'an unknown twist is refused')
    H.eq(select(2, Act(1, { usualTwists = 'time_crunch' })), 'err.option_value', 'a list, not one key')
    Act(1, { usualTwists = { 'time_crunch', 'radio_silence' } })
    local keep = Config.Events.twists.time_crunch.enabled
    Config.Events.twists.time_crunch.enabled = false
    H.eq(table.concat(Defs.values('usualTwists'), ','), 'armored_hostiles,radio_silence', 'a switched-off twist goes')
    H.eq(table.concat(Cb('getOptions', 1).data.values.usualTwists, ','), 'radio_silence',
        '...and is dropped from the saved list')
    Config.Events.twists.time_crunch.enabled = keep
    Act(1, { usualTwists = {} })
    H.eq(Saved('OPT00001') and Saved('OPT00001').usualTwists, nil, 'back to the defaults: nothing saved')
end

-- the column the step adds, in every storage mode (files mode: the saves folder engine)
H.ok(pcall(H.sql, 'SELECT options FROM cp_officers LIMIT 1'), 'migration 010: cp_officers.options exists')

for _, k in ipairs({ 't_bool', 't_enum', 't_list', 't_num', 't_local' }) do Defs.remove(k) end
H.sql('DELETE FROM cp_officers WHERE citizenid LIKE \'OPT%\'')

return H
