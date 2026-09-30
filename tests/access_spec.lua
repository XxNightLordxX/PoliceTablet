-- Tablet access and the UI shell (WP8): the ways and their switches, mission desks, requireItem, the sidebar badge
-- counts and their 'nav' push, Config health, and the client's desk zones, desk pose and item and distance watchers.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

local function Contains(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

-- ============================================================================
--                            THE SERVER UNDER TEST
-- ============================================================================
-- CP.Access, CP.Permissions and CP.Alerts are stand-ins: getSession's own checks are what this spec is about.

local officers = {
    [1] = { dept = 'sast', supervisor = true, cid = 'ACC1' },
    [2] = { dept = 'fib', supervisor = false, cid = 'ACC2' },
}
local arena = {}
local admins = { [9] = true }
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
            rank = 'Sergeant',
            callsign = 'C-' .. src,
            gradeLevel = 3,
            isSupervisor = o.supervisor,
        }
    end,
    isAdmin = function(src) return admins[src] == true end,
    department = function(key) return { key = key, theme = { primary = '#1f4e8c' } } end,
    departments = function()
        return {
            { key = 'sast', label = 'SAST', short = 'SAST', theme = { primary = '#1f4e8c' } },
            { key = 'fib', label = 'FIB', short = 'FIB', theme = { primary = '#1c2541' } },
        }
    end,
    refreshOfficerRow = function() end,
}
local allowed = { reviewFlagged = true, handleDisputes = true, reviewProfiles = true }
CP.Permissions = {
    can = function(src, action)
        return officers[src] ~= nil and officers[src].supervisor and allowed[action] == true
    end,
    actionsFor = function() return {} end,
}
CP.Alerts = {
    inArena = function(src) return arena[src] == true end,
}

Config.Tablet.item = false
Config.Tablet.access = { command = true, keybind = true, item = true, desk = true, requireItem = false }
Config.Tablet.desks = {
    { label = 'Desk A', coords = vec3(100.0, 100.0, 30.0), size = vec3(2.0, 1.0, 1.0), rotation = 0.0 },
    {
        label = 'Desk B',
        coords = vec3(200.0, 200.0, 30.0),
        size = vec3(4.0, 1.0, 1.0),
        rotation = 90.0,
        departments = { 'fib' },
        prop = 'prop_laptop_01a',
    },
}
H.players[1] = { coords = vec3(0.0, 0.0, 0.0) }
H.players[2] = { coords = vec3(0.0, 0.0, 0.0) }
H.players[9] = { coords = vec3(0.0, 0.0, 0.0) }

H.load('modules/tablet/server.lua')
H.load('modules/confighealth/server.lua')
local T = CP.Tablet

-- Every callback in its own second (the callbacks are rate limited per second).
local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    return H.callback('crimson-police:' .. name, src, args)
end
local function Open(src, args)
    args = args or {}
    args.ui = args.ui or 'officer'
    return Cb('getSession', src, args)
end
local function Refused(res) return res and res.ok == false and res.error or nil end
local function At(src, x, y, z) H.players[src].coords = vec3(x, y, z or 30.0) end

-- ============================================================================
--                        1. THE WAYS AND THEIR SWITCHES
-- ============================================================================

do
    for _, via in ipairs({ 'command', 'keybind', 'dispatch', 'export' }) do
        local res = Open(1, { via = via })
        H.ok(res and res.ok, ('%s opens while every way is on'):format(via))
        H.eq(res.data.access.via, via, ('access.via = %s'):format(via))
        H.eq(res.data.access.desk, nil, 'no desk index away from a desk')
    end
    H.eq(Refused(Open(1, { via = 'item' })), 'err.access_off', 'the item way without Config.Tablet.item is off')
    Config.Tablet.item = 'crimson_police_tablet'
    H.ok(Open(1, { via = 'item' }).ok, 'with an item set the item way opens')

    Config.Tablet.access.command = false
    H.eq(Refused(Open(1, { via = 'command' })), 'err.access_off', 'access.command = false refuses /CrimsonPolice')
    H.ok(Open(1, { via = 'keybind' }).ok, 'and leaves the key mapping on')
    Config.Tablet.access.keybind = false
    H.eq(Refused(Open(1, { via = 'keybind' })), 'err.access_off', 'access.keybind = false refuses the key mapping')
    H.eq(Refused(Open(1, { via = 'dispatch' })), 'err.access_off', 'and the Dispatch key mapping')
    Config.Tablet.access.item = false
    H.eq(Refused(Open(1, { via = 'item' })), 'err.access_off', 'access.item = false refuses the item')
    Config.Tablet.access.desk = false
    At(1, 100.0, 100.0)
    H.eq(Refused(Open(1, { via = 'desk', desk = 1 })), 'err.access_off', 'access.desk = false refuses a desk')
    H.ok(Open(1, { via = 'export' }).ok, 'the export is always on')
    H.eq(Refused(Open(1, { via = 'bogus' })), 'err.access_off', 'an unknown way counts as the command (off here)')
    H.ok(Open(1, { via = 'desk', desk = 1, silent = true }).ok, 'the silent theme session opens nothing: no checks')
    H.eq(Refused(Open(3, { via = 'export' })), 'err.not_police', 'the officer checks still come first')
    H.ok(Cb('getSession', 9, { ui = 'admin', via = 'command' }).ok, 'the Admin UI has its own command: no way checks')
    Config.Tablet.access = { command = true, keybind = true, item = true, desk = true, requireItem = false }
    Config.Tablet.item = false
end

-- ============================================================================
--                               2. MISSION DESKS
-- ============================================================================

do
    At(1, 102.9, 100.0)
    local res = Open(1, { via = 'desk', desk = 1 })
    H.ok(res and res.ok, 'inside the box plus 2 m (x half 1 + 2 = 3 m): accepted')
    H.eq(res.data.access.via, 'desk', 'access.via = desk')
    H.eq(res.data.access.desk, 1, 'access.desk = the index')
    At(1, 103.2, 100.0)
    H.eq(Refused(Open(1, { via = 'desk', desk = 1 })), 'err.not_at_desk', '3.2 m out along x: refused')
    At(1, 100.0, 102.4)
    H.ok(Open(1, { via = 'desk', desk = 1 }).ok, 'y half 0.5 + 2 = 2.5 m: 2.4 m accepted')
    At(1, 100.0, 102.6)
    H.eq(Refused(Open(1, { via = 'desk', desk = 1 })), 'err.not_at_desk', '2.6 m out along y: refused')
    At(1, 100.0, 100.0, 33.4)
    H.eq(Refused(Open(1, { via = 'desk', desk = 1 })), 'err.not_at_desk', 'a floor above: refused')

    -- desk B is turned 90°: its 4 m side runs along the world y axis
    At(2, 200.0, 203.8)
    H.ok(Open(2, { via = 'desk', desk = 2 }).ok, 'rotated box: 3.8 m along its long side accepted')
    At(2, 203.8, 200.0)
    H.eq(Refused(Open(2, { via = 'desk', desk = 2 })), 'err.not_at_desk', 'and 3.8 m across it refused')
    At(2, 200.0, 204.2)
    H.eq(Refused(Open(2, { via = 'desk', desk = 2 })), 'err.not_at_desk', 'and 4.2 m along its long side refused')
    At(1, 200.0, 200.0)
    H.eq(Refused(Open(1, { via = 'desk', desk = 2 })), 'err.desk_department', 'a desk for fib refuses sast')

    At(1, 100.0, 100.0)
    for _, spoof in ipairs({ 99, 0, -1, 'abc', 1.5 }) do
        H.eq(Refused(Open(1, { via = 'desk', desk = spoof })), 'err.not_at_desk',
            ('a spoofed desk index (%s) is refused'):format(tostring(spoof)))
    end
    H.eq(Refused(Open(1, { via = 'desk' })), 'err.not_at_desk', 'a desk way without an index is refused')
    arena[1] = true
    H.eq(Refused(Open(1, { via = 'desk', desk = 1 })), 'err.in_arena', 'in Crimson-Arena the desk refuses')
    H.eq(Refused(Open(1, { via = 'command' })), 'err.in_arena', 'and so does every other way')
    arena[1] = nil

    -- a later request of the same tablet (switchUi, refreshSession) names no way: the last one is checked again
    At(1, 100.0, 100.0)
    H.ok(Open(1, { via = 'desk', desk = 1 }).ok, 'opened at the desk')
    H.ok(Open(1, { ui = 'supervisor' }).ok, 'switching to the Supervisor UI at the desk')
    At(1, 150.0, 100.0)
    H.eq(Refused(Open(1, { ui = 'supervisor' })), 'err.not_at_desk', 'and refused once the officer walked away')
    H.ok(Open(1, { via = 'command' }).ok, 'a new open names its own way')
    H.ok(Open(1, {}).ok, 'the command is remembered from then on')
end

-- ============================================================================
--                                3. requireItem
-- ============================================================================

do
    local inv = H.mockInventory({ crimson_police_tablet = { label = 'Police Tablet' } })
    local searches = 0
    local realSearch = H.exportsMock.ox_inventory.Search
    local searchFails = false
    H.exportsMock.ox_inventory.Search = function(...)
        searches = searches + 1
        if searchFails then error('inventory not ready') end
        return realSearch(...)
    end
    Config.Tablet.item = 'crimson_police_tablet'

    H.ok(Open(1, { via = 'command' }).ok, 'requireItem off: no item needed')
    H.eq(searches, 0, 'and the inventory is never asked')
    searchFails = true
    H.ok(Open(1, { via = 'command' }).ok, 'a failing inventory does not matter while the item is not required')
    searchFails = false

    Config.Tablet.access.requireItem = true
    for _, via in ipairs({ 'command', 'keybind', 'item', 'export', 'dispatch' }) do
        H.eq(Refused(Open(1, { via = via })), 'err.no_tablet_item',
            ('requireItem: %s refused without the item'):format(via))
    end
    At(1, 100.0, 100.0)
    H.ok(Open(1, { via = 'desk', desk = 1 }).ok, 'a mission desk never needs the item')
    inv.slots[1] = { { slot = 1, name = 'crimson_police_tablet', count = 1 } }
    H.ok(Open(1, { via = 'command' }).ok, 'with the item in the inventory the command opens')
    H.eq(T.hasTabletItem(1), true, 'hasTabletItem')
    searchFails = true
    H.eq(Refused(Open(1, { via = 'command' })), 'err.no_tablet_item', 'a failing Search counts as no item')
    searchFails = false
    local realState = GetResourceState
    _G.GetResourceState = function(name) if name == 'ox_inventory' then return 'stopped' end return realState(name) end
    H.eq(Refused(Open(1, { via = 'command' })), 'err.no_tablet_item', 'ox_inventory stopped counts as no item')
    _G.GetResourceState = realState

    -- the client saw the item go: the server checks again and closes the tablet
    H.reset()
    H.fire('crimson-police:server:tabletItemGone', 1)
    H.eq(#H.findEvents('crimson-police:client:closeTablet'), 0, 'the item is still there: nothing is closed')
    inv.slots[1][1].count = 0
    H.fire('crimson-police:server:tabletItemGone', 1)
    local ev = H.findEvents('crimson-police:client:closeTablet')
    H.eq(#ev, 1, 'the item is gone: the tablet closes')
    H.eq(ev[1] and ev[1].target, 1, 'for that player')
    H.eq(ev[1] and ev[1].args[1], 'err.no_tablet_item', 'with the reason')
    H.clockMs = H.clockMs + 1100
    local before = searches
    for _ = 1, 10 do H.fire('crimson-police:server:tabletItemGone', 1) end
    H.eq(searches - before, 2, 'a flood of reports asks the inventory at most twice a second')
    H.ok(Open(1, { via = 'desk', desk = 1 }).ok, 'reopened at the desk')
    H.reset()
    H.fire('crimson-police:server:tabletItemGone', 1)
    H.eq(#H.findEvents('crimson-police:client:closeTablet'), 0, 'a tablet opened at a desk stays open')
    Config.Tablet.access.requireItem = false
    H.fire('crimson-police:server:tabletItemGone', 2)
    H.eq(#H.findEvents('crimson-police:client:closeTablet'), 0, 'requireItem off: the report is ignored')
    Config.Tablet.item = false
    H.exportsMock.ox_inventory = nil
end

-- ============================================================================
--                           4. SIDEBAR BADGE COUNTS
-- ============================================================================

do
    local function Counts(src)
        H.time = H.time + 60   -- past every count cache
        return T.navCounts(src)
    end
    local c = Counts(1)
    H.eq(c.invites + c.calls + c.review + c.commendations + c.rewards, 0, 'missing modules give 0 everywhere')
    H.eq(c.onRun, false, 'and no run')

    local asked = {}
    CP.Units = {
        view = function(src)
            asked.view = src
            return { invites = { { expiresIn = 20 }, { expiresIn = 0 }, { expiresIn = 5 } } }
        end,
    }
    CP.MissionCalls = {
        claimableCount = function() return 2 end,
    }
    CP.Profile = {
        newCommendations = function(cid)
            asked.commendations = cid
            return 1
        end,
        queue = function(dept)
            asked.queue = dept
            return { {}, {}, {} }
        end,
    }
    CP.Rewards = {
        lockerCount = function(cid)
            asked.rewards = cid
            return 4
        end,
    }
    CP.Runs = {
        getBySrc = function(src) return src == 1 and { id = 'r1' } or nil end,
    }
    CP.Admin = {
        flaggedRows = function(dept, cid)
            asked.flagged = { dept, cid }
            return { {}, {} }
        end,
    }
    CP.Disputes = {
        forSupervisor = function() return { {} } end,
    }
    c = Counts(1)
    H.eq(c.invites, 2, 'invites: the unit view\'s open invites')
    H.eq(asked.view, 1, 'for the viewer')
    H.eq(c.calls, 2, 'calls: CP.MissionCalls.claimableCount')
    H.eq(c.commendations, 1, 'commendations: CP.Profile.newCommendations')
    H.eq(asked.commendations, 'ACC1', 'by citizenid')
    H.eq(c.rewards, 4, 'rewards: CP.Rewards.lockerCount')
    H.eq(c.review, 6, 'review: flagged 2 + disputes 1 + profiles 3')
    H.eq(asked.flagged[1], 'sast', 'flagged rows of the supervisor\'s department')
    H.eq(asked.flagged[2], 'ACC1', 'without the supervisor\'s own runs')
    H.eq(asked.queue, 'sast', 'the profile queue of the department')
    H.eq(c.onRun, true, 'onRun: CP.Runs.getBySrc')
    CP.Units.invitesFor = function() return 3 end
    H.eq(Counts(1).invites, 3, 'CP.Units.invitesFor wins when it exists')
    local c2 = Counts(2)
    H.eq(c2.review, 0, 'no Review Queue count for an officer who is not a supervisor')
    H.eq(c2.onRun, false, 'and not on a run')
    H.eq(Counts(7).calls, 0, 'not an officer: everything 0')

    -- caches: badge counts 5 s, the Review Queue count 30 s
    local flaggedCalls = 0
    CP.Admin.flaggedRows = function()
        flaggedCalls = flaggedCalls + 1
        return {}
    end
    H.time = H.time + 60
    T.navCounts(1)
    T.navCounts(1)
    H.eq(flaggedCalls, 1, 'counts are cached')
    H.time = H.time + 10
    T.navCounts(1)
    H.eq(flaggedCalls, 1, 'the Review Queue count is kept 30 s')
    H.time = H.time + 31
    T.navCounts(1)
    H.eq(flaggedCalls, 2, 'then read again')

    CP.MissionCalls.claimableCount = function() error('boom') end
    H.eq(Counts(1).calls, 0, 'a failing module gives 0')
    CP.MissionCalls.claimableCount = function() return 2 end

    -- a push that can change a badge sends one 'nav' push a second later, only to a src that asked for its counts
    H.time = H.time + 700
    H.reset()
    T.push(2, 'unit', {})
    H.advance(1500)
    H.eq(#H.findEvents('crimson-police:client:push'), 1, 'no nav push for a src that did not ask or open for 10 min')
    H.time = H.time + 60
    local res = Cb('getNavCounts', 1)
    H.ok(res and res.ok, 'getNavCounts answers')
    H.eq(res.data.calls, 2, 'with the counts')
    H.reset()
    CP.MissionCalls.claimableCount = function() return 5 end
    T.push(1, 'calls', {})
    T.push(1, 'unit', {})
    T.push(1, 'board', {})
    H.advance(1500)
    local navs = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:push')) do
        if e.args[1] == 'nav' then navs[#navs + 1] = e end
    end
    H.eq(#navs, 1, 'a burst of pushes gives one nav push')
    H.eq(navs[1] and navs[1].target, 1, 'to that src')
    H.eq(navs[1] and navs[1].args[2].calls, 5, 'with fresh counts (the push cleared the cache)')
    H.reset()
    T.push(1, 'board', {})
    H.advance(1500)
    H.eq(#H.findEvents('crimson-police:client:push'), 1, 'a topic without a badge sends no nav push')
    -- the watch lasts 10 minutes from the last getNavCounts or tablet open
    H.time = H.time + 700
    H.reset()
    T.push(1, 'calls', {})
    H.advance(1500)
    H.eq(#H.findEvents('crimson-police:client:push'), 1, 'no nav push 10 minutes after the last ask')
    H.ok(Open(1, { via = 'command' }).ok, 'the tablet opens again')
    H.reset()
    T.push(1, 'calls', {})
    H.advance(1500)
    H.eq(#H.findEvents('crimson-police:client:push'), 2, 'an open renews the watch: the nav push is back')
    H.fire('playerDropped', 1)
    H.reset()
    T.push(1, 'calls', {})
    H.advance(1500)
    H.eq(#H.findEvents('crimson-police:client:push'), 1, 'a dropped player gets no more nav pushes')
    CP.Units, CP.MissionCalls, CP.Profile, CP.Rewards, CP.Runs, CP.Admin, CP.Disputes =
        nil, nil, nil, nil, nil, nil, nil
end

-- ============================================================================
--                           5. ADMIN: TABLET ACCESS
-- ============================================================================

do
    H.eq(Refused(Cb('admin:getTabletAccess', 1)), 'err.not_admin', 'admins only')
    Config.Departments.sast.theme.personalAccents = { '#f2c230', { colour = '#80ed99', level = 10 }, 'nope' }
    local res = Cb('admin:getTabletAccess', 9)
    H.ok(res and res.ok, 'admin:getTabletAccess answers')
    local v = res.data
    H.eq(#v.desks, 2, 'both desks')
    H.eq(v.desks[2].label, 'Desk B', 'labels')
    H.eq(v.desks[2].departments[1], 'fib', 'department lists')
    H.eq(v.desks[1].departments, nil, 'nil = every department')
    H.eq(v.desks[2].rotation, 90.0, 'rotation')
    H.eq(v.desks[2].prop, 'prop_laptop_01a', 'prop')
    H.eq(v.ways.desk, true, 'ways')
    H.eq(v.ways.requireItem, false, 'requireItem')
    H.eq(#v.accents.sast, 2, 'personal accents: the valid ones')
    H.eq(v.accents.sast[2].level, 10, 'with their levels')
    H.eq(#v.appearances, #Config.Profile.appearances, 'appearances')
end

-- ============================================================================
--                               6. CONFIG HEALTH
-- ============================================================================

local Health = CP.ConfigHealth

local function Lines(check)
    local out = {}
    for _, item in ipairs(Health.run()) do
        if item.check == check then out[#out + 1] = item end
    end
    return out
end
local function Levels(check)
    local out = {}
    for _, item in ipairs(Lines(check)) do out[#out + 1] = item.level end
    return table.concat(out, ',')
end
local function HasText(check, needle)
    for _, item in ipairs(Lines(check)) do if Contains(item.text, needle) then return true end end
    return false
end

do
    -- the first run, 5 s after the start
    H.eq(Health._checks()[1].name, 'items', 'built-in checks registered at load')
    H.advance(5100)
    H.ok(Cb('admin:getConfigHealth', 9).ok, 'admin:getConfigHealth answers')
    H.eq(Refused(Cb('admin:getConfigHealth', 1)), 'err.not_admin', 'admins only')
    -- "Check again" runs every check at once: a fixed or new problem shows without waiting
    Health.register('late', function() return { { level = 'warn', text = 'late line' } } end)
    local again = Cb('admin:getConfigHealth', 9)
    local found = false
    for _, item in ipairs(again.data or {}) do if item.check == 'late' then found = true end end
    H.ok(found, 'admin:getConfigHealth runs the checks again')
    Health.register('late', function() return {} end)

    -- items
    Config.Tablet.item, Config.Tablet.access.requireItem = false, false
    H.eq(Levels('items'), 'ok', 'items: the item off is fine')
    Config.Tablet.access.requireItem = true
    H.eq(Levels('items'), 'error', 'items: requireItem without an item is an error')
    Config.Tablet.access.requireItem = false
    Config.Tablet.item = 'crimson_police_tablet'
    H.mockInventory({ water = { label = 'Water' } })
    H.eq(Levels('items'), 'warn', 'items: an item ox_inventory does not know is a warning')
    H.ok(HasText('items', 'items/ox_inventory_items.lua'), 'which says where the snippet is')
    H.mockInventory({ crimson_police_tablet = { label = 'Police Tablet' } })
    -- the picture: ox_inventory/web/images/<item>.png, unless inventory:imagepath points somewhere else
    local images = { ['web/images/crimson_police_tablet.png'] = 'png' }
    local realImageLoad = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if res == 'ox_inventory' then return images[path] end
        return realImageLoad(res, path)
    end
    H.eq(Levels('items'), 'ok', 'items: a known item with its picture is fine')
    Config.Tablet.access.item = false
    H.eq(Levels('items'), 'warn,ok', 'items: an item whose way is off is a warning')
    Config.Tablet.access.item = true
    images['web/images/crimson_police_tablet.png'] = nil
    H.eq(Levels('items'), 'warn,ok', 'items: no picture in ox_inventory is a warning')
    H.ok(HasText('items', 'ox_inventory/web/images and name it crimson_police_tablet.png'), 'saying where it goes')
    _G.GetConvar = function(name, default)
        if name == 'inventory:imagepath' then return 'https://cdn.example.com/items' end
        return default
    end
    H.eq(Levels('items'), 'ok', 'items: pictures from a web host (inventory:imagepath) are not looked for')
    _G.GetConvar = function(_, default) return default end
    H.eq(Levels('items'), 'warn,ok', 'items: the default image path is looked in')
    _G.GetConvar = nil
    _G.LoadResourceFile = realImageLoad
    local realState = GetResourceState
    _G.GetResourceState = function(name) if name == 'ox_inventory' then return 'stopped' end return realState(name) end
    H.eq(Levels('items'), 'error', 'items: no ox_inventory is an error')
    _G.GetResourceState = realState
    Config.Tablet.item = false

    -- desks
    H.eq(Levels('desks'), 'ok', 'desks: two good desks')
    H.ok(HasText('desks', '2 of 2'), 'counted')
    Config.Tablet.desks[3] = { label = 'Broken', coords = 'here' }
    Config.Tablet.desks[4] = { label = 'Unknown', coords = vec3(1.0, 2.0, 3.0), departments = { 'nope' } }
    H.eq(Levels('desks'), 'error,warn,ok', 'desks: bad coords are an error, an unknown department a warning')
    H.ok(HasText('desks', 'nope'), 'naming the department')
    Config.Tablet.desks[3], Config.Tablet.desks[4] = nil, nil
    Config.Tablet.access.desk = false
    H.eq(Levels('desks'), 'ok', 'desks: switched off')
    Config.Tablet.access.desk = true

    -- colours and personal accents
    Config.Departments.sast.theme.personalAccents = { '#f2c230', { colour = '#80ed99', level = 10 } }
    Config.Departments.fib.theme.personalAccents = nil
    H.eq(Levels('colours'), 'ok,ok', 'colours: valid themes and accents')
    Config.Departments.sast.theme.personalAccents = { '#F2C230', '#f2c230', 'red', { colour = '#80ed99', level = 0 } }
    H.eq(Levels('colours'), 'warn,warn,warn,ok', 'colours: a twice listed accent, a bad colour, a bad level')
    Config.Departments.fib.theme.accent = 'gold'
    H.ok(HasText('colours', 'theme.accent'), 'colours: a bad theme colour is named')
    Config.Departments.fib.theme.accent = '#c9a227'
    Config.Departments.sast.theme.personalAccents = nil

    -- mission tweaks
    Config.MissionTweaks = {}
    H.eq(Levels('tweaks'), 'ok', 'tweaks: none')
    local defs = { prison_break = { id = 'prison_break', tweaked = true }, beat_patrol = { id = 'beat_patrol' } }
    CP.Missions = {
        get = function(id) return defs[id] end,
    }
    Config.MissionTweaks = { prison_break = { cooldown = 900 }, beat_patrol = { nope = 1 }, ghost = { cooldown = 1 } }
    H.eq(Levels('tweaks'), 'warn,warn,ok', 'tweaks: an ignored tweak and an unknown mission are warnings')
    H.ok(HasText('tweaks', '1 of 3'), 'the applied ones are counted')
    H.ok(HasText('tweaks', 'ghost'), 'the unknown mission is named')
    Config.MissionTweaks, CP.Missions = {}, nil

    -- the locale file
    H.eq(Levels('locale'), 'ok', 'locale: locales/en.json loads')
    Config.Locale = 'de'
    H.eq(Levels('locale'), 'warn,ok', 'locale: another language is a warning (English only)')
    Config.Locale = 'en'
    local realLoad = LoadResourceFile
    _G.LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return '{ nope' end
        return realLoad(res, path)
    end
    H.eq(Levels('locale'), 'error', 'locale: invalid JSON is an error')
    _G.LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return nil end
        return realLoad(res, path)
    end
    H.eq(Levels('locale'), 'error', 'locale: a missing file is an error')
    _G.LoadResourceFile = realLoad

    -- avatar link hosts
    local urls = Config.Profile.avatarUrls
    urls.enabled = false
    H.eq(Levels('avatars'), 'ok', 'avatars: links off')
    urls.enabled = true
    urls.hosts = { 'r2.fivemanage.com' }
    H.eq(Levels('avatars'), 'ok', 'avatars: one good host')
    urls.hosts = { 'r2.fivemanage.com', 'cdn.discordapp.com', 'https://x.example.com/', 'nodot' }
    H.eq(Levels('avatars'), 'warn,warn,warn,ok',
        'avatars: an expiring host and two bad ones are warnings (listed first)')
    urls.hosts = {}
    H.eq(Levels('avatars'), 'warn', 'avatars: links on with no host')
    urls.hosts, urls.requireApproval = { 'i.imgur.com' }, false
    H.eq(Levels('avatars'), 'warn,ok', 'avatars: no approval is a warning')
    urls.enabled, urls.requireApproval, urls.hosts = false, true, { 'r2.fivemanage.com', 'i.imgur.com' }

    -- departments: every job a department lists is a Qbox job, and supervisorGrade splits that job's grades
    local realDepartments = CP.Access.departments
    local depts = {
        { key = 'sast', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3 },
        { key = 'fib', short = 'FIB', jobs = { 'fib', 'fbi' }, supervisorGrade = 3 },
    }
    CP.Access.departments = function() return depts end
    local jobs = {
        sast = {
            label = 'SAST',
            grades = {
                [0] = { name = 'Cadet' },
                [1] = { name = 'Trooper' },
                [2] = { name = 'Sergeant' },
                [3] = { name = 'Lieutenant' },
                [4] = { name = 'Chief' },
            },
        },
        fib = { label = 'FIB', grades = { ['0'] = { name = 'Agent' }, ['1'] = { name = 'Special Agent' } } },
    }
    CP.Qbx = {
        getJobs = function() return jobs end,
    }
    H.eq(Levels('departments'), 'warn,warn,ok', 'departments: a grade above the ladder and a missing job')
    H.ok(HasText(
        'departments',
        'FIB: supervisorGrade is 3, higher than every grade of Qbox job fib (0 Agent, 1 Special Agent), so nobody is a supervisor'
    ), 'a supervisorGrade above every grade: nobody is a supervisor, with the ladder')
    H.ok(HasText('departments', 'FIB: Qbox has no job named fbi, so that name does nothing'),
        'a job Qbox does not have, next to one it has')
    H.ok(HasText('departments', 'players with the department\'s other jobs can still use it'),
        'which does not lock the department')
    H.ok(not HasText('departments', 'nobody can use this department'), 'so it does not say nobody can use it')
    H.ok(HasText('departments', 'jobs = { } of Config.Departments.fib in config/config.lua'), 'with the fix')
    depts[2].jobs = { 'fbi', 'feds' }
    H.eq(Levels('departments'), 'warn,warn,ok', 'departments: none of its jobs exists')
    H.ok(HasText('departments', 'FIB: Qbox has no job named feds, so nobody can use this department'),
        'then nobody can use it')
    H.ok(HasText('departments', 'put your own police job name in jobs = { } of Config.Departments.fib'), 'with the fix')
    depts[2].jobs = { 'fib', 'fbi' }
    H.ok(HasText(
        'departments',
        'SAST: Qbox job sast (0 Cadet, 1 Trooper, 2 Sergeant, 3 Lieutenant, 4 Chief); supervisors are grade 3 Lieutenant and up'
    ), 'a good department: its ladder and where supervisors start')
    depts[1].supervisorGrade = 0
    H.ok(HasText('departments', 'SAST: supervisorGrade 0 is the lowest grade of Qbox job sast'),
        'supervisorGrade at the lowest grade: every officer is a supervisor')
    depts[1].supervisorGrade = 2
    H.ok(HasText('departments', 'supervisors are grade 2 Sergeant and up'), 'a middle grade is fine')
    jobs.sast.grades = { [0] = { name = 'Cadet' }, [2] = {}, [5] = { name = 'Chief' } }
    H.ok(HasText('departments', '(0 Cadet, 2, 5 Chief); supervisors are grade 2 and up'),
        'a grade without a name, and a gap: the next grade up')
    depts[2].jobs = { 'fib' }
    Config.Departments.fib.supervisorGrade = 'x'
    H.eq(Levels('departments'), 'ok,ok', 'departments: a supervisorGrade that is not a number is CP.Access\'s warning')
    H.ok(HasText('departments', 'FIB: Qbox job fib exists'), 'the job itself is still checked')
    Config.Departments.fib.supervisorGrade = 3
    jobs = {}
    H.eq(Levels('departments'), 'warn', 'departments: no Qbox job list at all')
    H.ok(HasText('departments', 'qbx_core started without errors'), 'saying what to check')
    depts = {}
    H.eq(Levels('departments'), '', 'departments: none configured (CP.Access warns about that)')
    CP.Access.departments, CP.Qbx = realDepartments, nil

    -- admins: whether Qbox's admin group can open the Admin UI
    local principals = { ['group.admin'] = { ['crimsonpolice.admin'] = true } }
    _G.IsPrincipalAceAllowed = function(principal, ace)
        return principals[principal] ~= nil and principals[principal][ace] == true
    end
    local qboxOn = false
    CP.Access.adminAce = function() return 'crimsonpolice.admin' end
    CP.Access.qboxAdminAce = function() return qboxOn and 'admin' or nil end
    H.eq(Levels('admins'), 'ok', 'admins: group.admin has crimsonpolice.admin')
    H.ok(HasText('admins', 'Server admins (group.admin) have crimsonpolice.admin'), 'said so')
    principals['group.admin'] = { admin = true, command = true }
    qboxOn = true
    H.eq(Levels('admins'), 'ok', 'admins: QboxAdmins on and group.admin holds admin')
    H.ok(HasText('admins', 'Config.QboxAdmins is true'), 'said so')
    qboxOn = false
    H.eq(Levels('admins'), 'warn', 'admins: QboxAdmins off and no ace for group.admin')
    H.ok(HasText('admins', 'Add this line to server.cfg and restart: add_ace group.admin crimsonpolice.admin allow'),
        'with the exact server.cfg line')
    CP.Access.adminAce = function() return 'myserver.police' end
    H.ok(HasText('admins', 'add_ace group.admin myserver.police allow'), 'naming Config.AdminAce')
    CP.Access.adminAce, CP.Access.qboxAdminAce = nil, nil
    principals['group.admin'] = { ['crimsonpolice.admin'] = true }
    H.eq(Levels('admins'), 'ok', 'admins: without CP.Access helpers the default ace is checked')
    _G.IsPrincipalAceAllowed = nil
    H.eq(Levels('admins'), 'ok', 'admins: a server without IsPrincipalAceAllowed is not guessed at')

    -- the folder: everything follows a rename, except names written outside it
    H.eq(Levels('folder'), 'ok', 'folder: named Crimson-Police')
    local realResource = CP.resource
    CP.resource = 'police-tablet'
    H.eq(Levels('folder'), 'ok', 'folder: renamed with no tablet item, nothing in the stack names it')
    H.ok(HasText('folder', 'folder is named police-tablet, not Crimson-Police: everything works'), 'said so')
    H.ok(HasText('folder', 'export = \'police-tablet.useTablet\''), 'with the item line for later')
    Config.Tablet.item = 'crimson_police_tablet'
    H.eq(Levels('folder'), 'warn', 'folder: renamed while the tablet item is set')
    H.ok(HasText('folder', 'folder is named police-tablet, not Crimson-Police'), 'naming both')
    H.ok(HasText('folder', 'export = \'police-tablet.useTablet\''), 'with the item line to paste')
    H.ok(HasText('folder', 'exports[\'police-tablet\']'), 'and the export name for other scripts')
    Config.Tablet.item = false
    CP.resource = realResource

    -- other resources: Crimson-Police runs without them
    local stoppedRes = {}
    local realResState = GetResourceState
    _G.GetResourceState = function(name)
        if stoppedRes[name] then return stoppedRes[name] end
        return realResState(name)
    end
    H.eq(Levels('resources'), 'ok,ok,ok,ok',
        'resources: sc-police, sc-npcpolice, sc-multijob and Crimson-Arena running')
    stoppedRes['sc-police'] = 'missing'
    stoppedRes['sc-npcpolice'] = 'stopped'
    stoppedRes['Crimson-Arena'] = 'starting'
    H.eq(Levels('resources'), 'warn,ok,ok,ok', 'resources: only sc-police missing is a warning')
    H.ok(HasText('resources', 'Add ensure sc-police to server.cfg'), 'with the line to add')
    H.ok(HasText('resources', 'officers cannot set their callsign with /callsign'), 'saying what is lost')
    H.ok(not HasText('resources', '/imp'), 'not the /imp check, which only matters while sc-police runs')
    H.ok(HasText('resources', 'sc-npcpolice is not running (optional)'), 'the others are only mentioned')
    H.ok(HasText('resources', 'Crimson-Arena is running'), 'a resource that is starting counts as running')
    _G.GetResourceState = realResState

    -- Discord webhooks: which are on, and a value that is not a link
    H.eq(Levels('webhooks'), '', 'webhooks: nothing without CP.Admin')
    CP.Admin = {
        webhooks = function()
            return {
                { category = 'audit', convar = 'cp_webhook_audit', state = 'on' },
                { category = 'flags', convar = 'cp_webhook_flags', state = 'invalid' },
                { category = 'board', convar = 'cp_webhook_board', state = 'off' },
                { category = 'builder', convar = 'cp_webhook_builder', state = 'off' },
                { category = 'operations', convar = 'cp_webhook_operations', state = 'on' },
            }
        end,
    }
    H.eq(Levels('webhooks'), 'warn,ok', 'webhooks: an invalid value is a warning')
    H.ok(HasText('webhooks', 'Discord webhooks on: audit, operations. Off: board, builder'), 'the summary')
    H.ok(HasText('webhooks', 'cp_webhook_flags in server.cfg is not an https:// link'), 'the bad convar named')
    CP.Admin = nil

    -- the registry: modules add checks; a failing check is an error line; errors come first
    H.ok(Health.register('extra', function()
        return { { level = 'ok', text = 'fine' }, { level = 'bogus', text = 'x' } }
    end), 'register a check')
    H.ok(Health.register('broken', function() error('boom') end), 'and a broken one')
    H.eq(Health.register('', function() end), false, 'a check needs a name')
    local list = Health.run()
    H.eq(list[1].check, 'broken', 'a failing check is listed first (an error)')
    H.eq(list[1].level, 'error', 'as an error')
    H.eq(Levels('extra'), 'ok', 'lines of an unknown level are dropped')
    Health.register('broken', function() return { { level = 'warn', text = 'replaced' } } end)
    H.eq(Levels('broken'), 'warn', 'a second register of a name replaces the check')
    local seen = {}
    for _, item in ipairs(list) do
        H.ok(type(item.text) == 'string' and item.text ~= '' and not item.text:find('^health%.'),
            ('%s: a translated line'):format(item.check))
        seen[item.check] = true
    end
    for _, name in ipairs({
        'items',
        'desks',
        'colours',
        'tweaks',
        'locale',
        'avatars',
        'departments',
        'admins',
        'folder',
        'resources',
    }) do
        H.ok(seen[name], ('check %s listed'):format(name))
    end
    -- Admin UI → Permissions → Config health names each check by its label
    for _, c in ipairs(Health._checks()) do
        if not ({ extra = true, late = true, broken = true })[c.name] then
            H.ok(CP.Locale.has('access.health.check.' .. c.name), ('check %s has a label'):format(c.name))
        end
    end
end

do
    -- a new start (the module loaded again): the checks run 5 s later; each problem prints one line, then one line
    -- gives the counts, so a clean start is visible too
    local realDepartments = CP.Access.departments
    local function Start()
        local lines = {}
        local realPrint = print
        _G.print = function(...)
            local line = table.concat({ ... }, ' ')
            -- the start-up lines only (Config.Debug may add other modules' debug lines)
            if Contains(line, 'confighealth') or Contains(line, 'Start-up check') then lines[#lines + 1] = line end
        end
        H.load('modules/confighealth/server.lua')
        H.advance(4000)
        local early = #lines
        H.advance(1100)
        _G.print = realPrint
        return lines, early
    end
    CP.Access.departments = function()
        return { { key = 'sast', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3 } }
    end
    local lines, early = Start()
    H.eq(early, 0, 'nothing before 5 s')
    H.eq(#lines, 2, 'one problem: its line, then the summary')
    H.ok(Contains(lines[1], '^3[crimson-police:confighealth]^7 departments: Qbox gave no job list'), 'the problem')
    H.ok(Contains(lines[2], '^3[crimson-police:confighealth]^7 Start-up check: 1 warnings and 0 errors'),
        'then the counts, yellow')
    H.ok(Contains(lines[2], 'Type CrimsonPoliceAdmin check in the server console'), 'naming the check command')

    CP.Qbx = {
        getJobs = function()
            return { sast = { grades = { [0] = { name = 'Cadet' }, [3] = { name = 'Lieutenant' } } } }
        end,
    }
    _G.IsPrincipalAceAllowed = function(principal, ace)
        return principal == 'group.admin' and ace == 'crimsonpolice.admin'
    end
    lines = Start()
    H.eq(#lines, 1, 'nothing to fix: only the summary line')
    H.ok(Contains(lines[1], '[crimson-police] Start-up check: all ') and Contains(lines[1], 'checks passed'),
        'all checks passed: ' .. tostring(lines[1]))
    H.ok(not Contains(lines[1], '^3'), 'in the normal colour')
    _G.IsPrincipalAceAllowed, CP.Qbx = nil, nil
    CP.Access.departments = realDepartments
end

-- ============================================================================
--                                7. THE CLIENT
-- ============================================================================
-- Desk zones, the desk pose and distance watcher, the item watcher, the ways the client names and the arena.

H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })
local target = H.mockTarget()
local nui, keymaps, objects, deleted, scenarios, cleared = {}, {}, {}, {}, {}, 0
local nextObj = 5000
_G.SendNUIMessage = function(m) nui[#nui + 1] = m end
_G.SetNuiFocus = function() end
_G.RegisterNUICallback = function() end
_G.RegisterKeyMapping = function(cmd, desc, dev, key) keymaps[cmd] = { desc = desc, key = key } end
_G.PlayerPedId = function() return 42 end
local pedCoords = vec3(0.0, 0.0, 0.0)
_G.GetEntityCoords = function() return pedCoords end
_G.IsModelInCdimage = function() return true end
_G.RequestModel = function() end
_G.HasModelLoaded = function() return true end
_G.SetModelAsNoLongerNeeded = function() end
_G.CreateObject = function(model, x, y, z, net)
    nextObj = nextObj + 1
    objects[nextObj] = { model = model, net = net, coords = vec3(x, y, z) }
    return nextObj
end
_G.DoesEntityExist = function(e) return objects[e] ~= nil end
_G.DeleteEntity = function(e)
    deleted[#deleted + 1] = e
    objects[e] = nil
end
_G.DetachEntity = function() end
_G.SetEntityAsMissionEntity = function() end
_G.SetEntityCollision = function() end
_G.SetEntityHeading = function() end
_G.FreezeEntityPosition = function() end
_G.AttachEntityToEntity = function() end
_G.GetPedBoneIndex = function(_, b) return b end
_G.RequestAnimDict = function() end
_G.HasAnimDictLoaded = function() return true end
_G.RemoveAnimDict = function() end
local anims = 0
_G.TaskPlayAnim = function() anims = anims + 1 end
_G.IsEntityPlayingAnim = function() return true end
_G.StopAnimTask = function() end
_G.IsEntityDead = function() return false end
_G.IsPedInAnyVehicle = function() return false end
_G.TaskStartScenarioInPlace = function(_, name) scenarios[#scenarios + 1] = name end
local usingScenario = true
_G.IsPedUsingScenario = function() return usingScenario end
_G.ClearPedTasks = function() cleared = cleared + 1 end
_G.LocalPlayer = { state = { isLoggedIn = true } }
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 7 end
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, _, fn) bagHandlers[#bagHandlers + 1] = { key = key, fn = fn } end
local clientPD = { job = { name = 'sast', onduty = true, grade = { level = 3, name = 'Sergeant' } } }
H.exportsMock.qbx_core = {
    GetPlayerData = function() return clientPD end,
}
local itemCount = 1
H.exportsMock.ox_inventory = {
    Search = function(kind, name) return kind == 'count' and itemCount or nil end,
}

local sessionCalls = {}
lib.callback.await = function(name, _, args)
    if name ~= 'crimson-police:getSession' then return { ok = true, data = {} } end
    sessionCalls[#sessionCalls + 1] = args
    return {
        ok = true,
        data = {
            ui = args.ui,
            roles = { officer = true, supervisor = true, admin = false },
            officer = { citizenid = 'ACC1', name = 'A', department = 'sast', departmentShort = 'SAST' },
            theme = { primary = '#1f4e8c' },
            actions = {},
            config = {},
            access = { via = args.via, desk = args.desk },
        },
    }
end

Config.Tablet.item = 'crimson_police_tablet'
Config.Tablet.access = { command = true, keybind = true, item = true, desk = true, requireItem = false }
Config.Tablet.desks = {
    { label = 'Desk A', coords = vec3(100.0, 100.0, 30.0), size = vec3(2.0, 1.0, 1.0), rotation = 0.0 },
    {
        label = 'Desk B',
        coords = vec3(200.0, 200.0, 30.0),
        size = vec3(2.0, 1.0, 1.0),
        rotation = 90.0,
        departments = { 'fib' },
        prop = 'prop_laptop_01a',
    },
}

H.load('modules/integrations/qbx/client.lua')
H.load('modules/access/client.lua')
H.load('modules/tablet/client.lua')
local CT = CP.Tablet

local function LastOpen()
    for i = #nui, 1, -1 do if nui[i].type == 'open' then return nui[i] end end
    return nil
end
local function ZoneCount()
    local n = 0
    for _ in pairs(target.zones) do n = n + 1 end
    return n
end
local function DeskOption(i)
    local z = target.zones[CT.deskZones()[i]]
    return z and z.options[1]
end
local function PropCount()
    local n = 0
    for _ in pairs(objects) do n = n + 1 end
    return n
end
local function Arena(value)
    LocalPlayer.state.crimsonArena = value
    for _, h in ipairs(bagHandlers) do if h.key == 'crimsonArena' then h.fn('player:7', 'crimsonArena', value) end end
    H.advance(100, 50)
end
local function Close()
    CT.close()
    H.clockMs = H.clockMs + 1000
end

do
    -- zones and the laptop prop, created once
    H.eq(ZoneCount(), 2, 'one ox_target box per desk')
    local z1 = target.zones[CT.deskZones()[1]]
    H.eq(z1.coords.x, 100.0, 'at the desk coords')
    H.eq(z1.size.x, 2.0, 'with its size')
    H.eq(DeskOption(1).name, 'crimson-police:desk', 'option name crimson-police:desk')
    H.eq(DeskOption(1).label, CP.L('tablet.desk.open'), 'labelled Open Crimson-Police')
    H.eq(PropCount(), 1, 'desk B\'s laptop prop')
    local prop = select(2, next(objects))
    H.eq(prop.net, false, 'a local object only')
    H.eq(prop.model, joaat('prop_laptop_01a'), 'the configured model')
    Arena(nil)
    H.eq(ZoneCount(), 2, 'created once: a bag change without an arena adds none')
    H.eq(PropCount(), 1, 'nor a second prop')

    -- canInteract only shows; the server decides
    H.eq(DeskOption(1).canInteract(), true, 'desk A shows for sast')
    H.eq(DeskOption(2).canInteract(), false, 'desk B is for fib only')
    clientPD.job.onduty = false
    H.eq(DeskOption(1).canInteract(), false, 'off duty: hidden')
    clientPD.job.onduty = true
    LocalPlayer.state.crimsonArena = { active = true, matchId = 'm1' }
    H.eq(DeskOption(1).canInteract(), false, 'in Crimson-Arena: hidden')
    LocalPlayer.state.crimsonArena = nil

    -- opening at the desk: no handheld tablet, the standing scenario, closed beyond deskDistance
    pedCoords = vec3(101.0, 100.0, 30.0)
    DeskOption(1).onSelect()
    H.advance(200, 50)
    H.eq(CT.isOpen(), true, 'the desk opens the tablet')
    local args = sessionCalls[#sessionCalls]
    H.eq(args.via, 'desk', 'getSession names the desk way')
    H.eq(args.desk, 1, 'and its index')
    H.eq(DeskOption(1).canInteract(), false, 'the option hides while the tablet is open')
    H.eq(PropCount(), 1, 'no handheld tablet prop at a desk')
    H.eq(anims, 0, 'no tablet animation')
    H.eq(scenarios[#scenarios], 'PROP_HUMAN_ATM', 'the desk scenario plays')
    pedCoords = vec3(102.5, 100.0, 30.0)
    H.advance(1000, 100)
    H.eq(CT.isOpen(), true, '2.5 m from the desk: still open')
    pedCoords = vec3(103.5, 100.0, 30.0)
    H.advance(1000, 100)
    H.eq(CT.isOpen(), true, '3.5 m from the centre but 2.5 m from the desk box: still open')
    pedCoords = vec3(104.5, 100.0, 30.0)
    H.advance(1000, 100)
    H.eq(CT.isOpen(), false, 'beyond 3 m from the desk (Config.Tablet.deskDistance): closed')
    H.ok(cleared >= 1, 'the scenario is cleared')
    H.clockMs = H.clockMs + 1000

    -- the distance counts from the desk's box, so a long counter does not close the tablet at its own end
    Config.Tablet.desks[3] = {
        label = 'Counter',
        coords = vec3(300.0, 300.0, 30.0),
        size = vec3(1.0, 8.0, 1.0),
        rotation = 90.0,
    }
    pedCoords = vec3(300.0, 300.0, 30.0)
    CT.open('officer', { via = 'desk', desk = 3 })
    pedCoords = vec3(305.5, 300.0, 30.0)
    H.advance(1000, 100)
    H.eq(CT.isOpen(), true, 'turned counter: 5.5 m from its centre along its long side is 1.5 m from it')
    pedCoords = vec3(308.5, 300.0, 30.0)
    H.advance(1000, 100)
    H.eq(CT.isOpen(), false, 'and 4.5 m past its end closes the tablet')
    Config.Tablet.desks[3] = nil
    H.clockMs = H.clockMs + 1000

    -- the ways the client names
    H.commands.CrimsonPolice.fn()
    H.advance(100, 50)
    H.eq(sessionCalls[#sessionCalls].via, 'command', '/CrimsonPolice names the command')
    H.eq(PropCount(), 2, 'the handheld tablet prop elsewhere')
    Close()
    H.commands.crimsonpolice_tablet.fn()
    H.advance(100, 50)
    H.eq(sessionCalls[#sessionCalls].via, 'keybind', 'the key mapping names the keybind')
    Close()
    H.ok(keymaps.crimsonpolice_dispatch ~= nil, 'the crimsonpolice_dispatch key mapping is registered')
    H.eq(keymaps.crimsonpolice_dispatch.key, '', 'unbound by default (Config.Tablet.dispatchKey)')
    H.commands.crimsonpolice_dispatch.fn()
    H.advance(100, 50)
    H.eq(sessionCalls[#sessionCalls].via, 'dispatch', 'the Dispatch key names its way')
    H.eq(LastOpen().screen, 'dispatch', 'and opens on Dispatch')
    local opens = #sessionCalls
    H.commands.crimsonpolice_dispatch.fn()
    H.advance(100, 50)
    H.eq(#sessionCalls, opens, 'with the tablet open it only switches the screen')
    H.eq(LastOpen().screen, 'dispatch', 'to Dispatch')
    Close()
    CT.open('officer')
    H.eq(sessionCalls[#sessionCalls].via, 'export', 'another module opening it is the export way')
    Close()

    -- requireItem: the item leaves the inventory while the tablet is open
    Config.Tablet.access.requireItem = true
    H.commands.CrimsonPolice.fn()
    H.advance(100, 50)
    H.reset()
    H.advance(2500, 100)
    H.eq(#H.findEvents('crimson-police:server:tabletItemGone'), 0, 'the item is there: nothing reported')
    itemCount = 0
    H.advance(3500, 100)
    H.eq(#H.findEvents('crimson-police:server:tabletItemGone'), 1, 'the item is gone: reported to the server once')
    H.fire('crimson-police:client:closeTablet', nil, 'err.no_tablet_item')
    H.eq(CT.isOpen(), false, 'the server\'s closeTablet closes it')
    local toast = nui[#nui]
    H.eq(toast.type, 'notify', 'with a toast')
    H.eq(toast.notification.text, CP.L('err.no_tablet_item'), 'saying why')
    H.clockMs = H.clockMs + 1000
    pedCoords = vec3(100.5, 100.0, 30.0)
    DeskOption(1).onSelect()
    H.advance(200, 50)
    H.reset()
    H.advance(3000, 100)
    H.eq(#H.findEvents('crimson-police:server:tabletItemGone'), 0, 'at a desk the item is not watched')
    Close()
    Config.Tablet.access.requireItem = false
    itemCount = 1

    -- Crimson-Arena: zones and props go, and come back when it lets the player go
    Arena({ active = true, matchId = 'm1' })
    H.eq(ZoneCount(), 0, 'a foreign arena flag removes every desk zone')
    H.eq(#target.removed, 2, 'through ox_target removeZone')
    H.eq(PropCount(), 0, 'and the laptop prop')
    Arena({ active = true, source = 'crimson-police' })
    H.eq(ZoneCount(), 2, 'our own flag is not the arena: the zones are back')
    Arena({ active = true, matchId = 'm2' })
    Arena(nil)
    H.eq(ZoneCount(), 2, 'back after the arena, once')
    H.eq(PropCount(), 1, 'with the prop')

    -- resource stop
    for _, fn in ipairs(H.handlers.onResourceStop or {}) do fn('Crimson-Police') end
    H.eq(ZoneCount(), 0, 'the resource stop removes the zones')
    H.eq(PropCount(), 0, 'and the props')
    H.eq(CT.deskZones(), nil, 'none left')

    -- desks switched off: none are created
    Config.Tablet.access.desk = false
    Arena(nil)
    H.eq(ZoneCount(), 0, 'access.desk = false: no zones')
    Config.Tablet.access.desk = true
end

return H
