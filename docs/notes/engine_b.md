# engine_b · notes (modules/runs: the run engine)

Files: `Crimson-Police/modules/runs/server.lua`, `Crimson-Police/modules/runs/client.lua`,
`Crimson-Police/locales/parts/engine_b.json`, `tests/engine_b_spec.lua`,
`tests/fixtures/engine_b/client_spec.lua` (client half, run in its own process by the spec).

## Contract interpretations

### Creating a run
- `create(opts)`: `members` may be officer tables (§3.1) or srcs (resolved with `CP.Access.getOfficer`, then
  `CP.Qbx.getInfo` for non-police test admins). Refusals: `err.invalid_mission`, `err.invalid_location`,
  `err.no_members`, `err.member_unavailable` (no src/citizenid), `err.already_on_run` / `err.member_on_run`,
  `err.in_arena` (`CP.Alerts.inArena`), and `err.server_busy` from a second `capsOk` check for runs that are
  neither tests nor operations (closes the race between two accepts).
- `CP.Draw.reserve`'s return value is ignored: the draw holds a provisional reservation during `create`, and a
  spot may have several holders.
- The modifier is rolled only for runs that are not tests, operations or the boss (`CP.Events.rollModifier`
  checks the same). Time Crunch: `timeLimit = round(timeLimit × (1 − Config.Events.timeCrunchCut))`.
- `run.unit = CP.Units.unitOf(leaderSrc)` is kept and unlocked when the run ends (not for test runs).
- Mission items are given at accept with metadata `{ cpRun = run.id, cpItem = true }`, never to an in-arena
  player; removal is by slot (`Search(src, 'slots', name, { cpRun })` then `RemoveItem(..., slot)`). Items not
  found (offline, arena stash, full inventory) go on an orphan list by citizenid, swept on player load (5 s
  after), 10 s after `CP.Alerts.foreignClearedAt[src]`, and every 60 s. The load sweep and a sweep 15 s after
  resource start also remove leftovers of any mission item name (`metadata.cpItem` whose `cpRun` is not live).
- `client:start` data also carries `timeLimit`; `mission` is sent without `locations` (the drawn one is
  `location`).

### Route, arrival, In progress
- The server calls `CP.Route.begin(run, src)` for every participant at accept and `CP.Route.stop(run, src)`
  when a participant leaves or the run ends. The client calls `CP.Route.begin(runId, startCoords, { startRoute, radius })`
  on `client:start` (a test with the route off: waypoint only, done by CP.Route), and `CP.Route.stop()` when
  its own `client:participants` entry becomes `arrived` and at the end.
- `markArrived` also patches that participant's HUD `route = { status = 'arrived', distance = 0 }`.
- The tier counts every active participant (arrived or not). `client:inProgress` and the objective actions go
  to every active participant, so late arrivals run the client halves too.
- A leave before the start recalculates `expectedTier` (and sends `client:tierChanged` with it as both names).
  A forced test tier never changes.

### Objectives, timer, HUD
- `ctx` is built once per objective and reused (so `ctx.rng` continues); `ctx.obj` / `ctx.tier` / `ctx.state`
  are refreshed on every hook. `ctx.state` is `run.objectives[i].state`, cleared in place by a test restart.
- `objectiveComplete`: `minSeconds` counts from the objective's start (ms clock). An early call returns false;
  more than 1 s early (tick jitter) flags the run once per objective with
  `CP.AntiCheat.flag(run, nil, 'too_fast', detail)` (fallback `run.flagged` when AntiCheat is absent). Test
  runs are never flagged. An objective's entities are **not** deleted when it completes (interact_points
  devices are defused by the next objective); everything goes at run end.
- `onTimeout` returning `'completed'` ends the run `completed`/`completed`; otherwise `failed`/`time_limit`.
- `ctx.hud(patch)`: `detail`, `value`, `max` belong to that objective's HUD entry (stored in
  `run.objectives[i].hud`, `false` clears); every other key (e.g. `message`) is a top-level HUD patch.
- HUD objectives (§9.3): one entry per objective; the block `checklist` of the current objective gives
  `value`/`max` (first item) and `detail` (further items as "label v/m"); `ctx.hud` values win; done objectives
  keep the checklist taken when they completed. The server resends the full list whenever it changes (checked
  every tick) and pushes the `run` topic at most every 2 s for progress changes.
- Timer patches `{ remaining (ceil), paused }` on start, adjust, pause and every 30 s. HUD messages clear
  themselves after 8 s on the client; the ended HUD hides 12 s after the end.
- `remaining(run)` is nil before In progress (view `remaining = null`).

### Leaving and ending (ARCHITECTURE §4.3)
- Everything that must not race (status, cooldowns, host, rescale, flags, route) happens before the first yield;
  then the row, the payment and the hooks.
- `removeParticipant` increments `run.stats.downs` for `downed`. `onParticipantLeft` is called for the current
  objective only; `rescale` for every objective not done (with the re-scaled `ctx.obj`).
- `opts.notify` = a locale key shown as a toast to the leaver (arena: `run.left_for_arena`); `opts.silent` = no
  toast and no result screen (`client:runEnded` still arrives with a nil breakdown so the client cleans up).
- The last participant out ends the run with full cleanup; `CP.Operations.onRunEnded(run, state)` gets
  `'failed'` when that last result was failed (downed/disconnected), else `'abandoned'`.
- Operation runs start cooldowns like any run (the spec's exemption is about joining).
- Weekly Boss: never a type cooldown; the mission cooldown and the row (which uses the week's attempt) apply.

### Rows (cp_mission_runs)
- One insert per participant with every column; nil values are written as `NULL` literals so the parameter
  list never has holes. `penalty_points` is the positive sum of the penalties, `bonus_points` the sum of the
  bonuses; `cash_multiplier` = mTier × mMod rounded to 2 decimals (the exact amount is in the breakdown).
- `department` = the department of the player's active job at the end when it still is one, else the
  accept-time department. `participants` = active at that moment + the row's officer; `departments_n` the
  distinct departments of that set.
- Presence: for completed/failed results in runs that ever had 2+ participants, `CP.AntiCheat.presenceOk(run, p)
  == false` sets `p.flagged = { reason = 'presence' }`.
- Flagged rows keep their computed points and cash (so an approval can release them); `cash_status = 'held'`
  only for completed flagged rows (failed/abandoned stay `none`). `CP.Cash.pay(rowId)` runs only for completed,
  unflagged rows with an amount > 0; the final `cash_status`/`cash_paid` are read back, written into the
  breakdown JSON and sent in the result. `CP.Scoring.onRowCounted` runs for unflagged completed/failed rows,
  `CP.Goals.onRunCompleted` for unflagged completed rows, `CP.Draw.recordLast` for completed and abandoned rows.
- RunResult (§9.6) extras: `failReason` (the block's locale key) for `mission_failed`, `cash.paid` after payment.
- Test runs: the RunResult is computed (would-have points and cash, status `none`) and nothing is written.

### Cooldowns, caps, hourly count
- Cooldowns live in memory per citizenid; they are rebuilt from `cp_mission_runs` rows of the last
  `max(abandonCooldown, largest mission cooldown)` seconds on the first `cooldowns()` call for that citizenid and
  on player load. Voided rows count (the run happened). Boss rows never set a type cooldown.
- `completionsLastHour`: completed rows of the last 3600 s, excluding `manual_award`/`goal`; cached 10 s and
  dropped when a completed row is written.
- `capsOk('weekly_boss')` counts as Tactical; tests and operations never count.
- `reclassify` only changes rows whose `end_reason` is `real_call`, `force_recall` or `cancelled` (sets
  `state` and the JSON `endReason` too), applies the new reason's cooldowns from now, drops the pay tier if the
  run is still in progress, and works from the row alone once the run is gone. Returns false when no row
  matched.

### Entities, telemetry, evidence
- `spawnPed/Vehicle/Object` refuse (return nil) over the caps; vehicles use `CreateVehicleServerSetter` with
  `opts.vehicleType` (default `'automobile'`), falling back to `CreateVehicle`. The armed-alive cap does not count
  NPCs whose `cp` state is `cuffed`; the entity cap counts corpses until they are deleted.
- An entity missing on 2 consecutive ticks goes through `entityDied` (killer nil) and is forgotten. Ped deaths
  come from `CP.Npc`; only when `CP.Npc.onDeath` does not exist does the engine poll ped health itself.
- Telemetry: `vehicle` only from the driver of a non-mission vehicle, at most every 3 s, lowest engine/body
  over the whole run; `ped_hit` for a networked non-player, non-mission ped within 30 m of a sender who is in a
  vehicle, once per ped per run, at most 10 per participant → `penalize(run, 'pedestrian_hit', { src })`;
  `lights_siren` once per participant on `beat_patrol`/`business_check` while in a vehicle (accepted or in
  progress) → `penalize(run, 'lights_siren', { src })`; `weapon_fired` once per participant →
  `run.stats.weaponsFired + 1`, `p.firedWeapon = true`. In-arena senders are ignored.
- `server:objective`: active participant, run in progress, index = the current active objective; evidence is
  sanitised (tables ≤ 32 keys, depth ≤ 3, strings ≤ 256); `CP.AntiCheat.checkEvent` first; `CP.Access.recheck`
  on every objective event (removes with its reason). Block rejections are logged, never flagged. Events for
  unknown runs or from non-participants are logged only (a forged event must not flag someone else's run).
- Host: offline host → next in join order; a host silent for 15 s (`GetPlayerLastMsg`) hands over only to a
  responsive participant.
- `anchor(run)`: the current objective's first point from its fields (`checkpoints`, `points`, `spawns`, `npcs`,
  `targets`, `door`, `suspect`, `spawn`, `center`, `route`, `safe`, `scene`, or `run.shared.devices`), then a
  live entity of that objective, then the start.
- `testRestart`: the block's `restart`, else stop + delete its entities + clear its state + prepare + start.

## Requests to other modules

- **CP.Scoring**
  - `compute(run, p, result, opts)`, with `opts = { objectivesDone, objectivesTotal, failedShare (failed only),
    durationS, participants, departments, endReason }`; `p.result`/`p.endReason` are set before the call. Return
    §9.6 `points` with an integer `final`. It must write nothing (it is also used for test runs).
  - Recorded counts: `run.score.shared[id]`, `p.score[id]`; per-occurrence value hints `run.score.values[id]`
    (blocks pass `opts.points`, e.g. `hostage_hit = -50`, `kingpin_alive = 50`), use them when neither the mission
    entry nor `Config.Bonuses` gives a value; `run.score.kinds[id]` = `'bonus'|'penalty'`.
  - Engine ids: `pedestrian_hit` (→ `Config.Scoring.common.pedestrianHit`), `lights_siren` (→ `lightsSiren`);
    CP.Npc records `shot_surrendered`. End-evaluated: `no_participant_downed` (`run.stats.downs == 0`),
    `no_weapons_fired` (`run.stats.weaponsFired == 0`). Vehicle: `p.vehicle = { seen, engine, body }`; first run:
    `p.firstRunSinceDuty`; medals: `run.flags.medals`; team multiplier from `run.payTier`.
  - `onRowCounted(citizenid, row)`: `row` holds the column names of the insert plus `id`.
- **CP.Cash** — `compute(run, p)` → `amount, breakdown` (`p.result` is set; return 0 for non-completed). `pay(rowId)`
  may yield; the engine reads `cash_status`/`cash_paid` afterwards. Please pay the breakdown's exact amount
  (`breakdown.cash.amount`): `cash_multiplier` is rounded to 2 decimals (1.15 × 1.25 = 1.4375 → 1.44).
- **CP.AntiCheat** — `flag(run, src|nil, reason, detail)` should set `run.flagged` / `p.flagged = { reason, detail }`
  (the rows read those); `checkEvent` receives sanitised evidence; the idle check removes with
  `removeParticipant(run, src, 'idle')`; `presenceOk(run, p)` at the end.
- **CP.Route** — `status(run, src)` → `{ status = 'on'|'off'|'arrived'|'disabled', secondsLeft, recalcsLeft, distance }`;
  the client `begin(runId, startCoords, { startRoute, radius })` is called by modules/runs/client on
  `client:start`, and client `stop()`
  must be idempotent (called on arrival and at the end).
- **CP.Downed** — `removeParticipant(run, src, 'downed', { keepFlag = true })`; the engine already increments
  `run.stats.downs`.
- **CP.Alerts** — keep `foreignClearedAt[src]` readable on the table (orphan item sweep 10 s after an arena exit).
- **CP.Calls** — `reclassify(citizenid, runId, 'real_call_cancelled')` returns a boolean.
- **CP.Testing** — optional hook `CP.Testing.onRunEnded(run, state, endReason)` is called for test runs. Force
  complete → `endRun(run, 'completed', 'completed')`; force fail → `failRun(run, key)`; end test →
  `removeParticipant(run, src, 'cancelled')` for each (no cooldown, and test runs write nothing anyway).
- **CP.Operations** — cancel → `removeParticipant(run, src, 'cancelled')` for each participant.
- **CP.Npc** — report every mission ped death with `CP.Runs.entityDied(run, netId, killerSrc)`.
- **Blocks** — `ctx.award/penalize(id, { count, points, src })`; `ctx.hud` as above; checklists should put the main
  count first.
- **Tablet / web (Active Mission)** — the push topic `run` carries the view, or nil when the run ended for that
  player; `view.log.choices` → `clientAction('logResult', { point, choice })` (registered by modules/runs/client).
- **Locale merge** — keys shared with other parts (texts identical): `run.objective_default`, `modifier.*`,
  `tier.*`, `err.member_unavailable`, `err.already_on_run`, `err.member_on_run`, `err.in_arena`,
  `err.server_busy` (engine_a), `err.invalid_payload`, `err.invalid_run` (core).
