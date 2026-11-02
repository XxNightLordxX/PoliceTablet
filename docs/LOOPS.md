# Loops and timers (step LP1)

Every repeating loop of Crimson-Police: where it is, what it does, when it runs, its interval and why that interval.
"before -> after" shows the step LP1 change; a single value was checked and kept.

## The rules

- **Per frame (`Wait(0)`)** only while something is drawn or a control is read every frame, and only while that
  feature is on (a marker in range, the Escape guard after a close, a builder tool open). Otherwise the loop sleeps
  (750-1000 ms when far or idle, 250-500 ms when near).
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

User-visible intervals stay config options with their unit (for example `Config.Route` `every`,
`Config.Downed.checkEvery`, `Config.MissionCalls.checkEvery`, `Config.AntiCheat.jobRecheck`,
`Config.Tablet.pauseGuardMs`). Step LP1 changed no shipped value.

## Client loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/options/client.lua | Auto-Ready input watcher (last game input) | only while the officer option `autoReady` is on | always on, 2000 ms idle -> only while on, 250 ms | started by the option, a Settings change or the first Auto-Ready question; ends when the option is off |
| modules/tablet/client.lua | tablet prop and animation kept | tablet open | 1000 ms | other scripts clear tasks rarely; a second is invisible |
| modules/tablet/client.lua | desk distance watch | tablet open at a desk | 500 ms | closes soon after walking away |
| modules/tablet/client.lua | tablet item watch | tablet open, `requireItem` on | 1000 ms | the server checks again |
| modules/tablet/client.lua | downed watch | tablet open | 500 ms | focus released fast when the death screen comes up |
| modules/tablet/client.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, one thread | a disabled control is read every frame |
| modules/crimtab/client.lua | Escape guard (pause menu) | `pauseGuardMs` after a close | per frame, a thread per close -> one thread, extended | two quick closes no longer stack guard threads |
| modules/markers/client.lua | objective pointer: streaming, nearest target, line | while there is something on the map | 1000 ms | ends by itself once cleared |
| modules/route/client.lua | drive-to-start report | drive to the start | `Config.Route` every (s) | the server's warning deadline |
| modules/runs/client.lua | vehicle telemetry, lights and siren | on a run | 1000 ms (`PlayerPedId()` -> `cache.ped`) | sampled every 5 s |
| modules/runs/client.lua | weapon fired | on a run, until the first shot | per frame while armed, 500 ms unarmed | `IsPedShooting` is true for one frame |
| modules/npc/client.lua | AI of the run's peds this game owns | while it owns any | 500 ms | retasking is not frame critical |
| modules/npc/client.lua | combat caps / tired runner governor | on a run | 1000 ms | ends with the run |
| modules/npc/client.lua | tired runner pace | while a paced ped exists | per frame | the move rate override lasts one frame |
| modules/npc/client.lua | cuff progress guard | while cuffing | 250 ms | ends with the progress bar |
| modules/npccombat/client.lua | NPC damage values re-applied | run live | 1000 ms | `reassertAiDamage` |
| modules/testing/client.lua | test area debug drawing | Testing debug on, within 600 m | per frame near, 500 ms far (`PlayerPedId()` -> `cache.ped`) | drawn lines need every frame |
| modules/testing/client.lua | panel focus watch | panel focused | 250 ms | ends on blur |
| modules/builder/client.lua | placement, recording, drive test | a Builder tool open (admin only) | per frame | draws and reads controls |
| blocks/*/client.lua marker loops | objective markers | objective current | per frame in range, 750 ms (or 500 ms) far | markers need every frame |
| blocks/search_area/client.lua | clue markers | objective current | per frame in 150 m, 750 ms far (a vector per clue -> squared distance) | no allocation per frame |
| blocks/skill_check, interact_points | markers and HUD line | objective current | per frame in range, 500 ms far (new `{}` per pass -> shared empty list, squared range cached) | no allocation per frame |
| blocks/flee_arrest, search_area, pursuit, field_contact | suspect AI and reports | objective live | 250 ms near, 1000 ms far | reaction time near, cheap far |
| blocks/protect_rescue, escort, hostile_waves | host AI and blips | objective live | 500 ms (250 ms while control is asked) | AI retasks are not frame critical |
| blocks/checkpoint_route/client.lua | course markers and contact sampling | course on | per frame near, 100 ms while the course runs, 500 ms else | contact sampling deadline |

Bounded waits (model and animation loads, `NetworkRequestControlOfEntity`, collision and shape tests, the settings
list and mission definitions at start) all end at a deadline and are not loops of a feature.

## Server loops

| File | What it does | When it runs | Interval | Why |
| --- | --- | --- | --- | --- |
| modules/runs/server.lua | run timeouts, arrivals, arena exit sweeps | always | 1000 ms | run deadlines are in seconds |
| modules/runs/server.lua | job recheck | always | `Config.AntiCheat.jobRecheck` s | owner setting |
| modules/runs/server.lua | maintenance | always | 60 s | housekeeping |
| modules/route/server.lua | drive-to-start safety net | always | 1000 ms (idle: returns at once, no tables built) | the warning deadline is in seconds |
| modules/alerts/server.lua | crimsonArena flag reconcile | always | 1000 ms | a lost flag is restored within a second |
| modules/anticheat/server.lua | buckets, idle, presence sampling | always | 1000 ms, presence 5 s | idle and bucket rules count seconds |
| modules/custody/server.lua | custody timers | always | 1000 ms | transport and jail deadlines |
| modules/npc/server.lua | death watcher, health, cuff reach | always | 1000 ms | |
| modules/opponents/server.lua | live crime watch | while a case or crew is tracked | 1000 ms | ends when nothing is tracked |
| modules/operations/server.lua | operations | always | 1000 ms active, 5000 ms idle | adaptive |
| modules/spawn/server.lua | open spawn asks | while asks are open | 500 ms | placement timeouts |
| modules/units/server.lua | invite expiry, lock safety net | always | 2000 ms | invite timeouts |
| modules/volunteers/server.lua | volunteer window and duty | while someone volunteers | 15 s | |
| modules/volunteers/match/server.lua | asking, travel, engagement | while a run has a match | 1000 ms | |
| modules/missioncalls/server.lua | call posting and expiry; coalesced push | always | `checkEvery` s; 1000 ms (push only when dirty) | |
| modules/testing/server.lua | debug stream, invites | always | 1000 ms base, debug 2 s, upkeep 5 s | |
| modules/downed/server.lua | downed checks | always | `Config.Downed.checkEvery` s (min 0.5) | owner setting |
| modules/admin/server.lua | admin push queue | while queued | 50 ms sent, 250 ms else | ends when empty |
| modules/schedule/server.lua | daily jobs | always | 30 s | minute precision |
| modules/happyhour/server.lua | happy hour end | always | 15 s | |
| modules/challenge/server.lua | planned-end reminders | always | 60 s | |
| modules/calls/server.lua | prune | always | 60 s | |
| modules/draw/server.lua | housekeeping | always | 60 s | |
| modules/cash/server.lua, rewards/server.lua | forfeit sweeps | always | 10 min | |

## NUI timers (web/src)

| Where | What | When | Interval |
| --- | --- | --- | --- |
| shared/hooks.ts `useRequest` | screen polls (`pollMs`) | the screen is mounted in the open tablet | 10-60 s per screen; pushes refresh at once |
| layouts/navBadges.ts | sidebar counts re-ask | tablet open | 5 min (the `nav` push does the rest) |
| shared/hooks.ts `useCountdown` | HUD countdowns | a countdown shows | 200 ms, ends at 0 |
| builder/useDraftEditor.ts | autosave | an editable draft is open | `autosaveSeconds` |
| admin/screens/Testing.tsx | clock tick | the screen is open | 30 s |
