-- CP.Spawn.visible and the ox_lib callback crimson-police:client:spawn:visible (modules/spawn/client.lua; PLAN S5):
-- what an officer's game can see of the points the server's spawn director may use, from line-of-sight probes run
-- the way the game runs them (asynchronous, a handle polled each frame until it is done).

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                      THE GAME: PED, CAMERA, SHAPE TESTS
-- ============================================================================

local PED, CAR = 4242, 777
local world = {
    head = vec3(0.0, 0.0, 31.6),   -- the officer's head bone
    cam = vec3(0.0, -3.0, 32.5),   -- the third-person camera behind and above him
    inCar = false,
    blocked = function()
        return false
    end,                                      -- (from, to) -> the line hits something
    pollsToFinish = 1,                        -- frames a probe takes
    stuck = false,                            -- probes never finish
    failStart = function()
        return false
    end, -- (to) -> StartShapeTestLosProbe answers 0
    invalid = function()
        return false
    end,                                      -- (to) -> GetShapeTestResult answers 0
    hitAs = 1,                                -- how the game hands the hit BOOL back (1 or true)
}
local probes, byHandle, nextHandle, running, maxRunning = {}, {}, 100, 0, 0

_G.PlayerPedId = function() return PED end
_G.GetPedBoneCoords = function(ped, bone, ox, oy, oz)
    world.boneArgs = { ped = ped, bone = bone, ox = ox, oy = oy, oz = oz }
    return world.head
end
_G.GetFinalRenderedCamCoord = function() return world.cam end
_G.GetVehiclePedIsIn = function(ped, last)
    world.vehArgs = { ped = ped, last = last }
    return world.inCar and CAR or 0
end
_G.StartShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2, flags, ignore, options)
    local to = vec3(x2, y2, z2)
    if world.failStart(to) then return 0 end
    nextHandle = nextHandle + 1
    local p = {
        handle = nextHandle,
        from = vec3(x1, y1, z1),
        to = to,
        flags = flags,
        ignore = ignore,
        options = options,
        polls = 0,
        done = false,
    }
    byHandle[nextHandle] = p
    probes[#probes + 1] = p
    running = running + 1
    if running > maxRunning then maxRunning = running end
    return nextHandle
end
_G.GetShapeTestResult = function(handle)
    local p = byHandle[handle]
    if not p or p.done then return 0, false, vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 0.0), 0 end
    if world.invalid(p.to) then
        p.done = true
        running = running - 1
        return 0, false, vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 0.0), 0
    end
    p.polls = p.polls + 1
    if world.stuck or p.polls < world.pollsToFinish then
        return 1, false, vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 0.0), 0
    end
    p.done = true
    running = running - 1
    local hit = world.blocked(p.from, p.to)
    return 2, hit and world.hitAs or (world.hitAs == 1 and 0 or false), p.to, vec3(0.0, 0.0, 1.0), 0
end

local function ResetGame()
    probes, byHandle, running, maxRunning = {}, {}, 0, 0
    world.inCar, world.stuck, world.pollsToFinish, world.hitAs = false, false, 1, 1
    world.blocked = function() return false end
    world.failStart = function() return false end
    world.invalid = function() return false end
end

H.load('modules/spawn/client.lua')
local CALLBACK = 'crimson-police:client:spawn:visible'
H.ok(type(CP.Spawn) == 'table' and type(CP.Spawn.visible) == 'function', 'CP.Spawn.visible')
H.ok(type(H.callbacks[CALLBACK]) == 'function', 'the ox_lib callback is registered')

-- The server's ask, answered in a thread (ox_lib runs the handler in the callback's event), one frame = 16 ms.
local function Ask(args)
    local res, done = nil, false
    local t0 = H.clockMs
    CreateThread(function()
        res = H.callbacks[CALLBACK](args)
        done = true
    end)
    while not done and H.clockMs - t0 < 20000 do H.step(16) end
    H.ok(done, 'the callback answered')
    return res, H.clockMs - t0
end
local function Pt(x, y, z) return { x = x + 0.0, y = y + 0.0, z = (z or 30.0) + 0.0 } end
local function List(res)
    local out = {}
    for k = 1, #res do out[k] = tostring(res[k]) end
    return table.concat(out, ',')
end

-- ============================================================================
--                        HIDDEN: EVERY LINE IS BLOCKED
-- ============================================================================

do
    ResetGame()
    -- a 2.0 m wall at y = 20 (top at z = 32.0): his head (31.6 m) cannot see over it, the camera (32.5 m) sees over
    -- it to a far point on the same ground; close behind it, or down a slope behind it, nothing can
    world.blocked = function(from, to)
        if to.y <= 20.0 then return false end
        local t = (20.0 - from.y) / (to.y - from.y)
        local z = from.z + (to.z - from.z) * t
        return z < 32.0
    end
    local res, took = Ask({ points = { Pt(0, 10), Pt(0, 22), Pt(0, 200), Pt(0, 60, 20) }, ms = 1250 })
    H.eq(List(res), 'true,false,true,false',
        'in front of the wall seen; close behind it hidden; far behind it the camera sees over; down a slope hidden')
    H.ok(took < 200, 'the probes finish in a few frames (' .. took .. ' ms)')
    -- the probes: from the head and from the camera, to 1.0 and 1.7 m above each point
    H.eq(#probes, 16, 'four probes per point (two eyes, two heights)')
    local p = probes[1]
    H.ok(p.from == world.head and p.to.x == 0.0 and p.to.y == 10.0 and math.abs(p.to.z - 31.0) < 1e-9,
        'the first from his head to the chest height of point 1')
    H.ok(math.abs(probes[2].to.z - 31.7) < 1e-9, 'then the head height')
    H.ok(probes[3].from == world.cam, 'then from the camera')
    H.eq(p.flags, 1 + 2 + 16, 'the map, vehicles and objects block the view (not glass, not peds)')
    H.eq(p.options, 7, 'glass and see-through parts ignored')
    H.eq(p.ignore, PED, 'on foot the probes ignore his own ped')
    H.ok(world.boneArgs.ped == PED and world.boneArgs.bone == 31086, 'his head bone (SKEL_Head)')
    -- in a car: the car is ignored (the line starts inside it)
    ResetGame()
    world.inCar = true
    Ask({ points = { Pt(0, 50) }, ms = 1250 })
    H.eq(probes[1].ignore, CAR, 'in a car the probes ignore the car')
    H.eq(world.vehArgs.last, false, 'the car he is in now')
    -- the game hands the hit back as true instead of 1: the same answer
    ResetGame()
    world.hitAs = true
    world.blocked = function() return true end
    local res2 = Ask({ points = { Pt(0, 50), Pt(0, 60) }, ms = 1250 })
    H.eq(List(res2), 'false,false', 'a hit given as true hides the point too')
    ResetGame()
    world.blocked = function() return true end
    local res3 = Ask({ points = { Pt(0, 50) }, ms = 1250 })
    H.eq(List(res3), 'false', 'a hit given as 1 hides it')
    -- one clear line is enough to see it: only the camera's line to the head height is clear
    world.blocked = function(from, to) return not (from == world.cam and math.abs(to.z - 31.7) < 1e-9) end
    local res4 = Ask({ points = { Pt(0, 50) }, ms = 1250 })
    H.eq(List(res4), 'true', 'one of the four lines clear: seen')
end

-- ============================================================================
--                WHEN IT CANNOT TELL: THE POINT COUNTS AS SEEN
-- ============================================================================

do
    -- probes that never finish: after the server's budget every point is seen, and the game stops waiting
    ResetGame()
    world.stuck = true
    world.blocked = function() return true end
    local res, took = Ask({ points = { Pt(0, 50), Pt(0, 60) }, ms = 400 })
    H.eq(List(res), 'true,true', 'nothing finished in time: seen')
    H.ok(took >= 400 and took < 500, 'answered when the budget ran out (' .. took .. ' ms)')
    -- the probes still running are read a little longer (their handles are freed), then left
    local polls = probes[1].polls
    H.advance(2000, 16)
    H.ok(probes[1].polls > polls, 'a running probe is still read after the answer')
    local after = probes[1].polls
    H.advance(2000, 16)
    H.eq(probes[1].polls, after, 'and no longer than DRAIN_FRAMES')
    -- a probe that finishes after the answer is no longer read
    ResetGame()
    world.pollsToFinish = 3
    world.blocked = function() return true end
    local resLate = Ask({ points = { Pt(0, 50) }, ms = 1250 })
    H.eq(List(resLate), 'false', 'a probe that takes three frames still counts')
    -- a probe that does not start, or an invalid handle, leaves its point seen
    ResetGame()
    world.blocked = function() return true end
    world.failStart = function(to) return to.y == 60.0 and math.abs(to.z - 31.7) < 1e-9 end
    world.invalid = function(to) return to.y == 70.0 end
    local res2 = Ask({ points = { Pt(0, 50), Pt(0, 60), Pt(0, 70) }, ms = 1250 })
    H.eq(List(res2), 'false,true,true', 'one probe that did not start, or an invalid handle: seen')
    -- what is not a point is seen
    ResetGame()
    world.blocked = function() return true end
    local res3 = Ask({ points = { Pt(0, 50), { x = 'a', y = 1, z = 2 }, 'no', { 1.0, 60.0, 30.0 } }, ms = 1250 })
    H.eq(List(res3), 'false,true,true,false', 'bad entries seen; { [1], [2], [3] } is a point')
    -- no camera or head coords from the game: nothing can be probed
    local realHead = world.head
    world.head = nil
    world.cam = { x = 0 / 0, y = 0.0, z = 0.0 }
    local res4 = Ask({ points = { Pt(0, 50) }, ms = 1250 })
    H.eq(List(res4), 'true', 'no eyes: seen')
    world.head, world.cam = realHead, vec3(0.0, -3.0, 32.5)
end

-- ============================================================================
--                         LIMITS: POINTS, PROBES, TIME
-- ============================================================================

do
    ResetGame()
    world.blocked = function() return true end
    local many = {}
    for k = 1, 40 do many[k] = Pt(k, 50) end
    local res = Ask({ points = many, ms = 1250 })
    H.eq(#res, 32, 'at most 32 points are answered (the server sends no more)')
    H.eq(#probes, 32 * 4, 'and probed')
    H.ok(maxRunning <= 16, 'at most 16 probes run at once (' .. maxRunning .. ')')
    -- the server's budget is kept between 50 ms and 5 s
    ResetGame()
    world.stuck = true
    local _, took = Ask({ points = { Pt(0, 50) }, ms = 1 })
    H.ok(took >= 50 and took < 120, 'a budget under 50 ms is 50 ms (' .. took .. ' ms)')
    H.advance(2000, 16)
    local _, took2 = Ask({ points = { Pt(0, 50) }, ms = 999999 })
    H.ok(took2 >= 5000 and took2 < 5100, 'a budget over 5 s is 5 s (' .. took2 .. ' ms)')
    H.advance(2000, 16)
    local _, took3 = Ask({ points = { Pt(0, 50) } })
    H.ok(took3 >= 5000 and took3 < 5100, 'no budget given: 5 s')
    H.advance(2000, 16)
    -- what the server may send that is no ask
    ResetGame()
    H.eq(#H.callbacks[CALLBACK](nil), 0, 'no args: an empty answer')
    H.eq(#H.callbacks[CALLBACK]({ points = 'x' }), 0, 'points that are no list: an empty answer')
    H.eq(#Ask({ points = {} }), 0, 'no points: an empty answer')
end

return H
