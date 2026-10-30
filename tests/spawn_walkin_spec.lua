-- CP.Spawn.walkIn and the ox_lib callback crimson-police:client:spawn:walkIn (modules/spawn/client.lua; PLAN S12):

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                 THE GAME: PED, CAMERA, NAVMESH, SHAPE TESTS
-- ============================================================================

local PED = 4242
local world = {
    me = vec3(0.0, 0.0, 30.0),     -- where the officer stands
    camH = 0.0,                    -- the heading his camera looks along (0 = north, +y)
    navZ = 29.2,                   -- the footpath's height
    nav = function(x, y)
        return true, vec3(x, y, 29.2)
    end, -- (x, y, z) -> found, the navmesh point
    blocked = function()
        return false
    end, -- (from, to) -> the line hits something
}
local navCalls = {}

_G.PlayerPedId = function() return PED end
local realCoords = GetEntityCoords
_G.GetEntityCoords = function(ent)
    if ent == PED then return world.me end
    return realCoords(ent)
end
_G.GetEntityHeading = function() return 0.0 end
_G.GetFinalRenderedCamRot = function(order)
    world.rotOrder = order
    return vec3(0.0, 0.0, world.camH)
end
_G.GetSafeCoordForPed = function(x, y, z, onlyPavement, flags)
    navCalls[#navCalls + 1] = { x = x, y = y, z = z, pavement = onlyPavement, flags = flags }
    return world.nav(x, y, z)
end
_G.GetPedBoneCoords = function() return vec3(world.me.x, world.me.y, world.me.z + 1.6) end
_G.GetFinalRenderedCamCoord = function() return vec3(world.me.x, world.me.y - 3.0, world.me.z + 2.5) end
_G.GetVehiclePedIsIn = function() return 0 end
local probes, nextHandle = {}, 100
_G.StartShapeTestLosProbe = function(x1, y1, z1, x2, y2, z2)
    nextHandle = nextHandle + 1
    probes[nextHandle] = { from = vec3(x1, y1, z1), to = vec3(x2, y2, z2) }
    return nextHandle
end
_G.GetShapeTestResult = function(handle)
    local p = probes[handle]
    if not p or p.done then return 0, false end
    p.done = true
    return 2, world.blocked(p.from, p.to) and 1 or 0, p.to, vec3(0.0, 0.0, 1.0), 0
end

_G.AddStateBagChangeHandler = function() end -- the placer's handler (tests/spawn_placer_spec.lua)
H.load('modules/spawn/client.lua')
local CALLBACK = 'crimson-police:client:spawn:walkIn'
H.ok(type(CP.Spawn.walkIn) == 'function', 'CP.Spawn.walkIn')
H.ok(type(H.callbacks[CALLBACK]) == 'function', 'the ox_lib callback is registered')

-- The server's ask, answered in a thread (ox_lib runs the handler in the callback's event).
local function Ask(args)
    local res, done = nil, false
    local t0 = H.clockMs
    CreateThread(function()
        res = H.callbacks[CALLBACK](args)
        done = true
    end)
    while not done and H.clockMs - t0 < 20000 do H.step(16) end
    H.ok(done, 'the callback answered')
    return res
end
local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
-- degrees between his view (camH) and the line from him to p
local function OffView(p)
    local r = math.rad(world.camH)
    local fx, fy = -math.sin(r), math.cos(r)
    local vx, vy = p.x - world.me.x, p.y - world.me.y
    local l = math.sqrt(vx * vx + vy * vy)
    return math.deg(math.acos(math.max(-1, math.min(1, (vx * fx + vy * fy) / l))))
end

-- ============================================================================
--           THE OFFICER AT THE CAR, LOOKING ALONG THE STREET (NORTH)
-- ============================================================================

do
    -- he stands 3 m south of the car, looking north; a wall east of x = 10 hides everything beyond it
    local car = { x = 0.0, y = 3.0, z = 30.0 }
    world.blocked = function(_, to) return to.x > 10.0 end
    local res = Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 })
    H.eq(#res, 8, 'eight points at most')
    H.eq(world.rotOrder, 2, 'his camera\'s heading (rotation order 2)')
    local call = navCalls[1]
    H.ok(call and call.flags == 4 + 8 and call.pavement == false,
        'the navmesh without a building\'s inside and without water (GSC_FLAG_NOT_INTERIOR | GSC_FLAG_NOT_WATER)')
    H.ok(call and math.abs(call.z - 31.0) < 1e-9, 'looked for from 1 m over the car\'s point')
    H.ok(call and math.abs(call.x) < 1e-9 and math.abs(call.y - 28.0) < 1e-9, 'first straight ahead, 25 m on')
    local ok, hiddenFirst, seenAfter = true, true, false
    for _, p in ipairs(res) do
        local dc, dm = D2(p, car), D2(p, world.me)
        if dc < 25.0 - 1e-6 or dc > 40.0 + 1e-6 or dm < 25.0 or OffView(p) > 90.0 then ok = false end
        if math.abs(p.z - (world.navZ + 1.0)) > 1e-6 then ok = false end
        if p.hidden == false then seenAfter = true elseif seenAfter then hiddenFirst = false end
    end
    H.ok(ok, 'every point 25-40 m from the car, 25 m or more from him, in front of him, 1 m over the footpath')
    H.ok(res[1].hidden == true and res[1].x > 10.0, 'the ones behind the wall (out of his sight) come first')
    H.ok(hiddenFirst, 'then the ones he can see')
end

-- ============================================================================
--                   WHAT THE NAVMESH GIVES THAT DOES NOT FIT
-- ============================================================================

do
    navCalls = {}
    world.blocked = function() return false end
    local car = { x = 0.0, y = 3.0, z = 30.0 }
    -- the navmesh snaps every point to 5 m from the car (a yard): nothing fits the ring
    world.nav = function(x, y)
        local dx, dy = x - car.x, y - car.y
        local l = math.sqrt(dx * dx + dy * dy)
        return true, vec3(car.x + dx / l * 5.0, car.y + dy / l * 5.0, world.navZ)
    end
    H.eq(#Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 }), 0, 'a footpath only 5 m from the car: no point')
    -- no navmesh there at all (found = false, or 0 the way a BOOL may come back)
    world.nav = function() return false, vec3(0.0, 0.0, 0.0) end
    H.eq(#Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 }), 0,
        'no navmesh: an empty answer (the server uses the ring)')
    world.nav = function(x, y) return 1, vec3(x, y, world.navZ) end
    H.ok(#Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 }) > 0, 'found given as 1: points')
    -- the same footpath point for every look: one point, not eight copies
    world.nav = function() return true, vec3(0.0, 33.0, world.navZ) end
    H.eq(#Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 }), 1, 'one footpath point is answered once')
    world.nav = function(x, y) return true, vec3(x, y, world.navZ) end
end

-- ============================================================================
--                  HE TURNS ROUND: THE POINTS FOLLOW HIS VIEW
-- ============================================================================

do
    -- he stands north of the car and looks south across it: the points lie south of the car, none within 25 m of
    -- him (25 m straight ahead of the car is 22 m from him)
    world.me = vec3(0.0, 3.0, 30.0)
    world.camH = 180.0
    local car = { x = 0.0, y = 0.0, z = 30.0 }
    local res = Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 })
    local south = #res > 0
    for _, p in ipairs(res) do
        if p.y >= 0.0 or D2(p, world.me) < 25.0 then south = false end
    end
    H.ok(south, 'looking south: every point south of the car, 25 m or more from him')
    -- he has walked 30 m past the car and still looks north: what lies round the car is behind him or too close
    world.me = vec3(0.0, 30.0, 30.0)
    world.camH = 0.0
    local res2 = Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 })
    local front = true
    for _, p in ipairs(res2) do
        if OffView(p) > 90.0 or D2(p, world.me) < 25.0 then front = false end
    end
    H.ok(front, 'past the car: never a point behind him or beside him')
    world.me = vec3(0.0, 0.0, 30.0)
end

-- ============================================================================
--                               THE SERVER'S ASK
-- ============================================================================

do
    local car = { x = 0.0, y = 3.0, z = 30.0 }
    -- the ring is kept within 5-100 m
    navCalls = {}
    Ask({ car = car, ring = { 1.0, 500.0 }, ms = 1250 })
    H.ok(navCalls[1] and math.abs(navCalls[1].y - 8.0) < 1e-9, 'a ring under 5 m starts at 5 m')
    local far = 0
    for _, c in ipairs(navCalls) do far = math.max(far, D2(c, car)) end
    H.ok(math.abs(far - 100.0) < 1e-6, 'and ends at 100 m at most')
    H.eq(#H.callbacks[CALLBACK](nil), 0, 'no args: an empty answer')
    H.eq(#Ask({ car = 'x', ring = { 25.0, 40.0 } }), 0, 'a car that is no point: an empty answer')
    H.eq(#Ask({ car = car }), 0, 'no ring: an empty answer')
    -- a navmesh call that fails is said and answered empty
    world.nav = function() error('boom') end
    H.eq(#Ask({ car = car, ring = { 25.0, 40.0 }, ms = 1250 }), 0, 'a failure: an empty answer')
end

return H
