-- Other scripts' places: no built-in mission spawns or starts on a fixed place of another public script.

-- tests/fixtures/foreign_sites.lua lists the fixed world places of the public Qbox and overextended scripts (garages,
-- shops, banks, hospitals, police, job depots, robbery spots, properties, spawn points, doors), written by
-- tools/gen_foreign_sites.py; this spec reads only that file. Each built-in mission (the Weekly Boss too) on the
-- definitions the real loader makes: every spawn point (each block's pointKinds: people, vehicles, objects; a
-- route by its first point) and the start point stays outside each place's keep-out circle (flat, and only when
-- the heights are within 10 m, so an interior far below or a flat high up is not the street): the script's own
-- radius, or KEEP_OUT for its kind when it gives none, whichever is larger. CP_FOREIGN_REPORT=1 also prints every
-- mission point within 50 m (flat) of a place, the list a person reads when a script is added. The check itself on
-- probe points: 2 m from a garage found, 7 m not, a script radius used, an area and a far height ignored, a
-- camera ignored. No SQL.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local FLAG = 50.0       -- metres (flat): the report lists every mission point this close to a place
local HEIGHT = 10.0     -- metres: a place more than this above or below a point is another floor
local AREA = 10.0       -- metres: a place whose script radius is above this is an area (a trucker's 40 m delivery
                        -- box) where that script spawns nothing: only listed
-- metres (flat) kept clear round a place of each kind when its script gives a smaller radius: a garage, a vehicle
-- spawn or a job's pick-up spot needs the 5 m qbx_garages keeps clear before it spawns a car (distanceCheck) plus
-- 1 m; a counter, register, safe, locker, stash or door its ox_target reach (2 m, so two targets never overlap);
-- a hospital, station or prison point (a bed, a duty desk, an armory) a little more
local KEEP_OUT = {
    garage = 6.0,
    spawn = 6.0,
    job = 6.0,
    hospital = 4.0,
    police = 4.0,
    prison = 4.0,
    shop = 2.0,
    robbery = 2.0,
    bank = 2.0,
    property = 2.0,
    cityhall = 2.0,
    drugs = 2.0,
    stash = 2.0,
    door = 2.0,
    camera = 0.0,         -- a wall camera: nothing walks into it
}

H.load('modules/runs/scaling.lua')
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
H.load('modules/missions/missions.lua')
local summary = CP.Missions.loadAll()
CP.warn = realWarn
H.eq(#(summary.failed or {}), 0, 'the real loader rejects no built-in mission')

local U = CP.U
local VMT = getmetatable(vec3(0, 0, 0))
local function IsVec(v)
    return (type(v) == 'table' and getmetatable(v) == VMT) or type(v) == 'vector3' or type(v) == 'vector4'
end

-- Every point of a location value in file order: a point, { coords }, a road route ({ points }) or a list of them.
local function Points(v, out)
    out = out or {}
    if IsVec(v) then
        out[#out + 1] = v
        return out
    end
    if type(v) ~= 'table' then return out end
    if IsVec(v.coords) then
        out[#out + 1] = v.coords
        return out
    end
    if type(v.points) == 'table' then return Points(v.points, out) end
    for i = 1, #v do Points(v[i], out) end
    return out
end

-- ============================================================================
--                                  THE SITES
-- ============================================================================

-- { script, 'file:line', kind, x, y, z, radius or false, what } rows as { script, file, kind, x, y, z, r, what }
local sites = {}
for _, row in ipairs(dofile('tests/fixtures/foreign_sites.lua')) do
    sites[#sites + 1] = {
        script = row[1],
        file = row[2],
        kind = row[3],
        x = row[4],
        y = row[5],
        z = row[6] or nil,
        r = row[7] or nil,
        what = row[8],
    }
end
H.ok(type(sites) == 'table' and #sites >= 700, ('the fixture lists the other scripts\' places (%d)'):format(#sites))
local scripts, bad = {}, {}
for i, s in ipairs(sites) do
    scripts[s.script] = (scripts[s.script] or 0) + 1
    if type(s.x) ~= 'number' or type(s.y) ~= 'number' or KEEP_OUT[s.kind] == nil or type(s.file) ~= 'string' then
        bad[#bad + 1] = tostring(i)
    end
end
H.eq(#bad, 0, 'every site has a place, a known kind and its file: ' .. table.concat(bad, ', '))
for _, name in ipairs({
    'ox_inventory',
    'qbx_ambulancejob',
    'qbx_bankrobbery',
    'qbx_garages',
    'qbx_policejob',
    'qbx_storerobbery',
    'qbx_vehicleshop',
    'qbx_truckerjob',
}) do
    H.ok((scripts[name] or 0) > 0, name .. ' has places in the fixture')
end

-- The keep-out radius of a site (metres, flat).
local function KeepOut(s)
    local r = tonumber(s.r) or 0
    if r > AREA then return 0 end
    return math.max(r, KEEP_OUT[s.kind] or 0)
end

-- The sites whose keep-out circle holds p (flat, heights within HEIGHT): { { site, d } }.
local function Inside(p, list)
    local out = {}
    for _, s in ipairs(list) do
        local r = KeepOut(s)
        if r > 0 then
            local d = math.sqrt((p.x - s.x) ^ 2 + (p.y - s.y) ^ 2)
            if d < r and (s.z == nil or math.abs(p.z - s.z) <= HEIGHT) then out[#out + 1] = { site = s, d = d } end
        end
    end
    return out
end

-- ============================================================================
--                              THE MISSION POINTS
-- ============================================================================

-- The spawn keys of a mission (each block's pointKinds: ped, vehicle, prop; a path by its first point).
local function SpawnKeys(def)
    local out, seen = {}, {}
    for _, o in ipairs(def.objectives) do
        local impl = CP.Blocks.get(o.block)
        local ok, kinds = false, nil
        if impl and type(impl.pointKinds) == 'function' then ok, kinds = pcall(impl.pointKinds, o) end
        for _, k in ipairs(ok and type(kinds) == 'table' and kinds or {}) do
            local kind = k.kind == 'path' and k.first or k.kind
            if (kind == 'ped' or kind == 'vehicle' or kind == 'prop') and not seen[k.key] then
                seen[k.key] = true
                out[#out + 1] = { key = k.key, first = k.kind == 'path' }
            end
        end
    end
    return out
end

-- The checked points of one location: the start and every spawn point, { { p, name } }.
local function Checked(def, loc)
    local out = {}
    if type(loc.start) == 'table' and IsVec(loc.start.coords) then
        out[#out + 1] = { p = loc.start.coords, name = 'start' }
    end
    for _, k in ipairs(SpawnKeys(def)) do
        for i, p in ipairs(Points(loc[k.key])) do
            if i == 1 or not k.first then out[#out + 1] = { p = p, name = ('%s[%d]'):format(k.key, i) } end
        end
    end
    return out
end

local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
local conflicts, checked, points = {}, 0, 0
for _, id in ipairs(ids) do
    local def = CP.Missions.get(id)
    if H.ok(def ~= nil, id .. ': loaded by the real loader') then
        checked = checked + 1
        for li, loc in ipairs(def.locations) do
            for _, c in ipairs(Checked(def, loc)) do
                points = points + 1
                for _, hit in ipairs(Inside(c.p, sites)) do
                    local s = hit.site
                    conflicts[#conflicts + 1] = ('%s#%d %s %.1f m from %s %s (%s, %s, keep %.0f m)'):format(id, li,
                        c.name, hit.d, s.script, s.kind, s.what, s.file, KeepOut(s))
                end
            end
        end
    end
end
H.eq(checked, #ids, 'every built-in mission was checked')
H.ok(points >= 900, ('the check read the start and spawn points of every location (%d)'):format(points))
table.sort(conflicts)
H.eq(#conflicts, 0,
    'no built-in start or spawn point inside another script\'s place: ' .. table.concat(conflicts, '; '))

-- The report: every mission point (any location key) within FLAG metres of a place, nearest place only.
if os.getenv('CP_FOREIGN_REPORT') == '1' then
    for _, id in ipairs(ids) do
        local def = CP.Missions.get(id)
        for li, loc in ipairs(def and def.locations or {}) do
            local keys = {}
            for k in pairs(loc) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                for i, p in ipairs(Points(loc[k])) do
                    local best, bd = nil, FLAG
                    for _, s in ipairs(sites) do
                        local d = math.sqrt((p.x - s.x) ^ 2 + (p.y - s.y) ^ 2)
                        if d < bd and s.kind ~= 'camera' then best, bd = s, d end
                    end
                    if best then
                        print(('REPORT %s#%d %s[%d] (%.2f, %.2f, %.2f) %.1f m %s %s %s (%s)'):format(id, li, k, i, p.x,
                            p.y, p.z, bd, best.script, best.kind, best.what, best.file))
                    end
                end
            end
        end
    end
end

-- ============================================================================
--                               THE CHECK ITSELF
-- ============================================================================

do
    local probe = {
        { script = 'probe', file = 'a:1', kind = 'garage', x = 100.0, y = 100.0, z = 30.0, what = 'garage' },
        { script = 'probe', file = 'a:2', kind = 'job', x = 500.0, y = 500.0, z = 30.0, r = 9.0, what = 'zone' },
        { script = 'probe', file = 'a:5', kind = 'job', x = 1700.0, y = 1700.0, z = 30.0, r = 20.0, what = 'area' },
        { script = 'probe', file = 'a:3', kind = 'property', x = 900.0, y = 900.0, z = -99.0, what = 'interior' },
        { script = 'probe', file = 'a:4', kind = 'camera', x = 1300.0, y = 1300.0, z = 31.0, what = 'camera' },
    }
    H.eq(#Inside(vec3(102.0, 100.0, 30.0), probe), 1, 'a point 2 m from a garage is inside it')
    H.eq(#Inside(vec3(107.0, 100.0, 30.0), probe), 0, 'a point 7 m from a garage is clear')
    H.eq(#Inside(vec3(508.0, 500.0, 30.0), probe), 1, 'the script\'s own radius (9 m) is used when larger')
    H.eq(#Inside(vec3(1701.0, 1700.0, 30.0), probe), 0, 'a 20 m area (a delivery box) is only listed')
    H.eq(#Inside(vec3(900.0, 901.0, 30.0), probe), 0, 'an interior far below the street is another floor')
    H.eq(#Inside(vec3(1300.0, 1300.5, 30.0), probe), 0, 'a wall camera keeps nothing clear')
    local def = {
        objectives = { { block = 'pursuit', spawn = 'spawn', vehicles = 1 } },
    }
    local loc = { start = { coords = vec3(0.0, 0.0, 30.0), radius = 30.0 }, spawn = vec4(101.0, 100.0, 30.0, 0.0) }
    local names = {}
    for _, c in ipairs(Checked(def, loc)) do
        if #Inside(c.p, probe) > 0 then names[#names + 1] = c.name end
    end
    H.eq(table.concat(names, ','), 'spawn[1]', 'a pursuit car spawned on a garage is found, the clear start is not')
end

return H
