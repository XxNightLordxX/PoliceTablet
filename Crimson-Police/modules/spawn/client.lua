-- CP.Spawn (client): what this officer's game can see of the points where a mission's people may appear, for the
-- server's spawn director (Config.Spawning.preferHidden; modules/runs/server.lua Runs.choosePoints).

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
