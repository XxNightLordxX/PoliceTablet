# run_ui · notes (Officer UI: Mission Board + Active Mission)

UI-only slice (no Lua, no SQL). Files:
`Crimson-Police/web/src/officer/screens/MissionBoard.tsx` (+ `MissionBoard.css`),
`Crimson-Police/web/src/officer/screens/ActiveMission.tsx` (+ `ActiveMission.css`),
`Crimson-Police/web/src/types/run_ui.ts`, `Crimson-Police/web/src/mocks/run_ui.mock.ts`,
`Crimson-Police/locales/parts/run_ui.json`, `tests/run_ui_spec.lua`.

## Contract used (exact names)

| Kind | Name | Payload / shape | Screen |
|---|---|---|---|
| request | `getMissionTypes` | `{}` → BoardData (§9.4) | Mission Board |
| push topics | `board`, `operation`, `run` | one coalesced refetch of the board (`run` only when the active run starts or ends) | Mission Board |
| action | `server:acceptType` | the type key, or `'weekly_boss'` for the boss card → `{ runId }`; on ok `navigate('active')` | Mission Board |
| action | `server:joinOperation` | `operation.id` → `{ id, joined, max }` | Mission Board |
| request | `getRun` | `{}` → ActiveMissionView \| null (§9.4) | Active Mission |
| push topic | `run` | the view (applied as it is, no extra getRun) or nil (arrives as a missing field → getRun) | Active Mission |
| action | `server:abandon` | `runId` → `{ runId }` | Active Mission |
| client action | `setGps` | `{ runId }` (payload ignored by modules/route) → `{ runId }` | Active Mission |
| client action | `recalcRoute` | `{ runId }` (ignored) → `{ recalcsLeft }` | Active Mission |
| client action | `logResult` | `{ point, choice }` → `true` | Active Mission (Business Check log) |

No Lua API, no events, no callbacks are registered by this slice.

## Contract interpretations

### Mission Board
- **Only types are picked.** The board shows one card per `BoardData.cards` entry (label, points, cash per
  officer as `MoneyRange` → "$1,040–$1,300", pool count, Solo / Unit · N, Type of the Day tag). It never lists
  or previews individual missions; the Weekly Boss card (its mission label) and the Cross-Department card are
  the spec's exceptions. While `BoardData.operation` is set only the operation card is shown (no type cards,
  no boss, no unit line).
- **`locked.reason` is already translated** by the server (`CP.Draw.boardCards` uses `CP.L`), so it is shown
  as-is. **`locked.until` is an `os.time()` stamp.** The countdown converts it with a server-clock offset:
  `BoardData.serverTime` when present (requested below), else the offset measured from the last `open` /
  `session` NUI message (a module-level listener records `session.serverTime − Date.now()` on arrival), else
  `session.serverTime` the first time the board saw that session. A value below 1e9 is taken as "seconds
  left" already (defensive). When the countdown reaches 0 the board refetches.
- **Card status priority**: locked (reason + countdown) → on a call → server busy → a board-wide blocker
  (already on a mission / not the unit leader) → ready. Accept is disabled for any of these, and also for a
  pool of 0; the server re-checks everything anyway. Busy and on-call cards also carry a tag; when every card
  is busy / on call a notice explains it once at the top.
- **Points**: `card.points` as sent (the best P in the pool). Type of the Day adds a "{multiplier}× today" hint
  (points are multiplied after the cap; cash is not); the multiplier is the optional `BoardData.todMultiplier`
  (requested from draw), else 2 (the config default).
- **Accept confirm** (every card): the mission is drawn at random and revealed after the accept, no reroll;
  abandoning, leaving the start route or missing the start timeout puts the whole type on cooldown; in a unit
  every member gets the same mission and invites close. The boss confirm says the attempt of the week is used
  instead (no type cooldown for the boss, ARCHITECTURE §4.3).
- **Toasts**: no success toast for `server:acceptType` (the engine notifies `run.accepted`). `server:joinOperation`
  shows `board.op.joined_toast` (modules/operations sends none). Errors are toasted by `useAction` with `t(err)`.
- **Operation card**: missionLabel, missionTypeLabel, description, launcher, status (joining / running with
  runState / waiting), joined / max with `min`, the join countdown (`joinEndsIn`, refetch at 0), Join
  (`canJoin`), a joined state, and "Open Active Mission" once the joiner is on the operation's run. `boardCard`
  gives no reason when `canJoin` is false, so the hint is derived (closed, full, already on a mission, else a
  generic "can't join right now"). `joinEndsIn` is only sent while the window is open, so a `joining`
  operation without it (Start now just closed the window) shows "Starting" and "Joining is closed".
- **Unit line**: `BoardData.unit` → "Solo" (build a unit), "Unit of N · you lead", or "Unit of N · only your
  unit leader picks the type"; the button opens the Unit screen.
- Refetch: push `board` and `operation` (modules/operations sends both at once, modules/units sends `unit` +
  `board`), and `run` only when the pushed runId differs from `activeRunId` (a run started or ended: active
  run and cooldowns change; the view pushed every few seconds during a run changes nothing on the board).
  Pushes schedule **one** coalesced refetch 150 ms later, and a refetch refused with `err.rate_limited`
  (getMissionTypes allows 4 calls per second) is retried once after 1.2 s, so a burst never leaves a stale
  board up until the next poll. Plus every 30 s (busy and on-call states have no push). In a unit the on-call
  texts say "you or a member of your unit" (BoardCard.onCall is set when any member is on a call).
- A wide cash range (admin payouts go up to $25,000) wraps after its en dash instead of being cut off; a long
  type label is ellipsised with the full label as a tooltip.

### Active Mission
- **Header**: Abandon (danger) opens a danger ConfirmDialog → `server:abandon(runId)`; on ok the screen shows the
  empty state at once and refetches, so a getRun still in flight from before the abandon can never bring the
  old view back (the result card and the `run.ended_quit` toast come from Lua). Message: no points/cash;
  the whole type goes on cooldown, or "uses up your Weekly Boss attempt" (`isBoss`), or "test run: nothing is
  saved and no cooldown starts"; plus "the run continues for your partners" when others are active.
- **Hero**: type eyebrow, mission label and description, state badge (Accepted · heading to the start / In
  progress), `TierBadge` marked expected until In progress (`tierExpected || state === 'accepted'`), a
  "Pay: <tier>" chip only when the pay tier is **lower** than the tier (as specified), the modifier chip, Weekly
  Boss / Cross-Department chips, and, once In progress, "At the start" or "Start route off" instead of the route
  card. Right column: the timer (`Countdown` of `remaining`, local, paused state, restarted from every fresh
  view), expected cash and points. Before In progress `remaining` is null: the timer shows "–:––", or the start
  timeout countdown when the optional `startIn` is sent.
- **Route card** (shown while Accepted, while this participant's route is `on`/`off`, and — test run with the
  start route off — while this participant has not arrived yet, so Set GPS stays reachable): on route (+ distance
  to go), off route with the local countdown of `secondsLeft` (or the no-limit text), arrived, disabled (test run
  without the route). Set GPS is available until arrival (also for a test run without the route: modules/route
  still sets the waypoint). Recalculate route asks for confirmation (a limited resource), is disabled at
  `recalcsLeft == 0`, shows "Recalculations left: N" and keeps the reply's `recalcsLeft` until the next view
  arrives. The success toasts of both client actions come from modules/route (`route.gps_set`,
  `route.recalculated`); the screen toasts only errors.
- **Objectives**: every entry with its number/check mark, "Current" tag, `value/max` bar and `detail`. While
  Accepted the list is shown muted with `run.objectives.pending` ("The objectives start when the first
  participant reaches the start"; the view lists them before the start, so ui.json's "Objectives appear when
  you reach the start" would contradict the list).
- **Partners**: initials, name (+ "You"), callsign (or "No callsign"), department tag, status (Left / At the
  start / En route); the viewer is `view.me` when sent, else matched by name + callsign with
  `session.officer`. A cross-department note appears with 2+ active departments (an empty department tag is
  not counted). Long names and callsigns are ellipsised.
- **Radio Silence**: a note panel; the screen never shows coordinates or distances to NPCs/objectives, and shows
  `area` (street · zone) when the server sends it. The start route status still shows.
- **Business Check log** (`view.log` while In progress): one button per `log.choices` entry (server-translated
  labels) → client action `logResult { point, choice }`. After an ok the panel shows "Logged" until the view's
  log point changes (the server moved on); if the same point is still asked 6 s later (the server refused the
  log) the buttons come back.
- **TEST RUN** banner (`hud.test_run` + note) for test runs; expected cash says "Test run: not paid".
- Empty state "No active mission" with "Open the Mission Board"; loading only on the first fetch; error state
  with retry. Push `run`: a pushed view is applied as it is (no extra getRun per push: the RunBar already
  refetches on every push and getRun allows 6 calls per second); nil (`CP.Tablet.push(src, 'run', nil)`, which
  reaches the NUI with no `data` field, i.e. undefined) triggers a getRun, which shows the empty state. Every
  15 s as a safety net. In progress without a timer (never sent today) the timer says "No run timer".

## Response shapes defined here (src/types/run_ui.ts, all extras optional)
- `MissionBoardData` = BoardData with `operation: BoardOperation | null` and `serverTime?: number`.
- `BoardOperation` = §9.4 operation + `missionType?`, `missionTypeLabel?`, `description?`, `min?`, `runState?`
  (what `CP.Operations.boardCard` already sends, docs/notes/teams.md).
- `ActiveMissionData` = ActiveMissionView + `me?: number`, `isBoss?: boolean`, `operationId?: number | null`,
  `startIn?: number | null` (seconds left to reach the start), `area?: string | null` (street · zone).
- Replies: `AcceptTypeResult { runId }`, `JoinOperationResult { id, joined, max }`, `AbandonResult { runId }`,
  `RecalcRouteResult { recalcsLeft }`, `SetGpsResult { runId }`, payload `LogResultPayload { point, choice }`.

## Browser mocks (src/mocks/run_ui.mock.ts)
- `?board=normal | unit | member | locked | busy | oncall | boss | bossused | operation | opjoined | oprunning |
  opwaiting | opclosed | empty | error | edge` (`&oncall=1` combines "on a call" with any variant) and
  `?runv=none | accepted | offroute | progress | test | log | silence | boss | untracked | edge`. `edge` answers
  the way Lua's JSON encoding arrives (empty lists as `{}`, nil fields missing, no optional extras, very long
  labels/names, missing callsigns, a 3-choice log); `empty` sends `cards: {}`.
  (default none, or progress while the dev panel's run toggle / `?run=1` is on). The `getRun` mock is a normal
  registration, so it overrides core.mock.ts's fallback; it follows `devState.runActive`.
- Accepting a type starts a simulated run (random mission of that type, 25% modifier, route distance shrinking,
  In progress after ~10 s, objectives advancing, completed result card); Abandon ends it with the result card and
  puts the type on a 5-minute cooldown on the board; the Business Check log moves to the next door after a
  pick; Set GPS / Recalculate route fake the modules/route toasts; Join increments the operation.
- Error answers use the owners' keys: `err.invalid_type`, `err.already_on_run`, `err.not_leader`,
  `err.operation_locked`, `err.on_call`, `err.boss_unavailable`, `err.boss_used`, `err.type_cooldown`,
  `err.member_type_cooldown`, `err.pool_empty`, `err.server_busy`, `err.op_*`, `err.invalid_payload`,
  `err.invalid_run`, `err.not_on_run`, `err.route_*`, `err.internal`.

## Requests to other modules
- **draw (engine_a)** — add `serverTime = os.time()` to BoardData (`CP.Draw.boardCards`), so cooldown countdowns
  never depend on the client clock; keep `locked.until` as an `os.time()` stamp. Also add
  `todMultiplier = Config.Events.todMultiplier`: the Type of the Day texts ("{multiplier}× today") use it and
  fall back to the default 2 without it, so a changed config value would otherwise be shown wrong.
- **runs (engine_b)** — `CP.Runs.view(run, src)` already sends `me`, `isBoss`, `operationId` and `startIn`
  (modules/runs/server.lua header, done). Still open: optional `area` (street · zone of the current objective,
  e.g. from the host client's `GetStreetNameAtCoord`/`GetNameOfZone`), shown when present; and please push the
  `run` topic right away when the current objective's `state.log` changes (a new point or closed), so the log
  panel moves on without waiting for the 2 s progress push.
- **operations (teams)** — optional `joinBlocked` (locale key) in `boardCard` when `canJoin` is false (on a
  call, in the arena, on a run, full, closed), so the card can say exactly why; today the hint is derived.
- **tablet** — nothing; the screens use `useRequest`/`useAction`/`clientAction` as documented.
- **locale merge** — `run_ui.json` only adds `board.*` / `run.*` keys that no other part defines; it relies on
  ui.json (`common.*`, `hud.*`, `tier.*`, `ui.screen.*`) and on engine_a's translated `board.locked_*` /
  `board.boss_*` reasons (server side).

## Tests and checks
- `lua5.4 tests/run.lua run_ui` → locale part (flat strings, namespace, no ui.json redefinition, identical text
  for shared keys, placeholders, CP.L interpolation through shared/locale.lua), every screen key exists and every
  part key is used, every mock error/text key exists in some part, contract names in the screens and mocks, CSS
  rules (only `--cp-*` variables, no hex/color-mix/:has, every selector scoped by `run_ui-`), no SQL, and the
  **Lua producers** (parsed from the real module files): CP.Runs.view returns every ActiveMissionView field of
  `web/src/shared/types.ts` plus the extras; partners/objectives/expected/modifier/route shapes; CP.Route.status
  only returns on/off/arrived/disabled; setGps/recalcRoute/logResult are registered with the payload/reply the
  screen uses; the interact_points log state; CP.Draw.boardCards / CP.Events.bossCard produce every BoardCard /
  BoardData field (boss key `weekly_boss`, translated `locked.reason`, `locked.until` stamp);
  CP.Operations.boardCard produces the §9.4 fields and extras and every active status is handled; the owners
  register getMissionTypes/getRun/acceptType/joinOperation/abandon; units and operations push `board`.
- `npx tsc --noEmit` clean; `vite build` to the private dist dir; screenshots (1920×1080 and 1280×720) of every
  board and run variant plus interaction flows (log → next point, recalculate to 0, abandon → cooldown on the
  board, join, accept → In progress).

## Review (adversarial pass)
Fixed in this slice: the Active Mission screen ignored a `run` push carrying nil (it reaches the NUI as a
missing field, not null) and fired an extra getRun for every pushed view; the Mission Board refetched once per
push (bursts could hit getMissionTypes' 4/s limit and leave a stale board until the 30 s poll) and on every run
view; an abandon could be undone on screen by a getRun still in flight; a `joining` operation whose window was
closed said "Joining open" / "can't join right now"; unit on-call texts blamed the viewer; the cross-department
note counted an empty department tag; a wide cash range was cut off; long callsigns wrapped; test runs with the
start route off lost Set GPS once In progress; the Accepted objectives note contradicted the listed objectives.
The Type of the Day texts no longer hard-code "2×" (Config.Events.todMultiplier; optional `todMultiplier`).
Still open (other modules, see Requests): `BoardData.serverTime` and `todMultiplier`, `view.area` for Radio Silence, an immediate
`run` push when the Business Check log point changes, `boardCard.joinBlocked`.
