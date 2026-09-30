# Slice notes · economy (scoring, goals, cash, payouts)

Files: `Crimson-Police/modules/{scoring,goals,cash,payouts}/server.lua`,
`web/src/officer/screens/Home.tsx` (+ `Home.css`), `web/src/supervisor/screens/Payouts.tsx` (+ `.css`),
`web/src/admin/screens/Payouts.tsx` (+ `.css`), `web/src/types/economy.ts`, `web/src/mocks/economy.mock.ts`,
`locales/parts/economy.json`, `tests/economy_spec.lua`.

## Registered net entry points

| Kind | Name | Owner function | Permission |
|---|---|---|---|
| callback | `getHome` | scoring | `CP.Access.getOfficer` (its error keys) |
| callback | `sup:getPayouts` | payouts | `CP.Permissions.can(src, 'setTypePayout')` |
| callback | `admin:getPayouts` | payouts | admin (`CP.Access.isAdmin` + `can('setMissionPayout')`) |
| action | `server:sup:setTypePayout` `{ type, amount, reason }` | `CP.Payouts.setType(..., 'supervisor')` | setTypePayout |
| action | `server:admin:setTypePayout` `{ type, amount \| null, reason, clear? }` | `CP.Payouts.setType(..., 'admin')` | admin; clearing = `clearPayout` |
| action | `server:admin:setMissionPayout` `{ missionId, amount \| null, reason, clear? }` | `CP.Payouts.setMission` | `setMissionPayout`; clearing = `clearPayout` |

Push topics sent: `payouts` (`{ kind = 'type', key }` / `{ kind = 'mission', missionId }`) and `board`
(`{ reason = 'payouts' }`) to every online player after any payout change. Lua listeners: `CP.Qbx.onDutyChange`,
`onJobChange`, `onPlayerLoaded` (x2: duty tracking, pending cash 5 s later), `onPlayerUnload`, `playerDropped`.
Threads: the forfeiture job (at start, then every 10 min) and one start-up sweep 15 s after the resource starts that
pays the pending rows of players who are already online (they never fire PlayerLoaded again).

## Response shapes I defined (TypeScript in `web/src/types/economy.ts`)

```ts
// getHome: HomeData (§9.4); typeOfTheDay also carries the extras { multiplier (Config.Events.todMultiplier),
// cap (Config.Scoring.scoreCap) } and card.streak the extra graceDays (Config.Scoring.streakGraceDays; 0 = no
// grace, the Home hint then says nothing about grace) (web/src/types/economy.ts HomeTypeOfTheDay, HomeStreak)

// sup:getPayouts
SupPayoutsView = { types: SupPayoutType[]; rangeShare: { min, max }; cooldownSeconds; requireReason: true;
  limits: { min, max }; serverTime }
SupPayoutType = { key, label, amount, default, min, max, adminLocked, cooldownLeft /* s */, updatedByName?, updatedAt? /* unix s */,
  stored, canEdit }
// server:sup:setTypePayout -> SupPayoutType (the new state)

// admin:getPayouts
AdminPayoutsView = { types: AdminPayoutType[]; missions: AdminPayoutMission[]; limits: { min, max }; requireReason;
  cooldownSeconds; serverTime }
AdminPayoutType = { key, label, points, amount, default, adminLocked, stored, updatedBy?, updatedByName?, updatedAt?,
  supMin, supMax, cooldownLeft, missions /* count, boss excluded */ }
AdminPayoutMission = { id, label, type?, typeLabel?, difficulty, source: 'builtin'|'custom', isBoss, enabled, base,
  payoutSource: 'admin'|'type'|'event', missionPayout?, fallback /* B without the mission payout */, setBy?, setByName?,
  updatedAt?, missing /* stored payout of a mission that is not loaded */ }
// server:admin:setTypePayout -> AdminPayoutType; server:admin:setMissionPayout -> AdminPayoutMission

// CP.Cash.stuckPayments() (for admin:getStuckPayments, owned by modules/admin)
StuckPayment = { id, runUuid, citizenid, name, missionId, missionLabel, department, amount, createdAt /* unix s */, transId }
// CP.Scoring.badges(citizenid) (for Profile)
{ id, label /* CP.L('badge.<id>') */, earnedAt /* 'YYYY-MM-DD HH:MM:SS' */, earnedTs }
```

`CP.Payouts.list()` returns `{ types = { AdminPayoutType... }, missions = { AdminPayoutMission... } }`.
manual_award / goal rows store a RunResult-shaped breakdown (P = final = the points, empty lines, cash 0) plus
`kind`, `reason` (manual) or `period`, `periodKey`, `goalId` (goal). Every counted row also gets the internal
breakdown key `xpCounted` (the XP idempotency marker, see below).
A completed `CP.Scoring.compute` breakdown (RunResult `points`) also carries the optional extras `cap` (the points cap
in whole points, floor(scoreCap x P)), `scoreCap` (Config.Scoring.scoreCap) and `todMultiplier`
(Config.Events.todMultiplier), so the result card and the Profile breakdown show the configured cap and Type of the Day
multiplier (`web/src/shared/data.ts pointsLimits`; a row stored without them falls back to the shipped 2 and 2).

## Contract interpretations

Scoring
1. `P` is rounded to whole points (halves up) because `points_base` is a SMALLINT.
2. Each bonus/penalty line is rounded to whole points; `each = true` multiplies by the recorded count and the label
   gets `× n` (`scoring.times`). Penalty lines carry negative points; the engine stores the positive sum.
3. What counts: (a) every id on the mission card (`mission.bonuses` / `penalties`) with the recorded count (shared
   `run.score.shared` + personal `p.score`); value = the entry's `points` / `pctOfPoints` x P, else `Config.Bonuses`
   (`each` from the entry or Config.Bonuses); an entry in `penalties` is always negative. (b) the end-evaluated
   `no_participant_downed` (`run.stats.downs == 0`) and `no_weapons_fired` (`run.stats.weaponsFired == 0`), only when
   the card lists them. (c) recorded ids the card does not list: the common personal ids (`pedestrian_hit` x
   `common.pedestrianHit`, `lights_siren` once for beat_patrol/business_check, `shot_surrendered` x
   `common.shotSurrendered`) and ids with a per-occurrence value hint in `run.score.values` (kingpin_alive,
   inmate_alive, hostage_hit, ...). An unlisted id that only exists in Config.Bonuses (e.g. hostile_arrested on the
   Kingpin, recorded by hostile_waves) does **not** count: the mission did not opt in. A card entry with no value
   of its own that is not in Config.Bonuses uses the recorded hint (each). (d) the common ones: fast_finish
   (duration <= fastShare x run.timeLimit, not when `run.flags.medals`; label "Finished within {pct}% ..." with pct
   from fastShare), modifier (`Config.Events.modifierPoints` x P, label "Modifier: <name>"), first_run,
   no_vehicle_damage (`p.vehicle.seen`, engine and body > noDamageAbove), heavy_damage (body < heavyDamageBelow, not
   when `vehiclePenalties == false`).
   Custom missions (`mission.source == 'custom'`): mission-file values never raise points. A card entry is valued
   only when its id is in Config.Bonuses (`points` or `pctOfPoints` by the id's kind, else the config value, clamped
   to `Config.Builder.bonusCap`: 50 points / 25% of P per occurrence; `each` from Config.Bonuses only); the
   `points` / `pctOfPoints` / `each` a file writes on any other id are ignored, so only a block hint can value it.
   A recorded Config.Bonuses id the card does not list is ignored even with a hint. Hints from block code (medals
   and `no_contact` with their card values, the boss's `kingpin_alive` 50, `hostage_hit`) still count; a positive
   one is capped at `bonusCap.points`, a penalty keeps its block-setting range (hitPenalty 0-100).
4. Failed = floor(failedCredit x P x share) with no bonuses, multipliers or Type of the Day; `subtotal` shows the credit
   and mTeam/mCross/mStreak are reported as 1.0 (not applied). Abandoned = 0.
5. Presence (runs with 2+ participants, `CP.AntiCheat.presenceOk(run, p) == false`): SPEC 6.4 / Anti-exploit say the
   participant keeps the result with **0 points and $0**, so `compute` returns final 0 (lines still listed) and
   `CP.Cash.compute` returns $0. The engine flags the row `presence` (so the cash status is `held` with $0).
6. Type of the Day compares `CP.Events.typeOfTheDay()` with `run.missionType` (a boss run counts as Tactical), is
   applied after the cap and uses `Config.Events.todMultiplier`.
7. M_streak of a completed row uses the streak **including today** (the projected value after this completion);
   M_cross = `Config.CrossDepartmentPoints` when `opts.departments` (or the run's active departments + own) >= 2;
   M_team = the pay tier's `points`.
8. Streak: consecutive reset-adjusted days with a completed, counted run. Missed days are walked one by one; each is
   forgiven while its week (from the weekly reset, `CP.Schedule.weekKey`) has grace left
   (`Config.Scoring.streakGraceDays`); a forgiven day adds nothing. When the streak breaks, the grace of that gap is
   not used. `streak_days` is stored capped at 127 (signed TINYINT); the multiplier caps at streakMax anyway.
   `streak()` shows the live streak (alive while yesterday had a run or every missed day up to yesterday is
   forgivable); `graceLeft` = this week's grace not used, counting pending missed days of this week. An approval
   applies the row's own day (a day older than last_complete is ignored); voids never rewrite streaks.
9. XP = lifetime points of counted rows, **including manual_award and goal rows** (they count toward Overall, and the
   All-time board is lifetime XP). Idempotent per row: `breakdown.xpCounted` is set with a conditional UPDATE before
   XP is added and removed before XP is taken back, so double hook calls or a void of a never-counted (flagged) row
   change nothing. XP never goes below 0.
10. XP level names are configuration (`Config.XPLevels.label`, like mission type labels); `xpLevel().xp` is the
    level's threshold and `next` the next threshold (nil at the top).
11. Badges (ids `iron_wheels`, `sharpshooter`, `road_warrior`, `partner_in_crime`, `joint_task_force`) count
    completed, not flagged, not voided runs in cp_mission_runs **and** cp_mission_runs_archive: Iron Wheels = rows
    whose breakdown has the `no_vehicle_damage` bonus; Sharpshooter = gang_shootout rows with the
    `no_participant_downed` bonus; Road Warrior = patrol rows; Partner in Crime = participants >= 2; Joint Task Force =
    departments_n >= 2. Checked after every counted completed row and approval; after a void, a badge whose count fell
    below its threshold is removed.
12. First completed run since going on duty: per citizenid in memory. A new duty start = the live duty goes from off to
    on (duty or job events, re-read from `CP.Qbx.getInfo`) or a character load while on duty. A duplicate on-duty
    event changes nothing. After a resource restart the state is unknown: it counts as already used when the officer
    has a completed run since today's reset. Test runs never use it; any completed row (flagged too) does.
13. `manualAward`: admin only (`manualAward`), whole points 1–10,000, reason required (<= 255), the officer must exist
    in cp_officers (`err.unknown_officer`); the row's department is cp_officers.department ('unknown' fallback).
    Audited as `manualAward` (target citizenid, new = points). The officer is notified when online.

Goals
14. Goal labels come from `Config.Goals` (configuration text); `goals.unnamed` is only a fallback. Besides `type`,
    `unit` and `crossDepartment`, a goal may set `mission = '<id>'`. Progress counts completed, not flagged, not voided
    runs (never manual/goal rows) created since the period start; progress is capped at `count`. A reward row is found
    by `mission_id = goal id` + `breakdown.period`, so a daily and a weekly goal with the same id do not collide.
    Rewards are checked on `onRunCompleted` and after an approval (`CP.Scoring.onRowApproved`).

Cash
15. The amount paid is `breakdown.cash.amount` (exact); `round(cash_base x cash_multiplier)` only when the breakdown has
    none (cash_multiplier is DECIMAL(4,2) and loses precision, e.g. 1.30 x 1.25).
16. `pay(rowId)`: offline check first (online = `CP.Qbx.getByCitizenId`): an offline officer's row goes
    none/held -> `pending` (no money moves); otherwise the claim `UPDATE ... SET cash_status = 'paying' WHERE id = ? AND
    cash_status IN ('none','held','pending') AND state = 'completed' AND flagged = 0 AND voided = 0` must change the row.
    The extra guards mean a flagged or voided row is never paid, whatever calls pay. After the claim, the rest runs
    under pcall: a Lua error before the first call that can move money (society withdrawal or AddMoney) puts the
    row back to `pending`; an error after that leaves it `paying` (manual check), so nothing is ever paid twice.
    `payPending(src)` (login + 5 s, start-up sweep) pays `pending` rows and also completed, unflagged, unvoided
    mission rows still `none` with `cash_base > 0` (the engine's pay never ran: a crash right after the row insert,
    or a skipped lock wait); no money moved on either and `pay()` claims them like any other row.
17. Daily cap: the sum of paid/capped cash of rows created on the **same reset-day as the row** (a pending row paid
    later is capped against its own day). Payments of one officer are serialised in-process, so two rows cannot both
    pass the cap check.
18. Society source: the player is re-fetched right before `withdrawSociety`; false -> `unfunded` ($0), the officer and
    the online supervisors of the row's department are told (`cash.unfunded`, `cash.unfunded_supervisor`).
    If AddMoney then fails, the money already left the society account and the contract has no refund call: the row
    stays `paying` (listed by `stuckPayments`, error logged with the transaction id). If `CP.Banking.depositSociety`
    exists it is used to refund and the row goes back to `pending`. With the server source a failed AddMoney always
    puts the row back to `pending`.
19. Renewed-Banking: `recordDeposit(citizenid, amount, 'Mission payout: <label>', <department label>, <character name>,
    'CP-<run_uuid>-<citizenid>')` only when `Config.Cash.account == 'bank'`; with the society source also
    `recordSocietyWithdraw(societyAccount, ...)` with the same transaction id (RB's own transfer pattern).
    Final status `capped` when the cap cut the amount (also down to $0), else `paid`; the breakdown's `cash.status`
    and `cash.paid` are updated with the row.
20. `release(rowId)` requires the caller to have cleared `flagged` first (it refuses and warns otherwise) and never
    releases a voided row. `forfeit(rowId)` only touches voided rows in held/pending. The forfeiture job (at start,
    then every 10 min) forfeits voided held/pending rows older than `Config.Disputes.windowHours` (from created_at)
    without an open dispute.
21. `range(missionType, members)`: members = officer tables or srcs (tier = `CP.Scaling.tierFor(#members)`); pool =
    `CP.Draw.pool` (fallback: enabled `CP.Missions.byType` that support the size); min = lowest B x tier cash, max =
    highest B x tier cash x `modifierCash` (when `modifierChance > 0`; never for `'weekly_boss'`). Empty pool -> the
    type payout.
22. `earnedThisWeek`: cash_paid of paid/capped rows created since `CP.Schedule.weekStart()`.

Payouts
23. Supervisor range = ceil(default x low share) .. floor(default x high share), clamped to Config.Cash limits.
    Supervisors always need a reason (SPEC); admins need one unless `Config.Payouts.requireReason = false`. A value equal
    to the current one is refused (`err.payout_unchanged`) so it neither audits nor starts the cooldown.
24. Supervisor-set values are stored (admin_locked = 0), persist over restarts and start the 30 min cooldown via
    updated_at (written explicitly with `FROM_UNIXTIME(os.time())`). An admin on the supervisor path follows the
    supervisor rules; the admin path requires an admin. `updated_by` / `set_by` = the actor's citizenid or `'console'`.
25. Stored mission payouts whose mission is not loaded are listed with `missing = true` so an admin can clear them;
    a new payout can only be set for a loaded mission.
26. Audit: `CP.Admin.audit(src, role, 'audit', action, target, old, new, reason)` with actions `setTypePayout`,
    `clearTypePayout`, `setMissionPayout`, `clearMissionPayout` (old/new are amounts, or `config:<n>` / `type:<n>` /
    `event:<n>` for the value that applies without the stored one), role `supervisor` | `admin` | `console`. When
    modules/admin is not loaded the entry is written to cp_audit directly (no webhook) so no change goes unaudited.

UI
27. Home refreshes on the push `run` that carries no data (the run ended; its rows, XP, goals and cash are written
    by then) and every 60 s; the per-tick `run` pushes during a run do not refetch it. `announcements` / `goals`
    may arrive as `{}` / `[]` from Lua and are treated as empty. Announcement kinds `weekly_top3` / `monthly_top3`
    (modules/leaderboard) get the trophy / podium icons. The Type of the Day text shows the configured multiplier
    and cap (extras above). Supervisor Payouts counts cooldowns down locally and refetches when one ends.
    Browser mocks: `?economy=empty|lua|edge|error` (`lua` = empties the way Lua encodes them, `edge` = long names,
    huge numbers, top level, a 1.5x multiplier).

Tests: `tests/economy_spec.lua` uses its own database `cp_test_economy` (same migrations as cp_test, like the
engine_a spec) so parallel runs of other specs cannot reset its tables; every SQL statement of the slice runs there.

## Requests to other modules

- **runs** (already matches the current engine): keep passing `opts = { objectivesDone, objectivesTotal, failedShare,
  durationS, departments }` to `CP.Scoring.compute`, set `p.result` before `CP.Cash.compute`, keep per-occurrence
  hints in `run.score.values` / `run.score.kinds`, record `pedestrian_hit` / `lights_siren` personally, and call
  `CP.Scoring.onRowCounted(citizenid, row)` with `row.id`, `state`, `mission_type`, `final_points`. For presence the
  0-point / $0 result comes from my compute functions (SPEC 6.4); please do not recompute it.
- **admin**: `approveFlagged` must set `flagged = 0` **before** calling `CP.Scoring.onRowApproved(rowId)` and
  `CP.Cash.release(rowId)`; `voidRun` / `voidFlagged` set `voided = 1`, then call `CP.Scoring.onRowVoided(rowId)`
  (XP is only taken back from rows that counted) and `CP.Leaderboard.invalidate()`. Console `payout type <type>
  <amount|clear> <reason>` -> `CP.Payouts.setType(0, type, amount|nil, reason, 'admin')`, `payout mission ...` ->
  `CP.Payouts.setMission(0, id, amount|nil, reason)`, `award` and `server:admin:awardPoints` ->
  `CP.Scoring.manualAward(src, citizenid, points, reason)` (it audits itself), `admin:getStuckPayments` ->
  `CP.Cash.stuckPayments()`. `CP.Admin.audit` must accept a numeric src (0 = console) as actor.
- **disputes**: rejecting a dispute about a voided run -> `CP.Cash.forfeit(rowId)`; approving one about a flagged or
  voided run -> clear the flag/void, `CP.Scoring.onRowApproved(rowId)`, `CP.Cash.release(rowId)`; a failed-run award
  -> `CP.Scoring.manualAward`.
- **leaderboard**: `seasonPoints(citizenid) -> number`, `announcements() -> { { kind, text } }` (kinds the Home screen
  styles: `weekly_top3`, `monthly_top3` (what modules/leaderboard sends today), `officer_of_week`, `weekly_top`,
  `monthly_top`, `season`, `bounty`, `info`; any other kind gets the info icon); give the Officer of the Week /
  season badge ids a `badge.<id>` label in your part (`CP.Scoring.badges` labels every row of cp_badges). The All-time
  board can read cp_officers.xp. Profile: `CP.Scoring.xpLevel(xp)`, `CP.Scoring.badges(citizenid)`.
- **challenge**: `currentSeason() -> { id, name }|nil`, `championBanner(dept) -> { season = <name>, department =
  <label> }|nil`.
- **renewed_banking**: optional `CP.Banking.depositSociety(account, amount) -> boolean` (Renewed-Banking
  `addAccountMoney`) as the refund path when a society-funded payout's AddMoney fails; without it such a row stays
  `paying` for a manual check.
- **locale merge**: shared keys copied verbatim: `modifier.*` (engine_a), `err.busy`, `err.internal`,
  `err.invalid_citizenid`, `err.invalid_payload`, `err.no_permission`, `err.not_police`, `err.not_on_duty`,
  `err.suspended`, `err.suspended_dispatch` (core), `common.cancel`, `common.no_callsign`, `common.optional`,
  `common.pts`, `common.reason`, `ui.screen.home`, `ui.screen.sup_payouts`, `ui.screen.admin_payouts` (ui). Bonus labels
  owned by the blocks that record them are not repeated here: `bonus.medal_*`, `bonus.no_contact`,
  `bonus.devices_found_fast` (blocks_a), `bonus.kingpin_alive`, `bonus.inmate_alive`, `penalty.hostage_hit`
  (blocks_b), `bonus.racer_detained`, `bonus.all_racers_detained`, `penalty.ram` (blocks_c). I own every other
  `bonus.*` / `penalty.*` label of Config.Bonuses, the mission cards and the common list, and `badge.<5 ids>`.
