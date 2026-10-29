-- Built-in location labels name the right place (step L4): renamed locations keep their old label in `aliases`,
-- so a Config.DisabledLocations or MissionTweaks entry written by the old label still matches; Traffic
-- Enforcement's two city corridors are posted at 60 km/h.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U

for _, b in ipairs({
    'checkpoint_route',
    'interact_points',
    'skill_check',
    'hostile_waves',
    'protect_rescue',
    'flee_arrest',
    'pursuit',
    'escort',
    'search_area',
    'field_contact',
    'process_scene',
}) do
    H.load('blocks/' .. b .. '/server.lua')
end
local realWarn = CP.warn
CP.warn = function() end
CP.Missions = nil
H.load('modules/missions/server.lua')
local Missions = CP.Missions
local summary = Missions.loadAll()
CP.warn = realWarn
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission (aliases is accepted)')

-- ============================================================================
--                   1. THE NEW LABELS, EACH WITH ITS OLD ONE
-- ============================================================================

local RENAMED = {
    parking_patrol = {
        [3] = { 'Mirror Park Boulevard and Vinewood Boulevard', 'Mirror Park Boulevard, Mirror Park' },
        [4] = { 'Prosperity Street, Vespucci Canals', 'Prosperity Street, Del Perro' },
    },
    pursuit_sim = { [5] = { 'La Puerta & Chamberlain Hills', 'Strawberry & Chamberlain Hills' } },
    traffic_enforcement = {
        [2] = { 'Senora Freeway, San Chianski Mountain Range', 'Senora Freeway, Grand Senora Desert' },
        [3] = { 'Bay City Incline, Pacific Bluffs', 'Del Perro Freeway, Pillbox Hill' },
        [4] = { 'Capital Boulevard, Rancho', 'Olympic Freeway, Strawberry' },
        [5] = { 'Palomino Freeway, Palomino Highlands', 'Palomino Freeway, Tataviam Mountains' },
        [7] = { 'Great Ocean Highway, Tongva Hills', 'Great Ocean Highway, Banham Canyon' },
    },
    suspicious_activity = {
        [3] = { 'Golf club lane, Rockford Hills', 'Car park, Rockford Hills' },
        [4] = { 'Lay-by, Ron Alternates Wind Farm', 'Truck stop, Grand Senora' },
        [5] = { 'Farm lot, Mount Chiliad', 'Farm lot, Grapeseed' },
    },
    drug_lab_raid = {
        [1] = { 'Cabin, Chiliad Mountain State Wilderness', 'Cabin, Raton Canyon' },
        [4] = { 'Shack, Fort Zancudo Approach Road', 'Shack, Lago Zancudo' },
    },
    gang_hideout_raid = {
        [1] = { 'Yard, El Burro Heights', 'Yard, Murrieta Heights' },
        [2] = { 'Dock warehouse, Elysian Island', 'Duplex, Elysian Island' },
        [3] = { 'Beach house, Vespucci Beach', 'House, Vespucci Canals' },
        [5] = { 'House, Vinewood Racetrack', 'House, East Vinewood' },
        [6] = { 'Compound, El Burro Heights', 'Compound, Tataviam foothills' },
    },
    weekly_boss_kingpin = {
        [1] = { 'La Fuente Blanca ranch, Vinewood Hills', 'La Fuente Blanca ranch, Tataviam foothills' },
    },
    bomb_disposal = {
        [5] = {
            '24/7 Supermarket, Senora Freeway (Mount Chiliad)',
            '24/7 Supermarket, Great Ocean Highway (Mount Chiliad)',
        },
    },
}

for id, list in pairs(RENAMED) do
    local def = Missions.get(id)
    H.ok(def ~= nil, id .. ': loaded')
    for i, want in pairs(def and list or {}) do
        local loc = def.locations[i] or {}
        H.eq(loc.label, want[1], ('%s #%d: the new label'):format(id, i))
        H.eq(type(loc.aliases) == 'table' and loc.aliases[1], want[2],
            ('%s #%d: the old label is its alias'):format(id, i))
    end
end

-- every built-in: labels unique in the mission; an alias is a string list naming no other location
for _, def in pairs(Missions.all and Missions.all() or {}) do
    if def.source == 'builtin' then
        local names = {}
        for i, loc in ipairs(def.locations or {}) do
            local all = { loc.label }
            for _, a in ipairs(type(loc.aliases) == 'table' and loc.aliases or {}) do all[#all + 1] = a end
            H.ok(loc.aliases == nil or (type(loc.aliases) == 'table' and #loc.aliases > 0),
                ('%s #%d: aliases is a list'):format(def.id, i))
            for _, n in ipairs(all) do
                H.ok(type(n) == 'string' and names[n] == nil,
                    ('%s #%d: "%s" names one location only'):format(def.id, i, tostring(n)))
                names[n] = i
            end
        end
    end
end
H.ok(Missions.all ~= nil, 'Missions.all lists the definitions')

-- ============================================================================
--                      2. TRAFFIC ENFORCEMENT CITY SPEEDS
-- ============================================================================

do
    local def = Missions.get('traffic_enforcement')
    local want = { 90, 110, 60, 60, 110, 90, 90 }
    local over = def.objectives[1].observe.over
    for i, s in ipairs(want) do
        H.eq(def.locations[i].speed, s, ('traffic_enforcement #%d: posted %d km/h'):format(i, s))
    end
    H.ok(60 + over[1] >= 80 and 60 + over[2] <= 105, 'the city violator does 80-105 km/h, not 120-145')
    local lab = Missions.get('drug_lab_raid').locations[4]
    H.ok(U.dist(lab.escapes[2][3], vec3(-1690.50, 2680.00, 2.88)) < 0.01, 'drug_lab_raid #4: escape 2 ends on the road')
end

-- ============================================================================
--                  3. A SWITCH SAVED BY THE OLD LABEL MATCHES
-- ============================================================================

do
    H.ok(U.isLocationName({ label = 'A', aliases = { 'B' } }, 'B'), 'U.isLocationName: an alias names it')
    H.ok(U.isLocationName({ label = 'A' }, 'A'), 'U.isLocationName: the label names it')
    H.ok(not U.isLocationName({ label = 'A', aliases = { 'B' } }, 'C'), 'U.isLocationName: another name does not')
    H.ok(not U.isLocationName(nil, 'A') and not U.isLocationName({ label = 'A' }, 1), 'U.isLocationName: bad input')
    local map = { traffic_enforcement = { 'Del Perro Freeway, Pillbox Hill' } }
    H.eq(Missions.isLocationEnabled('traffic_enforcement', 3, map), false, 'old label: #3 stays off')
    H.eq(Missions.isLocationEnabled('traffic_enforcement', 4, map), true, 'the others stay on')
    map = { traffic_enforcement = { 'Bay City Incline, Pacific Bluffs' } }
    H.eq(Missions.isLocationEnabled('traffic_enforcement', 3, map), false, 'new label: #3 off')

    local raw = { id = 'traffic_enforcement', locations = U.deepcopy(Missions.get('traffic_enforcement').locations) }
    local d, why = Missions._applyTweak(raw, { disabledLocations = { 'Olympic Freeway, Strawberry' } })
    H.ok(d ~= nil and #d.locations == 6, 'MissionTweaks disabledLocations by the old label: ' .. tostring(why))
    for _, loc in ipairs(d and d.locations or {}) do
        H.ok(loc.label ~= 'Capital Boulevard, Rancho', 'the tweak drops ' .. tostring(loc.label) .. ' only if it is #4')
    end
    local _, bad = Missions._applyTweak(raw, { disabledLocations = { 'Nowhere' } })
    H.ok(tostring(bad):find('unknown location', 1, true) ~= nil, 'an unknown label is still refused')
end

return H
