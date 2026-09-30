-- CP.Custody (WP2): truths and cues, grading, knowing errors, police actions (begin/finish), facts, probable
-- cause, the custody chain, service vehicles, impound, the sc-police listener, excessive force and stats.

local W = dofile('tests/fixtures/custody/world.lua')
local H = W.H
local Runs, Custody = W.Runs, W.Custody
local U = CP.U

for src = 1, 4 do W.place(src, 100.0, 100.0, 30.0) end

-- A run whose current objective holds the contacts the checks register themselves.
local function HoldRun(members, extra)
    local m = W.mission({ { block = 'stub_hold', label = 'Hold', minSeconds = 0 } }, nil, extra)
    return W.start(members or { 1, 2 }, m)
end

local nextX = 0
-- A registered contact on objective 1. fields: kind, role, truth, cues, demeanour, vehicleOf, actions, state ...
local function Contact(run, fields)
    nextX = nextX + 3
    local at = fields.at or vec4(110.0 + nextX, 110.0, 30.0, 0.0)
    local netId
    if fields.kind == 'vehicle' then
        _, netId = Runs.spawnVehicle(run, { obj = 1, model = 'asea', coords = at, role = fields.role or 'contact_car' })
    else
        _, netId = Runs.spawnPed(run, {
            obj = 1,
            model = 'a_m_y_stbla_01',
            coords = at,
            role = fields.role or 'subject',
            hidden = true,
            armed = fields.truth == 'armed',
            weapon = 'WEAPON_PISTOL',
        })
    end
    local c = Custody.register(run, 1, netId, {
        kind = fields.kind or 'person',
        role = fields.role,
        truth = fields.truth,
        demeanour = fields.demeanour or 'compliant',
        cues = fields.cues or {},
        vehicleOf = fields.vehicleOf,
        owner = fields.owner,
        level = fields.level,
        spot = fields.spot,
        actions = fields.actions or (fields.kind == 'vehicle' and {
            'lookInside',
            'runPlate',
            'inspect',
            'orderOut',
            'searchVehicle',
            'noAction',
            'cite',
            'impound',
        } or { 'talk', 'frisk', 'detain', 'searchPerson', 'warn', 'cite', 'release', 'arrest' }),
        allowWarn = true,
        observed = fields.observed,
        evading = fields.evading,
        custody = fields.custody or 'cuff',
        revealed = fields.revealed,
        state = fields.state,
        caught = fields.caught,
    })
    return c, netId
end

-- ============================================================================
--                              1. TRUTHS AND CUES
-- ============================================================================

do
    local a = Custody.rollProfile(U.rng(77), 'scene', 'person', true)
    local b = Custody.rollProfile(U.rng(77), 'scene', 'person', true)
    H.eq(a.truth, b.truth, 'the same seed rolls the same truth')
    H.eq(a.demeanour, b.demeanour, 'and the same demeanour')
    H.eq(a.cues.where, b.cues.where, 'and the same cues')
    local counts, hostileClean = {}, 0
    for seed = 1, 400 do
        local p = Custody.rollProfile(U.rng(seed * 2654435 + 97531), 'scene', 'person', true)
        counts[p.truth] = (counts[p.truth] or 0) + 1
        if p.demeanour == 'hostile' and p.truth ~= 'armed' then hostileClean = hostileClean + 1 end
        if CP.U.contains({ 'narcotics', 'tools', 'armed' }, p.truth) == false then
            H.ok(p.cues.where == 'person', 'only contraband can be in the car')
        end
    end
    H.eq(hostileClean, 0, 'only a person rolled armed can be Hostile')
    H.ok((counts.clean or 0) > (counts.armed or 0), 'the weights hold (clean 35 > armed 8)')
    H.eq(Custody.rollTruth(U.rng(5), 'parking', 'vehicle') ~= nil, true, 'a vehicle truth from the parking set')
    H.eq(Custody.rollDemeanour(U.rng(1), 'nope'), 'compliant', 'an unknown truth is compliant')
    for seed = 1, 50 do
        local p = Custody.rollProfile(U.rng(seed * 2654435 + 97531), 'scene', 'person', false)
        H.eq(p.cues.where, 'person', 'no car: contraband is on the person')
    end
end

-- ============================================================================
--               2. GRADING: EVERY ROW OF THE DISPOSITIONS TABLE
-- ============================================================================

local function Reveal(run, c, key, src, data) return Custody.reveal(run, c.netId, key, src, data) end

do
    local run = HoldRun({ 1, 2 })
    local function G(c, choice, src) return Custody.grade(run, c.netId, choice, src or 1) end
    local function Check(c, choice, verdict, bonus, msg)
        local e = G(c, choice)
        H.eq(e and e.verdict, verdict, msg .. ': verdict')
        H.eq(e and e.bonusId, bonus, msg .. ': id')
    end
    -- clean
    local clean = Contact(run, { truth = 'clean' })
    Check(clean, 'release', 'best', 'correct_disposition', 'clean · Release')
    Check(clean, 'warn', 'ok', nil, 'clean · Warn')
    Check(clean, 'cite', 'wrong', 'wrong_citation', 'clean · Cite')
    Check(clean, 'arrest', 'wrong', 'wrongful_arrest', 'clean · Arrest')
    -- minor (found by Talk)
    local minor = Contact(run, { truth = 'minor', cues = { minor = 'open_container' } })
    Check(minor, 'cite', 'ok', nil, 'minor · Cite before the fact is known lawfully')
    Reveal(run, minor, 'minor', 1)
    Check(minor, 'cite', 'best', 'correct_disposition', 'minor · Cite')
    Check(minor, 'warn', 'ok', nil, 'minor · Warn')
    Check(minor, 'release', 'wrong', 'missed_offence', 'minor · Release')
    Check(minor, 'arrest', 'wrong', 'wrongful_arrest', 'minor · Arrest')
    -- suspended licence
    local susp = Contact(run, { truth = 'suspended', role = 'driver' })
    Reveal(run, susp, 'suspended', 1)
    Check(susp, 'cite', 'best', 'correct_disposition', 'suspended · Cite')
    Check(susp, 'release', 'wrong', 'missed_offence', 'suspended · Release')
    -- active warrant: unknown → missed_arrest; known → critical
    local warrant = Contact(run, { truth = 'warrant' })
    Check(warrant, 'release', 'wrong', 'missed_arrest', 'warrant · Release, never checked')
    Check(warrant, 'arrest', 'ok', nil, 'warrant · Arrest with no lawful fact: Acceptable')
    Reveal(run, warrant, 'warrant', 1)
    Check(warrant, 'arrest', 'best', 'correct_disposition', 'warrant · Arrest')
    local crit = G(warrant, 'release')
    H.eq(crit.verdict, 'critical', 'warrant · Release once known: fails the case')
    H.eq(crit.failKey, 'reason.known_error', 'with its key')
    -- armed: known → critical, discoverable → missed_arrest, in a car with no path → Acceptable
    local armed = Contact(run, { truth = 'armed' })
    Check(armed, 'release', 'wrong', 'missed_arrest', 'armed · Release, never frisked')
    Reveal(run, armed, 'weapon', 1)
    H.eq(G(armed, 'release').verdict, 'critical', 'armed · Release once the weapon is known')
    Check(armed, 'arrest', 'best', 'correct_disposition', 'armed · Arrest')
    local car0 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local armedCar = Contact(run, {
        truth = 'armed',
        vehicleOf = car0.netId,
        cues = { where = 'car', plainView = false, odour = false, admits = false, consents = false },
    })
    Check(armedCar, 'release', 'ok', nil, 'armed · in a car with no lawful path: Acceptable')
    H.eq(G(armedCar, 'release').discoverable, false, 'discoverable = false')
    -- narcotics: found lawfully / path open / no path
    local car1 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local narc = Contact(run,
        { truth = 'narcotics', vehicleOf = car1.netId, cues = { where = 'car', plainView = true } })
    Check(narc, 'release', 'wrong', 'missed_offence', 'narcotics · a lawful path open but not taken')
    Check(narc, 'cite', 'ok', nil, 'narcotics · Cite')
    Reveal(run, narc, 'veh_narcotics', 1)
    Check(narc, 'release', 'wrong', 'missed_arrest', 'narcotics · found lawfully, released')
    Check(narc, 'arrest', 'best', 'correct_disposition', 'narcotics · Arrest')
    local car2 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local hidden = Contact(run, {
        truth = 'narcotics',
        vehicleOf = car2.netId,
        cues = { where = 'car', plainView = false, odour = false, admits = false, consents = false },
    })
    Check(hidden, 'release', 'ok', nil, 'narcotics · no cue, no admission, refused consent: Release Acceptable')
    local tools = Contact(run, { truth = 'tools' })
    Check(tools, 'release', 'wrong', 'missed_offence', 'tools on the person · path open')
    Reveal(run, tools, 'tools', 1)
    Check(tools, 'release', 'wrong', 'missed_arrest', 'tools · found, released')
    -- intoxicated
    local drunk = Contact(run, { truth = 'intoxicated', role = 'driver' })
    Reveal(run, drunk, 'intoxicated', 1)
    Check(drunk, 'arrest', 'best', 'correct_disposition', 'intoxicated · Arrest')
    Check(drunk, 'cite', 'wrong', 'missed_arrest', 'intoxicated · Cite')
    Check(drunk, 'release', 'wrong', 'missed_arrest', 'intoxicated · Release')
    -- evading (ran from a lawful order)
    local runner = Contact(run, { truth = 'clean', evading = true })
    Check(runner, 'arrest', 'best', 'correct_disposition', 'evading · Arrest')
    Check(runner, 'cite', 'ok', nil, 'evading · Cite')
    Check(runner, 'release', 'wrong', 'missed_arrest', 'evading · Release')
    -- an observed violation makes a clean driver Minor
    local paced = Contact(run, { truth = 'clean', role = 'driver', observed = true })
    Check(paced, 'cite', 'best', 'correct_disposition', 'a clean driver who was paced and cited is Best')
    Check(paced, 'warn', 'ok', nil, 'paced · Warn')
    Check(paced, 'release', 'wrong', 'missed_offence', 'paced · Release')
    local passenger = Contact(run, { truth = 'clean', role = 'passenger', observed = nil })
    Check(passenger, 'release', 'best', 'correct_disposition', 'passengers are unaffected')
    -- cars
    local legal = Contact(run, { kind = 'vehicle', truth = 'legal' })
    Check(legal, 'noAction', 'best', 'correct_disposition', 'car legal · No action')
    Check(legal, 'cite', 'wrong', 'wrong_citation', 'car legal · Cite')
    Check(legal, 'impound', 'wrong', 'wrongful_impound', 'car legal · Impound')
    local meter = Contact(run, { kind = 'vehicle', truth = 'violation', level = 'cite', spot = { rule = 'metered' } })
    Reveal(run, meter, 'spot_meter', 1)
    Check(meter, 'cite', 'best', 'correct_disposition', 'meter · Cite')
    Check(meter, 'noAction', 'wrong', 'missed_offence', 'meter · No action')
    Check(meter, 'impound', 'wrong', 'wrongful_impound', 'meter · Impound')
    local block = Contact(run,
        { kind = 'vehicle', truth = 'violation', level = 'impound', spot = { rule = 'hydrant' } })
    Reveal(run, block, 'spot_blocking', 1)
    Check(block, 'impound', 'best', 'correct_disposition', 'blocking · Impound')
    Check(block, 'cite', 'ok', nil, 'blocking · Cite')
    Check(block, 'noAction', 'wrong', 'missed_offence', 'blocking · No action')
    local stolen = Contact(run, { kind = 'vehicle', truth = 'stolen' })
    Check(stolen, 'noAction', 'wrong', 'missed_impound', 'stolen · plate never run')
    Reveal(run, stolen, 'stolen', 1)
    H.eq(G(stolen, 'noAction').verdict, 'critical', 'stolen · No action once the plate result was known')
    H.eq(G(stolen, 'cite').verdict, 'critical', 'stolen · Cite once known')
    H.eq(G(stolen, 'cite').failKey, 'reason.known_stolen', 'with the stolen key')
    Check(stolen, 'impound', 'best', 'correct_disposition', 'stolen · Impound')
    local evid = Contact(run, { kind = 'vehicle', truth = 'legal' })
    Reveal(run, evid, 'veh_tools', 1)
    Check(evid, 'impound', 'best', 'correct_disposition', 'evidence found lawfully · Impound')
    Check(evid, 'noAction', 'wrong', 'missed_impound', 'evidence · No action')
    local ucar = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local udrv = Contact(run, { truth = 'warrant', role = 'driver', vehicleOf = ucar.netId })
    udrv.decided = { choice = 'arrest', bySrc = 1 }
    Check(ucar, 'impound', 'best', 'correct_disposition', 'left unattended by an arrest · Impound')
    Check(ucar, 'noAction', 'ok', nil, 'unattended · No action (left parked)')
    -- partner's fact: known to src 2 only when sent to them
    local pw = Contact(run, { truth = 'warrant' })
    Reveal(run, pw, 'warrant', 1)
    H.ok(Custody.knownTo(run, 'warrant', pw.netId, 2) ~= nil, 'a fact goes to every active participant')
    H.eq(Custody.knownTo(run, 'warrant', pw.netId, 3), nil, 'never to a non-participant')
    -- a revealed fact decides with 0 points; a caught runner's Arrest earns 0
    local rv = Contact(run, { kind = 'vehicle', truth = 'stolen', revealed = { 'stolen' } })
    local e = G(rv, 'impound')
    H.eq(e.verdict, 'best', 'a revealed fact: graded')
    H.eq(e.points, 0, 'and earns no correct_disposition')
    local caught = Contact(run, { truth = 'evading', evading = true, caught = true })
    H.eq(G(caught, 'arrest').points, 0, 'a caught runner: Best Arrest with 0 points')
    -- an unlawful (suppressed) fact never counts: an arrest resting only on it is Acceptable
    local sup = Contact(run, {
        truth = 'narcotics',
        vehicleOf = car2.netId,
        cues = { where = 'car', plainView = false, odour = false, admits = false, consents = false },
    })
    Reveal(run, sup, 'veh_narcotics', 1, { suppressed = true })
    H.eq(G(sup, 'arrest').verdict, 'ok', 'an arrest resting only on inadmissible facts: Acceptable')
    -- a mission's decisions make a grade stricter
    run.mission.decisions = { wrongfulArrest = 'fail' }
    local strict = G(clean, 'arrest')
    H.eq(strict.verdict, 'critical', 'decisions = { wrongfulArrest = \'fail\' } fails the case')
    run.mission.decisions = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--            3. EACH ACTION: REFUSALS, ONCE, CANCELLED, RATE LIMIT
-- ============================================================================

local function Facts(c)
    local out = {}
    for _, f in ipairs(c.facts) do out[#out + 1] = f.key .. (f.suppressed and '!' or '') end
    table.sort(out)
    return table.concat(out, ',')
end

do
    local run = HoldRun({ 1, 2, 4 })
    run.participants[4].arrived = false
    local p = Contact(run, { truth = 'warrant', state = 'contacted' })
    local function Talk(src) W.act(src, run, p.netId, 'talk') end
    W.near(3, run, p.netId)
    Talk(3)
    H.eq(Facts(p), '', 'a non-participant can\'t act')
    H.eq(W.lastNote(3).key, 'err.npc_not_on_run', 'and is told why')
    W.near(4, run, p.netId)
    Talk(4)
    H.eq(Facts(p), '', 'a participant who has not arrived can\'t act')
    H.eq(W.lastNote(4).key, 'err.npc_not_arrived', 'not arrived')
    W.near(1, run, p.netId)
    -- off duty and in the arena are checked at both halves (set only around the event: the engine's own
    -- rechecks would take the officer off the run)
    W.offDuty[1] = true
    W.begin(1, run, p.netId, 'talk')
    W.offDuty[1] = nil
    H.eq(W.lastNote(1).key, 'err.npc_not_officer', 'off duty: refused')
    W.arena[1] = true
    W.begin(1, run, p.netId, 'talk')
    W.arena[1] = nil
    H.eq(W.lastNote(1).key, 'err.npc_in_arena', 'in the arena: refused')
    W.begin(1, run, p.netId, 'talk')
    H.advance(4200)
    W.arena[1] = true
    W.finish(1, run, p.netId, 'talk')
    W.arena[1] = nil
    H.eq(Facts(p), '', 'entering the arena during the bar: the finish is refused')
    W.near(1, run, p.netId, 8.0)
    Talk(1)
    H.eq(W.lastNote(1).key, 'err.npc_too_far', 'out of reach at begin')
    W.near(1, run, p.netId)
    W.begin(1, run, p.netId, 'talk')
    H.advance(4200)
    W.near(1, run, p.netId, 9.0)
    W.finish(1, run, p.netId, 'talk')
    H.eq(Facts(p), '', 'out of reach at finish: refused')
    W.near(1, run, p.netId)
    W.finish(1, run, p.netId, 'talk')
    H.eq(W.lastNote(1).key, 'err.npc_too_fast', 'a finish without a begin is refused')
    W.begin(1, run, p.netId, 'talk')
    H.advance(2000)
    W.finish(1, run, p.netId, 'talk')
    H.eq(Facts(p), '', 'a finish earlier than its time minus actionSlack is refused')
    -- sampled every second: stepping out of reach for a sample breaks the dwell
    W.begin(1, run, p.netId, 'talk')
    H.advance(1100)
    W.near(1, run, p.netId, 6.0)
    H.advance(1100)
    W.near(1, run, p.netId)
    H.advance(2100)
    W.finish(1, run, p.netId, 'talk')
    H.eq(Facts(p), '', 'an action of 3 s or more is sampled every second while it runs')
    -- a cancelled bar sends no finish and counts for nothing
    W.begin(1, run, p.netId, 'talk')
    H.advance(5000)
    H.eq(Facts(p), '', 'a cancelled bar counts for nothing')
    -- the wrong state
    W.begin(1, run, p.netId, 'searchPerson')
    H.eq(W.lastNote(1).key, 'err.custody_state', 'Search person needs a detained person')
    W.begin(1, run, p.netId, 'arrest')
    H.eq(W.lastNote(1).key, 'err.custody_not_detained', 'Arrest needs a detained person')
    -- accepted
    Talk(1)
    H.eq(Facts(p), 'id_ok,warrant', 'accepted: Talk reveals ID and the warrant')
    local n = #p.facts
    Talk(1)
    H.eq(#p.facts, n, 'a second Talk reveals nothing new')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- rate limit: 4 custody events per 2 s per player
    local run = HoldRun({ 1 })
    local p = Contact(run, { truth = 'clean', state = 'contacted' })
    W.near(1, run, p.netId)
    -- Release takes 2 s: a finish 1.7 s after its begin is in time, but it is the fifth event within 2 s
    for _ = 1, 4 do H.fire('crimson-police:server:custody', 1, run.id, p.netId, 'release', 'begin') end
    H.advance(1700)
    H.fire('crimson-police:server:custody', 1, run.id, p.netId, 'release', 'finish')
    H.eq(p.decided, nil, 'the fifth event within 2 s is dropped')
    H.advance(400)
    W.act(1, run, p.netId, 'detain')
    H.eq(p.state, 'cuffed', 'Detain after the window')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                      4. FACTS: WHAT EACH ACTION REVEALS
-- ============================================================================

do
    local run = HoldRun({ 1, 2 })
    local car = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local drv = Contact(run, {
        truth = 'warrant',
        role = 'driver',
        vehicleOf = car.netId,
        state = 'contacted',
        cues = { where = 'person', consents = false },
    })
    car.owner = drv.netId
    W.near(1, run, drv.netId)
    W.act(1, run, drv.netId, 'talk')
    H.eq(Facts(drv), 'id_ok,refused,warrant', 'Talk: ID, warrant, consent answer')
    local armed = Contact(run, { truth = 'armed', state = 'contacted' })
    W.near(1, run, armed.netId, 1.0)
    W.act(1, run, armed.netId, 'frisk')
    H.eq(Facts(armed), 'weapon', 'Frisk finds the weapon on the person')
    local clean = Contact(run, { truth = 'narcotics', state = 'contacted' })
    W.near(1, run, clean.netId, 1.0)
    W.act(1, run, clean.netId, 'frisk')
    H.eq(Facts(clean), 'frisk_clear', 'a frisk only finds weapons')
    W.act(1, run, clean.netId, 'detain')
    H.eq(clean.state, 'cuffed', 'Detain cuffs them')
    W.act(1, run, clean.netId, 'searchPerson')
    H.eq(Facts(clean), 'frisk_clear,narcotics', 'Search person finds everything on them')
    -- run plate: valid, the registered owner's warrant
    local car2 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local own = Contact(run, { truth = 'warrant', role = 'driver', vehicleOf = car2.netId })
    car2.owner = own.netId
    W.near(1, run, car2.netId)
    W.act(1, run, car2.netId, 'runPlate')
    H.eq(Facts(car2), 'owner_warrant,plate_valid', 'Run plate: registration and the owner\'s warrant')
    H.eq(Facts(own), 'warrant', 'the warrant is known on the owner too')
    local stolen = Contact(run, { kind = 'vehicle', truth = 'stolen' })
    W.near(1, run, stolen.netId)
    W.act(1, run, stolen.netId, 'runPlate')
    H.eq(Facts(stolen), 'stolen', 'Run plate: STOLEN')
    -- look inside: a plain-view cue
    local car3 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    Contact(run, { truth = 'narcotics', vehicleOf = car3.netId, cues = { where = 'car', plainView = true } })
    W.near(1, run, car3.netId)
    W.act(1, run, car3.netId, 'lookInside')
    H.eq(Facts(car3), 'plain_view', 'Look inside: the item in plain view')
    local car4 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    W.near(1, run, car4.netId)
    W.act(1, run, car4.netId, 'lookInside')
    H.eq(Facts(car4), 'plain_clear', 'Look inside: nothing')
    -- inspect a parked car
    local park = Contact(run, {
        kind = 'vehicle',
        role = 'parked',
        truth = 'violation',
        level = 'impound',
        spot = { rule = 'hydrant', street = 'Alta Street' },
    })
    W.near(1, run, park.netId)
    W.act(1, run, park.netId, 'inspect')
    H.eq(Facts(park), 'spot_blocking', 'Inspect: the posted rule')
    -- search vehicle without probable cause: -15 and inadmissible
    local car5 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local own5 = Contact(run, {
        truth = 'tools',
        vehicleOf = car5.netId,
        cues = { where = 'car', plainView = false, odour = false, admits = false, consents = false },
    })
    W.near(1, run, car5.netId)
    W.act(1, run, car5.netId, 'searchVehicle')
    H.eq(run.participants[1].score.unlawful_search, 1, 'a search without probable cause costs unlawful_search')
    H.eq(run.participants[2].score.unlawful_search, nil, 'personal to the searcher')
    H.eq(Facts(car5), 'veh_tools!', 'what it finds is inadmissible')
    H.eq(Custody.grade(run, own5.netId, 'arrest', 1).verdict, 'ok', 'and never makes an arrest Best')
    -- with probable cause the find is lawful
    local car6 = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local own6 = Contact(run,
        { truth = 'narcotics', vehicleOf = car6.netId, cues = { where = 'car', plainView = true } })
    W.near(1, run, car6.netId)
    W.act(1, run, car6.netId, 'lookInside')
    W.act(1, run, car6.netId, 'searchVehicle')
    H.eq(Facts(car6), 'plain_view,veh_narcotics', 'a lawful search finds the narcotics')
    H.eq(run.participants[1].score.unlawful_search, 1, 'and costs nothing')
    H.eq(Custody.grade(run, own6.netId, 'arrest', 1).verdict, 'best', 'Best with the lawful find')
    -- a fact reveal reaches only participants
    local pushedTo = {}
    for _, pu in ipairs(W.pushes) do if pu.topic == 'run' then pushedTo[pu.src] = true end end
    H.ok(pushedTo[1] and pushedTo[2], 'the Contact panel is pushed to the participants')
    H.eq(pushedTo[3], nil, 'never to anyone else')
    local huds = H.findEvents('crimson-police:client:hud')
    H.eq(W.count(huds, function(e) return e.target == 3 end), 0, 'no HUD fact line for a non-participant')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                     5. PROBABLE CAUSE: THE SEVEN SOURCES
-- ============================================================================

do
    local run = HoldRun({ 1 })
    local function Pair(personTruth, cues)
        local car = Contact(run, { kind = 'vehicle', truth = 'legal' })
        local p = Contact(run, { truth = personTruth or 'clean', vehicleOf = car.netId, cues = cues or {} })
        return car, p
    end
    local car0 = Pair()
    H.eq(Custody.probableCause(run, car0.netId), false, 'no source: no probable cause')
    local sources = {
        {
            'plain_view',
            function(car) Reveal(run, car, 'plain_view', 1) end,
        },
        {
            'odour',
            function(_, p) Reveal(run, p, 'odour_cannabis', 1) end,
        },
        {
            'odour',
            function(_, p) Reveal(run, p, 'intoxicated', 1) end,
        },
        {
            'admission',
            function(_, p) Reveal(run, p, 'admission', 1) end,
        },
        {
            'weapon',
            function(_, p) Reveal(run, p, 'weapon', 1) end,
        },
        {
            'arrest',
            function(_, p) p.decided = { choice = 'arrest', bySrc = 1 } end,
        },
        {
            'stolen',
            function(car) Reveal(run, car, 'stolen', 1) end,
        },
        {
            'consent',
            function(_, p) Reveal(run, p, 'consent', 1) end,
        },
    }
    for _, sdef in ipairs(sources) do
        local car, p = Pair()
        sdef[2](car, p)
        local ok, list = Custody.probableCause(run, car.netId)
        H.eq(ok, true, 'probable cause from ' .. sdef[1])
        H.ok(U.contains(list, sdef[1]), 'the source is named: ' .. sdef[1])
    end
    local car, p = Pair()
    Reveal(run, p, 'refused', 1)
    H.eq(Custody.probableCause(run, car.netId), false, 'a refusal is no cause')
    local carS = Pair()
    Reveal(run, carS, 'plain_view', 1, { suppressed = true })
    H.eq(Custody.probableCause(run, carS.netId), false, 'an inadmissible fact is no cause')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--            6. KNOWING ERRORS: CONFIRM FIRST, THEN THE CASE FAILS
-- ============================================================================

do
    local run = HoldRun({ 1, 2 })
    local p = Contact(run, { truth = 'warrant', state = 'contacted' })
    W.near(1, run, p.netId)
    W.act(1, run, p.netId, 'talk')
    local ok, data = W.decide(1, run, p.netId, 'release')
    H.eq(ok, true, 'the tablet asks first')
    H.eq(data and data.confirm and data.confirm.factKey, 'warrant', 'with the fact that fails the case')
    H.eq(p.decided, nil, 'nothing is decided without the confirm')
    H.eq(run.state, 'in_progress', 'the case is still open')
    -- an ox_target choice never runs straight: client:contactConfirm, nothing decided
    H.reset()
    W.act(1, run, p.netId, 'release')
    local cf = H.findEvents('crimson-police:client:contactConfirm')
    H.eq(#cf, 1, 'an ox_target choice that would fail the case sends client:contactConfirm')
    H.eq(cf[1] and cf[1].target, 1, 'to the decider')
    H.eq(cf[1] and cf[1].args[1].factKey, 'warrant', 'naming the fact')
    H.eq(p.decided, nil, 'and decides nothing')
    local view = Custody.view(run, 1, 1)
    local entry = nil
    for _, e in ipairs(view.entries) do if e.netId == p.netId then entry = e end end
    H.eq(entry and entry.confirm and entry.confirm.choice, 'release', 'the Contact panel holds the confirm')
    local rel = nil
    for _, c in ipairs(entry.choices) do if c.id == 'release' then rel = c end end
    H.eq(rel and rel.failsCase, true, 'the choice is marked as failing the case')
    ok = W.decide(1, run, p.netId, 'release', { confirmed = true })
    H.eq(run.state, 'ended', 'confirmed: the case fails for the unit')
    H.eq(run.failReason, 'reason.known_error', 'with the knowing-error reason')
    H.eq(W.row(run.id, 'CUS2').state, 'failed', 'for everyone')
end

do
    -- releasing a person whose warrant was never checked costs -15 and does not fail
    local run = HoldRun({ 1 })
    local p = Contact(run, { truth = 'warrant', state = 'contacted' })
    W.near(1, run, p.netId)
    local ok, data = W.decide(1, run, p.netId, 'release')
    H.eq(ok and data and data.ok, true, 'decided')
    H.eq(run.state, 'in_progress', 'no fail')
    H.eq(run.participants[1].score.missed_arrest, 1, 'missed_arrest')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a STOLEN result that reaches the decider after their Cite began: an unknowing mistake
    local run = HoldRun({ 1, 2 })
    local car = Contact(run, { kind = 'vehicle', role = 'parked', truth = 'stolen' })
    W.near(1, run, car.netId)
    W.near(2, run, car.netId, -1.0)
    W.begin(1, run, car.netId, 'cite')
    H.advance(1000)
    W.act(2, run, car.netId, 'runPlate')
    H.eq(Facts(car), 'stolen', 'the partner\'s plate result arrives while the bar runs')
    H.advance(2500)
    W.finish(1, run, car.netId, 'cite')
    H.eq(car.decided and car.decided.choice, 'cite', 'the Cite is decided')
    H.eq(car.decided and car.decided.verdict, 'wrong', 'graded as the unknowing mistake')
    H.eq(run.state, 'in_progress', 'not a case fail')
    H.eq(run.participants[1].score.missed_impound, 1, 'missed_impound for the decider')
    H.eq(run.participants[2].score.missed_impound, nil, 'a partner\'s mistake never costs you points')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- one decision per contact; decision points only to the decider
    local run = HoldRun({ 1, 2 })
    local p = Contact(run, { truth = 'clean', state = 'contacted' })
    W.near(1, run, p.netId)
    W.near(2, run, p.netId)
    W.decide(1, run, p.netId, 'release')
    local ok = W.decide(2, run, p.netId, 'cite')
    H.eq(ok, false, 'a second decision is refused')
    H.eq(run.participants[1].score.correct_disposition, 1, 'Best to the decider')
    H.eq(run.participants[2].score.correct_disposition, nil, 'not the partner')
    H.eq(#run.decisions, 1, 'one ledger entry')
    local far = Contact(run, { truth = 'clean', state = 'contacted' })
    W.near(2, run, far.netId, 40.0)
    H.eq((W.decide(2, run, far.netId, 'release')), false, 'a tablet decision needs the officer at the scene')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                 7. DOOR OPTIONS AND RUN PLATE FROM A VEHICLE
-- ============================================================================
-- No world target.

do
    local run = HoldRun({ 1 })
    local car = Contact(run, { kind = 'vehicle', truth = 'legal', at = vec4(150.0, 150.0, 30.0, 0.0) })
    local drv = Contact(run, { truth = 'warrant', role = 'driver', vehicleOf = car.netId })
    local pas = Contact(run, { truth = 'clean', role = 'passenger', vehicleOf = car.netId })
    SetPedIntoVehicle(run.entities[drv.netId].entity, run.entities[car.netId].entity, -1)
    SetPedIntoVehicle(run.entities[pas.netId].entity, run.entities[car.netId].entity, 2)
    W.place(1, 151.5, 150.0, 30.0)
    W.act(1, run, car.netId, 'talk', { door = 'door_dside_f' })
    H.eq(Facts(drv), 'id_ok,refused,warrant', 'the driver door reaches the seated driver (GetPedInVehicleSeat)')
    H.eq(Facts(pas), '', 'and only the driver')
    W.act(1, run, car.netId, 'talk', { door = 'door_pside_r' })
    H.eq(Facts(pas), 'clear,id_ok,refused', 'the rear passenger door reaches the rear passenger')
    W.act(1, run, car.netId, 'frisk', { door = 'door_dside_f' })
    H.eq(Facts(drv), 'id_ok,refused,warrant', 'a seated person can\'t be frisked')
    -- Order out: they get out and stand (or react by demeanour)
    W.act(1, run, car.netId, 'orderOut')
    H.eq(drv.state, 'contacted', 'Order out: the driver stands by the car')
    H.eq(pas.state, 'contacted', 'and the passenger')
    -- Run plate from a vehicle: the nearest contact car within 20 m in front of the officer's car
    local myCar = H.entity(29001, { kind = 'vehicle', coords = vec3(150.0, 135.0, 30.0), heading = 0.0 })
    local behind = Contact(run, { kind = 'vehicle', truth = 'stolen', at = vec4(150.0, 128.0, 30.0, 0.0) })
    local far = Contact(run, { kind = 'vehicle', truth = 'stolen', at = vec4(150.0, 170.0, 30.0, 0.0) })
    myCar.seats[-1] = 100
    H.players[1].vehicle = myCar.handle
    W.place(1, 150.0, 135.0, 30.0)
    W.act(1, run, 0, 'runPlateFromVehicle')
    H.eq(Facts(car), 'plate_valid', 'the car 15 m in front is run')
    H.eq(Facts(behind), '', 'not the one behind')
    H.eq(Facts(far), '', 'not one beyond 20 m')
    myCar.heading = 180.0
    W.act(1, run, 0, 'runPlateFromVehicle')
    H.eq(Facts(behind), 'stolen', 'turned round, the car now in front is run')
    myCar.seats[-1] = nil
    H.players[1].vehicle = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--            8. THE CUSTODY CHAIN AND THE TRANSPORT VAN (two stops)
-- ============================================================================

local function RoadNear(dist)
    return function(_, args)
        return { coords = { x = args.near.x + dist, y = args.near.y, z = args.near.z }, heading = 90.0 }
    end
end

local function Service(run, kind)
    local b = nil
    for _, s in ipairs(CP.Custody._servicesOf and CP.Custody._servicesOf(run) or {}) do
        if s.kind == kind and s.status ~= 'gone' then b = s end
    end
    return b
end

do
    W.roadPoint = RoadNear(200.0)
    local m = W.mission({
        { block = 'stub_hold', label = 'Stop one', minSeconds = 0 },
        { block = 'stub_hold', label = 'Stop two', minSeconds = 0 },
    })
    local run = W.start({ 1, 2 }, m)
    local p = Contact(run, { truth = 'warrant', state = 'contacted', custody = 'handover' })
    W.near(1, run, p.netId)
    W.near(2, run, p.netId, 60.0)
    W.act(1, run, p.netId, 'talk')
    W.act(1, run, p.netId, 'detain')
    local ok = W.decide(1, run, p.netId, 'arrest')
    H.eq(ok, true, 'Arrest')
    H.eq(p.decided.verdict, 'best', 'graded Best (the warrant was found lawfully)')
    local van = Service(run, 'transport')
    H.ok(van ~= nil, 'the first arrest calls the prisoner transport')
    W.tick(2)
    H.eq(W.roadAsks[#W.roadAsks].src, 1, 'the nearest participant is asked for the road point')
    H.eq(van.status, 'coming', 'the van spawns at the checked road point')
    local drive = H.findEvents('crimson-police:client:serviceVehicle')
    H.eq(drive[#drive].target, 1, 'and that client drives it')
    H.eq(drive[#drive].args[1].op, 'drive', 'to its parking point')
    H.eq(W.model(run, van.veh).locked, 2, 'the van is locked')
    H.ok(Runs.isMissionPlate(W.model(run, van.veh).plate), 'with a reserved plate')
    -- it arrives and parks
    local dest = van.dest
    W.model(run, van.veh).coords = vec3(dest.x + 4.0, dest.y, dest.z)
    W.tick(1)
    H.eq(van.status, 'parked', 'parked within its parking point')
    H.eq(Custody.transport(run, 1).status, 'parked', 'transport(run) reports it')
    -- search, escort, seat, hand over
    W.act(1, run, p.netId, 'searchPerson')
    W.act(1, run, p.netId, 'escort')
    H.eq(p.state, 'escorted', 'Escort')
    H.eq(W.bags[run.entities[p.netId].entity].cp.escortBy, 1, 'the bag names the escorting officer')
    H.ok(CP.Npc.isNeutralised(p.netId), 'an escorted person is neutralised')
    local cruiser = H.entity(29002, { kind = 'vehicle', coords = vec3(0.0, 0.0, 30.0) })
    run.participants[1].vehicle.lastNetId = 29002
    local pc = W.at(run, p.netId)
    cruiser.coords = vec3(pc.x + 3.0, pc.y, pc.z)
    W.act(1, run, p.netId, 'seat')
    H.eq(p.state, 'seated', 'Place in vehicle: the rear seat of the officer\'s car')
    H.eq(cruiser.seats[1], run.entities[p.netId].entity, 'rear left seat')
    H.ok(CP.Npc.isNeutralised(p.netId), 'a seated person is neutralised (can\'t escape)')
    -- hand over at the van's rear doors, with the car within 20 m
    local vc = W.at(run, van.veh)
    cruiser.coords = vec3(vc.x + 30.0, vc.y, vc.z)
    W.model(run, p.netId).coords = cruiser.coords
    W.place(1, vc.x + 2.0, vc.y, vc.z)
    W.act(1, run, 0, 'handover')
    H.eq(p.state, 'seated', 'a seated person more than 20 m from the van is not handed over')
    H.eq(W.lastNote(1).key, 'err.custody_nobody_to_hand_over', 'and the officer is told')
    cruiser.coords = vec3(vc.x + 8.0, vc.y, vc.z)
    W.model(run, p.netId).coords = cruiser.coords
    W.place(1, vc.x + 2.0, vc.y, vc.z)
    W.act(1, run, 0, 'handover')
    H.eq(p.state, 'handed_over', 'Hand over moves the seated person into the van')
    H.eq(W.model(run, van.veh).seats[1], run.entities[p.netId].entity, 'into the van')
    H.eq(run.participants[1].stats.arrests, 1, 'one arrest')
    -- the van stays while its objective runs, then leaves and is deleted
    W.tick(70)
    H.eq(van.status, 'parked', 'the van stays until its objective ends')
    Runs.objectiveComplete(run, 1)
    W.tick(61)
    H.eq(van.status, 'leaving', 'leaveAfter after the objective ended it leaves')
    W.tick(26)
    H.eq(van.status, 'gone', 'and is deleted')
    H.eq(run.entities[van.veh], nil, 'with its driver and cargo')
    -- a second stop's arrest after it left sends it again
    local q = Contact(run, { truth = 'warrant', state = 'contacted', custody = 'handover' })
    q.obj = 2
    run.entities[q.netId].obj = 2
    W.near(1, run, q.netId)
    W.act(1, run, q.netId, 'talk')
    W.act(1, run, q.netId, 'detain')
    W.decide(1, run, q.netId, 'arrest')
    local van2 = Service(run, 'transport')
    H.ok(van2 ~= nil and van2 ~= van, 'a later arrest sends the van again')
    Runs.endRun(run, 'completed', 'completed')
    W.roadPoint = nil
end

-- ============================================================================
--                             9. SERVICE VEHICLES
-- ============================================================================

do
    local run = HoldRun({ 1, 2 })
    local car = Contact(run, { kind = 'vehicle', truth = 'legal', at = vec4(500.0, 500.0, 30.0, 0.0) })
    W.place(1, 505.0, 500.0, 30.0)
    W.place(2, 900.0, 500.0, 30.0)
    -- a road point 10 m from a player, or outside spawnDistance, is refused
    W.roadPoint = function(src) return { coords = { x = 905.0, y = 500.0, z = 30.0 }, heading = 0.0 } end
    local s = Custody.serviceVehicle(run, 'transport', vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(4)
    H.eq(s.status, 'pending', 'a road point outside spawnDistance is refused')
    W.roadPoint = function() return { coords = { x = 700.0, y = 500.0, z = 30.0 }, heading = 0.0 } end
    W.place(2, 710.0, 500.0, 30.0)
    W.tick(4)
    H.eq(s.status, 'pending', 'a road point closer than 30 m to a player is refused')
    -- nobody gives a usable point: after serviceTimeout the van is placed at its parking point
    W.roadPoint = nil
    W.tick(Config.Custody.serviceTimeout + 2)
    H.eq(s.status, 'parked', 'after serviceTimeout the van is placed')
    H.ok(s.placed, 'placed, not driven')
    local vc = W.at(run, s.veh)
    H.ok(U.dist(vc, vec3(500.0, 500.0, 30.0)) < 1.0, 'at its parking point')
    -- AI hand-off: the driving client leaves or goes beyond serviceHandoff
    W.roadPoint = RoadNear(180.0)
    W.place(2, 900.0, 900.0, 30.0)
    local s2 = Custody.serviceVehicle(run, 'coroner', vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(2)
    H.eq(s2.driverSrc, 1, 'the nearest participant drives')
    H.eq(s2.status, 'coming', 'coming')
    W.place(2, 690.0, 500.0, 30.0)
    W.place(1, 1200.0, 500.0, 30.0)
    H.reset()
    W.tick(1)
    H.eq(s2.driverSrc, 2, 'beyond serviceHandoff the AI moves to the next nearest participant')
    local ev = H.findEvents('crimson-police:client:serviceVehicle')
    H.eq(ev[1] and ev[1].target, 2, 'who gets the drive order')
    Runs.removeParticipant(run, 2, 'quit')
    W.place(1, 700.0, 500.0, 30.0)
    W.tick(1)
    H.eq(s2.driverSrc, 1, 'a driving client that left hands the AI on')
    -- a van not parked within serviceTimeout is placed
    W.tick(Config.Custody.serviceTimeout + 1)
    H.eq(s2.status, 'parked', 'not parked in time: placed at its parking point')
    -- caps: spawns wait for room, they are never cut
    W.roadPoint = RoadNear(200.0)
    local fill = {}
    local okC = Runs.canSpawn(run, 1, false)
    while okC do
        local _, n = Runs.spawnObject(run, { obj = 1, model = 'prop_cone', coords = vec3(0.0, 0.0, 0.0) })
        fill[#fill + 1] = n
        okC = Runs.canSpawn(run, 1, false)
    end
    W.place(1, 505.0, 500.0, 30.0)
    W.place(2, 2000.0, 2000.0, 30.0)
    local s3 = Custody.serviceVehicle(run, 'transport', vec3(500.0, 500.0, 30.0), { obj = 1 })
    W.tick(3)
    H.eq(s3.status, 'pending', 'at the entity cap the van waits')
    Runs.deleteEntity(run, table.remove(fill))
    Runs.deleteEntity(run, table.remove(fill))
    W.tick(2)
    H.eq(s3.status, 'coming', 'with room it spawns')
    for _, n in ipairs(fill) do Runs.deleteEntity(run, n) end
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                                 10. IMPOUND
-- ============================================================================

do
    W.roadPoint = RoadNear(200.0)
    local run = HoldRun({ 1 })
    local car = Contact(run,
        { kind = 'vehicle', role = 'parked', truth = 'stolen', at = vec4(600.0, 600.0, 30.0, 0.0) })
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'runPlate')
    W.act(1, run, car.netId, 'impound')
    H.eq(car.decided and car.decided.verdict, 'best', 'Impound of a stolen car found lawfully: Best')
    H.eq(run.participants[1].stats.impounds, 1, 'impounds +1 for the decider')
    local tow = Service(run, 'tow')
    H.ok(tow ~= nil, 'a Crimson-Police tow truck is called')
    W.tick(2)
    H.eq(tow.status, 'coming', 'it drives in')
    local cc = W.at(run, car.netId)
    W.model(run, tow.veh).coords = vec3(cc.x + 3.0, cc.y, cc.z)
    W.tick(1)
    H.eq(tow.status, 'loading', 'and loads the car')
    local ev = H.findEvents('crimson-police:client:serviceVehicle')
    H.eq(ev[#ev].args[1].op, 'load', 'the driving client loads it')
    W.tick(1)
    H.eq(car.state, 'impounded', 'the car counts as impounded')
    H.eq(tow.status, 'leaving', 'and the tow truck leaves with it')
    H.ok((run.stats.vehiclesWrecked or 0) == 0, 'never as a wreck')
    Runs.endRun(run, 'completed', 'completed')
    -- with the tow truck off the car fades out and counts as impounded
    Config.Custody.tow.enabled = false
    local run2 = HoldRun({ 1 })
    local car2 = Contact(run2,
        { kind = 'vehicle', role = 'parked', truth = 'violation', level = 'impound', spot = { rule = 'hydrant' } })
    W.near(1, run2, car2.netId)
    W.act(1, run2, car2.netId, 'inspect')
    W.act(1, run2, car2.netId, 'impound')
    H.eq(car2.state, 'impounded', 'tow off: the car fades out as impounded')
    H.eq(run2.entities[car2.netId], nil, 'and is removed')
    H.eq(run2.state, 'in_progress', 'which is never a removed car')
    Config.Custody.tow.enabled = true
    Runs.endRun(run2, 'completed', 'completed')
    -- a tow truck that has not loaded the car in time fades it out
    local run3 = HoldRun({ 1 })
    local car3 = Contact(run3,
        { kind = 'vehicle', role = 'parked', truth = 'legal', at = vec4(650.0, 600.0, 30.0, 0.0) })
    W.near(1, run3, car3.netId)
    W.act(1, run3, car3.netId, 'impound')
    local tow3 = Service(run3, 'tow')
    W.tick(Config.Custody.serviceTimeout + 3)
    H.eq(car3.state, 'impounded', 'not loaded within serviceTimeout: the car fades out')
    H.eq(run3.participants[1].score.wrongful_impound, 1, 'impounding a legal car costs wrongful_impound')
    H.eq(run3.participants[1].stats.impounds, nil, 'and adds no impound to the stats')
    H.ok(tow3.status == 'leaving' or tow3.status == 'gone', 'the tow truck leaves')
    Runs.endRun(run3, 'completed', 'completed')
    -- a tow truck that parked but could not load the car within serviceTimeout fades it out
    local run4 = HoldRun({ 1 })
    local car4 = Contact(run4,
        { kind = 'vehicle', role = 'parked', truth = 'legal', at = vec4(700.0, 600.0, 30.0, 0.0) })
    W.near(1, run4, car4.netId)
    W.act(1, run4, car4.netId, 'impound')
    local tow4 = Service(run4, 'tow')
    W.tick(2)
    local c4 = W.at(run4, car4.netId)
    W.model(run4, tow4.veh).coords = vec3(c4.x + 12.0, c4.y, c4.z)
    tow4.dest = vec4(c4.x + 12.0, c4.y, c4.z, 0.0)
    W.tick(1)
    H.eq(tow4.status, 'loading', 'parked beside the car: loading')
    W.tick(Config.Custody.serviceTimeout - 5)
    H.eq(car4.state, 'stopped', 'still loading within serviceTimeout')
    W.tick(6)
    H.eq(car4.state, 'impounded', 'not loaded within serviceTimeout: the car fades out as impounded')
    H.eq(run4.entities[car4.netId], nil, 'and is removed')
    Runs.endRun(run4, 'completed', 'completed')
    W.roadPoint = nil
end

-- ============================================================================
--              11. THE SC-POLICE LISTENER (police:server:Impound)
-- ============================================================================

do
    -- a participant's /imp on a run vehicle: the objective fails, the run is flagged sc_impound
    local run = HoldRun({ 1, 2 })
    local car = Contact(run, { kind = 'vehicle', role = 'parked', truth = 'stolen' })
    W.near(1, run, car.netId, 4.0)
    W.flags = {}
    H.fire('police:server:Impound', 1, 'CPXXXXXX', true, 0, 1000.0, 1000.0, 100, car.netId)
    W.model(run, car.netId).exists = false
    W.tick(3)
    H.eq(run.state, 'ended', 'a participant\'s /imp ends the run')
    H.eq(run.failReason, 'reason.vehicle_removed', 'as Mission vehicle removed')
    H.eq(W.flags[1] and W.flags[1].reason, 'sc_impound', 'flagged sc_impound')
    H.eq(W.flags[1] and W.flags[1].src, 1, 'with the officer')
    H.eq(#(run.decisions or {}), 0, 'never an Impound disposition')
    H.eq(car.decided, nil, 'the car has no decision')
    -- a moving run vehicle counts the same
    local run2 = HoldRun({ 1 })
    local car2 = Contact(run2, { kind = 'vehicle', truth = 'legal' })
    W.model(run2, car2.netId).velocity = vec3(10.0, 0.0, 0.0)
    H.fire('police:server:Impound', 1, 'X', false, 0, 1000.0, 1000.0, 100, car2.netId)
    W.model(run2, car2.netId).exists = false
    W.tick(3)
    H.eq(run2.failReason, 'reason.vehicle_removed', 'a moving car removed by a participant fails too')
    -- a non-participant: the run ends as not counted, nobody blamed, the sender audited
    W.audits = {}
    local run3 = HoldRun({ 1, 2 })
    local car3 = Contact(run3, { kind = 'vehicle', truth = 'legal' })
    W.place(3, 400.0, 400.0, 30.0)
    H.fire('police:server:Impound', 3, 'X', false, 0, 1000.0, 1000.0, 100, car3.netId)
    W.model(run3, car3.netId).exists = false
    W.tick(3)
    H.eq(run3.state, 'ended', 'a non-participant\'s /imp ends the run')
    local r1 = W.row(run3.id, 'CUS1')
    H.eq(r1 and r1.end_reason, 'vehicle_removed_external', 'end reason vehicle_removed_external')
    H.eq(r1 and r1.state, 'abandoned', 'not counted')
    H.eq(r1 and tonumber(r1.final_points), 0, 'no points')
    H.ok(W.count(W.audits, function(a) return a[4] == 'vehicleRemoved' end) >= 1, 'the sender is audited')
    H.eq(Runs.cooldowns('CUS1').types.patrol, nil, 'no type cooldown for anyone')
    -- a vanish with nothing recorded: the same
    local run4 = HoldRun({ 1 })
    local car4 = Contact(run4, { kind = 'vehicle', truth = 'legal' })
    W.model(run4, car4.netId).exists = false
    W.tick(3)
    H.eq(W.row(run4.id, 'CUS1').end_reason, 'vehicle_removed_external', 'a vanish with nothing recorded')
    -- a wrecked car (last sample at 0) is still a wreck
    local run5 = HoldRun({ 1 })
    local car5 = Contact(run5, { kind = 'vehicle', truth = 'legal' })
    W.model(run5, car5.netId).engine = -4000.0
    W.tick(2)
    H.eq(run5.state, 'in_progress', 'a wreck is not a removal')
    Runs.endRun(run5, 'completed', 'completed')
    -- the listener ignores anything that is not a run vehicle, and Crimson-Police never triggers police:*
    H.eq(CP.ScPolice.onImpound(1, 99999), false, 'not a run vehicle: ignored')
    local ours = 0
    for _, e in ipairs(H.events) do if tostring(e.name):find('^police:') then ours = ours + 1 end end
    H.eq(ours, 0, 'Crimson-Police never triggers any police:* event')
    local handlers = H.handlers['police:server:Impound'] or {}
    H.eq(#handlers, 1, 'one read-only handler')
end

-- ============================================================================
--                        12. EXCESSIVE FORCE (stun_hit)
-- ============================================================================

do
    local run = HoldRun({ 1 })
    local p = Contact(run, { truth = 'clean', state = 'contacted' })
    W.near(1, run, p.netId)
    W.act(1, run, p.netId, 'detain')
    local m = W.model(run, p.netId)
    H.advance(1500)
    H.fire('crimson-police:server:stunHit', 1, p.netId)
    H.eq(run.participants[1].score.excessive_force, nil, 'a stun_hit that matches nothing is ignored')
    m.ragdoll = true
    H.advance(600)
    H.fire('crimson-police:server:stunHit', 1, p.netId)
    H.eq(run.participants[1].score.excessive_force, 1, 'a stun_hit that matches a ragdoll costs excessive_force')
    H.advance(600)
    H.fire('crimson-police:server:stunHit', 1, p.netId)
    H.eq(run.participants[1].score.excessive_force, 1, 'at most once per person per 10 s')
    H.advance(10500)
    H.fire('crimson-police:server:stunHit', 1, p.netId)
    H.eq(run.participants[1].score.excessive_force, 2, 'again after 10 s')
    m.ragdoll = false
    -- weaponDamageEvent: melee on a detained person; a gun is shot_surrendered
    H.advance(10500)
    H.fire('weaponDamageEvent', 1, 1, { hitGlobalIds = { p.netId }, weaponType = joaat('WEAPON_NIGHTSTICK') })
    H.eq(run.participants[1].score.excessive_force, 3, 'a melee hit on a detained person is excessive_force')
    H.eq(run.participants[1].score.shot_surrendered, nil, 'not a shot')
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--                  13. STATS: ONE ARREST PER PERSON, AND MORE
-- ============================================================================

do
    local run = HoldRun({ 1, 2 })
    local w1 = Contact(run, { truth = 'warrant', state = 'contacted' })
    local cl = Contact(run, { truth = 'clean', state = 'contacted' })
    local dr = Contact(run, { truth = 'clean', state = 'contacted' })
    local mi = Contact(run, { truth = 'minor', state = 'contacted', cues = { minor = 'loitering' } })
    local car = Contact(run,
        { kind = 'vehicle', role = 'parked', truth = 'violation', level = 'impound', spot = { rule = 'hydrant' } })
    for _, c in ipairs({ w1, cl, dr, mi }) do
        W.near(1, run, c.netId)
        W.act(1, run, c.netId, 'talk')
        W.act(1, run, c.netId, 'detain')
    end
    W.near(1, run, w1.netId)
    W.decide(1, run, w1.netId, 'arrest')
    W.near(2, run, cl.netId)
    W.decide(2, run, cl.netId, 'arrest')
    W.near(1, run, dr.netId)
    W.decide(1, run, dr.netId, 'release')
    W.near(2, run, mi.netId)
    W.decide(2, run, mi.netId, 'cite')
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'inspect')
    W.decide(1, run, car.netId, 'impound')
    local p1, p2 = run.participants[1], run.participants[2]
    H.eq(p1.stats.arrests, 1, 'an Arrest graded Best is one arrest')
    H.eq(p2.stats.arrests, nil, 'a wrongful arrest adds nothing')
    H.eq(p2.score.wrongful_arrest, 1, 'and costs wrongful_arrest')
    H.eq(p2.stats.citations, 1, 'citations (Best) for the deciding officer')
    H.eq(p1.stats.impounds, 1, 'impounds (Best) for the deciding officer')
    H.eq(p1.stats.citations, nil, 'a Detain followed by Release adds nothing')
    -- lethal: a participant kills one of the people the mission is about
    local sus = Contact(run, { truth = 'armed', state = 'idle' })
    local m = W.model(run, sus.netId)
    m.killer = 100
    m.health = 0
    W.tick(2)
    H.eq(p1.stats.lethal, 1, 'lethal for a participant who kills a suspect')
    Runs.objectiveComplete(run, 1)
    H.eq(run.state, 'ended', 'completed')
    local r1, r2 = W.row(run.id, 'CUS1'), W.row(run.id, 'CUS2')
    H.eq(tonumber(r1.arrests), 1, 'the arrest reaches the row')
    H.eq(tonumber(r2.arrests), 0, 'no arrest for the wrongful one')
    H.eq(tonumber(r2.citations), 1, 'citations on the row')
    H.eq(tonumber(r1.impounds), 1, 'impounds on the row')
    H.eq(tonumber(r1.lethal), 1, 'lethal on the row (private)')
end

-- ============================================================================
--                     14. CRIMSON-ARENA: THE ESCORT STOPS
-- ============================================================================

do
    local run = HoldRun({ 1, 2 })
    local p = Contact(run, { truth = 'warrant', state = 'contacted', custody = 'handover' })
    W.near(1, run, p.netId)
    W.act(1, run, p.netId, 'talk')
    W.act(1, run, p.netId, 'detain')
    W.decide(1, run, p.netId, 'arrest')
    W.act(1, run, p.netId, 'escort')
    H.eq(p.state, 'escorted', 'escorted')
    W.arena[1] = true
    W.tick(1)
    H.eq(p.state, 'cuffed', 'an escorting officer in the arena: the person stops and waits where they are')
    W.arena[1] = nil
    Runs.endRun(run, 'completed', 'completed')
end

-- ============================================================================
--     15. A RELEASE AT THE CAR, THE PANEL'S CASE-FAIL FLAG, MORE REFUSALS
-- ============================================================================

do
    -- a person released while seated in an undecided contact car waits in it: the host would otherwise drive
    -- the car away before anyone could decide it
    local run = HoldRun({ 1 })
    local car = Contact(run, { kind = 'vehicle', role = 'stopped_car', truth = 'legal' })
    local drv = Contact(run, { truth = 'clean', role = 'driver', vehicleOf = car.netId })
    local pas = Contact(run, { truth = 'clean', role = 'passenger', vehicleOf = car.netId })
    SetPedIntoVehicle(run.entities[drv.netId].entity, run.entities[car.netId].entity, -1)
    SetPedIntoVehicle(run.entities[pas.netId].entity, run.entities[car.netId].entity, 0)
    W.near(1, run, car.netId)
    W.act(1, run, car.netId, 'talk', { door = 'door_dside_f' })
    W.act(1, run, car.netId, 'release', { door = 'door_dside_f' })
    H.eq(drv.decided and drv.decided.verdict, 'best', 'the seated driver is released (Best)')
    H.ok(drv.state ~= 'released', 'but stays seated while the car is undecided')
    H.ok(W.bags[run.entities[drv.netId].entity].cp.state ~= 'released', 'the host is not told to drive off')
    W.decide(1, run, car.netId, 'noAction')
    H.ok(car.state ~= 'released', 'No action: the car waits for its last occupant')
    W.act(1, run, car.netId, 'release', { door = 'door_pside_f' })
    H.eq(pas.state, 'released', 'the last occupant released')
    H.eq(drv.state, 'released', 'the waiting driver leaves with the car')
    H.eq(car.state, 'released', 'and the car is released')
    W.tick(Config.Custody.releaseDespawn + 1)
    H.eq(run.entities[drv.netId], nil, 'a released person is removed releaseDespawn seconds later')
    H.eq(run.entities[car.netId], nil, 'and the released car')
    -- the car impounded: a released occupant gets out and walks off instead
    W.roadPoint = RoadNear(200.0)
    local car2 = Contact(run, { kind = 'vehicle', role = 'stopped_car', truth = 'legal' })
    local p2 = Contact(run, { truth = 'clean', role = 'driver', vehicleOf = car2.netId })
    SetPedIntoVehicle(run.entities[p2.netId].entity, run.entities[car2.netId].entity, -1)
    W.near(1, run, car2.netId)
    W.act(1, run, car2.netId, 'release', { door = 'door_dside_f' })
    H.ok(p2.state ~= 'released', 'released at the door: waits for the car')
    H.reset()
    W.act(1, run, car2.netId, 'impound')
    local acts = {}
    for _, e in ipairs(H.findEvents('crimson-police:client:contactAct')) do
        if e.args[1].netId == p2.netId then acts[#acts + 1] = e.args[1].behaviour end
    end
    H.eq(acts[1], 'exit_and_stand', 'the car impounded: the occupant gets out first')
    W.tick(4)
    H.eq(p2.state, 'released', 'then walks off')
    W.roadPoint = nil
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a mission that makes a wrong choice fail the case never marks it on the panel: that would tell the officer
    -- the truth (a clean person's Arrest)
    local run = HoldRun({ 1 })
    run.mission.decisions = { wrongfulArrest = 'fail', wrongfulImpound = 'fail' }
    local p = Contact(run, { truth = 'clean', state = 'cuffed' })
    local car = Contact(run, { kind = 'vehicle', truth = 'legal' })
    local w = Contact(run, { truth = 'warrant', state = 'cuffed' })
    Reveal(run, w, 'warrant', 1)
    local flags = {}
    for _, e in ipairs(Custody.view(run, 1, 1).entries) do
        for _, ch in ipairs(e.choices) do flags[e.label .. ':' .. ch.id] = ch.failsCase end
    end
    H.eq(flags[p.label .. ':arrest'], false, 'a stricter mission rule is not shown as failing the case')
    H.eq(flags[car.label .. ':impound'], false, 'nor for a car')
    H.eq(flags[w.label .. ':release'], true, 'a known warrant\'s Release is (a knowing error)')
    run.mission.decisions = nil
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- an action on a contact whose objective is no longer the current one is refused
    local m = W.mission({
        { block = 'stub_hold', label = 'One', minSeconds = 0 },
        { block = 'stub_hold', label = 'Two', minSeconds = 0 },
    })
    local run = W.start({ 1 }, m)
    local p = Contact(run, { truth = 'warrant', state = 'contacted' })
    Runs.objectiveComplete(run, 1)
    W.near(1, run, p.netId)
    W.act(1, run, p.netId, 'talk')
    H.eq(#p.facts, 0, 'a contact of a finished objective reveals nothing')
    H.eq(W.lastNote(1).key, 'err.custody_not_current', 'refused as not current')
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- Config.Custody.handcuffsItem: Detain needs the item (checked with ox_inventory, never taken)
    local run = HoldRun({ 1 })
    local p = Contact(run, { truth = 'clean', state = 'contacted' })
    W.near(1, run, p.netId)
    Config.Custody.handcuffsItem = 'handcuffs'
    local inv = H.mockInventory({ handcuffs = { label = 'Handcuffs' } })
    W.begin(1, run, p.netId, 'detain')
    H.eq(W.lastNote(1).key, 'err.custody_no_handcuffs', 'no handcuffs: Detain is refused at its begin')
    H.advance(3100)
    W.finish(1, run, p.netId, 'detain')
    H.eq(p.state, 'contacted', 'and nothing happens at its finish')
    inv.slots[1] = { { slot = 1, name = 'handcuffs', count = 1 } }
    W.act(1, run, p.netId, 'detain')
    H.eq(p.state, 'cuffed', 'with handcuffs in the inventory')
    H.eq(inv.removed[1], nil, 'the item is checked, never used or taken')
    Config.Custody.handcuffsItem = false
    H.exportsMock.ox_inventory = nil
    Runs.endRun(run, 'completed', 'completed')
end

do
    -- a nervous person who bolts from a frisk is Evading: caught, their Arrest is Best
    local run = HoldRun({ 1 })
    local p = Contact(run, { truth = 'clean', demeanour = 'nervous', cues = { bolts = true }, state = 'contacted' })
    W.near(1, run, p.netId)
    W.act(1, run, p.netId, 'frisk')
    W.tick(4)
    H.eq(p.state, 'fleeing', 'they run from the frisk after a tell')
    H.eq(p.tellSeen, 'looking', 'the tell was seen')
    H.ok(p.evading, 'running from a lawful frisk makes them Evading')
    H.eq(Custody.grade(run, p.netId, 'arrest', 1).verdict, 'best', 'Arrest is Best')
    H.eq(Custody.grade(run, p.netId, 'cite', 1).verdict, 'ok', 'Cite is Acceptable')
    Runs.endRun(run, 'completed', 'completed')
end

return H
