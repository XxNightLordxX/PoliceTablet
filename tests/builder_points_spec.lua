-- The point list under the location map (Mission Builder, Locations step): web/src/builder/pointList.ts, bundled
-- with esbuild and run in node. One row per point with its distance from the start and stored street; Delete takes
-- out exactly that point; "Set here" on point k sends the other points and puts the answer back at position k.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })
local cjson = require('cjson')

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

local root = H.root
if root:sub(1, 1) ~= '/' then
    local pwd = io.popen('pwd')
    root = pwd:read('l') .. '/' .. root
    pwd:close()
end

-- ============================================================================
--                              THE SCREEN USES IT
-- ============================================================================

local step = Read(root .. 'web/src/builder/steps/StepLocations.tsx') or ''
local editor = Read(root .. 'web/src/builder/useDraftEditor.ts') or ''
H.ok(step:find('<PointList', 1, true) ~= nil, 'the Locations step shows the point list under the map')
H.ok(step:find('highlight={lit}', 1, true) ~= nil, 'the row under the pointer is ringed on the map')
H.ok(step:find('ed.removePoint(row.key, li, row.index)', 1, true) ~= nil, 'Delete removes that one point')
H.ok(step:find('ed.here(s, li, row.index)', 1, true) ~= nil, '"Set here" moves that one point')
H.ok(editor:find('pointsWithout(payload.points, index)', 1, true) ~= nil, 'Set here sends the other points')
H.ok(editor:find('await commitNow(next, before)', 1, true) ~= nil, 'a deleted point is stored at once (autosave)')

-- ============================================================================
--                                 THE HELPERS
-- ============================================================================

local esbuild = root .. 'web/node_modules/.bin/esbuild'
local fh = io.open(esbuild, 'r')
local probe = io.popen('command -v node')
local node = probe:read('a') ~= ''
probe:close()
if not (fh and node) then
    print('SKIP tests/builder_points_spec.lua: the point list check needs node and web/node_modules (npm ci)')
    return H
end
fh:close()

local js = [==[
const P = require('WEB_DIR/pointList');
const out = {};
const pt = (x, y) => ({ x, y, z: 30 });
const spawns = { key: 'spawns', labelKey: 'builder.points.spawns', kind: 'ped', heading: false, multiple: true,
    min: 1, max: 6, spawn: true, objective: 1 };
const kerb = { key: 'spots', labelKey: 'builder.points.kerb', kind: 'vehicle', heading: false, multiple: true,
    min: 1, max: 4, spawn: false, objective: 1, ruled: true };
const flee = { key: 'routes', labelKey: 'builder.points.flee_paths', kind: 'marker', heading: false, multiple: true,
    lists: true, min: 2, max: 4, spawn: false, objective: 1 };
const drive = { key: 'route', labelKey: 'builder.points.route', kind: 'route', heading: false, multiple: true,
    min: 2, max: 50, spawn: false, objective: 1 };
const loc = {
    label: 'L1',
    start: { coords: pt(0, 0), radius: 60 },
    spawns: [pt(30, 40), pt(60, 80), pt(0, 100)],
    spots: [{ coords: pt(0, 50), rule: 'none', street: 'Elgin Avenue' }, { coords: pt(10, 0), rule: 'none' }],
    routes: [[pt(1, 1), pt(2, 2)]],
    route: { points: [pt(5, 5), pt(9, 9)] },
};
const rows = P.pointListRows(loc, [spawns, kerb, flee, drive]);
out.rows = rows.map(r => `${r.key}${r.index}:${r.fromStart === null ? '-' : Math.round(r.fromStart)}:${r.street ?? ''}`);
const draft = JSON.parse(JSON.stringify(loc));
out.removed = P.removePointAt(draft, 'spawns', 3);
out.after = draft.spawns.map(p => p.y);
out.missing = P.removePointAt(draft, 'spawns', 9);
P.removePointAt(draft, 'spots', 1);
P.removePointAt(draft, 'spots', 1);
out.spotsGone = !('spots' in draft);
out.sent = P.pointsWithout(loc.spawns, 2).map(p => p.y);
const answer = { kind: 'placement', missionId: 'm', location: 1, key: 'spawns', cancelled: false,
    points: [pt(30, 40), pt(0, 100), pt(7, 7)], streets: ['A', 'C', 'New'] };
const put = P.resultReplacing(answer, 2);
out.placed = put.points.map(p => p.y);
out.streets = put.streets;
console.log(JSON.stringify(out));
]==]
js = js:gsub('WEB_DIR', function() return root .. 'web/src/builder' end)
local tmp = os.tmpname()
local entry, bundle = tmp .. '.js', tmp .. '.cjs'
local f = assert(io.open(entry, 'w'))
f:write(js)
f:close()
local cmd = ('\'%s\' \'%s\' --bundle --platform=node --format=cjs --log-level=error --outfile=\'%s\' 2>&1 && node \'%s\' 2>&1'):format(
    esbuild, entry, bundle, bundle)
local p = io.popen(cmd)
local text = p:read('a')
p:close()
os.remove(tmp)
os.remove(entry)
os.remove(bundle)
local ok, got = pcall(cjson.decode, text:match('{.*}') or '')
H.ok(ok and type(got) == 'table', 'pointList.ts ran in node: ' .. text:sub(1, 300))
got = (ok and type(got) == 'table') and got or {}
H.eq(cjson.encode(got.rows or {}),
    cjson.encode({ 'start1:-:', 'spawns1:50:', 'spawns2:100:', 'spawns3:100:', 'spots1:50:Elgin Avenue', 'spots2:10:' }),
    'one row per point: the start, then each point with its distance and street (no flee path or road route)')
H.eq(got.removed, true, 'Delete takes the point out')
H.eq(cjson.encode(got.after or {}), '[40,80]', 'only that point goes, the others keep their order')
H.eq(got.missing, false, 'a point that is not there is not deleted')
H.eq(got.spotsGone, true, 'the key goes with its last point')
H.eq(cjson.encode(got.sent or {}), '[40,100]', '"Set here" on point 2 sends the other points')
H.eq(cjson.encode(got.placed or {}), '[40,7,100]', 'the new spot takes position 2')
H.eq(cjson.encode(got.streets or {}), '["A","New","C"]', 'the street names follow their points')

return H
