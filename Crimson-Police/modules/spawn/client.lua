-- CP.Spawn (client): what this officer's game can see of the points where a mission's people may appear (the spawn
-- director's hidden points, Config.Spawning.preferHidden), where a person who walks up to a car appears (contactRing),
-- whether the ground at a point is fit to put a person, a vehicle or an object on (Config.Spawning.ground), the placer.

CP.Spawn = CP.Spawn or {}
local Spawn = CP.Spawn
local TAG = 'spawn'

local VISIBLE_CALLBACK = 'crimson-police:client:spawn:visible'
local MAX_POINTS = 32            -- points answered in one ask (the server sends at most this many)
local BUDGET_MS = { 50, 5000 }   -- the probe time the server may ask for, at least and at most
local LOS_FLAGS = 1 + 2 + 16     -- the map, vehicles and objects (containers, crates) block the view; glass, peds not
local LOS_OPTIONS = 7            -- ignore glass, see-through and no-collision parts
local HEAD_BONE = 31086          -- SKEL_Head
local TARGETS = { 1.0, 1.7 }     -- metres above a point: a standing person's chest and head
local RUNNING_MAX = 16           -- probes running at once (the game's pool of shape tests is small)
local DRAIN_FRAMES = 60          -- frames a probe still running after the time ran out is read, so its handle is freed

local function IsYes(v) return v == true or v == 1 end

local function Num(v)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

-- Where the officer looks from: his head and the camera the player sees through (third person sees over a low
-- wall his head does not), and the entity the probes ignore (his car, else himself).
local function Eyes()
    local ped = PlayerPedId()
    local eyes = {}
    local head = GetPedBoneCoords(ped, HEAD_BONE, 0.0, 0.0, 0.0)
    if head and Num(head.x) and Num(head.y) and Num(head.z) then eyes[#eyes + 1] = head end
    local cam = GetFinalRenderedCamCoord()
    if cam and Num(cam.x) and Num(cam.y) and Num(cam.z) then eyes[#eyes + 1] = cam end
    local veh = GetVehiclePedIsIn(ped, false)
    return eyes, (veh and veh ~= 0) and veh or ped
end

-- Reads the probes still running a little longer, so the game frees their handles.
local function Drain(running)
    if #running == 0 then return end
    CreateThread(function()
        for _ = 1, DRAIN_FRAMES do
            local still = {}
            for _, job in ipairs(running) do
                if GetShapeTestResult(job.handle) == 1 then still[#still + 1] = job end
            end
            running = still
            if #running == 0 then return end
            Wait(0)
        end
    end)
end

-- One answer per point: true = this game sees where a person would stand there (or cannot tell: no ground loaded
-- yet, a probe that did not start or did not finish within budgetMs, a point that is not one), false = hidden: every
-- line from both eyes to the chest and the head height of the point hits the map, a vehicle or an object first.
-- Points are { x, y, z } (at most MAX_POINTS are probed; the rest are seen).
function Spawn.visible(points, budgetMs)
    local out = {}
    if type(points) ~= 'table' then return out end
    local count = math.min(#points, MAX_POINTS)
    for k = 1, count do out[k] = true end
    local eyes, ignore = Eyes()
    if #eyes == 0 or count == 0 then return out end
    local budget = Num(budgetMs) or BUDGET_MS[2]
    budget = math.max(BUDGET_MS[1], math.min(BUDGET_MS[2], budget))

    local jobs = {}
    for k = 1, count do
        local p = points[k]
        local x, y, z = nil, nil, nil
        if type(p) == 'table' then x, y, z = Num(p.x or p[1]), Num(p.y or p[2]), Num(p.z or p[3]) end
        if x and y and z then
            for _, eye in ipairs(eyes) do
                for _, rise in ipairs(TARGETS) do
                    jobs[#jobs + 1] = { k = k, from = eye, x = x, y = y, z = z + rise }
                end
            end
        end
    end
    local need = #eyes * #TARGETS
    local blocked = {}
    local nextJob, running = 1, {}
    local deadline = GetGameTimer() + budget
    while (nextJob <= #jobs or #running > 0) and GetGameTimer() < deadline do
        while nextJob <= #jobs and #running < RUNNING_MAX do
            local job = jobs[nextJob]
            nextJob = nextJob + 1
            local e = job.from
            job.handle = StartShapeTestLosProbe(e.x, e.y, e.z, job.x, job.y, job.z, LOS_FLAGS, ignore, LOS_OPTIONS)
            -- a probe that did not start leaves its point seen
            if job.handle and job.handle ~= 0 then running[#running + 1] = job end
        end
        Wait(0)
        local still = {}
        for _, job in ipairs(running) do
            local status, hit = GetShapeTestResult(job.handle)
            if status == 2 then
                if IsYes(hit) then blocked[job.k] = (blocked[job.k] or 0) + 1 end
            elseif status == 1 then
                still[#still + 1] = job
            end
        end
        running = still
    end
    Drain(running)
    for k = 1, count do out[k] = (blocked[k] or 0) < need end
    return out
end

-- The server's ask: { points = { { x, y, z } }, ms = the time this game may probe }.
lib.callback.register(VISIBLE_CALLBACK, function(args)
    if type(args) ~= 'table' then return {} end
    local ok, res = pcall(Spawn.visible, args.points, args.ms)
    if not ok then
        CP.warn(TAG, 'line of sight failed: %s', tostring(res))
        return {}
    end
    return res
end)

-- ============================================================================
--                                 GROUND PROBE
-- ============================================================================
-- Whether a point of a mission is fit to put a person, a vehicle or an object on (owner request of 2026-10-19: "i
-- do not want them spawning in the ground"). A library: the Check spawn points tool and the placer use it.

local SHAPE_FLAGS = 1 + 2 + 16 -- a wall is the map, a vehicle or an object (the Builder's placement probe)
local SHAPE_OPTIONS = 7 -- glass, see-through and no-collision parts are no wall
local PROBE_OVER = 2.0 -- metres over the point the ground under it is looked for
local ROOF_OVER = 50.0 -- metres over the point the second look starts (a roof, a bridge, deep ground)
local NEAR_OVER = 0.1 -- metres over the point the look for the ground right under it starts (under any low roof)
local WATER_UNDER = 1.5 -- metres under the point the water probe ends (the Builder's)
local CAPSULE_MS = 1000 -- the wall probe may take this long; unfinished = not known, not a wall
local MODEL_MS = 2000 -- a vehicle model may take this long to load for its size
local PED_LIFT = 1.0 -- a standing person's point is this far over the ground (the Builder stores so)
local PED_SHAPE = { low = 0.45, high = 1.7, r = 0.32 } -- the capsule a standing person fills
local CAR_SHAPE = { lift = 0.5, half = 2.3, r = 0.8, midZ = 1.0 } -- a car of unknown size (the Builder's)
local TIMEOUT_MS = { 500, 30000 } -- collisionTimeoutMs and interiorTimeoutMs are kept inside this
local SNAP_MAX = 10.0 -- metres: snapWithin is kept under this
local KINDS = { ped = 'ped', vehicle = 'vehicle', prop = 'prop', object = 'prop' }
local RANGE_KEYS = { ped = 'pedAbove', vehicle = 'vehicleAbove', prop = 'propAbove' }
local RANGE_DEFAULTS = { ped = { -0.3, 1.6 }, vehicle = { -0.2, 1.5 }, prop = { -0.1, 0.5 } }

local function Clamp(x, lo, hi) if x < lo then return lo end if x > hi then return hi end return x end

local function HeadingDir(h)
    local r = math.rad(h)
    return -math.sin(r), math.cos(r)
end

local function GroundCfg() return (Config.Spawning or {}).ground or {} end

-- x, y, z of a vector the game handed back (a vector3, or a table in a test), or nil.
local function XYZ(v)
    local t = type(v)
    if t ~= 'table' and t ~= 'userdata' and t ~= 'vector3' then return nil end
    local x, y, z = Num(v.x), Num(v.y), Num(v.z)
    if not (x and y and z) then return nil end
    return x, y, z
end

-- The lowest and highest height over the ground a point of this kind fits (config.lua's while it is a range).
local function RangeOf(kind)
    local r = GroundCfg()[RANGE_KEYS[kind]]
    if type(r) == 'table' then
        local lo, hi = Num(r[1]), Num(r[2])
        if lo and hi and lo <= hi then return lo, hi end
    end
    local d = RANGE_DEFAULTS[kind]
    return d[1], d[2]
end

local function TimeoutOf(key, default)
    return Clamp(Num((Config.Spawning or {})[key]) or default, TIMEOUT_MS[1], TIMEOUT_MS[2])
end

-- The highest ground under (x, y, fromZ) and the z of its surface normal, or nil when the game finds none.
local function GroundUnder(x, y, fromZ)
    local found, gz, normal = GetGroundZAndNormalFor_3dCoord(x, y, fromZ)
    gz = Num(gz)
    if not IsYes(found) or not gz or gz > fromZ then return nil end
    local _, _, nz = XYZ(normal)
    return gz, nz
end

-- Water over the ground at the point (the Builder's check).
local function InWater(x, y, z, groundZ)
    if IsYes(TestProbeAgainstWater(x, y, z + PROBE_OVER, x, y, z - WATER_UNDER)) then return true end
    local found, height = GetWaterHeight(x, y, z + PROBE_OVER)
    height = Num(height)
    return IsYes(found) and height ~= nil and height > groundZ + 0.1
end

-- Waits for the ground around the point until the entity's collision is loaded or the deadline: true when it is.
local function LoadCollision(x, y, z, entity, deadline)
    while true do
        RequestCollisionAtCoord(x, y, z)
        if IsYes(HasCollisionLoadedAroundEntity(entity)) then return true end
        if GetGameTimer() >= deadline then return false end
        Wait(0)
    end
end

-- The inside of a building at the point: its id (0 = outside), whether it is loaded, whether this probe pinned it
-- (and unpins it when done).
local function LoadInterior(x, y, z, timeoutMs)
    local id = math.tointeger(tonumber(GetInteriorAtCoords(x, y, z)) or 0) or 0
    if id == 0 then return 0, true, false end
    if IsYes(IsInteriorReady(id)) then return id, true, false end
    PinInteriorInMemory(id)
    local deadline = GetGameTimer() + timeoutMs
    while GetGameTimer() < deadline do
        Wait(0)
        if IsYes(IsInteriorReady(id)) then return id, true, true end
    end
    return id, false, true
end

-- How big a vehicle model is for the wall probe and how far its point sits over the ground (the Builder's way), and
-- whether that came from the model: a car of unknown size when the model is unknown or does not load in time.
local function VehicleShape(model)
    local hash = model
    if type(model) == 'string' and model ~= '' then hash = joaat(model) end
    hash = math.tointeger(hash)
    local shape = { lift = CAR_SHAPE.lift, half = CAR_SHAPE.half, r = CAR_SHAPE.r, midZ = CAR_SHAPE.midZ }
    if not hash or hash == 0 or not IsYes(IsModelInCdimage(hash)) then return shape, false end
    local requested = false
    if not IsYes(HasModelLoaded(hash)) then
        RequestModel(hash)
        requested = true
        local deadline = GetGameTimer() + MODEL_MS
        while not IsYes(HasModelLoaded(hash)) and GetGameTimer() < deadline do Wait(0) end
    end
    local mn, mx = GetModelDimensions(hash)
    if requested then SetModelAsNoLongerNeeded(hash) end
    local minX, minY, minZ = XYZ(mn)
    local maxX, maxY, maxZ = XYZ(mx)
    if not (minX and maxX) then return shape, false end
    local width, length, height = maxX - minX, maxY - minY, maxZ - minZ
    if width <= 0 or length <= 0 or height <= 0 then return shape, false end
    shape.lift = Clamp(-minZ, 0.2, 1.5)
    shape.half = math.max(0.5, length / 2.0)
    shape.midZ = math.max(0.6, height / 2.0 + 0.15)
    shape.r = Clamp(math.min(width / 2.0 * 0.8, 1.0), 0.3, shape.midZ - 0.2)
    return shape, true
end

-- The capsule a standing person or the vehicle fills on the ground at gz (the Builder's placement probe).
local function StartCapsule(kind, x, y, gz, h, shape, ignore)
    if kind == 'ped' then
        return StartShapeTestCapsule(x, y, gz + PED_SHAPE.low, x, y, gz + PED_SHAPE.high, PED_SHAPE.r, SHAPE_FLAGS,
            ignore, SHAPE_OPTIONS)
    end
    local fx, fy = HeadingDir(h)
    local a = math.max(0.1, shape.half - shape.r)
    local zc = gz + shape.midZ
    return StartShapeTestCapsule(x + fx * a, y + fy * a, zc, x - fx * a, y - fy * a, zc, shape.r, SHAPE_FLAGS, ignore,
        SHAPE_OPTIONS)
end

-- true = the capsule hits the map, a vehicle or an object; false = clear; nil = not known (the probe did not start,
-- the game lost it, or it did not finish within CAPSULE_MS: then it is read a little longer, so its handle is freed).
local function InWall(kind, x, y, gz, h, shape, ignore)
    local handle = StartCapsule(kind, x, y, gz, h, shape, ignore)
    if not handle or handle == 0 then return nil end
    local deadline = GetGameTimer() + CAPSULE_MS
    while true do
        local status, hit = GetShapeTestResult(handle)
        if status == 2 then return IsYes(hit) end
        if status ~= 1 then return nil end
        if GetGameTimer() >= deadline then
            Drain({ { handle = handle } })
            return nil
        end
        Wait(0)
    end
end

-- Checks the point (x, y, z, heading h) for a 'ped', a 'vehicle' (model: its name or hash, for its size) or a 'prop'
-- (anything else). Loads the ground there first (the collision of opts.entity, default this player's ped, within
-- Config.Spawning.collisionTimeoutMs) and the inside of a building (interiorTimeoutMs). opts.wall = false skips the
-- wall probe (a marker an officer walks to: a door may stand in the space). Needs a thread. Returns
-- { status, groundZ, dz, z, ... }: see docs/ARCHITECTURE.md 5.43.
function Spawn.probe(kind, x, y, z, h, model, opts)
    kind = KINDS[kind] or 'prop'
    opts = type(opts) == 'table' and opts or {}
    x, y, z = Num(x), Num(y), Num(z)
    local res = { kind = kind, status = 'no_ground', interior = 0, loaded = false, water = false }
    if not (x and y and z) then return res end
    x, y, z = x + 0.0, y + 0.0, z + 0.0
    h = (Num(h) or 0.0) + 0.0
    res.x, res.y, res.z = x, y, z
    local ped = PlayerPedId()
    local entity = math.tointeger(opts.entity) or ped
    local ignore = math.tointeger(opts.ignore)
    if not ignore then
        local veh = GetVehiclePedIsIn(ped, false)
        ignore = (veh and veh ~= 0) and veh or ped
    end
    local deadline = GetGameTimer() + TimeoutOf('collisionTimeoutMs', 6000)
    res.loaded = LoadCollision(x, y, z, entity, deadline)

    local interior, ready, pinned = LoadInterior(x, y, z, TimeoutOf('interiorTimeoutMs', 5000))
    res.interior = interior
    local function done(status)
        res.status = status
        if pinned then UnpinInterior(interior) end
        return res
    end
    if not ready then return done('interior_not_loaded') end

    -- the highest ground under the point (from 2 m over it) and under 50 m over it (a roof or a bridge over the
    -- point, or the ground over a point buried more than 2 m); the game finds it only once the collision is there
    local low, lowNormal, high, highNormal
    repeat
        RequestCollisionAtCoord(x, y, z)
        low, lowNormal = GroundUnder(x, y, z + PROBE_OVER)
        high, highNormal = GroundUnder(x, y, z + ROOF_OVER)
        if low or high then break end
        Wait(0)
    until GetGameTimer() >= deadline
    local gz = low or high
    if not gz then return done('no_ground') end
    local normalZ, roofZ = highNormal, nil
    if low then normalZ = lowNormal end
    if high and high > z + PROBE_OVER then roofZ = high end

    local shape = nil
    if kind == 'vehicle' then shape, res.sized = VehicleShape(model) end
    local lift = kind == 'ped' and PED_LIFT or (shape and shape.lift or 0.0)
    res.lift = lift
    local lo, hi = RangeOf(kind)
    local snapWithin = Clamp(Num(GroundCfg().snapWithin) or 3.0, 0.0, SNAP_MAX)
    -- how far the point is from standing on the ground at g: 0 inside its range, else the move onto it
    local function MoveTo(g)
        if z - g >= lo and z - g <= hi then return 0.0 end
        return math.abs(g + lift - z)
    end
    -- the 2 m look found a surface over the point (a low roof or the floor above over a person inside, or the
    -- ground over a buried point) and there is ground right under it: the point is on the one it needs the smaller
    -- move to (the one under it on a tie), and then the surface over it is its roof
    if low and low > z + NEAR_OVER then
        local near, nearNormal = GroundUnder(x, y, z + NEAR_OVER)
        if near and MoveTo(near) <= MoveTo(low) then gz, normalZ, roofZ = near, nearNormal, low end
    end
    res.groundZ, res.dz, res.normalZ, res.roofZ = gz, z - gz, normalZ, roofZ
    if InWater(x, y, z, gz) then
        res.water = true
        return done('in_water')
    end

    local status = 'ok'
    if res.dz < lo or res.dz > hi then
        -- outside its range: put on the ground (gz + lift) when that is a small move, else bad
        if math.abs(gz + lift - z) <= snapWithin then
            status, res.z = 'snap', gz + lift
        else
            status = res.dz < lo and 'underground' or 'floating'
        end
    end
    if status ~= 'ok' and status ~= 'snap' then return done(status) end
    if kind ~= 'prop' and opts.wall ~= false then
        res.wall = InWall(kind, x, y, gz, h, shape, ignore)
        if res.wall == true then status = 'in_wall' end
    end
    return done(status)
end

-- ============================================================================
--                 WALK-IN POINT (a returning driver, a thief)
-- ============================================================================
-- Where a person who walks up to a car this officer is dealing with appears (Config.Spawning.contactRing; the server's
-- field_contact block asks, blocks/field_contact/server.lua): a footpath point (the navmesh, never inside a building or
-- in water) ring[1] to ring[2] metres from the car and ring[1] or more from this officer, in front of him (where his
-- camera looks), the ones he cannot see first. Its z is where a standing person's point sits (PED_LIFT over the
-- navmesh); the placer then puts him on the ground there.

local WALK_IN_CALLBACK = 'crimson-police:client:spawn:walkIn'
local WALK_IN_ANGLES = { 0, -25, 25, -50, 50, -75, 75 }  -- degrees off the officer's view, round the car
local WALK_IN_STEPS = 3                                  -- distances tried from ring[1] to ring[2]
local WALK_IN_FLAGS = 4 + 8                              -- GetSafeCoordForPed: no navmesh made from a building's inside, none in water
local WALK_IN_FRONT = 90.0                               -- degrees: a point further than this off his view is behind him
local WALK_IN_RING = { 5.0, 100.0 }                      -- metres the server may ask for
local WALK_IN_APART = 2.0                                -- metres: two navmesh points closer than this are the same one
local WALK_IN_MAX = 8                                    -- points answered, best first

local function Dist2(ax, ay, bx, by) return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

-- The direction this officer looks along the ground: his camera's, else his ped's heading.
local function ViewDir(ped)
    local rot = GetFinalRenderedCamRot(2)
    local h = rot and Num(rot.z) or nil
    if not h then h = Num(GetEntityHeading(ped)) or 0.0 end
    return HeadingDir(h)
end

-- Up to WALK_IN_MAX points { x, y, z, hidden } for a person who walks up to the car at car ({ x, y, z }), best
-- first: hidden ones (Spawn.visible within budgetMs) before seen ones, each group nearest the officer's view and the
-- car first. ring = { nearest, furthest } metres from the car. Empty when no footpath point fits.
function Spawn.walkIn(car, ring, budgetMs)
    local out = {}
    if type(car) ~= 'table' or type(ring) ~= 'table' then return out end
    local cx, cy, cz = Num(car.x or car[1]), Num(car.y or car[2]), Num(car.z or car[3])
    local r1, r2 = Num(ring[1]), Num(ring[2])
    if not (cx and cy and cz and r1 and r2) then return out end
    r1 = Clamp(r1, WALK_IN_RING[1], WALK_IN_RING[2])
    r2 = Clamp(r2, r1, WALK_IN_RING[2])
    local ped = PlayerPedId()
    local mx, my = XYZ(GetEntityCoords(ped))
    if not mx then return out end
    local fx, fy = ViewDir(ped)
    local kept = {}
    for step = 0, WALK_IN_STEPS - 1 do
        local d = r1 + (r2 - r1) * step / math.max(1, WALK_IN_STEPS - 1)
        for _, off in ipairs(WALK_IN_ANGLES) do
            local a = math.rad(off)
            local dx = fx * math.cos(a) - fy * math.sin(a)
            local dy = fx * math.sin(a) + fy * math.cos(a)
            local found, safe = GetSafeCoordForPed(cx + dx * d, cy + dy * d, cz + PED_LIFT, false, WALK_IN_FLAGS)
            local sx, sy, sz = XYZ(safe)
            if IsYes(found) and sx then
                local dc, dm = Dist2(sx, sy, cx, cy), Dist2(sx, sy, mx, my)
                local vx, vy = sx - mx, sy - my
                local front = dm > 0 and math.deg(math.acos(Clamp((vx * fx + vy * fy) / dm, -1.0, 1.0))) or 180.0
                local fresh = true
                for _, k in ipairs(kept) do
                    if Dist2(k.x, k.y, sx, sy) < WALK_IN_APART then fresh = false end
                end
                if fresh and dc >= r1 and dc <= r2 and dm >= r1 and front <= WALK_IN_FRONT then
                    kept[#kept + 1] = { x = sx + 0.0, y = sy + 0.0, z = sz + PED_LIFT }
                end
            end
        end
    end
    if #kept == 0 then return out end
    local seen = Spawn.visible(kept, budgetMs)
    for _, hidden in ipairs({ true, false }) do
        for k, p in ipairs(kept) do
            if #out < WALK_IN_MAX and (seen[k] == false) == hidden then
                out[#out + 1] = { x = p.x, y = p.y, z = p.z, hidden = hidden }
            end
        end
    end
    return out
end

-- The server's ask: { car = { x, y, z }, ring = { nearest, furthest }, ms = the time this game may probe }.
lib.callback.register(WALK_IN_CALLBACK, function(args)
    if type(args) ~= 'table' then return {} end
    local ok, res = pcall(Spawn.walkIn, args.car, args.ring, args.ms)
    if not ok then
        CP.warn(TAG, 'walk-in point failed: %s', tostring(res))
        return {}
    end
    return res
end)

-- ============================================================================
--                                    PLACER
-- ============================================================================
-- A new mission entity can wait frozen where the server made it until a game near it has put it on the ground (PLAN
-- S9; owner request of 2026-10-19: "i do not want them spawning in the ground"). The server asks through the entity's
-- cp bag: place = { x, y, z, h, kind, token, from? } (Config.Spawning.place; modules/spawn/server.lua writes it).
-- The game of a participant of that run places it: the one that controls the entity, or, when no participant's game
-- does, the participant's nearest to the point (it asks for control). It checks the server's point with Spawn.probe,
-- puts the entity on the ground there (ok or snap: only up or down, never to another spot) and lets a person or a
-- vehicle go (an object stays frozen), or leaves a bad point frozen, and then tells the server (server:spawnPlaced).
-- After a bad point the server may ask again with another point and from = where it waits: it is moved there first.
-- Until then nothing lets it go: CP.Npc asks Spawn.holds before it unfreezes a person (modules/npc/client.lua LetGo).

local PLACED_EVENT = 'server:spawnPlaced'
local CHECKING_EVENT = 'server:spawnChecking'
local PLACE_ENTITY_MS = 3000    -- the entity of a bag may take this long to exist in this game
local PLACE_CONTROL_MS = 2000   -- this game asks this long for control of an entity it places
local PLACERS_MAX = 4           -- entities placed at once (a wave's people and cars): the rest wait their turn
local PLACE_QUEUE_MS = 30000    -- an entity waits this long for its turn
local PLACE_MOVED_M = 3.0       -- an entity this far (flat) from the server's x, y was placed and let go already
local PLACE_KINDS = { ped = 'ped', vehicle = 'vehicle', object = 'prop', prop = 'prop' }
local ENTITY_TYPES = { [1] = 'ped', [2] = 'vehicle', [3] = 'prop' }  -- GetEntityType
local POSED = { cuffed = true }                                      -- a person CP.Npc holds frozen in this pose stays frozen

local placing = {} -- netId -> { token, run, state }: the ask this game places or answered (state: the bag's latest)
local placed = {}  -- entity -> { token, run }: the asks this game put on the ground (CP.Npc may let these go)
local placers = 0

local function IsToken(v) return type(v) == 'string' or math.type(v) == 'integer' end

-- true while the entity waits for its placement: its cp bag asks for one (place) and this game has not put it on the
-- ground for that ask. CP.Npc then leaves it frozen: the game that places it lets it go, or the server when it takes
-- an answer or gives up (it removes the ask), so a game with no ground loaded where it stands never drops it through
-- the map.
function Spawn.holds(ent)
    local ok, bag = pcall(function() return Entity(ent).state.cp end)
    if not ok or type(bag) ~= 'table' or bag.state == 'dead' then return false end
    local place = bag.place
    if type(place) ~= 'table' or not IsToken(place.token) then return false end
    local done = placed[ent]
    return not (done and done.token == place.token and done.run == bag.run)
end

local function MyServerId() return GetPlayerServerId(PlayerId()) end

local function ActiveSrcs(run)
    local out = {}
    for _, p in ipairs(type(run.participants) == 'table' and run.participants or {}) do
        local src = type(p) == 'table' and p.status == 'active' and math.tointeger(tonumber(p.src)) or nil
        if src then out[#out + 1] = src end
    end
    return out
end

local function Has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

-- The server id of the player whose game controls the entity, or nil (nobody, or a player this game does not know).
local function OwnerSrc(ent)
    local idx = math.tointeger(tonumber(NetworkGetEntityOwner(ent)))
    if not idx or idx < 0 then return nil end
    local src = math.tointeger(tonumber(GetPlayerServerId(idx)))
    return (src and src > 0) and src or nil
end

-- Of the active participants this game knows (their ped is streamed here), the one nearest to the point (the lower
-- server id on a tie).
local function NearestSrc(srcs, x, y, z)
    local best, bestD = nil, math.huge
    for _, src in ipairs(srcs) do
        local pl = GetPlayerFromServerId(src)
        if pl and pl ~= -1 and IsYes(NetworkIsPlayerActive(pl)) then
            local ped = GetPlayerPed(pl)
            local px, py, pz = nil, nil, nil
            if ped and ped ~= 0 then px, py, pz = XYZ(GetEntityCoords(ped)) end
            if px then
                local d = (px - x) ^ 2 + (py - y) ^ 2 + (pz - z) ^ 2
                if d < bestD or (d == bestD and src < best) then best, bestD = src, d end
            end
        end
    end
    return best
end

local function EntityOf(netId, ms)
    local deadline = GetGameTimer() + ms
    while true do
        if IsYes(NetworkDoesNetworkIdExist(netId)) then
            local ent = NetworkGetEntityFromNetworkId(netId)
            if ent and ent ~= 0 and IsYes(DoesEntityExist(ent)) then return ent end
        end
        if GetGameTimer() >= deadline then return nil end
        Wait(100)
    end
end

-- true once this game controls the entity (asked for it until ms ran out).
local function TakeControl(ent, ms)
    local deadline = GetGameTimer() + ms
    while true do
        if IsYes(NetworkHasControlOfEntity(ent)) then return true end
        if GetGameTimer() >= deadline or not IsYes(DoesEntityExist(ent)) then return false end
        NetworkRequestControlOfEntity(ent)
        Wait(0)
    end
end

local function Far(ent, x, y)
    local ex, ey = XYZ(GetEntityCoords(ent))
    return ex ~= nil and (ex - x) ^ 2 + (ey - y) ^ 2 > PLACE_MOVED_M ^ 2
end

-- true when the entity stands more than PLACE_MOVED_M (flat) from the server's x, y and from place.from (where it
-- waits after the server moved the ask to another point): it waited frozen there, so a game placed it and let it go
-- already (and could not tell the server: its player left the run)
local function Moved(ent, place, x, y)
    if not Far(ent, x, y) then return false end
    local from = type(place.from) == 'table' and place.from or nil
    local fx, fy = from and Num(from.x), from and Num(from.y)
    return not (fx and fy) or Far(ent, fx, fy)
end

-- 'seated' (a person in a vehicle), 'attached' (on another entity) or nil: it goes where that one goes.
local function Carried(ent, kind)
    if kind == 'ped' and IsYes(IsPedInAnyVehicle(ent, false)) then return 'seated' end
    if IsYes(IsEntityAttached(ent)) then return 'attached' end
    return nil
end

-- Takes control of one entity, checks and places it: 'placed' or 'bad', the reason (the probe's status, or 'seated' /
-- 'attached': it goes where its car or what it hangs on goes), the probe's result and the height it was put at.
-- Nothing (nil) when control is not given, the entity is gone or this game lost control during the check: then
-- nothing is told. rec.state is the bag's latest state (a later write of the same ask updates it).
local function PlaceEntity(ent, place, kind, rec)
    if not TakeControl(ent, PLACE_CONTROL_MS) then return nil end
    local x, y, z = Num(place.x) + 0.0, Num(place.y) + 0.0, Num(place.z) + 0.0
    FreezeEntityPosition(ent, true)
    SetEntityLoadCollisionFlag(ent, true)
    -- stays frozen once placed: an object, a person in a pose CP.Npc holds frozen
    local function Keep() return kind == 'prop' or POSED[rec.state] == true end
    local carried = Carried(ent, kind)
    if carried then
        if not Keep() then FreezeEntityPosition(ent, false) end
        return 'placed', carried, nil, nil
    end
    -- the server moved the ask to another point (the one before was bad): there first, so the ground loaded and
    -- probed is the one around it there
    if Far(ent, x, y) then SetEntityCoordsNoOffset(ent, x, y, z, kind == 'ped', false, true) end
    local h = Num(place.h) or Num(GetEntityHeading(ent)) or 0.0
    local model = kind == 'vehicle' and GetEntityModel(ent) or nil
    local res = Spawn.probe(kind, x, y, z, h, model, { entity = ent, ignore = ent })
    if not IsYes(DoesEntityExist(ent)) then return nil end
    -- seated or attached meanwhile (the server put him in his car right after it made him), or moved away during the
    -- check (the server set him somewhere else): left as he is, let go
    carried = Carried(ent, kind)
    if carried or Far(ent, x, y) then
        if not Keep() then FreezeEntityPosition(ent, false) end
        if carried then return 'placed', carried, nil, nil end
        local _, _, ez = XYZ(GetEntityCoords(ent))
        return 'placed', 'moved', nil, ez
    end
    if res.status ~= 'ok' and res.status ~= 'snap' then return 'bad', res.status, res, nil end
    if not TakeControl(ent, PLACE_CONTROL_MS) then return nil end
    -- on the ground at the server's x, y: a person's point 1 m over it, a vehicle's by its model, an object's on it
    local onZ = res.groundZ + (Num(res.lift) or 0.0)
    SetEntityCoordsNoOffset(ent, x, y, onZ, kind == 'ped', false, true)
    if kind == 'vehicle' then
        SetVehicleOnGroundProperly(ent)
    elseif kind == 'prop' then
        PlaceObjectOnGroundProperly(ent)
    end
    if not Keep() then FreezeEntityPosition(ent, false) end
    return 'placed', res.status, res, onZ
end

local function TryPlace(netId, bag, mine)
    local place, token = bag.place, bag.place.token
    local function Forget()
        if placing[netId] == mine then placing[netId] = nil end
    end
    local function Current()
        local run = CP.Runs and CP.Runs.current and CP.Runs.current()
        if type(run) ~= 'table' or run.id ~= bag.run or placing[netId] ~= mine then return nil end
        local srcs = ActiveSrcs(run)
        if not Has(srcs, MyServerId()) then return nil end
        return run, srcs
    end
    local ent = EntityOf(netId, PLACE_ENTITY_MS)
    local run, srcs = Current()
    if not ent or not run then return Forget() end
    local x, y, z = Num(place.x), Num(place.y), Num(place.z)
    -- who places it: the game that controls it; when that is no participant's (a bystander's, or nobody's), the
    -- nearest participant's
    local me = MyServerId()
    if not IsYes(NetworkHasControlOfEntity(ent)) then
        local owner = OwnerSrc(ent)
        if owner ~= me and ((owner and Has(srcs, owner)) or NearestSrc(srcs, x, y, z) ~= me) then return Forget() end
    end
    local kind = PLACE_KINDS[place.kind] or ENTITY_TYPES[GetEntityType(ent)] or 'prop'
    local result, reason, res, onZ = nil, nil, nil, nil
    if Moved(ent, place, x, y) then
        -- placed and let go already: left where it is, neither frozen nor moved
        local _, _, ez = XYZ(GetEntityCoords(ent))
        result, reason, onZ = 'placed', 'moved', ez
    else
        -- this game checks it (maybe after a wave's others: PLACERS_MAX at a time): the server's placeTimeoutMs waits
        TriggerServerEvent(CP.e(CHECKING_EVENT), bag.run, { netId = netId, token = token })
        local deadline = GetGameTimer() + PLACE_QUEUE_MS
        while placers >= PLACERS_MAX do
            if GetGameTimer() >= deadline then return Forget() end
            Wait(50)
        end
        if not Current() then return Forget() end
        -- the slot is taken before control is asked for (that waits), so no more than PLACERS_MAX run at once
        placers = placers + 1
        local ok
        ok, result, reason, res, onZ = pcall(PlaceEntity, ent, place, kind, mine)
        placers = placers - 1
        if not ok then
            CP.warn(TAG, 'placing %s %d failed: %s', kind, netId, tostring(result))
            return Forget()
        end
        if not result then
            CP.log(TAG, 'placing %s %d: no control of it, or it is gone; not told', kind, netId)
            return Forget()
        end
    end
    if result == 'placed' then placed[ent] = { token = token, run = bag.run } end
    if not Current() then return end
    res = res or {}
    TriggerServerEvent(CP.e(PLACED_EVENT), bag.run, {
        netId = netId,
        token = token,
        result = result,
        reason = reason,
        groundZ = res.groundZ,
        dz = res.dz,
        z = onZ,
    })
    CP.log(TAG, '%s %d %s (%s)%s', kind, netId, result, reason, onZ and (' at %.2f'):format(onZ) or '')
end

AddStateBagChangeHandler('cp', nil, function(bagName, _, value)
    local netId = math.tointeger(tonumber(tostring(bagName):match('^entity:(%d+)$')))
    if not netId then return end
    local place = type(value) == 'table' and value.place or nil
    if type(place) ~= 'table' or value.state == 'dead' then
        placing[netId] = nil
        return
    end
    local was = placing[netId]
    if was and was.token == place.token and was.run == value.run then
        was.state = value.state -- a later write of the same ask: the person's state now
        return
    end
    if not IsToken(place.token) or type(value.run) ~= 'string' then return end
    if not (Num(place.x) and Num(place.y) and Num(place.z)) then return end
    local run = CP.Runs and CP.Runs.current and CP.Runs.current()
    if type(run) ~= 'table' or run.id ~= value.run then return end
    local rec = { token = place.token, run = value.run, state = value.state }
    placing[netId] = rec
    CreateThread(function()
        Wait(0) -- change handlers run before the new value is in the bag
        local ok, err = pcall(TryPlace, netId, value, rec)
        if not ok then
            CP.warn(TAG, 'placing entity %d failed: %s', netId, tostring(err))
            if placing[netId] == rec then placing[netId] = nil end
        end
    end)
end)

-- The asks of a run that ended are forgotten (a placement still running for it stops before it tells the server).
RegisterNetEvent(CP.e('client:runEnded'), function(runId)
    for netId, rec in pairs(placing) do
        if rec.run == runId then placing[netId] = nil end
    end
    for ent, rec in pairs(placed) do
        if rec.run == runId then placed[ent] = nil end
    end
end)
