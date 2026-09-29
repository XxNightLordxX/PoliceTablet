# blocks_a · checkpoint_route, interact_points, skill_check

Files: `Crimson-Police/blocks/{checkpoint_route,interact_points,skill_check}/{server,client}.lua`,
`Crimson-Police/locales/parts/blocks_a.json`, `tests/blocks_a_spec.lua`.
Each file's header comment lists the fields it reads, the evidence it accepts and the ids it records.

## Evidence and messages (the exact shapes)

| Block | Client → server evidence (`ctx.report`) | Server → client (`ctx.send`) |
|---|---|---|
| checkpoint_route | `{ type='checkpoint', index, netId?, vehClass?, model?, try }` · `{ type='contact', netId }` · `{ type='undriveable', netId }` | `{ kind='state', points, current, done, total, finished, medals, track={contacts,undriveable}, course={running,elapsedMs,penalty,contacts,time,medal,held} }` |
| interact_points | `{ type='interact', point, seq }` · `{ type='followup', point, seq }` · `{ type='log', point, choice }` (the last one comes from the tablet) | `{ kind='state', points={ {coords,heading,label,status,outcome?,outcomeLabel?,followUp?,found?} }, hidden, found, total, done, log }` |
| skill_check | `{ type='check', target, index, success, seq }` (one per round) | `{ kind='state', targets={ {coords,netId,status,next,streak,worker} }, checks }` · `{ kind='explode', target, coords, by, effect }` |

`point`, `target` and `index` are 1-based positions in the lists the server sends. `seq` / `try` count the
client's own reports, so a retry, or a second miss on the same round, is never an exact duplicate of an
earlier report (the servers ignore them).
Point statuses: `pending` → (`followup`) → (`log`) → `done`; `dropped` after a rescale.

**`ctx.state.log`** (interact_points; read by `CP.Runs.view` for the Active Mission `log` field):
`nil` or `{ point = <n>, choices = { { id = 'secure', label = 'Secure' }, { id = 'found_open', label = 'Found open – secured' } } }`.
Labels are already translated on the server. Several doors can wait for their log at once; the oldest one is shown.

**`run.shared.devices`** (written by interact_points `hidden`, read by skill_check `targets = 'shared:devices'`):
`{ { netId, coords = vector3, point, model, heading } }`, appended when a device is found and its prop has
spawned. `netId` is the device's identity for skill_check; `model`/`heading` let skill_check re-create the prop.

## Bonus / penalty ids recorded

- checkpoint_route: `medal_gold` | `medal_silver` | `medal_bronze` (only on medal courses, from the course time + contact seconds), `no_contact` (only on medal courses).
  Each carries the EVOC card value as its `opts.points` hint (50 / 25 / 10, `no_contact` 10; capped by
  `Config.Builder.bonusCap.points` on non-built-in missions), so a custom medal course scores its medals although
  a custom file cannot list those ids (they are not in `Config.Bonuses`); a file that lists them keeps its own points.
- interact_points: `correct_log` (award), `wrong_log` (penalize), `fastBonus.id` (e.g. `devices_found_fast`).
- skill_check: `no_missed_checks`.

All are shared (no `src`). They are always recorded; scoring decides the value. The ids that are not in
`Config.Bonuses` need explicit values in the mission file (see requests below).

## Contract interpretations

1. **Randomness.** Every random pick (random checkpoints, door outcomes, hiding spots) is made once with
   `ctx.rng` when the state is first built (in `prepare`) and kept in `ctx.state`, so it does not matter
   whether the engine builds a fresh `ctx.rng` per call.
2. **Random selection keeps the start first.** With `use = 'random'` a pool point inside `location.start`
   (within `start.radius`) is always picked and comes first; the rest follow in the pool's circular order
   from it. This gives "Start: the first checkpoint / business" for Beat Patrol and Business Check.
3. **HUD.** The server never calls `ctx.hud`. It sends full snapshots with `ctx.send` on every change,
   plus once more on the first tick after `start`, in case an update arrives before the client's `start`.
   The client writes the only HUD line with `ctx.hudDetail`. Progress counts also come from `checklist`.
4. **validate** first applies the block defaults to a copy. It returns `false, <translated text>`
   (`CP.L` of a `block.<id>.invalid.*` key), which reads fine in the console and in `t()`. It checks the
   Config.Blocks ranges, the Config.Builder.allowed animations and `Config.Builder.noBuildZones` for every
   point. Custom missions (`mission.source ~= 'builtin'`) also get: interact_points `progress.anim` only an
   allowed animation name (built-ins may give a raw `{ scenario }` / `{ dict, clip }`), `hidden.prop` one of the
   block's device models (`prop_ld_bomb`, `prop_c4_final_green`), `fastBonus.id` a `Config.Bonuses` id. It does not apply `minSpawnFromStart` to hiding spots, because Bomb Disposal's start is at the building.
5. **onEvent reject reasons** are short ids for logs (`too_far`, `not_held`, `wrong_state`, …), not locale keys.
6. **checkpoint_route timing.** `timerStart` sets when the *course clock* (used for medals) starts. On a medal
   course that is the mission's **first** objective, `timerStart = 'first'` also holds the run timer
   (`CP.Runs.pauseTimer(run, true)` at the objective start) until checkpoint 1 counts (EVOC: "the timer starts
   at the first checkpoint"). The hold ends after at most 120 s even if nobody crosses checkpoint 1 (so a run
   can't sit paused forever), on `stop`, and is re-applied by `restart`. It is not taken when the timer is
   already paused (test controls), and never on non-medal routes (Beat Patrol) or later objectives (that would
   hand out free time mid-run). The snapshot carries `course.held`; the HUD then says "The timer starts at
   checkpoint 1". Each counted contact adds `contactPenalty` s to the course time **and** takes the same
   seconds off the run timer (`CP.Runs.adjustTimer`). Contacts are tracked when `contactPenalty > 0` or medals
   are on. The server counts at most one contact per 1.2 s per participant and 60 per objective. The running
   course clock on the HUD shows whole seconds (one NUI update a second); the final time shows tenths.
7. **Medals.** A `location.medals` table overrides `obj.medals`. `medals = true` means "take them from the
   location" (validate requires them). `no_contact` also needs no server-side body-health loss of 10 or more on
   the course vehicle.
8. **Police vehicle.** The server checks `Config.PoliceVehicles.models` itself. FiveM has no server-side
   `GetVehicleClass` native (qbx_core's export of that name asks a random client), so the class comes from
   `CP.Qbx.vehicleClass(model)` when the integrations module offers it (request below), a `GetVehicleClass`
   global if one exists, and otherwise from the class the client reported (`ev.vehClass`) — accepted only
   when the reported `ev.model` equals the model of the vehicle the server sees the reporter in.
9. **Stop time.** The client counts `stopFor` while stopped (< 1.5 m/s) inside the marker. The server
   accepts the report only if its own 1 s samples had that participant inside the marker, **stopped**
   (server `GetEntitySpeed` of the vehicle, or of the ped on foot, ≤ 3 m/s) and in a vehicle when
   `policeVehicle` is on, for at least `stopFor − 2` s. Drive-through gates allow radius + 12 m (lag at speed).
10. **Undriveable.** A client report is accepted only for the reporter's vehicle, and only when the server
    sees engine health ≤ 100 (or petrol tank ≤ 0). The server tick also fails the run by itself when a
    course vehicle it has seen healthy reaches engine health ≤ 0.
11. **interact_points dwell.** A main action is accepted when the server sampled the participant within
    target radius + 3 m, while the point was pending, for at least `progress.duration − 1.5 s`. A follow-up
    is accepted the same way for `followUp.duration − 1.5 s` while the point waits for its follow-up (the
    officer who checked the door starts that clock at the check; walking away resets it).
12. **logResult without roll** (builder: "2–4 choices, the correct one rolled by the server"): the server
    rolls one of the choices per point with equal chances, and that choice is the correct log.
13. **Hidden devices spawn when found**, not at start (nothing to see or take before the search). The
    device prop is spawned with `role = 'device', tag = 'shared:devices', frozen = true`. The search is done
    once every device is found **and** spawned, so it waits on `ctx.canSpawn`. `fastBonus` counts from this
    objective's start, which for Bomb Disposal is the run start.
    ARCHITECTURE §7.1 says the engine deletes an objective's entities when it stops, so skill_check does not
    rely on the search objective's props: while it runs, an armed device whose prop no longer exists is
    spawned again by skill_check itself (same model/coords/heading, waits for `ctx.canSpawn`, gives up after
    3 failed spawns). Distance checks fall back to the device's recorded coords, so defusing never depends
    on the prop existing.
14. **skill_check.** A miss repeats the same round and costs `missPenalty` seconds. `failAfter` misses in a
    row on one target set it off. One participant works a target at a time (the lock frees after 15 s idle).
    The explosion is `AddExplosion(x, y, z, 2, 0.0, true, false, 1.0)` (damage scale 0), played only by the
    client named in `by`: the participant who missed, or the run host when the timer runs out. `onTimeout`
    sends the effect for every armed device and returns nil, so the run fails with `time_limit`.
15. **Hooks.** Every hook of §7.1/§7.2 is defined. `onEntityDead` does nothing because these blocks spawn
    no peds or vehicles. `hostChanged` only records the flag (no NPC AI).
    The client halves keep their state in a per-file map keyed by `runId:index` (seeded with the first
    `ctx.state` they see), so they work whether the engine passes the same `ctx.state` every call or a fresh
    one; the entry is dropped on `stop`, and stale entries of finished runs are purged at the next run.
16. **Locale.** `blocks_a.json` also holds `bonus.medal_gold`, `bonus.medal_silver`, `bonus.medal_bronze`,
    `bonus.no_contact` and `bonus.devices_found_fast` (mission-card extras these blocks record). If another
    part defines them too, the texts must match. Pursuit Sim's medals use the same `bonus.medal_*` ids.

## Requests to other modules

- **modules/runs (engine)**
  - Preferably do not delete an objective's entities when that objective completes: the device props of
    interact_points (objective 1) are defused in skill_check (objective 2). skill_check now re-creates any
    that were deleted, so this only saves a respawn and a flicker.
  - `ctx.state` must be the same persistent table (`run.objectives[i].state`) for every hook of an
    objective on the server (the contract says so). The client halves no longer depend on it.
  - `CP.Runs.pauseTimer(run, paused)` is called by checkpoint_route (EVOC hold, note 6); it should update
    the HUD timer's `paused` flag.
  - `ctx.complete()` must return `false` while `minSeconds` is not reached. These blocks call it again on
    every later tick until it returns something else.
  - A block rejecting an event (`return false, reason`) is normal (lag retries, rate limits). Please log
    it, do not flag the run. Reports carry a `try`/`seq` counter so a retry, or a second miss on the same
    skill-check round, is never an exact duplicate: CP.AntiCheat's duplicate check must not drop them.
- **modules/integrations/qbx (CP.Qbx)**: please add `CP.Qbx.vehicleClass(model) -> class|nil` wrapping
  `exports.qbx_core:GetVehicleClass(model)` (it may yield; model hash as `GetEntityModel` returns it on the
  server). checkpoint_route uses it, when present, instead of the client-reported class.
  - `CP.Runs.view`: `log` = the current objective's `ctx.state.log`, as is (shape above).
- **modules/tablet + web (Active Mission screen)**: show `view.log.choices` as buttons (labels are already
  translated). A tap must send `server:objective` (runId, current objective index,
  `{ type = 'log', point = view.log.point, choice = <id> }`), e.g. through `CP.Runs.report`.
- **missions (built-in files)**
  - Beat Patrol: `{ block = 'checkpoint_route', checkpoints = 'spots', use = 'random', count = 5, radius = 10.0, stopFor = 10, policeVehicle = true, contactPenalty = 0, failIfUndriveable = false }`.
    The card fails only on the time limit and has common bonuses only. Put `start.coords` on one of the spots.
  - EVOC Course: `{ block = 'checkpoint_route', checkpoints = 'course', use = 'all', stopFor = 0, medals = true, contactPenalty = 2, timerStart = 'first', failIfUndriveable = true }`
    with `location.medals = { gold, silver, bronze }`. Bonuses: `{ id = 'medal_gold', points = 50 }`,
    `{ id = 'medal_silver', points = 25 }`, `{ id = 'medal_bronze', points = 10 }`, `{ id = 'no_contact', points = 10 }`.
  - Business Check: `{ block = 'interact_points', points = 'businesses', use = 'random', count = 4, target = { label = 'Check door' }, progress = { label = 'Checking door', duration = 5000 }, roll = { outcomes = { { id = 'secure', chance = 0.75 }, { id = 'open', chance = 0.25, followUp = { label = 'Secure door', duration = 5000 } } } }, logResult = { choices = { 'secure', 'found_open' }, correct = { secure = 'secure', open = 'found_open' } } }`.
    Bonuses `{ id = 'correct_log' }`, penalties `{ id = 'wrong_log' }` (values from Config.Bonuses).
  - Bomb Disposal: objective 1 `{ block = 'interact_points', points = 'spots', target = { label = 'Search' }, progress = { label = 'Searching', duration = 3000, anim = 'search' }, hidden = { count = 1, prop = 'prop_ld_bomb' }, fastBonus = { seconds = 120, id = 'devices_found_fast' } }`,
    objective 2 `{ block = 'skill_check', targets = 'shared:devices' }` (defaults = the card),
    `scaling = { 'objectives.1.hidden.count' }`, bonuses `{ id = 'no_missed_checks' }` and `{ id = 'devices_found_fast', points = 10 }`.
  - Secure the scene / Search the property: `{ block = 'interact_points', points = 'scene', progress = { label = ..., duration = 8000 } }`.
- **Server owners (README)**: the device explosion uses `AddExplosion` (damage 0) from one participant's
  client. An anti-cheat that bans client explosion events must allow it (explosion type 2) for Crimson-Police.
