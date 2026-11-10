-- CP.Markers (server): every part of a mission besides its objective on the officers' maps (Config.Markers.parts).

-- CP.Markers (server): every part of a mission besides its objective on the officers' maps (Config.Markers.parts).
-- The prisoner van and tow truck coming to an officer are sent by modules/custody (their rules are read here,
-- M.vanAllowed; each client reads their on). Every other part waits for Config.Markers.extraParts (shipped off):
-- every refreshEvery seconds this lists those parts of each run (where the vans wait, the coroner van, evidence, cars
-- and people of a scene, devices, hiding spots once found, ambush cars, the hospital, partners, a live case's
-- reported points), keeps for each officer only the parts he may see (each part's on, its rules, Radio Silence) and
-- sends him the list when it changed. Fairness: no real player suspect is ever listed (they are never run entities; a
-- live case gives its last-reported points only), an entity of an objective that has not started (staged ahead) or a
-- hidden contact is not listed, and a hiding spot shows only once its fugitive was found.

CP.Markers = CP.Markers or {}
local M = CP.Markers
local U = CP.U
local TAG = 'markers'

local EVENT = 'client:markerParts'
local MAX_ITEMS = 64            -- blips one officer gets at most
local STILL_M = 1.0             -- metres: a point's position is sent rounded to this
local MOVING_M = 25.0           -- metres: a car's, person's or partner's position is sent rounded to this
local OFFICER_MS = 15000        -- an officer's department, job and grade are read again after this long
local ROLES = { all = true, leader = true, supervisor = true }

-- Every part, in the order the client gets them (and the Map markers screen lists them).
local PARTS = {
    'prisonerVan',
    'prisonerDrop',
    'towTruck',
    'impoundDrop',
    'coronerVan',
    'coronerDrop',
    'evidence',
    'suspectVehicle',
    'parkedCar',
    'witness',
    'hostage',
    'device',
    'hidingSpot',
    'sceneProp',
    'ambush',
    'hospitalDrop',
    'partner',
    'reportedPoint',
}
-- A run entity's role -> its part (the service vans by their tag: SERVICE_PART).
local ROLE_PART = {
    clue = 'evidence',
    body_bag = 'evidence',
    suspect_vehicle = 'suspectVehicle',
    contact_car = 'suspectVehicle',
    stopped_car = 'suspectVehicle',
    parked = 'parkedCar',
    scene_car = 'parkedCar',
    witness = 'witness',
    pedestrian = 'witness',
    hostage = 'hostage',
    device = 'device',
    ambush_car = 'ambush',
    attacker = 'ambush',
}
-- The service vans by their tag. The prisoner van and tow truck are modules/custody's (one blip each, M.vanAllowed).
local SERVICE_PART = { coroner = 'coronerVan' }
local VAN_PART = { prisonerVan = true, towTruck = true }
local DROP_PART = { transport = 'prisonerDrop', tow = 'impoundDrop', coroner = 'coronerDrop' }
local DROP_SHOWN = { coming = true, parked = true, loading = true }
-- What Radio Silence keeps of these parts: 'area' keeps the vans and every point, never a person or a car; 'none'
-- keeps only the vans and where they wait (as the prisoner van and tow truck themselves always show).
local VANS = {
    prisonerVan = true,
    prisonerDrop = true,
    towTruck = true,
    impoundDrop = true,
    coronerVan = true,
    coronerDrop = true,
}

local sent = {}                 -- [src] = { runId, sig } : what each officer's map got last
local officers = {}             -- [src] = { at, department, job, grade, supervisor }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return type(Config.Markers) == 'table' and Config.Markers or {} end

local function On() return Cfg().extraParts == true end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function Call(mod, fn, ...)
    local m = CP[mod]
    if not (m and type(m[fn]) == 'function') then return false end
    return pcall(m[fn], ...)
end

local function PartCfg(part)
    local parts = type(Cfg().parts) == 'table' and Cfg().parts or {}
    return type(parts[part]) == 'table' and parts[part] or nil
end

-- An extra part that shows: extraParts and its own on. The prisoner van and tow truck are never in this list.
local function PartOn(part)
    if VAN_PART[part] or not On() then return false end
    local p = PartCfg(part)
    return p ~= nil and p.on == true
end

local function AnyPartOn()
    for _, part in ipairs(PARTS) do if PartOn(part) then return true end end
    return false
end

local function Round(v, step) return math.floor(v / step + 0.5) * step end

-- { x, y, z } of a vector or table, rounded to step metres; nil when it is none.
local function Point(v, step)
    local x, y, z = U.xyz(v)
    if type(x) ~= 'number' or type(y) ~= 'number' then return nil end
    return { x = Round(x, step) + 0.0, y = Round(y, step) + 0.0, z = Round(Num(z, 0.0), step) + 0.0 }
end

local function Has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local function Bucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    return ok and tonumber(b) or 0
end

local function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not DoesEntityExist(ped) then return nil end
    return GetEntityCoords(ped)
end

local function Silence(run)
    local ok, on = Call('Twists', 'has', run, 'radio_silence')
    if not (ok and on) then return nil end
    local m = Cfg().radioSilence
    if m == 'full' or m == 'none' then return m end
    return 'area'
end

-- ============================================================================
--                                WHAT A RUN HAS
-- ============================================================================

-- The part of a run entity, or nil (not a part, dead, hidden, gone, or of an objective that has not started).
local function EntityPart(run, e)
    if type(e) ~= 'table' or e.dead or e.hiddenCfg ~= nil then return nil end
    if not (e.entity and DoesEntityExist(e.entity)) then return nil end
    local o = e.obj and type(run.objectives) == 'table' and run.objectives[e.obj] or nil
    if o and o.status == 'pending' then return nil end
    if e.role == 'service' then return SERVICE_PART[e.tag] end
    local part = ROLE_PART[e.role]
    if part then return part end
    if e.kind == 'object' then return 'sceneProp' end
    return nil
end

-- A pursuit's violator still cruising toward its observe point (Traffic Enforcement): the pursuit block keeps its
-- blip hidden until it has passed (blocks/pursuit ShowsBlip), and so does this module.
local function Unseen(run, e, netId)
    if e.role ~= 'suspect_vehicle' or not e.obj then return false end
    local obj = (run.mission and run.mission.objectives or {})[e.obj]
    if type(obj) ~= 'table' or obj.block ~= 'pursuit' then return false end
    local ok, ctx = Call('Runs', 'ctx', run, e.obj)
    if not (ok and type(ctx) == 'table' and type(ctx.obj) == 'table' and type(ctx.obj.observe) == 'table') then
        return false
    end
    local st = type(ctx.state) == 'table' and ctx.state or {}
    local v = type(st.vehicles) == 'table' and st.vehicles[tostring(netId)] or nil
    return type(v) == 'table' and v.passed ~= true and v.state == 'cruising'
end

-- The objectives that have started, with their ctx (CP.Runs.ctx): { { index, block, ctx } }.
local function StartedCtxs(run)
    local out = {}
    for i, o in ipairs(type(run.objectives) == 'table' and run.objectives or {}) do
        if o.status ~= 'pending' then
            local obj = (run.mission and run.mission.objectives or {})[i]
            local ok, ctx = Call('Runs', 'ctx', run, i)
            if ok and type(ctx) == 'table' and type(obj) == 'table' then
                out[#out + 1] = { index = i, block = obj.block, ctx = ctx }
            end
        end
    end
    return out
end

local function NearestHospital(near)
    local best, bestD = nil, nil
    for _, p in ipairs(type(Config.Downed) == 'table' and Config.Downed.dropOffs or {}) do
        local pt = Point(p, STILL_M)
        if pt then
            local d = near and U.dist(pt, near) or 0
            if not bestD or d < bestD then best, bestD = pt, d end
        end
    end
    return best
end

-- Every part of a run that is on: { { key, part, netId, src, coords, moving } }, sorted by key. The partner items name
-- their officer (src) so each officer's list leaves himself out.
function M.collect(run)
    local out = {}
    if type(run) ~= 'table' or run.state == 'ended' then return out end
    local function Add(key, part, coords, extra)
        if not PartOn(part) or not coords then return end
        local item = { key = key, part = part, coords = coords }
        for k, v in pairs(extra or {}) do item[k] = v end
        out[#out + 1] = item
    end
    -- the run's own entities
    for netId, e in pairs(type(run.entities) == 'table' and run.entities or {}) do
        local part = EntityPart(run, e)
        if part and PartOn(part) and not Unseen(run, e, netId) then
            local moving = e.kind ~= 'object'
            Add('e' .. tostring(netId), part, Point(GetEntityCoords(e.entity), moving and MOVING_M or STILL_M),
                { netId = netId, moving = moving })
        end
    end
    -- where the prisoner van, tow truck and coroner van wait for the officers
    local okS, services = Call('Custody', '_servicesOf', run)
    for _, s in ipairs(okS and type(services) == 'table' and services or {}) do
        local part = DROP_PART[s.kind]
        if part and DROP_SHOWN[s.status] and s.dest then
            Add('d' .. tostring(s.id), part, Point(s.dest, STILL_M))
        end
    end
    -- hiding spots whose fugitive was found (Manhunt), and a live case's reported scene and last-reported points
    for _, c in ipairs(StartedCtxs(run)) do
        local st = type(c.ctx.state) == 'table' and c.ctx.state or {}
        if c.block == 'search_area' then
            for id, f in pairs(type(st.fugitives) == 'table' and st.fugitives or {}) do
                if type(f) == 'table' and f.ran == true and f.spot then
                    Add(('h%d:%s'):format(c.index, tostring(id)), 'hidingSpot', Point(f.spot, STILL_M))
                end
            end
        elseif c.block == 'live_response' then
            for n, r in ipairs(type(st.reported) == 'table' and st.reported or {}) do
                Add(('r%d:%d'):format(c.index, n), 'reportedPoint', Point(r.coords, STILL_M))
            end
            local okV, view = Call('Opponents', 'view', run)
            if okV and type(view) == 'table' then
                Add('r' .. c.index .. ':scene', 'reportedPoint', Point(view.scene, STILL_M))
            end
        end
    end
    -- the hospital, while a suspect of the live case is down (never where he is)
    if PartOn('hospitalDrop') then
        local okC, case = Call('Opponents', 'caseOf', run)
        local down = false
        if okC and type(case) == 'table' and type(case.suspects) == 'table' then
            -- only a suspect still in play: one who left (disconnect, lost, detained by leave) keeps rec.down
            for _, rec in pairs(case.suspects) do
                if type(rec) == 'table' and rec.down and rec.src ~= nil
                    and (rec.state == 'free' or rec.state == 'cuffed' or rec.state == 'detained') then
                    down = true
                end
            end
        end
        if down then
            local start = run.location and run.location.start
            Add('hospital', 'hospitalDrop', NearestHospital(Point(type(start) == 'table' and start.coords or start, 1)))
        end
    end
    -- the officers of the run
    if PartOn('partner') then
        local okA, srcs = Call('Runs', 'activeSrcs', run)
        for _, src in ipairs(okA and type(srcs) == 'table' and srcs or {}) do
            Add('p' .. tostring(src), 'partner', Point(PedCoords(src), MOVING_M), { src = src, moving = true })
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- ============================================================================
--                                WHO SEES WHAT
-- ============================================================================

-- The officer's department, job, grade level and supervisor flag (CP.Access.getOfficer), kept OFFICER_MS.
local function Officer(src)
    local now = GetGameTimer()
    local o = officers[src]
    if o and now - o.at < OFFICER_MS then return o end
    local ok, off = Call('Access', 'getOfficer', src)
    off = ok and type(off) == 'table' and off or {}
    o = {
        at = now,
        department = off.department,
        job = off.job,
        grade = math.floor(Num(off.gradeLevel, 0)),
        supervisor = off.isSupervisor == true,
    }
    officers[src] = o
    return o
end

local function ListRule(list, v)
    if type(list) ~= 'table' or next(list) == nil then return true end
    return v ~= nil and Has(list, v)
end

-- Does officer (src, o) of run match the rules of part (Config.Markers.rules[part])? No rules = yes.
function M.allowed(part, run, src, o)
    local rules = type(Cfg().rules) == 'table' and Cfg().rules[part] or nil
    if type(rules) ~= 'table' then return true end
    o = o or Officer(src)
    if not ListRule(rules.departments, o.department) then return false end
    if not ListRule(rules.jobs, o.job) then return false end
    if tonumber(rules.grade) and (o.grade or 0) < tonumber(rules.grade) then return false end
    if not ListRule(rules.missionTypes, run.missionType) then return false end
    if not ListRule(rules.missions, run.missionId) then return false end
    local role = ROLES[rules.roles] and rules.roles or 'all'
    -- the run's current leader: run.host moves on when he leaves or drops (run.leader is only who created it)
    if role == 'leader' and (run.host or run.leader) ~= src then return false end
    if role == 'supervisor' and not o.supervisor then return false end
    return true
end

-- The items officer src of run gets: every collected item he may see, at most MAX_ITEMS, never himself.
function M.viewFor(run, src, items)
    local out = {}
    local silence = Silence(run)
    local bucket = Bucket(src)
    local o = nil
    local allowed = {}
    for _, it in ipairs(items) do
        local keep = it.src ~= src
        if keep and silence and silence ~= 'full' then
            if silence == 'none' then
                keep = VANS[it.part] == true
            else
                keep = VANS[it.part] == true or not it.moving
            end
        end
        if keep and it.src and Bucket(it.src) ~= bucket then keep = false end
        if keep then
            if allowed[it.part] == nil then
                o = o or Officer(src)
                allowed[it.part] = M.allowed(it.part, run, src, o)
            end
            keep = allowed[it.part]
        end
        if keep then
            out[#out + 1] = {
                k = it.key,
                p = it.part,
                n = it.netId,
                s = it.src,
                x = it.coords.x,
                y = it.coords.y,
                z = it.coords.z,
            }
            if #out >= MAX_ITEMS then break end
        end
    end
    return out
end

local function Sig(list)
    local parts = {}
    for i, it in ipairs(list) do
        parts[i] = ('%s|%s|%s|%s|%.0f|%.0f|%.0f'):format(it.k, it.p, tostring(it.n), tostring(it.s), it.x, it.y, it.z)
    end
    return table.concat(parts, ';')
end

local function Send(src, runId, list)
    local sig = Sig(list)
    local last = sent[src]
    if last and last.runId == runId and last.sig == sig then return false end
    if #list == 0 and not last then return false end
    sent[src] = #list > 0 and { runId = runId, sig = sig } or nil
    TriggerClientEvent(CP.e(EVENT), src, { runId = runId, items = list })
    return true
end

-- Take every extra part off src's map (run end, he left the run, the switch went off).
function M.clear(src)
    local last = sent[src]
    if not last then return false end
    sent[src] = nil
    TriggerClientEvent(CP.e(EVENT), src, { runId = last.runId, items = {} })
    return true
end

-- ============================================================================
--                                   THE TICK
-- ============================================================================

-- One pass: every officer on a run gets his list when it changed; everyone else whose map has blips gets them taken
-- off. Returns true (the tick stops) when the switch is off or no run is going and no map has blips left.
function M.pass()
    local seen = {}
    local any = false
    if AnyPartOn() then
        local okR, runs = Call('Runs', 'all')
        for _, run in ipairs(okR and type(runs) == 'table' and runs or {}) do
            any = true
            local items = M.collect(run)
            local okA, srcs = Call('Runs', 'activeSrcs', run)
            for _, src in ipairs(okA and type(srcs) == 'table' and srcs or {}) do
                seen[src] = true
                Send(src, run.id, M.viewFor(run, src, items))
            end
        end
    end
    for src in pairs(sent) do if not seen[src] then M.clear(src) end end
    return not any and next(sent) == nil
end

local function TickMs() return CP.Perf.ms(math.floor(U.clamp(Num(Cfg().refreshEvery, 3), 1, 30) * 1000)) end

local Arm = CP.Perf.armed(TAG, TickMs, M.pass)
M._arm = Arm

function M.parts() return U.copy(PARTS) end

-- May officer src of run see the prisoner van or tow truck (part 'prisonerVan' | 'towTruck')? Its part's rules;
-- its on is read by each client (CP.Markers.service hides the blip while it is off, so a change shows at once) and
-- extraParts does not matter.
function M.vanAllowed(part, run, src)
    if not VAN_PART[part] then return false end
    if type(run) ~= 'table' then return true end
    return M.allowed(part, run, src)
end

-- Forget the officers' departments, jobs and grades read so far (tests; a job change is seen within OFFICER_MS).
function M._forgetOfficers() officers = {} end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

if CP.Hooks then
    CP.Hooks.on('run:created', function() if On() then Arm() end end)
    CP.Hooks.on('participant:joined', function() if On() then Arm() end end)
    CP.Hooks.on('settings:changed', function() Arm() end)
    CP.Hooks.on('participant:left', function(_, src) M.clear(src) end)
    CP.Hooks.on('run:ended', function(run)
        for src, last in pairs(sent) do
            if type(run) == 'table' and last.runId == run.id then M.clear(src) end
        end
    end)
end

AddEventHandler('playerDropped', function()
    local src = source
    sent[src] = nil
    officers[src] = nil
end)
