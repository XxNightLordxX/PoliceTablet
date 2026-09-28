# teams · notes (units, Cross-Department Missions)

Files: `Crimson-Police/modules/units/{server,client}.lua`, `Crimson-Police/modules/operations/{server,client}.lua`,
`Crimson-Police/web/src/officer/screens/Unit.tsx` (+ `Unit.css`), `Crimson-Police/web/src/supervisor/screens/CrossDept.tsx`,
`Crimson-Police/web/src/supervisor/components/OperationPanel.tsx` (+ `OperationPanel.css`),
`Crimson-Police/web/src/types/teams.ts`, `Crimson-Police/web/src/mocks/teams.mock.ts`,
`Crimson-Police/locales/parts/teams.json`, `tests/teams_spec.lua`. Each Lua file's header lists its public API.

## Registered names

| Kind | Name | Payload → reply |
|---|---|---|
| action | `server:unitInvite` | `targetSrc` or `{ targetSrc }` → `{ unitId, expiresIn }` |
| action | `server:unitRespond` | `{ accepted, unitId }` or a bare boolean (newest invite) → `{ unitId, accepted }` |
| action | `server:unitLeave` | — → `{ left = true, abandoned = bool }` |
| callback | `getUnit` | → UnitView + extras (below) |
| action | `server:sup:opLaunch` / `server:admin:opLaunch` | `{ missionId }` → `{ id }` |
| action | `server:sup:opStart` / `server:admin:opStart` | — → `{ runId, participants }` |
| action | `server:sup:opRelaunch` / `server:admin:opRelaunch` | — → `{ id }` |
| action | `server:sup:opCancel` / `server:admin:opCancel` | `{ reason }` (1–200 chars) → `{ id }` |
| action | `server:joinOperation` | `operationId` or `{ operationId }` (nil = the active one) → `{ id, joined, max }` |
| callback | `sup:getOperation` | → OperationView (below) |
| client event | `crimson-police:client:operation` | `(state, missionLabel, extra = { id, relaunched })` |
| push | `unit` | `{ unitId|false, invited? }` to every member and invitee; `board` to members |
| push | `operation`, `board` | `{ id|false, status|false }` to every online department member (`operation` also to admins) |

Every `server:sup:op*` / `server:admin:op*` handler calls `CP.Permissions.can(src, 'launchCrossDept')` first; the
`admin` ones also require `CP.Access.isAdmin(src)`. `sup:getOperation` checks the same permission. Officer paths
(`getUnit`, unit actions, `server:joinOperation`) call `CP.Access.getOfficer(src)`.

## Response shapes defined here (web types: `src/types/teams.ts`)

**UnitView extras** (`getUnit`): `me` (viewer src), `maxSize`, `inviteTtl` (120), `canInvite`,
`inviteBlocked` (`unit.blocked_on_run` | `unit.blocked_locked` | `unit.blocked_full` | nil), `onRun`,
`unit.size`, `unit.pending = { { src, name, callsign, departmentShort, expiresIn } }`, `members[].available`,
`invites[].size`, `invitable[].inUnit`. `invitable` is only filled while `canInvite`.

**OperationView** (`sup:getOperation`):
```
{ operation = nil | { id, missionId, missionLabel, missionType, missionTypeLabel, difficulty,
    launcher, launcherCallsign, launcherDepartment, launchedAt, status = 'joining'|'running'|'waiting',
    runState = 'accepted'|'in_progress'|nil, runId,
    participants = { { src, name, callsign, departmentShort, department, status = 'joined'|'active'|'left'|'waiting', arrived } },
    departments = { { short, count } }, joined, max, min, joinEndsIn, idleCancelIn, tier, tierExpected, remaining,
    waitingReason = 'failed'|'abandoned'|'not_enough'|'no_location'|'start_failed'|nil, attempt,
    canStart, startBlocked (sup.crossdept.start_blocked_* | nil), canRelaunch, canCancel },
  cooldownLeft, cooldown, joinWindow, idleCancel, maxParticipants, crossBonus, enabled, canLaunch,
  launchBlocked (err.* | nil), serverTime,
  eligibleMissions = { { id, label, type, typeLabel, difficulty, minOfficers, maxOfficers } }  -- only with no operation }
```

**BoardData.operation** (`CP.Operations.boardCard`): the §9.4 fields plus `missionType`, `missionTypeLabel`,
`description`, `min`, `runState`. `joined` counts joiners (joining) or active participants (running).

## Contract interpretations

### CP.Units
- Units live in memory only (nothing to store; a restart drops them, as it drops runs).
- A **forming unit** is the first inviter plus pending invites. `unitOf(leader)` returns it and `members` is `{ leader }`.
  It dissolves silently when its last invite expires or is declined, and at `lock` (the leader goes solo).
- **Any member may invite**, not only the leader (the spec: "any officer or supervisor can invite"). The cap is
  `members + open invites < Config.Limits.maxUnitSize`, so an accepted invite always fits.
- Invites expire after `INVITE_TTL = 120` s (constant in the file header). One open invite per (unit, target).
  Joining a unit drops the other open invites to that officer. Accepting while in another (unlocked) unit moves
  the officer (the old unit gets its normal leave handling).
- Invite targets must be on-duty officers (`getOfficer`), not on a run, not in the arena, not in a full unit.
  Accepting refuses in-arena players with `err.in_arena` (CRIMSON_ARENA rule 5), players on a run, full and locked units.
- **Leader succession**: `members` is kept in join order; when the leader leaves, `members[1]` (longest-standing)
  leads. A unit left with one member dissolves. Invites of the unit stay open when the leader changes.
- `lock(unit)` closes invites (pending ones are withdrawn with a toast). `unlock(unit)` accepts a unit table or id
  and is **ignored while a member is still an active participant of a normal run** (no operationId, no test):
  CP.Runs stores `run.unit = unitOf(leader)` for every non-test run, operation runs included, so an operation run
  led by someone whose unit is locked for another run must not reopen it. Safety net: a unit locked for 30 s
  (`LOCK_GRACE`) with nobody on a normal run is unlocked by the 2 s sweep.
- `server:unitLeave` while the unit is locked and the leaver is on a normal run → `CP.Runs.removeParticipant(run, src, 'quit')`
  (Abandoned, type cooldown), then the member leaves the unit. Leaving while on an operation/test run leaves that run alone.
- `remove(src)` never touches runs. playerDropped / `CP.Qbx.onPlayerUnload` / `CP.Access.onLost` call it (runs
  itself ends the run as disconnected / off_duty / job_change / suspended); invites to that player are cancelled.
- The leave action calls `getOfficer` (rule 7) but still lets a player who no longer qualifies leave their unit.
- The invite toast is `CP.Tablet.notify(target, 'info', 'unit.invite_received', …, { title = 'unit.invite_title' })`.
  The units client only adds a frontend sound when the `unit` push for that player carries `invited = true`.

### CP.Operations
- Status machine and board lock as in the file header. `isLocked()` is true for joining, running and waiting.
- **Minimum to start** = max(`Config.CrossDept.minParticipants`, mission `minOfficers`), so a mission that needs 3 is
  never started with 2. **Maximum** = `Config.CrossDept.maxParticipants` (ops take up to 8 whatever `maxOfficers` says).
- **Start now** is allowed for whoever opened the current join window (launch or relaunch), any admin, or anyone
  with the permission when that person is offline (the spec says "the launcher taps Start now"; nobody gets stuck).
  At the join-window end the run starts by itself with enough participants, else the operation goes to `waiting`
  (`not_enough`). A manual start that fails (too few, no location) keeps the window open.
- At start every joiner is re-checked (officer, same citizenid, not on a run, not in the arena, not on a real call);
  those who fail are dropped with a toast. The location comes from `CP.Draw.pickLocation(def, srcs, CP.U.rng(seed))`,
  the run from `CP.Runs.create({ mission, locationIndex, missionType = def.type, members = officers (join order),
  leaderSrc = first joiner, operationId, isBoss = false })`. Cooldowns, no-repeat, hourly cap, server cap and the
  modifier are left to CP.Runs / CP.Events (they read `operationId`).
- **Relaunch** is only possible in `waiting` (after a fail, everyone left, or a window that closed without a start).
  It opens a new join window with an empty list, is **not** a new launch (the 30-min cooldown and `created_at` stay),
  and resets the idle timer. The launch cooldown counts from the last `created_at` (persisted).
- **Idle auto-cancel** applies in `waiting`: `Config.CrossDept.idleCancel` seconds after the last run ended, the join
  window closed, or the last relaunch. Joining never auto-cancels (the window itself is at most `joinWindow`).
- **Cancel** needs a reason (1–200 characters, shown to participants). The lock lifts at once; everyone still on the
  run gets `CP.Runs.removeParticipant(run, src, 'cancelled')`. The auto-cancel reason is `sup.crossdept.reason_idle`
  (audited as `opAutoCancel` by `'console'`).
- `onRunEnded(run, state)`: `completed` → `completed` (final, lock lifts, `client:operation 'ended'`); anything
  else → `waiting` (`failed`, or `abandoned` when every participant left). A run of another id is ignored. If a
  running operation's run disappears without a report for 60 s, it is treated as failed.
- Restart safety: at start `UPDATE cp_operations SET status = 'cancelled', ended_at = … WHERE status IN ('joining','running','waiting')`.
- Launch requires `Config.CrossDept.enabled ~= false`, no active operation, the cooldown over, and an eligible
  mission (`CP.Operations.eligible`: published and `CP.Missions.isEnabled`, `departments` empty, `maxOfficers >= 2`,
  never `weekly_boss_kingpin`/`isBoss`). `launched_by` = the actor's citizenid (admins not on duty use their character's).
- Notifications: `client:operation` (`launched` incl. relaunch with `extra.relaunched = true`, `started`, `ended`,
  `cancelled`) to every on-duty officer (the operations client turns it into the toast); pushes `operation` + `board`
  on every change (joins included); `CP.Tablet.notify` to participants (started / cancelled with reason / dropped at
  start) and to everyone with `launchCrossDept` when the operation goes to `waiting`. `failed`/`abandoned` have no
  `client:operation` state in the contract, so officers only get the board push.
- Audit (`CP.Admin.audit(actor, role, 'operations', action, target, old, new, reason)`): `opLaunch` (new = mission id),
  `opStart` (old = attempt, new = participants), `opRelaunch` (old = previous waiting reason, new = attempt),
  `opCancel` / `opAutoCancel` (old = status, reason). Target `#<id> <missionId>`. Role `admin` for admins, else
  `supervisor`; the automatic cancel uses actor and role `console`. Results without an actor (automatic start,
  completed, failed, abandoned) go to `CP.Admin.webhook('operations', title, text, fields)` with Discord-style
  fields `{ name, value, inline }`.
- Every DB status write is queued in order on one worker thread (never blocks the state machine); the launch insert
  is synchronous (it needs the id). Times are written with `FROM_UNIXTIME(os.time())`, read with `UNIX_TIMESTAMP`.

### Web
- `OperationPanel` default export, props `{ scope: 'sup' | 'admin' }` (stable). It calls `sup:getOperation` for both
  scopes and `server:<scope>:op*`. It never wraps itself in `<Screen>`.
- With no operation active the panel shows a launch form (eligible missions + cooldown countdown); the Mission List
  and Admin Missions screens may also launch with `server:<scope>:opLaunch { missionId }`.
- Mocks: `?teams=leader|member|solo|invites|locked` (Unit) and `?op=joining|running|waiting|none|cooldown|empty`
  (panel). `server:joinOperation` and `getMissionTypes` are **not** mocked here (the Mission Board slice owns them).

## Deviations / additions to the contract
- `client:operation` carries an optional third argument `extra = { id, relaunched }`.
- UnitView / BoardData.operation / OperationView carry the extra fields listed above (all optional in TS).
- `CP.Units.view`, `CP.Operations.view`, `CP.Operations.cooldownLeft`, `CP.Operations.eligible` are public helpers
  beyond §5.16/§5.17 (used by the callbacks and useful for the Mission List / admin screens).
- Test DB: `tests/teams_spec.lua` runs its SQL on `cp_test_teams`, rebuilt from `sql/migrations` exactly like
  `cp_test` (same pattern as `engine_a_spec`), so a parallel `tests/run.lua` that drops `cp_test` cannot break it.

## Requests to other modules
- **runs**: `afterRunEnded → unlockUnit(run)` also runs for operation runs (it unlocks the first joiner's unit);
  Units ignores it safely, but skipping `unlockUnit` when `run.operationId` is set would be cleaner. Keep calling
  `CP.Operations.onRunEnded(run, state)` for `abandoned` (everyone left) too — the operation relies on it (a 60 s
  safety net exists). `create` must keep accepting up to `Config.CrossDept.maxParticipants` members for operation
  runs (no `maxOfficers`/`maxUnitSize` check) and treat `'cancelled'` as a no-cooldown end reason (it does).
- **draw**: keep `CP.Units.lock(unit)` right before the draw and `unlock` on failure (done). A forming unit (leader +
  pending invites) is dissolved by `lock`, so `run.unit` is nil for that leader — expected.
- **Mission Board (web)**: while `BoardData.operation` is set, show only that card: `missionLabel`, `launcher`,
  `status`, `joined`/`max` (+ `min`), `joinEndsIn` countdown, and a Join button (`canJoin`) → `action('server:joinOperation', operation.id)`.
  Refetch on pushes `board`/`operation`. Join errors: `err.op_join_closed`, `err.op_full`, `err.op_already_joined`,
  `err.op_not_found`, `err.in_arena`, `err.already_on_run`, `err.on_call` (all in `teams.json`).
- **Admin Missions (web)**: `import OperationPanel from '../../supervisor/components/OperationPanel'` and render
  `<OperationPanel scope="admin" />`.
- **Supervisor Mission List (web)**: Launch → `action('server:sup:opLaunch', { missionId })` for missions where
  `CP.Operations.eligible(def)` holds (published, open to every department, 2+ officers, not the boss); then
  `navigate('sup_crossdept')`. Launch errors: `err.op_active`, `err.op_cooldown`, `err.op_disabled`,
  `err.op_mission_*`, `err.op_not_ready`.
- **admin**: `CP.Admin.audit` with category `'operations'` and actor `'console'` / role `'console'` for the
  automatic cancel; `CP.Admin.webhook('operations', title, description, fields)` for results.
- **locale merge**: `teams.json` repeats these shared keys with the owners' exact text: `err.internal`,
  `err.invalid_payload`, `err.no_permission`, `err.not_police`, `err.not_in_game`, `err.rate_limited` (core),
  `err.busy`, `err.in_arena`, `err.already_on_run`, `err.on_call`, `err.no_location`, `err.run_create_failed`,
  `err.unit_locked` (engine_a), `common.no_callsign`, `common.reason`, `common.search`, `common.tier`,
  `ui.screen.unit`, `ui.screen.sup_crossdept` (ui).

## Tests
`lua5.4 tests/run.lua teams` → 385 assertions, 0 failed. Covers invites (validation, TTL expiry, decline, forming
units, moving between units, cap with open invites), leader succession, dissolve, lock/unlock (incl. the
member-still-on-run guard and the safety net), leave mid-run (quit) vs operation run, drop/unload/onLost cleanup,
the arena gates; operations: restart cancel, cooldown from the persisted `created_at`, permissions (sup/admin
scopes), eligibility, launch/join/start (run options), fail → waiting → relaunch, window end (auto start / not
enough), everyone left, idle auto-cancel, cancel of a running operation (`cancelled` for every participant),
completion, the vanished-run safety net, the tick thread, and every SQL statement of the slice on MariaDB.
