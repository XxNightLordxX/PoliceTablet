# testing · notes (Admin test mode)

Files: `modules/testing/server.lua`, `modules/testing/client.lua`, `web/src/admin/screens/Testing.tsx` (+ `.css`),
`web/src/hud/TestControls.tsx` (+ `.css`), `web/src/hud/DebugOverlay.tsx` (+ `.css`), `web/src/types/testing.ts`,
`web/src/mocks/testing.mock.ts`, `locales/parts/testing.json`, `tests/testing_spec.lua`.
Each Lua file's header lists its public API; the TypeScript shapes are in `web/src/types/testing.ts`.

## Flow: invite first, then Start

`CP.Runs.create` takes every member up front and has no "add participant" API, so nobody can join a
test once it has started. The flow is therefore:

1. The admin opens **Start a test** (Admin UI → Testing), picks mission, location (index or Random), tier
   (Auto or Standard…Critical, default = the tier the mission's `maxOfficers` reaches) and the start route
   (default `Config.Testing.useStartRoute`).
2. Optional: select testers (callback `test:candidates`: online on-duty officers and admins) and
   **Invite** (`server:test:invite { missionId, targets }`). Each invitee gets `client:testInvite`
   (toast "… Press F9 to answer") and answers either on the Admin UI Testing screen (banner) or, anywhere,
   with the F9 invitation prompt (`hud/DebugOverlay.tsx`, NUI focus only while it is open) →
   `server:testRespond { inviteId, accepted }`. The admin's dialog updates live (push `invites`).
3. **Start** (`server:admin:startTest { …, testers = accepted srcs }`) re-validates every tester and calls
   `CP.Runs.create`. Unanswered invitations are withdrawn.

`/CrimsonPoliceAdmin test <missionId> [tier] [location]` → `CP.Testing.command(src, args)` uses the accepted
invitations of the same mission as testers.

Invitations: one lobby per admin (one mission). Unanswered invitations expire after 120 s, accepted ones
after 15 min without a start; inviting for another mission withdraws the old lobby (accepted testers are told).
Seats: `Config.Testing.maxTesters - 1` (pending + accepted) besides the admin.

## Contract interpretations

- **Admin participant record.** Admins need not be police. `CP.Access.getOfficer(src)` is used when the admin
  is an on-duty officer (then the normal job/duty re-checks apply); otherwise the record is built from
  `CP.Qbx.getInfo` with `department` = the department of the admin's active job if it belongs to one, else
  the **first `Config.Departments` key in sorted order** (`CP.Access.departments()[1]`), rank = the job grade
  name for a department job or `test.admin_rank`, and `job = nil` so `CP.Runs` marks the participant as a
  non-officer (`isOfficer = false`) and skips duty/job re-checks. Invited admins get the same record.
- **Tier.** A chosen tier becomes `test.forcedTier` (no rescale when someone leaves). "Auto"/omitted passes
  `forcedTier = nil`: normal scaling by the number of testers, including rescaling. The recorded tier is the
  forced tier, else the run's tier at the end.
- **Location.** A chosen index that another run holds is refused (`err.test_location_busy`) so a test never
  spawns on top of a live run; Random uses `CP.Draw.pickLocation(def, srcs, CP.U.rng(seed))` (reserved spots
  and the player clearance skipped), falling back to a seeded pick of the unreserved spots. The run itself
  reserves the location through `CP.Runs.create` → `CP.Draw.reserve`.
- **Gates.** `testRun` permission, `Config.Testing.enabled`, `CP.Alerts.inArena` for the admin and every
  tester (Crimson-Arena rule 5; also for inviting and for accepting), not already on a run, one test per admin
  (`err.test_already_running`), 2 s between start attempts. Cooldowns, the hourly cap, the server caps and the
  Cross-Department lock are never checked (and `CP.Runs` skips them for tests).
- **Any mission.** `CP.Missions.get(id)` whatever its status (built-in, custom, `Config.DisabledMissions`).
  Archived custom missions are unregistered from `CP.Missions`, so they come from `CP.Builder.getArchived(id)`
  (catalog: `CP.Builder.archivedDefs()`), else from `missions/custom/archived/<id>.lua` through
  `CP.Missions.parse` + `normalize` when those exist (see requests).
- **Controls** (`server:test:control`, only `run.test.adminSrc`): `skip` → `CP.Runs.testSkip`, `restart` →
  `CP.Runs.testRestart` (both only In progress), `pause`/`resume` → `CP.Runs.pauseTimer`, `complete` →
  `CP.Runs.endRun(run, 'completed', 'completed')`, `fail` → `CP.Runs.failRun(run, 'test.fail_forced')`
  (= `endRun(run, 'failed', 'mission_failed')` with a failReason the HUD shows), **`end` →
  `CP.Runs.failRun(run, 'test.ended_by_admin')`**: the `cancelled` end reason was not used because the run
  client's end text for it is "the Cross-Department Mission was cancelled"; the result screen of an ended test
  is irrelevant anyway and cleanup is identical. `teleport { target = 'start'|'objective' }` returns
  `{ coords }` (start coords or `CP.Runs.anchor(run)`), refused for an in-arena admin (rule 13) and when
  `Config.Testing.allowTeleport = false`; the client re-checks `LocalPlayer.state.crimsonArena` before
  `SetEntityCoords` (the vehicle when driving) with a ground-z probe. `debug { enabled? }` toggles the stream
  (refused when `Config.Testing.debugOverlay = false`). Complete/fail/end are audited (`testControl`).
- **Debug stream** (every 2 s while on, to the admin only): `client:test { controls = true, runId, debug }`,
  `debug` = `TestDebugData` (objective, counts vs `Config.Limits.maxEntities`/`maxArmedAlive` read at call
  time, armed alive = armed, not dead, not cuffed via `CP.Npc.isNeutralised` when present, spawn point /
  waypoint / zone counts, start radius, AI host, timer) plus `geometry` (start, points, routes, zones) only
  when the state or objective changed. Geometry: every location key except `label`, `start`, `medals`: vec3/vec4
  → point, list of vectors or `{ coords }` → points (also a route when an objective names it in
  `checkpoints`/`route`/`routes`/`fleeTo`), `{ points, loop }` → road route, list of lists → routes; zones =
  presence (anchor + `presenceRange`), `safe`/`safeRadius`, `center`/`startRadius`, `blockTraffic` around the
  start; the current checkpoint radius is attached to its points. Caps: 240 points, 16 routes, 1200 waypoints.
- **Debug data to the NUI** goes through `CP.Tablet.push('test', { controls, focused, key, debugOn, runId,
  debug })` — the path the foundation's App already wires into `<DebugOverlay debug>` — not through
  `CP.Tablet.hud({ debug })` (which would resend the whole HUD every 2 s). DebugOverlay still reads `hud.debug`
  as a fallback. The in-world markers are drawn by the Lua client (only within 250 m, only while within 600 m of
  the test area, otherwise the loop sleeps 500 ms).
- **HUD flag.** The run client already sets `testControls` at `client:start`; this client re-asserts it with
  `CP.Tablet.hud({ testControls = true })` only while `CP.Runs.current().id` is the admin's run (it never
  creates a HUD of its own), and again at `client:inProgress`.
- **Panel focus.** `+crimsonpolice_testpanel` (default F9): with controls → `SetNuiFocus(true, true)` for the
  HUD panel; without → the invitation prompt when invitations wait. Never while a Crimson-Police UI is open.
  Released by F9/Escape in the NUI (client action `testPanel { open = false }`), when the test ends or this
  player leaves the run, on a foreign crimsonArena value, and on resource stop — only when this module took it.
- **Result screen.** Test runs keep going through `CP.Runs` settle, which returns the RunResult with
  `test = true` (what the run would have earned) and writes nothing.
- **Recording.** Only for a test that this admin (citizenid) actually ran in the last 6 h (a "waiting for a
  result" entry created by `onRunEnded`); tier, testers, def_hash and version come from that test, not the
  payload (`err.test_not_run` otherwise; the optional payload tier must match). One record per test.
  `cp_mission_tests` gets `def_hash` = the mission's `defHash` at test start, `mission_version` for custom
  missions/drafts. Notes are trimmed and clipped to 255 bytes on a UTF-8 boundary (fits VARCHAR(255) whatever
  the connection charset). Audited (`recordTest` / `recordDraftTest`, category `audit`) and posted with
  `CP.Admin.webhook('builder', title, description, fields)`.
- **Catalog "Changed since test".** The last row per (mission, location) (`MAX(id)`) is "changed" when its
  `def_hash` differs from the mission's current `defHash`, when it has no `def_hash` (rows from before
  migration 002), or (custom missions) when its `mission_version` differs from the current version.
- **Drafts.** `startDraft(src, def, opts)` accepts `builderEdit` (or `testRun`), normalises `def` with
  `CP.Missions.normalize(def, { source = 'custom', version = def.version, status = 'draft' })` and starts with
  `test.draft = true`. Recording a draft result (`server:admin:recordTest` or its alias `server:test:record`,
  permission `builderEdit`/`testRun`) writes `cp_mission_tests` too and calls
  `CP.Builder.onDraftTested(missionId, version, tierName, passed, src)`.
- **The admin leaves.** When the admin who started a test disconnects, the test ends for everyone
  (`failRun(run, 'test.ended_admin_left')`); their "waiting for a result" entries are kept by citizenid.
- **Audit of starts**: `CP.Admin.audit(src, role, 'audit', 'testStart'|'testDraft', '<missionId>#<loc>', nil,
  '<tier> x<testers>[ route]', nil)`.

## Response shapes (defined here)

- `admin:getTests` → `TestsView { missions: TestMissionRow[], totals, tiers, config, serverTime }`;
  `TestMissionRow { id, label, type, typeLabel, source, status, disabled, isBoss, version|false, minOfficers,
  maxOfficers, maxTier, defHash, editedInCode, locations: TestLocationRow[], summary }`;
  `TestLocationRow { index, label, reserved, active, status: passed|failed|untested|changed, last: false |
  { id, result, tier, testers, note|false, testedBy, testedByName, testedAt, version|false, changed, tests } }`.
- `test:state` → `TestState { lobby: TestLobby, active: TestActive|false, pending: TestPendingRecord[],
  invites: TestInvite[], serverTime }`.
- `test:candidates` → `TestCandidate[] { src, name, callsign|false, rank|false, departmentShort|false,
  role: officer|admin, admin, onRun, inArena, invite: status|false }`.
- `test:pendingInvites` → `TestInvite[] { inviteId, missionId, missionLabel, from, fromCallsign|false, expiresIn }`.
- `server:test:invite` → `{ lobby, skipped: { src, error }[] }`; `server:admin:startTest` → `{ runId, missionId,
  locationIndex, tier, testers }`; `server:admin:recordTest` → `{ id, missionId, location, tier, result, draft }`;
  `server:test:control` → `{ control, … }` (`paused`, `coords`/`target`, `debug`, `objectiveIndex`).
- `client:test { controls, runId, debug = false | TestDebugData (+ geometry) }`,
  `client:testInvite { inviteId, missionLabel, from, expiresIn }`.
- NUI push `test` from the Lua client: `TestPush { controls, focused, key, debugOn, runId, debug?, prompt? }`;
  server pushes `test { state = true }` and `invites { test = true }` (screen refetch triggers).
- Lua `false` stands for "no value" in every shape (a Lua table cannot hold nil); lists may arrive as `{}`.

## Requests to other modules

- **CP.Builder** (builder_server):
  - `getArchived(id) -> def|nil` and `archivedDefs() -> { def, ... }` (normalised with loader fields,
    `status = 'archived'`), so archived custom missions can be tested and appear in the catalog. Until then an
    archived mission is only testable through `CP.Missions.parse` of `missions/custom/archived/<id>.lua`.
  - `server:builder:test` should pass `CP.Testing.startDraft` the draft **in mission-file units** (fractions,
    milliseconds — what `CP.Missions.normalize` accepts), with `def.version` = the draft version.
  - Record draft results through `server:test:record { missionId, location, tier, result, note }` (Supervisor
    UI) — it calls `onDraftTested` — or call `CP.Testing.record(src, payload)` from your own action. For tester
    invitations on drafts use `CP.Testing.invite(src, targets, { missionId, missionLabel, draft = true })`.
- **CP.Admin** (admin): `/CrimsonPoliceAdmin test <missionId> [tier] [location]` → `CP.Testing.command(src,
  { missionId, tier?, location? })` (returns `ok, data|errKey`; the caller shows the toast/console line).
  `audit(...)` with category `audit` and `webhook('builder', title, description, fields)` where fields are
  `{ { name, value, inline } }`.
- **CP.Missions** (engine_a): `parse(luaSource, chunkName)` from ARCHITECTURE §5.6 is not implemented yet
  (used for archived files, guarded).
- **Officer UI owners** (Unit / Home screens): optionally list `test:pendingInvites` (push topic `invites`) with
  Accept/Decline → `server:testRespond { inviteId, accepted }`; the F9 prompt already covers officers.
- **CP.Runs** (engine_b): nothing required. Error keys it may return from `create` (`err.invalid_mission`, …) are
  passed through only when they exist in the locale, else `err.test_start_failed`.

## Verification

- `luac5.4 -p` on both Lua files.
- `lua5.4 tests/run.lua testing`: 270 assertions (gates, invitations, arena gates, controls, teleport, debug
  stream and geometry, end hook, recording with SQL on MariaDB, the catalog query with "Changed since test",
  archived missions, the command, drafts and `onDraftTested`, invitation expiry, the CP.Net wrappers, locale
  coverage, and the client: key mapping, focus, prompt, HUD flag, teleport arena re-check, debug data, arena
  flag handler).
- `npx tsc --noEmit` clean; build into a private dir; screenshots `testing-*.png` (1920×1080 and 1280×720).
