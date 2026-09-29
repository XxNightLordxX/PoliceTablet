# oversight · notes (admin, disputes, anticheat + supervisor/admin oversight screens)

Files: `modules/admin/server.lua`, `modules/disputes/server.lua`, `modules/anticheat/server.lua`,
`web/src/supervisor/screens/{MissionList,LiveMissions,ReviewQueue}.tsx` (+ `.css`),
`web/src/admin/screens/{Officers,Departments,Permissions,Audit}.tsx` (+ `.css`), `web/src/types/oversight.ts`,
`web/src/mocks/oversight.mock.ts`, `locales/parts/oversight.json`, `tests/oversight_spec.lua`.
Each Lua file's header comment documents its public API, net names and rules.

## Contract interpretations

### CP.Admin
- **audit roles.** `cp_audit.role` is `ENUM('supervisor','admin','console')`. Any other role passed in (CP.Calls passes
  `'officer'`, automatic entries may pass nil) is stored as `'console'`, which therefore means "console or automatic".
  A numeric actor becomes the player's citizenid (`player:<src>` without a character); `0`/`'console'` → `console`.
- **audit categories.** `'board'` is not in the enum: stored as `'audit'`, posted to the board webhook. Unknown
  categories are stored as `'audit'`.
- **audit outside a coroutine** (e.g. called from a non-yielding place) writes from a new thread and returns nil.
- **Every audit posts its category webhook** (embed: action label, who, role, target, old → new, reason).
- **Webhooks:** convar read at call time; only `https://` urls (others are off with one warning). Queue: one post
  per url every 2.1 s, 429 `retry_after` honoured, 5xx/network errors retried up to 3 times, 100 jobs max
  (oldest dropped). Embed title ≤ 256, description ≤ 3500, ≤ 20 fields (value ≤ 1000); empty fields dropped.
- **Who audits what (no double entries):** CP.Payouts (setType/setMission), CP.Scoring.manualAward, CP.Challenge
  (seasons, bounty), CP.Testing (test start/controls/results), CP.Missions' own `server:admin:reloadMissions`
  audit themselves. CP.Admin audits: the `/CrimsonPoliceAdmin reload` path (`reloadMissions`), suspensions
  (`suspend`/`unsuspend`, command and UI), `forceRecall`, `approveFlagged`, `voidFlagged`, `voidRun`.
  CP.Disputes audits `disputeApproved`/`disputeRejected`; CP.AntiCheat audits `runFlagged` and `autoSuspend`.
- **Console payout commands** pass `role = 'admin'` to `CP.Payouts.setType` (the console acts with admin
  authority; CP.Payouts stores the audit role `console` for src 0 itself).
- **Command citizenids** are resolved to the stored spelling (`cp_officers` has a case-insensitive collation),
  else an online player with that exact or upper-case id; unknown → `err.unknown_officer`.
- **Command replies:** console `print` (coloured), in game `CP.Tablet.notify`. The command is registered with
  `restricted = false`; the ace is checked in code (`CP.Access.isAdmin`) so console and players both work.
  `test` is in game only (`err.not_in_game`), refuses in-arena admins (`err.in_arena`); `[tier] [location]` may come
  in any order (`random` or a location number within the mission's locations).
- **Manual award range:** 1–10,000 points per award (typo guard; `final_points` is SMALLINT). Same as CP.Scoring.
- **Approve** clears `flagged` (keeps `flag_reason`) and sets the breakdown's `$.flagged` to JSON null, then
  `CP.Cash.release` (only when `cash_status = 'held'`), `CP.Scoring.onRowApproved`, `CP.Leaderboard.invalidate`.
- **Void** sets `voided = 1` (a flagged row stays flagged: its cash stays held until CP.Cash forfeits it), then
  `CP.Scoring.onRowVoided`, `CP.AntiCheat.onVoided(citizenid)` (mission rows only, never manual_award/goal),
  invalidate. `voidRun` by run uuid voids every non-voided row of that run.
- **Supervisor scope ("runs involving their department")** = any row of that run_uuid (or live participant) in
  their department, checked with `CP.Permissions.can(src, action, { departments = list })`. The own-run rule is
  checked separately with `CP.Permissions.canReviewRun` for every reviewer, admins included.
- **Force recall** takes an optional reason (audited); allowed for runs involving their department (any
  participant ever on the run), tests included; the recalled officer gets `admin.notice.force_recalled` through
  `CP.Runs.removeParticipant(..., { notify = ... })`.
- **Read permissions:** `getMissionList` / `sup:getLiveRuns` need `viewMissionList` (supervisors and admins);
  `sup:getReviewQueue` needs `reviewFlagged` or `handleDisputes` (each list only when its switch is on); every
  `admin:*` callback needs the admin-only `openAdmin` permission.
- **Supervisor UI scope for admins:** an admin with an officer character sees their own department there; an
  admin without one sees every department.

### CP.Disputes
- One dispute per row **ever**: an open one → `err.dispute_open`, a decided one → `err.dispute_final` ("decision
  final"). Kind priority when filing: voided > flagged > failed. Manual awards and goal rows are never disputable.
  Only the officer's own rows (`CP.Access.getOfficer` must pass: on duty). 3 filings per minute per officer.
- The window is measured from the row's `created_at` (`Config.Disputes.windowHours`, read at call time).
- Answer: claim first (`status = 'open'` guard), then apply. A failing manual award re-opens the dispute.
  Approving a flagged row goes through `CP.Admin.approveFlagged(src, rowId, reason, { skipPermission, noAudit })`
  (the dispute permission was checked; one audit entry `disputeApproved`). Approving a voided row sets
  `voided = 0, flagged = 0`, `CP.Scoring.onRowApproved`, `CP.Cash.release` when held/pending. Rejecting a voided
  row forfeits held/pending cash (`CP.Cash.forfeit`); rejecting a flagged row keeps it flagged in the queue.
- The supervisor endpoint refuses failed-run (admin) disputes; the admin endpoint answers any kind.
- `admin:getDisputes` (listed in §8.3 without an owner) is registered here: `{ disputes = forAdmin(own citizenid) }`.
- New disputes toast online supervisors of the run's departments (not participants) or online admins
  (`admin.notice.new_dispute`) and post to the flags webhook. A flagged/voided-run dispute whose run every online
  supervisor of those departments took part in (none of them may answer it; no other one online, on or off duty)
  toasts the online admins instead.

### CP.AntiCheat
- **checkEvent** (after CP.Runs' own checks): in-progress run, active participant, not in arena (`err.in_arena`,
  never flagged, speed position dropped), 10 events/s per src, index = current objective. A later index flags the
  run `unexpected_event` (the client can never legitimately be ahead of the server); an earlier or finished one is
  dropped as lag (`err.stale_event`). Exact duplicates (same objective, same evidence apart from `coords`/`time`,
  keys sorted) within 1 s are dropped (`err.duplicate_event`); blocks' `try`/`seq` counters keep retries distinct.
- **Speed:** server-side ped coords at each accepted event; `distance / max(1 s, elapsed) > Config.AntiCheat.maxSpeed`
  flags the **whole run** `speed` (the spec: "flags the run"). Pairs across a routing-bucket change are discarded
  (bucket stored with the position, plus a 1 s sweep that drops positions of srcs in another bucket/arena).
- **Flags:** the first reason stays on `run.flagged` / `p.flagged`; every distinct (reason, participant) is also
  written to cp_audit (`runFlagged`, target = run id, old_value = citizenid for a personal flag, new_value =
  reason, reason = detail) — that is where the Review Queue reads "who" (e.g. the outside killer) and extra reasons.
  Test runs are never flagged.
- **presenceOk** also records the failing participant's `presence` flag with its share as detail (once); CP.Runs'
  own presence fallback then sees `p.flagged` already set.
- **Presence sampling** every 5 s for in-progress runs with `#run.order >= 2`, only for the current active
  objective, with a read-only ctx built like §7.1 (the engine's ctx is private). Fallback distance: location start;
  fallback range: `Config.Blocks[block].presenceRange[3]`, then `Config.AntiCheat.presenceRadius`.
- **Idle check** once per run at `startedAt + Config.AntiCheat.idleCheck`: active participants with `arrived ~= true`
  are removed with `'idle'` (toast `admin.anticheat.idle_notice`).
- **Voids → suspension:** counts voided mission rows created within `voidWindowDays`, but only those created after
  the officer's last `autoSuspend` audit entry (so the same voids never suspend twice); no new suspension while one
  is active. `CP.Access.suspend(citizenid, suspendDays, 0, 'auto')` + audit `autoSuspend` (role console).

### UI
- Supervisor screens poll: Mission List 20 s (+ push `operation`), Live Missions 10 s, Review Queue 30 s.
- Mission List "Launch" calls `server:sup:opLaunch { missionId }` (CP.Operations) and opens `sup_crossdept`.
- Review Queue shows `flag.<reason>` labels, the recorded detail, other reasons, held points/cash; details dialog.
- Officers: void from the history uses `server:admin:voidRun { rowId, reason }`; suspend/unsuspend require a
  reason in the UI (the console command's reason is optional).
- Departments: the theme preview is the department's `--cp-*` set (`themeVars`) on a mini tablet, read-only.
- Audit dates are `YYYY-MM-DD` strings (server local days); the server also accepts unix seconds.

### Review pass (adversarial review)
- **Own run = also a live run.** A participant's row is written only when they leave, so a supervisor still ON a run
  had no row yet and could approve/void a partner's flagged row (or answer the dispute about it). CP.Admin
  (`ownRunCheck`, the flagged lists) and CP.Disputes (`handle`, the review lists, the new-dispute toasts) now also treat
  "citizenid is a participant of `CP.Runs.get(runUuid)`" as their own run (`err.own_run`; hidden from their queue).
- **UTF-8-safe clipping.** `CP.U.clip` cuts bytes; the cp_* columns are utf8mb4 and MariaDB strict mode refuses a cut
  sequence (error 1366), so an accented 255-character reason made the audit/dispute insert fail. The three modules clip
  by characters with a local `clip()` (invalid bytes dropped first); webhook texts too (Discord counts characters).
- `/CrimsonPoliceAdmin test` goes through `CP.Testing.command` when present (it adds the testers who accepted this
  admin's invitations and accepts tier `auto`); more than `[tier] [location]` is refused. Mission ids in `payout
  mission` / `test` are matched case-insensitively.
- `getMissionList.crossDeptEligible` uses `CP.Operations.eligible(def)` when present (the rule the launch applies).
- A dispute approval of a flagged row calls `approveFlagged(..., { quiet = true })`: one toast for the officer.
- New-dispute toasts respect `Config.Permissions.supervisor.handleDisputes` (off → admins are told instead).
- Admin UI → Officers: a failed-run dispute is answered with Award points / Dismiss; a flagged or voided-run
  dispute (listed while `handleDisputes` is off) with Approve / Reject, which calls `server:admin:handleDispute`
  `{ disputeId, decision, reason }` without `awardPoints` (approve restores the run and releases held cash). Those
  rows carry a "Flagged run" / "Voided run" badge and Approved / Rejected status labels.
- `admin:getOfficer` adds `suspensions` (the last 10 `suspend` / `unsuspend` / `autoSuspend` audit entries) for the
  spec's "suspensions"; the Officers screen shows them under Suspension (dates with the year).
- UI: Review Queue tables use fixed column widths (a 64-character name pushed Approve/Void off the table); Live Missions
  countdowns resync on every poll (a paused timer no longer runs ahead); the audit Copy button uses the selected
  textarea + `execCommand('copy')` first (FiveM's CEF rejects `navigator.clipboard`) and only reports success when it
  worked; a filter change goes back to page 1 without first fetching the old page; department cards/preview show the
  initials when the logo is missing or fails; Mission List says "No missions are loaded" when the list is empty.
- Mocks: every answer goes through `luaify()` (empty lists as `{}`, nil fields left out, like Lua sends them);
  `?oversight=edge` (64-character names, 32-character callsigns, missing callsigns, long labels/reasons, huge numbers)
  and `?oversight=empty` (every list empty) for screenshots.

## Response shapes (defined here; TS in `web/src/types/oversight.ts`)
- `getMissionList` → `{ missions = { { id, label, type, typeLabel, source, builtin, version, difficulty, minOfficers,
  maxOfficers, basePayout, payoutSource, cooldown, timeLimit, locations, enabled, isBoss, departments, runningNow =
  { { runId, src, name, callsign, departmentShort, test } }, crossDeptEligible } }, canLaunch, crossDeptEnabled,
  operation = nil | { id, missionId, missionLabel, status } }`
- `sup:getLiveRuns` → `{ runs = { LiveRun + { missionId, acceptedAt, startedAt, isBoss, departments = { short } },
  participants + { arrived, department } }, serverTime, canRecall }`
- `sup:getReviewQueue` → `{ flagged = { FlaggedRow }, disputes = { DisputeView }, canReview, canHandle }`;
  `admin:getFlagged` → `{ flagged }`; `admin:getDisputes` → `{ disputes }`
- `FlaggedRow = { rowId, runUuid, citizenid, name, callsign, department, departmentShort, missionId, missionLabel,
  missionType, missionTypeLabel, location, state, endReason, tier, participants, departments, points, cash (held
  amount from the breakdown), cashStatus, flagReason, flagDetail, otherReasons, durationS, createdAt }`
- `DisputeView` — see the header of modules/disputes/server.lua.
- `admin:searchOfficers { query }` → `{ officers = { { citizenid, name, callsign, rank, department, departmentShort,
  xp, suspendedUntil, online } }, query }` (25 max; empty query lists officers by name)
- `admin:getOfficer { citizenid }` → `{ citizenid, name, callsign, rank, department, departmentShort, departmentLabel,
  xp, level, streakDays, badges, cash = { total (incl. archive), week }, stats = { runs, completed, failed, abandoned,
  flagged, voided }, suspension = { suspended, untilTs }, suspensions = { { id, action, actor, actorName, role, days,
  reason, createdAt } } (10 newest), runs (25 newest), disputes (failed-run disputes),
  online, own, known, maxAward }`
- `admin:getDepartments` → `{ departments = { { key, label, short, jobs, supervisorGrade, societyAccount, theme,
  logo|nil, members, suspended, onDuty, societyBalance|nil } }, cashSource, showSociety }`
- `admin:getPermissions` → `{ supervisor = { { action, enabled } } (spec order), adminOnly = { ... }, always = { 'viewMissionList' } }`
- `admin:getAudit { category, action, actor, from, to, page }` → `{ rows = { { id, actor, actorName, role, category,
  action, target, oldValue, newValue, reason, createdAt } }, page, pages, total, pageSize = 50, actions }`
- `admin:exportAudit { same filters }` → `{ csv, rows, truncated }` (5,000 rows max; formula-leading cells prefixed
  with `'`; 1 export per 3 s)
- Actions reply: forceRecall `{ runId, src }`; reviewFlagged `{ rowId }`; voidRun `{ voided, runUuid }`; awardPoints
  `{ citizenid, points }`; suspend `{ citizenid, days, untilTs }`; dispute `{ disputeId, goesTo, kind }`;
  handleDispute `{ disputeId, status, kind, points }`.

## Requests to other modules
- **migrations / core**: consider a `system` value in `cp_audit.role` (today automatic entries are stored as `console`).
- **runs**: expose `CP.Runs.ctx(run, index)` (the engine's objective ctx) so presence sampling can use the exact
  same ctx as the blocks instead of CP.AntiCheat's read-only copy.
- **calls**: `CP.Admin.audit(citizenid, 'officer', ...)` is stored with role `console` (enum); pass `nil` if you
  prefer the automatic resolution.
- **leaderboard (Profile)**: `canDispute` can use `CP.Disputes.eligible(row, citizenid, os.time())` plus "no dispute
  row yet" so the button matches the server's rules exactly (one dispute per row, decision final).
- **shared (CP.U.clip)**: clips bytes, so any module clipping user text (names, reasons) can cut a UTF-8 character
  and MariaDB strict mode then refuses the whole insert (error 1366). A character-safe clip in shared/utils.lua would fix
  every caller; this slice uses its own.
- **permissions**: `CP.Permissions.canReviewRun` only looks at cp_mission_runs rows; it could also check
  `CP.Runs.get(runUuid)` participants (this slice does it on top).
- **migrations**: an index on `cp_audit (action, target)` would keep the Review Queue's `runFlagged` lookup and the
  officer suspension history fast once the audit table grows (180 days).
- **tests/harness.lua**: the mysql CLI runs with the latin1 client charset, unlike oxmysql (utf8mb4); oversight_spec
  adds `--default-character-set=utf8mb4` for its own process.
- **locale merge**: this part copies `common.*`, `ui.*`, `result.cash_status.*` and shared `err.*` texts verbatim;
  `err.reason_required`, `err.unknown_mission`, `err.unknown_officer`, `err.invalid_points` use economy.json's text.

## Tests
`lua5.4 tests/run.lua oversight` — 674 assertions: audit/webhooks (clipping, role/category mapping, 429 retry,
disabled convars), every `/CrimsonPoliceAdmin` subcommand (console and in game), approve/void/voidRun with the
department, own-run and switch checks, force recall, live runs, mission list, disputes (filing rules, lists,
answers, forfeits, award failure), anticheat (duplicates, order, speed, buckets, rate limit, outside help,
presence, idle, voids → suspension), officer/department/permission/audit callbacks, CSV export, and a locale
key check of the Lua files. Every SQL statement of the three modules runs on MariaDB.
