-- Loops run less often (docs/dev/LOOPS.md): CP.Perf scales the idle and far waits by
-- Config.Performance.loopScale (1-4) and never a per-frame wait; the slower shipped intervals; the NUI's shortest
-- screen poll.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- natives these loops do not need answer nil (FXServer would answer)
local function Nop() return nil end
H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^[A-Z]') then return Nop end
    return nil
end)
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.LocalPlayer = { state = {} }

-- every Wait of the resource's own files: { file, ms }
local waits = {}
local realWait = _G.Wait
_G.Wait = function(ms)
    local info = debug.getinfo(2, 'S')
    local file = info.short_src:match('Crimson%-Police/(.*)$')
    if file then waits[#waits + 1] = { file = file, ms = ms or 0 } end
    return realWait(ms)
end
_G.Citizen.Wait = _G.Wait

local function WaitsOf(file)
    local out = {}
    for _, w in ipairs(waits) do
        if w.file == file then out[#out + 1] = w.ms end
    end
    return out
end

-- ============================================================================
--                                   CP.PERF
-- ============================================================================

H.eq(Config.Performance and Config.Performance.loopScale, 1.0, 'Config.Performance.loopScale ships 1 (today\'s pace)')
H.eq(CP.Perf.scale(), 1, 'scale 1 as shipped')
H.eq(CP.Perf.ms(1500), 1500, 'scale 1: a far wait is unchanged')
H.eq(CP.Perf.ms(0), 0, 'a per-frame wait stays per frame')
Config.Performance.loopScale = 2
H.eq(CP.Perf.ms(1000), 2000, 'scale 2: half as often')
H.eq(CP.Perf.ms(0), 0, 'scale 2: a per-frame wait still per frame')
Config.Performance.loopScale = 2.5
H.eq(CP.Perf.ms(333), 833, 'a fraction rounds to whole milliseconds')
H.eq(math.type(CP.Perf.ms(333)), 'integer', 'an integer for Wait')
Config.Performance.loopScale = 9
H.eq(CP.Perf.scale(), 4, 'above 4: 4')
Config.Performance.loopScale = 0.1
H.eq(CP.Perf.scale(), 1, 'under 1: 1 (never faster than shipped)')
Config.Performance.loopScale = 'fast'
H.eq(CP.Perf.scale(), 1, 'not a number: 1')
Config.Performance.loopScale = 0 / 0
H.eq(CP.Perf.scale(), 1, 'NaN: 1')
local saved = Config.Performance
Config.Performance = nil
H.eq(CP.Perf.ms(2000), 2000, 'an older config.lua without the section: shipped pace')
Config.Performance = saved
Config.Performance.loopScale = 1.0

-- ============================================================================
--                    A REAL LOOP: SHIPPED PACE, THEN SCALED
-- ============================================================================
-- CP.NpcCombat's run watcher (re-applies the NPC damage values): 1000 ms before step LP2, 2000 ms now, 4000 ms at
-- loopScale 2.

H.load('modules/npc/client/npccombat.lua')
H.step(0)
waits = {}
CP.NpcCombat.start('lp2-run')
H.advance(8000, 250)
local list = WaitsOf('modules/npc/client/npccombat.lua')
H.ok(#list >= 3, ('the watcher ran (%d waits)'):format(#list))
local allTwo = #list > 0
for _, ms in ipairs(list) do if ms ~= 2000 then allTwo = false end end
H.ok(allTwo, 'the run watcher wakes every 2 s (was 1 s): ' .. table.concat(list, ','))
H.ok(#list <= 5, ('8 s of a run: at most 5 passes, not 8 (%d)'):format(#list))

Config.Performance.loopScale = 2
H.advance(4000, 250)   -- the pass already waiting ends at its old pace
waits = {}
H.advance(16000, 250)
list = WaitsOf('modules/npc/client/npccombat.lua')
local allFour = #list > 0
for _, ms in ipairs(list) do if ms ~= 4000 then allFour = false end end
H.ok(allFour, 'loopScale 2: every 4 s: ' .. table.concat(list, ','))
H.ok(#list >= 3 and #list <= 5, ('16 s at loopScale 2: about 4 passes (%d)'):format(#list))
CP.NpcCombat.stop()
H.advance(5000, 250)
Config.Performance.loopScale = 1.0

-- ============================================================================
--                    SHIPPED INTERVALS (docs/dev/LOOPS.md)
-- ============================================================================
-- The idle and far waits the owner asked to be slower, read from the files (before -> after in docs/dev/LOOPS.md).

local function Read(rel)
    local f = assert(io.open(H.root .. rel, 'r'))
    local s = f:read('a')
    f:close()
    return s
end
local function Has(rel, needle, msg)
    H.ok(Read(rel):find(needle, 1, true) ~= nil, msg .. ' (' .. rel .. ')')
end

Has('modules/access/client/tablet.lua', 'local DESK_WATCH_MS = 1000', 'walk-away close checked every 1 s')
Has('modules/access/client/tablet.lua', 'local DOWN_WATCH_MS = 1000', 'downed check every 1 s')
Has('modules/access/client/tablet.lua', 'local ITEM_WATCH_MS = 2000', 'tablet item check every 2 s')
Has('modules/access/client/tablet.lua', 'local ANIM_WATCH_MS = 2000', 'tablet animation kept every 2 s')
Has('modules/map/client/markers.lua', 'local TICK_MS = 2000', 'objective pointer every 2 s')
Has('modules/runs/client/runs.lua', 'local TELEMETRY_MS = 2000', 'run telemetry every 2 s')
Has('modules/runs/client/runs.lua', 'local UNARMED_MS = 1000', 'unarmed weapon check every 1 s')
Has('modules/npc/client/npc.lua', 'local LOOP_MS = 1000', 'NPC retask every 1 s')
Has('modules/npc/client/npc.lua', 'local GOVERN_MS = 2000', 'NPC combat governor every 2 s')
Has('modules/dispatch/alerts.lua', 'local RECONCILE_MS = 2000', 'crimsonArena flag reconcile every 2 s')
Has('modules/review/anticheat.lua', 'local TICK_MS = 2000', 'anticheat pass every 2 s')
Has('modules/teams/operations.lua', 'local TICK_IDLE_MS = 10000', 'no operation: every 10 s')
Has('modules/teams/units.lua', 'local SWEEP_MS = 5000', 'unit invite sweep every 5 s')
Has('modules/system/schedule.lua', 'local CHECK_EVERY_MS = 60000', 'daily boundary check every 60 s')
Has('modules/supervisor/happyhour.lua', 'local TICK_MS = 30000', 'happy hour end check every 30 s')
for _, rel in ipairs({
    'blocks/escort/client.lua',
    'blocks/flee_arrest/client.lua',
    'blocks/process_scene/client.lua',
    'blocks/protect_rescue/client.lua',
    'blocks/search_area/client.lua',
    'blocks/interact_points/client.lua',
    'blocks/skill_check/client.lua',
}) do
    Has(rel, 'local MARKER_FAR_MS = 1500', 'block markers far away every 1.5 s')
    Has(rel, 'CP.Perf.ms(MARKER_FAR_MS)', 'the far marker wait is scaled')
end
-- per frame stays per frame: the armed shooting check and the in-range markers never go through CP.Perf
Has('modules/runs/client/runs.lua', 'if IsPedArmed(ped, 6) then\n                Wait(0)',
    'armed: the shot check every frame')
-- the run engine's 1 s tick (run deadlines, HUD timers) is not scaled (step LP4 only arms it while it has work)
H.ok(Read('modules/runs/runs.lua'):find('CP.Perf.ms', 1, true) == nil, 'the run engine keeps its own 1 s tick')
Has('modules/runs/runs.lua', 'CP.Perf.armed(TAG, 1000,', 'the armed run engine tick stays 1 s')

-- ============================================================================
--                 CHECKPOINT ROUTE: THE FAR WAIT IN A CAR (Z4)
-- ============================================================================
-- At loopScale 4 the far wait would be 4 s: a car at 45 m/s covers the 150 m view distance in one sleep and
-- passes a checkpoint unseen. In a vehicle it stays at the shipped 1 s.

do
    _G.cache = _G.cache or {}
    _G.cache.ped = 77
    local me = vec3(0.0, 0.0, 30.0)
    local inCar = 5
    _G.GetEntityCoords = function() return me end
    _G.GetVehiclePedIsIn = function() return inCar end
    local keepMarkers = CP.Markers
    CP.Markers = CP.Markers
        or {
            adopt = function() return nil end,
            canRoute = function() return false end,
            hidden = function() return false end,
            release = function() end,
            routeColour = function() return 5 end,
            style = function() return {} end,
        }
    H.load('blocks/checkpoint_route/client.lua')
    local CRc = CP.Blocks.get('checkpoint_route')
    local ctx = {
        runId = 'run-z4cr',
        index = 1,
        obj = { radius = 10.0 },
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    CRc.prepare(ctx)
    CRc.start(ctx)
    CRc.update(ctx, {
        kind = 'state',
        points = { { x = 0.0, y = 400.0, z = 30.0 }, { x = 0.0, y = 900.0, z = 30.0 } },
        current = 1,
        total = 2,
        finished = false,
        track = {},
        course = {},
    })
    Config.Performance.loopScale = 4
    H.advance(5000, 250)
    waits = {}
    H.advance(12000, 250)
    local far = WaitsOf('blocks/checkpoint_route/client.lua')
    local most = 0
    for _, ms in ipairs(far) do if ms > most then most = ms end end
    H.ok(#far > 0 and most <= 1000, ('in a car at loopScale 4: the far wait stays 1 s (longest %d ms)'):format(most))
    inCar = 0
    H.advance(5000, 250)
    waits = {}
    H.advance(12000, 250)
    most = 0
    for _, ms in ipairs(WaitsOf('blocks/checkpoint_route/client.lua')) do if ms > most then most = ms end end
    H.eq(most, 4000, 'on foot: the far wait still stretches with loopScale')
    Config.Performance.loopScale = 1.0
    CRc.stop(ctx)
    H.advance(5000, 250)
    CP.Markers = keepMarkers
end

-- ============================================================================
--                             MARKER DRAW DISTANCE
-- ============================================================================
-- Config.Performance.markerRange, LP3.
-- Shipped 0: every per-frame marker loop keeps its own distance. A cap makes a marker farther than it sleep at the
-- far wait instead of drawing every frame.

H.eq(Config.Performance.markerRange, 0, 'markerRange ships 0 (each marker its own distance)')
H.eq(CP.Perf.rangeSq(150.0 * 150.0), 22500.0, 'shipped: a marker\'s own distance')
Config.Performance.markerRange = 50
H.eq(CP.Perf.rangeSq(150.0 * 150.0), 2500, 'a 50 m cap on a 150 m marker')
H.eq(CP.Perf.rangeSq(30.0 * 30.0), 900.0, 'never farther than the marker\'s own distance')
Config.Performance.markerRange = 'far'
H.eq(CP.Perf.rangeSq(900.0), 900.0, 'not a number: no cap')
Config.Performance.markerRange = 0
for _, rel in ipairs({
    'blocks/escort/client.lua',
    'blocks/flee_arrest/client.lua',
    'blocks/process_scene/client.lua',
    'blocks/protect_rescue/client.lua',
    'blocks/search_area/client.lua',
    'blocks/interact_points/client.lua',
    'blocks/skill_check/client.lua',
}) do
    H.ok(Read(rel):find('CP.Perf.rangeSq(', 1, true) ~= nil, rel .. ': its in-range distance goes through the cap')
end
H.ok(Read('blocks/checkpoint_route/client.lua'):find('CP.Perf.rangeSq', 1, true) == nil,
    'the checkpoint course keeps its own distance (it samples the pass through a checkpoint in range)')

do
    _G.cache = _G.cache or {}
    _G.cache.ped = 77
    local me = vec3(0.0, 0.0, 30.0)
    _G.GetEntityCoords = function() return me end
    local drawn = 0
    local keepDraw = _G.DrawMarker
    _G.DrawMarker = function() drawn = drawn + 1 end
    local keepTarget = H.exportsMock.ox_target
    local zoneN = 0
    H.exportsMock.ox_target = {
        addSphereZone = function() zoneN = zoneN + 1; return zoneN end,
        removeZone = function() end,
    }
    local keepMarkers = CP.Markers
    CP.Markers = CP.Markers
        or {
            adopt = function() return nil end,
            hidden = function() return false end,
            release = function() end,
            style = function() return {} end,
        }
    H.load('blocks/skill_check/client.lua')
    local SC = CP.Blocks.get('skill_check')
    local ctx = {
        runId = 'run-lp3sc',
        index = 1,
        obj = {},
        state = {},
        report = function() end,
        hudDetail = function() end,
    }
    SC.prepare(ctx)
    SC.start(ctx)
    SC.update(ctx, { kind = 'state', targets = { { status = 'armed', coords = { x = 0.0, y = 20.0, z = 30.0 } } } })
    H.advance(1000, 250)
    waits, drawn = {}, 0
    H.advance(3000, 50)
    local frame = 0
    for _, ms in ipairs(WaitsOf('blocks/skill_check/client.lua')) do if ms == 0 then frame = frame + 1 end end
    H.ok(frame > 0 and drawn > 0, ('shipped, a device 20 m away: drawn every frame (%d frames)'):format(frame))
    Config.Performance.markerRange = 10
    H.advance(1000, 50)
    waits, drawn = {}, 0
    H.advance(6000, 50)
    frame = 0
    local far = 0
    for _, ms in ipairs(WaitsOf('blocks/skill_check/client.lua')) do
        if ms == 0 then frame = frame + 1 elseif ms == 1500 then far = far + 1 end
    end
    H.eq(frame, 0, 'markerRange 10: the device 20 m away is not drawn every frame')
    H.eq(drawn, 0, 'and not drawn')
    H.ok(far >= 3 and far <= 5, ('the loop sleeps at the far wait (%d passes in 6 s)'):format(far))
    Config.Performance.markerRange = 0
    SC.stop(ctx)
    H.advance(3000, 250)
    _G.DrawMarker = keepDraw
    H.exportsMock.ox_target = keepTarget
    CP.Markers = keepMarkers
end

-- ============================================================================
--                                 NUI POLLING
-- ============================================================================

local hooks = Read('web/src/shared/hooks.ts')
H.ok(hooks:find('export const POLL_MIN_MS = 20000;', 1, true) ~= nil, 'the shortest screen poll is 20 s')
H.ok(hooks:find('Math.max(asked, POLL_MIN_MS)', 1, true) ~= nil, 'a screen asking for 10 s polls every 20 s')

return H
