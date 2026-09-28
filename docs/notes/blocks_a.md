# blocks_a · checkpoint_route, interact_points, skill_check

Files: `Crimson-Police/blocks/{checkpoint_route,interact_points,skill_check}/{server,client}.lua`,
`Crimson-Police/locales/parts/blocks_a.json`, `tests/blocks_a_spec.lua`.
Each file's header comment lists the fields it reads, the evidence it accepts and the ids it records.

## Evidence and messages (the exact shapes)

| Block | Client → server evidence (`ctx.report`) | Server → client (`ctx.send`) |
|---|---|---|
| checkpoint_route | `{ type='checkpoint', index, netId?, vehClass?, model?, try }` · `{ type='contact', netId }` · `{ type='undriveable', netId }` | `{ kind='state', points, current, done, total, finished, medals, track={contacts,undriveable}, course={running,elapsedMs,penalty,contacts,time,medal} }` |
| interact_points | `{ type='interact', point }` · `{ type='followup', point }` · `{ type='log', point, choice }` (the last one comes from the tablet) | `{ kind='state', points={ {coords,heading,label,status,outcome?,outcomeLabel?,followUp?,found?} }, hidden, found, total, done, log }` |
| skill_check | `{ type='check', target, index, success }` (one per round) | `{ kind='state', targets={ {coords,netId,status,next,streak,worker} }, checks }` · `{ kind='explode', target, coords, by, effect }` |

`point`, `target` and `index` are 1-based positions in the lists the server sends.
Point statuses: `pending` → (`followup`) → (`log`) → `done`; `dropped` after a rescale.

**`ctx.state.log`** (interact_points; read by `CP.Runs.view` for the Active Mission `log` field):
`nil` or `{ point = <n>, choices = { { id = 'secure', label = 'Secure' }, { id = 'found_open', label = 'Found open – secured' } } }`.
Labels are already translated on the server. Several doors can wait for their log at once; the oldest one is shown.

**`run.shared.devices`** (written by interact_points `hidden`, read by skill_check `targets = 'shared:devices'`):
`{ { netId, coords = vector3, point } }`, appended when a device is found and its prop has spawned.

## Bonus / penalty ids recorded

- checkpoint_route: `medal_gold` | `medal_silver` | `medal_bronze` (only on medal courses, from the course time + contact seconds), `no_contact` (only on medal courses).
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
   point. It does not apply `minSpawnFromStart` to hiding spots, because Bomb Disposal's start is at the building.
5. **onEvent reject reasons** are short ids for logs (`too_far`, `not_held`, `wrong_state`, …), not locale keys.
6. **checkpoint_route timing.** `timerStart` sets when the *course clock* (used for medals) starts. It never
   pauses the run timer. Each counted contact adds `contactPenalty` s to the course time **and** takes the same
   seconds off the run timer (`CP.Runs.adjustTimer`). Contacts are tracked when `contactPenalty > 0` or medals
   are on. The server counts at most one contact per 1.2 s per participant and 60 per objective.
7. **Medals.** A `location.medals` table overrides `obj.medals`. `medals = true` means "take them from the
   location" (validate requires them). `no_contact` also needs no server-side body-health loss of 10 or more on
   the course vehicle.
8. **Police vehicle.** The server checks `Config.PoliceVehicles.models` itself, and the class with
   `GetVehicleClass` when the server runtime has that native. Otherwise it uses the class the client
   reported (`ev.vehClass`).
9. **Stop time.** The client counts `stopFor` while stopped (< 1.5 m/s) inside the marker. The server
   accepts the report only if its own 1 s position samples had that participant inside for at least
   `stopFor − 2` s. Drive-through gates allow radius + 12 m (lag at speed).
10. **Undriveable.** A client report is accepted only for the reporter's vehicle, and only when the server
    sees engine health ≤ 100 (or petrol tank ≤ 0). The server tick also fails the run by itself when a
    course vehicle it has seen healthy reaches engine health ≤ 0.
11. **interact_points dwell.** A main action is accepted when the server sampled the participant within
    target radius + 3 m for at least `progress.duration − 1.5 s`. A follow-up is accepted
    `followUp.duration − 1.5 s` after the check.
12. **logResult without roll** (builder: "2–4 choices, the correct one rolled by the server"): the server
    rolls one of the choices per point with equal chances, and that choice is the correct log.
13. **Hidden devices spawn when found**, not at start (nothing to see or take before the search). The
    device prop is spawned with `role = 'device', tag = 'shared:devices', frozen = true`. The search is done
    once every device is found **and** spawned, so it waits on `ctx.canSpawn`. `fastBonus` counts from this
    objective's start, which for Bomb Disposal is the run start.
14. **skill_check.** A miss repeats the same round and costs `missPenalty` seconds. `failAfter` misses in a
    row on one target set it off. One participant works a target at a time (the lock frees after 15 s idle).
    The explosion is `AddExplosion(x, y, z, 2, 0.0, true, false, 1.0)` (damage scale 0), played only by the
    client named in `by`: the participant who missed, or the run host when the timer runs out. `onTimeout`
    sends the effect for every armed device and returns nil, so the run fails with `time_limit`.
15. **Hooks.** Every hook of §7.1/§7.2 is defined. `onEntityDead` does nothing because these blocks spawn
    no peds or vehicles. `hostChanged` only records the flag (no NPC AI).
16. **Locale.** `blocks_a.json` also holds `bonus.medal_gold`, `bonus.medal_silver`, `bonus.medal_bronze`,
    `bonus.no_contact` and `bonus.devices_found_fast` (mission-card extras these blocks record). If another
    part defines them too, the texts must match. Pursuit Sim's medals use the same `bonus.medal_*` ids.

## Requests to other modules

- **modules/runs (engine)**
  - Do not delete an objective's entities when that objective completes. The device props of
    interact_points (objective 1) are defused in skill_check (objective 2). Delete them at run end (and
    cleanup) only.
  - `ctx.state` must be the same persistent table (`run.objectives[i].state`) for every hook of an
    objective, on the server and on the client (`ctx.state` on the client too).
  - `ctx.complete()` must return `false` while `minSeconds` is not reached. These blocks call it again on
    every later tick until it returns something else.
  - A block rejecting an event (`return false, reason`) is normal (lag retries, rate limits). Please log
    it, do not flag the run. Checkpoint reports carry a `try` counter so a retry is never an exact duplicate.
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
