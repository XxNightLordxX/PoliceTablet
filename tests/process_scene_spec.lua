-- Blocks/process_scene (WP2): kept bodies (at most the limit, oldest out), nobody died (+15 at once), Photograph
-- & tag and Bag body with reach and dwell, Release at the coroner van or the scene marker, cleanup, the clocks.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local Runs = W.Runs
local U = CP.U

for src = 1, 4 do W.place(src, 300.0, 290.0, 30.0) end
local impl = CP.Blocks.get('process_scene')

local SCENE = vec3(305.0, 305.0, 30.0)
local function Location(extra)
    local loc = {
        label = 'Warehouse',
        start = { coords = vec3(300.0, 250.0, 30.0), radius = 40.0 },
        scene = SCENE,
        coroner = vec4(320.0, 300.0, 30.0, 0.0),
    }
    for k, v in pairs(extra or {}) do loc[k] = v end
    return loc
end

local function Mission(count, scene)
    local ps = { block = 'process_scene', label = 'Process the scene', minSeconds = 5 }
    for k, v in pairs(scene or {}) do ps[k] = v end
    return W.mission({
        { block = 'stub_hostiles', label = 'Hostiles', minSeconds = 0, count = count },
        ps,
    }, Location())
end

local function Kill(run, netId, src)
    local m = W.model(run, netId)
    m.killer = (src or 1) * 100
    m.health = 0
    W.tick(1)
end

local function Report(src, run, ev) H.fire('crimson-police:server:objective', src, run.id, 2, ev) end

local function Step(src, run, kind, netId, ms)
    Report(src, run, { type = kind .. '_begin', netId = netId })
    H.advance(ms, 250)
    Report(src, run, { type = kind, netId = netId })
end

local function State(run) return run.objectives[2].state end

-- ============================================================================
--                          1. DEFAULTS AND VALIDATION
-- ============================================================================

do
    local o = impl.defaults({ block = 'process_scene' })
    H.eq(o.bodies, 4, 'bodies kept: 4')
    H.eq(o.tag.duration, 5000, 'Photograph & tag 5 s')
    H.eq(o.bag.duration, 6000, 'Bag body 6 s')
    H.eq(o.release.duration, 8000, 'Release to coroner 8 s')
    H.eq(o.coroner, 'coroner', 'the coroner van is on')
    H.eq(o.aliveBonus.id, 'all_taken_alive', 'all_taken_alive')
    H.ok(impl.validate({ block = 'process_scene' }, { source = 'builtin', locations = { Location() } }), 'validates')
    H.eq((impl.validate({ block = 'process_scene', bodies = 9 }, { source = 'builtin', locations = { Location() } })),
        false, 'bodies above 8 are refused')
    H.eq((
        impl.validate({ block = 'process_scene', tag = { label = 'x', duration = 1000 } },
            { source = 'custom', locations = { Location() } })
    ), false, 'a custom 1 s step is refused')
    H.eq((
        impl.validate({ block = 'process_scene' }, { source = 'builtin', locations = { Location({ scene = false }) } })
    ), false, 'a scene marker is needed')
    H.eq(impl.armedCount({}), 0, 'no armed NPCs')
end

-- ============================================================================
--                  2. NOBODY DIED: IT COMPLETES AT ONCE (+15)
-- ============================================================================

do
    local run = W.start({ 1, 2 }, Mission(2))
    W.tick(1)
    Runs.objectiveComplete(run, 1)
    H.eq(run.state, 'ended', 'with no bodies Process the scene completes at once')
    H.eq(run.score.shared.all_taken_alive, 1, 'and every participant earns all_taken_alive')
    local r = W.row(run.id, 'CUS2')
    H.ok(r and W.contains(r.breakdown, 'all_taken_alive'), 'on every row')
end

-- ============================================================================
--                                3. BODIES KEPT
-- ============================================================================
-- AT MOST `bodies`, THE OLDEST RELEASED FIRST.

do
    local run = W.start({ 1 }, Mission(5, { bodies = 3 }))
    W.tick(1)
    local order = {}
    for i, n in ipairs(W.hostiles) do
        Kill(run, n)
        order[i] = n
    end
    H.eq(#Runs.heldBodies(run), 3, 'at most bodies are kept')
    H.eq(run.entities[order[1]], nil, 'the oldest body is released first')
    H.eq(run.entities[order[2]], nil, 'then the next')
    H.ok(run.entities[order[5]] ~= nil, 'the latest are kept')
    W.tick(35)
    H.ok(run.entities[order[3]] ~= nil, 'kept bodies skip the 30 s corpse cleanup')
    -- the objective starts: the clock stops and the time limit grows 60 s + 20 s per body
    local before = Runs.remaining(run)
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 180.0, y = args.near.y, z = args.near.z }, heading = 0.0 }
    end
    Runs.objectiveComplete(run, 1)
    H.ok(run.fastClockAt ~= nil, 'the fast-completion clock stops')
    H.near(Runs.remaining(run) - before, 60 + 20 * 3, 1.5, 'the time limit grows by 60 s + 20 s per body')
    local st = State(run)
    H.eq(#st.order, 3, 'the three kept bodies are the ones to process')
    local body = st.order[1]
    local bc = W.at(run, body)
    -- tag: reach at both ends and the dwell
    W.place(1, bc.x + 8.0, bc.y, bc.z)
    Step(1, run, 'tag', body, 5200)
    H.eq(st.bodies[body].tagged, false, 'out of reach: not tagged')
    W.place(1, bc.x + 1.0, bc.y, bc.z)
    Step(1, run, 'tag', body, 2000)
    H.eq(st.bodies[body].tagged, false, 'too early: not tagged')
    Report(1, run, { type = 'tag_begin', netId = body })
    H.advance(1500, 250)
    W.place(1, bc.x + 9.0, bc.y, bc.z)
    H.advance(1500, 250)
    W.place(1, bc.x + 1.0, bc.y, bc.z)
    H.advance(2300, 250)
    Report(1, run, { type = 'tag', netId = body })
    H.eq(st.bodies[body].tagged, false, 'walked away during the step: the dwell fails')
    Step(1, run, 'bag', body, 6200)
    H.eq(st.bodies[body].bagged, false, 'a body is bagged only after it is tagged')
    Step(1, run, 'tag', body, 5200)
    H.eq(st.bodies[body].tagged, true, 'Photograph & tag')
    Step(1, run, 'bag', body, 6200)
    H.eq(st.bodies[body].bagged, true, 'Bag body')
    H.eq(run.entities[body], nil, 'the body-bag prop replaces the body')
    local bag = st.bodies[body].bag
    H.ok(bag and run.entities[bag] and run.entities[bag].kind == 'object', 'a body-bag prop')
    -- the rest, then the release at the coroner van
    for i = 2, 3 do
        local n = st.order[i]
        local c = W.at(run, n)
        W.place(1, c.x + 1.0, c.y, c.z)
        Step(1, run, 'tag', n, 5200)
        Step(1, run, 'bag', n, 6200)
    end
    H.eq(run.objectives[2].status, 'active', 'every body bagged: release to the coroner next')
    local van = nil
    for _, s in ipairs(CP.Custody._servicesOf(run)) do if s.kind == 'coroner' then van = s end end
    H.ok(van ~= nil, 'the coroner van was called')
    W.tick(1)
    H.eq(van.status, 'coming', 'it drives in')
    Step(1, run, 'release', nil, 8200)
    H.eq(State(run).released, nil, 'the van is not parked yet: no release')
    local dest = van.dest
    W.model(run, van.veh).coords = vec3(dest.x, dest.y, dest.z)
    W.tick(1)
    H.eq(van.status, 'parked', 'the van parks nearby')
    W.place(1, dest.x + 3.0, dest.y, dest.z)
    Step(1, run, 'release', nil, 8200)
    H.eq(State(run).released, true, 'Release to coroner')
    H.eq(run.state, 'ended', 'the objective and the run complete')
    H.eq(run.score.shared.all_taken_alive, nil, 'processing bodies earns nothing')
    for netId, e in pairs(run.entities) do H.ok(false, 'left behind: ' .. tostring(e.kind) .. ' ' .. netId) end
    H.ok(next(run.entities) == nil, 'everything removed at the end')
    W.roadPoint = nil
end

-- ============================================================================
--              4. THE SCENE MARKER WHEN THE VAN IS OFF, AND STOP
-- ============================================================================

do
    local run = W.start({ 1 }, Mission(1, { coroner = false }))
    W.tick(1)
    Kill(run, W.hostiles[1])
    Runs.objectiveComplete(run, 1)
    local st = State(run)
    H.eq(#CP.Custody._servicesOf(run), 0, 'coroner off: no van')
    local body = st.order[1]
    local bc = W.at(run, body)
    W.place(1, bc.x + 1.0, bc.y, bc.z)
    Step(1, run, 'tag', body, 5200)
    Step(1, run, 'bag', body, 6200)
    W.place(1, SCENE.x + 30.0, SCENE.y, SCENE.z)
    Step(1, run, 'release', nil, 8200)
    H.eq(st.released, nil, 'the release needs the scene marker')
    W.place(1, SCENE.x + 2.0, SCENE.y, SCENE.z)
    Step(1, run, 'release', nil, 8200)
    H.eq(st.released, true, 'released at the scene marker')
    H.eq(run.state, 'ended', 'completed')
end

do
    -- the run ends mid-scene: bodies and bags are all removed
    local run = W.start({ 1 }, Mission(2, { coroner = false }))
    W.tick(1)
    Kill(run, W.hostiles[1])
    Kill(run, W.hostiles[2])
    Runs.objectiveComplete(run, 1)
    local st = State(run)
    local body = st.order[1]
    local bc = W.at(run, body)
    W.place(1, bc.x + 1.0, bc.y, bc.z)
    Step(1, run, 'tag', body, 5200)
    Step(1, run, 'bag', body, 6200)
    local bag = st.bodies[body].bag
    local bagModel = W.model(run, bag)
    local other = W.model(run, st.order[2])
    Runs.endRun(run, 'failed', 'time_limit')
    H.eq(bagModel.exists, false, 'a body bag is deleted at the end')
    H.eq(other.exists, false, 'a kept body is deleted at the end')
end

do
    -- a body another rule deleted is gone from the list; roles outside the list are never kept
    local m = W.mission({
        { block = 'stub_hostiles', label = 'Hostages', minSeconds = 0, count = 1, role = 'hostage' },
        { block = 'process_scene', label = 'Process the scene', minSeconds = 5 },
    }, Location())
    local run = W.start({ 1 }, m)
    W.tick(1)
    Kill(run, W.hostiles[1])
    H.eq(#Runs.heldBodies(run), 0, 'a role outside the list (a hostage) is never kept')
    Runs.endRun(run, 'completed', 'completed')
end

return H
