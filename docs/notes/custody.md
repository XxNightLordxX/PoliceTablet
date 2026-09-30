# Custody (WP2) · police actions, contacts, custody chain and scene processing

What WP2 built: CP.Custody (truths, facts, police actions, grading, the custody chain, the transport van, tow truck and
coroner van), the field_contact and process_scene blocks, the read-only sc-police listener, the CP.Npc custody states
and excessive-force detection, the ox_target options and the contact key, the Contact panel and the HUD contact card.
WP9 copies the API rows below into docs/ARCHITECTURE.md (§5, §7, §8).

English is the only language in this build; every text is a locale key in locales/parts/custody.json or npc.json.

## CP.Custody (modules/custody/server.lua)

Truths, demeanours and cues live only in this module's book per run (never in run.entities, a bag, an event or a push).

| Function | Meaning |
|---|---|
| `rollTruth(rng, setName, role) -> truthKey` | Config.Custody.profileSets[setName][role] (role 'person', 'driver', 'passenger', 'vehicle'; a set without the role uses person, then driver). Weighted pick over sorted keys (deterministic) |
| `rollDemeanour(rng, truthKey) -> name` | Config.Custody.demeanour[truth]; only an armed truth can roll hostile |
| `rollProfile(rng, setName, role, hasCar, truth?) -> { truth, demeanour, cues }` | Everything hidden about a person in one fixed order: cues.where ('person' or 'car', 50% for contraband with a car, never 'car' for a hostile), plainView (cues.plainView), odour (narcotics, cues.odour), admits (Config.Custody.admission), consents (consent.clean / consent.guilty), bolts (runner always, nervous 15%), minor (the offence) |
| `register(run, obj, netId, contact) -> contact` | contact = { kind, role, label, truth, demeanour, cues, vehicleOf, owner, spot, level, actions, allowWarn, observed, evading, custody, revealed, state, consensual, transportPoint, caught, ran, chain }. The bag gets only `contact = { label, kind, actions }` and the state (actions never depend on the truth). `revealed` facts are known to the run from the start |
| `get(run, netId)`, `contactsOf(run, obj|nil)` | Server-side records (sorted by net id) |
| `act(run, netId, behaviour, args)` | The only truth-derived signal to a client: `client:contactAct { runId, netId, behaviour, args, seconds }` to the run host at the moment it starts. flee_on_approach, flee_on_order and tell_then_draw play a Config.Npc.tellSeconds tell first (participants within tellRange get the `custody.tell.*` HUD hint); tell_then_draw calls CP.Runs.arm when the tell ends, then 'hostile'. Other behaviours: walk_away, leave, exit_and_stand, walk_to, drive_off. Once per behaviour per contact |
| `begin(src, runId, netId, action, extra)` / `finish(...)` | The two halves of every action (net event below). Checks: live in-progress run, active arrived participant, on duty (CP.Access.getOfficer), not in the arena, the contact's owning objective is current, the action is in its actions list, the state order, reach with server coordinates at both ends, finish ≥ Config.Custody.times[action] − actionSlack after its begin, and for actions of 3 s or more the CP.Npc dwell sampler (in reach for the time minus 2 s). A cancelled bar sends no finish and counts for nothing |
| `reveal(run, netId, factKey, src, data)` | A fact reaches the run: sentTo = every active participant now (ms and os.time), the Contact panel is pushed, a HUD line (`contact` patch) goes to them. data.suppressed = inadmissible (struck through, never graded, never a cause, never a knowing error). A suppressed fact found again lawfully is known from then on |
| `knownTo(run, factKey, netId, src) -> ms|nil` | When the server sent that (admissible) fact to that officer. A knowing error needs it ≤ the decision's begin |
| `probableCause(run, vehNetId) -> bool, sources` | plain_view, odour (intoxicated or odour_cannabis), admission, weapon (a frisk), arrest (an occupant decided Arrest), stolen, consent |
| `grade(run, netId, choice, src, beginMs) -> entry, failFact` | Pure. The CP.Runs.decide entry: the Dispositions table with the mission's `decisions` overrides (mission and objective; `{ wrongfulArrest = 'fail' }` makes that grade critical with reason.decision_fail) and Config.Decisions; Best only with the deciding fact admissible; points 0 for a caught runner or a `revealed` deciding fact |
| `enableChain(run, netId, opts)` | Custody chain after a cuff for any block: adds searchPerson, escort, seat, handover (registers a chain record when the ped is not a contact) and requests the transport. `{ type = 'handed_over', netId, src }` goes to the owning objective (CP.Runs.entityEvent) |
| `requestTransport(run, coords, { obj, point })`, `transport(run, src) -> { status, netId, distance }` | The prisoner van; a request while it is on its way or parked moves it to the new objective; one after it left sends a new van |
| `impound(run, netId, src)` | The tow truck (Config.Custody.tow; enabled = false fades the car out at once) and `{ type = 'impounded', netId }` to the owner |
| `serviceVehicle(run, kind, coords, opts) -> handle` | kind transport, tow, coroner; opts = { obj, point (parking point, default coords), target (tow: the car), decider }. See Service vehicles |
| `checkRoadPoint(run, handle, reply) -> vec4|nil` | The server check of a road point: within spawnDistance (±5 m) of the scene and 30 m from every player |
| `releaseService(run, handle)`, `serviceStatus(handle) -> status, vehNetId`, `_servicesOf(run)` | process_scene's coroner van; tests |
| `onCuffed(run, netId, src)`, `markGone(run, netId, how)`, `markDead(run, netId)` | field_contact keeps the records in step with CP.Npc's cuff, escapes, walk-offs and deaths |
| `closeObjective(run, obj) -> n` | Undecided contacts at the end: CP.Runs.decide with Config.Decisions.undecidedAtEnd (missed_offence, −5) for the officer who last worked each one (else the host); never a fail |
| `noteForce(run, netId, src)` | excessive_force (personal), at most once per person per 10 s |
| `view(run, obj, src) -> ContactView|nil` | web/src/types/custody.ts. Entries add `confirm` when this viewer has an ox_target choice waiting for the case-fail confirm. choices[].failsCase is worked out from the facts that reached this viewer only, and only for a knowing error (a mission's stricter `decisions` rule is never flagged: that would give the truth away) |

Decisions: `warn`, `cite`, `release`, `arrest` (a person; warn only where allowWarn, i.e. stops), `noAction`, `impound`
(a car), `cite` (a parked car). After a decision: citations and impounds (Best or Acceptable) → CP.Runs.noteStat for the
decider; Arrest → CP.Runs.decide calls noteArrest (Best or Acceptable only); release, warn and cite let the person go
(state released, removed after releaseDespawn); a stop car whose people were all let go drives off. A person let go
while seated in a contact car that is not yet decided waits in it (the host would drive the car away): once the car and
all its people are settled they leave with it (No action), or get out and walk off (Impound, or an arrested driver).
Config.Custody.evidenceItem (off by default): `giveEvidence(run)` on the run:inProgress hook gives each participant
of a run with a field_contact or process_scene objective one item (metadata cpRun, cpItem), added to p.items so the
engine takes it back at the end like every mission item. A failed effect (Place in vehicle, Hand over) is refused to the officer with its error key. A case-failing
choice with Config.Decisions.confirmKnownErrors decides nothing until confirmed.

Net and callbacks:

| Name | Side | Payload |
|---|---|---|
| `crimson-police:server:custody` | client → server, plain event | runId, netId, action, phase ('begin'\|'finish'), extra (`{ offence }`, `{ door = 'door_dside_f' }` for a door option). 4 per 2 s per player. `runPlateFromVehicle`, `seat` and `handover` may send netId 0: the server picks the car in front, the person this officer escorts, or everyone this officer escorts or seated |
| `server:contactDecide` | NUI action | `{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }`. The officer must be within 25 m of the contact; a confirmed choice uses the begin time of the ox_target choice that asked for it (60 s) |
| `crimson-police:server:stunHit` | client → server, plain event | netId. 2 per s. Accepted only when CP.Npc saw a ragdoll or a state change of that ped within 1 s and the ped is detained, escorted, seated or compliant |
| `crimson-police:client:contactAct` | server → run host | `{ runId, netId, behaviour, args, seconds }` |
| `crimson-police:client:contactConfirm` | server → decider | `{ netId, choice, factKey }`: the client opens the tablet and pushes `contactConfirm` to the NUI |
| `crimson-police:client:serviceVehicle` | server → driving client | `{ runId, id, op = 'drive'|'load'|'leave', kind, veh, driver, dest, target, away }`. New in this build (not in the design's §4.3 list): WP9 adds it to ARCHITECTURE §8.1 |
| `crimson-police:client:roadPoint` | ox_lib callback, server → client | `{ near, min, max }` → `{ coords, heading }` or nil |
| client action `contactAction` | NUI → client | `{ netId, action }` (the Contact panel's action buttons): closes the tablet and runs the same begin/bar/finish flow |
| push `contactConfirm` | client → NUI | the ContactConfirm shape |
| HUD patch `contact` | server → client (CP.Runs.hudFor) | `{ label, fact, hint, confirm, suppressed }` (CP.Lt tokens where translatable); `false` fields are empty |

## Service vehicles

The driving client is the nearest active participant not in the arena (else the host). It is asked for a road point
150–250 m from the scene; the server checks the answer (checkRoadPoint) and retries every 3 s. The vehicle and its
driver spawn through CP.Runs (reserved plate, caps: a spawn waits for room and is never cut), locked, and that client
gets `drive`. A driving client that leaves, is downed, enters the arena or is beyond serviceHandoff hands the AI to the
next nearest participant. Arrival = within 15 m of the parking point and below 1.5 m/s. Timeouts (serviceTimeout): no
usable road point → the van is placed at its parking point; a van not parked → placed; a tow truck not loaded → the
car fades out and counts as impounded. The tow truck loads when the car is within 8 m of the flatbed. The transport
leaves Config.Custody.transport.leaveAfter after the objective that called it is done; a coroner van leaves when
process_scene releases it; leaving vehicles are deleted 25 s later with their driver and cargo.

## CP.Npc additions (modules/npc/server.lua)

- States contacted, escorted, seated, released, handed_over, impounded. PROTECTED (shot_surrendered) gains contacted,
  escorted, seated; isNeutralised: dead, cuffed, escorted, seated, handed_over.
- excessive_force: a participant's melee hit (weaponDamageEvent, not a vehicle or a fall) or taser hit on a cuffed,
  escorted, seated or contacted ped; the health-drop fallback on a contacted, escorted or seated ped; the stun_hit
  telemetry (CP.Custody). A taser there is force, not shot_surrendered. Without CP.Custody the module keeps its own
  10 s window.
- A hidden contact (spawnPed opts.hidden) is refused 'hostile' until CP.Runs.arm gave it its weapon.
- `watch(run, netId, src, range)`, `inReachSince(run, netId, src) -> ms|nil`, `unwatch(netId, src)`: the dwell sampler
  of police actions (peds and vehicles), sampled every tick; a sample out of range restarts it.
- `stunMatches(netId, windowMs)`, `runOf(netId)`: for the stun_hit check (IsPedRagdoll is sampled every tick).
- The lethal stat (CP.Runs.noteStat) when a participant kills a ped of a suspect role (not hostages).
- Config.Custody.handcuffsItem: Cuff suspect needs the item (ox_inventory Search, never used or taken;
  err.npc_no_handcuffs).

Client (modules/npc/client.lua): ox_target options `crimson-police:contact_<action>` on peds and vehicles,
`crimson-police:custody_escort`, and per door `crimson-police:seat_<action>_<door>` (talk, warn, cite, release; bones
door_dside_f, door_pside_f, door_dside_r, door_pside_r), all reading the cp bag only; the `crimsonpolice_contact` key
(Config.Tablet.contactKey): Run plate from the driver seat, Hand over at the van, Place in vehicle near the officer's
last vehicle, Escort on/off; host tasks followPed (escort), stand (contacted), leave (released), the tells and the
contactAct behaviours; stun_hit from CEventNetworkEntityDamage. modules/custody/client.lua: the begin/bar/finish flow
(CP.Custody.perform), the confirm, the road point callback and the service vehicle driving.

## field_contact (blocks/field_contact)

Fields as in the design (2.5.2); defaults also `transport = 'transport'` (the location's transport point when it has
one), `models`, `vehicles`, `weapons` (flee_arrest's), `aliveBonus = { id = 'subject_alive' }`,
`allCorrect = { id = 'all_correct' }` (valued by Config.Bonuses; a built-in file may add points).

- parked: `cars` random kerb spots of the location's `spots` list; each car rolls the set's vehicle truth, a free spot
  never rolls a violation, a violation's level is Config.Custody.parkingRules[rule]. Returning driver (at most
  returning.max per run, returning.chance per cite or impound of a car that is not stolen): takes the ticket (60%),
  argues until Explain the citation (30%), drives off (10%, cites only). The thief (thief.chance, on the first inspect
  of a stolen car) waits 30 m away and runs once an officer is within thief.runAt.
- scene: a variant from `scene` (occupied_car, loitering, casing); people spots shuffled; the first participant within
  `approach` sets people off by demeanour (evasive: walk_away; runner: flee_on_approach; hostile: tell_then_draw;
  compliant and nervous stand, contacted). A consensual contact (scene) is free to leave: walking beyond the escape
  distance for the escape time is lawful and costs nothing.
- stop: takes the entries of `run.shared.contacts` owned by this objective (or not yet taken from an earlier one).
  The format WP3's pursuit writes: `{ vehicle = netId, occupants = { { netId, seat, state, truth } }, observed =
  { kind, speed, zone } | nil, forced = bool, profileSet = name|nil, truth = car truth|nil, taken = index|nil }`.
  occupant.state 'fleeing' or 'cuffed' marks someone who ran on foot (Evading, a caught runner when cuffed); forced =
  stopped by PIT or box-in (everyone Evading); observed gives the driver an observed violation; `revealed = { 'stolen' }`
  on the objective makes the car's plate known from the start (Stolen Vehicle Takedown). A person the pursuit spawned
  unarmed but rolled armed here gets armedTruth and a hidden weapon for the draw.
- Runners and walkers give up (surrendered, then CP.Npc's Cuff suspect) when aimed at within 10 m (client report
  `aim`), stunned (`stunned`) or when a participant stays within 3 m for 3 s; a walker stops (contacted). A runner or
  drawer cuffed through Cuff suspect is that officer's arrest (noteArrest) and earns aliveBonus once; their Arrest
  decision is then Best with 0 points.
- Escape: beyond escape.distance from every participant for escape.seconds: escapeFails → the case fails
  (block.field_contact.fail_escaped), else missed_arrest (shared) and the person is removed.
- Killing a person who never drew fails the case (run.fail_killed_unarmed); a person who drew may be killed.
- Complete when every contact is resolved: decided (an Arrest handed over when custody = 'handover'), dead, gone, and
  any returning driver done. Then all_correct (every decision Best) and procedure_complete once per officer (every
  person they arrested was ID-checked and searched). On the time limit, undecided contacts count as missed.
- A 'removed' vehicle (sc-police /imp) is marked gone and never becomes an Impound disposition; the engine fails or ends
  the run as its own rule says.

## process_scene (blocks/process_scene)

prepare: CP.Runs.holdBodies(run, { roles, max = bodies }). start: CP.Runs.pauseFastClock; the kept bodies are the list;
none → aliveBonus (shared) and it completes at once (its minSeconds drops to 0: there is nothing to process). Else the
coroner van is called to the location's `coroner` point (or the scene marker) unless `coroner = false`. Client reports
`tag_begin`/`tag`, `bag_begin`/`bag` (a body within 2.5 m), `release_begin`/`release` (the parked van within 6 m, or the
scene marker when the van is off); each finish needs the step's duration (−0.5 s) and the officer in reach for the
duration minus 2 s (sampled each tick). Bag body releases the body (CP.Runs.releaseBody) and spawns the body-bag prop;
Release deletes the bags and sends the van away. stop releases whatever is left. ox_target names crimson-police:body_tag,
crimson-police:body_bag, crimson-police:coroner.

## CP.ScPolice (modules/integrations/sc_police/server.lua)

A second, read-only `police:server:Impound` handler: when the netId is a vehicle of a live run it calls
`CP.Runs.noteExternalRemoval(netId, src, 'sc_impound', dist)` with the sender's server-side distance. It never
triggers, cancels or answers a police:* event. `ScPolice.onImpound(src, netId) -> bool`.

## Web

- `officer/components/ContactPanel.tsx` (+ .css, classes cp-contact*): replaces the Business Check log panel on Active
  Mission when view.contact has entries; facts (inadmissible struck through, causes tagged), "Not checked yet",
  "Not detained: free to leave", tells seen, probable cause per car, the transport status, the action buttons
  (client action contactAction), the dispositions (server:contactDecide; a failsCase choice or a `confirm` reply opens
  the case-fail confirm; push contactConfirm and entry.confirm open it too).
- `hud/ContactCard.tsx`: HUD patch `contact` (newest fact, tell hint, confirm waiting), using the HUD message styles.
- Active Mission also shows view.intel (run.intel.title) and the mission-call line (target, then the arrival time).
- `mocks/custody.mock.ts`: `?contact=1` pushes a sample run with a Contact panel and a HUD contact card.

## Deviations and notes for later packages

- The case-fail confirm from an ox_target choice opens the tablet on its default screen (CP.Tablet.open has no screen
  argument; WP8 owns it): the confirm shows on Active Mission, and the HUD card says to confirm there.
- Tablet decisions have no progress bar; they need the officer within 25 m of the contact.
- The mission-call line shows the response target and the arrival time only: the view carries no time since the claim
  for a live countdown (WP8 may add one to CP.Runs.view).
- tests/safety_spec.lua needed no change (it holds no NPC state checks); the arena rules are in tests/custody_spec.lua.
