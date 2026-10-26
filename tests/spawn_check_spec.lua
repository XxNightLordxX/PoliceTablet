-- Check spawn points (PLAN S7; modules/testing server and client, each block's pointKinds): the server lists every

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true

local logs = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('crimson-police', 1, true) then
        logs[#logs + 1] = line
        return
    end
    realPrint(line)
end

local function LogsWith(text)
    local out = {}
    for _, l in ipairs(logs) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end

-- ============================================================================
--               STUBS OF THE MODULES OUTSIDE THE CHECK (server)
-- ============================================================================
-- players: 1 = admin, 2 = officer (no testRun), 3 = admin in the arena, 4 = admin on a run

local admins = { [1] = true, [3] = true, [4] = true }
for src = 1, 4 do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
CP.Permissions = {
    can = function(src, action)
        if admins[src] and action == 'testRun' then return true end
        return false, 'err.no_permission'
    end,
}
CP.Qbx = {
    getInfo = function(src) return { citizenid = 'CID' .. src, name = 'Player ' .. src, job = { name = 'sast' } } end,
}
CP.Alerts = {
    inArena = function(src) return src == 3 end,
}
CP.Runs = {
    isOnMission = function(src) return src == 4 end,
}
CP.Tablet = { notify = function() end, push = function() end }

local BLOCKS = {
    'checkpoint_route',
    'escort',
    'flee_arrest',
    'hostile_waves',
    'interact_points',
    'protect_rescue',
    'pursuit',
    'search_area',
    'skill_check',
    'field_contact',
    'process_scene',
}
for _, b in ipairs(BLOCKS) do H.load('blocks/' .. b .. '/server.lua') end
H.load('modules/scaling/server.lua')
H.load('modules/missions/server.lua')
H.step(0) -- CP.Missions.loadAll runs in its start thread
H.load('modules/testing/server.lua')
local T = CP.Testing
local Missions = CP.Missions

local VMT = getmetatable(vec3(0, 0, 0))
local function IsVec(v) return type(v) == 'table' and getmetatable(v) == VMT end
local SKIP = { label = true, start = true, medals = true }

-- Every vector of a location outside its label, start and medals (the file's points).
local function FilePoints(loc)
    local n = 0
    local function walk(v)
        if IsVec(v) then
            n = n + 1
        elseif type(v) == 'table' then
            for _, x in pairs(v) do walk(x) end
        end
    end
    for k, v in pairs(loc) do if not SKIP[k] then walk(v) end end
    return n
end

local function Points(id, index, src)
    return T.spawnPoints(src or 1, { missionId = id, location = index })
end

local function Row(view, id)
    for _, p in ipairs(view and view.points or {}) do if p.id == id then return p end end
    return nil
end

-- ============================================================================
--          1. EVERY POINT OF EVERY BUILT-IN, WITH WHAT APPEARS THERE
-- ============================================================================

do
    local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
    H.eq(#ids, 19, '19 built-in missions')
    local kinds, total, locations, untyped = {}, 0, 0, {}
    for _, id in ipairs(ids) do
        local def = Missions.get(id)
        if H.ok(def ~= nil, id .. ' loaded') then
            for li, loc in ipairs(def.locations) do
                locations = locations + 1
                local view, err = Points(id, li)
                if H.ok(type(view) == 'table', ('%s #%d listed (%s)'):format(id, li, tostring(err))) then
                    H.eq(#view.points, FilePoints(loc), ('%s #%d: every point of the file once'):format(id, li))
                    H.ok(type(view.start) == 'table' and view.start.r > 0, ('%s #%d: with its start'):format(id, li))
                    local seen = {}
                    for _, p in ipairs(view.points) do
                        H.ok(not seen[p.id], ('%s #%d: %s listed once'):format(id, li, p.id))
                        seen[p.id] = true
                        kinds[p.kind] = (kinds[p.kind] or 0) + 1
                        total = total + 1
                        if p.obj == false then untyped[#untyped + 1] = ('%s #%d %s'):format(id, li, p.id) end
                        H.ok(type(p.above) == 'table' and p.above[1] < p.above[2],
                            ('%s #%d %s: the height it should have over the ground'):format(id, li, p.id))
                    end
                    -- every key an objective needs (the Builder's requiredPoints) is listed by what it holds
                    for oi, o in ipairs(def.objectives) do
                        local impl = CP.Blocks.get(o.block)
                        for _, key in ipairs(impl.requiredPoints(o)) do
                            local any = nil
                            for _, p in ipairs(view.points) do
                                if p.key == key or p.key:match('^(.-)#%d+$') == key then any = p end
                            end
                            if type(loc[key]) == 'table' then
                                H.ok(any ~= nil and any.obj ~= false,
                                    ('%s #%d objective %d (%s): its %s points know what they hold'):format(id, li, oi,
                                        o.block, key))
                            end
                        end
                    end
                end
            end
        end
    end
    H.eq(locations, 104, '104 built-in locations')
    -- 2199 before S21, which added 3 runner points at each of the 7 hideouts, 2 cook points at each of the 7 labs and
    -- 2 inmate points at Prison Break's south-west fence
    H.eq(total, 2236, 'the 2236 points of the built-in files')
    H.eq(#untyped, 0, 'every point is used by an objective: ' .. table.concat(untyped, ', '))
    H.ok(kinds.ped > 0 and kinds.vehicle > 0 and kinds.prop > 0 and kinds.marker > 0 and kinds.path > 0,
        'people, vehicles, objects, markers and paths')
end

-- What each key of each built-in holds. Cross-checked once against the spawn audit (gameplay a1 rows.json, 858
-- rows): its 773 rows at a point of a file are all listed here with the same kind (its 'clue' = an object), the other
-- 85 are places the blocks work out at run time from these points (ambush cars beside their point, a race car 200 m
-- along the route, extra runners around a point), which the check cannot visit before a run.
local EXPECTED = {
    beat_patrol = { checkpoints = 'marker' },
    business_check = { doors = 'marker' },
    street_race_bust = { route = 'path', spawns = 'vehicle' },
    parking_patrol = { spots = 'vehicle' },
    traffic_enforcement = { route = 'path' },
    evoc_course = { checkpoints = 'marker' },
    pursuit_sim = { route = 'path', spawn = 'vehicle' },
    stolen_vehicle_takedown = { route = 'path', spawn = 'vehicle' },
    warrant_service = { associates = 'ped', door = 'marker', fleeTo = 'path', suspect = 'ped', yard = 'marker' },
    manhunt = { center = 'marker', clues = 'prop', hiding = 'ped' },
    suspicious_activity = { car = 'vehicle', fleeTo = 'path', people = 'ped', transport = 'vehicle' },
    gang_shootout = { scene = 'marker', spawns = 'ped' },
    hostage_rescue = { hostages = 'ped', safe = 'marker', spawns = 'ped' },
    bomb_disposal = { hiding = 'prop' },
    armored_truck_escort = { ambushPoints = 'vehicle', route = 'path' }, -- the truck at route[1]: a vehicle
    prison_break = { routes = 'path', spawns = 'ped' },
    drug_lab_raid = {
        cook = 'ped',
        coroner = 'vehicle',
        entries = 'marker',
        escapes = 'path',
        inside = 'ped',
        lab = 'marker',
        scene = 'marker',
        stashes = 'marker',
        yard = 'ped',
    },
    gang_hideout_raid = {
        caches = 'marker',
        coroner = 'vehicle',
        entries = 'marker',
        escapes = 'path',
        front = 'ped',
        garage = 'ped',
        house = 'ped',
        lieutenant = 'ped',
        runners = 'ped',
        scene = 'marker',
    },
    weekly_boss_kingpin = { boss = 'ped', scene = 'marker', spawns = 'ped' },
}

do
    local wrong, keys = {}, {}
    for id, expect in pairs(EXPECTED) do
        local def = Missions.get(id)
        for li in ipairs(def and def.locations or {}) do
            for _, p in ipairs(Points(id, li).points) do
                local base = p.key:match('^(.-)#%d+$') or p.key
                keys[id .. '.' .. base] = true
                local want = expect[base]
                if id == 'armored_truck_escort' and base == 'route' and p.i == 1 then want = 'vehicle' end
                if p.kind ~= want then
                    wrong[#wrong + 1] = ('%s #%d %s: %s, not %s'):format(id, li, p.id, tostring(p.kind), tostring(want))
                end
            end
        end
        for base in pairs(expect) do
            H.ok(keys[id .. '.' .. base], ('%s: its %s points are listed'):format(id, base))
        end
    end
    H.eq(#wrong, 0, 'every point of every built-in holds what the mission puts there: ' .. table.concat(wrong, '; '))
end

-- the spawn audit's cases, point by point
do
    -- a1 4.2: Gang Shootout #4 spawns[7] half a metre under the yard
    local v = Points('gang_shootout', 4)
    local p = Row(v, 'spawns[7]')
    H.ok(p ~= nil and p.kind == 'ped' and p.as == 'ped' and p.wall == true, 'gang_shootout #4 spawns[7]: a person')
    H.ok(p and p.x == 1153.75 and p.y == -3169.5 and p.z == 5.88, 'at the file\'s coordinates')
    H.ok(p and p.obj == 1 and p.block == 'hostile_waves', 'of objective 1 (hostile_waves)')
    H.ok(p and p.above[1] == -0.3 and p.above[2] == 1.6, 'a person fits from 0.3 m under to 1.6 m over the ground')
    H.ok(p and type(p.dStart) == 'number' and p.dPrevious == nil, 'its distance to the start; no objective before')
    H.ok(Row(v, 'scene[1]').kind == 'marker' and Row(v, 'scene[1]').wall == false,
        'the scene marker: an officer stands there (no wall check: a door may stand in the space)')

    -- Street Race Bust: the racers' grid and the race route
    v = Points('street_race_bust', 2)
    p = Row(v, 'spawns[1]')
    H.ok(p and p.kind == 'vehicle' and p.as == 'vehicle' and p.wall == true, 'street_race_bust #2 spawns[1]: a vehicle')
    H.ok(p and type(p.model) == 'string', 'with a model for its size')
    H.ok(p and p.above[1] == -0.2 and p.above[2] == 1.5, 'a vehicle fits from 0.2 m under to 1.5 m over the ground')
    H.eq(Row(v, 'route[1]').kind, 'path', 'the race route is a path')

    -- Armored Truck Escort: the truck at its route's first point, facing along it
    v = Points('armored_truck_escort', 1)
    p = Row(v, 'route[1]')
    H.ok(p and p.kind == 'vehicle' and p.model == 'stockade', 'the truck (stockade) at route[1]')
    H.ok(p and type(p.h) == 'number' and p.h >= 0 and p.h < 360, 'facing the route\'s next point')
    H.eq(Row(v, 'route[2]').kind, 'path', 'the rest of the route is a path')
    H.eq(Row(v, 'ambushPoints[1]').kind, 'vehicle', 'the ambush cars')

    -- Warrant Service: the door is a marker, the suspect and his associates people, the flee route a path
    v = Points('warrant_service', 1)
    H.eq(Row(v, 'door[1]').kind, 'marker', 'the door: a marker')
    H.eq(Row(v, 'suspect[1]').kind, 'ped', 'the suspect: a person')
    H.eq(Row(v, 'associates[1]').kind, 'ped', 'his associates: people')
    H.eq(Row(v, 'fleeTo[1]').kind, 'path', 'where he runs: a path')
    H.eq(Row(v, 'yard[1]').kind, 'marker', 'the yard: the follow-up markers')

    -- Suspicious Activity: the scene car, its people, the prisoner van's stand-by spot
    v = Points('suspicious_activity', 1)
    H.eq(Row(v, 'car[1]').kind, 'vehicle', 'the scene car')
    H.eq(Row(v, 'people[1]').kind, 'ped', 'the scene\'s people')
    H.eq(Row(v, 'transport[1]').kind, 'vehicle', 'the prisoner van\'s spot')

    -- Manhunt: fugitives hide (people), clues are objects, the search centre a marker
    v = Points('manhunt', 1)
    H.eq(Row(v, 'hiding[1]').kind, 'ped', 'a fugitive\'s hiding spot')
    H.eq(Row(v, 'clues[1]').kind, 'prop', 'a clue')
    H.ok(Row(v, 'clues[1]').as == 'prop' and Row(v, 'clues[1]').wall == false, 'an object: no wall check')
    H.eq(Row(v, 'center[1]').kind, 'marker', 'the search centre')

    -- a hidden device is an object, a stash to seize only a marker
    H.eq(Row(Points('bomb_disposal', 1), 'hiding[1]').kind, 'prop', 'Bomb Disposal: the device is an object')
    v = Points('drug_lab_raid', 1)
    H.eq(Row(v, 'stashes[1]').kind, 'marker', 'Drug Lab Raid: stashes to seize are markers')
    H.eq(Row(v, 'inside[1]').kind, 'ped', 'the crew inside')
    H.eq(Row(v, 'coroner[1]').kind, 'vehicle', 'the coroner van\'s spot')
    H.eq(Row(v, 'escapes#1[1]').kind, 'path', 'an escape route (a list of routes) is a path')
    -- the cook (objective 3) appears where the officers stand after the fight (objective 2)
    p = Row(v, 'cook[1]')
    H.ok(p and p.obj == 3 and type(p.dPrevious) == 'number', 'the cook: his distance to the fight\'s points')
    local nearest = math.huge
    for _, q in ipairs(v.points) do
        if q.key == 'inside' or q.key == 'yard' then
            nearest = math.min(nearest, math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2))
        end
    end
    H.near(p.dPrevious, nearest, 0.05, 'the nearest point the fight uses')
    H.ok((p.dPrevious < 40) == (p.near ~= nil and p.near[#p.near] == 'previous'),
        'near the objective before: closer than Config.Spawning.minDistance')

    -- a person closer to the start than Config.Spawning.minDistance is noted (information)
    local saved = Config.Spawning.minDistance
    Config.Spawning.minDistance = 10000.0
    p = Row(Points('gang_shootout', 4), 'spawns[7]')
    H.ok(p and p.near and p.near[1] == 'start', 'near the start: noted')
    Config.Spawning.minDistance = 0.0
    p = Row(Points('gang_shootout', 4), 'spawns[7]')
    H.eq(p and p.near, nil, 'not near anything: no note')
    Config.Spawning.minDistance = saved
end

-- ============================================================================
--                     2. WHO MAY ASK, AND THE MISSION LIST
-- ============================================================================

local function Ask(src, args)
    H.clockMs = H.clockMs + 1000
    return H.callback('crimson-police:server:test:spawnPoints', src, args)
end

do
    local res = Ask(1, {})
    H.eq(res.ok, true, 'the callback answers an admin')
    local list = res.data.missions
    H.eq(#list, 19, 'no mission asked: every mission the loader has')
    local n = 0
    for _, m in ipairs(list) do n = n + #m.locations end
    H.eq(n, 104, 'with their locations')
    H.eq(list[1].locations[1].index, 1, 'each location by its index')
    res = Ask(1, { missionId = 'manhunt' })
    H.ok(#res.data.missions == 1 and res.data.missions[1].id == 'manhunt' and #res.data.missions[1].locations == 5,
        'one mission: its locations')
    res = Ask(1, { missionId = 'manhunt', location = 2 })
    H.ok(res.ok and res.data.location == 2 and #res.data.points > 0 and res.data.locationLabel ~= nil,
        'one location: its points')

    res = Ask(2, {})
    H.eq(res.error, 'err.no_permission', 'an officer without testRun is refused')
    res = Ask(3, { missionId = 'manhunt', location = 1 })
    H.eq(res.error, 'err.in_arena', 'an admin in the arena is refused (his game would move him)')
    res = Ask(4, { missionId = 'manhunt', location = 1 })
    H.eq(res.error, 'err.spawn_check_on_run', 'an admin on a run is refused')
    res = Ask(1, { missionId = 'nope' })
    H.eq(res.error, 'err.test_unknown_mission', 'an unknown mission')
    res = Ask(1, { missionId = 'manhunt', location = 6 })
    H.eq(res.error, 'err.invalid_location', 'a location the mission does not have')

    Config.Testing.spawnCheck.enabled = false
    res = Ask(1, {})
    H.eq(res.error, 'err.spawn_check_disabled', 'Config.Testing.spawnCheck.enabled = false: refused')
    Config.Testing.spawnCheck.enabled = true
    Config.Testing.enabled = false
    res = Ask(1, {})
    H.eq(res.error, 'err.spawn_check_disabled', 'test mode off: refused too')
    Config.Testing.enabled = true

    H.eq(Config.Testing.spawnCheck.sceneTimeoutMs, 8000, 'config.lua: 8 s for the map to load')
    H.eq(Config.Testing.spawnCheck.moveWithin, 150.0, 'config.lua: moved over points further than 150 m')
    H.eq(Config.Testing.spawnCheck.routes, false, 'config.lua: route points are not checked unless asked')
end

-- "Teleport here" next to a result (PLAN S8): one point by its id, with the server's own coordinates, audited
do
    logs = {}
    local audits = {}
    CP.Admin = {
        audit = function(...) audits[#audits + 1] = table.pack(...) end,
    }
    H.eq(Config.Testing.spawnCheck.teleport, true, 'config.lua: Teleport here is on')
    local res = Ask(1, { missionId = 'gang_shootout', location = 4, point = 'spawns[7]' })
    H.eq(res.ok, true, 'one point of a location')
    local p = res.ok and res.data.point or {}
    H.ok(res.ok and res.data.missionId == 'gang_shootout' and res.data.location == 4 and res.data.points == nil,
        'only that point, not the whole location')
    H.ok(p.id == 'spawns[7]' and p.x == 1153.75 and p.y == -3169.5 and p.z == 5.88 and p.kind == 'ped',
        'with the file\'s own coordinates')
    H.eq(#audits, 1, 'the teleport is audited')
    local a = audits[1] or {}
    H.ok(
        a[1] == 1 and a[3] == 'audit' and a[4] == 'testControl' and a[5] == 'gang_shootout#4'
            and a[7] == 'teleport spawns[7]',
        'who, where and which point: ' .. tostring(a[5]) .. ' ' .. tostring(a[7])
    )
    local lines = LogsWith('teleports to gang_shootout#4 spawns[7] (1153.75, -3169.50, 5.88)')
    H.eq(#lines, 1, 'and written to the console')

    res = Ask(1, { missionId = 'gang_shootout', location = 4, point = 'spawns[99]' })
    H.eq(res.error, 'err.invalid_payload', 'a point the location does not have')
    res = Ask(1, { missionId = 'gang_shootout', location = 4, point = 7 })
    H.eq(res.error, 'err.invalid_payload', 'a point id that is no text')
    res = Ask(1, { missionId = 'gang_shootout', location = 4, point = ('x'):rep(65) })
    H.eq(res.error, 'err.invalid_payload', 'a point id too long')
    res = Ask(2, { missionId = 'gang_shootout', location = 4, point = 'spawns[7]' })
    H.eq(res.error, 'err.no_permission', 'an officer without testRun is refused')
    res = Ask(3, { missionId = 'gang_shootout', location = 4, point = 'spawns[7]' })
    H.eq(res.error, 'err.in_arena', 'an admin in the arena is refused')
    res = Ask(4, { missionId = 'gang_shootout', location = 4, point = 'spawns[7]' })
    H.eq(res.error, 'err.spawn_check_on_run', 'an admin on a run is refused')
    Config.Testing.spawnCheck.teleport = false
    res = Ask(1, { missionId = 'gang_shootout', location = 4, point = 'spawns[7]' })
    H.eq(res.error, 'err.spawn_check_teleport_disabled', 'Config.Testing.spawnCheck.teleport = false: refused')
    res = Ask(1, { missionId = 'gang_shootout', location = 4 })
    H.ok(res.ok and #res.data.points > 0, 'the check itself still lists the points')
    Config.Testing.spawnCheck.teleport = true
    H.eq(#audits, 1, 'a refused teleport is not audited')
    CP.Admin = nil
end

-- ============================================================================
--                        3. THE REPORT OF ONE LOCATION
-- ============================================================================

do
    logs = {}
    local function Report(src, payload)
        H.clockMs = H.clockMs + 1000
        H.reset()
        H.fire('crimson-police:server:test:spawnCheckReport', src, payload, 'r1')
        local e = H.findEvents('crimson-police:client:actionResult')[1]
        return e and e.args[2], e and e.args[3]
    end
    local ok, data = Report(1, {
        missionId = 'gang_shootout',
        location = 4,
        results = {
            -- the game's own coordinates are never used
            { id = 'spawns[7]', status = 'underground', groundZ = 6.4, dz = -0.52, seen = true, x = 0, y = 0, z = 0 },
            { id = 'spawns[1]', status = 'ok', groundZ = 5.0, dz = 1.0, seen = false },
            { id = 'scene[1]', status = 'snap', groundZ = 4.1, dz = 1.75 },
        },
    })
    H.eq(ok, true, 'the report is taken')
    H.ok(type(data) == 'table' and data.checked == 3 and data.bad == 2, 'three checked, two to look at')
    local lines = LogsWith('spawn check: gang_shootout #4 spawns[7]')
    H.eq(#lines, 1, 'one console line for the point under the ground')
    H.ok(
        lines[1]
            and lines[1]:find(
                    'spawn check: gang_shootout #4 spawns[7] (1153.75, -3169.50, 5.88) UNDERGROUND ground 6.40 (-0.52) [ped',
                    1,
                    true
                )
                ~= nil,
        'with where it is, what is wrong and the ground under it: ' .. tostring(lines[1])
    )
    H.ok(lines[1] and lines[1]:find('seen from the start', 1, true) ~= nil, 'and that the start sees it')
    H.eq(#LogsWith('spawns[1]'), 0, 'no line for a point that is right')
    lines = LogsWith('scene[1]')
    H.ok(#lines == 1 and lines[1]:find('HEIGHT OFF ground 4.10 (+1.75) [marker]', 1, true) ~= nil,
        'a point the game could put on the ground: its own line')
    local problems = CP.Problems.list({ tag = 'spawncheck' })
    H.ok(#problems >= 2 and problems[#problems].level == 'warn', 'the lines are in Admin UI -> System -> Problems')

    local reports = T.spawnReports()
    H.eq(#reports, 1, 'the report is kept')
    local r = reports[1]
    H.ok(r.missionId == 'gang_shootout' and r.location == 4 and r.checked == 3 and r.bad == 2 and r.by == 'Player 1',
        'which location, how many points, how many bad, by whom')
    H.ok(r.points[1].x == 1153.75 and r.points[1].status == 'underground' and r.points[1].seen == true,
        'each point with the server\'s coordinates and the game\'s answer')

    -- what the server refuses
    ok, data = Report(2, { missionId = 'gang_shootout', location = 4, results = {} })
    H.eq(data, 'err.no_permission', 'an officer cannot report')
    ok, data = Report(1,
        { missionId = 'gang_shootout', location = 4, results = { { id = 'spawns[99]', status = 'ok' } } })
    H.eq(data, 'err.invalid_payload', 'a point the location does not have')
    ok, data = Report(1,
        { missionId = 'gang_shootout', location = 4, results = { { id = 'spawns[1]', status = 'lava' } } })
    H.eq(data, 'err.invalid_payload', 'a status the probe never gives')
    ok, data = Report(1, {
        missionId = 'gang_shootout',
        location = 4,
        results = { { id = 'spawns[1]', status = 'ok' }, { id = 'spawns[1]', status = 'ok' } },
    })
    H.eq(data, 'err.invalid_payload', 'one point twice')
    ok, data = Report(1, { missionId = 'gang_shootout', location = 9, results = {} })
    H.eq(data, 'err.invalid_location', 'a location the mission does not have')
    ok, data = Report(1, {
        missionId = 'gang_shootout',
        location = 4,
        results = { { id = 'spawns[2]', status = 'floating', groundZ = 0 / 0, dz = 1e300 } },
    })
    H.eq(ok, true, 'a height that is no number')
    r = T.spawnReports()[1]
    H.ok(r.points[1].groundZ == nil and r.points[1].dz == nil, 'is kept as no height')
    H.eq(#T.spawnReports(), 1, 'a new report of the same location replaces the old one')
end

print = realPrint

-- ============================================================================
--                      4. THE ADMIN'S GAME (client half)
-- ============================================================================

H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })

local PED = 100
local game = {
    coords = vec3(-50.0, 20.0, 30.0),
    heading = 90.0,
    frozen = false,
    visible = true,
    invincible = false,
    inVehicle = false,
    dead = false,
    sceneLoadedAfter = 2, -- frames
    typeErrors = 0,
}
local calls = {}
local function Rec(name, ...) calls[#calls + 1] = { name = name, args = table.pack(...) } end
local function Float(name, ...)
    for i = 1, select('#', ...) do
        local v = select(i, ...)
        if type(v) == 'number' and math.type(v) ~= 'float' then
            game.typeErrors = game.typeErrors + 1
            H.ok(false, ('%s argument %d: the game reads a float, got %s'):format(name, i, tostring(v)))
        end
    end
end
_G.PlayerPedId = function() return PED end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.LocalPlayer = { state = {} }
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, bag, fn) bagHandlers[#bagHandlers + 1] = { key = key, fn = fn } end
_G.RegisterKeyMapping = function() end
_G.GetControlInstructionalButton = function() return 't_F7' end
_G.SetNuiFocus = function() end
_G.GetEntityCoords = function() return game.coords end
_G.GetEntityHeading = function() return game.heading end
_G.IsEntityPositionFrozen = function() return game.frozen end
_G.IsEntityVisible = function() return game.visible end
_G.GetPlayerInvincible = function() return game.invincible end
_G.IsPedInAnyVehicle = function() return game.inVehicle end
_G.IsEntityDead = function() return game.dead end
_G.FreezeEntityPosition = function(e, on)
    Rec('FreezeEntityPosition', e, on)
    game.frozen = on
end
_G.SetEntityVisible = function(e, on, unk)
    Rec('SetEntityVisible', e, on, unk)
    game.visible = on
end
_G.SetEntityInvincible = function(e, on)
    Rec('SetEntityInvincible', e, on)
    game.invincible = on
end
_G.SetEntityCoords = function(e, x, y, z, a, b, c, d)
    Float('SetEntityCoords', x, y, z)
    Rec('SetEntityCoords', e, x, y, z)
    game.coords = vec3(x, y, z)
end
_G.SetEntityHeading = function(e, h)
    Float('SetEntityHeading', h)
    Rec('SetEntityHeading', e, h)
    game.heading = h
end
_G.DoScreenFadeOut = function(ms) Rec('DoScreenFadeOut', ms) end
_G.DoScreenFadeIn = function(ms) Rec('DoScreenFadeIn', ms) end
_G.IsScreenFadedOut = function() return true end
local sceneAt = nil
_G.NewLoadSceneStartSphere = function(x, y, z, r, p4)
    Float('NewLoadSceneStartSphere', x, y, z, r)
    Rec('NewLoadSceneStartSphere', x, y, z, r, p4)
    sceneAt = H.clockMs
    return true
end
_G.IsNewLoadSceneLoaded = function() return sceneAt ~= nil and H.clockMs >= sceneAt + game.sceneLoadedAfter * 16 end
_G.NewLoadSceneStop = function()
    Rec('NewLoadSceneStop')
    sceneAt = nil
end

local nuiPushes, clientActions = {}, {}
CP.Tablet = {
    isOpen = function() return true end,
    push = function(topic, data) nuiPushes[#nuiPushes + 1] = { topic = topic, data = CP.U.deepcopy(data) } end,
    notify = function() end,
    hud = function() end,
    registerClientAction = function(name, fn) clientActions[name] = fn end,
}
local currentRun = nil
CP.Runs = {
    current = function() return currentRun end,
}

-- the server: two locations of one mission; location 1 has a person by the start, a vehicle 400 m away, a marker and
-- a route point
local LOCATIONS = {
    [1] = {
        missionId = 'demo',
        missionLabel = 'Demo',
        location = 1,
        locationLabel = 'Docks',
        start = { x = 100.0, y = 200.0, z = 30.0, r = 60.0 },
        points = {
            {
                id = 'spawns[1]',
                key = 'spawns',
                i = 1,
                kind = 'ped',
                as = 'ped',
                wall = true,
                x = 110.0,
                y = 210.0,
                z = 30.0,
                h = 90.0,
                obj = 1,
                above = { -0.3, 1.6 },
            },
            {
                id = 'spot[1]',
                key = 'spot',
                i = 1,
                kind = 'vehicle',
                as = 'vehicle',
                wall = true,
                model = 'sultan',
                x = 500.0,
                y = 200.0,
                z = 20.0,
                h = 0.0,
                obj = 1,
                above = { -0.2, 1.5 },
            },
            {
                id = 'door[1]',
                key = 'door',
                i = 1,
                kind = 'marker',
                as = 'ped',
                wall = false,
                x = 501.0,
                y = 201.0,
                z = 20.0,
                obj = 2,
                above = { -0.3, 1.6 },
            },
            {
                id = 'route[1]',
                key = 'route',
                i = 1,
                kind = 'path',
                as = 'ped',
                wall = false,
                x = 900.0,
                y = 200.0,
                z = 20.0,
                obj = 2,
                above = { -0.3, 1.6 },
            },
        },
    },
    [2] = {
        missionId = 'demo',
        missionLabel = 'Demo',
        location = 2,
        locationLabel = 'Yard',
        start = { x = 1000.0, y = 1000.0, z = 10.0, r = 50.0 },
        points = {
            {
                id = 'spawns[1]',
                key = 'spawns',
                i = 1,
                kind = 'ped',
                as = 'ped',
                wall = true,
                x = 1010.0,
                y = 1000.0,
                z = 10.0,
                obj = 1,
                above = { -0.3, 1.6 },
            },
        },
    },
}
local requests, actions = {}, {}
local refuseLocation = nil
CP.Net.request = function(name, args)
    requests[#requests + 1] = { name = name, args = CP.U.deepcopy(args) }
    if name ~= 'server:test:spawnPoints' then return { ok = false, error = 'err.unknown' } end
    if args.location == nil then
        return {
            ok = true,
            data = {
                missions = {
                    {
                        id = 'demo',
                        label = 'Demo',
                        locations = { { index = 1, label = 'Docks' }, { index = 2, label = 'Yard' } },
                    },
                },
            },
        }
    end
    if refuseLocation then return { ok = false, error = refuseLocation } end
    return { ok = true, data = CP.U.deepcopy(LOCATIONS[args.location]) }
end
CP.Net.action = function(name, payload)
    actions[#actions + 1] = { name = name, payload = CP.U.deepcopy(payload) }
    return { ok = true, data = {} }
end

-- modules/integrations/qbx loads first, as the fxmanifest's modules/**/client.lua glob does (its logout listener)
H.load('modules/integrations/qbx/client.lua')
H.load('modules/testing/client.lua')
H.step(0) -- the action registration thread

-- the ground probe and the sight check (modules/spawn/client.lua) answer from these
local probes, asks = {}, {}
local probeStatus = { ['spawns[1]'] = 'ok', ['spot[1]'] = 'underground', ['door[1]'] = 'snap', ['route[1]'] = 'ok' }
local onProbe = nil
CP.Spawn = {
    probe = function(kind, x, y, z, h, model, opts)
        probes[#probes + 1] = { kind = kind, x = x, y = y, z = z, h = h, model = model, opts = opts, at = game.coords }
        Wait(0)
        if onProbe then onProbe(#probes) end
        for _, loc in pairs(LOCATIONS) do
            for _, p in ipairs(loc.points) do
                if p.x == x and p.y == y then
                    return { status = probeStatus[p.id], groundZ = z - 1.0, dz = 1.0, z = z }
                end
            end
        end
        return { status = 'no_ground' }
    end,
    visible = function(points, ms)
        asks[#asks + 1] = { points = CP.U.deepcopy(points), ms = ms, at = game.coords }
        local out = {}
        for k in ipairs(points) do out[k] = k ~= 1 end
        return out
    end,
}

local function Pushes(state)
    local out = {}
    for _, p in ipairs(nuiPushes) do
        if p.topic == 'spawnCheck' and p.data.state == state then out[#out + 1] = p.data end
    end
    return out
end
local function Called(name)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name then out[#out + 1] = c.args end end
    return out
end
local function RunToEnd()
    local check = CP.Testing._spawnCheck()
    for _ = 1, 5000 do
        if not check.running then return true end
        H.step(16)
    end
    return false
end
local function Reset()
    calls, probes, asks, nuiPushes, requests, actions = {}, {}, {}, {}, {}, {}
    game.coords, game.heading, game.frozen, game.visible, game.invincible =
        vec3(-50.0, 20.0, 30.0), 90.0, false, true, false
end

do
    H.ok(clientActions.spawnCheck ~= nil and clientActions.spawnCheckStop ~= nil,
        'client actions spawnCheck and spawnCheckStop')

    -- one location
    Reset()
    local ok, data = clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    H.eq(ok, true, 'the check starts')
    H.ok(data.started and data.missions == 1 and data.locations == 1, 'one mission, one location')
    H.ok(RunToEnd(), 'and ends')
    H.eq(#Pushes('started'), 1, 'the NUI hears it started')
    local loc = Pushes('location')[1]
    H.ok(loc and loc.missionId == 'demo' and loc.location == 1 and loc.points == 4 and loc.locationLabel == 'Docks',
        'then which location and how many points')
    local done = Pushes('done')[1]
    H.ok(done and done.totals.points == 4 and done.totals.bad == 2 and done.totals.locations == 1,
        'then that it is done: 4 points, 2 to look at')

    -- he is hidden first: frozen, unseen, unhurt, then at the start with the map loaded around him
    local f = Called('FreezeEntityPosition')
    H.ok(f[1] and f[1][1] == PED and f[1][2] == true, 'frozen')
    local vis = Called('SetEntityVisible')
    H.ok(vis[1] and vis[1][2] == false, 'unseen')
    local inv = Called('SetEntityInvincible')
    H.ok(inv[1] and inv[1][2] == true, 'unhurt')
    local moves = Called('SetEntityCoords')
    H.ok(moves[1] and moves[1][2] == 100.0 and moves[1][3] == 200.0, 'then at the start')
    H.eq(moves[1][4], 31.0, 'standing on it: his root 1 m over the start\'s ground, like an officer stood there')
    local scenes = Called('NewLoadSceneStartSphere')
    H.ok(scenes[1] and scenes[1][1] == 100.0 and scenes[1][4] == 200.0, 'the map loads 200 m around the start')
    H.ok(#Called('NewLoadSceneStop') == #scenes, 'every scene load is stopped')
    H.eq(game.typeErrors, 0, 'every coordinate reaches the game as a decimal')

    -- what his game sees from the start: only where something appears, within 200 m
    H.eq(#asks, 1, 'one sight check')
    H.ok(asks[1] and #asks[1].points == 1 and asks[1].points[1].x == 110.0, 'of the person by the start only')
    H.ok(asks[1] and asks[1].at.x == 100.0, 'asked from the start')
    H.ok(asks[1] and asks[1].at.z == 31.0, 'from a standing officer\'s height, not half under the ground')

    -- the points: the person from the start, the vehicle 400 m away from right over it, the marker from there
    -- (1 m away), the route point not at all (Config.Testing.spawnCheck.routes = false)
    H.eq(#probes, 3, 'three points probed, the route point skipped')
    H.ok(probes[1].kind == 'ped' and probes[1].opts.wall == true and probes[1].at.x == 100.0,
        'the person: as a person with the wall check, from the start')
    H.ok(probes[2].kind == 'vehicle' and probes[2].model == 'sultan' and probes[2].h == 0.0,
        'the vehicle: as a vehicle of its model, with its heading')
    H.ok(probes[2].at.x == 500.0 and probes[2].at.z == 21.0, 'from right over it (it is further than moveWithin)')
    H.ok(scenes[2] and scenes[2][1] == 500.0, 'the map loaded there first')
    H.ok(probes[3].kind == 'ped' and probes[3].opts.wall == false and probes[3].at.x == 500.0,
        'the marker: as where an officer stands, no wall check, from where he already is')

    local pts = Pushes('point')
    H.eq(#pts, 4, 'every point goes to the NUI')
    H.ok(pts[1].result.id == 'spawns[1]' and pts[1].result.status == 'ok' and pts[1].result.seen == false,
        'with its result and whether the start sees it')
    H.ok(pts[2].result.status == 'underground' and pts[2].result.groundZ == 19.0 and pts[2].result.kind == 'vehicle',
        'and what the server listed')
    H.ok(pts[4].result.status == 'skipped' and pts[4].result.kind == 'path', 'the route point: skipped')
    H.ok(
        pts[2].progress.mission == 1 and pts[2].progress.missions == 1 and pts[2].progress.location == 1
            and pts[2].progress.point == 2 and pts[2].progress.points == 4,
        'progress: mission 1/1, location 1/1, point 2/4'
    )

    -- the location's report to the server
    H.eq(#actions, 1, 'one report')
    local rep = actions[1] and actions[1].payload
    H.ok(actions[1].name == 'server:test:spawnCheckReport' and rep.missionId == 'demo' and rep.location == 1,
        'server:test:spawnCheckReport of demo #1')
    H.ok(
        #rep.results == 4 and rep.results[2].id == 'spot[1]' and rep.results[2].status == 'underground'
            and rep.results[2].groundZ == 19.0 and rep.results[4].status == 'skipped',
        'every point with its answer'
    )
    H.eq(rep.results[1].x, nil, 'no coordinates: the server uses its own')

    -- back where he was, as he was
    local last = moves[#moves]
    H.ok(last[2] == -50.0 and last[3] == 20.0 and last[4] == 30.0, 'back where he was')
    H.eq(Called('SetEntityHeading')[1][2], 90.0, 'facing the same way')
    f = Called('FreezeEntityPosition')
    H.eq(f[#f][2], false, 'let go')
    vis = Called('SetEntityVisible')
    H.eq(vis[#vis][2], true, 'seen again')
    inv = Called('SetEntityInvincible')
    H.eq(inv[#inv][2], false, 'hurt again')
    local fades = Called('DoScreenFadeIn')
    H.ok(#fades >= 2, 'the screen comes back')

    -- route points checked when asked
    Reset()
    local cfg = (Config.Testing or {}).spawnCheck
    cfg.routes = true
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    RunToEnd()
    H.eq(#probes, 4, 'routes = true: the route point is probed too')
    H.ok(probes[4].kind == 'ped' and probes[4].opts.wall == false and probes[4].at.x == 900.0,
        'as where someone walks, from right over it')
    cfg.routes = false

    -- moveWithin 0: moved over every point
    Reset()
    cfg.moveWithin = 0.0
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    RunToEnd()
    H.eq(probes[1].at.x, 110.0, 'moveWithin = 0: over the person too')
    H.eq(probes[3].at.x, 501.0, 'and over the marker')
    cfg.moveWithin = 150.0

    -- a whole mission, stopped after its first point
    Reset()
    onProbe = function(n) if n == 1 then clientActions.spawnCheckStop() end end
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.ok(ok and data.locations == 2, 'every location of the mission')
    RunToEnd()
    onProbe = nil
    H.eq(#probes, 1, 'Stop: the point being checked is finished, then nothing more')
    H.eq(#Pushes('stopped'), 1, 'the NUI hears it stopped')
    H.eq(#actions, 1, 'what was checked is still reported')
    H.eq(#actions[1].payload.results, 1, 'that one point')
    H.eq(#Pushes('location'), 1, 'the next location is not visited')
    last = Called('SetEntityCoords')
    last = last[#last]
    H.ok(last[2] == -50.0 and game.frozen == false and game.visible == true, 'back where he was, let go, seen')

    -- both locations
    Reset()
    clientActions.spawnCheck({ missionId = 'demo' })
    RunToEnd()
    H.eq(#actions, 2, 'a report per location')
    H.eq(Pushes('point')[5].progress.location, 2, 'location 2/2')
    local all = Called('SetEntityCoords')
    H.ok(all[#all - 1][2] == 1000.0, 'the second location from its own start')

    -- an admin who was invincible and frozen before stays so
    Reset()
    game.invincible, game.frozen = true, true
    clientActions.spawnCheck({ missionId = 'demo', location = 2 })
    RunToEnd()
    H.eq(game.invincible, true, 'invincible before: invincible after')
    H.eq(game.frozen, true, 'frozen before: still frozen')

    -- refusals
    Reset()
    currentRun = { id = 'run-1' }
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.eq(data, 'err.spawn_check_on_run', 'on a run: refused')
    currentRun = nil
    game.inVehicle = true
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.eq(data, 'err.spawn_check_in_vehicle', 'in a vehicle: refused')
    game.inVehicle = false
    game.dead = true
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.eq(data, 'err.spawn_check_dead', 'down: refused')
    game.dead = false
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.eq(data, 'err.in_arena', 'in the arena: refused')
    LocalPlayer.state.crimsonArena = nil
    cfg.enabled = false
    ok, data = clientActions.spawnCheck({ missionId = 'demo' })
    H.eq(data, 'err.spawn_check_disabled', 'Config.Testing.spawnCheck.enabled = false: refused')
    cfg.enabled = true
    ok, data = clientActions.spawnCheck({ missionId = 'demo', location = 3 })
    H.eq(data, 'err.invalid_location', 'a location the mission does not have')
    ok, data = clientActions.spawnCheck({ location = 1 })
    H.eq(data, 'err.invalid_payload', 'a location without its mission')
    ok, data = clientActions.spawnCheck({ missionId = 'demo', location = 'one' })
    H.eq(data, 'err.invalid_payload', 'a location that is no number')
    H.eq(#calls, 0, 'a refused check never touches him')
    ok = clientActions.spawnCheck({ missionId = 'demo', location = 2 })
    ok, data = clientActions.spawnCheck({ missionId = 'demo', location = 2 })
    H.eq(data, 'err.spawn_check_running', 'one check at a time')
    RunToEnd()

    -- the server refuses a location (he joined a run meanwhile): the check ends, he is back
    Reset()
    refuseLocation = 'err.spawn_check_on_run'
    clientActions.spawnCheck({ missionId = 'demo' })
    RunToEnd()
    refuseLocation = nil
    local failed = Pushes('failed')[1]
    H.ok(failed and failed.error == 'err.spawn_check_on_run', 'refused by the server: the check ends with why')
    H.ok(#probes == 0 and game.frozen == false and game.visible == true, 'nothing probed, he is let go')

    -- a run of his starts during the check (he started or joined a test): the check ends before the next point and
    -- never moves him again (not over the next point, not back where he was); he is let go, seen and hurt again
    Reset()
    onProbe = function(n) if n == 1 then currentRun = { id = 'run-t' } end end
    clientActions.spawnCheck({ missionId = 'demo' })
    RunToEnd()
    onProbe = nil
    currentRun = nil
    failed = Pushes('failed')[1]
    H.ok(failed and failed.error == 'err.spawn_check_on_run', 'a run of his started: the check ends with why')
    H.eq(#probes, 1, 'no point after that one is checked')
    moves = Called('SetEntityCoords')
    H.eq(#moves, 1, 'only the move to the start: not over the car 400 m away, not back where he was')
    H.ok(#actions == 1 and #actions[1].payload.results == 1, 'the point checked before is still reported')
    H.eq(#Pushes('location'), 1, 'the next location is not visited')
    H.ok(game.frozen == false and game.visible == true and game.invincible == false, 'let go, seen, hurt again')

    -- the server sees his run first (the next location is refused): he stays where the check had him
    Reset()
    local realRequest = CP.Net.request
    CP.Net.request = function(name, args)
        if args.location == 2 then return { ok = false, error = 'err.spawn_check_on_run' } end
        return realRequest(name, args)
    end
    clientActions.spawnCheck({ missionId = 'demo' })
    RunToEnd()
    CP.Net.request = realRequest
    moves = Called('SetEntityCoords')
    last = moves[#moves]
    H.ok(last and last[2] == 500.0 and last[3] == 200.0, 'not moved back: still over the last point he checked')
    H.ok(game.frozen == false and game.visible == true, 'let go and seen')

    -- the test panel's teleport waits for the check (it would let go of him in the middle of it)
    Reset()
    local st = CP.Testing._state()
    st.controls, st.runId = true, 'run-t'
    clientActions.spawnCheck({ missionId = 'demo', location = 2 })
    ok, data = clientActions.teleport({ target = 'start' })
    H.eq(data, 'err.spawn_check_running', 'the test teleport is refused while a check runs')
    local asked = false
    for _, a in ipairs(actions) do if a.name == 'server:test:control' then asked = true end end
    H.eq(asked, false, 'and the server is not asked')
    RunToEnd()
    st.controls, st.runId = false, nil

    -- Crimson-Arena takes him during the check (rule 13): no further move, his place and freeze are the arena's
    Reset()
    onProbe = function(n)
        if n == 1 then
            LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
            for _, b in ipairs(bagHandlers) do
                if b.key == 'crimsonArena' then b.fn('player:1', 'crimsonArena', LocalPlayer.state.crimsonArena) end
            end
        end
    end
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    RunToEnd()
    onProbe = nil
    moves = Called('SetEntityCoords')
    H.eq(#moves, 1, 'the arena took him: never moved again (not over the next point, not back)')
    f = Called('FreezeEntityPosition')
    H.eq(f[#f][2], true, 'the arena\'s freeze is left alone')
    H.eq(game.visible, true, 'but he is seen again')
    H.eq(game.invincible, false, 'and hurt again')
    H.eq(#Pushes('stopped') + #Pushes('failed'), 1, 'the NUI hears the check ended')
    LocalPlayer.state.crimsonArena = nil
end

-- a location the server refuses for its own reason is skipped: the NUI hears which one (with the mission's name,
-- for the dialog's "Locations not checked") and the check goes on (PLAN S8)
do
    Reset()
    local realRequest = CP.Net.request
    CP.Net.request = function(name, args)
        if args.location == 1 then return { ok = false, error = 'err.invalid_location' } end
        return realRequest(name, args)
    end
    clientActions.spawnCheck({ missionId = 'demo' })
    RunToEnd()
    CP.Net.request = realRequest
    local skipped = Pushes('location')[1]
    H.ok(
        skipped and skipped.error == 'err.invalid_location' and skipped.missionId == 'demo'
            and skipped.missionLabel == 'Demo' and skipped.location == 1,
        'a skipped location: which one, by name, and why'
    )
    H.ok(#Pushes('location') == 2 and #Pushes('done') == 1, 'and the check goes on to the next one')
end

-- ============================================================================
--                     5. "TELEPORT HERE" NEXT TO A RESULT
-- ============================================================================
-- PLAN S8, client half.
-- client action 'teleport' { target = 'point', missionId, location, point }: no test run needed; the server gives
-- the coordinates (the NUI sends none); he is put on the ground there like the test teleport.

do
    _G.GetVehiclePedIsIn = function() return 0 end
    _G.GetPedInVehicleSeat = function() return 0 end
    _G.RequestCollisionAtCoord = function(x, y, z) Float('RequestCollisionAtCoord', x, y, z) end
    _G.GetGroundZFor_3dCoord = function(x, y, z)
        Float('GetGroundZFor_3dCoord', x, y, z)
        return true, 19.25
    end
    local realRequest = CP.Net.request
    local pointReply = nil
    CP.Net.request = function(name, args)
        if name == 'server:test:spawnPoints' and type(args) == 'table' and args.point ~= nil then
            requests[#requests + 1] = { name = name, args = CP.U.deepcopy(args) }
            return pointReply
        end
        return realRequest(name, args)
    end

    Reset()
    game.typeErrors = 0
    pointReply = {
        ok = true,
        data = { missionId = 'demo', location = 1, point = CP.U.deepcopy(LOCATIONS[1].points[2]) },
    }
    local ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(ok, true, 'Teleport here works without a test run')
    H.ok(type(data) == 'table' and data.target == 'point' and data.point == 'spot[1]', 'and says which point')
    H.eq(#requests, 1, 'the server is asked once')
    local q = requests[1] and requests[1].args or {}
    H.ok(
        requests[1].name == 'server:test:spawnPoints' and q.missionId == 'demo' and q.location == 1
            and q.point == 'spot[1]',
        'for that one point by its id'
    )
    H.ok(q.x == nil and q.y == nil and q.z == nil, 'no coordinates from the NUI')
    local moves = Called('SetEntityCoords')
    H.ok(#moves == 2 and moves[1][2] == 500.0 and moves[1][3] == 200.0 and moves[1][4] == 21.0,
        'over the server\'s point first')
    H.ok(moves[2][2] == 500.0 and moves[2][4] == 19.25, 'then on the ground there')
    local f = Called('FreezeEntityPosition')
    H.ok(#f == 2 and f[1][2] == true and f[2][2] == false, 'frozen for the move, let go after')
    H.ok(#Called('DoScreenFadeOut') == 1 and #Called('DoScreenFadeIn') == 1, 'the screen fades out and back in')
    H.eq(game.typeErrors, 0, 'every coordinate reaches the game as a decimal')

    -- the server refuses: he is not moved
    Reset()
    pointReply = { ok = false, error = 'err.spawn_check_teleport_disabled' }
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.spawn_check_teleport_disabled', 'refused by the server: its reason')
    H.eq(#Called('SetEntityCoords'), 0, 'and not moved')
    pointReply = { ok = true, data = { missionId = 'demo', location = 1, point = { id = 'spot[1]' } } }
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.test_control_failed', 'an answer without coordinates: refused, never a move to 0, 0, 0')
    H.eq(#Called('SetEntityCoords'), 0, 'not moved')

    -- what the client refuses itself
    Reset()
    pointReply = {
        ok = true,
        data = { missionId = 'demo', location = 1, point = CP.U.deepcopy(LOCATIONS[1].points[2]) },
    }
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1 })
    H.eq(data, 'err.invalid_payload', 'no point id')
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 'one', point = 'spot[1]' })
    H.eq(data, 'err.invalid_payload', 'a location that is no number')
    ok, data = clientActions.teleport({ target = 'point', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.invalid_payload', 'no mission')
    currentRun = { id = 'run-1' }
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.spawn_check_on_run', 'on a run: refused')
    currentRun = nil
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.in_arena', 'in the arena: refused')
    LocalPlayer.state.crimsonArena = nil
    H.eq(#requests, 0, 'none of these asks the server')
    clientActions.spawnCheck({ missionId = 'demo', location = 2 })
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.spawn_check_running', 'not while a check runs (it puts him back where he was)')
    RunToEnd()
    -- the arena takes him while the server answers: not moved (rule 13)
    Reset()
    CP.Net.request = function(name, args)
        LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
        return pointReply
    end
    ok, data = clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
    H.eq(data, 'err.in_arena', 'Crimson-Arena took him meanwhile: refused')
    H.eq(#Called('SetEntityCoords'), 0, 'and not moved')
    LocalPlayer.state.crimsonArena = nil

    -- the test run teleport is unchanged: it still needs a test run
    ok, data = clientActions.teleport({ target = 'start' })
    H.eq(data, 'err.test_no_active', 'Teleport to the start still needs a test run')
    CP.Net.request = realRequest
end

-- ============================================================================
--            6. A RESTART OR A LOGOUT DURING A TELEPORT OR A CHECK
-- ============================================================================
-- A Crimson-Police restart in a teleport's fade or ground wait, or in the check's first fade, puts the screen back and
-- undoes our own freeze (never one of Crimson-Arena's); our own load scene ends. A logout during the check ends it
-- and the ped is never moved again: qbx's character screen freezes and places it.

-- FXServer stopping Crimson-Police: its onResourceStop handlers run, then its threads end (none resumes again)
local function StopPolice()
    H.fire('onResourceStop', nil, 'Crimson-Police')
    H.killThreads()
end
-- and starting it again: the file runs fresh
local function StartPolice()
    H.handlers.onResourceStop = nil
    H.load('modules/testing/client.lua')
    H.step(0)
end

do
    local faded, ground, car = false, false, 0
    _G.IsScreenFadedOut = function() return faded end
    _G.RequestCollisionAtCoord = function() end
    _G.GetGroundZFor_3dCoord = function() return ground, 19.25 end
    _G.GetVehiclePedIsIn = function() return car end
    _G.GetPedInVehicleSeat = function(veh, seat) return (veh ~= 0 and veh == car and seat == -1) and PED or 0 end
    local realRequest = CP.Net.request
    CP.Net.request = function(name, args)
        if name == 'server:test:spawnPoints' and type(args) == 'table' and args.point ~= nil then
            return {
                ok = true,
                data = { missionId = 'demo', location = 1, point = CP.U.deepcopy(LOCATIONS[1].points[2]) },
            }
        end
        return realRequest(name, args)
    end
    local function Teleport()
        CreateThread(function()
            clientActions.teleport({ target = 'point', missionId = 'demo', location = 1, point = 'spot[1]' })
        end)
    end
    local function FadedInAtOnce()
        local f = Called('DoScreenFadeIn')
        return #f == 1 and f[1][1] == 0
    end

    -- in the fade: nothing is frozen yet
    Reset()
    Teleport()
    H.eq(#Called('DoScreenFadeOut'), 1, 'the teleport waits in its fade')
    StopPolice()
    H.ok(FadedInAtOnce(), 'a restart in the teleport\'s fade: the screen comes back at once')
    H.eq(#Called('FreezeEntityPosition'), 0, 'nothing was frozen yet, nothing to undo')
    H.eq(#Called('NewLoadSceneStop'), 0, 'no load scene of ours: another resource\'s is left alone')
    StartPolice()

    -- in the ground wait: frozen over the point
    Reset()
    faded = true
    Teleport()
    local f = Called('FreezeEntityPosition')
    H.ok(#f == 1 and f[1][1] == PED and f[1][2] == true, 'the teleport waits for the ground, frozen over the point')
    StopPolice()
    f = Called('FreezeEntityPosition')
    H.ok(#f == 2 and f[2][1] == PED and f[2][2] == false, 'a restart then: he is let go')
    H.ok(FadedInAtOnce(), 'and the screen comes back at once')
    StartPolice()

    -- Crimson-Arena took him in the ground wait: its freeze is left alone, the screen still comes back
    Reset()
    Teleport()
    LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' }
    StopPolice()
    LocalPlayer.state.crimsonArena = nil
    H.eq(#Called('FreezeEntityPosition'), 1, 'the arena owns him: not let go')
    H.ok(FadedInAtOnce(), 'the screen comes back')
    StartPolice()

    -- driving: the car he drives was frozen, and is let go
    Reset()
    car = 300
    Teleport()
    StopPolice()
    f = Called('FreezeEntityPosition')
    H.ok(#f == 2 and f[1][1] == 300 and f[2][1] == 300 and f[2][2] == false, 'his car is let go')
    StartPolice()
    car = 0

    -- a teleport that ended is forgotten: a restart later touches nothing
    ground = true
    Teleport()
    Reset()
    StopPolice()
    H.eq(#calls, 0, 'a restart after the teleport ended: no fade, no freeze')
    StartPolice()

    -- a restart in the check's first fade (before he is hidden and his state saved)
    Reset()
    faded = false
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    H.eq(#Called('SetEntityVisible'), 0, 'the check waits in its first fade, he is not hidden yet')
    StopPolice()
    H.ok(FadedInAtOnce(), 'a restart then: the screen comes back at once')
    H.eq(#Called('FreezeEntityPosition') + #Called('SetEntityCoords'), 0, 'he was never frozen or moved')
    StartPolice()
    faded = true

    -- a restart while the map loads around the start: he is put back and our load scene ends
    Reset()
    game.sceneLoadedAfter = 100000
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    H.eq(#Called('NewLoadSceneStartSphere'), 1, 'the map loads around the start')
    StopPolice()
    H.eq(#Called('NewLoadSceneStop'), 1, 'a restart then: our load scene is stopped')
    local moves = Called('SetEntityCoords')
    H.ok(moves[#moves][2] == -50.0 and not game.frozen and game.visible, 'and he is back, let go and seen')
    StartPolice()
    game.sceneLoadedAfter = 2

    -- a logout while the server answers for the first location: his ped is never moved and not let go (the
    -- character screen freezes and places it), but he is seen and hurt again and the screen comes back
    Reset()
    CP.Net.request = function(name, args)
        if args.location ~= nil then H.fire('QBCore:Client:OnPlayerUnload', nil) end
        return realRequest(name, args)
    end
    clientActions.spawnCheck({ missionId = 'demo' })
    H.ok(RunToEnd(), 'a logout ends the check')
    CP.Net.request = realRequest
    H.eq(#Called('SetEntityCoords'), 0, 'his ped is never moved: not to the start, not back')
    H.eq(#Called('NewLoadSceneStartSphere'), 0, 'no map is loaded for him')
    f = Called('FreezeEntityPosition')
    H.ok(#f == 1 and f[1][2] == true, 'not let go: the character screen holds the ped')
    H.ok(game.visible and not game.invincible, 'seen and hurt again')
    H.ok(#Called('DoScreenFadeIn') == 1, 'the screen comes back')
    H.eq(#Pushes('location'), 1, 'the next location is not visited')

    -- a logout during a point: no move over the next point, none back where the old character stood
    Reset()
    onProbe = function(n) if n == 1 then H.fire('QBCore:Client:OnPlayerUnload', nil) end end
    clientActions.spawnCheck({ missionId = 'demo', location = 1 })
    RunToEnd()
    onProbe = nil
    H.eq(#Called('SetEntityCoords'), 1, 'a logout during a point: only the move to the start before it')
    H.eq(#probes, 1, 'no point after it is checked')
    H.eq(game.frozen, true, 'not let go')
    H.ok(game.visible and not game.invincible, 'seen and hurt again')
end

return H
