-- Spawn lint (PLAN S22): the built-in missions' spawn points stay 1.5 m apart, every list has a point per person
-- the largest team brings, and armed spawns keep the start circle plus Config.Builder.spawnMargin unless the spawn
-- director places them; known cases are in tests/spawn_lint_baseline.txt, which may only shrink.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local APART = 1.5          -- metres (flat): two spawn points of one run closer than this put people inside each other
local CLOSER = 0.05        -- metres: a listed armed point may never come closer to its start than the baseline says
local BASELINE_MAX = 26    -- lines in tests/spawn_lint_baseline.txt when it was written; never more

H.load('modules/scaling/server.lua')
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
local summary = CP.Missions.loadAll()
-- after the loader: the Builder's rule for armed spawns (CP.Builder.armedTooClose), no custom file read
H.load('modules/builder/server.lua')
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

-- An objective with its block's defaults filled in (the loader's definitions already have them).
local function Eff(o)
    local impl = CP.Blocks.get(o.block)
    local c = U.deepcopy(o)
    if impl and type(impl.defaults) == 'function' then
        local ok, res = pcall(impl.defaults, c)
        if ok and type(res) == 'table' then return res end
    end
    return c
end

-- ============================================================================
--                     1. NO TWO SPAWN POINTS WITHIN 1.5 M
-- ============================================================================
-- The spawn points of a run: the location keys where its blocks make people, vehicles or objects (each block's
-- pointKinds, as Check spawn points reads them; a route counts by its first point when a vehicle starts there, the
-- escort truck). A key that two objectives use is one list.

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

-- { { li, a, b, d } }: two spawn points of one location closer than APART (flat), named 'spawns[7]'.
local function Pairs(def)
    local out = {}
    local keys = SpawnKeys(def)
    for li, loc in ipairs(def.locations) do
        local pts = {}
        for _, k in ipairs(keys) do
            local list = Points(loc[k.key])
            for i, p in ipairs(list) do
                if i == 1 or not k.first then pts[#pts + 1] = { p = p, name = ('%s[%d]'):format(k.key, i) } end
            end
        end
        for i = 1, #pts do
            for j = i + 1, #pts do
                local d = U.dist2d(pts[i].p, pts[j].p)
                if d < APART then
                    local a, b = pts[i].name, pts[j].name
                    if b < a then a, b = b, a end
                    out[#out + 1] = { li = li, a = a, b = b, d = d }
                end
            end
        end
    end
    return out
end

-- ============================================================================
--                    2. A POINT FOR EVERY PERSON OF A LIST
-- ============================================================================
-- What each block makes from one list of points, at the counts of the scaled objective. A shorter list puts the extra
-- ones on a point already used: a ring 1.25 m round it for people, 8 m behind it for a racer, the same ambush point for
-- a later escort wave. spawnSets: the worst roll, the `use` smallest sets. A pursuit's single spawn point is the head
-- of a queue (its cars line up 8 m apart behind it), so it needs one point.

local function Num(v) return tonumber(v) or 0 end
local function MaxOf(v)
    if type(v) ~= 'table' then return Num(v) end
    local m = 0
    for _, x in ipairs(v) do m = math.max(m, Num(x)) end
    return m
end

local NEEDS = {
    hostile_waves = function(o, need)
        local sets = type(o.spawnSets) == 'table' and type(o.spawnSets.keys) == 'table' and o.spawnSets or nil
        need(sets and { sets = sets.keys, use = sets.use or 1 } or o.spawns, MaxOf(o.waves), 'hostiles in a wave')
        if type(o.boss) == 'table' then need(o.boss.spawn, 1, 'boss') end
    end,
    flee_arrest = function(o, need)
        if o.mode == 'scatter' then return need(o.spawns, Num(o.suspects), 'suspects') end
        need(o.suspect, 1, 'suspect')
        if type(o.associates) == 'table' then need(o.associates.spawns, Num(o.associates.count), 'associates') end
    end,
    pursuit = function(o, need)
        if o.spawns ~= nil then return need(o.spawns, Num(o.vehicles), 'vehicles') end
        need(o.spawn, 1, 'vehicle queue')
    end,
    escort = function(o, need)
        if type(o.ambush) == 'table' then need(o.ambushPoints, Num(o.ambush.waves), 'ambush waves') end
    end,
    protect_rescue = function(o, need) need(o.npcs, Num(o.count), 'hostages') end,
    search_area = function(o, need)
        need(o.hiding, Num(o.fugitives), 'fugitives')
        need(o.clues, Num(o.clueCount), 'clues')
    end,
    field_contact = function(o, need)
        if o.mode == 'parked' then
            need(o.spots, Num(o.cars), 'parked cars')
        elseif o.mode == 'scene' then
            need(o.car, 1, 'scene car')
            need(o.peopleSpots, Num(o.people), 'people')
        end
    end,
    interact_points = function(o, need)
        if type(o.hidden) == 'table' then need(o.points, Num(o.hidden.count), 'hidden items') end
    end,
    process_scene = function(o, need) need(o.coroner, 1, 'coroner van') end,
}

-- The points a list offers at one location (spawnSets: the `use` smallest sets together).
local function Have(loc, list)
    if type(list) == 'string' then return #Points(loc[list]) end
    local sizes = {}
    for _, k in ipairs(list.sets) do sizes[#sizes + 1] = #Points(loc[k]) end
    table.sort(sizes)
    local n = 0
    for i = 1, math.min(list.use, #sizes) do n = n + sizes[i] end
    return n
end

local function ListName(list) return type(list) == 'string' and list or table.concat(list.sets, '+') end

-- The highest count of each list over every team size the mission takes (the real CP.Scaling counts, each scaling
-- entry's max applied): { { oi, list, need, what } }.
local function Most(def)
    local most, order = {}, {}
    for n = math.max(1, Num(def.minOfficers)), math.max(1, Num(def.minOfficers), Num(def.maxOfficers)) do
        for oi, o in ipairs(CP.Scaling.apply(def, CP.Scaling.tierFor(n))) do
            local f = NEEDS[o.block]
            if f then
                f(o, function(list, count, what)
                    if type(list) ~= 'string' and type(list) ~= 'table' then return end
                    local tag = ('%d %s %s'):format(oi, ListName(list), what)
                    if not most[tag] then
                        most[tag] = { oi = oi, list = list, need = 0, what = what }
                        order[#order + 1] = tag
                    end
                    most[tag].need = math.max(most[tag].need, count)
                end)
            end
        end
    end
    local out = {}
    for _, tag in ipairs(order) do out[#out + 1] = most[tag] end
    return out
end

-- { { li, oi, list, have, need, what } }: a list with fewer points than people it is for.
local function Counts(def)
    local out = {}
    local most = Most(def)
    for li, loc in ipairs(def.locations) do
        for _, m in ipairs(most) do
            local have = Have(loc, m.list)
            if have < m.need then
                out[#out + 1] = {
                    li = li,
                    oi = m.oi,
                    list = ListName(m.list),
                    have = have,
                    need = m.need,
                    what = m.what,
                }
            end
        end
    end
    return out
end

-- ============================================================================
--                  3. ARMED SPAWNS OUTSIDE THE ARRIVAL CIRCLE
-- ============================================================================
-- Waves (hostile_waves) and scatters (flee_arrest scatter) wait for an officer to come near and take, from many
-- points, those far from every officer (the spawn director); a staged crew (stage = true) is in place, calm, before
-- its objective starts. Their points may lie inside the start circle (a raid's house). Every other armed spawn (a
-- pursuit car, an ambush car, a warrant's associates: one short list each) keeps the Mission Builder's rule for
-- custom missions (CP.Builder.armedKeepOut: the start circle plus Config.Builder.spawnMargin, flat), or is listed.

local function Directed(o)
    return o.block == 'hostile_waves' or (o.block == 'flee_arrest' and o.mode == 'scatter') or o.stage == true
end

-- { { li, oi, key, need, have } }: the Builder's own check, one objective at a time, with no built-in point trusted.
local function Armed(def)
    local out = {}
    local search = {}
    for _, o in ipairs(def.objectives) do
        if o.block == 'search_area' then search[#search + 1] = o end
    end
    for oi, o in ipairs(def.objectives) do
        if not Directed(o) then
            local one = { objectives = { o, table.unpack(search) }, locations = def.locations }
            for _, r in ipairs(CP.Builder.armedTooClose(one, {})) do
                out[#out + 1] = { li = r.location, oi = oi, key = r.key, need = r.min, have = r.have }
            end
        end
    end
    return out
end

-- ============================================================================
--                                   BASELINE
-- ============================================================================
-- tests/spawn_lint_baseline.txt: one line per case found when the lint was written.
--   pair <mission>#<location> <point> <point>  <metres> m
--   armed <mission>#<location> <key>  <metres> m (needs <metres>)
-- A listed pair is only reported; a listed armed key fails once a point of it comes closer than listed; a line
-- whose case is gone fails until it is removed, so the list only shrinks.

local function ReadBaseline(lines)
    local out = { pair = {}, armed = {}, n = 0 }
    for _, line in ipairs(lines) do
        local m, a, b = line:match('^pair ([%w_]+#%d+) (%S+) (%S+)')
        local am, key, have = line:match('^armed ([%w_]+#%d+) (%S+)%s+([%d.]+) m')
        if m then
            if b < a then a, b = b, a end
            out.pair[('%s %s %s'):format(m, a, b)] = true
            out.n = out.n + 1
        elseif am then
            out.armed[('%s %s'):format(am, key)] = tonumber(have)
            out.n = out.n + 1
        end
    end
    return out
end

-- found = { pair = { 'key' }, armed = { { key, have } } } against a baseline: the cases not listed, the listed armed
-- points that came closer, the lines that match nothing (each a sorted list) and how many listed cases were seen.
local function Judge(found, base)
    local new, closer, stale, seen, warned = {}, {}, {}, {}, 0
    for _, k in ipairs(found.pair) do
        seen['pair ' .. k] = true
        if base.pair[k] then
            warned = warned + 1
        else
            new[#new + 1] = 'pair ' .. k
        end
    end
    for _, a in ipairs(found.armed) do
        seen['armed ' .. a.key] = true
        local listed = base.armed[a.key]
        if not listed then
            new[#new + 1] = ('armed %s (%.1f m)'):format(a.key, a.have)
        elseif a.have < listed - CLOSER then
            closer[#closer + 1] = ('%s %.1f m (listed %.1f m)'):format(a.key, a.have, listed)
        else
            warned = warned + 1
        end
    end
    for k in pairs(base.pair) do
        if not seen['pair ' .. k] then stale[#stale + 1] = 'pair ' .. k end
    end
    for k in pairs(base.armed) do
        if not seen['armed ' .. k] then stale[#stale + 1] = 'armed ' .. k end
    end
    table.sort(new)
    table.sort(closer)
    table.sort(stale)
    return new, closer, stale, warned
end

-- ============================================================================
--                          THE LINT ON EVERY BUILT-IN
-- ============================================================================

local lines = {}
do
    local f = io.open(H.root:gsub('Crimson%-Police/$', '') .. 'tests/spawn_lint_baseline.txt', 'r')
        or io.open('tests/spawn_lint_baseline.txt', 'r')
    if H.ok(f ~= nil, 'tests/spawn_lint_baseline.txt exists') then
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
    end
end
local base = ReadBaseline(lines)
H.ok(base.n <= BASELINE_MAX, ('the baseline never grows (%d lines, at most %d)'):format(base.n, BASELINE_MAX))

local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
local found, short, checked, points = { pair = {}, armed = {} }, {}, 0, 0
for _, id in ipairs(ids) do
    local def = CP.Missions.get(id)
    if H.ok(def ~= nil, id .. ': loaded by the real loader') then
        checked = checked + 1
        for _, loc in ipairs(def.locations) do
            for _, k in ipairs(SpawnKeys(def)) do points = points + #Points(loc[k.key]) end
        end
        for _, p in ipairs(Pairs(def)) do
            found.pair[#found.pair + 1] = ('%s#%d %s %s'):format(id, p.li, p.a, p.b)
        end
        for _, c in ipairs(Counts(def)) do
            short[#short + 1] = ('%s#%d objective %d: %d %s point(s) for %d %s'):format(id, c.li, c.oi, c.have, c.list,
                c.need, c.what)
        end
        for _, a in ipairs(Armed(def)) do
            found.armed[#found.armed + 1] = { key = ('%s#%d %s'):format(id, a.li, a.key), have = a.have }
        end
    end
end
H.eq(checked, #ids, 'every built-in mission was linted')
H.ok(points >= 800, ('the lint read the spawn points of every location (%d)'):format(points))

table.sort(short)
H.eq(#short, 0, 'every spawn list has a point for each person the largest team brings: ' .. table.concat(short, ', '))
local new, closer, stale, warned = Judge(found, base)
H.eq(
    #new,
    0,
    'no spawn points within 1.5 m and no armed spawn inside the start circle plus the margin beyond the '
        .. 'baseline: ' .. table.concat(new, ', ')
)
H.eq(#closer, 0, 'no listed armed point comes closer to the start than listed: ' .. table.concat(closer, ', '))
H.eq(#stale, 0, 'every baseline line still matches a case (remove the fixed ones): ' .. table.concat(stale, ', '))
if warned > 0 then
    print(('  [spawn_lint] warning: %d known cases in the built-in missions (tests/spawn_lint_baseline.txt)'):format(
        warned))
end

-- ============================================================================
--                               THE LINT ITSELF
-- ============================================================================

do
    local start = { coords = vec3(0.0, 0.0, 10.0), radius = 60.0 }
    local function Ring(n, d)
        local out = {}
        for i = 1, n do
            local a = (i - 1) * 0.3
            out[i] = vec4(d * math.cos(a), d * math.sin(a), 10.0, 0.0)
        end
        return out
    end
    local function Probe(loc, objectives, scaling)
        local def = {
            id = 'lint_probe',
            minOfficers = 1,
            maxOfficers = 4,
            scaling = scaling or (objectives and {} or { 'objectives.1.waves', 'objectives.2.associates.count' }),
            objectives = objectives or {
                { block = 'hostile_waves', spawns = 'spawns', waves = { 4 } },
                {
                    block = 'flee_arrest',
                    mode = 'door',
                    door = 'door',
                    suspect = 'suspect',
                    fleeTo = 'fleeTo',
                    associates = { count = 1, spawns = 'associates' },
                },
                { block = 'pursuit', mode = 'stop', spawn = 'car', route = 'route', vehicles = 1 },
            },
            locations = { loc },
        }
        for i, o in ipairs(def.objectives) do def.objectives[i] = Eff(o) end
        return def
    end
    local function Loc(over)
        local loc = {
            start = start,
            spawns = Ring(6, 30.0),
            door = vec4(110.0, 0.0, 10.0, 0.0),
            suspect = vec4(111.0, 0.0, 10.0, 0.0),
            fleeTo = { vec3(130.0, 0.0, 10.0) },
            associates = { vec4(115.0, 5.0, 10.0, 0.0), vec4(115.0, -5.0, 10.0, 0.0) },
            car = vec4(0.0, 120.0, 10.0, 0.0),
            route = { vec3(0.0, 120.0, 10.0), vec3(0.0, 300.0, 10.0) },
        }
        for k, v in pairs(over or {}) do loc[k] = v end
        return loc
    end

    -- a clean location: 6 hostiles for a wave of 6 at 4 officers, 2 associates for 2, everything apart and outside
    local clean = Probe(Loc())
    H.eq(#Pairs(clean), 0, 'lint: points 3 m+ apart are no pair')
    H.eq(#Counts(clean), 0, 'lint: 6 points for a wave of 4 scaled to 6 (heavy) are enough')
    H.eq(#Armed(clean), 0, 'lint: armed spawns 110 m+ from a 60 m start pass')

    -- 1.5 m: a point 1.0 m from another (two lists) is a pair, 1.6 m is not; a route counts by its first point only
    local sp = Ring(6, 30.0)
    local near = Probe(Loc({ suspect = vec4(sp[1].x + 1.0, sp[1].y, 10.0, 0.0), spawns = sp }))
    local p = Pairs(near)
    H.eq(#p, 1, 'lint: a suspect 1.0 m from a hostile point is one pair')
    H.eq(p[1] and (p[1].a .. ' ' .. p[1].b), 'spawns[1] suspect[1]', 'lint: the pair names both points')
    H.eq(#Pairs(Probe(Loc({ suspect = vec4(sp[1].x + 1.6, sp[1].y, 10.0, 0.0), spawns = sp }))), 0,
        'lint: 1.6 m apart is no pair')
    local escort = Probe(Loc({
        route = { vec3(0.0, 120.0, 10.0), vec3(0.0, 120.5, 10.0), vec3(0.0, 300.0, 10.0) },
        ambushPoints = { vec4(0.0, 200.0, 10.0, 0.0), vec4(0.0, 250.0, 10.0, 0.0) },
    }), { { block = 'escort', route = 'route', ambushPoints = 'ambushPoints', ambush = { waves = 2 } } })
    H.eq(#Pairs(escort), 0, 'lint: an escort route counts by the truck at its first point, not every waypoint')

    -- counts: a wave of 4 scales to 6 at 4 officers (heavy x1.5); 5 points are short, so are 1 associate point for 2
    local c = Counts(Probe(Loc({ spawns = Ring(5, 30.0), associates = { vec4(115.0, 5.0, 10.0, 0.0) } })))
    H.eq(#c, 2, 'lint: a short wave list and a short associate list are both found')
    H.eq(c[1] and ('%s %d/%d'):format(c[1].list, c[1].have, c[1].need), 'spawns 5/6', 'lint: the wave list (5 for 6)')
    H.eq(c[2] and ('%s %d/%d'):format(c[2].list, c[2].have, c[2].need), 'associates 1/2',
        'lint: the associates (1 for 2)')
    -- spawnSets: the worst roll of 2 sets of 3 (2 + 3 points) is short of 6; 3 + 3 + 3 is not
    local sets = { { block = 'hostile_waves', spawnSets = { keys = { 'a', 'b', 'c' }, use = 2 }, waves = { 4 } } }
    local cs = Counts(
        Probe(Loc({ a = Ring(2, 30.0), b = Ring(3, 40.0), c = Ring(4, 50.0) }), sets, { 'objectives.1.waves' }))
    H.eq(cs[1] and ('%s %d/%d'):format(cs[1].list, cs[1].have, cs[1].need), 'a+b+c 5/6',
        'lint: spawnSets count the use smallest sets')
    H.eq(
        #Counts(Probe(Loc({ a = Ring(3, 30.0), b = Ring(3, 40.0), c = Ring(3, 50.0) }), sets, { 'objectives.1.waves' })),
        0, 'lint: 3 + 3 points for a wave of 6 are enough')

    -- armed: a pursuit car 70 m from a 60 m start and associates 30 m out are inside 60 + spawnMargin (100 m); the
    -- wave's own points 30 m out are the director's: the Builder's check finds them, the lint leaves them out
    local a = Armed(Probe(Loc({
        car = vec4(0.0, 70.0, 10.0, 0.0),
        associates = { vec4(30.0, 5.0, 10.0, 0.0), vec4(115.0, -5.0, 10.0, 0.0) },
    })))
    table.sort(a, function(x, y) return x.key < y.key end)
    H.eq(#a, 2, 'lint: a close pursuit car and close associates are found, the close wave points are not')
    H.eq(a[1] and ('%s %d %.0f'):format(a[1].key, a[1].need, a[1].have), 'associates 100 30',
        'lint: associates 30 m from a 60 m start (needs 100 m: Config.Builder.spawnMargin 40)')
    H.eq(a[2] and ('%s %d %.0f'):format(a[2].key, a[2].need, a[2].have), 'car 100 70', 'lint: the car at 70 m')
    H.eq(#Armed(Probe(Loc({ car = vec4(0.0, 101.0, 10.0, 0.0) }))), 0, 'lint: a car 101 m out passes')
    local wave = Probe(Loc(), { { block = 'hostile_waves', spawns = 'spawns', waves = { 4 }, stage = true } })
    H.eq(#CP.Builder.armedTooClose(wave, {}), 1, 'lint: the Builder finds wave points 30 m from a 60 m start')
    H.eq(#Armed(wave), 0, 'lint: a wave (staged or not) is placed by the director (no finding)')
    local door = Probe(Loc({ associates = { vec4(30.0, 5.0, 10.0, 0.0) } }), {
        {
            block = 'flee_arrest',
            mode = 'door',
            door = 'door',
            suspect = 'suspect',
            associates = { spawns = 'associates' },
        },
    })
    H.eq(#Armed(door), 1, 'lint: a warrant\'s associates are not a scatter (found)')
    local margin = Config.Builder.spawnMargin
    Config.Builder.spawnMargin = 0.0
    H.eq(#Armed(Probe(Loc({ car = vec4(0.0, 70.0, 10.0, 0.0) }))), 0, 'lint: Config.Builder.spawnMargin is read live')
    Config.Builder.spawnMargin = margin

    -- the baseline: listed cases are known, a new one fails, a listed armed key closer than listed fails, a line that
    -- matches nothing is stale
    local b = ReadBaseline({
        '# a comment',
        'pair x#1 spawns[2] hostages[1]  1.20 m',
        'armed x#1 spawn  47.0 m (needs 65)',
        'armed x#2 spawn  40.0 m (needs 65)',
    })
    H.eq(b.n, 3, 'baseline: comments are no lines')
    local n1, c1, s1, w1 = Judge(
        { pair = { 'x#1 hostages[1] spawns[2]' }, armed = { { key = 'x#1 spawn', have = 47.0 } } }, b)
    H.eq(#n1 .. #c1 .. #s1 .. w1, '0012', 'baseline: two listed cases are known, the unseen line is stale')
    H.eq(s1[1], 'armed x#2 spawn', 'baseline: the stale line is named')
    local n2, c2 = Judge({
        pair = { 'x#1 hostages[1] spawns[3]' },
        armed = { { key = 'x#1 spawn', have = 46.9 }, { key = 'x#3 spawn', have = 10.0 } },
    }, b)
    H.eq(table.concat(n2, ', '), 'armed x#3 spawn (10.0 m), pair x#1 hostages[1] spawns[3]',
        'baseline: a pair and an armed key not listed fail')
    H.eq(c2[1], 'x#1 spawn 46.9 m (listed 47.0 m)', 'baseline: a listed armed point 0.1 m closer fails')
end

return H
