-- tests/missions_b_spec.lua · slice missions_b: the built-in mission files warrant_service, manhunt,
-- gang_shootout, hostage_rescue, bomb_disposal, armored_truck_escort, prison_break and
-- weekly_boss_kingpin. Each file is run in the mission loader's sandbox and checked against the
-- mission catalog, its mission card, ARCHITECTURE §3.3 (objective fields, location keys) and the
-- built-in guardrails (location count and spacing, map bounds, no-build zones for points and route
-- segments, 30 m from the start, points of a location kept together, heights, headings facing the
-- approach, spawn counts, contiguous road / escape / flee routes, the armed-NPC budget, bonus ids, no
-- payout field). The objectives are then run through
-- the real blocks' defaults/validate (for the blocks that exist) and through CP.Missions.normalize.
-- Run it on its own to see the report lines (sizes, route lengths, nearest distances):
--   cd /home/user/PoliceTablet && lua5.4 tests/run.lua missions_b
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U

local function report(fmt, ...) print(('  [missions_b] ' .. fmt):format(...)) end

-- ── vectors ─────────────────────────────────────────────────────────────────
local VMT = getmetatable(vec3(0, 0, 0))
local function isVec(v) return type(v) == 'table' and getmetatable(v) == VMT end
local function isVec3(v) return isVec(v) and v.w == nil end
local function isVec4(v) return isVec(v) and v.w ~= nil end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function d3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + ((a.z or 0) - (b.z or 0)) ^ 2) end
local function isList(t)
    if type(t) ~= 'table' or isVec(t) then return false end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end
local function listOf(pred, t)
    if not isList(t) or #t == 0 then return false end
    for _, v in ipairs(t) do if not pred(v) then return false end end
    return true
end

-- Every vector anywhere inside v, with its path.
local function eachVec(v, path, fn, seen)
    seen = seen or {}
    if isVec(v) then fn(v, path) return end
    if type(v) ~= 'table' or seen[v] then return end
    seen[v] = true
    for k, x in pairs(v) do eachVec(x, path .. '.' .. tostring(k), fn, seen) end
end

local function hasKey(v, key, seen)
    seen = seen or {}
    if type(v) ~= 'table' or isVec(v) or seen[v] then return false end
    seen[v] = true
    for k, x in pairs(v) do
        if type(k) == 'string' and k:lower():find(key, 1, true) then return true end
        if hasKey(x, key, seen) then return true end
    end
    return false
end

local function polyLen(pts)
    local s = 0
    for i = 2, #pts do s = s + d2(pts[i - 1], pts[i]) end
    return s
end

local function distToPolyline(p, pts)
    local best = math.huge
    for i = 1, #pts - 1 do
        local a, b = pts[i], pts[i + 1]
        local vx, vy = b.x - a.x, b.y - a.y
        local l2 = vx * vx + vy * vy
        local t = l2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / l2)) or 0
        local d = math.sqrt((p.x - a.x - t * vx) ^ 2 + (p.y - a.y - t * vy) ^ 2)
        if d < best then best = d end
    end
    return best
end

-- ── load one file exactly like the loader (ARCHITECTURE §5.6 sandbox) ─────────
local function loadMission(id)
    local path = 'missions/builtin/' .. id .. '.lua'
    local content = LoadResourceFile('Crimson-Police', path)
    if not H.ok(type(content) == 'string' and #content > 0, id .. ': file exists') then return nil end
    local calls = {}
    local env = {
        RegisterMission = function(def) calls[#calls + 1] = def end,
        vec3 = vec3, vec4 = vec4, vector3 = vector3, vector4 = vector4,
        math = math, string = string, table = table,
        pairs = pairs, ipairs = ipairs, type = type, tonumber = tonumber, tostring = tostring,
    }
    local chunk, err = load(content, '@' .. path, 't', env)
    if not H.ok(chunk ~= nil, id .. ': compiles in the sandbox (' .. tostring(err) .. ')') then return nil end
    local ok, runErr = pcall(chunk)
    if not H.ok(ok, id .. ': runs in the sandbox (' .. tostring(runErr) .. ')') then return nil end
    H.eq(#calls, 1, id .. ': exactly one RegisterMission call')
    H.ok(content:match('^%-%-') ~= nil, id .. ': starts with a header comment')
    return calls[1], content
end

-- ── the contract: ARCHITECTURE §3.3 field names per block ────────────────────
local COMMON = { block = true, label = true, minSeconds = true, presenceRange = true }
local FIELDS = {
    checkpoint_route = { 'checkpoints', 'use', 'count', 'radius', 'stopFor', 'vehicleRequired', 'medals', 'contactPenalty', 'timerStart', 'failIfUndriveable' },
    interact_points  = { 'points', 'use', 'count', 'target', 'progress', 'roll', 'logResult', 'hidden', 'fastBonus' },
    skill_check      = { 'targets', 'checks', 'missPenalty', 'failAfter', 'target', 'explosion' },
    hostile_waves    = { 'spawns', 'waves', 'nextWave', 'weapons', 'accuracy', 'armour', 'health', 'behaviour', 'surrender', 'peds', 'boss', 'blockTraffic' },
    protect_rescue   = { 'npcs', 'count', 'peds', 'restrained', 'freeTime', 'target', 'safe', 'safeRadius', 'hitPenalty', 'failIfDies' },
    flee_arrest      = { 'mode', 'door', 'knock', 'suspect', 'fleeTo', 'responses', 'associates', 'spawns', 'routes', 'suspects', 'armedShare',
                         'models', 'weapons', 'fireWithin', 'escape', 'givesUp', 'armedGivesUp', 'cuff', 'aliveBonus' },
    pursuit          = { 'mode', 'vehicles', 'models', 'suspectsPerVehicle', 'spawn', 'spawns', 'route', 'speed', 'style', 'trigger', 'stopped',
                         'footFlee', 'surrenderOnAim', 'arrest', 'hold', 'lost', 'duration', 'medals', 'escape', 'complete', 'ramSpeed',
                         'ramPenaltyId', 'neverShoots' },
    escort           = { 'route', 'vehicle', 'speed', 'style', 'toughness', 'stoppedFail', 'arrival', 'ambushPoints', 'ambush', 'clearRadius' },
    search_area      = { 'center', 'startRadius', 'shrinkTo', 'clues', 'clueCount', 'clueProps', 'clueProgress', 'hiding', 'fugitives',
                         'runDistance', 'givesUp', 'escape', 'cuff' },
}
-- Nested tables written in §3.3 with their own field lists.
local NESTED = {
    boss = { 'model', 'label', 'health', 'armour', 'weapon', 'spawn', 'surrender' },
    ambush = { 'waves', 'carsPerWave', 'perCar', 'models', 'peds', 'weapons', 'accuracy', 'armour' },
    associates = { 'count', 'spawns', 'weapons', 'accuracy', 'armour' },
    hidden = { 'count', 'prop', 'label' },
    fastBonus = { 'seconds', 'id' },
    progress = { 'label', 'duration', 'anim' },
    clueProgress = { 'label', 'duration' },
    knock = { 'label', 'duration' },
    responses = { 'surrender', 'flee', 'fight' },
    escape = { 'distance', 'seconds' },
    givesUp = { 'aim', 'stun', 'close' },
    armedGivesUp = { 'stun', 'belowHealth' },
    cuff = { 'label', 'duration' },
    aliveBonus = { 'id', 'points', 'each' },
    nextWave = { 'aliveAtMost', 'afterSeconds' },
    surrender = { 'belowHealth', 'chance' },
}
local TARGET_FIELDS = { interact_points = { 'label', 'icon', 'radius' }, skill_check = { 'label', 'icon' }, protect_rescue = { 'label' } }

local function set(list) local s = {} for _, v in ipairs(list) do s[v] = true end return s end

local function checkFields(id, i, obj)
    local allowed = set(FIELDS[obj.block] or {})
    for k, v in pairs(obj) do
        H.ok(COMMON[k] or allowed[k], ('%s: objective %d (%s) field "%s" is in ARCHITECTURE 3.3'):format(id, i, obj.block, tostring(k)))
        local nested = (k == 'target') and TARGET_FIELDS[obj.block] or NESTED[k]
        if nested and type(v) == 'table' and not isList(v) then
            local ns = set(nested)
            for nk in pairs(v) do
                H.ok(ns[nk], ('%s: objective %d (%s) field "%s.%s" is in ARCHITECTURE 3.3'):format(id, i, obj.block, k, tostring(nk)))
            end
        end
    end
    if type(obj.surrender) == 'table' and type(obj.boss) == 'table' and type(obj.boss.surrender) == 'table' then
        for nk in pairs(obj.boss.surrender) do H.ok(set(NESTED.surrender)[nk], id .. ': boss.surrender.' .. nk) end
    end
    if type(obj.givesUp) == 'table' and type(obj.givesUp.close) == 'table' then
        for nk in pairs(obj.givesUp.close) do H.ok(nk == 'distance' or nk == 'seconds', id .. ': givesUp.close.' .. nk) end
    end
end

-- Location keys an objective references (with the §3.3 / block defaults), and the shape each must have.
local function refs(obj)
    local out = {}
    local function add(key, shape) if type(key) == 'string' then out[#out + 1] = { key = key, shape = shape } end end
    local b = obj.block
    if b == 'hostile_waves' then
        add(obj.spawns or 'spawns', 'list4')
        if type(obj.boss) == 'table' then add(obj.boss.spawn, 'vec4') end
    elseif b == 'interact_points' then
        add(obj.points, 'points')
    elseif b == 'skill_check' then
        if obj.targets ~= 'shared:devices' then add(obj.targets, 'points') end
    elseif b == 'protect_rescue' then
        add(obj.npcs or 'hostages', 'list4')
        add(obj.safe or 'safe', 'vec3')
    elseif b == 'flee_arrest' then
        if (obj.mode or 'door') == 'door' then
            add(obj.door or 'door', 'vec4')
            add(obj.suspect or 'suspect', 'vec4')
            add(obj.fleeTo or 'fleeTo', 'list3')
            add(type(obj.associates) == 'table' and obj.associates.spawns or 'associates', 'list4')
        else
            add(obj.spawns or 'spawns', 'list4')
            add(obj.routes or 'routes', 'routes')
        end
    elseif b == 'escort' then
        add(obj.route, 'route')
        add(obj.ambushPoints, 'list34')   -- escort: vec3 or vec4 (heading = direction of travel)
    elseif b == 'search_area' then
        add(obj.center, 'vec3')
        add(obj.clues, 'list3')
        add(obj.hiding, 'list4')
    elseif b == 'pursuit' then
        add(obj.spawn, 'vec4')
        add(obj.spawns, 'list4')
        add(obj.route, 'route')
    elseif b == 'checkpoint_route' then
        add(obj.checkpoints, 'points')
    end
    return out
end

local SHAPES = {
    vec3 = function(v) return isVec3(v) end,
    vec4 = function(v) return isVec4(v) end,
    list3 = function(v) return listOf(isVec3, v) end,
    list4 = function(v) return listOf(isVec4, v) end,
    list34 = function(v) return listOf(function(p) return isVec3(p) or isVec4(p) end, v) end,
    points = function(v) return isVec(v) or listOf(isVec, v) end,
    route = function(v) return type(v) == 'table' and listOf(isVec3, v.points) end,
    routes = function(v) return listOf(function(r) return listOf(isVec3, r) and #r >= 2 end, v) end,
}

-- ── the catalog and the cards ───────────────────────────────────────────────
local CATALOG = {
    warrant_service      = { type = 'investigation', min = 2, max = 4, stars = 3, time = 720, cooldown = 1200, locations = 5, vp = false, radius = 50 },
    manhunt              = { type = 'investigation', min = 1, max = 4, stars = 2, time = 720, cooldown = 1200, locations = 5, vp = true,  radius = 600 },
    gang_shootout        = { type = 'tactical',      min = 1, max = 4, stars = 3, time = 600, cooldown = 1200, locations = 5, vp = false, radius = 80 },
    hostage_rescue       = { type = 'tactical',      min = 1, max = 4, stars = 3, time = 600, cooldown = 1200, locations = 5, vp = false, radius = 60 },
    bomb_disposal        = { type = 'tactical',      min = 1, max = 4, stars = 2, time = 360, cooldown = 1200, locations = 5, vp = true,  radius = 50 },
    armored_truck_escort = { type = 'tactical',      min = 2, max = 4, stars = 3, time = 720, cooldown = 1200, locations = 3, vp = false, radius = 50 },
    prison_break         = { type = 'tactical',      min = 1, max = 4, stars = 3, time = 600, cooldown = 1200, locations = 5, vp = false, radius = 150 },
    -- the Weekly Boss has no card cooldown (its once-a-week limit is Config.Events); 1200 is this file's value
    weekly_boss_kingpin  = { type = 'tactical',      min = 1, max = 4, stars = 3, time = 900, cooldown = 1200, locations = 3, vp = false, radius = 100 },
}
local ORDER = { 'warrant_service', 'manhunt', 'gang_shootout', 'hostage_rescue', 'bomb_disposal', 'armored_truck_escort', 'prison_break', 'weekly_boss_kingpin' }

-- Expected bonuses / penalties per card: id -> { points = n } | { pct = f }, each
local BONUSES = {
    warrant_service      = { suspect_alive = { points = 15 }, no_participant_downed = { pct = 0.10 } },
    manhunt              = { clues_first = { points = 10 }, no_weapons_fired = { points = 10 } },
    gang_shootout        = { no_participant_downed = { pct = 0.10 }, hostile_arrested = { points = 5, each = true } },
    hostage_rescue       = { no_hostage_hurt = { points = 15 }, no_participant_downed = { pct = 0.10 } },
    bomb_disposal        = { no_missed_checks = { points = 15 }, devices_found_fast = { points = 10 } },
    armored_truck_escort = { truck_healthy = { pct = 0.10 }, no_participant_downed = { pct = 0.10 } },
    prison_break         = { inmate_alive = { points = 10, each = true } },
    weekly_boss_kingpin  = { kingpin_alive = { points = 50 }, no_participant_downed = { pct = 0.10 } },
}
local PENALTIES = { hostage_rescue = { hostage_hit = { points = -50, each = true } } }

-- Scaling paths per card (string path, or path -> max)
local SCALING = {
    warrant_service      = { ['objectives.1.associates.count'] = true },
    manhunt              = { ['objectives.1.fugitives'] = true },
    gang_shootout        = { ['objectives.1.waves'] = true },
    hostage_rescue       = { ['objectives.1.waves'] = true },
    bomb_disposal        = { ['objectives.1.hidden.count'] = true },
    armored_truck_escort = { ['objectives.1.ambush.waves'] = 5, ['objectives.1.ambush.carsPerWave'] = 5 },
    prison_break         = { ['objectives.1.suspects'] = true },
    weekly_boss_kingpin  = { ['objectives.1.waves'] = true },
}

-- Keys placed as ped/prop/marker points that must be 30 m+ from the start (routes and the manhunt
-- centre are excluded: a road route starts at the depot, the search circle is centred on the start).
local HOSTILE_KEYS = { spawns = true, associates = true, suspect = true, boss = true, ambushPoints = true }
local NOT_PLACED = { label = true, start = true, center = true, route = true, routes = true }

local ZONES = Config.Builder.noBuildZones
local PRISON_MIDDLE = vec3(1693.33, 2569.51, 45.55)   -- stock qb-prison middle point (reference, see INTEGRATIONS)

-- GTA V map bounds (Los Santos and Blaine County, land and coast)
local MAP = { minX = -4000, maxX = 4600, minY = -4200, maxY = 8000, minZ = 0.5, maxZ = 900 }
-- Points of one location stay together: every placed point within NEAR m (2D) of its start, except
-- the keys a card spreads further (the manhunt circle, the escort road route, prison escape routes).
local NEAR = 150.0
local FAR_KEYS = {
    manhunt              = { clues = true, hiding = true },           -- inside the 600 m circle (checked below)
    armored_truck_escort = { route = true, ambushPoints = true },     -- along the road route (checked below)
    prison_break         = { routes = true },                         -- escape routes into the countryside (checked below)
}
-- Heights: every point within this many metres of its start's z (a typo'd or wildly wrong z shows up).
local DZ_NEAR, DZ_FAR = 8.0, 25.0
-- Keys that follow a road downhill/uphill away from the start (heights from the GTA V road nodes): DZ_FAR.
local DZ_ROAD_KEYS = { warrant_service = { fleeTo = true } }   -- Wild Oats Dr drops 18 m over the 80 m flee path
-- Route-like lists: no jump between consecutive points over this many metres.
local MAX_JUMP = 250.0
-- Hostile spawn keys whose heading must face the approach (within FACE_MAX degrees of the start).
local FACE_KEYS = { spawns = true, associates = true, boss = true }
local FACE_MAX = 90.0

-- Angle (degrees) between a vec4's heading (GTA: forward = (-sin h, cos h)) and the direction to target.
local function facingError(p, target)
    local fx, fy = -math.sin(math.rad(p.w)), math.cos(math.rad(p.w))
    local tx, ty = target.x - p.x, target.y - p.y
    local l = math.sqrt(tx * tx + ty * ty)
    if l < 0.01 then return 0 end
    return math.deg(math.acos(math.max(-1, math.min(1, (fx * tx + fy * ty) / l))))
end

-- Largest gap between consecutive points of a list.
local function maxJump(pts)
    local m = 0
    for i = 2, #pts do m = math.max(m, d2(pts[i - 1], pts[i])) end
    return m
end

-- ── armed NPCs before scaling (Mission Builder rules) ────────────────────────
local function armedOf(obj)
    if obj.block == 'hostile_waves' then
        local n = 0
        for _, w in ipairs(obj.waves or { 7, 7, 6 }) do n = n + w end
        if type(obj.boss) == 'table' then n = n + 1 end
        return n
    elseif obj.block == 'escort' then
        local a = obj.ambush or {}
        return (a.waves or 2) * (a.carsPerWave or 2) * (a.perCar or 2)
    elseif obj.block == 'flee_arrest' then
        if obj.mode == 'scatter' then return ((obj.armedShare or 0.4) > 0) and (obj.suspects or 5) or 0 end
        local n = (obj.associates and obj.associates.count) or 1
        if (obj.responses and obj.responses.fight or 0.2) > 0 then n = n + 1 end
        return n
    end
    return 0
end

-- ── generic checks for one mission ──────────────────────────────────────────
local defs = {}

local function checkMission(id)
    local def, content = loadMission(id)
    if not def then return end
    defs[id] = def
    local cat = CATALOG[id]

    -- identity and catalog numbers
    H.eq(def.id, id, id .. ': id equals the file name')
    H.ok(type(def.label) == 'string' and def.label ~= '', id .. ': label')
    H.ok(type(def.description) == 'string' and #def.description > 20, id .. ': description')
    H.eq(def.type, cat.type, id .. ': type')
    H.ok(Config.MissionTypes[def.type] ~= nil, id .. ': type is a Config.MissionTypes key')
    H.ok(type(def.departments) == 'table' and next(def.departments) == nil, id .. ': departments = {} (every department)')
    H.eq(def.minOfficers, cat.min, id .. ': minOfficers')
    H.eq(def.maxOfficers, cat.max, id .. ': maxOfficers')
    H.eq(def.difficulty, cat.stars, id .. ': difficulty')
    H.eq(def.timeLimit, cat.time, id .. ': timeLimit')
    H.eq(def.startTimeout, Config.Limits.startTimeout, id .. ': startTimeout (default)')
    H.eq(def.cooldown, cat.cooldown, id .. ': cooldown')
    if cat.vp then
        H.ok(def.vehiclePenalties ~= false, id .. ': vehiclePenalties on')
    else
        H.eq(def.vehiclePenalties, false, id .. ': vehiclePenalties = false')
    end
    H.ok(not hasKey(def, 'payout'), id .. ': no payout field anywhere')
    H.ok(type(def.items) == 'table' and #def.items == 0, id .. ': items = {}')

    -- field order as in the Example file
    local order = { 'id', 'label', 'description', 'type', 'departments', 'minOfficers', 'maxOfficers', 'difficulty', 'timeLimit',
                    'startTimeout', 'cooldown', 'vehiclePenalties', 'locations', 'objectives', 'scaling', 'items', 'bonuses', 'penalties' }
    local last = 0
    for _, k in ipairs(order) do
        local pos = content:find('\n  ' .. k .. '%s*=')
        if H.ok(pos ~= nil, id .. ': top-level field ' .. k) then
            H.ok(pos > last, id .. ': field ' .. k .. ' in the Example file order')
            last = pos
        end
    end
    for k in pairs(def) do H.ok(set(order)[k], id .. ': top-level field "' .. tostring(k) .. '" is a mission definition field') end

    -- locations: count, labels, start, spacing
    local locs = def.locations
    H.ok(isList(locs) and #locs >= cat.locations, ('%s: %d+ locations (has %d)'):format(id, cat.locations, #locs))
    for li, loc in ipairs(locs) do
        H.ok(type(loc.label) == 'string' and loc.label ~= '', ('%s: location %d has a label'):format(id, li))
        H.ok(type(loc.start) == 'table' and isVec3(loc.start.coords), ('%s: location %d start.coords is a vec3'):format(id, li))
        H.eq(loc.start.radius, cat.radius + 0.0, ('%s: location %d start radius'):format(id, li))
    end
    local minGap = math.huge
    for i = 1, #locs do
        for j = i + 1, #locs do
            local d = d2(locs[i].start.coords, locs[j].start.coords)
            minGap = math.min(minGap, d)
            H.ok(d >= Config.Builder.minLocationGap, ('%s: locations %d and %d are %.0f m apart (100 m+)'):format(id, i, j, d))
        end
    end

    -- every vector: finite, sane height, headings in range, outside every no-build zone
    local nVec = 0
    for li, loc in ipairs(locs) do
        eachVec(loc, 'locations.' .. li, function(v, path)
            nVec = nVec + 1
            H.ok(type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number' and v.x == v.x and v.y == v.y and v.z == v.z,
                id .. ': numeric vector at ' .. path)
            H.ok(v.x >= MAP.minX and v.x <= MAP.maxX and v.y >= MAP.minY and v.y <= MAP.maxY and v.z > MAP.minZ and v.z < MAP.maxZ,
                ('%s: on the map at %s (%.1f, %.1f, %.1f)'):format(id, path, v.x, v.y, v.z))
            if v.w ~= nil then H.ok(v.w >= 0 and v.w < 360, id .. ': heading 0-360 at ' .. path) end
            for _, z in ipairs(ZONES) do
                local d = d2(v, z.coords)
                H.ok(d > z.radius, ('%s: %s is %.0f m from %s (no-build radius %.0f)'):format(id, path, d, z.label, z.radius))
            end
        end)
    end

    -- route-like lists (road routes, escape routes, flee paths): no segment cuts through a no-build zone
    for li, loc in ipairs(locs) do
        local paths = {}
        if type(loc.route) == 'table' and isList(loc.route.points) then paths[#paths + 1] = { 'route', loc.route.points } end
        if isList(loc.routes) then for r, pts in ipairs(loc.routes) do paths[#paths + 1] = { 'routes.' .. r, pts } end end
        if isList(loc.fleeTo) then paths[#paths + 1] = { 'fleeTo', loc.fleeTo } end
        for _, pth in ipairs(paths) do
            for _, z in ipairs(ZONES) do
                local d = distToPolyline(z.coords, pth[2])
                H.ok(d > z.radius, ('%s: location %d %s passes %.0f m from %s (no-build radius %.0f)'):format(id, li, pth[1], d, z.label, z.radius))
            end
        end
    end

    -- placed points 30 m+ from the start (hostile spawns always; every other ped/prop/marker too)
    local nearest, nearestHostile = math.huge, math.huge
    for li, loc in ipairs(locs) do
        local s = loc.start.coords
        for k, v in pairs(loc) do
            if not NOT_PLACED[k] then
                eachVec(v, k, function(p, path)
                    local d = d2(p, s)
                    nearest = math.min(nearest, d)
                    if HOSTILE_KEYS[k] then
                        nearestHostile = math.min(nearestHostile, d)
                        H.ok(d3(p, s) >= Config.Builder.minSpawnFromStart, ('%s: location %d hostile %s is %.1f m from the start (30 m+)'):format(id, li, path, d))
                    end
                    H.ok(d >= Config.Builder.minSpawnFromStart, ('%s: location %d %s is %.1f m from the start (30 m+)'):format(id, li, path, d))
                end)
            end
        end
    end

    -- points of one location together, heights consistent, hostiles facing the approach
    local far, dzMax = 0, 0
    for li, loc in ipairs(locs) do
        local s = loc.start.coords
        local farKeys = FAR_KEYS[id] or {}
        for k, v in pairs(loc) do
            if k ~= 'label' and k ~= 'start' then
                eachVec(v, k, function(p, path)
                    local d = d2(p, s)
                    if not farKeys[k] then
                        far = math.max(far, d)
                        H.ok(d <= NEAR, ('%s: location %d %s is %.0f m from the start (within %.0f m)'):format(id, li, path, d, NEAR))
                    end
                    local dz = math.abs(p.z - s.z)
                    dzMax = math.max(dzMax, dz)
                    local limit = (farKeys[k] or (DZ_ROAD_KEYS[id] or {})[k]) and DZ_FAR or DZ_NEAR
                    H.ok(dz <= limit, ('%s: location %d %s is %.1f m above/below the start (within %.0f m)'):format(id, li, path, dz, limit))
                    if FACE_KEYS[k] and p.w ~= nil then
                        local e = facingError(p, s)
                        H.ok(e <= FACE_MAX, ('%s: location %d %s faces %.0f deg away from the approach (within %.0f)'):format(id, li, path, e, FACE_MAX))
                    end
                end)
            end
        end
    end

    -- objectives: fields, labels, location keys in every location
    H.ok(isList(def.objectives) and #def.objectives >= 1, id .. ': objectives list')
    local armed = 0
    for i, obj in ipairs(def.objectives) do
        H.ok(FIELDS[obj.block] ~= nil, ('%s: objective %d block "%s" is an ARCHITECTURE 3.3 block'):format(id, i, tostring(obj.block)))
        H.ok(type(obj.label) == 'string' and obj.label ~= '', ('%s: objective %d has a label'):format(id, i))
        H.ok(type(obj.minSeconds) == 'number' and obj.minSeconds > 0, ('%s: objective %d minSeconds'):format(id, i))
        if FIELDS[obj.block] then checkFields(id, i, obj) end
        for _, r in ipairs(refs(obj)) do
            for li, loc in ipairs(locs) do
                H.ok(loc[r.key] ~= nil, ('%s: location %d has key "%s" (objective %d)'):format(id, li, r.key, i))
                H.ok(loc[r.key] == nil or SHAPES[r.shape](loc[r.key]), ('%s: location %d "%s" is a %s'):format(id, li, r.key, r.shape))
            end
        end
        -- durations are milliseconds, chances fractions
        for _, key in ipairs({ 'progress', 'clueProgress', 'knock', 'cuff' }) do
            if type(obj[key]) == 'table' and obj[key].duration then
                H.ok(obj[key].duration >= 1000 and obj[key].duration <= 30000, ('%s: objective %d %s.duration is in ms'):format(id, i, key))
            end
        end
        if type(obj.surrender) == 'table' then H.ok(obj.surrender.chance <= 1 and obj.surrender.belowHealth <= 1, id .. ': surrender as fractions') end
        armed = armed + armedOf(obj)
    end
    H.ok(armed <= Config.Builder.maxHostiles, ('%s: %d armed NPCs before scaling (budget %d)'):format(id, armed, Config.Builder.maxHostiles))

    -- scaling: every path resolves to a number or a list of numbers, exactly the card's counts
    H.ok(isList(def.scaling) and #def.scaling >= 1, id .. ': scaling list')
    local seen = {}
    for _, e in ipairs(def.scaling) do
        local path = type(e) == 'string' and e or e.path
        local v = U.getPath(def, path)
        local numeric = type(v) == 'number' or listOf(function(x) return type(x) == 'number' end, v)
        H.ok(numeric, ('%s: scaling %s is a real numeric field'):format(id, tostring(path)))
        local want = SCALING[id][path]
        H.ok(want ~= nil, ('%s: scaling %s is on the card'):format(id, tostring(path)))
        if type(want) == 'number' then H.eq(type(e) == 'table' and e.max, want, id .. ': scaling max for ' .. path) end
        seen[path] = true
    end
    for path in pairs(SCALING[id]) do H.ok(seen[path], id .. ': scales ' .. path) end

    -- bonuses and penalties: known ids or explicit values, the card's values
    local function checkEntries(list, expected, what, sign)
        H.ok(isList(list), id .. ': ' .. what .. ' list')
        local got = {}
        for _, e in ipairs(list) do
            H.ok(type(e.id) == 'string', id .. ': ' .. what .. ' entry id')
            local known = Config.Bonuses[e.id]
            H.ok(known ~= nil or type(e.points) == 'number' or type(e.pctOfPoints) == 'number',
                ('%s: %s %s is in Config.Bonuses or has an explicit value'):format(id, what, tostring(e.id)))
            local value = e.points or e.pctOfPoints or (known and known.value)
            H.ok(type(value) == 'number' and value * sign > 0, ('%s: %s %s has the right sign'):format(id, what, tostring(e.id)))
            got[e.id] = e
        end
        for bid, want in pairs(expected or {}) do
            local e = got[bid]
            if H.ok(e ~= nil, ('%s: %s %s from the card'):format(id, what, bid)) then
                if want.points then H.eq(e.points, want.points, id .. ': ' .. bid .. ' points') end
                if want.pct then H.near(e.pctOfPoints, want.pct, 1e-9, id .. ': ' .. bid .. ' pctOfPoints') end
                H.eq(e.each == true, want.each == true, id .. ': ' .. bid .. ' each')
                local known = Config.Bonuses[bid]
                if known and want.points then H.eq(known.kind, 'points', id .. ': ' .. bid .. ' kind') end
                if known and want.pct then H.eq(known.kind, 'pct', id .. ': ' .. bid .. ' kind') end
            end
        end
        for bid in pairs(got) do H.ok(expected and expected[bid] ~= nil, ('%s: %s %s is on the card'):format(id, what, bid)) end
    end
    checkEntries(def.bonuses, BONUSES[id], 'bonus', 1)
    checkEntries(def.penalties, PENALTIES[id], 'penalty', -1)

    report('%-21s %d locations, %d vectors, nearest location gap %.0f m, nearest point to a start %.1f m (hostile %.1f m), farthest %.0f m, max dz %.1f m, %d armed',
        id, #locs, nVec, minGap, nearest, nearestHostile, far, dzMax, armed)
    return def
end

for _, id in ipairs(ORDER) do checkMission(id) end

-- ── card-specific checks ────────────────────────────────────────────────────
local function obj(id, i) return defs[id] and defs[id].objectives[i] or {} end
local function each(id, fn) for li, loc in ipairs(defs[id] and defs[id].locations or {}) do fn(li, loc) end end

-- Warrant Service
do
    local o, s = obj('warrant_service', 1), obj('warrant_service', 2)
    H.eq(o.block, 'flee_arrest', 'warrant: objective 1 flee_arrest')
    H.eq(o.mode, 'door', 'warrant: door mode')
    H.eq(o.knock.label, 'Knock and announce', 'warrant: knock label')
    H.near(o.responses.surrender, 0.5, 1e-9, 'warrant: surrender 50%')
    H.near(o.responses.flee, 0.3, 1e-9, 'warrant: flee 30%')
    H.near(o.responses.fight, 0.2, 1e-9, 'warrant: fight 20%')
    H.eq(o.associates.count, 1, 'warrant: 1 associate (scales)')
    H.eq(o.weapons[1], 'WEAPON_PISTOL', 'warrant: the suspect fights with a pistol')
    H.eq(o.escape.distance, 400, 'warrant: escape 400 m')
    H.eq(o.escape.seconds, 20, 'warrant: escape 20 s')
    H.eq(o.cuff.label, 'Cuff suspect', 'warrant: cuff label')
    H.eq(o.cuff.duration, 5000, 'warrant: cuff 5 s')
    H.eq(o.aliveBonus.id, 'suspect_alive', 'warrant: alive bonus id')
    H.eq(s.block, 'interact_points', 'warrant: objective 2 interact_points')
    H.eq(s.label, 'Search the property', 'warrant: search label')
    H.eq(s.progress.duration, 8000, 'warrant: search 8 s')
    each('warrant_service', function(li, loc)
        H.ok(#loc.associates >= 3, ('warrant: location %d has 3+ associate spawns (critical tier)'):format(li))
        H.ok(#loc.fleeTo >= 3, ('warrant: location %d has 3+ fleeTo points'):format(li))
        H.ok(d2(loc.suspect, loc.door) <= 3, ('warrant: location %d suspect at the door'):format(li))
        H.ok(d2(loc.door, loc.start.coords) <= loc.start.radius, ('warrant: location %d door within the 50 m start'):format(li))
        H.ok(facingError(loc.door, loc.start.coords) <= 90, ('warrant: location %d door heading faces out, towards the street'):format(li))
        H.ok(d2(loc.fleeTo[1], loc.door) <= 50, ('warrant: location %d flee path starts at the house'):format(li))
        H.ok(maxJump(loc.fleeTo) <= MAX_JUMP, ('warrant: location %d flee path has no jump over %.0f m'):format(li, MAX_JUMP))
        -- fleeTo leads away from the front: each point further from the start than the door
        local prev = d2(loc.door, loc.start.coords)
        for k, p in ipairs(loc.fleeTo) do
            local d = d2(p, loc.door)
            H.ok(d > 10 and d < 150, ('warrant: location %d fleeTo %d is %.0f m from the door'):format(li, k, d))
        end
        H.ok(d2(loc.fleeTo[#loc.fleeTo], loc.start.coords) > prev, ('warrant: location %d flee path ends away from the start'):format(li))
    end)
end

-- Manhunt
do
    local o = obj('manhunt', 1)
    H.eq(o.block, 'search_area', 'manhunt: search_area')
    H.eq(o.startRadius, 600, 'manhunt: 600 m circle')
    H.eq(table.concat(o.shrinkTo, ','), '300,150,50', 'manhunt: 600 -> 300 -> 150 -> 50')
    H.eq(o.clueCount, 3, 'manhunt: 3 clues')
    H.eq(#o.clueProps, 3, 'manhunt: 3 clue props')
    H.eq(o.clueProps[3], 'witness', 'manhunt: a witness NPC')
    H.eq(o.clueProgress.duration, 4000, 'manhunt: clue 4 s')
    H.eq(o.fugitives, 1, 'manhunt: 1 fugitive (scales)')
    H.eq(o.runDistance, 30.0, 'manhunt: runs within 30 m')
    H.eq(o.escape.distance, 300, 'manhunt: escape 300 m')
    H.eq(o.escape.seconds, 30, 'manhunt: escape 30 s')
    H.eq(o.givesUp.stun, true, 'manhunt: gives up when stunned')
    H.eq(o.givesUp.close.distance, 3.0, 'manhunt: within 3 m')
    H.eq(o.givesUp.close.seconds, 3, 'manhunt: for 3 s')
    H.eq(o.cuff.duration, 5000, 'manhunt: cuff 5 s')
    each('manhunt', function(li, loc)
        H.ok(loc.start.coords == loc.center, ('manhunt: location %d start = the circle centre'):format(li))
        H.ok(#loc.clues >= 6, ('manhunt: location %d has 6+ clue spots'):format(li))
        H.ok(#loc.hiding >= 6, ('manhunt: location %d has 6+ hiding spots'):format(li))
        for _, list in ipairs({ loc.clues, loc.hiding }) do
            for k, p in ipairs(list) do
                local d = d2(p, loc.center)
                H.ok(d <= 600 - 25, ('manhunt: location %d spot %d is %.0f m from the centre (inside 600 m)'):format(li, k, d))
            end
        end
    end)
end

-- Gang Shootout (the spec's Example file)
do
    local o, s = obj('gang_shootout', 1), obj('gang_shootout', 2)
    H.eq(table.concat(o.waves, ','), '7,7,6', 'gang: waves 7/7/6')
    H.eq(o.nextWave.aliveAtMost, 2, 'gang: next wave at 2 alive')
    H.eq(o.nextWave.afterSeconds, 90, 'gang: or after 90 s')
    H.eq(table.concat(o.weapons, ','), 'WEAPON_PISTOL,WEAPON_MICROSMG', 'gang: pistols and SMGs')
    H.eq(o.accuracy, 25, 'gang: accuracy 25')
    H.eq(o.armour, 0, 'gang: armour 0')
    H.near(o.surrender.chance, 0.30, 1e-9, 'gang: 30% surrender')
    H.near(o.surrender.belowHealth, 0.25, 1e-9, 'gang: under 25% health')
    H.eq(o.blockTraffic, 120.0, 'gang: traffic blocked within 120 m')
    H.eq(s.label, 'Secure the scene', 'gang: secure the scene')
    H.eq(s.target and s.target.label, 'Secure the scene', 'gang: ox_target option reads Secure the scene')
    H.eq(s.progress.duration, 8000, 'gang: 8 s')
    each('gang_shootout', function(li, loc)
        H.ok(#loc.spawns >= 12, ('gang: location %d has 12+ hostile spawns'):format(li))
        H.ok(isVec3(loc.scene), ('gang: location %d scene marker'):format(li))
    end)
end

-- Hostage Rescue
do
    local o, p = obj('hostage_rescue', 1), obj('hostage_rescue', 2)
    H.eq(table.concat(o.waves, ','), '4', 'hostage: one wave of 4')
    H.eq(p.block, 'protect_rescue', 'hostage: protect_rescue')
    H.eq(p.count, 3, 'hostage: 3 hostages')
    H.eq(p.restrained, true, 'hostage: hands tied')
    H.eq(p.freeTime, 6000, 'hostage: cut restraints 6 s')
    H.eq(p.target.label, 'Cut restraints', 'hostage: cut restraints label')
    H.eq(p.hitPenalty, 50, 'hostage: hit penalty 50')
    H.eq(p.failIfDies, true, 'hostage: a death fails')
    each('hostage_rescue', function(li, loc)
        H.ok(#loc.spawns >= math.ceil(Config.Blocks.hostile_waves.spawnPointsPerHostile * 4), ('hostage: location %d has 6+ hostile spots'):format(li))
        H.ok(#loc.hostages >= 3, ('hostage: location %d has 3 hostage spots'):format(li))
        -- everything inside is one small interior; the safe marker is outside it
        local far = 0
        for _, sp in ipairs(loc.spawns) do far = math.max(far, d2(sp, loc.spawns[1])) end
        H.ok(far <= 12, ('hostage: location %d hostile spots within one interior (%.1f m)'):format(li, far))
        for _, h in ipairs(loc.hostages) do H.ok(d2(h, loc.spawns[1]) <= 8, ('hostage: location %d hostages inside'):format(li)) end
        for _, sp in ipairs(loc.spawns) do H.ok(d2(loc.safe, sp) >= 7, ('hostage: location %d safe marker outside'):format(li)) end
        H.ok(d2(loc.spawns[1], loc.start.coords) <= loc.start.radius, ('hostage: location %d building within the 60 m start'):format(li))
    end)
end

-- Bomb Disposal
do
    local s, k = obj('bomb_disposal', 1), obj('bomb_disposal', 2)
    H.eq(s.block, 'interact_points', 'bomb: search with interact_points')
    H.eq(s.target.label, 'Search', 'bomb: "Search"')
    H.eq(s.progress.duration, 3000, 'bomb: search 3 s')
    H.eq(s.hidden.count, 1, 'bomb: 1 device (scales)')
    H.ok(type(s.hidden.prop) == 'string' and s.hidden.prop ~= '', 'bomb: device prop')
    H.eq(s.fastBonus.seconds, 120, 'bomb: found within 2 minutes')
    H.eq(s.fastBonus.id, 'devices_found_fast', 'bomb: fast bonus id')
    H.eq(k.block, 'skill_check', 'bomb: defuse with skill_check')
    H.eq(k.targets, 'shared:devices', 'bomb: targets the found devices')
    H.eq(table.concat(k.checks, ','), 'easy,medium,medium,hard', 'bomb: easy, medium, medium, hard')
    H.eq(k.missPenalty, 30, 'bomb: a miss costs 30 s')
    H.eq(k.failAfter, 2, 'bomb: 2 misses in a row set it off')
    each('bomb_disposal', function(li, loc)
        H.ok(#loc.hiding >= 6 and #loc.hiding <= Config.Blocks.interact_points.points[2], ('bomb: location %d has 6-10 hiding spots'):format(li))
        for n, p in ipairs(loc.hiding) do
            H.ok(d2(p, loc.start.coords) <= loc.start.radius, ('bomb: location %d spot %d within 50 m of the start'):format(li, n))
        end
    end)
end

-- Armored Truck Escort: road routes
do
    local o = obj('armored_truck_escort', 1)
    H.eq(o.block, 'escort', 'truck: escort')
    H.eq(o.vehicle, 'stockade', 'truck: stockade')
    H.eq(o.speed, 60, 'truck: 60 km/h')
    H.eq(o.stoppedFail, 60, 'truck: fails when stopped 60 s')
    H.eq(o.clearRadius, 100.0, 'truck: no attacker within 100 m at the destination')
    H.eq(o.ambush.waves, 2, 'truck: 2 ambush waves')
    H.eq(o.ambush.carsPerWave, 2, 'truck: 2 cars per wave')
    H.eq(o.ambush.perCar, 2, 'truck: 2 attackers per car')
    local R = Config.Builder.route
    each('armored_truck_escort', function(li, loc)
        local pts = loc.route.points
        local len = polyLen(pts)
        H.ok(len >= R.minLength and len <= R.maxLength, ('truck: route %d is %.0f m (0.8-8 km)'):format(li, len))
        local ends = d2(pts[1], pts[#pts])
        H.ok(ends >= R.minStartEndGap, ('truck: route %d start and end %.0f m apart (300 m+)'):format(li, ends))
        H.ok(d2(loc.start.coords, pts[1]) < 1, ('truck: route %d starts at the depot (the start)'):format(li))
        local maxGap = 0
        for i = 2, #pts do
            local g = d2(pts[i - 1], pts[i])
            maxGap = math.max(maxGap, g)
            H.ok(g <= R.maxGap, ('truck: route %d waypoint gap %d is %.0f m (a waypoint every %.0f m)'):format(li, i, g, R.maxGap))
            H.ok(g >= 5, ('truck: route %d no duplicate waypoints'):format(li))
        end
        H.ok(#loc.ambushPoints >= Config.Blocks.escort.ambushPoints[3], ('truck: route %d has 5+ ambush points'):format(li))
        for i, a in ipairs(loc.ambushPoints) do
            H.ok(distToPolyline(a, pts) <= 15, ('truck: route %d ambush point %d is on the route'):format(li, i))
            for j = i + 1, #loc.ambushPoints do
                local g = d2(a, loc.ambushPoints[j])
                H.ok(g >= Config.Blocks.escort.ambushGap, ('truck: route %d ambush points %d and %d are %.0f m apart'):format(li, i, j, g))
            end
        end
        for _, st in ipairs(loc.route.stops or {}) do
            H.ok(type(st.at) == 'number' and st.at > 1 and st.at < #pts, ('truck: route %d stop index in the route'):format(li))
            H.ok(st.wait >= Config.Blocks.escort.stopWait[1] and st.wait <= Config.Blocks.escort.stopWait[2], ('truck: route %d stop wait'):format(li))
        end
        H.ok(#(loc.route.stops or {}) <= Config.Blocks.escort.stops[2], ('truck: route %d at most 5 stops'):format(li))
        report('route %d %-58s %5.0f m, %2d waypoints, max gap %3.0f m, start-end %4.0f m, %d ambush points',
            li, loc.label, len, #pts, maxGap, ends, #loc.ambushPoints)
    end)
end

-- Armored Truck Escort (integration rebuild on GTA V road nodes): every ambush point is a vec4 ON the route whose
-- heading is the truck's direction of travel there (the block lines the ambush cars up along it); the depot heading
-- follows the road; the destination is reached in 2D (escort `arrival`, like the waypoints) and the last waypoint
-- is 150 m+ past the last ambush point, so no wave spawns inside the arrival / clear area.
do
    local function hdg(a, b) return (math.deg(math.atan(-(b.x - a.x), b.y - a.y)) + 360) % 360 end
    local function dh(a, b) return math.abs((a - b + 180) % 360 - 180) end
    each('armored_truck_escort', function(li, loc)
        local pts = loc.route.points
        for i, a in ipairs(loc.ambushPoints) do
            H.ok(isVec4(a), ('truck: route %d ambush point %d is a vec4 (heading)'):format(li, i))
            local best, seg = math.huge, 1
            for j = 1, #pts - 1 do
                local d = distToPolyline(a, { pts[j], pts[j + 1] })
                if d < best then best, seg = d, j end
            end
            H.ok(best <= 8.0, ('truck: route %d ambush point %d lies on the route (%.1f m; the road node, the waypoint chord cuts curves)'):format(li, i, best))
            H.ok(a.w ~= nil and dh(a.w, hdg(pts[seg], pts[seg + 1])) <= 30,
                ('truck: route %d ambush point %d faces the direction of travel'):format(li, i))
            H.ok(d2(a, pts[#pts]) >= 150, ('truck: route %d ambush point %d is 150 m+ from the destination'):format(li, i))
            H.ok(d2(a, pts[1]) >= 200, ('truck: route %d ambush point %d is 200 m+ from the depot'):format(li, i))
        end
        for i = 2, #pts - 1 do
            -- a waypoint every turn: consecutive segments of one route never fold back
            H.ok(dh(hdg(pts[i - 1], pts[i]), hdg(pts[i], pts[i + 1])) <= 90, ('truck: route %d no U-turn at waypoint %d'):format(li, i))
        end
    end)
    local o = obj('armored_truck_escort', 1)
    H.eq(o.arrival, 20.0, 'truck: 20 m arrival circle (2D in the escort block)')
end

-- Gang Shootout / Kingpin (integration): the spawn points were moved onto the hideouts' road network (container-yard
-- lanes, trailer-park loop, yard tracks, driveways) so none is inside a container or building; they stay spread out.
do
    for _, id in ipairs({ 'gang_shootout', 'weekly_boss_kingpin' }) do
        local gap = id == 'gang_shootout' and 7.0 or 6.0
        each(id, function(li, loc)
            local sp = loc.spawns
            local minGap = math.huge
            for i = 1, #sp do
                for j = i + 1, #sp do minGap = math.min(minGap, d2(sp[i], sp[j])) end
                if loc.boss then minGap = math.min(minGap, d2(sp[i], loc.boss)) end
            end
            H.ok(minGap >= gap - 0.01, ('%s: location %d spawn points %.0f m+ apart (%.1f m)'):format(id, li, gap, minGap))
            H.ok(d2(loc.scene, loc.start.coords) >= Config.Builder.minSpawnFromStart, ('%s: location %d scene 30 m+ from the start'):format(id, li))
            if loc.boss then
                H.ok(d3(loc.boss, loc.start.coords) >= Config.Builder.minSpawnFromStart, ('%s: location %d boss 30 m+ from the start'):format(id, li))
            end
        end)
    end
end

-- Prison Break: outside the walls and outside the no-build circle
do
    local o = obj('prison_break', 1)
    H.eq(o.mode, 'scatter', 'prison: scatter mode')
    H.eq(o.suspects, 5, 'prison: 5 inmates (scale)')
    H.near(o.armedShare, 0.4, 1e-9, 'prison: 2 in every 5 armed')
    H.eq(o.weapons[1], 'WEAPON_PISTOL', 'prison: pistols')
    H.eq(o.fireWithin, 15.0, 'prison: fire within 15 m')
    H.eq(o.escape.distance, 600, 'prison: escape 600 m')
    H.eq(o.escape.seconds, 30, 'prison: escape 30 s')
    H.eq(o.givesUp.aim, 10.0, 'prison: aimed at within 10 m')
    H.eq(o.givesUp.stun, true, 'prison: stunned')
    H.eq(o.givesUp.close.distance, 3.0, 'prison: within 3 m')
    H.eq(o.givesUp.close.seconds, 3, 'prison: for 3 s')
    H.eq(o.armedGivesUp.stun, true, 'prison: armed give up when stunned')
    H.near(o.armedGivesUp.belowHealth, 0.5, 1e-9, 'prison: armed give up below 50%')
    H.eq(o.cuff.duration, 5000, 'prison: cuff 5 s')
    H.eq(o.aliveBonus.id, 'inmate_alive', 'prison: +10 per inmate alive (id)')
    H.eq(o.aliveBonus.points, 10, 'prison: +10 per inmate alive')
    H.eq(o.aliveBonus.each, true, 'prison: each')
    local zone
    for _, z in ipairs(ZONES) do if z.label == 'Bolingbroke interior' then zone = z end end
    H.ok(zone ~= nil, 'prison: the Bolingbroke zone is configured')
    each('prison_break', function(li, loc)
        H.ok(#loc.spawns >= 5, ('prison: location %d has 5+ inmate spawns'):format(li))
        H.ok(#loc.routes >= 2, ('prison: location %d has 2+ escape routes'):format(li))
        local nearestMid = math.huge
        eachVec(loc, 'loc', function(p)
            nearestMid = math.min(nearestMid, d2(p, PRISON_MIDDLE))
            H.ok(d2(p, zone.coords) > zone.radius, ('prison: location %d point outside the 180 m circle'):format(li))
            H.ok(d2(p, PRISON_MIDDLE) >= 230, ('prison: location %d point outside the walls (%.0f m from the middle)'):format(li, d2(p, PRISON_MIDDLE)))
        end)
        for _, sp in ipairs(loc.spawns) do
            H.ok(d2(sp, loc.start.coords) <= 60, ('prison: location %d inmates spawn at the breakout point'):format(li))
        end
        for r, route in ipairs(loc.routes) do
            H.ok(#route >= 3, ('prison: location %d route %d has 3+ points'):format(li, r))
            local fromSpawn = math.huge
            for _, sp in ipairs(loc.spawns) do fromSpawn = math.min(fromSpawn, d2(route[1], sp)) end
            H.ok(fromSpawn <= 100, ('prison: location %d route %d starts at the breakout (%.0f m from a spawn)'):format(li, r, fromSpawn))
            H.ok(maxJump(route) <= MAX_JUMP, ('prison: location %d route %d has no jump over %.0f m'):format(li, r, MAX_JUMP))
            local first, lastP = route[1], route[#route]
            H.ok(d2(lastP, PRISON_MIDDLE) > d2(first, PRISON_MIDDLE) + 150, ('prison: location %d route %d heads away from the prison'):format(li, r))
        end
        report('prison %d %-44s nearest point %.0f m from the middle, %.0f m from the zone centre',
            li, loc.label, nearestMid, d2(loc.start.coords, zone.coords))
    end)
end

-- Weekly Boss: Kingpin
do
    local o, s = obj('weekly_boss_kingpin', 1), obj('weekly_boss_kingpin', 2)
    H.eq(defs.weekly_boss_kingpin and defs.weekly_boss_kingpin.id, 'weekly_boss_kingpin', 'kingpin: the exact id')
    H.eq(table.concat(o.waves, ','), '8,8,7,7', 'kingpin: waves 8/8/7/7')
    H.eq(o.accuracy, 30, 'kingpin: accuracy 30')
    H.eq(o.armour, 25, 'kingpin: armour 25')
    local w = set(o.weapons)
    H.ok(w.WEAPON_PISTOL and (w.WEAPON_SMG or w.WEAPON_MICROSMG) and w.WEAPON_PUMPSHOTGUN, 'kingpin: pistols, SMGs and shotguns')
    H.ok(type(o.boss) == 'table' and type(o.boss.model) == 'string', 'kingpin: boss model')
    H.eq(o.boss.health, 400, 'kingpin: boss health 400')
    H.eq(o.boss.armour, 100, 'kingpin: boss armour 100')
    H.eq(o.boss.weapon, 'WEAPON_ASSAULTRIFLE', 'kingpin: boss assault rifle')
    H.ok(type(o.boss.surrender) == 'table', 'kingpin: the Kingpin can be arrested alive')
    H.eq(o.boss.spawn, 'boss', 'kingpin: boss spawn key')
    H.eq(s.label, 'Secure the scene', 'kingpin: secure the scene')
    H.eq(s.target and s.target.label, 'Secure the scene', 'kingpin: ox_target option reads Secure the scene')
    H.eq(s.progress.duration, 8000, 'kingpin: 8 s')
    H.eq(armedOf(o), 31, 'kingpin: 30 hostiles + the Kingpin (within the 40 budget)')
    each('weekly_boss_kingpin', function(li, loc)
        H.ok(#loc.spawns >= 16, ('kingpin: location %d has 16+ hostile spawns'):format(li))
        H.ok(#loc.spawns >= math.ceil(Config.Blocks.hostile_waves.spawnPointsPerHostile * 8), ('kingpin: location %d spawns for the largest wave'):format(li))
        H.ok(d2(loc.boss, loc.start.coords) <= loc.start.radius, ('kingpin: location %d compound within the 100 m start'):format(li))
    end)
end

-- hostile_waves spawn points: at least 1.5 x the largest wave
for _, id in ipairs({ 'gang_shootout', 'hostage_rescue', 'weekly_boss_kingpin' }) do
    local o = obj(id, 1)
    local maxWave = 0
    for _, n in ipairs(o.waves or {}) do maxWave = math.max(maxWave, n) end
    each(id, function(li, loc)
        H.ok(#loc.spawns >= math.ceil(Config.Blocks.hostile_waves.spawnPointsPerHostile * maxWave - 1e-9),
            ('%s: location %d has %d spawn points for a wave of %d'):format(id, li, #loc.spawns, maxWave))
    end)
end

-- ── the real blocks: defaults + validate for every location (built-in files are trusted) ─
CP.Npc = CP.Npc or { setState = function() end, getState = function() end, rollSurrender = function() return false end,
    enableCuff = function() end, onDamaged = function() end, onDeath = function() end }
local present = {}
for _, b in ipairs({ 'checkpoint_route', 'interact_points', 'skill_check', 'hostile_waves', 'protect_rescue', 'flee_arrest', 'pursuit', 'escort', 'search_area' }) do
    local f = io.open(H.root .. 'blocks/' .. b .. '/server.lua', 'r')
    if f then
        f:close()
        local ok, err = pcall(H.load, 'blocks/' .. b .. '/server.lua')
        if H.ok(ok, 'block ' .. b .. ' loads (' .. tostring(err) .. ')') then present[b] = CP.Blocks.get(b) ~= nil end
    end
end
local missing = {}
for _, id in ipairs(ORDER) do
    local def = defs[id]
    if def then
        local mission = U.deepcopy(def)
        mission.source = 'builtin'
        for i, o in ipairs(mission.objectives) do
            local impl = present[o.block] and CP.Blocks.get(o.block)
            if impl then
                local copy = U.deepcopy(o)
                if impl.defaults then copy = impl.defaults(copy) or copy end
                mission.objectives[i] = copy
                for li, loc in ipairs(mission.locations) do
                    local okCall, res, why = pcall(impl.validate, copy, mission, loc)
                    H.ok(okCall and res == true, ('%s: objective %d (%s) passes the block validate at location %d (%s)'):format(id, i, o.block, li, tostring(why or res)))
                end
                if impl.armedCount then
                    H.eq(impl.armedCount(U.deepcopy(o)), armedOf(o), ('%s: objective %d block armedCount'):format(id, i))
                end
                if impl.requiredPoints then
                    for _, key in ipairs(impl.requiredPoints(U.deepcopy(o))) do
                        each(id, function(li, loc) H.ok(loc[key] ~= nil, ('%s: location %d has required point "%s"'):format(id, li, key)) end)
                    end
                end
            else
                missing[o.block] = true
            end
        end
    end
end
for b in pairs(missing) do report('block %s is not written yet: its objectives were checked against ARCHITECTURE 3.3 only', b) end

-- ── the loader: CP.Missions.normalize accepts every file (stub blocks for the missing ones) ─
do
    for b in pairs(missing) do
        CP.Blocks.register(b, { defaults = function(o) return o end, validate = function() return true end, armedCount = function() return 0 end })
    end
    local ok, err = pcall(H.load, 'modules/missions/server.lua')
    if H.ok(ok, 'modules/missions loads (' .. tostring(err) .. ')') and CP.Missions and CP.Missions.normalize then
        for _, id in ipairs(ORDER) do
            local def = defs[id]
            if def then
                local n, why = CP.Missions.normalize(U.deepcopy(def), { source = 'builtin', filePath = 'missions/builtin/' .. id .. '.lua' })
                if n then
                    H.eq(n.id, id, id .. ': normalize keeps the id')
                    H.eq(#n.bonuses, #def.bonuses, id .. ': normalize keeps every bonus')
                    H.eq(#n.penalties, #def.penalties, id .. ': normalize keeps every penalty')
                    H.eq(#n.scaling, #def.scaling, id .. ': normalize keeps every scaling path')
                    H.eq(n.isBoss, id == 'weekly_boss_kingpin', id .. ': isBoss')
                else
                    -- the loader sets d.source = 'builtin' before the blocks' validate (engine_a fix), so the
                    -- Mission Builder's allowed-model lists no longer reject Prison Break's inmates or the Kingpin
                    H.ok(false, id .. ': CP.Missions.normalize accepts it (' .. tostring(why) .. ')')
                end
            end
        end
    end
end

-- ── the REAL loader end to end: CP.Missions.loadAll with every real block → all 14 built-ins valid ─
do
    for _, b in ipairs({ 'checkpoint_route', 'interact_points', 'skill_check', 'hostile_waves', 'protect_rescue',
                         'flee_arrest', 'pursuit', 'escort', 'search_area' }) do
        if not CP.Blocks.get(b) or missing[b] then
            local okB, errB = pcall(H.load, 'blocks/' .. b .. '/server.lua')
            H.ok(okB, 'real block loads: ' .. b .. ' (' .. tostring(errB) .. ')')
        end
    end
    local content = LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua')
    local ids = content and assert(load(content, '@index.lua', 't', {}))() or {}
    H.eq(#ids, 14, 'missions/builtin/index.lua lists all 14 built-in missions')
    if CP.Missions and CP.Missions.loadAll then
        local okL, summary = pcall(CP.Missions.loadAll)
        if H.ok(okL and type(summary) == 'table', 'CP.Missions.loadAll runs (' .. tostring(not okL and summary or '') .. ')') then
            local failed = summary.failed or {}
            H.eq(summary.builtin, 14, 'CP.Missions.loadAll: 14 built-in missions loaded')
            H.eq(#failed, 0, 'CP.Missions.loadAll: nothing rejected' .. (failed[1] and (' (' .. tostring(failed[1].id) .. ': ' .. tostring(failed[1].error) .. ')') or ''))
            for _, id in ipairs(ids) do
                local d = CP.Missions.get(id)
                H.ok(d ~= nil and d.source == 'builtin' and d.filePath == 'missions/builtin/' .. id .. '.lua', 'loaded as a valid built-in: ' .. id)
                H.ok(d ~= nil and CP.Missions.isEnabled(id), 'enabled: ' .. id)
            end
            local kp = CP.Missions.get('weekly_boss_kingpin')
            H.ok(kp ~= nil and kp.isBoss == true, 'the Kingpin loads as the Weekly Boss')
            report('LOADER: CP.Missions.loadAll loaded %d built-ins, %d rejected', summary.builtin or 0, #failed)
        end
    end
end

-- ── missions/builtin/index.lua (owned by another slice) must list these ids ────
do
    local content = LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua')
    if content then
        local chunk = load(content, '@index.lua', 't', {})
        local list = chunk and select(2, pcall(chunk)) or {}
        local listed = set(type(list) == 'table' and list or {})
        for _, id in ipairs(ORDER) do
            if not listed[id] then report('missions/builtin/index.lua does not list %s yet', id) end
        end
    else
        report('missions/builtin/index.lua does not exist yet; it must list the 8 ids of this slice')
    end
end

return H
