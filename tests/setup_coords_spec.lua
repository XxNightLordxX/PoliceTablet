-- Setup coordinates from the Qbox scripts: each shipped mission desk and drop-off names its source or is kept.

-- A sourced coordinate has 'from <script> <file>:<line>' on its config.lua line, a place in
-- tests/fixtures/foreign_sites.lua; one with no Qbox source is in KEPT below (today's value stays). A sourced point is
-- within 3 m (flat) of its source at the same height (within 1 m), 1.5 m or more from every other script's place,
-- inside the map, and inside no no-build zone that does not hold its source too (a station desk sits in its
-- station's zone, never in another). A desk is also 1.5 m or more from its source (never on the duty point) and
-- faces it. Probe cases test the check itself. No SQL.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local REPO = H.root .. '../'
local NEAR = 3.0        -- metres (flat): a point is at most this far from its source
local HEIGHT = 1.0      -- metres: and at most this far above or below it
local CLEAR = 1.5       -- metres (flat): kept clear of every other script's place (and a desk of its own source)
local FACING = 10.0     -- degrees: a desk's rotation is at most this far from facing its source
local MAP = { minX = -4000.0, maxX = 4500.0, minY = -4000.0, maxY = 8500.0 }

-- Shipped coordinates with no Qbox source, kept as they were (README 6.2 and the LOC2 notes list them)
local KEPT = {
    ['1853.20, 3689.60, 34.27'] = 'Sandy Shores office desk: qbx_policejob has only a map blip there',
}

local function ReadRepo(rel)
    local f = io.open(REPO .. rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local function V(x, y, z, w) return { x = x, y = y, z = z, w = w } end
local Shipped = { Config = {}, vec3 = V, vector3 = V, vec4 = V, vector4 = V }
local chunk = loadfile(REPO .. 'Crimson-Police/config/config.lua', 't', Shipped)
H.ok(chunk ~= nil and pcall(chunk), 'config.lua loads as shipped')
local Cfg = Shipped.Config

local function Key(p) return ('%.2f, %.2f, %.2f'):format(p.x, p.y, p.z) end
local function Flat(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- the places of other scripts, by 'script file:line'
local SITES, BY = {}, {}
for _, row in ipairs(dofile('tests/fixtures/foreign_sites.lua')) do
    local site = { script = row[1], at = row[2], kind = row[3], x = row[4], y = row[5], z = row[6], what = row[8] }
    SITES[#SITES + 1] = site
    BY[site.script .. ' ' .. site.at] = site
end

-- the config.lua lines that name a source: coordinates -> 'script file:line'
local SOURCED = {}
for ln in (ReadRepo('Crimson-Police/config/config.lua') or ''):gmatch('[^\n]+') do
    local x, y, z = ln:match('vec3%((%-?[%d%.]+), (%-?[%d%.]+), (%-?[%d%.]+)%)')
    local src = ln:match('from ([%w_%-]+ [%w_/%.%-]+:%d+)')
    if x and src then SOURCED[Key(V(tonumber(x), tonumber(y), tonumber(z)))] = src end
end

local function Heading(from, to)
    return math.deg(math.atan(-(to.x - from.x), to.y - from.y)) % 360
end

local function Zones()
    local out = {}
    for _, list in ipairs({ Cfg.Builder and Cfg.Builder.noBuildZones or {} }) do
        for _, z in ipairs(list) do out[#out + 1] = z end
    end
    return out
end

-- The problems of one point (nil when clean). opts.desk: also kept off its source and facing it (opts.rotation)
local function Problems(p, src, opts)
    local site = BY[src or '']
    if not site then return { 'source ' .. tostring(src) .. ' is not a place in tests/fixtures/foreign_sites.lua' } end
    local out = {}
    local d = Flat(p, site)
    if d > NEAR then out[#out + 1] = ('%.2f m from its source (max %.1f)'):format(d, NEAR) end
    if math.abs(p.z - site.z) > HEIGHT then
        out[#out + 1] = ('%.2f m above or below its source'):format(p.z - site.z)
    end
    if opts.desk and d < CLEAR then out[#out + 1] = ('%.2f m from its source: on the duty point'):format(d) end
    if opts.desk then
        local off = math.abs(((opts.rotation or 0) - Heading(p, site) + 180) % 360 - 180)
        if off > FACING then
            out[#out + 1] = ('rotation %.1f is %.1f degrees off facing its source'):format(opts.rotation or 0, off)
        end
    end
    for _, other in ipairs(SITES) do
        if other ~= site and Flat(p, other) < CLEAR and math.abs(p.z - other.z) < 10.0 then
            out[#out + 1] = ('%.2f m from %s %s (%s)'):format(Flat(p, other), other.script, other.at, other.what)
        end
    end
    if p.x < MAP.minX or p.x > MAP.maxX or p.y < MAP.minY or p.y > MAP.maxY then out[#out + 1] = 'outside the map' end
    for _, z in ipairs(Zones()) do
        if Flat(p, z.coords) <= z.radius and Flat(site, z.coords) > z.radius then
            out[#out + 1] = 'inside the no-build zone ' .. z.label
        end
    end
    return #out > 0 and out or nil
end

-- every shipped desk and drop-off
local checked = { sourced = 0, kept = 0 }
local function Check(what, p, opts)
    local key = Key(p)
    if KEPT[key] then
        checked.kept = checked.kept + 1
        return
    end
    local src = SOURCED[key]
    H.ok(src ~= nil, what .. ' (' .. key .. ') names its source on its config.lua line, or is in KEPT')
    if not src then return end
    checked.sourced = checked.sourced + 1
    local bad = Problems(p, src, opts)
    H.ok(bad == nil, what .. ' from ' .. src .. ': ' .. table.concat(bad or {}, '; '))
end

for i, desk in ipairs(Cfg.Tablet.desks or {}) do
    Check(('Desk %d (%s)'):format(i, tostring(desk.label)), desk.coords, { desk = true, rotation = desk.rotation })
end
for i, p in ipairs(Cfg.Downed.dropOffs or {}) do Check('Drop-off ' .. i, p, {}) end

local labels = {}
for _, desk in ipairs(Cfg.Tablet.desks or {}) do labels[#labels + 1] = desk.label end
local all = table.concat(labels, ' | ')
for _, station in ipairs({ 'Mission Row', 'Sandy Shores', 'Paleto Bay' }) do
    H.ok(all:find(station, 1, true) ~= nil, 'a desk for ' .. station .. ' (' .. all .. ')')
end
H.eq(checked.kept, 1, 'one kept coordinate (Sandy Shores), the rest sourced')
H.ok(checked.sourced >= 4, 'two desks and two drop-offs are sourced')

-- every KEPT entry is still shipped, and config.lua says it is kept
local text = ReadRepo('Crimson-Police/config/config.lua') or ''
for key in pairs(KEPT) do
    local at = text:find('vec3(' .. key .. '),', 1, true)
    local rest = at and text:sub(at, (text:find('\n', at, true) or #text)) or ''
    H.ok(rest:find('-- kept:', 1, true) ~= nil, key .. ' is shipped with a "kept:" comment')
end

-- the check itself on probe points near the Mission Row duty point (440.08, -974.92, 30.69)
local SRC = 'qbx_policejob config/shared.lua:21'
local function Probe(x, y, z, rot) return Problems(V(x, y, z), SRC, { desk = true, rotation = rot }) end
H.eq(Probe(441.00, -977.30, 30.69, 21.0), nil, 'probe: the shipped Mission Row desk is clean')
H.ok(Probe(441.20, -978.90, 30.69, 0.0) ~= nil, 'probe: the old desk, 4.1 m away, is too far')
H.ok(Probe(440.50, -975.40, 30.69, 40.0) ~= nil, 'probe: 0.6 m from the duty point is on it')
H.ok(Probe(441.00, -977.30, 33.00, 21.0) ~= nil, 'probe: 2.3 m higher is another floor')
H.ok(Probe(441.00, -977.30, 30.69, 200.0) ~= nil, 'probe: facing away')
H.ok(Probe(439.40, -977.40, 30.69, 344.0) ~= nil, 'probe: 0.7 m from the qbx_policejob trash point')
H.ok(Problems(V(0, 0, 0), 'qbx_policejob config/shared.lua:9999', {}) ~= nil, 'probe: an unknown source')

return H
