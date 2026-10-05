# builder_server · notes (CP.Builder server)

Files: `Crimson-Police/modules/builder/server.lua`, `docs/notes/builder_protocol.md` (the protocol: definition
shape, every callback/action with payload and result, client placement/recording results),
`Crimson-Police/web/src/types/builder_server.ts`, `Crimson-Police/web/src/mocks/builder_server.mock.ts`,
`Crimson-Police/locales/parts/builder_server.json`, `tests/builder_server_spec.lua`
(run: `lua5.4 tests/run.lua builder_server`).

Response shapes: all in `builder_protocol.md` §3/§4 and `web/src/types/builder_server.ts`.

## Contract interpretations

1. **Builder units** (task + `config/blocks.lua` header): chances are whole percent, progress times seconds; the
   field lists are fixed tables (`PERCENT_FIELDS`, `SECONDS_FIELDS`, sent in `builder:config`). Health shares
   (`belowHealth`) stay fractions. Vectors are rounded to 2 decimals and percents to whole numbers when stored, so
   the Lua file round-trips exactly (the spec asks for chances "with two decimals").
2. **Bonus entries** in the builder form are `{ id, points }` (flat kinds) or `{ id, pct }` (pct kinds, whole
   percent); the stored draft always carries the explicit value (config value when left out). The file gets
   `points = n` / `pctOfPoints = 0.10` and `each = true` from `Config.Bonuses`. Only `Config.Bonuses` ids are
   allowed; `bonuses` takes positive ids, `penalties` negative ones.
3. **Guardrails** (`CP.Builder.validate`): every check of SPEC "Guardrails" + "Route recording" and the task list,
   plus the block's `validate(obj, mission, location)` for every location (the per-block authority; mission has
   `source = 'custom'`, so strict checks apply), `requiredPoints`, `armedCount`. Numbers not in config are local
   constants: start radius 20–150 m (default 60), at most 20 locations, 10 items (count 1–100), 20 scaling entries,
   500 route waypoints, labels 64 / description 500 characters, "z sanity" |x|,|y| <= 10000 and -250 <= z <= 1500.
   `minSeconds` must be >= 1 s and the objectives' minimum times must fit in the time limit; the block default is a
   default, not a floor (the spec's own custom example uses 45 s for hostile_waves, below its default of 60).
   `publish`, `test`, `validate` (action) and reloads also run `CP.Missions.normalize` (the loader's own checks).
   **Start radius of a search mission**: when the mission has a `search_area` objective, its search circle is the
   start marker (the run starts when a participant enters it, as in Manhunt), so every location's start radius
   must equal the first `search_area` objective's `startRadius` (its block default 600 when unset) and is checked
   against `Config.Blocks.search_area.startRadius` (200–1000 m) instead of 20–150 m
   (`builder.error.start_radius_search`). The UI locks the start radius to that circle and keeps it in sync
   (an editable draft saved before this rule gets its start radii moved onto the circle when it is opened).
   **Copies of built-ins** (`server:builder:duplicate`): every built-in mission's copy passes these guardrails and
   can be published after its test (`tests/int_duplicates_spec.lua`); `Config.Builder.allowed.peds` holds every
   base-game ped a built-in or a block default uses (inmates, the Kingpin, the escort driver).
   **Renamed fields**: `RENAMED_FIELDS` reads an old objective field name as the new one wherever the builder
   reads a definition (sanitize, file units, record views): checkpoint_route `policeVehicle` → `vehicleRequired`.
4. **Spawn points** for `minSpawnFromStart` are the location keys named by the objective fields in `SPAWN_FIELDS`
   (NPC/vehicle spawns: hostile_waves spawns/boss.spawn, protect_rescue npcs, flee_arrest suspect/associates/spawns,
   pursuit spawn/spawns, escort ambushPoints, search_area hiding). Markers (interact points, doors, checkpoints,
   safe spots) may be near the start. No-build zones apply to every point (2D), including route waypoints.
5. **Road path check** between waypoints (`CalculateTravelDistanceBetweenPoints`) is client-only (the server has no
   path finding); the client reports `unreachable` waypoints with the recording.
6. **Save stores incomplete drafts** and returns `errors` + `valid`; publish refuses with `err.builder_invalid`
   (the UI calls `validate` for the list), because a CP.Net action error is a single locale key.
7. **draft_tested**: set only by `onDraftTested` for a pass of the **current** draft: same `draft_version`, and
   the `defHash` CP.Testing hands back (the content that ran) equals the stored draft's content hash (a caller
   without it: the hash of the last test `server:builder:test` started), at the required tier or a higher one
   (`testAtMaxTier = false`: any tier). The draft is read after the audit, right before the update. Any stored
   change of the draft content resets it to 0.
8. **Versions**: new draft v1; the first save of a published mission without a draft creates
   `published_version + 1`; publish consumes the draft (draft fields cleared, lock released); rollback and an
   accepted code edit publish `published_version + 1` and move an existing draft to the next number (rollback) or
   replace it (code edit).
9. **Rollback** restores the newest `<id>.v<n>.lua.bak` with n < published version, re-checked against the
   guardrails (not the test requirement: that content passed its test when it was published), re-exported with a
   fresh header as the new version; the replaced file becomes a `.bak` in turn. Supervisors need `builderRollback`
   and, for someone else's mission, `builderEditAny`.
10. **Hand edits** are processed on reload **and at start** (`loadPublished` runs the same file sync), because the
    file is the source of truth on start and on reload. An accepted edit keeps the developer's file (only our
    header's `version:` line is updated and an `edited:` line added), is stored as a new version with
    `edited_in_code = 1`, and the previous published version is regenerated as `<id>.v<n>.lua.bak` (the edit
    overwrote it). Payout fields (at any depth) are stripped with a console warning (each load). The guardrails
    run on the builder copy (builder units), and the file itself must also pass `CP.Missions.normalize` as
    written, because that file is what goes live. A file that breaks the guardrails or does not load stays on
    disk untouched and is **not** used: the last published version (`published_definition`) stays live, with a
    warning on every reload. Conflict (the draft also changed since the
    last publish, i.e. differs from `published_definition`): the file wins, the draft is written as
    `<id>.draft.lua.bak`, cleared from the row, the lock is released, the editor is told
    (`client:builder` `reloaded` + toast) and `codeEditConflict` is audited. The code-edit actor is `console`.
11. **File hash baseline** lives in `published_definition._file.hash` (no column for it in 001). A published row
    without it takes the file on disk as its baseline.
12. **Ids**: `custom_` + slug of the label (`[a-z0-9_]`, slug at most 30 characters), `_2`… on a clash with any
    custom or built-in id; creation uses `INSERT IGNORE` and retries on a race. An explicit `save` of a
    never-published draft renames the row when the label's slug changed (`previousId` in the reply). A test
    started before the rename is outdated (the id and label are part of its content); its result, sent under the
    old id, never reaches the renamed draft (a new mission may take the old id).
13. **Permissions**: `builder:list/get/config`, `create`, `duplicate` and `validate` need `builderEdit` (admins
    always); editing someone else's mission needs `builderEditAny`; publish/archive/restore of someone else's need
    `builderEditAny` too; `breakLock` needs `breakEditLock`. Any custom mission may be duplicated into an own draft.
    A duplicate keeps only standard bonuses in its lists and `B.customBonusFields` drops the objective-level ids
    and values the blocks refuse on custom missions (flee_arrest `aliveBonus` points / non-standard id, the boss's
    `aliveBonus` points, pursuit non-standard `detainBonus` / `allDetainedBonus` / `fastStop.id` / `ramPenaltyId`
    and `fastStop.seconds` above 120, interact_points non-standard `fastBonus`), so the block defaults apply. A
    saved or hand-edited definition that sets them is rejected by the block's validate instead.
    Supervisors must be on-duty officers (via CP.Permissions/CP.Access); admins may be off duty
    (identity from `CP.Qbx.getInfo`).
14. **Header publisher text**: `<rank> <name> (<department short>, citizenid <cid>)`, e.g. "Sergeant John Doe
    (SAST, citizenid ABC12345)"; an admin outside a department: `(admin, citizenid …)`. `]]` and control
    characters are neutralised so nothing can close the header comment.
15. **Discard** of a never-published draft deletes its row (nothing references it); for a published mission only
    the draft is cleared.
16. **Locks** are released when the holder drops or unloads their character (`playerDropped`,
    `CP.Qbx.onPlayerUnload`); lock state is computed in SQL (`TIMESTAMPDIFF`), never from the Lua clock.
17. **Audit**: `CP.Admin.audit(citizenid|'console', role, 'builder', action, target, old, new, reason)` for create,
    duplicate, save (explicit only; autosaves are not audited), test, testPassed/testFailed, publish, archive,
    restore, rollback, breakLock, discardDraft, codeEdit, codeEditConflict. The builder webhook is posted by
    `CP.Admin.audit` (category webhook), so the builder does not call `CP.Admin.webhook` itself (no double posts).
18. **Arena**: `server:builder:test` refuses with `err.in_arena` (same text as engine_a's key).
19. **Tests** use their own database `cp_test_builder_server` (same migrations; the engine_a pattern) so parallel
    specs that reset `cp_test` cannot interfere; every SQL statement of the module runs there. Mission files go to a
    temporary `missions/custom/test_builder_<n>/` folder (with `archived/`) that is removed at the end. The task
    text names `tests/builder_spec.lua`; the owned file is `tests/builder_server_spec.lua`.

## Mismatches with the real code of other modules
- `CP.Missions.parse(luaSource, chunkName)` (ARCHITECTURE §5.6) does not exist in `modules/missions/server.lua`
  yet. `CP.Builder.parse` calls it when present and otherwise runs the identical loader sandbox itself.
- `CP.Testing` and `CP.Admin` are not written yet; every call is guarded (`err.builder_testing_unavailable`;
  audit falls back to a debug log line).

## Requests to other modules
- **CP.Missions (engine_a)**: add `parse(luaSource, chunkName) -> def|nil, err` (the sandbox already in
  `runMissionFile`) as the contract says. `loadPublished()` entries are definitions carrying the loader fields
  (shape (a) of engine_a's notes); `onReload()` returns the summary documented in the protocol §5.
- **CP.Testing**: `startDraft(src, def, { tier, location = index|'random', useStartRoute })` receives the
  **normalised** draft (`id` = mission id, `source = 'custom'`, `status = 'draft'`, `version` = draft version,
  `defHash`). Please gate it with `CP.Alerts.inArena` too, and when the tester records Passed/Failed call
  `CP.Builder.onDraftTested(def.id, def.version, <tier name the run used>, passed, src, def.defHash)`.
- **CP.Admin**: accept category `'builder'` in `audit` and post it to `cp_webhook_builder`; the actions listed in
  interpretation 17. `/CrimsonPoliceAdmin reload` → `CP.Missions.reload()` (which calls `CP.Builder.onReload()`).
- **Builder client** (`modules/builder/client.lua`): the client actions of protocol §6 (`builderPlace`,
  `builderRecord`, `builderTestDrive`, `builderResult`, `builderCancel`, `builderWaypoint`) with the async
  start/result pattern (an NUI request times out after 20 s), the placement checks, `CP.Tablet.overlay` kinds, and
  `crimson-police:client:builder` `{ event, id }` handling (stop placement/recording for that mission on
  `lockBroken`/`reloaded`/`deleted`). Check `LocalPlayer.state.crimsonArena` before any move (CRIMSON_ARENA 13).
- **Builder screens** (`sup_builder`, `admin_missions` owners): data through `builder:list/get/config` and
  `server:builder:*`; autosave every `autosaveSeconds` while holding the lock; follow `previousId` after a save;
  `err.builder_locked` / push `lockBroken` → reload read-only; errors are shown by `path` (`message` is translated);
  confirm dialogs for publish, archive, rollback, break lock and discard; publish only with `can.publish` and
  `draftTested`. `builder.status.*` and `builder.block.*` labels are in `builder_server.json`.
- **Scoring (owner of `bonus.<id>` / `penalty.<id>`)**: labels for every `Config.Bonuses` id, including
  `penalty.wrong_log` and `penalty.hard_ram` (the builder sends these `labelKey`s and uses them in messages when
  present).
- **shared/net.lua (core)**: a big draft (20 locations with many points) can exceed what one
  `TriggerServerEvent` carries; consider `TriggerLatentServerEvent` in the client `CP.Net.action` for payloads
  over ~8 KB.
- **Locale merge**: keys shared with other parts (`err.in_arena`, `err.internal`, `err.invalid_payload`,
  `err.no_permission`, `err.rate_limited`) use the existing texts verbatim.
