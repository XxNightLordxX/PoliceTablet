# Changelog

Every version of Crimson-Police, newest first. The owner's guide is the `README.md` of the repository; what to
check in game after an update is in `docs/IN_GAME_CHECKLIST.md`.

## 1.0.0 (not released yet)

The first version for sale.

- **Works on any Qbox city.** Dispatch, ambulance, banking and police scripts are optional and found by themselves
  (`Config.Integrations`: sc-dispatch or ps-dispatch, sc-ambulance or qbx_ambulancejob, Renewed-Banking, sc-police or
  qbx_policejob); a feature that needs a missing script turns itself off and says why.
- **Generic starting config** in `config/examples/generic.lua`: qbx_core's own police jobs (`police`, `bcso`,
  `sasp`), every script on `auto`. Copy it over `config/config.lua` for a fresh city.
- **First-start setup** on Admin UI -> Home (`Config.AdminUi.setupScreen`): departments and their Qbox jobs,
  supervisor grades, desks, storage, the scripts found and a preset. Every answer is a normal setting. Skippable.
- **Guided tours** (`Config.Training`): each tablet shows a new character around on first open (Officer, Supervisor,
  Admin UI, criminal tablet), saved per character; the **?** in every header, the Tours lists and `/crimsonhelp`
  replay them. Admin UI -> Home's **Setup checklist** ticks off what a new city still has to do. The first mission
  run shows short tips beside the HUD (the HUD, objectives, the GPS line, the result card) with no clicks needed.
- **Escrow-friendly layout:** `config/`, `locales/` and `missions/builtin/` stay readable and editable
  (`escrow_ignore` in `fxmanifest.lua`); custom missions are files written in game; `web/dist` ships built.
- NPC missions (18 plus a Weekly Boss), mission calls, police actions and custody, the Mission Builder, units and
  Cross-Department Missions, recognition, leaderboards and seasons, real suspects, cash and item rewards, and an
  Admin UI where every setting can be changed in game.

### Fixes before 1.0.0

- **Payments -> Resolve, Mark withdrawn:** a Pay again whose department withdrawal (or its refund) was cut half way,
  where the department's history shows it **was** charged and not given it back, could only be closed with Mark
  paid. **Mark withdrawn** (tick the box) now records that, with no money moved: Pay again then pays the officer with
  the deposit only, and **Release Pay again** at that step gives the department its money back first.
- **Suspensions and a maintenance lock:** a new suspension given more than a dispute window after the last one
  ended, but inside the time a maintenance lock (a restore) added to that window, started a new hold, so the voided
  runs the last suspension still held closed early. It now keeps the last suspension's start, by the same moved
  window end the disputes use.

### Optimization work before 1.0.0

Measured in the test harness (`tests/`), before -> after. The intervals each loop runs at now are in
`docs/dev/LOOPS.md`.

**Client resmon (`tests/resmon_spec.lua`)**

| What | Measure | Before -> after |
| --- | --- | --- |
| idle (no run, tablet closed), two minutes | natives called | 0 -> 0 (no thread wakes, tests/loops_spec.lua) |
| checkpoint course, in a car inside the checkpoint, course running | natives a frame | 13.3 -> 10.3 (no `PlayerPedId()`: `cache.ped`; one `GetGameTimer` a frame) |
| the same | Lua memory a frame | 0.30 KB -> 0.00 KB (the "Stop inside" / "Hold still" / "drive a vehicle" line looked up once, not every frame) |
| the same | undriveable check (3 natives) | every frame -> every 100 ms sample (its retry is 3 s) |
| tired runner pacer, one runner, 60 frames | natives for the runner | 369 -> 221 (cap and move rate every frame, plus one clock read; entity, owner, vehicle and death every 100 ms instead of every frame) |
| HUD patches from the server that change nothing | NUI messages | one per patch -> none (21 identical patches: 22 -> 1 message) |
| a 'local' officer option read (sound cues, HUD target line, GPS mode) | KVP JSON decodes | one per read -> one per KVP change (100 reads: 100 -> 1) |

**Server cost and the NUI bundle (`tests/server_cost_spec.lua`, `tests/nui_bundle_spec.lua`)**

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
| the resource's start: the work the server scripts' main chunks do while the files load (lua5.4, `tests/harness.lua`, files mode, median of 7; compiling the files is about 128 ms of it and stays) | ms | 26.1 -> 13.4 (`shared/locale.lua` 8.4 -> 0.0: `locales/en.json` is decoded on first use; `modules/system/memsql.lua` 3.9 -> 0.4: the two utf8mb4_general_ci maps are built for the first non-ASCII text; `tests/startup_load_spec.lua`) |

**Work repeated inside one request, one ox_target pass or one draw**

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

**Every loop: event-driven, merged, scaled**

| What | Measure | Before -> after |
| --- | --- | --- |
| the Officer UI open for a minute, `requireItem` on (tests/loops_spec.lua) | tablet threads / wakes | 3 / 118 -> 2 / 88 (the downed, desk and item checks are one watcher: 60 + 30 item checks folded into its 60 passes; the animation keeper is the other thread; same timing: downed and desk every 1 s, item every 2 s) |
| an idle server with no happy hour, 10 minutes (tests/happy_hour_spec.lua) | happy hour loop wakes | 20 -> 0 (the end check runs only while one may be on; while one runs it still checks every 30 s and hears the end) |
| `Config.Performance.markerRange = 10`, a skill check device 20 m away (tests/loop_pace_spec.lua) | per-frame passes in 6 s | every frame -> none (the loop sleeps at its 1.5 s far wait); shipped `0` = every marker at its own distance, as before |

**Loops that slept only while idle are now armed by their work**

| What | Measure | Before -> after |
| --- | --- | --- |
| the run engine's 1 s tick, job recheck and 60 s maintenance (the first two over the same runs, all awake all day) | threads / idle wakes in 2 min | 3 / 134 -> 2 / 2 (the tick and the recheck are one engine thread, armed by a run or an orphaned item; the 60 s cache housekeeping stays) |
| custody timers, the NPC watcher, the drive-to-start check (1 s each, all day) | idle wakes in 2 min | 120 each -> 0 (each armed by a run, a custody book or a tracked participant) |
| the downed check (`Config.Downed.checkEvery` 2 s, all day) | idle wakes in 2 min | 60 -> 0 (armed by a run or a downed entry) |
| the Testing upkeep (2 s, all day) and the unit sweep (5 s, all day) | idle wakes in 2 min | 60 and 24 -> 0 (armed by a test, an invitation or a waiting result; by a unit) |
| the mission calls screen push (a 1 s loop looking at a flag) | idle wakes in 2 min | 120 -> 0 (one `SetTimeout` 1 s after the first change: same coalescing) |
| a HUD countdown of 10 s (`useCountdown`) | timer wakes | 50 -> 10 (one `setTimeout` just after each whole second, was a 200 ms poll; the shown second changes on time) |

Loop intervals made slower: the tablet prop keeper, the objective pointer, run telemetry, the NPC combat governor
and the NPC damage re-apply 1000 -> 2000 ms; the arena flag reconcile and the anticheat sampling 1000 -> 2000 ms;
the NPC AI, the cuff guard, the weapon-fired check unarmed, the Testing debug far wait, the spawn asks and the host
AI 250-500 -> 500-1000 ms; the block marker far waits 500-750 -> 1500 ms; the block suspect AI far wait 1000 ->
2000 ms and the checkpoint course's far wait 500 -> 1000 ms; operations 1000/5000 -> 2000/10000 ms;
units 2000 -> 5000 ms; volunteers 15 -> 30 s; volunteer matching 1000 -> 2000 ms; the schedule 30 -> 60 s; happy
hour 15 -> 30 s; the shortest screen poll 10 -> 20 s.
