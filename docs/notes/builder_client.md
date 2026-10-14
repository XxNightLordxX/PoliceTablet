# builder_client · notes (Mission Builder: in-world tools and screens)

Files: `modules/builder/client.lua` (CP.Builder, client), `web/src/builder/` (MissionList, BuilderEditor and its
seven steps, BlockPanels, LocationMap, store, schema, applyResult, useDraftEditor, Builder.css),
`web/src/supervisor/screens/Builder.tsx`, `web/src/admin/screens/Missions.tsx`, `web/src/hud/BuilderOverlay.tsx`
(+ `.css`), `web/src/types/builder_client.ts`, `web/src/mocks/builder_client.mock.ts`,
`locales/parts/builder_client.json`, `tests/builder_client_spec.lua`.
The Lua header lists the public API, every client action and every event handled; the TypeScript shapes of the
overlays and of the protocol extensions are in `web/src/types/builder_client.ts`. The protocol itself is
`docs/notes/builder_protocol.md` §6; the server side is `modules/builder/server.lua` (not edited by this slice).

## Flow of a tool

1. A screen calls a client action (`builderPlace`, `builderRecord`, `builderTestDrive`). The Lua client validates
   the payload, checks the refusals and answers at once with `{ started = true }` (NUI requests time out after 20 s;
   the tools take minutes).
2. The tool thread closes the tablet (`CP.Tablet.close()`), runs the tool and shows its HUD
   (`CP.Tablet.overlay({ kind = 'placement'|'recording'|'testdrive', … })`, refreshed every 150 ms).
3. When it ends for any reason the ghost / test vehicle / driver / blips / zones / GPS waypoint it set are removed,
   the overlay is hidden, the result gets an increasing `seq`, is kept for `builderResult` and pushed
   (topic `builder`, `{ event = 'clientResult', id = missionId, result }`), and 300 ms later the tablet reopens on
   `payload.ui` (`'supervisor'` default, `'admin'` from the Admin UI) unless the tool stopped for the arena, death,
   unload or deletion.
4. The NUI keeps editor state in module memory (`web/src/builder/store.ts`: open mission, step, location, the
   running tool, unsaved draft, route meta) because closing the tablet unmounts the screens. A window listener
   queues `clientResult` pushes even while no editor is mounted; on reopen the editor pulls `builderResult` too
   (both deduplicated by `seq`), applies the result to the draft (`applyResult.ts`) and autosaves. The running
   tool is kept until its result is applied: its `PointSpec` says how (flee paths are a list of lists, a recorded
   checkpoint route is thinned).

## Contract interpretations

- **Payload extensions (all optional, protocol §6 payloads still work):** `label` (display name on the HUD),
  `ui` (`'supervisor'|'admin'`, where the tablet reopens), `minGap` (metres between points of one key, used for
  escort ambush points = `Config.Blocks.escort.ambushGap`), `radiusMin` / `radiusMax` (area radius range, e.g. a
  search area's `startRadius` range). Aliases from the task text are accepted: `count` → `max`,
  `existing` → `points`, `block = 'escort'` → `stops = true` (explicit `stops` wins).
- **Result extras:** every result carries `seq`; recordings also carry `droppedStops` (stop points that were on
  the first or last waypoint and were removed because stops must be interior, protocol §1.3). A recording with
  fewer than two waypoints comes back `cancelled = true` with a warning toast.
- **Overlay fields** go beyond the protocol's minimum (all listed in `types/builder_client.ts`): placement adds
  `label, mode, multiple, heading, radius` and `reason` as translated text; recording adds `samples, maxStops,
  stopsEnabled, waiting ('vehicle'|'return'|'checking'), distance, loop, toStart, zone, tooLong, undoMetres,
  minLength, maxLength, message`; test drive adds `label, timeLeft, stopLeft, waiting ('approach'|'clear'|
  'spawning'), distance, speed, done`.
- **Stored heights:** peds at ground + 1.0 m (what `GetEntityCoords` of a standing ped reads, and what the
  NPC spawner expects), vehicles at their root height above the ground (from `GetModelDimensions`), markers on
  the surface aimed at (a counter or a door), starts and areas on the ground. Vectors are rounded to 2 decimals,
  headings to 2 decimals in 0–360.
- **Spot checks** (`CP.Builder.checkSpot`, order): every point placed → nothing aimed at → further than 50 m →
  inside a no-build zone (2D) → water → not on the ground (aimed surface more than 0.75 m from
  `GetGroundZFor_3dCoord`, or steeper than ~45°; not for markers) → capsule probe pending / blocked (peds and
  vehicles) → spawn key closer than `minSpawnFromStart` to the start (3D, as the server) → start closer than
  `minLocationGap` to another start (2D) → closer than `minGap` to a point of the same key. The zone and
  distance checks use the point as it is stored (`spot.stored`: rounded, a ped at ground + 1 m), which is what
  the server checks on save and publish.
- **Road snapping:** a sample further than `maxOffRoad` from the closest vehicle node is still accepted when the
  vehicle is on a road surface (`IsPointOnRoad`) and the node is within 4 × `maxOffRoad`: long straight roads
  have sparse nodes, and the server's own check is only on the saved waypoints. Waypoints are the snapped node
  positions.
- **Waypoints:** a turn is measured against the heading leaving the previous waypoint, so a slow curve still
  produces a waypoint once it adds up to `turnAngle`; the sample before a `maxGap` stretch is kept; samples closer
  than 1 m are duplicates. `length` is the sum of the waypoint distances (what the server measures).
- **Undo and resume:** Backspace removes the last `undoMetres` of samples (never the first). Sampling then waits
  until the driver is back within `snapEvery` of the new end (overlay `waiting = 'return'`, a marker shows the
  spot) so the route never jumps. The same applies to a resume (in a vehicle or on foot) more than 2 ×
  `snapEvery` away from the end, and to getting back into a driver seat that far from it (another car, or after
  walking off).
- **Stop points** (escort): E (or the horn) adds one at the current end with `Config.Blocks.escort.stopWait`
  default seconds, at most `Config.Blocks.escort.stops[2]`; the editor lets the builder change each wait within
  the stopWait range afterwards.
- **Unreachable waypoints:** each segment is checked with `CalculateTravelDistanceBetweenPoints` (≥ 100000 = no
  path) while recording, as soon as its second waypoint is kept: the player is next to it then, and the game
  streams path nodes around the player only (far away the native fails with 100000 too). An undo drops the checks
  of the segments it removes. After X the rest (the last segment) is checked, four per frame, and the indexes are
  returned in `unreachable` (the map draws them dashed red).
- **Test drive:** more than 200 m from the route start a GPS waypoint leads there first (`waiting = 'approach'`;
  the builder never teleports anyone); the spawn point must be clear of the player (6 m); the local vehicle and a
  local driver (`s_m_m_armoured_01`, fallback `a_m_m_business_01`) drive waypoint by waypoint with
  `TaskVehicleDriveToCoordLongrange`; arrival radius max(12 m, 1.2 s at speed), 10 m for the last one; a waypoint
  not reached within `testDriveTimeout` is added to `failed` and the drive continues; escort stops are waited out
  with `TaskVehicleTempAction(…, 27)`; a vehicle slower than 0.5 m/s for 6 s is re-tasked; X stops the drive
  (`cancelled = true`). Driving styles: careful/cautious 786603, normal 786475, fast 786492; **reckless is driven
  as fast (786492)** because a test drive must stay in its lanes to be a useful check of the recorded road route.
- **Refusals:** `err.in_arena` (foreign `crimsonArena` value, rule 13), `err.builder_busy` (one tool at a time),
  `err.builder_dead`, `err.builder_on_run` (the player is on a mission run: the tools would fight the run's
  HUD and controls), `err.builder_disabled` (`Config.Builder.enabled = false`), `err.builder_bad_vehicle`
  (test-drive vehicle outside `Config.Builder.allowed.vehicles` / `escortVehicles`, or not a vehicle model),
  `err.invalid_payload`. A foreign arena value arriving while a tool runs stops it (state bag handler, work
  queued with `SetTimeout(0)`; the tool also re-checks every 250 ms) and the tablet does not reopen. The same
  250 ms check stops a tool when the player is put on a mission run (a unit leader drew one): a
  `builder.tool_stopped_run` toast, no reopen over the run HUD.
- **Routing bucket:** the bucket half of `CP.Alerts.inArena` has no client native, so the client relies on the
  state bag; `server:builder:test` re-checks the full `CP.Alerts.inArena` on the server.
- **Builder events:** `crimson-police:client:builder` `lockBroken` / `reloaded` stop a running tool of that
  mission (the result is still delivered, cancelled, and the editor shows the lock banner); `deleted` stops it
  without reopening and drops a pending result of that mission.
- **Checkpoint routes** can be recorded (thinned evenly to `Config.Blocks.checkpoint_route.checkpoints[2]`
  points, first and last kept) or placed point by point as markers.
- **Location keys** follow the block defaults (`hostile_waves` → `spawns`, `escort` → `route` / `ambushPoints`,
  `protect_rescue` → `hostages` / `safe`, `flee_arrest` → `door`, `suspect`, `fleeTo`, `associates` or
  scatter `spawns` / `routes`, `search_area` → `center` / `clues` / `hiding`, `skill_check` →
  `shared:devices` unless targets are placed). A pursuit's race loop uses keys matching `^raceLoop\d*$` and is
  recorded with `loop = true`. Flee paths (`routes`) are a list of lists; each placement run adds one path.
  Search areas need at least 6 clue spots and 6 hiding spots (the block's MIN_SPOTS, mirrored in the UI).
- **Test step:** `server:builder:test` starts the draft test; the tablet then closes after 0.9 s. The tester
  records Passed / Failed on the Test step with `server:test:record { missionId, location, tier, result, note }`
  (allowed with `builderEdit` for drafts); when the test was started with location "Random" the UI asks which
  location ran, because the reply echoes `'random'` (see requests).
- **Admin catalog** merges `admin:getMissions` (every loaded mission with `filePath`, `editedInCode`,
  `disabledInConfig`, `crossDeptEligible`) with `builder:list` (drafts and archived custom missions, lock,
  `can.*`). Built-ins are read-only: view, duplicate, launch. `Config.DisabledMissions` is shown read-only.
  Launch uses `server:admin:opLaunch { missionId }` for missions the list marks `crossDeptEligible`.
- **Supervisor screen** is gated by `session.actions.builderEdit`; each row / editor action is also gated by the
  action (`builderPublish`, `builderArchive`, `builderEditAny`, `builderRollback`, `breakEditLock`) and by the
  row's `can.*` from `builder:list`; the server re-checks everything.
- **Autosave:** every `autosaveSeconds` while dirty (`server:builder:autosave`, with the `rev` guard), before any
  tool starts and before a test or publish; leaving the editor saves (`server:builder:save`) and releases the
  lock (`server:builder:unlock`). Validation runs 1.5 s after the last change (`server:builder:validate`) and
  the errors are shown inline per field and per step.

## Response shapes (client actions)

| action | reply `data` |
|---|---|
| `builderPlace` / `builderRecord` / `builderTestDrive` | `{ started = true }` |
| `builderResult` | the pending `BuilderClientResult & { seq, droppedStops? }` or `nil`; clears it |
| `builderCancel` | `{ cancelled = boolean }` (false when nothing runs) |
| `builderWaypoint` | `{ ok = true }` |

Errors come back as the `err.*` keys listed above (`{ ok = false, error }` through the NUI `client` endpoint).

## Requests to the builder server

- `server:builder:test` replies `location = 'random'` when asked for a random location. Please return the index
  that `CP.Testing.startDraft` actually picked, so the Test step can record the result without asking.
- `builder:config` could expose the block constants the UI mirrors today (search_area MIN_SPOTS = 6, the
  `shared:devices` target key) so a change in the block cannot drift from the editor.

## Requests to other modules

- **Admin (modules/admin):** keep `admin:getMissions` rows in the `getMissionList` shape plus `filePath`,
  `editedInCode`, `disabledInConfig` (typed here as `AdminMissionEntry` in `web/src/types/builder_client.ts`;
  the oversight types could adopt it).
- **Tablet core (modules/tablet):** the tools rely on `CP.Tablet.close()`, `CP.Tablet.open(ui)` (yields for
  `getSession`), `CP.Tablet.isOpen()`, `CP.Tablet.overlay(o|nil)` and the overlay staying visible while no UI
  is open, and on the boot `theme` NUI message carrying the locale so the HUD overlays translate.
- **Testing (modules/testing):** a draft test's HUD could offer Passed / Failed at the end for builders (today
  they record it on the Test step after reopening the tablet).

## Tests

`lua5.4 tests/run.lua builder_client`: the recorder (waypoint gaps, turns, duplicates, undo, stops), every spot
check reason, the payload parsers (aliases, clamping, labels, errors), driving styles, thinning, headings, and
the runtime against stubbed natives: registration, refusals, a placement run (ghost local, rotate, place, undo,
invalid spots, result, push, reopen on the right UI, builderResult once), a start placement (radius, single
point), a recording run (vehicle wait, road-surface acceptance, off-road rejection, stop point, undo and return,
pause, unreachable check), road paths checked while driving (a long route, an undo), a resume or another car
away from the end, a spawn below the start (stored height), a test drive (approach, clear, local entities, stop
wait, a waypoint failed after the timeout, cleanup), arena / mission run / death / unload / events / resource stop,
and the NUI store with `applyResult.ts` (bundled with esbuild from `web/node_modules` and run in node; skipped
without them). The slice writes no SQL.
