-- The mission loader yields between missions, so loading them never holds one server tick.

-- The real FXServer boot (build 38435) printed "server thread hitch warning: timer interval of 224 milliseconds"
-- during `restart Crimson-Police`, right where CP.Missions.loadAll read and normalised the 19 built-in missions in
-- one tick. The loader now yields (Wait(0)) between missions once it has worked LOAD_SLICE_MS in one go, inside a
-- thread that may yield, and never anywhere else. While it yields the old missions stay live (same tables), and a
-- change made meanwhile (a Builder publish or unpublish) is kept by the swap at the end.

-- GetGameTimer is the clock of the slice. The harness's clock only moves on Wait, so this spec makes it move 15 ms
-- per read (a slow server): deterministic, no wall-clock timing.

local H = dofile('tests/harness.lua')
local X = dofile('tests/fixtures/admin_missions/boot.lua')(H, 'missions_load_yield')
local M = CP.Missions

local function Count()
    local n = 0
    for _ in pairs(M.all and M.all() or {}) do n = n + 1 end
    return n
end

local before = M.get('gang_shootout')
H.ok(before ~= nil and before.source == 'builtin', 'the built-in missions are loaded at start')
local builtins = Count()
H.ok(builtins >= 19, 'the 19 built-in missions are there: ' .. builtins)

-- ============================================================================
--                        A DIRECT CALL OUTSIDE A THREAD
-- ============================================================================
-- (the main chunk, a C boundary) cannot yield: it loads in one go.

local realTimer = GetGameTimer
local fake = 0
GetGameTimer = function()
    fake = fake + 15
    return fake
end
local s0 = M.loadAll()
H.eq(s0.builtin, builtins, 'a load outside a thread still loads every built-in')
H.eq(s0.yields or 0, 0, 'and never yields (it cannot)')

-- ============================================================================
--                               INSIDE A THREAD
-- ============================================================================
-- It yields, and the old missions stay until the swap.

before = M.get('gang_shootout')
local summary
CreateThread(function() summary = M.loadAll() end)
H.eq(summary, nil, 'the load inside a thread has not finished in its first tick (it yielded)')
H.ok(M.get('gang_shootout') == before, 'while it yields the old definition stays live (the same table)')
H.eq(Count(), builtins, 'and no mission is missing while it loads')

-- a Builder publish while the load yields: the swap keeps it
local published = M.register({
    id = 'custom_during_load',
    label = 'During load',
    type = 'patrol',
    minOfficers = 1,
    maxOfficers = 1,
    timeLimit = 400,
    locations = {
        {
            label = 'Spot',
            start = { coords = vec3(1000.0, 5000.0, 30.0), radius = 50.0 },
            checkpoints = { vec3(1100.0, 5000.0, 30.0), vec3(1200.0, 5000.0, 30.0) },
        },
    },
    objectives = { { block = 'checkpoint_route', checkpoints = 'checkpoints' } },
    version = 1,
})
H.ok(published ~= nil, 'a custom mission registers while the load yields')

local steps = 0
while summary == nil and steps < 200 do
    H.step(0)
    steps = steps + 1
end
H.ok(summary ~= nil, 'the load finishes within a few ticks: ' .. steps)
H.ok(steps >= 2, 'it took more than one tick: ' .. steps)
H.ok((summary and summary.yields or 0) >= 2, 'it yielded between missions: ' .. tostring(summary and summary.yields))
H.eq(summary and summary.builtin, builtins, 'every built-in mission loaded')
H.ok(M.get('gang_shootout') ~= nil and M.get('gang_shootout') ~= before,
    'the new definitions are swapped in at the end')
H.ok(M.get('custom_during_load') == published, 'the mission published while it yielded is kept by the swap')

-- an unpublish while the load yields is kept too
summary = nil
CreateThread(function() summary = M.loadAll() end)
H.eq(summary, nil, 'a second load yields too')
H.ok(M.unregister('custom_during_load'), 'the custom mission unregisters while it yields')
steps = 0
while summary == nil and steps < 200 do
    H.step(0)
    steps = steps + 1
end
H.ok(summary ~= nil, 'the second load finishes')
H.eq(M.get('custom_during_load'), nil, 'the mission unpublished while it yielded stays gone after the swap')

-- a fast server (the clock does not move): nothing to give back, one tick as before
GetGameTimer = realTimer
summary = nil
CreateThread(function() summary = M.loadAll() end)
H.ok(summary ~= nil and (summary.yields or 0) == 0, 'under the slice the load runs in one tick, no yield')

X.cleanup()
return H
