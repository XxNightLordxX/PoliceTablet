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
