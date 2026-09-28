# safety · notes (route, calls, alerts, downed: Hard rules 15–18)

Files: `Crimson-Police/modules/route/{server,client}.lua`, `modules/calls/server.lua`,
`modules/alerts/server.lua`, `modules/downed/{server,client}.lua`, `locales/parts/safety.json`,
`tests/safety_spec.lua`. Each file's header comment lists what it owns and its public API.
None of the rules has a config switch; only the numbers come from `Config.Route` / `Calls` / `Alerts` /
`Downed`, read at call time.

## Events

| Event | Direction | Args | Notes |
|---|---|---|---|
| `server:routeStatus` | C → S | runId, metres, coords | plain `RegisterNetEvent`; ≥ 0.9 s apart per player (and CP.Net.rateOk 3/s) |
| `server:recalcRoute` | C → S | runId | plain; 1 per 2 s; always answered with `client:routeRecalc` |
| `server:pickupDone` | C → S | runId, ok (boolean, optional) | plain; **new** (owned by downed); 2 per 5 s |
| `client:routeWarning` | S → C | runId, secondsLeft \| nil | every second while the warning is shown; nil = warning withdrawn |
| `client:routeRecalc` | S → C | runId, ok, recalcsLeft | the third argument is an addition (the Active Mission screen shows it) |
| `client:routeStatus` | S → C | runId, RouteStatus | **new**: sent when the server marks the arrival (`status = 'arrived'`) — the "routeStatus reply" |
| `client:pickup` | S → C | runId, dropOff (vector3) | |
| `client:pickupCancel` | S → C | runId | **new**: the server cancelled a pick-up it had already sent (in the arena, recovered, unload); the client fades back in and never teleports. Not sent when the client itself gave up |
| `client:requestEMS` | S → C | runId | |

Client actions (`CP.Tablet.registerClientAction`): `setGps` (payload ignored; re-sets the waypoint to the
start, the sampled line is unchanged) → `{ runId }`; `recalcRoute` (payload ignored) → `{ recalcsLeft }` or
`err.route_inactive | err.route_arrived | err.route_disabled | err.route_no_recalcs | err.busy | err.timeout`.

## Contract interpretations

### CP.Route
- **Distances are 2D** (arrival radius, drift, straight-line `distance`): starts and search circles are map
  circles. `status().distance` is the straight line to the start; the client HUD `route.distance` is the
  distance still to drive along the fixed polyline.
- **Off-route timing.** Off route starts at the first report above `maxDeviation`, or `reportTimeout` s after
  the last accepted report (so silence warns 20 s and abandons 40 s after the last report with the default
  numbers). The warning is sent after `warnAfter` s off and then every second with the seconds left; the
  abandon comes after `abandonAfter` s off in one stretch. A report within `maxDeviation` ends the stretch
  and withdraws a shown warning (`client:routeWarning(runId, nil)`).
- **A report counts only** when the runId is the sender's active run with a route state, metres is a finite
  number ≥ 0 and the reported coords are within `maxDeviation` (2D, but never less than 150 m, so a small
  configured `maxDeviation` cannot reject honest reports sent at speed while the server position lags) of the
  server-side ped position. Anything else is ignored, i.e. it counts as a missing report.
- **Tablet**: SPEC says the warning shows "on the HUD and the tablet". The HUD gets `client:routeWarning`; the
  tablet (run bar / Active Mission) reads `CP.Runs.view` and only refreshes on push topic `'run'`, so the view
  is pushed (`CP.Tablet.push(src, 'run', CP.Runs.view(run, src))`) when the warning appears, when it goes and
  after a granted recalculation (the NUI counts `secondsLeft` down itself).
- **The first report** has `reportTimeout` s from `begin` (the client needs up to ~5 s to find the GPS route).
- **Recalculate** (≤ `maxRecalcs`) ends the current off stretch and gives a fresh `reportTimeout` (the client
  resamples from where the player is). The drift reference (closest distance) is not reset.
- **Manhunt**: the missions give `start = { coords = centre, radius = 600 }`; additionally, when objective 1
  is a `search_area`, the larger of `location.start` and its starting circle (`location[obj.center]`,
  `obj.startRadius`) is used.
- **Safety net**: the 1 s tick also begins the route for any active, not yet arrived participant of an
  accepted / in-progress run that has no route state (unless `stop` was called for them), so Hard rule 17
  cannot be skipped by a missed `begin`. `CP.Runs` calls `begin` itself at create (it does).
- **Arrival** calls `CP.Runs.markArrived` in its own thread and then makes sure the flag is on
  (`CP.Alerts.set`, idempotent — the engine sets it in markArrived). The arrived state is kept (with its
  recalc count) so `status()` keeps answering `arrived`.
- **Client**: the route is read from a temporary route blip (`SetBlipRoute`, `GetGpsBlipRouteFound`,
  `GetGpsBlipRouteLength`, `GetPosAlongGpsTypeRoute` slot 1, then slot 0), which is removed after sampling;
  the player follows the waypoint (`SetNewWaypoint`). If no route appears within 5 s the straight line is
  used, logged, and the player gets `route.no_gps`. `CP.Route.stop()` never touches the HUD and removes the
  waypoint only while it still points at our start; a stopped run is never begun again on that client.
  The client also reacts to `client:start` (1 s later, only for the latest start and never for a run that
  already ended or stopped) as a fallback for a missed `CP.Route.begin`.

### CP.Calls
- Order: NPC prefix on the normalised id (no lookup at all) → `CP.Dispatch.lookupActiveCall` (only a hit
  counts) → NPC prefix again on the canonical id → own-run prefixes → real call.
- **Own-run ids** match any participant of the sender's run, **including partners who already left** (a
  downed partner's `playerdown_<src>_…` must not end the others' runs) and the sender themself. A sender who
  is not on a run gets a real call for the same id.
- The responding map is keyed by the canonical id the lookup returns; the raw id form is kept as an alias,
  so `callCleared` and un-marks in either form find the entry.
- **Dodge rule**: an un-mark within `dodgeWindow` s of the free abandon reclassifies when it is the same
  call, or an id the sender never marked (a form we could not match must not let a dodge through). An
  un-mark of a different call they had marked does not.
- **Quick on/off toggles**: listeners run in their own threads and a mark yields twice (the mdt_dispatch
  lookup, then the row write inside `removeParticipant`). An un-mark that arrives during the lookup is kept on
  the pending mark (no responding entry is recorded; the run still ends as `real_call` and is reclassified at
  once); one that arrives while the row is written is applied right after `removeParticipant` returns
  (`CP.Runs.reclassify` needs the row). Either way the toggle ends as `real_call_cancelled`.
- A dispatcher detach also arrives as `ToggleResponding(false)` from the officer's own client and cannot be
  told apart, so a detach within `dodgeWindow` s counts as an un-mark too.
- `isOnCall` re-checks each live entry in mdt_dispatch at most every 10 s (it may yield).
- Every free abandon is audited: `CP.Admin.audit(citizenid, 'officer', 'flags', 'free_abandon', runId, nil,
  callId, '<text with the count in the last 24 h>')`; a reclassification as `'real_call_cancelled'`.

### CP.Alerts
- **Choice for in-arena participants**: this module removes them itself — `CP.Runs.removeParticipant(run,
  src, 'quit', { notify = 'run.left_for_arena' })` (from the change handler's queued work and the 1 s
  reconcile), after dropping the intent without touching the bag, `CP.Route.stop` and `CP.Downed.cancel` —
  and also exposes `CP.Alerts.onInArena(fn(src, run))` listeners (called afterwards). The engine's own 1 s
  re-check does the same; whichever runs first removes, the other finds the participant already left, and
  the toast is only sent by the engine when it really removes.
- `foreignClearedAt` is a **table** (`CP.Alerts.foreignClearedAt[src] = os.time()`), as §5.14 and the
  engine's item sweeps use it.
- `set` also refuses in a routing bucket ≠ 0 and over any non-nil value that is not ours (not only a
  foreign one); `clear` of a downed participant's flag is ignored while `CP.Downed` holds it
  (`CP.Alerts.hold`), unless `{ force = true }`.
- Orphans: an intent whose run no longer lists the player as active (and no pending downed follow-up) is
  removed after 3 s (leak guard).
- Backstop eligibility for shots: our intent is on, or an arrived active participant of an In-progress run;
  the radius is 3D from the location start or `CP.Runs.anchor(run)` (current objective point). Person
  down/dead: our intent only. An id of second s is skipped only when an earlier clear of it ran at s + 2 or
  later (within 15 s): a clear that ran sooner (the t + 1 id of the previous second's event) may have come
  before that call existed, so the next event clears it again.
- `foreignClearedAt` is recorded from the change handler's view of the old value (FiveM calls the handler
  before the value is set), so an arena exit counts even when this module never saw the foreign value
  (e.g. Crimson-Police restarted while the player was in a match).

### CP.Downed
- **EMS on duty and our flag was not on** (down before reaching the start): no `client:requestEMS`.
  sc-ambulance's client sends its own EMSDownAlert on entering last stand (every down passes through last
  stand) unless the flag suppresses it, so a second request would give EMS two calls.
- `run.stats.downs + 1` is done only when `CP.Runs.removeParticipant` did not already count the down
  (the engine does), so a down is never counted twice.
- The pick-up re-checks EMS after the delay: EMS that came on duty meanwhile gets the EMS path instead.
- Timings: the revive follows `client:pickup` after 1.5 s (fade-out); the flag is removed on
  `server:pickupDone` or 30 s after the revive; the client waits up to 20 s for the revive.
- Client "revived" = metadata isdead / inlaststand both false AND the ped not dead; no metadata at all
  (`CP.Qbx.getPlayerData()` is `{}` after a logout / character switch) is never "revived": the pick-up
  aborts (fade in, no teleport). A server cancel after `client:pickup` went out is sent as
  `client:pickupCancel`.
- **Every participant downed** (what I rely on): `CP.Runs.removeParticipant` ends a run that has no active
  participant left and reports the state as `failed` when the last one left with a failed result (the
  engine does this). As a guard, if a down removed the last active participant and the run is still open
  5 s later, `CP.Downed` calls `CP.Runs.endRun(run, 'failed', 'mission_failed')`.

## Requests to other modules
- **CP.Runs (engine_b)** — already matching: `markArrived` sets the flag, `removeParticipant` honours
  `keepFlag` / `notify`, calls `CP.Route.stop`, and ends a run with nobody left (failed when the last result
  is failed); `endRun` only clears flags of participants still in the run. Please keep `endRun` away from
  participants who left with `keepFlag` (their flag belongs to CP.Downed until the pick-up / EMS request).
- **CP.Ambulance (integrations)** — CRIMSON_ARENA rule 3: `revive(src)` should refuse and log for an in-arena
  src (`CP.Alerts.inArena`); CP.Downed re-checks right before calling it anyway.
- **CP.Tablet / web** — the Active Mission screen calls the client actions `recalcRoute` and `setGps`
  (payload ignored) and can show `data.recalcsLeft` from the reply. `CP.Tablet.hud({ route = ... })` is sent
  with `secondsLeft` / `distance` omitted when null.
- **ARCHITECTURE §8** — please list `client:routeStatus` (runId, RouteStatus), the third argument
  `recalcsLeft` of `client:routeRecalc`, `client:pickupCancel` (runId) and `server:pickupDone` (runId, ok)
  (plain event, owner downed).
- **Locale merge** — `err.busy` and `err.timeout` are copied verbatim from `core.json`; `run.left_for_arena`
  has the same text as in `engine_b.json` ("You left your mission because you entered the arena.").
