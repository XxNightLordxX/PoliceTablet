-- Blocks/field_contact (WP2): the three modes (parked, scene, stop), approach reactions and tells, runners and
-- escapes, the returning driver and the thief, the leak spec, and a stop-mode fixture completing at every tier.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local Runs, Custody = W.Runs, W.Custody
local U = CP.U
local cjson = require('cjson')
cjson.encode_sparse_array(true)

for src = 1, 4 do W.place(src, 0.0, 0.0, 30.0) end
local impl = CP.Blocks.get('field_contact')

-- ============================================================================
--                                  LOCATIONS
-- ============================================================================

local RULES = { 'metered', 'permit', 'no_parking', 'hydrant', 'loading', 'free' }
local function ParkedLocation(n)
    local spots = {}
    for i = 1, n or 6 do
        spots[i] = {
            coords = vec4(1000.0 + i * 20.0, 1000.0, 30.0, 90.0),
            rule = RULES[((i - 1) % #RULES) + 1],
            street = 'Alta Street',
        }
    end
    return { label = 'Downtown', start = { coords = vec3(1000.0, 950.0, 30.0), radius = 40.0 }, spots = spots }
end

local function SceneLocation()
    return {
        label = 'Behind the 24/7',
        start = { coords = vec3(2000.0, 1940.0, 30.0), radius = 40.0 },
        car = vec4(2000.0, 2000.0, 30.0, 0.0),
        peopleSpots = {
            vec4(2003.0, 2000.0, 30.0, 0.0),
            vec4(2005.0, 2002.0, 30.0, 0.0),
            vec4(2006.0, 1998.0, 30.0, 0.0),
        },
        fleeTo = { { vec3(2100.0, 2000.0, 30.0), vec3(2200.0, 2000.0, 30.0) } },
        transport = vec4(2010.0, 1980.0, 30.0, 0.0),
    }
end

local function Contact(run, obj, kind, i)
    local list = kind == 'vehicle' and W.cars(run, obj) or W.people(run, obj)
    return list[i or 1]
end

local function Report(src, run, index, ev)
    H.fire('crimson-police:server:objective', src, run.id, index, ev)
end

local function Obj(run, i) return run.objectives[i or 1] end

-- test profile sets and demeanours (restored at the end)
local sets = Config.Custody.profileSets
sets.test_clean = { person = { clean = 100 }, vehicle = { legal = 100 } }
sets.test_warrant = { person = { warrant = 100 }, vehicle = { legal = 100 } }
sets.test_armed = { person = { armed = 100 }, vehicle = { legal = 100 } }
sets.test_stolen = { vehicle = { stolen = 100 } }
sets.test_legal = { vehicle = { legal = 100 } }
local savedDemeanour = U.deepcopy(Config.Custody.demeanour)
local function Demeanour(truth, name) Config.Custody.demeanour[truth] = { [name] = 100 } end
local function RestoreDemeanour() Config.Custody.demeanour = U.deepcopy(savedDemeanour) end

-- ============================================================================
--                          1. DEFAULTS AND VALIDATION
-- ============================================================================

do
    local o = impl.defaults({ block = 'field_contact' })
    H.eq(o.mode, 'scene', 'default mode: scene')
    H.eq(o.people, 1, 'people 1')
    H.eq(o.approach, 25.0, 'approach 25 m')
    H.eq(o.custody, 'handover', 'after an arrest: hand over')
    H.eq(o.bestPoints, 10, 'best decision bonus 10')
    H.eq(o.returning.chance, 0.25, 'returning driver 25%')
    H.eq(o.escape.distance, 400, 'escape 400 m')
    H.eq(o.escape.seconds, 20, 'for 20 s')
    local builtin = { source = 'builtin', locations = { SceneLocation() } }
    H.ok(impl.validate({ block = 'field_contact', mode = 'scene', people = 2, cars = 1 }, builtin), 'a scene validates')
    local custom = { source = 'custom', locations = { SceneLocation() } }
    H.ok(impl.validate({ block = 'field_contact', mode = 'scene', people = 2, cars = 1 }, custom),
        'a custom scene with 3 person spots validates')
    local ok = impl.validate({ block = 'field_contact', mode = 'scene', people = 5 }, builtin)
    H.eq(ok, false, 'people above 4 is refused')
    ok = impl.validate({ block = 'field_contact', mode = 'nope' }, builtin)
    H.eq(ok, false, 'an unknown mode is refused')
    ok = impl.validate({ block = 'field_contact', mode = 'parked', cars = 5 },
        { source = 'custom', locations = { ParkedLocation(4) } })
    H.eq(ok, false, 'parked: 5 kerb spots are needed for a custom mission')
    H.ok(impl.validate(
        { block = 'field_contact', mode = 'parked', cars = 5 },
        { source = 'custom', locations = { ParkedLocation(6) } }
    ), 'parked with 6 spots validates')
    local badRule = ParkedLocation(6)
    badRule.spots[2].rule = 'nonsense'
    ok = impl.validate({ block = 'field_contact', mode = 'parked', cars = 5 },
        { source = 'builtin', locations = { badRule } })
    H.eq(ok, false, 'every spot needs a posted rule')
    H.eq(impl.armedCount({ block = 'field_contact', mode = 'scene', people = 3, profileSet = 'scene' }), 3,
        'the armed budget counts every person when the truth set can roll armed')
    H.eq(impl.armedCount({ block = 'field_contact', mode = 'parked' }), 0, 'parked cars are never armed')
    H.eq(impl.armedCount({ block = 'field_contact', mode = 'scene', profileSet = 'test_clean' }), 0,
        'a set with no armed weight counts nothing')
    local zoned = SceneLocation()
    zoned.peopleSpots[1] = vec4(441.0, -979.0, 30.0, 0.0)
    ok = impl.validate({ block = 'field_contact', mode = 'scene' }, { source = 'builtin', locations = { zoned } })
    H.eq(ok, false, 'a point inside a no-build zone is refused')
    ok = impl.validate({ block = 'field_contact', mode = 'scene', allCorrect = { id = 'all_correct', points = 20 } },
        custom)
    H.eq(ok, false, 'a custom mission cannot value its own all_correct')
end

-- ============================================================================
--              2. PARKED: SPOT RULES, BEST DECISIONS, ALL CORRECT
-- ============================================================================

local function BestFor(run, c)
    local t = c.truth
    if t == 'stolen' then return 'impound' end
    if t == 'violation' then return c.level == 'impound' and 'impound' or 'cite' end
    return 'noAction'
end

do
    local m = W.mission({
        {
            block = 'field_contact',
            label = 'Check the cars',
            mode = 'parked',
            cars = 5,
            returning = { chance = 0 },
            thief = { chance = 0 },
            minSeconds = 0,
            bestPoints = 5,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6))
    local run = W.start({ 1 }, m)
    W.tick(1)
    local cars = W.cars(run, 1)
    H.eq(#cars, 5, 'five parked cars, one per spot')
    local rules = Config.Custody.parkingRules
    for _, c in ipairs(cars) do
        H.eq(c.role, 'parked', 'role parked')
        if c.spot.rule == 'free' then H.ok(c.truth ~= 'violation', 'a free spot is legal or stolen') end
        if c.truth == 'violation' then
            H.eq(c.level, rules[c.spot.rule], 'the spot rule sets the violation level (' .. c.spot.rule .. ')')
        end
        H.eq(W.model(run, c.netId).locked, 2, 'the car is locked')
    end
    for _, c in ipairs(cars) do
        W.near(1, run, c.netId)
        W.act(1, run, c.netId, 'inspect')
        W.act(1, run, c.netId, 'runPlate')
        W.decide(1, run, c.netId, BestFor(run, c))
        H.eq(c.decided and c.decided.verdict, 'best', 'Best for ' .. c.truth)
    end
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'every car decided: the objective completes')
    H.eq(run.score.shared.all_correct, 1, 'all five Best: all_correct')
    H.eq(run.participants[1].score.correct_disposition, 5, 'correct_disposition per Best decision')
    H.eq(run.score.values.correct_disposition, 5, 'at the mission\'s bestPoints')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- one decision short of Best: no all_correct, and only the Best ones earn correct_disposition
    local m = W.mission({
        {
            block = 'field_contact',
            label = 'Check the cars',
            mode = 'parked',
            cars = 5,
            returning = { chance = 0 },
            thief = { chance = 0 },
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6))
    local run = W.start({ 1 }, m)
    W.tick(1)
    local cars = W.cars(run, 1)
    -- the last car that is not stolen (a stolen car's wrong choice would fail the case) is decided wrongly
    local wrong = nil
    for _, c in ipairs(cars) do if c.truth ~= 'stolen' then wrong = c end end
    for _, c in ipairs(cars) do
        W.near(1, run, c.netId)
        W.act(1, run, c.netId, 'inspect')
        W.act(1, run, c.netId, 'runPlate')
        local choice = BestFor(run, c)
        if c == wrong then choice = choice == 'noAction' and 'cite' or 'noAction' end
        W.decide(1, run, c.netId, choice)
    end
    W.tick(2)
    H.eq(wrong and wrong.decided and wrong.decided.verdict, 'wrong', 'one car decided wrongly')
    H.eq(Obj(run, 1).status, 'done', 'every car decided')
    H.eq(run.score.shared.all_correct, nil, 'a car not decided Best: no all_correct')
    H.eq(run.participants[1].score.correct_disposition, #cars - 1, 'correct_disposition only for the Best ones')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                    3. PARKED: THE RETURNING DRIVER (once)
-- ============================================================================

do
    local m = W.mission({
        {
            block = 'field_contact',
            label = 'Check the cars',
            mode = 'parked',
            cars = 3,
            profileSet = 'test_legal',
            returning = { chance = 1, max = 1 },
            thief = { chance = 0 },
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6))
    local run = W.start({ 1 }, m)
    W.tick(1)
    local cars = W.cars(run, 1)
    W.near(1, run, cars[1].netId)
    W.decide(1, run, cars[1].netId, 'cite')
    local drivers = W.count(W.people(run, 1), function(p) return p.role == 'returning_driver' end)
    H.eq(drivers, 1, 'citing a car that is not stolen brings its driver back')
    W.near(1, run, cars[2].netId)
    W.decide(1, run, cars[2].netId, 'cite')
    H.eq(W.count(W.people(run, 1), function(p) return p.role == 'returning_driver' end), 1, 'at most once per run')
    local st = Obj(run, 1).state
    local rd = nil
    for _, t in pairs(st.contacts) do if t.returning then rd = t end end
    H.ok(
        rd ~= nil
            and (
                rd.returning.outcome == 'takes'
                or rd.returning.outcome == 'argues'
                or rd.returning.outcome == 'drives_off'
            ),
        'the outcome is rolled: ' .. tostring(rd and rd.returning.outcome)
    )
    W.near(1, run, cars[3].netId)
    W.decide(1, run, cars[3].netId, 'noAction')
    W.tick(2)
    H.eq(Obj(run, 1).status, 'active', 'the objective waits for the returning driver')
    if rd.returning.outcome == 'argues' then
        W.tick(10)
        H.eq(Obj(run, 1).status, 'active', 'an arguing driver needs Explain the citation')
        W.near(1, run, rd.netId)
        W.act(1, run, rd.netId, 'explain')
    end
    W.tick(10)
    H.eq(Obj(run, 1).status, 'done', 'resolved: the objective completes')
    H.eq(run.participants[1].score.wrong_citation, 2, 'citing legal cars costs wrong_citation (the ticket stands)')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--           4. PARKED: THE THIEF (runs, caught, one act one reward)
-- ============================================================================

local function Thief(run)
    for _, p in ipairs(W.people(run, 1)) do if p.role == 'thief' then return p end end
    return nil
end

do
    local m = W.mission({
        {
            block = 'field_contact',
            label = 'Check the cars',
            mode = 'parked',
            cars = 2,
            profileSet = 'test_stolen',
            returning = { chance = 0 },
            thief = { chance = 1, runAt = 15.0 },
            escapeFails = false,
            custody = 'cuff',
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6))
    local run = W.start({ 1 }, m)
    W.tick(1)
    local cars = W.cars(run, 1)
    W.near(1, run, cars[1].netId)
    W.act(1, run, cars[1].netId, 'inspect')
    local th = Thief(run)
    H.ok(th ~= nil, 'the first inspect of a stolen car finds the thief nearby')
    W.act(1, run, cars[2].netId, 'inspect')
    H.eq(W.count(W.people(run, 1), function(p) return p.role == 'thief' end), 1, 'one thief per run')
    H.reset()
    W.near(1, run, th.netId, 10.0)
    W.tick(1)
    local acts = H.findEvents('crimson-police:client:contactAct')
    H.eq(acts[1] and acts[1].args[1].behaviour, 'flee_on_approach', 'the thief runs once an officer is within 15 m')
    H.eq(acts[1] and acts[1].target, run.host, 'told to the run host only')
    W.tick(4)
    H.eq(th.state, 'fleeing', 'after the tell he runs')
    H.eq(th.tellSeen, 'looking', 'the tell is seen')
    -- aim: he gives up; Cuff suspect
    W.near(1, run, th.netId, 6.0)
    Report(1, run, 1, { type = 'aim', netId = th.netId })
    H.eq(th.state, 'surrendered', 'aimed at within 10 m: he gives up')
    W.near(1, run, th.netId, 1.0)
    W.tick(4)
    H.fire('crimson-police:server:npcCuff', 1, run.id, th.netId)
    H.eq(th.state, 'cuffed', 'Cuff suspect')
    H.eq(run.score.shared.subject_alive, 1, 'the catch earns subject_alive once')
    H.eq(run.participants[1].stats.arrests, 1, 'the cuff of a runner is the arrest')
    W.decide(1, run, th.netId, 'arrest')
    H.eq(th.decided.verdict, 'best', 'his Arrest is Best')
    H.eq(run.participants[1].score.correct_disposition, nil, 'with 0 points (one act, one reward)')
    H.eq(run.participants[1].stats.arrests, 1, 'one person gives exactly one arrest')
    for _, c in ipairs(cars) do
        W.near(1, run, c.netId)
        W.act(1, run, c.netId, 'runPlate')
        W.decide(1, run, c.netId, 'impound')
    end
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'completed')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a thief who escapes costs missed_arrest; parking never fails on an escape
    local m = W.mission({
        {
            block = 'field_contact',
            label = 'Check the cars',
            mode = 'parked',
            cars = 1,
            profileSet = 'test_stolen',
            returning = { chance = 0 },
            thief = { chance = 1 },
            escapeFails = false,
            custody = 'cuff',
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6))
    local run = W.start({ 1 }, m)
    W.tick(1)
    local car = W.cars(run, 1)[1]
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'inspect')
    local th = Thief(run)
    W.near(1, run, th.netId, 10.0)
    W.tick(5)
    H.eq(th.state, 'fleeing', 'the thief runs')
    W.place(1, 5000.0, 5000.0, 30.0)
    W.tick(22)
    H.eq(run.state, 'in_progress', 'an escape never fails Illegal Parking Patrol')
    H.eq(run.score.shared.missed_arrest, 1, 'it costs missed_arrest')
    H.ok(th.escaped, 'the thief is gone')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--            5. SCENE: VARIANTS, APPROACH REACTIONS, FREE TO LEAVE
-- ============================================================================

local function SceneMission(extra, second)
    local obj = {
        block = 'field_contact',
        label = 'Make contact',
        mode = 'scene',
        people = 1,
        cars = 1,
        minSeconds = 0,
        custody = 'cuff',
    }
    for k, v in pairs(extra or {}) do obj[k] = v end
    return W.mission({ obj, second or { block = 'stub_hold', label = 'After', minSeconds = 0 } }, SceneLocation(),
        { type = 'investigation' })
end

do
    -- the scene variants: someone sitting in the car, people loitering beside it, someone casing cars
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_clean', scene = { occupied_car = 1 } }))
    W.tick(1)
    local st = Obj(run, 1).state
    H.eq(st.variant, 'occupied_car', 'occupied_car')
    local p = Contact(run, 1, 'person')
    local car = Contact(run, 1, 'vehicle')
    H.eq(W.model(run, car.netId).seats[-1], run.entities[p.netId].entity, 'someone sits in the driver seat')
    H.eq(car.owner, p.netId, 'the registered owner')
    Runs.endRun(run, 'completed', 'completed')
    local run2 = W.start({ 1 }, SceneMission({ profileSet = 'test_clean', scene = { casing = 1 } }))
    W.tick(1)
    H.eq(Obj(run2, 1).state.variant, 'casing', 'casing')
    H.eq(Contact(run2, 1, 'person').vehicleOf, nil, 'someone casing cars does not own the car')
    Runs.endRun(run2, 'completed', 'completed')
end

do
    -- evasive: walks away on approach (lawful, consensual), stops when aimed at
    Demeanour('clean', 'evasive')
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_clean', scene = { loitering = 1 } }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    W.place(1, 2000.0, 1960.0, 30.0)
    W.tick(1)
    H.eq(p.walking, nil, 'nothing before an officer is within the approach distance')
    H.reset()
    W.place(1, 2000.0, 1985.0, 30.0)
    W.tick(1)
    local acts = H.findEvents('crimson-police:client:contactAct')
    H.eq(acts[1] and acts[1].args[1].behaviour, 'walk_away', 'within 25 m the evasive person walks away')
    H.ok(p.walking, 'walking')
    local view = Custody.view(run, 1, 1)
    local e = view.entries[1].kind == 'person' and view.entries[1] or view.entries[2]
    H.eq(e.freeToLeave, true, 'Not detained: free to leave')
    W.near(1, run, p.netId, 8.0)
    Report(1, run, 1, { type = 'aim', netId = p.netId })
    H.eq(p.state, 'contacted', 'aimed at: they stop')
    H.eq(p.walking, false, 'no longer walking')
    H.eq(run.participants[1].score.missed_arrest, nil, 'walking away changes nothing')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a clean person walking off a consensual contact leaves; nobody is penalised
    Demeanour('clean', 'evasive')
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_clean', scene = { loitering = 1 } }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    local car = Contact(run, 1, 'vehicle')
    W.place(1, 2000.0, 1985.0, 30.0)
    W.tick(1)
    W.model(run, p.netId).coords = vec3(2500.0, 2000.0, 30.0)
    W.tick(22)
    H.ok(p.escaped, 'they walked off')
    H.eq(run.state, 'in_progress', 'no fail')
    H.eq(run.score.shared.missed_arrest, nil, 'no penalty')
    W.near(1, run, car.netId)
    W.decide(1, run, car.netId, 'noAction')
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'the objective completes without a decision for them')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- runner: runs on approach; an escape fails the case (escapeFails)
    Demeanour('warrant', 'runner')
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_warrant', scene = { loitering = 1 } }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    W.place(1, 2000.0, 1985.0, 30.0)
    W.tick(5)
    H.eq(p.state, 'fleeing', 'a runner runs as an officer comes within the approach distance')
    H.ok(p.ran, 'ran')
    W.place(1, 9000.0, 9000.0, 30.0)
    W.tick(22)
    H.eq(run.state, 'ended', 'an escape fails the case')
    H.eq(run.failReason, 'block.field_contact.fail_escaped', 'with the escape key')
    RestoreDemeanour()
end

do
    -- hostile: a tell, then the draw; the weapon is given only when the tell ends
    Demeanour('armed', 'hostile')
    W.weapons = {}
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_armed', scene = { loitering = 1 } }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    H.eq(#W.weapons, 0, 'an armed contact spawns with no weapon')
    H.eq(run.entities[p.netId].armedTruth, true, 'armedTruth counts toward the caps')
    local bag = W.bags[run.entities[p.netId].entity].cp
    H.eq(bag.armed, false, 'its bag says unarmed')
    H.eq(bag.cfg and bag.cfg.weapon, nil, 'with no weapon in its cfg')
    H.reset()
    W.place(1, 2000.0, 1990.0, 30.0)
    W.tick(1)
    local acts = H.findEvents('crimson-police:client:contactAct')
    H.eq(acts[1] and acts[1].args[1].behaviour, 'tell_then_draw', 'the host is told to play the tell')
    local secs = acts[1] and acts[1].args[1].seconds or 0
    H.ok(secs >= 1.5 and secs <= 3.0, 'a 1.5-3 s tell')
    local huds = H.findEvents('crimson-police:client:hud')
    local hinted = W.count(huds, function(e)
        return e.target == 1 and W.contains(cjson.encode(e.args[2]), 'custody.tell.hands')
    end)
    H.eq(hinted, 1, 'participants within 25 m get the hint')
    H.eq(#W.weapons, 0, 'no weapon during the tell')
    H.eq(p.tellSeen, nil, 'tellSeen is set only after the tell played')
    W.tick(4)
    H.eq(#W.weapons, 1, 'the weapon is given when the tell ends')
    H.eq(p.state, 'hostile', 'then they fight')
    H.eq(p.tellSeen, 'hands', 'the tell is now seen')
    -- killing a person who drew is lawful
    local mdl = W.model(run, p.netId)
    mdl.killer = 100
    mdl.health = 0
    W.tick(2)
    H.eq(run.state, 'in_progress', 'killing a person who drew does not fail the case')
    H.ok(p.dead, 'dead')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- killing a person who never drew fails the case
    Demeanour('clean', 'compliant')
    local run = W.start({ 1 }, SceneMission({ profileSet = 'test_clean', scene = { loitering = 1 } }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    W.place(1, 2000.0, 1990.0, 30.0)
    W.tick(1)
    H.eq(p.state, 'contacted', 'a compliant person stays and talks')
    local mdl = W.model(run, p.netId)
    mdl.killer = 100
    mdl.health = 0
    W.tick(2)
    H.eq(run.state, 'ended', 'killing a person who never drew fails the case')
    H.eq(run.failReason, 'run.fail_killed_unarmed', 'run.fail_killed_unarmed')
    RestoreDemeanour()
end

do
    -- a full scene: talk, frisk, look inside, search with cause, decide; the arrest goes to transport
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 180.0, y = args.near.y, z = args.near.z }, heading = 0.0 }
    end
    Demeanour('warrant', 'compliant')
    local run = W.start({ 1, 2 },
        SceneMission({ profileSet = 'test_warrant', scene = { loitering = 1 }, custody = 'handover' }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    local car = Contact(run, 1, 'vehicle')
    W.near(1, run, p.netId)
    W.near(2, run, car.netId)
    W.tick(1)
    W.act(1, run, p.netId, 'talk')
    W.act(1, run, p.netId, 'detain')
    W.decide(1, run, p.netId, 'arrest')
    H.eq(p.decided.verdict, 'best', 'Arrest of a known warrant: Best')
    W.act(2, run, car.netId, 'searchVehicle')
    H.eq(run.participants[2].score.unlawful_search, nil, 'an occupant arrested gives probable cause')
    W.decide(2, run, car.netId, 'impound')
    H.eq(car.decided.verdict, 'best', 'the car left unattended by the arrest: Impound Best')
    W.tick(2)
    H.eq(Obj(run, 1).status, 'active', 'the arrest still has to reach the transport')
    local van = nil
    for _, s in ipairs(Custody._servicesOf(run)) do if s.kind == 'transport' then van = s end end
    H.ok(van ~= nil, 'the van was called')
    local tp = SceneLocation().transport
    H.ok(van and U.dist(van.dest, tp) < 1.0, 'to the location\'s transport point')
    W.model(run, van.veh).coords = vec3(tp.x, tp.y, tp.z)
    W.tick(1)
    W.act(1, run, p.netId, 'escort')
    local vc = W.at(run, van.veh)
    W.place(1, vc.x + 2.0, vc.y, vc.z)
    W.model(run, p.netId).coords = vec3(vc.x + 3.0, vc.y, vc.z)
    W.act(1, run, 0, 'handover')
    H.eq(p.state, 'handed_over', 'handed over')
    H.eq(run.participants[1].score.unsearched_transport, nil, 'not armed: no unsearched_transport')
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'handed over: the objective completes')
    H.eq(run.participants[1].score.procedure_complete, nil, 'not searched before transport: no procedure bonus')
    RestoreDemeanour()
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- procedure_complete (ID-checked and searched before transport) and unsearched_transport
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 180.0, y = args.near.y, z = args.near.z }, heading = 0.0 }
    end
    Demeanour('armed', 'compliant')
    local run = W.start({ 1 }, SceneMission({
        profileSet = 'test_armed',
        scene = { loitering = 1 },
        cars = 0,
        custody = 'handover',
        people = 2,
    }))
    W.tick(1)
    local a, b = Contact(run, 1, 'person', 1), Contact(run, 1, 'person', 2)
    W.place(1, 2003.0, 1995.0, 30.0)
    W.tick(1)
    for _, c in ipairs({ a, b }) do
        W.near(1, run, c.netId, 1.0)
        W.act(1, run, c.netId, 'talk')
        W.act(1, run, c.netId, 'frisk')
        W.act(1, run, c.netId, 'detain')
        W.decide(1, run, c.netId, 'arrest')
    end
    W.act(1, run, a.netId, 'searchPerson')
    local van = nil
    for _, s in ipairs(Custody._servicesOf(run)) do if s.kind == 'transport' then van = s end end
    W.tick(2)
    local tp = SceneLocation().transport
    W.model(run, van.veh).coords = vec3(tp.x, tp.y, tp.z)
    W.tick(1)
    local vc = W.at(run, van.veh)
    for _, c in ipairs({ a, b }) do
        W.near(1, run, c.netId, 1.0)
        W.act(1, run, c.netId, 'escort')
        W.place(1, vc.x + 2.0, vc.y, vc.z)
        W.model(run, c.netId).coords = vec3(vc.x + 3.0, vc.y, vc.z)
        W.act(1, run, 0, 'handover')
    end
    H.eq(run.participants[1].score.unsearched_transport, nil, 'a frisk counts as searching an armed person')
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'both handed over')
    H.eq(run.participants[1].score.procedure_complete, nil, 'one of them was never searched: no procedure bonus')
    RestoreDemeanour()
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- procedure_complete once per officer; an armed person handed over unsearched costs unsearched_transport
    W.roadPoint = function(_, args)
        return { coords = { x = args.near.x + 180.0, y = args.near.y, z = args.near.z }, heading = 0.0 }
    end
    Demeanour('warrant', 'compliant')
    Demeanour('armed', 'compliant')
    local function Handover(run, c)
        local van = nil
        for _, s in ipairs(Custody._servicesOf(run)) do if s.kind == 'transport' then van = s end end
        if van.status ~= 'parked' then
            local tp = SceneLocation().transport
            W.model(run, van.veh).coords = vec3(tp.x, tp.y, tp.z)
            W.tick(1)
        end
        W.near(1, run, c.netId, 1.0)
        W.act(1, run, c.netId, 'escort')
        local vc = W.at(run, van.veh)
        W.place(1, vc.x + 2.0, vc.y, vc.z)
        W.model(run, c.netId).coords = vec3(vc.x + 3.0, vc.y, vc.z)
        W.act(1, run, 0, 'handover')
    end
    local run = W.start({ 1 },
        SceneMission({ profileSet = 'test_warrant', scene = { loitering = 1 }, cars = 0, custody = 'handover' }))
    W.tick(1)
    local p = Contact(run, 1, 'person')
    W.place(1, 2003.0, 1995.0, 30.0)
    W.tick(1)
    W.near(1, run, p.netId, 1.0)
    W.act(1, run, p.netId, 'talk')
    W.act(1, run, p.netId, 'detain')
    W.decide(1, run, p.netId, 'arrest')
    W.act(1, run, p.netId, 'searchPerson')
    W.tick(2)
    Handover(run, p)
    W.tick(2)
    H.eq(Obj(run, 1).status, 'done', 'handed over')
    H.eq(run.participants[1].score.procedure_complete, 1,
        'ID-checked and searched before transport: procedure_complete')
    Runs.endRun(run, 'completed', 'completed')
    local run2 = W.start({ 1 },
        SceneMission({ profileSet = 'test_armed', scene = { loitering = 1 }, cars = 0, custody = 'handover' }))
    W.tick(1)
    local q = Contact(run2, 1, 'person')
    W.place(1, 2003.0, 1995.0, 30.0)
    W.tick(1)
    W.near(1, run2, q.netId, 1.0)
    W.act(1, run2, q.netId, 'talk')
    W.act(1, run2, q.netId, 'detain')
    W.decide(1, run2, q.netId, 'arrest')
    W.tick(2)
    Handover(run2, q)
    H.eq(run2.participants[1].score.unsearched_transport, 1, 'an armed person handed over unsearched: -10')
    RestoreDemeanour()
    W.roadPoint = nil
    Runs.endRun(run2, 'completed', 'completed')
end

-- ============================================================================
--              6. STOP: TAKES run.shared.contacts FROM A PURSUIT
-- ============================================================================

local function StopMission(stub, fc, extra)
    local s = { block = 'stub_pursuit', label = 'Stop the car', minSeconds = 0 }
    for k, v in pairs(stub or {}) do s[k] = v end
    local f = { block = 'field_contact', label = 'Work the stop', mode = 'stop', minSeconds = 0, custody = 'cuff' }
    for k, v in pairs(fc or {}) do f[k] = v end
    return W.mission({ s, f, { block = 'stub_hold', label = 'After', minSeconds = 0 } }, nil, extra)
end

do
    Demeanour('clean', 'compliant')
    Demeanour('warrant', 'compliant')
    local run = W.start({ 1 }, StopMission({
        occupants = 2,
        truths = { 'clean', 'warrant' },
        observed = { kind = 'pace' },
        at = vec4(300.0, 300.0, 30.0, 0.0),
    }))
    W.tick(1)
    H.eq(run.objectiveIndex, 2, 'the pursuit handed over')
    local car = Contact(run, 2, 'vehicle')
    local ppl = W.people(run, 2)
    H.eq(#ppl, 2, 'the stop takes the car and both occupants')
    H.eq(Runs.ownerOf(run, car.netId), 2, 'adopted by the contact objective')
    H.eq(ppl[1].role, 'driver', 'the driver')
    H.eq(ppl[2].role, 'passenger', 'the passenger')
    H.eq(ppl[1].truth, 'clean', 'truths handed over by the pursuit')
    H.eq(run.shared.contacts[1].taken, 2, 'the entry is taken')
    H.eq(Custody.grade(run, ppl[1].netId, 'cite', 1).verdict, 'best',
        'an observed violation: a paced clean driver cited is Best')
    -- order out, then work them
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'orderOut')
    for _, p in ipairs(ppl) do
        H.eq(p.state, 'contacted', 'ordered out: stands by the car')
        W.leaveCar(run.entities[p.netId].entity)
    end
    W.act(1, run, ppl[2].netId, 'talk')
    W.act(1, run, ppl[2].netId, 'detain')
    W.decide(1, run, ppl[2].netId, 'arrest')
    W.decide(1, run, ppl[1].netId, 'cite')
    W.decide(1, run, car.netId, 'noAction')
    W.tick(2)
    H.eq(Obj(run, 2).status, 'done', 'every decision made: the stop is done')
    H.eq(run.decisions[1].verdict, 'best', 'the warrant arrest')
    H.eq(run.participants[1].stats.arrests, 1, 'one arrest')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a person who runs from Order out is Evading: caught, Arrest is Best
    Demeanour('clean', 'runner')
    local run = W.start({ 1 }, StopMission({ occupants = 1, truths = { 'clean' }, at = vec4(300.0, 300.0, 30.0, 0.0) }))
    W.tick(1)
    local car = Contact(run, 2, 'vehicle')
    local p = W.people(run, 2)[1]
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'orderOut')
    W.tick(4)
    H.eq(p.state, 'fleeing', 'ran from Order out')
    H.ok(p.evading, 'Evading')
    W.leaveCar(run.entities[p.netId].entity)
    W.near(1, run, p.netId, 5.0)
    Report(1, run, 2, { type = 'aim', netId = p.netId })
    W.near(1, run, p.netId, 1.0)
    W.tick(4)
    H.fire('crimson-police:server:npcCuff', 1, run.id, p.netId)
    H.eq(p.state, 'cuffed', 'caught and cuffed')
    W.decide(1, run, p.netId, 'arrest')
    H.eq(p.decided.verdict, 'best', 'a person who ran from Order out: Arrest Best')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- Stolen Vehicle Takedown: revealed = { 'stolen' } — Impound graded Best with 0 points, No action is a known error
    local run = W.start({ 1 }, StopMission(
        { occupants = 1, truths = { 'evading' }, carTruth = 'stolen', at = vec4(300.0, 300.0, 30.0, 0.0) },
        { revealed = { 'stolen' }, profileSet = 'stolenCar' }))
    W.tick(1)
    local car = Contact(run, 2, 'vehicle')
    H.ok(Custody.knownTo(run, 'stolen', car.netId, 1) ~= nil, 'the stolen plate is known from the start')
    W.near(1, run, car.netId)
    local ok, data = W.decide(1, run, car.netId, 'noAction')
    H.eq(data and data.confirm and data.confirm.factKey, 'stolen', 'No action on the known stolen car asks the confirm')
    W.decide(1, run, car.netId, 'impound')
    H.eq(car.decided.verdict, 'best', 'Impound Best')
    H.eq(run.participants[1].score.correct_disposition, nil, 'a revealed fact earns no correct_disposition')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                 7. UNDECIDED AT THE END, ONE ACT ONE REWARD
-- ============================================================================

do
    Demeanour('clean', 'compliant')
    local m = SceneMission({ profileSet = 'test_clean', scene = { loitering = 1 } })
    m.timeLimit = 60
    local run = W.start({ 1 }, m)
    W.tick(1)
    W.place(1, 2000.0, 1990.0, 30.0)
    W.tick(62)
    H.eq(run.state, 'ended', 'the time limit runs out')
    H.eq(W.count(run.decisions or {}, function(d) return d.choice == 'none' and d.verdict == 'wrong' end), 2,
        'every undecided contact counts as missed')
    H.eq(run.participants[1].score.missed_offence, 2, 'missed (-5), never a fail of its own')
    RestoreDemeanour()
end

-- ============================================================================
--                               8. THE LEAK SPEC
-- ============================================================================
-- During a full run of every mode: no bag write, client event or push carries a truth, a demeanour, a cue or an
-- armed flag of a contact before its behaviour starts; weapons appear only at the draw, after the tell.

local TRUTH_FIELDS = {
    '"truth"',
    '"demeanour"',
    '"cues"',
    '"armedTruth"',
    '"hiddenCfg"',
    '"consents"',
    '"plainView"',
    '"bolts"',
    '"admits"',
}

local function Leaks(label)
    local bad = {}
    local function scan(what, v)
        local ok, s = pcall(cjson.encode, v)
        if not ok then return end
        for _, f in ipairs(TRUTH_FIELDS) do
            if s:find(f, 1, true) then bad[#bad + 1] = ('%s carries %s'):format(what, f) end
        end
    end
    for _, w in ipairs(W.bagWrites) do scan('a bag write', w.v) end
    for _, e in ipairs(H.events) do if e.kind == 'client' then scan(e.name, e.args) end end
    for _, pu in ipairs(W.pushes) do scan('push ' .. tostring(pu.topic), pu.data) end
    H.eq(#bad, 0, label .. ': no truth field reaches a client (' .. tostring(bad[1]) .. ')')
end

-- bag writes of hidden contacts: armed/weapon/accuracy only after that ped's draw
local function ArmedBeforeDraw(run, label)
    local drawAt = {}
    for _, g in ipairs(W.weapons) do drawAt[g.h] = drawAt[g.h] or g.at end
    local early = 0
    for _, w in ipairs(W.bagWrites) do
        local v = w.v
        if w.k == 'cp' and type(v) == 'table' and v.contact
            and (v.armed == true or (type(v.cfg) == 'table' and (v.cfg.weapon or v.cfg.accuracy))) then
            if not drawAt[w.h] or w.at < drawAt[w.h] then early = early + 1 end
        end
    end
    H.eq(early, 0, label .. ': no armed flag, weapon or accuracy in a contact bag before its draw')
end

local function TellsBeforeWeapons(label)
    local tells = {}
    for _, e in ipairs(H.events) do
        if e.name == 'crimson-police:client:contactAct' and e.args[1].behaviour == 'tell_then_draw' then
            tells[#tells + 1] = e
        end
    end
    H.ok(#W.weapons <= #tells, label .. ': every weapon given follows a tell')
end

do
    -- scene, armed and hostile (the strictest case), with police actions and a push per fact
    Demeanour('armed', 'hostile')
    H.reset()
    W.bagWrites, W.weapons, W.pushes = {}, {}, {}
    local run = W.start({ 1, 2 }, SceneMission({ profileSet = 'test_armed', scene = { occupied_car = 1 }, people = 2 }))
    W.tick(1)
    local car = Contact(run, 1, 'vehicle')
    W.near(2, run, car.netId)
    W.act(2, run, car.netId, 'runPlate')
    W.act(2, run, car.netId, 'lookInside')
    local writesBeforeApproach = #W.bagWrites
    H.ok(writesBeforeApproach > 0, 'bags were written')
    Leaks('scene before the approach')
    ArmedBeforeDraw(run, 'scene before the approach')
    W.place(1, 2000.0, 1990.0, 30.0)
    W.tick(5)
    Leaks('scene after the draws')
    ArmedBeforeDraw(run, 'scene after the draws')
    TellsBeforeWeapons('scene')
    RestoreDemeanour()
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- parked and stop
    H.reset()
    W.bagWrites, W.weapons, W.pushes = {}, {}, {}
    local run = W.start({ 1 }, W.mission({
        {
            block = 'field_contact',
            label = 'Cars',
            mode = 'parked',
            cars = 5,
            returning = { chance = 1 },
            thief = { chance = 1 },
            minSeconds = 0,
        },
        { block = 'stub_hold', label = 'After', minSeconds = 0 },
    }, ParkedLocation(6)))
    W.tick(1)
    for _, c in ipairs(W.cars(run, 1)) do
        W.near(1, run, c.netId)
        W.act(1, run, c.netId, 'inspect')
        W.decide(1, run, c.netId, 'cite')
    end
    W.tick(3)
    Leaks('parked')
    ArmedBeforeDraw(run, 'parked')
    Runs.endRun(run, 'completed', 'completed')
    H.reset()
    W.bagWrites, W.weapons, W.pushes = {}, {}, {}
    Demeanour('armed', 'hostile')
    local run2 = W.start({ 1 },
        StopMission({ occupants = 3, truths = { 'armed', 'narcotics', 'clean' }, at = vec4(300.0, 300.0, 30.0, 0.0) }))
    W.tick(1)
    local car = Contact(run2, 2, 'vehicle')
    W.near(1, run2, car.netId)
    W.act(1, run2, car.netId, 'runPlate')
    Leaks('stop before Order out')
    ArmedBeforeDraw(run2, 'stop before Order out')
    W.act(1, run2, car.netId, 'orderOut')
    W.tick(4)
    Leaks('stop after Order out')
    ArmedBeforeDraw(run2, 'stop after Order out')
    TellsBeforeWeapons('stop')
    H.eq(#W.weapons, 1, 'only the armed hostile occupant draws, after the tell')
    RestoreDemeanour()
    Runs.endRun(run2, 'completed', 'completed')
end

-- ============================================================================
--               9. THE STOP-MODE FIXTURE COMPLETES AT EVERY TIER
-- ============================================================================
-- Test runs.

local function WorkEveryone(run, index)
    local car = Contact(run, index, 'vehicle')
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'orderOut')
    W.tick(4)
    for _, p in ipairs(W.people(run, index)) do
        W.leaveCar(run.entities[p.netId].entity)
        if p.state == 'hostile' then
            local mdl = W.model(run, p.netId)
            mdl.killer = 100
            mdl.health = 0
            W.tick(2)
        elseif p.state == 'fleeing' or p.state == 'idle' then
            W.near(1, run, p.netId, 5.0)
            Report(1, run, index, { type = 'aim', netId = p.netId })
            W.near(1, run, p.netId, 1.0)
            W.tick(4)
            H.fire('crimson-police:server:npcCuff', 1, run.id, p.netId)
        end
        if p.state == 'contacted' then
            W.near(1, run, p.netId)
            W.act(1, run, p.netId, 'detain')
        end
        if p.state == 'cuffed' then
            W.near(1, run, p.netId)
            W.decide(1, run, p.netId, 'arrest')
        end
    end
    W.near(1, run, car.netId)
    W.decide(1, run, car.netId, 'noAction')
    W.tick(2)
end

for _, row in ipairs(Config.Scaling) do
    local m = StopMission({ occupants = 1, at = vec4(300.0, 300.0, 30.0, 0.0) }, { profileSet = 'traffic' })
    m.scaling = { { path = 'objectives.1.occupants', max = 3 } }
    local run = W.start({ 1 }, m, { test = { adminSrc = 1, forcedTier = row.tier } })
    W.tick(1)
    local n = #W.people(run, 2)
    H.eq(n, math.min(3, U.round(1 * row.count)), 'tier ' .. row.tier .. ': occupants scale')
    WorkEveryone(run, 2)
    H.eq(Obj(run, 2).status, 'done', 'tier ' .. row.tier .. ': the field_contact fixture completes')
    Runs.endRun(run, 'completed', 'completed')
end

-- the test profile sets go again
for _, k in ipairs({ 'test_clean', 'test_warrant', 'test_armed', 'test_stolen', 'test_legal' }) do sets[k] = nil end

-- ============================================================================
--               10. Config.Custody.evidenceItem (off by default)
-- ============================================================================

do
    local function ParkedRun()
        local m = W.mission({
            {
                block = 'field_contact',
                label = 'Check the cars',
                mode = 'parked',
                cars = 5,
                returning = { chance = 0 },
                thief = { chance = 0 },
                minSeconds = 0,
            },
        }, ParkedLocation(6))
        return W.start({ 1, 2 }, m)
    end
    local inv = H.mockInventory({ evidence_bag = { label = 'Evidence bag' } })
    H.eq(Config.Custody.evidenceItem, false, 'off by default')
    local run = ParkedRun()
    W.tick(1)
    H.eq(#inv.added, 0, 'off: no evidence bag is given')
    Runs.endRun(run, 'completed', 'completed')
    Config.Custody.evidenceItem = 'evidence_bag'
    local run2 = ParkedRun()
    W.tick(1)
    H.eq(#inv.added, 2, 'on: one evidence bag per participant')
    H.eq(inv.added[1] and inv.added[1].count, 1, 'one each')
    H.eq(inv.added[1] and inv.added[1].meta.cpRun, run2.id, 'tagged with the run')
    H.eq(inv.added[1] and inv.added[1].meta.cpItem, true, 'as a mission item')
    Runs.endRun(run2, 'completed', 'completed')
    H.eq(W.count(inv.removed, function(r) return r.name == 'evidence_bag' end), 2, 'taken back when the run ends')
    Config.Custody.evidenceItem = false
    H.exportsMock.ox_inventory = nil
end

return H
