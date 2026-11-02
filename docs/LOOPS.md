# Loops and timers (steps LP1, LP2, OP1, OP2)

Every repeating loop of Crimson-Police: where it is, what it does, when it runs, its interval and why that interval.
"before -> after" shows the step LP2 change (owner, after LP1: "Try to fix the loops make it occur less often"); a
single value was checked and kept. A value marked *scaled* is multiplied by `Config.Performance.loopScale`.

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
  the start-up waits are over (tests/loops_spec.lua).

## The loop scale (step LP2)

`Config.Performance.loopScale` (1-4, shipped `1.0`, Admin UI → Settings) multiplies the idle and far waits through
one helper, `CP.Perf.ms(ms)` (shared/init.lua). It never touches a per-frame wait (`Wait(0)`), a near or "control
asked" pass, the run engine's 1 s tick (run deadlines, HUD timers) or a server deadline tick. `1` is the table below,
`2` wakes those loops half as often again (tests/loop_pace_spec.lua).

User-visible intervals stay config options with their unit (for example `Config.Route` `every`,
`Config.Downed.checkEvery`, `Config.MissionCalls.checkEvery`, `Config.AntiCheat.jobRecheck`,
`Config.Tablet.pauseGuardMs`). Step LP2 changed none of them.

## Resmon (step OP1)

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

Checked and kept: no client thread runs at idle (LP1); event and state bag handlers cost nothing until their event
fires; ox_target zones and options of a block are added on its start and removed on its stop; no client -> server
event is sent per frame (telemetry: a vehicle sample every 5 s while driving, lights and siren and the first shot
once); `ctx.hudDetail` lines are sent only when the text changes.

## Server cost and NUI (step OP2)

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

How the push gap merges (`modules/tablet/server.lua` `T.push`): per player and topic; the newer data wins, keys
only the older table had stay (a hint such as `invited = true` is kept), and `run` and `options` (whole views) are
never merged. A held push is sent by one `SetTimeout`, not a loop, and `playerDropped` forgets it.

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

## Client loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/options/client.lua | Auto-Ready input watcher (last game input) | only while the officer option `autoReady` is on | 250 ms | reads the last input time; ends when the option is off |
| modules/tablet/client.lua | tablet prop and animation kept | tablet open | 1000 -> 2000 ms, scaled | other scripts clear tasks rarely |
| modules/tablet/client.lua | desk distance watch | tablet open at a desk | 500 -> 1000 ms, scaled | closes within a second of walking away |
| modules/tablet/client.lua | tablet item watch | tablet open, `requireItem` on | 1000 -> 2000 ms, scaled | the server checks again |
| modules/tablet/client.lua | downed watch | tablet open | 500 -> 1000 ms, scaled | focus released soon after the death screen comes up |
| modules/tablet/client.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, one thread | a disabled control is read every frame |
| modules/crimtab/client.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, one thread, extended | a disabled control is read every frame |
| modules/markers/client.lua | objective pointer: streaming, nearest target, line | while there is something on the map | 1000 -> 2000 ms, scaled | ends by itself once cleared |
| modules/route/client.lua | drive-to-start report | drive to the start | `Config.Route` every (s) | the server's warning deadline |
| modules/runs/client.lua | vehicle telemetry, lights and siren | on a run | 1000 -> 2000 ms, scaled; the vehicle sample every 5 s by the game clock (was every 5th pass) | the server samples the vehicle itself too |
| modules/runs/client.lua | weapon fired | on a run, until the first shot | per frame while armed, 500 -> 1000 ms unarmed (scaled) | `IsPedShooting` is true for one frame |
| modules/npc/client.lua | AI of the run's peds this game owns | while it owns any | 500 -> 1000 ms, scaled; stuck after 4 -> 2 still passes (2 s as before) | retasking is not frame critical |
| modules/npc/client.lua | combat caps / tired runner governor | on a run | 1000 -> 2000 ms, scaled; a still tired runner flees again after 3 -> 2 passes | ends with the run |
| modules/npc/client.lua | tired runner pace | while a paced ped exists | per frame | the move rate override lasts one frame |
| modules/npc/client.lua | cuff progress guard | while cuffing | 250 -> 500 ms, scaled | ends with the progress bar |
| modules/npccombat/client.lua | NPC damage values re-applied | run live | 1000 -> 2000 ms, scaled | `reassertAiDamage` |
| modules/testing/client.lua | test area debug drawing | Testing debug on, within 600 m | per frame near, 500 -> 1000 ms far (scaled) | drawn lines need every frame |
| modules/testing/client.lua | panel focus watch | panel focused | 250 ms | ends on blur |
| modules/builder/client.lua | placement, recording, drive test | a Builder tool open (admin only) | per frame | draws and reads controls |
| blocks/escort, flee_arrest, process_scene, protect_rescue marker loops | objective markers | objective current | per frame in range, 750 -> 1500 ms far (scaled) | markers need every frame in range |
| blocks/search_area/client.lua | clue markers | objective current | per frame in 150 m, 750 -> 1500 ms far (scaled) | no allocation per frame |
| blocks/skill_check, interact_points | markers and HUD line | objective current | per frame in range, 500 -> 1500 ms far (scaled) | far away, a new HUD message shows up to 1.5 s later |
| blocks/flee_arrest, search_area, pursuit, field_contact | suspect AI and reports | objective live | 250 ms near, 1000 -> 2000 ms far (scaled) | reaction time near, cheap far |
| blocks/protect_rescue, escort, hostile_waves | host AI and blips | objective live | 500 -> 1000 ms, scaled (250 ms while control is asked) | AI retasks are not frame critical |
| blocks/checkpoint_route/client.lua | course markers and contact sampling | course on | per frame near, 100 ms while the course runs, 500 -> 1000 ms else (scaled) | contact sampling deadline |

Bounded waits (model and animation loads, `NetworkRequestControlOfEntity`, collision and shape tests, the settings
list and mission definitions at start) all end at a deadline and are not loops of a feature.

## Server loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/runs/server.lua | run timeouts, arrivals, arena exit sweeps | always | 1000 ms | run deadlines and HUD timers are in seconds |
| modules/runs/server.lua | job recheck | always | `Config.AntiCheat.jobRecheck` s | owner setting |
| modules/runs/server.lua | maintenance | always | 60 s | housekeeping |
| modules/route/server.lua | drive-to-start safety net | always | 1000 ms (idle: returns at once, no tables built) | the warning deadline is in seconds |
| modules/alerts/server.lua | crimsonArena flag reconcile | always | 1000 -> 2000 ms, scaled | a lost flag is restored within two seconds |
| modules/anticheat/server.lua | buckets, idle, presence sampling | always | 1000 -> 2000 ms, presence 5 s (on the next pass) | idle and bucket rules count seconds |
| modules/custody/server.lua | custody timers | always | 1000 ms (kept) | each service vehicle step (road point ask, spawn, drive, park, leave) is one pass: 2 s would make every transport and coroner arrive seconds later |
| modules/npc/server.lua | death watcher, health, cuff reach, flee clock | always | 1000 ms (kept) | the flee clock adds a second a pass (sprint, jog, walk), and a vanished ped must be seen before the engine's own 2-pass vanish rule |
| modules/opponents/server.lua | live crime watch | while a case or crew is tracked | 1000 ms (kept) | second deadlines: the lost rule, the disconnect grace, AFK and the trail |
| modules/operations/server.lua | operations | always | 1000 -> 2000 ms active, 5000 -> 10000 ms idle (scaled) | adaptive; the join window is minutes |
| modules/spawn/server.lua | open spawn asks | while asks are open | 500 -> 1000 ms | placement timeouts are seconds |
| modules/units/server.lua | invite expiry, lock safety net | always | 2000 -> 5000 ms, scaled | invites last 120 s; accepting checks the expiry itself |
| modules/volunteers/server.lua | volunteer window and duty | while someone volunteers | 15 -> 30 s, scaled | the window is minutes |
| modules/volunteers/match/server.lua | asking, travel, engagement | while a run has a match | 1000 -> 2000 ms | the travel time is minutes |
| modules/missioncalls/server.lua | call posting and expiry; coalesced push | always | `checkEvery` s; 1000 ms (push only when dirty) | |
| modules/testing/server.lua | debug stream, invites | always | 1000 -> 2000 ms base, debug 2 s, upkeep 5 s (on the next pass) | |
| modules/downed/server.lua | downed checks | always | `Config.Downed.checkEvery` s (min 0.5) | owner setting |
| modules/admin/server.lua | admin push queue | while queued | 50 ms sent, 250 ms else | ends when empty |
| modules/schedule/server.lua | daily jobs | always | 30 -> 60 s | minute precision |
| modules/happyhour/server.lua | happy hour end | always | 15 -> 30 s, scaled | the screens hear the end then |
| modules/challenge/server.lua | planned-end reminders | always | 60 s | |
| modules/calls/server.lua | prune | always | 60 s | |
| modules/draw/server.lua | housekeeping | always | 60 s | |
| modules/cash/server.lua, rewards/server.lua | forfeit sweeps | always | 10 min | |

## NUI timers (web/src)

| Where | What | When | Interval |
| --- | --- | --- | --- |
| shared/hooks.ts `useRequest` | screen polls (`pollMs`) | the screen is mounted in the open tablet | 10 -> 20 s shortest (`POLL_MIN_MS`: a smaller `pollMs` polls every 20 s), up to 60 s per screen; pushes refresh at once |
| layouts/navBadges.ts | sidebar counts re-ask | tablet open | 5 min (the `nav` push does the rest) |
| shared/hooks.ts `useCountdown` | HUD countdowns | a countdown shows | 200 ms, ends at 0 |
| builder/useDraftEditor.ts | autosave | an editable draft is open | `autosaveSeconds` |
| admin/screens/Testing.tsx | clock tick | the screen is open | 30 s |
