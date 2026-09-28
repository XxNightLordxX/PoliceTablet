# blocks_b · hostile_waves, protect_rescue, flee_arrest

Files: `Crimson-Police/blocks/{hostile_waves,protect_rescue,flee_arrest}/{server,client}.lua`,
`Crimson-Police/locales/parts/blocks_b.json`, `tests/blocks_b_spec.lua` (run: `lua5.4 tests/run.lua blocks_b`).
Each file's header lists the fields it reads (with defaults), the evidence it accepts and the ids it records.

## Contract interpretations

- **ctx.rng** is stored in `ctx.state.rng` on first use, so the sequence keeps advancing even if the engine builds
  a new ctx for every hook call. Every random pick (spawn points, models, weapons, door response, armed
  inmates, routes) uses it. The only exception is the low-health surrender of hostile_waves, which calls
  `CP.Npc.rollSurrender(run, netId, chance)` (§5.11 "surrender rolls"), falling back to `ctx.rng` if that function
  is missing.
- **Validate reasons** follow blocks_a: `false, CP.L('block.<id>.invalid.<what>', vars)` (translated text, with
  field/min/max vars). Built-in missions (`mission.source == 'builtin'`) are trusted on the allowed model and weapon
  lists, the spawn-point count (1.5 × largest wave, 1 point per NPC) and the minimum distance from the start (the
  Hostage Rescue hostiles are inside a store, so they are closer than 30 m to its start). Ranges, types, the
  40-armed budget, required points and `Config.Builder.noBuildZones` are checked for every mission: every spawn
  point (waves, boss spot, hostage spots, suspects, associates, inmates), the protect_rescue safe marker, the
  flee_arrest door marker and every fleeTo / route waypoint (docs/CRIMSON_ARENA.md rule 7; the loader only sees
  location keys, not points written into an objective). Custom missions also keep the boss spot and the hostage
  spots `Config.Builder.minSpawnFromStart` away from the start, like every other spawn point.
  When `location` is nil, `validate` walks `mission.locations`.
- **Text defaults** (`knock.label`, `cuff.label`, `target.label`, `boss.label`) are filled with `CP.L(...)` text, so
  translated labels end up in the objective. A label written in a mission file wins.
- **Defaults that conflict with config/blocks.lua**: for flee_arrest scatter, `suspects` [5] and `armedShare` [0.4]
  follow §3.3 and the Prison Break card. `Config.Blocks.flee_arrest.suspects[3] = 1` and `armedChance[3] = 20` are
  treated as Mission Builder UI defaults; their ranges are still used for validation.
  Defaults with no value anywhere: `knock.duration` 3000 ms, `safeRadius` 6.0 (§3.3), boss health/armour =
  `Config.Blocks.hostile_waves.health[2]` / `armour[2]` (400 / 100, the Kingpin card), boss weapon
  `WEAPON_ASSAULTRIFLE`, the protect_rescue npcs key `'hostages'`, the associates key `'associates'`.
- **Health share** (surrender under 25 %, armed give-up under 50 %) is measured above GTA's 100-point death
  threshold: `(hp - 100) / (max - 100)`, where `max = max(configured health, GetEntityMaxHealth)`. A ped at or below
  100 is dying and never gets a roll.
- **"alive" in nextWave** means not neutralised (not dead and not cuffed); a surrendered hostile waiting for cuffs
  still counts. afterSeconds is measured from when the wave started. The next wave starts only once the current
  one is fully spawned. A wave no bigger than aliveAtMost lets the next one start straight away.
- **Boss**: spawns after the last wave by the same nextWave rule, at `boss.spawn` (or a spawn point). Its
  accuracy/armour/health are used as written (no tier, no modifier). `boss.aliveBonus = { id = 'kingpin_alive',
  points = 50 }` is an added optional field (the card's +50).
- **Spawning**: at most 8 spawns per tick (larger waves need a few ticks; the count is never cut).
  `ctx.canSpawn(1, armed)` is checked before every single spawn, so one oversized wave cannot block forever.
  Partly spawned waves are topped up to the rescaled count only. Entities that vanish with no death event count
  as dead.
- **Surrender grace**: a participant kill within 3 s of an armed ped surrendering is treated as a shot already in
  flight, not as killing a surrendered NPC. After that, killing a surrendered, cuffed, restrained or unarmed
  suspect/inmate/hostage fails the run with `run.fail_killed_unarmed`. Only kills by a participant count
  (`run.participants[src]`, which includes people who left). Outsider kills are CP.AntiCheat's job.
- **Cuffs**: `onEvent { type = 'cuffed' }` is accepted only when `CP.Npc.getState(netId) == 'cuffed'` and the
  sender is within reach. `tick` also syncs from the bag, so an event that went missing or was rejected cannot
  leave the objective stuck (the award is given once either way).
- **Timed interactions** (Cut restraints, Knock and announce) take two events: `*_start` and then the finish. Both
  are distance-checked on the server, and the finish must come at least 80 % of the duration after the start.
- **Door response** is rolled when the objective starts (so a fighting suspect spawns with its pistol and counts
  toward the armed cap) and is kept secret until the knock. A door-mode NPC dying before the knock reveals it.
  A surrendering suspect is placed 1 m outside the door with server `SetEntityCoords`, facing out.
- **Escape**: only suspects/inmates that are `fleeing` or `hostile` (never associates, idle or surrendered ones),
  more than escape.distance from every active participant, for escape.seconds in a row.
- **Armed inmates**: switch to `hostile` when a participant is within fireWithin and back to `fleeing` beyond
  1.5 × fireWithin. Exactly `round(suspects × armedShare)` are armed (2 of 5). Armed ones give up only when
  stunned or under armedGivesUp.belowHealth, which the server polls every tick (no random roll).
- **flee_arrest relationship group**: every flee_arrest NPC spawns with `cfg.group = 'neutral'`, armed or not.
  Door-mode NPCs must not open fire before the knock and armed inmates only within fireWithin; CP.Npc's combat
  task puts a ped in `CRIMSONPOLICE_HOSTILE` when the server turns it `hostile` (and apply reads the state first).
- **stunned** evidence: the reporter must be within 50 m of the suspect (clients only look within 40 m) and some
  participant within 30 m.
- **hostile_waves surrender**: besides the host's `low_health` report, `tick` checks the server-side health of
  every hostile that has not rolled yet. The report can reach the server before the damage syncs (it is then
  refused as `health_ok` and the client never re-reports), so the poll is what guarantees the one roll.
- **Spawning** in all three blocks runs under a re-entry flag that is cleared by a pcall wrapper even when a
  spawn throws, so one failed CreatePed never freezes the objective; the next tick retries.
- **Host AI** (all three clients): control is requested before every task (OneSync gives ownership to the
  closest player, usually the officer next to the ped), and a ped only counts as applied/tasked when
  `CP.Npc.apply`/`CP.Npc.task` did not return false; otherwise the next loop (500 ms) retries. Without this a
  freed hostage owned by the officer who cut its restraints never got its `follow` task.
- **Progress bars** ("Cut restraints", "Knock and announce") still running when the objective or run stops are
  cancelled (`lib.cancelProgress`) in the client cleanup. Lock-on aim (`IsPlayerTargettingEntity`) counts as
  aiming for `givesUp.aim` like free aim.
- **protect_rescue** watches its hostages for the whole run, including while objective 1 is current: deaths come
  from `onEntityDead`, damage comes from `CP.Npc.onDamaged` (server-only). `onEvent` cannot tell a CP.Npc dispatch
  from client evidence of the same shape (both arrive as `{ type = 'shot'|'damaged', netId, ... }`), so while
  onDamaged is listened to, `shot`/`damaged` events are acknowledged and change nothing (CP.Npc always calls
  onDamaged for the same hit); only without onDamaged do they count. Hits by the same attacker on the same
  hostage within 1 s count once. `no_hostage_hurt` is lost by any damage from anyone and is recorded only once
  minSeconds has passed since the objective started (a completion refused as too fast must not keep it).
  `hostage_hit` needs a participant attacker. One pending "Cut restraints" per participant: a new `free_start`
  replaces that participant's previous one.
- **presence**: hostile_waves = nearest non-neutralised hostile, else the start point; protect_rescue = nearest
  living hostage, else the safe point; flee_arrest = nearest suspect not neutralised, else the door or start.
- **HUD**: server `ctx.hud({ detail, value, max })` only when it changes. flee_arrest also sends
  `ctx.hud({ message = { text, kind = 'warning' } })` for the door response. The clients use `ctx.hudDetail`
  for personal hints (cuff nearby, stay close, escape countdown, hostages walking).
- **Traffic** (hostile_waves client, every participant, while current): `AddRoadNodeSpeedZone` +
  `SetRoadsInArea` (box around the start) + one `ClearAreaOfVehicles` in the radius. Restored in stop and on
  resource stop.

## Requests to other modules

Status after the review (modules/runs and modules/npc as written now): 1–8 are implemented there
(`opts.points` hints in `run.score.values`, `objectiveEvent` to every objective that is not stopped, `onEntityDead`/
`dispatch` for any prepared objective, block rejections only logged, `cfg.group`, `cfg.fleePoints`, translated
cuff labels, restrained kneel, no retask for `freed`). Since the review, `shot`/`damaged` events are no-ops for
protect_rescue while `onDamaged` is listened to (see above), so request 8 only needs `onDamaged` to keep firing.

1. **modules/runs**: `ctx.award` / `ctx.penalize` pass `opts.points` as the per-occurrence value for ids that are
   neither in `Config.Bonuses` nor in the mission's list: `hostage_hit` (`-hitPenalty`), `kingpin_alive`
   (`boss.aliveBonus.points`), `aliveBonus.points` (Prison Break `inmate_alive` 10). Please honour it, or
   ignore it when the mission lists the id itself.
2. **modules/runs**: send `ctx.send` updates to a client half whose objective is not current yet
   (protect_rescue spawns and sends its hostages in `prepare`). Call `onEntityDead` and `dispatch` for the owning
   objective even when it is not current (as §5.10 `entityDied` / `dispatch` say).
3. **modules/runs**: the block-level rejections I return (`duplicate`, `wrong_state`, `health_ok`, `too_far`,
   `not_started`, `too_fast`, `armed`, `unknown_entity`, `unknown_event`) are ordinary gameplay races. Please log
   them but do not flag the run on them; only `too_fast`/`too_far` may be worth counting.
4. **modules/npc**: `apply(entity, cfg)` should put `cfg.group == 'neutral'` (and any unarmed role: hostage,
   suspect, inmate) in `CRIMSONPOLICE_NEUTRAL` and armed ones in `CRIMSONPOLICE_HOSTILE`. Every spawn passes
   `cfg.group`, plus `cfg.behaviour` for hostiles.
5. **modules/npc**: task `flee` should accept `args.points` (a list of vector3) and run along them. The bag cfg
   carries `cfg.fleePoints` (a serialized list) so your own `fleeing` state-bag handler can use it too.
6. **modules/npc**: `enableCuff` may get an already-translated `label` (CP.L of an unknown key returns it unchanged).
   Please keep `duration`/`maxDistance` defaults when they are nil.
7. **modules/npc**: the host handler for `restrained` should keep the ped kneeling; the block client also tasks
   `kneel`. For `freed`, the block client tasks `follow` to the safe marker, so please do not override it.
8. **modules/npc**: `onDamaged` and the dispatched `damaged`/`shot` events may both fire for one bullet. The blocks
   dedupe; nothing needed, just keep `attackerSrc` = the shooter's server id (nil for NPCs).
9. **locales (merge)**: `run.fail_killed_unarmed` ("Mission failed: a surrendered or unarmed person was killed") is
   in blocks_b.json because the blocks call it (§6.2). If the runs slice writes a different text, keep theirs and
   drop mine. The same goes for `bonus.kingpin_alive`, `bonus.inmate_alive` and `penalty.hostage_hit` (card extras
   recorded by these blocks).
10. **built-in missions** (whoever writes them):
    - gang_shootout: `scaling = { 'objectives.1.waves' }`.
    - hostage_rescue: hostile_waves `waves = { 4 }` + protect_rescue (`npcs`, `safe` location keys);
      `penalties = { { id = 'hostage_hit', points = -50, each = true } }`, bonuses `no_hostage_hurt`.
    - weekly_boss_kingpin: `waves = { 8, 8, 7, 7 }`, `weapons` incl. `WEAPON_PUMPSHOTGUN`, `accuracy = 30`,
      `armour = 25`, `boss = { model = ..., spawn = '<key>' }`, bonuses `{ id = 'kingpin_alive', points = 50 }`.
    - warrant_service: flee_arrest door mode, `scaling = { 'objectives.1.associates.count' }`, bonuses
      `suspect_alive`, then an interact_points "Search the property" objective.
    - prison_break: flee_arrest `mode = 'scatter'`, `suspects = 5`, `armedShare = 0.4`,
      `escape = { distance = 600, seconds = 30 }`,
      `aliveBonus = { id = 'inmate_alive', points = 10, each = true }` (+ the same entry in bonuses),
      `scaling = { 'objectives.1.suspects' }`. Every spawn point must be outside the Bolingbroke no-build zone
      (180 m around 1768.73, 2570.43), or validation refuses the location.

## Contract deviations

- Added optional fields: hostile_waves `boss.aliveBonus`, `boss.accuracy`, `boss.behaviour`, `cuff`; flee_arrest
  `accuracy` / `armour` (armed suspects and inmates; defaults are the hostile_waves defaults), `cuff.maxDistance`;
  protect_rescue `target.icon` / `target.distance`.
- Extra evidence types beyond §6.2's examples: `free_start`, `knock_start`, `knock`, `aim`, `stunned`, `low_health`.
- Extra locale keys from the review: `block.protect_rescue.invalid.points_start`, `block.flee_arrest.invalid.route_zone`.
- `ctx.award`/`ctx.penalize` opts carry `points` (request 1).
