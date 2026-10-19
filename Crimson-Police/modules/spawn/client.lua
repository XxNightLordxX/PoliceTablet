-- CP.Spawn (client): what this officer's game can see of the points where a mission's people may appear, for the
-- server's spawn director (Config.Spawning.preferHidden; modules/runs/server.lua Runs.choosePoints), and whether the
-- ground at a point is fit to put a person, a vehicle or an object on (Config.Spawning.ground).

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
