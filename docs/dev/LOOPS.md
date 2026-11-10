# Loops and timers

Every repeating loop of Crimson-Police: where it is, what it does, when it runs, its interval and why that interval.
"before -> after" shows an interval the owner asked to be slower ("make it occur less often"); a single value was
checked and kept. A value marked *scaled* is multiplied by `Config.Performance.loopScale`.

## The rules

- **Per frame (`Wait(0)`)** only while something is drawn or a control is read every frame, and only while that
  feature is on (a marker in range, the Escape guard after a close, a builder tool open). Otherwise the loop sleeps
  (1000-2000 ms when far or idle, 250-1000 ms when near).
- **One thread per purpose.** Each loop has a guard (`S.drawing`, a token, `running`, `watching`): a second start
  extends or reuses the running one.
- **Loops end with their feature**: run end (`current == run` / `S.alive` / tokens), tablet close (`openToken`),
  option or switch off, resource stop (FXServer ends every thread).
- **Inside a loop**: `cache.ped` instead of `PlayerPedId()` (tests/frame_loops_spec.lua), squared distances or
  `#(a - b)` on vectors, no new table per pass, cheap checks first.
- **Server ticks**: the slowest interval that still meets the feature's own deadline (timeouts, expiries, sweeps).
- **NUI polling** (`useRequest` `pollMs`): only on screens of the open tablet. The layout unmounts when the tablet
  closes, so every poll stops with it; screens with a server push (`pushTopic`) poll only as a safety net.
- **Idle game**: with no run, the tablet closed and every feature off, no client thread of Crimson-Police wakes once
  the start-up waits are over (tests/loops_spec.lua). On the server, every per-run tick sleeps with no run (
  tests/server_cost_spec.lua).
- **Census**: every file with a thread, a `while true do` or a web timer has a row in "Loop census" below
  (tests/loop_census_spec.lua).

## The loop scale

`Config.Performance.loopScale` (1-4, shipped `1.0`, Admin UI → Settings) multiplies the idle and far waits through
one helper, `CP.Perf.ms(ms)` (shared/init.lua). It never touches a per-frame wait (`Wait(0)`), a near or "control
asked" pass, the run engine's 1 s tick (run deadlines, HUD timers) or a server deadline tick. `1` is the table below,
`2` wakes those loops half as often again (tests/loop_pace_spec.lua).

User-visible intervals stay config options with their unit (for example `Config.Route` `every`,
`Config.Downed.checkEvery`, `Config.MissionCalls.checkEvery`, `Config.AntiCheat.jobRecheck`,
`Config.Tablet.pauseGuardMs`).

## Resmon

Owner: "Optimize everything and debug everything then help make resmon better also help with making loops more
efficient". LP1 and LP2 set when each loop runs; OP1 trimmed what a pass does. `tests/resmon_spec.lua` loads every
client script and counts each native a Crimson-Police file calls (and the Lua memory a frame allocates);
`tests/fixtures/npc/client_check.lua` counts the pacer's. Numbers are from the harness, before -> after:

| What | Measure | Before -> after |
| --- | --- | --- |
| idle (no run, tablet closed), two minutes | natives called | 0 -> 0 (no thread wakes, tests/loops_spec.lua) |
| checkpoint course, in a car inside the checkpoint, course running | natives a frame | 13.3 -> 10.3 (no `PlayerPedId()`: `cache.ped`; one `GetGameTimer` a frame) |
| the same | Lua memory a frame | 0.30 KB -> 0.00 KB (the "Stop inside" / "Hold still" / "drive a vehicle" line looked up once, not every frame) |
| the same | undriveable check (3 natives) | every frame -> every 100 ms sample (its retry is 3 s) |
| tired runner pacer, one runner, 60 frames | natives for the runner | 369 -> 221 (cap and move rate every frame, plus one clock read; entity, owner, vehicle and death every 100 ms instead of every frame) |
| HUD patches from the server that change nothing | NUI messages | one per patch -> none (21 identical patches: 22 -> 1 message) |
| a 'local' officer option read (sound cues, HUD target line, GPS mode) | KVP JSON decodes | one per read -> one per KVP change (100 reads: 100 -> 1) |

Also: the marker loops of escort, flee_arrest, process_scene and protect_rescue compare squared distances
(`CP.U.distSq`, no square root a frame); search_area's 250 ms suspect loop reads `cache.ped` and formats its circle
key once per snapshot, not every pass.

Checked and kept: no client thread runs at idle; event and state bag handlers cost nothing until their event
fires; ox_target zones and options of a block are added on its start and removed on its stop; no client -> server
event is sent per frame (telemetry: a vehicle sample every 5 s while driving, lights and siren and the first shot
once); `ctx.hudDetail` lines are sent only when the text changes.

## Server cost and NUI

Same owner request as OP1, for the server, the network and the tablet page. `tests/server_cost_spec.lua` loads the
real server side (the world of `tests/e2e_spec.lua`: 11 officers on duty, no run) and counts every MySQL call of two
idle minutes after the caches are warm; `tests/nui_bundle_spec.lua` reads `web/dist`. Before -> after:

| What | Measure | Before -> after |
| --- | --- | --- |
| idle server, 11 officers on duty, 120 s (calls rng fixed) | SQL calls | 133 -> 67 |
| an officer's tablet check (`CP.Access.getOfficer`: suspended? retired?) when its 15 s cache runs out | SQL calls | 2 -> 1 (`ReadOfficerState` fills both caches) |
| a mission call's pop-up check per officer (`calls_muted` and the callAlerts favourites), once per 30 s | SQL calls | 2 -> 1 (one row read; `CP.Options.effective` gets its options text) |
| the script every player's NUI loads at start (`web/dist` entry) | bytes | 1 161 475 -> 549 545 (gzip 306 -> 154 KB) |
| the stylesheet | bytes | 242 721 -> 242 721, byte for byte the same (`web/src/styles/order.ts`) |
| an admin who leaves in the middle of a logo upload | memory | his chunks kept 60 s (and the next player with his id refused with "busy") -> forgotten on `playerDropped` |
| `Config.Performance.pushGapMs = 300`, three pushes of one topic to one player at once | client events | 3 -> 2 (the first at once, the others merged and sent when the gap is over); shipped `0` = 3, as before |
| `Config.Performance.latentAboveBytes = 2000`, a 200-row list answer to the tablet | reliable events | 1 big reliable reply -> a small reply plus a latent event at `Config.Limits.exportBps`; shipped `0` = as before |

How the push gap merges (`modules/access/tablet.lua` `T.push`): per player and topic; the newer data wins. A view
topic (`run`, `options`, `unit`, `calls`, `nav`, `missionControls`, ...) is replaced whole, so a field the newer push
dropped (`readyCheck`, `activeRunId`) stays dropped; `unit` keeps only its `invited = true` hint. Only the hint
topics (`board`, `rewards`, `invites`, `test`, `profile`, `payouts`) keep the keys the older table had. Event
topics (`builder`: one `{ event, id }` per push) are never held. A held push is sent by one `SetTimeout`, not a
loop, and `playerDropped` forgets it.

Lazy screens (`web/src/layouts/screens.ts` `lazyScreen`): the Admin UI screens and the Supervisor Mission Builder;
`App.tsx` loads the criminal tablet the same way. Opening (or switching to) a UI starts loading all of its lazy
screens at once (`preloadScreens`), and `ScreenHost` keeps the sidebar and header on screen while one loads.

Checked and kept: the run engine's 1 s tick, the route, custody, NPC and live crime ticks send no SQL (they work on
memory); boards, season points and Type of the Day are cached with invalidation (`CP.Leaderboard`), the no-repeat
history and cooldowns of mission calls are read once per officer and type until a new row; the saves folder engine
looks rows up by key (no table scan for `WHERE citizenid = ?`); every per-player table of the server modules is
cleared on `playerDropped` or pruned by its sweep (`alerts` `wasInArena`, `npccombat` by the run's end); the App
keeps the open tablet from re-rendering on HUD, toast and overlay updates (its layout element depends on the UI
kind only), and every screen poll stops when the tablet closes.

## Second pass

Owner: "redo the optimization of the entire script redo the entire optimization of all loops". LP1/LP2 (when loops
run), OP1 (client frame cost) and OP2 (idle SQL, pushes, the NUI bundle) were kept; OP3 looked for what they missed:
work repeated inside one request, one ox_target pass or one draw, and lookups that read a whole table. Numbers are
from the harness, before -> after:

| What | Measure | Before -> after |
| --- | --- | --- |
| one ox_target pass over a contacted person and a stopped car with three seats (every contact, custody, seat and cuff option of `modules/npc/client/npc.lua`) | entity checks (`DoesEntityExist`, `NetworkGetEntityIsNetworked`) | 96 -> 10 (once per entity per frame, with the bag) |
| the same | run lookups (`CP.Runs.current`, a pcall each) | 82 -> 1 |
| the same | `IsPedInAnyVehicle` / `PlayerPedId` | 34 / 35 -> 1 / 2 |
| the same | Lua memory | 1.47 KB -> 0.80 KB (no new bag table a frame, no closure per bag read; the rest is the harness' own `Entity()` stand-in) |
| a mission desk's canInteract, 50 asks within a second | Qbox `GetPlayerData` export calls | 50 -> 1 (the department is kept up to 1 s, forgotten at once on a job, duty, login, logout or settings change; the arena state bag is read last) |
| one admin action (`CP.AdminKit.action`) | `IsPlayerAceAllowed` calls | 2 -> 1 (the guard hands its isAdmin answer to `CP.Permissions.can`) |
| one admin read (`CP.AdminKit.callback`) | `IsPlayerAceAllowed` calls | 2 -> 1 |
| one supervisor action (`CP.AdminKit.supAction`) | `IsPlayerAceAllowed` calls | 6 -> 4 |
| the auto-suspension check, the flagged-run notes of a run list, the Type of the Day and mission control overrides, the publisher lookup, the reward take-back check, the per-day caps (`cp_audit`) | rows read per lookup | the whole audit log -> the rows of that target or action (migration 017: `idx_audit_target`, `idx_audit_action`) |
| a dispute looked up by its run (`cp_disputes`) | rows read | the whole table -> that run's rows (`idx_dispute_run`) |
| Settings: typing in the search box or saving one setting | rows drawn again | every row on the screen -> only rows whose data changed (`SettingRow` is memoized, `save` and `reset` keep their identity) |
| An 800-row table in a scroll box (Leaderboards) | table rows drawn | 801 -> under 50 (the rows in view, 12 above and below, two spacers) |
| Settings search with hundreds of matches | rows drawn at first | every match -> 60, then 60 more each time the end is within 600 px |

How it was found: `CP.Storage.MemSQL.scanMeter` (nil in the game) counts the rows each whole-table read of the saves
folder engine hands over; run over the idle server (`tests/server_cost_spec.lua` world, 120 s) it found none, and over
`tests/e2e_spec.lua` it found the `cp_audit` and `cp_disputes` lookups above. The other whole-table reads it lists are
lists that are paged or summed on purpose (an Admin list ordered by date, a board build that is cached).

Checked and kept: `shared/net.lua` does one rate bucket, one start check and one maintenance check per request;
`CP.Access.getOfficer` reads Qbox through the 1 s player info cache and the suspension and retirement through their
15 s cache; the block ox_target options (flee_arrest, search_area, skill_check, interact_points,
protect_rescue, process_scene) read only their own Lua tables; the Activity log, Payments made, Officers and an
officer's runs are paged on the server (`Config.AdminUi.pageSize`); the Mission Builder list is filtered in a
`useMemo` and holds tens of rows. Specs: tests/fixtures/npc/target_check.lua (g), tests/access_spec.lua (desk),
tests/server_cost_spec.lua (ace checks), tests/foundation_spec.lua (017), web/src/shared/rowWindow.walk.ts.

## Every loop, second pass

Owner: "redo the optimization of the entire script redo the entire optimization of all loops". LP1/LP2 (when loops
run), OP1-OP3 (what a pass costs) were kept; LP3 went through every row below and every `CreateThread`,
`SetTimeout`, `while true`, `setInterval`, `setTimeout` and `requestAnimationFrame` of the code, asking: can it be
event-driven, can two loops on the same data merge, does it stop with its feature, is its far wait scaled, is a
per-frame radius as small as it can be. Numbers are from the harness, before -> after:

| What | Measure | Before -> after |
| --- | --- | --- |
| the Officer UI open for a minute, `requireItem` on (tests/loops_spec.lua) | tablet threads / wakes | 3 / 118 -> 2 / 88 (the downed, desk and item checks are one watcher: 60 + 30 item checks folded into its 60 passes; the animation keeper is the other thread; same timing: downed and desk every 1 s, item every 2 s) |
| an idle server with no happy hour, 10 minutes (tests/happy_hour_spec.lua) | happy hour loop wakes | 20 -> 0 (the end check runs only while one may be on; while one runs it still checks every 30 s and hears the end) |
| `Config.Performance.markerRange = 10`, a skill check device 20 m away (tests/loop_pace_spec.lua) | per-frame passes in 6 s | every frame -> none (the loop sleeps at its 1.5 s far wait); shipped `0` = every marker at its own distance, as before |

Checked and kept:
- Event-driven already: the crimsonArena, cp and arena bag handlers, the Qbox job, duty, load and unload hooks, the
  ox_target zones and options of a block (added on start, removed on stop), the unit invite cue and ready check, the
  mission call pop-ups, the HUD pushes. The admin push queue and the spawn asks loops run only while they hold work.
- Polls with no event to replace them: being down (the death and last stand screens have no event shared by every
  ambulance script), the tablet item (ox_inventory sends no count change to other resources), the last game input of
  Auto-Ready (only control reads see it; it runs only while the option is on), the walk-away distance at a desk (a
  zone exit would need a second ox_lib zone per desk for the same 1 s answer).
- Not merged: the tablet's animation keeper has its own token (the prop lives across a reopen); the criminal
  tablet's downed watch belongs to another UI with its own token; the block loops each draw their own objective and
  end with it.
- Deadlines stay exact: the server deadline ticks (run engine, route, custody, NPC, live crime) keep 1 s; the unit
  ready check keeps its timer at the deadline; the checkpoint course keeps its own 150 m view distance, because
  inside it the same pass samples your pass through the checkpoint, so `markerRange` does not apply to it.
- Start-up waits (the client actions of custody, runs and testing waiting for `CP.Tablet.registerClientAction`, the
  settings list, the mission definitions) find what they wait for on their first pass in a normal start and end.

## Final loop proof

Owner: "Ensure all loops are efficient optimized and is used to the best of its capabilities and can't be further
improved". LP4 asked five questions of every loop, timer and poll (the census at the end lists every file that has
one; `tests/loop_census_spec.lua` fails when a file gains or loses a `CreateThread`, a `while true do` or a web/src
timer without its row):

1. **Event**: could it be event-driven instead? (yes -> converted now)
2. **Active**: does it run only while its feature is active, and stop at once after?
3. **Interval**: is it the slowest that still meets its deadline, with deadline-exact work on a timer at the
   deadline rather than a sweep?
4. **Pass**: is the per-pass work minimal (natives hoisted, no allocations, cheap checks first, squared distances,
   cached config)?
5. **Merge**: is it merged with any other loop over the same data?

Every "no" was fixed. Numbers are from the harness (`tests/server_cost_spec.lua`: the real server side, 11
officers on duty, no run, two idle minutes after start-up; `web/src/shared/countdown.walk.ts`), before -> after:

| What | Measure | Before -> after |
| --- | --- | --- |
| the run engine's 1 s tick, job recheck and 60 s maintenance (the first two over the same runs, all awake all day) | threads / idle wakes in 2 min | 3 / 134 -> 2 / 2 (the tick and the recheck are one engine thread, armed by a run or an orphaned item; the 60 s cache housekeeping stays) |
| custody timers, the NPC watcher, the drive-to-start check (1 s each, all day) | idle wakes in 2 min | 120 each -> 0 (each armed by a run, a custody book or a tracked participant) |
| the downed check (`Config.Downed.checkEvery` 2 s, all day) | idle wakes in 2 min | 60 -> 0 (armed by a run or a downed entry) |
| the Testing upkeep (2 s, all day) and the unit sweep (5 s, all day) | idle wakes in 2 min | 60 and 24 -> 0 (armed by a test, an invitation or a waiting result; by a unit) |
| the mission calls screen push (a 1 s loop looking at a flag) | idle wakes in 2 min | 120 -> 0 (one `SetTimeout` 1 s after the first change: same coalescing) |
| a HUD countdown of 10 s (`useCountdown`) | timer wakes | 50 -> 10 (one `setTimeout` just after each whole second, was a 200 ms poll; the shown second changes on time) |

How a tick sleeps: `CP.Perf.armed(tag, ms, pass)` (shared/init.lua) returns `arm()`: it starts the loop unless it
runs; a pass that returns true (nothing left to watch) ends it until the next `arm()`. Each module arms it where its
work appears (`run:created`, a new book, entry, unit or test) and once at start, so a restart with work left (a
happy hour, a waiting Testing result) still ticks. While armed, each pass keeps its old interval and order.

Checked and kept as always-on (every one of them watches online players or a feature that is on all day):
the arena flag reconcile (alerts, 2 s: a lost flag back within two seconds), the anticheat buckets and idle sampling
(1 s: its rules count seconds per player), operations (adaptive 2 s / 10 s), mission call posting (`checkEvery`), and
the minute or longer housekeeping (run engine caches, schedule, challenge reminders, call prune, draw holders, cash
and reward forfeit sweeps): one pass a minute or ten, each over its own module's tables. Merging those into one
thread would save a few wakes a minute and tie the modules' failures together.

### The five questions, loop by loop

"yes" means the loop already does what the question asks; LP4 marks what this step changed.

| Loop | 1 Event | 2 Active | 3 Interval | 4 Pass | 5 Merge | Why it can't be improved |
| --- | --- | --- | --- | --- | --- | --- |
| options/client Auto-Ready input watcher | no event for game input | yes, option on | 250 ms catches a tap | yes, stops at the first pressed control | nothing else reads input | game input is only seen by control reads, and only while the option is on |
| tablet/client prop and animation keeper | no event when another script clears a task | yes, tablet open | 2000 ms, scaled | yes | own token: the prop lives across a reopen | the cheapest check that keeps the animation |
| tablet/client open tablet watcher | no shared death event across ambulance scripts; ox_inventory sends no count change | yes, tablet open | 1000 ms; item every 2000 ms | yes, cache.ped | merged | one thread, one wake a second while open |
| tablet/client, crimtab/client Escape guard | no: a disabled control must be set every frame | yes, `pauseGuardMs` after a close | per frame (required) | yes, one native | one thread each, extended | the game re-enables the pause menu each frame |
| crimtab/client downed watch | as the tablet watcher | yes, criminal tablet open | 1000 ms, scaled | yes | its own UI and token | as the officer tablet watcher |
| markers/client objective pointer | no event for "the player moved" | yes, ends when cleared | 2000 ms, scaled | yes | the one pointer loop | a GPS line needs no faster update |
| route/client drive-to-start report | no event for position | yes, the drive to the start | `Config.Route` every | yes | one per route | the server's own warning deadline |
| runs/client telemetry | no event for vehicle data | yes, on a run | 2000 ms, sample every 5 s by clock | yes | lights, siren and sample in one loop | the server samples too; slower misses the siren |
| runs/client weapon fired | `IsPedShooting` has no event | yes, until the first shot | per frame armed, 1000 ms unarmed | yes | its frame cost only while armed | the shot is true for one frame |
| npc/client AI of owned peds | no event for "stuck" | yes, while it owns any | 1000 ms, scaled | yes | one loop for every owned ped | retasks are not frame critical |
| npc/client combat caps / governor | no event | yes, on a run | 2000 ms, scaled | yes | one loop for every run ped | ends with the run |
| npc/client tired runner pace | no: the move rate override lasts one frame | yes, while a paced ped exists | per frame (required) | yes (221 natives) | one loop for every paced ped | the native must be called every frame |
| npc/client cuff progress guard | no event from the progress bar | yes, while cuffing | 500 ms, scaled | yes | one per cuff | ends with the bar |
| npccombat/client damage re-apply | no event when another script resets it | yes, run live | 2000 ms, scaled | yes | one loop | `reassertAiDamage` |
| testing/client debug drawing | no: drawn lines need every frame | yes, debug on, within 600 m | per frame near, 1000 ms far | yes, cache.ped | one loop | lines vanish after one frame |
| testing/client panel focus watch | no blur event from the game | yes, panel focused | 250 ms | yes | one loop | ends on blur |
| builder/client placement, recording, drive test | no: draws and reads controls | yes, a tool open (admin) | per frame (required) | yes, cache.ped | one loop per open tool | admin only, never at play |
| blocks marker loops (escort, flee_arrest, process_scene, protect_rescue, search_area, skill_check, interact_points) | no: markers need every frame | yes, objective current | per frame in range (`markerRange`), 1500 ms far | yes, squared distances, hoisted ranges | one per objective | far away they sleep |
| blocks suspect AI (flee_arrest, search_area, pursuit, field_contact) | no event for distance | yes, objective live | 250 ms near, 2000 ms far | yes | one per objective | reaction time near, cheap far |
| blocks host AI (protect_rescue, escort, hostile_waves, pursuit ram) | no event | yes, objective live | 1000 ms, 250 ms while control is asked | yes | one per objective | AI retasks are not frame critical |
| blocks/checkpoint_route course | no: contact sampling | yes, course on | per frame near, 100 ms running | yes | markers and sampling in one pass | the sampling deadline |
| runs/server engine thread | no event for time | yes, a run or an orphan | 1000 ms: second deadlines | yes | merged with the job recheck | the run deadlines are in seconds |
| runs/server maintenance | no | caches of online players | 60 s | yes | its own tables | housekeeping once a minute |
| route/server drive-to-start | no event for distance | yes, a run | 1000 ms | yes, idle returns at once | its own states | the warning deadline is in seconds |
| custody/server timers | no event for each service vehicle step | yes, a custody book | 1000 ms | yes | its own books | each transport step is one pass |
| npc/server watcher | no death event for server peds | yes, a live run | 1000 ms | yes | its own records | the flee clock adds a second a pass |
| downed/server checks | the meta change is the event; the poll is the safety net | yes, a run | `checkEvery` | yes | its own entries | owner setting |
| opponents/server live crime watch | no | yes, a case or crew tracked | 1000 ms | yes | the live crime scan runs on its tick (`onTick`) | second deadlines |
| alerts/server flag reconcile | no: a lost flag sends no event | players online | 2000 ms, scaled | yes | its own flags | a lost flag back within 2 s |
| anticheat/server buckets, idle, presence | no | players online | 1000 ms, presence 5 s | yes | presence on the same pass | its rules count seconds |
| operations/server | no | adaptive | 2000 ms active, 10000 ms idle | yes | one loop | the join window is minutes |
| spawn/server open asks | no | yes, asks open | 1000 ms | yes | one loop | placement timeouts are seconds |
| units/server sweep | no: an invite expiry is checked on accept too | yes, a unit | 5000 ms, scaled; ready check on its own timer | yes | one loop | invites last 120 s |
| volunteers/server, volunteers/match | no | yes, someone volunteers / a match | 30 s / 2000 ms | yes | one each | minutes-long windows |
| missioncalls/server posting | no: calls are posted over time | always (feature on) | `checkEvery` | yes | posting and expiry in one pass | owner setting |
| missioncalls/server push | converted to a timer | yes, a change | 1 s after the first change | yes | one push per burst | the coalescing window |
| testing/server upkeep | no | yes, a test | 2000 ms, debug 2 s, upkeep 5 s | yes | debug and upkeep in one pass | the debug stream rate |
| admin/server push queue | no | yes, while queued | 50 ms sent, 250 ms else | yes | one queue | ends when empty |
| supervisor/happyhour end | no event when time runs out | yes | 30 s | yes | one loop | the screens hear the end then |
| schedule, challenge, calls, draw (server) | no | always | 60 s | yes | one per module | minute precision |
| cash, rewards forfeit sweeps (server) | no | always | 10 min | yes | one each | the forfeit window is days |
| web `useRequest` polls | pushes refresh at once; the poll is the safety net | yes, screen mounted | 20-60 s | yes | one per screen | the safety net only |
| web nav badges | the `nav` push does the rest | yes, tablet open | 5 min | yes | one per layout | the safety net only |
| web `useCountdown` | no event for time | yes, countdown shows | one timer per whole second | yes | one per countdown | one wake per shown second |
| web `useRowWindow` | on scroll (an event) | yes | one update per frame | yes | one per table | no timer |
| web Builder autosave | no | yes, draft open | `autosaveSeconds` | yes | one per draft | owner setting |
| web Testing clock tick | no | yes, screen open | 30 s | yes | one per screen | "time ago" text in minutes |
| web one-shot timers (toasts, confirm buttons, debounces, retries) | each is a single `setTimeout` | yes, cleared on unmount | their own delay | yes | - | not loops |

Bounded waits (model, animation and collision loads, `NetworkRequestControlOfEntity`, shape tests, network ids,
lock waits, the settings and mission definition waits at start) end at a deadline; one-shot threads (start-up hooks,
async callbacks, audit writes) run once. The census marks them.

## Client loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/access/client/options.lua | Auto-Ready input watcher (last game input) | only while the officer option `autoReady` is on | 250 ms | reads the last input time; ends when the option is off |
| modules/access/client/tablet.lua | tablet prop and animation kept | tablet open | 1000 -> 2000 ms, scaled | other scripts clear tasks rarely |
| modules/access/client/tablet.lua | open tablet watcher (one thread): downed, desk distance, tablet item | tablet open; the desk check at a desk, the item check with `requireItem` on (not at a desk) | 1000 ms a pass, scaled: downed and desk every pass, item every 2000 ms | focus released soon after the death screen comes up; closes within a second of walking away; the server checks the item again |
| modules/access/client/tablet.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, one thread | a disabled control is read every frame |
| modules/realplayers/client/crimtab.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, one thread, extended | a disabled control is read every frame |
| modules/map/client/markers.lua | objective pointer: streaming, nearest target, line | while there is something on the map | 1000 -> 2000 ms, scaled | ends by itself once cleared |
| modules/map/client/markers.lua | extra parts: a car or partner moves onto its entity once streamed in | while such a blip is on the map (Config.Markers.extraParts on) | 1000 ms, scaled | ends by itself once no such blip is left |
| modules/runs/client/route.lua | drive-to-start report | drive to the start | `Config.Route` every (s) | the server's warning deadline |
| modules/runs/client/runs.lua | vehicle telemetry, lights and siren | on a run | 1000 -> 2000 ms, scaled; the vehicle sample every 5 s by the game clock (was every 5th pass) | the server samples the vehicle itself too |
| modules/runs/client/runs.lua | weapon fired | on a run, until the first shot | per frame while armed, 500 -> 1000 ms unarmed (scaled) | `IsPedShooting` is true for one frame |
| modules/npc/client/npc.lua | AI of the run's peds this game owns | while it owns any | 500 -> 1000 ms, scaled; stuck after 4 -> 2 still passes (2 s as before) | retasking is not frame critical |
| modules/npc/client/npc.lua | combat caps / tired runner governor | on a run | 1000 -> 2000 ms, scaled; a still tired runner flees again after 3 -> 2 passes | ends with the run |
| modules/npc/client/npc.lua | tired runner pace | while a paced ped exists | per frame | the move rate override lasts one frame |
| modules/npc/client/npc.lua | cuff progress guard | while cuffing | 250 -> 500 ms, scaled | ends with the progress bar |
| modules/npc/client/npccombat.lua | NPC damage values re-applied | run live | 1000 -> 2000 ms, scaled | `reassertAiDamage` |
| modules/missions/client/testing.lua | test area debug drawing | Testing debug on, within 600 m | per frame near, 500 -> 1000 ms far (scaled) | drawn lines need every frame |
| modules/missions/client/testing.lua | panel focus watch | panel focused | 250 ms | ends on blur |
| modules/missions/client/builder.lua | placement, recording, drive test | a Builder tool open (admin only) | per frame | draws and reads controls |
| blocks/escort, flee_arrest, process_scene, protect_rescue marker loops | objective markers | objective current | per frame in range (capped by `markerRange`), 750 -> 1500 ms far (scaled) | markers need every frame in range |
| blocks/search_area/client.lua | clue markers | objective current | per frame in 150 m (capped by `markerRange`), 750 -> 1500 ms far (scaled) | no allocation per frame |
| blocks/skill_check, interact_points | markers and HUD line | objective current | per frame in range (capped by `markerRange`), 500 -> 1500 ms far (scaled) | far away, a new HUD message shows up to 1.5 s later |
| blocks/flee_arrest, search_area, pursuit, field_contact | suspect AI and reports | objective live | 250 ms near, 1000 -> 2000 ms far (scaled) | reaction time near, cheap far |
| blocks/protect_rescue, escort, hostile_waves | host AI and blips | objective live | 500 -> 1000 ms, scaled (250 ms while control is asked) | AI retasks are not frame critical |
| blocks/checkpoint_route/client.lua | course markers and contact sampling | course on | per frame near, 100 ms while the course runs, 500 -> 1000 ms else (scaled) | contact sampling deadline |

Bounded waits (model and animation loads, `NetworkRequestControlOfEntity`, collision and shape tests, the settings
list and mission definitions at start) all end at a deadline and are not loops of a feature.

## Server loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/runs/runs.lua | engine thread (one thread): run timeouts, arrivals, arena exit sweeps, job recheck | while a run or an orphaned item is kept | 1000 ms; arena sweeps every 5th pass; job recheck every `Config.AntiCheat.jobRecheck` passes | run deadlines and HUD timers are in seconds |
| modules/runs/runs.lua | maintenance | always | 60 s | housekeeping |
| modules/runs/route.lua | drive-to-start safety net | while a run or a tracked participant exists | 1000 ms | the warning deadline is in seconds |
| modules/dispatch/alerts.lua | crimsonArena flag reconcile | always | 1000 -> 2000 ms, scaled | a lost flag is restored within two seconds |
| modules/review/anticheat.lua | buckets, idle, presence sampling | always | 1000 -> 2000 ms, presence 5 s (on the next pass) | idle and bucket rules count seconds |
| modules/npc/custody.lua | custody timers | while a run has a custody book | 1000 ms (kept) | each service vehicle step (road point ask, spawn, drive, park, leave) is one pass: 2 s would make every transport and coroner arrive seconds later |
| modules/npc/npc.lua | death watcher, health, cuff reach, flee clock | while a run is live or a ped record is kept | 1000 ms (kept) | the flee clock adds a second a pass (sprint, jog, walk), and a vanished ped must be seen before the engine's own 2-pass vanish rule |
| modules/realplayers/opponents.lua | live crime watch | while a case or crew is tracked | 1000 ms (kept) | second deadlines: the lost rule, the disconnect grace, AFK and the trail |
| modules/teams/operations.lua | operations | always | 1000 -> 2000 ms active, 5000 -> 10000 ms idle (scaled) | adaptive; the join window is minutes |
| modules/runs/spawn.lua | open spawn asks | while asks are open | 500 -> 1000 ms | placement timeouts are seconds |
| modules/teams/units.lua | invite expiry, lock safety net | while a unit exists | 2000 -> 5000 ms, scaled | invites last 120 s; accepting checks the expiry itself. A ready check has its own timer at the deadline, and Units.ready refuses an answer after it |
| modules/realplayers/volunteers.lua | volunteer window and duty | while someone volunteers | 15 -> 30 s, scaled | the window is minutes; its end is checked at the draw (`V.available`), so the sweep only tidies |
| modules/realplayers/match.lua | asking, travel, engagement | while a run has a match | 1000 -> 2000 ms | the travel time is minutes |
| modules/dispatch/missioncalls.lua | call posting and expiry | always | `checkEvery` s | the feature is on all day |
| modules/dispatch/missioncalls.lua | coalesced screen push | a change | one `SetTimeout`, 1 s after the first change | a burst of changes is one push |
| modules/missions/testing.lua | debug stream, invites | while a test, an invitation or a waiting result is kept | 1000 -> 2000 ms base, debug 2 s, upkeep 5 s (on the next pass) | |
| modules/runs/downed.lua | downed checks | while a run is live or an entry is kept | `Config.Downed.checkEvery` s (min 0.5) | owner setting |
| modules/map/markers.lua | the extra parts of each officer's map | while `Config.Markers.extraParts` and a part are on and a run is going, or a map still has parts | `Config.Markers.refreshEvery` s (1-30), scaled | owner setting; a list is sent only when it changed |
| modules/admin/admin.lua | admin push queue | while queued | 50 ms sent, 250 ms else | ends when empty |
| modules/system/schedule.lua | daily jobs | always | 30 -> 60 s | minute precision |
| modules/supervisor/happyhour.lua | happy hour end | while a happy hour may be on: armed at start, by a start and by a Settings change; ends after a pass that sees none | 15 -> 30 s, scaled | the screens hear the end then |
| modules/progression/challenge.lua | planned-end reminders | always | 60 s | |
| modules/dispatch/calls.lua | prune | always | 60 s | |
| modules/runs/draw.lua | housekeeping | always | 60 s | |
| modules/money/cash.lua, rewards/server.lua | forfeit sweeps | always | 10 min | |

## NUI timers (web/src)

| Where | What | When | Interval |
| --- | --- | --- | --- |
| shared/hooks.ts `useRequest` | screen polls (`pollMs`) | the screen is mounted in the open tablet | 10 -> 20 s shortest (`POLL_MIN_MS`: a smaller `pollMs` polls every 20 s), up to 60 s per screen; pushes refresh at once |
| layouts/navBadges.ts | sidebar counts re-ask | tablet open | 5 min (the `nav` push does the rest) |
| shared/hooks.ts `useCountdown` | HUD countdowns | a countdown shows | one `setTimeout` at each whole second, ends at 0 |
| shared/rowWindow.ts `useRowWindow` | the rows a windowed table draws | a scrolling table of more than 100 rows | on scroll, one update per animation frame (no timer) |
| builder/useDraftEditor.ts | autosave | an editable draft is open | `autosaveSeconds` |
| admin/screens/Testing.tsx | clock tick | the screen is open | 30 s |

## Loop census

Every file with a loop or a timer, and how many it has (`tests/loop_census_spec.lua` reads this table: a new or
removed `CreateThread`, `while true do`, `setTimeout`, `setInterval` or `requestAnimationFrame` fails it until the row
is updated and the loop is in the tables above). Paths of the Lua files are under `Crimson-Police/`; comments and
strings do not count.

| Lua file | `CreateThread` | `while true do` | What they are |
| --- | --- | --- | --- |
| `blocks/checkpoint_route/client.lua` | 1 | 0 | course markers and contact sampling |
| `blocks/escort/client.lua` | 2 | 0 | marker loop, host AI |
| `blocks/field_contact/client.lua` | 1 | 0 | suspect AI and reports |
| `blocks/field_contact/server.lua` | 2 | 0 | one-shot: a walk-in callback, a contact answer |
| `blocks/flee_arrest/client.lua` | 3 | 0 | marker loop, suspect AI; a one-shot |
| `blocks/hostile_waves/client.lua` | 2 | 0 | host AI and blips; a one-shot |
| `blocks/interact_points/client.lua` | 2 | 0 | markers and HUD line; a one-shot |
| `blocks/live_response/client.lua` | 1 | 0 | one-shot: End case from the radial |
| `blocks/process_scene/client.lua` | 4 | 0 | marker loop; one-shots |
| `blocks/protect_rescue/client.lua` | 3 | 0 | marker loop, host AI; a one-shot |
| `blocks/protect_rescue/server.lua` | 1 | 0 | respawn retry, ends when the hosts are out or the objective stops |
| `blocks/pursuit/client.lua` | 2 | 0 | suspect AI and reports, ram loop |
| `blocks/search_area/client.lua` | 3 | 0 | clue markers, suspect AI; a one-shot |
| `blocks/skill_check/client.lua` | 3 | 0 | markers and HUD line, the rounds (bounded); a one-shot |
| `modules/access/client/access.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/access/access.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/admin/admin.lua` | 4 | 0 | push queue while queued; one-shots |
| `modules/admin/adminkit.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/dispatch/alerts.lua` | 2 | 1 | flag reconcile (always, players); one-shots |
| `modules/review/anticheat.lua` | 2 | 1 | buckets, idle, presence (always, players); one-shots |
| `modules/missions/client/builder.lua` | 4 | 4 | Builder tools (admin, per frame while open); bounded loads |
| `modules/missions/builder.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/dispatch/calls.lua` | 2 | 1 | prune, 60 s; one-shots |
| `modules/money/cash.lua` | 4 | 1 | forfeit sweep, 10 min; one-shots |
| `modules/progression/challenge.lua` | 2 | 1 | planned-end reminders, 60 s; one-shots |
| `modules/admin/confighealth.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/client/crimtab.lua` | 6 | 0 | Escape guard, downed watch; one-shots |
| `modules/realplayers/crimtab.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/npc/client/custody.lua` | 3 | 0 | bounded control and load waits; one-shots |
| `modules/npc/custody.lua` | 1 | 0 | one-shot; the custody tick is a `CP.Perf.armed` loop |
| `modules/review/disputes.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/runs/client/downed.lua` | 1 | 0 | bounded waits |
| `modules/runs/downed.lua` | 3 | 0 | start-up hooks; the check is a `CP.Perf.armed` loop |
| `modules/runs/draw.lua` | 2 | 1 | holder housekeeping, 60 s; a one-shot |
| `modules/money/featurerewards.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/supervisor/happyhour.lua` | 1 | 1 | the end check, armed while one may run |
| `modules/system/client/qbx.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/system/integrations/qbx.lua` | 3 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/system/integrations/sc_dispatch.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/progression/leaderboard.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/client/livecrime.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/livecrime.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/supervisor/livectl.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/map/client/markers.lua` | 2 | 0 | objective pointer; a start-up hook |
| `modules/system/migrations.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/dispatch/missioncalls.lua` | 2 | 1 | call posting, `checkEvery`; one-shots; the push is a `SetTimeout` |
| `modules/missions/client/missions.lua` | 1 | 0 | bounded definitions retry at start |
| `modules/missions/missions.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/npc/client/npc.lua` | 19 | 1 | owned ped AI, pace, governor, cuff guard; bounded control waits; one-shots |
| `modules/npc/client/npccombat.lua` | 1 | 0 | damage re-apply while the run is live |
| `modules/teams/operations.lua` | 4 | 1 | operations, adaptive; one-shots |
| `modules/realplayers/conduct.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/pairs.lua` | 4 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/proof.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/saved.lua` | 3 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/opponents.lua` | 3 | 1 | live crime watch while a case is tracked; one-shots |
| `modules/realplayers/surrender.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/access/client/options.lua` | 3 | 0 | Auto-Ready input watcher; start-up hooks |
| `modules/money/payments.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/money/payouts.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/progression/profile.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/money/rewards.lua` | 5 | 1 | forfeit sweep, 10 min; one-shots |
| `modules/runs/client/route.lua` | 2 | 0 | drive-to-start report; a start-up hook |
| `modules/runs/route.lua` | 4 | 0 | one-shots; the tick is a `CP.Perf.armed` loop |
| `modules/runs/client/runs.lua` | 3 | 1 | telemetry, weapon fired; bounded entity wait |
| `modules/runs/runs.lua` | 6 | 1 | maintenance, 60 s; per-run tick threads; one-shots; the engine is a `CP.Perf.armed` loop |
| `modules/system/schedule.lua` | 3 | 1 | daily jobs, 60 s; one-shots |
| `modules/progression/scoring.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/admin/client/settings.lua` | 1 | 0 | bounded settings wait at start |
| `modules/admin/settings.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/runs/client/spawn.lua` | 2 | 4 | placer batches and bounded collision, shape test, network id and control waits |
| `modules/runs/spawn.lua` | 2 | 0 | open spawn asks while any; a one-shot |
| `modules/system/memsql.lua` | 2 | 18 | the saves folder SQL engine: parser and scan loops with no Wait, async query threads |
| `modules/system/storage.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/supervisor/missionban.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/admin/sysadmin.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/access/client/tablet.lua` | 14 | 0 | prop keeper, open watcher, Escape guard; bounded loads; one-shots |
| `modules/access/tablet.lua` | 3 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/missions/client/testing.lua` | 9 | 0 | debug drawing, focus watch; bounded waits; one-shots |
| `modules/teams/client/units.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/teams/units.lua` | 1 | 0 | a start-up hook; the sweep is a `CP.Perf.armed` loop |
| `modules/realplayers/client/volunteers.lua` | 2 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `modules/realplayers/match.lua` | 5 | 0 | match tick while a run has a match; one-shots |
| `modules/realplayers/volunteers.lua` | 6 | 0 | volunteer sweep while someone volunteers; one-shots |
| `shared/init.lua` | 1 | 1 | `CP.Perf.armed`: the loop that runs only while it has work |
| `shared/net.lua` | 1 | 0 | one-shot threads (start-up hooks, async work); no loop |
| `shared/utils.lua` | 0 | 5 | the config text parser, no Wait |

| Web file (web/src, no mocks or walks) | `setTimeout` + `setInterval` | `requestAnimationFrame` | What they are |
| --- | --- | --- | --- |
| `web/src/admin/components/DepartmentAdmin.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/admin/components/kit/OfficerPicker.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/admin/components/officers/OfficerLists.tsx` | 2 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/admin/screens/Audit.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/admin/screens/Home.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/admin/screens/Testing.tsx` | 1 | 0 | clock tick, 30 s |
| `web/src/builder/steps/StepTest.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/builder/useDraftEditor.ts` | 2 | 0 | autosave interval, validate debounce |
| `web/src/hud/FadeOverlay.tsx` | 0 | 1 | one frame to start the fade |
| `web/src/hud/ResultScreen.tsx` | 2 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/main.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/officer/screens/ActiveMission.tsx` | 2 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/officer/screens/Dispatch.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/officer/screens/MissionBoard.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/officer/screens/MyOptions.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/officer/screens/debouncedSave.ts` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/shared/components/Button.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/shared/components/QuietBoundary.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/shared/components/Toasts.tsx` | 2 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
| `web/src/shared/hooks.ts` | 4 | 0 | `useRequest` poll, `useCountdown` (a timer per second), `useDebounced` (one-shot) |
| `web/src/shared/nui.ts` | 4 | 0 | request timeout, retry delay, mock latency |
| `web/src/shared/rowWindow.ts` | 0 | 1 | one frame per scroll burst |
| `web/src/shared/NoticesCard.tsx` | 1 | 0 | one-shot timers (a toast, a confirm button, a debounce, a retry) |
