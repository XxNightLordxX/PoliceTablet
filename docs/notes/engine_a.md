# engine_a · notes (missions, draw, scaling, schedule, events)

Files: `modules/missions/server.lua`, `modules/missions/client.lua`, `modules/draw/server.lua`,
`modules/scaling/server.lua`, `modules/schedule/server.lua`, `modules/events/server.lua`,
`locales/parts/engine_a.json`, `tests/engine_a_spec.lua`.

## Contract interpretations

### CP.Missions
- **Custom missions from `CP.Builder.loadPublished()`**: each entry may be (a) a definition carrying the
  loader fields (`source`, `version`, `filePath`, `defHash`, `editedInCode`, `status`), (b)
  `{ def = <definition>, meta = { version, filePath, ... } }`, or (c) meta only
  `{ id, filePath, version, editedInCode }`, in which case the loader reads the file itself with the same
  sandbox used for built-ins. `defHash` is the hash of the file content when the file is readable, else a
  canonical (sorted keys) hash of the definition. If `loadPublished` throws, the custom missions that are
  loaded now stay loaded (they are not dropped from their pools).
- **`reload()`** calls `CP.Builder.onReload()` first (so hand edits become their new versions), then
  `loadAll()`; `summary.builder` holds the return value of `onReload`.
- **`register(def)`** reads the loader fields from `def` (default `source = 'custom'`, `status = 'published'`),
  refuses to replace a built-in mission and re-broadcasts the full list. **`unregister(id)`** only removes
  custom missions (built-ins are turned off in `Config.DisabledMissions`).
- **Hard checks (reject)**: id `^[%a][%w_]*$` and at most 40 characters (the `mission_id` column), label,
  type in `Config.MissionTypes` (the Weekly Boss is forced to `tactical` with a warning), departments a list
  (a `{ key = true }` map is converted), `1 <= minOfficers <= maxOfficers <= Config.Limits.maxUnitSize`,
  difficulty 1..#`Config.Difficulty.pointsByStars`, `timeLimit`/`startTimeout` 60–3600 s, `cooldown`
  0–86400 s, `vehiclePenalties` boolean, at least one location with `start = { coords, radius }` (a bare
  vector start is converted with radius 50 and a warning), at least one objective, a registered block per
  objective, the block's `defaults` and `validate(obj, mission, location)` for **every** location, no
  item named `armour`, `bandage`, `ammo-*` or `weapon_*` (any case; docs/CRIMSON_ARENA.md rule 4), and no
  point of any location (start and every named data key, recursively) inside a
  `Config.Builder.noBuildZones` zone (2D distance, as the blocks and the builder measure it; rule 7 —
  this also covers Crimson-Arena's Trailer Park and lobby zones).
- **Loader fields before the guardrails**: `source`, `isBoss`, `status`, `version` and `filePath` are set on
  the copy *before* the blocks' `validate` runs, because the blocks exempt built-in missions
  (`mission.source == 'builtin'`) from the Mission Builder's allowed model/weapon lists. (Before this fix
  the real `prison_break` and `weekly_boss_kingpin` were rejected at load.) `meta.source` other than
  `'custom'` means `'builtin'`.
- **`parse(luaSource, chunkName)`** (ARCHITECTURE §5.6) runs one file's source in the same sandbox and
  returns the raw definition (not normalised); `chunkName` may be given with or without the leading `@`
  (CP.Builder passes the path, CP.Testing `'@' .. path`).
- **Soft checks (warning only; the builder enforces them as guardrails for custom missions)**: fewer
  locations than expected (built-in 5, or 3 for `armored_truck_escort`, `evoc_course`,
  `weekly_boss_kingpin`; custom `Config.Builder.minLocations`), locations closer than
  `Config.Builder.minLocationGap`, more armed NPCs than `Config.Builder.maxHostiles` (block `armedCount`),
  more objectives than `Config.Builder.maxBlocks`, unknown department keys, a scaling base above its `max`.
- **Dropped with a warning**: scaling entries that do not resolve to a number or a list of numbers after the
  block defaults, items without a name, bonus/penalty entries without an id or whose id is not in
  `Config.Bonuses` and has no explicit `points`/`pctOfPoints`.
- **Payout fields**: any top-level key containing `payout` (any case) and `cash`, `cashBase`, `basePay`,
  `money`, `pay`, `reward`, `rewards` are removed with a console warning.
- **Defaults**: `description = ''`, `departments = {}`, `minOfficers = 1`, `maxOfficers = minOfficers`,
  `difficulty = Config.Blocks.details.difficulty[3]`, `startTimeout = Config.Limits.startTimeout`,
  `cooldown = Config.Blocks.details.cooldown[3]`, `vehiclePenalties = true`, objective `minSeconds` from
  ARCHITECTURE §3.3 (unless the block's `defaults` set it), `presenceRange = Config.Blocks[block].presenceRange[3]`
  (fallback `Config.AntiCheat.presenceRadius`), labels `run.objective_default` / `run.location_default`.
- The sandbox exposes exactly the contract globals; `math`, `string` and `table` are copies so a file can't
  change them for the rest of the resource. `error`, `os`, `require`, `load` are not available.
- Validation reasons returned by `normalize` are English developer-facing text (console, builder), not
  locale keys.
- The `crimson-police:client:missions` broadcast uses `TriggerLatentClientEvent(name, -1, 200000, list)`
  (the full list of 14 built-ins is about 60 kB of JSON), falling back to `TriggerClientEvent` where the
  native is missing (tests).
- `getMissionDefs` returns `nil, 'err.not_ready'` before the first load; the client retries (3 s, growing to
  15 s, 12 attempts) and ignores a callback reply once a push has arrived.
- `server:admin:reloadMissions` (§8.3 owner "missions") is registered here: `CP.Permissions.can(src,
  'reloadMissions')`, 1 per 5 s, audited with `CP.Admin.audit(src, role, 'audit', 'reloadMissions', nil,
  <count before>, '<n> loaded, <m> rejected', nil)`; replies with a plain summary
  `{ loaded, builtin, custom, warnings, failed = { { id, file, error } } }`.

### CP.Draw
- **No-repeat history**: distinct missions of that type whose `cp_mission_runs` rows have
  `state IN ('completed','abandoned')`, newest first (`MAX(created_at)`, ties by `MAX(id)`), per citizenid;
  the unit uses the union of every member's last `k` (k = `avoidLast`, or `avoidLastLarge` when the pool has
  `largePool`+ missions). Failed rows (downed, disconnected, time_limit, mission_failed) are not "completed
  or abandoned" and do not count. The Weekly Boss never counts (it is not in any pool). `recordLast` adds
  an in-memory record (15 minutes) that bridges a row that is being written.
- **When a unit's histories cover the whole pool** (pool of 2+): relax to `avoidLast`, then to "not the
  single most recent mission of any member", then the whole pool. A pool of one always repeats.
- The no-repeat rule is strict: if every candidate's locations are in use, the accept fails with
  `err.no_location` instead of falling back to an avoided mission.
- **Player clearance** ignores players for whom `CP.Alerts.inArena` is true (docs/CRIMSON_ARENA.md rule 7).
- **Reservations** allow several holders per spot (a test run can reserve a spot a live run holds, and
  vice versa the live draw skips it). `server:acceptType` holds a provisional `pending:<src>:<ms>`
  reservation around `CP.Runs.create`, and reserves under `run.id` itself if the engine did not. A sweep
  every 60 s releases pending holders older than 60 s and holders older than 120 s that `CP.Runs.get`
  does not know (leak protection only).
- **BoardData**: cards for every `Config.MissionTypes` key sorted by config points (then key). `points` =
  the best `CP.Scoring.P(def)` in the pool (fallback type points × `pointsByStars`), `cash` =
  `CP.Cash.range(key, officers)` (fallback: base payout — `CP.Payouts.baseFor` or type payout ×
  `cashByStars` — × tier cash, top of the range × `Config.Events.modifierCash`). `locked` priority: a member
  who is not an officer (`board.member_unavailable`) > type cooldown (own or a member's, with `until`) >
  hourly cap > empty pool (`board.locked_empty` / `board.locked_empty_solo`, or
  `board.locked_mission_cooldown` with `until` = the earliest per-mission cooldown end). `onCall` is true
  when any unit member is on a real call. While `CP.Operations.isLocked()` only `operation` is filled
  (`cards = {}`, `boss = nil`).
- **acceptType**: payload is the type key (a `{ missionType }`/`{ type }` table is tolerated). Checks in
  order: officer (the leader's own `CP.Access` error key is returned), unit leader, unit not locked, unit
  size, Cross-Department lock, every member an officer (`err.member_unavailable`), then per member:
  `CP.Alerts.inArena` (foreign crimsonArena flag or routing bucket ≠ 0, docs/CRIMSON_ARENA.md rule 5;
  `err.in_arena`; without modules/alerts: `foreignFlag` + `GetPlayerRoutingBucket`), active run, real call, hourly cap, type cooldown (own / `err.member_*`
  variants), then `CP.Runs.capsOk` (always reported as `err.server_busy`), then the boss checks. Invites
  close (`CP.Units.lock`) only after every check passed; the unit is unlocked on any later failure.
  Rate: 1 accept per 1.5 s per player (plus CP.Net's 3/s) and an in-flight guard per unit member
  (`err.busy`).
- **Weekly Boss accept**: the Tactical *type* cooldown does not block the event card (it is accepted with
  `weekly_boss`, not the type, and abandoning it starts no type cooldown), but the hourly cap, the Tactical
  server cap, the Cross-Department lock, the boss mission's own cooldown, department/size and the
  once-per-week rule do. `missionType = 'tactical'`, `isBoss = true` are passed to `CP.Runs.create`.

### CP.Events
- `bossAvailable` also refuses while a Cross-Department Mission is active (`err.operation_locked`), and when
  the boss mission is missing or disabled (`err.boss_unavailable`).
- "Used this week" = any `weekly_boss_kingpin` row (`mission_type = 'tactical'`, which also uses
  `idx_draw`) of that citizenid created since the reset of **the week's first boss day** (Friday with the
  default config; the week start itself when the week's first day is a boss day) whose `end_reason` is not
  `real_call`, `force_recall` or `cancelled` (voided rows still count: the attempt was used). Rows are
  written when a run ends, so a boss run accepted on Sunday night that ends after Monday's reset has a row
  dated in the new week; counting from the week start would have used up next weekend's attempt.
  Positive results are cached per citizenid for the week.
- The boss card is also locked by the hourly cap (`board.locked_hourly` / `board.locked_hourly_member`),
  which the accept enforces for the boss (it counts as Tactical for the hourly cap).
- `bossCard.available` = the unit may take this week's attempt (`locked == nil`); `busy` and `onCall` are
  separate flags as on the type cards. `typeOfTheDay` is true when the Type of the Day is `tactical`
  (boss runs are Tactical runs). Cash: `CP.Cash.range('weekly_boss', officers)` when it returns a
  positive range, else `CP.Payouts.baseFor(def)` (or `Config.Events.weeklyBoss.payout`) × tier cash, no
  modifier. Points: `CP.Scoring.P(def)`, else `Config.Events.weeklyBoss.points`.
- `rollModifier` uses `CP.U.rng(CP.U.hash(run.seed .. ':modifier'))` (deterministic per run, independent of
  the objectives' `seed + i` streams). The Tactical check reads `run.missionType`, else `run.mission.type`.
- `modifiers()` entries are `{ label = 'modifier.<key>', tacticalOnly = bool }`.

### CP.Scaling
- `combat`: accuracy is rounded and clamped to 0..100 (`SetPedAccuracy` range); armour is rounded and
  kept >= 0 but not capped (Critical tier + Armored Hostiles can exceed 100 on NPCs).
- `apply`: paths are relative to the mission (`objectives.` prefix optional, must start with an objective
  index); `max` clamps every scaled value. Unknown tiers resolve to the first row (Standard).

### CP.Schedule
- The retention job runs at each daily reset **and once 120 s after start** (catch-up for servers that
  always restart across the reset hour; it only touches rows past the cutoff, so it is idempotent).
  "Only when > 0": `runArchiveMonths`/`auditDays` of 0 turn the step off, and the INSERT … SELECT / DELETE
  only run when rows are past the cutoff. Rows are copied with `INSERT IGNORE` and only rows present in the
  archive are deleted (multi-table DELETE with a join), so a half-finished run can safely repeat.
- At the daily reset the retention job runs in its own thread *after* the daily listeners fire, so a slow
  archive never delays Type of the Day, goals, streaks or the cash cap.
- If the server clock moves backwards to an earlier day, nothing fires (a warning is printed).
- Day/week/month arithmetic uses `os.time` date normalisation (not `ts - resetHour * 3600`), so DST never
  shifts a day.

## Requests to other modules
- **CP.Runs**
  - `create(opts)` reserves the location with `CP.Draw.reserve(run.id, opts.mission.id, opts.locationIndex)`
    (test runs too) and `CP.Draw.release(run.id)` at cleanup; calls `CP.Events.rollModifier(run)` after
    `seed`, `missionType`, `isBoss`, `test` and `operationId` are set on the run; uses
    `run.missionType = 'tactical'` for the boss.
  - Call `CP.Draw.recordLast(citizenid, missionType, missionId)` whenever a **completed or abandoned** row is
    written (not failed rows, not tests).
  - `cooldowns(citizenid)` returns `{ types = { [type] = untilTs }, missions = { [id] = untilTs } }`;
    `completionsLastHour` counts boss completions; `capsOk('tactical')` covers boss runs; `get(runId)`
    also returns test runs (the reservation sweep relies on it).
- **CP.Cash** — `range(missionType, members)`: `members` are officer tables (§3.1) as the board passes them;
  please accept `'weekly_boss'` and return the boss's range (B via `CP.Payouts.baseFor(boss)` × tier cash,
  no modifier) as two numbers.
- **CP.Units** — `unitOf(src)` returns nil for a solo officer; `members(src)` returns `{ src }` when solo;
  `lock(unit)` / `unlock(unit)` are called by acceptType (unlock on failure).
- **CP.Operations** — `isLocked()` must be true for the whole time the board is locked (joining, running,
  waiting after a fail); `boardCard(src)` returns the §9.4 `operation` shape.
- **CP.Testing / CP.Operations** — pick a random location with `CP.Draw.pickLocation(def, srcs, rng)`;
  reservations go through `CP.Runs.create` (run ids). A non-run holder id kept longer than 2 minutes is
  released by the leak sweep.
- **CP.Builder** — `loadPublished()` in one of the three entry shapes above; `onReload()` returns a summary
  table; publish/restore → `CP.Missions.register(def)` with the loader fields on `def`; archive →
  `CP.Missions.unregister(id)`. `CP.Missions.normalize(def, meta)` is pure and can validate a draft.
- **CP.Scoring** — Type of the Day should apply by `run.missionType` (so a boss run counts when ToD is
  Tactical), which is what the boss card shows.
- **CP.Admin** — `/CrimsonPoliceAdmin reload` calls `CP.Missions.reload()` and prints its summary.
- **Locale merge** — keys this part shares with other parts: `err.busy`, `err.internal`,
  `err.no_permission`, `err.not_police`, `err.not_on_duty`, `err.rate_limited`, `err.suspended`,
  `err.suspended_dispatch`, `tier.*` (texts copied verbatim from `core.json`, the owner). `ui.json`
  currently differs from `core.json` on `err.internal` and `err.rate_limited`; that pair needs one text at
  merge. Keys other slices may add later with the same name: `err.in_arena`, `err.server_busy`,
  `err.operation_locked`, `err.on_call`, `err.already_on_run`, `modifier.*`. The access keys are passed
  through from `CP.Access.getOfficer`; `CP.Runs.create`'s error key is passed through as-is (runs' part).
- **Tablet** — `Session.config.tiers` labels: `CP.Scaling.label(name)`.
- **Web UI (Mission Board)** — Lua cannot send `null` inside a table: `BoardCard.locked`, `BoardData.boss`,
  `BoardData.operation` and `BoardData.activeRunId` arrive *missing* (undefined) when they are null in
  §9.4. Test them with `!value` / `value == null`, never `=== null`.
- **CP.Testing / CP.Builder** — `CP.Missions.parse` now exists (§5.6); both already prefer it.
