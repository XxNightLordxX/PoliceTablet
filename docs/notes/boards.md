# Boards slice notes (leaderboards, department challenge, profile, seasons)

Files: `modules/leaderboard/server.lua`, `modules/challenge/server.lua`, `web/src/officer/screens/{Leaderboard,Challenge,Profile}.tsx`
(+ sibling `.css`), `web/src/admin/screens/{Seasons,Leaderboards}.tsx` (+ `.css`), `web/src/supervisor/screens/DeptReport.tsx`
(+ `.css`), `web/src/types/boards.ts`, `web/src/mocks/boards.mock.ts`, `locales/parts/boards.json`, `tests/boards_spec.lua`.
Both Lua files document their full public API and every response shape in their header comment; the TS
interfaces for the same shapes are in `web/src/types/boards.ts`.

## Registered names

- Callbacks: `getBoard`, `getProfile`, `admin:getBoards` (leaderboard); `getChallenge`, `getDeptContributors`,
  `admin:getSeasons`, `sup:getDeptReport`, `sup:getOfficerActivity` (challenge).
- Actions: `server:setHideName` (leaderboard); `server:admin:startSeason`, `server:admin:endSeason`,
  `server:admin:overrideBounty` (challenge).
- Schedule listeners: `CP.Schedule.onWeekly` (both modules), `CP.Schedule.onMonthly` (leaderboard), registered
  1–1.5 s after start from a thread (no cross-module calls at load time).

## Contract interpretations

### CP.Leaderboard
- **Counted rows** = `voided = 0 AND flagged = 0`. `runs` = counted completed rows that are not `manual_award`/`goal`,
  `failed` = counted failed rows (same exclusion). Points = `SUM(final_points)` of counted rows.
- **Minimum runs** (`Config.Leaderboard.minRunsToRank`) are counted inside the board's own window *and filter*
  (the Tactical board needs 3 completed Tactical runs). All-time uses lifetime completed runs
  (`cp_mission_runs` + `cp_mission_runs_archive`); its points are `cp_officers.xp`, and it is always Overall
  (`filter` is echoed as `overall`).
- **Tie-break** "reached the score first" = the latest counted row that changed the total (`final_points <> 0`,
  falling back to the latest counted row), ascending; then `citizenid` so the order is stable.
- **Filters**: type keys = `mission_type = key` (the Weekly Boss is stored as `tactical`, so it counts there);
  `unit` = `participants >= 2`, `cross` = `departments_n >= 2` (award/goal rows excluded explicitly);
  `department` = the row's department (award/goal rows included). Unknown filter → `err.invalid_filter`,
  unknown period → `err.invalid_period`, unknown department → `err.unknown_department`.
- **Season board** = rows tagged with the active season's id; between seasons it keeps showing the last ended
  season (the spec's "resets when an admin starts the next season"); `season.active` tells the UI which.
  No season ever → empty rows and `season = nil`.
- **`me`** is always present for an officer. `rank = 0` means "not ranked yet" and carries the window's points,
  runs and failed (all 0 without rows). The viewer's own row (in `rows` and `me`) shows their own name even
  when they hide it.
- **Cache**: one entry per (period, filter, department, window start/season) for `Config.Leaderboard.cacheSeconds`,
  concurrent misses share one query; `invalidate()` drops boards, season points and announcements and calls
  `CP.Challenge.invalidate()`.
- **Profile**: last 20 rows of any type (manual awards and goal rewards are listed and labelled, never
  disputable). Own profile: cash, `cashStatus` (the row's column, also written into `breakdown.cash.status`).
  Someone else's profile: name → callsign when hidden, `cash = 0`, `cashStatus = ''`, `breakdown.cash`
  removed, `canDispute = false`; flagged/voided rows are still listed with their badges.
  `canDispute` = own row, not an award row, flagged or voided or failed, within `Config.Disputes.windowHours`,
  and no **open** `cp_disputes` row (a handled dispute does not block; `modules/disputes` has the last word).
  Extra fields: `departmentLabel`, `seasonPoints`, `disputeWindowHours`, `runs[i].createdTs`, `badges[i].kind`
  (`week` | `champion` | `top10` | `achievement`). Badges come from `CP.Scoring.badges` (fallback: `cp_badges`),
  newest first; this slice labels its own badge ids (`officer_of_week_*`, `season_<id>_champion`, `season_<id>_top10`).
- **Announcements** are computed from the database (restarts keep them): top 3 of the previous week, shown
  during the whole current week, and of the previous month, shown during the current month.
  `{ kind = 'weekly_top3'|'monthly_top3', text (localized), entries = { rank, citizenid, name, callsign,
  departmentShort, points }, period }`. Names respect hide_name.
- **Weekly job** (onWeekly): Overall top 3 of the week that ended → `CP.Admin.webhook('board', …)`, badge
  `officer_of_week_<weekKey>` (weekKey = start date of that week) for #1, toast to #1 if online. Idempotent: an
  existing badge for that week means it already ran. It also runs once 60 s after start as a catch-up.
  Monthly reset only invalidates (Home shows the month's top 3; the board webhook is weekly + season only).
- **admin:getBoards** (`openAdmin`): every ranked row with `cash` (= `SUM(cash_paid)` of **all** rows in the
  window/filter, voided and flagged included, since voiding never takes money back), `realName`, `hidden`;
  `unranked` = officers below the minimum; `stuck` = `CP.Cash.stuckPayments()` normalised to
  `{ rowId, runUuid, citizenid, name, callsign, missionLabel, amount, createdAt (text), transId }` (fallback: own
  query). Passing `citizenid` adds `runs` = that officer's rows in the window/filter (for Void run), instead of
  a new callback name.

### CP.Challenge
- **Week numbers**: week 1 runs from the season start to the first weekly reset; week n = number of weekly
  resets since the season started + 1 (DST-safe date arithmetic, `Config.Time.resetHour`, `weekStartsOn`).
- **cp_dept_bounties**: `winner` NULL = open, `''` = closed without a winner, else the department key.
  **Week 0** (`objective = 'season_champion'`) stores the season champion at season end (the schema has no
  champion column); every bounty list uses `week >= 1`.
- **Bounty pick**: `CP.U.rng(CP.U.hash('<seasonId>:<week>')):pick(Config.Challenge.bounties)`, stored when the
  week is first needed (season start, weekly reset, first view), so a restart keeps it. An id outside
  `most_tactical|most_cross|most_unit|most_completed` counts completed runs (one console warning).
- **Bounty winner**: count of the objective's completed runs in that department that week ÷ the department's
  season-to-date active officers (`minRunsActive` completed runs); tie-break completed runs, then unit runs that
  week; all zero or a perfect tie → no winner. Weeks close at the weekly reset, at start (catch-up for weeks that
  ended while the server was down) and at season end (the partial last week too).
- **Bonus** = `floor(bountyBonus × the winning department's counted season points of that week)`, derived from
  the rows whenever standings are computed (a later void lowers it); the winner itself is frozen at close.
- **Scores**: `average` = (points of active officers + bonuses) ÷ active officers; `total` = all points + bonuses;
  `top10` = 10 best officers' points + bonuses. Sorted by score, completed runs, unit runs, key. Departments
  come from `CP.Access.departments()` at call time, so one added mid-season appears at 0.
- **Season end**: champion = first of the standings when it has points or runs and is not perfectly tied with
  the second (`''` otherwise, also when `Config.Challenge.enabled = false`); trophy `season_<id>_champion` for the
  champion's active officers; `season_<id>_top10` for the season board's top 10 (minRuns applies); one board
  webhook with standings and top 10; audit `season_end` (new = champion or `-`). `startSeason` ends the running
  season first (audit `season_end` with reason `season_start`, then `season_start`).
- **championBanner(dept)** = the most recent ended season's champion (nil when that season had none, or `dept`
  is another department). Shape `{ season, seasonId, department (label), departmentKey, short }`.
- **currentSeason()** is cached (reloaded every 5 min and after every change), so the run engine can call it for
  every row.
- **Supervisor callbacks** use `CP.Permissions.can(src, 'viewMissionList')` (supervisors and admins, no config
  switch; there is no dedicated action for the Department Report). Supervisors always get their own department;
  only admins may pass `department`. Activity = every row of the department since this week's reset (any season,
  voided/flagged included in run counts; points only from counted rows; cash = `SUM(cash_paid)`).
  `sup:getOfficerActivity` accepts officers whose stored department is the supervisor's, or who have a row in it
  this week (else `err.other_department`, unknown → `err.unknown_officer`) and returns only that department's rows.
- Admin actions: seasons → `seasons`, override → `bountyOverride` (both admin-only in CP.Permissions).
  `err.busy` while another season change runs.

### Web
- The breakdown dialog renders the HUD result card's `cp-result__*` classes (hud.css) with its own markup
  (`RunBreakdown` in Profile.tsx), so both look the same; public breakdowns simply have no cash block.
- Reusable exports: `RankCell`, `filterLabel`, `formatDay`, `formatClock` (Leaderboard.tsx), `DeptBars`,
  `BountyCard`, `formatEndsIn` (Challenge.tsx), `RunBreakdown`, `ResultCell`, `StateBadge`, `missionTypeLabel`
  (Profile.tsx). Shared helper classes (`boards-muted`, `boards-strong`, `boards-struck`, `boards-flat-table`)
  live in Leaderboard.css, which every boards screen imports through these exports.
- Award points: 1–10,000 points (modules/admin's `MAX_AWARD`), reason required. Void run: reason required.
- Mocks for `server:dispute`, `server:admin:voidRun`, `server:admin:awardPoints` are registered as fallbacks
  (the owners' mocks win; oversight.mock.ts already registers the admin ones).

## Test scenario (tests/boards_spec.lua)

Part A ranks 5 officers over one week (ties on points broken by failed runs and by time), filters, windows,
all-time with archived rows, cache expiry and invalidate, profiles (own/public/hidden/disputes), hide-name,
admin boards and stuck payments (own query and `CP.Cash` shape), the weekly job, announcements.
Part B runs a season over three weeks: SAST (S1 460 pts/3 runs, S2 380/4, S3 210/1) vs FIB (F1 600/3, F2 255/4);
week 1 most_tactical → SAST (2/2 vs 1/2, bonus 40), week 2 most_completed → FIB (6/2 vs 5/2, bonus 65), week 3
most_tactical → SAST (bonus 25); final average FIB 460 vs SAST 452.5 → FIB champion; plus total/top10 modes, a
department added mid-season, overrides, the weekly reset through `CP.Schedule._check`, supervisor report and
activity, season end, banner and season rollover. Every SQL statement of both modules runs on MariaDB `cp_test`.
Note: the harness drops result lines that are empty, so a single-column query returning `''` looks like no row
(the spec selects two columns there). `cp_test` is shared: a concurrent `tests/run.lua` from another slice can
drop the database mid-run (seen once; re-running is green).

## Requests to other modules

- **scoring / goals**: set `season_id = CP.Challenge.currentSeason() and .id` and `department` (the officer's
  department) on `manual_award` and `goal` rows, so they count on the Season board and in the department
  challenge (the scoring module already reads currentSeason; goals please do the same). Call
  `CP.Leaderboard.invalidate()` after inserting them.
- **runs**: already tags rows with `season_id` and calls `CP.Leaderboard.invalidate()` — thanks; keep calling it
  for every counted/approved/voided row so voided runs leave the boards immediately (the cache also expires in 60 s).
- **admin / disputes / anticheat**: call `CP.Leaderboard.invalidate()` after void, approve, dispute approval and
  auto-flags (admin already does). The console `season start|end` path matches `CP.Challenge.startSeason(src, name)`
  / `endSeason(src)` (src 0 = console, audited with role `console`).
- **permissions** (optional): add an always-on supervisor read action (e.g. `viewDeptReport`) if the report should
  not share `viewMissionList`; switch the two `sup:*` callbacks here when it exists.
- **migrations** (optional, future): a column for the season champion (e.g. `cp_seasons.champion`) would replace the
  week-0 row; nothing else in this slice needs schema changes.
- **home (scoring getHome)**: `announcements()` entries carry `entries` for a richer card; `championBanner(dept)`
  returns `{ season, department, … }` exactly as `HomeData.champions` expects.
- **disputes**: the Profile sends `server:dispute { rowId, reason }` (reason ≤ 255 chars, required) and refetches
  on success; please return your own `err.*` keys (they are shown as toasts).
- **locale merge**: this part copies `common.*`, `result.*`, `reason.*`, `ui.screen.*` and the core `err.*` texts
  verbatim; `err.unknown_officer` uses economy.json's text. New: `reason.manual_award`, `reason.goal`.
