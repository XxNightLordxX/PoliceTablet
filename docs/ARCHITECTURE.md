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
   characters and names to 64 before writing (`CP.U.clip`: at most n bytes, never ending inside a UTF-8 character).
   **Database off** (`Config.Database.enabled = false`): modules/storage replaces this resource's `MySQL` global
   with `CP.Storage.MemSQL.shim`, an in-resource engine that runs the same SQL on tables kept as files in the saves folder
   (§5.29). Modules never test the mode: they keep their SQL, and new SQL must stay inside the construct list at
   the top of `modules/storage/memsql.lua` (anything else fails there with "the saves folder engine (files mode)
   does not support ..."). Reads of another resource's table (today only sc-dispatch's `mdt_dispatch`) still go
   read-only to the real oxmysql. The only code that sends `cp_` statements to the real oxmysql in files mode
   is the admin's storage copy (`/CrimsonPoliceAdmin storage copy`, §5.29). FiveM resource KVP is never used.
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
    time, except inside functions. An admin can change any setting in game (CP.Settings, §5.36): the changed
    top-level table (`Config.Tablet`, ...) is replaced by a new one, so never keep a reference to a Config table
    across calls, and a cache of one is rebuilt when `Config.X` is no longer the same table. Code that reads a
    setting once at start waits for the changed settings first (`CP.Settings.waitLoaded` on the server,
    `CP.Settings.ready` on the client).
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
  README.md                        the one owner document (install, permissions, config, commands, troubleshooting);
                                   every folder README below is a short note that points to its section
  docs/ARCHITECTURE.md             this file
  docs/SPEC.md                     the product spec (markdown)
  docs/WEB_UI.md                   the web UI developer guide (layout, screens, NUI bridge, hooks, components)
  tests/                           Lua unit tests + MariaDB query tests (not shipped)
  Crimson-Police/                  THE RESOURCE (folder name is a Hard rule)
    README.md                      short install note (points to the root README.md)
    fxmanifest.lua
    config/config.lua              every setting (copied verbatim from the spec)
    config/blocks.lua              Mission Builder ranges and defaults (verbatim from the spec)
    shared/init.lua                CP namespace, logging, CP.Blocks registry, RegisterMission stub
    shared/locale.lua              CP.L / CP.Locale
    shared/net.lua                 CP.Net (actions and callbacks)
    shared/utils.lua               CP.U helpers (round, rng, hash, vectors, colours ...)
    config/banned_words.txt        the default banned-word list for profile bios (one word or phrase a line)
    locales/en.json                all player-facing text (merged from locales/parts/*.json; English only)
    locales/parts/<slice>.json     one part per package; `python3 tools/check_contracts.py --merge` builds en.json
    items/                         crimson_police_tablet.png, ox_inventory_items.lua (the snippet an owner pastes
                                   into ox_inventory), README.md; never loaded by the resource
    logos/sast.png, fib.png        placeholder logos, README.md
    missions/builtin/index.lua     return { 'beat_patrol', ... }
    missions/builtin/<id>.lua      one RegisterMission({...}) each
    missions/custom/<id>.lua       written by the Mission Builder
    missions/custom/archived/
    modules/<feature>/server.lua   (+ client.lua where needed)
    modules/integrations/<name>/server.lua (+ client.lua)
    modules/storage/memsql.lua     CP.Storage.MemSQL: SQL engine + saves folder for database-off mode (server)
    modules/storage/server.lua     CP.Storage: picks MySQL/MariaDB or the saves folder (Config.Database)
    saves/                         database-off data (JSON documents, _tables.json); only README.md is committed
    blocks/<block_id>/server.lua + client.lua
    web/                           React 18 + TS + Vite; builds to web/dist (committed); README.md points to
                                   docs/WEB_UI.md
    sql/migrations/001_initial.sql, 002_test_def_hash.sql, 003_run_stats.sql, 004_profile.sql,
                   005_mission_calls.sql, 006_item_rewards.sql, 007_settings.sql
```

fxmanifest loads: `@ox_lib/init.lua`, config/config.lua, config/blocks.lua, shared/*.lua
(alphabetical: init, locale, net, utils), then `modules/**/server.lua` (server) /
`modules/**/client.lua` (client), then `blocks/**/server.lua` / `blocks/**/client.lua`.
Server also gets `@oxmysql/lib/MySQL.lua`, then `modules/storage/memsql.lua` and
`modules/storage/server.lua` before every other server module (so the `MySQL` global is settled before
any module can query). `files` ships web/dist, locales/*.json and logos/*.

Extra module folders beyond the spec's table (allowed: "each feature in its own folder"):
- `modules/missions/` — the mission registry: loads built-in and custom mission files, normalises
  definitions, sends them to clients, reload.
- `modules/npc/` — shared NPC behaviour used by blocks: state machine (hostile, surrendered,
  cuffed …), host-side AI, "Cuff suspect", surrender rolls, relationship groups.

Folders of the parity-plus build (all in the spec's Feature folders table; §5.30–§5.34):
`modules/custody/` (server, client), `modules/missioncalls/` (server, client), `modules/profile/` (server),
`modules/rewards/` (server), `modules/confighealth/` (server), `modules/integrations/sc_police/` (server),
`blocks/field_contact/` and `blocks/process_scene/` (server, client). What each package built, with its
deviations, is in `docs/notes/<package>.md` (foundation, custody, missions_c, missioncalls, teams, profile,
boards, rewards, access).

`modules/diag/` (client, §5.35): the F8 command `CrimsonPoliceState`, added with the freeze fix
(`docs/notes/freeze.md`).

`modules/settings/` (server, client, §5.36): settings changed in game (Admin UI → Settings) over config.lua and
blocks.lua, the mission and location switches, and the same values on every client.

---

## 2. Shared layer (already written — read the files)

| API | File | Notes |
|---|---|---|
| `CP.resource`, `CP.isServer`, `CP.prefix` | shared/init.lua | `GetCurrentResourceName()` (`'Crimson-Police'`; everything inside the resource follows a renamed folder, see §5.34 `folder`), bool, `'crimson-police'` |
| `CP.log(tag, fmt, ...)`, `CP.warn`, `CP.err` | shared/init.lua | tagged `[crimson-police:<tag>]` |
| `CP.e(name)` | shared/init.lua | `'crimson-police:' .. name` |
| `CP.configProblem(cfg) -> nil \| 'error'\|'warn', text` | shared/init.lua | The config load check: `'error'` when `Config` is not a table (config.lua did not load), `'warn'` naming the table sections of config.lua and blocks.lua that are missing (config.lua stopped at an error, or is from an older version). The server prints it once as the file loads (tag `config`), before any module can fail on it |
| `CP.Blocks.register(id, impl)`, `.get(id)`, `.all()` | shared/init.lua | one registry per side |
| `CP.L(key, vars)`, `CP.Locale.all()`, `CP.Locale.has(key)` | shared/locale.lua | `{var}` placeholders |
| `CP.Lt(key, vars) -> token`, `CP.Locale.isToken(v)`, `encode`, `tokenize(payload)`, `resolve(text, code)`, `resolveAll(payload, code)` | shared/locale.lua | A `{ key, vars }` token for text meant for a player's screen: `CP.Runs.hud`, `ctx.hud` and `ctx.send` accept it and the client resolves it right before `SendNUIMessage` (`CP.Locale.resolveAll`). CP.L is never replaced. English only: every token resolves in the server language |
| `CP.Locale.label(key, fallback, vars)` | shared/locale.lua | The locale text when the key exists, else the fallback (config or mission text): the optional label overrides of §10 |
| `CP.Hooks.on(name, fn) -> id`, `CP.Hooks.off(id) -> bool`, `CP.Hooks.fire(name, ...) -> n` | shared/init.lua | Both sides. Listeners run in the caller's thread, in the order added, each in pcall (a failure is logged, the next still runs). The hooks and who fires them: §5.10 |
| `CP.Net.action(name, handler, opts)` | shared/net.lua | server: registers net event `crimson-police:<name>`; handler `(src, payload) -> ok, data|errKey`; replies to `reqId` |
| `CP.Net.callback(name, handler, opts)` | shared/net.lua | server: ox_lib callback `crimson-police:<name>`; handler `(src, args) -> data` or `nil, errKey`; reply `{ok,data,error}` |
| `CP.Net.rateOk(src, key, max, windowMs)` | shared/net.lua | server |
| `CP.Net.action(name, payload, timeoutMs)`, `CP.Net.request(name, args, timeoutMs)` | shared/net.lua | client; both return `{ ok, data, error }` and never raise (`err.timeout` after timeoutMs, default 15000; `err.no_response` when ox_lib raises) |
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
  quietPatrol = false,            -- true: lights and siren after the first arrival cost -10, personal
  decisions = nil,                -- optional overrides of Config.Decisions (e.g. { wrongfulArrest = 'fail' })
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

Normalising also applies `Config.MissionTweaks[id]` (cooldown, timeLimit, startTimeout, disabledLocations,
peds, vehicles, weapons; a tweak that fails validation is ignored with a warning), refuses engineOnly bonus
ids (rapid_response, first_responder, ...) and every reward-like key in a mission file, and keeps
`quietPatrol` and `decisions`. `CP.Missions.label(def, field, n)` gives the label, description or location
label through the optional overrides of §10.

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
| `checkpoint_route` | 20 | `checkpoints` (location key: list of vec3, or `{ points = {...} }` route) · `use` ('all'\|'random') · `count` (N for random) · `radius` [10.0] · `stopFor` [10] s · `vehicleRequired` [true] (a checkpoint counts only while the participant is driving a vehicle, any vehicle, checked on the server: in a vehicle and in its driver seat; the old name `policeVehicle` is read as an alias) · `medals` (false or `{ gold, silver, bronze }` seconds; a location may override with `location.medals`) · `contactPenalty` [2] s · `timerStart` ('first' checkpoint\|'start') · `failIfUndriveable` [true] |
| `interact_points` | 5 | `points` (location key: vec3/vec4, list of them, or list of `{ coords, heading, label }`) · `use` ('all'\|'random') · `count` · `target = { label, icon, radius }` · `progress = { label, duration (ms), anim }` · `roll = { outcomes = { { id, chance, followUp = { label, duration } } } }` (server rolls per point) · `logResult = { choices = { 'secure', 'found_open' }, correct = { secure = 'secure', open = 'found_open' } }` · `hidden = { count, prop, label }` (N of the points hide a device; done when all found; found devices go to `run.shared.devices`) · `fastBonus = { seconds, id }` |
| `skill_check` | 10 | `targets` ('shared:devices' or a location key) · `checks` [{'easy','medium','medium','hard'}] · `missPenalty` [30] s off the run timer · `failAfter` [2] misses in a row on one target · `target = { label, icon }` · `explosion` [true] (effect only, damage 0) |
| `hostile_waves` | 60 | `spawns` (location key: list of vec4) · `waves` [{7,7,6}] · `nextWave = { aliveAtMost = 2, afterSeconds = 90 }` · `weapons` · `accuracy` [25] · `armour` [0] · `health` [200] · `behaviour` ('hold'\|'balanced'\|'push') · `surrender = { belowHealth = 0.25, chance = 0.30 }` · `peds` (models) · `boss = { model, label, health, armour, weapon, spawn (location key), surrender = {...} }` (does not scale) · `blockTraffic` [120.0] · `scene` handled by a following interact_points |
| `protect_rescue` | 15 | `npcs` (location key: list of vec4) · `count` [3] · `peds` · `restrained` [true] · `freeTime` [6000] ms · `target = { label = 'Cut restraints' }` · `safe` (location key vec3) · `safeRadius` [6.0] · `hitPenalty` [50] · `failIfDies` [true] · spawns when the run moves to In progress (`prepare`) |
| `flee_arrest` | 30 | `mode` ('door'\|'scatter') · door mode: `door` (vec4 key), `knock = { label, duration }`, `suspect` (vec4 key), `fleeTo` (list key), `responses = { surrender = 0.5, flee = 0.3, fight = 0.2 }`, `associates = { count, spawns, weapons, accuracy, armour }` (always fight) · scatter mode: `spawns` (list key), `routes` (list of lists of vec3), `suspects` [5], `armedShare` [0.4] · common: `models`, `weapons`, `fireWithin` [15.0], `escape = { distance, seconds }`, `givesUp = { aim = 10.0, stun = true, close = { distance = 3.0, seconds = 3 } }`, `armedGivesUp = { stun = true, belowHealth = 0.5 }`, `cuff = { label = 'Cuff suspect', duration = 5000 }`, `aliveBonus = { id, points, each }` |
| `pursuit` | 30 | `mode` ('stop'\|'follow') · `vehicles` [1] · `models` · `suspectsPerVehicle` [1] · `spawn` (vec4 key) or `spawns` (list key) · `route` (location key of a road route `{ points, loop }`, nil = free flee) · `speed` [120] km/h · `style` ('cautious'\|'reckless') · `trigger` ('arrive' \| `{ distance = 60.0, lights = true }` \| `{ ahead = 50.0 }`) · `stopped = { speed = 5.0, seconds = 5 }` · `footFlee` [0.2] · `surrenderOnAim` [true] · `arrest = { label, duration }` · follow mode: `hold` [150], `lost = { distance = 250, seconds = 10 }`, `duration` [180], `medals = { gold = 40, silver = 80, bronze = 150 }` (average distance, m) · `escape = { distance, seconds }` · `complete` ('all_detained'\|'all_or_timeout_any') · `ramSpeed` [100] km/h (0 = any contact counts as a ram) · `ramPenaltyId` ['hard_ram'] · `neverShoots` [true] |
| `escort` | 60 | `route` (location key `{ points = {...}, stops = { { at = 12, wait = 20 } } }`) · `vehicle` ['stockade'] · `speed` [60] · `style` ['normal'] · `toughness` [1.5] · `stoppedFail` [60] · `arrival` [20.0] · `ambushPoints` (list key) · `ambush = { waves = 2, carsPerWave = 2, perCar = 2, models, peds, weapons, accuracy, armour }` · `clearRadius` [100.0] |
| `field_contact` | 30 | `mode` ('parked'\|'scene'\|'stop') ['scene'] · `people` [1] (scene) · `cars` [1] · `spots` (parked: location key, list of `{ coords = vec4, rule, street }`) · `car` (scene: vec4 key) · `peopleSpots` (scene: list key of vec4) · `fleeTo` (list key of lists of vec3) · `transport` (vec4 key, optional; default the location's `transport`) · `profileSet` ['scene'] · `scene` (variants `{ occupied_car = 0.5, loitering = 0.3, casing = 0.2 }`) · `approach` [25.0] · `probableCause` [true] · `custody` ['handover'] · `returning` `{ chance = 0.25, max = 1 }` (parked) · `thief` `{ chance = 0.5, runAt = 15.0 }` (parked) · `escapeFails` [true] · `escape` `{ distance = 400, seconds = 20 }` · `revealed` (facts known from the start, e.g. `{ 'stolen' }`) · `bestPoints` [10] · `allCorrect` `{ id = 'all_correct' }` \| false · `aliveBonus` `{ id = 'subject_alive' }` · `models`, `vehicles`, `weapons` · `decisions` (overrides of Config.Decisions) |
| `process_scene` | 5 (0 with no bodies) | `scene` (vec3 key) · `coroner` (vec4 key \| false; false = release at the scene marker) · `bodies` [4] · `roles` [{ 'hostile', 'suspect', 'associate', 'inmate', 'boss', 'subject' }] · `tag = { label, duration = 5000 }` · `bag = { label, duration = 6000 }` · `release = { label, duration = 8000 }` · `aliveBonus = { id = 'all_taken_alive', points = 15 }` |
| `pursuit` (added) | — | `responses = { yield, flee, fight }` [nil = flee], rolled per vehicle from its own seed stream · `handoff` ('arrest'\|'contact') ['arrest']: with 'contact' the stopped car is written to `run.shared.contacts` (`{ vehicle, occupants = { { netId, seat, state, truth } }, observed, forced, profileSet, truth }`) and `CP.Runs.adoptMany` moves the car and its people to the next field_contact objective before the pursuit completes · `observe` [false] \| `{ kind = 'pace'\|'follow' (or kinds), zoneSpeed = 80 (or a location key), over = { 20, 45 }, behind = 80.0, seconds = 5, tolerance = 5 }` (pace passes when the median sample ≥ zoneSpeed + over[1] − tolerance; follow = within 60 m behind for 8 s) · lights before the observation cost the lighting officer `stop_without_cause` · `driveBy` [0] and `ram` [0] (percent; participants only) · `spawnOffset` [false] \| metres (−250 to 250; negative = upstream, the car drives past the officer) · `profileSet` · `team = n` (skipped when fewer than n participants: Traffic Enforcement's second violator) · a 'removed' vehicle is never stopped |
| `interact_points` (added) | — | `together = { count = 2, window = 6, soloProgress = 8000 }` (count capped at the participants left; a unit that drops to one finishes with soloProgress) · `hidden.kind` ('device'\|'seize') ['device']: seized finds never go to `run.shared.devices` · `hidden.action = { label, duration }` (a follow-up seize at each find) · `finds = { chance, pool = { 'narcotics', 'weapon', 'stolen_goods', 'documents' } }` (rolled once per point; `run.shared.evidence`, the `evidence` stat) · `fastBonus.after = n` (the fast clock starts when objective n ends) · ANIMS gains `notepad` and `photo` |
| `skill_check` (added) | — | `onFail` ['fail'] \| `{ setback = { label, duration = 10000, penalty = 'lab_fire' }, retryAfter = 30 }`: failAfter misses start a recovery step (a dwell at the target, report 'recover'), the officer who missed pays the penalty, a retry opens retryAfter s after the recovery; the case never fails |
| `flee_arrest` (added) | — | `demeanour` (weights, a fixed name, or 'rolled') · `feint` [0] (percent, unarmed suspects only; bolts after Config.Npc.feintAfter with nobody within feintRange or aiming) · `custody` ['cuff'] \| 'handover' (`CP.Custody.enableChain`) |
| `hostile_waves` (added) | — | `behaviour` (a name, or weights `{ hold = 0.5, balanced = 0.4, push = 0.1 }`, rolled per spawn from the objective seed) · `spawnSets = { keys = { 'front', 'house', 'garage' }, use = 2, intel = true }` (the intel line `block.hostile_waves.intel` in `run.shared.intel`) · `boss.aliveBonus = { id, points }` · Config.NpcDifficulty changes feel only (health, surrender) |
| `search_area` | 60 | `center` (vec3 key) · `startRadius` [600] · `shrinkTo` [{300,150,50}] · `clues` (list key, 6+) · `clueCount` [3] · `clueProps` (`'witness'` = a witness NPC) · `clueProgress = { label, duration = 4000 }` · `hiding` (vec4 list key, 6+) · `fugitives` [1] · `runDistance` [30.0] · `givesUp = { stun = true, close = { distance = 3.0, seconds = 3 } }` · `escape = { distance = 300, seconds = 30 }` · `cuff = {...}` |

Each block's `server.lua` exposes `defaults(obj)` and `validate(obj, mission, location)` so the
loader and the Mission Builder apply exactly these defaults and guardrails.

Evidence field_contact accepts: `{ type = 'action', netId, action, phase = 'begin'|'finish' }` (from the plain
event `crimson-police:server:custody`), `{ type = 'decide', netId, choice, offence }` (from the action
`server:contactDecide`), `{ type = 'cuffed', netId }` (CP.Npc), `{ type = 'aim' | 'stunned', netId }` (client
reports), and the engine's entity events `{ type = 'handed_over' | 'impounded' | 'removed', netId }`
(`CP.Runs.entityEvent`). The block keeps the Contact panel in `ctx.state.contact`; `CP.Runs.view` returns it
as `ActiveMissionView.contact` (web/src/types/custody.ts). process_scene takes `tag_begin`/`tag`,
`bag_begin`/`bag` (a body within 2.5 m) and `release_begin`/`release` (the parked van within 6 m, or the scene
marker), each finish after its duration (−0.5 s) with the officer in reach the whole time minus 2 s.

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
  seed = 123456789,               -- server only: drives the hidden rolls (ctx.rng); never sent to a client
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
  -- parity-plus (modules/runs, WP1)
  quietPatrol = false,            -- mission.quietPatrol: lights_siren counts only after the run is In progress
  decisions = { <DecisionEntry> },   -- the ledger (CP.Runs.decide): contact, choice, verdict, facts, knownAt ...
  arrested = { [netId] = src },   -- one arrest per person (CP.Runs.noteArrest)
  missionCall = nil | { id, code, area, targetS, staff },   -- a claimed mission call (rapid response unless staff)
  removedVehicles = { [netId] = { src, via } },            -- vehicles removed from outside (sc-police /imp)
  holdBodies = nil | { roles, max }, held = { netId, ... },  -- bodies kept for Process the scene (FIFO past max)
  fastClockAt = nil | ms,         -- CP.Runs.pauseFastClock: the fast-completion clock stopped
  failReason = nil | 'reason.*',  -- why the case failed (a decision, a removed vehicle ...)
  -- run.shared gains contacts (pursuit → field_contact hand-off), intel (hostile_waves) and evidence (finds);
  -- run.entities[netId] gains hidden, armedTruth (server only: a contact's hidden gun, counted by the caps)
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
  stats = { citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok, decisions_best,
            decisions_bad, lethal, arrests },   -- CP.Runs.noteStat / noteArrest; written to the row (003)
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
| `vehicle_removed_external` (a run vehicle removed by someone outside the run, or vanished with nothing recorded) | abandoned (not counted: no points, cash or abandon penalty) | **no** | **no** | — |

"Keeps pay tier" = `Config.Rescale.keepPayTierFor` (read from config, not hard-coded). When a
participant leaves an In-progress run: NPCs not yet spawned always shrink to the team that is left
(`Config.Rescale.enabled`), `run.tier` becomes the lower of the current tier and the tier for the
remaining count; `run.payTier` drops the same way only when the reason is not in keepPayTierFor.
Weekly Boss: abandoning (except real_call/force_recall/cancelled) uses up the week's attempt and
starts **no** type cooldown. Test runs start no cooldown and write no row.

Every row also gets the 003 columns: `location_index`, the stats above, `medal` (1 gold, 2 silver, 3 bronze
from the medal_* awards), `mission_call_id` and `response_s` (seconds from accept to that participant's
arrival). Stats are written on every row, and only `state = 'completed'` rows are ever summed.

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
- S `addMoney(src, account, amount, reason) -> boolean, why|nil` — amount rounded with `CP.U.round`; `why = 'error'` when `AddMoney` raised (the balance may already have changed: never retry or refund; CP.Cash leaves the row `paying`); a plain refusal returns only `false`
- S `isDowned(src) -> boolean` (`metadata.isdead == true or metadata.inlaststand == true`)
- S `onDutyChange(fn(src, onDuty))`, `onPlayerLoaded(fn(src))`, `onJobChange(fn(src, job))`, `onPlayerUnload(fn(src))`, `onGroupUpdate(fn(src))` — register listeners (any number).
- S `onMetaDataChange(fn(src, key, old, new), keys?)` — `qbx_core:server:onSetMetaData (key, oldValue, value, source)`, fired after the value is set; `keys` filters before any thread starts (CP.Downed uses `isdead` / `inlaststand`).
  Sources: `QBCore:Server:SetDuty (src, onDuty)`, `QBCore:Server:PlayerLoaded (player)`,
  `QBCore:Server:OnJobUpdate (src, job)`, `QBCore:Server:OnPlayerUnload (src)`,
  `qbx_core:server:onGroupUpdate (src, groupName, grade|nil)`, `qbx_core:server:onSetMetaData` — all server-local: register with
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

Parity-plus additions to the integrations:
- **CP.Qbx** S `plateOwned(plate) -> bool|nil` — `SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1`, read-only,
  always the real oxmysql (`CP.Storage.realMySQL` with the database off); nil on error (the caller then uses the
  reserved plate pattern alone). Used only to reroll a mission plate.
- **CP.Dispatch** S `realCallSummary() -> { total, p1 } | nil` — the Dispatch screen's real-call strip:
  `SELECT priority, COUNT(*) AS n FROM mdt_dispatch WHERE active = 1 AND (unique_id IS NULL OR unique_id NOT LIKE ?)
  GROUP BY priority` with `Config.Calls.npcCallPrefix` LIKE-escaped plus `%`; cached
  `Config.MissionCalls.realCallCache` s; nil on error (the strip is hidden). S `mdtCommendations(citizenid) -> list
  | nil` — `SELECT title, issued_by, UNIX_TIMESTAMP(created_at) AS ts FROM employee_incidents WHERE citizenid = ?
  AND type = 'commendation' ORDER BY created_at DESC LIMIT 10` (Config.Profile.showMdtCommendations, off by default);
  nil on error. Both read-only, never mixed with a cp_ table.
- **CP.ScPolice** — modules/integrations/sc_police (S only). A second, read-only `police:server:Impound` handler:
  when its netId (the 7th argument) is a vehicle of a live run it calls `CP.Runs.noteExternalRemoval(netId, src,
  'sc_impound', dist)` with the sender's server-side distance. It never triggers, cancels or answers a police:*
  event. `onImpound(src, netId) -> bool`.

### 5.2 CP.Access — modules/access
- S `departmentForJob(jobName) -> deptKey|nil`
- S `department(key) -> sanitised dept` `{ key, label, short, jobs, supervisorGrade, societyAccount, theme = { primary, accent, background, surface, text }, logo = { url|nil, watermark, opacity, size, grayscale } }` (invalid colours fall back to the Crimson-Police default with one console warning; `text` auto-picked with `CP.U.contrastText`; `logo.url` = `https://cfx-nui-<CP.resource>/logos/<file>` or the configured https url)
- S `departments() -> { dept, ... }` sorted by key
- S `getOfficer(src) -> officer|nil, errKey` — on-duty, active job in a department, not suspended (Crimson-Police or SC-Dispatch). errKeys: `err.not_police`, `err.not_on_duty`, `err.suspended`, `err.suspended_dispatch`
- S `isAdmin(src) -> boolean` (`IsPlayerAceAllowed(src, adminAce())`, or `IsPlayerAceAllowed(src, 'admin')` while `Config.QboxAdmins == true`: Qbox's own admin ace, which a stock Qbox server gives `group.admin`; only an explicit `true` counts, so a config.lua without the line keeps the ace alone; src 0 = console = true). Every admin check in the resource goes through it
- S `adminAce() -> string` (`Config.AdminAce`, or `'crimsonpolice.admin'` when it is empty or not a string)
- S `qboxAdminAce() -> 'admin'|nil` (`'admin'` while `Config.QboxAdmins == true`, else nil)
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

Parity-plus additions (WP1, WP8; docs/notes/access.md):
- S `getSession(args)`: `args = { ui, via = 'command'|'keybind'|'item'|'export'|'desk'|'dispatch', desk = index,
  silent }`. For the Officer and Supervisor UIs every way ends in `T.checkAccess(src, officer, via, desk)`:
  a way switched off in `Config.Tablet.access` → `err.access_off`; `CP.Alerts.inArena` → `err.in_arena`; a desk
  index that names no desk, or the ped outside the desk box grown by 2 m (server coordinates, rotation included)
  → `err.not_at_desk`; a desk of other departments → `err.desk_department`; requireItem: every way but a desk
  needs the item (`ox_inventory:Search(src, 'count', item)` in pcall; a failed lookup counts as no item only
  while requireItem is on) → `err.no_tablet_item`. A request naming no way reuses the last passed way of that src.
  The session gains `officer.avatar`, `officer.level`, `prefs`, `access = { via, desk }` and the config values
  `dispatch`, `leaderboardMetrics`, `profile`, `commendationKinds`, `rewards`, `format` (English only: no language
  list and no per-player language).
- S `desk(i)`, `deskAllows(desk, dept)`, `inDeskBox(desk, coords, margin)`, `hasTabletItem(src)`, `checkAccess(...)`.
- S `navCounts(src) -> NavCounts` and callback `getNavCounts`: invites, calls (CP.MissionCalls.claimableCount),
  review (supervisors: flagged rows, disputes and profile queue; 30 s cache), commendations, rewards, onRun, each
  through a guarded call (a missing module gives 0); the whole set is cached 5 s per src. Every push of unit,
  invites, calls, profile, rewards or run schedules one `nav` push 1 s later for a src that asked in the last 10 min.
- Plain event `server:tabletItemGone` (2 a second): with requireItem on, not at a desk and the item really gone, the
  server sends `client:closeTablet` (errKey). Callback `admin:getTabletAccess` → TabletAccessView
  (web/src/types/access.ts).
- C Down (metadata `isdead` / `inlaststand`, or a dead ped): the Officer and Supervisor UIs refuse to open
  (`err.downed`) and close within 0.5 s when the officer goes down while they are open, so no NUI focus is held
  while sc-ambulance's death or last stand screen is up (the owner's rule for sc-dispatch's bill). The Admin UI is
  exempt.
- C Every `open` sent to the NUI carries `seq`. Once the NUI said at `ready` that it confirms (`{ acks = true }`), an
  open it does not confirm with `opened { seq }` within 6 s closes the tablet and releases the focus (a crashed or
  never-loaded page must not hold the cursor). The NUI hands the focus back itself (`close`) when an `open` cannot
  be shown or a layout crashes (§9.1).
- C `open(ui, opts)` with `opts = { via, desk, screen }`; key mapping `crimsonpolice_dispatch`
  (`Config.Tablet.dispatchKey`) opens on Dispatch; mission desks are ox_target box zones (`crimson-police:desk`)
  created once, shown only to an on-duty officer of an allowed department outside Crimson-Arena (display only),
  removed on resource stop and on a foreign arena flag; at a desk `Config.Tablet.deskScenario` plays and the tablet
  closes beyond `Config.Tablet.deskDistance`; with requireItem the client checks the item every second while open.

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

Parity-plus additions (WP1): `normalize` keeps `quietPatrol` and `decisions`, applies `Config.MissionTweaks`, refuses
engineOnly bonus ids and reward-like keys; `label(def, field, n)` (§10); the new block ids field_contact and
process_scene are known to the loader.

Settings additions (§5.36): `isLocationEnabled(id, index, map?) -> bool` (`Config.DisabledLocations[id]` lists the
locations turned off, by label or number; `map` replaces that table), `enabledLocations(def) -> { index }`;
`isEnabled(id)` is also false when every location of the mission is off. `loadAll` waits for `CP.Migrations.ready()`
first, so built-in missions are normalised with the settings changed in game.

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

Parity-plus additions (WP4; docs/notes/missioncalls.md):
- `pool(type, members, opts)`, `draw(type, members, opts)`, `pickLocation(def, srcs, rng, opts)`: `opts.area` (hard:
  only missions and locations in that area), `opts.avoid` (soft), `opts.nearCoords` (county-wide weighting
  `1 / (1 + km / Config.MissionCalls.countyWeightKm)`), `opts.exclude` (hard). Rules in pickLocation's order:
  reservations, exclude and area (hard); zone clearance (`Config.Draw.zoneClearance` from every point of every held
  location of any mission; soft, falls back to the reservation rule); avoid = each participant's last
  `Config.Draw.avoidLastLocations` locations of that mission (soft); player clearance; then a weighted pick (half
  weight for a spot taken within `Config.Draw.locationFreshness`, and the county-wide weighting).
- `footprint(def, index) -> { vec3 }` (start and every point; routes sampled every 50 m).
- A location turned off (`CP.Missions.isLocationEnabled`) is a hard rule of `pickLocation` (also for Cross-Department
  Missions, the Weekly Boss and a random test location) and counts in no area (`pool` with `opts.area`,
  `CP.MissionCalls`); `_locationOn(def, i)`.
- `check(src, typeKey, counts?) -> ok, errKey` — every accept check without changing anything (a claim runs these).
- `accept(src, typeKey, opts)` — `opts.area`, `opts.nearCoords`, `opts.missionCall` (`{ id, code, area, staff }`; the
  response target is set here from the unit's nearest member to the drawn start), `opts.onDone`. Units of 2+ go
  through `CP.Units.readyCheck(unit, typeKey, onReady, onCancel)` (guarded: without it the draw follows at once)
  and the accept returns `{ pending = true }`.
- Daily cap: `Config.Limits.maxCompletionsDay` and `Config.MissionTypes[type].dailyLimit` through
  `CP.Runs.completionsToday`: `err.daily_cap`, `err.member_daily_cap`, `err.type_daily_cap`,
  `err.member_type_daily_cap`; the card is locked (`locked.daily = true`, `until` = next day start); BoardData
  gains `callsOpen`.
- `noRepeat(list, hist)`, `history(citizenid, type)`, `typeValues(type, officers, list) -> cash, points`,
  `recordLocation(citizenid, missionId, index)`, `locationStats(missionId)` (callback `admin:getLocationStats`).

### 5.8 CP.Scaling — modules/scaling (S)
- `tierFor(n) -> row` (first `Config.Scaling` row with `maxParticipants >= n`, else the last)
- `tierByName(name) -> row`, `lower(a, b) -> row` (the lower tier), `label(name) -> text`
- `scaleCount(base, tier) -> int` (`CP.U.round(base * tier.count)`)
- `apply(mission, tier) -> objectivesCopy` — deep copy of `mission.objectives` with every
  `mission.scaling` path scaled (numbers and lists of numbers; `{ path, max }` clamps)
- `combat(baseAccuracy, baseArmour, tier, run) -> accuracy, armour` (+ tier; + `Config.Events.armoredArmour` when the run's modifier is `armored_hostiles`)

Parity-plus: `combat()` adds `Config.NpcDifficulty[preset].accuracyAdd/armourAdd`; `feel() -> { healthMult,
surrenderMult, fleeMult }` for the blocks. Presets change how NPCs feel, never points or cash.

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
- `endRun(run, state, endReason)` — state `'completed'|'failed'`; an active participant who is down at that moment (`CP.Qbx.isDowned`, not in the arena) leaves first through `CP.Downed.handle` (result Failed, end_reason `downed`) and only the others get the run's end state
- `noteWeaponFired(run, src)` — server-side proof for `no_weapons_fired` (CP.Npc: a participant's gun hit or gun kill on a mission ped; the `weapon_fired` telemetry also goes through it)
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
- Entity state bag: every spawned entity gets `Entity(e).state:set('cp', { run = id, obj = i, role, state = 'idle', armed, cfg }, true)`. The server keeps its own copy in `run.entities[netId].bag` and never reads the bag back (a client can write the bag of an entity it owns): the armed-alive cap counts through `CP.Npc.getState`, and "is this a run entity" (vehicle / pedestrian telemetry) is answered from `run.entities` only.
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

Parity-plus additions (WP1; docs/notes/foundation.md):
- `noteStat(run, src|nil, key, n)` — citations, impounds, rescues, vehicles_stopped, evidence, decisions_ok,
  decisions_best, decisions_bad, lethal (nil src = every active participant now); `noteArrest(run, src, netId) ->
  bool` (one arrest per person per run; false for a repeat).
- `decide(run, src, entry) -> bool` — entry `{ contact, kind, choice, verdict ('best'|'ok'|'wrong'|'critical'),
  bonusId, points, truthKey, bestChoice, facts, factLog, discoverable, knownAt, failKey, netId }`: the ledger, the
  decision stats, noteArrest for an Arrest graded best or ok, the personal award or penalty (points 0 = graded, no
  points), and 'critical' fails the run with failKey. `factLog = { { key, text, at } }` (every fact the decider had,
  as text, with the os time it reached them) is kept as `{ key, text, atS }` (seconds from the start).
- `notePerson(run, netId, { label?, demeanour?, did? }) -> bool` — the people debrief: a person's label and
  demeanour, and what they did (`did` one of walked_away, ran, drew, surrendered, feinted, cuffed, escaped, killed;
  each once, in order). CP.Custody notes every contact person, flee_arrest every person with a demeanour.
  Server-only until the run ends: RunResult.people is filled only for rows settled when the run has ended.
- `adopt(run, netId, toIndex)`, `adoptMany(run, netIds, toIndex) -> n` — an entity moves to another objective
  (record, bag, CP.Npc.adopt); the host gets `client:objective` `{ action = 'adopt', netId, obj, from }`.
  `ownerOf(run, netId)`, `entityEvent(run, netId, ev)` (handed_over, impounded, removed to the owning objective).
- `spawnPed(run, { hidden = true, armed, weapon, accuracy, armour })` — a contact: bag armed = false and no
  weapon or combat cfg; `armedTruth` counts toward `maxArmedAlive`. `arm(run, netId) -> bool` gives it once (the draw).
- `isMissionPlate(plate)` — every mission vehicle gets a `Config.Custody.plates` plate, rerolled (5 tries) when
  `CP.Qbx.plateOwned` says a player owns it; plates come from their own random stream, never the run seed.
- `holdBodies(run, { roles, max })`, `heldBodies(run)`, `releaseBody(run, netId)`; `pauseFastClock(run)` (once; the
  time limit grows by 60 s + 20 s per held body).
- `noteExternalRemoval(netId, src, via, dist)` — remembered 15 s. A vanished run vehicle whose last sample had engine
  and body above 0 is removed, not wrecked: `{ type = 'removed' }` to its objective; a participant's removal flags
  `sc_impound` and fails the run (`reason.vehicle_removed`); anyone else's, or none recorded, removes everyone with
  `vehicle_removed_external` and writes the audit (`vehicleRemoved`, reason = the sender's citizenid).
- `completionsToday(citizenid, missionType|nil)` — completed rows since the daily reset, no manual_award, goal or
  operation rows; 10 s cache cleared on a completion.
- create `opts.missionCall` (rapid_response on arrival within targetS, never for staff calls); `view` adds `intel`,
  `missionCall = { code, targetS, arrivedS }` and `contact` (CP.Custody.view); RunResult adds decisions, people,
  stats (lethal left out), missionCall, progress and items. Config.Decisions.debrief = false sends the officer's
  result card without decisions and people and leaves them out of the officer's own history (getProfile); the
  stored breakdown keeps them for disputes and staff.
- `hud`, `hudFor`, `ctx.hud`, `ctx.send` accept CP.Lt tokens. Client: HUD patches and objective updates are resolved
  with `CP.Locale.resolveAll` before the NUI; the 'adopt' action calls the new objective's client half
  `adopt(ctx, netId, from)` and the old one's `release(ctx, netId)`; `CP.Runs.adoptedBy(netId)`.
- Hooks it fires (CP.Hooks): `run:created (run)`, `run:arrived (run, src, isFirst)`, `run:inProgress (run)`,
  `participant:left (run, src, endReason)`, `row:settled (run, p, rowId, row, result)` (may yield; listeners may add
  to result), `run:ended (run, state, endReason)` (may yield). Fired elsewhere: `row:approved (rowId)` and
  `row:voided (rowId)` (CP.Scoring), `row:forfeited (rowId)` (CP.Cash), `arena:exited (src)` (CP.Alerts' 1 s
  reconcile when inArena turns false), `xp:levelUp (citizenid, src|nil, oldLevel, newLevel)` (CP.Scoring),
  `goal:completed (citizenid, goalId, period)` (CP.Goals), `season:ended (seasonId, { champion, top10 })`
  (CP.Challenge), `home:extras (citizenid, src, extras)` (CP.Scoring homeData), `officer:loaded (src)` (CP.Cash).

### 5.11 CP.Npc — modules/npc (shared NPC behaviour for blocks)
Server:
- `setState(run, netId, state, extra)` — authoritative ped state in the `cp` bag:
  `'idle'|'hostile'|'fleeing'|'surrendered'|'cuffed'|'dead'|'restrained'|'freed'|'safe'|'driving'|'stopped'`
- `getState(netId) -> state`, `isNeutralised(netId) -> boolean` (dead or cuffed) — from the server record per net id (seeded from `run.entities[netId].bag`, mirrored back after every write), never from the replicated bag
- `rollSurrender(run, netId, chance) -> boolean` (server rng)
- `enableCuff(run, netId, opts)` — participants get ox_target "Cuff suspect" when state is `surrendered`
  (`opts = { label, duration = 5000, maxDistance = 3.0 }`); a validated cuff sets `cuffed` and calls the
  block's `onEvent` with `{ type = 'cuffed', netId }`
- `onDeath(fn(run, netId, killerSrc|nil, killerIsParticipant))` — every mission ped death once
  (server polls health; killer from `GetPedSourceOfDeath`, or the driver of the killing vehicle);
  `CP.AntiCheat.onNpcKilled` is called for non-participant killers
- `weaponDamageEvent` listener: a participant shooting a `surrendered`/`cuffed`/`restrained` ped →
  `CP.Runs.penalize(run, 'shot_surrendered', { src })` and the owning block's `onEvent` `{ type = 'shot', netId, src }`;
  a gun hit (not melee, not a vehicle) by an active participant on a mission ped, or a participant's gun kill
  (noted before `entityDied`), → `CP.Runs.noteWeaponFired(run, src)`
- `onDamaged(fn(run, netId, attackerSrc))` for blocks that care (hostages)
Client (host runs AI; all participants see targets):
- `apply(entity, cfg)` — model config from the `cp` bag: accuracy, armour, health, weapon,
  `SetPedDropsWeaponsWhenDead(ped, false)`, 
  combat attributes by behaviour, no ragdoll/flee when hostile (relationship groups `CRIMSONPOLICE_HOSTILE`/`CRIMSONPOLICE_NEUTRAL`)
- `task(entity, action, args)` actions: `combat` (nearest participant), `flee` (from participants, or along points), `handsUp`, `kneel`, `cuffed`, `follow` (walk to coords), `cower`, `wander`, `enterVehicle`, `driveTo`, `driveRoute` (TaskVehicleDriveToCoordLongrange waypoint by waypoint)
- Reacts to `cp` state bag changes (`AddStateBagChangeHandler('cp', ...)`) on the host: surrendered →
  hands up then kneel; cuffed → cuffed anim + freeze; fleeing → flee; hostile → combat.
- `nearestParticipant(coords) -> ped, dist` using the run's participant list.

Parity-plus additions (WP2; docs/notes/custody.md):
- States `contacted`, `escorted`, `seated`, `released`, `handed_over`, `impounded`; contacted, escorted and seated are
  protected (shot_surrendered); `isNeutralised` accepts dead, cuffed, escorted, seated and handed_over.
- `adopt(netId, obj)`; a hidden contact is refused 'hostile' until `CP.Runs.arm` gave it its weapon.
- excessive_force: a participant's melee or taser hit on a cuffed, escorted, seated or contacted ped
  (weaponDamageEvent), the health-drop fallback, and validated `stun_hit` telemetry; at most once per person per 10 s.
- `watch(run, netId, src, range)`, `inReachSince(run, netId, src) -> ms|nil`, `unwatch(netId, src)` (the dwell sampler
  of police actions, peds and vehicles); `stunMatches(netId, windowMs)`, `runOf(netId)`.
- The `lethal` stat when a participant kills a ped of a suspect role; `Config.Custody.handcuffsItem` makes Cuff
  suspect need that item (`err.npc_no_handcuffs`; never used or taken).
- Client: ox_target options `crimson-police:contact_<action>` on peds and vehicles, `crimson-police:custody_escort`,
  per door `crimson-police:seat_<action>_<door>` (bones door_dside_f, door_pside_f, door_dside_r, door_pside_r), the
  `crimsonpolice_contact` key (Run plate from the driver seat, Hand over, Place in vehicle, Escort), host tasks for
  escort, tells and contactAct behaviours, `stun_hit` from CEventNetworkEntityDamage.

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
- `hold(src, on)` (CP.Downed keeps a downed participant's flag), `forget(src) -> boolean` — drops our intent, hold, orphan timer and queued re-assert **without touching the bag** (CP.Runs uses it when an in-arena participant leaves; CRIMSON_ARENA rule 1)
- Start: removes leftover Crimson-Police flags from every online player. Stop: clears all.
- Backstop listeners (shots fired within `Config.Alerts.backstopRadius` of the run's start or the
  participant's objective area; person down/dead while flagged) → clear after `Config.Alerts.backstopDelay` s.

Parity-plus: the 1 s reconcile fires `arena:exited (src)` once when `inArena(src)` turns false (flag cleared, or the
bucket back to 0 with no flag change).

### 5.15 CP.Downed — modules/downed (Hard rule 18)
Server: every `Config.Downed.checkEvery` s checks active participants with `CP.Qbx.isDowned`;
downed → `CP.Runs.removeParticipant(run, src, 'downed', { keepFlag = true })`, run stats `downs + 1`;
no EMS (`CP.Ambulance.doctorCount() == 0`) → after `Config.Downed.pickupDelay` s `client:pickup`
(runId, dropOff) then `CP.Ambulance.revive(src)` then `CP.Alerts.clear(src)`; EMS on duty →
`CP.Alerts.clear(src)` then `client:requestEMS` (runId). Once per downed participant; cancelled on drop/unload.
Also reacts at once to `CP.Qbx.onMetaDataChange` (`isdead` / `inlaststand` set to true).
`handle(run, src) -> boolean` *(hook, from CP.Runs.endRun)*: holds the flag and removes the participant with
`{ keepFlag = true }` before anything yields, then starts the pick-up / EMS flow in its own thread; false (nothing
done) when they are not active, in the arena, the run ended, or that down is already past the leave.
`cancel(src, reason)`, `isPending(src)`.
Client: `client:pickup` → fade out, overlay "Picked up by an NPC unit", wait for revive, detach, move to the drop-off, fade in; `client:requestEMS` → `CP.Ambulance.sendEMSRequest()`.
End of the follow-up: every way an entry leaves the pending stages (done, every cancel reason, the EMS hand-over)
sends `client:downedEnded` (runId, reason) once. The client tracks its own fade and overlay (set before the call that
shows them, cleared after the one that removes them); a pick-up still running for that run stops as on
`client:pickupCancel`, otherwise anything of ours still on screen is undone. C `restore(why) -> boolean`: the same
safety net, a no-op while a pick-up runs; CP.Runs calls it at every run cleanup. `server:pickupDone` is sent once per
pick-up (before the screen is restored), and a pick-up whose abort fails still ends and clears `busy()`.

### 5.16 CP.Units — modules/units
Server: `unitOf(src) -> unit|nil` (`unit = { id, leader, members = { src... }, invites = { [src] = expiresAt }, locked }`),
`members(src) -> { src... }` (solo: `{ src }`), `isLeader(src)`, `lock(unit)`, `unlock(unit)` *(hook: runs call it when the run ends)*,
`remove(src)`; handles `server:unitInvite` (targetSrc), `server:unitRespond` ({ accepted, unitId }),
`server:unitLeave`; callback `getUnit` → UnitView (§9.4). Pushes `unit` topic to members.
Client: nothing beyond NUI (optional toast on invite).

Parity-plus additions (WP5; docs/notes/teams.md): `kick(src, target)`, `promote(src, target)`, `disband(src)` (leader
only; `err.unit_locked` once a type is accepted; a kicked officer can't be invited by that unit for
`Config.Units.kickReinvite` s), `cancelInvite(src, target)` (leader or inviter), `Config.Units.invitePolicy`
('anyone' | 'leader'), `readyCheck(unit, typeKey, onReady, onCancel) -> started` (units of 2+: every member but the
leader gets `client:readyCheck` with the type only; all accept → onReady once; a decline, the timeout
(`Config.Units.readyTimeout`), leaving, off duty, a real call or the arena → `onCancel(reasonKey, srcs)`; nobody gets
a cooldown), `lastPartners(src)` (900 s), distance bands (`Config.Units.nearbyBands`, server coordinates), UnitView
additions (canManage, readyCheck, avatars, levels, distanceBand, lastPartner, pendingSent, sizeFit counts only).
Actions `server:unitKick`, `server:unitPromote`, `server:unitDisband`, `server:unitCancelInvite`, `server:unitReady`;
key mapping `crimsonpolice_ready` (Config.Tablet.readyKey).

### 5.17 CP.Operations — modules/operations (Cross-Department Missions)
Server: `active() -> op|nil`, `isLocked() -> boolean`, `boardCard(src) -> card|nil`, `launch(src, missionId)`,
`startNow(src)`, `relaunch(src)`, `cancel(src, reason)`, `join(src, opId)` (`server:joinOperation`),
`onRunEnded(run, state)` *(hook)*, idle auto-cancel, launch cooldown, notifications to every on-duty
officer (`client:operation` (state, missionLabel)). Actions `server:sup:op*` and `server:admin:op*`
(§8). Callback `sup:getOperation`.

Parity-plus: `leave(src)` / `server:leaveOperation` (before the start, no penalty; `err.op_leave_started` after),
`removeJoiner(src, target, reason)` / `server:<scope>:opRemoveJoiner` (launchCrossDept, a reason, before the start,
audited `opRemoveJoiner`), the waitlist (`Config.CrossDept.waitlist`: a freed place goes to the first on it, re-checked
like a join), `officerCard(src)`.

### 5.18 CP.Scoring — modules/scoring (S)
- `P(mission) -> number` (type points × `Config.Difficulty.pointsByStars[difficulty]`; boss: `Config.Events.weeklyBoss.points`)
- `compute(run, p, result, opts) -> breakdown` (§9.6 `points`) — formula of the spec incl. cap, streak, ToD, failed credit (`objectivesDone / total`)
- `isFirstRunSinceDuty(src) -> boolean` + duty tracking (via `CP.Qbx.onDutyChange`)
- `streak(citizenid) -> { days, multiplier, graceLeft }`
- `onRowCounted(citizenid, row)` *(hook: row counts toward boards now — completed/failed and not flagged)* → XP, streak (completed only), badges
- `onRowApproved(rowId)`, `onRowVoided(rowId)` *(hooks)* — XP add/remove, badges
- `manualAward(actorSrc, citizenid, points, reason) -> ok, errKey` (a `manual_award` row, audited)
- `xpLevel(xp) -> { label, badge, xp, next }`, `badges(citizenid) -> list`

Parity-plus additions (WP1): `levelXp(n)`, `levelOf(xp)`, `xpLevel(xp) -> { n, label, badge, xp, levelXp,
nextLevelXp, prestige, next }` (Config.XPCurve; the label is the Config.XPLevels band of the level; `xp` = levelXp for
old callers), `progressFor(citizenid, gained, pending)` (pending XP never sets levelUp), badges by_the_book and
first_responder, engineOnly ids valued from Config.Bonuses (rapid_response from Config.MissionCalls.rapidResponse), one
level-up toast (`scoring.level_up`), stats and badges from completed rows only, `homeData` level and missionsToday
plus the `home:extras` hook.

### 5.19 CP.Goals — modules/goals (S)
- `forOfficer(citizenid) -> { daily = Goal, weekly = Goal }` (`Goal = { id, label, count, progress, done, points }`)
- `onRunCompleted(citizenid)` *(hook)* → inserts a `goal` row once per period when a goal completes

Parity-plus: stat goals (`stat = 'arrests'` …) sum that column over completed rows; missionCall goals count rows with a
`mission_call_id`; `goal:completed` fires after the goal row.

### 5.20 CP.Cash — modules/cash (S)
- `compute(run, p) -> amount, breakdown` (§9.6 `cash`)
- `pay(rowId)` — the claim-then-pay flow of the spec (paying → paid/capped/unfunded)
- `payPending(src)` *(hook: player loaded)* — pays `pending` rows
- `release(rowId)` (flag approved: held → pay now or pending), `forfeit(rowId)`
- `range(missionType, members) -> min, max` for board cards (modifiers and admin payouts in the pool)
- `stuckPayments() -> list` (rows still `paying`)
- `earnedThisWeek(citizenid) -> number`
- Forfeiture job (every 10 min): voided rows with `cash_status = 'held'` older than `Config.Disputes.windowHours` and no open dispute → `forfeited`

Parity-plus: `row:forfeited (rowId)` fires from `forfeit` and the forfeiture job (one UPDATE per row); `officer:loaded
(src)` fires right after the pending payments of a player who loaded in.

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

Parity-plus additions (WP6; docs/notes/boards.md):
- `getBoard` arg `metric` (Config.Leaderboard.metrics: points, missions, arrests, impounds, citations, rescues, calls,
  judgement; `err.invalid_metric` otherwise). Every stat is summed from `voided = 0 AND flagged = 0 AND state =
  'completed'` rows (all-time through the archive union); judgement = decisions_best ÷ (decisions_ok +
  decisions_bad), ranked only with Config.Leaderboard.minDecisions decisions; the cache key includes the metric.
  Rows gain `value`, `metric`, `level = { n, badge }` and `avatar`; kills (`lethal`) are never read by a board query.
- `serviceRecord(citizenid, seasonId|nil) -> ServiceStats, lethal`, `personalBests(citizenid)`,
  `favouritePartner(citizenid)`; `getProfile` gains bio, avatar, level, commendations, mdtCommendations, service
  `{ lifetime, season }`, bests, favouritePartner and (own profile only) cleanArrestRate; `profile(viewer, target,
  { staff = true })` is the admin view.
- Weekly metric badges (`Config.Leaderboard.weeklyBadges`): `top_<metric>_<weekKey>` to #1 of the week.

### 5.23 CP.Challenge — modules/challenge (S)
- `currentSeason() -> season|nil`, `startSeason(src, name)`, `endSeason(src)`
- `standings(seasonId?) -> { departments = {...} }`, `bounty(weekKey?)`, `overrideBounty(src, objective)`
- Weekly close: bounty winner once; season end: champions, badges, board webhook.
- callbacks `getChallenge`, `getDeptContributors`, `admin:getSeasons`; `championBanner(dept)`.

Parity-plus: bounties `most_arrests` and `most_calls` from counted completed rows; the Department Report's officers
gain arrests, citations, impounds, decisionsOk, decisionsBest, decisionsBad and calls; `sup:getOfficerActivity` adds
the officer's active commendations; `season:ended` fires after the season results.

### 5.24 CP.Disputes — modules/disputes (S)
- `server:dispute` ({ rowId, reason }) — own flagged/voided/failed rows within `Config.Disputes.windowHours`
- `forSupervisor(src) -> list`, `forAdmin() -> list`, `forOfficer(citizenid, goesTo?, viewerSrc?) -> list`, `handle(src, disputeId, decision, reason, awardPoints)`
- Each DisputeView carries the disputed row's debrief when it has one: `decisions` (the whole ledger, each fact with
  the time it reached the decider) and `people`; the Review Queue and Admin UI → Officers show them
- `supervisorCanAnswer(runUuid) -> boolean` — switch `Config.Permissions.supervisor.handleDisputes` on and an online supervisor of the run's departments who did not take part (on or off duty). While it is false for an open flagged/voided-run dispute, the admins are the ones told about it at filing and `admin:getOfficer` lists it on the Admin UI Officers screen (Approve / Reject)

### 5.25 CP.Admin — modules/admin (S)
- `/CrimsonPoliceAdmin` (`Config.Tablet.adminCommand`) and every subcommand of the spec (console too):
  `payout type <type> <amount|clear> <reason>`, `payout mission <id> <amount|clear> <reason>`,
  `award <citizenid> <points> <reason>`, `season start <name>` / `season end`,
  `suspend <citizenid> <days>`, `reload`, `test <missionId> [tier] [location]`. No args → `CP.Tablet.openAdmin(src)`.
  Also `storage` (the storage in use, rows per `cp_` table, the saves folder's size) and
  `storage copy database-to-files|files-to-database [force]` (§5.29); console or an admin (`CP.Access.isAdmin`) only.
  `check` runs `CP.ConfigHealth.run()` again: every line in the console (coloured by level) and the counts, in game only
  the counts (a toast: error, warning or success).
- A player who is not an admin and types the command gets `err.not_admin` and, once per player per start, one console
  warning naming them and the line that makes them one: `add_ace identifier.<fivem:… or license:…> <adminAce> allow`.
- `webhooks() -> { { category, convar, state = 'on'|'off'|'invalid' } }` in the order audit, flags, board, builder,
  operations (Config health lists them; `invalid` = not an https:// link, that webhook is off).
- `audit(actor, role, category, action, target, old, new, reason)` — `actor` = src or citizenid or 'console';
  writes `cp_audit` and posts to the category webhook (`cp_webhook_audit|flags|builder|operations`, convars)
- `webhook(category, title, description, fields)` (category 'board' also allowed)
- `voidRun(src, rowIdOrRunUuid, reason)`, `approveFlagged(src, rowId, reason)`, `voidFlagged(src, rowId, reason)`
- Supervisor/admin screen callbacks and actions listed in §8.3. `admin:getMissions` adds `switch`
  (`CP.Settings.missionView(def)`: the mission's and each location's on/off and config.lua's values).

Parity-plus: `registerSubcommand(name, fn, helpKey)` with `fn(src, args) -> ok, messageKey, vars` (the reply is sent
for it; helpKey is the console usage line; a built-in name can't be taken) — other modules add
`/CrimsonPoliceAdmin` subcommands (CP.MissionCalls: `missioncall <type> [area]`). The storage command lists every
cp_ table, the four new ones included.

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
`startDraft(src, def, { tier, location, useStartRoute }) -> ok, errKey` (Mission Builder test of an unpublished draft: `test.draft = true`; at the end the tester records Passed/Failed and the result goes to `CP.Builder.onDraftTested(missionId, version, tierName, passed, src, defHash)`, defHash = the tested definition's).
Client: test-control panel focus key (RegisterKeyMapping `+crimsonpolice_testpanel`, default F7: sc-multijob binds F9;
silent unless this player controls a test or has an invitation waiting), debug overlay drawing.

### 5.28 CP.Builder — modules/builder
Server: drafts, locks, autosave, test runs of drafts (via `CP.Testing`/`CP.Runs` with `test.draft = true`),
publish (Lua export with `SaveResourceFile`), archive/restore, rollback (.bak), reload of hand edits,
`loadPublished() -> { def, ... }` *(hook for CP.Missions.loadAll)*, `onReload()`,
`onDraftTested(missionId, version, tierName, passed, src, defHash)` *(hook from CP.Testing; a pass counts only for the draft content with that defHash)*. Testing is optional: a passed test at the tier `CP.Scaling.tierFor(maxOfficers)` (`draft_tested = 1`) is needed to publish only while `Config.Builder.requireTestToPublish` is true, and only for supervisors (never admins). List entries carry `needsTest`, `builder:config` carries `requireTestToPublish` (for the viewer), and an untested publish is audited as `publishUntested`.
Client: placement tool, route recording, test drive; overlays through `CP.Tablet.overlay`.

### 5.29 CP.Storage (with CP.Storage.MemSQL) — modules/storage (S)
Where Crimson-Police keeps its data (`Config.Database`). `enabled = true` (the default): MySQL/MariaDB through
oxmysql, exactly as before, tables built by the migrations runner, no SQL import. `enabled = false` ("database
off"): Crimson-Police never sends a query to oxmysql for its own data; every `cp_` table lives in the saves folder
(`Config.Database.folder`, default `saves` inside the resource; FXServer's file sandbox only lets a resource write
inside resource folders, so an absolute path must point inside the resource). The mode is called `'files'` in code
and "the saves folder" in player- and owner-facing text (`CP.Storage.name()` gives `'database'` or `'saves folder'`
for console lines). FiveM resource KVP is never used. The module's one global table is `CP.Storage`; the engine's
code is `CP.Storage.MemSQL` (memsql.lua creates `CP.Storage` and puts it there).

- **Load order.** fxmanifest loads `@oxmysql/lib/MySQL.lua`, then `modules/storage/memsql.lua` (it only defines
  `CP.Storage.MemSQL`), then `modules/storage/server.lua` (`CP.Storage`), before every other server module. In files mode
  `server.lua` opens the saves folder and replaces this resource's `MySQL` global with the shim at file load (the
  one exception to ground rule 5, so no module ever holds the wrong `MySQL`). The `modules/**/server.lua` glob
  loads `server.lua` a second time; that load returns at once. The migrations runner then builds the same tables
  in the engine (only the migrations the saves folder has not recorded yet) and prints `storage: ...`.
- **CP.Storage** (server): `mode() -> 'database'|'files'`, `name() -> 'database'|'saves folder'`,
  `folder() -> full path|nil` (files mode), `describe() -> text` (the runner's start-up line), `loadError() ->
  text|nil` (a saves folder that could not be created, written or read: every statement then fails with that
  text and nothing in the folder is changed; for a folder outside the resource it names FXServer's sandbox),
  `hasSavedData() -> bool` (the configured folder holds saves), `realMySQL` (oxmysql's `MySQL`, files mode), `db`
  (the engine, files mode), `MemSQL` (the engine's code). A new saves folder is announced on start, once oxmysql is
  connected (`realMySQL.ready`): when the real database holds Crimson-Police data (`cp_schema_migrations` has rows, or
  the database cannot tell) the warning names the storage copy command; when it has none (a first install with the
  database off) one plain line says the folder was created. A new database next to a saves folder with data is
  announced by the migrations runner, naming the storage copy command.
- **The migrations runner** (`modules/migrations`, `CP.Migrations.ready() / isReady() / version()`): a failed statement
  stops the resource with the file, the statement and the driver's error, then one `How to fix it:` line for the usual
  first-start errors (no CREATE/ALTER right, a wrong password, no rights on the database, an unknown database, a server
  or host that cannot be reached). When oxmysql has not connected 30 s after start (it waits without a word) one
  warning names `set mysql_connection_string` and `Config.Database.enabled = false` (database mode only: the saves
  folder never waits for oxmysql).
- **CP.Storage.MemSQL** (server; it also runs under plain lua5.4 in the tests, with the global `json`):
  `new({ store }) -> db`; `db:exec(sql, params) -> { kind = 'rows', cols, types, rows, n } | { kind = 'write',
  affected, changed, insertId, info, warnings }`, synchronous and atomic (a failing statement changes nothing),
  and saved before it returns (every changed document written as `.tmp` first, then renamed into place in a
  crash-safe order; a save that fails part way is undone in memory and in the folder); with `db.slice` (set by
  CP.Storage on a server: `{ wait = Citizen.Wait, ms = 4 }`) a SELECT run from a thread gives the server its turn
  every 4 ms, and every other statement waits for it; `db:load()`; `db:bulk(fn)` (the write-through paused, every document saved once at
  the end: bulk imports and the storage copy); `db:tableNames()`; `folderStore(dir)` (the saves folder: its file
  layout and crash-safe save sequence are in the header of memsql.lua); `luaRows(res)` (engine rows typed like
  oxmysql).
- **The shim**, `CP.Storage.MemSQL.shim(db, { realMySQL, resource }) -> MySQL`: `query`, `single`, `scalar`, `insert` and
  `update` (each callable with a callback, and with `.await`), plus `ready`. It copies oxmysql's return shapes,
  typing (TINYINT(1) as booleans, DECIMAL and SUM as strings, DATETIME/DATE as milliseconds, text always as
  strings, UPDATE counting matched rows), error text and parameter checks. Any other key (`prepare`,
  `transaction`, ...) raises. It routes by the tables a statement names: only `cp_` tables go to the engine; only
  other resources' tables (today sc-dispatch's `mdt_dispatch`, Hard rule 15) go read-only to `realMySQL` (nil,
  and one warning, when oxmysql is not started); a statement mixing both, or writing another resource's table,
  is an error.
- **Supported SQL** (the full list is the header of memsql.lua; anything else fails with "the saves folder
  engine (files mode) does not support ..."):
  - SELECT [DISTINCT] with aliases or `*`, FROM a table, a derived table or DUAL, [INNER] JOIN and LEFT
    [OUTER] JOIN ... ON, WHERE, GROUP BY, ORDER BY, LIMIT/OFFSET (numbers or `?`), UNION ALL in derived tables.
  - INSERT [IGNORE] ... VALUES (one or more rows) or SELECT, ON DUPLICATE KEY UPDATE with `VALUES(c)`; UPDATE
    [IGNORE] with an alias; DELETE FROM t [WHERE] and DELETE a FROM t a [INNER|LEFT] JOIN ....
  - CREATE TABLE [IF NOT EXISTS] (PRIMARY KEY, UNIQUE, KEY/INDEX) or LIKE; ALTER TABLE ADD [COLUMN] [IF NOT
    EXISTS] ... [FIRST|AFTER c], ADD [UNIQUE] INDEX/KEY [IF NOT EXISTS], several ADDs in one ALTER; CREATE [UNIQUE]
    INDEX [IF NOT EXISTS] ... ON t; types INT,
    TINYINT, SMALLINT, MEDIUMINT, BIGINT, VARCHAR(n), DECIMAL(p,s), DATETIME, DATE, ENUM, JSON.
  - `+ - *`, comparisons, AND/OR/NOT, IS [NOT] NULL, [NOT] IN (list or subquery), [NOT] EXISTS, scalar and
    correlated subqueries, [NOT] LIKE, CASE, `± INTERVAL n SECOND|MINUTE|HOUR`; COUNT SUM MAX MIN GROUP_CONCAT;
    COALESCE IFNULL NULLIF IF GREATEST LEAST ROUND, DATE DATE_FORMAT UNIX_TIMESTAMP FROM_UNIXTIME NOW
    CURRENT_TIMESTAMP TIMESTAMPDIFF, SUBSTRING_INDEX CHAR_LENGTH LOWER UUID, JSON_SET JSON_REMOVE JSON_EXTRACT
    JSON_UNQUOTE JSON_VALUE JSON_VALID JSON_CONTAINS JSON_TYPE.
  - MariaDB semantics: utf8mb4_general_ci comparison with MariaDB's own weight and LOWER() tables for every BMP
    character (`tools/gen_collation.py`) and PAD SPACE order, NULL logic, strict mode with its errors and
    warnings, BIGINT overflow as MariaDB's error 1690, NULLs first when ascending, MariaDB's error messages.
    NOW(), DATE() and UNIX_TIMESTAMP follow the FXServer's local time zone; a DATE is saved as its calendar day.
    A comparison of two parameters or literals uses utf8mb4_general_ci (the connection collation with
    `charset=utf8mb4`; a connection string without a charset makes MariaDB use utf8mb4_unicode_ci there).
  - Not supported (unused today): comma, RIGHT and CROSS joins, HAVING, BETWEEN, WITH, window functions, UNION
    without ALL, AVG and DISTINCT inside an aggregate, `/ % DIV MOD REGEXP`, other INTERVAL units, TEXT, CHAR and
    TIMESTAMP columns, fractional seconds, ALTER forms other than ADD, RENAME/DROP/SET/SHOW, Lua table
    parameters, `MySQL.prepare`, transactions. A migration that adds a NOT NULL DATETIME or DATE column to a
    table with rows needs a DEFAULT.
- **Rule for new SQL.** Modules never test the mode: every statement is written once and must run in both. A
  new or changed statement must use only the constructs above, or the change must extend the engine with
  MariaDB's exact behaviour. The whole suite must then pass in all three storage modes, and
  `lua5.4 tests/run.lua --storage=shadow` must report 0 differences (plus `--fuzz` after an engine change;
  §11). A statement on another resource's table may only read, and never together with a `cp_` table.
- **Storage copy** (CP.Admin, `/CrimsonPoliceAdmin storage copy database-to-files|files-to-database [force]`,
  console or the admin ace). It copies every `cp_` table except `cp_schema_migrations` between MariaDB and a
  saves folder engine. The MariaDB side is the real oxmysql (`MySQL` in database mode, `CP.Storage.realMySQL` in
  files mode). The files side is `CP.Storage.db` in files mode, or else an engine opened on
  `Config.Database.folder` for the command. The copy:
  - first runs on the target the migrations the source has (the same `sql/migrations` files);
  - keeps ids and AUTO_INCREMENT counters, and writes into an engine inside one `db:bulk`;
  - into the storage in use (the server keeps writing meanwhile), raises its counters to the source's before the
    first row and writes every row with `ON DUPLICATE KEY UPDATE`, so a row the server wrote first is replaced by
    the copied one instead of failing the copy;
  - reads DATETIME with `UNIX_TIMESTAMP` and writes it with `FROM_UNIXTIME`, and moves DATE as `YYYY-MM-DD`;
  - is refused while a run or a Cross-Department Mission is active, and into a target with rows unless `force`
    (which empties it first);
  - empties the target again on any failure (the source is only read);
  - is audited as `storageCopy`, also in the target's `cp_audit` when the target is not the storage in use.
  `/CrimsonPoliceAdmin storage` prints the mode, the saves folder path, the rows of every table and the
  folder's size.
- Tests: `tests/memsql_spec.lua` (the engine: MariaDB's answers, the collation table checked against the local
  MariaDB, a crash and a refused file operation at every point of a save, FXServer's inverted `os.rename`, hand-edited
  and missing documents, the SELECT slicing), `tests/storage_spec.lua` (files mode end to end, a restart, and
  50,000 runs with their timings, an fsync per document written, how long a board holds the server thread, and
  sizes), `tests/storage_copy_spec.lua` (the storage command and both copy
  directions in both modes, MariaDB and a temporary saves folder together). `lua5.4 tests/run.lua --storage=files`
  runs the whole suite in files mode, and `--storage=shadow` checks the engine against MariaDB statement by
  statement (§11).

---

### 5.30 CP.Custody — modules/custody (police actions, contacts, custody chain; WP2)
Truths, demeanours and cues live only in this module's book per run (never in run.entities, a bag, an event or a
push). Full notes: docs/notes/custody.md.
- `rollTruth(rng, setName, role)`, `rollDemeanour(rng, truthKey)`, `rollProfile(rng, setName, role, hasCar, truth?)`
  → `{ truth, demeanour, cues }` (Config.Custody.profileSets, demeanour, cues; deterministic per seed).
- `register(run, obj, netId, contact) -> contact` (the bag gets only `contact = { label, kind, actions }` and the
  state), `get(run, netId)`, `contactsOf(run, obj|nil)` (sorted by net id).
- `act(run, netId, behaviour, args)` — the only truth-derived signal to a client: `client:contactAct` to the run host
  when the behaviour starts (walk_away, flee_on_approach, flee_on_order, tell_then_draw (a tell first, then
  `CP.Runs.arm`), leave, exit_and_stand, walk_to, drive_off); once per behaviour per contact.
- `begin(src, runId, netId, action, extra)` / `finish(...)` — every action: live run, active arrived participant, on
  duty, not in the arena, the owning objective current, the action allowed, state order, reach at both ends
  (server coordinates), finish ≥ Config.Custody.times[action] − actionSlack, and for actions of 3 s or more the
  dwell sampler. A cancelled bar sends no finish.
- `reveal(run, netId, factKey, src, data)` (sentTo = active participants now; data.suppressed = inadmissible),
  `knownTo(run, factKey, netId, src) -> ms|nil`, `probableCause(run, vehNetId) -> bool, sources` (plain_view, odour,
  admission, weapon, arrest, stolen, consent).
- `grade(run, netId, choice, src, beginMs) -> entry, failFact` (pure: the Dispositions table with the mission's
  `decisions` overrides and Config.Decisions; Best only with the deciding fact admissible; points 0 for a caught
  runner or a `revealed` deciding fact).
- `enableChain(run, netId, opts)` (searchPerson, escort, seat, handover for any block's cuffed suspect),
  `requestTransport(run, coords, { obj, point })`, `transport(run, src)`, `impound(run, netId, src)` (tow truck, or a
  fade with Config.Custody.tow.enabled = false), `serviceVehicle(run, kind, coords, opts)`, `checkRoadPoint(run,
  handle, reply)`, `releaseService`, `serviceStatus`, `_servicesOf(run)` (tests).
- Service vehicles: the driving client is the nearest active participant outside the arena (else the host); it is
  asked for a road point 150–250 m away (`client:roadPoint`), the server checks it (within spawnDistance, 30 m
  from every player) and retries every 3 s; the AI moves on leave, down, arena or beyond serviceHandoff. A vehicle
  has arrived when below 1.5 m/s within 15 m of a placed parking point (a transport, coroner or tow point), or,
  for the prisoner van with no transport point, anywhere within Config.Custody.transport.parkWithin of the scene;
  after serviceTimeout a van is placed at its parking point and a tow that did not load fades the car (impounded).
- People debrief: `register` notes each person (label, demeanour) through CP.Runs.notePerson, and the behaviours
  (walked_away, ran, drew), cuffs, escapes and deaths as they happen; `grade` adds the factLog (every fact the
  decider had, as text, with when it reached them).
- `onCuffed`, `markGone`, `markDead`, `closeObjective(run, obj) -> n` (undecided contacts: missed_offence −5, never a
  fail), `noteForce(run, netId, src)`, `view(run, obj, src) -> ContactView|nil` (web/src/types/custody.ts; choices'
  failsCase only from facts that reached this viewer), `giveEvidence(run)` (Config.Custody.evidenceItem, off).
- Net: plain `server:custody` (runId, netId, action, phase, extra; 4 per 2 s), action `server:contactDecide`
  (`{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }`; within 25 m), plain
  `server:stunHit` (netId; 2 per s), `client:contactAct`, `client:contactConfirm`, `client:serviceVehicle`, the
  ox_lib callback `client:roadPoint`, client action `contactAction` (`{ netId, action }`), push `contactConfirm`,
  HUD patch `contact` (`{ label, fact, hint, confirm, suppressed }`).
- Blocks: `blocks/field_contact` (modes parked, scene, stop; returning driver, thief, escapes, all_correct,
  procedure_complete, a 'removed' car never becomes an Impound) and `blocks/process_scene` (holds bodies, pauses the
  fast clock, coroner van, all_taken_alive with no bodies). ox_target names `crimson-police:body_tag`,
  `crimson-police:body_bag`, `crimson-police:coroner`.

### 5.31 CP.MissionCalls — modules/missioncalls (Dispatch; WP4)
Full notes: docs/notes/missioncalls.md.
- Locations turned off (§5.36) count in no area.
- `list(src) -> DispatchView` (only for officers with the tablet open: callback `getMissionCalls` and the `calls`
  push to watchers), `eligibility(src) -> { at, unit, types }` (cached per unit for
  Config.MissionCalls.eligibilityCache s; cleared on row:settled, participant:left and duty changes; no database
  query per call or per viewer), `areaFor(src, call) -> areaKey|nil`, `claim(src, callId) -> ok, { runId } |
  { pending } | errKey`, `withdraw(src, id, reason)`, `page(src, typeKey, area, leaderSrc)`, `create(src, typeKey,
  area)`, `claimableCount(src)`, `areaOf(coords)`, `areaIndex()`, `stats(citizenid) -> { answered, avgResponse,
  rapid }`, `supView(src) -> SupCallsView`.
- The claim: every accept check (CP.Draw.check), then the call's rules (excluded citizenids, the issuer's unit,
  paged, priority window, a pool in the area); valid claims within `claimWindowMs` are ranked by the nearest
  member's distance to the area centre, then fewer calls won in the last hour, then the earliest; the row moves
  open → claimed with `UPDATE ... WHERE id = ? AND status = 'open'` before the accept; a declined ready check puts it
  back with the offer time it had left and tries the next claimant; losers get `err.mc_taken_by`.
- Hooks: run:arrived, run:ended (close with the outcome, or re-dispatch once when nobody arrived and the end reason
  is quit, off_route, start_timeout, idle, real_call or force_recall), row:settled and participant:left (cache),
  home:extras (callsOpen). `CP.Schedule.onDaily` deletes history older than Config.Retention.missionCallDays.
- Net: callbacks `getMissionCalls`, `sup:getMissionCalls`, `admin:getAreaCoverage`; actions
  `server:claimMissionCall`, `server:sup:mcWithdraw|mcPage|mcCreate` and `server:admin:*`; plain `server:mcWatch`;
  `client:missionCall` (toast and tone, only to idle units that could claim and have not muted calls); push `calls`.
  Nothing is ever sent to SC-Dispatch.

### 5.32 CP.Profile — modules/profile (pictures, bio, look, commendations, moderation; WP6)
Full notes: docs/notes/profile.md. English only: a profile has no language (no column, pref or picker).
- `avatarOf(row, { own })`, `avatarFor(citizenid, viewerSrc|nil) -> Avatar` (a hidden name shows the callsign's
  initials, never the picture, unless own), `prefsFor(citizenid) -> Prefs`, `commendations(citizenid, { staff,
  viewer })`, `newCommendations(citizenid)`, `report(src, citizenid, reason, note)`, `validateBio(text)`,
  `validateUrl(url)`, `set(officer, payload)`, `editView(officer)`, `queue(dept|nil)`, `adminView(citizenid)`.
- Net: callback `getProfileEdit`; actions `server:profile:set` (`{ bio?, avatar? = { kind, value }, appearance?,
  accent?, uiScale?, callsMuted? }`), `server:profile:report`,
  `server:sup|admin:reviewAvatar`, `clearProfile`, `handleReport`, `commend`, `revokeCommendation`; callbacks
  `sup:getProfileQueue`, `admin:getOfficerProfile`; push `profile` to the officer after every change. Commendations
  are zero-points: only cp_commendations and the audit row are written.

### 5.33 CP.Rewards — modules/rewards (optional item rewards; WP7)
Full notes: docs/notes/rewards.md. Off by default (`Config.Rewards.enabled = false`): no listener writes a row and
nothing calls ox_inventory.
- `lockerCount(citizenid)`, `forRow(rowId)`, `deliver(citizenid)`, `locker(src) -> RewardsLocker`, `claim(src, id)`,
  `adminView(page)`, `validate()`, `forbidden(name)`, `health()` (registered with CP.ConfigHealth), `entryFor(missionId,
  type)`, `chanceFor(entry, tier, evidence)`, `roll(runId, citizenid, entry, chance)` (seed of run id and citizenid).
- Status flow held → pending → giving → given, forfeited; claim before give (`UPDATE ... SET status = 'giving' WHERE
  id = ? AND status = 'pending'`), then CanCarryItem, then `AddItem(src, item, count, { cpReward = <row id> })`
  (never cpItem). In Crimson-Arena or offline the reward waits in the locker; retried on officer:loaded and 10 s after
  arena:exited. A row left `giving` is listed for admins.
- Listens to row:settled, row:approved, row:voided, row:forfeited, goal:completed, xp:levelUp, season:ended,
  officer:loaded, arena:exited, home:extras. Net: callback `getRewardsLocker`, action `server:rewards:claim`
  (`{ id }`), callback `admin:getRewards` (`{ page }`), push `rewards`.

### 5.34 CP.ConfigHealth — modules/confighealth (WP8)
`register(name, fn -> { { level = 'ok'|'warn'|'error', text } })` (a second register replaces it), `run() ->
ConfigHealthItem[]` (errors first; a failing check is one error line). Runs 5 s after start (only that first run
prints to the console, one line per problem, then one summary line: plain when every check passed, a warning with the
counts otherwise, naming `/CrimsonPoliceAdmin check`) and on callback `admin:getConfigHealth` (admins) and the `check`
subcommand (§5.25). Built-in checks: items (the item, its way, and its picture in `ox_inventory/web/images/<item>.png`
while `inventory:imagepath` is ox_inventory's default), desks, colours and personal accents, tweaks, locale (en.json
loads; a Config.Locale other than en warns: English only), avatars, departments (every job a department lists is a
Qbox job from `CP.Qbx.getJobs()`, a missing one saying whether the department's other jobs still let players in; its
grade ladder; warns when supervisorGrade is above every grade or is the lowest grade; an empty job list or a
supervisorGrade that is not a number stay CP.Access's own warnings), admins (`IsPrincipalAceAllowed('group.admin',
adminAce())`, or the Qbox ace while QboxAdmins is on; warns with the exact `add_ace` line), folder (when `CP.resource`
is not `Crimson-Police`: a warning while `Config.Tablet.item` is set, because the ox_inventory item line names the
folder, else an ok line; both name the item line and other scripts' `exports['<name>']`), resources (sc-police not
running warns: no /callsign, and sc-dispatch suspensions do not keep officers off duty; sc-npcpolice, sc-multijob,
Crimson-Arena are info lines), webhooks (`CP.Admin.webhooks()`: which are on, and a warning per invalid convar);
CP.Rewards registers its own, and CP.Settings registers `settings` (how many settings are changed in game, each saved
value that is ignored, and the changes waiting for a restart).

### 5.35 CP.Diag — modules/diag (client; the freeze fix)
F8 command `CrimsonPoliceState`: four `[crimson-police:diag]` lines with the screen fade, NUI focus (and keep input),
scripted camera, pause menu, player control, frozen, dead, last stand and dead metadata, in a vehicle, then what
Crimson-Police holds (tablet, panel focus, pick-up, run) and which of the rest is not ours.
`CrimsonPoliceState unstick` first closes our tablet, releases our panel focus and runs `CP.Downed.restore`, never
anything another resource holds. `state() -> table`, `unstick()`.

### 5.36 CP.Settings — modules/settings (settings changed in game)
Server:
- The schema is built from the files at the first use: `config/config.lua` and `config/blocks.lua` are read with
  `LoadResourceFile` and tokenized; every key's description is the comment lines right above it plus the comment after
  it on its line (and a comment continued under it at the same column); commented-out entries are never text; the
  banner above a `Config.X` line names its section (blocks.lua is one section). A setting is a leaf of the config.lua
  values (copied at file load, before anything changes Config): a scalar, a vector, a list, an empty table, or one of
  the open tables edited whole (`MissionTweaks`, `DisabledLocations`, `Rewards.byType|byMission|medals|goals|levels|season`,
  `Blocks.pursuit.responses`, `Blocks.flee_arrest.responses`); keys config.lua writes as nil (`dailyLimit = nil`) are
  settings too.
- Checking (`check(path, value, none) -> ok, clean | false, errKey`): the shape of the config.lua value (whole numbers
  stay whole, decimals become floats, signs kept), known ranges, the blocks.lua `{ min, max, default }` triples,
  options (also a Blocks `default` against its `options`), templates for what config.lua alone cannot say (`false` or an
  item name, desks, tweaks), ordered pairs (`CrossDept.min/maxParticipants`, `Cash.min/maxPayout`), and the export folder
  stays in `missions/custom/`. Locked (config.lua only, `err.setting_locked`): `Config.Database.*` (where the settings
  live) and `AdminAce`/`QboxAdmins` (who is an admin).
- Storage: `cp_settings` (007): `setting_key`, `value_json` (`{"v": value}` or `{"none": true}`), `updated_by`,
  `updated_at`. `boot()` is called by the migrations runner before it reports ready (and by the module's own thread when
  a runner did not): every row is checked again; a bad one is ignored with one warning and listed as invalid.
- Applying: every top-level Config table a setting touches (now or before) is rebuilt from the config.lua copy, then the
  applied settings are set on it. Restart settings (`Tablet.command|adminCommand|keybind|dispatchKey|readyKey|contactKey|
  desks`, `Locale`, `Time.resetHour`, `Leaderboard.weekStartsOn`) apply only at boot; a later change is saved and
  reported as pending. A change under what the mission loader reads queues one `CP.Missions.reload()` (1 s debounce).
- `set(src, path, value, none, opts) -> ok, SettingsReply | errKey` (a value equal to config.lua's is a reset; audit
  `settingChanged` / `settingReset`, old → new), `reset(src, path)`, `resetAll(src)` (`settingsResetAll`), `entry(path)`,
  `view(path) -> SettingView`, `all() -> SettingsView`, `isLoaded()`, `waitLoaded(ms)`, `missionView(def)`,
  `setMissionEnabled(src, id, on)` (`missionSwitch`), `setLocationEnabled(src, id, index, on)` (`locationSwitch`; the
  label when it is unique in the mission, else the number), `resetMission(src, id)` (`missionSwitchesReset`). After every
  change: `client:settings` to every client, the `settings` push to online admins, the hook `settings:changed (paths)`,
  and `CP.ConfigHealth.run()` in the reply.
- Net: callbacks `admin:getSettings`, `admin:getSettingsHistory` (`{ page, path? }`: the audit rows of the actions above);
  actions `server:admin:setSetting` (`{ path, value? | json?, none? }`), `server:admin:resetSetting` (`{ path }`),
  `server:admin:resetAllSettings`, `server:admin:setMissionEnabled` (`{ missionId, enabled }`),
  `server:admin:setLocationEnabled` (`{ missionId, index, enabled }`), `server:admin:resetMissionSwitches`
  (`{ missionId }`); plain event `server:settingsHello`. Every action needs `openAdmin`. The resource never restarts
  itself: restart settings wait for the owner's restart.
Client: the config.lua copy at file load; `client:settings` (`{ { path, value } | { path, none = true } }`) rebuilds the
same tables the same way; `ready(ms) -> bool`, `received()`; a `server:settingsHello` at start. The tablet's command,
key mappings and desks, the contact key and the ready key wait for the first list (10 s at most). On the server,
`/CrimsonPoliceAdmin` is registered and CP.Schedule records its first period after `waitLoaded` (15 s at most), and
`CP.Missions.loadAll` waits for `CP.Migrations.ready()`.

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
Only the server changes `state` (via `CP.Npc.setState`), and the server never reads the bag back: its record per net
id (`run.entities[netId].bag`, kept by CP.Npc) is the truth, so a client that rewrites the bag of an entity it owns
changes nothing on the server. Client requests are evidence events
(`{ type = 'cuffed', netId }`, `{ type = 'surrender_check', netId }`, `{ type = 'freed', netId }` …)
that the owning block validates with server-side distances and states.
Killing a `surrendered`, `cuffed`, `restrained` or unarmed suspect/fugitive/inmate/hostage fails the
mission for everyone (`ctx.fail('run.fail_killed_unarmed')`).
Parity-plus states: `contacted`, `escorted`, `seated`, `released`, `handed_over`, `impounded` (§5.11). A contact's
bag carries only `contact = { label, kind, actions }` besides the state: never its truth, demeanour, cues or a
weapon until the behaviour starts (the leak spec in tests/field_contact_spec.lua checks every write).

### 6.3 Telemetry (client → `server:telemetry`)
Sent only during a run by modules/runs/client.lua; the server rate-limits and caps counts.
- `vehicle` `{ netId }` every 5 s while the player drives: the server reads that vehicle's
  `GetVehicleBodyHealth` / `GetVehicleEngineHealth` and stores the lowest values in `p.vehicle`.
- `ped_hit` `{ netId }` — a non-mission, non-player ped damaged by the player's vehicle
  (`CEventNetworkEntityDamage` via `gameEventTriggered`); server checks it is not a run entity.
- `lights_siren` — once per run, missions with `quietPatrol = true` only (`IsVehicleSirenOn`), counted after the
  run is In progress (the drive to the start never costs anything).
- `stun_hit` `{ netId }` — a taser or melee hit seen through CEventNetworkEntityDamage (the plain event
  `server:stunHit`); accepted only when CP.Npc saw a ragdoll or state change of that ped within 1 s.
- `weapon_fired` — once per run when `IsPedShooting(PlayerPedId())` (for `no_weapons_fired`).
Shots at surrendered NPCs are detected server-side (`weaponDamageEvent`, §5.11).

### 6.4 Scoring details (modules/scoring implements; others rely on these meanings)
- `P = CP.Scoring.P(mission)`; common fast bonus (`+fastBonus × P` when `duration <= fastShare × timeLimit`)
  is skipped when `run.flags.medals` is true (EVOC Course, Pursuit Sim set it in `prepare`).
- No-damage bonus: `p.vehicle.seen` and lowest engine and body both above `noDamageAbove`.
  Heavy damage: lowest body below `heavyDamageBelow`, not when `mission.vehiclePenalties == false`.
- Lights & siren penalty only for missions with `quietPatrol = true` (Beat Patrol, Business Check, Illegal
  Parking Patrol), after the run is In progress.
- Decisions: the grade ids (correct_disposition, wrongful_arrest, missed_arrest, ...) are personal to the decider;
  a 'critical' grade fails the case for everyone. rapid_response (+10% of P) is personal and inside the 2P cap.
- Stats (arrests, citations, impounds, ...) and XP levels: see §4 and §5.18; only completed rows are summed.
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
  hud = function(patch) end,           -- HUD patch (e.g. { detail = 'Wave 2 of 3' }); CP.Lt tokens accepted
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
  adopt   = function(ctx, netId, from) end,  -- (optional) an entity moved to this objective (CP.Runs.adopt)
  release = function(ctx, netId) end,        -- (optional) an entity this objective owned moved away
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
| `client:start` | runId, data `{ missionId, mission, locationIndex, location, start = { coords, radius }, expectedTier, seed, host, test, modifier, participants, startRoute = bool, startTimeout, isBoss }` (seed = a client seed, the same for every participant and unrelated to `run.seed`, so no client can replay the server's rolls) | runs |
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
| `client:pickupCancel` | runId (the server cancelled a pick-up it had already sent; the client fades back in and never teleports) | downed |
| `client:downedEnded` | runId, reason (`client done`, `timeout`, `recovered`, `in_arena`, `ems`, `unload`, …: the follow-up is over; a pick-up still running stops, and whatever of it is still on screen is undone) | downed |
| `client:operation` | state (`launched`|`started`|`ended`|`cancelled`), missionLabel | operations |
| `client:missions` | list of definitions | missions |
| `client:notify` | `{ kind, key, vars, title, duration }` | tablet (server helper) |
| `client:push` | topic, data | tablet (server helper) |
| `client:openAdmin` | session | tablet |
| `client:actionResult` | reqId, ok, data | shared/net |
| `client:testInvite` | `{ inviteId, missionLabel, from }` | testing |
| `client:test` | `{ controls = bool, debug = data }` | testing |
| `client:builder` | `{ ... }` builder-specific | builder |
| `client:objective` (new action) | runId, index, `{ action = 'adopt', op = 'adopt', netId, obj, from }`: the host moves the AI of netId to objective obj's client half | runs |
| `client:missionCall` | `{ id, code, typeLabel, priority, areaLabel, paged? }` (toast and tone; the client drops it when muted, on a run or in the arena) | missioncalls |
| `client:readyCheck` | `{ typeKey, typeLabel, expiresIn, leaderName }` or nil to clear | units |
| `client:contactAct` | `{ runId, netId, behaviour, args, seconds }` to the run host only, when the behaviour starts | custody |
| `client:contactConfirm` | `{ netId, choice, factKey }`: open the tablet with the case-fail confirm | custody |
| `client:serviceVehicle` | `{ runId, id, op = 'drive'|'load'|'leave', kind, veh, driver, dest, target, away }` to the driving client | custody |
| `client:closeTablet` | errKey (requireItem: the item left the inventory) | tablet |
| `client:settings` | `{ { path, value } \| { path, none = true } }`: every setting changed in game that is in use | settings |

Server → client ox_lib callback: `crimson-police:client:roadPoint` `{ near, min, max }` → `{ coords, heading }` or nil (the service-vehicle driver's client; the server validates the reply; custody).

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
| `server:custody` | runId, netId, action, phase ('begin'\|'finish'), extra (`{ offence }`, `{ door }`) (plain event, no reqId; 4 per 2 s) | custody |
| `server:stunHit` | netId (plain event, no reqId; 2 per s) | custody |
| `server:tabletItemGone` | — (plain event; 2 per s) | tablet |
| `server:mcWatch` | false = the tablet closed (plain event) | missioncalls |
| `server:claimMissionCall` | `{ callId }` → `{ runId }` or `{ pending }` | missioncalls |
| `server:contactDecide` | `{ runId, netId, choice, offence?, confirmed? }` → `{ ok }` or `{ confirm = { factKey } }` | custody |
| `server:profile:set` / `server:profile:report` | see §5.32 | profile |
| `server:rewards:claim` | `{ id }` | rewards |
| `server:unitKick` / `server:unitPromote` / `server:unitCancelInvite` | `{ targetSrc }` | units |
| `server:unitDisband` | — | units |
| `server:unitReady` | `{ accepted }` (a bare boolean from the key mapping) | units |
| `server:leaveOperation` | — | operations |
| `server:settingsHello` | — (plain event, 2 per 10 s; the reply waits until the settings are loaded) | settings |

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
`builder:config`, `test:pendingInvites`, `test:state` (testRun or builderEdit), `test:candidates` (testRun).
Parity-plus: `getMissionCalls`, `getNavCounts`, `getProfileEdit`, `getRewardsLocker`, `sup:getMissionCalls`,
`sup:getProfileQueue`, `admin:getRewards` (`{ page }`), `admin:getAreaCoverage`, `admin:getLocationStats`
(`{ missionId }`), `admin:getOfficerProfile` (`{ citizenid }`), `admin:getConfigHealth`, `admin:getTabletAccess`,
`admin:getSettings`, `admin:getSettingsHistory` (`{ page, path? }`);
`getBoard` gains `metric`, `getSession` gains `via` and `desk`.

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
| `server:admin:recordTest` | `{ key?, missionId, location, tier, result, note }` (key = the pending entry's run id) | testRun | testing |
| `server:test:record` | alias of `server:admin:recordTest` (same payload) | testRun (a draft: builderEdit or testRun) | testing |
| `server:test:invite` | `{ missionId, targets = { src } }` | testRun | testing |
| `server:test:cancelInvites` | — | testRun | testing |
| `server:test:control` | `{ control, ... }` | test starter only | testing |
| `server:builder:*` | see builder section of its own module header | builderEdit/Publish/Archive/EditAny/Rollback/breakEditLock | builder |
| `server:sup:mcWithdraw` / `server:admin:mcWithdraw` | `{ callId, reason }` | missionCalls | missioncalls |
| `server:sup:mcPage` / `server:admin:mcPage` | `{ type, area, leaderSrc }` | missionCalls | missioncalls |
| `server:sup:mcCreate` / `server:admin:mcCreate` | `{ type, area }` | missionCalls | missioncalls |
| `server:sup:commend` / `server:admin:commend` | `{ citizenid, kind, citation, runUuid? }` → `{ id }` | issueCommendation / openAdmin | profile |
| `server:sup:revokeCommendation` / `server:admin:revokeCommendation` | `{ id, reason }` | issuer or admin | profile |
| `server:sup:reviewAvatar` / `server:admin:reviewAvatar` | `{ citizenid, decision, reason, what? }` | reviewProfiles / openAdmin | profile |
| `server:sup:clearProfile` / `server:admin:clearProfile` | `{ citizenid, what = 'bio'|'avatar', reason }` | reviewProfiles / openAdmin | profile |
| `server:sup:handleReport` / `server:admin:handleReport` | `{ id, decision = 'clear'|'dismiss', reason }` | reviewProfiles / openAdmin | profile |
| `server:sup:opRemoveJoiner` / `server:admin:opRemoveJoiner` | `{ src, reason }` | launchCrossDept | operations |
| `server:admin:setSetting` / `resetSetting` / `resetAllSettings` | `{ path, value? \| json?, none? }` / `{ path }` / — → SettingsReply | openAdmin | settings |
| `server:admin:setMissionEnabled` / `setLocationEnabled` / `resetMissionSwitches` | `{ missionId, enabled }` / `{ missionId, index, enabled }` / `{ missionId }` → MissionSwitchView | openAdmin | settings |

Key mappings: `crimsonpolice_dispatch` (Config.Tablet.dispatchKey), `crimsonpolice_ready` (readyKey),
`crimsonpolice_contact` (contactKey). ox_target option names (all `crimson-police:*`): `desk`,
`contact_<action>`, `seat_<action>_<door>`, `custody_escort`, `body_tag`, `body_bag`, `coroner`.

---

## 9. NUI protocol

### 9.1 Transport

Lua → NUI: `SendNUIMessage({ type = ..., ... })` (only modules/tablet/client.lua calls it).

| type | fields | meaning |
|---|---|---|
| `open` | `ui`, `session`, `screen?`, `seq?` | show a UI ('officer'\|'supervisor'\|'admin') and take focus; `screen` opens that screen (e.g. 'dispatch'); `seq` is confirmed with `opened` |
| `close` | — | hide the UI (HUD stays) |
| `session` | `session` | refreshed session |
| `notify` | `notification = { id, kind, title?, text, duration }` | Crimson-Police toast |
| `hud` | `hud = HudState \| null` | mission HUD (full state) |
| `result` | `result = RunResult` | result screen |
| `push` | `topic`, `data` | live data for open screens: `run`, `unit`, `board`, `operation`, `invites`, `test`, `builder`, `payouts`, and `calls` (DispatchView), `nav` (NavCounts), `profile` (own profile changed), `rewards` (locker changed), `contactConfirm`, `settings` (admins: a setting or switch changed, `{ paths }`); `unit` gains `readyCheck`, `run` gains `contact` |
| `overlay` | `overlay = null \| { kind: 'placement'\|'recording'\|'testdrive'\|'fade', ... }` | full-screen/HUD overlays |

NUI → Lua: `fetch('https://Crimson-Police/<endpoint>', { method: 'POST', body: JSON })`:

| endpoint | body | reply |
|---|---|---|
| `ready` | `{ acks? }` (`acks: true`: this NUI confirms every `open`) | `{ ok: true }` |
| `opened` | `{ seq }` (the UI of that `open` rendered) | `{ ok: true }` |
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

Parity-plus additions (web/src/shared/types.ts, verbatim there; all optional):

```ts
interface LevelInfo { n: number; label: string; badge: string; xp: number; levelXp: number;
  nextLevelXp: number | null; prestige: number }
interface Avatar { kind: 'initials' | 'preset' | 'url'; value: string | null; initials: string; frame: string }
interface Prefs { appearance: string; accent: string | null; uiScale: number; callsMuted: boolean }
                                                  // no language: English only
// Session.officer gains avatar?: Avatar; level?: LevelInfo. Session gains prefs?: Prefs and
// access?: { via: string; desk: number | null }. Session.config gains:
//   dispatch?: { enabled; areas: { key; label }[] }, leaderboardMetrics?: string[],
//   profile?: { bioMax, bioLines, presets, urls, appearances,
//   accents, uiScale }, commendationKinds?: string[], rewards?: { enabled }, format?: { currency, currencyAfter }
interface NavCounts { invites: number; calls: number; review: number; commendations: number; rewards: number;
  onRun: boolean }
interface ConfigHealthItem { check: string; level: 'ok' | 'warn' | 'error'; text: string }
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

Parity-plus screen data lives in its own type files (the Lua side follows them exactly):
`web/src/types/missioncalls.ts` (DispatchView, MissionCall, RecentCall, SupCallsView, AreaCoverage), `types/custody.ts`
(ContactView, ContactEntry, ContactConfirm), `types/profile.ts` (ProfileEdit, Commendation, ServiceStats,
ProfileQueueItem), `types/boards.ts` (the metric boards and profile additions), `types/teams.ts` (UnitView and
OperationView additions), `types/rewards.ts` (RewardRow, RewardsLocker, AdminRewardsView), `types/access.ts`
(TabletAccessView), `types/settings.ts` (SettingView, SettingsData, SettingsReply, SettingsHistory, MissionSwitchView) and
`types/run_ui.ts` (DecisionEntry, DecisionFact, DebriefPerson, RunProgress, RunStats,
RunMissionCall, RunItem and the
ActiveMissionView extras intel, missionCall and contact). BoardData gains `callsOpen` and daily locks; HomeData
gains `level` (LevelInfo), `missionsToday` and `extras` (callsOpen, commendations, news, rewardsWaiting).

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
    failedShare: number | null; final: number;
    cap?: number; scoreCap?: number; todMultiplier?: number };  // completed runs: the cap in whole points and the factors used
  cash: { B: number; mTier: number; mMod: number; amount: number; status: string };
  flagged: null | { reason: string };
  // parity-plus sections, each shown only when present (older rows lack them)
  decisions?: DecisionEntry[]; people?: DebriefPerson[] | null; progress?: RunProgress | null; stats?: RunStats;
  missionCall?: RunMissionCall | null; items?: RunItem[] }
// DecisionEntry.factLog?: { key, text, atS }[] (the facts the decider had); DebriefPerson = { contact, demeanour,
// did: string[] } (web/src/types/run_ui.ts); the result card, the Profile breakdown and the dispute reviews render
// both through web/src/hud/Debrief.tsx
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
  `block.<id>.*`, `modifier.<key>`, and for this build `mc.*`, `custody.*`, `bonus.*` additions, `rewards.*`.
- Optional label overrides (`CP.Locale.label`, `CP.Missions.label`): `type.<key>` (e.g. the ready-check prompt),
  `mission.<id>.label`, `mission.<id>.description`, `mission.<id>.location.<n>`. A missing key uses the text from
  config or the mission file, so custom missions keep the builder's text.
- English only in this build: `locales/en.json` is the only language file. Text for a player's screen that is
  built on the server may be sent as a `CP.Lt(key, vars)` token (§2); it resolves in the server language.
- The UI reads the same strings from `session.locale` via `t(key, vars)`.

## 11. Verification (every slice must pass before it is done)

`tools/check_all.sh` runs every check below in one command; `docs/TESTING.md` covers the set-up and how to
read a failure.

- `luac5.4 -p` on every Lua file it wrote.
- `python3 tools/lint_fivem.py`: the FiveM pitfall rules (wrong-side natives, late `source`, client `os`/`io`,
  unguarded focus release, raising callback awaits, orphan mode, `os.rename` answers, server `os.execute`,
  CRIMSON_ARENA natives, loops that can go round with no Wait (FX10, `tools/lua_flow.py`)); deliberate uses and bugs
  awaiting their fix are listed in `tools/lint_baseline.txt`.
- `python3 tools/restyle.py --check` lists no file: every Lua and web source is formatted to `docs/STYLE.md`
  (`python3 tools/restyle.py <files>` formats them).
- `cd Crimson-Police/web && npm run build` (tsc + vite) passes, for slices that touch web/.
- SQL: every query string it wrote must run against the MariaDB test database (`mysql -uroot cp_test`,
  schema already applied) — test SELECTs with sample params.
- Lua unit tests for pure logic go in `tests/<slice>_spec.lua` using `tests/harness.lua` (mocks of
  natives, `Config`, `CP`, and a `MySQL` that runs real queries on MariaDB `cp_test`) and run with
  `lua5.4 tests/run.lua <filter>`. See `tests/shared_spec.lua` for the pattern: `H.boot{side='server'}`,
  `H.load('modules/x/server.lua')`, stub other modules' tables (`CP.Runs = {...}`) as needed,
  `H.eq/H.ok/H.near`, `H.sql(...)` to reset tables, `H.fire(event, src, ...)` / `H.callback(name, src, args)`,
  `H.exportsMock['sc-dispatch'] = { ... }`, `H.players[src] = { coords = vec3(...), ace = {...} }`, and
  `return H` at the end. Specs run in separate processes, two at a time (`--jobs=N`), each on its own copy
  of the run database, which is rebuilt once per run. SQL `NOW()` is the spec's clock (`H.time` after
  `H.boot`) in every storage mode. Never leave a spec that fails, and never make a check depend on a random
  roll, the wall clock or the machine's time zone: the assertion counts are the same in every run and mode.
- Storage modes (`CP_TEST_STORAGE`, or `lua5.4 tests/run.lua --storage=<mode>`); the suite must pass in all three:
  - `database` (default): MySQL and `H.sql` go to MariaDB.
  - `files`: `Config.Database.enabled = false`; the real modules/storage files load, every module query and `H.sql`
    goes to CP.Storage.MemSQL and a temporary saves folder built by the real migrations runner (other resources' tables stay
    on MariaDB). A spec that compares a TINYINT(1) column accepts both the number and the boolean (`H.bit(v)`).
  - `shadow`: the specs get MariaDB's answers (as in database mode) while every statement also runs, in lockstep, on
    a MariaDB twin read the way oxmysql reads it (`tests/shadow/twin.cjs`: node + mysql2 with oxmysql's options,
    typeCast, parseArguments, parseResponse and error text; `cd tests/shadow && npm install` once) and on the
    engine through its MySQL drop-in, both from the migrated empty schema, NOW() pinned to the same second. Every
    difference (result, error, affected rows, insert id, value type, row order under ORDER BY, and every table and
    AUTO_INCREMENT counter at the end of each spec) is appended to `CP_SHADOW_REPORT`; the run fails unless the
    report is empty. `--fuzz[=N]` runs `tests/shadow/fuzz_*.lua` the same way for seeds 1..N: random aggregates
    (`fuzz_agg`), row queries and writes (`fuzz_rows`), functions, types and stores (`fuzz_funcs`), and every column
    type Crimson-Police uses fed every kind of value by INSERT / UPDATE in strict mode and with IGNORE, errors,
    warnings and notes included (`fuzz_store`; seed 1 runs its whole grid). What the engine deliberately does not
    copy (zero dates, warnings of expression evaluation, ...) is listed in the header of
    `modules/storage/memsql.lua`; the fuzz scripts keep clear of it.
  - A check that only means something on MariaDB is skipped with `H.skipIn(mode, reason)`; run.lua lists every skip.
  - A spec's `REPORT ...` lines are shown under its result (tests/storage_spec.lua prints its timings and sizes).
