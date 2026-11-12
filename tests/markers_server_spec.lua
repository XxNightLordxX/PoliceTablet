-- CP.Markers (modules/map/markers.lua): every part of a mission besides its objective, the extra parts shipped off.

-- CP.Markers (modules/map/markers.lua): every part of a mission besides its objective, the extra parts shipped off.
-- Who gets which part (each part's on, its rules by department, job, grade, mission type, mission and role), the
-- extraParts switch, Radio Silence, the fairness rules (no live suspect, nothing staged or hidden, a hiding spot only
-- once found), the prisoner van and tow truck (their own on, never a second blip) and the clean-up.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- ============================================================================
--                                  THE WORLD
-- ============================================================================

local ents = {}                 -- [entity] = coords
local buckets = {}              -- [src] = routing bucket
_G.DoesEntityExist = function(e) return ents[e] ~= nil or (e or 0) % 100 == 0 end
local realCoords = GetEntityCoords
_G.GetEntityCoords = function(e)
    if ents[e] then return ents[e] end
    return realCoords(e)
end
_G.GetPlayerRoutingBucket = function(src) return buckets[src] or 0 end
for src = 1, 3 do H.players[src] = { ace = {}, coords = vec3(src * 100.0, 0.0, 30.0) } end

local officers = {
    [1] = { department = 'sast', job = 'sast', gradeLevel = 4, isSupervisor = true },
    [2] = { department = 'sast', job = 'sast', gradeLevel = 0, isSupervisor = false },
    [3] = { department = 'fib', job = 'fib', gradeLevel = 2, isSupervisor = false },
}
CP.Access = {
    getOfficer = function(src) return officers[src] end,
}

local silent = false
CP.Twists = {
    has = function(_, id) return id == 'radio_silence' and silent end,
}

local services = {}
CP.Custody = {
    _servicesOf = function() return services end,
}

local case = nil
CP.Opponents = {
    caseOf = function() return case end,
    view = function() return case and { scene = vec3(500.0, 500.0, 30.0) } or nil end,
}

local ctxs = {}
local run = {
    id = 'run-a',
    state = 'in_progress',
    missionId = 'store_robbery',
    missionType = 'patrol',
    leader = 1,
    location = { start = { coords = vec3(0.0, 0.0, 30.0) } },
    mission = { objectives = { { block = 'process_scene' }, { block = 'search_area' } } },
    objectives = { { status = 'active', state = {} }, { status = 'pending', state = {} } },
    entities = {},
}
local runs = { run }
CP.Runs = {
    all = function() return runs end,
    activeSrcs = function(r) return r == run and { 1, 2, 3 } or {} end,
    ctx = function(_, i) return ctxs[i] end,
}

H.load('modules/map/markers.lua')
local MB = CP.Markers

local function Entity(netId, entity, fields)
    ents[entity] = fields.coords or vec3(100.0, 100.0, 30.0)
    local e = {
        entity = entity,
        kind = fields.kind or 'ped',
        obj = fields.obj or 1,
        role = fields.role,
        tag = fields.tag,
    }
    for k, v in pairs(fields) do if k ~= 'coords' then e[k] = v end end
    run.entities[netId] = e
end

local function On(parts)
    Config.Markers.extraParts = true
    for _, p in pairs(Config.Markers.parts) do p.on = false end
    for _, id in ipairs(parts) do Config.Markers.parts[id].on = true end
end

-- the last list each officer got
local function Last(src)
    local list = nil
    for _, e in ipairs(H.events) do
        if e.name == 'crimson-police:client:markerParts' and e.target == src then list = e.args[1] end
    end
    return list
end

local function Parts(src)
    local l = Last(src)
    if not l then return nil end
    local out = {}
    for _, it in ipairs(l.items) do out[#out + 1] = it.p end
    table.sort(out)
    return table.concat(out, ',')
end

local function Pass()
    H.reset()
    MB.pass()
end

-- ============================================================================
--                          SHIPPED: OFF, NOTHING SENT
-- ============================================================================

H.eq(Config.Markers.extraParts, false, 'the extra parts ship off')
H.eq(Config.MissionBlips, nil, 'one blip system: no Config.MissionBlips')
H.eq(Config.Markers.serviceVehicles, nil, 'serviceVehicles became the vans\' on')
for id, p in pairs(Config.Markers.parts) do
    local van = id == 'prisonerVan' or id == 'towTruck'
    H.eq(p.on, van, 'part ' .. id .. (van and ' ships on (as serviceVehicles did)' or ' ships off'))
end
H.eq(#MB.parts(), 18, 'eighteen parts')
for _, id in ipairs(MB.parts()) do H.ok(Config.Markers.parts[id] ~= nil, 'config.lua has part ' .. id) end
H.eq(Config.Markers.kinds.prisonerVan, nil, 'the vans\' look is their part\'s, not a second kind')

Entity(11, 1101, { role = 'parked', kind = 'vehicle' })
Entity(12, 1201, { role = 'witness' })
Pass()
H.eq(#H.findEvents('crimson-police:client:markerParts'), 0, 'master off: nothing is sent to anyone')

-- every part on, master still off: still nothing
for _, p in pairs(Config.Markers.parts) do p.on = true end
Pass()
H.eq(#H.findEvents('crimson-police:client:markerParts'), 0, 'every part on but the master off: nothing is sent')
H.eq(MB.pass(), true, 'master off with no map holding blips: the tick stops')

-- ============================================================================
--                     PARTS, AND ONLY THE ONES THAT ARE ON
-- ============================================================================

On({ 'parkedCar' })
Pass()
H.eq(Parts(1), 'parkedCar', 'only the part that is on is sent')
H.eq(Last(1).runId, 'run-a', 'the list names its run')
H.eq(Last(1).items[1].n, 11, 'an entity part carries its netId (the client follows it)')
Pass()
H.eq(Last(1), nil, 'nothing changed: nothing is sent again')

On({ 'parkedCar', 'witness', 'evidence', 'sceneProp', 'device', 'ambush', 'suspectVehicle', 'coronerVan' })
Entity(13, 1301, { role = 'clue', kind = 'object' })
Entity(14, 1401, { role = 'body_bag', kind = 'object' })
Entity(15, 1501, { role = 'device', kind = 'object' })
Entity(16, 1601, { role = 'stopped_car', kind = 'vehicle' })
Entity(17, 1701, { role = 'service', tag = 'coroner', kind = 'vehicle' })
Entity(18, 1801, { role = 'service_driver', tag = 'coroner' })
Entity(19, 1901, { kind = 'object' })
Pass()
H.eq(Parts(2), 'coronerVan,device,evidence,evidence,parkedCar,sceneProp,suspectVehicle,witness',
    'each role maps to its part; the van driver is no part')

-- ============================================================================
--                                   FAIRNESS
-- ============================================================================
-- NOTHING STAGED, HIDDEN, DEAD, OR A LIVE SUSPECT.

Entity(21, 2101, { role = 'ambush_car', kind = 'vehicle', obj = 2 })
Entity(22, 2201, { role = 'witness', hiddenCfg = { model = 'x' } })
Entity(23, 2301, { role = 'witness', dead = true })
Pass()
H.eq(Parts(2), nil, 'a staged-ahead ambush car, a hidden contact and a dead witness change nothing')
run.objectives[2].status = 'active'
Pass()
H.ok(Parts(2):find('ambush', 1, true) ~= nil, 'the ambush car shows once its objective started (it appeared)')

-- a Traffic Enforcement violator (pursuit with observe): hidden while it cruises toward the observe point
On({ 'suspectVehicle' })
run.mission.objectives[2].block = 'pursuit'
Entity(24, 2401, { role = 'suspect_vehicle', kind = 'vehicle', obj = 2 })
ctxs[2] = { obj = { observe = { radius = 30 } }, state = { vehicles = { ['24'] = { state = 'cruising' } } } }
Pass()
H.eq(Parts(1), 'suspectVehicle',
    'a violator still cruising before the observe point is never sent (the stopped car is)')
ctxs[2].state.vehicles['24'].passed = true
Pass()
H.eq(Parts(1), 'suspectVehicle,suspectVehicle', 'the violator shows once it has passed the observe point')
ctxs[2].state.vehicles['24'] = { state = 'cruising' }
ctxs[2].obj.observe = nil
Pass()
H.eq(Last(1), nil, 'a pursuit without observe shows its car from the start (nothing changed)')
run.entities[24] = nil
ctxs[2] = nil
run.mission.objectives[2].block = 'search_area'

-- hiding spots: only once the fugitive was found
On({ 'hidingSpot' })
ctxs[2] = { state = { fugitives = { ['30'] = { spot = vec3(300.0, 300.0, 30.0), ran = false } } } }
run.mission.objectives[2].block = 'search_area'
Pass()
H.eq(Parts(1), '', 'a hiding spot whose fugitive was not found yet is never sent')
ctxs[2].state.fugitives['30'].ran = true
Pass()
H.eq(Parts(1), 'hidingSpot', 'the hiding spot shows once its fugitive was found')
H.eq(Last(1).items[1].x, 300.0, 'at the spot')

-- a live case: the reported points only, never a suspect, and the hospital while one is down
On({ 'reportedPoint', 'hospitalDrop', 'partner' })
run.mission.objectives[2].block = 'live_response'
ctxs[2] = { state = { reported = { { label = 'Suspect 1', coords = vec3(700.0, 700.0, 30.0) } } } }
case = { suspects = { cidA = { src = 9, state = 'free', lastCoords = vec3(701.0, 702.0, 30.0), down = false } } }
Pass()
local items = Last(2).items
local keys = {}
for _, it in ipairs(items) do keys[#keys + 1] = it.p .. '@' .. math.floor(it.x) end
table.sort(keys)
H.eq(table.concat(keys, ' '), 'partner@100 partner@300 reportedPoint@500 reportedPoint@700',
    'a live case: the scene and the last-reported point, the partners; never the suspect himself')
for _, it in ipairs(items) do H.ok(it.s ~= 9 and it.s ~= 2, 'no suspect and not himself: ' .. tostring(it.s)) end
case.suspects.cidA.down = true
Pass()
H.ok(Parts(2):find('hospitalDrop', 1, true) ~= nil, 'the hospital shows while a live suspect is down')
local hosp = nil
for _, it in ipairs(Last(2).items) do if it.p == 'hospitalDrop' then hosp = it end end
H.eq(hosp and math.floor(hosp.x), 308, 'the hospital nearest the scene (Pillbox), not where the suspect is')

-- a downed suspect who left (disconnect, then lost): the hospital goes
case.suspects.cidA.state = 'free'
case.suspects.cidA.src = nil
Pass()
H.ok(Parts(2):find('hospitalDrop', 1, true) == nil, 'a downed suspect who disconnected: no hospital')
case.suspects.cidA.src = 9
case.suspects.cidA.state = 'lost'
Pass()
H.ok((Parts(2) or ''):find('hospitalDrop', 1, true) == nil, 'a downed suspect who is lost: no hospital')
case.suspects.cidA.state = 'free'

-- a partner in another routing bucket (the arena) is not shown
buckets[3] = 7
Pass()
for _, it in ipairs(Last(2).items) do H.ok(it.s ~= 3, 'a partner in another bucket is left out') end
buckets[3] = nil
case = nil

-- ============================================================================
--                          RULES: WHO SEES WHICH PART
-- ============================================================================

On({ 'parkedCar' })
run.objectives[2].status = 'pending'
-- what each officer's map shows now (a pass sends only the lists that changed)
local shown = {}
local function Sees(src) return shown[src] == 'parkedCar' end
local function Rule(r)
    Config.Markers.rules = { parkedCar = r }
    MB._forgetOfficers()
    Pass()
    for src = 1, 3 do
        local p = Parts(src)
        if p ~= nil then shown[src] = p end
    end
end
Rule(nil)

Rule({ departments = { 'fib' } })
H.ok(not Sees(1) and not Sees(2) and Sees(3), 'departments: only FIB sees it')
Rule({ jobs = { 'sast' } })
H.ok(Sees(1) and Sees(2) and not Sees(3), 'jobs: only the sast job')
Rule({ grade = 2 })
H.ok(Sees(1) and not Sees(2) and Sees(3), 'grade: grade 2 and up')
Rule({ missionTypes = { 'tactical' } })
H.ok(not Sees(1) and not Sees(2) and not Sees(3), 'missionTypes: not on a patrol mission')
Rule({ missionTypes = { 'patrol' }, missions = { 'store_robbery' } })
H.ok(Sees(1) and Sees(2) and Sees(3), 'missionTypes and missions match')
Rule({ missions = { 'bank_job' } })
H.ok(not Sees(1), 'missions: another mission only')
Rule({ roles = 'leader' })
H.ok(Sees(1) and not Sees(2) and not Sees(3), 'roles leader: the run\'s leader only')
-- the leader leaves or drops: the run's host moves on (MigrateHost), run.leader stays who created it
run.host = 2
Rule({ roles = 'leader' })
H.ok(not Sees(1) and Sees(2) and not Sees(3), 'roles leader: the new host sees it once the leader has left')
run.host = nil
Rule({ roles = 'supervisor' })
H.ok(Sees(1) and not Sees(2) and not Sees(3), 'roles supervisor: supervisors only')
Rule({ departments = { 'sast' }, grade = 3 })
H.ok(Sees(1) and not Sees(2) and not Sees(3), 'rules are AND-ed')
Rule(nil)
H.ok(Sees(1) and Sees(2) and Sees(3), 'no rules: every officer on the run')

-- ============================================================================
--                                RADIO SILENCE
-- ============================================================================

On({ 'parkedCar', 'coronerVan', 'evidence', 'coronerDrop' })
services = { { id = 1, kind = 'coroner', status = 'parked', dest = vec4(50.0, 60.0, 30.0, 0.0) } }
silent = true
Config.Markers.radioSilence = 'area'
Pass()
H.eq(Parts(1), 'coronerDrop,coronerVan,evidence,evidence',
    'Radio Silence \'area\': no cars or people; vans and points stay')
Config.Markers.radioSilence = 'none'
Pass()
H.eq(Parts(1), 'coronerDrop,coronerVan', 'Radio Silence \'none\': only the vans and where they wait')
Config.Markers.radioSilence = 'area'
silent = false

-- the prisoner van and tow truck: never an extra part (modules/npc/custody sends their one blip each), on or off
On({ 'prisonerVan', 'prisonerDrop', 'towTruck' })
services = { { id = 2, kind = 'transport', status = 'coming', dest = vec4(80.0, 80.0, 30.0, 0.0) } }
Entity(31, 3101, { role = 'service', tag = 'transport', kind = 'vehicle' })
Entity(32, 3201, { role = 'service', tag = 'tow', kind = 'vehicle' })
Pass()
H.eq(Parts(1), 'prisonerDrop', 'the prisoner van and tow truck are never drawn twice: only the drop-off is added')
Config.Markers.parts.prisonerVan.on = false
Pass()
H.eq(Last(1), nil, 'with their own on off they are still no extra part')
Config.Markers.parts.prisonerVan.on = true
services[1].status = 'leaving'
Pass()
H.eq(Parts(1), '', 'a van that drives off has no drop-off any more')
run.entities[31], run.entities[32] = nil, nil

-- who may see the prisoner van and tow truck: their rules (modules/npc/custody asks), whatever extraParts says
Config.Markers.extraParts = false
H.eq(MB.vanAllowed('prisonerVan', run, 2), true, 'no rules: every officer on the run sees the van')
Config.Markers.rules = { prisonerVan = { grade = 2 } }
MB._forgetOfficers()
H.eq(MB.vanAllowed('prisonerVan', run, 2), false, 'its rules: a grade 0 officer does not see it')
H.eq(MB.vanAllowed('prisonerVan', run, 1), true, 'a grade 4 officer does')
H.eq(MB.vanAllowed('towTruck', run, 2), true, 'the tow truck has rules of its own')
H.eq(MB.vanAllowed('coronerVan', run, 1), false, 'only the prisoner van and tow truck are asked this way')
Config.Markers.rules = {}

-- ============================================================================
--                                   CLEAN-UP
-- ============================================================================

On({ 'parkedCar' })
Pass()
H.eq(Parts(1), 'parkedCar', 'shown again')
H.reset()
CP.Hooks.fire('run:ended', run, 'completed')
H.eq(Parts(1), '', 'run end: an empty list takes every blip off')
H.eq(Parts(3), '', 'for every officer of the run')
Pass()
H.eq(Parts(1), 'parkedCar', 'a run still going sends it again')
H.reset()
CP.Hooks.fire('participant:left', run, 2, 'left')
H.eq(Parts(2), '', 'an officer who leaves the run gets his blips taken off')
runs = {}
Pass()
H.eq(Parts(1), '', 'no run: every map that had blips is cleared')
H.eq(MB.pass(), true, 'and the tick stops')
runs = { run }
Pass()
Config.Markers.extraParts = false
Pass()
H.eq(Parts(1), '', 'extraParts turned off in game: every extra part is taken off at the next pass')

return H
