-- tests/missions_a_spec.lua · the missions_a built-in mission files and missions/builtin/index.lua.
--   lua5.4 tests/run.lua missions_a
-- Each file is loaded exactly as modules/missions loads it (LoadResourceFile + a sandbox whose only
-- globals are RegisterMission, vec3/vec4/vector3/vector4, math, string, table, pairs, ipairs, type,
-- tonumber, tostring) and checked against the spec's catalog, its mission card, ARCHITECTURE 3.3 and
-- the Mission Builder guardrails. When the objective blocks it uses exist, the definition also goes
-- through CP.Missions.normalize (block defaults + validate) with no warnings.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local notes = {}
local function note(fmt, ...) notes[#notes + 1] = fmt:format(...) end

-- ── helpers ─────────────────────────────────────────────────────────────────
local VMT = getmetatable(vec3(0, 0, 0))
local function isVec(v) return type(v) == 'table' and getmetatable(v) == VMT end
local function isVec4(v) return isVec(v) and type(v.w) == 'number' end
local function d2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

local function segDist(p, a, b)
    local vx, vy = b.x - a.x, b.y - a.y
    local len2 = vx * vx + vy * vy
    local t = len2 > 0 and math.max(0, math.min(1, ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2)) or 0
    return math.sqrt((p.x - a.x - t * vx) ^ 2 + (p.y - a.y - t * vy) ^ 2)
end
local function distToRoute(p, pts, loop)
    local best = math.huge
    for i = 1, #pts - 1 do best = math.min(best, segDist(p, pts[i], pts[i + 1])) end
    if loop then best = math.min(best, segDist(p, pts[#pts], pts[1])) end
    return best
end

local function routeLength(pts, loop)
    local s = 0
    for i = 2, #pts do s = s + d2(pts[i - 1], pts[i]) end
    if loop then s = s + d2(pts[#pts], pts[1]) end
    return s
end

-- Every vector anywhere inside t (recursive), with a readable path.
local function eachVec(t, path, fn, seen)
    seen = seen or {}
    if isVec(t) then fn(t, path) return end
    if type(t) ~= 'table' or seen[t] then return end
    seen[t] = true
    for k, v in pairs(t) do eachVec(v, path .. '.' .. tostring(k), fn, seen) end
end

local function findKey(t, pred, path, out, seen)
    out, seen = out or {}, seen or {}
    if type(t) ~= 'table' or seen[t] or isVec(t) then return out end
    seen[t] = true
    for k, v in pairs(t) do
        local p = path .. '.' .. tostring(k)
        if pred(k) then out[#out + 1] = p end
        findKey(v, pred, p, out, seen)
    end
    return out
end

local function contains(list, v)
    for _, x in ipairs(list or {}) do if x == v then return true end end
    return false
end

local function loadMission(id)
    local path = 'missions/builtin/' .. id .. '.lua'
    local src = LoadResourceFile('Crimson-Police', path)
    if not H.ok(type(src) == 'string' and #src > 0, path .. ' exists') then return nil end
    local calls = {}
    local env = {
        RegisterMission = function(def) calls[#calls + 1] = def end,
        vec3 = vec3, vec4 = vec4, vector3 = vector3, vector4 = vector4,
        math = math, string = string, table = table, pairs = pairs, ipairs = ipairs,
        type = type, tonumber = tonumber, tostring = tostring,
    }
    local chunk, err = load(src, '@' .. path, 't', env)
    if not H.ok(chunk ~= nil, path .. ' compiles: ' .. tostring(err)) then return nil end
    local ok, runErr = pcall(chunk)
    if not H.ok(ok, path .. ' runs: ' .. tostring(runErr)) then return nil end
    H.eq(#calls, 1, path .. ': exactly one RegisterMission call')
    H.ok(src:match('^%-%-') ~= nil, path .. ': starts with a header comment')
    return calls[1], src
end

-- ── the contract ────────────────────────────────────────────────────────────
-- Mission catalog + mission cards (times and cooldowns in seconds).
local CATALOG = {
    beat_patrol             = { type = 'patrol',   min = 1, max = 1, stars = 1, timeLimit = 480, cooldown = 600, locations = 6 },
    business_check          = { type = 'patrol',   min = 1, max = 1, stars = 1, timeLimit = 600, cooldown = 600, locations = 5 },
    street_race_bust        = { type = 'patrol',   min = 1, max = 2, stars = 2, timeLimit = 240, cooldown = 900, locations = 5 },
    evoc_course             = { type = 'training', min = 1, max = 1, stars = 2, timeLimit = 240, cooldown = 600, locations = 3 },
    pursuit_sim             = { type = 'training', min = 1, max = 1, stars = 3, timeLimit = 300, cooldown = 900, locations = 5 },
    stolen_vehicle_takedown = { type = 'training', min = 1, max = 2, stars = 3, timeLimit = 480, cooldown = 900, locations = 5 },
}
local ORDER = { 'beat_patrol', 'business_check', 'street_race_bust', 'evoc_course', 'pursuit_sim', 'stolen_vehicle_takedown' }
local NO_VEHICLE_PENALTIES = {
    street_race_bust = true, stolen_vehicle_takedown = true, armored_truck_escort = true, warrant_service = true,
    gang_shootout = true, hostage_rescue = true, prison_break = true, weekly_boss_kingpin = true,
}

-- The playable map (Los Santos and Blaine County): every point must be inside it.
local MAP = { x = { -4000, 4600 }, y = { -4200, 8000 } }

-- ARCHITECTURE 3.3: every objective field (and the keys of its sub-tables) per block.
local COMMON = { block = true, label = true, minSeconds = true, presenceRange = true }
local FIELDS = {
    checkpoint_route = {
        checkpoints = true, use = true, count = true, radius = true, stopFor = true, vehicleRequired = true,
        medals = { gold = true, silver = true, bronze = true }, contactPenalty = true, timerStart = true,
        failIfUndriveable = true,
    },
    interact_points = {
        points = true, use = true, count = true,
        target = { label = true, icon = true, radius = true },
        progress = { label = true, duration = true, anim = true },
        roll = { outcomes = { ['*'] = { id = true, chance = true, followUp = { label = true, duration = true } } } },
        logResult = { choices = true, correct = true },
        hidden = { count = true, prop = true, label = true },
        fastBonus = { seconds = true, id = true },
    },
    pursuit = {
        mode = true, vehicles = true, models = true, suspectsPerVehicle = true, spawn = true, spawns = true,
        route = true, speed = true, style = true,
        trigger = { distance = true, lights = true, ahead = true },
        stopped = { speed = true, seconds = true }, footFlee = true, surrenderOnAim = true,
        arrest = { label = true, duration = true },
        hold = true, lost = { distance = true, seconds = true }, duration = true,
        medals = { gold = true, silver = true, bronze = true },
        escape = { distance = true, seconds = true }, complete = true, ramSpeed = true, ramPenaltyId = true,
        neverShoots = true,
    },
}
-- Objective fields that name a location key.
local LOCATION_KEYS = { checkpoint_route = { 'checkpoints' }, interact_points = { 'points' }, pursuit = { 'spawn', 'spawns', 'route' } }

local function checkFields(id, where, t, allowed)
    for k, v in pairs(t) do
        local rule = allowed[k]
        if rule == nil and type(k) == 'number' then rule = allowed['*'] end
        H.ok(rule ~= nil, ('%s: %s.%s is not an ARCHITECTURE 3.3 field'):format(id, where, tostring(k)))
        if type(rule) == 'table' and type(v) == 'table' and not isVec(v) then
            checkFields(id, where .. '.' .. tostring(k), v, rule)
        end
    end
end

-- ── generic guardrails for one mission ──────────────────────────────────────
local function checkCommon(id, def)
    local c = CATALOG[id]
    H.eq(def.id, id, id .. ': id equals the file name')
    H.ok(type(def.label) == 'string' and #def.label > 0, id .. ': label')
    H.ok(type(def.description) == 'string' and #def.description > 20, id .. ': description')
    H.eq(def.type, c.type, id .. ': type')
    H.ok(type(def.departments) == 'table' and next(def.departments) == nil, id .. ': departments = {} (every department)')
    H.eq(def.minOfficers, c.min, id .. ': minOfficers')
    H.eq(def.maxOfficers, c.max, id .. ': maxOfficers')
    H.eq(def.difficulty, c.stars, id .. ': difficulty')
    H.eq(def.timeLimit, c.timeLimit, id .. ': timeLimit')
    H.eq(def.startTimeout, 600, id .. ': startTimeout')
    H.eq(def.cooldown, c.cooldown, id .. ': cooldown')
    if NO_VEHICLE_PENALTIES[id] then
        H.eq(def.vehiclePenalties, false, id .. ': vehiclePenalties = false')
    else
        H.ok(def.vehiclePenalties ~= false, id .. ': vehiclePenalties on')
    end
    H.ok(type(def.items) == 'table' and #def.items == 0, id .. ': no items')

    -- no payout field anywhere
    local payouts = findKey(def, function(k) return type(k) == 'string' and k:lower():find('payout', 1, true) ~= nil end, id)
    H.eq(#payouts, 0, id .. ': no payout field (' .. table.concat(payouts, ', ') .. ')')

    -- locations: count, labels, start, spacing
    local locs = def.locations
    H.ok(type(locs) == 'table' and #locs >= c.locations, ('%s: at least %d locations (has %d)'):format(id, c.locations, #(locs or {})))
    for i, loc in ipairs(locs) do
        H.ok(type(loc.label) == 'string' and #loc.label > 0, ('%s: location %d label'):format(id, i))
        H.ok(type(loc.start) == 'table' and isVec(loc.start.coords) and type(loc.start.radius) == 'number' and loc.start.radius > 0,
            ('%s: location %d start = { coords, radius }'):format(id, i))
    end
    for i = 1, #locs do
        for j = i + 1, #locs do
            local d = d2(locs[i].start.coords, locs[j].start.coords)
            H.ok(d >= 100, ('%s: locations %d and %d are %.0f m apart (100 m minimum)'):format(id, i, j, d))
        end
    end

    -- every point of every location: outside the no-build zones, sane height and heading
    local zones = Config.Builder.noBuildZones
    local count = 0
    for i, loc in ipairs(locs) do
        eachVec(loc, ('%s.locations[%d]'):format(id, i), function(v, path)
            count = count + 1
            for _, z in ipairs(zones) do
                local d = d2(v, z.coords)
                if d <= z.radius then H.ok(false, ('%s is %.0f m inside no-build zone %s'):format(path, z.radius - d, z.label)) end
            end
            H.ok(v.z > 0 and v.z < 400, ('%s: ground height %.2f is plausible'):format(path, v.z))
            H.ok(v.x >= MAP.x[1] and v.x <= MAP.x[2] and v.y >= MAP.y[1] and v.y <= MAP.y[2],
                ('%s (%.0f, %.0f) is inside the GTA V map'):format(path, v.x, v.y))
            if v.w ~= nil then H.ok(v.w >= 0 and v.w < 360, path .. ': heading in 0..360') end
        end)
    end
    H.ok(count > 0, id .. ': has points')
    note('%-24s %d locations, %d points checked against %d no-build zones', id, #locs, count, #zones)

    -- objectives: known block, labels, ARCHITECTURE 3.3 field names, location keys present everywhere
    H.ok(type(def.objectives) == 'table' and #def.objectives >= 1, id .. ': objectives')
    local armed = 0
    for oi, obj in ipairs(def.objectives) do
        local where = ('objectives[%d]'):format(oi)
        local allowed = FIELDS[obj.block]
        if H.ok(allowed ~= nil, ('%s: %s uses a known block (%s)'):format(id, where, tostring(obj.block))) then
            H.ok(type(obj.label) == 'string' and #obj.label > 0, id .. ': ' .. where .. ' label')
            H.ok(type(obj.minSeconds) == 'number' and obj.minSeconds > 0, id .. ': ' .. where .. ' minSeconds')
            local merged = {}
            for k, v in pairs(allowed) do merged[k] = v end
            for k in pairs(COMMON) do merged[k] = true end
            checkFields(id, where, obj, merged)
            for _, key in ipairs(LOCATION_KEYS[obj.block]) do
                local ref = obj[key]
                if ref ~= nil then
                    H.ok(type(ref) == 'string', ('%s: %s.%s is a location key'):format(id, where, key))
                    for li, loc in ipairs(locs) do
                        H.ok(loc[ref] ~= nil, ('%s: location %d has "%s" (from %s.%s)'):format(id, li, tostring(ref), where, key))
                    end
                end
            end
            if obj.block == 'pursuit' and obj.neverShoots ~= true then
                armed = armed + (obj.vehicles or 1) * (obj.suspectsPerVehicle or 1)
            end
        end
    end
    H.ok(armed <= Config.Builder.maxHostiles, ('%s: %d armed NPCs before scaling (budget %d)'):format(id, armed, Config.Builder.maxHostiles))

    -- scaling paths point at numeric fields
    for i, entry in ipairs(def.scaling or {}) do
        local path = type(entry) == 'table' and entry.path or entry
        H.ok(type(path) == 'string' and path:match('^objectives%.%d+%.'), ('%s: scaling %d is an objectives path'):format(id, i))
        local v = CP.U.getPath(def, path)
        H.ok(type(v) == 'number' or (type(v) == 'table' and #v > 0), ('%s: scaling %s points at a number (%s)'):format(id, tostring(path), tostring(v)))
        if type(entry) == 'table' and entry.max then
            H.ok(type(v) == 'number' and v <= entry.max, ('%s: scaling %s base is within its max'):format(id, path))
        end
    end

    -- bonuses and penalties: Config.Bonuses ids or explicit values; positive / negative sides
    for _, list in ipairs({ { def.bonuses, 1, 'bonuses' }, { def.penalties, -1, 'penalties' } }) do
        for _, e in ipairs(list[1] or {}) do
            local known = Config.Bonuses[e.id]
            local value = e.points or (e.pctOfPoints and e.pctOfPoints * 100) or (known and known.value)
            H.ok(known ~= nil or type(e.points) == 'number' or type(e.pctOfPoints) == 'number',
                ('%s: %s %s is in Config.Bonuses or carries a value'):format(id, list[3], tostring(e.id)))
            H.ok(type(value) == 'number' and value * list[2] > 0, ('%s: %s %s has the right sign'):format(id, list[3], tostring(e.id)))
            if known and e.points then H.eq(e.points, known.value, ('%s: %s value matches Config.Bonuses'):format(id, e.id)) end
            if known and known.each then H.eq(e.each, true, ('%s: %s counts each occurrence'):format(id, e.id)) end
        end
    end
end

local function bonusMap(list)
    local m = {}
    for _, e in ipairs(list or {}) do m[e.id] = e end
    return m
end

-- Road route checks: gaps (150 m; 200 m tolerated and reported), length, closure / open ends.
local function checkRoute(id, li, route, want)
    local where = ('%s: location %d route'):format(id, li)
    if not H.ok(type(route) == 'table' and type(route.points) == 'table', where .. ' = { points = {...} }') then return end
    local pts = route.points
    H.ok(#pts >= 6, where .. ' has waypoints')
    for i, p in ipairs(pts) do H.ok(isVec(p) and not isVec4(p), ('%s waypoint %d is a vec3'):format(where, i)) end
    local gaps = {}
    for i = 2, #pts do gaps[#gaps + 1] = { d2(pts[i - 1], pts[i]), i - 1 } end
    if route.loop then gaps[#gaps + 1] = { d2(pts[#pts], pts[1]), #pts } end
    for _, g in ipairs(gaps) do
        -- Route recording: a waypoint at least every 150 m (Config.Builder.route.maxGap).
        H.ok(g[1] <= Config.Builder.route.maxGap, ('%s gap after waypoint %d is %.0f m (150 m max)'):format(where, g[2], g[1]))
        H.ok(g[1] >= 2, ('%s has no duplicate waypoints (%d)'):format(where, g[2]))
    end
    -- Contiguous on the ground: no height jump a road cannot have (30% grade + 3 m of node noise),
    -- which catches a waypoint on a bridge or freeway above the road it belongs to.
    for i = 2, #pts + (route.loop and 1 or 0) do
        local a, b = pts[i - 1], pts[(i - 1) % #pts + 1]
        local dz = math.abs(a.z - b.z)
        H.ok(dz <= 0.3 * d2(a, b) + 3, ('%s waypoints %d-%d climb %.1f m in %.0f m'):format(where, i - 1, (i - 1) % #pts + 1, dz, d2(a, b)))
    end
    local len = routeLength(pts, route.loop)
    if want.loop ~= nil then H.eq(route.loop == true, want.loop, where .. ' loop flag') end
    if route.loop then
        H.ok(d2(pts[#pts], pts[1]) <= Config.Builder.route.loopClose, ('%s loop closes within 50 m (%.0f)'):format(where, d2(pts[#pts], pts[1])))
    else
        H.ok(d2(pts[#pts], pts[1]) >= Config.Builder.route.minStartEndGap, ('%s start and end are 300 m+ apart (%.0f)'):format(where, d2(pts[#pts], pts[1])))
    end
    local lo, hi = want.min or Config.Builder.route.minLength, want.max or Config.Builder.route.maxLength
    H.ok(len >= lo and len <= hi, ('%s length %.0f m within %d-%d m'):format(where, len, lo, hi))
    return pts, len
end

-- ── index.lua ───────────────────────────────────────────────────────────────
do
    local src = LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua')
    H.ok(src ~= nil, 'index.lua exists')
    local chunk = src and load(src, '@missions/builtin/index.lua', 't', {})
    local list = chunk and chunk()
    H.ok(type(list) == 'table', 'index.lua returns a list')
    local want = { 'beat_patrol', 'business_check', 'street_race_bust', 'evoc_course', 'pursuit_sim', 'stolen_vehicle_takedown',
        'warrant_service', 'manhunt', 'gang_shootout', 'hostage_rescue', 'bomb_disposal', 'armored_truck_escort',
        'prison_break', 'weekly_boss_kingpin' }
    H.eq(#(list or {}), 14, 'index.lua lists 14 built-in missions')
    for i, idv in ipairs(want) do H.eq((list or {})[i], idv, 'index.lua entry ' .. i) end
end

-- ── the six missions ────────────────────────────────────────────────────────
local defs = {}
for _, id in ipairs(ORDER) do
    local def = loadMission(id)
    if def then
        defs[id] = def
        checkCommon(id, def)
    end
end

-- Beat Patrol
do
    local def = defs.beat_patrol
    if def then
        local o = def.objectives[1]
        H.eq(#def.objectives, 1, 'beat_patrol: one objective')
        H.eq(o.block, 'checkpoint_route', 'beat_patrol: checkpoint_route')
        H.eq(o.checkpoints, 'checkpoints', 'beat_patrol: checkpoints key')
        H.eq(o.use, 'random', 'beat_patrol: random checkpoints')
        H.eq(o.count, 5, 'beat_patrol: 5 per run')
        H.eq(o.radius, 10.0, 'beat_patrol: 10 m markers')
        H.eq(o.stopFor, 10, 'beat_patrol: stop 10 s')
        H.eq(o.vehicleRequired, true, 'beat_patrol: driving a vehicle required')
        H.eq(o.policeVehicle, nil, 'beat_patrol: no old policeVehicle field')
        H.eq(o.medals, false, 'beat_patrol: no medals')
        H.eq(o.contactPenalty, 0, 'beat_patrol: contactPenalty = 0 (blocks_a request: no course clock)')
        H.eq(o.failIfUndriveable, false, 'beat_patrol: failIfUndriveable = false (only the time limit fails)')
        H.eq(#def.bonuses + #def.penalties, 0, 'beat_patrol: common bonuses and penalties only')
        for i, loc in ipairs(def.locations) do
            local cps = loc.checkpoints
            H.ok(#cps >= 8 and #cps <= 20, ('beat_patrol: district %d has %d checkpoint spots (8+)'):format(i, #cps))
            H.ok(d2(cps[1], loc.start.coords) < 1, ('beat_patrol: district %d starts at its first checkpoint'):format(i))
            local inside = 0
            for j, p in ipairs(cps) do
                H.ok(not isVec4(p), ('beat_patrol: district %d checkpoint %d is a vec3'):format(i, j))
                if d2(p, loc.start.coords) <= loc.start.radius then inside = inside + 1 end
                for k = j + 1, #cps do
                    H.ok(d2(p, cps[k]) >= 40, ('beat_patrol: district %d checkpoints %d and %d are 40 m+ apart'):format(i, j, k))
                end
            end
            H.eq(inside, 1, ('beat_patrol: district %d start circle holds only the first checkpoint'):format(i))
            for j, p in ipairs(cps) do
                H.ok(d2(p, loc.start.coords) <= 1500, ('beat_patrol: district %d checkpoint %d is in the district (%.0f m from the start)'):format(i, j, d2(p, loc.start.coords)))
            end
        end
        -- minSeconds flags a run as too_fast: it must stay below a fast legal run (5 stops of
        -- stopFor seconds plus the drives between them).
        H.ok(o.minSeconds <= o.count * o.stopFor + 30, ('beat_patrol: minSeconds %d leaves room for a fast legal run'):format(o.minSeconds))
    end
end

-- Business Check
do
    local def = defs.business_check
    if def then
        local o = def.objectives[1]
        H.eq(o.block, 'interact_points', 'business_check: interact_points')
        H.eq(o.points, 'doors', 'business_check: doors key')
        H.eq(o.use, 'random', 'business_check: random doors')
        H.eq(o.count, 4, 'business_check: 4 per run')
        H.eq(o.progress.duration, 5000, 'business_check: check door 5 s')
        H.eq(o.target.label, 'Check door', 'business_check: Check door')
        local out = o.roll.outcomes
        H.eq(#out, 2, 'business_check: two outcomes')
        H.eq(out[1].id, 'secure', 'business_check: secure outcome')
        H.near(out[1].chance, 0.75, 1e-9, 'business_check: secure 75%')
        H.eq(out[2].id, 'open', 'business_check: open outcome')
        H.near(out[2].chance, 0.25, 1e-9, 'business_check: open 25%')
        H.eq(out[2].followUp.label, 'Secure door', 'business_check: Secure door follow-up')
        H.eq(out[2].followUp.duration, 5000, 'business_check: Secure door 5 s')
        H.eq(o.logResult.choices[1], 'secure', 'business_check: log Secure')
        H.eq(o.logResult.choices[2], 'found_open', 'business_check: log Found open')
        H.eq(o.logResult.correct.secure, 'secure', 'business_check: correct secure')
        H.eq(o.logResult.correct.open, 'found_open', 'business_check: correct open')
        H.ok(contains(Config.Builder.allowed.animations, o.progress.anim), 'business_check: allowed animation')
        local b, p = bonusMap(def.bonuses), bonusMap(def.penalties)
        H.ok(b.correct_log and b.correct_log.points == 5 and b.correct_log.each, 'business_check: +5 each correct log')
        H.ok(p.wrong_log and p.wrong_log.points == -5 and p.wrong_log.each, 'business_check: -5 each wrong log')
        local total = 0
        for i, loc in ipairs(def.locations) do
            local doors = loc.doors
            total = total + #doors
            H.ok(#doors >= 5 and #doors <= 6, ('business_check: area %d has %d businesses (5-6)'):format(i, #doors))
            H.ok(d2(doors[1].coords, loc.start.coords) < 1, ('business_check: area %d starts at its first business'):format(i))
            local inside = 0
            for j, d in ipairs(doors) do
                H.ok(isVec4(d.coords), ('business_check: area %d door %d is a vec4'):format(i, j))
                H.ok(type(d.heading) == 'number' and math.abs(d.heading - d.coords.w) < 1e-6, ('business_check: area %d door %d heading'):format(i, j))
                H.ok(type(d.label) == 'string' and #d.label > 3, ('business_check: area %d door %d label'):format(i, j))
                if d2(d.coords, loc.start.coords) <= loc.start.radius then inside = inside + 1 end
                for k = j + 1, #doors do
                    H.ok(d2(d.coords, doors[k].coords) >= 5, ('business_check: area %d doors %d and %d are distinct'):format(i, j, k))
                end
            end
            H.ok(inside >= 1, ('business_check: area %d start circle holds its first door'):format(i))
            for j, d in ipairs(doors) do
                H.ok(d2(d.coords, loc.start.coords) <= 1500, ('business_check: area %d door %d is in the area (%.0f m from the start)'):format(i, j, d2(d.coords, loc.start.coords)))
            end
        end
        H.ok(total >= 12, ('business_check: %d businesses in total (12+)'):format(total))
    end
end

-- Street Race Bust
do
    local def = defs.street_race_bust
    if def then
        local o = def.objectives[1]
        H.eq(o.block, 'pursuit', 'street_race_bust: pursuit')
        H.eq(o.mode, 'stop', 'street_race_bust: stop mode')
        H.eq(o.vehicles, 3, 'street_race_bust: 3 racers')
        H.eq(o.suspectsPerVehicle, 1, 'street_race_bust: one driver each')
        H.eq(o.route, 'route', 'street_race_bust: route key')
        H.eq(o.spawns, 'spawns', 'street_race_bust: spawns key')
        H.eq(o.trigger, 'arrive', 'street_race_bust: race starts on arrival')
        H.eq(o.stopped.speed, 5.0, 'street_race_bust: stopped below 5 km/h')
        H.eq(o.stopped.seconds, 5, 'street_race_bust: for 5 s')
        H.eq(o.arrest.label, 'Detain driver', 'street_race_bust: Detain driver')
        H.eq(o.arrest.duration, 3000, 'street_race_bust: 3 s detain')
        H.eq(o.complete, 'all_or_timeout_any', 'street_race_bust: completes on all or timeout with one')
        H.eq(o.ramSpeed, 100, 'street_race_bust: ram over 100 km/h')
        H.eq(o.ramPenaltyId, 'hard_ram', 'street_race_bust: hard_ram')
        H.eq(o.neverShoots, true, 'street_race_bust: racers never shoot')
        for _, m in ipairs(o.models) do H.ok(contains(Config.Builder.allowed.vehicles, m), 'street_race_bust: allowed model ' .. m) end
        H.eq(def.scaling[1], 'objectives.1.vehicles', 'street_race_bust: racers scale')
        local b, p = bonusMap(def.bonuses), bonusMap(def.penalties)
        H.ok(b.racer_detained and b.racer_detained.points == 30 and b.racer_detained.each, 'street_race_bust: +30 per racer')
        H.ok(b.all_racers_detained and b.all_racers_detained.points == 20 and not b.all_racers_detained.each, 'street_race_bust: +20 all racers')
        H.ok(p.hard_ram and p.hard_ram.points == -10 and p.hard_ram.each, 'street_race_bust: hard_ram -10 each')
        local maxRacers = CP.U.round(o.vehicles * Config.Scaling[#Config.Scaling].count)
        for i, loc in ipairs(def.locations) do
            local pts, len = checkRoute('street_race_bust', i, loc.route, { loop = true, min = 2000, max = 3000 })
            if pts then
                note('street_race_bust  loop %d %-34s %2d waypoints %5.0f m', i, loc.label, #pts, len)
                H.ok(distToRoute(loc.start.coords, pts, true) < 1, ('street_race_bust: location %d intercept is on the loop'):format(i))
                H.ok(loc.start.radius >= 50 and loc.start.radius <= 70, ('street_race_bust: location %d intercept radius ~60'):format(i))
                H.ok(#loc.spawns >= maxRacers, ('street_race_bust: location %d has %d racer slots (%d at Critical)'):format(i, #loc.spawns, maxRacers))
                for j, s in ipairs(loc.spawns) do
                    H.ok(isVec4(s), ('street_race_bust: location %d slot %d is a vec4'):format(i, j))
                    H.ok(distToRoute(s, pts, true) < 1, ('street_race_bust: location %d slot %d is on the loop'):format(i, j))
                    H.ok(d2(s, loc.start.coords) >= Config.Builder.minSpawnFromStart, ('street_race_bust: location %d slot %d is 30 m+ from the start'):format(i, j))
                end
            end
        end
    end
end

-- EVOC Course
do
    local def = defs.evoc_course
    if def then
        local o = def.objectives[1]
        H.eq(o.block, 'checkpoint_route', 'evoc_course: checkpoint_route')
        H.eq(o.use, 'all', 'evoc_course: every checkpoint in order')
        H.eq(o.stopFor, 0, 'evoc_course: drive-through')
        H.eq(o.vehicleRequired, true, 'evoc_course: driving a vehicle required')
        H.eq(o.policeVehicle, nil, 'evoc_course: no old policeVehicle field')
        H.eq(o.contactPenalty, 2, 'evoc_course: 2 s per contact')
        H.eq(o.timerStart, 'first', 'evoc_course: clock starts at the first checkpoint')
        H.eq(o.failIfUndriveable, true, 'evoc_course: fails when undriveable')
        H.ok(type(o.medals) == 'table', 'evoc_course: medal times on')
        -- A gold run must never be refused and flagged too_fast: minSeconds (counted from the start
        -- marker) stays well below the fastest layout's gold time (counted from checkpoint 1).
        local fastestGold = math.huge
        for _, loc in ipairs(def.locations) do
            if type(loc.medals) == 'table' then fastestGold = math.min(fastestGold, loc.medals.gold) end
        end
        H.ok(o.minSeconds <= fastestGold - 5, ('evoc_course: minSeconds %d is below every gold time (fastest %d s)'):format(o.minSeconds, fastestGold))
        local b = bonusMap(def.bonuses)
        H.ok(b.medal_gold and b.medal_gold.points == 50, 'evoc_course: gold +50')
        H.ok(b.medal_silver and b.medal_silver.points == 25, 'evoc_course: silver +25')
        H.ok(b.medal_bronze and b.medal_bronze.points == 10, 'evoc_course: bronze +10')
        H.ok(b.no_contact and b.no_contact.points == 10, 'evoc_course: no contact +10')
        -- flat, open airfield ground (rough outlines of the three airfields)
        local AIRFIELDS = {
            { label = 'LSIA',                  x = { -1750, -1000 }, y = { -3400, -2800 }, z = 13.94 },
            { label = 'Sandy Shores Airfield', x = { 1150, 1800 },   y = { 3050, 3300 },   z = 41.0 },
            { label = 'McKenzie Field',        x = { 1750, 2200 },   y = { 4550, 4850 },   z = 40.95 },
        }
        for i, loc in ipairs(def.locations) do
            local cps = loc.checkpoints
            H.ok(#cps >= 12 and #cps <= 20, ('evoc_course: layout %d has %d checkpoints (12-20)'):format(i, #cps))
            local len = routeLength(cps, false)
            local m = loc.medals
            H.ok(type(m) == 'table' and m.gold < m.silver and m.silver < m.bronze and m.bronze < def.timeLimit,
                ('evoc_course: layout %d medals gold < silver < bronze < time limit'):format(i))
            H.ok(len / m.gold <= 22 and len / m.bronze >= 8, ('evoc_course: layout %d medal times fit its %.0f m (gold %.1f m/s, bronze %.1f m/s)'):format(i, len, len / m.gold, len / m.bronze))
            note('evoc_course       layout %d %-26s %2d checkpoints %5.0f m  medals %d/%d/%d', i, loc.label, #cps, len, m.gold, m.silver, m.bronze)
            local field
            for _, a in ipairs(AIRFIELDS) do
                if loc.start.coords.x >= a.x[1] and loc.start.coords.x <= a.x[2] and loc.start.coords.y >= a.y[1] and loc.start.coords.y <= a.y[2] then field = a end
            end
            if H.ok(field ~= nil, ('evoc_course: layout %d is on an airfield'):format(i)) then
                for j, p in ipairs(cps) do
                    H.ok(p.x >= field.x[1] and p.x <= field.x[2] and p.y >= field.y[1] and p.y <= field.y[2],
                        ('evoc_course: layout %d checkpoint %d stays on %s'):format(i, j, field.label))
                    H.ok(math.abs(p.z - field.z) < 1.5, ('evoc_course: layout %d checkpoint %d is at ground level'):format(i, j))
                    if j > 1 then H.ok(d2(p, cps[j - 1]) >= 30, ('evoc_course: layout %d checkpoints %d and %d are 30 m+ apart'):format(i, j - 1, j)) end
                end
                H.ok(d2(loc.start.coords, cps[1]) <= 60, ('evoc_course: layout %d start marker is next to checkpoint 1'):format(i))
            end
        end
    end
end

-- Pursuit Sim
do
    local def = defs.pursuit_sim
    if def then
        local o = def.objectives[1]
        H.eq(o.block, 'pursuit', 'pursuit_sim: pursuit')
        H.eq(o.mode, 'follow', 'pursuit_sim: follow mode')
        H.eq(o.vehicles, 1, 'pursuit_sim: one car')
        H.eq(o.suspectsPerVehicle, 1, 'pursuit_sim: one driver')
        H.eq(o.spawn, 'spawn', 'pursuit_sim: spawn key')
        H.eq(o.route, 'route', 'pursuit_sim: route key')
        H.eq(o.hold, 150, 'pursuit_sim: hold 150 m')
        H.eq(o.lost.distance, 250, 'pursuit_sim: lost at 250 m')
        H.eq(o.lost.seconds, 10, 'pursuit_sim: for 10 s')
        H.eq(o.duration, 180, 'pursuit_sim: 3 minutes')
        H.eq(o.medals.gold, 40, 'pursuit_sim: gold under 40 m')
        H.eq(o.medals.silver, 80, 'pursuit_sim: silver under 80 m')
        H.eq(o.medals.bronze, 150, 'pursuit_sim: bronze under 150 m')
        H.eq(o.ramSpeed, 0, 'pursuit_sim: any contact is a ram')
        H.eq(o.ramPenaltyId, 'ram', 'pursuit_sim: ram penalty id')
        H.eq(o.neverShoots, true, 'pursuit_sim: never shoots')
        for _, m in ipairs(o.models) do H.ok(contains(Config.Builder.allowed.vehicles, m), 'pursuit_sim: allowed model ' .. m) end
        local b, p = bonusMap(def.bonuses), bonusMap(def.penalties)
        H.ok(b.medal_gold and b.medal_gold.points == 50 and b.medal_silver.points == 25 and b.medal_bronze.points == 10, 'pursuit_sim: medal bonuses')
        H.ok(p.ram and p.ram.points == -10 and p.ram.each, 'pursuit_sim: ram -10 each')
        for i, loc in ipairs(def.locations) do
            local pts, len = checkRoute('pursuit_sim', i, loc.route, { loop = true })
            if pts then
                note('pursuit_sim       loop %d %-34s %2d waypoints %5.0f m', i, loc.label, #pts, len)
                H.ok(isVec4(loc.spawn), ('pursuit_sim: location %d spawn is a vec4'):format(i))
                local ahead = d2(loc.spawn, loc.start.coords)
                H.ok(ahead >= 40 and ahead <= 60, ('pursuit_sim: location %d car waits %.0f m ahead of the start (~50)'):format(i, ahead))
                H.ok(ahead >= Config.Builder.minSpawnFromStart, ('pursuit_sim: location %d spawn is 30 m+ from the start'):format(i))
                H.ok(d2(loc.spawn, pts[1]) < 1, ('pursuit_sim: location %d car starts at the flee route'):format(i))
                H.ok(distToRoute(loc.start.coords, pts, true) < 1, ('pursuit_sim: location %d start is on the route'):format(i))
                local hx, hy = -math.sin(math.rad(loc.spawn.w)), math.cos(math.rad(loc.spawn.w))
                local dx, dy = pts[2].x - pts[1].x, pts[2].y - pts[1].y
                H.ok((hx * dx + hy * dy) / math.sqrt(dx * dx + dy * dy) > 0.95, ('pursuit_sim: location %d car faces along its route'):format(i))
            end
        end
    end
end

-- Stolen Vehicle Takedown
do
    local def = defs.stolen_vehicle_takedown
    if def then
        local o = def.objectives[1]
        H.eq(o.block, 'pursuit', 'stolen_vehicle_takedown: pursuit')
        H.eq(o.mode, 'stop', 'stolen_vehicle_takedown: stop mode')
        H.eq(o.vehicles, 1, 'stolen_vehicle_takedown: one car')
        H.eq(o.suspectsPerVehicle, 2, 'stolen_vehicle_takedown: 2 suspects')
        H.eq(o.spawn, 'spawn', 'stolen_vehicle_takedown: spawn key')
        H.eq(o.route, 'route', 'stolen_vehicle_takedown: route key')
        H.eq(o.trigger.distance, 60.0, 'stolen_vehicle_takedown: flees within 60 m')
        H.eq(o.trigger.lights, true, 'stolen_vehicle_takedown: ... of a participant with lights on')
        H.eq(o.stopped.speed, 5.0, 'stolen_vehicle_takedown: stopped below 5 km/h')
        H.eq(o.stopped.seconds, 5, 'stolen_vehicle_takedown: for 5 s')
        H.near(o.footFlee, 0.20, 1e-9, 'stolen_vehicle_takedown: 20% run on foot')
        H.eq(o.surrenderOnAim, true, 'stolen_vehicle_takedown: surrender on aim')
        H.eq(o.arrest.label, 'Cuff suspect', 'stolen_vehicle_takedown: Cuff suspect')
        H.eq(o.arrest.duration, 5000, 'stolen_vehicle_takedown: 5 s cuff')
        H.eq(o.escape.distance, 400, 'stolen_vehicle_takedown: escape at 400 m')
        H.eq(o.escape.seconds, 20, 'stolen_vehicle_takedown: for 20 s')
        H.eq(o.complete, 'all_detained', 'stolen_vehicle_takedown: every suspect detained')
        H.eq(o.ramSpeed, 100, 'stolen_vehicle_takedown: ram over 100 km/h')
        H.eq(o.ramPenaltyId, 'hard_ram', 'stolen_vehicle_takedown: hard_ram')
        H.eq(o.neverShoots, true, 'stolen_vehicle_takedown: suspects never shoot')
        for _, m in ipairs(o.models) do H.ok(contains(Config.Builder.allowed.vehicles, m), 'stolen_vehicle_takedown: allowed model ' .. m) end
        local sc = def.scaling[1]
        H.ok(type(sc) == 'table' and sc.path == 'objectives.1.suspectsPerVehicle' and sc.max == 4, 'stolen_vehicle_takedown: suspects scale, max 4')
        local b, p = bonusMap(def.bonuses), bonusMap(def.penalties)
        H.ok(b.vehicle_stopped_fast and b.vehicle_stopped_fast.points == 15, 'stolen_vehicle_takedown: +15 stopped fast')
        H.ok(p.hard_ram and p.hard_ram.points == -10 and p.hard_ram.each, 'stolen_vehicle_takedown: hard_ram -10 each')
        for i, loc in ipairs(def.locations) do
            local pts, len = checkRoute('stolen_vehicle_takedown', i, loc.route, { loop = false })
            if pts then
                note('svt               route %d %-33s %2d waypoints %5.0f m', i, loc.label, #pts, len)
                H.ok(isVec4(loc.spawn), ('stolen_vehicle_takedown: location %d spawn is a vec4'):format(i))
                local d = d2(loc.spawn, loc.start.coords)
                H.ok(d >= Config.Builder.minSpawnFromStart and d <= loc.start.radius, ('stolen_vehicle_takedown: location %d car is %.0f m from the start centre (30 m+, inside the circle)'):format(i, d))
                H.eq(loc.start.radius, 60.0, ('stolen_vehicle_takedown: location %d start radius 60'):format(i))
                H.ok(d2(loc.spawn, pts[1]) < 1, ('stolen_vehicle_takedown: location %d car starts at the flee route'):format(i))
                local hx, hy = -math.sin(math.rad(loc.spawn.w)), math.cos(math.rad(loc.spawn.w))
                local dx, dy = pts[2].x - pts[1].x, pts[2].y - pts[1].y
                H.ok((hx * dx + hy * dy) / math.sqrt(dx * dx + dy * dy) > 0.95, ('stolen_vehicle_takedown: location %d car faces along its route'):format(i))
            end
        end
    end
end

-- ── the real loader and block guardrails, for the blocks that exist ─────────
do
    local function exists(rel) local f = io.open(H.root .. rel, 'r'); if f then f:close() return true end return false end
    local okLoad, err = pcall(H.load, 'modules/missions/server.lua')
    if not okLoad then
        note('CP.Missions.normalize not run: modules/missions/server.lua did not load (%s)', tostring(err))
    else
        local loaded = {}
        for _, id in ipairs(ORDER) do
            local def = defs[id]
            if def then
                local blocks, missing = {}, nil
                for _, o in ipairs(def.objectives) do
                    local rel = ('blocks/%s/server.lua'):format(o.block)
                    if not exists(rel) then missing = o.block
                    elseif not loaded[o.block] then
                        local okB, errB = pcall(H.load, rel)
                        loaded[o.block] = okB or errB
                        if not okB then note('block %s did not load in the harness: %s', o.block, tostring(errB)) end
                    end
                    blocks[#blocks + 1] = o.block
                end
                if missing then
                    note('%-24s block %s not written yet: loader validation skipped', id, missing)
                elseif CP.Blocks.get(blocks[1]) then
                    local d, why, warnings = CP.Missions.normalize(def, { source = 'builtin', filePath = 'missions/builtin/' .. id .. '.lua' })
                    H.ok(d ~= nil, id .. ': CP.Missions.normalize accepts it (' .. tostring(why) .. ')')
                    H.eq(warnings or 0, 0, id .. ': CP.Missions.normalize has no warnings')
                    if d then note('%-24s passed CP.Missions.normalize and the %s block validate', id, table.concat(blocks, ', ')) end
                end
            end
        end
    end
end

for _, n in ipairs(notes) do print('  ' .. n) end
return H
