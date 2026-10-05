# teams · notes (units, Cross-Department Missions)

Files: `Crimson-Police/modules/units/{server,client}.lua`, `Crimson-Police/modules/operations/{server,client}.lua`,
`Crimson-Police/web/src/officer/screens/Unit.tsx` (+ `Unit.css`), `Crimson-Police/web/src/supervisor/screens/CrossDept.tsx`,
`Crimson-Police/web/src/supervisor/components/OperationPanel.tsx` (+ `OperationPanel.css`),
`Crimson-Police/web/src/officer/components/ReadyCheckBanner.tsx` (+ `.css`), `Crimson-Police/web/src/types/teams.ts`, `Crimson-Police/web/src/mocks/teams.mock.ts`,
`Crimson-Police/locales/parts/teams.json`, `tests/teams_spec.lua`. Each Lua file's header lists its public API.

## Registered names

| Kind | Name | Payload → reply |
|---|---|---|
| action | `server:unitInvite` | `targetSrc` or `{ targetSrc }` → `{ unitId, expiresIn }` |
| action | `server:unitRespond` | `{ accepted, unitId }` or a bare boolean (newest invite) → `{ unitId, accepted }` |
| action | `server:unitLeave` | — → `{ left = true, abandoned = bool }` |
| callback | `getUnit` | → UnitView + extras (below) |
| action | `server:unitKick` / `server:unitPromote` | `{ targetSrc }` → `{ kicked }` / `{ leader }` (leader; unit not locked) |
| action | `server:unitDisband` | — → `{ disbanded = true }` (leader; unit not locked) |
| action | `server:unitCancelInvite` | `{ targetSrc }` → `{ cancelled }` (inviter or leader; unit not locked) |
| action | `server:unitReady` | `{ accepted }` or a bare boolean → `{ accepted }` (member of a unit with a pending check; the key mapping sends it without a reply id) |
| client event | `crimson-police:client:readyCheck` | `{ typeKey, typeLabel, expiresIn, leaderName }` or nil to clear (every member but the leader) |
| key mapping | `crimsonpolice_ready` | Config.Tablet.readyKey: answers a pending ready check with Ready |
| action | `server:leaveOperation` | — → `{ left = true }` (joined or waitlisted, before the start) |
| action | `server:sup:opRemoveJoiner` / `server:admin:opRemoveJoiner` | `{ src, reason }` (1–200 chars) → `{ removed }` (launchCrossDept; audited `opRemoveJoiner`) |
| action | `server:sup:opLaunch` / `server:admin:opLaunch` | `{ missionId }` → `{ id }` |
| action | `server:sup:opStart` / `server:admin:opStart` | — → `{ runId, participants }` |
| action | `server:sup:opRelaunch` / `server:admin:opRelaunch` | — → `{ id }` |
| action | `server:sup:opCancel` / `server:admin:opCancel` | `{ reason }` (1–200 chars) → `{ id }` |
| action | `server:joinOperation` | `operationId` or `{ operationId }` (nil = the active one) → `{ id, joined, max }` |
| callback | `sup:getOperation` | → OperationView (below) |
| client event | `crimson-police:client:operation` | `(state, missionLabel, extra = { id, relaunched })` |
| push | `unit` | `{ unitId|false, invited?, readyCheck? }` to every member and invitee; `board` to members |
| push | `operation`, `board` | `{ id|false, status|false }` to every online department member (`operation` also to admins) |

Every `server:sup:op*` / `server:admin:op*` handler calls `CP.Permissions.can(src, 'launchCrossDept')` first; the
`admin` ones also require `CP.Access.isAdmin(src)`. `sup:getOperation` checks the same permission. Officer paths
(`getUnit`, unit actions, `server:joinOperation`) call `CP.Access.getOfficer(src)`.

## Response shapes defined here (web types: `src/types/teams.ts`)

**UnitView extras** (`getUnit`): `me` (viewer src), `maxSize`, `inviteTtl` (120), `canInvite`,
`inviteBlocked` (`unit.blocked_on_run` | `unit.blocked_locked` | `unit.blocked_full` | nil), `onRun`,
`unit.size`, `unit.pending = { { src, name, callsign, departmentShort, expiresIn } }`, `members[].available`,
`invites[].size`, `invitable[].inUnit`. `invitable` is only filled while `canInvite`.
Parity additions (design WP5): `unit.canManage` (the viewer leads and the unit is not locked), `unit.readyCheck =
{ typeLabel, expiresIn, ready = { src }, waiting = { src }, waitingForMe }` (nil when none), `members[].avatar`
(CP.Profile.avatarFor when loaded, else initials in the level's frame colour), `members[].level = { n, badge }`,
`invitable[].distanceBand` (0..3 from Config.Units.nearbyBands, server-side ped coordinates only),
`invitable[].lastPartner`, `pendingSent = { { src, name, expiresIn } }` (invites the viewer sent),
`sizeFit = { [type] = { now, plusOne } }` (CP.Draw.pool counts at the unit's size and one bigger, counts only),
`operation` (CP.Operations.officerCard: `{ id, missionLabel, status, joined, max, waitlistPosition, joinEndsIn,
canLeave }` for a joiner or a waitlisted officer). `inviteBlocked` may be `unit.blocked_policy`.

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
`description`, `min`, `runState`, `waitlist` (count), `waitlistPosition`, `waitlistOpen`. `joined` counts joiners
(joining) or active participants (running). A viewer on the waitlist gets `joinBlocked = 'err.op_waitlisted'`; a
full operation gives `err.op_full` only with `Config.CrossDept.waitlist = false`.

**OperationView additions**: `operation.participants[].canRemove`, `operation.waitlist = { { src, name, callsign,
departmentShort, position, canRemove } }`, `operation.waitlistEnabled`.

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
- Inviters in the arena are refused (`err.in_arena`, ARCHITECTURE §0.14 gates invites). Invite targets must be
  on-duty officers (`getOfficer`), not on a run, not in the arena, not in a full unit.
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
  The invitee gets exactly one `unit` push for a new invite, carrying `invited = true`; the units client only adds a
  frontend sound on it. The inviter's expiry toast names the invitee.

### Leader controls and the ready check (CP.Units, design 2.11)
- `kick(src, target)`, `promote(src, target)`, `disband(src)`: the leader only, refused with `err.unit_locked` once a
  type is accepted (the unit is locked from the accept to the run's end). `cancelInvite(src, target)`: the leader or
  the member who sent it; the slot frees at once. A kick never touches runs or cooldowns; the kicked officer can't be
  invited by that unit (its members at the kick and anyone who joins it later) for `Config.Units.kickReinvite` seconds
  (`err.unit_kicked_recently`), and is left out of their invite list meanwhile; a kick from another unit adds its own block. Disband tells members who disbanded and withdraws open invites.
- `Config.Units.invitePolicy = 'leader'`: a member's invite is refused (`err.unit_invite_leader_only`); the member's
  view shows `unit.blocked_policy`.
- `readyCheck(unit, typeKey, onReady, onCancel)` is called by CP.Draw.accept after the lock for units of 2+ (and for a
  mission call's winning claim). It returns false only when no check is needed (no unit, or fewer than 2), so the
  draw follows at once. The leader's accept counts as their answer; every other member gets `client:readyCheck`
  (type only), a toast from the units client and the `unit` push with `readyCheck`. All accepted → `onReady()` once.
  A decline (`err.unit_ready_declined`), the timeout (`Config.Units.readyTimeout`, checked by the 2 s sweep;
  `err.unit_ready_timeout`), or a member leaving, going off duty, disconnecting, entering the arena or taking a real
  call (`err.unit_ready_cancelled`) → `onCancel(reasonKey, srcs)` with the officers who did not answer; everyone asked
  gets a `unit.ready.cancel_*` toast naming them. CP.Draw unlocks the unit on cancel; nobody gets a cooldown. A second
  check for a unit with one pending gets `onCancel('err.busy')` at once, and `unlock` is ignored while a check is
  pending (the check clears itself before `onReady` / `onCancel` run), so that caller can't reopen the unit. The lock
  safety net (LOCK_GRACE) skips a unit with a pending check. An in-arena member answering Ready is refused
  (`err.in_arena`) and cancels the check; the last Ready re-checks every member for the arena before `onReady`.
- `lastPartners(src)`: the online officers of src's last ended run (the `run:ended` hook, test runs ignored,
  remembered 900 s by citizenid).

### Waitlist and leaving an operation (CP.Operations, design 2.11)
- `Config.CrossDept.waitlist` (default true): a join when every place is taken (or while someone waits) queues the
  officer (`{ waitlisted = true, position }`). A place freed before the start (leave, a supervisor's remove, a drop,
  unload or lost access) goes to the first on the list, re-checked like a join (officer, same citizenid, not on a run,
  not in the arena, not on a real call); one who fails is skipped with a toast. The list closes at the start (toast).
- `leave(src)` / `server:leaveOperation`: before the start only, no penalty; after it `err.op_leave_started` (the run's
  own abandon applies). `removeJoiner(src, target, reason)` / `server:<scope>:opRemoveJoiner`: launchCrossDept, a
  reason, before the start only (`err.op_remove_started`), audited as `opRemoveJoiner` (old = "name (citizenid)",
  new = joined | waitlist).
- `officerCard(src)`: the Unit screen card for a joiner or a waitlisted officer.

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
  It opens a new join window with an empty list and is **not** a new launch (the 30-min cooldown and `created_at`
  stay). The launch cooldown counts from the last `created_at` (persisted).
- **Idle auto-cancel** ("auto-cancels after 30 minutes with no run in progress"): the idle clock starts at the launch
  and again when the operation's run ends, is cleared while a run exists, and is **not** reset by a relaunch. The
  cancel fires in `waiting` once `Config.CrossDept.idleCancel` seconds have passed; an open join window is never cut
  short (a relaunch 28 minutes after a fail still gets its full window; if no run starts, it is cancelled as soon as
  the window closes).
- **Join** re-checks the operation state after the checks that may yield (`CP.Calls.isOnCall` can query the
  database), so two joins can never pass the cap together and a join can never land after Start now copied the list.
- The cancel reason is 1–200 **characters** (UTF-8, like the UI's `maxLength`); control characters become spaces;
  invalid UTF-8 is `err.invalid_payload`.
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
- Both screens normalise the callback data first (`asArray` for every list, missing nil fields → `null`), because
  Lua sends an empty list as `{}` and drops nil keys: `invites`, `invitable`, `unit.members`, `unit.pending`,
  `operation.participants`, `operation.departments`, `eligibleMissions` are all empty in common states.
- The locked banner says "leaving abandons your run" only while the viewer is still on the unit's run.
- `OperationPanel` default export, props `{ scope: 'sup' | 'admin' }` (stable). It calls `sup:getOperation` for both
  scopes and `server:<scope>:op*`. It never wraps itself in `<Screen>`.
- With no operation active the panel shows a launch form (eligible missions + cooldown countdown); the Mission List
  and Admin Missions screens may also launch with `server:<scope>:opLaunch { missionId }`.
- Mocks: `?teams=leader|member|solo|invites|locked|lockedoff|long|full` (Unit) and
  `?op=joining|running|waiting|none|cooldown|empty|fresh` (panel); add `&lua=1` to answer like Lua (empty lists as
  `{}` objects, nil fields missing). `server:joinOperation` and `getMissionTypes` are **not** mocked here (the Mission Board slice owns them).

## Deviations / additions to the contract
- `client:operation` carries an optional third argument `extra = { id, relaunched }`.
- UnitView / BoardData.operation / OperationView carry the extra fields listed above (all optional in TS).
- `CP.Units.view`, `CP.Operations.view`, `CP.Operations.cooldownLeft`, `CP.Operations.eligible` are public helpers
  beyond §5.16/§5.17 (used by the callbacks and useful for the Mission List / admin screens).
- Test DB: `tests/teams_spec.lua` runs its SQL on `<run database>_teams` (`CP_TEST_DB` + `_teams`), rebuilt from
  `sql/migrations` and dropped at the end, so neither other specs nor a parallel run of this spec can interfere.

## Requests to other modules
- **runs**: `afterRunEnded → unlockUnit(run)` also runs for operation runs (it unlocks the first joiner's unit);
  Units ignores it safely, but skipping `unlockUnit` when `run.operationId` is set would be cleaner. Keep calling
  `CP.Operations.onRunEnded(run, state)` for `abandoned` (everyone left) too — the operation relies on it (a 60 s
  safety net exists). `create` must keep accepting up to `Config.CrossDept.maxParticipants` members for operation
  runs (no `maxOfficers`/`maxUnitSize` check) and treat `'cancelled'` as a no-cooldown end reason (it does).
- **draw**: keep `CP.Units.lock(unit)` right before the draw and `unlock` on failure (done). A forming unit (leader +
  pending invites) is dissolved by `lock`, so `run.unit` is nil for that leader — expected. **Race:** `accept` reads
  `unitMembers(src)` before the checks that yield (`getOfficer`, hourly cap, cooldowns) and locks afterwards, so an
  invitee who accepts during those yields is in the locked unit but not on the run. Lock the unit before the
  yielding checks (unlock on every failure), or re-read `CP.Units.members(src)` after `lock` and refuse if it changed.
- **Mission Board (web)**: while `BoardData.operation` is set, show only that card: `missionLabel`, `launcher`,
  `status`, `joined`/`max` (+ `min`), `joinEndsIn` countdown, and a Join button (`canJoin`) → `action('server:joinOperation', operation.id)`.
  Refetch on pushes `board`/`operation`. Join errors: `err.op_join_closed`, `err.op_full`, `err.op_already_joined`,
  `err.op_not_found`, `err.in_arena`, `err.already_on_run`, `err.on_call` (all in `teams.json`).
- **Admin Missions (web)**: `import OperationPanel from '../../supervisor/components/OperationPanel'` and render
  `<OperationPanel scope="admin" />` — still missing in `admin/screens/Missions.tsx` at review time, so the Admin UI
  has no launch / start now / relaunch / cancel yet.
- **Supervisor Mission List (web)**: Launch → `action('server:sup:opLaunch', { missionId })` for missions where
  `CP.Operations.eligible(def)` holds (published, open to every department, 2+ officers, not the boss); then
  `navigate('sup_crossdept')`. Launch errors: `err.op_active`, `err.op_cooldown`, `err.op_disabled`,
  `err.op_mission_*`, `err.op_not_ready`.
- **admin**: `CP.Admin.audit` with category `'operations'` and actor `'console'` / role `'console'` for the
  automatic cancel; `CP.Admin.webhook('operations', title, description, fields)` for results.
- **draw** (WP4): `CP.Units.readyCheck` is called after the lock for units of 2+ (done); tests/e2e_spec.lua answers
  every member's Ready at once so its unit scenarios keep drawing synchronously.
- **Officer layout** (WP8): mount `web/src/officer/components/ReadyCheckBanner.tsx` (props optional; it follows the
  `unit` push). The Unit screen already renders it.
- **locale merge**: `teams.json` repeats these shared keys with the owners' exact text: `err.internal`,
  `err.invalid_payload`, `err.no_permission`, `err.not_police`, `err.not_in_game`, `err.rate_limited` (core),
  `err.busy`, `err.in_arena`, `err.already_on_run`, `err.on_call`, `err.no_location`, `err.run_create_failed`,
  `err.unit_locked` (engine_a), `common.no_callsign`, `common.reason`, `common.search`, `common.tier`,
  `ui.screen.unit`, `ui.screen.sup_crossdept` (ui).

## Tests
`lua5.4 tests/run.lua teams` → 632 assertions, 0 failed (409 before the parity build; the WP5 additions cover kick,
make leader, disband and withdraw (leader or inviter only, refused once locked, kick re-invite block, no cooldown), the
leader-only invite policy, the ready check (all accept → onReady once; decline, timeout, leaving, off duty, a real call
and the arena cancel it with who did not answer; the prompt carries the type only; a second check is refused), last
partners (900 s), distance bands from server-side coordinates, sizeFit counts only, member levels and avatars, and
operation leave, remove-joiner (permission, reason, audit) and the waitlist). Covers invites (validation, TTL expiry, decline, forming
units, moving between units, cap with open invites), leader succession, dissolve, lock/unlock (incl. the
member-still-on-run guard and the safety net), leave mid-run (quit) vs operation run, drop/unload/onLost cleanup,
the arena gates; operations: restart cancel, cooldown from the persisted `created_at`, permissions (sup/admin
scopes), eligibility, launch/join/start (run options), fail → waiting → relaunch, window end (auto start / not
enough), everyone left, idle auto-cancel, cancel of a running operation (`cancelled` for every participant),
completion, the vanished-run safety net, the tick thread, the idle clock across a relaunch, the join re-check after
a yielding lookup, reason length in characters, the inviter arena gate, one push per new invite, and every SQL
statement of the slice on MariaDB.
