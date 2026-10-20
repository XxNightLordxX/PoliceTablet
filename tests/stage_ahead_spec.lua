-- Stage ahead (Config.Spawning.stageAhead, PLAN S3) on the real engine (tests/fixtures/custody/world.lua: runs, npc,
-- scaling, scoring): while an objective runs, the block of the NEXT objective may place that objective's people in its
-- own stage(ctx, dt) hook; its start then sees ctx.staged. No SQL (test runs write no rows).

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local U = CP.U
local Runs = CP.Runs

local cfg = Config.Spawning
local DEFAULTS = U.deepcopy(cfg)
local function Reset()
    for k in pairs(cfg) do cfg[k] = nil end
    for k, v in pairs(DEFAULTS) do cfg[k] = v end
end

-- ============================================================================
--                          THE SHIPPED VALUE (README)
-- ============================================================================

H.eq(cfg.stageAhead, true, 'staging ahead ships on')
H.eq(cfg.enabled, true, 'under the director\'s master switch, which ships on')

-- ============================================================================
--                             CONSOLE AND WARNINGS
-- ============================================================================

local lines = {}
local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    lines[#lines + 1] = line
    -- the harness's own failure lines still reach the runner
    if line:find('^  FAIL ') then realPrint(line) end
end
local function LinesWith(text)
    local out = {}
    for _, l in ipairs(lines) do if l:find(text, 1, true) then out[#out + 1] = l end end
    return out
end
local function WarnsWith(text)
    local out = {}
    for _, e in ipairs(CP.Problems.list({ tag = 'runs', level = 'warn' })) do
        if e.text:find(text, 1, true) then out[#out + 1] = e end
    end
    return out
end
local function ErrorsWith(text)
    local out = {}
    for _, e in ipairs(CP.Problems.list({ tag = 'runs', level = 'error' })) do
        if e.text:find(text, 1, true) then out[#out + 1] = e end
    end
    return out
end

-- ============================================================================
--                                 PROBE BLOCKS
-- ============================================================================
-- Every hook call is recorded with the objective it was for, what the engine said then (ctx.staged, the current
-- objective and its status) and the fake clock.

local calls = {}
local function Note(hook, ctx, extra)
    local run = ctx.run
    local o = run.objectives[ctx.index]
    local c = {
        hook = hook,
        index = ctx.index,
        staged = ctx.staged,
        current = run.objectiveIndex,
        status = o and o.status,
        state = run.state,
        at = H.clockMs,
        run = run.id,
    }
    for k, v in pairs(extra or {}) do c[k] = v end
    calls[#calls + 1] = c
    return c
end
local function Count(run, hook, index, pred)
    local n = 0
    for _, c in ipairs(calls) do
        if c.run == run.id and c.hook == hook and (index == nil or c.index == index) and (not pred or pred(c)) then
            n = n + 1
        end
    end
    return n
end
local function Calls(run, hook, index)
    local out = {}
    for _, c in ipairs(calls) do
        if c.run == run.id and c.hook == hook and c.index == index then out[#out + 1] = c end
    end
    return out
end

-- The objective before: no stage hook of its own. ctx.obj.completeOnTick = n completes it in its n-th tick; an
-- officer's server:objective event { type = 'breach' } completes it at once (the raids' breach interact).
CP.Blocks.register('stage_before', {
    prepare = function(ctx) Note('prepare', ctx) end,
    start = function(ctx) Note('start', ctx) end,
    tick = function(ctx, dt)
        ctx.state.ticks = (ctx.state.ticks or 0) + 1
        Note('tick', ctx, { dt = dt })
        if ctx.obj.completeOnTick and ctx.state.ticks == ctx.obj.completeOnTick then ctx.complete() end
    end,
    onEvent = function(ctx, _, ev)
        Note('event', ctx, { type = ev.type })
        if ev.type == 'breach' then ctx.complete() end
        return true
    end,
    stop = function(ctx) Note('stop', ctx) end,
})

-- The staging block. ctx.obj.stageMode: nil = one ped on its first call, then true; 'later' = nothing for two calls,
-- then the ped; 'never' = called, places nobody, returns nothing; 'error' = raises an error; 'fail' = fails the run.
local STAGE_AT = vec4(160.0, 160.0, 30.0, 90.0)
CP.Blocks.register('stage_probe', {
    prepare = function(ctx) Note('prepare', ctx) end,
    stage = function(ctx, dt)
        ctx.state.stageCalls = (ctx.state.stageCalls or 0) + 1
        Note('stage', ctx, { dt = dt, n = ctx.state.stageCalls })
        local mode = ctx.obj.stageMode
        if mode == 'error' then error('stage probe failed on purpose') end
        if mode == 'fail' then
            ctx.fail('reason.stage_probe')
            return true
        end
        if mode == 'never' then return nil end
        if mode == 'later' and ctx.state.stageCalls < 3 then return false end
        if not ctx.state.stagedNet then
            local _, netId = ctx.spawnPed({
                model = 'g_m_y_lost_01',
                coords = STAGE_AT,
                role = 'hostile',
                armed = true,
                weapon = 'WEAPON_PISTOL',
            })
            ctx.state.stagedNet = netId
            return netId ~= nil
        end
        return true
    end,
    start = function(ctx) Note('start', ctx, { stagedNet = ctx.state.stagedNet }) end,
    tick = function(ctx, dt) Note('tick', ctx, { dt = dt }) end,
    stop = function(ctx) Note('stop', ctx) end,
    onEntityDead = function(ctx, netId) Note('dead', ctx, { netId = netId }) end,
})

local function Mission(opts)
    opts = opts or {}
    local objs = {
        { block = 'stage_before', label = 'Breach', completeOnTick = opts.completeOnTick },
        { block = 'stage_probe', label = 'Fight', stageMode = opts.stageMode },
        { block = 'stage_probe', label = 'Search', stageMode = opts.thirdMode },
    }
    if opts.two then objs[3] = nil end
    return W.mission(objs, { start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 } }, { id = 'stage_probe' })
end

-- A test run of officer 1 (and the others in srcs), every officer at the start: in progress, objective 1 started.
local function Start(opts, srcs)
    srcs = srcs or { 1 }
    for _, src in ipairs(srcs) do W.place(src, 100, 100) end
    return W.start(srcs, Mission(opts), { test = { adminSrc = srcs[1] } })
end
local function EndRun(run)
    if run.state ~= 'ended' then Runs.endRun(run, 'failed', 'test') end
    W.tick(1)
end
local function Exists(run, netId)
    local e = run.entities[netId]
    local m = e and W.ent(e.entity)
    return m ~= nil and m.exists == true
end
local function HandleOf(run, netId)
    local e = run.entities[netId]
    return e and W.ent(e.entity)
end

-- ============================================================================
--       THE NEXT OBJECTIVE STAGES WHILE THE ONE BEFORE RUNS, ONCE A TICK
-- ============================================================================

do
    Reset()
    local run = Start()
    H.eq(run.state, 'in_progress', 'the run is in progress')
    H.eq(run.objectiveIndex, 1, 'objective 1 is current')
    H.eq(Count(run, 'prepare'), 3, 'every objective was prepared first')
    H.eq(Count(run, 'stage'), 0, 'nothing stages before the first tick')

    W.tick(1)
    H.eq(Count(run, 'tick', 1), 1, 'one tick of objective 1')
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 staged in the same tick')
    H.eq(Count(run, 'stage', 3), 0, 'objective 3 does not stage while objective 1 runs (only the next one)')
    local first = Calls(run, 'stage', 2)[1] or {}
    H.eq(first.current, 1, 'it staged while objective 1 was current')
    H.eq(first.status, 'pending', 'and objective 2 was still pending')
    H.eq(first.staged, false, 'ctx.staged is false on its first call')
    H.ok(math.abs((first.dt or 0) - 1.0) < 1e-6, 'stage gets the tick\'s seconds (dt)')
    local net = Runs.ctx(run, 2).state.stagedNet
    H.ok(net ~= nil, 'the staged ped was created')
    H.eq(Runs.ownerOf(run, net), 2, 'it belongs to objective 2, not to the objective that runs')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 1, 'objective 2 owns one entity')
    H.eq(#Runs.entitiesFor(run, { obj = 1 }), 0, 'objective 1 owns none')
    H.eq((HandleOf(run, net) or {}).coords, vec3(STAGE_AT.x, STAGE_AT.y, STAGE_AT.z), 'at the point stage chose')
    H.eq(run.objectives[2].staged, true, 'the engine marked objective 2 staged')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead (objective 1 running)'), 1, 'one console line')
    H.ok(not Runs.canSpawn(run, 80, false), 'the staged ped counts toward the run\'s caps like any entity')

    W.tick(3)
    H.eq(Count(run, 'tick', 1), 4, 'four ticks of objective 1')
    H.eq(Count(run, 'stage', 2), 4, 'objective 2 staged once per tick, never twice in one')
    H.eq(Count(run, 'stage', 2, function(c) return c.n >= 2 and c.staged == true end), 3,
        'every later call sees ctx.staged = true')
    H.eq(Count(run, 'stage', 2, function(c) return c.current == 1 and c.status == 'pending' end), 4,
        'always while objective 1 was current and objective 2 pending')
    H.eq(Count(run, 'stage', 3), 0, 'objective 3 still never staged')
    H.eq(#LinesWith('objective 2 staged ahead'), 1, 'the console line is said once')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 1, 'still the one staged ped (stage decides what it places)')

    -- objective 1 completes: objective 2 starts with what it staged
    H.ok(Runs.ctx(run, 1).complete(), 'objective 1 completes')
    H.eq(run.objectiveIndex, 2, 'objective 2 is current')
    local st = Calls(run, 'start', 2)[1] or {}
    H.eq(st.staged, true, 'its start gets ctx.staged = true')
    H.eq(st.stagedNet, net, 'and the same ctx.state stage wrote')
    H.ok(Exists(run, net), 'the staged ped is still there when its objective starts')
    H.eq(Runs.ownerOf(run, net), 2, 'and still belongs to objective 2')
    H.eq(Count(run, 'stop', 1), 1, 'objective 1 stopped')
    H.eq(Count(run, 'stop', 2), 0, 'objective 2 did not')

    W.tick(3)
    H.eq(Count(run, 'stage', 2), 4, 'objective 2 never stages again once it started')
    H.eq(Count(run, 'tick', 2), 3, 'it ticks instead')
    H.eq(Count(run, 'stage', 3), 3, 'now objective 3 stages, once per tick, while objective 2 runs')
    H.eq(Count(run, 'stage', 3, function(c) return c.current == 2 and c.status == 'pending' end), 3,
        'while objective 2 is current and objective 3 pending')
    local net3 = Runs.ctx(run, 3).state.stagedNet
    H.ok(net3 ~= nil and Runs.ownerOf(run, net3) == 3, 'objective 3\'s staged ped belongs to objective 3')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 3 staged ahead (objective 2 running)'), 1,
        'and its own console line')

    -- the last objective has nothing after it
    H.ok(Runs.ctx(run, 2).complete(), 'objective 2 completes')
    local st3 = Calls(run, 'start', 3)[1] or {}
    H.eq(st3.staged, true, 'objective 3 starts staged')
    local n3 = Count(run, 'stage', 3)
    W.tick(3)
    H.eq(Count(run, 'stage', 3), n3, 'the last objective never stages once it runs')
    H.eq(run.state, 'in_progress', 'the run goes on: nothing to stage after the last objective')
    H.eq(#ErrorsWith('run ' .. run.id), 0, 'no block error')
    EndRun(run)
    H.ok(not Exists(run, net) and not Exists(run, net3), 'the run\'s end deletes the staged peds')
end

-- ============================================================================
--       AN OBJECTIVE THAT COMPLETES IN ITS OWN TICK STAGES NOTHING MORE
-- ============================================================================

do
    Reset()
    local run = Start({ completeOnTick = 2 })
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 staged in tick 1')
    W.tick(1)
    H.eq(run.objectiveIndex, 2, 'objective 1 completed in its second tick, objective 2 started in it')
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 did not stage in the tick it started')
    H.eq(Count(run, 'stage', 3), 0, 'and objective 3 did not stage in that tick either (once a tick)')
    W.tick(1)
    H.eq(Count(run, 'stage', 3), 1, 'objective 3 stages from the next tick on')
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 never again')
    EndRun(run)
end

-- ============================================================================
--    A FAILURE, AN END OR THE LAST OFFICER LEAVING DELETES WHAT WAS STAGED
-- ============================================================================

do
    Reset()
    local run = Start()
    W.tick(2)
    local net = Runs.ctx(run, 2).state.stagedNet
    H.ok(net ~= nil and Exists(run, net), 'staged while objective 1 runs')
    local h = HandleOf(run, net)
    Runs.ctx(run, 1).fail('reason.test')
    H.eq(run.state, 'ended', 'the run failed during objective 1')
    H.eq(h.exists, false, 'the staged ped of objective 2 is deleted')
    H.eq(run.entities[net], nil, 'and forgotten')
    H.eq(Count(run, 'stop', 2), 1, 'objective 2 (prepared) is stopped at the end')
    H.eq(Count(run, 'stop', 3), 1, 'objective 3 too')
    local n = Count(run, 'stage')
    W.tick(3)
    H.eq(Count(run, 'stage'), n, 'an ended run never stages')
end

do
    Reset()
    local run = Start(nil, { 1, 2 })
    W.tick(2)
    local net = Runs.ctx(run, 2).state.stagedNet
    local h = HandleOf(run, net)
    H.ok(h ~= nil and h.exists, 'staged with two officers')
    Runs.removeParticipant(run, 2, 'quit')
    H.eq(run.state, 'in_progress', 'one officer left: the run goes on')
    H.ok(h.exists, 'the staged ped stays while an officer is left')
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 3, 'and staging goes on')
    Runs.removeParticipant(run, 1, 'quit')
    H.eq(run.state, 'ended', 'the last officer left')
    H.eq(h.exists, false, 'the staged ped is deleted')
    W.tick(1)
end

do
    -- a stage that fails the run: the tick stops there
    Reset()
    local run = Start({ stageMode = 'fail' })
    W.tick(1)
    H.eq(run.state, 'ended', 'a stage hook may fail the run')
    H.eq(Count(run, 'stage', 2), 1, 'called once')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead'), 0, 'no staged line for a run that ended')
    H.eq(run.objectives[2].staged, nil, 'and the objective is not marked staged')
    W.tick(1)
end

-- ============================================================================
--                   SWITCHED OFF: EVERYONE APPEARS AT START
-- ============================================================================

do
    Reset()
    cfg.stageAhead = false
    local run = Start()
    W.tick(5)
    H.eq(Count(run, 'tick', 1), 5, 'objective 1 ticks')
    H.eq(Count(run, 'stage'), 0, 'stageAhead = false: stage is never called')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 0, 'objective 2 has nobody yet')
    Runs.ctx(run, 1).complete()
    local st = Calls(run, 'start', 2)[1] or {}
    H.eq(st.staged, false, 'its start gets ctx.staged = false')
    W.tick(2)
    H.eq(Count(run, 'stage'), 0, 'objective 3 never stages either')
    EndRun(run)

    Reset()
    cfg.enabled = false
    run = Start()
    W.tick(3)
    H.eq(Count(run, 'stage'), 0, 'Config.Spawning.enabled = false switches staging off too')
    Runs.ctx(run, 1).complete()
    H.eq((Calls(run, 'start', 2)[1] or {}).staged, false, 'objective 2 starts unstaged')
    EndRun(run)
end

do
    -- read live: off then on, on then off
    Reset()
    cfg.stageAhead = false
    local run = Start()
    W.tick(2)
    H.eq(Count(run, 'stage', 2), 0, 'off for two ticks')
    cfg.stageAhead = true
    W.tick(2)
    H.eq(Count(run, 'stage', 2), 2, 'switched on in Settings: it stages from the next tick')
    local net = Runs.ctx(run, 2).state.stagedNet
    cfg.stageAhead = false
    W.tick(2)
    H.eq(Count(run, 'stage', 2), 2, 'switched off again: no more calls')
    H.ok(Exists(run, net), 'what it already placed stays')
    Runs.ctx(run, 1).complete()
    H.eq((Calls(run, 'start', 2)[1] or {}).staged, true, 'and the objective starts staged')
    EndRun(run)

    -- a config.lua without the key (an older copy) keeps the shipped behaviour
    Reset()
    cfg.stageAhead = nil
    run = Start()
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 1, 'stageAhead missing = on, as shipped')
    EndRun(run)
end

do
    -- a staged person who dies before his objective starts is that objective's death
    Reset()
    local run = Start()
    W.tick(1)
    local net = Runs.ctx(run, 2).state.stagedNet
    Runs.entityDied(run, net, nil)
    local d = Calls(run, 'dead', 2)[1] or {}
    H.eq(d.netId, net, 'objective 2\'s block hears of the death')
    H.eq(d.status, 'pending', 'while it is still pending')
    H.eq(Count(run, 'dead', 1), 0, 'objective 1 does not')
    H.eq(run.state, 'in_progress', 'the run goes on')
    EndRun(run)
end

-- ============================================================================
--                  WHAT THE BLOCK'S STAGE RETURNS, AND ERRORS
-- ============================================================================

do
    Reset()
    local run = Start({ stageMode = 'never' })
    W.tick(3)
    H.eq(Count(run, 'stage', 2), 3, 'a stage that places nobody is still asked each tick')
    H.eq(run.objectives[2].staged, nil, 'but the objective is not marked staged')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead'), 0, 'and no staged line')
    Runs.ctx(run, 1).complete()
    H.eq((Calls(run, 'start', 2)[1] or {}).staged, false, 'its start gets ctx.staged = false')
    EndRun(run)

    Reset()
    run = Start({ stageMode = 'later' })
    W.tick(2)
    H.eq(run.objectives[2].staged, nil, 'not staged while stage returns false')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 0, 'nobody placed yet')
    W.tick(1)
    H.eq(run.objectives[2].staged, true, 'staged on the call that placed someone')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 1, 'one ped placed on the third call')
    EndRun(run)
end

do
    Reset()
    local run = Start({ stageMode = 'error' })
    W.tick(4)
    H.eq(Count(run, 'stage', 2), 1, 'a stage that raises an error is called once, not every tick')
    H.eq(#ErrorsWith('block stage_probe.stage (run ' .. run.id .. ', objective 2) failed'), 1,
        'the error is shown once')
    H.eq(#WarnsWith('run ' .. run.id .. ': objective 2 stopped staging ahead after an error; it starts as before'), 1,
        'with one warning in Admin -> System -> Problems')
    H.eq(run.state, 'in_progress', 'the run goes on')
    H.eq(Count(run, 'tick', 1), 4, 'objective 1 keeps ticking')
    Runs.ctx(run, 1).complete()
    local st = Calls(run, 'start', 2)[1] or {}
    H.eq(st.staged, false, 'objective 2 starts as before (not staged)')
    H.eq(st.state, 'in_progress', 'and its start is called as usual')
    W.tick(1)
    H.eq(Count(run, 'stage', 3), 1, 'the objective after it still stages (the error was objective 2\'s)')
    EndRun(run)
end

-- ============================================================================
--                     BEFORE THE START, AND TEST CONTROLS
-- ============================================================================

do
    -- an accepted run (nobody at the start yet) has no current objective and stages nothing
    Reset()
    W.place(1, 900, 900)
    local run = assert(Runs.create({
        mission = Mission(),
        locationIndex = 1,
        missionType = 'patrol',
        members = { W.officer(1) },
        leaderSrc = 1,
        test = { adminSrc = 1 },
    }))
    W.tick(3)
    H.eq(run.state, 'accepted', 'the run waits for its officer')
    H.eq(Count(run, 'stage'), 0, 'nothing stages before the run is in progress')
    H.eq(Count(run, 'prepare'), 0, 'nor before prepare')
    W.place(1, 100, 100)
    Runs.markArrived(run, 1)
    H.step(0)
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 1, 'it stages once the run is in progress')
    EndRun(run)
end

do
    -- Restart objective (test control) on a staged objective: it starts again as one nobody staged
    Reset()
    local run = Start()
    W.tick(2)
    local net = Runs.ctx(run, 2).state.stagedNet
    local h = HandleOf(run, net)
    Runs.testSkip(run)
    H.eq(run.objectiveIndex, 2, 'Skip objective: objective 2 starts')
    H.eq((Calls(run, 'start', 2)[1] or {}).staged, true, 'staged')
    H.ok(Runs.testRestart(run), 'Restart objective')
    H.eq(h.exists, false, 'the staged ped goes with the objective\'s other entities')
    local starts = Calls(run, 'start', 2)
    H.eq(#starts, 2, 'objective 2 started again')
    H.eq((starts[2] or {}).staged, false, 'as one nobody staged')
    H.eq(Count(run, 'stage', 2), 2, 'and it never stages itself again')
    EndRun(run)
end

-- ============================================================================
-- A STAGE THAT WAITS FOR ITS PEOPLE HOLDS ITS OBJECTIVE'S START UNTIL IT RETURNS
-- ============================================================================
-- On a real server ctx.spawnPed waits (Wait(0)) until the new ped exists and has a network id, and every run ticks in
-- its own thread, so an officer's event can complete objective 1 while objective 2's stage is still placing people.
-- Here the second ped of the staged wave appears only late.ms after CreatePed (the engine's own wait yields, as there)
-- and the breach is the officer's server:objective event. start places the wave itself when nothing was staged, as a
-- block does: a start that did not wait would place a second wave.

local late = { ms = 0 }
local worldCreatePed = _G.CreatePed
local function LateCreatePed(...)
    local h = worldCreatePed(...)
    if late.ms > 0 then
        W.ent(h):set({ exists = false }):at(H.clockMs + late.ms, { exists = true })
        late.ms = 0
    end
    return h
end

local WAVE_AT = { vec4(170.0, 160.0, 30.0, 0.0), vec4(172.0, 160.0, 30.0, 0.0) }
-- ctx.obj.lateMs: the stage's second ped appears that late; ctx.obj.hangMs: the stage waits that long after its first
local function PlaceWave(ctx, staging)
    local wave = {}
    for n, at in ipairs(WAVE_AT) do
        if staging and n == 2 then late.ms = ctx.obj.lateMs or 0 end
        local _, netId = ctx.spawnPed({
            model = 'g_m_y_lost_01',
            coords = at,
            role = 'hostile',
            armed = true,
            weapon = 'WEAPON_PISTOL',
        })
        wave[#wave + 1] = netId
        if staging and n == 1 and ctx.obj.hangMs then Wait(ctx.obj.hangMs) end
    end
    return wave
end
CP.Blocks.register('stage_wave', {
    stage = function(ctx)
        if ctx.state.wave then return true end
        Note('stage', ctx)
        local wave = PlaceWave(ctx, true)
        ctx.state.wave = wave
        Note('staged', ctx, { placed = #wave })
        return true
    end,
    start = function(ctx)
        Note('start', ctx, { have = #Runs.entitiesFor(ctx.run, { obj = ctx.index }), wave = ctx.state.wave })
        if not ctx.staged then ctx.state.startWave = PlaceWave(ctx, false) end
    end,
    tick = function(ctx, dt) Note('tick', ctx, { dt = dt }) end,
    stop = function(ctx) Note('stop', ctx) end,
})

local function WaveStart(fight)
    fight.block, fight.label = 'stage_wave', 'Fight'
    W.place(1, 100, 100)
    return W.start({ 1 }, W.mission(
        { { block = 'stage_before', label = 'Breach' }, fight },
        { start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 } },
        { id = 'stage_wave' }
    ), { test = { adminSrc = 1 } })
end
local function Breach(run) H.fire(CP.e('server:objective'), 1, run.id, 1, { type = 'breach' }) end
local function One(run, hook, index) return Calls(run, hook, index)[1] or {} end

do
    Reset()
    _G.CreatePed = LateCreatePed
    local run = WaveStart({ lateMs = 2500 })
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 began staging in the run\'s tick')
    H.eq(Count(run, 'staged', 2), 0, 'and is still waiting for its second ped to appear')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 1, 'one of its two people is placed so far')

    -- the officer breaches while the stage is still placing people (his event, its own thread)
    Breach(run)
    H.eq(Count(run, 'event', 1), 1, 'the breach reached objective 1')
    H.eq(run.objectives[1].status, 'done', 'objective 1 is done')
    H.eq(Count(run, 'start', 2), 0, 'objective 2 does not start while its stage is still placing people')
    H.eq(run.objectives[2].status, 'pending', 'it waits, still pending')

    W.tick(3)
    local staged, st = One(run, 'staged', 2), One(run, 'start', 2)
    H.eq(staged.placed, 2, 'the stage placed both people')
    H.eq(staged.status, 'pending', 'and returned while objective 2 was still pending')
    H.eq(Count(run, 'start', 2), 1, 'then objective 2 started, once')
    H.eq(run.objectiveIndex, 2, 'objective 2 is current')
    H.ok((st.at or -1) >= (staged.at or math.huge), 'it started only after the stage returned: nothing placed after')
    H.eq(st.staged, true, 'its start gets ctx.staged = true')
    H.eq(#(st.wave or {}), 2, 'and the same ctx.state, with everything the stage placed')
    H.eq(st.have, 2, 'both staged people are its own when it starts')
    H.eq(#Runs.entitiesFor(run, { obj = 2 }), 2, 'no second wave: still the two staged people')
    H.eq(run.objectives[2].staged, true, 'the engine marked it staged')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead (objective 1 done)'), 1,
        'one console line, saying objective 1 was done by then')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead (objective 1 running)'), 0, 'not "running"')
    H.eq(#WarnsWith('run ' .. run.id), 0, 'no warning')
    H.eq(#ErrorsWith('run ' .. run.id), 0, 'no error')
    local ticks = Count(run, 'tick', 2)
    W.tick(2)
    H.eq(Count(run, 'stage', 2), 1, 'objective 2 never stages again')
    H.eq(Count(run, 'tick', 2), ticks + 2, 'it ticks, once a second')
    EndRun(run)
    _G.CreatePed = worldCreatePed
end

do
    -- the run ends while the start waits: objective 2 never starts and nothing stays
    Reset()
    _G.CreatePed = LateCreatePed
    local run = WaveStart({ lateMs = 2500 })
    W.tick(1)
    local first = HandleOf(run, (Runs.entitiesFor(run, { obj = 2 })[1] or {}).netId or -1)
    H.ok(first ~= nil and first.exists, 'the stage placed its first ped')
    Breach(run)
    H.eq(Count(run, 'start', 2), 0, 'objective 2 waits for its stage')
    Runs.removeParticipant(run, 1, 'quit')
    H.eq(run.state, 'ended', 'the last officer left while it waited')
    W.tick(4)
    H.eq(Count(run, 'start', 2), 0, 'objective 2 never started')
    H.eq(next(run.entities), nil, 'nothing the stage placed is left')
    H.ok(first ~= nil and not first.exists, 'its first ped was deleted')
    H.eq(#ErrorsWith('run ' .. run.id), 0, 'no error')
    _G.CreatePed = worldCreatePed
end

do
    -- a stage that waits far longer than the engine holds: objective 2 starts after at most 30 s, as one nobody
    -- staged, and the engine says so once when the stage finally returns
    Reset()
    local run = WaveStart({ hangMs = 40000 })
    W.tick(1)
    H.eq(Count(run, 'stage', 2), 1, 'the stage placed its first ped and waits')
    Breach(run)
    W.tick(25)
    H.eq(Count(run, 'start', 2), 0, 'objective 2 is still held 25 s later')
    W.tick(6)
    H.eq(Count(run, 'start', 2), 1, 'it started once the engine stopped holding it (30 s)')
    H.eq(One(run, 'start', 2).staged, false, 'as one nobody staged (its start places its own people)')
    W.tick(12)
    H.eq(Count(run, 'staged', 2), 1, 'the stage returned in the end')
    H.eq(run.objectives[2].staged, nil, 'the engine did not mark the running objective staged')
    H.eq(#LinesWith('run ' .. run.id .. ': objective 2 staged ahead'), 0, 'and printed no staged line')
    H.eq(#WarnsWith('run ' .. run.id .. ': objective 2 started before its stage ahead returned'), 1, 'one warning')
    H.eq(run.state, 'in_progress', 'the run goes on')
    EndRun(run)
end

-- ============================================================================
--                A REAL BLOCK WITHOUT A STAGE HOOK IS UNCHANGED
-- ============================================================================

do
    Reset()
    local run = W.start({ 1 }, W.mission({
        { block = 'stage_before', label = 'One' },
        { block = 'stub_hold', label = 'Hold' },
    }, { start = { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 } }, { id = 'stage_none' }),
        { test = { adminSrc = 1 } })
    W.tick(3)
    H.eq(run.objectives[2].staged, nil, 'a block with no stage hook is never staged')
    H.eq(#ErrorsWith('run ' .. run.id), 0, 'and nothing complains')
    H.eq(#WarnsWith('run ' .. run.id), 0, 'no warning either')
    Runs.ctx(run, 1).complete()
    H.eq(run.objectiveIndex, 2, 'objective 2 starts as before')
    H.eq(Runs.ctx(run, 2).staged, false, 'with ctx.staged = false')
    EndRun(run)
end

_G.print = realPrint
Reset()
return H
