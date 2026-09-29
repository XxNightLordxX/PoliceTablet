# blocks_c · pursuit, escort, search_area

Files: `Crimson-Police/blocks/{pursuit,escort,search_area}/{server,client}.lua`,
`Crimson-Police/locales/parts/blocks_c.json`, `tests/blocks_c_spec.lua` (run: `lua5.4 tests/run.lua blocks_c`).
Each file's header lists the fields it reads (with defaults), the evidence it accepts and the ids it records.

## Evidence and messages (exact shapes)

| Block | Client → server evidence (`ctx.report`) | Server → client (`ctx.send`) |
|---|---|---|
| pursuit | `{ type='ram', netId, speed }` (km/h, pre-impact) · `{ type='lights_near', netId }` · `{ type='aim', netId }` · `{ type='stunned', netId }` · `{ type='undriveable', netId }` (own vehicle) · accepted too: `low_health`, and `cuffed` / `shot` from CP.Npc | `{ kind='state', mode, fled, trigger, lights, vehicles={ {netId,index,state,occupants} }, suspects={ {netId,vehicle,seat,state,armed} }, detained, neutralised, total, stopped, vtotal, escaping, follow={inRange,duration,hold,lost,average} }` |
| escort | `{ type='toughened', netId }` (host only) · `cuffed` / `shot` from CP.Npc | `{ kind='state', truck={netId,driver,wp,gen,stop={at,left},arrived,toughened,health,stoppedFor,stoppedFail}, waves={ {k,triggered,done,alive} }, attackers={netId}, completed }` |
| search_area | `{ type='clue_start', clue }` · `{ type='clue', clue }` · `{ type='stunned', netId }` · `cuffed` / `shot` from CP.Npc | `{ kind='state', circle={x,y,z,r,n}, clues={ {i,x,y,z,kind,model,netId,status} }, fugitives={ {netId,state} }, checked, clueTotal, arrests, neutralised, total, entered, escaping }` |

Vehicle states: `waiting` → `fleeing` → `stopped` | `wrecked`. Pursuit ped states (cp bag via `CP.Npc.setState`):
`driving` → `stopped` (told to get out) → `fleeing` | `hostile` | `surrendered` → `cuffed`, or `dead`.
Search-area fugitives: `idle` (hidden) → `fleeing` → `surrendered` → `cuffed`. Escort attackers: `hostile`, driver `driving`.
`onEvent` reject reasons are short log ids (`too_far`, `duplicate`, `wrong_state`, `implausible` …), not locale keys.

## Bonus / penalty ids recorded (all shared, `count = 1`)

- pursuit: `ramPenaltyId` (`hard_ram`; Pursuit Sim sets `ram`) per counted ram · `detainBonus` (`racer_detained`) per
  detained suspect · `allDetainedBonus` (`all_racers_detained`) once · `fastStop.id` (`vehicle_stopped_fast`) once ·
  `medal_gold` | `medal_silver` | `medal_bronze` (follow mode, only once the full `duration` was held), each with the
  Pursuit Sim card value as its `opts.points` hint (50 / 25 / 10, capped by `Config.Builder.bonusCap.points` on
  non-built-in missions), so custom follow objectives score their medals (their files cannot list medal ids).
- escort: `truck_healthy` once, when the truck's health at its arrival was above 50 %.
- search_area: `clues_first` once, when every clue was checked before the first arrest.

Ids are recorded whenever the event happens; the mission file gives the value (ids outside `Config.Bonuses` need
`points` on built-in files; custom missions value only `Config.Bonuses` ids and block hints).
Custom-mission guardrails (validate, `mission.source ~= 'builtin'`): pursuit `detainBonus` / `allDetainedBonus` /
`fastStop.id` / `ramPenaltyId` are `false`, a `Config.Bonuses` id or the block default, `fastStop.seconds` at most
120, `arrest.duration` 1000-30000 ms; escort `driver` the default `s_m_m_armoured_01` or a
`Config.Builder.allowed.peds` model; search_area `clueProps` only the block's own props (and `witness`),
`givesUp.close` off or exactly flee_arrest's 3 m / 3 s, `clueProgress.duration` / `cuff.duration` 1000-30000 ms,
`cuff.maxDistance` (when set) at most 3 m. Awards that belong to the completion (medal, all detained, truck healthy) are recorded once, **before**
the first `ctx.complete()` call, so they exist when the engine scores the run inside `complete`.

## Contract interpretations

1. **Randomness**: `ctx.rng` is stored in `ctx.state.rng` on first use and used for every pick (spawn order,
   models, footFlee rolls, wave points, clue spots, hiding spots, circle centres). `math.random` is never used.
2. **validate** applies the defaults to a copy and returns `false, CP.L('block.<id>.invalid.*', vars)`. Built-in
   missions (`mission.source == 'builtin'`) are trusted on the allowed lists, route length/ends, ambush spacing,
   no-build zones, the 30 m spawn distance and the 6+ spot minimum; ranges, types, counts, required keys and the
   armed budget are checked for every mission. With `location = nil` every `mission.locations[i]` is checked.
3. **Added optional fields** (defaults keep the contract behaviour): pursuit `peds`, `weapons` (only with
   `neverShoots = false`), `detainBonus`, `allDetainedBonus`, `fastStop = { id, seconds }`, `failIfUndriveable`;
   escort `driver` (ped model, `s_m_m_armoured_01`); search_area `peds`, `witnessModel`. Defaults of fields with no
   value in §3.3 / config: pursuit `escape` = flee_arrest's 400 m / 20 s for stop + `all_detained`, else `false`;
   `medals` only in follow mode; `arrest.duration` 5000; search_area `escape` 300 m / 30 s, clue props
   `{ 'prop_cs_heist_bag_02', 'prop_npc_phone_02', 'witness' }`.
4. **Pursuit start**: spawns at objective start. Placement priority: `spawns` (list, shuffled) > `spawn` (stacked
   8 m back along its heading) > `trigger.ahead` (that many metres ahead of `location.start`, along its vec4 heading,
   else towards the next route waypoint) > a loop route (racer i starts `2 + (i-1)` waypoints before the waypoint
   nearest the intercept start, facing the next one) > an open route's first point > 50 m ahead of the start.
   `trigger = 'arrive' | { ahead }` flee at once; `{ distance, lights }` waits for a validated `lights_near`
   (reporter in a vehicle within distance + 10 m), or any participant within 15 m, or the car's body health −25.
5. **Stopped** = below `stopped.speed` for `stopped.seconds` in a row, counted only once the car has been faster
   than 15 km/h (or 30 s after it fled) **and while a participant is within 50 m** (a PIT/box-in needs officers
   there; a racer waiting at a light far away is not stopped). A wrecked or vanished car counts as stopped.
6. **After the stop** the occupants are set `stopped` (host: `TaskLeaveVehicle`, repeated every 2.5 s while they are
   still seated, warping them out with flag 16 from the 3rd attempt). Only once the server sees them out of the car
   do they switch to `fleeing` (footFlee roll) / `hostile` (armed) / `surrendered` (`surrenderOnAim = false`): there
   is no time-out that switches a seated suspect, because CP.Npc's `flee` for a ped in the driver's seat is a
   vehicle flee (the stopped car would drive off again) and a suspect surrendered in a seat cannot be cuffed.
   Give-ups: aim within 25 m of a waiting suspect (`surrenderOnAim`), aim within `flee_arrest.aimDistance` of a
   running one (always), stun (a participant within 30 m and the reporter within 60 m), or a participant within
   `flee_arrest.closeDistance` for `closeSeconds`; armed ones only by stun or below 50 % health. Arrest = `CP.Npc.enableCuff` with `arrest`.
7. **Completion (stop mode)**: every suspect cuffed or dead without a participant kill (a crash death cannot block
   the run); with `all_or_timeout_any` (Street Race Bust) at least one racer must also be detained, so racers that
   all died in crashes leave the run to fail at the time limit ("Fail if: the time limit ends with no racer
   detained"). `all_racers_detained` only when all were cuffed. `onTimeout` returns `'completed'` for
   `all_or_timeout_any` with ≥ 1 detained. Killing an unarmed/surrendered/cuffed suspect by an **active**
   participant fails with `run.fail_killed_unarmed` (3 s grace for an armed suspect that just gave up); a kill by a
   player who already left the run is an outside kill (CP.Npc / CP.AntiCheat flag it), never a fail. The same rule
   holds for the escort driver and the search_area fugitives and witness.
8. **Rams**: the ramming driver's client reports the rising edge of `IsEntityTouchingEntity` with the pre-impact
   speed, only when `ramSpeed == 0` or the speed is above it. The server accepts it when the reporter is in a
   vehicle, within 12 m (+2) of the suspect car (server coords), the speed is at most the reporter's highest
   server-sampled speed of the last 3.5 s + 40 km/h, and no ram by that participant on that car was counted in the
   last 2.5 s. Counted when `ramSpeed <= 0 or speed > ramSpeed`. Rams also make a waiting car flee.
9. **`vehicle_stopped_fast`**: awarded once when every suspect vehicle is stopped within `fastStop.seconds` of
   the objective start (Stolen Vehicle Takedown: the run start).
10. **Follow mode**: the target is the car while its driver sits in it, else the nearest suspect on foot. One sample
    per tick (nearest participant distance) from the flee on; `inRange += dt` while ≤ `hold`; the average over all
    samples sets the medal (`< gold`, `< silver`, `< bronze`). Lost = more than `lost.distance` for `lost.seconds`
    in a row. Undriveable = a vehicle the participant drove during the objective reaching engine ≤ 0 on the server,
    or a client report confirmed by engine ≤ 100 or tank ≤ 0. A medal is only awarded once the full `duration` was
    held. If every suspect is gone (dead without a participant kill) the objective ends **without** a medal (a
    getaway driver rammed into a wall after a few seconds must not become a Gold medal once minSeconds pass).
    `prepare` sets `run.flags.medals = true`.
11. **Escort progress**: the truck spawns at `route.points[1]` facing `points[2]`; a waypoint is passed within 20 m
    (4 waypoints of look-ahead for cut corners). Reaching a stop waypoint (never the first or last) starts its wait;
    the wait never counts toward `stoppedFail`. Stopped = below 1 m/s, counted once the truck moved (3 m/s) or 30 s
    after it spawned. Destroyed = `onEntityDead` for the truck, entity health ≤ 0, engine ≤ −3999, or the entity
    missing for 2 ticks in a row (the engine's MISSING_TICKS; every block entity uses the same tolerance).
    Health % = min(engine, body) / baseline, baseline = 1000 × toughness after the host's `toughened` report (else
    1000); the host reads the toughness from the truck's cp bag `cfg.toughness` (else `ctx.obj.toughness`).
    `truck_healthy` uses the health **at the moment the truck arrives** ("arrives above 50% health"), recorded once
    before the first `ctx.complete()`. Completion also needs every triggered (not dropped) wave neutralised
    (each attacker killed or cuffed, however far behind: "neutralise each ambush wave"), not only no attacker
    within `clearRadius`. A participant killing the (unarmed) driver fails the run; otherwise a dead driver just
    leaves the truck stuck (stoppedFail).
12. **Escort waves**: `ambush.waves` waves at distinct random `ambushPoints` (cycled when there are more waves than
    points; spread over the route when the location has none), sorted along the route. A wave triggers within
    120 m of its point or once the truck passed its nearest waypoint; its `carsPerWave` is read at that moment. A car
    spawns together with its crew once `canSpawn(perCar + 1, false)` and `canSpawn(perCar, true)` both hold.
    Cars are placed at the point, 7 m apart along the road, alternating 4.5 m left/right, facing the truck, and
    doors-locked (the crew can get out, nobody can get in); attackers are seated with the server `SetPedIntoVehicle`
    and set `hostile`. **Complete** = truck within
    `arrival` of the last waypoint, no triggered wave still waiting to spawn, and no living attacker within
    `clearRadius` of the truck (attackers further away do not block; waves not triggered by the arrival are
    dropped). Rescale drops planned waves beyond the new count and lowers counts still missing.
13. **Search circle**: starts at `startRadius` around `location[center]` (or `location.start.coords`). Each checked
    (or lost) clue moves to the next `shrinkTo` radius; the new centre is within 0.7 × radius of a fugitive still at
    large (hidden ones preferred), nested in the old circle when one of 12 tries allows it. After the list ends the
    circle stays. `entered` (a participant inside the start circle) only drives the HUD. Completion needs every
    fugitive neutralised; checking clues is not required (the circle and `clues_first` reward it).
14. **Clues**: `clueCount` spots sampled from `location[clues]`; clue i uses `clueProps[((i-1) % #props) + 1]`
    (`'witness'` = a witness ped standing at the spot). Check = `clue_start` then `clue` within 2.5 m (+2) of the spot,
    at least 80 % of `clueProgress.duration` apart. A witness killed by a participant fails the run; killed by anyone
    else, or a clue entity that vanished, is `lost`: it shrinks the circle but `clues_first` can no longer be earned.
15. **Fugitives** run when a participant is within `runDistance` (server distance every tick), escape after
    running only, give up by stun (hidden or running) or the close rule (running). Presence = metres outside the
    current circle (0 inside).
16. **Presence**: pursuit = nearest suspect not neutralised (its car while driving), escort = the truck,
    search_area = distance beyond the circle edge.
17. **Nothing to take**: every mission vehicle (pursuit cars, the escorted truck, every ambush car) is locked
    (`SetVehicleDoorsLocked(veh, 2)` on the server; pursuit cars and the truck again by the host); peds inside can
    still get out. NPCs are unarmed except escort attackers (and pursuit with
    `neverShoots = false`); CP.Npc.apply sets no weapon drops.
18. **HUD**: the server only sends `ctx.hud({ message = { text, kind } })` for events (car fleeing/stopped, ambush,
    stop, wave cleared, arrival, circle shrinks, fugitive running). The HUD line is the client's `ctx.hudDetail`;
    progress counts come from `checklist`.
19. **Driving**: the clients pass the objective's style name (`cautious`/`reckless`, `careful`/`normal`/`fast`) and
    the speed in m/s to `CP.Npc.task`; CP.Npc owns the mapping to lane-following driving flags. Lap-end and
    stuck re-tasks (and every escort segment) pass `force = true`, because CP.Npc ignores identical repeats. The
    lap end (the waypoint just behind the car when the lap was tasked) only counts after the car first got 30 m
    away from it, so a racer is re-tasked once per lap, not on every loop pass at the start line.
20. **Host control**: the host calls `ctx.control` before anything it does to a run entity (not only on first
    sight); when control comes back from another client the entity is re-applied (`CP.Npc.apply`) and re-tasked,
    because local config and tasks may not survive an ownership change. A new escorted truck (test restart) is
    toughened again; clue zones are rebuilt when a clue number gets a new spot; a clue check still in its progress
    bar is cancelled when the objective stops.

## Requests to other modules

- **modules/npc (design question, not blocking)**: escort attackers are `CRIMSONPOLICE_HOSTILE`, which only hates
  `PLAYER`; the truck driver is `CRIMSONPOLICE_NEUTRAL`. Attackers therefore never shoot the truck or its driver
  on purpose, so "the truck is destroyed" / `truck_healthy` only depend on stray fire and collisions. If ambushes
  should attack the truck, CP.Npc `combat` needs a target option (the driver or the vehicle) that its AI loop does
  not re-target to the nearest participant; the block would then pass it.

- **modules/npc (client `CP.Npc.task`)** — checked against the landed module header; the args these blocks pass:
  - `'driveRoute'`: `{ vehicle = entity, points = { vector3, ... }, loop, speed = m/s, style = name, stopRange, force }`.
    The blocks already slice/rotate `points` to start at the next waypoint and re-task a new lap / segment.
  - `'flee'`: `{ vehicle, speed, style, force }` for a driver; `{}` on foot. Also `'cower'`, `'kneel'`,
    `'cuffed'`, `'combat'`.
  - Please keep the state-bag handler silent for the block-driven states `driving`, `stopped` and `idle` (it is
    today). Pursuit only sets `surrendered` once the ped is out of the car, so `kneel` never runs in a seat.
- **modules/npc (server)**: `setState` must accept `driving`, `stopped`, `idle`. `enableCuff` opts `label` /
  `duration` are the ox_target text and time (Street Race Bust: "Detain driver", 3000 ms).
- **modules/runs**: `ctx.isHost(src)` (escort only accepts `toughened` from the host); `onEntityDead` for vehicles
  of the objective (truck destroyed, pursuit car wrecked); `ctx.complete()` returns false while minSeconds is not
  reached (the blocks retry every tick); `ctx.state` is the same persistent table for every hook. `spawnVehicle`
  receives an extra `cfg = { toughness }` for the escorted truck — put it in the cp bag if you pass `opts.cfg`
  through, the client does not depend on it.
- **modules/runs / route (client)**: Manhunt's start is a 600 m circle "shown on the map when the type is
  accepted": please show a radius blip for `location.start` at accept when `start.radius >= 200`; the block draws
  its own circle from the objective start.
- **modules/anticheat**: rejected evidence (`duplicate` ram inside the cooldown, `too_far`, `implausible`) is normal
  lag/timing noise; please log it, do not flag the run.
- **Scoring / locale merge**: labels for standard ids come from the scoring/core part (`bonus.vehicle_stopped_fast`,
  `bonus.truck_healthy`, `bonus.clues_first`, `bonus.hard_ram` / `penalty.hard_ram`). `blocks_c.json` holds the
  extras: `bonus.racer_detained`, `bonus.all_racers_detained`, `bonus.ram` + `penalty.ram` (same text),
  `bonus.medal_gold|silver|bronze` (identical to blocks_a) and `run.fail_killed_unarmed` (identical to blocks_b).
- **missions (built-in files)** not written yet:
  - Street Race Bust: `{ block = 'pursuit', mode = 'stop', vehicles = 3, route = 'race', models = { sports set },
    speed = 120, style = 'reckless', trigger = 'arrive', footFlee = 0, surrenderOnAim = false,
    arrest = { label = 'Detain driver', duration = 3000 }, complete = 'all_or_timeout_any', ramSpeed = 100 }`,
    `location.race = { points = {...}, loop = true }`, `location.start` = the intercept point on the loop;
    `scaling = { 'objectives.1.vehicles' }`; bonuses `{ id = 'racer_detained', points = 30, each = true }`,
    `{ id = 'all_racers_detained', points = 20 }`; penalties `{ id = 'hard_ram' }`; `vehiclePenalties = false`.
  - Pursuit Sim: `{ block = 'pursuit', mode = 'follow', trigger = { ahead = 50.0 }, hold = 150,
    lost = { distance = 250, seconds = 10 }, duration = 180, medals = { gold = 40, silver = 80, bronze = 150 },
    ramSpeed = 0, ramPenaltyId = 'ram' }` with `start.coords` a vec4 whose heading points down the road (or a
    `spawn` point); bonuses `medal_gold` 50 / `medal_silver` 25 / `medal_bronze` 10 (explicit points);
    penalties `{ id = 'ram', points = -10, each = true }`.
  - Stolen Vehicle Takedown: `{ block = 'pursuit', mode = 'stop', vehicles = 1, suspectsPerVehicle = 2,
    spawn = 'car', route = 'flee', models = { 4-seat cars }, trigger = { distance = 60.0, lights = true },
    footFlee = 0.2, surrenderOnAim = true, escape = { distance = 400, seconds = 20 }, ramSpeed = 100 }`;
    `scaling = { { path = 'objectives.1.suspectsPerVehicle', max = 4 } }`; bonuses `{ id = 'vehicle_stopped_fast' }`;
    penalties `{ id = 'hard_ram' }`; `vehiclePenalties = false`.
  - Manhunt and Armored Truck Escort (already written) match these blocks as they are.
