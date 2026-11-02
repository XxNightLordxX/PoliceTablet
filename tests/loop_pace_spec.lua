-- Loops run less often (step LP2, docs/LOOPS.md): CP.Perf scales the idle and far waits by
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

H.load('modules/npccombat/client.lua')
H.step(0)
waits = {}
CP.NpcCombat.start('lp2-run')
H.advance(8000, 250)
local list = WaitsOf('modules/npccombat/client.lua')
H.ok(#list >= 3, ('the watcher ran (%d waits)'):format(#list))
local allTwo = #list > 0
for _, ms in ipairs(list) do if ms ~= 2000 then allTwo = false end end
H.ok(allTwo, 'the run watcher wakes every 2 s (was 1 s): ' .. table.concat(list, ','))
H.ok(#list <= 5, ('8 s of a run: at most 5 passes, not 8 (%d)'):format(#list))

Config.Performance.loopScale = 2
H.advance(4000, 250)   -- the pass already waiting ends at its old pace
waits = {}
H.advance(16000, 250)
list = WaitsOf('modules/npccombat/client.lua')
local allFour = #list > 0
for _, ms in ipairs(list) do if ms ~= 4000 then allFour = false end end
H.ok(allFour, 'loopScale 2: every 4 s: ' .. table.concat(list, ','))
H.ok(#list >= 3 and #list <= 5, ('16 s at loopScale 2: about 4 passes (%d)'):format(#list))
CP.NpcCombat.stop()
H.advance(5000, 250)
Config.Performance.loopScale = 1.0

-- ============================================================================
--                      SHIPPED INTERVALS (docs/LOOPS.md)
-- ============================================================================
-- The idle and far waits the owner asked to be slower, read from the files (before -> after in docs/LOOPS.md).

local function Read(rel)
    local f = assert(io.open(H.root .. rel, 'r'))
    local s = f:read('a')
    f:close()
    return s
end
local function Has(rel, needle, msg)
    H.ok(Read(rel):find(needle, 1, true) ~= nil, msg .. ' (' .. rel .. ')')
end

Has('modules/tablet/client.lua', 'local DESK_WATCH_MS = 1000', 'walk-away close checked every 1 s')
Has('modules/tablet/client.lua', 'local DOWN_WATCH_MS = 1000', 'downed check every 1 s')
Has('modules/tablet/client.lua', 'local ITEM_WATCH_MS = 2000', 'tablet item check every 2 s')
Has('modules/tablet/client.lua', 'local ANIM_WATCH_MS = 2000', 'tablet animation kept every 2 s')
Has('modules/markers/client.lua', 'local TICK_MS = 2000', 'objective pointer every 2 s')
Has('modules/runs/client.lua', 'local TELEMETRY_MS = 2000', 'run telemetry every 2 s')
Has('modules/runs/client.lua', 'local UNARMED_MS = 1000', 'unarmed weapon check every 1 s')
Has('modules/npc/client.lua', 'local LOOP_MS = 1000', 'NPC retask every 1 s')
Has('modules/npc/client.lua', 'local GOVERN_MS = 2000', 'NPC combat governor every 2 s')
Has('modules/alerts/server.lua', 'local RECONCILE_MS = 2000', 'crimsonArena flag reconcile every 2 s')
Has('modules/anticheat/server.lua', 'local TICK_MS = 2000', 'anticheat pass every 2 s')
Has('modules/operations/server.lua', 'local TICK_IDLE_MS = 10000', 'no operation: every 10 s')
Has('modules/units/server.lua', 'local SWEEP_MS = 5000', 'unit invite sweep every 5 s')
Has('modules/schedule/server.lua', 'local CHECK_EVERY_MS = 60000', 'daily boundary check every 60 s')
Has('modules/happyhour/server.lua', 'local TICK_MS = 30000', 'happy hour end check every 30 s')
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
Has('modules/runs/client.lua', 'if IsPedArmed(ped, 6) then\n                Wait(0)',
    'armed: the shot check every frame')
-- the run engine's 1 s tick (run deadlines, HUD timers) is not scaled
H.ok(Read('modules/runs/server.lua'):find('CP.Perf', 1, true) == nil, 'the run engine keeps its own 1 s tick')

-- ============================================================================
--                                 NUI POLLING
-- ============================================================================

local hooks = Read('web/src/shared/hooks.ts')
H.ok(hooks:find('export const POLL_MIN_MS = 20000;', 1, true) ~= nil, 'the shortest screen poll is 20 s')
H.ok(hooks:find('Math.max(asked, POLL_MIN_MS)', 1, true) ~= nil, 'a screen asking for 10 s polls every 20 s')

return H
