# Crimson-Police · architecture and code contracts

This document is the **single source of truth for how the code fits together**: module APIs, data
shapes, event names, the block interface and the NUI protocol. The product behaviour comes from the
spec (`docs/SPEC.md`, converted from "Crimson-Police – Tablet Missions & Leaderboard Spec").
Where the two overlap: the spec's Hard rules win, then `config/*.lua`, then this document.

Every implementer must read §0–§3 and the sections for the files they own. Anything a module
exposes that is not listed here is private to that module (keep it `local`).

---

## 0. Ground rules for all code

1. **Lua 5.4, standard syntax only.** No CfxLua-only syntax (no backtick hashes, no `+=`, no
   `?.`/safe navigation, no `in` unpacking). Use `joaat('name')` / `GetHashKey('name')`. Every Lua file
   must pass `luac5.4 -p`.
2. **Qbox only.** Never `exports['qb-core']`, `GetCoreObject`, `QBCore.` anything. Framework access
   only through `CP.Qbx` (modules/integrations/qbx). Listening to the `QBCore:*` *events* that
   qbx_core fires is allowed (only inside modules/integrations/qbx).
3. **Integration boundary.** Only `modules/integrations/*` may call qbx_core, sc-police,
   sc-dispatch, sc-ambulance, sc-multijob or Renewed-Banking, or read their tables. ox_lib,
   ox_target, ox_inventory and oxmysql may be called anywhere. Never call sc-npcpolice.
   Never trigger `hospital:server:RevivePlayer`, `hospital:client:RevivePlayer`,
   `hospital:client:HelpPerson` or `sc-ambulance:client:TargetRevive` (they get officers banned).
   Never call `exports['sc-dispatch']:AddNotification`.
4. **One global table per module**: `CP.<Name>` (e.g. `CP.Cash`). Everything else is `local`.
   The client and server halves of a module use the same table name (separate Lua states).
5. **No cross-module calls at file load time.** A file's top level only defines functions and
   registers handlers/threads. Other modules are called at runtime (inside handlers, threads,
   `CreateThread`), so load order between modules never matters.
6. **Database:** oxmysql only (`MySQL.query.await`, `MySQL.single.await`, `MySQL.scalar.await`,
   `MySQL.insert.await`, `MySQL.update.await`; never `MySQL.prepare`, whose return shape varies). Every module calls
   `CP.Migrations.ready()` before its first query (inside a thread/handler, never at top level).
   Always use `?` placeholders. Time columns are MySQL `DATETIME` in server local time; compare with
   `FROM_UNIXTIME(?)` or `NOW() - INTERVAL`. The test harness runs every query against MariaDB 10.11.
   **oxmysql type casts:** never rely on how oxmysql converts column types. Read times as seconds with
   `UNIX_TIMESTAMP(col) AS col_ts`, write them with `FROM_UNIXTIME(?)`. TINYINT(1) may arrive as a
   boolean or a number: test with `CP.U.truthy(v)`. JSON columns may arrive as a string or a table:
   read with `CP.U.jsonField(v)`; write with `json.encode(CP.U.serialize(t))`. COUNT/SUM results may be
   numbers or numeric strings: wrap with `tonumber(v) or 0` (`CP.U.num`). Callsigns are truncated to 32
   characters and names to 64 before writing (`CP.U.clip`).
7. **Server authority.** The client never sends points or cash amounts. Clients report objective
   events and telemetry; the server validates. Every `sup:*`/`admin:*` handler calls
   `CP.Permissions.can(src, action)` first, and every officer action calls `CP.Access.getOfficer(src)`.
8. **Text:** all player-facing text is a locale key (see §10). Lua uses `CP.L(key, vars)`, the UI
   uses `t(key, vars)`. Never hard-code English in Lua notifications or React components.
9. **Logging:** `CP.log('<module>', fmt, ...)` for debug lines (printed only with `Config.Debug`),
   `CP.warn`/`CP.err` for problems. The tag is the module folder name, e.g. `CP.log('cash', ...)`.
10. **No ox_lib UI for Crimson-Police screens**: no `lib.notify`, `lib.registerContext`,
    `lib.inputDialog`, `lib.alertDialog`, `lib.showTextUI`, menus. Only `lib.progressBar`/
    `lib.progressCircle` and `lib.skillCheck` during missions. ox_target prompts are allowed.
11. **Config values are read at call time** (`Config.X.y`), never copied into locals at load
    time, except inside functions.
12. **Performance:** no per-frame loops outside active objectives. Client loops that draw markers
    run only while the objective is current and the player is near; use `Wait(500+)` when idle.
13. **Cleanup:** anything you create (blips, zones, target options, threads, markers, props,
    entities, keybinds) must be removed on the matching stop/cleanup call and on resource stop.

14. **Coexistence with Crimson-Arena** (a separate resource named `Crimson-Arena` that sc-dispatch and
    sc-ambulance also integrate with). Crimson-Police must never conflict with it:
    - Never use the resource name, event prefix, command names, keybind names, exports or globals of
      Crimson-Arena. Crimson-Police's prefix is always `crimson-police` / `CrimsonPolice` / `CP`.
      Never define exports named `IsInArena` or `ShouldSuppressAlert` (sc-dispatch/sc-ambulance call
      those on `Crimson-Arena`). Never call any `exports['Crimson-Arena']` function or trigger its events.
    - The `crimsonArena` state bag may belong to Crimson-Arena. `CP.Alerts.set` never overwrites a
      value whose `source` is not `'crimson-police'`, and `CP.Alerts.clear` only removes a value whose
      `source == 'crimson-police'`. **The full, verified rule set is `docs/CRIMSON_ARENA.md` (mandatory):**
      `CP.Alerts.inArena(src)` (foreign flag or routing bucket ≠ 0) gates accept/join/invites/tests
      (`err.in_arena`); a participant who becomes in-arena mid-run leaves as `quit`; our flag is re-asserted
      when Crimson-Arena wipes it; downed pick-ups re-check; mission items carry `{ cpRun, cpItem }` metadata;
      anti-cheat/route/telemetry ignore in-arena players; never touch routing buckets, teams or friendly fire.
    - Client-side game state is global across resources: relationship groups are named
      `CRIMSONPOLICE_HOSTILE` / `CRIMSONPOLICE_NEUTRAL`, key mappings `crimsonpolice_*`, ox_target option
      names `crimson-police:*`, blip/zone names prefixed `crimson-police`. Never change the `PLAYER`
      relationship group's relations to other groups, never call global toggles that other resources rely on
      (e.g. `SetMaxWantedLevel`, `SetPoliceIgnorePlayer`, `NetworkSetFriendlyFireOption`,
      `SetCanAttackFriendly` on all players, global density multipliers outside the run's own area).
    - NPC traffic blocking uses a scenario/area-limited approach around the run's location only
      (`AddRoadNodeSpeedZone` / `SetRoadsInArea` / `ClearAreaOfVehicles` in radius), removed at cleanup.
---

## 1. Folder layout (actual) and load order

```
PoliceTablet/                      (git repo)
  README.md
  docs/ARCHITECTURE.md             this file
  docs/SPEC.md                     the product spec (markdown)
  tests/                           Lua unit tests + MariaDB query tests (not shipped)
  Crimson-Police/                  THE RESOURCE (folder name is a Hard rule)
    fxmanifest.lua
    config/config.lua              every setting (copied verbatim from the spec)
    config/blocks.lua              Mission Builder ranges and defaults (verbatim from the spec)
    shared/init.lua                CP namespace, logging, CP.Blocks registry, RegisterMission stub
    shared/locale.lua              CP.L / CP.Locale
    shared/net.lua                 CP.Net (actions and callbacks)
    shared/utils.lua               CP.U helpers (round, rng, hash, vectors, colours ...)
    locales/en.json                all player-facing text (merged from locales/parts/*.json)
    logos/sast.png, fib.png
    missions/builtin/index.lua     return { 'beat_patrol', ... }
    missions/builtin/<id>.lua      one RegisterMission({...}) each
    missions/custom/<id>.lua       written by the Mission Builder
    missions/custom/archived/
    modules/<feature>/server.lua   (+ client.lua where needed)
    modules/integrations/<name>/server.lua (+ client.lua)
    blocks/<block_id>/server.lua + client.lua
    web/                           React 18 + TS + Vite; builds to web/dist (committed)
    sql/migrations/001_initial.sql, 002_test_def_hash.sql
```

fxmanifest loads: `@ox_lib/init.lua`, config/config.lua, config/blocks.lua, shared/*.lua
(alphabetical: init, locale, net, utils), then `modules/**/server.lua` (server) /
`modules/**/client.lua` (client), then `blocks/**/server.lua` / `blocks/**/client.lua`.
Server also gets `@oxmysql/lib/MySQL.lua`. `files` ships web/dist, locales/*.json and logos/*.

Extra module folders beyond the spec's table (allowed: "each feature in its own folder"):
- `modules/missions/` — the mission registry: loads built-in and custom mission files, normalises
  definitions, sends them to clients, reload.
- `modules/npc/` — shared NPC behaviour used by blocks: state machine (hostile, surrendered,
  cuffed …), host-side AI, "Cuff suspect", surrender rolls, relationship groups.

---

## 2. Shared layer (already written — read the files)

| API | File | Notes |
|---|---|---|
| `CP.resource`, `CP.isServer`, `CP.prefix` | shared/init.lua | `'Crimson-Police'`, bool, `'crimson-police'` |
| `CP.log(tag, fmt, ...)`, `CP.warn`, `CP.err` | shared/init.lua | tagged `[crimson-police:<tag>]` |
| `CP.e(name)` | shared/init.lua | `'crimson-police:' .. name` |
| `CP.Blocks.register(id, impl)`, `.get(id)`, `.all()` | shared/init.lua | one registry per side |
| `CP.L(key, vars)`, `CP.Locale.all()`, `CP.Locale.has(key)` | shared/locale.lua | `{var}` placeholders |
| `CP.Net.action(name, handler, opts)` | shared/net.lua | server: registers net event `crimson-police:<name>`; handler `(src, payload) -> ok, data|errKey`; replies to `reqId` |
| `CP.Net.callback(name, handler, opts)` | shared/net.lua | server: ox_lib callback `crimson-police:<name>`; handler `(src, args) -> data` or `nil, errKey`; reply `{ok,data,error}` |
| `CP.Net.rateOk(src, key, max, windowMs)` | shared/net.lua | server |
| `CP.Net.action(name, payload, timeoutMs)`, `CP.Net.request(name, args)` | shared/net.lua | client; both return `{ ok, data, error }` |
| `CP.U.*` | shared/utils.lua | `round` (halves up), `clamp`, `inRange`, `copy`, `deepcopy`, `contains`, `keys`, `count`, `map`, `filter`, `getPath`, `setPath`, `hash`, `hashHex`, `startsWith`, `trim`, `rng(seed)` (`:next() :int(a,b) :chance(p) :pick(l) :shuffle(l) :sample(l,n)`), `uuid()`, `xyz`, `dist`, `dist2d`, `distToPolyline`, `vecToTable`, `tableToVec`, `serialize`, `isHexColour`, `contrastText` |

Naming of `CP.Net.action` names: officer actions are `'server:<name>'` (spec events, e.g.
`'server:acceptType'`), supervisor actions `'server:sup:<name>'`, admin actions
`'server:admin:<name>'`, Mission Builder actions `'server:builder:<name>'`, test actions
`'server:test:<name>'`. Callback names are bare: `'getSession'`, `'getBoard'`, or scoped
`'sup:getLiveRuns'`, `'admin:getAudit'`, `'builder:list'`.

Error keys returned by handlers are locale keys under `err.` (e.g. `'err.not_on_duty'`). Every
error key you return must exist in your locale part (§10).

---

## 3. Core data shapes

### 3.1 Officer (returned by `CP.Access.getOfficer(src)`)

```lua
officer = {
  src = 12, citizenid = 'ABC12345', name = 'John Doe',            -- charinfo first + last
  department = 'sast',                                            -- key in Config.Departments
  departmentLabel = 'San Andreas State Troopers', departmentShort = 'SAST',
  job = 'sast', rank = 'Sergeant', gradeLevel = 3, callsign = '2L-14',  -- nil when unset: qbx's default 'NO CALLSIGN' and '' count as unset
  onduty = true, isSupervisor = true, isAdmin = false,
}
```

### 3.2 Mission definition (normalised by `CP.Missions.normalize`)

Mission files follow the spec's Example files exactly. After loading, `CP.Missions` fills defaults:

```lua
mission = {
  id = 'gang_shootout', label = 'Gang Shootout', description = '...',
  type = 'tactical',              -- key in Config.MissionTypes
  departments = {},               -- {} = every department
  minOfficers = 1, maxOfficers = 4, difficulty = 3,
  timeLimit = 600, startTimeout = 600 (default Config.Limits.startTimeout), cooldown = 1200,
  vehiclePenalties = true,        -- default true
  locations = { { label = 'Hideout A', start = { coords = vec3, radius = 80.0 }, <named data> }, ... },
  objectives = { { block = 'hostile_waves', label = '...', minSeconds = 60, presenceRange = 150, <block fields> }, ... },
  scaling = { 'objectives.1.waves' } -- entries: string path or { path = '...', max = 4 }
  items = { { name = 'radio', count = 1 } },   -- ox_inventory items given at start, removed at end
  bonuses = { { id = 'no_participant_downed', pctOfPoints = 0.10 }, { id = 'hostile_arrested', points = 5, each = true } },
  penalties = { { id = 'hard_ram', points = -10, each = true } },
  -- set by the loader, never by files:
  source = 'builtin' | 'custom', version = 3 (custom only), filePath = 'missions/builtin/gang_shootout.lua',
  defHash = '1a2b3c4d',           -- CP.U.hashHex of the file content (tests: "Changed since test")
  editedInCode = false, isBoss = false (true for weekly_boss_kingpin), status = 'published',
}
```

Special mission ids: `weekly_boss_kingpin` (`isBoss = true`: excluded from type pools; accepted with
the key `'weekly_boss'`; runs stored with `mission_type = 'tactical'`).

**Location data keys** are free-form named fields referenced by objectives (`spawns = 'spawns'`
means `location.spawns`). Values are `vec3`, `vec4`, lists of them, or tables. `start` is required.

**Bonus/penalty resolution** (`CP.Scoring`): an entry `{ id, points?, pctOfPoints?, each? }`.
Value = explicit `points`/`pctOfPoints` if present, else `Config.Bonuses[id]` (`kind`
`points`→flat, `pct`→ share of P). `each = true` multiplies by the recorded count. Ids not in
`Config.Bonuses` (mission-card extras, e.g. `racer_detained`) must carry an explicit value.
Labels: locale `bonus.<id>`. A bonus/penalty only applies when the block or engine *records* it
with `CP.Runs.award` / `CP.Runs.penalize` (§5.10), except the end-evaluated ids:
`no_participant_downed` (no participant went down), `no_weapons_fired` (no participant fired).

### 3.3 Objective block fields (the mission-file format for each block)

Common to every objective: `block`, `label`, `minSeconds` (default: block default below),
`presenceRange` (default `Config.Blocks[block].presenceRange[3]`). Units in files: seconds,
metres, km/h; chances are fractions (0.30); progress durations are milliseconds.

| Block | Default minSeconds | Fields (defaults in brackets) |
|---|---|---|
| `checkpoint_route` | 20 | `checkpoints` (location key: list of vec3, or `{ points = {...} }` route) · `use` ('all'\|'random') · `count` (N for random) · `radius` [10.0] · `stopFor` [10] s · `policeVehicle` [true] · `medals` (false or `{ gold, silver, bronze }` seconds; a location may override with `location.medals`) · `contactPenalty` [2] s · `timerStart` ('first' checkpoint\|'start') · `failIfUndriveable` [true] |
| `interact_points` | 5 | `points` (location key: vec3/vec4, list of them, or list of `{ coords, heading, label }`) · `use` ('all'\|'random') · `count` · `target = { label, icon, radius }` · `progress = { label, duration (ms), anim }` · `roll = { outcomes = { { id, chance, followUp = { label, duration } } } }` (server rolls per point) · `logResult = { choices = { 'secure', 'found_open' }, correct = { secure = 'secure', open = 'found_open' } }` · `hidden = { count, prop, label }` (N of the points hide a device; done when all found; found devices go to `run.shared.devices`) · `fastBonus = { seconds, id }` |
| `skill_check` | 10 | `targets` ('shared:devices' or a location key) · `checks` [{'easy','medium','medium','hard'}] · `missPenalty` [30] s off the run timer · `failAfter` [2] misses in a row on one target · `target = { label, icon }` · `explosion` [true] (effect only, damage 0) |
| `hostile_waves` | 60 | `spawns` (location key: list of vec4) · `waves` [{7,7,6}] · `nextWave = { aliveAtMost = 2, afterSeconds = 90 }` · `weapons` · `accuracy` [25] · `armour` [0] · `health` [200] · `behaviour` ('hold'\|'balanced'\|'push') · `surrender = { belowHealth = 0.25, chance = 0.30 }` · `peds` (models) · `boss = { model, label, health, armour, weapon, spawn (location key), surrender = {...} }` (does not scale) · `blockTraffic` [120.0] · `scene` handled by a following interact_points |
| `protect_rescue` | 15 | `npcs` (location key: list of vec4) · `count` [3] · `peds` · `restrained` [true] · `freeTime` [6000] ms · `target = { label = 'Cut restraints' }` · `safe` (location key vec3) · `safeRadius` [6.0] · `hitPenalty` [50] · `failIfDies` [true] · spawns when the run moves to In progress (`prepare`) |
| `flee_arrest` | 30 | `mode` ('door'\|'scatter') · door mode: `door` (vec4 key), `knock = { label, duration }`, `suspect` (vec4 key), `fleeTo` (list key), `responses = { surrender = 0.5, flee = 0.3, fight = 0.2 }`, `associates = { count, spawns, weapons, accuracy, armour }` (always fight) · scatter mode: `spawns` (list key), `routes` (list of lists of vec3), `suspects` [5], `armedShare` [0.4] · common: `models`, `weapons`, `fireWithin` [15.0], `escape = { distance, seconds }`, `givesUp = { aim = 10.0, stun = true, close = { distance = 3.0, seconds = 3 } }`, `armedGivesUp = { stun = true, belowHealth = 0.5 }`, `cuff = { label = 'Cuff suspect', duration = 5000 }`, `aliveBonus = { id, points, each }` |
| `pursuit` | 30 | `mode` ('stop'\|'follow') · `vehicles` [1] · `models` · `suspectsPerVehicle` [1] · `spawn` (vec4 key) or `spawns` (list key) · `route` (location key of a road route `{ points, loop }`, nil = free flee) · `speed` [120] km/h · `style` ('cautious'\|'reckless') · `trigger` ('arrive' \| `{ distance = 60.0, lights = true }` \| `{ ahead = 50.0 }`) · `stopped = { speed = 5.0, seconds = 5 }` · `footFlee` [0.2] · `surrenderOnAim` [true] · `arrest = { label, duration }` · follow mode: `hold` [150], `lost = { distance = 250, seconds = 10 }`, `duration` [180], `medals = { gold = 40, silver = 80, bronze = 150 }` (average distance, m) · `escape = { distance, seconds }` · `complete` ('all_detained'\|'all_or_timeout_any') · `ramSpeed` [100] km/h (0 = any contact counts as a ram) · `ramPenaltyId` ['hard_ram'] · `neverShoots` [true] |
| `escort` | 60 | `route` (location key `{ points = {...}, stops = { { at = 12, wait = 20 } } }`) · `vehicle` ['stockade'] · `speed` [60] · `style` ['normal'] · `toughness` [1.5] · `stoppedFail` [60] · `arrival` [20.0] · `ambushPoints` (list key) · `ambush = { waves = 2, carsPerWave = 2, perCar = 2, models, peds, weapons, accuracy, armour }` · `clearRadius` [100.0] |
| `search_area` | 60 | `center` (vec3 key) · `startRadius` [600] · `shrinkTo` [{300,150,50}] · `clues` (list key, 6+) · `clueCount` [3] · `clueProps` (`'witness'` = a witness NPC) · `clueProgress = { label, duration = 4000 }` · `hiding` (vec4 list key, 6+) · `fugitives` [1] · `runDistance` [30.0] · `givesUp = { stun = true, close = { distance = 3.0, seconds = 3 } }` · `escape = { distance = 300, seconds = 30 }` · `cuff = {...}` |

Each block's `server.lua` exposes `defaults(obj)` and `validate(obj, mission, location)` so the
loader and the Mission Builder apply exactly these defaults and guardrails.

---

## 4. The run model (owned by modules/runs, read by everyone)

### 4.1 Run table (server)

```lua
run = {
  id = 'uuid',                    -- run_uuid, shared by every participant
  mission = <mission def>, missionId = 'gang_shootout', missionType = 'tactical',
  isBoss = false, version = nil,  -- custom mission version
  locationIndex = 2, location = <location table>,
  state = 'accepted' | 'in_progress' | 'ended',
  test = nil | { adminSrc = 3, useStartRoute = false, forcedTier = 'heavy', draft = false },
  operationId = nil | 7,
  seed = 123456789,               -- same for every participant; CP.U.rng(seed) for shared randomness
  host = 12,                      -- src whose client runs NPC AI
  leader = 12,
  participants = { [src] = <participant> },   -- everyone ever on the run (status tells who is left)
  order = { 12, 15, 9 },          -- join order; host succession follows it
  expectedTier = 'reinforced',    -- tier name at accept
  tier = <Config.Scaling row>,    -- counts/accuracy/armour tier (set at In progress, can only go down)
  payTier = <Config.Scaling row>, -- points and cash tier (can only go down, see §4.3)
  modifier = nil | 'armored_hostiles' | 'time_crunch' | 'radio_silence',
  cashBase = 800,                 -- B, locked at accept (CP.Payouts.baseFor)
  pointsBase = 200,               -- P (CP.Scoring.P)
  departments = { sast = true },  -- departments of participants still in the run (M_cross counts distinct departments of everyone who was a participant at the moment the row is computed, see §6.4)
  acceptedAt = os.time(), startedAt = nil, endedAt = nil,
  timeLimit = 600,                -- after Time Crunch
  timer = { remaining = 600, paused = false, lastTick = GetGameTimer() },
  objectiveIndex = 1,
  objectives = { [i] = { status = 'pending'|'active'|'done', startedAt, doneAt, state = {} } },  -- state = the block's own table
  shared = {},                    -- cross-objective data (e.g. shared.devices)
  entities = { [netId] = { entity, kind = 'ped'|'vehicle'|'object', obj = i, role, armed, dead = false, deadAt, tag } },
  stats = { downs = 0, weaponsFired = 0 },
  score = { shared = { [bonusId] = count } },  -- awards/penalties shared by every participant
  flags = { medals = false },     -- blocks set run.flags.medals = true to drop the common fast bonus
  flagged = nil | { reason = 'outside_help', detail = '...' },   -- whole-run flag
  reserved = { missionId, locationIndex },
}
```

### 4.2 Participant table

```lua
p = {
  src = 12, citizenid = 'ABC12345', name = 'John Doe', callsign = '2L-14', rank = 'Sergeant',
  department = 'sast', departmentShort = 'SAST',
  job = 'sast',                    -- active Qbox job name at accept (job-change detection)
  status = 'active' | 'left',
  joinedAt = os.time(),
  arrived = false, arrivedAt = nil,
  endReason = nil, result = nil,   -- set when they leave or the run ends
  rowId = nil,                     -- cp_mission_runs.id once written
  score = { [bonusOrPenaltyId] = count },   -- personal awards/penalties (ped hits, lights, etc.)
  vehicle = { lastNetId = nil, engine = 1000.0, body = 1000.0, seen = false },  -- last vehicle driven during the run
  presence = { inRange = 0, total = 0 },   -- seconds sampled by CP.AntiCheat
  lastEvent = { coords = vec3, at = GetGameTimer() },  -- for the speed check
  flagged = nil | { reason = 'presence' },  -- personal flag
  firstRunSinceDuty = true|false,           -- captured at accept (CP.Scoring.isFirstRunSinceDuty)
  items = { { name, count } },               -- mission items given (to remove)
}
```

### 4.3 End reasons, results, cooldowns and the pay tier

| end_reason | Result | Type cooldown (`Config.Limits.abandonCooldown`) | Mission cooldown (`mission.cooldown`) | Keeps pay tier |
|---|---|---|---|---|
| `quit`, `off_route`, `start_timeout`, `idle`, `job_change`, `off_duty`, `suspended` | abandoned | yes | yes | no |
| `real_call_cancelled` | abandoned | yes | yes | no |
| `real_call`, `force_recall`, `cancelled` | abandoned | **no** | **no** | real_call, force_recall: yes |
| `downed` | failed | yes | yes | yes |
| `disconnected` | failed | yes | yes | no |
| `completed` / `time_limit` / `mission_failed` (still in at the end) | completed / failed | no | yes | — |

"Keeps pay tier" = `Config.Rescale.keepPayTierFor` (read from config, not hard-coded). When a
participant leaves an In-progress run: NPCs not yet spawned always shrink to the team that is left
(`Config.Rescale.enabled`), `run.tier` becomes the lower of the current tier and the tier for the
remaining count; `run.payTier` drops the same way only when the reason is not in keepPayTierFor.
Weekly Boss: abandoning (except real_call/force_recall/cancelled) uses up the week's attempt and
starts **no** type cooldown. Test runs start no cooldown and write no row.

Cooldowns are kept in memory by `CP.Runs` and rebuilt from `cp_mission_runs` rows of the last
`max(mission cooldowns, abandonCooldown)` seconds when an officer is first seen after a restart.

### 4.4 Lifecycle (server-owned)

1. `server:acceptType` (modules/draw) validates, draws, then `CP.Runs.create(...)` → state
   `accepted`, location reserved, B locked, modifier rolled, `client:start` sent to each participant,
   `CP.Route.begin(run, src)` for each, start timeout armed, items given.
2. `CP.Route` detects arrival → `CP.Runs.markArrived(run, src)` → `CP.Alerts.set(src)`; the first
   arrival moves the run to `in_progress`: tier from active participants (or `test.forcedTier`),
   `client:inProgress`, every block's `prepare`, objective 1 `start`, timer starts.
3. Blocks call `ctx.complete()` / `ctx.fail(reason)`; the engine advances objectives. The last
   objective done → `CP.Runs.endRun(run, 'completed', 'completed')`. Timer out →
   `endRun(run, 'failed', 'time_limit')` unless the block's `onTimeout(ctx)` returns `'completed'`.
4. `CP.Runs.removeParticipant(run, src, endReason)` for individual leaves; the run ends (abandoned,
   cleanup) when no active participant is left.
5. `endRun` → per participant: `CP.Scoring.compute`, `CP.Cash.compute`, row insert, `CP.Cash.pay`,
   `CP.Scoring.onRowCounted`, `CP.Goals.onRunCompleted`, `client:runEnded`, cleanup of every
   entity/item/reservation, `CP.Operations.onRunEnded(run, state)` when `operationId`.
6. Resource stop: every entity deleted, every flag removed (modules/alerts), no rows, no cooldowns.

---

## 5. Module APIs

Signatures are `CP.X.fn(args) -> returns`. "S" = server, "C" = client. Functions marked
*(hook)* are called by other modules at the named moment; implement them even if they do little.
All functions that may query the database must be called from a thread (they may yield).

### 5.1 Integrations (only these touch outside resources)

Verified integration facts (exact signatures, payloads, pitfalls) are in `docs/INTEGRATIONS.md`.
Implementers of modules/integrations/* must follow it; the most important points are repeated here.

**CP.Qbx** — modules/integrations/qbx
- S `getPlayer(src) -> player|nil` (raw qbx player object)
- S `getInfo(src) -> info|nil` where `info = { src, citizenid, name, firstname, lastname, job = { name, label, type, onduty, gradeLevel, gradeName }, callsign, metadata, isDead, inLastStand }`
- S `getByCitizenId(citizenid) -> src|nil`
- S `getOnlinePlayers() -> { src, ... }`
- S `getJobs() -> table` (qbx jobs)
- S `addMoney(src, account, amount, reason) -> boolean`
- S `isDowned(src) -> boolean` (`metadata.isdead == true or metadata.inlaststand == true`)
- S `onDutyChange(fn(src, onDuty))`, `onPlayerLoaded(fn(src))`, `onJobChange(fn(src, job))`, `onPlayerUnload(fn(src))`, `onGroupUpdate(fn(src))` — register listeners (any number).
  Sources: `QBCore:Server:SetDuty (src, onDuty)`, `QBCore:Server:PlayerLoaded (player)`,
  `QBCore:Server:OnJobUpdate (src, job)`, `QBCore:Server:OnPlayerUnload (src)`,
  `qbx_core:server:onGroupUpdate (src, groupName, grade|nil)` — all server-local: register with
  **AddEventHandler only, never RegisterNetEvent** (a net handler would let clients spoof them). SetDuty can
  arrive stale/out of order: listeners must re-read `getInfo(src).job.onduty` before acting on "on duty".
- C `getPlayerData() -> PlayerData`, `onJobUpdate(fn(job))`, `onDutyChange(fn(onDuty))`, `onUnload(fn())`, `onLoaded(fn())`

**CP.Dispatch** — modules/integrations/sc_dispatch (S only)
- `available() -> boolean` (sc-dispatch started)
- `isSuspended(citizenid, jobName) -> boolean`
- `lookupActiveCall(callId) -> uniqueId|nil` — `SELECT unique_id FROM mdt_dispatch WHERE (id = ? OR unique_id = ?) AND active = 1` with the number and string form
- `clearNotification(uniqueId, jobs)` (pcall-wrapped)
- `normalizeCallId(id) -> string` (`123`, `'123'`, `123.0` → `'123'`; other strings unchanged)
- `onResponding(fn(src, callId, isResponding))` (RegisterNetEvent `sc-dispatch:server:ToggleResponding`; capture `source` first), `onCallCleared(fn(callId))` (AddEventHandler only — server-local), `onDispatchRestart(fn())` (sc-dispatch start/stop wipes every call), `onShotsFired(fn(src, data, receivedAt))`, `onPlayerDown(fn(src, data, receivedAt))`, `onPlayerDead(fn(src, data, receivedAt))` — listeners; `receivedAt = os.time()` when the event arrived

**CP.Ambulance** — modules/integrations/sc_ambulance
- S `doctorCount() -> integer` (pcall; 0 when sc-ambulance is not started, with one error log)
- S `revive(src)` → `TriggerClientEvent('hospital:client:Revive', src)` (numeric src only, never -1)
- C `sendEMSRequest()` → `TriggerServerEvent('hospital:server:EMSDownAlert', streetName)` from the downed player's own client

**CP.Banking** — modules/integrations/renewed_banking (S only)
- `recordDeposit(citizenid, amount, message, issuer, receiver, transId)`
- `withdrawSociety(account, amount) -> boolean`
- `recordSocietyWithdraw(account, amount, message, issuer, receiver, transId)`
- `societyBalance(account) -> number|nil`

### 5.2 CP.Access — modules/access
- S `departmentForJob(jobName) -> deptKey|nil`
- S `department(key) -> sanitised dept` `{ key, label, short, jobs, supervisorGrade, societyAccount, theme = { primary, accent, background, surface, text }, logo = { url|nil, watermark, opacity, size, grayscale } }` (invalid colours fall back to the Crimson-Police default with one console warning; `text` auto-picked with `CP.U.contrastText`; `logo.url` = `https://cfx-nui-Crimson-Police/logos/<file>` or the configured https url)
- S `departments() -> { dept, ... }` sorted by key
- S `getOfficer(src) -> officer|nil, errKey` — on-duty, active job in a department, not suspended (Crimson-Police or SC-Dispatch). errKeys: `err.not_police`, `err.not_on_duty`, `err.suspended`, `err.suspended_dispatch`
- S `isAdmin(src) -> boolean` (`IsPlayerAceAllowed(src, Config.AdminAce)`; src 0 = console = true)
- S `isSupervisor(src) -> boolean`
- S `role(src) -> 'admin'|'supervisor'|'officer'|nil` (highest)
- S `recheck(src, jobName) -> ok, endReason` — for players on a run: `'off_duty'|'job_change'|'suspended'` when they no longer qualify (job change = active job name differs from `jobName`, the one they accepted with; a job outside every department also counts as job_change)
- S `isSuspended(citizenid) -> boolean, untilTs` (cp_officers.suspended_until)
- S `suspend(citizenid, days, actorSrc, reason) -> ok, errKey` (0 days lifts it)
- S `refreshOfficerRow(src)` — upsert cp_officers callsign, rank_label, display_name, department (on load and on tablet open)
- S `onLost(fn(src, endReason))` — fired immediately on qbx duty/job events for a player who no longer qualifies
- S export `GetDepartment(src) -> deptKey|nil`

### 5.3 CP.Permissions — modules/permissions (S)
- `can(src, action, ctx) -> boolean, errKey` — admin: always true for admin and supervisor actions. Supervisor: `CP.Access.isSupervisor(src)` and `Config.Permissions.supervisor[action] == true`. Admin-only actions (never allowed for supervisors whatever the config): `setMissionPayout`, `clearPayout`, `manualAward`, `handleFailedDispute`, `voidAnyRun`, `seasons`, `bountyOverride`, `suspend`, `reloadMissions`, `testRun`, `openAdmin`. Also `viewMissionList` (supervisors and admins). errKey `err.no_permission`.
- `actionsFor(src) -> { actionName, ... }` (for the session)
- `tookPart(citizenid, runUuid) -> boolean` (any cp_mission_runs row of that run for that citizenid)
- `canReviewRun(src, runUuid) -> boolean, errKey` — false when the reviewer took part (`err.own_run`)

### 5.4 CP.Tablet — modules/tablet (owns the NUI)
Server:
- callback `getSession(args)` → Session (§9.2). `args.ui` = 'officer'|'supervisor'|'admin'.
- `notify(src, kind, key, vars, opts)` → client toast (`kind` = 'info'|'success'|'warning'|'error'); `opts = { title = key, duration = ms }`
- `notifyMany(srcs, kind, key, vars)`
- `push(src, topic, data)` → NUI `{ type = 'push', topic, data }` (live screen updates)
- `openAdmin(src)` → opens the Admin UI (called by modules/admin for `/CrimsonPoliceAdmin`)
- Logo check at start (`LoadResourceFile` of each department's logo file) and one warning per logo
  the NUI reports as failed (`logoFailed` client action).
Client:
- `/CrimsonPolice` command (`Config.Tablet.command`), optional keybind (`Config.Tablet.keybind`, via
  `RegisterKeyMapping`), optional ox_inventory item (`Config.Tablet.item`), export `OpenTablet()`.
- `open(ui)` / `close()` / `isOpen()`; the Officer/Supervisor UI plays the tablet prop
  (`Config.Tablet.prop`) and animation; closing removes the prop.
- `send(msg)` → `SendNUIMessage(msg)`
- `notify(kind, text, opts)` (already translated text) and handler for `crimson-police:client:notify`
- `hud(patch)` → merges into the HUD state and sends `{ type = 'hud', hud = state }`; `hud(nil)` hides it
- `result(result)` → `{ type = 'result', result }`
- `overlay(o)` → `{ type = 'overlay', overlay = o }` (placement, recording, pick-up fade text)
- `registerClientAction(name, fn(payload) -> ok, data|errKey)` — NUI 'client' endpoint handlers
- NUI callbacks: `ready`, `close`, `request`, `action`, `client`, `switchUi` (§9.1)
- Closes the tablet on job/duty loss (`CP.Qbx` client events) and character unload.

### 5.5 CP.Schedule — modules/schedule (S)
All times are server local time; the "day" starts at `Config.Time.resetHour`.
- `now() -> os.time()`
- `dayKey(ts?) -> 'YYYY-MM-DD'` (the reset-adjusted day), `dayStart(ts?) -> ts`
- `weekStart(ts?) -> ts` (resetHour on `Config.Leaderboard.weekStartsOn`), `weekKey(ts?) -> 'YYYY-MM-DD'` of the week start
- `monthStart(ts?) -> ts` (1st of the month at resetHour)
- `weekday(ts?) -> 'monday'..'sunday'` of the reset-adjusted day
- `sqlTime(ts) -> 'YYYY-MM-DD HH:MM:SS'`
- `onDaily(fn(dayKey))`, `onWeekly(fn(weekKey, prevWeekStartTs))`, `onMonthly(fn(monthStartTs))` — fired once when the boundary passes (checked every 30 s; never fired just because the resource started)
- Retention job at each daily reset: move `cp_mission_runs` rows older than `Config.Retention.runArchiveMonths` months into `cp_mission_runs_archive` (INSERT … SELECT then DELETE, only when > 0); delete `cp_audit` rows older than `Config.Retention.auditDays` (0 = off).

### 5.6 CP.Missions — modules/missions
Server:
- `loadAll()` — reads `missions/builtin/index.lua` (returns a list of ids), runs each file in a
  sandbox (`load(chunk, '@missions/builtin/<id>.lua', 't', env)` with `RegisterMission`, `vec3`,
  `vec4`, `vector3`, `vector4`, `math`, `string`, `table`, `pairs`, `ipairs`, `tonumber`,
  `tostring`, `type`), then asks `CP.Builder.loadPublished()` for custom missions; normalises and
  validates each (blocks' `validate`), keeps the valid ones, warns about the rest, then broadcasts.
- `reload() -> summary` (admin `/CrimsonPoliceAdmin reload`; also calls `CP.Builder.onReload()`
  for hand edits), `get(id)`, `all() -> { [id] = def }`, `list() -> sorted list`,
  `byType(type) -> list` (excludes the boss), `isEnabled(id)` (published, not archived, not in
  `Config.DisabledMissions`), `normalize(def, meta) -> def|nil, err`, `serializeForClient(def)`
- `register(def)` / `unregister(id)` — used by the builder for publish/archive without a reload.
- `parse(luaSource, chunkName) -> def|nil, err` — runs one mission file's source in the loader sandbox and returns the raw definition (used by the builder for custom files and hand-edit reloads).
- callback `getMissionDefs` → every definition for clients (plain tables, vectors as {x,y,z,w}).
Client:
- `CP.Missions.get(id)`; receives `crimson-police:client:missions` (full list) after load/reload.

### 5.7 CP.Draw — modules/draw (S)
- `pool(missionType, members) -> { def, ... }, reasonKey` — published, enabled, type match, open to
  every member's department, supports `#members`, off per-mission cooldown for every member
- `draw(missionType, members, opts) -> def, locationIndex | nil, reasonKey` — no-repeat rules
  (`Config.Draw.avoidLast` / `avoidLastLarge` / `largePool`), location via `pickLocation`
- `pickLocation(def, participantSrcs, rng, opts) -> index|nil` — skips reserved locations and
  (while another is free) spots with a non-participant player within `Config.Draw.playerClearance`
- `reserve(runId, missionId, index)`, `release(runId)`, `isReserved(missionId, index) -> boolean`
- `recordLast(citizenid, missionType, missionId)`
- `boardCards(src) -> BoardData` (§9.4; callback `getMissionTypes`)
- Handles `server:acceptType` (payload = type key or `'weekly_boss'`): leader only; checks role,
  duty, unit, cooldowns, `CP.Calls.isOnCall`, hourly cap, `CP.Runs.capsOk`, `CP.Operations.isLocked`,
  `CP.Events.bossAvailable`, `CP.Alerts.foreignFlag` for every member (`err.in_arena`); then `CP.Units.lock(unit)`, draw, `CP.Runs.create`.

### 5.8 CP.Scaling — modules/scaling (S)
- `tierFor(n) -> row` (first `Config.Scaling` row with `maxParticipants >= n`, else the last)
- `tierByName(name) -> row`, `lower(a, b) -> row` (the lower tier), `label(name) -> text`
- `scaleCount(base, tier) -> int` (`CP.U.round(base * tier.count)`)
- `apply(mission, tier) -> objectivesCopy` — deep copy of `mission.objectives` with every
  `mission.scaling` path scaled (numbers and lists of numbers; `{ path, max }` clamps)
- `combat(baseAccuracy, baseArmour, tier, run) -> accuracy, armour` (+ tier; + `Config.Events.armoredArmour` when the run's modifier is `armored_hostiles`)

### 5.9 CP.Events — modules/events (S)
- `typeOfTheDay(dayKey?) -> typeKey|nil` (seed = `CP.U.hash(dayKey)`; nil when `Config.Events.typeOfTheDay` is false)
- `rollModifier(run) -> key|nil` — `Config.Events.modifierChance`; never for operations, the boss or tests; `armored_hostiles` only for Tactical
- `modifiers() -> { key = { label = locale key } }`
- `bossAvailable(src, officer) -> ok, reasonKey` — enabled, weekday in `Config.Events.weeklyBoss.days`, not used this week (any boss row this week except end_reason real_call/force_recall/cancelled)
- `bossCard(src) -> card|nil` (§9.4)

### 5.10 CP.Runs — modules/runs (the engine)
Server:
- `create(opts) -> run|nil, errKey` — `opts = { mission, locationIndex, missionType, members = { officer }, leaderSrc, operationId, test, isBoss }`
- `get(runId)`, `getBySrc(src) -> run, participant` (active participants only), `all() -> list`,
  `isOnMission(src)` (+ export `IsOnMission(src)`)
- `capsOk(missionType) -> ok, errKey` (`Config.Limits.maxConcurrentRuns` / `maxConcurrentTactical`; operations and tests don't count)
- `cooldowns(citizenid) -> { types = { [type] = untilTs }, missions = { [id] = untilTs } }`, `onCooldown(citizenid, missionType, missionId) -> boolean, untilTs`
- `completionsLastHour(citizenid) -> int`
- `markArrived(run, src)` *(hook, from CP.Route)*
- `removeParticipant(run, src, endReason, opts) -> rowId|nil` — `opts.keepFlag` (downed), `opts.silent`
- `reclassify(citizenid, runId, newEndReason)` *(hook, from CP.Calls: real_call → real_call_cancelled)* — updates the row, applies the type cooldown, drops the pay tier if the run is still running
- `endRun(run, state, endReason)` — state `'completed'|'failed'`
- `objectiveComplete(run, index, data) -> boolean` (false when minSeconds is not reached yet; flags `too_fast`)
- `dispatch(run, index, src, ev) -> ok, reason` — deliver a SERVER-originated event (e.g. from CP.Npc: `{ type = 'cuffed', netId }`, `{ type = 'shot', netId, src }`, `{ type = 'damaged', netId, attacker }`) to the block's `onEvent` of objective `index` (the objective that owns the entity, `cp.obj`), bypassing the client anti-cheat checks
- Test hooks (used by CP.Testing; only valid on test runs): `testSkip(run)` (mark the current objective done regardless of minSeconds and start the next), `testRestart(run)` (block `restart` for the current objective, or stop+delete its entities and `start` again), `anchor(run) -> vec3` (teleport target: the current objective's reference point, or the start before In progress)
- Row fields owned by the engine at insert: `season_id = CP.Challenge.currentSeason() and .id`, `department` = the participant's department at the end, `departments_n`, `participants` (active at the end, plus themselves), `tier` = pay tier name, `modifier`, `mission_version`, `location_label`, `duration_s`, `breakdown` = RunResult JSON (9.6)
- `entityDied(run, netId, killerSrc)` — the single death path: marks the entity dead (for corpse cleanup and caps), updates stats, calls the owning block's `onEntityDead`. CP.Npc calls it for peds (with killer attribution); CP.Runs itself detects wrecked vehicles (`GetVehicleEngineHealth <= -3999` / not driveable / `GetEntityHealth <= 0`) and calls it with killerSrc nil
- `failRun(run, reasonKey)` → `endRun(run, 'failed', 'mission_failed')`
- `award(run, id, opts)`, `penalize(run, id, opts)` — `opts = { src = nil (shared) | src (personal), count = 1 }`
- `adjustTimer(run, seconds)` (negative = time off), `pauseTimer(run, paused)`, `remaining(run)`
- `spawnPed(run, opts) -> entity, netId` · `opts = { obj = i, model, coords = vec4, role, armed = false, weapon, accuracy, armour, health, cfg = {}, tag }`
- `spawnVehicle(run, opts) -> entity, netId` · `opts = { obj, model, coords = vec4, role, tag, plate }`
- `spawnObject(run, opts) -> entity, netId` · `opts = { obj, model, coords = vec3|vec4, role, tag, frozen = true }`
- `deleteEntity(run, netId)`, `entitiesFor(run, filter) -> list`, `canSpawn(run, n, armed) -> boolean` (caps `Config.Limits.maxArmedAlive` / `maxEntities`, counted now; callers wait and retry, never cut counts)
- `send(run, eventName, ...)` → `TriggerClientEvent` to every active participant
- `objectiveEvent(run, index, data)` → `crimson-police:client:objective` (runId, index, data)
- `hud(run, patch)` → `crimson-police:client:hud` to participants; `hudFor(run, src, patch)`
- `view(run, src) -> ActiveMissionView` (§9.4) and `summary(run) -> LiveRun` (§9.5)
- `isParticipant(run, src)`, `activeSrcs(run) -> list`, `host(run) -> src`
- Handles `server:objective` (runId, index, evidence) → `CP.AntiCheat.checkEvent` → block `onEvent`;
  `server:abandon` (runId) → `removeParticipant(run, src, 'quit')`; `server:telemetry` (runId, kind, data)
  kinds: `ped_hit`, `lights_siren`, `weapon_fired`, `vehicle` (netId of the vehicle they drive).
- Loops: 1 s timer/block tick; `Config.AntiCheat.jobRecheck` access recheck; corpse cleanup
  (`Config.Limits.corpseCleanup`); start timeout per participant; `playerDropped` → `disconnected`;
  character unload → `disconnected`; resource stop → delete all entities, no rows.
- Entity state bag: every spawned entity gets `Entity(e).state:set('cp', { run = id, obj = i, role, state = 'idle', armed, cfg }, true)`.
Client:
- `CP.Runs.current() -> clientRun|nil` (`{ id, mission, location, locationIndex, seed, isHost, test, state, tier, payTier, modifier, objectiveIndex }`)
- `report(index, evidence)` → `server:objective` (fills `coords` = player coords and `time` = GetGameTimer())
- `telemetry(kind, data)`
- `getEntity(netId, timeoutMs) -> entity|nil`, `control(entity, timeoutMs) -> boolean` (NetworkRequestControlOfEntity loop; host only)
- `hudDetail(text|nil)` — a client-side HUD line for the current objective (e.g. "Hold still: 6 s")
- Registers client actions (NUI `client` endpoint): `logResult` `{ point, choice }` → `report(currentIndex, { type = 'log', point, choice })` (Business Check tablet log)
- Runs the client halves of blocks: `prepare`, `start`, `update`, `stop`, `hostChanged` (§7.2).
- Personal telemetry loops during a run (only while on a run): ped hits by the player's vehicle,
  lights/siren on Beat Patrol and Business Check, weapon fired, current vehicle netId.

### 5.11 CP.Npc — modules/npc (shared NPC behaviour for blocks)
Server:
- `setState(run, netId, state, extra)` — authoritative ped state in the `cp` bag:
  `'idle'|'hostile'|'fleeing'|'surrendered'|'cuffed'|'dead'|'restrained'|'freed'|'safe'|'driving'|'stopped'`
- `getState(netId) -> state`, `isNeutralised(netId) -> boolean` (dead or cuffed)
- `rollSurrender(run, netId, chance) -> boolean` (server rng)
- `enableCuff(run, netId, opts)` — participants get ox_target "Cuff suspect" when state is `surrendered`
  (`opts = { label, duration = 5000, maxDistance = 3.0 }`); a validated cuff sets `cuffed` and calls the
  block's `onEvent` with `{ type = 'cuffed', netId }`
- `onDeath(fn(run, netId, killerSrc|nil, killerIsParticipant))` — every mission ped death once
  (server polls health; killer from `GetPedSourceOfDeath`, or the driver of the killing vehicle);
  `CP.AntiCheat.onNpcKilled` is called for non-participant killers
- `weaponDamageEvent` listener: a participant shooting a `surrendered`/`cuffed`/`restrained` ped →
  `CP.Runs.penalize(run, 'shot_surrendered', { src })` and the owning block's `onEvent` `{ type = 'shot', netId, src }`
- `onDamaged(fn(run, netId, attackerSrc))` for blocks that care (hostages)
Client (host runs AI; all participants see targets):
- `apply(entity, cfg)` — model config from the `cp` bag: accuracy, armour, health, weapon,
  `SetPedDropsWeaponsWhenDead(ped, false)`, 
  combat attributes by behaviour, no ragdoll/flee when hostile (relationship groups `CRIMSONPOLICE_HOSTILE`/`CRIMSONPOLICE_NEUTRAL`)
- `task(entity, action, args)` actions: `combat` (nearest participant), `flee` (from participants, or along points), `handsUp`, `kneel`, `cuffed`, `follow` (walk to coords), `cower`, `wander`, `enterVehicle`, `driveTo`, `driveRoute` (TaskVehicleDriveToCoordLongrange waypoint by waypoint)
- Reacts to `cp` state bag changes (`AddStateBagChangeHandler('cp', ...)`) on the host: surrendered →
  hands up then kneel; cuffed → cuffed anim + freeze; fleeing → flee; hostile → combat.
- `nearestParticipant(coords) -> ped, dist` using the run's participant list.

### 5.12 CP.Route — modules/route (Hard rule 17)
Server: `begin(run, src)`, `stop(run, src)`, `status(run, src) -> { status, secondsLeft, recalcsLeft, distance }`;
handles `server:routeStatus` (runId, metres, coords) and `server:recalcRoute` (runId); arrival check
(ped within `location.start.radius` of `location.start.coords`) every 1 s → `CP.Runs.markArrived`;
off-route timing per `Config.Route`; drift check; `client:routeWarning` (runId, secondsLeft|nil);
abandons with `off_route`. Test runs with `useStartRoute = false`: only the arrival check.
Client: `begin(runId, startCoords)` (waypoint + GPS sampling every `Config.Route.sampleEvery` m with
`GetPosAlongGpsTypeRoute`), `recalculate()`, `stop()`, reports every `Config.Route.reportEvery` s;
client actions `setGps`, `recalcRoute` registered with `CP.Tablet.registerClientAction`.

### 5.13 CP.Calls — modules/calls (Hard rule 15)
- `isOnCall(src) -> boolean` (a live real-call responding entry, `Config.Calls.respondingExpiry`)
- Listens through `CP.Dispatch.onResponding` / `onCallCleared`; npccall- ids never end a run;
  own-run call ids (`Config.Calls.ownRunCallPrefixes` + `<partnerSrc>_`) are ignored for partners;
  only `CP.Dispatch.lookupActiveCall` hits count; ends the run with `real_call` and within
  `Config.Calls.dodgeWindow` of an un-mark calls `CP.Runs.reclassify(..., 'real_call_cancelled')`.

### 5.14 CP.Alerts — modules/alerts (Hard rule 16; the only writer of the crimsonArena bag)
- `set(src)` → `Player(src).state:set('crimsonArena', { active = true, source = 'crimson-police' }, true)`
- `clear(src)` → only when the current value's `source == 'crimson-police'`; sets it to nil (replicated)
- `has(src) -> boolean` (our flag is on)
- `foreignFlag(src) -> boolean` — a `crimsonArena` value with `active == true` whose `source` is not `'crimson-police'` (Crimson-Arena's). `set` does nothing (returns false) while a foreign flag is present.
- `inArena(src) -> boolean` — `foreignFlag(src) or GetPlayerRoutingBucket(src) ~= 0` (the gate every module uses)
- `wanted` intent table, re-assert of our flag after a foreign wipe, `foreignClearedAt[src]` — see docs/CRIMSON_ARENA.md rules 1–3 and 9
- Start: removes leftover Crimson-Police flags from every online player. Stop: clears all.
- Backstop listeners (shots fired within `Config.Alerts.backstopRadius` of the run's start or the
  participant's objective area; person down/dead while flagged) → clear after `Config.Alerts.backstopDelay` s.

### 5.15 CP.Downed — modules/downed (Hard rule 18)
Server: every `Config.Downed.checkEvery` s checks active participants with `CP.Qbx.isDowned`;
downed → `CP.Runs.removeParticipant(run, src, 'downed', { keepFlag = true })`, run stats `downs + 1`;
no EMS (`CP.Ambulance.doctorCount() == 0`) → after `Config.Downed.pickupDelay` s `client:pickup`
(runId, dropOff) then `CP.Ambulance.revive(src)` then `CP.Alerts.clear(src)`; EMS on duty →
`CP.Alerts.clear(src)` then `client:requestEMS` (runId). Once per downed participant; cancelled on drop/unload.
Client: `client:pickup` → fade out, overlay "Picked up by an NPC unit", wait for revive, detach, move to the drop-off, fade in; `client:requestEMS` → `CP.Ambulance.sendEMSRequest()`.

### 5.16 CP.Units — modules/units
Server: `unitOf(src) -> unit|nil` (`unit = { id, leader, members = { src... }, invites = { [src] = expiresAt }, locked }`),
`members(src) -> { src... }` (solo: `{ src }`), `isLeader(src)`, `lock(unit)`, `unlock(unit)` *(hook: runs call it when the run ends)*,
`remove(src)`; handles `server:unitInvite` (targetSrc), `server:unitRespond` ({ accepted, unitId }),
`server:unitLeave`; callback `getUnit` → UnitView (§9.4). Pushes `unit` topic to members.
Client: nothing beyond NUI (optional toast on invite).

### 5.17 CP.Operations — modules/operations (Cross-Department Missions)
Server: `active() -> op|nil`, `isLocked() -> boolean`, `boardCard(src) -> card|nil`, `launch(src, missionId)`,
`startNow(src)`, `relaunch(src)`, `cancel(src, reason)`, `join(src, opId)` (`server:joinOperation`),
`onRunEnded(run, state)` *(hook)*, idle auto-cancel, launch cooldown, notifications to every on-duty
officer (`client:operation` (state, missionLabel)). Actions `server:sup:op*` and `server:admin:op*`
(§8). Callback `sup:getOperation`.

### 5.18 CP.Scoring — modules/scoring (S)
- `P(mission) -> number` (type points × `Config.Difficulty.pointsByStars[difficulty]`; boss: `Config.Events.weeklyBoss.points`)
- `compute(run, p, result, opts) -> breakdown` (§9.6 `points`) — formula of the spec incl. cap, streak, ToD, failed credit (`objectivesDone / total`)
- `isFirstRunSinceDuty(src) -> boolean` + duty tracking (via `CP.Qbx.onDutyChange`)
- `streak(citizenid) -> { days, multiplier, graceLeft }`
- `onRowCounted(citizenid, row)` *(hook: row counts toward boards now — completed/failed and not flagged)* → XP, streak (completed only), badges
- `onRowApproved(rowId)`, `onRowVoided(rowId)` *(hooks)* — XP add/remove, badges
- `manualAward(actorSrc, citizenid, points, reason) -> ok, errKey` (a `manual_award` row, audited)
- `xpLevel(xp) -> { label, badge, xp, next }`, `badges(citizenid) -> list`

### 5.19 CP.Goals — modules/goals (S)
- `forOfficer(citizenid) -> { daily = Goal, weekly = Goal }` (`Goal = { id, label, count, progress, done, points }`)
- `onRunCompleted(citizenid)` *(hook)* → inserts a `goal` row once per period when a goal completes

### 5.20 CP.Cash — modules/cash (S)
- `compute(run, p) -> amount, breakdown` (§9.6 `cash`)
- `pay(rowId)` — the claim-then-pay flow of the spec (paying → paid/capped/unfunded)
- `payPending(src)` *(hook: player loaded)* — pays `pending` rows
- `release(rowId)` (flag approved: held → pay now or pending), `forfeit(rowId)`
- `range(missionType, members) -> min, max` for board cards (modifiers and admin payouts in the pool)
- `stuckPayments() -> list` (rows still `paying`)
- `earnedThisWeek(citizenid) -> number`
- Forfeiture job (every 10 min): voided rows with `cash_status = 'held'` older than `Config.Disputes.windowHours` and no open dispute → `forfeited`

### 5.21 CP.Payouts — modules/payouts (S)
- `typePayout(type) -> amount, adminLocked` · `missionPayout(missionId) -> amount|nil`
- `baseFor(mission) -> B` · `sourceFor(mission) -> 'admin'|'type'|'event'`
- `setType(src, type, amount|nil, reason, role) -> ok, errKey` (nil = clear, admin only; supervisor limits)
- `setMission(src, missionId, amount|nil, reason) -> ok, errKey` (admin only)
- `list() -> { types = {...}, missions = {...} }`
- Registers `server:sup:setTypePayout`, `server:admin:setTypePayout`, `server:admin:setMissionPayout`, callbacks `sup:getPayouts`, `admin:getPayouts`.

### 5.22 CP.Leaderboard — modules/leaderboard (S)
- callback `getBoard({ period, filter, department })` → Board (§9.4); cache `Config.Leaderboard.cacheSeconds`
- `invalidate()` *(hook: void/approve)*, `seasonPoints(citizenid) -> number`, `announcements() -> {...}`
- Weekly reset: top 3 to `cp_webhook_board`, "Officer of the Week" badge.
- callback `getProfile(citizenid|nil)` → Profile (own when nil) and `server:setHideName` action.

### 5.23 CP.Challenge — modules/challenge (S)
- `currentSeason() -> season|nil`, `startSeason(src, name)`, `endSeason(src)`
- `standings(seasonId?) -> { departments = {...} }`, `bounty(weekKey?)`, `overrideBounty(src, objective)`
- Weekly close: bounty winner once; season end: champions, badges, board webhook.
- callbacks `getChallenge`, `getDeptContributors`, `admin:getSeasons`; `championBanner(dept)`.

### 5.24 CP.Disputes — modules/disputes (S)
- `server:dispute` ({ rowId, reason }) — own flagged/voided/failed rows within `Config.Disputes.windowHours`
- `forSupervisor(src) -> list`, `forAdmin() -> list`, `handle(src, disputeId, decision, reason, awardPoints)`

### 5.25 CP.Admin — modules/admin (S)
- `/CrimsonPoliceAdmin` (`Config.Tablet.adminCommand`) and every subcommand of the spec (console too):
  `payout type <type> <amount|clear> <reason>`, `payout mission <id> <amount|clear> <reason>`,
  `award <citizenid> <points> <reason>`, `season start <name>` / `season end`,
  `suspend <citizenid> <days>`, `reload`, `test <missionId> [tier] [location]`. No args → `CP.Tablet.openAdmin(src)`.
- `audit(actor, role, category, action, target, old, new, reason)` — `actor` = src or citizenid or 'console';
  writes `cp_audit` and posts to the category webhook (`cp_webhook_audit|flags|builder|operations`, convars)
- `webhook(category, title, description, fields)` (category 'board' also allowed)
- `voidRun(src, rowIdOrRunUuid, reason)`, `approveFlagged(src, rowId, reason)`, `voidFlagged(src, rowId, reason)`
- Supervisor/admin screen callbacks and actions listed in §8.3.

### 5.26 CP.AntiCheat — modules/anticheat (S)
- `checkEvent(run, src, index, evidence) -> ok, reason` — valid participant, index is the current
  objective, rate limit, speed (`Config.AntiCheat.maxSpeed` between events), duplicate
- `flag(run, src|nil, reason, detail)` — whole run (src nil) or one participant
- `onNpcKilled(run, killerSrc)` — outside kills ≥ `Config.AntiCheat.outsideKillsToFlag` → flag `outside_help`
- presence sampling (runs with 2+ participants) using block `presence`; idle check
  (`Config.AntiCheat.idleCheck`); `presenceOk(run, p) -> boolean` *(used by scoring/cash at the end)*
- `onVoided(citizenid)` → auto-suspension after `voidsToSuspend` in `voidWindowDays`

### 5.27 CP.Testing — modules/testing
Server: `start(adminSrc, { missionId, location = index|'random', tier, useStartRoute, testers = { src } }) -> ok, errKey`,
controls (`skip`, `restart`, `pause`, `complete`, `fail`, `end`, `teleport`), invites, `record(adminSrc, {...})`,
`list() -> tests view`. A test run goes through `CP.Runs.create({ test = {...} })` so everything else is identical.
`startDraft(src, def, { tier, location, useStartRoute }) -> ok, errKey` (Mission Builder test of an unpublished draft: `test.draft = true`; at the end the tester records Passed/Failed and the result goes to `CP.Builder.onDraftTested(missionId, version, tierName, passed, src)`).
Client: test-control panel focus key (RegisterKeyMapping `+crimsonpolice_testpanel`, default F9), debug overlay drawing.

### 5.28 CP.Builder — modules/builder
Server: drafts, locks, autosave, test runs of drafts (via `CP.Testing`/`CP.Runs` with `test.draft = true`),
publish (Lua export with `SaveResourceFile`), archive/restore, rollback (.bak), reload of hand edits,
`loadPublished() -> { def, ... }` *(hook for CP.Missions.loadAll)*, `onReload()`,
`onDraftTested(missionId, version, tierName, passed, src)` *(hook from CP.Testing)*. Publishing requires a passed test at the tier `CP.Scaling.tierFor(maxOfficers)` (`draft_tested = 1`).
Client: placement tool, route recording, test drive; overlays through `CP.Tablet.overlay`.

---

## 6. Cross-cutting conventions

### 6.1 Entities and NPCs
- Server spawns with OneSync server natives: `CreatePed(4, model, x, y, z, heading, true, true)`,
  `CreateVehicle(model, x, y, z, heading, true, true)` (or `CreateVehicleServerSetter` for correct
  vehicle type), `CreateObjectNoOffset(model, x, y, z, true, true, false)`. Wait until
  `DoesEntityExist`, then `NetworkGetNetworkIdFromEntity`. `SetEntityOrphanMode(entity, 2)` is not used
  (the engine deletes everything itself). Weapons: `GiveWeaponToPed(ped, hash, 250, false, true)`;
  armour: `SetPedArmour(ped, n)` (server natives).
- Anything that only exists client-side (accuracy, health above 200, combat attributes, drop-weapons,
  relationship group, tasks) is applied by the **host** client from the `cp` state bag with
  `CP.Npc.apply` after it has control. When the host changes, the new host re-applies and re-tasks.
- Relationship groups (client, host): `CRIMSONPOLICE_HOSTILE` hates `PLAYER` (5), is neutral to everything
  else; `CRIMSONPOLICE_NEUTRAL` (hostages, witnesses, racers, fugitives) is neutral to all. Only the
  relations *from* these two groups are set; `PLAYER`'s own relations are never changed (§0.14).
- Dead NPCs and wrecked vehicles are deleted `Config.Limits.corpseCleanup` s after death by the engine.
- Caps (`maxArmedAlive`, `maxEntities`) are checked *at the moment of spawning*: a wave that does not fit
  waits (re-checked each tick) and its counts are never reduced.

### 6.2 NPC state (the `cp` state bag, server-authoritative)
`Entity(e).state.cp = { run, obj, role, state, armed, cfg = { weapon, accuracy, armour, health, behaviour, model } , tag }`.
Only the server changes `state` (via `CP.Npc.setState`). Client requests are evidence events
(`{ type = 'cuffed', netId }`, `{ type = 'surrender_check', netId }`, `{ type = 'freed', netId }` …)
that the owning block validates with server-side distances and states.
Killing a `surrendered`, `cuffed`, `restrained` or unarmed suspect/fugitive/inmate/hostage fails the
mission for everyone (`ctx.fail('run.fail_killed_unarmed')`).

### 6.3 Telemetry (client → `server:telemetry`)
Sent only during a run by modules/runs/client.lua; the server rate-limits and caps counts.
- `vehicle` `{ netId }` every 5 s while the player drives: the server reads that vehicle's
  `GetVehicleBodyHealth` / `GetVehicleEngineHealth` and stores the lowest values in `p.vehicle`.
- `ped_hit` `{ netId }` — a non-mission, non-player ped damaged by the player's vehicle
  (`CEventNetworkEntityDamage` via `gameEventTriggered`); server checks it is not a run entity.
- `lights_siren` — once per run, Beat Patrol and Business Check only (`IsVehicleSirenOn`).
- `weapon_fired` — once per run when `IsPedShooting(PlayerPedId())` (for `no_weapons_fired`).
Shots at surrendered NPCs are detected server-side (`weaponDamageEvent`, §5.11).

### 6.4 Scoring details (modules/scoring implements; others rely on these meanings)
- `P = CP.Scoring.P(mission)`; common fast bonus (`+fastBonus × P` when `duration <= fastShare × timeLimit`)
  is skipped when `run.flags.medals` is true (EVOC Course, Pursuit Sim set it in `prepare`).
- No-damage bonus: `p.vehicle.seen` and lowest engine and body both above `noDamageAbove`.
  Heavy damage: lowest body below `heavyDamageBelow`, not when `mission.vehiclePenalties == false`.
- Lights & siren penalty only for `beat_patrol` and `business_check`.
- `M_cross`: 1.10 when the run's participants (everyone who was on the run and is still active at the
  end, plus the row's own officer) came from 2+ departments; the row's `departments_n` stores it.
- Streak: consecutive reset-adjusted days with a completed run; `M_streak = 1 + min(streakMax, streakStep × days)`
  where `days` includes the current day once it has a completed run. Up to `streakGraceDays` missed days
  per week (from the weekly reset) are forgiven: the streak continues but the forgiven day adds nothing.
- Presence: in runs with 2+ participants a participant under `Config.AntiCheat.presenceShare` keeps the
  run's result with 0 points and $0 and their row is flagged `presence`.
- Flagged rows: `flagged = 1`, cash `held`, not on boards and no XP until approved.

### 6.5 Cash status flow
`none` → (Completed, not flagged) claim `paying` → `paid` | `capped` | `unfunded`.
Flagged: `held` → approve → `pending` (offline) or paid now; void → stays `held` until the dispute
window closes or a dispute is rejected → `forfeited`. Failed/Abandoned rows stay `none` with 0.

---

## 7. Objective block interface

### 7.1 Server half — `blocks/<id>/server.lua`

```lua
CP.Blocks.register('hostile_waves', {
  defaults = function(obj) return obj end,                 -- fill block defaults (§3.3) in place, return obj
  validate = function(obj, mission, location) return true end,  -- or false, 'reason' (loader + builder guardrails)
  armedCount = function(obj) return 20 end,                -- armed NPCs before scaling (40 budget)
  requiredPoints = function(obj) return { 'spawns' } end,  -- location keys the builder must place
  prepare = function(ctx) end,     -- the run moved to In progress (called for EVERY objective, in order)
  start   = function(ctx) end,     -- this objective became current
  tick    = function(ctx, dt) end, -- every 1 s while current (dt seconds); check fail/complete conditions here
  onEvent = function(ctx, src, ev) return true end,       -- client evidence for this objective; return false,'reason' to reject
  onEntityDead = function(ctx, netId, killerSrc) end,     -- a ped/vehicle of this objective died
  onParticipantLeft = function(ctx, src) end,
  rescale = function(ctx) end,     -- ctx.obj now holds the counts for the smaller team: spawn only what is missing later
  onTimeout = function(ctx) return nil end,               -- return 'completed' to complete instead of failing (Street Race Bust)
  presence = function(ctx, src, coords) return distance end, -- metres from this objective's reference point (0 = inside)
  checklist = function(ctx) return { { label = 'Hostiles', done = false, value = 3, max = 20 } } end,
  restart = function(ctx) end,     -- test control: remove and respawn this objective's NPCs/props
  stop    = function(ctx) end,     -- objective finished or run ended (the engine deletes entities anyway)
})
```

`ctx` (server), built by the engine per objective:

```lua
ctx = {
  run = run, index = i, obj = <scaled objective copy>, base = <unscaled objective>,
  mission = run.mission, location = run.location, tier = run.tier, state = run.objectives[i].state,
  rng = CP.U.rng(run.seed + i),        -- deterministic per objective
  complete = function(data) end,       -- -> CP.Runs.objectiveComplete (false if minSeconds not reached: call again next tick)
  fail = function(reasonKey) end,      -- the whole run fails ('mission_failed')
  award = function(id, opts) end, penalize = function(id, opts) end,
  send = function(data) end,           -- objective update to every participant's client half (update)
  hud = function(patch) end,           -- HUD patch (e.g. { detail = 'Wave 2 of 3' })
  spawnPed = function(opts) end, spawnVehicle = function(opts) end, spawnObject = function(opts) end,  -- obj = i filled in
  canSpawn = function(n, armed) end, delete = function(netId) end,
  participants = function() return { src, ... } end,   -- active participants
  coords = function(src) return vec3 end,              -- server-side ped coords
  combat = function(acc, armour) return acc, armour end, -- CP.Scaling.combat with this run
  isHost = function(src) end, host = function() return run.host end,
}
```

### 7.2 Client half — `blocks/<id>/client.lua`

```lua
CP.Blocks.register('hostile_waves', {
  prepare = function(ctx) end,       -- run In progress (every objective)
  start   = function(ctx) end,       -- objective became current on this client
  update  = function(ctx, data) end, -- ctx.send(data) from the server half
  hostChanged = function(ctx, isHost) end,
  stop    = function(ctx) end,       -- remove markers, blips, ox_target options, threads, props it created
})
```

`ctx` (client): `{ runId, index, obj, base, mission, location, isHost, test, radioSilence, state = {},
report = function(evidence) end, hudDetail = function(text) end, participants = { src... },
getEntity = CP.Runs.getEntity, control = CP.Runs.control, seed }`.

Rules for blocks:
- NPCs/vehicles/props are created **only by the server half** (`ctx.spawnPed` …, OneSync networked).
  The client half never creates networked entities (local-only markers/blips/zones are fine).
- NPC AI runs on the host's client (`ctx.isHost`), using `CP.Npc` client helpers after `ctx.control`.
- ox_target options: `exports.ox_target:addLocalEntity(entity, options)` / `addSphereZone` /
  `addBoxZone` — only participants' clients register them, so non-participants never see them.
  Remove them in `stop` (`removeLocalEntity`, `removeZone`).
- Progress bars: `lib.progressBar({ duration, label, useWhileDead = false, canCancel = true, disable = { move = true, car = true, combat = true }, anim = {...} })`.
  Skill checks: `lib.skillCheck({ 'easy', 'medium' }, { 'w', 'a', 's', 'd' })`.
- Evidence sent with `ctx.report({ type = 'checkpoint', index = 3, netId = n, ... })`; the engine adds
  `coords` and `time`. The server half validates distances with server-side coordinates.
- Radio Silence (`ctx.radioSilence`): after the start, no blips for mission NPCs or objectives.
- Every block reads its builder ranges from `Config.Blocks[<id>]` for validation.

---

## 8. Net events, callbacks and actions (complete list)

### 8.1 Server → client events (`crimson-police:client:*`)

| Event | Args | Sent by |
|---|---|---|
| `client:start` | runId, data `{ missionId, mission, locationIndex, location, start = { coords, radius }, expectedTier, seed, host, test, modifier, participants, startRoute = bool, startTimeout, isBoss }` | runs |
| `client:inProgress` | runId, `{ tier, payTier, objectives = <scaled list>, timeLimit, remaining }` | runs |
| `client:objective` | runId, index, `{ action = 'prepare'|'start'|'update'|'stop', data }` | runs |
| `client:hud` | runId, patch | runs |
| `client:tierChanged` | runId, tierName, payTierName | runs |
| `client:hostChanged` | runId, hostSrc | runs |
| `client:participants` | runId, list `{ src, name, callsign, departmentShort, status, arrived }` | runs |
| `client:runEnded` | runId, result, endReason, breakdown (RunResult §9.6) | runs |
| `client:routeWarning` | runId, secondsLeft or nil | route |
| `client:routeRecalc` | runId, ok, recalcsLeft | route |
| `client:routeStatus` | runId, status (`'arrived'`…) | route |
| `client:pickup` | runId, dropOff (vec3) | downed |
| `client:requestEMS` | runId | downed |
| `client:operation` | state (`launched`|`started`|`ended`|`cancelled`), missionLabel | operations |
| `client:missions` | list of definitions | missions |
| `client:notify` | `{ kind, key, vars, title, duration }` | tablet (server helper) |
| `client:push` | topic, data | tablet (server helper) |
| `client:openAdmin` | session | tablet |
| `client:actionResult` | reqId, ok, data | shared/net |
| `client:testInvite` | `{ inviteId, missionLabel, from }` | testing |
| `client:test` | `{ controls = bool, debug = data }` | testing |
| `client:builder` | `{ ... }` builder-specific | builder |

### 8.2 Client → server events (spec names; payload then optional reqId)

| Event | Payload | Owner |
|---|---|---|
| `server:acceptType` | missionType (`'weekly_boss'` for the boss card) | draw |
| `server:unitInvite` | targetSrc | units |
| `server:unitRespond` | `{ accepted, unitId }` (a bare boolean = latest invite) | units |
| `server:unitLeave` | — | units |
| `server:joinOperation` | operationId | operations |
| `server:routeStatus` | runId, metres, coords (three args, no reqId) | route |
| `server:recalcRoute` | runId | route |
| `server:objective` | runId, index, evidence (three args, no reqId) | runs |
| `server:telemetry` | runId, kind, data (three args, no reqId) | runs |
| `server:abandon` | runId | runs |
| `server:dispute` | `{ rowId, reason }` | disputes |
| `server:setHideName` | boolean | leaderboard |
| `server:logoFailed` | deptKey | tablet |
| `server:testRespond` | `{ inviteId, accepted }` | testing |
| `server:pickupDone` | runId, ok (plain event, no reqId) | downed |
| `server:npcCuff` | runId, netId (plain event, no reqId) | npc |

Events with "three args, no reqId" are plain `RegisterNetEvent` handlers (client Lua → server);
all others use `CP.Net.action` (UI → server, with reply).

### 8.3 Supervisor, admin, builder and test actions (`CP.Net.action`) and callbacks (`CP.Net.callback`)

Callbacks (read): `getSession`, `getMissionTypes`, `getUnit`, `getRun`, `getHome`, `getBoard`,
`getProfile`, `getChallenge`, `getDeptContributors`, `getMissionList`, `getMissionDefs`,
`sup:getOperation`, `sup:getLiveRuns`, `sup:getReviewQueue`, `sup:getPayouts`, `sup:getDeptReport`,
`sup:getOfficerActivity`, `admin:getPayouts`, `admin:getMissions`, `admin:getSeasons`,
`admin:getBoards`, `admin:getStuckPayments`, `admin:searchOfficers`, `admin:getOfficer`,
`admin:getDepartments`, `admin:getPermissions`, `admin:getAudit`, `admin:exportAudit`,
`admin:getTests`, `admin:getFlagged`, `admin:getDisputes`, `builder:list`, `builder:get`,
`builder:config`, `test:pendingInvites`.

Actions (write), each checks `CP.Permissions.can`:

| Action | Payload | Permission | Owner |
|---|---|---|---|
| `server:sup:setTypePayout` / `server:admin:setTypePayout` | `{ type, amount (nil=clear, admin), reason }` | setTypePayout / admin | payouts |
| `server:admin:setMissionPayout` | `{ missionId, amount (nil=clear), reason }` | setMissionPayout | payouts |
| `server:sup:opLaunch` / `server:admin:opLaunch` | `{ missionId }` | launchCrossDept | operations |
| `server:sup:opStart` / `server:admin:opStart` | — | launchCrossDept | operations |
| `server:sup:opRelaunch` / `server:admin:opRelaunch` | — | launchCrossDept | operations |
| `server:sup:opCancel` / `server:admin:opCancel` | `{ reason }` | launchCrossDept | operations |
| `server:sup:forceRecall` | `{ runId, src }` | forceRecall | admin |
| `server:sup:reviewFlagged` / `server:admin:reviewFlagged` | `{ rowId, decision = 'approve'|'void', reason }` | reviewFlagged | admin |
| `server:sup:handleDispute` / `server:admin:handleDispute` | `{ disputeId, decision = 'approve'|'reject', reason, awardPoints }` | handleDisputes / handleFailedDispute | disputes |
| `server:admin:voidRun` | `{ rowId }` or `{ runUuid }`, `reason` | voidAnyRun | admin |
| `server:admin:awardPoints` | `{ citizenid, points, reason }` | manualAward | admin → scoring |
| `server:admin:suspend` | `{ citizenid, days, reason }` | suspend | admin → access |
| `server:admin:startSeason` / `endSeason` | `{ name }` / — | seasons | challenge |
| `server:admin:overrideBounty` | `{ objective }` | bountyOverride | challenge |
| `server:admin:reloadMissions` | — | reloadMissions | missions |
| `server:admin:startTest` | `{ missionId, location, tier, useStartRoute, testers }` | testRun | testing |
| `server:admin:recordTest` | `{ missionId, location, tier, result, note }` | testRun | testing |
| `server:test:control` | `{ control, ... }` | test starter only | testing |
| `server:builder:*` | see builder section of its own module header | builderEdit/Publish/Archive/EditAny/Rollback/breakEditLock | builder |

---

## 9. NUI protocol

### 9.1 Transport

Lua → NUI: `SendNUIMessage({ type = ..., ... })` (only modules/tablet/client.lua calls it).

| type | fields | meaning |
|---|---|---|
| `open` | `ui`, `session` | show a UI ('officer'\|'supervisor'\|'admin') and take focus |
| `close` | — | hide the UI (HUD stays) |
| `session` | `session` | refreshed session |
| `notify` | `notification = { id, kind, title?, text, duration }` | Crimson-Police toast |
| `hud` | `hud = HudState \| null` | mission HUD (full state) |
| `result` | `result = RunResult` | result screen |
| `push` | `topic`, `data` | live data for open screens: `run`, `unit`, `board`, `operation`, `invites`, `test`, `builder`, `payouts` |
| `overlay` | `overlay = null \| { kind: 'placement'\|'recording'\|'testdrive'\|'fade', ... }` | full-screen/HUD overlays |

NUI → Lua: `fetch('https://Crimson-Police/<endpoint>', { method: 'POST', body: JSON })`:

| endpoint | body | reply |
|---|---|---|
| `ready` | `{}` | `{ ok: true }` |
| `close` | `{}` | `{ ok: true }` |
| `request` | `{ name, args }` | `{ ok, data?, error? }` — ox_lib callback `crimson-police:<name>` |
| `action` | `{ name, payload }` | `{ ok, data?, error? }` — net event `crimson-police:<name>` (name includes `server:`) |
| `client` | `{ name, payload }` | `{ ok, data?, error? }` — client-local action (`CP.Tablet.registerClientAction`) |
| `switchUi` | `{ ui }` | `{ ok, data: Session }` |

The web bridge exposes `request<T>(name, args)`, `action<T>(name, payload)`, `clientAction<T>(name, payload)`
and `useNuiEvent(type, handler)`. In a normal browser (dev) the bridge uses registered mocks.

### 9.2 Session

```ts
interface Theme { primary: string; accent: string; background: string; surface: string; text: string }
interface Logo { url: string; watermark: boolean; opacity: number; size: number; grayscale: boolean }
interface Session {
  ui: 'officer' | 'supervisor' | 'admin';
  title: string;                                   // 'Crimson-Police'
  roles: { officer: boolean; supervisor: boolean; admin: boolean };
  officer: null | { citizenid: string; name: string; department: string; departmentLabel: string;
    departmentShort: string; rank: string; callsign: string | null; gradeLevel: number };
  theme: Theme;                                    // department theme, or Config.AdminTheme for admin
  logo: Logo | null;                               // null for admin
  actions: string[];                               // CP.Permissions.actionsFor
  locale: Record<string, string>;                  // CP.Locale.all()
  config: {
    missionTypes: { key: string; label: string; points: number }[];
    departments: { key: string; label: string; short: string; primary: string }[];
    tiers: { name: string; label: string }[];
    maxRecalcs: number; disputeWindowHours: number; periods: string[]; filters: string[];
  };
  serverTime: number;                              // os.time() at session build
}
```

### 9.3 HUD

```ts
interface HudState {
  runId: string; test: boolean; missionLabel: string;
  phase: 'route' | 'objectives' | 'ended';
  tier: string; payTier: string;                   // tier names
  modifier: null | { key: string; label: string };
  timer: null | { remaining: number; paused: boolean };   // seconds; the NUI counts down locally
  route: null | { status: 'on' | 'off' | 'arrived' | 'disabled'; secondsLeft: number | null; distance: number | null };
  objectives: { label: string; done: boolean; current: boolean; detail?: string; value?: number; max?: number }[];
  detail: string | null;                           // client-side line for the current objective
  message: null | { text: string; kind: 'info' | 'success' | 'warning' | 'error' };
  testControls: boolean;                           // the admin who started the test
}
```

### 9.4 Officer screen data (callbacks)

```ts
// getMissionTypes
interface BoardCard { key: string; label: string; points: number; cash: [number, number];
  pool: number; mode: 'solo' | 'unit'; locked: null | { reason: string; until?: number };
  busy: boolean; onCall: boolean; typeOfTheDay: boolean }
interface BoardData { cards: BoardCard[]; boss: null | (BoardCard & { available: boolean });
  operation: null | { id: number; missionLabel: string; launcher: string; status: string;
    joined: number; max: number; joinedByMe: boolean; canJoin: boolean; joinEndsIn: number | null };
  unit: { size: number; isLeader: boolean }; activeRunId: string | null }
// getUnit
interface UnitView { unit: null | { id: number; leader: number; locked: boolean;
  members: { src: number; name: string; callsign: string | null; rank: string; departmentShort: string; isLeader: boolean }[] };
  invites: { unitId: number; from: string; fromCallsign: string | null; departmentShort: string; expiresIn: number }[];
  invitable: { src: number; name: string; callsign: string | null; rank: string; departmentShort: string }[] }
// getRun (and push topic 'run')
interface ActiveMissionView { runId: string; missionLabel: string; description: string; missionType: string;
  state: 'accepted' | 'in_progress'; tier: string; tierExpected: boolean; payTier: string;
  route: HudState['route']; objectives: HudState['objectives']; remaining: number | null; paused: boolean;
  partners: { src: number; name: string; callsign: string | null; departmentShort: string; status: string; arrived: boolean }[];
  expected: { cash: number; points: number }; modifier: HudState['modifier']; test: boolean;
  recalcsLeft: number; radioSilence: boolean; log: null | { point: number; choices: { id: string; label: string }[] } }
// getHome
interface HomeData { card: { callsign: string | null; rank: string; departmentShort: string; name: string;
  xp: number; level: { label: string; badge: string; xp: number; next: number | null };
  streak: { days: number; graceLeft: boolean }; seasonPoints: number; cashThisWeek: number };
  goals: { daily: Goal | null; weekly: Goal | null }; typeOfTheDay: null | { key: string; label: string };
  announcements: { kind: string; text: string }[]; champions: null | { season: string; department: string } }
interface Goal { id: string; label: string; count: number; progress: number; done: boolean; points: number }
// getBoard({ period: 'weekly'|'monthly'|'season'|'alltime', filter: 'overall'|'patrol'|'training'|'investigation'|'tactical'|'unit'|'cross'|'department', department?: string })
interface BoardRow { rank: number; citizenid: string; name: string; callsign: string | null; departmentShort: string; points: number; runs: number; failed: number }
interface Board { period: string; filter: string; rows: BoardRow[]; me: BoardRow | null; updatedAt: number }
// getChallenge
interface ChallengeView { season: null | { id: number; name: string; weeksLeft: number };
  departments: { key: string; label: string; short: string; colour: string; score: number; activeOfficers: number }[];
  bounty: null | { id: string; label: string; leader: string | null };
  topContributors: { name: string; callsign: string | null; points: number }[] }
// getProfile(citizenid?)
interface Profile { citizenid: string; name: string; callsign: string | null; rank: string; departmentShort: string;
  xp: number; level: HomeData['card']['level']; badges: { id: string; label: string; earnedAt: string }[];
  hideName: boolean; own: boolean;
  runs: { id: number; missionLabel: string; missionType: string; state: string; endReason: string;
    points: number; cash: number; cashStatus: string; flagged: boolean; voided: boolean; createdAt: string;
    breakdown: RunResult | null; canDispute: boolean }[] }
```

### 9.5 Supervisor / admin shapes (owners define the rest in their module header comment)

```ts
interface LiveRun { runId: string; missionType: string; missionLabel: string; tier: string; state: string;
  remaining: number | null; test: boolean; operationId: number | null;
  participants: { src: number; name: string; callsign: string | null; departmentShort: string; status: string }[] }
```

### 9.6 RunResult (client:runEnded, result screen, Profile breakdown)

```ts
interface RunResult { runId: string; missionLabel: string; missionType: string;
  result: 'completed' | 'failed' | 'abandoned'; endReason: string; test: boolean;
  tier: string; payTier: string; participants: number; departments: number; durationS: number;
  points: { P: number; bonuses: { id: string; label: string; points: number }[];
    penalties: { id: string; label: string; points: number }[]; subtotal: number;
    mTeam: number; mCross: number; mStreak: number; capped: boolean; tod: boolean;
    failedShare: number | null; final: number };
  cash: { B: number; mTier: number; mMod: number; amount: number; status: string };
  flagged: null | { reason: string } }
```

---

## 10. Locale keys

- Flat dotted keys in `locales/en.json`. Each implementer writes **their own part file**
  `locales/parts/<slice>.json` (flat JSON object); the parts are merged into `en.json` at the end.
  Never edit another slice's part. Duplicate keys across parts must have identical text.
- Namespaces: `common.*` (shared words), `err.*` (error keys), `ui.*` (layout/sidebar),
  `officer.*`, `board.*`, `unit.*`, `run.*`, `hud.*`, `result.*`, `route.*`, `calls.*`, `downed.*`,
  `leaderboard.*`, `challenge.*`, `profile.*`, `sup.*`, `admin.*`, `builder.*`, `test.*`,
  `bonus.<id>`, `penalty.<id>`, `reason.<end_reason>`, `flag.<reason>`, `tier.<name>`,
  `type.<key>` is NOT used (type labels come from `Config.MissionTypes`), `block.<id>.*`, `modifier.<key>`.
- The UI reads the same strings from `session.locale` via `t(key, vars)`.

## 11. Verification (every slice must pass before it is done)

- `luac5.4 -p` on every Lua file it wrote.
- `cd Crimson-Police/web && npm run build` (tsc + vite) passes, for slices that touch web/.
- SQL: every query string it wrote must run against the MariaDB test database (`mysql -uroot cp_test`,
  schema already applied) — test SELECTs with sample params.
- Lua unit tests for pure logic go in `tests/<slice>_spec.lua` using `tests/harness.lua` (mocks of
  natives, `Config`, `CP`, and a `MySQL` that runs real queries on MariaDB `cp_test`) and run with
  `lua5.4 tests/run.lua <filter>`. See `tests/shared_spec.lua` for the pattern: `H.boot{side='server'}`,
  `H.load('modules/x/server.lua')`, stub other modules' tables (`CP.Runs = {...}`) as needed,
  `H.eq/H.ok/H.near`, `H.sql(...)` to reset tables, `H.fire(event, src, ...)` / `H.callback(name, src, args)`,
  `H.exportsMock['sc-dispatch'] = { ... }`, `H.players[src] = { coords = vec3(...), ace = {...} }`, and
  `return H` at the end. Specs run in separate processes; the database is rebuilt once per run.
  Never leave a spec that fails.
