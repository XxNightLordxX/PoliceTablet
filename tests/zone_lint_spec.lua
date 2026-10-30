-- Zone lint: new built-in missions keep Config.Draw.zoneClearance from every other mission's locations (250 m
-- for Drug Lab Raid); existing close pairs are only reported, from tests/zone_lint_baseline.txt.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- The missions of the parity-plus build: any close pair with one of them fails the suite.
local NEW = {
    parking_patrol = true,
    traffic_enforcement = true,
    suspicious_activity = true,
    drug_lab_raid = true,
    gang_hideout_raid = true,
}
local WIDE = { drug_lab_raid = 250.0 }  -- metres: a mission whose own clearance is wider
local BASELINE_MAX = 102                -- lines in tests/zone_lint_baseline.txt when it was written; never more

-- ============================================================================
--                                  FOOTPRINTS
-- ============================================================================
-- A location's footprint: its start and every point in it; a road route ({ points = ... }: a recorded
-- route or a Traffic Enforcement corridor) counts by its start and end only, because routes cross.

local VMT = getmetatable(vec3(0, 0, 0))
local function IsVec(v) return type(v) == 'table' and getmetatable(v) == VMT end

local function Footprint(loc)
    local out = {}
    local function walk(v)
        if IsVec(v) then
            out[#out + 1] = v
            return
        end
        if type(v) ~= 'table' then return end
        if type(v.points) == 'table' and #v.points > 0 then
            out[#out + 1] = v.points[1]
            out[#out + 1] = v.points[#v.points]
            return
        end
        for _, x in pairs(v) do walk(x) end
    end
    for k, v in pairs(loc) do
        if k == 'start' then
            out[#out + 1] = v.coords
        elseif k ~= 'label' then
            walk(v)
        end
    end
    return out
end

local function LoadDef(id)
    local src = LoadResourceFile('Crimson-Police', 'missions/builtin/' .. id .. '.lua')
    local def
    local env = {
        RegisterMission = function(d) def = d end,
        vec3 = vec3,
        vec4 = vec4,
        vector3 = vector3,
        vector4 = vector4,
        math = math,
    }
    local chunk = load(src, '@' .. id, 't', env)
    if chunk then pcall(chunk) end
    return def
end

local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
local sites = {}
for _, id in ipairs(ids) do
    local def = LoadDef(id)
    if H.ok(def ~= nil, id .. ': loads') then
        for li, loc in ipairs(def.locations) do
            sites[#sites + 1] = { id = id, li = li, label = loc.label, pts = Footprint(loc) }
        end
    end
end

local function MinDist(a, b)
    local best = math.huge
    for _, p in ipairs(a.pts) do
        for _, q in ipairs(b.pts) do
            local d = math.sqrt((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)
            if d < best then best = d end
        end
    end
    return best
end

local function Key(a, b)
    local x, y = ('%s#%d'):format(a.id, a.li), ('%s#%d'):format(b.id, b.li)
    if y < x then x, y = y, x end
    return x .. ' ' .. y
end

-- ============================================================================
--                                   BASELINE
-- ============================================================================

local baseline, baseLines = {}, 0
do
    local f = io.open(H.root:gsub('Crimson%-Police/$', '') .. 'tests/zone_lint_baseline.txt', 'r')
        or io.open('tests/zone_lint_baseline.txt', 'r')
    if H.ok(f ~= nil, 'tests/zone_lint_baseline.txt exists') then
        for line in f:lines() do
            local a, b = line:match('^([%w_]+#%d+) ([%w_]+#%d+)')
            if a then
                baseline[a .. ' ' .. b] = true
                baseLines = baseLines + 1
            end
        end
        f:close()
    end
end
H.ok(baseLines <= BASELINE_MAX, ('the baseline never grows (%d lines, at most %d)'):format(baseLines, BASELINE_MAX))

-- ============================================================================
--                                     LINT
-- ============================================================================

local clearance = tonumber(Config.Draw and Config.Draw.zoneClearance) or 200.0
local found, newBad, unlisted, warned = {}, {}, {}, 0
for i = 1, #sites do
    for j = i + 1, #sites do
        local a, b = sites[i], sites[j]
        if a.id ~= b.id then
            local need = math.max(clearance, WIDE[a.id] or 0, WIDE[b.id] or 0)
            local d = MinDist(a, b)
            if d < need then
                local k = Key(a, b)
                found[k] = true
                if NEW[a.id] or NEW[b.id] then
                    newBad[#newBad + 1] = ('%s (%.0f m, needs %.0f)'):format(k, d, need)
                elseif not baseline[k] then
                    unlisted[#unlisted + 1] = ('%s (%.0f m)'):format(k, d)
                else
                    warned = warned + 1
                end
            end
        end
    end
end
if warned > 0 then
    print(
        ('  [zone_lint] warning: %d existing pairs of locations are closer than %.0f m (tests/zone_lint_baseline.txt)'):format(
            warned, clearance))
end
table.sort(newBad)
table.sort(unlisted)
H.eq(#newBad, 0, 'no new mission location within the zone clearance of another mission: ' .. table.concat(newBad, ', '))
H.eq(#unlisted, 0, 'no close pair of existing locations beyond the baseline: ' .. table.concat(unlisted, ', '))
local stale = {}
for k in pairs(baseline) do if not found[k] then stale[#stale + 1] = k end end
table.sort(stale)
for _, k in ipairs(stale) do print('  [zone_lint] note: baseline pair ' .. k .. ' is no longer under the clearance') end

-- ============================================================================
--                          NO-BUILD ZONES, START GAPS
-- ============================================================================

local inZone = {}
for _, s in ipairs(sites) do
    for _, p in ipairs(s.pts) do
        for _, z in ipairs(Config.Builder.noBuildZones or {}) do
            if math.sqrt((p.x - z.coords.x) ^ 2 + (p.y - z.coords.y) ^ 2) <= (z.radius or 0) then
                inZone[#inZone + 1] = ('%s#%d in %s'):format(s.id, s.li, z.label)
            end
        end
    end
end
H.eq(#inZone, 0, 'no location point inside a no-build zone: ' .. table.concat(inZone, ', '))

-- Enabled built-in locations, their paths included: route.points, routes[n], escapes[n] and fleeTo are sampled every
-- 50 m, so a route that crosses a zone between two waypoints fails too (built-ins skip the Builder's zone check).
local STEP = 50.0
local function Sampled(loc)
    local out = {}
    local function path(list)
        for i = 1, #list do
            local a, b = list[i], list[i + 1]
            if IsVec(a) then
                out[#out + 1] = a
                if IsVec(b) then
                    local d = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
                    for k = 1, math.floor(d / STEP) do
                        local t = k * STEP / d
                        out[#out + 1] = vec3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, 0)
                    end
                end
            end
        end
    end
    if type(loc.route) == 'table' and type(loc.route.points) == 'table' then path(loc.route.points) end
    for _, key in ipairs({ 'routes', 'escapes' }) do
        for _, r in ipairs(type(loc[key]) == 'table' and loc[key] or {}) do
            if type(r) == 'table' then path(type(r.points) == 'table' and r.points or r) end
        end
    end
    if type(loc.fleeTo) == 'table' then path(loc.fleeTo) end
    return out
end

local function LocationOff(id, li, label)
    for _, m in ipairs(Config.DisabledMissions or {}) do if m == id then return true end end
    for _, v in ipairs((Config.DisabledLocations or {})[id] or {}) do
        if v == li or v == label then return true end
    end
    return false
end

local function PointsInZones(pts, zones)
    local hits = {}
    for _, p in ipairs(pts) do
        for _, z in ipairs(zones) do
            if math.sqrt((p.x - z.coords.x) ^ 2 + (p.y - z.coords.y) ^ 2) <= (z.radius or 0) then
                hits[z.label] = true
            end
        end
    end
    return hits
end

local pathHits = {}
for _, id in ipairs(ids) do
    local def = LoadDef(id)
    for li, loc in ipairs(def and def.locations or {}) do
        if not LocationOff(id, li, loc.label) then
            local pts = Sampled(loc)
            for _, p in ipairs(Footprint(loc)) do pts[#pts + 1] = p end
            for label in pairs(PointsInZones(pts, Config.Builder.noBuildZones or {})) do
                pathHits[#pathHits + 1] = ('%s#%d in %s'):format(id, li, label)
            end
        end
    end
end
table.sort(pathHits)
H.eq(#pathHits, 0,
    'no enabled built-in point (paths sampled every 50 m) inside a no-build zone: ' .. table.concat(pathHits, ', '))

-- the rule itself: a route whose waypoints sit 400 m either side of a 100 m zone is caught between them
do
    local loc = { route = { points = { vec3(-400, 0, 0), vec3(400, 0, 0) } } }
    local zone = { { label = 'test', coords = vec3(0, 0, 0), radius = 100.0 } }
    H.ok(next(PointsInZones(Footprint(loc), zone)) == nil, 'the route ends alone miss the zone')
    H.ok(PointsInZones(Sampled(loc), zone).test, 'the 50 m samples catch the route crossing the zone')
    H.ok(LocationOff('x', 2, 'B') == false, 'a location is on unless Config turns it off')
end

-- the lint itself: a pair under the clearance is found, and a route counts by its ends only
do
    local a = { id = 'x', li = 1, pts = { vec3(0, 0, 0) } }
    local b = { id = 'y', li = 1, pts = { vec3(150, 0, 0) } }
    H.ok(MinDist(a, b) < clearance, 'a point 150 m away is under the 200 m clearance')
    local fp = Footprint({
        start = { coords = vec3(0, 0, 0) },
        route = { points = { vec3(0, 0, 0), vec3(500, 0, 0), vec3(1000, 0, 0) } },
    })
    H.eq(#fp, 3, 'a route counts by its start and end only (plus the start marker)')
end

return H
