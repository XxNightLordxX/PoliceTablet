-- Armored Truck Escort through the spawn director (Config.Spawning, PLAN S14) on the real engine, the real block and

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
H.load('modules/spawn/server.lua')
H.load('blocks/escort/server.lua')

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = U.deepcopy(v) end
end
H.eq(cfg.ambushAheadOnly, true, 'an ambush car never appears next to or behind the truck (shipped on)')
H.eq(cfg.vehicleLift, 0.5, 'the truck and the ambush cars are made 0.5 m over the road')

-- ============================================================================
--                              CONSOLE, WARNINGS
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    if line:find('^  FAIL ') then realPrint(line) end
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end
local realWarn = CP.warn
local warns = {}
CP.warn = function(tag, fmt, ...)
    local ok, text = pcall(string.format, fmt, ...)
    warns[#warns + 1] = { tag = tag, text = ok and text or fmt }
    return realWarn(tag, fmt, ...)
end
local function WarnsWith(text)
    local out = {}
    for _, w in ipairs(warns) do if w.text:find(text, 1, true) then out[#out + 1] = w end end
    return out
end

-- HUD messages of the run containing text (crimson-police:client:hud to the participants).
local function HudWith(run, text)
    local n = 0
    for _, e in ipairs(H.findEvents('crimson-police:client:hud')) do
        local patch = e.args[2]
        if e.args[1] == run.id and type(patch) == 'table' and type(patch.message) == 'table'
            and tostring(patch.message.text):find(text, 1, true) then
            n = n + 1
        end
    end
    return n
end

local function D2(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function D3(a, b) return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2) end
local function Secs(n) W.tick(n) end
local function Place(src, x, y, z) W.place(src, x, y, z or 30.0) end
local function Me(src) return H.players[src].coords end
local function EndRun(run)
    if run.state ~= 'ended' then CP.Runs.endRun(run, 'failed', 'test') end
    Secs(1)
end

-- A car of somebody else (an officer's own, a parked one) the server knows: GetAllVehicles lists it.
local otherNet = 90000
local others = {}
local function OtherCar(x, y, z)
    otherNet = otherNet + 1
    local e = H.entity(otherNet, { kind = 'vehicle', model = 'police', coords = vec3(x, y, z), exists = true })
    others[#others + 1] = e
    return e
end
local function ClearOthers()
    for _, e in ipairs(others) do e.exists = false end
    others = {}
end

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

-- A straight road east along y = 7000 from x = 7000 to x = 8500 (a waypoint every 100 m), climbing 5 m every 100 m;
-- the depot (start) on its first point.
local function RoadZ(x) return 20.0 + (x - 7000.0) * 0.05 end

local function Road(ambush)
    local pts = {}
    for i = 0, 15 do
        local x = 7000.0 + i * 100.0
        pts[#pts + 1] = vec3(x, 7000.0, RoadZ(x))
    end
    return {
        label = 'East road',
        start = { coords = vec3(7000.0, 7000.0, 20.0), radius = 50.0 },
        route = { points = pts },
        ambushPoints = { ambush or vec4(7600.0, 7000.0, RoadZ(7600.0), 270.0) },
    }
end

local function Escort(extra)
    local o = {
        block = 'escort',
        label = 'Escort the armored truck',
        minSeconds = 0,
        route = 'route',
        vehicle = 'stockade',
        speed = 60,
        style = 'normal',
        toughness = 1.5,
        stoppedFail = 120,
        arrival = 20.0,
        ambushPoints = 'ambushPoints',
        ambush = {
            waves = 1,
            carsPerWave = 2,
            perCar = 1,
            models = { 'sultan' },
            weapons = { 'WEAPON_PISTOL' },
            accuracy = 25,
            armour = 0,
        },
        clearRadius = 100.0,
    }
    for k, v in pairs(extra or {}) do o[k] = v end
    return o
end

local function Mission(loc) return W.mission({ Escort() }, loc or Road()) end

local function State(run) return run.objectives[1] and run.objectives[1].state end

-- The truck: { netId, at, bag } or nil while it is not made.
local function Truck(run)
    local st = State(run)
    local tr = st and st.truck
    if not tr or not tr.netId then return nil end
    local e = run.entities[tr.netId]
    return { netId = tr.netId, at = W.at(run, tr.netId), bag = e and W.bags[e.entity] and W.bags[e.entity].cp }
end

-- The ambush cars in the order they were made: { netId, at }.
local function Cars(run)
    local st = State(run)
    local out = {}
    for _, w in ipairs(st and st.waves or {}) do
        for _, key in ipairs(w.cars) do
            local car = st.cars[key]
            out[#out + 1] = { netId = car.netId, at = W.at(run, car.netId) or car.coords }
        end
    end
    return out
end

-- Drive the truck east to x in 15 m steps (one a second, 54 km/h), officer 1 beside it (10 m off the road) and, with
-- lead, officer 2 on the road lead metres ahead of it. Stops early once until(run) is true (checked after each
-- second).
local function Drive(run, x, lead, until_)
    local tr = Truck(run)
    local m = W.model(run, tr.netId)
    local cx = m.coords.x
    while cx < x do
        cx = math.min(x, cx + 15.0)
        m.coords = vec3(cx, 7000.0, RoadZ(cx) + 0.5)
        m.speed = 15.0
        Place(1, cx, 7010.0, RoadZ(cx) + 1.0)
        if lead then Place(2, cx + lead, 7000.0, RoadZ(cx + lead) + 1.0) end
        Secs(1)
        if run.state == 'ended' or (until_ and until_(run)) then return end
    end
end

local function TwoCars(run) return #Cars(run) >= 2 end

-- ============================================================================
--                   1. THE TRUCK NEVER APPEARS INSIDE A CAR
-- ============================================================================

do
    -- the a1 case: an officer's car parked on the depot marker when the run starts
    Reset()
    warns, lines = {}, {}
    Place(1, 7000.0, 7012.0, 21.0)
    local parked = OtherCar(7002.0, 7001.0, 20.3)
    local run = W.start({ 1 }, Mission())
    Secs(3)
    H.eq(Truck(run), nil, 'a car parked on the start: the truck is not made inside it')
    H.eq(run.state, 'in_progress', 'the run goes on (the truck waits, nothing fails)')
    H.eq(HudWith(run, 'Keep the start clear'), 1, 'the officers are asked once to clear the start')
    H.eq(#LinesWith('the truck waits: a vehicle within 6 m of its spot (route[1])'), 1, 'the console says why it waits')
    -- the officer drives his car off the marker: the truck appears on its own spot
    parked.coords = vec3(7040.0, 7030.0, 22.0)
    Secs(1)
    local t = Truck(run)
    H.ok(t ~= nil, 'the start is clear: the truck appears')
    H.near(t and t.at.x or 0, 7000.0, 0.01, 'on the route\'s first point (the depot)')
    H.near(t and t.at.y or 0, 7000.0, 0.01, 'on the road')
    H.near(t and t.at.z or 0, 20.5, 0.001, 'vehicleLift (0.5 m) over the road: never inside the road surface')
    H.near(W.model(run, t.netId).heading, 270.0, 0.01, 'facing the second waypoint (east)')
    H.ok(t and t.bag and t.bag.place and math.abs(t.bag.place.z - 20.5) < 0.001,
        'it waits frozen for an officer\'s game to put it on its wheels there (the placer)')
    H.eq(#WarnsWith('stood on the truck\'s spot'), 0, 'no warning: it used its own spot')
    EndRun(run)
    ClearOthers()
end

do
    -- an officer on foot on the marker: the truck waits too, until he steps off it
    Reset()
    Place(1, 7001.0, 7002.0, 21.0)
    local run = W.start({ 1 }, Mission())
    Secs(2)
    H.eq(Truck(run), nil, 'an officer standing on the start: the truck is not made on him')
    Place(1, 7000.0, 7015.0, 21.0)
    Secs(1)
    local t = Truck(run)
    H.near(t and t.at.x or 0, 7000.0, 0.01, 'he steps off: the truck appears on its spot')
    EndRun(run)
end

do
    -- the car stays on the marker: after waveDelayMax (20 s) the truck takes the first free spot further along the
    -- route, never inside the car, with one warning
    Reset()
    warns = {}
    Place(1, 7000.0, 7012.0, 21.0)
    local parked = OtherCar(7002.0, 7001.0, 20.3)
    local run = W.start({ 1 }, Mission())
    Secs(18)
    H.eq(Truck(run), nil, 'the car stays for 18 s: the truck still waits')
    Secs(4)
    local t = Truck(run)
    H.ok(t ~= nil, 'after waveDelayMax it appears anyway')
    H.near(t and t.at.x or 0, 7010.0, 0.01, 'on the first free spot, 10 m along the route')
    H.near(t and t.at.y or 0, 7000.0, 0.01, 'on the road')
    H.near(t and t.at.z or 0, RoadZ(7010.0) + 0.5, 0.001, 'at the route\'s height there plus vehicleLift')
    H.ok(t and D3(t.at, parked.coords) > 6.0, 'never within 6 m of the parked car')
    H.eq(#WarnsWith('stood on the truck\'s spot (route[1])'), 1, 'one warning naming where it was made instead')
    H.eq(#WarnsWith('10 m along the route'), 1, 'the warning names the spot')
    EndRun(run)
    ClearOthers()

    -- every spot taken (a row of cars along the depot's first 40 m): it keeps waiting, never inside one
    Reset()
    Place(1, 7000.0, 7012.0, 21.0)
    for x = 7000.0, 7040.0, 10.0 do OtherCar(x + 1.0, 7000.0, RoadZ(x) + 0.3) end
    run = W.start({ 1 }, Mission())
    Secs(30)
    H.eq(Truck(run), nil, 'every spot along the depot taken: the truck waits, never inside a car')
    EndRun(run)
    ClearOthers()
end

do
    -- enabled = false: on the route's first point at the road's height at once, as before (even with the car there)
    Reset()
    cfg.enabled = false
    Place(1, 7000.0, 7012.0, 21.0)
    OtherCar(7002.0, 7001.0, 20.3)
    local run = W.start({ 1 }, Mission())
    local t = Truck(run)
    H.near(t and t.at.x or 0, 7000.0, 0.01, 'enabled = false: on the route\'s first point at once, as before')
    H.near(t and t.at.z or 0, 20.0, 0.001, 'enabled = false: at the road\'s own height, as before')
    EndRun(run)
    ClearOthers()
end

-- ============================================================================
--                2. THE AMBUSH CARS: ON THE ROAD, AT ITS HEIGHT
-- ============================================================================

do
    Reset()
    lines = {}
    Place(1, 7000.0, 7012.0, 21.0)
    local run = W.start({ 1 }, Mission())
    Secs(1)
    Drive(run, 7600.0, nil, TwoCars)
    local cars = Cars(run)
    H.eq(#cars, 2, 'the wave triggers and both cars appear')
    local c1, c2 = cars[1] and cars[1].at, cars[2] and cars[2].at
    H.near(c1 and c1.x or 0, 7600.0, 0.01, 'car 1 on its own slot: the ambush point')
    H.near(c1 and c1.y or 0, 6995.5, 0.01, 'car 1 4.5 m right of the road\'s centre')
    H.near(c1 and c1.z or 0, RoadZ(7600.0) + 0.5, 0.001, 'car 1 at the route\'s height plus vehicleLift')
    H.near(c2 and c2.x or 0, 7607.0, 0.01, 'car 2 7 m further along')
    H.near(c2 and c2.z or 0, RoadZ(7607.0) + 0.5, 0.001,
        'car 2 at the route\'s height where it stands (35 cm higher up the slope): not one height for every car')
    H.ok(c1 and D2(c1, Me(1)) >= 40.0, 'never within minDistance of the officer')
    H.eq(#LinesWith('wave 1 car 1 at ambushPoints[1]'), 1, 'the console names the slot it used')
    EndRun(run)
end

-- ============================================================================
--            3. NEVER NEXT TO AN OFFICER, ANOTHER CAR, OR THE TRUCK
-- ============================================================================
-- AMBUSHAHEADONLY.

do
    -- the owner's check: a lead car 90 m ahead of the truck is 15-30 m from the cars' own slots when the wave
    -- triggers: they slide further along the route, ahead of him
    Reset()
    lines = {}
    Place(1, 7000.0, 7012.0, 21.0)
    Place(2, 7000.0, 7020.0, 21.0)
    local run = W.start({ 1, 2 }, Mission())
    Secs(1)
    Drive(run, 7600.0, 90.0, TwoCars)
    local cars = Cars(run)
    H.eq(#cars, 2, 'the wave appears')
    for i, c in ipairs(cars) do
        H.ok(D2(c.at, Me(1)) >= 40.0 and D2(c.at, Me(2)) >= 40.0,
            ('car %d is 40 m or more from both officers (the lead car included)'):format(i))
        H.ok(c.at.x > Me(2).x + 30.0, ('car %d is ahead of the lead car'):format(i))
        H.near(c.at.z, RoadZ(c.at.x) + 0.5, 0.001, ('car %d at the route\'s height there plus vehicleLift'):format(i))
    end
    H.ok(cars[1] and math.abs(cars[1].at.y - 6995.5) < 0.01 and cars[2] and math.abs(cars[2].at.y - 7004.5) < 0.01,
        'still 4.5 m either side of the road')
    H.ok(#LinesWith('wave 1 car 1 at ambushPoints[1] skipped') >= 1, 'the console says why the own slot was skipped')
    EndRun(run)
end

do
    -- another vehicle (parked, passing) on car 1's own slot: car 1 takes the next slot along the route
    Reset()
    Place(1, 7000.0, 7012.0, 21.0)
    local parked = OtherCar(7600.5, 6995.0, RoadZ(7600.0) + 0.3)
    local run = W.start({ 1 }, Mission())
    Secs(1)
    Drive(run, 7600.0, nil, TwoCars)
    local cars = Cars(run)
    H.ok(cars[1] and D3(cars[1].at, parked.coords) > 4.0, 'car 1 never appears inside the parked car')
    H.near(cars[1] and cars[1].at.x or 0, 7615.0, 0.01, 'car 1 on the next slot, 15 m further along the route')
    H.ok(cars[2] and cars[2].at.x >= 7615.0, 'car 2 follows it (the wave stays together)')
    EndRun(run)
    ClearOthers()
end

-- An ambush point 130 m off the route (the builder allows 150 m): the truck never comes within 120 m of it, so the
-- wave triggers once the truck is past it (the a1 case: "the wave spawns at the point now BEHIND the truck").
local OFF = vec4(7600.0, 7130.0, RoadZ(7600.0), 270.0)
local function Past(run)
    local st = State(run)
    return st and st.waves[1] and st.waves[1].triggered == true
end

do
    Reset()
    Place(1, 7000.0, 7012.0, 21.0)
    local run = W.start({ 1 }, Mission(Road(OFF)))
    Secs(1)
    Drive(run, 7800.0, nil, Past)
    local tx = W.model(run, Truck(run).netId).coords.x
    H.ok(tx >= 7680.0, 'the wave triggered once the truck was past its point')
    Secs(1)
    local cars = Cars(run)
    H.eq(#cars, 2, 'both cars appear')
    for i, c in ipairs(cars) do
        H.ok(c.at.x >= tx + 40.0, ('car %d appears ahead of the truck, never behind it'):format(i))
        H.ok(math.abs(c.at.y - 7000.0) <= 4.6, ('car %d on the route itself'):format(i))
    end
    -- the truck at 7690 m: the first 15 m mark from the car's own slot (the point's 7600 m) 100 m or more ahead of it
    H.near(cars[1] and cars[1].at.x or 0, 7795.0, 0.01,
        'car 1 on the first 15 m mark of its slots 100 m or more ahead of the truck (100-115 m)')
    EndRun(run)

    -- ambushAheadOnly = false: at the point, behind the truck, as before
    Reset()
    cfg.ambushAheadOnly = false
    Place(1, 7000.0, 7012.0, 21.0)
    run = W.start({ 1 }, Mission(Road(OFF)))
    Secs(1)
    Drive(run, 7800.0, nil, Past)
    Secs(1)
    cars = Cars(run)
    H.near(cars[1] and cars[1].at.x or 0, 7600.0, 0.01, 'ambushAheadOnly = false: at the ambush point, as before')
    H.near(cars[1] and cars[1].at.y or 0, 7125.5, 0.01, 'ambushAheadOnly = false: beside the point, as before')
    EndRun(run)
end

do
    -- enabled = false: the cars on their slots at once, the point's height + 0.5 m for every car, as before
    Reset()
    cfg.enabled = false
    Place(1, 7000.0, 7012.0, 21.0)
    Place(2, 7000.0, 7020.0, 21.0)
    local run = W.start({ 1, 2 }, Mission())
    Secs(1)
    Drive(run, 7600.0, 90.0, TwoCars)
    local cars = Cars(run)
    H.near(cars[1] and cars[1].at.x or 0, 7600.0, 0.01, 'enabled = false: car 1 at the ambush point, as before')
    H.near(cars[2] and cars[2].at.z or 0, RoadZ(7600.0) + 0.5, 0.001,
        'enabled = false: every car at the point\'s height + 0.5 m, as before')
    EndRun(run)
end

-- ============================================================================
--              4. A WAVE WITH NO SLOT LEFT WHEN THE TRUCK ARRIVES
-- ============================================================================

do
    -- an ambush point 40 m before the destination, an officer waiting on the road beside it: every slot up to the
    -- route's end is within 40 m of him, so no car appears; the truck arrives within 20 s and the wave is left out,
    -- so the escort can end
    Reset()
    warns = {}
    Place(1, 7000.0, 7012.0, 21.0)
    Place(2, 8470.0, 7000.0, RoadZ(8470.0) + 1.0)
    local run = W.start({ 1, 2 }, Mission(Road(vec4(8460.0, 7000.0, RoadZ(8460.0), 270.0))))
    Secs(1)
    Drive(run, 8325.0)
    local m = W.model(run, Truck(run).netId)
    local x = 8325.0
    local near = false
    while run.state ~= 'ended' and x < 8490.0 do
        x = x + 15.0
        m.coords, m.speed = vec3(x, 7000.0, RoadZ(x) + 0.5), 15.0
        Place(1, x, 7010.0, RoadZ(x) + 1.0)
        Secs(1)
        for _, c in ipairs(Cars(run)) do if D2(c.at, Me(2)) < 40.0 then near = true end end
    end
    H.eq(near, false, 'no ambush car ever appears within 40 m of the officer waiting by the point')
    H.eq(#Cars(run), 0, 'no car at all: every slot up to the route\'s end is too close to him')
    H.eq(#WarnsWith('ambush wave 1 found no slot for 2 of its 2 cars'), 1, 'one warning when the truck arrives')
    H.eq(run.objectives[1].status, 'done', 'the wave is left out and the escort completes')
    EndRun(run)
end

do
    -- a wave the spawn caps hold back until the truck has arrived (Config.Limits.maxArmedAlive 1: wave 1's attacker is
    -- still alive when wave 2 triggers, so wave 2 never asked for a slot): once wave 1 is down, wave 2's car finds no
    -- slot ahead of the truck at the destination and the wave is left out with one warning, so the escort completes
    Reset()
    warns = {}
    local keep = Config.Limits.maxArmedAlive
    Config.Limits.maxArmedAlive = 1
    Place(1, 7000.0, 7012.0, 21.0)
    local loc = Road()
    loc.ambushPoints = { vec4(7600.0, 7000.0, RoadZ(7600.0), 270.0), vec4(8200.0, 7000.0, RoadZ(8200.0), 270.0) }
    local ambush = {
        waves = 2,
        carsPerWave = 1,
        perCar = 1,
        models = { 'sultan' },
        weapons = { 'WEAPON_PISTOL' },
        accuracy = 25,
        armour = 0,
    }
    local run = W.start({ 1 }, W.mission({ Escort({ ambush = ambush }) }, loc))
    Secs(1)
    Drive(run, 8490.0)
    local st = State(run)
    H.eq(st.truck.arrived, true, 'the truck arrives')
    H.eq(#st.waves[1].cars, 1, 'wave 1 appeared')
    H.eq(st.waves[2].triggered and #st.waves[2].cars, 0, 'wave 2 triggered, held back by maxArmedAlive')
    H.eq(st.waves[2].noSlot, nil, 'it never asked for a slot (the caps refused first)')
    H.eq(#WarnsWith('ambush wave 2'), 0, 'no warning yet: wave 2 was not waiting for a slot at the arrival')
    for _, p in pairs(st.peds) do
        if p.wave == 1 then CP.Runs.entityDied(run, p.netId, 1) end
    end
    Secs(2)
    H.eq(#Cars(run), 1, 'the caps free up: wave 2 finds no slot ahead of the truck at the destination (no car)')
    H.eq(st.waves[2].dropped, true, 'wave 2 is left out')
    H.eq(#WarnsWith('ambush wave 2 found no slot for 1 of its 1 cars and the truck has arrived; it is left out'), 1,
        'one warning')
    H.eq(run.objectives[1].status, 'done', 'the escort completes')
    Secs(3)
    H.eq(#WarnsWith('ambush wave 2'), 1, 'still one warning')
    EndRun(run)
    Config.Limits.maxArmedAlive = keep
end

-- ============================================================================
--                         5. ONE CONSOLE LINE PER SLOT
-- ============================================================================

-- The console lines of skipped slots of wave 1 car 1 (the director says each slot, reason and wave once).
local function Skipped()
    local n = 0
    for _, l in ipairs(lines) do
        if l:find('wave 1 car 1 ', 1, true) and l:find(' skipped: ', 1, true) then n = n + 1 end
    end
    return n
end

do
    -- the truck past the point of a wave whose slots ahead of it are all within 40 m of an officer (two officers
    -- waiting on the road near the destination): the car waits while the truck drives on 10 m a second. Its slots
    -- start on the first 15 m mark 100 m or more ahead of the truck, so each keeps its name and the console names
    -- each once, not a new line for every slot every second
    Reset()
    Place(1, 7000.0, 7012.0, 21.0)
    Place(2, 8420.0, 7000.0, RoadZ(8420.0) + 1.0)
    Place(3, 8480.0, 7000.0, RoadZ(8480.0) + 1.0)
    local run = W.start({ 1, 2, 3 }, Mission(Road(vec4(8200.0, 7130.0, RoadZ(8200.0), 270.0))))
    Secs(1)
    Drive(run, 8290.0, nil, Past)
    H.ok(Past(run), 'the wave triggered once the truck was past its point')
    local m = W.model(run, Truck(run).netId)
    local x, counts = 8290.0, {}
    lines = {}
    for i = 1, 8 do
        x = x + 10.0
        m.coords, m.speed = vec3(x, 7000.0, RoadZ(x) + 0.5), 10.0
        Place(1, x, 7010.0, RoadZ(x) + 1.0)
        Secs(1)
        counts[i] = Skipped()
    end
    H.eq(#Cars(run), 0, 'every slot ahead of the truck is within 40 m of an officer: the car waits')
    H.ok(counts[1] >= 1, 'the console says why its slots were skipped')
    H.eq(counts[8], counts[1], 'no new console line while the truck drives on: each slot keeps its name')
    EndRun(run)
end

_G.print = realPrint
CP.warn = realWarn
return H
