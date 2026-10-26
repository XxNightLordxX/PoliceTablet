-- Police vs real criminal players, step V1 (the owner's decision of 2026-10-26, "Build all 3 but options in the
-- config.lua"): the two master switches ship off and show in Admin UI → Settings, and the docs record the decision
-- without rewording RT1's start-route text.

local H = dofile('tests/harness.lua')

local function ReadRepo(rel)
    local f = io.open(H.root .. '../' .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- The bullet of a section that starts with "- <first words>" (one line in docs/SPEC.md).
local function Bullet(text, first)
    for line in (text or ''):gmatch('[^\n]+') do
        if line:sub(1, #first + 2) == '- ' .. first then return line end
    end
    return nil
end

local function Has(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

-- ============================================================================
--                      THE SWITCHES (config.lua, shipped)
-- ============================================================================

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
H.players[1] = { ace = { ['crimsonpolice.admin'] = true } }
CP.Access = {
    isAdmin = function(src) return src == 0 or src == 1 end,
    isSupervisor = function() return false end,
    getOfficer = function() return nil, 'err.not_police' end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = ('RSC%05d'):format(src), name = 'Admin ' .. src } end,
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

do
    H.eq(type(Config.LiveCrime), 'table', 'Config.LiveCrime exists')
    H.eq(type(Config.Volunteers), 'table', 'Config.Volunteers exists')
    H.eq(Config.LiveCrime and Config.LiveCrime.enabled, false, 'live crimes ship off')
    H.eq(Config.Volunteers and Config.Volunteers.enabled, false, 'volunteer suspects ship off')
end

-- ============================================================================
--                     ADMIN UI → SETTINGS (from the file)
-- ============================================================================

do
    local sc = S._schema()
    local order, byKey = {}, {}
    for i, sec in ipairs(sc.sections) do
        order[sec.key] = i
        byKey[sec.key] = sec
    end
    H.ok(order.live_crimes ~= nil and order.volunteer_suspects ~= nil, 'the two banners are Settings sections')
    H.ok(
        (order.dispatch or 0) < (order.live_crimes or 0) and (order.live_crimes or 0) < (order.volunteer_suspects or 0)
            and (order.volunteer_suspects or 0) < (order.police_actions_and_custody or 0),
        'right after Dispatch (mission calls), before Police actions and custody'
    )
    H.eq((byKey.live_crimes or {}).title, 'Live crimes (option A)', 'the live crimes title')
    H.eq((byKey.volunteer_suspects or {}).title, 'Volunteer suspects (options B and C)', 'the volunteers title')

    local function Section(key, group)
        local sec = byKey[key] or { groups = {} }
        for _, g in ipairs(sec.groups) do
            if g.path == group then
                local paths = {}
                for _, e in ipairs(g.settings) do paths[#paths + 1] = e.path end
                return g, paths
            end
        end
        return nil, {}
    end
    local g, paths = Section('live_crimes', 'LiveCrime')
    H.ok(g ~= nil and Has(g.desc, 'Crimson-Contracts reports once its police alert goes out'),
        'the comment under the banner describes Live crimes')
    H.ok(CP.U.contains(paths, 'LiveCrime.enabled'), 'its switch is in the group')
    g, paths = Section('volunteer_suspects', 'Volunteers')
    H.ok(g ~= nil and Has(g.desc, 'while every mode is \'npc\''), 'the comment under the banner describes Volunteers')
    H.ok(CP.U.contains(paths, 'Volunteers.enabled'), 'its switch is in the group')

    for path, desc in pairs({
        ['LiveCrime.enabled'] = 'true = reported crimes become LIVE calls on the Dispatch screen',
        ['Volunteers.enabled'] = 'true = players can volunteer with the command below',
    }) do
        local e = S.entry(path) or {}
        H.eq(e.kind, 'boolean', path .. ' is a switch')
        H.eq(e.default, false, path .. ' is off in config.lua')
        H.ok(type(e.desc) == 'string' and e.desc ~= '', path .. ' has a description')
        H.eq(e.desc, desc, path .. ': its trailing comment is the description')
        H.ok(not e.restart and not e.money, path .. ' needs no restart and is not a money switch')
    end
end

-- ============================================================================
--                         THE DOCS RECORD THE DECISION
-- ============================================================================

do
    local readme = ReadRepo('README.md')
    H.ok(Has(readme, 'Build all 3 but options in the config.lua'), 'README section 12 quotes the owner')
    H.ok(Has(readme, 'All three features ship off'), 'README says all three ship off')
    H.ok(Has(readme, '- Start route switch, at the owner\'s request of 2026-10-26'), 'RT1\'s README entry stays')

    local spec = ReadRepo('docs/SPEC.md')
    H.ok(spec ~= nil, 'docs/SPEC.md is readable')
    local route = Bullet(spec, 'Route to the start:')
    local switches = Bullet(spec, 'Rule switches:')
    -- RT1's sentences, word for word
    H.ok(Has(
        route,
        'The owner may switch this rule off (Config.Route.required = false, at the owner\'s request of '
            .. '2026-10-26): the route is still shown and checked for arrival, but leaving it never ends a run.'
    ), 'Route to the start keeps RT1\'s Config.Route.required text')
    H.ok(Has(
        switches,
        'Hard rule 17 (the start route) is the one exception: the owner made it switchable with '
            .. 'Config.Route.required (see that rule).'
    ), 'Rule switches keeps RT1\'s Config.Route.required text')
    H.ok(Has(route, 'Config.LiveCrime.requireRoute (shipped false) replaces Config.Route.required'),
        'Route to the start names the live-crime route option')
    H.ok(Has(route, 'Volunteer-suspect missions follow Config.Route.required.'), 'and the volunteers\' rule')
    H.ok(Has(switches, 'Config.LiveCrime.requireRoute sets the start-route rule for live crimes (shipped false)'),
        'Rule switches names the live-crime route option')
    H.ok(Has(switches, 'For NPC missions rules 15, 16 and 18 stay on.'), 'the NPC rules stay on')
    H.ok(Has(Bullet(spec, 'NPCs only:'), 'except live crimes (Config.LiveCrime) and volunteer suspects'),
        'NPCs only names the two exceptions')
    H.ok(Has(Bullet(spec, 'Real calls first:'), 'There are exactly three exceptions'), 'Real calls first: three')
    H.ok(Has(Bullet(spec, 'Mission choice:'), 'Only four exceptions exist'), 'Mission choice: four')

    local arch = ReadRepo('docs/ARCHITECTURE.md')
    for _, head in ipairs({
        '### 5.45 CP.Opponents',
        '### 5.46 CP.LiveCrime',
        '### 5.47 CP.Volunteers',
        '### 7.3 The `live_response` block',
    }) do
        H.ok(Has(arch, '\n' .. head), 'ARCHITECTURE has the stub ' .. head)
    end
end

return H
