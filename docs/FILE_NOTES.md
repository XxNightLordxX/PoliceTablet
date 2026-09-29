# File notes

The long headers that used to open each file, kept word for word. The owner's style (docs/STYLE.md)
keeps a file header to a short summary; tools/restyle.py moved the rest here. Section names are file
paths. Anything here that is also in docs/ARCHITECTURE.md is owned by ARCHITECTURE.md.

## Crimson-Police/blocks/checkpoint_route/client.lua

```text

 blocks/checkpoint_route/client.lua · objective block "checkpoint_route" (client half)

  What it does
    Shows the current checkpoint (marker within 150 m, blip with GPS route; the next one dimmer),
    runs the local stop timer ("Hold still: 6 s") and reports the checkpoint when it counts; during a
    course it watches the driven vehicle for wall/vehicle contacts and for becoming undriveable.
    Everything the server decides arrives as a full snapshot through update(); the HUD line is
    composed here with ctx.hudDetail (the running course clock in whole seconds, so the line changes
    at most once a second; "the timer starts at checkpoint 1" while the server holds the run timer).
    Radio Silence: no blips, the HUD names the next street instead.
    No networked entities are created here; this block has no NPCs (hostChanged only records the flag).
    The block's client state is kept per run and objective in this file (stateOf), so it also works
    when the engine hands every hook a fresh ctx.state table.

  Objective fields read: radius [10], stopFor [10], vehicleRequired [true], contactPenalty [2]
    (the server sends the checkpoint list, course state and which checks to run)
  Evidence sent (ctx.report)
    { type = 'checkpoint', index, netId?, try }   inside the current checkpoint
        (driving a vehicle when required; stopped for stopFor seconds, or at once for drive-through).
        The check here only drives the HUD hint: the server decides "driving a vehicle" itself (in a
        vehicle, in its driver seat; any vehicle counts) and trusts nothing else in the report.
    { type = 'contact', netId }       collision flag with a speed drop, a hard speed drop, or body damage
    { type = 'undriveable', netId }   the vehicle used on the course is no longer driveable
  Bonuses / penalties: none recorded on the client (the server records medal_* and no_contact).
```

## Crimson-Police/blocks/checkpoint_route/server.lua

```text

 blocks/checkpoint_route/server.lua · objective block "checkpoint_route" (server half)

  What it does
    Drive to a list of checkpoints in order. Each checkpoint counts when a participant is inside its
    radius (driving a vehicle when vehicleRequired is on) and, with stopFor > 0, has stayed stopped
    there for stopFor seconds; with stopFor = 0 it is a drive-through gate. Only the current
    checkpoint counts, so a missed one must be driven through before the next one counts.
    "Driving" is decided on the server only: the participant's ped is in a vehicle
    (GetVehiclePedIsIn(ped, false) ~= 0) and in its driver seat (GetPedInVehicleSeat(veh, -1) == ped).
    Any vehicle counts: FiveM has no server-side vehicle class, so the old "police vehicle" rule had to
    trust the client and was replaced by "driving a vehicle" at the owner's request.
    Powers Beat Patrol (use = 'random', count = 5, stop 10 s) and EVOC Course (use = 'all',
    drive-through, medal times, contact seconds, fails when the course vehicle is undriveable).
    The server tracks every participant's position each tick (server-side coordinates) to verify the
    stop time, and the course vehicle's engine/body health (undriveable fail, no_contact check).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.checkpoint_route)
    checkpoints        location key: list of vec3/vec4, or a road route { points = { vec3, ... } }
                       (an inline list or route table in the objective also works)
    use                'all' | 'random'                   [Config.Blocks.checkpoint_route.use.default = 'all']
    count              checkpoints used when use = 'random' (required for random)
    radius             metres                             [radius[3] = 10]
    stopFor            seconds stopped inside; 0 = drive through   [stopFor[3] = 10]
    vehicleRequired    checkpoint only counts while driving a vehicle (any vehicle)   [vehicleRequired.default = true]
                       (policeVehicle, the old name that published mission files may still use, is read as an
                       alias of vehicleRequired by defaults())
    medals             false | true | { gold, silver, bronze } seconds; location.medals (a table) overrides
                       [medals.default = false]. With medals the course time decides one medal bonus and
                       run.flags.medals = true is set in prepare (the common fast bonus is skipped).
    contactPenalty     seconds per wall/vehicle contact   [contactPenalty[3] = 2]; added to the course time
                       and taken off the run timer (CP.Runs.adjustTimer)
    timerStart         'first' (course clock starts at checkpoint 1) | 'start' (when the objective starts)  ['first']
                       On a medal course that is the mission's first objective, 'first' also holds the run
                       timer (CP.Runs.pauseTimer) from the objective start until checkpoint 1 counts, at most
                       PRESTART_GRACE s ("the timer starts at the first checkpoint", EVOC Course).
    failIfUndriveable  fail the run when the course vehicle becomes undriveable   [true]
    minSeconds [20] · presenceRange [presenceRange[3] = 300] · label
    With use = 'random' a pool point inside location.start (the start marker) is always used first and
    the others follow in the pool's circular order from it ("Start: the first checkpoint").
    Stop checkpoints (stopFor > 0): the server's own 1 s samples must see the participant inside the
    marker, stopped (server GetEntitySpeed <= SERVER_STOP_SPEED) and driving a vehicle when one is
    required, for stopFor - DWELL_SLACK seconds.

  Evidence accepted (client -> server through ctx.report; the engine adds coords and time)
    { type = 'checkpoint', index, netId?, try? }   index = the current checkpoint; nothing else in it is
        trusted (the vehicle, the driver seat, the position and the stop time are the server's own)
    { type = 'contact', netId? }        course running, reporter in a vehicle, at most 1 per 1.2 s, 60 counted
    { type = 'undriveable', netId }     the reporter's course vehicle; verified with its engine health

  Bonuses / penalties recorded (shared, via ctx.award)
    medal_gold | medal_silver | medal_bronze   one of them, from course time + contact seconds (medal courses)
    no_contact                                 medal courses: no counted contact and no server-side body damage
    Each carries the card value as its points hint (CARD_POINTS: 50 / 25 / 10, no_contact 10; capped by
    Config.Builder.bonusCap.points on custom missions).
  Fail reason keys: block.checkpoint_route.fail_undriveable

  ctx.state
    points = { vec3 }, current = index | nil (finished), done = n, finished, completed, failed,
    medals = { gold, silver, bronze } | nil, trackContacts, contacts, penalty (s), courseStartMs,
    startMs, courseTime, medal, near = { [src] = { cp, since } }, vehicles = { [src] = netId },
    body = { [netId] = { start, min } }, healthy = { [netId] = true }, lastContact = { [src] = ms }, timedOut,
    timerHeld (this objective holds the run timer until checkpoint 1)
```

## Crimson-Police/blocks/escort/client.lua

```text

 blocks/escort/client.lua · objective block "escort" (client half)

  What it does (while the objective is current on this participant's client)
    - blips for the escorted truck, the destination and living attackers (none with Radio Silence);
      the arrival marker at the destination (DrawMarker only within MARKER_RANGE, otherwise Wait(750));
    - a HUD line (ctx.hudDetail): truck health, stop wait, stopped countdown, attackers alive, and at the
      destination how many attackers are still within clearRadius (or, with none that close, how many are
      left to neutralise anywhere); nothing once a stop cleaned up while the host AI waited for control;
    - on the run host only: control of the truck, its driver and the attackers before anything is done
      to them (re-applied and re-tasked when control comes back from another client), CP.Npc.apply on
      the driver, the driver seated and kept in the truck, doors locked, the toughness (cp bag
      cfg.toughness, else ctx.obj.toughness) applied once
      (SetEntityMaxHealth / SetEntityHealth / SetVehicleEngineHealth / SetVehicleBodyHealth /
      SetVehiclePetrolTankHealth = 1000 × toughness, SetVehicleStrong) and reported ('toughened');
      then the route, segment by segment: CP.Npc.task(driver, 'driveRoute', { vehicle, points = the
      waypoints from the server's next one to the next stop (or the destination), loop = false,
      speed (m/s), style (CP.Npc's lane-following flags), stopRange, force }). At a stop, and at the
      destination, the truck brakes (TaskVehicleTempAction); the next segment is tasked when the server
      ends the stop (truck.gen changes), after a host change, or when the truck is stuck for RETASK_MS.
      Attackers are CP.Npc's (state 'hostile' -> combat); the host applies them once it has control.

  Objective fields read: route, speed, style, toughness, arrival, clearRadius (ctx.obj); location[route].
  Evidence sent: { type = 'toughened', netId }
  Server data (update): { kind = 'state', truck = { netId, driver, wp, gen, stop = { at, left } | nil,
    arrived, toughened, health, stoppedFor, stoppedFail }, waves = { { k, triggered, done, alive } },
    attackers = { netId }, completed }
```

## Crimson-Police/blocks/escort/server.lua

```text

 blocks/escort/server.lua · objective block "escort" (server half)

  What it does
    An escorted vehicle (Armored Truck Escort: a stockade) with an NPC driver (networked, ctx.spawnVehicle /
    ctx.spawnPed) leaves the start of a recorded road route when the objective starts (the first
    participant's arrival) and is driven by the run host's client from waypoint to waypoint with a
    lane-following style at `speed`. The server follows its progress with its own coordinates: a waypoint
    is passed within WP_REACH; at a route stop (`route.stops = { { at, wait } }`) the truck waits `wait`
    seconds, which never counts toward stoppedFail. Vehicle toughness is applied by the host
    (SetEntityMaxHealth / SetVehicleEngineHealth / SetVehicleBodyHealth ... = 1000 × toughness) and
    confirmed with the 'toughened' report, which sets the health baseline.
    Ambush waves (ambush.waves, scales) of ambush.carsPerWave cars (scales) with ambush.perCar armed
    attackers each are planned at start at random ambush points (ctx.rng, distinct, in route order) and
    trigger when the truck is within AMBUSH_TRIGGER of the point (or has passed it). Attackers are
    hostile only to participants (CP.Npc 'hostile'). Spawns wait for the run caps (ctx.canSpawn) and are
    never cut; rescale drops planned waves not yet triggered and lowers counts still missing.
    Done when the truck, on the final stretch (its next waypoint is the last one), is within `arrival` metres
    (2D, like the waypoints) of the destination (the last waypoint) with no living
    attacker within clearRadius of it, every triggered wave spawned and every triggered wave neutralised
    (each attacker killed or cuffed, wherever it is: "neutralise each ambush wave"). Fails when the truck is
    destroyed (entity health 0 only once a positive health was seen: a server-created truck reads 0 until a
    client synced it; not once the objective is done), stopped for stoppedFail seconds in a row outside a stop
    while the run host, whose client drives it, is within HOST_RANGE (after it first moved, or START_GRACE_MS
    after the host first came that close), or (engine) at the time limit.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.escort)
    minSeconds [60] · presenceRange [presenceRange[3] = 300] · label
    route        location key { points, stops = { { at, wait [stopWait[3] = 20] } } }  ['route']
    vehicle      [Config.Blocks.escort.vehicle = 'stockade'] · driver (added) ped model ['s_m_m_armoured_01']
                 (custom missions: that default or one of Config.Builder.allowed.peds)
    speed        [speed[3] = 60] km/h · style 'careful' | 'normal' | 'fast' [style.default = 'normal']
    toughness    [toughness[3] = 1.5] · stoppedFail [stoppedFail[3] = 60] s · arrival [arrival[3] = 20.0]
    ambushPoints location key: list of vec3/vec4                         ['ambushPoints']
    ambush       { waves [ambushWaves[3] = 2], carsPerWave [carsPerWave[3] = 2], perCar [perCar[3] = 2],
                   models [4-seat Config.Builder.allowed.vehicles], peds [Config.Blocks.hostile_waves.peds],
                   weapons [hostile_waves.weapons], accuracy [hostile_waves.accuracy[3] = 25],
                   armour [hostile_waves.armour[3] = 0], health [hostile_waves.health[3] = 200] }
                   (accuracy / armour + tier and Armored Hostiles via ctx.combat)
    clearRadius  [100.0]

  Evidence accepted (onEvent)
    { type = 'toughened', netId }   the run host applied the toughness to the truck (once)
    { type = 'cuffed', netId }      CP.Npc after a validated cuff of an attacker (the cp bag says cuffed)
    { type = 'shot', netId, src }   CP.Npc: a surrendered/cuffed ped was shot (penalty recorded there)

  Bonus / penalty ids recorded (shared)
    truck_healthy   ctx.award once (recorded before ctx.complete) when the truck's health at the moment
                    it arrived was above HEALTHY_SHARE (50 %)
  Fail reason keys: block.escort.fail_destroyed · block.escort.fail_stopped · block.escort.fail_setup ·
    run.fail_killed_unarmed (a participant killed the unarmed driver)

  ctx.state
    block, rng, points, stops = { [waypoint] = wait }, truck = { netId, entity, driver = { netId, entity,
    dead }, wp, served, stop = { at, left } | nil, stoppedFor, moved, nearAt, arrived, arrivalHealth,
    toughened, baseline, health, gen }, waves = { { k, point, wp, triggered, dropped, want, cars = { carKey } } },
    cars = { [key] = { netId, entity, wave, want, crew = { pedKey } } } (every car doors-locked), peds = { [key] = { netId,
    entity, wave, state } }, dirty, sentAt, completed, failed, halted
```

## Crimson-Police/blocks/flee_arrest/client.lua

```text

 blocks/flee_arrest/client.lua · objective block "flee_arrest" (client half)

  What it does (while the objective is current on this participant's client)
    - door mode: ox_target sphere zone "Knock and announce" on the door (option crimson-police:knock),
      selecting it reports 'knock_start', runs lib.progressBar(knock.duration) and reports 'knock';
      a marker over the door (DrawMarker only within MARKER_RANGE, otherwise Wait(750)) and a door
      blip until the knock (no blip with Radio Silence); all three come back when a test restart
      sends knocked = false again (restart sends no stop or start);
    - every participant checks the suspects near them: 'aim' when IsPlayerFreeAimingAtEntity (or
      lock-on IsPlayerTargettingEntity) on an unarmed fleeing suspect within givesUp.aim, 'stunned'
      when IsPedBeingStunned (throttled per
      suspect); the server re-checks both with server-side distances;
    - suspect blips (after the knock in door mode; none with Radio Silence);
    - HUD lines (ctx.hudDetail): the escape countdown from the server, or "stay close" while this
      player is within givesUp.close.distance of an unarmed fleeing suspect;
    - on the run host only: CP.Npc.apply once it has control of each suspect, then the task for its
      cp state: fleeing -> flee along the route (scatter: location[obj.routes][route]; door:
      location[obj.fleeTo]), hostile -> combat, and (on first sight / after hostChanged)
      surrendered -> kneel, cuffed -> cuffed. Control is requested before every task and a refused
      task is retried on the next loop. The "Cuff suspect" target is CP.Npc's (enableCuff).

  Objective fields read: mode, door, knock.label / duration, fleeTo, routes, givesUp.aim / stun /
    close (ctx.obj); location points.
  Evidence sent: { type = 'knock_start' }, { type = 'knock' }, { type = 'aim', netId }, { type = 'stunned', netId }
  Server data (update): { peds = { { netId, role, state, armed, route } }, mode, knocked, escaping, response }
```

## Crimson-Police/blocks/flee_arrest/server.lua

```text

 blocks/flee_arrest/server.lua · objective block "flee_arrest" (server half)

  What it does
    Suspects who must be taken into custody ("Cuff suspect", CP.Npc.enableCuff) after they give up.
    Two modes:
    - door (Warrant Service): the suspect waits inside at `suspect`, armed associates at
      `associates.spawns` (count scales). Participants use ox_target "Knock and announce" at the
      `door` (knock.duration progress; 'knock_start' then 'knock', both checked with server-side
      distance and the elapsed time). The suspect's response is rolled with the objective rng when
      the objective starts and revealed at the knock (or when a door-mode NPC dies first):
      surrender (placed DOOR_STEP in front of the door, facing out: out = the door's vec4 heading,
      turned round when the location start is clearly behind it; whether he waited inside or on the
      step beside the door), flee (runs out the back along `fleeTo`)
      or fight (spawned armed, the pistol from `weapons` given in hand only at the reveal so it does
      not give the response away). Associates always fight. Done when the
      suspect is cuffed (or was killed while armed and fighting) and every associate is
      neutralised (killed, or gave up and cuffed).
    - scatter (Prison Break): `suspects` inmates (scale) in prison clothes spawn at `spawns`
      (already outside the fence; spawn points inside a Config.Builder.noBuildZones zone are never
      used) and flee along the `routes`; round(suspects × armedShare) of them carry a pistol and turn
      to fight while a participant is within fireWithin. Done when every inmate is neutralised.
    Unarmed suspects give up when a participant aims at them within givesUp.aim metres (client
    'aim' report, server distance check), when stunned (client 'stunned' report, a participant must
    be within STUN_RANGE) or when a participant stays within givesUp.close.distance for
    givesUp.close.seconds (server-side distance sampling every tick). Armed suspects give up only
    when stunned (armedGivesUp.stun) or below armedGivesUp.belowHealth health (server polls health).
    A suspect or inmate more than escape.distance from every participant for escape.seconds
    escapes: the run fails. Killing an unarmed, surrendered or cuffed suspect/inmate (a participant
    kill) fails the run for everyone.
    Every NPC spawns in the neutral relationship group (cfg.group = 'neutral'), armed or not; only
    the 'hostile' state (fight response, associates after the knock, an armed inmate within
    fireWithin) puts it in CRIMSONPOLICE_HOSTILE through CP.Npc's combat task, so nobody opens fire
    before the knock or from beyond fireWithin.
    validate: spawn points, the door marker and every fleeTo / route waypoint must lie outside
    Config.Builder.noBuildZones for every mission; custom missions also get the allowed lists, the
    associate spawn-point count and the minimum distance of spawn points from the start, and:
    aliveBonus.id must be a Config.Bonuses id with no points / pctOfPoints of its own (the file value
    is never passed as a hint either: only built-in files value their own id), givesUp.close is either
    off or exactly Config.Blocks.flee_arrest closeDistance / closeSeconds, knock.duration and
    cuff.duration are 1000-30000 ms, and cuff.maxDistance (when set) is at most CUFF_RANGE.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.flee_arrest)
    minSeconds [30] · presenceRange [presenceRange[3] = 250] · label
    mode          'door' | 'scatter'                                    ['door']
    door mode     door ['door'] vec4 key · suspect ['suspect'] vec4 key · fleeTo ['fleeTo'] list key
                  knock { label [locale block.flee_arrest.knock], duration [3000] ms }
                  responses { surrender [0.5], flee [0.3], fight [0.2] } (Config responses / 100)
                  associates { count [1], spawns ['associates'], weapons [= weapons],
                    accuracy [hostile_waves.accuracy[3] = 25], armour [hostile_waves.armour[3] = 0] }
    scatter mode  spawns ['spawns'] list key · routes ['routes'] list of lists of vec3 (or { points })
                  suspects [5] · armedShare [0.4]
    common        models [door: Config.Blocks.hostile_waves.peds; scatter: { 's_m_y_prisoner_01' }]
                  weapons [Config.Blocks.flee_arrest.weapons] · accuracy / armour (armed suspects)
                    [hostile_waves defaults, + tier via ctx.combat] · fireWithin [15.0]
                  escape { distance [escapeDistance[3] = 400], seconds [escapeSeconds[3] = 20] }
                  givesUp { aim [aimDistance[3] = 10.0] | false, stun [true],
                    close { distance [closeDistance = 3.0], seconds [closeSeconds = 3] } | false }
                    (the builder's list form { 'aim', 'stun', 'close' } is accepted)
                  armedGivesUp { stun [true], belowHealth [0.5] | false }
                  cuff { label [locale block.flee_arrest.cuff], duration [5000], maxDistance }
                  aliveBonus { id ['suspect_alive'], points (built-in files only: hint for ids outside Config.Bonuses), each }

  Evidence accepted (onEvent)
    { type = 'knock_start' } / { type = 'knock' }  door mode, within KNOCK_RANGE + slack of the door;
                                     'knock' at least TIMED_SHARE × knock.duration after 'knock_start'
    { type = 'aim', netId }          an unarmed fleeing suspect aimed at within givesUp.aim (+ slack)
    { type = 'stunned', netId }      IsPedBeingStunned seen by a client; the reporter within
                                     STUN_REPORT_RANGE and a participant within STUN_RANGE
    { type = 'low_health', netId }   an armed suspect: re-checked with server-side health
    { type = 'cuffed', netId }       CP.Npc (CP.Runs.dispatch) after a validated cuff (cp bag says cuffed)
    { type = 'shot', netId, src }    CP.Npc: a surrendered/cuffed suspect was shot (penalty recorded there)
    { type = 'damaged', netId }      CP.Npc (CP.Runs.dispatch): an armed suspect's health is re-checked
                                     against armedGivesUp.belowHealth at once; always accepted

  Bonus / penalty ids recorded (shared)
    aliveBonus.id ['suspect_alive'; Prison Break: 'inmate_alive'] ctx.award count 1 for every suspect or
    inmate cuffed alive (associates earn nothing)
  Fail reason keys: block.flee_arrest.fail_escaped · block.flee_arrest.fail_setup (no usable spawn point
    outside the no-build zones) · run.fail_killed_unarmed
  Spawning is guarded: the re-entry flag is cleared even when a spawn throws (retried next tick).

  ctx.state
    block, mode, rng, response, knocked, knockStart = { [src] = ms }, peds = { [tostring(netId)] =
    { netId, entity, role = 'suspect'|'associate'|'inmate', armed, state, route, far, close,
    surrenderedAt } }, counts = { suspect, associate, inmate, armedInmates }, pointOrder,
    assocOrder, routeOrder, nextArmed, escaping, dirty, hudText, completed, failed, stopped
```

## Crimson-Police/blocks/hostile_waves/client.lua

```text

 blocks/hostile_waves/client.lua · objective block "hostile_waves" (client half)

  What it does
    While the objective is current on this participant's client:
    - blocks NPC traffic within obj.blockTraffic metres of location.start.coords, area-limited only
      (AddRoadNodeSpeedZone + SetRoadsInArea for that box + one ClearAreaOfVehicles in the radius)
      (ARCHITECTURE §0.14). It is restored (RemoveRoadNodeSpeedZone, SetRoadsBackToOriginal) when the
      objective stops only if no later objective of the run follows; otherwise the block is held for the
      rest of the run (every objective of a run shares its location: Gang Shootout / Kingpin "Secure the
      scene", "NPC traffic is blocked within 120 m while the run is active") and restored as soon as
      CP.Runs.current() is no longer that run (run end, silent removal) or on resource stop. A later
      hostile_waves objective with the same area takes the held block over instead of adding a second;
    - red entity blips on hostiles that are not neutralised (none with Radio Silence);
    - a HUD line (ctx.hudDetail) when a surrendered hostile is close enough to cuff;
    - on the run host only: CP.Npc.apply + the task for the current cp state once the host has control
      of each hostile (again after hostChanged; retried until CP.Npc took both), and one 'low_health'
      report per hostile whose health drops under surrender.belowHealth (boss: boss.surrender.belowHealth;
      the server also polls health itself, the report only makes the roll come sooner).
    The "Cuff suspect" target itself is CP.Npc's (enableCuff). No networked entity is created here.

  Objective fields read: blockTraffic, behaviour, surrender.belowHealth / .chance,
    boss.label / boss.surrender (ctx.obj, scaled copy); location.start.coords.
  Evidence sent: { type = 'low_health', netId } (host only, once per hostile)
  Server data (update): { peds = { { netId, role, state, wave } }, wave, waves }
```

## Crimson-Police/blocks/hostile_waves/server.lua

```text

 blocks/hostile_waves/server.lua · objective block "hostile_waves" (server half)

  What it does
    Spawns armed hostiles in waves at the location's spawn points (networked, OneSync, through
    ctx.spawnPed) and completes when every hostile, and the optional boss, is neutralised: killed, or
    surrendered and cuffed ("Cuff suspect", CP.Npc.enableCuff). The next wave spawns when
    nextWave.aliveAtMost or fewer hostiles of the current wave are not yet neutralised, or
    nextWave.afterSeconds after the wave began. The boss (if any) arrives after the last wave by the
    same rule; it never scales. A hostile under surrender.belowHealth health gets exactly one
    surrender roll (CP.Npc.rollSurrender with surrender.chance) when the host reports it and the
    server confirms the health; the server also polls the health of every hostile each tick, so a
    report that arrived before the damage synced (or never arrived) cannot cost the roll. Spawn
    points are picked with the objective rng: distinct points,
    free ones (no living hostile on them) first, reused (with a small offset) only when a wave is
    larger than the point list. Spawning respects the run caps (ctx.canSpawn: a wave that does not fit
    waits and is re-checked every tick, counts are never cut) and rescale (only the NPCs still missing
    for the new ctx.obj counts are spawned). The client half blocks NPC traffic within blockTraffic
    metres of the start while the objective runs.
    Used by Gang Shootout (3 waves 7/7/6), Hostage Rescue (1 wave of 4 inside) and Weekly Boss:
    Kingpin (4 waves 8/8/7/7 then the Kingpin).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.hostile_waves)
    minSeconds [60] · presenceRange [presenceRange[3] = 150] · label
    spawns        location key: list of vec4                               ['spawns']
    waves         base hostiles per wave (scaled by the engine)             [{ 7, 7, 6 }]
    nextWave      { aliveAtMost [nextWaveAlive[3] = 2], afterSeconds [nextWaveAfter[3] = 90] }
    weapons       weapon names, one picked per hostile                      [Config.Blocks.hostile_waves.weapons]
    peds          ped models, one picked per hostile                        [Config.Blocks.hostile_waves.peds]
    accuracy      [accuracy[3] = 25] · armour [armour[3] = 0]   (+ tier and Armored Hostiles via ctx.combat)
    health        [health[3] = 200]
    behaviour     'hold' | 'balanced' | 'push'                              [behaviour.default = 'balanced']
    surrender     { belowHealth [0.25], chance [surrender[3] / 100 = 0.30] }  (false = never)
    boss          false [boss.default] or { model [first of peds], label [locale block.hostile_waves.boss_label],
                  health [health[2] = 400], armour [armour[2] = 100], weapon ['WEAPON_ASSAULTRIFLE'],
                  accuracy [accuracy], behaviour [behaviour], spawn (location key; nil = a spawn point),
                  surrender [= surrender], aliveBonus { id ['kingpin_alive'], points [50] } }
                  The boss does not scale: its accuracy and armour are used as written.
                  aliveBonus.points is a hint only on built-in files; elsewhere kingpin_alive always
                  carries BOSS_BONUS.points and any other id no hint. Custom missions (validate) may only
                  use kingpin_alive (points absent or 50) or a Config.Bonuses id without points.
    cuff          optional { label, duration, maxDistance } passed to CP.Npc.enableCuff (custom missions:
                  duration 1000-30000 ms, maxDistance at most CUFF_RANGE)
    blockTraffic  metres around location.start.coords (client half)     [blockTraffic[3] = 120.0]

  Evidence accepted (onEvent)
    { type = 'low_health', netId }   host client: a hostile looks under belowHealth. The server re-checks
                                     GetEntityHealth against the configured / GetEntityMaxHealth max
                                     (health above the 100-point death threshold), then rolls once.
                                     tick runs the same server-side check for every hostile.
    { type = 'cuffed', netId }       CP.Npc (via CP.Runs.dispatch) after a validated "Cuff suspect"; the
                                     cp bag must say cuffed. A cuff the event missed is picked up by tick.
    { type = 'shot', netId, src }    CP.Npc: a participant shot a surrendered/cuffed hostile
                                     (shot_surrendered is recorded by CP.Npc); accepted, nothing else.
    { type = 'damaged', netId }      CP.Npc (CP.Runs.dispatch): the same server-side health check as
                                     low_health (still one roll per hostile); always accepted.

  Bonus / penalty ids recorded (shared)
    hostile_arrested   ctx.award, count 1 for every hostile cuffed
    kingpin_alive      ctx.award (boss.aliveBonus.id, points hint boss.aliveBonus.points) when the boss is cuffed
  Fail reason keys
    run.fail_killed_unarmed  a participant killed a surrendered or cuffed hostile (a kill within
                             SURRENDER_GRACE_MS of the surrender is a shot already in flight: not a fail)

  ctx.state
    block, rng, peds = { [tostring(netId)] = { netId, entity, role = 'hostile'|'boss', wave, state,
    rolled, maxHealth, surrenderedAt } }, waves = { [w] = { spawned, elapsed, points } }, wave,
    boss = { netId } | nil, arrested, dirty, hudText, completed, failed, stopped
```

## Crimson-Police/blocks/interact_points/client.lua

```text

 blocks/interact_points/client.lua · objective block "interact_points" (client half)

  What it does
    For every open point of the server's snapshot it registers an ox_target sphere zone (option names
    "crimson-police:interact_points:<runId>:<objective>:<point>:<main|follow>") that runs
    lib.progressBar (cancellable, movement/car/combat disabled, animation from progress.anim) and
    reports the result. Shows the rolled outcome ("Door is secure" / "Door found open") and the
    follow-up hint, the tablet-log hint, and hidden-device search results on the HUD line
    (ctx.hudDetail). Small markers within 40 m; blips per point (hidden search: one area blip);
    no blips under Radio Silence. Only participants' clients register targets. No networked entities
    are created here and there are no NPCs (hostChanged only records the flag).
    The block's client state is kept per run and objective in this file (stateOf), so it also works
    when the engine hands every hook a fresh ctx.state table.

  Objective fields read
    target { label, icon, radius [1.5] } · progress { label, duration (ms), anim } · hidden { label }
    · label (blip text fallback). Outcomes, follow-ups and the log come from the server snapshot.
  Evidence sent (ctx.report)
    { type = 'interact', point, seq }   the main action's progress bar finished at that point
    { type = 'followup', point, seq }   the follow-up action's progress bar finished
        (seq counts this client's reports, so a retry after a rejected report is never an exact duplicate)
    ('log' is sent by the tablet's Active Mission screen, not by this file)
  Bonuses / penalties: none on the client (the server records correct_log, wrong_log, fastBonus.id).
```

## Crimson-Police/blocks/interact_points/server.lua

```text

 blocks/interact_points/server.lua · objective block "interact_points" (server half)

  What it does
    One or more points, each worked with an ox_target option and a progress bar. Variants, all from
    the objective fields:
      · plain points (Secure the scene, Search the property, Seize the shipment): done after the action;
      · rolled points (Business Check): the server rolls an outcome per point with ctx.rng when the
        objective is prepared (secure 75% / open 25%); an outcome with followUp adds a second action
        ("Secure door"); with logResult the officer then logs the result on the tablet
        (correct_log +5 / wrong_log -5 each);
      · hidden devices (Bomb Disposal search): N of the points (hidden.count, scales) hide a device;
        searching one reveals it: the device prop is spawned (ctx.spawnObject, OneSync) and added to
        run.shared.devices = { { netId, coords, point, model, heading } } for the next objective
        (skill_check). Done when every device is found and spawned. Spawn caps are respected (a found
        device waits for ctx.canSpawn).
    Every action is validated with server-side coordinates and a server-side dwell time (the participant
    was sampled at the point, in that point's state, for the progress or follow-up duration), and each
    point is accepted once, in its state.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.interact_points)
    points     location key: vec3/vec4, list of them, or list of { coords, heading, label }
               (an inline value in the objective also works)
    use        'all' | 'random'                     [use.default = 'all']; with 'random' a point inside
               location.start is always used first ("Start: the first business")
    count      points used when use = 'random'
    target     { label, icon, radius }              [label: locale default; icon default; radius 1.5]
    progress   { label, duration (ms), anim }       [label = Config.Blocks.interact_points.label,
               duration = progress[3] s * 1000, anim = Config.Blocks.interact_points.animation]
    roll       { outcomes = { { id, chance, label?, followUp = { label, duration } } } }
    logResult  { choices = { 'secure', 'found_open' } (ids or { id, label }), correct = { outcomeId = choiceId } }
               without roll the server rolls one of the choices per point (equal chances; correct = it)
    hidden     { count [1], prop ['prop_ld_bomb'], label }
    fastBonus  { seconds, id }                      id recorded when all the work is done within seconds
                                                    of this objective's start (devices: all found)
    Custom missions (validate): progress.anim only a Config.Builder.allowed.animations name (no raw
    { scenario } / { dict, clip }), hidden.prop one of DEVICE_PROPS, fastBonus.id a Config.Bonuses id.
    minSeconds [5] · presenceRange [presenceRange[3] = 150] · label

  Evidence accepted (ctx.report from the client half; 'log' from the tablet's Active Mission screen)
    { type = 'interact', point }           main action finished at that point (check, search, secure)
    { type = 'followup', point }           follow-up action finished (e.g. "Secure door")
    { type = 'log', point, choice }        the logged result for a point waiting in state.log

  ctx.state.log (read by CP.Runs.view for the Active Mission screen's "log" field):
    nil, or { point = <point number>, choices = { { id = 'secure', label = 'Secure' }, ... } }
    (labels are already translated; the oldest point waiting for its log is shown first)

  Bonuses / penalties recorded (shared): correct_log (ctx.award), wrong_log (ctx.penalize),
    fastBonus.id (ctx.award, e.g. devices_found_fast)
```

## Crimson-Police/blocks/protect_rescue/client.lua

```text

 blocks/protect_rescue/client.lua · objective block "protect_rescue" (client half)

  What it does
    From prepare (the hostages spawn then) on the run host only: CP.Npc.apply once it has control of
    each hostage, then the task for its cp state (restrained -> kneel, idle/safe -> cower,
    freed -> follow to the safe marker, re-issued every RETASK_MS while walking); again after
    hostChanged. Control is requested before every task (the officer next to a hostage often owns
    it) and a task that CP.Npc.task refused is retried on the next loop.
    While the objective is current on this participant's client:
    - ox_target "Cut restraints" (exports.ox_target:addLocalEntity, option crimson-police:cut_restraints)
      on every restrained hostage, re-attached when the entity handle changes, removed in stop;
      selecting it reports 'free_start', runs lib.progressBar(freeTime) and reports 'freed';
    - the safe marker (DrawMarker only within MARKER_RANGE, otherwise Wait(750)) and blips for the
      hostages and the safe point (none with Radio Silence);
    - a HUD line (ctx.hudDetail) while freed hostages are walking to the safe point.

  Objective fields read: freeTime, target.label / icon / distance, safe, safeRadius (ctx.obj);
    location[obj.safe].
  Evidence sent: { type = 'free_start', netId }, { type = 'freed', netId }
  Server data (update): { peds = { { netId, state, index } } }
```

## Crimson-Police/blocks/protect_rescue/server.lua

```text

 blocks/protect_rescue/server.lua · objective block "protect_rescue" (server half)

  What it does
    Spawns the NPCs to protect (hostages) when the run moves to In progress (prepare), kneeling with
    their hands tied (state 'restrained', relationship group CRIMSONPOLICE_NEUTRAL through the cp
    bag cfg; they are not invincible and can die). When this objective becomes current (in Hostage
    Rescue: after the hostiles of objective 1 are neutralised) participants free each hostage with
    ox_target "Cut restraints" (freeTime progress): the client reports 'free_start' then 'freed'
    and the server checks the distance (server-side coordinates) and the elapsed time. A freed
    hostage walks to the safe marker (host AI, CP.Npc task follow) and becomes 'safe' once the
    server sees it within safeRadius of it. Completed when every hostage is safe.
    With restrained = false the hostages start cowering ('idle') and walk to safety when the
    objective starts. Hostages are watched for the whole run, also while an earlier objective is
    current: damage by an active participant costs hitPenalty (penalty hostage_hit, shared; someone
    who left shoots as an outsider), any damage loses the no_hostage_hurt bonus, a death fails the
    run (failIfDies), and a hostage killed by a participant, also one who left, always fails it
    (run.fail_killed_unarmed).

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.protect_rescue)
    minSeconds [15] · presenceRange [presenceRange[3] = 150] · label
    npcs        location key: list of vec4 (hostage spots; reused with an offset when fewer than count) ['hostages']
    count       hostages                                         [npcs[3] = 3]
    peds        ped models                                       [Config.Blocks.protect_rescue.peds]
    restrained  hands tied until freed                           [restrained.default = true]
    freeTime    ms of "Cut restraints" progress                  [freeTime[3] * 1000 = 6000]
    target      { label [locale block.protect_rescue.cut_restraints], icon ['fas fa-scissors'], distance [2.0] }
    safe        location key: vec3 (the safe marker)             ['safe']
    safeRadius  metres                                           [6.0]
    hitPenalty  points per hit by participant fire (0 = off)     [hitPenalty[3] = 50]
    failIfDies  a hostage death fails the run                    [failIfDies.default = true]

  Evidence accepted (onEvent)
    { type = 'free_start', netId }   a participant started cutting (within target.distance + slack)
    { type = 'freed', netId }        cutting finished: same participant, in range, at least
                                     FREE_SHARE × freeTime after its free_start (one pending cut
                                     per participant: a new free_start replaces the previous one)
    { type = 'shot', netId, src }    CP.Npc (CP.Runs.dispatch): a participant shot a restrained hostage
    { type = 'damaged', netId, attacker }  CP.Npc (CP.Runs.dispatch): a hostage took damage
    CP.Npc.onDamaged(run, netId, attackerSrc) is the damage channel: it is server-only and fires for
    every hit on a hostage. While it is listened to, 'shot' / 'damaged' are acknowledged without
    effect, because onEvent cannot tell a dispatch from the same shape sent as client evidence
    (a client could otherwise cost the team hostage_hit). Without onDamaged they count instead.
    One hit per hostage and attacker is counted per HIT_WINDOW_MS (one bullet, one penalty).
    no_hostage_hurt is recorded only once minSeconds has passed since the start (a completion
    refused as too fast must not keep a bonus a later hit would have cost).

  Bonus / penalty ids recorded (shared)
    hostage_hit      ctx.penalize, count 1 per counted hit by participant fire (points hint -hitPenalty)
    no_hostage_hurt  ctx.award once at completion when no hostage was ever damaged
  Fail reason keys: block.protect_rescue.fail_died · run.fail_killed_unarmed

  ctx.state
    block, rng, peds = { [tostring(netId)] = { netId, entity, index, state, hurt } }, spawned, order,
    freeing = { [netIdKey] = { [srcKey] = ms } }, lastHit = { ['netId:src'] = ms }, hurt, hits,
    bonusGiven, current, startedAt, dirty, hudText, completed, failed, stopped
```

## Crimson-Police/blocks/pursuit/client.lua

```text

 blocks/pursuit/client.lua · objective block "pursuit" (client half)

  What it does (while the objective is current on this participant's client)
    - every participant: reports rams of suspect vehicles by the car they drive (IsEntityTouchingEntity
      rising edge, polled every RAM_POLL_MS only while a suspect vehicle is within RAM_WATCH; speed =
      the pre-impact speed) when ramSpeed is 0 or the speed is above it; 'lights_near' when their lights
      or siren are on within trigger.distance of a waiting car; 'aim' after aiming at an unarmed
      suspect on foot for AIM_HOLD_MS (AIM_STOPPED by the car, flee_arrest.aimDistance when running);
      'stunned' when IsPedBeingStunned; follow mode: 'undriveable' when the car they drive is no
      longer driveable. The server re-checks every report with its own coordinates.
    - blips for suspect vehicles and suspects on foot (none with Radio Silence) and a HUD line
      (ctx.hudDetail): follow progress / lost countdown, escape countdown, lights hint, stop and
      detain progress, aim hint.
    - on the run host only: control of every suspect and car before anything is done to them (re-apply
      and re-task when control comes back from another client), CP.Npc.apply once per entity handle,
      seats them, locks the car, then drives: CP.Npc.task(driver, 'driveRoute', { vehicle, points,
      loop, speed (m/s), style, stopRange, force }) from the next waypoint of the route (a loop is
      re-tasked lap by lap, an open route ends in a free flee that stays a free flee after a regain or a
      new host: the server's routeDone), or CP.Npc.task(driver, 'flee', {
      vehicle, speed, style, force }) for a free flee; a stuck car is re-tasked every RETASK_MS (force:
      CP.Npc ignores identical repeats). CP.Npc maps the style name ('cautious' | 'reckless') to the
      driving flags. After a stop the occupants leave the car (TaskLeaveVehicle, repeated every
      EXIT_RETRY_MS, warping them out from the EXIT_WARP_TRY-th attempt: the server keeps them
      'stopped' until they are out); fleeing -> CP.Npc 'flee', hostile -> 'combat', and on first sight
      (new host) surrendered -> 'kneel', cuffed -> 'cuffed'. The arrest target ("Detain driver" /
      "Cuff suspect") is CP.Npc's (enableCuff). Everything is re-applied after hostChanged.

  Objective fields read: mode, route, speed, style, trigger, surrenderOnAim, ramSpeed, failIfUndriveable,
    neverShoots (ctx.obj); location[route].
  Evidence sent: { type = 'ram', netId, speed }, { type = 'lights_near', netId }, { type = 'aim', netId },
    { type = 'stunned', netId }, { type = 'undriveable', netId }
  Server data (update): { kind = 'state', mode, fled, trigger, lights, vehicles = { { netId, index, state,
    occupants, routeDone } }, suspects = { { netId, vehicle, seat, state, armed } }, detained, neutralised, total,
    stopped, vtotal, escaping, follow = { inRange, duration, hold, lost, average } }
```

## Crimson-Police/blocks/pursuit/server.lua

```text

 blocks/pursuit/server.lua · objective block "pursuit" (server half)

  What it does
    Suspect vehicles (networked, ctx.spawnVehicle) with their occupants (ctx.spawnPed, seated with the
    server SetPedIntoVehicle and again by the run host) drive away from the participants. The run
    host's client drives them: along a recorded road route waypoint by waypoint (route = location key
    { points, loop }; a loop is raced lap after lap, an open flee route ends in a free flee, marked
    routeDone in the snapshot once the car is within ROUTE_END of its last waypoint) or in a
    free flee (route = nil). Two modes:
    - stop (Street Race Bust, Stolen Vehicle Takedown): stop every vehicle. A vehicle is stopped when
      the server sees it below stopped.speed km/h (GetEntitySpeed) for stopped.seconds in a row, once
      it has been moving (or NEVER_MOVED_MS after it fled), or when it is wrecked. Its occupants get
      out; each one rolls footFlee (ctx.rng) to run on foot. The others wait by the car and surrender
      when a participant aims at them (surrenderOnAim) or at once (surrenderOnAim = false: racers).
      Suspects give up when aimed at (AIM_STOPPED by the car, Config.Blocks.flee_arrest.aimDistance
      when running), when stunned, or when a participant stays within flee_arrest.closeDistance for
      closeSeconds. Surrendered suspects are arrested with CP.Npc.enableCuff (arrest.label /
      arrest.duration: "Detain driver" 3 s on Street Race Bust). Done when every suspect is
      neutralised (cuffed, or dead without a participant kill). complete = 'all_or_timeout_any'
      (Street Race Bust) also needs at least one suspect detained before it completes early, and
      completes at the time limit when at least one was detained (onTimeout); none detained fails.
      A suspect more than escape.distance from every participant for escape.seconds escapes: fail.
      Occupants only switch from 'stopped' to fleeing / hostile / surrendered once they are out of
      the car (the host client retries the exit and finally warps them out).
    - follow (Pursuit Sim): stay within hold metres of the suspect vehicle (or its driver on foot
      after a wreck; with several suspects, the one nearest the party) for a total of duration seconds. More than lost.distance from every participant
      for lost.seconds straight fails, and so does the officer's vehicle becoming undriveable
      (failIfUndriveable). The average distance sets the medal, awarded only when the full duration
      was held; run.flags.medals = true. A target that died without a participant kill ends the
      objective without a medal.
    Vehicles start when the objective starts (trigger 'arrive' or { ahead }) or, with trigger
    { distance, lights }, when a participant with lights on is within distance (client evidence
    'lights_near', checked with server coords), when any participant gets within FLEE_CLOSE, or when
    the car is hit. Rams of a suspect vehicle above ramSpeed km/h (0 = any contact) are penalised.
    Killing an unarmed, surrendered or cuffed suspect (a participant kill) fails the run.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.pursuit)
    minSeconds [30] · presenceRange [presenceRange[3] = 400] · label
    mode               'stop' | 'follow'                                   [mode.default = 'stop']
    vehicles           suspect vehicles (scales)                           [vehicles[3] = 1]
    models             vehicle models                                      [Config.Builder.allowed.vehicles]
    peds               suspect ped models (added field)                    [Config.Blocks.hostile_waves.peds]
    suspectsPerVehicle occupants per vehicle, driver included, max 4        [suspects[3] = 1]
    spawn / spawns     vec4 key / list key; else placed on the route (loop: ROUTE_BACK waypoints
                       before the intercept start), else ahead of the start
    route              location key of a road route { points, loop }       [nil = free flee]
    speed [speed[3] = 120] km/h · style 'cautious' | 'reckless'            [style.default = 'reckless']
    trigger            'arrive' | { distance = 60.0, lights = true } | { ahead = 50.0 }   ['arrive']
    stopped            { speed [5.0] km/h, seconds [5] }
    footFlee [footFlee[3] / 100 = 0.2] · surrenderOnAim [true]
    arrest             { label [locale block.pursuit.arrest], duration [5000] ms }
    follow mode        hold [holdDistance[3] = 150] · lost { distance [250], seconds [10] }
                       duration [180] s · medals { gold [40], silver [80], bronze [150] } | false
                       failIfUndriveable (added) [true in follow mode, false in stop mode]
    escape             { distance, seconds } | false   [stop + 'all_detained': flee_arrest escape
                       defaults 400 m / 20 s; otherwise false]
    complete           'all_detained' | 'all_or_timeout_any'              ['all_detained']
    ramSpeed [100] km/h (0 = any contact) · ramPenaltyId ['hard_ram'] · neverShoots [true]
    weapons (added, only with neverShoots = false)                        [Config.Blocks.flee_arrest.weapons]
    detainBonus (added)      id per detained suspect   ['racer_detained' with 'all_or_timeout_any', else false]
    allDetainedBonus (added) id when all detained      ['all_racers_detained' with 'all_or_timeout_any', else false]
    fastStop (added)         { id, seconds } | false   [stop + 'all_detained': { 'vehicle_stopped_fast', 120 }]

  Evidence accepted (onEvent)
    { type = 'ram', netId, speed }      the reporter's vehicle touched suspect vehicle netId at speed km/h;
                                        reporter in a vehicle within RAM_RANGE (server coords), speed
                                        plausible against the server's samples, once per RAM_COOLDOWN_MS
    { type = 'lights_near', netId }     lights/siren on within trigger.distance of a waiting car
    { type = 'aim', netId }             an unarmed suspect on foot aimed at (server distance + weapon check)
    { type = 'stunned', netId }         a suspect seen stunned; a participant within STUN_RANGE and the
                                        reporter within STUN_REPORT (server coords)
    { type = 'low_health', netId }      an armed suspect (neverShoots = false) re-checked below 50 % health
    { type = 'undriveable', netId }     follow mode: the reporter's vehicle, confirmed by server engine/tank health
    { type = 'cuffed', netId }          CP.Npc after a validated cuff (the cp bag says cuffed)
    { type = 'shot', netId, src }       CP.Npc: a surrendered/cuffed suspect was shot (penalty recorded there)

  Bonus / penalty ids recorded (shared)
    ramPenaltyId ['hard_ram'; Pursuit Sim 'ram'] ctx.penalize count 1 per counted ram
    detainBonus ['racer_detained'] ctx.award count 1 per detained suspect
    allDetainedBonus ['all_racers_detained'] once when every suspect was detained
    fastStop.id ['vehicle_stopped_fast'] once when every vehicle stopped within fastStop.seconds of the start
    medal_gold | medal_silver | medal_bronze   follow mode, by average distance (medals); points hint
                                        MEDAL_POINTS (card values 50 / 25 / 10, capped on custom missions)
  Custom missions (validate): detainBonus / allDetainedBonus / fastStop.id / ramPenaltyId are false, a
    Config.Bonuses id or the block default (ID_DEFAULTS); fastStop.seconds at most 120; arrest.duration
    1000-30000 ms
  Fail reason keys: block.pursuit.fail_escaped · block.pursuit.fail_lost · block.pursuit.fail_undriveable ·
    block.pursuit.fail_setup · run.fail_killed_unarmed

  ctx.state
    block, mode, rng, vehicles = { [tostring(netId)] = { key, netId, entity, index, state = 'waiting'|
    'fleeing'|'stopped'|'wrecked', occupants = { pedKey }, want, slowFor, moved, fleeAt, body } }, vorder,
    peds = { [tostring(netId)] = { netId, entity, vehicle, seat, armed, state = 'driving'|'stopped'|
    'fleeing'|'hostile'|'surrendered'|'cuffed'|'dead', fleeRoll, stoppedAt, far, close } }, counts,
    fled, startedAt, detained, rams, speeds, officerVeh, follow = { inRange, lostFor, sum, samples },
    medal, escaping, dirty, completed, failed, halted
```

## Crimson-Police/blocks/search_area/client.lua

```text

 blocks/search_area/client.lua · objective block "search_area" (client half)

  What it does (while the objective is current on this participant's client)
    - the search circle as a radius blip with a centre blip, redrawn whenever the server shrinks it;
      blips for clues not yet checked and for fugitives on the run (none of these with Radio Silence);
    - an ox_target sphere zone on every clue not yet checked (option crimson-police:check_clue, label by
      clue kind); selecting it reports 'clue_start', runs lib.progressBar(clueProgress) and reports
      'clue'; a marker over each clue not yet checked (DrawMarker only within MARKER_RANGE, otherwise
      Wait(750));
    - 'stunned' reports for fugitives seen stunned (IsPedBeingStunned); the server re-checks distances;
    - a HUD line (ctx.hudDetail): enter the area, clues checked and circle size while a clue is still
      pending (a lost one is handled), then fugitives in custody, escape countdown, and "stay close" while
      this player is within givesUp.close.distance of a fugitive on the run;
    - on the run host only: control of each fugitive and the witness before anything is done to it
      (re-applied and re-tasked when control comes back from another client), CP.Npc.apply, then
      the task for its cp state: idle (hiding) -> 'cower', fleeing -> 'flee', and on first sight (new
      host) surrendered -> 'kneel', cuffed -> 'cuffed'; the witness stands at its spot
      (TaskStartScenarioInPlace). The "Cuff suspect" target is CP.Npc's (enableCuff).

  Objective fields read: clueProgress.label / duration, givesUp.close, runDistance (ctx.obj).
  Evidence sent: { type = 'clue_start', clue }, { type = 'clue', clue }, { type = 'stunned', netId }
  Server data (update): { kind = 'state', circle = { x, y, z, r, n }, clues = { { i, x, y, z, kind, model,
    netId, status } }, fugitives = { { netId, state } }, checked, clueTotal, arrests, neutralised, total,
    entered, escaping }
```

## Crimson-Police/blocks/search_area/server.lua

```text

 blocks/search_area/server.lua · objective block "search_area" (server half)

  What it does
    A search circle of startRadius metres around location[center] (Manhunt: the run starts when the first
    participant enters it). clueCount clue spots are picked at random (ctx.rng) from location[clues];
    each gets a clue from clueProps: a prop (ctx.spawnObject, frozen) or, for 'witness', a witness NPC
    (ctx.spawnPed). Participants check a clue with ox_target (clueProgress.duration; 'clue_start' then
    'clue', both within CLUE_RANGE of the spot by server coordinates, the second at least TIMED_SHARE of
    the duration later). Every checked clue shrinks the circle to the next shrinkTo radius; the server
    picks the new centre with ctx.rng within 0.7 × the new radius of a fugitive still at large (nested in
    the old circle when possible), so the circle always contains a fugitive.
    `fugitives` (scales) unarmed fugitives hide at random hiding spots (distinct first). A hidden
    fugitive runs when a participant gets within runDistance (server distance, every tick). Fugitives
    give up when stunned (client 'stunned', a participant within STUN_RANGE) or when a participant stays
    within givesUp.close.distance for givesUp.close.seconds; then "Cuff suspect" (CP.Npc.enableCuff).
    A fugitive who ran and is more than escape.distance from every participant for escape.seconds
    escapes: the run fails. Killing a fugitive or the witness (a participant kill) fails the run.
    Done when every fugitive is neutralised (cuffed, or dead without a participant kill).
    clues_first is awarded once when every clue was checked before the first arrest.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.search_area)
    minSeconds [60] · presenceRange [presenceRange[3] = 100] (margin outside the current circle) · label
    center       vec3 location key                               ['center'; falls back to location.start]
    startRadius  [startRadius[3] = 600] · shrinkTo [Config.Blocks.search_area.shrinkTo = { 300, 150, 50 }]
    clues        list location key (6+)                          ['clues']
    clueCount    [clues[3] = 3]
    clueProps    prop models or 'witness'                        [{ 'prop_cs_heist_bag_02', 'prop_npc_phone_02', 'witness' }]
                 (custom missions: only these; witnessModel and peds from Config.Builder.allowed.peds;
                 givesUp.close off or exactly flee_arrest closeDistance / closeSeconds; clueProgress and
                 cuff durations 1000-30000 ms; cuff.maxDistance at most CUFF_RANGE)
    witnessModel (added) ped model of the witness                [the first of Config.Blocks.protect_rescue.peds]
    clueProgress { label [locale block.search_area.clue_progress], duration [4000] ms }
    hiding       vec4 list location key (6+)                     ['hiding']
    fugitives    (scales)                                        [fugitives[3] = 1]
    peds (added) fugitive models                                 [Config.Blocks.hostile_waves.peds]
    runDistance  [runDistance[3] = 30.0]
    givesUp      { stun [true], close { distance [closeDistance = 3.0], seconds [closeSeconds = 3] } | false }
    escape       { distance [300], seconds [30] }
    cuff         { label [locale block.search_area.cuff], duration [5000], maxDistance }

  Evidence accepted (onEvent)
    { type = 'clue_start', clue }   a participant started checking clue n (1-based, the list the server sends)
    { type = 'clue', clue }         ...and finished it
    { type = 'stunned', netId }     a fugitive seen stunned; a participant within STUN_RANGE and the
                                    reporter within STUN_REPORT (server coords)
    { type = 'cuffed', netId }      CP.Npc after a validated cuff (the cp bag says cuffed)
    { type = 'shot', netId, src }   CP.Npc: a surrendered/cuffed fugitive was shot (penalty recorded there)

  Bonus / penalty ids recorded (shared)
    clues_first   ctx.award once: every clue checked (by participants) before the first arrest
  Fail reason keys: block.search_area.fail_escaped · block.search_area.fail_setup · run.fail_killed_unarmed

  ctx.state
    block, rng, circle = { center, radius, n }, clues = { { i, coords, kind = 'prop'|'witness', model,
    netId, entity, status = 'pending'|'done'|'lost', starts = { [src] = ms } } }, fugitives = { [key] =
    { netId, entity, spot, state = 'idle'|'fleeing'|'surrendered'|'cuffed'|'dead', ran, far, close } },
    order, count, entered, arrests, checked, cluesFirst, escaping, dirty, completed, failed, halted
```

## Crimson-Police/blocks/skill_check/client.lua

```text

 blocks/skill_check/client.lua · objective block "skill_check" (client half)

  What it does
    Registers an ox_target sphere zone on every armed target of the server's snapshot (option names
    "crimson-police:skill_check:<runId>:<objective>:<target>"). Selecting it plays a kneeling animation
    and runs the target's remaining lib.skillCheck rounds one at a time, reporting each round at once;
    a miss stops the sequence (select the target again to retry the same round). When the server
    says a target went off, the client of the participant it names plays the explosion effect
    (AddExplosion with damage scale 0: effect only, hurts nobody). Blips per armed target (none under
    Radio Silence), a small marker within 30 m, and the HUD line via ctx.hudDetail. No networked
    entities are created here and there are no NPCs (hostChanged only records the flag).
    The block's client state is kept per run and objective in this file (stateOf), so it also works
    when the engine hands every hook a fresh ctx.state table.

  Objective fields read: checks [easy, medium, medium, hard], missPenalty [30], target { label, icon },
    explosion [true]
  Evidence sent (ctx.report)
    { type = 'check', target, index, success, seq }   one skill-check round (seq counts this client's
        reports: two misses in a row on the same round are never identical reports)
  Bonuses / penalties: none on the client (the server records no_missed_checks).
```

## Crimson-Police/blocks/skill_check/server.lua

```text

 blocks/skill_check/server.lua · objective block "skill_check" (server half)

  What it does
    Every target (a device from run.shared.devices, or a point of a location key) must be worked with
    a sequence of ox_lib skill checks. The client reports each round as it happens; the server keeps
    the progress per target: a success moves to the next round, a miss repeats the round, takes
    missPenalty seconds off the run timer (CP.Runs.adjustTimer) and counts toward failAfter misses in
    a row on that target, which sets it off: an explosion effect only (played by the client of the
    participant who missed; damage scale 0) and the run fails for everyone. Done when every target is
    defused; no_missed_checks when nobody missed a round. One participant works a target at a time
    (the lock frees itself after 15 s without a round). Powers Bomb Disposal's defusing.
    Device props: the search objective spawned them, and the engine may delete an objective's entities
    when that objective ends (ARCHITECTURE §7.1 stop). While this objective runs, an armed device whose
    prop no longer exists is spawned again here (same model, coords and heading from run.shared.devices,
    role 'device', frozen; it waits for ctx.canSpawn like any spawn). Distances always fall back to the
    device's recorded coords, so defusing never depends on the prop.

  Objective fields read (defaults: ARCHITECTURE §3.3 and Config.Blocks.skill_check)
    targets      'shared:devices' (devices found by an earlier interact_points hidden search) or a
                 location key (vec3/vec4 or list of them)          ['shared:devices']
    checks       difficulty per round                               [difficulty.default = easy, medium, medium, hard]
    missPenalty  seconds off the run timer per miss                 [missPenalty[3] = 30]
    failAfter    misses in a row on one target that set it off      [failAfter[3] = 2]
    target       { label, icon }                                    [label: locale default, icon default]
    explosion    play the explosion effect when a target goes off   [true]
    minSeconds [10] · presenceRange [presenceRange[3] = 150] · label

  Evidence accepted (ctx.report from the client half)
    { type = 'check', target, index, success }   one round: index must be the target's next round,
                                                 the reporter within 5 m of the target (server coords)

  Evidence may also carry seq (the client's report counter); it is not used here.
  Messages sent (ctx.send): { kind = 'state', targets, checks } after every change;
    { kind = 'explode', target, coords, by, effect } when a target goes off (by = reporting src, or the
    run host when the timer runs out)
  Bonuses / penalties recorded (shared): no_missed_checks (ctx.award)
  Fail reason keys: block.skill_check.fail_exploded
```

## Crimson-Police/config/blocks.lua

```text

config/blocks.lua · Mission Builder ranges and defaults.
Numbers are { min, max, default }; the tablet only accepts values in range,
and the server checks them again on publish and on /CrimsonPoliceAdmin reload.
Times are seconds, distances metres, speeds km/h, chances percent. When the builder
writes a mission file it converts chances to fractions (30 → 0.30) and progress
times to milliseconds (5 → 5000), the units mission files use.
```

## Crimson-Police/modules/access/client.lua

```text

modules/access/client.lua · CP.Access (client): the latest officer and department the server sent.

Display data only: the server re-checks access on every request and action. The tablet
(modules/tablet/client.lua) calls setSession with every Session it receives (opening a UI, switching
UI and the silent theme fetch at login) and clear() when the character unloads or is no longer an
officer. This module also clears itself on character unload and when the player goes off duty.

Public API
  CP.Access.current() -> officer|nil
      a copy of { citizenid, name, department, departmentLabel, departmentShort, rank, callsign|nil,
      gradeLevel, roles = { officer, supervisor, admin }, theme, logo|nil } from the latest Session;
      nil when the player is not (or no longer) a qualifying officer.
  CP.Access.department() -> { key, label, short, theme, logo|nil }|nil
  CP.Access.roles() -> { officer, supervisor, admin }   (all false without a session)
  CP.Access.setSession(session)   used by modules/tablet
  CP.Access.clear()               used by modules/tablet
```

## Crimson-Police/modules/access/server.lua

```text

modules/access/server.lua · CP.Access (server): departments, roles, duty, active job, rank and
callsign, suspension checks.

Owns: the sanitised copy of Config.Departments (theme and logo validation with ONE console warning
per bad key), who counts as an officer / supervisor / admin, the Crimson-Police suspension
(cp_officers.suspended_until), the stored copy of rank, callsign and name (cp_officers), the
immediate "no longer qualifies" signal (onLost) and the server export GetDepartment.
All framework data comes through CP.Qbx; SC-Dispatch suspensions through CP.Dispatch.

Public API (docs/ARCHITECTURE.md §5.2)
  CP.Access.departmentForJob(jobName) -> deptKey|nil
  CP.Access.department(key) -> dept|nil       (a copy)
      dept = { key, label, short, jobs = { jobName... }, supervisorGrade, societyAccount,
               theme = { primary, accent, background, surface, text },
               logo = { url|nil, file|nil, watermark, opacity, size, grayscale } }
      Colours must be 6-digit hex: a missing or invalid one falls back to the Crimson-Police default
      (one warning per department and key); a missing text colour is picked with CP.U.contrastText
      for the background (an invalid one too, with a warning). logo.url is the configured https://
      url, else https://cfx-nui-Crimson-Police/logos/<file> (file names only: no folders);
      opacity is clamped to 0-0.25 (default 0.08), size to 0.05-1 (default 0.6), watermark defaults
      to true, grayscale to false.
  CP.Access.departments() -> { dept, ... }     sorted by key (copies)
  CP.Access.getOfficer(src) -> officer|nil, errKey
      officer = { src, citizenid, name, department, departmentLabel, departmentShort, job, rank,
                  gradeLevel, callsign|nil, onduty = true, isSupervisor, isAdmin }   (§3.1)
      Only the ACTIVE Qbox job counts (a department job held as a second sc-multijob job gives no
      access). errKeys, in check order: err.not_police (no character, or the active job is in no
      department), err.not_on_duty, err.suspended (Crimson-Police), err.suspended_dispatch
      (SC-Dispatch, checked for the active job). Suspension lookups are cached for 15 s.
  CP.Access.isAdmin(src) -> boolean            IsPlayerAceAllowed(src, Config.AdminAce); 0 = console = true
  CP.Access.isSupervisor(src) -> boolean       a qualifying officer whose grade >= supervisorGrade
  CP.Access.role(src) -> 'admin'|'supervisor'|'officer'|nil   (the highest)
  CP.Access.recheck(src, jobName) -> ok, endReason
      For a run participant who accepted with jobName: 'job_change' (active job differs from jobName,
      or is in no department), 'off_duty', 'suspended' (either suspension). A player without a loaded
      character returns true: the drop/unload paths end the run as disconnected.
  CP.Access.isSuspended(citizenid) -> boolean, untilTs|nil
  CP.Access.suspend(citizenid, days, actorSrc, reason) -> ok, errKey
      0 days lifts it. days: a whole number 0-3650 (err.invalid_days); citizenid as stored by Qbox
      (err.invalid_citizenid). When actorSrc is a player it must pass CP.Permissions.can(actorSrc,
      'suspend') (err.no_permission). An online officer is told on their tablet and a new suspension
      fires onLost(src, 'suspended'). Not audited here: the caller (modules/admin, modules/anticheat)
      writes the audit entry.
  CP.Access.refreshOfficerRow(src) -> boolean
      Upsert cp_officers callsign (32), rank_label (40), display_name (64) and department for a
      player whose active job is in a department (on duty or not). Runs on character load, on a
      job/grade change and when the tablet opens. Every text value (here and in the officer table) is
      cut to that many bytes without splitting a UTF-8 character (strict mode rejects half a character).
  CP.Access.onLost(fn(src, endReason))
      Fired right after a qbx duty/job/group event for a player whose last known active job (seeded at
      start, on load and by the first getOfficer/recheck) was a department job and who no longer qualifies: 'job_change' (the active job changed, including to
      'unemployed'), 'off_duty', 'suspended'. Listeners check whether the player is on a run.
  Server export GetDepartment(src) -> deptKey|nil   the department of the player's active job
                                                     (whether or not they are on duty)
getOfficer, isSupervisor, role, recheck, isSuspended, suspend and refreshOfficerRow may yield
(database): call them from a handler or thread.
```

## Crimson-Police/modules/admin/server.lua

```text

 modules/admin/server.lua · CP.Admin (server): supervisor and admin actions, /CrimsonPoliceAdmin, the
  audit log (cp_audit) and the Discord webhooks.

  Owns
    * the /CrimsonPoliceAdmin command (Config.Tablet.adminCommand, registered at runtime) with every
      subcommand of the spec, usable from the server console (src 0) and in game (ace Config.AdminAce):
        (no args)                                        open the Admin UI (in game)
        help                                             list the subcommands
        payout type <type> <amount|clear> <reason...>    CP.Payouts.setType
        payout mission <missionId> <amount|clear> <reason...>  CP.Payouts.setMission
        award <citizenid> <points> <reason...>           CP.Scoring.manualAward
        season start <name...> | season end              CP.Challenge.startSeason / endSeason
        suspend <citizenid> <days> [reason...]           CP.Access.suspend (0 days lifts it), audited here
        reload                                           CP.Missions.reload, audited here
        test <missionId> [tier] [location|random]        CP.Testing.command -> CP.Testing.start (in game only;
                                                         archived custom missions through CP.Testing.resolveMission)
        storage                                          where the data is kept (CP.Storage.mode(): the database or
                                                         the saves folder), rows per cp_ table, the saves folder size
        storage copy database-to-files|files-to-database [force]
                                                         copies every cp_ table (not cp_schema_migrations) between
                                                         MariaDB (the real oxmysql) and the saves folder engine, ids and
                                                         AUTO_INCREMENT counters kept; refused while a run or
                                                         operation is active, and into a target with rows unless
                                                         force; a failure empties the target again; audited as
                                                         storageCopy (also in the target's cp_audit when the target is
                                                         not the storage in use). Details: the "storage" section
                                                         of this file and docs/ARCHITECTURE.md §5.29.
      Replies: print() on the console, CP.Tablet.notify in game.
    * cp_audit rows (values clipped to the column sizes) and the category webhooks read at call time
      from the convars cp_webhook_audit / cp_webhook_flags / cp_webhook_builder / cp_webhook_operations /
      cp_webhook_board (missing or empty = off; only https:// urls), posted with PerformHttpRequest as
      Discord embeds through a rate-limited queue (one post per url every 2.1 s, 429 retry_after honoured,
      5xx/network errors retried, at most 100 queued).
    * flagged-run review (approve / void), voiding any run, force recall, manual award and suspension
      actions, and the supervisor/admin read callbacks listed below.

  Public API (docs/ARCHITECTURE.md §5.25)
    CP.Admin.audit(actor, role, category, action, target, old, new, reason) -> auditId|nil
        actor: src (number; 0 = console), citizenid (string) or 'console'. role: 'supervisor'|'admin'|
        'console'; anything else (e.g. 'officer', 'system') is stored as 'console' = an automatic entry
        (the cp_audit enum has no other value). category: 'audit'|'flags'|'builder'|'operations'; 'board'
        is stored as 'audit' and posted to the board webhook. action <= 40 chars, target/old/new <= 64,
        reason <= 255 (clipped). Posts the category webhook. Called outside a coroutine it writes from a
        new thread and returns nil.
    CP.Admin.webhook(category, title, description, fields) -> queued (boolean)
        category: audit|flags|builder|operations|board. fields: { { name, value, inline }, ... } (or
        { name, value } pairs); texts are already translated. false when that webhook is off.
    CP.Admin.approveFlagged(src, rowId, reason, opts) -> ok, data|errKey
    CP.Admin.voidFlagged(src, rowId, reason) -> ok, data|errKey
    CP.Admin.voidRun(src, rowIdOrRunUuid, reason) -> ok, data|errKey      (permission voidAnyRun)
        approve: flagged = 0 (flag_reason kept), CP.Cash.release when cash is held,
        CP.Scoring.onRowApproved, CP.Leaderboard.invalidate. void: voided = 1 (voidFlagged only while still
        flagged, else err.conflict), CP.Scoring.onRowVoided,
        cash untouched (held cash is forfeited by CP.Cash after the dispute window; a paid run is not
        clawed back), CP.AntiCheat.onVoided for mission rows, invalidate. Reason required. Reviewers who
        took part are refused (CP.Permissions.canReviewRun, plus a participant still on the live run who
        has no row yet: err.own_run); supervisors only for runs involving their department
        (err.other_department). Texts are clipped by characters, never inside a UTF-8 sequence.
        opts (approveFlagged, used by CP.Disputes): { skipPermission = true, noAudit = true, quiet = true (no toast) }
    CP.Admin.forceRecall(src, runId, targetSrc, reason) -> ok, data|errKey
        never on a run the caller is or was on (err.recall_own_run; test runs excepted); a target who left
        while the permission check waited: err.not_participant, nothing audited
    CP.Admin.getRow(rowId) -> row|nil, errKey        one cp_mission_runs row (flagged/voided as booleans)
    CP.Admin.runDepartments(runUuid) -> { deptKey, ... }   departments of every row (and live participant)
    CP.Admin.resolveCitizenId(input) -> citizenid|nil  the stored form (cp_officers, else an online player)
    CP.Admin.missionLabel(missionId) -> text
    CP.Admin.command(src, args) -> the /CrimsonPoliceAdmin handler (also used by tests)

  Net (docs/ARCHITECTURE.md §8.3)
    actions
      server:sup:forceRecall     { runId, src, reason? }                forceRecall (runs involving their dept)
      server:sup:reviewFlagged   { rowId, decision = 'approve'|'void', reason }   reviewFlagged
      server:admin:reviewFlagged { rowId, decision, reason }            admin
      server:admin:voidRun       { rowId } | { runUuid }, reason         voidAnyRun
      server:admin:awardPoints   { citizenid, points, reason }           manualAward -> CP.Scoring.manualAward
      server:admin:suspend       { citizenid, days, reason }             suspend -> CP.Access.suspend (audited)
    callbacks (shapes in docs/notes/oversight.md and web/src/types/oversight.ts)
      getMissionList             viewMissionList -> MissionListData
      admin:getMissions          admin -> MissionListData, each mission + { filePath, editedInCode, defHash, status,
                                 disabledInConfig }
      sup:getLiveRuns            viewMissionList -> { runs = { LiveRun + extras }, serverTime, canRecall }
      sup:getReviewQueue         reviewFlagged|handleDisputes -> { flagged, disputes, canReview, canHandle }
      admin:getFlagged           admin -> { flagged }
      admin:searchOfficers       { query } -> { officers }
      admin:getOfficer           { citizenid } -> OfficerDetail (incl. suspensions = the last 10 suspend/unsuspend/autoSuspend entries)
      admin:getDepartments       -> { departments, cashSource, showSociety }
      admin:getPermissions       -> { supervisor = { { action, enabled } }, adminOnly, always }
      admin:getAudit             { category, action, actor, from, to, page } -> AuditPage
      admin:exportAudit          same filters -> { csv, rows, truncated }
      admin:getStuckPayments     admin -> { payments = CP.Cash.stuckPayments() (StuckPayment list, docs/notes/economy.md),
                                 serverTime }   rows left 'paying' for a manual Renewed-Banking check
```

## Crimson-Police/modules/alerts/server.lua

```text

modules/alerts/server.lua · CP.Alerts (server): Hard rule 16 (no mission alerts) and the only writer
of the crimsonArena state bag (docs/ARCHITECTURE.md §5.14, docs/CRIMSON_ARENA.md rules 1, 2, 3, 9, 11).

Owns: the replicated player state bag key 'crimsonArena' (the name is fixed by sc-dispatch,
sc-ambulance and Crimson-Arena), the intent table 'wanted', the re-assert of our flag after another
resource wiped it, the in-arena detection for active participants (they leave the run as 'quit'),
foreignClearedAt, the start/stop cleanup, and the dispatch backstop that clears shots-fired,
person-down and person-dead calls that slipped through while a participant carries the flag.

Our value is always { active = true, source = 'crimson-police' }. A value is FOREIGN when it is a table
with active == true whose source is not 'crimson-police' (Crimson-Arena writes { active, matchId }).
A foreign value is never overwritten and never cleared; any other value that is not ours ('other') is
never overwritten either. The state bag change handler only queues work (SetTimeout 0): it never yields
and never writes the bag. Nothing here calls CancelEvent, and emsdown_ calls (the permitted EMS request)
are never cleared.

Public API
  CP.Alerts.set(src, run|runId?) -> boolean
      Records wanted[src] = { runId, setAt } and writes our value (replicated). Refuses (false, nothing
      recorded) while the value is foreign or not ours, or while the player is in a routing bucket ~= 0.
      runId defaults to CP.Runs.getBySrc(src). Idempotent.
  CP.Alerts.clear(src, opts?) -> boolean
      Forgets wanted[src] and removes the value only when its source is 'crimson-police' (true when a
      value was removed). While CP.Downed holds the flag of a downed participant (hold), a clear without
      opts.force is ignored (returns false): the flag stays until the pick-up is done or just before the
      EMS request. opts.force also drops the hold.
  CP.Alerts.has(src) -> boolean              wanted[src] ~= nil (the intent, not the live bag)
  CP.Alerts.foreignFlag(src) -> boolean      the live value is foreign (Crimson-Arena's)
  CP.Alerts.inArena(src) -> boolean          foreignFlag(src) or GetPlayerRoutingBucket(src) ~= 0
  CP.Alerts.foreignClearedAt[src] -> ts|nil  table (read only): os.time() when a foreign value last changed
                                             to nil (Crimson-Arena let the player go)
  CP.Alerts.hold(src, on)                    CP.Downed: keep the flag of a downed participant (keepFlag)
  CP.Alerts.forget(src) -> boolean           drops our intent (wanted, hold, orphan timer, queued re-assert)
                                             WITHOUT touching the bag (CRIMSON_ARENA rule 1: CP.Runs uses it
                                             for an in-arena participant, whose bag may still hold our value
                                             while only the routing bucket has moved). true when an intent
                                             or a hold was dropped.
  CP.Alerts.onInArena(fn(src, run))          listeners, called once per run when an active participant
                                             becomes in-arena (after this module removed them)
  CP.Alerts.wanted                           the intent table (read only): wanted[src] = { runId, setAt }

In-arena participants (CRIMSON_ARENA rule 1): the 1 s reconcile checks every active participant of every
run (accepted or in progress, tests and operations included) and the change handler reacts to a foreign
value at once. This module itself drops the intent (without touching the bag), stops the route check,
cancels a pending downed pick-up/EMS request and calls CP.Runs.removeParticipant(run, src, 'quit',
{ notify = 'run.left_for_arena' }) (the engine sends the toast only when it really removed them, so the
engine's own 1 s arena re-check never doubles it); onInArena listeners are informed afterwards.

Backstop (CP.Dispatch listeners, receivedAt = os.time() captured at receipt by the integration):
  shots fired   from a src whose intent is on, or an arrived active participant of an In-progress run,
                within Config.Alerts.backstopRadius (server-side ped coords) of the location start or the
                current objective anchor (CP.Runs.anchor) -> after Config.Alerts.backstopDelay s clear
                shots_<src>_<t> for t-1, t, t+1 with { 'police' }
  person down / dead  from a src in wanted -> clear playerdown_/playerdead_<src>_<t> for t-1, t, t+1
                with { 'police', 'ambulance' }
  Srcs with a foreign value are skipped (Crimson-Arena handles them).

Start: every leftover value whose source is 'crimson-police' is removed from every online player.
Stop: every value we set is removed.
```

## Crimson-Police/modules/anticheat/server.lua

```text

 modules/anticheat/server.lua · CP.AntiCheat (server): objective-event checks, run flags, outside help,
  presence sampling, the idle check and the voids -> suspension rule.

  Owns
    * checkEvent: every client objective event (after CP.Runs' own run/participant checks) must come from
      an active participant of an in-progress run, for the CURRENT objective (an event for a later
      objective flags the run 'unexpected_event'; an earlier/finished one is dropped silently as lag),
      within a per-src rate limit (10/s), and must not be an exact duplicate of the same src's last
      events (same objective, same evidence fields apart from coords/time) within 1 s. Between two
      events of one participant the server-side ped coordinates must not move faster than
      Config.AntiCheat.maxSpeed (distance / max(1 s, elapsed)); faster flags the whole run 'speed'.
      In-arena srcs (CP.Alerts.inArena) are refused with err.in_arena and never flagged or sampled
      (CRIMSON_ARENA rule 6); a position pair across a routing-bucket change is discarded.
    * flags: run-level (src nil -> run.flagged) or participant-level (p.flagged) { reason, detail };
      the rows CP.Runs writes afterwards are flagged with that reason. The first reason is kept; every
      distinct (reason, participant) is recorded once in cp_audit (category flags, action runFlagged,
      target = run id, old_value = citizenid for a participant flag, new_value = reason,
      reason = detail) and posted to the flags webhook. The Review Queue reads the detail (e.g. who
      helped) from there. Test runs are never flagged.
    * onNpcKilled: kills of mission NPCs by players who are not active participants; at
      Config.AntiCheat.outsideKillsToFlag the run is flagged 'outside_help' naming the killer(s).
    * presence sampling every 5 s for in-progress runs that have had 2+ participants: each active
      participant's distance from the current objective (its block's presence(ctx, src, coords) with the
      engine's ctx from CP.Runs.ctx when available, else the location start) against the objective's
      presenceRange (fallback Config.AntiCheat.presenceRadius);
      p.presence = { inRange, total } in seconds.
    * the idle check: Config.AntiCheat.idleCheck s after the run moved to In progress, active participants
      who have not reached the start are removed with end reason 'idle'.
    * onVoided: Config.AntiCheat.voidsToSuspend voided mission rows created within voidWindowDays (and
      after the officer's last automatic suspension) suspend the officer for suspendDays
      (CP.Access.suspend(citizenid, days, 0, 'auto') + audit 'autoSuspend').

  Public API (docs/ARCHITECTURE.md §5.26)
    CP.AntiCheat.checkEvent(run, src, index, evidence) -> ok, reasonKey
    CP.AntiCheat.flag(run, src|nil, reason, detail) -> boolean (true when newly recorded)
    CP.AntiCheat.onNpcKilled(run, killerSrc)
    CP.AntiCheat.presenceOk(run, p) -> boolean      share >= Config.AntiCheat.presenceShare (true for solo
                                                    runs and when nothing was sampled); a failing participant is
                                                    flagged 'presence' with the share as detail (once)
    CP.AntiCheat.presenceShare(p) -> number|nil     inRange / total
    CP.AntiCheat.onVoided(citizenid) -> suspended (boolean)
    CP.AntiCheat.evidenceSignature(evidence) -> string   (pure; coords/time excluded, keys sorted)
    CP.AntiCheat._sample(), _idleCheck(), _trackBuckets()  loop bodies (tests)
```

## Crimson-Police/modules/builder/client.lua

```text

 modules/builder/client.lua · CP.Builder (client): the Mission Builder's in-world tools.
  Protocol: docs/notes/builder_protocol.md §6 (client actions, results, overlays); shapes of the overlays and
  of the fields this client adds: web/src/types/builder_client.ts; notes: docs/notes/builder_client.md.

  Owns
    * the placement tool. The tablet closes (CP.Tablet.close) into placement mode: a LOCAL, non-networked
      ghost (ped or vehicle at alpha 160, collision off, frozen) or a marker follows the point the gameplay
      camera aims at (StartExpensiveSynchronousShapeTestLosProbe from GetGameplayCamCoord). Scroll rotates
      (areas and starts: scroll changes the radius; Shift = fine steps), E places, Backspace undoes, Enter
      returns to the tablet with the points. A spot that fails a check is drawn red and cannot be placed:
      not on the ground (GetGroundZFor_3dCoord, surfaces steeper than ~45°), in water (TestProbeAgainstWater /
      GetWaterHeight), inside a wall, object or vehicle (StartShapeTestCapsule around the ped / vehicle volume),
      inside a Config.Builder.noBuildZones circle (2D), a spawn point closer than Config.Builder.minSpawnFromStart
      to the location's start (3D, as the server checks), a start closer than Config.Builder.minLocationGap to
      another location's start (2D), closer than payload.minGap to another point of the same key, too far away,
      or every `max` point already placed. Placed starts/areas and the start's keep-out circle are drawn as
      ox_lib sphere zones (lib.zones.sphere with debug) for visualisation; no-build zones as red cylinders.
      Stored heights: peds at standing height (ground + 1.0 m, what GetEntityCoords of a standing ped reads),
      vehicles at their root height above the ground (GetModelDimensions), markers on the surface aimed at,
      starts and areas on the ground. Vectors are rounded to 2 decimals (the server stores them so).
    * route recording (overlay 'recording'). Drive the route as the driver of any vehicle. Every
      Config.Builder.route.snapEvery m the position is snapped to the nearest road node
      (GetClosestVehicleNodeWithHeading, any dry path). A sample further than maxOffRoad from that node is
      rejected with the "Off road" warning, unless the vehicle is on a road surface (IsPointOnRoad) and the node
      is within 4 × maxOffRoad (long straight roads have sparse nodes). Waypoints: one at every turn (heading
      change over turnAngle against the heading leaving the previous waypoint), at least every maxGap m of road
      (the sample before the gap is kept), consecutive duplicates removed (samples closer than 1 m). E adds a
      stop point (escort only: payload.stops; at most Config.Blocks.escort.stops[2], wait = stopWait[3] s,
      interior waypoints only), Backspace undoes the last undoMetres, P pauses and resumes, X finishes. After an
      undo, a resume (in a vehicle or on foot) away from the end, or getting back into a driver seat away from
      it, sampling waits until the driver is back within snapEvery of the end of the recording (a marker shows
      it). The result has the waypoints, stops, loop flag, the length (sum of the waypoint distances, as the
      server measures it), the rejected samples (count and at most 50 positions) and `unreachable` (waypoint
      indexes with no road path to the next one, CalculateTravelDistanceBetweenPoints; each segment is checked
      while it is driven, where the game has its path nodes loaded, the last one after X).
    * test drive (overlay 'testdrive'). When the player is more than 200 m from the route start a GPS waypoint
      leads there first. A LOCAL vehicle (the block's vehicle) with a local driver drives the route waypoint by
      waypoint with TaskVehicleDriveToCoordLongrange at the block's speed and a lane-following driving style
      (drivingStyle below). A waypoint not reached within Config.Builder.route.testDriveTimeout s is marked for
      re-recording (`failed`) and the drive goes on to the next one; escort stop points are waited out; a stuck
      vehicle is re-tasked; X stops the drive. Vehicle, driver and blip are deleted at the end.
    * the async start / result protocol: each tool is started by a client action that answers at once
      ({ started = true }); the tablet closes and the tool runs; its BuilderClientResult (plus `seq`) is kept until
      the NUI reads it (builderResult), pushed to the NUI (topic 'builder', event 'clientResult') and the tablet
      reopens on the UI the tool was started from (payload.ui, default 'supervisor').
    * refusals (docs/CRIMSON_ARENA.md rules 8 and 13): every tool refuses with err.in_arena while the local player
      carries Crimson-Arena's crimsonArena value, and a running tool stops (no reopen) when such a value arrives;
      also err.builder_busy (a tool runs), err.builder_dead, err.builder_on_run (the player is on a mission run;
      a running tool stops, no reopen, when the player is put on one) and err.builder_disabled. The builder never moves the player: no SetEntityCoords on the player's ped or
      vehicle anywhere; builderWaypoint only sets a GPS waypoint. The routing-bucket half of CP.Alerts.inArena is
      server-side only (no client native); see the notes.
    * cleanup: ghosts, test-drive vehicle and driver, blips, zones, the GPS waypoint it set and the overlay are
      removed when a tool ends for any reason, on character unload and on resource stop.

  Public API (client)
    CP.Builder.active() -> 'placement'|'recording'|'testdrive'|nil
    CP.Builder.cancel(reason) -> boolean                 stops the running tool; its result has cancelled = true
    Pure helpers (also used by tests/builder_client_spec.lua):
    CP.Builder.newRecorder(opts) -> recorder             opts = { turnAngle = 30, maxGap = 150, dupDist = 1 }
        recorder:add(p) -> boolean       a snapped sample; false for a duplicate
        recorder:undo(metres) -> metres  removes the last metres of samples (keeps the first)
        recorder:addStop(wait, max) -> ok, reasonKey      a stop point at the current end
        recorder:endPoint() -> p|nil · recorder:count() -> samples · recorder:length() -> metres
        recorder:waypoints() -> { p, ... } (with the current end) · recorder:finish() -> points, stops, dropped
    CP.Builder.checkSpot(spot, ctx) -> ok, reasonKey|nil, vars|nil
        spot = { hit, x, y, z, groundZ, normalZ, water, blocked = true|false|nil (not probed yet), distance,
                 stored = { x, y, z } (the point as stored; the zone and distance checks use it, as the server) }
        ctx  = { kind, points, multiple, max, zones, spawn, start, minFromStart, otherStarts, minLocationGap,
                 minGap, maxDistance }
    CP.Builder.parsePlace(payload) / CP.Builder.parseRecord(payload) / CP.Builder.parseTestDrive(payload)
        -> opts|nil, errKey                             validated, normalised client-action payloads
    CP.Builder.drivingStyle(name) -> flags               careful|cautious 786603, normal 786475, fast 786492,
                                                         reckless 786492 (the lane-keeping variant: a test drive
                                                         always keeps to its lanes)
    CP.Builder.thin(points, max) -> points               evenly thinned copy keeping the first and last point
    CP.Builder.routeLength(points) -> metres
    CP.Builder.headingOf(a, b) -> degrees                GTA heading (0 = north, counter-clockwise)

  Client actions (CP.Tablet.registerClientAction; NUI 'client' endpoint)
    builderPlace     { missionId, location, key, kind = 'ped'|'vehicle'|'marker'|'area'|'start', model?, heading,
                       multiple, min?, max?, radius?, radiusMin?, radiusMax?, points, start, spawn, otherStarts,
                       minGap?, label?, ui? }        aliases from the task text: count -> max, existing -> points
    builderRecord    { missionId, location, key, stops, loop, label?, ui? }   alias: block = 'escort' -> stops
    builderTestDrive { missionId, location, key, route = { points, stops? }, vehicle, speed (km/h), style, label?, ui? }
    builderResult    {} -> the pending result or nil (and clears it)
    builderCancel    {} -> { cancelled = boolean }
    builderWaypoint  { coords } -> { ok = true }   (GPS waypoint; refuses in the arena)
    Immediate replies of the three tools: { started = true } or err.invalid_payload, err.in_arena,
    err.builder_busy, err.builder_dead, err.builder_on_run, err.builder_disabled, err.builder_bad_vehicle.
  Events handled: crimson-police:client:builder { event = 'lockBroken'|'reloaded'|'deleted', id } (stops a tool of
    that mission; 'deleted' also drops its pending result), the local player's crimsonArena state bag, character
    unload (CP.Qbx.onUnload), onResourceStop.
  NUI: CP.Tablet.overlay({ kind = 'placement'|'recording'|'testdrive', ... }) / overlay(nil),
       CP.Tablet.push('builder', { event = 'clientResult', id = missionId, result }).
  Text: builder.place.*, builder.rec.*, builder.drive.*, builder.tool_failed, err.builder_* (locales/parts/builder_client.json).
```

## Crimson-Police/modules/builder/server.lua

```text

 modules/builder/server.lua · CP.Builder (server): the Mission Builder's drafts, edit locks, versions,
  guardrails, test runs of drafts, publishing (Lua export), archive/restore, rollback and the loading and
  reloading of custom mission files. The full protocol (definition shape, payloads, results, client
  placement/recording results) is docs/notes/builder_protocol.md; TS shapes web/src/types/builder_server.ts.

  Owns
    * cp_custom_missions rows: drafts (draft_definition, builder units), published copies
      (published_definition + the reserved _file key), versions, edit locks, draft_tested, edited_in_code
    * missions/custom/<id>.lua (written with SaveResourceFile in exactly the shape of the spec's custom
      example), <id>.v<version>.lua.bak backups, <id>.draft.lua.bak conflict copies and
      missions/custom/archived/<id>.lua
    * the builder guardrails (SPEC "Guardrails" + "Route recording"; block validate() per block)

  Public API (server)
    CP.Builder.loadPublished() -> { def, ... }          (hook: CP.Missions.loadAll) published custom missions
                                                          with loader fields; runs the file sync first
    CP.Builder.onReload() -> summary                    (hook: CP.Missions.reload) hand edits of published files
        summary = { checked, unchanged, edited = { { id, version } }, rejected = { { id, error } },
                    conflicts = { id }, rewritten = { id } }
    CP.Builder.onDraftTested(missionId, version, tierName, passed, src, defHash) -> boolean   (hook: CP.Testing)
    Pure helpers (also used by the tests):
    CP.Builder.sanitize(input, id) -> def|nil, errKey, info    a stored-safe builder definition
    CP.Builder.validate(def, opts) -> errors, info             guardrails; opts = { publish = bool, raw = input }
                                                               info = { armed, requiredTier }
    CP.Builder.toFileUnits(def) -> table / CP.Builder.fromFileUnits(fileDef) -> def   unit conversion
    CP.Builder.toRuntime(fileDef) -> def                       vector tables -> vec3/vec4
    CP.Builder.exportLua(def, meta) -> text                    meta = { version, publisher, at, edited }
    CP.Builder.parse(luaSource, chunkName) -> def|nil, err     CP.Missions.parse, or the same sandbox
    CP.Builder.slug(label) -> string
  Net (docs/notes/builder_protocol.md §3/§4)
    callbacks  builder:list · builder:get { id } · builder:config
    actions    server:builder:create { type, label? } · duplicate { id } · lock { id } · unlock { id } ·
               save { id, definition } · autosave { id, definition } · validate { id, definition? } ·
               test { id, tier?, location?, useStartRoute? } · publish { id } · archive { id } ·
               restore { id } · rollback { id } · breakLock { id } · discardDraft { id }
    events     crimson-police:client:builder { event, id } to an editor who lost the lock or the draft;
               NUI push topic 'builder' { event, id, by } to everyone who opened the builder recently

  Permissions (CP.Permissions.can; admins always): builderEdit (own), builderEditAny (someone else's),
  builderPublish, builderArchive (archive + restore), builderRollback, breakEditLock.
  Every save, test, publish, archive, restore, rollback, lock break, discard and code edit is audited with
  CP.Admin.audit(..., 'builder', ...), which also posts to the builder webhook.
```

## Crimson-Police/modules/calls/server.lua

```text

modules/calls/server.lua · CP.Calls (server): Hard rule 15, real calls first
(docs/ARCHITECTURE.md §5.13, SPEC "Real calls end missions; NPC calls never do", INTEGRATIONS sc-dispatch
and sc-npcpolice).

Owns: the responding map (who is responding to which real call), the free abandon on a real call, the
60-second dodge rule and the "On a call" answer the Mission Board and accept checks use. Everything comes
through CP.Dispatch listeners (onResponding / onCallCleared / onDispatchRestart); this file never talks to
sc-dispatch itself and never creates, clears or blocks a dispatch call.

Public API
  CP.Calls.isOnCall(src) -> boolean
      A live real-call responding entry: updated less than Config.Calls.respondingExpiry s ago and still
      active in mdt_dispatch (entries are re-checked with CP.Dispatch.lookupActiveCall at most every 10 s
      and dropped when inactive: sc-dispatch's 5-minute auto-clear fires no event). May yield (database).

Classification of a ToggleResponding (src, callId, isResponding), in this order:
  1. The id is normalised with CP.Dispatch.normalizeCallId. An id starting with Config.Calls.npcCallPrefix
     (plain find at position 1, never a pattern) is an SC-NPCPolice call: nothing happens at all (no run
     end, no entry, no free abandon, no dodge rule).
  2. Marking: only a hit from CP.Dispatch.lookupActiveCall counts (an unknown, inactive or faked id does
     nothing); the canonical id it returns is checked against the NPC prefix again.
  3. If the sender is on a run, an id that is one of Config.Calls.ownRunCallPrefixes followed by the server
     id of ANY participant of that same run (partners who already left included) and '_' (plain find at
     position 1) is a call about their own run and does not count for them.
  4. Otherwise it is a real call: responding[src][id] = { since, lastUpdate }. An active participant is
     removed with CP.Runs.removeParticipant(run, src, 'real_call') (the rest of the unit carries on; no
     penalty, no cooldown), gets the toast calls.run_ended, and the free abandon is remembered
     { runId, citizenid, at } and written to the audit log (category 'flags', action 'free_abandon').
  Un-marking: the entry goes; within Config.Calls.dodgeWindow s of that free abandon, an un-mark of the
  same call (or of an id the sender never marked, so a different id form cannot slip through) turns it into
  a normal abandon: CP.Runs.reclassify(citizenid, runId, 'real_call_cancelled') (audited, toast
  calls.reclassified). Listeners run in their own threads and the mark yields twice (the mdt_dispatch
  lookup, then the row write in removeParticipant): an un-mark that arrives during either wait is kept and
  applied once the free abandon is written, so a quick on/off toggle cannot keep it free.
callClearedByOfficer removes that call for everyone; playerDropped removes the player's entries; an
sc-dispatch restart wipes every entry (sc-dispatch deactivates every call when it starts or stops).
```

## Crimson-Police/modules/cash/server.lua

```text

modules/cash/server.lua · CP.Cash (server): the cash formula and every payment Crimson-Police makes.

Owns
  * cash per participant = round(B x M_tier x M_mod) (SPEC "Cash payouts"): B = run.cashBase, locked at
    accept by CP.Payouts.baseFor; M_tier = the run's points and cash tier (Config.Scaling cash); M_mod =
    Config.Events.modifierCash when the run rolled a modifier. Only Completed results pay; a participant
    who failed the presence share (runs with 2+ participants) gets $0.
  * the claim-then-pay flow of one cp_mission_runs row (cash_status none/held/pending -> paying -> paid |
    capped | unfunded; offline -> pending), the daily cap per reset-day (Config.Cash.dailyCap), the society
    source (Config.Cash.source = 'society': the department's Renewed-Banking account through CP.Banking),
    the Qbox deposit (CP.Qbx.addMoney, Config.Cash.account), the Renewed-Banking history entries with the
    transaction id CP-<run_uuid>-<citizenid>, pending payments on login, releases after an approval,
    forfeits of voided runs and the forfeiture job (every 10 min).
  A row is only ever paid when it is completed, not flagged and not voided, and the claim
  UPDATE ... SET cash_status = 'paying' WHERE ... IN ('none','held','pending') changed it: paid, capped,
  unfunded and forfeited are final. A row left in 'paying' (crash, or a failed deposit after a society
  withdrawal that could not be refunded) is never retried automatically: see stuckPayments().

Public API (docs/ARCHITECTURE.md §5.20)
  CP.Cash.compute(run, p) -> amount, breakdown       breakdown = RunResult.cash { B, mTier, mMod, amount, status }
      status: 'held' for a completed, flagged, non-test row, else 'none'. Reads p.result (set by the engine).
  CP.Cash.pay(rowId) -> status|nil                   'paid'|'capped'|'unfunded'|'pending'|'paying'|nil (nothing done)
  CP.Cash.payPending(src) -> n                       pays the player's pending rows, and completed mission rows left
                                                     'none' with cash (never claimed); run 5 s after login and once
                                                     for every online player 15 s after the resource starts
  CP.Cash.release(rowId) -> status|nil               after an approved flag (flagged already 0): pay now or pending
  CP.Cash.forfeit(rowId) -> boolean                  a voided row's held/pending cash -> forfeited
  CP.Cash.range(missionType, members) -> min, max    board card range per officer: missionType is a type key or
      'weekly_boss'; members = officer tables or srcs (the unit). Covers every mission of the pool (admin
      payouts, stars) at the unit's tier; the top also covers a modifier (never for the boss).
  CP.Cash.stuckPayments() -> { StuckPayment... }     rows still 'paying' (not being paid right now)
      StuckPayment = { id, runUuid, citizenid, name, missionId, missionLabel, department, amount, createdAt, transId }
  CP.Cash.earnedThisWeek(citizenid) -> number        cash_paid of paid/capped rows since the week start
All functions except compute and range query the database: call them from a thread.
```

## Crimson-Police/modules/challenge/server.lua

```text

modules/challenge/server.lua · CP.Challenge (server): seasons, the department challenge, the weekly
bounty and the supervisor Department Report.

Owns
  * cp_seasons (start / end, the cached current season every run row is tagged with)
  * cp_dept_bounties: one row per (season_id, week) with week = 1, 2 ... counted in weekly resets since
    the season started (week 1 runs from the season start to the first weekly reset). The objective is
    picked with CP.U.rng(CP.U.hash('<seasonId>:<week>')) from Config.Challenge.bounties, so a restart
    picks the same one; an admin may override the current week's objective while it is open.
    winner: NULL = week still open, '' = closed without a winner, else the winning department key.
    week = 0 (objective 'season_champion') stores the season's champion department at season end.
  * the season end: champion by Config.Challenge.scoring and the tie-break, "Season X Champions" banner
    data, trophy badges season_<id>_champion (champion members with minRunsActive completed runs),
    season_<id>_top10 badges (top 10 of the season board), the board webhook with the results
  * callbacks getChallenge, getDeptContributors, admin:getSeasons, sup:getDeptReport,
    sup:getOfficerActivity and the actions server:admin:startSeason, server:admin:endSeason,
    server:admin:overrideBounty

Challenge rules (SPEC "Department challenge")
  Season rows = cp_mission_runs with season_id = the season, voided = 0 AND flagged = 0, grouped by the
  row's department (the department at the end of the run, so transfers keep old points; joint runs
  count for each participant's own department). Active officer = minRunsActive completed runs
  (manual_award / goal rows never count as runs) in that department this season.
  Weekly bounty bonus = floor(bountyBonus x the winning department's season points that week), added
  to that department's points pool once its week is closed:
    average: (points of active officers + bonuses) / active officers
    total:   all points + bonuses
    top10:   the 10 best officers' points + bonuses
  Ranking and tie-break: score, then completed runs, then unit runs (2+ participants).
  Bounty winner: highest count per active officer (season-to-date active officers) for the objective
  (most_tactical: completed Tactical runs, most_cross: completed runs with 2+ departments, most_unit:
  completed runs with 2+ participants, most_completed: completed runs), tie-break completed runs then
  unit runs that week; no winner when every count is 0 or the tie cannot be broken. Weeks close at the
  weekly reset, as a catch-up after start (a server that was down across the reset) and at season end.
  A department added to Config.Departments mid-season simply starts at 0.

Public API (docs/ARCHITECTURE.md §5.23)
  CP.Challenge.currentSeason(reload?) -> { id, name, startsAt, endsAt|nil, active = true } | nil   (cached)
  CP.Challenge.latestSeason() -> the active season, else the last ended one (the Season board)
  CP.Challenge.seasonById(id) -> season | nil
  CP.Challenge.startSeason(src, name) -> ok, seasonView | errKey   (ends the running season first)
  CP.Challenge.endSeason(src, reason?) -> ok, { season, standings, champion, top10 } | errKey
  CP.Challenge.standings(seasonId?) -> { seasonId, mode, departments = { { key, label, short, colour,
      score, activeOfficers, officers, points, completed, unitRuns, bonus, rank } } }
  CP.Challenge.bounty(weekKey?) -> { seasonId, week, id, label, winner|nil, closed, startsAt, endsAt,
      overridden } | nil        (weekKey = 'YYYY-MM-DD' of a week start; default the current week)
  CP.Challenge.overrideBounty(src, objective) -> ok, bountyView | errKey
  CP.Challenge.championBanner(dept?) -> { season, department (label), departmentKey, short } | nil
      the last ended season's champion; nil when dept is given and is not the champion
  CP.Challenge.invalidate()  (hook, called by CP.Leaderboard.invalidate) drops the challenge caches
  callback getChallenge -> ChallengeView (§9.4) plus { enabled, mode, minRunsActive, myDepartment,
      season.week, season.startsAt, departments[i].rank/points/bonus, bounty.leaderKey/week/endsIn/
      overridden/rates = { { key, short, colour, count, activeOfficers, rate } }, topContributors[i].citizenid }
  callback getDeptContributors({ department }) -> { department = { key, label, short, colour }, season,
      minRunsActive, contributors = { { rank, citizenid, name, callsign, points, runs, active } } }
  callback admin:getSeasons ('seasons') -> { current, latest, standings, bounty, bountyHistory = { {
      seasonId, seasonName, week, objective, label, winner, winnerShort, bonus, closed, current,
      startsAt, endsAt, startDate, endDate } }, seasons = { { id, name, startsAt, endsAt, active, champion, championShort } },
      bounties = { { id, label } }, enabled, weeklyBounty, mode, seasonWeeks, minRunsActive }
  action server:admin:startSeason { name }    ('seasons', audited 'season_start')
  action server:admin:endSeason               ('seasons', audited 'season_end')
  action server:admin:overrideBounty { objective }   ('bountyOverride', audited 'bounty_override')
  callback sup:getDeptReport({ department? })  (supervisors and admins: CP.Permissions 'viewMissionList';
      department only for admins) -> { department, season, standing, standings, bounty, week = { key,
      startsAt }, officers = { { citizenid, name, callsign, rank, runs, completed, failed, abandoned,
      flagged, points, cash, lastRunAt, lastRunTs } } }
  callback sup:getOfficerActivity({ citizenid, department? }) -> { officer = { citizenid, name, callsign,
      rank, departmentShort }, week, runs = { { id, missionLabel, missionType, state, endReason, points,
      cash, cashStatus, flagged, flagReason, voided, participants, departments, tier, durationS,
      createdAt, createdTs } } }   only officers of the supervisor's department (err.other_department)
Test hooks: CP.Challenge._boot(), _weekIndex(season, ts), _weekWindow(season, n), _pickBounty(seasonId, week),
  _closeDueWeeks(season, nowTs, includeCurrent), _collect(seasonId, fresh), _standingsFrom(data)
```

## Crimson-Police/modules/disputes/server.lua

```text

 modules/disputes/server.lua · CP.Disputes (server): officers' disputes about their flagged, voided or
  failed runs (cp_disputes) and how supervisors and admins answer them.

  Owns
    * filing: an officer may dispute one of their OWN rows that is flagged, voided or failed, within
      Config.Disputes.windowHours of the run (read at call time). One dispute per row, ever: an open one
      blocks a second (err.dispute_open) and a decided one is final (err.dispute_final). Manual awards and
      goal rows cannot be disputed. goes_to = 'supervisor' for flagged or voided rows (the department's
      supervisors), 'admin' for failed rows. The insert is atomic (INSERT ... SELECT ... WHERE NOT EXISTS).
      Filing toasts the online staff who can answer it (tellStaff, never participants of the run): admins
      for 'admin' disputes or while Config.Permissions.supervisor.handleDisputes is off, else the on-duty
      supervisors of the run's departments, or the admins when none of them may answer it (every online
      supervisor of those departments took part in the run, or none is online).
    * answering (decision final, reason required, never by a participant of that run):
        approve  flagged row -> CP.Admin.approveFlagged (flag cleared, held cash released, XP)
                 voided row  -> voided = 0 (and flagged = 0), CP.Scoring.onRowApproved (XP back),
                                CP.Cash.release when its cash is still held, CP.Leaderboard.invalidate
                 failed row  -> CP.Scoring.manualAward(src, citizenid, awardPoints, reason)
        reject   keeps the row as it is; a voided row whose cash is still held (or pending) is forfeited (CP.Cash.forfeit)
      "Took part" also covers a participant still on the live run (no row of theirs yet): refused and
      left out of their lists.
      The dispute is claimed first (UPDATE ... WHERE status = 'open'), so two reviewers can never both
      answer it; a failed manual award re-opens it. Every answer is audited (category flags) and posted
      to the flags webhook; filing posts to the flags webhook. The officer gets a toast when online.

  Public API (docs/ARCHITECTURE.md §5.24)
    CP.Disputes.eligible(row, citizenid, nowTs) -> ok, errKey|nil, kind    pure; kind 'voided'|'flagged'|'failed'
        row = { citizenid, mission_type, state, flagged, voided, created_ts }
    CP.Disputes.kindOf(row) -> 'voided'|'flagged'|'failed'|nil      CP.Disputes.goesTo(kind) -> 'supervisor'|'admin'
    CP.Disputes.forSupervisor(src) -> { DisputeView }   open supervisor disputes about runs involving their
        department (every department for an admin without a department), never runs they took part in
    CP.Disputes.forAdmin(excludeCitizenid?) -> { DisputeView }   every open dispute (both kinds)
    CP.Disputes.forOfficer(citizenid, goesTo?, viewerSrc?) -> { DisputeView }   that officer's disputes (any status)
    CP.Disputes.supervisorCanAnswer(runUuid) -> boolean   switch on and an online supervisor of the run's
        departments who did not take part (on or off duty); false = only an admin can answer it now
    CP.Disputes.handle(src, disputeId, decision, reason, awardPoints, opts) -> ok, data|errKey
        decision 'approve'|'reject'; awardPoints 1..10000 for an approved failed-run dispute;
        opts.adminOnly = true refuses non-admins (the admin endpoint)
    DisputeView = { id, rowId, runUuid, citizenid, name, callsign, department, departmentShort, missionId,
      missionLabel, missionType, missionTypeLabel, kind, state, endReason, tier, participants, points, cash,
      cashStatus, flagged, voided, flagReason, reason, goesTo, status, handledBy, createdAt, handledAt,
      runAt, canHandle }
  Net
    action   server:dispute               { rowId, reason }                 officer (CP.Access.getOfficer)
    action   server:sup:handleDispute     { disputeId, decision, reason }   handleDisputes (flagged/voided)
    action   server:admin:handleDispute   { disputeId, decision, reason, awardPoints }  admin (any kind)
    callback admin:getDisputes            -> { disputes = CP.Disputes.forAdmin(own citizenid) }
```

## Crimson-Police/modules/downed/client.lua

```text

modules/downed/client.lua · CP.Downed (client): the NPC pick-up of a downed participant and the EMS
request from their own client (docs/ARCHITECTURE.md §5.15, CRIMSON_ARENA rules 3 and 13).

Owns the handlers of client:pickup (runId, dropOff), client:pickupCancel (runId) and client:requestEMS
(runId) and sends the plain net event server:pickupDone (runId, ok).

Public API
  CP.Downed.busy() -> boolean      a pick-up is running on this client

client:pickup: screen fade-out, overlay { kind = 'fade', text = CP.L('downed.picked_up') } ("Picked up by
an NPC unit"), wait for the server's revive (ped not dead AND metadata isdead / inlaststand false; 20 s
timeout), detach from any entity or vehicle, SetEntityCoords to the drop-off, wait for collision, fade in,
clear the overlay, server:pickupDone (runId, true). The Crimson-Arena value (LocalPlayer.state.crimsonArena
with a source other than 'crimson-police') is re-checked before the fade, while waiting for the revive and
right before SetEntityCoords, and so is a server cancel (client:pickupCancel); every abort path fades back
in, clears the overlay and sends server:pickupDone (runId, false). Nothing here revives anyone: the server sends sc-ambulance's own
hospital:client:Revive (through CP.Ambulance).
client:requestEMS: CP.Ambulance.sendEMSRequest() (sc-ambulance's standard EMS request, sent only after
the server removed our flag) and a toast.
```

## Crimson-Police/modules/downed/server.lua

```text

modules/downed/server.lua · CP.Downed (server): Hard rule 18, downed participants
(docs/ARCHITECTURE.md §5.15, SPEC "Downed participants", CRIMSON_ARENA rules 1 and 3).

Owns: the downed poll, the Failed result for a participant who goes down (end_reason 'downed'), the free
NPC pick-up when no EMS is on duty, the EMS request when EMS is on duty, the server -> client events
client:pickup (runId, dropOff vector3), client:pickupCancel (runId) (a pick-up already sent was cancelled
on the server: in the arena, recovered, unload) and client:requestEMS (runId), and the plain net event
server:pickupDone (runId, ok) the client sends when the pick-up has finished (ok = false: it gave up).

Public API
  CP.Downed.isPending(src) -> boolean     a pick-up or EMS request for src is still to come (CP.Alerts keeps
                                          the flag of such a participant)
  CP.Downed.cancel(src, reason) -> boolean   stops a pending pick-up / EMS request and removes our flag
                                          (CP.Alerts.clear leaves a foreign value alone). The run result
                                          stays 'downed'. Used for in-arena, disconnect and unload.
  CP.Downed.handle(run, src) -> boolean   CP.Runs.endRun: src is down (the caller checked CP.Qbx.isDowned)
                                          and still active in a run that is ending. Holds the flag and
                                          calls CP.Runs.removeParticipant(run, src, 'downed',
                                          { keepFlag = true }) at once, before anything here yields (the
                                          engine gives only the others the run's end state), then starts
                                          the pick-up / EMS flow below in its own thread. A down the poll
                                          or the metadata listener already recorded for this run, whose
                                          thread has not run yet (CreateThread starts on the next tick),
                                          only leaves now; that thread then does the follow-up alone.
                                          false (nothing done): not an active participant, in the arena,
                                          the run ended, or that down's follow-up is already past the leave
                                          - the engine then removes them itself.

Flow (every Config.Downed.checkEvery s, active participants of every run that has not ended; in-arena
srcs are skipped; also at once when qbx_core sets metadata isdead / inlaststand to true, through
CP.Qbx.onMetaDataChange, and from CP.Downed.handle when a run ends):
  CP.Qbx.isDowned(src) (metadata isdead / inlaststand; sc-ambulance resurrects the ped, so ped death is not
  used) -> once per participant per run: CP.Alerts.hold(src) (the flag stays), CP.Runs.removeParticipant
  (run, src, 'downed', { keepFlag = true }), run.stats.downs + 1 (only when the engine did not already
  count it inside removeParticipant), then:
  * no EMS (CP.Ambulance.doctorCount() == 0): toast downed.pickup_soon; after Config.Downed.pickupDelay s
    re-check (still downed, not in the arena, still no EMS) -> client:pickup (runId, the nearest
    Config.Downed.dropOffs point to the server-side ped) -> ~1.5 s for the fade -> re-check -> CP.Ambulance
    .revive(src) -> server:pickupDone from the client (or 30 s) -> CP.Alerts.clear(src). No pick-up bill
    (hospital:client:Revive never bills). A revive CP.Ambulance refuses or cannot send (false: in the
    arena, disconnected, sc-ambulance stopped) cancels the pick-up at once (client:pickupCancel).
  * EMS on duty: CP.Alerts.clear(src) at once, then wait until 11 s after the last arena exit
    (CP.Alerts.foreignClearedAt[src]; sc-ambulance drops EMS requests for 10 s after one), re-check, then
    client:requestEMS (runId) exactly once. The only exception: our flag was off when they went down AND
    they were in last stand (CP.Qbx.getInfo(src).inLastStand) - sc-ambulance's client has then sent its
    own automatic EMSDownAlert on entering last stand, so no second request is sent. A participant who
    went straight to 'dead' unflagged gets our request (sc-ambulance sends no death alert).
  A failed re-check cancels the pick-up / request and clears our flag. Each downed participant has one
  entry per run, so nothing fires twice (also when the 2 s poll still sees metadata "down" right after the
  revive). A disconnect (playerDropped) or character unload (CP.Qbx.onPlayerUnload) cancels it.
Every participant downed: CP.Runs ends a run that has no active participant left; when a down removed the
last one and the run is still open 5 s later, this module ends it as failed (see docs/notes/safety.md).
```

## Crimson-Police/modules/draw/server.lua

```text

modules/draw/server.lua · CP.Draw: mission pools, the random draw, locations and the Mission Board.

Owns
  * the pool of a mission type for an officer or unit: published, enabled, of that type, open to
    every member's department, supporting the unit's size, off per-mission cooldown for every member
  * the random draw with the no-repeat rules (cp_mission_runs history: the last completed or
    abandoned missions of that type per citizenid, union over the unit; Config.Draw.avoidLast, and
    avoidLastLarge with largePool+ missions in the pool; a pool of one may repeat)
  * location picking (reserved spots skipped; spots with a non-participant player within
    Config.Draw.playerClearance skipped while another spot is free; server-side ped coords; players
    in Crimson-Arena are ignored, docs/CRIMSON_ARENA.md rule 7) and the
    location reservations (several holders per spot are allowed so a test run can still reserve)
  * the Mission Board data (BoardData, ARCHITECTURE §9.4) and the accept of a mission type

Public API (server)
  CP.Draw.pool(missionType, members) -> { def, ... }, reasonKey|nil, info   members = officers (§3.1) or srcs
      reasonKey: 'board.locked_empty' | 'board.locked_empty_solo' | 'board.locked_mission_cooldown'
      info = { cooldownUntil = ts|nil } (earliest per-mission cooldown end when that emptied the pool)
  CP.Draw.draw(missionType, members, opts) -> def, locationIndex | nil, errKey
      opts = { rng = CP.U.rng(...), participants = { src... } }; errKeys err.pool_empty,
      err.pool_cooldown, err.no_location
  CP.Draw.pickLocation(def, participantSrcs, rng, opts) -> index|nil     opts = { exclude = { [index] = true } }
  CP.Draw.reserve(runId, missionId, index) -> wasFree
  CP.Draw.release(runId) -> boolean
  CP.Draw.isReserved(missionId, index) -> boolean
  CP.Draw.recordLast(citizenid, missionType, missionId)   (CP.Runs: a completed or abandoned row was written)
  CP.Draw.boardCards(src) -> BoardData | nil, errKey
Net
  callback 'getMissionTypes' -> BoardData
  action 'server:acceptType' (payload = a Config.MissionTypes key, or 'weekly_boss') -> { runId }
      leader only; every member must be an officer (CP.Access.getOfficer), not be in Crimson-Arena
      (CP.Alerts.inArena: foreign crimsonArena flag or routing bucket <> 0, docs/CRIMSON_ARENA.md rule 5;
      err.in_arena), have no active run, not be on a real call, be under the hourly
      cap and off the type cooldown; server caps (CP.Runs.capsOk); refused while a Cross-Department
      Mission is active; the Weekly Boss also needs CP.Events.bossAvailable for every member.
      Then CP.Units.lock(unit), the draw, CP.Runs.create (the unit is unlocked again on failure).
Internal (same slice): CP.Draw._eligibility(def, officers, size?, now?) -> ok, why, untilTs, officer

Contract interpretations (details in docs/notes/engine_a.md)
  * history = distinct missions of the type with state completed/abandoned (failed rows and the Weekly
    Boss never count); a unit whose histories cover the whole pool relaxes to avoidLast, then to "not the
    unit's most recent mission", then the whole pool; no fallback to avoided missions for locations
  * board: points = best CP.Scoring.P in the pool, cash = CP.Cash.range(key, officers) (fallback from
    payouts x tier); locked priority member unavailable > type cooldown > hourly cap > empty pool
  * the Weekly Boss is not blocked by the Tactical type cooldown (it has no type), everything else applies
  * capsOk failures are reported as err.server_busy; CP.Access / CP.Runs.create error keys pass through
  * after CP.Units.lock the unit must still hold exactly the members that were checked (an invite accepted
    while the checks yielded): otherwise err.busy, unlocked, and the leader accepts again
  * BoardData extras: serverTime (os.time) and todMultiplier (Config.Events.todMultiplier)
```

## Crimson-Police/modules/events/server.lua

```text

modules/events/server.lua · CP.Events: Type of the Day, run modifiers and the Weekly Boss.

Owns
  * Type of the Day: one Config.MissionTypes key per reset-adjusted day, picked with a seed made
    from the day key (CP.U.hash), so a restart keeps the same type. Points only (CP.Scoring doubles).
  * Modifiers: the roll at accept (Config.Events.modifierChance, the run's seed): Armored Hostiles
    (Tactical only), Time Crunch, Radio Silence. Never for Cross-Department Missions, the Weekly Boss
    or test runs. The effects are applied by the engine (CP.Runs / CP.Scaling / blocks).
  * Weekly Boss availability: enabled, the reset-adjusted weekday is in Config.Events.weeklyBoss.days,
    hidden while a Cross-Department Mission is active, once per officer per week (any
    weekly_boss_kingpin row since the reset of the week's first boss day, except end_reason
    real_call / force_recall / cancelled), and the Weekly Boss card of the Mission Board
    (BoardCard & { available }; locked by the hourly cap too, which the boss counts toward).

Public API (server)
  CP.Events.typeOfTheDay(dayKey?) -> typeKey|nil
  CP.Events.rollModifier(run) -> 'armored_hostiles'|'time_crunch'|'radio_silence'|nil
  CP.Events.modifiers() -> { [key] = { label = 'modifier.<key>', tacticalOnly = bool } }
  CP.Events.bossAvailable(src, officer?) -> ok, reasonKey
      reasonKeys: err.boss_disabled, err.boss_unavailable, err.boss_not_today, err.operation_locked,
      err.boss_used, or CP.Access.getOfficer's key when officer is not given and src is no officer
  CP.Events.bossCard(src) -> card|nil   (nil while hidden: disabled, not a boss day, operation active,
      mission missing or disabled)
The boss is mission id 'weekly_boss_kingpin', accepted with the key 'weekly_boss' (runs store 'tactical').

Contract interpretations (details in docs/notes/engine_a.md)
  * voided boss rows still use the week's attempt; bossAvailable also refuses during an operation
  * the attempt window starts at the reset of the week's first boss day (Friday by default), not at
    the week start: rows are written when a run ends, so a boss run accepted on Sunday night that ends
    after Monday's reset belongs to last week and must not use up this week's attempt
  * bossCard.available = the unit may take this week's attempt (busy/onCall are separate flags);
    typeOfTheDay is true when the Type of the Day is tactical
  * rollModifier uses CP.U.rng(CP.U.hash(run.seed .. ':modifier'))
```

## Crimson-Police/modules/goals/server.lua

```text

modules/goals/server.lua · CP.Goals (server): personal daily and weekly goals.

Owns
  * picking each officer's goals: one of Config.Goals.daily per reset-adjusted day and one of
    Config.Goals.weekly per week (from the weekly reset on Config.Leaderboard.weekStartsOn), with a seed
    made from the date (or the week's start) and the citizenid, so a restart keeps the same goals and
    nothing is stored
  * progress: the officer's counted runs since the period started (completed, not flagged, not voided,
    never manual_award or goal rows) that match the goal (type = a mission type key, unit = 2+
    participants, crossDepartment = 2+ departments, mission = one mission id; count = how many)
  * the reward: once per period a 'goal' row (mission_type 'goal', mission_id = the goal id, state and
    end_reason 'completed', final_points = Config.Goals.dailyPoints / weeklyPoints) counted through
    CP.Scoring (XP; Overall and Department boards only)

Public API (docs/ARCHITECTURE.md §5.19)
  CP.Goals.forOfficer(citizenid) -> { daily = Goal|nil, weekly = Goal|nil }
      Goal = { id, label, count, progress, done, points }   (progress is capped at count)
  CP.Goals.onRunCompleted(citizenid)   (hook: a completed row was counted) -> inserts the goal rows earned
Both query the database: call them from a thread.
```

## Crimson-Police/modules/integrations/qbx/client.lua

```text

modules/integrations/qbx/client.lua · CP.Qbx (client): the only client code that talks to qbx_core.

Owns exports.qbx_core:GetPlayerData() and the qbx_core client events the tablet reacts to. These
client events are for the UI only; every decision about runs, roles and access stays on the server.

Public API (docs/ARCHITECTURE.md §5.1)
  CP.Qbx.getPlayerData() -> PlayerData
      A fresh copy from qbx_core every call ({} before a character is loaded or after logout, so
      test 'pd.job', never just 'pd'). Display only: the server re-checks everything.
  CP.Qbx.onJobUpdate(fn(job))
      QBCore:Client:OnJobUpdate (job switch, grade change; PlayerData is already fresh), and
      qbx_core:client:onGroupUpdate (a job or gang was added or removed: removing the active job
      makes it 'unemployed' without an OnJobUpdate), which fires with the re-read PlayerData.job.
  CP.Qbx.onDutyChange(fn(onDuty))
      QBCore:Client:SetDuty. The boolean argument is passed on: PlayerData.job.onduty is still
      stale inside that event (qbx_core sends SetDuty before the PlayerData update).
  CP.Qbx.onUnload(fn())    QBCore:Client:OnPlayerUnload (character logout or switch; not on disconnect)
  CP.Qbx.onLoaded(fn())    QBCore:Client:OnPlayerLoaded
Listeners run in their own thread; errors are caught and logged.
```

## Crimson-Police/modules/integrations/qbx/server.lua

```text

modules/integrations/qbx/server.lua · CP.Qbx (server): the only server code that talks to qbx_core.

Owns every exports.qbx_core call on the server and the qbx_core server events Crimson-Police
listens to. Those events are fired by qbx_core with TriggerEvent (server-local), so they are
registered with AddEventHandler ONLY: a net handler would let any client spoof a duty or job
change (docs/INTEGRATIONS.md, qbx_core-usage). The Qbox player object is never cached: every
check calls GetPlayer again, because an export returns a snapshot.

Public API (docs/ARCHITECTURE.md §5.1)
  CP.Qbx.getPlayer(src) -> player|nil
      Raw Qbox player object (fields under player.PlayerData).
  CP.Qbx.getInfo(src) -> info|nil
      info = { src, citizenid, name, firstname, lastname,
               job = { name, label, type, onduty, gradeLevel, gradeName },
               callsign, metadata, isDead, inLastStand }
      name = charinfo first + last name; callsign = metadata.callsign trimmed, nil when empty or
      qbx_core's default 'NO CALLSIGN'; gradeName falls back to the job definition's grade name.
  CP.Qbx.getByCitizenId(citizenid) -> src|nil      online players only, exact (case-sensitive) match
  CP.Qbx.getOnlinePlayers() -> { src, ... }        loaded characters, ascending (cached for 1 s)
  CP.Qbx.getJobs() -> table                        qbx job definitions ({} when unavailable)
  CP.Qbx.addMoney(src, account, amount, reason) -> boolean, why|nil
      player.Functions.AddMoney(account, amount, reason); amount rounded half up (CP.U.round); 0 returns
      true without calling qbx_core (nothing to move); negative or invalid amounts return false.
      why = 'error' when AddMoney raised: the balance may already have changed, so the caller must not
      retry or refund (CP.Cash leaves the row 'paying'). A plain false (refused, offline) has no why.
  CP.Qbx.isDowned(src) -> boolean                  metadata.isdead == true or metadata.inlaststand == true
  Listeners (any number; each runs in its own thread, errors are caught and logged):
  CP.Qbx.onDutyChange(fn(src, onDuty))    QBCore:Server:SetDuty. false is passed on as is; a true is
                                          re-read from PlayerData (SetDuty can arrive stale or out of
                                          order when sc-police / sc-ambulance force a suspended officer
                                          off duty inside their own handler). Listeners must still
                                          re-read getInfo(src).job.onduty before acting on "on duty".
  CP.Qbx.onPlayerLoaded(fn(src))          QBCore:Server:PlayerLoaded (player object argument).
  CP.Qbx.onJobChange(fn(src, job))        QBCore:Server:OnJobUpdate; job has the getInfo job shape
                                          (read live: PlayerData is already updated when it fires).
  CP.Qbx.onPlayerUnload(fn(src))          QBCore:Server:OnPlayerUnload (character logout / switch).
  CP.Qbx.onGroupUpdate(fn(src))           qbx_core:server:onGroupUpdate (job or gang added/removed;
                                          removing the active job makes it 'unemployed' without an
                                          OnJobUpdate, so listeners re-read the job).
  CP.Qbx.onMetaDataChange(fn(src, key, old, new), keys?)
                                          qbx_core:server:onSetMetaData (key, oldValue, value, source),
                                          fired by qbx_core's SetMetaData after the value is set. keys
                                          (optional list of metadata keys) filters before any thread is
                                          started: metadata changes constantly (hunger, thirst, stress).

All functions may be called from any thread; none of them yields.
```

## Crimson-Police/modules/integrations/renewed_banking/server.lua

```text

modules/integrations/renewed_banking/server.lua · CP.Banking: the only code that talks to Renewed-Banking.

Owns exports['Renewed-Banking']:handleTransaction, removeAccountMoney, getAccountMoney and
addAccountMoney (verified signatures in docs/INTEGRATIONS.md; addAccountMoney is not in the spec's
Appendix, INTEGRATIONS.md "addAccountMoney" names it as the only refund path for a society withdrawal).
Personal money itself moves through Qbox (CP.Qbx.addMoney); Renewed-Banking only keeps the history, so
a payout needs both calls.

Public API (docs/ARCHITECTURE.md §5.1). Every function returns false/nil instead of raising when
Renewed-Banking is stopped or rejects the call. Amounts are rounded half up to whole dollars;
an amount of 0 is never sent (a $0 history entry) and returns true.
  CP.Banking.recordDeposit(citizenid, amount, message, issuer, receiver, transId) -> boolean
      handleTransaction(citizenid, Config.Tablet.title, amount, message, issuer, receiver, 'deposit', transId).
      true = Renewed-Banking accepted the arguments. It still drops the entry silently when the
      player's history is not loaded yet (right after QBCore:Server:PlayerLoaded), so pending payouts
      should wait a few seconds after the player loads.
  CP.Banking.withdrawSociety(account, amount) -> boolean
      removeAccountMoney(account, amount): false when the account is unknown or cannot cover it.
  CP.Banking.recordSocietyWithdraw(account, amount, message, issuer, receiver, transId) -> boolean
      handleTransaction(account, Config.Tablet.title, amount, message, issuer, receiver, 'withdraw', transId).
  CP.Banking.societyBalance(account) -> number|nil   getAccountMoney(account); nil for an unknown account.
  CP.Banking.depositSociety(account, amount) -> boolean
      addAccountMoney(account, amount): puts money back into a society account (CP.Cash's refund when a
      society-funded payout's AddMoney failed after withdrawSociety). Society/shared accounts only:
      Renewed-Banking returns false for a citizenid or an unknown account (and while its account cache
      loads after a restart). It records no history entry.
message: apostrophes and backslashes are removed (Renewed-Banking doubles them in the stored text).
issuer/receiver: never nil (nil becomes ''). transId: e.g. ('CP-%s-%s'):format(runUuid, citizenid).
```

## Crimson-Police/modules/integrations/sc_ambulance/client.lua

```text

modules/integrations/sc_ambulance/client.lua · CP.Ambulance (client): sc-ambulance's standard EMS
request for a downed participant.

Public API (docs/ARCHITECTURE.md §5.1)
  CP.Ambulance.sendEMSRequest() -> boolean
      TriggerServerEvent('hospital:server:EMSDownAlert', streetName) from the downed player's OWN
      client (sc-ambulance uses 'source' as the patient), with the street name computed exactly as
      sc-ambulance does. Send it only after the server has cleared the crimsonArena flag (modules/downed
      does that before client:requestEMS): sc-ambulance ignores flagged players and players who are
      not down. Guarded against duplicates (at most one request per 5 s); false when sc-ambulance is
      not started, the request was a duplicate, or the player carries Crimson-Arena's crimsonArena value
      (sc-ambulance drops the request then; Crimson-Arena handles its own players). This is the one
      dispatch call Crimson-Police may cause.
```

## Crimson-Police/modules/integrations/sc_ambulance/server.lua

```text

modules/integrations/sc_ambulance/server.lua · CP.Ambulance (server): the only server code that
talks to sc-ambulance.

Owns exports['sc-ambulance']:GetDoctorCount() and the revive event. The ONLY revive used is
TriggerClientEvent('hospital:client:Revive', src): it resurrects in place, never bills, never touches
the inventory. Crimson-Police never triggers sc-ambulance's player-revive server event, its
revive-player / help-person / target-revive client events (each makes the officer's client send the
server revive, which bans non-EMS senders), and none of its billing or respawn events.

Public API (docs/ARCHITECTURE.md §5.1)
  CP.Ambulance.doctorCount() -> integer
      On-duty EMS. exports['sc-ambulance']:GetDoctorCount() in pcall; 0 when sc-ambulance is not
      started (one error log until it starts again). The export is a counter clients update
      themselves (it can be inflated or stale), so it is cross-checked against a live count of
      on-duty 'ambulance' players from CP.Qbx.getOnlinePlayers(): the result is the lower of the
      two (0 means "no EMS", so a downed participant is picked up).
  CP.Ambulance.revive(src) -> boolean
      TriggerClientEvent('hospital:client:Revive', src) for one numeric, connected server id
      (never -1, never nil). false when refused or when sc-ambulance is not started (no handler).
      Refused and logged for an in-arena player (CP.Alerts.inArena: a foreign crimsonArena value or a
      routing bucket other than 0): Crimson-Arena revives and moves its own players
      (docs/CRIMSON_ARENA.md rule 3).
```

## Crimson-Police/modules/integrations/sc_dispatch/server.lua

```text

modules/integrations/sc_dispatch/server.lua · CP.Dispatch: the only code that talks to sc-dispatch.

Owns: the read-only listeners on sc-dispatch's events, the read-only mdt_dispatch lookup,
exports['sc-dispatch']:IsPlayerSuspended and exports['sc-dispatch']:ClearNotification.
Never uses sc-dispatch's call-creating export (missions never create dispatch calls) and never
triggers any sc-dispatch event. sc-dispatch's own handlers always run as well; nothing here blocks them.

Event registration (docs/INTEGRATIONS.md, sc-dispatch):
  RegisterNetEvent  sc-dispatch:server:ToggleResponding (callId, isResponding)   client-originated
  RegisterNetEvent  sc-dispatch:server:ShotsFired / PlayerDown / PlayerDead (data) client-originated
  AddEventHandler   sc-dispatch:server:callClearedByOfficer (callId)   server-local ONLY, so no client
                    can fire it to lift their own "On a call" block
  AddEventHandler   onResourceStart / onResourceStop of 'sc-dispatch' (a restart deactivates every call)
Every net handler captures 'source' on its first line (and os.time() right after, before anything can
yield) and validates the payload; per-player rate limits go through CP.Net.rateOk.

Public API (docs/ARCHITECTURE.md §5.1)
  CP.Dispatch.available() -> boolean                 sc-dispatch is started
  CP.Dispatch.isSuspended(citizenid, jobName) -> boolean
      exports['sc-dispatch']:IsPlayerSuspended(citizenid, jobName); false when sc-dispatch is not
      started or the export fails (sc-dispatch itself fails open). May yield (sc-dispatch awaits MySQL).
  CP.Dispatch.lookupActiveCall(callId) -> uniqueId|nil
      SELECT id, unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1 LIMIT 1
      with (the integer form or 0, the normalised string), in pcall. Returns the canonical call id:
      the row's unique_id, or its row id as a string when unique_id is empty. nil when the call is
      unknown or inactive, when sc-dispatch is not started, or on a query error (logged). The result
      can be an 'npccall-' id: the caller must still classify it. Yields (database).
  CP.Dispatch.clearNotification(uniqueId, jobs) -> boolean
      exports['sc-dispatch']:ClearNotification(uniqueId, jobs) in pcall. Only non-numeric string ids
      are accepted (a number, or a digit-only string, would also match unrelated ems/fire rows by row
      id). jobs defaults to { 'police' }. Call it from a handler or thread (sc-dispatch awaits MySQL).
  CP.Dispatch.normalizeCallId(id) -> string          123, '123', 123.0 -> '123'; other strings unchanged;
                                                     nil -> ''
  Listeners (any number; each runs in its own thread):
  CP.Dispatch.onResponding(fn(src, callId, isResponding))  callId as sent (number or string, validated),
                                                            isResponding a boolean
  CP.Dispatch.onCallCleared(fn(callId))                     number or string, as sc-dispatch sent it
  CP.Dispatch.onDispatchRestart(fn())                       sc-dispatch started or stopped
  CP.Dispatch.onShotsFired(fn(src, data, receivedAt))       data = { coords = vector3|nil, street, zone, sex }
  CP.Dispatch.onPlayerDown(fn(src, data, receivedAt))       (client-supplied: use server-side ped coords
  CP.Dispatch.onPlayerDead(fn(src, data, receivedAt))        for any distance check), receivedAt = os.time()
```

## Crimson-Police/modules/leaderboard/server.lua

```text

modules/leaderboard/server.lua · CP.Leaderboard (server): the four time-boxed boards, their cache,
the weekly/monthly recognition, public and own profiles, the hide-name privacy toggle and the admin
board view (cash paid per officer, payments stuck in paying).

Owns
  * callbacks getBoard, getProfile, admin:getBoards and the action server:setHideName
  * the in-memory board cache (Config.Leaderboard.cacheSeconds) per (period, filter, department, window)
  * the weekly reset job: top 3 of the week that just ended -> board webhook (cp_webhook_board) and the
    "Officer of the Week" badge officer_of_week_<weekKey> (idempotent; also run as a catch-up after start)
  * Home announcements: top 3 of the previous week and of the previous month

Board rules (SPEC "Leaderboards")
  points  = SUM(final_points) of counted rows (voided = 0 AND flagged = 0) in the window and filter
  runs    = completed runs (mission_type not 'manual_award'/'goal'), failed = failed runs (counted rows)
  windows = weekly: CP.Schedule.weekStart .. now; monthly: CP.Schedule.monthStart .. now;
            season: rows with season_id of the active season (or the last ended one until a new starts);
            alltime: cp_officers.xp (Overall filter only; runs/failed from cp_mission_runs + archive)
  filters = overall | <Config.MissionTypes key> | unit (participants >= 2) | cross (departments_n >= 2)
            | department (row department = args.department). manual_award and goal rows only count
            toward overall and department.
  ranking = points desc, fewer failed, then who reached the total first (latest counted row that
            changed the total, ascending), then citizenid. Minimum Config.Leaderboard.minRunsToRank
            completed runs in the board's own window and filter. Top Config.Leaderboard.topN rows.
  privacy = hide_name officers show their callsign (or leaderboard.hidden_name) instead of their name;
            cash is never on public boards.

Public API (docs/ARCHITECTURE.md §5.22)
  callback getBoard({ period, filter, department? }) -> Board (§9.4) plus
      { department?, minRuns, topN, ranked, window = { from, to|nil, fromDate, toDate|nil }, season = { id, name }|nil }
      fromDate/toDate = 'YYYY-MM-DD' in server time; the tablet shows these, never from/to in the player's time zone
      me = the viewer's row; rank 0 when they do not have minRuns completed runs yet (never nil for
      an officer). errKeys: the CP.Access.getOfficer keys, err.invalid_period, err.invalid_filter,
      err.unknown_department, err.invalid_payload
  callback getProfile(citizenid | { citizenid } | nil) -> Profile (§9.4) plus
      { departmentLabel, seasonPoints, disputeWindowHours, badges[i].kind }
      own = nil or the viewer's citizenid: cash, cash status and the breakdown's cash block are only in
      the own profile. runs = the last 20 rows (manual awards and goal rewards included, labelled).
      canDispute = CP.Disputes.eligible(row, viewer, now) (own row, flagged or voided or failed, not an award
      row, created within Config.Disputes.windowHours; the same rule server:dispute applies) and no cp_disputes
      row at all for it (one dispute per row, ever). errKeys: err.unknown_officer, err.invalid_payload
  action server:setHideName (boolean | { hideName = boolean }) -> { hideName }
  callback admin:getBoards({ period, filter, department?, citizenid? })   (CP.Permissions 'openAdmin')
      -> { period, filter, department?, rows = ranked rows + { cash, realName, hidden },
           unranked = the same for officers below minRuns, stuck = payments still in 'paying'
           (CP.Cash.stuckPayments(), normalised to { rowId, runUuid, citizenid, name, callsign,
           missionLabel, amount, createdAt, transId }), minRuns, updatedAt, window, season,
           runs = that officer's rows in the window/filter when citizenid is given }
  CP.Leaderboard.invalidate()                      (hook: void/approve/new rows) drops every cache
                                                   and calls CP.Challenge.invalidate()
  CP.Leaderboard.seasonPoints(citizenid) -> number counted points in the active season
  CP.Leaderboard.announcements() -> { { kind = 'weekly_top3'|'monthly_top3', text, entries }, ... }
  CP.Leaderboard.ranking(opts) -> ranked, byCitizen   (slice helper, used by CP.Challenge at season end)
      opts = { period = 'weekly'|'monthly'|'season'|'alltime'|'range', filter, department,
               from, to (range), seasonId (season), fresh }
  CP.Leaderboard.missionLabel(missionType, missionId, breakdown) -> text   (slice helper)
  CP.Leaderboard.publicName(entry) -> text        (slice helper: privacy-aware display name)
  CP.Leaderboard.badgeLabel(badgeId) -> label|nil, kind   label of this module's badge ids (officer_of_week_<week>,
      season_<id>_champion, season_<id>_top10); nil (kind 'achievement') for any other id
Test hooks: CP.Leaderboard._weeklyJob(prevStartTs, curStartTs), CP.Leaderboard._boot()
```

## Crimson-Police/modules/migrations/server.lua

```text

modules/migrations/server.lua · applies sql/migrations/NNN_*.sql in order on start.

Every other module calls CP.Migrations.ready() before its first query: it blocks the
calling thread until the database is at the latest version. If a migration fails the
resource prints the file and the error and stops itself, so it never runs on a
half-upgraded database.
```

## Crimson-Police/modules/missions/client.lua

```text

modules/missions/client.lua · CP.Missions (client): the mission definitions sent by the server.

Owns the client copy of every mission definition. The server sends the full list with
crimson-police:client:missions after each load, reload, publish or archive; a client that joins
later asks for it once with the getMissionDefs callback (retried while the server is still loading).
Vectors arrive as { x, y, z[, w] } tables and are turned back into vector3 / vector4 values here,
recursively, so block client halves can use them directly.

Public API (client)
  CP.Missions.get(id) -> def|nil
Events: crimson-police:client:missions (list)
```

## Crimson-Police/modules/missions/server.lua

```text

modules/missions/server.lua · CP.Missions: the mission registry (loader, normaliser, validator).

Owns
  * loading missions/builtin/index.lua (a Lua file that returns a list of ids) and every
    missions/builtin/<id>.lua with LoadResourceFile, each run in a sandbox whose only globals are
    RegisterMission, vec3, vec4, vector3, vector4, math, string, table (copies), pairs, ipairs,
    tonumber, tostring and type; exactly one RegisterMission({ ... }) call per file
  * custom missions from CP.Builder.loadPublished() (the builder owns their files and DB rows)
  * normalising every definition (defaults from the block's defaults(), minSeconds per block,
    presenceRange = Config.Blocks[block].presenceRange[3]) and validating it (generic checks + the
    block's validate(obj, mission, location) for every location); invalid missions are rejected
    with a console warning, the rest load. Payout fields in a file are ignored with a warning.
  * loader fields: source, version (custom), filePath, defHash (CP.U.hashHex of the file content),
    editedInCode, isBoss (weekly_boss_kingpin), status
  * sending the definitions to clients: crimson-police:client:missions (full list, vectors as
    { x, y, z[, w] }) after every load/change, and the getMissionDefs callback for joining players

Public API (server)
  CP.Missions.loadAll() -> summary          summary = { loaded, builtin, custom, failed = { { id, file, error } }, warnings }
  CP.Missions.reload() -> summary           CP.Builder.onReload() (hand edits) first, then loadAll(); summary.builder
  CP.Missions.get(id) -> def|nil
  CP.Missions.all() -> { [id] = def }       (a copy of the map; the defs are shared, do not mutate them)
  CP.Missions.list() -> { def, ... }        sorted by id
  CP.Missions.byType(missionType) -> list   sorted by id, never the Weekly Boss
  CP.Missions.isEnabled(id) -> boolean      loaded, status 'published', not in Config.DisabledMissions
  CP.Missions.normalize(def, meta) -> def|nil, err   pure; meta = { source, version, filePath, defHash, editedInCode, status }
  CP.Missions.parse(luaSource, chunkName) -> def|nil, err   one file's source in the loader sandbox (raw def)
  CP.Missions.serializeForClient(def) -> table
  CP.Missions.register(def) -> def|nil, err  publish/restore without a reload (loader fields read from def;
                                             always source = 'custom')
  CP.Missions.unregister(id) -> boolean      archive without a reload (custom missions only)
Net
  callback 'getMissionDefs' -> list of serialized definitions (err.not_ready before the first load)
  action 'server:admin:reloadMissions' (permission reloadMissions) -> summary
  event 'crimson-police:client:missions' (list) to every client after each load / register / unregister
      (sent with TriggerLatentClientEvent: the list is tens of kB)

Contract interpretations (details in docs/notes/engine_a.md)
  * CP.Builder.loadPublished() entries: a definition with loader fields, { def, meta }, or meta only
    ({ id, filePath, version }) whose file is read here; if the hook throws, loaded custom missions stay
  * reload(): CP.Builder.onReload() first, then loadAll()
  * design rules the builder enforces for custom missions (location count and gap, armed budget,
    maxBlocks) are warnings here; playability rules reject the mission
  * validation reasons are English developer-facing text (console, builder), not locale keys
  * the loader fields (source, isBoss, status, version, filePath) are set BEFORE the blocks' validate()
    runs, because the blocks exempt built-in missions (mission.source == 'builtin') from the builder's
    allowed model/weapon lists
  * docs/CRIMSON_ARENA.md: a mission is rejected when an item is named armour, bandage, ammo-* or
    weapon_* (rule 4), or when any point of a location lies inside a Config.Builder.noBuildZones zone
    (rule 7; 2D distance, as the blocks and the builder measure it)
```

## Crimson-Police/modules/npc/client.lua

```text

 modules/npc/client.lua · CP.Npc (client): host-side NPC AI helpers and "Cuff suspect".

  What this module owns (docs/ARCHITECTURE.md §5.11, §6.1, §6.2, §0.14)
    - The relationship groups CRIMSONPOLICE_HOSTILE and CRIMSONPOLICE_NEUTRAL, created once on every
      client. Only the relations FROM these two groups are set: HOSTILE hates PLAYER (5), is a companion
      of itself and neutral (3) to NEUTRAL and every other common group; NEUTRAL is neutral to all.
      The PLAYER group's own relations are never touched. Both groups are removed on resource stop.
    - apply / task / nearestParticipant for the block client halves (run host only: the caller has
      control of the ped, see CP.Runs.control).
    - A light host AI loop (500 ms, only while it manages a ped) that keeps combat on the nearest active
      participant (with no participant in reach a hostile stands still: it never guards, since a
      guarding ped attacks every player, bystanders included), walks flee routes point by point,
      drives recorded routes waypoint by waypoint, recovers stuck peds and re-plays the kneel /
      cuffed poses if something interrupted them.
    - Drop protection on EVERY client (participant or not) for every ped with a Crimson-Police cp bag:
      SetPedDropsWeaponsWhenDead false and SetPedMoney 0 once per entity handle, because the client
      that owns a ped when it dies creates the pickups and ownership moves to the nearest player.
    - The cp state bag change handler (AddStateBagChangeHandler('cp', nil, ...)): on the host of the
      local player's run it applies the bag cfg once control is gained and re-tasks the ped when its
      state changes: hostile -> combat, fleeing -> flee (bag.fleePoints / cfg.fleePoints route when
      present), surrendered -> hands up then kneel, cuffed -> cuffed pose + frozen, restrained -> kneel,
      and a server task = { action, args } for any state (run once per bag.taskSeq). When this client becomes the host
      (crimson-police:client:hostChanged) every known ped of the run is re-applied and re-tasked.
    - One global ox_target option set (exports.ox_target:addGlobalPed): 'crimson-police:cuff' with the
      default label (locale npc.cuff) and 'crimson-police:cuff:<n>' for other labels a block passed to
      enableCuff. canInteract only when the ped's cp.run is the local player's current run,
      cp.state == 'surrendered', cp.cuff is set and the player is within cp.cuff.maxDistance on foot,
      so non-participants never see it. onSelect runs lib.progressBar (cp.cuff.duration, mp_arresting
      anim; cancelled if the suspect stops being surrendered, moves out of reach or the local player is
      placed in Crimson-Arena) and then TriggerServerEvent('crimson-police:server:npcCuff', runId, netId).
      The options are removed on resource stop and re-added when ox_target restarts.

  Public API
    CP.Npc.apply(entity, cfg) -> boolean
        cfg (the bag's cfg): weapon, accuracy, armour, health, behaviour ('hold'|'balanced'|'push'),
        group ('hostile'|'neutral'); state and armed are read from the entity's cp bag.
        Weapon (GiveWeaponToPed when missing; unarmed peds have every weapon removed), no drops
        (SetPedDropsWeaponsWhenDead false, SetPedMoney 0), accuracy, max health (health only while the
        ped is untouched), armour (only while untouched), relationship group, combat
        attributes / ability / range / movement by behaviour, flee attributes, dies when injured (no
        writhing), no ragdoll from player impact, blocking of non-temporary events, keep task.
    CP.Npc.task(entity, action, args) -> boolean     (needs control; repeated identical tasks are ignored
                                                     unless args.force)
        'combat'       { target = ped?, behaviour? }        TaskCombatPed on the nearest active participant
                                                            (none: TaskStandStill until one is back)
        'flee'         { points = { vec3 }?, startIndex?, from = ped?, vehicle?, speed?, drivingStyle?, style?, stopRange? }
                       on foot: TaskFollowNavMeshToCoord along points, then TaskSmartFleePed from the
                       nearest participant; as a driver: the points as a road route, else
                       TaskVehicleMissionPedTarget flee
        'handsUp'      { duration? }                         TaskHandsUp facing the nearest participant
        'kneel'        { instant? }                          hands up, then kneel (random@arrests,
                                                            random@arrests@busted idle loop)
        'cuffed'       { instant? }                          (kneeling get-up), mp_arresting idle loop, frozen
        'follow'       { coords, speed = 1.0, radius = 1.5, anyMeans? }
                       TaskFollowNavMeshToCoord (TaskGoToCoordAnyMeans with anyMeans)
        'cower'        {}                                    TaskCower
        'wander'       {}                                    TaskWanderStandard
        'enterVehicle' { vehicle = netId|entity, seat = -1, speed = 2.0, timeout = 20000 }
        'driveTo'      { coords, vehicle?, speed = 16.7 m/s, drivingStyle?, style = 'normal', stopRange = 8.0 }
        'driveRoute'   { points = { vec3 }, loop?, startIndex?, vehicle?, speed = 16.7 m/s, drivingStyle?,
                         style = 'normal', stopRange?, arrive? }
                       TaskVehicleDriveToCoordLongrange waypoint by waypoint, lane-following style; the
                       route starts at the nearest point ahead (first local minimum of the distance)
        speed is m/s (kmh = km/h is accepted instead); a numeric drivingStyle wins over the style name.
        A managed task (combat retargeting, route stepping, stuck recovery, pose upkeep) ends when the
        ped's cp state changes or it leaves the vehicle it was driving: the new state's owner re-tasks.
        styles: 'careful'|'cautious' 786603, 'normal' 786475, 'fast' 786492 (all keep to their lanes),
                'reckless' 787004 (may use oncoming lanes to overtake)
    CP.Npc.nearestParticipant(coords) -> ped|nil, dist   active participants of the local player's run

  Events listened to (sent by modules/runs): crimson-police:client:start, client:participants,
  client:hostChanged, client:runEnded (participant list and host changes only).
  Event sent: crimson-police:server:npcCuff (runId, netId).
  Player-facing text: npc.cuff (npc.json).
```

## Crimson-Police/modules/npc/server.lua

```text

 modules/npc/server.lua · CP.Npc (server): the authoritative state machine of mission NPCs.

  What this module owns (docs/ARCHITECTURE.md §5.11, §6.1, §6.2)
    - The state, cuff, task and seq fields of every mission ped's replicated cp entity state
      bag (Entity(e).state.cp = { run, obj, role, state, armed, cfg, tag, ... }). The engine
      (CP.Runs.spawnPed) writes the bag first and keeps a server copy in run.entities[netId].bag;
      afterwards only this module changes state.
    - Bag trust: a client can write the state bag of an entity it owns, so the server NEVER reads the
      bag back. The server record per net id (rec.bag, seeded from the engine's run.entities[netId].bag,
      mirrored back into it after every write) is the only source of truth for state, cuff, obj, role
      and seq; the replicated bag is written from it and only read by clients. A client that rewrites
      the bag (state 'cuffed', a cuff table, another run) changes nothing on the server.
    - "Cuff suspect": blocks call enableCuff; participants' clients (modules/npc/client.lua) show one
      global ox_target option and report the finished progress bar with the plain net event
      crimson-police:server:npcCuff (runId, netId). The server validates it (active, arrived
      participant of that run, on duty, not in the arena, the ped belongs to the run and is
      surrendered and cuffable, server-side distance <= maxDistance + 0.5 m, and the officer has been
      within reach for most of the cuff duration), sets cuffed and delivers
      { type = 'cuffed', netId } to the owning objective (CP.Runs.dispatch with cp.obj).
    - The death watcher: every 1 s over every live mission ped of every run. Health <= 0 (once a positive
      health was seen, or while the server has health data for the ped: GetEntityMaxHealth > 0 or a cause
      of death; a server-made ped reads 0 before any client synced it), or an entity that no longer exists
      (a ped the engine deleted on purpose is no longer in run.entities), is a death. (The engine leaves ped health deaths to this module because CP.Npc.onDeath exists.) The killer is GetPedSourceOfDeath resolved to a
      player (the player's own ped, or the driver of the killing vehicle); when the engine names nobody,
      the last weapon hit by a player in the last 5 s. Then, exactly once per ped:
      CP.AntiCheat.onNpcKilled(run, killerSrc) for a killer who is not an active participant (first:
      the death can end the run inside entityDied, and an ended run takes no flag),
      CP.Runs.entityDied(run, netId, killerSrc), the bag state 'dead', and the onDeath listeners.
      Whether a death fails the mission (a surrendered, cuffed, restrained or unarmed ped killed by a
      participant, run.fail_killed_unarmed) is decided by the owning block's onEntityDead, which keeps
      its own "shot already in flight" grace.
    - The weaponDamageEvent listener (returns at once when WasEventCanceled(); never cancels):
      a gun hit (not melee, not a vehicle) by an active participant on a mission ped ->
      CP.Runs.noteWeaponFired(run, src) (server-side proof for no_weapons_fired; so is a weapon kill:
      GetPedCauseOfDeath is a gun, before entityDied);
      a participant shooting a surrendered (after SURRENDER_GRACE_MS), cuffed or restrained ped ->
      CP.Runs.penalize(run, 'shot_surrendered', { src }) and { type = 'shot', netId, src } to the owning
      block; any damage to a ped whose role is 'hostage' -> the onDamaged listeners, plus
      { type = 'damaged', netId, attacker } to the owning block when the attacker is a participant.
      The attacker is the sender, except that a parentGlobalId naming an NPC the sender owns (a
      hostile on the host shooting a hostage) is nobody. A parent naming another player (a forged
      packet) is still the sender: nobody can be blamed for someone else's packet.
    - A 1 s health poll for the case weaponDamageEvent never covers: a client damaging a ped it owns
      itself (the run host usually owns every mission ped). A health+armour drop with no weapon event
      in the last 2 s is attributed with GetPedSourceOfDamage: an NPC, a vehicle's driver, or a player
      only when that player owns the ped (any other player's hit came as a weaponDamageEvent, and the
      source it left behind names nobody for later damage). Never "no source".

  Public API
    CP.Npc.setState(run, netId, state, extra) -> boolean
        state: 'idle'|'hostile'|'fleeing'|'surrendered'|'cuffed'|'dead'|'restrained'|'freed'|'safe'|
               'driving'|'stopped'. extra (optional table) is merged into the bag: cfg merges into
               bag.cfg, task = { action, args } is a one-off client task for the run host
               (CP.Npc.task) identified by bag.taskSeq (the seq it was written with), any other key
               is copied (run, obj, state, seq and taskSeq are protected). A state change drops the
               previous task. Setting the same state with no extra is a no-op.
    CP.Npc.getState(netId) -> state|nil                    the server record (never the replicated bag);
                                                           nil for a net id no live run has
    CP.Npc.isNeutralised(netId) -> boolean                 dead or cuffed
    CP.Npc.rollSurrender(run, netId, chance) -> boolean    one roll per ped with the run's NPC rng
                                                           (CP.U.rng(run.seed ~ salt)); repeated calls
                                                           for the same ped return the first result;
                                                           chance is a fraction (a value > 1 is read as
                                                           a percentage)
    CP.Npc.enableCuff(run, netId, opts) -> boolean         opts = { label, duration = 5000, maxDistance = 3.0 }
                                                           writes bag.cuff = { label, duration, maxDistance }
    CP.Npc.onDeath(fn(run, netId, killerSrc|nil, killerIsParticipant))
    CP.Npc.onDamaged(fn(run, netId, attackerSrc|nil))     damage to peds whose role is 'hostage'
                                                           (attackerSrc nil = an NPC)

  Events and handlers
    RegisterNetEvent crimson-police:server:npcCuff (runId, netId)      rate limited 3 per 2 s
    AddEventHandler weaponDamageEvent (sender, data)
    AddEventHandler playerDropped
  Player-facing text (toasts through CP.Tablet.notify): npc.shot_surrendered, err.npc_* (npc.json).
  No database queries.
```

## Crimson-Police/modules/operations/client.lua

```text

modules/operations/client.lua · CP.Operations (client): the Cross-Department Mission toast.

The server (modules/operations/server.lua) sends crimson-police:client:operation to every on-duty
officer of every department when an operation is launched (or relaunched), when its run starts, when
it ends Completed and when it is cancelled. This half turns that into a Crimson-Police toast
(CP.Tablet.notify with translated text; the Mission Board refreshes itself from the 'board' push).
Nothing is created in the game world, so there is nothing to clean up on resource stop.

Public API (client)
  CP.Operations.last() -> { state, missionLabel, id, at } | nil   the last operation event received
Events handled: crimson-police:client:operation (state, missionLabel, extra = { id, relaunched })
```

## Crimson-Police/modules/operations/server.lua

```text

modules/operations/server.lua · CP.Operations (server): Cross-Department Missions.

Owns: the one active Cross-Department Mission ("operation"), the board lock for every department
while it is active, its join window, the start of its run through CP.Runs.create, fail → relaunch /
cancel, the idle auto-cancel, the server-wide launch cooldown, the cp_operations rows, the
operation notifications (client:operation to every on-duty officer, CP.Tablet.notify to the people
concerned, pushes 'operation' and 'board') and the operations audit / webhook entries.
SPEC "Cross-Department Missions", "Supervisor & admin actions" (launch row), "Data model" cp_operations.

Life cycle (cp_operations.status):
  joining  launched (or relaunched): officers of every department join, up to Config.CrossDept.maxParticipants;
           joining closes when the launcher taps Start now or after Config.CrossDept.joinWindow seconds.
           At window end the run starts by itself with enough participants, otherwise → waiting.
  running  the run exists (accepted → in progress). Operation runs ignore cooldowns, the no-repeat rule,
           the hourly cap and the server cap and roll no modifier (CP.Runs / CP.Events decide that from
           run.operationId). Nobody can join any more.
  waiting  the run failed, every participant left, or the window closed without enough participants /
           without a free location: still active (the board stays locked); any supervisor may relaunch
           (a new join window) or cancel. Config.CrossDept.idleCancel seconds with no run (counted from the
           launch or the end of the last run; a relaunch does not reset it) → auto-cancel once no join
           window is open.
  completed  the run was Completed: the lock lifts.            (final, ended_at set)
  cancelled  cancelled by a supervisor/admin, by the idle rule, or by a restart.   (final, ended_at set)
The board lock (isLocked) holds for joining, running and waiting. Cancelling a running operation ends
every participant still on the run with end reason 'cancelled' (no cooldown, no penalty).
A launch starts the server-wide cooldown Config.CrossDept.cooldown, counted from cp_operations.created_at
of the last launch (persisted, so a restart keeps it); a relaunch is not a new launch.
Restart safety: rows left joining/running/waiting by a previous server start are marked cancelled.

Public API (docs/ARCHITECTURE.md §5.17)
  CP.Operations.active() -> op|nil       the live operation table (read only):
      op = { id, missionId, missionLabel, missionType, status, launchedBy (citizenid), launcher (name),
             createdAt, joinEndsAt|nil, participants = { { src, citizenid, name, callsign, department,
             departmentShort, rank, joinedAt } }, runId|nil, idleSince, waitingReason|nil, attempt }
  CP.Operations.isLocked() -> boolean     an operation is joining, running or waiting
  CP.Operations.boardCard(src) -> card|nil   BoardData.operation (§9.4) + missionType, missionTypeLabel,
      description, min, runState, joinBlocked (the err.* key a Join would return while canJoin is false)
  CP.Operations.launch(src, missionId) -> ok, data|errKey      (permission launchCrossDept)
  CP.Operations.startNow(src) -> ok, data|errKey               (the one who opened the join window, an admin,
                                                                or anyone allowed when that person is offline)
  CP.Operations.relaunch(src) -> ok, data|errKey
  CP.Operations.cancel(src, reason) -> ok, data|errKey         src 0 = the server (no permission check)
  CP.Operations.join(src, opId) -> ok, data|errKey             officers of any department (server:joinOperation)
  CP.Operations.onRunEnded(run, state)                         (hook, CP.Runs) state 'completed' | other
  CP.Operations.view(src) -> OperationView (callback sup:getOperation, shape below)
  CP.Operations.cooldownLeft() -> seconds until the next launch is allowed (0 = now)
  CP.Operations.eligible(def) -> ok, errKey   launchable: published and enabled, departments empty
      (open to every department), maxOfficers >= 2, never the Weekly Boss
Net (CP.Net; every sup/admin action checks CP.Permissions.can(src, 'launchCrossDept') first, the admin
ones also require an admin)
  actions server:sup:opLaunch / server:admin:opLaunch   { missionId }  -> { id }
          server:sup:opStart / server:admin:opStart     -              -> { runId, participants }
          server:sup:opRelaunch / server:admin:opRelaunch -            -> { id }
          server:sup:opCancel / server:admin:opCancel   { reason }     -> { id }   (reason 1-200 characters)
          server:joinOperation                          operationId | { operationId } -> { id, joined, max }
                  (the operation state is checked again after the checks that may yield, so a join never
                  passes the cap or lands after Start now copied the list)
  callback sup:getOperation -> OperationView
      { operation = null | { id, missionId, missionLabel, missionType, missionTypeLabel, difficulty,
          launcher, launcherCallsign, launcherDepartment, launchedAt, status, runState, runId,
          participants = { { src, name, callsign, departmentShort, department, status, arrived } },
          departments = { { short, count } }, joined, max, min, joinEndsIn, idleCancelIn, tier,
          tierExpected, remaining, waitingReason, attempt, canStart, startBlocked, canRelaunch, canCancel },
        cooldownLeft, cooldown, joinWindow, idleCancel, maxParticipants, crossBonus (Config.CrossDepartmentPoints),
        enabled, canLaunch, launchBlocked, serverTime,
        eligibleMissions = { { id, label, type, typeLabel, difficulty, minOfficers, maxOfficers } } (no operation only) }
Client event: crimson-police:client:operation (state 'launched'|'started'|'ended'|'cancelled', missionLabel,
extra = { id, relaunched }) to every on-duty officer. Pushes: 'operation' and 'board' ({ id|false, status|false })
to every department member online (and 'operation' to online admins).
```

## Crimson-Police/modules/payouts/server.lua

```text

modules/payouts/server.lua · CP.Payouts (server): editable base cash payouts per mission type and per
mission, the supervisor limits and the Payouts screens of the Supervisor UI and the Admin UI.

Owns
  * cp_type_payouts (one row per type an admin or a supervisor has changed; admin_locked = 1 when an
    admin set it: permanent and read-only for supervisors) and cp_mission_payouts (admin only,
    permanent until an admin clears it), both cached in memory and reloaded after every write
  * the base payout B of a mission (SPEC "Cash payouts"): the admin mission payout if set; the Weekly
    Boss's Config.Events.weeklyBoss.payout otherwise; else the type payout x Config.Difficulty.cashByStars
  * who may change what: supervisors change a type (never one an admin set) only within
    Config.Payouts.supervisorRange of its Config.MissionTypes payout, at most once per
    Config.Payouts.supervisorCooldown seconds per type (any supervisor, timed by updated_at), with a
    reason; admins set any type or mission payout within Config.Cash.minPayout..maxPayout and are the
    only ones who clear. Every change is audited (CP.Admin.audit, category 'audit', which also posts the
    audit webhook) and pushed to open screens (topics 'payouts' and 'board').

Public API (docs/ARCHITECTURE.md §5.21)
  CP.Payouts.typePayout(type) -> amount, adminLocked      stored amount, or the Config.MissionTypes payout
  CP.Payouts.missionPayout(missionId) -> amount|nil        the admin mission payout
  CP.Payouts.baseFor(mission) -> B                         whole dollars (halves up)
  CP.Payouts.sourceFor(mission) -> 'admin'|'type'|'event'  where B comes from
  CP.Payouts.setType(src, type, amount|nil, reason, role) -> ok, errKey|entry
      role 'supervisor' | 'admin' (default: admin when src is an admin, else supervisor). amount nil =
      clear (admin only). src 0 = the server console (admin). On success the second value is the
      updated type entry of list().types.
  CP.Payouts.setMission(src, missionId, amount|nil, reason) -> ok, errKey|entry   (admin only; nil = clear)
  CP.Payouts.list() -> { types = { TypeEntry... }, missions = { MissionEntry... } }
      TypeEntry    = { key, label, points, amount, default, adminLocked, stored, updatedBy, updatedByName,
                       updatedAt (unix s)|nil, supMin, supMax, cooldownLeft (s), missions (count) }
      MissionEntry = { id, label, type, typeLabel, difficulty, source ('builtin'|'custom'), isBoss,
                       enabled, base, payoutSource ('admin'|'type'|'event'), missionPayout|nil,
                       fallback (B without the mission payout), setBy|nil, setByName|nil,
                       updatedAt|nil, missing (a stored payout whose mission is not loaded) }
Net (docs/notes/economy.md has the response shapes)
  callback 'sup:getPayouts'   (permission setTypePayout)  -> SupPayoutsView
  callback 'admin:getPayouts' (admin)                     -> AdminPayoutsView
  action 'server:sup:setTypePayout'     { type, amount, reason }                 -> SupPayoutType
  action 'server:admin:setTypePayout'   { type, amount (nil/clear = clear), reason } -> TypeEntry
  action 'server:admin:setMissionPayout' { missionId, amount (nil/clear = clear), reason } -> MissionEntry
Every function that reads the tables may yield on the first call (cache load): call from a thread.
```

## Crimson-Police/modules/permissions/server.lua

```text

modules/permissions/server.lua · CP.Permissions: the one place that decides whether a role may do
an action. Every sup:* / admin:* handler (and every builder/test action) asks can() first.

Rules (SPEC "Supervisor & admin actions", Config.Permissions):
  * Admins (ace Config.AdminAce, or the server console) may do every action.
  * Supervisors may do a supervisor action only when Config.Permissions.supervisor[action] == true
    (read at call time) and they currently qualify as a supervisor (CP.Access.isSupervisor).
  * Admin-only, whatever the config says: setMissionPayout, clearPayout, manualAward,
    handleFailedDispute, voidAnyRun, seasons, bountyOverride, suspend, reloadMissions, testRun, openAdmin.
  * viewMissionList: supervisors and admins (no config switch).
  * Nobody may approve, void or answer a dispute about a run they took part in: pass ctx.runUuid with
    reviewFlagged, handleDisputes, handleFailedDispute or voidAnyRun and the own-run check applies to
    admins too.

Public API (docs/ARCHITECTURE.md §5.3)
  CP.Permissions.can(src, action, ctx) -> boolean, errKey
      ctx (optional table):
        runUuid      -> own-run check for the review actions above (err.own_run, err.invalid_run)
        department / departments -> a supervisor (not an admin) must belong to that department, or to
                        one of the list (err.other_department). Use it for "runs involving their department".
      errKey otherwise err.no_permission.
  CP.Permissions.actionsFor(src) -> { actionName, ... }   sorted; admins: every admin and supervisor
      action; supervisors: the switched-on supervisor actions + viewMissionList; others: {}.
  CP.Permissions.tookPart(citizenid, runUuid) -> boolean  any cp_mission_runs row of that run for that citizenid
  CP.Permissions.canReviewRun(src, runUuid) -> boolean, errKey   false with err.own_run when the reviewer
      took part: a cp_mission_runs row of that run (tookPart), or a participant entry (active or left) of
      that run while it is still live in CP.Runs (a partner who is still on the run has no row yet). The
      console and players without a character can review.
can, actionsFor, tookPart and canReviewRun may yield (database): call them from a handler or thread.
```

## Crimson-Police/modules/route/client.lua

```text

modules/route/client.lua · CP.Route (client): the GPS route to the mission start and the reports the
server checks (docs/ARCHITECTURE.md §5.12, SPEC "Route to the start").

Owns: the start waypoint, a temporary route blip used to read GTA's GPS route, the fixed polyline sampled
from it, the reports to server:routeStatus, the route part of the HUD (HudState.route) and the client
actions setGps and recalcRoute (NUI 'client' endpoint, registered with CP.Tablet.registerClientAction).

Public API
  CP.Route.begin(runId, startCoords, opts?) -> boolean
      Sets the waypoint (SetNewWaypoint) and a GPS route to the start, waits for the route to exist,
      samples it every Config.Route.sampleEvery m with GetPosAlongGpsTypeRoute over GetGpsBlipRouteLength
      into a fixed polyline (never recalculated automatically; when sampling fails the straight line from
      the player to the start is used and logged), then reports every Config.Route.reportEvery s the 2D
      distance from the player to that polyline (CP.U.distToPolyline) and the player's coords.
      opts = { startRoute = false (test run without the route: waypoint only, no reports, HUD 'disabled'),
      radius }. Idempotent for the same runId. CP.Runs calls it on client:start; this file also reacts to
      client:start itself, so a missed call cannot skip the route.
  CP.Route.recalculate() -> ok, data|errKey     asks the server (server:recalcRoute); on ok resamples the
      route from where the player is. data = { recalcsLeft }. errKeys: err.route_inactive,
      err.route_arrived, err.route_disabled, err.route_no_recalcs, err.busy, err.timeout. Yields.
  CP.Route.stop()                               clears the waypoint (when it is still ours), the blip and
                                                the reports; that run is never begun again on this client
                                                (CP.Runs calls it on arrival and at the end). Never touches
                                                the HUD (the run engine owns it).
  CP.Route.current() -> { runId, arrived, routeOn } | nil
Client actions: setGps (re-sets the waypoint to the start; the polyline stays the same), recalcRoute.
Events handled: client:routeWarning (runId, secondsLeft|nil) -> HUD { route = { status, secondsLeft,
distance } } and one toast when a warning first appears; client:routeRecalc (runId, ok, recalcsLeft);
client:routeStatus (runId, RouteStatus) and client:participants (runId, list) -> 'arrived';
client:start (fallback begin) and client:runEnded (fallback stop).
```

## Crimson-Police/modules/route/server.lua

```text

modules/route/server.lua · CP.Route (server): Hard rule 17, the route to the mission start
(docs/ARCHITECTURE.md §5.12, SPEC "Route to the start", CRIMSON_ARENA rules 5 and 6).

Owns: the per-participant route state, the plain net events server:routeStatus (runId, metres, coords)
and server:recalcRoute (runId), the 1 s arrival / off-route / drift checks, and the server -> client
events client:routeWarning (runId, secondsLeft|nil), client:routeRecalc (runId, ok, recalcsLeft) and
client:routeStatus (runId, RouteStatus) (sent when the server marks the arrival).

Public API
  CP.Route.begin(run, src) -> boolean
      Starts the checks for one participant (CP.Runs calls it for each participant at create; the 1 s
      tick also begins any active, not yet arrived participant it finds without a state, unless stop was
      called for them). Idempotent. Test runs with test.useStartRoute == false get the arrival check only.
  CP.Route.stop(run|runId, src?) -> nil      ends the checks for src (every participant when src is nil)
  CP.Route.status(run, src) -> RouteStatus
      RouteStatus = { status = 'on'|'off'|'arrived'|'disabled', secondsLeft = number|nil (only while the
      off-route warning is shown), recalcsLeft = number, distance = metres (straight line to the start,
      2D, rounded)|nil }  (HudState.route plus recalcsLeft for the Active Mission view)

Per participant: { lastReport, offSince, warned, recalcs, closest, distance, arrived, mode }.
Every 1 s, with the SERVER-SIDE ped position:
  * arrival: within location.start.radius (2D) of location.start.coords -> CP.Runs.markArrived(run, src),
    then the flag (CP.Alerts.set, idempotent if CP.Runs already set it) and client:routeStatus 'arrived';
    the checks stop for that participant. For Manhunt the start is the search circle: when the first
    objective is a search_area, its starting circle (location[obj.center], obj.startRadius) is used if it
    is larger than location.start, so the route leads to the centre until the officer is inside it.
  * off route: the last reported metres > Config.Route.maxDeviation, or no accepted report for
    Config.Route.reportTimeout s (off from the moment the timeout passed). After Config.Route.warnAfter s
    off route: client:routeWarning (runId, secondsLeft) every second; after Config.Route.abandonAfter s off
    route in one stretch: CP.Runs.removeParticipant(run, src, 'off_route'). A report within maxDeviation
    ends the stretch (client:routeWarning (runId, nil) when a warning was shown). When the warning appears
    or goes (and after a granted recalculation) the run view is pushed to the tablet (push topic 'run').
  * drift: the straight-line distance to the start grows more than Config.Route.maxDrift past the closest
    it has been -> 'off_route', whatever the client reports.
  * in-arena participants (CP.Alerts.inArena) are not route-checked and cannot arrive (CP.Alerts removes
    them from the run); their reports are ignored.
Reports: at most one per 0.9 s per player; ignored unless the runId is the sender's active run, metres is
a finite number >= 0 and the reported coords lie within Config.Route.maxDeviation (at least 150 m) of the
server-side ped position (a report that fails is treated as missing). Recalculate: Config.Route.maxRecalcs per
participant per run; a granted recalculation ends the current off-route stretch (the new line starts
where the officer is).
```

## Crimson-Police/modules/runs/client.lua

```text

 modules/runs/client.lua · CP.Runs (client): this player's side of the run engine.

  Owns
    The local copy of the player's run (from client:start / client:inProgress), the client halves of the
    objective blocks (ARCHITECTURE §7.2: prepare, start, update, stop, hostChanged) with a persistent ctx
    per objective, objective evidence (report, which adds coords and time), telemetry while on a run
    (vehicle netId every 5 s while driving, pedestrian hits by the player's vehicle, lights and siren on
    Beat Patrol / Business Check, weapon fired; each once where the spec says once), the mission HUD
    state through CP.Tablet.hud (phase route/objectives/ended, tier, timer, objectives, TEST RUN banner,
    test controls for the admin who started the test, end messages) and the result screen through
    CP.Tablet.result. Everything is removed when the run ends and on resource stop.

  Public API (client, ARCHITECTURE §5.10)
    CP.Runs.current() -> clientRun|nil
        { id, mission, location, locationIndex, seed, isHost, test, state, tier, payTier, modifier,
          objectiveIndex, host, participants, objectives, startRoute, startTimeout, isBoss }
    CP.Runs.report(index, evidence) -> boolean     server:objective (runId, index, evidence + coords + time)
    CP.Runs.telemetry(kind, data) -> boolean       server:telemetry (runId, kind, data)
    CP.Runs.getEntity(netId, timeoutMs) -> entity|nil
    CP.Runs.control(entity, timeoutMs) -> boolean  network control loop (run host only)
    CP.Runs.hudDetail(text|nil)                    the client-side HUD line for the current objective
  Client action (NUI 'client' endpoint): logResult { point, choice } -> report(current objective,
    { type = 'log', point, choice }) (Business Check tablet log)
  Events handled: client:start, client:inProgress, client:objective, client:hud, client:tierChanged,
    client:hostChanged, client:participants, client:runEnded (docs/ARCHITECTURE.md §8.1)

  Contract interpretations (docs/notes/engine_b.md)
    * client:start begins the start route with CP.Route.begin(runId, startCoords, { startRoute, radius })
      (a test run with the route off gets a waypoint only); CP.Route.stop() runs when this player arrives
      and at the end.
    * client:tierChanged may carry the rescaled objectives as a 4th argument (ctx.obj is updated).
    * client:runEnded's breakdown may carry failReason (a locale key) for mission_failed; a nil breakdown
      (silent removal) cleans up without the result screen.
    * The street · zone names of the start (client:start) and of each objective's reference point
      (client:objective 'start' carries `area`) are resolved here once each and sent as telemetry 'area'
      { index = 0 | objective, text }: the server shows them in this player's own Active Mission view.
    * A start whose radius is at least 200 m is a search circle (Manhunt: "the 600 m search circle, shown on
      the map when the type is accepted"): a local radius blip from client:start until this officer is
      inside it or the first objective starts (the block then draws its own circle), removed at cleanup.
```

## Crimson-Police/modules/runs/server.lua

```text

 modules/runs/server.lua · CP.Runs (server): the run engine.

  Owns
    The run lifecycle (accepted -> in_progress -> ended), per-participant end reasons and results
    (ARCHITECTURE §4.3), the start timeout, abandon, cooldowns (in memory, rebuilt from cp_mission_runs
    after a restart), the server run caps, the run host and host succession, rescaling when the team
    shrinks, the mission timer, objective sequencing through the blocks (§7.1), every networked entity a
    run spawns (OneSync server natives, the `cp` state bag, caps, corpse cleanup), mission items
    (ox_inventory, tagged { cpRun, cpItem }, orphan sweeps), the cp_mission_runs row of every participant
    (points and cash breakdown JSON), telemetry (vehicle damage, pedestrian hits, lights and siren,
    weapons fired), the Active Mission view and the live-run summary. Test runs write nothing and start
    no cooldown. A resource stop deletes every entity and writes nothing.

  Public API (server, ARCHITECTURE §5.10)
    CP.Runs.create(opts) -> run|nil, errKey
        opts = { mission, locationIndex, missionType, members = { officer|src }, leaderSrc, operationId,
                 test = { adminSrc, useStartRoute, forcedTier, draft }|nil, isBoss }
    CP.Runs.get(runId) -> run|nil          CP.Runs.getBySrc(src) -> run, participant (active only)
    CP.Runs.all() -> { run, ... }          CP.Runs.isOnMission(src) -> boolean  (+ export IsOnMission)
    CP.Runs.capsOk(missionType) -> ok, errKey
    CP.Runs.cooldowns(citizenid) -> { types = { [type] = untilTs }, missions = { [id] = untilTs } }
    CP.Runs.onCooldown(citizenid, missionType, missionId) -> boolean, untilTs
    CP.Runs.completionsLastHour(citizenid) -> integer
    CP.Runs.markArrived(run, src)                              (hook from CP.Route)
    CP.Runs.removeParticipant(run, src, endReason, opts) -> rowId|nil   opts = { keepFlag, silent, notify }
    CP.Runs.reclassify(citizenid, runId, newEndReason) -> boolean      (hook from CP.Calls)
    CP.Runs.endRun(run, state, endReason)                      state 'completed'|'failed'
    CP.Runs.failRun(run, reasonKey)
    CP.Runs.objectiveComplete(run, index, data) -> boolean
    CP.Runs.dispatch(run, index, src, ev) -> ok, reason
    CP.Runs.entityDied(run, netId, killerSrc)
    CP.Runs.award(run, id, opts) / CP.Runs.penalize(run, id, opts)   opts = { src, count = 1, points }
    CP.Runs.adjustTimer(run, seconds) / pauseTimer(run, paused) / remaining(run) -> seconds|nil
    CP.Runs.spawnPed(run, opts) / spawnVehicle(run, opts) / spawnObject(run, opts) -> entity, netId
    CP.Runs.deleteEntity(run, netId) / entitiesFor(run, filter) -> list / canSpawn(run, n, armed) -> boolean
    CP.Runs.send(run, eventName, ...) / objectiveEvent(run, index, data) / hud(run, patch) / hudFor(run, src, patch)
    CP.Runs.view(run, src) -> ActiveMissionView (§9.4) / summary(run) -> LiveRun (§9.5)
    CP.Runs.isParticipant(run, src) / activeSrcs(run) -> { src... } / host(run) -> src
    CP.Runs.testSkip(run) / testRestart(run) / anchor(run) -> vec3    (test runs only)
    CP.Runs.ctx(run, index) -> ctx|nil     the engine's ctx of objective index (e.g. CP.AntiCheat presence)
    CP.Runs.noteWeaponFired(run, src) -> boolean   server-side proof of gunfire by an active participant
                                           (CP.Npc: weapon hits / kills on mission NPCs); once per participant
    Internal (same slice, used by tests): CP.Runs._tick() one 1 s tick, CP.Runs._jobRecheck() one recheck pass
  Net
    callback 'getRun' -> ActiveMissionView|nil for the caller's run
    action   'server:abandon' (runId) -> removeParticipant(run, src, 'quit')
    event    'crimson-police:server:objective' (runId, index, evidence) -> CP.AntiCheat.checkEvent -> block onEvent
    event    'crimson-police:server:telemetry' (runId, kind, data)  kinds vehicle | ped_hit | lights_siren | weapon_fired
             | area ({ index = 0 (start) | the current objective, text = 'street · zone' }, the sender's own view)
    client events sent: client:start, client:inProgress, client:objective, client:hud, client:tierChanged,
    client:hostChanged, client:participants, client:runEnded; push topic 'run' (view, or nil when it ended)
  Loops
    1 s: timers, the current objective's block tick, time limit, start timeouts, arena re-check, entity
    bookkeeping (vanished entities, wrecked vehicles, corpse cleanup after Config.Limits.corpseCleanup),
    host liveness, HUD refresh. Config.AntiCheat.jobRecheck s: CP.Access.recheck. 60 s: orphan item sweeps
    and cache pruning.

  Contract interpretations (details in docs/notes/engine_b.md)
    * ctx.award/penalize accept opts.points, a per-occurrence value hint kept in run.score.values[id]
      (blocks pass it for ids whose value comes from block settings, e.g. hostage_hit).
    * ctx.hud({ detail, value, max }) belongs to that objective's HUD entry; other keys (message, ...)
      are top-level HUD fields. The full objectives list is resent whenever it changes.
    * Objective entities are never deleted when their objective completes, only at run end.
    * An early ctx.complete() is refused and flags the run too_fast once per objective (not on tests).
    * Flagged rows keep their computed points and cash (held) so an approval can release them.
    * penalty_points stores the positive sum of the penalties; bonus_points the sum of the bonuses.
    * Engine-recorded personal ids: pedestrian_hit and lights_siren (penalize), weapons fired go to
      run.stats.weaponsFired / p.firedWeapon, vehicle damage to p.vehicle.
    * create re-checks "already on a run", the server caps and the Cross-Department lock
      (CP.Operations.isLocked, normal runs and the boss) with no yield right before the run is registered
      (its lookups may yield, so two racing accepts can never both pass); CP.Calls.isOnCall (may yield) is
      re-checked for every member just before that block (err.on_call / err.member_on_call).
    * endRun first removes every active participant who is down (CP.Qbx.isDowned) with end_reason
      'downed' through CP.Downed.handle(run, src) (pick-up / EMS flow) or, without it, directly; only the
      others get the run's end state (Hard rule 18). A re-entrant endRun during those leaves is ignored.
    * An in-arena participant who leaves never has the crimsonArena bag touched (CRIMSON_ARENA rule 1):
      CP.Alerts.forget(src) (when present) drops the intent instead of CP.Alerts.clear.
    * Mission items (metadata.cpItem) cannot leave their holder's inventory: an ox_inventory swapItems hook
      refuses give / drop / stash / vehicle moves (re-registered when ox_inventory restarts).
    * Vehicle damage (p.vehicle) is sampled by the server every VEHICLE_SAMPLE_MS from the vehicle each
      active participant drives; client 'vehicle' telemetry only adds samples.
    * The `cp` state bag is written, never read back on the server (a client can write the bag of an
      entity it owns): run.entities[netId].bag is the server's copy (CP.Npc seeds its record from it and
      keeps it current), the armed-alive cap counts through CP.Npc.getState, and "is this a run entity"
      (vehicle and pedestrian telemetry) is answered from the engine's registry only.
    * Server-side health is sync data (0 until a client synced a server-created entity): health 0 only
      counts as a death/wreck after a positive value was seen; engine health <= -3999 always counts.
    * Spawns waiting for their entity count toward the caps; an entity that appears after the spawn wait
      is deleted when it does (model-checked), so nothing is left behind.
    * reclassify(..., 'real_call_cancelled') only replaces a real_call end reason.
    * Presence flags go through CP.AntiCheat.flag (audited like every flag); an off-duty CP.Access.onLost
      signal is re-verified with CP.Access.recheck (stale duty events are ignored).
    * Every run ticks in its own thread; a run whose previous tick is still busy is skipped that second.
    * ActiveMissionView extras (web/src/types/run_ui.ts): me, isBoss, operationId, startIn, area (street ·
      zone of the start / current objective as the viewer's own client resolved it: client:objective 'start'
      carries the objective's reference point, the client answers with telemetry 'area' { index, text }).
    * A new or closed tablet log point (view.log) pushes the 'run' topic at once; the HUD and the view
      also refresh right after every accepted objective event, not only on the next tick.
    * The unit is kept (and unlocked at the end) only for normal runs: test and operation runs never lock
      one, so they never unlock one either.
    * CP.Runs.ctx(run, index) returns the engine's own ctx of an objective (the one every hook gets).
```

## Crimson-Police/modules/scaling/server.lua

```text

modules/scaling/server.lua · CP.Scaling: tiers by participant count and scaled mission counts.

Owns the reading of Config.Scaling (the tier table), the scaled copy of a mission's objectives
(mission.scaling paths) and NPC combat values (base + tier, + Armored Hostiles on Tactical runs).

Public API (server)
  CP.Scaling.tierFor(n) -> row            first Config.Scaling row with maxParticipants >= n, else the last
  CP.Scaling.tierByName(name) -> row|nil  (a row passed in is returned as-is)
  CP.Scaling.lower(a, b) -> row           the lower of two tiers (rows or names; nil-safe)
  CP.Scaling.label(name) -> text          locale 'tier.<name>'
  CP.Scaling.scaleCount(base, tier) -> int   CP.U.round(base * tier.count), halves up
  CP.Scaling.apply(mission, tier) -> objectivesCopy
      deep copy of mission.objectives with every mission.scaling entry scaled. Entries are a path
      string ('objectives.1.waves') or { path = '...', max = n }. A path points at a number or a list
      of numbers; max clamps each scaled value. Paths are relative to the mission (the leading
      'objectives.' is optional).
  CP.Scaling.combat(baseAccuracy, baseArmour, tier, run) -> accuracy, armour
      + tier.accuracy / tier.armour; + Config.Events.armoredArmour when run.modifier is
      'armored_hostiles' and the run is Tactical. Accuracy is clamped to 0..100, armour to >= 0.
Rows are the Config.Scaling tables themselves: { maxParticipants, tier, count, accuracy, armour, points, cash }.
Internal (same slice, used by modules/missions): CP.Scaling._entryPath(entry) -> relPath, max;
CP.Scaling._isScalable(value) -> boolean.

Contract interpretations: combat() clamps accuracy to 0..100 (SetPedAccuracy range) but does not cap
armour above 100 (NPC armour may exceed it at Critical + Armored Hostiles); unknown tiers = Standard.
```

## Crimson-Police/modules/schedule/server.lua

```text

modules/schedule/server.lua · CP.Schedule: server-time calendar, reset boundaries and the retention job.

Owns
  * the reset-adjusted calendar: every "day" starts at Config.Time.resetHour (server local time),
    every week at that hour on Config.Leaderboard.weekStartsOn, every month at that hour on the 1st
  * the boundary listeners (daily, weekly, monthly) other modules subscribe to; checked every 30 s
    and fired once when a boundary passes, never just because the resource started
  * the retention job (Config.Retention) run at each daily reset (plus one catch-up run shortly after
    start, see docs/notes/engine_a.md): cp_mission_runs rows older than runArchiveMonths are copied
    into cp_mission_runs_archive and then deleted, cp_audit rows older than auditDays are deleted

Public API (server)
  CP.Schedule.now() -> ts                          os.time()
  CP.Schedule.dayKey(ts?) -> 'YYYY-MM-DD'          the reset-adjusted day
  CP.Schedule.dayStart(ts?) -> ts                  resetHour on that day
  CP.Schedule.weekStart(ts?) -> ts                 resetHour on Config.Leaderboard.weekStartsOn
  CP.Schedule.weekKey(ts?) -> 'YYYY-MM-DD'         date of the week start
  CP.Schedule.monthStart(ts?) -> ts                the 1st of the (reset-adjusted) month at resetHour
  CP.Schedule.weekday(ts?) -> 'monday'..'sunday'   of the reset-adjusted day
  CP.Schedule.sqlTime(ts) -> 'YYYY-MM-DD HH:MM:SS' (server local time, for DATETIME columns)
  CP.Schedule.onDaily(fn(dayKey))
  CP.Schedule.onWeekly(fn(weekKey, prevWeekStartTs))
  CP.Schedule.onMonthly(fn(monthStartTs))

Test hooks (internal): CP.Schedule._check(ts?) runs one boundary check (the 30 s loop calls it);
CP.Schedule._runRetention(ts?) -> { archived = n, auditDeleted = n } runs the retention job now.

Contract interpretations: the retention job also runs once 120 s after start (idempotent catch-up);
at the daily reset it runs in its own thread after the daily listeners, so a slow archive never
delays them; a clock that moves back to an earlier day fires nothing.
```

## Crimson-Police/modules/scoring/server.lua

```text

modules/scoring/server.lua · CP.Scoring (server): points, streaks, XP, XP levels, badges, manual awards
and the officer Home screen.

Owns
  * P and the points formula of a run row (SPEC "Scoring, points & XP levels"):
      Points = max(0, min(scoreCap x P, (P + Bonuses - Penalties) x M_team x M_cross x M_streak)), rounded
      down, then x Config.Events.todMultiplier when the run's mission type is the Type of the Day (after the
      cap). Failed = floor(failedCredit x P x objectives done / total) (no bonuses, multipliers or ToD);
      Abandoned = 0; a participant under the presence share (runs with 2+ participants) gets 0.
    Bonus/penalty lines: the mission card's entries (shared counts in run.score.shared plus personal ones in
    p.score; value = the entry's points / pctOfPoints, else Config.Bonuses; each = x count), ids recorded
    with a per-occurrence value (run.score.values), the end-evaluated no_participant_downed /
    no_weapons_fired (when the card lists them) and the common ones of Config.Scoring.common: fast_finish
    (not when run.flags.medals), modifier (Config.Events.modifierPoints), first_run, no_vehicle_damage,
    heavy_damage (not when mission.vehiclePenalties == false), pedestrian_hit, lights_siren (Beat Patrol and
    Business Check), shot_surrendered. Labels: CP.L('bonus.<id>') / CP.L('penalty.<id>').
    Custom missions (mission.source == 'custom'): mission-file value hints never raise points. A card
    entry is valued only when its id is in Config.Bonuses (points / pctOfPoints by the id's kind, else the
    config value, clamped to Config.Builder.bonusCap; each from Config.Bonuses only); the points /
    pctOfPoints / each of any other id are ignored. Recorded ids that are in Config.Bonuses but not on the
    card are ignored. Per-occurrence hints passed by block code (ctx.award opts.points: medal values,
    kingpin_alive, hostage_hit) still count; a positive one is capped at Config.Builder.bonusCap.points.
  * streaks (cp_officers.streak_days, last_complete, grace_week, grace_used): consecutive reset-adjusted
    days with a completed run; up to Config.Scoring.streakGraceDays missed days per week (counted from the
    weekly reset) are forgiven and add nothing; M_streak = 1 + min(streakMax, streakStep x days)
  * XP (cp_officers.xp = lifetime points, never below 0) with an idempotency marker in the row's breakdown
    ('$.xpCounted'), XP levels (Config.XPLevels, cosmetic), the five achievement badges (Config.Badges,
    counted from cp_mission_runs + cp_mission_runs_archive, revoked when a void drops a count below its
    threshold), manual_award rows, "first completed run since going on duty" (CP.Qbx duty/load events)
  * callback getHome -> HomeData (ARCHITECTURE §9.4)

Public API (docs/ARCHITECTURE.md §5.18)
  CP.Scoring.P(mission) -> number                     whole points (halves up)
  CP.Scoring.compute(run, p, result, opts) -> RunResult.points (§9.6)
      result 'completed'|'failed'|'abandoned'; opts (all optional) = { objectivesDone, objectivesTotal,
      failedShare, durationS, participants, departments, endReason } as modules/runs passes them.
  CP.Scoring.isFirstRunSinceDuty(src) -> boolean
  CP.Scoring.streak(citizenid) -> { days, multiplier, graceLeft }
  CP.Scoring.onRowCounted(citizenid, row)   (hook) row = the inserted cp_mission_runs columns + id
  CP.Scoring.onRowApproved(rowId)            (hook) a flagged row was approved (flagged already 0)
  CP.Scoring.onRowVoided(rowId)              (hook) a row was voided (XP taken back when it had counted)
  CP.Scoring.manualAward(actorSrc, citizenid, points, reason) -> ok, errKey|rowId   (admin only, audited)
  CP.Scoring.xpLevel(xp) -> { label, badge, xp, next }       xp = the level's threshold, next = the next one or nil
  CP.Scoring.badges(citizenid) -> { { id, label, earnedAt, earnedTs } ... }   every badge in cp_badges
Net: callback 'getHome' -> HomeData (officers only; CP.Access.getOfficer error keys otherwise)
compute, streak, the hooks, manualAward and badges query the database: call them from a thread.
```

## Crimson-Police/modules/storage/memsql.lua

```text

modules/storage/memsql.lua · CP.Storage.MemSQL: the SQL engine and the saves folder behind "database off"
(Config.Database.enabled = false). fxmanifest loads it before every other server module; it only
defines functions. modules/storage/server.lua decides whether it is used.

What it is
  * CP.Storage.MemSQL.new({ store = store }) -> db: an in-memory SQL engine for exactly the MariaDB 10.11
    dialect Crimson-Police's modules send (the inventory's construct list, see "Supported SQL" below),
    with MariaDB semantics: utf8mb4_general_ci text comparison with MariaDB's own weight table (case and
    accents ignored, PAD SPACE; JSON text is binary), NULL three-valued logic, strict mode, NULL first in
    ascending order, integer / DECIMAL / DOUBLE arithmetic (a BIGINT result out of range is MariaDB's error
    1690), one NOW() per statement. db:exec(sql, params) runs one statement atomically: a failing statement
    leaves nothing changed. With db.slice (CP.Storage sets it on a server) a SELECT run from a thread gives
    the server its turn every few milliseconds; every other statement waits for it.
  * CP.Storage.MemSQL.shim(db, opts) -> a table shaped like oxmysql's MySQL global (query, single, scalar,
    insert, update: callable with a callback and with .await; ready). Results are typed like oxmysql:
    TINYINT(1) columns as booleans, DECIMAL and SUM() as strings, DATETIME/DATE as milliseconds, text
    always as strings, UPDATE counts matched rows. A statement that names only tables of other
    resources (not cp_*) is sent read-only to the real oxmysql (opts.realMySQL).
  * CP.Storage.MemSQL.folderStore(dir) -> the saves folder, written through after every write statement.
  The engine runs inside FiveM and under plain lua5.4 (tests); it uses io, os, utf8 and the global json.

The saves folder (Crimson-Police/saves by default; Config.Database.folder)
  _tables.json       every table layout as a CREATE TABLE statement (built by the migrations), how each
                     table is split into documents, the next AUTO_INCREMENT id where the rows cannot
                     tell it, and the applied migrations (the rows of cp_schema_migrations).
  <table>.json       one document per table, named after the table without the cp_ prefix
                     (officers.json, seasons.json, custom_missions.json, mission_runs.json ...):
                       {"table":"cp_officers","columns":["citizenid","callsign",...],"rows":[
                       ["ABC12345","101",null,...],
                       ["XYZ98765",null,"Sergeant",...]
                       ]}
                     The column names are written once, then one row per line as an array of values in
                     column order: DATETIME as unix seconds (a moment), DATE as "YYYY-MM-DD" (a calendar
                     day: a folder moved to a server in another time zone keeps its days), TINYINT(1) and
                     other integers as numbers, DECIMAL as a number with its decimals, text as a string, and
                     a JSON column embedded as JSON when it is a one-line object or array (it is read back
                     byte for byte), otherwise as a string. Nothing else is stored: no journal, no copies.
  <table>_<n>.json   a table that grows past 500 rows is split so no document holds (and no save
                     rewrites) more than about 500 rows: integer ids by range (mission_runs_1.json holds
                     ids 1-500, mission_runs_2.json 501-1000 ...), other keys by a stable hash bucket of the
                     key (linear hashing: one bucket splits at a time). An emptied range document is removed
                     unless it is the newest; hash buckets and the one document of a table always stay, so a
                     missing document is noticed.
  Write-through: at the end of every write statement the documents it changed, and _tables.json if it
  changed, are saved before the statement returns. First every one of them is written as <name>.tmp (a
  failure there, a full disk, changes no document); then each .tmp is renamed over its document (where a
  rename cannot replace a file, as on Windows: old -> <name>.bak, tmp -> name, .bak removed), in an order
  where a crash in between never loses a saved row: new documents, documents that receive rows (a row whose
  key moves is saved in its new document before it leaves its old one), the others, _tables.json, removals.
  A save that fails part way is undone: memory is rolled back and the documents already changed are
  written back from it (Store:restore); what cannot be written back then is written at the next save.
  FXServer's Linux build answers os.rename the wrong way round; each saves folder finds out how this
  runtime answers (Store:_probeRename). Loading removes leftover .tmp files, restores a .bak whose document
  is missing, loads every document it finds and raises each AUTO_INCREMENT counter to at least max(id) + 1
  (and past the ids of a missing newest document), so an interrupted save never loses saved rows or reuses
  an id. A document with a byte order mark or reformatted by an editor is read; a missing document is
  reported; a document with a value too many or too few, a key twice or NULL in a NOT NULL column stops the
  start with its name and line.

Supported SQL (anything else raises "the saves folder engine (files mode) does not support ...")
  SELECT [DISTINCT] items [AS alias] | * FROM table [alias] | (subquery) alias | DUAL
    [INNER] JOIN / LEFT [OUTER] JOIN ... ON, WHERE, GROUP BY (columns, expressions, select aliases),
    ORDER BY [ASC|DESC] (select aliases win), LIMIT n|? [OFFSET n|?], UNION ALL (in derived tables).
  INSERT [IGNORE] INTO t [(cols)] VALUES (...)[, (...)] | SELECT ... [ON DUPLICATE KEY UPDATE c = expr,
    VALUES(c)]; UPDATE [IGNORE] t [alias] SET [a.]c = expr ... [WHERE]; DELETE FROM t [WHERE];
    DELETE a FROM t a [INNER|LEFT] JOIN ... [WHERE].
  CREATE TABLE [IF NOT EXISTS] t (columns, PRIMARY KEY, UNIQUE KEY, KEY/INDEX) | LIKE other;
    ALTER TABLE t ADD [COLUMN] [IF NOT EXISTS] col [FIRST | AFTER c] | ADD [UNIQUE] {INDEX|KEY} [IF NOT EXISTS]
    [name] (cols), several separated by commas; CREATE [UNIQUE] INDEX [IF NOT EXISTS] name ON t (cols) (the
    additive changes of the SPEC's database upgrades); types INT, TINYINT, SMALLINT, MEDIUMINT, BIGINT, VARCHAR(n),
    DECIMAL(p,s), DATETIME, DATE, ENUM(...), JSON; NOT NULL, NULL, DEFAULT, AUTO_INCREMENT,
    CURRENT_TIMESTAMP defaults and ON UPDATE CURRENT_TIMESTAMP.
  Expressions: literals, ?, columns, + - *, = <> != < <= > >=, AND OR NOT, IS [NOT] NULL, [NOT] IN (list |
    subquery), [NOT] EXISTS, scalar subqueries, [NOT] LIKE, CASE, date +/- INTERVAL n SECOND|MINUTE|HOUR,
    COUNT SUM MAX MIN GROUP_CONCAT(... ORDER BY ... SEPARATOR ...), COALESCE IFNULL NULLIF IF GREATEST LEAST ROUND
    DATE DATE_FORMAT UNIX_TIMESTAMP FROM_UNIXTIME NOW CURRENT_TIMESTAMP TIMESTAMPDIFF SUBSTRING_INDEX
    CHAR_LENGTH LOWER UUID JSON_SET JSON_REMOVE JSON_EXTRACT JSON_UNQUOTE JSON_VALUE JSON_VALID
    JSON_CONTAINS JSON_TYPE.

Proof: tests/run.lua --storage=shadow runs every spec's statements on MariaDB (read like oxmysql) and here, and
--fuzz random SQL (tests/shadow/fuzz_*.lua); both compare every answer. MariaDB details copied on purpose:
GROUP_CONCAT(... ORDER BY k) sorts a NULL k as 0 / '' / the zero date and puts the newer row first on a full tie;
AUTO_INCREMENT ids come in the server's and InnoDB's intervals (section 8, compileInsert), and an UPDATE (or ON
DUPLICATE KEY UPDATE) that sets the AUTO_INCREMENT column at or past the counter moves it on; an UPDATE whose WHERE
MariaDB proves impossible answers without "Rows matched"; storing follows Field::store in strict mode, with its
errors, IGNORE's warnings and the notes (section 7), dates are read in all of MariaDB's spellings (strTime), a
failing CHECK (JSON_VALID) skips the row with IGNORE except in a one-row INSERT ... VALUES; an ENUM is its member
number in number contexts and ORDER BY / GROUP BY; GREATEST / LEAST compare text with numbers as DOUBLE; a
comparison or TRUE is a boolean (JSON_SET stores true); a DOUBLE is written like MariaDB (0.00001, 1e15) and
reaches Lua as an integer when whole and below 2^53 (FiveM's msgpack); a BIGINT beyond 2^53 as text (mysql2). Left
as they are, because MariaDB decides them by its query plan, not by the SQL: the order of rows tied on every ORDER
BY key, which rows a LIMIT without ORDER BY returns, the text shown for a GROUP BY on a text column whose rows
differ only in case or accents, and which row an UPDATE that breaks a UNIQUE key reports first (here: table
order). Not copied (Crimson-Police never does these): zero dates and dates with a zero month or day (refused as
unsupported, also where IGNORE or ALTER TABLE ... ADD a NOT NULL DATETIME without a default would store one); a
comparison of two parameters or literals (NULLIF(?, '')) uses utf8mb4_general_ci, the connection collation with
charset=utf8mb4 in mysql_connection_string (without it mysql2 connects as utf8mb4_unicode_ci, where for example
'ß' = 'ss' and a text of zero-width characters equals ''); warnings raised while evaluating an expression (a text read as a
number, "Truncated incorrect DOUBLE value"), which MariaDB counts as often as its plan evaluates it; the text of
COALESCE / IF / CASE / GREATEST of decimals with different scales where text is needed (MariaDB shows the chosen
argument's own digits: '1', not '1.00'); DECIMAL values of more than 18 digits (MariaDB: 65; refused as
unsupported); integer literals beyond BIGINT (read as DOUBLE here); subnormal doubles stored in short VARCHARs.
```

## Crimson-Police/modules/storage/server.lua

```text

modules/storage/server.lua · CP.Storage: where Crimson-Police keeps its data (Config.Database).

  Config.Database.enabled = true   MySQL/MariaDB through oxmysql, exactly as before (nothing here runs).
  Config.Database.enabled = false  database off: this file replaces the MySQL global of this resource with
                                   CP.Storage.MemSQL.shim before any other module can query, and every cp_ table
                                   lives as documents in the saves folder (modules/storage/memsql.lua).
                                   The modules keep their SQL; the migrations build the same tables.

Public API (server)
  CP.Storage.mode() -> 'database' | 'files'
  CP.Storage.name() -> 'database' | 'saves folder' (for console text: "the %s")
  CP.Storage.folder() -> the saves folder's full path (files mode) or nil
  CP.Storage.describe() -> one line for the start-up log
  CP.Storage.loadError() -> why the saves folder could not be used, or nil
  CP.Storage.hasSavedData() -> true when Config.Database.folder holds saves (a _tables.json), in either mode
  CP.Storage.realMySQL   oxmysql's MySQL table (files mode): the one read-only lookup of another
                         resource's table (sc-dispatch's mdt_dispatch, Hard rule 15) still goes there
  CP.Storage.db          the CP.Storage.MemSQL engine (files mode)
  CP.Storage.MemSQL      the engine's code (modules/storage/memsql.lua); this module's one global table holds both

fxmanifest loads memsql.lua and this file right after @oxmysql/lib/MySQL.lua and before every other server
module. The modules/**/server.lua glob matches this file a second time; that load returns at once.
FiveM resource KVP is not used anywhere. On FXServer a resource may only write inside resource folders (its
Lua file sandbox): the saves folder is a folder inside Crimson-Police, 'saves' unless Config.Database.folder
names another one.
```

## Crimson-Police/modules/tablet/client.lua

```text

modules/tablet/client.lua · CP.Tablet (client): the NUI. The only file that calls SendNUIMessage.

Owns: /CrimsonPolice (Config.Tablet.command), the key mapping crimsonpolice_tablet (default key
Config.Tablet.keybind; '' = unbound, players can bind it in GTA settings), the optional ox_inventory
tablet item, the client export OpenTablet, opening/closing the Officer, Supervisor and Admin UIs with
NUI focus, the tablet prop and animation (Officer/Supervisor UI only), toasts, the mission HUD state,
the result screen, overlays, live pushes, the department theme sent at login, and every NUI callback.
Every open goes through the server callback getSession, so the server decides who may open what.

Public API (docs/ARCHITECTURE.md §5.4)
  CP.Tablet.open(ui) -> ok, errKey        ui 'officer'|'supervisor'|'admin'; asks getSession, shows the
                                          UI and takes focus; on refusal shows the error as a toast.
                                          Yields (call it from a thread).
  CP.Tablet.close() -> boolean            hides the UI (the HUD stays), releases focus, removes the prop
  CP.Tablet.isOpen() -> boolean
  CP.Tablet.send(msg)                     SendNUIMessage (vectors serialised)
  CP.Tablet.notify(kind, text, opts)      a toast with already translated text; opts = { title, duration }
  CP.Tablet.hud(patch)                    shallow-merges patch into the HUD state (§9.3) and sends
                                          { type = 'hud', hud = state }; hud(nil) hides it. A nullable
                                          field (modifier, timer, route, message, detail) set to false
                                          is cleared (Lua tables cannot hold nil).
  CP.Tablet.result(result)                { type = 'result', result } (RunResult §9.6; nil hides it)
  CP.Tablet.overlay(o)                    { type = 'overlay', overlay = o } (nil hides it)
  CP.Tablet.push(topic, data)             { type = 'push', topic, data } for local live updates
  CP.Tablet.registerClientAction(name, fn(payload) -> ok, data|errKey)
                                          handlers for the NUI 'client' endpoint (built in: logoFailed,
                                          forwarded to the server action server:logoFailed)
  CP.Tablet.panelFocus(owner, on) -> boolean
                                          NUI focus for a Crimson-Police HUD panel that is not the tablet
                                          (modules/testing: the test-control panel and the test invitation
                                          prompt, owner 'testing'). on = true: SetNuiFocus(true, true) unless
                                          a tablet UI is open or opening, another owner holds the panel
                                          focus, or the local crimsonArena value is foreign (false then).
                                          on = false: released only by the owner that holds it, and
                                          SetNuiFocus(false, false) is only called when no tablet UI is open.
                                          A tablet UI that opens takes the focus over (the owner loses it);
                                          a foreign crimsonArena value, a character unload and the resource
                                          stop release it.
  CP.Tablet.panelFocusOwner() -> owner|nil  who holds the panel focus (nil also after a tablet takeover)
  CP.Tablet.cpProgressActive() -> boolean  a progress bar started by Crimson-Police runs (lib.progressBar
                                          and lib.progressCircle of this resource's ox_lib are wrapped
                                          once, at load and at runtime wiring, to count them)
Events handled: crimson-police:client:notify ({ kind, key, vars, title, duration }, translated with
CP.L), client:push (topic, data), client:openAdmin (session). This file registers NO handler for
client:hud or client:runEnded: the run engine's client (modules/runs/client.lua) is the one path that
forwards them, to CP.Tablet.hud (patches, the ended HUD, hud(nil) when it hides) and CP.Tablet.result.
NUI callbacks (§9.1): ready, close, request { name, args } -> CP.Net.request, action { name, payload }
-> CP.Net.action (names must start with 'server:'), client { name, payload } -> registered client
actions, switchUi { ui } -> getSession for that UI; replies { ok = true, data = Session } and re-opens.
The UI closes on duty loss, on a switch away from the job it was opened with (or out of every
department) and on character unload (the Admin UI only on unload).
Crimson-Arena (docs/CRIMSON_ARENA.md rule 8): while the local player carries a foreign crimsonArena
value (Crimson-Arena's, not { source = 'crimson-police' }) the command, key mapping, tablet item,
OpenTablet, switchUi and client:openAdmin refuse with the toast err.in_arena; when such a value
arrives, every Crimson-Police UI closes (prop deleted, animation stopped), the HUD and overlays are
hidden and a progress bar started by Crimson-Police itself is cancelled (CP.Tablet.cpProgressActive();
another resource's bar is left alone). While the value stays foreign, HUD patches and overlays (e.g. the run engine's ended HUD after the arena removal) are kept but not shown;
they are shown again once the value is no longer foreign. NUI focus is only released when a
Crimson-Police UI (the tablet, or a panel holding CP.Tablet.panelFocus) was open, never
unconditionally. The tablet prop is a local (non-networked) object.
Exports: OpenTablet() (the same checks as /CrimsonPolice), useTablet(data, slot) for ox_inventory.

ox_inventory item (optional): set Config.Tablet.item = 'crimson_police_tablet' and add to
ox_inventory/data/items.lua:
    ['crimson_police_tablet'] = {
        label = 'Police Tablet', weight = 500, stack = false, close = true,
        client = { export = 'Crimson-Police.useTablet' },
    },
Using the item opens the Officer UI with the same server checks as the command.
```

## Crimson-Police/modules/tablet/server.lua

```text

modules/tablet/server.lua · CP.Tablet (server): sessions for the three UIs, toasts, live pushes,
the Admin UI opener and the department logo checks.

Owns the callback getSession, the action server:logoFailed and the server side of the client events
crimson-police:client:notify / client:push / client:openAdmin (docs/ARCHITECTURE.md §8.1).

Public API (docs/ARCHITECTURE.md §5.4)
  callback getSession(args) -> Session (§9.2)
      args = { ui = 'officer'|'supervisor'|'admin' (default 'officer'), silent = bool }
      officer:    an officer (CP.Access.getOfficer) -> its errKey otherwise (err.not_police,
                  err.not_on_duty, err.suspended, err.suspended_dispatch)
      supervisor: an officer whose grade is at or above supervisorGrade, or an officer who is also
                  an admin -> err.not_supervisor otherwise
      admin:      the ace Config.AdminAce, on duty or not, police or not -> err.not_admin otherwise
      roles = { officer, supervisor (= officer and (isSupervisor or admin)), admin }; officer is set
      whenever the player qualifies as an officer (also in the Admin UI); theme = the department's
      theme (Config.AdminTheme, validated, for the Admin UI); logo = the department logo, or nil for
      the Admin UI, a department without a logo, or a logo file missing from logos/.
      config = { missionTypes (key,label,points; by points), departments (key,label,short,primary),
                 tiers (name, label = CP.Scaling.label(name), else CP.L('tier.<name>')), maxRecalcs, disputeWindowHours,
                 periods, filters }, locale = CP.Locale.all(), serverTime = os.time().
      Opening the Officer/Supervisor UI refreshes the stored rank/callsign (CP.Access.refreshOfficerRow);
      silent = true (the theme fetch at login) skips that. nil fields arrive in the NUI as missing keys.
  CP.Tablet.notify(src, kind, key, vars, opts) -> boolean
      kind 'info'|'success'|'warning'|'error'; key/vars a locale key and its variables (translated on
      the client); opts = { title = localeKey, duration = ms }
  CP.Tablet.notifyMany(srcs, kind, key, vars)       the same toast for a list of players (deduplicated)
  CP.Tablet.push(src, topic, data) -> boolean       NUI { type = 'push', topic, data } (vectors serialised)
  CP.Tablet.openAdmin(src) -> ok, errKey            builds the admin session and opens the Admin UI
      (client:openAdmin); err.not_admin, err.not_in_game (console). Called by modules/admin.
  action server:logoFailed (deptKey | { department, url })   the NUI could not load a department logo:
      one console warning per department (err.unknown_department for an unknown one).
At start every file-based department logo is checked with LoadResourceFile: one warning per missing
file, and that department's session carries no logo (no broken image in the NUI).
```

## Crimson-Police/modules/testing/client.lua

```text

 modules/testing/client.lua · CP.Testing (client): the test-control panel, the debug overlay drawing
  and the test invitation prompt.

  Owns
    * the key mapping +crimsonpolice_testpanel (default F7, rebindable in GTA settings; F9 is sc-multijob's).
      For the admin who started the active test it gives NUI focus to the HUD test-control panel
      (hud/TestControls.tsx); with no controls it opens the test invitation prompt (hud/DebugOverlay.tsx) when invitations are waiting,
      and with nothing to open it does nothing (no server call, no toast).
      NUI focus is taken only while the panel/prompt is open and only when no Crimson-Police UI is open, and
      it is released on close, Escape/the key (the NUI calls the client action testPanel), when the test ends,
      on a foreign crimsonArena value and on resource stop. It is never released unconditionally.
    * the HUD flag testControls (CP.Tablet.hud({ testControls = true })) re-asserted for the admin's run
      (CP.Runs client sets it at client:start; this module only patches a HUD that belongs to that run)
    * the in-world debug overlay while it is on: DrawMarker for the start radius, spawn points, zones and
      route waypoints (with lines between waypoints), drawn every frame only within DRAW_RANGE of the player
      and only while the player is near the test area; otherwise the loop sleeps 500 ms
    * live counts pushed to the NUI: CP.Tablet.push('test', { controls, focused, key, debugOn, runId,
      allowTeleport, debugOverlay (Config.Testing), debug = DebugData|false, prompt = { invites }|false })
      (App passes `debug` to DebugOverlay; the geometry stays in Lua)
    * the invitation toast (client:testInvite)

  Client actions (CP.Tablet.registerClientAction, NUI 'client' endpoint)
    testControl { control, target?, enabled? } -> forwards to server:test:control (teleport and debug are
                                                 handled locally as below)
    teleport    { target = 'start'|'objective' } -> server returns coords; re-checks crimsonArena, then
                                                 SetEntityCoords (the vehicle when driving) with ground z
    toggleDebug { enabled? }                  -> server:test:control { control = 'debug' }
    testPanel   { open = bool }               -> take / release the panel focus
  Events handled: client:test { controls, runId, debug }, client:testInvite { inviteId, missionLabel, from,
    expiresIn }, client:inProgress / client:runEnded (HUD flag, focus), crimsonArena state bag (local player).
```

## Crimson-Police/modules/testing/server.lua

```text

 modules/testing/server.lua · CP.Testing (server): Admin test mode.

  Owns
    Test runs (SPEC "Admin test mode"): any mission (built-in, custom published or archived, turned off in
    Config.DisabledMissions, or a Mission Builder draft), a chosen location (index or random, skipping
    reserved spots) and tier (Standard..Critical whatever the number of testers), the start route off by
    default (Config.Testing.useStartRoute). A test goes through CP.Runs.create({ test = {...} }), so scaling,
    NPCs, objectives, alert suppression, real calls, downed handling and cleanup are those of a real run;
    CP.Runs writes no row, pays nothing and starts no cooldown for it, and cooldowns, the hourly cap, the
    server caps and the Cross-Department lock are never checked here. The location is still reserved.
    Tester invitations (up to Config.Testing.maxTesters - 1 on-duty officers or admins, who accept on their
    own screen), the test controls of the admin who started the test (skip, restart, pause/resume, force
    complete/fail, end, teleport, debug stream), the test log (cp_mission_tests with def_hash, migration
    002) and the catalog view with "Changed since test". Every test start is audited.

  Flow: invite first, then Start. The admin invites testers for a mission (server:test:invite); each
  invitee gets client:testInvite and accepts on their own screen (server:testRespond); the admin's Testing
  screen shows who accepted and starts the test with the accepted testers (server:admin:startTest). CP.Runs
  cannot add participants to a run after create, so nobody joins a test once it has started.

  Public API (server, docs/ARCHITECTURE.md §5.27)
    CP.Testing.start(adminSrc, opts) -> ok, data|errKey
        opts = { missionId, location = index|'random'|nil, tier = name|'auto'|nil, useStartRoute = bool|nil,
                 testers = { src, ... } }   testers must have accepted an invitation of this admin for this
        mission. data = { runId, missionId, locationIndex, tier, testers }
    CP.Testing.startDraft(src, def, opts) -> ok, data|errKey, reason
        Mission Builder test of a draft (test.draft = true). def = the draft in mission-file units (what
        CP.Missions.normalize accepts; normalised here). opts = { tier, location, useStartRoute, testers }.
        The recorded result goes to CP.Builder.onDraftTested(missionId, version, tierName, passed, src, defHash).
    CP.Testing.command(src, args) -> ok, data|errKey
        /CrimsonPoliceAdmin test <missionId> [tier] [location] (args = the words after 'test'; tier and
        location in either order); testers = the accepted invitations for that mission.
    CP.Testing.resolveMission(missionId) -> def|nil, errKey
        the definition a test of missionId would use: CP.Missions.get (built-in, custom, turned off), else the
        archived custom mission (CP.Builder.getArchived, or the archived file). Used by /CrimsonPoliceAdmin test.
    CP.Testing.invite(adminSrc, targets, opts) -> ok, { lobby, skipped = { { src, error } } }|errKey
        opts = { missionId, missionLabel? (drafts), draft? }
    CP.Testing.cancelInvites(adminSrc) -> ok, lobby
    CP.Testing.respond(src, { inviteId, accepted }) -> ok, data|errKey
    CP.Testing.control(src, payload) -> ok, data|errKey     payload = { control, runId?, target?, enabled? }
        control skip | restart | pause | resume | complete | fail | end | teleport | debug
    CP.Testing.record(src, { missionId, location, tier?, result, note? }) -> ok, data|errKey
    CP.Testing.list() -> TestsView                             (callback admin:getTests)
    CP.Testing.candidates(src) -> { TestCandidate, ... }
    CP.Testing.state(src) -> TestState
    CP.Testing.pendingInvites(src) -> { TestInvite, ... }
    CP.Testing.onRunEnded(run, state, endReason)               (hook from CP.Runs, test runs only)
  Net
    callbacks admin:getTests (testRun) · test:state (testRun or builderEdit: own data only) · test:candidates (testRun) ·
              test:pendingInvites (anyone: their own invitations)
    actions   server:admin:startTest { missionId, location, tier, useStartRoute, testers } (testRun)
              server:admin:recordTest { missionId, location, tier, result, note } (testRun; builderEdit for a
              draft test) and its alias server:test:record (for the Supervisor UI builder)
              server:test:control { control, ... } (only the admin who started the test)
              server:test:invite { missionId, targets } · server:test:cancelInvites {} (testRun)
              server:testRespond { inviteId, accepted } (the invitee; accept gated by CP.Alerts.inArena)
    events sent  client:testInvite { inviteId, missionLabel, from, expiresIn } ·
                 client:test { controls, runId, debug = false|DebugData }
    pushes   'test' { state = true } (the admin's test state changed) · 'invites' { test = true }
  Response shapes: docs/notes/testing.md and web/src/types/testing.ts.
```

## Crimson-Police/modules/units/client.lua

```text

modules/units/client.lua · CP.Units (client): the invite cue.

Units live on the server (modules/units/server.lua). The Unit screen (NUI) lists members, invites
and the invite picker, and every answer goes through the tablet (server:unitRespond). This half only
makes an incoming invite noticeable while the tablet is closed: the server's toast
(CP.Tablet.notify 'unit.invite_received', rendered by modules/tablet) is paired with a short frontend
sound when the 'unit' push for this player carries { invited = true }. Nothing is created in the game
world, so there is nothing to clean up on resource stop.

Public API (client)
  CP.Units.lastInviteAt() -> GetGameTimer() of the last invite cue, or nil
Events handled: crimson-police:client:push (topic 'unit' only; the tablet module forwards every push
to the NUI itself, this handler never touches the NUI).
```

## Crimson-Police/modules/units/server.lua

```text

modules/units/server.lua · CP.Units (server): units of 2-4 officers from any department.

Owns: unit membership (in memory only; nothing is stored), invites and their expiry, the unit
leader and leader succession, the invite lock while the unit's run is active, the Unit screen data
(callback getUnit, UnitView §9.4) and the live 'unit' push topic. SPEC "Mission types, draw & teams"
→ Units: build the unit first, any department, up to Config.Limits.maxUnitSize, invitees accept on
their own tablet, whoever sends the first invite leads, the longest-standing member takes over when
the leader leaves, a unit left with one member dissolves, invites close when the leader accepts a type
(CP.Draw calls lock), and leaving the unit mid-run abandons that run (end reason quit).

Invites stay open for INVITE_TTL = 120 seconds (below), then expire on their own.

Public API (docs/ARCHITECTURE.md §5.16)
  CP.Units.unitOf(src) -> unit|nil
      unit = { id, leader, members = { src... } (join order: longest-standing first),
               invites = { [targetSrc] = expiresAtTs }, locked = bool,
               info = { [src] = { name, callsign, rank, departmentShort, department } },
               inviteFrom = { [targetSrc] = { src, name, callsign, departmentShort } }, lockedAt, createdAt }
      Treat it as read-only. A unit that only has its leader and pending invites is "forming".
  CP.Units.members(src) -> { src... }        the unit's members, or { src } for a solo officer
  CP.Units.isLeader(src) -> boolean          true for the leader, and for a solo officer (leads themselves)
  CP.Units.lock(unit|unitId)                 (hook, CP.Draw at accept) closes invites: pending invites are
                                             withdrawn; a forming unit (one member) dissolves
  CP.Units.unlock(unit|unitId)               (hook, CP.Runs when the run ends / CP.Draw when the accept
                                             fails) reopens invites. Ignored while a member is still an
                                             active participant of a normal (not operation, not test) run.
  CP.Units.remove(src, opts) -> boolean      takes src out of its unit and cancels every invite sent to src;
                                             never touches runs. opts = { reason = 'left'|'disconnected'|'lost'|'moved', silent }
  CP.Units.view(src) -> UnitView (§9.4) plus the slice fields documented below
Net (CP.Net)
  action   server:unitInvite (targetSrc | { targetSrc })          -> { unitId, expiresIn }
           an in-arena inviter gets err.in_arena, an in-arena target err.unit_target_unavailable
  action   server:unitRespond ({ accepted, unitId } | boolean)    -> { unitId|nil, accepted }
           a bare boolean answers the newest invite; accepting refuses in-arena players (err.in_arena)
  action   server:unitLeave ()                                     -> { left = true, abandoned = bool }
  callback getUnit -> UnitView
Pushes: topic 'unit' ({ unitId|false, invited? }; invited = true only on the push that delivers a new
invite) to every member and every invitee on each change,
topic 'board' to members (the board depends on the unit size). Toasts via CP.Tablet.notify.
Listeners: playerDropped, CP.Qbx.onPlayerUnload (character switch) and CP.Access.onLost (off duty,
job change, suspended) take the player out of their unit and cancel invites to them; the run itself is
handled by CP.Runs (disconnected / off_duty / job_change / suspended).

UnitView extras (this slice, see docs/notes/teams.md):
  me (the viewer's src), maxSize, inviteTtl (seconds), canInvite, inviteBlocked (locale key|nil), onRun,
  unit.size, unit.pending = { { src, name, callsign, departmentShort, expiresIn } },
  members[].available (false when that member is no longer an on-duty officer),
  invites[].size (members in that unit), invitable[].inUnit (already in another, non-full unit).

Safety net: a unit locked for more than LOCK_GRACE seconds while none of its members is on a normal
run is unlocked by the 2 s sweep (covers an engine that never called unlock).
```

## Crimson-Police/shared/init.lua

```text

shared/init.lua · the CP namespace, logging, the block registry and RegisterMission().
Loaded on both sides before every module. Only definitions live here: nothing in this
file calls another module.
```

## Crimson-Police/shared/locale.lua

```text

shared/locale.lua · loads locales/<Config.Locale>.json (falls back to en.json).
All player-facing text lives in locales/en.json as a flat map of dotted keys, e.g.
  "board.server_busy": "Server busy"
Placeholders use {name}: CP.L('run.ended_real_call') / CP.L('cash.paid', { amount = 250 })
```

## Crimson-Police/shared/net.lua

```text

shared/net.lua · the request/action plumbing between the NUI, the client and the server.

Two kinds of server entry points, both registered through CP.Net so every one gets
rate limiting, error handling and a uniform reply shape { ok, data, error }:

  CP.Net.callback('getBoard', function(src, args) return data end)
      -> ox_lib callback 'crimson-police:getBoard'. Return data, or nil, 'error_key'.

  CP.Net.action('server:acceptType', function(src, payload) return true, data end)
      -> net event 'crimson-police:server:acceptType' (payload, reqId). Return
         ok (boolean) and data (on success) or an error locale key (on failure).
         When the client passed a reqId it receives 'crimson-police:client:actionResult'.

On the client, CP.Net.request(name, args, timeoutMs) and CP.Net.action(name, payload, timeoutMs) call them and
wait for the reply; the tablet's NUI bridge (modules/tablet/client.lua) forwards the UI's
'request' and 'action' NUI callbacks to these two functions.
```

## Crimson-Police/web/build-stamp.mjs

```text

Writes dist/build-stamp.json after `vite build`: a sha256 over every input of the NUI bundle
(web/src/**, web/index.html, the build config and locales/parts/*.json: ui.json is the fallback text and
src/mocks/samples.ts bundles every part). tools/check_contracts.py recomputes the same hash and fails when
web/dist was not rebuilt after a source change (the shipped UI must be the reviewed source). Keep both
algorithms identical: files sorted by their path relative to Crimson-Police/ (posix), hashed as path \0 bytes \0.
```

## Crimson-Police/web/src/admin/screens/Audit.tsx

```text

Admin UI · Audit Log (screen key 'admin_audit').
Every supervisor and admin action (cp_audit), newest first, filterable by category, action, actor and
date range, 50 per page. Export shows the filtered rows as CSV in a dialog with a copy button.
Data: callbacks admin:getAudit { category, action, actor, from, to, page } and admin:exportAudit (modules/admin).
```

## Crimson-Police/web/src/admin/screens/Departments.tsx

```text

Admin UI · Departments (screen key 'admin_departments').
Each department in Config.Departments: name, tag, jobs, colours, logo thumbnail (hidden when it fails to
load), member count, officers on duty and the society balance (only when Config.Cash.source = 'society').
"Preview theme" renders a read-only mini tablet in that department's colours.
Data: callback admin:getDepartments (modules/admin).
```

## Crimson-Police/web/src/admin/screens/Leaderboards.tsx

```text

Admin UI · Leaderboards (screen key 'admin_leaderboards', callback admin:getBoards).
Every board and period with the full ranked list (real names, hidden-name marker, cash paid per officer),
officers still below the minimum, and the payments left in 'paying' after a crash (with the
Renewed-Banking transaction id to check). Row actions: open the officer's runs in this board and void
one (server:admin:voidRun { rowId, reason }), award points (server:admin:awardPoints
{ citizenid, points, reason }); both are implemented by modules/admin.
Flagged runs panel (SPEC Supervisor & admin actions, "Approve or void a flagged run ... Admin UI →
Leaderboards"): callback admin:getFlagged (the admin's own runs are left out), each row Approve / Void with
a required reason -> server:admin:reviewFlagged { rowId, decision: 'approve'|'void', reason }.
```

## Crimson-Police/web/src/admin/screens/Missions.tsx

```text

Admin UI · Missions (screen key 'admin_missions', title key 'ui.screen.admin_missions').

Tabs
  Catalog           every built-in and custom mission: version, Lua file path, "edited in code", edit lock and
                    status. Built-in missions are read-only and can only be turned off in config
                    (Config.DisabledMissions, shown read-only); custom ones can be built, have tested drafts
                    published, be archived, restored or rolled back, and have an edit lock broken. Built-ins can
                    be duplicated into the builder. Launch (Cross-Department) per eligible mission.
  Builder           the Mission Builder (src/builder, scope 'admin': admins can do every builder action)
  Cross-Department  <OperationPanel scope="admin" /> (launch, start now, relaunch, cancel) and the eligible
                    missions with their Launch buttons
Data: callbacks admin:getMissions (every loaded mission: `enabled`, `crossDeptEligible`, filePath, editedInCode,
disabledInConfig) and builder:list (custom rows incl. drafts and archived, file path, edited in code, lock, can.*). Actions: server:builder:publish / archive /
restore / rollback / breakLock / duplicate, server:admin:reloadMissions (summary dialog), server:admin:opLaunch
{ missionId }. Pushes 'builder' and 'operation' refresh the lists.
```

## Crimson-Police/web/src/admin/screens/Officers.tsx

```text

Admin UI · Officers (screen key 'admin_officers').
Search any officer (name, callsign or citizen id); the record shows rank, callsign, department, XP level,
badges, cash earned, recent runs, the Crimson-Police suspension and their disputes (failed runs; flagged
or voided runs too while the supervisors' handleDisputes switch is off, and open ones no online
supervisor can answer: every online supervisor of the run's departments took part, or none is online).
Actions: suspend (days + reason) / unsuspend, answer a failed-run dispute with a manual award or dismiss
it, approve or reject a flagged/voided-run dispute (no award points: approving restores the run), void a
run from the history. The server re-checks every action (admin only).
Data: callbacks admin:searchOfficers { query } and admin:getOfficer { citizenid } · actions
server:admin:suspend { citizenid, days, reason }, server:admin:handleDispute { disputeId, decision, reason,
awardPoints } (awardPoints only for failed runs), server:admin:voidRun { rowId, reason } (modules/admin,
modules/disputes).
```

## Crimson-Police/web/src/admin/screens/Payouts.tsx

```text

Admin UI · Payouts (screen key 'admin_payouts', title key 'ui.screen.admin_payouts').
Tabs Types / Missions: every mission type and every mission with its base payout and where it comes
from; admin payouts are marked "Admin · permanent". Set (NumberInput within Config.Cash limits + reason,
with a review of old → new) or clear (confirm dialog with a reason) a type or mission payout.
Data: callback 'admin:getPayouts' (AdminPayoutsView, src/types/economy.ts), push topic 'payouts';
writes: 'server:admin:setTypePayout' { type, amount|null, reason, clear } and
'server:admin:setMissionPayout' { missionId, amount|null, reason, clear }.
```

## Crimson-Police/web/src/admin/screens/Permissions.tsx

```text

Admin UI · Permissions (screen key 'admin_permissions').
A read-only view of Config.Permissions: which supervisor actions are switched on, the actions supervisors
always have, and the actions that are always admin-only. Changes are made in config/config.lua.
Data: callback admin:getPermissions (modules/admin).
```

## Crimson-Police/web/src/admin/screens/Seasons.tsx

```text

Admin UI · Seasons & Challenge (screen key 'admin_seasons', callback admin:getSeasons, actions
server:admin:startSeason { name }, server:admin:endSeason, server:admin:overrideBounty { objective }).
Current season card, department standings, this week's bounty with the override select, bounty history
and the list of seasons with their champions. Starting a season ends the running one first; ending and
overriding ask for confirmation.
```

## Crimson-Police/web/src/admin/screens/Testing.tsx

```text

Admin UI · Testing (screen key 'admin_testing'). SPEC "Admin test mode".

Data: request 'admin:getTests' (TestsView: every mission × location with its last result),
      request 'test:state' (TestState: my invitation lobby, my running test, ended tests waiting for a
      result, invitations waiting for me), request 'test:candidates' (on-duty officers and admins).
Actions: server:test:invite { missionId, targets } · server:test:cancelInvites · server:testRespond
      { inviteId, accepted } · server:admin:startTest { missionId, location, tier, useStartRoute, testers }
      · server:admin:recordTest { missionId, location, tier, result, note }.
Client actions (Lua testing client): testControl { control } · teleport { target } · toggleDebug { enabled }.
Pushes: 'test' { state: true } and 'invites' refetch the state (debug pushes from the Lua client are ignored).
Flow: invite first, then Start — the start dialog invites testers, shows who accepted, and starts with them.
```

## Crimson-Police/web/src/builder/BlockPanels.tsx

```text

src/builder/BlockPanels.tsx · one settings panel per objective block (SPEC "Mission Builder → Block settings"),
generated from the builder:config ranges (config/blocks.lua): every number shows its min, max and default and
refuses values outside them; selects offer only the allowed lists (Config.Builder.allowed); chances are whole
percent and progress times seconds (builder units, protocol §1.1). Field paths follow ARCHITECTURE §3.3.
```

## Crimson-Police/web/src/builder/BuilderEditor.tsx

```text

src/builder/BuilderEditor.tsx · the Mission Builder editor for one mission: header (name, lifecycle, version,
autosave state, running armed-NPC total vs Config.Builder.maxHostiles, Save / Close), the edit lock banner
(who holds it and until when; Break lock when allowed), the step bar New mission → Details → Block settings →
Locations → Scaling → Test → Publish with error counts per step, and the step content.
```

## Crimson-Police/web/src/builder/LocationMap.tsx

```text

src/builder/LocationMap.tsx · a schematic map (SVG, north up, metres) of one location: the start and its radius,
the spawn keep-out circle (Config.Builder.minSpawnFromStart), every placed point per key, recorded routes with
stop points, waypoints a test drive did not reach, waypoints with no road path and rejected "off road" samples,
and the no-build zones nearby. No map tiles: the NUI must work offline.
```

## Crimson-Police/web/src/builder/MissionList.tsx

```text

src/builder/MissionList.tsx · the Mission Builder's mission list: drafts, tested drafts, published and archived
custom missions (builder:list) with status, version, owner and edit lock, plus the built-ins to duplicate.
Actions (server:builder:*): create, duplicate, archive, restore, rollback, breakLock, discardDraft — each gated
by session.actions (builderEdit / builderArchive / builderRollback / breakEditLock) AND the entry's `can` flags
from the server; destructive ones ask for confirmation.
```

## Crimson-Police/web/src/builder/applyResult.ts

```text

src/builder/applyResult.ts · writes a builder client result (docs/notes/builder_protocol.md §6) into the
draft: placed points into definition.locations[location - 1][key] (a single vector for single-point keys,
a list otherwise, one more list for flee paths, { coords, radius } for the start), a recorded road route
{ points, stops?, loop? }, and the route meta (length, rejected samples, unreachable / failed waypoints)
that the Locations step shows but the definition never stores.
```

## Crimson-Police/web/src/builder/index.ts

```text

src/builder · the Mission Builder component library (Supervisor UI → Mission Builder, Admin UI → Missions).
  BuilderWorkspace  mission list + editor (the whole builder)
  MissionList       drafts, tested, published and archived custom missions with status, version and lock
  BuilderEditor     the step editor of one mission
Protocol: docs/notes/builder_protocol.md · notes: docs/notes/builder_client.md.
```

## Crimson-Police/web/src/builder/schema.ts

```text

src/builder/schema.ts · the Mission Builder's knowledge of the nine objective blocks: defaults of a new
objective in builder units (from builder:config = config/blocks.lua), the location keys each objective needs
and how they are placed (mirrors every block's requiredPoints and strict location checks), the armed NPC
count (mirrors every block's armedCount), the counts that can scale, and ranges read from the config.
Field names follow ARCHITECTURE §3.3 and the "Objective fields read" headers of blocks/<id>/server.lua.
```

## Crimson-Police/web/src/builder/steps/StepDetails.tsx

```text

src/builder/steps/StepDetails.tsx · "Details": name, description, mission type (required), difficulty stars,
min/max officers, time limit, start timeout, cooldown, "Available to" departments (none = every department),
the vehicle-damage penalties toggle with its suggestion, optional items and the standard bonuses and
penalties (Config.Bonuses) with their caps. There is no payout field.
```

## Crimson-Police/web/src/builder/steps/StepLocations.tsx

```text

src/builder/steps/StepLocations.tsx · "Locations": at least Config.Builder.minLocations locations, each with
its start and every point its objectives need. "Place in world" starts the placement tool (client action
builderPlace: the tablet closes, the points come back when Enter is pressed); road routes are recorded by
driving (builderRecord) and checked with a test drive (builderTestDrive), which marks waypoints it could not
reach for re-recording. The map shows everything placed; the route checks mirror the server's guardrails.
```

## Crimson-Police/web/src/builder/steps/StepPublish.tsx

```text

src/builder/steps/StepPublish.tsx · "Publish": enabled only when the draft passes every guardrail
(server:builder:validate with the publish checks), has a passed test at the required tier (draft_tested),
the editor holds the lock and may publish. Publishing writes missions/custom/<id>.lua (the previous file is
kept as a .bak) and the mission joins its type's pool at once. Discarding a draft is offered here too.
```

## Crimson-Police/web/src/builder/steps/StepTest.tsx

```text

src/builder/steps/StepTest.tsx · "Test": a private test run of the stored draft at any tier and location, in
the same test mode admins use (server:builder:test → CP.Testing.startDraft; nothing is saved or paid). The
tier defaults to the one maxOfficers reaches, which publishing needs a pass at (draft_tested). When the run
ends, the tester records Passed or Failed here (server:test:record → CP.Builder.onDraftTested).
```

## Crimson-Police/web/src/builder/store.ts

```text

src/builder/store.ts · module-level memory of the Mission Builder.

A placement, route recording or test drive closes the tablet (modules/builder/client.lua), which unmounts
every screen. What the editor needs afterwards lives here, outside React: the open mission and step per
UI scope, the unsaved local draft, the running tool, route meta (length, rejected samples, marked
waypoints), the last draft test, and tool results. Results are captured from the NUI push topic 'builder'
(event 'clientResult') by a window listener installed when this module loads, even while the tablet is
closed; the editor also pulls the Lua copy with the client action builderResult (both deduplicated by seq).
```

## Crimson-Police/web/src/builder/useBuilderConfig.ts

```text

src/builder/useBuilderConfig.ts · builder:config (Config.Blocks ranges, allowed lists, limits and the
caller's builder permissions), fetched once per open UI and shared by every builder component.
Lua sends an empty list as {} (and drops nil fields), so every list of the config is normalised to an array
here once; the components can then use the lists directly.
```

## Crimson-Police/web/src/builder/useDraftEditor.ts

```text

src/builder/useDraftEditor.ts · one open mission in the Mission Builder (docs/notes/builder_protocol.md §2–§6).

  builder:get { id }            → the record; an editable custom mission is locked with server:builder:lock
  server:builder:autosave       → every Config.Builder.autosaveSeconds while the lock is mine and the draft
                                  changed (also before a tool closes the tablet and after a tool result)
  server:builder:save           → explicit save (errors, previousId after a rename of a never-published draft)
  server:builder:validate       → live guardrails (debounced, publish checks included)
  server:builder:unlock         → when the editor is closed
  client actions builderPlace / builderRecord / builderTestDrive (+ builderResult on mount)
  push 'builder'                → lockBroken / tested / published / … for this mission refetch or go read-only
The unsaved draft is kept in the module store (store.ts), so closing the tablet for a tool loses nothing.
```

## Crimson-Police/web/src/hud/BuilderOverlay.tsx

```text

Mission Builder in-world overlays: the placement tool, route recording and test drive HUDs.

Props: { overlay } — the `overlay` message payload whose kind is 'placement' | 'recording' | 'testdrive',
sent by modules/builder/client.lua every ~150 ms while a tool runs (shapes: src/types/builder_client.ts).
Rendered full-screen by App while such an overlay is set; the tablet is closed at that time, there is no NUI
focus (the keys are game controls read by the Lua tool), so this panel is display-only.
  placement  what is being placed, count placed / needed / max, valid or invalid spot with the reason,
             heading or radius, key hints E / Scroll / Backspace / Enter
  recording  REC or PAUSED, length, waypoints, samples, rejected samples, off-road / no-build zone /
             too-long warnings, stop points, loop closure, waiting states, key hints E / Backspace / P / X
  testdrive  waypoint progress, time left to the current waypoint, stop countdown, waypoints marked for
             re-recording, approach / spawn states, key hint X
```

## Crimson-Police/web/src/hud/DebugOverlay.tsx

```text

Test-mode overlay layer: the debug overlay (live NPC/entity counts against the caps) and the test
invitation prompt.

Props: { debug, hud }
  debug — the `debug` field of the last `push` message with topic 'test' (the data of
          crimson-police:client:test { controls, debug }), passed through untouched; null/false = hidden.
          Shape: TestDebugData (src/types/testing.ts). A `hud.debug` field is read as a fallback.
  hud   — the current HudState or null.
Rendered by App at all times (outside the tablet, no NUI focus); returns null when there is nothing to show.
The in-world markers (spawn points, zones, route waypoints, start radius) are drawn by the Lua testing
client; this panel shows the numbers.
Invitation prompt: when the Lua testing client opens it (the panel key with invitations waiting) it gives NUI focus
and pushes 'test' { prompt: { invites } }; Accept/Decline call action server:testRespond { inviteId, accepted },
Escape / Close release the focus (client action testPanel { open: false }). Escape also releases a focus
the Lua client holds for the HUD panel while no panel is on screen (safety net).
```

## Crimson-Police/web/src/hud/Hud.tsx

```text
The mission HUD (ARCHITECTURE §9.3): shown at the right edge while hud is set, without NUI focus.
The timer and the off-route countdown count down locally; they restart only when Lua sends a new
value (Lua sends the full merged state on every patch, so an unchanged value keeps counting), and
count from the time that value arrived (normalizeHud), so a remount does not replay elapsed time.
```

## Crimson-Police/web/src/hud/HudColumn.tsx

```text

The right-edge column that holds the mission HUD and the result card (no NUI focus).
Centred vertically and scaled with the viewport (useHudScale), but never taller than the screen:
when the HUD and a long result card are shown together (or on 720p) the column scales down to fit,
since the player cannot scroll a HUD without focus.
```

## Crimson-Police/web/src/hud/TestControls.tsx

```text

HUD test controls (Admin test mode, SPEC "Test controls").

Props: { hud: HudState } — rendered by <Hud/> under the objectives only when hud.testControls is true
(the admin who started the test). The HUD has no NUI focus by default: the Lua testing client
(modules/testing/client.lua) gives focus with the +crimsonpolice_testpanel key (default F7) and tells
this panel through push 'test' { focused, key, debugOn } (TestPush), kept at module level so a panel that
mounts again shows the last values at once. While focused, that key or Escape
releases the cursor (client action testPanel { open: false }).
The same push carries Config.Testing's allowTeleport / debugOverlay: those buttons are disabled when off.
Buttons call client actions of the Lua testing client:
  testControl { control: 'skip' | 'restart' | 'pause' | 'resume' | 'complete' | 'fail' | 'end' }
  teleport { target: 'start' | 'objective' } · toggleDebug { enabled }
(the client forwards them to server:test:control). Force complete / Force fail / End test ask first.
Text keys: locales/parts/testing.json (test.*).
```

## Crimson-Police/web/src/mocks/DevPanel.tsx

```text

Browser dev mode only (App lazy-loads this file when isEnvBrowser(); it never runs in FiveM).
Fakes the Lua side: opens the three UIs, sends HUD states, results, toasts and overlays.
URL params for quick checks: ?ui=officer|supervisor|admin &dept=sast|fib|bcso &screen=<key>
  &hud=progress|offroute|test &result=completed|failed|test|flagged &run=1 &toast=info &bg=night|day|none &dev=0
Dev tool text is English on purpose: it is never shown to players.
```

## Crimson-Police/web/src/mocks/boards.mock.ts

```text

Browser mocks for the boards slice (Leaderboard, Department Challenge, Profile & History, Admin Seasons &
Challenge, Admin Leaderboards, Supervisor Department Report). Shapes follow modules/leaderboard and
modules/challenge (see their header comments and src/types/boards.ts). Actions keep a little state so
the screens can be clicked through: hide-name, disputes, season start/end, bounty override, void, award.
server:dispute, server:admin:voidRun and server:admin:awardPoints belong to other modules: registered as
fallbacks so their owners' mocks win.
```

## Crimson-Police/web/src/mocks/builder_client.mock.ts

```text

Browser mocks for the builder client slice (modules/builder/client.lua and the builder screens).

Client actions builderPlace / builderRecord / builderTestDrive play the whole in-game flow: the reply is
{ started: true }, then the tablet closes (message 'close'), the tool HUD overlay animates for a few seconds,
the result is kept for builderResult and pushed (topic 'builder', event 'clientResult'), the overlay hides and
the tablet reopens on the UI the tool was started from (payload.ui). builderCancel / builderWaypoint answer
like the Lua client. Also: server:test:record (recording a draft test result), server:admin:reloadMissions
(summary), and fallbacks for builder:list / builder:get / builder:config, every server:builder:* action,
getMissionList, admin:getMissions (built from getMissionList) and server:admin:opLaunch — builder_server.mock.ts, oversight.mock.ts and teams.mock.ts register
the full versions, which win over these fallbacks.

URL shortcuts (dev only):
  &bopen=<missionId>&bstep=blocks|details|settings|locations|scaling|test|publish&bloc=<n>&bobj=<n>
       open that mission in the builder (Supervisor: scope sup; Admin: Missions → Builder tab)
  &bov=placement|placement_bad|recording|recording_wait|testdrive   show a static tool overlay
  &blua=1   tool results in Lua shape (empty lists as {}), as builder_server.mock.ts does for the server
```

## Crimson-Police/web/src/mocks/builder_server.mock.ts

```text

Browser mocks for the Mission Builder server (modules/builder/server.lua, docs/notes/builder_protocol.md):
callbacks builder:list / builder:get / builder:config and every server:builder:* action, with an
in-memory store so create → save → test → publish → archive → restore → rollback can be clicked
through. The builder client's client actions (builderPlace, builderRecord, builderTestDrive,
builderResult, builderCancel, builderWaypoint) are registered as fallbacks: the builder client's own
mock file overrides them. Use ?ui=admin to get admin permissions (rollback, break lock, edit any).
Review switches: &blua=1 answers like Lua does (empty lists as {}, nil fields left out), &bedge=1 adds
edge-case missions (very long names, unknown names, an empty new draft) and no no-build zones, &bempty=1
starts with no custom missions at all.
```

## Crimson-Police/web/src/mocks/economy.mock.ts

```text

Browser-mode mocks for the economy slice: getHome, sup:getPayouts, admin:getPayouts and the three
payout actions. State is kept in memory so a change on one screen shows on the others.
URL switch for screenshots: ?economy=empty (no goals / no Type of the Day / no announcements, a fresh
officer), ?economy=lua (the same empties the way Lua encodes them: {} / [] for empty tables, keys of nil
values missing, no callsign), ?economy=edge (long names and labels, huge numbers, top XP level, a
config multiplier of 1.5) or ?economy=error (every economy request fails with err.internal).
```

## Crimson-Police/web/src/mocks/index.ts

```text

src/mocks/index.ts · browser dev mode only (main.tsx imports this only when isEnvBrowser()).
Eagerly loads every src/mocks/*.mock.ts, so a feature adds mocks by dropping in <feature>.mock.ts:
  import { registerMock } from '../shared/nui';
  registerMock('request', 'getBoard', (args) => ({ ... }));
  registerMock('action', 'server:acceptType', (type) => { if (type === 'tactical') throw new Error('err.server_busy'); return true; });
```

## Crimson-Police/web/src/mocks/run_ui.mock.ts

```text

Browser mocks of the run_ui slice (Mission Board + Active Mission): getMissionTypes, getRun (overrides
core.mock.ts's fallback), server:acceptType, server:joinOperation, server:abandon and the client actions
setGps, recalcRoute and logResult. Lua side effects are faked the way the game does them: 'board' /
'operation' / 'run' pushes, the route toasts from modules/route, the run.accepted toast and the result card.

URL variants (screenshots and manual checks):
  ?board=normal (default) | unit | member | locked | busy | oncall | boss | bossused
         | operation | opjoined | oprunning | opwaiting | opclosed | empty | error | edge
  ?runv=none | accepted | offroute | progress | test | log | silence | boss | untracked | edge
         (default: none, or progress while the dev panel's "run" toggle / ?run=1 is on)
  &oncall=1 puts the viewer (or, in a unit, someone in it) on a real call with any board variant.
'edge' answers the way Lua's JSON encoding really arrives: empty lists as {} objects, nil fields
missing (undefined, not null), no optional extras, very long names and labels, missing callsigns.
A type accepted in browser mode starts a simulated run: accepted → In progress after ~10 s → the
objectives advance every few seconds → completed (result card). Abandon puts the type on cooldown.
```

## Crimson-Police/web/src/mocks/teams.mock.ts

```text

Browser mocks of the teams slice: getUnit + unit actions, sup:getOperation + operation actions.
URL variants for screenshots and checks:
  ?teams=leader (default) | member | solo | invites | locked | lockedoff | long | full   the Unit screen
  ?op=joining (default) | running | waiting | none | cooldown | empty | fresh   the Cross-Department panel
  &lua=1   answer like Lua does: empty lists arrive as {} objects and nil fields are missing keys
```

## Crimson-Police/web/src/mocks/testing.mock.ts

```text

Browser mocks for Admin test mode (admin/screens/Testing.tsx, hud/TestControls.tsx, hud/DebugOverlay.tsx).
URL shortcuts (with ?ui=admin&screen=admin_testing for the screen, ?hud=test for the HUD):
  testactive=1  a running test of mine        testdebug=1  debug overlay data (push 'test')
  testfocus=1   the HUD panel has NUI focus   testprompt=1 the invitation prompt
  testinvite=0  no invitation banner for me    testempty=1  an empty test log (everything "Not tested")
  testlong=1    edge cases: very long mission/location/player names and notes, a mission without locations
  testlua=1     Lua-shaped replies: empty lists sent as {} objects, false for missing values
```

## Crimson-Police/web/src/officer/screens/ActiveMission.tsx

```text

Officer UI · Active Mission (screen key 'active', title key 'ui.screen.active') · run_ui slice.

The officer's current run: mission label and description (revealed only now, after the accept), state
(Accepted / In progress), tier (marked "expected" until In progress) and the pay tier when it is lower,
the modifier, the start-route status (on route, off route with its countdown, arrived, or off for test
runs) with Set GPS and Recalculate route (limited per run, remaining shown), the objective checklist
with progress and details, the run timer counting down locally (paused state), partners with department
tag, callsign and status, the expected cash and points, the TEST RUN banner, the Radio Silence note, the
Business Check log panel (view.log) and Abandon behind a confirm dialog. Empty state when no run.

Data:    request 'getRun' → ActiveMissionView | null (ARCHITECTURE §9.4; optional extras in
         src/types/run_ui.ts), live via push topic 'run' (the view is applied as it is; nil — the run
         ended — arrives as a missing field and triggers a getRun), plus a 15 s safety poll.
Actions: 'server:abandon' (payload = runId) · client actions 'setGps', 'recalcRoute' and
         'logResult' { point, choice } (the route and log toasts come from Lua; errors are toasted here).
Text:    locales/parts/run_ui.json (run.*), plus the foundation's hud.* / common.* / tier.* keys.
```

## Crimson-Police/web/src/officer/screens/Challenge.tsx

```text

Officer UI · Department Challenge (screen key 'challenge', callbacks getChallenge + getDeptContributors).
One score bar per department in its own theme colour, the season and weeks left, this week's bounty with
the department currently leading it, and the viewer's department's top 5 contributors. Tapping a
department opens its full contributor list. DeptBars and BountyCard are reused by the Admin Seasons
screen and the Supervisor Department Report.
```

## Crimson-Police/web/src/officer/screens/Home.tsx

```text

Officer UI · Home (screen key 'home', title key 'ui.screen.home').
Officer card (callsign, rank, department tag, XP level badge and XP bar, streak with this week's grace
day, season points, cash earned this week), today's and this week's goal, the Type of the Day in the
accent colour, announcements and the season champions banner. Data: callback 'getHome' (HomeData,
ARCHITECTURE §9.4, typeOfTheDay extras in src/types/economy.ts), refreshed when the run ends (push 'run'
with no data) and every minute.
```

## Crimson-Police/web/src/officer/screens/Leaderboard.tsx

```text

Officer UI · Leaderboard (screen key 'leaderboard', callback getBoard).
Tabs Weekly · Monthly · Season · All-time, filter chips (Overall, the mission types, Unit, Cross-Department,
Department + department select), the top 25 with medals for 1–3 and the viewer's own row pinned at the
bottom (highlighted when it is also in the list). Tapping an officer opens their public profile.
Cash is never shown here. All-time ranks lifetime XP with the Overall filter only.
```

## Crimson-Police/web/src/officer/screens/MissionBoard.tsx

```text

Officer UI · Mission Board (screen key 'board', title key 'ui.screen.board') · run_ui slice.

One card per mission type (label, points, cash per officer as a range "$1,040–$1,300", missions in the
pool, Solo/Unit, Type of the Day tag, locked reason with the cooldown countdown, "Server busy", "On a
call"), the Weekly Boss card when the server sends it, and — while a Cross-Department Mission is active —
only that operation's card (Join / joined state / join countdown). A unit summary line tells who picks
the type. Officers only ever pick a TYPE: the board never lists or previews individual missions (the
Weekly Boss and the operation are the spec's exceptions), and there is no reroll.

Data:    request 'getMissionTypes' → BoardData (ARCHITECTURE §9.4; extras in src/types/run_ui.ts),
         refetched (one coalesced call per burst) on push topics 'board' and 'operation', on 'run' when the
         active run starts or ends, every 30 s, and when a cooldown or the join window ends.
Actions: 'server:acceptType' (payload = the type key, or 'weekly_boss' for the boss card) after a
         confirm dialog, then navigate('active'); 'server:joinOperation' (payload = operation id).
Text:    locales/parts/run_ui.json (board.*); locked reasons arrive translated from the server.
```

## Crimson-Police/web/src/officer/screens/Profile.tsx

```text

Officer UI · Profile & History (screen key 'profile', callback getProfile, actions server:setHideName and
server:dispute). Own profile by default; navigate('profile', { citizenid }) opens someone's public
profile (no cash, no cash breakdown, no toggle, no disputes). Shows the XP level badge and bar, badges,
the hide-name toggle, and the last 20 runs with how each ended; a row opens the points/cash breakdown in
the same presentation as the HUD result card; flagged, voided or failed runs from the dispute window can
be disputed (reason required).
```

## Crimson-Police/web/src/officer/screens/Unit.tsx

```text

Officer UI · Unit (screen key 'unit', title key 'ui.screen.unit').
The officer's unit (members with department tag, rank and callsign, the leader marked), invites
waiting for them (Accept / Decline), an invite picker of on-duty officers from any department, and
Leave unit (confirm; mid-run it abandons the unit's run). Data: callback getUnit (UnitView + slice
fields, src/types/teams.ts), live via push topic 'unit'. Actions: server:unitInvite (targetSrc),
server:unitRespond ({ accepted, unitId }), server:unitLeave. Test invitations (callback test:pendingInvites,
push 'invites') are answered here too with server:testRespond. Invites close (locked) once the leader
accepts a mission type and stay closed while the unit's run is active.
```

## Crimson-Police/web/src/shared/hooks.ts

```text

src/shared/hooks.ts · data hooks for screens.

  const { data, loading, error, refetch } = useRequest<Board>('getBoard', { period, filter }, { pushTopic: 'board' });
  const { run, busy } = useAction();  await run('server:acceptType', 'patrol');
  const left = useCountdown(view?.remaining ?? null, { paused: view?.paused });
  usePush('unit', () => refetch());
```

## Crimson-Police/web/src/shared/i18n.tsx

```text

src/shared/i18n.tsx · UI text (docs/ARCHITECTURE.md §10).

Text comes from session.locale (CP.Locale.all(), i.e. locales/en.json). Keys are flat and dotted;
placeholders use {var}:   t('hud.objective_progress', { value: 12, max: 20 })
An unknown key renders the key itself, so a missing string is visible instead of blank.

The foundation's own part (locales/parts/ui.json) is bundled as a last-resort fallback so the HUD,
result card and toasts stay readable even before the first session arrives. Session text always wins.
```

## Crimson-Police/web/src/shared/navigation.tsx

```text

src/shared/navigation.tsx · the state-based screen switch (no router).
  const navigate = useNavigate();  navigate('board');
  navigate('profile', { citizenid: row.citizenid });   const { params } = useNavigation();
Keys outside the open UI (or hidden by permissions) are ignored with a console warning.
```

## Crimson-Police/web/src/shared/nui.ts

```text

src/shared/nui.ts · the NUI bridge (docs/ARCHITECTURE.md §9.1).

  Lua → NUI: window 'message' events whose data.type is one of
             open | close | session | notify | hud | result | push | overlay | theme
  NUI → Lua: POST https://<resource>/<endpoint> with a JSON body, endpoints
             ready | close | request | action | client | switchUi

In a normal browser (isEnvBrowser()) nothing is POSTed: request/action/client calls are answered
by mocks registered with registerMock() (see src/mocks/*.mock.ts), and emitDebug() fakes Lua
messages. Every call resolves (never rejects) to { ok, data?, error? } where error is an err.* key.
```

## Crimson-Police/web/src/shared/session.tsx

```text

src/shared/session.tsx · the open UI's session (ARCHITECTURE §9.2) and tablet controls.
  const session = useSession();            // Session (inside Officer/Supervisor/Admin UIs)
  const can = useCan(); can('forceRecall') // session.actions contains it
  const { close, switchUi } = useTablet();
```

## Crimson-Police/web/src/shared/theme.ts

```text

src/shared/theme.ts · department theming (SPEC "Departments & tablet theming").

applyTheme(el, theme) writes these CSS variables on `el` (everything inside inherits them):
  --cp-primary --cp-accent --cp-bg --cp-surface --cp-text          the five theme colours
  --cp-surface-2 --cp-surface-3                                     raised / hovered surfaces
  --cp-border --cp-border-strong                                    hairlines and outlines
  --cp-muted --cp-subtle                                            secondary and faint text
  --cp-primary-contrast --cp-accent-contrast                        text drawn ON primary / accent
  --cp-primary-hover --cp-primary-text --cp-accent-text             hover fill; primary/accent legible on bg
  --cp-primary-rgb --cp-accent-rgb --cp-bg-rgb --cp-surface-rgb --cp-text-rgb   "r, g, b" for rgba()
Colours must be 6-digit hex (#1f4e8c); anything else falls back per key to the Crimson-Police
default (text falls back to the best contrast for the background, as CP.U.contrastText does).
```

## Crimson-Police/web/src/supervisor/components/OperationPanel.tsx

```text

Supervisor/Admin UI · OperationPanel: the active Cross-Department Mission and its controls.

  import OperationPanel from '../../supervisor/components/OperationPanel';
  <OperationPanel scope="admin" />      // Admin UI → Missions
  <OperationPanel scope="sup" />        // Supervisor UI → Cross-Department Mission

Props (stable): { scope: 'sup' | 'admin' } picks the action family server:<scope>:opLaunch / opStart /
opRelaunch / opCancel. Data: callback sup:getOperation (OperationView, src/types/teams.ts), refreshed by
the push topic 'operation' and every 10 s. Shows the mission, launcher, status, tier, join / run / idle
timers, participants by department, and Start now / Relaunch (after a fail) / Cancel (reason required).
With no operation active it offers a launch form (missions open to every department that support 2+
officers; never the Weekly Boss) with the server-wide launch cooldown.
```

## Crimson-Police/web/src/supervisor/screens/Builder.tsx

```text

Supervisor UI · Mission Builder (screen key 'sup_builder', title key 'ui.screen.sup_builder').
The supervisor's drafts plus the published and archived custom missions (builder:list), and the step editor
(src/builder). Actions follow session.actions: builderEdit (build, record routes, test their own missions),
builderPublish, builderArchive, builderEditAny (other people's missions), builderRollback, breakEditLock —
the server re-checks every one (docs/notes/builder_protocol.md §2). Placement, route recording and test
drives close the tablet (modules/builder/client.lua) and reopen it here when they end.
```

## Crimson-Police/web/src/supervisor/screens/CrossDept.tsx

```text

Supervisor UI · Cross-Department Mission (screen key 'sup_crossdept', title key 'ui.screen.sup_crossdept').
The active operation (mission, launcher, joined participants by department, tier, status) with Start now,
Relaunch after a fail and Cancel, or the launch form when none is active. Everything lives in the
reusable OperationPanel (also used by the Admin UI → Missions screen); this screen uses the supervisor
actions server:sup:op*. Visible with the launchCrossDept permission (screen registry).
```

## Crimson-Police/web/src/supervisor/screens/DeptReport.tsx

```text

Supervisor UI · Department Report (screen key 'sup_report', callbacks sup:getDeptReport and
sup:getOfficerActivity). The department's challenge standing, this week's bounty, and every officer
of the department who played this week (runs, completed, points, cash, last run); tapping an officer
opens their runs of this week. Supervisors only see their own department (the server enforces it).
```

## Crimson-Police/web/src/supervisor/screens/LiveMissions.tsx

```text

Supervisor UI · Live Missions (screen key 'sup_live').
Runs involving the supervisor's department: participants, mission type, drawn mission, tier and time
left (counting down locally). Force recall ends one officer's run as Abandoned with no cooldown.
Data: callback sup:getLiveRuns (modules/admin, polled every 10 s) · action server:sup:forceRecall { runId, src, reason }.
```

## Crimson-Police/web/src/supervisor/screens/MissionList.tsx

```text

Supervisor UI · Mission List (screen key 'sup_missions').
Every mission by name, built-in and custom: type, difficulty, officers supported, current base payout
(and where it comes from), cooldown and who is running it now. Missions open to every department that
support 2+ officers (never the Weekly Boss) can be launched as a Cross-Department Mission.
Data: callback getMissionList (modules/admin) · action server:sup:opLaunch { missionId } (modules/operations).
```

## Crimson-Police/web/src/supervisor/screens/Payouts.tsx

```text

Supervisor UI · Payouts (screen key 'sup_payouts', title key 'ui.screen.sup_payouts').
Per mission type: current payout, config default, the supervisor's allowed range, "Set by admin"
(read-only), the cooldown before it can change again, and a change dialog (NumberInput clamped to the
range + a required reason). Single-mission payouts are never shown here.
Data: callback 'sup:getPayouts' (SupPayoutsView, src/types/economy.ts), push topic 'payouts';
write: action 'server:sup:setTypePayout' { type, amount, reason }.
```

## Crimson-Police/web/src/supervisor/screens/ReviewQueue.tsx

```text

Supervisor UI · Review Queue (screen key 'sup_review').
Tabs Flagged runs / Disputes: flagged runs involving the supervisor's department with the reason
(e.g. outside help) and who, and disputes about flagged or voided runs. Their own runs never appear.
Approve, void or reject, always with a reason; every decision is final and audited.
Data: callback sup:getReviewQueue · actions server:sup:reviewFlagged { rowId, decision, reason } and
server:sup:handleDispute { disputeId, decision, reason } (modules/admin, modules/disputes).
```

## Crimson-Police/web/src/types/boards.ts

```text

src/types/boards.ts · shapes of the boards slice (modules/leaderboard, modules/challenge).
The §9.4 contract types live in shared/types.ts; the interfaces here extend them with the optional
fields the Lua modules add (documented in their header comments and docs/notes/boards.md), plus the
supervisor/admin shapes the contract leaves to the module owner (§9.5).
```

## Crimson-Police/web/src/types/builder_client.ts

```text

src/types/builder_client.ts · shapes of the builder client slice: the in-world tool overlays sent by
modules/builder/client.lua (CP.Tablet.overlay kinds 'placement' | 'recording' | 'testdrive'), the fields the
builder client and screens add to the client protocol of docs/notes/builder_protocol.md §6, and the editor's
UI-side helper types (steps, point specs). The server shapes are in ./builder_server.ts.
```

## Crimson-Police/web/src/types/builder_server.ts

```text

src/types/builder_server.ts · Mission Builder protocol shapes (docs/notes/builder_protocol.md).
Server: modules/builder/server.lua (CP.Builder). Callbacks builder:list / builder:get / builder:config,
actions server:builder:*, NUI push topic 'builder', client actions builderPlace / builderRecord /
builderTestDrive / builderResult / builderCancel / builderWaypoint (modules/builder/client.lua).

Units in a BuilderDefinition: seconds, metres, km/h; chances are WHOLE PERCENT (0–100) and progress
times are SECONDS (see BuilderConfig.percentFields / secondsFields). The server converts them to
fractions and milliseconds only when it writes the Lua file.
```

## Crimson-Police/web/src/types/economy.ts

```text

src/types/economy.ts · response shapes of the economy slice's supervisor/admin callbacks and actions
(modules/payouts/server.lua; documented in docs/notes/economy.md). HomeData and Goal are contract
shapes and live in src/shared/types.ts.
```

## Crimson-Police/web/src/types/run_ui.ts

```text

src/types/run_ui.ts · response shapes of the run_ui slice (Mission Board and Active Mission screens,
documented in docs/notes/run_ui.md). BoardData and ActiveMissionView are contract shapes
(src/shared/types.ts, ARCHITECTURE §9.4); the types below only add the optional fields the server
sends (or may send) on top of them. Every extra field is optional: the screens work without them.
```

## Crimson-Police/web/src/types/testing.ts

```text

src/types/testing.ts · Admin test mode shapes (modules/testing/server.lua, docs/notes/testing.md).
Lua sends `false` for "no value" (a Lua table cannot hold nil) and may encode an empty list as {}:
read every list through asList().
```

## tests/boards_spec.lua

```text

tests/boards_spec.lua · the boards slice: CP.Leaderboard (modules/leaderboard) and CP.Challenge
(modules/challenge). Pure ranking/calendar logic plus every SQL statement of both modules, run against
MariaDB cp_test through the harness (boards, profiles, hide-name, admin boards, stuck payments, the
weekly job and announcements; seasons, bounties, standings in all three scoring modes, week closing,
overrides, season end, champion banner, supervisor report and officer activity).
```

## tests/builder_client_spec.lua

```text

tests/builder_client_spec.lua · the builder_client slice: modules/builder/client.lua (CP.Builder, client side).
Pure logic: the route recorder (snapping cadence is the runner's; waypoints at turns and every maxGap, duplicates,
undo, stop points), the placement spot checks, the client-action payload parsers, driving styles, thinning and
headings. Runtime against stubbed natives: the async start / result protocol of builder_protocol.md §6, the
refusals (Crimson-Arena rule 13, busy, dead, on a run, disabled), a placement run, a route recording run
(off-road rejection, road-surface acceptance, undo and return, stop points, unreachable waypoints), a test drive
(local entities, stop waits, a waypoint marked failed after testDriveTimeout, cleanup), cancellation, the builder
events, character unload and resource stop.
The builder_client slice writes no SQL, so this spec runs no queries.
```

## tests/builder_server_spec.lua

```text

tests/builder_server_spec.lua · modules/builder/server.lua (slice builder_server).

Covers the guardrails, unit conversion, the Lua export (golden text of the spec's custom example and a
round trip through the RegisterMission sandbox), versions, edit locks and every SQL statement of the
module on MariaDB, archive/restore/rollback files and the reload (hand edit) conflict logic.
Mission files are written to a temporary folder missions/custom/test_builder_<n>/ that is removed at
the end, whatever happens. The spec uses its own database (<run database>_builder_server).
```

## tests/e2e_spec.lua

```text

tests/e2e_spec.lua · end-to-end scenarios on the REAL server side of Crimson-Police.

Every modules/**/server.lua and blocks/**/server.lua is loaded (in the fxmanifest's glob order) together with
the real mission files (CP.Missions.loadAll through LoadResourceFile). Only these are stubbed:
  * FiveM / OneSync natives (entities, peds, vehicles, state bags; players are simulated through H.players),
  * the exports of qbx_core, sc-dispatch, sc-ambulance, Renewed-Banking and ox_inventory.
Runs are driven by firing the real net events and callbacks the clients / NUI would send.
Scenarios:
  1. solo Beat Patrol: acceptType -> route arrival -> checkpoint evidence -> completed row, points = formula,
     cash paid once through the claim flow with a Renewed-Banking record, leaderboard row after invalidate
  2. SAST + FIB unit Gang Shootout at Reinforced: a partner leaving by quit (pay tier drops) and by
     real_call (pay tier kept, no cooldown)
  3. real calls: an npccall- id does nothing, a real id ends only that participant, an un-mark within 60 s
     -> real_call_cancelled + type cooldown
  4. downed with no EMS -> failed row, NPC pick-up, flag cleared, never hospital:server:RevivePlayer
  5. Cross-Department Mission: launch locks every board and refuses other accepts, join, start, complete lifts
  6. admin test run: no row, no cooldown
  7. flagged run (outside help) holds cash, supervisor approve pays, own-run review refused
  8. supervisor payout limits and the admin lock
  9. resource stop: entities deleted, nothing written (plus the dispatch backstop, outside help and executor
     events on that run first)
Extra paths on the same stack: 2c presence share, 3b real call before the start / after 60 s / solo run already
  over, 4b downed in a unit with EMS on duty, 5b idle joiner + cancel of a running operation, 5c operation
  waiting -> relaunch -> idle auto-cancel, 7b approval while offline (pending, paid at login), 7c void ->
  dispute -> restored, 10 off duty / disconnect / off route.
Threads created while the files load are deferred until every file has loaded (FiveM's CreateThread runs a new
thread on the next scheduler tick; the harness would run it at once).
Own database (<run database>_e2e, rebuilt from sql/migrations; mdt_dispatch from tests/fixtures/core).
```

## tests/economy_spec.lua

```text

tests/economy_spec.lua · modules/scoring, goals, cash, payouts (slice economy).

Other modules are stubbed (CP.Qbx, CP.Access, CP.Missions, CP.Draw, CP.Banking, CP.Tablet, CP.Admin,
CP.Events, CP.AntiCheat, CP.Challenge); modules/permissions, scaling and schedule are the real ones.
Every SQL statement of the slice runs against MariaDB. The spec uses its own database
(<run database>_economy, rebuilt from sql/migrations like cp_test) so other specs that reset cp_test in
parallel cannot interfere. The fake clock is aligned with the database clock (NOW()).
```

## tests/engine_a_spec.lua

```text

tests/engine_a_spec.lua · modules/missions, draw, scaling, schedule, events (slice engine_a).

Mission files are served from memory through a LoadResourceFile override, other modules are
stubbed, and every SQL statement of the slice runs against MariaDB. The spec uses its own
database (<run database>_engine_a, rebuilt from sql/migrations) so parallel runs of other specs that
reset cp_test cannot interfere.
```

## tests/fixtures/engine_b/client_spec.lua

```text

tests/fixtures/engine_b/client_spec.lua · the client half of the run engine (modules/runs/client.lua).
Run in its own process by tests/engine_b_spec.lua (the harness boots one side per process); prints
"RESULT <passes> <failures>" on the last line.
```

## tests/fixtures/npc/client_check.lua

```text

tests/fixtures/npc/client_check.lua · the client half of modules/npc in its own Lua state
(H.boot side = 'client'). Run by tests/npc_spec.lua as a child process; prints "RESULT <passed> <failed>".
Natives the checks do not model are recorded by a fallback (every capitalised global that is not
defined becomes a recorder), so the checks can assert on the calls the module makes.
```

## tests/harness.lua

```text

tests/harness.lua · a tiny FiveM/Qbox stand-in for unit tests (not shipped with the resource).

  local H = dofile('tests/harness.lua')
  H.boot({ side = 'server' })            -- Config, CP shared layer, native stubs, MySQL -> MariaDB
  H.load('modules/scaling/server.lua')   -- any resource file, path relative to Crimson-Police/
  H.eq(CP.Scaling.tierFor(3).tier, 'heavy')

MySQL.* runs real queries against the local MariaDB database `cp_test` through the mysql CLI
(schema from sql/migrations). Use H.sql('DELETE FROM cp_mission_runs') to reset tables. The server is the one
`mysql -uroot` reaches: the local socket, or MYSQL_HOST / MYSQL_TCP_PORT / MYSQL_PWD (docs/TESTING.md). One
mysql client stays open per spec (CP_TEST_MYSQL=spawn: one per call), and every statement runs with
SET timestamp = os.time(), so NOW() is the spec's clock (H.time after H.boot) in every storage mode.
CP_TEST_NOW=<unix time> moves the default H.time, CP_TEST_CLOCK=<unix time> the wall clock (os.time() and NOW()).
CP_SQL_LOG=<file> (or <dir>/) logs every MySQL call as JSON lines (see "optional SQL log" below).
Storage modes (CP_TEST_STORAGE, H.storage; tests/run.lua --storage=... sets it for every spec):
  database (default)  as above: MySQL and H.sql go to MariaDB.
  files               database-off mode: H.boot sets Config.Database.enabled = false and loads the real
                      modules/storage files, so every module query goes through CP.Storage.MemSQL and a temporary
                      saves folder (H.savesDir(), built by the real migrations runner on the engine in
                      H.resetDatabase / H.resetSaves). H.sql goes to the same engine; statements that name only
                      other resources' tables (mdt_dispatch) go to MariaDB, as the real oxmysql would serve them.
  shadow              the specs run exactly as in database mode (they get the MariaDB answers), and every
                      MySQL call and H.sql statement also runs, in lockstep, on a MariaDB twin database read
                      through mysql2 the way oxmysql reads it (tests/shadow/twin.cjs) and on the saves folder
                      engine through its MySQL drop-in. Both start from the migrated empty schema (the real
                      migrations runner). Every difference in result, error, affected rows, insert id or
                      value type is appended to CP_SHADOW_REPORT (see "shadow mode" below).
H.bit(v) reads a TINYINT(1) value in any mode. H.skipIn(mode, reason) skips a MariaDB-only check.
Threads: CreateThread runs the function as a coroutine immediately; Wait(ms) advances the fake
clock and yields; H.step() resumes sleeping threads. Citizen.Await works on resolved promises.
```

## tests/int_core_spec.lua

```text

tests/int_core_spec.lua · integration of the core group (integrations, access, permissions, tablet) with
the modules that call it: CP.Banking.depositSociety (CP.Cash's society refund), the live-run own-run check
of CP.Permissions.canReviewRun, the session tier labels from CP.Scaling.label, and on the client the one
NUI path of the mission HUD / result screen (modules/runs/client.lua -> CP.Tablet -> SendNUIMessage),
the HUD kept off screen while Crimson-Arena owns the player (CRIMSON_ARENA rule 8) and the panel focus
helper CP.Tablet.panelFocus that modules/testing's test-control panel needs.
```

## tests/int_duplicates_spec.lua

```text

tests/int_duplicates_spec.lua · every built-in mission can be duplicated into a custom mission that passes the
Mission Builder guardrails and can be published after its test.

The REAL loader (CP.Missions.loadAll at start: missions/builtin/index.lua and every built-in file), the REAL
blocks and the REAL builder (modules/builder/server.lua) on MariaDB; stubs only for access, qbx, admin audit,
tablet pushes and CP.Testing.startDraft (the test run itself is modules/testing's job). For each of the 14
built-ins:
  * server:builder:duplicate (B.sanitize, the standard-bonus filter and B.customBonusFields) gives a draft
    whose record has no guardrail errors;
  * B.validate(draft, { publish = true }) (every builder guardrail, the blocks' validate() as a custom mission
    and CP.Missions.normalize) finds nothing; server:builder:save and server:builder:validate agree;
  * server:builder:test at the required tier, a passed result (B.onDraftTested) and server:builder:publish
    write missions/custom/<id>.lua, which CP.Missions registers as a custom mission.
Also: a search_area mission's start radius follows the search circle (Config.Blocks.search_area.startRadius)
instead of the 20-150 m start-marker limit, and a mission without one keeps that limit.
Mission files are written to a temporary folder missions/custom/test_dup_<n>/ that is removed at the end.
```

## tests/int_engine_spec.lua

```text

tests/int_engine_spec.lua · integration of the engine group: the REAL modules missions, draw, scaling,
schedule, events, runs and npc with every REAL block, on the REAL built-in mission files, with stubs only for
the modules outside the group (access, qbx, alerts, route, payouts, scoring, cash, anticheat, tablet ...).
It checks the cross-module paths the slice notes and the integration list asked for:
  * the real loader (CP.Missions.loadAll at start, LoadResourceFile of every missions/builtin file) loads all 14
    built-in missions: the loader sets def.source before the blocks' validate, so a built-in file is exempt from
    the Mission Builder's model lists (Prison Break's inmates and the Kingpin's boss model are in those lists
    now, so copies of them can be published; a model outside the lists passes only in a built-in file)
  * CP.Runs.create reserves the location through the real CP.Draw (test runs too, CP.Runs.get returns them),
    rolls the modifier through the real CP.Events after the seed / type / boss / test / operation are set,
    and releases the reservation when the run ends
  * server:acceptType -> draw -> create -> server:abandon: the cooldowns() shape the board and the accept read
  * Bomb Disposal: the device prop found by interact_points (objective 1) is kept by the engine when that
    objective completes and defused by skill_check (objective 2) without being re-created; every hook of an
    objective gets the same ctx.state; everything goes at the run end
  * Warrant Service, every location: the suspect waiting on the door step surrenders 1 m in front of the door
    (never behind the facade), through the real engine, CP.Npc and flee_arrest; a kill goes CP.Npc ->
    CP.Runs.entityDied -> the block, once
```

## tests/int_services_spec.lua

```text

tests/int_services_spec.lua · integration of the services group: the REAL modules scoring, goals, cash, payouts,
leaderboard, challenge, admin, disputes and anticheat running together (plus the real permissions, scaling and
schedule), on stubs of CP.Qbx, CP.Access, CP.Tablet, CP.Banking, CP.Missions and CP.Runs.
It checks the cross-module paths the slice notes asked for (docs/notes/economy.md, boards.md, oversight.md,
testing.md): approve/void ordering against the real XP / cash / board hooks, disputes forfeiting and restoring,
goal and manual_award rows (season, department, board refresh), admin:getStuckPayments, reasons counted in
characters across admin -> scoring and in payouts, the Profile's canDispute = CP.Disputes.eligible, badge labels
of leaderboard badges in CP.Scoring.badges, and /CrimsonPoliceAdmin test for archived custom missions.
Own database (<run database>_intsvc, rebuilt from sql/migrations and dropped at the end); the fake clock is
aligned with the database clock (rows are written with FROM_UNIXTIME(os.time())).
```

## tests/int_web_spec.lua

```text

tests/int_web_spec.lua · integration checks for the web group (web/src outside the Mission Builder).

Static cross-checks between the screens and the Lua that feeds them, for what the integration pass
changed or relies on:
  * Mission Board: BoardData.operation.joinBlocked (CP.Operations.boardCard) is typed, read by the
    screen, and every key the Lua can send has a text in some locale part;
  * Unit screen: test invitations (SPEC Admin test mode, "accept on their own screen") use the names
    modules/testing registers (callback test:pendingInvites, action server:testRespond { inviteId,
    accepted }, push 'invites') and the TestInvite fields the Lua returns; every literal key exists;
  * a nil push ('run' with no data) arrives as a missing field: the RunBar, Home, Mission Board and
    Active Mission treat undefined like null;
  * Home styles both announcement kinds modules/leaderboard sends (weekly_top3, monthly_top3);
  * lists from Lua ({} for an empty table): the touched screens wrap them (asArray / asList);
  * theme: primary/accent text colours reach WCAG AA (4.5:1) on the surface, checked with a Lua port of
    web/src/shared/theme.ts on the configured department themes (FIB's navy primary was 3.2:1).
```

## tests/memsql_spec.lua

```text

tests/memsql_spec.lua · CP.Storage.MemSQL (modules/storage/memsql.lua): the saves folder engine behind database-off
mode (Config.Database.enabled = false) and CP.Storage (modules/storage/server.lua).
  1. constructs: every SQL construct family of the inventory, run in order through the MySQL drop-in. The
     expected values were produced by running the very same statements, in the same order, on MariaDB 10.11
     through mysql2 3.22 with oxmysql's options, typeCast and parseResponse (the clock pinned with
     SET timestamp to the value os.time() has here), and are hard-coded below. Cases marked tz depend on the
     time zone and only run when the server zone is UTC, as it was when they were recorded.
  2. persistence: a new engine on the same saves folder has identical tables; AUTO_INCREMENT continues
  3. the saves folder layout: one document per table, one row per line, JSON embedded, _tables.json
  4. split documents (id ranges and hash buckets); a save rewrites only the documents it changed
  5. crash safety: a crash at every file operation of a save (POSIX and Windows rename rules)
  6. atomicity: a failing statement (or a failing disk) changes nothing
  7. the MySQL drop-in: return shapes, errors, callbacks, ready, other resources' tables
  8. CP.Storage and the migrations runner in files mode
  9. details a review found: MariaDB's collation table, PAD SPACE order, integer overflow, DATE across time zones,
     exact BIGINT / DECIMAL, additive ALTER TABLE, AUTO_INCREMENT after UPDATE, FXServer's inverted os.rename,
     a refused file operation at every point of a save, hand-edited, reformatted and missing documents
Needs no database (9.1 compares with the local MariaDB when it runs); every saves folder lives in a temporary
folder removed at the end.
```

## tests/missions_a_spec.lua

```text

tests/missions_a_spec.lua · the missions_a built-in mission files and missions/builtin/index.lua.
  lua5.4 tests/run.lua missions_a
Each file is loaded exactly as modules/missions loads it (LoadResourceFile + a sandbox whose only
globals are RegisterMission, vec3/vec4/vector3/vector4, math, string, table, pairs, ipairs, type,
tonumber, tostring) and checked against the spec's catalog, its mission card, ARCHITECTURE 3.3 and
the Mission Builder guardrails. When the objective blocks it uses exist, the definition also goes
through CP.Missions.normalize (block defaults + validate) with no warnings.
```

## tests/missions_b_spec.lua

```text

tests/missions_b_spec.lua · slice missions_b: the built-in mission files warrant_service, manhunt,
gang_shootout, hostage_rescue, bomb_disposal, armored_truck_escort, prison_break and
weekly_boss_kingpin. Each file is run in the mission loader's sandbox and checked against the
mission catalog, its mission card, ARCHITECTURE §3.3 (objective fields, location keys) and the
built-in guardrails (location count and spacing, map bounds, no-build zones for points and route
segments, 30 m from the start, points of a location kept together, heights, headings facing the
approach, spawn counts, contiguous road / escape / flee routes, the armed-NPC budget, bonus ids, no
payout field). The objectives are then run through
the real blocks' defaults/validate (for the blocks that exist) and through CP.Missions.normalize.
Run it on its own to see the report lines (sizes, route lengths, nearest distances):
  cd /home/user/PoliceTablet && lua5.4 tests/run.lua missions_b
```

## tests/npc_spec.lua

```text

tests/npc_spec.lua · slice npc: modules/npc/server.lua driven through a fake entity world, stubbed
CP.Runs / CP.AntiCheat / CP.Tablet / CP.Alerts / CP.Access, the harness clock (the 1 s watcher runs
as a harness thread) and simulated net events. The client half is checked in a separate Lua state
(tests/fixtures/npc/client_check.lua, side = 'client'); its results are added here.
The npc slice writes no SQL, so this spec runs no queries.
```

## tests/oversight_spec.lua

```text

tests/oversight_spec.lua · the oversight slice: modules/admin (audit, webhooks, /CrimsonPoliceAdmin,
review and void, force recall, supervisor/admin callbacks), modules/disputes and modules/anticheat.
The real CP.Access and CP.Permissions modules run on a CP.Qbx stub; every other module is a stub that
records its calls. Every SQL statement of the three modules runs here against MariaDB cp_test.
```

## tests/run.lua

```text

tests/run.lua · runs every tests/*_spec.lua in a fresh Lua state and prints a summary.
  lua5.4 tests/run.lua                    (all specs)
  lua5.4 tests/run.lua boards             (only specs whose file name contains "boards")
  lua5.4 tests/run.lua --storage=files    (database off: every spec on the saves folder engine; = CP_TEST_STORAGE=files)
  lua5.4 tests/run.lua --storage=shadow   (MariaDB answers; every statement is also compared on an oxmysql twin and
                                           the engine, 0 differences expected; = CP_TEST_STORAGE=shadow)
  lua5.4 tests/run.lua --fuzz[=N]         (shadow mode on tests/shadow/fuzz_*.lua, random SQL, seeds 1..N, default 3)
  lua5.4 tests/run.lua --jobs=N           (N specs at a time, each on a copy of the run database; = CP_TEST_JOBS=N;
                                           default 2; --jobs=1: one after another on the run database itself)
The filter and --storage combine (lua5.4 tests/run.lua --storage=files storage). New or changed SQL must pass in all
three modes (docs/ARCHITECTURE.md §5.29, §11). A filter that matches no spec is an error (exit 2).
Before the first spec the run checks lua5.4, lua-cjson, the mysql CLI and (shadow) node + mysql2 and stops with
exit 2 when one is missing; tools/setup_test_env.sh checks the whole environment (docs/TESTING.md).
Each spec file is a plain script: local H = dofile('tests/harness.lua'); H.boot{...}; ... H.eq(...)
and must end with `return H`. Every run gets its own MariaDB database, rebuilt from sql/migrations first.
Storage modes (tests/harness.lua has the details):
  database  (default) MySQL and H.sql go to MariaDB.
  files     Config.Database.enabled = false: everything goes to the saves folder engine (CP.Storage.MemSQL); the
            run's saves folders live in one temporary folder that is removed at the end (in database mode each
            spec gets its own subfolder of it).
  shadow    the specs run as in database mode, and every statement also runs in lockstep on a MariaDB twin
            (read the way oxmysql reads it, tests/shadow/twin.cjs) and on the saves folder engine; every
            difference is appended to CP_SHADOW_REPORT (default /tmp/cp_shadow_<run database>.jsonl),
            summarised at the end (the file is kept only when it holds a difference). Needs node and
            tests/shadow/node_modules (cd tests/shadow && npm install).
A check skipped in a mode (H.skipIn) prints a SKIP line; every skip is listed at the end. A spec's REPORT lines
(timings and sizes of tests/storage_spec.lua and tests/storage_copy_spec.lua) are shown under its result.
Results print in file order whatever --jobs is, and the counts do not depend on it.
For hunting order, clock and time zone effects (docs/TESTING.md):
  CP_TEST_ORDER=reverse | shuffle[:seed]  another spec order (with --jobs=1 also the order they run in)
  CP_TEST_NOW=<unix time>                 the harness' default fake clock H.time (1790000000 otherwise)
  CP_TEST_CLOCK=<unix time>               the wall clock itself: os.time() and MariaDB NOW() start there
  CP_TEST_TZ=<zone>                       the specs' TZ (UTC otherwise; shadow mode always runs UTC)
```

## tests/run_ui_spec.lua

```text

tests/run_ui_spec.lua · run_ui slice (Officer Mission Board + Active Mission screens, UI only).

The slice has no Lua and writes no SQL; this spec checks what the UI relies on from the Lua side and
the slice's own files:
  * locales/parts/run_ui.json: flat object of non-empty strings, only board.* / run.* keys, no key
    redefined from ui.json, identical text for keys other parts share, well-formed {var} placeholders,
    loads through shared/locale.lua (CP.L interpolation) like locales/en.json in game;
  * every literal t('…') / tOr('…') key in the two screens exists (own part or ui.json), and every key
    of the part is used by a screen (no dead text);
  * every err.* key the browser mocks answer with, and every key they translate, exists in some part;
  * the screens use exactly the contract names (ARCHITECTURE §8/§9.4) for requests, actions, client
    actions and push topics, keep a default export with no props, and never list individual missions;
  * the Lua producers really send what the screens read: CP.Runs.view (every ActiveMissionView field of
    web/src/shared/types.ts plus the extras), participants/objectives/expected/modifier/route shapes,
    CP.Route.status statuses, the setGps/recalcRoute/logResult client actions and their payloads, the
    interact_points log state, CP.Draw.boardCards / CP.Events.bossCard (every BoardCard / BoardData
    field), CP.Operations.boardCard (the §9.4 fields and extras, every active status handled), the
    callbacks/actions registered by their owners and the 'board' pushes the board listens to;
  * the slice CSS uses only --cp-* variables (no hex colours, no color-mix/:has), and every rule is
    scoped by a run_ui- class;
  * no SQL / MySQL anywhere in the slice files (nothing to run on MariaDB).
```

## tests/safety_spec.lua

```text

tests/safety_spec.lua · modules/route, calls, alerts, downed (slice safety: Hard rules 15-18).

CP.Runs, CP.Dispatch, CP.Ambulance, CP.Qbx, CP.Tablet and CP.Admin are stubbed; the four server
modules run together with their real 1 s / 2 s loops on the harness clock (H.step / H.advance).
The state bag is simulated: every write goes through bagSet, which fires the registered
AddStateBagChangeHandler handlers before the value changes (as FiveM does). At the end the two client
files are loaded in their own environment (a separate CP table) with stubbed natives.
No database is used.
```

## tests/shadow/fuzz_agg.lua

```text

tests/shadow/fuzz_agg.lua · random aggregate queries, compared in shadow mode (lua5.4 tests/run.lua --fuzz): SUM /
COUNT / MAX / MIN over CASE, AND / OR / NOT, IN lists, IS NULL, column and parameter comparisons (integer, DECIMAL,
DATETIME and case / accent / trailing-space variants of text), GROUP BY one to three columns (NULLs included), and
SUBSTRING_INDEX(GROUP_CONCAT(... ORDER BY ...), ',', 1) with NULL and tied keys. FUZZ_SEED picks the data and queries,
FUZZ_N how many. GROUP BY uses a text column without case variants: grouping by a text whose rows differ in case
shows an arbitrary member on MariaDB (it depends on the plan), which nothing can match.
```

## tests/shadow/fuzz_funcs.lua

```text

tests/shadow/fuzz_funcs.lua · random expressions, compared in shadow mode (lua5.4 tests/run.lua --fuzz): arithmetic on
INT / DECIMAL / DOUBLE / text, comparisons across types, CASE / IF / COALESCE / NULLIF / GREATEST / ROUND, the JSON
functions on a breakdown-like document, date functions (DATE_FORMAT, DATE, UNIX_TIMESTAMP, FROM_UNIXTIME,
TIMESTAMPDIFF, INTERVAL), text functions, DISTINCT, derived tables with UNION ALL, correlated subqueries, and
stores into typed columns (strict mode and IGNORE: too long, out of range, wrong type, NULL into NOT NULL, ENUM, bad
JSON, warnings and notes).
FUZZ_SEED picks the data and statements, FUZZ_N how many.
```

## tests/shadow/fuzz_rows.lua

```text

tests/shadow/fuzz_rows.lua · random row queries and writes, compared in shadow mode (lua5.4 tests/run.lua --fuzz):
SELECT with WHERE, ORDER BY (with the id as the last key: rows tied on every key come back in an order MariaDB
does not define), LIMIT / OFFSET, LEFT JOIN, IN / EXISTS subqueries and expressions; UPDATE, DELETE,
INSERT IGNORE ... SELECT (ordered), INSERT ... ON DUPLICATE KEY UPDATE, UNIQUE conflicts and AUTO_INCREMENT.
FUZZ_SEED picks the data and statements, FUZZ_N how many. An UPDATE that fails on a UNIQUE key reports the first
conflicting row in the order MariaDB's plan reads the rows (index or table order): that error text can differ.
```

## tests/shadow/fuzz_store.lua

```text

tests/shadow/fuzz_store.lua · storing values into typed columns, compared in shadow mode (lua5.4 tests/run.lua --fuzz):
every column type Crimson-Police uses (INT, TINYINT, TINYINT(1), SMALLINT, DECIMAL, VARCHAR, ENUM, DATETIME, DATE,
JSON, NOT NULL with and without a default) gets numbers, decimals, doubles, texts with and without a number in
them, dates in MariaDB's many spellings, JSON, booleans and NULL, through INSERT and UPDATE, in strict mode and
with IGNORE: the stored value, the error, and the warnings and notes (warningStatus, "Rows matched ... Warnings")
are compared. Then rows of several values at once: CHECK (JSON_VALID) failures with IGNORE, NULL into NOT NULL,
columns left out without a default, ON DUPLICATE KEY UPDATE conversions.
FUZZ_SEED 1 runs the whole grid; other seeds a random part of it and random multi-row statements.
Left out (the engine refuses them as unsupported): values MariaDB stores as a zero date or a date with a zero
month or day ('0000-00-00', 0, 300, '2026-00-01', and any bad date with IGNORE).
```

## tests/storage_copy_spec.lua

```text

tests/storage_copy_spec.lua · /CrimsonPoliceAdmin storage and storage copy (modules/admin) with MariaDB and a
temporary saves folder together.
  1. files mode (Config.Database.enabled = false; the live engine is the saves folder, MariaDB is reached through
     CP.Storage.realMySQL): the status lines; the refusals (usage, not an admin, a run or an operation active,
     oxmysql stopped, a target with rows); database-to-files into the live engine (every table and value, ids and
     AUTO_INCREMENT counters, split documents, a reload of the folder, the audit entry); force; a copy that fails
     half way leaves the target empty and the source as it was; files-to-database into an empty MariaDB database
     (the migrations create the tables there first) and back into a database with rows (force).
  2. database mode (Config.Database.enabled = true, an absolute saves folder): the status lines; files-to-database
     from an empty folder is refused; database-to-files into a new folder (built by the migrations); files-to-
     database back into MariaDB (refused without force, then replaced).
The spec picks its storage modes itself, whatever CP_TEST_STORAGE says. Values are compared as the modules read
them (DATETIME through UNIX_TIMESTAMP, DATE through DATE_FORMAT, TINYINT(1) as 0/1, DECIMAL and numeric text as
numbers: the harness' mysql CLI types every number-like text as a number). CP_COPY_RUNS sets the number of runs
(default 1203; e.g. 50000 for a timing at scale, printed as REPORT lines).
```

## tests/storage_spec.lua

```text

tests/storage_spec.lua · database off (Config.Database.enabled = false) from end to end: the saves folder holds
every feature's data, survives a restart, and stays fast and small at 50,000 runs.
  1. files mode on the REAL server side (every modules/**/server.lua and blocks/**/server.lua, as in e2e_spec):
     an admin starts a season, overrides the weekly bounty, sets a type payout and creates a custom mission; an
     officer runs a solo Beat Patrol from the Mission Board to a paid row, and the weekly board ranks them.
  2. a server restart: every handler, thread and module table is dropped, a new engine loads the same saves
     folder and the modules start again. Every cp_ table reads back identical, and the officer, the run and its
     points, the paid cash (still paid once), the season, the bounty, the payout, the custom mission, the audit
     rows and the mission cooldown all come back through the modules; AUTO_INCREMENT ids continue.
  3. load: 50,000 runs in the active season (500 officers). The leaderboard, challenge and admin stats queries
     each finish under 250 ms, the write statements of one finished run (with the documents they rewrite) take
     about 20 ms or less (and with an fsync per document written, as FXServer flushes, measured on this disk),
     loading the saves folder at start-up takes under 3 s; the size of the saves folder and its bytes per run row.
     Every timing and size is printed (CPU time, os.clock; the fsync writes in wall time).
The spec always runs in files mode (H.useFiles), whatever CP_TEST_STORAGE says. sc-dispatch's mdt_dispatch is
another resource's table: it stays on MariaDB and is read through the real oxmysql, as on a server.
```

## tests/teams_spec.lua

```text

tests/teams_spec.lua · modules/units and modules/operations (slice teams).

Other modules are stubbed (Access, Qbx, Tablet, Runs, Alerts, Calls, Permissions, Missions, Draw,
Admin); CP.Scaling is the real module. Every SQL statement of the slice runs against MariaDB. The
spec uses its own database (<run database>_teams, rebuilt from sql/migrations and dropped at the end)
so neither other specs nor a parallel run of this spec can interfere.
```
